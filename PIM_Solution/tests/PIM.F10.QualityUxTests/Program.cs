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
var fieldPolicy = Read(Path.Combine(services, "QualityFieldPolicy.cs"));

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
// Filter po spletnem mestu je uporabnik 2026-08-28 zavrnil: stran hkrati pokriva ERP,
// komercialo in splet, spletno mesto pa zozi samo enega od stirih nivojev. Zozevanje po
// spletnem mestu ostane na strani z napakami, kjer je izbrani nivo ze znan.
Assert(!quality.Contains("SelectedWebSite", StringComparison.Ordinal),
  "Filtra po spletnem mestu na pregledu kakovosti ni vec.");
Assert(!quality.Contains("Vsa spletna mesta", StringComparison.Ordinal),
  "Napis »Vsa spletna mesta« je na pregledu odpisan.");
Assert(issues.Contains("spletisce", StringComparison.Ordinal),
  "Zozevanje po spletnem mestu mora ostati na strani z napakami.");
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

// ─── Prenova pregleda kakovosti, 2026-08-28 ────────────────────────────────
// Uporabnik je stran razglasil za nepregledno. Razlog je merljiv: vseh 340.227 odprtih
// napak povzroca 16 polj, stran pa jih je razbijala po profilih, zato se je isto polje
// pojavilo v treh razdelkih. Pregled je zdaj urejen po POLJU, tabele profilov pa so
// odmaknjene v svoj zavihek. Te trditve drzijo tisto odlocitev.

Assert(quality.Contains("GetFieldGapsAsync", StringComparison.Ordinal),
  "Pregled mora imeti razclenitev po polju — to je edina razseznost, po kateri se delo res deli.");
Assert(governanceService.Contains("GetFieldGapsAsync", StringComparison.Ordinal),
  "Razclenitev po polju mora prihajati iz bralnega modela, ne iz strani.");
// Razdelek »Nacrt odblokiranja« je uporabnik 2026-08-28 razglasil za nesmiselnega in ga je
// zahteval odstraniti. Bralni model ostane: stran iz njega se vedno vzame stevilo aktivnih
// izdelkov in izdelkov s tezavo — to sta imenovalca delezev v tabeli vrzeli.
Assert(!quality.Contains("plan-title", StringComparison.Ordinal) && !quality.Contains("Načrt odblokiranja", StringComparison.Ordinal),
  "Nacrta odblokiranja na strani ni vec.");
Assert(!quality.Contains("plan-chart", StringComparison.Ordinal) && !quality.Contains("BestStep", StringComparison.Ordinal),
  "Z nacrtom odpade tudi njegov graf.");
Assert(quality.Contains("GetUnblockPlanAsync", StringComparison.Ordinal)
  && governanceService.Contains("GetUnblockPlanAsync", StringComparison.Ordinal),
  "Stevila aktivnih izdelkov in izdelkov s tezavo morajo se naprej priti iz bralnega modela.");

// Odstotek na nivoju je delez izdelkov BREZ napake. Prej je stala gola stevilka »18,1 %«
// in iz strani ni bilo mogoce ugotoviti, cesa je to odstotek.
Assert(quality.Contains("pripravljenih", StringComparison.Ordinal),
  "Ob odstotku mora pisati, cesa je odstotek.");

// Stiri visoke kartice in stirje zaporedni razdelki profilov so bili glavni vir nepreglednosti.
Assert(!quality.Contains("validation-level-grid", StringComparison.Ordinal),
  "Stirih visokih kartic nad seznamom ni vec.");
Assert(quality.Contains("page-tabs", StringComparison.Ordinal) && quality.Contains("pogled=profili", StringComparison.Ordinal),
  "Profili in zahteve morajo dobiti svoj zavihek, ne cetrtega zaporednega razdelka na pregledu.");
Assert(quality.Contains("QualityFieldPolicy", StringComparison.Ordinal),
  "Ime polja in cilj popravka morata biti skupna politika, ne besedilo v strani.");
Assert(fieldPolicy.Contains("kakovost/napake?polje=", StringComparison.Ordinal)
  && quality.Contains("QualityFieldPolicy.IssuesHref", StringComparison.Ordinal),
  "Vsaka vrstica polja mora voditi na svoje napake, naslov pa sestavi politika in ne stran.");

// ─── Popravki kakovosti 2026-08-28 ────────────────────────────────────────────────────────

// F2: kakovost je vprasanje celotnega kataloga. Prej je racunala iz prvega podjetja po sifri
// in je kazala samo DEMO.
Assert(!quality.Contains("Data.GetCurrentOrganizationAsync", StringComparison.Ordinal),
  "Kakovost ne sme racunati iz enega samega podjetja.");
Assert(quality.Contains("Data.GetOrganizationsAsync", StringComparison.Ordinal),
  "Obseg kakovosti mora zajeti vsa aktivna podjetja.");
foreach (var merge in new[] { "MergeProfiles", "MergeSummaries", "MergeGaps" })
  Assert(quality.Contains(merge, StringComparison.Ordinal), "Manjka zdruzevanje cez podjetja: " + merge + ".");

// F5: karantena in napaka validacije nista isto in ne nastaneta na istem mestu v toku.
Assert(quality.Contains("Karantena je pred PIM-om", StringComparison.Ordinal)
  && quality.Contains("Napaka validacije je za PIM-om", StringComparison.Ordinal),
  "Stran mora povedati, kaj loci karanteno od napake validacije.");

// F6: stolpec »Kje se popravi« mora povedati, kaj uporabnik na cilju dejansko naredi.
Assert(fieldPolicy.Contains("string Explanation", StringComparison.Ordinal),
  "Cilj popravka mora nositi razlago, ne samo imena strani.");
Assert(quality.Contains("@target.Explanation", StringComparison.Ordinal),
  "Razlaga cilja mora biti vidna v tabeli, ne samo v namigu.");
foreach (var explained in new[] { "dodaj sliko ali dokument", "poveži dobaviteljevo pot", "vpiši prevod besedila", "popravi se v ERP" })
  Assert(fieldPolicy.Contains(explained, StringComparison.Ordinal), "Manjka razlaga cilja: " + explained + ".");
Assert(!fieldPolicy.Contains("new(\"Lastnosti\"", StringComparison.Ordinal),
  "Pri spletu se lastnosti imenujejo atributi; ime je poenoteno povsod.");


/* ─── Ocena ucinka skupinskega posega (P1-7, pregled 2026-09-08 §3.3) ─────────
   Zahteva pregleda: ob polju mora pisati, koliko izdelkov ta poseg sploh doseze. Ocena mora
   biti izmerjena in ne domnevana; prav pri kategorijah je razlika bistvena, ker nepreslikane
   poti pokrijejo le delcek izdelkov brez kategorije. */
Assert(qualityService.Contains("GetCategoryLeverAsync", StringComparison.Ordinal),
  "Bralni model mora znati izmeriti ucinek preslikave kategorij.");
Assert(qualityService.Contains("map.SourceCategoryToMap", StringComparison.Ordinal)
    && qualityService.Contains("ProductCount", StringComparison.Ordinal),
  "Ocena mora priti iz registra nepreslikanih poti, ne iz priblizka.");
Assert(qualityService.Contains("TotalMissingProductCount", StringComparison.Ordinal),
  "Ocena brez imenovalca (koliko izdelkov je sploh brez kategorije) ne pove nicesar.");
Assert(quality.Contains("QualityRead.GetCategoryLeverAsync", StringComparison.Ordinal),
  "Stran kakovosti mora oceno prebrati, ne izracunati sama.");
Assert(quality.Contains("lever-note", StringComparison.Ordinal) && quality.Contains("lever-weak", StringComparison.Ordinal),
  "Sibek vzvod mora biti viden; stevilka, ki je videti kot vsaka druga, ne prepreci zaman opravljenega dela.");
Assert(Regex.IsMatch(quality, @"CategoryLever\.CoverageShare < 5"),
  "Meja, pod katero je poseg oznacen kot sibek, mora biti v kodi in ne v glavi bralca.");
var qualityCss = Read(Path.Combine(pages, "Quality.razor.css"));
Assert(qualityCss.Contains(".lever-note", StringComparison.Ordinal),
  "Ocena mora imeti svoj slog; izolirani slog Blazorja velja samo za oznako svoje komponente.");


/* ─── Hitrost strani kakovosti (P2-11) ────────────────────────────────────────
   Branja po podjetjih so neodvisna, tekla pa so zaporedno: pri stirih podjetjih in 490 ms na
   klic je bilo to blizu dveh sekund golega cakanja. Znotraj podjetja zaporedje ostane, ker
   obseg in vrzeli potrebujeta seznam profilov. */
Assert(quality.Contains("Task.WhenAll(Organizations.Select", StringComparison.Ordinal),
  "Branja po podjetjih morajo teci vzporedno; zaporedna zanka je bila merjeno ozko grlo strani.");
Assert(!Regex.IsMatch(quality, @"foreach \(var organization in Organizations\)\s*\{\s*var profiles = await"),
  "Zaporedna zanka po podjetjih se ne sme vrniti.");
Assert(quality.Contains("GetValidationLayerSummariesAsync(organization.OrganizationId, profiles)", StringComparison.Ordinal),
  "Znotraj podjetja mora obseg se vedno dobiti seznam profilov, sicer bi vzporednost spremenila izid.");


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
