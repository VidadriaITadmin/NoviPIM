using System.Text;
using PIM.Intranet.Services;

/// <summary>
/// Ročni zagon workerjev (/sistem/workerji, 2026-09-15): sestava ukaza, razvrstitev dnevnika in
/// branje izpisa schtasks. Brez procesa in brez baze; pravi zagon je preverjen posebej.
/// Od 2026-09-17 cikli ne tečejo prek PowerShella (glej WorkerSchedulerChecks); tu ostane worker.
/// </summary>
static class WorkerConsoleChecks
{
  public static void Run()
  {
    var paths = new WorkerPaths(@"C:\repo", @"C:\repo\PIM_Solution", _ => null, organizationId => $@"C:\repo\izvoz\magento\{organizationId}");

    // ─── Katalog poslov ──────────────────────────────────────────────────────
    var keys = WorkerJobs.All.Select(job => job.Key).ToList();
    Check(keys.Distinct().Count() == keys.Count, "Ključ posla mora biti enoličen.");
    Check(keys.All(key => WorkerLogs.TryParseRunLogFileName(WorkerLogs.RunLogFileName(key, new DateTime(2026, 9, 15, 7, 0, 0)), out var back, out _) && back == key),
      "Ime dnevnika zagona se mora prebrati nazaj v isti ključ.");
    Check(WorkerJobs.All.All(job => job.Reach == WorkerJobReach.Internal || !string.IsNullOrWhiteSpace(job.ReachNote)),
      "Posel, ki seže navzven, mora povedati, kam.");
    Check(WorkerJobs.All.Where(job => job.Target == "PIM.SaopStockWorker").All(job => job.Environment?["PIM_SAOP_MODE"] == "Live"),
      "SaopStockWorker brez PIM_SAOP_MODE=Live SAOP-a ne pokliče in konča z 0 — ročni zagon bi lagal, da je uspel.");
    Check(WorkerJobs.All.Where(job => job.Kind == WorkerJobKind.Cycle).All(job => WorkerCycles.Find(job.Target) is not null && job.ScriptLogPrefix is not null),
      "Cikel kaže na obstoječ cikel in pozna predpono dnevnika stare skripte.");
    Check(WorkerJobs.WindowsTasks.All(task => task.JobKey is null || WorkerJobs.Find(task.JobKey) is not null),
      "Vsaka Windows naloga mora kazati na obstoječ posel.");
    Check(WorkerJobs.WindowsTasks.Any(task => task.Task == "PIM zaloga") && WorkerJobs.WindowsTasks.Any(task => task.Task == "PIM nadzor"),
      "Stran mora poznati nalogi za zalogo in nadzor — prav ti dve 2026-09-15 nista bili registrirani.");

    // ─── Cikel nima načrta procesov: to je delo WorkerCycles.Plan ────────────
    var refusedCycle = false;
    try { WorkerJobs.Plan(WorkerJobs.Find("zaloga-cikel")!, [2, 3], false, paths); }
    catch (InvalidOperationException) { refusedCycle = true; }
    Check(refusedCycle, "Načrt procesov za cikel se zavrne; cikel teče v intranetu po WorkerCycles.Plan.");

    // ─── Worker na podjetje: en proces na podjetje, vsak v svojo mapo ───────
    var export = WorkerJobs.Plan(WorkerJobs.Find("izvoz-cene-zaloga")!, [1, 4], false, paths);
    Check(export.Count == 2, "Izvoz teče enkrat na podjetje.");
    Check(export[1].OrganizationId == 4 && export[1].Arguments.Contains(@"C:\repo\izvoz\magento\4") && export[1].Arguments.Contains("4"),
      "Drugo podjetje gre v svojo mapo.");
    Check(export[0].FileName == "dotnet" && export[0].Arguments.Contains("--no-build")
      && export[0].Arguments.Contains(@"C:\repo\PIM_Solution\workers\PIM.B2bWorker"),
      "Brez objavljenega exe worker teče kot iz skript: dotnet run --no-build.");
    Check(export[0].Arguments.SkipWhile(argument => argument != "--").Skip(1).First() == "--export-profile", "Argumenti workerja so za --.");

    var refused = false;
    try { WorkerJobs.Plan(WorkerJobs.Find("saop-zaloga")! with { PerOrganization = true }, [], false, paths); }
    catch (InvalidOperationException) { refused = true; }
    Check(refused, "Posel po podjetjih brez podjetja se ne sme tiho končati brez dela.");

    // ─── Katalog: en par datotek, vedno podjetje 2, ne glede na izbiro (2026-09-15) ────
    // Brez --output-dir: mapo razreši worker sam iz registra EXPORT_ROOT, da ročni zagon in urnik
    // pišeta na isto mesto (2026-09-16).
    foreach (var izbor in new[] { (IReadOnlyList<int>)[], [1, 3, 4], [1, 2, 3, 4] })
    {
      var katalog = WorkerJobs.Plan(WorkerJobs.Find("izvoz-katalog")!, izbor, izbor.Count == 4, paths);
      Check(katalog.Count == 1 && katalog[0].OrganizationId == 2
        && !katalog[0].Arguments.Contains("--output-dir") && katalog[0].Arguments.Contains("--organization-id")
        && katalog[0].Arguments[katalog[0].Arguments.ToList().IndexOf("--organization-id") + 1] == "2",
        $"Izvoz kataloga teče enkrat, za podjetje 2, brez lastne mape, tudi pri izbiri [{string.Join(",", izbor)}].");
    }

    // ─── Objavljen worker (strežnik): exe naravnost ─────────────────────────
    var published = WorkerJobs.Plan(WorkerJobs.Find("saop-zaloga")!, [2], false,
      paths with { PublishedWorker = worker => $@"D:\PIM\{worker}\{worker}.exe" });
    Check(published[0].FileName == @"D:\PIM\PIM.SaopStockWorker\PIM.SaopStockWorker.exe" && published[0].Arguments.SequenceEqual(["--organizations", "2"]),
      "Objavljen worker teče naravnost z izbranimi podjetji.");

    // ─── Postavitev: strežnik brez PIM.sln z objavljenimi workerji, razvoj s PIM.sln (2026-09-16) ────
    var layoutRoot = Path.Combine(Path.GetTempPath(), "pim-postavitev-" + Guid.NewGuid().ToString("N"));
    var publishedRoot = Path.Combine(layoutRoot, "workerji");
    var sourceRoot = Path.Combine(layoutRoot, "repo");
    Directory.CreateDirectory(Path.Combine(publishedRoot, "PIM.B2bWorker"));
    File.WriteAllText(Path.Combine(publishedRoot, "PIM.B2bWorker", "PIM.B2bWorker.exe"), "");
    Directory.CreateDirectory(Path.Combine(sourceRoot, "PIM_Solution"));
    File.WriteAllText(Path.Combine(sourceRoot, "PIM_Solution", "PIM.sln"), "");
    try
    {
      var none = WorkerConsoleLayout.Resolve(null, null, null, () => null);
      Check(!none.Available && none.Reason!.Contains("Workerji", StringComparison.Ordinal) && none.Reason.Contains("PublishedWorkersRoot", StringComparison.Ordinal),
        "Brez izvorne kode in brez objavljenih workerjev stran pove, kako objaviti in kateri ključ nastaviti.");
      var missing = WorkerConsoleLayout.Resolve(null, Path.Combine(layoutRoot, "ni"), null, () => null);
      Check(!missing.Available, "Nastavljena, a neobstoječa mapa objavljenih workerjev ni na voljo.");

      var server = WorkerConsoleLayout.Resolve(null, publishedRoot, null, () => null);
      Check(server.Available && !server.HasSource && server.SolutionRoot == ""
        && server.PublishedWorkersRoot == publishedRoot && server.LogRoot == Path.Combine(publishedRoot, "logs"),
        "Strežnik samo z objavljenimi workerji: na voljo, brez izvorne kode, dnevniki ob workerjih.");
      Check(WorkerConsoleLayout.Unavailable(server, WorkerJobs.Find("izvoz-katalog")!) is null, "Objavljen worker je na voljo.");
      Check(WorkerConsoleLayout.Unavailable(server, WorkerJobs.Find("saop-zaloga")!) is { } manjka
        && manjka.Contains("PIM.SaopStockWorker", StringComparison.Ordinal),
        "Neobjavljen worker brez izvorne kode ni na voljo in razlog pove, kateri .exe manjka.");
      Check(WorkerConsoleLayout.Unavailable(server, WorkerJobs.Find("katalog-cikel")!) is null,
        "Cikel je na voljo povsod, kjer je postavitev na voljo; manjkajoč worker pove njegov korak.");

      var dev = WorkerConsoleLayout.Resolve(null, null, null, () => Path.Combine(sourceRoot, "PIM_Solution"));
      Check(dev.Available && dev.HasSource && dev.RepositoryRoot == sourceRoot
        && dev.SolutionRoot == Path.Combine(sourceRoot, "PIM_Solution") && dev.PublishedWorkersRoot is null,
        "Razvoj: koren se najde po PIM.sln, objavljenih workerjev ni.");
      Check(WorkerConsoleLayout.Unavailable(dev, WorkerJobs.Find("saop-zaloga")!) is null, "Z izvorno kodo teče vsak worker (dotnet run).");
      Check(dev.CycleLogRoot == Path.Combine(sourceRoot, "logs", "cikli") && dev.ManualLogRoot == Path.Combine(sourceRoot, "logs", "workerji"),
        "Cikli in ročni zagoni workerjev imata vsak svojo podmapo dnevnikov.");

      var configured = WorkerConsoleLayout.Resolve(sourceRoot, null, Path.Combine(layoutRoot, "dnevniki"), () => null);
      Check(configured.HasSource && configured.LogRoot == Path.Combine(layoutRoot, "dnevniki"), "Nastavljen koren in LogRoot veljata pred privzetki.");

      // Objava v eno mapo (dotnet publish intraneta): Workerji\ ob intranetu, brez ključev.
      var site = Path.Combine(layoutRoot, "site");
      Directory.CreateDirectory(Path.Combine(site, "Workerji", "PIM.Watchdog"));
      File.WriteAllText(Path.Combine(site, "Workerji", "PIM.Watchdog", "PIM.Watchdog.exe"), "");
      var bundled = WorkerConsoleLayout.Resolve(null, null, null, () => null, site);
      Check(bundled.Available && !bundled.HasSource && bundled.RepositoryRoot == site
        && bundled.PublishedWorkersRoot == Path.Combine(site, "Workerji") && bundled.LogRoot == Path.Combine(site, "logs"),
        "Objava v eno mapo: Workerji\\ ob intranetu velja brez nastavitev, dnevniki ob aplikaciji.");
      Check(WorkerConsoleLayout.Unavailable(bundled, WorkerJobs.Find("watchdog")!) is null
        && WorkerConsoleLayout.Unavailable(bundled, WorkerJobs.Find("izvoz-katalog")!) is { } neobjavljen
        && neobjavljen.Contains("PIM.B2bWorker", StringComparison.Ordinal),
        "V objavi v eno mapo je na voljo natanko to, kar je objavljeno.");
      var devWithSite = WorkerConsoleLayout.Resolve(null, null, null, () => Path.Combine(sourceRoot, "PIM_Solution"), site);
      Check(devWithSite.HasSource && devWithSite.RepositoryRoot == sourceRoot && devWithSite.PublishedWorkersRoot == Path.Combine(site, "Workerji"),
        "Z izvorno kodo koren ostane repozitorij; objavljeni workerji ob aplikaciji se vseeno uporabijo.");
      var overridden = WorkerConsoleLayout.Resolve(Path.Combine(layoutRoot, "koren"), publishedRoot, null, () => null, site);
      Check(overridden.RepositoryRoot == Path.Combine(layoutRoot, "koren") && overridden.PublishedWorkersRoot == publishedRoot,
        "Ključi WorkerConsole:* prepišejo postavitev ob intranetu.");
    }
    finally { Directory.Delete(layoutRoot, recursive: true); }
    var saopAll = WorkerJobs.Plan(WorkerJobs.Find("saop-zaloga")!, [1, 2, 3, 4], true, paths);
    Check(!saopAll[0].Arguments.Contains("--organizations"), "Vsa podjetja pri SAOP pomeni aktivna iz nastavitev, kot pri načrtovanem zagonu.");

    // ─── Spremenljivke gostitelja ────────────────────────────────────────────
    Check(WorkerJobs.IsInheritedHostVariable("DOTNET_STARTUP_HOOKS") && WorkerJobs.IsInheritedHostVariable("ASPNETCORE_ENVIRONMENT")
      && WorkerJobs.IsInheritedHostVariable("ASPNETCORE_URLS"), "Spremenljivke gostitelja (VS, IIS) se ne dedujejo v worker.");
    Check(!WorkerJobs.IsInheritedHostVariable("PIM_CONNECTION_STRING") && !WorkerJobs.IsInheritedHostVariable("PATH")
      && !WorkerJobs.IsInheritedHostVariable("DOTNET_ROOT"), "Spremenljivke, ki jih worker rabi, ostanejo.");

    // ─── Razvrstitev vrstic: primeri iz pravih dnevnikov ─────────────────────
    Check(WorkerLogs.Classify("2026-09-04 02:36:11     NAPAKA v koraku 'SAOP katalog' po 340 s: worker je končal z izhodno kodo 1") == LogLineTone.Error,
      "NAPAKA je napaka, tudi če vrstica omenja konec.");
    Check(WorkerLogs.Classify("2026-09-04 02:39:51  POVZETEK: opravljenih 7, padlih 2.") == LogLineTone.Error, "Padli koraki v povzetku so napaka.");
    Check(WorkerLogs.Classify("08:27:51  Zalogovni cikel koncan; padlih korakov: 0.") == LogLineTone.Success, "Nič padlih je uspeh.");
    Check(WorkerLogs.Classify("08:27:41     [1] SAOP_STOCK: se ni na vrsti po razporedu; preskoceno.") == LogLineTone.Warning,
      "Preskok po razporedu je opozorilo: nič se ni zgodilo.");
    Check(WorkerLogs.Classify("08:27:39  == Zaloga iz SAOP (kolicine) ==") == LogLineTone.Header, "Korak je naslov.");
    Check(WorkerLogs.Classify("08:27:36     Prebranih zapisov: 1389; SHA-256: 9fa8") == LogLineTone.Normal, "Navadna vrstica ostane navadna.");
    Check(WorkerLogs.Classify("07:00:00  STDERR: Razpored za SAOP_DELIVERY_DATES ni omogocen") == LogLineTone.Error, "Izpis na stderr je napaka.");
    Check(WorkerLogs.Classify("19:05:00  PRESKOCENO: cikel poganja razporejevalnik v aplikaciji (PC:1:dotnet).") == LogLineTone.Warning,
      "Umik skripte pred razporejevalnikom je opozorilo, ne napaka.");

    var footerOk = WorkerLogs.Footer(0, TimeSpan.FromSeconds(75), cancelled: false);
    Check(footerOk == "=== KONEC: izhod 0, trajanje 00:01:15", "Zadnja vrstica ima izhodno kodo in trajanje: " + footerOk);
    Check(WorkerLogs.Classify(footerOk) == LogLineTone.Success && WorkerLogs.Classify(WorkerLogs.Footer(2, TimeSpan.Zero, false)) == LogLineTone.Error,
      "Konec z 0 je uspeh, z drugo kodo napaka.");
    Check(WorkerLogs.ExitCodeFromFooter(["vrstica", WorkerLogs.Footer(3, TimeSpan.FromMinutes(2), false)]) == 3, "Izhodna koda se prebere nazaj.");
    Check(WorkerLogs.ExitCodeFromFooter([WorkerLogs.HeaderPrefix + "Zaloga", "vrstica"]) is null, "Nekončan zagon nima izhodne kode.");
    // Tako je zapisana v datoteki: z uro spredaj. Brez tega je stran pri vsakem ročnem zagonu
    // med dnevniki kazala »ni končal« (najdeno s pravim zagonom 2026-09-15).
    Check(WorkerLogs.ExitCodeFromFooter(["vrstica", WorkerLogs.Stamp(WorkerLogs.Footer(2, TimeSpan.FromSeconds(2), false), new DateTime(2026, 9, 15, 8, 19, 29))]) == 2,
      "Izhodna koda se prebere tudi iz vrstice z uro.");
    Check(WorkerLogs.Footer(-1, TimeSpan.FromHours(1.5), cancelled: true).Contains("ustavljeno ročno", StringComparison.Ordinal), "Ročna ustavitev je zapisana.");

    // ─── Imena in vrste dnevnikov ────────────────────────────────────────────
    Check(WorkerLogs.RunLogFileName("saop-zaloga", new DateTime(2026, 9, 15, 7, 30, 5)) == "saop-zaloga_2026-09-15_073005.log", "Ime dnevnika ročnega zagona.");
    Check(!WorkerLogs.TryParseRunLogFileName("zaloga-2026-09-07.log", out _, out _), "Dnevni dnevnik skripte ni zagon iz intraneta.");
    Check(WorkerLogs.KindOf("zaloga-2026-09-07.log") == "zaloga" && WorkerLogs.KindOf("nocno_2026-09-04_0230.log") == "nocno"
      && WorkerLogs.KindOf(Path.Combine("workerji", "saop-zaloga_2026-09-15_073005.log")) == "rocno"
      && WorkerLogs.KindOf(Path.Combine("cikli", "nadzor_2026-09-17_120000.log")) == "cikli" && WorkerLogs.KindOf("cudno.log") == "drugo",
      "Vrsta dnevnika se ugotovi po imenu.");

    Check(WorkerLogs.Stamp("== Zaloga ==", new DateTime(2026, 9, 15, 7, 1, 2)) == "07:01:02  == Zaloga ==", "Vrstica brez ure dobi uro.");
    Check(WorkerLogs.Stamp("07:00:00  že ima uro", new DateTime(2026, 9, 15, 7, 1, 2)) == "07:00:00  že ima uro", "Skriptina ura se ne podvoji.");
    Check(WorkerLogs.Stamp("2026-09-04 02:36:11  nočni", new DateTime(2026, 9, 15, 7, 1, 2)) == "2026-09-04 02:36:11  nočni", "Nočni tok piše datum in uro.");

    // ─── Mapa dnevnikov: pobeg iz mape se zavrne ─────────────────────────────
    var root = Path.Combine(Path.GetTempPath(), "pim-dnevniki-" + Guid.NewGuid().ToString("N"));
    Check(WorkerLogs.ResolveInside(root, Path.Combine("..", "skrivnost.log")) is null, "Pot ne sme pobegniti iz mape dnevnikov.");
    Check(WorkerLogs.ResolveInside(root, @"C:\Windows\win.ini") is null, "Absolutna pot ni dovoljena.");
    Check(WorkerLogs.ResolveInside(root, "appsettings.Local.json") is null, "Samo dnevniki, ne druge datoteke.");
    Check(WorkerLogs.ResolveInside(root, Path.Combine("workerji", "a.log")) == Path.Combine(root, "workerji", "a.log"), "Dnevnik v podmapi je dovoljen.");

    // ─── Kodna stran: worker brez skripte piše v 852, skripta v UTF-8 ────────
    Check(WorkerLogs.DecodeLine(Encoding.UTF8.GetBytes("Validacija končana\r")) == "Validacija končana", "UTF-8 ostane UTF-8, \\r odpade.");
    Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
    Check(WorkerLogs.DecodeLine(Encoding.GetEncoding(852).GetBytes("Validacija končana")) == "Validacija končana", "Kodna stran 852 se prepozna.");

    // ─── Konec datoteke: delna prva vrstica in BOM odpadeta ──────────────────
    Directory.CreateDirectory(root);
    try
    {
      var file = Path.Combine(root, "zaloga-2026-09-15.log");
      File.WriteAllText(file, "prva vrstica\nčetrta ura\nzadnja\n", new UTF8Encoding(encoderShouldEmitUTF8Identifier: true));
      var all = WorkerLogs.ReadTail(file, 1 << 20);
      Check(all.SequenceEqual(["prva vrstica", "četrta ura", "zadnja"]), "Cela datoteka: " + string.Join("|", all));
      var tail = WorkerLogs.ReadTail(file, 10);
      Check(tail.SequenceEqual(["zadnja"]), "Konec datoteke brez delne vrstice: " + string.Join("|", tail));
    }
    finally { Directory.Delete(root, recursive: true); }

    // ─── schtasks ────────────────────────────────────────────────────────────
    var task = WorkerLogs.ParseSchtasksCsv("\"\\PIM katalog\",\"15. 09. 2026 07:53:04\",\"Ready\"");
    Check(task == new ScheduledTaskLine("PIM katalog", "15. 09. 2026 07:53:04", "Ready"), "Vrstica schtasks: " + task);
    Check(WorkerLogs.ParseSchtasksCsv("") is null, "Prazna vrstica ni naloga.");

    Console.WriteLine("F10 worker console logic PASS.");
  }

  static void Check(bool condition, string message)
  {
    if (condition) return;
    Console.Error.WriteLine("NAPAKA: " + message);
    Environment.Exit(1);
  }
}
