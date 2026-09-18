using PIM.Intranet.Services;

var nw = MediaUrlPolicy.Normalize("//pim.nowodvorski.com/media/files/203.jpg");
Assert(nw.Href == "https://pim.nowodvorski.com/media/files/203.jpg", "NW naslov mora dobiti https:.");
Assert(nw.Note == "Dodan https:", "Popravljeni naslov mora ohraniti sled normalizacije.");

var http = MediaUrlPolicy.Normalize("http://primer.si/slika.jpg");
Assert(http.Href == "http://primer.si/slika.jpg", "HTTP naslova ne smemo tiho nadgraditi.");
Assert(http.Note == "Nešifrirana povezava", "HTTP naslov mora biti označen kot nešifriran.");

var unsafeUrl = MediaUrlPolicy.Normalize("javascript:alert(1)");
Assert(unsafeUrl.Href is null, "Izvedljiva shema ne sme postati povezava.");
Assert(unsafeUrl.Note == "Naslov ni varna spletna povezava", "Nevarna shema mora imeti razlago.");

var empty = MediaUrlPolicy.Normalize(" \u200B ");
Assert(empty.Href is null && empty.Display == "—" && empty.Note == "Naslov ni zapisan", "Prazen naslov mora biti pošteno prazen.");

var trimmed = MediaUrlPolicy.Normalize("  www.primer.si/slika.jpg\uFEFF ");
Assert(trimmed.Href == "https://www.primer.si/slika.jpg", "Presledki in nevidni robni znaki se morajo odstraniti.");

AssertLayers("ERP_L1_SLO", "ERP", true, false, PimValidationLayer.ErpSlo);
AssertLayers("ERP_L1_EU", "ERP", true, false, PimValidationLayer.ErpEuThird);
AssertLayers("ERP_L1_THIRD", "ERP", true, false, PimValidationLayer.ErpEuThird);
AssertLayers("COMMERCIAL_L2", "COMMERCIAL", false, false, PimValidationLayer.Komerciala);
AssertLayers("WEB_svetila_si", "WEB", false, true, PimValidationLayer.Splet);
AssertLayers("WEB_videlektro", "WEB", false, true, PimValidationLayer.Splet);
AssertLayers("ERP_L1", "ERP", false, false, PimValidationLayer.ErpSlo);
AssertLayers("WEB_B2C", "WEB", false, false, PimValidationLayer.Splet);
AssertLayers("SHARED_CORE", "SHARED", true, true,
  PimValidationLayer.ErpSlo, PimValidationLayer.ErpEuThird, PimValidationLayer.Splet);

var now = new DateTime(2026, 8, 27, 12, 0, 0, DateTimeKind.Utc);
Assert(PimFormat.Ago(now.AddHours(-2), now) == "pred 2 h", "Svežina mora imeti enoten zapis ur.");
Assert(PimFormat.Ago(null, now) == "—", "Manjkajoča svežina ne sme postati izmišljen čas.");

// ─── Politika polj kakovosti ───────────────────────────────────────────────
// Ime polja se ne prevaja iz slovarja: register zahtev se spreminja, izmisljen slovar bi se
// z njim razsel. Prevaja se samo predpona entitete, ki pride iz imena kanonicne tabele.
Expect(QualityFieldPolicy.EntityLabel("ProductMedia.Url") == "Medij", "Predpona entitete se prevede.");
Expect(QualityFieldPolicy.EntityLabel("ProductCommercial.CustomsTariff") == "Trgovinski podatki", "Trgovinski podatki so svoja entiteta.");
Expect(QualityFieldPolicy.EntityLabel("Cudno.Polje") == "Cudno", "Neznana predpona ostane, kot je.");
Expect(QualityFieldPolicy.FieldName("ProductText.WEB_TITLE.sl") == "WEB_TITLE.sl", "Ime polja obdrzi jezik.");
Expect(QualityFieldPolicy.FieldName("BrezPike") == "BrezPike", "Koda brez pike ostane cela.");

Expect(QualityFieldPolicy.FixTarget("ProductMedia.Url").Href == "mediji", "Manjkajoca slika se popravi na strani Mediji.");
Expect(QualityFieldPolicy.FixTarget("ProductCategory.CategoryPath").Href == "kakovost/kategorije", "Pot kategorije je stvar preslikave.");
Expect(QualityFieldPolicy.FixTarget("ProductAttribute.CategoryRequired").Href == "kakovost/kategorije", "Zahtevana kategorija je prav tako preslikava, ceprav je zapisana kot lastnost.");
Expect(QualityFieldPolicy.FixTarget("ProductText.WEB_TITLE.en").Href == "kakovost/prevodi", "Besedilo v tujem jeziku je manjkajoc prevod.");
Expect(QualityFieldPolicy.FixTarget("ProductText.WEB_TITLE.sl").Href == "izvozi/mnozicno", "Besedilo v slovenscini ni prevod, ampak manjkajoc vnos.");
Expect(QualityFieldPolicy.FixTarget("Product.EAN").Href == "saop/polja", "Polja izdelka prihajajo iz SAOP.");
Expect(QualityFieldPolicy.FixTarget("Cudno.Polje").Href is null, "Za neznano polje ne izmisljujemo strani.");
Expect(QualityFieldPolicy.IssuesHref("ProductText.WEB_TITLE.sl") == "kakovost/napake?polje=ProductText.WEB_TITLE.sl",
  "Napake polja se odprejo z obstojecim filtrom.");

// ─── Navigacija po popravkih 2026-08-28 ───────────────────────────────────
// Uporabnik je odpisal dve postavki menija in preimenoval stiri. Test drzi odlocitev na mestu,
// da se stara imena in odpisani strani ne vrnejo tiho nazaj.
var navItems = PimNavigation.Sections.SelectMany(section => section.Items).ToList();
var navRoutes = navItems.Select(item => item.Route).ToList();
var navLabels = navItems.Select(item => item.Label).ToList();

Expect(!navRoutes.Contains("izvozi"), "»Izvozni profili in datoteke« je podvajal »Izhod na splet« in ne sodi vec v meni.");
Expect(!navRoutes.Contains("partnerji"), "Partnerji odpadejo: stranke se locijo po vrsti (kupec, dobavitelj, proizvajalec).");
Expect(navRoutes.Distinct().Count() == navRoutes.Count, "Vsaka destinacija sme biti v meniju natanko enkrat.");

foreach (var retired in new[] { "Zajem in preslikave", "Validacija in vrzeli", "SAOP — pisanje nazaj", "Splet — kaj gre ven", "Izvozni profili in datoteke", "Partnerji" })
  Expect(!navLabels.Contains(retired), $"Ime »{retired}« je uporabnik zavrnil in se ne sme vrniti.");

foreach (var expected in new[] { "Zajem podatkov", "Kakovost podatkov", "Izhod v SAOP", "Izhod na splet" })
  Expect(navLabels.Contains(expected), $"V meniju manjka postavka »{expected}«.");

WorkerConsoleChecks.Run();
WorkerSchedulerChecks.Run();
Console.WriteLine("F10 intranet logic PASS.");

/* ─── Kontrast palete po WCAG (P3-23, pregled 2026-09-08) ─────────────────────
   Pregled zahteva »kontrast z orodjem«. Orodje je to: barve se preberejo iz :root v app.css in
   razmerje se izracuna po WCAG 2.1 (relativna svetlost + (L1+0.05)/(L2+0.05)). Prag za navadno
   besedilo je 4,5 : 1.

   Merjeno 2026-09-09 je padlo troje: prigusen tekst na podlagi strani 4,47 : 1, znacka »dobro«
   3,58 : 1 in znacka »napaka« 4,41 : 1. Znacki sta imeli barvo, izbrano za polno podlago, stali
   pa sta na svoji bledi. Brez tega testa bi se to vrnilo ob prvi spremembi palete. */
var cssPath = Path.Combine(FindSolutionRoot(), "src", "PIM.Intranet", "wwwroot", "app.css");
Assert(File.Exists(cssPath), "Manjka app.css s paleto.");
var appCss = File.ReadAllText(cssPath);

// Nekatere barve so vzdevki (--pim-accent-link: var(--pim-primary)), zato se sklic razresi.
// Brez tega bi test preveril samo polovico palete in molcal o drugi.
string Token(string name)
{
  for (var hop = 0; hop < 5; hop++)
  {
    var match = System.Text.RegularExpressions.Regex.Match(appCss, @"--" + name + @":\s*(#[0-9a-fA-F]{6}|var\(--[a-z-]+\))");
    Assert(match.Success, "V paleti manjka barva --" + name + ".");
    var value = match.Groups[1].Value;
    if (value.StartsWith("#", StringComparison.Ordinal)) return value;
    name = value[6..^1];
  }
  throw new InvalidOperationException("Barva --" + name + " se sklicuje v krogu.");
}

foreach (var (label, foreground, background) in new[]
{
  ("besedilo na kartici", Token("pim-text"), Token("pim-surface")),
  ("besedilo na podlagi strani", Token("pim-text"), Token("pim-bg")),
  ("prigušeno besedilo na kartici", Token("pim-text-muted"), Token("pim-surface")),
  ("prigušeno besedilo na podlagi strani", Token("pim-text-muted"), Token("pim-bg")),
  ("mehko besedilo na kartici", Token("pim-text-soft"), Token("pim-surface")),
  ("povezava na kartici", Token("pim-accent-link"), Token("pim-surface")),
  ("značka dobro", Token("pim-good-text"), Token("pim-good-bg")),
  ("značka opozorilo", Token("pim-warn-text"), Token("pim-warn-bg")),
  ("značka napaka", Token("pim-bad-text"), Token("pim-bad-bg")),
  ("značka info", Token("pim-info-text"), Token("pim-info-bg")),
  ("značka nevtralno", Token("pim-neutral-text"), Token("pim-neutral-bg")),
})
{
  var contrast = Contrast(foreground, background);
  Assert(contrast >= 4.5,
    $"Kontrast pod pragom WCAG AA: {label} ({foreground} na {background}) = {contrast:0.00} : 1, potrebno 4,5 : 1.");
}

Console.WriteLine("F10 kontrast palete: vseh 11 parov nad 4,5 : 1.");

static double Contrast(string first, string second)
{
  var a = Luminance(first);
  var b = Luminance(second);
  var high = Math.Max(a, b);
  var low = Math.Min(a, b);
  return (high + 0.05) / (low + 0.05);
}

static double Luminance(string hex)
{
  var value = hex.TrimStart('#');
  double Channel(int offset)
  {
    var raw = Convert.ToInt32(value.Substring(offset, 2), 16) / 255.0;
    return raw <= 0.03928 ? raw / 12.92 : Math.Pow((raw + 0.055) / 1.055, 2.4);
  }
  return 0.2126 * Channel(0) + 0.7152 * Channel(2) + 0.0722 * Channel(4);
}

static string FindSolutionRoot()
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


static void AssertLayers(string code, string scope, bool blocksErp, bool blocksWeb, params PimValidationLayer[] expected)
{
  var actual = ValidationLayer.Resolve(code, scope, blocksErp, blocksWeb);
  Assert(actual.SequenceEqual(expected), $"Napačni nivoji za {code}: {string.Join(", ", actual)}.");
}

static void Assert(bool condition, string message)
{
  if (!condition) throw new InvalidOperationException(message);
}

static void Expect(bool condition, string message)
{
  if (condition) return;
  Console.Error.WriteLine("NAPAKA: " + message);
  Environment.Exit(1);
}
