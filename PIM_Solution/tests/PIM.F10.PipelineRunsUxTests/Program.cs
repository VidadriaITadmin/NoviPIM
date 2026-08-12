using System.Text.RegularExpressions;

// Pogodbeni test UX skladnosti strani uvozov.
// Obseg je namenoma ozek: samo predstavitev in dostopnost strani /teki-obdelave.
// Referenca `../PIM_test/UX_pictures/uvozi.png` prikazuje tudi zavihke Viri/Novi izdelki/Excel,
// tip uvoza, uporabnika, dejanji »Nastavitve« in »Nov uvoz« ter izbiro vrstic na stran;
// `PipelineRunRow` in `intranet.GetPipelineRuns` teh podatkov ne vračata, zato niso del pogodbe.
// Test ne sme zahtevati novih poizvedb, novih stolpcev, novih vrednosti ali akcij pisanja.

var root = FindRoot();
var razorPath = Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", "PipelineRuns.razor");
var cssPath = Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", "PipelineRuns.razor.css");

Assert(File.Exists(razorPath), "Manjka stran uvozov: " + razorPath);
Assert(File.Exists(cssPath), "Manjka izoliran slog uvozov: " + cssPath);

var markup = File.ReadAllText(razorPath);
var css = File.ReadAllText(cssPath);

// 1. Pot, avtorizacija in naslov strani ostanejo nespremenjeni.
Assert(markup.Contains("@page \"/teki-obdelave\"", StringComparison.Ordinal), "Pot strani /teki-obdelave se ne sme spremeniti.");
Assert(markup.Contains("@attribute [Authorize]", StringComparison.Ordinal), "Avtorizacija strani se ne sme spremeniti.");
Assert(Regex.IsMatch(markup, "<h1>Uvozi</h1>"), "Stran mora ohraniti vidni naslov <h1>Uvozi</h1>.");

// 2. Kontekstni zavihki so navigacijski sklop; aktivni zavihek se sporoči bralcu zaslona.
var tabs = Regex.Match(markup, "<nav[^>]*class=\"page-tabs\"[^>]*>");
Assert(tabs.Success, "Zavihki morajo biti navigacijski sklop <nav class=\"page-tabs\">.");
Assert(Regex.IsMatch(tabs.Value, "aria-label=\"[^\"]+\""), "Zavihki morajo imeti aria-label.");
Assert(Regex.Matches(markup, "class=\"page-tab(?!s)").Count == 2,
  "Stran ima dva podatkovno podprta zavihka; »Viri«, »Novi izdelki« in »Excel« iz reference nimajo vira.");
Assert(Regex.IsMatch(markup, "class=\"page-tab active\"[^>]*aria-current=\"page\""), "Aktivni zavihek mora imeti aria-current=\"page\".");
Assert(Regex.IsMatch(markup, "<a class=\"page-tab\" href=\"outbound\">Izvozi</a>"), "Povezava na izvoze mora ostati nespremenjena.");

// 3. Kartice virov so poimenovan sklop z naslovom vira; vsaka vrednost izhaja iz zadnjega teka.
var sourceGrid = Regex.Match(markup, "<section[^>]*class=\"source-grid\"[^>]*>");
Assert(sourceGrid.Success, "Kartice virov morajo biti v poimenovanem sklopu <section class=\"source-grid\">.");
Assert(Regex.IsMatch(sourceGrid.Value, "aria-label=\"[^\"]+\""), "Sklop kartic virov mora imeti aria-label.");
Assert(Regex.Matches(markup, "class=\"ui-card source-card\"").Count == 1,
  "Kartica vira se izriše enkrat, v zanki nad dejanskimi viri, ne kot ponovljena predloga.");
Assert(Regex.IsMatch(markup, "<article class=\"ui-card source-card\""), "Kartica vira mora biti samostojna vsebina <article>.");
Assert(Regex.IsMatch(markup, "<h2 class=\"source-name\">"), "Ime vira mora biti naslov <h2 class=\"source-name\">, ne zgolj krepko besedilo.");
Assert(Regex.IsMatch(markup, "@foreach\\s*\\(var source in Sources\\)"), "Kartice virov morajo izhajati iz obstoječega izračuna Sources.");
Assert(Regex.IsMatch(markup, "var last\\s*=\\s*source\\.First\\(\\);"), "Kartica vira mora prikazati zadnji dejanski tek vira.");
foreach (var term in new[] { "<dt>Zadnji tek</dt>", "<dt>Napake</dt>" })
  Assert(markup.Contains(term, StringComparison.Ordinal), "Kartica vira mora ohraniti postavko " + term + ".");
Assert(markup.Contains("<dt>Prebrane vrstice</dt>", StringComparison.Ordinal),
  "RowsRead so prebrane vrstice; oznaka mora povedati, kaj vrednost je.");

// 4. Orodna vrstica je poimenovan iskalni sklop, vsaka kontrola pa ima svojo oznako.
var toolbar = Regex.Match(markup, "<section[^>]*class=\"ui-card toolbar\"[^>]*>");
Assert(toolbar.Success, "Orodna vrstica mora ostati <section class=\"ui-card toolbar\">.");
Assert(toolbar.Value.Contains("role=\"search\"", StringComparison.Ordinal), "Orodna vrstica mora biti razglašena kot role=\"search\".");
var toolbarLabel = Regex.Match(toolbar.Value, "aria-labelledby=\"([^\"]+)\"");
Assert(toolbarLabel.Success, "Iskalni sklop mora imeti aria-labelledby.");
Assert(Regex.IsMatch(markup, "<h2 id=\"" + Regex.Escape(toolbarLabel.Groups[1].Value) + "\" class=\"visually-hidden\">"),
  "Naslov iskalnega sklopa mora ostati bralcem zaslona dostopen in vizualno skrit.");
foreach (var control in new[] { "run-search", "run-status" })
  Assert(Regex.IsMatch(markup, "<label[^>]*for=\"" + control + "\""), "Kontrola " + control + " nima povezane oznake <label for>.");
Assert(Regex.IsMatch(markup, "<input id=\"run-search\"[^>]*type=\"search\""), "Iskalno polje mora biti type=\"search\".");

// 5. Filter statusa mora uporabniku pokazati isto besedišče kot tabela; vrednost ostane izvorna.
Assert(Regex.IsMatch(markup, "<option value=\"@status\">@Status\\(status\\)</option>"),
  "Možnost filtra mora prikazati prevedeni status, vezana vrednost pa mora ostati izvorni status iz baze.");

// 6. Število rezultatov oziroma stanje nalaganja/napake se mora sporočati v živo.
var count = Regex.Match(markup, "<span class=\"result-count\"[^>]*>");
Assert(count.Success, "Orodna vrstica mora ohraniti izpis števila rezultatov.");
foreach (var attribute in new[] { "role=\"status\"", "aria-live=\"polite\"" })
  Assert(count.Value.Contains(attribute, StringComparison.Ordinal), "Izpis rezultatov nima " + attribute + ": " + count.Value);
Assert(Regex.IsMatch(markup, "string ResultSummary=>Loading\\?"), "Izpis rezultatov mora pošteno ločiti nalaganje, napako in dejansko število.");
Assert(Regex.IsMatch(markup, "class=\"loading-state\"[^>]*role=\"status\""), "Stanje nalaganja mora biti razglašeno kot role=\"status\".");
Assert(Regex.IsMatch(markup, "class=\"error-state\"[^>]*role=\"alert\""), "Stanje napake mora biti razglašeno kot role=\"alert\".");
Assert(markup.Contains("class=\"empty-state\"", StringComparison.Ordinal), "Stran mora ohraniti prazno stanje.");

// 7. Statusni čipi ne smejo biti razločljivi samo po barvi.
var chipCount = Regex.Matches(markup, "class=\"status-chip ").Count;
Assert(chipCount == 2, "Čip statusa ostane na kartici vira in v vrstici zgodovine, brez novih statusov.");
Assert(Regex.Matches(markup, "<span class=\"visually-hidden\">Status: </span>").Count == chipCount,
  "Vsak statusni čip mora imeti bralcem zaslona namenjeno oznako \"Status: \".");

// 8. Tabela mora ostati berljiva in se na ozkih zaslonih vodoravno pomikati.
var scroll = Regex.Match(markup, "<div class=\"table-scroll\"[^>]*>");
Assert(scroll.Success, "Tabela mora biti v ovoju <div class=\"table-scroll\"> zaradi prelivanja.");
foreach (var attribute in new[] { "role=\"region\"", "tabindex=\"0\"", "aria-label=" })
  Assert(scroll.Value.Contains(attribute, StringComparison.Ordinal), "Pomični ovoj tabele nima " + attribute + ": " + scroll.Value);
Assert(Regex.IsMatch(markup, "<caption>"), "Tabela mora ohraniti napis <caption>.");
Assert(Regex.Matches(markup, "<th scope=\"col\"").Count == 8, "Tabela mora ohraniti natanko osem obstoječih stolpcev z scope=\"col\".");
Assert(Regex.Matches(markup, "class=\"numeric\"").Count >= 6,
  "Trije količinski stolpci morajo biti poravnani desno v glavi in v celicah.");
Assert(Regex.IsMatch(css, "\\.table-scroll\\s*\\{[^}]*overflow-x:\\s*auto"), "Ovoj tabele mora imeti overflow-x: auto.");
Assert(Regex.IsMatch(css, "\\.numeric\\s*\\{[^}]*text-align:\\s*right"), "Številski stolpci morajo biti poravnani desno.");
Assert(Regex.IsMatch(css, "\\.numeric\\s*\\{[^}]*font-variant-numeric:\\s*tabular-nums"), "Številski stolpci morajo uporabljati tabelarične številke.");

// 9. Odzivnost: niti tabela niti mreža virov se na ozkih zaslonih ne smeta stiskati.
Assert(Regex.IsMatch(css, "@media[^{]*max-width:\\s*900px"), "Manjka odzivno pravilo za ozke zaslone.");
Assert(Regex.IsMatch(css, "\\.data-table\\s*\\{[^}]*min-width:"), "Na ozkih zaslonih se tabela ne sme stiskati; potrebna je min-width.");
Assert(Regex.IsMatch(css, "\\.source-grid\\s*\\{[^}]*grid-template-columns:\\s*1fr"),
  "Skupna mreža virov ima tri stolpce; na ozkih zaslonih se mora zložiti v enega.");

// 10. Paginacija mora ostati vidna in dostopna.
var pagination = Regex.Match(markup, "<nav class=\"pagination\"[^>]*>");
Assert(pagination.Success, "Paginacija mora ostati <nav class=\"pagination\">.");
Assert(Regex.IsMatch(pagination.Value, "aria-label=\"[^\"]+\""), "Paginacija mora imeti aria-label.");
Assert(Regex.Matches(markup, "<button type=\"button\"").Count == 2,
  "Obe strani morata biti izrecna gumba type=\"button\" brez oddajanja obrazca.");

// 11. Tipkovnični fokus mora biti viden na vseh interaktivnih elementih strani.
foreach (var selector in new[] { ".page-tab", ".search-input", ".filter-select", ".pagination button", ".table-scroll" })
  Assert(css.Contains(selector + ":focus-visible", StringComparison.Ordinal), "Manjka slog fokusa za " + selector + ".");
Assert(Regex.IsMatch(css, ":focus-visible[^{]*\\{[^}]*outline:"), "Fokus mora risati obris, ne samo sence.");
Assert(!css.Contains("::deep", StringComparison.Ordinal), "Izoliran slog ne sme uhajati z ::deep.");

// 12. Varovalka: stran ostane vezana na obstoječi resnični poizvedbi.
var allowedCalls = new[] { "GetCurrentOrganizationAsync", "GetPipelineRunsAsync" };
foreach (var call in allowedCalls)
  Assert(markup.Contains("Data." + call, StringComparison.Ordinal), "Stran mora ohraniti klic " + call + ".");
foreach (Match call in Regex.Matches(markup, "Data\\.(\\w+)"))
  Assert(allowedCalls.Contains(call.Groups[1].Value, StringComparer.Ordinal), "Nova podatkovna poizvedba ni v obsegu naloge: " + call.Value);
Assert(!markup.Contains("Async(2,", StringComparison.Ordinal), "Stran ne sme uporabljati hardkodirane organizacije 2.");

// 13. Varovalka: obstoječe filtriranje, združevanje virov in paginacija ostanejo nedotaknjeni.
foreach (var behavior in new[]
{
  "const int PageSize=10",
  "Skip(Page*PageSize).Take(PageSize)",
  "GroupBy(x=>x.SourceCode??x.Pipeline)",
  "(FilterStatus==\"\"||x.Status==FilterStatus)",
  "x.Pipeline.Contains(Search,StringComparison.OrdinalIgnoreCase)",
  "x.SourceCode?.Contains(Search,StringComparison.OrdinalIgnoreCase)??false",
  "@bind=\"Search\"",
  "@bind:event=\"oninput\"",
  "@bind=\"FilterStatus\"",
  "Rows=await Data.GetPipelineRunsAsync(org.OrganizationId);",
  "Error=\"Aktivna organizacija ni na voljo.\"",
  "Error=\"Uvozov trenutno ni mogoče naložiti.\"",
  "value==\"Succeeded\"?\"good\":value is \"Failed\" or \"Cancelled\"?\"bad\":\"warn\"",
  "\"Succeeded\"=>\"Uspešno\"",
  "\"Failed\"=>\"Napaka\"",
  "\"Cancelled\"=>\"Preklicano\"",
  "\"Running\"=>\"V teku\"",
  "\"Pending\"=>\"Čaka\"",
  "_=>value",
})
  Assert(markup.Contains(behavior, StringComparison.Ordinal), "Obstoječe ravnanje strani je spremenjeno; manjka: " + behavior);
var allowedHandlers = new[] { "Previous", "Next" };
foreach (Match handler in Regex.Matches(markup, "@onclick=['\"](?:\\(\\)=>)?(\\w+)"))
  Assert(allowedHandlers.Contains(handler.Groups[1].Value, StringComparer.Ordinal), "Novo dejanje ni v obsegu naloge: " + handler.Value);
Assert(Regex.Matches(markup, "@onclick=").Count == 2, "Število dejanj na strani se ne sme spremeniti.");

// 14. Varovalka: gre za predstavitveni sklop brez akcij pisanja in brez nepodprtih kontrol.
foreach (var forbidden in new[] { "<form", "@onsubmit", "method=\"post\"", "<img", "type=\"checkbox\"", "type=\"file\"", "<dialog", "contenteditable" })
  Assert(!markup.Contains(forbidden, StringComparison.OrdinalIgnoreCase), "Predstavitveni sklop ne sme uvesti " + forbidden + ".");
Assert(!markup.Contains('\u203A'), "Unicode nadomestne ikone niso dovoljene; uporabi CSS obliko.");

// 15. Varovalka: povezave ostanejo base-relativne, da delujejo tudi pod virtualno potjo /PIM.
foreach (Match link in Regex.Matches(markup, "href=\"([^\"]*)\""))
  Assert(!link.Groups[1].Value.StartsWith('/'), "Povezava mora ostati base-relativna: " + link.Value);

// 16. Varovalka: referenčna slika ni podatkovna pogodba.
// Našteto so polja in dejanja z uvozi.png, ki jih PipelineRunRow oziroma GetPipelineRuns ne vračata.
foreach (var fabricated in new[]
{
  "Novi izdelki", "Excel", "Nov uvoz", "Nastavitve", "Poglej napako", "Osveži", "Uporabnik",
  "Celoten uvoz", "Delni uvoz", "Posodobitev", "Uvožene vrstice", "Vrstic na stran", "Prikazujem",
  "Akcije", "Stolpci", "Izbranih", "API", "MANUAL", "Ročni vnos", "Zaženi uvoz",
})
  Assert(!Regex.IsMatch(markup, "\\b" + Regex.Escape(fabricated) + "\\b"),
    "Stran ne sme prikazovati izmišljene vsebine: " + fabricated + ".");
foreach (var literal in new[] { "12.480", "54.213", "23.876", "8.913", "1.934", "8.902", "3.120", "2.856" })
  Assert(!markup.Contains(literal, StringComparison.Ordinal), "Številke iz UX slike se ne prepisujejo v kodo: " + literal + ".");

Console.WriteLine("F10 pipeline runs UX contract PASS.");

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
