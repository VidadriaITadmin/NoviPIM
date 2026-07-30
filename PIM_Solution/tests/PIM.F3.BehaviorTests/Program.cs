using System.Net;
using System.Xml.Linq;
using PIM.KatalogWorker;

var currentDirectory = Directory.GetCurrentDirectory();
var root = Environment.GetEnvironmentVariable("PIM_SOLUTION_ROOT")
  ?? (Directory.Exists(Path.Combine(currentDirectory, "sql", "migrations"))
    ? currentDirectory
    : Path.GetFullPath("../..", currentDirectory));
var fixtures = Path.Combine(Path.GetTempPath(), "pim-f3-behavior-fixture");
if (Directory.Exists(fixtures)) Directory.Delete(fixtures, recursive: true);
await CreateFixtureAsync(fixtures);
var endpoints = new[] { "ItemGeneralData", "Prices", "Descriptions", "Currencies", "PriceLists" };

var disabled = SaopSource.Create(new SaopSourceOptions(SaopSourceMode.Disabled, fixtures, null), new HttpClient(new RejectingHandler()));
Assert((await disabled.ReadAsync()).Count == 0, "Disabled mora vrniti nič strani.");

var fixtureHandler = new CountingHandler(_ => throw new InvalidOperationException("Fixture ne sme uporabljati omrežja."));
var fixture = SaopSource.Create(new SaopSourceOptions(SaopSourceMode.Fixture, fixtures, null), new HttpClient(fixtureHandler));
var fixturePages = await fixture.ReadAsync();
Assert(fixturePages.Count == 5, "Fixture mora vrniti natanko pet strani.");
Assert(fixtureHandler.Requests.Count == 0, "Fixture je izvedel omrežni klic.");
Assert(fixturePages.Select(page => page.Endpoint).SequenceEqual(endpoints), "Fixture strani niso v pričakovanem vrstnem redu.");
foreach (var page in fixturePages)
{
  var expectedPath = Path.Combine(fixtures, page.Endpoint, "page-001.xml");
  Assert(page.PayloadXml == await File.ReadAllTextAsync(expectedPath), $"Payload {page.Endpoint} ni ostal surov.");
}

var facts = FixtureFacts.Count(fixturePages);
Assert(facts.GeneralProducts == 25, "Fixture mora vsebovati 25 splošnih izdelkov.");
Assert(facts.Prices == 70, "Fixture mora vsebovati 70 cen.");
Assert(facts.Descriptions == 1, "Fixture mora vsebovati 1 opis.");

var liveHandler = new CountingHandler(request =>
  new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("<root />") });
var live = SaopSource.Create(
  new SaopSourceOptions(SaopSourceMode.Live, fixtures, new Uri("https://saop.test.example/api/")),
  new HttpClient(liveHandler));
var livePages = await live.ReadAsync();
Assert(livePages.Count == 5, "Live mora prebrati pet končnih točk.");
Assert(liveHandler.Requests.Count == 5, "Live mora izvesti pet zahtev.");
Assert(liveHandler.Requests.All(uri => uri.AbsoluteUri.StartsWith("https://saop.test.example/api/", StringComparison.Ordinal)), "Live ne uporablja nastavljenega osnovnega URL-ja.");

await using var command = RawInboxWriter.CreateCommand(
  new Microsoft.Data.SqlClient.SqlConnection(),
  new RawPage("Prices", 1, "<Price><ItemCode>X' OR 1=1--</ItemCode></Price>"),
  Guid.NewGuid(),
  2,
  "SAOP_IQLIGHTING");
Assert(command.CommandText.Contains("@PayloadXml", StringComparison.Ordinal), "Writer ne uporablja parametra @PayloadXml.");
Assert(command.CommandText.Contains("MERGE raw.Inbox", StringComparison.Ordinal), "Writer mora dedup/ponovno vrstitev izvesti z MERGE.");
Assert(command.CommandText.Contains("WHEN NOT MATCHED", StringComparison.Ordinal), "Writer mora vstaviti nov zapis, če ujemajoč hash še ne obstaja.");
Assert(command.CommandText.Contains("WHEN MATCHED AND target.Status = N'Quarantined'", StringComparison.Ordinal), "Writer mora varno vrniti v vrsto samo karantenske zapise z enakim hashem.");
Assert(!command.CommandText.Contains("OR 1=1", StringComparison.Ordinal), "Payload je vstavljen v SQL.");
Assert(command.Parameters.Cast<Microsoft.Data.SqlClient.SqlParameter>().Single(parameter => parameter.ParameterName == "@PayloadXml").Value.ToString()!.Contains("OR 1=1", StringComparison.Ordinal), "Surovi payload ni parameter.");

var requeueUpdateStart = command.CommandText.IndexOf("WHEN MATCHED AND target.Status = N'Quarantined' THEN", StringComparison.Ordinal);
var requeueUpdateEnd = command.CommandText.IndexOf("WHEN NOT MATCHED", StringComparison.Ordinal);
Assert(requeueUpdateStart >= 0 && requeueUpdateEnd > requeueUpdateStart, "Writer nima ločenega bloka za ponovno vrstitev karantenskih zapisov.");
var requeueUpdateClause = command.CommandText[requeueUpdateStart..requeueUpdateEnd];
Assert(!requeueUpdateClause.Contains("PayloadXml", StringComparison.Ordinal), "Ponovna vrstitev ne sme spremeniti surovega PayloadXml.");
Assert(!requeueUpdateClause.Contains("PayloadHash", StringComparison.Ordinal), "Ponovna vrstitev ne sme spremeniti PayloadHash.");
Assert(requeueUpdateClause.Contains("RunId = @RunId", StringComparison.Ordinal), "Ponovna vrstitev mora zapis prenesti na nov RunId.");
Assert(requeueUpdateClause.Contains("Status = N'Pending'", StringComparison.Ordinal), "Ponovna vrstitev mora status vrniti na Pending.");

var workerProgram = await File.ReadAllTextAsync(Path.Combine(root, "workers", "PIM.KatalogWorker", "Program.cs"));
Assert(!workerProgram.Contains("map.RunSaopProducts", StringComparison.Ordinal), "Worker ne sme zaganjati preslikave, validacije ali promocije.");

Console.WriteLine($"F3 vedenjski testi so uspešni: izdelki={facts.GeneralProducts}, cene={facts.Prices}, opisi={facts.Descriptions}.");
Directory.Delete(fixtures, recursive: true);
return;

static async Task CreateFixtureAsync(string fixtureRoot)
{
  var generalRows = string.Concat(Enumerable.Range(1, 25).Select(index =>
    $"<ItemGeneralData><ItemID>TEST-{index:000}</ItemID></ItemGeneralData>"));
  var priceRows = string.Concat(Enumerable.Range(1, 70).Select(index =>
    $"<Price><ItemCode>TEST-{index:000}</ItemCode></Price>"));
  var endpointPayloads = new Dictionary<string, string>
  {
    ["ItemGeneralData"] = $"<ItemsGeneralData>{generalRows}</ItemsGeneralData>",
    ["Prices"] = $"<ArrayOfPrice>{priceRows}</ArrayOfPrice>",
    ["Descriptions"] = "<ItemsDescriptions><itemDescriptions><Descriptions><Description>Opis</Description></Descriptions></itemDescriptions></ItemsDescriptions>",
    ["Currencies"] = "<ArrayOfCurrency />",
    ["PriceLists"] = "<ArrayOfPriceList />"
  };

  foreach (var (endpoint, payload) in endpointPayloads)
  {
    var directory = Path.Combine(fixtureRoot, endpoint);
    Directory.CreateDirectory(directory);
    await File.WriteAllTextAsync(Path.Combine(directory, "page-001.xml"), payload);
  }

  var manifest = """
    {
      "endpoints": [
        { "endpoint": "ItemGeneralData", "pages": [{ "page": 1, "fileName": "page-001.xml" }] },
        { "endpoint": "Prices", "pages": [{ "page": 1, "fileName": "page-001.xml" }] },
        { "endpoint": "Descriptions", "pages": [{ "page": 1, "fileName": "page-001.xml" }] },
        { "endpoint": "Currencies", "pages": [{ "page": 1, "fileName": "page-001.xml" }] },
        { "endpoint": "PriceLists", "pages": [{ "page": 1, "fileName": "page-001.xml" }] }
      ]
    }
    """;
  await File.WriteAllTextAsync(Path.Combine(fixtureRoot, "manifest.json"), manifest);
}

static void Assert(bool condition, string message)
{
  if (!condition) throw new InvalidOperationException(message);
}

sealed class RejectingHandler : HttpMessageHandler
{
  protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
    throw new InvalidOperationException("Omrežni klic ni dovoljen.");
}

sealed class CountingHandler(Func<HttpRequestMessage, HttpResponseMessage> response) : HttpMessageHandler
{
  public List<Uri> Requests { get; } = [];

  protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
  {
    Requests.Add(request.RequestUri!);
    return Task.FromResult(response(request));
  }
}
