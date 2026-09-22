using Microsoft.Extensions.Configuration;
using System.Data;
using System.Text.RegularExpressions;
using Microsoft.Data.SqlClient;

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
//
// 2026-09-22 (migracija 250) je uporabnik zahteval uporabne filtre, izvoz za paketno urejanje in
// dobavitelje po podjetju. Pogodba zato doda:
//
//   H9  seznam kaze vsa podjetja (ne prvega aktivnega), podjetje je filter, kartica vzame podjetje stranke
//   H10 vloga je izracunana (izdelki podjetja, SAOP vrsta), rocna vrsta jo prepise; zavihki stejejo iz nje
//   H11 izvoz /izvoz/stranke.xlsx in uvoz /stranke/uvoz; krog izvoz -> uvoz brez sprememb ne spremeni nicesar,
//       sprememba popustov pa se pokaze v stranke.csv in katalog.csv (out.GetExportRows)

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
// H10: stolpec vloge izpise izracunano vlogo in njen vir; oznake so na enem mestu (CustomerRoles).
var listService = File.ReadAllText(Path.Combine(root, "src", "PIM.Intranet", "Services", "CustomerListService.cs"));
Assert(markup.Contains("@row.RoleLabel", StringComparison.Ordinal) && markup.Contains("RoleSourceLabel", StringComparison.Ordinal),
  "Stolpec vloge mora pokazati izracunano vlogo in njen vir.");
Assert(listService.Contains("(\"MANUFACTURER\", \"Proizvajalec\")", StringComparison.Ordinal),
  "Proizvajalec mora imeti oznako tudi v stolpcu vloge.");

// 3. Stevci zavihkov izhajajo iz nalozenih vrstic, ne iz vpisanih vrednosti.
Assert(markup.Contains("@KindCount(view.Code)", StringComparison.Ordinal), "Vsak zavihek mora izpisati stevec iz dejanskih vrstic.");
Assert(Regex.IsMatch(markup, @"int KindCount\(string kind\) => Scoped\.Count\("),
  "Stevec zavihka se mora izracunati iz nalozenih strank ob trenutnih filtrih, ne iz locene poizvedbe.");

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
foreach (var control in new[] { "customer-search", "customer-organization", "customer-type", "customer-activity", "customer-source", "customer-discount", "customer-export", "customer-magento" })
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

// 7. Varovalka: seznam bere eno proceduro za vsa podjetja (250) in seznam podjetij za filter.
// »Aktivna organizacija« je bila vedno prva (DEMO) — IQLighting, Vidadria in Ediito niso bili vidni.
var allowedCalls = new[] { "GetOrganizationsAsync" };
foreach (Match call in Regex.Matches(markup, @"Data\.(\w+)"))
  Assert(allowedCalls.Contains(call.Groups[1].Value, StringComparer.Ordinal), "Nova podatkovna poizvedba ni v obsegu: " + call.Value);
foreach (Match link in Regex.Matches(markup, "href=\"([^\"]*)\""))
  Assert(!link.Groups[1].Value.StartsWith('/'), "Povezava mora ostati base-relativna: " + link.Value);
Assert(!markup.Contains("Async(2,", StringComparison.Ordinal), "Stran ne sme uporabljati hardkodirane organizacije 2.");
Assert(markup.Contains("CustomerList.GetAsync(null)", StringComparison.Ordinal), "Seznam mora naloziti stranke vseh podjetij.");
Assert(listService.Contains("intranet.GetCustomerList", StringComparison.Ordinal), "Seznam mora brati intranet.GetCustomerList.");
Assert(markup.Contains("<option value=\"\">Vsa podjetja</option>", StringComparison.Ordinal), "Podjetje je filter; privzeto so vsa.");
Assert(!card.Contains("GetCurrentOrganizationAsync", StringComparison.Ordinal) && card.Contains("GetCustomerOrganizationAsync", StringComparison.Ordinal),
  "Kartica mora vzeti podjetje stranke, ne prvega aktivnega podjetja.");
// H11: izvoz in uvoz delovnega lista.
Assert(markup.Contains("\"izvoz/stranke.xlsx\"", StringComparison.Ordinal) && markup.Contains("href=\"stranke/uvoz\"", StringComparison.Ordinal),
  "Seznam mora ponuditi izvoz in uvoz delovnega lista strank.");

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

/* --- Kontakti stranke (migracija 140) ------------------------------------------------- */

// H-magento: e-posta, telefon, mobitel in osebe so obvezni stolpci izvoza strank za Magento.
// Zajema kontaktov iz SAOP v NoviPIM-u ni; kartica mora to povedati in vseeno ponuditi rocni vnos.

Assert(card.Contains("<h2>Kontakti</h2>", StringComparison.Ordinal), "Kartici manjka sklop Kontakti.");
foreach (var label in new[] { "E-pošta", "Telefon", "Mobitel", "Uporabniki oziroma osebe" })
  Assert(card.Contains(label, StringComparison.Ordinal), "Kontaktom manjka polje: " + label + ".");
Assert(card.Contains("Shrani kontakte", StringComparison.Ordinal) && card.Contains("Počisti ročni prepis", StringComparison.Ordinal),
  "Kontakti morajo imeti gumb za shranjevanje in za umik rocnega prepisa.");
Assert(card.Contains("Cards.SaveContactAsync", StringComparison.Ordinal), "Kontakti morajo iti skozi pisljivo pot servisa.");
Assert(Regex.IsMatch(card, "<PimMissing[^>]*Object=\"zajem SAOP GetCustomerContacts"),
  "Kadar zajema kontaktov ni, mora kartica to izrecno povedati, ne pokazati praznih polj.");
// Obrazec ureja rocni prepis; ce bi urejal ucinkovito vrednost, bi prvo shranjevanje
// posnetek iz SAOP zabetoniralo kot rocno vrednost.
foreach (var manual in new[] { "Card.Contacts.ManualEmail", "Card.Contacts.ManualPhone", "Card.Contacts.ManualMobile", "Card.Contacts.ManualPersons" })
  Assert(card.Contains(manual, StringComparison.Ordinal), "Obrazec kontaktov mora izhajati iz rocnega prepisa: " + manual + ".");
Assert(card.Contains("@OriginLabel(contacts.EmailSource)", StringComparison.Ordinal),
  "Ob vsakem polju mora biti znacka, ali je vrednost rocna ali iz SAOP.");
Assert(service.Contains("b2b.SaveCustomerContact", StringComparison.Ordinal),
  "Pisljiva pot kontaktov mora klicati proceduro, ne pisati inline SQL.");
Assert(!card.Contains("SELECT ", StringComparison.Ordinal) && !card.Contains("SqlCommand", StringComparison.Ordinal),
  "V .razor ni inline SQL.");

// Dokaz nad razvojno bazo: osem naborov, pisljiva pot in revizijska sled.
// Migracija sama tega ne more dokazati — T-SQL naborov tuje procedure ne zna presteti.
var connectionString = Environment.GetEnvironmentVariable("PIM_CONNECTION_STRING") ?? LocalConnectionString(root);
if (string.IsNullOrWhiteSpace(connectionString))
{
  Console.WriteLine("OPOZORILO: brez PIM_CONNECTION_STRING je dokaz kontaktov nad bazo preskocen.");
}
else
{
  var settings = new SqlConnectionStringBuilder(connectionString);
  if (!string.Equals(settings.InitialCatalog, "PIM", StringComparison.OrdinalIgnoreCase))
    throw new InvalidOperationException("Test kontaktov je dovoljen samo v razvojni bazi PIM.");

  await using var connection = new SqlConnection(connectionString);
  await connection.OpenAsync();

  // Stranka brez rocnega prepisa: test pise samo vrstico, ki jo ustvari sam, in jo za sabo pobrise.
  var target = await ScalarPairAsync(connection, @"
    SELECT TOP (1) customer.OrganizationId, customer.CustomerId
    FROM b2b.Customer AS customer
    WHERE NOT EXISTS (SELECT 1 FROM pim.CustomerContact AS contact
                      WHERE contact.OrganizationId = customer.OrganizationId AND contact.CustomerId = customer.CustomerId)
    ORDER BY customer.CustomerId;");
  Assert(target is not null, "Za dokaz kontaktov je potrebna vsaj ena stranka brez rocnega prepisa.");
  var (organizationId, customerId) = target!.Value;

  try
  {
    // 1. Kartica vrne osem naborov in osmi je kontaktni.
    await using (var command = new SqlCommand("intranet.GetCustomerCard", connection) { CommandType = CommandType.StoredProcedure })
    {
      command.Parameters.AddWithValue("@OrganizationId", organizationId);
      command.Parameters.AddWithValue("@CustomerId", customerId);
      await using var reader = await command.ExecuteReaderAsync();
      var sets = 1;
      while (await reader.NextResultAsync()) sets++;
      Assert(sets == 8, $"intranet.GetCustomerCard mora vrniti osem naborov, vrnila jih je {sets}.");
    }

    var before = await ContactAsync(connection, organizationId, customerId);
    Assert(before.EmailSource is null, "Stranka brez prepisa in brez izvora ne sme imeti oznacenega izvora.");
    Assert(!before.SourceAvailable && before.SourceNote is not null,
      "Kadar zajema kontaktov ni, mora bralni model povedati, kaj natanko manjka.");

    // 2. Rocni vnos obvelja in je oznacen kot rocni.
    await SaveContactAsync(connection, organizationId, customerId, "test.f10@primer.si", "01 234 5678", null, "Ana Test | Bojan Test");
    var saved = await ContactAsync(connection, organizationId, customerId);
    Assert(saved.Email == "test.f10@primer.si" && saved.EmailSource == "PIM", "Rocna e-posta mora obveljati z znacko PIM.");
    Assert(saved.Persons == "Ana Test | Bojan Test", "Vec oseb gre v eno celico, loceno z ' | '.");
    Assert(saved.MobileSource is null, "Polje brez vrednosti nima izvora.");

    // 3. Umik rocnega prepisa pusti vrstico in revizijsko sled, ne pobrise podatka.
    await SaveContactAsync(connection, organizationId, customerId, null, null, null, null);
    var cleared = await ContactAsync(connection, organizationId, customerId);
    Assert(cleared.Email is null && cleared.EmailSource is null, "Po umiku prepisa velja vrednost izvora, danes torej nobena.");
    Assert(cleared.UpdatedBy is not null, "Vrstica mora ostati, da se vidi, kdo je prepis umaknil.");

    var auditCount = await CountAsync(connection,
      "SELECT COUNT(*) FROM b2b.AuditLog WHERE EntityType = N'CustomerContact' AND EntityKey = @key AND ChangedBy = N'test-f10';",
      customerId);
    Assert(auditCount == 2, $"Vsako shranjevanje kontaktov mora pustiti sled; sledi je {auditCount}, pricakovani sta 2.");
  }
  finally
  {
    // Pospravljanje: samo vrstice, ki jih je ustvaril ta test (AGENTS.md §4.1).
    await ExecuteAsync(connection,
      "DELETE FROM b2b.AuditLog WHERE EntityType = N'CustomerContact' AND EntityKey = @key AND ChangedBy = N'test-f10';", customerId);
    await ExecuteAsync(connection,
      "DELETE FROM pim.CustomerContact WHERE CustomerId = @key AND UpdatedBy = N'test-f10';", customerId);
  }
}

if (!string.IsNullOrWhiteSpace(connectionString))
{
  await WorkbookRoundTripAsync(connectionString);
  await GroupDiscountRuleAsync(connectionString);
}

Console.WriteLine("F10 customers UX contract PASS.");

// H11 nad razvojno bazo: izvoz -> uvoz brez sprememb ne spremeni nicesar; uvoz popustov se pokaze
// v stranke.csv in katalog.csv; povratni uvoz z »-« vrne stranko v prvotno stanje. Test pise samo
// stranki, ki jo izbere sam, in za sabo pobrise vse, kar je ustvaril (AGENTS.md §4.1).
static async Task WorkbookRoundTripAsync(string connectionString)
{
  const string Actor = "test-f10-stranke";
  const int Organization = 2; // IQLighting: podjetje spletnega kataloga, iz katerega se gradita stranke.csv in katalog.csv
  var configuration = new Microsoft.Extensions.Configuration.ConfigurationBuilder()
    .AddInMemoryCollection(new Dictionary<string, string?> { ["ConnectionStrings:Pim"] = connectionString })
    .Build();
  var list = new PIM.Intranet.Services.CustomerListService(configuration);
  var workbook = new PIM.Intranet.Services.CustomerWorkbookService(configuration, list);

  await using var connection = new SqlConnection(connectionString);
  await connection.OpenAsync();

  var target = (await list.GetAsync(Organization)).FirstOrDefault(row => row.InCustomerExport && row.ManualKind is null
    && row.CustomerTypeCode is null && !row.PackagingDiscountEnabled && !row.ValueDiscountEnabled && !row.B2bPlusEnabled
    && row.B2bPlusValidFrom is null && row.B2bPlusValidTo is null && !row.HasOwnTiers && row.GroupDiscounts is null
    && row.SpecialDiscounts is null && row.Email is null && row.Phone is null && row.Mobile is null && row.Persons is null);
  Assert(target is not null, "Za krog delovnega lista je potrebna stranka IQLighting brez rocnih nastavitev.");
  var customer = target!;

  // Izdelek, ki je res v katalog.csv (od 251 samo objavljeni), z znano skupino artiklov: nanj gre
  // posebni S, na njegovo skupino skupinski popust.
  var (item, itemGroup) = await CatalogItemAsync(connection, Organization);

  var tierRowsBefore = await CountAsync(connection, "SELECT COUNT(*) FROM pim.CustomerValueDiscountTier WHERE CustomerId = @key;", customer.CustomerId);
  var contactBefore = await CountAsync(connection, "SELECT COUNT(*) FROM pim.CustomerContact WHERE CustomerId = @key;", customer.CustomerId);
  var groupMax = await CountAsync(connection, "SELECT ISNULL(MAX(OverrideId), 0) FROM b2b.GroupDiscountOverride WHERE @key = @key;", customer.CustomerId);
  var specialMax = await CountAsync(connection, "SELECT ISNULL(MAX(OverrideId), 0) FROM b2b.CustomerPackagingDiscountOverride WHERE @key = @key;", customer.CustomerId);

  var beforeRow = await ExportRowAsync(connection, Organization, "MAGENTO_CUSTOMERS", customer.CustomerKey, true, "Customer.Key");
  Assert(beforeRow is not null, "Izbrana stranka mora biti v stranke.csv.");

  try
  {
    // 1. Izvoz in takojsnji uvoz iste datoteke: nic za spremeniti.
    var exported = PIM.Intranet.Services.CustomerWorkbookService.Build([customer]);
    var clean = await workbook.PreviewAsync(new MemoryStream(exported), null);
    Assert(clean.RowsRead == 1 && clean.Rows.Count == 0 && clean.Problems.Count == 0,
      $"Izvoz, vrnjen brez sprememb, ne sme nicesar spremeniti (sprememb {clean.ChangeCount}, napak {clean.Problems.Count}: {string.Join("; ", clean.Problems)}).");
    Assert(clean.UnknownColumns.Count == 0, "Uvoz mora prepoznati vse stolpce izvoza: " + string.Join(", ", clean.UnknownColumns));

    // 2. Urejena datoteka: vrsta, tip po imenu, zastavice, B2B+ okno, prag, skupinski popust, posebni S, e-posta.
    var today = DateTime.Today;
    var email = "test.f10.stranke@primer.si";
    var edited = Sheet(customer,
      ("Vrsta (ročno)", "Dobavitelj"), ("Tip stranke", "INŠTALATER"), ("Popust polno pakiranje", "D"), ("Vrednostni rabat", "da"),
      ("B2B+", "D"), ("B2B+ velja od", today.AddDays(-1)), ("B2B+ velja do", today.AddDays(30).ToString("d.M.yyyy")),
      ("Prag 1 (€ brez DDV)", 900m), ("Rabat 1 (%)", "2,5"),
      ("Skupinski popusti stranke", itemGroup.ToLowerInvariant() + "=7"), ("Posebni S po izdelku (katalog.csv)", item + "\\s3"),
      ("E-pošta", email));
    var preview = await workbook.PreviewAsync(new MemoryStream(edited), null);
    Assert(preview.Problems.Count == 0, "Urejena datoteka ne sme imeti napak: " + string.Join("; ", preview.Problems));
    Assert(preview.Rows.Count == 1 && preview.ChangeCount == 11,
      $"Urejena datoteka mora prinesti 11 sprememb ene stranke, prinesla jih je {preview.ChangeCount}: "
      + string.Join("; ", preview.Rows.SelectMany(row => row.Changes).Select(change => change.Label)));
    var outcome = await workbook.ApplyAsync(preview, Actor);
    Assert(outcome.Problems.Count == 0, "Uvoz ne sme javiti napake: " + string.Join("; ", outcome.Problems));
    Assert(outcome.CustomersTouched == 1 && outcome.ValuesWritten == 5 && outcome.CustomerExportRows == 1 && outcome.CatalogProducts == 1,
      $"Uvoz mora zapisati profil, prag, skupino, posebni S in kontakt (5), zapisal je {outcome.ValuesWritten}.");

    // 3. Seznam: rocna vrsta prevlada nad izracunom, vse vrednosti so zapisane.
    var after = (await list.GetAsync(Organization)).Single(row => row.CustomerId == customer.CustomerId);
    Assert(after.ManualKind == "SUPPLIER" && after.IsSupplier && !after.IsBuyer && after.RoleSource == "MANUAL",
      "Rocna vrsta Dobavitelj mora prevladati nad izracunano vlogo.");
    Assert(after.CustomerTypeCode == "INSTALLER" && after.PackagingDiscountEnabled && after.ValueDiscountEnabled && after.B2bPlusEnabled,
      "Tip stranke in zastavice morajo biti zapisani (tip po imenu INSTALATER -> INSTALLER).");
    Assert(after.Tier1Threshold == 900m && after.Tier1Percent == 2.5m, "Lastni prag 1 mora biti 900 € -> 2,5 %.");
    Assert(after.GroupDiscounts == itemGroup + "=7", $"Skupinski popust mora biti zapisan s kodo, kot jo nosi izdelek ({itemGroup}=7), je {after.GroupDiscounts}.");
    Assert(string.Equals(after.SpecialDiscounts, item + "\\S3", StringComparison.Ordinal), $"Posebni S mora biti {item}\\S3, je {after.SpecialDiscounts}.");
    Assert(after.Email == email, "E-posta mora biti zapisana kot rocni kontakt.");

    // 4. stranke.csv (out.GetExportRows, profil MAGENTO_CUSTOMERS) nosi vse, kar je uvoz zapisal.
    var customerRow = await ExportRowAsync(connection, Organization, "MAGENTO_CUSTOMERS", customer.CustomerKey, true, "Customer.Key");
    Assert(customerRow is not null, "Stranka mora biti v stranke.csv.");
    Assert(customerRow!["Customer.PackagingDiscountEnabled"] == "1" && customerRow["Customer.ValueDiscountEnabled"] == "1"
      && customerRow["Customer.B2bPlus"] == "1", "stranke.csv mora imeti pakiranje, vrednostni rabat in B2B+ = 1.");
    Assert(customerRow["Customer.Tier1Threshold"] == "900" && customerRow["Customer.Tier1Percent"] == "2.5",
      $"stranke.csv mora imeti lastni prag 900 / 2.5, ima {customerRow["Customer.Tier1Threshold"]} / {customerRow["Customer.Tier1Percent"]}.");
    Assert((customerRow["Customer.GroupDiscounts"] ?? "").Split(" | ").Contains(itemGroup + "=7%"),
      $"stranke.csv mora imeti skupinski popust {itemGroup}=7%, ima {customerRow["Customer.GroupDiscounts"]}.");
    // 253: seznam strank in stranke.csv bereta isto pravilo - niz je znak za znakom enak.
    Assert(customerRow["Customer.GroupDiscounts"] == after.ExportGroupDiscounts,
      $"Skupine popustov na seznamu ({after.ExportGroupDiscounts}) in v stranke.csv ({customerRow["Customer.GroupDiscounts"]}) se morata ujemati.");
    Assert(customerRow["Customer.Email"] == email, "stranke.csv mora imeti e-posto iz uvoza.");
    Console.WriteLine("stranke.csv po uvozu: " + string.Join("; ", customerRow.Select(pair => pair.Key + "=" + pair.Value)));

    // 5. katalog.csv (profil MAGENTO_PRODUCTS): stolpec »Posebni popust za stranko« izdelka.
    var productRow = await ExportRowAsync(connection, Organization, "MAGENTO_PRODUCTS", item, true, "Product.ItemID");
    Assert(productRow is not null, "Izdelek mora biti v katalog.csv.");
    Assert((productRow!["Product.SpecialCustomerDiscounts"] ?? "").Split(" | ").Contains(customer.CustomerKey + "\\S3"),
      $"katalog.csv mora imeti {customer.CustomerKey}\\S3 pri izdelku {item}, ima »{productRow["Product.SpecialCustomerDiscounts"]}«.");
    Console.WriteLine($"katalog.csv po uvozu, izdelek {item}: Posebni popust za stranko = {productRow["Product.SpecialCustomerDiscounts"]}");

    // 6. Povratni uvoz z »-« in N vrne stranko v prvotno stanje, tudi v stranke.csv in katalog.csv.
    var revert = Sheet(customer,
      ("Vrsta (ročno)", "-"), ("Tip stranke", "-"), ("Popust polno pakiranje", "N"), ("Vrednostni rabat", "N"), ("B2B+", "N"),
      ("B2B+ velja od", "-"), ("B2B+ velja do", "-"), ("Prag 1 (€ brez DDV)", "-"), ("Skupinski popusti stranke", "-"),
      ("Posebni S po izdelku (katalog.csv)", "-"), ("E-pošta", "-"));
    var revertOutcome = await workbook.ApplyAsync(await workbook.PreviewAsync(new MemoryStream(revert), null), Actor);
    Assert(revertOutcome.Problems.Count == 0, "Povratni uvoz ne sme javiti napake: " + string.Join("; ", revertOutcome.Problems));
    var restored = (await list.GetAsync(Organization)).Single(row => row.CustomerId == customer.CustomerId);
    Assert(restored == customer, "Povratni uvoz mora stranko vrniti v prvotno stanje.");
    var restoredRow = await ExportRowAsync(connection, Organization, "MAGENTO_CUSTOMERS", customer.CustomerKey, true, "Customer.Key");
    Assert(restoredRow!["Customer.PackagingDiscountEnabled"] == "0" && restoredRow["Customer.GroupDiscounts"] == beforeRow!["Customer.GroupDiscounts"]
      && restoredRow["Customer.Email"] is null, "Po povratnem uvozu stranke.csv ne sme vec nositi testnih vrednosti.");
    var restoredProduct = await ExportRowAsync(connection, Organization, "MAGENTO_PRODUCTS", item, true, "Product.ItemID");
    Assert(!(restoredProduct!["Product.SpecialCustomerDiscounts"] ?? "").Contains(customer.CustomerKey + "\\", StringComparison.Ordinal),
      "Po povratnem uvozu katalog.csv ne sme vec nositi testnega posebnega S.");
    Console.WriteLine($"Krog delovnega lista strank: {customer.OrganizationName} {customer.CustomerKey}, izdelek {item} ({itemGroup}) — PASS.");
  }
  finally
  {
    // Pospravljanje: samo vrstice, ki jih je ustvaril ta test. Profil se vrne na prvotne vrednosti
    // tudi, kadar je test padel sredi kroga (povratni uvoz se takrat ni zgodil).
    await using (var restore = new SqlCommand("""
      UPDATE pim.CustomerWebProfile
      SET CustomerTypeCode = @Type, CustomerKind = @Kind, PackagingDiscountEnabled = @Packaging, ValueDiscountEnabled = @Value,
        B2bPlusEnabled = @Plus, B2bPlusValidFrom = @From, B2bPlusValidTo = @To, WebEnabled = @Web
      WHERE CustomerId = @Customer;
      """, connection))
    {
      restore.Parameters.AddWithValue("@Customer", customer.CustomerId);
      restore.Parameters.AddWithValue("@Type", (object?)customer.CustomerTypeCode ?? DBNull.Value);
      restore.Parameters.AddWithValue("@Kind", (object?)customer.ManualKind ?? DBNull.Value);
      restore.Parameters.AddWithValue("@Packaging", customer.PackagingDiscountEnabled);
      restore.Parameters.AddWithValue("@Value", customer.ValueDiscountEnabled);
      restore.Parameters.AddWithValue("@Plus", customer.B2bPlusEnabled);
      restore.Parameters.AddWithValue("@From", (object?)customer.B2bPlusValidFrom ?? DBNull.Value);
      restore.Parameters.AddWithValue("@To", (object?)customer.B2bPlusValidTo ?? DBNull.Value);
      restore.Parameters.AddWithValue("@Web", customer.WebEnabled);
      await restore.ExecuteNonQueryAsync();
    }
    await ExecuteAsync(connection, $"DELETE FROM b2b.GroupDiscountOverride WHERE CustomerId = @key AND OverrideId > {groupMax};", customer.CustomerId);
    await ExecuteAsync(connection, $"DELETE FROM b2b.CustomerPackagingDiscountOverride WHERE CustomerId = @key AND OverrideId > {specialMax};", customer.CustomerId);
    if (tierRowsBefore == 0) await ExecuteAsync(connection, "DELETE FROM pim.CustomerValueDiscountTier WHERE CustomerId = @key;", customer.CustomerId);
    if (contactBefore == 0) await ExecuteAsync(connection, "DELETE FROM pim.CustomerContact WHERE CustomerId = @key;", customer.CustomerId);
    await ExecuteAsync(connection, $"DELETE FROM b2b.AuditLog WHERE ChangedBy = N'{Actor}' AND @key = @key;", customer.CustomerId);
  }
}

// 253 nad razvojno bazo (samo branje): skupine popustov po pravilu PE/tranzit, enake na seznamu in v stranke.csv.
static async Task GroupDiscountRuleAsync(string connectionString)
{
  const int Organization = 3; // Vidadria: tu so tipi strank (212/252) in SAOP rabatni ceniki
  var configuration = new Microsoft.Extensions.Configuration.ConfigurationBuilder()
    .AddInMemoryCollection(new Dictionary<string, string?> { ["ConnectionStrings:Pim"] = connectionString })
    .Build();
  var rows = await new PIM.Intranet.Services.CustomerListService(configuration).GetAsync(Organization);
  await using var connection = new SqlConnection(connectionString);
  await connection.OpenAsync();

  // Poslovna enota brez svojega rabatnega cenika podeduje popuste od placnika (dokument §4.10).
  var branch = rows.FirstOrDefault(row => row.PayerKind == "PE" && row.DiscountPriceListCode is null
    && row.ExportGroupDiscounts is not null && row.InCustomerExport);
  Assert(branch is not null, "Vsaj ena poslovna enota brez lastnega cenika mora podedovati skupine popustov od placnika.");
  var branchRow = await ExportRowAsync(connection, Organization, "MAGENTO_CUSTOMERS", branch!.CustomerKey, true, "Customer.Key");
  Assert(branchRow is not null && branchRow["Customer.GroupDiscounts"] == branch.ExportGroupDiscounts,
    $"stranke.csv mora za poslovno enoto {branch.CustomerKey} imeti iste skupine popustov kot seznam.");

  // Tranzit brez rocnih popustov nima skupin popustov, ceprav jih ima njegov placnik.
  var transitWithGroups = rows.Count(row => row.PayerKind == "TRANZIT" && row.GroupDiscounts is null && row.ExportGroupDiscounts is not null);
  Assert(transitWithGroups == 0, $"Tranzit ne sme imeti skupin popustov iz SAOP; ima jih {transitWithGroups} strank.");

  // Navadna stranka z lastnim rabatnim cenikom: SAOP popusti gredo v stranke.csv.
  var own = rows.FirstOrDefault(row => row.PayerKind is null && row.ExportGroupDiscounts is not null && row.InCustomerExport);
  Assert(own is not null, "Vsaj ena navadna stranka mora imeti skupine popustov iz svojega rabatnega cenika.");
  var ownRow = await ExportRowAsync(connection, Organization, "MAGENTO_CUSTOMERS", own!.CustomerKey, true, "Customer.Key");
  Assert(ownRow is not null && ownRow["Customer.GroupDiscounts"] == own.ExportGroupDiscounts,
    $"stranke.csv mora za stranko {own.CustomerKey} imeti iste skupine popustov kot seznam.");
  Console.WriteLine($"Skupine popustov (253): PE {branch.CustomerKey} = {branch.ExportGroupDiscounts?[..Math.Min(60, branch.ExportGroupDiscounts.Length)]} …; tranzit brez SAOP; {own.CustomerKey} iz lastnega cenika — PASS.");
}

// Prvi izdelek iz katalog.csv podjetja, ki ima skupino artiklov in kratko sifro (b2b procedura sprejme 50 znakov).
static async Task<(string Item, string Group)> CatalogItemAsync(SqlConnection connection, int organizationId)
{
  var profileId = 0;
  await using (var command = new SqlCommand("SELECT ExportProfileId FROM out.ExportProfile WHERE ProfileCode = N'MAGENTO_PRODUCTS';", connection))
    profileId = Convert.ToInt32(await command.ExecuteScalarAsync());
  var header = "";
  await using (var command = new SqlCommand("SELECT OutputColumnName FROM out.ExportColumn WHERE ExportProfileId = @Profile AND CanonicalFieldCode = N'Product.ItemID' AND IsActive = 1;", connection))
  {
    command.Parameters.AddWithValue("@Profile", profileId);
    header = Convert.ToString(await command.ExecuteScalarAsync())!;
  }
  var items = new List<string>();
  await using (var export = new SqlCommand("out.GetExportRows", connection) { CommandType = CommandType.StoredProcedure, CommandTimeout = 300 })
  {
    export.Parameters.AddWithValue("@OrganizationId", organizationId);
    export.Parameters.AddWithValue("@ExportProfileId", profileId);
    export.Parameters.AddWithValue("@OnlyPublished", true);
    export.Parameters.AddWithValue("@Skip", 0);
    export.Parameters.AddWithValue("@Take", 200);
    export.Parameters.Add("@TotalCount", SqlDbType.Int).Direction = ParameterDirection.Output;
    await using var rows = await export.ExecuteReaderAsync();
    var ordinal = rows.GetOrdinal(header);
    while (await rows.ReadAsync())
      if (!rows.IsDBNull(ordinal)) items.Add(rows.GetString(ordinal));
  }
  foreach (var item in items.Where(item => item.Length <= 50))
  {
    await using var command = new SqlCommand("""
      SELECT canonProduct.ItemGroup FROM canon.Product AS canonProduct
      INNER JOIN pim.Product AS pimProduct ON pimProduct.OrganizationId = canonProduct.OrganizationId AND pimProduct.ItemID = canonProduct.ItemID
      WHERE canonProduct.OrganizationId = @Organization AND canonProduct.ItemID = @Item AND canonProduct.ItemGroup IS NOT NULL;
      """, connection);
    command.Parameters.AddWithValue("@Organization", organizationId);
    command.Parameters.AddWithValue("@Item", item);
    if (await command.ExecuteScalarAsync() is string group) return (item, group);
  }
  throw new InvalidOperationException("V katalog.csv ni izdelka s skupino artiklov za krog delovnega lista.");
}

// Delovni list z eno vrstico: kljuc stranke in dana polja; naslovi so isti kot v izvozu.
static byte[] Sheet(PIM.Intranet.Services.CustomerListRow customer, params (string Header, object? Value)[] cells)
{
  var columns = new List<PIM.Operations.WorkbookColumn> { new("Podjetje"), new("Šifra stranke") };
  var values = new List<object?> { customer.OrganizationName, customer.CustomerKey };
  foreach (var (header, value) in cells)
  {
    columns.Add(new(header, value is DateTime ? PIM.Operations.WorkbookCellKind.DateTime : PIM.Operations.WorkbookCellKind.Text));
    values.Add(value);
  }
  return PIM.Operations.WorkbookWriter.Write("Stranke", columns, [values]);
}

// Ena vrstica izvoza po kanonicnih poljih — natanko to, kar gre v stranke.csv / katalog.csv.
static async Task<Dictionary<string, string?>?> ExportRowAsync(SqlConnection connection, int organizationId, string profileCode,
  string search, bool onlyPublished, string keyField)
{
  var headers = new Dictionary<string, string>(StringComparer.Ordinal);
  var profileId = 0;
  await using (var command = new SqlCommand("""
    SELECT profile.ExportProfileId, exportColumn.OutputColumnName, exportColumn.CanonicalFieldCode
    FROM out.ExportProfile AS profile
    INNER JOIN out.ExportColumn AS exportColumn ON exportColumn.ExportProfileId = profile.ExportProfileId AND exportColumn.IsActive = 1
    WHERE profile.ProfileCode = @Profile AND exportColumn.CanonicalFieldCode IS NOT NULL;
    """, connection))
  {
    command.Parameters.AddWithValue("@Profile", profileCode);
    await using var reader = await command.ExecuteReaderAsync();
    while (await reader.ReadAsync())
    {
      profileId = reader.GetInt32(0);
      headers[reader.GetString(1)] = reader.GetString(2);
    }
  }

  await using var export = new SqlCommand("out.GetExportRows", connection) { CommandType = CommandType.StoredProcedure, CommandTimeout = 300 };
  export.Parameters.AddWithValue("@OrganizationId", organizationId);
  export.Parameters.AddWithValue("@ExportProfileId", profileId);
  export.Parameters.AddWithValue("@OnlyPublished", onlyPublished);
  export.Parameters.AddWithValue("@Search", search);
  export.Parameters.AddWithValue("@Skip", 0);
  export.Parameters.AddWithValue("@Take", 50);
  export.Parameters.Add("@TotalCount", SqlDbType.Int).Direction = ParameterDirection.Output;
  await using var rows = await export.ExecuteReaderAsync();
  while (await rows.ReadAsync())
  {
    var values = new Dictionary<string, string?>(StringComparer.Ordinal);
    for (var index = 0; index < rows.FieldCount; index++)
      if (headers.TryGetValue(rows.GetName(index), out var field))
        values[field] = rows.IsDBNull(index) ? null : Convert.ToString(rows.GetValue(index), System.Globalization.CultureInfo.InvariantCulture);
    if (values.TryGetValue(keyField, out var key) && string.Equals(key, search, StringComparison.Ordinal)) return values;
  }
  return null;
}


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

static async Task<(int OrganizationId, long CustomerId)?> ScalarPairAsync(SqlConnection connection, string sql)
{
  await using var command = new SqlCommand(sql, connection);
  await using var reader = await command.ExecuteReaderAsync();
  if (!await reader.ReadAsync()) return null;
  return (reader.GetInt32(0), reader.GetInt64(1));
}

static async Task<ContactRow> ContactAsync(SqlConnection connection, int organizationId, long customerId)
{
  await using var command = new SqlCommand("intranet.GetCustomerCard", connection) { CommandType = CommandType.StoredProcedure };
  command.Parameters.AddWithValue("@OrganizationId", organizationId);
  command.Parameters.AddWithValue("@CustomerId", customerId);
  await using var reader = await command.ExecuteReaderAsync();
  for (var skipped = 0; skipped < 7; skipped++)
    if (!await reader.NextResultAsync()) throw new InvalidOperationException("Kartica nima osmega nabora.");
  if (!await reader.ReadAsync()) throw new InvalidOperationException("Nabor s kontakti mora vrniti natanko eno vrstico.");
  return new ContactRow(
    Text(reader, "Email"), Text(reader, "Persons"), Text(reader, "EmailSource"), Text(reader, "MobileSource"),
    reader.GetBoolean(reader.GetOrdinal("SourceAvailable")), Text(reader, "SourceNote"), Text(reader, "UpdatedBy"));

  static string? Text(SqlDataReader reader, string name)
  {
    var ordinal = reader.GetOrdinal(name);
    return reader.IsDBNull(ordinal) ? null : reader.GetString(ordinal);
  }
}

static async Task SaveContactAsync(SqlConnection connection, int organizationId, long customerId,
  string? email, string? phone, string? mobile, string? persons)
{
  await using var command = new SqlCommand("b2b.SaveCustomerContact", connection) { CommandType = CommandType.StoredProcedure };
  command.Parameters.AddWithValue("@OrganizationId", organizationId);
  command.Parameters.AddWithValue("@CustomerId", customerId);
  command.Parameters.AddWithValue("@Email", (object?)email ?? DBNull.Value);
  command.Parameters.AddWithValue("@Phone", (object?)phone ?? DBNull.Value);
  command.Parameters.AddWithValue("@Mobile", (object?)mobile ?? DBNull.Value);
  command.Parameters.AddWithValue("@Persons", (object?)persons ?? DBNull.Value);
  command.Parameters.AddWithValue("@ChangedBy", "test-f10");
  await command.ExecuteNonQueryAsync();
}

static async Task<int> CountAsync(SqlConnection connection, string sql, long key)
{
  await using var command = new SqlCommand(sql, connection);
  command.Parameters.AddWithValue("@key", key.ToString());
  return Convert.ToInt32(await command.ExecuteScalarAsync());
}

static async Task ExecuteAsync(SqlConnection connection, string sql, long key)
{
  await using var command = new SqlCommand(sql, connection);
  command.Parameters.AddWithValue("@key", key.ToString());
  await command.ExecuteNonQueryAsync();
}

internal sealed record ContactRow(
  string? Email, string? Persons, string? EmailSource, string? MobileSource,
  bool SourceAvailable, string? SourceNote, string? UpdatedBy);
