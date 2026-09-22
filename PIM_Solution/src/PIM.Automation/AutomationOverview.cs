namespace PIM.Automation;

/// <summary>Stanje poslovne kartice. Vrstni red je vrstni red resnosti.</summary>
public enum FlowState { Ok, Stale, Blocked, Failed, Off, HostDown }

/// <param name="ActionJobKey">Posel, ki ga skrbnik požene kot en jasen ukrep; null, kadar ukrep ni zagon (npr. gostitelj ne teče).</param>
/// <param name="VersionLabel">Kaj splet trenutno uporablja (zadnji artefakt); null, kadar tok nima datoteke.</param>
public sealed record FlowCard(
  string Flow, string Label, string Description, FlowState State, string StateLabel, string Tone,
  DateTime? LastSuccessUtc, string? RunningLabel, DateTime? NextDueUtc,
  string? Cause, string? Consequence, string? ActionJobKey, string? ActionLabel, string? VersionLabel, string ResultJobKey);

/// <summary>
/// Štiri poslovne kartice na pregledu: »Ali poslovanje trenutno deluje in kaj moram narediti?«
/// Čista funkcija nad vrsticami ops.JobDefinition, odvisnostmi, artefakti in stanjem gostitelja, da jo
/// preveri test brez baze. Merilo je rezultat toka (posel z IsFlowResult), ne izhodna koda procesa:
/// starost zadnjega uspeha proti SLA, zadnje stanje, blokada po verigi predhodnikov.
/// </summary>
public static class AutomationOverview
{
  public static IReadOnlyList<FlowCard> Build(
    IReadOnlyList<JobDefinitionRow> jobs, IReadOnlyList<JobDependencyRow> dependencies, IReadOnlyList<ArtifactRow> artifacts,
    AutomationHostRow? host, DateTime nowUtc)
  {
    var hostLive = host?.IsAutomationHostLive == true;
    var cards = new List<FlowCard>();
    foreach (var flow in JobFlows.Cards)
    {
      var inFlow = jobs.Where(job => job.Flow == flow).OrderBy(job => job.SortOrder).ToList();
      var result = inFlow.FirstOrDefault(job => job.IsFlowResult) ?? inFlow.FirstOrDefault();
      if (result is null) continue;

      var running = jobs.FirstOrDefault(job => job.Flow == flow && job.IsRunning)
        ?? Upstream(result.JobKey, jobs, dependencies).FirstOrDefault(job => job.IsRunning);
      var runningLabel = running is null ? null
        : $"{running.Label}{(running.RunningStep is { Length: > 0 } step ? $" · {step}" : "")}{(running.RunningIsStale ? " (brez utripa!)" : "")}";
      var nextDue = inFlow.Where(job => job.IsEnabled && job.NextDueUtc is not null).Select(job => job.NextDueUtc).Min();
      var version = VersionOf(flow, artifacts);

      FlowState state;
      string? cause;
      string? actionJob;
      string? actionLabel;

      if (!hostLive)
      {
        state = FlowState.HostDown;
        cause = host?.HeartbeatUtc is { } beat
          ? $"Gostitelj avtomatike ne utripa od {beat:yyyy-MM-dd HH:mm} UTC (najem: {host.Owner})."
          : "Gostitelj avtomatike (PIM.AutomationHost) ne drži najema.";
        actionJob = null;
        actionLabel = "Preveri storitev PIM.AutomationHost";
      }
      else if (!result.IsEnabled)
      {
        state = FlowState.Off;
        cause = $"Posel »{result.Label}« je izklopljen.";
        actionJob = null;
        actionLabel = $"Vklopi {result.Label} (Opravila)";
      }
      else if (JobRunStatus.IsFailure(result.LastStatus))
      {
        state = FlowState.Failed;
        cause = Cut(result.LastError) ?? $"Zadnji zagon posla »{result.Label}« se je končal s stanjem {result.LastStatus}.";
        actionJob = result.JobKey;
        actionLabel = $"Ponovi {result.Label}";
      }
      else if (result.LastStatus == JobRunStatus.Blocked)
      {
        var blocker = Blocker(result, jobs);
        state = FlowState.Blocked;
        cause = Cut(blocker?.LastError) ?? Cut(result.LastError) ?? $"Predhodnik posla »{result.Label}« ni uspel.";
        actionJob = blocker?.JobKey ?? result.JobKey;
        actionLabel = $"Ponovi {(blocker ?? result).Label}";
      }
      else if (result.LastSucceededUtc is null || (result.SlaSeconds is { } sla && nowUtc - result.LastSucceededUtc.Value > TimeSpan.FromSeconds(sla)))
      {
        state = FlowState.Stale;
        var failedUpstream = Upstream(result.JobKey, jobs, dependencies).FirstOrDefault(job => JobRunStatus.IsFailure(job.LastStatus) || job.LastStatus == JobRunStatus.Blocked);
        cause = failedUpstream is not null
          ? $"{failedUpstream.Label}: {Cut(failedUpstream.LastError) ?? failedUpstream.LastStatus}"
          : result.LastSucceededUtc is null ? $"Posel »{result.Label}« še ni nikoli uspel." : $"Zadnji uspeh posla »{result.Label}« je starejši od SLA ({(result.SlaSeconds ?? 0) / 60} min).";
        actionJob = failedUpstream?.JobKey ?? result.JobKey;
        actionLabel = $"Ponovi {(failedUpstream ?? result).Label}";
      }
      else
      {
        state = FlowState.Ok;
        cause = null;
        actionJob = null;
        actionLabel = null;
      }

      cards.Add(new(flow, JobFlows.Label(flow), JobFlows.Description(flow), state, StateLabel(state), Tone(state),
        result.LastSucceededUtc, runningLabel, nextDue, cause, state == FlowState.Ok ? null : Consequence(flow, result, version), actionJob, actionLabel, version, result.JobKey));
    }
    return cards;
  }

  /// <summary>Predhodniki po verigi odvisnosti (brez ponavljanja), najbližji najprej.</summary>
  public static IReadOnlyList<JobDefinitionRow> Upstream(string jobKey, IReadOnlyList<JobDefinitionRow> jobs, IReadOnlyList<JobDependencyRow> dependencies)
  {
    var result = new List<JobDefinitionRow>();
    var seen = new HashSet<string>(StringComparer.Ordinal) { jobKey };
    var queue = new Queue<string>([jobKey]);
    while (queue.Count > 0)
    {
      var current = queue.Dequeue();
      foreach (var link in dependencies.Where(d => d.JobKey == current))
      {
        if (!seen.Add(link.DependsOnJobKey)) continue;
        var job = jobs.FirstOrDefault(j => j.JobKey == link.DependsOnJobKey);
        if (job is null) continue;
        result.Add(job);
        queue.Enqueue(job.JobKey);
      }
    }
    return result;
  }

  /// <summary>Kdo je blokiral: po verigi LastBlockedByJobKey do prvega, ki ni sam blokiran.</summary>
  static JobDefinitionRow? Blocker(JobDefinitionRow job, IReadOnlyList<JobDefinitionRow> jobs)
  {
    var current = job;
    var hops = 0;
    while (current.LastStatus == JobRunStatus.Blocked && current.LastBlockedByJobKey is { } key && hops++ < 10)
    {
      var next = jobs.FirstOrDefault(j => j.JobKey == key);
      if (next is null) break;
      current = next;
    }
    return current == job ? null : current;
  }

  static string? VersionOf(string flow, IReadOnlyList<ArtifactRow> artifacts)
  {
    var kind = flow switch { JobFlows.WebCatalog => "MAGENTO_PRODUCTS", JobFlows.Stock => "MAGENTO_STOCK_PRICES", _ => null };
    if (kind is null) return null;
    var latest = artifacts.Where(a => a.Kind == kind).OrderByDescending(a => a.ArtifactId).FirstOrDefault();
    return latest is null ? null
      : $"verzija #{latest.ArtifactId} · {latest.FileName} · {latest.RowCountValue?.ToString("N0") ?? "?"} vrstic · {latest.CreatedUtc:yyyy-MM-dd HH:mm} UTC";
  }

  static string Consequence(string flow, JobDefinitionRow result, string? version) => flow switch
  {
    JobFlows.WebCatalog => version is null ? "Splet nima potrjene datoteke kataloga iz tega sistema." : $"Splet uporablja zadnjo uspešno datoteko ({version}).",
    JobFlows.Stock => version is null ? "Splet nima sveže datoteke cen in zaloge." : $"Cene in zaloga na spletu so iz zadnje uspešne datoteke ({version}).",
    JobFlows.Orders => "MIN/MID/MAX in mail »Zaloga pod MID« računajo s starimi naročili.",
    JobFlows.Inputs => "Novi artikli in spremembe iz SAOP ne pridejo v PIM; validacija in objava delata s starim katalogom.",
    _ => $"Zadnji uspeh: {result.LastSucceededUtc?.ToString("yyyy-MM-dd HH:mm") ?? "nikoli"} UTC.",
  };

  public static string StateLabel(FlowState state) => state switch
  {
    FlowState.Ok => "DELUJE",
    FlowState.Stale => "ZASTAREL",
    FlowState.Blocked => "BLOKIRAN",
    FlowState.Failed => "NAPAKA",
    FlowState.Off => "IZKLOPLJEN",
    FlowState.HostDown => "GOSTITELJ NE TEČE",
    _ => state.ToString(),
  };

  public static string Tone(FlowState state) => state switch
  {
    FlowState.Ok => "good",
    FlowState.Stale or FlowState.Blocked or FlowState.Off => "warn",
    _ => "bad",
  };

  static string? Cut(string? text) => text is null ? null : text.Length <= 220 ? text : text[..217] + "…";
}
