using System.Data;
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using PIM.Operations;

namespace PIM.Intranet.Services;

/// <param name="PimValues">Spletni podatki, atributi, slike: zapišejo se takoj; ključ je kanonična koda polja.</param>
/// <param name="SaopValues">ERP polja: zapišejo se v PIM takoj in gredo v odhodno vrsto za SAOP (245).</param>
public sealed record ProductWorkbookRowChange(
  int RowNumber, int OrganizationId, string OrganizationName, string ItemId,
  IReadOnlyDictionary<string, string> PimValues,
  IReadOnlyDictionary<string, string> SaopValues);

/// <param name="UnknownColumns">Naslovi, ki jim ne ustreza noben stolpec pogodbe.</param>
/// <param name="ReadOnlyColumns">Naslovi, ki jih uvoz namenoma ne bere.</param>
/// <param name="NewAttributes">Atributi, ki jih šifrant še ne pozna, stolpec pa je pod skupino
/// atributov; uvoz jih ustvari, preden zapiše vrednosti.</param>
public sealed record ProductWorkbookPreview(
  IReadOnlyList<ProductWorkbookRowChange> Rows,
  IReadOnlyList<string> UnknownColumns,
  IReadOnlyList<string> ReadOnlyColumns,
  IReadOnlyList<string> Problems,
  IReadOnlyList<string>? NewAttributes = null)
{
  public int PimChangeCount => Rows.Sum(row => row.PimValues.Count);
  public int SaopChangeCount => Rows.Sum(row => row.SaopValues.Count);
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
  AttributeMappingService attributeDefinitions)
{
  /// <summary>Kljukica »izloči iz rezervacije zaloge« (register SAOP, element ItemExcludeQtyReservation).</summary>
  const string ReservationExclusionField = "Planning.ExcludeQtyReservation";

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
    var rows = await ListRowsAsync(filter, progress, cancellationToken);
    if (onlySelectionKeys is { Count: > 0 })
      rows = rows.Where(row => onlySelectionKeys.Contains($"{row.OrganizationId}|{row.ItemId}", StringComparer.OrdinalIgnoreCase)).ToList();
    progress?.Report(new(ProductWorkbookPhase.Writing, 0, rows.Count));

    var sites = await ActiveWebSitesAsync(cancellationToken);
    var saopFields = await WritableSaopFieldsAsync(cancellationToken);
    var languages = await LanguagesAsync(filter.WithPartnerScope().OrganizationId, cancellationToken);
    bool Included(ProductWorkbookColumn column) =>
      column.Group == ProductWorkbookContract.GroupKey
      || includeFieldKeys is null || includeFieldKeys.Contains(column.FieldKey);

    // Prvi obhod da stolpce brez atributov; iz njih izhajajo kode polj, ki jih je treba
    // prebrati. Sifrant atributov dopolni stolpce v drugem obhodu.
    var probe = ProductWorkbookContract.Build(new(saopFields, sites, WebTextTypes, languages, [])).Where(Included).ToList();
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
    IReadOnlyDictionary<string, string> siteNames, IProgress<ProductWorkbookProgress>? progress,
    [EnumeratorCancellation] CancellationToken cancellationToken)
  {
    for (var offset = 0; offset < rows.Count; offset += BatchSize)
    {
      var batch = rows.GetRange(offset, Math.Min(BatchSize, rows.Count - offset));
      var sheet = await ReadAsync(batch.Select(row => row.ProductId).ToList(), fieldCodes, null, null, cancellationToken);
      foreach (var row in batch)
        yield return definition.Select(column => Cell(column, row, sheet, siteNames)).ToArray();
      progress?.Report(new(ProductWorkbookPhase.Writing, offset + batch.Count, rows.Count));
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
      case ProductWorkbookContract.WebPublishField: return ProductWorkbookContract.SheetYesNo(row.WebPublish);
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
    var problems = new List<string>();
    var (matches, newAttributes) = await MatchAttributesAsync(
      ProductWorkbookContract.Match(sheet.Headers, definition), sheet, cancellationToken);

    var keyColumn = matches.FirstOrDefault(match => match.Column?.FieldKey == ProductWorkbookContract.ItemIdField);
    if (keyColumn is null)
      throw new WorkbookReadException("Zvezek nima stolpca s šifro artikla. Poimenuj ga »Šifra artikla« ali »ItemID«.");
    var organizationColumn = matches.FirstOrDefault(match => match.Column?.FieldKey == ProductWorkbookContract.OrganizationField);

    if (organizationColumn is null && defaultOrganizationId is null)
      problems.Add("Zvezek nima stolpca »Podjetje«, podjetje pa ni izbrano. Šifra artikla je enolična samo znotraj podjetja.");

    var rows = new List<ProductWorkbookRowChange>();
    var seen = new HashSet<(int, string)>();

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

      if (!seen.Add((organizationId.Value, itemId)))
      {
        problems.Add($"Vrstica {rowNumber}: artikel {itemId} je v zvezku večkrat; upoštevana bo prva.");
        continue;
      }

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
        if (match.Column.IsBool)
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
        else if (match.Column.IsNumber)
        {
          // Število gre naprej v zapisu s piko — tako ga razume SAOP in hrani katalog. Besedilo
          // namesto števila bi v vrsti čakalo, dokler ga graditelj dokumenta ne zavrne.
          if (Number(value) is not { } number)
          {
            problems.Add($"Vrstica {rowNumber}: »{match.Header}« = »{value}« ni število; polje se preskoči.");
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

      if (pim.Count == 0 && saopValues.Count == 0) continue;
      rows.Add(new(rowNumber, organizationId.Value, organizationName, itemId, pim, saopValues));
    }

    var unknown = matches.Where(match => match.Column is null && !string.IsNullOrWhiteSpace(match.Header))
      .Select(match => match.Header).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
    var readOnly = matches.Where(match => match.Column?.Target == ProductWorkbookTarget.ReadOnly)
      .Select(match => match.Header).Distinct(StringComparer.OrdinalIgnoreCase).ToList();

    var boolFields = matches.Where(match => match.Column?.IsBool == true)
      .Select(match => match.Column!.FieldKey).ToHashSet(StringComparer.Ordinal);
    var numberFields = matches.Where(match => match.Column?.IsNumber == true)
      .Select(match => match.Column!.FieldKey).ToHashSet(StringComparer.Ordinal);
    rows = await OnlyChangedAsync(rows, siteByToken: SiteLookup(sites), boolFields, numberFields, problems, cancellationToken);

    if (rows.Count == 0) problems.Add("V zvezku ni nobene vrstice, ki bi kaj spremenila. Kar je v datoteki, je v PIM že tako zapisano.");
    return new(rows, unknown, readOnly, problems, newAttributes);
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
  async Task<(IReadOnlyList<ProductWorkbookHeaderMatch> Matches, IReadOnlyList<string> NewAttributes)> MatchAttributesAsync(
    IReadOnlyList<ProductWorkbookHeaderMatch> matches, WorkbookSheet sheet, CancellationToken cancellationToken)
  {
    if (matches.All(match => match.Column is not null || string.IsNullOrWhiteSpace(match.Header)))
      return (matches, []);

    var known = await AttributeNamesAsync(cancellationToken);
    var used = matches.Where(match => match.Column is not null)
      .Select(match => match.Column!.FieldKey).ToHashSet(StringComparer.Ordinal);
    var result = new List<ProductWorkbookHeaderMatch>(matches.Count);
    var created = new List<string>();
    foreach (var match in matches)
    {
      if (match.Column is not null || string.IsNullOrWhiteSpace(match.Header)) { result.Add(match); continue; }
      var group = sheet.GroupOf(match.Index);
      var header = match.Header.Trim();
      string? name = known.TryGetValue(WorkbookHeader.Normalize(header), out var existing) ? existing : null;
      if (name is null && ProductWorkbookContract.IsAttributeGroup(group))
      {
        name = header;
        created.Add(header);
      }
      var column = name is null ? null : ProductWorkbookContract.AttributeColumn(group, header, name);
      // Isti atribut dvakrat (ime in koda v dveh stolpcih): drugi bi povozil prvega.
      result.Add(column is not null && used.Add(column.FieldKey) ? match with { Column = column } : match);
    }
    return (result, created.Distinct(StringComparer.OrdinalIgnoreCase).ToList());
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
    List<ProductWorkbookRowChange> rows, IReadOnlyDictionary<string, IReadOnlyList<string>> siteByToken,
    IReadOnlySet<string> boolFields, IReadOnlySet<string> numberFields, List<string> problems, CancellationToken cancellationToken)
  {
    if (rows.Count == 0) return rows;

    var keys = new Dictionary<(int, string), ProductKey>();
    foreach (var group in rows.GroupBy(row => row.OrganizationId))
      foreach (var pair in await ResolveProductIdsAsync(group.Key, group.Select(row => row.ItemId).ToList(), cancellationToken))
        keys[(group.Key, pair.Key)] = pair.Value;

    var fieldCodes = rows
      .SelectMany(row => row.PimValues.Keys.Concat(row.SaopValues.Keys))
      .Where(key => !IsListField(key))
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
        if (Changed(pair.Key, pair.Value, key, current, siteByToken, boolFields, numberFields)) pim[pair.Key] = pair.Value;

      var saopValues = new Dictionary<string, string>(StringComparer.Ordinal);
      foreach (var pair in row.SaopValues)
        if (Changed(pair.Key, pair.Value, key, current, siteByToken, boolFields, numberFields)) saopValues[pair.Key] = pair.Value;

      // Šifra, ki se razlikuje samo po vodilnih ničlah (»02« -> »2«), je sprememba — a pogosto je
      // ni naredil človek, ampak Excel, ki vpis v navadno celico spremeni v število. Uvoz je ne
      // zamolči in je ne pošlje tiho: v predogledu jo izrecno pokaže.
      foreach (var pair in pim.Concat(saopValues))
        if (!numberFields.Contains(pair.Key) && Stored(pair.Key, key.ProductId, current) is { } stored
          && OnlyLeadingZerosDiffer(pair.Value, stored))
          problems.Add($"Vrstica {row.RowNumber} (artikel {row.ItemId}): {pair.Key} »{stored.Trim()}« -> »{pair.Value}« "
            + "se razlikuje samo po vodilnih ničlah. Če jih je odrezal Excel, celico zapiši kot besedilo ('" + stored.Trim() + ").");

      if (pim.Count == 0 && saopValues.Count == 0) continue;
      result.Add(row with { PimValues = pim, SaopValues = saopValues });
    }
    return result;
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
    IReadOnlyDictionary<string, IReadOnlyList<string>> siteByToken, IReadOnlySet<string> boolFields,
    IReadOnlySet<string> numberFields)
  {
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
    var siteByToken = SiteLookup(sites);

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

      // 3) Slike in dokumenti — celica je cel seznam; kar izdelek ima, v celici pa ni, se izbriše.
      //    Kaj je slika in kaj dokument, pove ista MediaKindPolicy kot izvoz (current.Media/Documents).
      foreach (var (field, kind, stored) in new[]
      {
        (ProductWorkbookContract.ImagesField, ProductMediaBulkEdit.Images, current.Media),
        (ProductWorkbookContract.DocumentsField, ProductMediaBulkEdit.Documents, current.Documents),
      })
      {
        if (!row.PimValues.TryGetValue(field, out var cell)) continue;
        var urls = ProductWorkbookContract.SplitList(cell);
        var before = stored.TryGetValue(productId, out var joined) ? ProductWorkbookContract.SplitList(joined) : [];
        var remove = before.Where(url => !urls.Contains(url, StringComparer.OrdinalIgnoreCase)).ToList();
        if (!mediaByOrganization.TryGetValue(row.OrganizationId, out var mediaList))
          mediaByOrganization[row.OrganizationId] = mediaList = [];
        mediaList.Add(new(productId, kind, urls, remove));
        bulkRows.Add(row.RowNumber);
      }

      // 4) Spletne strani in kategorije
      var siteChanges = await ApplySitesAsync(
        row, productId, current, siteByToken, sites, validCategoryPaths, actor, note, problems, cancellationToken);
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
        queued += outcome.Queued; duplicates += outcome.Duplicates; rejected += outcome.Rejected;
        foreach (var line in outcome.Rows.Where(line => line.Status == "Rejected"))
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

    return new(touched, pimChanges, queued, duplicates, rejected, batches, problems,
      erpWritten, mediaAdded, mediaRemoved, createdAttributes);
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
    IReadOnlyDictionary<string, SiteCategoryPaths> validCategoryPaths,
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
    else
    {
      // Brez stolpca »Spletne strani«: jezikovne različice strani iz stolpca kategorij pridejo v
      // poštev za sledenje (drugi obhod spodaj). Izvoz obe različici izpiše kot eno ime
      // (»Videlektro«) in uvoz to ime razširi na obe — brez tega bi prvi uvoz izdelek postavil
      // samo na slovensko stran, naslednji uvoz iste, nespremenjene datoteke pa še na angleško.
      foreach (var site in incoming.Keys.ToList())
      {
        var tree = sites.FirstOrDefault(candidate => string.Equals(candidate.Code, site, StringComparison.OrdinalIgnoreCase))?.CategoryTreeCode;
        foreach (var sibling in sites.Where(candidate => tree is not null && candidate.CategoryTreeCode == tree))
          affected.Add(sibling.Code);
      }
    }

    // Prvi obhod: cilj za vsako stran, ki ga vrstica ali dosedanje stanje določa samo.
    var targets = new Dictionary<string, IReadOnlyList<string>>(StringComparer.OrdinalIgnoreCase);
    var withoutCategory = new List<string>();
    foreach (var site in affected)
    {
      var stays = listed is null || listed.Contains(site, StringComparer.OrdinalIgnoreCase);
      if (!stays) { targets[site] = []; continue; }
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
    var languages = await LanguagesAsync(filter.WithPartnerScope().OrganizationId, cancellationToken);
    var registry = await ReadAsync([], [], filter.CategoryTreeCode, filter.CategoryCode, cancellationToken);
    var attributes = filter.CategoryCode is null
      ? OrderAttributes(registry.Attributes)
      : OrderAttributes(registry.Attributes).Where(attribute => attribute.InSet).ToList();
    return ProductWorkbookContract.Build(new(saopFields, sites, WebTextTypes, languages, attributes));
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

    if (productIds.Count > 0 && fieldCodes.Contains(ReservationExclusionField, StringComparer.Ordinal))
      await ReadReservationExclusionAsync(productIds, values, cancellationToken);

    return new(values, categoryPaths, attributeValues, media, documents, attributes, required);
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

    static string Normalize(string? value) =>
      (value ?? string.Empty).Replace("\r\n", "\n").Replace("\r", "\n").Trim();
  }

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
