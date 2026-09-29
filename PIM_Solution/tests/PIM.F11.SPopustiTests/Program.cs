using System.Data;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using PIM.Intranet.Services;
using PIM.Operations;

// S-popusti na polno pakiranje (migracija 274) od začetka do konca nad razvojno bazo, skozi prave
// servise intraneta (brez brskalnika):
//
//   S1  uvoz cenika (ceniki_skupine_popusta_vpak.xlsx, trije listi) prek delovnega lista izdelkov:
//       S koda se zapiše privzeto vsem objavljenim izdelkom podjetja; VPAK se primerja s PAK2, ne zapiše;
//       drugi uvoz iste datoteke ne spremeni ničesar
//   S2  pravila po tipu stranke in po stranki (rabatna skupina, S koda, en artikel); zmaga najbolj
//       specifično, stranka pred tipom — kartica izdelka, kartica stranke
//   S3  katalog.csv: »Posebni popust za stranko« (ŠIFRA\S) in »Posebni S za skupino strank« (MAGENTO\S);
//       stranke.csv: skupina Magento in kljukica stranke
//   S4  »spremeni S za vse inštalaterje«: eno pravilo, katalog.csv se spremeni pri vseh izdelkih skupine
//   S5  filtri seznama izdelkov: S koda, rabatna skupina, posebni S za tip in za stranko
//   S6  delovni list strank: posebni S po obsegu (SKUPINA:, S:, *) in list »S po tipih strank«
//   S7  delovni list izdelkov: stolpca posebnih S po tipih in strankah
//
// Test pusti v bazi SAMO privzete S kode iz cenika (to je namen uvoza). Pravila, ki jih ustvari, in
// profil testne stranke na koncu vrne v prvotno stanje.

const int Organization = 2; // IQLighting: podjetje spletnega kataloga (katalog.csv, stranke.csv)
const string Actor = "test-f11-spopusti";
var failures = 0;
var passed = 0;

void Check(string name, bool condition, string? detail = null)
{
  if (condition) { passed++; Console.WriteLine($"  OK   {name}"); }
  else { failures++; Console.WriteLine($"  NAPAKA {name}{(detail is null ? "" : " — " + detail)}"); }
}

var connectionString = Environment.GetEnvironmentVariable("PIM_CONNECTION_STRING")
  ?? "Server=DAVID\\MSSQL19;Database=PIM;Integrated Security=True;Encrypt=True;TrustServerCertificate=True";
var configuration = new ConfigurationBuilder()
  .AddInMemoryCollection(new Dictionary<string, string?> { ["ConnectionStrings:Pim"] = connectionString })
  .Build();

var root = FindRoot();
var cenik = Path.Combine(root, "pdf_datoteke", "ceniki_skupine_popusta_vpak.xlsx");
if (!File.Exists(cenik)) { Console.WriteLine("Cenik ni najden: " + cenik); return 2; }

var database = new PimDb(configuration);
var workbench = new ProductWorkbenchService(configuration);
var catalog = new CatalogReadService(database);
var export = new ProductExportService(configuration, workbench);
var guard = PimWriteGuard.Trusted("konzolni test PIM.F11.SPopustiTests");
var edit = new ProductEditService(configuration, guard);
var categoryMapping = new CategoryMappingService(database, configuration, guard);
var saop = new SaopWriteService(configuration, guard, NullLogger<SaopWriteService>.Instance);
var data = new IntranetDataService(configuration, guard);
var attributeDefinitions = new AttributeMappingService(database, configuration, guard);
var packaging = new PackagingDiscountService(configuration);
var workbook = new ProductWorkbookService(configuration, workbench, export, catalog, edit, categoryMapping, saop, data, attributeDefinitions, packaging);
var customerList = new CustomerListService(configuration);
var customerWorkbook = new CustomerWorkbookService(configuration, customerList, packaging);

await using var connection = new SqlConnection(connectionString);
await connection.OpenAsync();

var rulesAtStart = (await packaging.GetRulesAsync(Organization)).Select(rule => rule.RuleId).ToHashSet();
CustomerListRow? customer = null;

try
{
  /* --- S1: uvoz cenika ------------------------------------------------------------------ */
  Console.WriteLine("=== S1 uvoz cenika S-popustov ===");
  var expected = await ExpectedFromCenikAsync(cenik);
  var preview = await PreviewAsync(workbook, File.ReadAllBytes(cenik));
  var sRows = preview.Rows.Count(row => row.PimValues.ContainsKey(ProductWorkbookContract.PackagingCodeField));
  Console.WriteLine($"  cenik: {expected.Rows} vrstic, {expected.WithCode.Count} artiklov s S; predogled: {sRows} sprememb S, opozoril {preview.Problems.Count}");
  foreach (var problem in preview.Problems.Take(6)) Console.WriteLine("     · " + (problem.Length > 220 ? problem[..220] + " …" : problem));
  Check("predogled prebere vse tri liste cenika (S iz lista ViD_Tech je med spremembami ali že zapisan)",
    preview.Problems.All(problem => !problem.Contains("imata druge stolpce", StringComparison.Ordinal)));
  Check("VPAK se ne zapiše, razlika do PAK2 se pove",
    preview.Rows.All(row => row.SaopValues.Count == 0) && preview.Problems.Any(problem => problem.StartsWith("VPAK iz datoteke", StringComparison.Ordinal)));
  var outcome = await workbook.ApplyAsync(preview, Actor, "F11: cenik S-popustov");
  foreach (var problem in outcome.Problems.Take(5)) Console.WriteLine("     · " + problem);

  var promotedWithCode = await ScalarAsync<int>(connection, """
    SELECT COUNT(*) FROM OPENJSON(@Json) WITH (i nvarchar(100) '$.i', s nvarchar(10) '$.s') AS wanted
    INNER JOIN pim.Product AS product ON product.OrganizationId = @Org AND product.ItemID = wanted.i
    INNER JOIN pim.ProductPackagingDiscount AS base ON base.PimProductId = product.PimProductId AND base.DiscountCode = wanted.s;
    """, ("@Json", JsonSerializer.Serialize(expected.WithCode.Select(pair => new { i = pair.Key, s = pair.Value }))), ("@Org", Organization));
  var promotedInFile = await ScalarAsync<int>(connection, """
    SELECT COUNT(*) FROM OPENJSON(@Json) WITH (i nvarchar(100) '$.i') AS wanted
    INNER JOIN pim.Product AS product ON product.OrganizationId = @Org AND product.ItemID = wanted.i;
    """, ("@Json", JsonSerializer.Serialize(expected.WithCode.Keys.Select(key => new { i = key }))), ("@Org", Organization));
  Console.WriteLine($"  v IQLighting objavljenih artiklov s S iz cenika: {promotedInFile}; z enako S kodo v PIM: {promotedWithCode}");
  Check("vsak objavljen artikel iz cenika ima v PIM S kodo iz cenika", promotedInFile > 0 && promotedWithCode == promotedInFile,
    $"{promotedWithCode} od {promotedInFile}");

  var again = await PreviewAsync(workbook, File.ReadAllBytes(cenik));
  Check("drugi uvoz iste datoteke ne spremeni S nobenemu artiklu",
    again.Rows.All(row => !row.PimValues.ContainsKey(ProductWorkbookContract.PackagingCodeField)));

  /* --- izbor testnih podatkov -------------------------------------------------------------- */
  var probe = await FirstAsync(connection, """
    SELECT TOP (1) product.ItemID, canonProduct.ProductId, canonProduct.DiscountGroup, base.DiscountCode
    FROM pim.Product AS product
    INNER JOIN pim.ProductPackagingDiscount AS base ON base.PimProductId = product.PimProductId
    INNER JOIN canon.Product AS canonProduct ON canonProduct.OrganizationId = product.OrganizationId AND canonProduct.ItemID = product.ItemID
    INNER JOIN pim.ProductCommercial AS commercial ON commercial.PimProductId = product.PimProductId AND commercial.Pak2 > 0
    WHERE product.OrganizationId = @Org AND canonProduct.DiscountGroup IS NOT NULL
      /* v katalog.csv gre samo izdelek s kljukico spletisca */
      AND EXISTS (SELECT 1 FROM pim.ProductWebShop AS shop WHERE shop.ProductId = canonProduct.ProductId AND shop.IsPublished = 1)
      AND (SELECT COUNT(*) FROM canon.Product AS sibling WHERE sibling.OrganizationId = @Org AND sibling.DiscountGroup = canonProduct.DiscountGroup
           AND EXISTS (SELECT 1 FROM pim.Product AS p2 WHERE p2.OrganizationId = @Org AND p2.ItemID = sibling.ItemID)
           AND EXISTS (SELECT 1 FROM pim.ProductWebShop AS shop2 WHERE shop2.ProductId = sibling.ProductId AND shop2.IsPublished = 1)) >= 2
    ORDER BY product.ItemID;
    """, ("@Org", Organization));
  var item = (string)probe["ItemID"]!; var productId = (long)probe["ProductId"]!; var group = (string)probe["DiscountGroup"]!; var itemCode = (string)probe["DiscountCode"]!;
  var sibling = (string)(await FirstAsync(connection, """
    SELECT TOP (1) product.ItemID FROM canon.Product AS canonProduct
    INNER JOIN pim.Product AS product ON product.OrganizationId = canonProduct.OrganizationId AND product.ItemID = canonProduct.ItemID
    LEFT JOIN pim.ProductPackagingDiscount AS base ON base.PimProductId = product.PimProductId
    WHERE canonProduct.OrganizationId = @Org AND canonProduct.DiscountGroup = @Group AND product.ItemID <> @Item
      AND ISNULL(base.DiscountCode, N'') <> @Code
      AND EXISTS (SELECT 1 FROM pim.ProductWebShop AS shop WHERE shop.ProductId = canonProduct.ProductId AND shop.IsPublished = 1)
    ORDER BY product.ItemID;
    """, ("@Org", Organization), ("@Group", group), ("@Item", item), ("@Code", itemCode)))["ItemID"]!;
  customer = (await customerList.GetAsync(Organization)).First(row => row.InCustomerExport && row.CustomerTypeCode is null
    && !row.PackagingDiscountEnabled && row.SpecialDiscounts is null && row.ManualKind is null);
  var installerGroup = (await data.GetCustomerTypesAsync()).First(type => type.CustomerTypeCode == "INSTALLER").MagentoGroupKey!;
  Console.WriteLine($"  testni artikel {item} (S {itemCode}, skupina {group}), drugi artikel skupine {sibling}, stranka {customer.CustomerKey} {customer.Name}");

  /* --- S2: pravila ---------------------------------------------------------------------- */
  Console.WriteLine("=== S2 pravila po tipu in stranki ===");
  await SaveProfileAsync(connection, customer, "INSTALLER", packagingEnabled: true);
  await packaging.SaveRuleAsync(Organization, new("TYPE", "INSTALLER", null, null, "ITEM_GROUP", null, group, null, "S3", Note: "F11"), Actor);
  await packaging.SaveRuleAsync(Organization, new("TYPE", "INŠTALATER", null, null, "ITEM", item, null, null, "S4", Note: "F11"), Actor);
  await packaging.SaveRuleAsync(Organization, new("CUSTOMER", null, null, customer.CustomerKey, "S_CODE", null, null, itemCode, "S1", Note: "F11"), Actor);

  var card = (await packaging.GetProductAsync(productId))!;
  Check("kartica izdelka: privzeti S iz cenika", card.DiscountCode == itemCode, card.DiscountCode);
  Check("kartica izdelka: za inštalaterje velja pravilo na izdelku (S4), ne pravilo skupine (S3)",
    card.Specials.Any(row => row.TargetKind == "TYPE" && row.TargetCode == "INSTALLER" && row.DiscountCode == "S4" && row.ScopeKind == "ITEM"));
  Check("kartica izdelka: stranka dobi S1 iz pravila po S kodi",
    card.Specials.Any(row => row.TargetKind == "CUSTOMER" && row.TargetCode == customer.CustomerKey && row.DiscountCode == "S1"));

  var customerView = await packaging.GetCustomerAsync(Organization, customer.CustomerId, 20_000);
  var onItem = customerView.Items.FirstOrDefault(row => row.ItemId == item);
  var onSibling = customerView.Items.FirstOrDefault(row => row.ItemId == sibling);
  Check("kartica stranke: na testnem artiklu ima stranka S1 (stranka pred tipom)", onItem is { DiscountCode: "S1", Source: "CUSTOMER" }, onItem?.ToString());
  Check("kartica stranke: na drugem artiklu skupine ima S3 prek tipa", onSibling is { DiscountCode: "S3", Source: "TYPE", ScopeKind: "ITEM_GROUP" }, onSibling?.ToString());
  Check("kartica stranke: pravila stranke in tipa so našteta", customerView.Rules.Count == 3, customerView.Rules.Count.ToString());

  /* --- S3: katalog.csv in stranke.csv ------------------------------------------------------ */
  Console.WriteLine("=== S3 katalog.csv in stranke.csv ===");
  var row1 = await ExportRowAsync(connection, "MAGENTO_PRODUCTS", item);
  var row2 = await ExportRowAsync(connection, "MAGENTO_PRODUCTS", sibling);
  Console.WriteLine($"  {item}: S={row1.GetValueOrDefault("Skupina popusta")} %={row1.GetValueOrDefault("S popust %")} | stranka={row1.GetValueOrDefault("Posebni popust za stranko")} | skupina={row1.GetValueOrDefault("Posebni S za skupino strank")}");
  Console.WriteLine($"  {sibling}: stranka={row2.GetValueOrDefault("Posebni popust za stranko")} | skupina={row2.GetValueOrDefault("Posebni S za skupino strank")}");
  Check("katalog.csv: privzeta S koda in odstotek", row1.GetValueOrDefault("Skupina popusta") == itemCode && !string.IsNullOrEmpty(row1.GetValueOrDefault("S popust %")));
  Check("katalog.csv: Posebni popust za stranko = ŠIFRA\\S1", (row1.GetValueOrDefault("Posebni popust za stranko") ?? "").Contains($"{customer.CustomerKey}\\S1", StringComparison.Ordinal));
  Check("katalog.csv: Posebni S za skupino strank = inštalaterji\\S4 na izdelku", (row1.GetValueOrDefault("Posebni S za skupino strank") ?? "").Contains($"{installerGroup}\\S4", StringComparison.Ordinal));
  Check("katalog.csv: drugi artikel skupine ima inštalaterji\\S3", (row2.GetValueOrDefault("Posebni S za skupino strank") ?? "").Contains($"{installerGroup}\\S3", StringComparison.Ordinal));
  var customerRow = await ExportRowAsync(connection, "MAGENTO_CUSTOMERS", customer.CustomerKey);
  Check("stranke.csv: skupina Magento inštalaterjev in kljukica polno pakiranje",
    customerRow.GetValueOrDefault("Skupina (Magento)") == installerGroup && customerRow.GetValueOrDefault("Popust polno pakiranje") == "1",
    $"{customerRow.GetValueOrDefault("Skupina (Magento)")} / {customerRow.GetValueOrDefault("Popust polno pakiranje")}");

  /* --- S4: sprememba za vse inštalaterje ----------------------------------------------------- */
  Console.WriteLine("=== S4 spremeni S za vse inštalaterje ===");
  await packaging.SaveRuleAsync(Organization, new("TYPE", "INSTALLER", null, null, "ITEM_GROUP", null, group, null, "S2", Note: "F11"), Actor);
  var groupRules = (await packaging.GetRulesAsync(Organization)).Where(rule => rule.TargetCode == "INSTALLER" && rule.ScopeKind == "ITEM_GROUP" && rule.ItemGroupCode == group).ToList();
  row2 = await ExportRowAsync(connection, "MAGENTO_PRODUCTS", sibling);
  Check("eno pravilo na skupino (posodobljeno, ne podvojeno)", groupRules.Count == 1, groupRules.Count.ToString());
  Check("katalog.csv: drugi artikel skupine ima zdaj inštalaterji\\S2", (row2.GetValueOrDefault("Posebni S za skupino strank") ?? "").Contains($"{installerGroup}\\S2", StringComparison.Ordinal),
    row2.GetValueOrDefault("Posebni S za skupino strank"));
  Check("pravilo zadene vse objavljene izdelke rabatne skupine", groupRules[0].ProductCount >= 2, groupRules[0].ProductCount.ToString());

  /* --- S5: filtri ------------------------------------------------------------------------- */
  Console.WriteLine("=== S5 filtri seznama izdelkov ===");
  async Task<long> CountAsync(ProductListFilter filter) => (await workbench.GetProductListAsync(filter)).TotalCount;
  var byCode = await CountAsync(new(Organization, 0, 5, PackagingDiscount: itemCode));
  var byCodeDb = await ScalarAsync<int>(connection, "SELECT COUNT(*) FROM pim.ProductPackagingDiscount AS base INNER JOIN pim.Product AS product ON product.PimProductId = base.PimProductId WHERE product.OrganizationId = @Org AND base.DiscountCode = @Code;",
    ("@Org", Organization), ("@Code", itemCode));
  Check($"filter S koda {itemCode}: {byCode} = {byCodeDb} v bazi", byCode == byCodeDb);
  var byGroup = await CountAsync(new(Organization, 0, 5, DiscountGroup: group));
  var byGroupDb = await ScalarAsync<int>(connection, "SELECT COUNT(*) FROM canon.Product WHERE OrganizationId = @Org AND DiscountGroup = @Group;", ("@Org", Organization), ("@Group", group));
  Check($"filter rabatna skupina {group}: {byGroup} = {byGroupDb}", byGroup == byGroupDb);
  var byType = await workbench.GetProductListAsync(new(Organization, 0, 20_000, SpecialFor: "TYPE:INSTALLER"));
  Check("filter posebni S za inštalaterje vsebuje oba testna artikla",
    byType.Rows.Any(row => row.ItemId == item) && byType.Rows.Any(row => row.ItemId == sibling), byType.TotalCount.ToString());
  var byCustomer = await workbench.GetProductListAsync(new(Organization, 0, 20_000, SpecialFor: "CUSTOMER:" + customer.CustomerKey));
  Check("filter posebni S za stranko = izdelki s kartice stranke", byCustomer.TotalCount == customerView.SpecialProductCount,
    $"{byCustomer.TotalCount} / {customerView.SpecialProductCount}");
  var combined = await CountAsync(new(Organization, 0, 5, PackagingDiscount: "NONE", DiscountGroup: group));
  Check("filtri se seštevajo (brez S + skupina)", combined <= byGroup);

  /* --- S6: delovni list strank ------------------------------------------------------------ */
  Console.WriteLine("=== S6 delovni list strank ===");
  var current = (await customerList.GetAsync(Organization)).First(row => row.CustomerId == customer.CustomerId);
  Check("seznam strank nosi pravilo po S kodi v zapisu S:koda\\S1", current.SpecialDiscounts?.Contains($"S:{itemCode}\\S1", StringComparison.Ordinal) == true, current.SpecialDiscounts);
  var edited = current with { SpecialDiscounts = $"S:{itemCode}\\S1 | SKUPINA:{group}\\S4 | {sibling}\\S3" };
  var typeRule = new PackagingRule(0, "TYPE", "ALL", "RESELLER", "TRGOVEC", null, null, null, null, "S1", null, null, null, true, "F11", null, null, 0, 0);
  var sheetBytes = CustomerWorkbookService.Build([edited], [("IQLighting", typeRule)]);
  var customerPreview = await customerWorkbook.PreviewAsync(new MemoryStream(sheetBytes), Organization);
  foreach (var problem in customerPreview.Problems) Console.WriteLine("     · " + problem);
  var specialChange = customerPreview.Rows.SingleOrDefault()?.Specials;
  Check("predogled strank: dodani skupina in artikel, S koda ostane", specialChange is { Count: 2 }
    && specialChange.ContainsKey($"SKUPINA:{group}") && specialChange.ContainsKey(sibling), specialChange is null ? "ni spremembe" : string.Join(", ", specialChange.Keys));
  Check("predogled strank: list »S po tipih strank« doda pravilo za trgovce", customerPreview.TypeRules is { Count: 1 });
  var customerOutcome = await customerWorkbook.ApplyAsync(customerPreview, Actor);
  foreach (var problem in customerOutcome.Problems) Console.WriteLine("     · " + problem);
  var afterImport = await packaging.GetRulesAsync(Organization);
  Check("uvoz strank: pravilo SKUPINA za stranko", afterImport.Any(rule => rule.TargetKind == "CUSTOMER" && rule.TargetCode == customer.CustomerKey && rule.ScopeKind == "ITEM_GROUP" && rule.DiscountCode == "S4"));
  Check("uvoz strank: pravilo za trgovce na vse artikle", afterImport.Any(rule => rule.TargetKind == "TYPE" && rule.TargetCode == "RESELLER" && rule.ScopeKind == "ALL" && rule.DiscountCode == "S1"));
  var roundTrip = await customerWorkbook.PreviewAsync(new MemoryStream(await customerWorkbook.BuildAsync(
    (await customerList.GetAsync(Organization)).Where(row => row.CustomerId == customer.CustomerId).ToList(), Organization)), Organization);
  Check("krog izvoz → uvoz strank brez sprememb ne spremeni ničesar", roundTrip.ChangeCount == 0, roundTrip.ChangeCount.ToString());

  /* --- S7: delovni list izdelkov, posebni S ------------------------------------------------ */
  Console.WriteLine("=== S7 delovni list izdelkov: posebni S ===");
  var productSheet = WorkbookWriter.Write([new WorkbookWriteSheet("Izdelki",
    [new WorkbookColumn("Šifra artikla"), new WorkbookColumn("Posebni S — tipi strank"), new WorkbookColumn("Posebni S — stranke")],
    [[sibling, "INŠTALATER\\S4 | RESELLER\\S3", customer.CustomerKey + "\\S2"]])]);
  var productPreview = await PreviewAsync(workbook, productSheet);
  foreach (var problem in productPreview.Problems) Console.WriteLine("     · " + problem);
  Check("predogled izdelkov: obe celici posebnih S prepoznani",
    productPreview.Rows.SingleOrDefault()?.PimValues is { } values && values.ContainsKey(ProductWorkbookContract.TypeSpecialsField) && values.ContainsKey(ProductWorkbookContract.CustomerSpecialsField));
  await workbook.ApplyAsync(productPreview, Actor, "F11");
  var siblingSpecials = (await packaging.GetProductAsync(await ScalarAsync<long>(connection,
    "SELECT ProductId FROM canon.Product WHERE OrganizationId = @Org AND ItemID = @Item;", ("@Org", Organization), ("@Item", sibling))))!.Specials;
  Check("uvoz izdelkov: inštalaterji S4 na izdelku (prej S2 iz skupine)", siblingSpecials.Any(row => row.TargetCode == "INSTALLER" && row.DiscountCode == "S4" && row.ScopeKind == "ITEM"));
  Check("uvoz izdelkov: trgovci S3 na izdelku (prej S1 za vse)", siblingSpecials.Any(row => row.TargetCode == "RESELLER" && row.DiscountCode == "S3" && row.ScopeKind == "ITEM"));
  Check("uvoz izdelkov: stranka S2 na izdelku", siblingSpecials.Any(row => row.TargetCode == customer.CustomerKey && row.DiscountCode == "S2"));
  var productAgain = await PreviewAsync(workbook, productSheet);
  Check("drugi uvoz iste datoteke izdelkov ne spremeni ničesar", productAgain.Rows.Count == 0);
}
catch (Exception failure)
{
  failures++;
  Console.WriteLine("  NAPAKA izjema: " + failure);
}
finally
{
  /* --- pospravljanje: pravila testa in profil stranke ------------------------------------ */
  var created = (await packaging.GetRulesAsync(Organization)).Where(rule => !rulesAtStart.Contains(rule.RuleId)).ToList();
  foreach (var rule in created) await packaging.RemoveRuleAsync(Organization, rule.RuleId, Actor);
  if (customer is not null) await SaveProfileAsync(connection, customer, null, packagingEnabled: false);
  Console.WriteLine($"Pospravljeno: umaknjenih pravil {created.Count}, profil stranke vrnjen.");
}

Console.WriteLine($"\nRezultat: {passed} OK, {failures} napak.");
return failures == 0 ? 0 : 1;

/* --- pomožno --------------------------------------------------------------------------------- */

static async Task<ProductWorkbookPreview> PreviewAsync(ProductWorkbookService workbook, byte[] bytes)
{
  using var stream = new MemoryStream(bytes);
  return await workbook.PreviewAsync(stream, Organization);
}

static async Task<(int Rows, Dictionary<string, string> WithCode)> ExpectedFromCenikAsync(string path)
{
  await Task.CompletedTask;
  using var stream = File.OpenRead(path);
  var sheet = WorkbookTable.ReadMatchingSheets(stream, ["Šifra"], out _);
  var itemAt = sheet.Headers.ToList().FindIndex(header => WorkbookHeader.Same(header, "Šifra"));
  var codeAt = sheet.Headers.ToList().FindIndex(header => WorkbookHeader.Same(header, "Skupina popusta"));
  var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
  foreach (var row in sheet.Rows)
    if (row[itemAt].Trim() is { Length: > 0 } itemId && row[codeAt].Trim() is { Length: > 0 } code)
      result.TryAdd(itemId, code.ToUpperInvariant());
  return (sheet.Rows.Count, result);
}

static async Task SaveProfileAsync(SqlConnection connection, CustomerListRow customer, string? typeCode, bool packagingEnabled)
{
  await using var command = new SqlCommand("b2b.SaveCustomerWebProfile", connection) { CommandType = CommandType.StoredProcedure };
  command.Parameters.AddWithValue("@OrganizationId", customer.OrganizationId);
  command.Parameters.AddWithValue("@CustomerId", customer.CustomerId);
  command.Parameters.AddWithValue("@CustomerTypeCode", (object?)typeCode ?? DBNull.Value);
  command.Parameters.AddWithValue("@CustomerKind", (object?)customer.ManualKind ?? DBNull.Value);
  command.Parameters.AddWithValue("@PackagingDiscountEnabled", packagingEnabled);
  command.Parameters.AddWithValue("@ValueDiscountEnabled", customer.ValueDiscountEnabled);
  command.Parameters.AddWithValue("@B2bPlusEnabled", customer.B2bPlusEnabled);
  command.Parameters.AddWithValue("@B2bPlusValidFrom", (object?)customer.B2bPlusValidFrom ?? DBNull.Value);
  command.Parameters.AddWithValue("@B2bPlusValidTo", (object?)customer.B2bPlusValidTo ?? DBNull.Value);
  command.Parameters.AddWithValue("@WebEnabled", customer.WebEnabled);
  command.Parameters.AddWithValue("@ChangedBy", Actor);
  await command.ExecuteNonQueryAsync();
}

static async Task<Dictionary<string, string?>> ExportRowAsync(SqlConnection connection, string profileCode, string search)
{
  var profileId = await ScalarAsync<int>(connection, "SELECT ExportProfileId FROM out.ExportProfile WHERE ProfileCode = @Code;", ("@Code", profileCode));
  await using var command = new SqlCommand("out.GetExportRows", connection) { CommandType = CommandType.StoredProcedure, CommandTimeout = 900 };
  command.Parameters.AddWithValue("@OrganizationId", Organization);
  command.Parameters.AddWithValue("@ExportProfileId", profileId);
  command.Parameters.AddWithValue("@WebSite", DBNull.Value);
  command.Parameters.AddWithValue("@OnlyPublished", false);
  command.Parameters.AddWithValue("@Search", search);
  command.Parameters.AddWithValue("@Skip", 0);
  command.Parameters.AddWithValue("@Take", 50);
  command.Parameters.Add("@TotalCount", SqlDbType.Int).Direction = ParameterDirection.Output;
  await using var reader = await command.ExecuteReaderAsync();
  var keyColumn = profileCode == "MAGENTO_PRODUCTS" ? "Šifra artikla" : "Šifra stranke";
  while (await reader.ReadAsync())
  {
    if (!string.Equals(Convert.ToString(reader[keyColumn]), search, StringComparison.OrdinalIgnoreCase)) continue;
    var row = new Dictionary<string, string?>(StringComparer.Ordinal);
    for (var index = 0; index < reader.FieldCount; index++)
      row[reader.GetName(index)] = reader.IsDBNull(index) ? null : Convert.ToString(reader.GetValue(index), System.Globalization.CultureInfo.InvariantCulture);
    return row;
  }
  return [];
}

static async Task<T> ScalarAsync<T>(SqlConnection connection, string sql, params (string Name, object Value)[] parameters)
{
  await using var command = new SqlCommand(sql, connection) { CommandTimeout = 300 };
  foreach (var (name, value) in parameters) command.Parameters.AddWithValue(name, value);
  return (T)Convert.ChangeType((await command.ExecuteScalarAsync())!, typeof(T), System.Globalization.CultureInfo.InvariantCulture);
}

static async Task<Dictionary<string, object?>> FirstAsync(SqlConnection connection, string sql, params (string Name, object Value)[] parameters)
{
  await using var command = new SqlCommand(sql, connection) { CommandTimeout = 300 };
  foreach (var (name, value) in parameters) command.Parameters.AddWithValue(name, value);
  await using var reader = await command.ExecuteReaderAsync();
  if (!await reader.ReadAsync()) throw new InvalidOperationException("Poizvedba ni vrnila vrstice: " + sql[..Math.Min(80, sql.Length)]);
  var row = new Dictionary<string, object?>(StringComparer.Ordinal);
  for (var index = 0; index < reader.FieldCount; index++) row[reader.GetName(index)] = reader.IsDBNull(index) ? null : reader.GetValue(index);
  return row;
}

static string FindRoot()
{
  var directory = new DirectoryInfo(AppContext.BaseDirectory);
  while (directory is not null && !Directory.Exists(Path.Combine(directory.FullName, "sql", "migrations"))) directory = directory.Parent;
  return directory?.FullName ?? throw new DirectoryNotFoundException("PIM_Solution ni najden.");
}
