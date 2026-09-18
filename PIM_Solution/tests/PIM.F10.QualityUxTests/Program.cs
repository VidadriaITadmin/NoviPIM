using System.Text.RegularExpressions;

// Pogodba štiristopenjske kakovosti 2026-08-27. Isti ValidationLayer mora napajati
// pregled, seznam napak, kartico izdelka in stran pravil.
var root = FindRoot();
var pages = Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages");
var services = Path.Combine(root, "src", "PIM.Intranet", "Services");
var shared = Path.Combine(root, "src", "PIM.Intranet", "Components", "Shared");
var quality = Read(Path.Combine(pages, "Quality.razor"));
var issues = Read(Path.Combine(pages, "ValidationErrors.razor"));
var rules = Read(Path.Combine(pages, "ValidationRules.razor"));
var quarantine = Read(Path.Combine(pages, "RawQuarantine.razor"));
var qualityProducts = Read(Path.Combine(pages, "QualityProducts.razor"));
var translations = Read(Path.Combine(pages, "MissingTranslations.razor"));
var mapping = Read(Path.Combine(pages, "MissingCategories.razor"));
var layer = Read(Path.Combine(services, "ValidationLayer.cs"));
var qualityService = Read(Path.Combine(services, "QualityReadService.cs"));
var governanceService = Read(Path.Combine(services, "GovernanceReadService.cs"));
var fieldPolicy = Read(Path.Combine(services, "QualityFieldPolicy.cs"));
var pimTab = Read(Path.Combine(shared, "PimTab.cs"));
var qualityGateMigration = Read(Path.Combine(root, "sql", "migrations", "194_ProfessionalDataQualityAndChannelGates.sql"));

foreach (var markup in new[] { quality, issues, rules, quarantine, translations, mapping, qualityProducts })
  Assert(markup.Contains("[Authorize", StringComparison.Ordinal), "Vse strani kakovosti morajo zahtevati prijavo.");

foreach (var code in new[] { "ERP_SLO", "ERP_EU/THIRD", "KOMERCIALA", "SPLET" })
  Assert(layer.Contains(code, StringComparison.Ordinal), "Skupni razvrščevalnik mora poznati nivo " + code + ".");
Assert(layer.Contains("IsShared", StringComparison.Ordinal), "Razvrščevalnik mora posebej prepoznati skupne zahteve.");
Assert(layer.Contains("layers.Add(PimValidationLayer.ErpSlo)", StringComparison.Ordinal)
  && layer.Contains("layers.Add(PimValidationLayer.ErpEuThird)", StringComparison.Ordinal)
  && layer.Contains("layers.Add(PimValidationLayer.Splet)", StringComparison.Ordinal),
  "Skupna blokirajoča zahteva mora biti razširjena v oba ERP nivoja in splet.");

Assert(quality.Contains("ValidationLayer.IsShared", StringComparison.Ordinal) && quality.Contains("Skupna", StringComparison.Ordinal), "Skupni profil mora imeti značko.");

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

Assert(quarantine.Contains("<PimState", StringComparison.Ordinal),
  "Karantena mora uporabiti skupno komponento stanja (nalaganje/napaka/prazno), enako kot ostale strani kakovosti.");
Assert(!Regex.IsMatch(quality + issues + rules, "<form|@onsubmit|method=\"post\"", RegexOptions.IgnoreCase), "Pregledi kakovosti ostajajo bralni.");

// ─── Prenova pregleda kakovosti, 2026-08-28 ────────────────────────────────
// Uporabnik je stran razglasil za nepregledno. Razlog je merljiv: vseh 340.227 odprtih
// napak povzroca 16 polj, stran pa jih je razbijala po profilih, zato se je isto polje
// pojavilo v treh razdelkih. Pregled je zdaj urejen po POLJU, tabele profilov pa so
// odmaknjene v svoj zavihek. Te trditve drzijo tisto odlocitev (razen razclenitve po
// polju — glej naslednji razdelek).

Assert(rules.Contains("@page \"/pravila/validacija\"", StringComparison.Ordinal)
  && !pimTab.Contains("pogled=profili", StringComparison.Ordinal),
  "Profili in zahteve sodijo pod nastavitve pravil, ne med operativne zavihke kakovosti.");
Assert(quality.Contains("QualityFieldPolicy", StringComparison.Ordinal),
  "Ime polja mora priti iz skupne politike, ne iz besedila v strani (uporabljeno v pogledu po kategorijah).");

// ─── Popravki kakovosti 2026-08-28 ────────────────────────────────────────────────────────

// F2: kakovost je vprasanje celotnega kataloga. Prej je racunala iz prvega podjetja po sifri
// in je kazala samo DEMO.
Assert(!quality.Contains("Data.GetCurrentOrganizationAsync", StringComparison.Ordinal),
  "Kakovost ne sme racunati iz enega samega podjetja.");
Assert(quality.Contains("Data.GetOrganizationsAsync", StringComparison.Ordinal),
  "Obseg kakovosti mora zajeti vsa aktivna podjetja.");
Assert(quality.Contains("MergeProfiles", StringComparison.Ordinal), "Manjka zdruzevanje profilov cez podjetja.");

// F5: karantena in napaka validacije nista isto in ne nastaneta na istem mestu v toku.
Assert(quality.Contains("Karantena je pred PIM-om", StringComparison.Ordinal)
  && quality.Contains("Napaka validacije je za PIM-om", StringComparison.Ordinal),
  "Stran mora povedati, kaj loci karanteno od napake validacije.");

// F6: stolpec »Kje se popravi« mora povedati, kaj uporabnik na cilju dejansko naredi
// (razlaga zivi v QualityFieldPolicy; pogled po polju, ki jo je uporabljal, je zdaj v
// pogledu po kategorijah).
Assert(fieldPolicy.Contains("string Explanation", StringComparison.Ordinal),
  "Cilj popravka mora nositi razlago, ne samo imena strani.");
foreach (var explained in new[] { "dodaj sliko ali dokument", "poveži dobaviteljevo pot", "vpiši prevod besedila", "popravi se v ERP" })
  Assert(fieldPolicy.Contains(explained, StringComparison.Ordinal), "Manjka razlaga cilja: " + explained + ".");
Assert(!fieldPolicy.Contains("new(\"Lastnosti\"", StringComparison.Ordinal),
  "Pri spletu se lastnosti imenujejo atributi; ime je poenoteno povsod.");


/* ─── Ocena ucinka skupinskega posega (P1-7, pregled 2026-09-08 §3.3) ─────────
   Bralni model mora se vedno znati izmeriti ucinek preslikave kategorij — stran kategorij
   (mapiranje) ga lahko uporabi, tudi ce ga zavihek »Pregled« ne kaze vec (glej spodaj). */
Assert(qualityService.Contains("GetCategoryLeverAsync", StringComparison.Ordinal),
  "Bralni model mora znati izmeriti ucinek preslikave kategorij.");
Assert(qualityService.Contains("map.SourceCategoryToMap", StringComparison.Ordinal)
    && qualityService.Contains("ProductCount", StringComparison.Ordinal),
  "Ocena mora priti iz registra nepreslikanih poti, ne iz priblizka.");
Assert(qualityService.Contains("TotalMissingProductCount", StringComparison.Ordinal),
  "Ocena brez imenovalca (koliko izdelkov je sploh brez kategorije) ne pove nicesar.");


/* ─── Hitrost strani kakovosti (P2-11) ────────────────────────────────────────
   Branja po podjetjih so neodvisna, tekla pa so zaporedno: pri stirih podjetjih in 490 ms na
   klic je bilo to blizu dveh sekund golega cakanja. Znotraj podjetja zaporedje ostane, ker
   obseg potrebuje seznam profilov (nacrt odblokiranja). */
Assert(quality.Contains("Task.WhenAll(Organizations.Select", StringComparison.Ordinal),
  "Branja po podjetjih morajo teci vzporedno; zaporedna zanka je bila merjeno ozko grlo strani.");
Assert(!Regex.IsMatch(quality, @"foreach \(var organization in Organizations\)\s*\{\s*var profiles = await"),
  "Zaporedna zanka po podjetjih se ne sme vrniti.");
Assert(quality.Contains("GetUnblockPlanAsync", StringComparison.Ordinal)
  && governanceService.Contains("GetUnblockPlanAsync", StringComparison.Ordinal),
  "Stevila aktivnih izdelkov in izdelkov s tezavo morajo se vedno priti iz bralnega modela.");


/* ─── Gostota strani pravil (P2-16, pregled 2026-09-08) ───────────────────────
   Stran je nosila 623 vrstic s 623 izbirniki resnosti, zato je ena sprememba pomenila iskanje po
   vsem seznamu. Zahteve ostanejo vse — skrivanje bi bilo laz — dobijo pa filter in posteno stevilo. */
Assert(rules.Contains("id=\"rules-profile\"", StringComparison.Ordinal)
    && rules.Contains("id=\"rules-severity\"", StringComparison.Ordinal)
    && rules.Contains("id=\"rules-search\"", StringComparison.Ordinal),
  "Stran pravil mora imeti filter po profilu, resnosti in polju.");
Assert(rules.Contains("prikazano @VisibleCount", StringComparison.Ordinal)
    && rules.Contains("od @ActiveCount", StringComparison.Ordinal),
  "Filter brez imenovalca zavaja: stran mora povedati, koliko od vseh zahtev je prikazanih.");
Assert(rules.Contains(".Where(Matches)", StringComparison.Ordinal),
  "Filter mora veljati na vrsticah vseh nivojev, ne samo na stevcu.");


/* ─── Izbirnik podjetja na seznamu napak (U1, P2-10) ──────────────────────────
   Stran je tiho kazala samo prvo podjetje: 17.413 izdelkov proti 177.653 na /kakovost. */
Assert(issues.Contains("id=\"issue-organization\"", StringComparison.Ordinal),
  "Seznam napak mora imeti izbirnik podjetja; brez njega je obseg neviden.");
Assert(issues.Contains("Name = \"podjetje\"", StringComparison.Ordinal),
  "Izbrano podjetje mora biti v naslovu, sicer povezave in vrnitev nazaj izgubijo obseg.");
Assert(issues.Contains("Add(\"podjetje\"", StringComparison.Ordinal),
  "Gradnik naslova mora nositi podjetje skozi vse filtre in strani.");


/* ─── Prenova zavihkov kakovosti, 2026-09-10 ──────────────────────────────────
   Uporabnik: kartice-gumbi na dnu /kakovost ("Kje popraviti") so odvec, ko so lahko zavihki, in
   zavihek "Pregled" podvaja nadzorno plosco. Zahteva: karantena in napake validacije postaneta
   prva dva zavihka (v tem vrstnem redu), ker se z njima delo dejansko zacne — po sklopih. Isti
   seznam zavihkov (QualityTabs, PimTab.cs) nosijo vse strani podrocja, da je vrstni red povsod
   enak, kot je ze uveljavljeno na podrocju SAOP (SaopTabs). */

Assert(pimTab.Contains("class QualityTabs", StringComparison.Ordinal),
  "Zavihki kakovosti morajo biti en sam skupen seznam, enako kot SaopTabs.");
{
  var artikliIndex = pimTab.IndexOf("\"artikli\"", StringComparison.Ordinal);
  var karantenaIndex = pimTab.IndexOf("\"karantena\"", StringComparison.Ordinal);
  var napakeIndex = pimTab.IndexOf("\"napake\"", StringComparison.Ordinal);
  Assert(artikliIndex >= 0 && napakeIndex > artikliIndex && karantenaIndex > napakeIndex,
    "Artikli za popravilo morajo biti prvi, napake validacije druge in napake uvoza tretje.");
}
foreach (var page in new[] { quality, issues, quarantine, translations, mapping, qualityProducts })
  Assert(page.Contains("<PimTabs", StringComparison.Ordinal) && page.Contains("QualityTabs.Tabs", StringComparison.Ordinal),
    "Vsaka stran podrocja kakovosti mora prikazati skupni zavihek QualityTabs.");

// Zavihek "Pregled" (privzeti pogled) in kartice-gumbi "Kje popraviti" so odstranjeni.
Assert(!quality.Contains("Pripravljenost za objavo", StringComparison.Ordinal),
  "Razdelek »Pripravljenost za objavo« (nekdanji privzeti zavihek Pregled) je odstranjen.");
Assert(!quality.Contains("hub-grid", StringComparison.Ordinal) && !quality.Contains("PimHubCard", StringComparison.Ordinal),
  "Kartice-gumbi »Kje popraviti« so odstranjene — poti so zdaj zavihki.");
Assert(!quality.Contains("GetFieldGapsAsync", StringComparison.Ordinal),
  "Razclenitev po polju (nekdanji privzeti zavihek) je odstranjena; isto kaze nadzorna plosca.");
Assert(quality.Contains("kakovost/artikli", StringComparison.Ordinal),
  "Bare /kakovost mora voditi na operativno pripravljenost artiklov.");
Assert(qualityProducts.Contains("IsErpReady", StringComparison.Ordinal)
  && qualityProducts.Contains("IsWebReady", StringComparison.Ordinal)
  && qualityProducts.Contains("Ročni zadržek", StringComparison.Ordinal),
  "Operativni pogled mora prikazati kanalsko pripravljenost in ročni zadržek.");
foreach (var contract in new[] { "ProductChannelReadiness", "ProductHold", "TR_OutboxMessage_ErpQualityGate", "ERP_L1" })
  Assert(qualityGateMigration.Contains(contract, StringComparison.Ordinal), "Manjka pogodba profesionalne kakovosti: " + contract);

// Izvoz odprtih napak: isti filtri kot pogled, vrstica obarvana po resnosti (rdeca/oranzna) —
// enaka oblika izvoza kot na strani Izdelki.
Assert(issues.Contains("izvoz/kakovost-napake.xlsx", StringComparison.Ordinal),
  "Napake validacije morajo imeti izvoz v Excel, enako kot stran Izdelki.");
var qualityExport = Read(Path.Combine(services, "QualityIssueExportService.cs"));
Assert(qualityExport.Contains("WorkbookCellTone.Missing", StringComparison.Ordinal)
    && qualityExport.Contains("WorkbookCellTone.Warning", StringComparison.Ordinal),
  "Izvoz napak mora obarvati vrstico po resnosti: rdeca za napako, oranzna za opozorilo.");
var workbookWriter = Read(Path.Combine(root, "src", "PIM.Operations", "WorkbookWriter.cs"));
Assert(workbookWriter.Contains("Warning,", StringComparison.Ordinal) || Regex.IsMatch(workbookWriter, @"Warning,?\s*\r?\n\s*}"),
  "WorkbookCellTone mora poznati opozorilni ton (bleda oranzna), ne samo manjkajoce/zahtevano.");

// Karantena: filtri kot na strani Izdelki (dropdown + iskanje) in izvoz, ki uposteva filtre.
foreach (var id in new[] { "quarantine-organization", "quarantine-source", "quarantine-entity", "quarantine-search" })
  Assert(quarantine.Contains($"id=\"{id}\"", StringComparison.Ordinal), "Karantena mora imeti filter: " + id);
Assert(quarantine.Contains("izvoz/karantena.xlsx", StringComparison.Ordinal),
  "Karantena mora imeti izvoz v Excel, ki uposteva trenutne filtre.");

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
