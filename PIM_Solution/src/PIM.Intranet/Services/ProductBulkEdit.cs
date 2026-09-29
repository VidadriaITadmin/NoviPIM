using System.Globalization;
using PIM.Operations;

namespace PIM.Intranet.Services;

/// <summary>
/// Paketno urejanje na seznamu izdelkov (/izdelki, naloga #10): »izbrane vrstice ali vse po filtru →
/// polje → vrednost → predogled prej/potem → potrditev«.
///
/// Zakaj »navidezen uvoz Excela« in ne svoja pot. Uvoz delovnega lista že zna vse, kar mora znati
/// množična sprememba: preveri vrednost (D/N, število, pot kategorije, nov atribut), izloči izdelke,
/// kjer je vrednost že taka, zapiše po paketih skozi množične procedure (pim.Save*Bulk) z zgodovino
/// in ponovno validacijo samo spremenjenih izdelkov, zabeleži uvoz v ops.ImportRun (prej → potem po
/// celicah) in ga zna povrniti na /uvozi/{Id}. Paketna sprememba zato sestavi majhen zvezek
/// (Podjetje | Šifra artikla | izbrano polje) in gre skozi <see cref="ProductWorkbookService.PreviewAsync"/>,
/// <see cref="ProductWorkbookService.ApplyAsync"/> in <see cref="ImportHistoryService.RecordAsync"/> —
/// brez nove migracije in brez druge poti, ki bi se z uvozom slej ko prej razšla.
///
/// Statična pomočnica (ne storitev v DI): servise ji poda stran, zato ne potrebuje registracije.
///
/// Kaj namenoma NI v izbiri polja (PRIVZETO ZA NOČ 2026-09-29, lastnik lahko spremeni):
///   - ERP polja (cilj SAOP): gredo v vrsto za SAOP; paketno jih še naprej ureja uvoz Excela.
///   - S-popust: ima svoje dejanje na seznamu (pravica Komerciale, BusinessWrite).
///   - slike in dokumenti: celica je cel seznam izdelka v vrstnem redu — isti seznam za vse izdelke
///     nima smisla (naloga #32, stran Mediji).
/// </summary>
public static class ProductBulkEdit
{
  /// <summary>Naslov zapisa v zgodovini uvozov (/uvozi).</summary>
  public const string HistoryTitle = "Seznam izdelkov – paketno";

  /// <summary>Vir za samodejni umik s spleta (251) — isti kot pri uvozu delovnega lista.</summary>
  public const string WithdrawalSource = "DELOVNI_LIST";

  /// <summary>Koliko vrstic prej → potem pokaže predogled.</summary>
  public const int SampleSize = 25;

  /// <summary>Izbrana vrstica: šifra je enolična samo znotraj podjetja.</summary>
  public sealed record Target(int OrganizationId, string OrganizationName, string ItemId);

  /// <summary>Pri seznamih (kategorije, spletne strani): nadomesti ves seznam ali dodaj k obstoječemu.</summary>
  public enum ListMode { Replace, Add }

  /// <param name="Products">Izdelkov, ki se jim vrednost res spremeni.</param>
  /// <param name="Unchanged">Izbranih izdelkov, ki že imajo to vrednost (ali jih ni).</param>
  /// <param name="LosingWebSite">Izdelkov, ki izgubijo kljukico vsaj enega spletišča (251: umik s spleta).</param>
  public sealed record Summary(
    int Products, int Unchanged, IReadOnlyList<(string Organization, int Products)> ByOrganization,
    IReadOnlyList<Sample> Samples, int LosingWebSite);

  public sealed record Sample(string OrganizationName, string ItemId, string? Before, string After);

  /// <param name="HistoryId">Zapis na /uvozi/{Id}; null, če ni bilo sprememb ali zgodovina ni uspela.</param>
  /// <param name="Failure">Zapis se je ustavil; kar je zapisano, je v zgodovini in se da povrniti.</param>
  public sealed record Result(ProductWorkbookOutcome? Outcome, long? HistoryId, int Withdrawn, string? Failure);

  /// <summary>Ali sme paketno urejanje ponuditi to polje (glej opombo razreda).</summary>
  public static bool IsEditable(ProductWorkbookColumn column) =>
    column.Target == ProductWorkbookTarget.Pim
    && !ProductWorkbookContract.IsPackagingField(column.FieldKey)
    && column.FieldKey is not (ProductWorkbookContract.ImagesField or ProductWorkbookContract.DocumentsField);

  /// <summary>
  /// Polja za izbiro. Kategorija se ponudi samo za prvo (primarno) spletišče vsakega drevesa: jezikovna
  /// različica brez svojega stolpca dobi kategorijo iz primarne strani (ProductWorkbookService.ApplySitesAsync),
  /// slovenska pot v stolpcu angleške strani pa bi bila samo »manjkajoča kategorija«.
  /// </summary>
  public static IReadOnlyList<ProductWorkbookColumn> EditableColumns(
    IEnumerable<ProductWorkbookColumn> columns, IReadOnlyList<WorkbookWebSite> sites)
  {
    var primary = sites.GroupBy(site => site.CategoryTreeCode, StringComparer.OrdinalIgnoreCase)
      .Select(tree => ProductWorkbookContract.CategoryFieldKey(tree.First().Code))
      .ToHashSet(StringComparer.Ordinal);
    return columns.Where(IsEditable)
      .Where(column => !column.FieldKey.StartsWith(ProductWorkbookContract.CategoryFieldPrefix, StringComparison.Ordinal)
        || primary.Contains(column.FieldKey))
      .ToList();
  }

  /// <summary>Spletišče, katerega kategorije piše stolpec (null, če stolpec ni kategorija).</summary>
  public static WorkbookWebSite? CategorySite(ProductWorkbookColumn column, IReadOnlyList<WorkbookWebSite> sites) =>
    column.FieldKey.StartsWith(ProductWorkbookContract.CategoryFieldPrefix, StringComparison.Ordinal)
      ? sites.FirstOrDefault(site => ProductWorkbookContract.CategoryFieldKey(site.Code) == column.FieldKey)
      : null;

  public static bool IsList(ProductWorkbookColumn column) => column.IsMultiValue;

  /// <summary>
  /// Majhen zvezek, kot bi ga uporabnik sestavil v Excelu: Podjetje (številka, enolična), Šifra artikla
  /// in izbrano polje pod svojo skupino — ista oblika kot izvoz, zato ga uvoz prebere po isti poti.
  /// </summary>
  public static byte[] BuildWorkbook(ProductWorkbookColumn column, IReadOnlyCollection<Target> targets, string value)
  {
    ArgumentNullException.ThrowIfNull(column);
    ArgumentNullException.ThrowIfNull(targets);
    if (targets.Count > WorkbookWriter.MaxRows)
      throw new InvalidOperationException($"Izbranih je {targets.Count:N0} izdelkov; en paket jih sme imeti največ {WorkbookWriter.MaxRows:N0}. Zoži filter.");
    var columns = new List<WorkbookColumn>
    {
      new("Podjetje", Group: ProductWorkbookContract.GroupKey),
      new("Šifra artikla", Group: ProductWorkbookContract.GroupKey),
      new(column.Header, Group: column.Group),
    };
    var rows = targets
      .DistinctBy(target => (target.OrganizationId, target.ItemId.ToUpperInvariant()))
      .Select(target => (IReadOnlyList<object?>)[target.OrganizationId.ToString(CultureInfo.InvariantCulture), target.ItemId, value]);
    return WorkbookWriter.Write("Paketno", columns, rows);
  }

  /// <summary>
  /// Predogled: zvezek skozi uvoz. Pri »Dodaj« se seznam vsakega izdelka združi z obstoječim (prej iz
  /// predogleda); izdelek, ki ima vse dodano že zapisano, odpade.
  /// </summary>
  public static async Task<ProductWorkbookPreview> PreviewAsync(
    ProductWorkbookService workbook, ProductWorkbookColumn column, IReadOnlyCollection<Target> targets,
    string value, ListMode mode, CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(workbook);
    using var file = new MemoryStream(BuildWorkbook(column, targets, value));
    var preview = await workbook.PreviewAsync(file, null, cancellationToken);
    // Neznan stolpec bi pomenil, da polja uvoz ne pozna — takrat se ne zapiše nič (varno), a se pove.
    if (preview.UnknownColumns.Count > 0)
      preview = preview with { Problems = [.. preview.Problems, $"Polja »{column.Header}« uvoz ne prepozna; nič se ne zapiše."] };
    return mode == ListMode.Add && IsList(column) && value != ProductWorkbookContract.ClearToken
      ? MergeAdd(preview, column.FieldKey)
      : preview;
  }

  /// <summary>»Dodaj«: nova vrednost = prej ∪ dodano (vrstni red: prej, nato novo). Brez razlike vrstica odpade.</summary>
  public static ProductWorkbookPreview MergeAdd(ProductWorkbookPreview preview, string fieldKey)
  {
    var rows = new List<ProductWorkbookRowChange>(preview.Rows.Count);
    foreach (var row in preview.Rows)
    {
      if (!row.PimValues.TryGetValue(fieldKey, out var added)) { rows.Add(row); continue; }
      var before = row.OldValues is not null && row.OldValues.TryGetValue(fieldKey, out var old) ? old : null;
      var existing = ProductWorkbookContract.SplitList(before);
      var merged = existing.Concat(ProductWorkbookContract.SplitList(added))
        .Distinct(StringComparer.OrdinalIgnoreCase).ToList();
      if (merged.Count == existing.Count) continue;
      var values = new Dictionary<string, string>(row.PimValues, StringComparer.Ordinal)
      {
        [fieldKey] = ProductWorkbookContract.JoinList(merged) ?? added,
      };
      rows.Add(row with { PimValues = values });
    }
    return preview with { Rows = rows };
  }

  /// <summary>Kaj bo paket naredil — za potrditev (število, podjetja, prej → potem, umik s spleta).</summary>
  public static Summary Summarize(ProductWorkbookPreview preview, string fieldKey, int selected)
  {
    ArgumentNullException.ThrowIfNull(preview);
    var changed = preview.Rows.Where(row => row.PimValues.ContainsKey(fieldKey)).ToList();
    var byOrganization = changed.GroupBy(row => row.OrganizationName)
      .Select(group => (group.Key, group.Count()))
      .OrderByDescending(pair => pair.Item2).ToList();
    var samples = changed.Take(SampleSize)
      .Select(row => new Sample(row.OrganizationName, row.ItemId,
        row.OldValues is not null && row.OldValues.TryGetValue(fieldKey, out var before) ? before : null,
        row.PimValues[fieldKey]))
      .ToList();
    var losing = fieldKey == ProductWorkbookContract.WebSitesField
      ? changed.Count(row =>
      {
        var before = row.OldValues is not null && row.OldValues.TryGetValue(fieldKey, out var old) ? old : null;
        var after = row.PimValues[fieldKey] == ProductWorkbookContract.ClearToken ? [] : ProductWorkbookContract.SplitList(row.PimValues[fieldKey]);
        return ProductWorkbookContract.SplitList(before).Any(site => !after.Contains(site, StringComparer.OrdinalIgnoreCase));
      })
      : 0;
    return new(changed.Count, Math.Max(0, selected - changed.Count), byOrganization, samples, losing);
  }

  /// <summary>
  /// Zapis. Pravico preveri tukaj (CatalogWrite) IN zapisovalne procedure v ProductEditService — skrit
  /// gumb je samo videz. Zapis ni transakcija čez ves paket (ApplyAsync piše po 1.000 izdelkov): če se
  /// ustavi, se vseeno zabeleži v zgodovino, ker povratek (PlanUndoAsync) povrne samo celice, ki res
  /// nosijo novo vrednost — torej tudi delni zapis. Po zapisu se kandidati za umik s spleta (251)
  /// ponovno validirajo, kot pri uvozu.
  /// </summary>
  public static async Task<Result> ApplyAsync(
    PimWriteGuard guard, ProductWorkbookService workbook, ImportHistoryService history, WebWithdrawalService withdrawals,
    ProductWorkbookPreview preview, string actor, string? note, IProgress<string>? progress = null)
  {
    ArgumentNullException.ThrowIfNull(guard);
    ArgumentNullException.ThrowIfNull(preview);
    await guard.RequireAsync(PimPolicies.CatalogWrite);
    if (preview.Rows.Count == 0) return new(null, null, 0, null);
    // Varovalka: ta pot ne pošilja v SAOP. Če bi predogled kdaj nosil ERP polje, se zapis ne začne.
    if (preview.Rows.Any(row => row.SaopValues.Count > 0))
      throw new InvalidOperationException("Paketno urejanje ne piše polj SAOP; uporabi uvoz Excela (/izdelki/uvoz).");

    ProductWorkbookOutcome? outcome = null;
    string? failure = null;
    try
    {
      outcome = await workbook.ApplyAsync(preview, actor, note, progress);
    }
    catch (Exception exception) when (exception is not UnauthorizedAccessException)
    {
      failure = exception.Message;
    }

    var problems = preview.Problems.Concat(outcome?.Problems ?? []).Distinct(StringComparer.Ordinal).ToList();
    if (failure is not null)
      problems.Insert(0, "Zapis se je ustavil: " + failure + " Kar je bilo zapisano, lahko povrneš s »Povrni«.");
    progress?.Report("Zapisujem zgodovino (prej → potem) …");
    long? historyId = null;
    try
    {
      historyId = await history.RecordAsync(ImportKinds.Products, HistoryTitle, note, actor,
        outcome?.RowsTouched ?? preview.Rows.Count, 0, outcome?.OutboundBatchIds, problems, null,
        ImportHistoryService.FromProducts(preview));
    }
    catch (Exception exception)
    {
      failure ??= "Zgodovina ni zapisana: " + exception.Message;
    }

    var withdrawn = 0;
    try
    {
      progress?.Report("Preverjam, ali kak izdelek po spremembi ni več veljaven za splet …");
      foreach (var organization in preview.Rows.GroupBy(row => row.OrganizationId))
        withdrawn += (await withdrawals.AfterChangeByItemsAsync(organization.Key,
          organization.Select(row => row.ItemId).Distinct(StringComparer.OrdinalIgnoreCase).ToList(),
          WithdrawalSource, actor, revalidate: true)).Count;
    }
    catch (Exception exception)
    {
      failure ??= "Preverjanje umika s spleta ni uspelo: " + exception.Message;
    }
    return new(outcome, historyId, withdrawn, failure);
  }

  /// <summary>Kratek prikaz vrednosti v predogledu (»-« = izprazni, 1/0 = Da/Ne pri D/N poljih).</summary>
  public static string Shown(string? value, bool isBool)
  {
    if (value is null || value.Length == 0) return "(prazno)";
    if (value == ProductWorkbookContract.ClearToken) return "(izprazni)";
    if (isBool && value is "1" or "0") return value == "1" ? "Da" : "Ne";
    var flat = value.ReplaceLineEndings(" ");
    return flat.Length <= 80 ? flat : flat[..80] + "…";
  }
}
