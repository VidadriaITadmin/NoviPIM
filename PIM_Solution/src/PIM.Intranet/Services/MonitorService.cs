using System.Data;
using Microsoft.Data.SqlClient;
using PIM.Automation;

namespace PIM.Intranet.Services;

/// <summary>Posel na Nadzoru: vrstica iz baze, definicija iz kode, sodba in tisto, iz česar je sodba nastala.</summary>
/// <param name="Code">Definicija iz <see cref="JobCatalog"/>; posli brez nje (testni) se na Nadzoru ne prikažejo.</param>
/// <param name="Sources">Viri tega posla (ops.JobSourceState), po podjetjih.</param>
/// <param name="Pipelines">Postopki tega posla (<see cref="MonitorPolicy.PipelinesOf"/>) za vsa aktivna podjetja.</param>
/// <param name="Alerts">Odprti nepodatkovni alarmi, ki pripadajo poslu (<see cref="MonitorPolicy.BelongsTo"/>).</param>
public sealed record MonitorJob(
  JobDefinitionRow Job, JobDefinition? Code, MonitorVerdict Verdict,
  IReadOnlyList<SourceStateRow> Sources, IReadOnlyList<PipelineHealthRow> Pipelines, IReadOnlyList<MonitorAlertRow> Alerts);

/// <param name="OtherAlerts">Odprti nepodatkovni alarmi, ki jih nobena vrstica posla ne pokaže: ne pripadajo nobenemu
/// poslu (OutboundDead, gostitelj) ali pripadajo samo izklopljenim poslom (izklop je pravilo 1 in bi alarm skril).</param>
/// <param name="Organizations">Aktivna podjetja in ali so v avtomatiki (intranet.GetOrganizationAutomation).</param>
/// <param name="NowUtc">Čas baze (intranet.GetAutomationHost), da se starosti ne zamaknejo za razliko ur strežnikov.</param>
public sealed record MonitorOverview(
  AutomationHostRow? Host, bool HostLive, IReadOnlyList<MonitorJob> Jobs,
  IReadOnlyList<MonitorAlertRow> OtherAlerts, IReadOnlyList<OrganizationAutomationRow> Organizations, DateTime NowUtc);

/// <summary>Faza teka (intranet.GetJobRunPhases, 259).</summary>
/// <param name="JobRunId">Null: faza je vezana na tek samo po času in postopku (gostitelj s starim binarjem ni
/// podal PIM_JOB_RUN_ID); stran jo pripne koraku po času in podjetju in jo označi kot nenatančno vez
/// (*); šele če je ne more pripeti nobenemu koraku, jo pokaže v razdelku »Faze tega teka«.</param>
public sealed record JobRunPhaseRow(
  long JobPhaseRunId, long? JobRunId, int? StepOrder, string? StepName, string PhaseCode,
  int PhaseOrder, int? OrganizationId, string? OrganizationName, string? Pipeline, string? SourceCode, string Status,
  bool HasNewData, DateTime StartedUtc, DateTime? EndedUtc, int? DurationMs, long? ItemsIn, long? ItemsOut,
  long? ItemsRejected, long? ByteCount, string? Message);

/// <summary>Stran posla.</summary>
/// <param name="Runs">Zadnjih 20 tekov posla (brez omejitve dni), najnovejši prvi.</param>
/// <param name="SelectedRun">Zahtevani tek tega posla (?tek=), sicer zadnji; null, kadar posel še ni tekel.</param>
/// <param name="LogTail">Zadnjih ~80 vrstic dnevnika izbranega teka; null, kadar dnevnika ni ali ni v mapi dnevnikov.</param>
/// <param name="DependsOn">Predhodniki (ops.JobDependency, kjer je ta posel odvisen): »Čaka na«.</param>
/// <param name="Triggers">Posli, ki jih uspeh tega posla sproži (TriggersDependent): »Sproži«.</param>
/// <param name="RunPhases">Povzetek faz po tekih zgodovine (samo faze z natančno vezjo JobRunId), da zgodovina
/// uspešen tek brez novih podatkov pokaže sivo, ne zeleno (<see cref="MonitorPolicy.SucceededByPhases"/>).</param>
public sealed record MonitorJobDetail(
  MonitorJob Job, IReadOnlyList<JobRunRow> Runs, JobRunRow? SelectedRun,
  IReadOnlyList<JobStepRunRow> Steps, IReadOnlyList<JobRunPhaseRow> Phases, IReadOnlyList<WorkerLogLine>? LogTail,
  IReadOnlyList<JobDependencyRow> DependsOn, IReadOnlyList<JobDependencyRow> Triggers, IReadOnlyList<ArtifactRow> Artifacts,
  IReadOnlyDictionary<long, PhaseTally> RunPhases);

/// <summary>
/// Dejanje je bilo izvedeno, sled v dnevniku sprememb (ops.LogUserActivity) pa ni zapisana. Stran naj to pokaže
/// kot opozorilo ob uspehu, ne kot neuspeh dejanja — ponovitev bi npr. dvakrat zahtevala zagon.
/// </summary>
public sealed class MonitorTraceException(string message, Exception inner) : Exception(message, inner);

/// <summary>
/// Branje in dejanja za stran Nadzor (/sistem) in stran posla (/sistem/posel/{posel}), blok 5 prenove nadzora.
///
/// Zakaj ena storitev: prej je sedem strani bralo isto stanje po svoje (kartice, opravila, zagoni, postopki,
/// integracije …) in vsaka je imela svoje barve. Tu se vse sestavi enkrat, sodbo o poslu pa izreče
/// <see cref="MonitorPolicy"/> (čista funkcija, test brez baze). Posle in teke bere <see cref="AutomationStore"/>
/// (isti razred kot gostitelj), nove poglede (postopki, alarmi, faze teka) procedure migracije 259.
///
/// Meja je servis, ne stran: vsako dejanje preveri vlogo, preden pokliče bazo (posli, postopki in podjetja
/// v avtomatiki: ADMIN; alarmi: politika AlertWrite, kot doslej na /preverbe), in ob uspehu zapiše sled.
/// </summary>
public sealed class MonitorService(
  IConfiguration configuration, AutomationStore store, WorkerConsoleService logs, PimWriteGuard guard, AdminConsoleService activity)
{
  /// <summary>Koliko vrstic dnevnika pokaže stran posla, preden uporabnik zahteva cel izpis.</summary>
  public const int LogTailLines = 80;

  /// <summary>Koliko zadnjih tekov pokaže zgodovina posla.</summary>
  public const int HistoryRuns = 20;

  // Tek, starejši od zadnjih 20, se poišče med zadnjimi 500 (povezava iz zgodovine ali alarma); dlje nazaj
  // stran pokaže zadnji tek.
  const int RunLookupDepth = 500;

  string ConnectionString => ConnectionStringResolver.Resolve(configuration)
    ?? throw new InvalidOperationException("Povezava PIM ni nastavljena.");

  // ─── Branje ──────────────────────────────────────────────────────────────

  /// <summary>Vsi posli iz kataloga kode v vrstnem redu tokov, s sodbo, gostitelj, druga obvestila in podjetja.</summary>
  public async Task<MonitorOverview> GetOverviewAsync(CancellationToken ct = default)
  {
    // Vsak klic ima svojo povezavo (AutomationStore), zato gredo neodvisna branja hkrati: stran se osveži vsakih 15 s.
    var definitionsTask = store.GetDefinitionsAsync(ct);
    var hostTask = store.GetHostAsync(ct);
    var sourcesTask = GetSourceStatesAsync(null, ct);
    var pipelinesTask = GetPipelinesAsync(ct);
    var alertsTask = GetAlertsAsync(ct);
    var organizationsTask = GetOrganizationsAsync(ct);
    await Task.WhenAll(definitionsTask, hostTask, sourcesTask, pipelinesTask, alertsTask, organizationsTask);

    var host = hostTask.Result;
    var hostLive = host?.IsAutomationHostLive == true;
    var nowUtc = host?.NowUtc ?? DateTime.UtcNow;
    var sources = sourcesTask.Result;
    var pipelines = pipelinesTask.Result;
    var alerts = alertsTask.Result;

    var lane = SaopLaneBusyWith(definitionsTask.Result.Jobs);
    var jobs = Displayed(definitionsTask.Result.Jobs)
      .Select(row => BuildJob(row, sources, pipelines, alerts, hostLive, nowUtc, lane))
      .ToList();
    var otherAlerts = alerts
      .Where(alert => !jobs.Any(job => job.Job.IsEnabled && MonitorPolicy.BelongsTo(alert, job.Job.JobKey)))
      .ToList();

    return new(host, hostLive, jobs, otherAlerts, organizationsTask.Result, nowUtc);
  }

  /// <summary>Stran posla; null, kadar posla ni v katalogu kode ali v bazi.</summary>
  /// <param name="jobRunId">Izbrani tek (?tek=); tek drugega posla ali neznan tek pomeni zadnji tek.</param>
  public async Task<MonitorJobDetail?> GetJobAsync(string jobKey, long? jobRunId, CancellationToken ct = default)
  {
    var code = JobCatalog.Find(jobKey);
    if (code is null) return null;

    var definitionsTask = store.GetDefinitionsAsync(ct);
    var hostTask = store.GetHostAsync(ct);
    var sourcesTask = GetSourceStatesAsync(jobKey, ct);
    var pipelinesTask = GetPipelinesAsync(ct);
    var alertsTask = GetAlertsAsync(ct);
    var runsTask = store.GetRunsAsync(HistoryRuns, jobKey, null, null, ct);
    await Task.WhenAll(definitionsTask, hostTask, sourcesTask, pipelinesTask, alertsTask, runsTask);

    var (definitions, dependencies, artifacts) = definitionsTask.Result;
    var row = definitions.FirstOrDefault(definition => definition.JobKey == jobKey);
    if (row is null) return null;

    var host = hostTask.Result;
    var nowUtc = host?.NowUtc ?? DateTime.UtcNow;
    var job = BuildJob(row, sourcesTask.Result, pipelinesTask.Result, alertsTask.Result, host?.IsAutomationHostLive == true, nowUtc,
      SaopLaneBusyWith(definitions));

    var runs = runsTask.Result;
    JobRunRow? selected = null;
    if (jobRunId is { } requested)
      selected = runs.FirstOrDefault(run => run.JobRunId == requested)
        ?? (await store.GetRunsAsync(RunLookupDepth, jobKey, null, null, ct)).FirstOrDefault(run => run.JobRunId == requested);
    selected ??= runs.FirstOrDefault();

    IReadOnlyList<JobStepRunRow> steps = [];
    IReadOnlyList<JobRunPhaseRow> phases = [];
    var tallyTask = GetRunPhaseTalliesAsync(runs.Select(run => run.JobRunId).ToList(), ct);
    if (selected is not null)
    {
      var stepsTask = store.GetStepsAsync(selected.JobRunId, ct);
      var phasesTask = GetRunPhasesAsync(selected.JobRunId, MonitorPolicy.PipelinesOf(jobKey), ct);
      await Task.WhenAll(stepsTask, phasesTask);
      steps = stepsTask.Result;
      phases = phasesTask.Result;
    }
    var tallies = await tallyTask;

    return new(
      job, runs, selected, steps, phases, ReadRunLog(selected?.LogPath, LogTailLines),
      dependencies.Where(dependency => dependency.JobKey == jobKey).ToList(),
      dependencies.Where(dependency => dependency.DependsOnJobKey == jobKey && dependency.TriggersDependent).ToList(),
      artifacts.Where(artifact => artifact.JobKey == jobKey).OrderByDescending(artifact => artifact.CreatedUtc).ToList(),
      tallies);
  }

  /// <summary>
  /// Dnevnik teka (ops.JobRun.LogPath) z razvrščenimi vrsticami; null, kadar ga ni ali ni v mapi dnevnikov.
  /// <paramref name="tailLines"/> null: cel izpis (do 512 KB, kot ga prebere <see cref="WorkerConsoleService.ReadLog"/>).
  /// </summary>
  public IReadOnlyList<WorkerLogLine>? ReadRunLog(string? logPath, int? tailLines = LogTailLines)
  {
    if (logs.RelativeLogPath(logPath) is not { } relative) return null;
    if (logs.ReadLog(relative) is not { } lines) return null;
    var shown = tailLines is { } take && lines.Count > take ? lines.Skip(lines.Count - take) : lines;
    return shown.Select(line => new WorkerLogLine(line, WorkerLogs.Classify(line))).ToList();
  }

  // ─── Dejanja ─────────────────────────────────────────────────────────────

  /// <summary>Zahteva za zagon; prevzame jo gostitelj ob naslednjem tiku. Posel, ki teče, baza zavrne (52377).</summary>
  public async Task RequestRunAsync(string jobKey, string actor, CancellationToken ct = default)
  {
    await RequireAdminAsync();
    var code = KnownJob(jobKey);
    await store.RequestRunAsync(jobKey, actor, ct);
    await TraceAsync(actor, "JOB_RUN_REQUEST", "Opravilo", $"Zahteva za zagon posla {code.Label} z Nadzora.", jobKey, ct: ct);
  }

  /// <summary>Zahteva za ustavitev teka; gostitelj jo izvede ob naslednjem utripu.</summary>
  public async Task RequestCancelAsync(long jobRunId, string actor, CancellationToken ct = default)
  {
    await RequireAdminAsync();
    await store.RequestCancelAsync(jobRunId, actor, ct);
    var jobKey = await JobKeyOfRunAsync(jobRunId, ct);
    var label = JobCatalog.Find(jobKey)?.Label ?? jobKey;
    await TraceAsync(actor, "JOB_CANCEL_REQUEST", "Opravilo",
      $"Zahteva za ustavitev teka #{jobRunId}{(label is null ? "" : $" ({label})")} z Nadzora.", jobKey, ct: ct);
  }

  /// <summary>Vklop ali izklop posla; urnik in časovna meja ostaneta, kot sta.</summary>
  public async Task SetJobEnabledAsync(string jobKey, bool enabled, string actor, CancellationToken ct = default)
  {
    await RequireAdminAsync();
    var code = KnownJob(jobKey);
    var row = await DefinitionAsync(jobKey, ct);
    var (interval, daily) = CurrentSchedule(row, code);
    await store.SaveScheduleAsync(jobKey, enabled, interval, daily, null, actor, ct);
    await TraceAsync(actor, enabled ? "JOB_ENABLE" : "JOB_DISABLE", "Opravilo",
      $"Posel {row.Label} je {(enabled ? "vklopljen" : "izklopljen")} z Nadzora.", jobKey,
      oldValue: row.IsEnabled ? "vklopljen" : "izklopljen", newValue: enabled ? "vklopljen" : "izklopljen", ct: ct);
  }

  /// <summary>
  /// Urnik posla: razmik v minutah ALI dnevna ura (naša ura), časovna meja v minutah. Null pri razmiku in uri
  /// obdrži obstoječ urnik (npr. samo nova časovna meja); null pri meji obdrži obstoječo mejo. Vklop ostane.
  /// </summary>
  public async Task SaveJobScheduleAsync(
    string jobKey, int? intervalMinutes, TimeOnly? dailyAtLocal, int? timeoutMinutes, string actor, CancellationToken ct = default)
  {
    await RequireAdminAsync();
    if (intervalMinutes is not null && dailyAtLocal is not null)
      throw new ArgumentException("Posel ima bodisi razmik bodisi dnevno uro, ne obojega.");
    if (intervalMinutes is < 1 or > 1440)
      throw new ArgumentOutOfRangeException(nameof(intervalMinutes), intervalMinutes, "Razmik mora biti med 1 in 1440 minutami.");
    if (timeoutMinutes is < 1 or > 1440)
      throw new ArgumentOutOfRangeException(nameof(timeoutMinutes), timeoutMinutes, "Časovna meja mora biti med 1 in 1440 minutami.");

    var code = KnownJob(jobKey);
    var row = await DefinitionAsync(jobKey, ct);
    var (currentInterval, currentDaily) = CurrentSchedule(row, code);
    int? interval = intervalMinutes is { } minutes ? minutes * 60 : dailyAtLocal is null ? currentInterval : null;
    TimeOnly? daily = dailyAtLocal ?? (intervalMinutes is null ? currentDaily : null);
    int? timeout = timeoutMinutes is { } limit ? limit * 60 : null;

    await store.SaveScheduleAsync(jobKey, row.IsEnabled, interval, daily, timeout, actor, ct);
    var before = $"{JobCatalog.FormatSchedule(row.IntervalSeconds, row.DailyAtLocal)}, meja {Math.Max(1, row.TimeoutSeconds / 60)} min";
    var after = $"{JobCatalog.FormatSchedule(interval, daily)}, meja {Math.Max(1, (timeout ?? row.TimeoutSeconds) / 60)} min";
    await TraceAsync(actor, "JOB_SCHEDULE", "Opravilo", $"Urnik posla {row.Label}: {after}.", jobKey, oldValue: before, newValue: after, ct: ct);
  }

  /// <summary>Vklop postopka (ops.ScheduleProfile) za podjetje z obstoječim razmikom; po samodejnem izklopu ali ročnem.</summary>
  public async Task EnablePipelineAsync(string pipeline, int organizationId, string actor, CancellationToken ct = default)
  {
    await RequireAdminAsync();
    var row = (await GetPipelinesAsync(ct)).FirstOrDefault(item => item.Pipeline == pipeline && item.OrganizationId == organizationId)
      ?? throw new InvalidOperationException($"Postopek {pipeline} za podjetje {organizationId} ne obstaja.");

    await using (var connection = await OpenAsync(ct))
    await using (var command = new SqlCommand("intranet.SaveSchedule", connection) { CommandType = CommandType.StoredProcedure })
    {
      command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
      command.Parameters.Add("@Pipeline", SqlDbType.NVarChar, 100).Value = pipeline;
      command.Parameters.Add("@IsEnabled", SqlDbType.Bit).Value = true;
      command.Parameters.Add("@IntervalSeconds", SqlDbType.Int).Value = row.IntervalSeconds;
      command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
      await command.ExecuteNonQueryAsync(ct);
    }

    // Isti zapis sledi kot na nekdanjem pogledu postopkov (odstranjen v bloku 7): ops.ScheduleProfile hrani samo zadnjo spremembo.
    await TraceAsync(actor, "SCHEDULE_ENABLE", "Urnik", $"Postopek {pipeline} za {row.OrganizationName} je vklopljen z Nadzora.",
      pipeline, organizationId, row.IsEnabled ? "vklopljen" : "izklopljen", "vklopljen", ct);
  }

  /// <summary>Vključi ali izključi podjetje iz avtomatike; izključitev zapre tudi njegove odprte alarme in dostave.</summary>
  public async Task SetOrganizationAutomationAsync(int organizationId, bool enabled, string actor, CancellationToken ct = default)
  {
    await RequireAdminAsync();
    var name = (await GetOrganizationsAsync(ct)).FirstOrDefault(item => item.OrganizationId == organizationId)?.Name ?? $"podjetje {organizationId}";

    await using (var connection = await OpenAsync(ct))
    await using (var command = new SqlCommand("intranet.SetOrganizationAutomation", connection) { CommandType = CommandType.StoredProcedure })
    {
      command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
      command.Parameters.Add("@IsEnabled", SqlDbType.Bit).Value = enabled;
      command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
      await command.ExecuteNonQueryAsync(ct);
    }

    await TraceAsync(actor, enabled ? "AUTOMATION_ENABLE" : "AUTOMATION_DISABLE", "Podjetje",
      enabled ? $"Avtomatika za {name} je vključena." : $"Avtomatika za {name} je izključena; posli za podjetje in obvestila so ustavljeni.",
      organizationId.ToString(System.Globalization.CultureInfo.InvariantCulture), organizationId,
      enabled ? "izključena" : "vključena", enabled ? "vključena" : "izključena", ct);
  }

  /// <summary>Potrdi alarm (ostane odprt, a je viden kot potrjen).</summary>
  public Task AcknowledgeAlertAsync(long alertId, string actor, CancellationToken ct = default) =>
    AlertActionAsync("intranet.AcknowledgeAlert", "ALERT_ACK", "potrjen", alertId, actor, ct);

  /// <summary>Razreši alarm; če vzrok ostane, ga gostitelj ali nadzornik ob naslednjem vrednotenju odpre znova.</summary>
  public Task ResolveAlertAsync(long alertId, string actor, CancellationToken ct = default) =>
    AlertActionAsync("intranet.ResolveAlert", "ALERT_RESOLVE", "razrešen", alertId, actor, ct);

  // ─── Sestava ─────────────────────────────────────────────────────────────

  /// <summary>Posli iz kataloga kode v vrstnem redu tokov (JobCatalog.FlowOrder), nato SortOrder.</summary>
  static IEnumerable<JobDefinitionRow> Displayed(IEnumerable<JobDefinitionRow> rows) =>
    rows.Where(row => JobCatalog.Find(row.JobKey) is not null)
      .OrderBy(row => FlowRank(row.Flow)).ThenBy(row => row.SortOrder).ThenBy(row => row.JobKey, StringComparer.Ordinal);

  static int FlowRank(string flow)
  {
    for (var index = 0; index < JobCatalog.FlowOrder.Count; index++)
      if (JobCatalog.FlowOrder[index] == flow) return index;
    return int.MaxValue;
  }

  /// <summary>Posel, ki trenutno zaseda pot do SAOP (teče in kliče SAOP); null, kadar je pot prosta.</summary>
  /// Po koncu posla SAOP gostitelj drži še JobCatalog.SaopQuietSeconds premora; tudi to je čakanje, ne zamuda.
  static string? SaopLaneBusyWith(IReadOnlyList<JobDefinitionRow> jobs) =>
    jobs.FirstOrDefault(job => job.IsRunning && JobCatalog.UsesSaop(job.JobKey))?.Label
    ?? jobs.Where(job => JobCatalog.UsesSaop(job.JobKey) && job.LastEndedUtc is { } ended
                         && ended > DateTime.UtcNow.AddSeconds(-(JobCatalog.SaopQuietSeconds + 60)))
           .Select(job => $"{job.Label} (premor po koncu)").FirstOrDefault();

  static MonitorJob BuildJob(
    JobDefinitionRow row, IReadOnlyList<SourceStateRow> sources, IReadOnlyList<PipelineHealthRow> pipelines,
    IReadOnlyList<MonitorAlertRow> alerts, bool hostLive, DateTime nowUtc, string? saopLaneBusyWith)
  {
    var jobPipelines = MonitorPolicy.PipelinesOf(row.JobKey);
    // Posel, ki sam teče, ne čaka na drugega.
    var lane = saopLaneBusyWith is not null && !row.IsRunning && saopLaneBusyWith != row.Label ? saopLaneBusyWith : null;
    return new(
      row, JobCatalog.Find(row.JobKey), MonitorPolicy.Evaluate(row, sources, pipelines, alerts, hostLive, nowUtc, lane),
      sources.Where(source => source.JobKey == row.JobKey).ToList(),
      pipelines.Where(pipeline => jobPipelines.Contains(pipeline.Pipeline)).ToList(),
      alerts.Where(alert => MonitorPolicy.BelongsTo(alert, row.JobKey)).ToList());
  }

  /// <summary>Urnik, kot ga ima vrstica; posel brez obojega (ne bi smel obstajati) dobi privzetek kode, sicer ga baza zavrne (52373).</summary>
  static (int? Interval, TimeOnly? Daily) CurrentSchedule(JobDefinitionRow row, JobDefinition code)
  {
    if (row.IntervalSeconds is { } interval) return (interval, null);
    if (row.DailyAtLocal is { } daily) return (null, daily);
    return code.IntervalSeconds is { } fallback ? (fallback, null) : (null, code.DailyAtLocal ?? new TimeOnly(0, 30));
  }

  static JobDefinition KnownJob(string jobKey) =>
    JobCatalog.Find(jobKey) ?? throw new InvalidOperationException($"Posel {jobKey} ne obstaja.");

  async Task<JobDefinitionRow> DefinitionAsync(string jobKey, CancellationToken ct) =>
    (await store.GetDefinitionsAsync(ct)).Jobs.FirstOrDefault(row => row.JobKey == jobKey)
      ?? throw new InvalidOperationException($"Posel {jobKey} ne obstaja v bazi; gostitelj ga zapiše ob zagonu.");

  // ─── Varovalka in sled ───────────────────────────────────────────────────

  /// <summary>
  /// Posle, postopke in podjetja v avtomatiki ureja samo skrbnik: strani so [Authorize(Roles = "ADMIN")], a
  /// meja je servis (pregled 2026-09-08, A1/A4) — gumb, ki bi ga kdo ponudil drugje, ne sme obiti vloge.
  /// </summary>
  async Task RequireAdminAsync()
  {
    var user = await guard.CurrentUserAsync();
    if (user?.Identity?.IsAuthenticated != true)
      throw new UnauthorizedAccessException("Za to dejanje je potrebna prijava.");
    if (!user.IsInRole(PimRoles.Admin))
      throw new UnauthorizedAccessException("Posle, postopke in avtomatiko podjetij ureja samo skrbnik (ADMIN).");
  }

  /// <summary>Sled se zapiše samo ob uspešnem dejanju; če pade, dejanje ostane izvedeno (<see cref="MonitorTraceException"/>).</summary>
  async Task TraceAsync(
    string actor, string actionCode, string entityType, string summary, string? entityKey,
    int? organizationId = null, string? oldValue = null, string? newValue = null, CancellationToken ct = default)
  {
    try
    {
      await activity.LogActivityAsync(actor, actionCode, entityType, summary, entityKey, organizationId, oldValue, newValue, ct);
    }
    catch (Exception exception) when (exception is not OperationCanceledException)
    {
      throw new MonitorTraceException("Dejanje je izvedeno, sled v dnevniku sprememb pa ni zapisana.", exception);
    }
  }

  async Task AlertActionAsync(string procedure, string actionCode, string done, long alertId, string actor, CancellationToken ct)
  {
    await guard.RequireAsync(PimPolicies.AlertWrite);
    await using var connection = await OpenAsync(ct);

    // Proceduri zahtevata podjetje alarma (varovalka pred napačnim podjetjem); stran pozna samo številko alarma.
    int organizationId;
    string title;
    await using (var lookup = new SqlCommand("SELECT OrganizationId, Title FROM ops.Alert WHERE AlertId = @AlertId;", connection))
    {
      lookup.Parameters.Add("@AlertId", SqlDbType.BigInt).Value = alertId;
      await using var reader = await lookup.ExecuteReaderAsync(ct);
      if (!await reader.ReadAsync(ct)) throw new InvalidOperationException($"Alarm #{alertId} ne obstaja.");
      organizationId = reader.GetInt32(0);
      title = reader.GetString(1);
    }

    await using (var command = new SqlCommand(procedure, connection) { CommandType = CommandType.StoredProcedure })
    {
      command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
      command.Parameters.Add("@AlertId", SqlDbType.BigInt).Value = alertId;
      command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
      await command.ExecuteNonQueryAsync(ct);
    }

    await TraceAsync(actor, actionCode, "Alarm", $"Alarm #{alertId} je {done} z Nadzora: {title}",
      alertId.ToString(System.Globalization.CultureInfo.InvariantCulture), organizationId, ct: ct);
  }

  // ─── Branje iz baze ──────────────────────────────────────────────────────

  async Task<SqlConnection> OpenAsync(CancellationToken ct)
  {
    var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(ct);
    return connection;
  }

  async Task<IReadOnlyList<SourceStateRow>> GetSourceStatesAsync(string? jobKey, CancellationToken ct)
  {
    await using var connection = await OpenAsync(ct);
    await using var command = new SqlCommand("intranet.GetJobSourceState", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@JobKey", SqlDbType.NVarChar, 60).Value = (object?)jobKey ?? DBNull.Value;
    await using var reader = await command.ExecuteReaderAsync(ct);
    var rows = new List<SourceStateRow>();
    while (await reader.ReadAsync(ct))
      rows.Add(new(
        Text(reader, "JobKey"), Text(reader, "Pipeline"), Text(reader, "SourceCode"), Text(reader, "Label"),
        NullableInt(reader, "OrganizationId"), NullableText(reader, "OrganizationName"), Int(reader, "MaxAgeSeconds"), Bool(reader, "MeasureNewData"),
        NullableDate(reader, "LastContactUtc"), NullableDate(reader, "LastNewDataUtc"), NullableDate(reader, "LastFailureUtc"), NullableDate(reader, "BasisUtc"),
        NullableText(reader, "LastMessage"), NullableText(reader, "LastStatus"), NullableText(reader, "LastPhaseCode"),
        NullableLong(reader, "LastItemsOut"), NullableLong(reader, "LastItemsRejected"), Text(reader, "State")));
    return rows;
  }

  async Task<IReadOnlyList<PipelineHealthRow>> GetPipelinesAsync(CancellationToken ct)
  {
    await using var connection = await OpenAsync(ct);
    await using var command = new SqlCommand("intranet.GetMonitorPipelines", connection) { CommandType = CommandType.StoredProcedure };
    await using var reader = await command.ExecuteReaderAsync(ct);
    var rows = new List<PipelineHealthRow>();
    while (await reader.ReadAsync(ct))
      rows.Add(new(
        Text(reader, "Pipeline"), Int(reader, "OrganizationId"), Text(reader, "OrganizationName"), Bool(reader, "IsEnabled"),
        Bool(reader, "OrganizationInAutomation"), Int(reader, "IntervalSeconds"), NullableText(reader, "HealthStatus"),
        NullableDate(reader, "LastHeartbeatUtc"), NullableDate(reader, "LastSuccessfulRunUtc"), NullableText(reader, "LastError"),
        Int(reader, "ConsecutiveFailures")));
    return rows;
  }

  async Task<IReadOnlyList<MonitorAlertRow>> GetAlertsAsync(CancellationToken ct)
  {
    await using var connection = await OpenAsync(ct);
    await using var command = new SqlCommand("intranet.GetMonitorAlerts", connection) { CommandType = CommandType.StoredProcedure };
    await using var reader = await command.ExecuteReaderAsync(ct);
    var rows = new List<MonitorAlertRow>();
    while (await reader.ReadAsync(ct))
      rows.Add(new(
        Long(reader, "AlertId"), Text(reader, "AlertKind"), Text(reader, "Severity"), NullableText(reader, "Pipeline"),
        Int(reader, "OrganizationId"), Text(reader, "OrganizationName"), Text(reader, "Title"), NullableText(reader, "Summary"),
        Date(reader, "FirstSeenUtc"), Date(reader, "LastSeenUtc"), NullableDate(reader, "AcknowledgedUtc")));
    return rows;
  }

  async Task<IReadOnlyList<OrganizationAutomationRow>> GetOrganizationsAsync(CancellationToken ct)
  {
    await using var connection = await OpenAsync(ct);
    await using var command = new SqlCommand("intranet.GetOrganizationAutomation", connection) { CommandType = CommandType.StoredProcedure };
    await using var reader = await command.ExecuteReaderAsync(ct);
    var rows = new List<OrganizationAutomationRow>();
    while (await reader.ReadAsync(ct))
      rows.Add(new(
        Int(reader, "OrganizationId"), Text(reader, "Name"), Bool(reader, "IsAutomationEnabled"),
        NullableDate(reader, "UpdatedUtc"), NullableText(reader, "UpdatedBy")));
    return rows;
  }

  async Task<IReadOnlyList<JobRunPhaseRow>> GetRunPhasesAsync(long jobRunId, IReadOnlyList<string> pipelines, CancellationToken ct)
  {
    await using var connection = await OpenAsync(ct);
    await using var command = new SqlCommand("intranet.GetJobRunPhases", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@JobRunId", SqlDbType.BigInt).Value = jobRunId;
    command.Parameters.Add("@Pipelines", SqlDbType.NVarChar, -1).Value = pipelines.Count == 0 ? DBNull.Value : (object)string.Join(",", pipelines);
    await using var reader = await command.ExecuteReaderAsync(ct);
    var rows = new List<JobRunPhaseRow>();
    while (await reader.ReadAsync(ct))
      rows.Add(new(
        Long(reader, "JobPhaseRunId"), NullableLong(reader, "JobRunId"), NullableInt(reader, "StepOrder"), NullableText(reader, "StepName"),
        Text(reader, "PhaseCode"), Int(reader, "PhaseOrder"), NullableInt(reader, "OrganizationId"), NullableText(reader, "OrganizationName"),
        NullableText(reader, "Pipeline"), NullableText(reader, "SourceCode"), Text(reader, "Status"), Bool(reader, "HasNewData"),
        Date(reader, "StartedUtc"), NullableDate(reader, "EndedUtc"), NullableInt(reader, "DurationMs"),
        NullableLong(reader, "ItemsIn"), NullableLong(reader, "ItemsOut"), NullableLong(reader, "ItemsRejected"), NullableLong(reader, "ByteCount"),
        NullableText(reader, "Message")));
    return rows;
  }

  async Task<IReadOnlyDictionary<long, PhaseTally>> GetRunPhaseTalliesAsync(IReadOnlyList<long> jobRunIds, CancellationToken ct)
  {
    var tallies = new Dictionary<long, PhaseTally>();
    if (jobRunIds.Count == 0) return tallies;
    await using var connection = await OpenAsync(ct);
    await using var command = new SqlCommand("""
      SELECT phase.JobRunId,
             Total = COUNT(*),
             WithNewData = SUM(CASE WHEN phase.Status = N'Succeeded' AND phase.HasNewData = 1 THEN 1 ELSE 0 END),
             Skipped = SUM(CASE WHEN phase.Status = N'Skipped' THEN 1 ELSE 0 END),
             Failed = SUM(CASE WHEN phase.Status = N'Failed' THEN 1 ELSE 0 END)
      FROM ops.JobPhaseRun phase
      WHERE phase.JobRunId IN (SELECT TRY_CONVERT(bigint, value) FROM STRING_SPLIT(@JobRunIds, N','))
      GROUP BY phase.JobRunId;
      """, connection);
    command.Parameters.Add("@JobRunIds", SqlDbType.NVarChar, -1).Value =
      string.Join(",", jobRunIds.Select(id => id.ToString(System.Globalization.CultureInfo.InvariantCulture)));
    await using var reader = await command.ExecuteReaderAsync(ct);
    while (await reader.ReadAsync(ct))
      tallies[Long(reader, "JobRunId")] = new(Int(reader, "Total"), Int(reader, "WithNewData"), Int(reader, "Skipped"), Int(reader, "Failed"));
    return tallies;
  }

  async Task<string?> JobKeyOfRunAsync(long jobRunId, CancellationToken ct)
  {
    await using var connection = await OpenAsync(ct);
    await using var command = new SqlCommand("SELECT JobKey FROM ops.JobRun WHERE JobRunId = @JobRunId;", connection);
    command.Parameters.Add("@JobRunId", SqlDbType.BigInt).Value = jobRunId;
    return await command.ExecuteScalarAsync(ct) as string;
  }

  static string Text(SqlDataReader reader, string column) => reader.GetString(reader.GetOrdinal(column));
  static string? NullableText(SqlDataReader reader, string column)
  {
    var ordinal = reader.GetOrdinal(column);
    return reader.IsDBNull(ordinal) ? null : reader.GetString(ordinal);
  }
  static int Int(SqlDataReader reader, string column) => Convert.ToInt32(reader.GetValue(reader.GetOrdinal(column)));
  static int? NullableInt(SqlDataReader reader, string column)
  {
    var ordinal = reader.GetOrdinal(column);
    return reader.IsDBNull(ordinal) ? null : Convert.ToInt32(reader.GetValue(ordinal));
  }
  static long Long(SqlDataReader reader, string column) => Convert.ToInt64(reader.GetValue(reader.GetOrdinal(column)));
  static long? NullableLong(SqlDataReader reader, string column)
  {
    var ordinal = reader.GetOrdinal(column);
    return reader.IsDBNull(ordinal) ? null : Convert.ToInt64(reader.GetValue(ordinal));
  }
  static bool Bool(SqlDataReader reader, string column) => Convert.ToBoolean(reader.GetValue(reader.GetOrdinal(column)));
  static DateTime Date(SqlDataReader reader, string column) => reader.GetDateTime(reader.GetOrdinal(column));
  static DateTime? NullableDate(SqlDataReader reader, string column)
  {
    var ordinal = reader.GetOrdinal(column);
    return reader.IsDBNull(ordinal) ? null : reader.GetDateTime(ordinal);
  }
}
