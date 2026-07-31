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
public sealed record CustomerRow(long CustomerId, string CustomerKey, string Name, string? CustomerKind, string? CustomerType, string? MagentoGroupKey, bool WebEnabled, bool PackagingDiscountEnabled, bool ValueDiscountEnabled, bool B2bPlusEnabled);
public sealed record CustomerDetailRow(long CustomerId, string CustomerKey, string Name, string? PayerCode, string? PayerName, string? PriceListCode, string? DiscountPriceListCode, string? CustomerTypeCode, string? CustomerKind, bool PackagingDiscountEnabled, bool ValueDiscountEnabled, bool B2bPlusEnabled, DateTime? B2bPlusValidFrom, DateTime? B2bPlusValidTo, bool WebEnabled, string? MagentoGroupKey);
public sealed record CustomerTypeRow(string CustomerTypeCode, string Name, string? MagentoGroupKey);
public sealed record ValueTierRow(byte TierNumber, decimal ThresholdGrossExVat, decimal PercentValue);
public sealed record GroupOverrideRow(long OverrideId, string TargetKind, string? CustomerKey, string? CustomerTypeCode, string ItemGroupCode, decimal PercentValue, DateTime? ValidFrom, DateTime? ValidTo);
public sealed record OutboundRow(long OutboxMessageId, string TargetKind, string Operation, string EntityType, string EntityKey,
  string FieldSummary, string DedupKey, string Status, int AttemptCount, DateTime? NextAttemptUtc,
  int? ResponseStatusCode, string? ResponseCorrelationId, string? DriftDetail, DateTime CreatedUtc);
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
