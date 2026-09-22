using System.Collections.Concurrent;
using PIM.Operations;

namespace PIM.Intranet.Services;

public enum ExportRunStatus { Queued, Running, Completed, Failed }

/// <param name="RowCount">Do zdaj obdelanih vrstic v trenutni fazi (napredek) oziroma vseh vrstic ob koncu.</param>
/// <param name="DownloadToken">Ključ v <see cref="ExportResultStore"/>; na voljo šele ko je
/// <see cref="Status"/> <see cref="ExportRunStatus.Completed"/>.</param>
/// <param name="QueuePosition">Koliko izvozov je bilo pred tem v vrsti, ko je vstopil vanjo (Queued).</param>
/// <param name="Owner">Uporabnik, ki je izvoz sprožil (Identity.Name). Po njem ga najde okno
/// izvozov v kotu vsake strani, tudi ko uporabnik zapusti /izdelki.</param>
/// <param name="Phase">Branje seznama ali pisanje vrstic; <see cref="TotalRows"/> velja za fazo.</param>
/// <param name="TotalRows">Vseh vrstic pogleda — imenovalec vrstice napredka; null, dokler baza tega ne pove.</param>
/// <param name="WritingStartedUtc">Začetek pisanja vrstic; iz njega in hitrosti do zdaj sledi ocena preostanka.</param>
/// <param name="Downloaded">Datoteko je brskalnik že prevzel (GET /izvoz/zvezek ali /izvoz/prenos).</param>
/// <param name="Dismissed">Uporabnik je obvestilo zaprl; okno ga ne kaže več.</param>
/// <param name="BrowserWaiting">Brskalnik ima prenos že odprt (GET /izvoz/zvezek čaka na konec gradnje);
/// datoteka mu gre sama, okno izvozov je ne ponuja.</param>
public sealed record ExportJobState(
  Guid JobId, ExportRunStatus Status, int? RowCount = null,
  Guid? DownloadToken = null, string? FileName = null, string? Error = null,
  int QueuePosition = 0, string? Owner = null, DateTime StartedUtc = default, DateTime? FinishedUtc = null,
  ProductWorkbookPhase Phase = ProductWorkbookPhase.Listing, int? TotalRows = null, DateTime? WritingStartedUtc = null,
  bool Downloaded = false, bool Dismissed = false, bool BrowserWaiting = false)
{
  public bool IsActive => Status is ExportRunStatus.Queued or ExportRunStatus.Running;

  /// <summary>Ocena preostanka pisanja v sekundah iz dosedanje hitrosti; null, dokler je premalo
  /// podatkov za pošteno oceno (prvih nekaj sekund ali prvi paket).</summary>
  public int? RemainingSeconds(DateTime nowUtc)
  {
    if (Status != ExportRunStatus.Running || Phase != ProductWorkbookPhase.Writing
      || WritingStartedUtc is not { } started || RowCount is not > 0 || TotalRows is not { } total || total <= 0)
      return null;
    var elapsed = (nowUtc - started).TotalSeconds;
    if (elapsed < 5) return null;
    var remaining = (total - RowCount.Value) / (RowCount.Value / elapsed);
    return (int)Math.Ceiling(Math.Max(remaining, 0));
  }
}

/// <summary>
/// Gradnja delovnega zvezka izdelkov v ozadju, loceno od klika, ki jo sproži.
///
/// Zakaj obstaja: pri vecjem katalogu (uporabnikova zahteva 2026-09-17: brez zgornje meje
/// vrstic, ker mora iti ven cel katalog, tudi ce zraste na 100.000+) gradnja zvezka traja
/// predolgo, da bi brskalnik cakal na odgovor enega klika na povezavo. Tu tece kot opravilo v
/// svoji DI seji (IServiceScopeFactory, ne seja klica, ki je job sprožil — ta lahko medtem
/// razpade, ce uporabnik zapre stran), stran pa dobi stanje nazaj prek dogodka Changed.
///
/// Opravilo pripada uporabniku, ne strani (<see cref="ExportJobState.Owner"/>). Do 2026-09-22
/// je stanje poznala samo stran /izdelki, ki ga je sprožila: uporabnik je kliknil »Izvozi«,
/// takoj za tem »Uvozi«, gradnja je tekla naprej, a nihče ni več vedel zanjo — ne napredka ne
/// prenosa, zvezek je dve uri ležal na disku in se pobrisal. Uporabnik: »kaj se sploh dogaja
/// ne vem v ozadju, ker sem prec kliknil uvoz«. Zdaj stanje bere okno izvozov v kotu vsake
/// strani (MainLayout #pim-export-tray, wwwroot/js/pim-export.js prek GET /izvoz/opravila).
///
/// Prenos odpre klik, ne konec gradnje (<see cref="WaitForBrowserAsync"/>, GET /izvoz/zvezek).
/// Prej ga je sprožil skript minute po kliku, ko je bil zvezek gotov: brskalnik tak prenos brez
/// uporabnikovega dejanja obravnava kot sumljiv — Chrome ga je zadržal z »Obdrži« in ni pokazal
/// svojega polja prenosov (uporabnik 2026-09-22). Zdaj brskalnik dobi glavo odgovora takoj ob
/// kliku, prenos kaže ves čas gradnje, datoteka pride, ko je gotova.
///
/// Sočasnost: opravila gredo skozi <see cref="HeavyWorkGate.Exports"/> — hkrati jih teče
/// največ toliko, kolikor vrata dovolijo, ostala čakajo po vrstnem redu (stanje Queued s
/// položajem v vrsti). Brez tega bi deset uporabnikov z enim klikom sprožilo deset vzporednih
/// gradenj celega kataloga (analiza 2026-09-17). Zvezek se piše naravnost v datoteko na disku
/// (<see cref="ExportResultStore.CreateTempFile"/>), ne v pomnilnik.
///
/// En proces drži vsa opravila v pomnilniku (ConcurrentDictionary); ob ponovnem zagonu
/// strežnika tekoča opravila izginejo, kar je v redu — uporabnik ob osvežitvi stran znova
/// klikne izvozi. Končana opravila izginejo skupaj z datoteko (<see cref="ExportResultStore.Lifetime"/>).
/// Opravilo, ki preseže <see cref="MaxDuration"/>, se prekine in javi napako, da vrata ne
/// ostanejo zasedena z obviselim tekom.
/// </summary>
public sealed class ExportJobService(
  IServiceScopeFactory scopeFactory, ExportResultStore results, HeavyWorkGate gate, ILogger<ExportJobService> logger)
{
  /// <summary>Zgornja meja trajanja ene gradnje; cel katalog je izmerjen v minutah, ne urah.</summary>
  static readonly TimeSpan MaxDuration = TimeSpan.FromMinutes(90);

  public const string WorkbookContentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";

  readonly ConcurrentDictionary<Guid, ExportJobState> jobs = new();

  /// <summary>Konec gradnje po opravilih — nanj čaka odprt prenos v brskalniku (<see cref="WaitForBrowserAsync"/>).</summary>
  readonly ConcurrentDictionary<Guid, TaskCompletionSource<ExportJobState>> finished = new();

  /// <summary>Sproži se ob vsakem premiku opravila (Queued → Running → napredek → Completed/Failed).
  /// Poslušalci filtrirajo po JobId, ker je en servis skupen vsem uporabnikom vezja.</summary>
  public event Action<ExportJobState>? Changed;

  public ExportJobState? Get(Guid jobId) => jobs.TryGetValue(jobId, out var state) ? state : null;

  /// <summary>Izvozi uporabnika, ki jih še ni zaprl, najnovejši prvi — za okno izvozov na vsaki strani.</summary>
  public IReadOnlyList<ExportJobState> ForOwner(string owner)
  {
    Prune();
    return jobs.Values
      .Where(job => !job.Dismissed && IsOwner(job, owner))
      .OrderByDescending(job => job.StartedUtc)
      .ToList();
  }

  /// <summary>Zapre obvestilo o končanem izvozu; tekočega ne, ker bi uporabnik izgubil sled za njim.</summary>
  public bool Dismiss(Guid jobId, string owner)
  {
    if (!jobs.TryGetValue(jobId, out var state) || state.IsActive || !IsOwner(state, owner))
      return false;
    return jobs.TryUpdate(jobId, state with { Dismissed = true }, state);
  }

  /// <summary>Brskalnik je datoteko prevzel; okno izvozov jo pokaže kot preneseno.</summary>
  public void MarkDownloaded(Guid downloadToken)
  {
    foreach (var state in jobs.Values)
      if (state.DownloadToken == downloadToken)
        Update(state.JobId, current => current with { Downloaded = true, BrowserWaiting = false });
  }

  /// <summary>
  /// Prenos, ki ga je odprl klik (GET /izvoz/zvezek), čaka tu na konec gradnje. Vrne končno stanje
  /// ali null, če opravila ni ali ni od tega uporabnika. Dokler čaka, okno izvozov ve, da gre
  /// datoteka v brskalnik sama; če uporabnik prenos v brskalniku prekliče, gradnja teče naprej in
  /// okno ob koncu ponudi »Prenesi«.
  /// </summary>
  public async Task<ExportJobState?> WaitForBrowserAsync(Guid jobId, string owner, CancellationToken cancellationToken)
  {
    if (!jobs.TryGetValue(jobId, out var state) || !IsOwner(state, owner) || !finished.TryGetValue(jobId, out var done))
      return null;
    Update(jobId, current => current with { BrowserWaiting = !current.Downloaded });
    try
    {
      await done.Task.WaitAsync(cancellationToken);
      return Get(jobId);
    }
    catch (OperationCanceledException)
    {
      ReleaseBrowser(jobId);
      throw;
    }
  }

  /// <summary>Brskalnik je prenos opustil (preklic, prekinjena povezava); okno ponudi »Prenesi«.</summary>
  public void ReleaseBrowser(Guid jobId) => Update(jobId, current => current with { BrowserWaiting = false });

  /// <summary>Koliko izvozov trenutno teče in koliko jih čaka — za stran /sistem/zmogljivost in opozorila.</summary>
  public (int Running, int Waiting, int Limit) Load => (gate.Exports.Running, gate.Exports.Waiting, gate.Exports.Limit);

  /// <summary>Zažene gradnjo in takoj vrne; klicatelj naj si <paramref name="jobId"/> zapomni
  /// pred klicem (ne šele po njem), da mu noben dogodek Changed ne uide.</summary>
  /// <param name="owner">Uporabnik (Identity.Name), ki mu izvoz pripada.</param>
  /// <param name="includeFieldKeys">Katera posamezna polja gredo v datoteko (glej
  /// <see cref="ProductWorkbookService.BuildAsync"/>); null pomeni vsa.</param>
  public void StartWorkbookExport(
    Guid jobId, string owner, string fileName, ProductListFilter filter, IReadOnlyCollection<string>? selection,
    IReadOnlySet<string>? includeFieldKeys = null)
  {
    Prune();
    var state = new ExportJobState(jobId, ExportRunStatus.Queued, FileName: fileName,
      QueuePosition: gate.Exports.Waiting, Owner: owner, StartedUtc: DateTime.UtcNow);
    finished[jobId] = new TaskCompletionSource<ExportJobState>(TaskCreationOptions.RunContinuationsAsynchronously);
    jobs[jobId] = state;
    _ = RunAsync(state, filter, selection, includeFieldKeys);
  }

  async Task RunAsync(
    ExportJobState state, ProductListFilter filter, IReadOnlyCollection<string>? selection,
    IReadOnlySet<string>? includeFieldKeys)
  {
    // Task.Yield: klicatelj (klik na strani) dobi nadzor nazaj takoj, gradnja tece na bazenu niti.
    await Task.Yield();
    using var timeout = new CancellationTokenSource(MaxDuration);
    string? tempPath = null;
    try
    {
      Publish(state = state with { QueuePosition = gate.Exports.Waiting });
      using var lease = await gate.Exports.EnterAsync(timeout.Token);
      Publish(state = state with { Status = ExportRunStatus.Running, RowCount = 0 });

      using var scope = scopeFactory.CreateScope();
      var workbook = scope.ServiceProvider.GetRequiredService<ProductWorkbookService>();
      tempPath = results.CreateTempFile();
      int rowCount;
      await using (var stream = new FileStream(tempPath, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16, useAsync: true))
      {
        // Napredek se javi v istem toku kot gradnja, ne prek Progress<T>: ta bi brez
        // SynchronizationContext klical na bazenu niti, in pozno sporocilo »Running« bi lahko
        // prehitelo »Completed« — okno bi potem vrtelo koncan izvoz v nedogled.
        var progress = new InlineProgress<ProductWorkbookProgress>(step => Publish(state = state with
        {
          Phase = step.Phase,
          RowCount = step.Done,
          TotalRows = step.Total,
          WritingStartedUtc = step.Phase == ProductWorkbookPhase.Writing ? state.WritingStartedUtc ?? DateTime.UtcNow : null,
        }));
        rowCount = await workbook.BuildToAsync(stream, filter, selection, includeFieldKeys, progress, timeout.Token);
      }
      var token = results.Put(tempPath, state.FileName ?? "izvoz.xlsx", WorkbookContentType);
      tempPath = null;
      Publish(state = state with
      {
        Status = ExportRunStatus.Completed, RowCount = rowCount, TotalRows = rowCount,
        DownloadToken = token, FinishedUtc = DateTime.UtcNow,
      });
    }
    catch (OperationCanceledException) when (timeout.IsCancellationRequested)
    {
      logger.LogWarning("Izvoz {JobId} je presegel casovno mejo {Minutes} min in je bil prekinjen.", state.JobId, MaxDuration.TotalMinutes);
      Publish(state = state with
      {
        Status = ExportRunStatus.Failed, FinishedUtc = DateTime.UtcNow,
        Error = $"Izvoz je trajal več kot {MaxDuration.TotalMinutes:0} minut in je bil prekinjen. Zoži pogled (podjetje, filter) ali izvozi v več delih.",
      });
    }
    catch (Exception failure)
    {
      logger.LogError(failure, "Izvoz {JobId} ni uspel.", state.JobId);
      Publish(state = state with { Status = ExportRunStatus.Failed, FinishedUtc = DateTime.UtcNow, Error = failure.Message });
    }
    finally
    {
      if (tempPath is not null)
      {
        try { File.Delete(tempPath); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
      }
    }
  }

  void Publish(ExportJobState state)
  {
    // Dismissed/Downloaded/BrowserWaiting postavita uporabnik in brskalnik mimo gradnje; gradnja
    // jih ne sme povoziti.
    jobs.AddOrUpdate(state.JobId, state, (_, current) => state with
    {
      Downloaded = current.Downloaded, Dismissed = current.Dismissed, BrowserWaiting = current.BrowserWaiting,
    });
    if (!state.IsActive && finished.TryGetValue(state.JobId, out var done))
      done.TrySetResult(state);
    // Poslusalec, ki pade (npr. vezje strani je medtem razpadlo), ne sme podreti opravila
    // ali ostalih poslusalcev.
    foreach (var handler in Changed?.GetInvocationList() ?? [])
    {
      try { ((Action<ExportJobState>)handler)(state); }
      catch (Exception failure) { logger.LogDebug(failure, "Poslusalec izvoza {JobId} je padel.", state.JobId); }
    }
  }

  /// <summary>Končana opravila zivijo toliko kot njihova datoteka; potem ni vec cesa prenesti.</summary>
  void Prune()
  {
    var cutoff = DateTime.UtcNow - ExportResultStore.Lifetime;
    foreach (var pair in jobs)
      if (pair.Value.FinishedUtc is { } finishedUtc && finishedUtc < cutoff)
      {
        jobs.TryRemove(pair.Key, out _);
        finished.TryRemove(pair.Key, out _);
      }
  }

  static bool IsOwner(ExportJobState state, string owner) =>
    string.Equals(state.Owner, owner, StringComparison.OrdinalIgnoreCase);

  void Update(Guid jobId, Func<ExportJobState, ExportJobState> change)
  {
    while (jobs.TryGetValue(jobId, out var current) && !jobs.TryUpdate(jobId, change(current), current)) { }
  }

  sealed class InlineProgress<T>(Action<T> report) : IProgress<T>
  {
    public void Report(T value) => report(value);
  }
}
