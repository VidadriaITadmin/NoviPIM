var root = Environment.GetEnvironmentVariable("PIM_SOLUTION_ROOT")
  ?? (Directory.Exists(Path.Combine(Directory.GetCurrentDirectory(), "sql", "migrations"))
    ? Directory.GetCurrentDirectory()
    : Path.GetFullPath("../..", Directory.GetCurrentDirectory()));
var migration = Path.Combine(root, "sql", "migrations", "010_CreateIntranetF4.sql");
var required = new[]
{
  "sec.LocalUser",
  "sec.Role",
  "sec.LocalUserRole",
  "sec.NavigationGroup",
  "sec.NavigationItem",
  "sec.NavigationItemRole",
  "intranet.GetDashboard",
  "intranet.GetProducts",
  "intranet.GetProductDetail",
  "intranet.GetValidationIssues",
  "intranet.GetRawQuarantine",
  "intranet.GetPipelineRuns",
};

if (!File.Exists(migration))
{
  Console.Error.WriteLine("Manjka migracija 010_CreateIntranetF4.sql.");
  return 1;
}

var sql = File.ReadAllText(migration);
var missing = required.Where(value => !sql.Contains(value, StringComparison.Ordinal)).ToArray();
if (missing.Length > 0)
{
  Console.Error.WriteLine("F4 intranetni kontrakt ni izpolnjen:");
  foreach (var value in missing) Console.Error.WriteLine("- " + value);
  return 1;
}

if (sql.Contains("Password =", StringComparison.OrdinalIgnoreCase)
  || sql.Contains("Password=", StringComparison.OrdinalIgnoreCase))
{
  Console.Error.WriteLine("F4 migracija ne sme vsebovati privzetega gesla.");
  return 1;
}

Console.WriteLine("F4 statični intranetni kontrakt je izpolnjen.");
return 0;
