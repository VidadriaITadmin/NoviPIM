using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Data.SqlClient;
using PIM.Operations;

var connectionString = LocalSettings.ConnectionString();

if (string.IsNullOrWhiteSpace(connectionString))
{
  Console.Error.WriteLine(LocalSettings.MissingConnectionMessage() + " Connection string ni zapisan v repozitorij.");
  return 2;
}

var verifyOnly = args.Contains("--verify", StringComparer.OrdinalIgnoreCase);
var createDatabase = args.Contains("--create-database", StringComparer.OrdinalIgnoreCase);
var showMigrations = args.Contains("--show-migrations", StringComparer.OrdinalIgnoreCase);
var showOutputContract = args.Contains("--show-output-contract", StringComparer.OrdinalIgnoreCase);

// Prvega skrbnika na novem racunalniku ni komu ustvariti: strani za uporabnike ni mogoce odpreti
// brez prijave, prijave pa ni brez racuna. Migrator je edino orodje, ki se na prazni bazi ze
// zaganja, zato zna racun ustvariti. Geslo se ne podaja kot argument - v zgodovini ukazov bi
// ostalo v cistopisu.
var adminIndex = Array.FindIndex(args, argument => argument.Equals("--ustvari-admina", StringComparison.OrdinalIgnoreCase));
if (adminIndex >= 0)
{
  if (adminIndex + 1 >= args.Length)
  {
    Console.Error.WriteLine("--ustvari-admina potrebuje uporabnisko ime, na primer: --ustvari-admina david");
    return 2;
  }

  return await UstvariAdminaAsync(connectionString!, args[adminIndex + 1]);
}
var migrationsDirectory = ResolveMigrationsDirectory(args);

if (!Directory.Exists(migrationsDirectory))
{
  Console.Error.WriteLine($"Mapa z migracijami ne obstaja: {migrationsDirectory}");
  return 2;
}

var migrations = Directory.GetFiles(migrationsDirectory, "*.sql")
  .Select(path => new Migration(Path.GetFileName(path), File.ReadAllText(path)))
  .OrderBy(migration => migration.Name, StringComparer.Ordinal)
  .ToArray();

if (migrations.Length == 0 || migrations.Any(migration => !Regex.IsMatch(migration.Name, "^\\d{3}_[A-Za-z0-9][A-Za-z0-9_-]*\\.sql$", RegexOptions.CultureInvariant)))
{
  Console.Error.WriteLine("Migracije morajo biti oštevilčene kot NNN_Opis.sql.");
  return 2;
}

if (createDatabase)
{
  await EnsureDatabaseAsync(connectionString);
}

await using var connection = new SqlConnection(connectionString);
try
{
  await connection.OpenAsync();
}
catch (SqlException exception)
{
  Console.Error.WriteLine($"Povezava z MSSQL ni uspela: {exception.Message}");
  return 1;
}
await EnsureMigrationLedgerAsync(connection);

if (showMigrations)
{
  await ShowMigrationsAsync(connection);
  return 0;
}

if (showOutputContract)
{
  await ShowOutputContractAsync(connection);
  return 0;
}

if (verifyOnly)
{
  await VerifyF0Async(connection, migrations);
  await VerifyF1Async(connection);
  await VerifyF2Async(connection);
  await VerifyF3Async(connection);
  await VerifyF6Async(connection);
  await VerifyF7Async(connection);
  await VerifyF8Async(connection);
  await VerifyF9Async(connection);
  await VerifyF10Async(connection);
  Console.WriteLine("Preverjanje F0–F10 baze je uspešno.");
  return 0;
}

string? currentMigration = null;
await using var transaction = (SqlTransaction)await connection.BeginTransactionAsync();
try
{
  await AcquireMigrationLockAsync(connection, transaction);

  foreach (var migration in migrations)
  {
    currentMigration = migration.Name;
    var scriptHash = ScriptHash(migration.Script);
    var storedHash = await ReadMigrationHashAsync(connection, transaction, migration.Name);

    if (storedHash is not null)
    {
      if (!MatchesStoredHash(storedHash, migration.Script))
      {
        throw new InvalidOperationException($"Vsebina že uporabljene migracije {migration.Name} je bila spremenjena.");
      }

      Console.WriteLine($"Preskočena že uporabljena migracija: {migration.Name}");
      continue;
    }

    await ExecuteAsync(connection, transaction, migration.Script);
    await InsertMigrationAsync(connection, transaction, migration.Name, scriptHash);
    Console.WriteLine($"Uporabljena migracija: {migration.Name}");
  }

  await transaction.CommitAsync();
  Console.WriteLine("Migracije so uspešno uporabljene.");
  return 0;
}
catch (Exception exception)
{
  // Ob SET XACT_ABORT ON (ali časovni omejitvi) strežnik transakcijo že sam razveljavi;
  // RollbackAsync takrat vrže NullReferenceException in prekrije pravo napako iz skripte.
  try { await transaction.RollbackAsync(); }
  catch (Exception rollbackException) { Console.Error.WriteLine($"Rollback ni uspel (transakcija je verjetno že razveljavljena): {rollbackException.Message}"); }
  Console.Error.WriteLine($"Migracija {currentMigration ?? "?"} ni uspela: {exception.Message}");
  throw;
}

// Hash je neodvisen od koncev vrstic: git s core.autocrlf isto datoteko enkrat odloži z LF in
// drugič s CRLF (2026-09-15 je bila 195_ReclaimStaleSendingDocuments.sql uveljavljena z LF, po
// ponovnem checkoutu pa je bila CRLF), migrator pa je to javil kot spremenjeno vsebino in
// razveljavil vse migracije v isti transakciji. Vsebinska sprememba ostane napaka.
static string ScriptHash(string script)
  => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(NormalizeLineEndings(script)))).ToLowerInvariant();

static string NormalizeLineEndings(string script) => script.Replace("\r\n", "\n").Replace('\r', '\n');

// Stari zapisi v dbo.SchemaMigration so bili hashirani iz surove vsebine, ki je bila lahko LF ali
// CRLF; oba sprejmemo, da obstoječih ledgerjev (tudi produkcijskega) ni treba prepisovati.
static bool MatchesStoredHash(string storedHash, string script)
{
  var normalized = NormalizeLineEndings(script);
  string[] candidates =
  [
    ScriptHash(script),
    RawHash(normalized.Replace("\n", "\r\n")),
    RawHash(script),
  ];
  return candidates.Any(candidate => string.Equals(storedHash, candidate, StringComparison.OrdinalIgnoreCase));

  static string RawHash(string text) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text))).ToLowerInvariant();
}

static string ResolveMigrationsDirectory(string[] arguments)
{
  var optionIndex = Array.FindIndex(arguments, argument => string.Equals(argument, "--migrations", StringComparison.OrdinalIgnoreCase));
  if (optionIndex >= 0)
  {
    if (optionIndex == arguments.Length - 1)
    {
      throw new ArgumentException("Manjka vrednost za --migrations.");
    }

    return Path.GetFullPath(arguments[optionIndex + 1]);
  }

  var configuredPath = Environment.GetEnvironmentVariable("PIM_MIGRATIONS_PATH");
  if (!string.IsNullOrWhiteSpace(configuredPath))
  {
    return Path.GetFullPath(configuredPath);
  }

  var current = new DirectoryInfo(Directory.GetCurrentDirectory());
  while (current is not null)
  {
    var candidate = Path.Combine(current.FullName, "sql", "migrations");
    if (Directory.Exists(candidate))
    {
      return candidate;
    }

    current = current.Parent;
  }

  return Path.Combine(Directory.GetCurrentDirectory(), "sql", "migrations");
}

static async Task EnsureMigrationLedgerAsync(SqlConnection connection)
{
  const string sql = """
    IF OBJECT_ID(N'dbo.SchemaMigration', N'U') IS NULL
    BEGIN
      CREATE TABLE dbo.SchemaMigration
      (
        MigrationId nvarchar(255) NOT NULL,
        ScriptHash char(64) NOT NULL,
        AppliedUtc datetime2(3) NOT NULL CONSTRAINT DF_SchemaMigration_AppliedUtc DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_SchemaMigration PRIMARY KEY CLUSTERED (MigrationId)
      );
    END;
    """;

  await ExecuteAsync(connection, null, sql);
}

static async Task EnsureDatabaseAsync(string connectionString)
{
  var targetConnection = new SqlConnectionStringBuilder(connectionString);
  var databaseName = targetConnection.InitialCatalog;
  if (string.IsNullOrWhiteSpace(databaseName) || !Regex.IsMatch(databaseName, "^[A-Za-z][A-Za-z0-9_]{0,127}$", RegexOptions.CultureInvariant))
  {
    throw new ArgumentException("Connection string mora vsebovati veljavno ime ciljne baze.");
  }

  targetConnection.InitialCatalog = "master";
  await using var connection = new SqlConnection(targetConnection.ConnectionString);
  try
  {
    await connection.OpenAsync();
  }
  catch (SqlException exception)
  {
    Console.Error.WriteLine($"Povezava z MSSQL za ustvarjanje baze ni uspela: {exception.Message}");
    return;
  }

  const string sql = """
    IF DB_ID(@DatabaseName) IS NULL
    BEGIN
      DECLARE @CreateDatabaseSql nvarchar(300) = N'CREATE DATABASE ' + QUOTENAME(@DatabaseName) + N';';
      EXEC(@CreateDatabaseSql);
    END;
    """;
  await using var command = new SqlCommand(sql, connection);
  command.Parameters.AddWithValue("@DatabaseName", databaseName);
  await command.ExecuteNonQueryAsync();
  Console.WriteLine($"Baza {databaseName} je pripravljena.");
}

static async Task AcquireMigrationLockAsync(SqlConnection connection, SqlTransaction transaction)
{
  await using var command = new SqlCommand("EXEC @result = sp_getapplock @Resource = N'PIM.SchemaMigration', @LockMode = N'Exclusive', @LockOwner = N'Transaction', @LockTimeout = 60000;", connection, transaction);
  var result = command.Parameters.Add("@result", System.Data.SqlDbType.Int);
  result.Direction = System.Data.ParameterDirection.Output;
  await command.ExecuteNonQueryAsync();

  if ((int)result.Value < 0)
  {
    throw new InvalidOperationException("Migracijske ključavnice ni bilo mogoče pridobiti v 60 sekundah.");
  }
}

static async Task<string?> ReadMigrationHashAsync(SqlConnection connection, SqlTransaction transaction, string migrationName)
{
  await using var command = new SqlCommand("SELECT ScriptHash FROM dbo.SchemaMigration WHERE MigrationId = @MigrationId;", connection, transaction);
  command.Parameters.AddWithValue("@MigrationId", migrationName);
  return (string?)await command.ExecuteScalarAsync();
}

static async Task InsertMigrationAsync(SqlConnection connection, SqlTransaction transaction, string migrationName, string scriptHash)
{
  await using var command = new SqlCommand("INSERT dbo.SchemaMigration (MigrationId, ScriptHash) VALUES (@MigrationId, @ScriptHash);", connection, transaction);
  command.Parameters.AddWithValue("@MigrationId", migrationName);
  command.Parameters.AddWithValue("@ScriptHash", scriptHash);
  await command.ExecuteNonQueryAsync();
}

static async Task ExecuteAsync(SqlConnection connection, SqlTransaction? transaction, string sql)
{
  // Brez casovne omejitve: podatkovne migracije (197 je pobrisala ~6,5 GB PayloadXml) trajajo
  // vec minut, 120 s pa je prekinilo skripto sredi dela in razveljavilo vse migracije v paketu.
  // Socasnost varuje sp_getapplock, zato blokada ne more viseti v nedogled brez vidnega vzroka.
  await using var command = new SqlCommand(sql, connection, transaction)
  {
    CommandTimeout = 0
  };
  await command.ExecuteNonQueryAsync();
}

static async Task VerifyF0Async(SqlConnection connection, IReadOnlyCollection<Migration> migrations)
{
  foreach (var migration in migrations)
  {
    await using var command = new SqlCommand("SELECT ScriptHash FROM dbo.SchemaMigration WHERE MigrationId = @MigrationId;", connection);
    command.Parameters.AddWithValue("@MigrationId", migration.Name);
    var actualHash = (string?)await command.ExecuteScalarAsync();
    if (actualHash is null || !MatchesStoredHash(actualHash, migration.Script))
    {
      throw new InvalidOperationException($"Migracijska sled za {migration.Name} manjka ali ne ustreza vsebini skripte.");
    }
  }

  var expectedSchemas = new[] { "raw", "map", "canon", "val", "pim", "out", "ops", "dbo", "sec", "stock" };
  foreach (var schema in expectedSchemas)
  {
    await AssertCountAsync(connection, "SELECT COUNT(*) FROM sys.schemas WHERE name = @value;", schema, 1, $"Manjka shema {schema}.");
  }

  var expectedObjects = new[]
  {
    // ops.Heartbeat je spuscena v migraciji 144: imela je nic vrstic in nobenega pisca,
    // nasledila jo je ops.IntegrationHealth. Prazna tabela je past — naslednji, ki jo najde,
    // domneva, da nekaj pomeni.
    "ops.PipelineRun", "ops.PipelineStepLog", "ops.DeadLetterQueue", "ops.ErrorLog", "dbo.OrganizationConfig",
    "ops.LogError", "ops.EnqueueDeadLetter", "ops.RecordPipelineStep"
  };
  foreach (var expectedObject in expectedObjects)
  {
    await AssertCountAsync(connection, "SELECT COUNT(*) FROM sys.objects WHERE object_id = OBJECT_ID(@value);", expectedObject, 1, $"Manjka objekt {expectedObject}.");
  }

  await AssertAtLeastAsync(connection, "SELECT COUNT(*) FROM dbo.OrganizationConfig;", 4, "OrganizationConfig mora vsebovati najmanj štiri začetne organizacije.");
}

static async Task ShowOutputContractAsync(SqlConnection connection)
{
  const string sql = """
    SELECT validationProfile.ProfileCode,
           COUNT(DISTINCT exportColumn.ExportColumnId) AS ActiveExportColumns,
           COUNT(DISTINCT fieldRequirement.FieldRequirementId) AS ActiveGeneratedRequirements
    FROM val.ValidationProfile validationProfile
    LEFT JOIN out.ExportColumn exportColumn
      ON exportColumn.ExportProfileId = validationProfile.ExportProfileId
     AND exportColumn.IsActive = 1
    LEFT JOIN val.FieldRequirement fieldRequirement
      ON fieldRequirement.ValidationProfileId = validationProfile.ValidationProfileId
     AND fieldRequirement.IsActive = 1
    WHERE validationProfile.IsActive = 1
    GROUP BY validationProfile.ProfileCode
    ORDER BY validationProfile.ProfileCode;
    """;
  await using var command = new SqlCommand(sql, connection);
  await using var reader = await command.ExecuteReaderAsync();
  Console.WriteLine("ValidationProfile | ActiveExportColumns | ActiveGeneratedRequirements");
  while (await reader.ReadAsync())
  {
    Console.WriteLine($"{reader.GetString(0)} | {reader.GetInt32(1)} | {reader.GetInt32(2)}");
  }
}

static async Task ShowMigrationsAsync(SqlConnection connection)
{
  const string sql = """
    SELECT TOP (3) MigrationId, ScriptHash, AppliedUtc
    FROM dbo.SchemaMigration
    ORDER BY AppliedUtc DESC, MigrationId DESC;
    """;
  await using var command = new SqlCommand(sql, connection);
  await using var reader = await command.ExecuteReaderAsync();
  Console.WriteLine("MigrationId | ScriptHash | AppliedUtc");
  while (await reader.ReadAsync())
  {
    Console.WriteLine($"{reader.GetString(0)} | {reader.GetString(1)} | {reader.GetDateTime(2):O}");
  }
}

static async Task VerifyF1Async(SqlConnection connection)
{
  var expectedObjects = new[]
  {
    "out.ExportProfile", "out.ExportColumn", "val.ValidationProfile", "val.FieldRequirement", "val.SyncFieldRequirementsFromExportProfiles"
  };
  foreach (var expectedObject in expectedObjects)
  {
    await AssertCountAsync(connection, "SELECT COUNT(*) FROM sys.objects WHERE object_id = OBJECT_ID(@value);", expectedObject, 1, $"Manjka F1 objekt {expectedObject}.");
  }

  /* 2026-09-16: ERP_L1 in WEB_B2C sta bila po uporabnikovi odlocitvi umaknjena iz validacije
     (nadomestila sta ju ERP_L1_EU/SLO/THIRD/SHARED_CORE in WEB_svetila_si/WEB_videlektro/
     SHARED_CORE) - preverba zdaj zahteva vsaj en aktiven blokirajoc profil na vsako stran, ne
     vec ti dve konkretni, zdaj neaktivni/nescinkovito imeni. */
  await AssertAtLeastAsync(connection, "SELECT COUNT(*) FROM val.ValidationProfile WHERE BlocksErp = 1 AND IsActive = 1;", 1, "Ni nobenega aktivnega validacijskega profila, ki bi blokiral ERP.");
  await AssertAtLeastAsync(connection, "SELECT COUNT(*) FROM val.ValidationProfile WHERE BlocksWeb = 1 AND IsActive = 1;", 1, "Ni nobenega aktivnega validacijskega profila, ki bi blokiral splet.");
  await AssertCountAsync(connection, """
    SELECT COUNT(*)
    FROM out.ExportColumn exportColumn
    INNER JOIN val.ValidationProfile validationProfile ON validationProfile.ExportProfileId = exportColumn.ExportProfileId
    WHERE exportColumn.IsActive = 1
      AND exportColumn.IsRequired = 1
      AND NOT EXISTS
      (
        SELECT 1
        FROM val.FieldRequirement requirement
        WHERE requirement.ValidationProfileId = validationProfile.ValidationProfileId
          AND requirement.SourceExportColumnId = exportColumn.ExportColumnId
          AND requirement.FieldCode = exportColumn.CanonicalFieldCode
          AND requirement.IsRequired = 1
          AND requirement.IsActive = 1
      );
    """, null, 0, "Aktiven obvezen izvozni stolpec nima skladnega generiranega validacijskega zahtevka.");
}

static async Task VerifyF2Async(SqlConnection connection)
{
  var expectedObjects = new[]
  {
    "canon.Product", "canon.ProductText", "canon.ProductAttribute", "canon.ProductCategory", "canon.ProductMedia",
    "canon.ProductPrice", "canon.ProductCommercial", "canon.FieldValue", "val.ProductIssue",
    "val.ProductValidationState", "val.RunValidation", "val.Promote", "pim.Product"
  };
  foreach (var expectedObject in expectedObjects)
  {
    await AssertCountAsync(connection, "SELECT COUNT(*) FROM sys.objects WHERE object_id = OBJECT_ID(@value);", expectedObject, 1, $"Manjka F2 objekt {expectedObject}.");
  }
}

static async Task VerifyF3Async(SqlConnection connection)
{
  var expectedObjects = new[]
  {
    "raw.Inbox", "map.SourceConnector", "map.FieldMapping", "map.Watermark", "map.PipelineStep",
    "map.ProcessRawInbox", "map.RunSaopProducts", "out.ExportProductsCsv"
  };
  foreach (var expectedObject in expectedObjects)
  {
    await AssertCountAsync(connection, "SELECT COUNT(*) FROM sys.objects WHERE object_id = OBJECT_ID(@value);", expectedObject, 1, $"Manjka F3 objekt {expectedObject}.");
  }

  await AssertCountAsync(connection, "SELECT COUNT(*) FROM map.SourceConnector WHERE SourceCode=N'SAOP_IQLIGHTING' AND OrganizationId=2 AND IsActive=1;", null, 1, "Manjka aktivni SAOP konektor za IQLighting.");
  await AssertCountAsync(connection, "SELECT COUNT(*) FROM map.PipelineStep WHERE PipelineCode=N'SAOP_PRODUCTS' AND IsActive=1;", null, 3, "SAOP pipeline mora imeti tri aktivne korake.");
}

static async Task VerifyF6Async(SqlConnection connection)
{
  var expectedObjects = new[]
  {
    "stock.SaopProviderProfile", "map.StockIdentityRule", "stock.LandingRecord", "stock.Snapshot",
    "stock.Position", "stock.UnmatchedPosition", "stock.SyncRun", "stock.ApplyLandingRecord",
    "intranet.GetStocks", "out.ExportStockCsv"
  };
  foreach (var expectedObject in expectedObjects)
  {
    await AssertCountAsync(connection, "SELECT COUNT(*) FROM sys.objects WHERE object_id=OBJECT_ID(@value);", expectedObject, 1, $"Manjka F6 objekt {expectedObject}.");
  }
  await AssertCountAsync(connection, "SELECT COUNT(*) FROM sys.indexes WHERE object_id=OBJECT_ID(N'stock.Position') AND name=N'IX_stock_Position_Identity';", null, 1, "Manjka F6 indeks identitete.");
  await AssertCountAsync(connection, "SELECT COUNT(*) FROM map.StockIdentityRule ruleValue INNER JOIN map.SourceConnector connector ON connector.SourceConnectorId=ruleValue.SourceConnectorId WHERE connector.OrganizationId=2 AND connector.SourceCode IN (N'NW_STOCK',N'BT_STOCK') AND ruleValue.IsActive=1;", null, 2, "Manjkajo aktivna F6 identitetna pravila v konfiguraciji.");
}

static async Task VerifyF7Async(SqlConnection connection)
{
  var expectedObjects = new[]
  {
    "b2b.Customer", "pim.CustomerTypeCatalog", "pim.CustomerWebProfile", "pim.PackagingDiscountCatalog",
    "pim.ValueDiscountTier", "pim.ShippingRuleCatalog", "b2b.GroupDiscountOverride", "b2b.AuditLog",
    "b2b.LandingRecord", "map.B2bFieldMapping", "b2b.MappingRejection", "b2b.ApplyLandingRecord",
    "b2b.ReplayLandingRecord", "out.ExportB2bCustomersCsv", "out.ExportB2bProductsCsv",
    "out.ExportPriceList",
    // 142: spletni CSV (katalog in stranke) nastane iz tabel, ne iz datoteke na disku.
    "out.MagentoNumber", "out.GetExportRows", "intranet.GetWebExportRows"
  };
  foreach (var expectedObject in expectedObjects)
    await AssertCountAsync(connection, "SELECT COUNT(*) FROM sys.objects WHERE object_id=OBJECT_ID(@value);", expectedObject, 1, $"Manjka F7 objekt {expectedObject}.");

  // Brez vira vrednosti profil ne more roditi vrstic: izvoz bi vrgel napako sele ob kliku.
  await AssertCountAsync(connection,
    "SELECT COUNT(*) FROM out.ExportProfile WHERE ProfileCode=N'MAGENTO_PRODUCTS' AND IsActive=1 AND ValueSourceCode=N'PIM_PRODUCT';",
    null, 1, "Profil MAGENTO_PRODUCTS mora brati vrednosti iz sloja pim.");
  await AssertCountAsync(connection,
    "SELECT COUNT(*) FROM out.ExportProfile WHERE ProfileCode=N'MAGENTO_CUSTOMERS' AND IsActive=1 AND ValueSourceCode=N'PIM_CUSTOMER';",
    null, 1, "Profil MAGENTO_CUSTOMERS mora brati vrednosti iz sloja b2b in pim.");
  await AssertCountAsync(connection, "SELECT COUNT(*) FROM pim.CustomerTypeCatalog WHERE IsActive=1;", null, 18, "F7 mora imeti 18 aktivnih tipov strank.");
  await AssertCountAsync(connection, "SELECT COUNT(*) FROM pim.PackagingDiscountCatalog WHERE IsActive=1 AND DiscountCode IN(N'S1',N'S2',N'S3',N'S4');", null, 4, "Manjkajo F7 S-stopnje.");
  await AssertCountAsync(connection, "SELECT COUNT(*) FROM pim.ValueDiscountTier WHERE IsActive=1;", null, 3, "F7 mora imeti tri vrednostne pragove.");
  await AssertCountAsync(connection, "SELECT COUNT(*) FROM pim.ShippingRuleCatalog WHERE IsActive=1;", null, 4, "Manjkajo poštninska pravila F7.");
  await AssertCountAsync(connection, "SELECT COUNT(*) FROM out.ExportProfile WHERE ProfileCode IN(N'CUSTOMERS_B2B',N'PRODUCTS_B2B') AND IsActive=1;", null, 2, "Manjkata aktivna B2B izvozna profila.");
  await AssertCountAsync(connection, "SELECT COUNT(*) FROM sec.Role WHERE RoleCode IN(N'ADMIN',N'CATALOG_EDITOR',N'COMMERCIAL');", null, 3, "Manjkajo eksplicitne F7 vloge.");
}

static async Task VerifyF8Async(SqlConnection connection)
{
  var expectedObjects = new[]
  {
    "out.OutboxMessage", "out.OutboxAttempt", "out.OwnershipPolicy", "dbo.IntegrationProfile",
    "out.EnqueueMessage", "out.ApproveMessage", "out.CancelMessage", "out.RetryMessage",
    "out.ClaimMessage", "out.CompleteAttempt", "out.VerifyEcho",
    "out.SaopItemAssignment", "out.ResolveSaopItemAssignment",
    "intranet.GetOutboundMessages", "intranet.GetOutboundMessage"
  };
  foreach (var expectedObject in expectedObjects)
    await AssertCountAsync(connection, "SELECT COUNT(*) FROM sys.objects WHERE object_id=OBJECT_ID(@value);", expectedObject, 1, $"Manjka F8 objekt {expectedObject}.");
  await AssertCountAsync(connection, "SELECT COUNT(*) FROM sys.indexes WHERE object_id=OBJECT_ID(N'out.OutboxMessage') AND name=N'UX_OutboxMessage_ActiveDedup';", null, 1, "Manjka F8 aktivni dedup indeks.");
  // Migracija 046: brez teh dveh se odhodna pot tiho vrne na "vsaka napaka je enaka" in
  // "nadomeščeno sporočilo je videti kot nepotrjeno".
  await AssertCountAsync(connection, "SELECT COUNT(*) FROM sys.columns WHERE object_id=OBJECT_ID(N'out.OutboxMessage') AND name=N'ErrorClass';", null, 1, "Manjka F8 stolpec out.OutboxMessage.ErrorClass.");
  await AssertCountAsync(connection, "SELECT COUNT(*) FROM sys.check_constraints WHERE name=N'CK_OutboxMessage_Status' AND definition LIKE N'%Superseded%';", null, 1, "F8 stanje Superseded ni dovoljeno v CK_OutboxMessage_Status.");
  // Migracija 169: brez tega stolpca bi izbira POST/PATCH spet sklepala iz obstoja vrstice v
  // canon.Product in bi za artikel, ki je v PIM, v SAOP pa ne, izbrala PATCH.
  await AssertCountAsync(connection, "SELECT COUNT(*) FROM sys.columns WHERE object_id=OBJECT_ID(N'canon.Product') AND name=N'ErpExistence';", null, 1, "Manjka F8 stolpec canon.Product.ErpExistence.");
  await AssertCountAsync(connection, "SELECT COUNT(*) FROM sys.sql_modules WHERE object_id IN(OBJECT_ID(N'out.GetSaopItemWriteState'),OBJECT_ID(N'out.ClaimItemDocument'),OBJECT_ID(N'out.PeekItemDocuments')) AND definition LIKE N'%ErpExistence%';", null, 3, "F8 izbira POST/PATCH ne bere canon.Product.ErpExistence.");
}

static async Task VerifyF9Async(SqlConnection connection)
{
  var expectedObjects = new[]
  {
    "ops.ScheduleProfile","ops.IntegrationHealth","ops.Alert","ops.AlertDelivery","ops.AlertRecipientConfig","ops.DeploymentRun",
    "ops.BeginRun","ops.RecordHeartbeat","ops.CompleteRun","ops.UpsertAlert","ops.RunWatchdog","ops.QueueAlertDeliveries","ops.ClaimAlertDelivery","ops.CompleteAlertDelivery",
    "intranet.GetSystemIntegrations","intranet.AcknowledgeAlert","intranet.ResolveAlert"
  };
  foreach(var expectedObject in expectedObjects)
    await AssertCountAsync(connection,"SELECT COUNT(*) FROM sys.objects WHERE object_id=OBJECT_ID(@value);",expectedObject,1,$"Manjka F9 objekt {expectedObject}.");
  await AssertCountAsync(connection,"SELECT COUNT(*) FROM sys.indexes WHERE object_id=OBJECT_ID(N'ops.Alert') AND name=N'UX_Alert_OpenDedup';",null,1,"Manjka F9 odprti dedup indeks.");
}

static async Task VerifyF10Async(SqlConnection connection)
{
  await AssertCountAsync(connection, "SELECT COUNT(*) FROM sys.columns WHERE object_id=OBJECT_ID(N'sec.LocalUser') AND name IN(N'AuthSource',N'DomainIdentity');", null, 2, "Manjkajo F10 stolpci za vir prijave.");
  foreach (var expectedObject in new[] { "sec.CreateLocalUser", "sec.CreateDomainUser" })
    await AssertCountAsync(connection, "SELECT COUNT(*) FROM sys.objects WHERE object_id=OBJECT_ID(@value);", expectedObject, 1, $"Manjka F10 postopek {expectedObject}.");
  await AssertCountAsync(connection, "SELECT COUNT(*) FROM sec.NavigationItem itemValue INNER JOIN sec.NavigationItemRole itemRole ON itemRole.NavigationItemId=itemValue.NavigationItemId INNER JOIN sec.Role roleValue ON roleValue.RoleId=itemRole.RoleId WHERE itemValue.ItemCode=N'USERS' AND itemValue.Route=N'/system/uporabniki' AND roleValue.RoleCode=N'ADMIN';", null, 1, "Manjka administratorska F10 navigacija uporabnikov.");

  // Zig seje (migracija 181). Brez stolpca, obeh sprozilcev in bralnega postopka onemogocen
  // racun ostane prijavljen do izteka piskotka; to je bila ugotovitev A3 pregleda 2026-09-08.
  await AssertCountAsync(connection, "SELECT COUNT(*) FROM sys.columns WHERE object_id=OBJECT_ID(N'sec.LocalUser') AND name=N'SecurityStamp';", null, 1, "Manjka stolpec sec.LocalUser.SecurityStamp za preverjanje seje.");
  foreach (var expectedObject in new[] { "sec.TR_LocalUser_SecurityStamp", "sec.TR_LocalUserRole_SecurityStamp", "sec.GetUserSecurityState" })
    await AssertCountAsync(connection, "SELECT COUNT(*) FROM sys.objects WHERE object_id=OBJECT_ID(@value);", expectedObject, 1, $"Manjka F10 objekt {expectedObject}.");
}

static async Task AssertCountAsync(SqlConnection connection, string sql, string? value, int expected, string failureMessage)
{
  await using var command = new SqlCommand(sql, connection);
  if (value is not null)
  {
    command.Parameters.AddWithValue("@value", value);
  }

  var count = Convert.ToInt32(await command.ExecuteScalarAsync());
  if (count != expected)
  {
    throw new InvalidOperationException(failureMessage);
  }
}

static async Task AssertAtLeastAsync(SqlConnection connection,string sql,int expected,string failureMessage)
{
  await using var command=new SqlCommand(sql,connection);
  var count=Convert.ToInt32(await command.ExecuteScalarAsync());
  if(count<expected)throw new InvalidOperationException(failureMessage);
}
static async Task<int> UstvariAdminaAsync(string connectionString, string uporabniskoIme)
{
  var ime = uporabniskoIme.Trim();
  if (ime.Length == 0)
  {
    Console.Error.WriteLine("Uporabnisko ime ne sme biti prazno.");
    return 2;
  }

  Console.Write($"Prikazno ime za {ime}: ");
  var prikazno = (Console.ReadLine() ?? "").Trim();
  if (prikazno.Length == 0) prikazno = ime;

  // Dolzina je samo priporocilo. Zavrne se le prazno geslo, ker ga prijava ne sprejme in bi
  // racun ostal zaklenjen.
  var geslo = PreberiGeslo("Geslo: ");
  if (string.IsNullOrWhiteSpace(geslo))
  {
    Console.Error.WriteLine("Geslo ne sme biti prazno.");
    return 2;
  }

  if (geslo.Length < 10)
    Console.WriteLine("Priporocilo: geslo je krajse od 10 znakov. Daljse geslo je varnejse, ni pa obvezno.");

  if (geslo != PreberiGeslo("Ponovi geslo: "))
  {
    Console.Error.WriteLine("Gesli se ne ujemata.");
    return 2;
  }

  await using var connection = new SqlConnection(connectionString);
  await connection.OpenAsync();
  await using var command = new SqlCommand("sec.CreateLocalUser", connection) { CommandType = System.Data.CommandType.StoredProcedure };
  command.Parameters.AddWithValue("@UserName", ime);
  command.Parameters.AddWithValue("@DisplayName", prikazno);
  command.Parameters.AddWithValue("@PasswordHash", PIM.Operations.PasswordHash.Create(geslo));
  command.Parameters.AddWithValue("@RoleCode", "ADMIN");

  try
  {
    await command.ExecuteNonQueryAsync();
  }
  catch (SqlException exception)
  {
    Console.Error.WriteLine($"Racuna ni bilo mogoce ustvariti: {exception.Message}");
    return 1;
  }

  Console.WriteLine($"Skrbnik {ime} je ustvarjen. Prijavi se na /prijava in geslo takoj spremeni na /sistem/uporabniki.");
  return 0;
}

/// <summary>Vnos brez odmeva; geslo se ne sme izpisati na zaslon niti med tipkanjem.</summary>
static string PreberiGeslo(string poziv)
{
  Console.Write(poziv);
  var znaki = new System.Text.StringBuilder();
  while (true)
  {
    var tipka = Console.ReadKey(intercept: true);
    if (tipka.Key == ConsoleKey.Enter) break;
    if (tipka.Key == ConsoleKey.Backspace)
    {
      if (znaki.Length > 0) znaki.Length--;
      continue;
    }

    if (!char.IsControl(tipka.KeyChar)) znaki.Append(tipka.KeyChar);
  }

  Console.WriteLine();
  return znaki.ToString();
}

internal sealed record Migration(string Name, string Script);
