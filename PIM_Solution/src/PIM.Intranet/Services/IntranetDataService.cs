using Microsoft.Data.SqlClient;

namespace PIM.Intranet.Services;

public sealed record NavigationEntry(string GroupName, string Name, string Route, int GroupOrder, int ItemOrder);
public sealed record OrganizationContext(int OrganizationId, string Name);
public sealed record DashboardMetrics(long CanonProductCount, long PimProductCount, long ErpValidCount, long WebInvalidCount, long QuarantineCount);
public sealed record ProductRow(long ProductId, string ItemId, string? Ean, string Status, decimal Completeness);
public sealed record ProductPage(IReadOnlyList<ProductRow> Rows, long TotalCount, int Skip, int Take);
public sealed record ValidationIssueRow(long ProductIssueId, long ProductId, string ItemId, string ProfileCode, string IssueCode, string Message, DateTime LastDetectedUtc);
public sealed record QualityProfileRow(string ProfileCode, long ProductCount, long ValidCount, long InvalidCount, decimal? AverageCompleteness);
public sealed record FrequentIssueRow(string IssueCode, string Message, long OccurrenceCount);
public sealed record QualityView(IReadOnlyList<ValidationIssueRow> Issues, IReadOnlyList<QualityProfileRow> Profiles, IReadOnlyList<FrequentIssueRow> FrequentIssues);
public sealed record PipelineRunRow(Guid RunId, string Pipeline, string? SourceCode, string Status, long RowsRead, long RowsSucceeded, long RowsFailed, DateTime StartedUtc, DateTime? EndedUtc);
public sealed record ProductDetailHeader(long ProductId, string ItemId, string? Ean, string Status, decimal Completeness, bool IsActive, bool WebPublish, string? Uom, string? ItemGroup, string? Department, string? Manufacturer, string? Supplier, DateTime? LastValidatedUtc);
public sealed record ProductProfileRow(string ProfileCode, string Status, decimal Completeness, DateTime ValidatedUtc);
public sealed record ProductIssueRow(long ProductIssueId, string ProfileCode, string IssueCode, string Message, DateTime FirstDetectedUtc, DateTime LastDetectedUtc);
public sealed record ProductHistoryRow(long ChangeId, long ChangeBatchId, string FieldKey, string Owner, string? OldValue, string? NewValue, DateTime ChangedAtUtc, string ChangeSource, string ChangedBy, string? Note, DateTime? SentToSaopAtUtc);
public sealed record ProductDetailView(ProductDetailHeader Header, IReadOnlyList<ProductProfileRow> Profiles, IReadOnlyList<ProductIssueRow> Issues, IReadOnlyList<ProductHistoryRow> History);
public sealed record QuarantineRow(long InboxId, Guid RunId, string SourceCode, string EntityType, int PageNumber, string? FailureReason, DateTime ReceivedUtc);
public sealed record StockRow(long PositionId, string? ItemId, string? Ean, decimal Quantity, DateTime? AvailabilityDate,
  decimal? IncomingQuantity, string SourceCode, DateTime SnapshotUtc, string MatchKey, string? ProviderKind,
  string Endpoint, int FreshnessMinutes, long? ProductId);
public sealed record CustomerRow(long CustomerId, string CustomerKey, string Name, string? CustomerKind, string? CustomerType, string? MagentoGroupKey, bool WebEnabled, bool PackagingDiscountEnabled, bool ValueDiscountEnabled, bool B2bPlusEnabled);
public sealed record CustomerDetailRow(long CustomerId, string CustomerKey, string Name, string? PayerCode, string? PayerName, string? PriceListCode, string? DiscountPriceListCode, string? CustomerTypeCode, string? CustomerKind, bool PackagingDiscountEnabled, bool ValueDiscountEnabled, bool B2bPlusEnabled, DateTime? B2bPlusValidFrom, DateTime? B2bPlusValidTo, bool WebEnabled, string? MagentoGroupKey);
public sealed record CustomerTypeRow(string CustomerTypeCode, string Name, string? MagentoGroupKey);
public sealed record ValueTierRow(byte TierNumber, decimal ThresholdGrossExVat, decimal PercentValue);
public sealed record GroupOverrideRow(long OverrideId, string TargetKind, string? CustomerKey, string? CustomerTypeCode, string ItemGroupCode, decimal PercentValue, DateTime? ValidFrom, DateTime? ValidTo);
public sealed record OutboundRow(long OutboxMessageId, string TargetKind, string Operation, string EntityType, string EntityKey,
  string FieldSummary, string DedupKey, string Status, int AttemptCount, DateTime? NextAttemptUtc,
  int? ResponseStatusCode, string? ResponseCorrelationId, string? DriftDetail, DateTime CreatedUtc);
/// <param name="IntervalSeconds">Kako pogosto naj postopek tece; ura v Windows tiktaka na 5 minut.</param>
/// <param name="NextScheduledUtc">Kdaj je postopek naslednjic na vrsti; null pomeni takoj.</param>
public sealed record ScheduleRow(
  int OrganizationId, string OrganizationName, string Provider, string Pipeline,
  bool IsEnabled, int IntervalSeconds, int StaleAfterSeconds, DateTime? NextScheduledUtc,
  DateTime? UpdatedUtc, string? UpdatedBy, string? Status,
  DateTime? LastHeartbeatUtc, DateTime? LastSuccessfulRunUtc, DateTime? LastFailedRunUtc,
  string? LastErrorRedacted);

public sealed record SystemIntegrationRow(int OrganizationId, string OrganizationCode, string Provider, string Pipeline, bool IsEnabled,
  string? Status, DateTime? LastHeartbeatUtc, DateTime? LastSuccessfulRunUtc, DateTime? LastFailedRunUtc, DateTime? WatermarkUtc,
  DateTime? NextScheduledUtc, int OpenAlerts, int OutboxDeadCount, int OutboxDriftCount);
public sealed record SystemAlertRow(long AlertId, string Pipeline, string AlertKind, string Severity, string Title,
  string PayloadSummaryRedacted, int OccurrenceCount, DateTime FirstSeenUtc, DateTime LastSeenUtc,
  DateTime? AcknowledgedUtc, string? AcknowledgedBy, DateTime? ResolvedUtc, string? ResolvedBy);
public sealed record SystemIntegrationView(IReadOnlyList<SystemIntegrationRow> Integrations, IReadOnlyList<SystemAlertRow> Alerts);
public sealed class ShippingRuleRow
{
  public required string RuleCode { get; init; }
  public decimal? OrderThreshold { get; set; }
  public decimal? PackageLengthMeters { get; set; }
  public decimal ShippingNet { get; set; }
  public bool IsFree { get; set; }
  public int Priority { get; set; }
}

public sealed class IntranetDataService(IConfiguration configuration)
{
  string ConnectionString => ConnectionStringResolver.Resolve(configuration)
    ?? throw new InvalidOperationException("Povezava PIM ni nastavljena.");

  /// <summary>
  /// Privzeta aktivna organizacija aplikacije. Globalnega preklopnika organizacije ni vec;
  /// vecorganizacijski pogledi izbiro ponudijo lokalno samo tam, kjer je poslovno smiselna.
  /// </summary>
  public async Task<OrganizationContext?> GetCurrentOrganizationAsync(CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("""
      SELECT TOP (1) OrganizationId, Name FROM dbo.OrganizationConfig
      WHERE IsActive = 1
      ORDER BY OrganizationId;
      """, connection);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    return await reader.ReadAsync(cancellationToken)
      ? new(reader.GetInt32(reader.GetOrdinal("OrganizationId")), reader.GetString(reader.GetOrdinal("Name")))
      : null;
  }

  /// <summary>
  /// Vsa aktivna podjetja za lokalni filter na strani. Vecorganizacijski pogledi privzeto
  /// prikazejo vsa; brez tega seznama je edina izbira <see cref="GetCurrentOrganizationAsync"/>,
  /// ki vedno vrne prvo po sifri in zato pokaze samo eno podjetje.
  /// </summary>
  public async Task<IReadOnlyList<OrganizationContext>> GetOrganizationsAsync(CancellationToken cancellationToken = default)
  {
    var rows = new List<OrganizationContext>();
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand(
      "SELECT OrganizationId, Name FROM dbo.OrganizationConfig WHERE IsActive = 1 ORDER BY OrganizationId;", connection);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    while (await reader.ReadAsync(cancellationToken))
      rows.Add(new(reader.GetInt32(reader.GetOrdinal("OrganizationId")), reader.GetString(reader.GetOrdinal("Name"))));

    return rows;
  }

  /// <summary>
  /// Podjetje, ki mu izdelek pripada. Kartica izdelka je dosegljiva iz seznama vseh podjetij,
  /// zato obseg ne sme priti iz <see cref="GetCurrentOrganizationAsync"/> — ta vrne vedno prvo
  /// podjetje in kartica tujega izdelka bi bila prazna.
  /// </summary>
  public async Task<OrganizationContext?> GetProductOrganizationAsync(long productId, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("""
      SELECT TOP (1) product.OrganizationId, Name = COALESCE(organizationValue.Name, CONVERT(nvarchar(200), product.OrganizationId))
      FROM canon.Product AS product
      LEFT JOIN dbo.OrganizationConfig AS organizationValue ON organizationValue.OrganizationId = product.OrganizationId
      WHERE product.ProductId = @ProductId;
      """, connection);
    command.Parameters.AddWithValue("@ProductId", productId);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    return await reader.ReadAsync(cancellationToken)
      ? new(reader.GetInt32(reader.GetOrdinal("OrganizationId")), reader.GetString(reader.GetOrdinal("Name")))
      : null;
  }

  public async Task<int> GetOpenAlertCountAsync(int organizationId, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand(
      "SELECT COUNT_BIG(*) FROM ops.Alert WHERE OrganizationId = @OrganizationId AND ResolvedUtc IS NULL;", connection);
    command.Parameters.AddWithValue("@OrganizationId", organizationId);
    return Convert.ToInt32(await command.ExecuteScalarAsync(cancellationToken));
  }

  public async Task<IReadOnlyList<NavigationEntry>> GetNavigationAsync(IEnumerable<string> roles, CancellationToken cancellationToken = default)
  {
    var roleList = roles.Distinct(StringComparer.Ordinal).ToArray();
    if (roleList.Length == 0) return [];
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    var parameterNames = roleList.Select((_, index) => $"@Role{index}").ToArray();
    await using var command = new SqlCommand($"""
      SELECT DISTINCT navigationGroup.Name, navigationItem.Name, navigationItem.Route, navigationGroup.SortOrder, navigationItem.SortOrder
      FROM sec.NavigationItem navigationItem
      INNER JOIN sec.NavigationGroup navigationGroup ON navigationGroup.NavigationGroupId = navigationItem.NavigationGroupId
      INNER JOIN sec.NavigationItemRole itemRole ON itemRole.NavigationItemId = navigationItem.NavigationItemId
      INNER JOIN sec.Role roleValue ON roleValue.RoleId = itemRole.RoleId
      WHERE navigationGroup.IsActive = 1 AND navigationItem.IsActive = 1 AND roleValue.RoleCode IN ({string.Join(", ", parameterNames)})
      ORDER BY navigationGroup.SortOrder, navigationItem.SortOrder;
      """, connection);
    for (var index = 0; index < roleList.Length; index++) command.Parameters.AddWithValue(parameterNames[index], roleList[index]);
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
    return new(
      Convert.ToInt64(reader.GetValue(reader.GetOrdinal("CanonProductCount"))),
      Convert.ToInt64(reader.GetValue(reader.GetOrdinal("PimProductCount"))),
      Convert.ToInt64(reader.GetValue(reader.GetOrdinal("ErpValidCount"))),
      Convert.ToInt64(reader.GetValue(reader.GetOrdinal("WebInvalidCount"))),
      Convert.ToInt64(reader.GetValue(reader.GetOrdinal("QuarantineCount"))));
  }

  public async Task<ProductPage> GetProductsAsync(int organizationId, int skip = 0, int take = 50, string? search = null, string? status = null, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString); await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("EXEC intranet.GetProducts @OrganizationId, @Skip, @Take, @Search, @Status;", connection);
    command.Parameters.AddWithValue("@OrganizationId", organizationId);
    command.Parameters.AddWithValue("@Skip", skip); command.Parameters.AddWithValue("@Take", take);
    command.Parameters.AddWithValue("@Search", (object?)search ?? DBNull.Value); command.Parameters.AddWithValue("@Status", (object?)status ?? DBNull.Value);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken); var rows = new List<ProductRow>();
    while (await reader.ReadAsync(cancellationToken)) rows.Add(new(reader.GetInt64(reader.GetOrdinal("ProductId")), reader.GetString(reader.GetOrdinal("ItemId")), GetNullableString(reader, "Ean"), reader.GetString(reader.GetOrdinal("Status")), reader.GetDecimal(reader.GetOrdinal("Completeness"))));
    long totalCount = 0;
    if (await reader.NextResultAsync(cancellationToken) && await reader.ReadAsync(cancellationToken)) totalCount = Convert.ToInt64(reader["TotalCount"]);
    return new(rows, totalCount, skip, take);
  }

  public async Task<QualityView> GetValidationIssuesAsync(int organizationId, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString); await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("EXEC intranet.GetValidationIssues @OrganizationId;", connection); command.Parameters.AddWithValue("@OrganizationId", organizationId);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken); var rows = new List<ValidationIssueRow>();
    while (await reader.ReadAsync(cancellationToken)) rows.Add(new(reader.GetInt64(reader.GetOrdinal("ProductIssueId")), reader.GetInt64(reader.GetOrdinal("ProductId")), reader.GetString(reader.GetOrdinal("ItemId")), reader.GetString(reader.GetOrdinal("ProfileCode")), reader.GetString(reader.GetOrdinal("IssueCode")), reader.GetString(reader.GetOrdinal("Message")), reader.GetDateTime(reader.GetOrdinal("LastDetectedUtc"))));
    var profiles = new List<QualityProfileRow>();
    if (await reader.NextResultAsync(cancellationToken)) while (await reader.ReadAsync(cancellationToken)) profiles.Add(new(reader.GetString(reader.GetOrdinal("ProfileCode")), Convert.ToInt64(reader["ProductCount"]), Convert.ToInt64(reader["ValidCount"]), Convert.ToInt64(reader["InvalidCount"]), reader.IsDBNull(reader.GetOrdinal("AverageCompleteness")) ? null : reader.GetDecimal(reader.GetOrdinal("AverageCompleteness"))));
    var frequent = new List<FrequentIssueRow>();
    if (await reader.NextResultAsync(cancellationToken)) while (await reader.ReadAsync(cancellationToken)) frequent.Add(new(reader.GetString(reader.GetOrdinal("IssueCode")), reader.GetString(reader.GetOrdinal("Message")), Convert.ToInt64(reader["OccurrenceCount"])));
    return new(rows, profiles, frequent);
  }

  public async Task<IReadOnlyList<PipelineRunRow>> GetPipelineRunsAsync(int organizationId, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString); await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("EXEC intranet.GetPipelineRuns @OrganizationId;", connection); command.Parameters.AddWithValue("@OrganizationId", organizationId);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken); var rows = new List<PipelineRunRow>();
    while (await reader.ReadAsync(cancellationToken)) rows.Add(new(reader.GetGuid(0), reader.GetString(1), reader.IsDBNull(2) ? null : reader.GetString(2), reader.GetString(3), reader.GetInt64(4), reader.GetInt64(5), reader.GetInt64(6), reader.GetDateTime(7), reader.IsDBNull(8) ? null : reader.GetDateTime(8)));
    return rows;
  }

  public async Task<ProductDetailView?> GetProductDetailAsync(int organizationId, long productId, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString); await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("EXEC intranet.GetProductDetail @OrganizationId, @ProductId;", connection);
    command.Parameters.AddWithValue("@OrganizationId", organizationId); command.Parameters.AddWithValue("@ProductId", productId);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    if (!await reader.ReadAsync(cancellationToken)) return null;
    var header = new ProductDetailHeader(reader.GetInt64(reader.GetOrdinal("ProductId")), reader.GetString(reader.GetOrdinal("ItemId")), GetNullableString(reader,"Ean"), reader.GetString(reader.GetOrdinal("Status")), reader.GetDecimal(reader.GetOrdinal("Completeness")), reader.GetBoolean(reader.GetOrdinal("IsActive")), reader.GetBoolean(reader.GetOrdinal("WebPublish")), GetNullableString(reader,"Uom"), GetNullableString(reader,"ItemGroup"), GetNullableString(reader,"Department"), GetNullableString(reader,"Manufacturer"), GetNullableString(reader,"Supplier"), GetNullableDateTime(reader,"LastValidatedUtc"));
    var profiles = new List<ProductProfileRow>();
    if (await reader.NextResultAsync(cancellationToken)) while (await reader.ReadAsync(cancellationToken)) profiles.Add(new(reader.GetString(reader.GetOrdinal("ProfileCode")), reader.GetString(reader.GetOrdinal("Status")), reader.GetDecimal(reader.GetOrdinal("Completeness")), reader.GetDateTime(reader.GetOrdinal("ValidatedUtc"))));
    var issues = new List<ProductIssueRow>();
    if (await reader.NextResultAsync(cancellationToken)) while (await reader.ReadAsync(cancellationToken)) issues.Add(new(reader.GetInt64(reader.GetOrdinal("ProductIssueId")), reader.GetString(reader.GetOrdinal("ProfileCode")), reader.GetString(reader.GetOrdinal("IssueCode")), reader.GetString(reader.GetOrdinal("Message")), reader.GetDateTime(reader.GetOrdinal("FirstDetectedUtc")), reader.GetDateTime(reader.GetOrdinal("LastDetectedUtc"))));
    await reader.NextResultAsync(cancellationToken);
    var history = new List<ProductHistoryRow>();
    while (await reader.ReadAsync(cancellationToken)) history.Add(new(reader.GetInt64(reader.GetOrdinal("ChangeId")), reader.GetInt64(reader.GetOrdinal("ChangeBatchId")), reader.GetString(reader.GetOrdinal("FieldKey")), reader.GetString(reader.GetOrdinal("Owner")), GetNullableString(reader, "OldValue"), GetNullableString(reader, "NewValue"), reader.GetDateTime(reader.GetOrdinal("ChangedAtUtc")), reader.GetString(reader.GetOrdinal("ChangeSource")), reader.GetString(reader.GetOrdinal("ChangedBy")), GetNullableString(reader, "Note"), GetNullableDateTime(reader, "SentToSaopAtUtc")));
    return new(header, profiles, issues, history);
  }

  public async Task<IReadOnlyList<QuarantineRow>> GetQuarantineAsync(int organizationId, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString); await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("EXEC intranet.GetRawQuarantine @OrganizationId;", connection); command.Parameters.AddWithValue("@OrganizationId", organizationId);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken); var rows = new List<QuarantineRow>();
    while (await reader.ReadAsync(cancellationToken)) rows.Add(new(reader.GetInt64(reader.GetOrdinal("InboxId")), reader.GetGuid(reader.GetOrdinal("RunId")), reader.GetString(reader.GetOrdinal("SourceCode")), reader.GetString(reader.GetOrdinal("EntityType")), reader.GetInt32(reader.GetOrdinal("PageNumber")), GetNullableString(reader,"FailureReason"), reader.GetDateTime(reader.GetOrdinal("ReceivedUtc"))));
    return rows;
  }

  static string? GetNullableString(SqlDataReader reader, string name) { var ordinal = reader.GetOrdinal(name); return reader.IsDBNull(ordinal) ? null : reader.GetString(ordinal); }
  static DateTime? GetNullableDateTime(SqlDataReader reader, string name) { var ordinal = reader.GetOrdinal(name); return reader.IsDBNull(ordinal) ? null : reader.GetDateTime(ordinal); }

  public async Task<IReadOnlyList<StockRow>> GetStocksAsync(int organizationId, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString); await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("EXEC intranet.GetStocks @OrganizationId;", connection); command.Parameters.AddWithValue("@OrganizationId", organizationId);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken); var rows = new List<StockRow>();
    while (await reader.ReadAsync(cancellationToken)) rows.Add(new(
      reader.GetInt64(reader.GetOrdinal("PositionId")),
      GetNullableString(reader, "NormalizedItemId"),
      GetNullableString(reader, "Ean"),
      reader.GetDecimal(reader.GetOrdinal("Quantity")),
      GetNullableDateTime(reader, "AvailabilityDate"),
      reader.IsDBNull(reader.GetOrdinal("IncomingQuantity")) ? null : reader.GetDecimal(reader.GetOrdinal("IncomingQuantity")),
      reader.GetString(reader.GetOrdinal("SourceCode")),
      reader.GetDateTime(reader.GetOrdinal("SnapshotUtc")),
      reader.GetString(reader.GetOrdinal("MatchKey")),
      GetNullableString(reader, "ProviderKind"),
      reader.GetString(reader.GetOrdinal("Endpoint")),
      reader.GetInt32(reader.GetOrdinal("FreshnessMinutes")),
      reader.IsDBNull(reader.GetOrdinal("MatchedProductId")) ? null : reader.GetInt64(reader.GetOrdinal("MatchedProductId"))));
    return rows;
  }

  public async Task<IReadOnlyList<CustomerRow>> GetCustomersAsync(int organizationId, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString); await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("EXEC intranet.GetCustomers @OrganizationId;", connection); command.Parameters.AddWithValue("@OrganizationId", organizationId);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken); var rows = new List<CustomerRow>();
    while (await reader.ReadAsync(cancellationToken)) rows.Add(new(reader.GetInt64(0),reader.GetString(1),reader.GetString(2),reader.IsDBNull(3)?null:reader.GetString(3),reader.IsDBNull(4)?null:reader.GetString(4),reader.IsDBNull(5)?null:reader.GetString(5),!reader.IsDBNull(6)&&reader.GetBoolean(6),!reader.IsDBNull(7)&&reader.GetBoolean(7),!reader.IsDBNull(8)&&reader.GetBoolean(8),!reader.IsDBNull(9)&&reader.GetBoolean(9)));
    return rows;
  }

  public async Task<CustomerDetailRow?> GetCustomerDetailAsync(int organizationId, long customerId, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString); await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("EXEC intranet.GetCustomerDetail @OrganizationId,@CustomerId;", connection); command.Parameters.AddWithValue("@OrganizationId",organizationId);command.Parameters.AddWithValue("@CustomerId",customerId);
    await using var reader=await command.ExecuteReaderAsync(cancellationToken);if(!await reader.ReadAsync(cancellationToken))return null;
    return new(reader.GetInt64(0),reader.GetString(1),reader.GetString(2),reader.IsDBNull(3)?null:reader.GetString(3),reader.IsDBNull(4)?null:reader.GetString(4),reader.IsDBNull(5)?null:reader.GetString(5),reader.IsDBNull(6)?null:reader.GetString(6),reader.IsDBNull(7)?null:reader.GetString(7),reader.IsDBNull(8)?null:reader.GetString(8),reader.GetBoolean(9),reader.GetBoolean(10),reader.GetBoolean(11),reader.IsDBNull(12)?null:reader.GetDateTime(12),reader.IsDBNull(13)?null:reader.GetDateTime(13),reader.GetBoolean(14),reader.IsDBNull(15)?null:reader.GetString(15));
  }

  public async Task SaveCustomerWebProfileAsync(int organizationId, CustomerDetailRow row, string changedBy, CancellationToken cancellationToken = default)
  {
    await using var connection=new SqlConnection(ConnectionString);await connection.OpenAsync(cancellationToken);
    await using var command=new SqlCommand("EXEC b2b.SaveCustomerWebProfile @OrganizationId,@CustomerId,@CustomerTypeCode,@CustomerKind,@PackagingDiscountEnabled,@ValueDiscountEnabled,@B2bPlusEnabled,@B2bPlusValidFrom,@B2bPlusValidTo,@WebEnabled,@ChangedBy;",connection);
    command.Parameters.AddWithValue("@OrganizationId",organizationId);command.Parameters.AddWithValue("@CustomerId",row.CustomerId);command.Parameters.AddWithValue("@CustomerTypeCode",(object?)row.CustomerTypeCode??DBNull.Value);command.Parameters.AddWithValue("@CustomerKind",(object?)row.CustomerKind??DBNull.Value);command.Parameters.AddWithValue("@PackagingDiscountEnabled",row.PackagingDiscountEnabled);command.Parameters.AddWithValue("@ValueDiscountEnabled",row.ValueDiscountEnabled);command.Parameters.AddWithValue("@B2bPlusEnabled",row.B2bPlusEnabled);command.Parameters.AddWithValue("@B2bPlusValidFrom",(object?)row.B2bPlusValidFrom?.Date??DBNull.Value);command.Parameters.AddWithValue("@B2bPlusValidTo",(object?)row.B2bPlusValidTo?.Date??DBNull.Value);command.Parameters.AddWithValue("@WebEnabled",row.WebEnabled);command.Parameters.AddWithValue("@ChangedBy",changedBy);
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  public async Task<IReadOnlyList<ShippingRuleRow>> GetShippingRulesAsync(CancellationToken cancellationToken=default)
  {
    await using var connection=new SqlConnection(ConnectionString);await connection.OpenAsync(cancellationToken);await using var command=new SqlCommand("EXEC intranet.GetDiscountRules;",connection);await using var reader=await command.ExecuteReaderAsync(cancellationToken);var rows=new List<ShippingRuleRow>();while(await reader.ReadAsync(cancellationToken))rows.Add(new(){RuleCode=reader.GetString(0),OrderThreshold=reader.IsDBNull(1)?null:reader.GetDecimal(1),PackageLengthMeters=reader.IsDBNull(2)?null:reader.GetDecimal(2),ShippingNet=reader.GetDecimal(3),IsFree=reader.GetBoolean(4),Priority=reader.GetInt32(5)});return rows;
  }

  public async Task<IReadOnlyList<CustomerTypeRow>> GetCustomerTypesAsync(CancellationToken cancellationToken=default)
  {
    await using var connection=new SqlConnection(ConnectionString);await connection.OpenAsync(cancellationToken);await using var command=new SqlCommand("EXEC intranet.GetCustomerTypes;",connection);await using var reader=await command.ExecuteReaderAsync(cancellationToken);var rows=new List<CustomerTypeRow>();while(await reader.ReadAsync(cancellationToken))rows.Add(new(reader.GetString(0),reader.GetString(1),reader.IsDBNull(2)?null:reader.GetString(2)));return rows;
  }

  public async Task<IReadOnlyList<ValueTierRow>> GetValueTiersAsync(CancellationToken cancellationToken=default)
  {
    await using var connection=new SqlConnection(ConnectionString);await connection.OpenAsync(cancellationToken);await using var command=new SqlCommand("EXEC intranet.GetValueDiscountTiers;",connection);await using var reader=await command.ExecuteReaderAsync(cancellationToken);var rows=new List<ValueTierRow>();while(await reader.ReadAsync(cancellationToken))rows.Add(new(reader.GetByte(0),reader.GetDecimal(1),reader.GetDecimal(2)));return rows;
  }

  public async Task<IReadOnlyList<GroupOverrideRow>> GetGroupOverridesAsync(int organizationId,CancellationToken cancellationToken=default)
  {
    await using var connection=new SqlConnection(ConnectionString);await connection.OpenAsync(cancellationToken);await using var command=new SqlCommand("EXEC intranet.GetGroupDiscountOverrides @OrganizationId;",connection);command.Parameters.AddWithValue("@OrganizationId",organizationId);await using var reader=await command.ExecuteReaderAsync(cancellationToken);var rows=new List<GroupOverrideRow>();while(await reader.ReadAsync(cancellationToken))rows.Add(new(reader.GetInt64(0),reader.GetString(1),reader.IsDBNull(2)?null:reader.GetString(2),reader.IsDBNull(3)?null:reader.GetString(3),reader.GetString(4),reader.GetDecimal(5),reader.IsDBNull(6)?null:reader.GetDateTime(6),reader.IsDBNull(7)?null:reader.GetDateTime(7)));return rows;
  }

  public async Task SaveShippingRuleAsync(int organizationId, ShippingRuleRow row, string changedBy, CancellationToken cancellationToken=default)
  {
    await using var connection=new SqlConnection(ConnectionString);await connection.OpenAsync(cancellationToken);await using var command=new SqlCommand("EXEC b2b.SaveDiscountRule @OrganizationId,@RuleCode,@OrderThreshold,@PackageLengthMeters,@ShippingNet,@IsFree,@Priority,@ChangedBy;",connection);command.Parameters.AddWithValue("@OrganizationId",organizationId);command.Parameters.AddWithValue("@RuleCode",row.RuleCode);command.Parameters.AddWithValue("@OrderThreshold",(object?)row.OrderThreshold??DBNull.Value);command.Parameters.AddWithValue("@PackageLengthMeters",(object?)row.PackageLengthMeters??DBNull.Value);command.Parameters.AddWithValue("@ShippingNet",row.ShippingNet);command.Parameters.AddWithValue("@IsFree",row.IsFree);command.Parameters.AddWithValue("@Priority",row.Priority);command.Parameters.AddWithValue("@ChangedBy",changedBy);await command.ExecuteNonQueryAsync(cancellationToken);
  }

  public async Task SaveCustomerTypeMappingAsync(int organizationId,string typeCode,string? groupKey,string changedBy,CancellationToken cancellationToken=default)
  {
    await ExecuteCommercialAsync("EXEC b2b.SaveCustomerTypeMapping @OrganizationId,@CustomerTypeCode,@MagentoGroupKey,@ChangedBy;",organizationId,changedBy,command=>{command.Parameters.AddWithValue("@CustomerTypeCode",typeCode);command.Parameters.AddWithValue("@MagentoGroupKey",(object?)groupKey??DBNull.Value);},cancellationToken);
  }
  public async Task SaveCustomerValueTierAsync(int organizationId,long customerId,int tierNumber,decimal threshold,decimal percent,string changedBy,CancellationToken cancellationToken=default)
  {
    await ExecuteCommercialAsync("EXEC b2b.SaveCustomerValueTier @OrganizationId,@CustomerId,@TierNumber,@ThresholdGrossExVat,@PercentValue,@ChangedBy;",organizationId,changedBy,command=>{command.Parameters.AddWithValue("@CustomerId",customerId);command.Parameters.AddWithValue("@TierNumber",tierNumber);command.Parameters.AddWithValue("@ThresholdGrossExVat",threshold);command.Parameters.AddWithValue("@PercentValue",percent);},cancellationToken);
  }
  public async Task SaveValueTierAsync(int organizationId,int tierNumber,decimal threshold,decimal percent,string changedBy,CancellationToken cancellationToken=default)
  {
    await ExecuteCommercialAsync("EXEC b2b.SaveValueDiscountTier @OrganizationId,@TierNumber,@ThresholdGrossExVat,@PercentValue,@ChangedBy;",organizationId,changedBy,command=>{command.Parameters.AddWithValue("@TierNumber",tierNumber);command.Parameters.AddWithValue("@ThresholdGrossExVat",threshold);command.Parameters.AddWithValue("@PercentValue",percent);},cancellationToken);
  }
  public async Task SaveGroupOverrideAsync(int organizationId,string targetKind,long? customerId,string? typeCode,string itemGroup,decimal percent,DateTime? validFrom,DateTime? validTo,string changedBy,CancellationToken cancellationToken=default)
  {
    await ExecuteCommercialAsync("EXEC b2b.SaveGroupDiscountOverride @OrganizationId,@TargetKind,@CustomerId,@CustomerTypeCode,@ItemGroupCode,@PercentValue,@ValidFrom,@ValidTo,@ChangedBy;",organizationId,changedBy,command=>{command.Parameters.AddWithValue("@TargetKind",targetKind);command.Parameters.AddWithValue("@CustomerId",(object?)customerId??DBNull.Value);command.Parameters.AddWithValue("@CustomerTypeCode",(object?)typeCode??DBNull.Value);command.Parameters.AddWithValue("@ItemGroupCode",itemGroup);command.Parameters.AddWithValue("@PercentValue",percent);command.Parameters.AddWithValue("@ValidFrom",(object?)validFrom?.Date??DBNull.Value);command.Parameters.AddWithValue("@ValidTo",(object?)validTo?.Date??DBNull.Value);},cancellationToken);
  }
  async Task ExecuteCommercialAsync(string sql,int organizationId,string changedBy,Action<SqlCommand> configure,CancellationToken cancellationToken)
  {
    await using var connection=new SqlConnection(ConnectionString);await connection.OpenAsync(cancellationToken);await using var command=new SqlCommand(sql,connection);command.Parameters.AddWithValue("@OrganizationId",organizationId);command.Parameters.AddWithValue("@ChangedBy",changedBy);configure(command);await command.ExecuteNonQueryAsync(cancellationToken);
  }

  public async Task<IReadOnlyList<OutboundRow>> GetOutboundAsync(int organizationId, CancellationToken cancellationToken=default)
  {
    await using var connection=new SqlConnection(ConnectionString);await connection.OpenAsync(cancellationToken);
    await using var command=new SqlCommand("EXEC intranet.GetOutboundMessages @OrganizationId;",connection);command.Parameters.AddWithValue("@OrganizationId",organizationId);
    await using var reader=await command.ExecuteReaderAsync(cancellationToken);var rows=new List<OutboundRow>();
    while(await reader.ReadAsync(cancellationToken))rows.Add(new(reader.GetInt64(0),reader.GetString(1),reader.GetString(2),reader.GetString(3),reader.GetString(4),reader.GetString(5),reader.GetString(6),reader.GetString(7),reader.GetInt32(8),reader.IsDBNull(9)?null:reader.GetDateTime(9),reader.IsDBNull(10)?null:reader.GetInt32(10),reader.IsDBNull(11)?null:reader.GetString(11),reader.IsDBNull(12)?null:reader.GetString(12),reader.GetDateTime(13)));
    return rows;
  }

  public Task ApproveOutboundAsync(long messageId,string actor,CancellationToken cancellationToken=default) => ExecuteOutboundActionAsync("out.ApproveMessage",messageId,actor,cancellationToken);
  public Task CancelOutboundAsync(long messageId,string actor,CancellationToken cancellationToken=default) => ExecuteOutboundActionAsync("out.CancelMessage",messageId,actor,cancellationToken);
  public Task RetryOutboundAsync(long messageId,string actor,CancellationToken cancellationToken=default) => ExecuteOutboundActionAsync("out.RetryMessage",messageId,actor,cancellationToken);

  async Task ExecuteOutboundActionAsync(string procedure,long messageId,string actor,CancellationToken cancellationToken)
  {
    await using var connection=new SqlConnection(ConnectionString);await connection.OpenAsync(cancellationToken);
    await using var command=new SqlCommand($"EXEC {procedure} @OutboxMessageId,@Actor;",connection);
    command.Parameters.AddWithValue("@OutboxMessageId",messageId);command.Parameters.AddWithValue("@Actor",actor);
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  public async Task<SystemIntegrationView> GetSystemIntegrationsAsync(int organizationId,CancellationToken cancellationToken=default)
  {
    await using var connection=new SqlConnection(ConnectionString);await connection.OpenAsync(cancellationToken);
    await using var command=new SqlCommand("intranet.GetSystemIntegrations",connection){CommandType=System.Data.CommandType.StoredProcedure};command.Parameters.AddWithValue("@OrganizationId",organizationId);
    await using var reader=await command.ExecuteReaderAsync(cancellationToken);var integrations=new List<SystemIntegrationRow>();
    while(await reader.ReadAsync(cancellationToken))integrations.Add(new(reader.GetInt32(0),reader.GetString(1),reader.GetString(2),reader.GetString(3),reader.GetBoolean(4),reader.IsDBNull(5)?null:reader.GetString(5),reader.IsDBNull(6)?null:reader.GetDateTime(6),reader.IsDBNull(7)?null:reader.GetDateTime(7),reader.IsDBNull(8)?null:reader.GetDateTime(8),reader.IsDBNull(9)?null:reader.GetDateTime(9),reader.IsDBNull(10)?null:reader.GetDateTime(10),reader.GetInt32(11),reader.GetInt32(12),reader.GetInt32(13)));
    await reader.NextResultAsync(cancellationToken);var alerts=new List<SystemAlertRow>();
    while(await reader.ReadAsync(cancellationToken))alerts.Add(new(reader.GetInt64(0),reader.GetString(1),reader.GetString(2),reader.GetString(3),reader.GetString(4),reader.GetString(5),reader.GetInt32(6),reader.GetDateTime(7),reader.GetDateTime(8),reader.IsDBNull(9)?null:reader.GetDateTime(9),reader.IsDBNull(10)?null:reader.GetString(10),reader.IsDBNull(11)?null:reader.GetDateTime(11),reader.IsDBNull(12)?null:reader.GetString(12)));
    return new(integrations,alerts);
  }

  /// <summary>
  /// Urniki vseh podjetij. Nacrtovano opravilo Windows je samo ura, ki tiktaka; ali postopek sme
  /// teci in kako pogosto je zares na vrsti, pove ta vrstica v bazi.
  /// </summary>
  public async Task<IReadOnlyList<ScheduleRow>> GetSchedulesAsync(CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.GetSchedules", connection) { CommandType = System.Data.CommandType.StoredProcedure };
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var rows = new List<ScheduleRow>();
    while (await reader.ReadAsync(cancellationToken))
      rows.Add(new(
        reader.GetInt32(0), reader.GetString(1), reader.GetString(2), reader.GetString(3),
        reader.GetBoolean(4), reader.GetInt32(5), reader.GetInt32(6),
        reader.IsDBNull(7) ? null : reader.GetDateTime(7),
        reader.IsDBNull(8) ? null : reader.GetDateTime(8),
        reader.IsDBNull(9) ? null : reader.GetString(9),
        reader.IsDBNull(10) ? null : reader.GetString(10),
        reader.IsDBNull(11) ? null : reader.GetDateTime(11),
        reader.IsDBNull(12) ? null : reader.GetDateTime(12),
        reader.IsDBNull(13) ? null : reader.GetDateTime(13),
        reader.IsDBNull(14) ? null : reader.GetString(14)));

    return rows;
  }

  public async Task SaveScheduleAsync(int organizationId, string pipeline, bool isEnabled, int intervalSeconds, string actor, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.SaveSchedule", connection) { CommandType = System.Data.CommandType.StoredProcedure };
    command.Parameters.AddWithValue("@OrganizationId", organizationId);
    command.Parameters.AddWithValue("@Pipeline", pipeline);
    command.Parameters.AddWithValue("@IsEnabled", isEnabled);
    command.Parameters.AddWithValue("@IntervalSeconds", intervalSeconds);
    command.Parameters.AddWithValue("@Actor", actor);
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  public Task AcknowledgeAlertAsync(int organizationId,long alertId,string actor,CancellationToken cancellationToken=default) => ExecuteAlertActionAsync("intranet.AcknowledgeAlert",organizationId,alertId,actor,cancellationToken);
  public Task ResolveAlertAsync(int organizationId,long alertId,string actor,CancellationToken cancellationToken=default) => ExecuteAlertActionAsync("intranet.ResolveAlert",organizationId,alertId,actor,cancellationToken);

  async Task ExecuteAlertActionAsync(string procedure,int organizationId,long alertId,string actor,CancellationToken cancellationToken)
  {
    await using var connection=new SqlConnection(ConnectionString);await connection.OpenAsync(cancellationToken);
    await using var command=new SqlCommand(procedure,connection){CommandType=System.Data.CommandType.StoredProcedure};
    command.Parameters.AddWithValue("@OrganizationId",organizationId);command.Parameters.AddWithValue("@AlertId",alertId);command.Parameters.AddWithValue("@Actor",actor);
    await command.ExecuteNonQueryAsync(cancellationToken);
  }
}
