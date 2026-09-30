var root = FindRoot();
// Stran /system/integracije je odstranjena (prenova nadzora, blok 7); njeno vlogo (gostitelj, obvestila s
// potrditvijo in razrešitvijo ter sled dejanja) zdaj nosi stran Nadzor na /sistem prek MonitorService.
var page = File.ReadAllText(Path.Combine(root, "src/PIM.Intranet/Components/Pages/Monitor.razor"));
var service = File.ReadAllText(Path.Combine(root, "src/PIM.Intranet/Services/MonitorService.cs"));
foreach (var value in new[] { "@page \"/sistem\"", "Authorize(Roles = \"ADMIN\"", "Gostitelj avtomatike", "utrip", "Potrdi", "Razreši" }) Assert(page.Contains(value, StringComparison.Ordinal), "stran manjka: " + value);
foreach (var value in new[] { "intranet.AcknowledgeAlert", "intranet.ResolveAlert", "@OrganizationId", "@Actor", "ALERT_ACK", "ALERT_RESOLVE" }) Assert(service.Contains(value, StringComparison.Ordinal), "storitev manjka: " + value);
Assert(!page.Contains("TODO", StringComparison.OrdinalIgnoreCase), "stran vsebuje placeholder");

// Naloga #57: testni intranet (klikalnik, preverjalec) ne sme zagnati, izklopiti ali urejati poslov.
// Zapora je v servisu (RequireAdminAsync), vklopi jo samo PIM.Klikalnik; pravi intranet je ne nastavi.
var guardStart = service.IndexOf("async Task RequireAdminAsync()", StringComparison.Ordinal);
Assert(guardStart > 0, "RequireAdminAsync manjka");
var guardBody = service.Substring(guardStart, service.IndexOf("\n  }", guardStart, StringComparison.Ordinal) - guardStart);
Assert(guardBody.Contains("IsTestIntranetWithoutJobs(configuration)", StringComparison.Ordinal)
  && guardBody.Contains("TestIntranetMessage", StringComparison.Ordinal), "RequireAdminAsync ne upošteva testnega intraneta");
Assert(service.Contains("TestIntranetWithoutJobsKey = \"Pim:TestniIntranet:BrezPoslov\"", StringComparison.Ordinal), "ključ zapore poslov manjka");
Assert(service.Contains("Testni intranet: zagon in urejanje poslov sta izklopljena", StringComparison.Ordinal), "sporočilo zapore manjka");
foreach (var method in new[] { "RequestRunAsync(", "RequestCancelAsync(", "SetJobEnabledAsync(", "SaveJobScheduleAsync(",
  "SaveSourceMaxAgeAsync(", "EnablePipelineAsync(", "SetOrganizationAutomationAsync(" })
{
  var at = service.IndexOf("public async Task " + method, StringComparison.Ordinal);
  Assert(at > 0, "upravljalna metoda manjka: " + method);
  var body = service.Substring(at, service.IndexOf('{', at) + 60 - at);
  Assert(body.Contains("await RequireAdminAsync();", StringComparison.Ordinal), "metoda ne kliče RequireAdminAsync na začetku: " + method);
}
var klikalnik = File.ReadAllText(Path.Combine(root, "tools/PIM.Klikalnik/Program.cs"));
Assert(klikalnik.Contains("MonitorService.TestIntranetWithoutJobsKey] = \"true\"", StringComparison.Ordinal), "testni intranet ne izklopi poslov");
foreach (var settings in Directory.GetFiles(Path.Combine(root, "src/PIM.Intranet"), "appsettings*.json"))
  Assert(!File.ReadAllText(settings).Contains("TestniIntranet", StringComparison.OrdinalIgnoreCase), "pravi intranet ne sme imeti zapore poslov: " + Path.GetFileName(settings));
var skripta = File.ReadAllText(Path.Combine(root, "tools/PIM.Klikalnik/klikalnik.mjs"));
Assert(skripta.Contains("oznake: oznake(el)", StringComparison.Ordinal) && skripta.Contains("NEVARNO.test(g.oznake)", StringComparison.Ordinal),
  "klikalnik ne preverja aria-label/title pri nevarnih gumbih");
foreach (var word in new[] { "pozen", "zagon", "zazeni", "izklopi", "vklopi" })
  Assert(skripta.Contains("|" + word + "|", StringComparison.Ordinal) || skripta.Contains("(" + word + "|", StringComparison.Ordinal), "NEVARNO manjka: " + word);
Console.WriteLine("F9 intranet: testni intranet ne upravlja poslov (#57) PASS.");
Console.WriteLine("F9 intranet: administratorski slovenski pregled in audit dejanja PASS.");

static void Assert(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
static string FindRoot() { var current=new DirectoryInfo(Directory.GetCurrentDirectory());while(current is not null){if(Directory.Exists(Path.Combine(current.FullName,"sql","migrations")))return current.FullName;current=current.Parent;}throw new InvalidOperationException("PIM_Solution ni najden."); }
