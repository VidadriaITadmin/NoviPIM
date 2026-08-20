using Microsoft.Data.SqlClient;
using PIM.KatalogWorker;
using PIM.Operations;
using PIM.XmlMapping;

var modeText = Environment.GetEnvironmentVariable("PIM_SAOP_MODE") ?? "Disabled";
if (!Enum.TryParse<SaopSourceMode>(modeText, true, out var mode))
{
  Console.Error.WriteLine("Neveljaven način vira.");
  return 2;
}

WorkerArguments arguments;
try
{
  arguments = WorkerArguments.Parse(args);
}
catch (ArgumentException ex)
{
  Console.Error.WriteLine(ex.Message);
  return 2;
}
if (arguments.ShowHelp)
{
  WorkerArguments.PrintUsage();
  return 0;
}

// Live gre po svoji poti: paginacija, več organizacij in delta zajem. Fixture ostane
// enostaven bralec posnetih strani, ker je dokaz za F3 vezan nanj.
if (mode == SaopSourceMode.Live)
{
  return await RunLiveAsync(arguments);
}

var fixtureRoot = Environment.GetEnvironmentVariable("PIM_SAOP_FIXTURE_ROOT")
  ?? Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", "fixtures", "saop", "iqlighting"));
var baseUrlText = Environment.GetEnvironmentVariable("PIM_SAOP_BASE_URL");
var baseUrl = string.IsNullOrWhiteSpace(baseUrlText) ? null : new Uri(baseUrlText);
using var httpClient = new HttpClient();
ISaopSource source = SaopSource.Create(new SaopSourceOptions(mode, fixtureRoot, baseUrl), httpClient);
var pages = await source.ReadAsync();

if (mode == SaopSourceMode.Disabled)
{
  Console.WriteLine("SAOP zajem je izključen.");
  return 0;
}

var connectionString = LocalConfiguration.GetConnectionString("PIM_CONNECTION_STRING", "Pim");
if (string.IsNullOrWhiteSpace(connectionString))
{
  Console.Error.WriteLine("Manjka PIM_CONNECTION_STRING oziroma ConnectionStrings:Pim v appsettings.Local.json.");
  return 2;
}

var runId = Guid.NewGuid();
await using var operationsRun = await OperationsRun.BeginAsync(connectionString, 2, "SAOP_PRODUCTS", $"{Environment.MachineName}:{Environment.ProcessId}");
await using (var connection = new SqlConnection(connectionString))
{
  await connection.OpenAsync();
  await using var start = new SqlCommand("""
    INSERT ops.PipelineRun (RunId, Pipeline, OrganizationId, SourceCode, Status)
    VALUES (@RunId, N'SAOP_PRODUCTS', 2, N'SAOP_IQLIGHTING', N'Running');
    """, connection);
  start.Parameters.AddWithValue("@RunId", runId);
  await start.ExecuteNonQueryAsync();
}

await new RawInboxWriter(connectionString).WriteAsync(pages, runId, 2, "SAOP_IQLIGHTING");
await new SqlMappingPipeline(connectionString).ExtractAndApplyAsync(runId, 2, "SAOP_IQLIGHTING");
await using (var connection = new SqlConnection(connectionString))
{
  await connection.OpenAsync();
  await using var captured = new SqlCommand("""
    UPDATE ops.PipelineRun
    SET Status = N'Succeeded', EndedUtc = SYSUTCDATETIME(), RowsRead = @RowsRead, RowsSucceeded = @RowsRead
    WHERE RunId = @RunId;
    """, connection);
  captured.Parameters.AddWithValue("@RunId", runId);
  captured.Parameters.AddWithValue("@RowsRead", pages.Count);
  await captured.ExecuteNonQueryAsync();
}

if (mode == SaopSourceMode.Fixture)
{
  var facts = FixtureFacts.Count(pages);
  Console.WriteLine($"Fixture: izdelki={facts.GeneralProducts}, cene={facts.Prices}, opisi={facts.Descriptions}.");
}
else
{
  Console.WriteLine($"Zajetih strani: {pages.Count}.");
}

await operationsRun.CompleteAsync(true);

return 0;

static async Task<int> RunLiveAsync(WorkerArguments arguments)
{
  var connection = SaopWorkerConfiguration.GetConnectionString();
  if (string.IsNullOrWhiteSpace(connection))
  {
    Console.Error.WriteLine("Manjka PIM_CONNECTION_STRING oziroma ConnectionStrings:Pim v appsettings.Local.json.");
    return 2;
  }

  var settings = SaopWorkerConfiguration.Read();
  if (!settings.HasCredentials)
  {
    Console.Error.WriteLine(
      "Manjkajo SAOP poverilnice. Dopolni sekcijo \"Saop\" v korenski appsettings.Local.json "
      + "(BaseUrl, Username, Password) ali nastavi PIM_SAOP_BASE_URL, PIM_SAOP_USERNAME in PIM_SAOP_PASSWORD.");
    return 2;
  }

  var organizations = settings.Organizations
    .Where(organization => organization.IsActive)
    .Where(organization => arguments.OrganizationIds.Count == 0 || arguments.OrganizationIds.Contains(organization.Id))
    .ToArray();
  if (organizations.Length == 0)
  {
    Console.Error.WriteLine("V nastavitvah ni nobene aktivne organizacije, ki bi ustrezala izbiri.");
    return 2;
  }

  IReadOnlyList<SaopEndpoint> endpoints;
  try
  {
    endpoints = SaopEndpoints.Resolve(arguments.EndpointKeys);
  }
  catch (InvalidOperationException exception)
  {
    Console.Error.WriteLine(exception.Message);
    return 2;
  }

  Console.WriteLine(
    $"Živ SAOP zajem: podjetij={organizations.Length}, končnih točk={endpoints.Count}, "
    + $"{(arguments.FullSync ? "poln zajem" : "delta zajem")}{(arguments.SkipMapping ? ", brez preslikave" : "")}.");

  var runner = new SaopIngestRunner(connection, settings);

  // Zanka je v OrganizationLoop, ker mora veljati ena zaveza: padec enega podjetja ne ustavi
  // ostalih. Sem sodi tudi ops.BeginRun — manjkajoč razpored vrne 51100 in je prej ubil worker.
  var failed = await OrganizationLoop.RunAsync(
    organizations,
    beginAsync: organization =>
    {
      Console.WriteLine($"[{organization.Id}] {organization.Name} ({organization.SourceCode})");
      return OperationsRun.BeginAsync(
        connection, organization.Id, "SAOP_PRODUCTS", $"{Environment.MachineName}:{Environment.ProcessId}");
    },
    workAsync: async (organization, operationsRun) =>
    {
      var summary = await runner.RunAsync(
        organization, endpoints, arguments.FullSync, () => operationsRun.HeartbeatAsync());
      if (!arguments.SkipMapping)
      {
        await new SqlMappingPipeline(connection)
          .ExtractAndApplyAsync(summary.RunId, organization.Id, organization.SourceCode);
      }

      Console.WriteLine(
        $"  SKUPAJ strani={summary.TotalPages} zapisov={summary.TotalRecords} RunId={summary.RunId}");
      if (summary.AwaitingMappingCount > 0)
      {
        Console.WriteLine(
          $"  OPOZORILO: {summary.AwaitingMappingCount} končnih točk je zajetih brez preslikave. "
          + "Njihovi mejniki niso premaknjeni, zato jih bo naslednji zagon zajel znova.");
      }

      return summary.AllSucceeded;
    },
    completeAsync: (operationsRun, succeeded, error) => operationsRun.CompleteAsync(succeeded, error),
    disposeAsync: operationsRun => operationsRun.DisposeAsync().AsTask(),
    reportFailure: (organization, exception) =>
      Console.Error.WriteLine($"  Zajem podjetja {organization.Id} je padel: {exception.Message}"));

  return failed ? 1 : 0;
}

internal sealed record WorkerArguments(
  IReadOnlyList<string> EndpointKeys,
  IReadOnlyList<int> OrganizationIds,
  bool FullSync,
  bool SkipMapping,
  bool ShowHelp)
{
  public static WorkerArguments Parse(string[] args)
  {
    // --help/-h takes precedence over everything; no other validation needed.
    if (args.Any(a => a.ToLowerInvariant() is "--help" or "-h"))
    {
      return new WorkerArguments([], [], false, false, true);
    }

    var endpoints = new List<string>();
    var organizations = new List<int>();
    var full = false;
    var skipMapping = false;

    for (var index = 0; index < args.Length; index++)
    {
      var arg = args[index];
      switch (arg.ToLowerInvariant())
      {
        case "--endpoints":
          if (index + 1 >= args.Length)
          {
            throw new ArgumentException($"Argument '{arg}' zahteva vrednost (seznam končnih točk, npr. GetPrices,Currencies).");
          }
          endpoints.AddRange(Split(args[++index]));
          break;
        case "--organizations":
          if (index + 1 >= args.Length)
          {
            throw new ArgumentException($"Argument '{arg}' zahteva vrednost (seznam ID-jev organizacij, npr. 2,3).");
          }
          foreach (var token in Split(args[++index]))
          {
            if (!int.TryParse(token, out var parsed) || parsed <= 0)
            {
              throw new ArgumentException(
                $"Neveljaven ID organizacije: '{token}'. Vrednost mora biti pozitivno celo število.");
            }
            organizations.Add(parsed);
          }
          break;
        case "--full":
          full = true;
          break;
        case "--only-ingest":
          skipMapping = true;
          break;
        default:
          throw new ArgumentException(
            $"Neznan argument: '{arg}'. Zaženite z --help za seznam veljavnih argumentov.");
      }
    }

    return new WorkerArguments(endpoints, organizations, full, skipMapping, false);
  }

  private static IEnumerable<string> Split(string value) =>
    value.Split([',', ';'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

  public static void PrintUsage()
  {
    Console.WriteLine("""
      PIM.KatalogWorker — zajem kataloga iz SAOP.

      Način izbere okoljska spremenljivka PIM_SAOP_MODE: Disabled | Fixture | Live.

      Argumenti (samo Live):
        --endpoints A,B,C     zajemi samo naštete končne točke (privzeto vse)
        --organizations 2,3   zajemi samo našteta podjetja (privzeto vsa aktivna)
        --full                prezri mejnik in poberi vse (privzeto delta)
        --only-ingest         samo zapiši v raw.Inbox, brez preslikave v canon
        --help                ta izpis

      Znane končne točke:
      """);
    foreach (var endpoint in SaopEndpoints.All)
    {
      Console.WriteLine($"  {endpoint.Key,-30} {endpoint.Path}");
    }
  }
}
