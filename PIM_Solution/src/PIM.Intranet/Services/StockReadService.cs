using System.Data;
using Microsoft.Data.SqlClient;
using PIM.Operations;

namespace PIM.Intranet.Services;

/// <summary>
/// Ena vrstica na artikel (migracija 190): SAOP in dobaviteljev del združena, ne dve ločeni
/// vrstici. <c>Has*</c> loči "vira ni" (null/pomišljaj) od "vir pravi 0" (dejanska ničla).
/// </summary>
public sealed record StockItemRow(
  string GroupKey, int OrganizationId, string OrganizationName, string? NormalizedItemId, string? Ean,
  long? MatchedProductId, string? ProductName, string? ProductItemId,
  bool HasErp, string? ErpWarehouse, decimal ErpQuantity, decimal ErpAvailable, decimal ErpOrdered,
  decimal ErpForShipment, decimal ErpSupplierOrdered, decimal? ErpIncomingQuantity, DateTime? ErpIncomingDate, DateTime? ErpSnapshotUtc,
  bool HasSupplier, string? SupplierCode, decimal SupplierQuantity, decimal? SupplierIncoming, DateTime? SupplierIncomingDate, DateTime? SupplierSnapshotUtc,
  decimal? MinimumStock, decimal? MaximumStock);

public sealed record StockItemPage(IReadOnlyList<StockItemRow> Rows, long TotalCount);

/// <param name="OrganizationId">null pomeni vsa podjetja (migracija 134).</param>
public sealed record StockItemFilter(
  int? OrganizationId, int Skip = 0, int Take = 50, string? Search = null, string? SourceCode = null,
  string? Availability = null, int? MaxAgeHours = null, string Language = "sl");

public sealed record StockTotals(
  long PositionCount, long MatchedCount, long UnmatchedCount, long InStockCount,
  long OutOfStockCount, long IncomingCount, DateTime? OldestSnapshotUtc, DateTime? NewestSnapshotUtc);

public sealed record StockSourceRow(
  string SourceCode, string? ProviderKind, string? Endpoint, DateTime? SnapshotUtc,
  int? FreshnessMinutes, long PositionCount, long MatchedCount, long InStockCount);

public sealed record StockIssueRow(
  string ReasonCode, long PositionCount, DateTime FirstSeenUtc, DateTime LastSeenUtc, string? SampleDetail);

public sealed record StockOverview(
  StockTotals Totals, IReadOnlyList<StockSourceRow> Sources, IReadOnlyList<StockIssueRow> Issues);

/// <summary>
/// Bralni model zaloge. SQL ostane v oštevilčeni migraciji (103, 190).
///
/// Zaloga je namerno samo bralna: PIM je ne piše nazaj v ERP. To ni vrzel, ampak meja sistema,
/// zato tudi izpeljana težava nima gumba »reši« — izgine, ko izgine vzrok.
/// </summary>
public sealed class StockReadService(IConfiguration configuration)
{
  string ConnectionString => ConnectionStringResolver.Resolve(configuration)
    ?? throw new InvalidOperationException("Povezava PIM ni nastavljena.");

  /// <summary>
  /// Ena vrstica na artikel (migracija 190) — stranicenje teče nad že združenimi vrsticami, ne
  /// nad pozicijami, sicer bi SAOP in dobaviteljeva pozicija istega artikla padli na različni
  /// strani (intranet.GetStockPositions razvršča po viru najprej).
  /// </summary>
  public async Task<StockItemPage> GetItemsAsync(
    StockItemFilter filter, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.GetStockByItem", connection)
    {
      CommandType = CommandType.StoredProcedure,
      CommandTimeout = 60,
    };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = (object?)filter.OrganizationId ?? DBNull.Value;
    command.Parameters.Add("@Skip", SqlDbType.Int).Value = filter.Skip;
    command.Parameters.Add("@Take", SqlDbType.Int).Value = filter.Take;
    command.Parameters.Add("@Search", SqlDbType.NVarChar, 200).Value = Optional(filter.Search);
    command.Parameters.Add("@SourceCode", SqlDbType.NVarChar, 100).Value = Optional(filter.SourceCode);
    command.Parameters.Add("@Availability", SqlDbType.NVarChar, 20).Value = Optional(filter.Availability);
    command.Parameters.Add("@MaxAgeHours", SqlDbType.Int).Value = filter.MaxAgeHours is null ? DBNull.Value : filter.MaxAgeHours.Value;
    command.Parameters.Add("@Language", SqlDbType.NVarChar, 20).Value = filter.Language;

    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var rows = await ReadAsync(reader, row => new StockItemRow(
      PimDb.TextOrEmpty(row, "GroupKey"), PimDb.Int32(row, "OrganizationId"), PimDb.TextOrEmpty(row, "OrganizationName"),
      PimDb.Text(row, "NormalizedItemId"), PimDb.Text(row, "Ean"), PimDb.NullableInt64(row, "MatchedProductId"),
      PimDb.Text(row, "ProductName"), PimDb.Text(row, "ProductItemId"),
      PimDb.Int32(row, "HasErp") == 1, PimDb.Text(row, "ErpWarehouse"),
      PimDb.Decimal(row, "ErpQuantity"), PimDb.Decimal(row, "ErpAvailable"), PimDb.Decimal(row, "ErpOrdered"),
      PimDb.Decimal(row, "ErpForShipment"), PimDb.Decimal(row, "ErpSupplierOrdered"),
      PimDb.NullableDecimal(row, "ErpIncomingQuantity"), PimDb.NullableDateTime(row, "ErpIncomingDate"), PimDb.NullableDateTime(row, "ErpSnapshotUtc"),
      PimDb.Int32(row, "HasSupplier") == 1, PimDb.Text(row, "SupplierCode"), PimDb.Decimal(row, "SupplierQuantity"),
      PimDb.NullableDecimal(row, "SupplierIncoming"), PimDb.NullableDateTime(row, "SupplierIncomingDate"), PimDb.NullableDateTime(row, "SupplierSnapshotUtc"),
      PimDb.NullableDecimal(row, "MinimumStock"), PimDb.NullableDecimal(row, "MaximumStock")), cancellationToken);

    long total = 0;
    if (await reader.NextResultAsync(cancellationToken) && await reader.ReadAsync(cancellationToken))
      total = Convert.ToInt64(reader.GetValue(0));

    return new(rows, total);
  }

  /// <summary>Najdaljši Naziv, preden Excel stolpec postane nepregleden.</summary>
  const int NameMaxLength = 40;

  static string? Truncate(string? value) =>
    value is { Length: > NameMaxLength } ? value[..NameMaxLength] + "…" : value;

  /// <summary>Fizična meja lista .xlsx, ne poslovna — glej WorkbookTable.MaxRows (2026-09-17).</summary>
  const int MaxExportRows = PIM.Operations.WorkbookTable.MaxRows;

  /// <summary>
  /// Zvezek zaloge (.xlsx), en list, ena vrstica na artikel — isti vir kot tabela na strani
  /// (intranet.GetStockByItem, migracija 190), samo s slovenskimi imeni stolpcev in skrajšanim
  /// nazivom. Strani prebere zaporedoma, dokler ne zbere vsega ali doseže MaxExportRows.
  /// </summary>
  /// <param name="organizationId">null pomeni vsa podjetja — izvoz sledi popolnoma isti izbiri kot tabela.</param>
  public async Task<byte[]> BuildStockWorkbookAsync(
    int? organizationId, string? sourceCode, string? search, string? availability, int? maxAgeHours,
    CancellationToken cancellationToken = default)
  {
    // 20.000 = zgornja meja @Take v intranet.GetStockByItem (migracija 218; prej 200). Vsak klic
    // znova sestavi celotno #StockByItem, zato je bil izvoz z 2.000 (dejansko 200) na klic
    // desetine klicev in 44 s za eno podjetje; zdaj je en klic.
    const int PageSize = 20_000;
    var rows = new List<StockItemRow>();
    var skip = 0;
    while (rows.Count < MaxExportRows)
    {
      var page = await GetItemsAsync(
        new StockItemFilter(organizationId, skip, PageSize, search, sourceCode, availability, maxAgeHours), cancellationToken);
      rows.AddRange(page.Rows);
      if (page.Rows.Count == 0 || rows.Count >= page.TotalCount) break;
      skip += PageSize;
    }
    var truncated = rows.Count > MaxExportRows;
    if (truncated) rows = rows.Take(MaxExportRows).ToList();

    IReadOnlyList<WorkbookColumn> columns =
    [
      new("Šifra artikla", Width: 18), new("EAN", Width: 16), new("Naziv", Width: NameMaxLength + 4),
      new("Skladišče", Width: 24), new("SAOP količina", WorkbookCellKind.Number), new("SAOP razpoložljivo", WorkbookCellKind.Number),
      new("SAOP prihodna količina", WorkbookCellKind.Number), new("SAOP datum prihoda", Width: 18),
      new("Minimalna zaloga", WorkbookCellKind.Number), new("Maksimalna zaloga", WorkbookCellKind.Number),
      new("Dobavitelj", Width: 20), new("Dobaviteljeva količina", WorkbookCellKind.Number),
      new("Dobaviteljeva prihodna količina", WorkbookCellKind.Number), new("Dobaviteljev datum prihoda", Width: 18),
      new("Podjetje", Width: 16), new("SAOP posnetek", WorkbookCellKind.DateTime), new("Dobaviteljev posnetek", WorkbookCellKind.DateTime),
    ];

    var cells = rows.Select(row => (IReadOnlyList<object?>)new object?[]
    {
      row.ProductItemId ?? row.NormalizedItemId, row.Ean, Truncate(row.ProductName),
      row.HasErp ? row.ErpWarehouse : null, row.HasErp ? row.ErpQuantity : null, row.HasErp ? row.ErpAvailable : null,
      row.HasErp ? row.ErpIncomingQuantity : null, row.HasErp ? row.ErpIncomingDate : null,
      row.MinimumStock, row.MaximumStock,
      row.HasSupplier ? row.SupplierCode : null, row.HasSupplier ? row.SupplierQuantity : null,
      row.HasSupplier ? row.SupplierIncoming : null, row.HasSupplier ? row.SupplierIncomingDate : null,
      row.OrganizationName, row.HasErp ? row.ErpSnapshotUtc : null, row.HasSupplier ? row.SupplierSnapshotUtc : null,
    });

    IReadOnlyList<string>? notes = truncated ? [$"Zapisanih je prvih {MaxExportRows:N0} vrstic; datoteka je odrezana."] : null;
    return WorkbookWriter.Write("Zaloga", columns, cells, notes);
  }

  /// <param name="organizationId">null pomeni vsa podjetja (migracija 134).</param>
  public async Task<StockOverview> GetOverviewAsync(
    int? organizationId, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.GetStockOverview", connection)
    {
      CommandType = CommandType.StoredProcedure,
      CommandTimeout = 60,
    };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = (object?)organizationId ?? DBNull.Value;

    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var totals = new StockTotals(0, 0, 0, 0, 0, 0, null, null);
    if (await reader.ReadAsync(cancellationToken))
      totals = new(
        PimDb.Int64(reader, "PositionCount"), PimDb.Int64(reader, "MatchedCount"),
        PimDb.Int64(reader, "UnmatchedCount"), PimDb.Int64(reader, "InStockCount"),
        PimDb.Int64(reader, "OutOfStockCount"), PimDb.Int64(reader, "IncomingCount"),
        PimDb.NullableDateTime(reader, "OldestSnapshotUtc"), PimDb.NullableDateTime(reader, "NewestSnapshotUtc"));

    await NextAsync(reader, cancellationToken);
    var sources = await ReadAsync(reader, row => new StockSourceRow(
      PimDb.TextOrEmpty(row, "SourceCode"), PimDb.Text(row, "ProviderKind"), PimDb.Text(row, "Endpoint"),
      PimDb.NullableDateTime(row, "SnapshotUtc"), NullableInt32(row, "FreshnessMinutes"),
      PimDb.Int64(row, "PositionCount"), PimDb.Int64(row, "MatchedCount"),
      PimDb.Int64(row, "InStockCount")), cancellationToken);

    await NextAsync(reader, cancellationToken);
    var issues = await ReadAsync(reader, row => new StockIssueRow(
      PimDb.TextOrEmpty(row, "ReasonCode"), PimDb.Int64(row, "PositionCount"),
      PimDb.DateTimeValue(row, "FirstSeenUtc"), PimDb.DateTimeValue(row, "LastSeenUtc"),
      PimDb.Text(row, "SampleDetail")), cancellationToken);

    return new(totals, sources, issues);
  }

  static object Optional(string? value) =>
    string.IsNullOrWhiteSpace(value) ? DBNull.Value : value.Trim();

  static int? NullableInt32(SqlDataReader reader, string column)
  {
    var ordinal = reader.GetOrdinal(column);
    return reader.IsDBNull(ordinal) ? null : Convert.ToInt32(reader.GetValue(ordinal));
  }

  static async Task NextAsync(SqlDataReader reader, CancellationToken cancellationToken)
  {
    if (!await reader.NextResultAsync(cancellationToken))
      throw new InvalidOperationException("Bralna procedura zaloge ni vrnila vseh pogodbenih naborov.");
  }

  static async Task<IReadOnlyList<T>> ReadAsync<T>(
    SqlDataReader reader, Func<SqlDataReader, T> map, CancellationToken cancellationToken)
  {
    var rows = new List<T>();
    while (await reader.ReadAsync(cancellationToken)) rows.Add(map(reader));
    return rows;
  }
}
