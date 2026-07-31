using System.Data;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using PIM.XmlMapping;

var sourceCode = Environment.GetEnvironmentVariable("PIM_XML_SOURCE_CODE");
var root = Environment.GetEnvironmentVariable("PIM_XML_ROOT");
var organizationText = Environment.GetEnvironmentVariable("PIM_XML_ORGANIZATION_ID");
var connectionString = ReadConnectionString();
if (string.IsNullOrWhiteSpace(sourceCode) || string.IsNullOrWhiteSpace(root)
  || !int.TryParse(organizationText, out var organizationId) || string.IsNullOrWhiteSpace(connectionString))
{
  Console.Error.WriteLine("Manjkajo PIM_XML_SOURCE_CODE, PIM_XML_ROOT, PIM_XML_ORGANIZATION_ID ali povezava Pim.");
  return 2;
}

var files = Directory.GetFiles(root, "*.xml").OrderBy(path => path, StringComparer.Ordinal).ToArray();
var runId = Guid.NewGuid();
await using (var connection = new SqlConnection(connectionString))
{
  await connection.OpenAsync();
  var entities = await ReadEntitiesAsync(connection, sourceCode, organizationId);
  await InsertRunAsync(connection, runId, organizationId, sourceCode);
  var page = 0;
  foreach (var file in files)
  {
    var payload = await File.ReadAllTextAsync(file);
    foreach (var entity in entities)
    {
      await InsertInboxAsync(connection, runId, organizationId, sourceCode, entity, ++page, payload);
    }
  }
}
await new SqlMappingPipeline(connectionString).ExtractAndApplyAsync(runId, organizationId, sourceCode);
Console.WriteLine($"Generični XML zajem je končan; datotek={files.Length}, RunId={runId}.");
return 0;

static string? ReadConnectionString()
{
  var value = Environment.GetEnvironmentVariable("PIM_CONNECTION_STRING");
  if (!string.IsNullOrWhiteSpace(value)) return value;
  var path = Path.Combine(Directory.GetCurrentDirectory(), "appsettings.Local.json");
  if (!File.Exists(path)) return null;
  using var document = JsonDocument.Parse(File.ReadAllText(path));
  return document.RootElement.GetProperty("ConnectionStrings").GetProperty("Pim").GetString();
}
static async Task<string[]> ReadEntitiesAsync(SqlConnection connection, string sourceCode, int organizationId)
{
  await using var command = new SqlCommand("""
    SELECT entityMapping.EntityType FROM map.EntityMapping entityMapping
    INNER JOIN map.SourceConnector connector ON connector.SourceConnectorId=entityMapping.SourceConnectorId
    WHERE connector.SourceCode=@SourceCode AND connector.OrganizationId=@OrganizationId
      AND connector.IsActive=1 AND entityMapping.IsActive=1 ORDER BY entityMapping.EntityType;
    """, connection);
  command.Parameters.AddWithValue("@SourceCode", sourceCode);
  command.Parameters.AddWithValue("@OrganizationId", organizationId);
  await using var reader = await command.ExecuteReaderAsync();
  var values = new List<string>();
  while (await reader.ReadAsync()) values.Add(reader.GetString(0));
  return values.ToArray();
}
static async Task InsertRunAsync(SqlConnection connection, Guid runId, int organizationId, string sourceCode)
{
  await using var command = new SqlCommand("""
    INSERT ops.PipelineRun(RunId,Pipeline,OrganizationId,SourceCode,Status)
    VALUES(@RunId,N'GENERIC_XML',@OrganizationId,@SourceCode,N'Running');
    """, connection);
  command.Parameters.AddWithValue("@RunId", runId);
  command.Parameters.AddWithValue("@OrganizationId", organizationId);
  command.Parameters.AddWithValue("@SourceCode", sourceCode);
  await command.ExecuteNonQueryAsync();
}
static async Task InsertInboxAsync(SqlConnection connection, Guid runId, int organizationId, string sourceCode, string entityType, int page, string payload)
{
  var hash = Convert.ToHexString(SHA256.HashData(Encoding.Unicode.GetBytes(payload)));
  await using var command = new SqlCommand("""
    INSERT raw.Inbox(RunId,OrganizationId,SourceCode,EntityType,PageNumber,PayloadXml,PayloadHash,Status)
    VALUES(@RunId,@OrganizationId,@SourceCode,@EntityType,@PageNumber,@PayloadXml,@PayloadHash,N'Pending');
    """, connection);
  command.Parameters.AddWithValue("@RunId", runId);
  command.Parameters.AddWithValue("@OrganizationId", organizationId);
  command.Parameters.AddWithValue("@SourceCode", sourceCode);
  command.Parameters.AddWithValue("@EntityType", entityType);
  command.Parameters.AddWithValue("@PageNumber", page);
  command.Parameters.Add("@PayloadXml", SqlDbType.NVarChar, -1).Value = payload;
  command.Parameters.AddWithValue("@PayloadHash", hash);
  await command.ExecuteNonQueryAsync();
}
