using PIM.Intranet.Services;

/// <summary>
/// Razporejevalnik v aplikaciji (2026-09-17): katalog ciklov, načrt korakov, naslednji termin in
/// presoja zaostanka. Brez baze in brez procesa; kar cikel potrebuje od sveta, pride prek
/// CycleEnvironment iz konstant.
/// </summary>
static class WorkerSchedulerChecks
{
  static readonly TimeZoneInfo Zone = TimeZoneInfo.FindSystemTimeZoneById("Central European Standard Time");

  public static void Run()
  {
    // ─── Katalog ciklov ──────────────────────────────────────────────────────
    var keys = WorkerCycles.All.Select(cycle => cycle.Key).ToList();
    Check(keys.Distinct().Count() == keys.Count && keys.Count == 5, "Pet ciklov z enoličnimi ključi: isti, kot jih je poganjalo pet Windows nalog.");
    Check(WorkerCycles.All.All(cycle => (cycle.IntervalSeconds is not null) != (cycle.DailyAtLocal is not null)),
      "Cikel ima bodisi razmik bodisi dnevno uro.");
    Check(WorkerCycles.LegacyTasks.All(task => WorkerCycles.Find(task.CycleKey) is not null)
      && WorkerCycles.LegacyTasks.Select(task => task.Task).Order().SequenceEqual(WorkerJobs.WindowsTasks.Select(task => task.Task).Order()),
      "Vsaka stara Windows naloga ima svoj cikel in stran jih pozna po istih imenih.");
    Check(WorkerJobs.All.Where(job => job.Kind == WorkerJobKind.Cycle).All(job => WorkerCycles.Find(job.Target) is not null),
      "Vsak posel vrste Cikel kaže na obstoječ cikel.");
    Check(WorkerCycles.All.All(cycle => WorkerJobs.ForCycle(cycle.Key) is { } job && job.Cycle is null),
      "Vsak cikel ima posel s privzetimi stikali, ki ga požene razporejevalnik.");
    Check(WorkerJobs.ForCycle(WorkerCycles.Zaloga)!.Key == "zaloga-cikel" && WorkerJobs.Find("zaloga-dobavitelji")!.Cycle!.OnlySuppliers,
      "Zaloga dobaviteljev je isti cikel z drugačnim stikalom, ne drug cikel.");
    Check(WorkerCycles.OwnerName("PIM-SRV", 4242, WorkerCycles.ApplicationName("PIM")) == "PIM-SRV:4242:IIS:PIM"
      && WorkerCycles.ApplicationName(null) == "dotnet",
      "Lastnik najema pove gostitelja, proces in ali gre za IIS bazen.");

    // ─── Naslednji termin ───────────────────────────────────────────────────
    var noon = new DateTime(2026, 9, 17, 10, 0, 0, DateTimeKind.Utc); // 12:00 CEST
    Check(WorkerCycles.NextDue(300, null, noon, Zone) == noon.AddMinutes(5), "Ponavljajoč cikel: začetek + razmik.");
    Check(WorkerCycles.NextDue(null, new TimeOnly(2, 30), noon, Zone) == new DateTime(2026, 9, 18, 0, 30, 0, DateTimeKind.Utc),
      "Dnevni cikel ob 02:30 naše ure je naslednjič jutri ob 00:30 UTC (poletni čas).");
    Check(WorkerCycles.NextDue(null, new TimeOnly(2, 30), new DateTime(2026, 9, 17, 0, 0, 0, DateTimeKind.Utc), Zone) == new DateTime(2026, 9, 17, 0, 30, 0, DateTimeKind.Utc),
      "Ob 02:00 naše ure je 02:30 še danes.");
    Check(WorkerCycles.NextDue(null, new TimeOnly(2, 30), new DateTime(2026, 12, 17, 10, 0, 0, DateTimeKind.Utc), Zone) == new DateTime(2026, 12, 18, 1, 30, 0, DateTimeKind.Utc),
      "Pozimi je 02:30 naše ure ob 01:30 UTC.");
    var springForward = WorkerCycles.NextDue(null, new TimeOnly(2, 30), new DateTime(2026, 3, 28, 12, 0, 0, DateTimeKind.Utc), Zone);
    Check(springForward == new DateTime(2026, 3, 29, 1, 30, 0, DateTimeKind.Utc),
      "Ura, ki je na dan prehoda na poletni čas ni (02:30 -> 03:30), se premakne za uro naprej in ne pade: " + springForward.ToString("o"));
    Check(WorkerCycles.InitialDue(300, null, 2, noon, Zone) == noon.AddMinutes(5) && WorkerCycles.InitialDue(300, null, 0, noon, Zone) == noon.AddMinutes(1),
      "Prvi termini ponavljajočih ciklov so razmaknjeni za dve minuti.");

    // ─── Zaostanek: 5 min razmik, 10 min mirovanja = opozorilo ──────────────
    var now = noon;
    Check(WorkerCycles.Evaluate(true, false, now.AddMinutes(-4), now.AddHours(-1), 300, 2m, now).State == CycleRhythm.Ok, "4 min po začetku je cikel v ritmu.");
    Check(WorkerCycles.Evaluate(true, false, now.AddMinutes(-7), now.AddHours(-1), 300, 2m, now).State == CycleRhythm.Late, "7 min pri razmiku 5 min zamuja.");
    var overdue = WorkerCycles.Evaluate(true, false, now.AddMinutes(-11), now.AddHours(-1), 300, 2m, now);
    Check(overdue.State == CycleRhythm.Overdue && overdue.Behind == TimeSpan.FromMinutes(6),
      "11 min pri razmiku 5 min je zastal (več kot dvakrat razmika), za 6 min čez razmik.");
    Check(WorkerCycles.Evaluate(true, false, now.AddMinutes(-10), now.AddHours(-1), 300, 2m, now).State == CycleRhythm.Late,
      "Natanko dvakratnik še ni zastal; meja je presežena, ne dosežena.");
    Check(WorkerCycles.Evaluate(true, true, now.AddMinutes(-30), now.AddHours(-1), 300, 2m, now).State == CycleRhythm.Running, "Tekoč cikel ni zastal, tudi če teče dolgo.");
    Check(WorkerCycles.Evaluate(false, false, now.AddHours(-5), now.AddHours(-6), 300, 2m, now).State == CycleRhythm.Off, "Izklopljen cikel nima ritma.");
    Check(WorkerCycles.Evaluate(true, false, null, now.AddMinutes(-3), 300, 2m, now).State == CycleRhythm.Never, "Pravkar vklopljen cikel še ni zastal.");
    Check(WorkerCycles.Evaluate(true, false, null, now.AddMinutes(-11), 300, 2m, now).State == CycleRhythm.Overdue, "Cikel, ki ni tekel nikoli, zastane od nastavitve naprej.");
    Check(WorkerCycles.Evaluate(true, false, now.AddHours(-30), now.AddDays(-3), null, 2m, now).State == CycleRhythm.Late
      && WorkerCycles.Evaluate(true, false, now.AddHours(-49), now.AddDays(-3), null, 2m, now).State == CycleRhythm.Overdue,
      "Dnevni cikel ima razmik en dan: po 30 h zamuja, po 49 h je zastal.");

    // ─── Stare naloge, ki še tečejo vzporedno ────────────────────────────────
    var logs = new List<WorkerLogFile>
    {
      new("zaloga-2026-09-17.log", "zaloga", now.AddMinutes(-3), 10, 0, null, null),
      new(Path.Combine("cikli", "zaloga-cikel_2026-09-17_115500.log"), "cikli", now.AddMinutes(-1), 10, 0, null, "zaloga-cikel"),
      new("nadzor-2026-09-17.log", "nadzor", now.AddHours(-2), 10, 0, null, null),
    };
    var legacy = WorkerCycles.RecentLegacyRuns(logs, now, TimeSpan.FromMinutes(15));
    Check(legacy.Count == 1 && legacy[0].Task == "PIM zaloga" && legacy[0].CycleKey == WorkerCycles.Zaloga,
      "Svež dnevnik skripte v korenu pomeni, da stara naloga še teče; dnevnik cikla v podmapi in star dnevnik ne štejeta.");

    // ─── Načrt: zaloga ─────────────────────────────────────────────────────
    var files = new Dictionary<string, IReadOnlyList<string>>(StringComparer.OrdinalIgnoreCase)
    {
      [@"D:\prevzem\NW_STOCK"] = [@"D:\prevzem\NW_STOCK\nw-zaloga.csv"],
      [@"D:\prevzem\BT_STOCK"] = [],
      // Razvojni računalnik ima fixtures; strežnik jih nima (FixturesRoot = null).
      [@"C:\repo\PIM_Solution\fixtures\nw"] = [@"C:\repo\PIM_Solution\fixtures\nw\products_en_US.xml"],
      [@"C:\repo\PIM_Solution\fixtures\bt"] = [@"C:\repo\PIM_Solution\fixtures\bt\BRaytron_xml_2026_07_29.xml"],
    };
    var paths = new WorkerPaths(@"C:\repo", @"C:\repo\PIM_Solution", _ => null, organizationId => $@"C:\repo\izvoz\magento\{organizationId}");
    var env = new CycleEnvironment(paths, [1, 2, 3, 4], 2, @"D:\prevzem", null, @"C:\repo\PIM_Solution\fixtures", false, 4,
      directory => files.ContainsKey(directory), directory => files.TryGetValue(directory, out var list) ? list : []);

    var zaloga = Expand(WorkerCycles.Plan(WorkerCycles.Zaloga, new(BySchedule: true), env));
    var names = zaloga.Select(group => group.Name).ToList();
    Check(names.SequenceEqual(["Zaloga NW_STOCK", "Zaloga BT_STOCK", "Zaloga iz SAOP (kolicine)", "Osvezitev cen kataloga",
        "Izvoz cen in zaloge za splet", "Osvezitev kataloga in strank s cenami in zalogo (podjetje 2)", "Zaloga iz SAOP (datumi prihoda)"]),
      "Skupine zalogovnega cikla so iste kot koraki v Zaloga-cikel.ps1, na koncu še datumi dobave: " + string.Join(" | ", names));
    var nw = zaloga[0].Steps;
    Check(nw[0].Process!.Arguments.SequenceEqual(["run", "--project", @"C:\repo\PIM_Solution\workers\PIM.SourceFetchWorker", "--no-build", "--", "--source", "NW_STOCK", "--target", @"D:\prevzem", "--po-urniku"]),
      "Prevzem NW gre v koren prevzema in po razporedu: " + string.Join(" ", nw[0].Process!.Arguments));
    Check(nw.Count == 5 && nw.Skip(1).All(step => step.Process!.Arguments.Contains("--file") && step.Process!.Arguments.Contains(@"D:\prevzem\NW_STOCK\nw-zaloga.csv") && step.Process!.Arguments.Contains("--po-urniku"))
      && nw.Skip(1).Select(step => step.OrganizationId).SequenceEqual([1, 2, 3, 4]),
      "Prevzeta datoteka se prebere za vsako podjetje, po razporedu.");
    Check(zaloga[1].Steps.Count == 2 && zaloga[1].Steps[1].Kind == CycleStepKind.Note && zaloga[1].Steps[1].Command.Contains("prevzete datoteke ni", StringComparison.Ordinal),
      "Vir brez datoteke je zapis, ne napaka: " + zaloga[1].Steps[1].Command);
    var saop = zaloga[2].Steps[0];
    Check(saop.Environment!["PIM_SAOP_MODE"] == "Live" && saop.Process!.Arguments.Contains("--organizations") && saop.Process!.Arguments.Contains("1,2,3,4") && saop.Process!.Arguments.Contains("--po-urniku"),
      "Zaloga iz SAOP teče v živo za vsa podjetja in po razporedu.");
    Check(zaloga[3].Steps[0].Process!.Arguments.Contains("GetPrices") && zaloga[3].Steps[0].Environment!["PIM_SAOP_MODE"] == "Live", "Cene: samo končna točka GetPrices, v živo.");
    var izvoz = zaloga[4].Steps;
    Check(izvoz.Count == 4 && izvoz[2].Process!.Arguments.Contains(@"C:\repo\izvoz\magento\3") && izvoz[2].Process!.Arguments.Contains("MAGENTO_STOCK_PRICES") && izvoz[2].OrganizationId == 3,
      "Cene in zaloga za splet: en proces na podjetje, brez registra v mapo ob korenu.");
    Check(zaloga[5].Steps[0].Process!.Arguments.SequenceEqual(["run", "--project", @"C:\repo\PIM_Solution\workers\PIM.B2bWorker", "--no-build", "--", "--export-magento", "--organization-id", "2"]),
      "Katalog in stranke: samo podjetje 2, mapo razreši worker sam.");
    Check(zaloga[6].Steps[0].Process!.Arguments.Contains("--dostave") && zaloga[6].Steps[0].Process!.Arguments.Contains("--po-urniku"),
      "Datumi dobave vedno po svojem razporedu (30 min), tudi znotraj petminutnega cikla.");

    var rocno = Expand(WorkerCycles.Plan(WorkerCycles.Zaloga, new(), env));
    Check(!rocno[0].Steps[0].Process!.Arguments.Contains("--po-urniku") && !rocno[2].Steps[0].Process!.Arguments.Contains("--po-urniku"),
      "Ročni zagon ne čaka na razpored postopkov (kot skripta brez -PoUrniku).");
    Check(rocno[6].Steps[0].Process!.Arguments.Contains("--po-urniku"), "Datumi dobave so po razporedu tudi pri ročnem zagonu (počasen klic na artikel).");

    var dobavitelji = Expand(WorkerCycles.Plan(WorkerCycles.Zaloga, new(OnlySuppliers: true), env));
    Check(dobavitelji.Count == 2 && dobavitelji.All(group => group.Steps.All(step => step.Environment is null || !step.Environment.ContainsKey("PIM_SAOP_MODE"))),
      "Samo dobavitelji: brez enega samega klica na SAOP.");

    var withExportRoot = Expand(WorkerCycles.Plan(WorkerCycles.Zaloga, new(), env with { ExportRoot = @"E:\izvoz" }));
    Check(!withExportRoot[4].Steps[0].Process!.Arguments.Contains("--output-dir"), "Z nastavljenim EXPORT_ROOT mapo razreši worker sam.");

    // ─── Načrt: katalog ─────────────────────────────────────────────────────
    var katalog = Expand(WorkerCycles.Plan(WorkerCycles.Katalog, new(BySchedule: true), env));
    Check(katalog.Select(group => group.Name).SequenceEqual(["SAOP katalog (delta)", "Narocila iz SAOP (VNK/VND)",
        "Osvezitev objave (podjetje 1)", "Osvezitev objave (podjetje 2)", "Osvezitev objave (podjetje 3)", "Osvezitev objave (podjetje 4)", "Izvoz kataloga in strank (podjetje 2)"]),
      "Urni katalog: SAOP delta, naročila, objava vseh podjetij, izvoz podjetja 2: " + string.Join(" | ", katalog.Select(group => group.Name)));
    Check(katalog[0].Steps[0].Process!.Arguments.Contains("--max-parallel") && katalog[0].Steps[0].Environment!["PIM_SAOP_MODE"] == "Live", "SAOP delta teče v živo, štiri podjetja hkrati.");
    var objava = katalog[2].Steps[0];
    Check(objava.Kind == CycleStepKind.Sql && objava.OrganizationId == 1 && objava.Sql!.Count == 2
      && objava.Sql[0].Contains("val.RunValidation", StringComparison.Ordinal) && objava.Sql[1].Contains("val.Promote", StringComparison.Ordinal),
      "Objava je SQL korak: validacija, potem objava, na podjetje.");

    // ─── Načrt: nadzor ──────────────────────────────────────────────────────
    var nadzor = Expand(WorkerCycles.Plan(WorkerCycles.Nadzor, new(BySchedule: true), env));
    Check(nadzor.Count == 2 && nadzor[0].Steps[0].Process!.Arguments.Contains(@"C:\repo\PIM_Solution\workers\PIM.Watchdog")
      && nadzor[1].Steps[0].Process!.Arguments.Contains(@"C:\repo\PIM_Solution\workers\PIM.AlertDispatcher"),
      "Nadzor: nadzornik, nato razpošiljanje.");

    // ─── Načrt: nočni tok ───────────────────────────────────────────────────
    var nocni = Expand(WorkerCycles.Plan(WorkerCycles.NocniTok, new(BySchedule: true), env with { IsFullCatalogDay = true }));
    var nocniNames = nocni.Select(group => group.Name).ToList();
    Check(nocniNames[0] == "Gradnja" && nocni[0].Steps.All(step => step.Process!.FileName == "dotnet" && step.Process!.Arguments[0] == "build"),
      "Na razvoju se workerji nočnega toka zgradijo enkrat na začetku, vsak posebej (ne PIM.sln).");
    Check(nocniNames.Skip(1).SequenceEqual(["SAOP katalog", "Prevzem dobaviteljevih datotek", "Dobaviteljev XML (Nowodvorski)", "Dobaviteljev XML (Braytron)",
        "Preslikava zaostanka v raw.Inbox", "Zaloge dobaviteljev", "Zaloga iz SAOP (kolicine)", "Zaloga iz SAOP (datumi prihoda)", "Validacija in objava",
        "Izvoz kataloga in strank", "Zaloga pod MID (dnevni mail)"]),
      "Vrstni red nočnega toka je isti kot v Nocno-vse.ps1, na koncu dnevni mail: " + string.Join(" | ", nocniNames));
    Check(nocni[1].Steps[0].Process!.Arguments.Contains("--full"), "Prvi dan v mesecu je zajem kataloga poln.");
    Check(!Expand(WorkerCycles.Plan(WorkerCycles.NocniTok, new(), env))[1].Steps[0].Process!.Arguments.Contains("--full"), "Ostale dni je delta.");
    var xmlNw = nocni[3].Steps;
    Check(xmlNw.Count == 4 && xmlNw[0].Environment!["PIM_XML_ROOT"] == @"C:\repo\PIM_Solution\fixtures\nw" && xmlNw[0].Environment!["PIM_XML_SOURCE_CODE"] == "NW_XML" && xmlNw[3].Environment!["PIM_XML_ORGANIZATION_ID"] == "4",
      "Brez prevzetega XML se na razvoju bere fixtures, za vsako podjetje.");
    files[@"D:\prevzem\BT_XML"] = [@"D:\prevzem\BT_XML\braytron-izdelki.xml"];
    var nocniZBt = Expand(WorkerCycles.Plan(WorkerCycles.NocniTok, new(), env));
    Check(nocniZBt[4].Steps[0].Environment!["PIM_XML_ROOT"] == @"D:\prevzem\BT_XML", "Prevzeti dobaviteljev XML ima prednost pred fixtures.");
    Check(nocni[6].Steps.Count == 5 && nocni[6].Steps[4].Kind == CycleStepKind.Note, "Zaloge dobaviteljev: štiri podjetja za NW datoteko, BT brez datoteke je zapis.");
    var brezSaop = Expand(WorkerCycles.Plan(WorkerCycles.NocniTok, new(SkipSaopCatalog: true, SaopStock: false), env));
    Check(brezSaop.First(group => group.Name == "SAOP katalog").Steps[0].Kind == CycleStepKind.Note
      && brezSaop.Any(group => group.Name == "Zaloga iz SAOP" && group.Steps[0].Kind == CycleStepKind.Note)
      && !brezSaop.Any(group => group.Name.StartsWith("Zaloga iz SAOP (", StringComparison.Ordinal)),
      "Brez SAOP: katalog in zaloga iz SAOP sta zapisa, ne klica.");
    var serverPaths = paths with { SolutionRoot = "", PublishedWorkersRoot = @"D:\site\Workerji", PublishedWorker = worker => $@"D:\site\Workerji\{worker}\{worker}.exe" };
    var server = Expand(WorkerCycles.Plan(WorkerCycles.NocniTok, new(), env with { Paths = serverPaths, FixturesRoot = null }));
    Check(server[0].Name != "Gradnja" && server.SelectMany(group => group.Steps).Where(step => step.Kind == CycleStepKind.Process).All(step => step.Process!.FileName.EndsWith(".exe", StringComparison.Ordinal)),
      "Na strežniku ni gradnje in vsak korak je objavljen .exe.");
    Check(server.First(group => group.Name == "Dobaviteljev XML (Nowodvorski)").Steps[0].Kind == CycleStepKind.Note, "Na strežniku brez prevzetega NW XML ni fixtures: korak je zapis.");

    // ─── Načrt: samotest ────────────────────────────────────────────────────
    var samotest = Expand(WorkerCycles.Plan(WorkerCycles.Samotest, new(), env));
    Check(samotest.Count == 1 && samotest[0].Steps[0].Process!.Arguments.SequenceEqual(["run", "--project", @"C:\repo\PIM_Solution\tests\PIM.SelfTest.Nightly"])
      && samotest[0].Steps[0].Environment!["PIM_TRIGGERED_BY"] == "Task" && samotest[0].Steps[0].Environment!["PIM_SELFTEST_ORG"] == "2",
      "Samotest na razvoju: dotnet run brez --no-build, sprožil Task.");
    var samotestServer = Expand(WorkerCycles.Plan(WorkerCycles.Samotest, new(), env with { Paths = serverPaths }));
    Check(samotestServer[0].Steps[0].Process!.FileName == @"D:\site\Workerji\PIM.SelfTest.Nightly\PIM.SelfTest.Nightly.exe", "Samotest na strežniku: objavljen .exe ob workerjih.");

    // ─── Dnevniki ciklov ────────────────────────────────────────────────────
    Check(WorkerLogs.KindOf(Path.Combine("cikli", "zaloga-cikel_2026-09-17_120000.log")) == "cikli", "Dnevnik cikla je svoja vrsta.");
    Check(WorkerLogs.TryParseRunLogFileName("zaloga-cikel_2026-09-17_120000.log", out var key, out _) && key == "zaloga-cikel", "Ime dnevnika cikla se prebere nazaj v posel.");

    Console.WriteLine("F10 worker scheduler logic PASS.");
  }

  /// <summary>Razgrne korake, ki jih načrt določi šele med tekom (datoteke po prevzemu) — kot to naredi izvajalec.</summary>
  static IReadOnlyList<CycleGroup> Expand(IReadOnlyList<CycleGroup> groups) =>
    groups.Select(group => new CycleGroup(group.Name, group.Steps.SelectMany(step => step.Kind == CycleStepKind.Expand ? step.Expand!() : [step]).ToList())).ToList();

  static void Check(bool condition, string message)
  {
    if (condition) return;
    Console.Error.WriteLine("NAPAKA: " + message);
    Environment.Exit(1);
  }
}
