var root = FindRoot();
var failures = new List<string>();
var migration = Read("sql/migrations/025_CreateOperationsMonitoring.sql");

foreach (var expected in new[]
{
  "CREATE TABLE ops.ScheduleProfile", "CREATE TABLE ops.IntegrationHealth",
  "CREATE TABLE ops.Alert", "CREATE TABLE ops.AlertDelivery", "CREATE TABLE ops.DeploymentRun",
  "CREATE OR ALTER PROCEDURE ops.BeginRun", "sp_getapplock", "CREATE OR ALTER PROCEDURE ops.Heartbeat",
  "CREATE OR ALTER PROCEDURE ops.CompleteRun", "CREATE OR ALTER PROCEDURE ops.RunWatchdog",
  "CREATE OR ALTER PROCEDURE ops.ClaimAlertDelivery", "CREATE OR ALTER PROCEDURE ops.CompleteAlertDelivery",
  "CREATE OR ALTER PROCEDURE intranet.GetSystemIntegrations",
  "CREATE OR ALTER PROCEDURE intranet.AcknowledgeAlert", "CREATE OR ALTER PROCEDURE intranet.ResolveAlert"
}) Contains(expected);

foreach (var expected in new[]
{
  "OrganizationId", "Pipeline", "IsEnabled", "IntervalSeconds", "StaleAfterSeconds", "LockTimeoutMilliseconds",
  "Severity", "DedupKey", "AcknowledgedUtc", "AcknowledgedBy", "ResolvedUtc", "ResolvedBy",
  "PayloadSummaryRedacted", "NextScheduledUtc", "LeaseOwner", "LeaseUntilUtc", "UpdatedUtc", "UpdatedBy"
}) Contains(expected);

if (migration.Contains("PIM_test", StringComparison.OrdinalIgnoreCase)) failures.Add("Migracija F9 ne sme omenjati PIM_test.");
if (failures.Count > 0)
{
  Console.Error.WriteLine("F9 contract RED:");
  failures.ForEach(x => Console.Error.WriteLine("- " + x));
  return 1;
}
Console.WriteLine("F9 contract: operativni podatkovni kontrakt PASS.");
return 0;

void Contains(string value)
{
  if (!migration.Contains(value, StringComparison.OrdinalIgnoreCase)) failures.Add("Manjka: " + value);
}

string Read(string relative)
{
  var path = Path.Combine(root, relative);
  if (File.Exists(path)) return File.ReadAllText(path);
  failures.Add("Manjka " + relative);
  return "";
}

string FindRoot()
{
  var current = new DirectoryInfo(Directory.GetCurrentDirectory());
  while (current is not null)
  {
    if (Directory.Exists(Path.Combine(current.FullName, "sql", "migrations"))) return current.FullName;
    current = current.Parent;
  }
  throw new InvalidOperationException("PIM_Solution ni najden.");
}
