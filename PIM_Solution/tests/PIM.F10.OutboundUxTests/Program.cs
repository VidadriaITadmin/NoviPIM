using System.Text.RegularExpressions;

// Pogodbeni test UX skladnosti odhodne vrste v SAOP: stran /outbound (naslov »Izvozi«).
// Obseg je namenoma ozek: predstavitev, dostopnost in varovalke strani.
// Pogodba sledi prenovi strani (e857b69, 2026-09-18): hitri pregled s štirimi karticami je bil
// odstranjen, stran je zdaj ena vrstica na artikel z izbiro vrstic in skupinskimi dejanji,
// izbirnikom podjetja, predogledom XML in podrobnostmi po polju za administratorja (naloga #20).
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

// 2. Zavihkov cez strani ni. Odlocitev uporabnika 2026-08-28: vrstica zavihkov, v kateri
// povezava odnese na drugo pot, je past — videti je kot preklop pogleda, v resnici pa zamenja
// stran in z njo celo navigacijsko drevo. Prejsnja pogodba je tak vzorec zahtevala; zahteva je
// odpravljena, prepoved cez vse strani pa je zdaj v PIM.F10.AuthTests.
Assert(!Regex.IsMatch(markup, "<nav[^>]*class=\"page-tabs\"", RegexOptions.IgnoreCase),
  "Vrstice zavihkov, ki vodi na druge strani, tu ne sme biti.");
Assert(markup.Contains("<PimTabs Active=\"queue\" Tabs=\"SaopTabs.Tabs\"", StringComparison.Ordinal),
  "Pogledi izhoda v SAOP morajo ostati skupni gradnik PimTabs z aktivnim pogledom queue.");

// 3. Stran jasno pove, v katerem podjetju dela, in ob menjavi ne pomeša podatkov.
// (Hitri pregled s štirimi karticami je bil ob prenovi 18. 9. namenoma odstranjen.)
Assert(Regex.IsMatch(markup, "<select id=\"out-org\"[^>]*@onchange=\"OnOrganizationChangedAsync\""),
  "Izbirnik podjetja out-org mora ostati in ob spremembi klicati OnOrganizationChangedAsync.");
Assert(markup.Contains("@foreach (var organization in Organizations)", StringComparison.Ordinal),
  "Seznam podjetij mora izhajati iz naloženih organizacij, ne iz vpisanega seznama.");
var orgChange = Regex.Match(markup, "async Task OnOrganizationChangedAsync\\(ChangeEventArgs args\\)\\s*\\{(?<body>.*?)\\n  \\}", RegexOptions.Singleline);
Assert(orgChange.Success, "Manjka metoda OnOrganizationChangedAsync.");
foreach (var reset in new[] { "Selected.Clear();", "Page = 0;", "OrgContext.OrganizationId = organizationId;" })
  Assert(orgChange.Groups["body"].Value.Contains(reset, StringComparison.Ordinal),
    "Menjava podjetja mora počistiti izbor in stran ter nastaviti kontekst; manjka: " + reset);
// 301: stran bere samo nezaključena sporočila; vseh je lahko 50.000+.
Assert(markup.Contains("Data.GetOutboundAsync(OrganizationId.Value,onlyActive:true)", StringComparison.Ordinal),
  "Stran mora brati samo nezaključena sporočila (onlyActive:true).");

// 4. Orodna vrstica je poimenovan iskalni sklop, vsaka kontrola pa ima svojo oznako.
var toolbar = Regex.Match(markup, "<section[^>]*class=\"ui-card toolbar\"[^>]*>");
Assert(toolbar.Success, "Orodna vrstica mora ostati <section class=\"ui-card toolbar\">.");
Assert(toolbar.Value.Contains("role=\"search\"", StringComparison.Ordinal), "Orodna vrstica mora biti razglašena kot role=\"search\".");
var toolbarLabel = Regex.Match(toolbar.Value, "aria-labelledby=\"([^\"]+)\"");
Assert(toolbarLabel.Success, "Iskalni sklop mora imeti aria-labelledby.");
AssertHeading(markup, toolbarLabel.Groups[1].Value, "iskalnega sklopa izvozov");
foreach (var control in new[] { "out-org", "out-search", "out-status" })
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

// 6. Statusni čip ne sme biti razločljiv samo po barvi (tabela artiklov in podrobnosti po polju).
var chipCount = Regex.Matches(markup, "class=\"status-chip ").Count;
Assert(chipCount == 2, "Stran ima natanko dva statusna čipa: artikel in sporočilo po polju.");
Assert(Regex.Matches(markup, "<span class=\"visually-hidden\">Status: </span>").Count == chipCount,
  "Statusni čip mora imeti bralcem zaslona namenjeno oznako \"Status: \".");
Assert(Regex.Matches(markup, "<span class=\"status-chip @Chip\\(\\w+\\.Status\\)\"><span class=\"visually-hidden\">Status: </span>@StatusLabel\\(\\w+\\.Status\\)</span>").Count == chipCount,
  "Čip mora barvo dobiti iz Chip, besedilo pa iz StatusLabel.");
Assert(Regex.IsMatch(markup, "static string Chip\\(string"), "Barvna razvrstitev statusa mora ostati v obstoječi funkciji Chip.");
Assert(Regex.IsMatch(markup, "static string StatusLabel\\(string"), "Naziv statusa mora ostati v funkciji StatusLabel.");
foreach (var group in new[] { "\"Verified\" or \"Succeeded\" or \"Completed\"", "\"Error\" or \"Dead\" or \"Drift\" or \"Cancelled\"" })
  Assert(markup.Contains(group, StringComparison.Ordinal), "Obstoječa razvrstitev statusov je spremenjena; manjka: " + group);
foreach (var label in new[] { "\"PendingApproval\" => \"Čaka odobritev\"", "\"Error\" or \"Dead\" or \"Drift\" => \"Napaka\"", "_ => \"V obdelavi\"" })
  Assert(markup.Contains(label, StringComparison.Ordinal), "Naziv statusa je spremenjen; manjka: " + label);

// 7. Tabela ostane berljiva in se na ozkih zaslonih vodoravno pomika.
var dataCard = Regex.Match(markup, "<section class=\"ui-card data-card\"[^>]*>");
Assert(dataCard.Success, "Seznam mora ostati v <section class=\"ui-card data-card\">.");
Assert(dataCard.Value.Contains("aria-label=", StringComparison.Ordinal), "Podatkovna kartica nima aria-label: " + dataCard.Value);
var scrolls = Regex.Matches(markup, "<div class=\"table-scroll\"[^>]*>");
Assert(scrolls.Count == 2, "Obe tabeli (artikli in podrobnosti po polju) morata biti v ovoju <div class=\"table-scroll\">.");
foreach (Match scroll in scrolls)
  foreach (var attribute in new[] { "role=\"region\"", "tabindex=\"0\"", "aria-label=" })
    Assert(scroll.Value.Contains(attribute, StringComparison.Ordinal), "Pomični ovoj tabele nima " + attribute + ": " + scroll.Value);
var tables = Regex.Matches(markup, "<table class=\"data-table\">(?<body>.*?)</table>", RegexOptions.Singleline);
Assert(tables.Count == 2, "Stran ima natanko dve podatkovni tabeli.");
var expectedColumns = new[] { 8, 10 };
for (var i = 0; i < tables.Count; i++)
{
  var table = tables[i].Groups["body"].Value;
  Assert(table.StartsWith("<caption>", StringComparison.Ordinal), "Vsaka tabela mora imeti napis <caption>.");
  Assert(Regex.Matches(table, "<th scope=\"col\"").Count == expectedColumns[i],
    "Tabela " + (i + 1) + " mora ohraniti natanko " + expectedColumns[i] + " obstoječih stolpcev z scope=\"col\".");
}
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

// 9. Vsi gumbi so izrecno type="button"; dejanja, ki spremenijo stanje, so med izvajanjem onemogočena,
// ponovljena vrstična dejanja pa imajo razločljivo ime s šifro artikla.
Assert(!Regex.IsMatch(markup, "<button(?![^>]*type=\"button\")"), "Vsak gumb mora biti izrecno type=\"button\".");
foreach (var handler in new[] { "ApproveSelected", "CancelSelected", "VerifyEchoesAsync", "()=>Approve(", "()=>Cancel(", "()=>RetryArticle(", "()=>RetryMessage(", "()=>SendNow(" })
{
  var buttons = Regex.Matches(markup, "<button[^>]*@onclick=\"" + Regex.Escape(handler) + "[^>]*>");
  Assert(buttons.Count > 0, "Manjka obstoječe dejanje " + handler + ".");
  foreach (Match button in buttons)
    Assert(Regex.IsMatch(button.Value, "disabled=\"@\\(?[^\"]*ActionBusy"), "Dejanje mora biti med izvajanjem onemogočeno: " + button.Value);
}
var rowActions = Regex.Matches(markup, "<button[^>]*@onclick=\"\\(\\)=>(Approve|Cancel|RetryArticle|RetryMessage|SendNow|OpenXmlAsync|OpenError|OpenErrorForRow)\\([^>]*>");
Assert(rowActions.Count == 10, "Vrstična dejanja obeh tabel morajo ostati: šest pri artiklu, štiri pri sporočilu po polju.");
foreach (Match button in rowActions)
  Assert(Regex.IsMatch(button.Value, "aria-label=\"[^\"]*@\\w+\\.EntityKey"),
    "Ponovljeno vrstično dejanje mora imeti razločljiv aria-label s šifro artikla: " + button.Value);

// 9a. Izbira vrstic in skupinska dejanja: poimenovana orodna vrstica, oznake potrditvenih polj.
var bulk = Regex.Match(markup, "<section class=\"ui-card toolbar bulk-actions\"[^>]*>");
Assert(bulk.Success, "Skupinska dejanja morajo ostati v <section class=\"ui-card toolbar bulk-actions\">.");
Assert(bulk.Value.Contains("role=\"toolbar\"", StringComparison.Ordinal) && bulk.Value.Contains("aria-label=", StringComparison.Ordinal),
  "Vrstica skupinskih dejanj mora biti role=\"toolbar\" z aria-label.");
Assert(markup.Contains("@if (Selected.Count > 0) {", StringComparison.Ordinal), "Skupinska dejanja se pokažejo šele ob izbiri.");
Assert(markup.Contains("Izbranih artiklov: @Selected.Count", StringComparison.Ordinal), "Vrstica skupinskih dejanj mora povedati, koliko je izbranih.");
var checkboxes = Regex.Matches(markup, "<input type=\"checkbox\"[^>]*>");
Assert(checkboxes.Count == 2, "Stran ima dve potrditveni polji: izberi vse na strani in izbira vrstice.");
foreach (Match checkbox in checkboxes)
  Assert(checkbox.Value.Contains("aria-label=", StringComparison.Ordinal), "Potrditveno polje nima aria-label: " + checkbox.Value);
Assert(markup.Contains("Izberi vse filtrirane (@SelectableFilteredCount)", StringComparison.Ordinal),
  "Izbira vseh, ki ustrezajo filtru, mora ostati s številom.");
Assert(markup.Contains("FilteredArticles.Where(a=>a.CanApprove||a.CanCancel)", StringComparison.Ordinal),
  "Izbira vseh filtriranih sme zajeti samo artikle, ki jih je mogoče odobriti ali preklicati.");

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
var allowedCalls = new[] { "GetOrganizationsAsync", "GetCurrentOrganizationAsync", "GetOutboundAsync", "ApproveItemAsync", "CancelItemAsync", "RetryOutboundAsync" };
foreach (var call in allowedCalls)
  Assert(markup.Contains("Data." + call, StringComparison.Ordinal), "Stran mora ohraniti klic " + call + ".");
foreach (Match call in Regex.Matches(markup, "(?<![\\w.])Data\\.(\\w+)"))
  Assert(allowedCalls.Contains(call.Groups[1].Value, StringComparer.Ordinal), "Nova podatkovna poizvedba ni v obsegu naloge: " + call.Value);
var allowedServiceCalls = new[] { "Write.TrySendArticleAsync", "Write.GetPendingOverlayAsync", "ItemWrite.PreviewQueuedAsync", "Workbook.VerifyPendingEchoesAsync" };
foreach (Match call in Regex.Matches(markup, "\\b(Write|ItemWrite|Workbook)\\.(\\w+)"))
  Assert(allowedServiceCalls.Contains(call.Value, StringComparer.Ordinal), "Nov klic storitve SAOP ni v obsegu naloge: " + call.Value);
Assert(markup.Contains("state.User.Identity?.Name", StringComparison.Ordinal),
  "Izvajalec dejanja mora ostati prijavljeni uporabnik, ne vpisana vrednost.");
// Rdeča črta: nič se ne pošlje v SAOP ob odprtju ali osvežitvi strani, samo ob kliku uporabnika.
foreach (var passive in new[] { "protected override async Task OnInitializedAsync()", "async Task Reload()", "async Task RefreshAsync()" })
{
  var line = markup.Split('\n').FirstOrDefault(l => l.Contains(passive, StringComparison.Ordinal));
  Assert(line is not null, "Manjka " + passive + ".");
  Assert(!line!.Contains("Write.", StringComparison.Ordinal) && !line.Contains("Approve", StringComparison.Ordinal),
    "Nalaganje strani ne sme pošiljati ali odobravati: " + passive);
}

// 13. Varovalka: obstoječe filtriranje, statusi in pogoji dejanj ostanejo nedotaknjeni.
foreach (var behavior in new[] { "@bind=\"Search\"", "@bind:event=\"oninput\"", "@bind=\"StatusFilter\"", "const int PageSize=10" })
  Assert(markup.Contains(behavior, StringComparison.Ordinal), "Obstoječe ravnanje s filtri je spremenjeno; manjka: " + behavior);
Assert(Regex.IsMatch(markup, "Select\\(\\w+ ?=> ?\\w+\\.Status\\)\\.Distinct\\(\\)"),
  "Seznam statusov mora ostati izpeljan iz naloženih vrstic, ne iz vpisanega seznama.");
foreach (var condition in new[] { "row.Status==\"PendingApproval\"", "\"PendingApproval\" or \"Pending\" or \"Error\" or \"Retry\"", "row.Status is \"Error\" or \"Dead\"" })
  Assert(markup.Contains(condition, StringComparison.Ordinal), "Pogoj razpoložljivosti dejanja je spremenjen; manjka: " + condition);

// 14. Varovalka: brez novih zapisovalnih poti in nepodprtih kontrol.
foreach (var forbidden in new[] { "<form", "@onsubmit", "method=\"post\"", "<img", "type=\"file\"", "<dialog", "contenteditable" })
  Assert(!markup.Contains(forbidden, StringComparison.OrdinalIgnoreCase), "Stran ne sme uvesti " + forbidden + ".");
Assert(!markup.Contains("href=\"/", StringComparison.Ordinal), "Notranje povezave morajo ostati base-relativne.");
foreach (var glyph in new[] { '\u203A', '\u2713', '\u26A0' })
  Assert(!markup.Contains(glyph), "Unicode nadomestne ikone niso dovoljene; uporabi CSS obliko.");

// 15. Varovalka: referenčna slika ni podatkovna pogodba.
// Našteto so polja, zavihki in dejanja z uvozi_izvozi.png, ki jih OutboundRow ne vrača.
// (»Osveži«, »Izbranih«, »Predogled« in »SAOP« so po prenovi resnična dejanja strani, zato niso več na seznamu.)
foreach (var fabricated in new[] { "Nov izvoz", "Magento", "Splet (CSV)", "Zgodovina izvozov", "Tip izvoza",
  "Št. izdelkov", "Kanal", "Prenesi", "Vrstic na stran", "Poglej zgodovino", "Stolpci", "Počisti vse", "Nastavitve" })
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
