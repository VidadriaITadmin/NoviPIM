using System.Data;
using Microsoft.Data.SqlClient;
using PIM.Operations;

namespace PIM.Intranet.Services;

/// <param name="IsStale">Postopek sme teči, pa se dlje od svojega dovoljenega zamika ni oglasil.</param>
/// <param name="Runs24h">Koliko zagonov je bilo v zadnjih 24 urah — nič pomeni, da nič ne tiktaka.</param>
public sealed record WorkerPulseRow(
  int OrganizationId, string OrganizationName, string Pipeline, bool IsEnabled,
  int IntervalSeconds, int StaleAfterSeconds, DateTime? NextScheduledUtc,
  string? Status, DateTime? LastHeartbeatUtc, DateTime? LastSuccessfulRunUtc, DateTime? LastFailedRunUtc,
  string? LastErrorRedacted, int? SecondsSinceHeartbeat, bool IsStale,
  string? LastRunStatus, DateTime? LastRunStartedUtc, int? LastRunDurationMs,
  long? LastRunRowsRead, long? LastRunRowsFailed,
  long Runs24h, long Failures24h, int? AvgDurationMs, int? MaxDurationMs)
{
  /// <summary>
  /// Ena beseda, ki jo skrbnik prebere iz treh metrov. Vrstni red presoje ni poljuben:
  /// izklopljen postopek ne more biti bolan, tišina je hujša od zabeležene napake (ker o njej
  /// nihče ne poroča), in šele nato šteje zadnji znani status.
  /// </summary>
  public WorkerHealth Health =>
    !IsEnabled ? WorkerHealth.Off
    : IsStale ? WorkerHealth.Silent
    : Status is "Failed" ? WorkerHealth.Failing
    : LastHeartbeatUtc is null ? WorkerHealth.NeverRun
    : Status is "Running" ? WorkerHealth.Running
    : WorkerHealth.Healthy;

  /// <summary>Ali je postopek počasnejši od svojega razmika — takrat se zagoni lovijo sami s seboj.</summary>
  public bool IsSlowerThanInterval => MaxDurationMs is { } max && max > IntervalSeconds * 1000;

  public int IntervalMinutes => Math.Max(1, IntervalSeconds / 60);
}

public enum WorkerHealth { Healthy, Running, Silent, Failing, Off, NeverRun }

public sealed record AdminAlertRow(
  long AlertId, int OrganizationId, string OrganizationName, string Pipeline, string AlertKind,
  string Severity, string Title, string PayloadSummaryRedacted, long OccurrenceCount,
  DateTime FirstSeenUtc, DateTime LastSeenUtc, DateTime? AcknowledgedUtc, string? AcknowledgedBy, bool IsSeen);

public sealed record SelfTestRunRow(
  long SelfTestRunId, Guid RunKey, string TestCode, DateTime StartedUtc, DateTime? EndedUtc,
  string Status, int StepsTotal, int StepsPassed, int StepsFailed, int StepsSkipped,
  int? DurationMs, string TriggeredBy, string? DetailRedacted);

public sealed record SelfTestStepRow(
  int Ordinal, string StepCode, string Label, string Status, int DurationMs,
  decimal? Measure, string? MeasureUnit, string? DetailRedacted);

public sealed record CatalogPulseRow(
  int OrganizationId, string OrganizationName, long ProductCount, long ActiveCount,
  long PublishedCount, long InvalidCount, long QuarantineCount);

public sealed record OutboxStatusRow(string Status, long MessageCount);

/// <param name="Source">Od kod je zaloga prišla: iz ERP prek SAOP ali iz dobaviteljeve datoteke.</param>
/// <param name="AgeHours">Koliko ur je star najnovejši posnetek tega vira.</param>
public sealed record StockFreshnessRow(
  string Source, int OrganizationId, string OrganizationName, long PositionCount,
  DateTime NewestSnapshotUtc, int AgeHours)
{
  /// <summary>Posnetek, starejši od enega dne, ni več zaloga, ampak zgodovina.</summary>
  public bool IsStale => AgeHours >= 24;
}

public sealed record SystemPathRow(
  int SystemPathId, string PathKey, int? OrganizationId, string? OrganizationName,
  string Location, bool IsActive, string? Note,
  DateTime? LastCheckedUtc, string? LastCheckResult, DateTime UpdatedUtc, string UpdatedBy);

public sealed record ExportSnapshotRow(
  string ProfileCode, string ProfileName, string ChannelCode, string EntityType, bool IsActive,
  int OrganizationId, string OrganizationName, DateTime StartedUtc, DateTime? EndedUtc, string Status,
  long? RowCountValue, int? ColumnCountValue, long? ByteCountValue, int? DurationMs,
  string? FileName, string TriggeredBy, string? ErrorRedacted);

/// <param name="UnseenCount">Odprti alarmi, ki jih ta skrbnik še ni videl; zvonček šteje te.</param>
/// <param name="SelfTestStatus">Izid zadnjega nočnega samotesta; <c>null</c>, če se še ni izvedel.</param>
public sealed record AttentionSummary(
  int SilentCount, int FailingCount, int CriticalCount, int UnseenCount, string? SelfTestStatus)
{
  public static AttentionSummary Empty { get; } = new(0, 0, 0, 0, null);

  /// <summary>Koliko stvari zahteva skrbnikovo pozornost; to je število na zvončku.</summary>
  public int Total => SilentCount + FailingCount + CriticalCount + (SelfTestStatus == "Failed" ? 1 : 0);

  /// <summary>Naslov zvončka; pove, kaj je narobe, ne samo koliko.</summary>
  public string Title
  {
    get
    {
      if (Total == 0) return "Vse teče: noben postopek ne molči in ni kritičnega alarma.";

      var deli = new List<string>(4);
      if (SilentCount > 0) deli.Add($"{SilentCount} postopkov molči");
      if (FailingCount > 0) deli.Add($"{FailingCount} v napaki");
      if (CriticalCount > 0) deli.Add($"{CriticalCount} kritičnih alarmov");
      if (SelfTestStatus == "Failed") deli.Add("nočni samotest je padel");
      return string.Join(", ", deli);
    }
  }
}

/// <summary>Vse, kar nadzorna plošča skrbnika pokaže naenkrat — iz enega obiska baze.</summary>
public sealed record AdminPulse(
  IReadOnlyList<WorkerPulseRow> Workers,
  IReadOnlyList<AdminAlertRow> Alerts,
  SelfTestRunRow? SelfTest,
  IReadOnlyList<SelfTestStepRow> SelfTestSteps,
  IReadOnlyList<CatalogPulseRow> Catalog,
  IReadOnlyList<OutboxStatusRow> Outbox,
  IReadOnlyList<ExportSnapshotRow> Exports)
{
  public static AdminPulse Empty { get; } = new([], [], null, [], [], [], []);

  public int SilentCount => Workers.Count(row => row.Health is WorkerHealth.Silent);
  public int FailingCount => Workers.Count(row => row.Health is WorkerHealth.Failing);
  public int OffCount => Workers.Count(row => row.Health is WorkerHealth.Off);
  public int HealthyCount => Workers.Count(row => row.Health is WorkerHealth.Healthy or WorkerHealth.Running);

  public int OpenCriticalCount => Alerts.Count(row => row.Severity == "Critical");
  public int UnseenCount => Alerts.Count(row => !row.IsSeen);

  /// <summary>Koliko stvari zahteva skrbnikovo pozornost zdaj; to je število na zvončku.</summary>
  public int AttentionCount => SilentCount + FailingCount + OpenCriticalCount
    + (SelfTest is { Status: "Failed" } ? 1 : 0);

  public long OutboxCount(string status) => Outbox.FirstOrDefault(row => row.Status == status)?.MessageCount ?? 0;
}

public sealed record WorkerPerformanceRow(
  string Pipeline, int? OrganizationId, string? OrganizationName, long RunCount,
  long SucceededCount, long WarningCount, long FailedCount,
  int? AvgDurationMs, int? MaxDurationMs, long RowsRead, long RowsFailed,
  DateTime? LastStartedUtc, int? IntervalSeconds)
{
  public decimal SuccessShare => RunCount == 0 ? 0 : Math.Round(100m * SucceededCount / RunCount, 1);

  /// <summary>Najdaljši zagon presega razmik: naslednji zagon čaka na prejšnjega.</summary>
  public bool OverrunsInterval => IntervalSeconds is { } interval && MaxDurationMs is { } max && max > interval * 1000;
}

public sealed record ActivityRow(
  DateTime OccurredUtc, string Actor, string ActionCode, string EntityType, string? EntityKey,
  int? OrganizationId, string? OrganizationName, string Summary, string? OldValue, string? NewValue,
  string SourceTable);

public sealed record ExportRunRow(
  long ExportRunId, string ProfileCode, string? ProfileName, string? ChannelCode,
  int OrganizationId, string? OrganizationName, DateTime StartedUtc, DateTime? EndedUtc, string Status,
  long? RowCountValue, int? ColumnCountValue, long? ByteCountValue, string? Sha256, string? FileName,
  int? DurationMs, string TriggeredBy, string? Actor, string? ErrorRedacted);

/// <summary>
/// Bralni in zapisovalni model skrbniške konzole (migracija 172).
///
/// Zakaj svoj servis in ne še ena metoda v <see cref="IntranetDataService"/>: konzola je edina
/// stran, ki bere <b>čez</b> vsa področja hkrati — urnike, zdravje, alarme, katalog, izvoze in
/// samotest. Če bi to razdelili po obstoječih servisih, bi ena stran držala pet odvisnosti in
/// pet ločenih obiskov baze, ploščice pa bi kazale pet različnih trenutkov.
///
/// Vsi časi tu so UTC, tako kot v bazi. V našo uro jih pretvori šele <see cref="PimTime"/>
/// v pogledu.
/// </summary>
public sealed class AdminConsoleService(PimDb database, IConfiguration configuration)
{
  string ConnectionString => ConnectionStringResolver.Resolve(configuration)
    ?? throw new InvalidOperationException("Povezava PIM ni nastavljena.");

  // ─── Utrip: en klic, sedem rezultatov ─────────────────────────────────────
  public async Task<AdminPulse> GetPulseAsync(string userKey, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.GetAdminPulse", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.AddWithValue("@UserKey", userKey);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);

    var workers = new List<WorkerPulseRow>();
    while (await reader.ReadAsync(cancellationToken))
      workers.Add(new(
        PimDb.Int32(reader, "OrganizationId"), PimDb.TextOrEmpty(reader, "OrganizationName"),
        PimDb.TextOrEmpty(reader, "Pipeline"), PimDb.Bool(reader, "IsEnabled"),
        PimDb.Int32(reader, "IntervalSeconds"), PimDb.Int32(reader, "StaleAfterSeconds"),
        PimDb.NullableDateTime(reader, "NextScheduledUtc"),
        PimDb.Text(reader, "Status"), PimDb.NullableDateTime(reader, "LastHeartbeatUtc"),
        PimDb.NullableDateTime(reader, "LastSuccessfulRunUtc"), PimDb.NullableDateTime(reader, "LastFailedRunUtc"),
        PimDb.Text(reader, "LastErrorRedacted"), NullableInt32(reader, "SecondsSinceHeartbeat"),
        PimDb.Bool(reader, "IsStale"),
        PimDb.Text(reader, "LastRunStatus"), PimDb.NullableDateTime(reader, "LastRunStartedUtc"),
        NullableInt32(reader, "LastRunDurationMs"),
        PimDb.NullableInt64(reader, "LastRunRowsRead"), PimDb.NullableInt64(reader, "LastRunRowsFailed"),
        PimDb.Int64(reader, "Runs24h"), PimDb.Int64(reader, "Failures24h"),
        NullableInt32(reader, "AvgDurationMs"), NullableInt32(reader, "MaxDurationMs")));

    var alerts = new List<AdminAlertRow>();
    if (await reader.NextResultAsync(cancellationToken))
      while (await reader.ReadAsync(cancellationToken))
        alerts.Add(new(
          PimDb.Int64(reader, "AlertId"), PimDb.Int32(reader, "OrganizationId"),
          PimDb.TextOrEmpty(reader, "OrganizationName"), PimDb.TextOrEmpty(reader, "Pipeline"),
          PimDb.TextOrEmpty(reader, "AlertKind"), PimDb.TextOrEmpty(reader, "Severity"),
          PimDb.TextOrEmpty(reader, "Title"), PimDb.TextOrEmpty(reader, "PayloadSummaryRedacted"),
          PimDb.Int64(reader, "OccurrenceCount"), PimDb.DateTimeValue(reader, "FirstSeenUtc"),
          PimDb.DateTimeValue(reader, "LastSeenUtc"), PimDb.NullableDateTime(reader, "AcknowledgedUtc"),
          PimDb.Text(reader, "AcknowledgedBy"), PimDb.Bool(reader, "IsSeen")));

    SelfTestRunRow? selfTest = null;
    if (await reader.NextResultAsync(cancellationToken) && await reader.ReadAsync(cancellationToken))
      selfTest = ReadSelfTestRun(reader);

    var steps = new List<SelfTestStepRow>();
    if (await reader.NextResultAsync(cancellationToken))
      while (await reader.ReadAsync(cancellationToken))
        steps.Add(new(
          PimDb.Int32(reader, "Ordinal"), PimDb.TextOrEmpty(reader, "StepCode"), PimDb.TextOrEmpty(reader, "Label"),
          PimDb.TextOrEmpty(reader, "Status"), PimDb.Int32(reader, "DurationMs"),
          PimDb.NullableDecimal(reader, "Measure"), PimDb.Text(reader, "MeasureUnit"),
          PimDb.Text(reader, "DetailRedacted")));

    var catalog = new List<CatalogPulseRow>();
    if (await reader.NextResultAsync(cancellationToken))
      while (await reader.ReadAsync(cancellationToken))
        catalog.Add(new(
          PimDb.Int32(reader, "OrganizationId"), PimDb.TextOrEmpty(reader, "OrganizationName"),
          PimDb.Int64(reader, "ProductCount"), PimDb.NullableInt64(reader, "ActiveCount") ?? 0,
          PimDb.NullableInt64(reader, "PublishedCount") ?? 0, PimDb.NullableInt64(reader, "InvalidCount") ?? 0,
          PimDb.Int64(reader, "QuarantineCount")));

    var outbox = new List<OutboxStatusRow>();
    if (await reader.NextResultAsync(cancellationToken))
      while (await reader.ReadAsync(cancellationToken))
        outbox.Add(new(PimDb.TextOrEmpty(reader, "Status"), PimDb.Int64(reader, "MessageCount")));

    var exports = new List<ExportSnapshotRow>();
    if (await reader.NextResultAsync(cancellationToken))
      while (await reader.ReadAsync(cancellationToken))
        exports.Add(new(
          PimDb.TextOrEmpty(reader, "ProfileCode"), PimDb.TextOrEmpty(reader, "ProfileName"),
          PimDb.TextOrEmpty(reader, "ChannelCode"), PimDb.TextOrEmpty(reader, "EntityType"),
          PimDb.Bool(reader, "IsActive"), PimDb.Int32(reader, "OrganizationId"),
          PimDb.TextOrEmpty(reader, "OrganizationName"), PimDb.DateTimeValue(reader, "StartedUtc"),
          PimDb.NullableDateTime(reader, "EndedUtc"), PimDb.TextOrEmpty(reader, "Status"),
          PimDb.NullableInt64(reader, "RowCountValue"), NullableInt32(reader, "ColumnCountValue"),
          PimDb.NullableInt64(reader, "ByteCountValue"), NullableInt32(reader, "DurationMs"),
          PimDb.Text(reader, "FileName"), PimDb.TextOrEmpty(reader, "TriggeredBy"),
          PimDb.Text(reader, "ErrorRedacted")));

    return new(workers, alerts, selfTest, steps, catalog, outbox, exports);
  }

  /// <summary>
  /// Poceni števec za zvonček v glavi aplikacije. Zvonček je na vsaki strani, zato tu ni
  /// celotnega utripa: en obisk baze, pet števil, brez branja tabel izdelkov.
  /// </summary>
  public async Task<AttentionSummary> GetAttentionAsync(string userKey, CancellationToken cancellationToken = default)
  {
    var rows = await database.QueryAsync("""
      SELECT
        (SELECT COUNT(*)
           FROM ops.ScheduleProfile razpored
           LEFT JOIN ops.IntegrationHealth zdravje
                  ON zdravje.OrganizationId = razpored.OrganizationId AND zdravje.Pipeline = razpored.Pipeline
          WHERE razpored.IsEnabled = 1
            AND (zdravje.LastHeartbeatUtc IS NULL
                 OR DATEDIFF(second, zdravje.LastHeartbeatUtc, SYSUTCDATETIME()) > razpored.StaleAfterSeconds)) AS SilentCount,
        (SELECT COUNT(*)
           FROM ops.IntegrationHealth zdravje
           JOIN ops.ScheduleProfile razpored
                  ON razpored.OrganizationId = zdravje.OrganizationId AND razpored.Pipeline = zdravje.Pipeline
          WHERE zdravje.Status = N'Failed' AND razpored.IsEnabled = 1) AS FailingCount,
        (SELECT COUNT(*) FROM ops.Alert WHERE ResolvedUtc IS NULL AND Severity = N'Critical') AS CriticalCount,
        (SELECT COUNT(*)
           FROM ops.Alert alarm
          WHERE alarm.ResolvedUtc IS NULL
            AND NOT EXISTS (SELECT 1 FROM ops.AlertSeen videno
                             WHERE videno.AlertId = alarm.AlertId AND videno.UserKey = @UserKey)) AS UnseenCount,
        (SELECT TOP (1) Status FROM ops.SelfTestRun ORDER BY StartedUtc DESC) AS SelfTestStatus;
      """,
      reader => new AttentionSummary(
        PimDb.Int32(reader, "SilentCount"), PimDb.Int32(reader, "FailingCount"),
        PimDb.Int32(reader, "CriticalCount"), PimDb.Int32(reader, "UnseenCount"),
        PimDb.Text(reader, "SelfTestStatus")),
      command => command.Parameters.AddWithValue("@UserKey", userKey), cancellationToken);

    return rows.Count > 0 ? rows[0] : AttentionSummary.Empty;
  }

  /// <summary>
  /// Zadnjih <paramref name="take"/> odprtih alarmov za zvonec v glavi — enako razvrscenih kot
  /// v <see cref="GetPulseAsync"/>, a brez ostalih sestih rezultatov, ker se zvonec izrise na
  /// vsaki strani in ne sme vleci celotnega utripa.
  /// </summary>
  public Task<IReadOnlyList<AdminAlertRow>> GetRecentAlertsAsync(string userKey, int take = 5, CancellationToken cancellationToken = default) =>
    database.QueryAsync("EXEC intranet.GetRecentAlerts @UserKey = @UserKey, @Take = @Take;",
      reader => new AdminAlertRow(
        PimDb.Int64(reader, "AlertId"), PimDb.Int32(reader, "OrganizationId"),
        PimDb.TextOrEmpty(reader, "OrganizationName"), PimDb.TextOrEmpty(reader, "Pipeline"),
        PimDb.TextOrEmpty(reader, "AlertKind"), PimDb.TextOrEmpty(reader, "Severity"),
        PimDb.TextOrEmpty(reader, "Title"), PimDb.TextOrEmpty(reader, "PayloadSummaryRedacted"),
        PimDb.Int64(reader, "OccurrenceCount"), PimDb.DateTimeValue(reader, "FirstSeenUtc"),
        PimDb.DateTimeValue(reader, "LastSeenUtc"), PimDb.NullableDateTime(reader, "AcknowledgedUtc"),
        PimDb.Text(reader, "AcknowledgedBy"), PimDb.Bool(reader, "IsSeen")),
      command =>
      {
        command.Parameters.AddWithValue("@UserKey", userKey);
        command.Parameters.AddWithValue("@Take", take);
      }, cancellationToken);

  /// <summary>
  /// Svežina zaloge po viru.
  ///
  /// Zakaj svoja poizvedba in ne del utripa: na zaslonu sta »zaloga« dve različni stvari, ki
  /// pišeta v isto tabelo — količine iz ERP prek SAOP in zaloga iz dobaviteljeve datoteke.
  /// Postopek <c>STOCK_FILE</c> je lahko zelen, ker mu datoteka priteče po javnem internetu,
  /// medtem ko <c>SAOP_STOCK</c> pada, ker do ERP ni povezave — in takrat je pol zaloge sveže,
  /// pol pa nekaj dni stare. Iz zelene lučke postopka to ni razvidno; iz starosti posnetka je.
  /// </summary>
  public Task<IReadOnlyList<StockFreshnessRow>> GetStockFreshnessAsync(CancellationToken cancellationToken = default) =>
    database.QueryAsync(StockFreshnessSql,
      reader => new StockFreshnessRow(
        PimDb.TextOrEmpty(reader, "Source"), PimDb.Int32(reader, "OrganizationId"),
        PimDb.Text(reader, "OrganizationName") ?? "—", PimDb.Int64(reader, "PositionCount"),
        PimDb.DateTimeValue(reader, "NewestSnapshotUtc"), NullableInt32(reader, "AgeHours") ?? 0),
      null, cancellationToken);

  // Vir se loci po koncni tocki posnetka: SAOP odgovarja na /iCenterAPI in na registrirane
  // poglede (migracija 145), datoteka dobavitelja pa nosi file:// oziroma fixture://.
  const string StockFreshnessSql = @"
    SELECT vir.Source, vir.OrganizationId, podjetje.Name AS OrganizationName,
           vir.PositionCount, vir.NewestSnapshotUtc,
           DATEDIFF(hour, vir.NewestSnapshotUtc, SYSUTCDATETIME()) AS AgeHours
      FROM (
        SELECT CASE WHEN posnetek.Endpoint LIKE '/iCenterAPI%' OR posnetek.Endpoint LIKE 'api/registeredviews%'
                      THEN N'SAOP (ERP)'
                    WHEN posnetek.Endpoint LIKE 'file://%' THEN N'Datoteka dobavitelja'
                    WHEN posnetek.Endpoint LIKE 'fixture://%' THEN N'Fixture'
                    ELSE N'Drugo' END AS Source,
               posnetek.OrganizationId,
               COUNT_BIG(*) AS PositionCount,
               MAX(posnetek.SnapshotUtc) AS NewestSnapshotUtc
          FROM stock.Position pozicija
          JOIN stock.Snapshot posnetek ON posnetek.SnapshotId = pozicija.SnapshotId
         WHERE posnetek.IsActive = 1
         GROUP BY CASE WHEN posnetek.Endpoint LIKE '/iCenterAPI%' OR posnetek.Endpoint LIKE 'api/registeredviews%'
                         THEN N'SAOP (ERP)'
                       WHEN posnetek.Endpoint LIKE 'file://%' THEN N'Datoteka dobavitelja'
                       WHEN posnetek.Endpoint LIKE 'fixture://%' THEN N'Fixture'
                       ELSE N'Drugo' END, posnetek.OrganizationId
      ) vir
      LEFT JOIN dbo.OrganizationConfig podjetje ON podjetje.OrganizationId = vir.OrganizationId
     ORDER BY vir.Source, vir.OrganizationId;";

  // ─── Mesta shranjevanja (migracija 173) ───────────────────────────────────
  public Task<IReadOnlyList<SystemPathRow>> GetSystemPathsAsync(CancellationToken cancellationToken = default) =>
    database.QueryAsync("EXEC intranet.GetSystemPaths;", reader => new SystemPathRow(
        PimDb.Int32(reader, "SystemPathId"), PimDb.TextOrEmpty(reader, "PathKey"),
        NullableInt32(reader, "OrganizationId"), PimDb.Text(reader, "OrganizationName"),
        PimDb.TextOrEmpty(reader, "Location"), PimDb.Bool(reader, "IsActive"), PimDb.Text(reader, "Note"),
        PimDb.NullableDateTime(reader, "LastCheckedUtc"), PimDb.Text(reader, "LastCheckResult"),
        PimDb.DateTimeValue(reader, "UpdatedUtc"), PimDb.TextOrEmpty(reader, "UpdatedBy")),
      null, cancellationToken);

  /// <summary>
  /// Shrani mesto shranjevanja. Pot se pred zapisom dejansko preizkusi z zapisom in brisom
  /// datoteke — obstoj mape ne pove ničesar o pravicah, pod IIS pa je prav pravica tista, ki
  /// manjka. Nepišljive poti ne shranimo: nastavitev, ki ne deluje, je slabša od privzetka,
  /// ker izgleda kot da deluje.
  /// </summary>
  public async Task<PathCheck> SaveSystemPathAsync(
    string pathKey, string location, string actor, int? organizationId = null, string? note = null,
    CancellationToken cancellationToken = default)
  {
    var preverba = SystemPaths.Check(location);
    if (!preverba.Writable) return preverba;

    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("ops.SetSystemPath", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.AddWithValue("@PathKey", pathKey);
    command.Parameters.AddWithValue("@Location", Trim(location.Trim(), 400));
    command.Parameters.AddWithValue("@UpdatedBy", Trim(actor, 200));
    command.Parameters.AddWithValue("@OrganizationId", organizationId is null ? DBNull.Value : organizationId.Value);
    command.Parameters.AddWithValue("@Note", note is null ? DBNull.Value : Trim(note, 400));
    command.Parameters.AddWithValue("@IsActive", true);
    command.Parameters.AddWithValue("@LastCheckResult", Trim(preverba.Message, 400));
    await command.ExecuteNonQueryAsync(cancellationToken);
    return preverba;
  }

  /// <summary>Odstrani nastavitev; od tedaj spet velja vgrajeni privzetek.</summary>
  public async Task ClearSystemPathAsync(string pathKey, int? organizationId = null, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("ops.ClearSystemPath", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.AddWithValue("@PathKey", pathKey);
    command.Parameters.AddWithValue("@OrganizationId", organizationId is null ? DBNull.Value : organizationId.Value);
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  // ─── Zmogljivost ──────────────────────────────────────────────────────────

  public Task<IReadOnlyList<WorkerPerformanceRow>> GetPerformanceAsync(int days, CancellationToken cancellationToken = default) =>
    database.QueryAsync("EXEC intranet.GetWorkerPerformance @Days = @Days;", reader => new WorkerPerformanceRow(
        PimDb.TextOrEmpty(reader, "Pipeline"), NullableInt32(reader, "OrganizationId"),
        PimDb.Text(reader, "OrganizationName"), PimDb.Int64(reader, "RunCount"),
        PimDb.NullableInt64(reader, "SucceededCount") ?? 0, PimDb.NullableInt64(reader, "WarningCount") ?? 0,
        PimDb.NullableInt64(reader, "FailedCount") ?? 0,
        NullableInt32(reader, "AvgDurationMs"), NullableInt32(reader, "MaxDurationMs"),
        PimDb.NullableInt64(reader, "RowsRead") ?? 0, PimDb.NullableInt64(reader, "RowsFailed") ?? 0,
        PimDb.NullableDateTime(reader, "LastStartedUtc"), NullableInt32(reader, "IntervalSeconds")),
      command => command.Parameters.AddWithValue("@Days", days), cancellationToken);

  // ─── Sled uporabnikov ─────────────────────────────────────────────────────
  public Task<IReadOnlyList<ActivityRow>> GetActivityAsync(
    int days, string? actor, string? search, int take, CancellationToken cancellationToken = default) =>
    database.QueryAsync("EXEC intranet.GetUserActivityTrail @Days = @Days, @Actor = @Actor, @Search = @Search, @Take = @Take;",
      reader => new ActivityRow(
        PimDb.DateTimeValue(reader, "OccurredUtc"), PimDb.TextOrEmpty(reader, "Actor"),
        PimDb.TextOrEmpty(reader, "ActionCode"), PimDb.TextOrEmpty(reader, "EntityType"),
        PimDb.Text(reader, "EntityKey"), NullableInt32(reader, "OrganizationId"),
        PimDb.Text(reader, "OrganizationName"), PimDb.TextOrEmpty(reader, "Summary"),
        PimDb.Text(reader, "OldValue"), PimDb.Text(reader, "NewValue"), PimDb.TextOrEmpty(reader, "SourceTable")),
      command =>
      {
        command.Parameters.AddWithValue("@Days", days);
        command.Parameters.AddWithValue("@Actor", string.IsNullOrWhiteSpace(actor) ? DBNull.Value : actor);
        command.Parameters.AddWithValue("@Search", string.IsNullOrWhiteSpace(search) ? DBNull.Value : search);
        command.Parameters.AddWithValue("@Take", take);
      }, cancellationToken);

  // ─── Izvozi ───────────────────────────────────────────────────────────────
  public Task<IReadOnlyList<ExportRunRow>> GetExportRunsAsync(
    int days, string? profileCode, int take, CancellationToken cancellationToken = default) =>
    database.QueryAsync("EXEC intranet.GetExportRuns @Days = @Days, @ProfileCode = @ProfileCode, @Take = @Take;",
      reader => new ExportRunRow(
        PimDb.Int64(reader, "ExportRunId"), PimDb.TextOrEmpty(reader, "ProfileCode"),
        PimDb.Text(reader, "ProfileName"), PimDb.Text(reader, "ChannelCode"),
        PimDb.Int32(reader, "OrganizationId"), PimDb.Text(reader, "OrganizationName"),
        PimDb.DateTimeValue(reader, "StartedUtc"), PimDb.NullableDateTime(reader, "EndedUtc"),
        PimDb.TextOrEmpty(reader, "Status"), PimDb.NullableInt64(reader, "RowCountValue"),
        NullableInt32(reader, "ColumnCountValue"), PimDb.NullableInt64(reader, "ByteCountValue"),
        PimDb.Text(reader, "Sha256"), PimDb.Text(reader, "FileName"), NullableInt32(reader, "DurationMs"),
        PimDb.TextOrEmpty(reader, "TriggeredBy"), PimDb.Text(reader, "Actor"), PimDb.Text(reader, "ErrorRedacted")),
      command =>
      {
        command.Parameters.AddWithValue("@Days", days);
        command.Parameters.AddWithValue("@ProfileCode", string.IsNullOrWhiteSpace(profileCode) ? DBNull.Value : profileCode);
        command.Parameters.AddWithValue("@Take", take);
      }, cancellationToken);

  // ─── Zgodovina nočnega samotesta ──────────────────────────────────────────
  public Task<IReadOnlyList<SelfTestRunRow>> GetSelfTestHistoryAsync(int take, CancellationToken cancellationToken = default) =>
    database.QueryAsync("EXEC intranet.GetSelfTestHistory @Take = @Take;", ReadSelfTestRun,
      command => command.Parameters.AddWithValue("@Take", take), cancellationToken);

  // ─── Zapisi ───────────────────────────────────────────────────────────────

  /// <summary>Označi vse odprte alarme kot videne za tega skrbnika; zvonček se s tem umiri.</summary>
  public async Task MarkAlertsSeenAsync(string userKey, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.MarkAlertsSeen", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.AddWithValue("@UserKey", userKey);
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  /// <summary>Označi eno samo obvestilo kot videno za tega skrbnika; zvonček ga nato izpusti.</summary>
  public async Task MarkAlertSeenAsync(string userKey, long alertId, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.MarkAlertSeen", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.AddWithValue("@UserKey", userKey);
    command.Parameters.AddWithValue("@AlertId", alertId);
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  /// <summary>
  /// Zapiše dejanje, ki drugod ne pusti sledi. Kliče se ob <b>uspešni</b> spremembi: sled, ki
  /// beleži tudi neuspele poskuse, bi trdila, da se je zgodilo nekaj, česar ni.
  /// </summary>
  public async Task LogActivityAsync(
    string actor, string actionCode, string entityType, string summary,
    string? entityKey = null, int? organizationId = null, string? oldValue = null, string? newValue = null,
    CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("ops.LogUserActivity", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.AddWithValue("@Actor", Trim(actor, 200));
    command.Parameters.AddWithValue("@ActionCode", Trim(actionCode, 60));
    command.Parameters.AddWithValue("@EntityType", Trim(entityType, 100));
    command.Parameters.AddWithValue("@Summary", Trim(summary, 400));
    command.Parameters.AddWithValue("@EntityKey", entityKey is null ? DBNull.Value : Trim(entityKey, 300));
    command.Parameters.AddWithValue("@OrganizationId", organizationId is null ? DBNull.Value : organizationId.Value);
    command.Parameters.AddWithValue("@OldValue", oldValue is null ? DBNull.Value : Trim(oldValue, 400));
    command.Parameters.AddWithValue("@NewValue", newValue is null ? DBNull.Value : Trim(newValue, 400));
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  /// <summary>
  /// Odpre zapis o izvozu na zahtevo iz intraneta. Enaka sled kot pri workerju: datoteka, ki
  /// jo je uporabnik prenesel, je enakovreden dogodek kot datoteka, ki jo je ponoči sestavil
  /// urnik — in prav tako mora biti v zgodovini.
  /// </summary>
  public async Task<Guid?> BeginExportRunAsync(
    string profileCode, int organizationId, string actor, CancellationToken cancellationToken = default)
  {
    try
    {
      await using var connection = new SqlConnection(ConnectionString);
      await connection.OpenAsync(cancellationToken);
      await using var command = new SqlCommand("out.BeginExportRun", connection) { CommandType = CommandType.StoredProcedure };
      command.Parameters.AddWithValue("@ProfileCode", profileCode);
      command.Parameters.AddWithValue("@OrganizationId", organizationId);
      command.Parameters.AddWithValue("@TriggeredBy", "Human");
      command.Parameters.AddWithValue("@Actor", Trim(actor, 200));
      var key = command.Parameters.Add("@RunKey", SqlDbType.UniqueIdentifier);
      key.Direction = ParameterDirection.Output;
      await command.ExecuteNonQueryAsync(cancellationToken);
      return (Guid)key.Value;
    }
    catch (SqlException)
    {
      // Datoteka, ki jo uporabnik čaka, je pomembnejša od zapisa o njej.
      return null;
    }
  }

  public async Task CompleteExportRunAsync(
    Guid? runKey, bool succeeded, long? rowCount = null, string? fileName = null, string? error = null,
    CancellationToken cancellationToken = default)
  {
    if (runKey is null) return;

    try
    {
      await using var connection = new SqlConnection(ConnectionString);
      await connection.OpenAsync(cancellationToken);
      await using var command = new SqlCommand("out.CompleteExportRun", connection) { CommandType = CommandType.StoredProcedure };
      command.Parameters.AddWithValue("@RunKey", runKey.Value);
      command.Parameters.AddWithValue("@Succeeded", succeeded);
      command.Parameters.AddWithValue("@RowCountValue", rowCount is null ? DBNull.Value : rowCount.Value);
      command.Parameters.AddWithValue("@FileName", fileName is null ? DBNull.Value : Trim(fileName, 400));
      command.Parameters.AddWithValue("@ErrorRedacted", error is null ? DBNull.Value : Trim(error, 2000));
      await command.ExecuteNonQueryAsync(cancellationToken);
    }
    catch (SqlException) { }
  }

  static SelfTestRunRow ReadSelfTestRun(SqlDataReader reader) => new(
    PimDb.Int64(reader, "SelfTestRunId"),
    HasColumn(reader, "RunKey") ? reader.GetGuid(reader.GetOrdinal("RunKey")) : Guid.Empty,
    PimDb.TextOrEmpty(reader, "TestCode"), PimDb.DateTimeValue(reader, "StartedUtc"),
    PimDb.NullableDateTime(reader, "EndedUtc"), PimDb.TextOrEmpty(reader, "Status"),
    PimDb.Int32(reader, "StepsTotal"), PimDb.Int32(reader, "StepsPassed"),
    PimDb.Int32(reader, "StepsFailed"), PimDb.Int32(reader, "StepsSkipped"),
    NullableInt32(reader, "DurationMs"), PimDb.TextOrEmpty(reader, "TriggeredBy"),
    PimDb.Text(reader, "DetailRedacted"));

  // GetSelfTestHistory ne vrača RunKey — enak zapis brani obe poti, zato se stolpec preveri.
  static bool HasColumn(SqlDataReader reader, string name)
  {
    for (var index = 0; index < reader.FieldCount; index++)
      if (string.Equals(reader.GetName(index), name, StringComparison.OrdinalIgnoreCase)) return true;
    return false;
  }

  static int? NullableInt32(SqlDataReader reader, string column)
  {
    var ordinal = reader.GetOrdinal(column);
    return reader.IsDBNull(ordinal) ? null : Convert.ToInt32(reader.GetValue(ordinal));
  }

  static string Trim(string value, int length) => value.Length <= length ? value : value[..length];
}
