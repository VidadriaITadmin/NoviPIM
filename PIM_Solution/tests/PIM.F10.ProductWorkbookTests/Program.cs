using System.Text.Json;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using PIM.Intranet.Services;
using PIM.Operations;

// Delovni list izdelkov: dokaz, da gre datoteka ven in se vrne nazaj.
//
// Zahteva uporabnika 2026-09-08: en izvoz in en uvoz, da uporabnik podatke dopolni v Excelu in
// jih vrne. Kar je bilo prej narobe: izvoz »pregled« je imel slovenske naslove, uvoz pa je
// poznal samo kanonicne kode — od izvozene datoteke bi se nazaj prebrala samo sifra artikla.
//
// Prvi del testa je cista logika in tece vedno. Drugi del potrebuje razvojno bazo; brez nje se
// PRESKOCI in ne pade — AGENTS.md §12: test, ki je zelen samo pri agentu s sejo, je slabsi od
// testa, ki pove, da ni tekel.

var failures = new List<string>();
void Check(string name, bool condition, string? detail = null)
{
  if (condition) { Console.WriteLine($"  OK   {name}"); return; }
  failures.Add(name + (detail is null ? "" : " — " + detail));
  Console.WriteLine($"  FAIL {name}" + (detail is null ? "" : " — " + detail));
}

Console.WriteLine("=== Pogodba stolpcev (brez baze) ===");

var spec = new ProductWorkbookSpec(
  SaopFields:
  [
    new("Product.UoM", "ItemUnit", "Enota mere", "text"),
    new("Product.Supplier", "SupplierID", "Dobavitelj", "text"),
    new("ProductCommercial.NetWeight", "ItemNetWeight", "Neto teža", "decimal4"),
    // Namenoma ista oznaka kot atribut spodaj: dvoumnost mora pogodba razrešiti sama.
    new("Product.Warranty", "ItemWarranty", "Garancija", "text"),
  ],
  WebSites: [new("svetila_si", "Svetila.si", "svetila_si"), new("B2C", "Videlektro", "videlektro")],
  TextTypes: ["WEB_TITLE", "DESCRIPTION"],
  Languages: ["sl", "en"],
  Attributes: [new("Garancija", "Garancija", InSet: true, SetLevel: "REQUIRED"), new("Barva", "Barva")]);

var columns = ProductWorkbookContract.Build(spec);

Check("ključ je prvi in nosi šifro artikla",
  columns[1].FieldKey == ProductWorkbookContract.ItemIdField && columns[0].FieldKey == ProductWorkbookContract.OrganizationField);

// Objemke.xlsx 2026-09-22: »Oddelek (ABC)« B -> A se ni zaznal, ker je »Dodatna lastnost 1«
// (AdditionalProperty1ID, isti ključ Product.Department) v isti vrstici še nosila B in je povozila A.
var sharedKey = ProductWorkbookContract.Build(new(
  [new("Product.Department", "ItemDepartment", "Oddelek (ABC)", "text"),
   new("Product.Department", "AdditionalProperty1ID", "Dodatna lastnost 1", "text")],
  [], [], ["sl"], []));
Check("drugo polje SAOP z istim ključem je samo za branje",
  sharedKey.Single(column => column.Header == "Oddelek (ABC)").Target == ProductWorkbookTarget.Saop
  && sharedKey.Single(column => column.Header == "Dodatna lastnost 1").Target == ProductWorkbookTarget.ReadOnly);

// »02« -> »2« v šifri je sprememba (prej jo je številska primerjava zamolčala); predogled jo
// pokaže z opozorilom, ker jo pogosto naredi Excel sam.
Check("razlika samo v vodilnih ničlah se prepozna",
  ProductWorkbookService.OnlyLeadingZerosDiffer("2", "02")
  && ProductWorkbookService.OnlyLeadingZerosDiffer("1", "0000001")
  && !ProductWorkbookService.OnlyLeadingZerosDiffer("1", "0000601")
  && !ProductWorkbookService.OnlyLeadingZerosDiffer("02", "02")
  && !ProductWorkbookService.OnlyLeadingZerosDiffer("1.5", "01.5"));
Check("šifra ni število: »02« je številsko polje le, kadar je decimal",
  !new ProductWorkbookColumn("g", "DDV", "Product.VatRateId", ProductWorkbookTarget.Saop, ValueFormat: "text").IsNumber
  && new ProductWorkbookColumn("g", "Teža", "ProductCommercial.NetWeight", ProductWorkbookTarget.Saop, ValueFormat: "decimal4").IsNumber);

Check("stolpec spletnih strani obstaja in je last PIM",
  columns.Any(column => column.FieldKey == ProductWorkbookContract.WebSitesField
    && column.Target == ProductWorkbookTarget.Pim && column.IsMultiValue));

Check("vsaka spletna stran ima svoj stolpec kategorij",
  columns.Any(column => column.FieldKey == "ProductCategory.svetila_si")
  && columns.Any(column => column.FieldKey == "ProductCategory.B2C"));

Check("spletna besedila so po jezikih",
  columns.Any(column => column.FieldKey == "ProductText.WEB_TITLE.sl")
  && columns.Any(column => column.FieldKey == "ProductText.DESCRIPTION.en"));

Check("atribut iz nabora in atribut izven nabora sta v ločenih skupinah",
  columns.Any(column => column.FieldKey == "ProductAttribute.Garancija" && column.Group == ProductWorkbookContract.GroupAttributesInSet)
  && columns.Any(column => column.FieldKey == "ProductAttribute.Barva" && column.Group == ProductWorkbookContract.GroupAttributesOutside));

Check("ERP polja gredo v vrsto za SAOP, ne v katalog",
  columns.Where(column => column.FieldKey.StartsWith("Product.UoM")).All(column => column.Target == ProductWorkbookTarget.Saop));

Check("stanje je samo za branje",
  columns.Where(column => column.FieldKey.StartsWith("Row.")).All(column => column.Target == ProductWorkbookTarget.ReadOnly));

var duplicateHeaders = columns.GroupBy(column => WorkbookHeader.Normalize(column.Header))
  .Where(group => group.Count() > 1).Select(group => group.Key).ToList();
Check("noben naslov stolpca ni podvojen", duplicateHeaders.Count == 0, string.Join(", ", duplicateHeaders));

// Ta je bistvo naloge: kar izvoz izpise, mora uvoz prepoznati.
var headers = columns.Select(column => column.Header).ToList();
var matched = ProductWorkbookContract.Match(headers, columns);
var lost = matched.Where(match => match.Column is null).Select(match => match.Header).ToList();
Check("izvožene glave se vse prepoznajo nazaj", lost.Count == 0, string.Join(", ", lost));
Check("prepoznan je isti stolpec, ne kar koli",
  matched.All(match => match.Column is not null && match.Column.Header == match.Header));

// Kanonicna koda in ime elementa SAOP sta prav tako sprejeta: kdor si naredi svojo datoteko,
// ni vezan na slovenske naslove.
var byCode = ProductWorkbookContract.Match(["Šifra artikla", "Product.UoM", "ItemNetWeight", "ProductText.WEB_TITLE.sl"], columns);
Check("koda polja je sprejeta kot naslov", byCode[1].Column?.FieldKey == "Product.UoM");
Check("ime elementa SAOP je sprejeto kot naslov", byCode[2].Column?.FieldKey == "ProductCommercial.NetWeight");
Check("koda besedila je sprejeta kot naslov", byCode[3].Column?.FieldKey == "ProductText.WEB_TITLE.sl");

var unknown = ProductWorkbookContract.Match(["Šifra artikla", "Nekaj izmišljenega"], columns);
Check("neznan stolpec se ne prilepi na napačno polje", unknown[1].Column is null);

// Naloga #6: stari stolpec »Naziv« (spletni naziv, sicer naziv ERP) se je ob uvozu vpisal v
// »Spletni naziv (sl)«. Izvoz ga nima več, uvoz pa ga preskoči kot dvoumnega in to pove.
Check("izvoz nima dvoumnega stolpca »Naziv«",
  !columns.Any(column => ProductWorkbookContract.IsAmbiguousHeader(column.Header)),
  string.Join(", ", columns.Where(column => ProductWorkbookContract.IsAmbiguousHeader(column.Header)).Select(column => column.Header)));
var titles = ProductWorkbookContract.Match(["Šifra artikla", "Naziv", "Spletni naziv (sl)", " naziv  artikla ", "Title"], columns);
Check("»Naziv« se ne ujame z nobenim poljem in je označen kot dvoumen",
  titles[1].Column is null && titles[1].Ambiguous);
Check("»Spletni naziv (sl)« gre v spletni naziv (sl)",
  titles[2].Column?.FieldKey == "ProductText.WEB_TITLE.sl" && !titles[2].Ambiguous);
Check("dvoumen je tudi »Naziv artikla« in »Title« (brez razlike v presledkih in velikosti)",
  titles[3].Ambiguous && titles[4].Ambiguous && titles[3].Column is null && titles[4].Column is null);
Check("pravi stolpci in atributi »Nazivna …« niso dvoumni (natančna primerjava, ne »vsebuje«)",
  !ProductWorkbookContract.IsAmbiguousHeader("Spletni naziv (sl)") && !ProductWorkbookContract.IsAmbiguousHeader("Naziv ERP (sl)")
  && !ProductWorkbookContract.IsAmbiguousHeader("Nazivna napetost") && !ProductWorkbookContract.IsAmbiguousHeader("Ime"));
// Nasvet mora imenovati stolpca, ki na listu res obstajata: naziv ERP ima naslov iz registra SAOP
// (»Naziv 1«), ne »Naziv ERP (sl)« — ta naslov uvoz ne pozna in bi vodil v napačen nov atribut.
var titleColumns = ProductWorkbookContract.Build(spec with
{
  SaopFields = [.. spec.SaopFields, new("ProductText.TITLE_ERP.sl", "ItemTitle1", "Naziv 1", "text")],
});
var titleWarnings = ProductWorkbookService.AmbiguousColumnWarnings(titles, titleColumns);
Check("opozorilo pove, kateri stolpec je preskočen, zakaj in kaj uporabiti (dejanska naslova lista)",
  titleWarnings.Count == 3 && titleWarnings[0].Contains("»Naziv«") && titleWarnings[0].Contains("dvoumen")
  && titleWarnings[0].Contains("»Spletni naziv (sl)«") && titleWarnings[0].Contains("»Naziv 1«")
  && !titleWarnings[0].Contains("Naziv ERP (sl)"),
  string.Join(" | ", titleWarnings));
var advisedHeaders = new[] { "Spletni naziv (sl)", "Naziv 1" };
Check("predlagana stolpca uvoz res prepozna (spletni naziv in naziv ERP za SAOP)",
  ProductWorkbookContract.Match(advisedHeaders, titleColumns) is var advised
  && advised[0].Column?.FieldKey == "ProductText.WEB_TITLE.sl"
  && advised[1].Column?.FieldKey == "ProductText.TITLE_ERP.sl" && advised[1].Column?.Target == ProductWorkbookTarget.Saop);
Check("list brez stolpca naziva ERP ga v nasvetu ne omenja",
  ProductWorkbookService.AmbiguousColumnWarnings(titles, columns)[0] is var noErp
  && noErp.Contains("»Spletni naziv (sl)«") && !noErp.Contains("ERP (")
  && !noErp.Contains("Naziv 1"), ProductWorkbookService.AmbiguousColumnWarnings(titles, columns)[0]);
Check("atribut z dvoumnim imenom dobi v izvozu naslov s kodo (uvoz bi ga sicer preskočil)",
  ProductWorkbookContract.Build(spec with { Attributes = [.. spec.Attributes, new("NAZIV", "Naziv")] })
    .Any(column => column.FieldKey == "ProductAttribute.NAZIV" && !ProductWorkbookContract.IsAmbiguousHeader(column.Header)));

// Atributi: »Naziv« ne sme dobiti predloga »Nazivna napetost« in se ne sme ustvariti kot nov
// atribut — ne brez skupine, ne pod »Atributi kategorije — nabor«, ne po izbiri v oknu.
var knownAttributes = new Dictionary<string, string>(StringComparer.Ordinal)
{
  [WorkbookHeader.Normalize("Nazivna napetost")] = "Nazivna napetost",
  [WorkbookHeader.Normalize("NAZIVNA_NAPETOST")] = "Nazivna napetost",
  [WorkbookHeader.Normalize("Barva ohišja")] = "Barva ohišja",
};
string AttributeGroup(int index) => index >= 2 ? "Atributi kategorije — nabor" : ProductWorkbookContract.GroupKey;
var attributeHeaders = ProductWorkbookContract.Match(["Šifra artikla", "Naziv", "Naziv", "Barva ohisja", "Nov atribut"], columns);
var attributeMatch = ProductWorkbookService.MatchAttributes(attributeHeaders, AttributeGroup, knownAttributes,
  new Dictionary<string, string> { ["Naziv"] = "Naziv" });
Check("»Naziv« ne postane atribut (ne v ključu, ne pod skupino atributov, ne po izbiri v oknu)",
  attributeMatch.Matches[1].Column is null && attributeMatch.Matches[2].Column is null
  && !attributeMatch.NewAttributes.Contains("Naziv", StringComparer.OrdinalIgnoreCase),
  string.Join(", ", attributeMatch.NewAttributes));
Check("»Naziv« ne dobi predloga atributa (»Nazivna napetost«)",
  !attributeMatch.Suggestions.ContainsKey("Naziv"));
Check("ostali stolpci pod skupino atributov delujejo kot prej",
  attributeMatch.Matches[3].Column?.FieldKey == ProductWorkbookContract.AttributeFieldPrefix + "Barva ohišja"
  && attributeMatch.NewAttributes.Contains("Nov atribut"),
  $"{attributeMatch.Matches[3].Column?.FieldKey}; {string.Join(", ", attributeMatch.NewAttributes)}");

Check("seznam se loči z |",
  ProductWorkbookContract.SplitList("Svetila.si | Videlektro").SequenceEqual(["Svetila.si", "Videlektro"]));
Check("prazna celica da prazen seznam", ProductWorkbookContract.SplitList("   ").Count == 0);
Check("seznam se sestavi nazaj",
  ProductWorkbookContract.JoinList(["Svetila.si", "Videlektro"]) == "Svetila.si | Videlektro");
Check("prazen seznam da prazno celico", ProductWorkbookContract.JoinList([]) is null);

Check("da in ne se prebereta", ProductWorkbookContract.ParseYesNo("DA") == true && ProductWorkbookContract.ParseYesNo(" ne ") == false);
Check("nerazumljiva vrednost ni tiho ne", ProductWorkbookContract.ParseYesNo("mogoče") is null);

// Zvezek s skupinami ima dve naslovni vrstici. Brez namigov bi bralnik vzel prvo (skupine) in
// uvoz bi videl stolpce, ki jih ni.
var sampleColumns = columns.Select(column => new WorkbookColumn(column.Header, column.Kind, column.Width, column.Group)).ToList();
var sampleBytes = WorkbookWriter.Write("Izdelki", sampleColumns,
  [[.. columns.Select(column => (object?)(column.FieldKey == ProductWorkbookContract.ItemIdField ? "TEST-1" : null))]],
  ["opomba pod tabelo"]);
var sheet = WorkbookTable.Read(new MemoryStream(sampleBytes), null, ProductWorkbookContract.HeaderHints);
Check("naslovna vrstica je vrstica z imeni stolpcev, ne s skupinami",
  sheet.Headers.Contains("Šifra artikla") && !sheet.Headers.Contains(ProductWorkbookContract.GroupKey));
Check("opomba pod tabelo ne postane vrstica z artiklom",
  sheet.Rows.Count(row => row[1].Length > 0) == 1);

// 245 (Objemke.xlsx): opozorila so kazala eno vrstico prenizko, stolpec pod skupino atributov,
// ki ga šifrant ne pozna, pa je tiho padel med neprepoznane.
Check("številka vrstice je tista iz Excela (skupine + naslovi = prva podatkovna je 3)",
  sheet.RowNumber(0) == 3, $"dobljeno {sheet.RowNumber(0)}");
var gardeHeader = columns.ToList().FindIndex(column => column.FieldKey == "ProductAttribute.Garancija");
Check("skupina stolpca se prebere iz vrstice nad naslovi (združena celica velja v desno)",
  gardeHeader >= 0 && ProductWorkbookContract.IsAttributeGroup(sheet.GroupOf(gardeHeader))
  && sheet.GroupOf(1) == ProductWorkbookContract.GroupKey);
Check("skupina atributov se prepozna", ProductWorkbookContract.IsAttributeGroup("Atributi kategorije — nabor")
  && ProductWorkbookContract.IsAttributeGroup(ProductWorkbookContract.GroupAttributesOutside)
  && !ProductWorkbookContract.IsAttributeGroup(ProductWorkbookContract.GroupWeb));
Check("slike in dokumenti se uvozijo (niso več samo za branje)",
  columns.Where(column => column.FieldKey is ProductWorkbookContract.ImagesField or ProductWorkbookContract.DocumentsField)
    .All(column => column.Target == ProductWorkbookTarget.Pim)
  && columns.Count(column => column.FieldKey is ProductWorkbookContract.ImagesField or ProductWorkbookContract.DocumentsField) == 2);
Check("logična vrednost gre naprej kot 1/0",
  ProductWorkbookContract.BoolValue("da") == "1" && ProductWorkbookContract.BoolValue("X") == "1"
  && ProductWorkbookContract.BoolValue("ne") == "0" && ProductWorkbookContract.BoolValue("mogoče") is null);
Check("D in N (kot v SAOP POST/PATCH) se prebereta in izvoz ju piše",
  ProductWorkbookContract.ParseYesNo("D") == true && ProductWorkbookContract.ParseYesNo("n") == false
  && ProductWorkbookContract.SheetYesNo(true) == "D" && ProductWorkbookContract.SheetYesNo(false) == "N");
Check("ERP polje nosi obliko iz registra (logično polje se prepozna)",
  new ProductWorkbookColumn("g", "Kljukica", "Planning.ExcludeQtyReservation", ProductWorkbookTarget.Saop, ValueFormat: "bool").IsBool
  && !columns.First(column => column.FieldKey == "Product.UoM").IsBool);

Console.WriteLine();
Console.WriteLine("=== Ocena preostanka izvoza v ozadju (brez baze) ===");

// Okno izvozov v kotu strani pove, koliko je se do konca (uporabnik 2026-09-22: »da se ti
// pokaze un bar koliko se ima do konca«). Ocena je dosedanja hitrost pisanja, nic vec.
var writingFrom = new DateTime(2026, 9, 22, 15, 0, 0, DateTimeKind.Utc);
var halfway = new ExportJobState(Guid.NewGuid(), ExportRunStatus.Running, RowCount: 50_000,
  Phase: ProductWorkbookPhase.Writing, TotalRows: 100_000, WritingStartedUtc: writingFrom);
Check("ocena preostanka sledi dosedanji hitrosti", halfway.RemainingSeconds(writingFrom.AddSeconds(60)) == 60,
  halfway.RemainingSeconds(writingFrom.AddSeconds(60))?.ToString());
Check("prve sekunde pisanja so brez ocene", halfway.RemainingSeconds(writingFrom.AddSeconds(2)) is null);
Check("branje seznama je brez ocene", (halfway with { Phase = ProductWorkbookPhase.Listing }).RemainingSeconds(writingFrom.AddSeconds(60)) is null);
Check("koncan izvoz je brez ocene", (halfway with { Status = ExportRunStatus.Completed }).RemainingSeconds(writingFrom.AddSeconds(60)) is null);

Console.WriteLine();
Console.WriteLine("=== Krog izvoz → uvoz nad razvojno bazo ===");

// CLAUDE.md §6: DB del zna na razvojnem računalniku zamrzniti SQL (8 GB RAM). PIM_TEST_BREZ_BAZE=1
// zažene samo pogodbo zgoraj, tudi če povezava obstaja.
if (Environment.GetEnvironmentVariable("PIM_TEST_BREZ_BAZE") == "1")
{
  Console.WriteLine("  Del z bazo PRESKOČEN: PIM_TEST_BREZ_BAZE=1.");
  return Report();
}

var connectionString = Environment.GetEnvironmentVariable("PIM_CONNECTION_STRING") ?? LocalConnectionString();
if (string.IsNullOrWhiteSpace(connectionString))
{
  Console.WriteLine("  Del z bazo PRESKOČEN: povezave PIM ni (PIM_CONNECTION_STRING ali appsettings.Local.json).");
  return Report();
}

var configuration = new ConfigurationBuilder()
  .AddInMemoryCollection(new Dictionary<string, string?> { ["ConnectionStrings:Pim"] = connectionString })
  .Build();

var database = new PimDb(configuration);
var workbench = new ProductWorkbenchService(configuration);
var catalog = new CatalogReadService(database);
var export = new ProductExportService(configuration, workbench);
// Konzolni test nima prijavljene seje, zato zapisovalnim servisom poda izrecno varovalko za
// procese brez uporabnika. Vloge preverja PIM.F10.AuthTests; tu je predmet preizkusa krog
// izvoz -> urejanje -> uvoz delovnega lista.
var guard = PimWriteGuard.Trusted("konzolni test PIM.F10.ProductWorkbookTests");
var Categories = new CategoryTreeService(database, configuration, guard);
var edit = new ProductEditService(configuration, guard);
var categoryMapping = new CategoryMappingService(database, configuration, guard);
var saop = new SaopWriteService(configuration, guard, NullLogger<SaopWriteService>.Instance);
var data = new IntranetDataService(configuration, guard);
var attributeDefinitions = new AttributeMappingService(database, configuration, guard);
var workbook = new ProductWorkbookService(configuration, workbench, export, catalog, edit, categoryMapping, saop, data, attributeDefinitions);

byte[] bytes;
ProductListFilter narrowed = new(null, 0, 25);
try
{
  // Obseg izvoza je cel pogled. Za test ga zozimo z ISKANJEM in ne s seznamom sifer: seznam
  // sifer izbira sele po tem, ko je pogled ze prebran, zato bi vsak zagon vseeno potegnil
  // 20.000 vrstic in test bi meril potrpezljivost, ne pogodbe.
  var sample = await workbench.GetProductListAsync(new ProductListFilter(null, 0, 25));
  if (sample.Rows.Count == 0)
  {
    Console.WriteLine("  Del z bazo PRESKOČEN: v razvojni bazi ni izdelkov.");
    return Report();
  }
  // Iskalni niz je zacetek sifre prvega izdelka; pogled zozi na nekaj vrstic, ne na eno,
  // zato test se vedno vidi vec kot en izdelek.
  var needle = sample.Rows[0].ItemId.Length > 4 ? sample.Rows[0].ItemId[..4] : sample.Rows[0].ItemId;
  narrowed = new ProductListFilter(null, 0, 25, Search: needle);
  bytes = await workbook.BuildAsync(narrowed);
}
catch (Exception failure)
{
  Console.WriteLine("  Del z bazo PRESKOČEN: baza ni dosegljiva (" + failure.GetType().Name + ": " + failure.Message + ").");
  return Report();
}

var exported = WorkbookTable.Read(new MemoryStream(bytes), null, ProductWorkbookContract.HeaderHints);
Check("izvoz ima vrstice", exported.Rows.Count > 0, $"vrstic: {exported.Rows.Count}");
Check("izvoz ima stolpec spletnih strani", exported.Headers.Any(header => WorkbookHeader.Same(header, "Spletne strani")));
Check("izvoz ima stolpec objave na spletu", exported.Headers.Any(header => WorkbookHeader.Same(header, "Objava na spletu")));
Check("izvoz ima stolpec kategorij vsaj ene strani",
  exported.Headers.Any(header => header.StartsWith("Kategorije — ", StringComparison.Ordinal)));

var sites = await workbook.ActiveWebSitesAsync();
Check("register spletnih strani ni prazen", sites.Count > 0, string.Join(", ", sites.Select(site => site.Name)));

// --- Pojavno okno »Stolpci«: izbira posameznih polj, ne le skupin ----------------------
// DescribeColumnsAsync je vir resnice za okno na /izdelki; ce se razide z dejanskim izvozom
// (BuildAsync brez omejitve), bi uporabnik v oknu videl polja, ki jih datoteka sploh ne dobi,
// ali obratno.
var described = await workbook.DescribeColumnsAsync(narrowed);
var describedHeaders = described.Select(column => column.Header).ToHashSet(StringComparer.Ordinal);
var exportedHeaderSet = exported.Headers.ToHashSet(StringComparer.Ordinal);
Check("seznam polj za pojavno okno ustreza dejanskemu izvozu (brez omejitve)",
  describedHeaders.SetEquals(exportedHeaderSet),
  $"samo v oknu: {string.Join(", ", describedHeaders.Except(exportedHeaderSet).Take(5))}; "
  + $"samo v izvozu: {string.Join(", ", exportedHeaderSet.Except(describedHeaders).Take(5))}");

// Izbira enega samega polja (mimo kljuca) mora dati datoteko s kljucem in natanko tem poljem —
// to je pogodba, na kateri sloni pojavno okno (ProductWorkbookService.BuildToAsync/Included).
var singleField = described.FirstOrDefault(column => column.Group == ProductWorkbookContract.GroupState)
  ?? described.First();
var narrowExport = WorkbookTable.Read(
  new MemoryStream(await workbook.BuildAsync(narrowed, includeFieldKeys: new HashSet<string> { singleField.FieldKey })),
  null, ProductWorkbookContract.HeaderHints);
var expectedNarrowHeaders = new HashSet<string>(StringComparer.Ordinal)
  { "Podjetje", "Šifra artikla", singleField.Header };
Check($"izbira enega polja ({singleField.Header}) da kljuc plus natanko to polje",
  narrowExport.Headers.ToHashSet(StringComparer.Ordinal).SetEquals(expectedNarrowHeaders),
  string.Join(", ", narrowExport.Headers));

// --- Izvoz v ozadju pripada uporabniku ---------------------------------------------------
// Uporabnik 2026-09-22 je kliknil »Izvozi«, takoj za tem »Uvozi«: gradnja je tekla naprej, a jo
// je poznala samo zapuscena stran — ne napredka ne prenosa. Opravilo zato nosi lastnika in ga
// okno izvozov najde z vsake strani (GET /izvoz/opravila). Tu tece pravi izvoz skozi vrata.
{
  var services = new Microsoft.Extensions.DependencyInjection.ServiceCollection();
  Microsoft.Extensions.DependencyInjection.ServiceCollectionServiceExtensions.AddSingleton(services, workbook);
  using var provider = Microsoft.Extensions.DependencyInjection.ServiceCollectionContainerBuilderExtensions.BuildServiceProvider(services);
  using var store = new ExportResultStore();
  var exports = new ExportJobService(
    Microsoft.Extensions.DependencyInjection.ServiceProviderServiceExtensions.GetRequiredService<Microsoft.Extensions.DependencyInjection.IServiceScopeFactory>(provider),
    store, new HeavyWorkGate(configuration), NullLogger<ExportJobService>.Instance);

  var jobId = Guid.NewGuid();
  var states = new List<ExportJobState>();
  var finished = new TaskCompletionSource<ExportJobState>(TaskCreationOptions.RunContinuationsAsynchronously);
  exports.Changed += state =>
  {
    if (state.JobId != jobId) return;
    lock (states) states.Add(state);
    if (!state.IsActive) finished.TrySetResult(state);
  };
  exports.StartWorkbookExport(jobId, "ana", "preizkus.xlsx", narrowed, selection: null);
  Check("izvoz je viden lastniku takoj ob zagonu, preden zacne", exports.ForOwner("ana").Any(job => job.JobId == jobId && job.IsActive));

  var done = await finished.Task.WaitAsync(TimeSpan.FromMinutes(5));
  Check("izvoz v ozadju se konca", done.Status == ExportRunStatus.Completed, done.Error);
  List<ExportJobState> seen;
  lock (states) seen = states.ToList();
  Check("napredek pove branje seznama z imenovalcem",
    seen.Any(state => state.Phase == ProductWorkbookPhase.Listing && state.TotalRows > 0));
  Check("napredek pove pisanje vrstic od vseh",
    seen.Any(state => state.Phase == ProductWorkbookPhase.Writing && state.TotalRows == done.RowCount && state.WritingStartedUtc is not null));
  Check("po koncu ni vec sporocila »tece« (napredek ne prehiti konca)", seen.Last().Status == ExportRunStatus.Completed);
  Check("koncano stanje nosi lastnika, cas in zeton",
    done.Owner == "ana" && done.FinishedUtc >= done.StartedUtc && done.DownloadToken is not null);
  Check("izvoz vidi samo lastnik", exports.ForOwner("ANA").Count == 1 && exports.ForOwner("bor").Count == 0);
  Check("tuji uporabnik obvestila ne more zapreti", !exports.Dismiss(jobId, "bor"));
  // Prenos, ki ga odpre klik (GET /izvoz/zvezek), caka na konec gradnje in dobi koncano stanje;
  // tujemu uporabniku ga ne da. HTTP pot (glava takoj, preklic, prekinitev ob napaki) je
  // ExportDownloadEndpoint.
  Check("odprt prenos tujega uporabnika ne dobi izvoza", await exports.WaitForBrowserAsync(jobId, "bor", CancellationToken.None) is null);
  Check("odprt prenos dobi koncan izvoz", (await exports.WaitForBrowserAsync(jobId, "ana", CancellationToken.None))?.Status == ExportRunStatus.Completed);
  exports.MarkDownloaded(done.DownloadToken!.Value);
  Check("prevzem datoteke se zabelezi", exports.Get(jobId)?.Downloaded == true);
  Check("lastnik obvestilo zapre in ga ni vec", exports.Dismiss(jobId, "ana") && exports.ForOwner("ana").Count == 0);
  if (store.TryGet(done.DownloadToken.Value, out var producedPath, out _, out _)) File.Delete(producedPath);

  // Preklic: uporabnik 2026-09-23 je po pomoti kliknil »Izvozi« na celem pogledu (180.000 vrstic)
  // in ga ni mogel ustaviti. Tu tece cel pogled (brez iskanja) in se prekliče ob prvem napredku —
  // koncati se mora hitro, kot preklican, brez zetona in brez zacasne datoteke.
  var cancelId = Guid.NewGuid();
  var canceled = new TaskCompletionSource<ExportJobState>(TaskCreationOptions.RunContinuationsAsynchronously);
  var cancelRequested = 0;
  exports.Changed += state =>
  {
    if (state.JobId != cancelId) return;
    if (state.Status == ExportRunStatus.Running && state.TotalRows > 0 && Interlocked.Exchange(ref cancelRequested, 1) == 0)
    {
      Check("tuji uporabnik izvoza ne more preklicati", !exports.Cancel(cancelId, "bor"));
      Check("lastnik tekoč izvoz prekliče", exports.Cancel(cancelId, "ana"));
    }
    if (!state.IsActive) canceled.TrySetResult(state);
  };
  var exportFolder = Path.Combine(Path.GetTempPath(), "PIM.Intranet", "izvozi");
  var tempBefore = Directory.GetFiles(exportFolder).ToHashSet();
  exports.StartWorkbookExport(cancelId, "ana", "preklic.xlsx", new ProductListFilter(null, 0, 25), selection: null);
  var stopwatch = System.Diagnostics.Stopwatch.StartNew();
  var afterCancel = await canceled.Task.WaitAsync(TimeSpan.FromMinutes(5));
  Check("preklican izvoz se konca kot preklican, ne kot napaka", afterCancel.Status == ExportRunStatus.Canceled,
    $"{afterCancel.Status} {afterCancel.Error}");
  Check("preklican izvoz nima datoteke za prenos", afterCancel.DownloadToken is null);
  Check("preklican izvoz se ustavi hitro", stopwatch.Elapsed < TimeSpan.FromMinutes(1), stopwatch.Elapsed.ToString());
  Check("koncanega izvoza ni mogoce preklicati", !exports.Cancel(cancelId, "ana"));
  Check("odprt prenos preklicanega izvoza ne dobi datoteke",
    (await exports.WaitForBrowserAsync(cancelId, "ana", CancellationToken.None))?.Status == ExportRunStatus.Canceled);
  Check("obvestilo o preklicu se da zapreti", exports.Dismiss(cancelId, "ana"));
  Check("preklic ne pusti zacasne datoteke",
    !Directory.GetFiles(exportFolder).Except(tempBefore).Any());
}

// --- Izvoz po kategoriji ----------------------------------------------------------------
// Kategorija mora zoziti dvoje hkrati: vrstice (izdelki te kategorije in njenih potomcev) in
// stolpce atributov (nabor kategorije). Prej je vsak izdelek dobil vseh 148 stolpcev.
var categoryTree = await Categories.GetTreeCodesAsync();
var pick = new List<CategoryTreeService.CategoryPickRow>();
foreach (var treeCode in categoryTree) pick.AddRange(await Categories.GetCategoryPickerAsync(treeCode));
var chosen = pick.Where(node => node.AttributeCount > 0 && node.ProductCount > 0)
  .OrderByDescending(node => node.AttributeCount).ThenBy(node => node.ProductCount).FirstOrDefault();

if (chosen is null) Console.WriteLine("  (nobena kategorija nima nabora in izdelkov; preskok preizkusa po kategoriji)");
else
{
  Console.WriteLine($"  (kategorija »{chosen.CategoryPath}«: {chosen.ProductCount:N0} izdelkov, {chosen.AttributeCount:N0} atributov v naboru)");
  var byCategory = new ProductListFilter(null, 0, 25,
    CategoryTreeCode: chosen.CategoryTreeCode, CategoryCode: chosen.CategoryCode);

  var listed = await workbench.GetProductListAsync(byCategory with { Take = 5 });
  Check("filter po kategoriji zoži seznam",
    listed.TotalCount > 0 && listed.TotalCount < 196_000, $"vrstic {listed.TotalCount:N0}");

  var categorySheet = WorkbookTable.Read(
    new MemoryStream(await workbook.BuildAsync(byCategory)), null, ProductWorkbookContract.HeaderHints);

  Check("list po kategoriji ima vrstice", categorySheet.Rows.Count > 0, $"vrstic {categorySheet.Rows.Count}");

  var setAttributes = await AttributeSetNamesAsync(database, chosen.CategoryTreeCode, chosen.CategoryCode);
  var missing = setAttributes.Where(name => !categorySheet.Headers.Any(header => WorkbookHeader.Same(header, name))).ToList();
  Check("vsak atribut iz nabora kategorije ima stolpec", missing.Count == 0,
    missing.Count == 0 ? null : string.Join(", ", missing.Take(5)));

  // Stolpec mora biti tudi tam, kjer vrednosti se ni — ravno ta je razlog za izvoz.
  var praznih = setAttributes.Count(name =>
  {
    var index = categorySheet.Headers.ToList().FindIndex(header => WorkbookHeader.Same(header, name));
    return index >= 0 && categorySheet.Rows.All(row => row[index].Length == 0);
  });
  Console.WriteLine($"  (od {setAttributes.Count} atributov nabora jih je {praznih} praznih pri vseh izvoženih izdelkih)");

  var untouchedCategory = await workbook.PreviewAsync(new MemoryStream(await workbook.BuildAsync(byCategory)), null);
  Check("tudi list po kategoriji se vrne brez sprememb", untouchedCategory.Rows.Count == 0,
    $"vrstic s spremembo: {untouchedCategory.Rows.Count}");
  Check("noben stolpec lista po kategoriji ne ostane neprepoznan",
    untouchedCategory.UnknownColumns.Count == 0, string.Join(", ", untouchedCategory.UnknownColumns));
}

// Nespremenjena datoteka ne sme uvoziti nicesar. To je pogoj, brez katerega bi uvoz vsakic
// napolnil odhodno vrsto z niclami sprememb.
var untouched = await workbook.PreviewAsync(new MemoryStream(bytes), null);
if (untouched.Rows.Count > 0)
  foreach (var group in untouched.Rows.SelectMany(row => row.PimValues.Concat(row.SaopValues))
    .GroupBy(pair => pair.Key).OrderByDescending(group => group.Count()).Take(5))
    Console.WriteLine($"  (razlika brez urejanja) {group.Key}: {group.Count()}x, primer '{group.First().Value}'");
Check("nespremenjena datoteka ne prinese nobene spremembe",
  untouched.Rows.Count == 0,
  $"vrstic s spremembo: {untouched.Rows.Count}; prva: {(untouched.Rows.Count > 0 ? Describe(untouched.Rows[0]) : "-")}");
Check("noben stolpec izvoza ne ostane neprepoznan",
  untouched.UnknownColumns.Count == 0, string.Join(", ", untouched.UnknownColumns));

// Spremenjena celica se mora vrniti kot natanko ena sprememba — in nic drugega.
var titleHeader = exported.Headers.FirstOrDefault(header => WorkbookHeader.Same(header, "Spletni naziv (sl)"));
if (titleHeader is null) Console.WriteLine("  (stolpca »Spletni naziv (sl)« ni; preskok preizkusa ene spremembe)");
else
{
  var titleIndex = exported.Headers.ToList().FindIndex(header => WorkbookHeader.Same(header, titleHeader));
  // Za zapis vzamemo izdelek, ki spletni naziv ze ima: prazne celice uvoz namenoma ne bere,
  // zato izdelka brez naziva po testu ne bi bilo mogoce vrniti v prejsnje stanje.
  var target = exported.Rows.Select((row, index) => (row, index))
    .FirstOrDefault(pair => pair.row[titleIndex].Length > 0);

  var probe = EditCell(exported, titleIndex, target.index, "PREIZKUS " + DateTime.UtcNow.Ticks);
  var preview = await workbook.PreviewAsync(new MemoryStream(probe), null);
  Check("ena spremenjena celica da eno spremembo",
    preview.Rows.Count == 1 && preview.PimChangeCount == 1 && preview.SaopChangeCount == 0,
    $"vrstic {preview.Rows.Count}, PIM {preview.PimChangeCount}, SAOP {preview.SaopChangeCount}");
  Check("sprememba nosi kodo spletnega naziva",
    preview.Rows.Count == 1 && preview.Rows[0].PimValues.ContainsKey("ProductText.WEB_TITLE.sl"));

  if (target.row is null) Console.WriteLine("  (noben izvozen izdelek nima spletnega naziva; preskok zapisa)");
  // 124: zapis samo, kadar predogled nosi natanko eno spremembo v PIM. Sicer je zapis 30. 9. na
  // razvojno bazo prepisal enoto mere 455 artiklom in jih poslal v vrsto za SAOP.
  else if (!(preview.Rows.Count == 1 && preview.PimChangeCount == 1 && preview.SaopChangeCount == 0))
    Console.WriteLine("  (predogled nima natanko ene spremembe; zapis v bazo preskočen, da test ne pokvari podatkov)");
  else
  {
    // Zapis v razvojno bazo in vrnitev v prejsnje stanje. AGENTS.md §4.1 dovoli testu pisanje
    // v razvojno bazo PIM; zato se stara vrednost najprej prebere in na koncu vrne nazaj.
    var original = target.row[titleIndex];
    var marker = "PREIZKUS " + DateTime.UtcNow.Ticks;
    var itemId = target.row[exported.Headers.ToList().FindIndex(header => WorkbookHeader.Same(header, "Šifra artikla"))];
    try
    {
      var write = await workbook.PreviewAsync(new MemoryStream(EditCell(exported, titleIndex, target.index, marker)), null);
      // Tudi drugi predogled se preveri, preden gre karkoli v bazo ali v vrsto za SAOP.
      var outcome = write.Rows.Count == 1 && write.SaopChangeCount == 0
        ? await workbook.ApplyAsync(write, "test:PIM.F10.ProductWorkbookTests", "preizkus delovnega lista")
        : new ProductWorkbookOutcome(write.Rows.Count, 0, write.SaopChangeCount, 0, 0, [], ["zapis preskočen: predogled ni ena sprememba v PIM"]);
      Check("uvoz zapiše natanko en izdelek",
        outcome.RowsTouched == 1 && outcome.PimChanges == 1 && outcome.SaopQueued == 0,
        $"izdelkov {outcome.RowsTouched}, PIM {outcome.PimChanges}, SAOP {outcome.SaopQueued}; {string.Join("; ", outcome.Problems)}");

      var after = await StoredTitleAsync(database, itemId);
      Check("nova vrednost je v katalogu", after == marker, $"'{after}'");
    }
    finally
    {
      var restore = await workbook.PreviewAsync(
        new MemoryStream(EditCell(exported, titleIndex, target.index, original)), null);
      if (restore.Rows.Count > 0 && restore.SaopChangeCount == 0)
        await workbook.ApplyAsync(restore, "test:PIM.F10.ProductWorkbookTests", "vrnitev v prejšnje stanje");
      var back = await StoredTitleAsync(database, itemId);
      Check("stara vrednost je vrnjena", back == original, $"'{back}' namesto '{original}'");
    }
  }
}

return Report();

int Report()
{
  Console.WriteLine();
  if (failures.Count == 0) { Console.WriteLine("F10 delovni list izdelkov: vse OK."); return 0; }
  Console.WriteLine($"F10 delovni list izdelkov: PADLO {failures.Count}:");
  foreach (var failure in failures) Console.WriteLine("  - " + failure);
  return 1;
}

// Slovenska imena atributov iz ucinkovitega nabora kategorije. V naboru je stabilna koda,
// v canon.ProductAttribute pa slovensko ime; stolpec lista nosi ime, zato ga tudi tu iscemo.
static async Task<IReadOnlyList<string>> AttributeSetNamesAsync(PimDb database, string tree, string category)
{
  var rows = await database.QueryAsync(
    """
    SELECT AttributeName = COALESCE(translation.Name, effective.AttributeCode)
    FROM canon.CategoryAttributeEffective(@Tree, @Category) AS effective
    LEFT JOIN canon.AttributeTranslation AS translation
      ON translation.AttributeCode = effective.AttributeCode AND translation.LanguageCode = N'sl'
    WHERE effective.Level <> N'EXCLUDED';
    """,
    reader => PimDb.TextOrEmpty(reader, "AttributeName"),
    command =>
    {
      command.Parameters.AddWithValue("@Tree", tree);
      command.Parameters.AddWithValue("@Category", category);
    });
  return rows;
}

// Preverjanje gre naravnost v katalog in ne skozi nov izvoz: izvoz vedno prebere cel pogled
// (do 20.000 vrstic) in bi test iz sekund raztegnil v minute, dokazal pa bi isto.
static async Task<string?> StoredTitleAsync(PimDb database, string itemId)
{
  var rows = await database.QueryAsync(
    """
    SELECT textValue.Value
    FROM canon.ProductText AS textValue
    INNER JOIN canon.Product AS product ON product.ProductId = textValue.ProductId
    WHERE product.ItemID = @ItemId AND textValue.TextType = N'WEB_TITLE' AND textValue.Lang = N'sl';
    """,
    reader => PimDb.Text(reader, "Value"),
    command => command.Parameters.AddWithValue("@ItemId", itemId));
  return rows.FirstOrDefault();
}

static string Describe(ProductWorkbookRowChange row) =>
  $"{row.ItemId}: " + string.Join(", ", row.PimValues.Concat(row.SaopValues).Select(pair => pair.Key + "=" + pair.Value));

// Zamenja eno celico v ze prebranem zvezku tako, da ga zapise znova. Pisati v XML zvezka
// neposredno bi pomenilo se en zapisovalnik xlsx v testu; tega ni treba.
static byte[] EditCell(WorkbookSheet sheet, int column, int row, string value)
{
  var columns = sheet.Headers.Select(name => new WorkbookColumn(name)).ToList();
  var rows = sheet.Rows.Select((cells, position) =>
  {
    var copy = cells.Select(cell => (object?)(cell.Length == 0 ? null : cell)).ToList();
    if (position == row) copy[column] = value;
    return (IReadOnlyList<object?>)copy;
  }).ToList();
  return WorkbookWriter.Write("Izdelki", columns, rows);
}

static string? LocalConnectionString()
{
  var directory = new DirectoryInfo(Directory.GetCurrentDirectory());
  while (directory is not null)
  {
    var candidate = Path.Combine(directory.FullName, "appsettings.Local.json");
    if (File.Exists(candidate))
    {
      using var document = JsonDocument.Parse(File.ReadAllText(candidate));
      if (document.RootElement.TryGetProperty("ConnectionStrings", out var strings)
        && strings.TryGetProperty("Pim", out var pim))
        return pim.GetString();
    }
    directory = directory.Parent;
  }
  return null;
}
