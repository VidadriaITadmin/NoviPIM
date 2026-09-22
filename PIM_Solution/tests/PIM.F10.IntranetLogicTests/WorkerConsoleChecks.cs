using System.Text;
using PIM.Automation;
using PIM.Intranet.Services;

/// <summary>
/// Gradniki zagona workerja in branja dnevnikov (WorkerConsolePolicy): postavitev (izvorna koda ali
/// objavljeni workerji), ukaz enega procesa, razvrstitev vrstic in branje konca datoteke. Brez procesa
/// in brez baze. Stran /sistem/workerji, ročni zagoni mimo gostitelja in stari cikli so odpadli
/// (migracija 254); posle poganja samo PIM.AutomationHost (glej JobCatalogChecks), dnevnike zagonov
/// pa bere stran zagonov.
/// </summary>
static class WorkerConsoleChecks
{
  public static void Run()
  {
    var paths = new WorkerPaths(@"C:\repo", @"C:\repo\PIM_Solution", _ => null, organizationId => $@"C:\repo\izvoz\magento\{organizationId}");

    // ─── En proces workerja: dotnet run --no-build na razvoju ───────────────
    var launch = WorkerJobs.LaunchWorker("PIM.B2bWorker", ["--export-profile", "MAGENTO_STOCK_PRICES", "--organization-id", "4"], paths, 4);
    Check(launch.FileName == "dotnet" && launch.Arguments.Contains("--no-build")
      && launch.Arguments.Contains(@"C:\repo\PIM_Solution\workers\PIM.B2bWorker") && launch.OrganizationId == 4,
      "Brez objavljenega exe worker teče kot iz skript: dotnet run --no-build.");
    Check(launch.Arguments.SkipWhile(argument => argument != "--").Skip(1).First() == "--export-profile", "Argumenti workerja so za --.");

    // ─── Objavljen worker (strežnik): exe naravnost ─────────────────────────
    var published = WorkerJobs.LaunchWorker("PIM.SaopStockWorker", ["--organizations", "2"],
      paths with { PublishedWorker = worker => $@"D:\PIM\{worker}\{worker}.exe" }, 2);
    Check(published.FileName == @"D:\PIM\PIM.SaopStockWorker\PIM.SaopStockWorker.exe" && published.Arguments.SequenceEqual(["--organizations", "2"])
      && published.WorkingDirectory == @"D:\PIM\PIM.SaopStockWorker",
      "Objavljen worker teče naravnost, v svoji mapi, z izbranimi podjetji.");

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
      Check(WorkerConsoleLayout.PublishedWorker(server.PublishedWorkersRoot, "PIM.B2bWorker") == Path.Combine(publishedRoot, "PIM.B2bWorker", "PIM.B2bWorker.exe"),
        "Objavljen worker se najde kot <mapa>\\<Worker>\\<Worker>.exe.");
      Check(WorkerConsoleLayout.PublishedWorker(server.PublishedWorkersRoot, "PIM.SaopStockWorker") is null,
        "Neobjavljen worker nima .exe; brez izvorne kode ga ni mogoče pognati.");

      var dev = WorkerConsoleLayout.Resolve(null, null, null, () => Path.Combine(sourceRoot, "PIM_Solution"));
      Check(dev.Available && dev.HasSource && dev.RepositoryRoot == sourceRoot
        && dev.SolutionRoot == Path.Combine(sourceRoot, "PIM_Solution") && dev.PublishedWorkersRoot is null
        && dev.LogRoot == Path.Combine(sourceRoot, "logs"),
        "Razvoj: koren se najde po PIM.sln, objavljenih workerjev ni, dnevniki so v logs ob repozitoriju.");

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
      Check(WorkerConsoleLayout.PublishedWorker(bundled.PublishedWorkersRoot, "PIM.Watchdog") is not null
        && WorkerConsoleLayout.PublishedWorker(bundled.PublishedWorkersRoot, "PIM.B2bWorker") is null,
        "V objavi v eno mapo je na voljo natanko to, kar je objavljeno.");
      var devWithSite = WorkerConsoleLayout.Resolve(null, null, null, () => Path.Combine(sourceRoot, "PIM_Solution"), site);
      Check(devWithSite.HasSource && devWithSite.RepositoryRoot == sourceRoot && devWithSite.PublishedWorkersRoot == Path.Combine(site, "Workerji"),
        "Z izvorno kodo koren ostane repozitorij; objavljeni workerji ob aplikaciji se vseeno uporabijo.");
      var overridden = WorkerConsoleLayout.Resolve(Path.Combine(layoutRoot, "koren"), publishedRoot, null, () => null, site);
      Check(overridden.RepositoryRoot == Path.Combine(layoutRoot, "koren") && overridden.PublishedWorkersRoot == publishedRoot,
        "Ključi WorkerConsole:* prepišejo postavitev ob intranetu.");
    }
    finally { Directory.Delete(layoutRoot, recursive: true); }

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
    // Tako je zapisana v datoteki: z uro spredaj; ton se mora prepoznati tudi takrat.
    Check(WorkerLogs.Classify(WorkerLogs.Stamp(WorkerLogs.Footer(2, TimeSpan.FromSeconds(2), false), new DateTime(2026, 9, 15, 8, 19, 29))) == LogLineTone.Error,
      "Konec z napako ostane napaka tudi v vrstici z uro.");
    Check(WorkerLogs.Footer(-1, TimeSpan.FromHours(1.5), cancelled: true).Contains("ustavljeno ročno", StringComparison.Ordinal), "Ročna ustavitev je zapisana.");

    // ─── Ime dnevnika zagona ─────────────────────────────────────────────────
    Check(WorkerLogs.RunLogFileName("SAOP_PRODUCT_IMPORT", new DateTime(2026, 9, 15, 7, 30, 5)) == "SAOP_PRODUCT_IMPORT_2026-09-15_073005.log", "Ime dnevnika zagona posla.");

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

    Console.WriteLine("F10 worker console logic PASS.");
  }

  static void Check(bool condition, string message)
  {
    if (condition) return;
    Console.Error.WriteLine("NAPAKA: " + message);
    Environment.Exit(1);
  }
}
