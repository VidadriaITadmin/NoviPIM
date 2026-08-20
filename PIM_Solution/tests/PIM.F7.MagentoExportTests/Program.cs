using System.Text;
using Microsoft.Data.SqlClient;
using PIM.B2b;
using PIM.B2bWorker;

// ---------------------------------------------------------------------------
// 1. Pogodba CSV — brez baze.
// ---------------------------------------------------------------------------

Equal(215, MagentoCsvContract.ProductHeaders.Count, "Magento products mora imeti 215 glav.");
Equal(19, MagentoCsvContract.CustomerHeaders.Count, "Magento customers mora imeti 19 glav.");
Equal("Šifra artikla", MagentoCsvContract.ProductHeaders[0], "Prva glava izdelkov.");
Equal("Združljivo z", MagentoCsvContract.ProductHeaders[^1], "Zadnja glava izdelkov.");
Equal("Šifra stranke", MagentoCsvContract.CustomerHeaders[0], "Prva glava strank.");
Equal("Popust NW", MagentoCsvContract.CustomerHeaders[^1], "Zadnja glava strank.");
Equal("Enota višine stropne kapice ", MagentoCsvContract.ProductHeaders[72], "Končni presledek predloge je ohranjen.");

// Shema, ki jo uporablja izvozni ukaz, mora biti ista pogodba. Prej sta bila to dva
// neodvisna seznama 215 nizov; pogodbeni test je preverjal enega, ukaz pa uporabljal drugega.
Equal(true, MagentoProductSchema.Headers.SequenceEqual(MagentoCsvContract.ProductHeaders),
  "MagentoProductSchema mora uporabljati iste glave kot pogodba.");
Equal(true, MagentoCustomerSchema.Headers.SequenceEqual(MagentoCsvContract.CustomerHeaders),
  "MagentoCustomerSchema mora uporabljati iste glave kot pogodba.");
Equal(215, MagentoProductSchema.BuildColumns().Length, "Ukaz mora zapisati 215 stolpcev izdelkov.");
Equal(19, MagentoCustomerSchema.BuildColumns().Length, "Ukaz mora zapisati 19 stolpcev strank.");
Equal("Product.MainImage", MagentoProductSchema.GetCanonicalCode(37), "Stolpec 38 je glavna slika.");
Equal("Product.OtherImages", MagentoProductSchema.GetCanonicalCode(38), "Stolpec 39 so ostale slike.");

// ---------------------------------------------------------------------------
// 2. Vloga glavne slike.
//
// Kanonicni sloj pise PRIMARY (migracije 012/013/016/017/040/042), v canon.ProductMedia
// pa obstajajo tudi vrstice z zapisom "Primary". Koda je prej primerjala z "MAIN" in se
// ni ujemala z nicimer: glavna slika je ostala prazna, vse slike pa so pristale med ostalimi.
// ---------------------------------------------------------------------------

Equal(true, MagentoExportCommand.IsPrimaryMediaRole("PRIMARY"), "PRIMARY je glavna vloga.");
Equal(true, MagentoExportCommand.IsPrimaryMediaRole("Primary"), "Primary je glavna vloga.");
Equal(true, MagentoExportCommand.IsPrimaryMediaRole("primary"), "primary je glavna vloga.");
Equal(true, MagentoExportCommand.IsPrimaryMediaRole("MAIN"), "MAIN ostane podprt.");
Equal(false, MagentoExportCommand.IsPrimaryMediaRole("GALLERY"), "GALLERY ni glavna vloga.");
Equal(false, MagentoExportCommand.IsPrimaryMediaRole(""), "Prazna vloga ni glavna.");
Equal(false, MagentoExportCommand.IsPrimaryMediaRole(null), "Manjkajoča vloga ni glavna.");

// ---------------------------------------------------------------------------
// 3. Zapis CSV — kodiranje, LF, escape.
// ---------------------------------------------------------------------------

var directory = Path.Combine(Path.GetTempPath(), "f7-magento-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(directory);
try
{
  var productPath = Path.Combine(directory, "products.csv");
  var customerPath = Path.Combine(directory, "customers.csv");
  var product = MagentoCsvContract.EmptyProductRow();
  product["Šifra artikla"] = "SKU-1";
  product["Naziv artikla"] = "Svetilka, \"test\"";
  var customer = MagentoCsvContract.EmptyCustomerRow();
  customer["Šifra stranke"] = "C-1";
  customer["Naziv"] = "Kupec";
  var columns = MagentoCsvContract.ProductHeaders.Select((x, i) => new ExportColumnDefinition($"P{i}", x, x, i + 1, i == 0, true));
  var customerColumns = MagentoCsvContract.CustomerHeaders.Select((x, i) => new ExportColumnDefinition($"C{i}", x, x, i + 1, i == 0, true));
  await B2bProductCsvGenerator.WriteAsync(productPath, columns, new[] { product });
  await CustomerCsvGenerator.WriteAsync(customerPath, customerColumns, new[] { customer });
  var productBytes = await File.ReadAllBytesAsync(productPath);
  var productText = Encoding.UTF8.GetString(productBytes);
  var customerText = await File.ReadAllTextAsync(customerPath, Encoding.UTF8);
  Equal(false, productBytes.Length >= 3 && productBytes[..3].SequenceEqual(new byte[] { 0xEF, 0xBB, 0xBF }), "CSV nima BOM.");
  Equal(false, productText.Contains("\r"), "Izdelki uporabljajo LF.");
  Equal(false, customerText.Contains("\r"), "Stranke uporabljajo LF.");
  Contains(productText, "SKU-1", "SKU je v izvozu.");
  Contains(productText, "\"Svetilka, \"\"test\"\"\"", "CSV escape vejice in narekovajev.");
  Equal(2, productText.Split('\n', StringSplitOptions.RemoveEmptyEntries).Length, "Glava in ena vrstica izdelka.");
  Equal(2, customerText.Split('\n', StringSplitOptions.RemoveEmptyEntries).Length, "Glava in ena vrstica stranke.");
}
finally { Directory.Delete(directory, true); }

// ---------------------------------------------------------------------------
// 4. Ukaz zavrne nesmiselne argumente — brez baze.
// ---------------------------------------------------------------------------

await Throws<InvalidOperationException>(
  () => MagentoExportCommand.ExecuteAsync(1, Path.GetTempPath(), "", CancellationToken.None),
  "Brez povezovalnega niza mora ukaz pasti.");
await Throws<ArgumentOutOfRangeException>(
  () => MagentoExportCommand.ExecuteAsync(0, Path.GetTempPath(), "Server=x", CancellationToken.None),
  "OrganizationId 0 mora pasti.");

// ---------------------------------------------------------------------------
// 5. Ukaz dejansko izveden proti razvojni bazi.
//
// To je edini del, ki bi ujel obe napaki, najdeni 2026-08-20:
//   - prb2c.VatRate ni obstajal -> SQL se ni prevedel in ukaz ni zajel nicesar;
//   - vloga medija se je primerjala z MAIN -> glavna slika vedno prazna.
// Prejsnji test je preverjal samo MagentoCsvContract in te poti ni nikoli izvedel.
// ---------------------------------------------------------------------------

var connectionString = Environment.GetEnvironmentVariable("PIM_CONNECTION_STRING");
if (string.IsNullOrWhiteSpace(connectionString))
{
  Console.WriteLine("F7 Magento izvoz proti bazi preskočen: manjka PIM_CONNECTION_STRING.");
  Console.WriteLine("F7 Magento export: pogodba, shema, vloga glavne slike, LF/UTF8 brez BOM in escape PASS.");
  return 0;
}

const int organizationId = 2;
const string primaryUrl = "https://test.local/f7-primary.jpg";
const string galleryUrl = "https://test.local/f7-gallery.jpg";

await using var connection = new SqlConnection(connectionString);
await connection.OpenAsync();

// Vzamemo obstojec promoviran izdelek in mu zacasno dodamo dva medija. Novega izdelka
// ne ustvarjamo - manj posega v skupno stanje, in test brise samo svoji dve vrstici.
long pimProductId;
string itemId;
await using (var pick = new SqlCommand(
  "SELECT TOP(1) PimProductId, ItemID FROM pim.Product WHERE OrganizationId=@OrgId ORDER BY ItemID;", connection))
{
  pick.Parameters.AddWithValue("@OrgId", organizationId);
  await using var reader = await pick.ExecuteReaderAsync();
  if (!await reader.ReadAsync()) throw new InvalidOperationException("V pim.Product ni izdelka organizacije 2 za dokaz izvoza.");
  pimProductId = reader.GetInt64(0);
  itemId = reader.GetString(1);
}

// Zapomnimo si natanko tiste vrstice, ki jih vstavimo. Brisanje po (PimProductId, SortOrder)
// bi lahko odstranilo tuje vrstice, ki bi slučajno imele isti SortOrder — AGENTS.md §4.1
// dovoli testu brisati samo tisto, kar je ustvaril sam.
var seededMediaIds = new List<long>();
var seededPriceIds = new List<long>();
var seededAttributeIds = new List<long>();
var seededCategoryIds = new List<long>();
long? seededCustomerId = null;
var exportDirectory = Path.Combine(Path.GetTempPath(), "f7-magento-db-" + Guid.NewGuid().ToString("N"));

// try se zacne PRED prvim vstavljanjem. Ce bi se zacel sele po sajenju, bi neuspeh
// vmesnega koraka (krsitev omejitve, manjkajoc privzeti prag) pustil testne vrstice
// v skupni razvojni bazi - finally se v tem primeru sploh ne bi izvedel.
try
{
  await using (var seed = new SqlCommand("""
    INSERT pim.ProductMedia (PimProductId, Url, Role, SortOrder)
    OUTPUT INSERTED.PimProductMediaId
    VALUES (@PimProductId, @PrimaryUrl, N'PRIMARY', 901),
           (@PimProductId, @GalleryUrl, N'GALLERY', 902);
    """, connection))
  {
    seed.Parameters.AddWithValue("@PimProductId", pimProductId);
    seed.Parameters.AddWithValue("@PrimaryUrl", primaryUrl);
    seed.Parameters.AddWithValue("@GalleryUrl", galleryUrl);
    await using var seedReader = await seed.ExecuteReaderAsync();
    while (await seedReader.ReadAsync()) seededMediaIds.Add(seedReader.GetInt64(0));
  }

  Equal(2, seededMediaIds.Count, "Test mora vstaviti natanko dva medija.");

  // Dve ceni B2C: tekoca in vnaprej pripravljena. Izvoz mora vzeti tekoco — brez omejitve
  // ValidFrom <= zdaj bi ORDER BY ValidFrom DESC izbral prihodnjo in bi se pojavila v
  // Magentu, preden zacne veljati.
  await using (var seedPrices = new SqlCommand("""
    INSERT pim.ProductPrice (PimProductId, PriceList, Net, VatRate, ValidFrom, IsActive)
    OUTPUT INSERTED.PimProductPriceId
    VALUES (@PimProductId, N'B2C', 111.11, 22, SYSUTCDATETIME(), 1),
           (@PimProductId, N'B2C', 999.99, 22, DATEADD(day, 30, SYSUTCDATETIME()), 1);
    """, connection))
  {
    seedPrices.Parameters.AddWithValue("@PimProductId", pimProductId);
    await using var priceReader = await seedPrices.ExecuteReaderAsync();
    while (await priceReader.ReadAsync()) seededPriceIds.Add(priceReader.GetInt64(0));
  }

  Equal(2, seededPriceIds.Count, "Test mora vstaviti natanko dve ceni.");

  await using (var seedCategory = new SqlCommand("""
    INSERT pim.ProductCategory (PimProductId, WebSite, CategoryPath)
    OUTPUT INSERTED.PimProductCategoryId
    VALUES (@PimProductId, N'B2C', N'Svetila/Stropne'),
           (@PimProductId, N'B2C_EN', N'Lights/Ceiling');
    """, connection))
  {
    seedCategory.Parameters.AddWithValue("@PimProductId", pimProductId);
    await using var categoryReader = await seedCategory.ExecuteReaderAsync();
    while (await categoryReader.ReadAsync()) seededCategoryIds.Add(categoryReader.GetInt64(0));
  }

  // Atributni stolpci (54 naprej) se polnijo podatkovno: kanonicna koda atributa mora biti
  // enaka glavi iz predloge. Ta test dokaze, da mehanizem dela — v bazi taka konfiguracija
  // danes ne obstaja, zato so ti stolpci v resnicnem izvozu prazni (glej TASKBOARD.md).
  await using (var seedAttribute = new SqlCommand("""
    INSERT pim.ProductAttribute (PimProductId, AttributeCode, Value)
    OUTPUT INSERTED.PimProductAttributeId
    VALUES (@PimProductId, @AttributeCode, N'E27');
    """, connection))
  {
    seedAttribute.Parameters.AddWithValue("@PimProductId", pimProductId);
    seedAttribute.Parameters.AddWithValue("@AttributeCode", MagentoCsvContract.ProductHeaders[53].Trim());
    await using var attributeReader = await seedAttribute.ExecuteReaderAsync();
    while (await attributeReader.ReadAsync()) seededAttributeIds.Add(attributeReader.GetInt64(0));
  }

  // ---------------------------------------------------------------------------
  // Testna stranka. Razvojna baza nima nobene stranke z WebEnabled=1, zato brez tega
  // izvoz strank ostane prazen in trije robni primeri niso dokazani:
  //   - izklopljen (IsActive=0) prag stranke se mora vrniti na privzeti prag;
  //   - potekel skupinski rabat ne sme v izvoz;
  //   - veljaven skupinski rabat mora v izvoz.
  // ---------------------------------------------------------------------------

  const string customerKey = "F7-TEST-KUPEC";

  await using (var seedCustomer = new SqlCommand("""
    INSERT b2b.Customer (OrganizationId, CustomerKey, Name, PayerCode, PayerName, PriceListCode)
    OUTPUT INSERTED.CustomerId
    VALUES (@OrgId, @CustomerKey, N'F7 testni kupec', N'PL-1', N'F7 placnik', N'CENIK-1');
    """, connection))
  {
    seedCustomer.Parameters.AddWithValue("@OrgId", organizationId);
    seedCustomer.Parameters.AddWithValue("@CustomerKey", customerKey);
    seededCustomerId = Convert.ToInt64(await seedCustomer.ExecuteScalarAsync());
  }

  await using (var seedProfile = new SqlCommand("""
    INSERT pim.CustomerWebProfile (CustomerId, CustomerTypeCode, PackagingDiscountEnabled, ValueDiscountEnabled, B2bPlusEnabled, WebEnabled)
    -- B2B+ je VKLOPLJEN, a mu je okno poteklo: izvoz mora javiti 0, ne 1.
    VALUES (@CustomerId, NULL, 1, 1, 1, 1);
    UPDATE pim.CustomerWebProfile SET B2bPlusValidFrom='2020-01-01', B2bPlusValidTo='2020-12-31'
    WHERE CustomerId=@CustomerId;

    -- Prag 1 je IZKLOPLJEN: izvoz mora vzeti privzeto vrednost iz pim.ValueDiscountTier.
    INSERT pim.CustomerValueDiscountTier (CustomerId, TierNumber, ThresholdGrossExVat, PercentValue, IsActive)
    VALUES (@CustomerId, 1, 99999, 42, 0);

    -- Prag 2 je vklopljen: izvoz mora vzeti vrednost stranke.
    INSERT pim.CustomerValueDiscountTier (CustomerId, TierNumber, ThresholdGrossExVat, PercentValue, IsActive)
    VALUES (@CustomerId, 2, 4321, 7, 1);

    -- Veljaven, potekel in prihodnji skupinski rabat.
    INSERT b2b.GroupDiscount (CustomerId, ItemGroupCode, PercentValue, ValidFrom, ValidTo)
    VALUES (@CustomerId, N'NW',        11, NULL, NULL),
           (@CustomerId, N'F7POTEKEL', 22, '2020-01-01', '2020-12-31'),
           (@CustomerId, N'F7PRIHOD',  33, '2999-01-01', NULL);
    """, connection))
  {
    seedProfile.Parameters.AddWithValue("@CustomerId", seededCustomerId!.Value);
    await seedProfile.ExecuteNonQueryAsync();
  }

  decimal defaultTier1Threshold, defaultTier1Percent;
  await using (var defaults = new SqlCommand(
    "SELECT ThresholdGrossExVat, PercentValue FROM pim.ValueDiscountTier WHERE TierNumber=1;", connection))
  {
    await using var reader = await defaults.ExecuteReaderAsync();
    if (!await reader.ReadAsync()) throw new InvalidOperationException("Manjka privzeti prag 1 v pim.ValueDiscountTier.");
    defaultTier1Threshold = reader.GetDecimal(0);
    defaultTier1Percent = reader.GetDecimal(1);
  }

  await MagentoExportCommand.ExecuteAsync(organizationId, exportDirectory, connectionString);

  var productsCsv = Path.Combine(exportDirectory, "magento-products.csv");
  var customersCsv = Path.Combine(exportDirectory, "magento-customers.csv");
  Equal(true, File.Exists(productsCsv), "Ukaz mora ustvariti magento-products.csv.");
  Equal(true, File.Exists(customersCsv), "Ukaz mora ustvariti magento-customers.csv.");

  var productLines = (await File.ReadAllTextAsync(productsCsv, Encoding.UTF8))
    .Split('\n', StringSplitOptions.RemoveEmptyEntries);
  var customerLines = (await File.ReadAllTextAsync(customersCsv, Encoding.UTF8))
    .Split('\n', StringSplitOptions.RemoveEmptyEntries);

  Equal(215, SplitCsvLine(productLines[0]).Count, "Glava izdelkov mora imeti 215 stolpcev.");
  Equal(19, SplitCsvLine(customerLines[0]).Count, "Glava strank mora imeti 19 stolpcev.");
  Equal(true, productLines.Length > 1, "Izvoz mora vrniti vsaj eno vrstico izdelka — če je SQL padel, jih ni.");

  var row = productLines.Skip(1).Select(SplitCsvLine)
    .FirstOrDefault(fields => fields.Count > 0 && fields[0] == itemId)
    ?? throw new InvalidOperationException($"Izvoz ne vsebuje vrstice za izdelek {itemId}.");

  Equal(215, row.Count, "Vrstica izdelka mora imeti 215 stolpcev.");
  Equal("111.11", row[28], "Cena B2C mora biti tekoca cena, ne vnaprej pripravljena.");
  Equal("E27", row[53], "Atribut z kodo, enako glavi predloge, mora pristati v svojem stolpcu.");

  // Kategorije: WebSite B2C -> slovenski stolpec, B2C_EN -> angleski.
  if (seededCategoryIds.Count > 0)
  {
    Equal("Svetila/Stropne", row[26], "Stolpec 'Kategorije vid SLO' mora vsebovati pot iz B2C.");
    Equal("Lights/Ceiling", row[25], "Stolpec 'Kategorije vid ANG' mora vsebovati pot iz B2C_EN.");
  }

  // Socasni izvoz v isto mapo mora pasti z jasnim sporocilom, ne objaviti mesanega para.
  using (MagentoExportLock.Acquire(exportDirectory))
  {
    await Throws<InvalidOperationException>(
      () => MagentoExportCommand.ExecuteAsync(organizationId, exportDirectory, connectionString, CancellationToken.None),
      "Drugi socasni izvoz v isto mapo mora pasti.");
  }
  Equal(primaryUrl, row[37], "Stolpec 'Glavna slika' mora vsebovati medij z vlogo PRIMARY.");
  Contains(row[38], galleryUrl, "Stolpec 'Ostale slike' mora vsebovati medij z vlogo GALLERY.");
  Equal(false, row[38].Contains(primaryUrl, StringComparison.Ordinal),
    "Glavna slika se ne sme podvojiti med ostalimi slikami.");

  // --- Stranka: izklopljen prag in veljavnostno okno rabatov --------------
  var customerRow = customerLines.Skip(1).Select(SplitCsvLine)
    .FirstOrDefault(fields => fields.Count > 0 && fields[0] == customerKey)
    ?? throw new InvalidOperationException($"Izvoz strank ne vsebuje vrstice za {customerKey}.");

  Equal(19, customerRow.Count, "Vrstica stranke mora imeti 19 stolpcev.");

  // idx 10/11 = Rabat prag 1 / Rabat % 1 — override je IsActive=0, zato mora priti privzeta vrednost.
  Equal(Decimal(defaultTier1Threshold), customerRow[10],
    "Izklopljen prag stranke se mora vrniti na privzeti prag iz pim.ValueDiscountTier.");
  Equal(Decimal(defaultTier1Percent), customerRow[11],
    "Izklopljen odstotek stranke se mora vrniti na privzeti odstotek.");

  // idx 12/13 = Rabat prag 2 / Rabat % 2 — override je aktiven, zato mora priti vrednost stranke.
  Equal("4321", customerRow[12], "Aktiven prag 2 stranke mora biti izvozen.");
  Equal("7", customerRow[13], "Aktiven odstotek 2 stranke mora biti izvozen.");

  // idx 17 = Skupine popustov, idx 18 = Popust NW
  Equal("0", customerRow[16], "B2B+ s poteklim oknom mora biti izvozen kot 0, cetudi je zastavica 1.");
  Contains(customerRow[17], "NW=11%", "Veljaven skupinski rabat mora biti izvozen.");
  Equal(false, customerRow[17].Contains("F7POTEKEL", StringComparison.Ordinal),
    "Potekel skupinski rabat ne sme biti izvozen.");
  Equal(false, customerRow[17].Contains("F7PRIHOD", StringComparison.Ordinal),
    "Prihodnji skupinski rabat ne sme biti izvozen.");
  Equal("11", customerRow[18], "Popust NW mora priti iz veljavnega rabata.");

  // Datoteki sta par: po uspesnem izvozu ne sme ostati nobena zacasna datoteka.
  Equal(0, Directory.GetFiles(exportDirectory, "*.tmp").Length,
    "Po uspesnem izvozu ne sme ostati nobena .tmp datoteka.");

  // Oznaka dokoncanosti: porabnik sme brati sele, ko obstaja.
  var markerPath = Path.Combine(exportDirectory, "magento-export.complete");
  Equal(true, File.Exists(markerPath), "Po uspesnem izvozu mora obstajati magento-export.complete.");
  Contains(await File.ReadAllTextAsync(markerPath), "izdelki=", "Oznaka mora navesti stevilo izdelkov.");

  // In ce izvoz pade, se obstojeci par ne sme podreti na pol. Ponovimo ga s pokvarjenim
  // povezovalnim nizom: ukaz mora pasti, obe prejsnji datoteki pa ostati nespremenjeni.
  var productBefore = await File.ReadAllTextAsync(productsCsv, Encoding.UTF8);
  var customerBefore = await File.ReadAllTextAsync(customersCsv, Encoding.UTF8);
  await Throws<SqlException>(
    () => MagentoExportCommand.ExecuteAsync(
      organizationId, exportDirectory, "Server=ne-obstaja-f7;Database=PIM;Connect Timeout=2;Encrypt=False", CancellationToken.None),
    "Izvoz z nedosegljivo bazo mora pasti.");
  Equal(productBefore, await File.ReadAllTextAsync(productsCsv, Encoding.UTF8),
    "Padli izvoz ne sme spremeniti magento-products.csv.");
  Equal(customerBefore, await File.ReadAllTextAsync(customersCsv, Encoding.UTF8),
    "Padli izvoz ne sme spremeniti magento-customers.csv.");
  Equal(0, Directory.GetFiles(exportDirectory, "*.tmp").Length,
    "Padli izvoz ne sme pustiti .tmp datotek.");
  Equal(true, File.Exists(markerPath), "Padli izvoz mora pustiti oznako, ker prejsnji par ostane veljaven.");

  // Najtezji primer: poizvedbi uspeta, zatakne pa se pri zamenjavi datotek. Datoteko strank
  // zaklenemo, tako da odmik prejsnjega para ne uspe. Prejsnji par mora ostati cel — prej je
  // izdelcna datoteka koncala v .prej in jo je finally pobrisal, torej trajna izguba.
  await using (var lockStream = new FileStream(customersCsv, FileMode.Open, FileAccess.Read, FileShare.None))
  {
    await Throws<IOException>(
      () => MagentoExportCommand.ExecuteAsync(organizationId, exportDirectory, connectionString, CancellationToken.None),
      "Izvoz z zaklenjeno datoteko strank mora pasti.");
  }

  Equal(true, File.Exists(productsCsv), "Po padcu pri zamenjavi mora magento-products.csv se obstajati.");
  Equal(true, File.Exists(customersCsv), "Po padcu pri zamenjavi mora magento-customers.csv se obstajati.");
  Equal(productBefore, await File.ReadAllTextAsync(productsCsv, Encoding.UTF8),
    "Padec pri zamenjavi ne sme spremeniti magento-products.csv.");
  Equal(customerBefore, await File.ReadAllTextAsync(customersCsv, Encoding.UTF8),
    "Padec pri zamenjavi ne sme spremeniti magento-customers.csv.");
  Equal(0, Directory.GetFiles(exportDirectory, "*.tmp").Length, "Ne sme ostati .tmp datoteka.");
  Equal(0, Directory.GetFiles(exportDirectory, "*.prej").Length, "Ne sme ostati .prej datoteka.");
  Equal(true, File.Exists(markerPath), "Po povratku mora oznaka spet veljati za vrnjeni par.");

  Console.WriteLine($"F7 Magento izvoz proti bazi: {productLines.Length - 1} izdelkov, {customerLines.Length - 1} strank, glavna slika za {itemId} PASS.");
}
finally
{
  // Brisanje po vstavljenih identitetah, ne po (PimProductId, SortOrder).
  if (seededMediaIds.Count > 0)
  {
    var parameterNames = seededMediaIds.Select((_, index) => "@Id" + index).ToArray();
    await using var cleanup = new SqlCommand(
      $"DELETE FROM pim.ProductMedia WHERE PimProductMediaId IN ({string.Join(",", parameterNames)});", connection);
    for (var index = 0; index < seededMediaIds.Count; index++)
      cleanup.Parameters.AddWithValue(parameterNames[index], seededMediaIds[index]);
    await cleanup.ExecuteNonQueryAsync();
  }

  if (seededCategoryIds.Count > 0)
  {
    var categoryParameters = seededCategoryIds.Select((_, index) => "@Cat" + index).ToArray();
    await using var cleanupCategories = new SqlCommand(
      $"DELETE FROM pim.ProductCategory WHERE PimProductCategoryId IN ({string.Join(",", categoryParameters)});", connection);
    for (var index = 0; index < seededCategoryIds.Count; index++)
      cleanupCategories.Parameters.AddWithValue(categoryParameters[index], seededCategoryIds[index]);
    await cleanupCategories.ExecuteNonQueryAsync();
  }

  if (seededAttributeIds.Count > 0)
  {
    var attributeParameters = seededAttributeIds.Select((_, index) => "@Attr" + index).ToArray();
    await using var cleanupAttributes = new SqlCommand(
      $"DELETE FROM pim.ProductAttribute WHERE PimProductAttributeId IN ({string.Join(",", attributeParameters)});", connection);
    for (var index = 0; index < seededAttributeIds.Count; index++)
      cleanupAttributes.Parameters.AddWithValue(attributeParameters[index], seededAttributeIds[index]);
    await cleanupAttributes.ExecuteNonQueryAsync();
  }

  if (seededPriceIds.Count > 0)
  {
    var priceParameters = seededPriceIds.Select((_, index) => "@Price" + index).ToArray();
    await using var cleanupPrices = new SqlCommand(
      $"DELETE FROM pim.ProductPrice WHERE PimProductPriceId IN ({string.Join(",", priceParameters)});", connection);
    for (var index = 0; index < seededPriceIds.Count; index++)
      cleanupPrices.Parameters.AddWithValue(priceParameters[index], seededPriceIds[index]);
    await cleanupPrices.ExecuteNonQueryAsync();
  }

  // Testna stranka in vse, kar visi na njej. Vse te vrstice je ustvaril ta test in nobena
  // ne obstaja pred njim — CustomerId je identiteta, vrnjena ob vstavljanju. Pogojno, ker
  // se sajenje lahko ustavi ze pri prvem koraku in stranka sploh ne nastane.
  if (seededCustomerId is not null)
  {
    await using var cleanupCustomer = new SqlCommand("""
      DELETE FROM b2b.GroupDiscount WHERE CustomerId = @CustomerId;
      DELETE FROM pim.CustomerValueDiscountTier WHERE CustomerId = @CustomerId;
      DELETE FROM pim.CustomerWebProfile WHERE CustomerId = @CustomerId;
      DELETE FROM b2b.Customer WHERE CustomerId = @CustomerId;
      """, connection);
    cleanupCustomer.Parameters.AddWithValue("@CustomerId", seededCustomerId.Value);
    await cleanupCustomer.ExecuteNonQueryAsync();
  }

  if (Directory.Exists(exportDirectory)) Directory.Delete(exportDirectory, true);
}

Console.WriteLine("F7 Magento export: pogodba, shema, vloga glavne slike, LF/UTF8 brez BOM, escape in izvoz proti bazi PASS.");
return 0;

static void Equal<T>(T expected, T actual, string message) { if (!EqualityComparer<T>.Default.Equals(expected, actual)) throw new InvalidOperationException($"{message}: pričakovano {expected}, dejansko {actual}."); }

/// <summary>Ista oblika, kot jo izvoz zapise v CSV (FormatDecimalString: "0.####", invariant).</summary>
static string Decimal(decimal value) => value.ToString("0.####", System.Globalization.CultureInfo.InvariantCulture);
static void Contains(string actual, string expected, string message) { if (!actual.Contains(expected, StringComparison.Ordinal)) throw new InvalidOperationException($"{message}: manjka {expected}."); }

static async Task Throws<TException>(Func<Task> action, string message) where TException : Exception
{
  try { await action(); }
  catch (TException) { return; }
  catch (Exception exception) { throw new InvalidOperationException($"{message}: pričakovan {typeof(TException).Name}, dobil {exception.GetType().Name}."); }
  throw new InvalidOperationException($"{message}: izjeme ni bilo.");
}

/// <summary>Razdeli CSV vrstico po RFC 4180 — polje v narekovajih sme vsebovati vejico in "".</summary>
static List<string> SplitCsvLine(string line)
{
  var fields = new List<string>();
  var current = new StringBuilder();
  var inQuotes = false;
  for (var index = 0; index < line.Length; index++)
  {
    var character = line[index];
    if (inQuotes)
    {
      if (character != '"') { current.Append(character); continue; }
      if (index + 1 < line.Length && line[index + 1] == '"') { current.Append('"'); index++; continue; }
      inQuotes = false;
      continue;
    }

    if (character == '"') { inQuotes = true; continue; }
    if (character == ',') { fields.Add(current.ToString()); current.Clear(); continue; }
    current.Append(character);
  }

  fields.Add(current.ToString());
  return fields;
}
