var currentDirectory = Directory.GetCurrentDirectory();
var root = Environment.GetEnvironmentVariable("PIM_SOLUTION_ROOT")
  ?? (Directory.Exists(Path.Combine(currentDirectory, "sql", "migrations"))
    ? currentDirectory
    : Path.GetFullPath("../..", currentDirectory));
var failures = new List<string>();

Require(Path.Combine(root, "sql", "migrations", "007_CreateSaopPipeline.sql"));
Require(Path.Combine(root, "sql", "migrations", "008_AllowCorePromotion.sql"));
Require(Path.Combine(root, "sql", "migrations", "009_FixSaopXmlParsingAndErpEligibility.sql"));
Require(Path.Combine(root, "workers", "PIM.KatalogWorker", "PIM.KatalogWorker.csproj"));
Require(Path.Combine(root, "workers", "PIM.KatalogWorker", "SaopSource.cs"));
Require(Path.Combine(root, "workers", "PIM.KatalogWorker", "RawInboxWriter.cs"));

var migration = Path.Combine(root, "sql", "migrations", "007_CreateSaopPipeline.sql");
AssertContains(migration, "raw.Inbox");
AssertContains(migration, "map.SourceConnector");
AssertContains(migration, "map.FieldMapping");
AssertContains(migration, "map.Watermark");
AssertContains(migration, "map.PipelineStep");
AssertContains(migration, "map.ProcessRawInbox");
AssertContains(migration, "val.RunValidation");
AssertContains(migration, "val.Promote");
AssertContains(migration, "out.ExportProductsCsv");
AssertContains(migration, "WEB_B2C_PRODUCTS");

var fixMigration = Path.Combine(root, "sql", "migrations", "009_FixSaopXmlParsingAndErpEligibility.sql");
AssertContains(fixMigration, "map.StripXmlDeclaration");
AssertContains(fixMigration, "CREATE OR ALTER PROCEDURE map.ProcessRawInbox");
AssertContains(fixMigration, "StockData/SupplierID");
AssertContains(fixMigration, "SalesData/DiscountGroup1ID");
AssertContains(fixMigration, "StockData/ManufacturerID");
AssertContains(fixMigration, "Product.Supplier");
AssertContains(fixMigration, "Product.DiscountGroup");
AssertContains(fixMigration, "Product.Manufacturer");
if (File.Exists(fixMigration) && File.ReadAllText(fixMigration).Contains("IsRequired=0", StringComparison.Ordinal))
{
  failures.Add(Path.GetRelativePath(root, fixMigration) + " ne sme obveznega polja spremeniti v neobvezno.");
}

var appliedMigrations = new[] { migration, Path.Combine(root, "sql", "migrations", "008_AllowCorePromotion.sql") };
foreach (var appliedMigration in appliedMigrations)
{
  if (File.Exists(appliedMigration) && File.ReadAllText(appliedMigration).Contains("StripXmlDeclaration", StringComparison.Ordinal))
  {
    failures.Add(Path.GetRelativePath(root, appliedMigration) + " je bila spremenjena; popravki F3 morajo biti v novi migraciji.");
  }
}

var source = Path.Combine(root, "workers", "PIM.KatalogWorker", "SaopSource.cs");
AssertContains(source, "interface ISaopSource");
AssertContains(source, "Disabled");
AssertContains(source, "Fixture");
AssertContains(source, "Live");
AssertContains(source, "HttpClient");
AssertContains(source, "ItemGeneralData");
AssertContains(source, "Prices");
AssertContains(source, "Descriptions");
AssertContains(source, "Currencies");
AssertContains(source, "PriceLists");

var writer = Path.Combine(root, "workers", "PIM.KatalogWorker", "RawInboxWriter.cs");
AssertContains(writer, "raw.Inbox");
AssertContains(writer, "@PayloadXml");
AssertContains(writer, "MERGE raw.Inbox");
AssertContains(writer, "WHEN MATCHED AND target.Status = N'Quarantined'");
AssertContains(writer, "WHEN NOT MATCHED");
if (File.Exists(writer) && File.ReadAllText(writer).Contains("WHERE NOT EXISTS", StringComparison.Ordinal))
{
  failures.Add(Path.GetRelativePath(root, writer) + " še vedno uporablja INSERT ... WHERE NOT EXISTS, ki karantenskih zapisov ne vrne v vrsto.");
}

if (failures.Count > 0)
{
  Console.Error.WriteLine("F3 kontrakt NI izpolnjen:");
  foreach (var failure in failures) Console.Error.WriteLine("- " + failure);
  return 1;
}

Console.WriteLine("F3 statični kontrakt je izpolnjen.");
return 0;

void Require(string path)
{
  if (!File.Exists(path)) failures.Add("Manjka " + Path.GetRelativePath(root, path));
}

void AssertContains(string path, string expected)
{
  if (!File.Exists(path) || !File.ReadAllText(path).Contains(expected, StringComparison.Ordinal))
    failures.Add(Path.GetRelativePath(root, path) + " ne vsebuje: " + expected);
}
