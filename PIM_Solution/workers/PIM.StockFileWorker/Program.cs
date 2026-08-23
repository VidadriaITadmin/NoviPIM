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

// Posnetek nosi čas datoteke, ne čas zagona: zaloga pripada trenutku, ko jo je dobavitelj
// zapisal. Dvakrat obdelana ista datoteka je zato isti posnetek, ne dva različna.
var snapshotUtc = File.GetLastWriteTimeUtc(options.FilePath);
var (runId, applied, quarantined, alreadyApplied) = await new StockLandingWriter(connectionString).PersistAsync(
  options.OrganizationId, options.SourceCode, "FILE", options.Endpoint, snapshotUtc,
  batch.PayloadHash, batch.Records, options.DateFormat);

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
