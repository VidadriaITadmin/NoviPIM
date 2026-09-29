using System.Text.RegularExpressions;
using PIM.Api;

// Koren rešitve: testi se poganjajo iz PIM_Solution (scripts/run_tests.ps1) ali iz mape projekta.
var root = Directory.GetCurrentDirectory();
while (root is not null && !File.Exists(Path.Combine(root, "PIM.sln"))) root = Path.GetDirectoryName(root);
Expect(root is not null, "Koren rešitve (PIM.sln) ni najden.");
var migrationPath = Directory.GetFiles(Path.Combine(root!, "sql", "migrations"), "287_*.sql").SingleOrDefault();
Expect(migrationPath is not null, "Migracija 287_*.sql mora obstajati (shema api).");
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

Console.WriteLine($"PIM.F12.ApiContractTests: OK ({Catalog.Endpoints.Length} končnih točk, {procedures.Count} postopkov).");
return 0;

static void Expect(bool condition, string message)
{
  if (condition) return;
  Console.Error.WriteLine("NAPAKA: " + message);
  Environment.Exit(1);
}
