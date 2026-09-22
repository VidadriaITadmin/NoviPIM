using System.Security.Claims;
using System.Text.RegularExpressions;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using PIM.Intranet.Components.Pages.ProductCardParts;
using PIM.Intranet.Services;

var root = FindRoot();
var pagesDirectory = Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages");
var migration = Path.Combine(root, "sql", "migrations", "026_AddIntranetUserAdministration.sql");
var auth = Path.Combine(root, "src", "PIM.Intranet", "Services", "LocalUserAuthenticationService.cs");
var activeDirectory = Path.Combine(root, "src", "PIM.Intranet", "Services", "ActiveDirectoryService.cs");
var administration = Path.Combine(root, "src", "PIM.Intranet", "Services", "IntranetUserAdministrationService.cs");
var usersPage = Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", "SystemUsers.razor");
var provisioner = Path.Combine(root, "tools", "PIM.UserProvisioning", "Program.cs");
var migrator = Path.Combine(root, "src", "PIM.Migrator", "Program.cs");
var intranetProgram = Path.Combine(root, "src", "PIM.Intranet", "Program.cs");
var loginPage = Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", "Login.razor");
var intranetData = Path.Combine(root, "src", "PIM.Intranet", "Services", "IntranetDataService.cs");
var saopWrite = Path.Combine(root, "src", "PIM.Intranet", "Services", "SaopWriteService.cs");

foreach (var path in new[] { migration, auth, activeDirectory, administration, usersPage, provisioner })
  Assert(File.Exists(path), "Manjka zahtevan artefakt: " + path);

var migrationText = File.ReadAllText(migration);
foreach (var value in new[] { "AuthSource", "DomainIdentity", "sec.CreateLocalUser", "sec.CreateDomainUser", "ADMIN", "USERS" })
  Assert(migrationText.Contains(value, StringComparison.Ordinal), "Migracija ne vsebuje: " + value);
Assert(!migrationText.Contains("Password =", StringComparison.OrdinalIgnoreCase), "Migracija ne sme vsebovati privzetega gesla.");

var authText = File.ReadAllText(auth);
foreach (var value in new[] { "AuthSource", "DOMAIN", "ActiveDirectoryService" })
  Assert(authText.Contains(value, StringComparison.Ordinal), "Avtentikacija ne podpira: " + value);

var page = File.ReadAllText(usersPage);
foreach (var value in new[] { "@page \"/administracija\"", "Authorize(Roles = \"ADMIN\")", "Najdi v AD", "Dodaj domenskega uporabnika" })
  Assert(page.Contains(value, StringComparison.Ordinal), "Administratorska stran ne vsebuje: " + value);

var provisioningText = File.ReadAllText(provisioner);
foreach (var value in new[] { "ReadPassword", "sec.CreateLocalUser", "PasswordHasher.Hash" })
  Assert(provisioningText.Contains(value, StringComparison.Ordinal), "Provisioning ne vsebuje: " + value);
Assert(!provisioningText.Contains("david", StringComparison.OrdinalIgnoreCase), "Provisioning ne sme vsebovati gesla.");

var migratorText = File.ReadAllText(migrator);
foreach (var value in new[] { "VerifyF10Async", "sec.CreateLocalUser", "sec.CreateDomainUser", "DomainIdentity" })
  Assert(migratorText.Contains(value, StringComparison.Ordinal), "Migrator ne preverja F10 zahteve: " + value);

var programText = File.ReadAllText(intranetProgram);
var loginText = File.ReadAllText(loginPage);
Assert(programText.Contains("UseStaticWebAssets()", StringComparison.Ordinal), "Intranet mora v produkciji streči generiran CSS paket Razor komponent.");
Assert(programText.Contains("LocalSettings.Sources(builder.Environment.ContentRootPath)", StringComparison.Ordinal), "Lokalne nastavitve mora najti skupni iskalnik rešitve (mapa ob .exe + koren rešitve), ne fiksna relativna pot.");
Assert(!programText.Contains("\"..\", \"..\", \"..\"", StringComparison.Ordinal), "Pot do korenske nastavitve ne sme biti krhka fiksna relativna pot treh nivojev navzgor.");
Assert(programText.Contains("MapPost(\"/auth/prijava\"", StringComparison.Ordinal), "Prijavna POST pot mora biti ločena od Razor poti /prijava.");
Assert(loginText.Contains("action=\"auth/prijava\"", StringComparison.Ordinal), "Prijavni obrazec mora oddati na base-path relativno auth pot.");
Assert(loginText.Contains("name=\"zapomniMe\"", StringComparison.Ordinal), "Prijavni obrazec mora ponuditi funkcionalno izbiro za zapomnitev seje.");
Assert(!programText.Contains("MapPost(\"/prijava\"", StringComparison.Ordinal), "POST /prijava se ne sme podvajati z Razor komponento.");
var loginPostEnd = programText.IndexOf("app.MapPost(\"/odjava\"", StringComparison.Ordinal);
var loginPost = programText[..loginPostEnd];
Assert(loginPost.Contains("AllowAnonymous()", StringComparison.Ordinal), "Prijavna POST pot mora biti dostopna brez obstoječe seje.");
Assert(loginPost.Contains("ValidateRequestAsync", StringComparison.Ordinal), "Prijavna POST pot mora validirati antiforgery token.");
Assert(loginPost.Contains("IsPersistent", StringComparison.Ordinal), "Prijavna POST pot mora upoštevati zapomnitev seje.");

var intranetDataText = File.ReadAllText(intranetData);
var mainLayoutText = File.ReadAllText(Path.Combine(root, "src", "PIM.Intranet", "Components", "Layout", "MainLayout.razor"));
var mainLayoutCss = File.ReadAllText(Path.Combine(root, "src", "PIM.Intranet", "Components", "Layout", "MainLayout.razor.css"));
Assert(!mainLayoutText.Contains("☰", StringComparison.Ordinal), "Glavna navigacija ne sme uporabljati Unicode ikone menija.");
Assert(mainLayoutText.Contains("menu-glyph-icon", StringComparison.Ordinal) && mainLayoutCss.Contains(".menu-glyph-icon", StringComparison.Ordinal), "Glavna navigacija mora uporabljati nadzorovano CSS ikono menija.");
foreach (var column in new[] { "CanonProductCount", "PimProductCount", "ErpValidCount", "WebInvalidCount", "QuarantineCount", "PositionId", "FreshnessMinutes", "MatchedProductId" })
  Assert(intranetDataText.Contains($"reader.GetOrdinal(\"{column}\")", StringComparison.Ordinal), "Preslikava mora uporabljati ime stolpca: " + column);
foreach (var column in new[] { "NormalizedItemId", "Ean", "ProviderKind" })
  Assert(intranetDataText.Contains($"GetNullableString(reader, \"{column}\")", StringComparison.Ordinal), "Nullable preslikava mora uporabljati ime stolpca: " + column);
Assert(intranetDataText.Contains("Convert.ToInt64(reader.GetValue(reader.GetOrdinal(\"CanonProductCount\")))", StringComparison.Ordinal), "Nadzorna plošča mora imenovano SQL COUNT vrednost varno pretvoriti v long.");
Assert(intranetDataText.Contains("GetCurrentOrganizationAsync", StringComparison.Ordinal), "UX mora organizacijo prebrati iz baze.");
Assert(intranetDataText.Contains("reader.GetOrdinal(\"ProductId\")", StringComparison.Ordinal), "Poslovni rezultati se morajo preslikati po imenih stolpcev.");
Assert(intranetDataText.Contains("string.Join(\", \", parameterNames)", StringComparison.Ordinal), "Navigacija mora podpirati poljubno število parametriziranih vlog.");
Assert(!intranetDataText.Contains("IN (@Role0, @Role1, @Role2)", StringComparison.Ordinal), "Navigacija ne sme biti omejena na tri vloge.");
var uxMigration = File.ReadAllText(Path.Combine(root, "sql", "migrations", "027_HardenIntranetQualityReadModels.sql"));
foreach (var value in new[] { "TotalCount", "@Search", "@Status", "AverageCompleteness", "OccurrenceCount", "FirstDetectedUtc" })
  Assert(uxMigration.Contains(value, StringComparison.Ordinal), "UX read-model migracija ne vsebuje: " + value);
Assert(!File.ReadAllText(Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", "ValidationErrors.razor")).Contains(">Napaka</span>", StringComparison.Ordinal), "UI ne sme izmišljati resnosti validacijske težave.");
// Zahteva je bila vedno: organizacija pride iz baze in ni vpisana v stran. Bralni poti sta
// dve — GetCurrentOrganizationAsync (ena organizacija) in GetOrganizationsAsync (vse) — in
// obe izpolnita zahtevo. Nadzorna plosca in zaloga sta 2026-08-28 oziroma 2026-08-31 presli
// na drugo, ker sta kazali samo prvo podjetje po sifri.
//
// Trditev je namenoma vezana na KLIC (Data.…), ne na golo besedo: prej je test zadoscala
// omemba imena v komentarju, zato je nadzorna plosca ostala zelena, ceprav klica ni imela vec.
foreach (var pageName in new[] { "Dashboard.razor", "Stocks.razor", "ValidationErrors.razor", "RawQuarantine.razor" })
{
  var pageText = File.ReadAllText(Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", pageName));
  Assert(pageText.Contains("Data.GetCurrentOrganizationAsync", StringComparison.Ordinal)
      || pageText.Contains("Data.GetOrganizationsAsync", StringComparison.Ordinal),
    pageName + " mora dobiti organizacijo iz baze, ne iz vpisane vrednosti.");
}

// Seznam izdelkov je vecorganizacijski: privzeto pokaze vsa podjetja, filter zozi na eno.
// Zahteva ostaja ista — organizacija pride iz baze in ni vpisana v stran — samo bralna pot
// je zdaj register vseh podjetij namesto prvega aktivnega.
var productsPage = File.ReadAllText(Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", "Products.razor"));
Assert(productsPage.Contains("GetOrganizationsAsync", StringComparison.Ordinal), "Products.razor mora podjetja prebrati iz baze.");
Assert(!productsPage.Contains("GetCurrentOrganizationAsync", StringComparison.Ordinal), "Products.razor ne sme biti omejen na prvo aktivno organizacijo.");
Assert(!System.Text.RegularExpressions.Regex.IsMatch(productsPage, "ProductListFilter\\(\\s*\\d"), "Products.razor ne sme uporabljati hardkodirane organizacije.");
var dashboardPage = File.ReadAllText(Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", "Dashboard.razor"));
Assert(dashboardPage.Contains("else if (Metrics is null)", StringComparison.Ordinal), "Nadzorna plošča ne sme hkrati prikazati napake in nalaganja.");
var stocksPage = File.ReadAllText(Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", "Stocks.razor"));
// Napis tabele je od prenove zaloge parameter skupnega gradnika PimTable; zahteva ostaja
// ista (tabela mora imeti napis), le zapisana je tam, kjer tabela zdaj nastane.
Assert(stocksPage.Contains("<caption>", StringComparison.Ordinal) || stocksPage.Contains("<PimTable Caption=\"", StringComparison.Ordinal),
  "Tabela zalog mora imeti programsko določen napis.");
var quarantinePage = File.ReadAllText(Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", "RawQuarantine.razor"));
Assert(quarantinePage.Contains("<h1>Karantena</h1>", StringComparison.Ordinal), "Vidni naslov karantene mora biti dosleden.");
// SystemIntegrations.razor (/sistem/integracije) je odstranjena v bloku 7 prenove nadzora (2026-09-22);
// alarme in izključitev podjetij zdaj kaže Nadzor, ki bere vsa podjetja, ne »aktivne organizacije«.
// PipelineRuns.razor je od pregleda 2026-09-22 samo preusmeritev na /zajem/teki.
foreach (var pageName in new[] { "Outbound.razor", "DiscountRules.razor" })
{
  var pageText = File.ReadAllText(Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", pageName));
  Assert(pageText.Contains("GetCurrentOrganizationAsync", StringComparison.Ordinal), pageName + " mora uporabljati aktivno organizacijo iz baze.");
  Assert(!pageText.Contains("Async(2,", StringComparison.Ordinal), pageName + " ne sme uporabljati hardkodirane organizacije 2.");
}
// Stranke kazejo vsa podjetja (250): »aktivna organizacija« je bila vedno prva (DEMO) in stranke
// drugih podjetij niso bile vidne. Seznam ima podjetje za filter, kartica vzame podjetje stranke.
foreach (var (pageName, organizationSource) in new[] { ("Customers.razor", "GetOrganizationsAsync"), ("CustomerDetail.razor", "GetCustomerOrganizationAsync") })
{
  var pageText = File.ReadAllText(Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", pageName));
  Assert(pageText.Contains(organizationSource, StringComparison.Ordinal), pageName + " mora podjetje vzeti iz " + organizationSource + ".");
  Assert(!pageText.Contains("GetCurrentOrganizationAsync", StringComparison.Ordinal), pageName + " ne sme biti zaklenjena na prvo aktivno podjetje.");
  Assert(!pageText.Contains("Async(2,", StringComparison.Ordinal), pageName + " ne sme uporabljati hardkodirane organizacije 2.");
}
foreach (var pageName in new[] { "Customers.razor", "Outbound.razor" })
{
  var pageText = File.ReadAllText(Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", pageName));
  // Isto pravilo kot spodaj: razred sme priti iz skupnega gradnika. <PimTable> izrise
  // data-table, <PimState> pa error-state. Zahteva je bila vedno "uporabi skupni PIM UX",
  // ne "prepisi razred na roko" — gradnik je celo bolj zanesljiv, ker je razred na enem mestu.
  Assert(pageText.Contains("data-table", StringComparison.Ordinal) || pageText.Contains("<PimTable", StringComparison.Ordinal),
    pageName + " mora uporabljati skupni tabelarični UX.");
  Assert(pageText.Contains("error-state", StringComparison.Ordinal) || pageText.Contains("<PimState", StringComparison.Ordinal),
    pageName + " mora imeti pošteno stanje napake.");
}
foreach (var pageName in new[] { "DiscountRules.razor", "CustomerDetail.razor", "SystemUsers.razor" })
{
  var pageText = File.ReadAllText(Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", pageName));
  // Razred sme priti tudi iz skupnega gradnika: <PimPage> izrise page-header, <PimTable> pa
  // data-table. Zahteva je bila vedno "uporabi PIM oblikovanje, ne Bootstrap", ne "prepisi
  // razred na roko" - gradnik je celo bolj zanesljiv, ker je razred zapisan na enem mestu.
  foreach (var (designClass, sharedComponent) in new[]
    { ("page-header", "<PimPage"), ("ui-card", (string?)null), ("data-table", "<PimTable") })
  {
    var present = pageText.Contains(designClass, StringComparison.Ordinal)
      || (sharedComponent is not null && pageText.Contains(sharedComponent, StringComparison.Ordinal));
    Assert(present, pageName + " mora uporabljati PIM razred " + designClass + " ali ustrezen skupni gradnik.");
  }
  foreach (var bootstrapClass in new[] { "row", "col", "card", "table", "form-control", "form-select", "form-check", "btn" })
    Assert(!HasCssClass(pageText, bootstrapClass), pageName + " ne sme uporabljati Bootstrap razreda " + bootstrapClass + ".");
}
var discountRulesPage = File.ReadAllText(Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", "DiscountRules.razor"));
Assert(!discountRulesPage.Contains("S1 3 %", StringComparison.Ordinal), "Pravila popustov ne smejo prikazovati statičnega stavka S1–S4.");
Assert(discountRulesPage.Contains("GetValueTiersAsync", StringComparison.Ordinal), "Pravila popustov morajo prikazati pragove iz baze.");
// Pregled strani 2026-09-23: predlogi Blazor (Counter, Weather) in opuscena kartica ProductDetail so izbrisani.
foreach (var removed in new[] { "Counter.razor", "Weather.razor", "ProductDetail.razor", "Partners.razor", "Exports.razor", "PipelineRuns.razor" })
  Assert(!File.Exists(Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", removed)), removed + " je odstranjena; stran brez vsebine ali druga pot na isto stran ne sme nazaj.");

// Ponovni poskus je zapisovalna pot v ERP: obe strani morata imeti enako ozko avtorizacijo,
// dejanje pa sme biti vidno samo pri neuspelem sporocilu. Skupinska pot mora uporabljati
// atomsko bazno proceduro, ne zanke posameznih klicev brez skupnega izida.
foreach (var pageName in new[] { "Saop.razor", "SaopHistory.razor" })
{
  var pageText = File.ReadAllText(Path.Combine(pagesDirectory, pageName));
  Assert(pageText.Contains("@attribute [Authorize(Roles = \"ADMIN,CATALOG_EDITOR\")]", StringComparison.Ordinal),
    pageName + " mora zapisovanje omejiti na ADMIN in CATALOG_EDITOR.");
  Assert(pageText.Contains("row.Status is \"Error\" or \"Dead\"", StringComparison.Ordinal),
    pageName + " sme gumb Pošlji znova pokazati samo pri Error ali Dead.");
  Assert(pageText.Contains("Pošlji znova", StringComparison.Ordinal),
    pageName + " mora imeti jasno poimenovano vrstično dejanje.");
  Assert(pageText.Contains("Write.RequeueMessageAsync", StringComparison.Ordinal),
    pageName + " mora klicati novo varno zapisovalno pot.");
  Assert(pageText.Contains("Authentication", StringComparison.Ordinal),
    pageName + " mora izvajalca vzeti iz prijavljene seje.");
}
var saopPage = File.ReadAllText(Path.Combine(pagesDirectory, "Saop.razor"));
Assert(saopPage.Contains("Pošlji znova vse neuspele", StringComparison.Ordinal),
  "Pregled SAOP mora ponuditi skupinski ponovni poskus.");
Assert(saopPage.Contains("Write.RequeueBatchAsync", StringComparison.Ordinal),
  "Skupinski gumb mora uporabiti atomsko bazno proceduro.");
var saopWriteText = File.ReadAllText(saopWrite);
foreach (var contract in new[] { "RequeueMessageAsync", "out.RequeueOutboxMessage", "RequeueBatchAsync", "out.RequeueOutboundBatch" })
  Assert(saopWriteText.Contains(contract, StringComparison.Ordinal), "SaopWriteService nima pogodbe: " + contract);

// ─── Zavihek ostane na svoji strani, 2026-08-28 ────────────────────────────
// Uporabnikova zahteva, dobesedno: »ce je zavihek, ga tle prikazi; ce ne, ne dodaj zavihka«.
// Vrstica zavihkov, v kateri povezava odnese na drugo pot, je past: videti je kot preklop
// pogleda, v resnici pa zamenja stran in z njo celo navigacijsko drevo. Take povezave sodijo
// med kartice ali navadne povezave, ne med zavihke.
//
// Preverjamo samo dobesedne naslove; racunani (`href="@(...)"`) se staticno ne dajo razresiti
// in so v tej resitvi vedno na isto stran s poizvedbenim parametrom.
foreach (var razorPage in Directory.EnumerateFiles(pagesDirectory, "*.razor", SearchOption.AllDirectories))
{
  var markup = File.ReadAllText(razorPage);
  var routes = System.Text.RegularExpressions.Regex.Matches(markup, "@page \"/([^\"{]*)")
    .Select(match => match.Groups[1].Value.Trim('/')).ToArray();
  if (routes.Length == 0) continue;

  foreach (System.Text.RegularExpressions.Match strip in
    System.Text.RegularExpressions.Regex.Matches(markup, "<nav[^>]*class=\"page-tabs\"[^>]*>(.*?)</nav>",
      System.Text.RegularExpressions.RegexOptions.Singleline))
  {
    foreach (System.Text.RegularExpressions.Match link in
      System.Text.RegularExpressions.Regex.Matches(strip.Groups[1].Value, "href=\"([^\"@]+)\""))
    {
      var target = link.Groups[1].Value.Split('?')[0].Trim('/');
      Assert(routes.Any(route => string.Equals(route, target, StringComparison.OrdinalIgnoreCase)),
        $"Zavihek na strani {Path.GetFileName(razorPage)} vodi na tujo pot »{target}«. "
        + "Zavihek mora prikazati vsebino na isti strani; povezava na drugo stran ne sme biti zavihek.");
    }
  }
}

/* ─────────────────────────────────────────────────────────────────────────────
   P0 iz pregleda 2026-09-08 — vloge na zapisovalni meji, padec zgodovine SAOP,
   seja onemogocenega racuna in stran brez dostopa (A1–A5).

   Ta del ni branje datotek: zapisovalne servise dejansko poklice s prijavljeno
   bralno vlogo VIEWER in preveri, da zavrnejo **pred** klicem baze.
   ───────────────────────────────────────────────────────────────────────────── */

var authorizationPath = Path.Combine(root, "src", "PIM.Intranet", "Services", "PimAuthorization.cs");
var sessionPath = Path.Combine(root, "src", "PIM.Intranet", "Services", "PimSessionSecurity.cs");
Assert(File.Exists(authorizationPath), "Manjka Services/PimAuthorization.cs — politike zapisovalnih poti (A1, A4).");
Assert(File.Exists(sessionPath), "Manjka Services/PimSessionSecurity.cs — zig seje in omejitev prijave (A3).");
var authorizationSource = File.ReadAllText(authorizationPath);
var sessionSource = File.ReadAllText(sessionPath);
foreach (var contract in new[] { "CatalogWrite", "SaopWrite", "AlertWrite", "BusinessWrite", "PimWriteGuard", "RequireAsync", "UnauthorizedAccessException" })
  Assert(authorizationSource.Contains(contract, StringComparison.Ordinal), "PimAuthorization nima pogodbe: " + contract);

// --- A1/A4: politike so ena sama resnica o tem, katera vloga sme pisati -------------------
Assert(PimPolicies.RolesFor(PimPolicies.CatalogWrite).OrderBy(role => role).SequenceEqual(["ADMIN", "CATALOG_EDITOR"]),
  "Politika CatalogWrite mora biti ADMIN in CATALOG_EDITOR.");
Assert(PimPolicies.RolesFor(PimPolicies.SaopWrite).OrderBy(role => role).SequenceEqual(["ADMIN", "CATALOG_EDITOR"]),
  "Politika SaopWrite mora biti ADMIN in CATALOG_EDITOR.");
Assert(PimPolicies.RolesFor(PimPolicies.AlertWrite).OrderBy(role => role).SequenceEqual(["ADMIN", "COMMERCIAL"]),
  "Politika AlertWrite mora biti ADMIN in COMMERCIAL.");
Assert(PimPolicies.RolesFor(PimPolicies.BusinessWrite).OrderBy(role => role).SequenceEqual(["ADMIN", "CATALOG_EDITOR", "COMMERCIAL"]),
  "Politika BusinessWrite mora biti ADMIN, CATALOG_EDITOR in COMMERCIAL.");

var viewer = Principal("qa_viewer", "VIEWER");
var editor = Principal("qa_editor", "CATALOG_EDITOR");
var commercial = Principal("qa_komerciala", "COMMERCIAL");
Assert(!PimPolicies.Allows(viewer, PimPolicies.CatalogWrite), "Bralna vloga ne sme izpolnjevati CatalogWrite.");
Assert(PimPolicies.Allows(editor, PimPolicies.CatalogWrite), "Urednik kataloga mora izpolnjevati CatalogWrite.");
Assert(!PimPolicies.Allows(editor, PimPolicies.AlertWrite), "Urednik kataloga ne sme potrjevati alarmov.");
Assert(PimPolicies.Allows(commercial, PimPolicies.AlertWrite), "Komerciala mora smeti potrjevati alarme.");
Assert(!PimPolicies.Allows(new ClaimsPrincipal(new ClaimsIdentity()), PimPolicies.CatalogWrite),
  "Neprijavljen uporabnik ne sme izpolnjevati nobene zapisovalne politike.");

// --- A1: zapisovalna pot zavrne bralno vlogo pred klicem baze -----------------------------
// Povezovalni niz je namenoma neveljaven: ce bi varovalka manjkala, bi test padel s SqlException
// namesto z UnauthorizedAccessException, in prav ta razlika je dokaz, da se vloga preveri prva.
var unusableConfiguration = new ConfigurationBuilder()
  .AddInMemoryCollection(new Dictionary<string, string?>
  {
    ["ConnectionStrings:Pim"] = "Server=ta-streznik-ne-obstaja;Database=PIM;Connect Timeout=1;Encrypt=False",
  })
  .Build();
Environment.SetEnvironmentVariable("PIM_CONNECTION_STRING", null);

var viewerGuard = GuardFor(viewer);
var editorGuard = GuardFor(editor);

await AssertRefusedAsync("ProductEditService.SaveTextsAsync",
  () => new ProductEditService(unusableConfiguration, viewerGuard)
    .SaveTextsAsync(1, 1, [new ProductTextEdit("sl", "WEB_TITLE", "x")], "qa_viewer"));
await AssertRefusedAsync("ProductEditService.SaveAttributesAsync",
  () => new ProductEditService(unusableConfiguration, viewerGuard)
    .SaveAttributesAsync(1, 1, [new ProductAttributeEdit("BARVA", "x")], "qa_viewer"));
await AssertRefusedAsync("SaopWriteService.EnqueueAsync",
  () => new SaopWriteService(unusableConfiguration, viewerGuard, NullLogger<SaopWriteService>.Instance)
    .EnqueueAsync(1, [("0000000000001", "Product.Name", "x")], "qa_viewer", "CARD", null));
await AssertRefusedAsync("SaopWriteService.RequeueMessageAsync",
  () => new SaopWriteService(unusableConfiguration, viewerGuard, NullLogger<SaopWriteService>.Instance).RequeueMessageAsync(1, "qa_viewer"));
await AssertRefusedAsync("SaopWriteService.ApproveBatchAsync",
  () => new SaopWriteService(unusableConfiguration, viewerGuard, NullLogger<SaopWriteService>.Instance).ApproveBatchAsync(1, "qa_viewer"));
await AssertRefusedAsync("IntranetDataService.AcknowledgeAlertAsync",
  () => new IntranetDataService(unusableConfiguration, viewerGuard).AcknowledgeAlertAsync(1, 1, "qa_viewer"));
await AssertRefusedAsync("IntranetDataService.ResolveAlertAsync",
  () => new IntranetDataService(unusableConfiguration, viewerGuard).ResolveAlertAsync(1, 1, "qa_viewer"));
await AssertRefusedAsync("RulesWriteService.SaveCheckThresholdAsync",
  () => new RulesWriteService(unusableConfiguration, viewerGuard).SaveCheckThresholdAsync("PRICE", 1, 1m, "qa_viewer"));
// Urednik kataloga pride mimo varovalke in obtici sele na bazi — to dokaze, da varovalka
// ne zavraca vsega po vrsti.
await AssertReachesDatabaseAsync("ProductEditService.SaveTextsAsync z vlogo CATALOG_EDITOR",
  () => new ProductEditService(unusableConfiguration, editorGuard)
    .SaveTextsAsync(1, 1, [new ProductTextEdit("sl", "WEB_TITLE", "x")], "qa_editor"));

// --- Geslo: dolzina je samo priporocilo (zahteva 2026-09-22) -----------------------------
// Uporabnik: »nobenih omejitev glede znakov, lahko je samo priporocilo«. Kratko geslo mora zato
// priti mimo servisa do baze (tu nedosegljive), prazno pa se zavrne prej, ker ga prijava ne sprejme.
var userAdministration = new IntranetUserAdministrationService(unusableConfiguration,
  new ActiveDirectoryService(unusableConfiguration), new UserSecurityStateService(unusableConfiguration));
await AssertPasswordReachesDatabaseAsync("ResetPasswordAsync s kratkim geslom",
  () => userAdministration.ResetPasswordAsync("qa_ni_uporabnik", "abc"));
await AssertPasswordReachesDatabaseAsync("CreateLocalUserAsync s kratkim geslom",
  () => userAdministration.CreateLocalUserAsync("qa_ni_uporabnik", "QA", "1", "VIEWER", null));
foreach (var emptyPassword in new[] { "", "   " })
{
  var refused = false;
  try { await userAdministration.ResetPasswordAsync("qa_ni_uporabnik", emptyPassword); }
  catch (InvalidOperationException) { refused = true; }
  Assert(refused, "Prazno geslo mora biti zavrnjeno pred bazo, sicer bi racun ostal zaklenjen.");
}
Assert(IntranetUserAdministrationService.PasswordAdvice("abc") is not null, "Kratko geslo mora dobiti priporocilo.");
Assert(IntranetUserAdministrationService.PasswordAdvice("dolgo geslo iz besed") is null, "Dovolj dolgo geslo ne sme dobiti priporocila.");
Assert(IntranetUserAdministrationService.PasswordAdvice("") is null, "Prazno polje ne sme kazati priporocila.");

// Zadnja vrata za procese brez uporabnika smejo obstajati samo za teste in orodja.
foreach (var file in Directory.EnumerateFiles(Path.Combine(root, "src", "PIM.Intranet"), "*.cs", SearchOption.AllDirectories)
           .Concat(Directory.EnumerateFiles(Path.Combine(root, "src", "PIM.Intranet"), "*.razor", SearchOption.AllDirectories)))
{
  if (Path.GetFileName(file) == "PimAuthorization.cs") continue;
  Assert(!File.ReadAllText(file).Contains("PimWriteGuard.Trusted", StringComparison.Ordinal),
    "PimWriteGuard.Trusted so zadnja vrata mimo vseh politik in v intranetu ne smejo biti uporabljena: " + file);
}

// --- A1: kartica bralni vlogi ne ponudi obrazca -------------------------------------------
var productCard = File.ReadAllText(Path.Combine(pagesDirectory, "ProductCard.razor"));
var channelPanel = File.ReadAllText(Path.Combine(pagesDirectory, "ProductCard", "ProductChannelPanel.razor"));
Assert(productCard.Contains("PimPolicies.Allows(", StringComparison.Ordinal) && productCard.Contains("CanEdit", StringComparison.Ordinal),
  "Kartica mora pravico do urejanja vzeti iz politike, ne iz vrste polja.");
Assert(Regex.IsMatch(productCard, @"@if \(!CanEdit\)[\s\S]{0,400}Samo za branje"),
  "Kartica mora bralni vlogi pokazati znacko »Samo za branje«.");
Assert(productCard.IndexOf("Shrani spremembe", StringComparison.Ordinal) > productCard.IndexOf("@if (!CanEdit)", StringComparison.Ordinal),
  "Gumb »Shrani spremembe« mora biti znotraj veje, ki velja samo za vlogo s pravico pisanja.");
Assert(Regex.Matches(productCard, @"ReadOnly=""@\(!CanEdit\)""").Count == 3,
  "Vsi trije kanalni obrazci kartice morajo dobiti ReadOnly iz iste pravice.");
Assert(productCard.Contains("if (!CanEdit) { SaveError", StringComparison.Ordinal),
  "Shranjevanje kartice mora zavrniti vlogo brez pravice tudi, ce gumb pride do klica.");
Assert(channelPanel.Contains("ProductFieldEdit.None || ReadOnly", StringComparison.Ordinal),
  "Obrazec kanala mora ob ReadOnly izrisati vrednost namesto vnosnega polja.");

// --- A4: potrjevanje in resevanje alarmov ni vec odprto vsem prijavljenim ------------------
var checksPage = File.ReadAllText(Path.Combine(pagesDirectory, "Checks.razor"));
Assert(checksPage.Contains("CanActOnAlerts", StringComparison.Ordinal)
    && Regex.IsMatch(checksPage, @"@if \(CanActOnAlerts\)[\s\S]{0,400}Potrdi"),
  "Gumba »Potrdi« in »Reši« morata biti vezana na pravico do alarmov.");
Assert(checksPage.Contains("PimPolicies.Allows(state.User, PimPolicies.AlertWrite)", StringComparison.Ordinal),
  "Stran preverb mora pravico brati iz politike, ne iz seznama vlog v strani.");

// --- A2: /saop/zgodovina brez parametra v naslovu ------------------------------------------
var saopHistoryPage = File.ReadAllText(Path.Combine(pagesDirectory, "SaopHistory.razor"));
Assert(saopHistoryPage.Contains("public string? Status", StringComparison.Ordinal),
  "Parameter »stanje« mora biti nicelen: brez njega Blazor lastnost nastavi na null.");
// Pojasnilo v komentarju sme omenjati staro napako; prepoved velja za kodo.
Assert(!WithoutComments(saopHistoryPage).Contains("Status.Length", StringComparison.Ordinal),
  "Filter zgodovine ne sme brati Status.Length — prav to je padlo s HTTP 500.");
Assert(saopHistoryPage.Contains("string.IsNullOrEmpty(Status)", StringComparison.Ordinal),
  "Filter zgodovine mora prazen in manjkajoc parameter obravnavati enako.");

// --- A3: zig seje, preverjanje piskotka in omejitev prijave --------------------------------
Assert(programText.Contains("OnValidatePrincipal = PimSessionValidator.ValidateAsync", StringComparison.Ordinal),
  "Piskotek se mora ob zahtevi znova preveriti; brez tega onemogocen racun ostane prijavljen.");
Assert(sessionSource.Contains("sec.GetUserSecurityState", StringComparison.Ordinal)
    && sessionSource.Contains("RejectPrincipal", StringComparison.Ordinal)
    && sessionSource.Contains("SignOutAsync", StringComparison.Ordinal),
  "Preverjanje seje mora brati stanje iz baze in sejo ob neujemanju zavreci.");
Assert(programText.Contains("AddRateLimiter", StringComparison.Ordinal)
    && programText.Contains("UseRateLimiter", StringComparison.Ordinal)
    && programText.Contains("RequireRateLimiting(PimRateLimits.Login)", StringComparison.Ordinal),
  "Prijavna pot mora imeti omejitev zahtev.");
Assert(programText.Contains("PimClaims.SecurityStamp", StringComparison.Ordinal)
    || sessionSource.Contains("PimClaims.SecurityStamp", StringComparison.Ordinal),
  "Zig seje mora priti v piskotek, sicer ga ni s cim primerjati.");
Assert(File.ReadAllText(auth).Contains("SecurityStamp", StringComparison.Ordinal),
  "Prijava mora prebrati zig seje iz sec.LocalUser.");

var throttle = new PimLoginThrottle();
for (var attempt = 1; attempt <= PimLoginThrottle.MaxFailures; attempt++)
{
  Assert(throttle.RetryAfter("qa_viewer", "10.0.0.1") is null, $"Poskus {attempt} se ne sme biti blokiran.");
  throttle.RegisterFailure("qa_viewer", "10.0.0.1");
}
Assert(throttle.RetryAfter("qa_viewer", "10.0.0.1") is not null,
  $"Poskus {PimLoginThrottle.MaxFailures + 1} mora biti zavrnjen z 429.");
Assert(throttle.RetryAfter("qa_viewer", "10.0.0.2") is null,
  "Omejitev velja na par uporabnisko ime + naslov in ne sme zakleniti druge naprave.");
Assert(throttle.RetryAfter("qa_editor", "10.0.0.1") is null,
  "Omejitev ne sme zakleniti drugega uporabnika z istega naslova.");
throttle.RegisterSuccess("qa_viewer", "10.0.0.1");
Assert(throttle.RetryAfter("qa_viewer", "10.0.0.1") is null, "Uspesna prijava mora stevec pocistiti.");

// --- A5: stran brez dostopa in slovenska stran napake ---------------------------------------
Assert(programText.Contains("AccessDeniedPath = \"/brez-dostopa\"", StringComparison.Ordinal),
  "Zavrnjen dostop ne sme voditi na prijavni obrazec.");
var accessDeniedPath = Path.Combine(pagesDirectory, "AccessDenied.razor");
Assert(File.Exists(accessDeniedPath), "Manjka stran /brez-dostopa.");
var accessDenied = File.ReadAllText(accessDeniedPath);
foreach (var value in new[] { "@page \"/brez-dostopa\"", "Prijavljen si kot", "Tvoje vloge", "skrbnik" })
  Assert(accessDenied.Contains(value, StringComparison.Ordinal), "Stran brez dostopa ne pove: " + value);

var errorPage = File.ReadAllText(Path.Combine(pagesDirectory, "Error.razor"));
foreach (var english in new[] { "Development Mode", "An error occurred while processing your request.", "Request ID:" })
  Assert(!errorPage.Contains(english, StringComparison.Ordinal), "Stran napake ne sme biti angleska predloga: " + english);
foreach (var value in new[] { "Nekaj je šlo narobe", "Oznaka zahteve", "nadzorna-plosca" })
  Assert(errorPage.Contains(value, StringComparison.Ordinal), "Stran napake mora vsebovati: " + value);

// --- A5: meni ne sme kazati poti, ki jo vloga dobi kot 403 ----------------------------------
// Vloge menija se primerjajo z [Authorize(Roles = ...)] ciljne strani. Tega ni mogoce preveriti
// z branjem enega mesta: meni je v kodi, avtorizacija pa na strani, zato se razideta tiho.
var routeRoles = new Dictionary<string, string[]>(StringComparer.OrdinalIgnoreCase);
foreach (var razorPage in Directory.EnumerateFiles(pagesDirectory, "*.razor", SearchOption.AllDirectories))
{
  var markup = File.ReadAllText(razorPage);
  var authorize = Regex.Match(markup, @"@attribute \[Authorize\(Roles = ""([^""]+)""\)\]");
  var roles = authorize.Success
    ? authorize.Groups[1].Value.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
    : [];
  foreach (Match route in Regex.Matches(markup, @"@page ""/([^""{]*)"))
    routeRoles[route.Groups[1].Value.Trim('/')] = roles;
}

foreach (var section in PimNavigation.Sections)
  foreach (var item in section.Items)
  {
    if (!routeRoles.TryGetValue(item.Route.Trim('/'), out var pageRoles)) continue;
    if (pageRoles.Length == 0) continue;
    Assert(item.Roles is { Length: > 0 },
      $"Postavka menija »{item.Label}« vodi na stran, omejeno na {string.Join(", ", pageRoles)}, sama pa nima vlog.");
    foreach (var role in item.Roles!)
      Assert(pageRoles.Contains(role, StringComparer.Ordinal),
        $"Postavka menija »{item.Label}« je vidna vlogi {role}, stran {item.Route} pa je zanjo zaprta.");
  }

// --- Blok 7 prenove nadzora (2026-09-22): katalog pravic sledi odstranjenim stranem ----------
// Ključ strani, ki je ni več, bi v upravljanju vlog ostal kot kljukica brez učinka, shranjevanje
// vloge pa bi ga zavrnilo kot neznanega. Stran posla mora spadati pod isto pravico kot Nadzor,
// sicer bi skrbnik z dostopom do Nadzora ob kliku na posel dobil »brez dostopa«.
foreach (var removedKey in new[] { "tab.system.jobs", "tab.system.runs", "tab.system.schedules", "tab.system.alerts", "tab.system.workers", "view.system.exports", "view.system.performance", "view.system.errors" })
  Assert(!PimAccessCatalog.Keys.Contains(removedKey), "Katalog pravic še vsebuje ključ odstranjene strani: " + removedKey);
foreach (var (path, expected) in new[]
{
  ("sistem", "tab.system.overview"),
  ("sistem?pogled=postopki", "tab.system.overview"),
  ("sistem/posel/SAOP_STOCK_IMPORT", "tab.system.overview"),
  ("sistem/posel/WEB_CATALOG_EXPORT?tek=12", "tab.system.overview"),
  ("sistem/samotest", "view.system.self-test"),
  ("sistem/sled", "view.system.activity"),
})
  Assert(PimAccessCatalog.Resolve(path) == expected, $"Pot {path} mora zahtevati {expected}, zahteva pa {PimAccessCatalog.Resolve(path)}.");
foreach (var removedPath in new[] { "sistem/opravila", "sistem/zagoni", "sistem/integracije", "system/integracije", "sistem/napake", "sistem/zmogljivost", "sistem/izvozi" })
  Assert(PimAccessCatalog.Resolve(removedPath) == "__unknown__", "Odstranjena pot ne sme imeti pravice: " + removedPath);
foreach (var tab in PIM.Intranet.Components.Shared.NadzorTabs.Tabs)
{
  Assert(tab.PermissionKey is not null && PimAccessCatalog.Keys.Contains(tab.PermissionKey), $"Zavihek nadzora {tab.Key} nima ključa iz kataloga.");
  Assert(PimAccessCatalog.ParentOf(tab.PermissionKey!) == PimAccessCatalog.System, $"Zavihek nadzora {tab.Key} mora spadati pod {PimAccessCatalog.System}.");
  Assert(PimAccessCatalog.Resolve(tab.Href) == tab.PermissionKey, $"Zavihek nadzora {tab.Key} vodi na pot z drugo pravico kot jo sam zahteva.");
}
Assert(PIM.Intranet.Components.Shared.NadzorTabs.Tabs.Select(tab => tab.Key).SequenceEqual(["nadzor", "samotest", "sled"]),
  "Nadzor ima natanko tri zavihke: Nadzor, Samotest, Sled sprememb.");
foreach (var child in PimAccessCatalog.All.Where(item => item.ParentKey is not null))
  Assert(PimAccessCatalog.Pages.Any(item => item.Key == child.ParentKey), $"Pravica {child.Key} kaže na neobstoječo stran {child.ParentKey}.");
foreach (var pageDefinition in PimAccessCatalog.Pages)
{
  var children = PimAccessCatalog.ChildrenOf(pageDefinition.Key);
  Assert(children.Count == 0 || children.Any(child => PimAccessCatalog.Resolve(child.Route) == child.Key),
    $"Nobena podstran strani {pageDefinition.Key} se ne razreši v svoj ključ; vloga je ne bi mogla odpreti.");
}
Assert(PimAccessCatalog.All.Select(item => item.Key).Distinct(StringComparer.Ordinal).Count() == PimAccessCatalog.All.Count,
  "Katalog pravic ima podvojen ključ.");


Console.WriteLine("F10 auth contract PASS.");

static void Assert(bool condition, string message)
{
  if (!condition) throw new InvalidOperationException(message);
}

static bool HasCssClass(string markup, string cssClass)
{
  foreach (System.Text.RegularExpressions.Match match in System.Text.RegularExpressions.Regex.Matches(markup, "class=\\\"([^\\\"]*)\\\""))
    if (match.Groups[1].Value.Split(' ', StringSplitOptions.RemoveEmptyEntries).Contains(cssClass, StringComparer.Ordinal)) return true;
  return false;
}

static string FindRoot()
{
  var current = new DirectoryInfo(Directory.GetCurrentDirectory());
  while (current is not null)
  {
    if (Directory.Exists(Path.Combine(current.FullName, "sql", "migrations"))) return current.FullName;
    current = current.Parent;
  }

  throw new InvalidOperationException("PIM_Solution ni najden.");
}

/// <summary>Vrstice brez // in @* *@ komentarjev; pogodba velja za kodo, ne za pojasnila.</summary>
static string WithoutComments(string source) =>
  Regex.Replace(Regex.Replace(source, @"@\*[\s\S]*?\*@", " "), @"//[^\r\n]*", " ");

static ClaimsPrincipal Principal(string name, params string[] roles)
{
  var claims = new List<Claim> { new(ClaimTypes.Name, name) };
  claims.AddRange(roles.Select(role => new Claim(ClaimTypes.Role, role)));
  return new ClaimsPrincipal(new ClaimsIdentity(claims, "test"));
}

// Namenoma NE uporablja HttpContextAccessor: ta hrani kontekst v enem samem staticnem
// AsyncLocal, zato bi drugi klic povozil prvega in bi varovalka bralne vloge videla urednika.
static PimWriteGuard GuardFor(ClaimsPrincipal user) =>
  new(new EmptyServices(), new FixedHttpContext(new DefaultHttpContext { User = user }));

static async Task AssertRefusedAsync(string what, Func<Task> call)
{
  try
  {
    await call();
  }
  catch (UnauthorizedAccessException)
  {
    return;
  }
  catch (Exception other)
  {
    throw new InvalidOperationException(
      $"{what} je bralno vlogo spustil do baze: pricakovan UnauthorizedAccessException, dobljen {other.GetType().Name}.");
  }

  throw new InvalidOperationException($"{what} bralne vloge ni zavrnil.");
}

static async Task AssertReachesDatabaseAsync(string what, Func<Task> call)
{
  try
  {
    await call();
  }
  catch (UnauthorizedAccessException)
  {
    throw new InvalidOperationException($"{what} je bil zavrnjen, ceprav ima vlogo s pravico pisanja.");
  }
  catch
  {
    return;
  }

  throw new InvalidOperationException($"{what} bi moral obtičati na nedosegljivi bazi, ne uspeti.");
}

/// <summary>Kratko geslo ne sme obticati na preverjanju gesla, ampak sele na (nedosegljivi) bazi.</summary>
static async Task AssertPasswordReachesDatabaseAsync(string what, Func<Task> call)
{
  try
  {
    await call();
  }
  catch (Microsoft.Data.SqlClient.SqlException)
  {
    return;
  }
  catch (Exception other)
  {
    throw new InvalidOperationException($"{what} je bil zavrnjen pred bazo ({other.GetType().Name}: {other.Message}); dolzina gesla ne sme biti pogoj.");
  }

  throw new InvalidOperationException($"{what} bi moral obtičati na nedosegljivi bazi, ne uspeti.");
}

/// <summary>Vsebnik brez storitev: PimWriteGuard mora uporabnika najti v HttpContext.</summary>
sealed class EmptyServices : IServiceProvider
{
  public object? GetService(Type serviceType) => null;
}

/// <summary>En kontekst na eno varovalko; brez skupnega staticnega AsyncLocal.</summary>
sealed class FixedHttpContext(HttpContext? context) : IHttpContextAccessor
{
  public HttpContext? HttpContext { get; set; } = context;
}
