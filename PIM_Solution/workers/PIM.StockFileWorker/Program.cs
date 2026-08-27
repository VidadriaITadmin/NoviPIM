using Microsoft.Data.SqlClient;
using PIM.Operations;
using PIM.StockFileWorker;
using PIM.StockMapping;

// Zaloga dobavitelja od datoteke do baze. Doslej je worker prebrano samo preštel in izpisal,
// zato so bile vse vrstice v stock.* iz testov, ne iz pravega vira. Bralna in pisalna stran
// sta obstajali; manjkal je zapisan vhodni dogovor — čigava zaloga je in v kateri vir gre.
//
//   dotnet run --project PIM_Solution\workers\PIM.StockFileWorker -- --file <pot> [--source NW_STOCK]
//              [--organization-id 2] [--endpoint <niz>] [--date-format dd/MM/yyyy] [--samo-preberi]
//
// Vir se privzeto ugane iz končnice (.xml = Braytron, ostalo = Nowodvorski CSV), oblika datuma
// pa iz vira. Konektor in pravilo identitete morata biti v registru (map.SourceConnector,
// map.StockIdentityRule) — worker si ju ne izmišlja.

StockFileWorkerOptions options;
try
{
  options = StockFileWorkerOptions.Parse(args);
}
catch (ArgumentException exception)
{
  Console.Error.WriteLine(exception.Message);
  Console.Error.WriteLine("Uporaba: PIM.StockFileWorker --file <pot> [--source NW_STOCK|BT_STOCK] "
    + "[--organization-id 2] [--endpoint <niz>] [--date-format <format>] [--samo-preberi]");
  return 2;
}

if (!File.Exists(options.FilePath))
{
  Console.Error.WriteLine($"Datoteke ni: {options.FilePath}");
  return 2;
}

var batch = options.FilePath.EndsWith(".xml", StringComparison.OrdinalIgnoreCase)
  ? await new BtXmlTransport().ReadFixtureAsync(options.FilePath)
  : await new NwFtpTransport().ReadFixtureAsync(options.FilePath);
Console.WriteLine($"Prebranih zapisov: {batch.Records.Count}; SHA-256: {batch.PayloadHash}");

if (options.ReadOnly)
{
  Console.WriteLine("--samo-preberi: v bazo ni bilo zapisano nič.");
  return 0;
}

var connectionString = StockFileWorkerOptions.ReadConnectionString();
if (string.IsNullOrWhiteSpace(connectionString))
{
  Console.Error.WriteLine("Manjka povezava Pim (PIM_CONNECTION_STRING ali appsettings.Local.json).");
  return 2;
}

// Ime postopka je isto v ops.ScheduleProfile, ops.PipelineRun in ops.IntegrationHealth.
const string Pipeline = "STOCK_FILE";

// Zagon se odpre prek ops.BeginRun, da dobaviteljeva zaloga tece pod istim razporedom in isto
// sledjo kot ostali vhodi. Doslej je to varovalko obhajala in je zato ni bilo v /zajem/teki.
if (options.BySchedule && !await OperationsRun.IsDueAsync(connectionString, options.OrganizationId, Pipeline))
{
  Console.WriteLine($"{Pipeline} pri podjetju {options.OrganizationId}: se ni na vrsti po razporedu; preskoceno.");
  return 0;
}

OperationsRun run;
try
{
  run = await OperationsRun.BeginAsync(connectionString, options.OrganizationId, Pipeline,
    $"{Environment.MachineName}:{Environment.ProcessId}");
}
catch (SqlException exception) when (exception.Number is 51100 or 51101)
{
  Console.Error.WriteLine(exception.Number == 51100
    ? $"Razpored za {Pipeline} pri podjetju {options.OrganizationId} ni omogocen; nic ni bilo prebrano."
    : $"{Pipeline} pri podjetju {options.OrganizationId} ze tece; ta zagon se je umaknil.");
  return exception.Number == 51100 ? 1 : 0;
}

// Posnetek nosi čas datoteke, ne čas zagona: zaloga pripada trenutku, ko jo je dobavitelj
// zapisal. Dvakrat obdelana ista datoteka je zato isti posnetek, ne dva različna.
var snapshotUtc = File.GetLastWriteTimeUtc(options.FilePath);
Guid runId; long applied, quarantined; bool alreadyApplied;
try
{
  (runId, applied, quarantined, alreadyApplied) = await new StockLandingWriter(connectionString).PersistAsync(
    options.OrganizationId, options.SourceCode, "FILE", options.Endpoint, snapshotUtc,
    batch.PayloadHash, batch.Records, options.DateFormat);
  await run.CompleteAsync(true);
}
catch (Exception exception)
{
  await run.CompleteAsync(false, exception.Message);
  await run.DisposeAsync();
  throw;
}

await run.DisposeAsync();

if (alreadyApplied)
{
  // Ista datoteka z istim casom spremembe je isti posnetek. To ni napaka: dobavitelj datoteke
  // ne posodobi vsak dan, nocno opravilo pa tece vsako noc.
  Console.WriteLine($"Ta posnetek je ze v bazi; vir={options.SourceCode}, podjetje={options.OrganizationId}, "
    + $"cas posnetka={snapshotUtc:yyyy-MM-dd HH:mm:ss}Z, uporabljenih={applied}, v karanteni={quarantined}, RunId={runId}. "
    + "Zapisano ni bilo nic.");
  return 0;
}

Console.WriteLine($"Zaloga zapisana; vir={options.SourceCode}, podjetje={options.OrganizationId}, "
  + $"uporabljenih={applied}, v karanteni={quarantined}, RunId={runId}.");
return quarantined > 0 && applied == 0 ? 1 : 0;
