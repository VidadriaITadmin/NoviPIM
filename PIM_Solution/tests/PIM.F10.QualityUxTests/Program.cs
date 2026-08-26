using System.Text.RegularExpressions;

// Pogodbeni test UX skladnosti kakovosti: strani /napake-validacije in /karantena.
// Obseg je namenoma ozek: samo predstavitev in dostopnost obeh strani.
// Referenca: ../PIM_test/UX_pictures/Kakovost.png (naslov, zavihki, KPI, kakovost po
// profilih z merilniki, najpogostejše napake, filtrirana tabela in karantena).
// Test ne sme zahtevati novih poizvedb, novih stolpcev, novih vrednosti ali akcij pisanja.

var root = FindRoot();
var pages = Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages");
var issuesRazorPath = Path.Combine(pages, "ValidationErrors.razor");
var issuesCssPath = Path.Combine(pages, "ValidationErrors.razor.css");
var quarantineRazorPath = Path.Combine(pages, "RawQuarantine.razor");
var quarantineCssPath = Path.Combine(pages, "RawQuarantine.razor.css");

Assert(File.Exists(issuesRazorPath), "Manjka stran kakovosti: " + issuesRazorPath);
Assert(File.Exists(issuesCssPath), "Manjka izoliran slog kakovosti: " + issuesCssPath);
Assert(File.Exists(quarantineRazorPath), "Manjka stran karantene: " + quarantineRazorPath);
Assert(File.Exists(quarantineCssPath), "Manjka izoliran slog karantene: " + quarantineCssPath);

var issues = File.ReadAllText(issuesRazorPath);
var issuesCss = File.ReadAllText(issuesCssPath);
var quarantine = File.ReadAllText(quarantineRazorPath);
var quarantineCss = File.ReadAllText(quarantineCssPath);

// ---------------------------------------------------------------------------
// A. /napake-validacije in /kakovost/napake
// ---------------------------------------------------------------------------
//
// Obseg te strani je bil razsirjen z odlocitvijo uporabnika: stran je prej brala vse odprte
// tezave podjetja naenkrat (3.004.688 aktivnih vrstic v val.ProductIssue) in filtrirala v
// pomnilniku. Zdaj stranici po izdelku nad intranet.GetQualityIssues in pokaze resnost,
// obseg blokade in manjkajoce polje. Pogodba je zato posodobljena skupaj s stranjo; varovalke
// so ostale in so ostrejse.

Assert(issues.Contains("@attribute [Authorize]", StringComparison.Ordinal), "Stran kakovosti mora ostati zascitena z [Authorize].");
Assert(Regex.IsMatch(issues, "<PimPage Title=\"Napake validacije\""), "Stran mora uporabiti skupno glavo PimPage.");
Assert(issues.Contains("Crumbs=\"Crumbs\"", StringComparison.Ordinal), "Podstran mora imeti drobtine nazaj na kakovost.");

// A1. KPI povzetek izhaja iz podatkov in vodi na svoj filtriran seznam.
var kpiGrid = Regex.Match(issues, "<section class=\"kpi-grid\"[^>]*>");
Assert(kpiGrid.Success, "KPI povzetek mora biti poimenovan sklop <section class=\"kpi-grid\">.");
var kpiLabel = Regex.Match(kpiGrid.Value, "aria-labelledby=\"([^\"]+)\"");
Assert(kpiLabel.Success, "KPI sklop mora imeti aria-labelledby.");
AssertHeading(issues, kpiLabel.Groups[1].Value, "KPI sklopa");
Assert(Regex.Matches(issues, "<PimStat ").Count == 5, "Povzetek ima pet kartic: odprto, prizadeti izdelki in trije obsegi blokade.");
foreach (var target in new[] { "kakovost/napake?blokira=ERP", "kakovost/napake?blokira=WEB", "kakovost/napake?blokira=NONE" })
  Assert(issues.Contains(target, StringComparison.Ordinal), "Stevilka mora voditi na filtriran seznam, ki jo pojasni: " + target);

// A2. Iskalni sklop je poimenovan, vsaka kontrola pa ima svojo oznako.
var issuesToolbar = Regex.Match(issues, "<section class=\"ui-card toolbar\"[^>]*>");
Assert(issuesToolbar.Success, "Orodna vrstica napak mora ostati <section class=\"ui-card toolbar\">.");
Assert(issuesToolbar.Value.Contains("role=\"search\"", StringComparison.Ordinal), "Orodna vrstica napak mora biti razglasena kot role=\"search\".");
var issuesToolbarLabel = Regex.Match(issuesToolbar.Value, "aria-labelledby=\"([^\"]+)\"");
Assert(issuesToolbarLabel.Success, "Iskalni sklop napak mora imeti aria-labelledby.");
AssertHeading(issues, issuesToolbarLabel.Groups[1].Value, "iskalnega sklopa napak");
foreach (var control in new[] { "issue-search", "issue-profile", "issue-severity", "issue-blocks", "issue-field" })
{
  Assert(Regex.IsMatch(issues, "<label[^>]*for=\"" + control + "\""), "Kontrola " + control + " nima povezane oznake <label for>.");
  Assert(Regex.IsMatch(issues, "id=\"" + control + "\""), "Kontrola " + control + " ne obstaja.");
}
Assert(Regex.IsMatch(issues, "<input id=\"issue-search\"[^>]*type=\"search\""), "Iskalno polje napak mora biti type=\"search\".");

// A3. Vrednosti profila in polja izhajajo iz meritve vpliva, ne iz vpisanega seznama.
foreach (var source in new[] { "Overview.Rules.Select(rule => rule.ProfileCode)", "Overview.Rules.Select(rule => rule.FieldCode)" })
  Assert(issues.Contains(source, StringComparison.Ordinal), "Spustni seznam mora izhajati iz podatkov: " + source + ".");

// A4. Ziva stanja gredo skozi skupni PimState, rezultat pa se sporoci na glas.
var count = Regex.Match(issues, "<span class=\"result-count\"[^>]*>");
Assert(count.Success, "Orodna vrstica mora ohraniti izpis stevila rezultatov.");
foreach (var attribute in new[] { "role=\"status\"", "aria-live=\"polite\"" })
  Assert(count.Value.Contains(attribute, StringComparison.Ordinal), "Izpis rezultatov nima " + attribute + ": " + count.Value);
Assert(Regex.Matches(issues, "<PimState ").Count == 3, "Vsaka od treh tabel mora imeti svoje stanje nalaganja, napake in praznega nabora.");
foreach (var parameter in new[] { "Loading=", "Error=", "Empty=", "EmptyText=", "LoadingText=" })
  Assert(issues.Contains(parameter, StringComparison.Ordinal), "PimState mora dobiti " + parameter + ".");

// A5. Resnost in obseg blokade sta locena in nista razlocljiva samo po barvi.
Assert(issues.Contains("SeverityLabel(issue.Severity)", StringComparison.Ordinal), "Vrstica tezave mora povedati resnost z besedo.");
Assert(Regex.Matches(issues, "<PimChip Text=\"ERP\" Tone=\"bad\" Prefix=\"Blokira: \"").Count >= 1, "Blokada ERP mora biti oznacena z govorno predpono.");
Assert(Regex.Matches(issues, "<PimChip Text=\"Splet\" Tone=\"warn\" Prefix=\"Blokira: \"").Count >= 1, "Blokada spleta mora biti oznacena z govorno predpono.");
Assert(Regex.IsMatch(issues, "<PimBar Percent=\"product\\.Completeness\"[^>]*Label="), "Popolnost mora uporabiti skupni merilnik z oznako.");

// A6. Stranicenje je streznisko in izhaja iz istega stetja kot seznam.
Assert(Regex.IsMatch(issues, "<PimPager Skip=\"Skip\" Take=\"Take\" Total=\"PageData\\.TotalCount\""),
  "Seznam mora biti strezniski; odjemalsko filtriranje treh milijonov vrstic ni dovoljeno.");
foreach (var parameter in new[] { "isci", "profil", "resnost", "blokira", "polje", "stran" })
  Assert(Regex.IsMatch(issues, "SupplyParameterFromQuery\\(Name = \"" + parameter + "\"\\)"),
    "Filter " + parameter + " mora ziveti v naslovu URL.");
Assert(!issues.Contains("x.ProfileCode==Profile", StringComparison.Ordinal), "Odjemalskega filtriranja ne sme biti vec.");

// A7. Tabele so skupni gradnik z napisom in oznako.
Assert(Regex.Matches(issues, "<PimTable Caption=\"").Count == 3, "Stran ima tri tabele: izdelki, pravila in dobavitelji.");
foreach (Match table in Regex.Matches(issues, "<PimTable [^>]*>"))
  Assert(table.Value.Contains("AriaLabel=", StringComparison.Ordinal), "Tabela nima aria-label: " + table.Value);
Assert(!issues.Contains("<table class=\"data-table\">", StringComparison.Ordinal), "Tabele se ne pisejo znova; uporabi PimTable.");

// A8. Tipkovnicni fokus in izoliran slog.
AssertCss(issuesCss, new[] { ".search-input", ".filter-select", ".filter-button", ".filter-chip", ".table-scroll", ".data-table a" }, "kakovosti");

// A9. Varovalka: stran ostane vezana na dejanski bralni proceduri in ne pise.
Assert(issues.Contains("Data.GetCurrentOrganizationAsync", StringComparison.Ordinal), "Stran mora prevzeti aktivno organizacijo.");
foreach (var call in new[] { "Quality.GetIssuesAsync", "Quality.GetOverviewAsync" })
  Assert(issues.Contains(call, StringComparison.Ordinal), "Stran mora ohraniti klic " + call + ".");
foreach (Match call in Regex.Matches(issues, "(?<![A-Za-z0-9_])(?:Data|Quality)\\.(\\w+)"))
  Assert(new[] { "GetCurrentOrganizationAsync", "GetIssuesAsync", "GetOverviewAsync" }.Contains(call.Groups[1].Value, StringComparer.Ordinal),
    "Nova podatkovna poizvedba ni v obsegu naloge: " + call.Value);
Assert(issues.Contains("intranet.GetQualityIssues", StringComparison.Ordinal), "Stran mora povedati, iz katerega vira bere.");
var allowedHandlers = new[] { "ApplyFiltersAsync" };
foreach (Match handler in Regex.Matches(issues, "@onclick=\"(\\w+)\""))
  Assert(allowedHandlers.Contains(handler.Groups[1].Value, StringComparer.Ordinal), "Novo dejanje ni v obsegu naloge: " + handler.Value);
foreach (var writeSurface in new[] { "SaopWriteService", "EnqueueAsync", "ApproveBatchAsync", "ResolveIssue", "MarkResolved", "Označi kot rešeno" })
  Assert(!issues.Contains(writeSurface, StringComparison.Ordinal), "Napake ni mogoce zapreti rocno: " + writeSurface + ".");

// ---------------------------------------------------------------------------
// B. /karantena
// ---------------------------------------------------------------------------

// B1. Naslov in isti kontekstni zavihki.
Assert(quarantine.Contains("@attribute [Authorize]", StringComparison.Ordinal), "Karantena mora ostati zaščitena z [Authorize].");
Assert(quarantine.Contains("<h1>Karantena</h1>", StringComparison.Ordinal), "Karantena mora ohraniti vidni naslov <h1>Karantena</h1>.");
var quarantineTabs = Regex.Match(quarantine, "<nav[^>]*class=\"page-tabs\"[^>]*>");
Assert(quarantineTabs.Success, "Zavihki karantene morajo biti navigacijski sklop <nav class=\"page-tabs\">.");
Assert(Regex.IsMatch(quarantineTabs.Value, "aria-label=\"[^\"]+\""), "Zavihki karantene morajo imeti aria-label.");
Assert(Regex.Matches(quarantine, "class=\"page-tab(?!s)").Count == 2,
  "Karantena ima dva zavihka; stanja zavihkov druge strani ni mogoče naslavljati z URL, zato se ga ne izmišlja.");
Assert(Regex.IsMatch(quarantine, "<a class=\"page-tab\" href=\"napake-validacije\">"), "Zavihek nazaj na kakovost mora ostati povezava na /napake-validacije.");
Assert(quarantine.Contains("<span class=\"page-tab active\" aria-current=\"page\">", StringComparison.Ordinal),
  "Aktivni zavihek karantene mora imeti aria-current=\"page\".");

// B2. Iskalni sklop.
var quarantineToolbar = Regex.Match(quarantine, "<section[^>]*class=\"ui-card toolbar\"[^>]*>");
Assert(quarantineToolbar.Success, "Orodna vrstica karantene mora ostati <section class=\"ui-card toolbar\">.");
Assert(quarantineToolbar.Value.Contains("role=\"search\"", StringComparison.Ordinal), "Orodna vrstica karantene mora biti razglašena kot role=\"search\".");
var quarantineToolbarLabel = Regex.Match(quarantineToolbar.Value, "aria-labelledby=\"([^\"]+)\"");
Assert(quarantineToolbarLabel.Success, "Iskalni sklop karantene mora imeti aria-labelledby.");
AssertHeading(quarantine, quarantineToolbarLabel.Groups[1].Value, "iskalnega sklopa karantene");
Assert(Regex.IsMatch(quarantine, "<label[^>]*for=\"quarantine-search\""), "Kontrola quarantine-search nima povezane oznake <label for>.");
Assert(Regex.IsMatch(quarantine, "<input id=\"quarantine-search\"[^>]*type=\"search\""), "Iskalno polje karantene mora biti type=\"search\".");

// B3. Živa stanja in tabela.
AssertLiveStates(quarantine, "Karantena");
AssertTables(quarantine, 1, 5, "Karantena");
Assert(Regex.Matches(quarantine, "class=\"empty-state\"").Count == 1, "Karantena mora ohraniti prazno stanje.");

// B4. Tipkovnični fokus in izoliran slog.
AssertCss(quarantineCss, new[] { ".page-tab", ".search-input", ".table-scroll" }, "karantene");

// B5. Varovalka: stran ostane vezana na obstoječi resnični poizvedbi.
AssertDataCalls(quarantine, new[] { "GetCurrentOrganizationAsync", "GetQuarantineAsync" }, "Karantena");
Assert(!Regex.IsMatch(quarantine, "@onclick"), "Karantena je predstavitvena stran brez novih dejanj.");

// ---------------------------------------------------------------------------
// C. Skupne varovalke za oba pogleda
// ---------------------------------------------------------------------------

foreach (var (name, markup) in new[] { ("Kakovost", issues), ("Karantena", quarantine) })
{
  // C1. Predstavitveni sklop brez akcij pisanja in brez nepodprtih kontrol.
  foreach (var forbidden in new[] { "<form", "@onsubmit", "method=\"post\"", "<img", "type=\"checkbox\"", "type=\"file\"", "<dialog", "contenteditable" })
    Assert(!markup.Contains(forbidden, StringComparison.OrdinalIgnoreCase), name + ": predstavitveni sklop ne sme uvesti " + forbidden + ".");

  // C2. Nobene vsebine brez podatkovnega vira.
  //
  // Resnost in obseg blokade sta od migracije 102 resnicna stolpca (val.FieldRequirement.Severity,
  // val.ValidationProfile.BlocksErp/BlocksWeb), zato nista vec na tem seznamu. Trendi ostanejo
  // prepovedani, ker zgodovinskega read modela ni.
  foreach (var fabricated in new[] { "ta teden", "Trend", "Osveži podatke", "Stolpci",
             "Vrstic na stran", "Izbranih", "Akcije", "Uvozi", "Privzeti" })
    Assert(!markup.Contains(fabricated, StringComparison.Ordinal), name + " ne sme prikazovati izmišljene vsebine: " + fabricated + ".");

  // C3. Povezave ostanejo base-relativne, sicer pod virtualno potjo /PIM padejo na koren strežnika.
  Assert(!markup.Contains("href=\"/", StringComparison.Ordinal), name + ": notranje povezave morajo ostati base-relativne.");

  // C4. Unicode nadomestne ikone niso stabilen ikonografski sistem.
  foreach (var glyph in new[] { '\u203A', '\u2713', '\u26A0' })
    Assert(!markup.Contains(glyph), name + ": Unicode nadomestne ikone niso dovoljene; uporabi CSS obliko.");
}

Console.WriteLine("F10 quality UX contract PASS.");

static void AssertLiveStates(string markup, string name)
{
  var count = Regex.Match(markup, "<span class=\"result-count\"[^>]*>");
  Assert(count.Success, name + ": orodna vrstica mora ohraniti izpis števila rezultatov.");
  foreach (var attribute in new[] { "role=\"status\"", "aria-live=\"polite\"" })
    Assert(count.Value.Contains(attribute, StringComparison.Ordinal), name + ": izpis rezultatov nima " + attribute + ": " + count.Value);
  Assert(Regex.IsMatch(markup, "class=\"[^\"]*loading-state\"[^>]*role=\"status\""), name + ": stanje nalaganja mora biti razglašeno kot role=\"status\".");
  Assert(Regex.IsMatch(markup, "class=\"[^\"]*error-state\"[^>]*role=\"alert\""), name + ": stanje napake mora biti razglašeno kot role=\"alert\".");
}

static void AssertTables(string markup, int tableCount, int columnCount, string name)
{
  Assert(Regex.Matches(markup, "<table class=\"data-table\">").Count == tableCount,
    name + ": pričakovanih je natanko " + tableCount + " obstoječih tabel.");
  var scrolls = Regex.Matches(markup, "<div class=\"table-scroll\"[^>]*>");
  Assert(scrolls.Count == tableCount, name + ": vsaka tabela mora biti v ovoju <div class=\"table-scroll\"> zaradi prelivanja.");
  foreach (Match scroll in scrolls)
    foreach (var attribute in new[] { "role=\"region\"", "tabindex=\"0\"", "aria-label=" })
      Assert(scroll.Value.Contains(attribute, StringComparison.Ordinal), name + ": pomični ovoj tabele nima " + attribute + ": " + scroll.Value);
  Assert(Regex.Matches(markup, "<caption>").Count == tableCount, name + ": vsaka tabela mora ohraniti napis <caption>.");
  Assert(Regex.Matches(markup, "<th scope=\"col\">").Count == columnCount,
    name + ": tabele morajo ohraniti natanko " + columnCount + " obstoječih stolpcev z scope=\"col\".");
  // Negativni pogled naprej za `[a-z]` izloči <thead>, ki ni glava stolpca.
  Assert(!Regex.IsMatch(markup, "<th(?![a-z])(?![^>]*scope=\"col\")"), name + ": vsaka glava stolpca mora imeti scope=\"col\".");
  foreach (Match card in Regex.Matches(markup, "<section class=\"ui-card data-card\"[^>]*>"))
    Assert(card.Value.Contains("aria-label=", StringComparison.Ordinal), name + ": podatkovna kartica nima aria-label: " + card.Value);
}

static void AssertCss(string css, string[] selectors, string name)
{
  foreach (var selector in selectors)
    Assert(css.Contains(selector + ":focus-visible", StringComparison.Ordinal), "Manjka slog fokusa za " + selector + " (" + name + ").");
  Assert(Regex.IsMatch(css, ":focus-visible[^{]*\\{[^}]*outline:"), "Fokus " + name + " mora risati obris, ne samo sence.");
  Assert(Regex.IsMatch(css, "\\.table-scroll\\s*\\{[^}]*overflow-x:\\s*auto"), "Ovoj tabele " + name + " mora imeti overflow-x: auto.");
  Assert(Regex.IsMatch(css, "@media[^{]*max-width:\\s*900px"), "Manjka odzivno pravilo za ozke zaslone (" + name + ").");
  Assert(Regex.IsMatch(css, "\\.data-table\\s*\\{[^}]*min-width:"), "Na ozkih zaslonih se tabela " + name + " ne sme stiskati; potrebna je min-width.");
  Assert(!css.Contains("::deep", StringComparison.Ordinal), "Izoliran slog " + name + " ne sme uhajati z ::deep.");
}

static void AssertDataCalls(string markup, string[] allowedCalls, string name)
{
  foreach (var call in allowedCalls)
    Assert(markup.Contains("Data." + call, StringComparison.Ordinal), name + " mora ohraniti klic " + call + ".");
  foreach (Match call in Regex.Matches(markup, "Data\\.(\\w+)"))
    Assert(allowedCalls.Contains(call.Groups[1].Value, StringComparer.Ordinal), name + ": nova podatkovna poizvedba ni v obsegu naloge: " + call.Value);
}

static void AssertHeading(string markup, string headingId, string what)
{
  Assert(Regex.IsMatch(markup, "<h2 id=\"" + Regex.Escape(headingId) + "\" class=\"visually-hidden\">"),
    "Naslov " + what + " mora ostati bralcem zaslona dostopen in vizualno skrit: " + headingId);
}

static void Assert(bool condition, string message)
{
  if (!condition) throw new InvalidOperationException(message);
}

// Koren se poišče iz delovne mape in iz mape sestave, da je test neodvisen od načina zagona.
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
