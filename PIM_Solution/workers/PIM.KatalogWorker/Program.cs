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

// --map-run ne kliče SAOP, zato ne potrebuje niti načina Live niti poverilnic: podatek je
// že v raw.Inbox in gre samo skozi preslikavo.
if (arguments.MapRunId is not null || arguments.MapPending || mode == SaopSourceMode.Live)
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

  // --preslikaj-zaostanek: pospravi vse, kar je v raw.Inbox ostalo nepreslikano.
  //
  // Zaostanek nastane po zasnovi, ne po okvari: ko se preslikava dopolni (nova koncna tocka,
  // novo polje), so zajete strani ze v bazi in nova preslikava jih ne vidi, ker cakajo kot
  // Pending pod svojim RunId. Worker je doslej znal preslikati en zagon, ce si njegov RunId
  // nasel sam. V nocnem opravilu to ne gre — zato si zagone poisce sam.
  //
  // Vir ni omejen na SAOP: iste vrstice pusca za sabo tudi dobaviteljev XML, cevovod pa je
  // za oba isti. Podjetje in vir bereva iz vrstic, ne iz nastavitev, ker je samo tam resnica.
  if (arguments.MapPending)
  {
    var backlog = await ReadPendingRunsAsync(connection, arguments.OrganizationIds);
    if (backlog.Count == 0)
    {
      Console.WriteLine("V raw.Inbox ni nepreslikanih vrstic.");
      return 0;
    }

    Console.WriteLine($"Zagonov z nepreslikanimi vrsticami: {backlog.Count}.");
    var mappedTotal = 0;
    var padli = 0;
    foreach (var (runId, organizationId, sourceCode, pending) in backlog)
    {
      Console.WriteLine($"  {sourceCode} [{organizationId}] {runId}: {pending} vrstic.");
      try
      {
        await new SqlMappingPipeline(connection).ExtractAndApplyAsync(runId, organizationId, sourceCode);
      }
      catch (Exception exception)
      {
        // Padec enega zagona ne sme ustaviti ostalih — enako pravilo kot pri zajemu podjetij.
        Console.Error.WriteLine($"  Preslikava zagona {runId} je padla: {exception.Message}");
        padli++;
        continue;
      }
      var left = await CountPendingAsync(connection, runId, organizationId, sourceCode);
      Console.WriteLine($"    obdelano {pending - left}, ostalo Pending {left}.");
      mappedTotal += pending - left;
    }

    Console.WriteLine($"SKUPAJ preslikanih vrstic raw.Inbox: {mappedTotal}; padlih zagonov: {padli}.");
    return padli > 0 ? 1 : 0;
  }

  var settings = SaopWorkerConfiguration.Read();
  if (!settings.HasCredentials && arguments.MapRunId is null && !arguments.MapPending)
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

  // --map-run: preslikaj že zajet zagon. Brez klica na SAOP in brez poverilnic — podatek je
  // že v raw.Inbox. Potrebno je zato, ker --only-ingest pusti vrstice Pending in bi jih sicer
  // bilo treba pobrati še enkrat; delta zajem jih po premaknjenem mejniku ne bi več prinesel.
  if (arguments.MapRunId is { } mapRunId)
  {
    Console.WriteLine($"Preslikava že zajetega zagona {mapRunId}; klica na SAOP ni.");
    if (arguments.Reprocess)
    {
      // Isti ukaz kot pri PIM.XmlFileWorker: strani tega zagona gredo nazaj na Pending, da jih
      // dopolnjena preslikava lahko obdela. Nič se ne briše — vsi zapisi so združevalni.
      var reopened = await ReopenRunAsync(connection, mapRunId);
      Console.WriteLine($"Na ponovno preslikavo postavljenih strani: {reopened}.");
    }
    var mapped = 0;
    foreach (var organization in organizations)
    {
      var pending = await CountPendingAsync(connection, mapRunId, organization.Id, organization.SourceCode);
      if (pending == 0)
      {
        Console.WriteLine($"[{organization.Id}] {organization.Name}: v tem zagonu ni nepreslikanih vrstic.");
        continue;
      }

      Console.WriteLine($"[{organization.Id}] {organization.Name}: {pending} nepreslikanih vrstic.");
      await new SqlMappingPipeline(connection).ExtractAndApplyAsync(mapRunId, organization.Id, organization.SourceCode);
      var left = await CountPendingAsync(connection, mapRunId, organization.Id, organization.SourceCode);
      Console.WriteLine($"[{organization.Id}] {organization.Name}: obdelano {pending - left}, ostalo Pending {left}.");
      mapped += pending - left;
    }

    Console.WriteLine($"SKUPAJ preslikanih vrstic raw.Inbox: {mapped}.");
    return 0;
  }

  Console.WriteLine(
    $"Živ SAOP zajem: podjetij={organizations.Length}, končnih točk={endpoints.Count}, "
    + $"{(arguments.FullSync ? "poln zajem" : "delta zajem")}{(arguments.SkipMapping ? ", brez preslikave" : "")}.");

  if (arguments.MaxPages is { } pageLimit)
  {
    // SaopSettings je nespremenljiv; za meritev naredimo kopijo z drugo mejo strani.
    settings = settings with { MaxPagesPerEndpoint = pageLimit };
    Console.WriteLine($"MERITEV: omejeno na {pageLimit} strani na koncno tocko.");
  }
  if (arguments.PageSize is { } size)
  {
    settings = settings with { PageSize = size };
    Console.WriteLine($"MERITEV: {size} zapisov na stran.");
  }
  if (arguments.IncludeNonActive == false)
  {
    settings = settings with { IncludeNonActiveItems = false };
    Console.WriteLine("MERITEV: brez neaktivnih artiklov.");
  }

  var runner = new SaopIngestRunner(connection, settings);
  var parallel = Math.Min(arguments.MaxParallelOrganizations, organizations.Length);
  if (parallel > 1)
  {
    Console.WriteLine($"Podjetja tečejo vzporedno ({parallel} hkrati).");
    Console.WriteLine($"Meja na klic: {settings.PageSize} zapisov na stran, največ {settings.MaxPagesPerEndpoint} strani na končno točko.");
  }
  if (arguments.MaxParallelEndpoints > 1)
  {
    Console.WriteLine(
      $"Znotraj podjetja tece {arguments.MaxParallelEndpoints} koncnih tock hkrati — "
      + $"najvec {parallel * arguments.MaxParallelEndpoints} hkratnih zahtevkov na SAOP.");
  }

  // Vzporedno bi se izpisi podjetij prepletali v kašo. Vsako podjetje zato piše v svoj
  // medpomnilnik, ki se izpiše v enem kosu, ko je podjetje končano.
  var consoleLock = new object();
  var buffers = organizations.ToDictionary(organization => organization.Id, _ => new System.Text.StringBuilder());
  void Log(SaopOrganization organization, string line)
  {
    if (parallel <= 1) { Console.WriteLine(line); return; }
    lock (consoleLock) { buffers[organization.Id].AppendLine(line); }
  }
  void Flush(SaopOrganization organization)
  {
    if (parallel <= 1) return;
    lock (consoleLock)
    {
      Console.Write(buffers[organization.Id].ToString());
      buffers[organization.Id].Clear();
    }
  }

  // Zanka je v OrganizationLoop, ker mora veljati ena zaveza: padec enega podjetja ne ustavi
  // ostalih. Sem sodi tudi ops.BeginRun — manjkajoč razpored vrne 51100 in je prej ubil worker.
  var failed = await OrganizationLoop.RunAsync(
    organizations,
    beginAsync: organization =>
    {
      Log(organization, $"[{organization.Id}] {organization.Name} ({organization.SourceCode})");
      return OperationsRun.BeginAsync(
        connection, organization.Id, "SAOP_PRODUCTS", $"{Environment.MachineName}:{Environment.ProcessId}");
    },
    workAsync: async (organization, operationsRun) =>
    {
      var summary = await runner.RunAsync(
        organization, endpoints, arguments.FullSync, () => operationsRun.HeartbeatAsync(),
        skipMapping: arguments.SkipMapping, log: line => Log(organization, line),
        maxParallelEndpoints: arguments.MaxParallelEndpoints);
      if (!arguments.SkipMapping)
      {
        await new SqlMappingPipeline(connection)
          .ExtractAndApplyAsync(summary.RunId, organization.Id, organization.SourceCode);

        // Sele zdaj, ko je podatek v katalogu, se sme mejnik premakniti. Prej je stal tu
        // zajem, preslikava pa je prisla za njim — in ce je podjetje vmes padlo, je mejnik
        // ostal pred nepreslikanim podatkom.
        var advanced = await runner.AdvanceWatermarksAsync(summary, organization);
        var candidates = summary.Endpoints.Count(endpoint => endpoint.WatermarkAdvanced);
        if (advanced.Count < candidates)
        {
          Log(organization,
            $"  OPOZORILO: mejnik premaknjen za {advanced.Count} od {candidates} upravicenih koncnih tock; "
            + "za ostale je v raw.Inbox ostalo nepreslikano. Isto obdobje bo zajeto znova.");
        }
      }

      Log(organization,
        $"  SKUPAJ strani={summary.TotalPages} zapisov={summary.TotalRecords} RunId={summary.RunId}");
      var backlog = summary.Endpoints.Where(endpoint => endpoint.PendingBacklog > 0).ToArray();
      if (backlog.Length > 0)
      {
        Log(organization,
          "  OPOZORILO: v raw.Inbox ležijo nepreslikane vrstice iz prejšnjih zagonov: "
          + string.Join(", ", backlog.Select(endpoint => $"{endpoint.EndpointKey}={endpoint.PendingBacklog}"))
          + ". Preslikaj jih z --map-run <RunId tistega zagona>; poizvedba:"
          + " SELECT DISTINCT RunId, EntityType FROM raw.Inbox WHERE Status=N'Pending';");
      }

      if (summary.AwaitingMappingCount > 0)
      {
        Log(organization,
          $"  OPOZORILO: pri {summary.AwaitingMappingCount} končnih točkah mejnik stoji. "
          + "Zajeti podatek leži v raw.Inbox in ga bo naslednji zagon zajel znova; "
          + "če ga hočeš preslikati brez ponovnega klica, uporabi --map-run " + summary.RunId + ".");
      }

      Flush(organization);
      return summary.AllSucceeded;
    },
    completeAsync: (operationsRun, succeeded, error) => operationsRun.CompleteAsync(succeeded, error),
    disposeAsync: operationsRun => operationsRun.DisposeAsync().AsTask(),
    reportFailure: (organization, exception) =>
    {
      Flush(organization);
      Console.Error.WriteLine($"  Zajem podjetja {organization.Id} je padel: {exception.Message}");
    },
    maxParallel: parallel);

  return failed ? 1 : 0;
}

static async Task<IReadOnlyList<(Guid RunId, int OrganizationId, string SourceCode, int Pending)>> ReadPendingRunsAsync(
  string connectionString, IReadOnlyList<int> organizationIds)
{
  await using var connection = new SqlConnection(connectionString);
  await connection.OpenAsync();
  await using var command = new SqlCommand("""
    SELECT RunId, OrganizationId, SourceCode, COUNT(*) AS Pending
    FROM raw.Inbox
    WHERE Status = N'Pending'
    GROUP BY RunId, OrganizationId, SourceCode
    ORDER BY MIN(ReceivedUtc);
    """, connection) { CommandTimeout = 300 };
  await using var reader = await command.ExecuteReaderAsync();
  var runs = new List<(Guid, int, string, int)>();
  while (await reader.ReadAsync())
  {
    var organizationId = reader.GetInt32(1);
    if (organizationIds.Count > 0 && !organizationIds.Contains(organizationId)) continue;
    runs.Add((reader.GetGuid(0), organizationId, reader.GetString(2), reader.GetInt32(3)));
  }
  return runs;
}

static async Task<int> CountPendingAsync(string connectionString, Guid runId, int organizationId, string sourceCode)
{
  await using var connection = new SqlConnection(connectionString);
  await connection.OpenAsync();
  await using var command = new SqlCommand(
    "SELECT COUNT(*) FROM raw.Inbox WHERE RunId=@RunId AND OrganizationId=@OrganizationId "
    + "AND SourceCode=@SourceCode AND Status=N'Pending';",
    connection);
  command.Parameters.AddWithValue("@RunId", runId);
  command.Parameters.AddWithValue("@OrganizationId", organizationId);
  command.Parameters.AddWithValue("@SourceCode", sourceCode);
  return Convert.ToInt32(await command.ExecuteScalarAsync());
}

static async Task<int> ReopenRunAsync(string connectionString, Guid runId)
{
  // Samo stanje strani, brez brisanja: že izluščene vrednosti in zapisani podatki ostanejo,
  // preslikava jih ob ponovnem zagonu združi (MERGE oziroma "vstavi, če še ni").
  await using var connection = new SqlConnection(connectionString);
  await connection.OpenAsync();
  await using var command = new SqlCommand("""
    UPDATE raw.Inbox SET Status=N'Pending', ProcessedUtc=NULL
    WHERE RunId=@RunId AND Status IN (N'Processed', N'Quarantined');
    """, connection);
  command.Parameters.AddWithValue("@RunId", runId);
  return await command.ExecuteNonQueryAsync();
}

internal sealed record WorkerArguments(
  IReadOnlyList<string> EndpointKeys,
  IReadOnlyList<int> OrganizationIds,
  bool FullSync,
  bool SkipMapping,
  bool ShowHelp,
  Guid? MapRunId = null,
  int MaxParallelOrganizations = 1,
  int MaxParallelEndpoints = 1,
  int? MaxPages = null,
  int? PageSize = null,
  bool? IncludeNonActive = null,
  bool Reprocess = false,
  bool MapPending = false)
{
  public static WorkerArguments Parse(string[] args)
  {
    // --help/-h takes precedence over everything; no other validation needed.
    if (args.Any(a => a.ToLowerInvariant() is "--help" or "-h"))
    {
      return new WorkerArguments([], [], false, false, true);
    }

    var reprocess = false;
    var mapPending = false;
    var endpoints = new List<string>();
    var organizations = new List<int>();
    var full = false;
    var skipMapping = false;
    Guid? mapRunId = null;
    var maxParallel = 1;
    var maxParallelEndpoints = 1;
    int? maxPages = null;
    int? pageSize = null;
    bool? includeNonActive = null;

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
        case "--max-parallel":
          // Vzporednost je po podjetjih, ne po koncnih tockah: znotraj podjetja gre en klic
          // naenkrat, zato SAOP nikoli ne dobi vec hkratnih zahtevkov, kot je podjetij.
          if (index + 1 >= args.Length)
          {
            throw new ArgumentException($"Argument '{arg}' zahteva vrednost (stevilo hkratnih podjetij).");
          }
          if (!int.TryParse(args[++index], out maxParallel) || maxParallel < 1 || maxParallel > 8)
          {
            throw new ArgumentException($"Neveljavna vrednost --max-parallel: '{args[index]}'. Dovoljeno je 1 do 8.");
          }
          break;
        case "--max-parallel-endpoints":
          // Merilno stikalo. Vsaka hkratna koncna tocka je dodaten hkraten zahtevek na SAOP
          // za ISTO podjetje, zato privzeto ostaja 1, dokler ne izmerimo, ali sploh pomaga.
          if (index + 1 >= args.Length)
          {
            throw new ArgumentException($"Argument '{arg}' zahteva vrednost (stevilo hkratnih koncnih tock).");
          }
          if (!int.TryParse(args[++index], out maxParallelEndpoints) || maxParallelEndpoints < 1 || maxParallelEndpoints > 8)
          {
            throw new ArgumentException($"Neveljavna vrednost --max-parallel-endpoints: '{args[index]}'. Dovoljeno je 1 do 8.");
          }
          break;
        case "--max-pages":
          // Za meritve: ustavi se po n straneh na koncno tocko, da ni treba cakati celega zajema.
          if (index + 1 >= args.Length)
          {
            throw new ArgumentException($"Argument '{arg}' zahteva vrednost (stevilo strani na koncno tocko).");
          }
          if (!int.TryParse(args[++index], out var parsedMaxPages) || parsedMaxPages < 1)
          {
            throw new ArgumentException($"Neveljavna vrednost --max-pages: '{args[index]}'.");
          }
          maxPages = parsedMaxPages;
          break;
        case "--page-size":
          // Za meritve: koliko zapisov naj SAOP vrne na stran.
          if (index + 1 >= args.Length) throw new ArgumentException($"Argument '{arg}' zahteva vrednost.");
          if (!int.TryParse(args[++index], out var parsedPageSize) || parsedPageSize < 1 || parsedPageSize > 5000)
            throw new ArgumentException($"Neveljavna vrednost --page-size: '{args[index]}'. Dovoljeno je 1 do 5000.");
          pageSize = parsedPageSize;
          break;
        case "--brez-neaktivnih":
          // Za meritve: ali naj SAOP vkljuci tudi neaktivne artikle.
          includeNonActive = false;
          break;
        case "--preslikaj-zaostanek":
          // Preslika vse zagone, ki imajo v raw.Inbox se kaksno vrstico Pending. Rabi se v
          // nocnem opravilu: zaostanek nastane vsakic, ko se preslikava dopolni po zajemu,
          // in doslej ga je bilo treba pobrati rocno, RunId po RunId.
          mapPending = true;
          break;
        case "--znova-preslikaj":
          // Kot --map-run, le da najprej vrne že obdelane in karantenirane strani na Pending.
          reprocess = true;
          goto case "--map-run";
        case "--map-run":
          // Preslikaj že zajet zagon, brez novega klica na SAOP. Potrebno, ker --only-ingest
          // pusti vrstice Pending: brez tega bi bilo treba iste podatke pobrati še enkrat.
          if (index + 1 >= args.Length)
          {
            throw new ArgumentException($"Argument '{arg}' zahteva vrednost (RunId iz ops.PipelineRun).");
          }
          if (!Guid.TryParse(args[++index], out var parsedRunId))
          {
            throw new ArgumentException($"Neveljaven RunId: '{args[index]}'. Pričakovan je GUID.");
          }
          mapRunId = parsedRunId;
          break;
        default:
          throw new ArgumentException(
            $"Neznan argument: '{arg}'. Zaženite z --help za seznam veljavnih argumentov.");
      }
    }

    if (mapRunId is not null && skipMapping)
    {
      throw new ArgumentException("--map-run in --only-ingest se izključujeta: prvi preslika, drugi preslikavo preskoči.");
    }

    if (mapPending && (mapRunId is not null || skipMapping))
    {
      throw new ArgumentException(
        "--preslikaj-zaostanek se izključuje z --map-run in --only-ingest: sam si poišče zagone z nepreslikanimi vrsticami.");
    }

    return new WorkerArguments(endpoints, organizations, full, skipMapping, false, mapRunId, maxParallel, maxParallelEndpoints, maxPages, pageSize, includeNonActive, reprocess, mapPending);
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
                              (mejnik se v tem primeru NE premakne)
        --map-run <RunId>     preslikaj že zajet zagon iz raw.Inbox, brez klica na SAOP
        --znova-preslikaj <RunId>  isto, a strani najprej vrne na Pending (po dopolnjeni preslikavi)
        --preslikaj-zaostanek preslikaj vse zagone, ki imajo se kaksno vrstico Pending
        --help                ta izpis

      Znane končne točke:
      """);
    foreach (var endpoint in SaopEndpoints.All)
    {
      Console.WriteLine($"  {endpoint.Key,-30} {endpoint.Path}");
    }
  }
}
