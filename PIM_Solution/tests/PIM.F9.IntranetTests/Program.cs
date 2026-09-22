var root = FindRoot();
// Stran /system/integracije je odstranjena (prenova nadzora, blok 7); njeno vlogo (gostitelj, obvestila s
// potrditvijo in razrešitvijo ter sled dejanja) zdaj nosi stran Nadzor na /sistem prek MonitorService.
var page = File.ReadAllText(Path.Combine(root, "src/PIM.Intranet/Components/Pages/Monitor.razor"));
var service = File.ReadAllText(Path.Combine(root, "src/PIM.Intranet/Services/MonitorService.cs"));
foreach (var value in new[] { "@page \"/sistem\"", "Authorize(Roles = \"ADMIN\"", "Gostitelj avtomatike", "utrip", "Potrdi", "Razreši" }) Assert(page.Contains(value, StringComparison.Ordinal), "stran manjka: " + value);
foreach (var value in new[] { "intranet.AcknowledgeAlert", "intranet.ResolveAlert", "@OrganizationId", "@Actor", "ALERT_ACK", "ALERT_RESOLVE" }) Assert(service.Contains(value, StringComparison.Ordinal), "storitev manjka: " + value);
Assert(!page.Contains("TODO", StringComparison.OrdinalIgnoreCase), "stran vsebuje placeholder");
Console.WriteLine("F9 intranet: administratorski slovenski pregled in audit dejanja PASS.");

static void Assert(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
static string FindRoot() { var current=new DirectoryInfo(Directory.GetCurrentDirectory());while(current is not null){if(Directory.Exists(Path.Combine(current.FullName,"sql","migrations")))return current.FullName;current=current.Parent;}throw new InvalidOperationException("PIM_Solution ni najden."); }
