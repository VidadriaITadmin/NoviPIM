using Microsoft.Data.SqlClient;
using PIM.B2bWorker;
using PIM.Operations;

if (args.Length == 0)
{
  Console.WriteLine("PIM.B2bWorker: --export-magento --organization-id <int> [--output-dir <dir>] [--osvezi-validacijo] [--po-urniku]");
  Console.WriteLine("               --export-profile <koda> --organization-id <int> [--output-dir <dir>] [--file-name <ime.csv>] [--osvezi-validacijo] [--po-urniku]");
  return 0;
}

var exportProfile = args.Contains("--export-profile", StringComparer.Ordinal);
if (!args.Contains("--export-magento", StringComparer.Ordinal) && !exportProfile)
  throw new ArgumentException("Podprta sta ukaza --export-magento in --export-profile.");

var organizationId = RequiredInt(args, "--organization-id");
var outputDirOverride = Optional(args, "--output-dir");
var bySchedule = args.Contains("--po-urniku", StringComparer.Ordinal);
var refreshValidation = args.Contains("--osvezi-validacijo", StringComparer.Ordinal);
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
  return exception.Number == 51100 ? 2 : 0;
}

try
{
  if (refreshValidation)
  {
    await MagentoExportCommand.RefreshValidationAsync(organizationId, connectionString);
    await run.HeartbeatAsync();
    Console.WriteLine($"Validacija in objava za podjetje {organizationId} osveženi.");
  }

  if (exportProfile)
  {
    // En profil, ena datoteka: hitra osvezitev cen in zaloge (MAGENTO_STOCK_PRICES, migracija 146).
    var fileNameIndex = Array.IndexOf(args, "--file-name");
    var fileName = fileNameIndex >= 0 && fileNameIndex + 1 < args.Length ? args[fileNameIndex + 1] : null;
    var rows = await MagentoExportCommand.ExportProfileAsync(pipeline, organizationId, outputDirectory, fileName, connectionString);
    Console.WriteLine($"Izvoz profila {pipeline} končan: {rows} vrstic v {outputDirectory}");
  }
  else
  {
    await MagentoExportCommand.ExecuteAsync(organizationId, outputDirectory, connectionString);
    Console.WriteLine($"Magento CSV izvoz končan: {outputDirectory}");
  }
  await run.CompleteAsync(true);
}
catch (Exception exception)
{
  await run.CompleteAsync(false, exception.Message);
  throw;
}
finally
{
  await run.DisposeAsync();
}
return 0;

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
