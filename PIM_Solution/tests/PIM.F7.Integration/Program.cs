using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Data.SqlClient;
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

var connectionString = ReadPimConnectionString()
  ?? throw new InvalidOperationException("Manjka razvojna povezava Pim; F7 MSSQL integracije ni dovoljeno preskočiti.");
await using (var connection = new SqlConnection(connectionString))
{
  await connection.OpenAsync();
  await ExecuteAsync(connection, File.ReadAllText(Path.Combine(FindSolutionRoot(), "tests", "sql", "Verify-F7.sql")));
  await VerifyMssqlPipelineAndExportsAsync(connection);
  Equal(0, await ScalarAsync<int>(connection, "SELECT COUNT(*) FROM dbo.OrganizationConfig WHERE OrganizationId=9707;"), "Dokazna organizacija ni odstranjena.");
  Equal(0, await ScalarAsync<int>(connection, "SELECT COUNT(*) FROM pim.Product WHERE OrganizationId=9707;"), "Dokazni PIM izdelki niso odstranjeni.");
  Equal(0, await ScalarAsync<int>(connection, "SELECT COUNT(*) FROM b2b.Customer WHERE OrganizationId=9707;"), "Dokazne B2B stranke niso odstranjene.");
}
Console.WriteLine("F7 MSSQL integration: landing, profil, revizija, B2B izvozi in čiščenje PASS.");

static ExportColumnDefinition[] Columns(params (string Code, string Name, string Field, bool Required)[] definitions)
  => definitions.Select((definition, index) => new ExportColumnDefinition(definition.Code, definition.Name, definition.Field, (index + 1) * 10, definition.Required, true)).ToArray();
static void Contains(string actual, string expected, string message) { if (!actual.Contains(expected, StringComparison.Ordinal)) throw new InvalidOperationException($"{message}: manjka {expected}"); }
static void NotContains(string actual, string unexpected, string message) { if (actual.Contains(unexpected, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException(message); }
static void Equal<T>(T expected, T actual, string message) { if (!EqualityComparer<T>.Default.Equals(expected, actual)) throw new InvalidOperationException(message); }
static async Task ThrowsAsync<T>(Func<Task> action, string message) where T : Exception { try { await action(); } catch (T) { return; } throw new InvalidOperationException(message); }

static string? ReadPimConnectionString()
{
  var environmentValue = Environment.GetEnvironmentVariable("PIM_CONNECTION_STRING");
  if (!string.IsNullOrWhiteSpace(environmentValue)) return environmentValue;
  var root = FindSolutionRoot();
  var localPath = Path.Combine(root, "appsettings.Local.json");
  if (!File.Exists(localPath)) return null;
  using var document = JsonDocument.Parse(File.ReadAllText(localPath));
  return document.RootElement.TryGetProperty("ConnectionStrings", out var strings)
    && strings.TryGetProperty("Pim", out var setting) ? setting.GetString() : null;
}

static async Task VerifyMssqlPipelineAndExportsAsync(SqlConnection connection)
{
  const int organizationId = 9707;
  const string customerType = "INSTALLER";
  const string groupKey = "F7_PROOF_INSTALLERS";
  var suffix = Guid.NewGuid().ToString("N");
  var customerKey = "F7-PROOF-" + suffix;
  var productItemId = "F7-PRODUCT-" + suffix;
  string? originalGroupKey = null;
  var organizationCreated = false;
  try
  {
    originalGroupKey = await NullableStringAsync(connection, "SELECT MagentoGroupKey FROM pim.CustomerTypeMagentoGroup WHERE CustomerTypeCode=@CustomerType;", ("@CustomerType", customerType));
    await ExecuteAsync(connection, "INSERT dbo.OrganizationConfig(OrganizationId,Name,SaopPrefix,IsActive) VALUES(@OrganizationId,@Name,@Prefix,1);",
      ("@OrganizationId", organizationId), ("@Name", "F7 proof " + suffix), ("@Prefix", "F7" + suffix[..12]));
    organizationCreated = true;

    var payload = JsonSerializer.Serialize(new { CustomerCode = customerKey, CustomerName = "F7 dokazna stranka", PriceList = "F7", DiscountPriceList = "F7D" });
    var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(payload)));
    var landingId = await ScalarAsync<long>(connection, """
      INSERT b2b.LandingRecord(OrganizationId,SourceCode,EntityType,SourceRecordKey,PayloadJson,PayloadHash)
      OUTPUT INSERTED.LandingRecordId
      VALUES(@OrganizationId,N'SAOP',N'Customers',@SourceRecordKey,@Payload,@PayloadHash);
      """
      , ("@OrganizationId", organizationId), ("@SourceRecordKey", customerKey), ("@Payload", payload), ("@PayloadHash", hash));
    await ExecuteAsync(connection, "EXEC b2b.ApplyLandingRecord @LandingRecordId=@LandingRecordId;", ("@LandingRecordId", landingId));
    Equal("Applied", await ScalarAsync<string>(connection, "SELECT Status FROM b2b.LandingRecord WHERE LandingRecordId=@LandingRecordId;", ("@LandingRecordId", landingId)), "Generični B2B landing zapis ni uporabljen.");
    var customerId = await ScalarAsync<long>(connection, "SELECT CustomerId FROM b2b.Customer WHERE OrganizationId=@OrganizationId AND CustomerKey=@CustomerKey;", ("@OrganizationId", organizationId), ("@CustomerKey", customerKey));

    await ExecuteAsync(connection, """
      EXEC b2b.SaveCustomerWebProfile @OrganizationId=@OrganizationId,@CustomerId=@CustomerId,@CustomerTypeCode=N'INSTALLER',@CustomerKind=N'CUSTOMER',
        @PackagingDiscountEnabled=1,@ValueDiscountEnabled=1,@B2bPlusEnabled=0,@WebEnabled=1,@ChangedBy=N'F7 integration proof';
      EXEC b2b.SaveCustomerValueTier @OrganizationId=@OrganizationId,@CustomerId=@CustomerId,@TierNumber=1,@ThresholdGrossExVat=801,@PercentValue=1.1,@ChangedBy=N'F7 integration proof';
      EXEC b2b.SaveCustomerValueTier @OrganizationId=@OrganizationId,@CustomerId=@CustomerId,@TierNumber=2,@ThresholdGrossExVat=1501,@PercentValue=2.1,@ChangedBy=N'F7 integration proof';
      EXEC b2b.SaveCustomerValueTier @OrganizationId=@OrganizationId,@CustomerId=@CustomerId,@TierNumber=3,@ThresholdGrossExVat=3001,@PercentValue=3.1,@ChangedBy=N'F7 integration proof';
      EXEC b2b.SaveCustomerTypeMapping @OrganizationId=@OrganizationId,@CustomerTypeCode=N'INSTALLER',@MagentoGroupKey=@GroupKey,@ChangedBy=N'F7 integration proof';
      """
      , ("@OrganizationId", organizationId), ("@CustomerId", customerId), ("@GroupKey", groupKey));
    Equal(1, await ScalarAsync<int>(connection, "SELECT COUNT(*) FROM pim.CustomerWebProfile WHERE CustomerId=@CustomerId AND WebEnabled=1;", ("@CustomerId", customerId)), "Profil stranke ni shranjen.");
    Equal(5, await ScalarAsync<int>(connection, "SELECT COUNT(*) FROM b2b.AuditLog WHERE OrganizationId=@OrganizationId AND ChangedBy=N'F7 integration proof';", ("@OrganizationId", organizationId)), "Shranjevanje profila, pragov in skupine ni revidirano.");

    await ExecuteAsync(connection, """
      INSERT pim.Product(OrganizationId,ItemID,EAN,Name,Manufacturer) VALUES(@OrganizationId,@ItemID,N'9707000000001',N'F7 dokaz',N'F7');
      DECLARE @PimProductId bigint=SCOPE_IDENTITY();
      INSERT pim.ProductCommercial(PimProductId,Pak2) VALUES(@PimProductId,5);
      INSERT pim.ProductPackagingDiscount(PimProductId,DiscountCode,PromotionGateState) VALUES(@PimProductId,N'S2',N'Regular');
      """
      , ("@OrganizationId", organizationId), ("@ItemID", productItemId));

    Equal(18, await ScalarAsync<int>(connection, "SELECT COUNT(*) FROM pim.CustomerTypeCatalog WHERE IsActive=1;"), "Ni 18 aktivnih tipov strank.");
    Equal(4, await ScalarAsync<int>(connection, "SELECT COUNT(*) FROM pim.PackagingDiscountCatalog WHERE IsActive=1;"), "Ni štirih aktivnih S-stopenj.");
    Equal(3, await ScalarAsync<int>(connection, "SELECT COUNT(*) FROM pim.ValueDiscountTier WHERE IsActive=1;"), "Ni treh aktivnih vrednostnih pragov.");
    Equal(0, await ScalarAsync<int>(connection, "SELECT COUNT(*) FROM pim.CustomerTypeMagentoGroup WHERE MagentoGroupKey=N'UNASSIGNED';"), "Izmišljena Magento skupina UNASSIGNED obstaja.");
    await AssertExportContainsAsync(connection, "EXEC out.ExportB2bCustomersCsv @OrganizationId=@OrganizationId;", customerKey, ("@OrganizationId", organizationId));
    await AssertExportContainsAsync(connection, "EXEC out.ExportB2bProductsCsv @OrganizationId=@OrganizationId;", productItemId, ("@OrganizationId", organizationId));
    await AssertExportContainsAsync(connection, "EXEC out.ExportB2bShippingCsv;", "B2B_PLUS");
  }
  finally
  {
    if (originalGroupKey is not null || organizationCreated)
      await ExecuteAsync(connection, "UPDATE pim.CustomerTypeMagentoGroup SET MagentoGroupKey=@GroupKey WHERE CustomerTypeCode=N'INSTALLER';", ("@GroupKey", (object?)originalGroupKey ?? DBNull.Value));
    if (organizationCreated)
    {
      await ExecuteAsync(connection, """
        DELETE pd FROM pim.ProductPackagingDiscount pd INNER JOIN pim.Product p ON p.PimProductId=pd.PimProductId WHERE p.OrganizationId=@OrganizationId;
        DELETE pc FROM pim.ProductCommercial pc INNER JOIN pim.Product p ON p.PimProductId=pc.PimProductId WHERE p.OrganizationId=@OrganizationId;
        DELETE FROM pim.Product WHERE OrganizationId=@OrganizationId;
        DELETE FROM pim.CustomerValueDiscountTier WHERE CustomerId IN(SELECT CustomerId FROM b2b.Customer WHERE OrganizationId=@OrganizationId);
        DELETE FROM pim.CustomerWebProfile WHERE CustomerId IN(SELECT CustomerId FROM b2b.Customer WHERE OrganizationId=@OrganizationId);
        DELETE FROM b2b.AuditLog WHERE OrganizationId=@OrganizationId;
        DELETE FROM b2b.MappingRejection WHERE LandingRecordId IN(SELECT LandingRecordId FROM b2b.LandingRecord WHERE OrganizationId=@OrganizationId);
        DELETE FROM b2b.LandingRecord WHERE OrganizationId=@OrganizationId;
        DELETE FROM b2b.Customer WHERE OrganizationId=@OrganizationId;
        DELETE FROM dbo.OrganizationConfig WHERE OrganizationId=@OrganizationId;
        """
        , ("@OrganizationId", organizationId));
    }
  }
}

static async Task AssertExportContainsAsync(SqlConnection connection, string sql, string expected, params (string Name, object Value)[] parameters)
{
  await using var command = Command(connection, sql, parameters);
  await using var reader = await command.ExecuteReaderAsync();
  while (await reader.ReadAsync())
    if (Enumerable.Range(0, reader.FieldCount).Any(index => !reader.IsDBNull(index) && reader.GetValue(index).ToString()!.Contains(expected, StringComparison.Ordinal))) return;
  throw new InvalidOperationException($"Izvoz ne vsebuje {expected}.");
}
static SqlCommand Command(SqlConnection connection, string sql, params (string Name, object Value)[] parameters)
{
  var command = new SqlCommand(sql, connection) { CommandTimeout = 120 };
  foreach (var parameter in parameters) command.Parameters.AddWithValue(parameter.Name, parameter.Value);
  return command;
}
static async Task ExecuteAsync(SqlConnection connection, string sql, params (string Name, object Value)[] parameters)
{
  await using var command = Command(connection, sql, parameters);
  await command.ExecuteNonQueryAsync();
}
static async Task<T> ScalarAsync<T>(SqlConnection connection, string sql, params (string Name, object Value)[] parameters)
{
  await using var command = Command(connection, sql, parameters);
  return (T)(await command.ExecuteScalarAsync() ?? throw new InvalidOperationException("Poizvedba ni vrnila vrednosti."));
}
static async Task<string?> NullableStringAsync(SqlConnection connection, string sql, params (string Name, object Value)[] parameters)
{
  await using var command = Command(connection, sql, parameters);
  var result = await command.ExecuteScalarAsync();
  return result is null or DBNull ? null : (string)result;
}
static string FindSolutionRoot()
{
  var directory = new DirectoryInfo(Directory.GetCurrentDirectory());
  while (directory is not null)
  {
    if (File.Exists(Path.Combine(directory.FullName, "PIM.sln"))) return directory.FullName;
    directory = directory.Parent;
  }
  throw new InvalidOperationException("PIM.sln ni najden.");
}
