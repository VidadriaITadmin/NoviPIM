using System.Text.RegularExpressions;

var currentDirectory = Directory.GetCurrentDirectory();
var solutionRoot = Environment.GetEnvironmentVariable("PIM_SOLUTION_ROOT")
  ?? (Directory.Exists(Path.Combine(currentDirectory, "sql", "migrations"))
    ? currentDirectory
    : Path.GetFullPath("../..", currentDirectory));
var migrationsDirectory = Path.Combine(solutionRoot, "sql", "migrations");

var failures = new List<string>();

RequireFile("001_CreateSchemas.sql");
RequireFile("002_CreateOperationsAndOrganization.sql");
RequireFile("003_CreateOperationalProcedures.sql");
RequireFile("004_CreateProcedureSkeleton.sql");

AssertContains("001_CreateSchemas.sql", "dbo.SchemaMigration");
AssertContains("001_CreateSchemas.sql", "CREATE SCHEMA raw");
AssertContains("001_CreateSchemas.sql", "CREATE SCHEMA sec");
AssertContains("002_CreateOperationsAndOrganization.sql", "ops.PipelineRun");
AssertContains("002_CreateOperationsAndOrganization.sql", "ops.PipelineStepLog");
AssertContains("002_CreateOperationsAndOrganization.sql", "ops.DeadLetterQueue");
AssertContains("002_CreateOperationsAndOrganization.sql", "ops.ErrorLog");
AssertContains("002_CreateOperationsAndOrganization.sql", "ops.Heartbeat");
AssertContains("002_CreateOperationsAndOrganization.sql", "dbo.OrganizationConfig");
AssertContains("002_CreateOperationsAndOrganization.sql", "IQLighting");
AssertContains("003_CreateOperationalProcedures.sql", "ops.LogError");
AssertContains("003_CreateOperationalProcedures.sql", "ops.EnqueueDeadLetter");
AssertContains("004_CreateProcedureSkeleton.sql", "SET XACT_ABORT ON");
AssertContains("004_CreateProcedureSkeleton.sql", "BEGIN TRANSACTION");
AssertContains("004_CreateProcedureSkeleton.sql", "ops.LogError");
AssertFileContains(Path.Combine(solutionRoot, "src", "PIM.Migrator", "Program.cs"), "--create-database");
AssertFileContains(Path.Combine(solutionRoot, "src", "PIM.Migrator", "Program.cs"), "EnsureDatabaseAsync");
AssertFileContains(Path.Combine(solutionRoot, "src", "PIM.Migrator", "Program.cs"), "--show-migrations");
AssertFileContains(Path.Combine(solutionRoot, "src", "PIM.Migrator", "Program.cs"), "ShowMigrationsAsync");

if (Directory.Exists(migrationsDirectory))
{
  var migrationNames = Directory.GetFiles(migrationsDirectory, "*.sql")
    .Select(Path.GetFileName)
    .OrderBy(name => name, StringComparer.Ordinal)
    .ToArray();
  var numbered = migrationNames.Where(name => Regex.IsMatch(name!, "^\\d{3}_.+\\.sql$", RegexOptions.CultureInvariant)).ToArray();

  if (numbered.Length != 4)
  {
    failures.Add($"Pričakovane so natanko štiri F0 oštevilčene migracije, najdenih je {numbered.Length}.");
  }
}

if (failures.Count > 0)
{
  Console.Error.WriteLine("F0 migracijski kontrakt NI izpolnjen:");
  foreach (var failure in failures)
  {
    Console.Error.WriteLine($"- {failure}");
  }

  return 1;
}

Console.WriteLine("F0 migracijski kontrakt je izpolnjen.");
return 0;

void RequireFile(string name)
{
  var path = Path.Combine(migrationsDirectory, name);
  if (!File.Exists(path))
  {
    failures.Add($"Manjka migracija {name}.");
  }
}

void AssertContains(string name, string expected)
{
  var path = Path.Combine(migrationsDirectory, name);
  if (!File.Exists(path))
  {
    return;
  }

  var contents = File.ReadAllText(path);
  if (!contents.Contains(expected, StringComparison.Ordinal))
  {
    failures.Add($"Migracija {name} ne vsebuje zahtevanega kontrakta: {expected}.");
  }
}

void AssertFileContains(string path, string expected)
{
  if (!File.Exists(path) || !File.ReadAllText(path).Contains(expected, StringComparison.Ordinal))
  {
    failures.Add($"Manjka pričakovani migratorjev kontrakt: {expected}.");
  }
}
