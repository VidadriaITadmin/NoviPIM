using System.Text.RegularExpressions;

// Pogodba kartice po prenovi 2026-08-27. Preverja uporabnikovo poslovno razdelitev,
// podatkovne vire, varno prikazovanje medijev in dostopnost; ne zaklepa notranjega HTML-ja.
var root = FindRoot();
var pages = Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages");
var cardPath = Path.Combine(pages, "ProductCard.razor");
var cssPath = cardPath + ".css";
var channelPath = Path.Combine(pages, "ProductCard", "ProductChannelPanel.razor");
var galleryPath = Path.Combine(pages, "ProductCard", "ProductMediaGallery.razor");
var policyPath = Path.Combine(root, "src", "PIM.Intranet", "Services", "MediaUrlPolicy.cs");
var layerPath = Path.Combine(root, "src", "PIM.Intranet", "Services", "ValidationLayer.cs");

foreach (var path in new[] { cardPath, cssPath, channelPath, galleryPath, policyPath, layerPath })
  Assert(File.Exists(path), "Manjka del prenovljene kartice: " + path);

var card = File.ReadAllText(cardPath);
var css = File.ReadAllText(cssPath);
var channel = File.ReadAllText(channelPath);
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
Assert(Regex.Matches(card, "@TabButton\\(\"").Count == 11, "Kartica mora imeti natanko 11 dogovorjenih zavihkov.");
foreach (var tab in expectedTabs)
  Assert(card.Contains($"@TabButton(\"{tab.Key}\",", StringComparison.Ordinal), "Manjka zavihek " + tab.Value + ".");
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
foreach (var forbidden in new[] { "Shrani", "Izbriši", "Revalidiraj", "HttpClient" })
  Assert(!card.Contains(forbidden, StringComparison.OrdinalIgnoreCase), "Bralna kartica ne sme ponujati ali izvajati: " + forbidden);

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
