using System.Text.RegularExpressions;

// Pogodbeni test UX skladnosti pregleda zaloge (/zaloge).
//
// Prejsnja razlicica je zamrznila ozek obseg: stiri KPI kartice iz Rows.Count, en zavihek,
// sest stolpcev in odjemalsko filtriranje. Ta obseg je bil odvisen od tega, da stran nalozi
// vse pozicije naenkrat — stock.Position ima 379.610 vrstic, zato je bila to okvara, ne izbira.
// Stran zdaj bere intranet.GetStockPositions in intranet.GetStockOverview (migracija 103).
//
// Kar pogodba varuje, ostaja isto in je zaostreno: dostopnost, resnicen podatkovni vir,
// odsotnost zapisovalnih dejanj (zaloga se v ERP nikoli ne pise) in odsotnost izmisljene vsebine.

var root = FindRoot();
var razorPath = Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", "Stocks.razor");
var cssPath = Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", "Stocks.razor.css");

Assert(File.Exists(razorPath), "Manjka stran zaloge: " + razorPath);
Assert(File.Exists(cssPath), "Manjka izoliran slog zaloge: " + cssPath);

var markup = File.ReadAllText(razorPath);
var css = File.ReadAllText(cssPath);

// 1. Glava strani in izrecna meja sistema.
Assert(markup.Contains("@attribute [Authorize]", StringComparison.Ordinal), "Stran zaloge mora ostati zascitena z [Authorize].");
Assert(Regex.IsMatch(markup, "<PimPage Title=\"Zaloga\""), "Stran mora uporabiti skupno glavo PimPage z naslovom Zaloga.");
Assert(markup.Contains("nikoli ne piše nazaj v ERP", StringComparison.Ordinal),
  "Stran mora povedati, da je zaloga samo bralna; to je meja sistema, ne pomanjkljivost.");

// 2. KPI kartice izhajajo iz agregata v bazi in vodijo na svoj filtriran seznam.
var kpiGrid = Regex.Match(markup, "<section class=\"kpi-grid\"[^>]*>");
Assert(kpiGrid.Success, "KPI kartice morajo biti v poimenovanem sklopu <section class=\"kpi-grid\">.");
var kpiLabel = Regex.Match(kpiGrid.Value, "aria-labelledby=\"([^\"]+)\"");
Assert(kpiLabel.Success, "Sklop KPI kartic mora imeti aria-labelledby.");
Assert(Regex.IsMatch(markup, "<h2 id=\"" + Regex.Escape(kpiLabel.Groups[1].Value) + "\" class=\"visually-hidden\">"),
  "Naslov KPI sklopa mora ostati bralcem zaslona dostopen in vizualno skrit.");
Assert(Regex.Matches(markup, "<PimStat ").Count == 5, "Povzetek ima pet kartic: skupaj, na zalogi, brez zaloge, prihaja in brez artikla.");
foreach (var target in new[] { "zaloge?razpolozljivost=IN_STOCK", "zaloge?razpolozljivost=OUT_OF_STOCK", "zaloge?razpolozljivost=INCOMING", "zaloge?ujemanje=UNMATCHED" })
  Assert(markup.Contains(target, StringComparison.Ordinal), "Stevilka mora voditi na filtriran seznam, ki jo pojasni: " + target);
Assert(markup.Contains("Overview?.Totals", StringComparison.Ordinal), "KPI vrednost mora izhajati iz agregata v bazi, ne iz preSteVanja vrstic v pomnilniku.");

// 3. Orodna vrstica je poimenovan iskalni sklop, vsaka kontrola pa ima svojo oznako.
var toolbar = Regex.Match(markup, "<section class=\"ui-card toolbar\"[^>]*>");
Assert(toolbar.Success, "Orodna vrstica mora ostati <section class=\"ui-card toolbar\">.");
Assert(toolbar.Value.Contains("role=\"search\"", StringComparison.Ordinal), "Orodna vrstica mora biti razglasena kot role=\"search\".");
var toolbarLabel = Regex.Match(toolbar.Value, "aria-labelledby=\"([^\"]+)\"");
Assert(toolbarLabel.Success, "Iskalni sklop mora imeti aria-labelledby.");
Assert(Regex.IsMatch(markup, "<h2 id=\"" + Regex.Escape(toolbarLabel.Groups[1].Value) + "\" class=\"visually-hidden\">"),
  "Naslov iskalnega sklopa mora ostati bralcem zaslona dostopen in vizualno skrit.");
foreach (var control in new[] { "stock-search", "stock-source", "stock-availability", "stock-matched", "stock-age" })
{
  Assert(Regex.IsMatch(markup, "<label[^>]*for=\"" + control + "\""), "Kontrola " + control + " nima povezane oznake <label for>.");
  Assert(Regex.IsMatch(markup, "id=\"" + control + "\""), "Kontrola " + control + " ne obstaja.");
}
Assert(Regex.IsMatch(markup, "<input id=\"stock-search\"[^>]*type=\"search\""), "Iskalno polje mora biti type=\"search\".");
Assert(markup.Contains("Overview.Sources.Select(source => source.SourceCode)", StringComparison.Ordinal),
  "Seznam virov mora izhajati iz dejanskih posnetkov, ne iz vpisanega seznama.");

// 4. Ziva stanja in zivo sporocilo o rezultatu.
var count = Regex.Match(markup, "<span class=\"result-count\"[^>]*>");
Assert(count.Success, "Orodna vrstica mora ohraniti izpis stevila rezultatov.");
foreach (var attribute in new[] { "role=\"status\"", "aria-live=\"polite\"" })
  Assert(count.Value.Contains(attribute, StringComparison.Ordinal), "Izpis rezultatov nima " + attribute + ": " + count.Value);
Assert(Regex.Matches(markup, "<PimState ").Count == 3, "Vsaka od treh tabel mora imeti svoje stanje nalaganja, napake in praznega nabora.");
foreach (var parameter in new[] { "Loading=", "Error=", "Empty=", "EmptyText=", "LoadingText=" })
  Assert(markup.Contains(parameter, StringComparison.Ordinal), "PimState mora dobiti " + parameter + ".");

// 5. Stanje in svezina nista razlocljiva samo po barvi.
Assert(Regex.IsMatch(markup, "<PimChip Text=\"@\\(row\\.Quantity > 0 \\? \"Na zalogi\" : \"Brez zaloge\"\\)\""),
  "Stanje pozicije mora biti izpisano z besedo.");
Assert(markup.Contains("Prefix=\"Svežina: \"", StringComparison.Ordinal), "Svezina vira mora imeti govorno predpono.");
Assert(markup.Contains("FreshnessLabel(", StringComparison.Ordinal), "Starost posnetka mora biti izpisana z besedo, ne le z barvo.");

// 6. Stranicenje je streznisko in izhaja iz istega stetja kot seznam.
Assert(Regex.IsMatch(markup, "<PimPager Skip=\"Skip\" Take=\"Take\" Total=\"PageData\\.TotalCount\""),
  "Seznam mora biti strezniski; 379.610 pozicij se ne nalaga v pomnilnik.");
foreach (var parameter in new[] { "isci", "vir", "razpolozljivost", "ujemanje", "starost", "stran" })
  Assert(Regex.IsMatch(markup, "SupplyParameterFromQuery\\(Name = \"" + parameter + "\"\\)"),
    "Filter " + parameter + " mora ziveti v naslovu URL.");
Assert(!markup.Contains("Rows?.Where(", StringComparison.Ordinal), "Odjemalskega filtriranja ne sme biti vec.");

// 7. Tabele so skupni gradnik z napisom in oznako.
Assert(Regex.Matches(markup, "<PimTable Caption=\"").Count == 3, "Stran ima tri tabele: pozicije, viri in izpeljane tezave.");
foreach (Match table in Regex.Matches(markup, "<PimTable [^>]*>"))
  Assert(table.Value.Contains("AriaLabel=", StringComparison.Ordinal), "Tabela nima aria-label: " + table.Value);
Assert(!markup.Contains("<table class=\"data-table\">", StringComparison.Ordinal), "Tabele se ne pisejo znova; uporabi PimTable.");
Assert(Regex.Matches(markup, "class=\"numeric\"").Count >= 4, "Kolicinski stolpci morajo biti poravnani desno.");

// 8. Slog: fokus, prelivanje, odzivnost; brez uhajanja z ::deep.
foreach (var selector in new[] { ".search-input", ".filter-select", ".filter-button", ".filter-chip", ".table-scroll", ".data-table a" })
  Assert(css.Contains(selector + ":focus-visible", StringComparison.Ordinal), "Manjka slog fokusa za " + selector + ".");
Assert(Regex.IsMatch(css, ":focus-visible[^{]*\\{[^}]*outline:"), "Fokus mora risati obris, ne samo sence.");
Assert(!css.Contains("::deep", StringComparison.Ordinal), "Izoliran slog ne sme uhajati z ::deep.");
Assert(Regex.IsMatch(css, "\\.table-scroll\\s*\\{[^}]*overflow-x:\\s*auto"), "Ovoj tabele mora imeti overflow-x: auto.");
Assert(Regex.IsMatch(css, "\\.data-table\\s*\\{[^}]*min-width:"), "Na ozkih zaslonih se tabela ne sme stiskati; potrebna je min-width.");
Assert(Regex.IsMatch(css, "@media[^{]*max-width:\\s*900px"), "Manjka odzivno pravilo za ozke zaslone.");

// 9. Varovalka: stran ostane vezana na dejanski bralni proceduri in nicesar ne pise.
Assert(markup.Contains("Data.GetCurrentOrganizationAsync", StringComparison.Ordinal), "Stran mora prevzeti aktivno organizacijo.");
foreach (var call in new[] { "Stock.GetPositionsAsync", "Stock.GetOverviewAsync" })
  Assert(markup.Contains(call, StringComparison.Ordinal), "Stran mora ohraniti klic " + call + ".");
foreach (Match call in Regex.Matches(markup, "(?<![A-Za-z0-9_])(?:Data|Stock)\\.(\\w+)"))
  Assert(new[] { "GetCurrentOrganizationAsync", "GetPositionsAsync", "GetOverviewAsync" }.Contains(call.Groups[1].Value, StringComparer.Ordinal),
    "Nova podatkovna poizvedba ni v obsegu naloge: " + call.Value);
Assert(markup.Contains("intranet.GetStockPositions", StringComparison.Ordinal), "Stran mora povedati, iz katerega vira bere.");
var allowedHandlers = new[] { "ApplyFiltersAsync" };
foreach (Match handler in Regex.Matches(markup, "@onclick=\"(\\w+)\""))
  Assert(allowedHandlers.Contains(handler.Groups[1].Value, StringComparer.Ordinal), "Novo dejanje ni v obsegu naloge: " + handler.Value);

// 10. Varovalka: predstavitveni sklop brez zapisovalne povrsine.
foreach (var forbidden in new[] { "<form", "@onsubmit", "method=\"post\"", "<img", "type=\"checkbox\"", "type=\"file\"", "<dialog", "contenteditable" })
  Assert(!markup.Contains(forbidden, StringComparison.OrdinalIgnoreCase), "Predstavitveni sklop ne sme uvesti " + forbidden + ".");
foreach (var writeSurface in new[] { "SaopWriteService", "EnqueueAsync", "ApproveBatchAsync", "MarkResolved", "Označi kot rešeno" })
  Assert(!markup.Contains(writeSurface, StringComparison.Ordinal), "Zaloga se ne pise nazaj: " + writeSurface + ".");
Assert(!markup.Contains('\u203A'), "Unicode nadomestne ikone niso dovoljene; uporabi CSS obliko.");

// 11. Varovalka: nobene vsebine brez podatkovnega vira.
// Skladisce, dobavni rok in min/max so od migracije 103 resnicni stolpci, zato niso vec na
// seznamu. Rezervacije, trendi in izvozi ostanejo prepovedani, ker vira zanje ni.
foreach (var fabricated in new[] { "Rezervirano", "Fizična zaloga", "Nizek nivo", "Trend", "ta teden",
  "Osveži", "Stolpci", "Izvozi", "Uvozi", "Vrstic na stran", "Izbranih" })
  Assert(!markup.Contains(fabricated, StringComparison.Ordinal), "Stran ne sme prikazovati izmisljene vsebine: " + fabricated + ".");
foreach (var literal in new[] { "9.842", "9842", "426", "3,7", "86%" })
  Assert(!markup.Contains(literal, StringComparison.Ordinal), "Stevilke iz UX slike se ne prepisujejo v kodo: " + literal + ".");

Console.WriteLine("F10 stocks UX contract PASS.");

static void Assert(bool condition, string message)
{
  if (!condition) throw new InvalidOperationException(message);
}

// Koren se poisce iz delovne mape in iz mape sestave, da je test neodvisen od nacina zagona.
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
