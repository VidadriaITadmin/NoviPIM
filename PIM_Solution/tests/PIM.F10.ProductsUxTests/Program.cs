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

// 1. Glava strani; shranjeni pogledi so zdaj filter "Napaka", ne locena vrstica zavihkov.
Assert(Regex.IsMatch(markup, "<PimPage Title=\"Izdelki\""), "Stran mora uporabiti skupno glavo PimPage z naslovom Izdelki.");
// Uporabnik 2026-09-17: »a bi stran kej hitreje delal ce to odstraniva, sej to lahk vse v
// filtre dodava«. Vrstica <nav class="page-tabs"> je ob vsaki zamenjavi podjetja klicala
// intranet.GetProductListViews — sedem stetij cez cel katalog za zavihke, ki jih uporabnik ni
// nujno gledal. Ista izbira zdaj zivi v filtru Napaka (isti parameter pogled v naslovu), brez
// locenega stetja.
Assert(!markup.Contains("<nav class=\"page-tabs\"", StringComparison.Ordinal),
  "Vrstica zavihkov je odsla; shranjeni pogledi so zdaj filter Napaka.");
Assert(!markup.Contains("GetProductListViewsAsync", StringComparison.Ordinal),
  "Stetje po zavihkih ni vec potrebno, ker locene vrstice zavihkov ni vec.");
Assert(Regex.IsMatch(markup, "<label for=\"product-view\">Napaka</label>"), "Filter Napaka manjka.");
foreach (var view in new[] { "TO_FIX", "NO_IMAGE", "NO_WEB_TITLE", "NO_CATEGORY", "NO_EAN", "NOT_PUBLISHED", "WAITING_SAOP" })
  Assert(markup.Contains("<option value=\"" + view + "\">", StringComparison.Ordinal), "Manjka moznost napake " + view + ".");
Assert(markup.Contains("QueryView", StringComparison.Ordinal) && markup.Contains("ViewDraft", StringComparison.Ordinal),
  "Filter Napaka mora ziveti v naslovu (parameter pogled), kot vsi ostali filtri.");

// 2. Orodna vrstica je poimenovan iskalni sklop, vsaka kontrola ima svojo oznako.
var toolbar = Regex.Match(markup, "<section class=\"ui-card toolbar\"[^>]*>");
Assert(toolbar.Success, "Orodna vrstica mora ostati <section class=\"ui-card toolbar\">.");
Assert(toolbar.Value.Contains("role=\"search\"", StringComparison.Ordinal), "Orodna vrstica mora biti razglasena kot role=\"search\".");
var toolbarLabel = Regex.Match(toolbar.Value, "aria-labelledby=\"([^\"]+)\"");
Assert(toolbarLabel.Success, "Iskalni sklop mora imeti aria-labelledby.");
Assert(Regex.IsMatch(markup, "<h2 id=\"" + Regex.Escape(toolbarLabel.Groups[1].Value) + "\" class=\"visually-hidden\">"),
  "Naslov iskalnega sklopa mora ostati bralcem zaslona dostopen in vizualno skrit.");
foreach (var control in new[] { "product-search", "product-view", "product-organization", "product-manufacturer", "product-supplier",
  "product-group", "product-department", "product-erp", "product-web", "product-activity", "product-webpublish",
  "product-completeness", "product-sort" })
{
  Assert(Regex.IsMatch(markup, "<label[^>]*for=\"" + control + "\""), "Kontrola " + control + " nima povezane oznake <label for>.");
  // Seznami partnerjev, skupin in ABC so skupni iskalni izbirnik PimPicker (Id="..."), ki id
  // postavi na svoje vnosno polje, zato <label for> se vedno kaze nanj.
  Assert(Regex.IsMatch(markup, "(?:id|<PimPicker Id)=\"" + control + "\""), "Kontrola " + control + " ne obstaja.");
}
Assert(Regex.IsMatch(markup, "<input id=\"product-search\"[^>]*type=\"search\""), "Iskalno polje mora biti type=\"search\".");

// 3. Vrednosti filtrov so dejanske vrednosti kataloga, ne trdo kodiran seznam.
foreach (var facet in new[] { "MANUFACTURER", "SUPPLIER", "ITEM_GROUP", "DEPARTMENT" })
  Assert(markup.Contains("row.FacetKind == \"" + facet + "\"", StringComparison.Ordinal),
    "Spustni seznam " + facet + " mora izhajati iz intranet.GetProductListFilters.");

// Uporabnik bere ime partnerja, filtriramo pa po sifri, ker sifra potuje nazaj v SAOP.
// Od prehoda na PimPicker (iskanje po imenu pri 124+ dobaviteljih) je to moznost
// PimPickerOption(kljuc = FacetValue, besedilo = FacetLabel ali PartnerLabel z imenom in sifro).
foreach (var (control, options) in new[] { ("product-manufacturer", "ManufacturerOptions"), ("product-supplier", "SupplierOptions"),
  ("product-group", "GroupOptions"), ("product-department", "DepartmentOptions") })
  Assert(Regex.IsMatch(markup, "<PimPicker Id=\"" + control + "\" Options=\"" + options + "\""),
    "Filter " + control + " mora biti PimPicker z moznostmi " + options + ".");
Assert(!Regex.IsMatch(markup, @"new PimPickerOption\(facet\.FacetValue,\s*facet\.FacetValue"),
  "Spustni seznami morajo kazati ime (FacetLabel), ne sifre.");
Assert(Regex.Matches(markup, @"new PimPickerOption\(facet\.FacetValue,\s*(?:facet\.FacetLabel|PartnerLabel\(facet\))").Count >= 3
    && Regex.IsMatch(markup, @"static string PartnerLabel\(ProductListFacet facet\)[^}]*facet\.FacetLabel", RegexOptions.Singleline),
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
Assert(Regex.IsMatch(markup, @"<tr class=""row-link[^""]*""[^>]*@onclick=""\(\) => OpenAsync\(row\)"""),
  "Klik na vrstico mora odpreti kartico izdelka.");

// 6.2 Kartica se nalaga vec kot trenutek. Uporabnik 2026-08-28: »rabi nekaj casa da nalozi
// kartico artikla, in se vmes kar pokaze stran izdelki«. Seznam mora zato takoj povedati, da
// se kartica odpira, sicer je videti, kot da klik ni bil zaznan.
Assert(markup.Contains("class=\"opening-overlay\"", StringComparison.Ordinal),
  "Med odpiranjem kartice mora seznam pokazati, da se nekaj dogaja.");
Assert(Regex.IsMatch(markup, "<div class=\"opening-overlay\"[^>]*role=\"status\"[^>]*aria-live="),
  "Prekrivalo odpiranja mora biti razglaseno kot role=\"status\" z aria-live.");
Assert(Regex.IsMatch(markup, @"Opening = row\.ProductId;\s*\r?\n\s*StateHasChanged\(\);"),
  "Prekrivalo se mora izrisati, preden se navigacija zacne.");
Assert(css.Contains(".opening-spinner", StringComparison.Ordinal), "Prekrivalo mora imeti viden znak nalaganja.");
Assert(css.Contains("prefers-reduced-motion", StringComparison.Ordinal),
  "Vrtenje mora upostevati nastavitev zmanjsanega gibanja.");
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

// 8. Izbira ni tiho odrezana. Do 2026-09-17 je imela zgornjo mejo (SelectionOverflow + obvestilo
// role="status"), ker je potovala v naslovu izvoza. Uporabnik je mejo odpravil: izbira gre v
// pomnilniku do izvoza v ozadju. Zahteva ostaja, da uporabnik vidi, koliko je izbral in kaj gre ven.
Assert(!markup.Contains("SelectionOverflow", StringComparison.Ordinal),
  "Meje izbire ni vec; ce se vrne, mora biti spet povedana na glas (role=\"status\"), ne tiho odrezana.");
Assert(Regex.IsMatch(markup, @"ExportScopeLabel => Selected\.Count == 0 \? ""\(cel pogled\)"" : \$""\(izbrani: \{Selected\.Count"),
  "Gumb za izvoz mora povedati stevilo izbranih ali da gre ven cel pogled.");
Assert(markup.Contains("Selected.Values.Select(item => $\"{item.OrganizationId}|{item.ItemId}\")", StringComparison.Ordinal),
  "Izvoz izbranih mora nesti celotno izbiro s podjetjem, ne odrezanega dela.");

// 8.1 Sifra artikla je enolicna samo znotraj podjetja, zato mora izbira nositi podjetje.
// Do 2026-09-08 je to varovala prepoved izbire cez vec podjetij, ker je mnozicno urejanje
// pisalo v eno samo. Odkar je pot izvoz -> uvoz in delovni list nosi stolpec Podjetje, izbire
// ni treba omejevati; nositi pa mora podjetje vsake vrstice, sicer bi uvoz vrstico pripisal
// napacnemu podjetju.
Assert(markup.Contains("record SelectedItem(int OrganizationId, string OrganizationName, string ItemId)", StringComparison.Ordinal),
  "Izbrana vrstica mora nositi podjetje; sifra artikla je enolicna samo znotraj njega.");

// 9. Izvoz pogleda uporabi iste filtre kot pogled in je delovni zvezek, ne CSV.
// Od 2026-09-22 izvoz tece v ozadju (ExportJobService, okno izvozov v kotu vsake strani):
// povezava izvoz/izdelki.xlsx?... je zamenjana z opravilom in prenosom izvoz/zvezek/{jobId}.
Assert(Regex.IsMatch(markup, @"ExportJobs\.StartWorkbookExport\(") && markup.Contains("izvoz/zvezek/", StringComparison.Ordinal),
  "Stran mora ponuditi izvoz trenutnega pogleda v Excel (opravilo v ozadju in prenos).");
Assert(!markup.Contains("izvoz/izdelki.csv", StringComparison.Ordinal), "Gumb za izvoz mora dati zvezek; CSV pot ostaja samo za skripte.");
// »Kar vidis, se izvozi«: filter izvoza (BuildExportFilter) mora nositi natanko iste parametre
// naslova (Query*) kot poizvedba seznama. Prej je to varoval ExportHref iz Href(page: 1); ker
// izvoz ne gre vec skozi naslov, primerjamo obe sestavi ProductListFilter neposredno.
var listFilter = Regex.Match(markup, @"Workbench\.GetProductListAsync\(new ProductListFilter\((.*?)\)\);", RegexOptions.Singleline);
var exportFilter = Regex.Match(markup, @"ProductListFilter BuildExportFilter\(\) => new\((.*?)\);", RegexOptions.Singleline);
static string FilterShape(string arguments) =>
  string.Join(",", Regex.Matches(arguments, @"\b(?:Query\w+|ActiveView|CategoryTreeOf|CategoryCodeOf)\b").Select(match => match.Value));
Assert(listFilter.Success && exportFilter.Success
    && FilterShape(listFilter.Groups[1].Value) == FilterShape(exportFilter.Groups[1].Value)
    && markup.Contains("BuildExportFilter(), selection", StringComparison.Ordinal),
  "Izvoz mora sestaviti naslov iz istih filtrov kot seznam.");
// Uporabnik 2026-08-28: »Kaj je point polja Pregled – cel pregled, ker ko spreminjam se nic ne
// zgodi tako da odstrani.« Spustni seznam obsega je zato odpravljen: obseg pove izbira v tabeli
// in gumb ga izpise.
Assert(!markup.Contains("id=\"product-export\"", StringComparison.Ordinal),
  "Spustnega seznama obsega izvoza ni vec — spreminjal se je brez vidnega ucinka.");
foreach (var retired in new[] { "POGLED_SAOP", "IZBRANI_SAOP", "ExportChoice", "ExportDisabled" })
  Assert(!markup.Contains(retired, StringComparison.Ordinal), "Odpisani mehanizem izvoza se ne sme vrniti: " + retired + ".");
Assert(markup.Contains("ExportScopeLabel", StringComparison.Ordinal),
  "Gumb za izvoz mora povedati, ali gre cel pogled ali samo izbrani.");

// Uporabnik 2026-09-08: »zakaj imava petsto gumbov, naredi samo izvoz in uvoz in to je to,
// ostalo ne rabiva.« Orodna vrstica ima zato natanko dve dejanji. Do tega dne je zahteva
// govorila nasprotno — »Predloga SAOP mora ostati na voljo« in »Izbrani izdelki morajo voditi
// na stran za mnozicno urejanje« — obe sta bili pripeti na gumb na tej strani. Nobena pot ni
// izginila: predloga SAOP je na /izvoz/izdelki.xlsx?predloga=saop, cakalna lista na
// /saop/artikli (zavihek v razdelku SAOP), mnozicno urejanje na /izvozi/mnozicno (povezano s
// /kakovost in s strani uvoza). Zahteva je odslej ta, da tu ni nicesar drugega.
// Kasneje dodano po narocilu: izvoz je gumb (opravilo v ozadju, 2026-09-22), zraven je izbira
// stolpcev izvoza (»Stolpci«), povezava na odprodajo pa je zavihek-bliznjica. Pogodba zato
// dovoli natanko te stiri in nobenega drugega; noben od njih ne pise.
var actions = Regex.Match(markup, "<div class=\"toolbar-actions\">(.*?)</div>", RegexOptions.Singleline);
Assert(actions.Success, "Orodna vrstica seznama izdelkov manjka.");
var actionLinks = Regex.Matches(actions.Groups[1].Value, "<a [^>]*href=\"([^\"]+)\"").Select(match => match.Groups[1].Value).ToList();
Assert(actionLinks.Count == 2 && actionLinks.Contains("izdelki/uvoz") && actionLinks.Contains("izdelki/odprodaja"),
  "Orodna vrstica ima samo povezavi na uvoz in odprodajo; vsak nadaljnji gumb je vprasanje namesto odgovora: " + string.Join(", ", actionLinks));
var actionButtons = Regex.Matches(actions.Groups[1].Value, "<button[^>]*@onclick=\"(\\w+)\"").Select(match => match.Groups[1].Value).ToList();
Assert(Regex.Matches(actions.Groups[1].Value, "<button").Count == 2
    && actionButtons.OrderBy(name => name, StringComparer.Ordinal).SequenceEqual(new[] { "OpenColumnPickerAsync", "StartExportAsync" }),
  "V orodni vrstici seznama ni gumbov, ki bi kaj pisali; dovoljena sta le izvoz in izbira stolpcev izvoza.");
Assert(markup.Contains("ProductWorkbookService.FileName(", StringComparison.Ordinal)
    && markup.Contains("StartWorkbookExport(", StringComparison.Ordinal),
  "Izvoz mora dati delovni list — edino datoteko, ki se da vrniti nazaj.");
Assert(actions.Groups[1].Value.Contains("izdelki/uvoz", StringComparison.Ordinal),
  "Uvoz urejene datoteke mora biti dosegljiv s seznama.");
Assert(!actions.Groups[1].Value.Contains("predloga=saop", StringComparison.Ordinal)
  && !actions.Groups[1].Value.Contains("saop/artikli", StringComparison.Ordinal),
  "Poti SAOP so v razdelku SAOP, ne kot gumb na seznamu izdelkov.");

// 9.1 Novi filtri iz popravkov 2026-08-28: slika in preimenovana ABC klasifikacija.
Assert(Regex.IsMatch(markup, "<label for=\"product-image\">Slika</label>"),
  "Filter »ima sliko / brez slike« manjka.");
Assert(markup.Contains("QueryImage", StringComparison.Ordinal) && markup.Contains("ImageDraft", StringComparison.Ordinal),
  "Filter slike mora ziveti v naslovu, kot vsi ostali.");
Assert(Regex.IsMatch(markup, "<label for=\"product-department\">ABC klasifikacija</label>"),
  "Oddelek se povsod imenuje ABC klasifikacija.");
Assert(!Regex.IsMatch(markup, ">Oddelek<|Oddelek: |Vsi oddelki"),
  "Beseda »Oddelek« je nadomescena z »ABC klasifikacija«.");

// 9.2 Razvrstitev ni filter: stoji nad tabelo in ucinkuje takoj, brez gumba Uporabi.
// V isti vrstici nad tabelo je od 274 se gumb »S-popust …« (samo za urednike popustov).
Assert(Regex.IsMatch(markup, "<div class=\"table-toolbar\">(?:(?!</div>).)*?<label for=\"product-sort\">", RegexOptions.Singleline),
  "Razvrstitev mora stati nad tabelo, ne v panelu filtrov.");
Assert(markup.IndexOf("class=\"table-toolbar\"", StringComparison.Ordinal) < markup.IndexOf("aria-label=\"Seznam izdelkov\"", StringComparison.Ordinal),
  "Razvrstitev mora biti pred tabelo.");
Assert(markup.IndexOf("product-sort", StringComparison.Ordinal) > markup.IndexOf("id=\"products-filter-panel\"", StringComparison.Ordinal),
  "Razvrstitve ne sme biti vec v panelu filtrov.");
Assert(markup.Contains("@bind:after=\"ApplySortAsync\"", StringComparison.Ordinal),
  "Razvrstitev mora ucinkovati takoj ob izbiri.");

// 10. Varovalka: stran ostane vezana na dejanske bralne procedure.
var allowedCalls = new[] { "GetOrganizationsAsync", "GetProductListAsync", "GetProductListFacetsAsync" };
foreach (var call in allowedCalls)
  Assert(markup.Contains(call, StringComparison.Ordinal), "Stran mora ohraniti klic " + call + ".");
// GetCustomerTypesAsync (274): seznam tipov strank za S-popust in filter »posebni S«; bralna procedura.
var allowedReads = allowedCalls.Append("GetCustomerTypesAsync").ToArray();
// (?<![\w.]) izloci imenske prostore, npr. Microsoft.Data.SqlClient, ki niso klic servisa Data.
foreach (Match call in Regex.Matches(markup, "(?<![\\w.])(?:Data|Workbench)\\.(\\w+)"))
  Assert(allowedReads.Contains(call.Groups[1].Value, StringComparer.Ordinal), "Nova podatkovna poizvedba ni v obsegu naloge: " + call.Value);

// 11. Varovalka: stran bere in izbira; pisati sme samo S-popust (274) skozi PackagingDiscountService.
// <img> je bil prepovedan, dokler seznam ni imel medijev. Uporabnik je zahteval glavno sliko
// izdelka v vrstici, zato prepoved ni vec pogodba; namesto nje veljata zahtevi zgoraj: slika
// mora skozi MediaUrlPolicy in se nalagati leno.
foreach (var forbidden in new[] { "<form", "@onsubmit", "method=\"post\"", "type=\"file\"", "<dialog", "contenteditable" })
  Assert(!markup.Contains(forbidden, StringComparison.OrdinalIgnoreCase), "Bralni seznam ne sme uvesti " + forbidden + ".");
foreach (var writeSurface in new[] { "SaopWriteService", "EnqueueAsync", "ApproveBatchAsync", "UndoProduct" })
  Assert(!markup.Contains(writeSurface, StringComparison.Ordinal), "Seznam izdelkov ne sme sam pisati: " + writeSurface + ".");
// Bliznjica na mnozicno urejanje je 2026-09-08 odsla z orodne vrstice (glej razdelek 9); stran
// je dosegljiva s /kakovost in s strani uvoza, izbira na seznamu pa odslej doloca samo obseg
// izvoza.
Assert(!markup.Contains("izvozi/mnozicno", StringComparison.Ordinal),
  "Seznam izdelkov ne vodi vec na mnozicno urejanje; pot do njega je izvoz in uvoz.");
// Edina pisalna pot s seznama je S-popust (274, narocilo lastnika): gre skozi PackagingDiscountService
// (procedure b2b.*PackagingDiscount*, ki pisejo zgodovino), okno in gumb pa sta vidna samo
// urednikom popustov. Druge pisalne poti ostanejo prepovedane (zgoraj).
Assert(markup.Contains("@if (CanEditDiscounts && BulkOpen)", StringComparison.Ordinal)
    && Regex.IsMatch(markup, @"@if \(CanEditDiscounts\)\s*\{\s*<button[^\n]*>S-popust"),
  "S-popust na seznamu mora biti skrit uporabnikom brez pravice urejanja popustov.");
foreach (Match write in Regex.Matches(markup, @"(?<![\w.])Packaging\.(\w+)"))
  Assert(new[] { "GetCatalogAsync", "GetRulesAsync", "OpenAsync", "SaveDefaultsBulkAsync", "SaveRuleAsync", "RemoveRuleAsync" }
      .Contains(write.Groups[1].Value, StringComparer.Ordinal),
    "Nova pisalna pot s seznama izdelkov ni v obsegu: " + write.Value);
// Gumbi okna »Stolpci« samo spreminjajo izbor polj izvoza v pomnilniku strani.
var allowedHandlers = new[] { "ApplyFiltersAsync", "ToggleFilters", "OpenColumnPickerAsync", "StartExportAsync",
  "CloseColumnPicker", "SelectAllColumns", "SelectNoColumns" };
foreach (Match handler in Regex.Matches(markup, "@onclick=\"(\\w+)\""))
  Assert(allowedHandlers.Contains(handler.Groups[1].Value, StringComparer.Ordinal), "Novo dejanje ni v obsegu naloge: " + handler.Value);

// 12. Varovalka: vsak prikazan podatek ima svoj stolpec v bralnem modelu.
foreach (var bound in new[] { "row.Name", "row.ItemId", "row.Manufacturer", "row.ErpStatus", "row.WebStatus",
  "row.Completeness", "row.OpenIssueCount", "row.MediaCount", "row.CategoryCount", "row.PendingOutboundCount",
  "row.IsPromoted", "row.HasWebTitle", "row.LastChangedUtc", "row.OrganizationName" })
  Assert(markup.Contains(bound, StringComparison.Ordinal), "Prikaz mora izhajati iz bralnega modela: " + bound + ".");
Assert(markup.Contains("intranet.GetProductList", StringComparison.Ordinal), "Stran mora povedati, iz katerega vira bere.");
// »Uvozi« je s tega seznama odslo 2026-09-08: stran ima zdaj resnicen uvoz na /izdelki/uvoz,
// zato beseda ne pomeni vec izmisljene vsebine. Ostale ostanejo prepovedane.
foreach (var fabricated in new[] { "Cena", "Zaloga", "Nov izdelek", "Izbriši", "Osnutek" })
  Assert(!markup.Contains(fabricated, StringComparison.Ordinal), "Stran ne sme prikazovati izmisljene vsebine: " + fabricated + ".");

// 13. Slog: fokus, prelivanje in odzivnost; brez uhajanja z ::deep.
foreach (var selector in new[] { ".search-input", ".filter-select", ".ghost-button", ".link-button", ".filter-chip", ".table-scroll", ".data-table a", ".row-link", ".select-cell input" })
  Assert(css.Contains(selector + ":focus-visible", StringComparison.Ordinal), "Manjka slog fokusa za " + selector + ".");
Assert(Regex.IsMatch(css, ":focus-visible[^{]*\\{[^}]*outline:"), "Fokus mora risati obris, ne samo sence.");
// ::deep je dovoljen samo za raztegnitev skupnega PimPickerja znotraj lastnega filtrskega polja
// (.filter-field ::deep .pim-picker); vsak drug ::deep bi slog iz strani spustil v tuje gradnike.
foreach (Match deep in Regex.Matches(css, @"[^\n{}]*::deep[^{]*"))
  Assert(Regex.IsMatch(deep.Value.Trim(), @"^\.filter-field ::deep \.pim-picker$"), "Izoliran slog ne sme uhajati z ::deep: " + deep.Value.Trim());
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


/* ─── Ozka sirina in tabela cez rob (A6 in A9, pregled 2026-09-08) ────────────
   Pri 800 px je bilo iskalno polje visoko pol zaslona: v stolpcu postane flex-basis visina.
   Tabela je tekla cez desni rob brez znaka, da je se vsebina, vrstica filtrov pa se ni imela
   kam preliti. Vsi trije popravki so v CSS in se dajo preveriti brez brskalnika. */
var narrow = Regex.Match(css, @"@media \(max-width: 900px\) \{(.*?)\n\}", RegexOptions.Singleline);
Assert(narrow.Success, "Slog izdelkov mora imeti pravila za ozko sirino.");
Assert(Regex.IsMatch(narrow.Groups[1].Value, @"\.search-field\s*\{[^}]*flex:\s*0 0 auto"),
  "Pri ozki sirini iskalno polje ne sme imeti flex-basis - ta postane visina in polje zavzame pol zaslona.");
Assert(Regex.IsMatch(css, @"\.search-field \{ flex: 1 1 22rem"),
  "Pri sirokem zaslonu naj iskalno polje ostane raztegljivo; popravek velja samo za ozko sirino.");

var appCss = File.ReadAllText(Path.Combine(root, "src", "PIM.Intranet", "wwwroot", "app.css"));
Assert(Regex.IsMatch(appCss, @"\.toolbar \{[^}]*flex-wrap: wrap"),
  "Vrstica filtrov mora imeti flex-wrap, sicer je desni del odrezan.");
Assert(appCss.Contains("background-attachment", StringComparison.Ordinal) || appCss.Contains("no-repeat local", StringComparison.Ordinal),
  "Tabela mora pokazati, da je se vsebina desno; senca na robu je pripeta z local/scroll.");
Assert(Regex.IsMatch(appCss, @"\.table-scroll \{[^}]*overflow: auto", RegexOptions.Singleline),
  "Tabela mora ostati vodoravno drsna.");
Assert(appCss.Contains(".table-scroll:focus-visible", StringComparison.Ordinal),
  "Drsno obmocje je dosegljivo s tipkovnico in mora imeti viden fokus.");

// #25: izbirnik spletnega mesta je od prenove na /splet/izvoz (predogled po profilu), /splet pa kaže izdelano datoteko.
var webExportPage = File.ReadAllText(Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", "WebExportBuild.razor"));
Assert(Regex.IsMatch(webExportPage, @"<select class=""filter-select"" @bind=""SelectedSite"""),
  "Izbirnik spletnega mesta na /splet/izvoz ne sme biti surov element brez razreda.");
Assert(webExportPage.Contains("SupplyParameterFromQuery(Name = \"profil\")", StringComparison.Ordinal)
    && webExportPage.Contains("aria-label=\"Samo objavljeni izdelki\"", StringComparison.Ordinal)
    && webExportPage.Contains("PimFormat.Count(", StringComparison.Ordinal),
  "/splet/izvoz: filtri v naslovu, aria oznaka na »Samo objavljeni« in sklanjano število vrstic (#19).");
foreach (var page in new[] { "Web.razor", "WebExportBuild.razor", "WebWithdrawals.razor", "OrganizationMismatches.razor", "CatalogControl.razor" })
  Assert(File.ReadAllText(Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", page)).Contains("Tabs=\"WebTabs.Tabs\"", StringComparison.Ordinal),
    "Strani izhoda na splet imajo iste zavihke (WebTabs): " + page);

// #88: /splet/katalog — Enter sproži iskanje (obrazec), iskanje in čakalna vrsta sta v naslovu,
// prazen rezultat ima PimState s predlogom, podnaslov kaže ime podjetja iz baze, osvežitev javi izid.
var catalogControlPage = File.ReadAllText(Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", "CatalogControl.razor"));
Assert(catalogControlPage.Contains("@onsubmit=\"SubmitAsync\"", StringComparison.Ordinal)
    && catalogControlPage.Contains("type=\"submit\"", StringComparison.Ordinal),
  "/splet/katalog: iskanje mora biti obrazec, da ga sproži tudi Enter v polju (#88).");
Assert(catalogControlPage.Contains("SupplyParameterFromQuery(Name = \"iskanje\")", StringComparison.Ordinal)
    && catalogControlPage.Contains("SupplyParameterFromQuery(Name = \"vrsta\")", StringComparison.Ordinal),
  "/splet/katalog: iskanje in »Samo čakalna vrsta O« morata biti v naslovu (#88).");
Assert(catalogControlPage.Contains("<PimState", StringComparison.Ordinal) && catalogControlPage.Contains("EmptyText=\"@EmptyText\"", StringComparison.Ordinal),
  "/splet/katalog: prazen rezultat mora pokazati PimState s predlogom (#88).");
Assert(!catalogControlPage.Contains("Katalog podjetja 2", StringComparison.Ordinal)
    && catalogControlPage.Contains("GetOrganizationsAsync", StringComparison.Ordinal),
  "/splet/katalog: podnaslov mora kazati ime podjetja iz baze, ne »podjetja 2« (#88).");
Assert(catalogControlPage.Contains("Čakalna vrsta je osvežena", StringComparison.Ordinal),
  "/splet/katalog: »Osveži čakalno vrsto« mora javiti izid (#88).");


/* ─── Obseg podjetja je viden in resnicen (U1, P2-10) ─────────────────────────
   Napis tabele je pisal »Izdelki v aktivni organizaciji«, stran pa je privzeto kazala vsa
   podjetja. Napis mora povedati dejanski obseg, ne domnevnega. */
// Prepoved velja za napis v oznaki, ne za pojasnilo v komentarju, ki staro besedilo navaja.
Assert(!markup.Contains("Caption=\"Izdelki v aktivni organizaciji\"", StringComparison.Ordinal),
  "Napis tabele ne sme trditi obsega, ki ga stran nima.");
Assert(markup.Contains("Caption=\"@ScopeCaption\"", StringComparison.Ordinal)
    && markup.Contains("Izdelki vseh podjetij", StringComparison.Ordinal),
  "Napis mora izhajati iz izbranega obsega in znati povedati tudi »vsa podjetja«.");

// Vse krsitve se zberejo in izpisejo naenkrat, da en tek pokaze celotno neujemanje s stranjo.
if (Failures.Count > 0)
{
  foreach (var failure in Failures) Console.Error.WriteLine("FAIL: " + failure);
  throw new InvalidOperationException("F10 products UX contract: " + Failures.Count + " krsitev (izpisane zgoraj).");
}
Console.WriteLine("F10 products UX contract PASS.");

static void Assert(bool condition, string message)
{
  if (!condition) Failures.Add(message);
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

partial class Program
{
  internal static readonly List<string> Failures = new();
}
