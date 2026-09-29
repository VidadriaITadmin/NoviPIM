using PIM.Automation;

/// <summary>
/// Razporejanje poslov in napoved zagona (naloga #12, 2026-09-29). Brez baze in brez procesa.
///
/// Kar ta test drži:
///   - pravila čakanja (predhodnik, pas SAOP s tišino, prednost ročne zahteve v pasu SAOP, en težak posel,
///     meja hkratnih poslov) so v ENI funkciji (JobQueue.Gate), ki jo uporabljata gostitelj in stran Nadzor;
///   - težak posel čaka na drugega največ JobQueue.HeavyMaxWaitSeconds, zato zadrževanje ne postane zamuda;
///   - nadzornik in alarmi gredo mimo meje hkratnih poslov (ročni zagon jih ne izrine);
///   - napoved (JobQueue.Forecast) pove oceno začetka za zasedenim pasom SAOP, za predhodnikom, ob meji in
///     brez zgodovine tekov (»ocene še ni«);
///   - Nadzor oddane zahteve in namenoma zadržanega posla ne obarva rdeče.
/// </summary>
static class JobQueueChecks
{
  static readonly DateTime Now = new(2026, 9, 29, 12, 0, 0, DateTimeKind.Utc);
  static readonly TimeZoneInfo Zone = TimeZoneInfo.Utc;

  static readonly IReadOnlyList<JobDependencyRow> Dependencies = JobCatalog.All
    .SelectMany(job => job.Dependencies.Select(d => new JobDependencyRow(job.Key, d.DependsOnJobKey, d.IsGate, d.MaxAgeSeconds, d.TriggersDependent, d.Note)))
    .ToList();

  public static void Run()
  {
    // ─── Uvrstitev poslov ────────────────────────────────────────────────────
    foreach (var heavy in new[] { JobCatalog.ProductValidation, JobCatalog.ProductPublication, JobCatalog.WebCatalogExport, JobCatalog.SaopDeliveryImport, JobCatalog.NightlyReconciliation })
      Check(JobCatalog.IsHeavy(heavy), $"{heavy} je težak posel.");
    foreach (var light in new[] { JobCatalog.StockImport, JobCatalog.PriceImport, JobCatalog.AlertEvaluation, JobCatalog.AlertDelivery })
      Check(!JobCatalog.IsHeavy(light), $"{light} ni težak posel.");
    Check(JobQueue.BypassesConcurrencyLimit(JobCatalog.AlertEvaluation) && JobQueue.BypassesConcurrencyLimit(JobCatalog.AlertDelivery)
      && !JobQueue.BypassesConcurrencyLimit(JobCatalog.ProductValidation), "Samo nadzornik in razpošiljanje alarmov gresta mimo meje hkratnih poslov.");
    var options = new AutomationOptions("test", Zone, ".");
    Check(options.MaxConcurrentJobs == JobQueue.MaxConcurrentJobs && JobQueue.MaxConcurrentJobs == 3 && options.TickSeconds == JobQueue.TickSeconds,
      "Gostitelj in napoved uporabljata isto mejo (3) in isti tik.");
    Check(!JobCatalog.IsHeavy(JobCatalog.SaopOutboundDispatch) && JobCatalog.Find(JobCatalog.SaopOutboundDispatch)!.EnabledByDefault == false,
      "Odhodna vrsta v SAOP ostane privzeto izklopljena.");

    // ─── Vrstni red: ročne zahteve najprej ─────────────────────────────────
    var all = JobCatalog.All.Select(job => Job(job.Key)).ToList();
    var withRequest = all.Select(job => job.JobKey == JobCatalog.NightlyReconciliation ? Requested(job) : job).ToList();
    Check(JobQueue.Order(withRequest)[0].JobKey == JobCatalog.NightlyReconciliation, "Ročna zahteva je v tiku pregledana prva.");
    Check(JobQueue.Order(all).Select(job => job.JobKey).SequenceEqual(all.Select(job => job.JobKey)), "Brez zahtev ostane vrstni red iz baze.");

    // ─── Vrata ──────────────────────────────────────────────────────────────
    JobGate Gate(string key, string[] running, DateTime? lastSaopEnd = null, string? saopRequest = null, bool requested = false, DateTime? since = null) =>
      JobQueue.Gate(key, requested, since ?? Now, all, Dependencies, new QueueSnapshot(running, lastSaopEnd, saopRequest, JobQueue.MaxConcurrentJobs), Now);

    Check(Gate(JobCatalog.ProductPublication, [JobCatalog.ProductValidation]) is { Kind: JobWaitKind.Predecessor, BlockingJobKey: JobCatalog.ProductValidation },
      "Objava čaka, dokler teče validacija (predhodnik).");
    Check(Gate(JobCatalog.WebCatalogExport, [JobCatalog.ProductValidation]).Kind == JobWaitKind.Predecessor,
      "Izvoz kataloga čaka validacijo po celi verigi (validacija → objava → izvoz).");
    Check(Gate(JobCatalog.SaopProductImport, [JobCatalog.PriceImport]) is { Kind: JobWaitKind.SaopBusy, BlockingJobKey: JobCatalog.PriceImport },
      "Artikli iz SAOP čakajo, dokler SAOP uporabljajo cene.");
    var quiet = Gate(JobCatalog.StockImport, [], lastSaopEnd: Now.AddSeconds(-60));
    Check(quiet.Kind == JobWaitKind.SaopQuiet && quiet.UntilUtc == Now.AddSeconds(60), "Po koncu posla SAOP velja tišina 120 s: " + quiet);
    Check(Gate(JobCatalog.StockImport, [], lastSaopEnd: Now.AddSeconds(-121)).CanStart, "Po tišini posel SAOP začne.");
    Check(Gate(JobCatalog.StockImport, [], saopRequest: JobCatalog.NightlyReconciliation) is { Kind: JobWaitKind.SaopYields, BlockingJobKey: JobCatalog.NightlyReconciliation },
      "Redni posel SAOP prepusti pas ročni zahtevi.");
    Check(Gate(JobCatalog.NightlyReconciliation, [], saopRequest: JobCatalog.NightlyReconciliation, requested: true).CanStart,
      "Ročna zahteva sama sebi pasu ne prepusti.");
    Check(Gate(JobCatalog.SupplierStockImport, [JobCatalog.PriceImport]).CanStart, "Posel, ki ne kliče SAOP, ne čaka pasu SAOP.");

    Check(Gate(JobCatalog.WebStockExport, [JobCatalog.ProductValidation]) is { Kind: JobWaitKind.HeavyBusy, BlockingJobKey: JobCatalog.ProductValidation },
      "Dva težka posla ne tečeta hkrati.");
    Check(Gate(JobCatalog.WebStockExport, [JobCatalog.ProductValidation], since: Now.AddSeconds(-JobQueue.HeavyMaxWaitSeconds - 1)).CanStart,
      "Težak posel čaka na drugega največ 15 min, potem gre (sicer bi zadrževanje postalo zamuda).");
    Check(Gate(JobCatalog.ProductValidation, [JobCatalog.StockImport]).CanStart, "Lahek posel težkega ne zadrži.");

    var three = new[] { JobCatalog.StockImport, JobCatalog.SupplierStockImport, JobCatalog.SupplierCatalogImport };
    Check(Gate(JobCatalog.ProductValidation, three).Kind == JobWaitKind.ConcurrencyLimit, "Ob treh tekočih poslih četrti čaka (meja).");
    Check(Gate(JobCatalog.AlertEvaluation, three).CanStart, "Nadzornik gre mimo meje hkratnih poslov.");
    Check(Gate(JobCatalog.ProductValidation, [JobCatalog.StockImport, JobCatalog.SupplierStockImport, JobCatalog.AlertEvaluation]).CanStart,
      "Nadzornik ne zaseda mesta pod mejo.");

    // ─── Napoved: zagon za zasedenim pasom SAOP (scenarij iz naloge) ─────────
    var stats = new Dictionary<string, JobDurationStats>
    {
      [JobCatalog.PriceImport] = new(JobCatalog.PriceImport, 20, 71, 120),
      [JobCatalog.SaopProductImport] = new(JobCatalog.SaopProductImport, 12, 59, 90),
      [JobCatalog.ProductValidation] = new(JobCatalog.ProductValidation, 10, 93, 150),
    };
    var price = Running(Job(JobCatalog.PriceImport), Now.AddSeconds(-30));
    var product = Requested(Job(JobCatalog.SaopProductImport));
    var scene = Quiet(all).Select(job => job.JobKey == price.JobKey ? price : job.JobKey == product.JobKey ? product : job).ToList();
    var forecast = JobQueue.Forecast(scene, Dependencies, stats, hostLive: true, Now, Zone);
    var f = forecast[JobCatalog.SaopProductImport];
    var priceEnd = Now.AddSeconds(41);
    Check(f is { Kind: JobWaitKind.SaopBusy, BlockingJobKey: JobCatalog.PriceImport, IsQueued: true, HasEstimate: true, EstimatedSeconds: 59 },
      "Zahtevan zajem artiklov čaka na cene v pasu SAOP: " + f);
    Check(f.BlockingEndUtc == priceEnd, $"Konec cen je začetek + povprečje (71 s): {f.BlockingEndUtc:HH:mm:ss}.");
    Check(f.EstimatedStartUtc is { } start && start >= priceEnd.AddSeconds(JobCatalog.SaopQuietSeconds) && start <= priceEnd.AddSeconds(JobCatalog.SaopQuietSeconds + JobQueue.TickSeconds),
      $"Ocena začetka je konec cen + 2 min tišine (na tik natančno): {f.EstimatedStartUtc:HH:mm:ss}.");
    Check(f.NextRegularUtc == f.EstimatedEndUtc!.Value.AddSeconds(3600), "Naslednji redni zagon šteje od ocene konca ročnega teka + razmik.");
    Check(forecast[JobCatalog.PriceImport] is { Kind: JobWaitKind.Running, EstimatedEndUtc: var end } && end == priceEnd, "Tekoči posel ima oceno konca.");
    var text = Explain(f);
    foreach (var part in new[] { "Cene iz SAOP", "tišine SAOP", "Ocena začetka", "trajanje ~59 s", "naslednji redni zagon" })
      Check(text.Contains(part, StringComparison.Ordinal), $"Napoved mora povedati »{part}«: {text}");

    // Validacija sledi uspehu zajema (sprožilec) — ocena začetka je po koncu zajema artiklov.
    var validation = forecast[JobCatalog.ProductValidation];
    Check(validation.EstimatedStartUtc is { } vs && vs >= f.EstimatedEndUtc && vs <= f.EstimatedEndUtc!.Value.AddSeconds(JobQueue.TickSeconds),
      $"Uspeh zajema artiklov sproži validacijo takoj po koncu: {validation.EstimatedStartUtc:HH:mm:ss} (konec zajema {f.EstimatedEndUtc:HH:mm:ss}).");

    // ─── Napoved za predhodnikom ────────────────────────────────────────────
    var behind = Quiet(all).Select(job =>
      job.JobKey == JobCatalog.ProductValidation ? Running(job, Now.AddSeconds(-13))
      : job.JobKey == JobCatalog.ProductPublication ? Requested(job) : job).ToList();
    var pub = JobQueue.Forecast(behind, Dependencies, stats, true, Now, Zone)[JobCatalog.ProductPublication];
    Check(pub is { Kind: JobWaitKind.Predecessor, BlockingJobKey: JobCatalog.ProductValidation } && pub.BlockingEndUtc == Now.AddSeconds(80)
      && pub.EstimatedStartUtc is { } ps && ps >= Now.AddSeconds(80) && ps <= Now.AddSeconds(80 + JobQueue.TickSeconds),
      $"Objava začne za validacijo (konec čez 80 s): {pub}");
    Check(!pub.HasEstimate && Explain(pub).Contains("ocene še ni", StringComparison.Ordinal), "Posel brez zgodovine tekov: »ocene še ni«: " + Explain(pub));

    // ─── Napoved ob meji hkratnih poslov ────────────────────────────────────
    var busy = Quiet(all).Select(job =>
      job.JobKey == JobCatalog.StockImport ? Running(job, Now.AddSeconds(-10))
      : job.JobKey == JobCatalog.SupplierStockImport ? Running(job, Now.AddSeconds(-10))
      : job.JobKey == JobCatalog.SupplierCatalogImport ? Running(job, Now.AddSeconds(-10))
      : job.JobKey == JobCatalog.ProductValidation ? Requested(job) : job).ToList();
    var limited = JobQueue.Forecast(busy, Dependencies, new Dictionary<string, JobDurationStats>(), true, Now, Zone)[JobCatalog.ProductValidation];
    Check(limited.Kind == JobWaitKind.ConcurrencyLimit && limited.IsHeldByScheduler && limited.EstimatedStartUtc is { } ls && ls > Now,
      "Ob meji hkratnih poslov je validacija v vrsti z oceno začetka po koncu enega od treh: " + limited);

    // ─── Brez gostitelja in brez zgodovine ──────────────────────────────────
    var down = JobQueue.Forecast([Requested(Job(JobCatalog.ProductValidation))], [], new Dictionary<string, JobDurationStats>(), false, Now, Zone)[JobCatalog.ProductValidation];
    Check(down.Kind == JobWaitKind.HostDown && down.EstimatedStartUtc is null && Explain(down).Contains("Gostitelj", StringComparison.Ordinal),
      "Brez gostitelja napoved ne obljublja začetka.");
    Check(JobQueue.EstimateOf(new(JobCatalog.PriceImport, 2, 71, 80)) == (JobQueue.FallbackSeconds, false), "Dva teka nista ocena.");
    Check(JobQueue.EstimateOf(new(JobCatalog.PriceImport, 3, 71, 80)) == (71, true), "Trije teki so ocena.");
    var idle = JobQueue.Forecast([Job(JobCatalog.StockImport)], [], stats, true, Now, Zone)[JobCatalog.StockImport];
    Check(idle.Kind == JobWaitKind.NotDue && idle.NextRegularUtc == Now.AddMinutes(5) && Explain(idle).StartsWith("Naslednji redni zagon ob", StringComparison.Ordinal),
      "Posel brez zahteve pove naslednji redni zagon: " + Explain(idle));

    // ─── Po izpadu gostitelja: več SAOP poslov naenkrat na vrsti ───────────
    // Vsi posli SAOP so zapadli (gostitelj je bil dol); »zdaj« je prost samo prvi, drugi so v vrsti za njim
    // z razlogom iz simulacije (preverjalec #12: »zdaj« na /sistem, v »Vrsti poslov« pa ocena 19:27).
    var saopKeys = JobCatalog.All.Where(job => JobCatalog.UsesSaop(job.Key)).Select(job => job.Key).ToHashSet();
    var restart = Quiet(all).Select(job => saopKeys.Contains(job.JobKey) ? job with { NextDueUtc = Now.AddMinutes(-20) } : job).ToList();
    var after = JobQueue.Forecast(restart, Dependencies, stats, true, Now, Zone);
    var saopForecasts = restart.Where(job => job.IsEnabled && saopKeys.Contains(job.JobKey)).Select(job => after[job.JobKey]).ToList();
    Check(saopForecasts.Count >= 2, "Scenarij potrebuje vsaj dva vklopljena posla SAOP.");
    Check(saopForecasts.Count(f2 => f2.Kind == JobWaitKind.Ready) == 1, "Po izpadu je »zdaj« na vrsti samo en posel SAOP: "
      + string.Join("; ", saopForecasts.Select(f2 => $"{f2.JobKey}={f2.Kind}")));
    foreach (var waiting in saopForecasts.Where(f2 => f2.Kind != JobWaitKind.Ready))
    {
      Check(waiting.IsHeldByScheduler && waiting.EstimatedStartUtc is { } ws && ws > Now.AddSeconds(JobQueue.TickSeconds),
        $"Posel SAOP za prvim je v vrsti z oceno začetka: {waiting}");
      var label = JobQueue.ShortLabel(waiting, utc => utc.ToString("HH:mm"));
      Check(label.StartsWith("v vrsti · ~", StringComparison.Ordinal), $"Stolpec »Naslednji« pove »v vrsti · ~HH:MM«, ne »zdaj«: {label}");
      Check(!Explain(waiting).Contains("naslednjem tiku", StringComparison.Ordinal), "Razlog je iz simulacije: " + Explain(waiting));
    }

    // ─── Ko nič ne teče, noben razlog ne trdi »teče« (preverjalec #12) ──────
    // Gostitelj z --samo-nadzor: vsi posli zapadli, nobeden ne teče. Razlogi pridejo iz simulacije, zato
    // morajo reči »v vrsti za X (na vrsti ob ~HH:MM, traja ~44 s)«, ne »X, ki ravno teče«.
    var stalled = all.Select(job => job with { LastEndedUtc = Now.AddHours(-1), NextDueUtc = Now.AddMinutes(-20) }).ToList();
    var idleForecast = JobQueue.Forecast(stalled, Dependencies, stats, true, Now, Zone);
    Check(idleForecast.Values.All(f2 => f2.Kind != JobWaitKind.Running), "Scenarij: nič ne teče.");
    var heldIdle = idleForecast.Values.Where(f2 => f2.IsHeldByScheduler).ToList();
    Check(heldIdle.Count(f2 => f2.BlockingJobKey is not null) >= 2, "Scenarij potrebuje vsaj dva posla, zadržana za drugim: "
      + string.Join("; ", idleForecast.Values.Select(f2 => $"{f2.JobKey}={f2.Kind}")));
    foreach (var f2 in idleForecast.Values)
    {
      var why = Explain(f2);
      var chip = JobQueue.HeldLabel(f2, key => JobCatalog.Find(key)?.Label ?? key);
      Check(!why.Contains("teče", StringComparison.OrdinalIgnoreCase) && !chip.Contains("teče", StringComparison.OrdinalIgnoreCase),
        $"Ko nič ne teče, razlog ne sme reči »teče« ({f2.JobKey}, {f2.Kind}): {why} | {chip}");
      Check(!why.Contains(", ki", StringComparison.Ordinal) || why.IndexOf(", ki", StringComparison.Ordinal) == why.LastIndexOf(", ki", StringComparison.Ordinal),
        "Največ en odvisni stavek z »ki«: " + why);
      if (f2.IsHeldByScheduler && f2.BlockingJobKey is not null && f2.Kind != JobWaitKind.SaopYields)
      {
        Check(!f2.BlockingIsRunning && f2.BlockingStartUtc is not null && why.Contains("na vrsti ob ~", StringComparison.Ordinal),
          $"Zadržan za poslom, ki še ne teče: pove, kdaj je ta na vrsti: {why}");
        Check(chip.StartsWith("v vrsti za ", StringComparison.Ordinal), "Čip pove »v vrsti za X«: " + chip);
      }
    }
    // Ko posel pred njim res teče, besedilo to pove — in brez dveh »ki« zapored (preverjalec #12, NIZKA).
    Check(f.BlockingIsRunning && JobQueue.HeldLabel(f, key => JobCatalog.Find(key)?.Label ?? key) == "čaka SAOP (teče Cene iz SAOP)",
      "Ko cene res tečejo, čip pove »teče«.");
    Check(text.Split(", ki").Length <= 2, "Brez dveh odvisnih stavkov z »ki« zapored: " + text);

    // ─── Izklopljen posel brez gostitelja ───────────────────────────────────
    var offDown = JobQueue.Forecast([Job(JobCatalog.StockImport) with { IsEnabled = false }], [], stats, false, Now, Zone)[JobCatalog.StockImport];
    Check(offDown.Kind == JobWaitKind.Disabled && JobQueue.ShortLabel(offDown, utc => utc.ToString("HH:mm")) == "—",
      "Izklopljen posel ima »—« tudi, ko gostitelj ne teče: " + offDown);

    // ─── Nadzor: v vrsti ni rdeče ───────────────────────────────────────────
    var failedRequested = Requested(Job(JobCatalog.ProductValidation)) with { LastStatus = JobRunStatus.Failed, LastError = "padlo" };
    var verdict = MonitorPolicy.Evaluate(failedRequested, [], [], [], true, Now, null, null, "Na vrsti takoj.");
    Check(verdict is { Tone: MonitorTone.Idle, Label: "V vrsti", Reason: "Na vrsti takoj." }, "Oddana zahteva je »V vrsti« (siva), tudi po padlem teku: " + verdict);
    var overdue = Job(JobCatalog.ProductValidation) with { NextDueUtc = Now.AddHours(-3) };
    var held = new JobForecast(overdue.JobKey, JobWaitKind.HeavyBusy, JobCatalog.NightlyReconciliation, null, null, null, 93, true, null, null, false, null);
    var heldVerdict = MonitorPolicy.Evaluate(overdue, [], [], [], true, Now, null, held, "Teče težak posel.");
    Check(heldVerdict is { Tone: MonitorTone.Idle, Label: "Čaka v vrsti" }, "Namenoma zadržan posel ni »Zamuja«: " + heldVerdict);
    Check(MonitorPolicy.Evaluate(overdue, [], [], [], true, Now) is { Tone: MonitorTone.Bad, Label: "Zamuja" }, "Brez napovedi zamuda ostane rdeča.");
    Console.WriteLine("F10 razporejanje poslov in napoved zagona PASS.");
  }

  static string Explain(JobForecast forecast) =>
    JobQueue.Explain(forecast, key => JobCatalog.Find(key)?.Label ?? key, utc => utc.ToString("HH:mm:ss"), Now);

  /// <summary>Vsi posli brez zadnjega konca SAOP (da tišina ne vpliva) in s terminom čez uro.</summary>
  static IEnumerable<JobDefinitionRow> Quiet(IEnumerable<JobDefinitionRow> jobs) =>
    jobs.Select(job => job with { LastEndedUtc = Now.AddHours(-1), NextDueUtc = Now.AddHours(1) });

  static JobDefinitionRow Requested(JobDefinitionRow job) => job with { RequestedRunUtc = Now, RequestedBy = "test" };

  static JobDefinitionRow Running(JobDefinitionRow job, DateTime since) => job with { RunningJobRunId = 7, RunningSinceUtc = since, LastStartedUtc = since };

  /// <summary>Zdrav vklopljen posel iz kataloga kode: uspel pred 9 min, naslednji termin čez 5 min.</summary>
  static JobDefinitionRow Job(string key)
  {
    var code = JobCatalog.Find(key)!;
    return new(
      key, code.Label, code.Description, code.Flow, code.IsFlowResult, code.SortOrder, code.ReachCode, true,
      code.IntervalSeconds, code.DailyAtLocal, code.TimeoutSeconds, code.SlaSeconds, 2m,
      Now.AddMinutes(5), null, null, null,
      null, 100, Now.AddMinutes(-10), Now.AddMinutes(-9), JobRunStatus.Succeeded,
      Now.AddMinutes(-9), 100, null, Now, "test",
      null, null, null, null, null, false,
      0, "Vsi koraki uspeli.", 3, 0, 0, "Schedule",
      null, "SRV", 60_000);
  }

  static void Check(bool condition, string message)
  {
    if (condition) return;
    Console.Error.WriteLine("NAPAKA: " + message);
    Environment.Exit(1);
  }
}
