using System.Data;
using Microsoft.Data.SqlClient;
using PIM.Operations;
using PIM.Outbound;

namespace PIM.OutboxDispatcher;

/// <summary>Sporočilo, kot ga vrne <c>out.ClaimMessage</c>.</summary>
public sealed record ClaimedOutboxMessage(
  long OutboxMessageId,
  int OrganizationId,
  string PayloadJson,
  string EndpointTemplate,
  string HttpOperation,
  int TimeoutSeconds,
  int AttemptCount,
  int MaxAttempts);

/// <summary>Izid enega zagona dispatcherja.</summary>
/// <param name="Claimed">Koliko sporočil je bilo prevzetih.</param>
/// <param name="Sent">Koliko jih je bilo poslanih (2xx).</param>
/// <param name="Failed">Koliko jih je končalo v Retry ali Dead.</param>
/// <param name="ScheduleMissing">
/// Ali je zagon odpadel, ker za <c>OUTBOUND</c> ni omogočenega razporeda. Ni napaka
/// dispatcherja — je manjkajoča nastavitev.
/// </param>
/// <param name="AlreadyRunning">
/// Ali je isto izvajanje že teklo (<c>51101</c>). Za načrtovan worker je prekrivanje
/// normalno stanje, ne napaka: drugi zagon se umakne in ne stori ničesar.
/// </param>
/// <param name="Truncated">
/// Ali je zagon zadel mejo <c>maxMessages</c>. Takrat v vrsti lahko ostane še kaj —
/// meja se izpiše, da tiho odrezana vrsta ne izgleda kot prazna.
/// </param>
public sealed record DispatchRunResult(
  int Claimed,
  int Sent,
  int Failed,
  bool ScheduleMissing,
  bool AlreadyRunning = false,
  bool Truncated = false);

/// <summary>Pošiljanje ene zahteve. Ločeno od zagona, da ga test lahko zamenja z lokalnim fixtureom.</summary>
public delegate Task<DispatchResult> OutboundSend(ClaimedOutboxMessage message, CancellationToken cancellationToken);

/// <summary>
/// En zagon odhodne poti: prevzame sporočila iz <c>out.OutboxMessage</c>, pošlje jih in
/// zapiše izid. Logika je tu in ne v <c>Program.cs</c>, ker je <c>Program.cs</c> ni mogoče
/// preizkusiti — dispatcher je bil doslej edini del odhodne poti brez testa.
/// </summary>
public sealed class OutboxDispatchRunner(string connectionString, string workerId, OutboundSend send, int maxMessages = 100)
{
  public const string Pipeline = "OUTBOUND";

  /// <summary>ops.BeginRun: za ta par (organizacija, pipeline) izvajanje ze tece.</summary>
  const int ConcurrentRunErrorNumber = 51101;

  public async Task<DispatchRunResult> RunAsync(CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(connectionString);
    await connection.OpenAsync(cancellationToken);

    // Razpored se prebere PRED prvim prevzemom. ops.BeginRun vrze 51100, ce za par
    // (organizacija, OUTBOUND) ni omogocene vrstice v ops.ScheduleProfile. Ce bi to
    // izvedeli sele po out.ClaimMessage — kot doslej — bi sporocilo ostalo v Sending s
    // porabljenim poskusom in brez poslane zahteve; ob dovolj ponovitvah bi umrlo od
    // poskusov, ki se niso zgodili. Manjkajoc razpored zato ni izjema, ampak izid zagona.
    var scheduled = await ReadScheduledOrganizationsAsync(connection, cancellationToken);
    if (scheduled.Count == 0) return new(0, 0, 0, true);

    var runs = new Dictionary<int, OperationsRun>();
    var failuresByOrganization = new Dictionary<int, int>();
    var claimed = 0;
    var sent = 0;
    var failed = 0;
    try
    {
      // Vsa izvajanja se odprejo pred prvim prevzemom, da noben prevzem ne prehiti svojega
      // zagona. Zakljucek je v finally, tudi ce eno izvajanje ne uspe odpreti.
      foreach (var organizationId in scheduled)
      {
        try
        {
          runs[organizationId] = await OperationsRun.BeginAsync(connectionString, organizationId, Pipeline, workerId, cancellationToken);
        }
        catch (SqlException exception) when (exception.Number == ConcurrentRunErrorNumber)
        {
          // 51101: za to podjetje ta pipeline ze tece. Nacrtovan worker se sam s sabo redno
          // prekriva, kadar prejsnji zagon traja dlje od intervala; to ni napaka in ne sme
          // koncati z neobravnavano izjemo. Drugi zagon se umakne in ne prevzame nicesar.
          return new(0, 0, 0, false, AlreadyRunning: true);
        }
        failuresByOrganization[organizationId] = 0;
      }

      // Zanka, ne eno sporocilo: dispatcher je doslej obdelal prvo sporocilo in koncal, zato
      // se cakalna vrsta ni praznila brez toliko zagonov, kolikor je bilo sporocil.
      while (claimed < maxMessages && !cancellationToken.IsCancellationRequested)
      {
        var message = await ClaimAsync(connection, cancellationToken);
        if (message is null) break;
        claimed++;

        if (!runs.TryGetValue(message.OrganizationId, out var operationsRun))
        {
          // Podjetje ima omogoceno integracijo, razporeda za OUTBOUND pa ne. Sporocila ne
          // ubijemo in ne ugibamo poslovnega pravila: zacasna napaka ga vrne v Retry.
          await CompleteAttemptAsync(connection, message,
            new(DispatchOutcome.Retry, 0, string.Empty, null, OutboundErrorClass.Transient),
            $"Za organizacijo {message.OrganizationId} ni omogocenega razporeda {Pipeline}.", cancellationToken);
          failed++;
          continue;
        }

        // Utrip na sporocilo: brez tega bi daljsa cakalna vrsta izgledala kot zastal zagon,
        // enako kot se je zgodilo zajemu 2026-08-21.
        await operationsRun.HeartbeatAsync(cancellationToken: cancellationToken);

        var (result, failureReason) = await SendAsync(message, cancellationToken);
        await CompleteAttemptAsync(connection, message, result, failureReason, cancellationToken);
        if (result.Outcome == DispatchOutcome.Sent) sent++;
        else { failed++; failuresByOrganization[message.OrganizationId]++; }
      }
    }
    finally
    {
      foreach (var (organizationId, operationsRun) in runs)
      {
        var organizationFailed = failuresByOrganization[organizationId] > 0;
        try { await operationsRun.CompleteAsync(!organizationFailed, organizationFailed ? "Odhodna dostava ni uspela." : null, CancellationToken.None); }
        catch (SqlException) { /* zakljucek zagona ne sme povoziti izvorne napake */ }
        await operationsRun.DisposeAsync();
      }
    }

    return new(claimed, sent, failed, false, Truncated: claimed >= maxMessages);
  }

  /// <summary>Organizacije z omogocenim razporedom za <see cref="Pipeline"/>.</summary>
  static async Task<List<int>> ReadScheduledOrganizationsAsync(SqlConnection connection, CancellationToken cancellationToken)
  {
    await using var command = new SqlCommand(
      """
      SELECT profile.OrganizationId
      FROM ops.ScheduleProfile profile
      LEFT JOIN ops.OrganizationAutomationPolicy policy ON policy.OrganizationId = profile.OrganizationId
      WHERE profile.Pipeline=@Pipeline AND profile.IsEnabled=1 AND COALESCE(policy.IsEnabled, CONVERT(bit, 1))=1
      ORDER BY profile.OrganizationId;
      """, connection);
    command.Parameters.Add("@Pipeline", SqlDbType.NVarChar, 100).Value = Pipeline;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var organizations = new List<int>();
    while (await reader.ReadAsync(cancellationToken)) organizations.Add(reader.GetInt32(0));
    await reader.CloseAsync();
    return organizations;
  }

  /// <summary>
  /// Posiljanje enega sporocila. Nobena napaka enega sporocila ne sme podreti zagona:
  /// out.ClaimMessage bere vrsto po <c>OutboxMessageId</c>, zato bi eno sporocilo s pokvarjeno
  /// nastavitvijo (na primer <c>HttpOperation</c>, ki ni POST ali PATCH, ali neveljaven
  /// <c>EndpointTemplate</c>) ob vsakem zagonu vrglo izjemo na istem mestu in trajno zaprlo
  /// pot vsem sporocilom za sabo. Zato se ujame vsaka izjema, ne le omrezna.
  /// </summary>
  async Task<(DispatchResult Result, string? FailureReason)> SendAsync(ClaimedOutboxMessage message, CancellationToken cancellationToken)
  {
    try
    {
      return (await send(message, cancellationToken), null);
    }
    catch (Exception exception)
    {
      // Prekinjena povezava, iztek casa ali pokvarjena nastavitev — nic od tega ni poslovna
      // zavrnitev, zato ostane Transient in sporocilo se sme ponoviti.
      var outcome = message.AttemptCount >= message.MaxAttempts ? DispatchOutcome.Dead : DispatchOutcome.Retry;
      // V bazo gre samo vrsta izjeme. Sporocilo izjeme lahko nosi naslov s poverilnico ali
      // zeton, redakcija iz SaopOutboundHandler pa velja za telo odgovora, ne za izjemo.
      return (new(outcome, 0, string.Empty, null, OutboundErrorClass.Transient), $"Dispatcher: {exception.GetType().Name}.");
    }
  }

  async Task<ClaimedOutboxMessage?> ClaimAsync(SqlConnection connection, CancellationToken cancellationToken)
  {
    // Isti workerId gre v claim in v complete: out.CompleteAttempt zavrne zakljucek poskusa,
    // ki ga je prevzel nekdo drug (F8 hardening, "stari worker po reclaimu").
    await using var claim = new SqlCommand("EXEC out.ClaimMessage @WorkerId;", connection);
    claim.Parameters.Add("@WorkerId", SqlDbType.NVarChar, 200).Value = workerId;
    await using var reader = await claim.ExecuteReaderAsync(cancellationToken);
    if (!await reader.ReadAsync(cancellationToken)) return null;
    var message = new ClaimedOutboxMessage(
      reader.GetInt64(reader.GetOrdinal("OutboxMessageId")),
      reader.GetInt32(reader.GetOrdinal("OrganizationId")),
      reader.GetString(reader.GetOrdinal("PayloadJson")),
      reader.GetString(reader.GetOrdinal("EndpointTemplate")),
      reader.GetString(reader.GetOrdinal("HttpOperation")),
      reader.GetInt32(reader.GetOrdinal("TimeoutSeconds")),
      reader.GetInt32(reader.GetOrdinal("AttemptCount")),
      reader.GetInt32(reader.GetOrdinal("MaxAttempts")));
    await reader.CloseAsync();
    return message;
  }

  async Task CompleteAttemptAsync(SqlConnection connection, ClaimedOutboxMessage message, DispatchResult result, string? failureReason, CancellationToken cancellationToken)
  {
    await using var complete = new SqlCommand(
      "EXEC out.CompleteAttempt @OutboxMessageId,@WorkerId,@Succeeded,@PermanentFailure,@ResponseStatusCode,@ResponseBodyRedacted,@ResponseCorrelationId,@FailureReason,@ErrorClass;",
      connection);
    complete.Parameters.AddWithValue("@OutboxMessageId", message.OutboxMessageId);
    complete.Parameters.AddWithValue("@WorkerId", workerId);
    complete.Parameters.AddWithValue("@Succeeded", result.Outcome == DispatchOutcome.Sent);
    complete.Parameters.AddWithValue("@PermanentFailure", result.Outcome == DispatchOutcome.Dead);
    complete.Parameters.AddWithValue("@ResponseStatusCode", result.StatusCode == 0 ? DBNull.Value : result.StatusCode);
    complete.Parameters.AddWithValue("@ResponseBodyRedacted", result.RedactedBody);
    complete.Parameters.AddWithValue("@ResponseCorrelationId", (object?)result.CorrelationId ?? DBNull.Value);
    complete.Parameters.AddWithValue("@FailureReason", result.Outcome == DispatchOutcome.Sent ? DBNull.Value : failureReason ?? $"HTTP dispatch: {result.Outcome} ({result.ErrorClass}).");
    complete.Parameters.AddWithValue("@ErrorClass", result.ErrorClass == OutboundErrorClass.None ? DBNull.Value : result.ErrorClass.ToString());
    await complete.ExecuteNonQueryAsync(cancellationToken);
  }
}
