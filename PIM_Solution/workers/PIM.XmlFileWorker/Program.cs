using System.Data;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using PIM.XmlFileWorker;
using PIM.XmlMapping;
using PIM.Operations;

var sourceCode = Environment.GetEnvironmentVariable("PIM_XML_SOURCE_CODE");
var root = Environment.GetEnvironmentVariable("PIM_XML_ROOT");
var organizationText = Environment.GetEnvironmentVariable("PIM_XML_ORGANIZATION_ID");
var connectionString = ReadConnectionString();

// --map-run <RunId> preslika ze zajet zagon brez ponovnega branja datotek. Isti razlog kot pri
// PIM.KatalogWorker: ko se preslikave dopolnijo, morajo iti iste ze zajete strani skozi novo
// preslikavo. Ponoven zajem iste datoteke bi bil drugi izvod istih 19 MB v raw.Inbox.
Guid? mapRunId = null;
var reprocess = false;
for (var index = 0; index < args.Length; index++)
{
  var isMapRun = args[index].Equals("--map-run", StringComparison.OrdinalIgnoreCase);
  // --znova-preslikaj je isto kot --map-run, le da strani tega zagona najprej postavi nazaj
  // na Pending. Rabi se, ko se preslikave dopolnijo nad ze obdelanim zajemom: iste datoteke
  // ni mogoce zajeti drugic (raw.Inbox je enolicen po vsebini), preslikava pa bere Pending.
  var isReprocess = args[index].Equals("--znova-preslikaj", StringComparison.OrdinalIgnoreCase);
  if (!isMapRun && !isReprocess) continue;
  if (index + 1 >= args.Length || !Guid.TryParse(args[index + 1], out var parsed))
  {
    Console.Error.WriteLine($"{args[index]} potrebuje veljaven RunId.");
    return 2;
  }
  mapRunId = parsed;
  reprocess = isReprocess;
}

if (string.IsNullOrWhiteSpace(connectionString))
{
  Console.Error.WriteLine("Manjka povezava Pim (PIM_CONNECTION_STRING ali appsettings.Local.json).");
  return 2;
}

if (mapRunId is Guid existingRunId)
{
  // Podjetje in vir bereva iz zajetih vrstic, ne iz okolja — zagon je ze zapisan in samo ta
  // vrednost je pravilna. Tako se tudi ne da po pomoti preslikati tujega zagona z drugim virom.
  await using var mapConnection = new SqlConnection(connectionString);
  await mapConnection.OpenAsync();
  var existing = await ReadRunAsync(mapConnection, existingRunId);
  if (existing is null)
  {
    Console.Error.WriteLine($"Zagon {existingRunId} v raw.Inbox ne obstaja.");
    return 2;
  }
  var (existingOrganizationId, existingSourceCode) = existing.Value;
  Console.WriteLine($"Preslikava ze zajetega zagona {existingRunId}; vir={existingSourceCode}, podjetje={existingOrganizationId}.");
  if (reprocess)
  {
    var vrnjenih = await ReopenRunAsync(mapConnection, existingRunId);
    Console.WriteLine($"  Na ponovno preslikavo postavljenih strani: {vrnjenih}. Nic ni pobrisano — preslikava je zdruzevalna.");
  }
  await new SqlMappingPipeline(connectionString).ExtractAndApplyAsync(existingRunId, existingOrganizationId, existingSourceCode);
  await FinishRunAsync(mapConnection, existingRunId);
  foreach (var line in await ReadRunSummaryAsync(mapConnection, existingRunId)) Console.WriteLine($"  {line}");
  return 0;
}

if (string.IsNullOrWhiteSpace(sourceCode) || string.IsNullOrWhiteSpace(root)
  || !int.TryParse(organizationText, out var organizationId))
{
  Console.Error.WriteLine("Manjkajo PIM_XML_SOURCE_CODE, PIM_XML_ROOT ali PIM_XML_ORGANIZATION_ID.");
  return 2;
}

// Poleg XML beremo tudi delovne zvezke: pretvorimo jih v isti generični XML in gredo po isti
// poti (WorkbookReader). Zacasne Excelove datoteke (~$...) preskocimo.
var files = Directory.GetFiles(root, "*.*")
  .Where(path => path.EndsWith(".xml", StringComparison.OrdinalIgnoreCase)
    || path.EndsWith(".xlsx", StringComparison.OrdinalIgnoreCase))
  .Where(path => !Path.GetFileName(path).StartsWith("~$", StringComparison.Ordinal))
  .OrderBy(path => path, StringComparer.Ordinal)
  .ToArray();
await using var operationsRun = await OperationsRun.BeginAsync(connectionString, organizationId, "GENERIC_XML", $"{Environment.MachineName}:{Environment.ProcessId}");
var runId = Guid.NewGuid();
await using (var connection = new SqlConnection(connectionString))
{
  await connection.OpenAsync();
  var entities = await ReadEntitiesAsync(connection, sourceCode, organizationId);
  await InsertRunAsync(connection, runId, organizationId, sourceCode);
  var page = 0;
  var preskoceneDatoteke = 0;
  var zeZajete = 0;
  foreach (var file in files)
  {
    string payload;
    try
    {
      payload = file.EndsWith(".xlsx", StringComparison.OrdinalIgnoreCase)
        ? WorkbookReader.ToXml(file)
        : await File.ReadAllTextAsync(file);
    }
    catch (Exception exception) when (exception is InvalidOperationException or IOException
      or System.IO.InvalidDataException)
    {
      // Zvezek brez lista s sifro artikla ni napaka zajema, ampak datoteka, ki ne sodi sem.
      // Prej je taka datoteka ustavila cel zagon in vse za njo je ostalo nezajeto.
      Console.Error.WriteLine($"  preskoceno: {Path.GetFileName(file)} — {exception.Message}");
      preskoceneDatoteke++;
      continue;
    }

    foreach (var entity in entities)
    {
      try
      {
        await InsertInboxAsync(connection, runId, organizationId, sourceCode, entity, ++page, payload);
      }
      catch (SqlException exception) when (exception.Number is 2627 or 2601)
      {
        // Enolicnost (vir, entiteta, stran, hash) pomeni: to vsebino smo ze zajeli. To ni okvara,
        // ampak varovalka pred podvojenim zajemom — in ne sme ustaviti datotek za njo.
        zeZajete++;
      }
    }
  }
  if (preskoceneDatoteke > 0 || zeZajete > 0)
    Console.WriteLine($"Preskocenih datotek: {preskoceneDatoteke}; ze zajetih strani: {zeZajete}.");
}
await new SqlMappingPipeline(connectionString).ExtractAndApplyAsync(runId, organizationId, sourceCode);
// Zaključi lasten zapis v ops.PipelineRun (enako kot PIM.KatalogWorker), da run ne ostane v stanju Running.
await using (var connection = new SqlConnection(connectionString))
{
  await connection.OpenAsync();
  await FinishRunAsync(connection, runId);
}
Console.WriteLine($"Generični XML zajem je končan; datotek={files.Length}, RunId={runId}.");
await using (var summaryConnection = new SqlConnection(connectionString))
{
  await summaryConnection.OpenAsync();
  foreach (var line in await ReadRunSummaryAsync(summaryConnection, runId)) Console.WriteLine($"  {line}");
}
await operationsRun.CompleteAsync(true);
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
static async Task FinishRunAsync(SqlConnection connection, Guid runId)
{
  // RowsRead = vse zajete vrstice; RowsSucceeded = tiste, ki niso končale v karanteni.
  await using var command = new SqlCommand("""
    UPDATE ops.PipelineRun
    SET Status = N'Succeeded', EndedUtc = SYSUTCDATETIME(),
        RowsRead = (SELECT COUNT(*) FROM raw.Inbox WHERE RunId = @RunId),
        RowsSucceeded = (SELECT COUNT(*) FROM raw.Inbox WHERE RunId = @RunId AND Status <> N'Quarantined')
    WHERE RunId = @RunId;
    """, connection);
  command.Parameters.AddWithValue("@RunId", runId);
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

static async Task<(int OrganizationId, string SourceCode)?> ReadRunAsync(SqlConnection connection, Guid runId)
{
  await using var command = new SqlCommand("""
    SELECT TOP 1 OrganizationId, SourceCode FROM raw.Inbox WHERE RunId=@RunId;
    """, connection);
  command.Parameters.AddWithValue("@RunId", runId);
  await using var reader = await command.ExecuteReaderAsync();
  if (!await reader.ReadAsync()) return null;
  return (reader.GetInt32(0), reader.GetString(1));
}
static async Task<string[]> ReadRunSummaryAsync(SqlConnection connection, Guid runId)
{
  // Izpis po entiteti in stanju: brez tega je edini dokaz zagona vrstica v bazi, ki je nihce ne pogleda.
  await using var command = new SqlCommand("""
    SELECT EntityType, Status, COUNT(*) AS Strani, MAX(ISNULL(FailureReason,N'')) AS Razlog
    FROM raw.Inbox WHERE RunId=@RunId GROUP BY EntityType, Status ORDER BY EntityType, Status;
    """, connection);
  command.Parameters.AddWithValue("@RunId", runId);
  await using var reader = await command.ExecuteReaderAsync();
  var lines = new List<string>();
  while (await reader.ReadAsync())
  {
    var reason = reader.GetString(3);
    lines.Add($"{reader.GetString(0),-16} {reader.GetString(1),-12} strani={reader.GetInt32(2)}"
      + (reason.Length == 0 ? string.Empty : $" — {reason}"));
  }
  return lines.ToArray();
}

static async Task<int> ReopenRunAsync(SqlConnection connection, Guid runId)
{
  // Strani nazaj na Pending IN izluscene vrednosti nazaj v surovo obliko. Drugo je bistvo:
  // map.ApplyValueTransforms preskoci vrednost, ki ima RawValue (ze pretvorjena), zato
  // dopolnjen slovar brez tega nad ze obdelanim zajemom nima ucinka — natanko primer, za
  // katerega to stikalo obstaja. Postopek je v bazi (migracija 094), ker ga kliceta oba workerja.
  await using var command = new SqlCommand("map.ReopenRunForMapping", connection)
  {
    CommandType = System.Data.CommandType.StoredProcedure
  };
  command.Parameters.AddWithValue("@RunId", runId);
  var pages = command.Parameters.Add("@Pages", System.Data.SqlDbType.Int);
  pages.Direction = System.Data.ParameterDirection.Output;
  await command.ExecuteNonQueryAsync();
  return pages.Value as int? ?? 0;
}
