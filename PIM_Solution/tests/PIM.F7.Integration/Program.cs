using PIM.B2b;

var customerColumns = Columns(
  ("KEY", "customer_key", "Customer.Key", true),
  ("GROUP", "customer_group", "Customer.MagentoGroupKey", true),
  ("FLAGS", "policy_flags", "Customer.Flags", false),
  ("TIERS", "value_tiers", "Customer.ValueTiers", false),
  ("GROUP_DISCOUNTS", "group_discounts", "Customer.GroupDiscounts", false),
  ("SHIPPING", "shipping_policy", "Policy.Shipping", true),
  ("WEB", "web_discount_percent", "Policy.B2bWebPercent", true));
var customers = new[]
{
  new CustomerExportRow("C-1", "INSTALLERS", "INSTALLER", true, true, false, null, null, "PL-1", "DPL-1", null, null,
    [new(1, 800m, 1m), new(2, 1500m, 2m), new(3, 3000m, 3m)], [new("TOOLS", 7.5m, "CUSTOMER")]),
  new CustomerExportRow("C-2", "RESELLERS", "RESELLER", false, true, true, new(2026, 1, 1), new(2026, 12, 31), "PL-2", null, "P-9", "Plačnik, d.o.o.",
    [new(1, 900m, 1.5m), new(2, 1700m, 2.5m), new(3, 3200m, 3.5m)], [new("TOOLS", 6m, "TYPE")])
};

var productColumns = Columns(
  ("ITEM", "sku", "Product.ItemID", true),
  ("GROUP", "customer_group", "Customer.MagentoGroupKey", true),
  ("PAK2", "pak2", "Product.Pak2", true),
  ("S_CODE", "s_code", "Product.PackagingDiscountCode", false),
  ("S_PERCENT", "s_percent", "Product.PackagingDiscountPercent", false),
  ("GATE", "promotion_gate_state", "Product.PromotionGateState", true));
var products = new[]
{
  new ProductExportRow("BA.1", "INSTALLERS", 5m, "S2", 5m, PromotionGateState.Regular),
  new ProductExportRow("BA.1", "RESELLERS", 5m, "S2", 5m, PromotionGateState.Regular),
  new ProductExportRow("NW.2", "INSTALLERS", 12m, "S3", 10m, PromotionGateState.Unknown),
  new ProductExportRow("NW.2", "RESELLERS", 12m, "S3", 10m, PromotionGateState.Unknown)
};

var shippingColumns = Columns(
  ("RULE", "rule_code", "Shipping.RuleCode", true),
  ("ORDER", "order_threshold", "Shipping.OrderThreshold", false),
  ("LENGTH", "package_length_m", "Shipping.PackageLengthMeters", false),
  ("NET", "shipping_net", "Shipping.Net", true),
  ("FREE", "is_free", "Shipping.IsFree", true),
  ("PRIORITY", "priority", "Shipping.Priority", true));
var shipping = new[]
{
  new ShippingPolicyExportRow("STANDARD_PAID", 150m, null, 4.10m, false, 10),
  new ShippingPolicyExportRow("STANDARD_FREE", 150m, null, 0m, true, 20),
  new ShippingPolicyExportRow("OVERSIZE", 300m, 2m, 10m, false, 30),
  new ShippingPolicyExportRow("B2B_PLUS", null, null, 0m, true, 100)
};

var directory = Path.Combine(Path.GetTempPath(), "f7-export-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(directory);
try
{
  var customerPath = Path.Combine(directory, "customers.csv");
  var productPath = Path.Combine(directory, "products.csv");
  var shippingPath = Path.Combine(directory, "shipping.csv");
  await CustomerCsvGenerator.WriteAsync(customerPath, customerColumns, customers);
  await B2bProductCsvGenerator.WriteAsync(productPath, productColumns, products);
  await ShippingPolicyCsvGenerator.WriteAsync(shippingPath, shippingColumns, shipping);

  var customerCsv = await File.ReadAllTextAsync(customerPath);
  var productCsv = await File.ReadAllTextAsync(productPath);
  var shippingCsv = await File.ReadAllTextAsync(shippingPath);
  Contains(customerCsv, "C-1,INSTALLERS,PAK2|VALUE,1:800:1|2:1500:2|3:3000:3,TOOLS:7.5:CUSTOMER,STANDARD,2", "Komponente prve stranke");
  Contains(customerCsv, "C-2,RESELLERS,VALUE|B2B_PLUS,1:900:1.5|2:1700:2.5|3:3200:3.5,TOOLS:6:TYPE,B2B_PLUS,2", "B2B+ in tipski override druge stranke");
  Contains(productCsv, "NW.2,INSTALLERS,12,S3,10,Unknown", "Unknown mora ostati ekspliciten");
  Contains(shippingCsv, "STANDARD_PAID,150,,4.1,0,10", "Plačljiva standardna dostava");
  Contains(shippingCsv, "OVERSIZE,300,2,10,0,30", "Politika velikih paketov");
  Contains(shippingCsv, "B2B_PLUS,,,0,1,100", "B2B+ brezplačna dostava");

  foreach (var customer in customers)
  {
    Contains(customerCsv, customer.CustomerKey, "Sledljivost stranke");
    var rowsForGroup = productCsv.Split('\n').Count(line => line.Contains(',' + customer.MagentoGroupKey + ',', StringComparison.Ordinal));
    Equal(2, rowsForGroup, "Vsaka stabilna skupina mora imeti vse izdelke");
  }
  foreach (var product in products.Select(product => product.ItemId).Distinct()) Contains(productCsv, product, "Sledljivost izdelka");
  NotContains(productCsv, "customer_override", "Per-customer S override nima odobrene Magento reprezentacije");
  NotContains(customerCsv + productCsv + shippingCsv, "final_price", "Končna cena košarice se ne materializira");

  var inactive = productColumns.Select(column => column.ColumnCode == "S_PERCENT" ? column with { IsActive = false } : column).ToArray();
  await B2bProductCsvGenerator.WriteAsync(productPath, inactive, products);
  NotContains(File.ReadLines(productPath).First(), "s_percent", "Neaktiven konfiguriran stolpec");
  await ThrowsAsync<ExportContractException>(() => B2bProductCsvGenerator.WriteAsync(productPath, productColumns, [products[0] with { Pak2 = 0 }]), "PAK2 mora biti pozitiven");
}
finally
{
  Directory.Delete(directory, true);
}

Console.WriteLine("F7 integration: več strank in izdelkov, komponente pravil, Unknown ter dostava PASS.");

static ExportColumnDefinition[] Columns(params (string Code, string Name, string Field, bool Required)[] definitions)
  => definitions.Select((definition, index) => new ExportColumnDefinition(definition.Code, definition.Name, definition.Field, (index + 1) * 10, definition.Required, true)).ToArray();
static void Contains(string actual, string expected, string message) { if (!actual.Contains(expected, StringComparison.Ordinal)) throw new InvalidOperationException($"{message}: manjka {expected}"); }
static void NotContains(string actual, string unexpected, string message) { if (actual.Contains(unexpected, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException(message); }
static void Equal<T>(T expected, T actual, string message) { if (!EqualityComparer<T>.Default.Equals(expected, actual)) throw new InvalidOperationException(message); }
static async Task ThrowsAsync<T>(Func<Task> action, string message) where T : Exception { try { await action(); } catch (T) { return; } throw new InvalidOperationException(message); }
