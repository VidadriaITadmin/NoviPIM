using Microsoft.Data.SqlClient;

namespace PIM.Intranet.Services;

public sealed record NavigationEntry(string GroupName, string Name, string Route, int GroupOrder, int ItemOrder);
public sealed record DashboardMetrics(long CanonProductCount, long PimProductCount, long ErpValidCount, long WebInvalidCount, long QuarantineCount);
public sealed record ProductRow(long ProductId, string ItemId, string? Ean, string Status, decimal Completeness);
public sealed record ValidationIssueRow(long ProductId, string ItemId, string ProfileCode, string IssueCode, string Message);
public sealed record PipelineRunRow(Guid RunId, string Pipeline, string? SourceCode, string Status, long RowsRead, long RowsSucceeded, long RowsFailed, DateTime StartedUtc, DateTime? EndedUtc);
public sealed record ProductDetailRow(string ItemId, string? Ean, string? ProfileCode, string? ProfileStatus, decimal? ProfileCompleteness);
public sealed record QuarantineRow(string SourceCode, string EntityType, int PageNumber, string? FailureReason, DateTime ReceivedUtc);
public sealed record StockRow(long PositionId, string? ItemId, string? Ean, decimal Quantity, DateTime? AvailabilityDate,
  decimal? IncomingQuantity, string SourceCode, DateTime SnapshotUtc, string MatchKey, string? ProviderKind,
  string Endpoint, int FreshnessMinutes, long? ProductId);

public sealed class IntranetDataService(IConfiguration configuration)
{
  string ConnectionString => configuration.GetConnectionString("Pim")
    ?? throw new InvalidOperationException("Povezava PIM ni nastavljena.");

  public async Task<IReadOnlyList<NavigationEntry>> GetNavigationAsync(IEnumerable<string> roles, CancellationToken cancellationToken = default)
  {
    var roleList = roles.Distinct(StringComparer.Ordinal).ToArray();
    if (roleList.Length == 0) return [];
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("""
      SELECT DISTINCT navigationGroup.Name, navigationItem.Name, navigationItem.Route, navigationGroup.SortOrder, navigationItem.SortOrder
      FROM sec.NavigationItem navigationItem
      INNER JOIN sec.NavigationGroup navigationGroup ON navigationGroup.NavigationGroupId = navigationItem.NavigationGroupId
      INNER JOIN sec.NavigationItemRole itemRole ON itemRole.NavigationItemId = navigationItem.NavigationItemId
      INNER JOIN sec.Role roleValue ON roleValue.RoleId = itemRole.RoleId
      WHERE navigationGroup.IsActive = 1 AND navigationItem.IsActive = 1 AND roleValue.RoleCode IN (@Role0, @Role1, @Role2)
      ORDER BY navigationGroup.SortOrder, navigationItem.SortOrder;
      """, connection);
    for (var index = 0; index < 3; index++) command.Parameters.AddWithValue($"@Role{index}", index < roleList.Length ? roleList[index] : string.Empty);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var rows = new List<NavigationEntry>();
    while (await reader.ReadAsync(cancellationToken)) rows.Add(new(reader.GetString(0), reader.GetString(1), reader.GetString(2), reader.GetInt32(3), reader.GetInt32(4)));
    return rows;
  }

  public async Task<DashboardMetrics> GetDashboardAsync(int organizationId, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("EXEC intranet.GetDashboard @OrganizationId;", connection);
    command.Parameters.AddWithValue("@OrganizationId", organizationId);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    if (!await reader.ReadAsync(cancellationToken)) throw new InvalidOperationException("Nadzorna plošča ni vrnila podatkov.");
    return new(reader.GetInt64(0), reader.GetInt64(1), reader.GetInt64(2), reader.GetInt64(3), reader.GetInt64(4));
  }

  public async Task<IReadOnlyList<ProductRow>> GetProductsAsync(int organizationId, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString); await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("EXEC intranet.GetProducts @OrganizationId, @Skip=0, @Take=100;", connection);
    command.Parameters.AddWithValue("@OrganizationId", organizationId);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken); var rows = new List<ProductRow>();
    while (await reader.ReadAsync(cancellationToken)) rows.Add(new(reader.GetInt64(0), reader.GetString(1), reader.IsDBNull(2) ? null : reader.GetString(2), reader.GetString(3), reader.GetDecimal(4)));
    return rows;
  }

  public async Task<IReadOnlyList<ValidationIssueRow>> GetValidationIssuesAsync(int organizationId, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString); await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("EXEC intranet.GetValidationIssues @OrganizationId;", connection); command.Parameters.AddWithValue("@OrganizationId", organizationId);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken); var rows = new List<ValidationIssueRow>();
    while (await reader.ReadAsync(cancellationToken)) rows.Add(new(reader.GetInt64(1), reader.GetString(2), reader.GetString(3), reader.GetString(4), reader.GetString(5)));
    return rows;
  }

  public async Task<IReadOnlyList<PipelineRunRow>> GetPipelineRunsAsync(int organizationId, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString); await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("EXEC intranet.GetPipelineRuns @OrganizationId;", connection); command.Parameters.AddWithValue("@OrganizationId", organizationId);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken); var rows = new List<PipelineRunRow>();
    while (await reader.ReadAsync(cancellationToken)) rows.Add(new(reader.GetGuid(0), reader.GetString(1), reader.IsDBNull(2) ? null : reader.GetString(2), reader.GetString(3), reader.GetInt64(4), reader.GetInt64(5), reader.GetInt64(6), reader.GetDateTime(7), reader.IsDBNull(8) ? null : reader.GetDateTime(8)));
    return rows;
  }

  public async Task<IReadOnlyList<ProductDetailRow>> GetProductDetailAsync(int organizationId, long productId, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString); await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("EXEC intranet.GetProductDetail @OrganizationId, @ProductId;", connection);
    command.Parameters.AddWithValue("@OrganizationId", organizationId); command.Parameters.AddWithValue("@ProductId", productId);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken); var rows = new List<ProductDetailRow>();
    while (await reader.ReadAsync(cancellationToken)) rows.Add(new(reader.GetString(1), reader.IsDBNull(2) ? null : reader.GetString(2), reader.IsDBNull(5) ? null : reader.GetString(5), reader.IsDBNull(6) ? null : reader.GetString(6), reader.IsDBNull(7) ? null : reader.GetDecimal(7)));
    return rows;
  }

  public async Task<IReadOnlyList<QuarantineRow>> GetQuarantineAsync(int organizationId, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString); await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("EXEC intranet.GetRawQuarantine @OrganizationId;", connection); command.Parameters.AddWithValue("@OrganizationId", organizationId);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken); var rows = new List<QuarantineRow>();
    while (await reader.ReadAsync(cancellationToken)) rows.Add(new(reader.GetString(2), reader.GetString(3), reader.GetInt32(4), reader.IsDBNull(5) ? null : reader.GetString(5), reader.GetDateTime(6)));
    return rows;
  }

  public async Task<IReadOnlyList<StockRow>> GetStocksAsync(int organizationId, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString); await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("EXEC intranet.GetStocks @OrganizationId;", connection); command.Parameters.AddWithValue("@OrganizationId", organizationId);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken); var rows = new List<StockRow>();
    while (await reader.ReadAsync(cancellationToken)) rows.Add(new(reader.GetInt64(0), reader.IsDBNull(1)?null:reader.GetString(1), reader.IsDBNull(2)?null:reader.GetString(2),
      reader.GetDecimal(3), reader.IsDBNull(4)?null:reader.GetDateTime(4), reader.IsDBNull(5)?null:reader.GetDecimal(5), reader.GetString(6), reader.GetDateTime(7),
      reader.GetString(8), reader.IsDBNull(9)?null:reader.GetString(9), reader.GetString(10), reader.GetInt32(11), reader.IsDBNull(12)?null:reader.GetInt64(12)));
    return rows;
  }
}
