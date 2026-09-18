var root = FindRoot();
var failures = new List<string>();
var migration = Read("sql/migrations/020_CreateB2bChannel.sql");
var migrator = Read("src/PIM.Migrator/Program.cs");

Contains(migrator, "Directory.GetFiles(migrationsDirectory, \"*.sql\")", "Migrator ne odkriva oštevilčenih SQL migracij.");
Contains(migrator, "OrderBy(migration => migration.Name, StringComparer.Ordinal)", "Migrator migracij ne razvršča deterministično po imenu.");
Contains(migrator, "await VerifyF7Async(connection)", "Migratorjev --verify ne preverja F7.");
Contains(migrator, "LocalSettings.MissingConnectionMessage()", "Migrator nima varnega odziva za manjkajoč PIM_CONNECTION_STRING.");
if (!Directory.GetFiles(Path.Combine(root, "sql", "migrations"), "*.sql")
  .Select(Path.GetFileName)
  .Contains("020_CreateB2bChannel.sql", StringComparer.Ordinal))
  failures.Add("Migratorjev nabor migracij ne vsebuje 020_CreateB2bChannel.sql.");

foreach (var expected in new[]
{
  "CREATE SCHEMA b2b",
  "CREATE TABLE b2b.Customer",
  "CREATE TABLE pim.CustomerTypeCatalog",
  "CREATE TABLE pim.CustomerTypeMagentoGroup",
  "CREATE TABLE pim.CustomerWebProfile",
  "CREATE TABLE pim.PackagingDiscountCatalog",
  "CREATE TABLE pim.ProductPackagingDiscount",
  "CREATE TABLE pim.ValueDiscountTier",
  "CREATE TABLE pim.CustomerValueDiscountTier",
  "CREATE TABLE pim.ShippingRuleCatalog",
  "CREATE TABLE b2b.GroupDiscount",
  "CREATE TABLE b2b.GroupDiscountOverride",
  "CREATE TABLE b2b.CustomerPackagingDiscountOverride",
  "CREATE TABLE b2b.AuditLog",
  "CREATE TABLE b2b.LandingRecord",
  "CREATE TABLE map.B2bFieldMapping",
  "CREATE TABLE b2b.MappingRejection",
  "CREATE OR ALTER PROCEDURE b2b.ApplyLandingRecord",
  "CREATE OR ALTER PROCEDURE b2b.ReplayLandingRecord",
  "CREATE OR ALTER PROCEDURE b2b.SaveCustomerWebProfile",
  "CREATE OR ALTER PROCEDURE b2b.SaveDiscountRule",
  "CREATE OR ALTER PROCEDURE intranet.GetCustomers",
  "CREATE OR ALTER PROCEDURE intranet.GetCustomerDetail",
  "CREATE OR ALTER PROCEDURE intranet.GetCustomerTypes",
  "CREATE OR ALTER PROCEDURE intranet.GetValueDiscountTiers",
  "CREATE OR ALTER PROCEDURE intranet.GetGroupDiscountOverrides",
  "CREATE OR ALTER PROCEDURE out.ExportB2bCustomersCsv",
  "CREATE OR ALTER PROCEDURE out.ExportB2bProductsCsv"
}) Contains(migration, expected, $"Manjka pogodbeni objekt: {expected}.");

foreach (var type in new[]
{
  "INŠTALATER", "MAX INŠTALATER", "MIZAR", "TRGOVEC – TRANZIT",
  "KONČNI KUPEC – B2B", "TRGOVEC", "INŠTALATER MAX", "TRGOVEC – PE",
  "NADALJNJA PRODAJA", "TRGOVEC – PE – NEAKTIVEN", "KONČNI KUPEC – B2B – PE",
  "INŠTALATER – PE", "INŠTALATER – TRANZIT", "TRGOVEC – TRANZIT – NEAKTIVEN",
  "TRGOVEC – neaktiven", "PROJEKTANT", "NEAKTIVEN", "JAVNI SEKTOR"
}) Contains(migration, type, $"Manjka tip stranke: {type}.");

foreach (var seed in new[] { "N'S1', 3", "N'S2', 5", "N'S3', 10", "N'S4', 15", "800, 1", "1500, 2", "3000, 3", "N'STANDARD_PAID',150,NULL,4.10", "N'OVERSIZE',300,2.000,10.00" })
  Contains(migration, seed, $"Manjka začetno pravilo: {seed}.");

foreach (var permission in new[] { "CATALOG_EDITOR", "COMMERCIAL", "ADMIN" })
  Contains(migration, permission, $"Manjka eksplicitna pravica {permission}.");

Contains(migration, "CUSTOMERS_B2B", "Manjka CUSTOMERS B2B profil.");
Contains(migration, "PRODUCTS_B2B", "Manjka PRODUCTS B2B profil.");
Contains(migration, "PromotionGateState", "Manjka eksplicitno stanje promocijskega vira.");
Contains(migration, "Unknown", "Promocijski gate mora privzeto ostati Unknown.");
Contains(migration, "IX_b2b_Customer_OrganizationCustomer", "Manjka indeks identitete stranke.");
Contains(migration, "UX_b2b_LandingRecord_SourcePayloadHash", "Manjka immutable/dedup landing ključ.");
if (migration.Contains("PIM_test", StringComparison.OrdinalIgnoreCase)) failures.Add("Migracija F7 ne sme pisati v PIM_test.");

var service = Read("src/PIM.Intranet/Services/IntranetDataService.cs");
var customersPage = Read("src/PIM.Intranet/Components/Pages/Customers.razor");
var detailPage = Read("src/PIM.Intranet/Components/Pages/CustomerDetail.razor");
var rulesPage = Read("src/PIM.Intranet/Components/Pages/DiscountRules.razor");
foreach (var procedure in new[] { "b2b.SaveCustomerWebProfile", "b2b.SaveCustomerValueTier", "b2b.SaveCustomerTypeMapping", "b2b.SaveValueDiscountTier", "b2b.SaveDiscountRule", "b2b.SaveGroupDiscountOverride" })
  Contains(service, procedure, $"Intranetni servis ne kliče procedure {procedure}.");
foreach (var page in new[] { customersPage, detailPage, rulesPage })
  Contains(page, "ADMIN,CATALOG_EDITOR,COMMERCIAL", "B2B stran nima eksplicitnih vlog Admin/Urednik kataloga/Komerciala.");
Contains(detailPage, "samo za branje", "Plačnik in ceniki niso označeni samo za branje.");
Contains(rulesPage, "OverrideFrom", "Override nima začetka veljavnosti.");
Contains(rulesPage, "OverrideTo", "Override nima konca veljavnosti.");
if ((customersPage + detailPage + rulesPage + service).Contains("pošlji v ERP", StringComparison.OrdinalIgnoreCase)) failures.Add("F7 ne sme vsebovati dejanja F8 za pošiljanje v ERP.");

if (failures.Count > 0)
{
  Console.Error.WriteLine("F7 contract RED:");
  failures.ForEach(failure => Console.Error.WriteLine("- " + failure));
  return 1;
}
Console.WriteLine("F7 contract: B2B podatkovni in izvozni kontrakt PASS.");
return 0;

string FindRoot()
{
  var current = new DirectoryInfo(Directory.GetCurrentDirectory());
  while (current is not null)
  {
    if (Directory.Exists(Path.Combine(current.FullName, "sql", "migrations"))) return current.FullName;
    var solution = Path.Combine(current.FullName, "PIM_Solution");
    if (Directory.Exists(Path.Combine(solution, "sql", "migrations"))) return solution;
    current = current.Parent;
  }
  throw new InvalidOperationException("PIM_Solution ni najden.");
}
string Read(string path)
{
  var fullPath = Path.Combine(root, path);
  if (!File.Exists(fullPath))
  {
    failures.Add("Manjka " + path);
    return "";
  }
  return File.ReadAllText(fullPath);
}
void Contains(string text, string expected, string failure)
{
  if (!text.Contains(expected, StringComparison.OrdinalIgnoreCase)) failures.Add(failure);
}
