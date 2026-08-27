using System.Text.RegularExpressions;

// Pogodbeni test UX skladnosti delovnega seznama izdelkov (/izdelki).
//
// Prejsnja razlicica te pogodbe je zamrznila ozek obseg strani: en sam zavihek, sest stolpcev,
// samo Data.GetProductsAsync in prepoved besed "Proizvajalec", "Slika", "Kategorija". Obseg
// strani je bil nato z odlocitvijo uporabnika razsirjen na delovni seznam iz nacrta
// (docs/Sprecifikacije_starega_PIMa/Nacrt_Intranet_Aplikacija.md §4.3), zato je pogodba
// posodobljena skupaj s stranjo — ne zato, da bi test sel skozi, ampak ker se je spremenil
// dogovor, kaj stran je.
//
// Kar pogodba varuje, ostaja isto in je zaostreno: dostopnost, resnicen podatkovni vir,
// odsotnost navideznih zapisovalnih dejanj in odsotnost izmisljene vsebine.

var root = FindRoot();
var razorPath = Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", "Products.razor");
var cssPath = Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", "Products.razor.css");

Assert(File.Exists(razorPath), "Manjka stran izdelkov: " + razorPath);
Assert(File.Exists(cssPath), "Manjka izoliran slog izdelkov: " + cssPath);

var markup = File.ReadAllText(razorPath);
var css = File.ReadAllText(cssPath);

// 1. Glava strani in shranjeni delovni pogledi.
Assert(Regex.IsMatch(markup, "<PimPage Title=\"Izdelki\""), "Stran mora uporabiti skupno glavo PimPage z naslovom Izdelki.");
var tabs = Regex.Match(markup, "<nav class=\"page-tabs\"[^>]*>");
Assert(tabs.Success, "Shranjeni pogledi morajo biti navigacijski sklop <nav class=\"page-tabs\">.");
Assert(Regex.IsMatch(tabs.Value, "aria-label=\"[^\"]+\""), "Zavihki morajo imeti aria-label.");
Assert(Regex.IsMatch(markup, "aria-current=\"@\\(active \\? \"page\" : null\\)\""), "Aktivni pogled mora imeti aria-current=\"page\".");
Assert(markup.Contains("@ViewCount(view.Code)", StringComparison.Ordinal),
  "Stevec pogleda mora izhajati iz podatkov (intranet.GetProductListViews), ne iz vpisane vrednosti.");
foreach (var view in new[] { "ALL", "TO_FIX", "NO_IMAGE", "NO_WEB_TITLE", "NO_CATEGORY", "NO_EAN", "NOT_PUBLISHED", "WAITING_SAOP" })
  Assert(Regex.IsMatch(markup, "new\\(\"" + view + "\", "), "Manjka shranjeni pogled " + view + ".");
Assert(Regex.Matches(markup, "new\\(\"(ALL|TO_FIX|NO_IMAGE|NO_WEB_TITLE|NO_CATEGORY|NO_EAN|NOT_PUBLISHED|WAITING_SAOP)\", ").Count == 8,
  "Pogledov je natanko osem; vsak mora imeti svoj stevec v bralni proceduri.");

// 2. Orodna vrstica je poimenovan iskalni sklop, vsaka kontrola ima svojo oznako.
var toolbar = Regex.Match(markup, "<section class=\"ui-card toolbar\"[^>]*>");
Assert(toolbar.Success, "Orodna vrstica mora ostati <section class=\"ui-card toolbar\">.");
Assert(toolbar.Value.Contains("role=\"search\"", StringComparison.Ordinal), "Orodna vrstica mora biti razglasena kot role=\"search\".");
var toolbarLabel = Regex.Match(toolbar.Value, "aria-labelledby=\"([^\"]+)\"");
Assert(toolbarLabel.Success, "Iskalni sklop mora imeti aria-labelledby.");
Assert(Regex.IsMatch(markup, "<h2 id=\"" + Regex.Escape(toolbarLabel.Groups[1].Value) + "\" class=\"visually-hidden\">"),
  "Naslov iskalnega sklopa mora ostati bralcem zaslona dostopen in vizualno skrit.");
foreach (var control in new[] { "product-search", "product-organization", "product-manufacturer", "product-supplier",
  "product-group", "product-department", "product-erp", "product-web", "product-activity", "product-webpublish",
  "product-completeness", "product-sort" })
{
  Assert(Regex.IsMatch(markup, "<label[^>]*for=\"" + control + "\""), "Kontrola " + control + " nima povezane oznake <label for>.");
  Assert(Regex.IsMatch(markup, "id=\"" + control + "\""), "Kontrola " + control + " ne obstaja.");
}
Assert(Regex.IsMatch(markup, "<input id=\"product-search\"[^>]*type=\"search\""), "Iskalno polje mora biti type=\"search\".");

// 3. Vrednosti filtrov so dejanske vrednosti kataloga, ne trdo kodiran seznam.
foreach (var facet in new[] { "MANUFACTURER", "SUPPLIER", "ITEM_GROUP", "DEPARTMENT" })
  Assert(markup.Contains("row.FacetKind == \"" + facet + "\"", StringComparison.Ordinal),
    "Spustni seznam " + facet + " mora izhajati iz intranet.GetProductListFilters.");

// Uporabnik bere ime partnerja, filtriramo pa po sifri, ker sifra potuje nazaj v SAOP.
Assert(!Regex.IsMatch(markup, "<option value=\"@facet.FacetValue\">@facet.FacetValue"),
  "Spustni seznami morajo kazati ime (FacetLabel), ne sifre.");
Assert(Regex.Matches(markup, "<option value=\"@facet.FacetValue\">@facet.FacetLabel").Count == 4,
  "Vsi stirje spustni seznami morajo kazati ime in filtrirati po sifri.");
Assert(markup.Contains("row.ManufacturerLabel", StringComparison.Ordinal) && markup.Contains("row.SupplierLabel", StringComparison.Ordinal),
  "Tudi v vrstici mora biti ime partnerja, kadar je znano.");

// 3.1 Seznam ni vezan na eno podjetje: privzeto so vsa, izbira pa pride iz registra podjetij.
Assert(Regex.IsMatch(markup, "<option value=\"\">Vsa podjetja</option>"),
  "Privzeta izbira podjetja mora biti \u00bbVsa podjetja\u00ab; seznam ne sme tiho pokazati samo prvega podjetja.");
Assert(markup.Contains("GetOrganizationsAsync", StringComparison.Ordinal),
  "Spustni seznam podjetij mora izhajati iz dbo.OrganizationConfig (GetOrganizationsAsync), ne iz trdo kodiranega seznama.");
Assert(!markup.Contains("GetCurrentOrganizationAsync", StringComparison.Ordinal),
  "Seznam izdelkov ne sme brati samo privzetega podjetja; obseg dolocita filter in vsa podjetja.");
Assert(markup.Contains("row.OrganizationName", StringComparison.Ordinal),
  "Ker ista sifra artikla obstaja v vec podjetjih, mora vsaka vrstica povedati, cigava je.");

// 4. Stanje seznama in zivo sporocanje rezultata.
var count = Regex.Match(markup, "<span class=\"result-count\"[^>]*>");
Assert(count.Success, "Orodna vrstica mora ohraniti izpis stevila rezultatov.");
foreach (var attribute in new[] { "role=\"status\"", "aria-live=\"polite\"" })
  Assert(count.Value.Contains(attribute, StringComparison.Ordinal), "Izpis rezultatov nima " + attribute + ": " + count.Value);
var state = Regex.Match(markup, "<PimState[^>]*", RegexOptions.Singleline);
Assert(state.Success, "Nalaganje, napaka in prazen nabor morajo iti skozi skupni PimState.");
foreach (var parameter in new[] { "Loading=", "Error=", "Empty=", "EmptyText=", "LoadingText=" })
  Assert(markup.Contains(parameter, StringComparison.Ordinal), "PimState mora dobiti " + parameter + ".");

// 5. Statusi so loceni na ERP in splet in niso razlocljivi samo po barvi.
Assert(Regex.IsMatch(markup, "<PimChip Text=\"@StatusLabel\\(row\\.ErpStatus\\)\"[^>]*Prefix=\"Stanje ERP: \""),
  "Stolpec ERP mora uporabiti PimChip z govorno predpono.");
Assert(Regex.IsMatch(markup, "<PimChip Text=\"@StatusLabel\\(row\\.WebStatus\\)\"[^>]*Prefix=\"Stanje splet: \""),
  "Stolpec Splet mora uporabiti PimChip z govorno predpono.");
Assert(Regex.IsMatch(markup, "<PimBar Percent=\"row\\.Completeness\"[^>]*Label="),
  "Popolnost mora uporabiti skupni merilnik PimBar z oznako.");

// 6. Tabela in paginacija sta skupna gradnika, stolpci so imenovani.
Assert(Regex.IsMatch(markup, "<PimTable Caption=\"[^\"]+\"[^>]*AriaLabel=\"[^\"]+\""), "Tabela mora imeti napis in aria-label.");
var columns = Regex.Match(markup, "Columns =\\s*\\[(.*?)\\];", RegexOptions.Singleline);
Assert(columns.Success, "Stolpci morajo biti razglaseni kot seznam PimColumn.");
Assert(Regex.Matches(columns.Groups[1].Value, "new\\(").Count == 12, "Tabela ima dvanajst stolpcev; vsak mora imeti ime.");
Assert(!columns.Groups[1].Value.Contains("Odpri", StringComparison.Ordinal),
  "Stolpca Odpri ni vec: cela vrstica vodi na kartico, zato bi bil drugi gumb za isto stvar odvec.");
foreach (var column in new[] { "Slika", "Dobavitelj" })
  Assert(columns.Groups[1].Value.Contains(column, StringComparison.Ordinal), "Manjka stolpec " + column + ".");
Assert(!Regex.IsMatch(columns.Groups[1].Value, "new\\(\"\"\\)"), "Prazno ime stolpca ni dovoljeno; tudi izbor in odpiranje se poimenujeta.");
Assert(Regex.IsMatch(markup, "<PimPager Skip=\"Skip\" Take=\"Take\" Total=\"Page\\.TotalCount\""),
  "Paginacija mora biti strezniska in izhajati iz istega stetja kot seznam.");
Assert(Regex.IsMatch(markup, "aria-label=\"Izberi izdelek @row.ItemId\""), "Vsaka kljukica mora povedati, kateri izdelek izbira.");

// 6.1 Cela vrstica vodi na kartico; naziv zato ni povezava, kljukica pa ne sme odpirati kartice.
Assert(Regex.IsMatch(markup, @"<tr class=""row-link""[^>]*@onclick=""\(\) => OpenAsync\(row\)"""),
  "Klik na vrstico mora odpreti kartico izdelka.");
Assert(markup.Contains("@onkeydown=\"args => OpenKeyAsync(args, row)\"", StringComparison.Ordinal),
  "Vrstica mora biti dosegljiva tudi s tipkovnico (Enter ali preslednica).");
Assert(markup.Contains("@onclick:stopPropagation=\"true\"", StringComparison.Ordinal),
  "Klik v celico izbire ne sme odpreti kartice.");
Assert(Regex.IsMatch(markup, "<span class=\"product-name\">@row.Name</span>"),
  "Naziv je navadno besedilo, ne povezava: podcrtan naziv v vsej klikljivi vrstici obljublja dve dejanji, pa je le eno.");
Assert(!Regex.IsMatch(markup, "<a class=\"product-name\""), "Naziv ne sme biti povezava.");

// 6.2 Glavna slika izdelka mora biti vidna ze na seznamu, skozi isto varnostno politiko kot kartica.
Assert(markup.Contains("MediaUrlPolicy.Normalize(row.ThumbnailUrl)", StringComparison.Ordinal),
  "Slicica mora iti skozi skupno politiko naslovov medijev.");
Assert(Regex.IsMatch(markup, "<img src=\"@thumbnail.Href\"[^>]*loading=\"lazy\""),
  "Slicice se morajo nalagati leno; 50 slik na stran ne sme zadrzati seznama.");

// 7. Stanje pogleda mora biti v naslovu, da je povezavo mogoce deliti in gumb Nazaj dela.
foreach (var parameter in new[] { "pogled", "isci", "podjetje", "proizvajalec", "dobavitelj", "skupina", "oddelek",
  "erp", "splet", "aktivnost", "objava", "popolnost", "sort", "smer", "stran" })
  Assert(Regex.IsMatch(markup, "SupplyParameterFromQuery\\(Name = \"" + parameter + "\"\\)"),
    "Filter " + parameter + " mora ziveti v naslovu URL.");

// 8. Meja mnozicne izbire mora biti povedana na glas, ne tiho odrezana.
Assert(markup.Contains("SelectionOverflow", StringComparison.Ordinal), "Prekoracena izbira mora biti vidna uporabniku.");
Assert(Regex.IsMatch(markup, "class=\"notice\"[^>]*role=\"status\""), "Obvestilo o meji izbire mora biti razglaseno kot role=\"status\".");

// 8.1 Mnozicno urejanje pise v eno podjetje: izbira cez vec podjetij mora biti ustavljena in pojasnjena.
Assert(markup.Contains("SelectionSpansOrganizations", StringComparison.Ordinal),
  "Izbira cez vec podjetij mora biti prepoznana; sicer bi sifre enega podjetja pisale v drugo.");
Assert(Regex.IsMatch(markup, "izvozi/mnozicno\\?items=[^\"]*podjetje="),
  "Mnozicno urejanje mora dobiti podjetje izbranih izdelkov, ne privzetega.");

// 8.2 Filtri se odprejo na zahtevo in povedo, koliko jih je aktivnih; sicer je vrstica natrpana.
var filterToggle = Regex.Match(markup, "<button[^>]*class=\"[^\"]*filter-toggle[^\"]*\"[^>]*>", RegexOptions.Singleline);
Assert(filterToggle.Success, "Filtri morajo biti za gumbom, ne vsi hkrati v orodni vrstici.");
Assert(filterToggle.Value.Contains("aria-expanded", StringComparison.Ordinal), "Gumb za filtre mora povedati, ali je plosca odprta (aria-expanded).");
Assert(Regex.IsMatch(filterToggle.Value, "aria-controls=\"([^\"]+)\""), "Gumb za filtre mora kazati na plosco (aria-controls).");
var panelId = Regex.Match(filterToggle.Value, "aria-controls=\"([^\"]+)\"").Groups[1].Value;
Assert(Regex.IsMatch(markup, "id=\"" + Regex.Escape(panelId) + "\"[^>]*class=\"filter-panel\""), "Plosca s filtri mora obstajati z id " + panelId + ".");
Assert(Regex.IsMatch(markup, "<div class=\"filter-field\">\\s*<label for=\"product-organization\">"),
  "Vsak filter mora imeti vidno oznako, ne samo skrite; natrpana vrstica brez oznak je bila prav to, kar je bilo narobe.");

// 9. Izvoz pogleda uporabi iste filtre kot pogled in je delovni zvezek, ne CSV.
Assert(markup.Contains("izvoz/izdelki.xlsx", StringComparison.Ordinal), "Stran mora ponuditi izvoz trenutnega pogleda v Excel.");
Assert(!markup.Contains("izvoz/izdelki.csv", StringComparison.Ordinal), "Gumb za izvoz mora dati zvezek; CSV pot ostaja samo za skripte.");
Assert(Regex.IsMatch(markup, "string ExportHref\\(\\)\\s*\\{[^}]*Href\\(page: 1\\)", RegexOptions.Singleline),
  "Izvoz mora sestaviti naslov iz istih filtrov kot seznam.");
Assert(Regex.IsMatch(markup, "id=\"product-export\""), "Uporabnik mora izbrati, kaj se izvozi.");
foreach (var choice in new[] { "POGLED", "POGLED_SAOP", "IZBRANI", "IZBRANI_SAOP" })
  Assert(markup.Contains("value=\"" + choice + "\"", StringComparison.Ordinal), "Manjka izbira izvoza " + choice + ".");
Assert(markup.Contains("predloga=saop", StringComparison.Ordinal),
  "Predloga SAOP mora biti izbirna; njeni stolpci so register out.SaopXmlField, ne seznam v strani.");
Assert(markup.Contains("ExportDisabled", StringComparison.Ordinal),
  "Izvoz izbranih brez izbire ni dejanje, ampak past; gumb mora biti onemogocen.");

// 10. Varovalka: stran ostane vezana na dejanske bralne procedure.
var allowedCalls = new[] { "GetOrganizationsAsync", "GetProductListAsync", "GetProductListViewsAsync", "GetProductListFacetsAsync" };
foreach (var call in allowedCalls)
  Assert(markup.Contains(call, StringComparison.Ordinal), "Stran mora ohraniti klic " + call + ".");
foreach (Match call in Regex.Matches(markup, "(?:Data|Workbench)\\.(\\w+)"))
  Assert(allowedCalls.Contains(call.Groups[1].Value, StringComparer.Ordinal), "Nova podatkovna poizvedba ni v obsegu naloge: " + call.Value);

// 11. Varovalka: stran sme brati in izbirati, ne sme pa pisati.
// <img> je bil prepovedan, dokler seznam ni imel medijev. Uporabnik je zahteval glavno sliko
// izdelka v vrstici, zato prepoved ni vec pogodba; namesto nje veljata zahtevi zgoraj: slika
// mora skozi MediaUrlPolicy in se nalagati leno.
foreach (var forbidden in new[] { "<form", "@onsubmit", "method=\"post\"", "type=\"file\"", "<dialog", "contenteditable" })
  Assert(!markup.Contains(forbidden, StringComparison.OrdinalIgnoreCase), "Bralni seznam ne sme uvesti " + forbidden + ".");
foreach (var writeSurface in new[] { "SaopWriteService", "EnqueueAsync", "ApproveBatchAsync", "UndoProduct" })
  Assert(!markup.Contains(writeSurface, StringComparison.Ordinal), "Seznam izdelkov ne sme sam pisati: " + writeSurface + ".");
Assert(markup.Contains("izvozi/mnozicno", StringComparison.Ordinal), "Izbrani izdelki morajo voditi na stran za mnozicno urejanje.");
var allowedHandlers = new[] { "ApplyFiltersAsync", "EditSelectedAsync", "ToggleFilters" };
foreach (Match handler in Regex.Matches(markup, "@onclick=\"(\\w+)\""))
  Assert(allowedHandlers.Contains(handler.Groups[1].Value, StringComparer.Ordinal), "Novo dejanje ni v obsegu naloge: " + handler.Value);

// 12. Varovalka: vsak prikazan podatek ima svoj stolpec v bralnem modelu.
foreach (var bound in new[] { "row.Name", "row.ItemId", "row.Manufacturer", "row.ErpStatus", "row.WebStatus",
  "row.Completeness", "row.OpenIssueCount", "row.MediaCount", "row.CategoryCount", "row.PendingOutboundCount",
  "row.IsPromoted", "row.HasWebTitle", "row.LastChangedUtc", "row.OrganizationName" })
  Assert(markup.Contains(bound, StringComparison.Ordinal), "Prikaz mora izhajati iz bralnega modela: " + bound + ".");
Assert(markup.Contains("intranet.GetProductList", StringComparison.Ordinal), "Stran mora povedati, iz katerega vira bere.");
foreach (var fabricated in new[] { "Cena", "Zaloga", "Nov izdelek", "Uvozi", "Izbriši", "Osnutek" })
  Assert(!markup.Contains(fabricated, StringComparison.Ordinal), "Stran ne sme prikazovati izmisljene vsebine: " + fabricated + ".");

// 13. Slog: fokus, prelivanje in odzivnost; brez uhajanja z ::deep.
foreach (var selector in new[] { ".search-input", ".filter-select", ".ghost-button", ".link-button", ".filter-chip", ".table-scroll", ".data-table a", ".row-link", ".select-cell input" })
  Assert(css.Contains(selector + ":focus-visible", StringComparison.Ordinal), "Manjka slog fokusa za " + selector + ".");
Assert(Regex.IsMatch(css, ":focus-visible[^{]*\\{[^}]*outline:"), "Fokus mora risati obris, ne samo sence.");
Assert(!css.Contains("::deep", StringComparison.Ordinal), "Izoliran slog ne sme uhajati z ::deep.");
Assert(Regex.IsMatch(css, "\\.table-scroll\\s*\\{[^}]*overflow-x:\\s*auto"), "Ovoj tabele mora imeti overflow-x: auto.");
Assert(Regex.IsMatch(css, "\\.data-table\\s*\\{[^}]*min-width:"), "Na ozkih zaslonih se tabela ne sme stiskati; potrebna je min-width.");
Assert(Regex.IsMatch(css, "@media[^{]*max-width:\\s*900px"), "Manjka odzivno pravilo za ozke zaslone.");
Assert(!markup.Contains('\u203A'), "Unicode nadomestne ikone niso dovoljene; uporabi CSS obliko.");
// Puscice za odpiranje ni vec — odpira cela vrstica. Prazna slicica pa je se vedno oblika in ne
// besedilo, zato mora biti skrita bralcu zaslona: vrzel »brez slike« pove znacka v stolpcu Vrzeli.
Assert(Regex.IsMatch(markup, "<span class=\"thumb-empty\" aria-hidden=\"true\"></span>"),
  "Prazna slicica mora biti CSS oblika z aria-hidden.");
Assert(Regex.IsMatch(markup, "<img src=\"@thumbnail.Href\" alt=\"\""),
  "Slicica je okras ob nazivu, zato prazen alt; naziv je ze v isti vrstici.");
foreach (Match icon in Regex.Matches(markup, "<span class=\"chip-remove\"[^>]*>"))
  Assert(icon.Value.Contains("aria-hidden=\"true\"", StringComparison.Ordinal), "Okrasni krizec mora imeti aria-hidden: " + icon.Value);

Console.WriteLine("F10 products UX contract PASS.");

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
