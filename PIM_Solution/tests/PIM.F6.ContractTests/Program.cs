var root = FindRoot();
var failures = new List<string>();
var migration = Read("sql/migrations/018_CreateStockPipeline.sql");
var identityConfiguration = Read("sql/migrations/019_ConfigureStockIdentityRules.sql");

foreach (var expected in new[]
{
  "CREATE SCHEMA stock", "CREATE TABLE stock.SaopProviderProfile",
  "CREATE TABLE map.StockIdentityRule", "CREATE TABLE stock.LandingRecord",
  "CREATE TABLE stock.Snapshot", "CREATE TABLE stock.Position",
  "CREATE TABLE stock.UnmatchedPosition", "CREATE TABLE stock.SyncRun",
  "CREATE OR ALTER PROCEDURE stock.ApplyLandingRecord",
  "CREATE OR ALTER PROCEDURE intranet.GetStocks",
  "CREATE OR ALTER PROCEDURE out.ExportStockCsv"
})
{
  Contains(migration, expected, $"Manjka pogodbeni objekt: {expected}.");
}
Contains(migration, "OrganizationId, SourceConnectorId, SourceRecordKey, SnapshotUtc",
  "Immutable identiteta landing zapisa ni eksplicitna.");
Contains(migration, "IX_stock_Position_Identity", "Manjka iskalni indeks ItemID/EAN.");
Contains(identityConfiguration, "MERGE map.StockIdentityRule", "Manjka konfigurirana identitetna pravila za stock vire.");
var writer = Read("workers/PIM.StockFileWorker/StockLandingWriter.cs");
Contains(writer, "LoadIdentityRuleAsync", "Worker mora identitetno pravilo prebrati iz map.StockIdentityRule.");
if (migration.Contains("val.", StringComparison.OrdinalIgnoreCase))
{
  failures.Add("Zalogovni tok ne sme biti odvisen od val.*.");
}

if (failures.Count > 0)
{
  Console.Error.WriteLine("F6 contract RED:");
  failures.ForEach(failure => Console.Error.WriteLine("- " + failure));
  return 1;
}
Console.WriteLine("F6 contract: ločeni stock podatkovni objekti PASS.");
return 0;

string FindRoot()
{
  var current = new DirectoryInfo(Directory.GetCurrentDirectory());
  while (current is not null && !Directory.Exists(Path.Combine(current.FullName, "sql", "migrations"))) current = current.Parent;
  return current?.FullName ?? throw new InvalidOperationException("PIM_Solution ni najden.");
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
