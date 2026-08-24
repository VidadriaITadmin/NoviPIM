using System.Text.RegularExpressions;

// Pogodbeni test UX skladnosti izvozov: stran /outbound.
// Obseg je namenoma ozek: samo predstavitev in dostopnost strani.
// Referenca: ../PIM_test/UX_pictures/uvozi_izvozi.png (desni zaslon »Izvozi«: naslov,
// zavihki, »Hitri pregled« s štirimi karticami in tabela »Zadnji izvozi« z akcijami).
// Referenca prikazuje tudi kanalske zavihke (SAOP, Splet (CSV), Magento), gumb »Nov izvoz«,
// stolpca »Št. izdelkov« in »Uporabnik« ter prenos datotek. `OutboundRow` in
// `intranet.GetOutboundMessages` teh podatkov ne vračata, zato jih test izrecno prepove.
// Test ne sme zahtevati novih poizvedb, novih stolpcev, novih vrednosti ali novih akcij pisanja.

var root = FindRoot();
var pages = Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages");
var razorPath = Path.Combine(pages, "Outbound.razor");
var cssPath = Path.Combine(pages, "Outbound.razor.css");

Assert(File.Exists(razorPath), "Manjka stran izvozov: " + razorPath);
Assert(File.Exists(cssPath), "Manjka izoliran slog izvozov: " + cssPath);

var markup = File.ReadAllText(razorPath);
var css = File.ReadAllText(cssPath);

// 1. Pot, zaščita in vidni naslov ostanejo nespremenjeni.
Assert(markup.Contains("@page \"/outbound\"", StringComparison.Ordinal), "Pot /outbound se ne sme spremeniti.");
Assert(markup.Contains("@attribute [Authorize(Roles = \"ADMIN,CATALOG_EDITOR,COMMERCIAL\")]", StringComparison.Ordinal),
  "Izvozi morajo ostati omejeni na obstoječe vloge.");
Assert(markup.Contains("<h1>Izvozi</h1>", StringComparison.Ordinal), "Stran mora ohraniti vidni naslov <h1>Izvozi</h1>.");

// 2. Kontekstni zavihki so navigacijski sklop, ne le vrsta škatel.
var tabs = Regex.Match(markup, "<nav[^>]*class=\"page-tabs\"[^>]*>");
Assert(tabs.Success, "Zavihki morajo biti navigacijski sklop <nav class=\"page-tabs\">.");
Assert(Regex.IsMatch(tabs.Value, "aria-label=\"[^\"]+\""), "Zavihki izvozov morajo imeti aria-label.");
// Zavihki so stirje: Uvozi, Vsi izvozi, Mnozicno urejanje in Obvestila. Vsak od njih ima svojo
// stran s podatki; kanalskih zavihkov iz reference se se vedno ne sme izmisljati.
Assert(Regex.Matches(markup, "class=\"page-tab(?!s)").Count == 4,
  "Izvozi imajo stiri podatkovno podprte zavihke.");
Assert(Regex.IsMatch(markup, "<a class=\"page-tab\" href=\"izvozi/mnozicno\">"),
  "Zavihek Mnozicno urejanje mora biti povezava na /izvozi/mnozicno.");
Assert(Regex.IsMatch(markup, "<a class=\"page-tab\" href=\"izvozi/obvestila\">"),
  "Zavihek Obvestila mora biti povezava na /izvozi/obvestila.");
Assert(Regex.IsMatch(markup, "<a class=\"page-tab\" href=\"teki-obdelave\">"), "Zavihek Uvozi mora ostati povezava na /teki-obdelave.");
Assert(markup.Contains("<span class=\"page-tab active\" aria-current=\"page\">", StringComparison.Ordinal),
  "Aktivni zavihek mora imeti aria-current=\"page\".");

// 3. »Hitri pregled« je poimenovan sklop, vsaka vrednost pa izpeljana iz dejansko naloženih vrstic.
var kpiGrid = Regex.Match(markup, "<section[^>]*class=\"kpi-grid\"[^>]*>");
Assert(kpiGrid.Success, "Hitri pregled mora biti poimenovan sklop <section class=\"kpi-grid\">.");
var kpiLabel = Regex.Match(kpiGrid.Value, "aria-labelledby=\"([^\"]+)\"");
Assert(kpiLabel.Success, "Sklop hitrega pregleda mora imeti aria-labelledby.");
AssertHeading(markup, kpiLabel.Groups[1].Value, "hitrega pregleda");
Assert(Regex.Matches(markup, "class=\"ui-card kpi\"").Count == 4,
  "Hitri pregled ima natanko štiri kartice, izpeljane iz obstoječih statusov in odklonov.");
Assert(Regex.Matches(markup, "Rows\\.Count\\(").Count >= 4,
  "Vsaka vrednost hitrega pregleda mora izhajati iz dejanskega števila vrstic, ne iz vpisane vrednosti.");
Assert(Regex.Matches(markup, "@Share\\(").Count == 4, "Vsaka kartica mora izpisati delež, izpeljan iz Rows.Count.");
Assert(Regex.IsMatch(markup, "string Share\\(int [^)]*\\)[^;]*Rows\\.Count"), "Delež se mora računati iz dejanskega števila vrstic.");
Assert(Regex.IsMatch(markup, "Rows(\\.Count)? == 0|Rows\\.Count==0"), "Delež mora varno obravnavati prazen nabor.");
Assert(markup.Contains("@if (Rows is not null)", StringComparison.Ordinal),
  "Hitri pregled se ne sme izrisati, dokler vrstic ni; ničle brez podatkov niso poštene.");

// 4. Orodna vrstica je poimenovan iskalni sklop, vsaka kontrola pa ima svojo oznako.
var toolbar = Regex.Match(markup, "<section[^>]*class=\"ui-card toolbar\"[^>]*>");
Assert(toolbar.Success, "Orodna vrstica mora ostati <section class=\"ui-card toolbar\">.");
Assert(toolbar.Value.Contains("role=\"search\"", StringComparison.Ordinal), "Orodna vrstica mora biti razglašena kot role=\"search\".");
var toolbarLabel = Regex.Match(toolbar.Value, "aria-labelledby=\"([^\"]+)\"");
Assert(toolbarLabel.Success, "Iskalni sklop mora imeti aria-labelledby.");
AssertHeading(markup, toolbarLabel.Groups[1].Value, "iskalnega sklopa izvozov");
foreach (var control in new[] { "out-search", "out-status" })
  Assert(Regex.IsMatch(markup, "<label[^>]*for=\"" + control + "\""), "Kontrola " + control + " nima povezane oznake <label for>.");
Assert(Regex.IsMatch(markup, "<input id=\"out-search\"[^>]*type=\"search\""), "Iskalno polje mora biti type=\"search\".");

// 5. Živa stanja: število rezultatov, nalaganje in napaka.
var count = Regex.Match(markup, "<span class=\"result-count\"[^>]*>");
Assert(count.Success, "Orodna vrstica mora ohraniti izpis števila rezultatov.");
foreach (var attribute in new[] { "role=\"status\"", "aria-live=\"polite\"" })
  Assert(count.Value.Contains(attribute, StringComparison.Ordinal), "Izpis rezultatov nima " + attribute + ": " + count.Value);
Assert(Regex.IsMatch(markup, "class=\"loading-state\"[^>]*role=\"status\""), "Stanje nalaganja mora biti razglašeno kot role=\"status\".");
Assert(Regex.IsMatch(markup, "class=\"error-state\"[^>]*role=\"alert\""), "Stanje napake mora biti razglašeno kot role=\"alert\".");
Assert(Regex.Matches(markup, "class=\"empty-state\"").Count == 1, "Seznam mora ohraniti pošteno prazno stanje.");

// 6. Statusni čip ne sme biti razločljiv samo po barvi.
var chipCount = Regex.Matches(markup, "class=\"status-chip ").Count;
Assert(chipCount == 1, "Seznam mora ohraniti natanko en statusni čip izvoza.");
Assert(Regex.Matches(markup, "<span class=\"visually-hidden\">Status: </span>").Count == chipCount,
  "Statusni čip mora imeti bralcem zaslona namenjeno oznako \"Status: \".");
Assert(Regex.IsMatch(markup, "static string Chip\\(string"), "Barvna razvrstitev statusa mora ostati v obstoječi funkciji Chip.");
foreach (var group in new[] { "\"Succeeded\" or \"Sent\" or \"Completed\"", "\"Error\" or \"Dead\" or \"Drift\" or \"Cancelled\"" })
  Assert(markup.Contains(group, StringComparison.Ordinal), "Obstoječa razvrstitev statusov je spremenjena; manjka: " + group);

// 7. Tabela ostane berljiva in se na ozkih zaslonih vodoravno pomika.
var dataCard = Regex.Match(markup, "<section class=\"ui-card data-card\"[^>]*>");
Assert(dataCard.Success, "Seznam mora ostati v <section class=\"ui-card data-card\">.");
Assert(dataCard.Value.Contains("aria-label=", StringComparison.Ordinal), "Podatkovna kartica nima aria-label: " + dataCard.Value);
var scroll = Regex.Match(markup, "<div class=\"table-scroll\"[^>]*>");
Assert(scroll.Success, "Tabela mora biti v ovoju <div class=\"table-scroll\"> zaradi prelivanja.");
foreach (var attribute in new[] { "role=\"region\"", "tabindex=\"0\"", "aria-label=" })
  Assert(scroll.Value.Contains(attribute, StringComparison.Ordinal), "Pomični ovoj tabele nima " + attribute + ": " + scroll.Value);
Assert(markup.Contains("<caption>", StringComparison.Ordinal), "Tabela mora ohraniti napis <caption>.");
Assert(Regex.Matches(markup, "<th scope=\"col\"").Count == 10,
  "Tabela mora ohraniti natanko deset obstoječih stolpcev z scope=\"col\".");
// Negativni pogled naprej za `[a-z]` izloči <thead>, ki ni glava stolpca.
Assert(!Regex.IsMatch(markup, "<th(?![a-z])(?![^>]*scope=\"col\")"), "Vsaka glava stolpca mora imeti scope=\"col\".");
Assert(Regex.Matches(markup, "class=\"numeric\"").Count >= 2, "Število poskusov mora biti poravnano desno v glavi in v celici.");
Assert(markup.Contains("ResponseSummary", StringComparison.Ordinal),
  "Prazen odziv se ne sme izrisati kot prazna celica; potreben je izpeljan povzetek odziva.");

// 8. Paginacija naloženega nabora ostane dostopna in nikoli ne kaže strani izven obsega.
var pagination = Regex.Match(markup, "<nav class=\"pagination\"[^>]*>");
Assert(pagination.Success, "Paginacija mora ostati <nav class=\"pagination\">.");
Assert(Regex.IsMatch(pagination.Value, "aria-label=\"[^\"]+\""), "Paginacija mora imeti aria-label.");
Assert(markup.Contains("class=\"page-position\"", StringComparison.Ordinal), "Položaj strani mora biti označen razred, da ga slog lahko umiri.");
Assert(Regex.IsMatch(markup, "int CurrentPage\\s*=>\\s*Math\\.Min\\("),
  "Po zožitvi filtra stran ne sme ostati izven obsega; potrebna je omejena CurrentPage.");
Assert(Regex.IsMatch(markup, "Skip\\(CurrentPage\\s*\\*\\s*PageSize\\)"), "Izpisana stran mora izhajati iz omejene CurrentPage.");
Assert(!Regex.IsMatch(markup, "@onclick=\"\\(\\)=>Page(\\+\\+|--)\""), "Premik po straneh mora klicati imenovano metodo z omejitvijo.");

// 9. Vsi gumbi so izrecno type="button", vrstična dejanja pa imajo razločljivo ime.
Assert(Regex.Matches(markup, "<button").Count == 5,
  "Stran ima tri vrstična dejanja in dva gumba paginacije; novih gumbov ni dovoljeno uvesti.");
Assert(!Regex.IsMatch(markup, "<button(?![^>]*type=\"button\")"), "Vsak gumb mora biti izrecno type=\"button\".");
var actionButtons = Regex.Matches(markup, "<button[^>]*class=\"small-action[^>]*>");
Assert(actionButtons.Count == 3, "Ohraniti je treba natanko tri obstoječa vrstična dejanja.");
foreach (Match button in actionButtons)
{
  Assert(button.Value.Contains("aria-label=", StringComparison.Ordinal),
    "Ponovljeno vrstično dejanje mora imeti razločljiv aria-label: " + button.Value);
  Assert(button.Value.Contains("disabled=\"@ActionBusy\"", StringComparison.Ordinal),
    "Vrstično dejanje mora med izvajanjem ostati onemogočeno: " + button.Value);
}

// 10. Sporočilo o uspehu uporablja skupni PIM slog, ne Bootstrap razredov.
Assert(Regex.IsMatch(markup, "class=\"message-state success-message\"[^>]*role=\"status\""),
  "Sporočilo o uspehu mora uporabiti skupni razred message-state success-message z role=\"status\".");
Assert(!markup.Contains("class=\"alert", StringComparison.Ordinal), "Bootstrap razred alert ni del PIM vizualnega jezika.");

// 11. Izoliran slog: pomik tabele, številski stolpec, viden fokus in odzivnost.
Assert(Regex.IsMatch(css, "\\.table-scroll\\s*\\{[^}]*overflow-x:\\s*auto"), "Ovoj tabele mora imeti overflow-x: auto.");
Assert(Regex.IsMatch(css, "\\.numeric\\s*\\{[^}]*text-align:\\s*right"), "Številski stolpec mora biti poravnan desno.");
Assert(Regex.IsMatch(css, "\\.numeric\\s*\\{[^}]*font-variant-numeric:\\s*tabular-nums"), "Številski stolpec mora uporabljati tabelarične številke.");
Assert(Regex.IsMatch(css, "@media[^{]*max-width:\\s*900px"), "Manjka odzivno pravilo za ozke zaslone.");
Assert(Regex.IsMatch(css, "\\.data-table\\s*\\{[^}]*min-width:"), "Deset stolpcev se na ozkih zaslonih ne sme stiskati; potrebna je min-width.");
foreach (var selector in new[] { ".page-tab", ".search-input", ".filter-select", ".small-action", ".pagination button", ".table-scroll" })
  Assert(css.Contains(selector + ":focus-visible", StringComparison.Ordinal), "Manjka slog fokusa za " + selector + ".");
Assert(Regex.IsMatch(css, ":focus-visible[^{]*\\{[^}]*outline:"), "Fokus mora risati obris, ne samo sence.");
Assert(!css.Contains("::deep", StringComparison.Ordinal), "Izoliran slog ne sme uhajati z ::deep.");

// 12. Varovalka: stran ostane vezana na obstoječe resnične poizvedbe in dejanja.
var allowedCalls = new[] { "GetCurrentOrganizationAsync", "GetOutboundAsync", "ApproveOutboundAsync", "CancelOutboundAsync", "RetryOutboundAsync" };
foreach (var call in allowedCalls)
  Assert(markup.Contains("Data." + call, StringComparison.Ordinal), "Stran mora ohraniti klic " + call + ".");
foreach (Match call in Regex.Matches(markup, "Data\\.(\\w+)"))
  Assert(allowedCalls.Contains(call.Groups[1].Value, StringComparer.Ordinal), "Nova podatkovna poizvedba ni v obsegu naloge: " + call.Value);
Assert(markup.Contains("state.User.Identity?.Name", StringComparison.Ordinal),
  "Izvajalec dejanja mora ostati prijavljeni uporabnik, ne vpisana vrednost.");

// 13. Varovalka: obstoječe filtriranje, statusi in pogoji dejanj ostanejo nedotaknjeni.
foreach (var behavior in new[] { "@bind=\"Search\"", "@bind:event=\"oninput\"", "@bind=\"StatusFilter\"", "const int PageSize=10" })
  Assert(markup.Contains(behavior, StringComparison.Ordinal), "Obstoječe ravnanje s filtri je spremenjeno; manjka: " + behavior);
Assert(markup.Contains("Select(x=>x.Status).Distinct()", StringComparison.Ordinal),
  "Seznam statusov mora ostati izpeljan iz naloženih vrstic, ne iz vpisanega seznama.");
foreach (var condition in new[] { "row.Status==\"PendingApproval\"", "\"PendingApproval\" or \"Pending\" or \"Error\" or \"Retry\"", "row.Status is \"Error\" or \"Dead\"" })
  Assert(markup.Contains(condition, StringComparison.Ordinal), "Pogoj razpoložljivosti dejanja je spremenjen; manjka: " + condition);

// 14. Varovalka: brez novih zapisovalnih poti in nepodprtih kontrol.
foreach (var forbidden in new[] { "<form", "@onsubmit", "method=\"post\"", "<img", "type=\"checkbox\"", "type=\"file\"", "<dialog", "contenteditable" })
  Assert(!markup.Contains(forbidden, StringComparison.OrdinalIgnoreCase), "Stran ne sme uvesti " + forbidden + ".");
Assert(!markup.Contains("href=\"/", StringComparison.Ordinal), "Notranje povezave morajo ostati base-relativne.");
foreach (var glyph in new[] { '\u203A', '\u2713', '\u26A0' })
  Assert(!markup.Contains(glyph), "Unicode nadomestne ikone niso dovoljene; uporabi CSS obliko.");

// 15. Varovalka: referenčna slika ni podatkovna pogodba.
// Našteto so polja, zavihki in dejanja z uvozi_izvozi.png, ki jih OutboundRow ne vrača.
foreach (var fabricated in new[] { "Nov izvoz", "SAOP", "Magento", "Splet (CSV)", "Zgodovina izvozov", "Tip izvoza",
  "Št. izdelkov", "Uporabnik", "Kanal", "Prenesi", "Osveži", "Vrstic na stran", "Izbranih", "Predogled",
  "Poglej zgodovino", "Odpri", "Stolpci", "Počisti vse", "Nastavitve" })
  Assert(!markup.Contains(fabricated, StringComparison.Ordinal), "Stran ne sme prikazovati izmišljene vsebine: " + fabricated + ".");
foreach (var literal in new[] { "214", "327", "9.900", "9.812", "9.785", "Janez Novak", "24.07.2026" })
  Assert(!markup.Contains(literal, StringComparison.Ordinal), "Številke in imena iz UX slike se ne prepisujejo v kodo: " + literal + ".");

Console.WriteLine("F10 outbound UX contract PASS.");

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
