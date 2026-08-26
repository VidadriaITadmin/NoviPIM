using System.Text.RegularExpressions;

// Pogodbeni test celovite bralne kartice izdelka. Uporabnik je 2026-08-26 izrecno odobril
// zamenjavo stare pogodbe s stirimi zavihki. Dostopnostne zahteve prejsnje pogodbe ostajajo;
// spremenjen je samo podatkovni obseg, ki ga zdaj dokazujeta migracija 100 in Workbench servis.

var root = FindRoot();
var razorPath = Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", "ProductCard.razor");
var cssPath = Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", "ProductCard.razor.css");
var servicePath = Path.Combine(root, "src", "PIM.Intranet", "Services", "ProductWorkbenchService.cs");
var tablePath = Path.Combine(root, "src", "PIM.Intranet", "Components", "Shared", "PimTable.razor");
var statePath = Path.Combine(root, "src", "PIM.Intranet", "Components", "Shared", "PimState.razor");
var chipPath = Path.Combine(root, "src", "PIM.Intranet", "Components", "Shared", "PimChip.razor");
var barPath = Path.Combine(root, "src", "PIM.Intranet", "Components", "Shared", "PimBar.razor");

Assert(File.Exists(razorPath), "Manjka stran podrobnosti izdelka: " + razorPath);
Assert(File.Exists(cssPath), "Manjka izoliran slog podrobnosti izdelka: " + cssPath);
foreach (var path in new[] { servicePath, tablePath, statePath, chipPath, barPath })
  Assert(File.Exists(path), "Manjka zahtevani gradnik kartice: " + path);

var markup = File.ReadAllText(razorPath);
var css = File.ReadAllText(cssPath);
var service = File.ReadAllText(servicePath);
var table = File.ReadAllText(tablePath);
var state = File.ReadAllText(statePath);
var chip = File.ReadAllText(chipPath);
var bar = File.ReadAllText(barPath);

// 1. Skupna glava izrise dostopne drobtine nazaj na seznam.
Assert(markup.Contains("<PimPage", StringComparison.Ordinal), "Kartica mora uporabljati skupno glavo PimPage.");
Assert(markup.Contains("new(\"Izdelki\", \"izdelki\")", StringComparison.Ordinal), "Prva drobtina mora voditi na seznam izdelkov.");
Assert(!markup.Contains('\u203A'), "Unicode nadomestne ikone niso dovoljene; uporabi CSS obliko.");

// 2. Naslov in identifikacijska vrstica izhajata iz resničnih polj glave (referenca: naslov + "ItemID · EAN").
Assert(markup.Contains("Title=\"@Detail.Header.Name\"", StringComparison.Ordinal), "Naslov strani mora biti dejanski naziv izdelka.");
var identity = Regex.Match(markup, "<p class=\"identity-line\">[\\s\\S]*?</p>");
Assert(identity.Success, "Manjka identifikacijska vrstica <p class=\"identity-line\">.");
Assert(identity.Value.Contains("Detail.Header.ItemId", StringComparison.Ordinal), "Identifikacijska vrstica mora izpisati dejanski ItemId.");
Assert(identity.Value.Contains("Detail.Header.Ean", StringComparison.Ordinal), "Identifikacijska vrstica mora izpisati dejanski EAN.");

// 3. Glava loci aktivnost, objavo in pripravljenost obeh ciljnih svetov.
Assert(Regex.Matches(markup, "class=\"flag-chip").Count >= 2, "Glava mora ohraniti zastavici IsActive in WebPublish.");
Assert(markup.Contains(">Aktiven: ", StringComparison.Ordinal), "Zastavica aktivnosti mora imeti vidno oznako \"Aktiven: \".");
Assert(markup.Contains(">Za splet: ", StringComparison.Ordinal), "Zastavica spletne objave mora imeti vidno oznako \"Za splet: \".");
foreach (var field in new[] { "Detail.Header.IsActive", "Detail.Header.WebPublish" })
  Assert(markup.Contains(field, StringComparison.Ordinal), "Zastavica mora izhajati iz " + field + ".");
foreach (var field in new[] { "Detail.Header.IsPromoted", "Detail.Header.ErpStatus", "Detail.Header.WebStatus", "Detail.Header.Completeness" })
  Assert(markup.Contains(field, StringComparison.Ordinal), "Glava mora prikazati resnicno polje " + field + ".");

// 4. Povzetek stanja je poimenovan sklop kartic, izpeljan iz dejanskih profilov (referenca: kartice kanalov + popolnost).
var summary = Regex.Match(markup, "<section class=\"detail-summary\"[\\s\\S]*?</section>");
Assert(summary.Success, "Povzetek stanja mora biti sklop <section class=\"detail-summary\">.");
var summaryLabel = Regex.Match(summary.Value, "aria-labelledby=\"([^\"]+)\"");
Assert(summaryLabel.Success, "Sklop povzetka mora imeti aria-labelledby.");
Assert(Regex.IsMatch(markup, "<h2 id=\"" + Regex.Escape(summaryLabel.Groups[1].Value) + "\" class=\"visually-hidden\">"),
  "Naslov povzetka mora ostati bralcem zaslona dostopen in vizualno skrit.");
Assert(summary.Value.Contains("foreach", StringComparison.Ordinal) && summary.Value.Contains("Detail.Profiles", StringComparison.Ordinal),
  "Kartice povzetka se morajo izpisati iz dejanskih Detail.Profiles, ne iz vpisanih kanalov.");
Assert(summary.Value.Contains("Detail.Issues", StringComparison.Ordinal),
  "Število odprtih težav na kartici mora izhajati iz dejanskih Detail.Issues.");
Assert(summary.Value.Contains("Detail.Header.Completeness", StringComparison.Ordinal),
  "Kartica popolnosti mora izpisati dejansko popolnost izdelka.");
Assert(Regex.IsMatch(css, "\\.summary-grid\\s*\\{[^}]*grid-template-columns:"), "Kartice povzetka morajo biti postavljene v mrežo.");

// 5. Skupni merilnik popolnosti mora sporocati vrednost, ne samo sirine.
Assert(markup.Contains("<PimBar", StringComparison.Ordinal), "Povzetek mora uporabiti skupni merilnik PimBar.");
var meters = Regex.Matches(bar, "<span class=\"progress-track\"[^>]*>");
Assert(meters.Count == 1, "PimBar mora imeti en merilnik popolnosti.");
foreach (Match meter in meters)
  foreach (var attribute in new[] { "role=\"progressbar\"", "aria-valuenow=", "aria-valuemin=\"0\"", "aria-valuemax=\"100\"", "aria-label=" })
    Assert(meter.Value.Contains(attribute, StringComparison.Ordinal), "Merilnik popolnosti nima " + attribute + ": " + meter.Value);
Assert(bar.Contains("aria-valuenow=\"@Number\"", StringComparison.Ordinal), "aria-valuenow mora biti izpisan neodvisno od obmocnih nastavitev.");
foreach (Match icon in Regex.Matches(markup + bar, "<i [^>]*>"))
  Assert(icon.Value.Contains("aria-hidden=\"true\"", StringComparison.Ordinal), "Okrasni element mora imeti aria-hidden: " + icon.Value);

// 6. Zavihki so pravi ARIA tablist, vsak zavihek pa je povezan s svojim panelom (referenca: vrstica zavihkov).
var tablist = Regex.Match(markup, "<div class=\"product-tabs\"[^>]*>");
Assert(tablist.Success, "Zavihki morajo ostati sklop <div class=\"page-tabs\">.");
Assert(tablist.Value.Contains("role=\"tablist\"", StringComparison.Ordinal), "Sklop zavihkov mora biti razglašen kot role=\"tablist\".");
Assert(Regex.IsMatch(tablist.Value, "aria-label=\"[^\"]+\""), "Sklop zavihkov mora imeti aria-label.");

var tabs = Regex.Matches(markup, "<button[^>]*role=\"tab\"[^>]*>");
var panels = Regex.Matches(markup, "<section[^>]*role=\"tabpanel\"[^>]*>");
Assert(tabs.Count == 12, "Nova odobrena pogodba zahteva natanko 12 domenskih zavihkov. Najdenih: " + tabs.Count);
Assert(panels.Count == tabs.Count,
  "Vsak zavihek mora imeti natanko en pripadajoč panel role=\"tabpanel\". Zavihkov: " + tabs.Count + ", panelov: " + panels.Count);

// Pravilo ni "natanko toliko zavihkov", ampak "noben zavihek brez podatkovnega
// vira". Zato vsak panel dokazano prikazuje podatke iz modela, ne statične vsebine.
foreach (Match panel in panels)
{
  var bodyStart = panel.Index + panel.Length;
  var bodyEnd = markup.IndexOf("</section>", bodyStart, StringComparison.Ordinal);
  Assert(bodyEnd > bodyStart, "Panel ni pravilno zaprt: " + panel.Value);
  var body = markup.Substring(bodyStart, bodyEnd - bodyStart);
  Assert(body.Contains("Detail.", StringComparison.Ordinal),
    "Panel mora prikazovati podatke iz modela (Detail.*), ne statične vsebine: " + panel.Value);
}
foreach (Match tab in tabs)
{
  Assert(tab.Value.Contains("type=\"button\"", StringComparison.Ordinal), "Zavihek mora biti izrecni gumb type=\"button\": " + tab.Value);
  Assert(tab.Value.Contains("aria-selected=\"@", StringComparison.Ordinal), "Zavihek mora izračunati aria-selected iz stanja: " + tab.Value);
  var tabId = Regex.Match(tab.Value, "id=\"([^\"]+)\"");
  var controls = Regex.Match(tab.Value, "aria-controls=\"([^\"]+)\"");
  Assert(tabId.Success, "Zavihek nima id: " + tab.Value);
  Assert(controls.Success, "Zavihek nima aria-controls: " + tab.Value);
  var panel = panels.FirstOrDefault(candidate => candidate.Value.Contains("id=\"" + controls.Groups[1].Value + "\"", StringComparison.Ordinal));
  Assert(panel is not null, "Zavihek kaže na neobstoječ panel: " + controls.Value);
  Assert(panel!.Value.Contains("aria-labelledby=\"" + tabId.Groups[1].Value + "\"", StringComparison.Ordinal),
    "Panel mora biti poimenovan s svojim zavihkom: " + panel.Value);
  Assert(panel.Value.Contains("tabindex=\"0\"", StringComparison.Ordinal), "Panel mora biti dosegljiv s tipkovnico: " + panel.Value);
  Assert(panel.Value.Contains("tab-panel", StringComparison.Ordinal), "Panel mora nositi razred tab-panel: " + panel.Value);
}
Assert(markup.Contains("Detail.Profiles.Count", StringComparison.Ordinal), "Stevec kakovosti mora izhajati iz dejanskih profilov.");
Assert(markup.Contains("Detail.Issues.Count", StringComparison.Ordinal), "Stevec kakovosti mora izhajati iz dejanskih tezav.");

// 7. Tabele morajo ostati berljive, opisane in se na ozkih zaslonih vodoravno pomikati.
// Pravila se ne vežejo na fiksno število tabel, ampak na razmerje: vsaka
// podatkovna tabela mora imeti svoj pomični ovoj, vsaka tabela svoj napis in
// vsaka celica glave svoj scope. Tako nova tabela ne podre testa, izpuščen
// ovoj ali napis pa ga.
Assert(Regex.Matches(markup, "<PimTable").Count >= 10, "Kartica mora podatkovne sklope izrisati s skupnim PimTable.");
var scrolls = Regex.Matches(table, "<div class=\"table-scroll\"[^>]*>");
var dataTables = Regex.Matches(table, "<table class=\"data-table\"[^>]*>");
Assert(scrolls.Count == dataTables.Count && dataTables.Count == 1,
  "Skupni PimTable mora imeti en pomični ovoj in eno tabelo.");
foreach (Match scroll in scrolls)
  foreach (var attribute in new[] { "role=\"region\"", "tabindex=\"0\"", "aria-label=" })
    Assert(scroll.Value.Contains(attribute, StringComparison.Ordinal), "Pomični ovoj tabele nima " + attribute + ": " + scroll.Value);

var allTables = Regex.Matches(table, "<table[^>]*>");
Assert(Regex.Matches(table, "<caption>").Count == allTables.Count,
  "Vsaka tabela mora ohraniti napis <caption>.");

// \b prepreci, da bi se "<th" ujel tudi z "<thead>".
var glaveBrezScope = Regex.Matches(table, "<th\\b(?![^>]*scope=)[^>]*>");
Assert(glaveBrezScope.Count == 0,
  "Vsaka celica glave <th> mora imeti scope. Brez scope: " + (glaveBrezScope.Count > 0 ? glaveBrezScope[0].Value : ""));
Assert(table.Contains("<th scope=\"col\"", StringComparison.Ordinal), "PimTable mora stolpce oznaciti s scope=col.");
Assert(markup.Contains("<th scope=\"row\"", StringComparison.Ordinal), "Vrstice pregleda morajo imeti scope=row.");
Assert(Regex.IsMatch(css, "@media[^{]*max-width:\\s*900px"), "Manjka odzivno pravilo za ozke zaslone.");
Assert(Regex.IsMatch(css, "\\.data-table\\s*\\{[^}]*min-width:"), "Na ozkih zaslonih se tabela ne sme stiskati; potrebna je min-width.");

// 8. Statusni čipi ne smejo biti razločljivi samo po barvi.
Assert(Regex.Matches(markup, "<PimChip").Count >= 5, "Kartica mora statusne cipe uporabljati v glavi, povzetku in profilih.");
Assert(chip.Contains("<span class=\"visually-hidden\">@Prefix</span>", StringComparison.Ordinal),
  "Vsak statusni cip mora imeti bralcem zaslona namenjeno predpono.");
Assert(chip.Contains("= \"Status: \"", StringComparison.Ordinal), "Privzeta predpona statusnega cipa mora biti Status.");

// 9. Asinhrona in prazna stanja se morajo sporočiti tehnologijam za dostopnost.
Assert(markup.Contains("<PimState", StringComparison.Ordinal), "Kartica mora uporabljati skupna stanja PimState.");
Assert(Regex.IsMatch(state, "loading-state[^>]*role=\"status\""), "Stanje nalaganja mora biti razglašeno kot role=status.");
Assert(Regex.IsMatch(state, "error-state[^>]*role=\"alert\""), "Stanje napake mora biti razglašeno kot role=alert.");
// Vsaka podatkovna tabela potrebuje svoje prazno stanje, poleg tega še
// neobstoječ izdelek. Vezano na število tabel, ne na fiksno številko.
Assert(Regex.Matches(markup, "empty-state").Count >= 11,
  "Vsak domenski sklop kartice mora imeti posteno prazno stanje.");

// 10. Viden fokus tipkovnice na vseh interaktivnih in pomičnih elementih strani.
foreach (var selector in new[] { ".product-tabs button", ".tab-panel", ".media-link", ".origin-link" })
  Assert(css.Contains(selector + ":focus-visible", StringComparison.Ordinal), "Manjka slog fokusa za " + selector + ".");
Assert(Regex.IsMatch(css, ":focus-visible[^{]*\\{[^}]*outline:"), "Fokus mora risati obris, ne samo sence.");
Assert(!css.Contains("::deep", StringComparison.Ordinal), "Izoliran slog ne sme uhajati z ::deep.");

// 11. Varovalka: stran ostane vezana na obstoječi resnični poizvedbi.
var allowedCalls = new[] { "GetCurrentOrganizationAsync" };
foreach (var call in allowedCalls)
  Assert(markup.Contains("Data." + call, StringComparison.Ordinal), "Stran mora ohraniti klic " + call + ".");
foreach (Match call in Regex.Matches(markup, "Data\\.(\\w+)"))
  Assert(allowedCalls.Contains(call.Groups[1].Value, StringComparer.Ordinal), "Nova podatkovna poizvedba ni v obsegu naloge: " + call.Value);
foreach (var call in new[] { "GetProductCardAsync", "GetProductOriginAsync" })
  Assert(markup.Contains("Workbench." + call, StringComparison.Ordinal), "Kartica mora uporabiti " + call + ".");

// 12. Varovalka: obstoječe ravnanje ostane nedotaknjeno — zavihki samo preklapljajo prikaz.
foreach (var behavior in new[] { "OnParametersSetAsync", "GetProductCardAsync(organization.OrganizationId, ProductId", "GetProductOriginAsync(organization.OrganizationId, ProductId" })
  Assert(markup.Contains(behavior, StringComparison.Ordinal), "Obstoječe ravnanje strani je spremenjeno; manjka: " + behavior);
// "history" dodan 2026-08-12 s sledljivostjo sprememb (migracije 028-038).
var allowedTabs = new[] { "overview", "texts", "attributes", "categories", "media", "prices", "stock", "commercial", "quality", "outbound", "history", "origin" };
var handlers = Regex.Matches(markup, "@onclick='\\(\\)=>Tab=\"(\\w+)\"'");
Assert(handlers.Count == tabs.Count,
  "Vsak zavihek mora imeti natanko en preklop prikaza. Zavihkov: " + tabs.Count + ", preklopov: " + handlers.Count);
foreach (Match handler in handlers)
  Assert(allowedTabs.Contains(handler.Groups[1].Value, StringComparer.Ordinal), "Nov zavihek ni v obsegu naloge: " + handler.Value);
Assert(Regex.Matches(markup, "@onclick").Count == handlers.Count, "Novo dejanje ni v obsegu naloge; dovoljen je samo preklop zavihka.");

// 13. Varovalka: gre za predstavitveni sklop brez urejanja in brez nepodprtih kontrol.
foreach (var forbidden in new[] { "<form", "@onsubmit", "@bind", "method=\"post\"", "<input", "<select", "<textarea", "<img", "type=\"checkbox\"", "type=\"file\"", "<dialog", "contenteditable" })
  Assert(!markup.Contains(forbidden, StringComparison.OrdinalIgnoreCase), "Predstavitveni sklop ne sme uvesti " + forbidden + ".");

// 14. Nova polja so dovoljena samo zato, ker imajo proceduro; zapisovanje ostaja prepovedano.
foreach (var value in new[] { "intranet.GetProductCard", "intranet.GetProductOrigin", "CommandType.StoredProcedure", "GetOrdinal" })
  Assert(service.Contains(value, StringComparison.Ordinal), "Bralni servis ne dokazuje: " + value);
Assert(!service.Contains("HttpClient", StringComparison.Ordinal), "Kartica ne sme klicati zunanjih URL-jev.");
foreach (var fabricatedAction in new[] { "Shrani", "Uredi", "Izbriši", "Revalidiraj" })
  Assert(!markup.Contains(fabricatedAction, StringComparison.Ordinal), "Bralna kartica ne sme ponujati dejanja: " + fabricatedAction + ".");
foreach (var link in new[] { "zajem/tezave/INBOX/", "outbound", "mediji?izdelek=", "cene?izdelek=", "zaloge?izdelek=" })
  Assert(markup.Contains(link, StringComparison.Ordinal), "Kartica mora povezati uporabnika v kontekst: " + link);

Console.WriteLine("F10 product detail UX contract PASS.");

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
