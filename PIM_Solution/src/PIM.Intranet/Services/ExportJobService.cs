using System.Collections.Concurrent;
using PIM.Operations;

namespace PIM.Intranet.Services;

public enum ExportRunStatus { Queued, Running, Completed, Failed }

/// <param name="RowCount">Do zdaj zapisanih vrstic (napredek) oziroma vseh vrstic ob koncu.</param>
/// <param name="DownloadToken">Ključ v <see cref="ExportResultStore"/>; na voljo šele ko je
/// <see cref="Status"/> <see cref="ExportRunStatus.Completed"/>.</param>
/// <param name="QueuePosition">Koliko izvozov je bilo pred tem v vrsti, ko je vstopil vanjo (Queued).</param>
public sealed record ExportJobState(
  Guid JobId, ExportRunStatus Status, int? RowCount = null,
  Guid? DownloadToken = null, string? FileName = null, string? Error = null,
  int QueuePosition = 0);

/// <summary>
/// Gradnja delovnega zvezka izdelkov v ozadju, loceno od klika, ki jo sproži.
///
/// Zakaj obstaja: pri vecjem katalogu (uporabnikova zahteva 2026-09-17: brez zgornje meje
/// vrstic, ker mora iti ven cel katalog, tudi ce zraste na 100.000+) gradnja zvezka traja
/// predolgo, da bi brskalnik cakal na odgovor enega klika na povezavo. Tu tece kot opravilo v
/// svoji DI seji (IServiceScopeFactory, ne seja klica, ki je job sprožil — ta lahko medtem
/// razpade, ce uporabnik zapre stran), stran pa dobi stanje nazaj prek dogodka Changed.
///
/// Sočasnost: opravila gredo skozi <see cref="HeavyWorkGate.Exports"/> — hkrati jih teče
/// največ toliko, kolikor vrata dovolijo, ostala čakajo po vrstnem redu (stanje Queued s
/// položajem v vrsti). Brez tega bi deset uporabnikov z enim klikom sprožilo deset vzporednih
/// gradenj celega kataloga (analiza 2026-09-17). Zvezek se piše naravnost v datoteko na disku
/// (<see cref="ExportResultStore.CreateTempFile"/>), ne v pomnilnik.
///
/// En proces drži vsa opravila v pomnilniku (ConcurrentDictionary); ob ponovnem zagonu
/// strežnika tekoča opravila izginejo, kar je v redu — uporabnik ob osvežitvi stran znova
/// klikne izvozi. Opravilo, ki preseže <see cref="MaxDuration"/>, se prekine in javi napako,
/// da vrata ne ostanejo zasedena z obviselim tekom.
/// </summary>
public sealed class ExportJobService(
  IServiceScopeFactory scopeFactory, ExportResultStore results, HeavyWorkGate gate, ILogger<ExportJobService> logger)
{
  /// <summary>Zgornja meja trajanja ene gradnje; cel katalog je izmerjen v minutah, ne urah.</summary>
  static readonly TimeSpan MaxDuration = TimeSpan.FromMinutes(90);

  const string WorkbookContentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";

  readonly ConcurrentDictionary<Guid, ExportJobState> jobs = new();

  /// <summary>Sproži se ob vsakem premiku opravila (Queued → Running → napredek → Completed/Failed).
  /// Poslušalci filtrirajo po JobId, ker je en servis skupen vsem uporabnikom vezja.</summary>
  public event Action<ExportJobState>? Changed;

  public ExportJobState? Get(Guid jobId) => jobs.TryGetValue(jobId, out var state) ? state : null;

  /// <summary>Koliko izvozov trenutno teče in koliko jih čaka — za stran /sistem/zmogljivost in opozorila.</summary>
  public (int Running, int Waiting, int Limit) Load => (gate.Exports.Running, gate.Exports.Waiting, gate.Exports.Limit);

  /// <summary>Zažene gradnjo in takoj vrne; klicatelj naj si <paramref name="jobId"/> zapomni
  /// pred klicem (ne šele po njem), da mu noben dogodek Changed ne uide.</summary>
  /// <param name="includeGroups">Katere skupine stolpcev gredo v datoteko (glej
  /// <see cref="ProductWorkbookService.BuildAsync"/>); null pomeni vse.</param>
  public void StartWorkbookExport(
    Guid jobId, string fileName, ProductListFilter filter, IReadOnlyCollection<string>? selection,
    IReadOnlySet<string>? includeGroups = null)
  {
    jobs[jobId] = new ExportJobState(jobId, ExportRunStatus.Queued, QueuePosition: gate.Exports.Waiting);
    _ = RunAsync(jobId, fileName, filter, selection, includeGroups);
  }

  async Task RunAsync(
    Guid jobId, string fileName, ProductListFilter filter, IReadOnlyCollection<string>? selection,
    IReadOnlySet<string>? includeGroups)
  {
    // Task.Yield: klicatelj (klik na strani) dobi nadzor nazaj takoj, gradnja tece na bazenu niti.
    await Task.Yield();
    using var timeout = new CancellationTokenSource(MaxDuration);
    string? tempPath = null;
    try
    {
      Publish(new ExportJobState(jobId, ExportRunStatus.Queued, QueuePosition: gate.Exports.Waiting));
      using var lease = await gate.Exports.EnterAsync(timeout.Token);
      Publish(new ExportJobState(jobId, ExportRunStatus.Running, RowCount: 0));

      using var scope = scopeFactory.CreateScope();
      var workbook = scope.ServiceProvider.GetRequiredService<ProductWorkbookService>();
      tempPath = results.CreateTempFile();
      int rowCount;
      await using (var stream = new FileStream(tempPath, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16, useAsync: true))
      {
        var progress = new Progress<int>(rows => Publish(new ExportJobState(jobId, ExportRunStatus.Running, RowCount: rows)));
        rowCount = await workbook.BuildToAsync(stream, filter, selection, includeGroups, progress, timeout.Token);
      }
      var token = results.Put(tempPath, fileName, WorkbookContentType);
      tempPath = null;
      Publish(new ExportJobState(jobId, ExportRunStatus.Completed, RowCount: rowCount, DownloadToken: token, FileName: fileName));
    }
    catch (OperationCanceledException) when (timeout.IsCancellationRequested)
    {
      logger.LogWarning("Izvoz {JobId} je presegel casovno mejo {Minutes} min in je bil prekinjen.", jobId, MaxDuration.TotalMinutes);
      Publish(new ExportJobState(jobId, ExportRunStatus.Failed,
        Error: $"Izvoz je trajal več kot {MaxDuration.TotalMinutes:0} minut in je bil prekinjen. Zoži pogled (podjetje, filter) ali izvozi v več delih."));
    }
    catch (Exception failure)
    {
      logger.LogError(failure, "Izvoz {JobId} ni uspel.", jobId);
      Publish(new ExportJobState(jobId, ExportRunStatus.Failed, Error: failure.Message));
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
    jobs[state.JobId] = state;
    // Poslusalec, ki pade (npr. vezje strani je medtem razpadlo), ne sme podreti opravila
    // ali ostalih poslusalcev.
    foreach (var handler in Changed?.GetInvocationList() ?? [])
    {
      try { ((Action<ExportJobState>)handler)(state); }
      catch (Exception failure) { logger.LogDebug(failure, "Poslusalec izvoza {JobId} je padel.", state.JobId); }
    }
  }
}
