using Microsoft.Data.SqlClient;
using PIM.Operations;
using PIM.StockFileWorker;
using PIM.StockMapping;

// Zaloga dobavitelja od datoteke do baze. Doslej je worker prebrano samo preštel in izpisal,
// zato so bile vse vrstice v stock.* iz testov, ne iz pravega vira. Bralna in pisalna stran
// sta obstajali; manjkal je zapisan vhodni dogovor — čigava zaloga je in v kateri vir gre.
//
//   dotnet run --project PIM_Solution\workers\PIM.StockFileWorker -- --file <pot> [--source NW_STOCK]
//              [--organizations 2,3,4] [--endpoint <niz>] [--date-format dd/MM/yyyy] [--samo-preberi]
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
    + "[--organizations 2,3,4] [--endpoint <niz>] [--date-format <format>] [--samo-preberi]");
  return 2;
}

if (!File.Exists(options.FilePath))
{
  Console.Error.WriteLine($"Datoteke ni: {options.FilePath}");
  return 2;
}

// Ime postopka je isto v ops.ScheduleProfile, ops.PipelineRun in ops.IntegrationHealth.
const string Pipeline = "STOCK_FILE";

// Brez povezave se da datoteko samo prebrati (--samo-preberi); faze se takrat ne zapisujejo.
var connectionString = StockFileWorkerOptions.ReadConnectionString();

// Faze (migracija 255): branje se zgodi PRED ops.BeginRun, zato mora imeti svojo vrstico — doslej
// je pokvarjena datoteka podrla proces, ne da bi v bazi ostala sled.
//
// Dobavitelj ima eno zalogo za vsa podjetja: datoteka se prebere ENKRAT (--organizations 2,3,4), nato
// se zapiše vsakemu podjetju posebej. Vrstica faze BRANJE se zapiše pri vsakem podjetju, ker nadzor
// svežino vira meri po podjetju (ops.JobSourceState, 256).
var workerId = $"{Environment.MachineName}:{Environment.ProcessId}";
var phases = PhaseLog.FromEnvironment(connectionString, workerId);
var fileInfo = new FileInfo(options.FilePath);

StockFixtureBatch batch;
try
{
  batch = options.FilePath.EndsWith(".xml", StringComparison.OrdinalIgnoreCase)
    ? await new BtXmlTransport().ReadFixtureAsync(options.FilePath)
    : await new NwFtpTransport().ReadFixtureAsync(options.FilePath);
}
catch (Exception exception)
{
  foreach (var organizationId in options.OrganizationIds)
    await phases.RecordAsync(PhaseCodes.Read, PhaseOutcome.Failed, options.SourceCode, organizationId, Pipeline,
      message: $"Datoteke {fileInfo.Name} ni bilo mogoče prebrati: {exception.Message}");
  Console.Error.WriteLine($"Datoteke ni bilo mogoče prebrati: {exception.Message}");
  return 2;
}

Console.WriteLine($"Prebranih zapisov: {batch.Records.Count}; SHA-256: {batch.PayloadHash}; "
  + $"podjetja: {string.Join(", ", options.OrganizationIds)}");
// Branje ne prinese novih podatkov v bazo (to pove šele faza ZAPIS), zato HasNewData ostane 0 —
// sicer bi vsako branje pet dni stare datoteke veljalo za sveže podatke.
foreach (var organizationId in options.OrganizationIds)
  await phases.RecordAsync(PhaseCodes.Read, PhaseOutcome.Succeeded, options.SourceCode, organizationId, Pipeline,
    message: $"datoteka z dne {fileInfo.LastWriteTime:d. M. yyyy HH:mm}", hasNewData: false,
    itemsIn: batch.Records.Count, itemsOut: batch.Records.Count, byteCount: fileInfo.Length);

if (options.ReadOnly)
{
  Console.WriteLine("--samo-preberi: v bazo ni bilo zapisano nič.");
  return 0;
}

if (string.IsNullOrWhiteSpace(connectionString))
{
  Console.Error.WriteLine("Manjka povezava Pim (PIM_CONNECTION_STRING ali appsettings.Local.json).");
  return 2;
}

// Posnetek nosi čas datoteke, ne čas zagona: zaloga pripada trenutku, ko jo je dobavitelj
// zapisal. Dvakrat obdelana ista datoteka je zato isti posnetek, ne dva različna.
var snapshotUtc = File.GetLastWriteTimeUtc(options.FilePath);

// Padec enega podjetja ne ustavi naslednjih (prej je bil vsak svoj korak posla); izhodna koda je najslabša.
var exitCode = 0;
foreach (var organizationId in options.OrganizationIds)
{
  try
  {
    exitCode = Math.Max(exitCode, await WriteOrganizationAsync(organizationId));
  }
  catch (Exception exception)
  {
    Console.Error.WriteLine($"Zaloga {options.SourceCode} pri podjetju {organizationId} ni zapisana: {exception.Message}");
    exitCode = Math.Max(exitCode, 1);
  }
}
return exitCode;

async Task<int> WriteOrganizationAsync(int organizationId)
{
  // Zagon se odpre prek ops.BeginRun, da dobaviteljeva zaloga tece pod istim razporedom in isto
  // sledjo kot ostali vhodi. Doslej je to varovalko obhajala in je zato ni bilo v /zajem/teki.
  if (options.BySchedule && !await OperationsRun.IsDueAsync(connectionString, organizationId, Pipeline))
  {
    Console.WriteLine($"{Pipeline} pri podjetju {organizationId}: se ni na vrsti po razporedu; preskoceno.");
    return 0;
  }

  OperationsRun run;
  try
  {
    run = await OperationsRun.BeginAsync(connectionString, organizationId, Pipeline, workerId);
  }
  catch (SqlException exception) when (exception.Number is 51100 or 51101)
  {
    Console.Error.WriteLine(exception.Number == 51100
      ? $"Razpored za {Pipeline} pri podjetju {organizationId} ni omogocen; nic ni bilo zapisano."
      : $"{Pipeline} pri podjetju {organizationId} ze tece; ta zagon se je umaknil.");
    return exception.Number == 51100 ? 1 : 0;
  }

  Guid runId; long applied, quarantined; bool alreadyApplied;
  var zapis = await phases.BeginAsync(PhaseCodes.Land, options.SourceCode, organizationId, Pipeline, run.RunId);
  try
  {
    (runId, applied, quarantined, alreadyApplied) = await new StockLandingWriter(connectionString).PersistAsync(
      organizationId, options.SourceCode, "FILE", options.Endpoint, snapshotUtc,
      batch.PayloadHash, batch.Records, options.DateFormat);
    await run.CompleteAsync(true);
  }
  catch (Exception exception)
  {
    await zapis.FailedAsync(exception.Message, itemsIn: batch.Records.Count);
    await run.CompleteAsync(false, exception.Message);
    await run.DisposeAsync();
    throw;
  }

  await run.DisposeAsync();

  if (alreadyApplied)
  {
    // Ista datoteka z istim casom spremembe je isti posnetek. To ni napaka: dobavitelj datoteke
    // ne posodobi vsak dan, nocno opravilo pa tece vsako noc. Faza je zato preskok z razlogom in
    // ne uspeh — svezina vira se od tega ne osvezi (blok 3 prenove nadzora).
    await zapis.SkippedAsync($"isti posnetek je že v bazi (datoteka z dne {snapshotUtc.ToLocalTime():d. M. yyyy HH:mm})",
      itemsIn: batch.Records.Count);
    Console.WriteLine($"Ta posnetek je ze v bazi; vir={options.SourceCode}, podjetje={organizationId}, "
      + $"cas posnetka={snapshotUtc:yyyy-MM-dd HH:mm:ss}Z, uporabljenih={applied}, v karanteni={quarantined}, RunId={runId}. "
      + "Zapisano ni bilo nic.");
    return 0;
  }

  await zapis.SucceededAsync(itemsIn: batch.Records.Count, itemsOut: applied, itemsRejected: quarantined,
    hasNewData: applied > 0, message: $"posnetek {runId}");

  // Ujemanje z artikli: »uporabljeno« ne pomeni »najdeno«. Vrstica brez artikla obvisi kot neujeta
  // pozicija in doslej je ni bilo nikjer videti (popis 2026-09-22).
  var ujemanje = await phases.BeginAsync(PhaseCodes.Match, options.SourceCode, organizationId, Pipeline, run.RunId);
  try
  {
    var (ujetih, neujetih) = await StockMatchCounts.ReadAsync(connectionString, runId);
    // Dobaviteljeva datoteka gre vsakemu podjetju in ima večino šifer, ki jih podjetje nima: to ni
    // zavrnitev, zaloga se prikaže samo pri obstoječem artiklu (262). Zavrnjene ostanejo le karantene.
    await ujemanje.SucceededAsync(itemsIn: applied, itemsOut: ujetih, itemsRejected: null,
      hasNewData: ujetih > 0,
      message: neujetih > 0 ? $"{neujetih} šifer dobavitelja podjetje nima (pri njem se ne prikažejo)" : null);
  }
  catch (Exception exception)
  {
    await ujemanje.FailedAsync($"Ujemanja ni bilo mogoče prešteti: {exception.Message}");
  }

  Console.WriteLine($"Zaloga zapisana; vir={options.SourceCode}, podjetje={organizationId}, "
    + $"uporabljenih={applied}, v karanteni={quarantined}, RunId={runId}.");
  return quarantined > 0 && applied == 0 ? 1 : 0;
}
