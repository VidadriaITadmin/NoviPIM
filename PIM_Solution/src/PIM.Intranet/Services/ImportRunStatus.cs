namespace PIM.Intranet.Services;

/// <summary>En uveljavljen uvoz (<c>ops.ImportRun</c>).</summary>
public sealed record ImportRunRow(
  long ImportRunId, string Kind, string Title, string? Note, string Actor, DateTime AppliedUtc, int RowCount,
  int ChangeCount, int SaopCount, string? OutboundBatchIds, long? UndoOfImportRunId, long? UndoneByImportRunId,
  DateTime? UndoneUtc, string? UndoneBy, string? Organizations, string? Problems = null)
{
  public bool IsUndone => UndoneByImportRunId is not null;
  public bool IsUndo => UndoOfImportRunId is not null;
}

/// <summary>
/// Stanje uvoza v vrsti za SAOP, šteto po <b>zapisih</b> (cena, artikel), ne po sporočilih: ena cena so štiri
/// sporočila (neto, DDV, velja od, aktivna), zato bi »12 sporočil« zmedlo (naloga #66). Zapis šteje v eno samo
/// stanje, in sicer v prvo, ki velja za katerokoli njegovo sporočilo: čaka → v SAOP → neuspelo → preklicano.
/// </summary>
/// <param name="Waiting">Še čaka (odobritev, pošiljanje, ponovni poskus, napaka) — lahko se prekliče.</param>
/// <param name="Sent">Vsaj del je šel (ali gre) v SAOP.</param>
/// <param name="Cancelled">Vse preklicano ali nadomeščeno — v SAOP ni šlo nič.</param>
/// <param name="Failed">Dokončno neuspelo (Dead) — v SAOP ni prišlo.</param>
public sealed record ImportQueueState(int Waiting, int Sent, int Cancelled, int Failed = 0)
{
  public int Total => Waiting + Sent + Cancelled + Failed;
}

/// <summary>Kako se uvoz pokaže v zgodovini: napis in ton čipa ter ali ima smisel povratek.</summary>
/// <param name="UndoOffered">Ali stran ponudi »Pripravi povratek«.</param>
/// <param name="Explanation">Stavek za uporabnika, kadar povratka ni (ali je stanje posebno).</param>
public sealed record ImportRunStatus(string Text, string? Tone, bool UndoOffered, string? Explanation = null);

public static class ImportKinds
{
  public const string Products = "IZDELKI";
  public const string Prices = "CENE";
  public const string Customers = "STRANKE";

  public static string Label(string kind) => kind switch
  {
    Products => "Izdelki (delovni list)",
    Prices => "Cene",
    Customers => "Stranke",
    _ => kind,
  };

  /// <summary>Stran uvoza, ki zna povratek pokazati v predogledu in ga uveljaviti.</summary>
  public static string ImportPage(string kind) => kind switch
  {
    Products => "izdelki/uvoz",
    Prices => "cene/uvoz",
    Customers => "stranke/uvoz",
    _ => "uvozi",
  };

  /// <summary>
  /// Uvoz, ki v PIM ne zapiše ničesar in samo uvrsti v vrsto za SAOP. Cene gredo samo v vrsto
  /// (<c>PriceWorkbookService.ApplyAsync</c> → <c>prices.EnqueueAsync</c>); <c>canon.ProductPrice</c> se spremeni
  /// šele, ko zajem cen prinese novo ceno iz SAOP. Izdelki SAOP polja zapišejo v PIM takoj in jih uvrstijo v vrsto.
  /// </summary>
  public static bool QueueOnly(string kind) => kind == Prices;

  /// <summary>Stolpec »Kam« na /uvozi/{Id}.</summary>
  public static string Where(string kind, string target) =>
    target != "SAOP" ? "PIM" : QueueOnly(kind) ? "vrsta za SAOP" : "PIM + vrsta za SAOP";

  /// <summary>Število zapisov v vrsti s pravo sklanjatvijo: »3 cene«, »1 artikel«.</summary>
  public static string QueueUnit(string kind, long count) => kind switch
  {
    Prices => PimFormat.Count(count, "cena", "ceni", "cene", "cen"),
    Customers => PimFormat.Count(count, "zapis", "zapisa", "zapisi", "zapisov"),
    _ => PimFormat.Count(count, "artikel", "artikla", "artikli", "artiklov"),
  };

  /// <summary>
  /// Stanje uvoza. Izračuna se iz zapisa uvoza in stanja v vrsti — nič se ne zapiše v bazo.
  /// PRIVZETO ZA NOČ (naloga #66, lastnik lahko spremeni, odločitev #85): uvoz, ki je spremenil samo vrsto za SAOP
  /// (cene) in so vsi njegovi zapisi preklicani, je »preklican« in nima povratka (ni česa vrniti). Uvoz, ki je
  /// spremenil tudi PIM (izdelki, stranke), ostane »uveljavljen« s povratkom. Mešano (del v SAOP, del preklican)
  /// je »delno preklican« in povratek ostane — kar je šlo v SAOP, vrne samo povratek.
  /// </summary>
  public static ImportRunStatus StatusOf(ImportRunRow run, ImportQueueState? queue)
  {
    if (run.IsUndone) return new($"povrnjen z uvozom #{run.UndoneByImportRunId}", "warn", false);
    var undoLabel = run.IsUndo ? $"povratek uvoza #{run.UndoOfImportRunId}" : null;
    if (queue is { Total: > 0 } state && state.Cancelled > 0)
    {
      if (state is { Waiting: 0, Sent: 0, Failed: 0 })
        return QueueOnly(run.Kind)
          ? new(undoLabel is null ? "preklican" : $"{undoLabel}, preklican", "warn", false,
              $"Vse, kar je ta uvoz dal v vrsto za SAOP ({QueueUnit(run.Kind, state.Cancelled)}), je bilo preklicano, preden je šlo v SAOP. " +
              "V SAOP ni šlo nič in v PIM se ni nič spremenilo, zato povratek ni potreben.")
          : new(undoLabel is null ? "uveljavljen, SAOP preklican" : $"{undoLabel}, SAOP preklican", null, true,
              "Spremembe v PIM so uveljavljene; del za SAOP je bil preklican in v SAOP ni šel.");
      if (state.Sent > 0)
        return new(undoLabel is null ? "delno preklican" : $"{undoLabel}, delno preklican", "warn", true,
          $"V SAOP je šlo: {QueueUnit(run.Kind, state.Sent)}; preklicano: {QueueUnit(run.Kind, state.Cancelled)}. " +
          "Kar je šlo v SAOP, vrne samo povratek.");
    }
    return undoLabel is null ? new("uveljavljen", "good", true) : new(undoLabel, null, true);
  }
}
