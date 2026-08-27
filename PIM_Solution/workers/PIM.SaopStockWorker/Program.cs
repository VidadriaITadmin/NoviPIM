using System.Globalization;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using Microsoft.Data.SqlClient;
using PIM.Operations;
using PIM.SaopStockWorker;

// Zaloga iz SAOP. Profil (kateri vmesnik, katera skladišča) je vrstica v
// stock.SaopProviderProfile, ne nastavitev v kodi — migracija 065.
//
//   dotnet run --project PIM_Solution\workers\PIM.SaopStockWorker -- --organizations 2,3 [--page-size 5000]
//              [--base-url https://…] [--samo-nastavitve]
//
// Živ klic je odločitev človeka (AGENTS.md §4.5), zato ga worker izvede samo, kadar je
// PIM_SAOP_MODE=Live. Brez tega izpiše, kaj bi poklical, in konča z 0.

var organizations = new List<int>();
int? pageSize = null;
string? baseUrlOverride = null;
var onlySettings = false;

for (var index = 0; index < args.Length; index++)
{
  switch (args[index].ToLowerInvariant())
  {
    case "--organizations":
      if (index + 1 >= args.Length) return Napaka("--organizations potrebuje seznam, npr. 2,3.");
      organizations.AddRange(args[++index].Split(',', StringSplitOptions.RemoveEmptyEntries)
        .Select(value => int.Parse(value.Trim(), CultureInfo.InvariantCulture)));
      break;
    case "--page-size":
      if (index + 1 >= args.Length) return Napaka("--page-size potrebuje število.");
      pageSize = int.Parse(args[++index], CultureInfo.InvariantCulture);
      break;
    case "--base-url":
      if (index + 1 >= args.Length) return Napaka("--base-url potrebuje naslov.");
      baseUrlOverride = args[++index];
      break;
    case "--samo-nastavitve":
      onlySettings = true;
      break;
    default:
      return Napaka($"Neznan argument: {args[index]}.");
  }
}

var settings = SaopStockSettings.Read(baseUrlOverride);
if (settings is null) return Napaka("Manjka nastavitev Saop (BaseUrl, Username, Password) v appsettings.Local.json.");
if (string.IsNullOrWhiteSpace(settings.ConnectionString)) return Napaka("Manjka povezava Pim.");

if (organizations.Count == 0) organizations.AddRange(settings.ActiveOrganizations);
if (organizations.Count == 0) return Napaka("Nobenega podjetja: navedi --organizations ali vklopi podjetje v nastavitvah.");

var live = string.Equals(Environment.GetEnvironmentVariable("PIM_SAOP_MODE"), "Live", StringComparison.OrdinalIgnoreCase);
if (onlySettings || !live)
{
  Console.WriteLine(live ? "Samo nastavitve, klic ni izveden." : "PIM_SAOP_MODE ni Live — klic ni izveden.");
  Console.WriteLine($"  naslov:   {settings.BaseUrl}");
  Console.WriteLine($"  podjetja: {string.Join(", ", organizations)}");
  Console.WriteLine("  profil in skladišča se preberejo iz stock.SaopProviderProfile in canon.Warehouse.");
  return 0;
}

using var handler = new HttpClientHandler();
if (settings.AcceptUntrustedCertificate)
{
  // Isto pravilo kot pri katalogu: velja samo za ta odjemalec in samo, kadar je izrecno vklopljeno.
  handler.ServerCertificateCustomValidationCallback = (_, _, _, _) => true;
}
using var http = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(Math.Max(30, settings.TimeoutSeconds)) };
http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue(
  "Basic", Convert.ToBase64String(Encoding.ASCII.GetBytes($"{settings.Username}:{settings.Password}")));
http.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/xml"));

// Ime postopka je isto v ops.ScheduleProfile, ops.PipelineRun in ops.IntegrationHealth,
// zato stoji na enem mestu.
const string Pipeline = "SAOP_STOCK";

var runner = new SaopStockRunner(settings.ConnectionString, http, new Uri(settings.BaseUrl.TrimEnd('/') + "/"));
var napake = 0;
foreach (var organizationId in organizations)
{
  // Zagon se odpre prek ops.BeginRun, da zaloga tece pod istim razporedom in isto sledjo kot
  // ostali vhodi: brez omogocene vrstice v ops.ScheduleProfile vrze 51100 in podjetje se
  // preskoci. Doslej je zaloga to varovalko obhajala in je zato ni bilo v /zajem/teki.
  OperationsRun? run = null;
  try
  {
    run = await OperationsRun.BeginAsync(settings.ConnectionString, organizationId, Pipeline,
      $"{Environment.MachineName}:{Environment.ProcessId}");
  }
  catch (SqlException exception) when (exception.Number is 51100 or 51101)
  {
    napake++;
    Console.Error.WriteLine(exception.Number == 51100
      ? $"[{organizationId}] Razpored za {Pipeline} ni omogocen; podjetje je preskoceno."
      : $"[{organizationId}] {Pipeline} ze tece; ta zagon se je umaknil.");
    continue;
  }

  try
  {
    var izid = await runner.RunAsync(organizationId, pageSize);
    await run.CompleteAsync(true);
    Console.WriteLine($"[{organizationId}] {izid.ProfileCode} ({izid.ProviderKind}): skladišč={izid.Warehouses}, "
      + $"zapisov={izid.RecordsRead}, uporabljenih={izid.Applied}, v karanteni={izid.Quarantined}, RunId={izid.RunId}.");
  }
  catch (Exception exception)
  {
    // Padec enega podjetja ne sme ustaviti ostalih — isto pravilo kot pri katalogu.
    napake++;
    await run.CompleteAsync(false, exception.Message);
    Console.Error.WriteLine($"[{organizationId}] NAPAKA: {exception.Message}");
  }
  finally
  {
    await run.DisposeAsync();
  }
}
return napake == 0 ? 0 : 1;

static int Napaka(string sporocilo)
{
  Console.Error.WriteLine(sporocilo);
  Console.Error.WriteLine("Uporaba: PIM.SaopStockWorker [--organizations 2,3] [--page-size N] [--base-url URL] [--samo-nastavitve]");
  return 2;
}

/// <summary>Nastavitve SAOP in povezava, prebrane iz iste lokalne datoteke kot pri katalogu.</summary>
internal sealed record SaopStockSettings(
  string BaseUrl, string Username, string Password, int TimeoutSeconds,
  bool AcceptUntrustedCertificate, string? ConnectionString, IReadOnlyList<int> ActiveOrganizations)
{
  public static SaopStockSettings? Read(string? baseUrlOverride)
  {
    // Nastavitve korena repozitorija, ne prve najdene datoteke. Pod PIM_Solution stoji svoja
    // appsettings.Local.json, ki nosi samo povezavo in nima odseka Saop; ko worker pozene
    // skripta iz PIM_Solution, bi vzel njo in koncal z "Manjka nastavitev Saop", ceprav so
    // nastavitve v korenu. Koren prepoznamo po PIM_Solution\PIM.sln.
    var path = FindSettingsPath();
    if (path is not null)
    {
      {
        using var document = JsonDocument.Parse(File.ReadAllText(path));
        var root = document.RootElement;
        if (!root.TryGetProperty("Saop", out var saop)) return null;
        var organizations = new List<int>();
        if (saop.TryGetProperty("Organizations", out var array))
        {
          foreach (var element in array.EnumerateArray())
          {
            if (element.TryGetProperty("IsActive", out var active) && active.GetBoolean()
              && element.TryGetProperty("Id", out var id)) organizations.Add(id.GetInt32());
          }
        }
        var connection = Environment.GetEnvironmentVariable("PIM_CONNECTION_STRING");
        if (string.IsNullOrWhiteSpace(connection) && root.TryGetProperty("ConnectionStrings", out var strings)
          && strings.TryGetProperty("Pim", out var pim)) connection = pim.GetString();
        return new(
          baseUrlOverride ?? saop.GetProperty("BaseUrl").GetString() ?? "",
          saop.TryGetProperty("Username", out var user) ? user.GetString() ?? "" : "",
          saop.TryGetProperty("Password", out var pass) ? pass.GetString() ?? "" : "",
          saop.TryGetProperty("TimeoutSeconds", out var timeout) ? timeout.GetInt32() : 120,
          saop.TryGetProperty("AcceptUntrustedCertificate", out var untrusted) && untrusted.GetBoolean(),
          connection, organizations);
      }
    }

    return null;
  }

  /// <summary>Prva najdena datoteka navzgor; ce je med njimi koren repozitorija, zmaga ta.</summary>
  static string? FindSettingsPath()
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
}
