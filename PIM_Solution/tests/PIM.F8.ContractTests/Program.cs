var root = FindRoot();
var failures = new List<string>();
var migration = Read("sql/migrations/021_CreateOutboundOutbox.sql");

foreach (var expected in new[]
{
  "CREATE TABLE out.OutboxMessage",
  "CREATE TABLE out.OutboxAttempt",
  "CREATE TABLE out.OwnershipPolicy",
  "CREATE TABLE dbo.IntegrationProfile",
  "CK_OutboxMessage_Status",
  "UX_OutboxMessage_ActiveDedup",
  "CREATE OR ALTER PROCEDURE out.EnqueueMessage",
  "CREATE OR ALTER PROCEDURE out.ApproveMessage",
  "CREATE OR ALTER PROCEDURE out.CancelMessage",
  "CREATE OR ALTER PROCEDURE out.RetryMessage",
  "CREATE OR ALTER PROCEDURE out.ClaimMessage",
  "CREATE OR ALTER PROCEDURE out.CompleteAttempt",
  "CREATE OR ALTER PROCEDURE out.VerifyEcho",
  "CREATE OR ALTER PROCEDURE intranet.GetOutboundMessages",
  "CREATE OR ALTER PROCEDURE intranet.GetOutboundMessage"
}) Contains(migration, expected, $"Manjka pogodbeni objekt: {expected}.");

foreach (var state in new[]
{
  "PendingApproval", "Pending", "Sending", "Sent", "Verified",
  "Error", "Retry", "Dead", "Cancelled", "Drift"
}) Contains(migration, state, $"Manjka stanje {state}.");

foreach (var column in new[]
{
  "CorrelationId", "DedupKey", "PayloadHash", "ExpectedEchoHash",
  "LeaseOwner", "LeaseUntilUtc", "NextAttemptUtc", "ResponseStatusCode",
  "ResponseBodyRedacted", "EndpointTemplate", "HttpOperation", "ApprovalMode"
}) Contains(migration, column, $"Manjka lastnost {column}.");

Contains(migration, "UPDLOCK, READPAST, ROWLOCK", "Claim ne uporablja atomskega zaklepa vrste.");
Contains(migration, "SYSUTCDATETIME()", "Prehodi ne uporabljajo UTC časa.");
Contains(migration, "ManualApproval", "Privzeti profil ne zahteva ročne odobritve.");
Contains(migration, "POST", "Pogodba ne omejuje operacije POST.");
Contains(migration, "PATCH", "Pogodba ne omejuje operacije PATCH.");
var migrator = Read("src/PIM.Migrator/Program.cs");
Contains(migrator, "VerifyF8Async(connection)", "--verify ne preverja F8 podatkovnega kontrakta.");
Contains(migrator, "out.OutboxMessage", "Migrator ne preveri tabele F8 OutboxMessage.");
Contains(migrator, "intranet.GetOutboundMessages", "Migrator ne preveri intranetnega pregleda F8.");
if (migration.Contains("PIM_test", StringComparison.OrdinalIgnoreCase)) failures.Add("F8 ne sme dostopati do PIM_test.");

if (failures.Count > 0)
{
  Console.Error.WriteLine("F8 contract RED:");
  failures.ForEach(failure => Console.Error.WriteLine("- " + failure));
  return 1;
}
Console.WriteLine("F8 contract: generična odhodna pošta PASS.");
return 0;

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

string Read(string path)
{
  var fullPath = Path.Combine(root, path);
  if (File.Exists(fullPath)) return File.ReadAllText(fullPath);
  failures.Add("Manjka " + path);
  return "";
}

void Contains(string text, string expected, string failure)
{
  if (!text.Contains(expected, StringComparison.OrdinalIgnoreCase)) failures.Add(failure);
}
