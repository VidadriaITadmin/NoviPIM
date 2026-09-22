using System.Globalization;

namespace PIM.Automation;

/*
  Razporejevalnik v aplikaciji (2026-09-17).

  Uporabnik: »zakaj na IIS-ju ne delajo workerji, v aplikaciji pa delajo. Naredi mi, da mi bodo
  workerji delali ne glede, kje je aplikacija postavljena.« Do zdaj je bila ura Windows naloga,
  registrirana pod računom človeka na razvojnem računalniku (scripts\Namesti-opravila.ps1); pod
  IIS aplikacijski bazen nalog drugega uporabnika ne vidi in jih ne sme registrirati, objavljen
  intranet pa nad sabo nima ne PIM.sln ne sqlcmd, ki ju skripte ciklov potrebujejo. Zato je stran
  /sistem/workerji na strežniku pisala »Ročni zagon tu ni na voljo« in pet vrstic »Ni registrirana«.

  Odslej je ura v intranetu (WorkerSchedulerService), cikli pa so tu opisani v C# — isti workerji
  in isti vrstni red korakov kot v skriptah Zaloga-cikel.ps1, Katalog-cikel.ps1, Nadzor.ps1,
  Nocno-vse.ps1 in Nocni-samotest.ps1, brez PowerShella in brez sqlcmd. Skripte ostajajo za ročno
  rabo iz ukazne vrstice; ko intranet drži najem, se same umaknejo (Sql.ps1).

  V tej datoteki je vse, kar se da preveriti brez baze in brez procesa (PIM.F10.IntranetLogicTests):
  katalog ciklov, načrt korakov, izračun naslednjega termina in presoja zaostanka. Kar potrebuje
  disk ali bazo (seznam datotek, podjetja, register map), pride od zunaj prek CycleEnvironment.
*/

/// <summary>Kaj naj cikel naredi drugače od privzetega; oblika stikal iz skript.</summary>
/// <param name="BySchedule"><c>--po-urniku</c>: spoštuj razpored postopkov v ops.ScheduleProfile in preskoči,
/// kar še ni na vrsti. Poda ga razporejevalnik; človek, ki cikel požene sam, hoče videti izid zdaj.</param>
/// <param name="OnlySuppliers">Zaloga: samo Nowodvorski in Braytron, brez SAOP (<c>-Kaj Dobavitelji</c>).</param>
/// <param name="SkipSaopCatalog">Nočni tok: brez zajema kataloga iz SAOP (<c>-BrezSaopKataloga</c>).</param>
/// <param name="SaopStock">Nočni tok: količine in datumi dobave iz SAOP (<c>-ZalogaIzSaop</c>).</param>
public sealed record CycleOptions(
  bool BySchedule = false, bool OnlySuppliers = false, bool SkipSaopCatalog = false, bool SaopStock = true);

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

/// <param name="Command">Kar gre v ops.WorkerCycleStep.Command in v dnevnik: človeku berljiv ukaz.</param>
/// <param name="Sql">Ukazi, izvedeni po vrsti z <c>@OrganizationId</c> = <paramref name="OrganizationId"/>.</param>
public sealed record CycleStep(
  string Name, CycleStepKind Kind, string Command,
  WorkerLaunchStep? Process = null, IReadOnlyDictionary<string, string>? Environment = null,
  IReadOnlyList<string>? Sql = null, int? OrganizationId = null,
  Func<IReadOnlyList<CycleStep>>? Expand = null);

/// <summary>
/// Skupina korakov = en »Korak« iz skript: če katerikoli korak v njej pade, se preostali v isti
/// skupini preskočijo, skupina šteje kot padla, cikel pa gre naprej na naslednjo skupino. Izhodna
/// koda cikla je število padlih skupin — enako pravilo kot v Zaloga-cikel.ps1 in Nocno-vse.ps1.
/// </summary>
public sealed record CycleGroup(string Name, IReadOnlyList<CycleStep> Steps, bool RequiresAllPrevious = false);

/// <param name="IntervalSeconds">Ponavljajoč cikel; null pomeni dnevni ob <paramref name="DailyAtLocal"/>.</param>
/// <param name="LogPrefix">Predpona dnevnika, ki ga je za ta cikel pisala skripta (zaloga-, nocno_ …); po njej
/// stran prepozna, da stara Windows naloga še teče vzporedno.</param>
public sealed record WorkerCycleDefinition(
  string Key, string Label, string Description, int SortOrder,
  int? IntervalSeconds, TimeOnly? DailyAtLocal, string LogPrefix,
  WorkerJobReach Reach, string? ReachNote, IReadOnlyList<string> Pipelines);

/// <summary>
/// Vse, kar načrt potrebuje od sveta zunaj sebe. Razporejevalnik ga sestavi iz baze in diska,
/// test iz konstant — načrt sam je čista funkcija.
/// </summary>
/// <param name="Organizations">Aktivna podjetja (skripte: privzeto 1, 2, 3, 4).</param>
/// <param name="CatalogOrganizationId">Podjetje, katerega artikli in stranke gredo v katalog.csv (2, uporabnik 2026-09-15).</param>
/// <param name="LandingRoot">Koren prevzema (register LANDING_ROOT ali privzetek), isti kot ga dobi prevzemnik z <c>--target</c>.</param>
/// <param name="ExportRoot">Register EXPORT_ROOT; kadar je nastavljen, izvozni worker mapo razreši sam.</param>
/// <param name="FixturesRoot">Mapa <c>fixtures</c> na razvoju (rezervni vir dobaviteljevega XML); null na strežniku.</param>
/// <param name="IsFullCatalogDay">Prvi dan v mesecu: poln zajem kataloga iz SAOP namesto delte.</param>
/// <param name="ListFiles">Datoteke v mapi (polne poti), že brez oznak prevzema (.prenos, .pocakaj) in Excelovih zaklepov.</param>
public sealed record CycleEnvironment(
  WorkerPaths Paths, IReadOnlyList<int> Organizations, int CatalogOrganizationId,
  string LandingRoot, string? ExportRoot, string? FixturesRoot, bool IsFullCatalogDay, int MaxParallel,
  Func<string, bool> DirectoryExists, Func<string, IReadOnlyList<string>> ListFiles);

/// <summary>Kako je cikel v ritmu glede na svoj razmik.</summary>
public enum CycleRhythm
{
  /// <summary>Izklopljen; ritma ni.</summary>
  Off,
  /// <summary>Pravkar teče.</summary>
  Running,
  /// <summary>Še ni tekel nikoli, a še ni zastal (šteje se od nastavitve).</summary>
  Never,
  /// <summary>Zadnji začetek je znotraj razmika.</summary>
  Ok,
  /// <summary>Zadnji začetek je starejši od razmika, a še ne dvakratnika.</summary>
  Late,
  /// <summary>Uporabnikovo pravilo: »če je na 5 min naštiman in je že 10 min v mirovanju, je treba opozorilo dati«.</summary>
  Overdue,
}

/// <param name="SinceLastStart">Kolikor je od zadnjega začetka (ali od nastavitve, če ni tekel nikoli).</param>
/// <param name="Expected">Razmik cikla; dnevni cikel ima en dan.</param>
/// <param name="Behind">Za koliko je zadnji začetek čez razmik; null, kadar je v ritmu.</param>
public sealed record CycleLag(CycleRhythm State, TimeSpan SinceLastStart, TimeSpan Expected, TimeSpan? Behind);

public static class WorkerCycles
{
  public const string Zaloga = "zaloga";
  public const string Katalog = "katalog";
  public const string Nadzor = "nadzor";
  public const string NocniTok = "nocni-tok";
  public const string Samotest = "samotest";
  public const string Magento = "magento-csv";

  /// <summary>Podjetje kataloga (katalog.csv, stranke.csv): en par datotek, samo IQLighting.</summary>
  public const int CatalogOrganization = 2;

  /// <summary>Cikel Magento (stari model, 221): validacija in objava pred izvozom tečeta le, kadar je najstarejša
  /// validacija aktivnih izdelkov podjetja starejša od te meje (--starost-validacije; seja »Sistem za produkcijsko
  /// obratovanje«, 2026-09-21). V enotnem modelu opravil (237) izvoz ne validira več — validacija je svoj posel.</summary>
  public const int MagentoValidationMaxAgeMinutes = 90;

  /// <summary>Privzeti razmik cikla magento-csv (242): 15 min; glej opombo pri definiciji cikla. Spremenljiv na /sistem/workerji.</summary>
  public const int MagentoIntervalSeconds = 900;

  internal static readonly IReadOnlyDictionary<string, string> SaopLive = new Dictionary<string, string> { ["PIM_SAOP_MODE"] = "Live" };

  public static IReadOnlyList<WorkerCycleDefinition> All { get; } =
  [
    // 242: razmik 15 min. Izvoz podjetja 2 (89.491 vrstic × 180 stolpcev) traja minute; ops.ClaimWorkerCycle
    // prekrivanje istega cikla prepreči, a pri 5 min bi izvoz tekel skoraj neprekinjeno in obremenjeval bazo.
    // Cene in zaloga gredo v magento-stock-prices.csv vsakih 5 min (cikel zaloga), katalog se spremeni
    // šele z validacijo in objavo (urno), zato je 15 min za katalog.csv dovolj sveže.
    new(Magento, "CSV za Magento",
      "Samostojen izhod iz PIM-a: validacija, objava ter katalog.csv in stranke.csv. Bere podatke v PIM-u; ne kliče SAOP ali Magenta.",
      5, MagentoIntervalSeconds, null, "magento-csv", WorkerJobReach.Internal, null, ["MAGENTO_PRODUCTS"]),
    new(Zaloga, "Zaloga in cene",
      "Zajem zalog in cen ter hitri izvoz cen in zaloge. Katalog in stranke izdela ločen cikel CSV za Magento.",
      10, 300, null, "zaloga-", WorkerJobReach.ExternalCall, "kliče SAOP in dobavitelja",
      ["SOURCE_FETCH", "STOCK_FILE", "SAOP_STOCK", "SAOP_PRICES", "MAGENTO_STOCK_PRICES", "SAOP_DELIVERY"]),
    new(Katalog, "Zajem kataloga in naročil",
      "Vsako uro: vhod iz SAOP, validacija in objava v PIM. CSV za Magento ima samostojen urnik.",
      20, 3600, null, "katalog-", WorkerJobReach.ExternalCall, "kliče SAOP",
      ["SAOP_PRODUCTS", "SAOP_ORDERS_VNK", "SAOP_ORDERS_VND"]),
    new(Nadzor, "Nadzor in alarmi",
      "Vsakih 5 minut: nadzornik zastalih obdelav in razpošiljanje odprtih alarmov po e-pošti (če je dostava vklopljena).",
      30, 300, null, "nadzor-", WorkerJobReach.SendsEmail, "pošlje e-pošto, če je dostava vklopljena",
      ["WATCHDOG", "ALERT_DISPATCH"]),
    new(NocniTok, "Nočni tok",
      "Vsak dan ob 02:30: vhodni tok, zaloge, validacija, objava v PIM in dnevni mail o zalogi pod MID. CSV za Magento ima samostojen cikel.",
      40, null, new TimeOnly(2, 30), "nocno_", WorkerJobReach.ExternalCall, "kliče SAOP in dobavitelja, pošlje e-pošto",
      ["SAOP_PRODUCTS", "SOURCE_FETCH", "GENERIC_XML", "STOCK_FILE", "SAOP_STOCK", "SAOP_DELIVERY", "STOCK_REPLENISHMENT_DIGEST"]),
    new(Samotest, "Nočni samotest",
      "Vsak dan ob 04:30: prehodi celo verigo (baza, razporedi, utripi, katalog, izvoz) in rezultat zapiše v ops.SelfTestRun. Samo bere.",
      50, null, new TimeOnly(4, 30), "samotest", WorkerJobReach.Internal, null, []),
  ];

  public static WorkerCycleDefinition? Find(string? key) => All.FirstOrDefault(cycle => cycle.Key == key);

  /// <summary>Katera Windows naloga je doslej poganjala kateri cikel (Namesti-opravila.ps1, Namesti-samotest.ps1).</summary>
  public static IReadOnlyList<(string Task, string CycleKey)> LegacyTasks { get; } =
  [
    ("PIM zaloga", Zaloga), ("PIM katalog", Katalog), ("PIM nadzor", Nadzor), ("PIM nocni tok", NocniTok), ("PIM samotest", Samotest),
    ("PIM magento", Magento),
  ];

  /// <summary>Ime lastnika najema: gostitelj, proces in kje teče (IIS bazen ali dotnet), da se na strani vidi, kdo je ura.</summary>
  public static string OwnerName(string hostName, int processId, string application) => $"{hostName}:{processId.ToString(CultureInfo.InvariantCulture)}:{application}";

  /// <summary>Pod IIS je nastavljen APP_POOL_ID; sicer je to razvojni zagon (dotnet run, Visual Studio).</summary>
  public static string ApplicationName(string? appPoolId) =>
    string.IsNullOrWhiteSpace(appPoolId) ? "dotnet" : $"IIS:{appPoolId}";

  // ─── Naslednji termin ─────────────────────────────────────────────────────

  /// <summary>
  /// Kdaj je cikel naslednjič na vrsti, šteto od <paramref name="fromUtc"/> (začetek tega teka, ne
  /// konec — sicer se razmik sešteva s trajanjem, ista napaka kot jo je migracija 118 odpravila pri
  /// postopkih). Dnevni cikel: naslednja pojavitev ure v naši uri; ura, ki je na dan prehoda na
  /// poletni čas ne obstaja, se premakne za uro naprej.
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

  /// <summary>
  /// Prvi termin po zagonu razporejevalnika, kadar ga vrstica še nima: ponavljajoči cikli so
  /// razmaknjeni za dve minuti (isto kot zamiki v Namesti-opravila.ps1, da se trije cikli ne zaletijo
  /// v isti minuti), dnevni čaka na svojo uro.
  /// </summary>
  public static DateTime InitialDue(int? intervalSeconds, TimeOnly? dailyAtLocal, int staggerIndex, DateTime nowUtc, TimeZoneInfo zone) =>
    intervalSeconds is not null
      ? DateTime.SpecifyKind(nowUtc, DateTimeKind.Utc).AddMinutes(1 + 2 * staggerIndex)
      : NextDue(null, dailyAtLocal, nowUtc, zone);

  // ─── Zaostanek ────────────────────────────────────────────────────────────

  /// <param name="baselineUtc">Od kod se šteje, kadar cikel ni tekel nikoli: zadnja nastavitev (UpdatedUtc).</param>
  public static CycleLag Evaluate(
    bool enabled, bool running, DateTime? lastStartedUtc, DateTime baselineUtc,
    int? intervalSeconds, decimal warnAfterMultiplier, DateTime nowUtc)
  {
    var expected = TimeSpan.FromSeconds(intervalSeconds ?? 86400);
    var since = nowUtc - (lastStartedUtc ?? baselineUtc);
    if (since < TimeSpan.Zero) since = TimeSpan.Zero;

    if (!enabled) return new(CycleRhythm.Off, since, expected, null);
    if (running) return new(CycleRhythm.Running, since, expected, null);
    if (since.TotalSeconds > (double)warnAfterMultiplier * expected.TotalSeconds) return new(CycleRhythm.Overdue, since, expected, since - expected);
    if (lastStartedUtc is null) return new(CycleRhythm.Never, since, expected, null);
    if (since > expected) return new(CycleRhythm.Late, since, expected, since - expected);
    return new(CycleRhythm.Ok, since, expected, null);
  }

  /// <summary>
  /// Stare Windows naloge še tečejo vzporedno: skripta piše svoj dnevnik (zaloga-<datum>.log …) v
  /// koren mape dnevnikov, razporejevalnik pa v podmapo cikli. Svež zapis v korenu ob aktivnem
  /// razporejevalniku pomeni, da isti cikel poganjata dve uri — to stran pove, ne skrije.
  /// </summary>
  public static IReadOnlyList<(string Task, string CycleKey, DateTime LastWriteUtc)> RecentLegacyRuns(
    IReadOnlyList<WorkerLogFile> logs, DateTime nowUtc, TimeSpan window)
  {
    var result = new List<(string, string, DateTime)>();
    foreach (var (task, key) in LegacyTasks)
    {
      var prefix = Find(key)!.LogPrefix;
      var latest = logs
        .Where(log => !log.RelativePath.Contains(Path.DirectorySeparatorChar) && !log.RelativePath.Contains('/')
          && log.RelativePath.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
        .Select(log => (DateTime?)log.LastWriteUtc)
        .Max();
      if (latest is { } write && nowUtc - write <= window) result.Add((task, key, write));
    }
    return result;
  }

  // ─── Načrt korakov ────────────────────────────────────────────────────────

  public static IReadOnlyList<CycleGroup> Plan(string cycleKey, CycleOptions options, CycleEnvironment env) => cycleKey switch
  {
    Zaloga => PlanZaloga(options, env),
    Katalog => PlanKatalog(env),
    Nadzor => PlanNadzor(env),
    NocniTok => PlanNocniTok(options, env),
    Samotest => PlanSamotest(env),
    Magento => env.Organizations.Contains(env.CatalogOrganizationId)
      ? [new("Validacija in izdelava CSV za Magento", [Worker("Katalog in stranke", "PIM.B2bWorker",
          ["--export-magento", "--osvezi-validacijo", "--starost-validacije", MagentoValidationMaxAgeMinutes.ToString(CultureInfo.InvariantCulture), "--organization-id", Org(env.CatalogOrganizationId)], env.Paths, env.CatalogOrganizationId)])]
      : [new("CSV za Magento", [Note("CSV za Magento", "Podjetje kataloga je izključeno iz avtomatike.")])],
    _ => throw new InvalidOperationException($"Neznan cikel: {cycleKey}."),
  };

  /// <summary>Zaloga-cikel.ps1: trije viri zaloge, cene, hitri izvoz cen in zaloge, osvežen katalog, datumi dobave.</summary>
  static IReadOnlyList<CycleGroup> PlanZaloga(CycleOptions options, CycleEnvironment env)
  {
    var groups = new List<CycleGroup>();
    string[] urnik = options.BySchedule ? ["--po-urniku"] : [];
    var orgs = Orgs(env);

    // Samo zalogovna vira. Prevzem in branje gresta skupaj, da zaloga ne čaka na naslednji cikel.
    foreach (var vir in new[] { "NW_STOCK", "BT_STOCK" })
    {
      var mapa = Path.Combine(env.LandingRoot, vir);
      groups.Add(new($"Zaloga {vir}",
      [
        Worker($"Prevzem {vir}", "PIM.SourceFetchWorker", ["--source", vir, "--target", env.LandingRoot, .. urnik], env.Paths),
        // Katere datoteke so prišle, se ve šele po prevzemu — zato se ta del razgrne med tekom.
        new($"Branje {vir}", CycleStepKind.Expand, $"datoteke v {mapa}", Expand: () => StockFilesSteps(vir, mapa, env, urnik)),
      ]));
    }

    if (options.OnlySuppliers) return groups;

    // Živ klic je odločitev človeka (AGENTS.md §4.5); vklopil ga je z vklopom cikla na /sistem/workerji.
    groups.Add(new("Zaloga iz SAOP (kolicine)",
      [Worker("Zaloga iz SAOP", "PIM.SaopStockWorker", ["--organizations", orgs, .. urnik], env.Paths, environment: SaopLive)]));

    // Cene: delta zajem za vsa podjetja (migracija 204 bere cene iz canon.ProductPrice; validacija
    // besedil in objava ostaneta v urnem katalogu). Uporabnik 2026-09-15: cene za vsa podjetja na 5 min.
    groups.Add(new("Osvezitev cen kataloga",
      [Worker("Cene iz SAOP", "PIM.KatalogWorker", ["--organizations", orgs, "--endpoints", "GetPrices"], env.Paths, environment: SaopLive)]));

    // Profil MAGENTO_STOCK_PRICES (146): brez validacije, samo izdelki, ki so že na spletu.
    var izvoz = new List<CycleStep>();
    foreach (var org in env.Organizations)
      izvoz.Add(Worker($"Cene in zaloga (podjetje {org})", "PIM.B2bWorker",
        ["--export-profile", "MAGENTO_STOCK_PRICES", "--organization-id", Org(org), .. ExportDirectory(env, org), "--file-name", "magento-stock-prices.csv"],
        env.Paths, org));
    groups.Add(new("Izvoz cen in zaloge za splet", izvoz));

    // Katalog in stranke izdeluje samostojen cikel Magento.

    // Datumi dobave (189): en klic na artikel, do 300 artiklov na podjetje — počasen, zato vedno po
    // razporedu SAOP_DELIVERY (30 min), tudi pri ročnem zagonu, in na koncu, da ne zadrži izvoza.
    groups.Add(new("Zaloga iz SAOP (datumi prihoda)",
      [Worker("Datumi dobave iz SAOP", "PIM.SaopStockWorker", ["--organizations", orgs, "--dostave", "--po-urniku"], env.Paths, environment: SaopLive)]));

    return groups;
  }

  /// <summary>Katalog-cikel.ps1 + urni SAOP katalog s strežnika (Configure-WorkerScheduledTasks.ps1, PIM-SaopKatalog).</summary>
  static IReadOnlyList<CycleGroup> PlanKatalog(CycleEnvironment env)
  {
    var groups = new List<CycleGroup>
    {
      // Delta vsako uro: nova šifra artikla in spremembe pridejo v PIM čez dan, ne šele ponoči
      // (docs/WORKERS.md, »SAOP katalog na strežniku in VatRateId«). Poln zajem je stvar nočnega toka.
      new("SAOP katalog (delta)",
        [Worker("Katalog iz SAOP", "PIM.KatalogWorker", ["--organizations", Orgs(env), "--max-parallel", Org(env.MaxParallel)], env.Paths, environment: SaopLive)]),
      // Naročila kupcev in dobaviteljem za MIN/MID/MAX; ločena razporeda VNK/VND (210), oba na uro.
      new("Narocila iz SAOP (VNK/VND)",
        [Worker("Naročila iz SAOP", "PIM.SaopOrdersWorker", ["--organizations", Orgs(env)], env.Paths, environment: SaopLive)]),
    };

    // Validacija in objava vseh podjetij: VID zaloga in VID cenik vstopata v IQ katalog prek
    // objavljenega sloja podjetja 3 — brez njegove objave bi bila IQ datoteka stara.
    foreach (var org in env.Organizations)
      groups.Add(new($"Osvezitev objave (podjetje {org})", [ValidateAndPromote(org)]));

    return groups;
  }

  /// <summary>Nadzor.ps1: edini del avtomatike, ki pove, da se je nekaj ustavilo.</summary>
  static IReadOnlyList<CycleGroup> PlanNadzor(CycleEnvironment env) =>
  [
    new("Nadzornik zastalih obdelav", [Worker("Nadzornik", "PIM.Watchdog", [], env.Paths)]),
    new("Razposiljanje alarmov", [Worker("Razpošiljanje alarmov", "PIM.AlertDispatcher", [], env.Paths)]),
  ];

  /// <summary>Nocno-vse.ps1 z -ZalogaIzSaop: vsi vhodi po vrsti; vrstni red ni naključen (glej opis skripte).</summary>
  static IReadOnlyList<CycleGroup> PlanNocniTok(CycleOptions options, CycleEnvironment env)
  {
    var groups = new List<CycleGroup>();
    var orgs = Orgs(env);

    // 0. gradnja — samo z izvorno kodo. Workerji tečejo z --no-build, zato se zgradijo enkrat na začetku;
    // gradi se vsak worker posebej in ne PIM.sln, ker bi zaklenjen intranet (Visual Studio) podrl celo rešitev.
    if (env.Paths.SolutionRoot.Length > 0 && env.Paths.PublishedWorkersRoot is null)
    {
      var gradnja = new List<CycleStep>();
      foreach (var worker in new[] { "PIM.KatalogWorker", "PIM.SourceFetchWorker", "PIM.XmlFileWorker", "PIM.StockFileWorker", "PIM.SaopStockWorker", "PIM.B2bWorker", "PIM.StockReplenishmentWorker" })
      {
        var project = Path.Combine(env.Paths.SolutionRoot, "workers", worker);
        gradnja.Add(new($"Gradnja {worker}", CycleStepKind.Process, $"dotnet build {worker}",
          new("dotnet", ["build", project, "-v", "q", "--nologo"], env.Paths.SolutionRoot, $"dotnet build {worker}", null)));
      }
      groups.Add(new("Gradnja", gradnja));
    }

    // 1. SAOP katalog: nova šifra artikla mora obstajati, preden jo kdo obogati.
    if (options.SkipSaopCatalog)
      groups.Add(new("SAOP katalog", [Note("SAOP katalog", "preskočeno: brez zajema kataloga iz SAOP. Klica navzven ni bilo.")]));
    else
      groups.Add(new("SAOP katalog",
        [Worker("Katalog iz SAOP", "PIM.KatalogWorker", ["--organizations", Orgs(env), "--max-parallel", Org(env.MaxParallel), .. (env.IsFullCatalogDay ? new[] { "--full" } : Array.Empty<string>())], env.Paths, environment: SaopLive)]));

    // 1a. Prevzem pred vsemi vhodi, sicer bi ostali koraki brali včeraj prineseno datoteko.
    groups.Add(new("Prevzem dobaviteljevih datotek", [Worker("Prevzem", "PIM.SourceFetchWorker", ["--target", env.LandingRoot], env.Paths)]));

    // 2. Dobaviteljev XML: lastnosti, kategorije in slike se vežejo na artikel po EAN. Bere se
    // prevzeta datoteka (LANDING_ROOT\NW_XML, BT_XML); brez nje na razvoju fixtures, na strežniku nič.
    groups.Add(new("Dobaviteljev XML (Nowodvorski)", [new("XML Nowodvorski", CycleStepKind.Expand, "NW_XML", Expand: () => XmlSteps("NW_XML", "nw", env))]));
    groups.Add(new("Dobaviteljev XML (Braytron)", [new("XML Braytron", CycleStepKind.Expand, "BT_XML", Expand: () => XmlSteps("BT_XML", "bt", env))]));

    // 4. Preslikava zaostanka: kar je ostalo Pending, pride v katalog, preden objava pogleda, kaj ima.
    groups.Add(new("Preslikava zaostanka v raw.Inbox",
      [Worker("Preslikava zaostanka", "PIM.KatalogWorker", ["--preslikaj-zaostanek"], env.Paths, environment: SaopLive)]));

    // 5. Zaloge dobaviteljev za vsa podjetja: šifre NW.* in BA.* ima vsako od štirih (087).
    groups.Add(new("Zaloge dobaviteljev", [new("Zaloge iz datotek", CycleStepKind.Expand, "NW_STOCK, BT_STOCK", Expand: () =>
    {
      var steps = new List<CycleStep>();
      foreach (var vir in new[] { "NW_STOCK", "BT_STOCK" })
        steps.AddRange(StockFilesSteps(vir, Path.Combine(env.LandingRoot, vir), env, []));
      return steps;
    })]));

    // 6. Zaloga iz SAOP: količine in datumi prihoda (en klic na artikel — sodi v noč, ne v petminutni cikel).
    if (options.SaopStock)
    {
      groups.Add(new("Zaloga iz SAOP (kolicine)", [Worker("Zaloga iz SAOP", "PIM.SaopStockWorker", ["--organizations", orgs], env.Paths, environment: SaopLive)]));
      groups.Add(new("Zaloga iz SAOP (datumi prihoda)", [Worker("Datumi dobave iz SAOP", "PIM.SaopStockWorker", ["--organizations", orgs, "--dostave"], env.Paths, environment: SaopLive)]));
    }
    else
      groups.Add(new("Zaloga iz SAOP", [Note("Zaloga iz SAOP", "preskočeno: brez zaloge iz SAOP (živ klic je odločitev človeka).")]));

    // 7. Validacija in objava šele, ko so vsi podatki v katalogu.
    groups.Add(new("Validacija in objava", env.Organizations.Select(ValidateAndPromote).ToList()));

    // CSV je samostojen cikel; neuspešen vhod ne sme prikazovati uspešne izdelave CSV.

    // 9. Dnevni mail o zalogi pod MID (200): razpored STOCK_REPLENISHMENT_DIGEST je na en dan, a ga
    // doslej ni poganjal nihče. Brez prejemnikov s kljukico ali brez vklopljene e-pošte samo poroča.
    groups.Add(new("Zaloga pod MID (dnevni mail)",
      [Worker("Zaloga pod MID", "PIM.StockReplenishmentWorker", ["--organizations", orgs], env.Paths)]));

    return groups;
  }

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

  /// <summary>Datoteke enega vira zaloge × podjetja; ista datoteka drugič je isti posnetek (worker to pove sam).</summary>
  internal static IReadOnlyList<CycleStep> StockFilesSteps(string vir, string mapa, CycleEnvironment env, string[] urnik)
  {
    if (!env.DirectoryExists(mapa)) return [Note($"Branje {vir}", $"preskočeno: mape {mapa} ni")];
    var datoteke = env.ListFiles(mapa);
    if (datoteke.Count == 0) return [Note($"Branje {vir}", "preskočeno: prevzete datoteke ni")];

    var steps = new List<CycleStep>();
    foreach (var datoteka in datoteke)
      foreach (var org in env.Organizations)
        steps.Add(Worker($"Zaloga {vir} (podjetje {org})", "PIM.StockFileWorker",
          ["--file", datoteka, "--source", vir, "--organization-id", Org(org), .. urnik], env.Paths, org));
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

  internal static CycleStep ValidateAndPromote(int org) =>
    new($"Validacija in objava (podjetje {org})", CycleStepKind.Sql, $"EXEC val.RunValidation, val.Promote @OrganizationId = {org}",
      Sql: ["EXEC val.RunValidation @OrganizationId = @OrganizationId;", "EXEC val.Promote @OrganizationId = @OrganizationId;"], OrganizationId: org);

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
