using System.Text.RegularExpressions;

// Pogodbeni test UX skladnosti osebne izkaznice izdelka.
// Obseg je namenoma ozek: samo predstavitev in dostopnost strani /izdelki/{id}.
// Referenca je potrjena slika `../PIM_test/UX_pictures/Osebna_izkaznica_izdelka.png`,
// vendar se prevzame samo tisto, kar pokriva obstoječi read model `GetProductDetailAsync`.
// Test ne sme zahtevati novih poizvedb, novih polj, urejevalnih kontrol ali akcij pisanja.

var root = FindRoot();
var razorPath = Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", "ProductDetail.razor");
var cssPath = Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", "ProductDetail.razor.css");

Assert(File.Exists(razorPath), "Manjka stran podrobnosti izdelka: " + razorPath);
Assert(File.Exists(cssPath), "Manjka izoliran slog podrobnosti izdelka: " + cssPath);

var markup = File.ReadAllText(razorPath);
var css = File.ReadAllText(cssPath);

// 1. Drobtinice so navigacijski sklop nazaj na seznam (referenca: "Izdelki › AZ_0002").
var breadcrumb = Regex.Match(markup, "<nav class=\"breadcrumb\"[^>]*>");
Assert(breadcrumb.Success, "Pot do izdelka mora biti navigacijski sklop <nav class=\"breadcrumb\">.");
Assert(Regex.IsMatch(breadcrumb.Value, "aria-label=\"[^\"]+\""), "Drobtinice morajo imeti aria-label.");
Assert(Regex.IsMatch(markup, "<nav class=\"breadcrumb\"[^>]*>\\s*<a href=\"izdelki\">"), "Prva drobtinica mora biti povezava na seznam izdelkov.");
Assert(Regex.IsMatch(markup, "class=\"breadcrumb-current\" aria-current=\"page\""), "Zadnja drobtinica mora biti označena z aria-current=\"page\".");
Assert(Regex.IsMatch(markup, "<span class=\"breadcrumb-sep\" aria-hidden=\"true\"></span>"), "Ločilo drobtinic mora biti nadzorovana CSS oblika z aria-hidden.");
Assert(!markup.Contains('\u203A'), "Unicode nadomestne ikone niso dovoljene; uporabi CSS obliko.");

// 2. Naslov in identifikacijska vrstica izhajata iz resničnih polj glave (referenca: naslov + "ItemID · EAN").
Assert(markup.Contains("<h1>@Detail.Header.ItemId</h1>", StringComparison.Ordinal), "Naslov strani mora biti dejanski ItemId izdelka.");
var identity = Regex.Match(markup, "<p class=\"identity-line\">[\\s\\S]*?</p>");
Assert(identity.Success, "Manjka identifikacijska vrstica <p class=\"identity-line\">.");
Assert(identity.Value.Contains("Detail.Header.ItemId", StringComparison.Ordinal), "Identifikacijska vrstica mora izpisati dejanski ItemId.");
Assert(identity.Value.Contains("Detail.Header.Ean", StringComparison.Ordinal), "Identifikacijska vrstica mora izpisati dejanski EAN.");

// 3. Zastavici aktivnosti in spletne objave sta resnični polji glave, izpisani s svojo oznako.
Assert(Regex.Matches(markup, "class=\"flag-chip").Count == 2, "Glava mora prikazati natanko obe obstoječi zastavici (IsActive, WebPublish).");
Assert(markup.Contains(">Aktiven: ", StringComparison.Ordinal), "Zastavica aktivnosti mora imeti vidno oznako \"Aktiven: \".");
Assert(markup.Contains(">Za splet: ", StringComparison.Ordinal), "Zastavica spletne objave mora imeti vidno oznako \"Za splet: \".");
foreach (var field in new[] { "Detail.Header.IsActive", "Detail.Header.WebPublish" })
  Assert(markup.Contains(field, StringComparison.Ordinal), "Zastavica mora izhajati iz " + field + ".");

// 4. Povzetek stanja je poimenovan sklop kartic, izpeljan iz dejanskih profilov (referenca: kartice kanalov + popolnost).
var summary = Regex.Match(markup, "<section class=\"detail-summary\"[\\s\\S]*?</section>");
Assert(summary.Success, "Povzetek stanja mora biti sklop <section class=\"detail-summary\">.");
var summaryLabel = Regex.Match(summary.Value, "aria-labelledby=\"([^\"]+)\"");
Assert(summaryLabel.Success, "Sklop povzetka mora imeti aria-labelledby.");
Assert(Regex.IsMatch(markup, "<h2 id=\"" + Regex.Escape(summaryLabel.Groups[1].Value) + "\" class=\"visually-hidden\">"),
  "Naslov povzetka mora ostati bralcem zaslona dostopen in vizualno skrit.");
Assert(summary.Value.Contains("foreach", StringComparison.Ordinal) && summary.Value.Contains("Detail.Profiles", StringComparison.Ordinal),
  "Kartice povzetka se morajo izpisati iz dejanskih Detail.Profiles, ne iz vpisanih kanalov.");
Assert(summary.Value.Contains("Detail.Issues", StringComparison.Ordinal),
  "Število odprtih težav na kartici mora izhajati iz dejanskih Detail.Issues.");
Assert(summary.Value.Contains("Detail.Header.Completeness", StringComparison.Ordinal),
  "Kartica popolnosti mora izpisati dejansko popolnost izdelka.");
Assert(Regex.IsMatch(css, "\\.summary-grid\\s*\\{[^}]*grid-template-columns:"), "Kartice povzetka morajo biti postavljene v mrežo.");

// 5. Merilnik popolnosti mora sporočati vrednost, ne samo širine.
var meters = Regex.Matches(markup, "<span class=\"progress-track\"[^>]*>");
Assert(meters.Count >= 1, "Povzetek mora ohraniti merilnik popolnosti.");
foreach (Match meter in meters)
  foreach (var attribute in new[] { "role=\"progressbar\"", "aria-valuenow=", "aria-valuemin=\"0\"", "aria-valuemax=\"100\"", "aria-label=" })
    Assert(meter.Value.Contains(attribute, StringComparison.Ordinal), "Merilnik popolnosti nima " + attribute + ": " + meter.Value);
Assert(Regex.IsMatch(markup, "aria-valuenow=\"@Number\\("), "aria-valuenow mora biti izpisan neodvisno od območnih nastavitev.");
foreach (Match icon in Regex.Matches(markup, "<i [^>]*>"))
  Assert(icon.Value.Contains("aria-hidden=\"true\"", StringComparison.Ordinal), "Okrasni element mora imeti aria-hidden: " + icon.Value);

// 6. Zavihki so pravi ARIA tablist, vsak zavihek pa je povezan s svojim panelom (referenca: vrstica zavihkov).
var tablist = Regex.Match(markup, "<div class=\"page-tabs\"[^>]*>");
Assert(tablist.Success, "Zavihki morajo ostati sklop <div class=\"page-tabs\">.");
Assert(tablist.Value.Contains("role=\"tablist\"", StringComparison.Ordinal), "Sklop zavihkov mora biti razglašen kot role=\"tablist\".");
Assert(Regex.IsMatch(tablist.Value, "aria-label=\"[^\"]+\""), "Sklop zavihkov mora imeti aria-label.");

var tabs = Regex.Matches(markup, "<button[^>]*role=\"tab\"[^>]*>");
Assert(tabs.Count == 3, "Stran ima tri podatkovno podprte zavihke; dodatnih zavihkov brez podatkovnega vira ni dovoljeno ustvariti.");
var panels = Regex.Matches(markup, "<section[^>]*role=\"tabpanel\"[^>]*>");
Assert(panels.Count == 3, "Vsak zavihek mora imeti svoj panel role=\"tabpanel\".");
foreach (Match tab in tabs)
{
  Assert(tab.Value.Contains("type=\"button\"", StringComparison.Ordinal), "Zavihek mora biti izrecni gumb type=\"button\": " + tab.Value);
  Assert(tab.Value.Contains("aria-selected=\"@", StringComparison.Ordinal), "Zavihek mora izračunati aria-selected iz stanja: " + tab.Value);
  var tabId = Regex.Match(tab.Value, "id=\"([^\"]+)\"");
  var controls = Regex.Match(tab.Value, "aria-controls=\"([^\"]+)\"");
  Assert(tabId.Success, "Zavihek nima id: " + tab.Value);
  Assert(controls.Success, "Zavihek nima aria-controls: " + tab.Value);
  var panel = panels.FirstOrDefault(candidate => candidate.Value.Contains("id=\"" + controls.Groups[1].Value + "\"", StringComparison.Ordinal));
  Assert(panel is not null, "Zavihek kaže na neobstoječ panel: " + controls.Value);
  Assert(panel!.Value.Contains("aria-labelledby=\"" + tabId.Groups[1].Value + "\"", StringComparison.Ordinal),
    "Panel mora biti poimenovan s svojim zavihkom: " + panel.Value);
  Assert(panel.Value.Contains("tabindex=\"0\"", StringComparison.Ordinal), "Panel mora biti dosegljiv s tipkovnico: " + panel.Value);
  Assert(panel.Value.Contains("tab-panel", StringComparison.Ordinal), "Panel mora nositi razred tab-panel: " + panel.Value);
}
Assert(Regex.IsMatch(markup, "role=\"tab\"[^>]*>[^<]*Detail\\.Profiles\\.Count"), "Števec profilov mora izhajati iz dejanskega Detail.Profiles.Count.");
Assert(Regex.IsMatch(markup, "role=\"tab\"[^>]*>[^<]*Detail\\.Issues\\.Count"), "Števec težav mora izhajati iz dejanskega Detail.Issues.Count.");

// 7. Tabele morajo ostati berljive, opisane in se na ozkih zaslonih vodoravno pomikati.
var scrolls = Regex.Matches(markup, "<div class=\"table-scroll\"[^>]*>");
Assert(scrolls.Count == 2, "Obe podatkovni tabeli (profili, težave) morata biti v ovoju <div class=\"table-scroll\">.");
foreach (Match scroll in scrolls)
  foreach (var attribute in new[] { "role=\"region\"", "tabindex=\"0\"", "aria-label=" })
    Assert(scroll.Value.Contains(attribute, StringComparison.Ordinal), "Pomični ovoj tabele nima " + attribute + ": " + scroll.Value);
Assert(Regex.Matches(markup, "<caption>").Count == 3, "Vsaka tabela mora ohraniti napis <caption>.");
Assert(Regex.Matches(markup, "<th scope=\"col\">").Count == 8, "Tabeli profilov in težav morata ohraniti obstoječe stolpce z scope=\"col\".");
Assert(Regex.Matches(markup, "<th scope=\"row\">").Count >= 8, "Vrstice pregleda morajo biti glave vrstic z scope=\"row\".");
Assert(Regex.IsMatch(css, "\\.table-scroll\\s*\\{[^}]*overflow-x:\\s*auto"), "Ovoj tabele mora imeti overflow-x: auto.");
Assert(Regex.IsMatch(css, "@media[^{]*max-width:\\s*900px"), "Manjka odzivno pravilo za ozke zaslone.");
Assert(Regex.IsMatch(css, "\\.data-table\\s*\\{[^}]*min-width:"), "Na ozkih zaslonih se tabela ne sme stiskati; potrebna je min-width.");

// 8. Statusni čipi ne smejo biti razločljivi samo po barvi.
var chipCount = Regex.Matches(markup, "class=\"status-chip ").Count;
Assert(chipCount >= 3, "Stran mora ohraniti statusne čipe glave, povzetka in profilov.");
Assert(Regex.Matches(markup, "<span class=\"visually-hidden\">Status: </span>").Count == chipCount,
  "Vsak statusni čip mora imeti bralcem zaslona namenjeno oznako \"Status: \".");

// 9. Asinhrona in prazna stanja se morajo sporočiti tehnologijam za dostopnost.
Assert(Regex.IsMatch(markup, "class=\"ui-card loading-state\"[^>]*role=\"status\""), "Stanje nalaganja mora biti razglašeno kot role=\"status\".");
Assert(Regex.IsMatch(markup, "class=\"ui-card error-state\"[^>]*role=\"alert\""), "Stanje napake mora biti razglašeno kot role=\"alert\".");
Assert(Regex.Matches(markup, "empty-state").Count == 3, "Neobstoječ izdelek, prazni profili in prazne težave morajo ohraniti svoje prazno stanje.");

// 10. Viden fokus tipkovnice na vseh interaktivnih in pomičnih elementih strani.
foreach (var selector in new[] { ".breadcrumb a", ".page-tab", ".tab-panel", ".table-scroll" })
  Assert(css.Contains(selector + ":focus-visible", StringComparison.Ordinal), "Manjka slog fokusa za " + selector + ".");
Assert(Regex.IsMatch(css, ":focus-visible[^{]*\\{[^}]*outline:"), "Fokus mora risati obris, ne samo sence.");
Assert(Regex.IsMatch(css, "\\.breadcrumb-sep\\s*\\{[^}]*transform:\\s*rotate\\(45deg\\)"), "Ločilo drobtinic mora biti CSS oblika, ne besedilni znak.");
Assert(!css.Contains("::deep", StringComparison.Ordinal), "Izoliran slog ne sme uhajati z ::deep.");

// 11. Varovalka: stran ostane vezana na obstoječi resnični poizvedbi.
var allowedCalls = new[] { "GetCurrentOrganizationAsync", "GetProductDetailAsync" };
foreach (var call in allowedCalls)
  Assert(markup.Contains("Data." + call, StringComparison.Ordinal), "Stran mora ohraniti klic " + call + ".");
foreach (Match call in Regex.Matches(markup, "Data\\.(\\w+)"))
  Assert(allowedCalls.Contains(call.Groups[1].Value, StringComparer.Ordinal), "Nova podatkovna poizvedba ni v obsegu naloge: " + call.Value);

// 12. Varovalka: obstoječe ravnanje ostane nedotaknjeno — zavihki samo preklapljajo prikaz.
foreach (var behavior in new[] { "OnParametersSetAsync", "GetProductDetailAsync(org.OrganizationId,ProductId)" })
  Assert(markup.Contains(behavior, StringComparison.Ordinal), "Obstoječe ravnanje strani je spremenjeno; manjka: " + behavior);
var allowedTabs = new[] { "overview", "profiles", "issues" };
var handlers = Regex.Matches(markup, "@onclick='\\(\\)=>Tab=\"(\\w+)\"'");
Assert(handlers.Count == 3, "Zavihki morajo ostati preprost preklop prikaza brez novih dejanj.");
foreach (Match handler in handlers)
  Assert(allowedTabs.Contains(handler.Groups[1].Value, StringComparer.Ordinal), "Nov zavihek ni v obsegu naloge: " + handler.Value);
Assert(Regex.Matches(markup, "@onclick").Count == handlers.Count, "Novo dejanje ni v obsegu naloge; dovoljen je samo preklop zavihka.");

// 13. Varovalka: gre za predstavitveni sklop brez urejanja in brez nepodprtih kontrol.
foreach (var forbidden in new[] { "<form", "@onsubmit", "@bind", "method=\"post\"", "<input", "<select", "<textarea", "<img", "type=\"checkbox\"", "type=\"file\"", "<dialog", "contenteditable" })
  Assert(!markup.Contains(forbidden, StringComparison.OrdinalIgnoreCase), "Predstavitveni sklop ne sme uvesti " + forbidden + ".");

// 14. Varovalka: referenčna slika ni podatkovna pogodba — polj in dejanj brez vira ni dovoljeno prikazati.
foreach (var fabricated in new[] { "Shrani", "Uredi", "Izbriši", "Revalidiraj", "Naziv", "Kratki naziv", "Tip izdelka", "Dimenzije",
  "Teža", "Višina", "Širina", "Globina", "Država porekla", "HS koda", "Slika", "Mediji", "Kategorije", "Atributi", "Cene", "Zaloga",
  "Zgodovina", "Komerciala", "Napake in opozorila" })
  Assert(!markup.Contains(fabricated, StringComparison.Ordinal), "Stran ne sme prikazovati nepodprte vsebine: " + fabricated + ".");

Console.WriteLine("F10 product detail UX contract PASS.");

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
