using System.Data;
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using PIM.Operations;

namespace PIM.Intranet.Services;

/// <param name="PimValues">Kar se zapiše takoj; ključ je kanonična koda polja.</param>
/// <param name="SaopValues">Kar gre v odhodno vrsto in čaka odobritev.</param>
public sealed record ProductWorkbookRowChange(
  int RowNumber, int OrganizationId, string OrganizationName, string ItemId,
  IReadOnlyDictionary<string, string> PimValues,
  IReadOnlyDictionary<string, string> SaopValues);

/// <param name="UnknownColumns">Naslovi, ki jim ne ustreza noben stolpec pogodbe.</param>
/// <param name="ReadOnlyColumns">Naslovi, ki jih uvoz namenoma ne bere.</param>
public sealed record ProductWorkbookPreview(
  IReadOnlyList<ProductWorkbookRowChange> Rows,
  IReadOnlyList<string> UnknownColumns,
  IReadOnlyList<string> ReadOnlyColumns,
  IReadOnlyList<string> Problems)
{
  public int PimChangeCount => Rows.Sum(row => row.PimValues.Count);
  public int SaopChangeCount => Rows.Sum(row => row.SaopValues.Count);
}

/// <param name="OutboundBatchIds">Skupine, ki čakajo odobritev na /izvozi/mnozicno.</param>
public sealed record ProductWorkbookOutcome(
  int RowsTouched, int PimChanges, int SaopQueued, int SaopDuplicates, int SaopRejected,
  IReadOnlyList<long> OutboundBatchIds, IReadOnlyList<string> Problems);

/// <summary>
/// Delovni list izdelkov: en zvezek, ki gre ven in se vrne nazaj.
///
/// Zakaj obstaja. Do zdaj sta bila izvoz in uvoz na strani /izdelki dve različni datoteki.
/// Izvožen »pregled« je imel vsebino, a se ni dal vrniti — naslovi stolpcev niso ustrezali
/// ničemur, kar uvoz pozna. Vračljiva »predloga SAOP« pa je imela samo ERP polja: brez
/// spletnih nazivov, opisov, kategorij, atributov in brez podatka, na katero spletno stran
/// artikel gre. Kdor je hotel dopolniti splet za tisoč izdelkov, tega ni mogel narediti
/// nikjer razen po enem izdelku na kartici.
///
/// Stolpci obeh smeri pridejo iz <see cref="ProductWorkbookContract"/> — enega seznama. Zato
/// stolpec ne more zdrsniti samo na eni strani.
///
/// Kam gre kaj pri uvozu, ne odloča ta koda:
///   - ERP polja: register <c>out.SaopXmlField</c> pove, katero polje sme PIM pisati. Taka
///     vrednost gre v odhodno vrsto in čaka odobritev, ne v katalog.
///   - Spletni podatek je last PIM in se zapiše takoj, skozi iste procedure kot kartica
///     izdelka, torej z zgodovino in takojšnjo ponovno validacijo.
///
/// Dve pravili lista: prazna celica pomeni »ne dotikaj se«, seznam v celici je ločen z »|«.
/// </summary>
public sealed class ProductWorkbookService(
  IConfiguration configuration,
  ProductWorkbenchService workbench,
  ProductExportService export,
  CatalogReadService catalog,
  ProductEditService edit,
  CategoryMappingService categories,
  SaopWriteService saop,
  IntranetDataService data)
{
  /// <summary>Zgornja meja vrstic izvoza: fizična meja lista .xlsx, ne poslovna (WorkbookTable.MaxRows).</summary>
  public const int MaxRows = WorkbookTable.MaxRows;

  /// <summary>Vrstic seznama v enem klicu intranet.GetProductList — toliko, kot procedura dovoli
  /// (@Take je omejen na 20.000). Vsak klic znova prefiltrira in razvrsti cel pogled, zato so
  /// vecje strani ceneje: 196.000 izdelkov je deset klicev, ne sto (218).</summary>
  const int ListPageSize = 20_000;

  /// <summary>Izdelkov v enem klicu intranet.GetProductWorkbook (podatki na vrstico): izmerjeno
  /// po 218 okoli 1 ms na izdelek pri 5.000, s stalnim stroskom klica; pomnilnik drzi en paket.</summary>
  const int BatchSize = 5_000;

  /// <summary>Izdelkov v enem klicu mnozicnega zapisa (pim.SaveProductTextsBulk/AttributesBulk):
  /// dovolj, da je klicev malo, in dovolj malo, da ena mnozicna validacija ne drzi zaklepov predolgo.</summary>
  const int BulkProducts = 1_000;

  /// <summary>Spletni vrsti besedila; <c>TITLE_ERP</c> je last SAOP in pride iz registra.</summary>
  static readonly string[] WebTextTypes = ["WEB_TITLE", "DESCRIPTION"];

  string ConnectionString => ConnectionStringResolver.Resolve(configuration)
    ?? throw new InvalidOperationException("Povezava PIM ni nastavljena.");

  /* ─── Izvoz ────────────────────────────────────────────────────────────────────────── */

  /// <param name="onlySelectionKeys">Ključi izbranih vrstic v obliki »PodjetjeId|Šifra« — šifra
  /// artikla sama ni dovolj, ker isto šifro lahko nosi vec podjetij (isti dobavitelj v vec
  /// katalogih); brez podjetja bi izvoz vrnil vse njih namesto samo izbrane vrstice.</param>
  /// <remarks>
  /// Brez lastne zgornje meje (uporabnik 2026-09-17: »cel pogled je cel pogled«): baza pove,
  /// koliko vrstic ima pogled, seznam se bere stran za stranjo, podatki na vrstico (atributi,
  /// kategorije, mediji) pa po paketih sproti med pisanjem datoteke — noben trenutek ne drzi
  /// v pomnilniku vec kot en paket teh podatkov. Do zdaj je sel ves pogled v en klic z mejo
  /// @Take (20.000) in en klic intranet.GetProductWorkbook za vse izdelke hkrati.
  /// </remarks>
  /// <param name="includeGroups">Katere skupine stolpcev (<see cref="ProductWorkbookContract.GroupErp"/>
  /// ipd.) gredo v datoteko; null pomeni vse. Skupina »Ključ« gre v datoteko vedno, brez nje
  /// vrstice ne bi bilo mogoce prebrati nazaj. Uporabnik izbere skupine v pojavnem oknu »Stolpci«
  /// na /izdelki, da je datoteka manjša in uvoz nazaj hitrejši — uvoz s tem ne potrebuje nobene
  /// spremembe, ker ProductWorkbookContract.Match itak bere samo stolpce, ki so v datoteki.</param>
  public async Task<byte[]> BuildAsync(
    ProductListFilter filter, IReadOnlyCollection<string>? onlySelectionKeys = null,
    IReadOnlySet<string>? includeGroups = null,
    CancellationToken cancellationToken = default)
  {
    using var stream = new MemoryStream();
    await BuildToAsync(stream, filter, onlySelectionKeys, includeGroups, progress: null, cancellationToken);
    return stream.ToArray();
  }

  /// <summary>
  /// Isto kot <see cref="BuildAsync"/>, a zvezek pise naravnost v dani tok (datoteko na disku,
  /// glej ExportJobService/ExportResultStore) in sproti javlja stevilo zapisanih vrstic.
  /// Vrne stevilo vrstic v datoteki.
  /// </summary>
  public async Task<int> BuildToAsync(
    Stream destination, ProductListFilter filter, IReadOnlyCollection<string>? onlySelectionKeys,
    IReadOnlySet<string>? includeGroups, IProgress<int>? progress, CancellationToken cancellationToken)
  {
    var rows = await ListRowsAsync(filter, cancellationToken);
    if (onlySelectionKeys is { Count: > 0 })
      rows = rows.Where(row => onlySelectionKeys.Contains($"{row.OrganizationId}|{row.ItemId}", StringComparer.OrdinalIgnoreCase)).ToList();

    var sites = await ActiveWebSitesAsync(cancellationToken);
    var saopFields = await WritableSaopFieldsAsync(cancellationToken);
    var languages = await LanguagesAsync(filter.OrganizationId, cancellationToken);
    bool Included(ProductWorkbookColumn column) =>
      includeGroups is null || column.Group == ProductWorkbookContract.GroupKey || includeGroups.Contains(column.Group);

    // Prvi obhod da stolpce brez atributov; iz njih izhajajo kode polj, ki jih je treba
    // prebrati. Sifrant atributov dopolni stolpce v drugem obhodu.
    var probe = ProductWorkbookContract.Build(new(saopFields, sites, WebTextTypes, languages, [])).Where(Included).ToList();
    var fieldCodes = probe
      .Where(column => column.Target != ProductWorkbookTarget.ReadOnly)
      .Select(column => column.FieldKey)
      .Where(key => !key.StartsWith(ProductWorkbookContract.CategoryFieldPrefix, StringComparison.Ordinal)
        && key != ProductWorkbookContract.WebPublishField && key != ProductWorkbookContract.WebSitesField)
      .Distinct(StringComparer.Ordinal).ToList();

    // Nabor stolpcev se doloci enkrat, pred vrsticami: datoteka ima en nabor, ne enega na paket.
    // Register pride brez seznama izdelkov. Kadar je kategorija izbrana, je nabor njen in od
    // izdelkov neodvisen (isto kot doslej) — samo InSet, atributi drugih kategorij niso hrup.
    // Brez kategorije je to celoten sifrant: isti, s katerim uvoz prepozna stolpce datoteke z
    // neznanim naborom izdelkov (PreviewAsync). Prej ga je dolocal seznam vseh izdelkov pogleda
    // v enem klicu, kar pri katalogu brez zgornje meje ne gre vec.
    var wantsAttributes = includeGroups is null
      || includeGroups.Contains(ProductWorkbookContract.GroupAttributesInSet)
      || includeGroups.Contains(ProductWorkbookContract.GroupAttributesOutside);
    var registry = await ReadAsync([], [], filter.CategoryTreeCode, filter.CategoryCode, cancellationToken);
    var attributes = !wantsAttributes ? []
      : filter.CategoryCode is null
      ? OrderAttributes(registry.Attributes)
      : OrderAttributes(registry.Attributes).Where(attribute => attribute.InSet).ToList();

    var definition = ProductWorkbookContract.Build(new(saopFields, sites, WebTextTypes, languages, attributes))
      .Where(Included).ToList();
    var columns = definition.Select(column => new WorkbookColumn(
      column.Header, column.Kind, column.Width, column.Group,
      registry.Required.ContainsKey(column.FieldKey) ? WorkbookCellTone.Required : WorkbookCellTone.None)).ToArray();

    // Jezikovna razlicica strani (svetila_si_en) se izpise pod imenom primarne (Svetila.si) —
    // uporabnik vidi eno stran, ne dveh vrstic za isto stvar. Uvoz to razsiri nazaj, glej ApplySitesAsync/SiteLookup.
    var primaryByTree = PrimarySiteByTree(sites);
    var siteNames = sites.ToDictionary(site => site.Code, site => primaryByTree[site.CategoryTreeCode].Name, StringComparer.OrdinalIgnoreCase);

    await WorkbookWriter.WriteAsync(destination, "Izdelki", columns,
      CellsAsync(rows, fieldCodes, definition, siteNames, progress, cancellationToken), cancellationToken: cancellationToken);
    return rows.Count;
  }

  /// <summary>Vse vrstice pogleda, stran za stranjo; baza sama pove, koliko jih je (TotalCount).</summary>
  async Task<List<ProductListRow>> ListRowsAsync(ProductListFilter filter, CancellationToken cancellationToken)
  {
    var rows = new List<ProductListRow>();
    var skip = 0;
    while (rows.Count < MaxRows)
    {
      var page = await workbench.GetProductListAsync(filter with { Skip = skip, Take = ListPageSize }, cancellationToken);
      rows.AddRange(page.Rows);
      if (page.Rows.Count == 0 || rows.Count >= page.TotalCount) break;
      skip += ListPageSize;
    }
    return rows;
  }

  /// <summary>
  /// Celice vrstic po paketih: podatki na vrstico se preberejo za en paket, zapisejo in
  /// spustijo, preden pride naslednji. Zapisovalnik (WorkbookWriter.WriteAsync) jih bere
  /// sproti, zato datoteka nastaja, medtem ko se baza se bere.
  /// </summary>
  async IAsyncEnumerable<IReadOnlyList<object?>> CellsAsync(
    List<ProductListRow> rows, IReadOnlyList<string> fieldCodes, IReadOnlyList<ProductWorkbookColumn> definition,
    IReadOnlyDictionary<string, string> siteNames, IProgress<int>? progress,
    [EnumeratorCancellation] CancellationToken cancellationToken)
  {
    for (var offset = 0; offset < rows.Count; offset += BatchSize)
    {
      var batch = rows.GetRange(offset, Math.Min(BatchSize, rows.Count - offset));
      var sheet = await ReadAsync(batch.Select(row => row.ProductId).ToList(), fieldCodes, null, null, cancellationToken);
      foreach (var row in batch)
        yield return definition.Select(column => Cell(column, row, sheet, siteNames)).ToArray();
      progress?.Report(offset + batch.Count);
    }
  }

  object? Cell(
    ProductWorkbookColumn column, ProductListRow row, WorkbookData sheet,
    IReadOnlyDictionary<string, string> siteNames)
  {
    var value = Value(column, row, sheet, siteNames);
    // Rdece se obarva samo prazno polje, ki je pogoj za validacijo. Ce bi se obarvala vsaka
    // prazna celica, bi bil list rdec povsod in oznaka ne bi pomenila nicesar.
    if (value is null or "" && sheet.Required.ContainsKey(column.FieldKey))
      return new WorkbookCell(null, WorkbookCellTone.Missing);
    return value;
  }

  object? Value(
    ProductWorkbookColumn column, ProductListRow row, WorkbookData sheet,
    IReadOnlyDictionary<string, string> siteNames)
  {
    switch (column.FieldKey)
    {
      case ProductWorkbookContract.OrganizationField: return row.OrganizationName;
      case ProductWorkbookContract.ItemIdField: return row.ItemId;
      case "Row.Name": return row.Name;
      case "Row.ErpStatus": return StatusText(row.ErpStatus);
      case "Row.WebStatus": return StatusText(row.WebStatus);
      case "Row.Completeness": return row.Completeness;
      case "Row.OpenIssueCount": return row.OpenIssueCount;
      case "Row.LastChangedUtc": return row.LastChangedUtc;
      case ProductWorkbookContract.WebPublishField: return ProductWorkbookContract.YesNo(row.WebPublish);
      case ProductWorkbookContract.WebSitesField:
        return ProductWorkbookContract.JoinList(sheet.SitesOf(row.ProductId)
          .Select(code => siteNames.TryGetValue(code, out var name) ? name : code)
          .Distinct(StringComparer.OrdinalIgnoreCase));
      case "ProductMedia.Url":
        return sheet.Media.TryGetValue(row.ProductId, out var media) ? media : null;
      case "ProductMedia.Documents":
        return sheet.Documents.TryGetValue(row.ProductId, out var documents) ? documents : null;
    }

    if (column.FieldKey.StartsWith(ProductWorkbookContract.CategoryFieldPrefix, StringComparison.Ordinal))
    {
      var site = column.FieldKey[ProductWorkbookContract.CategoryFieldPrefix.Length..];
      return sheet.Categories.TryGetValue((row.ProductId, site), out var paths) ? paths : null;
    }

    if (column.FieldKey.StartsWith(ProductWorkbookContract.AttributeFieldPrefix, StringComparison.Ordinal))
    {
      var code = column.FieldKey[ProductWorkbookContract.AttributeFieldPrefix.Length..];
      return sheet.AttributeValues.TryGetValue((row.ProductId, code), out var attribute) ? attribute : null;
    }

    return sheet.Values.TryGetValue((row.ProductId, column.FieldKey), out var found) ? found : null;
  }

  /// <summary>Ime datoteke z datumom, da se izvozi ne prepisujejo v mapi prenosov.</summary>
  public static string FileName(DateTime nowUtc) =>
    "delovni-list-izdelki-" + nowUtc.ToPimLocal().ToString("yyyyMMdd-HHmm", CultureInfo.InvariantCulture) + ".xlsx";

  static string StatusText(string status) => status switch
  {
    "VALID" => "pripravljen",
    "INVALID" => "blokiran",
    "PENDING" => "čaka validacijo",
    "NOT_CONFIGURED" => "ni profila",
    _ => status,
  };

  /* ─── Uvoz: predogled ──────────────────────────────────────────────────────────────── */

  /// <param name="defaultOrganizationId">Podjetje za vrstice brez stolpca »Podjetje«.</param>
  public async Task<ProductWorkbookPreview> PreviewAsync(
    Stream file, int? defaultOrganizationId, CancellationToken cancellationToken = default)
  {
    var organizations = await data.GetOrganizationsAsync(cancellationToken);
    var sites = await ActiveWebSitesAsync(cancellationToken);
    var saopFields = await WritableSaopFieldsAsync(cancellationToken);
    var languages = await LanguagesAsync(defaultOrganizationId, cancellationToken);

    // Stolpci atributov niso znani vnaprej: uvazamo lahko datoteko, ki jo je izvozil nekdo z
    // drugim naborom. Sifrant se zato prebere brez omejitve na izdelke — prazen seznam pomeni
    // ves sifrant (migracija 172). Vrstni red je isti kot pri izvozu, sicer bi se stolpca z
    // enakim imenom v obe smeri razresila drugace in vrednost bi pristala na napacnem polju.
    var attributes = OrderAttributes((await ReadAsync([], [], null, null, cancellationToken)).Attributes);

    var sheet = WorkbookTable.Read(file, sheetName: null, headerHints: ProductWorkbookContract.HeaderHints);
    var definition = ProductWorkbookContract.Build(new(saopFields, sites, WebTextTypes, languages, attributes));
    var matches = ProductWorkbookContract.Match(sheet.Headers, definition);

    var keyColumn = matches.FirstOrDefault(match => match.Column?.FieldKey == ProductWorkbookContract.ItemIdField);
    if (keyColumn is null)
      throw new WorkbookReadException("Zvezek nima stolpca s šifro artikla. Poimenuj ga »Šifra artikla« ali »ItemID«.");
    var organizationColumn = matches.FirstOrDefault(match => match.Column?.FieldKey == ProductWorkbookContract.OrganizationField);

    var problems = new List<string>();
    if (organizationColumn is null && defaultOrganizationId is null)
      problems.Add("Zvezek nima stolpca »Podjetje«, podjetje pa ni izbrano. Šifra artikla je enolična samo znotraj podjetja.");

    var rows = new List<ProductWorkbookRowChange>();
    var seen = new HashSet<(int, string)>();

    for (var index = 0; index < sheet.Rows.Count; index++)
    {
      var cells = sheet.Rows[index];
      // Prva podatkovna vrstica je druga za naslovi; list s skupinami ima naslova dva.
      var rowNumber = index + 2;
      var itemId = cells[keyColumn.Index].Trim();
      if (itemId.Length == 0) continue;

      var organizationId = defaultOrganizationId;
      var organizationName = string.Empty;
      if (organizationColumn is not null)
      {
        var text = cells[organizationColumn.Index].Trim();
        if (text.Length > 0)
        {
          var match = organizations.FirstOrDefault(organization =>
            WorkbookHeader.Same(organization.Name, text)
            || organization.OrganizationId.ToString(CultureInfo.InvariantCulture) == text);
          if (match is null)
          {
            problems.Add($"Vrstica {rowNumber}: podjetja »{text}« ni; vrstica se preskoči.");
            continue;
          }
          organizationId = match.OrganizationId;
          organizationName = match.Name;
        }
      }
      if (organizationId is null)
      {
        problems.Add($"Vrstica {rowNumber}: podjetje ni znano; vrstica se preskoči.");
        continue;
      }
      if (organizationName.Length == 0)
        organizationName = organizations.FirstOrDefault(organization => organization.OrganizationId == organizationId)?.Name
          ?? organizationId.Value.ToString(CultureInfo.InvariantCulture);

      if (!seen.Add((organizationId.Value, itemId)))
      {
        problems.Add($"Vrstica {rowNumber}: artikel {itemId} je v zvezku večkrat; upoštevana bo prva.");
        continue;
      }

      var pim = new Dictionary<string, string>(StringComparer.Ordinal);
      var saopValues = new Dictionary<string, string>(StringComparer.Ordinal);
      foreach (var match in matches)
      {
        if (match.Column is null || match.Column.Target == ProductWorkbookTarget.ReadOnly) continue;
        var value = cells[match.Index].Trim();
        // Prazna celica pomeni »ne dotikaj se«. Brez tega bi en uvoz izpraznil cel katalog.
        if (value.Length == 0) continue;
        if (match.Column.Target == ProductWorkbookTarget.Pim) pim[match.Column.FieldKey] = value;
        else saopValues[match.Column.FieldKey] = value;
      }

      if (pim.Count == 0 && saopValues.Count == 0) continue;
      rows.Add(new(rowNumber, organizationId.Value, organizationName, itemId, pim, saopValues));
    }

    var unknown = matches.Where(match => match.Column is null && !string.IsNullOrWhiteSpace(match.Header))
      .Select(match => match.Header).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
    var readOnly = matches.Where(match => match.Column?.Target == ProductWorkbookTarget.ReadOnly)
      .Select(match => match.Header).Distinct(StringComparer.OrdinalIgnoreCase).ToList();

    rows = await OnlyChangedAsync(rows, siteByToken: SiteLookup(sites), problems, cancellationToken);

    if (rows.Count == 0) problems.Add("V zvezku ni nobene vrstice, ki bi kaj spremenila. Kar je v datoteki, je v PIM že tako zapisano.");
    return new(rows, unknown, readOnly, problems);
  }

  /// <summary>
  /// Odstrani celice, ki nosijo isto vrednost, kot je ze zapisana.
  ///
  /// Brez tega bi uvoz nespremenjene datoteke prijavil vsako izpolnjeno celico kot spremembo:
  /// pri 20.000 izdelkih bi to pomenilo desettisoce sporocil v odhodni vrsti za SAOP, ki ne
  /// spremenijo nicesar, in predogled, ki uporabniku ne pove, kaj je pravzaprav popravil.
  /// Uvoz mora prinesti to, kar je clovek spremenil, in nic drugega.
  /// </summary>
  async Task<List<ProductWorkbookRowChange>> OnlyChangedAsync(
    List<ProductWorkbookRowChange> rows, IReadOnlyDictionary<string, IReadOnlyList<string>> siteByToken,
    List<string> problems, CancellationToken cancellationToken)
  {
    if (rows.Count == 0) return rows;

    var keys = new Dictionary<(int, string), ProductKey>();
    foreach (var group in rows.GroupBy(row => row.OrganizationId))
      foreach (var pair in await ResolveProductIdsAsync(group.Key, group.Select(row => row.ItemId).ToList(), cancellationToken))
        keys[(group.Key, pair.Key)] = pair.Value;

    var fieldCodes = rows
      .SelectMany(row => row.PimValues.Keys.Concat(row.SaopValues.Keys))
      .Where(key => !key.StartsWith(ProductWorkbookContract.CategoryFieldPrefix, StringComparison.Ordinal)
        && key != ProductWorkbookContract.WebPublishField && key != ProductWorkbookContract.WebSitesField)
      .Distinct(StringComparer.Ordinal).ToList();

    var productIds = rows.Where(row => keys.ContainsKey((row.OrganizationId, row.ItemId)))
      .Select(row => keys[(row.OrganizationId, row.ItemId)].ProductId).Distinct().ToList();
    var current = await ReadBatchedAsync(productIds, fieldCodes, cancellationToken);

    var result = new List<ProductWorkbookRowChange>(rows.Count);
    foreach (var row in rows)
    {
      if (!keys.TryGetValue((row.OrganizationId, row.ItemId), out var key))
      {
        // Artikla ni. Vrstica odpade, ker je ni kam zapisati, a se to pove — tiho izpuscena
        // vrstica bi pomenila, da uporabnik misli, da je uvozil vec, kot je res.
        problems.Add($"Vrstica {row.RowNumber}: artikla {row.ItemId} v podjetju {row.OrganizationName} ni.");
        continue;
      }

      var pim = new Dictionary<string, string>(StringComparer.Ordinal);
      foreach (var pair in row.PimValues)
        if (Changed(pair.Key, pair.Value, key, current, siteByToken)) pim[pair.Key] = pair.Value;

      var saopValues = new Dictionary<string, string>(StringComparer.Ordinal);
      foreach (var pair in row.SaopValues)
        if (Changed(pair.Key, pair.Value, key, current, siteByToken)) saopValues[pair.Key] = pair.Value;

      if (pim.Count == 0 && saopValues.Count == 0) continue;
      result.Add(row with { PimValues = pim, SaopValues = saopValues });
    }
    return result;
  }

  static string? Stored(string fieldKey, long productId, WorkbookData current)
  {
    if (fieldKey.StartsWith(ProductWorkbookContract.AttributeFieldPrefix, StringComparison.Ordinal))
      return current.AttributeValues.TryGetValue(
        (productId, fieldKey[ProductWorkbookContract.AttributeFieldPrefix.Length..]), out var attribute) ? attribute : null;
    return current.Values.TryGetValue((productId, fieldKey), out var value) ? value : null;
  }

  static bool Changed(
    string fieldKey, string incoming, ProductKey key, WorkbookData current,
    IReadOnlyDictionary<string, IReadOnlyList<string>> siteByToken)
  {
    if (fieldKey == ProductWorkbookContract.WebPublishField)
    {
      // Zastavica ni v canon.FieldValue, zato je edina primerjava tista s canon.Product.
      // Brez nje bi vsaka vrstica prijavila spremembo objave, tudi ce je nihce ni spremenil.
      var parsed = ProductWorkbookContract.ParseYesNo(incoming);
      // Nerazumljivo vrednost pustimo naprej: uvoz jo prijavi kot napako vrstice, ne kot tisino.
      return parsed is null || parsed.Value != key.WebPublish;
    }

    if (fieldKey == ProductWorkbookContract.WebSitesField)
    {
      var listed = ProductWorkbookContract.SplitList(incoming)
        .SelectMany(token => siteByToken.TryGetValue(WorkbookHeader.Normalize(token), out var codes) ? codes : [token])
        .ToList();
      return !SameList(listed, current.SitesOf(key.ProductId));
    }

    if (fieldKey.StartsWith(ProductWorkbookContract.CategoryFieldPrefix, StringComparison.Ordinal))
    {
      var site = fieldKey[ProductWorkbookContract.CategoryFieldPrefix.Length..];
      var stored = current.Categories.TryGetValue((key.ProductId, site), out var paths)
        ? ProductWorkbookContract.SplitList(paths) : [];
      return !SameList(ProductWorkbookContract.SplitList(incoming), stored);
    }

    return !SameValue(incoming, Stored(fieldKey, key.ProductId, current));
  }

  /* ─── Uvoz: zapis ─────────────────────────────────────────────────────────────────── */

  /// <param name="progress">Sprotno besedilo napredka za stran uvoza (koraki in stevci); null = brez.</param>
  public async Task<ProductWorkbookOutcome> ApplyAsync(
    ProductWorkbookPreview preview, string actor, string? note = null,
    IProgress<string>? progress = null,
    CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(preview);
    var problems = new List<string>();
    var sites = await ActiveWebSitesAsync(cancellationToken);
    var siteByToken = SiteLookup(sites);

    // Poti kategorij, veljavne za vsako spletno stran, ki jo ta uvoz sploh omenja — preberemo
    // jih enkrat vnaprej, ne na vrstico, da lahko napačno pot povemo natančno (katera pot, za
    // katero stran), namesto da bi to za vsako slabo vrstico posebej povedala šele baza
    // (pim.SetProductCategories, napaka 106007, vedno samo prva najdena). Ta seznam ponovi isti
    // pogoj vnaprej; baza ob dejanskem zapisu ostaja zadnja beseda.
    var touchedSiteCodes = preview.Rows
      .SelectMany(row => row.PimValues.Keys)
      .Where(key => key.StartsWith(ProductWorkbookContract.CategoryFieldPrefix, StringComparison.Ordinal))
      .Select(key => key[ProductWorkbookContract.CategoryFieldPrefix.Length..])
      .Distinct(StringComparer.OrdinalIgnoreCase).ToList();
    var validCategoryPaths = await ValidCategoryPathsBySiteAsync(touchedSiteCodes, cancellationToken);

    // Zapisovalne procedure delajo z ProductId; datoteka nosi sifro. Preslikava gre v enem
    // klicu na podjetje, ne v enem klicu na vrstico.
    var productIds = new Dictionary<(int OrganizationId, string ItemId), long>();
    foreach (var group in preview.Rows.GroupBy(row => row.OrganizationId))
      foreach (var pair in await ResolveProductIdsAsync(group.Key, group.Select(row => row.ItemId).ToList(), cancellationToken))
        productIds[(group.Key, pair.Key)] = pair.Value.ProductId;

    var known = preview.Rows.Where(row => productIds.ContainsKey((row.OrganizationId, row.ItemId))).ToList();
    foreach (var row in preview.Rows.Except(known))
      problems.Add($"Vrstica {row.RowNumber}: artikla {row.ItemId} v podjetju {row.OrganizationName} ni.");

    // Kategorije in strani je mogoce pravilno postaviti samo ob znanju, kaj je zdaj zapisano:
    // stran, ki je v celici ni, mora kategorije izgubiti. Branje gre po paketih (218), ne v
    // enem klicu za vse izdelke datoteke.
    progress?.Report("Berem trenutno stanje izdelkov …");
    var current = await ReadBatchedAsync(
      known.Select(row => productIds[(row.OrganizationId, row.ItemId)]).Distinct().ToList(), [], cancellationToken);

    var pimChanges = 0;
    var touchedRows = new HashSet<int>();
    var saopByOrganization = new Dictionary<int, List<(string ItemId, string FieldKey, string? Value)>>();

    // 218: besedila in atributi se ne zapisujejo vrstica za vrstico (procedura + validacija
    // izdelka na vrstico, izmerjeno 10 s na vrstico pred 218), ampak zbrano po podjetjih in v
    // paketih prek pim.SaveProductTextsBulk / pim.SaveProductAttributesBulk: en MERGE, ena
    // serija zgodovine in ena mnozicna validacija na paket. Vrstica, ki je paket ne zapise,
    // dobi opozorilo s svojo stevilko (rowByProduct).
    var textsByOrganization = new Dictionary<int, List<ProductTextBulkEdit>>();
    var attributesByOrganization = new Dictionary<int, List<ProductAttributeBulkEdit>>();
    var rowByProduct = new Dictionary<long, ProductWorkbookRowChange>();
    foreach (var row in known) rowByProduct.TryAdd(productIds[(row.OrganizationId, row.ItemId)], row);
    var bulkRows = new HashSet<int>();

    var processed = 0;
    foreach (var row in known)
    {
      cancellationToken.ThrowIfCancellationRequested();
      var productId = productIds[(row.OrganizationId, row.ItemId)];
      var rowChanged = false;

      // 1) Besedila — zbrana; zapis spodaj v paketih
      var texts = row.PimValues
        .Where(pair => pair.Key.StartsWith(ProductWorkbookContract.TextFieldPrefix, StringComparison.Ordinal))
        .Select(pair => pair.Key[ProductWorkbookContract.TextFieldPrefix.Length..].Split('.', 2))
        .Where(parts => parts.Length == 2)
        .Select(parts => new ProductTextBulkEdit(productId, parts[1], parts[0],
          row.PimValues[$"{ProductWorkbookContract.TextFieldPrefix}{parts[0]}.{parts[1]}"]))
        .ToList();
      if (texts.Count > 0)
      {
        if (!textsByOrganization.TryGetValue(row.OrganizationId, out var textList))
          textsByOrganization[row.OrganizationId] = textList = [];
        textList.AddRange(texts);
        bulkRows.Add(row.RowNumber);
      }

      // 2) Atributi — enako
      var attributes = row.PimValues
        .Where(pair => pair.Key.StartsWith(ProductWorkbookContract.AttributeFieldPrefix, StringComparison.Ordinal))
        .Select(pair => new ProductAttributeBulkEdit(productId, pair.Key[ProductWorkbookContract.AttributeFieldPrefix.Length..], pair.Value))
        .ToList();
      if (attributes.Count > 0)
      {
        if (!attributesByOrganization.TryGetValue(row.OrganizationId, out var attributeList))
          attributesByOrganization[row.OrganizationId] = attributeList = [];
        attributeList.AddRange(attributes);
        bulkRows.Add(row.RowNumber);
      }

      // 3) Objava na spletu ne gre skozi tu: register jo pozna kot element WebPublish, torej
      //    potuje v SAOP in je med ERP polji spodaj. Tu se preveri samo, ali je zapisana
      //    vrednost sploh razumljiva — »mogoce« ni ne da ne ne.
      var erp = row.SaopValues;
      if (erp.TryGetValue(ProductWorkbookContract.WebPublishField, out var publishText)
        && ProductWorkbookContract.ParseYesNo(publishText) is null)
      {
        problems.Add($"Vrstica {row.RowNumber}: objava na spletu »{publishText}« ni da ali ne; polje se preskoči.");
        erp = erp.Where(pair => pair.Key != ProductWorkbookContract.WebPublishField)
          .ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.Ordinal);
      }

      // 4) Spletne strani in kategorije
      var siteChanges = await ApplySitesAsync(
        row, productId, current, siteByToken, sites, validCategoryPaths, actor, note, problems, cancellationToken);
      if (siteChanges > 0) { pimChanges += siteChanges; rowChanged = true; }

      // 5) ERP polja gredo v vrsto, ne v katalog
      if (erp.Count > 0)
      {
        if (!saopByOrganization.TryGetValue(row.OrganizationId, out var list))
          saopByOrganization[row.OrganizationId] = list = [];
        foreach (var pair in erp) list.Add((row.ItemId, pair.Key, pair.Value));
        rowChanged = true;
      }

      if (rowChanged) touchedRows.Add(row.RowNumber);
      if (++processed % 500 == 0)
        progress?.Report($"Spletne strani in kategorije: {processed:N0} od {known.Count:N0} vrstic …");
    }

    // Mnozicni zapis besedil in atributov: po podjetjih, v paketih po BulkProducts izdelkov.
    string Describe(long productId) => rowByProduct.TryGetValue(productId, out var owner)
      ? $"Vrstica {owner.RowNumber} (artikel {owner.ItemId})" : $"Izdelek {productId}";
    var bulkTotal = textsByOrganization.Sum(pair => pair.Value.Select(item => item.ProductId).Distinct().Count())
      + attributesByOrganization.Sum(pair => pair.Value.Select(item => item.ProductId).Distinct().Count());
    var bulkDone = 0;
    foreach (var (organizationId, edits) in textsByOrganization)
      foreach (var chunk in edits.GroupBy(item => item.ProductId).Chunk(BulkProducts))
      {
        try
        {
          var outcome = await edit.SaveTextsBulkAsync(organizationId, chunk.SelectMany(group => group).ToList(), actor, note, cancellationToken);
          pimChanges += (int)outcome.ChangedCount;
          foreach (var skip in outcome.Skipped) problems.Add($"{Describe(skip.ProductId)}: besedila niso zapisana — {skip.Reason}");
        }
        catch (Exception failure)
        {
          problems.Add($"Besedila za {chunk.Length:N0} izdelkov (podjetje {organizationId}) niso zapisana — {failure.Message}");
        }
        bulkDone += chunk.Length;
        progress?.Report($"Zapisujem besedila in atribute: {bulkDone:N0} od {bulkTotal:N0} izdelkov …");
      }
    foreach (var (organizationId, edits) in attributesByOrganization)
      foreach (var chunk in edits.GroupBy(item => item.ProductId).Chunk(BulkProducts))
      {
        try
        {
          var outcome = await edit.SaveAttributesBulkAsync(organizationId, chunk.SelectMany(group => group).ToList(), actor, note, cancellationToken);
          pimChanges += (int)outcome.ChangedCount;
          foreach (var skip in outcome.Skipped) problems.Add($"{Describe(skip.ProductId)}: atributi niso zapisani — {skip.Reason}");
        }
        catch (Exception failure)
        {
          problems.Add($"Atributi za {chunk.Length:N0} izdelkov (podjetje {organizationId}) niso zapisani — {failure.Message}");
        }
        bulkDone += chunk.Length;
        progress?.Report($"Zapisujem besedila in atribute: {bulkDone:N0} od {bulkTotal:N0} izdelkov …");
      }
    touchedRows.UnionWith(bulkRows);
    var touched = touchedRows.Count;
    progress?.Report("Uvrščam ERP polja v vrsto za SAOP …");

    var batches = new List<long>();
    var queued = 0; var duplicates = 0; var rejected = 0;
    foreach (var (organizationId, changes) in saopByOrganization)
    {
      try
      {
        var outcome = await saop.EnqueueAsync(organizationId, changes, actor, "EXCEL",
          note ?? "Delovni list izdelkov", cancellationToken);
        batches.Add(outcome.OutboundBatchId);
        queued += outcome.Queued; duplicates += outcome.Duplicates; rejected += outcome.Rejected;
        foreach (var line in outcome.Rows.Where(line => line.Status == "Rejected"))
          problems.Add($"Artikel {line.ItemId}, polje {line.FieldKey}: zavrnjeno — {line.Reason}");
      }
      catch (Exception failure) { problems.Add($"ERP spremembe podjetja {organizationId} niso uvrščene — {failure.Message}"); }
    }

    return new(touched, pimChanges, queued, duplicates, rejected, batches, problems);
  }

  /// <summary>
  /// Postavi spletne strani in kategorije ene vrstice.
  ///
  /// Pravilo je isto kot v izvozu na splet (migracija 146): izdelek je na strani natanko
  /// takrat, kadar ima na njej kategorijo. Zato stolpec »Spletne strani« ni svoja zastavica,
  /// ampak ukaz nad kategorijami: stran, ki je v celici ni, kategorije izgubi; stran, ki je
  /// v celici je, jih mora imeti — iz svojega stolpca ali že od prej.
  /// </summary>
  async Task<int> ApplySitesAsync(
    ProductWorkbookRowChange row, long productId, WorkbookData current,
    IReadOnlyDictionary<string, IReadOnlyList<string>> siteByToken, IReadOnlyList<WorkbookWebSite> sites,
    IReadOnlyDictionary<string, HashSet<string>> validCategoryPaths,
    string actor, string? note, List<string> problems, CancellationToken cancellationToken)
  {
    var written = 0;
    var currentSites = current.SitesOf(productId);

    // Kategorije, ki jih vrstica prinasa, po kodi strani.
    var incoming = new Dictionary<string, IReadOnlyList<string>>(StringComparer.OrdinalIgnoreCase);
    foreach (var pair in row.PimValues)
    {
      if (!pair.Key.StartsWith(ProductWorkbookContract.CategoryFieldPrefix, StringComparison.Ordinal)) continue;
      incoming[pair.Key[ProductWorkbookContract.CategoryFieldPrefix.Length..]] = ProductWorkbookContract.SplitList(pair.Value);
    }

    List<string>? listed = null;
    if (row.PimValues.TryGetValue(ProductWorkbookContract.WebSitesField, out var siteCell))
    {
      listed = [];
      foreach (var token in ProductWorkbookContract.SplitList(siteCell))
      {
        if (siteByToken.TryGetValue(WorkbookHeader.Normalize(token), out var codes)) listed.AddRange(codes);
        else problems.Add($"Vrstica {row.RowNumber}: spletne strani »{token}« ni v registru; prezrta. Na voljo: {string.Join(", ", sites.Select(site => site.Name))}.");
      }
    }

    var affected = new HashSet<string>(incoming.Keys, StringComparer.OrdinalIgnoreCase);
    if (listed is not null) { affected.UnionWith(listed); affected.UnionWith(currentSites); }

    foreach (var site in affected)
    {
      var stays = listed is null || listed.Contains(site, StringComparer.OrdinalIgnoreCase);
      IReadOnlyList<string> target;
      if (!stays) target = [];
      else if (incoming.TryGetValue(site, out var given) && given.Count > 0)
      {
        // Preverimo tu, ne šele v bazi: uporabnik izve TOČNO katera pot(i) v celici ne obstajajo
        // — vse naenkrat, ne le prva (pim.SetProductCategories, THROW 106007, vrne vedno samo
        // eno). Brez znanega drevesa (stran med uvozom izgine, siteCodes prazen) se preskoči in
        // odloci baza, tako kot doslej.
        var unknownPaths = validCategoryPaths.TryGetValue(site, out var valid)
          ? given.Where(path => !valid.Contains(path)).ToList()
          : [];
        if (unknownPaths.Count > 0)
        {
          foreach (var path in unknownPaths)
            problems.Add($"Vrstica {row.RowNumber}: kategorija »{path}« za stran »{SiteName(sites, site)}« "
              + "ne obstaja v drevesu te strani — preveri zapis (ločilo » > «, presledki) ali izberi obstoječo "
              + "pot na /kategorije/preslikave; stran ostane pri prejšnjih kategorijah.");
          continue;
        }
        target = given;
      }
      else
      {
        var existing = current.Categories.TryGetValue((productId, site), out var paths)
          ? ProductWorkbookContract.SplitList(paths) : [];
        if (existing.Count == 0)
        {
          problems.Add($"Vrstica {row.RowNumber}: stran »{SiteName(sites, site)}« nima kategorije — izdelek nanjo ne gre. Izpolni stolpec »Kategorije — {SiteName(sites, site)}«.");
          continue;
        }
        target = existing;
      }

      var before = current.Categories.TryGetValue((productId, site), out var stored)
        ? ProductWorkbookContract.SplitList(stored) : [];
      if (before.OrderBy(path => path, StringComparer.Ordinal)
          .SequenceEqual(target.OrderBy(path => path, StringComparer.Ordinal), StringComparer.Ordinal))
        continue;

      try
      {
        await categories.SetProductCategoriesAsync(row.OrganizationId, row.ItemId, site, target, actor, note, cancellationToken);
        written++;
      }
      catch (Exception failure)
      {
        problems.Add($"Vrstica {row.RowNumber}: kategorije za »{SiteName(sites, site)}« niso zapisane — {failure.Message}");
      }
    }

    return written;
  }

  static string SiteName(IReadOnlyList<WorkbookWebSite> sites, string code) =>
    sites.FirstOrDefault(site => string.Equals(site.Code, code, StringComparison.OrdinalIgnoreCase))?.Name ?? code;

  /// <summary>
  /// Ime in koda strani sta oba sprejeta; uporabnik pise ime, datoteka nosi ime. Ime primarne
  /// strani vsakega drevesa (tisto, ki ga izvoz izpise namesto jezikovne razlicice — glej
  /// BuildAsync/siteNames) se pri uvozu razsiri nazaj na VSE strani tega drevesa, da vpis
  /// »Svetila.si« ne odjavi izdelka s »Svetila.si (ANG)«. Jezikovno ime samo (»Svetila.si
  /// (ANG)«) in vsaka koda ostajata en na en, ce jih kdo vpise izrecno.
  /// </summary>
  static IReadOnlyDictionary<string, IReadOnlyList<string>> SiteLookup(IReadOnlyList<WorkbookWebSite> sites)
  {
    var byTree = sites.GroupBy(site => site.CategoryTreeCode)
      .ToDictionary(group => group.Key, group => (IReadOnlyList<string>)group.Select(site => site.Code).ToArray());
    var primaryByTree = PrimarySiteByTree(sites);

    var lookup = new Dictionary<string, IReadOnlyList<string>>(StringComparer.Ordinal);
    foreach (var site in sites)
    {
      IReadOnlyList<string> codes = [site.Code];
      lookup.TryAdd(WorkbookHeader.Normalize(site.Code), codes);
      var isPrimary = primaryByTree[site.CategoryTreeCode].Code == site.Code;
      lookup.TryAdd(WorkbookHeader.Normalize(site.Name), isPrimary ? byTree[site.CategoryTreeCode] : codes);
    }
    return lookup;
  }

  /* ─── Registri in branje ──────────────────────────────────────────────────────────── */

  public async Task<IReadOnlyList<WorkbookWebSite>> ActiveWebSitesAsync(CancellationToken cancellationToken = default) =>
    (await catalog.GetWebSitesAsync(cancellationToken))
      .Where(site => site.IsActive)
      .Select(site => new WorkbookWebSite(site.WebSiteCode,
        string.IsNullOrWhiteSpace(site.WebSiteName) ? site.WebSiteCode : site.WebSiteName,
        site.CategoryTreeCode))
      .ToList();

  /// <summary>
  /// Poti, ki v drevesu dane spletne strani res obstajajo — isti pogoj, ki ga ob zapisu preveri
  /// <c>pim.SetProductCategories</c> (ujemanje po <c>CategoryTreeCode</c> in <c>LanguageCode</c>
  /// strani v <c>canon.CategoryPathTranslated</c>, migracija 059). Prebere se enkrat na klic
  /// <see cref="ApplyAsync"/>, ne na vrstico: strani je največ nekaj, poti na stran nekaj sto —
  /// brati jih znova za vsako vrstico bi bilo tisoče nepotrebnih klicev baze. Primerjava proti
  /// tem potem je namenoma neobčutljiva na velike/male črke (<see cref="StringComparer.OrdinalIgnoreCase"/>):
  /// če bi bila baza strožja, bi napačno pot vseeno ujela ona sama ob zapisu; ta seznam sme biti
  /// kvečjemu preveč popustljiv, nikoli preveč strog, sicer bi zavrnil pot, ki jo baza sprejme.
  /// </summary>
  async Task<IReadOnlyDictionary<string, HashSet<string>>> ValidCategoryPathsBySiteAsync(
    IReadOnlyList<string> siteCodes, CancellationToken cancellationToken)
  {
    var result = new Dictionary<string, HashSet<string>>(StringComparer.OrdinalIgnoreCase);
    if (siteCodes.Count == 0) return result;

    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("""
      SELECT site.WebSiteCode, path.CategoryPath
      FROM canon.WebSite AS site
      INNER JOIN canon.CategoryPathTranslated AS path
        ON path.CategoryTreeCode = site.CategoryTreeCode AND path.LanguageCode = site.LanguageCode
      WHERE site.WebSiteCode IN (SELECT value FROM OPENJSON(@SiteCodesJson));
      """, connection) { CommandTimeout = 60 };
    command.Parameters.Add("@SiteCodesJson", SqlDbType.NVarChar, -1).Value = JsonSerializer.Serialize(siteCodes);

    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    while (await reader.ReadAsync(cancellationToken))
    {
      var site = PimDb.TextOrEmpty(reader, "WebSiteCode");
      if (!result.TryGetValue(site, out var paths)) result[site] = paths = new(StringComparer.OrdinalIgnoreCase);
      paths.Add(PimDb.TextOrEmpty(reader, "CategoryPath"));
    }
    return result;
  }

  /// <summary>
  /// Prva stran vsakega drevesa kategorij, po vrstnem redu GetWebSitesAsync (SortOrder). Jezikovne
  /// razlicice iste strani (svetila_si / svetila_si_en) delijo drevo; uporabnik vidi in pise samo
  /// ime primarne, ki na uvozu pomeni celotno skupino — glej ExpandSiteCodes.
  /// </summary>
  static IReadOnlyDictionary<string, WorkbookWebSite> PrimarySiteByTree(IReadOnlyList<WorkbookWebSite> sites)
  {
    var primary = new Dictionary<string, WorkbookWebSite>(StringComparer.Ordinal);
    foreach (var site in sites) primary.TryAdd(site.CategoryTreeCode, site);
    return primary;
  }

  /// <summary>Dodatna lastnost 2-4 se v delovnem listu ne uporabljajo; samo prva ostane.</summary>
  static readonly HashSet<string> HiddenElementNames = new(StringComparer.OrdinalIgnoreCase)
  {
    "AdditionalProperty2ID", "AdditionalProperty3ID", "AdditionalProperty4ID",
  };

  async Task<IReadOnlyList<SaopWritableField>> WritableSaopFieldsAsync(CancellationToken cancellationToken)
  {
    var template = await export.GetTemplateColumnsAsync(cancellationToken);
    return template
      .Where(column => column.IsWritable && !string.IsNullOrWhiteSpace(column.FieldKey))
      // Sifra artikla je kljuc vrstice in stoji v skupini »Kljuc«; dvakrat bi bila dvoumna.
      .Where(column => column.FieldKey != ProductWorkbookContract.ItemIdField)
      .Where(column => !HiddenElementNames.Contains(column.ElementName))
      .OrderBy(column => column.SortOrder)
      .Select(column => new SaopWritableField(column.FieldKey!, column.ElementName,
        SaopFieldLabels.For(column.ElementName), column.ValueFormat))
      .ToList();
  }

  async Task<IReadOnlyList<string>> LanguagesAsync(int? organizationId, CancellationToken cancellationToken)
  {
    var registered = (await catalog.GetLanguagesAsync(organizationId, cancellationToken))
      .Where(language => language.IsActive).Select(language => language.LanguageCode);
    var ordered = PimLanguages.Order(registered.Append("sl"));
    return ordered.Count > 0 ? ordered : PimLanguages.Preferred;
  }

  sealed record WorkbookAttributeRow(
    string Code, string Name, bool IsRequired, bool InSet, string? SetLevel, int SortOrder);

  /// <summary>
  /// Vrstni red stolpcev atributov: najprej zahtevani, potem po imenu. Izvoz in uvoz ga morata
  /// uporabiti enako — od njega je odvisno, kateri od dveh stolpcev z istim imenom dobi za
  /// naslov se svojo kodo (<see cref="ProductWorkbookContract"/>).
  /// </summary>
  static List<WorkbookAttribute> OrderAttributes(IReadOnlyList<WorkbookAttributeRow> attributes) =>
    attributes
      .OrderByDescending(attribute => attribute.InSet)
      .ThenByDescending(attribute => attribute.IsRequired || attribute.SetLevel == "REQUIRED")
      .ThenBy(attribute => attribute.SortOrder)
      .ThenBy(attribute => attribute.Name, StringComparer.CurrentCulture)
      .ThenBy(attribute => attribute.Code, StringComparer.Ordinal)
      .Select(attribute => new WorkbookAttribute(attribute.Code, attribute.Name, attribute.InSet, attribute.SetLevel))
      .ToList();

  sealed record WorkbookData(
    Dictionary<(long ProductId, string FieldCode), string?> Values,
    Dictionary<(long ProductId, string WebSite), string> Categories,
    Dictionary<(long ProductId, string AttributeCode), string?> AttributeValues,
    Dictionary<long, string> Media,
    Dictionary<long, string> Documents,
    IReadOnlyList<WorkbookAttributeRow> Attributes,
    Dictionary<string, string> Required)
  {
    /// <summary>
    /// Spletne strani izdelka. Kazalo je zgrajeno enkrat in ne ob vsaki vrstici: iskanje po
    /// kljucih slovarja bi bilo pri 20.000 izdelkih in desettisocih kategorijah kvadraticno in
    /// bi samo za en stolpec porabilo vec casa kot ves ostali izvoz.
    /// </summary>
    public IReadOnlyList<string> SitesOf(long productId) =>
      Index.TryGetValue(productId, out var sites) ? sites : [];

    Dictionary<long, List<string>>? index;
    Dictionary<long, List<string>> Index
    {
      get
      {
        if (index is not null) return index;
        index = [];
        foreach (var key in Categories.Keys)
        {
          if (!index.TryGetValue(key.ProductId, out var sites)) index[key.ProductId] = sites = [];
          sites.Add(key.WebSite);
        }
        return index;
      }
    }
  }

  /// <summary>
  /// <see cref="ReadAsync"/> po paketih po <see cref="BatchSize"/> izdelkov, zdruzeno v en rezultat
  /// (218). Uvoz cele datoteke je prej bral vse izdelke v enem klicu — pri deset tisocih izdelkov
  /// en JSON parameter in ena poizvedba, ki drzi bazo minute. Sifrant atributov in register
  /// zahtev sta v vsakem paketu ista; vzameta se iz prvega.
  /// </summary>
  async Task<WorkbookData> ReadBatchedAsync(
    IReadOnlyList<long> productIds, IReadOnlyList<string> fieldCodes, CancellationToken cancellationToken)
  {
    if (productIds.Count <= BatchSize) return await ReadAsync(productIds, fieldCodes, null, null, cancellationToken);

    WorkbookData? merged = null;
    foreach (var chunk in productIds.Chunk(BatchSize))
    {
      var part = await ReadAsync(chunk, fieldCodes, null, null, cancellationToken);
      if (merged is null) { merged = part; continue; }
      foreach (var pair in part.Values) merged.Values[pair.Key] = pair.Value;
      foreach (var pair in part.Categories) merged.Categories[pair.Key] = pair.Value;
      foreach (var pair in part.AttributeValues) merged.AttributeValues[pair.Key] = pair.Value;
      foreach (var pair in part.Media) merged.Media[pair.Key] = pair.Value;
      foreach (var pair in part.Documents) merged.Documents[pair.Key] = pair.Value;
    }
    return merged!;
  }

  async Task<WorkbookData> ReadAsync(
    IReadOnlyList<long> productIds, IReadOnlyList<string> fieldCodes,
    string? categoryTreeCode, string? categoryCode, CancellationToken cancellationToken)
  {
    var values = new Dictionary<(long, string), string?>();
    var categoryPaths = new Dictionary<(long, string), string>();
    var attributeValues = new Dictionary<(long, string), string?>();
    var media = new Dictionary<long, string>();
    var documents = new Dictionary<long, string>();
    var attributes = new List<WorkbookAttributeRow>();
    var required = new Dictionary<string, string>(StringComparer.Ordinal);

    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.GetProductWorkbook", connection)
    {
      CommandType = CommandType.StoredProcedure,
      CommandTimeout = 300,
    };
    command.Parameters.Add("@ProductIdsJson", SqlDbType.NVarChar, -1).Value = JsonSerializer.Serialize(productIds);
    command.Parameters.Add("@FieldCodesJson", SqlDbType.NVarChar, -1).Value = JsonSerializer.Serialize(fieldCodes);
    command.Parameters.Add("@CategoryTreeCode", SqlDbType.NVarChar, 100).Value =
      string.IsNullOrWhiteSpace(categoryTreeCode) ? DBNull.Value : categoryTreeCode;
    command.Parameters.Add("@CategoryCode", SqlDbType.NVarChar, 200).Value =
      string.IsNullOrWhiteSpace(categoryCode) ? DBNull.Value : categoryCode;

    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    while (await reader.ReadAsync(cancellationToken))
      values[(PimDb.Int64(reader, "ProductId"), PimDb.TextOrEmpty(reader, "FieldCode"))] = PimDb.Text(reader, "Value");

    if (await reader.NextResultAsync(cancellationToken))
      while (await reader.ReadAsync(cancellationToken))
        categoryPaths[(PimDb.Int64(reader, "ProductId"), PimDb.TextOrEmpty(reader, "WebSite"))] =
          PimDb.TextOrEmpty(reader, "CategoryPaths");

    if (await reader.NextResultAsync(cancellationToken))
      while (await reader.ReadAsync(cancellationToken))
        attributeValues[(PimDb.Int64(reader, "ProductId"), PimDb.TextOrEmpty(reader, "AttributeCode"))] =
          PimDb.Text(reader, "Value");

    // Slike in dokumenti pridejo surovi (URL, vloga) in se tu razvrstijo z isto MediaKindPolicy,
    // ki jo uporablja stran Mediji — sicer bi izvoz in stran lahko za isti izdelek pokazala
    // razlicno stvar. canon.ProductMedia sam po sebi ne loci slike od dokumenta (samo URL/vloga),
    // zato je bila prej cela vsebina te tabele v enem stolpcu »Slike«, ceprav ni bila vsa slika.
    if (await reader.NextResultAsync(cancellationToken))
    {
      var imagesByProduct = new Dictionary<long, List<string>>();
      var documentsByProduct = new Dictionary<long, List<string>>();
      while (await reader.ReadAsync(cancellationToken))
      {
        var productId = PimDb.Int64(reader, "ProductId");
        var url = PimDb.TextOrEmpty(reader, "Url");
        var role = PimDb.Text(reader, "Role");
        var bucket = MediaKindPolicy.Classify(url, role) == MediaKindPolicy.ImageCode ? imagesByProduct : documentsByProduct;
        if (!bucket.TryGetValue(productId, out var urls)) bucket[productId] = urls = [];
        urls.Add(url);
      }
      foreach (var pair in imagesByProduct)
        if (ProductWorkbookContract.JoinList(pair.Value) is { } joined) media[pair.Key] = joined;
      foreach (var pair in documentsByProduct)
        if (ProductWorkbookContract.JoinList(pair.Value) is { } joined) documents[pair.Key] = joined;
    }

    if (await reader.NextResultAsync(cancellationToken))
      while (await reader.ReadAsync(cancellationToken))
        attributes.Add(new(PimDb.TextOrEmpty(reader, "AttributeCode"), PimDb.TextOrEmpty(reader, "Name"),
          PimDb.Bool(reader, "IsRequired"), PimDb.Bool(reader, "InSet"), PimDb.Text(reader, "SetLevel"),
          PimDb.Int32(reader, "SortOrder")));

    if (await reader.NextResultAsync(cancellationToken))
      while (await reader.ReadAsync(cancellationToken))
      {
        var blocksErp = PimDb.Bool(reader, "BlocksErp");
        var blocksWeb = PimDb.Bool(reader, "BlocksWeb");
        required[PimDb.TextOrEmpty(reader, "FieldCode")] = (blocksErp, blocksWeb) switch
        {
          (true, true) => "ERP in splet",
          (true, false) => "ERP",
          (false, true) => "splet",
          _ => "validacija",
        };
      }

    return new(values, categoryPaths, attributeValues, media, documents, attributes, required);
  }

  sealed record ProductKey(long ProductId, bool WebPublish);

  async Task<IReadOnlyDictionary<string, ProductKey>> ResolveProductIdsAsync(
    int organizationId, IReadOnlyList<string> itemIds, CancellationToken cancellationToken)
  {
    var found = new Dictionary<string, ProductKey>(StringComparer.OrdinalIgnoreCase);
    if (itemIds.Count == 0) return found;

    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("""
      SELECT product.ItemID, product.ProductId, product.WebPublish
      FROM canon.Product AS product
      INNER JOIN OPENJSON(@ItemIdsJson) AS wanted ON wanted.value = product.ItemID
      WHERE product.OrganizationId = @OrganizationId;
      """, connection) { CommandTimeout = 120 };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@ItemIdsJson", SqlDbType.NVarChar, -1).Value = JsonSerializer.Serialize(itemIds);

    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    while (await reader.ReadAsync(cancellationToken))
      found[PimDb.TextOrEmpty(reader, "ItemID")] =
        new(PimDb.Int64(reader, "ProductId"), PimDb.Bool(reader, "WebPublish"));
    return found;
  }

  /// <summary>
  /// Ali je vrednost iz datoteke ista kot zapisana. Primerjava ni gola primerjava nizov:
  /// Excel zapise stevilo kot 1.5, baza pa 1.5000 — brez tega bi vsak uvoz nespremenjene
  /// datoteke prijavil spremembo pri vsakem stevilcnem polju in napolnil odhodno vrsto z
  /// niclami sprememb.
  /// </summary>
  static bool SameValue(string incoming, string? current)
  {
    // Prelom vrstice se zapise enotno kot LF; zvezek ne loci CRLF od LF, baza pa ju nosi oba.
    var left = Normalize(incoming);
    var right = Normalize(current);
    if (string.Equals(left, right, StringComparison.Ordinal)) return true;
    if (decimal.TryParse(left, NumberStyles.Any, CultureInfo.InvariantCulture, out var leftNumber)
      && decimal.TryParse(right, NumberStyles.Any, CultureInfo.InvariantCulture, out var rightNumber))
      return leftNumber == rightNumber;
    return false;

    static string Normalize(string? value) =>
      (value ?? string.Empty).Replace("\r\n", "\n").Replace("\r", "\n").Trim();
  }

  /// <summary>Seznama sta ista, kadar vsebujeta iste vrednosti; vrstni red v celici ni pomen.</summary>
  static bool SameList(IReadOnlyList<string> left, IReadOnlyList<string> right) =>
    left.Count == right.Count
    && left.OrderBy(value => value, StringComparer.Ordinal)
        .SequenceEqual(right.OrderBy(value => value, StringComparer.Ordinal), StringComparer.Ordinal);
}
