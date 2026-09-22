using System.Diagnostics;
using System.Globalization;
using PIM.Operations;

namespace PIM.Automation;

/// <param name="Status">Eno od končnih stanj <see cref="JobRunStatus"/> (brez Running in Blocked — blokado zapiše ops.ClaimJobRun).</param>
public sealed record JobRunOutcome(string Status, int ExitCode, int StepsTotal, int StepsFailed, int StepsBlocked, int ErrorLines, string Summary);

/// <summary>
/// Izvede en zagon posla: skupina za skupino, korak za korakom — proces workerja, SQL ukaz ali zapis.
/// Vsak korak gre v dnevnik zagona in v ops.JobStepRun, tek pa utripa v ops.JobRun.
///
/// Pravila, ki jih ta razred uveljavlja (zahteva 2026-09-21):
///   - časovna meja: ob preseženi meji se drevo procesov ubije in zagon konča kot TimedOut, ne kot večni Running;
///   - ustavitev: zahtevo iz konzole (ops.RequestJobCancel) izve ob utripu in tek ustavi kot Cancelled;
///   - odvisni koraki: skupina z RequiresAllPrevious se po padli skupini ne izvede — koraki so Blocked;
///   - padec enega koraka v skupini preskoči preostale v isti skupini (kot doslej), ne pa naslednjih skupin,
///     razen če te zahtevajo uspeh vseh prejšnjih.
///
/// Dodano v bloku 2 prenove nadzora (2026-09-22), ker »korak, ki ga ni bilo«, ni smel biti neviden:
///   - preskočeni koraki za padlim korakom se zapišejo kot Blocked z razlogom, ne izginejo;
///   - opomba padlega koraka nosi zadnjo vrstico z napako, ne samo izhodne kode;
///   - vsak otroški proces dobi PIM_JOB_RUN_ID in PIM_JOB_STEP_ORDER, da svoje faze (ops.JobPhaseRun)
///     poveže s tem zagonom in korakom.
/// </summary>
public sealed class JobRunner(AutomationStore store, Action<string, Exception?> warn)
{
  /// <param name="write">Vrstica dnevnika (datoteka in izpis); vrstice z napako se štejejo.</param>
  /// <param name="onProcess">Kdo drži otroški proces, da ga ustavitev lahko ubije.</param>
  /// <param name="hostStopping">Gostitelj se ustavlja: tek konča kot Cancelled.</param>
  public async Task<JobRunOutcome> RunAsync(
    JobDefinitionRow job, long jobRunId, IReadOnlyList<CycleGroup> groups, IReadOnlyDictionary<string, string> childEnvironment,
    Action<string> write, Action<Process?> onProcess, CancellationToken hostStopping)
  {
    var errorLines = 0;
    void Log(string text)
    {
      if (WorkerLogs.Classify(text) == LogLineTone.Error) errorLines++;
      write(text);
    }

    using var cancel = CancellationTokenSource.CreateLinkedTokenSource(hostStopping);
    using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(Math.Max(30, job.TimeoutSeconds)));
    using var combined = CancellationTokenSource.CreateLinkedTokenSource(cancel.Token, deadline.Token);
    var token = combined.Token;
    string? cancelledBy = null;
    string? currentStep = null;

    // Utrip med dolgim korakom (validacija celega podjetja traja minute): brez njega bi gostitelj tek po
    // desetih minutah razglasil za zapuščenega. Isti klic pove, ali je kdo zahteval ustavitev.
    using var heartbeatStop = new CancellationTokenSource();
    var heartbeat = Task.Run(async () =>
    {
      using var timer = new PeriodicTimer(TimeSpan.FromSeconds(30));
      try
      {
        while (await timer.WaitForNextTickAsync(heartbeatStop.Token))
        {
          try
          {
            var (requested, by) = await store.HeartbeatAsync(jobRunId, currentStep, heartbeatStop.Token);
            if (requested && cancelledBy is null)
            {
              cancelledBy = by ?? "konzola";
              Log($"=== ustavitev zahteval: {cancelledBy}");
              cancel.Cancel();
            }
          }
          catch (OperationCanceledException) { throw; }
          catch (Exception exception) { warn($"Utrip zagona {jobRunId} ni uspel.", exception); }
        }
      }
      catch (OperationCanceledException) { }
    });

    var failedGroups = new List<string>();
    var blockedGroups = new List<string>();
    var completedGroups = new List<string>();
    var stepsTotal = 0;
    var stepsFailed = 0;
    var stepsBlocked = 0;
    var order = 0;

    try
    {
      foreach (var group in groups)
      {
        if (token.IsCancellationRequested) break;
        Log($"== {group.Name} ==");
        currentStep = group.Name;
        var watch = Stopwatch.StartNew();

        // Odvisna skupina po padlem obveznem koraku: koraki so zapisani kot Blocked in se ne izvedejo.
        if (group.RequiresAllPrevious && failedGroups.Count > 0)
        {
          var reason = $"Blokirano: padla skupina '{failedGroups[^1]}'.";
          foreach (var step in Expand(group.Steps))
          {
            order++;
            stepsTotal++;
            stepsBlocked++;
            Log($"   BLOKIRANO: {step.Name} — {reason}");
            await RecordAsync(jobRunId, order, step, DateTime.UtcNow, DateTime.UtcNow, null, JobStepStatus.Blocked, reason);
          }
          blockedGroups.Add(group.Name);
          Log($"   blokirano: {group.Name}");
          continue;
        }

        var groupFailed = false;
        string? failure = null;
        var queue = new Queue<CycleStep>(group.Steps);
        while (queue.Count > 0)
        {
          if (token.IsCancellationRequested) break;
          var step = queue.Dequeue();
          if (step.Kind == CycleStepKind.Expand)
          {
            queue = new Queue<CycleStep>(step.Expand!().Concat(queue));
            continue;
          }

          order++;
          stepsTotal++;
          var started = DateTime.UtcNow;
          int? exitCode = null;
          string status;
          string? note = null;
          currentStep = step.Name;

          switch (step.Kind)
          {
            case CycleStepKind.Note:
              Log($"   {step.Command}");
              status = JobStepStatus.Skipped;
              note = step.Command;
              break;

            case CycleStepKind.Sql:
              // Faza IZRACUN (blok 6 prenove nadzora): SQL korak teče v gostitelju, zato ga poveže s tekom
              // in korakom sam (PhaseLog.ForJob), ne prek okolja. Pisec pogoltne napake baze in teka ne podre;
              // brez žetona teka, da ustavitev ne pusti faze brez konca.
              var phases = PhaseLog.ForJob(store.ConnectionString, $"{Environment.MachineName}:{Environment.ProcessId}",
                jobRunId, order, line => write("   " + line));
              var phaseSource = SqlPhaseSource(step, job.JobKey);
              var counted = phaseSource is "VALIDACIJA" or "OBJAVA";
              var before = counted ? await TryReadCountsAsync(step.OrganizationId, Log, token) : null;
              await using (var faza = await phases.BeginAsync(PhaseCodes.Compute, phaseSource, step.OrganizationId, job.JobKey,
                message: step.Command))
              {
                try
                {
                  await store.ExecuteSqlStepAsync(step.Sql!, step.OrganizationId, Math.Max(60, job.TimeoutSeconds), token);
                  Log($"   {step.Name}: opravljeno.");
                  status = JobStepStatus.Succeeded;
                  exitCode = 0;
                }
                catch (OperationCanceledException) when (token.IsCancellationRequested)
                {
                  status = deadline.IsCancellationRequested ? JobStepStatus.TimedOut : JobStepStatus.Cancelled;
                }
                catch (Exception exception)
                {
                  note = exception.Message;
                  Log($"   NAPAKA: {step.Name}: {exception.Message}");
                  status = JobStepStatus.Failed;
                  exitCode = 1;
                }

                // Faza se zapre šele po izidu koraka, zunaj try: zapis faze ne sme nikoli spremeniti izida koraka.
                if (status == JobStepStatus.Succeeded)
                {
                  // Števila po koraku: »opravljeno« brez njih je objavo 0 artiklov kazalo enako zeleno kot objavo tisočih.
                  var after = counted ? await TryReadCountsAsync(step.OrganizationId, Log, token) : null;
                  var izid = SqlPhaseResult(phaseSource, step.Name, before, after);
                  await faza.SucceededAsync(izid.ItemsIn, izid.ItemsOut, izid.ItemsRejected, hasNewData: izid.HasNewData, message: izid.Message);
                }
                else
                  await faza.FailedAsync(status switch
                  {
                    JobStepStatus.TimedOut => $"presežena časovna meja {job.TimeoutSeconds} s",
                    JobStepStatus.Cancelled => "ustavljeno med izvajanjem",
                    _ => note ?? $"{step.Name}: napaka",
                  });
              }
              break;

            default:
              var (processExit, lastError) = await RunProcessAsync(step, childEnvironment, jobRunId, order, Log, onProcess, token);
              exitCode = processExit;
              status = token.IsCancellationRequested
                ? deadline.IsCancellationRequested ? JobStepStatus.TimedOut : JobStepStatus.Cancelled
                : exitCode == 0 ? JobStepStatus.Succeeded : JobStepStatus.Failed;
              if (status == JobStepStatus.Failed)
              {
                // Zadnja vrstica z napako, ne samo izhodna koda: brez nje je bilo na strani videti
                // le "izhodna koda 1", vzrok pa samo v datoteki dnevnika.
                note = lastError is { Length: > 0 } ? $"izhodna koda {exitCode}: {lastError}" : $"izhodna koda {exitCode}";
                Log($"   NAPAKA: {step.Name} je končal z izhodno kodo {exitCode}.");
              }
              else if (status == JobStepStatus.TimedOut)
              {
                note = $"presežena časovna meja {job.TimeoutSeconds} s";
                Log($"   NAPAKA: {step.Name} je presegel časovno mejo posla ({job.TimeoutSeconds} s); proces je ubit.");
              }
              break;
          }

          await RecordAsync(jobRunId, order, step, started, DateTime.UtcNow, exitCode, status, note);

          if (status == JobStepStatus.Failed)
          {
            stepsFailed++;
            groupFailed = true;
            failure = note ?? step.Name;

            // Preostali koraki iste skupine se ne izvedejo — a morajo biti VIDNI. Doslej za njimi ni
            // ostala nobena vrstica v ops.JobStepRun, zato je bilo na strani videti le manjkajoče
            // korake (uporabnik 2026-09-22: »štirje koraki v enem workerju, pa se ti ne delajo«).
            var razlog = $"Preskočeno: v isti skupini je padel korak »{step.Name}«.";
            foreach (var preskocen in Expand(queue))
            {
              order++;
              stepsTotal++;
              stepsBlocked++;
              Log($"   BLOKIRANO: {preskocen.Name} — {razlog}");
              await RecordAsync(jobRunId, order, preskocen, DateTime.UtcNow, DateTime.UtcNow, null, JobStepStatus.Blocked, razlog);
            }
            queue.Clear();
            break; // padec preskoči preostale korake v isti skupini
          }
          if (status is JobStepStatus.Cancelled or JobStepStatus.TimedOut) break;
        }

        watch.Stop();
        if (token.IsCancellationRequested)
        {
          Log($"   ustavljeno: {group.Name}");
          break;
        }
        if (groupFailed)
        {
          failedGroups.Add(group.Name);
          Log($"   NAPAKA v skupini '{group.Name}' po {(int)watch.Elapsed.TotalSeconds} s: {failure}");
        }
        else
        {
          completedGroups.Add(group.Name);
          Log($"   konec: {group.Name} ({(int)watch.Elapsed.TotalSeconds} s)");
        }
      }
    }
    finally
    {
      heartbeatStop.Cancel();
      try { await heartbeat; } catch (OperationCanceledException) { }
      currentStep = null;
    }

    string finalStatus;
    string summary;
    if (deadline.IsCancellationRequested)
    {
      finalStatus = JobRunStatus.TimedOut;
      summary = $"Presežena časovna meja {job.TimeoutSeconds} s pri skupini '{groups.FirstOrDefault(g => !completedGroups.Contains(g.Name) && !failedGroups.Contains(g.Name))?.Name ?? "?"}'. Opravljenih skupin: {completedGroups.Count}.";
    }
    else if (token.IsCancellationRequested)
    {
      finalStatus = JobRunStatus.Cancelled;
      summary = cancelledBy is null ? "Ustavljeno: gostitelj se je ustavil med tekom." : $"Ustavil: {cancelledBy}.";
    }
    else if (failedGroups.Count > 0 && completedGroups.Count > 0 && blockedGroups.Count == 0)
    {
      // Delni padec (npr. eno od treh podjetij): posel ni Failed, sicer bi odlog po napakah upočasnil
      // zdrava podjetja in uspeh ne bi sprožil odvisnih (izvoz cen in zaloge). Padla skupina ostane
      // zapisana v povzetku, koraku (ops.JobStepRun) in v ops.PipelineRun workerja za to podjetje.
      finalStatus = JobRunStatus.Warning;
      summary = $"Delno: padle skupine: {string.Join(", ", failedGroups)}. Uspelih skupin: {completedGroups.Count}.";
    }
    else if (failedGroups.Count > 0)
    {
      finalStatus = JobRunStatus.Failed;
      summary = $"Padle skupine: {string.Join(", ", failedGroups)}."
        + (blockedGroups.Count > 0 ? $" Blokirane: {string.Join(", ", blockedGroups)}." : "");
    }
    else
    {
      finalStatus = JobRunStatus.Succeeded;
      summary = $"Opravljenih skupin: {completedGroups.Count}, korakov: {stepsTotal}.";
    }

    Log($"{job.Label} končan: {finalStatus}; padlih skupin: {failedGroups.Count}, blokiranih: {blockedGroups.Count}.");
    var exit = finalStatus == JobRunStatus.Succeeded ? 0
      : finalStatus is JobRunStatus.Failed or JobRunStatus.Warning ? Math.Max(1, failedGroups.Count) : -1;
    return new(finalStatus, exit, stepsTotal, stepsFailed, stepsBlocked, errorLines, summary);
  }

  /// <summary>
  /// SourceCode faze SQL koraka (blok 6): VALIDACIJA ali OBJAVA po imenu oziroma ukazu koraka, sicer ključ
  /// posla. Isti niz v validaciji in nočni uskladitvi, da stran Nadzor obe pokaže kot isti vir.
  /// </summary>
  public static string SqlPhaseSource(CycleStep step, string jobKey)
  {
    var besedilo = $"{step.Name} {step.Command} {string.Join(" ", step.Sql ?? [])}";
    if (step.Name.StartsWith("Validacija", StringComparison.OrdinalIgnoreCase)
      || besedilo.Contains("val.RunValidation", StringComparison.OrdinalIgnoreCase)) return "VALIDACIJA";
    if (step.Name.StartsWith("Objava", StringComparison.OrdinalIgnoreCase)
      || besedilo.Contains("val.Promote", StringComparison.OrdinalIgnoreCase)) return "OBJAVA";
    return jobKey;
  }

  /// <summary>
  /// Izid faze IZRACUN SQL koraka iz stanja kataloga pred in po koraku (čista funkcija, test brez baze).
  /// Validacija ima nove podatke le, če se je spremenilo število veljavnih ali neveljavnih artiklov; objava,
  /// če je objavila vsaj en artikel (val.Promote vsakič osveži vse veljavne). Brez števil (branje ni uspelo
  /// ali drug SQL korak) ostane stari izid »opravljeno« z novimi podatki.
  /// </summary>
  public static (long? ItemsIn, long? ItemsOut, long? ItemsRejected, bool HasNewData, string Message) SqlPhaseResult(
    string phaseSource, string stepName, CatalogCounts? before, CatalogCounts? after)
  {
    static string N(long value) => value.ToString("N0", CultureInfo.GetCultureInfo("sl-SI"));
    if (after is null) return (null, null, null, true, $"{stepName}: opravljeno");

    if (phaseSource == "VALIDACIJA")
    {
      var changed = before is null || before.Valid != after.Valid || before.Invalid != after.Invalid;
      var prej = before is null ? "" : $" (prej {N(before.Valid)} / {N(before.Invalid)})";
      return (after.Valid + after.Invalid, after.Valid, after.Invalid, changed,
        changed
          ? $"{stepName}: veljavnih {N(after.Valid)}, neveljavnih {N(after.Invalid)}{prej}"
          : $"{stepName}: brez sprememb — veljavnih {N(after.Valid)}, neveljavnih {N(after.Invalid)}");
    }

    if (phaseSource == "OBJAVA")
    {
      var novih = before is null ? (long?)null : Math.Max(0, after.Published - before.Published);
      return (after.Valid, after.Valid, null, after.Valid > 0,
        after.Valid > 0
          ? $"{stepName}: objavljenih {N(after.Valid)} veljavnih artiklov{(novih is { } n ? $", novih v PIM {N(n)}" : "")}"
          : $"{stepName}: ni veljavnih artiklov za objavo");
    }

    return (null, null, null, true, $"{stepName}: opravljeno");
  }

  // Branje števil ne sme nikoli spremeniti izida koraka: napaka pomeni samo, da faza števil nima.
  async Task<CatalogCounts?> TryReadCountsAsync(int? organizationId, Action<string> write, CancellationToken token)
  {
    try { return await store.ReadCatalogCountsAsync(organizationId, token); }
    catch (Exception exception) when (exception is not OperationCanceledException)
    {
      write($"   [FAZA] opozorilo: števil kataloga ni bilo mogoče prebrati ({exception.GetType().Name}).");
      return null;
    }
    catch (OperationCanceledException) { return null; }
  }

  static IEnumerable<CycleStep> Expand(IEnumerable<CycleStep> steps) =>
    steps.SelectMany(step => step.Kind == CycleStepKind.Expand ? step.Expand!() : [step]);

  async Task RecordAsync(long jobRunId, int order, CycleStep step, DateTime started, DateTime ended, int? exitCode, string status, string? note)
  {
    try { await store.RecordStepAsync(jobRunId, order, step.Name, step.OrganizationId, step.Command, started, ended, exitCode, status, note, CancellationToken.None); }
    catch (Exception exception) { warn($"Koraka {step.Name} ni bilo mogoče zapisati v ops.JobStepRun.", exception); }
  }

  /// <summary>
  /// Požene worker in vrne izhodno kodo ter zadnjo vrstico z napako iz njegovega izpisa.
  ///
  /// Otroku pove, kateremu teku posla in kateremu koraku pripada (<see cref="PhaseLog.JobRunVariable"/>,
  /// <see cref="PhaseLog.StepOrderVariable"/>): worker po tem veže svoje faze (ops.JobPhaseRun) na ta
  /// zagon. Ročni zagon iz ukazne vrstice teh spremenljivk nima in faze zapiše brez teka posla.
  /// </summary>
  static async Task<(int ExitCode, string? LastError)> RunProcessAsync(
    CycleStep step, IReadOnlyDictionary<string, string> baseEnvironment, long jobRunId, int stepOrder,
    Action<string> write, Action<Process?> onProcess, CancellationToken cancellationToken)
  {
    var environment = new Dictionary<string, string>(baseEnvironment, StringComparer.OrdinalIgnoreCase)
    {
      [PhaseLog.JobRunVariable] = jobRunId.ToString(CultureInfo.InvariantCulture),
      [PhaseLog.StepOrderVariable] = stepOrder.ToString(CultureInfo.InvariantCulture),
    };
    if (step.Environment is { } extra)
      foreach (var (name, value) in extra) environment[name] = value;

    string? lastError = null;
    void Line(string line)
    {
      if (WorkerLogs.Classify(line) == LogLineTone.Error && line.Trim() is { Length: > 0 } napaka)
        lastError = napaka.Length <= 400 ? napaka : napaka[..400];
      write("   " + line);
    }

    try
    {
      return (await WorkerProcess.RunAsync(step.Process!, environment, Line, onProcess, cancellationToken), lastError);
    }
    catch (Exception exception) when (exception is System.ComponentModel.Win32Exception or InvalidOperationException or IOException)
    {
      var sporocilo = $"procesa ni bilo mogoče zagnati ({step.Process!.FileName}): {exception.Message}";
      write($"   NAPAKA: {sporocilo}");
      return (-1, sporocilo.Length <= 400 ? sporocilo : sporocilo[..400]);
    }
  }
}
