var root = Environment.GetEnvironmentVariable("PIM_SOLUTION_ROOT") ?? FindRoot();
var failures = new List<string>();
var migration = Read("sql/migrations/016_CreateGenericXmlMappingPipeline.sql");
var remediation = Read("sql/migrations/017_HardenGenericXmlMappingPipeline.sql");

Require("src/PIM.XmlMapping/XPathMappingExtractor.cs");
Require("src/PIM.XmlMapping/SqlMappingPipeline.cs");
Require("workers/PIM.XmlFileWorker/Program.cs");
var saopWorker = Read("workers/PIM.KatalogWorker/Program.cs");
Contains(saopWorker, "SqlMappingPipeline", "SAOP worker ni priklopljen na generični extract/apply.");
Contains(migration, "CREATE TABLE map.ExtractedValue", "Manjka generična extracted hramba.");
Contains(migration, "InboxId", "Manjka sled do inboxa.");
Contains(migration, "FieldMappingId", "Manjka sled do mappinga.");
Contains(migration, "MappingVersion", "Manjka verzija mappinga.");
Contains(migration, "RecordOrdinal", "Manjka sled do zapisa.");
Contains(migration, "CREATE TABLE map.UnmappedValue", "Manjka generična nepodprta vrsta.");
Contains(migration, "CREATE OR ALTER PROCEDURE map.ProcessRawInbox", "Manjka generični apply.");
Contains(migration, "ProductCategory.CategoryPath", "Apply ne podpira kategorije.");
Contains(migration, "ProductMedia.Url", "Apply ne podpira medija.");
Contains(migration, "ProductAttribute.", "Apply ne podpira atributa.");
Contains(remediation, "BEGIN TRANSACTION", "017 ne zagotavlja atomske obdelave inboxa.");
Contains(remediation, "GROUP BY", "017 ne grupira podvojenih ciljnih vrednosti pred MERGE.");
Contains(remediation, "IsRequired", "017 ne preverja obveznih preslikav.");
Contains(remediation, "TRY_CONVERT(decimal(19,4)", "017 ne preverja neto cene.");
Contains(remediation, "TRY_CONVERT(decimal(5,2)", "017 ne preverja DDV.");
Contains(remediation, "TRY_CONVERT(datetime2(3)", "017 ne preverja datuma veljavnosti.");
Contains(remediation, "Izdelek za konfigurirani identifikator ne obstaja", "017 ne zavrne neujemajočega izdelka.");
Contains(remediation, "map.UnmappedValue", "017 ne ohrani zavrnjenih generičnih vrednosti.");
if (migration.Contains(".nodes(", StringComparison.OrdinalIgnoreCase)
  || migration.Contains("sp_executesql", StringComparison.OrdinalIgnoreCase))
{
  failures.Add("SQL apply ne sme izvajati XPath.");
}

var genericCode = Read("src/PIM.XmlMapping/XPathMappingExtractor.cs")
  + Read("src/PIM.XmlMapping/SqlMappingPipeline.cs")
  + Read("workers/PIM.XmlFileWorker/Program.cs");
if (genericCode.Contains("NW", StringComparison.OrdinalIgnoreCase))
{
  failures.Add("Generična C# koda vsebuje ime NW.");
}

if (failures.Count > 0)
{
  Console.Error.WriteLine("F5 contract RED:");
  failures.ForEach(failure => Console.Error.WriteLine("- " + failure));
  return 1;
}

Console.WriteLine("F5 contract: generična staging/apply pot PASS.");
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
void Require(string path) => Read(path);
void Contains(string text, string expected, string failure)
{
  if (!text.Contains(expected, StringComparison.OrdinalIgnoreCase)) failures.Add(failure);
}
