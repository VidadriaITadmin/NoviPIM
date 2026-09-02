using PIM.B2bWorker;

if (args.Length == 0)
{
  Console.WriteLine("PIM.B2bWorker: --export-magento --organization-id <int> --output-dir <dir>");
  Console.WriteLine("               --export-profile <koda> --organization-id <int> --output-dir <dir> [--file-name <ime.csv>]");
  return 0;
}

var exportProfile = args.Contains("--export-profile", StringComparer.Ordinal);
if (!args.Contains("--export-magento", StringComparer.Ordinal) && !exportProfile)
  throw new ArgumentException("Podprta sta ukaza --export-magento in --export-profile.");

var organizationId = RequiredInt(args, "--organization-id");
var outputDirectory = Required(args, "--output-dir");
var connectionString = Environment.GetEnvironmentVariable("PIM_CONNECTION_STRING");
if (string.IsNullOrWhiteSpace(connectionString))
  throw new InvalidOperationException("Manjka PIM_CONNECTION_STRING; worker ne bere appsettings ali drugih virov konfiguracije.");

if (exportProfile)
{
  // En profil, ena datoteka: hitra osvezitev cen in zaloge (MAGENTO_STOCK_PRICES, migracija 146).
  var profileCode = Required(args, "--export-profile");
  var fileNameIndex = Array.IndexOf(args, "--file-name");
  var fileName = fileNameIndex >= 0 && fileNameIndex + 1 < args.Length ? args[fileNameIndex + 1] : null;
  var rows = await MagentoExportCommand.ExportProfileAsync(profileCode, organizationId, outputDirectory, fileName, connectionString);
  Console.WriteLine($"Izvoz profila {profileCode} končan: {rows} vrstic v {outputDirectory}");
  return 0;
}

await MagentoExportCommand.ExecuteAsync(organizationId, outputDirectory, connectionString);
Console.WriteLine($"Magento CSV izvoz končan: {outputDirectory}");
return 0;

static string Required(string[] args, string name)
{
  var index = Array.IndexOf(args, name);
  if (index < 0 || index + 1 >= args.Length || string.IsNullOrWhiteSpace(args[index + 1])) throw new ArgumentException($"Manjka {name}.");
  return args[index + 1];
}

static int RequiredInt(string[] args, string name)
  => int.TryParse(Required(args, name), out var value) && value > 0 ? value : throw new ArgumentException($"{name} mora biti pozitiven integer.");
