using System.Data;
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using PIM.Operations;

namespace PIM.Intranet.Services;

/// <param name="PimValues">Spletni podatki, atributi, slike: zapišejo se takoj; ključ je kanonična koda polja.</param>
/// <param name="SaopValues">ERP polja: zapišejo se v PIM takoj in gredo v odhodno vrsto za SAOP (245).</param>
/// <param name="OldValues">280: vrednost vsakega spremenjenega polja tik pred uvozom (null = prazno) — za zgodovino in povratek.</param>
public sealed record ProductWorkbookRowChange(
  int RowNumber, int OrganizationId, string OrganizationName, string ItemId,
  IReadOnlyDictionary<string, string> PimValues,
  IReadOnlyDictionary<string, string> SaopValues,
  IReadOnlyDictionary<string, string?>? OldValues = null);

/// <param name="UnknownColumns">Naslovi, ki jim ne ustreza noben stolpec pogodbe.</param>
/// <param name="ReadOnlyColumns">Naslovi, ki jih uvoz namenoma ne bere.</param>
/// <param name="NewAttributes">Atributi, ki jih šifrant še ne pozna, stolpec pa je pod skupino
/// atributov; uvoz jih ustvari, preden zapiše vrednosti.</param>
/// <param name="FieldLabels">280: naslov stolpca za kodo polja (zgodovina uvozov).</param>
/// <param name="BoolFields">280: polja D/N; <paramref name="NumberFields"/>: številska polja.</param>
/// <param name="AttributeSuggestions">Naslov novega ali neprepoznanega stolpca → najbližji obstoječi
/// atribut (tipkarska napaka, drug zapis). Uporabnik predlog sprejme v pojavnem oknu.</param>
/// <param name="MissingCategories">Poti kategorij iz datoteke, ki jih drevo strani ne pozna; uporabnik
/// jih v pojavnem oknu potrdi in se ustvarijo (David 2026-09-24), sicer ostane stran pri starih.</param>
public sealed record ProductWorkbookPreview(
  IReadOnlyList<ProductWorkbookRowChange> Rows,
  IReadOnlyList<string> UnknownColumns,
  IReadOnlyList<string> ReadOnlyColumns,
  IReadOnlyList<string> Problems,
  IReadOnlyList<string>? NewAttributes = null,
  IReadOnlyDictionary<string, string>? FieldLabels = null,
  IReadOnlySet<string>? BoolFields = null,
  IReadOnlySet<string>? NumberFields = null,
  IReadOnlyList<ProductWorkbookMissingCategory>? MissingCategories = null,
  IReadOnlyDictionary<string, string>? AttributeSuggestions = null)
{
  public int PimChangeCount => Rows.Sum(row => row.PimValues.Count);
  public int SaopChangeCount => Rows.Sum(row => row.SaopValues.Count);
}

/// <param name="Path">Pot v jeziku strani, ločena z » > «.</param>
/// <param name="Items">Artikli datoteke, ki to pot nosijo.</param>
/// <param name="Suggestion">Najbližja obstoječa pot (isti zadnji del ali najdaljši skupni začetek).</param>
public sealed record ProductWorkbookMissingCategory(
  string SiteCode, string SiteName, string CategoryTreeCode, string LanguageCode,
  string Path, IReadOnlyList<string> Items, string? Suggestion)
{
  /// <summary>Ustvari se samo v slovenskem drevesu: ime kategorije je slovensko, prevod pride posebej.
  /// Jezikovna različica brez svoje celice prevzame kategorijo slovenske strani.</summary>
  public bool CanCreate => string.Equals(LanguageCode, "sl", StringComparison.OrdinalIgnoreCase);
}

/// <param name="OutboundBatchIds">Skupine, ki čakajo odobritev na /izvozi/mnozicno.</param>
/// <param name="ErpWritten">ERP vrednosti, zapisane v katalog PIM takoj (245).</param>
/// <param name="MediaAdded">Dodane slike in dokumenti.</param>
/// <param name="MediaRemoved">Odstranjene slike in dokumenti (naslov, ki ga v celici ni več).</param>
/// <param name="CreatedAttributes">Atributi, ki jih je uvoz ustvaril v šifrantu.</param>
public sealed record ProductWorkbookOutcome(
  int RowsTouched, int PimChanges, int SaopQueued, int SaopDuplicates, int SaopRejected,
  IReadOnlyList<long> OutboundBatchIds, IReadOnlyList<string> Problems,
  int ErpWritten = 0, int MediaAdded = 0, int MediaRemoved = 0,
  IReadOnlyList<string>? CreatedAttributes = null);

/// <summary>Kje je gradnja zvezka: branje seznama pogleda (stran za stranjo) ali pisanje vrstic.</summary>
public enum ProductWorkbookPhase { Listing, Writing }

/// <param name="Done">Prebranih (Listing) oziroma zapisanih (Writing) vrstic do zdaj.</param>
/// <param name="Total">Vseh vrstic pogleda; pri Writing tudi po zožitvi na izbrane vrstice.</param>
public readonly record struct ProductWorkbookProgress(ProductWorkbookPhase Phase, int Done, int Total);

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
///   - ERP polja: register <c>out.SaopXmlField</c> pove, katero polje sme PIM pisati. Od 245
///     gre taka vrednost v katalog PIM TAKOJ (pim.SaveProductErpFieldsBulk) in hkrati v
///     odhodno vrsto, kjer za pot v SAOP čaka odobritev. Uporabnik 2026-09-22: »ERP brez
///     čakanja SAOPa in omejitev«.
///   - Spletni podatek je last PIM in se zapiše takoj, skozi iste procedure kot kartica
///     izdelka, torej z zgodovino in takojšnjo ponovno validacijo. Enako slike in dokumenti
///     (pim.SaveProductMediaBulk) in atributi — tudi taki, ki jih šifrant še ne pozna.
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
  IntranetDataService data,
  AttributeMappingService attributeDefinitions,
  PackagingDiscountService? packagingService = null)
{
  /// <summary>S-popusti (274); v testih brez DI se ustvari iz iste konfiguracije.</summary>
  readonly PackagingDiscountService packaging = packagingService ?? new PackagingDiscountService(configuration);

  /// <summary>Kljukica »izloči iz rezervacije zaloge« (register SAOP, element ItemExcludeQtyReservation).</summary>
  const string ReservationExclusionField = "Planning.ExcludeQtyReservation";

  /// <summary>Oznaka v prebranih vrednostih: izdelek je objavljen (pim.Product) in S se mu lahko dodeli (274).</summary>
  const string PackagingPromotedMarker = "Discount.Promoted";

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
  /// <param name="includeFieldKeys">Katera posamezna polja (<see cref="ProductWorkbookColumn.FieldKey"/>)
  /// gredo v datoteko; null pomeni vsa. Skupina »Ključ« gre v datoteko vedno, brez nje vrstice ne
  /// bi bilo mogoce prebrati nazaj. Uporabnik izbere polja v pojavnem oknu »Stolpci« na /izdelki
  /// (glej <see cref="DescribeColumnsAsync"/>), da je datoteka manjša in uvoz nazaj hitrejši — uvoz
  /// s tem ne potrebuje nobene spremembe, ker ProductWorkbookContract.Match itak bere samo stolpce,
  /// ki so v datoteki.</param>
  public async Task<byte[]> BuildAsync(
    ProductListFilter filter, IReadOnlyCollection<string>? onlySelectionKeys = null,
    IReadOnlySet<string>? includeFieldKeys = null,
    CancellationToken cancellationToken = default)
  {
    using var stream = new MemoryStream();
    await BuildToAsync(stream, filter, onlySelectionKeys, includeFieldKeys, progress: null, cancellationToken);
    return stream.ToArray();
  }

  /// <summary>
  /// Isto kot <see cref="BuildAsync"/>, a zvezek pise naravnost v dani tok (datoteko na disku,
  /// glej ExportJobService/ExportResultStore) in sproti javlja napredek: najprej branje seznama
  /// (stran za stranjo), potem zapisane vrstice od vseh — iz tega okno izvoza v kotu strani
  /// izrise vrstico napredka in oceno, koliko je se do konca. Vrne stevilo vrstic v datoteki.
  /// </summary>
  public async Task<int> BuildToAsync(
    Stream destination, ProductListFilter filter, IReadOnlyCollection<string>? onlySelectionKeys,
    IReadOnlySet<string>? includeFieldKeys, IProgress<ProductWorkbookProgress>? progress, CancellationToken cancellationToken)
  {
    // Izbrani izdelki se preberejo neposredno, ne s sitom cez cel pogled (glej GetSelectedRowsAsync).
    var rows = onlySelectionKeys is { Count: > 0 }
      ? await workbench.GetSelectedRowsAsync(filter, onlySelectionKeys, cancellationToken)
      : await ListRowsAsync(filter, progress, cancellationToken);
    progress?.Report(new(ProductWorkbookPhase.Writing, 0, rows.Count));

    var sites = await ActiveWebSitesAsync(cancellationToken);
    var saopFields = await WritableSaopFieldsAsync(cancellationToken);
    var flags = await FlagDefinitionsAsync(cancellationToken);
    var languages = await LanguagesAsync(filter.WithPartnerScope().OrganizationId, cancellationToken);
    bool Included(ProductWorkbookColumn column) =>
      column.Group == ProductWorkbookContract.GroupKey
      || includeFieldKeys is null || includeFieldKeys.Contains(column.FieldKey);

    // Prvi obhod da stolpce brez atributov; iz njih izhajajo kode polj, ki jih je treba
    // prebrati. Sifrant atributov dopolni stolpce v drugem obhodu.
    var probe = ProductWorkbookContract.Build(new(saopFields, sites, WebTextTypes, languages, [], flags)).Where(Included).ToList();
    var fieldCodes = probe
      .Where(column => column.Target != ProductWorkbookTarget.ReadOnly)
      .Select(column => column.FieldKey)
      .Where(key => !IsListField(key) && key != ProductWorkbookContract.WebPublishField)
      .Distinct(StringComparer.Ordinal).ToList();

    // Nabor stolpcev se doloci enkrat, pred vrsticami: datoteka ima en nabor, ne enega na paket.
    // Register pride brez seznama izdelkov. Kadar je kategorija izbrana, je nabor njen in od
    // izdelkov neodvisen (isto kot doslej) — samo InSet, atributi drugih kategorij niso hrup.
    // Brez kategorije je to celoten sifrant: isti, s katerim uvoz prepozna stolpce datoteke z
    // neznanim naborom izdelkov (PreviewAsync). Prej ga je dolocal seznam vseh izdelkov pogleda
    // v enem klicu, kar pri katalogu brez zgornje meje ne gre vec.
    var wantsAttributes = includeFieldKeys is null
      || includeFieldKeys.Any(key => key.StartsWith(ProductWorkbookContract.AttributeFieldPrefix, StringComparison.Ordinal));
    var registry = await ReadAsync([], [], filter.CategoryTreeCode, filter.CategoryCode, cancellationToken);
    var attributes = !wantsAttributes ? []
      : filter.CategoryCode is null
      ? OrderAttributes(registry.Attributes)
      : OrderAttributes(registry.Attributes).Where(attribute => attribute.InSet).ToList();

    var definition = ProductWorkbookContract.Build(new(saopFields, sites, WebTextTypes, languages, attributes, flags))
      .Where(Included).ToList();
    var columns = definition.Select(column => new WorkbookColumn(
      column.Header, column.Kind, column.Width, column.Group,
      registry.Required.ContainsKey(column.FieldKey) ? WorkbookCellTone.Required : WorkbookCellTone.None)).ToArray();

    // »Spletne strani« je kljukica spletišča (pim.ProductWebShop, po drevesu kategorij), zapisana
    // z imenom primarne strani drevesa (Svetila.si, Videlektro). Uvoz ime prevede nazaj, glej ShopLookup.
    var shopNames = PrimarySiteByTree(sites).ToDictionary(
      pair => pair.Key, pair => pair.Value.Name, StringComparer.OrdinalIgnoreCase);

    await WorkbookWriter.WriteAsync(destination, "Izdelki", columns,
      CellsAsync(rows, fieldCodes, definition, shopNames, progress, cancellationToken), cancellationToken: cancellationToken);
    return rows.Count;
  }

  /// <summary>Vse vrstice pogleda, stran za stranjo; baza sama pove, koliko jih je (TotalCount).</summary>
  async Task<List<ProductListRow>> ListRowsAsync(
    ProductListFilter filter, IProgress<ProductWorkbookProgress>? progress, CancellationToken cancellationToken)
  {
    var rows = new List<ProductListRow>();
    var skip = 0;
    while (rows.Count < MaxRows)
    {
      var page = await workbench.GetProductListAsync(filter with { Skip = skip, Take = ListPageSize }, cancellationToken);
      rows.AddRange(page.Rows);
      progress?.Report(new(ProductWorkbookPhase.Listing, rows.Count, (int)Math.Min(page.TotalCount, MaxRows)));
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
    IReadOnlyDictionary<string, string> shopNames, IProgress<ProductWorkbookProgress>? progress,
    [EnumeratorCancellation] CancellationToken cancellationToken)
  {
    for (var offset = 0; offset < rows.Count; offset += BatchSize)
    {
      var batch = rows.GetRange(offset, Math.Min(BatchSize, rows.Count - offset));
      var sheet = await ReadAsync(batch.Select(row => row.ProductId).ToList(), fieldCodes, null, null, cancellationToken);
      foreach (var row in batch)
        yield return definition.Select(column => Cell(column, row, sheet, shopNames)).ToArray();
      progress?.Report(new(ProductWorkbookPhase.Writing, offset + batch.Count, rows.Count));
    }
  }

  object? Cell(
    ProductWorkbookColumn column, ProductListRow row, WorkbookData sheet,
    IReadOnlyDictionary<string, string> shopNames)
  {
    var value = Value(column, row, sheet, shopNames);
    // Rdece se obarva samo prazno polje, ki je pogoj za validacijo. Ce bi se obarvala vsaka
    // prazna celica, bi bil list rdec povsod in oznaka ne bi pomenila nicesar.
    if (value is null or "" && sheet.Required.ContainsKey(column.FieldKey))
      return new WorkbookCell(null, WorkbookCellTone.Missing);
    return value;
  }

  object? Value(
    ProductWorkbookColumn column, ProductListRow row, WorkbookData sheet,
    IReadOnlyDictionary<string, string> shopNames)
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
      case ProductWorkbookContract.WebPublishField: return ProductWorkbookContract.SheetYesNo(row.WebPublish);
      case ProductWorkbookContract.WebSitesField:
        return ProductWorkbookContract.JoinList(sheet.ShopsOf(row.ProductId)
          .Where(shopNames.ContainsKey)
          .Select(tree => shopNames[tree]));
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

    var stored = sheet.Values.TryGetValue((row.ProductId, column.FieldKey), out var found) ? found : null;
    // Logično polje v Excelu je D/N, kot v dokumentih SAOP (uporabnik 2026-09-22); uvoz sprejme
    // tudi 1/0 in da/ne. Kljukica brez vrstice planiranja je N, ne prazna celica.
    return column.IsBool ? ProductWorkbookContract.SheetYesNo(ProductWorkbookContract.ParseYesNo(stored) ?? false) : stored;
  }

  /// <summary>Polja, ki niso ena vrednost v canon.FieldValue, ampak seznam, ki ga uvoz primerja posebej.</summary>
  static bool IsListField(string fieldKey) =>
    fieldKey.StartsWith(ProductWorkbookContract.CategoryFieldPrefix, StringComparison.Ordinal)
    || fieldKey is ProductWorkbookContract.WebSitesField or ProductWorkbookContract.ImagesField or ProductWorkbookContract.DocumentsField;

  /// <summary>Ime datoteke z datumom, da se izvozi ne prepisujejo v mapi prenosov.</summary>
  public static string FileName(DateTime nowUtc) =>
    "delovni-list-izdelki-" + nowUtc.ToPimLocal().ToString("yyyyMMdd-HHmm", CultureInfo.InvariantCulture) + ".xlsx";

  static string StatusText(string status) => status switch
  {
    "VALID" => "pripravljen",
    "INVALID" => "blokiran",
    "PENDING" => "čaka validacijo",
    "NOT_CONFIGURED" => "ni profila",
    "NOT_ON_WEB" => "ni na spletu",
    _ => status,
  };

  /* ─── Uvoz: predogled ──────────────────────────────────────────────────────────────── */

  /// <param name="defaultOrganizationId">Podjetje za vrstice brez stolpca »Podjetje«.</param>
  /// <param name="columnAttributes">Odločitve iz pojavnega okna: naslov stolpca → ime atributa, v katerega
  /// gredo vrednosti. Ime, ki ga šifrant ne pozna, je nov atribut (ustvari se ob zapisu).</param>
  public async Task<ProductWorkbookPreview> PreviewAsync(
    Stream file, int? defaultOrganizationId, CancellationToken cancellationToken = default,
    IReadOnlyDictionary<string, string>? columnAttributes = null)
  {
    var organizations = await data.GetOrganizationsAsync(cancellationToken);
    var sites = await ActiveWebSitesAsync(cancellationToken);
    var saopFields = await WritableSaopFieldsAsync(cancellationToken);
    var flags = await FlagDefinitionsAsync(cancellationToken);
    var languages = await LanguagesAsync(defaultOrganizationId, cancellationToken);

    // Stolpci atributov niso znani vnaprej: uvazamo lahko datoteko, ki jo je izvozil nekdo z
    // drugim naborom. Sifrant se zato prebere brez omejitve na izdelke — prazen seznam pomeni
    // ves sifrant (migracija 172). Vrstni red je isti kot pri izvozu, sicer bi se stolpca z
    // enakim imenom v obe smeri razresila drugace in vrednost bi pristala na napacnem polju.
    var attributes = OrderAttributes((await ReadAsync([], [], null, null, cancellationToken)).Attributes);

    // 274: vsi listi z istimi stolpci kot prvi (cenik S-popustov je razdeljen po listih).
    var sheet = WorkbookTable.ReadMatchingSheets(file, ProductWorkbookContract.HeaderHints, out var skippedSheets);
    var definition = ProductWorkbookContract.Build(new(saopFields, sites, WebTextTypes, languages, attributes, flags));
    var problems = new List<string>();
    if (skippedSheets.Count > 0)
      problems.Add($"Lista {string.Join(", ", skippedSheets)} imata druge stolpce kot prvi list in nista prebrana.");
    var packagingCodes = (await packaging.GetCatalogAsync(cancellationToken: cancellationToken))
      .Select(code => code.Code).ToHashSet(StringComparer.OrdinalIgnoreCase);
    var customerTypes = await data.GetCustomerTypesAsync(cancellationToken);
    // VPAK iz cenika: PAK2 je podatek SAOP, zato se ne zapiše — uvoz ga samo primerja s PAK2 v PIM.
    var vpakIndex = sheet.Headers.ToList().FindIndex(header => WorkbookHeader.Same(header, "VPAK"));
    var vpakByItem = new Dictionary<(int, string), string>();
    var (matches, newAttributes, attributeSuggestions) = await MatchAttributesAsync(
      ProductWorkbookContract.Match(sheet.Headers, definition), sheet, columnAttributes, cancellationToken);

    var keyColumn = matches.FirstOrDefault(match => match.Column?.FieldKey == ProductWorkbookContract.ItemIdField);
    if (keyColumn is null)
      throw new WorkbookReadException("Zvezek nima stolpca s šifro artikla. Poimenuj ga »Šifra artikla« ali »ItemID«.");
    var organizationColumn = matches.FirstOrDefault(match => match.Column?.FieldKey == ProductWorkbookContract.OrganizationField);

    if (organizationColumn is null && defaultOrganizationId is null)
      problems.Add("Zvezek nima stolpca »Podjetje«, podjetje pa ni izbrano. Šifra artikla je enolična samo znotraj podjetja.");

    var rows = new List<ProductWorkbookRowChange>();
    // Prva vrstica artikla: pri dvojniku (isti artikel na dveh listih cenika) uvoz pove, ali se vrednosti
    // razlikujejo — sicer »upoštevana bo prva« skrije, da je drugi list imel drugo S kodo.
    var firstRow = new Dictionary<(int, string), (int RowNumber, IReadOnlyList<string> Cells)>();

    for (var index = 0; index < sheet.Rows.Count; index++)
    {
      var cells = sheet.Rows[index];
      // Številka, ki jo uporabnik vidi v Excelu. Prej index + 2, kar je pri listu s skupinami
      // (dve naslovni vrstici) kazalo eno vrstico prenizko.
      var rowNumber = sheet.RowNumber(index);
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

      if (firstRow.TryGetValue((organizationId.Value, itemId), out var first))
      {
        var differing = matches
          .Where(match => match.Column is not null && match.Column.Target != ProductWorkbookTarget.ReadOnly)
          .Select(match => (match.Header, Earlier: Cell(first.Cells, match.Index), Now: Cell(cells, match.Index)))
          .Where(pair => pair.Now.Length > 0 && !string.Equals(pair.Earlier, pair.Now, StringComparison.OrdinalIgnoreCase))
          .Select(pair => $"{pair.Header}: »{pair.Earlier}« -> »{pair.Now}«")
          .ToList();
        problems.Add(differing.Count == 0
          ? $"Vrstica {rowNumber}: artikel {itemId} je v zvezku večkrat; upoštevana bo prva (vrstica {first.RowNumber})."
          : $"Vrstica {rowNumber}: artikel {itemId} je v zvezku večkrat Z DRUGAČNIMI VREDNOSTMI ({string.Join("; ", differing)}); "
            + $"upoštevana bo prva (vrstica {first.RowNumber}). Preveri, katera je prava.");
        continue;
      }
      firstRow[(organizationId.Value, itemId)] = (rowNumber, cells);

      var pim = new Dictionary<string, string>(StringComparer.Ordinal);
      var saopValues = new Dictionary<string, string>(StringComparer.Ordinal);
      // Kateri stolpec je v tej vrstici že dal vrednost polju. Dva stolpca za isto polje (naslov
      // in ime elementa, ali stara datoteka) ne smeta tiho povoziti drug drugega: drugi je prej
      // zmagal in uvoz je spremembo v prvem zamolčal kot »v PIM že tako zapisano«.
      var sourceOf = new Dictionary<string, string>(StringComparer.Ordinal);
      var conflicting = new HashSet<string>(StringComparer.Ordinal);
      foreach (var match in matches)
      {
        if (match.Column is null || match.Column.Target == ProductWorkbookTarget.ReadOnly) continue;
        var value = cells[match.Index].Trim();
        // Prazna celica pomeni »ne dotikaj se«. Brez tega bi en uvoz izpraznil cel katalog.
        if (value.Length == 0) continue;
        // »-« izprazni polje (besedilo, atribut, kategorije strani, kljukice, slike, dokumente, S).
        // ERP polja ne: prazna vrednost v SAOP ni isto kot »ni podatka« in bi jo SAOP zavrnil ali
        // prepisal obvezno polje — tako polje se izprazni v SAOP ali na kartici artikla.
        if (value == ProductWorkbookContract.ClearToken && match.Column.Target == ProductWorkbookTarget.Saop)
        {
          problems.Add($"Vrstica {rowNumber}: »{match.Header}« = »-« — ERP polja se z uvozom ne praznijo (izprazni ga na kartici artikla ali v SAOP); polje se preskoči.");
          continue;
        }
        // »-« gre naprej brez pretvorbe (število, D/N); zapis ga razume kot »izprazni«.
        var clears = value == ProductWorkbookContract.ClearToken && !ProductWorkbookContract.IsPackagingField(match.Column.FieldKey);
        if (clears) { }
        else if (match.Column.IsBool)
        {
          // V listu je D/N (sprejeto tudi da/ne, 1/0); naprej gre kot 1/0 — tako ga hrani katalog,
          // graditelj dokumenta pa ga po registru pretvori v obliko SAOP (D/N, d/N, true/false).
          // Nerazumljivo (»mogoče«) se pove in preskoči, ne ugiba.
          if (ProductWorkbookContract.BoolValue(value) is not { } flag)
          {
            problems.Add($"Vrstica {rowNumber}: »{match.Header}« = »{value}« ni D ali N; polje se preskoči.");
            continue;
          }
          value = flag;
        }
        else if (ProductWorkbookContract.IsPackagingField(match.Column.FieldKey))
        {
          // 274: S koda in posebni S se preverijo in zapišejo v enotni obliki, da se primerjava
          // s shranjenim ne zmoti ob velikih črkah, presledkih ali vrstnem redu.
          if (NormalizePackagingCell(match.Column.FieldKey, value, packagingCodes, customerTypes, out var error) is not { } normalized)
          {
            problems.Add($"Vrstica {rowNumber}: »{match.Header}« = »{value}« — {error}; polje se preskoči.");
            continue;
          }
          value = normalized;
        }
        else if (match.Column.IsNumber)
        {
          // Število gre naprej v zapisu s piko — tako ga razume SAOP in hrani katalog. Besedilo
          // namesto števila bi v vrsti čakalo, dokler ga graditelj dokumenta ne zavrne.
          if (Number(value) is not { } number)
          {
            problems.Add($"Vrstica {rowNumber}: »{match.Header}« = »{value}« ni število; polje se preskoči."
              + (match.Column.Target == ProductWorkbookTarget.Saop
                ? $" »{match.Header}« je tu polje SAOP (samo število, v enoti dimenzij artikla); če je mišljen atribut, "
                  + "postavi stolpec pod skupino »Atributi …« (vrstica nad naslovi) — tam se »5m« razdeli na število in enoto."
                : ""));
            continue;
          }
          value = number;
        }
        var target = match.Column.Target == ProductWorkbookTarget.Pim ? pim : saopValues;
        var fieldKey = match.Column.FieldKey;
        if (conflicting.Contains(fieldKey)) continue;
        if (sourceOf.TryGetValue(fieldKey, out var earlier)
          && (pim.TryGetValue(fieldKey, out var previous) || saopValues.TryGetValue(fieldKey, out previous)))
        {
          if (SameValue(value, previous, match.Column.IsNumber)) continue;
          problems.Add($"Vrstica {rowNumber}: stolpca »{earlier}« (»{previous}«) in »{match.Header}« (»{value}«) "
            + "pišeta isto polje z različno vrednostjo; polje se preskoči. Popravi enega od njiju.");
          pim.Remove(fieldKey);
          saopValues.Remove(fieldKey);
          conflicting.Add(fieldKey);
          continue;
        }
        sourceOf[fieldKey] = match.Header;
        target[fieldKey] = value;
      }

      if (vpakIndex >= 0 && cells[vpakIndex].Trim() is { Length: > 0 } vpak)
        vpakByItem.TryAdd((organizationId.Value, itemId), vpak);

      if (pim.Count == 0 && saopValues.Count == 0) continue;
      rows.Add(new(rowNumber, organizationId.Value, organizationName, itemId, pim, saopValues));
    }

    await ComparePackagingQuantitiesAsync(rows, vpakByItem, problems, cancellationToken);

    // Dvoumni stolpci (»Naziv«) niso »neznani«: v okno za izbiro atributa ne sodijo, opozorilo pa
    // gre med težave na vrh — s tem tudi v izid in v ops.ImportRun.Problems (ProductImport.ApplyAsync).
    problems.InsertRange(0, AmbiguousColumnWarnings(matches, definition));
    var unknown = matches.Where(match => match.Column is null && !match.Ambiguous && !string.IsNullOrWhiteSpace(match.Header))
      .Select(match => match.Header).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
    var readOnly = matches.Where(match => match.Column?.Target == ProductWorkbookTarget.ReadOnly)
      .Select(match => match.Header).Distinct(StringComparer.OrdinalIgnoreCase).ToList();

    var boolFields = matches.Where(match => match.Column?.IsBool == true)
      .Select(match => match.Column!.FieldKey).ToHashSet(StringComparer.Ordinal);
    var numberFields = matches.Where(match => match.Column?.IsNumber == true)
      .Select(match => match.Column!.FieldKey).ToHashSet(StringComparer.Ordinal);
    rows = await NormalizeCodesAsync(rows, problems, cancellationToken);
    var (resolved, missingCategories) = await ResolveCategoryCellsAsync(rows, sites, cancellationToken);
    rows = await OnlyChangedAsync(resolved, shopByToken: ShopLookup(sites), boolFields, numberFields, problems, cancellationToken);
    // Po primerjavi: razdeli se samo, kar je uporabnik spremenil — ponoven uvoz izvožene datoteke
    // ne sme tiho predelati starih vrednosti z enoto.
    rows = await SplitAttributeUnitsAsync(rows, problems, cancellationToken);
    // Manjkajoča pot je vedno sprememba (shranjena biti ne more); pokaže se samo za vrstice, ki ostanejo.
    var remaining = rows.Select(row => row.ItemId).ToHashSet(StringComparer.OrdinalIgnoreCase);
    missingCategories = missingCategories
      .Select(missing => missing with { Items = missing.Items.Where(remaining.Contains).ToList() })
      .Where(missing => missing.Items.Count > 0).ToList();
    if (missingCategories.Count > 0)
      problems.Add($"{missingCategories.Count:N0} poti kategorij ne obstaja v drevesu strani — v oknu »Manjkajoče« jih lahko ustvariš; "
        + "sicer te strani ostanejo pri prejšnjih kategorijah.");

    if (rows.Count == 0) problems.Add("V zvezku ni nobene vrstice, ki bi kaj spremenila. Kar je v datoteki, je v PIM že tako zapisano.");
    var labels = new Dictionary<string, string>(StringComparer.Ordinal);
    foreach (var match in matches.Where(match => match.Column is not null && match.Column.Target != ProductWorkbookTarget.ReadOnly))
      labels.TryAdd(match.Column!.FieldKey, match.Header);
    return new(rows, unknown, readOnly, problems, newAttributes, labels, boolFields, numberFields,
      missingCategories, attributeSuggestions);
  }

  /// <summary>Šifre ERP, ki jih predogled preveri, preden gredo v PIM in v vrsto SAOP.</summary>
  /// <remarks>Strict: neznana vrednost se zavrne. Sicer (država, DDV) je nova vrednost pravilne
  /// oblike dovoljena z opozorilom — šifranta SAOP za njiju PIM nima, samo vrednosti artiklov.</remarks>
  sealed record CodeField(string Label, bool Strict, bool Partner = false, string? Pattern = null, int PadTo = 0);

  static readonly Dictionary<string, CodeField> CodeFields = new(StringComparer.Ordinal)
  {
    ["Product.UoM"] = new("Merska enota", Strict: true),
    ["Product.ItemGroup"] = new("Skupina artikla", Strict: true),
    ["Product.AccountingGroup"] = new("Knjižna skupina", Strict: true),
    ["Product.Department"] = new("Oddelek (ABC)", Strict: true),
    ["Product.DiscountGroup"] = new("Rabatna skupina", Strict: true),
    ["Product.PriceListCode"] = new("Cenik", Strict: true),
    ["Product.Supplier"] = new("Dobavitelj", Strict: true, Partner: true),
    ["Product.Manufacturer"] = new("Proizvajalec", Strict: true, Partner: true),
    ["ProductCommercial.DimensionUnit"] = new("Enota dimenzij", Strict: true),
    ["ProductCommercial.CountryOfOrigin"] = new("Država porekla", Strict: false, Pattern: "^[A-Z]{2}$"),
    ["Product.VatRateId"] = new("DDV (stopnja)", Strict: false, Pattern: "^[0-9]{2}$", PadTo: 2),
  };

  /// <summary>
  /// Šifre ERP v obliki, ki jo pozna SAOP, preden gredo v PIM in v vrsto (David 2026-09-24: »človek
  /// bo delal 100 napak«). Excel iz »0000428« naredi 428, uporabnik piše »KOM« namesto »kom« —
  /// taka vrednost se poravna na znano šifro. Šifra, ki je podjetje ne pozna, se ne zapiše: v PIM
  /// bi takoj pokvarila artikel, v SAOP pa bi jo zavrnil šele po odobritvi. Znane šifre so šifrant
  /// partnerjev (canon.PartnerName), ceniki (canon.Codebook) in vrednosti, ki jih artikli podjetja
  /// že uporabljajo — drugega šifranta SAOP za enote in skupine PIM nima.
  /// </summary>
  async Task<List<ProductWorkbookRowChange>> NormalizeCodesAsync(
    List<ProductWorkbookRowChange> rows, List<string> problems, CancellationToken cancellationToken)
  {
    if (!rows.Any(row => row.SaopValues.Keys.Any(CodeFields.ContainsKey))) return rows;
    var known = await ReadKnownCodesAsync(rows.Select(row => row.OrganizationId).Distinct().ToList(), cancellationToken);

    var rejected = new Dictionary<(string Field, string Value), List<string>>();
    var warned = new Dictionary<(string Field, string Value), List<string>>();
    var corrected = new Dictionary<(string Field, string From, string To), int>();
    var result = new List<ProductWorkbookRowChange>(rows.Count);
    foreach (var row in rows)
    {
      var values = new Dictionary<string, string>(row.SaopValues, StringComparer.Ordinal);
      foreach (var (fieldKey, rule) in CodeFields)
      {
        if (!values.TryGetValue(fieldKey, out var value)) continue;
        var codes = known.TryGetValue((row.OrganizationId, fieldKey), out var list) ? list : [];
        var probe = rule.PadTo > 0 && value.All(char.IsAsciiDigit) ? value.PadLeft(rule.PadTo, '0') : value;
        // Natančno ujemanje ostane, kot je: podjetje ima lahko »kos« in »KOS« — oba sta veljavna.
        if (codes.ContainsKey(ExactCode + probe)) { values[fieldKey] = probe; continue; }
        if (codes.TryGetValue(CodeKey(probe, rule.Partner), out var canonical))
        {
          if (canonical != value) corrected[(fieldKey, value, canonical)] = corrected.GetValueOrDefault((fieldKey, value, canonical)) + 1;
          values[fieldKey] = canonical;
          continue;
        }
        var shaped = rule.Pattern is null ? probe : probe.ToUpperInvariant();
        if (!rule.Strict && System.Text.RegularExpressions.Regex.IsMatch(shaped, rule.Pattern!))
        {
          values[fieldKey] = shaped;
          (warned.TryGetValue((fieldKey, shaped), out var items) ? items : warned[(fieldKey, shaped)] = []).Add(row.ItemId);
          continue;
        }
        values.Remove(fieldKey);
        (rejected.TryGetValue((fieldKey, value), out var skipped) ? skipped : rejected[(fieldKey, value)] = []).Add(row.ItemId);
      }
      if (values.Count == 0 && row.PimValues.Count == 0) continue;
      result.Add(row with { SaopValues = values });
    }

    foreach (var ((fieldKey, value), items) in rejected)
    {
      var rule = CodeFields[fieldKey];
      var examples = rows.Select(row => row.OrganizationId).Distinct()
        .SelectMany(organization => known.TryGetValue((organization, fieldKey), out var list) ? list.Values : Enumerable.Empty<string>())
        .Distinct(StringComparer.Ordinal).Order(StringComparer.OrdinalIgnoreCase).ToList();
      var hint = rule.Partner ? "šifra partnerja mora obstajati v SAOP (canon.PartnerName)"
        : examples.Count == 0 ? "podjetje te šifre ne pozna"
        : "znane vrednosti: " + string.Join(", ", examples.Take(25)) + (examples.Count > 25 ? " …" : "");
      problems.Add($"{rule.Label} »{value}« ni znana šifra ({hint}); polje se ne zapiše pri {Items(items)}.");
    }
    foreach (var ((fieldKey, value), items) in warned)
      problems.Add($"{CodeFields[fieldKey].Label} »{value}« ni še pri nobenem artiklu podjetja — preveri, ali je prava (SAOP jo lahko zavrne): {Items(items)}.");
    foreach (var ((fieldKey, from, to), count) in corrected)
      problems.Add($"{CodeFields[fieldKey].Label} »{from}« je popravljen na znano šifro »{to}« ({count:N0}×)"
        + (to.Length > from.Length && to.TrimStart('0') == from.TrimStart('0')
          ? " — Excel je odrezal vodilne ničle; celico zapiši kot besedilo." : "."));
    return result;

    static string Items(List<string> items) =>
      $"{items.Count:N0} artiklih ({string.Join(", ", items.Take(10))}{(items.Count > 10 ? " …" : "")})";
  }

  /// <summary>
  /// Celice »Kategorije — …« v zapisu drevesa: ločilo » > « ne glede na presledke (»A>B«, »A >B«),
  /// velike črke kot v drevesu. Pot, ki je drevo strani ne pozna, gre na seznam manjkajočih s
  /// predlogom najbližje obstoječe — uporabnik jo v pojavnem oknu potrdi in se ustvari.
  /// </summary>
  async Task<(List<ProductWorkbookRowChange> Rows, List<ProductWorkbookMissingCategory> Missing)> ResolveCategoryCellsAsync(
    List<ProductWorkbookRowChange> rows, IReadOnlyList<WorkbookWebSite> sites, CancellationToken cancellationToken)
  {
    var siteCodes = rows.SelectMany(row => row.PimValues.Keys)
      .Where(key => key.StartsWith(ProductWorkbookContract.CategoryFieldPrefix, StringComparison.Ordinal))
      .Select(key => key[ProductWorkbookContract.CategoryFieldPrefix.Length..])
      .Distinct(StringComparer.OrdinalIgnoreCase).ToList();
    if (siteCodes.Count == 0) return (rows, []);

    var valid = await CategoryPathsBySiteAsync(siteCodes, cancellationToken);
    var languages = await SiteLanguagesAsync(cancellationToken);
    var missing = new Dictionary<(string Site, string Path), List<string>>();
    var result = new List<ProductWorkbookRowChange>(rows.Count);
    foreach (var row in rows)
    {
      var values = new Dictionary<string, string>(row.PimValues, StringComparer.Ordinal);
      foreach (var site in siteCodes)
      {
        var fieldKey = ProductWorkbookContract.CategoryFieldKey(site);
        if (!values.TryGetValue(fieldKey, out var cell) || cell == ProductWorkbookContract.ClearToken) continue;
        var paths = valid.TryGetValue(site, out var tree) ? tree : null;
        var normalized = ProductWorkbookContract.SplitList(cell).Select(CategoryPathText).Select(path =>
        {
          // Množica je brez razlike velikih črk; TryGetValue vrne zapis iz drevesa (brez preiskovanja).
          if (paths is not null && paths.Paths.TryGetValue(path, out var known)) return known;
          if (paths is not null)
            (missing.TryGetValue((site, path), out var items) ? items : missing[(site, path)] = []).Add(row.ItemId);
          return path;
        }).ToList();
        values[fieldKey] = ProductWorkbookContract.JoinList(normalized) ?? cell;
      }
      result.Add(row with { PimValues = values });
    }

    var list = missing.Select(pair =>
    {
      var (site, path) = pair.Key;
      var web = sites.FirstOrDefault(candidate => string.Equals(candidate.Code, site, StringComparison.OrdinalIgnoreCase));
      return new ProductWorkbookMissingCategory(site, web?.Name ?? site, web?.CategoryTreeCode ?? "",
        languages.TryGetValue(site, out var language) ? language : "sl", path,
        pair.Value.Distinct(StringComparer.OrdinalIgnoreCase).ToList(),
        valid.TryGetValue(site, out var tree) ? ClosestCategory(path, tree.Paths) : null);
    }).OrderBy(item => item.SiteName).ThenBy(item => item.Path).ToList();
    return (result, list);
  }

  static readonly System.Text.RegularExpressions.Regex NumberWithUnit =
    new(@"^\s*([-+]?\d+(?:[.,]\d+)?)\s*([\p{L}°µ%][\p{L}°µ%²³/]{0,9})\s*$", System.Text.RegularExpressions.RegexOptions.CultureInvariant);

  /// <summary>
  /// Vrednost z enoto (»40 cm«) pri atributu, ki ima svojo enoto, se razdeli: v atribut gre samo
  /// število, enota pa v atribut enote (David 2026-09-24: »program naj sam loči in vstavi pravilno —
  /// cifro in enoto pod atribute, ki imajo enoto«). Atribut ima enoto, kadar:
  ///   - ima v šifrantu stalno enoto (AttributeDefinition.Unit) — potem gre naprej samo število,
  ///     drugačna enota pa se ne zapiše, ker bi bila vrednost v napačni enoti;
  ///   - ima par »atribut enote« (IsUnitCandidate, UnitOfAttributeCode na /katalog/atributi), ali pa
  ///     ima atribut enote s pripadajočim imenom (»Enota dolžine paketa I« ↔ »Dolžina paketa I«).
  /// Vrednost brez enote in atribut brez enote ostaneta nespremenjena.
  /// </summary>
  async Task<List<ProductWorkbookRowChange>> SplitAttributeUnitsAsync(
    List<ProductWorkbookRowChange> rows, List<string> problems, CancellationToken cancellationToken)
  {
    var prefix = ProductWorkbookContract.AttributeFieldPrefix;
    if (!rows.Any(row => row.PimValues.Keys.Any(key => key.StartsWith(prefix, StringComparison.Ordinal))))
      return rows;

    var units = await AttributeUnitsAsync(cancellationToken);
    var split = new Dictionary<(string Attribute, string Target), int>();
    var wrongUnit = new Dictionary<(string Attribute, string Unit, string Expected), List<string>>();
    var converted = new Dictionary<(string Attribute, string From, string To), int>();
    var notInUnit = new Dictionary<(string Attribute, string Expected), List<string>>();
    var result = new List<ProductWorkbookRowChange>(rows.Count);
    foreach (var row in rows)
    {
      var values = new Dictionary<string, string>(row.PimValues, StringComparer.Ordinal);
      foreach (var (fieldKey, value) in row.PimValues)
      {
        if (!fieldKey.StartsWith(prefix, StringComparison.Ordinal)) continue;
        var name = fieldKey[prefix.Length..];
        if (!units.TryGetValue(name, out var unit)) continue;
        if (unit.Fixed is { } expected)
        {
          // 301 (uporabnik 2026-09-29): atribut ima svojo enoto. Uvoz dovoli karkoli, enoto pa upošteva:
          //   - »5 m« ali 5 + stolpec »Enota …« v isti vrstici -> pretvori v enoto atributa (ista enota: samo število);
          //   - enota, ki je ni mogoče pretvoriti (»5 ft«), in besedilo (»do 30m«) se zapišeta, kot sta, z opozorilom.
          // Atribut enote se ne zapiše iz datoteke: PIM ga ob zapisu nastavi na enoto atributa (canon.AlignAttributeUnits).
          var unitColumn = unit.UnitAttribute is { } unitName ? prefix + unitName : null;
          string? columnUnit = null;
          if (unitColumn is not null && row.PimValues.TryGetValue(unitColumn, out var fromColumn) && !string.IsNullOrWhiteSpace(fromColumn))
          {
            columnUnit = fromColumn.Trim();
            values.Remove(unitColumn);
          }
          string? numberText = null, given = null;
          if (NumberWithUnit.Match(value) is { Success: true } withUnit)
          {
            numberText = withUnit.Groups[1].Value;
            given = withUnit.Groups[2].Value;
          }
          else if (Number(value) is not null)
          {
            numberText = value.Trim();
            given = columnUnit ?? expected;
          }
          if (numberText is null)
          {
            (notInUnit.TryGetValue((name, expected), out var textItems) ? textItems : notInUnit[(name, expected)] = []).Add(row.ItemId);
            continue;
          }
          if (SameUnit(given!, expected))
          {
            if (!string.Equals(numberText, value.Trim(), StringComparison.Ordinal))
            {
              values[fieldKey] = numberText;
              split[(name, expected)] = split.GetValueOrDefault((name, expected)) + 1;
            }
          }
          // Uporabnik 2026-09-29: »če imamo isto enoto, pusti, čene spremeni v tisto, ki je enota atributa«.
          else if (UnitFactor(given!, expected) is { } factor
            && decimal.TryParse(numberText.Replace(',', '.'), NumberStyles.Number, CultureInfo.InvariantCulture, out var parsed))
          {
            values[fieldKey] = (parsed * factor).ToString("0.######", CultureInfo.InvariantCulture);
            converted[(name, given!, expected)] = converted.GetValueOrDefault((name, given!, expected)) + 1;
          }
          else
          {
            (wrongUnit.TryGetValue((name, given!, expected), out var items) ? items : wrongUnit[(name, given!, expected)] = []).Add(row.ItemId);
          }
          continue;
        }
        if (NumberWithUnit.Match(value) is not { Success: true } match) continue;
        var number = match.Groups[1].Value.Replace(',', '.');
        var given2 = match.Groups[2].Value;
        var unitKey = prefix + unit.UnitAttribute;
        // Stolpec enote v isti vrstici ima prednost: uporabnik ga je izpolnil izrecno.
        if (values.TryGetValue(unitKey, out var explicitUnit) && !string.Equals(explicitUnit, given2, StringComparison.OrdinalIgnoreCase)
          && row.PimValues.ContainsKey(unitKey))
          continue;
        values[fieldKey] = number;
        values[unitKey] = given2;
        split[(name, unit.UnitAttribute!)] = split.GetValueOrDefault((name, unit.UnitAttribute!)) + 1;
      }
      result.Add(row with { PimValues = values });
    }

    foreach (var ((name, target), count) in split)
      problems.Add(target == units[name].Fixed
        ? $"Atribut »{name}«: enota »{target}« je odstranjena iz vrednosti ({count:N0}×) — atribut ima stalno enoto."
        : $"Atribut »{name}«: vrednost z enoto razdeljena ({count:N0}×) — število v »{name}«, enota v »{target}«.");
    foreach (var ((name, from, to), count) in converted)
      problems.Add($"Atribut »{name}«: vrednosti v »{from}« pretvorjene v »{to}« ({count:N0}×) — atribut ima stalno enoto {to}.");
    foreach (var ((name, given, expected), items) in wrongUnit)
      problems.Add($"Atribut »{name}« je v »{expected}«, v datoteki pa »{given}«, ki se v {expected} ne da pretvoriti; vrednost je zapisana, "
        + $"kot je, pri {items.Count:N0} artiklih ({string.Join(", ", items.Take(10))}{(items.Count > 10 ? " …" : "")}). Popravi jo v {expected}.");
    foreach (var ((name, expected), items) in notInUnit)
      problems.Add($"Atribut »{name}« je v »{expected}«, v datoteki pa ni število: vrednost je zapisana, kot je, pri {items.Count:N0} artiklih "
        + $"({string.Join(", ", items.Take(10))}{(items.Count > 10 ? " …" : "")}). Če se da, jo zapiši kot število v {expected}.");
    return result;
  }

  /// <summary>
  /// Količnik med enotama iste vrste (dolžina, masa, prostornina); null, kadar enote ne poznamo ali nista
  /// iste vrste — takrat se vrednost ne pretvori. Isto pravilo kot out.UnitFactor pri izvozu kataloga.
  /// </summary>
  internal static decimal? UnitFactor(string from, string to)
  {
    static (string Kind, decimal Base)? Of(string unit) => CanonicalUnit(unit) switch
    {
      "mm" => ("len", 1m), "cm" => ("len", 10m), "m" => ("len", 1000m),
      "g" => ("mass", 1m), "kg" => ("mass", 1000m),
      "cm3" => ("vol", 1m), "dm3" => ("vol", 1000m), "m3" => ("vol", 1000000m),
      _ => null,
    };
    return Of(from) is { } source && Of(to) is { } target && source.Kind == target.Kind ? source.Base / target.Base : null;
  }

  /// <summary>Enota v enotni obliki; sopomenke kot canon.UnitConversion (301): mt, kgs, gr, l, m³ …</summary>
  static string CanonicalUnit(string unit) => unit.Trim().ToLowerInvariant() switch
  {
    "mt" => "m", "kgs" => "kg", "gr" => "g", "l" or "dm³" => "dm3", "cm³" => "cm3", "m³" => "m3",
    "deg" => "°", "hours" or "hr" or "ur" => "h", var other => other,
  };

  /// <summary>Ista enota ne glede na zapis (»MM« = »mm«, »mt« = »m«).</summary>
  static bool SameUnit(string left, string right) => CanonicalUnit(left) == CanonicalUnit(right);

  /// <param name="Fixed">Stalna enota atributa (AttributeDefinition.Unit).</param>
  /// <param name="UnitAttribute">Slovensko ime atributa, ki nosi enoto tega atributa.</param>
  sealed record AttributeUnit(string? Fixed, string? UnitAttribute);

  /// <summary>Atributi z enoto, po slovenskem imenu (ključ vrednosti v canon.ProductAttribute).</summary>
  async Task<Dictionary<string, AttributeUnit>> AttributeUnitsAsync(CancellationToken cancellationToken)
  {
    var definitions = new List<(string Code, string Name, string? Unit, bool IsUnit, string? UnitOf)>();
    await using (var connection = new SqlConnection(ConnectionString))
    {
      await connection.OpenAsync(cancellationToken);
      await using var command = new SqlCommand("""
        SELECT definition.AttributeCode, Name = COALESCE(translation.Name, definition.AttributeCode),
          definition.Unit, definition.IsUnitCandidate, definition.UnitOfAttributeCode
        FROM canon.AttributeDefinition AS definition
        LEFT JOIN canon.AttributeTranslation AS translation
          ON translation.AttributeCode = definition.AttributeCode AND translation.LanguageCode = N'sl'
        WHERE definition.IsActive = 1;
        """, connection) { CommandTimeout = 60 };
      await using var reader = await command.ExecuteReaderAsync(cancellationToken);
      while (await reader.ReadAsync(cancellationToken))
        definitions.Add((PimDb.TextOrEmpty(reader, "AttributeCode"), PimDb.TextOrEmpty(reader, "Name"),
          PimDb.Text(reader, "Unit"), PimDb.Bool(reader, "IsUnitCandidate"), PimDb.Text(reader, "UnitOfAttributeCode")));
    }

    var byCode = definitions.ToDictionary(item => item.Code, item => item.Name, StringComparer.OrdinalIgnoreCase);
    var result = new Dictionary<string, AttributeUnit>(StringComparer.OrdinalIgnoreCase);
    foreach (var item in definitions.Where(item => !item.IsUnit && !string.IsNullOrWhiteSpace(item.Unit)))
      result[item.Name] = new(item.Unit!.Trim(),
        definitions.FirstOrDefault(unit => unit.IsUnit && string.Equals(unit.UnitOf, item.Code, StringComparison.OrdinalIgnoreCase)).Name is { Length: > 0 } unitName
          ? unitName : null);
    // Izrecni par ima prednost pred ujemanjem po imenu.
    foreach (var unit in definitions.Where(item => item.IsUnit && item.UnitOf is not null))
      if (byCode.TryGetValue(unit.UnitOf!, out var baseName) && !result.ContainsKey(baseName))
        result[baseName] = new(null, unit.Name);
    var stems = definitions.Where(item => !item.IsUnit)
      .GroupBy(item => NameStem(item.Name), StringComparer.OrdinalIgnoreCase)
      .Where(group => group.Count() == 1)
      .ToDictionary(group => group.Key, group => group.Single().Name, StringComparer.OrdinalIgnoreCase);
    foreach (var unit in definitions.Where(item => item.IsUnit && item.UnitOf is null
      && item.Name.StartsWith("Enota ", StringComparison.OrdinalIgnoreCase)))
      if (stems.TryGetValue(NameStem(unit.Name[6..]), out var baseName) && !result.ContainsKey(baseName))
        result[baseName] = new(null, unit.Name);
    return result;
  }

  /// <summary>Ime brez sklonskih končnic: »dolžine paketa I« in »Dolžina paketa I« dasta isto.</summary>
  static string NameStem(string name) => string.Join(" ", name.ToLowerInvariant()
    .Split(' ', StringSplitOptions.RemoveEmptyEntries)
    .Select(word => word.Length > 3 && char.IsLetter(word[^1]) ? word[..^1] : word));

  /// <summary>
  /// Predogled brez novih atributov, ki jih uporabnik v pojavnem oknu ni potrdil: atribut se ne
  /// ustvari in njegove vrednosti se ne zapišejo. Prej je uvoz vsak neznan stolpec pod skupino
  /// atributov ustvaril brez vprašanja — tipkarska napaka v naslovu je postala nov atribut.
  /// </summary>
  public static ProductWorkbookPreview WithoutNewAttributes(ProductWorkbookPreview preview, IReadOnlyCollection<string> rejected)
  {
    if (rejected.Count == 0) return preview;
    var names = rejected.ToHashSet(StringComparer.OrdinalIgnoreCase);
    var rows = preview.Rows
      .Select(row => row with
      {
        PimValues = row.PimValues
          .Where(pair => !(pair.Key.StartsWith(ProductWorkbookContract.AttributeFieldPrefix, StringComparison.Ordinal)
            && names.Contains(pair.Key[ProductWorkbookContract.AttributeFieldPrefix.Length..])))
          .ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.Ordinal),
      })
      .Where(row => row.PimValues.Count > 0 || row.SaopValues.Count > 0).ToList();
    return preview with
    {
      Rows = rows,
      NewAttributes = (preview.NewAttributes ?? []).Where(name => !names.Contains(name)).ToList(),
    };
  }

  /// <summary>»A>B >C« → »A > B > C«.</summary>
  public static string CategoryPathText(string path) =>
    string.Join(" > ", path.Split('>').Select(part => part.Trim()).Where(part => part.Length > 0));

  /// <summary>
  /// Obstoječa pot, ki je najbrž mišljena: zadnji del poti mora biti podoben (enak, vsebovan ali z
  /// največ dvema tipkarskima napakama, brez razlike šumnikov); med takimi zmaga tista z najdaljšim
  /// skupnim začetkom. Brez podobnega zadnjega dela predloga ni — naključna sestrska kategorija bi zavajala.
  /// </summary>
  static string? ClosestCategory(string path, IEnumerable<string> existing)
  {
    var parts = path.Split(" > ");
    var last = FoldText(parts[^1]);
    string? best = null;
    var bestScore = int.MinValue;
    foreach (var candidate in existing)
    {
      var other = candidate.Split(" > ");
      var otherLast = FoldText(other[^1]);
      var distance = otherLast == last ? 0
        : otherLast.Length >= 4 && last.Length >= 4 && (otherLast.Contains(last) || last.Contains(otherLast))
          && Math.Min(otherLast.Length, last.Length) >= 0.6 * Math.Max(otherLast.Length, last.Length) ? 1
        : Levenshtein(otherLast, last);
      if (distance > 2) continue;
      var prefix = 0;
      while (prefix < parts.Length - 1 && prefix < other.Length - 1
        && string.Equals(parts[prefix], other[prefix], StringComparison.OrdinalIgnoreCase)) prefix++;
      var score = prefix * 10 - distance * 5 - Math.Abs(parts.Length - other.Length);
      if (score > bestScore) { best = candidate; bestScore = score; }
    }
    return best;
  }

  static string FoldText(string text) => new string(text.ToLowerInvariant()
    .Replace('č', 'c').Replace('š', 's').Replace('ž', 'z').Replace('ć', 'c').Replace('đ', 'd')
    .Where(char.IsLetterOrDigit).ToArray());

  async Task<Dictionary<string, string>> SiteLanguagesAsync(CancellationToken cancellationToken)
  {
    var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("SELECT WebSiteCode, LanguageCode FROM canon.WebSite;", connection);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    while (await reader.ReadAsync(cancellationToken))
      result[PimDb.TextOrEmpty(reader, "WebSiteCode")] = PimDb.Text(reader, "LanguageCode") ?? "sl";
    return result;
  }

  /// <summary>Predpona ključa, pod katerim je šifra zapisana natanko tako, kot jo nosijo artikli.</summary>
  const string ExactCode = "\u0001";

  /// <summary>Ključ za primerjavo šifer: brez razlike velikih črk, pri partnerjih brez vodilnih ničel.</summary>
  static string CodeKey(string value, bool partner)
  {
    var key = value.Trim().ToUpperInvariant();
    if (partner || key.All(char.IsAsciiDigit)) key = key.TrimStart('0');
    return key;
  }

  async Task<Dictionary<(int OrganizationId, string FieldKey), Dictionary<string, string>>> ReadKnownCodesAsync(
    IReadOnlyList<int> organizationIds, CancellationToken cancellationToken)
  {
    var known = new Dictionary<(int, string), Dictionary<string, string>>();
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("""
      DECLARE @Org TABLE (OrganizationId int PRIMARY KEY);
      INSERT @Org SELECT DISTINCT CONVERT(int, value) FROM OPENJSON(@OrganizationIdsJson);
      -- 124: zapis šifre se loči po velikih črkah (BIN2). Baza je CI, zato je GROUP BY po v.Code
      -- »KPL« in »kpl« zlil v en (naključen) zapis; »KPL« potem ni bil znan natanko, uvoz nespremenjene
      -- datoteke ga je »popravil« na »kpl« in 455 artiklov poslal v vrsto za SAOP.
      WITH Uses AS (
        SELECT p.OrganizationId, v.FieldKey, v.Code, Uses = 1
        FROM canon.Product AS p
        INNER JOIN @Org AS o ON o.OrganizationId = p.OrganizationId
        CROSS APPLY (VALUES (N'Product.UoM', p.UoM), (N'Product.ItemGroup', p.ItemGroup),
          (N'Product.AccountingGroup', p.AccountingGroup), (N'Product.Department', p.Department),
          (N'Product.DiscountGroup', p.DiscountGroup), (N'Product.VatRateId', p.VatRateId),
          (N'Product.PriceListCode', p.PriceListCode), (N'Product.Supplier', p.Supplier),
          (N'Product.Manufacturer', p.Manufacturer)) AS v(FieldKey, Code)
        WHERE NULLIF(LTRIM(v.Code), N'') IS NOT NULL
        UNION ALL
        SELECT p.OrganizationId, v.FieldKey, v.Code, 1
        FROM canon.ProductCommercial AS c
        INNER JOIN canon.Product AS p ON p.ProductId = c.ProductId
        INNER JOIN @Org AS o ON o.OrganizationId = p.OrganizationId
        CROSS APPLY (VALUES (N'ProductCommercial.DimensionUnit', c.DimensionUnit),
          (N'ProductCommercial.CountryOfOrigin', c.CountryOfOrigin)) AS v(FieldKey, Code)
        WHERE NULLIF(LTRIM(v.Code), N'') IS NOT NULL
        UNION ALL
        SELECT n.OrganizationId, v.FieldKey, n.PartnerCode, 0
        FROM canon.PartnerName AS n
        INNER JOIN @Org AS o ON o.OrganizationId = n.OrganizationId
        CROSS APPLY (VALUES (N'Product.Supplier'), (N'Product.Manufacturer')) AS v(FieldKey)
        UNION ALL
        SELECT b.OrganizationId, N'Product.PriceListCode', b.EntryCode, 0
        FROM canon.Codebook AS b
        INNER JOIN @Org AS o ON o.OrganizationId = b.OrganizationId
        WHERE b.CodebookCode = N'PRICELIST' AND b.IsActive = 1
      )
      SELECT OrganizationId, FieldKey, Code = Code COLLATE Latin1_General_BIN2, Uses = SUM(Uses)
      FROM Uses
      GROUP BY OrganizationId, FieldKey, Code COLLATE Latin1_General_BIN2
      ORDER BY Uses DESC;
      """, connection) { CommandTimeout = 120 };
    command.Parameters.Add("@OrganizationIdsJson", SqlDbType.NVarChar, -1).Value = JsonSerializer.Serialize(organizationIds);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    while (await reader.ReadAsync(cancellationToken))
    {
      var key = (PimDb.Int32(reader, "OrganizationId"), PimDb.TextOrEmpty(reader, "FieldKey"));
      var code = PimDb.TextOrEmpty(reader, "Code").Trim();
      if (!known.TryGetValue(key, out var codes)) known[key] = codes = new(StringComparer.Ordinal);
      // Pri več zapisih iste šifre (»kom« in »KOM«) zmaga pogostejši: poizvedba jih vrne po številu
      // artiklov padajoče, zato ga TryAdd vzame prvega; oba sta veljavna v SAOP, ker ju artikli že nosijo.
      codes.TryAdd(CodeKey(code, CodeFields[key.Item2].Partner), code);
      // Drugi zapis iste šifre (»KOS« ob »kos«) je tudi veljaven; ključ z zapisom ga ohrani.
      codes.TryAdd(ExactCode + code, code);
    }
    return known;
  }

  /// <summary>
  /// Stolpci atributov, ki jih pogodba ni poznala. Pogodba pozna samo atribute, ki so v kakšnem
  /// naboru, imajo kje vrednost ali jih zahteva validacija (intranet.GetProductWorkbook); vse
  /// drugo je padlo med neprepoznane in vrednosti so se tiho izgubile. Zdaj:
  ///   - naslov, ki je ime ali koda atributa iz šifranta, je ta atribut (ključ vrednosti je
  ///     slovensko ime, kot v canon.ProductAttribute);
  ///   - naslov pod skupino atributov (vrstica nad naslovi, npr. »Atributi kategorije — nabor«),
  ///     ki ga šifrant ne pozna, je NOV atribut — uvoz ga ustvari ob zapisu (ApplyAsync).
  /// Naslov brez skupine, ki ga ni v šifrantu, ostane neprepoznan: brez skupine ne vemo, ali je
  /// atribut ali tipkarska napaka v imenu drugega stolpca.
  /// </summary>
  async Task<(IReadOnlyList<ProductWorkbookHeaderMatch> Matches, IReadOnlyList<string> NewAttributes, IReadOnlyDictionary<string, string> Suggestions)> MatchAttributesAsync(
    IReadOnlyList<ProductWorkbookHeaderMatch> matches, WorkbookSheet sheet,
    IReadOnlyDictionary<string, string>? columnAttributes, CancellationToken cancellationToken)
  {
    if (!NeedsAttributeMatching(matches, sheet.GroupOf))
      return (matches, [], new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase));
    return MatchAttributes(matches, sheet.GroupOf, await AttributeNamesAsync(cancellationToken), columnAttributes);
  }

  /// <summary>Opozorilo za vsak preskočen dvoumen stolpec (»Naziv«), enkrat na naslov (#6).</summary>
  public static IReadOnlyList<string> AmbiguousColumnWarnings(IReadOnlyList<ProductWorkbookHeaderMatch> matches,
    IReadOnlyList<ProductWorkbookColumn> columns) =>
    matches.Where(match => match.Ambiguous).Select(match => match.Header.Trim())
      .Distinct(StringComparer.OrdinalIgnoreCase)
      .Select(header => ProductWorkbookContract.AmbiguousHeaderWarning(header, columns)).ToList();

  // Stolpec pod skupino atributov, ki se je po naslovu ujel s poljem SAOP (»Dolžina« = ItemLength), je
  // atribut: uporabnik 2026-09-29 — »5m« pod Atributi je šel v številsko polje SAOP in bil preskočen.
  static bool UnderAttributeGroupAsField(ProductWorkbookHeaderMatch match, Func<int, string> groupOf) =>
    match.Column is not null && !match.Column.FieldKey.StartsWith(ProductWorkbookContract.AttributeFieldPrefix, StringComparison.Ordinal)
    && match.Column.Group != ProductWorkbookContract.GroupKey
    && ProductWorkbookContract.IsAttributeGroup(groupOf(match.Index));

  /// <summary>Ali ima list kak stolpec, ki ga je treba iskati med atributi (šifrant se bere samo takrat).</summary>
  static bool NeedsAttributeMatching(IReadOnlyList<ProductWorkbookHeaderMatch> matches, Func<int, string> groupOf) =>
    !matches.All(match => (match.Column is not null && !UnderAttributeGroupAsField(match, groupOf))
      || match.Ambiguous || string.IsNullOrWhiteSpace(match.Header));

  /// <summary>Čisti del <see cref="MatchAttributesAsync"/> (brez baze; preizkus F10.ProductWorkbookTests).</summary>
  /// <param name="known">Normaliziran naslov (ime ali koda atributa) → slovensko ime atributa.</param>
  public static (IReadOnlyList<ProductWorkbookHeaderMatch> Matches, IReadOnlyList<string> NewAttributes, IReadOnlyDictionary<string, string> Suggestions) MatchAttributes(
    IReadOnlyList<ProductWorkbookHeaderMatch> matches, Func<int, string> groupOf,
    IReadOnlyDictionary<string, string> known, IReadOnlyDictionary<string, string>? columnAttributes)
  {
    var suggestions = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    bool UnderAttributeGroupAsField(ProductWorkbookHeaderMatch match) => ProductWorkbookService.UnderAttributeGroupAsField(match, groupOf);
    var used = matches.Where(match => match.Column is not null && !UnderAttributeGroupAsField(match))
      .Select(match => match.Column!.FieldKey).ToHashSet(StringComparer.Ordinal);
    var result = new List<ProductWorkbookHeaderMatch>(matches.Count);
    var created = new List<string>();
    foreach (var match in matches)
    {
      // Dvoumen naslov (»Naziv«) ni atribut, tudi pod skupino atributov ne in tudi če ga je kdo
      // izbral v oknu: ne dobi predloga (»Nazivna napetost«) in se ne ustvari kot nov atribut (#6).
      if (match.Ambiguous) { result.Add(match); continue; }
      if (UnderAttributeGroupAsField(match))
      {
        // Samo, če atribut s tem imenom obstaja; sicer ostane polje, kot je bilo (ne ustvarjamo atributa z imenom polja SAOP).
        if (known.TryGetValue(WorkbookHeader.Normalize(match.Header.Trim()), out var attributeName)
          && ProductWorkbookContract.AttributeColumn(groupOf(match.Index), match.Header.Trim(), attributeName) is var attributeColumn
          && used.Add(attributeColumn.FieldKey))
        {
          result.Add(match with { Column = attributeColumn });
          continue;
        }
        used.Add(match.Column!.FieldKey);
        result.Add(match);
        continue;
      }
      if (match.Column is not null || string.IsNullOrWhiteSpace(match.Header)) { result.Add(match); continue; }
      var group = groupOf(match.Index);
      var header = match.Header.Trim();
      string? name = known.TryGetValue(WorkbookHeader.Normalize(header), out var existing) ? existing : null;
      // Odločitev uporabnika iz pojavnega okna ima prednost: stolpec gre v izbrani (obstoječi ali nov) atribut.
      if (columnAttributes is not null && columnAttributes.TryGetValue(header, out var chosen) && !string.IsNullOrWhiteSpace(chosen))
      {
        name = known.TryGetValue(WorkbookHeader.Normalize(chosen), out var chosenExisting) ? chosenExisting : chosen.Trim();
        if (!known.ContainsKey(WorkbookHeader.Normalize(chosen))) created.Add(name);
      }
      else if (name is null && ProductWorkbookContract.IsAttributeGroup(group))
      {
        name = header;
        created.Add(header);
      }
      if (name is null || created.Contains(name, StringComparer.OrdinalIgnoreCase))
        if (ClosestAttribute(header, known.Values) is { } similar) suggestions[header] = similar;
      var column = name is null ? null : ProductWorkbookContract.AttributeColumn(
        ProductWorkbookContract.IsAttributeGroup(group) ? group : ProductWorkbookContract.GroupAttributesOutside, header, name);
      // Isti atribut dvakrat (ime in koda v dveh stolpcih): drugi bi povozil prvega.
      result.Add(column is not null && used.Add(column.FieldKey) ? match with { Column = column } : match);
    }
    return (result, created.Distinct(StringComparer.OrdinalIgnoreCase).ToList(), suggestions);
  }

  /// <summary>
  /// Obstoječi atribut, ki je najbrž mišljen z danim naslovom: brez razlike velikih črk in šumnikov
  /// (»Barva ohisja« → »Barva ohišja«), z največ nekaj tipkarskimi napakami, ali pa vsebuje/je vsebovan.
  /// </summary>
  static string? ClosestAttribute(string header, IEnumerable<string> names)
  {
    var wanted = Fold(header);
    if (wanted.Length < 3) return null;
    string? best = null;
    var bestDistance = int.MaxValue;
    foreach (var name in names.Distinct(StringComparer.OrdinalIgnoreCase))
    {
      var candidate = Fold(name);
      var distance = candidate == wanted ? 0
        : (candidate.Length >= 4 && wanted.Length >= 4 && (candidate.Contains(wanted) || wanted.Contains(candidate)))
          ? 1 + Math.Abs(candidate.Length - wanted.Length) / 4
          : Levenshtein(candidate, wanted);
      if (distance < bestDistance) { best = name; bestDistance = distance; }
    }
    return bestDistance <= Math.Max(2, wanted.Length / 5) ? best : null;

    static string Fold(string text) => new string(text.ToLowerInvariant()
      .Replace('č', 'c').Replace('š', 's').Replace('ž', 'z').Replace('ć', 'c').Replace('đ', 'd')
      .Where(char.IsLetterOrDigit).ToArray());
  }

  static int Levenshtein(string left, string right)
  {
    var previous = Enumerable.Range(0, right.Length + 1).ToArray();
    for (var i = 1; i <= left.Length; i++)
    {
      var current = new int[right.Length + 1];
      current[0] = i;
      for (var j = 1; j <= right.Length; j++)
        current[j] = Math.Min(Math.Min(current[j - 1] + 1, previous[j] + 1),
          previous[j - 1] + (left[i - 1] == right[j - 1] ? 0 : 1));
      previous = current;
    }
    return previous[right.Length];
  }

  /// <summary>Ime atributa po normaliziranem slovenskem imenu ali kodi; vrednost je slovensko ime (ključ vrednosti).</summary>
  async Task<Dictionary<string, string>> AttributeNamesAsync(CancellationToken cancellationToken)
  {
    var names = new Dictionary<string, string>(StringComparer.Ordinal);
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("""
      SELECT definition.AttributeCode, Name = COALESCE(translation.Name, definition.AttributeCode)
      FROM canon.AttributeDefinition AS definition
      LEFT JOIN canon.AttributeTranslation AS translation
        ON translation.AttributeCode = definition.AttributeCode AND translation.LanguageCode = N'sl'
      ORDER BY definition.IsActive DESC, definition.AttributeCode;
      """, connection) { CommandTimeout = 60 };
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    while (await reader.ReadAsync(cancellationToken))
    {
      var name = PimDb.TextOrEmpty(reader, "Name");
      names.TryAdd(WorkbookHeader.Normalize(name), name);
      names.TryAdd(WorkbookHeader.Normalize(PimDb.TextOrEmpty(reader, "AttributeCode")), name);
    }
    return names;
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
    List<ProductWorkbookRowChange> rows, IReadOnlyDictionary<string, string> shopByToken,
    IReadOnlySet<string> boolFields, IReadOnlySet<string> numberFields, List<string> problems, CancellationToken cancellationToken)
  {
    if (rows.Count == 0) return rows;

    var keys = new Dictionary<(int, string), ProductKey>();
    // Ključ je šifra, kot je v DATOTEKI: baza vrne svoj zapis (J4.8V2…), datoteka ima lahko J4.8v2…;
    // ResolveProductIdsAsync išče brez razlikovanja velikih črk, ta slovar pa jih loči.
    foreach (var group in rows.GroupBy(row => row.OrganizationId))
    {
      var found = await ResolveProductIdsAsync(group.Key, group.Select(row => row.ItemId).ToList(), cancellationToken);
      foreach (var row in group)
        if (found.TryGetValue(row.ItemId, out var key)) keys[(group.Key, row.ItemId)] = key;
    }

    var fieldCodes = rows
      .SelectMany(row => row.PimValues.Keys.Concat(row.SaopValues.Keys))
      .Where(key => !IsListField(key))
      .Distinct(StringComparer.Ordinal).ToList();

    var productIds = rows.Where(row => keys.ContainsKey((row.OrganizationId, row.ItemId)))
      .Select(row => keys[(row.OrganizationId, row.ItemId)].ProductId).Distinct().ToList();
    var current = await ReadBatchedAsync(productIds, fieldCodes, cancellationToken);

    var result = new List<ProductWorkbookRowChange>(rows.Count);
    var notPromoted = new List<string>();
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
        if (Changed(pair.Key, pair.Value, key, current, shopByToken, boolFields, numberFields)) pim[pair.Key] = pair.Value;

      var saopValues = new Dictionary<string, string>(StringComparer.Ordinal);
      foreach (var pair in row.SaopValues)
        if (Changed(pair.Key, pair.Value, key, current, shopByToken, boolFields, numberFields)) saopValues[pair.Key] = pair.Value;

      // 280: kaj je bilo zapisano tik pred uvozom — zgodovina uvozov in povratek (»Povrni uvoz«).
      var old = new Dictionary<string, string?>(StringComparer.Ordinal);
      foreach (var fieldKey in pim.Keys.Concat(saopValues.Keys))
        old[fieldKey] = CurrentCell(fieldKey, key, current, boolFields);

      // 274: S se dodeli samo objavljenemu izdelku (pim.Product). Neobjavljen bi bil ob vsakem uvozu
      // znova »sprememba«, ki se ne more zapisati — zato se izloči in pove enkrat, za vse skupaj.
      if (pim.Keys.Any(ProductWorkbookContract.IsPackagingField) && !current.Values.ContainsKey((key.ProductId, PackagingPromotedMarker)))
      {
        foreach (var field in pim.Keys.Where(ProductWorkbookContract.IsPackagingField).ToList()) pim.Remove(field);
        notPromoted.Add(row.ItemId);
      }

      // Šifra, ki se razlikuje samo po vodilnih ničlah (»02« -> »2«), je sprememba — a pogosto je
      // ni naredil človek, ampak Excel, ki vpis v navadno celico spremeni v število. Uvoz je ne
      // zamolči in je ne pošlje tiho: v predogledu jo izrecno pokaže.
      foreach (var pair in pim.Concat(saopValues))
        if (!numberFields.Contains(pair.Key) && Stored(pair.Key, key.ProductId, current) is { } stored
          && OnlyLeadingZerosDiffer(pair.Value, stored))
          problems.Add($"Vrstica {row.RowNumber} (artikel {row.ItemId}): {pair.Key} »{stored.Trim()}« -> »{pair.Value}« "
            + "se razlikuje samo po vodilnih ničlah. Če jih je odrezal Excel, celico zapiši kot besedilo ('" + stored.Trim() + ").");

      if (pim.Count == 0 && saopValues.Count == 0) continue;
      result.Add(row with { PimValues = pim, SaopValues = saopValues, OldValues = old });
    }
    if (notPromoted.Count > 0)
      problems.Add($"S-popust se ne zapiše {notPromoted.Count:N0} artiklom, ker še niso objavljeni v PIM (S se dodeli samo objavljenemu izdelku; "
        + "ko bo artikel objavljen, uvozi datoteko znova): " + string.Join(", ", notPromoted.Take(40)) + (notPromoted.Count > 40 ? $" … in še {notPromoted.Count - 40}." : "."));
    return result;
  }

  /// <summary>
  /// 280: trenutna vrednost polja v obliki, ki jo uvoz zna zapisati nazaj (logično 1/0, seznam ločen z »|«,
  /// spletne strani kot kode dreves); null = prazno. Iz tega nastane »prej« v zgodovini in vrednost povratka.
  /// </summary>
  static string? CurrentCell(string fieldKey, ProductKey key, WorkbookData current, IReadOnlySet<string> boolFields)
  {
    if (fieldKey == ProductWorkbookContract.WebPublishField) return key.WebPublish ? "1" : "0";
    if (boolFields.Contains(fieldKey))
      return ProductWorkbookContract.ParseYesNo(Stored(fieldKey, key.ProductId, current)) ?? false ? "1" : "0";
    if (fieldKey == ProductWorkbookContract.ImagesField)
      return current.Media.TryGetValue(key.ProductId, out var images) && !string.IsNullOrWhiteSpace(images) ? images : null;
    if (fieldKey == ProductWorkbookContract.DocumentsField)
      return current.Documents.TryGetValue(key.ProductId, out var documents) && !string.IsNullOrWhiteSpace(documents) ? documents : null;
    if (fieldKey == ProductWorkbookContract.WebSitesField)
      return ProductWorkbookContract.JoinList(current.ShopsOf(key.ProductId));
    if (fieldKey.StartsWith(ProductWorkbookContract.CategoryFieldPrefix, StringComparison.Ordinal))
      return current.Categories.TryGetValue((key.ProductId, fieldKey[ProductWorkbookContract.CategoryFieldPrefix.Length..]), out var paths)
        && !string.IsNullOrWhiteSpace(paths) ? paths : null;
    return Stored(fieldKey, key.ProductId, current) is { } stored && !string.IsNullOrWhiteSpace(stored) ? stored : null;
  }

  /// <summary>
  /// 280: povratek uvoza. Iz zabeleženih celic (prej → potem) sestavi nov predogled, ki vrne »prej« — samo tam,
  /// kjer je v PIM še vedno vrednost uvoza. Celica, ki jo je po uvozu spremenil kdo drug, je spor in se ne povrne;
  /// celica, ki je že spet »prej«, se preskoči. Prazne vrednosti v SAOP ni mogoče poslati (graditelj dokumenta
  /// prazno izpusti), zato se tako ERP polje ne povrne in se pove. Zapis gre skozi ApplyAsync kot vsak uvoz:
  /// ERP spremembe čakajo odobritev v vrsti za SAOP.
  /// </summary>
  public async Task<ProductUndoPlan> PlanUndoAsync(IReadOnlyList<ImportChange> changes, CancellationToken cancellationToken = default)
  {
    var skipped = new List<string>();
    var sites = await ActiveWebSitesAsync(cancellationToken);
    var shopByToken = ShopLookup(sites);
    var boolFields = changes.Where(change => change.ValueKind == "BOOL").Select(change => change.FieldKey).ToHashSet(StringComparer.Ordinal);
    var numberFields = changes.Where(change => change.ValueKind == "NUMBER").Select(change => change.FieldKey).ToHashSet(StringComparer.Ordinal);

    var keys = new Dictionary<(int, string), ProductKey>();
    foreach (var group in changes.GroupBy(change => change.OrganizationId))
      foreach (var pair in await ResolveProductIdsAsync(group.Key, group.Select(change => change.RowKey).Distinct(StringComparer.Ordinal).ToList(), cancellationToken))
        keys[(group.Key, pair.Key)] = pair.Value;
    var fieldCodes = changes.Select(change => change.FieldKey).Where(field => !IsListField(field)).Distinct(StringComparer.Ordinal).ToList();
    var current = await ReadBatchedAsync(keys.Values.Select(key => key.ProductId).Distinct().ToList(), fieldCodes, cancellationToken);

    var rows = new List<ProductWorkbookRowChange>();
    int conflicts = 0, alreadyReverted = 0, rowNumber = 0;
    foreach (var item in changes.GroupBy(change => (change.OrganizationId, change.RowKey)))
    {
      var first = item.First();
      if (!keys.TryGetValue((item.Key.OrganizationId, item.Key.RowKey), out var key))
      {
        skipped.Add($"{item.Key.RowKey}: artikla v podjetju {first.OrganizationName} ni več — ne povrnem.");
        continue;
      }
      var pim = new Dictionary<string, string>(StringComparer.Ordinal);
      var saopValues = new Dictionary<string, string>(StringComparer.Ordinal);
      var now = new Dictionary<string, string?>(StringComparer.Ordinal);
      foreach (var change in item)
      {
        var label = change.FieldLabel ?? change.FieldKey;
        var nowCell = CurrentCell(change.FieldKey, key, current, boolFields);
        if (IsSame(change.OldValue, nowCell, change.FieldKey, key)) { alreadyReverted++; continue; }
        if (!IsSame(change.NewValue, nowCell, change.FieldKey, key))
        {
          conflicts++;
          skipped.Add($"{item.Key.RowKey}, {label}: po uvozu spremenjeno (zdaj »{nowCell ?? "prazno"}«, uvoz je zapisal »{change.NewValue ?? "prazno"}«) — ne povrnem, preveri ročno.");
          continue;
        }
        if (change.Target == "SAOP")
        {
          if (change.OldValue is null)
          {
            skipped.Add($"{item.Key.RowKey}, {label}: pred uvozom je bilo prazno — prazne vrednosti v SAOP ni mogoče poslati; polje izprazni v SAOP ročno.");
            continue;
          }
          saopValues[change.FieldKey] = change.OldValue;
        }
        else
        {
          pim[change.FieldKey] = change.OldValue
            ?? (ProductWorkbookContract.IsPackagingField(change.FieldKey) ? ProductWorkbookContract.ClearToken : "");
        }
        now[change.FieldKey] = nowCell;
      }
      if (pim.Count == 0 && saopValues.Count == 0) continue;
      rows.Add(new(++rowNumber, first.OrganizationId, first.OrganizationName ?? first.OrganizationId.ToString(CultureInfo.InvariantCulture),
        item.Key.RowKey, pim, saopValues, now));
    }

    var labels = changes.GroupBy(change => change.FieldKey, StringComparer.Ordinal)
      .ToDictionary(group => group.Key, group => group.First().FieldLabel ?? group.Key, StringComparer.Ordinal);
    var preview = new ProductWorkbookPreview(rows, [], [], [], null, labels, boolFields, numberFields);
    return new(preview, skipped, conflicts, alreadyReverted);

    bool IsSame(string? expected, string? stored, string fieldKey, ProductKey productKey)
    {
      if (string.IsNullOrWhiteSpace(expected) || expected == ProductWorkbookContract.ClearToken) return string.IsNullOrWhiteSpace(stored);
      if (string.IsNullOrWhiteSpace(stored))
        return boolFields.Contains(fieldKey) && ProductWorkbookContract.ParseYesNo(expected) == false;
      return !Changed(fieldKey, expected, productKey, current, shopByToken, boolFields, numberFields);
    }
  }

  /// <summary>»02« in »2«, »0000001« in »1«: isto celo število, različen zapis.</summary>
  public static bool OnlyLeadingZerosDiffer(string incoming, string stored)
  {
    var left = incoming.Trim();
    var right = stored.Trim();
    return left != right && left.Length > 0 && right.Length > 0
      && left.All(char.IsAsciiDigit) && right.All(char.IsAsciiDigit)
      && left.TrimStart('0') == right.TrimStart('0');
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
    IReadOnlyDictionary<string, string> shopByToken, IReadOnlySet<string> boolFields,
    IReadOnlySet<string> numberFields)
  {
    // »-« (izprazni) je sprememba samo, kadar je kaj za izprazniti; primerja se kot prazna vrednost.
    if (incoming == ProductWorkbookContract.ClearToken && !ProductWorkbookContract.IsPackagingField(fieldKey))
      incoming = "";

    if (fieldKey == ProductWorkbookContract.WebPublishField)
    {
      // Zastavica je ze v canon.Product (ResolveProductIdsAsync); ni je treba brati posebej.
      var parsed = ProductWorkbookContract.ParseYesNo(incoming);
      // Nerazumljivo vrednost pustimo naprej: uvoz jo prijavi kot napako vrstice, ne kot tisino.
      return parsed is null || parsed.Value != key.WebPublish;
    }

    if (boolFields.Contains(fieldKey))
    {
      // »da« in »1« sta ista vrednost; kljukica, ki je se nikoli ni bilo (ni vrstice planiranja),
      // velja za »ne« — tako jo kaze tudi kartica izdelka.
      var parsed = ProductWorkbookContract.ParseYesNo(incoming);
      var stored = ProductWorkbookContract.ParseYesNo(Stored(fieldKey, key.ProductId, current)) ?? false;
      return parsed is null || parsed.Value != stored;
    }

    if (ProductWorkbookContract.IsPackagingField(fieldKey))
    {
      // 274: vrednost je že v enotni obliki (NormalizePackagingCell); »-« je prazno.
      var wanted = incoming == ProductWorkbookContract.ClearToken ? "" : incoming;
      var stored = Stored(fieldKey, key.ProductId, current) ?? "";
      return !string.Equals(wanted, stored, StringComparison.OrdinalIgnoreCase);
    }

    if (fieldKey == ProductWorkbookContract.ImagesField)
    {
      // Vrstni red slik je pomen (prva je glavna), zato se primerja po vrsti.
      var stored = current.Media.TryGetValue(key.ProductId, out var images) ? ProductWorkbookContract.SplitList(images) : [];
      return !ProductWorkbookContract.SplitList(incoming).SequenceEqual(stored, StringComparer.Ordinal);
    }

    if (fieldKey == ProductWorkbookContract.DocumentsField)
    {
      var stored = current.Documents.TryGetValue(key.ProductId, out var documents) ? ProductWorkbookContract.SplitList(documents) : [];
      return !SameList(ProductWorkbookContract.SplitList(incoming), stored);
    }

    if (fieldKey == ProductWorkbookContract.WebSitesField)
    {
      // Kljukica spletišča, ne kategorije: neznano ime ostane v seznamu, da ga zapis prijavi.
      var listed = ProductWorkbookContract.SplitList(incoming)
        .Select(token => shopByToken.TryGetValue(WorkbookHeader.Normalize(token), out var tree) ? tree : token)
        .Distinct(StringComparer.OrdinalIgnoreCase)
        .ToList();
      return !SameList(listed, current.ShopsOf(key.ProductId));
    }

    if (fieldKey.StartsWith(ProductWorkbookContract.CategoryFieldPrefix, StringComparison.Ordinal))
    {
      var site = fieldKey[ProductWorkbookContract.CategoryFieldPrefix.Length..];
      var stored = current.Categories.TryGetValue((key.ProductId, site), out var paths)
        ? ProductWorkbookContract.SplitList(paths) : [];
      return !SameList(ProductWorkbookContract.SplitList(incoming), stored);
    }

    return !SameValue(incoming, Stored(fieldKey, key.ProductId, current), numberFields.Contains(fieldKey));
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
    var shopByToken = ShopLookup(sites);

    // Poti kategorij, veljavne za vsako spletno stran, ki jo ta uvoz sploh omenja — preberemo
    // jih enkrat vnaprej, ne na vrstico, da lahko napačno pot povemo natančno (katera pot, za
    // katero stran), namesto da bi to za vsako slabo vrstico posebej povedala šele baza
    // (pim.SetProductCategories, napaka 106007, vedno samo prva najdena). Ta seznam ponovi isti
    // pogoj vnaprej; baza ob dejanskem zapisu ostaja zadnja beseda.
    // 245: poti se preberejo za VSE strani, ne le za tiste s stolpcem v datoteki — jezikovna
    // razlicica (Videlektro (ANG)) brez svojega stolpca dobi kategorijo iz primarne strani istega
    // drevesa (ista kategorija, pot v svojem jeziku), glej ApplySitesAsync.
    var touchesSites = preview.Rows.SelectMany(row => row.PimValues.Keys).Any(key =>
      key == ProductWorkbookContract.WebSitesField
      || key.StartsWith(ProductWorkbookContract.CategoryFieldPrefix, StringComparison.Ordinal));
    var validCategoryPaths = touchesSites
      ? await CategoryPathsBySiteAsync(sites.Select(site => site.Code).ToList(), cancellationToken)
      : new Dictionary<string, SiteCategoryPaths>(StringComparer.OrdinalIgnoreCase);

    // Atributi, ki jih šifrant ne pozna (stolpec pod skupino atributov): najprej v šifrant, nato
    // vrednosti. Brez tega so se vrednosti tiho izgubile (stolpec je bil »neprepoznan«).
    var createdAttributes = new List<string>();
    foreach (var name in preview.NewAttributes ?? [])
    {
      try
      {
        await attributeDefinitions.CreateDefinitionAsync(name, null, null, "TEXT", null, false,
          "Ustvarjen ob uvozu delovnega lista izdelkov.", null, actor, cancellationToken);
        createdAttributes.Add(name);
      }
      catch (Exception failure)
      {
        problems.Add($"Atributa »{name}« ni bilo mogoče ustvariti v šifrantu — {failure.Message} Vrednosti so zapisane pod tem imenom.");
      }
    }

    // Zapisovalne procedure delajo z ProductId; datoteka nosi sifro. Preslikava gre v enem
    // klicu na podjetje, ne v enem klicu na vrstico.
    var productIds = new Dictionary<(int OrganizationId, string ItemId), long>();
    foreach (var group in preview.Rows.GroupBy(row => row.OrganizationId))
    {
      var found = await ResolveProductIdsAsync(group.Key, group.Select(row => row.ItemId).ToList(), cancellationToken);
      foreach (var row in group)
        if (found.TryGetValue(row.ItemId, out var key)) productIds[(group.Key, row.ItemId)] = key.ProductId;
    }

    var known = preview.Rows.Where(row => productIds.ContainsKey((row.OrganizationId, row.ItemId))).ToList();
    foreach (var row in preview.Rows.Except(known))
      problems.Add($"Vrstica {row.RowNumber}: artikla {row.ItemId} v podjetju {row.OrganizationName} ni.");

    // Kategorije in kljukice je mogoce pravilno postaviti samo ob znanju, kaj je zdaj zapisano:
    // spletišče, ki ga v celici ni, mora kljukico izgubiti. Branje gre po paketih (218), ne v
    // enem klicu za vse izdelke datoteke.
    progress?.Report("Berem trenutno stanje izdelkov …");
    var current = await ReadBatchedAsync(
      known.Select(row => productIds[(row.OrganizationId, row.ItemId)]).Distinct().ToList(), [], cancellationToken);

    // 277: prevedljivi atributi imajo vrstico na jezik; celica »sl | en« se razdeli po jezikih.
    var attributeLanguages = await ReadAttributeLanguagesAsync(
      known.Where(row => row.PimValues.Keys.Any(key => key.StartsWith(ProductWorkbookContract.AttributeFieldPrefix, StringComparison.Ordinal)))
        .Select(row => productIds[(row.OrganizationId, row.ItemId)]).Distinct().ToList(), cancellationToken);

    var pimChanges = 0;
    var touchedRows = new HashSet<int>();
    var saopByOrganization = new Dictionary<int, List<(string ItemId, string FieldKey, string? Value)>>();
    var erpByOrganization = new Dictionary<int, List<ProductErpBulkEdit>>();
    var mediaByOrganization = new Dictionary<int, List<ProductMediaBulkEdit>>();

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
          Cleared(row.PimValues[$"{ProductWorkbookContract.TextFieldPrefix}{parts[0]}.{parts[1]}"])))
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
        .SelectMany(pair => AttributeEdits(productId, pair.Key[ProductWorkbookContract.AttributeFieldPrefix.Length..],
          Cleared(pair.Value), attributeLanguages, row, problems))
        .ToList();
      if (attributes.Count > 0)
      {
        if (!attributesByOrganization.TryGetValue(row.OrganizationId, out var attributeList))
          attributesByOrganization[row.OrganizationId] = attributeList = [];
        attributeList.AddRange(attributes);
        bulkRows.Add(row.RowNumber);
      }

      // 3) Slike in dokumenti — celica je cel seznam; kar izdelek ima, v celici pa ni, se izbriše.
      //    Kaj je slika in kaj dokument, pove ista MediaKindPolicy kot izvoz (current.Media/Documents).
      foreach (var (field, kind, stored) in new[]
      {
        (ProductWorkbookContract.ImagesField, ProductMediaBulkEdit.Images, current.Media),
        (ProductWorkbookContract.DocumentsField, ProductMediaBulkEdit.Documents, current.Documents),
      })
      {
        if (!row.PimValues.TryGetValue(field, out var cell)) continue;
        var urls = ProductWorkbookContract.SplitList(Cleared(cell));
        var before = stored.TryGetValue(productId, out var joined) ? ProductWorkbookContract.SplitList(joined) : [];
        var remove = before.Where(url => !urls.Contains(url, StringComparer.OrdinalIgnoreCase)).ToList();
        if (!mediaByOrganization.TryGetValue(row.OrganizationId, out var mediaList))
          mediaByOrganization[row.OrganizationId] = mediaList = [];
        mediaList.Add(new(productId, kind, urls, remove));
        bulkRows.Add(row.RowNumber);
      }

      // 4) Spletne strani in kategorije
      var siteChanges = await ApplySitesAsync(
        row, productId, current, shopByToken, sites, validCategoryPaths, actor, note, problems, cancellationToken);
      if (siteChanges > 0) { pimChanges += siteChanges; rowChanged = true; }

      // 5) ERP polja: v odhodno vrsto za SAOP (čaka odobritev) IN v katalog PIM takoj (245).
      //    Logična polja (objava, aktiven, kljukica za rezervacijo) so že v predogledu 1/0.
      if (row.SaopValues.Count > 0)
      {
        if (!saopByOrganization.TryGetValue(row.OrganizationId, out var list))
          saopByOrganization[row.OrganizationId] = list = [];
        if (!erpByOrganization.TryGetValue(row.OrganizationId, out var erpList))
          erpByOrganization[row.OrganizationId] = erpList = [];
        foreach (var pair in row.SaopValues)
        {
          list.Add((row.ItemId, pair.Key, pair.Value));
          erpList.Add(new(productId, pair.Key, pair.Value));
        }
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
    // Slike in dokumenti: po podjetjih, v paketih po BulkProducts izdelkov.
    var mediaAdded = 0; var mediaRemoved = 0;
    foreach (var (organizationId, edits) in mediaByOrganization)
      foreach (var chunk in edits.GroupBy(item => item.ProductId).Chunk(BulkProducts))
      {
        progress?.Report("Zapisujem slike in dokumente …");
        try
        {
          var outcome = await edit.SaveMediaBulkAsync(organizationId, chunk.SelectMany(group => group).ToList(), actor, note, cancellationToken);
          mediaAdded += (int)outcome.AddedCount;
          mediaRemoved += (int)outcome.RemovedCount;
          foreach (var skip in outcome.Skipped) problems.Add($"{Describe(skip.ProductId)}: slike in dokumenti niso zapisani — {skip.Reason}");
        }
        catch (Exception failure)
        {
          problems.Add($"Slike in dokumenti za {chunk.Length:N0} izdelkov (podjetje {organizationId}) niso zapisani — {failure.Message}");
        }
      }
    pimChanges += mediaAdded + mediaRemoved;

    touchedRows.UnionWith(bulkRows);
    var touched = touchedRows.Count;
    progress?.Report("Uvrščam ERP polja v vrsto za SAOP …");

    // Najprej vrsta, potem katalog: vrsta vrednosti ne primerja s katalogom, zato vrstni red na
    // izid ne vpliva, a če zapis v katalog pade, sprememba za SAOP ni izgubljena.
    var batches = new List<long>();
    var queued = 0; var duplicates = 0; var rejected = 0;
    foreach (var (organizationId, changes) in saopByOrganization)
    {
      try
      {
        var outcome = await saop.EnqueueAsync(organizationId, changes, actor, "EXCEL",
          note ?? "Delovni list izdelkov", cancellationToken);
        batches.Add(outcome.OutboundBatchId);
        queued += outcome.Queued; duplicates += outcome.Duplicates; rejected += outcome.Rejected;        foreach (var line in outcome.Rows.Where(line => line.Status == "Rejected"))
          problems.Add($"Artikel {line.ItemId}, polje {line.FieldKey}: ni uvrščeno v vrsto za SAOP — {line.Reason}");
      }
      catch (Exception failure) { problems.Add($"ERP spremembe podjetja {organizationId} niso uvrščene v vrsto za SAOP — {failure.Message}"); }
    }

    // 245: ERP vrednost gre v katalog PIM takoj, ne šele ko jo zajem prinese nazaj iz SAOP.
    progress?.Report("Zapisujem ERP polja v PIM …");
    var erpWritten = 0;
    foreach (var (organizationId, edits) in erpByOrganization)
      foreach (var chunk in edits.GroupBy(item => item.ProductId).Chunk(BulkProducts))
      {
        try
        {
          var outcome = await edit.SaveErpFieldsBulkAsync(organizationId, chunk.SelectMany(group => group).ToList(), actor, note, cancellationToken);
          erpWritten += (int)outcome.ChangedCount;
          foreach (var skip in outcome.Skipped)
            problems.Add($"{Describe(skip.ProductId)}, polje {skip.FieldKey}: ni zapisano v PIM — {skip.Reason}");
        }
        catch (Exception failure)
        {
          problems.Add($"ERP polja za {chunk.Length:N0} izdelkov (podjetje {organizationId}) niso zapisana v PIM — {failure.Message}");
        }
      }
    pimChanges += erpWritten;

    // 274: S-popust (privzeta koda in posebni S po tipu/stranki na izdelku).
    progress?.Report("Zapisujem S-popuste …");
    var packagingWritten = await ApplyPackagingAsync(known, actor, note, problems, cancellationToken);
    pimChanges += packagingWritten;
    foreach (var row in known.Where(row => row.PimValues.Keys.Any(ProductWorkbookContract.IsPackagingField)))
      touchedRows.Add(row.RowNumber);

    // 302: oznake artikla (Pakirno naročanje, Razstavni eksponat).
    progress?.Report("Zapisujem oznake …");
    pimChanges += await ApplyFlagsAsync(known, actor, note, problems, cancellationToken);
    foreach (var row in known.Where(row => row.PimValues.Keys.Any(ProductWorkbookContract.IsFlagField)))
      touchedRows.Add(row.RowNumber);
    touched = touchedRows.Count;

    return new(touched, pimChanges, queued, duplicates, rejected, batches, problems,
      erpWritten, mediaAdded, mediaRemoved, createdAttributes);
  }

  /* ─── S-popust na polno pakiranje (274) ────────────────────────────────────────────── */

  /// <summary>
  /// Celica S v enotni obliki: S koda z velikimi črkami; seznam »LEVO\S2 | …« razvrščen, tip
  /// stranke kot koda šifranta (sprejme tudi ime, npr. INŠTALATER). »-« ostane »-« (izprazni).
  /// Null z razlogom v <paramref name="error"/>, kadar celica ni veljavna.
  /// </summary>
  static string? NormalizePackagingCell(string fieldKey, string value, IReadOnlySet<string> codes,
    IReadOnlyList<CustomerTypeRow> types, out string? error)
  {
    error = null;
    if (value == ProductWorkbookContract.ClearToken) return value;
    if (fieldKey == ProductWorkbookContract.PackagingCodeField)
    {
      var code = value.Trim().ToUpperInvariant();
      if (codes.Contains(code)) return code;
      error = $"neznana S koda; dovoljene so {string.Join(", ", codes.Order())} ali »-«";
      return null;
    }

    var pairs = PackagingDiscountService.ParsePairs(value, out var parseError);
    if (parseError is not null) { error = parseError; return null; }
    var result = new List<string>();
    foreach (var (left, code) in pairs)
    {
      if (!codes.Contains(code)) { error = $"neznana S koda {code}"; return null; }
      var target = left;
      if (fieldKey == ProductWorkbookContract.TypeSpecialsField)
      {
        var type = types.FirstOrDefault(row => string.Equals(row.CustomerTypeCode, left, StringComparison.OrdinalIgnoreCase)
          || WorkbookHeader.Same(row.Name, left));
        if (type is null) { error = $"tipa stranke »{left}« ni v šifrantu"; return null; }
        target = type.CustomerTypeCode;
      }
      result.Add(target + "\\" + code.ToUpperInvariant());
    }
    return SortPairs(string.Join(" | ", result)) ?? ProductWorkbookContract.ClearToken;
  }

  /// <summary>»B\S2 | A\S3« → »A\S3 | B\S2«; prazno ostane null.</summary>
  static string? SortPairs(string? text)
  {
    if (string.IsNullOrWhiteSpace(text)) return null;
    var items = text.Split('|', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
      .OrderBy(item => item, StringComparer.OrdinalIgnoreCase).ToArray();
    return items.Length == 0 ? null : string.Join(" | ", items);
  }

  /// <summary>
  /// VPAK iz cenika proti PAK2 v PIM. PAK2 je podatek SAOP (ItemQuantityOfPackaging2) in ga uvoz S
  /// ne prepiše — razlika se samo pove, da jo nekdo popravi v SAOP. Pove tudi, kje S nima učinka,
  /// ker izdelek nima PAK2 (Magento pravilo: količina ≥ PAK2).
  /// </summary>
  async Task ComparePackagingQuantitiesAsync(List<ProductWorkbookRowChange> rows,
    Dictionary<(int, string), string> vpakByItem, List<string> problems, CancellationToken cancellationToken)
  {
    var withCode = rows.Where(row => row.PimValues.TryGetValue(ProductWorkbookContract.PackagingCodeField, out var code)
      && code != ProductWorkbookContract.ClearToken).Select(row => (row.OrganizationId, row.ItemId));
    var items = vpakByItem.Keys.Concat(withCode).Distinct().ToList();
    if (items.Count == 0) return;

    var pak2 = new Dictionary<(int, string), decimal?>();
    foreach (var organization in items.GroupBy(item => item.Item1))
    {
      var ids = await ResolveProductIdsAsync(organization.Key, organization.Select(item => item.Item2).ToList(), cancellationToken);
      var sheet = await packaging.GetSheetAsync(ids.Values.Select(id => id.ProductId).ToList(), cancellationToken);
      foreach (var (itemId, key) in ids)
        pak2[(organization.Key, itemId.ToUpperInvariant())] = sheet.TryGetValue(key.ProductId, out var state) ? state.Pak2 : null;
    }

    var differences = new List<string>();
    foreach (var ((organizationId, itemId), text) in vpakByItem)
    {
      if (Number(text) is not { } number || !pak2.TryGetValue((organizationId, itemId.ToUpperInvariant()), out var stored)) continue;
      var vpak = decimal.Parse(number, CultureInfo.InvariantCulture);
      if (stored != vpak) differences.Add($"{itemId}: VPAK {vpak:0.##}, PAK2 v PIM {(stored is { } value ? value.ToString("0.##", CultureInfo.InvariantCulture) : "prazen")}");
    }
    if (differences.Count > 0)
      problems.Add($"VPAK iz datoteke se pri {differences.Count:N0} artiklih razlikuje od PAK2 v PIM (PAK2 je podatek SAOP — »Količina v pakiranju 2«; uvoz S ga ne spremeni, popravi ga v SAOP ali v stolpcu ERP): "
        + string.Join("; ", differences.Take(40)) + (differences.Count > 40 ? $" … in še {differences.Count - 40}." : "."));

    var noPak2 = rows.Where(row => row.PimValues.TryGetValue(ProductWorkbookContract.PackagingCodeField, out var code)
        && code != ProductWorkbookContract.ClearToken
        && pak2.TryGetValue((row.OrganizationId, row.ItemId.ToUpperInvariant()), out var stored) && stored is null or <= 0)
      .Select(row => row.ItemId).ToList();
    if (noPak2.Count > 0)
      problems.Add($"S koda se zapiše, a pri {noPak2.Count:N0} artiklih nima učinka, ker nimajo PAK2 (količina polnega pakiranja): "
        + string.Join(", ", noPak2.Take(40)) + (noPak2.Count > 40 ? $" … in še {noPak2.Count - 40}." : "."));
  }

  /// <summary>
  /// Zapis S-popustov iz delovnega lista. Privzeta koda gre v en množični zapis na podjetje
  /// (pim.SaveProductPackagingDiscountsBulk, zgodovina v pim.ProductFieldHistory). Posebni S je
  /// celoten seznam za ta izdelek: kar je v celici, se zapiše (b2b.SavePackagingDiscountRule), kar
  /// v celici ni več, se umakne; pravila po rabatni skupini ali za vse izdelke celica ne vidi.
  /// </summary>
  async Task<int> ApplyPackagingAsync(IReadOnlyList<ProductWorkbookRowChange> rows, string actor, string? note,
    List<string> problems, CancellationToken cancellationToken)
  {
    var written = 0;
    foreach (var organization in rows.GroupBy(row => row.OrganizationId))
    {
      var defaults = organization
        .Where(row => row.PimValues.ContainsKey(ProductWorkbookContract.PackagingCodeField))
        .Select(row => (row.ItemId, Code: row.PimValues[ProductWorkbookContract.PackagingCodeField] is var code && code == ProductWorkbookContract.ClearToken ? null : code))
        .ToList();
      if (defaults.Count > 0)
      {
        try
        {
          var outcome = await packaging.SaveDefaultsBulkAsync(organization.Key, defaults, actor, note, "EXCEL", cancellationToken);
          written += outcome.Changed;
          foreach (var (itemId, reason) in outcome.Skipped) problems.Add($"Artikel {itemId}: S koda ni zapisana — {reason}");
        }
        catch (SqlException failure) { problems.Add($"S kode podjetja {organization.Key} niso zapisane — {failure.Message}"); }
      }

      var specialRows = organization.Where(row => row.PimValues.ContainsKey(ProductWorkbookContract.TypeSpecialsField)
        || row.PimValues.ContainsKey(ProductWorkbookContract.CustomerSpecialsField)).ToList();
      if (specialRows.Count == 0) continue;

      var existing = (await packaging.GetRulesAsync(organization.Key, cancellationToken: cancellationToken))
        .Where(rule => rule.ScopeKind == PackagingDiscountService.ScopeItem && rule.ItemId is not null)
        .ToList();
      await using var connection = await packaging.OpenAsync(cancellationToken);
      foreach (var row in specialRows)
        foreach (var (field, kind) in new[]
        {
          (ProductWorkbookContract.TypeSpecialsField, PackagingDiscountService.TargetType),
          (ProductWorkbookContract.CustomerSpecialsField, PackagingDiscountService.TargetCustomer),
        })
        {
          if (!row.PimValues.TryGetValue(field, out var cell)) continue;
          var wanted = cell == ProductWorkbookContract.ClearToken ? [] : PackagingDiscountService.ParsePairs(cell, out _);
          var current = existing.Where(rule => rule.TargetKind == kind
            && string.Equals(rule.ItemId, row.ItemId, StringComparison.OrdinalIgnoreCase)).ToList();
          foreach (var (target, code) in wanted)
          {
            if (current.Any(rule => string.Equals(rule.TargetCode, target, StringComparison.OrdinalIgnoreCase)
              && string.Equals(rule.DiscountCode, code, StringComparison.OrdinalIgnoreCase))) continue;
            try
            {
              await packaging.SaveRuleAsync(organization.Key, new(kind,
                kind == PackagingDiscountService.TargetType ? target : null, null,
                kind == PackagingDiscountService.TargetCustomer ? target : null,
                PackagingDiscountService.ScopeItem, row.ItemId, null, null, code, Note: note), actor, cancellationToken, connection);
              written++;
            }
            catch (SqlException failure) { problems.Add($"Vrstica {row.RowNumber} (artikel {row.ItemId}): posebni S {target}\\{code} ni zapisan — {failure.Message}"); }
          }
          foreach (var rule in current.Where(rule => !wanted.Any(pair => string.Equals(pair.Left, rule.TargetCode, StringComparison.OrdinalIgnoreCase))))
          {
            try
            {
              await packaging.RemoveRuleAsync(organization.Key, rule.RuleId, actor, cancellationToken, connection);
              written++;
            }
            catch (SqlException failure) { problems.Add($"Vrstica {row.RowNumber} (artikel {row.ItemId}): posebni S {rule.TargetCode} ni umaknjen — {failure.Message}"); }
          }
        }
    }
    return written;
  }

  /// <summary>
  /// Postavi kategorije in kljukice spletišč ene vrstice.
  ///
  /// Stolpec »Spletne strani« je kljukica spletišča na kartici (<c>pim.ProductWebShop</c>, po
  /// drevesu kategorij) — isto, kar bere katalog.csv. Do zdaj je bil ukaz nad kategorijami: uvoz je
  /// kategorije postavil, kljukice pa ne, zato izdelek na kartici ni bil označen in na splet ni šel.
  /// Kategorije pridejo samo iz stolpcev »Kategorije — …« in se zapišejo najprej, ker procedura
  /// kljukice brez kategorije na tem spletišču ne sprejme (251).
  /// </summary>
  async Task<int> ApplySitesAsync(
    ProductWorkbookRowChange row, long productId, WorkbookData current,
    IReadOnlyDictionary<string, string> shopByToken, IReadOnlyList<WorkbookWebSite> sites,
    IReadOnlyDictionary<string, SiteCategoryPaths> validCategoryPaths,
    string actor, string? note, List<string> problems, CancellationToken cancellationToken)
  {
    var written = await ApplyCategoriesAsync(row, productId, current, sites, validCategoryPaths, actor, note, problems, cancellationToken);

    if (!row.PimValues.TryGetValue(ProductWorkbookContract.WebSitesField, out var shopCell)) return written;
    var listed = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    foreach (var token in ProductWorkbookContract.SplitList(Cleared(shopCell)))
    {
      if (shopByToken.TryGetValue(WorkbookHeader.Normalize(token), out var tree)) listed.Add(tree);
      else problems.Add($"Vrstica {row.RowNumber}: spletne strani »{token}« ni v registru; prezrta. Na voljo: {string.Join(", ", PrimarySiteByTree(sites).Values.Select(site => site.Name))}.");
    }

    var published = current.ShopsOf(productId);
    var changes = PrimarySiteByTree(sites).Keys
      .Where(tree => listed.Contains(tree) != published.Contains(tree, StringComparer.OrdinalIgnoreCase))
      .Select(tree => (tree, listed.Contains(tree)))
      .ToList();
    if (changes.Count == 0) return written;

    try
    {
      var outcome = await edit.SaveWebShopsAsync(row.OrganizationId, productId, changes, actor, note, cancellationToken);
      written += changes.Count - outcome.Rejected.Count;
      foreach (var rejection in outcome.Rejected)
        problems.Add($"Vrstica {row.RowNumber}: kljukica za »{rejection.ShopLabel}« ni postavljena — {rejection.ReasonText}.");
    }
    catch (Exception failure)
    {
      problems.Add($"Vrstica {row.RowNumber}: spletne strani niso zapisane — {failure.Message}");
    }
    return written;
  }

  /// <summary>
  /// Kategorije ene vrstice iz stolpcev »Kategorije — …«. Jezikovna različica strani brez svoje
  /// celice sledi primarni strani istega drevesa (drugi obhod spodaj).
  /// </summary>
  async Task<int> ApplyCategoriesAsync(
    ProductWorkbookRowChange row, long productId, WorkbookData current, IReadOnlyList<WorkbookWebSite> sites,
    IReadOnlyDictionary<string, SiteCategoryPaths> validCategoryPaths,
    string actor, string? note, List<string> problems, CancellationToken cancellationToken)
  {
    var written = 0;

    // Kategorije, ki jih vrstica prinasa, po kodi strani; »-« (cleared) stran izprazni.
    var cleared = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    var incoming = new Dictionary<string, IReadOnlyList<string>>(StringComparer.OrdinalIgnoreCase);
    foreach (var pair in row.PimValues)
    {
      if (!pair.Key.StartsWith(ProductWorkbookContract.CategoryFieldPrefix, StringComparison.Ordinal)) continue;
      incoming[pair.Key[ProductWorkbookContract.CategoryFieldPrefix.Length..]] = ProductWorkbookContract.SplitList(Cleared(pair.Value));
      if (pair.Value == ProductWorkbookContract.ClearToken) cleared.Add(pair.Key[ProductWorkbookContract.CategoryFieldPrefix.Length..]);
    }

    // Jezikovne različice strani iz stolpca kategorij pridejo v poštev za sledenje (drugi obhod
    // spodaj) — brez tega bi prvi uvoz izdelek postavil samo na slovensko stran, naslednji uvoz
    // iste, nespremenjene datoteke pa še na angleško.
    var affected = new HashSet<string>(incoming.Keys, StringComparer.OrdinalIgnoreCase);
    foreach (var site in incoming.Keys.ToList())
    {
      var tree = sites.FirstOrDefault(candidate => string.Equals(candidate.Code, site, StringComparison.OrdinalIgnoreCase))?.CategoryTreeCode;
      foreach (var sibling in sites.Where(candidate => tree is not null && candidate.CategoryTreeCode == tree))
        affected.Add(sibling.Code);
    }

    // Prvi obhod: cilj za vsako stran, ki ga vrstica ali dosedanje stanje določa samo.
    var targets = new Dictionary<string, IReadOnlyList<string>>(StringComparer.OrdinalIgnoreCase);
    var withoutCategory = new List<string>();
    // Izpraznjena stran izprazni tudi svojo jezikovno različico brez lastne celice — sicer bi ta
    // ostala v kategoriji, ki je na slovenski strani ni več.
    var clearedTrees = cleared.Select(site => sites.FirstOrDefault(candidate =>
      string.Equals(candidate.Code, site, StringComparison.OrdinalIgnoreCase))?.CategoryTreeCode).OfType<string>().ToHashSet();
    foreach (var site in affected)
    {
      var siteTree = sites.FirstOrDefault(candidate => string.Equals(candidate.Code, site, StringComparison.OrdinalIgnoreCase))?.CategoryTreeCode;
      if (cleared.Contains(site) || (!incoming.ContainsKey(site) && siteTree is not null && clearedTrees.Contains(siteTree)))
      {
        targets[site] = [];
        continue;
      }
      if (incoming.TryGetValue(site, out var given) && given.Count > 0)
      {
        // Preverimo tu, ne šele v bazi: uporabnik izve TOČNO katera pot(i) v celici ne obstajajo
        // — vse naenkrat, ne le prva (pim.SetProductCategories, THROW 106007, vrne vedno samo
        // eno). Brez znanega drevesa (stran med uvozom izgine, siteCodes prazen) se preskoči in
        // odloci baza, tako kot doslej.
        var unknownPaths = validCategoryPaths.TryGetValue(site, out var valid)
          ? given.Where(path => !valid.Paths.Contains(path)).ToList()
          : [];
        if (unknownPaths.Count > 0)
        {
          foreach (var path in unknownPaths)
            problems.Add($"Vrstica {row.RowNumber}: kategorija »{path}« za stran »{SiteName(sites, site)}« "
              + "ne obstaja v drevesu te strani — preveri zapis (ločilo » > «, presledki) ali izberi obstoječo "
              + "pot na /kategorije/preslikave; stran ostane pri prejšnjih kategorijah.");
          continue;
        }
        targets[site] = given;
        continue;
      }
      withoutCategory.Add(site);
    }

    // Drugi obhod (245): jezikovna različica brez svoje celice (Videlektro (ANG), prazen stolpec)
    // sledi drugi strani istega drevesa — ista koda kategorije, pot v jeziku te strani:
    //   - nima nobene kategorije: dobi kategorijo druge strani. Prej je vsaka vrstica
    //     Objemke.xlsx dobila opozorilo »nima kategorije« in izdelek na angleško stran ni šel,
    //     čeprav je kategorija v obeh jezikih ista;
    //   - ima kategorijo, ki je bila do zdaj ista kot na drugi strani: gre z njo na novo. Brez
    //     tega bi sprememba slovenske kategorije angleško pustila v stari;
    //   - ima drugačno kategorijo kot druga stran: ostane, ker jo je nekdo tako postavil namenoma.
    foreach (var site in withoutCategory)
    {
      var existing = current.Categories.TryGetValue((productId, site), out var paths)
        ? ProductWorkbookContract.SplitList(paths) : [];
      if (FollowSibling(site, existing, productId, incoming, targets, current, sites, validCategoryPaths) is { } followed)
      {
        targets[site] = followed;
        continue;
      }
      if (existing.Count > 0) { targets[site] = existing; continue; }
      problems.Add($"Vrstica {row.RowNumber}: stran »{SiteName(sites, site)}« nima kategorije — izdelek nanjo ne gre. Izpolni stolpec »Kategorije — {SiteName(sites, site)}«.");
    }

    foreach (var (site, target) in targets)
    {
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

  /// <summary>
  /// Zapisi atributa iz ene celice (277). Atribut brez jezikovnih vrstic: ena vrednost za vse, kot doslej.
  /// Prevedljiv atribut (vrstica na jezik) ima v izvozu vse jezike v eni celici, ločene z »|«. Del,
  /// ki je enak shranjeni vrednosti jezika, ostane pri tem jeziku; ostali deli gredo po vrsti v
  /// jezike, katerih vrednosti v celici ni več — najprej slovenščina. Ena sama nova vrednost zato
  /// spremeni slovensko in pusti angleško. Prej je ena vrednost povozila vse jezike.
  /// </summary>
  static IEnumerable<ProductAttributeBulkEdit> AttributeEdits(
    long productId, string code, string value,
    IReadOnlyDictionary<(long ProductId, string Code), List<(string Language, string Value)>> languages,
    ProductWorkbookRowChange row, List<string> problems)
  {
    if (value.Length == 0 || !languages.TryGetValue((productId, code), out var stored) || stored.Count == 0)
      return [new(productId, code, value)];

    var parts = ProductWorkbookContract.SplitList(value).ToList();
    // Vsi jeziki z isto vrednostjo (»LED | LED«) se v celici pokažejo enkrat: ena vrednost gre v vse.
    if (parts.Count == 1 && stored.Select(item => item.Value).Distinct(StringComparer.Ordinal).Count() == 1)
      return stored[0].Value == parts[0] ? [] : stored.Select(item => new ProductAttributeBulkEdit(productId, code, parts[0], item.Language));
    var open = new List<string>();
    foreach (var (language, current) in stored)
    {
      var at = parts.FindIndex(part => string.Equals(part, current, StringComparison.Ordinal));
      if (at >= 0) parts.RemoveAt(at); else open.Add(language);
    }
    var edits = new List<ProductAttributeBulkEdit>();
    for (var index = 0; index < parts.Count && index < open.Count; index++)
      edits.Add(new(productId, code, parts[index], open[index]));
    if (parts.Count > open.Count)
      problems.Add($"Vrstica {row.RowNumber} (artikel {row.ItemId}): atribut »{code}« ima več vrednosti, kot je jezikov "
        + $"({string.Join(", ", stored.Select(item => item.Language))}); odvečne niso zapisane: {string.Join(" | ", parts.Skip(open.Count))}.");
    return edits;
  }

  /// <summary>Vrednosti prevedljivih atributov po jezikih, slovenščina prva (277).</summary>
  async Task<Dictionary<(long ProductId, string Code), List<(string Language, string Value)>>> ReadAttributeLanguagesAsync(
    IReadOnlyList<long> productIds, CancellationToken cancellationToken)
  {
    var result = new Dictionary<(long, string), List<(string, string)>>();
    if (productIds.Count == 0) return result;
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("""
      SELECT attributeValue.ProductId, attributeValue.AttributeCode, attributeValue.LanguageCode, attributeValue.Value
      FROM canon.ProductAttribute AS attributeValue
      WHERE attributeValue.LanguageCode IS NOT NULL
        AND attributeValue.ProductId IN (SELECT CONVERT(bigint, value) FROM OPENJSON(@ProductIdsJson))
      ORDER BY attributeValue.ProductId, attributeValue.AttributeCode,
        CASE attributeValue.LanguageCode WHEN N'sl' THEN 0 WHEN N'en' THEN 1 ELSE 2 END, attributeValue.LanguageCode;
      """, connection) { CommandTimeout = 120 };
    command.Parameters.Add("@ProductIdsJson", SqlDbType.NVarChar, -1).Value = JsonSerializer.Serialize(productIds);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    while (await reader.ReadAsync(cancellationToken))
    {
      var key = (PimDb.Int64(reader, "ProductId"), PimDb.TextOrEmpty(reader, "AttributeCode"));
      if (!result.TryGetValue(key, out var list)) result[key] = list = [];
      list.Add((PimDb.TextOrEmpty(reader, "LanguageCode"), PimDb.TextOrEmpty(reader, "Value")));
    }
    return result;
  }

  /// <summary>»-« v celici pomeni »izprazni«: zapis dobi prazno vrednost oziroma prazen seznam.</summary>
  static string Cleared(string value) => value == ProductWorkbookContract.ClearToken ? "" : value;

  static string SiteName(IReadOnlyList<WorkbookWebSite> sites, string code) =>
    sites.FirstOrDefault(site => string.Equals(site.Code, code, StringComparison.OrdinalIgnoreCase))?.Name ?? code;

  /// <summary>
  /// Kategorije, ki jih jezikovna različica brez svoje celice prevzame od druge strani istega
  /// drevesa (pravila glej v ApplySitesAsync). Null pomeni »ne sledi« — stran ostane, kot je,
  /// ali dobi opozorilo, kadar kategorije nima.
  /// </summary>
  static IReadOnlyList<string>? FollowSibling(
    string site, IReadOnlyList<string> existing, long productId,
    IReadOnlyDictionary<string, IReadOnlyList<string>> incoming, IReadOnlyDictionary<string, IReadOnlyList<string>> targets,
    WorkbookData current, IReadOnlyList<WorkbookWebSite> sites, IReadOnlyDictionary<string, SiteCategoryPaths> paths)
  {
    var tree = sites.FirstOrDefault(candidate => string.Equals(candidate.Code, site, StringComparison.OrdinalIgnoreCase))?.CategoryTreeCode;
    if (tree is null) return null;
    // Najprej strani s celico v tej vrstici (sprememba), nato tiste, ki ostanejo pri svojem.
    var siblings = sites
      .Where(candidate => candidate.CategoryTreeCode == tree && !string.Equals(candidate.Code, site, StringComparison.OrdinalIgnoreCase))
      .OrderByDescending(candidate => incoming.ContainsKey(candidate.Code));
    foreach (var sibling in siblings)
    {
      if (!targets.TryGetValue(sibling.Code, out var chosen) || chosen.Count == 0) continue;
      if (Translate(chosen, sibling.Code, site, paths) is not { } translated) continue;
      if (existing.Count == 0) return translated;
      if (!incoming.ContainsKey(sibling.Code)) continue;
      var siblingBefore = current.Categories.TryGetValue((productId, sibling.Code), out var stored)
        ? ProductWorkbookContract.SplitList(stored) : [];
      if (Translate(siblingBefore, sibling.Code, site, paths) is { } before && SameList(before, existing))
        return translated;
    }
    return null;
  }

  /// <summary>Poti ene strani v jezik druge strani istega drevesa (pot → koda kategorije → pot);
  /// null, kadar se katera ne prevede — takrat ne ugibamo.</summary>
  static IReadOnlyList<string>? Translate(
    IReadOnlyList<string> categoryPaths, string fromSite, string toSite, IReadOnlyDictionary<string, SiteCategoryPaths> paths)
  {
    if (categoryPaths.Count == 0 || !paths.TryGetValue(fromSite, out var from) || !paths.TryGetValue(toSite, out var to)) return null;
    var translated = new List<string>(categoryPaths.Count);
    foreach (var path in categoryPaths)
    {
      if (!from.CodeByPath.TryGetValue(path, out var code) || !to.PathByCode.TryGetValue(code, out var mine)) return null;
      translated.Add(mine);
    }
    return translated;
  }

  /// <summary>
  /// Vpis v celici »Spletne strani« → spletišče (koda drevesa, <c>pim.ProductWebShop.WebShopCode</c>).
  /// Sprejeto je ime ali koda katerekoli strani drevesa in koda drevesa, brez razlike v velikih
  /// črkah: »Videlektro«, »videlektro« in »Videlektro (ANG)« so vsi isto spletišče. Velja tudi
  /// kratko ime brez končnice (».si«, »_si«, »(ANG)«): uporabnik piše »svetila«, ne »Svetila.si«.
  /// </summary>
  static IReadOnlyDictionary<string, string> ShopLookup(IReadOnlyList<WorkbookWebSite> sites)
  {
    var lookup = new Dictionary<string, string>(StringComparer.Ordinal);
    foreach (var site in sites)
      foreach (var name in new[] { site.CategoryTreeCode, site.Code, site.Name })
      {
        var normalized = WorkbookHeader.Normalize(name);
        lookup.TryAdd(normalized, site.CategoryTreeCode);
        var cut = normalized.IndexOfAny(['.', '_', '(']);
        if (cut > 0) lookup.TryAdd(normalized[..cut], site.CategoryTreeCode);
      }
    return lookup;
  }

  /* ─── Registri in branje ──────────────────────────────────────────────────────────── */

  /// <summary>Aktivne oznake artikla iz registra (233/302) — vsaka dobi stolpec D/N v delovnem listu.</summary>
  async Task<IReadOnlyList<WorkbookFlag>> FlagDefinitionsAsync(CancellationToken cancellationToken)
  {
    var flags = new List<WorkbookFlag>();
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand(
      "SELECT FlagCode, DisplayName FROM pim.ProductFlagDefinition WHERE IsActive = 1 ORDER BY SortOrder, FlagCode;", connection);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    while (await reader.ReadAsync(cancellationToken))
      flags.Add(new(PimDb.TextOrEmpty(reader, "FlagCode"), PimDb.TextOrEmpty(reader, "DisplayName")));
    return flags;
  }

  /// <summary>Oznake artikla za izvoz in primerjavo pri uvozu: »1« ali »0«; artikel brez vrstice ima »0«.</summary>
  async Task ReadFlagsAsync(IReadOnlyList<long> productIds, IReadOnlyList<string> fieldCodes,
    Dictionary<(long, string), string?> values, CancellationToken cancellationToken)
  {
    var codes = fieldCodes.Where(ProductWorkbookContract.IsFlagField).Select(ProductWorkbookContract.FlagCode)
      .Distinct(StringComparer.Ordinal).ToList();
    if (codes.Count == 0) return;
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("""
      SELECT product.ProductId, code.FlagCode, Value = CONVERT(nvarchar(1), ISNULL(CONVERT(int, flag.IsSet), 0))
      FROM canon.Product AS product
      CROSS JOIN (SELECT FlagCode = CONVERT(nvarchar(50), value) FROM OPENJSON(@CodesJson)) AS code
      LEFT JOIN pim.ProductFlag AS flag ON flag.ProductId = product.ProductId AND flag.FlagCode = code.FlagCode
      WHERE product.ProductId IN (SELECT CONVERT(bigint, value) FROM OPENJSON(@ProductIdsJson));
      """, connection) { CommandTimeout = 120 };
    command.Parameters.Add("@CodesJson", SqlDbType.NVarChar, -1).Value = JsonSerializer.Serialize(codes);
    command.Parameters.Add("@ProductIdsJson", SqlDbType.NVarChar, -1).Value = JsonSerializer.Serialize(productIds);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    while (await reader.ReadAsync(cancellationToken))
      values[(PimDb.Int64(reader, "ProductId"), ProductWorkbookContract.FlagFieldPrefix + PimDb.TextOrEmpty(reader, "FlagCode"))] =
        PimDb.Text(reader, "Value");
  }

  /// <summary>
  /// Zapis oznak iz delovnega lista (302): ena oznaka za več artiklov podjetja naenkrat
  /// (pim.SetProductFlagsBulk, zgodovina v pim.ProductFieldHistory). »-« pomeni »ne«.
  /// </summary>
  async Task<int> ApplyFlagsAsync(IReadOnlyList<ProductWorkbookRowChange> rows, string actor, string? note,
    List<string> problems, CancellationToken cancellationToken)
  {
    var written = 0;
    var byFlag = rows
      .SelectMany(row => row.PimValues.Where(pair => ProductWorkbookContract.IsFlagField(pair.Key))
        .Select(pair => (row.OrganizationId, row.ItemId, Flag: ProductWorkbookContract.FlagCode(pair.Key), IsSet: pair.Value == "1")))
      .GroupBy(item => (item.OrganizationId, item.Flag));
    foreach (var group in byFlag)
    {
      try
      {
        var outcome = await edit.SaveProductFlagsBulkAsync(group.Key.OrganizationId, group.Key.Flag,
          group.Select(item => (item.ItemId, item.IsSet)).ToList(), actor, "EXCEL", note, cancellationToken);
        written += outcome.ChangedCount;
        if (outcome.UnknownItems is { Length: > 0 } unknown)
          problems.Add($"Oznaka {group.Key.Flag}: artiklov {unknown} v podjetju {group.Key.OrganizationId} ni.");
        if (outcome.Held > 0)
          problems.Add($"Pakirno naročanje brez Pakiranja 2 (večjega od 1): {outcome.Held:N0} artiklov je zadržanih s spleta, dokler Pakiranje 2 ni vpisano.");
      }
      catch (Exception failure)
      {
        problems.Add($"Oznaka {group.Key.Flag} za {group.Count():N0} artiklov (podjetje {group.Key.OrganizationId}) ni zapisana — {failure.Message}");
      }
    }
    return written;
  }

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
  /// <param name="Paths">Veljavne poti strani (za preverjanje celice).</param>
  /// <param name="CodeByPath">Pot → koda kategorije; <paramref name="PathByCode"/> obratno. Z njima se
  /// kategorija prevede med jezikovnima različicama iste strani (SiblingCategories).</param>
  sealed record SiteCategoryPaths(HashSet<string> Paths, Dictionary<string, string> CodeByPath, Dictionary<string, string> PathByCode);

  async Task<IReadOnlyDictionary<string, SiteCategoryPaths>> CategoryPathsBySiteAsync(
    IReadOnlyList<string> siteCodes, CancellationToken cancellationToken)
  {
    var result = new Dictionary<string, SiteCategoryPaths>(StringComparer.OrdinalIgnoreCase);
    if (siteCodes.Count == 0) return result;

    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("""
      SELECT site.WebSiteCode, path.CategoryCode, path.CategoryPath
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
      if (!result.TryGetValue(site, out var paths))
        result[site] = paths = new(new(StringComparer.OrdinalIgnoreCase),
          new(StringComparer.OrdinalIgnoreCase), new(StringComparer.OrdinalIgnoreCase));
      var path = PimDb.TextOrEmpty(reader, "CategoryPath");
      var code = PimDb.TextOrEmpty(reader, "CategoryCode");
      paths.Paths.Add(path);
      paths.CodeByPath.TryAdd(path, code);
      paths.PathByCode.TryAdd(code, path);
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

  /// <summary>
  /// Stolpci, ki bi šli v datoteko za dani filter — brez branja izdelkov. Uporablja pojavno okno
  /// »Stolpci« na /izdelki (glej Products.razor), da uporabnik izbira posamezna polja in ne le
  /// skupine: seznam je odvisen od konteksta (kategorija doloca nabor atributov, podjetje jezike),
  /// zato ga mora prebrati stran, ne trdo kodirati. Ista pravila kot v BuildToAsync (register brez
  /// seznama izdelkov, nabor atributov po kategoriji), da se pojavno okno in dejanski izvoz ne razideta.
  /// </summary>
  public async Task<IReadOnlyList<ProductWorkbookColumn>> DescribeColumnsAsync(
    ProductListFilter filter, CancellationToken cancellationToken = default)
  {
    var sites = await ActiveWebSitesAsync(cancellationToken);
    var saopFields = await WritableSaopFieldsAsync(cancellationToken);
    var flags = await FlagDefinitionsAsync(cancellationToken);
    var languages = await LanguagesAsync(filter.WithPartnerScope().OrganizationId, cancellationToken);
    var registry = await ReadAsync([], [], filter.CategoryTreeCode, filter.CategoryCode, cancellationToken);
    var attributes = filter.CategoryCode is null
      ? OrderAttributes(registry.Attributes)
      : OrderAttributes(registry.Attributes).Where(attribute => attribute.InSet).ToList();
    return ProductWorkbookContract.Build(new(saopFields, sites, WebTextTypes, languages, attributes, flags));
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
    Dictionary<string, string> Required,
    Dictionary<long, List<string>> Shops)
  {
    /// <summary>Spletišča (koda drevesa), ki imajo pri izdelku kljukico — stolpec »Spletne strani«.</summary>
    public IReadOnlyList<string> ShopsOf(long productId) =>
      Shops.TryGetValue(productId, out var shops) ? shops : [];
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
      foreach (var pair in part.Shops) merged.Shops[pair.Key] = pair.Value;
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

    if (productIds.Count > 0 && fieldCodes.Contains(ReservationExclusionField, StringComparer.Ordinal))
      await ReadReservationExclusionAsync(productIds, values, cancellationToken);

    // 302: oznake artikla (pim.ProductFlag) — Pakirno naročanje, Razstavni eksponat.
    if (productIds.Count > 0)
      await ReadFlagsAsync(productIds, fieldCodes, values, cancellationToken);

    // 274: S-popust bere PackagingDiscountService (pim.ProductPackagingDiscount, b2b.PackagingDiscountRule),
    // ne canon.FieldValue; v enotni obliki, kot jo vrne NormalizePackagingCell.
    if (productIds.Count > 0 && fieldCodes.Any(ProductWorkbookContract.IsPackagingField))
      foreach (var (productId, state) in await packaging.GetSheetAsync(productIds, cancellationToken))
      {
        values[(productId, PackagingPromotedMarker)] = "1";
        values[(productId, ProductWorkbookContract.PackagingCodeField)] = state.Code;
        values[(productId, ProductWorkbookContract.TypeSpecialsField)] = SortPairs(state.Types);
        values[(productId, ProductWorkbookContract.CustomerSpecialsField)] = SortPairs(state.Customers);
      }

    var shops = productIds.Count > 0 ? await ReadWebShopsAsync(productIds, cancellationToken) : [];
    return new(values, categoryPaths, attributeValues, media, documents, attributes, required, shops);
  }

  /// <summary>
  /// Kljukice spletišč (<c>pim.ProductWebShop.IsPublished</c>). intranet.GetProductWorkbook jih ne
  /// bere; ločena poizvedba kot pri rezervaciji, da se procedura, ki jo berejo vsi izvozi, ne spremeni.
  /// </summary>
  async Task<Dictionary<long, List<string>>> ReadWebShopsAsync(
    IReadOnlyList<long> productIds, CancellationToken cancellationToken)
  {
    var shops = new Dictionary<long, List<string>>();
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("""
      SELECT shop.ProductId, shop.WebShopCode
      FROM pim.ProductWebShop AS shop
      WHERE shop.IsPublished = 1
        AND shop.ProductId IN (SELECT CONVERT(bigint, value) FROM OPENJSON(@ProductIdsJson))
      ORDER BY shop.ProductId, shop.WebShopCode;
      """, connection) { CommandTimeout = 120 };
    command.Parameters.Add("@ProductIdsJson", SqlDbType.NVarChar, -1).Value = JsonSerializer.Serialize(productIds);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    while (await reader.ReadAsync(cancellationToken))
    {
      var productId = PimDb.Int64(reader, "ProductId");
      if (!shops.TryGetValue(productId, out var list)) shops[productId] = list = [];
      list.Add(PimDb.TextOrEmpty(reader, "WebShopCode"));
    }
    return shops;
  }

  /// <summary>
  /// Kljukica »izloči iz rezervacije zaloge« (canon.ProductPlanning). intranet.GetProductWorkbook
  /// je ne bere, zato je bil stolpec »Kljukica za rezervacijo« v izvozu vedno prazen, uvoz pa je
  /// vsako izpolnjeno celico štel za spremembo. Ločena poizvedba namesto predelave te procedure
  /// (218), ki jo berejo vsi izvozi. Izdelek brez vrstice planiranja ima kljukico »ne«.
  /// </summary>
  async Task ReadReservationExclusionAsync(
    IReadOnlyList<long> productIds, Dictionary<(long, string), string?> values, CancellationToken cancellationToken)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("""
      SELECT product.ProductId, Value = CONVERT(nvarchar(1), ISNULL(planning.ExcludeQuantityReservation, 0))
      FROM canon.Product AS product
      LEFT JOIN canon.ProductPlanning AS planning ON planning.ProductId = product.ProductId
      WHERE product.ProductId IN (SELECT CONVERT(bigint, value) FROM OPENJSON(@ProductIdsJson));
      """, connection) { CommandTimeout = 120 };
    command.Parameters.Add("@ProductIdsJson", SqlDbType.NVarChar, -1).Value = JsonSerializer.Serialize(productIds);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    while (await reader.ReadAsync(cancellationToken))
      values[(PimDb.Int64(reader, "ProductId"), ReservationExclusionField)] = PimDb.Text(reader, "Value");
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

  sealed record SentEchoRow(string EntityKey, string FieldKey, string OriginalValue, string? Qualifier, DateTime SentUtc);

  /// <param name="Checked">Sporocil, za katera je bila potrditev dejansko poskusena.</param>
  /// <param name="Waiting">Sporocil, ki so bila poslana PO zadnjem uspesnem teku SAOP_PRODUCTS —
  /// se ni bilo priloznosti, da bi kanon dobil novo vrednost, zato so bila namerno preskocena.</param>
  public sealed record VerifyEchoOutcome(int Checked, int Waiting);

  /// <summary>
  /// Potrdi vsa sporocila v stanju "Sent" tega podjetja proti trenutni kanonicni vrednosti PIM
  /// (migracija 243, glej njen komentar): dokler noben klicatelj ne pokliche out.VerifyEcho, se
  /// odobreno in poslano sporocilo ne premakne nikoli naprej od "Sent" — na kartici artikla
  /// ostane trajno "caka SAOP", tudi ce je SAOP spremembo dejansko sprejel. Bere trenutne
  /// vrednosti po isti poti kot primerjava "kaj se je spremenilo" pri uvozu delovnega lista
  /// (Stored/ReadBatchedAsync), da polje-tabela preslikave ni podvojena na dveh mestih.
  ///
  /// 22.9.2026, druga napaka po prvem popravku: gumb je sporocilo, poslano pred nekaj sekundami,
  /// takoj oznacil kot "Drift", ceprav vhodna sinhronizacija (SAOP_PRODUCTS, urna) sploh se ni
  /// utegnila pognati — kanonicna vrednost v PIM je bila zato se stara, ne napacna, in
  /// out.VerifyEcho pa Drift oznaci TRAJNO (isce samo Status=Sent, torej se kasnejsi, pravilen
  /// poskus ne more vec popraviti). Zato se sporocilo preveri samo, ce je SAOP_PRODUCTS za to
  /// podjetje uspesno tekel PO tem, ko je bilo sporocilo poslano — drugace ostane "Sent" in
  /// caka na naslednji klik, ko bo kanon dejansko imel prilozica, da se ujema.
  /// </summary>
  public async Task<VerifyEchoOutcome> VerifyPendingEchoesAsync(int organizationId, CancellationToken cancellationToken = default)
  {
    var allSent = await ReadSentMessagesAsync(organizationId, cancellationToken);
    if (allSent.Count == 0) return new(0, 0);

    var lastSync = await ReadSaopProductsLastSyncAsync(organizationId, cancellationToken);
    var sent = lastSync is null ? [] : allSent.Where(row => row.SentUtc <= lastSync).ToList();
    var waiting = allSent.Count - sent.Count;
    if (sent.Count == 0) return new(0, waiting);

    var itemIds = sent.Select(row => row.EntityKey).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
    var keys = await ResolveProductIdsAsync(organizationId, itemIds, cancellationToken);
    if (keys.Count == 0) return new(0, waiting);

    var fieldCodes = sent.Select(row => row.FieldKey).Distinct(StringComparer.Ordinal).ToList();
    var productIds = sent.Where(row => keys.ContainsKey(row.EntityKey))
      .Select(row => keys[row.EntityKey].ProductId).Distinct().ToList();
    var current = await ReadBatchedAsync(productIds, fieldCodes, cancellationToken);
    var numberFields = (await WritableSaopFieldsAsync(cancellationToken))
      .Where(field => field.ValueFormat is "decimal4" or "decimal8")
      .Select(field => field.FieldKey).ToHashSet(StringComparer.Ordinal);

    var fields = new List<object>();
    foreach (var row in sent)
    {
      if (!keys.TryGetValue(row.EntityKey, out var key)) continue;
      var stored = Stored(row.FieldKey, key.ProductId, current) ?? "";
      // Hash primerja izvirno besedilo bajt-za-bajt (out.EnqueueMessage, 046) — "2,2" in "2.2000"
      // sta ista stevilka, a razlicen niz, in bi se hash nikoli ne ujel. Kadar je trenutna
      // kanonicna vrednost POMENSKO ista kot poslana (SameValue, ista logika kot pri primerjavi
      // ob uvozu delovnega lista), se za hash uporabi izvirno poslano besedilo — s tem se pravi
      // odklon (dejansko drugacna vrednost) se vedno pravilno zazna, samo drugacen zapis ne vec.
      var value = SameValue(row.OriginalValue, stored, numberFields.Contains(row.FieldKey)) ? row.OriginalValue : stored;
      fields.Add(new { entityKey = row.EntityKey, field = row.FieldKey, value, qualifier = row.Qualifier });
    }
    if (fields.Count == 0) return new(0, waiting);

    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("out.VerifyEchoBatch", connection)
    {
      CommandType = CommandType.StoredProcedure,
      CommandTimeout = 120,
    };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@EntityType", SqlDbType.NVarChar, 100).Value = "Product";
    command.Parameters.Add("@FieldsJson", SqlDbType.NVarChar, -1).Value = JsonSerializer.Serialize(fields);
    command.Parameters.Add("@ObservedUtc", SqlDbType.DateTime2).Value = DateTime.UtcNow;
    await command.ExecuteNonQueryAsync(cancellationToken);
    return new(fields.Count, waiting);
  }

  async Task<List<SentEchoRow>> ReadSentMessagesAsync(int organizationId, CancellationToken cancellationToken)
  {
    var rows = new List<SentEchoRow>();
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("""
      SELECT EntityKey, FieldSummary, JSON_VALUE(PayloadJson,'$.value') AS Vrednost, JSON_VALUE(PayloadJson,'$.qualifier') AS Qualifier, SentUtc
      FROM out.OutboxMessage
      WHERE OrganizationId = @OrganizationId AND EntityType = N'Product' AND Status = N'Sent' AND SentUtc IS NOT NULL;
      """, connection) { CommandTimeout = 60 };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    while (await reader.ReadAsync(cancellationToken))
      rows.Add(new(
        PimDb.TextOrEmpty(reader, "EntityKey"), PimDb.TextOrEmpty(reader, "FieldSummary"),
        PimDb.TextOrEmpty(reader, "Vrednost"), PimDb.Text(reader, "Qualifier"), PimDb.DateTimeValue(reader, "SentUtc")));
    return rows;
  }

  /// <summary>Zadnji USPESEN tek SAOP_PRODUCTS za to podjetje, ali null, ce se ni nikoli uspesno tekel.</summary>
  async Task<DateTime?> ReadSaopProductsLastSyncAsync(int organizationId, CancellationToken cancellationToken)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("""
      SELECT LastSuccessfulRunUtc FROM ops.IntegrationHealth
      WHERE OrganizationId = @OrganizationId AND Pipeline = N'SAOP_PRODUCTS';
      """, connection) { CommandTimeout = 30 };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    var value = await command.ExecuteScalarAsync(cancellationToken);
    return value is null or DBNull ? null : Convert.ToDateTime(value, CultureInfo.InvariantCulture);
  }

  /// <summary>
  /// Ali je vrednost iz datoteke ista kot zapisana. Primerjava ni gola primerjava nizov:
  /// Excel zapise stevilo kot 1.5, baza pa 1.5000 — brez tega bi vsak uvoz nespremenjene
  /// datoteke prijavil spremembo pri vsakem stevilcnem polju in napolnil odhodno vrsto z
  /// niclami sprememb.
  ///
  /// Po vrednosti se primerja SAMO stevilsko polje (<paramref name="numeric"/>). Prej je veljalo za
  /// vsa polja, zato »02« -> »2« ali »0000001« -> »1« v sifri (DDV, dobavitelj, skupina) uvoz ni
  /// zaznal kot spremembe.
  /// </summary>
  static bool SameValue(string incoming, string? current, bool numeric)
  {
    // Prelom vrstice se zapise enotno kot LF; zvezek ne loci CRLF od LF, baza pa ju nosi oba.
    var left = Normalize(incoming);
    var right = Normalize(current);
    if (string.Equals(left, right, StringComparison.Ordinal)) return true;
    // NumberStyles.Any dovoli locilo tisocic — InvariantCulture bi "2,2" prebral kot 22, ne 2,2.
    // Enak varen vzorec (najprej InvariantCulture, nato sl-SI) kot v SaopDocumentBuilder.Decimal.
    if (numeric && TryParseNumber(left, out var leftNumber) && TryParseNumber(right, out var rightNumber))
      return leftNumber == rightNumber;
    return false;

    static bool TryParseNumber(string value, out decimal number) =>
      decimal.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out number)
        || decimal.TryParse(value, NumberStyles.Float, CultureInfo.GetCultureInfo("sl-SI"), out number);

    // Tabulator iz vira (npr. SEARCH_NAME »Dea Amata M⇥927⇥…«) pride iz Excela nazaj kot presledek;
    // brez tega je vsak uvoz nespremenjene datoteke prijavil spremembo in jo poslal v SAOP.
    static string Normalize(string? value) =>
      (value ?? string.Empty).Replace("\r\n", "\n").Replace("\r", "\n").Replace('\t', ' ').Trim();
  }

  /// <summary>Obrezana vrednost celice; prazen niz, kadar je vrstica krajša od stolpca.</summary>
  static string Cell(IReadOnlyList<string> row, int index) => index >= 0 && index < row.Count ? row[index].Trim() : string.Empty;

  /// <summary>Število iz celice z decimalno vejico ali piko, zapisano s piko; null, kadar ni število.</summary>
  static string? Number(string cell)
  {
    var text = cell.Replace(" ", string.Empty).Replace(' '.ToString(), string.Empty).Replace(',', '.');
    return decimal.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var number)
      ? number.ToString(CultureInfo.InvariantCulture) : null;
  }

  /// <summary>Seznama sta ista, kadar vsebujeta iste vrednosti; vrstni red v celici ni pomen.</summary>
  static bool SameList(IReadOnlyList<string> left, IReadOnlyList<string> right) =>
    left.Count == right.Count
    && left.OrderBy(value => value, StringComparer.Ordinal)
        .SequenceEqual(right.OrderBy(value => value, StringComparer.Ordinal), StringComparer.Ordinal);
}
