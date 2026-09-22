using System.Data;
using System.Globalization;
using Microsoft.Data.SqlClient;
using PIM.Operations;

namespace PIM.XmlMapping;

/// <summary>
/// Faza PRESLIKAVA po preslikavi enega zagona (blok 6 prenove nadzora, 2026-09-22).
///
/// Zakaj: preslikava je bila doslej nevidna. Worker je javil »zajem uspel«, strani pa so lahko
/// ostale Pending (entiteta brez preslikave, zastoj) ali šle v karanteno (pokvarjen XML), in tega
/// ni videl nihče, dokler ni kdo preštel vrstic v raw.Inbox. Stanje strani PO preslikavi je edini
/// pošten dokaz, da so podatki prišli v katalog, zato ga pomočnik prešteje v bazi, ne iz spomina
/// workerja. Isti pomočnik za SAOP artikle, naročila in dobaviteljev XML: ena pravila, ena beseda.
///
/// Izid na EntityType (glej <see cref="Classify"/>):
///   - vse strani v karanteni → Failed (nič ni prišlo v katalog);
///   - po preslikavi ostajajo strani Pending → Succeeded brez novih podatkov, sporočilo »čaka N«;
///   - sicer → Succeeded z novimi podatki, če je bila obdelana vsaj ena stran.
/// Zagon brez ene same strani (vse že zajeto, prazen odgovor) → ena faza Skipped z razlogom.
///
/// Števila so STRANI raw.Inbox (ItemsIn = vse, ItemsOut = Processed, ItemsRejected = Quarantined),
/// ne zapisi — ena stran nosi do tisoč zapisov; zapise šteje faza PRENOS oziroma ZAPIS.
///
/// Poročanje nikoli ne podre workerja: PhaseLog pogoltne napake baze, napaka pri štetju pa se
/// zapiše kot faza brez števil (preslikava sama je v tem trenutku že uspela).
/// </summary>
public static class MappingPhaseReport
{
  /// <summary>Stanje strani ene entitete v zagonu po preslikavi.</summary>
  public sealed record EntityCount(string EntityType, long Total, long Processed, long Quarantined, long Pending, string? QuarantineReason);

  /// <summary>Izid faze za eno entiteto; čista funkcija <see cref="Classify"/>.</summary>
  public sealed record Verdict(PhaseOutcome Outcome, bool HasNewData, string Message);

  /// <summary>
  /// Prešteje strani zagona po entiteti in stanju ter zapiše eno fazo PRESLIKAVA na entiteto.
  /// </summary>
  /// <param name="sourceCode">SourceCode faze (vir, pod katerim nadzor meri svežino); null → ime entitete.</param>
  /// <param name="organizationId">Podjetje faze in hkrati omejitev štetja (null = vse vrstice zagona).</param>
  /// <param name="pipeline">Postopek faze (GENERIC_XML, SAOP_PRODUCTS, SAOP_ORDERS_VNK ...).</param>
  public static Task<IReadOnlyList<EntityCount>> RecordAsync(
    PhaseLog phases, string connectionString, Guid runId, string? sourceCode, int? organizationId, string pipeline,
    CancellationToken cancellationToken = default) =>
    RecordAsync(phases, connectionString, runId, sourceCode, organizationId, pipeline, perEntity: null, cancellationToken);

  /// <param name="perEntity">
  /// Kadar ima vsaka entiteta svoj vir (SAOP: ItemGeneralData je vir GetItemsGeneralData pod SAOP_PRODUCTS,
  /// Prices je GetPrices pod SAOP_PRICES), vrne (SourceCode, Pipeline) za entiteto; null → privzeta vira zgoraj.
  /// </param>
  public static async Task<IReadOnlyList<EntityCount>> RecordAsync(
    PhaseLog phases, string connectionString, Guid runId, string? sourceCode, int? organizationId, string pipeline,
    Func<string, (string? SourceCode, string Pipeline)?>? perEntity, CancellationToken cancellationToken = default)
  {
    IReadOnlyList<EntityCount> counts;
    try
    {
      counts = await CountAsync(connectionString, runId, organizationId, cancellationToken);
    }
    catch (Exception exception) when (exception is SqlException or InvalidOperationException)
    {
      await phases.RecordAsync(PhaseCodes.Map, PhaseOutcome.Succeeded, sourceCode, organizationId, pipeline, runId,
        $"preslikava je končala, stanja strani v raw.Inbox pa ni bilo mogoče prešteti ({exception.GetType().Name})");
      return [];
    }

    if (counts.Count == 0)
    {
      await phases.RecordAsync(PhaseCodes.Map, PhaseOutcome.Skipped, sourceCode, organizationId, pipeline, runId,
        "ta zagon ni zapisal nobene strani v raw.Inbox (vse je že zajeto ali je bil odgovor prazen); ni bilo česa preslikati");
      return counts;
    }

    foreach (var count in counts)
    {
      var (vir, postopek) = perEntity?.Invoke(count.EntityType) ?? (sourceCode ?? count.EntityType, pipeline);
      var verdict = Classify(count);
      await phases.RecordAsync(PhaseCodes.Map, verdict.Outcome, vir, organizationId, postopek, runId, verdict.Message,
        verdict.HasNewData, itemsIn: count.Total, itemsOut: count.Processed, itemsRejected: count.Quarantined);
    }
    return counts;
  }

  /// <summary>Preslikava je padla z izjemo: sled ostane kot padla faza, izjema gre naprej h klicatelju.</summary>
  public static Task RecordFailureAsync(
    PhaseLog phases, Guid runId, string? sourceCode, int? organizationId, string pipeline, Exception exception) =>
    phases.RecordAsync(PhaseCodes.Map, PhaseOutcome.Failed, sourceCode, organizationId, pipeline, runId,
      $"preslikava je padla: {exception.Message}");

  /// <summary>Izid faze PRESLIKAVA za eno entiteto. Čista funkcija, da je pravilo mogoče preveriti brez baze.</summary>
  public static Verdict Classify(EntityCount count)
  {
    // Razlog karantene gre sredi stavka; njegova končna pika bi se ob piki vrstice podvojila.
    var razlog = count.QuarantineReason?.Trim().TrimEnd('.').Trim();
    var karantena = count.Quarantined > 0
      ? $", v karanteni {Number(count.Quarantined)}{(razlog is { Length: > 0 } ? $" ({razlog})" : "")}"
      : "";

    if (count.Total > 0 && count.Quarantined == count.Total)
      return new(PhaseOutcome.Failed, false,
        $"{count.EntityType}: vse strani ({Number(count.Total)}) so v karanteni{(razlog is { Length: > 0 } ? $": {razlog}" : "")}");

    if (count.Pending > 0)
      return new(PhaseOutcome.Succeeded, false,
        $"{count.EntityType}: čaka {Number(count.Pending)} strani (entiteta brez aktivne preslikave ali preslikava ni končala){karantena}");

    return count.Processed > 0
      ? new(PhaseOutcome.Succeeded, true, $"{count.EntityType}: obdelanih strani {Number(count.Processed)}{karantena}")
      : new(PhaseOutcome.Succeeded, false, $"{count.EntityType}: nobena stran ni bila obdelana{karantena}");
  }

  static async Task<IReadOnlyList<EntityCount>> CountAsync(string connectionString, Guid runId, int? organizationId, CancellationToken cancellationToken)
  {
    const string sql = """
      SELECT EntityType,
             Total = COUNT_BIG(*),
             Processed = SUM(CONVERT(bigint, CASE WHEN Status = N'Processed' THEN 1 ELSE 0 END)),
             Quarantined = SUM(CONVERT(bigint, CASE WHEN Status = N'Quarantined' THEN 1 ELSE 0 END)),
             Pending = SUM(CONVERT(bigint, CASE WHEN Status = N'Pending' THEN 1 ELSE 0 END)),
             Reason = MAX(CASE WHEN Status = N'Quarantined' THEN LEFT(FailureReason, 200) END)
      FROM raw.Inbox
      WHERE RunId = @RunId AND (@OrganizationId IS NULL OR OrganizationId = @OrganizationId)
      GROUP BY EntityType
      ORDER BY EntityType;
      """;
    await using var connection = new SqlConnection(connectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand(sql, connection) { CommandTimeout = 120 };
    command.Parameters.Add("@RunId", SqlDbType.UniqueIdentifier).Value = runId;
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = (object?)organizationId ?? DBNull.Value;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var counts = new List<EntityCount>();
    while (await reader.ReadAsync(cancellationToken))
    {
      counts.Add(new EntityCount(
        reader.GetString(0), reader.GetInt64(1), reader.GetInt64(2), reader.GetInt64(3), reader.GetInt64(4),
        reader.IsDBNull(5) ? null : reader.GetString(5)));
    }
    return counts;
  }

  static string Number(long value) => value.ToString("N0", CultureInfo.GetCultureInfo("sl-SI"));
}
