var root = FindRoot();
var failures = new List<string>();
var service = Read("src/PIM.Intranet/Services/IntranetDataService.cs");
var page = Read("src/PIM.Intranet/Components/Pages/Outbound.razor");
Contains(page, "@page \"/outbound\"", "Manjka pot /outbound.");
Contains(page, "ADMIN,CATALOG_EDITOR,COMMERCIAL", "Manjkajo dovoljene vloge.");
foreach (var label in new[] { "Cilj", "Operacija", "Entiteta", "Polja", "Poskusi", "Naslednji poskus", "Odziv", "Odklon", "Odobri", "Prekliči", "Pošlji znova" })
  Contains(page, label, $"Manjka slovenska oznaka {label}.");
foreach (var procedure in new[] { "intranet.GetOutboundMessages", "out.ApproveMessage", "out.CancelMessage", "out.RequeueOutboxMessage" })
  Contains(service, procedure, $"Servis ne uporablja {procedure}.");
if ((page + service).Contains("HttpClient", StringComparison.OrdinalIgnoreCase)) failures.Add("Intranet ne sme neposredno klicati HTTP.");
if (failures.Count > 0) { failures.ForEach(Console.Error.WriteLine); return 1; }
Console.WriteLine("F8 intranet: slovenski monitor in proceduralna dejanja PASS."); return 0;

string FindRoot()
{
  var current = new DirectoryInfo(Directory.GetCurrentDirectory());
  while (current is not null) { if (Directory.Exists(Path.Combine(current.FullName, "src"))) return current.FullName; current=current.Parent; }
  throw new InvalidOperationException("PIM_Solution ni najden.");
}
string Read(string path) { var full=Path.Combine(root,path); if(File.Exists(full))return File.ReadAllText(full);failures.Add("Manjka "+path);return ""; }
void Contains(string value,string expected,string failure) { if(!value.Contains(expected,StringComparison.OrdinalIgnoreCase))failures.Add(failure); }
