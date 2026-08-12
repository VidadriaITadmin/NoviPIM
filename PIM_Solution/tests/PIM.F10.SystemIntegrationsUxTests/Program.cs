using System.Text.RegularExpressions;

// Pogodbeni test UX skladnosti strani /system/integracije.
// Obseg je namenoma ozek: samo predstavitev in dostopnost te strani.
// Za integracije v `../PIM_test/UX_pictures` ni potrjene slike, zato je vizualni standard
// notranji sistem že usklajenih strani (glava, zavihki, KPI sklop, kartice, pomične tabele,
// statusni čipi, stanja nalaganja/napake/praznega nabora) — enako kot pri /zaloge in /stranke.
// Starejša referenca `../PIM_test/Backup/PIM_aplikacija/Components/Pages/SystemIntegrations.razor`
// prikazuje `SyncState`, `DeltaJobState` in `OrganizationConfig`; teh virov `GetSystemIntegrationsAsync`
// ne vrača, zato jih test izrecno prepove.
// Test ne sme zahtevati novih poizvedb, novih stolpcev, novih vrednosti ali novih akcij pisanja;
// obstoječi dejanji Potrdi in Razreši morata ostati nedotaknjeni.

var root = FindRoot();
var razorPath = Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", "SystemIntegrations.razor");
var cssPath = Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", "SystemIntegrations.razor.css");

Assert(File.Exists(razorPath), "Manjka stran integracij: " + razorPath);
Assert(File.Exists(cssPath), "Manjka izoliran slog integracij: " + cssPath);

var markup = File.ReadAllText(razorPath);
var css = File.ReadAllText(cssPath);

// 1. Pot in avtorizacija ostaneta nespremenjeni; UX sklop ne sme razširiti dostopa.
Assert(markup.Contains("@page \"/system/integracije\"", StringComparison.Ordinal), "Pot strani se ne sme spremeniti.");
Assert(markup.Contains("@attribute [Authorize(Roles = \"ADMIN\")]", StringComparison.Ordinal), "Stran mora ostati omejena na vlogo ADMIN.");

// 2. Naslov strani, kontekstni zavihek in dejanje osvežitve.
Assert(Regex.IsMatch(markup, "<h1>Integracije sistema</h1>"), "Stran mora ohraniti vidni naslov <h1>Integracije sistema</h1>.");
var tabs = Regex.Match(markup, "<nav[^>]*class=\"page-tabs\"[^>]*>");
Assert(tabs.Success, "Zavihki morajo biti navigacijski sklop <nav class=\"page-tabs\">.");
Assert(Regex.IsMatch(tabs.Value, "aria-label=\"[^\"]+\""), "Zavihki morajo imeti aria-label.");
Assert(Regex.Matches(markup, "class=\"page-tab(?!s)").Count == 1,
  "Stran ima en sam podatkovno podprt pogled; drugih zavihkov brez vira ni dovoljeno uvesti.");
Assert(Regex.IsMatch(markup, "class=\"page-tab active\"[^>]*aria-current=\"page\""), "Aktivni zavihek mora imeti aria-current=\"page\".");
var refresh = Regex.Match(markup, "<button[^>]*class=\"filter-button\"[^>]*>");
Assert(refresh.Success, "Gumb za osvežitev mora ostati na strani.");
Assert(refresh.Value.Contains("type=\"button\"", StringComparison.Ordinal), "Gumb osvežitve mora imeti type=\"button\", da v obrazcu ne pošilja.");
Assert(refresh.Value.Contains("@onclick=\"Reload\"", StringComparison.Ordinal), "Gumb osvežitve mora ohraniti obstoječe dejanje Reload.");
Assert(Regex.IsMatch(refresh.Value, "disabled=\"@\\(?Loading"), "Gumb osvežitve mora ostati onemogočen med nalaganjem.");

// 3. KPI kartice morajo biti poimenovan sklop, vsaka vrednost pa izpeljana iz dejanskega read modela.
var kpiGrid = Regex.Match(markup, "<section[^>]*class=\"kpi-grid\"[^>]*>");
Assert(kpiGrid.Success, "KPI kartice morajo biti v poimenovanem sklopu <section class=\"kpi-grid\">.");
Assert(Regex.IsMatch(kpiGrid.Value, "aria-label=\"[^\"]+\""), "Sklop KPI kartic mora imeti aria-label.");
Assert(Regex.Matches(markup, "class=\"ui-card kpi\"").Count == 4,
  "Stran mora ohraniti natanko štiri obstoječe KPI kartice.");
foreach (var source in new[] { "View.Integrations.Count", "View.Integrations.Count(x=>x.IsEnabled)",
  "View.Alerts.Count(x=>x.ResolvedUtc is null)", "View.Integrations.Sum(x=>x.OutboxDeadCount)",
  "View.Integrations.Sum(x=>x.OutboxDriftCount)" })
  Assert(markup.Contains(source, StringComparison.Ordinal), "KPI vrednost mora ostati izpeljana iz " + source + ".");
// Delež brez zajamčenega imenovalca ni pošten; mrtva sporočila in odkloni ga nimajo.
Assert(!markup.Contains("kpi-share", StringComparison.Ordinal), "Odstotkov se ne prikazuje tam, kjer pogodba ne zagotavlja imenovalca.");

// 4. Stanja nalaganja, napake in potrditve dejanja morajo biti razglašena bralcem zaslona.
Assert(Regex.IsMatch(markup, "class=\"ui-card loading-state\"[^>]*role=\"status\""), "Stanje nalaganja mora biti razglašeno kot role=\"status\".");
Assert(Regex.IsMatch(markup, "class=\"ui-card error-state\"[^>]*role=\"alert\""), "Stanje napake mora biti razglašeno kot role=\"alert\".");
var message = Regex.Match(markup, "<p class=\"alert alert-success\"[^>]*>");
Assert(message.Success, "Sporočilo o uspešnem dejanju mora ostati na strani.");
foreach (var attribute in new[] { "role=\"status\"", "aria-live=\"polite\"" })
  Assert(message.Value.Contains(attribute, StringComparison.Ordinal), "Sporočilo dejanja nima " + attribute + ": " + message.Value);

// 5. Obe tabeli morata biti poimenovani kartici s pomičnim, tipkovnici dostopnim ovojem.
Assert(Regex.Matches(markup, "<section class=\"ui-card data-card\"[^>]*aria-label=\"[^\"]+\"").Count == 2,
  "Obe podatkovni kartici morata imeti aria-label.");
var scrolls = Regex.Matches(markup, "<div class=\"table-scroll\"[^>]*>");
Assert(scrolls.Count == 2, "Obe tabeli morata biti v ovoju <div class=\"table-scroll\"> zaradi prelivanja.");
foreach (Match scroll in scrolls)
  foreach (var attribute in new[] { "role=\"region\"", "tabindex=\"0\"", "aria-label=" })
    Assert(scroll.Value.Contains(attribute, StringComparison.Ordinal), "Pomični ovoj tabele nima " + attribute + ": " + scroll.Value);
Assert(Regex.Matches(markup, "<caption>").Count == 2, "Obe tabeli morata ohraniti napis <caption>.");
Assert(Regex.Matches(markup, "<th scope=\"col\"").Count == 18,
  "Tabeli morata ohraniti natanko devet + devet obstoječih stolpcev z scope=\"col\".");
Assert(Regex.Matches(markup, "class=\"numeric\"").Count >= 2, "Števec pojavitev mora biti poravnan desno v glavi in v celici.");

// 6. Prazen nabor se mora izpisati; prazna tabela ni sporočilo.
Assert(Regex.Matches(markup, "class=\"empty-state\"").Count == 2, "Obe tabeli morata imeti stanje praznega nabora.");

// 7. Statusni čipi ne smejo biti razločljivi samo po barvi.
var chipCount = Regex.Matches(markup, "class=\"status-chip ").Count;
Assert(chipCount == 3, "Stran mora ohraniti natanko tri statusne čipe: omogočeno, stanje in resnost.");
foreach (var label in new[] { "Omogočeno: ", "Stanje: ", "Resnost: " })
  Assert(markup.Contains("<span class=\"visually-hidden\">" + label + "</span>", StringComparison.Ordinal),
    "Statusni čip nima bralcem zaslona namenjene oznake \"" + label + "\".");

// 8. Obstoječi zapisovalni dejanji morata ostati, biti razločljivi in zaščiteni pred dvojnim klikom.
foreach (var action in new[] { "Potrdi", "Razreši" })
  Assert(Regex.IsMatch(markup, "<button type=\"button\"[^>]*class=\"small-action[^\"]*\"[^>]*aria-label=\"" + action + " opozorilo @alert.Title\""),
    "Dejanje " + action + " mora imeti type=\"button\" in aria-label z naslovom opozorila.");
Assert(Regex.Matches(markup, "disabled=\"@ActionBusy\"").Count == 2, "Obe dejanji morata biti onemogočeni med izvajanjem zapisa.");
foreach (var call in new[] { "Data.AcknowledgeAlertAsync", "Data.ResolveAlertAsync" })
  Assert(markup.Contains(call, StringComparison.Ordinal), "Stran mora ohraniti klic " + call + ".");
Assert(markup.Contains("GetAuthenticationStateAsync", StringComparison.Ordinal), "Revizijski izvajalec mora ostati resnični prijavljeni uporabnik.");
Assert(Regex.Matches(markup, "@onclick=").Count == 3, "Stran ima natanko tri dejanja: osvežitev, potrditev in razrešitev.");

// 9. Tabela mora ostati berljiva na ozkih zaslonih, fokus pa viden na vseh interaktivnih elementih.
Assert(Regex.IsMatch(css, "\\.table-scroll\\s*\\{[^}]*overflow-x:\\s*auto"), "Ovoj tabele mora imeti overflow-x: auto.");
Assert(Regex.IsMatch(css, "\\.numeric\\s*\\{[^}]*text-align:\\s*right"), "Številski stolpec mora biti poravnan desno.");
Assert(Regex.IsMatch(css, "\\.numeric\\s*\\{[^}]*font-variant-numeric:\\s*tabular-nums"), "Številski stolpec mora uporabljati tabelarične številke.");
Assert(Regex.IsMatch(css, "@media[^{]*max-width:\\s*900px"), "Manjka odzivno pravilo za ozke zaslone.");
Assert(Regex.IsMatch(css, "\\.data-table\\s*\\{[^}]*min-width:"), "Na ozkih zaslonih se tabela ne sme stiskati; potrebna je min-width.");
foreach (var selector in new[] { ".filter-button", ".small-action", ".table-scroll" })
  Assert(css.Contains(selector + ":focus-visible", StringComparison.Ordinal), "Manjka slog fokusa za " + selector + ".");
Assert(Regex.IsMatch(css, ":focus-visible[^{]*\\{[^}]*outline:"), "Fokus mora risati obris, ne samo sence.");
Assert(!css.Contains("::deep", StringComparison.Ordinal), "Izoliran slog ne sme uhajati z ::deep.");

// 10. Varovalka: stran ostane vezana na obstoječe resnične poizvedbe in dejanja.
var allowedCalls = new[] { "GetCurrentOrganizationAsync", "GetSystemIntegrationsAsync", "AcknowledgeAlertAsync", "ResolveAlertAsync" };
foreach (var call in allowedCalls)
  Assert(markup.Contains("Data." + call, StringComparison.Ordinal), "Stran mora ohraniti klic " + call + ".");
foreach (Match call in Regex.Matches(markup, "Data\\.(\\w+)"))
  Assert(allowedCalls.Contains(call.Groups[1].Value, StringComparer.Ordinal), "Nova podatkovna poizvedba ni v obsegu naloge: " + call.Value);

// 11. Varovalka: brez novih kontrol, obrazcev in nepodprtih vzorcev.
foreach (var forbidden in new[] { "<form", "@onsubmit", "method=\"post\"", "<img", "<input", "type=\"checkbox\"",
  "type=\"file\"", "<dialog", "contenteditable", "class=\"pagination\"", "class=\"toolbar\"" })
  Assert(!markup.Contains(forbidden, StringComparison.OrdinalIgnoreCase), "Ta sklop ne sme uvesti " + forbidden + ".");
foreach (var glyph in new[] { '\u203A', '\u2713', '\u26A0', '\u2699', '\u21BB' })
  Assert(!markup.Contains(glyph), "Unicode nadomestne ikone niso dovoljene; uporabi CSS obliko.");

// 12. Varovalka: starejša aplikacija ni podatkovna pogodba te strani.
foreach (var fabricated in new[] { "SyncState", "DeltaJobState", "OrganizationConfig", "Endpoint", "Urnik cron",
  "Uredi", "Izbriši", "Testiraj povezavo", "Poveži", "Ponovni zagon", "Dnevnik", "Zgodovina", "Izvozi", "Uvozi",
  "Nastavitve integracije", "Trend", "Uptime", "SLA" })
  Assert(!markup.Contains(fabricated, StringComparison.Ordinal), "Stran ne sme prikazovati izmišljene vsebine: " + fabricated + ".");
foreach (var literal in new[] { "99,9", "99.9", "24/7", "12 %", "0 ms" })
  Assert(!markup.Contains(literal, StringComparison.Ordinal), "Izmišljenih vrednosti se ne prepisuje v kodo: " + literal + ".");

Console.WriteLine("F10 system integrations UX contract PASS.");

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
