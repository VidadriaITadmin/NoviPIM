using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using PIM.Api;

// Koren rešitve: testi se poganjajo iz PIM_Solution (scripts/run_tests.ps1) ali iz mape projekta.
var root = Directory.GetCurrentDirectory();
while (root is not null && !File.Exists(Path.Combine(root, "PIM.sln"))) root = Path.GetDirectoryName(root);
Expect(root is not null, "Koren rešitve (PIM.sln) ni najden.");
var migrationPath = Directory.GetFiles(Path.Combine(root!, "sql", "migrations"), "287_BralniApi*.sql").SingleOrDefault();
Expect(migrationPath is not null, "Migracija 287_BralniApi*.sql mora obstajati (shema api).");
var sql = File.ReadAllText(migrationPath!).Replace("''", "'");

// Glava vsakega postopka: od CREATE OR ALTER PROCEDURE <ime> do prvega samostojnega AS.
var procedures = Regex.Matches(sql, @"CREATE OR ALTER PROCEDURE (api\.\w+)(.*?)\bAS\s*\n\s*BEGIN", RegexOptions.Singleline)
  .ToDictionary(m => m.Groups[1].Value, m => m.Groups[2].Value, StringComparer.OrdinalIgnoreCase);
Expect(procedures.Count >= 20, $"V 287 pričakujem vsaj 20 postopkov api.*, najdenih {procedures.Count}.");

// ─── Vsaka končna točka kliče obstoječ postopek z obstoječimi parametri ───────────────────────
foreach (var endpoint in Catalog.Endpoints)
{
  Expect(procedures.TryGetValue(endpoint.Procedure, out var header), $"{endpoint.Path}: postopek {endpoint.Procedure} ni v migraciji 287.");
  foreach (var parameter in Catalog.AllParams(endpoint))
    Expect(Regex.IsMatch(header!, Regex.Escape(parameter.Sql) + @"\b", RegexOptions.IgnoreCase),
      $"{endpoint.Path}: parameter {parameter.Sql} ({parameter.Name}) ni parameter postopka {endpoint.Procedure}.");
  if (endpoint.Kind == EndpointKind.Paged)
    Expect(Regex.IsMatch(header!, @"@TotalCount\s+int\s*=\s*NULL\s+OUTPUT", RegexOptions.IgnoreCase),
      $"{endpoint.Path}: stran potrebuje @TotalCount OUTPUT v {endpoint.Procedure}.");
  if (endpoint.Kind == EndpointKind.Detail)
    Expect(endpoint.Sets is { Length: > 1 }, $"{endpoint.Path}: kartica mora imenovati svoje nabore.");
  Expect(endpoint.Path.StartsWith("/api/v1/", StringComparison.Ordinal), $"{endpoint.Path}: poti so pod /api/v1/.");
  Expect(endpoint.Scope.Length == 0 || Catalog.Scopes.Contains(endpoint.Scope), $"{endpoint.Path}: neznano področje {endpoint.Scope}.");
  Expect(Regex.IsMatch(endpoint.Tool, "^[a-z][a-z0-9_]{2,63}$"), $"{endpoint.Path}: ime orodja MCP {endpoint.Tool} ni veljavno.");
}

Expect(Catalog.Endpoints.Select(e => e.Path).Distinct(StringComparer.OrdinalIgnoreCase).Count() == Catalog.Endpoints.Length, "Poti se ne smejo ponoviti.");
Expect(Catalog.Endpoints.Select(e => e.Tool).Distinct().Count() == Catalog.Endpoints.Length, "Imena orodij MCP se ne smejo ponoviti.");

// ─── Parametri z zaprtim seznamom vrednosti: postopek mora poznati vsako vrednost ────────────
foreach (var endpoint in Catalog.Endpoints)
  foreach (var parameter in endpoint.Params.Where(p => p.Values is not null && p.Name is "sort" or "groupBy" or "source" or "role"))
    foreach (var value in parameter.Values!.Where(v => v is not ("itemId" or "dobavitelj" or "skupno" or "ERP")))
      Expect(sql.Contains($"N'{value}'", StringComparison.Ordinal),
        $"{endpoint.Path}: vrednost {parameter.Name}={value} postopek {endpoint.Procedure} ne pozna (manjka N'{value}' v 287).");

// ─── Področja v katalogu = področja, ki jih sprejme api.Admin_CreateClient ───────────────────
foreach (var scope in Catalog.Scopes)
  Expect(Regex.Matches(sql, $"N'{scope}'").Count >= 2, $"Področje {scope} manjka v preverjanju api.Admin_CreateClient / Admin_UpdateClient.");

// ─── Varnost vloge ──────────────────────────────────────────────────────────────────────────
Expect(sql.Contains("GRANT EXECUTE ON SCHEMA::api TO pim_api_reader"), "Vloga pim_api_reader mora dobiti EXECUTE na shemi api.");
foreach (var admin in procedures.Keys.Where(p => p.StartsWith("api.Admin_", StringComparison.OrdinalIgnoreCase)))
  Expect(sql.Contains($"DENY EXECUTE ON OBJECT::{admin} TO pim_api_reader"), $"{admin} mora biti vlogi pim_api_reader prepovedan.");
Expect(!Regex.IsMatch(sql, @"GRANT\s+(SELECT|INSERT|UPDATE|DELETE)\b[^;]*TO\s+pim_api_reader", RegexOptions.IgnoreCase),
  "Vloga pim_api_reader ne sme dobiti neposrednih pravic na tabele.");
Expect(!Regex.IsMatch(sql, @"sp_executesql|EXEC\s*\(\s*@", RegexOptions.IgnoreCase),
  "Postopki api.* ne smejo uporabljati dinamičnega SQL (prekine verigo lastništva in odpre vbrizgavanje).");

// ─── MCP (/mcp): protokol brez baze in brez strežnika ─────────────────────────────────────────
var toolCalls = new List<(string Tool, Dictionary<string, string?> Input)>();
McpToolRunner fakeRunner = (endpoint, input, _) =>
{
  toolCalls.Add((endpoint.Tool, input));
  return Task.FromResult(new McpToolResult("{\"organizationId\":2,\"count\":0,\"items\":[]}", false));
};
Func<string, bool> allScopes = _ => true;
Func<string, bool> onlyProducts = scope => scope is "" or "izdelki";
const string guide = "NAVODILA";

async Task<McpReply> Mcp(string body, Func<string, bool>? scopes = null) =>
  await McpProtocol.HandleAsync(new MemoryStream(Encoding.UTF8.GetBytes(body)), scopes ?? allScopes, guide, fakeRunner, CancellationToken.None);

// initialize: dogovorjena različica, zmožnost orodij, navodila za AI, ime strežnika.
var init = await Mcp("""{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}""");
Expect(init.Status == 200 && init.Body?["result"] is JsonObject, "MCP initialize mora vrniti result.");
Expect((string?)init.Body!["result"]!["protocolVersion"] == "2025-03-26", "MCP initialize mora sprejeti podprto različico odjemalca (2025-03-26).");
Expect(init.Body["result"]!["capabilities"]?["tools"] is JsonObject, "MCP initialize mora napovedati orodja (capabilities.tools).");
Expect((string?)init.Body["result"]!["instructions"] == guide, "MCP initialize mora vrniti navodila za AI (instructions).");
Expect((string?)init.Body["result"]!["serverInfo"]?["name"] == "pim-api", "MCP serverInfo.name mora biti pim-api.");
Expect((int?)init.Body["id"] == 1 && (string?)init.Body["jsonrpc"] == "2.0", "MCP odgovor mora ponoviti id in jsonrpc 2.0.");
var unknownVersion = await Mcp("""{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"1999-01-01"}}""");
Expect((string?)unknownVersion.Body!["result"]!["protocolVersion"] == McpProtocol.SupportedVersions[0], "Neznana različica: strežnik ponudi svojo privzeto.");
Expect((string?)unknownVersion.Body["id"] == "a", "MCP id je lahko tudi besedilo in se mora vrniti nespremenjen.");

// Obvestilo (brez id) nima odgovora: 202 brez telesa.
var notification = await Mcp("""{"jsonrpc":"2.0","method":"notifications/initialized"}""");
Expect(notification.Status == 202 && notification.Body is null, "MCP obvestilo brez id mora vrniti 202 brez telesa.");

// ping
var ping = await Mcp("""{"jsonrpc":"2.0","id":2,"method":"ping"}""");
Expect(ping.Body?["result"] is JsonObject, "MCP ping mora vrniti prazen result.");

// tools/list: vsa orodja kataloga, vsa samo za branje, s shemo vhodov.
var list = await Mcp("""{"jsonrpc":"2.0","id":3,"method":"tools/list"}""");
var tools = list.Body?["result"]?["tools"] as JsonArray;
Expect(tools is not null && tools.Count == Catalog.Endpoints.Length, $"MCP tools/list mora vrniti vseh {Catalog.Endpoints.Length} orodij kataloga, vrnil {tools?.Count}.");
foreach (var tool in tools!)
{
  var toolName = (string?)tool!["name"];
  Expect(Catalog.ByTool(toolName ?? "") is not null, $"MCP orodje {toolName} ni v katalogu.");
  Expect((bool?)tool["annotations"]?["readOnlyHint"] == true, $"MCP orodje {toolName} mora imeti readOnlyHint=true (API samo bere).");
  Expect((string?)tool["inputSchema"]?["type"] == "object", $"MCP orodje {toolName} mora imeti inputSchema tipa object.");
  Expect(!string.IsNullOrWhiteSpace((string?)tool["description"]), $"MCP orodje {toolName} mora imeti opis.");
}
var detailToolName = Catalog.Endpoints.First(e => e.Kind == EndpointKind.Detail).Tool;
var detailTool = tools.First(t => (string?)t!["name"] == detailToolName)!;
Expect(detailTool["inputSchema"]?["properties"]?["organizationId"] is JsonObject, "MCP kartica izdelka mora imeti parameter organizationId.");

// Ključ z enim področjem vidi samo orodja tega področja (in splošna).
var limited = await Mcp("""{"jsonrpc":"2.0","id":4,"method":"tools/list"}""", onlyProducts);
var limitedNames = ((JsonArray)limited.Body!["result"]!["tools"]!).Select(t => (string)t!["name"]!).ToHashSet();
var expectedNames = Catalog.Endpoints.Where(e => e.Scope is "" or "izdelki").Select(e => e.Tool).ToHashSet();
Expect(limitedNames.SetEquals(expectedNames), "MCP tools/list mora skriti orodja izven področij ključa.");
Expect(!limitedNames.Any(n => Catalog.ByTool(n)!.Scope == "stranke"), "Ključ brez področja stranke ne sme videti orodij strank.");

// tools/call: argumenti (števila, besedilo) pridejo do izvajalca kot besedilo.
var searchTool = Catalog.Endpoints.First(e => e.Kind == EndpointKind.Paged && e.Scope == "izdelki").Tool;
var call = await Mcp("{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"" + searchTool
  + "\",\"arguments\":{\"organizationId\":2,\"search\":\"svetilka\",\"take\":2}}}");
Expect(call.Status == 200 && (bool?)call.Body?["result"]?["isError"] == false, "MCP tools/call mora vrniti result z isError=false.");
Expect((string?)call.Body!["result"]!["content"]?[0]?["type"] == "text", "MCP tools/call vrne vsebino tipa text.");
Expect(toolCalls.Count == 1 && toolCalls[0].Tool == searchTool, "MCP tools/call mora poklicati izvajalca za pravo orodje.");
Expect(toolCalls[0].Input["organizationId"] == "2" && toolCalls[0].Input["search"] == "svetilka" && toolCalls[0].Input["TAKE"] == "2",
  "MCP argumenti morajo priti do izvajalca kot besedilo (ime ne loči velikih črk).");

// Napaka izvajalca (npr. brez področja) je rezultat orodja z isError, ne napaka protokola.
McpToolRunner failing = (_, _, _) => Task.FromResult(new McpToolResult("Ključ nima področja »stranke«.", true));
var denied = await McpProtocol.HandleAsync(JsonNode.Parse("""{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"list_organizations"}}"""),
  allScopes, guide, failing, CancellationToken.None);
Expect((bool?)denied.Body?["result"]?["isError"] == true, "Zavrnjeno orodje mora vrniti isError=true.");

// Napake protokola.
var unknownTool = await Mcp("""{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"delete_everything"}}""");
Expect((int?)unknownTool.Body?["error"]?["code"] == McpProtocol.InvalidParams, "Neznano orodje mora vrniti napako -32602.");
var unknownMethod = await Mcp("""{"jsonrpc":"2.0","id":8,"method":"resources/list"}""");
Expect((int?)unknownMethod.Body?["error"]?["code"] == McpProtocol.MethodNotFound, "Nepodprta metoda mora vrniti napako -32601.");
var broken = await Mcp("{ to ni json");
Expect(broken.Status == 400 && (int?)broken.Body?["error"]?["code"] == McpProtocol.ParseError, "Neveljaven JSON mora vrniti 400 in -32700.");
var batch = await Mcp("""[{"jsonrpc":"2.0","id":9,"method":"ping"}]""");
Expect(batch.Status == 400 && (int?)batch.Body?["error"]?["code"] == McpProtocol.InvalidRequest, "Seznam zahtevkov (paket) mora vrniti 400 in -32600, ne izjeme.");
var numericMethod = await Mcp("""{"jsonrpc":"2.0","id":10,"method":42}""");
Expect((int?)numericMethod.Body?["error"]?["code"] == McpProtocol.InvalidRequest, "method, ki ni besedilo, mora vrniti -32600, ne izjeme.");
Expect(toolCalls.Count == 1, "Napačni zahtevki ne smejo klicati baze.");

// Navodila za AI povedo, kje je merodajna kakovost podatkov.
Expect(ApiDocs.Guide("http://x").Contains("nabor `validation`", StringComparison.Ordinal), "Navodila za AI morajo povedati, da je merodajen nabor validation na kartici.");

Console.WriteLine($"PIM.F12.ApiContractTests: OK ({Catalog.Endpoints.Length} končnih točk, {procedures.Count} postopkov, MCP OK).");
return 0;

static void Expect(bool condition, string message)
{
  if (condition) return;
  Console.Error.WriteLine("NAPAKA: " + message);
  Environment.Exit(1);
}
