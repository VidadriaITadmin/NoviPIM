using PIM.Automation;
using PIM.Operations;

/// <summary>
/// Faze znotraj koraka (migracija 255, blok 2 prenove nadzora): šifrant faz, vrstica dnevnika in
/// vez med tekom posla ter workerjem. Brez baze in brez procesa.
///
/// Zakaj je to pogodba in ne podrobnost: ista vrstica gre v dnevnik in v ops.JobPhaseRun, stran
/// Nadzor pa iz nje bere, ali je faza prinesla nove podatke. Uporabnik 2026-09-22: »moram videti,
/// da se je XML prenesel, da se je dal prebrati in da so se podatki vnesli v tabele«. »Preskočeno«
/// zato nikoli ne sme izpasti kot »uspelo«.
/// </summary>
static class PhaseLogChecks
{
  public static void Run()
  {
    // ─── Šifrant faz ────────────────────────────────────────────────────────
    string[] kode =
    [
      PhaseCodes.Fetch, PhaseCodes.Read, PhaseCodes.Land, PhaseCodes.Match,
      PhaseCodes.Map, PhaseCodes.Watermark, PhaseCodes.File, PhaseCodes.Compute, PhaseCodes.Send,
    ];
    Check(kode.Distinct(StringComparer.Ordinal).Count() == kode.Length, "Šifre faz se ne smejo ponavljati.");
    Check(PhaseCodes.Order.Count == kode.Length && kode.All(PhaseCodes.Order.Contains),
      "Vrstni red faz mora vsebovati natanko vse šifre: " + string.Join(", ", PhaseCodes.Order));
    Check(PhaseCodes.Order.Distinct(StringComparer.Ordinal).Count() == PhaseCodes.Order.Count, "Vrstni red faz ne sme ponavljati šifre.");
    foreach (var koda in kode)
    {
      var oznaka = PhaseCodes.Label(koda);
      Check(oznaka.Length > 0 && oznaka != koda, $"Faza {koda} mora imeti slovensko oznako, dobil »{oznaka}«.");
    }
    Check(PhaseCodes.Label("NEKAJ_NOVEGA") == "NEKAJ_NOVEGA", "Neznana faza se pokaže s svojo šifro, ne prazna.");
    Check(PhaseCodes.Order[0] == PhaseCodes.Fetch && PhaseCodes.Order[^1] == PhaseCodes.Send,
      "Vrstni red faz gre od prenosa do pošiljanja.");

    // ─── Vrstica dnevnika: uspeh z novimi podatki ───────────────────────────
    var uspeh = PhaseLog.Describe(PhaseCodes.Read, "BT_STOCK", 2, PhaseOutcome.Succeeded, hasNewData: true,
      itemsIn: 1389, itemsOut: 1389, itemsRejected: 0, byteCount: null, message: null);
    Check(uspeh.StartsWith("[FAZA] ", StringComparison.Ordinal), "Vrstica faze se mora začeti z [FAZA]: " + uspeh);
    Check(uspeh.Contains("Branje") && uspeh.Contains("BT_STOCK") && uspeh.Contains("(podjetje 2)"),
      "Vrstica mora povedati fazo, vir in podjetje: " + uspeh);
    Check(uspeh.Contains("1.389"), "Števila morajo biti zapisana po slovensko (1.389): " + uspeh);
    Check(uspeh.Contains("uspelo") && !uspeh.Contains("brez novih podatkov"), "Uspeh z novimi podatki je »uspelo«: " + uspeh);
    Check(uspeh.EndsWith('.'), "Vrstica faze se konča s piko: " + uspeh);

    // ─── Uspeh brez novih podatkov ni isto kot uspeh ────────────────────────
    var brezNovega = PhaseLog.Describe(PhaseCodes.Land, "BT_STOCK", 2, PhaseOutcome.Succeeded, hasNewData: false,
      itemsIn: 1389, itemsOut: 0, itemsRejected: null, byteCount: null, message: "isti posnetek je že v bazi");
    Check(brezNovega.Contains("brez novih podatkov"), "Uspeh brez novih podatkov mora biti izrecen: " + brezNovega);
    Check(brezNovega.Contains("isti posnetek je že v bazi"), "Razlog mora ostati v vrstici: " + brezNovega);

    // ─── Preskočeno z razlogom ──────────────────────────────────────────────
    var preskoceno = PhaseLog.Describe(PhaseCodes.Fetch, "BT_STOCK", null, PhaseOutcome.Skipped, hasNewData: false,
      itemsIn: null, itemsOut: null, itemsRejected: null, byteCount: null,
      message: "dobavitelj dovoli prenos na 3 h, naslednji ob 19:44");
    Check(preskoceno.Contains("preskočeno"), "Preskok mora biti poimenovan preskok: " + preskoceno);
    Check(!preskoceno.Contains("uspelo"), "Preskok ne sme izpasti kot uspeh: " + preskoceno);
    Check(preskoceno.Contains("naslednji ob 19:44"), "Preskok mora nositi razlog: " + preskoceno);
    Check(!preskoceno.Contains("(podjetje"), "Brez podjetja vrstica ne sme izmišljati podjetja: " + preskoceno);

    // ─── Napaka ─────────────────────────────────────────────────────────────
    var napaka = PhaseLog.Describe(PhaseCodes.Map, "NW_XML", 3, PhaseOutcome.Failed, hasNewData: false,
      itemsIn: 120, itemsOut: null, itemsRejected: 17, byteCount: null, message: "XPath ne najde zapisov");
    Check(napaka.Contains("NAPAKA"), "Padla faza mora biti videti kot napaka: " + napaka);
    Check(napaka.Contains("zavrnjeno 17"), "Zavrnjeni zapisi se morajo videti: " + napaka);

    // ─── Velikost datoteke ──────────────────────────────────────────────────
    var prenos = PhaseLog.Describe(PhaseCodes.Fetch, "BT_STOCK", null, PhaseOutcome.Succeeded, hasNewData: true,
      itemsIn: null, itemsOut: null, itemsRejected: null, byteCount: 2_097_152, message: null);
    Check(prenos.Contains("2,0 MB"), "Velikost prenosa mora biti berljiva: " + prenos);

    // ─── Pisec brez baze in vez s tekom posla ───────────────────────────────
    var brezBaze = PhaseLog.Disabled(_ => { });
    Check(!brezBaze.WritesToDatabase && brezBaze.JobRunId is null && brezBaze.StepOrder is null,
      "Pisec brez povezave ne sme trditi, da piše v bazo.");

    var prejsnjiTek = Environment.GetEnvironmentVariable(PhaseLog.JobRunVariable);
    var prejsnjiKorak = Environment.GetEnvironmentVariable(PhaseLog.StepOrderVariable);
    try
    {
      Environment.SetEnvironmentVariable(PhaseLog.JobRunVariable, null);
      Environment.SetEnvironmentVariable(PhaseLog.StepOrderVariable, null);
      var rocno = PhaseLog.FromEnvironment(null, "preizkus", _ => { });
      Check(rocno.JobRunId is null && rocno.StepOrder is null && !rocno.WritesToDatabase,
        "Ročni zagon iz ukazne vrstice nima teka posla in to ni napaka.");

      Environment.SetEnvironmentVariable(PhaseLog.JobRunVariable, "42");
      Environment.SetEnvironmentVariable(PhaseLog.StepOrderVariable, "7");
      var izGostitelja = PhaseLog.FromEnvironment(null, "preizkus", _ => { });
      Check(izGostitelja.JobRunId == 42 && izGostitelja.StepOrder == 7,
        "Worker mora tek in korak prevzeti iz okolja gostitelja.");

      Environment.SetEnvironmentVariable(PhaseLog.JobRunVariable, "ni številka");
      Environment.SetEnvironmentVariable(PhaseLog.StepOrderVariable, "-3");
      var smeti = PhaseLog.FromEnvironment(null, "preizkus", _ => { });
      Check(smeti.JobRunId is null && smeti.StepOrder is null, "Pokvarjena spremenljivka okolja ne sme podreti workerja.");
    }
    finally
    {
      Environment.SetEnvironmentVariable(PhaseLog.JobRunVariable, prejsnjiTek);
      Environment.SetEnvironmentVariable(PhaseLog.StepOrderVariable, prejsnjiKorak);
    }

    // ─── Gostitelj mora vez dejansko podati (pogodba nad kodo) ──────────────
    var runner = ReadSource("src", "PIM.Automation", "JobRunner.cs");
    Check(runner.Contains("PhaseLog.JobRunVariable") && runner.Contains("PhaseLog.StepOrderVariable"),
      "JobRunner mora otroškemu procesu podati PIM_JOB_RUN_ID in PIM_JOB_STEP_ORDER, sicer faze ne najdejo svojega teka.");
    Check(runner.Contains("JobStepStatus.Blocked") && runner.Contains("Preskočeno: v isti skupini je padel korak"),
      "Koraki za padlim korakom morajo ostati vidni kot blokirani.");
    Check(runner.Contains("izhodna koda {exitCode}: {lastError}"),
      "Opomba padlega koraka mora nositi zadnjo vrstico z napako, ne samo izhodne kode.");

    // ─── Blok 6: gostiteljev SQL korak (validacija, objava) piše fazo IZRACUN ────
    var zaPosel = PhaseLog.ForJob(null, "gostitelj", 42, 7, _ => { });
    Check(zaPosel.JobRunId == 42 && zaPosel.StepOrder == 7 && !zaPosel.WritesToDatabase,
      "PhaseLog.ForJob mora vezati fazo na tek in korak gostitelja; brez povezave samo izpisuje.");
    var brezVezi = PhaseLog.ForJob("Server=.;Database=PIM;Integrated Security=true", null, 0, -1, _ => { });
    Check(brezVezi.JobRunId is null && brezVezi.StepOrder is null && brezVezi.WritesToDatabase,
      "Neveljaven tek ali korak (0, negativno) pomeni »brez vezi«, ne napačne vezi.");
    Check(runner.Contains("PhaseLog.ForJob") && runner.Contains("PhaseCodes.Compute"),
      "JobRunner mora SQL korake (validacija, objava) zapisati kot fazo IZRACUN.");
    Check(JobRunner.SqlPhaseSource(new CycleStep("Validacija (podjetje 2)", CycleStepKind.Sql, "EXEC val.RunValidation @OrganizationId = 2"), "PRODUCT_VALIDATION") == "VALIDACIJA"
      && JobRunner.SqlPhaseSource(new CycleStep("Objava (podjetje 3)", CycleStepKind.Sql, "EXEC val.Promote @OrganizationId = 3"), "NIGHTLY_RECONCILIATION") == "OBJAVA"
      && JobRunner.SqlPhaseSource(new CycleStep("Drugo", CycleStepKind.Sql, "EXEC dbo.Nekaj"), "NEKI_POSEL") == "NEKI_POSEL",
      "Vir faze SQL koraka: VALIDACIJA/OBJAVA po koraku, sicer ključ posla.");

    // ─── Blok 6: faze v preostalih workerjih (pogodba nad kodo) ─────────────
    // Stran Nadzor ne sme reči »worker tega posla faz še ne poroča« za noben posel s procesom.
    (string Worker, string[] Mora)[] workerji =
    [
      ("PIM.KatalogWorker", ["MappingPhaseReport.RecordAsync", "MappingPhaseReport.RecordFailureAsync", "PhaseCodes.Watermark"]),
      ("PIM.XmlFileWorker", ["PhaseCodes.Read", "PhaseCodes.Land", "MappingPhaseReport.RecordAsync", "\"GENERIC_XML\""]),
      ("PIM.SaopOrdersWorker", ["PhaseCodes.Fetch", "PhaseCodes.Watermark", "MappingPhaseReport.RecordAsync", "\"SAOP_ORDERS_VNK\"", "\"SAOP_ORDERS_VND\""]),
      ("PIM.B2bWorker", ["PhaseCodes.File", "MagentoProductSchema.ProfileCode", "MagentoCustomerSchema.ProfileCode"]),
      ("PIM.Watchdog", ["PhaseCodes.Compute"]),
      ("PIM.AlertDispatcher", ["PhaseCodes.Send", "PhaseOutcome.Skipped", "PhaseOutcome.Failed"]),
      ("PIM.StockReplenishmentWorker", ["PhaseCodes.Compute", "PhaseCodes.Send", "PhaseOutcome.Failed"]),
    ];
    foreach (var (worker, mora) in workerji)
    {
      var koda = ReadSource("workers", worker, "Program.cs");
      Check(koda.Contains("PhaseLog.FromEnvironment"), $"{worker} mora faze pisati prek PhaseLog.FromEnvironment (vez s tekom posla).");
      foreach (var niz in mora)
        Check(koda.Contains(niz, StringComparison.Ordinal), $"{worker} mora vsebovati {niz} (blok 6).");
    }
    var preslikava = ReadSource("src", "PIM.XmlMapping", "MappingPhaseReport.cs");
    Check(preslikava.Contains("raw.Inbox") && preslikava.Contains("GROUP BY EntityType") && preslikava.Contains("PhaseCodes.Map"),
      "MappingPhaseReport šteje strani raw.Inbox po entiteti in piše fazo PRESLIKAVA.");
    Check(preslikava.Contains("PhaseOutcome.Skipped") && preslikava.Contains("PhaseOutcome.Failed"),
      "Preslikava brez strani je preskok, vse strani v karanteni so napaka — ne »uspelo«.");

    Console.WriteLine("F10 faze korakov PASS.");
  }

  /// <summary>Datoteka izvorne kode iz korena rešitve; testi tečejo iz mape rešitve.</summary>
  static string ReadSource(params string[] parts)
  {
    var root = Directory.GetCurrentDirectory();
    while (root is { Length: > 0 } && !File.Exists(Path.Combine(root, "PIM.sln")))
      root = Path.GetDirectoryName(root) ?? "";
    Check(root.Length > 0, "Korena rešitve (PIM.sln) ni bilo mogoče najti iz " + Directory.GetCurrentDirectory());
    var path = Path.Combine([root, .. parts]);
    Check(File.Exists(path), "Manjka datoteka: " + path);
    return File.ReadAllText(path);
  }

  static void Check(bool condition, string message)
  {
    if (condition) return;
    Console.Error.WriteLine("NAPAKA: " + message);
    Environment.Exit(1);
  }
}
