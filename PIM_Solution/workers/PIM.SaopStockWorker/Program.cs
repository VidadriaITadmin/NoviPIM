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
var bySchedule = false;
// Datumi in kolicine prihoda (migracija 189, GetItemDeliveryDate) so locen, pocasnejsi zajem —
// en artikel naenkrat, zato gre v nocni tek, ne v petminutni cikel zaloge same.
var deliveryDates = false;
var maxDeliveryLookups = 300;

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
    case "--po-urniku":
      // Nacrtovani zagon spostuje razpored iz baze; rocni ga namenoma obide.
      bySchedule = true;
      break;
    case "--dostave":
      deliveryDates = true;
      break;
    case "--max-dostave":
      if (index + 1 >= args.Length) return Napaka("--max-dostave potrebuje število.");
      maxDeliveryLookups = int.Parse(args[++index], CultureInfo.InvariantCulture);
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
  if (deliveryDates)
    Console.WriteLine($"  dejanje:  datumi in kolicine prihoda (GetItemDeliveryDate), do {maxDeliveryLookups} artiklov na podjetje.");
  else
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
// zato stoji na enem mestu. Datumi prihoda dobijo svoj Pipeline (SAOP_DELIVERY, migracija 164), da imajo
// svoj razpored — ta zajem je en klic na artikel in ne sodi v petminutni cikel zaloge same.
// Pipeline mora biti omogocen v ops.ScheduleProfile, preden prvi zagon uspe (glej spodaj).
var Pipeline = deliveryDates ? "SAOP_DELIVERY" : "SAOP_STOCK";

var runner = new SaopStockRunner(settings.ConnectionString, http, new Uri(settings.BaseUrl.TrimEnd('/') + "/"));
var napake = 0;
foreach (var organizationId in organizations)
{
  if (bySchedule && !await OperationsRun.IsDueAsync(settings.ConnectionString, organizationId, Pipeline))
  {
    Console.WriteLine($"[{organizationId}] {Pipeline}: se ni na vrsti po razporedu; preskoceno.");
    continue;
  }

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
    if (deliveryDates)
    {
      var izidDostave = await runner.RunItemDeliveryDatesAsync(organizationId, maxDeliveryLookups);
      await run.CompleteAsync(true);
      Console.WriteLine($"[{organizationId}] datumi prihoda: preverjenih={izidDostave.ItemsChecked}, "
        + $"z dobavo={izidDostave.ItemsWithDelivery}.");
    }
    else
    {
      var izid = await runner.RunAsync(organizationId, pageSize);
      await run.CompleteAsync(true);
      Console.WriteLine($"[{organizationId}] {izid.ProfileCode} ({izid.ProviderKind}): skladišč={izid.Warehouses}, "
        + $"zapisov={izid.RecordsRead}, uporabljenih={izid.Applied}, v karanteni={izid.Quarantined}, RunId={izid.RunId}.");
    }
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
  Console.Error.WriteLine("Uporaba: PIM.SaopStockWorker [--organizations 2,3] [--page-size N] [--base-url URL] "
    + "[--samo-nastavitve] [--dostave [--max-dostave N]]");
  return 2;
}

/// <summary>Nastavitve SAOP in povezava, prebrane iz iste lokalne datoteke kot pri katalogu.</summary>
internal sealed record SaopStockSettings(
  string BaseUrl, string Username, string Password, int TimeoutSeconds,
  bool AcceptUntrustedCertificate, string? ConnectionString, IReadOnlyList<int> ActiveOrganizations)
{
  public static SaopStockSettings? Read(string? baseUrlOverride)
  {
    // Odsek Saop iz skupne lokalne nastavitve rešitve. Prej je bilo tu svoje iskanje datoteke:
    // ker je vsak worker iskal po svoje, je vsak našel drugo datoteko in ta je znala biti brez
    // odseka Saop — worker je javil "Manjka nastavitev Saop", čeprav je bila nastavljena.
    if (LocalSettings.Section("Saop") is not { } saop) return null;

    var organizations = new List<int>();
    if (saop.TryGetProperty("Organizations", out var array))
    {
      foreach (var element in array.EnumerateArray())
      {
        if (element.TryGetProperty("IsActive", out var active) && active.GetBoolean()
          && element.TryGetProperty("Id", out var id)) organizations.Add(id.GetInt32());
      }
    }

    return new(
      baseUrlOverride ?? saop.GetProperty("BaseUrl").GetString() ?? "",
      saop.TryGetProperty("Username", out var user) ? user.GetString() ?? "" : "",
      saop.TryGetProperty("Password", out var pass) ? pass.GetString() ?? "" : "",
      saop.TryGetProperty("TimeoutSeconds", out var timeout) ? timeout.GetInt32() : 120,
      saop.TryGetProperty("AcceptUntrustedCertificate", out var untrusted) && untrusted.GetBoolean(),
      LocalSettings.ConnectionString(), organizations);
  }

}
