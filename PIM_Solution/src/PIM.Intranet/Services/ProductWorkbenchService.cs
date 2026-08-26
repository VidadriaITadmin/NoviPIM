using System.Data;
using Microsoft.Data.SqlClient;

namespace PIM.Intranet.Services;

public sealed record ProductCardHeader(
  long ProductId, string ItemId, string? Ean, string Name, string? ThumbnailUrl,
  bool IsActive, bool WebPublish, bool IsPromoted, string ErpStatus, string WebStatus,
  string ValidationStatus, decimal Completeness, string? Uom, string? ItemGroup,
  string? Department, string? Manufacturer, string? Supplier, string? DiscountGroup,
  string? AccountingGroup, DateTime? LastValidatedUtc, long OpenIssueCount);

public sealed record ProductCardField(string FieldKey, string Label, string? Value, string Owner);
public sealed record ProductPendingOverlay(
  string FieldKey, string? Value, string Status, long OutboxMessageId, long? OutboundBatchId,
  DateTime CreatedUtc, DateTime? SentUtc, string? LastError, string? SaopErrorKind);
public sealed record ProductCardText(long ProductTextId, string Language, string TextType, string Value, string FieldKey, string Owner);
public sealed record ProductCardAttribute(long ProductAttributeId, string AttributeCode, string Value, string FieldKey, string Owner);
public sealed record ProductCardCategory(long ProductCategoryId, string WebSite, string CategoryPath, string? CategoryTreeCode, string? CategoryCode, string? CategoryName, string Owner);
public sealed record ProductCardMedia(long ProductMediaId, string Url, string Role, int SortOrder, string Owner);
public sealed record ProductCardDocument(long ProductDocumentId, string Role, string Url, string? Title, int SortOrder);
public sealed record ProductCardPrice(long ProductPriceId, string PriceList, decimal Net, decimal VatRate, decimal Gross, DateTime ValidFrom, bool IsActive);
public sealed record ProductCardStock(
  long PositionId, long SnapshotId, string? ProviderKind, string Endpoint, DateTime SnapshotUtc,
  decimal Quantity, DateTime? AvailabilityDate, decimal? IncomingQuantity, string MatchKey,
  string? WarehouseCode, string? WarehouseName, decimal? MinimumStock, decimal? MaximumStock);
public sealed record ProductCardCommercial(
  long ProductCommercialId, decimal? NetWeight, decimal? GrossWeight, string? CustomsTariff,
  string? CountryOfOrigin, decimal? Pak1, decimal? Pak2, string? Dimensions, decimal? Volume,
  decimal? PackageLength, decimal? PackageWidth, decimal? PackageHeight, string? DimensionUnit);
public sealed record ProductCardProfile(
  int ValidationProfileId, string ProfileCode, string Name, string Scope, bool BlocksErp,
  bool BlocksWeb, string Status, decimal Completeness, DateTime? ValidatedUtc, long OpenIssueCount);
public sealed record ProductCardIssue(
  long ProductIssueId, string ProfileCode, string FieldCode, string Severity, bool BlocksErp,
  bool BlocksWeb, string IssueCode, string Message, DateTime FirstDetectedUtc, DateTime LastDetectedUtc);
public sealed record ProductCardOutbound(
  long OutboxMessageId, string Operation, string EntityType, string EntityKey, string FieldSummary,
  string Status, int AttemptCount, string? LastError, string? DriftDetail, DateTime CreatedUtc,
  DateTime? ApprovedUtc, DateTime? SentUtc, DateTime? VerifiedUtc, DateTime UpdatedUtc,
  long? OutboundBatchId, int? LastAttemptNumber, string? LastAttemptOutcome,
  DateTime? LastAttemptStartedUtc, DateTime? LastAttemptCompletedUtc, string? LastAttemptFailureReason);
public sealed record ProductCardHistory(
  long ChangeId, long ChangeBatchId, string FieldKey, string Owner, string? OldValue,
  string? NewValue, DateTime ChangedAtUtc, DateTime? SentToSaopAtUtc, long? UndoOfChangeId,
  Guid BatchId, string ChangeSource, string ChangedBy, string? Note);
public sealed record ProductOriginRow(
  long InboxId, Guid RunId, string SourceCode, string EntityType, int PageNumber, string Status,
  DateTime ReceivedUtc, DateTime? ProcessedUtc, int RecordOrdinal, long ExtractedFieldCount);

public sealed record ProductCardView(
  ProductCardHeader Header,
  IReadOnlyList<ProductCardField> Fields,
  IReadOnlyList<ProductPendingOverlay> PendingOverlays,
  IReadOnlyList<ProductCardText> Texts,
  IReadOnlyList<ProductCardAttribute> Attributes,
  IReadOnlyList<ProductCardCategory> Categories,
  IReadOnlyList<ProductCardMedia> Media,
  IReadOnlyList<ProductCardDocument> Documents,
  IReadOnlyList<ProductCardPrice> Prices,
  IReadOnlyList<ProductCardStock> Stock,
  ProductCardCommercial? Commercial,
  IReadOnlyList<ProductCardProfile> Profiles,
  IReadOnlyList<ProductCardIssue> Issues,
  IReadOnlyList<ProductCardOutbound> Outbound,
  IReadOnlyList<ProductCardHistory> History);

/// <summary>
/// Bralna delovna miza izdelka. SQL ostane v oštevilčeni migraciji; servis kliče samo
/// <c>intranet.GetProductCard</c> in <c>intranet.GetProductOrigin</c> ter vse stolpce
/// preslika po imenu.
/// </summary>
public sealed class ProductWorkbenchService(IConfiguration configuration)
{
  string ConnectionString => ConnectionStringResolver.Resolve(configuration)
    ?? throw new InvalidOperationException("Povezava PIM ni nastavljena.");

  public async Task<ProductCardView?> GetProductCardAsync(
    int organizationId, long productId, string language = "sl", CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.GetProductCard", connection)
    {
      CommandType = CommandType.StoredProcedure,
      CommandTimeout = 60,
    };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@ProductId", SqlDbType.BigInt).Value = productId;
    command.Parameters.Add("@Language", SqlDbType.NVarChar, 20).Value = language;

    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    if (!await reader.ReadAsync(cancellationToken)) return null;

    var header = new ProductCardHeader(
      PimDb.Int64(reader, "ProductId"), PimDb.TextOrEmpty(reader, "ItemID"), PimDb.Text(reader, "EAN"),
      PimDb.TextOrEmpty(reader, "Name"), PimDb.Text(reader, "ThumbnailUrl"),
      PimDb.Bool(reader, "IsActive"), PimDb.Bool(reader, "WebPublish"), PimDb.Bool(reader, "IsPromoted"),
      PimDb.TextOrEmpty(reader, "ErpStatus"), PimDb.TextOrEmpty(reader, "WebStatus"),
      PimDb.TextOrEmpty(reader, "ValidationStatus"), PimDb.Decimal(reader, "Completeness"),
      PimDb.Text(reader, "UoM"), PimDb.Text(reader, "ItemGroup"), PimDb.Text(reader, "Department"),
      PimDb.Text(reader, "Manufacturer"), PimDb.Text(reader, "Supplier"), PimDb.Text(reader, "DiscountGroup"),
      PimDb.Text(reader, "AccountingGroup"), PimDb.NullableDateTime(reader, "LastValidatedUtc"),
      PimDb.Int64(reader, "OpenIssueCount"));

    await NextAsync(reader, cancellationToken);
    var fields = await ReadAsync(reader, row => new ProductCardField(
      PimDb.TextOrEmpty(row, "FieldKey"), PimDb.TextOrEmpty(row, "Label"),
      PimDb.Text(row, "Value"), PimDb.TextOrEmpty(row, "Owner")), cancellationToken);

    await NextAsync(reader, cancellationToken);
    var overlays = await ReadAsync(reader, row => new ProductPendingOverlay(
      PimDb.TextOrEmpty(row, "FieldKey"), PimDb.Text(row, "Value"), PimDb.TextOrEmpty(row, "Status"),
      PimDb.Int64(row, "OutboxMessageId"), PimDb.NullableInt64(row, "OutboundBatchId"),
      PimDb.DateTimeValue(row, "CreatedUtc"), PimDb.NullableDateTime(row, "SentUtc"),
      PimDb.Text(row, "LastError"), PimDb.Text(row, "SaopErrorKind")), cancellationToken);

    await NextAsync(reader, cancellationToken);
    var texts = await ReadAsync(reader, row => new ProductCardText(
      PimDb.Int64(row, "ProductTextId"), PimDb.TextOrEmpty(row, "Lang"), PimDb.TextOrEmpty(row, "TextType"),
      PimDb.TextOrEmpty(row, "Value"), PimDb.TextOrEmpty(row, "FieldKey"), PimDb.TextOrEmpty(row, "Owner")), cancellationToken);

    await NextAsync(reader, cancellationToken);
    var attributes = await ReadAsync(reader, row => new ProductCardAttribute(
      PimDb.Int64(row, "ProductAttributeId"), PimDb.TextOrEmpty(row, "AttributeCode"), PimDb.TextOrEmpty(row, "Value"),
      PimDb.TextOrEmpty(row, "FieldKey"), PimDb.TextOrEmpty(row, "Owner")), cancellationToken);

    await NextAsync(reader, cancellationToken);
    var categories = await ReadAsync(reader, row => new ProductCardCategory(
      PimDb.Int64(row, "ProductCategoryId"), PimDb.TextOrEmpty(row, "WebSite"), PimDb.TextOrEmpty(row, "CategoryPath"),
      PimDb.Text(row, "CategoryTreeCode"), PimDb.Text(row, "CategoryCode"), PimDb.Text(row, "CategoryName"),
      PimDb.TextOrEmpty(row, "Owner")), cancellationToken);

    await NextAsync(reader, cancellationToken);
    var media = await ReadAsync(reader, row => new ProductCardMedia(
      PimDb.Int64(row, "ProductMediaId"), PimDb.TextOrEmpty(row, "Url"), PimDb.TextOrEmpty(row, "Role"),
      PimDb.Int32(row, "SortOrder"), PimDb.TextOrEmpty(row, "Owner")), cancellationToken);

    await NextAsync(reader, cancellationToken);
    var documents = await ReadAsync(reader, row => new ProductCardDocument(
      PimDb.Int64(row, "ProductDocumentId"), PimDb.TextOrEmpty(row, "Role"), PimDb.TextOrEmpty(row, "Url"),
      PimDb.Text(row, "Title"), PimDb.Int32(row, "SortOrder")), cancellationToken);

    await NextAsync(reader, cancellationToken);
    var prices = await ReadAsync(reader, row => new ProductCardPrice(
      PimDb.Int64(row, "ProductPriceId"), PimDb.TextOrEmpty(row, "PriceList"), PimDb.Decimal(row, "Net"),
      PimDb.Decimal(row, "VatRate"), PimDb.Decimal(row, "Gross"), PimDb.DateTimeValue(row, "ValidFrom"),
      PimDb.Bool(row, "IsActive")), cancellationToken);

    await NextAsync(reader, cancellationToken);
    var stock = await ReadAsync(reader, row => new ProductCardStock(
      PimDb.Int64(row, "PositionId"), PimDb.Int64(row, "SnapshotId"), PimDb.Text(row, "ProviderKind"),
      PimDb.TextOrEmpty(row, "Endpoint"), PimDb.DateTimeValue(row, "SnapshotUtc"), PimDb.Decimal(row, "Quantity"),
      PimDb.NullableDateTime(row, "AvailabilityDate"), PimDb.NullableDecimal(row, "IncomingQuantity"),
      PimDb.TextOrEmpty(row, "MatchKey"), PimDb.Text(row, "WarehouseCode"), PimDb.Text(row, "WarehouseName"),
      PimDb.NullableDecimal(row, "MinimumStock"), PimDb.NullableDecimal(row, "MaximumStock")), cancellationToken);

    await NextAsync(reader, cancellationToken);
    ProductCardCommercial? commercial = null;
    if (await reader.ReadAsync(cancellationToken))
      commercial = new(
        PimDb.Int64(reader, "ProductCommercialId"), PimDb.NullableDecimal(reader, "NetWeight"),
        PimDb.NullableDecimal(reader, "GrossWeight"), PimDb.Text(reader, "CustomsTariff"),
        PimDb.Text(reader, "CountryOfOrigin"), PimDb.NullableDecimal(reader, "Pak1"),
        PimDb.NullableDecimal(reader, "Pak2"), PimDb.Text(reader, "Dimensions"),
        PimDb.NullableDecimal(reader, "Volume"), PimDb.NullableDecimal(reader, "PackageLength"),
        PimDb.NullableDecimal(reader, "PackageWidth"), PimDb.NullableDecimal(reader, "PackageHeight"),
        PimDb.Text(reader, "DimensionUnit"));

    await NextAsync(reader, cancellationToken);
    var profiles = await ReadAsync(reader, row => new ProductCardProfile(
      PimDb.Int32(row, "ValidationProfileId"), PimDb.TextOrEmpty(row, "ProfileCode"), PimDb.TextOrEmpty(row, "Name"),
      PimDb.TextOrEmpty(row, "Scope"), PimDb.Bool(row, "BlocksErp"), PimDb.Bool(row, "BlocksWeb"),
      PimDb.TextOrEmpty(row, "Status"), PimDb.Decimal(row, "Completeness"), PimDb.NullableDateTime(row, "ValidatedUtc"),
      PimDb.Int64(row, "OpenIssueCount")), cancellationToken);

    await NextAsync(reader, cancellationToken);
    var issues = await ReadAsync(reader, row => new ProductCardIssue(
      PimDb.Int64(row, "ProductIssueId"), PimDb.TextOrEmpty(row, "ProfileCode"), PimDb.TextOrEmpty(row, "FieldCode"),
      PimDb.TextOrEmpty(row, "Severity"), PimDb.Bool(row, "BlocksErp"), PimDb.Bool(row, "BlocksWeb"),
      PimDb.TextOrEmpty(row, "IssueCode"), PimDb.TextOrEmpty(row, "Message"),
      PimDb.DateTimeValue(row, "FirstDetectedUtc"), PimDb.DateTimeValue(row, "LastDetectedUtc")), cancellationToken);

    await NextAsync(reader, cancellationToken);
    var outbound = await ReadAsync(reader, row => new ProductCardOutbound(
      PimDb.Int64(row, "OutboxMessageId"), PimDb.TextOrEmpty(row, "Operation"), PimDb.TextOrEmpty(row, "EntityType"),
      PimDb.TextOrEmpty(row, "EntityKey"), PimDb.TextOrEmpty(row, "FieldSummary"), PimDb.TextOrEmpty(row, "Status"),
      PimDb.Int32(row, "AttemptCount"), PimDb.Text(row, "LastError"), PimDb.Text(row, "DriftDetail"),
      PimDb.DateTimeValue(row, "CreatedUtc"), PimDb.NullableDateTime(row, "ApprovedUtc"),
      PimDb.NullableDateTime(row, "SentUtc"), PimDb.NullableDateTime(row, "VerifiedUtc"),
      PimDb.DateTimeValue(row, "UpdatedUtc"), PimDb.NullableInt64(row, "OutboundBatchId"),
      NullableInt32(row, "AttemptNumber"), PimDb.Text(row, "AttemptOutcome"),
      PimDb.NullableDateTime(row, "AttemptStartedUtc"), PimDb.NullableDateTime(row, "AttemptCompletedUtc"),
      PimDb.Text(row, "AttemptFailureReason")), cancellationToken);

    await NextAsync(reader, cancellationToken);
    var history = await ReadAsync(reader, row => new ProductCardHistory(
      PimDb.Int64(row, "ChangeId"), PimDb.Int64(row, "ChangeBatchId"), PimDb.TextOrEmpty(row, "FieldKey"),
      PimDb.TextOrEmpty(row, "Owner"), PimDb.Text(row, "OldValue"), PimDb.Text(row, "NewValue"),
      PimDb.DateTimeValue(row, "ChangedAtUtc"), PimDb.NullableDateTime(row, "SentToSaopAtUtc"),
      PimDb.NullableInt64(row, "UndoOfChangeId"), row.GetGuid(row.GetOrdinal("BatchId")),
      PimDb.TextOrEmpty(row, "ChangeSource"), PimDb.TextOrEmpty(row, "ChangedBy"), PimDb.Text(row, "Note")), cancellationToken);

    return new(header, fields, overlays, texts, attributes, categories, media, documents,
      prices, stock, commercial, profiles, issues, outbound, history);
  }

  public async Task<IReadOnlyList<ProductOriginRow>> GetProductOriginAsync(
    int organizationId, long productId, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.GetProductOrigin", connection)
    {
      CommandType = CommandType.StoredProcedure,
      CommandTimeout = 60,
    };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@ProductId", SqlDbType.BigInt).Value = productId;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    return await ReadAsync(reader, row => new ProductOriginRow(
      PimDb.Int64(row, "InboxId"), row.GetGuid(row.GetOrdinal("RunId")), PimDb.TextOrEmpty(row, "SourceCode"),
      PimDb.TextOrEmpty(row, "EntityType"), PimDb.Int32(row, "PageNumber"), PimDb.TextOrEmpty(row, "Status"),
      PimDb.DateTimeValue(row, "ReceivedUtc"), PimDb.NullableDateTime(row, "ProcessedUtc"),
      PimDb.Int32(row, "RecordOrdinal"), PimDb.Int64(row, "ExtractedFieldCount")), cancellationToken);
  }

  static async Task NextAsync(SqlDataReader reader, CancellationToken cancellationToken)
  {
    if (!await reader.NextResultAsync(cancellationToken))
      throw new InvalidOperationException("Bralna procedura kartice ni vrnila vseh pogodbenih naborov.");
  }

  static async Task<IReadOnlyList<T>> ReadAsync<T>(
    SqlDataReader reader, Func<SqlDataReader, T> map, CancellationToken cancellationToken)
  {
    var rows = new List<T>();
    while (await reader.ReadAsync(cancellationToken)) rows.Add(map(reader));
    return rows;
  }

  static int? NullableInt32(SqlDataReader reader, string column)
  {
    var ordinal = reader.GetOrdinal(column);
    return reader.IsDBNull(ordinal) ? null : Convert.ToInt32(reader.GetValue(ordinal));
  }
}
