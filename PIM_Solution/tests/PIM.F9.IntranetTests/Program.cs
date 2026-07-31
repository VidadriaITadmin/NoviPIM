var root = FindRoot();
var page = File.ReadAllText(Path.Combine(root, "src/PIM.Intranet/Components/Pages/SystemIntegrations.razor"));
var service = File.ReadAllText(Path.Combine(root, "src/PIM.Intranet/Services/IntranetDataService.cs"));
foreach (var value in new[] { "@page \"/system/integracije\"", "Authorize(Roles = \"ADMIN\"", "Integracije sistema", "Zadnji srčni utrip", "Potrdi", "Razreši" }) Assert(page.Contains(value, StringComparison.Ordinal), "stran manjka: " + value);
foreach (var value in new[] { "GetSystemIntegrations", "AcknowledgeAlert", "ResolveAlert", "@OrganizationId", "@Actor" }) Assert(service.Contains(value, StringComparison.Ordinal), "storitev manjka: " + value);
Assert(!page.Contains("TODO", StringComparison.OrdinalIgnoreCase), "stran vsebuje placeholder");
Console.WriteLine("F9 intranet: administratorski slovenski pregled in audit dejanja PASS.");

static void Assert(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
static string FindRoot() { var current=new DirectoryInfo(Directory.GetCurrentDirectory());while(current is not null){if(Directory.Exists(Path.Combine(current.FullName,"sql","migrations")))return current.FullName;current=current.Parent;}throw new InvalidOperationException("PIM_Solution ni najden."); }
