using System.Globalization;
using PIM.Operations;

namespace PIM.Automation;

/// <summary>
/// Kar gostitelj potrebuje od sveta zunaj baze: postavitev (izvorna koda ali objavljeni workerji), mapa
/// dnevnikov, časovni pas in okolje otroških procesov. Ročni zagon s strani je samo zahteva
/// (ops.RequestJobRun), ki jo izvede isti gostitelj — zato ročni in načrtovani zagon poganjata isti
/// ukaz na isti mapi.
/// </summary>
public static class AutomationEnvironment
{
  /// <summary>Windows ime pasu; Linux/ICU ime Europe/Ljubljana je sprejeto kot rezerva (isto kot PimTime).</summary>
  public const string DefaultZoneId = "Central European Standard Time";

  public static TimeZoneInfo ResolveZone(string? id)
  {
    foreach (var candidate in new[] { id, DefaultZoneId, "Europe/Ljubljana" })
    {
      if (string.IsNullOrWhiteSpace(candidate)) continue;
      try { return TimeZoneInfo.FindSystemTimeZoneById(candidate); }
      catch (TimeZoneNotFoundException) { }
      catch (InvalidTimeZoneException) { }
    }
    return TimeZoneInfo.Local;
  }

  /// <summary>
  /// Postavitev za gostitelja. Objavljen gostitelj teče iz <c>&lt;mapa&gt;\Workerji\PIM.AutomationHost\</c>
  /// (objava intraneta, cilj PimPublishWorkersAndScripts): objavljeni workerji so ob njem, koren je mapa
  /// intraneta. Iz izvorne kode ga najde po PIM.sln. Ključi Automation:RepositoryRoot, PublishedWorkersRoot
  /// in LogRoot to prepišejo.
  /// </summary>
  public static WorkerConsoleSetup ResolveSetup(string? repositoryRoot, string? publishedWorkersRoot, string? logRoot, string applicationDirectory)
  {
    var directory = new DirectoryInfo(applicationDirectory.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
    string? siteRoot = null;
    if (string.IsNullOrWhiteSpace(publishedWorkersRoot) && directory.Parent is { } parent
        && parent.Name.Equals("Workerji", StringComparison.OrdinalIgnoreCase) && parent.Parent is { } site)
    {
      publishedWorkersRoot = parent.FullName;
      siteRoot = site.FullName;
    }

    return WorkerConsoleLayout.Resolve(
      repositoryRoot, publishedWorkersRoot, logRoot,
      () => LocalSettings.FindSolutionRoot(applicationDirectory),
      siteRoot ?? applicationDirectory);
  }

  /// <summary>
  /// Kam gredo dnevniki: nastavitev, register LOG_ROOT (/administracija/mape), sicer privzetek postavitve;
  /// nezapisljiva mapa gre v rezervo (%TEMP%\PIM\logs) in to je vidno v opombi, ne tiho.
  /// </summary>
  public static async Task<(string LogRoot, string? Note)> PrepareLogRootAsync(
    AutomationStore store, WorkerConsoleSetup setup, bool configuredExplicitly, CancellationToken cancellationToken)
  {
    string? note = null;
    var root = setup.LogRoot;
    if (!configuredExplicitly)
    {
      try
      {
        if (await store.ResolveSystemPathAsync(SystemPaths.Log, cancellationToken) is { Length: > 0 } registered)
        {
          root = registered;
          note = $"Dnevniki gredo v {root} (register LOG_ROOT).";
        }
      }
      catch (Exception) { /* register ni dosegljiv: velja privzetek */ }
    }

    if (!IsWritable(root))
    {
      var fallback = Path.Combine(Path.GetTempPath(), "PIM", "logs");
      note = $"Mapa dnevnikov {root} ni zapisljiva za račun {Environment.UserName}; dnevniki gredo v {fallback}. Nastavi LOG_ROOT na /administracija/mape ali daj računu pravico pisanja.";
      root = fallback;
    }
    return (root, note);
  }

  /// <summary>Podmapa mape dnevnikov za zagone poslov (en dnevnik na zagon); pot gre v ops.JobRun.LogPath, po njej ga bere intranet.</summary>
  public const string JobLogFolder = "opravila";

  /// <summary>Koliko dni gostitelj hrani svoje dnevnike (opravila\, gostitelj\).</summary>
  public const int LogRetentionDays = 14;

  /// <summary>
  /// Hramba: izbriše *.log v podmapah opravila\ in gostitelj\, starejše od <paramref name="days"/> dni.
  /// Drugih datotek v mapi dnevnikov (dnevniki starih ciklov iz časa pred 254, skripte) se ne dotika.
  /// </summary>
  public static int PruneLogs(string logRoot, int days, Action<string, Exception?> warn)
  {
    var removed = 0;
    var cutoff = DateTime.UtcNow.AddDays(-Math.Max(1, days));
    foreach (var folder in new[] { JobLogFolder, "gostitelj" })
    {
      var path = Path.Combine(logRoot, folder);
      if (!Directory.Exists(path)) continue;
      foreach (var file in Directory.EnumerateFiles(path, "*.log"))
      {
        try
        {
          if (File.GetLastWriteTimeUtc(file) >= cutoff) continue;
          File.Delete(file);
          removed++;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
          warn($"Dnevnika {file} ni bilo mogoče izbrisati.", exception);
        }
      }
    }
    return removed;
  }

  public static string JobLogPath(string logRoot, string jobKey, DateTime startedLocal)
  {
    var folder = Path.Combine(logRoot, JobLogFolder);
    Directory.CreateDirectory(folder);
    return Path.Combine(folder, WorkerLogs.RunLogFileName(jobKey, startedLocal));
  }

  /// <summary>Okolje posla za en zagon: podjetja, mape, register (isti vrstni red kot v PIM.Operations.SystemPaths).</summary>
  public static async Task<CycleEnvironment> BuildAsync(
    AutomationStore store, WorkerConsoleSetup setup, TimeZoneInfo zone, int maxParallel, Action<string, Exception?> warn, CancellationToken cancellationToken)
  {
    var organizations = await store.GetActiveOrganizationsAsync(cancellationToken);

    var exportBase = setup.RepositoryRoot.Length > 0 ? setup.RepositoryRoot : setup.PublishedWorkersRoot ?? AppContext.BaseDirectory;
    var landing = Environment.GetEnvironmentVariable("PIM_FETCH_ROOT");
    if (string.IsNullOrWhiteSpace(landing))
    {
      try { landing = await store.ResolveSystemPathAsync(SystemPaths.Landing, cancellationToken); }
      catch (Exception exception) { warn("Registra LANDING_ROOT ni mogoče prebrati; velja privzetek.", exception); }
    }
    if (string.IsNullOrWhiteSpace(landing))
      landing = Path.Combine(setup.SolutionRoot.Length > 0 ? setup.SolutionRoot : exportBase, "data", "prevzem");

    var export = Environment.GetEnvironmentVariable("PIM_EXPORT_ROOT");
    if (string.IsNullOrWhiteSpace(export))
    {
      try { export = await store.ResolveSystemPathAsync(SystemPaths.Export, cancellationToken); }
      catch (Exception exception) { warn("Registra EXPORT_ROOT ni mogoče prebrati; velja privzetek.", exception); }
    }

    var paths = new WorkerPaths(
      setup.RepositoryRoot, setup.SolutionRoot,
      worker => WorkerConsoleLayout.PublishedWorker(setup.PublishedWorkersRoot, worker),
      organizationId => Path.Combine(exportBase, "izvoz", "magento", organizationId.ToString(CultureInfo.InvariantCulture)),
      setup.PublishedWorkersRoot);

    var localNow = TimeZoneInfo.ConvertTimeFromUtc(DateTime.UtcNow, zone);
    return new(
      paths, organizations, WorkerCycles.CatalogOrganization, landing,
      string.IsNullOrWhiteSpace(export) ? null : export,
      setup.SolutionRoot.Length > 0 ? Path.Combine(setup.SolutionRoot, "fixtures") : null,
      localNow.Day == 1, maxParallel,
      Directory.Exists, ListFiles);
  }

  /// <summary>Datoteke v mapi brez oznak prevzema (.prenos, .pocakaj) in Excelovih zaklepov — isti filter kot v skriptah.</summary>
  public static IReadOnlyList<string> ListFiles(string directory)
  {
    if (!Directory.Exists(directory)) return [];
    return Directory.EnumerateFiles(directory)
      .Where(path =>
      {
        var name = Path.GetFileName(path);
        var extension = Path.GetExtension(path);
        return !name.StartsWith("~$", StringComparison.Ordinal)
          && !extension.Equals(".prenos", StringComparison.OrdinalIgnoreCase)
          && !extension.Equals(".pocakaj", StringComparison.OrdinalIgnoreCase);
      })
      .OrderBy(path => path, StringComparer.OrdinalIgnoreCase)
      .ToList();
  }

  /// <summary>
  /// Kar mora otrok vedeti: isto povezavo kot gostitelj (da piše v bazo, ki jo stran kaže), kdo ga je
  /// sprožil (ops.PipelineRun.TriggeredBy), in nič od gostiteljevih spremenljivk.
  /// </summary>
  public static Dictionary<string, string> ChildEnvironment(string triggeredBy, string? connectionString)
  {
    var environment = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
    {
      // Zaprt seznam iz 144: Scheduler, Human, Task. Zagon iz odvisnosti je za worker zagon razporejevalnika.
      ["PIM_TRIGGERED_BY"] = triggeredBy == "Human" ? "Human" : "Scheduler",
      ["DOTNET_NOLOGO"] = "1",
    };
    if (connectionString is { Length: > 0 })
      environment[LocalSettings.ConnectionVariable] = connectionString;
    return environment;
  }

  public static bool IsWritable(string directory)
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

  /// <summary>
  /// Razvojni računalnik: workerji tečejo z <c>dotnet run --no-build</c>, zato jih gostitelj ob svojem
  /// zagonu zgradi enkrat — vsak projekt posebej, ne PIM.sln (zaklenjen intranet v Visual Studiu bi podrl
  /// celo rešitev). Na strežniku (objavljeni .exe) ni česa graditi.
  /// </summary>
  public static async Task<string?> BuildWorkersIfSourceAsync(WorkerConsoleSetup setup, Action<string> log, CancellationToken cancellationToken)
  {
    if (!setup.Available || !setup.HasSource || setup.PublishedWorkersRoot is not null) return null;

    var projects = new List<string>();
    var workers = Path.Combine(setup.SolutionRoot, "workers");
    if (Directory.Exists(workers))
      projects.AddRange(Directory.EnumerateDirectories(workers)
        .Where(directory => Directory.EnumerateFiles(directory, "*.csproj").Any())
        .Where(directory => !Path.GetFileName(directory).Equals("PIM.AutomationHost", StringComparison.OrdinalIgnoreCase)));
    var selfTest = Path.Combine(setup.SolutionRoot, "tests", "PIM.SelfTest.Nightly");
    if (Directory.Exists(selfTest)) projects.Add(selfTest);

    var watch = System.Diagnostics.Stopwatch.StartNew();
    var failed = new List<string>();
    foreach (var project in projects)
    {
      if (cancellationToken.IsCancellationRequested) return null;
      var lines = new List<string>();
      try
      {
        var step = new WorkerLaunchStep("dotnet", ["build", project, "-v", "q", "--nologo"], setup.SolutionRoot, $"dotnet build {Path.GetFileName(project)}", null);
        var exitCode = await WorkerProcess.RunAsync(step, new Dictionary<string, string> { ["DOTNET_NOLOGO"] = "1" }, lines.Add, _ => { }, cancellationToken);
        if (exitCode != 0)
        {
          failed.Add(Path.GetFileName(project));
          log($"Gradnja {Path.GetFileName(project)} ni uspela: {string.Join(" | ", lines.TakeLast(5))}");
        }
      }
      catch (Exception exception) when (exception is System.ComponentModel.Win32Exception or InvalidOperationException or IOException)
      {
        failed.Add(Path.GetFileName(project));
        log($"Gradnje {Path.GetFileName(project)} ni bilo mogoče zagnati: {exception.Message}");
      }
    }
    watch.Stop();
    return failed.Count == 0
      ? $"Workerji zgrajeni ob zagonu ({projects.Count} projektov, {(int)watch.Elapsed.TotalSeconds} s); posli tečejo z dotnet run --no-build."
      : $"Gradnja ob zagonu ni uspela za: {string.Join(", ", failed)} — ti workerji bodo tekli s starim binarnim izpisom ali padli.";
  }
}
