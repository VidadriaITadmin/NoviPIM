using System.Data;
using Microsoft.Data.SqlClient;

namespace PIM.Intranet.Services;

public sealed record StockPositionRow(
  long PositionId, string? NormalizedItemId, string? Ean, decimal Quantity,
  DateTime? AvailabilityDate, decimal? IncomingQuantity, string? MatchKey, long? MatchedProductId,
  string? ProductName, string? ProductItemId, string SourceCode, string? SourceKind,
  int OrganizationId, string OrganizationName, string? ProviderKind,
  string? Endpoint, DateTime SnapshotUtc, int FreshnessMinutes,
  decimal? MinimumStock, decimal? MaximumStock, string? WarehouseCode,
  // Registrirani pogled SAOP (migracija 145); NULL pri virih, ki teh kolicin ne poznajo.
  decimal? OrderedQuantity = null, decimal? ForShipmentQuantity = null,
  decimal? AvailableQuantity = null, decimal? SupplierOrderedQuantity = null);

public sealed record StockPositionPage(IReadOnlyList<StockPositionRow> Rows, long TotalCount);

/// <param name="OrganizationId">null pomeni vsa podjetja (migracija 134).</param>
public sealed record StockPositionFilter(
  int? OrganizationId, int Skip = 0, int Take = 50, string? Search = null, string? SourceCode = null,
  string? Availability = null, string? Matched = null, int? MaxAgeHours = null, string Language = "sl",
  string? SourceKind = null);

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
/// Bralni model zaloge. SQL ostane v oštevilčeni migraciji (103).
///
/// Zaloga je namerno samo bralna: PIM je ne piše nazaj v ERP. To ni vrzel, ampak meja sistema,
/// zato tudi izpeljana težava nima gumba »reši« — izgine, ko izgine vzrok.
/// </summary>
public sealed class StockReadService(IConfiguration configuration)
{
  string ConnectionString => ConnectionStringResolver.Resolve(configuration)
    ?? throw new InvalidOperationException("Povezava PIM ni nastavljena.");

  public async Task<StockPositionPage> GetPositionsAsync(
    StockPositionFilter filter, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.GetStockPositions", connection)
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
    command.Parameters.Add("@Matched", SqlDbType.NVarChar, 20).Value = Optional(filter.Matched);
    command.Parameters.Add("@MaxAgeHours", SqlDbType.Int).Value = filter.MaxAgeHours is null ? DBNull.Value : filter.MaxAgeHours.Value;
    command.Parameters.Add("@Language", SqlDbType.NVarChar, 20).Value = filter.Language;
    command.Parameters.Add("@SourceKind", SqlDbType.NVarChar, 20).Value = Optional(filter.SourceKind);

    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var rows = await ReadAsync(reader, row => new StockPositionRow(
      PimDb.Int64(row, "PositionId"), PimDb.Text(row, "NormalizedItemId"), PimDb.Text(row, "Ean"),
      PimDb.Decimal(row, "Quantity"), PimDb.NullableDateTime(row, "AvailabilityDate"),
      PimDb.NullableDecimal(row, "IncomingQuantity"), PimDb.Text(row, "MatchKey"),
      PimDb.NullableInt64(row, "MatchedProductId"), PimDb.Text(row, "ProductName"),
      PimDb.Text(row, "ProductItemId"), PimDb.TextOrEmpty(row, "SourceCode"), PimDb.Text(row, "SourceKind"),
      PimDb.Int32(row, "OrganizationId"), PimDb.TextOrEmpty(row, "OrganizationName"),
      PimDb.Text(row, "ProviderKind"), PimDb.Text(row, "Endpoint"),
      PimDb.DateTimeValue(row, "SnapshotUtc"), PimDb.Int32(row, "FreshnessMinutes"),
      PimDb.NullableDecimal(row, "MinimumStock"), PimDb.NullableDecimal(row, "MaximumStock"),
      PimDb.Text(row, "WarehouseCode"),
      PimDb.NullableDecimal(row, "OrderedQuantity"), PimDb.NullableDecimal(row, "ForShipmentQuantity"),
      PimDb.NullableDecimal(row, "AvailableQuantity"), PimDb.NullableDecimal(row, "SupplierOrderedQuantity")), cancellationToken);

    long total = 0;
    if (await reader.NextResultAsync(cancellationToken) && await reader.ReadAsync(cancellationToken))
      total = Convert.ToInt64(reader.GetValue(0));

    return new(rows, total);
  }

  /// <summary>
  /// Pretocno zapise CSV zaloge podjetja iz out.GetStockExportRows (migracija 150): vir ERP,
  /// DOBAVITELJ ali VSE, po zelji samo izdelki na spletu. Glava je iz imen stolpcev procedure.
  /// </summary>
  public async Task<int> WriteStockCsvAsync(int organizationId, string source, bool onlyWeb, Stream body, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("out.GetStockExportRows", connection)
    {
      CommandType = CommandType.StoredProcedure, CommandTimeout = 300,
    };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@Source", SqlDbType.NVarChar, 20).Value = source;
    command.Parameters.Add("@OnlyWeb", SqlDbType.Bit).Value = onlyWeb;
    command.Parameters.Add("@Skip", SqlDbType.Int).Value = 0;
    command.Parameters.Add("@Take", SqlDbType.Int).Value = 0;
    command.Parameters.Add("@TotalCount", SqlDbType.Int).Direction = ParameterDirection.Output;

    await using var reader = await command.ExecuteReaderAsync(CommandBehavior.SequentialAccess, cancellationToken);
    await using var writer = new StreamWriter(body, new System.Text.UTF8Encoding(true), leaveOpen: true);
    var headers = Enumerable.Range(0, reader.FieldCount).Select(reader.GetName).ToArray();
    await writer.WriteLineAsync(string.Join(';', headers.Select(WebExportBuildService.Escape)));
    var written = 0;
    while (await reader.ReadAsync(cancellationToken))
    {
      var values = new string?[reader.FieldCount];
      for (var index = 0; index < values.Length; index++)
        values[index] = await reader.IsDBNullAsync(index, cancellationToken) ? null : Convert.ToString(reader.GetValue(index), System.Globalization.CultureInfo.InvariantCulture);
      await writer.WriteLineAsync(string.Join(';', values.Select(WebExportBuildService.Escape)));
      written++;
    }
    await writer.FlushAsync(cancellationToken);
    return written;
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
