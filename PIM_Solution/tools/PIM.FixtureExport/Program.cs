using System.Text;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using PIM.KatalogWorker;

// Varno, izključno bralno orodje: iz PIM_test.raw_history.ApiResponses izvozi surove ResponseBody
// za natanko pet dovoljenih F3 SAOP končnih točk organizacije 2 (IQLighting) v fixtures/saop/iqlighting.
// Nikoli ne piše v izvorno bazo, nikoli ne bere drugih organizacij ali končnih točk (NW ni med njimi),
// in ResponseBody zapiše dobesedno — brez "popravljanja" ali skrajševanja.

const int OrganizationId = 2;

// (ime mape fixture / F3 endpoint, EndpointKey v raw_history.ApiResponses) — glej SaopCatalogWorker.EndpointKeys.
var endpoints = new (string Folder, string EndpointKey)[]
{
  ("ItemGeneralData", "GetItemsGeneralData"),
  ("Prices", "GetPrices"),
  ("Descriptions", "GetItemsDescriptions"),
  ("Currencies", "Currencies"),
  ("PriceLists", "PriceLists"),
};

var connectionString = LocalConfiguration.GetConnectionString("PIM_TEST_CONNECTION_STRING", "PimTest");
if (string.IsNullOrWhiteSpace(connectionString))
{
  Console.Error.WriteLine("Manjka PIM_TEST_CONNECTION_STRING oziroma ConnectionStrings:PimTest v appsettings.Local.json (povezava na izvorno bazo PIM_test, ki vsebuje raw_history.ApiResponses).");
  Console.Error.WriteLine("To NI PIM_CONNECTION_STRING — ta kaže na ciljno bazo PIM, ne na izvorno zgodovino SAOP odgovorov.");
  return 2;
}

var fixtureRoot = Environment.GetEnvironmentVariable("PIM_SAOP_FIXTURE_ROOT") ?? ResolveDefaultFixtureRoot();
Directory.CreateDirectory(fixtureRoot);

await using var connection = new SqlConnection(connectionString);
await connection.OpenAsync();

await using (var dbNameCommand = new SqlCommand("SELECT DB_NAME();", connection))
{
  var databaseName = (string?)await dbNameCommand.ExecuteScalarAsync();
  Console.WriteLine($"Povezan na bazo: {databaseName}. OrganizationId={OrganizationId} (samo branje).");
}

var manifestEndpoints = new List<FixtureManifestEndpointDocument>();
var failures = new List<string>();

foreach (var (folder, endpointKey) in endpoints)
{
  var picked = await FindCompleteRunAsync(connection, OrganizationId, endpointKey);
  if (picked is null)
  {
    failures.Add($"{folder} ({endpointKey}): ni najti enega samega RunId z zaporednimi stranmi (Page 1..N, HttpStatusCode=200) za OrganizationId={OrganizationId}.");
    continue;
  }

  var (runId, ingestedAtUtc) = picked.Value;
  var pages = await ReadRunPagesAsync(connection, OrganizationId, endpointKey, runId);
  if (pages.Count == 0)
  {
    failures.Add($"{folder} ({endpointKey}): izbrani RunId {runId} nima nobene strani ob dejanskem branju.");
    continue;
  }

  var endpointDirectory = Path.Combine(fixtureRoot, folder);
  Directory.CreateDirectory(endpointDirectory);
  foreach (var staleFile in Directory.EnumerateFiles(endpointDirectory, "page-*.xml"))
  {
    File.Delete(staleFile);
  }

  var pageDocuments = new List<FixtureManifestPageDocument>();
  foreach (var page in pages)
  {
    var fileName = $"page-{page.Page:000}.xml";
    // Dobesedno, brez BOM in brez kakršnegakoli "popravljanja" — natanko ResponseBody iz baze.
    await File.WriteAllTextAsync(Path.Combine(endpointDirectory, fileName), page.ResponseBody, new UTF8Encoding(false));
    pageDocuments.Add(new FixtureManifestPageDocument { Page = page.Page, FileName = fileName, ResponseHash = page.ResponseHash });
  }

  manifestEndpoints.Add(new FixtureManifestEndpointDocument
  {
    Endpoint = folder,
    EndpointKey = endpointKey,
    RunId = runId,
    IngestedAtUtc = ingestedAtUtc.ToString("O"),
    Pages = pageDocuments,
  });

  Console.WriteLine($"{folder,-16} <- {endpointKey,-22} RunId={runId} strani={pages.Count} zajeto={ingestedAtUtc:O}");
}

if (failures.Count > 0)
{
  Console.Error.WriteLine("Izvoz NI uspel za vse končne točke:");
  foreach (var failure in failures) Console.Error.WriteLine("- " + failure);
  Console.Error.WriteLine("Fixture ni bila delno prepisana za neuspele končne točke; obstoječe datoteke te končne točke ostanejo nespremenjene.");
  return 1;
}

var manifestDocument = new FixtureManifestDocument
{
  GeneratedUtc = DateTime.UtcNow.ToString("O"),
  SourceOrganizationId = OrganizationId,
  SourceOrganizationName = "IQLighting",
  Note = "Ustvarjeno s tools/PIM.FixtureExport iz PIM_test.raw_history.ApiResponses (dobeseden ResponseBody, brez popravkov).",
  Endpoints = manifestEndpoints,
};

var manifestPath = Path.Combine(fixtureRoot, "manifest.json");
await using (var manifestStream = File.Create(manifestPath))
{
  await JsonSerializer.SerializeAsync(manifestStream, manifestDocument, new JsonSerializerOptions { WriteIndented = true });
}

Console.WriteLine($"Manifest zapisan: {manifestPath}");
return 0;

static string ResolveDefaultFixtureRoot()
{
  var current = new DirectoryInfo(Directory.GetCurrentDirectory());
  while (current is not null)
  {
    var candidate = Path.Combine(current.FullName, "sql", "migrations");
    if (Directory.Exists(candidate))
    {
      return Path.Combine(current.FullName, "fixtures", "saop", "iqlighting");
    }

    current = current.Parent;
  }

  return Path.Combine(Directory.GetCurrentDirectory(), "fixtures", "saop", "iqlighting");
}

static async Task<(string RunId, DateTime IngestedAtUtc)?> FindCompleteRunAsync(SqlConnection connection, int organizationId, string endpointKey)
{
  const string sql = """
    ;WITH Dedup AS
    (
      SELECT RunId, Page, ResponseBody, IngestedAtUtc,
             ROW_NUMBER() OVER (PARTITION BY RunId, Page ORDER BY IngestedAtUtc DESC, Id DESC) AS rn
      FROM raw_history.ApiResponses
      WHERE OrganizationId = @OrganizationId AND EndpointKey = @EndpointKey AND HttpStatusCode = 200
    ),
    RunPages AS
    (
      SELECT RunId, MIN(Page) AS MinPage, MAX(Page) AS MaxPage, COUNT(*) AS PageCount,
             SUM(CASE WHEN LEN(LTRIM(RTRIM(ResponseBody))) > 0 THEN 1 ELSE 0 END) AS NonEmptyPageCount,
             SUM(LEN(ResponseBody)) AS TotalPayloadLength,
             MAX(IngestedAtUtc) AS LastIngestedUtc
      FROM Dedup
      WHERE rn = 1
      GROUP BY RunId
    )
    SELECT TOP (1) RunId, LastIngestedUtc
    FROM RunPages
    WHERE MinPage = 1 AND PageCount = MaxPage AND NonEmptyPageCount > 0
    ORDER BY TotalPayloadLength DESC, LastIngestedUtc DESC;
    """;
  await using var command = new SqlCommand(sql, connection);
  command.Parameters.AddWithValue("@OrganizationId", organizationId);
  command.Parameters.AddWithValue("@EndpointKey", endpointKey);
  await using var reader = await command.ExecuteReaderAsync();
  if (!await reader.ReadAsync()) return null;
  return (reader.GetString(0), reader.GetDateTime(1));
}

static async Task<IReadOnlyList<(int Page, string ResponseBody, string? ResponseHash)>> ReadRunPagesAsync(
  SqlConnection connection, int organizationId, string endpointKey, string runId)
{
  const string sql = """
    ;WITH Dedup AS
    (
      SELECT Page, ResponseBody, ResponseHash,
             ROW_NUMBER() OVER (PARTITION BY Page ORDER BY IngestedAtUtc DESC, Id DESC) AS rn
      FROM raw_history.ApiResponses
      WHERE OrganizationId = @OrganizationId AND EndpointKey = @EndpointKey AND RunId = @RunId AND HttpStatusCode = 200
    )
    SELECT Page, ResponseBody, ResponseHash FROM Dedup WHERE rn = 1 ORDER BY Page;
    """;
  await using var command = new SqlCommand(sql, connection);
  command.Parameters.AddWithValue("@OrganizationId", organizationId);
  command.Parameters.AddWithValue("@EndpointKey", endpointKey);
  command.Parameters.AddWithValue("@RunId", runId);
  await using var reader = await command.ExecuteReaderAsync();
  var pages = new List<(int, string, string?)>();
  while (await reader.ReadAsync())
  {
    pages.Add((reader.GetInt32(0), reader.GetString(1), reader.IsDBNull(2) ? null : reader.GetString(2)));
  }

  return pages;
}
