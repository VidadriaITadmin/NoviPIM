using System.Data;
using System.Globalization;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using PIM.Operations;

namespace PIM.Intranet.Services;

/// <param name="FieldKey">Ključ vrednosti v katalogu; prazen pomeni stolpec, ki ga PIM ne hrani
/// in ga je treba pri novem artiklu vpisati ročno.</param>
/// <param name="IsWritable">Ali sme PIM to polje pisati nazaj v SAOP.</param>
public sealed record SaopTemplateColumn(
  int SortOrder, string ElementName, string Section, string? FieldKey,
  string ValueFormat, bool IsAddMandatory, bool IsWritable);

/// <summary>Katera predloga se izvozi.</summary>
public enum ProductExportTemplate
{
  /// <summary>Kar je na seznamu: pregled stanja, brez polj za vračanje nazaj.</summary>
  Overview,

  /// <summary>Enotna predloga SAOP: isti stolpci za izvoz, urejanje in vračanje v PIM ali SAOP.</summary>
  Saop,
}

/// <summary>
/// Izvoz izdelkov v delovni zvezek.
///
/// Zakaj dve predlogi: pregled odgovarja na vprašanje »kje smo«, predloga SAOP pa je delovna —
/// stolpci so imena elementov SAOP iz registra <c>out.SaopXmlField</c>, zato je datoteko mogoče
/// urediti in vrniti nazaj skozi isti register. Register je en sam vir resnice; ko dobi novo
/// polje, ga dobita tudi predloga in odhodna vrsta.
///
/// Zakaj en klic in ne stranicenje: prej je izvoz sestavljal zvezek s 100 zaporednimi klici po
/// 200 vrstic in brskalnik je zahtevo prekinil, preden je datoteka nastala. Zdaj gre en klic
/// z <c>@Take</c> do <see cref="MaxRows"/> (migracija 115; meja dvignjena 2026-09-17) — merjeno
/// 1,0 s za 20.000 vrstic pri predlogi »pregled«; predloga »delovni« bere vec tabel na vrstico
/// (kategorije, atributi, mediji) in je zato pocasnejsa pri istem stevilu vrstic.
/// </summary>
public sealed class ProductExportService(IConfiguration configuration, ProductWorkbenchService workbench)
{
  /// <summary>Zgornja meja vrstic: fizična meja lista .xlsx (WorkbookTable.MaxRows), ne poslovna.
  /// Do 2026-09-17 je bila tu lastna meja 20.000 in izvoz »cel pogled« je pri 28.915 artiklih
  /// tiho odrezal tretjino; uporabnik je zahteval, da izvoz nima svoje meje.</summary>
  public const int MaxRows = WorkbookTable.MaxRows;

  /// <summary>Vrstic v enem klicu baze; seznam se bere po straneh, ne z eno visoko mejo @Take.</summary>
  const int PageSize = 2_000;

  string ConnectionString => ConnectionStringResolver.Resolve(configuration)
    ?? throw new InvalidOperationException("Povezava PIM ni nastavljena.");

  /// <param name="onlySelectionKeys">Ključi izbranih vrstic v obliki »PodjetjeId|Šifra« — šifra
  /// artikla sama ni dovolj, ker isto šifro lahko nosi vec podjetij (isti dobavitelj v vec
  /// katalogih); brez podjetja bi izvoz vrnil vse njih namesto samo izbrane vrstice. Null pomeni
  /// »brez izbora« in vrne cel pogled (izvoz s strani Izdelki); prazna, a ne-null zbirka pomeni
  /// »izbor je izrecno prazen« in vrne nič vrstic (predloga SAOP brez dodanih artiklov).</param>
  public async Task<byte[]> BuildAsync(
    ProductListFilter filter, ProductExportTemplate template,
    IReadOnlyCollection<string>? onlySelectionKeys = null, CancellationToken cancellationToken = default)
  {
    // Baza sama pove, koliko vrstic ima pogled (TotalCount); tu se bere stran za stranjo, dokler
    // ni vsega — isti vzorec kot StockReadService.BuildStockWorkbookAsync.
    var rows = new List<ProductListRow>();
    long totalCount = 0;
    var skip = 0;
    while (rows.Count < MaxRows)
    {
      var page = await workbench.GetProductListAsync(filter with { Skip = skip, Take = PageSize }, cancellationToken);
      totalCount = page.TotalCount;
      rows.AddRange(page.Rows);
      if (page.Rows.Count == 0 || rows.Count >= page.TotalCount) break;
      skip += PageSize;
    }
    if (onlySelectionKeys is not null)
      rows = rows.Where(row => onlySelectionKeys.Contains($"{row.OrganizationId}|{row.ItemId}", StringComparer.OrdinalIgnoreCase)).ToList();

    var notes = new List<string>();
    if (onlySelectionKeys is { Count: > 0 })
      notes.Add($"Izvoženi so izbrani izdelki: {rows.Count:N0} od {onlySelectionKeys.Count:N0} izbranih (ostali niso v tem pogledu).");
    else if (onlySelectionKeys is null && totalCount > rows.Count)
      notes.Add($"Izvoženih {rows.Count:N0} od {totalCount:N0} vrstic pogleda; zgornja meja izvoza je {MaxRows:N0}.");

    return template == ProductExportTemplate.Saop
      ? await BuildSaopAsync(rows, notes, cancellationToken)
      : await BuildOverviewAsync(rows, notes, cancellationToken);
  }

  /* --- pregled: ERP, komerciala in splet -------------------------------------------- */

  /// <param name="FieldCode">Koda v <c>canon.FieldValue</c>; null pomeni stolpec, ki pride iz
  /// vrstice seznama in ne iz registra polj (podjetje, ime partnerja, izracunano stanje).</param>
  sealed record OverviewColumn(string Group, string Header, string? FieldCode,
    WorkbookCellKind Kind = WorkbookCellKind.Text, double Width = 0,
    Func<ProductListRow, object?>? FromRow = null);

  /// <summary>Jeziki nazivov in opisov, v vrstnem redu, ki ga je dolocil uporabnik.</summary>
  static readonly string[] Languages = ["sl", "en", "de", "hr", "it"];

  const string GroupIdentity = "Istovetnost";
  const string GroupErp = "ERP";
  const string GroupCommercial = "Komerciala";
  const string GroupWeb = "Splet";
  const string GroupState = "Stanje";

  /// <summary>
  /// Stolpci zvezka »pregled«. Do 2026-08-28 je bil ta list prepis zaslonskega seznama —
  /// stanja in stevci, nobene vsebine izdelka — zato ga ni bilo mogoce uporabiti za mnozicno
  /// popravljanje, ki je edini razlog za izvoz 20.000 vrstic. Zdaj nosi tri skupine, ki jih je
  /// nastel uporabnik: ERP, komerciala in splet. Stevci (odprte tezave, stevilo medijev,
  /// kategorij, caka SAOP, objavljen) so odpadli kot moteci.
  ///
  /// Pakiranje in dimenzije pakiranja stojijo pod ERP, ne pod komercialo: uporabnik je povedal,
  /// da tja spadata, ker prideta iz istega dokumenta SAOP kot ostala ERP polja.
  /// </summary>
  static IReadOnlyList<OverviewColumn> OverviewColumns()
  {
    var columns = new List<OverviewColumn>
    {
      new(GroupIdentity, "Podjetje", null, Width: 16, FromRow: row => row.OrganizationName),
      new(GroupIdentity, "Šifra artikla", "Product.ItemID", Width: 18),
      new(GroupIdentity, "EAN", "Product.EAN", Width: 16),
      new(GroupIdentity, "Naziv", null, Width: 46, FromRow: row => row.Name),

      new(GroupErp, "Enota mere", "Product.UoM"),
      new(GroupErp, "Skupina artikla", "Product.ItemGroup"),
      new(GroupErp, "ABC klasifikacija", "Product.Department"),
      new(GroupErp, "Proizvajalec (šifra)", "Product.Manufacturer"),
      new(GroupErp, "Proizvajalec (ime)", null, Width: 26, FromRow: row => row.ManufacturerName),
      new(GroupErp, "Dobavitelj (šifra)", "Product.Supplier"),
      new(GroupErp, "Dobavitelj (ime)", null, Width: 26, FromRow: row => row.SupplierName),
      new(GroupErp, "Obračunska skupina", "Product.AccountingGroup"),
      new(GroupErp, "Skupina popusta", "Product.DiscountGroup"),
      new(GroupErp, "Aktiven", null, FromRow: row => row.IsActive),
    };

    foreach (var language in Languages)
      columns.Add(new(GroupErp, $"Naziv ERP ({language})", $"ProductText.TITLE_ERP.{language}", Width: 34));

    columns.AddRange(
    [
      new(GroupErp, "Pakiranje 1", "ProductCommercial.Pak1", WorkbookCellKind.Number),
      new(GroupErp, "Pakiranje 2", "ProductCommercial.Pak2", WorkbookCellKind.Number),
      new(GroupErp, "Dolžina pakiranja", "ProductCommercial.PackageLength", WorkbookCellKind.Number),
      new(GroupErp, "Širina pakiranja", "ProductCommercial.PackageWidth", WorkbookCellKind.Number),
      new(GroupErp, "Višina pakiranja", "ProductCommercial.PackageHeight", WorkbookCellKind.Number),
      new(GroupErp, "Enota dimenzij", "ProductCommercial.DimensionUnit"),
      new(GroupErp, "Prostornina", "ProductCommercial.Volume", WorkbookCellKind.Number),

      new(GroupCommercial, "Neto teža", "ProductCommercial.NetWeight", WorkbookCellKind.Number),
      new(GroupCommercial, "Bruto teža", "ProductCommercial.GrossWeight", WorkbookCellKind.Number),
      new(GroupCommercial, "Carinska tarifa", "ProductCommercial.CustomsTariff"),
      new(GroupCommercial, "Država porekla", "ProductCommercial.CountryOfOrigin"),
      new(GroupCommercial, "Stopnja DDV", "ProductPrice.VatRate", WorkbookCellKind.Number),
      new(GroupCommercial, "Bruto cena", "ProductPrice.Gross", WorkbookCellKind.Number),

      new(GroupWeb, "Za splet", null, FromRow: row => row.WebPublish),
    ]);

    foreach (var language in Languages)
      columns.Add(new(GroupWeb, $"Spletni naziv ({language})", $"ProductText.WEB_TITLE.{language}", Width: 34));
    foreach (var language in Languages)
      columns.Add(new(GroupWeb, $"Spletni opis ({language})", $"ProductText.DESCRIPTION.{language}", Width: 40));

    columns.AddRange(
    [
      new(GroupWeb, "Kategorija", "ProductCategory.CategoryPath", Width: 40),
      new(GroupWeb, "Slika", "ProductMedia.Url", Width: 40),

      new(GroupState, "ERP", null, FromRow: row => StatusText(row.ErpStatus)),
      new(GroupState, "Splet", null, FromRow: row => StatusText(row.WebStatus)),
      new(GroupState, "Popolnost", null, WorkbookCellKind.Percent, FromRow: row => row.Completeness),
      new(GroupState, "Zadnja sprememba", null, WorkbookCellKind.DateTime, FromRow: row => row.LastChangedUtc),
    ]);

    return columns;
  }

  async Task<byte[]> BuildOverviewAsync(
    IReadOnlyList<ProductListRow> rows, List<string> notes, CancellationToken cancellationToken)
  {
    var definition = OverviewColumns();
    var fieldCodes = definition.Where(column => column.FieldCode is not null)
      .Select(column => column.FieldCode!).Distinct(StringComparer.Ordinal).ToList();

    var sheet = await GetExportSheetAsync(rows.Select(row => row.ProductId).ToList(), fieldCodes, cancellationToken);

    // Rumena oznaka pride iz registra val.FieldRequirement, ne iz seznama v kodi: register se
    // spreminja in seznam bi se z njim slej ko prej razsel.
    var columns = definition.Select(column => new WorkbookColumn(
      column.Header, column.Kind, column.Width, column.Group,
      column.FieldCode is not null && sheet.Required.ContainsKey(column.FieldCode)
        ? WorkbookCellTone.Required : WorkbookCellTone.None)).ToArray();

    var cells = rows.Select(row => (IReadOnlyList<object?>)definition.Select(column =>
    {
      if (column.FieldCode is null) return (object?)column.FromRow?.Invoke(row);

      var value = sheet.Values.TryGetValue((row.ProductId, column.FieldCode), out var found) ? found : null;
      var missing = string.IsNullOrWhiteSpace(value) && sheet.Required.ContainsKey(column.FieldCode);
      // Rdece se obarva samo prazno polje, ki je pogoj za validacijo. Ce bi se obarvala vsaka
      // prazna celica, bi bil list rdec povsod in oznaka ne bi vec pomenila nicesar.
      return new WorkbookCell(value, missing ? WorkbookCellTone.Missing : WorkbookCellTone.None);
    }).ToArray()).ToArray();

    notes.Add("Rumena glava: polje je pogoj za validacijo (register val.FieldRequirement).");
    notes.Add("Rdeča celica: polje je pogoj za validacijo in je pri tem izdelku prazno.");
    if (sheet.Required.Count > 0)
      notes.Add("Zahtevana polja: " + string.Join(", ", sheet.Required
        .OrderBy(pair => pair.Key, StringComparer.Ordinal)
        .Select(pair => $"{pair.Key} ({pair.Value})")));
    notes.Add("Več vrednosti istega polja (kategorije, slike) je združenih s podpičjem.");

    return WorkbookWriter.Write("Izdelki", columns, cells, notes);
  }

  sealed record ExportSheetData(
    Dictionary<(long ProductId, string FieldCode), string?> Values,
    Dictionary<string, string> Required);

  /// <summary>Vrednosti izbranih polj in register zahtevanih polj v enem klicu (migracija 127).</summary>
  async Task<ExportSheetData> GetExportSheetAsync(
    IReadOnlyList<long> productIds, IReadOnlyList<string> fieldCodes, CancellationToken cancellationToken)
  {
    var values = new Dictionary<(long, string), string?>();
    var required = new Dictionary<string, string>(StringComparer.Ordinal);
    if (productIds.Count == 0 || fieldCodes.Count == 0) return new(values, required);

    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.GetProductExportSheet", connection)
    {
      CommandType = CommandType.StoredProcedure,
      CommandTimeout = 180,
    };
    command.Parameters.Add("@ProductIdsJson", SqlDbType.NVarChar, -1).Value = JsonSerializer.Serialize(productIds);
    command.Parameters.Add("@FieldCodesJson", SqlDbType.NVarChar, -1).Value = JsonSerializer.Serialize(fieldCodes);

    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    while (await reader.ReadAsync(cancellationToken))
      values[(PimDb.Int64(reader, "ProductId"), PimDb.TextOrEmpty(reader, "FieldCode"))] = PimDb.Text(reader, "Value");

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

    return new(values, required);
  }

  /* --- predloga SAOP: ista datoteka za izvoz, urejanje in vracanje -------------------- */

  async Task<byte[]> BuildSaopAsync(
    IReadOnlyList<ProductListRow> rows, List<string> notes, CancellationToken cancellationToken)
  {
    var registry = await GetTemplateColumnsAsync(cancellationToken);
    var values = await GetFieldValuesAsync(rows.Select(row => row.ProductId).ToList(), cancellationToken);

    // Isti vrstni red in isti slovenski naslovi kot delovni list s strani Izdelki
    // (ProductWorkbookService.WritableSaopFieldsAsync): sifra artikla prva, pisljiva ERP polja po
    // SortOrder, nepisljiva (»dodatna«, samo za nov artikel — SAOP jih zahteva, PIM jih ne hrani)
    // cisto na koncu. Tako je datoteka s te strani in tista iz Izdelkov ista oblika in ju je
    // mogoce zamenjati. Uporabnikova zahteva 2026-09-10.
    var itemId = registry.FirstOrDefault(column => column.FieldKey == ProductWorkbookContract.ItemIdField);
    var writable = registry.Where(column => column.IsWritable && column.FieldKey != ProductWorkbookContract.ItemIdField).ToList();
    var readOnlyExtra = registry.Where(column => !column.IsWritable && column.FieldKey != ProductWorkbookContract.ItemIdField).ToList();
    var template = new List<SaopTemplateColumn>();
    if (itemId is not null) template.Add(itemId);
    template.AddRange(writable);
    template.AddRange(readOnlyExtra);

    // Podjetje je prvi stolpec, ker je sifra artikla enolicna samo znotraj podjetja; brez njega
    // uvoz ne ve, komu vrstica pripada.
    var columns = new List<WorkbookColumn> { new("Podjetje", Width: 16) };
    columns.AddRange(template.Select(column =>
    {
      var label = SaopFieldLabels.For(column.ElementName);
      return new WorkbookColumn(
        label,
        column.ValueFormat switch
        {
          "decimal4" or "decimal8" => WorkbookCellKind.Number,
          _ => WorkbookCellKind.Text,
        },
        Width: Math.Clamp(label.Length + 3, 14, 32));
    }));

    var cells = rows.Select(row =>
    {
      var line = new List<object?> { row.OrganizationName };
      foreach (var column in template)
        line.Add(column.FieldKey is null
          ? null
          : values.TryGetValue((row.ProductId, column.FieldKey), out var value) ? value : null);
      return (IReadOnlyList<object?>)line;
    });

    notes.Add("Predloga SAOP: naslovi stolpcev so slovenska imena elementov SAOP (register out.SaopXmlField); dodatna, nepisljiva polja stojijo na koncu.");
    var mandatory = template.Where(column => column.IsAddMandatory).Select(column => SaopFieldLabels.For(column.ElementName)).ToList();
    if (mandatory.Count > 0)
      notes.Add($"Obvezno pri novem artiklu: {string.Join(", ", mandatory)}.");
    var readOnly = readOnlyExtra.Select(column => SaopFieldLabels.For(column.ElementName)).ToList();
    if (readOnly.Count > 0)
      notes.Add($"PIM teh polj ne piše nazaj v SAOP (pri spremembi se prezrejo): {string.Join(", ", readOnly)}.");
    notes.Add("Podjetje in Šifra artikla sta ključ vrstice; ne spreminjaj ju, sicer uvoz ne najde izdelka.");

    return WorkbookWriter.Write("Artikli SAOP", columns, cells, notes);
  }

  public async Task<IReadOnlyList<SaopTemplateColumn>> GetTemplateColumnsAsync(CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.GetSaopTemplateColumns", connection)
    {
      CommandType = CommandType.StoredProcedure,
      CommandTimeout = 60,
    };
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var columns = new List<SaopTemplateColumn>();
    while (await reader.ReadAsync(cancellationToken))
      columns.Add(new(
        PimDb.Int32(reader, "SortOrder"), PimDb.TextOrEmpty(reader, "ElementName"),
        PimDb.TextOrEmpty(reader, "Section"), PimDb.Text(reader, "FieldKey"),
        PimDb.TextOrEmpty(reader, "ValueFormat"), PimDb.Bool(reader, "IsAddMandatory"),
        PimDb.Bool(reader, "IsWritable")));
    return columns;
  }

  async Task<Dictionary<(long ProductId, string FieldKey), string?>> GetFieldValuesAsync(
    IReadOnlyList<long> productIds, CancellationToken cancellationToken)
  {
    var values = new Dictionary<(long, string), string?>();
    if (productIds.Count == 0) return values;

    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.GetProductFieldValues", connection)
    {
      CommandType = CommandType.StoredProcedure,
      CommandTimeout = 120,
    };
    command.Parameters.Add("@ProductIdsJson", SqlDbType.NVarChar, -1).Value = JsonSerializer.Serialize(productIds);

    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    while (await reader.ReadAsync(cancellationToken))
      values[(PimDb.Int64(reader, "ProductId"), PimDb.TextOrEmpty(reader, "FieldCode"))] = PimDb.Text(reader, "Value");
    return values;
  }

  static string StatusText(string status) => status switch
  {
    "VALID" => "pripravljen",
    "INVALID" => "blokiran",
    "PENDING" => "čaka validacijo",
    "NOT_CONFIGURED" => "ni profila",
    "NOT_ON_WEB" => "ni na spletu",
    _ => status,
  };

  /// <summary>Ime datoteke z datumom, da se izvozi ne prepisujejo v mapi prenosov.</summary>
  public static string FileName(ProductExportTemplate template, DateTime nowUtc) =>
    (template == ProductExportTemplate.Saop ? "artikli-saop-" : "izdelki-")
    + nowUtc.ToPimLocal().ToString("yyyyMMdd-HHmm", CultureInfo.InvariantCulture) + ".xlsx";
}
