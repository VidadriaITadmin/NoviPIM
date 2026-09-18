using System.Data;
using Microsoft.Data.SqlClient;
using PIM.Operations;
using PIM.StockReplenishmentWorker;

/*
  PIM.StockReplenishmentWorker — dnevni mail o artiklih, ki so padli na ali pod MID prag
  (MIN_MAX_proces.docx, migracija 200). Teče enkrat na dan (ponoči), da prejemniki zjutraj dobijo
  pregled po dobavitelju in kategoriji. Mail gre ven tudi, če ni nič pod pragom ("danes ni nič").

  Ne kliče SAOP: bere samo bazo (zaloga, naročila, pravila), ki jo polnijo drugi delavci
  (PIM.SaopStockWorker, PIM.SaopOrdersWorker). Prejemniki so PIM uporabniki s kljukico
  "Zaloga pod MID" (sec.LocalUser.ReceivesStockReplenishmentEmail) in nastavljenim naslovom.

  --dry-run zapiše sestavljen HTML v datoteko namesto pošiljanja — za preverjanje vsebine z
  resničnimi podatki, ne da bi kdo dobil testni mail.
*/

const string Pipeline = "STOCK_REPLENISHMENT_DIGEST";

if (args.Contains("--help", StringComparer.OrdinalIgnoreCase) || args.Contains("-h", StringComparer.OrdinalIgnoreCase))
{
  PrintUsage();
  return 0;
}

var organizationFilter = ParseOrganizationFilter(args);
var dryRun = args.Contains("--dry-run", StringComparer.OrdinalIgnoreCase);
var dryRunDirectory = dryRun ? Path.Combine(AppContext.BaseDirectory, "dry-run") : null;

var connectionString = LocalSettings.ConnectionString();
if (string.IsNullOrWhiteSpace(connectionString))
{
  Console.Error.WriteLine(LocalSettings.MissingConnectionMessage());
  return 2;
}

var emailOptions = DigestEmailOptions.FromEnvironment();
using var http = new HttpClient();
var sender = new DigestEmailSender(emailOptions, http);
if (!dryRun && !emailOptions.Enabled)
{
  Console.WriteLine("OPOZORILO: pošiljanje e-pošte je izklopljeno (PIM_ALERT_EMAIL_ENABLED ni true). Povzetek se sestavi, a se ne pošlje.");
}

var organizations = await ReadOrganizationsAsync(connectionString, organizationFilter);
if (organizations.Count == 0)
{
  Console.Error.WriteLine("Ni organizacije z omogočenim razporedom STOCK_REPLENISHMENT_DIGEST, ki bi ustrezala izbiri.");
  return 2;
}

var recipients = await ReadRecipientsAsync(connectionString);
Console.WriteLine($"Prejemnikov s kljukico in naslovom: {recipients.Count}.");
if (recipients.Count == 0 && !dryRun)
{
  Console.WriteLine("OPOZORILO: nihče ni odkljukan za ta mail (Sistem → Uporabniki → Zaloga pod MID). Povzetek se sestavi, a nima komu iti.");
}

var failedAny = false;
foreach (var organization in organizations)
{
  Console.WriteLine($"[{organization.Id}] {organization.Name}");
  await using var operationsRun = await OperationsRun.BeginAsync(
    connectionString, organization.Id, Pipeline, $"{Environment.MachineName}:{Environment.ProcessId}");

  try
  {
    await using var connection = new SqlConnection(connectionString);
    await connection.OpenAsync();

    var refreshed = await RefreshMidAsync(connection);
    Console.WriteLine($"  MID osvežen: {refreshed} vrstic.");

    var rows = await ReadBelowMidAsync(connection, organization.Id);
    Console.WriteLine($"  Artiklov na ali pod MID: {rows.Count} (dobaviteljev: {rows.Select(r => r.Supplier ?? "").Distinct().Count()}).");

    var generatedUtc = DateTime.UtcNow;
    var html = DigestHtmlBuilder.Build(organization.Name, generatedUtc, rows);
    var subject = $"PIM — Zaloga pod MID ({organization.Name}) — {generatedUtc:dd.MM.yyyy}";

    if (dryRun)
    {
      Directory.CreateDirectory(dryRunDirectory!);
      var path = Path.Combine(dryRunDirectory!, $"digest-{organization.Id}-{generatedUtc:yyyyMMdd-HHmmss}.html");
      await File.WriteAllTextAsync(path, html);
      Console.WriteLine($"  SUHI TEK: HTML zapisan v {path}; nič ni poslano.");
    }
    else
    {
      var delivered = 0;
      foreach (var recipient in recipients)
      {
        var outcome = await sender.SendAsync(subject, html, recipient);
        Console.WriteLine($"  {recipient}: {outcome}");
        if (outcome == DigestSendOutcome.Delivered) delivered++;
      }
      Console.WriteLine($"  Poslano: {delivered} od {recipients.Count}.");
    }

    await operationsRun.CompleteAsync(true);
  }
  catch (Exception exception)
  {
    Console.Error.WriteLine($"  Organizacija {organization.Id} je padla: {exception.Message}");
    await operationsRun.CompleteAsync(false, exception.Message[..Math.Min(2000, exception.Message.Length)]);
    failedAny = true;
  }
}

return failedAny ? 1 : 0;

static async Task<IReadOnlyList<(int Id, string Name)>> ReadOrganizationsAsync(string connectionString, IReadOnlyList<int> filter)
{
  await using var connection = new SqlConnection(connectionString);
  await connection.OpenAsync();
  await using var command = new SqlCommand("""
    SELECT organization.OrganizationId, organization.Name
    FROM dbo.OrganizationConfig organization
    INNER JOIN ops.ScheduleProfile profile ON profile.OrganizationId = organization.OrganizationId
      AND profile.Pipeline = @Pipeline AND profile.IsEnabled = 1
    WHERE organization.IsActive = 1
    ORDER BY organization.OrganizationId;
    """, connection);
  command.Parameters.AddWithValue("@Pipeline", Pipeline);
  await using var reader = await command.ExecuteReaderAsync();
  var organizations = new List<(int, string)>();
  while (await reader.ReadAsync())
  {
    var id = reader.GetInt32(0);
    if (filter.Count > 0 && !filter.Contains(id)) continue;
    organizations.Add((id, reader.GetString(1)));
  }
  return organizations;
}

static async Task<IReadOnlyList<string>> ReadRecipientsAsync(string connectionString)
{
  await using var connection = new SqlConnection(connectionString);
  await connection.OpenAsync();
  await using var command = new SqlCommand("""
    SELECT DISTINCT LTRIM(RTRIM(Email))
    FROM sec.LocalUser
    WHERE ReceivesStockReplenishmentEmail = 1 AND IsEnabled = 1 AND NULLIF(LTRIM(RTRIM(Email)), N'') IS NOT NULL
    ORDER BY 1;
    """, connection);
  await using var reader = await command.ExecuteReaderAsync();
  var recipients = new List<string>();
  while (await reader.ReadAsync()) recipients.Add(reader.GetString(0));
  return recipients;
}

static async Task<int> RefreshMidAsync(SqlConnection connection)
{
  await using var command = new SqlCommand("stock.RefreshStockPolicyMid", connection) { CommandType = CommandType.StoredProcedure };
  var value = await command.ExecuteScalarAsync();
  return value is int count ? count : 0;
}

static async Task<IReadOnlyList<ReplenishmentRow>> ReadBelowMidAsync(SqlConnection connection, int organizationId)
{
  await using var command = new SqlCommand("stock.GetBelowMidReplenishment", connection) { CommandType = CommandType.StoredProcedure, CommandTimeout = 300 };
  command.Parameters.AddWithValue("@OrganizationId", organizationId);
  await using var reader = await command.ExecuteReaderAsync();
  // Po imenu stolpca, ne po zaporedju: proc se je enkrat že spremenil (dodan SupplierName), zaporedje
  // pa je takrat premaknilo vse indekse za enega naprej in tiho pokvarilo branje.
  var rows = new List<ReplenishmentRow>();
  while (await reader.ReadAsync())
  {
    rows.Add(new ReplenishmentRow(
      ItemID: reader.GetString(reader.GetOrdinal("ItemID")),
      ItemName: reader.IsDBNull(reader.GetOrdinal("ItemName")) ? null : reader.GetString(reader.GetOrdinal("ItemName")),
      Supplier: reader.IsDBNull(reader.GetOrdinal("Supplier")) ? null : reader.GetString(reader.GetOrdinal("Supplier")),
      SupplierName: reader.IsDBNull(reader.GetOrdinal("SupplierName")) ? null : reader.GetString(reader.GetOrdinal("SupplierName")),
      Department: reader.IsDBNull(reader.GetOrdinal("Department")) ? null : reader.GetString(reader.GetOrdinal("Department")),
      CurrentStock: reader.GetInt32(reader.GetOrdinal("CurrentStock")),
      MaximumStock: reader.IsDBNull(reader.GetOrdinal("MaximumStock")) ? null : reader.GetInt32(reader.GetOrdinal("MaximumStock")),
      MidStock: reader.IsDBNull(reader.GetOrdinal("MidStock")) ? null : reader.GetInt32(reader.GetOrdinal("MidStock")),
      MinimumStock: reader.IsDBNull(reader.GetOrdinal("MinimumStock")) ? null : reader.GetInt32(reader.GetOrdinal("MinimumStock")),
      AvailableStock: reader.GetInt32(reader.GetOrdinal("AvailableStock")),
      IncomingPurchaseQty: reader.IsDBNull(reader.GetOrdinal("IncomingPurchaseQty")) ? null : reader.GetInt32(reader.GetOrdinal("IncomingPurchaseQty"))));
  }
  return rows;
}

static IReadOnlyList<int> ParseOrganizationFilter(string[] args)
{
  var index = Array.FindIndex(args, a => string.Equals(a, "--organizations", StringComparison.OrdinalIgnoreCase));
  if (index < 0 || index + 1 >= args.Length) return [];
  return args[index + 1]
    .Split([',', ';'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
    .Select(token => int.TryParse(token, out var id) ? id : (int?)null)
    .Where(id => id is not null)
    .Select(id => id!.Value)
    .ToArray();
}

static void PrintUsage()
{
  Console.WriteLine("""
    PIM.StockReplenishmentWorker — dnevni mail o artiklih na ali pod MID pragu, po dobavitelju in kategoriji.

    Argumenti:
      --organizations 2,3   samo našteta podjetja (privzeto vsa z omogočenim razporedom)
      --dry-run             sestavi HTML in ga zapiše v bin/.../dry-run/, nič ne pošlje
      --help                ta izpis

    Prejemniki: Sistem → Uporabniki → kljukica "Zaloga pod MID" + nastavljen naslov e-pošte.
    Pošiljanje: iste okoljske spremenljivke kot PIM.AlertDispatcher (PIM_ALERT_EMAIL_ENABLED,
    PIM_ALERT_EMAIL_PROVIDER, PIM_SMTP_*, PIM_RESEND_API_KEY).
    """);
}
