using System.Text.RegularExpressions;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Configuration;
using PIM.Intranet.Services;

// Pogodba kartice po prenovi 2026-08-28. Preverja uporabnikovo poslovno razdelitev,
// podatkovne vire, varno prikazovanje medijev in dostopnost; ne zaklepa notranjega HTML-ja.
//
// Sprememba dogovora 2026-08-27 (drugi krog): kartica ni vec bralna. Uporabnik je zahteval
// urejanje polj in lastnosti na kartici, zato prejsnja prepoved besede »Shrani« ni vec pogodba,
// ki bi karkoli varovala. Namesto nje je zaostrena zahteva, ki dejansko steje: **sprememba sme
// v katalog samo po pravi poti** — kar potuje v SAOP, gre skozi odhodno vrsto z odobritvijo,
// last PIM pa naravnost v katalog prek oznacene migracije. Prepoved HttpClient ostaja.
var root = FindRoot();
var pages = Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages");
var cardPath = Path.Combine(pages, "ProductCard.razor");
var cssPath = cardPath + ".css";
var channelPath = Path.Combine(pages, "ProductCard", "ProductChannelPanel.razor");
var galleryPath = Path.Combine(pages, "ProductCard", "ProductMediaGallery.razor");
var channelCssPath = Path.Combine(pages, "ProductCard", "ProductChannelPanel.razor.css");
var policyPath = Path.Combine(root, "src", "PIM.Intranet", "Services", "MediaUrlPolicy.cs");
var layerPath = Path.Combine(root, "src", "PIM.Intranet", "Services", "ValidationLayer.cs");

foreach (var path in new[] { cardPath, cssPath, channelPath, channelCssPath, galleryPath, policyPath, layerPath })
  Assert(File.Exists(path), "Manjka del prenovljene kartice: " + path);

var card = File.ReadAllText(cardPath);
var css = File.ReadAllText(cssPath);
var channel = File.ReadAllText(channelPath);
var channelCss = File.ReadAllText(channelCssPath);
var gallery = File.ReadAllText(galleryPath);
var policy = File.ReadAllText(policyPath);

Assert(card.Contains("@page \"/izdelki/{ProductId:long}\"", StringComparison.Ordinal), "Kartica mora ohraniti pot izdelka.");
Assert(card.Contains("<PimPage Title=\"@Detail.Header.Name\"", StringComparison.Ordinal), "Naslov mora biti dejanski naziv izdelka.");
foreach (var value in new[] { "Detail.Header.ItemId", "Detail.Header.Ean", "Detail.Header.IsActive", "Detail.Header.WebPublish", "Detail.Header.IsPromoted", "Detail.Header.Completeness" })
  Assert(card.Contains(value, StringComparison.Ordinal), "Glava mora izhajati iz " + value + ".");

Assert(card.Contains("<img src=\"@heroUrl.Href\"", StringComparison.Ordinal), "Glava mora prikazati dejansko sliko izdelka.");
Assert(card.Contains("@onerror=\"HeroFailed\"", StringComparison.Ordinal), "Nedosegljiva glavna slika mora imeti nadomestno stanje.");
Assert(card.Contains("MediaUrlPolicy.Normalize", StringComparison.Ordinal) && gallery.Contains("MediaUrlPolicy.Normalize", StringComparison.Ordinal),
  "Glava in galerija morata uporabljati skupno varnostno politiko naslovov.");
Assert(policy.Contains("Uri.UriSchemeHttp", StringComparison.Ordinal) && policy.Contains("Uri.UriSchemeHttps", StringComparison.Ordinal),
  "Politika sme dovoliti le HTTP in HTTPS.");

foreach (var channelName in new[] { "ERP (SAOP)", "Komerciala", "Splet" })
  Assert(card.Contains(channelName, StringComparison.Ordinal), "Manjka kanalski povzetek: " + channelName);
Assert(Regex.Matches(card, "class=\"ui-card channel-card").Count == 3, "Glava mora imeti natanko tri klikljive kanalske kartice.");
Assert(card.Contains("nikoli ne blokira", StringComparison.Ordinal), "Komercialna opozorila morajo izrecno povedati, da ne blokirajo.");

// Sklopi so nastali v dveh korakih. 2026-08-28: »Zakaj imava medij in zaloga skupaj — ne vem«
// (mediji in zaloga sta se locila). 2026-08-31: »komercialne podatke in pa splet podatke bi
// locili« — skupni sklop »Prodaja in kanali« se je razdelil na Komercialo in Splet.
var expectedSections = new Dictionary<string, string>
{
  ["overview"] = "Pregled",
  ["core"] = "ERP",
  ["commercial"] = "Komerciala",
  ["web"] = "Splet",
  ["media"] = "Mediji",
  ["stock"] = "Zaloga",
  ["quality-history"] = "Kakovost in zgodovina",
};
Assert(Regex.Matches(card, "new\\(\"(overview|core|commercial|web|media|stock|quality-history)\", ").Count == 7,
  "Kartica ima sedem sklopov; komerciala in splet sta locena.");
foreach (var retired in new[] { "media-stock", "panel-sales", "tab-sales" })
  Assert(!card.Contains(retired, StringComparison.Ordinal), "Odpisani skupni sklop se ne sme vrniti: " + retired + ".");
foreach (var section in expectedSections)
  Assert(Regex.IsMatch(card, "new\\(\"" + section.Key + "\", \"" + Regex.Escape(section.Value)), "Manjka sklop " + section.Value + ".");
Assert(card.Contains("Tone: \"bad\"", StringComparison.Ordinal) && card.Contains("Tone: \"warn\"", StringComparison.Ordinal),
  "Stevci v navigaciji smejo poudariti samo blokade in opozorila.");

// Zavihki morajo biti oznaka, ne sestavljeni v RenderTreeBuilder: izoliran slog Blazorja doda
// oznako obsega samo elementom iz datoteke .razor, zato so bili zavihki iz kode brez sloga in
// so bili videti kot goli gumbi brskalnika. To je pogodba, ker se je napaka ze zgodila.
Assert(Regex.IsMatch(card, "<button type=\"button\" role=\"tab\""),
  "Sklopi morajo biti zapisani kot oznaka, sicer ostanejo brez izoliranega sloga.");
Assert(!card.Contains("builder.OpenElement", StringComparison.Ordinal),
  "Vidnih elementov kartice se ne sestavlja v kodi; izoliran slog jih ne doseze.");
Assert(card.Contains("role=\"tablist\"", StringComparison.Ordinal), "Sklopi morajo biti ARIA tablist.");
foreach (var key in expectedSections.Keys)
  Assert(card.Contains("panel-" + key, StringComparison.Ordinal), "Manjka panel sklopa " + key + ".");
Assert(card.Contains("aria-selected", StringComparison.Ordinal) && card.Contains("aria-controls", StringComparison.Ordinal), "Navigacija mora povezati gumb in panel.");
Assert(card.Contains("Navigation.NavigateTo($\"izdelki/{ProductId}#{section}\"", StringComparison.Ordinal), "Izbrani sklop mora biti del deljivega URL-ja.");

Assert(Regex.Matches(card, "<ProductChannelPanel").Count == 3, "Trije kanali morajo uporabljati isti gradnik.");
foreach (var heading in new[] { "Ključni podatki", "Odprte naloge", "Prikaži vse podrobnosti" })
  Assert(card.Contains(heading, StringComparison.Ordinal), "Pregled mora vsebovati " + heading + ".");
Assert(!card.Contains("Caption=\"Kanonična vrednost, lastnik in čakajoča sprememba\"", StringComparison.Ordinal),
  "Pregled ne sme biti velika tehnicna tabela.");
Assert(card.Contains("napak blokira ERP", StringComparison.Ordinal) && card.Contains("Odpri kakovost", StringComparison.Ordinal),
  "Pregled mora jasno povedati blokado in naslednje dejanje.");
foreach (var field in new[] { "Davčna stopnja", "Izloči iz rezervacije zaloge", "Knjigovodske šifre", "Kosov v paketu", "Nabavni podatki" })
  Assert(card.Contains(field, StringComparison.Ordinal), "Manjkajoče polje mora ostati vidno: " + field + ".");
Assert(channel.Contains("ni v bralnem modelu", StringComparison.Ordinal), "Kanalski gradnik mora pošteno označiti polja zunaj modela.");

/* --- Razdelitev na kanale je prevzeta iz PIM_test -------------------------------------
   Uporabnik 2026-09-02: »razporedi podatke tako kot so pri starem PIM_test intranetu.
   Kar se tice kaj je pod ERP, kaj je pod komercialo in kaj je pod splet.«

   Merilo ni videz, ampak KATERO polje je na katerem kanalu. Test zato preverja, da so
   polja v pravem bloku ErpFields / CommercialFields / WebFields — ne kje na zaslonu so.
   Pogodba je zapisana, ker se je razdelitev ze dvakrat premaknila. */

static string BlockOf(string card, string name)
{
  var start = card.IndexOf("IReadOnlyList<ProductChannelField> " + name, StringComparison.Ordinal);
  Assert(start >= 0, "Manjka blok " + name + ".");
  var next = card.IndexOf("IReadOnlyList<ProductChannelField> ", start + 40, StringComparison.Ordinal);
  return next > 0 ? card[start..next] : card[start..];
}

var erpBlock = BlockOf(card, "ErpFields");
var comBlock = BlockOf(card, "CommercialFields");
var webBlock = BlockOf(card, "WebFields");

// ERP nosi identiteto, sifrante ERP, partnerja, davek in logistiko za izvoz (PIM_test:
// kartice »ERP — Slovenija«, »ERP — EU / tretje države«, »Pakiranje«, »Dimenzije pakiranja«).
foreach (var key in new[]
{
  "Product.ItemID", "Product.EAN", "Product.UoM", "Product.AccountingGroup", "Product.DiscountGroup",
  "Product.Supplier", "Product.Manufacturer", "Product.VatRate", "ProductPlanning",
  "ProductAttribute.Garancija", "SEARCH_NAME", "TITLE_ERP", "TITLE_ERP2",
  "ProductCommercial.NetWeight", "ProductCommercial.GrossWeight",
  "ProductCommercial.CustomsTariff", "ProductCommercial.CountryOfOrigin",
  "ProductCommercial.Pak1", "ProductCommercial.Pak2", "Product.PiecesInPackage",
  "ProductCommercial.PackageLength", "ProductCommercial.PackageWidth", "ProductCommercial.PackageHeight",
  "ProductCommercial.DimensionUnit", "ProductCommercial.Volume", "ProductCommercial.Dimensions",
})
{
  Assert(erpBlock.Contains(key, StringComparison.Ordinal), "Polje mora biti na kanalu ERP: " + key);
  Assert(!comBlock.Contains(key, StringComparison.Ordinal), "Polje ne sme biti tudi na komerciali: " + key);
}

// Komerciala nosi uvrstitev artikla, aktivnost in nabavne pogoje (PIM_test: kartica
// »Komerciala — klasifikacija in objava«). ABC klasifikacija in skupina artikla sta
// komercialni razvrstitvi, ne sifranta ERP.
foreach (var key in new[] { "Product.Department", "Product.ItemGroup", "Product.IsActive",
                            "ProductCommercial.Purchase", "ProductStockAccounting" })
{
  Assert(comBlock.Contains(key, StringComparison.Ordinal), "Polje mora biti na kanalu Komerciala: " + key);
  Assert(!erpBlock.Contains(key, StringComparison.Ordinal), "Polje ne sme biti tudi na ERP: " + key);
}

// Splet nosi objavo, spletna besedila, kategorije in atribute.
foreach (var key in new[] { "Product.WebPublish", "WEB_TITLE", "ProductCategory.", "canon.WebSite" })
{
  Assert(webBlock.Contains(key, StringComparison.Ordinal), "Polje mora biti na kanalu Splet: " + key);
  Assert(!erpBlock.Contains(key, StringComparison.Ordinal) && !comBlock.Contains(key, StringComparison.Ordinal),
    "Spletno polje ne sme biti na ERP ali komerciali: " + key);
}

// Imena skupin so prevzeta iz PIM_test, da je razdelitev prepoznavna.
foreach (var group in new[] { "ERP — Slovenija", "Dodatno (ERP iskanje, drugi naziv)",
                              "ERP — EU / tretje države", "Pakiranje", "Dimenzije pakiranja" })
  Assert(erpBlock.Contains(group, StringComparison.Ordinal), "ERP mora ohraniti skupino iz PIM_test: " + group);
Assert(comBlock.Contains("Klasifikacija in objava", StringComparison.Ordinal),
  "Komerciala mora ohraniti skupino »Klasifikacija in objava« iz PIM_test.");

// Isto kanonicno polje ne sme viseti na dveh kanalih hkrati — sicer se dve polji urejata
// ena vrednost in uporabnik ne ve, katera velja.
foreach (Match m in Regex.Matches(erpBlock, "\"(Product(?:Commercial|Text|Attribute)?\\.[A-Za-z0-9_]+)\""))
  Assert(!comBlock.Contains("\"" + m.Groups[1].Value + "\"", StringComparison.Ordinal),
    "Polje je na dveh kanalih hkrati: " + m.Groups[1].Value);

// Polja, ki jih je uporabnik pogresal: mere paketa, volumen, enota, ERP nazivi po jezikih.
foreach (var field in new[] { "ProductCommercial.PackageLength", "ProductCommercial.PackageWidth",
  "ProductCommercial.PackageHeight", "ProductCommercial.Volume", "ProductCommercial.DimensionUnit" })
  Assert(card.Contains(field, StringComparison.Ordinal), "Kartica mora pokrivati " + field + ".");
Assert(card.Contains("TITLE_ERP", StringComparison.Ordinal) && card.Contains("ErpLanguages", StringComparison.Ordinal),
  "ERP nazivi sodijo v zavihek ERP, po jezikih — ne med spletna besedila.");
Assert(card.Contains("WebTextTypes", StringComparison.Ordinal) && card.Contains("WebLanguages", StringComparison.Ordinal),
  "Spletna besedila morajo biti ponujena po vrstah in jezikih, tudi kjer jih se ni.");

Assert(card.Contains("ValidationLayer.Resolve", StringComparison.Ordinal), "Kartica mora nivoje dobiti iz skupnega razvrščevalnika.");
Assert(card.Contains("SKUPNO", StringComparison.Ordinal), "Skupne zahteve morajo biti označene.");
Assert(card.Contains("SelectedSite", StringComparison.Ordinal) && card.Contains("Spletno mesto", StringComparison.Ordinal), "Spletni kanal mora podpirati spletno mesto.");
Assert(card.Contains("PimFormat.Ago", StringComparison.Ordinal), "Svežina mora uporabljati skupno oblikovanje.");
Assert(card.Contains("Poslano, nepotrjeno", StringComparison.Ordinal), "Sent ne sme biti prikazan kot potrjeno stanje.");
Assert(Regex.IsMatch(card, "PendingApproval[^}]*Sent[^}]*=> \"warn\""), "Sent mora imeti opozorilni ton.");

foreach (var call in new[] { "GetProductCardAsync", "GetProductOriginAsync" })
  Assert(card.Contains("Workbench." + call, StringComparison.Ordinal), "Kartica mora klicati " + call + ".");
foreach (var call in new[] { "GetPriceChecksAsync", "GetStockChecksAsync" })
  Assert(card.Contains("Features." + call, StringComparison.Ordinal), "Kartica mora klicati " + call + ".");
Assert(card.Contains("<PimMissing", StringComparison.Ordinal), "Manjkajoče preverbe morajo imeti viden PimMissing.");
foreach (var forbidden in new[] { "HttpClient", "new SqlCommand", "SELECT ", "UPDATE ", "DELETE " })
  Assert(!card.Contains(forbidden, StringComparison.Ordinal), "Kartica ne sme sama do baze ali v svet: " + forbidden);

// Urejanje: dve poti, vsaka po svojem servisu, in nobena mimo druge.
Assert(card.Contains("Edits.SaveTextsAsync", StringComparison.Ordinal) && card.Contains("Edits.SaveAttributesAsync", StringComparison.Ordinal),
  "Besedila in lastnosti, ki so last PIM, morajo iti skozi ProductEditService (migracija 111).");
Assert(card.Contains("SaopWrite.EnqueueAsync", StringComparison.Ordinal),
  "Polje, ki ga PIM pise nazaj v SAOP, mora iti v odhodno vrsto, ne naravnost v katalog.");
Assert(card.Contains("ProductFieldEdit.Saop", StringComparison.Ordinal) && card.Contains("ProductFieldEdit.Text", StringComparison.Ordinal)
  && card.Contains("ProductFieldEdit.Attribute", StringComparison.Ordinal),
  "Vsako urejivo polje mora povedati, kam gre njegova sprememba.");
Assert(card.Contains("WritableSaopFields", StringComparison.Ordinal) && card.Contains("GetWritableFieldsAsync", StringComparison.Ordinal),
  "Kateri polja so pisljiva v SAOP, mora povedati register, ne seznam v strani.");
Assert(Regex.IsMatch(card, @"Writable\(fieldKey\)"),
  "Odlocitev o poti mora izhajati iz registra pisljivih polj.");
Assert(card.Contains("MissingRequired", StringComparison.Ordinal),
  "Manjkajoce obvezno polje mora biti vnosno mesto, ne samo obvestilo, da manjka.");
Assert(card.Contains("52401 or 52402", StringComparison.Ordinal),
  "Zavrnitev iz baze (tuje podjetje, besedilo v lasti SAOP) mora priti do uporabnika, ne v splosno napako.");

// Panel kanala je obrazec z oznakami, ne tabela vrednosti.
Assert(channel.Contains("<label for=\"@controlId\">", StringComparison.Ordinal), "Vsako polje mora imeti povezano oznako.");
foreach (var control in new[] { "<input id=\"@controlId\"", "<textarea id=\"@controlId\"", "<select id=\"@controlId\"" })
  Assert(channel.Contains(control, StringComparison.Ordinal), "Panel mora znati urejati polje s kontrolo " + control + ".");
Assert(channel.Contains("disabled=\"@row.Pending\"", StringComparison.Ordinal),
  "Polje, ki ze caka potrditev SAOP, se ne sme urejati naprej.");
Assert(channel.Contains("Drafts", StringComparison.Ordinal) && channel.Contains("FieldChanged", StringComparison.Ordinal),
  "Neshranjena sprememba mora ziveti v kartici, ne v panelu.");
// Slog obrazca mora biti pri komponenti, ki nosi oznako. Ko je bil pri kartici, obrazec ni
// imel nobenega sloga — polja in napisi so se zlili v eno vrstico.
foreach (var selector in new[] { ".field-grid", ".field-input", ".group-title", ".field-note" })
  Assert(channelCss.Contains(selector, StringComparison.Ordinal),
    "Slog obrazca mora biti v ProductChannelPanel.razor.css: manjka " + selector + ".");
foreach (var selector in new[] { ".field-grid", ".field-input" })
  Assert(!css.Contains(selector, StringComparison.Ordinal),
    "Slog obrazca ne sme biti v ProductCard.razor.css — do otroske komponente ne sega: " + selector + ".");
Assert(channelCss.Contains(".field.needs-value .field-input", StringComparison.Ordinal),
  "Manjkajoce obvezno polje mora biti vidno tudi v obrazcu.");
Assert(css.Contains(".product-section-nav button.active", StringComparison.Ordinal)
  && Regex.IsMatch(css, @"\.product-section-nav button\.active\s*\{[^}]*font-weight"),
  "Aktivni sklop mora biti razpoznaven tudi brez barve (pisava, podlaga, crta).");
Assert(Regex.IsMatch(css, @"\.section-nav-card\s*\{[^}]*position: sticky"),
  "Lokalna navigacija mora ostati vidna med drsenjem dolgega obrazca.");
foreach (var selector in new[] { ".product-workspace", ".blocking-banner", ".overview-grid", ".task-list" })
  Assert(css.Contains(selector, StringComparison.Ordinal), "Prenovljeni pregled potrebuje slog " + selector + ".");
Assert(card.Contains("<Actions>", StringComparison.Ordinal) && card.Contains("Shrani spremembe", StringComparison.Ordinal),
  "Dejanji kartice sodita ob naslov strani in morata jasno poimenovati shranjevanje.");

Assert(css.Contains(".product-section-nav button:focus-visible", StringComparison.Ordinal), "Navigacija sklopov mora imeti viden fokus.");
Assert(css.Contains("@media (max-width: 900px)", StringComparison.Ordinal), "Kartica mora biti odzivna.");
Assert(gallery.Contains("loading=\"lazy\"", StringComparison.Ordinal) && gallery.Contains("@onerror", StringComparison.Ordinal), "Galerija mora leno nalagati in obravnavati nedosegljive slike.");

// ─── Popravki kartice 2026-08-28 ───────────────────────────────────────────────────────────

// D1: dobavitelj in proizvajalec z imenom in sifro. Sifra ostane, ker gre nazaj v SAOP.
Assert(Regex.IsMatch(card, @"static string\? PartnerValue\(string\? code, string\? name\)"),
  "Partner mora imeti eno mesto, kjer se sestavita ime in sifra.");
Assert(card.Contains("PartnerValue(Detail.Header.Supplier, Detail.Header.SupplierName)", StringComparison.Ordinal),
  "Dobavitelj mora pokazati ime in sifro.");
Assert(card.Contains("PartnerValue(Detail.Header.Manufacturer, Detail.Header.ManufacturerName)", StringComparison.Ordinal),
  "Proizvajalec mora pokazati ime in sifro.");
Assert(!card.Contains("\"Koda dobavitelja\"", StringComparison.Ordinal) && !card.Contains("\"Koda proizvajalca\"", StringComparison.Ordinal),
  "Oznaki »Koda dobavitelja« in »Koda proizvajalca« odpadeta: polje nosi ime in sifro.");

// D2: nazivi v vseh jezikih registra, ne samo v tistih, ki jih izdelek ze ima.
Assert(card.Contains("Catalog.GetLanguagesAsync", StringComparison.Ordinal),
  "Jeziki nazivov morajo priti iz registra canon.Language, ne iz obstojecih besedil izdelka.");
Assert(card.Contains("RegisteredLanguages", StringComparison.Ordinal) && card.Contains("PimLanguages.Order", StringComparison.Ordinal),
  "Jeziki morajo biti urejeni po dogovorjenem redu sl, en, de, hr, it.");

// D3: pri spletu se lastnosti imenujejo atributi.
Assert(card.Contains("const string attributes = \"Atributi\";", StringComparison.Ordinal),
  "Pri spletu se skupina imenuje Atributi, ne Lastnosti izdelka.");
Assert(!card.Contains("Lastnosti izdelka", StringComparison.Ordinal), "Izraz »Lastnosti izdelka« je odpisan.");

// C8: pakiranje in dimenzije pakiranja stojijo pod ERP, ne pod komercialo.
// Od 2026-09-02 sta to dve loceni skupini z imeni iz PIM_test (»Pakiranje« in
// »Dimenzije pakiranja«); kje katero polje visi, preverja pogodba o kanalih zgoraj.
Assert(erpBlock.Contains("const string packaging = \"Pakiranje\";", StringComparison.Ordinal)
  && erpBlock.Contains("const string dimensions = \"Dimenzije pakiranja\";", StringComparison.Ordinal),
  "ERP mora imeti loceni skupini »Pakiranje« in »Dimenzije pakiranja«.");
Assert(erpBlock.Contains("TextField(\"Ime za iskanje\", \"SEARCH_NAME\", \"sl\"", StringComparison.Ordinal),
  "Ime za iskanje mora biti vedno vidno, tudi ko je prazno.");
Assert(erpBlock.Contains("Channel(\"Garancija\", \"ProductAttribute.Garancija\"", StringComparison.Ordinal),
  "Garancija mora biti vedno vidna, tudi ko je prazna.");
// Slovenski ERP naziv stoji med osnovnimi polji, preostali jeziki v svoji skupini —
// sicer se slovenski naziv izgubi med petimi jeziki.
Assert(erpBlock.Contains("TextField(\"ERP naziv (sl)\", \"TITLE_ERP\", \"sl\"", StringComparison.Ordinal)
  && erpBlock.Contains("!string.Equals(code, \"sl\"", StringComparison.Ordinal),
  "Slovenski ERP naziv sodi med osnovna polja, ostali jeziki v svojo skupino.");

// D5: galerija mora povedati, da so prikazane vse slike, in katera je glavna.
Assert(gallery.Contains("Vse slike izdelka (@Media.Count", StringComparison.Ordinal),
  "Galerija mora povedati, da prikazuje vse slike, in koliko jih je.");
Assert(gallery.Contains("Glavna slika", StringComparison.Ordinal), "Glavna slika mora biti oznacena kot glavna.");

// ─── Popravki kartice 2026-08-31 ───────────────────────────────────────────────────────────

// A6: sifra artikla je enolicna samo znotraj podjetja, zato mora kartica povedati, cigav je.
Assert(card.Contains("organization-badge", StringComparison.Ordinal),
  "Kartica mora povedati, iz katerega podjetja je artikel.");
Assert(card.Contains("OrganizationName = organization.Name", StringComparison.Ordinal),
  "Ime podjetja mora priti iz istega klica, ki doloci obseg kartice.");

// A1: kar je izdelek shranil, mora biti na zaslonu — tudi polje, ki ga nihce ni predvidel.
Assert(card.Contains("IEnumerable<ProductChannelField> StoredFields(", StringComparison.Ordinal),
  "Kartica mora izpisati tudi polja, ki jih pripravljen seznam ne nasteje.");
Assert(System.Text.RegularExpressions.Regex.Matches(card, @"StoredFields\(rows,").Count >= 4,
  "Vsak kanal mora dodati svoja shranjena polja.");

// A2: ERP nazivi so pari (naziv in naziv 2) in se berejo po jezikih.
Assert(card.Contains("TwoColumnGroups", StringComparison.Ordinal), "ERP nazivi morajo biti v dveh stolpcih.");
var panelPath = Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", "ProductCard", "ProductChannelPanel.razor");
var panel = File.ReadAllText(panelPath);
Assert(panel.Contains("two-columns", StringComparison.Ordinal), "Gradnik mora znati skupino v dveh stolpcih.");
var panelCss = File.ReadAllText(panelPath + ".css");
Assert(panelCss.Contains(".field-group.two-columns .field-grid", StringComparison.Ordinal),
  "Manjka slog za skupino v dveh stolpcih.");

/* --- Zavihek »SAOP endpoint« (migracija 141) ------------------------------------------ */

// Ko se PIM in SAOP ne ujemata, mora biti mogoce videti, kaj ima ERP — vkljucno s polji,
// ki jih PIM ne hrani. Zapis pride iz zajetega odgovora, ne iz novega klica v SAOP.

Assert(card.Contains("new(\"saop-endpoint\", \"SAOP endpoint\"", StringComparison.Ordinal),
  "Kartici manjka zavihek »SAOP endpoint«.");
Assert(card.IndexOf("new(\"saop-endpoint\"", StringComparison.Ordinal) > card.IndexOf("new(\"web\", \"Splet\"", StringComparison.Ordinal),
  "Zavihek »SAOP endpoint« stoji za zavihkom »Splet«.");
Assert(card.Contains("id=\"panel-saop-endpoint\"", StringComparison.Ordinal), "Manjka panel zavihka SAOP endpoint.");
Assert(card.Contains("SaopSnapshot.GetAsync", StringComparison.Ordinal), "Zavihek mora brati skozi bralni servis.");
Assert(!card.Contains("SqlCommand", StringComparison.Ordinal) && !card.Contains("SELECT ", StringComparison.Ordinal),
  "V .razor ni inline SQL.");
// Posnetek se isce po zajetih straneh odgovora in traja nekaj sekund; kartica se zato zaradi
// zavihka, ki ga nihce ne odpre, ne sme upocasniti.
Assert(card.Contains("if (section == \"saop-endpoint\") _ = LoadSnapshotAsync();", StringComparison.Ordinal),
  "Posnetek se mora nalozit sele ob odprtju zavihka.");
foreach (var column in new[] { "Vrednost v SAOP", "Vrednost v PIM", "Ujemanje" })
  Assert(card.Contains(column, StringComparison.Ordinal), "Tabela posnetka nima stolpca: " + column + ".");
Assert(card.Contains("row-different", StringComparison.Ordinal) && css.Contains(".row-different", StringComparison.Ordinal),
  "Vrstica z odklonom mora biti oznacena.");
Assert(card.Contains("Odklon", StringComparison.Ordinal) && card.Contains("PIM ne hrani", StringComparison.Ordinal),
  "Oznaka odklona ne sme biti samo barva; stolpec mora nositi tudi besedo.");
Assert(card.Contains("head.Explanation", StringComparison.Ordinal),
  "Kadar posnetka ni, mora kartica izpisati pojasnilo iz bralnega modela, ne prazne tabele.");
Assert(card.Contains("head.SourceTable", StringComparison.Ordinal) && card.Contains("head.LastModifiedAtUtc", StringComparison.Ordinal),
  "V glavi zavihka mora pisati, iz katere tabele je posnetek in kdaj je bil narejen.");


/* ─── Spletisca na kartici (D2, migracija 182) ─────────────────────────────────
   Uporabnikova odlocitev 2026-09-08: Product.WebPublish iz SAOP ni vec merilo za splet.
   Kam izdelek gre, povedo potrditvena polja po spletiscu in po njih se ravna spletna
   validacija. Kartica je edino mesto, kjer se to nastavi, zato je pogodba tu. */
Assert(card.Contains("Edits.GetWebShopsAsync", StringComparison.Ordinal),
  "Kartica mora prebrati oznake spletisc iz bralnega modela.");
Assert(card.Contains("Edits.SaveWebShopsAsync", StringComparison.Ordinal),
  "Oznaka spletisca mora iti skozi ProductEditService, ne mimo njega.");
Assert(card.Contains("id=\"panel-spletisca\"", StringComparison.Ordinal) && card.Contains("Spletišča", StringComparison.Ordinal),
  "Kartica mora imeti razdelek Spletisca.");
Assert(Regex.IsMatch(card, @"type=""checkbox"" disabled=""@\(!CanEdit \|\| ShopBusy\)"""),
  "Potrditvena polja spletisc morajo biti onemogocena za vlogo brez pravice pisanja.");
Assert(!Regex.IsMatch(card, @"WebPublish[^\n]*checkbox"),
  "Objava na splet ne sme biti vezana na Product.WebPublish.");

var webShopMigration = Path.Combine(root, "sql", "migrations", "182_ProductWebShopFlags.sql");
Assert(File.Exists(webShopMigration), "Manjka migracija 182 z oznakami spletisc.");
var webShopSql = File.ReadAllText(webShopMigration);
foreach (var contract in new[]
  { "pim.ProductWebShop", "pim.SaveProductWebShops", "intranet.GetProductWebShops", "val.RunValidation" })
  Assert(webShopSql.Contains(contract, StringComparison.Ordinal), "Migracija 182 nima pogodbe: " + contract);
Assert(Regex.Matches(webShopSql, @"profile\.Scope <> N''WEB'' OR EXISTS").Count >= 4,
  "Obseg spletnega profila mora veljati na vseh stirih mestih validacije: izbor zahtev, "
  + "zapiranje zastarelih napak, popolnost po profilu in koncno stanje izdelka.");
Assert(webShopSql.Contains("WebPublish", StringComparison.Ordinal),
  "Migracija mora povedati, zakaj WebPublish ni vec merilo.");

// Dokaz nad razvojno bazo. Test samo bere.
var connectionString = Environment.GetEnvironmentVariable("PIM_CONNECTION_STRING") ?? LocalConnectionString(root);
if (string.IsNullOrWhiteSpace(connectionString))
{
  Console.WriteLine("OPOZORILO: brez PIM_CONNECTION_STRING je dokaz posnetka SAOP nad bazo preskocen.");
}
else
{
  var settings = new SqlConnectionStringBuilder(connectionString);
  if (!string.Equals(settings.InitialCatalog, "PIM", StringComparison.OrdinalIgnoreCase))
    throw new InvalidOperationException("Dokaz posnetka SAOP je dovoljen samo v razvojni bazi PIM.");

  var service = new SaopEndpointSnapshotService(new ConfigurationBuilder()
    .AddInMemoryCollection(new Dictionary<string, string?> { ["ConnectionStrings:Pim"] = connectionString })
    .Build());

  await using var connection = new SqlConnection(connectionString);
  await connection.OpenAsync();

  // Artikel podjetja z virom SAOP, ki je v zajemu res prisel.
  var probe = await ProbeAsync(connection);
  Assert(probe is not null, "Za dokaz posnetka je potreben artikel podjetja z zajetim zapisom SAOP.");
  var (organizationId, itemId) = probe!.Value;

  var snapshot = await service.GetAsync(organizationId, itemId);
  Assert(snapshot.Head.HasSnapshot, "Artikel iz zajema mora imeti posnetek: " + itemId);
  Assert(snapshot.Head.SourceTable == "raw.Inbox", "Posnetek mora povedati, iz katere tabele je.");
  Assert(snapshot.Head.Explanation is null, "Kadar posnetek obstaja, pojasnila ni.");
  Assert(snapshot.Rows.Count > 20, "Posnetek mora vrniti celoten zapis, ne samo polj, ki jih PIM hrani.");

  // Dolga oblika: sklopi iz registra, neznano v »Ostalo«, in nobenega praznega imena.
  var known = new[] { "Item", "GeneralData", "SalesData", "StockData", "PropertiesData", "Ostalo" };
  foreach (var row in snapshot.Rows)
  {
    Assert(known.Contains(row.Section, StringComparer.Ordinal), "Neznan sklop v posnetku: " + row.Section);
    Assert(row.ElementName.Length > 0, "Element brez imena ni element.");
    Assert(row.HasCanonical || (row.FieldKey is null && !row.IsDifferent),
      "Polje brez kanonicne ustreznice ne more biti odklon: " + row.ElementName);
  }
  Assert(snapshot.Rows.Any(row => !row.HasCanonical),
    "Posnetek mora pokazati tudi polja, ki jih PIM ne hrani; sicer ne pove nic novega.");
  Assert(snapshot.Rows.Any(row => row.HasCanonical),
    "Polja s kanonicno ustreznico morajo biti prepoznana, sicer primerjave ni.");
  // Vrstni red je registrski: sklopi po SectionSort, znotraj sklopa po SortOrder.
  Assert(snapshot.Rows.Select(row => (row.SectionSort, row.SortOrder, row.ElementName))
    .SequenceEqual(snapshot.Rows.Select(row => (row.SectionSort, row.SortOrder, row.ElementName))
      .OrderBy(key => key.SectionSort).ThenBy(key => key.SortOrder).ThenBy(key => key.ElementName, StringComparer.Ordinal)),
    "Vrstni red posnetka mora priti iz registra out.SaopXmlField.");

  // Stevilke se primerjajo kot stevilke: SAOP posilja '0.000000' tam, kjer ima PIM 0.0000.
  var numeric = snapshot.Rows.FirstOrDefault(row =>
    row.HasCanonical && row.Value is not null && row.PimValue is not null
    && decimal.TryParse(row.Value, System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.InvariantCulture, out _)
    && decimal.TryParse(row.PimValue, System.Globalization.NumberStyles.Any, System.Globalization.CultureInfo.InvariantCulture, out _));
  if (numeric is not null)
  {
    var left = decimal.Parse(numeric.Value!, System.Globalization.CultureInfo.InvariantCulture);
    var right = decimal.Parse(numeric.PimValue!, System.Globalization.CultureInfo.InvariantCulture);
    Assert(numeric.IsDifferent == (left != right),
      "Stevilcno polje se mora primerjati kot stevilo, ne kot niz: " + numeric.ElementName);
  }

  // Artikel, ki ga v zajemu ni: pojasnilo, ne napaka in ne prazna tabela brez besede.
  var missing = await service.GetAsync(organizationId, "NE.OBSTAJA." + Guid.NewGuid().ToString("N")[..8]);
  Assert(!missing.Head.HasSnapshot && missing.Rows.Count == 0, "Artikla brez zajema ni mogoce imeti posnetka.");
  Assert(!string.IsNullOrWhiteSpace(missing.Head.Explanation), "Odsotnost posnetka mora biti pojasnjena.");

  // Posebni znaki v sifri ne smejo postati vzorec LIKE.
  var escaped = await service.GetAsync(organizationId, "100%_[x]");
  Assert(!escaped.Head.HasSnapshot, "Sifra s posebnimi znaki ne sme ujeti tujega zapisa.");

  /* ─── Spletisca nad bazo (182). Test samo bere. ───────────────────────────── */
  await using (var shopCommand = new SqlCommand(@"
    SELECT
      (SELECT COUNT(*) FROM sys.objects WHERE object_id = OBJECT_ID(N'pim.ProductWebShop')) AS Tabela,
      (SELECT COUNT(*) FROM sys.objects WHERE object_id = OBJECT_ID(N'pim.SaveProductWebShops')) AS Zapis,
      (SELECT COUNT(*) FROM sys.objects WHERE object_id = OBJECT_ID(N'intranet.GetProductWebShops')) AS Branje,
      (SELECT COUNT(*) FROM sys.sql_modules WHERE object_id = OBJECT_ID(N'val.RunValidation')
        AND definition LIKE N'%pim.ProductWebShop%') AS ValidacijaVeZaSpletisca,
      (SELECT COUNT(DISTINCT CategoryTreeCode) FROM val.ValidationProfile WHERE Scope = N'WEB' AND CategoryTreeCode IS NOT NULL) AS SpletnihProfilov;", connection))
  await using (var shopReader = await shopCommand.ExecuteReaderAsync())
  {
    Assert(await shopReader.ReadAsync(), "Preverba spletisc ni vrnila vrstice.");
    Assert(shopReader.GetInt32(0) == 1, "Manjka tabela pim.ProductWebShop.");
    Assert(shopReader.GetInt32(1) == 1, "Manjka postopek pim.SaveProductWebShops.");
    Assert(shopReader.GetInt32(2) == 1, "Manjka postopek intranet.GetProductWebShops.");
    Assert(shopReader.GetInt32(3) == 1, "val.RunValidation ne upošteva oznak spletisc; spletni profil bi spet validiral cel katalog.");
    Assert(shopReader.GetInt32(4) >= 1, "Spletni profil mora imeti kodo spletisca (CategoryTreeCode).");
  }

  // Bralni model mora vrniti vsa aktivna spletisca, tudi neoznacena - sicer obrazec nima
  // praznega potrditvenega polja in izdelka ni mogoce dodati na spletisce.
  await using (var listCommand = new SqlCommand("intranet.GetProductWebShops", connection) { CommandType = System.Data.CommandType.StoredProcedure })
  {
    listCommand.Parameters.AddWithValue("@ProductId", -1L);
    var shops = new List<string>();
    await using var listReader = await listCommand.ExecuteReaderAsync();
    while (await listReader.ReadAsync()) shops.Add(listReader.GetString(0));
    Assert(shops.Count >= 1, "Register spletisc je prazen; kartica ne bi imela cesa pokazati.");
    Assert(shops.Distinct(StringComparer.Ordinal).Count() == shops.Count, "Spletisce se ne sme podvajati po jezikovnih razlicicah.");
  }
}

Console.WriteLine("F10 product detail UX contract PASS.");

static void Assert(bool condition, string message)
{
  if (!condition) throw new InvalidOperationException(message);
}

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

static string? LocalConnectionString(string root)
{
  foreach (var candidate in new[] { Path.Combine(root, "appsettings.Local.json"), Path.Combine(root, "..", "appsettings.Local.json") })
  {
    if (!File.Exists(candidate)) continue;
    var match = Regex.Match(File.ReadAllText(candidate), "\"Pim\"\\s*:\\s*\"([^\"]+)\"");
    if (match.Success) return match.Groups[1].Value;
  }
  return null;
}

/// <summary>
/// Artikel, ki je v zajetem odgovoru SAOP res prisel. Vzet je iz najnovejse zajete strani,
/// da dokaz ne visi na tem, kateri artikli so trenutno v katalogu.
/// </summary>
static async Task<(int OrganizationId, string ItemId)?> ProbeAsync(SqlConnection connection)
{
  const string sql = @"
    SELECT TOP (1) inbox.OrganizationId,
      SUBSTRING(inbox.PayloadXml,
        CHARINDEX(N'<ItemID>', inbox.PayloadXml) + 8,
        CHARINDEX(N'</ItemID>', inbox.PayloadXml) - CHARINDEX(N'<ItemID>', inbox.PayloadXml) - 8)
    FROM raw.Inbox AS inbox
    INNER JOIN map.SourceConnector AS connector
      ON connector.OrganizationId = inbox.OrganizationId AND connector.SourceCode = inbox.SourceCode
     AND connector.ConnectorType = N'SAOP' AND connector.IsActive = 1
    WHERE inbox.EntityType = N'ItemGeneralData'
      AND CHARINDEX(N'<ItemID>', inbox.PayloadXml) > 0
    ORDER BY inbox.InboxId DESC;";
  await using var command = new SqlCommand(sql, connection) { CommandTimeout = 300 };
  await using var reader = await command.ExecuteReaderAsync();
  if (!await reader.ReadAsync()) return null;
  return (reader.GetInt32(0), reader.GetString(1));
}
