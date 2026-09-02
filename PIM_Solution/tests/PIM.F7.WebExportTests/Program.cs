using Microsoft.Extensions.Configuration;
using Microsoft.Data.SqlClient;
using System.Data;
using PIM.Intranet.Services;

// Datoteke, ki gredo na splet: branje, predogled in varna razresitev imena.
//
// Uporabnik 2026-08-28: »bi oni dejansko CSV videli, ki ga bomo dali za splet in da si ga
// lahko potegnejo dol«, ter »imeli bomo vec CSVjev za splet — artikli in pa stranke«.
//
// Test si mapo naredi sam in jo za sabo pospravi; ne potrebuje ne baze ne workerja.

var sandbox = Path.Combine(Path.GetTempPath(), "pim-web-export-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(sandbox);
try
{
  File.WriteAllText(Path.Combine(sandbox, "magento-products.csv"),
    "Šifra artikla,EAN,Naziv artikla\nBA.BC15.00310,5949097729164,\"Sijalka, \"\"E14\"\", bela\"\nNW.10168,5903139101684,Svetilka\n");
  File.WriteAllText(Path.Combine(sandbox, "magento-customers.csv"),
    "Šifra stranke,Naziv,Skupina\n888,ITI ELEKT d.o.o.,b2b_trgovec\n");
  // Datoteka, ki ni CSV, ne sme priti v seznam.
  File.WriteAllText(Path.Combine(sandbox, "magento-export.complete"), "ok");

  var service = new WebExportFileService(new ConfigurationBuilder()
    .AddInMemoryCollection(new Dictionary<string, string?> { ["WebExport:Directory"] = sandbox })
    .Build());

  var files = service.List();
  Assert(files.Count == 2, "V seznamu morata biti natanko dve datoteki CSV; oznaka .complete ni izvoz.");
  Assert(files.Any(file => file.Kind == "Izdelki"), "Datoteka izdelkov mora biti prepoznana kot Izdelki.");
  Assert(files.Any(file => file.Kind == "Stranke"), "Datoteka strank mora biti prepoznana kot Stranke.");
  Assert(files.Single(file => file.Kind == "Izdelki").RowCount == 2, "Stevilo vrstic je brez glave.");
  Assert(files.Single(file => file.Kind == "Stranke").RowCount == 1, "Stevilo vrstic je brez glave.");

  var preview = service.Preview("magento-products.csv");
  Assert(preview is not null, "Predogled datoteke izdelkov mora obstajati.");
  Assert(preview!.Columns.Count == 3, "Glava mora imeti tri stolpce.");
  Assert(preview.Columns[0] == "Šifra artikla", "Glava mora priti nazaj nespremenjena.");
  Assert(preview.Rows.Count == 2, "Predogled mora vrniti obe vrstici.");
  // Vejica in narekovaji v nazivu so v izvozih pravilo, ne izjema; brez tega bi se stolpci zamaknili.
  Assert(preview.Rows[0][2] == "Sijalka, \"E14\", bela", "Narekovaji in vejica v vrednosti ne smejo razbiti stolpcev.");
  Assert(!preview.Truncated, "Dve vrstici nista odrezan predogled.");

  Assert(service.Resolve("magento-products.csv") is not null, "Datoteka iz mape se mora razresiti.");
  // Ime se ne sestavlja iz uporabnikovega niza: sprejeta so samo imena, ki jih je servis nasel.
  foreach (var attack in new[] { "../appsettings.Local.json", "..\\appsettings.Local.json", "magento-export.complete", "", "magento-PRODUCTS.csv" })
    Assert(service.Resolve(attack) is null, "Neveljavno ime se ne sme razresiti: " + attack);

  var empty = new WebExportFileService(new ConfigurationBuilder().Build());
  Assert(empty.Directory is null && empty.List().Count == 0,
    "Brez nastavljene mape servis vrne prazen seznam; stran to pove naravnost.");

  // Predogled na zahtevo mora obliko dobiti iz registra, ne iz seznama v aplikaciji.
  var connectionString = Environment.GetEnvironmentVariable("PIM_CONNECTION_STRING") ?? LocalConnectionString();
  if (!string.IsNullOrWhiteSpace(connectionString))
  {
    var settings = new SqlConnectionStringBuilder(connectionString);
    if (!string.Equals(settings.InitialCatalog, "PIM", StringComparison.OrdinalIgnoreCase))
      throw new InvalidOperationException("F7 spletni izvoz je dovoljen samo v razvojni bazi PIM.");

    await using var connection = new SqlConnection(connectionString);
    await connection.OpenAsync();
    var profileId = await ProfileIdAsync(connection, "WEB_B2C_PRODUCTS");
    var expectedColumns = await ColumnNamesAsync(connection, profileId);
    var previewPage = await ReadWebExportAsync(connection, profileId, onlyPublished: false, take: 2);

    Assert(expectedColumns.Count > 0, "Obstoječi spletni profil mora imeti aktivne stolpce.");
    Assert(previewPage.Columns.SequenceEqual(expectedColumns),
      "Stolpci in vrstni red predogleda morajo priti iz out.ExportColumn.");
    Assert(previewPage.Rows <= 2, "Predogled mora upoštevati @Take.");
    Assert(previewPage.Total >= previewPage.Rows, "@TotalCount ne sme biti manjši od vrnjene strani.");

    var published = await ReadWebExportAsync(connection, profileId, onlyPublished: true, take: 1);
    Assert(published.Total <= previewPage.Total,
      "Filter samo objavljeni ne sme razširiti nabora.");
  }

  Console.WriteLine("F7 spletne datoteke: seznam, predogled, varna razresitev imena in registrski izvoz na zahtevo PASS.");
  return 0;
}
finally
{
  // Pospravimo samo to, kar je test ustvaril.
  if (Directory.Exists(sandbox)) Directory.Delete(sandbox, recursive: true);
}

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

static async Task<(IReadOnlyList<string> Columns, int Rows, int Total)> ReadWebExportAsync(
  SqlConnection connection, int profileId, bool onlyPublished, int take)
{
  await using var command = new SqlCommand("intranet.GetWebExportRows", connection)
  {
    CommandType = CommandType.StoredProcedure,
    CommandTimeout = 600,
  };
  command.Parameters.AddWithValue("@OrganizationId", 2);
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
  await using (var reader = await command.ExecuteReaderAsync())
  {
    columns = Enumerable.Range(0, reader.FieldCount).Select(reader.GetName).ToArray();
    while (await reader.ReadAsync()) rows++;
  }
  return (columns, rows, Convert.ToInt32(total.Value));
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
