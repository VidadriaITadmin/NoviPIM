using System.Net.Http;

using PIM.Automation;

namespace PIM.Intranet.Services;

/// <summary>
/// Naslov, na katerem intranet sam sebe doseže. Pod IIS ga aplikacija ne ve vnaprej (vezava je v
/// applicationHost.config); ve ga po prvi zahtevi. Rabi ga samo samodejni utrip (glej
/// <see cref="WorkerSchedulerService"/>), zato je dovolj, da se zapomni prva.
/// </summary>
public sealed class SelfAddress
{
  volatile string? url;

  public string? Url => url;

  public void Observe(HttpRequest request)
  {
    if (url is not null || !request.Host.HasValue) return;
    url = $"{request.Scheme}://{request.Host}{request.PathBase}";
  }
}

/// <param name="IsOwner">Ta proces drži najem in poganja cikle.</param>
/// <param name="Lease">Zadnji prebrani najem (naš ali tuj); null, kadar baze ni bilo mogoče vprašati.</param>
/// <param name="LogRootNote">Kadar dnevniki ne gredo v privzeto mapo (register LOG_ROOT ali rezerva, ker mapa ni zapisljiva).</param>
public sealed record SchedulerStatus(
  bool Enabled, string Owner, string Application, string HostName, bool IsOwner, SchedulerLease? Lease,
  DateTime? StartedUtc, DateTime? LastTickUtc, long Ticks, string? LastError, DateTime? LastErrorUtc,
  string? SelfUrl, DateTime? LastKeepAliveUtc, string? KeepAliveError, string? LogRootNote, IReadOnlyList<string> Notes)
{
  public bool IsIis => Application.StartsWith("IIS:", StringComparison.Ordinal);
}

/// <summary>
/// Ura v aplikaciji. Vsakih nekaj sekund obnovi najem v ops.SchedulerLease; kdor ga drži, požene
/// cikle, ki so na vrsti (ops.ClaimWorkerCycle — edina vrata, zato isti cikel nikoli ne teče dvakrat),
/// in ob vsakem tiku preveri zaostanek (ops.RaiseOverdueAlerts). Ostali procesi nad isto bazo samo
/// čakajo in to povedo na strani.
///
/// Zakaj v aplikaciji in ne v Windows nalogi: naloga je vezana na račun in računalnik, na katerem
/// jo je človek registriral; ta ura teče tam, kjer teče intranet — IIS, Visual Studio, dotnet run —
/// brez PowerShella, brez sqlcmd in brez skrbniških pravic.
///
/// IIS in mirovanje. Bazen brez zahtev IIS po 20 minutah ugasne in z njim to uro. Zato se, kadar
/// intranet teče pod IIS, vsakih nekaj minut sam pokliče na /health (naslov si zapomni ob prvi
/// zahtevi); to bazen drži buden. Recikliranje bazena (privzeto na 29 ur) ura preživi tako, da si
/// naslednji proces najem vzame, ko prvič steče — najbolje takoj ob zagonu z Application
/// Initialization (deploy\Configure-IisAlwaysRunning.ps1). Kar med izpadom ni teklo, pove alarm
/// CycleOverdue, ki ga prvi tik po vrnitvi odpre in prvi uspešen tek zapre.
/// </summary>
public sealed class WorkerSchedulerService(
  WorkerConsoleService konzola, WorkerSchedulerStore store, SelfAddress selfAddress,
  IConfiguration configuration, ILogger<WorkerSchedulerService> logger) : BackgroundService
{
  static readonly HttpClient KeepAliveClient = new(new HttpClientHandler
  {
    // Klic gre na lasten naslov; samopodpisan certifikat na localhostu ne sme podreti utripa.
    ServerCertificateCustomValidationCallback = (_, _, _, _) => true,
  })
  { Timeout = TimeSpan.FromSeconds(15) };

  readonly object gate = new();
  readonly List<string> notes = [];
  readonly string hostName = Environment.MachineName;
  readonly string application = WorkerCycles.ApplicationName(Environment.GetEnvironmentVariable("APP_POOL_ID"));
  SchedulerStatus status = new(true, "", "", Environment.MachineName, false, null, null, null, 0, null, null, null, null, null, null, []);
  bool wasOwner;

  public SchedulerStatus Status
  {
    get { lock (gate) return status; }
  }

  string Owner => WorkerCycles.OwnerName(hostName, Environment.ProcessId, application);

  // Od 2026-09-22 privzeto IZKLOPLJEN: workerje poganja samo PIM.AutomationHost. Prej je vsak zagon
  // intraneta (VS, testna kopija, recikel IIS) prevzel prost najem, pognal vse zapadle cikle hkrati in ob
  // koncu pustil viseče zagone in sirote. Vklop samo še izrecno: Scheduler:Enabled=true ali
  // PIM_SCHEDULER_ENABLED=true (zasilna rezerva, dokler storitev ni nameščena).
  bool Enabled =>
    string.Equals(Environment.GetEnvironmentVariable("PIM_SCHEDULER_ENABLED"), "true", StringComparison.OrdinalIgnoreCase)
    || string.Equals(configuration["Scheduler:Enabled"], "true", StringComparison.OrdinalIgnoreCase);

  int TickSeconds => Clamp(configuration.GetValue<int?>("Scheduler:TickSeconds") ?? 30, 10, 300);
  int LeaseSeconds => Clamp(configuration.GetValue<int?>("Scheduler:LeaseSeconds") ?? 90, 30, 600);
  int KeepAliveMinutes => Clamp(configuration.GetValue<int?>("Scheduler:KeepAliveMinutes") ?? 5, 0, 60);

  protected override async Task ExecuteAsync(CancellationToken stoppingToken)
  {
    lock (gate)
      status = new(Enabled, Owner, application, hostName, false, null, DateTime.UtcNow, null, 0, null, null, null, null, null, null, []);

    if (!Enabled)
    {
      Note("Razporejevalnik v intranetu je izklopljen (privzeto). Workerje poganja storitev PIM.AutomationHost; vklop samo izrecno s Scheduler:Enabled=true.");
      return;
    }

    // Zagon aplikacije ima prednost: prvi tik pride šele, ko je stran že dosegljiva.
    try { await Task.Delay(TimeSpan.FromSeconds(5), stoppingToken); }
    catch (OperationCanceledException) { return; }

    await PrepareLogRootAsync(stoppingToken);
    var layout = konzola.Setup;
    logger.LogInformation(
      "Razporejevalnik {Owner}: postavitev na voljo={Available} {Reason}; koren={RepositoryRoot}; rešitev={SolutionRoot}; objavljeni workerji={Published}; dnevniki={LogRoot}",
      Owner, layout.Available, layout.Reason ?? "", layout.RepositoryRoot, layout.SolutionRoot, layout.PublishedWorkersRoot ?? "-", layout.LogRoot);
    await BuildWorkersIfSourceAsync(stoppingToken);
    try { await store.EnsureCyclesAsync(WorkerCycles.All, stoppingToken); }
    catch (OperationCanceledException) { return; }
    catch (Exception exception) { Fail("Ciklov ni bilo mogoče uskladiti z bazo: " + exception.Message); }

    using var timer = new PeriodicTimer(TimeSpan.FromSeconds(TickSeconds));
    do
    {
      try { await TickAsync(stoppingToken); }
      catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { break; }
      catch (Exception exception)
      {
        logger.LogWarning(exception, "Tik razporejevalnika je padel.");
        Fail(exception.Message);
      }
    }
    while (await WaitAsync(timer, stoppingToken));
  }

  static async Task<bool> WaitAsync(PeriodicTimer timer, CancellationToken token)
  {
    try { return await timer.WaitForNextTickAsync(token); }
    catch (OperationCanceledException) { return false; }
  }

  public override async Task StopAsync(CancellationToken cancellationToken)
  {
    // Bazen se reciklira ali aplikacija ugaša: tekoči cikel se ustavi (drevo procesov), zagon dobi
    // stanje Cancelled z razlogom, najem pa se sprosti, da naslednji proces ne čaka na potek.
    konzola.CancelAll("intranet se ustavlja");
    await konzola.WaitForRunsAsync(TimeSpan.FromSeconds(10));
    if (Enabled)
    {
      try { await store.ReleaseLeaseAsync(Owner, CancellationToken.None); }
      catch (Exception exception) { logger.LogWarning(exception, "Najema ni bilo mogoče sprostiti."); }
    }
    await base.StopAsync(cancellationToken);
  }

  async Task TickAsync(CancellationToken cancellationToken)
  {
    // Intranet brez workerjev (npr. kopija brez izvorne kode) uro drži samo, dokler je nima kdo
    // drug; intranet, ki cikle lahko požene, mu jo vzame (ops.AcquireSchedulerLease).
    var lease = await store.AcquireLeaseAsync(Owner, hostName, Environment.ProcessId, application, LeaseSeconds, konzola.Setup.Available, cancellationToken);
    var isOwner = lease?.IsOwner == true;
    lock (gate)
      status = status with { Lease = lease, IsOwner = isOwner, LastTickUtc = DateTime.UtcNow, Ticks = status.Ticks + 1, LastError = null };

    if (!isOwner)
    {
      wasOwner = false;
      return;
    }

    if (!wasOwner)
    {
      wasOwner = true;
      // Nič od prejšnjega procesa tega gostitelja ne teče več; tuji teki brez utripa so enako mrtvi.
      var closed = await store.AbandonAsync(hostName, Owner, cancellationToken);
      if (closed > 0) Note($"Ob prevzemu najema zaprtih {closed} zagon(ov), ki se niso končali sami (Abandoned).");
      logger.LogInformation("Razporejevalnik {Owner} drži najem.", Owner);
    }

    await store.RaiseOverdueAlertsAsync(Owner, cancellationToken);

    if (!konzola.Setup.Available)
    {
      if (Note("Ciklov ni mogoče pognati: " + konzola.Setup.Reason))
        logger.LogWarning("Razporejevalnik drži najem, a ciklov ne more pognati: {Reason}", konzola.Setup.Reason);
      return;
    }

    var cycles = await store.GetCyclesAsync(cancellationToken);
    var now = DateTime.UtcNow;
    var stagger = 0;
    foreach (var cycle in cycles)
    {
      if (!cycle.IsEnabled || cycle.RunningRunId is not null) continue;

      if (cycle.NextDueUtc is null)
      {
        // Nova nastavitev ali prvi zagon: termin se določi zdaj, tek pride ob naslednjem tiku.
        var due = WorkerCycles.InitialDue(cycle.IntervalSeconds, cycle.DailyAtLocal, stagger++, now, PimTime.Zone);
        await store.SetNextDueAsync(cycle.CycleKey, due, onlyIfNull: true, cancellationToken);
        continue;
      }
      if (cycle.NextDueUtc > now) continue;
      if (konzola.ActiveForCycle(cycle.CycleKey) is not null) continue;
      if (WorkerJobs.ForCycle(cycle.CycleKey) is not { } job) continue;

      try
      {
        await konzola.StartCycleAsync(job, "razporejevalnik", scheduled: true, cancellationToken);
        logger.LogInformation("Cikel {Cycle} je na vrsti; pognan.", cycle.CycleKey);
      }
      catch (InvalidOperationException exception)
      {
        // Drug gostitelj je bil hitrejši ali cikel medtem ni več na vrsti — to ni napaka razporejevalnika.
        logger.LogInformation("Cikel {Cycle} ni bil pognan: {Reason}", cycle.CycleKey, exception.Message);
      }
    }

    await KeepAliveAsync(cancellationToken);
  }

  /// <summary>Pod IIS bazen brez zahtev ugasne; lasten klic na /health ga drži budnega.</summary>
  async Task KeepAliveAsync(CancellationToken cancellationToken)
  {
    if (!application.StartsWith("IIS:", StringComparison.Ordinal) || KeepAliveMinutes == 0) return;
    var url = selfAddress.Url;
    var last = Status.LastKeepAliveUtc;
    lock (gate) status = status with { SelfUrl = url };
    if (url is null) return;
    if (last is { } previous && DateTime.UtcNow - previous < TimeSpan.FromMinutes(KeepAliveMinutes)) return;

    try
    {
      using var response = await KeepAliveClient.GetAsync(url.TrimEnd('/') + "/health", cancellationToken);
      lock (gate)
        status = status with
        {
          LastKeepAliveUtc = DateTime.UtcNow,
          KeepAliveError = response.IsSuccessStatusCode ? null : $"/health je vrnil {(int)response.StatusCode}",
        };
    }
    catch (Exception exception) when (exception is HttpRequestException or TaskCanceledException)
    {
      lock (gate) status = status with { LastKeepAliveUtc = DateTime.UtcNow, KeepAliveError = exception.Message };
    }
  }

  /// <summary>
  /// Kam gredo dnevniki. Vrstni red: nastavitev WorkerConsole:LogRoot (že v postavitvi), register
  /// LOG_ROOT (/administracija/mape), sicer privzetek postavitve. Pod IIS mapa spletnega mesta
  /// aplikacijskemu bazenu praviloma ni zapisljiva — takrat gre v rezervno mapo in stran to pove,
  /// namesto da bi vsak zagon tiho ostal brez dnevnika.
  /// </summary>
  async Task PrepareLogRootAsync(CancellationToken cancellationToken)
  {
    var setup = konzola.Setup;
    if (!setup.Available) return;

    string? note = null;
    var root = setup.LogRoot;
    if (string.IsNullOrWhiteSpace(configuration["WorkerConsole:LogRoot"]))
    {
      try
      {
        if (await store.ResolveSystemPathAsync(PIM.Operations.SystemPaths.Log, cancellationToken) is { Length: > 0 } registered)
        {
          root = registered;
          note = $"Dnevniki gredo v {root} (register LOG_ROOT).";
        }
      }
      catch (Exception exception) { logger.LogWarning(exception, "Registra LOG_ROOT ni mogoče prebrati."); }
    }

    if (!IsWritable(root))
    {
      var fallback = Path.Combine(Path.GetTempPath(), "PIM", "logs");
      note = $"Mapa dnevnikov {root} ni zapisljiva za račun {Environment.UserName}; dnevniki gredo v {fallback}. "
        + "Nastavi LOG_ROOT na /administracija/mape ali daj računu pravico pisanja.";
      root = fallback;
    }

    if (root != setup.LogRoot) konzola.ApplyLogRoot(root);
    lock (gate) status = status with { LogRootNote = note };
  }

  /// <summary>
  /// Razvojni računalnik: workerji tečejo z <c>dotnet run --no-build</c> (kot iz skript), zato jih
  /// razporejevalnik ob svojem zagonu zgradi enkrat — vsak projekt posebej, ne PIM.sln, ker bi
  /// zaklenjen intranet (Visual Studio) podrl celo rešitev. Zastarel binarni worker je 2026-09-17
  /// petminutni cikel podiral z »Manjka --output-dir«, ker skripta med dnevom ne gradi. Na strežniku
  /// (objavljeni .exe) ni česa graditi.
  /// </summary>
  async Task BuildWorkersIfSourceAsync(CancellationToken cancellationToken)
  {
    var setup = konzola.Setup;
    if (!setup.Available || !setup.HasSource || setup.PublishedWorkersRoot is not null) return;

    var projects = new List<string>();
    var workers = Path.Combine(setup.SolutionRoot, "workers");
    if (Directory.Exists(workers))
      projects.AddRange(Directory.EnumerateDirectories(workers).Where(directory => Directory.EnumerateFiles(directory, "*.csproj").Any()));
    var selfTest = Path.Combine(setup.SolutionRoot, "tests", "PIM.SelfTest.Nightly");
    if (Directory.Exists(selfTest)) projects.Add(selfTest);

    var watch = System.Diagnostics.Stopwatch.StartNew();
    var failed = new List<string>();
    foreach (var project in projects)
    {
      if (cancellationToken.IsCancellationRequested) return;
      var lines = new List<string>();
      try
      {
        var step = new WorkerLaunchStep("dotnet", ["build", project, "-v", "q", "--nologo"], setup.SolutionRoot, $"dotnet build {Path.GetFileName(project)}", null);
        var exitCode = await WorkerProcess.RunAsync(step, new Dictionary<string, string> { ["DOTNET_NOLOGO"] = "1" }, lines.Add, _ => { }, cancellationToken);
        if (exitCode != 0)
        {
          failed.Add(Path.GetFileName(project));
          logger.LogWarning("Gradnja {Project} ni uspela: {Output}", project, string.Join(" | ", lines.TakeLast(5)));
        }
      }
      catch (Exception exception) when (exception is System.ComponentModel.Win32Exception or InvalidOperationException or IOException)
      {
        failed.Add(Path.GetFileName(project));
        logger.LogWarning(exception, "Gradnje {Project} ni bilo mogoče zagnati.", project);
      }
    }
    watch.Stop();

    Note(failed.Count == 0
      ? $"Workerji zgrajeni ob zagonu ({projects.Count} projektov, {(int)watch.Elapsed.TotalSeconds} s); cikli tečejo z dotnet run --no-build."
      : $"Gradnja ob zagonu ni uspela za: {string.Join(", ", failed)} — ti workerji bodo tekli s starim binarnim izpisom ali padli. Glej dnevnik aplikacije.");
  }

  static bool IsWritable(string directory)
  {
    try
    {
      Directory.CreateDirectory(directory);
      var probe = Path.Combine(directory, $".pim-probe-{Guid.NewGuid():N}");
      File.WriteAllText(probe, "");
      File.Delete(probe);
      return true;
    }
    catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { return false; }
  }

  /// <returns>true, kadar je opomba nova (ista zaporedna opomba se ne ponavlja).</returns>
  bool Note(string text)
  {
    lock (gate)
    {
      var added = notes.Count == 0 || notes[^1] != text;
      if (added)
      {
        notes.Add(text);
        if (notes.Count > 10) notes.RemoveAt(0);
      }
      status = status with { Notes = notes.ToList() };
      return added;
    }
  }

  void Fail(string message)
  {
    lock (gate) status = status with { LastError = message, LastErrorUtc = DateTime.UtcNow };
  }

  static int Clamp(int value, int min, int max) => Math.Max(min, Math.Min(max, value));
}
