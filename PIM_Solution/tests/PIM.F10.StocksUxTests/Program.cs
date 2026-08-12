using System.Text.RegularExpressions;

// Pogodbeni test UX skladnosti pregleda zaloge.
// Obseg je namenoma ozek: samo predstavitev in dostopnost strani /zaloge.
// Referenca `../PIM_test/UX_pictures/zaloga.png` prikazuje skladišča, rezervacije, izvoze in
// dodatne zavihke, ki jih `StockRow` ne pokriva; test zato izrecno prepove njihovo izmišljanje.
// Test ne sme zahtevati novih poizvedb, novih stolpcev, novih vrednosti ali akcij pisanja.

var root = FindRoot();
var razorPath = Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", "Stocks.razor");
var cssPath = Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", "Stocks.razor.css");

Assert(File.Exists(razorPath), "Manjka stran zaloge: " + razorPath);
Assert(File.Exists(cssPath), "Manjka izoliran slog zaloge: " + cssPath);

var markup = File.ReadAllText(razorPath);
var css = File.ReadAllText(cssPath);

// 1. Naslov strani in kontekstni zavihki (referenca: naslov + zavihki nad KPI karticami).
Assert(Regex.IsMatch(markup, "<h1>Zaloga</h1>"), "Stran mora ohraniti vidni naslov <h1>Zaloga</h1>.");
var tabs = Regex.Match(markup, "<nav[^>]*class=\"page-tabs\"[^>]*>");
Assert(tabs.Success, "Zavihki morajo biti navigacijski sklop <nav class=\"page-tabs\">.");
Assert(Regex.IsMatch(tabs.Value, "aria-label=\"[^\"]+\""), "Zavihki morajo imeti aria-label.");
Assert(Regex.Matches(markup, "class=\"page-tab(?!s)").Count == 1,
  "Stran ima en sam podatkovno podprt zavihek; »Dobavni roki« in »Težave« iz reference nimata vira.");
Assert(Regex.IsMatch(markup, "class=\"page-tab active\"[^>]*aria-current=\"page\""), "Aktivni zavihek mora imeti aria-current=\"page\".");

// 2. KPI kartice morajo biti poimenovan sklop, vsaka vrednost pa izpeljana iz dejanskih vrstic.
var kpiGrid = Regex.Match(markup, "<section[^>]*class=\"kpi-grid\"[^>]*>");
Assert(kpiGrid.Success, "KPI kartice morajo biti v poimenovanem sklopu <section class=\"kpi-grid\">.");
Assert(Regex.IsMatch(kpiGrid.Value, "aria-label=\"[^\"]+\""), "Sklop KPI kartic mora imeti aria-label.");
var kpiCards = Regex.Matches(markup, "class=\"ui-card kpi\"");
Assert(kpiCards.Count == 4, "Stran mora ohraniti natanko štiri obstoječe KPI kartice, ne " + kpiCards.Count + ".");
Assert(Regex.Matches(markup, "Rows\\.Count\\(").Count >= 4,
  "Vsaka KPI vrednost mora izhajati iz dejanskega števila vrstic, ne iz vpisane vrednosti.");
// Delež je izpeljan iz istih vrstic; imenovalec mora biti resničen, ne privzeta konstanta.
Assert(Regex.Matches(markup, "@Share\\(").Count == 4, "Vsaka KPI kartica mora izpisati delež, izpeljan iz Rows.Count.");
Assert(Regex.IsMatch(markup, "string Share\\(int [^)]*\\)[^;]*Rows\\.Count"),
  "Delež se mora računati iz dejanskega števila vrstic.");
Assert(Regex.IsMatch(markup, "Rows(\\.Count)? == 0|Rows.Count==0"), "Delež mora varno obravnavati prazen nabor.");

// 3. Orodna vrstica je poimenovan iskalni sklop, vsaka kontrola pa ima svojo oznako.
var toolbar = Regex.Match(markup, "<section[^>]*class=\"ui-card toolbar\"[^>]*>");
Assert(toolbar.Success, "Orodna vrstica mora ostati <section class=\"ui-card toolbar\">.");
Assert(toolbar.Value.Contains("role=\"search\"", StringComparison.Ordinal), "Orodna vrstica mora biti razglašena kot role=\"search\".");
var toolbarLabel = Regex.Match(toolbar.Value, "aria-labelledby=\"([^\"]+)\"");
Assert(toolbarLabel.Success, "Iskalni sklop mora imeti aria-labelledby.");
Assert(Regex.IsMatch(markup, "<h2 id=\"" + Regex.Escape(toolbarLabel.Groups[1].Value) + "\" class=\"visually-hidden\">"),
  "Naslov iskalnega sklopa mora ostati bralcem zaslona dostopen in vizualno skrit.");
foreach (var control in new[] { "stock-search", "stock-availability" })
  Assert(Regex.IsMatch(markup, "<label[^>]*for=\"" + control + "\""), "Kontrola " + control + " nima povezane oznake <label for>.");
Assert(Regex.IsMatch(markup, "<input id=\"stock-search\"[^>]*type=\"search\""), "Iskalno polje mora biti type=\"search\".");

// 4. Število rezultatov oziroma stanje nalaganja/napake se mora sporočati v živo.
var count = Regex.Match(markup, "<span class=\"result-count\"[^>]*>");
Assert(count.Success, "Orodna vrstica mora ohraniti izpis števila rezultatov.");
foreach (var attribute in new[] { "role=\"status\"", "aria-live=\"polite\"" })
  Assert(count.Value.Contains(attribute, StringComparison.Ordinal), "Izpis rezultatov nima " + attribute + ": " + count.Value);
Assert(Regex.IsMatch(markup, "class=\"loading-state\"[^>]*role=\"status\""), "Stanje nalaganja mora biti razglašeno kot role=\"status\".");
Assert(Regex.IsMatch(markup, "class=\"error-state\"[^>]*role=\"alert\""), "Stanje napake mora biti razglašeno kot role=\"alert\".");

// 5. Statusni čipi ne smejo biti razločljivi samo po barvi.
var chipCount = Regex.Matches(markup, "class=\"status-chip ").Count;
Assert(chipCount >= 1, "Seznam mora ohraniti statusni čip zaloge.");
Assert(Regex.Matches(markup, "<span class=\"visually-hidden\">Status: </span>").Count == chipCount,
  "Vsak statusni čip mora imeti bralcem zaslona namenjeno oznako \"Status: \".");

// 6. Zastarelost je že izračunana za KPI; v vrstici mora biti besedilna, ne zgolj barvna.
Assert(Regex.IsMatch(markup, "<span class=\"stale-flag\">[^<]+</span>"), "Zastarel zapis mora imeti besedilno oznako <span class=\"stale-flag\">.");
Assert(Regex.IsMatch(markup, "@if\\s*\\(IsStale\\(row\\)\\)"), "Oznaka zastarelosti mora izhajati iz obstoječega predikata IsStale.");

// 7. Tabela mora ostati berljiva in se na ozkih zaslonih vodoravno pomikati.
var scroll = Regex.Match(markup, "<div class=\"table-scroll\"[^>]*>");
Assert(scroll.Success, "Tabela mora biti v ovoju <div class=\"table-scroll\"> zaradi prelivanja.");
foreach (var attribute in new[] { "role=\"region\"", "tabindex=\"0\"", "aria-label=" })
  Assert(scroll.Value.Contains(attribute, StringComparison.Ordinal), "Pomični ovoj tabele nima " + attribute + ": " + scroll.Value);
Assert(Regex.IsMatch(markup, "<caption>"), "Tabela mora ohraniti napis <caption>.");
Assert(Regex.Matches(markup, "<th scope=\"col\"").Count == 6, "Tabela mora ohraniti natanko šest obstoječih stolpcev z scope=\"col\".");
Assert(Regex.Matches(markup, "class=\"numeric\"").Count >= 4,
  "Količinska stolpca morata biti poravnana desno v glavi in v celicah.");
Assert(Regex.IsMatch(css, "\\.table-scroll\\s*\\{[^}]*overflow-x:\\s*auto"), "Ovoj tabele mora imeti overflow-x: auto.");
Assert(Regex.IsMatch(css, "\\.numeric\\s*\\{[^}]*text-align:\\s*right"), "Številski stolpci morajo biti poravnani desno.");
Assert(Regex.IsMatch(css, "\\.numeric\\s*\\{[^}]*font-variant-numeric:\\s*tabular-nums"), "Številski stolpci morajo uporabljati tabelarične številke.");
Assert(Regex.IsMatch(css, "@media[^{]*max-width:\\s*900px"), "Manjka odzivno pravilo za ozke zaslone.");
Assert(Regex.IsMatch(css, "\\.data-table\\s*\\{[^}]*min-width:"), "Na ozkih zaslonih se tabela ne sme stiskati; potrebna je min-width.");

// 8. Tipkovnični fokus mora biti viden na vseh interaktivnih elementih strani.
foreach (var selector in new[] { ".search-input", ".filter-select", ".table-scroll", ".data-table a" })
  Assert(css.Contains(selector + ":focus-visible", StringComparison.Ordinal), "Manjka slog fokusa za " + selector + ".");
Assert(Regex.IsMatch(css, ":focus-visible[^{]*\\{[^}]*outline:"), "Fokus mora risati obris, ne samo sence.");
Assert(!css.Contains("::deep", StringComparison.Ordinal), "Izoliran slog ne sme uhajati z ::deep.");

// 9. Varovalka: stran ostane vezana na obstoječi resnični poizvedbi.
var allowedCalls = new[] { "GetCurrentOrganizationAsync", "GetStocksAsync" };
foreach (var call in allowedCalls)
  Assert(markup.Contains("Data." + call, StringComparison.Ordinal), "Stran mora ohraniti klic " + call + ".");
foreach (Match call in Regex.Matches(markup, "Data\\.(\\w+)"))
  Assert(allowedCalls.Contains(call.Groups[1].Value, StringComparer.Ordinal), "Nova podatkovna poizvedba ni v obsegu naloge: " + call.Value);

// 10. Varovalka: obstoječe filtriranje ostane nedotaknjeno.
foreach (var behavior in new[] { "@bind=\"Search\"", "@bind:event=\"oninput\"", "@bind=\"Availability\"" })
  Assert(markup.Contains(behavior, StringComparison.Ordinal), "Obstoječe ravnanje s filtri je spremenjeno; manjka: " + behavior);
foreach (var option in new[] { "value=\"\"", "value=\"yes\"", "value=\"no\"" })
  Assert(markup.Contains("<option " + option, StringComparison.Ordinal), "Manjka obstoječa možnost filtra: " + option);
Assert(Regex.Matches(markup, "@onclick=").Count == 0, "Pregled zaloge nima podprtih dejanj; novih klikov ni dovoljeno uvesti.");

// 11. Varovalka: gre za predstavitveni sklop brez akcij pisanja in brez nepodprtih kontrol.
foreach (var forbidden in new[] { "<form", "@onsubmit", "method=\"post\"", "<img", "type=\"checkbox\"", "type=\"file\"", "<dialog", "contenteditable", "class=\"pagination\"" })
  Assert(!markup.Contains(forbidden, StringComparison.OrdinalIgnoreCase), "Predstavitveni sklop ne sme uvesti " + forbidden + ".");
Assert(!markup.Contains('\u203A'), "Unicode nadomestne ikone niso dovoljene; uporabi CSS obliko.");

// 12. Varovalka: referenčna slika ni podatkovna pogodba.
// Našteto so polja in dejanja z zaloga.png, ki jih StockRow oziroma GetStocks ne vračata.
foreach (var fabricated in new[] { "Skladišč", "Rezervirano", "Fizična zaloga", "Naziv", "Nizek nivo", "Dobavni roki",
  "Težave", "Opozorila", "Osveži", "Stolpci", "Izvozi", "Uvozi", "Počisti vse", "Vrstic na stran", "Izbranih",
  "Napake sinhronizacije", "Pogled:" })
  Assert(!markup.Contains(fabricated, StringComparison.Ordinal), "Stran ne sme prikazovati izmišljene vsebine: " + fabricated + ".");
foreach (var literal in new[] { "9.842", "9842", "426", "3,7", "1,0", "86%" })
  Assert(!markup.Contains(literal, StringComparison.Ordinal), "Številke iz UX slike se ne prepisujejo v kodo: " + literal + ".");

Console.WriteLine("F10 stocks UX contract PASS.");

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
