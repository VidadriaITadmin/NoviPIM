using PIM.Automation;

/// <summary>
/// Model stanja posla za stran Nadzor (blok 5 prenove nadzora, 2026-09-22). Brez baze in brez procesa.
///
/// Kar ta test drži (odločitev Davida 2026-09-22):
///   - tri barve in nič drugega: zelena = sveži podatki, siva = izklopljeno ali brez dela, rdeča = napaka
///     ali prestari podatki; rumene NI;
///   - »preskočeno ni uspeh«: posel, ki je po izhodni kodi uspel, a so njegovi podatki prestari, je rdeč
///     (Braytron 17.–22. 9. 2026: vsi koraki zeleni, podatki stari pet dni);
///   - vsaka rdeča ima EN korak, ki težavo reši; pravila veljajo po vrsti (prvo, ki velja).
/// </summary>
static class MonitorPolicyChecks
{
  static readonly DateTime Now = new(2026, 9, 22, 18, 0, 0, DateTimeKind.Utc);
  static readonly List<MonitorVerdict> Seen = [];

  public static void Run()
  {
    // ─── Tri barve, nikoli rumena ─────────────────────────────────────────────
    Check(Enum.GetNames<MonitorTone>().SequenceEqual(["Good", "Idle", "Bad"]),
      "MonitorTone ima natanko Good, Idle, Bad: " + string.Join(", ", Enum.GetNames<MonitorTone>()));
    Check(!Enum.GetNames<MonitorTone>().Any(name => name.Contains("Warn", StringComparison.OrdinalIgnoreCase) || name.Contains("Yellow", StringComparison.OrdinalIgnoreCase)),
      "Stanja »opozorilo« ali »rumeno« ni: uporabnik je zavrnil barve, ki ne povedo, kaj narediti.");
    Check(MonitorPolicy.ToneCss(MonitorTone.Good) == "good" && MonitorPolicy.ToneCss(MonitorTone.Bad) == "bad" && MonitorPolicy.ToneCss(MonitorTone.Idle) is null,
      "Barve za PimChip: good, bad in nevtralno (null) za sivo.");
    Check(Enum.GetValues<MonitorTone>().All(tone => MonitorPolicy.ToneCss(tone) is null or "good" or "bad"), "ToneCss nikoli ne vrne »warn«.");

    // ─── Starost po človeško ────────────────────────────────────────────────
    Check(MonitorPolicy.AgeLabel(TimeSpan.FromSeconds(45)) == "45 s", "45 sekund: »45 s«.");
    Check(MonitorPolicy.AgeLabel(TimeSpan.FromMinutes(12)) == "12 min", "12 minut: »12 min«.");
    Check(MonitorPolicy.AgeLabel(new TimeSpan(3, 10, 0)) == "3 h 10 min", "3 ure 10 minut: »3 h 10 min«.");
    Check(MonitorPolicy.AgeLabel(TimeSpan.FromHours(3)) == "3 h", "Cele ure brez »0 min«.");
    Check(MonitorPolicy.AgeLabel(TimeSpan.FromDays(5)) == "5 dni", "Pet dni: »5 dni«.");
    Check(MonitorPolicy.AgeLabel(TimeSpan.FromHours(36)) == "1 dan 12 h", "Meja 36 h ne sme postati »1 dan«: " + MonitorPolicy.AgeLabel(TimeSpan.FromHours(36)));
    Check(MonitorPolicy.AgeLabel(TimeSpan.FromDays(2)) == "2 dneva", "Dva dni: »2 dneva«.");
    Check(MonitorPolicy.AgeLabel(TimeSpan.FromMinutes(-3)) == "0 s", "Ura strežnika pred bazo ne sme dati negativne starosti.");

    // ─── Pripadnost alarmov in podatkovni alarmi ────────────────────────────
    foreach (var kind in new[] { "ReservationExcluded", "ExportRejected", "WebShopWithdrawn", "StockSnapshotStale", "StockSnapshotEmpty" })
      Check(MonitorPolicy.IsDataAlert(kind), $"{kind} je podatkovni alarm (rešuje ga urednik) in ne sodi na Nadzor.");
    foreach (var kind in new[] { "PipelineOverdue", "JobFailed", "SourceStale", "AutomationHostDown", "OutboundDead" })
      Check(!MonitorPolicy.IsDataAlert(kind), $"{kind} je alarm delovanja in mora biti na Nadzoru.");

    var ownAlert = Alert("JobFailed", "Critical", MonitorPolicy.JobAlertPrefix + JobCatalog.StockImport);
    Check(MonitorPolicy.BelongsTo(ownAlert, JobCatalog.StockImport) && !MonitorPolicy.BelongsTo(ownAlert, JobCatalog.PriceImport),
      "Alarm OPRAVILO:<posel> pripada samo svojemu poslu.");
    var pipelineAlert = Alert("PipelineOverdue", "Critical", "SAOP_STOCK");
    Check(MonitorPolicy.BelongsTo(pipelineAlert, JobCatalog.StockImport) && MonitorPolicy.BelongsTo(pipelineAlert, JobCatalog.NightlyReconciliation)
      && !MonitorPolicy.BelongsTo(pipelineAlert, JobCatalog.PriceImport),
      "Alarm postopka pripada vsem poslom, ki postopek odpirajo (zaloga in nočna uskladitev), drugim ne.");
    Check(!JobCatalog.All.Any(job => MonitorPolicy.BelongsTo(Alert("AutomationHostDown", "Critical", "GOSTITELJ"), job.Key)),
      "Alarm gostitelja ne pripada nobenemu poslu (gre med druga obvestila).");
    Check(MonitorPolicy.PipelinesOf("NI_TAKEGA_POSLA").Count == 0, "Neznan posel nima postopkov.");

    // ─── 12. V redu ─────────────────────────────────────────────────────────
    var stock = Job(JobCatalog.StockImport);
    var fresh = Source(JobCatalog.StockImport, "SAOP_STOCK", "Zaloga iz SAOP", "Fresh", Now.AddMinutes(-10));
    var ok = Eval(stock, [fresh]);
    Check(ok is { Tone: MonitorTone.Good, Label: "V redu", Action: MonitorAction.None, ActionLabel: null },
      $"Svež vir in uspešen tek sta zelena: {ok}");
    Check(ok.Reason.Contains("Zadnji uspeh pred 9 min", StringComparison.Ordinal) && ok.Reason.Contains("podatki stari 10 min", StringComparison.Ordinal),
      "Zelena pove, kdaj je posel uspel in kako stari so podatki: " + ok.Reason);
    Check(ok.DataAge == TimeSpan.FromMinutes(10) && ok.DataAgeLabel == "10 min", "Starost podatkov je starost vira.");

    // ─── Starost podatkov: najstarejši vir, brez virov zadnji uspeh ─────────
    var older = Source(JobCatalog.StockImport, "SAOP_STOCK", "Zaloga iz SAOP", "Fresh", Now.AddMinutes(-25), organizationId: 3, organizationName: "Vidadria");
    var twoSources = Eval(stock, [fresh, older]);
    Check(twoSources.DataAge == TimeSpan.FromMinutes(25) && twoSources.DataAgeLabel == "25 min" && twoSources.Tone == MonitorTone.Good,
      $"Starost podatkov je starost NAJSTAREJŠEGA vira: {twoSources.DataAgeLabel}");
    var validation = Job(JobCatalog.ProductValidation);
    Check(Eval(validation, []).DataAge == TimeSpan.FromMinutes(9), "Posel brez virov meri starost od zadnjega uspeha.");
    var foreignSource = Eval(stock, [Source(JobCatalog.PriceImport, "GetPrices", "Cene iz SAOP", "Stale", Now.AddDays(-2), pipeline: "SAOP_PRICES")]);
    Check(foreignSource.Tone == MonitorTone.Good && foreignSource.DataAge == TimeSpan.FromMinutes(9),
      "Vir drugega posla ne vpliva na posel (Evaluate sme dobiti vse vire hkrati).");

    // ─── Vir brez faz (Unknown) posla ne obarva ─────────────────────────────
    var unknown = Eval(stock, [Source(JobCatalog.StockImport, "SAOP_STOCK", "Zaloga iz SAOP", "Unknown", null)]);
    Check(unknown.Tone == MonitorTone.Good && unknown.DataAge is null && unknown.DataAgeLabel == "—",
      $"Vir, ki še ni zapisal faze, ne obarva posla in nima izmišljene starosti: {unknown}");

    // ─── 1. Izklopljen: siv, tudi če je vse drugo narobe ────────────────────
    var disabled = Eval(stock with { IsEnabled = false, LastStatus = JobRunStatus.Failed, LastError = "SAOP ne odgovarja." },
      [Source(JobCatalog.StockImport, "SAOP_STOCK", "Zaloga iz SAOP", "Stale", Now.AddDays(-5))], hostLive: false);
    Check(disabled is { Tone: MonitorTone.Idle, Label: "Izklopljen", Action: MonitorAction.EnableJob } && disabled.ActionTarget == JobCatalog.StockImport
      && MonitorPolicy.ToneCss(disabled.Tone) is null,
      $"Izklopljen posel je SIV z vklopom, ne rdeč: {disabled}");
    var offByDefault = Eval(Job(JobCatalog.SaopOutboundDispatch) with { IsEnabled = false }, []);
    Check(offByDefault is { Tone: MonitorTone.Idle, Label: "Izklopljen", Action: MonitorAction.None }
      && offByDefault.Reason.StartsWith("Privzeto izklopljen", StringComparison.Ordinal),
      $"Privzeto izklopljen posel (piše v SAOP) Nadzor ne vabi k vklopu z enim klikom; razlog je opis posla: {offByDefault}");

    // ─── Barva koraka in teka po fazah: preskočeno ni uspeh ─────────────────
    PhaseTally Tally(params (string, bool)[] phases) => PhaseTally.Of(phases);
    Check(MonitorPolicy.SucceededByPhases(JobRunStatus.Succeeded, Tally(("Skipped", false), ("Skipped", false))) is ("Preskočeno", MonitorTone.Idle),
      "Korak z izhodno kodo 0, čigar vse faze so preskočile, je SIV »Preskočeno«, ne zelen.");
    Check(MonitorPolicy.SucceededByPhases(JobRunStatus.Succeeded, Tally(("Skipped", false), ("Succeeded", false))) is ("Brez novih podatkov", MonitorTone.Idle),
      "Korak brez novih podatkov je SIV.");
    Check(MonitorPolicy.SucceededByPhases(JobRunStatus.Succeeded, Tally(("Skipped", false), ("Succeeded", true))) is ("Uspešno", MonitorTone.Good),
      "Korak z vsaj eno fazo z novimi podatki je zelen.");
    Check(MonitorPolicy.SucceededByPhases(JobRunStatus.Succeeded, Tally(("Failed", false), ("Succeeded", true))) is { Tone: MonitorTone.Bad },
      "Faza z napako obarva uspešen korak rdeče.");
    Check(MonitorPolicy.SucceededByPhases(JobRunStatus.Succeeded, PhaseTally.Empty) is null
      && MonitorPolicy.SucceededByPhases(JobRunStatus.Failed, Tally(("Succeeded", true))) is null,
      "Brez faz ali pri neuspehu velja izhodna koda.");

    // ─── Faza IZRACUN validacije in objave nosi števila ─────────────────────
    var val = JobRunner.SqlPhaseResult("VALIDACIJA", "Validacija (podjetje 2)", new(100, 80, 20, 70), new(100, 80, 20, 70));
    Check(val is { ItemsIn: 100, ItemsOut: 80, ItemsRejected: 20, HasNewData: false } && val.Message.Contains("brez sprememb", StringComparison.Ordinal),
      $"Validacija brez sprememb nima novih podatkov (sivo), a nosi števila: {val}");
    Check(JobRunner.SqlPhaseResult("VALIDACIJA", "Validacija", new(100, 80, 20, 70), new(100, 82, 18, 70)).HasNewData,
      "Validacija, ki je spremenila število veljavnih, ima nove podatke.");
    var promoteNone = JobRunner.SqlPhaseResult("OBJAVA", "Objava", new(10, 0, 10, 0), new(10, 0, 10, 0));
    Check(promoteNone is { ItemsOut: 0, HasNewData: false }, $"Objava 0 artiklov ni zelena: {promoteNone}");
    var promoted = JobRunner.SqlPhaseResult("OBJAVA", "Objava", new(10, 5, 5, 3), new(10, 5, 5, 5));
    Check(promoted is { ItemsOut: 5, HasNewData: true } && promoted.Message.Contains("novih v PIM 2", StringComparison.Ordinal), $"Objava pove, koliko je objavila: {promoted}");

    // ─── 2. Gostitelj ne teče ───────────────────────────────────────────────
    var hostDown = Eval(stock with { LastStatus = JobRunStatus.Failed }, [fresh], hostLive: false);
    Check(hostDown is { Tone: MonitorTone.Bad, Label: "Gostitelj ne teče", Action: MonitorAction.CheckHost, ActionTarget: null },
      $"Brez gostitelja je vklopljen posel rdeč in ukrep je gostitelj, ne zagon: {hostDown}");

    // ─── 3. Zadnji tek padel ────────────────────────────────────────────────
    var failed = Eval(stock with { LastStatus = JobRunStatus.Failed, LastError = "SAOP 192.168.178.12:81 se ni odzval.", LastSummary = "1 od 3 korakov padel." }, [fresh]);
    Check(failed is { Tone: MonitorTone.Bad, Label: "Zadnji tek padel", Action: MonitorAction.RunNow, ActionLabel: "Poženi znova" }
      && failed.ActionTarget == JobCatalog.StockImport && failed.Reason == "SAOP 192.168.178.12:81 se ni odzval.",
      $"Padel tek: rdeče, razlog je zadnja napaka, ukrep ponovitev: {failed}");
    var summaryOnly = Eval(stock with { LastStatus = JobRunStatus.Failed, LastError = null, LastSummary = "1 od 3 korakov padel." }, [fresh]);
    Check(summaryOnly.Reason == "1 od 3 korakov padel.", "Brez zapisane napake je razlog povzetek teka: " + summaryOnly.Reason);
    var timedOut = Eval(stock with { LastStatus = JobRunStatus.TimedOut, LastError = "Presežena časovna meja 900 s." }, [fresh]);
    Check(timedOut is { Tone: MonitorTone.Bad, Label: "Zadnji tek presegel časovno mejo" }, $"Presežena meja ima svojo oznako: {timedOut.Label}");
    Check(Eval(stock with { LastStatus = JobRunStatus.Abandoned }, [fresh]) is { Tone: MonitorTone.Bad, Label: "Zadnji tek padel" },
      "Zapuščen tek (gostitelj se je ustavil med tekom) je padel tek.");
    var retrying = Eval(stock with { LastStatus = JobRunStatus.Failed, LastError = "napaka", RunningJobRunId = 501, RunningStep = "Zaloga iz SAOP (podjetje 2)" }, [fresh]);
    Check(retrying.Label != "Zadnji tek padel", "Med ponovnim tekom pravilo o padlem teku ne velja; izid pove nov tek: " + retrying.Label);
    Check(Eval(stock with { LastStatus = JobRunStatus.Failed },
        [Source(JobCatalog.StockImport, "SAOP_STOCK", "Zaloga iz SAOP", "Stale", Now.AddDays(-5))]).Label == "Zadnji tek padel",
      "Padel tek ima prednost pred starimi podatki (vzrok pred posledico).");

    // ─── 4. Blokiran ────────────────────────────────────────────────────────
    var publication = Job(JobCatalog.ProductPublication);
    var blocked = Eval(publication with
    {
      LastStatus = JobRunStatus.Blocked, LastBlockedByJobKey = JobCatalog.ProductValidation,
      LastError = "Blokirano: Validacija artiklov se je nazadnje končala s stanjem TimedOut.",
    }, []);
    Check(blocked is { Tone: MonitorTone.Bad, Label: "Blokiran", Action: MonitorAction.OpenJob } && blocked.ActionTarget == JobCatalog.ProductValidation
      && blocked.ActionLabel == "Odpri posel Validacija artiklov" && blocked.Reason.Contains("TimedOut", StringComparison.Ordinal),
      $"Blokiran posel pokaže predhodnika, ne ponovitve samega sebe: {blocked}");

    // ─── 5. Postopek izklopljen ─────────────────────────────────────────────
    var autoDisabled = Pipeline("SAOP_STOCK", 2, enabled: false, failures: 5, error: "SAOP GetStocks: 500 Internal Server Error");
    var pipelineOff = Eval(stock, [fresh], [autoDisabled, Pipeline("SAOP_STOCK", 3, enabled: true)]);
    Check(pipelineOff is { Tone: MonitorTone.Bad, Label: "Postopek izklopljen", Action: MonitorAction.EnablePipeline } && pipelineOff.ActionTarget == "SAOP_STOCK|2"
      && pipelineOff.ActionLabel == "Vklopi postopek SAOP_STOCK (IQLighting)"
      && pipelineOff.Reason.Contains("5 zaporednih napakah", StringComparison.Ordinal) && pipelineOff.Reason.Contains("500 Internal Server Error", StringComparison.Ordinal),
      $"Samodejno izklopljen postopek: rdeče, razlog zadnja napaka, ukrep vklop postopka za podjetje: {pipelineOff}");
    Check(Eval(stock, [fresh], [autoDisabled with { OrganizationInAutomation = false }]).Tone == MonitorTone.Good,
      "Izklopljen postopek podjetja, ki je izključeno iz avtomatike, ni izpad.");
    Check(Eval(stock, [fresh], [Pipeline("SAOP_PRICES", 2, enabled: false, failures: 5)]).Tone == MonitorTone.Good,
      "Izklopljen postopek drugega posla ne obarva tega posla.");
    var catalogExport = Job(JobCatalog.WebCatalogExport);
    var unusedRow = Pipeline("MAGENTO_PRODUCTS", 3, enabled: false, health: null) with { OrganizationName = "Vidadria" };
    Check(Eval(catalogExport, [], [Pipeline("MAGENTO_PRODUCTS", 2, enabled: true), unusedRow]).Tone == MonitorTone.Good,
      "Izklopljena vrstica postopka, ki za podjetje še nikoli ni tekla (MAGENTO_PRODUCTS za Vidadrio), ni izpad.");

    // ─── 6. Vir padel ───────────────────────────────────────────────────────
    var sourceFailed = Eval(stock, [Source(JobCatalog.StockImport, "SAOP_STOCK", "Zaloga iz SAOP", "Failed", Now.AddMinutes(-20), message: "SAOP ni vrnil zaloge (timeout).")]);
    Check(sourceFailed is { Tone: MonitorTone.Bad, Label: "Vir padel: Zaloga iz SAOP (IQLighting)", Action: MonitorAction.RunNow }
      && sourceFailed.Reason == "SAOP ni vrnil zaloge (timeout).",
      $"Padel vir je rdeč, čeprav je tek po izhodni kodi uspel: {sourceFailed}");

    // ─── 7. Prestari podatki: »preskočeno ni uspeh« ─────────────────────────
    var supplier = Job(JobCatalog.SupplierStockImport);
    var braytron = Source(JobCatalog.SupplierStockImport, "BT_STOCK", "Braytron zaloga", "Stale", Now.AddDays(-5),
      maxAgeSeconds: 21600, pipeline: "STOCK_FILE", message: "isti posnetek je že v bazi");
    var nowodvorski = Source(JobCatalog.SupplierStockImport, "NW_STOCK", "Nowodvorski zaloga", "Stale", Now.AddHours(-7),
      maxAgeSeconds: 14400, pipeline: "STOCK_FILE");
    var skippedIsNotSuccess = Eval(supplier, [nowodvorski, braytron]);
    Check(supplier.LastStatus == JobRunStatus.Succeeded && skippedIsNotSuccess.Tone == MonitorTone.Bad,
      "Posel je po izhodni kodi uspel, podatki pa so prestari: to je RDEČE, ne zeleno.");
    Check(skippedIsNotSuccess is { Label: "Podatki stari 5 dni", Action: MonitorAction.RunNow }
      && skippedIsNotSuccess.Reason.StartsWith("Braytron zaloga (IQLighting): zadnji novi podatki pred 5 dni, meja 6 h.", StringComparison.Ordinal)
      && skippedIsNotSuccess.Reason.Contains("isti posnetek je že v bazi", StringComparison.Ordinal),
      $"Pokaže se najstarejši vir z mejo in zadnjo fazo: {skippedIsNotSuccess.Label} / {skippedIsNotSuccess.Reason}");
    Check(skippedIsNotSuccess.DataAge == TimeSpan.FromDays(5) && skippedIsNotSuccess.DataAgeLabel == "5 dni", "Starost podatkov je starost najstarejšega vira.");
    var btSkipped = braytron with { LastStatus = "Skipped", LastContactUtc = Now.AddHours(-1), LastNewDataUtc = Now.AddDays(-5) };
    var ranIdle = Eval(supplier, [btSkipped with { LastMessage = "Razmik dobavitelja še teče" }]);
    Check(ranIdle is { Tone: MonitorTone.Bad, Label: "Podatki stari 5 dni", Action: MonitorAction.OpenJob } && ranIdle.ActionTarget == JobCatalog.SupplierStockImport
      && ranIdle.Reason.Contains("ponovni zagon ne pomaga", StringComparison.Ordinal) && ranIdle.Reason.Contains("Razmik dobavitelja", StringComparison.Ordinal),
      $"Posel teče, vir pa preskoči: rdeče, a korak je pogled v posel (vzrok faze), ne »Poženi zdaj«: {ranIdle}");
    var noBook = Source(JobCatalog.SaopOrderImport, "SAOP_ORDERS_VNK", "Naročila VNK", "Stale", null, pipeline: "SAOP_ORDERS", message: "podjetje nima knjige naročil")
      with { LastStatus = "Skipped", LastContactUtc = null, LastNewDataUtc = null };
    var structural = Eval(Job(JobCatalog.SaopOrderImport), [noBook]);
    Check(structural is { Tone: MonitorTone.Idle, Label: "Brez dela" } && structural.Reason.Contains("nima knjige", StringComparison.Ordinal),
      $"Vir, ki ga posel vedno samo preskoči (ni knjige), je SIV z razlogom, ne rdeč »Podatkov še ni«: {structural}");
    var contactOnly = Eval(Job(JobCatalog.PriceImport),
      [Source(JobCatalog.PriceImport, "GetPrices", "Cene iz SAOP", "Stale", Now.AddHours(-2), measureNewData: false, pipeline: "SAOP_PRICES")]);
    Check(contactOnly.Reason.Contains("zadnji uspešen stik pred 2 h", StringComparison.Ordinal),
      "Vir, ki se meri po stiku (cene), pove »zadnji uspešen stik«, ne »novi podatki«: " + contactOnly.Reason);

    // ─── 8. Zamuja ──────────────────────────────────────────────────────────
    var late = Eval(stock with { NextDueUtc = Now.AddMinutes(-30), IntervalSeconds = 600 }, [fresh]);
    Check(late is { Tone: MonitorTone.Bad, Label: "Zamuja", Action: MonitorAction.OpenLog } && late.Reason.Contains("pred 30 min", StringComparison.Ordinal),
      $"Termin je minil za več kot (2 − 1) × razmik: rdeče; gostitelj utripa, zato korak vodi v zadnji tek, ne h gostitelju: {late}");
    Check(Eval(stock with { NextDueUtc = Now.AddMinutes(-30), IntervalSeconds = 600, LastJobRunId = null }, [fresh]).Action == MonitorAction.RunNow,
      "Zamujen posel brez teka ponudi zagon.");
    Check(Eval(stock with { NextDueUtc = Now.AddMinutes(-5), IntervalSeconds = 600 }, [fresh]).Tone == MonitorTone.Good,
      "Zamuda znotraj dovoljene ni rdeča (gostitelj čaka na prosto mesto ali na tišino SAOP).");
    Check(Eval(stock with { NextDueUtc = Now.AddMinutes(-30), IntervalSeconds = 600, RunningJobRunId = 77 }, [fresh]).Label != "Zamuja",
      "Posel, ki teče, ne zamuja.");
    // Pot do SAOP je zasedena (teče drug posel, ki kliče SAOP): zaloga čaka, ni zamujena (2026-09-22, lažen »Zamuja«).
    var waiting = MonitorPolicy.Evaluate(stock with { NextDueUtc = Now.AddMinutes(-30), IntervalSeconds = 600 }, [fresh], [], [], true, Now, "Naročila iz SAOP");
    Seen.Add(waiting);
    Check(waiting is { Tone: MonitorTone.Idle, Label: "Čaka na SAOP" } && waiting.Reason.Contains("Naročila iz SAOP", StringComparison.Ordinal),
      $"Posel, ki čaka na prosto pot do SAOP, je siv z razlogom, ne rdeč: {waiting}");

    // ─── 9. Delno padlo ─────────────────────────────────────────────────────
    var partial = Eval(stock with { LastStatus = JobRunStatus.Warning, LastSummary = "Podjetje 3: SAOP ni odgovoril; podjetji 2 in 4 uspeli." }, [fresh]);
    Check(partial is { Tone: MonitorTone.Bad, Label: "Delno padlo", Action: MonitorAction.OpenLog } && partial.ActionTarget == JobCatalog.StockImport
      && partial.Reason.StartsWith("Podjetje 3", StringComparison.Ordinal),
      $"Delno padel tek je RDEČ (ni rumene) in vodi v izpis: {partial}");

    // ─── 10. Kritičen alarm posla ───────────────────────────────────────────
    var overdueAlert = Alert("PipelineOverdue", "Critical", "SAOP_STOCK",
      title: "Postopek SAOP_STOCK ni tekel 7213 min, zadnji utrip je star več kot pet dni in to je zelo dolg naslov alarma.",
      summary: "Podjetje: IQLighting. Zadnji utrip: 2026-09-17 18:54:25 UTC.");
    var alerted = Eval(stock, [fresh], alerts: [overdueAlert]);
    Check(alerted is { Tone: MonitorTone.Bad, Action: MonitorAction.RunNow } && alerted.Label.Length <= 60 && alerted.Label.StartsWith("Postopek SAOP_STOCK ni tekel", StringComparison.Ordinal)
      && alerted.Reason == "Podjetje: IQLighting. Zadnji utrip: 2026-09-17 18:54:25 UTC.",
      $"Kritičen alarm posla: rdeče, oznaka je skrajšan naslov, razlog povzetek: {alerted}");
    var withBeat = Eval(stock, [fresh], [Pipeline("SAOP_STOCK", 2, true) with { LastHeartbeatUtc = Now.AddDays(-5) }],
      [overdueAlert with { Summary = "Podjetje: IQLighting. Preveri posel in zadnje zagone na /sistem." }]);
    Check(withBeat.Label == "Postopek SAOP_STOCK ni tekel 5 dni" && !withBeat.Reason.Contains("/sistem", StringComparison.Ordinal),
      $"Zamuda postopka: starost po človeško (ne surove minute), brez napotka na /sistem, kjer uporabnik že je: {withBeat.Label} / {withBeat.Reason}");
    Check(Eval(stock, [fresh], alerts: [overdueAlert with { LastSeenUtc = Now.AddHours(-2) }]).Tone == MonitorTone.Good,
      "Zamuda postopka, ki je nadzornik ni potrdil po zadnjem teku posla (ostanek starega motorja), posla ne obarva.");
    Check(Eval(stock, [fresh], alerts: [overdueAlert with { Severity = "Warning" }]).Tone == MonitorTone.Good, "Alarm brez kritične resnosti posla ne obarva.");
    Check(Eval(Job(JobCatalog.SaopProductImport), [], alerts: [Alert("ReservationExcluded", "Critical", "SAOP_PRODUCTS")]).Tone == MonitorTone.Good,
      "Podatkovni alarm (izključena rezervacija) posla ne obarva, četudi je kritičen.");
    Check(Eval(stock, [fresh], alerts: [Alert("JobFailed", "Critical", MonitorPolicy.JobAlertPrefix + JobCatalog.PriceImport)]).Tone == MonitorTone.Good,
      "Alarm drugega posla ne obarva tega posla.");

    // ─── 11. Še ni teklo ────────────────────────────────────────────────────
    var nightly = Job(JobCatalog.NightlyReconciliation) with
    {
      LastStartedUtc = null, LastEndedUtc = null, LastStatus = null, LastSucceededUtc = null, LastJobRunId = null, LastSucceededJobRunId = null,
      NextDueUtc = Now.AddHours(4).AddMinutes(30),
    };
    var neverRan = Eval(nightly, []);
    Check(neverRan is { Tone: MonitorTone.Idle, Label: "Še ni teklo", Action: MonitorAction.RunNow } && neverRan.Reason.Contains("čez 4 h 30 min", StringComparison.Ordinal)
      && neverRan.DataAgeLabel == "—",
      $"Posel, ki še ni tekel, je SIV z naslednjim terminom: {neverRan}");
    var neverSucceeded = Eval(nightly with { LastStartedUtc = Now.AddMinutes(-3), LastStatus = JobRunStatus.Running, RunningJobRunId = 900 }, []);
    Check(neverSucceeded is { Tone: MonitorTone.Idle, Label: "Še ni uspelo" }, $"Prvi tek, ki še teče, ni zelen: {neverSucceeded}");

    // ─── Splošno: vsaka rdeča ima korak, zelena ga nima ─────────────────────
    foreach (var verdict in Seen)
    {
      if (verdict.Tone == MonitorTone.Bad)
        Check(verdict.Action != MonitorAction.None && verdict.ActionLabel is { Length: > 0 }, $"Rdeča brez koraka: {verdict}");
      if (verdict.Tone == MonitorTone.Good)
        Check(verdict.Action == MonitorAction.None, $"Zelena ne ponuja ukrepa: {verdict}");
      Check(verdict.Reason.Length > 0 && verdict.Label.Length > 0, $"Vsaka sodba ima oznako in razlog: {verdict}");
      Check(MonitorPolicy.ToneCss(verdict.Tone) is not "warn", "Nobena sodba ni rumena.");
    }

    Console.WriteLine("F10 model stanja posla (Nadzor) PASS.");
  }

  static MonitorVerdict Eval(
    JobDefinitionRow job, IReadOnlyList<SourceStateRow> sources, IReadOnlyList<PipelineHealthRow>? pipelines = null,
    IReadOnlyList<MonitorAlertRow>? alerts = null, bool hostLive = true)
  {
    var verdict = MonitorPolicy.Evaluate(job, sources, pipelines ?? [], alerts ?? [], hostLive, Now);
    Seen.Add(verdict);
    return verdict;
  }

  /// <summary>Zdrav posel iz kataloga kode: uspel pred 9 min (začel pred 10), naslednji termin čez 5 min.</summary>
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

  static SourceStateRow Source(
    string jobKey, string sourceCode, string label, string state, DateTime? basis,
    int maxAgeSeconds = 1800, bool measureNewData = true, string pipeline = "SAOP_STOCK", string? message = null,
    int? organizationId = 2, string? organizationName = "IQLighting") =>
    new(jobKey, pipeline, sourceCode, label, organizationId, organizationName, maxAgeSeconds, measureNewData,
      basis, measureNewData ? basis : null, state == "Failed" ? basis : null, basis,
      message, state == "Failed" ? "Failed" : "Succeeded", "ZAPIS", 100, 0, state);

  static PipelineHealthRow Pipeline(string pipeline, int organizationId, bool enabled, int failures = 0, string? error = null, string? health = "Healthy") =>
    new(pipeline, organizationId, "IQLighting", enabled, true, 1800, health,
      health is null ? null : Now.AddHours(-1), health is null ? null : Now.AddHours(-1), error, failures);

  static MonitorAlertRow Alert(string kind, string severity, string pipeline, string title = "Alarm", string? summary = null) =>
    new(1, kind, severity, pipeline, 2, "IQLighting", title, summary, Now.AddHours(-1), Now.AddMinutes(-1), null);

  static void Check(bool condition, string message)
  {
    if (condition) return;
    Console.Error.WriteLine("NAPAKA: " + message);
    Environment.Exit(1);
  }
}
