using Microsoft.Data.SqlClient;
using PIM.KatalogWorker;
using PIM.XmlMapping;

var modeText = Environment.GetEnvironmentVariable("PIM_SAOP_MODE") ?? "Disabled";
if (!Enum.TryParse<SaopSourceMode>(modeText, true, out var mode))
{
  Console.Error.WriteLine("Neveljaven način vira.");
  return 2;
}

var fixtureRoot = Environment.GetEnvironmentVariable("PIM_SAOP_FIXTURE_ROOT")
  ?? Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", "fixtures", "saop", "iqlighting"));
var baseUrlText = Environment.GetEnvironmentVariable("PIM_SAOP_BASE_URL");
var baseUrl = string.IsNullOrWhiteSpace(baseUrlText) ? null : new Uri(baseUrlText);
using var httpClient = new HttpClient();
ISaopSource source = SaopSource.Create(new SaopSourceOptions(mode, fixtureRoot, baseUrl), httpClient);
var pages = await source.ReadAsync();

if (mode == SaopSourceMode.Disabled)
{
  Console.WriteLine("SAOP zajem je izključen.");
  return 0;
}

var connectionString = LocalConfiguration.GetConnectionString("PIM_CONNECTION_STRING", "Pim");
if (string.IsNullOrWhiteSpace(connectionString))
{
  Console.Error.WriteLine("Manjka PIM_CONNECTION_STRING oziroma ConnectionStrings:Pim v appsettings.Local.json.");
  return 2;
}

var runId = Guid.NewGuid();
await using (var connection = new SqlConnection(connectionString))
{
  await connection.OpenAsync();
  await using var start = new SqlCommand("""
    INSERT ops.PipelineRun (RunId, Pipeline, OrganizationId, SourceCode, Status)
    VALUES (@RunId, N'SAOP_PRODUCTS', 2, N'SAOP_IQLIGHTING', N'Running');
    """, connection);
  start.Parameters.AddWithValue("@RunId", runId);
  await start.ExecuteNonQueryAsync();
}

await new RawInboxWriter(connectionString).WriteAsync(pages, runId, 2, "SAOP_IQLIGHTING");
await new SqlMappingPipeline(connectionString).ExtractAndApplyAsync(runId, 2, "SAOP_IQLIGHTING");
await using (var connection = new SqlConnection(connectionString))
{
  await connection.OpenAsync();
  await using var captured = new SqlCommand("""
    UPDATE ops.PipelineRun
    SET Status = N'Succeeded', EndedUtc = SYSUTCDATETIME(), RowsRead = @RowsRead, RowsSucceeded = @RowsRead
    WHERE RunId = @RunId;
    """, connection);
  captured.Parameters.AddWithValue("@RunId", runId);
  captured.Parameters.AddWithValue("@RowsRead", pages.Count);
  await captured.ExecuteNonQueryAsync();
}

if (mode == SaopSourceMode.Fixture)
{
  var facts = FixtureFacts.Count(pages);
  Console.WriteLine($"Fixture: izdelki={facts.GeneralProducts}, cene={facts.Prices}, opisi={facts.Descriptions}.");
}
else
{
  Console.WriteLine($"Zajetih strani: {pages.Count}.");
}

return 0;
