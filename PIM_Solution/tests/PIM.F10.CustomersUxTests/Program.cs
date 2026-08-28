using System.Text.RegularExpressions;

// Pogodbeni test UX skladnosti strank: seznam /stranke in kartica /stranke/{id}.
//
// Pogodba je bila 2026-08-28 predelana po zahtevah uporabnika. Prejsnja razlicica je opisovala
// stran, ki jo je uporabnik zavrnil: stiri zavihke brez proizvajalca, povezave v celicah in
// puscico na koncu vrstice, kartico brez zavihkov. Nova pogodba drzi to, kar je zahteval:
//
//   H1  vrste stranke so kupec, kupec in dobavitelj, dobavitelj, proizvajalec
//   H2  klik kjerkoli v vrstici odpre stranko; povezav in puscice v vrstici ni
//   H3  kartica ima zavihke, prvi je »Splosni podatki«
//   H4  zavihek »Komercialni podatki« zbere B2B nastavitve, skupine popustov, vrednostni
//       rabat in posebne popuste
//   H5  zavihek »Poslovne enote in tranziti« z dodajanjem iz sifranta ali na novo
//   H6  zavihek »Zaznamki« s prostim besedilom in vidnim avtorjem
//   H7  dokumenti in financni podatki se pridejo — stran to pove, ne izmislja
//   H8  zavihek »Zgodovina sprememb«

var root = FindRoot();
var pages = Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages");
var listPath = Path.Combine(pages, "Customers.razor");
var cardPath = Path.Combine(pages, "CustomerDetail.razor");
var cssPath = Path.Combine(pages, "Customers.razor.css");

foreach (var path in new[] { listPath, cardPath, cssPath })
  Assert(File.Exists(path), "Manjka datoteka: " + path);

var markup = File.ReadAllText(listPath);
var card = File.ReadAllText(cardPath);
var css = File.ReadAllText(cssPath);
var service = File.ReadAllText(Path.Combine(root, "src", "PIM.Intranet", "Services", "CustomerCardService.cs"));

/* --- Seznam strank ------------------------------------------------------------------- */

// 1. Pot, avtorizacija in naslov ostanejo nespremenjeni.
Assert(markup.Contains("@page \"/stranke\"", StringComparison.Ordinal), "Pot strani /stranke se ne sme spremeniti.");
Assert(markup.Contains("@attribute [Authorize(Roles = \"ADMIN,CATALOG_EDITOR,COMMERCIAL\")]", StringComparison.Ordinal),
  "Avtorizacijske vloge strani se ne smejo spremeniti.");
Assert(markup.Contains("<PimPage Title=\"Stranke\"", StringComparison.Ordinal), "Stran mora ohraniti vidni naslov Stranke.");

// 2. H1: pet pogledov — vsi, kupci, kupci in dobavitelji, dobavitelji, proizvajalci.
var tabs = Regex.Match(markup, "<nav[^>]*class=\"page-tabs\"[^>]*>");
Assert(tabs.Success, "Zavihki morajo biti navigacijski sklop <nav class=\"page-tabs\">.");
Assert(Regex.IsMatch(tabs.Value, "aria-label=\"[^\"]+\""), "Zavihki morajo imeti aria-label.");
foreach (var kind in new[] { "\"CUSTOMER\", \"Kupci\"", "\"BOTH\", \"Kupci in dobavitelji\"", "\"SUPPLIER\", \"Dobavitelji\"", "\"MANUFACTURER\", \"Proizvajalci\"" })
  Assert(markup.Contains(kind, StringComparison.Ordinal), "Manjka pogled po vrsti stranke: " + kind + ".");
Assert(markup.Contains("\"MANUFACTURER\" => \"Proizvajalec\"", StringComparison.Ordinal),
  "Proizvajalec mora imeti oznako tudi v stolpcu vrste.");

// 3. Stevci zavihkov izhajajo iz nalozenih vrstic, ne iz vpisanih vrednosti.
Assert(markup.Contains("@KindCount(view.Code)", StringComparison.Ordinal), "Vsak zavihek mora izpisati stevec iz dejanskih vrstic.");
Assert(Regex.IsMatch(markup, @"int KindCount\(string kind\) => \(Rows \?\? \[\]\)\.Count\("),
  "Stevec zavihka se mora izracunati iz nalozenih strank, ne iz locene poizvedbe.");

// 4. H2: cela vrstica odpre stranko; povezave in puscice v vrstici ni.
Assert(Regex.IsMatch(markup, "<tr class=\"row-link\"[^>]*@onclick=\"\\(\\) => Open\\(row\\)\""),
  "Klik kjerkoli v vrstici mora odpreti stranko.");
Assert(markup.Contains("@onkeydown=\"args => OpenKey(args, row)\"", StringComparison.Ordinal),
  "Vrstica mora biti dosegljiva tudi s tipkovnico.");
Assert(!markup.Contains("class=\"chevron\"", StringComparison.Ordinal), "Puscice na koncu vrstice ni vec.");
Assert(!markup.Contains("class=\"open-link\"", StringComparison.Ordinal), "Locene povezave za odpiranje ni vec.");
Assert(!Regex.IsMatch(markup, "<td>\\s*<a href=\"stranke/"), "V celicah seznama ni vec povezav; cela vrstica je ena poteza.");
Assert(!markup.Contains('›'), "Unicode nadomestne ikone niso dovoljene.");

// 5. Iskalni sklop, oznake in zivo stanje ostanejo.
foreach (var control in new[] { "customer-search", "customer-type" })
  Assert(Regex.IsMatch(markup, "<label[^>]*for=\"" + control + "\""), "Kontrola " + control + " nima povezane oznake <label for>.");
Assert(Regex.IsMatch(markup, "<input id=\"customer-search\"[^>]*type=\"search\""), "Iskalno polje mora biti type=\"search\".");
var count = Regex.Match(markup, "<span class=\"result-count\"[^>]*>");
Assert(count.Success, "Orodna vrstica mora ohraniti izpis stevila rezultatov.");
foreach (var attribute in new[] { "role=\"status\"", "aria-live=\"polite\"" })
  Assert(count.Value.Contains(attribute, StringComparison.Ordinal), "Izpis rezultatov nima " + attribute + ".");
Assert(markup.Contains("EmptyText=\"Za izbrane filtre ni strank.\"", StringComparison.Ordinal), "Stran mora ohraniti posteno prazno stanje.");

// 6. Paginacija ostane vidna in dostopna.
var pagination = Regex.Match(markup, "<nav class=\"pagination\"[^>]*>");
Assert(pagination.Success, "Paginacija mora ostati <nav class=\"pagination\">.");
Assert(Regex.IsMatch(pagination.Value, "aria-label=\"[^\"]+\""), "Paginacija mora imeti aria-label.");
foreach (var behavior in new[] { "const int PageSize = 25", "Skip(Page * PageSize).Take(PageSize)" })
  Assert(markup.Contains(behavior, StringComparison.Ordinal), "Obstojece ravnanje s stranmi je spremenjeno; manjka: " + behavior);

// 7. Varovalka: seznam ostane vezan na obstojeci resnicni poizvedbi.
var allowedCalls = new[] { "GetCurrentOrganizationAsync", "GetCustomersAsync" };
foreach (Match call in Regex.Matches(markup, @"Data\.(\w+)"))
  Assert(allowedCalls.Contains(call.Groups[1].Value, StringComparer.Ordinal), "Nova podatkovna poizvedba ni v obsegu: " + call.Value);
foreach (Match link in Regex.Matches(markup, "href=\"([^\"]*)\""))
  Assert(!link.Groups[1].Value.StartsWith('/'), "Povezava mora ostati base-relativna: " + link.Value);
Assert(!markup.Contains("Async(2,", StringComparison.Ordinal), "Stran ne sme uporabljati hardkodirane organizacije 2.");

// 8. Fokus tipkovnice mora biti viden.
foreach (var selector in new[] { ".page-tab", ".search-input", ".filter-select", ".pagination button" })
  Assert(css.Contains(selector + ":focus-visible", StringComparison.Ordinal), "Manjka slog fokusa za " + selector + ".");
Assert(Regex.IsMatch(css, ":focus-visible[^{]*\\{[^}]*outline:"), "Fokus mora risati obris, ne samo sence.");
Assert(!css.Contains("::deep", StringComparison.Ordinal), "Izoliran slog ne sme uhajati z ::deep.");

/* --- Kartica stranke ----------------------------------------------------------------- */

// 9. H3–H8: sest zavihkov, prvi so splosni podatki.
Assert(card.Contains("@page \"/stranke/{CustomerId:long}\"", StringComparison.Ordinal), "Pot kartice se ne sme spremeniti.");
var expectedTabs = new (string Key, string Label)[]
{
  ("general", "Splošni podatki"),
  ("commercial", "Komercialni podatki"),
  ("branches", "Poslovne enote in tranziti"),
  ("notes", "Zaznamki"),
  ("documents", "Dokumenti in finance"),
  ("history", "Zgodovina sprememb"),
};
foreach (var (key, label) in expectedTabs)
{
  Assert(card.Contains($"new(\"{key}\", \"{label}\"", StringComparison.Ordinal), "Manjka zavihek kartice: " + label + ".");
  Assert(card.Contains("id=\"panel-" + key + "\"", StringComparison.Ordinal), "Manjka panel zavihka " + key + ".");
}
Assert(card.Contains("Section = \"general\"", StringComparison.Ordinal), "Prvi zavihek kartice so splosni podatki.");
Assert(card.Contains("role=\"tablist\"", StringComparison.Ordinal) && card.Contains("aria-selected=", StringComparison.Ordinal)
  && card.Contains("aria-controls=", StringComparison.Ordinal), "Zavihki kartice morajo biti povezani s paneli po ARIA.");

// 10. H1 na kartici: vrsta stranke ponudi vse stiri vrste.
foreach (var kind in new[] { "new(\"CUSTOMER\", \"Kupec\")", "new(\"BOTH\", \"Kupec in dobavitelj\")", "new(\"SUPPLIER\", \"Dobavitelj\")", "new(\"MANUFACTURER\", \"Proizvajalec\")" })
  Assert(card.Contains(kind, StringComparison.Ordinal), "Kartici manjka vrsta stranke: " + kind + ".");

// 11. H4: komercialni zavihek pokrije vse, kar je nastel uporabnik.
foreach (var heading in new[] { "B2B spletne nastavitve", "Skupine popustov", "Vrednostni rabat", "Posebni popusti za stranko", "Popust na polno pakiranje" })
  Assert(card.Contains(heading, StringComparison.Ordinal), "Komercialnemu zavihku manjka: " + heading + ".");
Assert(card.Contains("Tip stranke", StringComparison.Ordinal) && card.Contains("Vrsta stranke", StringComparison.Ordinal),
  "Tip in vrsta stranke morata biti med komercialnimi nastavitvami.");

// 12. H5: enota se doda iz sifranta ali na novo, PE in tranzit sta loceni vrsti.
Assert(card.Contains("Iz šifranta strank", StringComparison.Ordinal) && card.Contains("— vpiši na novo —", StringComparison.Ordinal),
  "Enoto mora biti mogoce izbrati iz sifranta ali vpisati na novo.");
Assert(card.Contains("<option value=\"PE\">Poslovna enota</option>", StringComparison.Ordinal)
  && card.Contains("<option value=\"TRANZIT\">Tranzit</option>", StringComparison.Ordinal),
  "Poslovna enota in tranzit sta loceni vrsti enote.");
Assert(card.Contains("Cards.SaveBranchAsync", StringComparison.Ordinal), "Dodajanje enote mora iti skozi pisljivo pot.");

// 13. H6: zaznamek je prosto besedilo z vidnim avtorjem in se ne popravlja.
Assert(card.Contains("Cards.AddNoteAsync", StringComparison.Ordinal), "Zaznamek mora iti skozi pisljivo pot.");
Assert(card.Contains("<textarea", StringComparison.Ordinal), "Zaznamek je prosto besedilo.");
Assert(card.Contains("@note.CreatedBy", StringComparison.Ordinal), "Ob zaznamku mora pisati, kdo ga je napisal.");
Assert(card.Contains("Zapisanega zaznamka ni mogoče spremeniti", StringComparison.Ordinal),
  "Stran mora povedati, da je zaznamek zapis in ne polje.");

// 14. H7: dokumenti in finance se pridejo — stran to pove in nicesar ne izmislja.
Assert(Regex.IsMatch(card, "<PimMissing[^>]*Object=\"pim\\.CustomerDocument"),
  "Manjkajoci sklop mora biti izrecno oznacen kot manjkajoc, ne prazna tabela.");

// 15. H8: zgodovina bere obstojeco revizijsko sled; nove tabele ni.
Assert(card.Contains("Revizijska sled sprememb stranke", StringComparison.Ordinal), "Kartici manjka zgodovina sprememb.");
Assert(service.Contains("b2b.AuditLog", StringComparison.Ordinal) || service.Contains("CustomerHistoryEntry", StringComparison.Ordinal),
  "Zgodovina mora priti iz obstojece revizijske sledi.");

// 16. Varovalka: vsi podatki kartice pridejo iz enega bralnega klica.
Assert(service.Contains("intranet.GetCustomerCard", StringComparison.Ordinal),
  "Kartica mora brati iz ene procedure, ne iz sedmih klicev.");
Assert(card.Contains("Cards.GetAsync", StringComparison.Ordinal), "Kartica mora uporabiti bralni servis.");

Console.WriteLine("F10 customers UX contract PASS.");

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
