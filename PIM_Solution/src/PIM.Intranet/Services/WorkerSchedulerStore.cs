using System.Data;
using Microsoft.Data.SqlClient;
using PIM.Automation;
using PIM.Operations;

namespace PIM.Intranet.Services;

/// <param name="IsOwner">Ali je najem naš (klicatelj procedure); pri branju za prikaz vedno false.</param>
/// <param name="CanRunCycles">Lastnik ima workerje (izvorno kodo ali objavljene) in cikle res poganja; sicer drži
/// uro samo za alarme zastalosti, dokler ga ne zamenja intranet, ki cikle lahko požene.</param>
public sealed record SchedulerLease(
  bool IsOwner, string Owner, string HostName, int ProcessId, string Application,
  DateTime AcquiredUtc, DateTime HeartbeatUtc, DateTime ExpiresUtc, long TickCount, bool CanRunCycles, int Priority = 0)
{
  public bool IsLive(DateTime nowUtc) => ExpiresUtc > nowUtc;

  /// <summary>Uro drži gostitelj avtomatike (237): intranet je takrat samo nadzorna konzola in starih ciklov ne poganja.</summary>
  public bool IsAutomationHost => Application.StartsWith(AutomationApplications.Prefix, StringComparison.Ordinal);
}

/// <summary>Vrstica ops.WorkerCycle z zadnjim stanjem (intranet.GetWorkerCycles).</summary>
public sealed record WorkerCycleRow(
  string CycleKey, string Label, int SortOrder, bool IsEnabled, int? IntervalSeconds, TimeOnly? DailyAtLocal,
  decimal WarnAfterMultiplier, DateTime? NextDueUtc, long? RunningRunId, DateTime? RunningSinceUtc, string? RunningHost,
  DateTime? LastStartedUtc, DateTime? LastEndedUtc, string? LastStatus, int? LastExitCode, int? LastDurationMs,
  string? LastTriggeredBy, string? LastHost, int? LastStepsFailed, string? LastError,
  DateTime UpdatedUtc, string UpdatedBy, string? RunningStep, DateTime? RunningHeartbeatUtc, int OpenOverdueAlerts,
  DateTime? LastSucceededUtc = null)
{
  /// <summary>
  /// Termin je že mimo, tek pa še traja: ura ga ne požene še enkrat (ops.ClaimWorkerCycle zavrne z
  /// »Running«), naslednji zagon pride šele po koncu tega. To je prikazano kot preprečeno prekrivanje,
  /// ne kot zamuda — cikel, ki traja dlje od svojega razmika, sicer ni napaka, je pa znak, da je
  /// razmik prekratek.
  /// </summary>
  public bool OverlapPrevented(DateTime nowUtc) => RunningRunId is not null && NextDueUtc is { } due && due <= nowUtc;
}

public sealed record WorkerCycleRunRow(
  long WorkerCycleRunId, string CycleKey, string? Label, DateTime StartedUtc, DateTime? EndedUtc, string Status, int? ExitCode,
  string TriggeredBy, string StartedBy, string HostName, string? LogPath, DateTime HeartbeatUtc, string? CurrentStep,
  int StepsTotal, int StepsFailed, int ErrorLines, string? Summary)
{
  public TimeSpan Duration => (EndedUtc ?? DateTime.UtcNow) - StartedUtc;
}

public sealed record WorkerCycleStepRow(
  int StepOrder, string StepName, int? OrganizationId, string? Command, DateTime StartedUtc, DateTime? EndedUtc,
  int? ExitCode, string Status, string? Note);

/// <summary>
/// Dostop do tabel razporejevalnika (migracija 221). Vsak klic odpre svojo povezavo: razporejevalnik
/// teče v ozadju brez DI seje, korak cikla pa lahko traja minute — držati povezavo odprto čez ves
/// tek bi pomenilo eno mrtvo sejo na cikel ob vsakem recikliranju bazena.
/// </summary>
public sealed class WorkerSchedulerStore(IConfiguration configuration)
{
  string ConnectionString => ConnectionStringResolver.Resolve(configuration)
    ?? throw new InvalidOperationException("Povezava PIM ni nastavljena.");

  public bool HasConnection => ConnectionStringResolver.Resolve(configuration) is { Length: > 0 };

  async Task<SqlConnection> OpenAsync(CancellationToken cancellationToken)
  {
    var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    return connection;
  }

  // ─── Najem ────────────────────────────────────────────────────────────────

  public async Task<SchedulerLease?> AcquireLeaseAsync(
    string owner, string hostName, int processId, string application, int ttlSeconds, bool canRunCycles, CancellationToken cancellationToken)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("ops.AcquireSchedulerLease", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@Owner", SqlDbType.NVarChar, 200).Value = owner;
    command.Parameters.Add("@HostName", SqlDbType.NVarChar, 200).Value = hostName;
    command.Parameters.Add("@ProcessId", SqlDbType.Int).Value = processId;
    command.Parameters.Add("@Application", SqlDbType.NVarChar, 200).Value = application;
    command.Parameters.Add("@TtlSeconds", SqlDbType.Int).Value = ttlSeconds;
    command.Parameters.Add("@CanRunCycles", SqlDbType.Bit).Value = canRunCycles;
    // 237: intranet ima prednost 0 — gostitelj avtomatike (10) mu uro vzame, tudi kadar je najem živ.
    command.Parameters.Add("@Priority", SqlDbType.Int).Value = 0;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    return await reader.ReadAsync(cancellationToken) ? ReadLease(reader, reader.GetBoolean(reader.GetOrdinal("IsOwner"))) : null;
  }

  public async Task ReleaseLeaseAsync(string owner, CancellationToken cancellationToken)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("ops.ReleaseSchedulerLease", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@Owner", SqlDbType.NVarChar, 200).Value = owner;
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  /// <summary>Najem za prikaz, ne za prevzem: kdo je ura zdaj, ne glede na ta proces.</summary>
  public async Task<SchedulerLease?> ReadLeaseAsync(CancellationToken cancellationToken = default)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand(
      "SELECT Owner, HostName, ProcessId, Application, AcquiredUtc, HeartbeatUtc, ExpiresUtc, TickCount, CanRunCycles, Priority FROM ops.SchedulerLease WHERE LeaseKey = N'PIM';",
      connection);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    return await reader.ReadAsync(cancellationToken) ? ReadLease(reader, false) : null;
  }

  static SchedulerLease ReadLease(SqlDataReader reader, bool isOwner) => new(
    isOwner, Text(reader, "Owner"), Text(reader, "HostName"), reader.GetInt32(reader.GetOrdinal("ProcessId")),
    Text(reader, "Application"), reader.GetDateTime(reader.GetOrdinal("AcquiredUtc")),
    reader.GetDateTime(reader.GetOrdinal("HeartbeatUtc")), reader.GetDateTime(reader.GetOrdinal("ExpiresUtc")),
    reader.GetInt64(reader.GetOrdinal("TickCount")), reader.GetBoolean(reader.GetOrdinal("CanRunCycles")),
    reader.GetInt32(reader.GetOrdinal("Priority")));

  // ─── Cikli ────────────────────────────────────────────────────────────────

  public async Task EnsureCyclesAsync(IEnumerable<WorkerCycleDefinition> cycles, CancellationToken cancellationToken)
  {
    await using var connection = await OpenAsync(cancellationToken);
    foreach (var cycle in cycles)
    {
      await using var command = new SqlCommand("ops.EnsureWorkerCycle", connection) { CommandType = CommandType.StoredProcedure };
      command.Parameters.Add("@CycleKey", SqlDbType.NVarChar, 40).Value = cycle.Key;
      command.Parameters.Add("@Label", SqlDbType.NVarChar, 100).Value = cycle.Label;
      command.Parameters.Add("@SortOrder", SqlDbType.Int).Value = cycle.SortOrder;
      command.Parameters.Add("@IntervalSeconds", SqlDbType.Int).Value = (object?)cycle.IntervalSeconds ?? DBNull.Value;
      command.Parameters.Add("@DailyAtLocal", SqlDbType.Time).Value = cycle.DailyAtLocal is { } at ? at.ToTimeSpan() : DBNull.Value;
      await command.ExecuteNonQueryAsync(cancellationToken);
    }
  }

  public async Task<IReadOnlyList<WorkerCycleRow>> GetCyclesAsync(CancellationToken cancellationToken = default)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.GetWorkerCycles", connection) { CommandType = CommandType.StoredProcedure };
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var rows = new List<WorkerCycleRow>();
    while (await reader.ReadAsync(cancellationToken))
      rows.Add(new(
        Text(reader, "CycleKey"), Text(reader, "Label"), Int(reader, "SortOrder"), reader.GetBoolean(reader.GetOrdinal("IsEnabled")),
        NullableInt(reader, "IntervalSeconds"), Time(reader, "DailyAtLocal"),
        reader.GetDecimal(reader.GetOrdinal("WarnAfterMultiplier")), NullableDate(reader, "NextDueUtc"),
        NullableLong(reader, "RunningRunId"), NullableDate(reader, "RunningSinceUtc"), NullableText(reader, "RunningHost"),
        NullableDate(reader, "LastStartedUtc"), NullableDate(reader, "LastEndedUtc"), NullableText(reader, "LastStatus"),
        NullableInt(reader, "LastExitCode"), NullableInt(reader, "LastDurationMs"), NullableText(reader, "LastTriggeredBy"),
        NullableText(reader, "LastHost"), NullableInt(reader, "LastStepsFailed"), NullableText(reader, "LastError"),
        reader.GetDateTime(reader.GetOrdinal("UpdatedUtc")), Text(reader, "UpdatedBy"),
        NullableText(reader, "RunningStep"), NullableDate(reader, "RunningHeartbeatUtc"), Int(reader, "OpenOverdueAlerts"),
        NullableDate(reader, "LastSucceededUtc")));
    return rows;
  }

  public async Task SetNextDueAsync(string cycleKey, DateTime nextDueUtc, bool onlyIfNull, CancellationToken cancellationToken)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("ops.SetWorkerCycleNextDue", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@CycleKey", SqlDbType.NVarChar, 40).Value = cycleKey;
    command.Parameters.Add("@NextDueUtc", SqlDbType.DateTime2).Value = nextDueUtc;
    command.Parameters.Add("@OnlyIfNull", SqlDbType.Bit).Value = onlyIfNull;
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  public async Task SaveCycleAsync(string cycleKey, bool isEnabled, int? intervalSeconds, TimeOnly? dailyAtLocal, string actor, CancellationToken cancellationToken = default)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.SaveWorkerCycle", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@CycleKey", SqlDbType.NVarChar, 40).Value = cycleKey;
    command.Parameters.Add("@IsEnabled", SqlDbType.Bit).Value = isEnabled;
    command.Parameters.Add("@IntervalSeconds", SqlDbType.Int).Value = (object?)intervalSeconds ?? DBNull.Value;
    command.Parameters.Add("@DailyAtLocal", SqlDbType.Time).Value = dailyAtLocal is { } at ? at.ToTimeSpan() : DBNull.Value;
    command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  // ─── Zagoni ───────────────────────────────────────────────────────────────

  /// <returns>Id zagona, kadar je cikel prevzet; sicer null in razlog (NotDue, Running:…, Disabled, Unknown).</returns>
  public async Task<(long? RunId, string Reason)> ClaimAsync(
    string cycleKey, DateTime nextDueUtc, string triggeredBy, string startedBy, string hostName, string? logPath, bool force,
    CancellationToken cancellationToken)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("ops.ClaimWorkerCycle", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@CycleKey", SqlDbType.NVarChar, 40).Value = cycleKey;
    command.Parameters.Add("@NextDueUtc", SqlDbType.DateTime2).Value = nextDueUtc;
    command.Parameters.Add("@TriggeredBy", SqlDbType.NVarChar, 30).Value = triggeredBy;
    command.Parameters.Add("@StartedBy", SqlDbType.NVarChar, 200).Value = startedBy;
    command.Parameters.Add("@HostName", SqlDbType.NVarChar, 200).Value = hostName;
    command.Parameters.Add("@LogPath", SqlDbType.NVarChar, 800).Value = (object?)logPath ?? DBNull.Value;
    command.Parameters.Add("@Force", SqlDbType.Bit).Value = force;
    var runId = command.Parameters.Add("@WorkerCycleRunId", SqlDbType.BigInt);
    runId.Direction = ParameterDirection.Output;
    var reason = command.Parameters.Add("@Reason", SqlDbType.NVarChar, 200);
    reason.Direction = ParameterDirection.Output;
    await command.ExecuteNonQueryAsync(cancellationToken);
    return (runId.Value is long id ? id : null, reason.Value as string ?? "");
  }

  public async Task HeartbeatAsync(long runId, string? currentStep, CancellationToken cancellationToken)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("ops.HeartbeatWorkerCycle", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@WorkerCycleRunId", SqlDbType.BigInt).Value = runId;
    command.Parameters.Add("@CurrentStep", SqlDbType.NVarChar, 200).Value = (object?)Cut(currentStep, 200) ?? DBNull.Value;
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  public async Task RecordStepAsync(
    long runId, int order, string name, int? organizationId, string? command, DateTime startedUtc, DateTime endedUtc,
    int? exitCode, string status, string? note, CancellationToken cancellationToken)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var sql = new SqlCommand("ops.RecordWorkerCycleStep", connection) { CommandType = CommandType.StoredProcedure };
    sql.Parameters.Add("@WorkerCycleRunId", SqlDbType.BigInt).Value = runId;
    sql.Parameters.Add("@StepOrder", SqlDbType.Int).Value = order;
    sql.Parameters.Add("@StepName", SqlDbType.NVarChar, 200).Value = Cut(name, 200)!;
    sql.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = (object?)organizationId ?? DBNull.Value;
    sql.Parameters.Add("@Command", SqlDbType.NVarChar, 1000).Value = (object?)Cut(command, 1000) ?? DBNull.Value;
    sql.Parameters.Add("@StartedUtc", SqlDbType.DateTime2).Value = startedUtc;
    sql.Parameters.Add("@EndedUtc", SqlDbType.DateTime2).Value = endedUtc;
    sql.Parameters.Add("@ExitCode", SqlDbType.Int).Value = (object?)exitCode ?? DBNull.Value;
    sql.Parameters.Add("@Status", SqlDbType.NVarChar, 20).Value = status;
    sql.Parameters.Add("@Note", SqlDbType.NVarChar, 2000).Value = (object?)Cut(note, 2000) ?? DBNull.Value;
    await sql.ExecuteNonQueryAsync(cancellationToken);
  }

  public async Task CompleteAsync(
    long runId, string status, int? exitCode, int stepsTotal, int stepsFailed, int errorLines, string? summary, string actor,
    CancellationToken cancellationToken)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("ops.CompleteWorkerCycle", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@WorkerCycleRunId", SqlDbType.BigInt).Value = runId;
    command.Parameters.Add("@Status", SqlDbType.NVarChar, 20).Value = status;
    command.Parameters.Add("@ExitCode", SqlDbType.Int).Value = (object?)exitCode ?? DBNull.Value;
    command.Parameters.Add("@StepsTotal", SqlDbType.Int).Value = stepsTotal;
    command.Parameters.Add("@StepsFailed", SqlDbType.Int).Value = stepsFailed;
    command.Parameters.Add("@ErrorLines", SqlDbType.Int).Value = errorLines;
    command.Parameters.Add("@Summary", SqlDbType.NVarChar, 2000).Value = (object?)Cut(summary, 2000) ?? DBNull.Value;
    command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  public async Task<int> AbandonAsync(string hostName, string actor, CancellationToken cancellationToken)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("ops.AbandonWorkerCycleRuns", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@HostName", SqlDbType.NVarChar, 200).Value = hostName;
    command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
    return Convert.ToInt32(await command.ExecuteScalarAsync(cancellationToken) ?? 0);
  }

  public async Task RaiseOverdueAlertsAsync(string actor, CancellationToken cancellationToken)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("ops.RaiseOverdueAlerts", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  public async Task<IReadOnlyList<WorkerCycleRunRow>> GetRunsAsync(int take = 40, string? cycleKey = null, CancellationToken cancellationToken = default)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.GetWorkerCycleRuns", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@Take", SqlDbType.Int).Value = take;
    command.Parameters.Add("@CycleKey", SqlDbType.NVarChar, 40).Value = (object?)cycleKey ?? DBNull.Value;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var rows = new List<WorkerCycleRunRow>();
    while (await reader.ReadAsync(cancellationToken))
      rows.Add(new(
        reader.GetInt64(reader.GetOrdinal("WorkerCycleRunId")), Text(reader, "CycleKey"), NullableText(reader, "Label"),
        reader.GetDateTime(reader.GetOrdinal("StartedUtc")), NullableDate(reader, "EndedUtc"), Text(reader, "Status"),
        NullableInt(reader, "ExitCode"), Text(reader, "TriggeredBy"), Text(reader, "StartedBy"), Text(reader, "HostName"),
        NullableText(reader, "LogPath"), reader.GetDateTime(reader.GetOrdinal("HeartbeatUtc")), NullableText(reader, "CurrentStep"),
        Int(reader, "StepsTotal"), Int(reader, "StepsFailed"), Int(reader, "ErrorLines"), NullableText(reader, "Summary")));
    return rows;
  }

  public async Task<IReadOnlyList<WorkerCycleStepRow>> GetStepsAsync(long runId, CancellationToken cancellationToken = default)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.GetWorkerCycleSteps", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@WorkerCycleRunId", SqlDbType.BigInt).Value = runId;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var rows = new List<WorkerCycleStepRow>();
    while (await reader.ReadAsync(cancellationToken))
      rows.Add(new(
        Int(reader, "StepOrder"), Text(reader, "StepName"), NullableInt(reader, "OrganizationId"), NullableText(reader, "Command"),
        reader.GetDateTime(reader.GetOrdinal("StartedUtc")), NullableDate(reader, "EndedUtc"), NullableInt(reader, "ExitCode"),
        Text(reader, "Status"), NullableText(reader, "Note")));
    return rows;
  }

  // ─── Kar cikel potrebuje od baze med tekom ────────────────────────────────

  /// <summary>Aktivna podjetja, ki niso izključena iz avtomatike.</summary>
  public async Task<IReadOnlyList<int>> GetActiveOrganizationsAsync(CancellationToken cancellationToken)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("""
      SELECT organizationValue.OrganizationId
      FROM dbo.OrganizationConfig organizationValue
      LEFT JOIN ops.OrganizationAutomationPolicy policy ON policy.OrganizationId = organizationValue.OrganizationId
      WHERE organizationValue.IsActive = 1 AND COALESCE(policy.IsEnabled, CONVERT(bit, 1)) = 1
      ORDER BY organizationValue.OrganizationId;
      """, connection);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var ids = new List<int>();
    while (await reader.ReadAsync(cancellationToken)) ids.Add(reader.GetInt32(0));
    return ids;
  }

  public Task<string?> ResolveSystemPathAsync(string key, CancellationToken cancellationToken) =>
    SystemPaths.ResolveAsync(ConnectionString, key, null, cancellationToken);

  /// <summary>
  /// Varovalka nočnega toka (Nocno-vse.ps1): sama vrstica Running v ops.PipelineRun ni dokaz, da kaj
  /// teče — blokira samo zajem, ki je hkrati Running, zadnji za svoj cevovod in je utripnil v
  /// zadnjih 15 minutah.
  /// </summary>
  public async Task<(int Live, int Orphans)> CountIngestRunsAsync(int hours, CancellationToken cancellationToken)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("""
      SELECT
        (SELECT COUNT(*)
           FROM ops.PipelineRun zagon
           INNER JOIN ops.IntegrationHealth zdravje
             ON zdravje.OrganizationId = zagon.OrganizationId AND zdravje.Pipeline = zagon.Pipeline AND zdravje.RunId = zagon.RunId
          WHERE zagon.Pipeline IN (N'SAOP_PRODUCTS', N'GENERIC_XML') AND zagon.Status = N'Running'
            AND zagon.StartedUtc > DATEADD(hour, -@Hours, SYSUTCDATETIME())
            AND zdravje.LastHeartbeatUtc > DATEADD(minute, -15, SYSUTCDATETIME())) AS Live,
        (SELECT COUNT(*) FROM ops.PipelineRun
          WHERE Status = N'Running' AND StartedUtc < DATEADD(hour, -1, SYSUTCDATETIME())) AS Orphans;
      """, connection);
    command.Parameters.Add("@Hours", SqlDbType.Int).Value = hours;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    return await reader.ReadAsync(cancellationToken) ? (reader.GetInt32(0), reader.GetInt32(1)) : (0, 0);
  }

  public async Task<(int Pending, int Quarantined)> RawInboxCountsAsync(CancellationToken cancellationToken)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand(
      "SELECT (SELECT COUNT(*) FROM raw.Inbox WHERE Status = N'Pending'), (SELECT COUNT(*) FROM raw.Inbox WHERE Status = N'Quarantined');", connection);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    return await reader.ReadAsync(cancellationToken) ? (reader.GetInt32(0), reader.GetInt32(1)) : (0, 0);
  }

  /// <summary>
  /// SQL korak cikla (validacija in objava). Zastoj (Msg 1205) je v SQL Serverju pričakovan dogodek,
  /// ne okvara: strežnik namenoma izbere eno stran za žrtev. Isto pravilo kot v scripts\Sql.ps1 —
  /// do trije poskusi z naraščajočim in naključnim počitkom, preden obupamo.
  /// </summary>
  public async Task ExecuteSqlStepAsync(IReadOnlyList<string> statements, int? organizationId, CancellationToken cancellationToken)
  {
    const int attempts = 3;
    for (var attempt = 1; ; attempt++)
    {
      try
      {
        await using var connection = await OpenAsync(cancellationToken);
        foreach (var statement in statements)
        {
          await using var command = new SqlCommand(statement, connection) { CommandTimeout = 1800 };
          command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = (object?)organizationId ?? DBNull.Value;
          await command.ExecuteNonQueryAsync(cancellationToken);
        }
        return;
      }
      catch (SqlException exception) when (exception.Number == 1205 && attempt < attempts)
      {
        await Task.Delay(TimeSpan.FromMilliseconds(500 * attempt + Random.Shared.Next(500)), cancellationToken);
      }
    }
  }

  // ─── Branje po imenu stolpca (PimDb: zaporedje se tiho pokvari) ──────────

  static string Text(SqlDataReader reader, string column) => reader.GetString(reader.GetOrdinal(column));
  static string? NullableText(SqlDataReader reader, string column)
  {
    var ordinal = reader.GetOrdinal(column);
    return reader.IsDBNull(ordinal) ? null : reader.GetString(ordinal);
  }
  static int Int(SqlDataReader reader, string column) => reader.GetInt32(reader.GetOrdinal(column));
  static int? NullableInt(SqlDataReader reader, string column)
  {
    var ordinal = reader.GetOrdinal(column);
    return reader.IsDBNull(ordinal) ? null : reader.GetInt32(ordinal);
  }
  static long? NullableLong(SqlDataReader reader, string column)
  {
    var ordinal = reader.GetOrdinal(column);
    return reader.IsDBNull(ordinal) ? null : reader.GetInt64(ordinal);
  }
  static DateTime? NullableDate(SqlDataReader reader, string column)
  {
    var ordinal = reader.GetOrdinal(column);
    return reader.IsDBNull(ordinal) ? null : reader.GetDateTime(ordinal);
  }
  static TimeOnly? Time(SqlDataReader reader, string column)
  {
    var ordinal = reader.GetOrdinal(column);
    return reader.IsDBNull(ordinal) ? null : TimeOnly.FromTimeSpan(reader.GetTimeSpan(ordinal));
  }
  static string? Cut(string? value, int max) => value is null ? null : value.Length <= max ? value : value[..max];
}
