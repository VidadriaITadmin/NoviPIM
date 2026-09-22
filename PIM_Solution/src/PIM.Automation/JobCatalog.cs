using System.Globalization;

namespace PIM.Automation;

/*
  Katalog poslov (migracija 237). Vsak posel ima natanko eno odgovornost in svoj urnik; kar je bil
  prej cikel »katalog« (zajem artiklov + naročila + validacija + objava + izvoz v enem teku), je zdaj
  pet poslov z izrecnimi odvisnostmi:

    SAOP artikli  →  validacija  →  objava  →  spletni izvoz        (poslovni tok WEB_CATALOG)
    SAOP naročila                                                    (tok ORDERS, brez odvisnosti)

  Objava teče samo po uspešni validaciji, izvoz samo iz uspešne objave (vrata v ops.JobDependency);
  uspeh predhodnika naslednjega postavi na vrsto takoj (sprožilec). Izvoz ne validira več (stikalo
  B2bWorkerja za osvežitev validacije je tu prepovedano, glej test JobCatalogChecks): bere samo
  potrjeno stanje. Prav tako noben posel ne podaja stikala za razpored postopkov: urnik je ena raven.

  Tu je vse, kar se da preveriti brez baze in brez procesa: seznam poslov, privzeti urniki, odvisnosti
  in načrt korakov. Gradniki korakov (Worker, Note, StockFilesSteps, XmlSteps) so v WorkerSchedulerPolicy.cs,
  kjer so ostali od starih ciklov (221), ki jih je migracija 254 odstranila; PIM.AutomationHost je edini
  motor avtomatike. Kar posel potrebuje od sveta, pride prek CycleEnvironment.
*/

/// <summary>Poslovni tok, po katerem nadzorna plošča sestavi kartico. Zaprt seznam (CK_JobDefinition_Flow).</summary>
public static class JobFlows
{
  public const string WebCatalog = "WEB_CATALOG";
  public const string Stock = "STOCK";
  public const string Orders = "ORDERS";
  public const string Inputs = "INPUTS";
  public const string System = "SYSTEM";

  /// <summary>Štiri poslovne kartice na pregledu, v tem vrstnem redu; SYSTEM ni kartica.</summary>
  public static IReadOnlyList<string> Cards { get; } = [WebCatalog, Stock, Orders, Inputs];

  public static string Label(string flow) => flow switch
  {
    WebCatalog => "Spletni katalog",
    Stock => "Cene in zaloga",
    Orders => "Naročila",
    Inputs => "Vhodni viri",
    System => "Sistem",
    _ => flow,
  };

  public static string Description(string flow) => flow switch
  {
    WebCatalog => "Validacija, objava v PIM ter katalog.csv in stranke.csv za splet.",
    Stock => "Zaloga in cene iz SAOP in dobaviteljev ter cene in zaloga za splet.",
    Orders => "Naročila kupcev in dobaviteljem za MIN/MID/MAX ter dnevni mail o zalogi pod MID.",
    Inputs => "Artikli iz SAOP in nočna uskladitev vseh vhodov.",
    System => "Nadzornik, alarmi, samotest in odhodna pot v SAOP.",
    _ => "",
  };
}

/// <param name="IsGate">Odvisen posel se ne izvede (Blocked), kadar predhodnik ni uspel ali je njegov uspeh prestar.</param>
/// <param name="TriggersDependent">Uspeh predhodnika postavi odvisnega na vrsto takoj.</param>
public sealed record JobDependencyDefinition(string DependsOnJobKey, bool IsGate, int? MaxAgeSeconds, bool TriggersDependent, string Note);

/// <param name="Pipelines">Postopki v ops.ScheduleProfile, ki jih koraki odprejo prek ops.BeginRun (izklopljen postopek zavrne zagon z 51100).</param>
/// <param name="Workers">Imena projektov workerjev, ki jih posel poganja; test (JobCatalogChecks) z njimi preveri, da noben worker ni brez posla.</param>
/// <param name="ArtifactKinds">Kode izvoznih profilov, katerih datoteke gostitelj po uspehu zapiše v ops.Artifact.</param>
/// <summary>
/// Vir, ki ga posel prinaša, in koliko časa smejo biti njegovi podatki stari (blok 4 prenove nadzora, 2026-09-22).
/// Svežina se meri iz faz workerjev (ops.JobPhaseRun), ne iz izhodne kode: zelena lučka pomeni sveže podatke.
/// </summary>
/// <param name="SourceCode">Isti niz, kot ga worker piše v ops.JobPhaseRun.SourceCode (BT_STOCK, GetPrices ...).</param>
/// <param name="Pipeline">Postopek, pod katerim worker fazo piše (SOURCE_FETCH, STOCK_FILE, SAOP_STOCK ...).</param>
/// <param name="MaxAgeSeconds">Meja svežine; starejši podatki so rdeči (alarm SourceStale).</param>
/// <param name="PerOrganization">Ali se svežina meri za vsako podjetje posebej.</param>
/// <param name="MeasureNewData">true: šteje zadnja faza z NOVIMI podatki (zaloga); false: šteje zadnji uspešen stik
/// (cene, artikli — dolgo brez sprememb je normalno).</param>
public sealed record JobSourceDefinition(string SourceCode, string Label, string Pipeline, int MaxAgeSeconds, bool PerOrganization, bool MeasureNewData);

public sealed record JobDefinition(
  string Key, string Label, string Description, string Flow, bool IsFlowResult, int SortOrder,
  WorkerJobReach Reach, string? ReachNote, int? IntervalSeconds, TimeOnly? DailyAtLocal, int TimeoutSeconds, int? SlaSeconds,
  bool EnabledByDefault, IReadOnlyList<JobDependencyDefinition> Dependencies, IReadOnlyList<string> Pipelines,
  IReadOnlyList<string> Workers, IReadOnlyList<string> ArtifactKinds)
{
  public string ReachCode => Reach switch
  {
    WorkerJobReach.ExternalCall => "ExternalCall",
    WorkerJobReach.SendsEmail => "SendsEmail",
    _ => "Internal",
  };

  /// <summary>Viri s prago svežine (ops.JobSource); prazno pri poslih, katerih workerji še ne pišejo faz.</summary>
  public IReadOnlyList<JobSourceDefinition> Sources { get; init; } = [];
}

public static class JobCatalog
{
  public const string SaopProductImport = "SAOP_PRODUCT_IMPORT";
  public const string SaopOrderImport = "SAOP_ORDER_IMPORT";
  public const string StockImport = "STOCK_IMPORT";
  public const string SupplierStockImport = "SUPPLIER_STOCK_IMPORT";
  public const string PriceImport = "PRICE_IMPORT";
  public const string SaopDeliveryImport = "SAOP_DELIVERY_IMPORT";
  public const string ProductValidation = "PRODUCT_VALIDATION";
  public const string ProductPublication = "PRODUCT_PUBLICATION";
  public const string WebCatalogExport = "WEB_CATALOG_EXPORT";
  public const string WebStockExport = "WEB_STOCK_EXPORT";
  public const string AlertEvaluation = "ALERT_EVALUATION";
  public const string AlertDelivery = "ALERT_DELIVERY";
  public const string NightlyReconciliation = "NIGHTLY_RECONCILIATION";
  public const string StockReplenishmentDigest = "STOCK_REPLENISHMENT_DIGEST";
  public const string SystemSelfTest = "SYSTEM_SELF_TEST";
  public const string SaopOutboundDispatch = "SAOP_OUTBOUND_DISPATCH";

  const string MagentoProducts = "MAGENTO_PRODUCTS";
  const string MagentoCustomers = "MAGENTO_CUSTOMERS";
  const string MagentoStockPrices = "MAGENTO_STOCK_PRICES";

  public static IReadOnlyList<JobDefinition> All { get; } =
  [
    // 2026-09-22 (ekipa SAOP: preveč klicev): posli, ki kličejo SAOP, tečejo po enem naenkrat z dvema
    // minutama tišine vmes (UsesSaop, AutomationEngine) in obdelajo vsako podjetje v svojem koraku.
    new(SaopProductImport, "Artikli iz SAOP",
      "Samo osem točk za artikle (brez cen in šifrantov), vsako podjetje v svojem koraku; padec enega podjetja ne ustavi drugih. Cene imajo svoj posel, šifranti in poln zajem tečejo v nočni uskladitvi. Samo vhod: brez validacije, objave in izvoza. Uspeh sproži validacijo.",
      JobFlows.Inputs, true, 10, WorkerJobReach.ExternalCall, "kliče SAOP", 3600, null, 3600, 7200, true,
      [], ["SAOP_PRODUCTS"], ["PIM.KatalogWorker"], []) { Sources = [
      new("GetItemsGeneralData", "Osnovni podatki artiklov", "SAOP_PRODUCTS", 7200, true, false),
      new("GetItemsDescriptions", "Opisi artiklov", "SAOP_PRODUCTS", 7200, true, false),
      new("GetItemsTitlesLanguage", "Nazivi po jezikih", "SAOP_PRODUCTS", 7200, true, false),
      new("GetItemsCustomProperties", "Lastnosti artiklov", "SAOP_PRODUCTS", 7200, true, false),
      new("GetItemsPlanningData", "Planski podatki", "SAOP_PRODUCTS", 7200, true, false),
      new("GetItemsStockData", "Zalogovni podatki", "SAOP_PRODUCTS", 7200, true, false),
      new("GetItemsStockAccountingData", "Knjigovodski podatki zaloge", "SAOP_PRODUCTS", 7200, true, false),
      new("GetItemCustomerDataV2", "Podatki artiklov po kupcih", "SAOP_PRODUCTS", 7200, true, false),
    ] },
    new(SaopOrderImport, "Naročila iz SAOP",
      "Naročila kupcev (VNK) in naročila dobaviteljem (VND) za MIN/MID/MAX, vsako podjetje v svojem koraku. Popolnoma ločeno od spletnega kataloga.",
      JobFlows.Orders, true, 20, WorkerJobReach.ExternalCall, "kliče SAOP", 3600, null, 1800, 7200, true,
      [], ["SAOP_ORDERS_VNK", "SAOP_ORDERS_VND"], ["PIM.SaopOrdersWorker"], []) { Sources = [
      // Blok 6: PIM.SaopOrdersWorker piše faze pod imenom razporeda (SourceCode = Pipeline). Stik, ne novi
      // podatki: ura brez novega naročila je normalna. Podjetje brez knjige je preskok in ni stik.
      new("SAOP_ORDERS_VNK", "Naročila kupcev (VNK)", "SAOP_ORDERS_VNK", 7200, true, false),
      new("SAOP_ORDERS_VND", "Naročila dobaviteljem (VND)", "SAOP_ORDERS_VND", 7200, true, false),
    ] },
    new(StockImport, "Zaloga iz SAOP",
      "Količine zaloge iz SAOP, vsako podjetje v svojem koraku; padec enega podjetja ne ustavi drugih. Uspeh sproži izvoz cen in zaloge za splet.",
      JobFlows.Stock, false, 30, WorkerJobReach.ExternalCall, "kliče SAOP", 600, null, 900, 1800, true,
      [], ["SAOP_STOCK"], ["PIM.SaopStockWorker"], []) { Sources = [
      new("SAOP_STOCK", "Zaloga iz SAOP", "SAOP_STOCK", 1800, true, true),
    ] },
    new(PriceImport, "Cene iz SAOP",
      "Spremembe cen (GetPrices), vsako podjetje v svojem koraku. Okno spremembe določa Saop:LookbackDays v nastavitvah.",
      JobFlows.Stock, false, 31, WorkerJobReach.ExternalCall, "kliče SAOP", 600, null, 900, 1800, true,
      [], ["SAOP_PRICES"], ["PIM.KatalogWorker"], []) { Sources = [
      new("GetPrices", "Cene iz SAOP", "SAOP_PRICES", 1800, true, false),
    ] },
    new(SaopDeliveryImport, "Datumi dobave iz SAOP",
      "Datumi in količine prihoda, en klic na artikel za VSE artikle z zalogo iz SAOP (IQLighting ~8.800, okoli 50 min). Redno jih bere nočna uskladitev; ta posel je privzeto izklopljen in za ročni zagon.",
      JobFlows.Stock, false, 32, WorkerJobReach.ExternalCall, "kliče SAOP", 10800, null, 10800, 129600, false,
      [], ["SAOP_DELIVERY"], ["PIM.SaopStockWorker"], []),
    new(SupplierStockImport, "Zaloga dobaviteljev",
      "Prevzem in branje zaloge Nowodvorski (FTP) in Braytron (HTTPS) za vsa vključena podjetja. Prevzemnik sam spoštuje omejitve dobaviteljev (Nowodvorski na 2 h, Braytron en prenos na 3 h); nespremenjena datoteka se ne zapiše znova. SAOP ne kliče.",
      JobFlows.Stock, false, 33, WorkerJobReach.ExternalCall, "kliče dobavitelja", 1800, null, 900, 7200, true,
      [], ["SOURCE_FETCH", "STOCK_FILE"], ["PIM.SourceFetchWorker", "PIM.StockFileWorker"], []) { Sources = [
      // Dobaviteljeva datoteka: meri se zadnja NOVA datoteka v bazi (STOCK_FILE), ne stik s strežnikom —
      // Braytron je 2026-09-22 pet dni vračal isto datoteko in vse je bilo zeleno.
      new("BT_STOCK", "Braytron zaloga", "STOCK_FILE", 21600, true, true),
      new("NW_STOCK", "Nowodvorski zaloga", "STOCK_FILE", 14400, true, true),
    ] },
    new(ProductValidation, "Validacija artiklov",
      "val.RunValidation za vsako podjetje (celotna validacija, ker canon nima sledenja sprememb artiklov). Sproži jo uspešen zajem artiklov, sicer teče vsako uro.",
      JobFlows.WebCatalog, false, 40, WorkerJobReach.Internal, null, 3600, null, 3600, 7200, true,
      [new(SaopProductImport, false, null, true, "Uspešen zajem artiklov sproži validacijo; padec zajema je ne blokira (validira se obstoječi katalog, tudi urejanja v PIM).")],
      [], [], []),
    new(ProductPublication, "Objava v PIM",
      "val.Promote: veljavni artikli iz canon v pim za vsako podjetje. Teče samo po uspešni in sveži validaciji; sicer je blokirana.",
      JobFlows.WebCatalog, false, 41, WorkerJobReach.Internal, null, 3600, null, 1800, 7200, true,
      [new(ProductValidation, true, 7200, true, "Objava samo po uspešni validaciji, mlajši od dveh ur (236: pripravljenost zahteva svežo validacijo).")],
      [], [], []),
    new(WebCatalogExport, "Katalog in stranke za splet",
      "katalog.csv in stranke.csv (podjetje 2) iz objavljenega stanja. Brez validacije: bere samo potrjeno stanje in teče samo po uspešni objavi.",
      // 242: uspešna objava ga sproži takoj (TriggersDependent); razmik je rezerva. Izvoz podjetja 2
      // (89.491 vrstic × 180 stolpcev) traja minute — pri 300 s bi tekel neprekinjeno in obremenjeval bazo.
      JobFlows.WebCatalog, true, 42, WorkerJobReach.Internal, null, 3600, null, 1800, 7200, true,
      [new(ProductPublication, true, null, true, "Izvoz samo iz uspešno objavljenega stanja.")],
      [MagentoProducts], ["PIM.B2bWorker"], [MagentoProducts, MagentoCustomers]) { Sources = [
      // Blok 6: faza DATOTEKA PIM.B2bWorker (SourceCode = koda profila). Izvoz je samo za podjetje kataloga
      // (2), zato vir ni po podjetjih — sicer bi bila 3 in 4 za vedno »prestara«.
      new(MagentoProducts, "katalog.csv za splet", MagentoProducts, 7200, false, false),
    ] },
    new(WebStockExport, "Cene in zaloga za splet",
      "magento-stock-prices.csv za vsako podjetje iz trenutnega objavljenega stanja (profil MAGENTO_STOCK_PRICES).",
      // Sproži ga uspešna zaloga iz SAOP (vsakih ~10 min); cene pridejo v datoteko ob naslednjem izvozu.
      // Brez sprožilca iz cen, sicer bi izvoz treh podjetij (org 2 ~3 min) tekel skoraj neprekinjeno.
      JobFlows.Stock, true, 43, WorkerJobReach.Internal, null, 1800, null, 1800, 3600, true,
      [new(StockImport, false, null, true, "Uspešen zajem zaloge sproži izvoz cen in zaloge; padec ga ne blokira (izvoz bere zadnje objavljeno stanje)."),
       new(PriceImport, false, null, false, "Izvoz ne teče med zajemom cen; cene pridejo v datoteko ob naslednjem izvozu.")],
      [MagentoStockPrices], ["PIM.B2bWorker"], [MagentoStockPrices]) { Sources = [
      new(MagentoStockPrices, "magento-stock-prices.csv za splet", MagentoStockPrices, 3600, true, false),
    ] },
    new(AlertEvaluation, "Nadzornik",
      "Nadzornik zastalih obdelav (PIM.Watchdog): zastareli utripi, mirujoči vodni žigi, mrtva odhodna sporočila; alarme uvrsti v vrsto za dostavo.",
      JobFlows.System, false, 50, WorkerJobReach.Internal, null, 300, null, 300, 1800, true,
      [], ["WATCHDOG"], ["PIM.Watchdog"], []),
    new(AlertDelivery, "Razpošiljanje alarmov",
      "Odprte alarme pošlje po e-pošti oziroma webhooku, če je dostava vklopljena (PIM_ALERT_DELIVERY_ENABLED).",
      JobFlows.System, false, 51, WorkerJobReach.SendsEmail, "pošlje e-pošto, če je dostava vklopljena", 300, null, 300, 1800, true,
      [new(AlertEvaluation, false, null, true, "Nadzornik najprej uvrsti alarme v vrsto, razpošiljanje jih nato dostavi.")],
      ["ALERT_DISPATCH"], ["PIM.AlertDispatcher"], []),
    new(NightlyReconciliation, "Nočna uskladitev",
      "Kontrolni polni pregled, ne redna produkcijska pot: SAOP katalog, prevzem in dobaviteljev XML, preslikava zaostanka, zaloge iz datotek, zaloga in dobave iz SAOP, nato validacija in objava vseh podjetij. Če pade katerikoli vhod, sta validacija in objava blokirani.",
      // 00:30: zunaj okna 02:00-03:00, ki ga poletni čas preskoči ali ponovi.
      JobFlows.Inputs, false, 60, WorkerJobReach.ExternalCall, "kliče SAOP in dobavitelja", null, new TimeOnly(0, 30), 21600, 129600, true,
      [], ["SAOP_PRODUCTS", "SOURCE_FETCH", "GENERIC_XML", "STOCK_FILE", "SAOP_STOCK", "SAOP_DELIVERY"],
      ["PIM.KatalogWorker", "PIM.SourceFetchWorker", "PIM.XmlFileWorker", "PIM.StockFileWorker", "PIM.SaopStockWorker"], []) { Sources = [
      new("SAOP_DELIVERY", "Datumi dobave iz SAOP", "SAOP_DELIVERY", 129600, true, false),
      // Blok 6: PIM.XmlFileWorker piše BRANJE/ZAPIS/PRESLIKAVA pod GENERIC_XML s kodo vira (PIM_XML_SOURCE_CODE).
      // Meji po odobrenem načrtu (2026-09-22): Nowodvorski 7 dni, Braytron 36 h (dan in rezerva za nočni termin).
      new("NW_XML", "Nowodvorski XML (katalog)", "GENERIC_XML", 604800, true, false),
      new("BT_XML", "Braytron XML (katalog)", "GENERIC_XML", 129600, true, false),
    ] },
    new(StockReplenishmentDigest, "Zaloga pod MID (dnevni mail)",
      "Dnevni mail o artiklih na ali pod MID pragom prejemnikom s kljukico »Zaloga pod MID«.",
      JobFlows.Orders, false, 61, WorkerJobReach.SendsEmail, "pošlje e-pošto prejemnikom", null, new TimeOnly(5, 30), 900, 129600, true,
      [], ["STOCK_REPLENISHMENT_DIGEST"], ["PIM.StockReplenishmentWorker"], []) { Sources = [
      // Blok 6: IZRACUN in POSILJANJE PIM.StockReplenishmentWorker; neuspelo pošiljanje je padla faza.
      new("STOCK_REPLENISHMENT_DIGEST", "Dnevni mail o zalogi pod MID", "STOCK_REPLENISHMENT_DIGEST", 129600, true, false),
    ] },
    new(SystemSelfTest, "Nočni samotest",
      "Prehodi celo verigo (baza, razporedi, utripi, katalog, izvoz) in rezultat zapiše v ops.SelfTestRun. Samo bere. Privzeto izklopljen: brez objavljenega samotesta ga gostitelj poganja z dotnet run, ki ponoči gradi projekt.",
      JobFlows.System, false, 70, WorkerJobReach.Internal, null, null, new TimeOnly(4, 30), 1800, 129600, false,
      [], [], ["PIM.SelfTest.Nightly"], []),
    new(SaopOutboundDispatch, "Pošiljanje v SAOP (odhodna vrsta)",
      "Odhodna pot v SAOP (PIM.OutboxDispatcher). Privzeto izklopljeno: pošiljanje je ročna odločitev z odobritvijo in zahteva razpored OUTBOUND ter poverilnice.",
      JobFlows.System, false, 80, WorkerJobReach.ExternalCall, "piše v SAOP", 300, null, 900, null, false,
      [], ["OUTBOUND"], ["PIM.OutboxDispatcher"], []),
  ];

  public static JobDefinition? Find(string? key) => All.FirstOrDefault(job => job.Key == key);

  /// <summary>Posli po tokovih v vrstnem redu kartic; sistem na koncu.</summary>
  public static IReadOnlyList<string> FlowOrder { get; } = [.. JobFlows.Cards, JobFlows.System];

  // ─── Načrt korakov ────────────────────────────────────────────────────────

  /// <summary>
  /// Koraki posla za dano okolje. Skupine so zaporedne; skupina z <see cref="CycleGroup.RequiresAllPrevious"/>
  /// se ne izvede (koraki Blocked), če je katera od prejšnjih padla — odvisni koraki po padlem
  /// obveznem koraku ne smejo »vseeno« teči.
  /// </summary>
  public static IReadOnlyList<CycleGroup> Plan(string jobKey, CycleEnvironment env) => jobKey switch
  {
    // Urni zajem artiklov: samo točke artiklov, eno podjetje na proces in brez vzporednih zahtevkov.
    // Poln zajem (--full) in šifranti so v nočni uskladitvi; prej je bil prvi dan v mesecu vsak urni tek poln.
    SaopProductImport => PerOrganization(env, "Artikli iz SAOP", org => WorkerCycles.Worker($"Artikli iz SAOP (podjetje {org})", "PIM.KatalogWorker",
      ["--organizations", WorkerCycles.Org(org), "--endpoints", ItemEndpoints, "--max-parallel", "1"], env.Paths, org, environment: WorkerCycles.SaopLive)),
    SaopOrderImport => PerOrganization(env, "Naročila iz SAOP", org => WorkerCycles.Worker($"Naročila iz SAOP (podjetje {org})", "PIM.SaopOrdersWorker",
      ["--organizations", WorkerCycles.Org(org)], env.Paths, org, environment: WorkerCycles.SaopLive)),
    StockImport => PerOrganization(env, "Zaloga iz SAOP", org => WorkerCycles.Worker($"Zaloga iz SAOP (podjetje {org})", "PIM.SaopStockWorker",
      ["--organizations", WorkerCycles.Org(org)], env.Paths, org, environment: WorkerCycles.SaopLive)),
    SupplierStockImport => PlanSupplierStock(env),
    PriceImport => PerOrganization(env, "Cene iz SAOP", org => WorkerCycles.Worker($"Cene iz SAOP (podjetje {org})", "PIM.KatalogWorker",
      ["--organizations", WorkerCycles.Org(org), "--endpoints", "GetPrices"], env.Paths, org, environment: WorkerCycles.SaopLive)),
    SaopDeliveryImport => PerOrganization(env, "Datumi dobave iz SAOP", org => WorkerCycles.Worker($"Datumi dobave iz SAOP (podjetje {org})", "PIM.SaopStockWorker",
      ["--organizations", WorkerCycles.Org(org), "--dostave"], env.Paths, org, environment: WorkerCycles.SaopLive)),
    ProductValidation => env.Organizations.Select(org => new CycleGroup($"Validacija (podjetje {org})", [Validate(org)])).ToList(),
    ProductPublication => env.Organizations.Select(org => new CycleGroup($"Objava (podjetje {org})", [Promote(org)])).ToList(),
    WebCatalogExport => env.Organizations.Contains(env.CatalogOrganizationId)
      ? [new("Katalog in stranke za splet", [WorkerCycles.Worker("Katalog in stranke", "PIM.B2bWorker",
          ["--export-magento", "--organization-id", WorkerCycles.Org(env.CatalogOrganizationId)], env.Paths, env.CatalogOrganizationId)])]
      : [new("Katalog in stranke za splet", [WorkerCycles.Note("Katalog in stranke", "preskočeno: podjetje kataloga je izključeno iz avtomatike.")])],
    WebStockExport => env.Organizations.Select(org => new CycleGroup($"Cene in zaloga (podjetje {org})",
      [WorkerCycles.Worker($"Cene in zaloga (podjetje {org})", "PIM.B2bWorker",
        ["--export-profile", MagentoStockPrices, "--organization-id", WorkerCycles.Org(org), .. WorkerCycles.ExportDirectory(env, org), "--file-name", "magento-stock-prices.csv"],
        env.Paths, org)])).ToList(),
    AlertEvaluation => [new("Nadzornik zastalih obdelav", [WorkerCycles.Worker("Nadzornik", "PIM.Watchdog", [], env.Paths)])],
    AlertDelivery => [new("Razpošiljanje alarmov", [WorkerCycles.Worker("Razpošiljanje alarmov", "PIM.AlertDispatcher", [], env.Paths)])],
    NightlyReconciliation => PlanNightly(env),
    StockReplenishmentDigest =>
    [
      new("Zaloga pod MID (dnevni mail)", [WorkerCycles.Worker("Zaloga pod MID", "PIM.StockReplenishmentWorker",
        ["--organizations", WorkerCycles.Orgs(env)], env.Paths)]),
    ],
    SystemSelfTest => WorkerCycles.PlanSamotest(env),
    SaopOutboundDispatch => [new("Odhodna vrsta v SAOP", [WorkerCycles.Worker("Odhodna vrsta", "PIM.OutboxDispatcher", [], env.Paths)])],
    _ => throw new InvalidOperationException($"Neznan posel: {jobKey}."),
  };

  /// <summary>Točke artiklov za urni zajem; GetPrices ima svoj posel, šifranti in poln zajem so nočni.</summary>
  public const string ItemEndpoints =
    "GetItemsGeneralData,GetItemsDescriptions,GetItemsTitlesLanguage,GetItemsCustomProperties,GetItemsPlanningData,GetItemsStockData,GetItemsStockAccountingData,GetItemCustomerDataV2";

  static readonly HashSet<string> SaopJobs = new(StringComparer.Ordinal)
  {
    SaopProductImport, SaopOrderImport, StockImport, PriceImport, SaopDeliveryImport, NightlyReconciliation, SaopOutboundDispatch,
  };

  /// <summary>
  /// Posel kliče SAOP: gostitelj takih poslov nikoli ne požene hkrati in med njimi pusti tišino
  /// (<see cref="SaopQuietSeconds"/>), kot je zahtevala ekipa SAOP 2026-09-22.
  /// </summary>
  public static bool UsesSaop(string jobKey) => SaopJobs.Contains(jobKey);

  public const int SaopQuietSeconds = 120;

  /// <summary>En korak (in ena skupina) na podjetje: padec enega podjetja ne ustavi naslednjih.</summary>
  static IReadOnlyList<CycleGroup> PerOrganization(CycleEnvironment env, string label, Func<int, CycleStep> step) =>
    env.Organizations.Select(org => new CycleGroup($"{label} (podjetje {org})", [step(org)])).ToList();

  /// <summary>Zaloga dobaviteljev: dva neodvisna vira; padec enega ne ustavi drugega.</summary>
  static IReadOnlyList<CycleGroup> PlanSupplierStock(CycleEnvironment env)
  {
    var groups = new List<CycleGroup>();
    foreach (var vir in new[] { "NW_STOCK", "BT_STOCK" })
    {
      var mapa = Path.Combine(env.LandingRoot, vir);
      groups.Add(new($"Zaloga {vir}",
      [
        WorkerCycles.Worker($"Prevzem {vir}", "PIM.SourceFetchWorker", ["--source", vir, "--target", env.LandingRoot], env.Paths),
        new($"Branje {vir}", CycleStepKind.Expand, $"datoteke v {mapa}", Expand: () => WorkerCycles.StockFilesSteps(vir, mapa, env, [])),
      ]));
    }
    return groups;
  }

  /// <summary>
  /// Nočna uskladitev: isti vrstni red vhodov kot Nocno-vse.ps1 (nova šifra artikla mora obstajati,
  /// preden jo kdo obogati), validacija in objava pa šele, ko so vsi vhodi uspeli — sicer sta blokirani.
  /// Dnevni mail o zalogi pod MID je svoj posel.
  /// </summary>
  static IReadOnlyList<CycleGroup> PlanNightly(CycleEnvironment env)
  {
    var groups = new List<CycleGroup>();
    var orgs = WorkerCycles.Orgs(env);

    // --max-parallel 1: podjetja zaporedno, en zahtevek na SAOP naenkrat (prej štirje hkrati).
    groups.Add(new("SAOP katalog",
      [WorkerCycles.Worker("Katalog iz SAOP", "PIM.KatalogWorker",
        ["--organizations", orgs, "--max-parallel", "1", .. (env.IsFullCatalogDay ? new[] { "--full" } : [])],
        env.Paths, environment: WorkerCycles.SaopLive)]));
    groups.Add(new("Prevzem dobaviteljevih datotek", [WorkerCycles.Worker("Prevzem", "PIM.SourceFetchWorker", ["--target", env.LandingRoot], env.Paths)]));
    groups.Add(new("Dobaviteljev XML (Nowodvorski)", [new("XML Nowodvorski", CycleStepKind.Expand, "NW_XML", Expand: () => WorkerCycles.XmlSteps("NW_XML", "nw", env))]));
    groups.Add(new("Dobaviteljev XML (Braytron)", [new("XML Braytron", CycleStepKind.Expand, "BT_XML", Expand: () => WorkerCycles.XmlSteps("BT_XML", "bt", env))]));
    groups.Add(new("Preslikava zaostanka v raw.Inbox",
      [WorkerCycles.Worker("Preslikava zaostanka", "PIM.KatalogWorker", ["--preslikaj-zaostanek"], env.Paths, environment: WorkerCycles.SaopLive)]));
    groups.Add(new("Zaloge dobaviteljev", [new("Zaloge iz datotek", CycleStepKind.Expand, "NW_STOCK, BT_STOCK", Expand: () =>
    {
      var steps = new List<CycleStep>();
      foreach (var vir in new[] { "NW_STOCK", "BT_STOCK" })
        steps.AddRange(WorkerCycles.StockFilesSteps(vir, Path.Combine(env.LandingRoot, vir), env, []));
      return steps;
    })]));
    groups.Add(new("Zaloga iz SAOP (kolicine)",
      [WorkerCycles.Worker("Zaloga iz SAOP", "PIM.SaopStockWorker", ["--organizations", orgs], env.Paths, environment: WorkerCycles.SaopLive)]));
    groups.Add(new("Zaloga iz SAOP (datumi prihoda)",
      [WorkerCycles.Worker("Datumi dobave iz SAOP", "PIM.SaopStockWorker", ["--organizations", orgs, "--dostave"], env.Paths, environment: WorkerCycles.SaopLive)]));

    // Uskladitev je popolna samo, če so vsi vhodi uspeli; sicer objava ne sme potrditi napol posodobljenega stanja.
    groups.Add(new("Validacija vseh podjetij", env.Organizations.Select(Validate).ToList(), RequiresAllPrevious: true));
    groups.Add(new("Objava vseh podjetij", env.Organizations.Select(Promote).ToList(), RequiresAllPrevious: true));
    return groups;
  }

  // 251: v istem koraku (en stavek, en poskus ob zastoju) po validaciji se umaknejo kljukice artiklov, ki
  // niso več veljavni za splet — samo pri podjetju z vklopljenim samodejnim umikom (pim.WebPublicationPolicy).
  // Stanje je sveže, zato brez ponovne validacije kandidatov.
  static CycleStep Validate(int org) =>
    new($"Validacija (podjetje {org})", CycleStepKind.Sql, $"EXEC val.RunValidation @OrganizationId = {org}; EXEC pim.WithdrawIneligibleWebShops",
      Sql: ["EXEC val.RunValidation @OrganizationId = @OrganizationId; "
        + "EXEC pim.WithdrawIneligibleWebShops @OrganizationId = @OrganizationId, @TriggerSource = N'VALIDACIJA';"], OrganizationId: org);

  static CycleStep Promote(int org) =>
    new($"Objava (podjetje {org})", CycleStepKind.Sql, $"EXEC val.Promote @OrganizationId = {org}",
      Sql: ["EXEC val.Promote @OrganizationId = @OrganizationId;"], OrganizationId: org);

  // ─── Artefakti ────────────────────────────────────────────────────────────

  /// <summary>
  /// Kje posel pusti datoteke, ki jih gostitelj po uspehu zapiše v ops.Artifact. Ista pot, kot jo
  /// razreši PIM.B2bWorker: register EXPORT_ROOT, sicer izvoz\magento\&lt;podjetje&gt; ob korenu.
  /// </summary>
  public static IReadOnlyList<(string Kind, int OrganizationId, string FilePath)> ArtifactLocations(string jobKey, CycleEnvironment env)
  {
    string Directory(int org) => env.ExportRoot is { Length: > 0 } root ? root : env.Paths.ExportDirectory(org);
    return jobKey switch
    {
      WebCatalogExport when env.Organizations.Contains(env.CatalogOrganizationId) =>
      [
        (MagentoProducts, env.CatalogOrganizationId, Path.Combine(Directory(env.CatalogOrganizationId), "katalog.csv")),
        (MagentoCustomers, env.CatalogOrganizationId, Path.Combine(Directory(env.CatalogOrganizationId), "stranke.csv")),
      ],
      WebStockExport => env.Organizations.Select(org => (MagentoStockPrices, org, Path.Combine(WorkerCycles.StockExportDirectory(env, org), "magento-stock-prices.csv"))).ToList(),
      _ => [],
    };
  }

  /// <summary>Prvi termin po zagonu gostitelja, kadar ga vrstica še nima; ponavljajoči posli so razmaknjeni za minuto.</summary>
  public static DateTime InitialDue(JobDefinitionRow job, int staggerIndex, DateTime nowUtc, TimeZoneInfo zone) =>
    job.IntervalSeconds is not null
      ? DateTime.SpecifyKind(nowUtc, DateTimeKind.Utc).AddSeconds(30 + 60 * staggerIndex)
      : WorkerCycles.NextDue(null, job.DailyAtLocal, nowUtc, zone);

  /// <summary>Najdaljši odlog ponavljajočega posla po zaporednih napakah.</summary>
  public const int MaxBackoffSeconds = 4 * 3600;

  /// <summary>
  /// Naslednji termin po koncu teka. Ponavljajoč posel: konec + razmik, po n-ti zaporedni napaki
  /// konec + razmik × 2^(n-1), največ <see cref="MaxBackoffSeconds"/> (nikoli manj kot razmik). Dnevni
  /// posel: naslednji dnevni termin, ne glede na napake.
  /// </summary>
  public static DateTime NextAfterEnd(int? intervalSeconds, TimeOnly? dailyAtLocal, DateTime endUtc, TimeZoneInfo zone, int consecutiveFailures)
  {
    if (intervalSeconds is not { } seconds || seconds <= 0) return WorkerCycles.NextDue(null, dailyAtLocal, endUtc, zone);
    var factor = consecutiveFailures <= 1 ? 1L : 1L << Math.Min(consecutiveFailures - 1, 10);
    var delay = Math.Min(seconds * factor, Math.Max(seconds, MaxBackoffSeconds));
    return DateTime.SpecifyKind(endUtc, DateTimeKind.Utc).AddSeconds(delay);
  }

  public static string FormatSchedule(int? intervalSeconds, TimeOnly? dailyAtLocal) =>
    intervalSeconds is { } seconds
      ? seconds % 3600 == 0 ? $"vsakih {seconds / 3600} h" : $"vsakih {Math.Max(1, seconds / 60)} min"
      : $"vsak dan ob {dailyAtLocal?.ToString("HH:mm", CultureInfo.InvariantCulture) ?? "?"}";
}
