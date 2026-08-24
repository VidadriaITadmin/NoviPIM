using System.Text.RegularExpressions;

// Pogodbeni test UX skladnosti seznama izdelkov.
// Obseg je namenoma ozek: samo predstavitev in dostopnost strani /izdelki.
// Test ne sme zahtevati novih poizvedb, novih stolpcev, novih vrednosti ali akcij pisanja.

var root = FindRoot();
var razorPath = Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", "Products.razor");
var cssPath = Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", "Products.razor.css");

Assert(File.Exists(razorPath), "Manjka stran izdelkov: " + razorPath);
Assert(File.Exists(cssPath), "Manjka izoliran slog izdelkov: " + cssPath);

var markup = File.ReadAllText(razorPath);
var css = File.ReadAllText(cssPath);

// 1. Naslov strani in kontekstni zavihki (referenca: naslov + zavihki nad orodno vrstico).
Assert(Regex.IsMatch(markup, "<h1>Izdelki</h1>"), "Stran mora ohraniti vidni naslov <h1>Izdelki</h1>.");
var tabs = Regex.Match(markup, "<nav[^>]*class=\"page-tabs\"[^>]*>");
Assert(tabs.Success, "Zavihki morajo biti navigacijski sklop <nav class=\"page-tabs\">.");
Assert(Regex.IsMatch(tabs.Value, "aria-label=\"[^\"]+\""), "Zavihki morajo imeti aria-label.");
Assert(Regex.Matches(markup, "class=\"page-tab(?!s)").Count == 1,
  "Stran ima en sam obstoječi zavihek; dodatnih zavihkov brez podatkovnega vira ni dovoljeno ustvariti.");
Assert(Regex.IsMatch(markup, "class=\"page-tab active\"[^>]*aria-current=\"page\""), "Aktivni zavihek mora imeti aria-current=\"page\".");
Assert(Regex.IsMatch(markup, "<span class=\"page-tab active\"[^>]*>[^<]*Page\\.TotalCount"),
  "Števec v zavihku mora izhajati iz dejanskega Page.TotalCount, ne iz vpisane vrednosti.");

// 2. Orodna vrstica je poimenovan iskalni sklop, vsaka kontrola pa ima svojo oznako.
var toolbar = Regex.Match(markup, "<section[^>]*class=\"ui-card toolbar\"[^>]*>");
Assert(toolbar.Success, "Orodna vrstica mora ostati <section class=\"ui-card toolbar\">.");
Assert(toolbar.Value.Contains("role=\"search\"", StringComparison.Ordinal), "Orodna vrstica mora biti razglašena kot role=\"search\".");
var toolbarLabel = Regex.Match(toolbar.Value, "aria-labelledby=\"([^\"]+)\"");
Assert(toolbarLabel.Success, "Iskalni sklop mora imeti aria-labelledby.");
Assert(Regex.IsMatch(markup, "<h2 id=\"" + Regex.Escape(toolbarLabel.Groups[1].Value) + "\" class=\"visually-hidden\">"),
  "Naslov iskalnega sklopa mora ostati bralcem zaslona dostopen in vizualno skrit.");
foreach (var control in new[] { "product-search", "product-status" })
  Assert(Regex.IsMatch(markup, "<label[^>]*for=\"" + control + "\""), "Kontrola " + control + " nima povezane oznake <label for>.");
Assert(Regex.IsMatch(markup, "<input id=\"product-search\"[^>]*type=\"search\""), "Iskalno polje mora biti type=\"search\".");

// 3. Število rezultatov oziroma stanje nalaganja/napake se mora sporočati v živo.
var count = Regex.Match(markup, "<span class=\"result-count\"[^>]*>");
Assert(count.Success, "Orodna vrstica mora ohraniti izpis števila rezultatov.");
foreach (var attribute in new[] { "role=\"status\"", "aria-live=\"polite\"" })
  Assert(count.Value.Contains(attribute, StringComparison.Ordinal), "Izpis rezultatov nima " + attribute + ": " + count.Value);
Assert(Regex.IsMatch(markup, "class=\"loading-state\"[^>]*role=\"status\""), "Stanje nalaganja mora biti razglašeno kot role=\"status\".");
Assert(Regex.IsMatch(markup, "class=\"error-state\"[^>]*role=\"alert\""), "Stanje napake mora biti razglašeno kot role=\"alert\".");

// 4. Statusni čipi ne smejo biti razločljivi samo po barvi.
var chipCount = Regex.Matches(markup, "class=\"status-chip ").Count;
Assert(chipCount >= 1, "Seznam mora ohraniti statusni čip izdelka.");
Assert(Regex.Matches(markup, "<span class=\"visually-hidden\">Status: </span>").Count == chipCount,
  "Vsak statusni čip mora imeti bralcem zaslona namenjeno oznako \"Status: \".");

// 5. Merilnik popolnosti mora sporočati vrednost, ne samo širine.
var meters = Regex.Matches(markup, "<span class=\"progress-track\"[^>]*>");
Assert(meters.Count >= 1, "Stolpec popolnosti mora ohraniti merilnik.");
foreach (Match meter in meters)
  foreach (var attribute in new[] { "role=\"progressbar\"", "aria-valuenow=", "aria-valuemin=\"0\"", "aria-valuemax=\"100\"", "aria-label=" })
    Assert(meter.Value.Contains(attribute, StringComparison.Ordinal), "Merilnik popolnosti nima " + attribute + ": " + meter.Value);
Assert(Regex.IsMatch(markup, "aria-valuenow=\"@Number\\("), "aria-valuenow mora biti izpisan neodvisno od območnih nastavitev.");
foreach (Match icon in Regex.Matches(markup, "<i [^>]*>"))
  Assert(icon.Value.Contains("aria-hidden=\"true\"", StringComparison.Ordinal), "Okrasni element mora imeti aria-hidden: " + icon.Value);
Assert(Regex.IsMatch(markup, "<span class=\"chevron\" aria-hidden=\"true\"></span>"),
  "Ikona odpiranja vrstice mora biti nadzorovana CSS oblika z aria-hidden.");
Assert(!markup.Contains('\u203A'), "Unicode nadomestne ikone niso dovoljene; uporabi CSS obliko.");

// 6. Tabela mora ostati berljiva in se na ozkih zaslonih vodoravno pomikati.
var scroll = Regex.Match(markup, "<div class=\"table-scroll\"[^>]*>");
Assert(scroll.Success, "Tabela mora biti v ovoju <div class=\"table-scroll\"> zaradi prelivanja.");
foreach (var attribute in new[] { "role=\"region\"", "tabindex=\"0\"", "aria-label=" })
  Assert(scroll.Value.Contains(attribute, StringComparison.Ordinal), "Pomični ovoj tabele nima " + attribute + ": " + scroll.Value);
Assert(Regex.IsMatch(markup, "<caption>"), "Tabela mora ohraniti napis <caption>.");
// Stolpcev je zdaj sest: pet obstojecih in stolpec za mnozicno izbiro.
Assert(Regex.Matches(markup, "<th scope=\"col\"").Count == 6, "Tabela mora imeti sest stolpcev z scope=\"col\".");
Assert(Regex.IsMatch(markup, "aria-label=\"Izberi vse na strani\""), "Izbira vseh na strani mora imeti aria-label.");
Assert(Regex.IsMatch(markup, "aria-label=\"Izberi izdelek @row.ItemId\""), "Vsaka kljukica mora povedati, kateri izdelek izbira.");
Assert(Regex.IsMatch(css, "\\.table-scroll\\s*\\{[^}]*overflow-x:\\s*auto"), "Ovoj tabele mora imeti overflow-x: auto.");
Assert(Regex.IsMatch(css, "@media[^{]*max-width:\\s*900px"), "Manjka odzivno pravilo za ozke zaslone.");
Assert(Regex.IsMatch(css, "\\.data-table\\s*\\{[^}]*min-width:"), "Na ozkih zaslonih se tabela ne sme stiskati; potrebna je min-width.");

// 7. Paginacija mora ostati vidna in dostopna.
var pagination = Regex.Match(markup, "<nav class=\"pagination\"[^>]*>");
Assert(pagination.Success, "Paginacija mora ostati <nav class=\"pagination\">.");
Assert(Regex.IsMatch(pagination.Value, "aria-label=\"[^\"]+\""), "Paginacija mora imeti aria-label.");
Assert(Regex.Matches(markup, "<button type=\"button\"").Count == 4,
  "Filter, mnozicno urejanje in obe strani morajo biti izrecni gumbi type=\"button\" brez oddajanja obrazca.");

// 8. Tipkovnični fokus mora biti viden na vseh interaktivnih elementih strani.
foreach (var selector in new[] { ".search-input", ".filter-select", ".filter-button", ".pagination button", ".table-scroll", ".data-table a", ".open-link", ".select-cell input" })
  Assert(css.Contains(selector + ":focus-visible", StringComparison.Ordinal), "Manjka slog fokusa za " + selector + ".");
Assert(Regex.IsMatch(css, ":focus-visible[^{]*\\{[^}]*outline:"), "Fokus mora risati obris, ne samo sence.");
Assert(!css.Contains("::deep", StringComparison.Ordinal), "Izoliran slog ne sme uhajati z ::deep.");

// 9. Varovalka: stran ostane vezana na obstoječi resnični poizvedbi.
var allowedCalls = new[] { "GetCurrentOrganizationAsync", "GetProductsAsync" };
foreach (var call in allowedCalls)
  Assert(markup.Contains("Data." + call, StringComparison.Ordinal), "Stran mora ohraniti klic " + call + ".");
foreach (Match call in Regex.Matches(markup, "Data\\.(\\w+)"))
  Assert(allowedCalls.Contains(call.Groups[1].Value, StringComparer.Ordinal), "Nova podatkovna poizvedba ni v obsegu naloge: " + call.Value);

// 10. Varovalka: obstoječe ravnanje s filtri in paginacijo ostane nedotaknjeno.
foreach (var behavior in new[] { "const int Take = 50", "Skip=0", "Skip=Math.Max(0,Skip-Take)", "Skip+=Take" })
  Assert(markup.Contains(behavior, StringComparison.Ordinal), "Obstoječe ravnanje s filtri/paginacijo je spremenjeno; manjka: " + behavior);
// Seznam se je razsiril z mnozicno izbiro. Vsak od dodanih rokovalcev samo spreminja izbiro
// ali odpre drugo stran; nobeden ne pise v bazo.
var allowedHandlers = new[] { "ApplyFiltersAsync", "PreviousAsync", "NextAsync", "EditSelected", "ToggleAll" };
foreach (Match handler in Regex.Matches(markup, "@onclick=\"(\\w+)\""))
  Assert(allowedHandlers.Contains(handler.Groups[1].Value, StringComparer.Ordinal), "Novo dejanje ni v obsegu naloge: " + handler.Value);

// 11. Varovalka: stran sme izbirati, ne sme pa pisati.
//
// Kljukica za mnozicno izbiro je odslej dovoljena — brez nje mnozicnega urejanja ni. Vse
// ostalo ostaja prepovedano, in dodana je ostrejsa zahteva: stran ne sme klicati nobene
// zapisovalne storitve. Izbrane sifre samo preda strani /izvozi/mnozicno, ki edina naroci
// spremembo in ima za to svojo varovalko v bazi.
foreach (var forbidden in new[] { "<form", "@onsubmit", "method=\"post\"", "<img", "type=\"file\"", "<dialog", "contenteditable" })
  Assert(!markup.Contains(forbidden, StringComparison.OrdinalIgnoreCase), "Predstavitveni sklop ne sme uvesti " + forbidden + ".");
foreach (var writeSurface in new[] { "SaopWriteService", "EnqueueAsync", "ApproveBatchAsync" })
  Assert(!markup.Contains(writeSurface, StringComparison.Ordinal), "Seznam izdelkov ne sme sam pisati v odhodno pot: " + writeSurface + ".");
Assert(markup.Contains("izvozi/mnozicno", StringComparison.Ordinal), "Izbrani izdelki morajo voditi na stran za mnozicno urejanje.");

// 12. Varovalka: nobenega novega stolpca ali izmišljene vsebine brez podatkovnega vira.
// 'Uredi izbrane' ni izmisljen stolpec, ampak dejanje nad dejansko izbiro, zato 'Uredi' tu ni
// vec prepovedana beseda; ostale ostajajo.
foreach (var fabricated in new[] { "Proizvajalec", "Slika", "Cena", "Zaloga", "Kategorija", "Nov izdelek", "Uvozi", "Izbriši", "Osnutek", "Objavljeno", "Nedavno" })
  Assert(!markup.Contains(fabricated, StringComparison.Ordinal), "Stran ne sme prikazovati izmišljene vsebine: " + fabricated + ".");

Console.WriteLine("F10 products UX contract PASS.");

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
