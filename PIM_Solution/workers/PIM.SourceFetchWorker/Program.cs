using System.Text.Json;
using Microsoft.Data.SqlClient;
using PIM.Operations;
using PIM.SourceFetchWorker;

// Prevzem dobaviteljevih datotek. Doslej prevzemnika ni bilo: map.SourceFetchLocation je bil
// register, ki ga ni brala nobena koda, zato so datoteke v mapo prihajale rocno in zaloga je
// bila stara toliko, kolikor je bila stara zadnja rocno odlozena datoteka.
//
//   dotnet run --project PIM_Solution\workers\PIM.SourceFetchWorker -- [--source BT_STOCK]
//              [--target <mapa>] [--samo-nastavitve]
//
// Prevzemnik samo prinese datoteko. Branje v bazo opravi PIM.StockFileWorker oziroma
// PIM.XmlFileWorker — locitev je namerna, ker so napake prevzema (omrezje, poverilnice,
// dobaviteljev izpad) druga vrsta napake kot napake preslikave.

string? onlySource = null;
string? targetOverride = null;
var onlySettings = false;

for (var index = 0; index < args.Length; index++)
{
  switch (args[index].ToLowerInvariant())
  {
    case "--source":
      if (index + 1 >= args.Length) return Napaka("--source potrebuje sifro vira.");
      onlySource = args[++index];
      break;
    case "--target":
      if (index + 1 >= args.Length) return Napaka("--target potrebuje pot do mape.");
      targetOverride = args[++index];
      break;
    case "--samo-nastavitve":
      onlySettings = true;
      break;
    default:
      return Napaka($"Neznan argument: {args[index]}.");
  }
}

var settingsPath = FindLocalSettings();
var connectionString = ReadConnectionString(settingsPath);
if (string.IsNullOrWhiteSpace(connectionString))
  return Napaka("Manjka povezava Pim (PIM_CONNECTION_STRING ali appsettings.Local.json).");

var fetchSection = SourceFetcher.ReadFetchSection(settingsPath);
var targetRoot = targetOverride
  ?? Environment.GetEnvironmentVariable("PIM_FETCH_ROOT")
  ?? Path.Combine(RepositoryRoot(settingsPath), "PIM_Solution", "data", "prevzem");

await using var connection = new SqlConnection(connectionString);
await connection.OpenAsync();
var locations = await ReadLocationsAsync(connection, onlySource);

if (locations.Count == 0)
{
  Console.Error.WriteLine(onlySource is null
    ? "V map.SourceFetchLocation ni nobenega aktivnega prevzema."
    : $"Za vir {onlySource} v map.SourceFetchLocation ni aktivnega prevzema.");
  return 2;
}

if (onlySettings)
{
  Console.WriteLine($"Samo nastavitve; ciljna mapa: {targetRoot}");
  foreach (var location in locations)
  {
    var credential = FetchCredential.Read(fetchSection, location.CredentialKey ?? "");
    var stanje = location.Kind.Equals("MAPA", StringComparison.OrdinalIgnoreCase)
      ? "lokalna mapa"
      : credential is null ? "NASTAVITEV MANJKA" : "nastavljeno";
    Console.WriteLine($"  {location.SourceCode,-12} {location.Kind,-5} {stanje}");
  }
  return 0;
}

// Prevzem je skupen vsem podjetjem (OrganizationId je v registru NULL), zato tece pod prvim
// aktivnim podjetjem — razpored in sled sta vezana na organizacijo, datoteka pa ne.
var organizationId = await ReadScheduledOrganizationAsync(connection);
if (organizationId is null)
{
  Console.Error.WriteLine("Za pipeline SOURCE_FETCH ni omogocenega razporeda v ops.ScheduleProfile; nic ni bilo prevzeto.");
  return 1;
}

using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(10) };
http.DefaultRequestHeaders.Add("User-Agent", "PIM.SourceFetchWorker/1.0");
var fetcher = new SourceFetcher(http, targetRoot);

await using var run = await OperationsRun.BeginAsync(connectionString, organizationId.Value, "SOURCE_FETCH",
  $"{Environment.MachineName}:{Environment.ProcessId}");

var prevzetih = 0;
var napak = 0;
try
{
  foreach (var location in locations)
  {
    var credential = FetchCredential.Read(fetchSection, location.CredentialKey ?? "");
    var outcome = await fetcher.FetchAsync(location, credential);
    await run.HeartbeatAsync();

    if (outcome.Error is not null)
    {
      napak++;
      Console.Error.WriteLine($"[{outcome.SourceCode}] NAPAKA: {outcome.Error}");
    }
    else if (outcome.Fetched)
    {
      prevzetih++;
      Console.WriteLine($"[{outcome.SourceCode}] prevzeto {outcome.Bytes:N0} bajtov -> {outcome.TargetPath}");
    }
    else
    {
      Console.WriteLine($"[{outcome.SourceCode}] preskoceno: {outcome.Skipped}");
    }
  }
}
finally
{
  await run.CompleteAsync(napak == 0, napak == 0 ? null : $"Neuspesnih prevzemov: {napak}.");
}

Console.WriteLine($"Prevzem koncan: uspesno {prevzetih}, neuspesno {napak}, skupaj virov {locations.Count}.");
return napak > 0 ? 1 : 0;

static int Napaka(string sporocilo)
{
  Console.Error.WriteLine(sporocilo);
  Console.Error.WriteLine("Uporaba: PIM.SourceFetchWorker [--source <sifra>] [--target <mapa>] [--samo-nastavitve]");
  return 2;
}

static async Task<List<FetchLocation>> ReadLocationsAsync(SqlConnection connection, string? sourceCode)
{
  await using var command = new SqlCommand("""
    SELECT SourceFetchLocationId, OrganizationId, SourceCode, Kind, Location, CredentialKey, FileNamePattern, Note
    FROM map.SourceFetchLocation
    WHERE IsActive = 1 AND (@SourceCode IS NULL OR SourceCode = @SourceCode)
    ORDER BY SourceCode;
    """, connection);
  command.Parameters.AddWithValue("@SourceCode", (object?)sourceCode ?? DBNull.Value);
  await using var reader = await command.ExecuteReaderAsync();
  var rows = new List<FetchLocation>();
  while (await reader.ReadAsync())
  {
    rows.Add(new(
      reader.GetInt32(0),
      reader.IsDBNull(1) ? null : reader.GetInt32(1),
      reader.GetString(2), reader.GetString(3),
      reader.IsDBNull(4) ? null : reader.GetString(4),
      reader.IsDBNull(5) ? null : reader.GetString(5),
      reader.IsDBNull(6) ? null : reader.GetString(6),
      reader.IsDBNull(7) ? null : reader.GetString(7)));
  }

  return rows;
}

static async Task<int?> ReadScheduledOrganizationAsync(SqlConnection connection)
{
  await using var command = new SqlCommand(
    "SELECT TOP(1) OrganizationId FROM ops.ScheduleProfile WHERE Pipeline = N'SOURCE_FETCH' AND IsEnabled = 1 ORDER BY OrganizationId;",
    connection);
  return await command.ExecuteScalarAsync() as int?;
}

/// <summary>
/// Nastavitve korena repozitorija, ne prve najdene datoteke. Pod PIM_Solution stoji svoja
/// appsettings.Local.json, ki nosi samo povezavo in nima odseka Fetch; ce bi worker vzel njo
/// (kar se zgodi, ko ga pozene skripta iz PIM_Solution), poverilnic ne bi nasel. Koren
/// prepoznamo po PIM_Solution\PIM.sln — isti postopek kot LocalSettingsLocator v intranetu.
/// </summary>
static string? FindLocalSettings()
{
  var directory = new DirectoryInfo(Directory.GetCurrentDirectory());
  string? prvaNajdena = null;

  while (directory is not null)
  {
    var candidate = Path.Combine(directory.FullName, "appsettings.Local.json");
    if (File.Exists(candidate))
    {
      prvaNajdena ??= candidate;
      if (File.Exists(Path.Combine(directory.FullName, "PIM_Solution", "PIM.sln"))) return candidate;
    }

    directory = directory.Parent;
  }

  return prvaNajdena;
}

static string RepositoryRoot(string? settingsPath) =>
  settingsPath is null ? Directory.GetCurrentDirectory() : Path.GetDirectoryName(settingsPath)!;

static string? ReadConnectionString(string? settingsPath)
{
  var value = Environment.GetEnvironmentVariable("PIM_CONNECTION_STRING");
  if (!string.IsNullOrWhiteSpace(value)) return value;
  if (settingsPath is null) return null;
  using var document = JsonDocument.Parse(File.ReadAllText(settingsPath));
  return document.RootElement.GetProperty("ConnectionStrings").GetProperty("Pim").GetString();
}
