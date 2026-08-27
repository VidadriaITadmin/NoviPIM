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
/// z <c>@Take</c> do 20.000 (migracija 115) — merjeno 1,0 s za 20.000 vrstic.
/// </summary>
public sealed class ProductExportService(IConfiguration configuration, ProductWorkbenchService workbench)
{
  /// <summary>Zgornja meja vrstic; izrecna in zapisana v datoteko, kadar je nabor večji.</summary>
  public const int MaxRows = 20_000;

  string ConnectionString => ConnectionStringResolver.Resolve(configuration)
    ?? throw new InvalidOperationException("Povezava PIM ni nastavljena.");

  public async Task<byte[]> BuildAsync(
    ProductListFilter filter, ProductExportTemplate template,
    IReadOnlyCollection<string>? onlyItemIds = null, CancellationToken cancellationToken = default)
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

    return template == ProductExportTemplate.Saop
      ? await BuildSaopAsync(rows, notes, cancellationToken)
      : BuildOverview(rows, notes);
  }

  /* --- pregled: kar je na seznamu ---------------------------------------------------- */

  static byte[] BuildOverview(IReadOnlyList<ProductListRow> rows, List<string> notes)
  {
    WorkbookColumn[] columns =
    [
      new("Podjetje"), new("Šifra artikla"), new("EAN"), new("Naziv", Width: 46),
      new("Proizvajalec", Width: 26), new("Dobavitelj", Width: 26), new("Skupina"), new("Oddelek"),
      new("ERP"), new("Splet"), new("Popolnost", WorkbookCellKind.Percent),
      new("Odprte težave", WorkbookCellKind.Number), new("Mediji", WorkbookCellKind.Number),
      new("Kategorije", WorkbookCellKind.Number), new("Čaka SAOP", WorkbookCellKind.Number),
      new("Objavljen"), new("Aktiven"), new("Za splet"), new("Zadnja sprememba", WorkbookCellKind.DateTime),
    ];

    var cells = rows.Select(row => new object?[]
    {
      row.OrganizationName, row.ItemId, row.Ean, row.Name, row.ManufacturerLabel, row.SupplierLabel,
      row.ItemGroup, row.Department, StatusText(row.ErpStatus), StatusText(row.WebStatus),
      row.Completeness, row.OpenIssueCount, row.MediaCount, row.CategoryCount,
      row.PendingOutboundCount, row.IsPromoted, row.IsActive, row.WebPublish, row.LastChangedUtc,
    });

    return WorkbookWriter.Write("Izdelki", columns, cells, notes);
  }

  /* --- predloga SAOP: ista datoteka za izvoz, urejanje in vracanje -------------------- */

  async Task<byte[]> BuildSaopAsync(
    IReadOnlyList<ProductListRow> rows, List<string> notes, CancellationToken cancellationToken)
  {
    var template = await GetTemplateColumnsAsync(cancellationToken);
    var values = await GetFieldValuesAsync(rows.Select(row => row.ProductId).ToList(), cancellationToken);

    // Podjetje je prvi stolpec, ker je sifra artikla enolicna samo znotraj podjetja; brez njega
    // uvoz ne ve, komu vrstica pripada. Sifra pride iz registra (element ItemID), zato je tu ni
    // se enkrat — dva stolpca z istim naslovom bi bila pri uvozu dvoumna.
    var columns = new List<WorkbookColumn> { new("Podjetje", Width: 16) };
    columns.AddRange(template.Select(column => new WorkbookColumn(
      column.ElementName,
      column.ValueFormat switch
      {
        "decimal4" or "decimal8" => WorkbookCellKind.Number,
        _ => WorkbookCellKind.Text,
      },
      Width: Math.Clamp(column.ElementName.Length + 3, 14, 30))));

    var cells = rows.Select(row =>
    {
      var line = new List<object?> { row.OrganizationName };
      foreach (var column in template)
        line.Add(column.FieldKey is null
          ? null
          : values.TryGetValue((row.ProductId, column.FieldKey), out var value) ? value : null);
      return (IReadOnlyList<object?>)line;
    });

    notes.Add("Predloga SAOP: naslovi stolpcev so imena elementov SAOP iz registra out.SaopXmlField.");
    notes.Add($"Obvezno pri novem artiklu: {string.Join(", ", template.Where(column => column.IsAddMandatory).Select(column => column.ElementName))}.");
    var readOnly = template.Where(column => !column.IsWritable).Select(column => column.ElementName).ToList();
    if (readOnly.Count > 0)
      notes.Add($"PIM teh polj ne piše nazaj v SAOP (pri spremembi se prezrejo): {string.Join(", ", readOnly)}.");
    notes.Add("Podjetje in ItemID sta ključ vrstice; ne spreminjaj ju, sicer uvoz ne najde izdelka.");

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
    _ => status,
  };

  /// <summary>Ime datoteke z datumom, da se izvozi ne prepisujejo v mapi prenosov.</summary>
  public static string FileName(ProductExportTemplate template, DateTime nowUtc) =>
    (template == ProductExportTemplate.Saop ? "artikli-saop-" : "izdelki-")
    + nowUtc.ToLocalTime().ToString("yyyyMMdd-HHmm", CultureInfo.InvariantCulture) + ".xlsx";
}
