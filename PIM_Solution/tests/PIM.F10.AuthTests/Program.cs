var root = FindRoot();
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
foreach (var value in new[] { "@page \"/system/uporabniki\"", "Authorize(Roles = \"ADMIN\")", "Najdi v AD", "Dodaj domenskega uporabnika" })
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
foreach (var pageName in new[] { "Dashboard.razor", "Products.razor", "ProductDetail.razor", "Stocks.razor", "ValidationErrors.razor", "RawQuarantine.razor" })
{
  var pageText = File.ReadAllText(Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", pageName));
  Assert(pageText.Contains("GetCurrentOrganizationAsync", StringComparison.Ordinal), pageName + " mora uporabljati aktivno organizacijo iz baze.");
}
var dashboardPage = File.ReadAllText(Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", "Dashboard.razor"));
Assert(dashboardPage.Contains("else if (Metrics is null)", StringComparison.Ordinal), "Nadzorna plošča ne sme hkrati prikazati napake in nalaganja.");
var stocksPage = File.ReadAllText(Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", "Stocks.razor"));
Assert(stocksPage.Contains("<caption>", StringComparison.Ordinal), "Tabela zalog mora imeti programsko določen napis.");
var quarantinePage = File.ReadAllText(Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", "RawQuarantine.razor"));
Assert(quarantinePage.Contains("<h1>Karantena</h1>", StringComparison.Ordinal), "Vidni naslov karantene mora biti dosleden.");
foreach (var pageName in new[] { "Customers.razor", "CustomerDetail.razor", "PipelineRuns.razor", "Outbound.razor", "SystemIntegrations.razor", "DiscountRules.razor" })
{
  var pageText = File.ReadAllText(Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", pageName));
  Assert(pageText.Contains("GetCurrentOrganizationAsync", StringComparison.Ordinal), pageName + " mora uporabljati aktivno organizacijo iz baze.");
  Assert(!pageText.Contains("Async(2,", StringComparison.Ordinal), pageName + " ne sme uporabljati hardkodirane organizacije 2.");
}
foreach (var pageName in new[] { "Customers.razor", "PipelineRuns.razor", "Outbound.razor", "SystemIntegrations.razor" })
{
  var pageText = File.ReadAllText(Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", pageName));
  Assert(pageText.Contains("data-table", StringComparison.Ordinal), pageName + " mora uporabljati skupni tabelarični UX.");
  Assert(pageText.Contains("error-state", StringComparison.Ordinal), pageName + " mora imeti pošteno stanje napake.");
}
foreach (var pageName in new[] { "DiscountRules.razor", "CustomerDetail.razor", "SystemUsers.razor" })
{
  var pageText = File.ReadAllText(Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", pageName));
  foreach (var designClass in new[] { "page-header", "ui-card", "data-table" })
    Assert(pageText.Contains(designClass, StringComparison.Ordinal), pageName + " mora uporabljati PIM razred " + designClass + ".");
  foreach (var bootstrapClass in new[] { "row", "col", "card", "table", "form-control", "form-select", "form-check", "btn" })
    Assert(!HasCssClass(pageText, bootstrapClass), pageName + " ne sme uporabljati Bootstrap razreda " + bootstrapClass + ".");
}
var discountRulesPage = File.ReadAllText(Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", "DiscountRules.razor"));
Assert(!discountRulesPage.Contains("S1 3 %", StringComparison.Ordinal), "Pravila popustov ne smejo prikazovati statičnega stavka S1–S4.");
Assert(discountRulesPage.Contains("GetValueTiersAsync", StringComparison.Ordinal), "Pravila popustov morajo prikazati pragove iz baze.");
Assert(!File.ReadAllText(Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", "Counter.razor")).Contains("@page", StringComparison.Ordinal), "Counter ne sme biti javna PIM stran.");
Assert(!File.ReadAllText(Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages", "Weather.razor")).Contains("@page", StringComparison.Ordinal), "Weather ne sme biti javna PIM stran.");

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
