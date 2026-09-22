using System.Globalization;
using PIM.Automation;

namespace PIM.AutomationHost;

/// <summary>
/// Gostujoča storitev: sestavi nastavitve, postavitev in mapo dnevnikov, nato preda delo motorju
/// (<see cref="AutomationEngine"/>). Piše dnevnik gostitelja v <c>&lt;dnevniki&gt;\gostitelj\gostitelj-&lt;datum&gt;.log</c>
/// in v ILogger (pod storitvijo Windows dnevnik dogodkov, v konzoli zaslon).
/// </summary>
public sealed class AutomationHostService(
  HostArguments mode, HostConnection connection, IConfiguration configuration,
  IHostApplicationLifetime lifetime, ILogger<AutomationHostService> logger) : BackgroundService
{
  readonly object gate = new();
  StreamWriter? hostLog;
  string? hostLogDate;
  string logRoot = "";
  TimeZoneInfo zone = TimeZoneInfo.Utc;

  protected override async Task ExecuteAsync(CancellationToken stoppingToken)
  {
    zone = AutomationEnvironment.ResolveZone(configuration["Pim:TimeZone"]);
    var store = new AutomationStore(connection.ConnectionString);

    var repositoryRoot = Empty(configuration["Automation:RepositoryRoot"]);
    var publishedRoot = Empty(configuration["Automation:PublishedWorkersRoot"]);
    var configuredLogRoot = Empty(configuration["Automation:LogRoot"]);
    var setup = AutomationEnvironment.ResolveSetup(repositoryRoot, publishedRoot, configuredLogRoot, AppContext.BaseDirectory);

    string? logNote = null;
    try
    {
      (logRoot, logNote) = await AutomationEnvironment.PrepareLogRootAsync(store, setup, configuredLogRoot is not null, stoppingToken);
    }
    catch (OperationCanceledException) { return; }
    catch (Exception exception)
    {
      logger.LogWarning(exception, "Mape dnevnikov ni bilo mogoče pripraviti; velja začasna mapa.");
      logRoot = Path.Combine(Path.GetTempPath(), "PIM", "logs");
    }
    Log(logNote ?? $"Dnevniki: {logRoot}");

    var options = new AutomationOptions(
      connection.IsWindowsService ? AutomationApplications.Service : AutomationApplications.Console,
      zone, logRoot,
      TickSeconds: configuration.GetValue<int?>("Automation:TickSeconds") ?? 15,
      LeaseSeconds: configuration.GetValue<int?>("Automation:LeaseSeconds") ?? 90,
      MaxConcurrentJobs: configuration.GetValue<int?>("Automation:MaxConcurrentJobs") ?? 3,
      StaleMinutes: configuration.GetValue<int?>("Automation:StaleMinutes") ?? 10,
      MaxParallel: configuration.GetValue<int?>("Automation:MaxParallel") ?? 4,
      AllowedJobs: mode.AllowedJobs,
      MonitorOnly: mode.MonitorOnly,
      RunOnceJob: mode.RunOnceJob);

    if (mode.RunOnceJob is { } once && JobCatalog.Find(once) is null)
    {
      Log($"NAPAKA: posel {once} ne obstaja. Znani posli: {string.Join(", ", JobCatalog.All.Select(job => job.Key))}");
      Environment.ExitCode = 4;
      lifetime.StopApplication();
      return;
    }

    var engine = new AutomationEngine(store, setup, options, Log, (message, exception) => Warn(message, exception));
    try
    {
      await engine.RunAsync(stoppingToken);
    }
    catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { }
    catch (Exception exception)
    {
      Warn("Motor gostitelja se je ustavil z napako.", exception);
      Environment.ExitCode = 1;
    }

    if (mode.RunOnceJob is not null)
    {
      var status = engine.Status;
      Environment.ExitCode = status.RunOnceExitCode ?? 1;
      Log($"Enkratni zagon {mode.RunOnceJob} končan; izhod {Environment.ExitCode}.");
      lifetime.StopApplication();
    }
    Log("Gostitelj se je ustavil.");
    lock (gate) { hostLog?.Dispose(); hostLog = null; }
  }

  static string? Empty(string? value) => string.IsNullOrWhiteSpace(value) ? null : value;

  void Log(string message)
  {
    logger.LogInformation("{Message}", message);
    WriteHostLog(message);
  }

  void Warn(string message, Exception? exception)
  {
    if (exception is null) logger.LogWarning("{Message}", message);
    else logger.LogWarning(exception, "{Message}", message);
    WriteHostLog($"OPOZORILO: {message}{(exception is null ? "" : $" — {exception.Message}")}");
  }

  /// <summary>Dnevnik gostitelja po dnevih; na strežniku brez konzole je to edino mesto, kjer se vidi, kaj je ura delala.</summary>
  void WriteHostLog(string message)
  {
    if (logRoot.Length == 0) return;
    var local = TimeZoneInfo.ConvertTimeFromUtc(DateTime.UtcNow, zone);
    var date = local.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
    lock (gate)
    {
      try
      {
        if (hostLog is null || hostLogDate != date)
        {
          hostLog?.Dispose();
          var folder = Path.Combine(logRoot, "gostitelj");
          Directory.CreateDirectory(folder);
          hostLog = new StreamWriter(new FileStream(Path.Combine(folder, $"gostitelj-{date}.log"), FileMode.Append, FileAccess.Write, FileShare.Read),
            new System.Text.UTF8Encoding(false)) { AutoFlush = true };
          hostLogDate = date;
        }
        hostLog.WriteLine($"{local.ToString("HH:mm:ss", CultureInfo.InvariantCulture)}  {message}");
      }
      catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
      {
        logger.LogWarning(exception, "Dnevnika gostitelja ni mogoče pisati.");
        hostLog = null;
      }
    }
  }
}
