using System.Data;
using Microsoft.Data.SqlClient;

namespace PIM.Intranet.Services;

/// <param name="SourceCustomerType">Vrsta iz SAOP (O/F …), ne tip iz PIM sifranta.</param>
public sealed record CustomerGeneral(
  long CustomerId, string CustomerKey, string Name,
  string? PayerCode, string? PayerName, string? PriceListCode, string? DiscountPriceListCode,
  string? Address, string? Street, string? HouseNumber, string? City, string? PostalCode, string? Country,
  string? TaxNumber, string? RegistrationNumber, string? ActivityCode,
  bool? SubjectToVat, int? PaymentDays, decimal? RebatePercent, bool? IsActive,
  string? SourceCustomerType, string? LegalForm, bool? IsDefaulter, bool? UpfrontPayment,
  string? LanguageId, string? CurrencyCode, DateTime UpdatedUtc,
  string? CustomerTypeCode, string? CustomerKind, string? PayerKind,
  bool PackagingDiscountEnabled, bool ValueDiscountEnabled, bool B2bPlusEnabled,
  DateTime? B2bPlusValidFrom, DateTime? B2bPlusValidTo, bool WebEnabled,
  string? MagentoGroupKey, string? CustomerTypeName);

public sealed record CustomerGroupDiscount(string ItemGroupCode, decimal DiscountPercent, decimal? MinQuantity, DateTime? ValidFrom, DateTime? ValidTo, string CustomerGroupCode);
public sealed record CustomerValueTier(byte TierNumber, decimal ThresholdGrossExVat, decimal PercentValue, bool IsActive);
public sealed record CustomerSpecialDiscount(long OverrideId, string DiscountCode, DateTime? ValidFrom, DateTime? ValidTo, bool IsActive, string? ItemId);
public sealed record CustomerBranch(long CustomerBranchId, string BranchKind, bool IsActive, string? Note, string CreatedBy, DateTime CreatedUtc, long? BranchCustomerId, string? BranchCode, string? BranchName, bool FromCatalog);
public sealed record CustomerNote(long CustomerNoteId, string Body, string CreatedBy, DateTime CreatedUtc);
public sealed record CustomerHistoryEntry(long AuditLogId, string EntityType, string ActionCode, string? OldValueJson, string? NewValueJson, string ChangedBy, DateTime ChangedUtc);

public sealed record CustomerCard(
  CustomerGeneral General,
  IReadOnlyList<CustomerGroupDiscount> GroupDiscounts,
  IReadOnlyList<CustomerValueTier> ValueTiers,
  IReadOnlyList<CustomerSpecialDiscount> SpecialDiscounts,
  IReadOnlyList<CustomerBranch> Branches,
  IReadOnlyList<CustomerNote> Notes,
  IReadOnlyList<CustomerHistoryEntry> History);

/// <summary>
/// Kartica stranke v enem bralnem klicu (<c>intranet.GetCustomerCard</c>, migracija 129) ter
/// dve pisljivi poti, ki ju je zahteval uporabnik: zaznamek in poslovna enota.
///
/// Zakaj svoj servis in ne <see cref="IntranetDataService"/>: ta je splosen odjemalec bralnih
/// procedur, kartica pa je ena zaokrozena stvar s sedmimi nabori. Loceno je lazje brati in
/// lazje preizkusiti.
/// </summary>
public sealed class CustomerCardService(IConfiguration configuration)
{
  string ConnectionString => ConnectionStringResolver.Resolve(configuration)
    ?? throw new InvalidOperationException("Povezava PIM ni nastavljena.");

  public async Task<CustomerCard?> GetAsync(int organizationId, long customerId, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.GetCustomerCard", connection)
    {
      CommandType = CommandType.StoredProcedure,
      CommandTimeout = 60,
    };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@CustomerId", SqlDbType.BigInt).Value = customerId;

    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    if (!await reader.ReadAsync(cancellationToken)) return null;

    var general = new CustomerGeneral(
      PimDb.Int64(reader, "CustomerId"), PimDb.TextOrEmpty(reader, "CustomerKey"), PimDb.TextOrEmpty(reader, "Name"),
      PimDb.Text(reader, "PayerCode"), PimDb.Text(reader, "PayerName"),
      PimDb.Text(reader, "PriceListCode"), PimDb.Text(reader, "DiscountPriceListCode"),
      PimDb.Text(reader, "Address"), PimDb.Text(reader, "Street"), PimDb.Text(reader, "HouseNumber"),
      PimDb.Text(reader, "City"), PimDb.Text(reader, "PostalCode"), PimDb.Text(reader, "Country"),
      PimDb.Text(reader, "TaxNumber"), PimDb.Text(reader, "RegistrationNumber"), PimDb.Text(reader, "ActivityCode"),
      NullableBool(reader, "SubjectToVat"), NullableInt(reader, "PaymentDays"), NullableDecimal(reader, "RebatePercent"),
      NullableBool(reader, "IsActive"), PimDb.Text(reader, "SourceCustomerType"), PimDb.Text(reader, "LegalForm"),
      NullableBool(reader, "IsDefaulter"), NullableBool(reader, "UpfrontPayment"),
      PimDb.Text(reader, "LanguageId"), PimDb.Text(reader, "CurrencyCode"),
      reader.GetDateTime(reader.GetOrdinal("UpdatedUtc")),
      PimDb.Text(reader, "CustomerTypeCode"), PimDb.Text(reader, "CustomerKind"), PimDb.Text(reader, "PayerKind"),
      PimDb.Bool(reader, "PackagingDiscountEnabled"), PimDb.Bool(reader, "ValueDiscountEnabled"),
      PimDb.Bool(reader, "B2bPlusEnabled"), PimDb.NullableDateTime(reader, "B2bPlusValidFrom"),
      PimDb.NullableDateTime(reader, "B2bPlusValidTo"), PimDb.Bool(reader, "WebEnabled"),
      PimDb.Text(reader, "MagentoGroupKey"), PimDb.Text(reader, "CustomerTypeName"));

    var groupDiscounts = await NextAsync(reader, row => new CustomerGroupDiscount(
      PimDb.TextOrEmpty(row, "ItemGroupCode"), PimDb.Decimal(row, "DiscountPercent"),
      NullableDecimal(row, "MinQuantity"), PimDb.NullableDateTime(row, "ValidFrom"),
      PimDb.NullableDateTime(row, "ValidTo"), PimDb.TextOrEmpty(row, "CustomerGroupCode")), cancellationToken);

    var valueTiers = await NextAsync(reader, row => new CustomerValueTier(
      Convert.ToByte(row["TierNumber"]), PimDb.Decimal(row, "ThresholdGrossExVat"),
      PimDb.Decimal(row, "PercentValue"), PimDb.Bool(row, "IsActive")), cancellationToken);

    var specials = await NextAsync(reader, row => new CustomerSpecialDiscount(
      PimDb.Int64(row, "OverrideId"), PimDb.TextOrEmpty(row, "DiscountCode"),
      PimDb.NullableDateTime(row, "ValidFrom"), PimDb.NullableDateTime(row, "ValidTo"),
      PimDb.Bool(row, "IsActive"), PimDb.Text(row, "ItemID")), cancellationToken);

    var branches = await NextAsync(reader, row => new CustomerBranch(
      PimDb.Int64(row, "CustomerBranchId"), PimDb.TextOrEmpty(row, "BranchKind"), PimDb.Bool(row, "IsActive"),
      PimDb.Text(row, "Note"), PimDb.TextOrEmpty(row, "CreatedBy"), row.GetDateTime(row.GetOrdinal("CreatedUtc")),
      row.IsDBNull(row.GetOrdinal("BranchCustomerId")) ? null : PimDb.Int64(row, "BranchCustomerId"),
      PimDb.Text(row, "BranchCode"), PimDb.Text(row, "BranchName"), PimDb.Bool(row, "FromCatalog")), cancellationToken);

    var notes = await NextAsync(reader, row => new CustomerNote(
      PimDb.Int64(row, "CustomerNoteId"), PimDb.TextOrEmpty(row, "Body"),
      PimDb.TextOrEmpty(row, "CreatedBy"), row.GetDateTime(row.GetOrdinal("CreatedUtc"))), cancellationToken);

    var history = await NextAsync(reader, row => new CustomerHistoryEntry(
      PimDb.Int64(row, "AuditLogId"), PimDb.TextOrEmpty(row, "EntityType"), PimDb.TextOrEmpty(row, "ActionCode"),
      PimDb.Text(row, "OldValueJson"), PimDb.Text(row, "NewValueJson"),
      PimDb.TextOrEmpty(row, "ChangedBy"), row.GetDateTime(row.GetOrdinal("ChangedUtc"))), cancellationToken);

    return new(general, groupDiscounts, valueTiers, specials, branches, notes, history);
  }

  /// <summary>Zaznamek uporabnika. Besedilo brez vsebine procedura zavrne.</summary>
  public async Task AddNoteAsync(int organizationId, long customerId, string body, string actor, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.AddCustomerNote", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@CustomerId", SqlDbType.BigInt).Value = customerId;
    command.Parameters.Add("@Body", SqlDbType.NVarChar, 4000).Value = body;
    command.Parameters.Add("@CreatedBy", SqlDbType.NVarChar, 200).Value = actor;
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  /// <param name="branchCustomerId">Enota iz sifranta strank; null pomeni rocno vpisano enoto.</param>
  public async Task SaveBranchAsync(
    int organizationId, long customerId, string branchKind,
    long? branchCustomerId, string? branchCode, string? branchName, string? note, string actor,
    CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.SaveCustomerBranch", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@CustomerId", SqlDbType.BigInt).Value = customerId;
    command.Parameters.Add("@BranchKind", SqlDbType.NVarChar, 20).Value = branchKind;
    command.Parameters.Add("@BranchCustomerId", SqlDbType.BigInt).Value = (object?)branchCustomerId ?? DBNull.Value;
    command.Parameters.Add("@BranchCode", SqlDbType.NVarChar, 200).Value = (object?)branchCode ?? DBNull.Value;
    command.Parameters.Add("@BranchName", SqlDbType.NVarChar, 600).Value = (object?)branchName ?? DBNull.Value;
    command.Parameters.Add("@Note", SqlDbType.NVarChar, 1000).Value = (object?)note ?? DBNull.Value;
    command.Parameters.Add("@CreatedBy", SqlDbType.NVarChar, 200).Value = actor;
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  static async Task<IReadOnlyList<T>> NextAsync<T>(SqlDataReader reader, Func<SqlDataReader, T> map, CancellationToken cancellationToken)
  {
    if (!await reader.NextResultAsync(cancellationToken)) return [];
    var rows = new List<T>();
    while (await reader.ReadAsync(cancellationToken)) rows.Add(map(reader));
    return rows;
  }

  static bool? NullableBool(SqlDataReader reader, string name)
  {
    var ordinal = reader.GetOrdinal(name);
    return reader.IsDBNull(ordinal) ? null : reader.GetBoolean(ordinal);
  }

  static int? NullableInt(SqlDataReader reader, string name)
  {
    var ordinal = reader.GetOrdinal(name);
    return reader.IsDBNull(ordinal) ? null : Convert.ToInt32(reader.GetValue(ordinal));
  }

  static decimal? NullableDecimal(SqlDataReader reader, string name)
  {
    var ordinal = reader.GetOrdinal(name);
    return reader.IsDBNull(ordinal) ? null : Convert.ToDecimal(reader.GetValue(ordinal));
  }
}
