using System.Text.RegularExpressions;

// Pogodba štiristopenjske kakovosti 2026-08-27. Isti ValidationLayer mora napajati
// pregled, seznam napak, kartico izdelka in stran pravil.
var root = FindRoot();
var pages = Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages");
var services = Path.Combine(root, "src", "PIM.Intranet", "Services");
var quality = Read(Path.Combine(pages, "Quality.razor"));
var issues = Read(Path.Combine(pages, "ValidationErrors.razor"));
var rules = Read(Path.Combine(pages, "ValidationRules.razor"));
var quarantine = Read(Path.Combine(pages, "RawQuarantine.razor"));
var layer = Read(Path.Combine(services, "ValidationLayer.cs"));
var qualityService = Read(Path.Combine(services, "QualityReadService.cs"));
var governanceService = Read(Path.Combine(services, "GovernanceReadService.cs"));

foreach (var markup in new[] { quality, issues, rules, quarantine })
  Assert(markup.Contains("[Authorize", StringComparison.Ordinal), "Vse strani kakovosti morajo zahtevati prijavo.");

foreach (var code in new[] { "ERP_SLO", "ERP_EU/THIRD", "KOMERCIALA", "SPLET" })
  Assert(layer.Contains(code, StringComparison.Ordinal), "Skupni razvrščevalnik mora poznati nivo " + code + ".");
Assert(layer.Contains("IsShared", StringComparison.Ordinal), "Razvrščevalnik mora posebej prepoznati skupne zahteve.");
Assert(layer.Contains("layers.Add(PimValidationLayer.ErpSlo)", StringComparison.Ordinal)
  && layer.Contains("layers.Add(PimValidationLayer.ErpEuThird)", StringComparison.Ordinal)
  && layer.Contains("layers.Add(PimValidationLayer.Splet)", StringComparison.Ordinal),
  "Skupna blokirajoča zahteva mora biti razširjena v oba ERP nivoja in splet.");

Assert(quality.Contains("Enum.GetValues<PIM.Intranet.Services.PimValidationLayer>()", StringComparison.Ordinal), "Pregled mora izpisati vse nivoje iz skupnega šifranta.");
Assert(quality.Contains("GetValidationLayerSummariesAsync", StringComparison.Ordinal), "Števci morajo prihajati iz skupne storitve.");
Assert(quality.Contains("AffectedProductCount", StringComparison.Ordinal), "Stran mora prikazati natančen števec prizadetih izdelkov iz storitve.");
Assert(quality.Contains("ne blokirajo", StringComparison.OrdinalIgnoreCase), "Komercialni nivo mora izrecno povedati, da ne blokira.");
Assert(quality.Contains("Spletno mesto", StringComparison.Ordinal) && quality.Contains("SelectedWebSite", StringComparison.Ordinal), "Spletni nivo mora biti zožljiv po spletnem mestu.");
Assert(quality.Contains("kakovost/napake?nivo=", StringComparison.Ordinal), "Vsaka kartica nivoja mora voditi na filtrirane napake.");
Assert(quality.Contains("ValidationLayer.IsShared", StringComparison.Ordinal) && quality.Contains("Skupna", StringComparison.Ordinal), "Skupni profil mora imeti značko.");
foreach (var hub in new[] { "Napake validacije", "Karantena", "Manjkajoči prevodi", "Nepreslikane kategorije" })
  Assert(quality.Contains(hub, StringComparison.Ordinal), "Pregled mora ohraniti delovno povezavo: " + hub);

Assert(issues.IndexOf("id=\"issue-layer\"", StringComparison.Ordinal) < issues.IndexOf("id=\"issue-search\"", StringComparison.Ordinal),
  "Nivo mora biti prvi filter.");
foreach (var query in new[] { "Name = \"nivo\"", "Name = \"spletisce\"", "Name = \"profil\"", "Name = \"resnost\"", "Name = \"polje\"" })
  Assert(issues.Contains(query, StringComparison.Ordinal), "Manjka deljivi filter: " + query);
Assert(issues.Contains("LayerDraft == \"SPLET\"", StringComparison.Ordinal), "Spletno mesto mora biti vidno samo pri spletnem nivoju.");
Assert(issues.Contains("ProfilesForLayer", StringComparison.Ordinal), "Profil mora biti ožji znotraj izbranega nivoja.");
Assert(issues.Contains("GetIssuesForProfilesAsync", StringComparison.Ordinal), "Izbrani nivo mora zožiti poizvedbo pred stranjenjem.");
Assert(governanceService.Contains("COUNT_BIG(DISTINCT", StringComparison.Ordinal), "Števci nivoja morajo šteti različne izdelke.");
Assert(qualityService.Contains("profile.ProfileCode IN", StringComparison.Ordinal), "Poizvedba nivoja mora uporabiti izbrane profile.");
Assert(issues.Contains("new(\"Nivo\")", StringComparison.Ordinal), "Nivo mora biti prvi stolpec tabele.");
Assert(issues.Contains("IsShared(issue)", StringComparison.Ordinal), "Skupne napake morajo biti označene.");
foreach (var fragment in new[] { "\"erp\"", "\"komerciala\"", "\"splet\"" })
  Assert(issues.Contains(fragment, StringComparison.Ordinal), "Napaka mora voditi na kanalski zavihek " + fragment + ".");
Assert(!issues.Contains("ResolveIssue", StringComparison.OrdinalIgnoreCase), "Validacijske napake ne sme biti mogoče ročno zapreti.");

Assert(rules.Contains("Enum.GetValues<PimValidationLayer>()", StringComparison.Ordinal), "Pravila morajo biti razvrščena po istih nivojih.");
Assert(rules.Contains("Zahteve, ki čakajo na polje", StringComparison.Ordinal), "Neaktivne zahteve morajo biti ločen viden delovni seznam.");
Assert(rules.Contains("!row.Requirement.IsActive", StringComparison.Ordinal), "Čakajoče zahteve morajo res izbrati IsActive = 0.");
Assert(rules.Contains("GetFieldRequirementsAsync", StringComparison.Ordinal), "Zahteve morajo izvirati iz registra.");

foreach (var stateClass in new[] { "loading-state", "error-state", "empty-state" })
  Assert(quarantine.Contains(stateClass, StringComparison.Ordinal), "Karantena mora ohraniti stanje " + stateClass + ".");
Assert(!Regex.IsMatch(quality + issues + rules, "<form|@onsubmit|method=\"post\"", RegexOptions.IgnoreCase), "Pregledi kakovosti ostajajo bralni.");

Console.WriteLine("F10 quality UX contract PASS.");

static string Read(string path)
{
  if (!File.Exists(path)) throw new InvalidOperationException("Manjka datoteka: " + path);
  return File.ReadAllText(path);
}

static void Assert(bool condition, string message)
{
  if (!condition) throw new InvalidOperationException(message);
}

static string FindRoot()
{
  foreach (var start in new[] { Directory.GetCurrentDirectory(), AppContext.BaseDirectory })
  {
    var current = new DirectoryInfo(start);
    while (current is not null)
    {
      if (File.Exists(Path.Combine(current.FullName, "PIM.sln"))) return current.FullName;
      current = current.Parent;
    }
  }
  throw new InvalidOperationException("PIM_Solution ni najden.");
}
