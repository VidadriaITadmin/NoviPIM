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
