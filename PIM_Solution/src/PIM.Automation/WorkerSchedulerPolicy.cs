using System.Globalization;

namespace PIM.Automation;

/*
  Gradniki korakov za posle gostitelja avtomatike (PIM.AutomationHost, JobCatalog).

  Do bloka 1 prenove nadzora (2026-09-22, migracija 254) je bil tu tudi razporejevalnik v intranetu
  (221, 2026-09-17): katalog ciklov (zaloga, katalog, nadzor, nočni tok, samotest, magento-csv),
  njihov načrt, prvi termin in presoja zaostanka nad ops.WorkerCycle*. Migracija 254 je tabele in
  procedure ciklov odstranila, intranet pa ne poganja ničesar več: edini motor avtomatike je
  PIM.AutomationHost nad ops.JobDefinition, ops.JobRun in ops.JobStepRun.

  Ostalo je, iz česar JobCatalog sestavi korake poslov (Worker, Note, StockFilesSteps, XmlSteps,
  PlanSamotest, mape izvoza), okolje zagona (CycleEnvironment), ime lastnika najema in dnevni
  termin. Imena Cycle* in WorkerCycles so ostala, da se JobCatalog, JobRunner in testi ne
  spreminjajo hkrati. Vse se da preveriti brez baze in brez procesa (PIM.F10.IntranetLogicTests);
  kar potrebuje disk ali bazo (seznam datotek, podjetja, register map), pride prek CycleEnvironment.
*/

public enum CycleStepKind
{
  /// <summary>Proces workerja ali orodja; uspeh je izhodna koda 0.</summary>
  Process,
  /// <summary>SQL ukazi nad bazo (validacija, objava); uspeh je odsotnost napake.</summary>
  Sql,
  /// <summary>Samo vrstica v dnevniku (»preskočeno: …«); ne šteje kot napaka.</summary>
  Note,
  /// <summary>Koraki, ki jih je mogoče določiti šele med tekom — po prevzemu je treba pogledati, katere
  /// datoteke so prišle. <see cref="CycleStep.Expand"/> jih vrne, ko pridejo na vrsto.</summary>
  Expand,
}

/// <param name="Command">Kar gre v ops.JobStepRun.Command in v dnevnik: človeku berljiv ukaz.</param>
/// <param name="Sql">Ukazi, izvedeni po vrsti z <c>@OrganizationId</c> = <paramref name="OrganizationId"/>.</param>
public sealed record CycleStep(
  string Name, CycleStepKind Kind, string Command,
  WorkerLaunchStep? Process = null, IReadOnlyDictionary<string, string>? Environment = null,
  IReadOnlyList<string>? Sql = null, int? OrganizationId = null,
  Func<IReadOnlyList<CycleStep>>? Expand = null);

/// <summary>
/// Skupina korakov = en »Korak« iz skript: če katerikoli korak v njej pade, se preostali v isti
/// skupini preskočijo, skupina šteje kot padla, posel pa gre naprej na naslednjo skupino (razen v
/// skupino z <c>RequiresAllPrevious</c>, ki je takrat blokirana). Pravilo uveljavlja JobRunner.
/// </summary>
public sealed record CycleGroup(string Name, IReadOnlyList<CycleStep> Steps, bool RequiresAllPrevious = false);

/// <summary>
/// Vse, kar načrt posla potrebuje od sveta zunaj sebe. Gostitelj ga sestavi iz baze in diska
/// (AutomationEnvironment.BuildAsync), test iz konstant — načrt sam je čista funkcija.
/// </summary>
/// <param name="Organizations">Aktivna podjetja (skripte: privzeto 1, 2, 3, 4).</param>
/// <param name="CatalogOrganizationId">Podjetje, katerega artikli in stranke gredo v katalog.csv (2, uporabnik 2026-09-15).</param>
/// <param name="LandingRoot">Koren prevzema (register LANDING_ROOT ali privzetek), isti kot ga dobi prevzemnik z <c>--target</c>.</param>
/// <param name="ExportRoot">Register EXPORT_ROOT; kadar je nastavljen, izvozni worker mapo razreši sam.</param>
/// <param name="FixturesRoot">Mapa <c>fixtures</c> na razvoju (rezervni vir dobaviteljevega XML); null na strežniku.</param>
/// <param name="IsFullCatalogDay">Prvi dan v mesecu: poln zajem kataloga iz SAOP namesto delte.</param>
/// <param name="MaxParallel">Automation:MaxParallel. Noben posel ga zdaj ne bere (SAOP posli tečejo z
/// <c>--max-parallel 1</c>, ekipa SAOP 2026-09-22); ostaja, da se klicatelji okolja ne spreminjajo.</param>
/// <param name="ListFiles">Datoteke v mapi (polne poti), že brez oznak prevzema (.prenos, .pocakaj) in Excelovih zaklepov.</param>
public sealed record CycleEnvironment(
  WorkerPaths Paths, IReadOnlyList<int> Organizations, int CatalogOrganizationId,
  string LandingRoot, string? ExportRoot, string? FixturesRoot, bool IsFullCatalogDay, int MaxParallel,
  Func<string, bool> DirectoryExists, Func<string, IReadOnlyList<string>> ListFiles);

public static class WorkerCycles
{
  /// <summary>Podjetje kataloga (katalog.csv, stranke.csv): en par datotek, samo IQLighting.</summary>
  public const int CatalogOrganization = 2;

  internal static readonly IReadOnlyDictionary<string, string> SaopLive = new Dictionary<string, string> { ["PIM_SAOP_MODE"] = "Live" };

  /// <summary>Ime lastnika najema: računalnik, proces in vloga gostitelja (<see cref="AutomationApplications"/>), da se na strani vidi, kdo je ura.</summary>
  public static string OwnerName(string hostName, int processId, string application) => $"{hostName}:{processId.ToString(CultureInfo.InvariantCulture)}:{application}";

  // ─── Naslednji termin ─────────────────────────────────────────────────────

  /// <summary>
  /// Termin, šteto od <paramref name="fromUtc"/>: ponavljajoč posel <paramref name="fromUtc"/> + razmik,
  /// dnevni naslednja pojavitev ure v naši uri; ura, ki je na dan prehoda na poletni čas ne obstaja,
  /// se premakne za uro naprej. Gostitelj ga poda ob prevzemu (ops.ClaimJobRun), po koncu teka pa
  /// termin prepiše JobCatalog.NextAfterEnd, ki za dnevni posel spet kliče to funkcijo.
  /// </summary>
  public static DateTime NextDue(int? intervalSeconds, TimeOnly? dailyAtLocal, DateTime fromUtc, TimeZoneInfo zone)
  {
    var from = DateTime.SpecifyKind(fromUtc, DateTimeKind.Utc);
    if (intervalSeconds is { } interval) return from.AddSeconds(interval);
    if (dailyAtLocal is not { } at) throw new InvalidOperationException("Cikel nima ne razmika ne dnevne ure.");

    var localNow = TimeZoneInfo.ConvertTimeFromUtc(from, zone);
    var candidate = DateTime.SpecifyKind(localNow.Date.Add(at.ToTimeSpan()), DateTimeKind.Unspecified);
    if (candidate <= localNow) candidate = candidate.AddDays(1);
    if (zone.IsInvalidTime(candidate)) candidate = candidate.AddHours(1);
    return TimeZoneInfo.ConvertTimeToUtc(candidate, zone);
  }

  // ─── Načrt korakov ────────────────────────────────────────────────────────

  /// <summary>Nocni-samotest.ps1: tests\PIM.SelfTest.Nightly — objavljen ob workerjih ali dotnet run iz izvorne kode.</summary>
  internal static IReadOnlyList<CycleGroup> PlanSamotest(CycleEnvironment env)
  {
    var environment = new Dictionary<string, string>
    {
      ["PIM_SELFTEST_PROFILE"] = "MAGENTO_STOCK_PRICES",
      ["PIM_SELFTEST_ORG"] = Org(env.CatalogOrganizationId),
      // Enaka pogodba kot pri ops.BeginRun (144): ob štirih zjutraj je razlika med »urnik« in »nekdo je pritisnil« prvo vprašanje.
      ["PIM_TRIGGERED_BY"] = "Task",
    };

    const string tool = "PIM.SelfTest.Nightly";
    CycleStep step;
    if (env.Paths.PublishedWorker(tool) is { } exe)
      step = new("Samotest", CycleStepKind.Process, tool, new(exe, [], Path.GetDirectoryName(exe) ?? "", tool, null), environment);
    else if (env.Paths.SolutionRoot.Length > 0)
    {
      // --no-build je namenoma izpuščen: samotest teče na tem, kar je v repozitoriju zdaj (Nocni-samotest.ps1).
      var project = Path.Combine(env.Paths.SolutionRoot, "tests", tool);
      step = new("Samotest", CycleStepKind.Process, $"dotnet run --project tests\\{tool}",
        new("dotnet", ["run", "--project", project], env.Paths.SolutionRoot, $"dotnet run --project tests\\{tool}", null), environment);
    }
    else
      step = Note("Samotest", $"preskočeno: {tool} ni objavljen ob workerjih in izvorne kode ni.");

    return [new("Nočni samotest", [step])];
  }

  // ─── Gradniki ─────────────────────────────────────────────────────────────

  /// <summary>
  /// En korak na datoteko vira zaloge: worker jo prebere enkrat in zapiše vsem podjetjem (--organizations);
  /// padec enega podjetja ne ustavi drugih (worker). Ista datoteka drugič je isti posnetek (worker to pove sam).
  /// </summary>
  internal static IReadOnlyList<CycleStep> StockFilesSteps(string vir, string mapa, CycleEnvironment env, string[] urnik)
  {
    if (!env.DirectoryExists(mapa)) return [Note($"Branje {vir}", $"preskočeno: mape {mapa} ni")];
    var datoteke = env.ListFiles(mapa);
    if (datoteke.Count == 0) return [Note($"Branje {vir}", "preskočeno: prevzete datoteke ni")];

    var steps = new List<CycleStep>();
    foreach (var datoteka in datoteke)
      steps.Add(Worker($"Zaloga {vir} (podjetja {Orgs(env)})", "PIM.StockFileWorker",
        ["--file", datoteka, "--source", vir, "--organizations", Orgs(env), .. urnik], env.Paths));
    return steps;
  }

  /// <summary>Dobaviteljev XML na podjetje: mapa prevzema, sicer fixtures (razvoj), sicer preskok.</summary>
  internal static IReadOnlyList<CycleStep> XmlSteps(string sourceCode, string fixtureFolder, CycleEnvironment env)
  {
    var prevzeta = Path.Combine(env.LandingRoot, sourceCode);
    string? root = env.DirectoryExists(prevzeta) && env.ListFiles(prevzeta).Count > 0 ? prevzeta
      : env.FixturesRoot is { } fixtures && env.DirectoryExists(Path.Combine(fixtures, fixtureFolder)) ? Path.Combine(fixtures, fixtureFolder)
      : null;
    if (root is null) return [Note($"XML {sourceCode}", $"preskočeno: ni mape {prevzeta} z datotekami")];

    return env.Organizations.Select(org => Worker($"XML {sourceCode} (podjetje {org})", "PIM.XmlFileWorker", [], env.Paths, org,
      new Dictionary<string, string>
      {
        ["PIM_XML_SOURCE_CODE"] = sourceCode,
        ["PIM_XML_ORGANIZATION_ID"] = Org(org),
        ["PIM_XML_ROOT"] = root,
      })).ToList();
  }

  internal static CycleStep Worker(string name, string worker, IReadOnlyList<string> arguments, WorkerPaths paths, int? org = null,
    IReadOnlyDictionary<string, string>? environment = null)
  {
    var launch = WorkerJobs.LaunchWorker(worker, arguments, paths, org);
    return new(name, CycleStepKind.Process, launch.Display, launch, environment, OrganizationId: org);
  }

  internal static CycleStep Note(string name, string note) => new(name, CycleStepKind.Note, note);

  /// <summary>
  /// Mapa za magento-stock-prices.csv podjetja: &lt;EXPORT_ROOT&gt;\&lt;podjetje&gt;, sicer ista mapa kot v skripti.
  /// Vsako podjetje ima svojo mapo, ker je ime datoteke za vsa enako (prej so si jo v EXPORT_ROOT prepisovala).
  /// </summary>
  internal static string[] ExportDirectory(CycleEnvironment env, int org) =>
    ["--output-dir", StockExportDirectory(env, org)];

  internal static string StockExportDirectory(CycleEnvironment env, int org) =>
    env.ExportRoot is { Length: > 0 } root ? Path.Combine(root, Org(org)) : env.Paths.ExportDirectory(org);

  internal static string Orgs(CycleEnvironment env) => string.Join(",", env.Organizations.Select(Org));
  internal static string Org(int value) => value.ToString(CultureInfo.InvariantCulture);
}
