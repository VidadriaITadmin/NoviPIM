using System.Text.RegularExpressions;

// Pogodba kartice po prenovi 2026-08-27. Preverja uporabnikovo poslovno razdelitev,
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

var expectedTabs = new Dictionary<string, string>
{
  ["overview"] = "Pregled", ["erp"] = "ERP", ["komerciala"] = "Komerciala", ["splet"] = "Splet",
  ["media"] = "Mediji", ["prices"] = "Cene", ["stock"] = "Zaloga", ["quality"] = "Kakovost",
  ["saop"] = "SAOP", ["history"] = "Zgodovina", ["origin"] = "Izvor",
};
Assert(Regex.Matches(card, "new\\(\"(overview|erp|komerciala|splet|media|prices|stock|quality|saop|history|origin)\", ").Count == 11,
  "Kartica mora imeti natanko 11 dogovorjenih zavihkov.");
foreach (var tab in expectedTabs)
  Assert(Regex.IsMatch(card, "new\\(\"" + tab.Key + "\", \"" + Regex.Escape(tab.Value)), "Manjka zavihek " + tab.Value + ".");

// Zavihki morajo biti oznaka, ne sestavljeni v RenderTreeBuilder: izoliran slog Blazorja doda
// oznako obsega samo elementom iz datoteke .razor, zato so bili zavihki iz kode brez sloga in
// so bili videti kot goli gumbi brskalnika. To je pogodba, ker se je napaka ze zgodila.
Assert(Regex.IsMatch(card, "<button type=\"button\" role=\"tab\""),
  "Zavihki morajo biti zapisani kot oznaka, sicer ostanejo brez izoliranega sloga.");
Assert(!card.Contains("builder.OpenElement", StringComparison.Ordinal),
  "Vidnih elementov kartice se ne sestavlja v kodi; izoliran slog jih ne doseze.");
Assert(card.Contains("role=\"tablist\"", StringComparison.Ordinal), "Zavihki morajo biti ARIA tablist.");
foreach (var key in expectedTabs.Keys)
  Assert(card.Contains("panel-" + key, StringComparison.Ordinal), "Manjka panel zavihka " + key + ".");
Assert(card.Contains("aria-selected", StringComparison.Ordinal) && card.Contains("aria-controls", StringComparison.Ordinal), "Zavihki morajo povezati gumb in panel.");
Assert(card.Contains("Navigation.NavigateTo($\"izdelki/{ProductId}#{tab}\"", StringComparison.Ordinal), "Izbrani zavihek mora biti del deljivega URL-ja.");

Assert(Regex.Matches(card, "<ProductChannelPanel").Count == 3, "Trije kanali morajo uporabljati isti gradnik.");
foreach (var heading in new[] { "Kanonična vrednost", "Lastnik", "Čaka potrditev" })
  Assert(card.Contains(heading, StringComparison.Ordinal), "Pregled mora vsebovati stolpec " + heading + ".");
foreach (var field in new[] { "Davčna stopnja", "Planiranje in rezervacija", "Knjigovodske šifre", "Kosov v paketu", "Nabavni podatki" })
  Assert(card.Contains(field, StringComparison.Ordinal), "Manjkajoče polje mora ostati vidno: " + field + ".");
Assert(channel.Contains("ni v bralnem modelu", StringComparison.Ordinal), "Kanalski gradnik mora pošteno označiti polja zunaj modela.");

// Polja, ki jih je uporabnik pogresal: mere paketa, volumen, enota, ERP nazivi po jezikih.
foreach (var field in new[] { "ProductCommercial.PackageLength", "ProductCommercial.PackageWidth",
  "ProductCommercial.PackageHeight", "ProductCommercial.Volume", "ProductCommercial.DimensionUnit" })
  Assert(card.Contains(field, StringComparison.Ordinal), "Komerciala mora pokrivati " + field + ".");
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
Assert(css.Contains(".product-tabs button.active", StringComparison.Ordinal)
  && Regex.IsMatch(css, @"\.product-tabs button\.active\s*\{[^}]*font-weight"),
  "Aktivni zavihek mora biti razpoznaven tudi brez barve (pisava, podlaga, crta).");
Assert(Regex.IsMatch(css, @"\.card-bar\s*\{[^}]*position: sticky"),
  "Vrstica z zavihki in dejanji mora ostati vidna med drsenjem, sicer se izgubi, kje si.");
Assert(Regex.IsMatch(card, "<div class=\"card-bar\">"),
  "Zavihki in dejanja sodijo v eno vrstico; tri nalozene vrstice nad vsakim zavihkom so bile prevec.");

Assert(css.Contains(".product-tabs button:focus-visible", StringComparison.Ordinal), "Zavihki morajo imeti viden fokus.");
Assert(css.Contains("@media (max-width: 900px)", StringComparison.Ordinal), "Kartica mora biti odzivna.");
Assert(gallery.Contains("loading=\"lazy\"", StringComparison.Ordinal) && gallery.Contains("@onerror", StringComparison.Ordinal), "Galerija mora leno nalagati in obravnavati nedosegljive slike.");

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
