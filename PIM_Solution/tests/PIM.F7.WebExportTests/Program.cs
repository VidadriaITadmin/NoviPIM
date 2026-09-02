using Microsoft.Extensions.Configuration;
using Microsoft.Data.SqlClient;
using System.Data;
using System.Text;
using PIM.Intranet.Services;

var repositoryRoot = FindRoot();
var buildServicePath = Path.Combine(repositoryRoot, "src", "PIM.Intranet", "Services", "WebExportBuildService.cs");
var buildPagePath = Path.Combine(repositoryRoot, "src", "PIM.Intranet", "Components", "Pages", "WebExportBuild.razor");
Assert(File.Exists(buildServicePath), "Manjka pretočni servis WebExportBuildService.");
Assert(File.Exists(buildPagePath), "Manjka stran /splet/izvoz.");

var buildServiceText = File.ReadAllText(buildServicePath);
foreach (var contract in new[] { "PreviewAsync", "WriteCsvAsync", "SqlDataReader", "StreamWriter", "UTF8Encoding(true)", "CommandTimeout = 600", "@Take", "PIM_splet_" })
  Assert(buildServiceText.Contains(contract, StringComparison.Ordinal), "Pretočni servis nima pogodbe: " + contract);
var buildPageText = File.ReadAllText(buildPagePath);
foreach (var contract in new[] { "@page \"/splet/izvoz\"", "Samo objavljeni", "Prikaži", "Prenesi CSV", "200", "PreviewAsync" })
  Assert(buildPageText.Contains(contract, StringComparison.Ordinal), "Stran izvoza nima: " + contract);
var webPageText = File.ReadAllText(Path.Combine(repositoryRoot, "src", "PIM.Intranet", "Components", "Pages", "Web.razor"));
Assert(webPageText.Contains("href=\"splet/izvoz\"", StringComparison.Ordinal)
    && webPageText.Contains("Pripravi izvoz", StringComparison.Ordinal),
  "/splet mora biti edina vstopna točka do nove strani.");
var programText = File.ReadAllText(Path.Combine(repositoryRoot, "src", "PIM.Intranet", "Program.cs"));
Assert(programText.Contains("WebExportBuildService", StringComparison.Ordinal)
    && programText.Contains("Response.Body", StringComparison.Ordinal)
    && programText.Contains("WriteCsvAsync", StringComparison.Ordinal),
  "Minimalni API mora CSV pisati naravnost v Response.Body.");
Assert(programText.Split("GetProductListAsync", StringSplitOptions.None).Length - 1 == 1
    && !programText.Contains("while (rows.Count", StringComparison.Ordinal),
  "/izvoz/izdelki.csv mora nabor prebrati z enim klicem do 20.000, ne s 100 zaporednimi stranmi.");

// Datoteke, ki gredo na splet, ne cakajo vec v mapi na disku (migracija 142). Datoteko in
// predogled sestavi ista procedura out.GetExportRows, ki jo uporabi tudi PIM.B2bWorker.
//
// Uporabnik 2026-08-28: »bi oni dejansko CSV videli, ki ga bomo dali za splet in da si ga
// lahko potegnejo dol«, ter »imeli bomo vec CSVjev za splet — artikli in pa stranke«.

Assert(!File.Exists(Path.Combine(repositoryRoot, "src", "PIM.Intranet", "Services", "WebExportFileService.cs")),
  "Branja datotek z diska v intranetu ne sme vec biti; CSV nastane iz tabel.");
// Iscemo registracijo poti in servisa, ne omembe imena: zgodovinsko pojasnilo v komentarju
// (»prej je bila tu mapa WebExport:Directory«) je koristno in ne sme podreti testa.
Assert(!programText.Contains("MapGet(\"/izvoz/splet/{fileName}\"", StringComparison.Ordinal)
    && !programText.Contains("AddScoped<WebExportFileService>", StringComparison.Ordinal),
  "Program.cs ne sme imeti ne prenosa datoteke z diska ne servisa, ki jo bere.");
Assert(!File.ReadAllText(Path.Combine(repositoryRoot, "src", "PIM.Intranet", "appsettings.json"))
    .Contains("WebExport", StringComparison.Ordinal),
  "Nastavitve intraneta ne smejo vec obljubljati mape s spletnimi izvozi.");
foreach (var contract in new[] { "izvoz/splet-na-zahtevo", "TogglePreviewAsync", "DownloadHref", "OnlyPublishedDefault" })
  Assert(webPageText.Contains(contract, StringComparison.Ordinal),
    "Stran /splet mora izvoz pripraviti iz registra, ne z diska: manjka " + contract);

{
  var connectionString = Environment.GetEnvironmentVariable("PIM_CONNECTION_STRING") ?? LocalConnectionString();
  if (!string.IsNullOrWhiteSpace(connectionString))
  {
    var settings = new SqlConnectionStringBuilder(connectionString);
    if (!string.Equals(settings.InitialCatalog, "PIM", StringComparison.OrdinalIgnoreCase))
      throw new InvalidOperationException("F7 spletni izvoz je dovoljen samo v razvojni bazi PIM.");

    await using var connection = new SqlConnection(connectionString);
    await connection.OpenAsync();

    // --- Kanonicni profil: oblika pride iz registra, kot od migracije 139 --------------
    var profileId = await ProfileIdAsync(connection, "WEB_B2C_PRODUCTS");
    var expectedColumns = await ColumnNamesAsync(connection, profileId);
    var previewPage = await ReadWebExportAsync(connection, "intranet.GetWebExportRows", 2, profileId, onlyPublished: false, take: 2);

    Assert(expectedColumns.Count > 0, "Obstoječi spletni profil mora imeti aktivne stolpce.");
    Assert(previewPage.Columns.SequenceEqual(expectedColumns),
      "Stolpci in vrstni red predogleda morajo priti iz out.ExportColumn.");
    Assert(previewPage.Rows <= 2, "Predogled mora upoštevati @Take.");
    Assert(previewPage.Total >= previewPage.Rows, "@TotalCount ne sme biti manjši od vrnjene strani.");

    var published = await ReadWebExportAsync(connection, "intranet.GetWebExportRows", 2, profileId, onlyPublished: true, take: 1);
    Assert(published.Total <= previewPage.Total,
      "Filter samo objavljeni ne sme razširiti nabora.");

    // --- Magento izdelki: vrednosti pridejo iz sloja pim, ne iz canon.FieldValue -------
    //
    // Zakaj to potrebuje test: profil MAGENTO_PRODUCTS ima 213 stolpcev, od katerih jih
    // 186 od 191 preslikanih v canon.FieldValue nima nobene vrstice (kanonicni sloj
    // uporablja druge kode). Ce bi ta profil kdaj spet bral kanonicni vir, bi datoteka
    // nastala, imela vse glave in bila skoraj prazna — kar se prebere kot »dobavitelj
    // tega ne poslje«, ne kot okvara.
    var magentoProductProfileId = await ProfileIdAsync(connection, "MAGENTO_PRODUCTS");
    var magentoProductColumns = await ColumnNamesAsync(connection, magentoProductProfileId);
    var magentoProducts = await ReadWebExportAsync(connection, "out.GetExportRows", 2, magentoProductProfileId, onlyPublished: false, take: 5);
    Assert(magentoProducts.Columns.SequenceEqual(magentoProductColumns),
      "Stolpci izvoza izdelkov za Magento morajo priti iz out.ExportColumn.");
    Assert(magentoProducts.Total > 0 && magentoProducts.Rows > 0,
      "Izvoz izdelkov za Magento mora vrniti vrstice; brez njih SQL ni tekel.");
    Assert(magentoProducts.FirstValues.Count > 0 && !string.IsNullOrWhiteSpace(magentoProducts.FirstValues[0]),
      "Prvi stolpec (šifra artikla) ne sme biti prazen — brez nje vrstica ni uvozljiva.");
    Assert(magentoProducts.FirstValues.Count(value => !string.IsNullOrWhiteSpace(value)) > 5,
      "Vrstica z eno samo izpolnjeno vrednostjo pomeni, da vir vrednosti ni pravi.");

    // --- Magento stranke: profil, ki ga je 139 se zavracala --------------------------
    var magentoCustomerProfileId = await ProfileIdAsync(connection, "MAGENTO_CUSTOMERS");
    var magentoCustomerColumns = await ColumnNamesAsync(connection, magentoCustomerProfileId);
    // onlyPublished = false: razvojna baza nima nobene stranke z WebEnabled = 1, zato bi
    // sicer nabor bil prazen in oblika ne bi bila dokazana nad resnicnimi vrsticami.
    var magentoCustomers = await ReadWebExportAsync(connection, "out.GetExportRows", 2, magentoCustomerProfileId, onlyPublished: false, take: 3);
    Assert(magentoCustomers.Columns.SequenceEqual(magentoCustomerColumns),
      "Stolpci izvoza strank morajo priti iz out.ExportColumn.");
    Assert(magentoCustomers.Total > 0 && magentoCustomers.Rows > 0,
      "Izvoz strank mora vrniti vrstice; profil strank ni vec zavrnjen.");
    Assert(!string.IsNullOrWhiteSpace(magentoCustomers.FirstValues[0]),
      "Prvi stolpec (šifra stranke) ne sme biti prazen.");

    var webEnabledOnly = await ReadWebExportAsync(connection, "out.GetExportRows", 2, magentoCustomerProfileId, onlyPublished: true, take: 1);
    Assert(webEnabledOnly.Total <= magentoCustomers.Total,
      "Omejitev na spletne stranke ne sme razširiti nabora.");

    // Kontakti iz migracije 140 morajo imeti vir; brez tega trije stolpci ostanejo prazni.
    foreach (var pair in new[] { ("CUC03", "Customer.Email"), ("CUC04", "Customer.Phone"), ("CUC05", "Customer.Persons") })
      Assert(await FieldCodeAsync(connection, magentoCustomerProfileId, pair.Item1) == pair.Item2,
        $"Stolpec {pair.Item1} mora brati {pair.Item2}.");

    // Zapis stevila je pogodba do Magenta in ne stvar jezikovnih nastavitev seje.
    foreach (var pair in new[] { ("12.34", "12.34"), ("12", "12"), ("0", "0"), ("-0.5", "-0.5"), ("1.23456", "1.2346") })
      Assert(await MagentoNumberAsync(connection, pair.Item1) == pair.Item2,
        $"out.MagentoNumber({pair.Item1}) mora dati {pair.Item2}.");

    // --- Servis intraneta: brez preoblikovanja vrne registrski predogled --------------
    var configuration = new ConfigurationBuilder()
      .AddInMemoryCollection(new Dictionary<string, string?> { ["ConnectionStrings:Pim"] = connectionString })
      .Build();
    var build = new WebExportBuildService(configuration);
    var servicePreview = await build.PreviewAsync(2, profileId, null, false, null, take: 2);
    Assert(servicePreview.Columns.SequenceEqual(expectedColumns) && servicePreview.Rows.Count == previewPage.Rows,
      "Servis mora brez preoblikovanja vrniti registrski predogled.");

    var customerPreview = await build.PreviewAsync(2, magentoCustomerProfileId, null, false, null, take: 2);
    Assert(customerPreview.Columns.SequenceEqual(magentoCustomerColumns) && customerPreview.Rows.Count > 0,
      "Isti servis mora znati pripraviti tudi predogled strank.");

    var itemId = await FirstItemIdAsync(connection, 2);
    await using var csv = new MemoryStream();
    await build.WriteCsvAsync(2, profileId, null, false, itemId, csv);
    var bytes = csv.ToArray();
    Assert(bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF,
      "CSV mora imeti UTF-8 BOM za Excel in slovenske znake.");
    var csvText = new UTF8Encoding(false).GetString(bytes, 3, bytes.Length - 3);
    Assert(csvText.StartsWith(string.Join(';', expectedColumns) + Environment.NewLine, StringComparison.Ordinal),
      "CSV glava mora ohraniti registrski vrstni red in podpičje.");
    Assert(WebExportBuildService.Escape("a;\"b") == "\"a;\"\"b\"",
      "Podpičje in dvojni narekovaj morata biti pravilno ubežana.");
    Assert(WebExportBuildService.FileName("WEB_B2C_PRODUCTS", new DateTime(2026, 9, 2, 14, 5, 0))
      == "PIM_splet_WEB_B2C_PRODUCTS_20260902_1405.csv", "Ime datoteke mora vsebovati profil in minuto nastanka.");
  }
}

Console.WriteLine("F7 spletni izvoz: register, izdelki in stranke iz tabel, brez datoteke na disku PASS.");
return 0;

static void Assert(bool condition, string message)
{
  if (!condition) throw new InvalidOperationException(message);
}

static async Task<int> ProfileIdAsync(SqlConnection connection, string code)
{
  await using var command = new SqlCommand(
    "SELECT ExportProfileId FROM out.ExportProfile WHERE ProfileCode=@Code AND IsActive=1;", connection);
  command.Parameters.AddWithValue("@Code", code);
  return Convert.ToInt32(await command.ExecuteScalarAsync());
}

static async Task<IReadOnlyList<string>> ColumnNamesAsync(SqlConnection connection, int profileId)
{
  await using var command = new SqlCommand(
    "SELECT OutputColumnName FROM out.ExportColumn WHERE ExportProfileId=@Profile AND IsActive=1 ORDER BY SortOrder;", connection);
  command.Parameters.AddWithValue("@Profile", profileId);
  await using var reader = await command.ExecuteReaderAsync();
  var names = new List<string>();
  while (await reader.ReadAsync()) names.Add(reader.GetString(0));
  return names;
}

static async Task<(IReadOnlyList<string> Columns, int Rows, int Total, IReadOnlyList<string?> FirstValues)> ReadWebExportAsync(
  SqlConnection connection, string procedure, int organizationId, int profileId, bool onlyPublished, int take)
{
  await using var command = new SqlCommand(procedure, connection)
  {
    CommandType = CommandType.StoredProcedure,
    CommandTimeout = 600,
  };
  command.Parameters.AddWithValue("@OrganizationId", organizationId);
  command.Parameters.AddWithValue("@ExportProfileId", profileId);
  command.Parameters.AddWithValue("@WebSite", DBNull.Value);
  command.Parameters.AddWithValue("@OnlyPublished", onlyPublished);
  command.Parameters.AddWithValue("@Search", DBNull.Value);
  command.Parameters.AddWithValue("@Skip", 0);
  command.Parameters.AddWithValue("@Take", take);
  var total = command.Parameters.Add("@TotalCount", SqlDbType.Int);
  total.Direction = ParameterDirection.Output;

  var rows = 0;
  string[] columns;
  string?[] firstValues = [];
  await using (var reader = await command.ExecuteReaderAsync())
  {
    columns = Enumerable.Range(0, reader.FieldCount).Select(reader.GetName).ToArray();
    while (await reader.ReadAsync())
    {
      if (rows == 0)
        firstValues = Enumerable.Range(0, reader.FieldCount)
          .Select(index => reader.IsDBNull(index) ? null : reader.GetString(index)).ToArray();
      rows++;
    }
  }
  return (columns, rows, Convert.ToInt32(total.Value), firstValues);
}

static async Task<string?> FieldCodeAsync(SqlConnection connection, int profileId, string columnCode)
{
  await using var command = new SqlCommand(
    "SELECT CanonicalFieldCode FROM out.ExportColumn WHERE ExportProfileId=@Profile AND ColumnCode=@Code AND IsActive=1;", connection);
  command.Parameters.AddWithValue("@Profile", profileId);
  command.Parameters.AddWithValue("@Code", columnCode);
  return await command.ExecuteScalarAsync() as string;
}

static async Task<string?> MagentoNumberAsync(SqlConnection connection, string value)
{
  await using var command = new SqlCommand("SELECT out.MagentoNumber(CONVERT(decimal(38,6), @Value));", connection);
  command.Parameters.AddWithValue("@Value", value);
  return await command.ExecuteScalarAsync() as string;
}

static async Task<string> FirstItemIdAsync(SqlConnection connection, int organizationId)
{
  await using var command = new SqlCommand(
    "SELECT TOP(1) ItemID FROM canon.Product WHERE OrganizationId=@Org ORDER BY ItemID;", connection);
  command.Parameters.AddWithValue("@Org", organizationId);
  return Convert.ToString(await command.ExecuteScalarAsync())
    ?? throw new InvalidOperationException("Organizacija za test nima izdelka.");
}

static string? LocalConnectionString()
{
  var current = new DirectoryInfo(Directory.GetCurrentDirectory());
  while (current is not null)
  {
    var candidate = Path.Combine(current.FullName, "src", "PIM.Intranet", "appsettings.Local.json");
    if (File.Exists(candidate))
      return new ConfigurationBuilder().AddJsonFile(candidate).Build().GetConnectionString("Pim");
    current = current.Parent;
  }
  return null;
}

static string FindRoot()
{
  foreach (var start in new[] { Directory.GetCurrentDirectory(), AppContext.BaseDirectory })
  {
    var current = new DirectoryInfo(start);
    while (current is not null)
    {
      if (File.Exists(Path.Combine(current.FullName, "PIM.sln"))) return current.FullName;
      current = current.Parent;
    }
  }
  throw new InvalidOperationException("PIM_Solution ni najden.");
}
