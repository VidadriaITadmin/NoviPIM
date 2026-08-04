using System.Data;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using PIM.XmlMapping;

if (args.Length != 5 || args[0] != "--apply" || args[1] != "--run-id" || args[3] != "--source-code"
  || !Guid.TryParse(args[2], out var runId)
  || args[4] is not ("SAOP_IQLIGHTING" or "NW_XML"))
{
  Console.Error.WriteLine("Uporaba: --apply --run-id <GUID> --source-code SAOP_IQLIGHTING|NW_XML");
  return 2;
}

var connectionString = ReadPimConnectionString();
if (connectionString is null)
{
  Console.Error.WriteLine("Pim povezava ni nastavljena.");
  return 2;
}

var builder = new SqlConnectionStringBuilder(connectionString);
if (!string.Equals(builder.InitialCatalog, "PIM", StringComparison.OrdinalIgnoreCase)
  || !builder.IntegratedSecurity)
{
  Console.Error.WriteLine("Helper dovoljuje samo Windows Integrated povezavo v bazo PIM.");
  return 2;
}

var sourceCode = args[4];
await new SqlMappingPipeline(builder.ConnectionString).ExtractAndApplyAsync(runId, 2, sourceCode);

await using var connection = new SqlConnection(builder.ConnectionString);
await connection.OpenAsync();
await using var command = new SqlCommand("""
  UPDATE ops.PipelineRun
  SET Status=N'Succeeded', EndedUtc=SYSUTCDATETIME(),
      RowsRead=(SELECT COUNT(*) FROM raw.Inbox WHERE RunId=@RunId),
      RowsSucceeded=(SELECT COUNT(*) FROM raw.Inbox WHERE RunId=@RunId AND Status=N'Processed'),
      RowsFailed=(SELECT COUNT(*) FROM raw.Inbox WHERE RunId=@RunId AND Status=N'Quarantined')
  WHERE RunId=@RunId;

  SELECT
    (SELECT COUNT(*) FROM raw.Inbox WHERE RunId=@RunId) AS RowsRead,
    (SELECT COUNT(*) FROM raw.Inbox WHERE RunId=@RunId AND Status=N'Processed') AS RowsSucceeded,
    (SELECT COUNT(*) FROM raw.Inbox WHERE RunId=@RunId AND Status=N'Quarantined') AS RowsFailed,
    (SELECT COUNT(*) FROM raw.Inbox WHERE RunId=@RunId AND Status=N'Pending') AS RowsPending;
  """, connection);
command.Parameters.Add("@RunId", SqlDbType.UniqueIdentifier).Value = runId;
await using var reader = await command.ExecuteReaderAsync();
if (await reader.ReadAsync())
  Console.WriteLine($"Raw replay je končan: prebrano={reader.GetInt32(0)}, obdelano={reader.GetInt32(1)}, karantena={reader.GetInt32(2)}, pending={reader.GetInt32(3)}.");

return 0;

static string? ReadPimConnectionString()
{
  var environmentValue = Environment.GetEnvironmentVariable("PIM_CONNECTION_STRING");
  if (!string.IsNullOrWhiteSpace(environmentValue)) return environmentValue;

  var path = Path.Combine(Directory.GetCurrentDirectory(), "appsettings.Local.json");
  if (!File.Exists(path)) return null;
  using var document = JsonDocument.Parse(File.ReadAllText(path));
  return document.RootElement.GetProperty("ConnectionStrings").GetProperty("Pim").GetString();
}
