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
  string? MagentoGroupKey, string? CustomerTypeName,
  bool HasManualGeneral, string? GeneralUpdatedBy, DateTime? GeneralUpdatedUtc);

/// <summary>
/// Osnutek rocnega prepisa splosnih podatkov stranke (migracija 200). Isto nacelo kot pri
/// kontaktih: obrazec ureja rocni prepis, ne ucinkovito vrednost, zato je to svoj razred in ne
/// <see cref="CustomerGeneral"/> sam.
/// </summary>
public sealed class CustomerGeneralDraft
{
  public string? CustomerKey { get; set; }
  public string? Name { get; set; }
  public string? PayerCode { get; set; }
  public string? PayerName { get; set; }
  public string? PriceListCode { get; set; }
  public string? DiscountPriceListCode { get; set; }
  public string? Address { get; set; }
  public string? Street { get; set; }
  public string? HouseNumber { get; set; }
  public string? City { get; set; }
  public string? PostalCode { get; set; }
  public string? Country { get; set; }
  public string? TaxNumber { get; set; }
  public string? RegistrationNumber { get; set; }
  public string? ActivityCode { get; set; }
  public bool? SubjectToVat { get; set; }
  public int? PaymentDays { get; set; }
  public decimal? RebatePercent { get; set; }
  public bool? IsActive { get; set; }
  public string? CustomerType { get; set; }
  public string? LegalForm { get; set; }
  public bool? IsDefaulter { get; set; }
  public bool? UpfrontPayment { get; set; }
  public string? LanguageId { get; set; }
  public string? CurrencyCode { get; set; }
}

public sealed record CustomerGroupDiscount(string ItemGroupCode, decimal DiscountPercent, decimal? MinQuantity, DateTime? ValidFrom, DateTime? ValidTo, string CustomerGroupCode);
public sealed record CustomerValueTier(byte TierNumber, decimal ThresholdGrossExVat, decimal PercentValue, bool IsActive);
public sealed record CustomerSpecialDiscount(long OverrideId, string DiscountCode, DateTime? ValidFrom, DateTime? ValidTo, bool IsActive, string? ItemId);
public sealed record CustomerBranch(long CustomerBranchId, string BranchKind, bool IsActive, string? Note, string CreatedBy, DateTime CreatedUtc, long? BranchCustomerId, string? BranchCode, string? BranchName, bool FromCatalog);
public sealed record CustomerNote(long CustomerNoteId, string Body, string CreatedBy, DateTime CreatedUtc);
public sealed record CustomerHistoryEntry(long AuditLogId, string EntityType, string ActionCode, string? OldValueJson, string? NewValueJson, string ChangedBy, DateTime ChangedUtc);

/// <summary>
/// Kontakti stranke (migracija 140). Ucinkovita vrednost je rocni prepis, sicer izvor;
/// <c>*Source</c> pove, kateri od obeh je obveljal, in je <c>null</c>, kadar vrednosti ni.
/// <c>Manual*</c> je tisto, kar ureja obrazec — obrazec nikoli ne ureja ucinkovite vrednosti,
/// sicer bi prvo shranjevanje posnetek izvora zapisalo kot rocni prepis.
/// </summary>
/// <param name="SourceAvailable">Ali zajem kontaktov v tej organizaciji sploh obstaja.</param>
/// <param name="SourceNote">Kadar zajema ni: kaj natanko manjka. Vmesnik to izpise, ne ugiba.</param>
public sealed record CustomerContact(
  string? Email, string? Phone, string? Mobile, string? Persons,
  string? EmailSource, string? PhoneSource, string? MobileSource, string? PersonsSource,
  string? ManualEmail, string? ManualPhone, string? ManualMobile, string? ManualPersons,
  string? SourceEmail, string? SourcePhone, string? SourceMobile, string? SourcePersons,
  bool SourceAvailable, string? SourceNote, string? UpdatedBy, DateTime? UpdatedUtc);

public sealed record CustomerCard(
  CustomerGeneral General,
  IReadOnlyList<CustomerGroupDiscount> GroupDiscounts,
  IReadOnlyList<CustomerValueTier> ValueTiers,
  IReadOnlyList<CustomerSpecialDiscount> SpecialDiscounts,
  IReadOnlyList<CustomerBranch> Branches,
  IReadOnlyList<CustomerNote> Notes,
  IReadOnlyList<CustomerHistoryEntry> History,
  CustomerContact Contacts);

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
      PimDb.Text(reader, "MagentoGroupKey"), PimDb.Text(reader, "CustomerTypeName"),
      PimDb.Bool(reader, "HasManualGeneral"), PimDb.Text(reader, "GeneralUpdatedBy"),
      PimDb.NullableDateTime(reader, "GeneralUpdatedUtc"));

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

    // Osmi nabor je namenoma na koncu (migracija 140) in vrne natanko eno vrstico, tudi ko
    // stranka nima ne rocnega prepisa ne izvora — takrat so vse vrednosti prazne.
    var contacts = await NextAsync(reader, row => new CustomerContact(
      PimDb.Text(row, "Email"), PimDb.Text(row, "Phone"), PimDb.Text(row, "Mobile"), PimDb.Text(row, "Persons"),
      PimDb.Text(row, "EmailSource"), PimDb.Text(row, "PhoneSource"),
      PimDb.Text(row, "MobileSource"), PimDb.Text(row, "PersonsSource"),
      PimDb.Text(row, "ManualEmail"), PimDb.Text(row, "ManualPhone"),
      PimDb.Text(row, "ManualMobile"), PimDb.Text(row, "ManualPersons"),
      PimDb.Text(row, "SourceEmail"), PimDb.Text(row, "SourcePhone"),
      PimDb.Text(row, "SourceMobile"), PimDb.Text(row, "SourcePersons"),
      PimDb.Bool(row, "SourceAvailable"), PimDb.Text(row, "SourceNote"),
      PimDb.Text(row, "UpdatedBy"), PimDb.NullableDateTime(row, "UpdatedUtc")), cancellationToken);

    return new(general, groupDiscounts, valueTiers, specials, branches, notes, history,
      contacts.Count > 0 ? contacts[0] : EmptyContact);
  }

  /// <summary>
  /// Rocni prepis kontaktov. Prazno polje pomeni »rocnega prepisa ni« in vrne vrednost izvora;
  /// pravilo, da se rocna vrednost, enaka izvoru, ne shrani kot prepis, je v proceduri.
  /// </summary>
  public async Task SaveContactAsync(
    int organizationId, long customerId,
    string? email, string? phone, string? mobile, string? persons, string actor,
    CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("b2b.SaveCustomerContact", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@CustomerId", SqlDbType.BigInt).Value = customerId;
    command.Parameters.Add("@Email", SqlDbType.NVarChar, 400).Value = Trimmed(email);
    command.Parameters.Add("@Phone", SqlDbType.NVarChar, 200).Value = Trimmed(phone);
    command.Parameters.Add("@Mobile", SqlDbType.NVarChar, 200).Value = Trimmed(mobile);
    command.Parameters.Add("@Persons", SqlDbType.NVarChar, 1000).Value = Trimmed(persons);
    command.Parameters.Add("@ChangedBy", SqlDbType.NVarChar, 200).Value = actor;
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  static object Trimmed(string? value) =>
    string.IsNullOrWhiteSpace(value) ? DBNull.Value : value.Trim();

  /// <summary>
  /// Rocni prepis splosnih podatkov stranke (migracija 200). Obrazec ureja UCINKOVITO vrednost
  /// (glej klicatelja v CustomerDetail.razor: draft se napolni iz <see cref="CustomerGeneral"/>,
  /// ne iz surovega prepisa) - uporabnik vidi trenutni podatek in ga po potrebi popravi, namesto
  /// praznega obrazca. Polje, ki ga uporabnik ne spremeni, procedura sama prepozna kot enako
  /// trenutnemu SAOP izvoru in ga NE zapise kot prepis (primerjava je tu, ne v klicatelju), zato
  /// obstojeci prepisi na drugih poljih ostanejo nedotaknjeni.
  /// </summary>
  public async Task SaveGeneralAsync(int organizationId, long customerId, CustomerGeneralDraft draft, string actor,
    CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("b2b.SaveCustomerGeneral", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@CustomerId", SqlDbType.BigInt).Value = customerId;
    command.Parameters.Add("@CustomerKey", SqlDbType.NVarChar, 100).Value = Trimmed(draft.CustomerKey);
    command.Parameters.Add("@Name", SqlDbType.NVarChar, 300).Value = Trimmed(draft.Name);
    command.Parameters.Add("@PayerCode", SqlDbType.NVarChar, 100).Value = Trimmed(draft.PayerCode);
    command.Parameters.Add("@PayerName", SqlDbType.NVarChar, 300).Value = Trimmed(draft.PayerName);
    command.Parameters.Add("@PriceListCode", SqlDbType.NVarChar, 100).Value = Trimmed(draft.PriceListCode);
    command.Parameters.Add("@DiscountPriceListCode", SqlDbType.NVarChar, 100).Value = Trimmed(draft.DiscountPriceListCode);
    command.Parameters.Add("@Address", SqlDbType.NVarChar, 400).Value = Trimmed(draft.Address);
    command.Parameters.Add("@Street", SqlDbType.NVarChar, 400).Value = Trimmed(draft.Street);
    command.Parameters.Add("@HouseNumber", SqlDbType.NVarChar, 60).Value = Trimmed(draft.HouseNumber);
    command.Parameters.Add("@City", SqlDbType.NVarChar, 200).Value = Trimmed(draft.City);
    command.Parameters.Add("@PostalCode", SqlDbType.NVarChar, 40).Value = Trimmed(draft.PostalCode);
    command.Parameters.Add("@Country", SqlDbType.NVarChar, 20).Value = Trimmed(draft.Country);
    command.Parameters.Add("@TaxNumber", SqlDbType.NVarChar, 40).Value = Trimmed(draft.TaxNumber);
    command.Parameters.Add("@RegistrationNumber", SqlDbType.NVarChar, 40).Value = Trimmed(draft.RegistrationNumber);
    command.Parameters.Add("@ActivityCode", SqlDbType.NVarChar, 40).Value = Trimmed(draft.ActivityCode);
    command.Parameters.Add("@SubjectToVat", SqlDbType.Bit).Value = (object?)draft.SubjectToVat ?? DBNull.Value;
    command.Parameters.Add("@PaymentDays", SqlDbType.Int).Value = (object?)draft.PaymentDays ?? DBNull.Value;
    var rebateParam = command.Parameters.Add("@RebatePercent", SqlDbType.Decimal);
    rebateParam.Precision = 9; rebateParam.Scale = 4;
    rebateParam.Value = (object?)draft.RebatePercent ?? DBNull.Value;
    command.Parameters.Add("@IsActive", SqlDbType.Bit).Value = (object?)draft.IsActive ?? DBNull.Value;
    command.Parameters.Add("@CustomerType", SqlDbType.NVarChar, 10).Value = Trimmed(draft.CustomerType);
    command.Parameters.Add("@LegalForm", SqlDbType.NVarChar, 10).Value = Trimmed(draft.LegalForm);
    command.Parameters.Add("@IsDefaulter", SqlDbType.Bit).Value = (object?)draft.IsDefaulter ?? DBNull.Value;
    command.Parameters.Add("@UpfrontPayment", SqlDbType.Bit).Value = (object?)draft.UpfrontPayment ?? DBNull.Value;
    command.Parameters.Add("@LanguageId", SqlDbType.NVarChar, 20).Value = Trimmed(draft.LanguageId);
    command.Parameters.Add("@CurrencyCode", SqlDbType.NVarChar, 20).Value = Trimmed(draft.CurrencyCode);
    command.Parameters.Add("@ChangedBy", SqlDbType.NVarChar, 200).Value = actor;
    await command.ExecuteNonQueryAsync(cancellationToken);
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

  /// <summary>Stranka brez kontaktov: kartica mora imeti kaj izrisati tudi takrat.</summary>
  static readonly CustomerContact EmptyContact = new(
    null, null, null, null, null, null, null, null, null, null, null, null,
    null, null, null, null, false, null, null, null);

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
