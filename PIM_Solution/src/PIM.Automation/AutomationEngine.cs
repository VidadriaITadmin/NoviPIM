using System.Diagnostics;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace PIM.Automation;

/// <param name="AllowedJobs">Samo ti posli smejo teči (preizkus, --posli); null pomeni vsi.</param>
/// <param name="MonitorOnly">Najem, čiščenje visečih zagonov in alarmi tečejo, posli pa ne (--samo-nadzor).</param>
/// <param name="RunOnceJob">Posel za en sam zagon (--enkrat): prevzame se takoj (ne čaka na termin, spoštuje vrata), nato se motor ustavi.</param>
public sealed record AutomationOptions(
  string Application, TimeZoneInfo Zone, string LogRoot,
  int TickSeconds = 15, int LeaseSeconds = 90, int MaxConcurrentJobs = 3, int StaleMinutes = 10, int MaxParallel = 4,
  IReadOnlySet<string>? AllowedJobs = null, bool MonitorOnly = false, string? RunOnceJob = null);

public sealed record RunningJob(string JobKey, long JobRunId, DateTime StartedUtc, string LogPath);

/// <param name="Notes">Zadnje opombe (gradnja, prevzem najema, mapa dnevnikov), najnovejša zadnja.</param>
public sealed record EngineStatus(
  bool IsOwner, SchedulerLeaseInfo? Lease, DateTime? StartedUtc, DateTime? LastTickUtc, long Ticks, string? LastError, DateTime? LastErrorUtc,
  IReadOnlyList<RunningJob> Running, IReadOnlyList<string> Notes, bool Finished, int? RunOnceExitCode);

/// <summary>
/// Motor razporejanja (ena instanca na proces gostitelja). Vsakih nekaj sekund obnovi najem v
/// ops.SchedulerLease s prednostjo gostitelja; kdor ga drži, pospravi viseče zagone, oceni alarme in
/// požene posle, ki so na vrsti (ops.ClaimJobRun — edina vrata, zato isti posel nikoli ne teče dvakrat,
/// tudi če gostitelj teče na dveh mestih). Drugi gostitelj nad isto bazo samo čaka.
///
/// Motor ne ve za IIS, Windows storitev ali konzolo: gostitelj mu da nastavitve, dnevnik in žeton
/// ustavitve. Zato ga lahko požene tudi test.
/// </summary>
public sealed class AutomationEngine(
  AutomationStore store, WorkerConsoleSetup setup, AutomationOptions options,
  Action<string> log, Action<string, Exception?> warn)
{
  readonly object gate = new();
  readonly List<string> notes = [];
  readonly Dictionary<string, RunningJob> running = new(StringComparer.Ordinal);
  readonly Dictionary<long, (CancellationTokenSource Cancel, Task Task)> tasks = [];
  readonly string hostName = Environment.MachineName;
  EngineStatus status = new(false, null, null, null, 0, null, null, [], [], false, null);
  bool wasOwner;
  bool runOnceStarted;
  int ticksSinceAlerts;
  DateTime? lastRequestScan;
  DateTime? lastSaopEndUtc;
  DateTime? lastPruneUtc;
  volatile bool shuttingDown;

  public string Owner { get; } = WorkerCycles.OwnerName(Environment.MachineName, Environment.ProcessId, options.Application);

  public EngineStatus Status
  {
    get { lock (gate) return status with { Running = running.Values.OrderBy(job => job.StartedUtc).ToList(), Notes = notes.ToList() }; }
  }

  /// <summary>Glavna zanka: teče, dokler gostitelj ne zahteva ustavitve (ali dokler --enkrat ne konča).</summary>
  public async Task RunAsync(CancellationToken stopping)
  {
    lock (gate) status = status with { StartedUtc = DateTime.UtcNow };
    log($"Gostitelj {Owner}: postavitev na voljo={setup.Available} {setup.Reason ?? ""}; koren={setup.RepositoryRoot}; rešitev={setup.SolutionRoot}; objavljeni workerji={setup.PublishedWorkersRoot ?? "-"}; dnevniki={options.LogRoot}");
    if (options.AllowedJobs is { } allowed) Note($"Dovoljeni posli: {string.Join(", ", allowed)}.");
    if (options.MonitorOnly) Note("Samo nadzor: posli se ne poganjajo.");

    if (setup.Available && options.RunOnceJob is null)
    {
      var built = await AutomationEnvironment.BuildWorkersIfSourceAsync(setup, log, stopping);
      if (built is not null) Note(built);
    }

    try { await store.EnsureDefinitionsAsync(JobCatalog.All, stopping); }
    catch (OperationCanceledException) { return; }
    catch (Exception exception) { Fail("Poslov ni bilo mogoče uskladiti z bazo: " + exception.Message); warn("EnsureDefinitions", exception); }

    PruneLogs();

    using var timer = new PeriodicTimer(TimeSpan.FromSeconds(Math.Clamp(options.TickSeconds, 5, 300)));
    do
    {
      try { await TickAsync(stopping); }
      catch (OperationCanceledException) when (stopping.IsCancellationRequested) { break; }
      catch (Exception exception)
      {
        warn("Tik gostitelja je padel.", exception);
        Fail(exception.Message);
      }
      if (Status.Finished) break;
    }
    while (await WaitAsync(timer, stopping));

    await ShutdownAsync();
  }

  static async Task<bool> WaitAsync(PeriodicTimer timer, CancellationToken token)
  {
    try { return await timer.WaitForNextTickAsync(token); }
    catch (OperationCanceledException) { return false; }
  }

  async Task TickAsync(CancellationToken stopping)
  {
    var lease = await store.AcquireLeaseAsync(Owner, hostName, Environment.ProcessId, options.Application,
      Math.Clamp(options.LeaseSeconds, 30, 600), canRunCycles: false, AutomationApplications.HostPriority, stopping);
    var isOwner = lease?.IsOwner == true;
    lock (gate) status = status with { Lease = lease, IsOwner = isOwner, LastTickUtc = DateTime.UtcNow, Ticks = status.Ticks + 1, LastError = null };

    if (!isOwner)
    {
      if (wasOwner) log($"Najem je prevzel {lease?.Owner}; ta gostitelj čaka.");
      wasOwner = false;
      return;
    }

    if (!wasOwner)
    {
      wasOwner = true;
      // Nič od prejšnjega procesa tega gostitelja ne teče več; zagoni brez utripa so mrtvi ne glede na gostitelja.
      var closed = await store.AbandonStaleAsync(Owner, options.StaleMinutes, hostName, stopping);
      var legacy = 0;
      try { legacy = await store.AbandonLegacyCycleRunsAsync(Owner, stopping); }
      catch (Exception exception) { warn("Visečih zagonov starih ciklov ni bilo mogoče zapreti.", exception); }
      Note($"Najem prevzet. Zaprtih visečih zagonov: {closed} (posli), {legacy} (stari cikli).");
      log($"Gostitelj {Owner} drži najem.");
    }
    else
    {
      var closed = await store.AbandonStaleAsync(Owner, options.StaleMinutes, null, stopping);
      if (closed > 0) Note($"Zaprtih {closed} zagon(ov) brez utripa (Abandoned).");
    }

    if (++ticksSinceAlerts * options.TickSeconds >= 60 || ticksSinceAlerts == 1)
    {
      ticksSinceAlerts = ticksSinceAlerts == 1 ? 1 : 0;
      try { await store.EvaluateAlertsAsync(Owner, stopping); }
      catch (Exception exception) { warn("Ocena alarmov ni uspela.", exception); }
    }

    if (lastPruneUtc is null || DateTime.UtcNow - lastPruneUtc > TimeSpan.FromHours(6)) PruneLogs();

    if (options.MonitorOnly) return;
    if (!setup.Available)
    {
      Note("Poslov ni mogoče pognati: " + setup.Reason);
      return;
    }

    var (jobs, dependencies, _) = await store.GetDefinitionsAsync(stopping);
    var now = DateTime.UtcNow;
    var stagger = 0;
    lastRequestScan = now;

    foreach (var job in jobs)
    {
      if (stopping.IsCancellationRequested) return;
      if (options.RunOnceJob is { } once && job.JobKey != once) continue;
      // --enkrat pomeni en poskus prevzema; brez tega bi se posel po koncu ob vsakem tiku prevzel znova.
      if (options.RunOnceJob == job.JobKey && runOnceStarted) continue;
      if (options.AllowedJobs is { } allowed && !allowed.Contains(job.JobKey)) continue;
      // Vrstica brez kode (star ali testni posel): gostitelj je ne poganja in to pove enkrat, ne vsak tik.
      if (JobCatalog.Find(job.JobKey) is null) { Note($"Posel {job.JobKey} v katalogu kode ne obstaja; preskočen."); continue; }
      if (job.IsRunning) continue;
      lock (gate) if (running.ContainsKey(job.JobKey)) continue;

      var force = options.RunOnceJob == job.JobKey;
      if (!force && !job.IsRequested)
      {
        if (!job.IsEnabled) continue;
        if (job.NextDueUtc is null)
        {
          await store.SetNextDueAsync(job.JobKey, JobCatalog.InitialDue(job, stagger++, now, options.Zone), onlyIfNull: true, stopping);
          continue;
        }
        if (job.NextDueUtc > now) continue;
      }

      // Predhodnik po celi verigi, ki ravno teče (validacija med objavo, objava med izvozom): počakamo na
      // naslednji tik. ops.ClaimJobRun čaka samo na neposrednega predhodnika; izvoz kataloga (65 s branja
      // 90.000 vrstic) ne sme teči vzporedno z validacijo istega podjetja.
      if (AutomationOverview.Upstream(job.JobKey, jobs, dependencies).FirstOrDefault(upstream => upstream.IsRunning) is { } busy)
      {
        if (job.IsRequested || force) Note($"{job.Label} čaka: predhodnik {busy.Label} ravno teče.");
        continue;
      }

      // Pas SAOP (ekipa SAOP 2026-09-22): posel, ki kliče SAOP, nikoli ne teče hkrati z drugim takim in
      // začne šele po tišini od konca zadnjega. Velja tudi za ročne zahteve in --enkrat.
      if (JobCatalog.UsesSaop(job.JobKey))
      {
        string? saopBusy;
        lock (gate) saopBusy = running.Keys.FirstOrDefault(JobCatalog.UsesSaop);
        saopBusy ??= jobs.FirstOrDefault(other => other.IsRunning && JobCatalog.UsesSaop(other.JobKey))?.JobKey;
        if (saopBusy is not null)
        {
          if (job.IsRequested || force) Note($"{job.Label} čaka: SAOP ravno uporablja {saopBusy}.");
          continue;
        }
        if (LastSaopEnd(jobs)?.AddSeconds(JobCatalog.SaopQuietSeconds) is { } quietUntil && quietUntil > now)
        {
          if (job.IsRequested || force) Note($"{job.Label} čaka na tišino SAOP do {Local(quietUntil)}.");
          continue;
        }
      }

      int active;
      lock (gate) active = running.Count;
      // continue, ne return: posel za mejo ne sme zapreti poti tistim za njim (nadzor in alarmi so zadnji).
      if (active >= Math.Max(1, options.MaxConcurrentJobs)) { Note($"Meja hkratnih poslov ({options.MaxConcurrentJobs}) je dosežena; {job.Label} počaka."); continue; }

      await StartJobAsync(job, force, stopping);
    }

    if (options.RunOnceJob is { } onceKey)
    {
      bool stillRunning;
      lock (gate) stillRunning = running.ContainsKey(onceKey);
      if (!stillRunning && Status.RunOnceExitCode is not null)
        lock (gate) status = status with { Finished = true };
    }
  }

  async Task StartJobAsync(JobDefinitionRow job, bool force, CancellationToken stopping)
  {
    if (options.RunOnceJob == job.JobKey) runOnceStarted = true;
    CycleEnvironment environment;
    try { environment = await AutomationEnvironment.BuildAsync(store, setup, options.Zone, options.MaxParallel, warn, stopping); }
    catch (Exception exception) { warn($"Okolja za {job.JobKey} ni mogoče sestaviti.", exception); Fail(exception.Message); return; }

    var nextDue = WorkerCycles.NextDue(job.IntervalSeconds, job.DailyAtLocal, DateTime.UtcNow, options.Zone);
    var startedLocal = TimeZoneInfo.ConvertTimeFromUtc(DateTime.UtcNow, options.Zone);
    var logPath = AutomationEnvironment.JobLogPath(options.LogRoot, job.JobKey, startedLocal);

    var claim = await store.ClaimAsync(job.JobKey, nextDue, Owner, hostName, Owner, logPath, force, stopping);
    if (!claim.Claimed)
    {
      if (claim.Reason.StartsWith("Blocked:", StringComparison.Ordinal))
        log($"{job.Label}: blokiran (predhodnik {claim.Reason["Blocked:".Length..]}); zapisano v ops.JobRun.");
      else if (claim.Reason.StartsWith("WaitingOn:", StringComparison.Ordinal))
        log($"{job.Label}: čaka na predhodnika {claim.Reason["WaitingOn:".Length..]}, ki ravno teče.");
      else
        log($"{job.Label}: ni bil pognan ({claim.Reason}).");
      if (options.RunOnceJob == job.JobKey)
        lock (gate) status = status with { RunOnceExitCode = claim.Reason.StartsWith("Blocked:", StringComparison.Ordinal) ? 3 : 4, Finished = true };
      return;
    }

    var runId = claim.JobRunId!.Value;
    var triggeredBy = claim.TriggeredBy ?? "Scheduler";
    var cancel = CancellationTokenSource.CreateLinkedTokenSource(stopping);
    var entry = new RunningJob(job.JobKey, runId, DateTime.UtcNow, logPath);
    lock (gate) running[job.JobKey] = entry;
    log($"{job.Label} ({triggeredBy}) je na vrsti; zagon #{runId}, dnevnik {logPath}.");

    var task = Task.Run(() => ExecuteAsync(job, runId, triggeredBy, environment, logPath, cancel.Token), CancellationToken.None);
    lock (gate) tasks[runId] = (cancel, task);
  }

  async Task ExecuteAsync(JobDefinitionRow job, long runId, string triggeredBy, CycleEnvironment environment, string logPath, CancellationToken cancellation)
  {
    var writerGate = new object();
    StreamWriter? writer = null;
    try
    {
      writer = new StreamWriter(new FileStream(logPath, FileMode.CreateNew, FileAccess.Write, FileShare.Read), new UTF8Encoding(false)) { AutoFlush = true };
    }
    catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
    {
      warn($"Dnevnika zagona {logPath} ni mogoče odpreti.", exception);
    }

    void Write(string text)
    {
      var line = WorkerLogs.Stamp(text, TimeZoneInfo.ConvertTimeFromUtc(DateTime.UtcNow, options.Zone));
      if (writer is not null) lock (writerGate) writer.WriteLine(line);
    }

    Process? current = null;
    var startedUtc = DateTime.UtcNow;
    JobRunOutcome outcome;
    try
    {
      Write($"{WorkerLogs.HeaderPrefix}{job.Label} | posel {job.JobKey} | sprožil: {triggeredBy} | gostitelj {Owner} | "
        + TimeZoneInfo.ConvertTimeFromUtc(startedUtc, options.Zone).ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture)
        + (writer is null ? " | OPOZORILO: dnevnik na disku ni zapisan" : ""));
      Write($"Podjetja: {string.Join(", ", environment.Organizations)} · prevzem: {environment.LandingRoot} · izvoz: {environment.ExportRoot ?? "ob korenu (register EXPORT_ROOT ni nastavljen)"} · "
        + (setup.PublishedWorkersRoot is { } published ? $"objavljeni workerji: {published}" : $"izvorna koda: {setup.SolutionRoot}")
        + $" · časovna meja: {job.TimeoutSeconds} s");

      if (environment.Organizations.Count == 0 && job.Flow != JobFlows.System)
      {
        Write("PRESKOČENO: nobeno aktivno podjetje ni vključeno v avtomatiko.");
        outcome = new(JobRunStatus.Warning, 0, 0, 0, 0, 0, "Preskočeno: vsa podjetja so izključena iz avtomatike.");
      }
      else if (job.JobKey == JobCatalog.NightlyReconciliation && await NightlyBlockedByLiveIngestAsync(Write, cancellation))
      {
        outcome = new(JobRunStatus.Warning, 0, 0, 0, 0, 0, "Preskočeno: živ zajem še teče (utrip mlajši od 15 minut).");
      }
      else
      {
        var groups = JobCatalog.Plan(job.JobKey, environment);
        var runner = new JobRunner(store, warn);
        outcome = await runner.RunAsync(job, runId, groups, AutomationEnvironment.ChildEnvironment(triggeredBy, store.ConnectionString), Write,
          process => current = process, cancellation);

        if (job.JobKey == JobCatalog.NightlyReconciliation)
          await WriteNightlySummaryAsync(Write, cancellation);
        if (JobRunStatus.IsSuccess(outcome.Status))
          await RegisterArtifactsAsync(job, runId, environment, Write, cancellation);
      }
    }
    catch (Exception exception)
    {
      warn($"Zagon {job.JobKey} #{runId} je padel v gostitelju.", exception);
      Write($"NAPAKA: zagon je padel v gostitelju: {exception.Message}");
      outcome = new(JobRunStatus.Failed, 1, 0, 0, 0, 1, $"Padel v gostitelju: {exception.Message}");
    }
    finally
    {
      try { current?.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
    }

    Write(WorkerLogs.Footer(outcome.ExitCode, DateTime.UtcNow - startedUtc, outcome.Status == JobRunStatus.Cancelled));
    if (writer is not null) lock (writerGate) writer.Dispose();

    try { await store.CompleteAsync(runId, outcome, Owner, CancellationToken.None); }
    catch (Exception exception) { warn($"Zagona {runId} ni bilo mogoče zaključiti v bazi.", exception); }

    // Konec SAOP posla zabeležimo, PREDEN posel izgine iz seznama tekočih: sicer bi ga tik, ki je vrstice
    // prebral pred koncem, videl kot prost pas brez tišine.
    if (JobCatalog.UsesSaop(job.JobKey)) lock (gate) lastSaopEndUtc = DateTime.UtcNow;
    await ScheduleNextAsync(job, outcome);

    log($"{job.Label} #{runId}: {outcome.Status} — {outcome.Summary}");
    lock (gate)
    {
      running.Remove(job.JobKey);
      if (tasks.Remove(runId, out var entry)) entry.Cancel.Dispose();
      if (options.RunOnceJob == job.JobKey) status = status with { RunOnceExitCode = outcome.Status == JobRunStatus.Succeeded ? 0 : 1 };
    }
  }

  /// <summary>
  /// Naslednji termin šteje od KONCA teka (prej od začetka: posel, daljši od razmika, je tekel brez
  /// premora), po zaporednih napakah pa z odlogom (JobCatalog.NextAfterEnd). Ustavitev ga ne premakne.
  /// </summary>
  async Task ScheduleNextAsync(JobDefinitionRow job, JobRunOutcome outcome)
  {
    // Ustavitev ob izklopu gostitelja termina ne premakne (posel se po ponovnem zagonu nadaljuje);
    // ročna ustavitev ga premakne na konec + razmik, sicer bi se posel po tišini SAOP takoj znova začel.
    if (outcome.Status == JobRunStatus.Cancelled && shuttingDown) return;
    try
    {
      var failures = outcome.Status is JobRunStatus.Failed or JobRunStatus.TimedOut
        ? await store.CountConsecutiveFailuresAsync(job.JobKey, CancellationToken.None)
        : 0;
      var next = JobCatalog.NextAfterEnd(job.IntervalSeconds, job.DailyAtLocal, DateTime.UtcNow, options.Zone, failures);
      await store.SetNextDueAsync(job.JobKey, next, onlyIfNull: false, CancellationToken.None);
      if (failures > 1) log($"{job.Label}: {failures}. zaporedna napaka; naslednji poskus ob {Local(next)}.");
    }
    catch (Exception exception) { warn($"Naslednjega termina za {job.JobKey} ni bilo mogoče zapisati.", exception); }
  }

  DateTime? LastSaopEnd(IReadOnlyList<JobDefinitionRow> jobs)
  {
    DateTime? fromRows = jobs.Where(row => JobCatalog.UsesSaop(row.JobKey) && row.LastEndedUtc is not null).Select(row => row.LastEndedUtc).Max();
    DateTime? inMemory;
    lock (gate) inMemory = lastSaopEndUtc;
    return fromRows is null ? inMemory : inMemory is null ? fromRows : (fromRows > inMemory ? fromRows : inMemory);
  }

  string Local(DateTime utc) =>
    TimeZoneInfo.ConvertTimeFromUtc(DateTime.SpecifyKind(utc, DateTimeKind.Utc), options.Zone).ToString("HH:mm:ss", CultureInfo.InvariantCulture);

  void PruneLogs()
  {
    lastPruneUtc = DateTime.UtcNow;
    var removed = AutomationEnvironment.PruneLogs(options.LogRoot, AutomationEnvironment.LogRetentionDays, warn);
    if (removed > 0) log($"Hramba dnevnikov: izbrisanih {removed} datotek, starejših od {AutomationEnvironment.LogRetentionDays} dni.");
  }

  async Task<bool> NightlyBlockedByLiveIngestAsync(Action<string> write, CancellationToken cancellation)
  {
    try
    {
      var (live, orphans) = await store.CountIngestRunsAsync(6, cancellation);
      if (live > 0)
      {
        write($"PRESKOČENO: {live} živ zajem(ov) še teče (utrip mlajši od 15 minut). Nocojšnja uskladitev se ne začne.");
        return true;
      }
      if (orphans > 0)
        write($"OPOZORILO: v ops.PipelineRun je {orphans} zagon(ov) v stanju Running brez konca, starejših od ure. Ne blokirajo, so pa rep prejšnjih padcev.");
    }
    catch (Exception exception) { warn("Varovalke nočne uskladitve ni bilo mogoče preveriti.", exception); }
    return false;
  }

  async Task WriteNightlySummaryAsync(Action<string> write, CancellationToken cancellation)
  {
    try
    {
      var (pending, quarantined) = await store.RawInboxCountsAsync(cancellation);
      write($"POVZETEK raw.Inbox: Pending {pending}, Quarantined {quarantined}.");
      if (pending > 0) write("   OPOZORILO: nekaj strani je ostalo nepreslikanih. Poglej raw.Inbox.FailureReason.");
    }
    catch (Exception exception) { write($"OPOZORILO: povzetka raw.Inbox ni mogoče prebrati: {exception.Message}"); }
  }

  /// <summary>Datoteke, ki jih je posel pustil: velikost, vrstice in SHA-256 gredo v ops.Artifact — »splet uporablja verzijo N«.</summary>
  async Task RegisterArtifactsAsync(JobDefinitionRow job, long runId, CycleEnvironment environment, Action<string> write, CancellationToken cancellation)
  {
    foreach (var (kind, organizationId, path) in JobCatalog.ArtifactLocations(job.JobKey, environment))
    {
      try
      {
        if (!File.Exists(path)) { write($"   OPOZORILO: pričakovana datoteka {path} ne obstaja; artefakt ni zapisan."); continue; }
        var info = new FileInfo(path);
        var (hash, rows) = await HashAndCountAsync(path, cancellation);
        var (artifactId, isNew) = await store.RegisterArtifactAsync(runId, job.JobKey, organizationId, kind, path, info.Length, rows, hash, info.LastWriteTimeUtc, cancellation);
        write(isNew
          ? $"   Artefakt #{artifactId} {kind} (podjetje {organizationId}): {info.Name}, {info.Length:N0} B, {rows:N0} vrstic, SHA-256 {hash[..12]}…"
          : $"   Artefakt {kind} (podjetje {organizationId}): {info.Name} je nespremenjen (isti hash kot zadnjič).");
        await store.SetCheckpointAsync(kind, organizationId, job.JobKey, runId, $"{info.Name}: {rows:N0} vrstic, {info.Length:N0} B", cancellation);
      }
      catch (Exception exception) { warn($"Artefakta {kind} ({path}) ni bilo mogoče zapisati.", exception); write($"   OPOZORILO: artefakta {kind} ni bilo mogoče zapisati: {exception.Message}"); }
    }
  }

  static async Task<(string Sha256, long Rows)> HashAndCountAsync(string path, CancellationToken cancellation)
  {
    using var sha = SHA256.Create();
    await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1 << 16, useAsync: true);
    var buffer = new byte[1 << 16];
    long lines = 0;
    var lastByte = (byte)'\n';
    int read;
    while ((read = await stream.ReadAsync(buffer, cancellation)) > 0)
    {
      sha.TransformBlock(buffer, 0, read, null, 0);
      for (var index = 0; index < read; index++) if (buffer[index] == (byte)'\n') lines++;
      lastByte = buffer[read - 1];
    }
    sha.TransformFinalBlock([], 0, 0);
    if (lastByte != (byte)'\n' && stream.Length > 0) lines++;
    // Prva vrstica je glava; vrstic podatkov je ena manj.
    return (Convert.ToHexString(sha.Hash!).ToLowerInvariant(), Math.Max(0, lines - 1));
  }

  /// <summary>Ob ustavitvi gostitelja: tekoči posli se ustavijo (drevo procesov), zagoni dobijo Cancelled, najem se sprosti.</summary>
  async Task ShutdownAsync()
  {
    shuttingDown = true;
    List<(CancellationTokenSource Cancel, Task Task)> pending;
    lock (gate) pending = tasks.Values.ToList();
    foreach (var (cancel, _) in pending) { try { cancel.Cancel(); } catch (ObjectDisposedException) { } }
    if (pending.Count > 0)
    {
      log($"Ustavljam {pending.Count} tekočih poslov …");
      await Task.WhenAny(Task.WhenAll(pending.Select(p => p.Task)), Task.Delay(TimeSpan.FromSeconds(20)));
    }
    if (wasOwner)
    {
      try { await store.ReleaseLeaseAsync(Owner, CancellationToken.None); log("Najem sproščen."); }
      catch (Exception exception) { warn("Najema ni bilo mogoče sprostiti.", exception); }
    }
  }

  bool Note(string text)
  {
    lock (gate)
    {
      var added = notes.Count == 0 || notes[^1] != text;
      if (added)
      {
        notes.Add(text);
        if (notes.Count > 20) notes.RemoveAt(0);
        log(text);
      }
      return added;
    }
  }

  void Fail(string message)
  {
    lock (gate) status = status with { LastError = message, LastErrorUtc = DateTime.UtcNow };
  }
}
