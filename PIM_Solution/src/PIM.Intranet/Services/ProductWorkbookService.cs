using System.Data;
using System.Globalization;
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
  /// <summary>Zgornja meja vrstic izvoza; enaka kot pri ostalih predlogah.</summary>
  public const int MaxRows = ProductExportService.MaxRows;

  /// <summary>Največ stolpcev atributov; brez meje bi list rasel z vsakim novim atributom vira.</summary>
  public const int MaxAttributeColumns = 200;

  /// <summary>Spletni vrsti besedila; <c>TITLE_ERP</c> je last SAOP in pride iz registra.</summary>
  static readonly string[] WebTextTypes = ["WEB_TITLE", "DESCRIPTION"];

  string ConnectionString => ConnectionStringResolver.Resolve(configuration)
    ?? throw new InvalidOperationException("Povezava PIM ni nastavljena.");

  /* ─── Izvoz ────────────────────────────────────────────────────────────────────────── */

  public async Task<byte[]> BuildAsync(
    ProductListFilter filter, IReadOnlyCollection<string>? onlyItemIds = null,
    CancellationToken cancellationToken = default)
  {
    var page = await workbench.GetProductListAsync(filter with { Skip = 0, Take = MaxRows }, cancellationToken);
    var rows = onlyItemIds is { Count: > 0 }
      ? page.Rows.Where(row => onlyItemIds.Contains(row.ItemId, StringComparer.OrdinalIgnoreCase)).ToList()
      : page.Rows.ToList();

    var notes = new List<string>();
    if (onlyItemIds is { Count: > 0 })
      notes.Add($"Izvoženi so izbrani izdelki: {rows.Count:N0} od {onlyItemIds.Count:N0} izbranih (ostali niso v tem pogledu).");
    else if (page.TotalCount > rows.Count)
      notes.Add($"Izvoženih {rows.Count:N0} od {page.TotalCount:N0} vrstic pogleda; zgornja meja izvoza je {MaxRows:N0}.");

    var sites = await ActiveWebSitesAsync(cancellationToken);
    var saopFields = await WritableSaopFieldsAsync(cancellationToken);
    var languages = await LanguagesAsync(filter.OrganizationId, cancellationToken);

    // Prvi obhod da stolpce brez atributov; iz njih izhajajo kode polj, ki jih je treba
    // prebrati. Sifrant atributov pride iz istega klica in dopolni stolpce v drugem obhodu.
    var probe = ProductWorkbookContract.Build(new(saopFields, sites, WebTextTypes, languages, []));
    var fieldCodes = probe
      .Where(column => column.Target != ProductWorkbookTarget.ReadOnly)
      .Select(column => column.FieldKey)
      .Where(key => !key.StartsWith(ProductWorkbookContract.CategoryFieldPrefix, StringComparison.Ordinal)
        && key != ProductWorkbookContract.WebPublishField && key != ProductWorkbookContract.WebSitesField)
      .Distinct(StringComparer.Ordinal).ToList();

    var sheet = await ReadAsync(rows.Select(row => row.ProductId).ToList(), fieldCodes,
      filter.CategoryTreeCode, filter.CategoryCode, cancellationToken);

    // Nabor kategorije gre v list cel; meja velja samo za atribute izven nabora, ki jih je pri
    // izvozu brez izbrane kategorije lahko vseh 148 in so za posamezen izdelek vecinoma prazni.
    var ordered = OrderAttributes(sheet.Attributes);
    var attributes = ordered.Where(attribute => attribute.InSet)
      .Concat(ordered.Where(attribute => !attribute.InSet).Take(MaxAttributeColumns)).ToList();
    if (ordered.Count > attributes.Count)
      notes.Add($"Stolpcev atributov izven nabora je {MaxAttributeColumns:N0} od {ordered.Count - attributes.Count + MaxAttributeColumns:N0}; nabor kategorije je izpisan cel.");

    var definition = ProductWorkbookContract.Build(new(saopFields, sites, WebTextTypes, languages, attributes));
    var columns = definition.Select(column => new WorkbookColumn(
      column.Header, column.Kind, column.Width, column.Group,
      sheet.Required.ContainsKey(column.FieldKey) ? WorkbookCellTone.Required : WorkbookCellTone.None)).ToArray();

    var siteNames = sites.ToDictionary(site => site.Code, site => site.Name, StringComparer.OrdinalIgnoreCase);
    var cells = rows.Select(row => (IReadOnlyList<object?>)definition
      .Select(column => Cell(column, row, sheet, siteNames)).ToArray()).ToArray();

    notes.Add("Ta list gre ven in se vrne nazaj: /izdelki → Uvozi Excel. Naslovov stolpcev ne spreminjaj.");
    notes.Add("Podjetje in Šifra artikla sta ključ vrstice; brez njiju uvoz vrstice ne najde.");
    notes.Add("Prazna celica pomeni »tega polja se ne dotakni«, ne »izprazni ga«.");
    notes.Add("Več vrednosti v eni celici loči z znakom | (spletne strani, kategorije, slike).");
    notes.Add($"Stolpec »Spletne strani«: {string.Join(" | ", sites.Select(site => site.Name))}. Stran, ki je v celici ni, izdelek izgubi.");
    notes.Add("Stran, ki jo dodaš, mora imeti kategorijo — v svojem stolpcu »Kategorije — …« ali že od prej.");
    notes.Add($"Skupina »{ProductWorkbookContract.GroupErp}«: te vrednosti se ne zapišejo takoj, ampak čakajo odobritev na /izvozi/mnozicno.");
    notes.Add($"Skupina »{ProductWorkbookContract.GroupState}« se pri uvozu prezre.");
    notes.Add("Rumena glava: polje je pogoj za validacijo. Rdeča celica: tako polje je pri tem izdelku prazno.");

    var setCount = attributes.Count(attribute => attribute.InSet);
    if (setCount > 0)
      notes.Add($"Skupina »{ProductWorkbookContract.GroupAttributesInSet}«: {setCount:N0} atributov, ki jih predpisuje kategorija (nastavi jih na /nastavitve/nabori-atributov). Stolpec je tu tudi, kadar je vrednost prazna — ravno tega je treba vpisati.");
    else
      notes.Add("Kategorija ni izbrana ali njen nabor je prazen, zato so atributi izpisani brez nabora. Za ožji list izberi kategorijo v filtru na /izdelki.");

    return WorkbookWriter.Write("Izdelki", columns, cells, notes);
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
          .Select(code => siteNames.TryGetValue(code, out var name) ? name : code));
      case "ProductMedia.Url":
        return sheet.Media.TryGetValue(row.ProductId, out var media) ? media : null;
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
    List<ProductWorkbookRowChange> rows, IReadOnlyDictionary<string, string> siteByToken,
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
    var current = await ReadAsync(productIds, fieldCodes, null, null, cancellationToken);

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
    IReadOnlyDictionary<string, string> siteByToken)
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
        .Select(token => siteByToken.TryGetValue(WorkbookHeader.Normalize(token), out var code) ? code : token)
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

  public async Task<ProductWorkbookOutcome> ApplyAsync(
    ProductWorkbookPreview preview, string actor, string? note = null,
    CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(preview);
    var problems = new List<string>();
    var sites = await ActiveWebSitesAsync(cancellationToken);
    var siteByToken = SiteLookup(sites);

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
    // stran, ki je v celici ni, mora kategorije izgubiti.
    var current = await ReadAsync(
      known.Select(row => productIds[(row.OrganizationId, row.ItemId)]).ToList(), [], null, null, cancellationToken);

    var pimChanges = 0;
    var touched = 0;
    var saopByOrganization = new Dictionary<int, List<(string ItemId, string FieldKey, string? Value)>>();

    foreach (var row in known)
    {
      var productId = productIds[(row.OrganizationId, row.ItemId)];
      var rowChanged = false;

      // 1) Besedila
      var texts = row.PimValues
        .Where(pair => pair.Key.StartsWith(ProductWorkbookContract.TextFieldPrefix, StringComparison.Ordinal))
        .Select(pair => pair.Key[ProductWorkbookContract.TextFieldPrefix.Length..].Split('.', 2))
        .Where(parts => parts.Length == 2)
        .Select(parts => new ProductTextEdit(parts[1], parts[0],
          row.PimValues[$"{ProductWorkbookContract.TextFieldPrefix}{parts[0]}.{parts[1]}"]))
        .ToList();
      if (texts.Count > 0)
      {
        try
        {
          await edit.SaveTextsAsync(row.OrganizationId, productId, texts, actor, note, cancellationToken);
          pimChanges += texts.Count; rowChanged = true;
        }
        catch (Exception failure) { problems.Add($"Vrstica {row.RowNumber}: besedila niso zapisana — {failure.Message}"); }
      }

      // 2) Atributi
      var attributes = row.PimValues
        .Where(pair => pair.Key.StartsWith(ProductWorkbookContract.AttributeFieldPrefix, StringComparison.Ordinal))
        .Select(pair => new ProductAttributeEdit(pair.Key[ProductWorkbookContract.AttributeFieldPrefix.Length..], pair.Value))
        .ToList();
      if (attributes.Count > 0)
      {
        try
        {
          await edit.SaveAttributesAsync(row.OrganizationId, productId, attributes, actor, note, cancellationToken);
          pimChanges += attributes.Count; rowChanged = true;
        }
        catch (Exception failure) { problems.Add($"Vrstica {row.RowNumber}: atributi niso zapisani — {failure.Message}"); }
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
      var siteChanges = await ApplySitesAsync(row, productId, current, siteByToken, sites, actor, note, problems, cancellationToken);
      if (siteChanges > 0) { pimChanges += siteChanges; rowChanged = true; }

      // 5) ERP polja gredo v vrsto, ne v katalog
      if (erp.Count > 0)
      {
        if (!saopByOrganization.TryGetValue(row.OrganizationId, out var list))
          saopByOrganization[row.OrganizationId] = list = [];
        foreach (var pair in erp) list.Add((row.ItemId, pair.Key, pair.Value));
        rowChanged = true;
      }

      if (rowChanged) touched++;
    }

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
    IReadOnlyDictionary<string, string> siteByToken, IReadOnlyList<WorkbookWebSite> sites,
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
        if (siteByToken.TryGetValue(WorkbookHeader.Normalize(token), out var code)) listed.Add(code);
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
      else if (incoming.TryGetValue(site, out var given) && given.Count > 0) target = given;
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

  /// <summary>Ime in koda strani sta oba sprejeta; uporabnik pise ime, datoteka nosi ime.</summary>
  static IReadOnlyDictionary<string, string> SiteLookup(IReadOnlyList<WorkbookWebSite> sites)
  {
    var lookup = new Dictionary<string, string>(StringComparer.Ordinal);
    foreach (var site in sites)
    {
      lookup.TryAdd(WorkbookHeader.Normalize(site.Name), site.Code);
      lookup.TryAdd(WorkbookHeader.Normalize(site.Code), site.Code);
    }
    return lookup;
  }

  /* ─── Registri in branje ──────────────────────────────────────────────────────────── */

  public async Task<IReadOnlyList<WorkbookWebSite>> ActiveWebSitesAsync(CancellationToken cancellationToken = default) =>
    (await catalog.GetWebSitesAsync(cancellationToken))
      .Where(site => site.IsActive)
      .Select(site => new WorkbookWebSite(site.WebSiteCode,
        string.IsNullOrWhiteSpace(site.WebSiteName) ? site.WebSiteCode : site.WebSiteName))
      .ToList();

  async Task<IReadOnlyList<SaopWritableField>> WritableSaopFieldsAsync(CancellationToken cancellationToken)
  {
    var template = await export.GetTemplateColumnsAsync(cancellationToken);
    return template
      .Where(column => column.IsWritable && !string.IsNullOrWhiteSpace(column.FieldKey))
      // Sifra artikla je kljuc vrstice in stoji v skupini »Kljuc«; dvakrat bi bila dvoumna.
      .Where(column => column.FieldKey != ProductWorkbookContract.ItemIdField)
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

  async Task<WorkbookData> ReadAsync(
    IReadOnlyList<long> productIds, IReadOnlyList<string> fieldCodes,
    string? categoryTreeCode, string? categoryCode, CancellationToken cancellationToken)
  {
    var values = new Dictionary<(long, string), string?>();
    var categoryPaths = new Dictionary<(long, string), string>();
    var attributeValues = new Dictionary<(long, string), string?>();
    var media = new Dictionary<long, string>();
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

    if (await reader.NextResultAsync(cancellationToken))
      while (await reader.ReadAsync(cancellationToken))
        media[PimDb.Int64(reader, "ProductId")] = PimDb.TextOrEmpty(reader, "Urls");

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

    return new(values, categoryPaths, attributeValues, media, attributes, required);
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
