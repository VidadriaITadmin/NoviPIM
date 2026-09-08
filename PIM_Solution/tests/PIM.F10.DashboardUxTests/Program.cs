using System.Text.RegularExpressions;

// Pogodbeni test UX skladnosti nadzorne plošče.
// Obseg je namenoma ozek: samo predstavitev in dostopnost strani /nadzorna-plosca.
// Test ne sme zahtevati novih poizvedb, novih vrednosti ali akcij pisanja.

var root = FindRoot();
var razorPath = Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", "Dashboard.razor");
var cssPath = Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", "Dashboard.razor.css");

Assert(File.Exists(razorPath), "Manjka nadzorna plošča: " + razorPath);
Assert(File.Exists(cssPath), "Manjka izoliran slog nadzorne plošče: " + cssPath);

var markup = File.ReadAllText(razorPath);
var css = File.ReadAllText(cssPath);

// 1. Povzetek stanja je poimenovan sklop s petimi karticami (referenca: 5-kartični povzetek).
var summary = Regex.Match(markup, "<section[^>]*class=\"dashboard-summary\"[^>]*>");
Assert(summary.Success, "Povzetek kartic mora biti v sklopu <section class=\"dashboard-summary\">.");
var summaryLabel = Regex.Match(summary.Value, "aria-labelledby=\"([^\"]+)\"");
Assert(summaryLabel.Success, "Sklop povzetka mora imeti aria-labelledby.");
AssertHeading(markup, summaryLabel.Groups[1].Value, "povzetka");
Assert(Regex.IsMatch(markup, "<h2 id=\"" + Regex.Escape(summaryLabel.Groups[1].Value) + "\" class=\"visually-hidden\">"),
  "Naslov povzetka mora ostati bralcem zaslona dostopen in vizualno skrit.");
Assert(Regex.Matches(markup, "class=\"metric-card ").Count == 5, "Povzetek mora imeti natanko pet kartic.");

// 2. Vsak panel je poimenovana regija, vezana na svoj vidni naslov.
// Panelov je po popravku 2026-08-28 pet, ne sest: „Moja opravila" je ponavljal dve kartici
// povzetka in priznaval, da drugih opravil v modelu ni, „Hitri dostopi" pa je podvajal levo
// navigacijo. Uporabnik je oboje oznacil za nepametno vsebino; namesto tega je prisel panel
// „Po podjetjih" s celotno tabelo.
var panels = Regex.Matches(markup, "<section[^>]*class=\"dashboard-panel[^\"]*\"[^>]*>");
Assert(panels.Count == 5, "Nadzorna plošča ima pet panelov: podjetja, kakovost, procesi, opozorila, integracije.");
Assert(markup.Contains("class=\"dashboard-panel companies-panel\"", StringComparison.Ordinal),
  "Plošča mora imeti panel z razčlenitvijo po podjetjih.");
foreach (var retired in new[] { "tasks-panel", "quick-panel", "quick-links", "unavailable-note" })
  Assert(!markup.Contains(retired, StringComparison.Ordinal), "Odpisani sklop se ne sme vrniti: " + retired + ".");
foreach (Match panel in panels)
{
  var label = Regex.Match(panel.Value, "aria-labelledby=\"([^\"]+)\"");
  Assert(label.Success, "Panel nima aria-labelledby: " + panel.Value);
  AssertHeading(markup, label.Groups[1].Value, "panela");
}

// 3. Okrasne ikone se ne smejo izgovarjati.
foreach (Match icon in Regex.Matches(markup, "<span[^>]*class=\"[^\"]*\\b(metric-icon|row-icon|quick-icon)\\b[^\"]*\"[^>]*>"))
  Assert(icon.Value.Contains("aria-hidden=\"true\"", StringComparison.Ordinal), "Okrasna ikona mora imeti aria-hidden: " + icon.Value);

// 4. Statusni čipi ne smejo biti brez konteksta (barva sama ni pomen).
var chipCount = Regex.Matches(markup, "class=\"status ").Count;
Assert(chipCount >= 2, "Statusni čipi procesov in integracij morajo ostati prisotni.");
Assert(Regex.Matches(markup, "<span class=\"visually-hidden\">Status: </span>").Count == chipCount,
  "Vsak statusni čip mora imeti bralcem zaslona namenjeno oznako \"Status: \".");

// 5. Merilnik popolnosti mora sporočati vrednost, ne samo širine.
var meterCount = Regex.Matches(markup, "class=\"progress\"").Count;
Assert(meterCount >= 1, "Kakovost po profilih mora ohraniti merilnik popolnosti.");
foreach (Match meter in Regex.Matches(markup, "<span class=\"progress\"[^>]*>"))
  foreach (var attribute in new[] { "role=\"progressbar\"", "aria-valuenow=", "aria-valuemin=\"0\"", "aria-valuemax=\"100\"", "aria-label=" })
    Assert(meter.Value.Contains(attribute, StringComparison.Ordinal), "Merilnik popolnosti nima " + attribute + ": " + meter.Value);

// 6. Asinhrona stanja se morajo sporočiti tehnologijam za dostopnost.
Assert(Regex.IsMatch(markup, "class=\"ui-card error-state\"[^>]*role=\"alert\""), "Stanje napake mora biti razglašeno kot role=\"alert\".");
Assert(Regex.IsMatch(markup, "class=\"loading-state\"[^>]*role=\"status\""), "Stanje nalaganja mora biti razglašeno kot role=\"status\".");

// 7. Tipkovnični fokus mora biti viden na vseh interaktivnih elementih plošče.
foreach (var selector in new[] { ".metric-card", ".company-row", ".quality-row", ".process-row", ".alert-row", ".integration-row", ".panel-title a", ".panel-link" })
  Assert(css.Contains(selector + ":focus-visible", StringComparison.Ordinal), "Manjka slog fokusa za " + selector + ".");
Assert(Regex.IsMatch(css, ":focus-visible[^{]*\\{[^}]*outline:"), "Fokus mora risati obris, ne samo sence.");

// 8. Varovalka: plošča ostane vezana na obstoječe resnične poizvedbe.
// GetCurrentOrganizationAsync je namenoma prepovedan: vrne vedno prvo podjetje po sifri, zato
// je plošča kazala samo DEMO. Zahteva uporabnika 2026-08-28 je celotna tabela, torej vsa podjetja.
Assert(!markup.Contains("Data.GetCurrentOrganizationAsync", StringComparison.Ordinal),
  "Plošča ne sme računati iz enega samega podjetja — številke morajo zajeti vsa aktivna podjetja.");
Assert(markup.Contains("Data.GetOrganizationsAsync", StringComparison.Ordinal),
  "Obseg plošče mora priti iz seznama vseh aktivnih podjetij.");
Assert(Regex.IsMatch(markup, "companies\\.Sum\\(company => company\\.Metrics\\.\\w+\\)"),
  "Skupne številke morajo biti vsota podjetij, ne vrednost enega.");
var allowedCalls = new[] { "GetOrganizationsAsync", "GetDashboardAsync", "GetValidationIssuesAsync", "GetPipelineRunsAsync", "GetSystemIntegrationsAsync" };
foreach (var call in allowedCalls)
  Assert(markup.Contains("Data." + call, StringComparison.Ordinal), "Nadzorna plošča mora ohraniti klic " + call + ".");
foreach (Match call in Regex.Matches(markup, "Data\\.(\\w+)"))
  Assert(allowedCalls.Contains(call.Groups[1].Value, StringComparer.Ordinal), "Nova podatkovna poizvedba ni v obsegu naloge: " + call.Value);

// 9. Varovalka: gre za predstavitveni sklop, brez akcij pisanja.
foreach (var forbidden in new[] { "<form", "<button", "<input", "@onclick", "@onchange", "@onsubmit" })
  Assert(!markup.Contains(forbidden, StringComparison.OrdinalIgnoreCase), "Predstavitveni sklop ne sme uvesti kontrole " + forbidden + ".");

// 10. Varovalka: nobene vrednosti ali sklopa iz referenčne slike brez podatkovnega vira.
foreach (var fabricated in new[] { "12.480", "Janez Novak", "Ana Kovač", "Miha Kranjec", "AZ_0002", "AZ_0016", "BT_XML_240725", "Magento export", "SAOP katalog", "Nedavne aktivnosti", "pred 15 minutami", "Izdelki brez slik" })
  Assert(!markup.Contains(fabricated, StringComparison.Ordinal), "Nadzorna plošča ne sme prikazovati izmišljene vsebine iz UX slike: " + fabricated + ".");


/* ─── Hitrost nadzorne plosce (P2-11, pregled 2026-09-08 §5) ──────────────────
   Izmerjeno 2026-09-09: intranet.GetValidationIssues je za eno podjetje tekel 9.788 ms, ker je
   prvi nabor vracal vse aktivne tezave (za podjetje 2 cez dva milijona vrstic). Plosca iz
   odgovora bere samo povzetek po profilih. Po omejitvi 714 ms, stran 8,84 s -> 4,47 s.
   Brez te pogodbe bi meja tiho izpadla ob naslednjem popravku postopka. */
var migrations = Path.Combine(root, "sql", "migrations");
var boundedPath = Path.Combine(migrations, "183_ValidationIssuesReadModelBounded.sql");
Assert(File.Exists(boundedPath), "Manjka migracija 183, ki omeji bralni model tezav.");
var bounded = File.ReadAllText(boundedPath);
Assert(bounded.Contains("@Take int = 200", StringComparison.Ordinal),
  "Prvi nabor mora imeti privzeto mejo, sicer plosca spet povlece cel katalog tezav.");
Assert(bounded.Contains("SELECT TOP (@Take)", StringComparison.Ordinal),
  "Meja mora veljati na poizvedbi in ne sele v aplikaciji.");
Assert(bounded.Contains("issueValue.ProductIssueId DESC", StringComparison.Ordinal),
  "Ob enakih casih mora biti razvrstitev ponovljiva, sicer meja vsakic odreze drugo mnozico.");

var dataService = File.ReadAllText(Path.Combine(root, "src", "PIM.Intranet", "Services", "IntranetDataService.cs"));
Assert(dataService.Contains("intranet.GetValidationIssues @OrganizationId, @Take", StringComparison.Ordinal),
  "Servis mora mejo podati izrecno; privzetek v bazi je varovalka, ne pogodba.");

Console.WriteLine("F10 dashboard UX contract PASS.");

static void AssertHeading(string markup, string headingId, string what)
{
  Assert(Regex.IsMatch(markup, "<h2 id=\"" + Regex.Escape(headingId) + "\""),
    "aria-labelledby " + what + " kaže na neobstoječ naslov: " + headingId);
}

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
