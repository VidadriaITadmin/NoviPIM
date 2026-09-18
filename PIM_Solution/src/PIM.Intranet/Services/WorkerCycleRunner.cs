using System.Globalization;
using PIM.Operations;

namespace PIM.Intranet.Services;

/// <param name="FailedGroups">Padle skupine korakov; to je izhodna koda cikla (isto kot v skriptah).</param>
public sealed record CycleOutcome(int FailedGroups, int StepsTotal, int StepsFailed, string Summary);

/// <summary>
/// Izvede en cikel v procesu intraneta: sestavi okolje (podjetja, mape) iz baze in diska, dobi načrt
/// iz <see cref="WorkerCycles.Plan"/> in požene korak za korakom — proces workerja, SQL ukaz ali
/// zapis. Vsak korak gre v dnevnik zagona (isto besedilo kot iz skript, da razvrstitev vrstic in
/// filter »samo napake« delata naprej) in v ops.WorkerCycleStep, tek pa utripa v ops.WorkerCycleRun.
///
/// Pravila iz skript, ki jih ta razred ohranja: padec enega koraka ne ustavi ostalih skupin; znotraj
/// skupine se po padcu preostali koraki preskočijo; izhodna koda je število padlih skupin; workerji
/// dobijo isto povezavo kot intranet in PIM_TRIGGERED_BY, da je v ops.PipelineRun vidno, kdo je zagon
/// sprožil.
/// </summary>
public sealed class WorkerCycleRunner(WorkerSchedulerStore store, IConfiguration configuration, ILogger<WorkerCycleRunner> logger)
{
  /// <summary>Nočni tok kliče SAOP za štiri podjetja hkrati (Nocno-vse.ps1 -HkratnihPodjetij 4).</summary>
  const int MaxParallel = 4;

  public async Task<CycleOutcome> RunAsync(
    WorkerRun run, WorkerCycleDefinition cycle, CycleOptions options, WorkerConsoleSetup setup,
    Action<string> write, CancellationToken cancellationToken)
  {
    var environment = await BuildEnvironmentAsync(setup, cancellationToken);
    write($"Podjetja: {string.Join(", ", environment.Organizations)} · prevzem: {environment.LandingRoot} · "
      + $"izvoz: {environment.ExportRoot ?? "ob korenu (register EXPORT_ROOT ni nastavljen)"} · "
      + (setup.PublishedWorkersRoot is { } published ? $"objavljeni workerji: {published}" : $"izvorna koda: {setup.SolutionRoot}"));

    // Izključitev avtomatike ni prazna konfiguracija workerja: prazen seznam bi večina workerjev
    // razumela kot »vsa podjetja«. Cikel zato jasno končamo brez klica navzven.
    if (environment.Organizations.Count == 0 && cycle.Key is not WorkerCycles.Nadzor)
    {
      write("PRESKOČENO: nobeno aktivno podjetje ni vključeno v avtomatiko.");
      return new(0, 0, 0, "Preskočeno: vsa podjetja so izključena iz avtomatike.");
    }

    if (cycle.Key == WorkerCycles.NocniTok)
    {
      // Varovalka: dva zajema se ne smeta prekrivati (glej Nocno-vse.ps1 in CountIngestRunsAsync).
      var (live, orphans) = await store.CountIngestRunsAsync(6, cancellationToken);
      if (live > 0)
      {
        write($"PRESKOČENO: {live} živ zajem(ov) še teče (utrip mlajši od 15 minut). Nocojšnji zagon se ne začne.");
        return new(0, 0, 0, "Preskočeno: živ zajem še teče.");
      }
      if (orphans > 0)
        write($"OPOZORILO: v ops.PipelineRun je {orphans} zagon(ov) v stanju Running brez konca, starejših od ure. Ne blokirajo, so pa rep prejšnjih padcev.");
      write($"Začetek nočnega toka: {(environment.IsFullCatalogDay ? "POLN" : "delta")} zajem, podjetja: {string.Join(", ", environment.Organizations)}.");
    }

    var groups = WorkerCycles.Plan(cycle.Key, options, environment);
    var childEnvironment = ChildEnvironment(run);

    var failedGroups = 0;
    var stepsTotal = 0;
    var stepsFailed = 0;
    var order = 0;
    var completed = new List<string>();
    var failed = new List<string>();

    // Utrip med dolgim korakom (validacija celega podjetja traja minute): brez njega bi drug
    // gostitelj tek po pol ure razglasil za zapuščenega.
    using var heartbeat = new CancellationTokenSource();
    var heartbeatTask = run.CycleRunId is { } runId ? PulseAsync(runId, run, heartbeat.Token) : Task.CompletedTask;

    try
    {
      foreach (var group in groups)
      {
        if (cancellationToken.IsCancellationRequested) break;
        write($"== {group.Name} ==");
        run.CurrentStep = group.Name;
        var watch = System.Diagnostics.Stopwatch.StartNew();
        var groupFailed = false;
        string? failure = null;

        var queue = new Queue<CycleStep>(group.Steps);
        while (queue.Count > 0)
        {
          if (cancellationToken.IsCancellationRequested) break;
          var step = queue.Dequeue();

          // Razgrnitev: koraki, ki jih je mogoče določiti šele zdaj (datoteke po prevzemu), gredo
          // na začetek vrste, da vrstni red ostane tak, kot bi ga zapisala skripta.
          if (step.Kind == CycleStepKind.Expand)
          {
            var expanded = step.Expand!();
            queue = new Queue<CycleStep>(expanded.Concat(queue));
            continue;
          }

          order++;
          stepsTotal++;
          var started = DateTime.UtcNow;
          int? exitCode = null;
          string status;
          string? note = null;

          switch (step.Kind)
          {
            case CycleStepKind.Note:
              write($"   {step.Command}");
              status = "Skipped";
              note = step.Command;
              break;

            case CycleStepKind.Sql:
              try
              {
                await store.ExecuteSqlStepAsync(step.Sql!, step.OrganizationId, cancellationToken);
                write($"   {step.Name}: opravljeno.");
                status = "Succeeded";
                exitCode = 0;
              }
              catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
              {
                status = "Cancelled";
                break;
              }
              catch (Exception exception)
              {
                note = exception.Message;
                write($"   NAPAKA: {step.Name}: {exception.Message}");
                status = "Failed";
                exitCode = 1;
              }
              break;

            default:
              exitCode = await RunProcessAsync(run, step, childEnvironment, write, cancellationToken);
              status = cancellationToken.IsCancellationRequested ? "Cancelled" : exitCode == 0 ? "Succeeded" : "Failed";
              if (status == "Failed")
              {
                note = $"izhodna koda {exitCode}";
                write($"   NAPAKA: {step.Name} je končal z izhodno kodo {exitCode}.");
              }
              break;
          }

          if (run.CycleRunId is { } id)
          {
            try { await store.RecordStepAsync(id, order, step.Name, step.OrganizationId, step.Command, started, DateTime.UtcNow, exitCode, status, note, CancellationToken.None); }
            catch (Exception exception) { logger.LogWarning(exception, "Koraka {Step} ni bilo mogoče zapisati v ops.WorkerCycleStep.", step.Name); }
          }

          if (status == "Failed")
          {
            stepsFailed++;
            groupFailed = true;
            failure = note ?? step.Name;
            // Padec enega koraka preskoči preostale v isti skupini — isto kot throw v skriptinem Korak.
            break;
          }
          if (status == "Cancelled") break;
        }

        watch.Stop();
        if (cancellationToken.IsCancellationRequested)
        {
          write($"   ustavljeno: {group.Name}");
          break;
        }
        if (groupFailed)
        {
          failedGroups++;
          failed.Add(group.Name);
          write($"   NAPAKA v koraku '{group.Name}' po {(int)watch.Elapsed.TotalSeconds} s: {failure}");
        }
        else
        {
          completed.Add(group.Name);
          write($"   konec: {group.Name} ({(int)watch.Elapsed.TotalSeconds} s)");
        }
      }
    }
    finally
    {
      heartbeat.Cancel();
      try { await heartbeatTask; } catch (OperationCanceledException) { }
      run.CurrentStep = null;
    }

    if (cycle.Key == WorkerCycles.NocniTok && !cancellationToken.IsCancellationRequested)
    {
      // Povzetek pove tudi, kaj je ostalo neobdelano — sicer je »vse OK« lahko pomenilo, da so koraki
      // tekli, podatek pa je ostal ležati v raw.Inbox (Nocno-vse.ps1).
      try
      {
        var (pending, quarantined) = await store.RawInboxCountsAsync(cancellationToken);
        write("");
        write($"POVZETEK: opravljenih {completed.Count}, padlih {failed.Count}.");
        write($"   raw.Inbox: Pending {pending}, Quarantined {quarantined}.");
        if (pending > 0) write("   OPOZORILO: nekaj strani je ostalo nepreslikanih. Poglej raw.Inbox.FailureReason.");
        foreach (var name in completed) write($"   OK    {name}");
        foreach (var name in failed) write($"   PADEL {name}");
      }
      catch (Exception exception) { write($"OPOZORILO: povzetka raw.Inbox ni mogoče prebrati: {exception.Message}"); }
    }

    write($"{cycle.Label} koncan; padlih korakov: {failedGroups}.");
    var summary = failedGroups == 0
      ? $"Opravljenih skupin: {completed.Count}, korakov: {stepsTotal}."
      : $"Padle skupine: {string.Join(", ", failed)}.";
    return new(failedGroups, stepsTotal, stepsFailed, summary);
  }

  /// <summary>
  /// Kar mora otrok vedeti: isto povezavo kot intranet (da piše v bazo, ki jo stran kaže), kdo ga je
  /// sprožil, in nič od gostiteljevih spremenljivk (glej <see cref="WorkerJobs.IsInheritedHostVariable"/>).
  /// </summary>
  Dictionary<string, string> ChildEnvironment(WorkerRun run)
  {
    var environment = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
    {
      ["PIM_TRIGGERED_BY"] = run.TriggeredBy,
      ["DOTNET_NOLOGO"] = "1",
    };
    if (ConnectionStringResolver.Resolve(configuration) is { Length: > 0 } connectionString)
      environment[LocalSettings.ConnectionVariable] = connectionString;
    return environment;
  }

  static async Task<int> RunProcessAsync(
    WorkerRun run, CycleStep step, IReadOnlyDictionary<string, string> baseEnvironment, Action<string> write, CancellationToken cancellationToken)
  {
    var environment = new Dictionary<string, string>(baseEnvironment, StringComparer.OrdinalIgnoreCase);
    if (step.Environment is { } extra)
      foreach (var (name, value) in extra) environment[name] = value;

    try
    {
      return await WorkerProcess.RunAsync(step.Process!, environment, line => write("   " + line), process => run.CurrentProcess = process, cancellationToken);
    }
    catch (Exception exception) when (exception is System.ComponentModel.Win32Exception or InvalidOperationException or IOException)
    {
      write($"   NAPAKA: procesa ni bilo mogoče zagnati ({step.Process!.FileName}): {exception.Message}");
      return -1;
    }
  }

  async Task PulseAsync(long runId, WorkerRun run, CancellationToken cancellationToken)
  {
    using var timer = new PeriodicTimer(TimeSpan.FromSeconds(60));
    try
    {
      while (await timer.WaitForNextTickAsync(cancellationToken))
      {
        try { await store.HeartbeatAsync(runId, run.CurrentStep, cancellationToken); }
        catch (OperationCanceledException) { throw; }
        catch (Exception exception) { logger.LogWarning(exception, "Utrip zagona cikla {RunId} ni uspel.", runId); }
      }
    }
    catch (OperationCanceledException) { }
  }

  async Task<CycleEnvironment> BuildEnvironmentAsync(WorkerConsoleSetup setup, CancellationToken cancellationToken)
  {
    var organizations = await store.GetActiveOrganizationsAsync(cancellationToken);

    // Isti vrstni red kot povsod (PIM.Operations.SystemPaths): okolje, register, privzetek. Prevzemnik
    // dobi isto mapo z --target, bralec bere iz nje — zato se ne moreta raziti.
    var exportBase = setup.RepositoryRoot.Length > 0 ? setup.RepositoryRoot : setup.PublishedWorkersRoot ?? AppContext.BaseDirectory;
    var landing = Environment.GetEnvironmentVariable("PIM_FETCH_ROOT");
    if (string.IsNullOrWhiteSpace(landing))
    {
      try { landing = await store.ResolveSystemPathAsync(SystemPaths.Landing, cancellationToken); }
      catch (Exception exception) { logger.LogWarning(exception, "Registra LANDING_ROOT ni mogoče prebrati; velja privzetek."); }
    }
    if (string.IsNullOrWhiteSpace(landing))
      landing = Path.Combine(setup.SolutionRoot.Length > 0 ? setup.SolutionRoot : exportBase, "data", "prevzem");

    var export = Environment.GetEnvironmentVariable("PIM_EXPORT_ROOT");
    if (string.IsNullOrWhiteSpace(export))
    {
      try { export = await store.ResolveSystemPathAsync(SystemPaths.Export, cancellationToken); }
      catch (Exception exception) { logger.LogWarning(exception, "Registra EXPORT_ROOT ni mogoče prebrati; velja privzetek."); }
    }

    var paths = new WorkerPaths(
      setup.RepositoryRoot, setup.SolutionRoot,
      worker => WorkerConsoleLayout.PublishedWorker(setup.PublishedWorkersRoot, worker),
      organizationId => Path.Combine(exportBase, "izvoz", "magento", organizationId.ToString(CultureInfo.InvariantCulture)),
      setup.PublishedWorkersRoot);

    return new(
      paths, organizations, WorkerCycles.CatalogOrganization, landing,
      string.IsNullOrWhiteSpace(export) ? null : export,
      setup.SolutionRoot.Length > 0 ? Path.Combine(setup.SolutionRoot, "fixtures") : null,
      PimTime.Local(DateTime.UtcNow).Day == 1, MaxParallel,
      Directory.Exists, ListFiles);
  }

  /// <summary>Datoteke v mapi brez oznak prevzema (.prenos, .pocakaj) in Excelovih zaklepov — isti filter kot v skriptah.</summary>
  static IReadOnlyList<string> ListFiles(string directory)
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
}
