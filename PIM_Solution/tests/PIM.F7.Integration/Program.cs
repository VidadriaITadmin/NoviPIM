using PIM.B2b;

var columns = new[]
{
  new ExportColumnDefinition("KEY", "customer_key", "Customer.Key", 10, true, true),
  new ExportColumnDefinition("GROUP", "customer_group", "Customer.MagentoGroupKey", 20, true, true),
  new ExportColumnDefinition("FLAGS", "policy_flags", "Customer.Flags", 30, false, true)
};
var customerRows = new[]
{
  Row(("Customer.Key","C-1"),("Customer.MagentoGroupKey","INSTALLERS"),("Customer.Flags","PAK2|VALUE")),
  Row(("Customer.Key","C-2"),("Customer.MagentoGroupKey","RESELLERS"),("Customer.Flags","B2B_PLUS"))
};
var customersPath = Path.Combine(Path.GetTempPath(), "f7-customers-" + Guid.NewGuid().ToString("N") + ".csv");
await CustomerCsvGenerator.WriteAsync(customersPath, columns, customerRows);
var customers = await File.ReadAllTextAsync(customersPath);
Equal("customer_key,customer_group,policy_flags\nC-1,INSTALLERS,PAK2|VALUE\nC-2,RESELLERS,B2B_PLUS\n", customers, "Konfiguriran CUSTOMERS CSV");

var productColumns = new[]
{
  new ExportColumnDefinition("ITEM", "sku", "Product.ItemID", 10, true, true),
  new ExportColumnDefinition("GROUP", "customer_group", "Customer.MagentoGroupKey", 20, true, true),
  new ExportColumnDefinition("PAK2", "pak2", "Product.Pak2", 30, true, true),
  new ExportColumnDefinition("S", "s_percent", "Product.PackagingDiscountPercent", 40, false, true),
  new ExportColumnDefinition("GATE", "promotion_gate_state", "Product.PromotionGateState", 50, true, true)
};
var productsPath = Path.Combine(Path.GetTempPath(), "f7-products-" + Guid.NewGuid().ToString("N") + ".csv");
await B2bProductCsvGenerator.WriteAsync(productsPath, productColumns, new[]
{
  Row(("Product.ItemID","BA.1"),("Customer.MagentoGroupKey","INSTALLERS"),("Product.Pak2","5"),("Product.PackagingDiscountPercent","5"),("Product.PromotionGateState","Regular")),
  Row(("Product.ItemID","BA.1"),("Customer.MagentoGroupKey","RESELLERS"),("Product.Pak2","5"),("Product.PackagingDiscountPercent","5"),("Product.PromotionGateState","Regular")),
  Row(("Product.ItemID","NW.2"),("Customer.MagentoGroupKey","INSTALLERS"),("Product.Pak2","12"),("Product.PackagingDiscountPercent","10"),("Product.PromotionGateState","Unknown"))
});
var products = await File.ReadAllTextAsync(productsPath);
foreach (var group in new[] { "INSTALLERS", "RESELLERS" })
  if (!customers.Contains(group, StringComparison.Ordinal) || !products.Contains(group, StringComparison.Ordinal)) throw new InvalidOperationException("Customer group ni usklajen: " + group);
if (products.Contains("customer_override", StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Per-customer S override še nima odobrene Magento reprezentacije.");

await ThrowsAsync<ExportContractException>(() => CustomerCsvGenerator.WriteAsync(customersPath, columns, new[] { Row(("Customer.Key","C-3")) }), "Obvezna group vrednost ne sme postati prazen CSV.");
File.Delete(customersPath); File.Delete(productsPath);
var root = FindRoot();
foreach (var page in new[] { "Customers.razor", "CustomerDetail.razor", "DiscountRules.razor" })
{
  var source = File.ReadAllText(Path.Combine(root, "src/PIM.Intranet/Components/Pages", page));
  foreach (var required in page switch
  {
    "Customers.razor" => new[] { "Stranke", "Vrsta stranke", "Tip stranke", "Skupina Magento" },
    "CustomerDetail.razor" => new[] { "Plačnik", "Cenik", "Popust na polno pakiranje", "Vrednostni rabat", "B2B+", "SaveCustomerWebProfileAsync" },
    _ => new[] { "Pravila popustov", "Vrednostni pragovi", "Poštnina", "SaveShippingRuleAsync" }
  })
    if (!source.Contains(required, StringComparison.Ordinal)) throw new InvalidOperationException($"{page} manjka {required}.");
  if (source.Contains("pošlji v ERP", StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("F8 akcija ni dovoljena.");
}
Console.WriteLine("F7 integration (brez DB): konfigurirana CUSTOMERS/PRODUCTS CSV in skupni group ključ PASS.");

static IReadOnlyDictionary<string,string?> Row(params (string Key,string? Value)[] values) => values.ToDictionary(x=>x.Key,x=>x.Value);
static void Equal<T>(T expected,T actual,string message) { if(!EqualityComparer<T>.Default.Equals(expected,actual))throw new InvalidOperationException(message); }
static async Task ThrowsAsync<T>(Func<Task> action,string message) where T:Exception { try{await action();}catch(T){return;}throw new InvalidOperationException(message); }
static string FindRoot(){var d=new DirectoryInfo(Directory.GetCurrentDirectory());while(d is not null&&!File.Exists(Path.Combine(d.FullName,"PIM.sln")))d=d.Parent;return d?.FullName??throw new InvalidOperationException();}
