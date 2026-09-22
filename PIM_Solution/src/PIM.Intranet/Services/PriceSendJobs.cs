using System.Collections.Concurrent;
using PIM.Outbound;

namespace PIM.Intranet.Services;

/// <summary>Stanje enega teka pošiljanja cen in cenikov podjetja; stran ga bere, dokler teče.</summary>
public sealed class PriceSendJob(int organizationId, string actor)
{
  readonly object gate = new();
  readonly List<string> notes = [];

  public int OrganizationId { get; } = organizationId;
  public string Actor { get; } = actor;
  public DateTime StartedUtc { get; } = DateTime.UtcNow;
  public DateTime? FinishedUtc { get; private set; }
  public string Phase { get; private set; } = "Začenjam …";
  public int Sent { get; private set; }
  public int Failed { get; private set; }
  public string? Error { get; private set; }
  public bool Running => FinishedUtc is null;
  internal CancellationTokenSource Cancellation { get; } = new();

  /// <summary>Zadnjih 30 vrstic pošiljatelja (»B2C|14V268.5: Posodobitev (POST) uspešno«).</summary>
  public IReadOnlyList<string> Notes { get { lock (gate) return notes.ToArray(); } }

  internal void SetPhase(string phase) => Phase = phase;

  internal void Add(SaopDocumentRunResult result)
  {
    lock (gate)
    {
      Sent += result.Sent;
      Failed += result.Failed;
      notes.AddRange(result.Notes);
      if (notes.Count > 30) notes.RemoveRange(0, notes.Count - 30);
    }
  }

  internal void Finish(string? error)
  {
    Error = error;
    Phase = error is null ? "Končano" : "Ustavljeno";
    FinishedUtc = DateTime.UtcNow;
  }

  public void Cancel() => Cancellation.Cancel();
}

/// <summary>
/// Pošiljanje odobrenih cen in cenikov v SAOP v ozadju (265) — teče naprej, tudi ko uporabnik
/// zapusti stran; en tek na podjetje. Cenik velja ali 20.000 cen: po dokumentu gre to minute, zato ne
/// sme viseti v kliku kot pošiljanje enega artikla (<see cref="SaopWriteService.TrySendArticleAsync"/>).
///
/// Vrstni red je zavezujoč: najprej ceniki (AddPriceLists), šele nato cene — cena za cenik, ki ga
/// SAOP ne pozna, bi bila zavrnjena; out.ClaimSaopDocument jo do takrat sam izpusti.
/// Poverilnice in naslov so isti kot pri artiklih (razdelek »Saop« / PIM_SAOP_*).
/// </summary>
public sealed class PriceSendJobs(ILogger<PriceSendJobs> logger)
{
  /// <summary>Dokumentov na en klic pošiljatelja; med klici se preveri preklic in osveži napredek.</summary>
  const int Chunk = 20;

  readonly ConcurrentDictionary<int, PriceSendJob> jobs = new();

  public PriceSendJob? Current(int organizationId) => jobs.TryGetValue(organizationId, out var job) ? job : null;

  /// <returns>Tek (nov ali že tekoči); <c>NotConfigured</c>, kadar poverilnic SAOP ni — takrat se ne začne nič.</returns>
  public (PriceSendJob? Job, bool NotConfigured) Start(string connectionString, int organizationId, string actor)
  {
    var (baseUrl, username, password, acceptUntrusted) = SaopWriteService.ReadSaopCredentials();
    if (string.IsNullOrWhiteSpace(username) || string.IsNullOrWhiteSpace(password)) return (null, true);

    if (jobs.TryGetValue(organizationId, out var running) && running.Running) return (running, false);

    var job = new PriceSendJob(organizationId, actor);
    jobs[organizationId] = job;
    var connection = new SaopConnection(baseUrl ?? string.Empty, username, password,
      TimeoutSeconds: 60, AcceptUntrustedCertificate: acceptUntrusted);
    _ = Task.Run(() => RunAsync(job, connectionString, connection));
    return (job, false);
  }

  async Task RunAsync(PriceSendJob job, string connectionString, SaopConnection connection)
  {
    var token = job.Cancellation.Token;
    try
    {
      using var sender = new SaopDocumentSender(connection);
      var workerId = $"intranet-cene:{Environment.MachineName}:{Environment.ProcessId}";
      foreach (var (target, label) in new[] { ("SAOP_PRICELIST", "ceniki"), ("SAOP_PRICE", "cene") })
      {
        var options = new SaopDocumentRunOptions(target, DryRun: false, OutputDirectory: null, MaxDocuments: Chunk,
          OrganizationId: job.OrganizationId);
        var runner = new SaopDocumentRunner(connectionString, workerId, options, sender);
        while (!token.IsCancellationRequested)
        {
          job.SetPhase($"Pošiljam {label} — poslanih {job.Sent:N0}, zavrnjenih {job.Failed:N0}");
          var result = await runner.RunAsync(token);
          job.Add(result);
          if (result.Documents < Chunk) break;
        }
      }
      logger.LogInformation("Cene v SAOP: podjetje {Organizacija}, {Akter} — poslanih {Poslanih}, zavrnjenih {Zavrnjenih}.",
        job.OrganizationId, job.Actor, job.Sent, job.Failed);
      job.Finish(token.IsCancellationRequested ? "Pošiljanje je bilo ustavljeno; kar ni odšlo, ostane v vrsti." : null);
    }
    catch (OperationCanceledException)
    {
      job.Finish("Pošiljanje je bilo ustavljeno; kar ni odšlo, ostane v vrsti.");
    }
    catch (Exception exception)
    {
      logger.LogError(exception, "Cene v SAOP: podjetje {Organizacija} — pošiljanje je padlo.", job.OrganizationId);
      job.Finish("Pošiljanje je padlo: " + exception.Message + " Kar ni odšlo, ostane v vrsti za naslednji poskus.");
    }
  }
}
