using System.Data;
using Microsoft.Data.SqlClient;

namespace PIM.Intranet.Services;

/// <summary>
/// Ena stranka na seznamu /stranke, v izvozu /izvoz/stranke.xlsx in v primerjavi uvoza
/// (<c>intranet.GetCustomerList</c>, migracija 250). Splošni podatki so učinkoviti (ročni prepis
/// prevlada nad SAOP), vloga je izračunana po pravilu iz 250 in se nikamor ne zapiše.
/// </summary>
/// <param name="SourceIsActive">Aktivnost v SAOP brez ročnega prepisa — po njej izbira stranke.csv (202).</param>
/// <param name="SaopPartnerType">Vrsta partnerja v SAOP (O/K/D/S), ne tip stranke iz PIM šifranta.</param>
/// <param name="ManualKind">Ročna vrsta s kartice; null pomeni, da vlogo določi pravilo.</param>
/// <param name="RoleSource">MANUAL, PRODUCTS, SAOP, TYPE ali DEFAULT — od kod je vloga.</param>
/// <param name="InCustomerExport">Ali vrstica gre v stranke.csv: aktivna v SAOP in ima B2B profil.</param>
/// <param name="GroupDiscounts">Skupinski popusti stranke »SKUPINA=%« ločeni z » | «.</param>
/// <param name="SpecialDiscounts">Posebni S po izdelku »ARTIKEL\S2« ločeni z » | «.</param>
/// <param name="PayerKind">PE ali TRANZIT: rocno na profilu, sicer iz tipa stranke (253); null = navadna stranka.</param>
/// <param name="ExportGroupDiscounts">Skupine popustov natanko tako, kot gredo v stranke.csv (253): rocni popust
/// stranke, rocni popust tipa, SAOP rabatni cenik (PE od placnika, tranzit brez); samo danes veljavni.</param>
public sealed record CustomerListRow(
  long CustomerId, int OrganizationId, string OrganizationName, string CustomerKey, string Name,
  string? City, string? TaxNumber, bool IsActive, bool SourceIsActive, string? SaopPartnerType,
  string? PriceListCode, string? DiscountPriceListCode, bool HasProfile,
  string? CustomerTypeCode, string? CustomerTypeName, string? MagentoGroupKey, string? ManualKind, string? PayerKind,
  int SuppliedProductCount, int ManufacturedProductCount,
  bool PackagingDiscountEnabled, bool ValueDiscountEnabled, bool B2bPlusEnabled,
  DateTime? B2bPlusValidFrom, DateTime? B2bPlusValidTo, bool WebEnabled,
  string? Email, string? Phone, string? Mobile, string? Persons,
  bool IsSupplier, bool IsManufacturer, bool IsBuyer, string RoleSource, bool InCustomerExport,
  decimal? Tier1Threshold, decimal? Tier1Percent, decimal? Tier2Threshold, decimal? Tier2Percent,
  decimal? Tier3Threshold, decimal? Tier3Percent,
  string? GroupDiscounts, string? SpecialDiscounts, string? ExportGroupDiscounts)
{
  public string RoleLabel => CustomerRoles.Label(IsBuyer, IsSupplier, IsManufacturer);
  public string RoleSourceLabel => CustomerRoles.SourceLabel(RoleSource);
  public bool HasOwnTiers => Tier1Threshold is not null || Tier2Threshold is not null || Tier3Threshold is not null;
  public int GroupDiscountCount => CountItems(GroupDiscounts);
  public int SpecialDiscountCount => CountItems(SpecialDiscounts);
  public int ExportGroupDiscountCount => CountItems(ExportGroupDiscounts);
  public string? PayerKindLabel => PayerKind switch { "PE" => "poslovna enota", "TRANZIT" => "tranzit", _ => null };

  static int CountItems(string? list) =>
    string.IsNullOrWhiteSpace(list) ? 0 : list.Split('|', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).Length;
}

/// <summary>Imena vlog in njihovega vira, kot jih bere uporabnik — na strani, v datoteki in v uvozu.</summary>
public static class CustomerRoles
{
  /// <summary>Ročne vrste s kartice (CustomerKind, 129). Uvoz sprejme kodo ali ime.</summary>
  public static readonly IReadOnlyList<(string Code, string Label)> Kinds =
  [
    ("CUSTOMER", "Kupec"),
    ("BOTH", "Kupec in dobavitelj"),
    ("SUPPLIER", "Dobavitelj"),
    ("MANUFACTURER", "Proizvajalec"),
  ];

  public static string KindLabel(string? code) =>
    Kinds.FirstOrDefault(kind => string.Equals(kind.Code, code, StringComparison.Ordinal)).Label ?? "";

  /// <summary>Partner je lahko hkrati dobavitelj in proizvajalec (npr. KARIZMA LUCE v DEMO).</summary>
  public static string Label(bool buyer, bool supplier, bool manufacturer)
  {
    var parts = new List<string>(3);
    if (buyer) parts.Add("kupec");
    if (supplier) parts.Add("dobavitelj");
    if (manufacturer) parts.Add("proizvajalec");
    if (parts.Count == 0) return "—";
    var text = parts.Count == 1 ? parts[0] : string.Join(", ", parts.Take(parts.Count - 1)) + " in " + parts[^1];
    return char.ToUpperInvariant(text[0]) + text[1..];
  }

  public static string SourceLabel(string? source) => source switch
  {
    "MANUAL" => "ročno",
    "PRODUCTS" => "iz izdelkov",
    "SAOP" => "iz SAOP",
    "TYPE" => "iz tipa stranke",
    "DEFAULT" => "privzeto",
    _ => source ?? "",
  };
}

/// <summary>
/// Filtri seznama strank. Ista pravila veljajo na strani in v izvozu (<see cref="CustomerListService.Apply"/>),
/// zato je datoteka natanko to, kar uporabnik vidi. Vrednosti so kode, ki jih nosi tudi naslov strani.
/// </summary>
/// <param name="Role">CUSTOMER (kupci), BOTH (kupci in dobavitelji), SUPPLIER, MANUFACTURER; prazno = vse.</param>
/// <param name="Type">Koda tipa stranke ali NONE (brez tipa).</param>
/// <param name="Activity">ACTIVE ali INACTIVE.</param>
/// <param name="Source">Vir vloge: MANUAL, PRODUCTS, SAOP, TYPE, DEFAULT.</param>
/// <param name="Export">YES ali NO — ali gre v stranke.csv.</param>
/// <param name="Discount">PACKAGING, VALUE, B2BPLUS, OWN_TIERS, GROUP, SPECIAL, EXPORT_GROUPS ali NONE.</param>
/// <param name="Magento">YES ali NO — ali ima Magento skupino.</param>
public sealed record CustomerListQuery(
  int? OrganizationId = null, string? Role = null, string? Search = null, string? Type = null,
  string? Activity = null, string? Source = null, string? Export = null, string? Discount = null,
  string? Magento = null)
{
  /// <summary>Parametri naslova, isti na strani in na povezavi za izvoz.</summary>
  public static CustomerListQuery FromQuery(Func<string, string?> value) => new(
    int.TryParse(value("podjetje"), out var organization) && organization > 0 ? organization : null,
    value("vloga"), value("isci"), value("tip"), value("aktivnost"), value("vir"), value("izvoz"),
    value("popust"), value("magento"));

  public string ToQueryString()
  {
    var parameters = new List<string>();
    Add("podjetje", OrganizationId?.ToString());
    Add("vloga", Role);
    Add("isci", Search);
    Add("tip", Type);
    Add("aktivnost", Activity);
    Add("vir", Source);
    Add("izvoz", Export);
    Add("popust", Discount);
    Add("magento", Magento);
    return string.Join('&', parameters);

    void Add(string name, string? value)
    {
      if (!string.IsNullOrWhiteSpace(value)) parameters.Add(name + "=" + Uri.EscapeDataString(value.Trim()));
    }
  }
}

/// <summary>
/// Seznam strank vseh podjetij (migracija 250). Prej je stran brala samo prvo aktivno podjetje
/// (DEMO) — IQLighting, Vidadria in Ediito niso bili vidni. Podjetje je zdaj filter, privzeto so
/// vsa; šifra stranke je enolična samo znotraj podjetja, zato ima vsaka vrstica svoje podjetje.
/// </summary>
public sealed class CustomerListService(IConfiguration configuration)
{
  string ConnectionString => ConnectionStringResolver.Resolve(configuration)
    ?? throw new InvalidOperationException("Povezava PIM ni nastavljena.");

  public async Task<IReadOnlyList<CustomerListRow>> GetAsync(int? organizationId, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.GetCustomerList", connection)
    {
      CommandType = CommandType.StoredProcedure,
      CommandTimeout = 120,
    };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = (object?)organizationId ?? DBNull.Value;

    var rows = new List<CustomerListRow>();
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    while (await reader.ReadAsync(cancellationToken))
    {
      rows.Add(new(
        PimDb.Int64(reader, "CustomerId"), PimDb.Int32(reader, "OrganizationId"), PimDb.TextOrEmpty(reader, "OrganizationName"),
        PimDb.TextOrEmpty(reader, "CustomerKey"), PimDb.TextOrEmpty(reader, "Name"),
        PimDb.Text(reader, "City"), PimDb.Text(reader, "TaxNumber"),
        PimDb.Bool(reader, "IsActive"), PimDb.Bool(reader, "SourceIsActive"), PimDb.Text(reader, "SaopPartnerType"),
        PimDb.Text(reader, "PriceListCode"), PimDb.Text(reader, "DiscountPriceListCode"), PimDb.Bool(reader, "HasProfile"),
        PimDb.Text(reader, "CustomerTypeCode"), PimDb.Text(reader, "CustomerTypeName"), PimDb.Text(reader, "MagentoGroupKey"),
        PimDb.Text(reader, "ManualKind"), PimDb.Text(reader, "PayerKind"),
        PimDb.Int32(reader, "SuppliedProductCount"), PimDb.Int32(reader, "ManufacturedProductCount"),
        PimDb.Bool(reader, "PackagingDiscountEnabled"), PimDb.Bool(reader, "ValueDiscountEnabled"), PimDb.Bool(reader, "B2bPlusEnabled"),
        PimDb.NullableDateTime(reader, "B2bPlusValidFrom"), PimDb.NullableDateTime(reader, "B2bPlusValidTo"), PimDb.Bool(reader, "WebEnabled"),
        PimDb.Text(reader, "Email"), PimDb.Text(reader, "Phone"), PimDb.Text(reader, "Mobile"), PimDb.Text(reader, "Persons"),
        PimDb.Bool(reader, "IsSupplier"), PimDb.Bool(reader, "IsManufacturer"), PimDb.Bool(reader, "IsBuyer"),
        PimDb.TextOrEmpty(reader, "RoleSource"), PimDb.Bool(reader, "InCustomerExport"),
        PimDb.NullableDecimal(reader, "Tier1Threshold"), PimDb.NullableDecimal(reader, "Tier1Percent"),
        PimDb.NullableDecimal(reader, "Tier2Threshold"), PimDb.NullableDecimal(reader, "Tier2Percent"),
        PimDb.NullableDecimal(reader, "Tier3Threshold"), PimDb.NullableDecimal(reader, "Tier3Percent"),
        PimDb.Text(reader, "GroupDiscounts"), PimDb.Text(reader, "SpecialDiscounts"), PimDb.Text(reader, "ExportGroupDiscounts")));
    }

    return rows;
  }

  /// <summary>Vse filtre razen podjetja; podjetje zoži že bralna procedura.</summary>
  /// <param name="ignoreRole">Števci zavihkov štejejo vrstice ob vseh drugih filtrih, brez vloge same.</param>
  public static IEnumerable<CustomerListRow> Apply(IEnumerable<CustomerListRow> rows, CustomerListQuery query, bool ignoreRole = false)
  {
    var search = query.Search?.Trim();
    return rows.Where(row =>
      (query.OrganizationId is null || row.OrganizationId == query.OrganizationId)
      && (ignoreRole || MatchesRole(row, query.Role))
      && (string.IsNullOrEmpty(search)
        || row.CustomerKey.Contains(search, StringComparison.OrdinalIgnoreCase)
        || row.Name.Contains(search, StringComparison.OrdinalIgnoreCase)
        || (row.TaxNumber?.Contains(search, StringComparison.OrdinalIgnoreCase) ?? false)
        || (row.City?.Contains(search, StringComparison.OrdinalIgnoreCase) ?? false))
      && Matches(query.Type, value => value == "NONE" ? row.CustomerTypeCode is null : string.Equals(row.CustomerTypeCode, value, StringComparison.OrdinalIgnoreCase))
      && Matches(query.Activity, value => value switch { "ACTIVE" => row.IsActive, "INACTIVE" => !row.IsActive, _ => true })
      && Matches(query.Source, value => string.Equals(row.RoleSource, value, StringComparison.OrdinalIgnoreCase))
      && Matches(query.Export, value => value switch { "YES" => row.InCustomerExport, "NO" => !row.InCustomerExport, _ => true })
      && Matches(query.Magento, value => value switch { "YES" => row.MagentoGroupKey is not null, "NO" => row.MagentoGroupKey is null, _ => true })
      && Matches(query.Discount, value => MatchesDiscount(row, value)));

    static bool Matches(string? filter, Func<string, bool> predicate) =>
      string.IsNullOrWhiteSpace(filter) || predicate(filter.Trim().ToUpperInvariant());
  }

  /// <summary>Zavihki strani. Partner je lahko v več zavihkih — dobavitelj in proizvajalec hkrati.</summary>
  public static bool MatchesRole(CustomerListRow row, string? role) => role?.Trim().ToUpperInvariant() switch
  {
    null or "" => true,
    "CUSTOMER" => row.IsBuyer,
    "BOTH" => row.IsBuyer && row.IsSupplier,
    "SUPPLIER" => row.IsSupplier,
    "MANUFACTURER" => row.IsManufacturer,
    _ => false,
  };

  static bool MatchesDiscount(CustomerListRow row, string value) => value switch
  {
    "PACKAGING" => row.PackagingDiscountEnabled,
    "VALUE" => row.ValueDiscountEnabled,
    "B2BPLUS" => row.B2bPlusEnabled,
    "OWN_TIERS" => row.HasOwnTiers,
    "GROUP" => row.GroupDiscountCount > 0,
    "SPECIAL" => row.SpecialDiscountCount > 0,
    "EXPORT_GROUPS" => row.ExportGroupDiscounts is not null,
    "NONE" => !row.PackagingDiscountEnabled && !row.ValueDiscountEnabled && !row.B2bPlusEnabled && !row.HasOwnTiers
      && row.GroupDiscountCount == 0 && row.SpecialDiscountCount == 0,
    _ => true,
  };
}
