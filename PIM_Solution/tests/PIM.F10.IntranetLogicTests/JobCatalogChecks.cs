using PIM.Automation;

/// <summary>
/// Enotni model opravil (migracija 237): katalog poslov, odvisnosti, načrti korakov in poslovne
/// kartice. Brez baze in brez procesa; kar posel potrebuje od sveta, pride prek CycleEnvironment.
///
/// Kar ta test drži (zahteva 2026-09-21):
///   - naročila so zunaj kataloškega toka in brez odvisnosti;
///   - izvoz ne validira (--osvezi-validacijo je prepovedan) in ne čaka na razpored postopkov (--po-urniku);
///   - objava samo po uspešni validaciji, izvoz samo iz uspešne objave (vrata);
///   - vsak worker ima svoj posel, nobenega procesa ne poganja »nadrejeni cikel z neprimernim imenom«;
///   - poslovna kartica meri rezultat (starost uspeha, blokada po verigi), ne izhodne kode.
/// </summary>
static class JobCatalogChecks
{
  static readonly TimeZoneInfo Zone = TimeZoneInfo.FindSystemTimeZoneById("Central European Standard Time");

  public static void Run()
  {
    // ─── Katalog ─────────────────────────────────────────────────────────────
    var keys = JobCatalog.All.Select(job => job.Key).ToList();
    Check(keys.Distinct().Count() == keys.Count && keys.Count == 16, $"Šestnajst enoličnih poslov, dobil {keys.Count}.");
    Check(JobCatalog.All.All(job => (job.IntervalSeconds is not null) != (job.DailyAtLocal is not null)), "Posel ima bodisi razmik bodisi dnevno uro.");
    Check(JobCatalog.All.All(job => job.TimeoutSeconds >= 30), "Vsak posel ima časovno mejo.");
    Check(JobCatalog.All.All(job => job.Reach == WorkerJobReach.Internal || !string.IsNullOrWhiteSpace(job.ReachNote)), "Posel, ki seže navzven, pove, kam.");
    Check(JobCatalog.All.All(job => JobCatalog.FlowOrder.Contains(job.Flow)), "Vsak posel sodi v znan tok.");
    foreach (var flow in JobFlows.Cards)
      Check(JobCatalog.All.Count(job => job.Flow == flow && job.IsFlowResult) == 1, $"Tok {flow} ima natanko en posel, ki je rezultat toka.");
    Check(JobCatalog.All.All(job => job.Dependencies.All(d => JobCatalog.Find(d.DependsOnJobKey) is not null)), "Vsaka odvisnost kaže na obstoječ posel.");
    Check(!HasCycle(), "Odvisnosti nimajo kroga.");

    // ─── Naročila so ločena od kataloga ──────────────────────────────────────
    var orders = JobCatalog.Find(JobCatalog.SaopOrderImport)!;
    Check(orders.Dependencies.Count == 0 && JobCatalog.All.All(job => job.Dependencies.All(d => d.DependsOnJobKey != JobCatalog.SaopOrderImport)),
      "Naročila iz SAOP nimajo nobene odvisnosti in nihče ni odvisen od njih.");
    Check(orders.Flow == JobFlows.Orders && orders.IsFlowResult, "Naročila so rezultat svojega toka.");

    // ─── Vrata: objava po validaciji, izvoz iz objave ───────────────────────
    var publication = JobCatalog.Find(JobCatalog.ProductPublication)!;
    Check(publication.Dependencies.Single(d => d.DependsOnJobKey == JobCatalog.ProductValidation) is { IsGate: true, MaxAgeSeconds: 7200, TriggersDependent: true },
      "Objava je vrata za validacijo, mlajšo od dveh ur, in jo validacija sproži.");
    var export = JobCatalog.Find(JobCatalog.WebCatalogExport)!;
    Check(export.Dependencies.Single(d => d.DependsOnJobKey == JobCatalog.ProductPublication) is { IsGate: true, TriggersDependent: true },
      "Izvoz kataloga je vrata za objavo in ga objava sproži.");
    Check(export.IntervalSeconds == 3600 && export.TimeoutSeconds == 1800,
      "242: razmik izvoza kataloga je rezerva (1 h), ker ga sproži objava; izvoz podjetja 2 traja minute, zato mora meja ostati 30 min.");
    Check(JobCatalog.Find(JobCatalog.ProductValidation)!.Dependencies.Single().IsGate == false, "Padec zajema artiklov validacije ne blokira (samo sproži).");

    // ─── Vsak worker ima posel ───────────────────────────────────────────────
    foreach (var worker in new[] { "PIM.KatalogWorker", "PIM.SaopOrdersWorker", "PIM.SourceFetchWorker", "PIM.StockFileWorker", "PIM.SaopStockWorker",
      "PIM.XmlFileWorker", "PIM.B2bWorker", "PIM.Watchdog", "PIM.AlertDispatcher", "PIM.StockReplenishmentWorker", "PIM.OutboxDispatcher", "PIM.SelfTest.Nightly" })
      Check(JobCatalog.All.Any(job => job.Workers.Contains(worker)), $"Worker {worker} nima posla.");

    // ─── Načrti ──────────────────────────────────────────────────────────────
    var files = new Dictionary<string, IReadOnlyList<string>>(StringComparer.OrdinalIgnoreCase)
    {
      [@"D:\prevzem\NW_STOCK"] = [@"D:\prevzem\NW_STOCK\nw-zaloga.csv"],
      [@"D:\prevzem\BT_STOCK"] = [],
      [@"C:\repo\PIM_Solution\fixtures\nw"] = [@"C:\repo\PIM_Solution\fixtures\nw\products_en_US.xml"],
    };
    var paths = new WorkerPaths(@"C:\repo", @"C:\repo\PIM_Solution", _ => null, org => $@"C:\repo\izvoz\magento\{org}");
    var env = new CycleEnvironment(paths, [1, 2, 3, 4], 2, @"D:\prevzem", null, @"C:\repo\PIM_Solution\fixtures", false, 4,
      directory => files.ContainsKey(directory), directory => files.TryGetValue(directory, out var list) ? list : []);

    foreach (var job in JobCatalog.All)
    {
      var plan = Expand(JobCatalog.Plan(job.Key, env));
      Check(plan.Count > 0 && plan.All(group => group.Steps.Count > 0), $"Načrt {job.Key} ni prazen.");
      var arguments = plan.SelectMany(group => group.Steps).Where(step => step.Process is not null).SelectMany(step => step.Process!.Arguments).ToList();
      Check(!arguments.Contains("--osvezi-validacijo"), $"{job.Key}: izvoz ne sme validirati (--osvezi-validacijo).");
      Check(!arguments.Contains("--po-urniku"), $"{job.Key}: posel ima en urnik — gostitelja; --po-urniku je dvojno razporejanje.");
    }

    var catalogExport = Expand(JobCatalog.Plan(JobCatalog.WebCatalogExport, env));
    Check(catalogExport.Count == 1 && catalogExport[0].Steps[0].Process!.Arguments.Contains("--export-magento")
      && catalogExport[0].Steps[0].OrganizationId == 2 && catalogExport[0].Steps[0].Process!.Arguments.Contains(@"C:\repo\PIM_Solution\workers\PIM.B2bWorker"),
      "Izvoz kataloga: en proces B2bWorker za podjetje 2, brez validacije.");
    Check(Expand(JobCatalog.Plan(JobCatalog.WebCatalogExport, env with { Organizations = [1, 3] }))[0].Steps[0].Kind == CycleStepKind.Note,
      "Izključeno podjetje kataloga je zapis, ne klic.");

    // 2026-09-22: urni zajem artiklov bere samo točke artiklov, eno podjetje na korak, brez vzporednih
    // zahtevkov in nikoli poln (poln je samo v nočni uskladitvi, tudi prvi dan v mesecu).
    var import = Expand(JobCatalog.Plan(JobCatalog.SaopProductImport, env with { IsFullCatalogDay = true }));
    var importArgs = import.Select(g => g.Steps.Single().Process!.Arguments).ToList();
    Check(import.Count == 4 && import.Select(g => g.Steps[0].OrganizationId).SequenceEqual([1, 2, 3, 4])
      && importArgs.All(a => !a.Contains("--full") && a.Contains(JobCatalog.ItemEndpoints) && !string.Join(",", a).Contains("GetPrices")
        && a.SkipWhile(x => x != "--max-parallel").Skip(1).First() == "1")
      && import.All(g => g.Steps[0].Environment!["PIM_SAOP_MODE"] == "Live")
      && !import.SelectMany(g => g.Steps).Any(s => s.Process!.Arguments.Any(a => a.Contains("SaopOrdersWorker"))),
      "Zajem artiklov: en korak na podjetje, samo točke artiklov, en zahtevek naenkrat, nikoli poln, v živo, brez naročil.");
    var nightlyCatalog = Expand(JobCatalog.Plan(JobCatalog.NightlyReconciliation, env with { IsFullCatalogDay = true }))[0].Steps[0].Process!.Arguments;
    Check(nightlyCatalog.Contains("--full") && nightlyCatalog.SkipWhile(x => x != "--max-parallel").Skip(1).First() == "1",
      "Poln zajem je samo nočni, tudi ta brez vzporednih zahtevkov.");

    var ordersPlan = Expand(JobCatalog.Plan(JobCatalog.SaopOrderImport, env));
    Check(ordersPlan.Count == 4 && ordersPlan.All(g => g.Steps[0].Process!.Arguments.Any(a => a.EndsWith("PIM.SaopOrdersWorker", StringComparison.Ordinal))
      && g.Steps[0].Environment!["PIM_SAOP_MODE"] == "Live"), "Naročila: SaopOrdersWorker, en korak na podjetje, v živo.");

    var prices = Expand(JobCatalog.Plan(JobCatalog.PriceImport, env));
    Check(prices.Count == 4 && prices.All(g => !g.RequiresAllPrevious && g.Steps.Single().Process!.Arguments.Contains("GetPrices"))
      && prices.Select(g => g.Steps[0].OrganizationId).SequenceEqual([1, 2, 3, 4]), "Cene: en korak na podjetje, padec enega ne blokira drugih.");

    // Pas SAOP: kateri posli kličejo SAOP in zato nikoli ne tečejo hkrati.
    Check(new[] { JobCatalog.SaopProductImport, JobCatalog.SaopOrderImport, JobCatalog.StockImport, JobCatalog.PriceImport, JobCatalog.SaopDeliveryImport,
        JobCatalog.NightlyReconciliation, JobCatalog.SaopOutboundDispatch }.All(JobCatalog.UsesSaop)
      && !new[] { JobCatalog.SupplierStockImport, JobCatalog.WebStockExport, JobCatalog.WebCatalogExport, JobCatalog.ProductValidation, JobCatalog.AlertEvaluation }.Any(JobCatalog.UsesSaop),
      "Pas SAOP zajema vse posle, ki kličejo SAOP, in nobenega drugega.");
    Check(JobCatalog.Find(JobCatalog.StockImport)!.IntervalSeconds == 600 && JobCatalog.Find(JobCatalog.PriceImport)!.IntervalSeconds == 600,
      "Zaloga in cene iz SAOP: vsakih 10 minut (od konca teka).");
    Check(!JobCatalog.Find(JobCatalog.SaopDeliveryImport)!.EnabledByDefault && !JobCatalog.Find(JobCatalog.SystemSelfTest)!.EnabledByDefault,
      "Datumi dobave (nočna uskladitev jih bere) in samotest (dotnet run) sta privzeto izklopljena.");
    Check(JobCatalog.Find(JobCatalog.NightlyReconciliation)!.DailyAtLocal == new TimeOnly(0, 30), "Nočna uskladitev ob 00:30, zunaj okna poletnega časa.");

    // Termin od konca in odlog po napakah.
    var end = new DateTime(2026, 9, 22, 10, 0, 0, DateTimeKind.Utc);
    Check(JobCatalog.NextAfterEnd(600, null, end, Zone, 0) == end.AddMinutes(10) && JobCatalog.NextAfterEnd(600, null, end, Zone, 1) == end.AddMinutes(10),
      "Brez napake in po prvi napaki: konec + razmik.");
    Check(JobCatalog.NextAfterEnd(600, null, end, Zone, 2) == end.AddMinutes(20) && JobCatalog.NextAfterEnd(600, null, end, Zone, 3) == end.AddMinutes(40),
      "Zaporedne napake podvojijo razmik.");
    Check(JobCatalog.NextAfterEnd(600, null, end, Zone, 30) == end.AddHours(4) && JobCatalog.NextAfterEnd(21600, null, end, Zone, 5) == end.AddHours(6),
      "Odlog največ 4 h, nikoli manj kot razmik.");
    Check(JobCatalog.NextAfterEnd(null, new TimeOnly(0, 30), end, Zone, 7) == WorkerCycles.NextDue(null, new TimeOnly(0, 30), end, Zone),
      "Dnevni posel ostane na dnevni uri ne glede na napake.");

    var validation = Expand(JobCatalog.Plan(JobCatalog.ProductValidation, env));
    Check(validation.Count == 4 && validation.All(g => g.Steps.Single() is { Kind: CycleStepKind.Sql } s && s.Sql!.Single().Contains("val.RunValidation", StringComparison.Ordinal))
      && validation.Select(g => g.Steps[0].OrganizationId).SequenceEqual([1, 2, 3, 4]),
      "Validacija: en SQL korak na podjetje, brez objave.");
    var promote = Expand(JobCatalog.Plan(JobCatalog.ProductPublication, env));
    Check(promote.Count == 4 && promote.All(g => g.Steps.Single().Sql!.Single().Contains("val.Promote", StringComparison.Ordinal) && !g.Steps[0].Sql![0].Contains("RunValidation", StringComparison.Ordinal)),
      "Objava: en SQL korak na podjetje, brez validacije.");

    var stock = Expand(JobCatalog.Plan(JobCatalog.StockImport, env));
    Check(stock.Count == 4 && stock.All(g => !g.RequiresAllPrevious && g.Steps.Single().Process!.Arguments.Any(a => a.EndsWith("PIM.SaopStockWorker", StringComparison.Ordinal)))
      && stock.Select(g => g.Steps[0].OrganizationId).SequenceEqual([1, 2, 3, 4]),
      "Zaloga iz SAOP: en korak na podjetje, padec enega ne blokira drugih: " + string.Join(" | ", stock.Select(g => g.Name)));

    var supplier = Expand(JobCatalog.Plan(JobCatalog.SupplierStockImport, env));
    Check(supplier.Select(g => g.Name).SequenceEqual(["Zaloga NW_STOCK", "Zaloga BT_STOCK"]),
      "Zaloga dobaviteljev: dve neodvisni skupini: " + string.Join(" | ", supplier.Select(g => g.Name)));
    Check(supplier[0].Steps.Count == 5 && supplier[0].Steps.Skip(1).Select(s => s.OrganizationId).SequenceEqual([1, 2, 3, 4]) && supplier[1].Steps[1].Kind == CycleStepKind.Note,
      "Prevzeta datoteka se prebere za vsako podjetje; vir brez datoteke je zapis.");
    Check(supplier.All(g => !g.RequiresAllPrevious) && !supplier.SelectMany(g => g.Steps).Any(s => s.Environment?.ContainsKey("PIM_SAOP_MODE") == true),
      "Padec enega vira zaloge ne blokira drugega; zaloga dobaviteljev ne kliče SAOP.");

    var stockExport = Expand(JobCatalog.Plan(JobCatalog.WebStockExport, env));
    Check(stockExport.Count == 4 && stockExport[2].Steps[0].Process!.Arguments.Contains(@"C:\repo\izvoz\magento\3") && stockExport[2].Steps[0].OrganizationId == 3,
      "Cene in zaloga: ena skupina na podjetje, vsaka v svojo mapo.");
    var rootedExport = Expand(JobCatalog.Plan(JobCatalog.WebStockExport, env with { ExportRoot = @"E:\izvoz" }));
    Check(rootedExport[2].Steps[0].Process!.Arguments.SkipWhile(a => a != "--output-dir").Skip(1).First() == @"E:\izvoz\3",
      "Z nastavljenim EXPORT_ROOT ima vsako podjetje svojo podmapo (prej so si datoteko prepisovala).");
    var stockExportJob = JobCatalog.Find(JobCatalog.WebStockExport)!;
    Check(stockExportJob.Dependencies.Single(d => d.DependsOnJobKey == JobCatalog.StockImport).TriggersDependent
      && !stockExportJob.Dependencies.Single(d => d.DependsOnJobKey == JobCatalog.PriceImport).TriggersDependent,
      "Izvoz cen in zaloge sproži samo zaloga iz SAOP; cene ga ne sprožijo (sicer bi izvoz tekel skoraj neprekinjeno).");

    var nightly = Expand(JobCatalog.Plan(JobCatalog.NightlyReconciliation, env));
    var nightlyNames = nightly.Select(g => g.Name).ToList();
    Check(nightlyNames.SequenceEqual(["SAOP katalog", "Prevzem dobaviteljevih datotek", "Dobaviteljev XML (Nowodvorski)", "Dobaviteljev XML (Braytron)",
        "Preslikava zaostanka v raw.Inbox", "Zaloge dobaviteljev", "Zaloga iz SAOP (kolicine)", "Zaloga iz SAOP (datumi prihoda)", "Validacija vseh podjetij", "Objava vseh podjetij"]),
      "Nočna uskladitev: vhodi v vrstnem redu skript, nato validacija in objava: " + string.Join(" | ", nightlyNames));
    Check(nightly[^1].RequiresAllPrevious && nightly[^2].RequiresAllPrevious && nightly.Take(8).All(g => !g.RequiresAllPrevious),
      "Validacija in objava v nočni uskladitvi zahtevata uspeh vseh vhodov; vhodi so neodvisni.");
    Check(!nightly.SelectMany(g => g.Steps).Any(s => s.Process?.Arguments.Contains("--export-magento") == true || s.Process?.Arguments.Any(a => a.Contains("StockReplenishmentWorker")) == true),
      "Nočna uskladitev ne izvaža in ne pošilja dnevnega maila; to sta svoja posla.");

    var selfTest = Expand(JobCatalog.Plan(JobCatalog.SystemSelfTest, env));
    Check(selfTest[0].Steps[0].Environment!["PIM_TRIGGERED_BY"] == "Task", "Samotest ima isto pogodbo kot prej.");

    // ─── Artefakti ───────────────────────────────────────────────────────────
    var artifacts = JobCatalog.ArtifactLocations(JobCatalog.WebCatalogExport, env);
    Check(artifacts.Select(a => a.FilePath).SequenceEqual([@"C:\repo\izvoz\magento\2\katalog.csv", @"C:\repo\izvoz\magento\2\stranke.csv"]),
      "Artefakta kataloga sta katalog.csv in stranke.csv v mapi podjetja 2.");
    Check(JobCatalog.ArtifactLocations(JobCatalog.WebCatalogExport, env with { ExportRoot = @"E:\izvoz" })[0].FilePath == @"E:\izvoz\katalog.csv",
      "Z registrom EXPORT_ROOT je artefakt v registrirani mapi.");
    Check(JobCatalog.ArtifactLocations(JobCatalog.WebStockExport, env).Count == 4 && JobCatalog.ArtifactLocations(JobCatalog.SaopOrderImport, env).Count == 0,
      "Cene in zaloga: en artefakt na podjetje; naročila nimajo datoteke.");
    Check(JobCatalog.ArtifactLocations(JobCatalog.WebStockExport, env with { ExportRoot = @"E:\izvoz" })[1].FilePath == @"E:\izvoz\2\magento-stock-prices.csv",
      "Artefakt cen in zaloge je v podmapi podjetja, kamor ga je worker zapisal.");

    // ─── Termini ─────────────────────────────────────────────────────────────
    var noon = new DateTime(2026, 9, 21, 10, 0, 0, DateTimeKind.Utc);
    Check(JobCatalog.FormatSchedule(300, null) == "vsakih 5 min" && JobCatalog.FormatSchedule(3600, null) == "vsakih 1 h" && JobCatalog.FormatSchedule(null, new TimeOnly(2, 30)) == "vsak dan ob 02:30",
      "Opis urnika je človeku berljiv.");
    var row = Row(JobCatalog.StockImport, JobFlows.Stock, false, true, 300, null);
    Check(JobCatalog.InitialDue(row, 2, noon, Zone) == noon.AddSeconds(150) && JobCatalog.InitialDue(row with { IntervalSeconds = null, DailyAtLocal = new TimeOnly(2, 30) }, 0, noon, Zone) == new DateTime(2026, 9, 22, 0, 30, 0, DateTimeKind.Utc),
      "Prvi termini so razmaknjeni; dnevni čaka na svojo uro.");

    // ─── Poslovne kartice ────────────────────────────────────────────────────
    var now = noon;
    var host = new AutomationHostRow("SRV:1:AutomationHost:service", "SRV", 1, "AutomationHost:service", now, now, now.AddSeconds(90), 10, false, 10, now, true, 0, 0, 0, 0, 0, 15, 0, 0);
    var okJobs = JobCatalog.All.Select(job => Row(job.Key, job.Flow, job.IsFlowResult, true, job.IntervalSeconds, job.DailyAtLocal,
      lastStatus: JobRunStatus.Succeeded, lastSucceeded: now.AddMinutes(-10), sla: job.SlaSeconds)).ToList();
    var deps = JobCatalog.All.SelectMany(job => job.Dependencies.Select(d => new JobDependencyRow(job.Key, d.DependsOnJobKey, d.IsGate, d.MaxAgeSeconds, d.TriggersDependent, d.Note))).ToList();
    var cards = AutomationOverview.Build(okJobs, deps, [], host, now);
    Check(cards.Count == 4 && cards.Select(c => c.Flow).SequenceEqual(JobFlows.Cards) && cards.All(c => c.State == FlowState.Ok && c.Cause is null),
      "Štiri kartice v vrstnem redu tokov; vse zelene, ko so rezultati sveži.");

    var blocked = okJobs.Select(job => job.JobKey switch
    {
      JobCatalog.ProductValidation => job with { LastStatus = JobRunStatus.TimedOut, LastError = "Presežena časovna meja 3600 s pri skupini 'Validacija (podjetje 4)'." },
      JobCatalog.ProductPublication => job with { LastStatus = JobRunStatus.Blocked, LastBlockedByJobKey = JobCatalog.ProductValidation, LastError = "Blokirano: Validacija artiklov se je nazadnje končala s stanjem TimedOut." },
      JobCatalog.WebCatalogExport => job with { LastStatus = JobRunStatus.Blocked, LastBlockedByJobKey = JobCatalog.ProductPublication, LastError = "Blokirano: Objava v PIM se je nazadnje končala s stanjem Blocked." },
      _ => job,
    }).ToList();
    var artifact = new ArtifactRow(1842, JobCatalog.WebCatalogExport, 7, 2, "MAGENTO_PRODUCTS", @"E:\izvoz\katalog.csv", "katalog.csv", 2_100_000, 2176, new string('a', 64), now.AddHours(-2), now.AddHours(-2));
    var web = AutomationOverview.Build(blocked, deps, [artifact], host, now).Single(c => c.Flow == JobFlows.WebCatalog);
    Check(web.State == FlowState.Blocked && web.ActionJobKey == JobCatalog.ProductValidation && web.Cause!.Contains("podjetje 4", StringComparison.Ordinal)
      && web.Consequence!.Contains("#1842", StringComparison.Ordinal) && web.VersionLabel!.Contains("2.176", StringComparison.Ordinal),
      $"Blokiran izvoz pove pravi vzrok po verigi (validacija podjetja 4), ukrep je ponovitev validacije, splet uporablja verzijo 1842: {web.Cause} / {web.ActionLabel}");
    Check(AutomationOverview.Build(blocked, deps, [artifact], host, now).Single(c => c.Flow == JobFlows.Orders).State == FlowState.Ok, "Naročila niso prizadeta s padcem kataloga.");

    var stale = okJobs.Select(job => job.JobKey == JobCatalog.WebStockExport ? job with { LastSucceededUtc = now.AddHours(-3) } : job).ToList();
    Check(AutomationOverview.Build(stale, deps, [], host, now).Single(c => c.Flow == JobFlows.Stock).State == FlowState.Stale, "Zadnji uspeh čez SLA je ZASTAREL.");

    var down = AutomationOverview.Build(okJobs, deps, [], host with { IsAutomationHostLive = false, HeartbeatUtc = now.AddMinutes(-25) }, now);
    Check(down.All(c => c.State == FlowState.HostDown && c.ActionJobKey is null && c.Cause!.Contains("ne utripa", StringComparison.Ordinal)),
      "Brez gostitelja so vse kartice GOSTITELJ NE TEČE, ukrep ni zagon.");

    var failed = okJobs.Select(job => job.JobKey == JobCatalog.SaopOrderImport ? job with { LastStatus = JobRunStatus.Failed, LastError = "SAOP 192.168.178.12:81 se ni odzval." } : job).ToList();
    var ordersCard = AutomationOverview.Build(failed, deps, [], host, now).Single(c => c.Flow == JobFlows.Orders);
    Check(ordersCard.State == FlowState.Failed && ordersCard.ActionJobKey == JobCatalog.SaopOrderImport && ordersCard.Cause!.Contains("192.168.178.12", StringComparison.Ordinal),
      "Padel rezultat toka: NAPAKA z vzrokom iz zadnje napake in ukrepom ponovitve.");

    Check(AutomationOverview.Build(okJobs.Select(j => j.JobKey == JobCatalog.WebCatalogExport ? j with { IsEnabled = false } : j).ToList(), deps, [], host, now)
      .Single(c => c.Flow == JobFlows.WebCatalog) is { State: FlowState.Off, ActionJobKey: null }, "Izklopljen rezultat toka je IZKLOPLJEN; ukrep je vklop, ne zagon.");

    Console.WriteLine("F10 job catalog logic PASS.");
  }

  static JobDefinitionRow Row(string key, string flow, bool isResult, bool enabled, int? interval, TimeOnly? daily,
    string? lastStatus = null, DateTime? lastSucceeded = null, int? sla = null) =>
    new(key, JobCatalog.Find(key)?.Label ?? key, "", flow, isResult, 0, "Internal", enabled, interval, daily, 600, sla, 2m,
      null, null, null, null, null, null, lastSucceeded, lastSucceeded, lastStatus, lastSucceeded, null, null, DateTime.UtcNow, "test",
      null, null, null, null, null, false, 0, null, null, null, null, null, null, null, null);

  static bool HasCycle()
  {
    var visiting = new HashSet<string>(StringComparer.Ordinal);
    var done = new HashSet<string>(StringComparer.Ordinal);
    bool Visit(string key)
    {
      if (done.Contains(key)) return false;
      if (!visiting.Add(key)) return true;
      foreach (var dependency in JobCatalog.Find(key)!.Dependencies)
        if (Visit(dependency.DependsOnJobKey)) return true;
      visiting.Remove(key);
      done.Add(key);
      return false;
    }
    return JobCatalog.All.Any(job => Visit(job.Key));
  }

  static IReadOnlyList<CycleGroup> Expand(IReadOnlyList<CycleGroup> groups) =>
    groups.Select(group => new CycleGroup(group.Name, group.Steps.SelectMany(step => step.Kind == CycleStepKind.Expand ? step.Expand!() : [step]).ToList(), group.RequiresAllPrevious)).ToList();

  static void Check(bool condition, string message)
  {
    if (condition) return;
    Console.Error.WriteLine("NAPAKA: " + message);
    Environment.Exit(1);
  }
}
