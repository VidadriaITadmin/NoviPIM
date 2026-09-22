using Microsoft.Data.SqlClient;
using PIM.B2bWorker;
using PIM.Operations;

if (args.Length == 0)
{
  Console.WriteLine("PIM.B2bWorker: --export-magento --organization-id <int> [--output-dir <dir>] [--osvezi-validacijo [--starost-validacije <min>]] [--po-urniku]");
  Console.WriteLine("               --export-profile <koda> --organization-id <int> [--output-dir <dir>] [--file-name <ime.csv>] [--osvezi-validacijo [--starost-validacije <min>]] [--po-urniku]");
  Console.WriteLine("  --starost-validacije <min>: validacija in objava tečeta samo, če je validacija podjetja starejša od <min> minut.");
  return 0;
}

var exportProfile = args.Contains("--export-profile", StringComparer.Ordinal);
if (!args.Contains("--export-magento", StringComparer.Ordinal) && !exportProfile)
  throw new ArgumentException("Podprta sta ukaza --export-magento in --export-profile.");

var organizationId = RequiredInt(args, "--organization-id");
var outputDirOverride = Optional(args, "--output-dir");
var bySchedule = args.Contains("--po-urniku", StringComparer.Ordinal);
var refreshValidation = args.Contains("--osvezi-validacijo", StringComparer.Ordinal);
// Meja starosti: cikel CSV (vsakih 5 minut) validacije ne ponavlja, ce jo je urni cikel kataloga ze
// opravil — validacija celega podjetja traja minute (glej MagentoExportCommand.RefreshValidationAsync).
var validationMaxAgeMinutes = OptionalInt(args, "--starost-validacije");
if (validationMaxAgeMinutes is not null && !refreshValidation)
  throw new ArgumentException("--starost-validacije velja samo skupaj z --osvezi-validacijo.");
var connectionString = LocalSettings.ConnectionString();
if (string.IsNullOrWhiteSpace(connectionString))
  throw new InvalidOperationException(LocalSettings.MissingConnectionMessage());

// Vrstni red je enak povsod (glej PIM.Operations.SystemPaths): argument, okolje, register
// ops.SystemPath (kljuc EXPORT_ROOT, nastavljiv na /sistem/mape ali s scripts\Nastavi-izvozno-pot.ps1),
// vgrajeni privzetek. Register je tretji, da rocni preizkus z --output-dir ostane mocnejsi od
// nastavitve, ne prvi.
var outputDirectory = outputDirOverride
  ?? Environment.GetEnvironmentVariable("PIM_EXPORT_ROOT")
  ?? await SystemPaths.ResolveAsync(connectionString, SystemPaths.Export, organizationId)
  ?? Path.Combine(
       LocalSettings.FindSolutionRoot(AppContext.BaseDirectory) ?? Directory.GetCurrentDirectory(),
       "izvoz", "magento", organizationId.ToString(System.Globalization.CultureInfo.InvariantCulture));

// Ime postopka za ops.ScheduleProfile/ops.PipelineRun je isto kot koda izvoznega profila, da je
// na strani Postopki takoj razvidno, kateri izvoz je kateri. Poln izvoz (--export-magento,
// izdelki + stranke kot par) teče pod MAGENTO_PRODUCTS — ta datoteka nosi glavni katalog.
var pipeline = exportProfile ? Required(args, "--export-profile") : "MAGENTO_PRODUCTS";

if (bySchedule && !await OperationsRun.IsDueAsync(connectionString, organizationId, pipeline))
{
  Console.WriteLine($"{pipeline}: se ni na vrsti po razporedu; preskoceno.");
  return 0;
}

// Faze (blok 6 prenove nadzora, 2026-09-22): DATOTEKA na izvozno datoteko — ime, vrstice, stolpci,
// velikost. SourceCode je koda profila (MAGENTO_PRODUCTS, MAGENTO_CUSTOMERS, MAGENTO_STOCK_PRICES),
// Pipeline ime teka. Zakaj: stran Nadzor mora pokazati, da je datoteka za splet res nastala in kako
// velika je, ne samo izhodne kode; neuspeh je padla faza z razlogom.
var phases = PhaseLog.FromEnvironment(connectionString, $"{Environment.MachineName}:{Environment.ProcessId}");
string[] fileProfiles = exportProfile ? [pipeline] : [MagentoProductSchema.ProfileCode, MagentoCustomerSchema.ProfileCode];

var datotekeZapisane = false;
OperationsRun? run = null;
try
{
  run = await OperationsRun.BeginAsync(connectionString, organizationId, pipeline,
    $"{Environment.MachineName}:{Environment.ProcessId}");
}
catch (SqlException exception) when (exception.Number is 51100 or 51101)
{
  Console.Error.WriteLine(exception.Number == 51100
    ? $"Razpored za {pipeline} ni omogocen; zagon je preskocen."
    : $"{pipeline} ze tece; ta zagon se je umaknil.");
  foreach (var profil in fileProfiles)
  {
    await phases.RecordAsync(PhaseCodes.File, exception.Number == 51100 ? PhaseOutcome.Failed : PhaseOutcome.Skipped,
      profil, organizationId, pipeline,
      message: exception.Number == 51100
        ? $"razpored {pipeline} za podjetje ni omogočen; datoteka ni nastala"
        : $"{pipeline} že teče; ta zagon se je umaknil");
  }
  return exception.Number == 51100 ? 2 : 0;
}

try
{
  if (refreshValidation)
  {
    var refreshed = await MagentoExportCommand.RefreshValidationAsync(organizationId, connectionString, validationMaxAgeMinutes);
    await run.HeartbeatAsync();
    Console.WriteLine(refreshed
      ? $"Validacija in objava za podjetje {organizationId} osveženi."
      : $"Validacija podjetja {organizationId} je mlajša od {validationMaxAgeMinutes} min; osvežitev preskočena, izvoz vzame obstoječo objavo.");
  }

  if (exportProfile)
  {
    // En profil, ena datoteka: hitra osvezitev cen in zaloge (MAGENTO_STOCK_PRICES, migracija 146).
    var fileNameIndex = Array.IndexOf(args, "--file-name");
    var fileName = fileNameIndex >= 0 && fileNameIndex + 1 < args.Length ? args[fileNameIndex + 1] : null;
    var file = await MagentoExportCommand.ExportProfileFileAsync(pipeline, organizationId, outputDirectory, fileName, connectionString);
    Console.WriteLine($"Izvoz profila {pipeline} končan: {file.Rows} vrstic v {outputDirectory}");
    datotekeZapisane = true;
    await RecordFileAsync(file);
  }
  else
  {
    // 251: to je datoteka, ki jo bere Magento — pred izvozom samodejni umik, po njem zapis objave.
    var files = await MagentoExportCommand.ExecuteAsync(organizationId, outputDirectory, connectionString, publishToMagento: true);
    Console.WriteLine($"Magento CSV izvoz končan: {outputDirectory}");
    datotekeZapisane = true;
    foreach (var file in files) await RecordFileAsync(file);
  }
  await run.CompleteAsync(true);
}
catch (Exception exception)
{
  // Par katalog.csv + stranke.csv se zamenja skupaj: ob padcu ni nastala nobena od datotek. Padec
  // zapisa teka po že zapisanih datotekah ni padec datoteke.
  foreach (var profil in datotekeZapisane ? Array.Empty<string>() : fileProfiles)
  {
    await phases.RecordAsync(PhaseCodes.File, PhaseOutcome.Failed, profil, organizationId, pipeline,
      message: $"datoteka ni nastala: {exception.Message}");
  }
  await run.CompleteAsync(false, exception.Message);
  throw;
}
finally
{
  await run.DisposeAsync();
}
return 0;

// Faza DATOTEKA: prazna datoteka (0 vrstic) je uspeh brez novih podatkov, ne »uspelo«.
Task RecordFileAsync(ExportFileResult file) =>
  phases.RecordAsync(PhaseCodes.File, PhaseOutcome.Succeeded, file.ProfileCode, organizationId, pipeline,
    message: file.Rows > 0
      ? $"{Path.GetFileName(file.FilePath)}, stolpcev {file.Columns}"
      : $"{Path.GetFileName(file.FilePath)} je prazna (0 vrstic), stolpcev {file.Columns}",
    hasNewData: file.Rows > 0, itemsOut: file.Rows, byteCount: file.Bytes);

static string Required(string[] args, string name)
{
  var index = Array.IndexOf(args, name);
  if (index < 0 || index + 1 >= args.Length || string.IsNullOrWhiteSpace(args[index + 1])) throw new ArgumentException($"Manjka {name}.");
  return args[index + 1];
}

static string? Optional(string[] args, string name)
{
  var index = Array.IndexOf(args, name);
  return index < 0 || index + 1 >= args.Length ? null : args[index + 1];
}

static int RequiredInt(string[] args, string name)
  => int.TryParse(Required(args, name), out var value) && value > 0 ? value : throw new ArgumentException($"{name} mora biti pozitiven integer.");

static int? OptionalInt(string[] args, string name)
{
  var raw = Optional(args, name);
  if (raw is null) return null;
  return int.TryParse(raw, out var value) && value >= 0 ? value : throw new ArgumentException($"{name} mora biti nenegativen integer (minute).");
}
