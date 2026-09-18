using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace PIM.Intranet.Services;

/*
  Ročni zagon workerjev iz intraneta (/sistem/workerji, 2026-09-15).

  Uporabnik: »v aplikaciji mi omogoči da ročno poženem in spremljam potem kaj se zgodi in da
  vidim loge od vsakega workerja«. Doslej je bila edina pot ukazna vrstica, dnevniki pa so bili
  datoteke v mapi logs, ki jih ni gledal nihče — zato je zaloga lahko šest dni stala, ne da bi
  kdo opazil.

  Od 2026-09-17 cikli ne tečejo več prek PowerShell skript, ampak v procesu intraneta
  (WorkerSchedulerPolicy.cs, WorkerCycleRunner) — zato tu ni več sestavljanja ukaza za
  powershell.exe; posel vrste Cycle samo pove, kateri cikel in s katerimi stikali.

  Tu je vse, kar se da preveriti brez procesa in brez baze: katalog poslov, sestava ukaza,
  razvrstitev vrstice dnevnika, ime datoteke ročnega zagona in branje izpisa schtasks. Datoteka
  je povezana v PIM.F10.IntranetLogicTests, zato nima odvisnosti izven BCL.
*/

/// <summary>Kako daleč seže zagon. Od tega je odvisno, ali ga mora skrbnik posebej potrditi.</summary>
public enum WorkerJobReach
{
  /// <summary>Bere in piše samo našo bazo in datoteke.</summary>
  Internal,
  /// <summary>Kliče SAOP ali dobavitelja v živo (AGENTS.md §4.5: to je odločitev človeka).</summary>
  ExternalCall,
  /// <summary>Pošlje e-pošto pravim prejemnikom.</summary>
  SendsEmail,
}

/// <summary>Cikel teče v procesu intraneta po načrtu iz <see cref="WorkerCycles"/>; worker je en proces.</summary>
public enum WorkerJobKind { Cycle, Worker }

/// <param name="Target">Za cikel ključ cikla (<see cref="WorkerCycles"/>), za worker ime projekta.</param>
/// <param name="Arguments">Argumenti; <c>{org}</c> in <c>{izvoz}</c> se zamenjata ob zagonu.</param>
/// <param name="PerOrganization">Worker nima notranje zanke po podjetjih in se kliče enkrat na podjetje.</param>
/// <param name="OrganizationsArgument">Kako se poda izbor podjetij; null, kadar ga posel ne pozna.</param>
/// <param name="Pipelines">Postopki v ops.ScheduleProfile, ki jih zagon odpre prek ops.BeginRun.
/// Izklopljen postopek zavrne tudi ročni zagon (51100), zato jih stran pokaže pred gumbom.</param>
/// <param name="ScriptLogPrefix">Predpona dnevnika, ki ga je za isti cikel pisala skripta v mapo dnevnikov.</param>
/// <param name="FixedOrganizationId">Posel vedno teče za to podjetje, ne glede na izbiro na strani —
/// katalog.csv/stranke.csv sta en par datotek samo za podjetje 2 (uporabnik 2026-09-15).</param>
/// <param name="Cycle">Stikala cikla (samo <see cref="WorkerJobKind.Cycle"/>); null pomeni privzeta.</param>
public sealed record WorkerJob(
  string Key, string Group, string Label, string Description,
  WorkerJobKind Kind, string Target, IReadOnlyList<string> Arguments,
  bool PerOrganization, string? OrganizationsArgument,
  WorkerJobReach Reach, string? ReachNote,
  IReadOnlyList<string> Pipelines, string? ScriptLogPrefix,
  IReadOnlyDictionary<string, string>? Environment = null,
  int? FixedOrganizationId = null,
  CycleOptions? Cycle = null);

/// <summary>En proces, ki ga zagon požene. Posel na podjetje ima en korak na podjetje.</summary>
public sealed record WorkerLaunchStep(
  string FileName, IReadOnlyList<string> Arguments, string WorkingDirectory, string Display, int? OrganizationId);

/// <param name="PublishedWorker">Pot do objavljenega .exe ali null; na razvojnem računalniku ga ni
/// in worker teče z <c>dotnet run --no-build</c>, enako kot iz skript.</param>
/// <param name="ExportDirectory">Izvozna mapa podjetja (samo za izvoze, ki jih worker sam ne razreši).</param>
/// <param name="PublishedWorkersRoot">Mapa objavljenih workerjev (<c>&lt;mapa&gt;\&lt;Worker&gt;\&lt;Worker&gt;.exe</c>); null na razvoju.</param>
public sealed record WorkerPaths(
  string RepositoryRoot, string SolutionRoot,
  Func<string, string?> PublishedWorker, Func<int, string> ExportDirectory, string? PublishedWorkersRoot = null);

/// <param name="ErrorLines">Vrstice z napako v zadnjih 64 KB datoteke.</param>
/// <param name="ExitCode">Samo pri zagonu iz intraneta: izhodna koda iz zadnje vrstice, null če ni končal.</param>
public sealed record WorkerLogFile(
  string RelativePath, string Kind, DateTime LastWriteUtc, long Length, int ErrorLines, int? ExitCode, string? JobKey);

/// <param name="Available">Ali se na tem strežniku da kaj pognati: z izvorno kodo (razvoj) ali z
/// objavljenimi workerji (strežnik). Kaj od tega je, pove <paramref name="HasSource"/>.</param>
/// <param name="RepositoryRoot">Koren, ob katerem so dnevniki, izvozi in prevzem: repozitorij (razvoj) ali
/// mapa intraneta (objava v eno mapo); prazno, kadar sta znana samo objavljena workerja.</param>
/// <param name="LogRoot">Mapa dnevnikov (<c>&lt;koren&gt;\logs</c>); razporejevalnik jo ob zagonu lahko zamenja
/// z registrom LOG_ROOT ali z rezervno mapo, kadar ta ni zapisljiva (IIS).</param>
/// <param name="PublishedWorkersRoot">Mapa <c>&lt;mapa&gt;\&lt;Worker&gt;\&lt;Worker&gt;.exe</c>, kot jo naredi
/// objava intraneta (PIM.Intranet.csproj, cilj PimPublishWorkersAndScripts); null, kadar ni nastavljena ali je ni.</param>
/// <param name="HasSource">PIM.sln je najden: worker brez objavljenega .exe teče z <c>dotnet run</c>.</param>
public sealed record WorkerConsoleSetup(
  bool Available, string? Reason, string RepositoryRoot, string SolutionRoot,
  string LogRoot, string? PublishedWorkersRoot, bool HasSource = false)
{
  public string ManualLogRoot => Path.Combine(LogRoot, WorkerLogs.ManualFolder);
  public string CycleLogRoot => Path.Combine(LogRoot, WorkerLogs.CycleFolder);
}

/// <summary>
/// Kaj je na tem računalniku za zagon: izvorna koda ali objavljeni workerji. Čista funkcija nad
/// potmi, da se da preveriti brez IIS in brez konfiguracije (F10).
///
/// Do 2026-09-16 je bil PIM.sln pogoj za vse. Objavljen intranet (dotnet publish v IIS) ga nad
/// sabo nima, zato je stran na strežniku pisala »izvorne kode ni«, čeprav so bili workerji
/// objavljeni poleg. Zdaj zadošča eno od dvojega: izvorna koda (dotnet run) ali objavljeni .exe.
/// </summary>
public static class WorkerConsoleLayout
{
  /// <param name="repositoryRoot">WorkerConsole:RepositoryRoot — koren z <c>logs\</c> (in na razvoju <c>PIM_Solution\PIM.sln</c>).</param>
  /// <param name="publishedWorkersRoot">WorkerConsole:PublishedWorkersRoot — mapa <c>&lt;mapa&gt;\&lt;Worker&gt;\&lt;Worker&gt;.exe</c>.</param>
  /// <param name="logRoot">WorkerConsole:LogRoot; privzeto <c>&lt;koren&gt;\logs</c>, brez korena <c>&lt;objavljeni&gt;\logs</c>.</param>
  /// <param name="findSolutionRoot">Kje je PIM.sln nad aplikacijo (razvoj); null izven rešitve.</param>
  /// <param name="applicationDirectory">Mapa intraneta (<c>AppContext.BaseDirectory</c>). Objava intraneta odloži ob
  /// njo <c>Workerji\</c> (in <c>scripts\</c>); ta postavitev velja brez ključev, ključi jo le prepišejo.</param>
  public static WorkerConsoleSetup Resolve(
    string? repositoryRoot, string? publishedWorkersRoot, string? logRoot, Func<string?> findSolutionRoot,
    string? applicationDirectory = null)
  {
    if (string.IsNullOrWhiteSpace(publishedWorkersRoot) && applicationDirectory is { Length: > 0 }
        && Directory.Exists(Path.Combine(applicationDirectory, "Workerji")))
      publishedWorkersRoot = Path.Combine(applicationDirectory, "Workerji");
    var hasPublished = !string.IsNullOrWhiteSpace(publishedWorkersRoot) && Directory.Exists(publishedWorkersRoot);

    var solution = !string.IsNullOrWhiteSpace(repositoryRoot)
      ? Path.Combine(repositoryRoot, "PIM_Solution")
      : findSolutionRoot();
    var hasSource = solution is not null && File.Exists(Path.Combine(solution, "PIM.sln"));

    // Brez izvorne kode in brez ključa je koren mapa intraneta, če so ob njej objavljeni workerji ali
    // skripte (objava v eno mapo): dnevniki in izvozi gredo ob aplikacijo, ne ob posamezen .exe.
    if (string.IsNullOrWhiteSpace(repositoryRoot) && !hasSource && applicationDirectory is { Length: > 0 }
        && (Directory.Exists(Path.Combine(applicationDirectory, "scripts")) || Directory.Exists(Path.Combine(applicationDirectory, "Workerji"))))
      repositoryRoot = applicationDirectory;

    if (!hasSource && !hasPublished)
      return new(false,
        "izvorne kode ni (PIM.sln ni najden nad mapo aplikacije) in ob intranetu ni mape Workerji z objavljenimi workerji. "
        + "Objavi intranet skupaj z workerji (dotnet publish PIM.Intranet — cilj PimPublishWorkersAndScripts, deploy\\Publish-All.ps1) "
        + "ali v appsettings.Local.json ob intranetu nastavi WorkerConsole:PublishedWorkersRoot (strežnik) oziroma WorkerConsole:RepositoryRoot (razvoj).",
        "", "", "", publishedWorkersRoot);

    var repository = !string.IsNullOrWhiteSpace(repositoryRoot) ? repositoryRoot
      : hasSource ? Directory.GetParent(solution!)!.FullName
      : "";

    var logs = logRoot is { Length: > 0 } ? logRoot
      : repository.Length > 0 ? Path.Combine(repository, "logs")
      : Path.Combine(publishedWorkersRoot!, "logs");
    return new(true, null, repository, hasSource ? solution! : "", logs, hasPublished ? publishedWorkersRoot : null, hasSource);
  }

  /// <summary>Pot do objavljenega .exe ali null; na razvojnem računalniku ga ni in worker teče z dotnet run.</summary>
  public static string? PublishedWorker(string? root, string worker)
  {
    if (string.IsNullOrWhiteSpace(root)) return null;
    var exe = Path.Combine(root, worker, worker + ".exe");
    return File.Exists(exe) ? exe : null;
  }

  /// <summary>
  /// Zakaj posla tu ni mogoče pognati, ali null, kadar se da. Cikel teče v intranetu in potrebuje
  /// samo to, da je postavitev sploh na voljo (posamezen manjkajoč worker pove njegov korak); worker
  /// pa objavljen .exe ali izvorno kodo — na strežniku brez izvorne kode je torej na voljo natanko to,
  /// kar je objavljeno, in gumb pove, kaj manjka.
  /// </summary>
  public static string? Unavailable(WorkerConsoleSetup setup, WorkerJob job)
  {
    if (!setup.Available) return setup.Reason;
    if (job.Kind == WorkerJobKind.Cycle)
      return WorkerCycles.Find(job.Target) is null ? $"cikel {job.Target} ne obstaja." : null;

    if (setup.HasSource || PublishedWorker(setup.PublishedWorkersRoot, job.Target) is not null) return null;
    return setup.PublishedWorkersRoot is { Length: > 0 } root
      ? $"{job.Target}.exe ni v {Path.Combine(root, job.Target)} in izvorne kode ni."
      : $"{job.Target} ni objavljen (WorkerConsole:PublishedWorkersRoot) in izvorne kode ni.";
  }
}

public enum LogLineTone { Normal, Header, Success, Warning, Error }

/// <summary>Ena vrstica izpisa schtasks: ime naloge, naslednji zagon in stanje, kot jih pove Windows.</summary>
public sealed record ScheduledTaskLine(string Name, string NextRun, string Status);

public static class WorkerJobs
{
  public const string GroupCycles = "Cikli — isto, kar poganja razporejevalnik";
  public const string GroupWorkers = "Posamezni workerji";

  static readonly IReadOnlyDictionary<string, string> SaopLive = new Dictionary<string, string> { ["PIM_SAOP_MODE"] = "Live" };

  public static IReadOnlyList<WorkerJob> All { get; } =
  [
    new("zaloga-cikel", GroupCycles, "Zalogovni cikel",
      "SAOP zaloga, Nowodvorski FTP, Braytron XML, cene, izvoz cen in zaloge za splet. Isto kot cikel »Zaloga in cene«, le da ne čaka na razpored postopkov.",
      WorkerJobKind.Cycle, WorkerCycles.Zaloga, [], false, null,
      WorkerJobReach.ExternalCall, "kliče SAOP in dobavitelja",
      ["SAOP_STOCK", "SOURCE_FETCH", "STOCK_FILE", "SAOP_PRICES", "MAGENTO_STOCK_PRICES"], "zaloga-"),
    new("zaloga-dobavitelji", GroupCycles, "Zaloga dobaviteljev",
      "Samo Nowodvorski in Braytron: prevzem datoteke in branje v bazo. SAOP ne kliče.",
      WorkerJobKind.Cycle, WorkerCycles.Zaloga, [], false, null,
      WorkerJobReach.ExternalCall, "kliče FTP in HTTPS dobavitelja",
      ["SOURCE_FETCH", "STOCK_FILE"], "zaloga-", Cycle: new(OnlySuppliers: true)),
    new("katalog-cikel", GroupCycles, "Katalog za splet",
      "SAOP katalog (delta), naročila, validacija, objava in poln izvoz kataloga in strank. Isto kot cikel »Katalog za splet«.",
      WorkerJobKind.Cycle, WorkerCycles.Katalog, [], false, null,
      WorkerJobReach.ExternalCall, "kliče SAOP", ["SAOP_PRODUCTS", "SAOP_ORDERS_VNK", "SAOP_ORDERS_VND", "MAGENTO_PRODUCTS"], "katalog-"),
    new("nadzor", GroupCycles, "Nadzor in alarmi",
      "Nadzornik zastalih obdelav in razpošiljanje alarmov. Isto kot cikel »Nadzor in alarmi«.",
      WorkerJobKind.Cycle, WorkerCycles.Nadzor, [], false, null,
      WorkerJobReach.Internal, null, ["WATCHDOG", "ALERT_DISPATCH"], "nadzor-"),
    new("nocno-brez-saop", GroupCycles, "Nočni tok brez SAOP kataloga",
      "Dobaviteljev XML, zaloge, preslikava zaostanka, validacija, objava in izvoz. Zajema kataloga iz SAOP ne kliče.",
      WorkerJobKind.Cycle, WorkerCycles.NocniTok, [], false, null,
      WorkerJobReach.ExternalCall, "kliče dobavitelja in SAOP zalogo", ["GENERIC_XML", "STOCK_FILE"], "nocno_", Cycle: new(SkipSaopCatalog: true)),
    new("nocno-vse", GroupCycles, "Nočni tok v celoti",
      "Vse, kar teče ponoči, skupaj z zajemom kataloga in zaloge iz SAOP. Traja več minut.",
      WorkerJobKind.Cycle, WorkerCycles.NocniTok, [], false, null,
      WorkerJobReach.ExternalCall, "kliče SAOP in dobavitelja",
      ["SAOP_PRODUCTS", "GENERIC_XML", "STOCK_FILE", "SAOP_STOCK", "SAOP_DELIVERY"], "nocno_"),
    new("samotest", GroupCycles, "Nočni samotest",
      "Prehodi celo verigo in rezultat zapiše v bazo; vidiš ga na zavihku Nočni samotest. Samo bere.",
      WorkerJobKind.Cycle, WorkerCycles.Samotest, [], false, null,
      WorkerJobReach.Internal, null, [], "samotest"),

    new("saop-zaloga", GroupWorkers, "Zaloga iz SAOP",
      "Količine zaloge po skladiščih iz ERP.",
      WorkerJobKind.Worker, "PIM.SaopStockWorker", [], false, "--organizations",
      WorkerJobReach.ExternalCall, "kliče SAOP", ["SAOP_STOCK"], null, SaopLive),
    new("saop-dostave", GroupWorkers, "Datumi dobave iz SAOP",
      "Datumi in količine prihoda, do 300 artiklov na podjetje.",
      WorkerJobKind.Worker, "PIM.SaopStockWorker", ["--dostave"], false, "--organizations",
      WorkerJobReach.ExternalCall, "kliče SAOP", ["SAOP_DELIVERY"], null, SaopLive),
    new("saop-narocila", GroupWorkers, "Naročila iz SAOP",
      "Naročila kupcev in naročila dobaviteljem za MIN/MID/MAX.",
      WorkerJobKind.Worker, "PIM.SaopOrdersWorker", [], false, "--organizations",
      WorkerJobReach.ExternalCall, "kliče SAOP", ["SAOP_ORDERS_VNK", "SAOP_ORDERS_VND"], null, SaopLive),
    new("preslikava-zaostanka", GroupWorkers, "Preslikava zaostanka",
      "Kar je v raw.Inbox ostalo Pending, gre skozi preslikavo v katalog. SAOP ne kliče.",
      WorkerJobKind.Worker, "PIM.KatalogWorker", ["--preslikaj-zaostanek"], false, null,
      WorkerJobReach.Internal, null, [], null, SaopLive),
    // Brez --output-dir: mapo razreši worker sam (register ops.SystemPath, ključ EXPORT_ROOT; glej
    // PIM.B2bWorker/Program.cs), da ročni zagon piše tja, kamor urnik.
    new("izvoz-katalog", GroupWorkers, "Izvoz kataloga za splet",
      "Validacija, objava ter katalog.csv in stranke.csv — en par datotek, vedno za podjetje 2 (IQLighting), ne glede na izbiro podjetja. Mapa: /sistem/mape, EXPORT_ROOT.",
      WorkerJobKind.Worker, "PIM.B2bWorker",
      ["--export-magento", "--osvezi-validacijo", "--organization-id", "{org}"], false, null,
      WorkerJobReach.Internal, null, ["MAGENTO_PRODUCTS"], null, FixedOrganizationId: 2),
    new("izvoz-cene-zaloga", GroupWorkers, "Izvoz cen in zaloge za splet",
      "magento-stock-prices.csv iz trenutnega stanja v bazi, za vsako podjetje posebej.",
      WorkerJobKind.Worker, "PIM.B2bWorker",
      ["--export-profile", "MAGENTO_STOCK_PRICES", "--organization-id", "{org}", "--output-dir", "{izvoz}", "--file-name", "magento-stock-prices.csv"], true, null,
      WorkerJobReach.Internal, null, ["MAGENTO_STOCK_PRICES"], null),
    new("watchdog", GroupWorkers, "Nadzornik",
      "Najde zastala izvajanja in odprte težave ter jih uvrsti v vrsto za alarme.",
      WorkerJobKind.Worker, "PIM.Watchdog", [], false, null,
      WorkerJobReach.Internal, null, ["WATCHDOG"], null),
    new("alarmi", GroupWorkers, "Razpošiljanje alarmov",
      "Odprte alarme pošlje po e-pošti, če je dostava vklopljena (PIM_ALERT_DELIVERY_ENABLED).",
      WorkerJobKind.Worker, "PIM.AlertDispatcher", [], false, null,
      WorkerJobReach.SendsEmail, "pošlje e-pošto, če je dostava vklopljena", ["ALERT_DISPATCH"], null),
    new("zaloga-pod-mid-predogled", GroupWorkers, "Zaloga pod MID — predogled",
      "Sestavi dnevni mail in ga zapiše v datoteko. Ne pošlje ga nikomur.",
      WorkerJobKind.Worker, "PIM.StockReplenishmentWorker", ["--dry-run"], false, "--organizations",
      WorkerJobReach.Internal, null, ["STOCK_REPLENISHMENT_DIGEST"], null),
    new("zaloga-pod-mid", GroupWorkers, "Zaloga pod MID — pošlji",
      "Pošlje dnevni mail prejemnikom s kljukico »Zaloga pod MID«.",
      WorkerJobKind.Worker, "PIM.StockReplenishmentWorker", [], false, "--organizations",
      WorkerJobReach.SendsEmail, "pošlje e-pošto prejemnikom", ["STOCK_REPLENISHMENT_DIGEST"], null),
  ];

  public static WorkerJob? Find(string? key) => All.FirstOrDefault(job => job.Key == key);

  /// <summary>Posel, ki požene cel cikel s privzetimi stikali (za razporejevalnik in gumb »Poženi zdaj«).</summary>
  public static WorkerJob? ForCycle(string cycleKey) =>
    All.FirstOrDefault(job => job.Kind == WorkerJobKind.Cycle && job.Target == cycleKey && (job.Cycle is null || job.Cycle == new CycleOptions()));

  /// <summary>
  /// Načrtovane naloge Windows, ki jih registrirata Namesti-opravila.ps1 in Namesti-samotest.ps1,
  /// predpona dnevnika, ki ga pišejo, in posel na tej strani, ki naredi isto. Od 2026-09-17 jih
  /// nadomešča razporejevalnik v aplikaciji; seznam ostaja, da stran pove, če še tečejo vzporedno.
  /// </summary>
  public static IReadOnlyList<(string Task, string? LogPrefix, string? JobKey)> WindowsTasks { get; } =
  [
    ("PIM zaloga", "zaloga-", "zaloga-cikel"),
    ("PIM katalog", "katalog-", "katalog-cikel"),
    ("PIM nadzor", "nadzor-", "nadzor"),
    ("PIM nocni tok", "nocno_", "nocno-vse"),
    ("PIM samotest", "samotest", "samotest"),
  ];

  /// <summary>
  /// Spremenljivke gostitelja, ki jih otrok ne sme podedovati. Intranet teče pod Visual Studiem ali
  /// IIS: VS vanj vstavi DOTNET_STARTUP_HOOKS za vroče nalaganje, ki bi se sicer naložil v vsak
  /// worker, ASPNETCORE_* pa workerju, ki ni spletna aplikacija, ne povedo ničesar.
  /// </summary>
  public static bool IsInheritedHostVariable(string name) =>
    name.StartsWith("ASPNETCORE_", StringComparison.OrdinalIgnoreCase)
    || name.StartsWith("DOTNET_STARTUP_HOOKS", StringComparison.OrdinalIgnoreCase)
    || name.StartsWith("DOTNET_MODIFIABLE_ASSEMBLIES", StringComparison.OrdinalIgnoreCase)
    || name.StartsWith("DOTNET_HOTRELOAD", StringComparison.OrdinalIgnoreCase)
    || name.StartsWith("DOTNET_WATCH", StringComparison.OrdinalIgnoreCase);

  /// <summary>
  /// Procesi, ki jih zagon workerja požene. <paramref name="allOrganizations"/> pomeni, da posel izbere
  /// podjetja sam (privzetek workerja); takrat se izbor ne poda, da ročni zagon naredi natanko to,
  /// kar naredi načrtovani. Cikel nima načrta tu: njegove korake sestavi <see cref="WorkerCycles.Plan"/>.
  /// </summary>
  public static IReadOnlyList<WorkerLaunchStep> Plan(
    WorkerJob job, IReadOnlyList<int> organizations, bool allOrganizations, WorkerPaths paths)
  {
    if (job.Kind == WorkerJobKind.Cycle)
      throw new InvalidOperationException($"{job.Label} je cikel; njegove korake sestavi WorkerCycles.Plan.");

    // Izbira podjetja na strani se ne upošteva: en proces, eno podjetje, ista mapa kot pri urniku.
    if (job.FixedOrganizationId is { } fixedOrganizationId)
      return [LaunchWorker(job.Target, Substitute(job.Arguments, fixedOrganizationId, paths), paths, fixedOrganizationId)];

    if (job.PerOrganization)
    {
      if (organizations.Count == 0)
        throw new InvalidOperationException($"{job.Label} teče po podjetjih, podjetje pa ni izbrano.");
      return organizations
        .Select(organizationId => LaunchWorker(job.Target, Substitute(job.Arguments, organizationId, paths), paths, organizationId))
        .ToList();
    }

    var arguments = job.Arguments.ToList();
    if (!allOrganizations && job.OrganizationsArgument is { } name && organizations.Count > 0)
    {
      arguments.Add(name);
      arguments.Add(string.Join(",", organizations.Select(id => id.ToString(CultureInfo.InvariantCulture))));
    }

    return [LaunchWorker(job.Target, arguments, paths, !allOrganizations && organizations.Count == 1 ? organizations[0] : null)];
  }

  /// <summary>En proces workerja: objavljen .exe, sicer <c>dotnet run --no-build</c> iz izvorne kode (isto kot skripte).</summary>
  public static WorkerLaunchStep LaunchWorker(string worker, IReadOnlyList<string> arguments, WorkerPaths paths, int? organizationId)
  {
    var display = arguments.Count > 0 ? $"{worker} {string.Join(" ", arguments)}" : worker;
    if (paths.PublishedWorker(worker) is { } exe)
      return new(exe, arguments, Path.GetDirectoryName(exe) ?? paths.SolutionRoot, display, organizationId);

    // Isto kot skripte: dotnet run --no-build. Če worker ni zgrajen, to pove dotnet sam, in to
    // sporočilo pristane v izpisu, ne v tihem padcu.
    var project = Path.Combine(paths.SolutionRoot, "workers", worker);
    return new("dotnet", ["run", "--project", project, "--no-build", "--", .. arguments], paths.SolutionRoot, display, organizationId);
  }

  static List<string> Substitute(IReadOnlyList<string> arguments, int organizationId, WorkerPaths paths) =>
    arguments.Select(argument => argument
        .Replace("{org}", organizationId.ToString(CultureInfo.InvariantCulture), StringComparison.Ordinal)
        .Replace("{izvoz}", paths.ExportDirectory(organizationId), StringComparison.Ordinal))
      .ToList();
}

/// <summary>Dnevniki: imena datotek, razvrstitev vrstic in branje konca datoteke.</summary>
public static partial class WorkerLogs
{
  /// <summary>Podmapa mape dnevnikov, kamor pišejo ročni zagoni posameznih workerjev iz intraneta.</summary>
  public const string ManualFolder = "workerji";

  /// <summary>Podmapa za cikle, ki jih požene razporejevalnik ali gumb na strani; en dnevnik na zagon.</summary>
  public const string CycleFolder = "cikli";

  public const string HeaderPrefix = "=== ZAČETEK: ";
  public const string FooterPrefix = "=== KONEC: izhod ";

  /// <summary>Vrste dnevnikov po predponi imena. Vrstni red je vrstni red v izbirniku.</summary>
  public static IReadOnlyList<(string Key, string Label, string Prefix)> Kinds { get; } =
  [
    ("cikli", "Cikli (razporejevalnik in ročni)", CycleFolder + Path.DirectorySeparatorChar),
    ("rocno", "Ročni zagoni workerjev", ManualFolder + Path.DirectorySeparatorChar),
    ("zaloga", "Zalogovni cikel (skripta)", "zaloga-"),
    ("katalog", "Katalog (skripta)", "katalog-"),
    ("nadzor", "Nadzor (skripta)", "nadzor-"),
    ("nocno", "Nočni tok (skripta)", "nocno_"),
    ("zajem", "Zajem SAOP", "zajem_"),
    ("samotest", "Samotest (skripta)", "samotest"),
  ];

  public static string KindOf(string relativePath)
  {
    var normalized = relativePath.Replace('/', Path.DirectorySeparatorChar);
    foreach (var (key, _, prefix) in Kinds)
      if (normalized.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) return key;
    return "drugo";
  }

  public static string KindLabel(string key) =>
    Kinds.FirstOrDefault(kind => kind.Key == key).Label ?? "Drugo";

  public static string RunLogFileName(string jobKey, DateTime startedLocal) =>
    $"{jobKey}_{startedLocal.ToString("yyyy-MM-dd_HHmmss", CultureInfo.InvariantCulture)}.log";

  public static bool TryParseRunLogFileName(string fileName, out string jobKey, out DateTime startedLocal)
  {
    jobKey = "";
    startedLocal = default;
    var match = RunLogName().Match(Path.GetFileName(fileName));
    if (!match.Success) return false;
    if (!DateTime.TryParseExact(match.Groups["t"].Value, "yyyy-MM-dd_HHmmss", CultureInfo.InvariantCulture, DateTimeStyles.None, out startedLocal))
      return false;
    jobKey = match.Groups["key"].Value;
    return true;
  }

  public static string Footer(int exitCode, TimeSpan duration, bool cancelled) =>
    $"{FooterPrefix}{exitCode.ToString(CultureInfo.InvariantCulture)}"
    + (cancelled ? " (ustavljeno ročno)" : "")
    + $", trajanje {(int)duration.TotalHours:00}:{duration.Minutes:00}:{duration.Seconds:00}";

  /// <summary>Izhodna koda iz zadnjih vrstic dnevnika zagona; null, kadar zagon ni končal
  /// (še teče ali pa je intranet med njim ugasnil).</summary>
  public static int? ExitCodeFromFooter(IReadOnlyList<string> lines)
  {
    for (var index = lines.Count - 1; index >= 0 && index >= lines.Count - 5; index--)
    {
      var match = FooterLine().Match(lines[index]);
      if (match.Success) return int.Parse(match.Groups["code"].Value, CultureInfo.InvariantCulture);
    }
    return null;
  }

  /// <summary>
  /// Kaj vrstica pomeni človeku, ki išče, zakaj nekaj ne dela. Napaka ima prednost pred vsem:
  /// vrstica "NAPAKA v koraku …" ostane rdeča, četudi vsebuje tudi "konec".
  /// </summary>
  public static LogLineTone Classify(string line)
  {
    if (string.IsNullOrWhiteSpace(line)) return LogLineTone.Normal;
    if (ErrorPattern().IsMatch(line)) return LogLineTone.Error;
    if (WarningPattern().IsMatch(line)) return LogLineTone.Warning;
    if (HeaderPattern().IsMatch(line)) return LogLineTone.Header;
    if (SuccessPattern().IsMatch(line)) return LogLineTone.Success;
    return LogLineTone.Normal;
  }

  static readonly UTF8Encoding StrictUtf8 = new(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);
  static readonly Lazy<Encoding> ConsoleCodePage = new(() =>
  {
    Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
    return Encoding.GetEncoding(852);
  });

  /// <summary>
  /// Vrstica izpisa v besedilo. Skripte izpis preklopijo v UTF-8, worker, pognan naravnost, pa piše
  /// v kodni strani konzole, ki je na tem računalniku 852. Ena napačna izbira je že enkrat
  /// naredila "kon-Zcan" iz "končan" (glej Zaloga-cikel.ps1), zato se izbere po vsebini vrstice.
  /// </summary>
  public static string DecodeLine(ReadOnlySpan<byte> bytes)
  {
    while (bytes.Length > 0 && (bytes[^1] == (byte)'\r' || bytes[^1] == (byte)'\n')) bytes = bytes[..^1];
    if (bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) bytes = bytes[3..];
    try { return StrictUtf8.GetString(bytes); }
    catch (DecoderFallbackException) { return ConsoleCodePage.Value.GetString(bytes); }
  }

  /// <summary>
  /// Zadnjih največ <paramref name="maxBytes"/> bajtov datoteke kot vrstice. Datoteka se odpre z
  /// deljenim pisanjem, ker jo skripta morda ravno piše; delna prva vrstica se zavrže.
  /// </summary>
  public static IReadOnlyList<string> ReadTail(string path, int maxBytes)
  {
    using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
    var start = Math.Max(0, stream.Length - maxBytes);
    stream.Seek(start, SeekOrigin.Begin);
    var buffer = new byte[stream.Length - start];
    var read = 0;
    while (read < buffer.Length)
    {
      var count = stream.Read(buffer, read, buffer.Length - read);
      if (count == 0) break;
      read += count;
    }

    ReadOnlySpan<byte> span = buffer.AsSpan(0, read);
    if (start > 0)
    {
      var firstBreak = span.IndexOf((byte)'\n');
      span = firstBreak < 0 ? [] : span[(firstBreak + 1)..];
    }

    var lines = new List<string>();
    while (span.Length > 0)
    {
      var end = span.IndexOf((byte)'\n');
      var line = end < 0 ? span : span[..end];
      lines.Add(DecodeLine(line));
      span = end < 0 ? [] : span[(end + 1)..];
    }
    return lines;
  }

  /// <summary>
  /// Pot znotraj mape dnevnikov ali null. Stran pošlje relativno ime, ki ga je sama prebrala iz
  /// seznama; kljub temu se preveri, da ne pobegne iz mape in da je dnevnik.
  /// </summary>
  public static string? ResolveInside(string root, string relativePath)
  {
    if (string.IsNullOrWhiteSpace(relativePath) || Path.IsPathRooted(relativePath)) return null;
    var rootFull = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
    var full = Path.GetFullPath(Path.Combine(rootFull, relativePath));
    return full.StartsWith(rootFull, StringComparison.OrdinalIgnoreCase)
      && full.EndsWith(".log", StringComparison.OrdinalIgnoreCase) ? full : null;
  }

  /// <summary>Vrstica izpisa <c>schtasks /Query /FO CSV /NH</c>. Stolpci so ime, naslednji zagon in
  /// stanje; njihova vsebina je v jeziku sistema, zato se samo prenese.</summary>
  public static ScheduledTaskLine? ParseSchtasksCsv(string line)
  {
    var fields = new List<string>();
    var current = new StringBuilder();
    var quoted = false;
    foreach (var character in line.Trim())
    {
      if (character == '"') { quoted = !quoted; continue; }
      if (character == ',' && !quoted) { fields.Add(current.ToString()); current.Clear(); continue; }
      current.Append(character);
    }
    fields.Add(current.ToString());
    if (fields.Count < 3 || fields[0].Length == 0) return null;
    return new(fields[0].TrimStart('\\'), fields[1], fields[2]);
  }

  /// <summary>Vrstica z uro na začetku. Skripte uro pišejo same (nočni tok tudi datum); worker,
  /// pognan naravnost, je ne — brez nje se v dnevniku ne vidi, kje je čakal.</summary>
  public static string Stamp(string line, DateTime local) =>
    StampedLine().IsMatch(line) ? line : $"{local.ToString("HH:mm:ss", CultureInfo.InvariantCulture)}  {line}";

  [GeneratedRegex(@"^(\d{4}-\d{2}-\d{2} )?\d{2}:\d{2}:\d{2}\s")]
  private static partial Regex StampedLine();

  [GeneratedRegex(@"^(?<key>[a-z0-9-]+)_(?<t>\d{4}-\d{2}-\d{2}_\d{6})\.log$")]
  private static partial Regex RunLogName();

  // Zadnja vrstica gre v datoteko z uro spredaj (Stamp), zato ura ni del pogoja.
  [GeneratedRegex(@"^(?:(?:\d{4}-\d{2}-\d{2} )?\d{2}:\d{2}:\d{2}\s+)?=== KONEC: izhod (?<code>-?\d+)")]
  private static partial Regex FooterLine();

  [GeneratedRegex(@"NAPAKA|STDERR|Exception|Unhandled|\bFailed\b|padlih korakov: [1-9]|padlih [1-9]|izhodno kodo [1-9]|=== KONEC: izhod -?[1-9]|\bfail:|\bError:|\bERROR\b")]
  private static partial Regex ErrorPattern();

  [GeneratedRegex(@"OPOZORILO|preskoceno|preskočeno|ni omogocen|ni omogočen|ze tece|že teče|umaknil|ni na vrsti|zastarel|\bwarn:|\bWarning\b", RegexOptions.IgnoreCase)]
  private static partial Regex WarningPattern();

  [GeneratedRegex(@"(^|\s)==\s.+\s==\s*$|^=== ZAČETEK")]
  private static partial Regex HeaderPattern();

  [GeneratedRegex(@"padlih korakov: 0|padlih 0|=== KONEC: izhod 0|\bPASS\b|koncan|končan|konec:", RegexOptions.IgnoreCase)]
  private static partial Regex SuccessPattern();
}
