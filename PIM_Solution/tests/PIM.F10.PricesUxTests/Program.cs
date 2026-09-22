using System.Data;
using System.Text.RegularExpressions;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using PIM.Intranet.Services;
using PIM.Outbound;

// Pogodbeni test strani /cene (265): cene in ceniki gredo iz PIM v SAOP.
//
// Uporabnik 2026-09-22: »stran Cene naj ima uvoz, izvoz itd. kot izdelki in stranke; omogoci, da se
// cene pisejo v SAOP, in nove cenike«. Pogodba:
//
//   C1  stran ima zavihke Cene po izdelkih / Ceniki / V SAOP, filter podjetja z »vsa podjetja«
//   C2  izvoz /izvoz/cene.xlsx z istim filtrom kot stran, uvoz /cene/uvoz
//   C3  pisalna dejanja so za politiko SaopWrite; nic ne odide brez odobritve (ManualApproval)
//   C4  SAOP za cene in cenike nima PATCH: nova cena AddPrices, sprememba ModifyPricesV2, obe POST
//   C5  krog nad bazo: izvoz -> uvoz brez sprememb = nic; sprememba neto gre v vrsto (ne v canon), suhi
//       tek posiljatelja sestavi ItemPrice za ModifyPricesV2; nov cenik gre pred svojimi cenami, cena
//       zanj pocaka, dokler cenik ne odide. Test v SAOP ne poslje nicesar in za sabo pobrise vse.

var root = FindRoot();
var pages = Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages");
var markup = File.ReadAllText(Path.Combine(pages, "Prices.razor"));
var import = File.ReadAllText(Path.Combine(pages, "PriceImport.razor"));
var program = File.ReadAllText(Path.Combine(root, "src", "PIM.Intranet", "Program.cs"));
var access = File.ReadAllText(Path.Combine(root, "src", "PIM.Intranet", "Services", "PimAccessCatalog.cs"));

/* --- C1: zavihki in filtri ---------------------------------------------------------------- */
Assert(markup.Contains("@page \"/cene\"", StringComparison.Ordinal), "Pot /cene se ne sme spremeniti.");
foreach (var tab in new[] { "Cene po izdelkih", "Ceniki (", "V SAOP" })
  Assert(markup.Contains(tab, StringComparison.Ordinal), "Manjka zavihek: " + tab);
Assert(markup.Contains("<option value=\"\">Vsa podjetja</option>", StringComparison.Ordinal), "Filter podjetja mora imeti »Vsa podjetja«.");
Assert(markup.Contains("PriceData.GetProductsAsync(Query", StringComparison.Ordinal), "Seznam mora brati po istem filtru (PriceQuery) kot izvoz.");

/* --- C2: izvoz in uvoz -------------------------------------------------------------------- */
Assert(markup.Contains("\"izvoz/cene.xlsx\" + (Query.ToQueryString()", StringComparison.Ordinal), "Izvoz mora nositi filtre pogleda.");
Assert(markup.Contains("href=\"cene/uvoz\"", StringComparison.Ordinal), "Stran mora voditi na uvoz.");
Assert(import.Contains("@page \"/cene/uvoz\"", StringComparison.Ordinal), "Uvoz mora biti na /cene/uvoz.");
Assert(program.Contains("app.MapGet(\"/izvoz/cene.xlsx\"", StringComparison.Ordinal), "Manjka izvozna pot /izvoz/cene.xlsx.");
Assert(program.Contains("PriceQuery.FromQuery(", StringComparison.Ordinal), "Izvoz mora brati isti filter kot stran.");
Assert(access.Contains("path == \"cene/uvoz\"", StringComparison.Ordinal), "Uvoz cen mora imeti isto dovoljenje strani kot /cene.");

/* --- C3: pisanje samo s SaopWrite ---------------------------------------------------------- */
Assert(Regex.Matches(markup, "<AuthorizeView Policy=\"@PimPolicies.SaopWrite\">").Count >= 3,
  "Urejanje cene, nov cenik in odobritev morajo biti za politiko SaopWrite.");
Assert(import.Contains("<AuthorizeView Policy=\"@PimPolicies.SaopWrite\">", StringComparison.Ordinal), "Uvrstitev uvoza v vrsto mora biti za SaopWrite.");

/* --- C4: oblike dokumentov ----------------------------------------------------------------- */
var price = SaopKnownShapes.Price;
Assert(price.AddPath == "api/Price/AddPrices" && price.AddOperation == "POST", "Nova cena gre s POST api/Price/AddPrices.");
Assert(price.UpdatePath == "api/V2/Price/ModifyPricesV2" && price.UpdateOperation == "POST", "Sprememba cene gre s POST api/V2/Price/ModifyPricesV2 (PATCH-a ni).");
Assert(SaopKnownShapes.PriceList.AddOperation == "POST" && SaopKnownShapes.PriceList.UpdateOperation == "POST", "Cenik gre s POST.");

var query = PriceQuery.FromQuery(name => name switch { "podjetje" => "3", "cenik" => "B2C", "isci" => "14V", "vrsta" => "QUEUED", _ => null });
Assert(query == new PriceQuery(3, "B2C", "14V", 1, "QUEUED"), "Filter iz poizvedbe se ne prebere pravilno.");
Assert(PriceQuery.FromQuery(name => query.ToQueryString().Split('&').Select(part => part.Split('='))
  .Where(part => part[0] == name).Select(part => Uri.UnescapeDataString(part[1])).FirstOrDefault()) == query,
  "Filter mora preživeti pot v povezavo in nazaj.");

Console.WriteLine("F10 prices UX contract PASS.");

var connectionString = Environment.GetEnvironmentVariable("PIM_CONNECTION_STRING") ?? LocalConnectionString(root);
if (!string.IsNullOrWhiteSpace(connectionString))
{
  await RoundTripAsync(connectionString);
  Console.WriteLine("F10 prices DB round trip PASS.");
}
else Console.WriteLine("F10 prices: povezave na bazo ni, krog nad bazo je preskočen.");

/* --- C5 nad bazo -------------------------------------------------------------------------- */
static async Task RoundTripAsync(string connectionString)
{
  const string Actor = "test-f10-cene";
  const int Organization = 3; // Vidadria: ceniki B2B in B2C
  const string NewList = "PIMTEST265";
  var configuration = new ConfigurationBuilder()
    .AddInMemoryCollection(new Dictionary<string, string?> { ["ConnectionStrings:Pim"] = connectionString })
    .Build();
  var guard = PimWriteGuard.Trusted("test F10 cene");
  var prices = new PriceService(configuration, guard, new PriceSendJobs(NullLogger<PriceSendJobs>.Instance));
  var workbook = new PriceWorkbookService(prices, new IntranetDataService(configuration, guard));

  await using var connection = new SqlConnection(connectionString);
  await connection.OpenAsync();
  var firstMessage = await ScalarAsync(connection, "SELECT ISNULL(MAX(OutboxMessageId), 0) FROM out.OutboxMessage;");
  var firstBatch = await ScalarAsync(connection, "SELECT ISNULL(MAX(OutboundBatchId), 0) FROM out.OutboundBatch;");
  var output = Path.Combine(Path.GetTempPath(), "pim-f10-cene-" + Guid.NewGuid().ToString("N"));

  try
  {
    // Cena brez česar v vrsti, z ne-nično ceno.
    var line = (await prices.GetLinesAsync(new PriceQuery(Organization, "B2C", null)))
      .First(candidate => candidate.QueueStatus is null && candidate.Net is > 1 && candidate.VatRate is not null);

    // 1. Izvoz, vrnjen brez sprememb: nič.
    var clean = await workbook.PreviewAsync(new MemoryStream(PriceWorkbookService.Build([line])), null);
    Assert(clean.RowsRead == 1 && clean.Rows.Count == 0 && clean.Problems.Count == 0 && clean.UnknownColumns.Count == 0,
      $"Nespremenjen izvoz ne sme ničesar spremeniti (sprememb {clean.Rows.Count}, napak {string.Join("; ", clean.Problems)}, neznanih {string.Join(", ", clean.UnknownColumns)}).");

    // 2. Neto +1: ena sprememba, v vrsto, ne v canon.
    var newNet = line.Net!.Value + 1;
    var edited = await workbook.PreviewAsync(new MemoryStream(PriceWorkbookService.Build([line with { Net = newNet }])), null);
    Assert(edited.Rows.Count == 1 && edited.Rows[0].NewNet == newNet && edited.Rows[0].OldNet == line.Net && !edited.Rows[0].IsNew,
      "Sprememba neto mora biti ena sprememba obstoječe cene.");
    var outcome = await workbook.ApplyAsync(edited, Actor, "test.xlsx");
    Assert(outcome.Queued == 1 && outcome.Batches.Single().BatchId is not null, "Sprememba mora iti v vrsto kot ena cena v eni seriji.");
    var batchId = outcome.Batches.Single().BatchId!.Value;

    var overlay = (await prices.GetProductLinesAsync(line.ProductId)).Single(candidate => candidate.PriceList == "B2C");
    Assert(overlay.Net == line.Net && overlay.QueuedNet == newNet && overlay.QueueStatus == "PendingApproval",
      "Stara cena ostane (SAOP je vir), nova je vidna kot »čaka odobritev«.");

    // Ponovni uvoz iste datoteke: dvojnik, nova serija ne nastane.
    var again = await workbook.ApplyAsync(await workbook.PreviewAsync(new MemoryStream(PriceWorkbookService.Build([line with { Net = newNet }])), null), Actor, null);
    Assert(again.Queued == 0 && again.Duplicates == 1, "Ista sprememba, ki že čaka, ne sme nastati znova.");

    // 3. Odobritev + suhi tek: ItemPrice za ModifyPricesV2 z vsemi polji cene.
    await ExecuteAsync(connection, "EXEC out.ApproveOutboundBatch @Id, N'test-f10-cene';", batchId);
    var run = await new SaopDocumentRunner(connectionString, "test-f10-cene",
      new SaopDocumentRunOptions("SAOP_PRICE", DryRun: true, OutputDirectory: output, MaxDocuments: 500, OrganizationId: Organization)).RunAsync();
    var key = $"B2C|{line.ItemId}";
    Assert(run.Notes.Any(note => note.StartsWith(key + ":", StringComparison.Ordinal) && note.Contains("POST api/V2/Price/ModifyPricesV2", StringComparison.Ordinal)),
      "Suhi tek mora obstoječo ceno poslati s POST api/V2/Price/ModifyPricesV2: " + string.Join(" | ", run.Notes));
    var xml = File.ReadAllText(Directory.GetFiles(output, "*.xml").Single(file => Path.GetFileName(file).StartsWith("B2C_" + Safe(line.ItemId) + ".POST.Update", StringComparison.Ordinal)));
    foreach (var element in new[] { "<ItemPrice>", "<PriceListId>B2C</PriceListId>", $"<ItemCode>{line.ItemId}</ItemCode>",
      $"<Price>{newNet:F4}</Price>".Replace(',', '.'), "<VATRate>", "<Active>true</Active>" })
      Assert(xml.Contains(element, StringComparison.Ordinal), $"Dokument cene nima {element}:\n{xml}");

    // 4. Nov cenik s ceno v isti seriji: cenik gre kot AddPriceLists, cena zanj počaka.
    var (listBatch, operation) = await prices.EnqueuePriceListAsync(Organization, NewList, "Testni cenik F10", null, false, true, Actor);
    Assert(operation == "ADD" && listBatch is not null, "Nov cenik mora iti kot nov (AddPriceLists).");
    var listPrice = await prices.EnqueueAsync(Organization, [new PriceChange(NewList, line.ItemId, 12.34m, 22m)], Actor, "BULK", null, listBatch);
    Assert(listPrice.Queued == 1 && listPrice.BatchId == listBatch && listPrice.Rows[0].Intent == "ADD", "Cena novega cenika gre v isto serijo kot nova cena.");
    var lists = await prices.GetPriceListsAsync(Organization);
    Assert(lists.Any(list => list.Code == NewList && !list.InSaop && list.QueueStatus == "PendingApproval" && list.QueuedPrices == 1),
      "Nov cenik mora biti na seznamu cenikov kot »ni v SAOP, čaka odobritev« z eno ceno v vrsti.");

    await ExecuteAsync(connection, "EXEC out.ApproveOutboundBatch @Id, N'test-f10-cene';", listBatch!.Value);
    var claimed = await ScalarAsync(connection,
      $"EXEC out.ClaimSaopDocument @WorkerId = N'test-f10-cene', @TargetKind = N'SAOP_PRICE', @OrganizationId = {Organization}, @EntityKey = N'{NewList}|{line.ItemId.Replace("'", "''")}'; SELECT CONVERT(bigint, COUNT(*)) FROM out.OutboxMessage WHERE Status = N'Sending' AND LeaseOwner = N'test-f10-cene';");
    Assert(claimed == 0, "Cena za cenik, ki ga SAOP še ne pozna, se ne sme prevzeti.");

    var listRun = await new SaopDocumentRunner(connectionString, "test-f10-cene",
      new SaopDocumentRunOptions("SAOP_PRICELIST", DryRun: true, OutputDirectory: output, MaxDocuments: 50, OrganizationId: Organization)).RunAsync();
    Assert(listRun.Notes.Any(note => note.StartsWith(NewList + ":", StringComparison.Ordinal) && note.Contains("POST api/pricelists/AddPriceLists", StringComparison.Ordinal)),
      "Nov cenik gre s POST api/pricelists/AddPriceLists: " + string.Join(" | ", listRun.Notes));
    var listXml = File.ReadAllText(Directory.GetFiles(output, NewList + ".POST.Add.xml").Single());
    foreach (var element in new[] { "<PriceList>", $"<PriceListId>{NewList}</PriceListId>", "<PriceListDescription>Testni cenik F10</PriceListDescription>", "<CurrencyId>978</CurrencyId>", "<Active>true</Active>" })
      Assert(listXml.Contains(element, StringComparison.Ordinal), $"Dokument cenika nima {element}:\n{listXml}");
  }
  finally
  {
    // Pospravljanje: samo sporočila in serije, ki jih je ustvaril ta test.
    const string Mine = "message.OutboxMessageId > @First AND message.CreatedBy = N'test-f10-cene'";
    await ExecuteAsync(connection, $"DELETE event FROM ops.OutboundEvent AS event INNER JOIN out.OutboxMessage AS message ON message.OutboxMessageId = event.OutboxMessageId WHERE {Mine};", firstMessage);
    await ExecuteAsync(connection, $"DELETE attempt FROM out.OutboxAttempt AS attempt INNER JOIN out.OutboxMessage AS message ON message.OutboxMessageId = attempt.OutboxMessageId WHERE {Mine};", firstMessage);
    await ExecuteAsync(connection, $"DELETE message FROM out.OutboxMessage AS message WHERE {Mine};", firstMessage);
    await ExecuteAsync(connection, "DELETE FROM out.OutboundBatch WHERE OutboundBatchId > @First AND CreatedBy = N'test-f10-cene';", firstBatch);
    if (Directory.Exists(output)) Directory.Delete(output, recursive: true);
  }
}

static string Safe(string value) => string.Concat(value.Select(character => Path.GetInvalidFileNameChars().Contains(character) ? '_' : character));

static async Task<long> ScalarAsync(SqlConnection connection, string sql)
{
  await using var command = new SqlCommand(sql, connection);
  return Convert.ToInt64(await command.ExecuteScalarAsync());
}

static async Task ExecuteAsync(SqlConnection connection, string sql, long id)
{
  await using var command = new SqlCommand(sql.Replace("@Id", "@First"), connection);
  command.Parameters.Add("@First", SqlDbType.BigInt).Value = id;
  await command.ExecuteNonQueryAsync();
}

static void Assert(bool condition, string message)
{
  if (!condition) throw new InvalidOperationException(message);
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

static string? LocalConnectionString(string root)
{
  foreach (var candidate in new[] { Path.Combine(root, "appsettings.Local.json"), Path.Combine(root, "..", "appsettings.Local.json") })
  {
    if (!File.Exists(candidate)) continue;
    var match = Regex.Match(File.ReadAllText(candidate), "\"Pim\"\\s*:\\s*\"([^\"]+)\"");
    if (match.Success) return match.Groups[1].Value;
  }
  return null;
}
