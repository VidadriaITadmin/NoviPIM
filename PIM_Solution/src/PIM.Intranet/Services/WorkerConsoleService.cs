using System.Diagnostics;
using System.Globalization;
using System.Text;
using PIM.Operations;

namespace PIM.Intranet.Services;

public enum WorkerRunStatus { Running, Succeeded, Failed, Cancelled }

public sealed record WorkerLogLine(string Text, LogLineTone Tone);

/// <param name="Registered">null, kadar se tega ne da ugotoviti (npr. ni Windows).</param>
public sealed record ScheduledTaskState(
  string Name, bool? Registered, string? NextRun, string? Status, string? LogPrefix, string? JobKey);

/// <summary>En zagon (worker ali cikel): izpis v pomnilniku za stran in ista vsebina v datoteki za pozneje.</summary>
public sealed class WorkerRun
{
  const int MaxLines = 4000;
  readonly object gate = new();
  readonly List<WorkerLogLine> lines = [];

  internal WorkerRun(WorkerJob job, IReadOnlyList<WorkerLaunchStep> steps, string organizationsLabel, string startedBy, string logPath, bool scheduled)
  {
    Job = job;
    Steps = steps;
    OrganizationsLabel = organizationsLabel;
    StartedBy = startedBy;
    LogPath = logPath;
    Scheduled = scheduled;
  }

  public Guid Id { get; } = Guid.NewGuid();
  public WorkerJob Job { get; }
  public IReadOnlyList<WorkerLaunchStep> Steps { get; }
  public string OrganizationsLabel { get; }
  public string StartedBy { get; }
  public string LogPath { get; }
  /// <summary>Pognal ga je razporejevalnik (in ne človek s strani).</summary>
  public bool Scheduled { get; }
  public DateTime StartedUtc { get; } = DateTime.UtcNow;
  public DateTime? EndedUtc { get; internal set; }
  public int? ExitCode { get; internal set; }
  public string? CurrentStep { get; internal set; }
  public string? CancelledBy { get; internal set; }
  public int ErrorLines { get; private set; }
  /// <summary>Vrstica v ops.WorkerCycleRun (samo cikli).</summary>
  public long? CycleRunId { get; internal set; }
  /// <summary>Izid cikla, kot ga je vrnil izvajalec (samo cikli, po koncu).</summary>
  public CycleOutcome? CycleSummary { get; internal set; }
  /// <summary>Napaka, ki je zagon podrla v intranetu (pred prvim korakom ali med njimi); gre tudi v ops.WorkerCycleRun.Summary.</summary>
  public string? Failure { get; internal set; }

  public string? CycleKey => Job.Kind == WorkerJobKind.Cycle ? Job.Target : null;
  public string TriggeredBy => Scheduled ? "Scheduler" : "Human";

  internal Process? CurrentProcess { get; set; }
  internal CancellationTokenSource Cancellation { get; } = new();

  public WorkerRunStatus Status =>
    EndedUtc is null ? WorkerRunStatus.Running
    : CancelledBy is not null ? WorkerRunStatus.Cancelled
    : ExitCode == 0 ? WorkerRunStatus.Succeeded
    : WorkerRunStatus.Failed;

  public TimeSpan Elapsed => (EndedUtc ?? DateTime.UtcNow) - StartedUtc;

  internal void Append(string text)
  {
    var line = new WorkerLogLine(text, WorkerLogs.Classify(text));
    lock (gate)
    {
      // Stran pokaže konec; celoten izpis je v datoteki. Brez meje bi en zgovoren nočni tok
      // v pomnilniku intraneta zrasel brez konca.
      if (lines.Count >= MaxLines) lines.RemoveRange(0, MaxLines / 8);
      lines.Add(line);
      if (line.Tone == LogLineTone.Error) ErrorLines++;
    }
  }

  public IReadOnlyList<WorkerLogLine> Snapshot(bool onlyProblems, int take)
  {
    lock (gate)
    {
      IEnumerable<WorkerLogLine> selected = onlyProblems
        ? lines.Where(line => line.Tone is LogLineTone.Error or LogLineTone.Warning or LogLineTone.Header)
        : lines;
      var list = selected.ToList();
      return list.Count <= take ? list : list.GetRange(list.Count - take, take);
    }
  }
}

/// <summary>Zagon procesa z izpisom v živo; skupen ročnemu zagonu workerja in korakom cikla.</summary>
public static class WorkerProcess
{
  /// <param name="environment">Spremenljivke otroka poleg podedovanih; gostiteljeve (VS, IIS) se odstranijo.</param>
  /// <param name="onProcess">Kdo drži proces, da ga ustavitev lahko ubije; ob koncu dobi null.</param>
  public static async Task<int> RunAsync(
    WorkerLaunchStep step, IReadOnlyDictionary<string, string> environment, Action<string> write,
    Action<Process?> onProcess, CancellationToken cancellationToken)
  {
    var info = new ProcessStartInfo(step.FileName)
    {
      WorkingDirectory = step.WorkingDirectory,
      UseShellExecute = false,
      RedirectStandardOutput = true,
      RedirectStandardError = true,
      RedirectStandardInput = true,
      CreateNoWindow = true,
    };
    foreach (var argument in step.Arguments) info.ArgumentList.Add(argument);

    foreach (var name in info.Environment.Keys.Where(WorkerJobs.IsInheritedHostVariable).ToList())
      info.Environment.Remove(name);
    foreach (var (name, value) in environment) info.Environment[name] = value;

    using var process = new Process { StartInfo = info };
    process.Start();
    process.StandardInput.Close();
    onProcess(process);
    try
    {
      using var registration = cancellationToken.Register(() => TryKill(process));
      if (cancellationToken.IsCancellationRequested) TryKill(process);
      var output = PumpAsync(process.StandardOutput.BaseStream, write);
      var errors = PumpAsync(process.StandardError.BaseStream, line => write("STDERR: " + line));
      await process.WaitForExitAsync(CancellationToken.None);
      await Task.WhenAll(output, errors);
      return process.ExitCode;
    }
    finally
    {
      onProcess(null);
    }
  }

  static void TryKill(Process process)
  {
    try { process.Kill(entireProcessTree: true); }
    catch (InvalidOperationException) { /* proces je ravno končal sam */ }
  }

  public static async Task PumpAsync(Stream stream, Action<string> onLine)
  {
    var buffer = new byte[8192];
    using var pending = new MemoryStream();
    int read;
    while ((read = await stream.ReadAsync(buffer)) > 0)
    {
      var start = 0;
      for (var index = 0; index < read; index++)
      {
        if (buffer[index] != (byte)'\n') continue;
        pending.Write(buffer, start, index - start);
        onLine(WorkerLogs.DecodeLine(pending.GetBuffer().AsSpan(0, (int)pending.Length)));
        pending.SetLength(0);
        start = index + 1;
      }
      pending.Write(buffer, start, read - start);
    }
    if (pending.Length > 0) onLine(WorkerLogs.DecodeLine(pending.GetBuffer().AsSpan(0, (int)pending.Length)));
  }
}

/// <summary>
/// Zagon workerjev in ciklov iz intraneta ter branje dnevnikov.
///
/// Singleton, ker zagon živi dlje od strani, ki ga je sprožila: skrbnik lahko stran zapre in se
/// vrne, zagon pa teče naprej in je še vedno viden. Vzporedno sme teči več različnih poslov,
/// isti pa samo enkrat — dvojni klik ne sme dvakrat klicati SAOP-a. Isti cikel ne teče dvakrat
/// niti čez procese: to drži ops.ClaimWorkerCycle. Prekrivanje na ravni postopka in podjetja
/// prepreči ops.BeginRun (sp_getapplock), ne ta razred.
///
/// Ura je <see cref="WorkerSchedulerService"/>: ta razred sam ne ponavlja in ne čaka; razporejevalnik
/// ga kliče, kadar je cikel na vrsti, človek pa z gumbom.
/// </summary>
public sealed class WorkerConsoleService(
  IConfiguration configuration, WorkerCycleRunner runner, WorkerSchedulerStore store, ILogger<WorkerConsoleService> logger)
{
  const int MaxRuns = 40;
  readonly object gate = new();
  readonly List<WorkerRun> runs = [];
  WorkerConsoleSetup? setup;
  long version;
  IReadOnlyList<ScheduledTaskState>? taskCache;
  DateTime taskCacheUtc;

  public WorkerConsoleSetup Setup
  {
    get
    {
      lock (gate) return setup ??= ResolveSetup(configuration);
    }
  }

  /// <summary>Razporejevalnik ob zagonu zamenja mapo dnevnikov (register LOG_ROOT ali rezerva, kadar ni zapisljiva).</summary>
  public void ApplyLogRoot(string logRoot)
  {
    lock (gate) setup = Setup with { LogRoot = logRoot };
    Touch();
  }

  /// <summary>Raste ob vsaki novi vrstici ali spremembi stanja; stran po njem ve, ali mora risati.</summary>
  public long Version => Interlocked.Read(ref version);

  public IReadOnlyList<WorkerRun> Runs
  {
    get { lock (gate) return runs.ToList(); }
  }

  public int RunningCount
  {
    get { lock (gate) return runs.Count(run => run.EndedUtc is null); }
  }

  public WorkerRun? Find(Guid id)
  {
    lock (gate) return runs.FirstOrDefault(run => run.Id == id);
  }

  public WorkerRun? ActiveFor(string jobKey)
  {
    lock (gate) return runs.FirstOrDefault(run => run.Job.Key == jobKey && run.EndedUtc is null);
  }

  public WorkerRun? ActiveForCycle(string cycleKey)
  {
    lock (gate) return runs.FirstOrDefault(run => run.CycleKey == cycleKey && run.EndedUtc is null);
  }

  /// <summary>Zakaj posla tu ni mogoče pognati, ali null, kadar se da (glej <see cref="WorkerConsoleLayout.Unavailable"/>).</summary>
  public string? Unavailable(WorkerJob job) => WorkerConsoleLayout.Unavailable(Setup, job);

  /// <summary>Ročni zagon s strani: worker takoj, cikel prek najema v bazi.</summary>
  public Task<WorkerRun> StartAsync(WorkerJob job, IReadOnlyList<int> organizations, bool allOrganizations, string organizationsLabel, string actor,
    CancellationToken cancellationToken = default) =>
    job.Kind == WorkerJobKind.Cycle
      ? StartCycleAsync(job, actor, scheduled: false, cancellationToken)
      : Task.FromResult(StartWorker(job, organizations, allOrganizations, organizationsLabel, actor));

  WorkerRun StartWorker(WorkerJob job, IReadOnlyList<int> organizations, bool allOrganizations, string organizationsLabel, string actor)
  {
    var current = Setup;
    if (!current.Available) throw new InvalidOperationException($"Zagon tu ni na voljo: {current.Reason}");
    if (Unavailable(job) is { } reason) throw new InvalidOperationException($"{job.Label} tu ni na voljo: {reason}");

    var steps = WorkerJobs.Plan(job, organizations, allOrganizations, Paths(current));
    Directory.CreateDirectory(current.ManualLogRoot);
    var logPath = Path.Combine(current.ManualLogRoot, WorkerLogs.RunLogFileName(job.Key, PimTime.Local(DateTime.UtcNow)));
    var run = new WorkerRun(job, steps, organizationsLabel, actor, logPath, scheduled: false);
    Register(run, run.Job.Key);
    _ = Task.Run(() => ExecuteAsync(run, (write, token) => RunWorkerStepsAsync(run, write, token)));
    return run;
  }

  /// <summary>
  /// Zagon cikla: najprej najem vrstice v bazi (ops.ClaimWorkerCycle), šele nato proces. Razporejevalnik
  /// poda <paramref name="scheduled"/>; takrat cikel spoštuje razpored postopkov (--po-urniku) in se
  /// umakne, če ni na vrsti. Človek s strani cikel požene takoj (@Force), a nikoli dvakrat hkrati.
  /// </summary>
  public async Task<WorkerRun> StartCycleAsync(WorkerJob job, string actor, bool scheduled, CancellationToken cancellationToken = default)
  {
    var current = Setup;
    if (!current.Available) throw new InvalidOperationException($"Zagon tu ni na voljo: {current.Reason}");
    if (job.Kind != WorkerJobKind.Cycle) throw new InvalidOperationException($"{job.Label} ni cikel.");
    var cycle = WorkerCycles.Find(job.Target) ?? throw new InvalidOperationException($"Cikel {job.Target} ne obstaja.");
    lock (gate)
    {
      if (runs.Any(existing => existing.CycleKey == cycle.Key && existing.EndedUtc is null))
        throw new InvalidOperationException($"{cycle.Label} že teče v tem procesu; počakaj, da konča, ali ga ustavi.");
    }

    var row = (await store.GetCyclesAsync(cancellationToken)).FirstOrDefault(candidate => candidate.CycleKey == cycle.Key)
      ?? throw new InvalidOperationException($"Cikel {cycle.Key} v bazi ne obstaja (migracija 221).");
    var options = (job.Cycle ?? new CycleOptions()) with { BySchedule = scheduled };
    var nextDue = WorkerCycles.NextDue(row.IntervalSeconds, row.DailyAtLocal, DateTime.UtcNow, PimTime.Zone);

    Directory.CreateDirectory(current.CycleLogRoot);
    var logPath = Path.Combine(current.CycleLogRoot, WorkerLogs.RunLogFileName(job.Key, PimTime.Local(DateTime.UtcNow)));
    var (runId, reason) = await store.ClaimAsync(cycle.Key, nextDue, scheduled ? "Scheduler" : "Human", actor, Environment.MachineName, logPath,
      force: !scheduled, cancellationToken);
    if (runId is null)
      throw new InvalidOperationException(reason switch
      {
        "NotDue" => $"{cycle.Label} še ni na vrsti.",
        "Disabled" => $"{cycle.Label} je izklopljen.",
        "Unknown" => $"Cikel {cycle.Key} v bazi ne obstaja.",
        _ when reason.StartsWith("Running:", StringComparison.Ordinal) => $"{cycle.Label} že teče: {reason["Running:".Length..]}.",
        _ => $"{cycle.Label} ni bil pognan: {reason}.",
      });

    var run = new WorkerRun(job, [], scheduled ? "po razporedu" : "vsa podjetja", actor, logPath, scheduled) { CycleRunId = runId };
    Register(run, run.Job.Key);
    _ = Task.Run(() => ExecuteAsync(run, async (write, token) =>
    {
      var outcome = await runner.RunAsync(run, cycle, options, Setup, write, token);
      run.CycleSummary = outcome;
      return outcome.FailedGroups;
    }));
    return run;
  }

  void Register(WorkerRun run, string jobKey)
  {
    lock (gate)
    {
      if (runs.Any(existing => existing.Job.Key == jobKey && existing.EndedUtc is null))
        throw new InvalidOperationException($"{run.Job.Label} že teče; počakaj, da konča, ali ga ustavi.");
      runs.Insert(0, run);
      var finished = runs.Where(existing => existing.EndedUtc is not null).Skip(MaxRuns).ToList();
      foreach (var old in finished) runs.Remove(old);
    }
    Touch();
  }

  public bool Cancel(Guid id, string actor)
  {
    var run = Find(id);
    if (run is null || run.EndedUtc is not null) return false;
    run.CancelledBy = actor;
    run.Cancellation.Cancel();
    try { run.CurrentProcess?.Kill(entireProcessTree: true); }
    catch (InvalidOperationException) { /* proces je ravno končal sam */ }
    Touch();
    return true;
  }

  /// <summary>Ob ustavljanju aplikacije: vsi tekoči zagoni dobijo razlog in se ustavijo.</summary>
  public void CancelAll(string actor)
  {
    foreach (var run in Runs.Where(run => run.EndedUtc is null)) Cancel(run.Id, actor);
  }

  public async Task WaitForRunsAsync(TimeSpan timeout)
  {
    var until = DateTime.UtcNow + timeout;
    while (RunningCount > 0 && DateTime.UtcNow < until) await Task.Delay(200);
  }

  /// <summary>Najnovejše datoteke dnevnikov: dnevni dnevniki skript, cikli in ročni zagoni.</summary>
  public IReadOnlyList<WorkerLogFile> ListLogs(int take = 80)
  {
    var current = Setup;
    if (!current.Available || !Directory.Exists(current.LogRoot)) return [];

    IEnumerable<FileInfo> files = new DirectoryInfo(current.LogRoot).EnumerateFiles("*.log", SearchOption.TopDirectoryOnly);
    foreach (var folder in new[] { current.ManualLogRoot, current.CycleLogRoot })
    {
      var directory = new DirectoryInfo(folder);
      if (directory.Exists) files = files.Concat(directory.EnumerateFiles("*.log", SearchOption.TopDirectoryOnly));
    }

    return files
      .OrderByDescending(file => file.LastWriteTimeUtc)
      .Take(take)
      .Select(file => Describe(current.LogRoot, file))
      .ToList();
  }

  /// <summary>Konec dnevnika ali null, kadar pot ne kaže na dnevnik v mapi dnevnikov.</summary>
  public IReadOnlyList<string>? ReadLog(string relativePath, int maxBytes = 512 * 1024)
  {
    var current = Setup;
    if (!current.Available) return null;
    var full = WorkerLogs.ResolveInside(current.LogRoot, relativePath);
    return full is null || !File.Exists(full) ? null : WorkerLogs.ReadTail(full, maxBytes);
  }

  /// <summary>Pot dnevnika zagona cikla, relativna na mapo dnevnikov (za odpiranje s strani); null, kadar ni v njej.</summary>
  public string? RelativeLogPath(string? fullPath)
  {
    if (string.IsNullOrWhiteSpace(fullPath)) return null;
    var root = Path.GetFullPath(Setup.LogRoot).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
    var full = Path.GetFullPath(fullPath);
    return full.StartsWith(root, StringComparison.OrdinalIgnoreCase) ? full[root.Length..] : null;
  }

  /// <summary>
  /// Ali so stare načrtovane naloge Windows registrirane. Od 2026-09-17 cikle poganja razporejevalnik
  /// v aplikaciji; naloge so tu zato, da stran pove, če še tečejo vzporedno (podvojeni klici).
  /// </summary>
  public async Task<IReadOnlyList<ScheduledTaskState>> GetScheduledTasksAsync(bool refresh, CancellationToken cancellationToken = default)
  {
    if (!refresh && taskCache is not null && DateTime.UtcNow - taskCacheUtc < TimeSpan.FromSeconds(30)) return taskCache;

    var result = new List<ScheduledTaskState>();
    foreach (var (task, prefix, jobKey) in WorkerJobs.WindowsTasks)
    {
      if (!OperatingSystem.IsWindows())
      {
        result.Add(new(task, null, null, "samo Windows", prefix, jobKey));
        continue;
      }

      var (exitCode, output, errors) = await RunQuietAsync("schtasks.exe", ["/Query", "/TN", task, "/FO", "CSV", "/NH"], TimeSpan.FromSeconds(10), cancellationToken);
      var line = exitCode == 0 ? output.Select(WorkerLogs.ParseSchtasksCsv).FirstOrDefault(parsed => parsed is not null) : null;
      result.Add(line is not null
        ? new(task, true, line.NextRun, line.Status, prefix, jobKey)
        // Neničelna koda je skoraj vedno "ni najdena". Pod IIS pa lahko pomeni tudi, da račun
        // aplikacijskega bazena nalog drugega uporabnika ne vidi — zato gre sporočilo zraven.
        : new(task, exitCode == 0 ? null : false, null, errors.FirstOrDefault(text => !string.IsNullOrWhiteSpace(text))?.Trim(), prefix, jobKey));
    }

    taskCache = result;
    taskCacheUtc = DateTime.UtcNow;
    return result;
  }

  void Touch() => Interlocked.Increment(ref version);

  WorkerPaths Paths(WorkerConsoleSetup current)
  {
    // Brez korena repozitorija (strežnik samo z objavljenimi workerji) gre izvoz po podjetjih ob
    // objavljene workerje, ne v relativno mapo ob trenutni mapi procesa.
    var exportBase = current.RepositoryRoot.Length > 0 ? current.RepositoryRoot : current.PublishedWorkersRoot ?? "";
    return new WorkerPaths(
      current.RepositoryRoot, current.SolutionRoot,
      worker => WorkerConsoleLayout.PublishedWorker(current.PublishedWorkersRoot, worker),
      organizationId => Path.Combine(exportBase, "izvoz", "magento", organizationId.ToString(CultureInfo.InvariantCulture)),
      current.PublishedWorkersRoot);
  }

  /// <summary>Okvir zagona: dnevnik, glava, telo, noga, stanje — enak za worker in cikel.</summary>
  async Task ExecuteAsync(WorkerRun run, Func<Action<string>, CancellationToken, Task<int>> body)
  {
    var writerGate = new object();
    StreamWriter? writer = null;
    try
    {
      writer = new StreamWriter(
        new FileStream(run.LogPath, FileMode.CreateNew, FileAccess.Write, FileShare.Read),
        new UTF8Encoding(encoderShouldEmitUTF8Identifier: false)) { AutoFlush = true };
    }
    catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
    {
      logger.LogWarning(exception, "Dnevnika zagona {LogPath} ni mogoče odpreti.", run.LogPath);
    }

    void Write(string text)
    {
      var line = WorkerLogs.Stamp(text, PimTime.Local(DateTime.UtcNow));
      run.Append(line);
      if (writer is not null)
        lock (writerGate) writer.WriteLine(line);
      Touch();
    }

    var exitCode = 0;
    try
    {
      Write($"{WorkerLogs.HeaderPrefix}{run.Job.Label} | sprožil: {run.StartedBy}{(run.Scheduled ? " (razporejevalnik)" : "")} | {run.OrganizationsLabel} | "
        + PimTime.Local(run.StartedUtc).ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture)
        + (writer is null ? " | OPOZORILO: dnevnik na disku ni zapisan" : ""));
      exitCode = await body(Write, run.Cancellation.Token);
      if (run.CancelledBy is not null) Write($"=== ustavil: {run.CancelledBy}");
    }
    catch (OperationCanceledException) when (run.CancelledBy is not null)
    {
      Write($"=== ustavil: {run.CancelledBy}");
    }
    catch (Exception exception)
    {
      logger.LogError(exception, "Zagon {Job} je padel.", run.Job.Key);
      run.Failure = exception.Message;
      Write($"NAPAKA: zagon je padel v intranetu: {exception.Message}");
      exitCode = Math.Max(exitCode, 1);
    }
    finally
    {
      if (run.CancelledBy is not null) exitCode = -1;
      run.ExitCode = exitCode;
      run.CurrentStep = null;
      run.EndedUtc = DateTime.UtcNow;
      Write(WorkerLogs.Footer(exitCode, run.Elapsed, run.CancelledBy is not null));
      if (writer is not null)
        lock (writerGate) writer.Dispose();

      if (run.CycleRunId is { } runId)
      {
        var status = run.CancelledBy is not null ? "Cancelled" : exitCode == 0 ? "Succeeded" : "Failed";
        // Zagon, ki je padel pred prvim korakom (npr. baza brez tabele), mora razlog pustiti v zgodovini,
        // ne samo v datoteki: stran »Zgodovina zagonov ciklov« je prvo mesto, kamor človek pogleda.
        var summary = run.CancelledBy is not null ? $"Ustavil: {run.CancelledBy}."
          : run.CycleSummary?.Summary ?? (run.Failure is { } failure ? $"Padel v intranetu: {failure}" : null);
        try
        {
          await store.CompleteAsync(runId, status, exitCode, run.CycleSummary?.StepsTotal ?? 0, run.CycleSummary?.StepsFailed ?? 0,
            run.ErrorLines, summary, run.StartedBy, CancellationToken.None);
        }
        catch (Exception exception) { logger.LogError(exception, "Zagona cikla {RunId} ni bilo mogoče zaključiti v bazi.", runId); }
      }
      Touch();
    }
  }

  /// <summary>Ročni zagon workerja: en proces na korak (posel po podjetjih ima korak na podjetje).</summary>
  async Task<int> RunWorkerStepsAsync(WorkerRun run, Action<string> write, CancellationToken cancellationToken)
  {
    var environment = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
    {
      ["PIM_TRIGGERED_BY"] = run.TriggeredBy,
      ["DOTNET_NOLOGO"] = "1",
    };
    // Worker mora pisati v isto bazo, ki jo kaže ta stran. Brez tega bi vzel appsettings.Local.json
    // iz korena repozitorija, ki lahko kaže drugam kot nastavitev intraneta.
    if (ConnectionStringResolver.Resolve(configuration) is { Length: > 0 } connectionString)
      environment[LocalSettings.ConnectionVariable] = connectionString;
    if (run.Job.Environment is { } extra)
      foreach (var (name, value) in extra) environment[name] = value;

    var failures = 0;
    var lastExitCode = 0;
    foreach (var step in run.Steps)
    {
      if (cancellationToken.IsCancellationRequested) break;
      run.CurrentStep = step.Display;
      write($"--- {step.Display}");

      int exitCode;
      try
      {
        exitCode = await WorkerProcess.RunAsync(step, environment, write, process => run.CurrentProcess = process, cancellationToken);
      }
      catch (Exception exception) when (exception is System.ComponentModel.Win32Exception or InvalidOperationException or IOException)
      {
        write($"NAPAKA: procesa ni bilo mogoče zagnati ({step.FileName}): {exception.Message}");
        exitCode = -1;
      }

      lastExitCode = exitCode;
      if (exitCode != 0 && !cancellationToken.IsCancellationRequested)
      {
        failures++;
        write($"NAPAKA: {step.Display} je končal z izhodno kodo {exitCode}.");
      }
    }

    // En korak: izhodna koda procesa. Več korakov (izvoz po podjetjih): število podjetij, pri
    // katerih je padel — isto pravilo kot v skriptah.
    return run.Steps.Count == 1 ? lastExitCode : failures;
  }

  static async Task<(int ExitCode, List<string> Output, List<string> Errors)> RunQuietAsync(
    string fileName, IReadOnlyList<string> arguments, TimeSpan timeout, CancellationToken cancellationToken)
  {
    var info = new ProcessStartInfo(fileName)
    {
      UseShellExecute = false,
      RedirectStandardOutput = true,
      RedirectStandardError = true,
      CreateNoWindow = true,
    };
    foreach (var argument in arguments) info.ArgumentList.Add(argument);

    var output = new List<string>();
    var errors = new List<string>();
    using var process = Process.Start(info) ?? throw new InvalidOperationException($"{fileName} se ni zagnal.");
    using var limit = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
    limit.CancelAfter(timeout);
    var readOutput = WorkerProcess.PumpAsync(process.StandardOutput.BaseStream, line => { lock (output) output.Add(line); });
    var readErrors = WorkerProcess.PumpAsync(process.StandardError.BaseStream, line => { lock (errors) errors.Add(line); });
    try
    {
      await process.WaitForExitAsync(limit.Token);
    }
    catch (OperationCanceledException)
    {
      try { process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
      return (-1, output, [$"{fileName} ni odgovoril v {timeout.TotalSeconds:N0} s."]);
    }
    await Task.WhenAll(readOutput, readErrors);
    return (process.ExitCode, output, errors);
  }

  static WorkerLogFile Describe(string root, FileInfo file)
  {
    var relative = Path.GetRelativePath(root, file.FullName);
    var kind = WorkerLogs.KindOf(relative);
    IReadOnlyList<string> tail = [];
    try { tail = WorkerLogs.ReadTail(file.FullName, 64 * 1024); }
    catch (IOException) { }
    catch (UnauthorizedAccessException) { }

    var fromIntranet = kind is "rocno" or "cikli";
    string? jobKey = fromIntranet && WorkerLogs.TryParseRunLogFileName(file.Name, out var key, out _) ? key : null;
    return new(relative, kind, file.LastWriteTimeUtc, file.Length,
      tail.Count(line => WorkerLogs.Classify(line) == LogLineTone.Error),
      fromIntranet ? WorkerLogs.ExitCodeFromFooter(tail) : null, jobKey);
  }

  // Na razvojnem računalniku intranet teče iz bin\ znotraj repozitorija in koren najde sam po
  // PIM.sln. Na strežniku je Workerji\ ob intranetu (objava intraneta) in ni treba nastaviti nič;
  // ključi WorkerConsole:* v appsettings.Local.json ob intranetu to prepišejo.
  static WorkerConsoleSetup ResolveSetup(IConfiguration configuration) =>
    WorkerConsoleLayout.Resolve(
      configuration["WorkerConsole:RepositoryRoot"],
      configuration["WorkerConsole:PublishedWorkersRoot"],
      configuration["WorkerConsole:LogRoot"],
      () => LocalSettings.FindSolutionRoot(AppContext.BaseDirectory),
      AppContext.BaseDirectory);
}
