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
var bySchedule = false;

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
    case "--po-urniku":
      bySchedule = true;
      break;
    default:
      return Napaka($"Neznan argument: {args[index]}.");
  }
}

var connectionString = LocalSettings.ConnectionString();
if (string.IsNullOrWhiteSpace(connectionString))
  return Napaka(LocalSettings.MissingConnectionMessage());

var fetchSection = LocalSettings.Section("Fetch") ?? default;

await using var connection = new SqlConnection(connectionString);
await connection.OpenAsync();

// Vrstni red je enak povsod (glej PIM.Operations.SystemPaths): argument, okolje, register,
// privzetek. Register je tretji zato, da rocni zagon z --target ostane mocnejsi od nastavitve
// in se da preizkus izvesti drugje kot v produkcijski mapi.
var targetRoot = targetOverride
  ?? Environment.GetEnvironmentVariable("PIM_FETCH_ROOT")
  ?? await PIM.Operations.SystemPaths.ResolveAsync(connection, PIM.Operations.SystemPaths.Landing)
  ?? Path.Combine(LocalSettings.FindSolutionRoot(AppContext.BaseDirectory) ?? Directory.GetCurrentDirectory(), "data", "prevzem");
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

if (bySchedule && !await OperationsRun.IsDueAsync(connectionString, organizationId.Value, "SOURCE_FETCH"))
{
  Console.WriteLine("SOURCE_FETCH: se ni na vrsti po razporedu; preskoceno.");
  return 0;
}

using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(10) };
http.DefaultRequestHeaders.Add("User-Agent", "PIM.SourceFetchWorker/1.0");
var fetcher = new SourceFetcher(http, targetRoot);

var workerId = $"{Environment.MachineName}:{Environment.ProcessId}";
await using var run = await OperationsRun.BeginAsync(connectionString, organizationId.Value, "SOURCE_FETCH", workerId);

// Faze (migracija 255): vsak vir dobi svojo vrstico s tem, kaj se je z njim zgodilo. Brez tega je
// bil prenos, ki se pet dni ni zgodil, videti enako kot uspesen prenos (BT_STOCK, 2026-09-22).
var phases = PhaseLog.FromEnvironment(connectionString, workerId);

var prevzetih = 0;
var napake = new List<string>();
try
{
  foreach (var location in locations)
  {
    var credential = FetchCredential.Read(fetchSection, location.CredentialKey ?? "");
    var phase = await phases.BeginAsync(PhaseCodes.Fetch, location.SourceCode, organizationId, "SOURCE_FETCH", run.RunId);
    var outcome = await fetcher.FetchAsync(location, credential);
    await run.HeartbeatAsync();

    if (outcome.Error is not null)
    {
      napake.Add($"{outcome.SourceCode}: {outcome.Error}");
      Console.Error.WriteLine($"[{outcome.SourceCode}] NAPAKA: {outcome.Error}");
      await phase.FailedAsync(outcome.Error);
    }
    else if (outcome.Fetched)
    {
      prevzetih++;
      var arhiv = outcome.ArchivePath is null ? "" : $"; arhiv {Path.GetFileName(outcome.ArchivePath)}";
      Console.WriteLine($"[{outcome.SourceCode}] prevzeto {outcome.Bytes:N0} bajtov -> {outcome.TargetPath}{arhiv}");
      await phase.SucceededAsync(byteCount: outcome.Bytes, hasNewData: true,
        message: outcome.TargetPath is null ? null : Path.GetFileName(outcome.TargetPath));
    }
    else if (outcome.TargetPath is not null && outcome.Bytes > 0 && outcome.Skipped is { } nespremenjeno && nespremenjeno.Contains("nespremenjena", StringComparison.OrdinalIgnoreCase))
    {
      // Stik z dobaviteljem je bil, datoteka je ista: uspeh brez novih podatkov. Svezina vira se
      // meri po stiku (dobavitelj je dosegljiv), starost podatkov pa po zadnji novi datoteki.
      Console.WriteLine($"[{outcome.SourceCode}] nespremenjeno: {outcome.Skipped}");
      await phase.SucceededAsync(byteCount: outcome.Bytes, hasNewData: false, message: nespremenjeno);
    }
    else
    {
      Console.WriteLine($"[{outcome.SourceCode}] preskoceno: {outcome.Skipped}");
      // Stika ni bilo (razmik dobavitelja, lokalna mapa): ni uspeh in ne napaka, razlog pa mora biti zapisan.
      await phase.SkippedAsync(outcome.Skipped ?? "Brez novega prevzema.");
    }
  }
}
finally
{
  await run.CompleteAsync(napake.Count == 0, napake.Count == 0 ? null : string.Join("; ", napake));
}

Console.WriteLine($"Prevzem koncan: uspesno {prevzetih}, neuspesno {napake.Count}, skupaj virov {locations.Count}.");
return napake.Count > 0 ? 1 : 0;

static int Napaka(string sporocilo)
{
  Console.Error.WriteLine(sporocilo);
  Console.Error.WriteLine("Uporaba: PIM.SourceFetchWorker [--source <sifra>] [--target <mapa>] [--samo-nastavitve]");
  return 2;
}

static async Task<List<FetchLocation>> ReadLocationsAsync(SqlConnection connection, string? sourceCode)
{
  await using var command = new SqlCommand("""
    SELECT SourceFetchLocationId, OrganizationId, SourceCode, Kind, Location, CredentialKey, FileNamePattern, Note,
           MinIntervalMinutes
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
      reader.IsDBNull(7) ? null : reader.GetString(7),
      reader.IsDBNull(8) ? null : reader.GetInt32(8)));
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


