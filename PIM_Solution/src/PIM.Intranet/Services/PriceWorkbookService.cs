using System.Globalization;
using PIM.Operations;

namespace PIM.Intranet.Services;

/// <summary>Ena cena iz uvoza, ki se razlikuje od SAOP (ali je nova).</summary>
public sealed record PriceImportRow(
  int RowNumber, int OrganizationId, string OrganizationName, string PriceList, string ItemId,
  decimal? OldNet, decimal NewNet, decimal? OldVat, decimal? NewVat, DateTime? OldValidFrom, DateTime? ValidFrom,
  bool? OldActive, bool? Active)
{
  public bool IsNew => OldNet is null;

  /// <summary>Sprememba neto v odstotkih; null pri novi ceni ali stari ceni 0.</summary>
  public decimal? ChangePercent => OldNet is { } old && old != 0 ? Math.Round((NewNet - old) / old * 100, 1) : null;
}

public sealed record PriceImportPreview(
  IReadOnlyList<PriceImportRow> Rows, int RowsRead, int UnchangedRows,
  IReadOnlyList<string> Problems, IReadOnlyList<string> Warnings,
  IReadOnlyList<string> UnknownColumns, IReadOnlyList<string> ReadOnlyColumns)
{
  public int NewCount => Rows.Count(row => row.IsNew);
  public IReadOnlyList<string> Organizations => Rows.Select(row => row.OrganizationName).Distinct().ToArray();
}

/// <param name="Batches">Serija na podjetje: čaka odobritev na zavihku »V SAOP«.</param>
public sealed record PriceImportOutcome(
  IReadOnlyList<(string Organization, long? BatchId, PriceEnqueueOutcome Outcome)> Batches)
{
  public int Queued => Batches.Sum(batch => batch.Outcome.Queued);
  public int Duplicates => Batches.Sum(batch => batch.Outcome.Duplicates);
  public int Unchanged => Batches.Sum(batch => batch.Outcome.Unchanged);
  public IReadOnlyList<PriceEnqueueRow> Rejected => Batches.SelectMany(batch => batch.Outcome.Rows).Where(row => row.Status == "Rejected").ToArray();
}

/// <summary>
/// Delovni list cen (265): izvoz v Excel in uvoz nazaj, po vzoru strank in izdelkov. Ena vrstica je
/// ena cena (podjetje + cenik + šifra artikla). Uvoz ne piše v PIM: spremembe gredo v vrsto za SAOP
/// (<see cref="PriceService.EnqueueAsync"/>), kjer počakajo odobritev na zavihku »V SAOP«. Cena se v
/// PIM spremeni šele, ko jo SAOP sprejme in jo zajem cen prinese nazaj.
///
/// Pravila celic kot pri strankah: prazna celica pomeni »ne spreminjaj«. Nova vrstica (cenik, v
/// katerem artikel še nima cene) je nova cena v SAOP (AddPrices).
/// </summary>
public sealed class PriceWorkbookService(PriceService prices, IntranetDataService data)
{
  public const string SheetName = "Cene";

  const string GroupKey = "Ključ";
  const string GroupInfo = "Artikel — samo za branje";
  const string GroupPrice = "Cena — gre v SAOP";
  const string GroupState = "Stanje — samo za branje";

  public const string OrganizationKey = "ORG";
  public const string PriceListKey = "LIST";
  public const string ItemKey = "ITEM";
  const string NetKey = "NET";
  const string VatKey = "VAT";
  const string FromKey = "FROM";
  const string ActiveKey = "ACTIVE";

  public static readonly IReadOnlyList<CustomerWorkbookColumn> Columns =
  [
    new(OrganizationKey, "Podjetje", GroupKey, false, Width: 14),
    new(PriceListKey, "Cenik", GroupKey, false, Width: 10),
    new(ItemKey, "Šifra artikla", GroupKey, false, Width: 18),

    new("TITLE", "Naziv", GroupInfo, false, Width: 44),
    new("EAN", "EAN", GroupInfo, false, Width: 15),
    new("LIST_NAME", "Naziv cenika", GroupInfo, false, Width: 22),

    new(NetKey, "Neto cena", GroupPrice, true, WorkbookCellKind.Number, 12),
    new(VatKey, "DDV %", GroupPrice, true, WorkbookCellKind.Number, 8),
    new(FromKey, "Velja od", GroupPrice, true, WorkbookCellKind.DateTime, 12),
    new(ActiveKey, "Aktivna", GroupPrice, true, Width: 8),

    new("GROSS", "Cena z DDV", GroupState, false, WorkbookCellKind.Number, 12),
    new("QUEUED", "Čaka v vrsti za SAOP (neto)", GroupState, false, WorkbookCellKind.Number, 14),
    new("QUEUE_STATE", "Stanje v vrsti", GroupState, false, Width: 22),
  ];

  static readonly IReadOnlyList<string> Notes =
  [
    "Ena vrstica je ena cena: podjetje + cenik + šifra artikla. Uredi Neto cena, DDV %, Velja od ali Aktivna in datoteko vrni prek »Uvozi Excel« na strani Cene.",
    "Uvoz cen ne zapiše v PIM, ampak jih uvrsti v vrsto za SAOP. Tam počakajo, da jih nekdo odobri (zavihek »V SAOP«). Ko jih SAOP sprejme, jih naslednji zajem cen prinese nazaj v PIM.",
    "Prazna celica pomeni »ne spreminjaj«. Vrstica s cenikom, v katerem artikel še nima cene, je nova cena (v SAOP gre kot AddPrices). Nov cenik najprej dodaj na zavihku »Ceniki«.",
    "Neto cena je cena brez DDV, kot jo vodi SAOP (Price), z decimalno vejico ali piko. Aktivna: D ali N. Velja od: datum, npr. 1. 10. 2026.",
    "Stolpci pod »samo za branje« se pri uvozu prezrejo. Sprememba nad 25 % je v predogledu označena kot opozorilo.",
  ];

  public static string FileName(DateTime utc) => $"PIM_cene_{utc:yyyyMMdd_HHmm}.xlsx";

  /* --- izvoz -------------------------------------------------------------------------------- */

  public static byte[] Build(IReadOnlyList<PriceLine> rows)
  {
    var columns = Columns.Select(column => new WorkbookColumn(column.Header, column.Kind, column.Width, column.Group)).ToArray();
    return WorkbookWriter.Write([new WorkbookWriteSheet(SheetName, columns, rows.Select(Cells), Notes)]);
  }

  static IReadOnlyList<object?> Cells(PriceLine row)
  {
    var queued = row.QueueStatus is { } status && !(status == "Sent" && row.QueuedNet == row.Net);
    return
    [
      row.OrganizationName, row.PriceList, row.ItemId,
      row.Title, row.Ean, row.PriceListName,
      row.Net, row.VatRate, row.ValidFrom is { Year: > 1900 } from ? from : null,
      ProductWorkbookContract.SheetYesNo(row.IsActive),
      row.Gross,
      queued ? row.QueuedNet : null,
      queued ? PriceService.QueueLabel(row.QueueStatus) : null,
    ];
  }

  /* --- uvoz: predogled ---------------------------------------------------------------------- */

  public async Task<PriceImportPreview> PreviewAsync(Stream stream, int? fallbackOrganizationId, CancellationToken cancellationToken = default)
  {
    var sheet = WorkbookTable.Read(stream, headerHints: ["Šifra artikla", "Cenik"]);

    var byHeader = Columns.ToDictionary(column => WorkbookHeader.Normalize(column.Header));
    var matched = new Dictionary<string, int>(StringComparer.Ordinal);
    var unknown = new List<string>();
    var readOnly = new List<string>();
    for (var index = 0; index < sheet.Headers.Count; index++)
    {
      var header = sheet.Headers[index];
      if (string.IsNullOrWhiteSpace(header)) continue;
      if (!byHeader.TryGetValue(WorkbookHeader.Normalize(header), out var column)) { unknown.Add(header); continue; }
      if (column.Editable || column.Key is OrganizationKey or PriceListKey or ItemKey) matched.TryAdd(column.Key, index);
      else readOnly.Add(header);
    }

    if (!matched.ContainsKey(ItemKey) || !matched.ContainsKey(PriceListKey))
      throw new WorkbookReadException("Datoteka nima stolpcev »Cenik« in »Šifra artikla« — po njiju uvoz najde ceno. Izvozi datoteko s strani Cene in jo uredi.");
    if (!matched.ContainsKey(NetKey))
      throw new WorkbookReadException("Datoteka nima stolpca »Neto cena«.");
    if (!matched.ContainsKey(OrganizationKey) && fallbackOrganizationId is null)
      throw new WorkbookReadException("Datoteka nima stolpca »Podjetje«. Izberi podjetje, ki mu pripadajo vse vrstice.");

    var organizations = (await data.GetOrganizationsAsync(cancellationToken)).ToDictionary(row => row.OrganizationId, row => row.Name);

    // Najprej vse vrstice po podjetju, nato ena poizvedba trenutnih cen in artiklov na podjetje.
    var parsed = new List<(int RowNumber, int OrganizationId, string PriceList, string ItemId, Func<string, string> Cell)>();
    var problems = new List<string>();
    var warnings = new List<string>();
    var read = 0;
    for (var index = 0; index < sheet.Rows.Count; index++)
    {
      var cells = sheet.Rows[index];
      var rowNumber = sheet.RowNumber(index);
      string Cell(string key) => matched.TryGetValue(key, out var at) && at < cells.Count ? (cells[at] ?? "").Trim() : "";
      var itemId = Cell(ItemKey);
      var priceList = Cell(PriceListKey).ToUpperInvariant();
      if (itemId.Length == 0 && priceList.Length == 0) continue;
      read++;
      if (itemId.Length == 0 || priceList.Length == 0) { problems.Add($"Vrstica {rowNumber}: manjka cenik ali šifra artikla — vrstica je izpuščena."); continue; }

      var organizationText = Cell(OrganizationKey);
      int? organizationId = organizationText.Length == 0 ? fallbackOrganizationId : ResolveOrganization(organizations, organizationText);
      if (organizationId is null) { problems.Add($"Vrstica {rowNumber}: podjetja »{organizationText}« ni — vrstica je izpuščena."); continue; }
      parsed.Add((rowNumber, organizationId.Value, priceList, itemId, Cell));
    }

    var rows = new List<PriceImportRow>();
    var seen = new HashSet<(int, string, string)>();
    var unchanged = 0;
    foreach (var organization in parsed.GroupBy(row => row.OrganizationId))
    {
      var organizationName = organizations.GetValueOrDefault(organization.Key, organization.Key.ToString(CultureInfo.InvariantCulture));
      var itemIds = organization.Select(row => row.ItemId).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
      var current = await prices.GetCurrentAsync(organization.Key, itemIds, cancellationToken);
      var items = await prices.GetItemsAsync(organization.Key, itemIds, cancellationToken);
      var lists = (await prices.GetPriceListsAsync(organization.Key, cancellationToken))
        .Select(list => list.Code).ToHashSet(StringComparer.OrdinalIgnoreCase);

      foreach (var (rowNumber, organizationId, priceList, itemId, cell) in organization)
      {
        var where = $"Vrstica {rowNumber} ({organizationName} {priceList} {itemId})";
        if (!seen.Add((organizationId, priceList.ToUpperInvariant(), itemId.ToUpperInvariant())))
        { problems.Add($"{where}: ista cena je v datoteki že višje — vrstica je izpuščena."); continue; }
        if (!lists.Contains(priceList))
        { problems.Add($"{where}: cenika {priceList} v tem podjetju ni. Nov cenik najprej dodaj na zavihku Ceniki."); continue; }
        if (!items.ContainsKey(itemId))
        { problems.Add($"{where}: artikla {itemId} v tem podjetju ni — vrstica je izpuščena."); continue; }

        var netText = cell(NetKey);
        if (netText.Length == 0) { unchanged++; continue; }
        if (CustomerWorkbookService.ParseDecimal(netText) is not { } net || net < 0)
        { problems.Add($"{where}: neto cena »{netText}« ni število, večje ali enako 0."); continue; }
        net = Math.Round(net, 4);

        decimal? vat = null;
        var vatText = cell(VatKey);
        if (vatText.Length > 0)
        {
          if (CustomerWorkbookService.ParseDecimal(vatText) is { } parsedVat && parsedVat is >= 0 and <= 100) vat = Math.Round(parsedVat, 2);
          else { problems.Add($"{where}: DDV »{vatText}« ni odstotek med 0 in 100."); continue; }
        }

        DateTime? from = null;
        var fromText = cell(FromKey);
        if (fromText.Length > 0)
        {
          if (CustomerWorkbookService.ParseDate(fromText) is { } parsedDate) from = parsedDate;
          else { problems.Add($"{where}: »Velja od« »{fromText}« ni datum (npr. 1. 10. 2026)."); continue; }
        }

        bool? active = null;
        var activeText = cell(ActiveKey);
        if (activeText.Length > 0)
        {
          if (ProductWorkbookContract.ParseYesNo(activeText) is { } parsedActive) active = parsedActive;
          else { problems.Add($"{where}: Aktivna »{activeText}« ni D ali N."); continue; }
        }

        current.TryGetValue((organizationId, priceList, itemId), out var now);
        var oldFrom = now?.ValidFrom is { Year: > 1900 } date ? date.Date : (DateTime?)null;
        var same = now is not null && now.Net == net
          && (vat is null || vat == now.VatRate)
          && (active is null || active == now.IsActive)
          && (from is null || from == oldFrom);
        if (same) { unchanged++; continue; }

        var row = new PriceImportRow(rowNumber, organizationId, organizationName, priceList, items.Keys.First(key =>
            string.Equals(key, itemId, StringComparison.OrdinalIgnoreCase)),
          now?.Net, net, now?.VatRate, vat, oldFrom, from, now?.IsActive, active);
        if (row.ChangePercent is { } percent && Math.Abs(percent) > 25)
          warnings.Add($"{where}: neto {row.OldNet:N2} → {net:N2} ({percent:+0.#;-0.#} %).");
        if (net == 0) warnings.Add($"{where}: neto cena je 0.");
        if (row.IsNew && vat is null) warnings.Add($"{where}: nova cena brez DDV — SAOP bo uporabil stopnjo artikla.");
        rows.Add(row);
      }
    }

    return new(rows, read, unchanged, problems, warnings, unknown, readOnly);
  }

  /* --- uvoz: vrsta za SAOP ------------------------------------------------------------------ */

  public async Task<PriceImportOutcome> ApplyAsync(PriceImportPreview preview, string actor, string? fileName,
    CancellationToken cancellationToken = default)
  {
    var batches = new List<(string, long?, PriceEnqueueOutcome)>();
    foreach (var organization in preview.Rows.GroupBy(row => (row.OrganizationId, row.OrganizationName)))
    {
      var changes = organization.Select(row => new PriceChange(row.PriceList, row.ItemId, row.NewNet, row.NewVat, row.ValidFrom, row.Active)).ToArray();
      var note = $"Uvoz cen{(string.IsNullOrWhiteSpace(fileName) ? "" : " " + fileName)}: {changes.Length:N0} cen";
      var outcome = await prices.EnqueueAsync(organization.Key.OrganizationId, changes, actor, "EXCEL", note, cancellationToken: cancellationToken);
      batches.Add((organization.Key.OrganizationName, outcome.BatchId, outcome));
    }
    return new(batches);
  }

  static int? ResolveOrganization(IReadOnlyDictionary<int, string> organizations, string text)
  {
    if (int.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out var id) && organizations.ContainsKey(id)) return id;
    foreach (var (key, name) in organizations)
      if (WorkbookHeader.Same(name, text)) return key;
    return null;
  }
}
