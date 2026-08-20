using PIM.B2bWorker;

if (args.Length == 0)
{
  Console.WriteLine("PIM.B2bWorker: --export-magento --organization-id <int> --output-dir <dir>");
  return 0;
}

if (!args.Contains("--export-magento", StringComparer.Ordinal))
  throw new ArgumentException("Podprt je samo ukaz --export-magento.");

var organizationId = RequiredInt(args, "--organization-id");
var outputDirectory = Required(args, "--output-dir");
var connectionString = Environment.GetEnvironmentVariable("PIM_CONNECTION_STRING");
if (string.IsNullOrWhiteSpace(connectionString))
  throw new InvalidOperationException("Manjka PIM_CONNECTION_STRING; worker ne bere appsettings ali drugih virov konfiguracije.");

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
