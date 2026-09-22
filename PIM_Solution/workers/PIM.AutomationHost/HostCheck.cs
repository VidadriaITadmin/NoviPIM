using PIM.Automation;
using PIM.Operations;

namespace PIM.AutomationHost;

/// <summary>
/// Zunanji nadzor (--preveri). Notranji watchdog lahko nadzira posle, ne more pa zanesljivo nadzirati
/// samega sebe: če se gostitelj ustavi, se ustavi tudi nadzor in nihče ne pošlje alarma. Zato ta način
/// teče iz načrtovane naloge Windows (scripts\Namesti-nadzor-avtomatike.ps1) v svojem procesu: prebere
/// najem, ob molku odpre alarm AutomationHostDown (ops.EvaluateJobAlerts), ga uvrsti v vrsto in požene
/// razpošiljalca alarmov, da e-pošta odide tudi takrat, ko gostitelj leži.
/// </summary>
public static class HostCheck
{
  public static async Task<int> RunAsync(string connectionString, int staleMinutes, bool dispatchAlerts)
  {
    var store = new AutomationStore(connectionString);
    SchedulerLeaseInfo? lease;
    try { lease = await store.ReadLeaseAsync(); }
    catch (Exception exception)
    {
      Console.Error.WriteLine($"Baza ni dosegljiva: {exception.Message}");
      return 2;
    }

    var now = DateTime.UtcNow;
    var age = lease is null ? (TimeSpan?)null : now - lease.HeartbeatUtc;
    var alive = lease is not null && lease.IsAutomationHost && age < TimeSpan.FromMinutes(staleMinutes);

    if (alive)
    {
      Console.WriteLine($"Gostitelj avtomatike utripa: {lease!.Owner}, zadnji utrip pred {(int)age!.Value.TotalSeconds} s, tikov {lease.TickCount}.");
      try { await store.EvaluateAlertsAsync("nadzor gostitelja", CancellationToken.None); } catch (Exception exception) { Console.Error.WriteLine($"Ocena alarmov ni uspela: {exception.Message}"); }
      return 0;
    }

    Console.Error.WriteLine(lease is null
      ? "Gostitelj avtomatike ne teče: najema ni."
      : !lease.IsAutomationHost
        ? $"Gostitelj avtomatike ne teče: najem drži {lease.Owner} ({lease.Application})."
        : $"Gostitelj avtomatike molči: zadnji utrip {lease.HeartbeatUtc:yyyy-MM-dd HH:mm:ss} UTC (pred {(int)age!.Value.TotalMinutes} min).");

    try
    {
      await store.EvaluateAlertsAsync("nadzor gostitelja", CancellationToken.None);
      await store.QueueAlertDeliveriesAsync(CancellationToken.None);
      Console.Error.WriteLine("Alarm AutomationHostDown je odprt in uvrščen v vrsto za dostavo.");
    }
    catch (Exception exception) { Console.Error.WriteLine($"Alarma ni bilo mogoče odpreti: {exception.Message}"); }

    if (dispatchAlerts) await DispatchAsync(connectionString);
    return 1;
  }

  /// <summary>Razpošiljalec ob gostitelju (objava) ali iz izvorne kode (razvoj); brez PIM_ALERT_DELIVERY_ENABLED=true sam pove, da ni poslal.</summary>
  static async Task DispatchAsync(string connectionString)
  {
    var baseDirectory = AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
    var published = Path.Combine(Path.GetDirectoryName(baseDirectory) ?? baseDirectory, "PIM.AlertDispatcher", "PIM.AlertDispatcher.exe");
    WorkerLaunchStep step;
    if (File.Exists(published))
      step = new(published, [], Path.GetDirectoryName(published)!, "PIM.AlertDispatcher", null);
    else if (LocalSettings.FindSolutionRoot(baseDirectory) is { } solution)
      step = new("dotnet", ["run", "--project", Path.Combine(solution, "workers", "PIM.AlertDispatcher"), "--no-build"], solution, "dotnet run PIM.AlertDispatcher", null);
    else
    {
      Console.Error.WriteLine("Razpošiljalca alarmov ni ob gostitelju in izvorne kode ni; alarm ostane v vrsti za naslednjega razpošiljalca.");
      return;
    }

    var environment = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
    {
      [LocalSettings.ConnectionVariable] = connectionString,
      ["PIM_TRIGGERED_BY"] = "Task",
      ["DOTNET_NOLOGO"] = "1",
    };
    try
    {
      var exit = await WorkerProcess.RunAsync(step, environment, line => Console.Error.WriteLine("   " + line), _ => { }, CancellationToken.None);
      Console.Error.WriteLine($"Razpošiljalec alarmov je končal z izhodno kodo {exit}.");
    }
    catch (Exception exception) { Console.Error.WriteLine($"Razpošiljalca ni bilo mogoče zagnati: {exception.Message}"); }
  }
}
