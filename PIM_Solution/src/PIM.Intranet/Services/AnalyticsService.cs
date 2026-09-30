using System.Data;
using System.Globalization;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using PIM.Operations;
using static PIM.Intranet.Services.PimDb;

namespace PIM.Intranet.Services;

/*
  Analitika prodaje, zalog in nabave (migracija 284). Samo bere preračunane tabele ana.* prek
  postopkov; edini zapis so nastavitve formule (ana.SaveSettings, politika AnalyticsSettings, z zgodovino).
  Podatke polni PIM.SaopAnalyticsWorker (posel SAOP_ANALYTICS_IMPORT), preračun ana.RefreshAnalytics.
*/

/// <summary>Signali artikla: koda iz ana.ItemMetric.Signal, vidno ime, ton čipa in kaj naj uporabnik naredi.</summary>
public static class AnalyticsSignals
{
  public const string Stockout = "BREZ_ZALOGE";
  public const string Order = "NAROCI";
  public const string Dead = "ZALEZANO";
  public const string Overstock = "PREVEC";
  public const string Ok = "V_REDU";
  public const string Inactive = "NEAKTIVNO";

  public sealed record Signal(string Code, string Label, string? Tone, string Hint);

  public static IReadOnlyList<Signal> All { get; } =
  [
    new(Stockout, "Ni zaloge", "bad", "Artikel se prodaja, zaloge pa ni. Naroči takoj."),
    new(Order, "Naroči", "warn", "Zaloga z naročenim je pod točko naročila ali pod SAOP minimumom."),
    new(Dead, "Zaležano", "bad", "Zaloga, ki se v izbranem obdobju ni prodala in ni bila na novo prevzeta."),
    new(Overstock, "Preveč zaloge", "warn", "Zaloge je za več dni, kot je nastavljena meja pokritosti."),
    new(Ok, "V redu", "good", "Zaloga ustreza prodaji."),
    new(Inactive, "Brez prometa", null, "Ni zaloge in ni prodaje."),
  ];

  public static Signal Find(string? code) => All.FirstOrDefault(s => s.Code == code) ?? All[^1];
}

public sealed record AnalyticsItemFilter(
  string? Search = null, string? SupplierId = null, string? Signal = null, string? Abc = null,
  string? Sort = null, bool Descending = true, int Skip = 0, int Take = 50);

/// <summary>Ista imena parametrov v naslovu strani in v izvozu: povezavo se da deliti, izvoz = zaslon.</summary>
public static class AnalyticsQuery
{
  public static AnalyticsItemFilter FromQuery(Func<string, string?> read) => new(
    Search: read("isci"),
    SupplierId: read("dobavitelj"),
    Signal: AnalyticsSignals.All.Any(s => s.Code == read("signal")) ? read("signal") : null,
    Abc: read("abc") is "A" or "B" or "C" ? read("abc") : null,
    Sort: read("razvrsti"),
    Descending: read("smer") != "nar",
    Skip: int.TryParse(read("stran"), out var page) && page > 1 ? (page - 1) * 50 : 0);

  public static string ToQueryString(AnalyticsItemFilter filter, int page = 1)
  {
    var parts = new List<string>();
    void Add(string name, string? value) { if (!string.IsNullOrWhiteSpace(value)) parts.Add($"{name}={Uri.EscapeDataString(value)}"); }
    Add("isci", filter.Search);
    Add("dobavitelj", filter.SupplierId);
    Add("signal", filter.Signal);
    Add("abc", filter.Abc);
    Add("razvrsti", filter.Sort);
    if (!filter.Descending) Add("smer", "nar");
    if (page > 1) Add("stran", page.ToString(CultureInfo.InvariantCulture));
    return string.Join("&", parts);
  }
}

public sealed record AnalyticsKpi(
  decimal? Sales12Net, decimal? SalesPrev12Net, decimal? Sales12Qty, decimal? Sales12Margin, decimal? SalesYtdNet,
  decimal? StockValue, int ItemsInStock, int StockWithoutCost, decimal? DeadStockValue, int DeadItems,
  decimal? OverstockValue, int OverstockItems, int ToOrderItems, decimal? ToOrderValue, int StockoutItems,
  DateTime? CalculatedUtc, string? DemandSource);

public sealed record AnalyticsMonth(DateTime MonthStart, decimal Qty, decimal? Net, decimal? Margin, decimal? Ordered, decimal? PrevYearQty, decimal? PrevYearNet);
public sealed record AnalyticsSignalCount(string Signal, int Items, decimal? StockValue, decimal? SuggestedValue, decimal? ExcessValue);
public sealed record AnalyticsTopSupplier(string SupplierId, string? SupplierName, decimal? Sales365Net, decimal? YoyPct, decimal? StockValue, int ItemsToOrder, decimal? SuggestedOrderValue, decimal? DeadStockValue);
public sealed record AnalyticsTopItem(long ProductId, string ItemId, string? ItemName, decimal Sales365Qty, decimal? Sales365Net, decimal? YoyPct, decimal Stock, string Signal);
public sealed record AnalyticsTopCustomer(string? CustomerId, string? CustomerName, decimal? Net, int Invoices);
public sealed record AnalyticsStream(string Stream, DateTime? LastAttemptUtc, DateTime? LastSuccessUtc, int? LastRowCount, string? LastError);

public sealed record AnalyticsOverview(
  AnalyticsKpi Kpi, IReadOnlyList<AnalyticsMonth> Months, IReadOnlyList<AnalyticsSignalCount> Signals,
  IReadOnlyList<AnalyticsTopSupplier> TopSuppliers, IReadOnlyList<AnalyticsTopItem> TopItems,
  IReadOnlyList<AnalyticsTopCustomer> TopCustomers, IReadOnlyList<AnalyticsStream> Streams, string? SupplierName)
{
  public bool HasData => Kpi.CalculatedUtc is not null;
}

public sealed record AnalyticsItemRow(
  long ProductId, string ItemId, string? ItemName, string? Ean, string SupplierId, string? SupplierName, string? AbcClass, string? XyzClass,
  string Signal, decimal Stock, decimal Available, decimal OnOrder, DateTime? NextDeliveryDate, decimal? UnitCost, decimal? StockValue,
  decimal Sales30Qty, decimal Sales90Qty, decimal Sales365Qty, decimal? Sales365Net, decimal? Sales365Margin, decimal? TrendPct, decimal? YoyPct,
  int? CoverDays, DateTime? LastSaleDate, int LeadTimeDays, string LeadTimeSource, decimal ReorderPoint, decimal OrderUpToLevel,
  decimal SuggestedQty, decimal? SuggestedValue, string? SuggestionReason, decimal ExcessQty, decimal? ExcessValue,
  decimal? PolicyMin, decimal? PolicyMax, decimal OrderMultiple, decimal SafetyStock, decimal DailyDemand);

public sealed record AnalyticsItemPage(IReadOnlyList<AnalyticsItemRow> Rows, long Total, IReadOnlyDictionary<string, int> SignalCounts);

public sealed record AnalyticsSupplierRow(
  string SupplierId, string? SupplierName, int Items, int ItemsInStock, int ItemsSold365, decimal? StockValue, decimal? Sales365Net,
  decimal? SalesPrev365Net, decimal? Sales365Margin, decimal? YoyPct, int ItemsToOrder, decimal? SuggestedOrderValue, int StockoutItems,
  int DeadItems, decimal? DeadStockValue, decimal? OverstockValue, decimal? LeadTimeAvgDays, int LeadTimeSamples,
  int OpenPurchaseLines, int OverduePurchaseLines, DateTime? LastPurchaseOrderDate);

public sealed record AnalyticsItemDetail(
  AnalyticsItemRow Item, string LeadTimeSourceLabel, int LeadTimeSamples, string? CostSource, DateTime? LastReceiptDate, int Customers365,
  string DemandSource, DateTime CalculatedUtc, decimal ServiceLevelZ, int ReviewPeriodDays, int DemandWindowDays, int DeadStockDays, int OverstockCoverDays,
  IReadOnlyList<AnalyticsMonth> Months, IReadOnlyList<AnalyticsPurchase> Purchases, IReadOnlyList<AnalyticsItemCustomer> Customers,
  IReadOnlyList<AnalyticsStockPoint> Stock);

public sealed record AnalyticsPurchase(string Source, string Document, string? SupplierId, DateTime? OrderDate, decimal? Qty, decimal? ReceivedQty,
  DateTime? ExpectedDate, DateTime? ReceivedDate, int? LeadTimeDays, string? Status);
public sealed record AnalyticsItemCustomer(string? CustomerId, string? CustomerName, decimal Qty, decimal? Net, DateTime? LastDate);
public sealed record AnalyticsStockPoint(DateTime Date, decimal Quantity);

public sealed record AnalyticsSettings(
  int OrganizationId, decimal ServiceLevelZ, int ReviewPeriodDays, int DefaultLeadTimeDays, int DemandWindowDays, int DeadStockDays,
  int OverstockCoverDays, string CostPriceList, DateTime UpdatedUtc, string UpdatedBy);
public sealed record AnalyticsSettingsChange(long Id, string? OldValueJson, string NewValueJson, DateTime ChangedUtc, string ChangedBy);
public sealed record AnalyticsSettingsView(AnalyticsSettings Settings, IReadOnlyList<AnalyticsSettingsChange> History, IReadOnlyList<string> PriceLists);

public sealed class AnalyticsService(IConfiguration configuration, PimWriteGuard guard)
{
  string ConnectionString => ConnectionStringResolver.Resolve(configuration) ?? throw new InvalidOperationException("Povezava PIM ni nastavljena.");

  public static string DemandSourceLabel(string? source) => source switch
  {
    "RACUNI" => "izdani računi",
    "VNK" => "odpremljena naročila kupcev (VNK)",
    "BARKAWI_CO" => "odpremljena naročila kupcev (Barkawi)",
    "BREZ" => "ni podatkov o prodaji",
    _ => "še ni preračunano",
  };

  public static string StreamLabel(string stream) => stream switch
  {
    "RACUNI" => "Računi (prodaja)",
    "NAROCILA_KUPCEV" => "Naročila kupcev",
    "NAROCILA_DOBAVITELJEM" => "Naročila dobaviteljem in prevzemi",
    "NABAVNI_PODATKI" => "Nabavni podatki",
    "IZRACUN" => "Preračun",
    _ => stream,
  };

  public static string LeadTimeSourceLabel(string? source) => source switch
  {
    "IZMERJEN" => "izmerjen iz prevzemov artikla",
    "DOBAVITELJ" => "povprečje prevzemov dobavitelja",
    "SAOP" => "nabavni čas iz SAOP",
    _ => "privzeta vrednost iz nastavitev",
  };

  // ─── Pregled ────────────────────────────────────────────────────────────────

  public async Task<AnalyticsOverview> GetOverviewAsync(int organizationId, string? supplierId, CancellationToken ct = default)
  {
    await using var connection = await OpenAsync(ct);
    await using var command = Procedure(connection, "ana.GetOverview");
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@SupplierId", SqlDbType.NVarChar, 100).Value = (object?)NullIfEmpty(supplierId) ?? DBNull.Value;
    await using var r = await command.ExecuteReaderAsync(ct);

    await r.ReadAsync(ct);
    var kpi = new AnalyticsKpi(
      NullableDecimal(r, "Sales12Net"), NullableDecimal(r, "SalesPrev12Net"), NullableDecimal(r, "Sales12Qty"), NullableDecimal(r, "Sales12Margin"),
      NullableDecimal(r, "SalesYtdNet"), NullableDecimal(r, "StockValue"), IntOrZero(r, "ItemsInStock"), IntOrZero(r, "StockWithoutCost"),
      NullableDecimal(r, "DeadStockValue"), IntOrZero(r, "DeadItems"), NullableDecimal(r, "OverstockValue"), IntOrZero(r, "OverstockItems"),
      IntOrZero(r, "ToOrderItems"), NullableDecimal(r, "ToOrderValue"), IntOrZero(r, "StockoutItems"),
      NullableDateTime(r, "CalculatedUtc"), Text(r, "DemandSource"));

    var months = new List<AnalyticsMonth>();
    await r.NextResultAsync(ct);
    while (await r.ReadAsync(ct))
      months.Add(new(DateTimeValue(r, "MonthStart"), Decimal(r, "Qty"), NullableDecimal(r, "Net"), NullableDecimal(r, "Margin"),
        NullableDecimal(r, "Ordered"), NullableDecimal(r, "PrevYearQty"), NullableDecimal(r, "PrevYearNet")));

    var signals = new List<AnalyticsSignalCount>();
    await r.NextResultAsync(ct);
    while (await r.ReadAsync(ct))
      signals.Add(new(TextOrEmpty(r, "Signal"), Int32(r, "Items"), NullableDecimal(r, "StockValue"), NullableDecimal(r, "SuggestedValue"), NullableDecimal(r, "ExcessValue")));

    var suppliers = new List<AnalyticsTopSupplier>();
    await r.NextResultAsync(ct);
    while (await r.ReadAsync(ct))
      suppliers.Add(new(TextOrEmpty(r, "SupplierId"), Text(r, "SupplierName"), NullableDecimal(r, "Sales365Net"), NullableDecimal(r, "YoyPct"),
        NullableDecimal(r, "StockValue"), Int32(r, "ItemsToOrder"), NullableDecimal(r, "SuggestedOrderValue"), NullableDecimal(r, "DeadStockValue")));

    var items = new List<AnalyticsTopItem>();
    await r.NextResultAsync(ct);
    while (await r.ReadAsync(ct))
      items.Add(new(Int64(r, "ProductId"), TextOrEmpty(r, "ItemId"), Text(r, "ItemName"), Decimal(r, "Sales365Qty"), NullableDecimal(r, "Sales365Net"),
        NullableDecimal(r, "YoyPct"), Decimal(r, "Stock"), TextOrEmpty(r, "Signal")));

    var customers = new List<AnalyticsTopCustomer>();
    await r.NextResultAsync(ct);
    while (await r.ReadAsync(ct))
      customers.Add(new(Text(r, "CustomerId"), Text(r, "CustomerName"), NullableDecimal(r, "Net"), Int32(r, "Invoices")));

    var streams = new List<AnalyticsStream>();
    await r.NextResultAsync(ct);
    while (await r.ReadAsync(ct))
      streams.Add(new(TextOrEmpty(r, "Stream"), NullableDateTime(r, "LastAttemptUtc"), NullableDateTime(r, "LastSuccessUtc"),
        r.IsDBNull(r.GetOrdinal("LastRowCount")) ? null : Int32(r, "LastRowCount"), Text(r, "LastError")));

    string? supplierName = null;
    if (await r.NextResultAsync(ct) && await r.ReadAsync(ct)) supplierName = Text(r, "SupplierName");

    return new(kpi, months, signals, suppliers, items, customers, streams, supplierName);
  }

  // ─── Artikli ────────────────────────────────────────────────────────────────

  public async Task<AnalyticsItemPage> GetItemsAsync(int organizationId, AnalyticsItemFilter filter, IReadOnlyCollection<long>? productIds = null, CancellationToken ct = default)
  {
    await using var connection = await OpenAsync(ct);
    await using var command = Procedure(connection, "ana.GetItemMetrics");
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@Search", SqlDbType.NVarChar, 200).Value = (object?)NullIfEmpty(filter.Search) ?? DBNull.Value;
    command.Parameters.Add("@SupplierId", SqlDbType.NVarChar, 100).Value = (object?)NullIfEmpty(filter.SupplierId) ?? DBNull.Value;
    command.Parameters.Add("@Signal", SqlDbType.NVarChar, 20).Value = (object?)NullIfEmpty(filter.Signal) ?? DBNull.Value;
    command.Parameters.Add("@Abc", SqlDbType.Char, 1).Value = (object?)NullIfEmpty(filter.Abc) ?? DBNull.Value;
    command.Parameters.Add("@Sort", SqlDbType.NVarChar, 20).Value = (object?)NullIfEmpty(filter.Sort) ?? DBNull.Value;
    command.Parameters.Add("@Descending", SqlDbType.Bit).Value = filter.Descending;
    command.Parameters.Add("@Skip", SqlDbType.Int).Value = filter.Skip;
    command.Parameters.Add("@Take", SqlDbType.Int).Value = filter.Take;
    command.Parameters.Add("@ProductIdsJson", SqlDbType.NVarChar, -1).Value =
      productIds is null ? DBNull.Value : JsonSerializer.Serialize(productIds);
    await using var r = await command.ExecuteReaderAsync(ct);

    var rows = new List<AnalyticsItemRow>();
    while (await r.ReadAsync(ct)) rows.Add(MapItem(r));
    long total = 0;
    if (await r.NextResultAsync(ct) && await r.ReadAsync(ct)) total = Int64(r, "Total");
    var counts = new Dictionary<string, int>(StringComparer.Ordinal);
    if (await r.NextResultAsync(ct)) while (await r.ReadAsync(ct)) counts[TextOrEmpty(r, "Signal")] = Int32(r, "Items");
    return new(rows, total, counts);
  }

  static AnalyticsItemRow MapItem(SqlDataReader r) => new(
    Int64(r, "ProductId"), TextOrEmpty(r, "ItemId"), Text(r, "ItemName"), Text(r, "Ean"), TextOrEmpty(r, "SupplierId"), Text(r, "SupplierName"),
    Text(r, "AbcClass"), Text(r, "XyzClass"), TextOrEmpty(r, "Signal"), Decimal(r, "Stock"), Decimal(r, "Available"), Decimal(r, "OnOrder"),
    NullableDateTime(r, "NextDeliveryDate"), NullableDecimal(r, "UnitCost"), NullableDecimal(r, "StockValue"),
    Decimal(r, "Sales30Qty"), Decimal(r, "Sales90Qty"), Decimal(r, "Sales365Qty"), NullableDecimal(r, "Sales365Net"), NullableDecimal(r, "Sales365Margin"),
    NullableDecimal(r, "TrendPct"), NullableDecimal(r, "YoyPct"), r.IsDBNull(r.GetOrdinal("CoverDays")) ? null : Int32(r, "CoverDays"),
    NullableDateTime(r, "LastSaleDate"), Int32(r, "LeadTimeDays"), TextOrEmpty(r, "LeadTimeSource"), Decimal(r, "ReorderPoint"),
    Decimal(r, "OrderUpToLevel"), Decimal(r, "SuggestedQty"), NullableDecimal(r, "SuggestedValue"), Text(r, "SuggestionReason"),
    Decimal(r, "ExcessQty"), NullableDecimal(r, "ExcessValue"), NullableDecimal(r, "PolicyMin"), NullableDecimal(r, "PolicyMax"),
    Decimal(r, "OrderMultiple"), Decimal(r, "SafetyStock"), Decimal(r, "DailyDemand"));

  // ─── Dobavitelji ────────────────────────────────────────────────────────────

  public async Task<(IReadOnlyList<AnalyticsSupplierRow> Rows, long Total)> GetSuppliersAsync(
    int organizationId, string? search, string? sort, bool descending, int skip, int take, bool onlyActive, CancellationToken ct = default)
  {
    await using var connection = await OpenAsync(ct);
    await using var command = Procedure(connection, "ana.GetSupplierMetrics");
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@Search", SqlDbType.NVarChar, 200).Value = (object?)NullIfEmpty(search) ?? DBNull.Value;
    command.Parameters.Add("@Sort", SqlDbType.NVarChar, 20).Value = (object?)NullIfEmpty(sort) ?? DBNull.Value;
    command.Parameters.Add("@Descending", SqlDbType.Bit).Value = descending;
    command.Parameters.Add("@Skip", SqlDbType.Int).Value = skip;
    command.Parameters.Add("@Take", SqlDbType.Int).Value = take;
    command.Parameters.Add("@OnlyActive", SqlDbType.Bit).Value = onlyActive;
    await using var r = await command.ExecuteReaderAsync(ct);
    var rows = new List<AnalyticsSupplierRow>();
    while (await r.ReadAsync(ct))
      rows.Add(new(TextOrEmpty(r, "SupplierId"), Text(r, "SupplierName"), Int32(r, "Items"), Int32(r, "ItemsInStock"), Int32(r, "ItemsSold365"),
        NullableDecimal(r, "StockValue"), NullableDecimal(r, "Sales365Net"), NullableDecimal(r, "SalesPrev365Net"), NullableDecimal(r, "Sales365Margin"),
        NullableDecimal(r, "YoyPct"), Int32(r, "ItemsToOrder"), NullableDecimal(r, "SuggestedOrderValue"), Int32(r, "StockoutItems"), Int32(r, "DeadItems"),
        NullableDecimal(r, "DeadStockValue"), NullableDecimal(r, "OverstockValue"), NullableDecimal(r, "LeadTimeAvgDays"), Int32(r, "LeadTimeSamples"),
        Int32(r, "OpenPurchaseLines"), Int32(r, "OverduePurchaseLines"), NullableDateTime(r, "LastPurchaseOrderDate")));
    long total = 0;
    if (await r.NextResultAsync(ct) && await r.ReadAsync(ct)) total = Int64(r, "Total");
    return (rows, total);
  }

  // ─── Kartica artikla ────────────────────────────────────────────────────────

  public async Task<AnalyticsItemDetail?> GetItemDetailAsync(int organizationId, long productId, CancellationToken ct = default)
  {
    await using var connection = await OpenAsync(ct);
    await using var command = Procedure(connection, "ana.GetItemDetail");
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@ProductId", SqlDbType.BigInt).Value = productId;
    await using var r = await command.ExecuteReaderAsync(ct);
    if (!await r.ReadAsync(ct)) return null;
    var item = MapItem(r);
    var leadSource = TextOrEmpty(r, "LeadTimeSource");
    var samples = Int32(r, "LeadTimeSamples");
    var costSource = Text(r, "CostSource");
    var lastReceipt = NullableDateTime(r, "LastReceiptDate");
    var customers365 = Int32(r, "Customers365");
    var demandSource = TextOrEmpty(r, "DemandSource");
    var calculated = DateTimeValue(r, "CalculatedUtc");
    var z = Decimal(r, "ServiceLevelZ");
    var review = Int32(r, "ReviewPeriodDays");
    var window = Int32(r, "DemandWindowDays");
    var dead = Int32(r, "DeadStockDays");
    var over = Int32(r, "OverstockCoverDays");

    var months = new List<AnalyticsMonth>();
    await r.NextResultAsync(ct);
    while (await r.ReadAsync(ct))
      months.Add(new(DateTimeValue(r, "MonthStart"), Decimal(r, "Qty"), NullableDecimal(r, "Net"), null, NullableDecimal(r, "Ordered"), NullableDecimal(r, "PrevYearQty"), null));

    var purchases = new List<AnalyticsPurchase>();
    await r.NextResultAsync(ct);
    while (await r.ReadAsync(ct))
      purchases.Add(new(TextOrEmpty(r, "Source"), TextOrEmpty(r, "Document"), Text(r, "SupplierId"), NullableDateTime(r, "OrderDate"),
        NullableDecimal(r, "Qty"), NullableDecimal(r, "ReceivedQty"), NullableDateTime(r, "ExpectedDate"), NullableDateTime(r, "ReceivedDate"),
        r.IsDBNull(r.GetOrdinal("LeadTimeDays")) ? null : Int32(r, "LeadTimeDays"), Text(r, "Status")));

    var customers = new List<AnalyticsItemCustomer>();
    await r.NextResultAsync(ct);
    while (await r.ReadAsync(ct))
      customers.Add(new(Text(r, "CustomerId"), Text(r, "CustomerName"), Decimal(r, "Qty"), NullableDecimal(r, "Net"), NullableDateTime(r, "LastDate")));

    var stock = new List<AnalyticsStockPoint>();
    await r.NextResultAsync(ct);
    while (await r.ReadAsync(ct)) stock.Add(new(DateTimeValue(r, "SnapshotDate"), Decimal(r, "Quantity")));

    return new(item, LeadTimeSourceLabel(leadSource), samples, costSource, lastReceipt, customers365, demandSource, calculated,
      z, review, window, dead, over, months, purchases, customers, stock);
  }

  // ─── Nastavitve ─────────────────────────────────────────────────────────────

  public async Task<AnalyticsSettingsView> GetSettingsAsync(int organizationId, CancellationToken ct = default)
  {
    await using var connection = await OpenAsync(ct);
    await using var command = Procedure(connection, "ana.GetSettings");
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    await using var r = await command.ExecuteReaderAsync(ct);
    if (!await r.ReadAsync(ct)) throw new InvalidOperationException("Nastavitev analitike za podjetje ni.");
    var settings = new AnalyticsSettings(Int32(r, "OrganizationId"), Decimal(r, "ServiceLevelZ"), Int32(r, "ReviewPeriodDays"),
      Int32(r, "DefaultLeadTimeDays"), Int32(r, "DemandWindowDays"), Int32(r, "DeadStockDays"), Int32(r, "OverstockCoverDays"),
      TextOrEmpty(r, "CostPriceList"), DateTimeValue(r, "UpdatedUtc"), TextOrEmpty(r, "UpdatedBy"));
    var history = new List<AnalyticsSettingsChange>();
    await r.NextResultAsync(ct);
    while (await r.ReadAsync(ct))
      history.Add(new(Int64(r, "SettingHistoryId"), Text(r, "OldValueJson"), TextOrEmpty(r, "NewValueJson"), DateTimeValue(r, "ChangedUtc"), TextOrEmpty(r, "ChangedBy")));
    var priceLists = new List<string>();
    await r.NextResultAsync(ct);
    while (await r.ReadAsync(ct)) priceLists.Add(TextOrEmpty(r, "PriceList"));
    return new(settings, history, priceLists);
  }

  public Task<bool> CanEditSettingsAsync() => guard.AllowsAsync(PimPolicies.AnalyticsSettings);

  /// <summary>Shrani parametre formule (z zgodovino). Učinek pride ob naslednjem preračunu ali takoj z <see cref="RefreshAsync"/>.</summary>
  public async Task SaveSettingsAsync(AnalyticsSettings settings, CancellationToken ct = default)
  {
    var actor = await guard.RequireAsync(PimPolicies.AnalyticsSettings);
    await using var connection = await OpenAsync(ct);
    await using var command = Procedure(connection, "ana.SaveSettings");
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = settings.OrganizationId;
    command.Parameters.Add("@ServiceLevelZ", SqlDbType.Decimal).Value = settings.ServiceLevelZ;
    command.Parameters["@ServiceLevelZ"].Precision = 5; command.Parameters["@ServiceLevelZ"].Scale = 2;
    command.Parameters.Add("@ReviewPeriodDays", SqlDbType.Int).Value = settings.ReviewPeriodDays;
    command.Parameters.Add("@DefaultLeadTimeDays", SqlDbType.Int).Value = settings.DefaultLeadTimeDays;
    command.Parameters.Add("@DemandWindowDays", SqlDbType.Int).Value = settings.DemandWindowDays;
    command.Parameters.Add("@DeadStockDays", SqlDbType.Int).Value = settings.DeadStockDays;
    command.Parameters.Add("@OverstockCoverDays", SqlDbType.Int).Value = settings.OverstockCoverDays;
    command.Parameters.Add("@CostPriceList", SqlDbType.NVarChar, 40).Value = settings.CostPriceList;
    command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
    await command.ExecuteNonQueryAsync(ct);
  }

  /// <summary>Takojšen preračun (samo baza, brez SAOP). Vrne povzetek za sporočilo po shranjevanju.</summary>
  public async Task<string> RefreshAsync(int organizationId, CancellationToken ct = default)
  {
    await guard.RequireAsync(PimPolicies.AnalyticsSettings);
    await using var connection = await OpenAsync(ct);
    await using var command = Procedure(connection, "ana.RefreshAnalytics");
    command.CommandTimeout = 900;
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    await using var r = await command.ExecuteReaderAsync(ct);
    string summary = "Preračun končan.";
    do
    {
      while (await r.ReadAsync(ct))
        if (r.FieldCount >= 6 && r.GetName(0) == "DemandSource")
          summary = $"Preračunano {Int32(r, "Items"):N0} artiklov: za naročilo {Int32(r, "ToOrder"):N0}, brez zaloge {Int32(r, "Stockouts"):N0}, "
            + $"zaležanih {Int32(r, "Dead"):N0}, preveč zaloge {Int32(r, "Overstock"):N0}.";
    } while (await r.NextResultAsync(ct));
    return summary;
  }

  // ─── Izvoz v Excel ──────────────────────────────────────────────────────────

  public async Task<byte[]> BuildItemsWorkbookAsync(int organizationId, AnalyticsItemFilter filter, IReadOnlyCollection<long>? productIds, CancellationToken ct = default)
  {
    var page = await GetItemsAsync(organizationId, filter with { Skip = 0, Take = WorkbookWriter.MaxRows }, productIds, ct);
    WorkbookColumn Text(string header, double width = 14, string? group = null) => new(header, WorkbookCellKind.Text, width, group);
    WorkbookColumn Number(string header, double width = 12, string? group = null) => new(header, WorkbookCellKind.Number, width, group);
    WorkbookColumn Date(string header, string? group = null) => new(header, WorkbookCellKind.DateTime, 12, group);
    IReadOnlyList<WorkbookColumn> columns =
    [
      Text("Šifra", 16, "Artikel"), Text("Naziv (ERP, sicer spletni)", 40, "Artikel"), Text("EAN", 15, "Artikel"), Text("Dobavitelj", 12, "Artikel"),
      Text("Ime dobavitelja", 28, "Artikel"), Text("ABC"), Text("XYZ"), Text("Signal", 14),
      Number("Zaloga", 10, "Zaloga"), Number("Razpoložljivo", 12, "Zaloga"), Number("Naročeno pri dobaviteljih", 14, "Zaloga"), Date("Naslednja dobava", "Zaloga"),
      Number("Nabavna cena", 12, "Zaloga"), Number("Vrednost zaloge", 14, "Zaloga"),
      Number("Prodano 30 dni", 12, "Prodaja"), Number("Prodano 90 dni", 12, "Prodaja"), Number("Prodano 365 dni", 12, "Prodaja"),
      Number("Promet 365 dni €", 14, "Prodaja"), Number("Razlika v ceni 365 dni €", 14, "Prodaja"), Number("Trend 3 mes. %", 10, "Prodaja"),
      Number("Glede na lani %", 10, "Prodaja"), Date("Zadnja prodaja", "Prodaja"), Number("Pokritost (dni)", 10, "Prodaja"),
      Number("Dobavni čas (dni)", 10, "Predlog"), Text("Vir dobavnega časa", 14, "Predlog"), Number("Varnostna zaloga", 10, "Predlog"),
      Number("Točka naročila", 10, "Predlog"), Number("Ciljna zaloga", 10, "Predlog"), Number("SAOP MIN", 10, "Predlog"), Number("SAOP MAX", 10, "Predlog"),
      Number("Večkratnik", 10, "Predlog"), Number("Predlog količine", 12, "Predlog"), Number("Predlog vrednost €", 12, "Predlog"),
      Text("Razlog", 30, "Predlog"), Number("Presežek količina", 12, "Presežek"), Number("Presežek vrednost €", 12, "Presežek"),
    ];
    var rows = page.Rows.Select(row => (IReadOnlyList<object?>)
    [
      row.ItemId, row.ItemName, row.Ean, row.SupplierId, row.SupplierName, row.AbcClass, row.XyzClass, AnalyticsSignals.Find(row.Signal).Label,
      row.Stock, row.Available, row.OnOrder, row.NextDeliveryDate, row.UnitCost, row.StockValue,
      row.Sales30Qty, row.Sales90Qty, row.Sales365Qty, row.Sales365Net, row.Sales365Margin, row.TrendPct, row.YoyPct, row.LastSaleDate, row.CoverDays,
      row.LeadTimeDays, LeadTimeSourceLabel(row.LeadTimeSource), Math.Round(row.SafetyStock, 1), Math.Round(row.ReorderPoint, 1),
      Math.Round(row.OrderUpToLevel, 1), row.PolicyMin, row.PolicyMax, row.OrderMultiple, row.SuggestedQty, row.SuggestedValue, row.SuggestionReason,
      row.ExcessQty, row.ExcessValue,
    ]);
    var notes = new List<string>
    {
      $"Izvoženo {DateTime.Now:dd.MM.yyyy HH:mm}; vrstic {page.Rows.Count:N0}" + (page.Total > page.Rows.Count ? $" od {page.Total:N0} (meja {WorkbookWriter.MaxRows:N0})." : "."),
      "Predlog naročila je izračun PIM; v SAOP se nič ne pošlje samo.",
    };
    return WorkbookWriter.Write("Analitika artiklov", columns, rows, notes);
  }

  public async Task<byte[]> BuildSuppliersWorkbookAsync(int organizationId, string? search, string? sort, bool descending, bool onlyActive, CancellationToken ct = default)
  {
    var (rows, _) = await GetSuppliersAsync(organizationId, search, sort, descending, 0, WorkbookWriter.MaxRows, onlyActive, ct);
    WorkbookColumn Number(string header, double width = 12) => new(header, WorkbookCellKind.Number, width);
    IReadOnlyList<WorkbookColumn> columns =
    [
      new("Šifra", WorkbookCellKind.Text, 12), new("Dobavitelj", WorkbookCellKind.Text, 32), Number("Artiklov"), Number("Na zalogi"), Number("Prodanih 365 dni"),
      Number("Vrednost zaloge €", 14), Number("Promet 365 dni €", 14), Number("Promet lani €", 14), Number("Razlika v ceni €", 14), Number("Glede na lani %"),
      Number("Za naročilo (artiklov)"), Number("Predlog naročila €", 14), Number("Brez zaloge"), Number("Zaležanih"), Number("Zaležano €", 14),
      Number("Preveč zaloge €", 14), Number("Povp. dobavni čas (dni)"), Number("Izmerjenih prevzemov"), Number("Odprtih vrstic naročil"),
      Number("Zamujenih vrstic"), new("Zadnje naročilo", WorkbookCellKind.DateTime, 12),
    ];
    var data = rows.Select(s => (IReadOnlyList<object?>)
    [
      s.SupplierId, s.SupplierName ?? (s.SupplierId.Length == 0 ? "Brez dobavitelja" : null), s.Items, s.ItemsInStock, s.ItemsSold365, s.StockValue,
      s.Sales365Net, s.SalesPrev365Net, s.Sales365Margin, s.YoyPct, s.ItemsToOrder, s.SuggestedOrderValue, s.StockoutItems, s.DeadItems, s.DeadStockValue,
      s.OverstockValue, s.LeadTimeAvgDays, s.LeadTimeSamples, s.OpenPurchaseLines, s.OverduePurchaseLines, s.LastPurchaseOrderDate,
    ]);
    return WorkbookWriter.Write("Dobavitelji", columns, data, [$"Izvoženo {DateTime.Now:dd.MM.yyyy HH:mm}; dobaviteljev {rows.Count:N0}."]);
  }

  // ─── Pomočniki ──────────────────────────────────────────────────────────────

  static string? NullIfEmpty(string? value) => string.IsNullOrWhiteSpace(value) ? null : value.Trim();

  static int IntOrZero(SqlDataReader r, string column) => r.IsDBNull(r.GetOrdinal(column)) ? 0 : Int32(r, column);

  async Task<SqlConnection> OpenAsync(CancellationToken ct)
  {
    var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(ct);
    return connection;
  }

  static SqlCommand Procedure(SqlConnection connection, string name) =>
    new(name, connection) { CommandType = CommandType.StoredProcedure, CommandTimeout = 120 };
}
