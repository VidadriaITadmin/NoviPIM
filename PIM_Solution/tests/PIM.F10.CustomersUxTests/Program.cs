using System.Text.RegularExpressions;

// Pogodbeni test UX skladnosti seznama strank.
// Obseg je namenoma ozek: samo predstavitev in dostopnost strani /stranke.
// Test ne sme zahtevati novih poizvedb, novih stolpcev, novih vrednosti ali akcij pisanja.
// Referenca `../PIM_test/UX_pictures/Stranke.png` prikazuje tudi plačnika, cenik, status,
// čas posodobitve, množično izbiro in izvoz; za te ni read modela, zato niso del pogodbe.

var root = FindRoot();
var razorPath = Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", "Customers.razor");
var cssPath = Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", "Customers.razor.css");

Assert(File.Exists(razorPath), "Manjka stran strank: " + razorPath);
Assert(File.Exists(cssPath), "Manjka izoliran slog strank: " + cssPath);

var markup = File.ReadAllText(razorPath);
var css = File.ReadAllText(cssPath);

// 1. Pot, avtorizacija in naslov strani ostanejo nespremenjeni.
Assert(markup.Contains("@page \"/stranke\"", StringComparison.Ordinal), "Pot strani /stranke se ne sme spremeniti.");
Assert(markup.Contains("@attribute [Authorize(Roles = \"ADMIN,CATALOG_EDITOR,COMMERCIAL\")]", StringComparison.Ordinal),
  "Avtorizacijske vloge strani se ne smejo spremeniti.");
Assert(Regex.IsMatch(markup, "<h1>Stranke</h1>"), "Stran mora ohraniti vidni naslov <h1>Stranke</h1>.");

// 2. Kontekstni zavihki so navigacijski sklop; aktivni zavihek se sporoči bralcu zaslona.
var tabs = Regex.Match(markup, "<nav[^>]*class=\"page-tabs\"[^>]*>");
Assert(tabs.Success, "Zavihki morajo biti navigacijski sklop <nav class=\"page-tabs\">.");
Assert(Regex.IsMatch(tabs.Value, "aria-label=\"[^\"]+\""), "Zavihki morajo imeti aria-label.");
Assert(Regex.Matches(markup, "class=\"page-tab(?!s)").Count == 4,
  "Stran ima štiri zavihke, podprte z obstoječim CustomerKind; dodatnih zavihkov brez podatkovnega vira ni dovoljeno ustvariti.");
var tabElements = Regex.Matches(markup, "<button[^>]*class=\"page-tab.*?</button>", RegexOptions.Singleline);
Assert(tabElements.Count == 4, "Vsak zavihek mora ostati gumb <button class=\"page-tab …\">.");
foreach (Match tab in tabElements)
{
  Assert(tab.Value.Contains("type=\"button\"", StringComparison.Ordinal), "Zavihek mora biti type=\"button\": " + tab.Value);
  Assert(tab.Value.Contains("aria-current=", StringComparison.Ordinal), "Zavihek mora sporočati aria-current: " + tab.Value);
  Assert(Regex.IsMatch(tab.Value, "aria-current=\"@\\("), "aria-current mora slediti dejansko izbranemu zavihku: " + tab.Value);
  Assert(tab.Value.Contains("@onclick=", StringComparison.Ordinal), "Zavihek mora ostati interaktiven: " + tab.Value);
}

// 3. Števci zavihkov izhajajo iz naloženih vrstic, ne iz vpisanih vrednosti.
Assert(Regex.Matches(markup, "@KindCount\\(").Count == 4, "Vsak zavihek mora izpisati števec iz dejanskih vrstic.");
Assert(Regex.IsMatch(markup, "int KindCount\\(string [A-Za-z]+\\)=>\\(Rows\\?\\?\\[\\]\\)\\.Count\\("),
  "Števec zavihka se mora izračunati iz naloženih strank, ne iz ločene poizvedbe.");
Assert(!Regex.IsMatch(markup, "class=\"page-tab[^>]*>[^<]*\\(\\s*\\d"), "Števci zavihkov ne smejo biti vpisane vrednosti.");

// 4. Orodna vrstica je poimenovan iskalni sklop, vsaka kontrola pa ima svojo oznako.
var toolbar = Regex.Match(markup, "<section[^>]*class=\"ui-card toolbar\"[^>]*>");
Assert(toolbar.Success, "Orodna vrstica mora ostati <section class=\"ui-card toolbar\">.");
Assert(toolbar.Value.Contains("role=\"search\"", StringComparison.Ordinal), "Orodna vrstica mora biti razglašena kot role=\"search\".");
var toolbarLabel = Regex.Match(toolbar.Value, "aria-labelledby=\"([^\"]+)\"");
Assert(toolbarLabel.Success, "Iskalni sklop mora imeti aria-labelledby.");
Assert(Regex.IsMatch(markup, "<h2 id=\"" + Regex.Escape(toolbarLabel.Groups[1].Value) + "\" class=\"visually-hidden\">"),
  "Naslov iskalnega sklopa mora ostati bralcem zaslona dostopen in vizualno skrit.");
foreach (var control in new[] { "customer-search", "customer-type" })
  Assert(Regex.IsMatch(markup, "<label[^>]*for=\"" + control + "\""), "Kontrola " + control + " nima povezane oznake <label for>.");
Assert(Regex.IsMatch(markup, "<input id=\"customer-search\"[^>]*type=\"search\""), "Iskalno polje mora biti type=\"search\".");

// 5. Število rezultatov oziroma stanje nalaganja/napake se mora sporočati v živo.
var count = Regex.Match(markup, "<span class=\"result-count\"[^>]*>");
Assert(count.Success, "Orodna vrstica mora ohraniti izpis števila rezultatov.");
foreach (var attribute in new[] { "role=\"status\"", "aria-live=\"polite\"" })
  Assert(count.Value.Contains(attribute, StringComparison.Ordinal), "Izpis rezultatov nima " + attribute + ": " + count.Value);
Assert(Regex.IsMatch(markup, "string ResultSummary=>Loading\\?"), "Izpis rezultatov mora pošteno ločiti nalaganje, napako in dejansko število.");
Assert(Regex.IsMatch(markup, "class=\"loading-state\"[^>]*role=\"status\""), "Stanje nalaganja mora biti razglašeno kot role=\"status\".");
Assert(Regex.IsMatch(markup, "class=\"error-state\"[^>]*role=\"alert\""), "Stanje napake mora biti razglašeno kot role=\"alert\".");
Assert(markup.Contains("class=\"empty-state\"", StringComparison.Ordinal), "Stran mora ohraniti prazno stanje.");

// 6. Statusni čipi ne smejo biti razločljivi samo po barvi.
var chipCount = Regex.Matches(markup, "class=\"status-chip ").Count;
Assert(chipCount == 2, "Seznam mora ohraniti obstoječa čipa B2B+ in Splet, brez novih statusov.");
Assert(Regex.Matches(markup, "class=\"status-chip [^>]*><span class=\"visually-hidden\">[^<]+</span>").Count == chipCount,
  "Vsak statusni čip mora imeti bralcem zaslona namenjeno besedilno oznako stolpca.");

// 7. Ikona odpiranja vrstice mora biti nadzorovana CSS oblika, ne Unicode nadomestek.
Assert(Regex.IsMatch(markup, "<span class=\"chevron\" aria-hidden=\"true\"></span>"),
  "Ikona odpiranja vrstice mora biti nadzorovana CSS oblika z aria-hidden.");
Assert(!markup.Contains('\u203A'), "Unicode nadomestne ikone niso dovoljene; uporabi CSS obliko.");
Assert(Regex.IsMatch(markup, "<a class=\"open-link\"[^>]*aria-label=\"[^\"]+\""), "Povezava za odpiranje vrstice mora imeti aria-label.");

// 8. Tabela mora ostati berljiva in se na ozkih zaslonih vodoravno pomikati.
var scroll = Regex.Match(markup, "<div class=\"table-scroll\"[^>]*>");
Assert(scroll.Success, "Tabela mora biti v ovoju <div class=\"table-scroll\"> zaradi prelivanja.");
foreach (var attribute in new[] { "role=\"region\"", "tabindex=\"0\"", "aria-label=" })
  Assert(scroll.Value.Contains(attribute, StringComparison.Ordinal), "Pomični ovoj tabele nima " + attribute + ": " + scroll.Value);
Assert(Regex.IsMatch(markup, "<caption>"), "Tabela mora ohraniti napis <caption>.");
Assert(Regex.Matches(markup, "<th scope=\"col\">").Count == 8, "Tabela mora ohraniti natanko osem obstoječih stolpcev z scope=\"col\".");
Assert(Regex.IsMatch(css, "\\.table-scroll\\s*\\{[^}]*overflow-x:\\s*auto"), "Ovoj tabele mora imeti overflow-x: auto.");
Assert(Regex.IsMatch(css, "@media[^{]*max-width:\\s*900px"), "Manjka odzivno pravilo za ozke zaslone.");
Assert(Regex.IsMatch(css, "\\.data-table\\s*\\{[^}]*min-width:"), "Na ozkih zaslonih se tabela ne sme stiskati; potrebna je min-width.");

// 9. Paginacija mora ostati vidna in dostopna.
var pagination = Regex.Match(markup, "<nav class=\"pagination\"[^>]*>");
Assert(pagination.Success, "Paginacija mora ostati <nav class=\"pagination\">.");
Assert(Regex.IsMatch(pagination.Value, "aria-label=\"[^\"]+\""), "Paginacija mora imeti aria-label.");
Assert(Regex.Matches(markup, "<button type=\"button\"").Count == 6,
  "Štirje zavihki in obe strani morajo biti izrecni gumbi type=\"button\" brez oddajanja obrazca.");

// 10. Tipkovnični fokus mora biti viden na vseh interaktivnih elementih strani.
foreach (var selector in new[] { ".page-tab", ".search-input", ".filter-select", ".pagination button", ".table-scroll", ".data-table a", ".open-link" })
  Assert(css.Contains(selector + ":focus-visible", StringComparison.Ordinal), "Manjka slog fokusa za " + selector + ".");
Assert(Regex.IsMatch(css, ":focus-visible[^{]*\\{[^}]*outline:"), "Fokus mora risati obris, ne samo sence.");
Assert(!css.Contains("::deep", StringComparison.Ordinal), "Izoliran slog ne sme uhajati z ::deep.");

// 11. Varovalka: stran ostane vezana na obstoječi resnični poizvedbi.
var allowedCalls = new[] { "GetCurrentOrganizationAsync", "GetCustomersAsync" };
foreach (var call in allowedCalls)
  Assert(markup.Contains("Data." + call, StringComparison.Ordinal), "Stran mora ohraniti klic " + call + ".");
foreach (Match call in Regex.Matches(markup, "Data\\.(\\w+)"))
  Assert(allowedCalls.Contains(call.Groups[1].Value, StringComparer.Ordinal), "Nova podatkovna poizvedba ni v obsegu naloge: " + call.Value);
Assert(!markup.Contains("Async(2,", StringComparison.Ordinal), "Stran ne sme uporabljati hardkodirane organizacije 2.");

// 12. Varovalka: obstoječe ravnanje s filtri in paginacijo ostane nedotaknjeno.
foreach (var behavior in new[]
{
  "const int PageSize=25",
  "Skip(Page*PageSize).Take(PageSize)",
  "void SetKind(string value){Kind=value;Page=0;}",
  "void Previous()=>Page=Math.Max(0,Page-1);",
  "void Next()=>Page=Math.Min(PageCount-1,Page+1);",
  "(Kind==\"\"||x.CustomerKind==Kind)&&(Type==\"\"||x.CustomerType==Type)",
  "x.CustomerKey.Contains(Search,StringComparison.OrdinalIgnoreCase)",
  "x.Name.Contains(Search,StringComparison.OrdinalIgnoreCase)",
  "Rows=await Data.GetCustomersAsync(org.OrganizationId);",
  "Error=\"Aktivna organizacija ni na voljo.\"",
  "Error=\"Strank trenutno ni mogoče naložiti.\"",
  "\"CUSTOMER\"=>\"Kupec\"",
  "\"SUPPLIER\"=>\"Dobavitelj\"",
  "\"BOTH\"=>\"Kupec in dobavitelj\"",
})
  Assert(markup.Contains(behavior, StringComparison.Ordinal), "Obstoječe ravnanje strani je spremenjeno; manjka: " + behavior);
var allowedHandlers = new[] { "SetKind", "Previous", "Next" };
foreach (Match handler in Regex.Matches(markup, "@onclick=['\"](?:\\(\\)=>)?(\\w+)"))
  Assert(allowedHandlers.Contains(handler.Groups[1].Value, StringComparer.Ordinal), "Novo dejanje ni v obsegu naloge: " + handler.Value);
Assert(Regex.Matches(markup, "@onclick=").Count == 6, "Število dejanj na strani se ne sme spremeniti.");

// 13. Varovalka: gre za predstavitveni sklop brez akcij pisanja in brez nepodprtih kontrol.
foreach (var forbidden in new[] { "<form", "@onsubmit", "method=\"post\"", "<img", "type=\"checkbox\"", "type=\"file\"", "<dialog", "contenteditable", "Save", "Delete" })
  Assert(!markup.Contains(forbidden, StringComparison.OrdinalIgnoreCase), "Predstavitveni sklop ne sme uvesti " + forbidden + ".");

// 14. Varovalka: povezave ostanejo base-relativne, da delujejo tudi pod virtualno potjo /PIM.
foreach (Match link in Regex.Matches(markup, "href=\"([^\"]*)\""))
  Assert(!link.Groups[1].Value.StartsWith('/'), "Povezava mora ostati base-relativna: " + link.Value);

// 15. Varovalka: nobenega novega stolpca ali izmišljene vsebine brez podatkovnega vira.
// Vse našteto je vidno na referenčni sliki, a nima read modela.
// Ujemanje je po celi besedi, da dostopnostne oznake (npr. »Filtriranje strank«,
// »Pogledi strank«) ne štejejo za referenčne kontrole »Filtri« oziroma »Pogled«.
foreach (var fabricated in new[]
{
  "Plačnik", "Cenik", "Posodobljeno", "Akcije", "Status", "Aktiven", "Neaktiven", "Neaktivni",
  "Nova stranka", "Filtri", "Stolpci", "Izvozi", "Uvozi", "Počisti vse", "Vrstic na stran",
  "Izbranih", "Davčna", "Pogled", "PAK2", "Vrednostni rabat", "Brez tipa",
})
  Assert(!Regex.IsMatch(markup, "\\b" + Regex.Escape(fabricated) + "\\b"),
    "Stran ne sme prikazovati izmišljene vsebine: " + fabricated + ".");

Console.WriteLine("F10 customers UX contract PASS.");

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
