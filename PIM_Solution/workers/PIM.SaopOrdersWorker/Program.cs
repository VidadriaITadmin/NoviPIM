using System.Data;
using System.Globalization;
using Microsoft.Data.SqlClient;
using PIM.Operations;
using PIM.SaopOrdersWorker;
using PIM.XmlMapping;

/*
  PIM.SaopOrdersWorker — zajem naročil kupcev (VNK) in naročil dobaviteljem (VND) iz SAOP, za
  MIN/MID/MAX in ABC klasifikacijo (MIN_MAX_proces.docx).

  Prodajna zgodovina za ABC/formulo se računa iz sales.OrderLine (Qty/ShippedQTY), ne iz ločenega
  klica GetOrderRealisation — ta bi vrnil isti podatek, ki ga VNK zajem že prinese (glej migracijo 199).

  Prva izvedba (v1), namenoma manjša od PIM.KatalogWorker: brez vzporednosti med organizacijami,
  brez fixture načina, brez --map-run/--preslikaj-zaostanek orodij za zaostanek. Doda se, ko se
  izkaže potreba — glej docs/DATABASE.md, migracija 199.

  Odkritje + podrobnosti (dvokorak) je nov vzorec v tem cevovodu (glej migracijo 199): GetOrderStatus/
  GetPurchaseOrdersStatus vrneta samo ključe sprememb od zadnjega vodnega žiga, GetOrder/
  GetPurchaseOrder pa za vsak ključ posebej polne podatke, ki šele ti gredo v raw.Inbox.

  Ločena razporeda (2026-09-15, migracija 210). Do zdaj sta VNK in VND delila en sam
  OperationsRun pod imenom SAOP_ORDERS — to je pomenilo dvoje: (1) skrbnik ju ni mogel vklopiti/
  izklopiti/spremljati ločeno na /sistem/urniki, čeprav uporabnik izrecno hoče oboje posebej;
  (2) padec VND po uspešnem VNK je s CompleteAsync(false) označil kot neuspešen CEL tek, čeprav
  je VNK podatek varno pristal. Zdaj vsak dobi svoj OperationsRun (SAOP_ORDERS_VND, VND) in
  svojo preslikavo takoj po pristanku, namesto ene skupne na koncu.

  Nihče doslej te skripte ni zagnal samodejno — v nobenem od štirih ciklov (Zaloga-cikel.ps1,
  Katalog-cikel.ps1, Nadzor.ps1, Nocno-vse.ps1) ni bila omenjena, čeprav je razpored v bazi
  ves čas kazal "vklopljeno". Zdaj jo kliče Katalog-cikel.ps1 vsako uro (isti ritem kot
  IntervalSeconds v ops.ScheduleProfile), zato tu doda še isto varovalko za živ klic kot
  PIM.KatalogWorker in PIM.SaopStockWorker (AGENTS.md §4.5): brez PIM_SAOP_MODE=Live samo
  izpiše, kaj bi naredil, in se ne dotakne SAOP.
*/

var organizationFilter = ParseOrganizationFilter(args);
var full = args.Contains("--full", StringComparer.OrdinalIgnoreCase);
if (args.Contains("--help", StringComparer.OrdinalIgnoreCase) || args.Contains("-h", StringComparer.OrdinalIgnoreCase))
{
  PrintUsage();
  return 0;
}

var connectionString = OrdersWorkerConfiguration.GetConnectionString();
if (string.IsNullOrWhiteSpace(connectionString))
{
  Console.Error.WriteLine(LocalSettings.MissingConnectionMessage());
  return 2;
}

var settings = OrdersWorkerConfiguration.Read();
if (!settings.HasCredentials)
{
  Console.Error.WriteLine(
    "Manjkajo SAOP poverilnice. Dopolni sekcijo \"Saop\" v korenski appsettings.Local.json "
    + "(BaseUrl, Username, Password) ali nastavi PIM_SAOP_BASE_URL, PIM_SAOP_USERNAME in PIM_SAOP_PASSWORD.");
  return 2;
}

var organizations = settings.Organizations
  .Where(organization => organization.IsActive)
  .Where(organization => organizationFilter.Count == 0 || organizationFilter.Contains(organization.Id))
  .ToArray();
if (organizations.Length == 0)
{
  Console.Error.WriteLine("V nastavitvah ni nobene aktivne organizacije, ki bi ustrezala izbiri.");
  return 2;
}

// Živ klic je odločitev človeka (AGENTS.md §4.5), enako kot pri KatalogWorker/SaopStockWorker.
// Brez tega worker samo pove, kaj bi naredil, in SAOP ne dotakne.
var live = string.Equals(Environment.GetEnvironmentVariable("PIM_SAOP_MODE"), "Live", StringComparison.OrdinalIgnoreCase);
if (!live)
{
  Console.WriteLine("PIM_SAOP_MODE ni Live — klic ni izveden.");
  foreach (var organization in organizations)
  {
    Console.WriteLine($"  [{organization.Id}] {organization.Name}: VNK={(string.IsNullOrWhiteSpace(organization.SalesOrderBook) ? "brez knjige" : organization.SalesOrderBook)}, "
      + $"VND={(string.IsNullOrWhiteSpace(organization.PurchaseOrderBook) ? "brez knjige" : organization.PurchaseOrderBook)}");
  }
  return 0;
}

using var client = new SaopOrdersApiClient(settings);
var workerId = $"{Environment.MachineName}:{Environment.ProcessId}";
var failedAny = false;

// Faze (blok 6 prenove nadzora, 2026-09-22): PRENOS, MEJNIK in PRESLIKAVA za VNK in VND posebej.
// SourceCode in Pipeline faze sta ime razporeda (SAOP_ORDERS_VNK / SAOP_ORDERS_VND) — isti niz kot vir
// posla SAOP_ORDER_IMPORT v JobCatalog. Podjetje brez knjige je preskok z razlogom, ne tišina.
var phases = PhaseLog.FromEnvironment(connectionString, workerId);

foreach (var organization in organizations)
{
  Console.WriteLine($"[{organization.Id}] {organization.Name} ({organization.SourceCode})");
  await using var connection = new SqlConnection(connectionString);
  await connection.OpenAsync();

  var sourceConnectorId = await ReadSourceConnectorIdAsync(connection, organization.Id, organization.SourceCode);
  if (sourceConnectorId is null)
  {
    Console.Error.WriteLine($"  Ni aktivnega map.SourceConnector za {organization.SourceCode}; preskočeno.");
    foreach (var brezVira in new[] { "SAOP_ORDERS_VNK", "SAOP_ORDERS_VND" })
    {
      await phases.RecordAsync(PhaseCodes.Fetch, PhaseOutcome.Failed, brezVira, organization.Id, brezVira,
        message: $"ni aktivnega map.SourceConnector za {organization.SourceCode}; naročil ni mogoče zajeti");
    }
    continue;
  }

  // VNK in VND vsak v svojem OperationsRun (glej opis na vrhu): padec enega ne sme oznaciti
  // podatka, ki ga je drugi ze varno pristanil, kot neuspesnega.
  if (!string.IsNullOrWhiteSpace(organization.SalesOrderBook))
  {
    if (!await RunOrderKindAsync("SAOP_ORDERS_VNK", "Naročila kupcev (VNK)", async (connection, runId) =>
      await RunSalesOrdersAsync(client, connection, settings, organization, sourceConnectorId.Value, runId, full)))
      failedAny = true;
  }
  else
  {
    await RegisterSkippedAsync("SAOP_ORDERS_VNK", "Naročila kupcev (VNK)", "SalesOrderBook");
  }

  if (!string.IsNullOrWhiteSpace(organization.PurchaseOrderBook))
  {
    if (!await RunOrderKindAsync("SAOP_ORDERS_VND", "Naročila dobaviteljem (VND)", async (connection, runId) =>
      await RunPurchaseOrdersAsync(client, connection, settings, organization, sourceConnectorId.Value, runId, full)))
      failedAny = true;
  }
  else
  {
    await RegisterSkippedAsync("SAOP_ORDERS_VND", "Naročila dobaviteljem (VND)", "PurchaseOrderBook");
  }

  // Podjetje brez knjige se preskoči, a tek se vseeno zabeleži (2026-09-17): brez ops.BeginRun
  // razpored SAOP_ORDERS_VNK/VND nikoli ne dobi utripa in razporejevalnik po dvojnem razmiku javlja
  // "postopek ni tekel", čeprav je worker vsako uro preveril in ni imel česa zajeti.
  async Task RegisterSkippedAsync(string pipeline, string label, string setting)
  {
    Console.WriteLine($"  {label}: brez nastavljene knjige (Saop:Organizations:{setting}), preskočeno.");
    // Preskok ni stik z virom: brez knjige naročila ne prihajajo in nadzor mora to videti z razlogom.
    await phases.RecordAsync(PhaseCodes.Fetch, PhaseOutcome.Skipped, pipeline, organization.Id, pipeline,
      message: $"brez nastavljene knjige (Saop:Organizations:{setting}); naročila se ne zajemajo");
    try
    {
      await using var skipped = await OperationsRun.BeginAsync(connectionString, organization.Id, pipeline, workerId);
      await skipped.CompleteAsync(true);
    }
    catch (SqlException exception) when (exception.Number is 51100 or 51101)
    {
      // Izklopljen razpored ali tek, ki že teče: ni kaj beležiti.
    }
  }

  // Eno samo ime organizacije (VNK/VND se ne ločita v tem klicu), zato lokalna funkcija zapre
  // nad zunanjimi spremenljivkami organization/connection/sourceConnectorId.
  async Task<bool> RunOrderKindAsync(string pipeline, string label, Func<SqlConnection, Guid, Task<OrderFetch>> fetchAsync)
  {
    OperationsRun? run = null;
    try
    {
      run = await OperationsRun.BeginAsync(connectionString, organization.Id, pipeline, workerId);
    }
    catch (SqlException exception) when (exception.Number is 51100 or 51101)
    {
      Console.Error.WriteLine(exception.Number == 51100
        ? $"  {label}: razpored za {pipeline} ni omogočen; podjetje je preskočeno."
        : $"  {label}: {pipeline} že teče; ta zagon se je umaknil.");
      await phases.RecordAsync(PhaseCodes.Fetch, exception.Number == 51100 ? PhaseOutcome.Failed : PhaseOutcome.Skipped,
        pipeline, organization.Id, pipeline,
        message: exception.Number == 51100
          ? $"razpored {pipeline} za podjetje ni omogočen; naročila niso bila zajeta"
          : $"{pipeline} že teče; ta zagon se je umaknil");
      return exception.Number == 51101; // ze tece ni napaka, izklopljen razpored je
    }

    // Katera faza teče, ko pride izjema: padec mora ostati zapisan pri pravi fazi.
    string? faza = PhaseCodes.Fetch;
    try
    {
      var fetched = await fetchAsync(connection, run.RunId);
      // Dokument, ki ga SAOP ni vrnil, naredi fazo rdečo s številkami dokumentov; ostala naročila so zajeta.
      await phases.RecordAsync(PhaseCodes.Fetch, fetched.Failed.Count > 0 ? PhaseOutcome.Failed : PhaseOutcome.Succeeded,
        pipeline, organization.Id, pipeline, run.RunId,
        fetched.Failed.Count > 0
          ? $"SAOP ni vrnil {fetched.Failed.Count} dokumentov: {string.Join(", ", fetched.Failed.Take(10))}{(fetched.Failed.Count > 10 ? " …" : "")}; zajetih {fetched.Landed} od {fetched.Keys}"
          : fetched.Keys == 0
            ? $"ni sprememb od {fetched.ModifiedFrom:yyyy-MM-dd}"
            : $"spremenjenih naročil od {fetched.ModifiedFrom:yyyy-MM-dd}: {fetched.Keys}, pristanjenih strani {fetched.Landed}",
        hasNewData: fetched.Landed > 0, itemsIn: fetched.Keys, itemsOut: fetched.Landed, itemsRejected: fetched.Failed.Count);
      await run.HeartbeatAsync();
      faza = PhaseCodes.Map;
      await new SqlMappingPipeline(connectionString).ExtractAndApplyAsync(run.RunId, organization.Id, organization.SourceCode);
      faza = null;
      await MappingPhaseReport.RecordAsync(phases, connectionString, run.RunId, pipeline, organization.Id, pipeline);

      // Vodni žig po preslikavi: premakne se, ko v tem teku ne ostane nič Pending.
      faza = PhaseCodes.Watermark;
      var pending = await CountPendingAsync(connection, run.RunId, organization.Id, organization.SourceCode, fetched.EntityType);
      if (pending == 0)
        await AdvanceWatermarkAsync(connection, fetched.SourceConnectorId, fetched.EntityType, fetched.FetchStartedUtc);
      else
        Console.WriteLine($"  OPOZORILO: {pending} vrstic {fetched.EntityType} ostaja Pending po preslikavi; vodni žig ni premaknjen.");
      await phases.RecordAsync(PhaseCodes.Watermark, pending == 0 ? PhaseOutcome.Succeeded : PhaseOutcome.Skipped,
        pipeline, organization.Id, pipeline, run.RunId,
        pending == 0
          ? $"vodni žig premaknjen na {fetched.FetchStartedUtc:yyyy-MM-dd HH:mm} UTC"
          : $"vodni žig ni premaknjen: {pending} strani po preslikavi še čaka; isto obdobje bo zajeto znova",
        hasNewData: pending == 0);
      faza = null;
      Console.WriteLine($"  {label}: pristanjenih strani {fetched.Landed}. RunId={run.RunId}");
      await run.CompleteAsync(true);
      return true;
    }
    catch (Exception exception)
    {
      // Padec ene organizacije ali enega toka (VNK/VND) ne sme ustaviti ostalih.
      Console.Error.WriteLine($"  {label} za organizacijo {organization.Id} je padlo: {exception.Message}");
      if (faza == PhaseCodes.Map)
        await MappingPhaseReport.RecordFailureAsync(phases, run.RunId, pipeline, organization.Id, pipeline, exception);
      else if (faza is not null)
        await phases.RecordAsync(faza, PhaseOutcome.Failed, pipeline, organization.Id, pipeline, run.RunId, exception.Message);
      await run.CompleteAsync(false, exception.Message[..Math.Min(2000, exception.Message.Length)]);
      return false;
    }
    finally
    {
      await run.DisposeAsync();
    }
  }
}

return failedAny ? 1 : 0;

/// <summary>
/// VNK: odkritje prek GetOrderStatus (samo ključi sprememb), nato GetOrder po ključu za vsako
/// spremenjeno naročilo. Vodni žig se premakne šele, ko za ta EntityType v tem teku ne ostane
/// nobena vrstica Pending — enak vrstni red kot pri PIM.KatalogWorker (glej SaopIngestRunner),
/// ker je premik pred potrjeno preslikavo že enkrat pomenil tiho izgubljeno okno podatkov.
/// </summary>
static async Task<OrderFetch> RunSalesOrdersAsync(
  SaopOrdersApiClient client, SqlConnection connection, OrdersSettings settings, SaopOrganization organization,
  int sourceConnectorId, Guid runId, bool full)
{
  const string entityType = "GetOrder";
  var fetchStartedUtc = DateTime.UtcNow;
  var modifiedFrom = full ? null : await ReadWatermarkAsync(connection, sourceConnectorId, entityType);
  modifiedFrom ??= DateTime.UtcNow.AddMonths(-settings.InitialBackfillMonths);
  modifiedFrom = modifiedFrom.Value.AddDays(-settings.LookbackDays);

  var keys = new List<OrderKey>();
  await foreach (var page in client.ReadSalesOrderKeysAsync(organization.Id, organization.SalesOrderBook!, modifiedFrom))
  {
    keys.AddRange(page.Keys);
  }

  Console.WriteLine($"  Naročila kupcev (VNK): {keys.Count} spremenjenih od {modifiedFrom:yyyy-MM-dd}.");
  var landed = 0;
  var failed = new List<string>();
  foreach (var key in keys.DistinctBy(k => (k.Year, k.Book, k.Number)))
  {
    // En pokvarjen dokument v SAOP (npr. 2024/VND/214 vrne 500) ne sme ustaviti zajema ostalih
    // (David 2026-09-22): zapišemo ga kot napako s številko dokumenta in gremo naprej.
    string xml;
    try { xml = await client.GetSalesOrderDetailAsync(organization.Id, key); }
    catch (Exception exception) when (exception is not OperationCanceledException)
    {
      failed.Add($"{key.Year}/{key.Book}/{key.Number}");
      Console.Error.WriteLine($"  NAPAKA: dokument {key.Year}/{key.Book}/{key.Number} ni prebran: {exception.Message[..Math.Min(300, exception.Message.Length)]}");
      continue;
    }
    await RawInboxWriter.WriteAsync(connection, runId, organization.Id, organization.SourceCode, entityType, key.Number, xml);
    landed++;
  }

  // Vodni žig se odloči šele PO preslikavi (RunOrderKindAsync): pred njo so sveže zapisane strani vedno
  // Pending, zato se žig ni premaknil nikoli, ko je tek kaj prinesel, in vsak tek je znova prenesel vse
  // (Vidadria 2026-09-22: 634 naročil vsako uro).
  return new OrderFetch(keys.Count, landed, 0, false, modifiedFrom.Value, fetchStartedUtc, failed, entityType, sourceConnectorId);
}

/// <summary>VND: enak vzorec kot RunSalesOrdersAsync, glej tam.</summary>
static async Task<OrderFetch> RunPurchaseOrdersAsync(
  SaopOrdersApiClient client, SqlConnection connection, OrdersSettings settings, SaopOrganization organization,
  int sourceConnectorId, Guid runId, bool full)
{
  const string entityType = "GetPurchaseOrder";
  var fetchStartedUtc = DateTime.UtcNow;
  var modifiedFrom = full ? null : await ReadWatermarkAsync(connection, sourceConnectorId, entityType);
  modifiedFrom ??= DateTime.UtcNow.AddMonths(-settings.InitialBackfillMonths);
  modifiedFrom = modifiedFrom.Value.AddDays(-settings.LookbackDays);

  var keys = new List<OrderKey>();
  await foreach (var page in client.ReadPurchaseOrderKeysAsync(organization.Id, organization.PurchaseOrderBook!, modifiedFrom))
  {
    keys.AddRange(page.Keys);
  }

  Console.WriteLine($"  Naročila dobaviteljem (VND): {keys.Count} spremenjenih od {modifiedFrom:yyyy-MM-dd}.");
  var landed = 0;
  var failed = new List<string>();
  foreach (var key in keys.DistinctBy(k => (k.Year, k.Book, k.Number)))
  {
    // En pokvarjen dokument v SAOP (npr. 2024/VND/214 vrne 500) ne sme ustaviti zajema ostalih
    // (David 2026-09-22): zapišemo ga kot napako s številko dokumenta in gremo naprej.
    string xml;
    try { xml = await client.GetPurchaseOrderDetailAsync(organization.Id, key); }
    catch (Exception exception) when (exception is not OperationCanceledException)
    {
      failed.Add($"{key.Year}/{key.Book}/{key.Number}");
      Console.Error.WriteLine($"  NAPAKA: dokument {key.Year}/{key.Book}/{key.Number} ni prebran: {exception.Message[..Math.Min(300, exception.Message.Length)]}");
      continue;
    }
    await RawInboxWriter.WriteAsync(connection, runId, organization.Id, organization.SourceCode, entityType, key.Number, xml);
    landed++;
  }

  // Vodni žig se odloči šele PO preslikavi (RunOrderKindAsync): pred njo so sveže zapisane strani vedno
  // Pending, zato se žig ni premaknil nikoli, ko je tek kaj prinesel, in vsak tek je znova prenesel vse
  // (Vidadria 2026-09-22: 634 naročil vsako uro).
  return new OrderFetch(keys.Count, landed, 0, false, modifiedFrom.Value, fetchStartedUtc, failed, entityType, sourceConnectorId);
}

static async Task<int?> ReadSourceConnectorIdAsync(SqlConnection connection, int organizationId, string sourceCode)
{
  await using var command = new SqlCommand(
    "SELECT SourceConnectorId FROM map.SourceConnector WHERE OrganizationId=@OrganizationId AND SourceCode=@SourceCode AND IsActive=1;",
    connection);
  command.Parameters.AddWithValue("@OrganizationId", organizationId);
  command.Parameters.AddWithValue("@SourceCode", sourceCode);
  var value = await command.ExecuteScalarAsync();
  return value is int id ? id : null;
}

/// <summary>Isti bralni vzorec kot PIM.KatalogWorker.SaopIngestRunner.ReadWatermarkAsync.</summary>
static async Task<DateTime?> ReadWatermarkAsync(SqlConnection connection, int sourceConnectorId, string entityType)
{
  await using var command = new SqlCommand(
    "SELECT WatermarkValue FROM map.Watermark WHERE SourceConnectorId=@SourceConnectorId AND EntityType=@EntityType;", connection);
  command.Parameters.AddWithValue("@SourceConnectorId", sourceConnectorId);
  command.Parameters.AddWithValue("@EntityType", entityType);
  var value = await command.ExecuteScalarAsync();
  if (value is null or DBNull) return null;
  return DateTime.TryParse(
    Convert.ToString(value, CultureInfo.InvariantCulture), CultureInfo.InvariantCulture,
    DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out var parsed) ? parsed : null;
}

/// <summary>
/// Vodni žig se premakne SAMO, ko klicatelj potrdi, da za ta (connector, entityType, runId) ne
/// ostane nobena vrstica Pending — glej klicatelje zgoraj. Premik pred potrjeno preslikavo je pri
/// PIM.KatalogWorker že enkrat povzročil tiho izgubljeno okno podatkov (glej SaopIngestRunner).
/// </summary>
static async Task AdvanceWatermarkAsync(SqlConnection connection, int sourceConnectorId, string entityType, DateTime newWatermarkUtc)
{
  await using var command = new SqlCommand(
    """
    MERGE map.Watermark AS target
    USING (SELECT @SourceConnectorId AS SourceConnectorId, @EntityType AS EntityType, @WatermarkValue AS WatermarkValue) AS source
      ON target.SourceConnectorId = source.SourceConnectorId AND target.EntityType = source.EntityType
    WHEN MATCHED THEN UPDATE SET WatermarkValue = source.WatermarkValue, UpdatedUtc = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT (SourceConnectorId, EntityType, WatermarkValue, UpdatedUtc)
      VALUES (source.SourceConnectorId, source.EntityType, source.WatermarkValue, SYSUTCDATETIME());
    """, connection);
  command.Parameters.AddWithValue("@SourceConnectorId", sourceConnectorId);
  command.Parameters.AddWithValue("@EntityType", entityType);
  command.Parameters.AddWithValue("@WatermarkValue", newWatermarkUtc.ToString("O", CultureInfo.InvariantCulture));
  await command.ExecuteNonQueryAsync();
}

static async Task<int> CountPendingAsync(SqlConnection connection, Guid runId, int organizationId, string sourceCode, string entityType)
{
  await using var command = new SqlCommand(
    "SELECT COUNT(*) FROM raw.Inbox WHERE RunId=@RunId AND OrganizationId=@OrganizationId AND SourceCode=@SourceCode "
    + "AND EntityType=@EntityType AND Status=N'Pending';", connection);
  command.Parameters.AddWithValue("@RunId", runId);
  command.Parameters.AddWithValue("@OrganizationId", organizationId);
  command.Parameters.AddWithValue("@SourceCode", sourceCode);
  command.Parameters.AddWithValue("@EntityType", entityType);
  return Convert.ToInt32(await command.ExecuteScalarAsync());
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
    PIM.SaopOrdersWorker — zajem naročil kupcev (VNK) in naročil dobaviteljem (VND) iz SAOP,
    za MIN/MID/MAX in ABC klasifikacijo.

    Argumenti:
      --organizations 2,3   zajemi samo našteta podjetja (privzeto vsa aktivna z nastavljeno knjigo)
      --full                prezri vodni žig; zajemi zadnjih InitialBackfillMonths mesecev znova
      --help                ta izpis

    Knjige (SalesOrderBook/PurchaseOrderBook) se nastavijo na organizacijo v appsettings.Local.json
    pod Saop:Organizations — niso univerzalna konstanta, ker jih vsako podjetje nastavi po svoje.
    Organizacija brez nastavljene knjige se pri tistem toku preskoči, ne pade; tek se vseeno
    zabeleži kot uspešen, da razpored dobi utrip in razporejevalnik ne javlja zaostanka.

    Živ klic je odločitev človeka (AGENTS.md §4.5): brez PIM_SAOP_MODE=Live worker samo izpiše,
    kaj bi zajel, in SAOP se ne dotakne. VNK teče pod razporedom SAOP_ORDERS_VNK, VND pod
    SAOP_ORDERS_VND (migracija 210) — vsak s svojim vklopom/izklopom na /sistem/urniki.
    """);
}

/// <summary>
/// Izid zajema enega toka (VNK/VND) za faze PRENOS in MEJNIK (blok 6 prenove nadzora):
/// koliko ključev je SAOP javil, koliko strani je pristalo in ali se je vodni žig premaknil.
/// </summary>
/// <param name="Failed">Dokumenti, ki jih SAOP ni vrnil (leto/knjiga/številka); ostali so zajeti.</param>
sealed record OrderFetch(int Keys, int Landed, int Pending, bool WatermarkAdvanced, DateTime ModifiedFrom, DateTime FetchStartedUtc, IReadOnlyList<string> Failed, string EntityType, int SourceConnectorId);
