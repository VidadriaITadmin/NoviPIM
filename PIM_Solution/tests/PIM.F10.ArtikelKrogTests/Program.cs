using System.Globalization;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using PIM.Intranet.Services;
using PIM.Operations;

// Krog delovnega lista za EN artikel, stolpec za stolpcem (David 2026-09-24: »ne sme se zgodit,
// da je stolpec v uvozu pa ga izpolnijo pa ne gre not«).
//
// Faza »predogled« (privzeto): izvozi artikel, nato vsak stolpec posebej spremeni in pogleda, ali
// predogled uvoza spremembo zazna (ali jo vsaj izrecno zavrne). Tiho spregledan stolpec je napaka.
// V bazo ne piše nič.
//
// Argumenti: [podjetje] [šifra]; privzeto 3 BA.BA09.00511 (Vidadria, S2, slike, kategorije).
var organizationId = args.Length > 0 ? int.Parse(args[0], CultureInfo.InvariantCulture) : 3;
var itemId = args.Length > 1 ? args[1] : "BA.BA09.00511";

var connectionString = Environment.GetEnvironmentVariable("PIM_CONNECTION_STRING")
  ?? throw new InvalidOperationException("Nastavi PIM_CONNECTION_STRING (razvojna baza).");
var configuration = new ConfigurationBuilder()
  .AddInMemoryCollection(new Dictionary<string, string?> { ["ConnectionStrings:Pim"] = connectionString })
  .Build();

var database = new PimDb(configuration);
var workbench = new ProductWorkbenchService(configuration);
var catalog = new CatalogReadService(database);
var export = new ProductExportService(configuration, workbench);
var guard = PimWriteGuard.Trusted("konzolni test PIM.F10.ArtikelKrogTests");
var workbook = new ProductWorkbookService(configuration, workbench, export, catalog,
  new ProductEditService(configuration, guard), new CategoryMappingService(database, configuration, guard),
  new SaopWriteService(configuration, guard, NullLogger<SaopWriteService>.Instance),
  new IntranetDataService(configuration, guard), new AttributeMappingService(database, configuration, guard));

// »datoteka-uvoz <pot> [zapisi]«: predogled (in po želji zapis) poljubne datoteke z isto potjo kot stran /izdelki/uvoz.
if (args.Contains("datoteka-uvoz"))
{
  var path = args[Array.IndexOf(args, "datoteka-uvoz") + 1];
  await using var stream = File.OpenRead(path);
  using var memory = new MemoryStream();
  await stream.CopyToAsync(memory);
  memory.Position = 0;
  var started = DateTime.UtcNow;
  var filePreview = await workbook.PreviewAsync(memory, organizationId);
  Console.WriteLine($"Predogled ({(DateTime.UtcNow - started).TotalSeconds:N0} s): vrstic s spremembo {filePreview.Rows.Count:N0}, PIM {filePreview.PimChangeCount:N0}, SAOP {filePreview.SaopChangeCount:N0}");
  Console.WriteLine("Neprepoznani stolpci: " + string.Join(", ", filePreview.UnknownColumns));
  Console.WriteLine("Samo za branje: " + string.Join(", ", filePreview.ReadOnlyColumns));
  Console.WriteLine("Novi atributi: " + string.Join(", ", filePreview.NewAttributes ?? []));
  foreach (var missing in filePreview.MissingCategories ?? [])
    Console.WriteLine($"Manjkajoča kategorija: {missing.SiteName} »{missing.Path}« ({missing.Items.Count} art.), predlog: {missing.Suggestion ?? "-"}");
  foreach (var group in filePreview.Rows.SelectMany(line => line.PimValues.Keys.Concat(line.SaopValues.Keys)).GroupBy(key => key).OrderByDescending(group => group.Count()))
    Console.WriteLine($"  polje {group.Key}: {group.Count():N0}");
  foreach (var problem in filePreview.Problems.Take(80)) Console.WriteLine("  opozorilo: " + Short(problem, 400));
  if (filePreview.Problems.Count > 80) Console.WriteLine($"  … in še {filePreview.Problems.Count - 80} opozoril");
  if (!args.Contains("zapisi")) return 0;
  var result = await workbook.ApplyAsync(filePreview, "uvoz: " + Path.GetFileName(path), Path.GetFileName(path),
    new Progress<string>(text => Console.WriteLine("  … " + text)));
  Console.WriteLine($"Zapis: izdelkov {result.RowsTouched:N0}, PIM {result.PimChanges:N0}, ERP v PIM {result.ErpWritten:N0}, v vrsti SAOP {result.SaopQueued:N0} (že v vrsti {result.SaopDuplicates:N0}, zavrnjeno {result.SaopRejected:N0}), skupine {string.Join(", ", result.OutboundBatchIds)}");
  foreach (var problem in result.Problems.Take(80)) Console.WriteLine("  težava: " + Short(problem, 400));
  if (result.Problems.Count > 80) Console.WriteLine($"  … in še {result.Problems.Count - 80} težav");
  return 0;
}

var filter = new ProductListFilter(organizationId, 0, 25, Search: itemId);
var bytes = await workbook.BuildAsync(filter);
var sheet = WorkbookTable.Read(new MemoryStream(bytes), null, ProductWorkbookContract.HeaderHints);
var itemColumn = sheet.Headers.ToList().FindIndex(header => WorkbookHeader.Same(header, "Šifra artikla"));
var rowIndex = sheet.Rows.ToList().FindIndex(row => string.Equals(row[itemColumn], itemId, StringComparison.OrdinalIgnoreCase));
if (rowIndex < 0) { Console.WriteLine($"Artikla {itemId} ni v izvozu."); return 1; }
var row = sheet.Rows[rowIndex];

Console.WriteLine($"=== Izvoz {itemId} (podjetje {organizationId}): {sheet.Headers.Count} stolpcev ===");
for (var index = 0; index < sheet.Headers.Count; index++)
  if (row[index].Length > 0 || !sheet.GroupOf(index).StartsWith("Atributi", StringComparison.Ordinal))
    Console.WriteLine($"  [{sheet.GroupOf(index)}] {sheet.Headers[index]} = {Short(row[index])}");

var untouched = await workbook.PreviewAsync(new MemoryStream(Rewrite(sheet, rowIndex, null, null)), organizationId);
Console.WriteLine($"\nNespremenjena datoteka: {untouched.Rows.Count} vrstic s spremembo, neprepoznani: {string.Join(", ", untouched.UnknownColumns)}");
foreach (var change in untouched.Rows)
  Console.WriteLine($"  !! {change.ItemId}: " + string.Join("; ", change.PimValues.Concat(change.SaopValues).Select(pair => $"{pair.Key}={Short(pair.Value)}")));
foreach (var problem in untouched.Problems) Console.WriteLine("  opozorilo: " + problem);

if (args.Contains("zapis")) return await WriteRoundAsync();
if (args.Contains("primerjaj"))
{
  // Po ročnem uvozu: sveži izvoz artikla proti datoteki, ki je bila uvožena — stolpec za stolpcem.
  var uploaded = WorkbookTable.Read(File.OpenRead(args[Array.IndexOf(args, "primerjaj") + 1]), null, ProductWorkbookContract.HeaderHints);
  var wanted = uploaded.Rows[0];
  var ok = 0; var differ = new List<string>();
  for (var index = 0; index < uploaded.Headers.Count; index++)
  {
    var header = uploaded.Headers[index];
    var group = uploaded.GroupOf(index);
    if (group == ProductWorkbookContract.GroupKey || group.StartsWith("Stanje", StringComparison.Ordinal)) continue;
    var at = sheet.Headers.ToList().FindIndex(name => WorkbookHeader.Same(name, header));
    var now = at >= 0 ? row[at] : "(ni stolpca v izvozu)";
    var expect = wanted[index];
    bool Same(string left, string right) => Normalize(left) == Normalize(right)
      || (decimal.TryParse(left.Replace(',', '.'), NumberStyles.Number, CultureInfo.InvariantCulture, out var a)
        && decimal.TryParse(right.Replace(',', '.'), NumberStyles.Number, CultureInfo.InvariantCulture, out var b) && a == b);
    if (Same(now, expect)) ok++;
    else differ.Add($"  [{group}] {header}: v datoteki '{Short(expect, 70)}', v PIM '{Short(now, 70)}'");
  }
  Console.WriteLine($"Enakih: {ok}, različnih: {differ.Count}");
  differ.ForEach(Console.WriteLine);
  return 0;
}
if (args.Contains("datoteka")) return await WriteTestFilesAsync(args[Array.IndexOf(args, "datoteka") + 1]);

Console.WriteLine("\n=== Vsak stolpec posebej: ali predogled zazna spremembo ===");
var silent = new List<string>();
for (var index = 0; index < sheet.Headers.Count; index++)
{
  var header = sheet.Headers[index];
  var group = sheet.GroupOf(index);
  if (group == ProductWorkbookContract.GroupKey || group.StartsWith("Stanje", StringComparison.Ordinal)) continue;
  // Atributi: preizkusi tiste z vrednostjo in prvih nekaj praznih (vsi so ista pot).
  if (group.StartsWith("Atributi", StringComparison.Ordinal) && row[index].Length == 0 && index % 25 != 0) continue;

  var changed = Different(header, row[index]);
  var preview = await workbook.PreviewAsync(new MemoryStream(Rewrite(sheet, rowIndex, index, changed)), organizationId);
  var keys = preview.Rows.SelectMany(change => change.PimValues.Keys.Select(key => "PIM " + key)
    .Concat(change.SaopValues.Keys.Select(key => "SAOP " + key))).ToList();
  var readOnly = preview.ReadOnlyColumns.Any(name => WorkbookHeader.Same(name, header));
  var problems = preview.Problems.Where(problem => !untouched.Problems.Contains(problem)).ToList();
  var verdict = keys.Count > 0 ? "zazna: " + string.Join(", ", keys) + (problems.Count > 0 ? " | opozori: " + Short(problems[0], 160) : " | brez opozorila")
    : readOnly ? "samo za branje"
    : problems.Count > 0 ? "zavrne: " + Short(problems[0], 140)
    : "TIHO SPREGLEDANO";
  if (keys.Count == 0 && !readOnly && problems.Count == 0) silent.Add(header);
  foreach (var missing in preview.MissingCategories ?? [])
    Console.WriteLine($"    manjkajoča kategorija: {missing.SiteName} »{missing.Path}« ({missing.Items.Count}), predlog: {missing.Suggestion ?? "-"}, ustvari: {missing.CanCreate}");
  Console.WriteLine($"  [{group}] {header}: '{Short(row[index], 30)}' -> '{Short(changed, 30)}' => {verdict}");
}

Console.WriteLine();
Console.WriteLine(silent.Count == 0 ? "Noben stolpec ni tiho spregledan." : "TIHO SPREGLEDANI: " + string.Join(", ", silent));
return silent.Count == 0 ? 0 : 1;

// Faza »zapis«: ena datoteka z več spremembami iz vsake skupine, pravi uvoz, ponovni izvoz za
// preverbo, nato vrnitev v prejšnje stanje in preklic skupin SAOP (da ne čakajo na odobritev).
async Task<int> WriteRoundAsync()
{
  var edits = new Dictionary<string, string>
  {
    ["Aktiven"] = "N",
    ["Neto teža na enoto"] = "0.05",
    ["S koda"] = "S3",
    ["Kategorije — Videlektro"] = "Razsvetljava > Sijalke > LED sijalke E27",
    ["Spletni naziv (sl)"] = row[Index("Spletni naziv (sl)")] + " PREIZKUS",
    ["Slike"] = row[Index("Slike")] + " | https://cdn.braytron.center/images/BA09-00511-5.webp",
    ["Kategorije — Svetila.si"] = "Svetlobni viri in dodatki > E14",
    ["Spletne strani"] = "Videlektro | Svetila.si",
    ["Premer"] = "38 mm",
    ["Spletni naziv (it)"] = "PREIZKUS it",
  };
  // Pričakovano stanje po uvozu, kadar se razlikuje od vpisanega (enota gre v svoj atribut).
  var expected = new Dictionary<string, string>(edits)
  {
    ["Spletne strani"] = "Svetila.si | Videlektro",
  };
  if (Index("Dolžina paketa I") >= 0 && Index("Enota dolžine paketa I") >= 0)
  {
    edits["Dolžina paketa I"] = "45 mm";
    expected["Dolžina paketa I"] = "45";
    expected["Enota dolžine paketa I"] = "mm";
  }
  var failures = new List<string>();
  var batches = new List<long>();
  try
  {
    var file = edits.Aggregate(sheet, (current, edit) => With(current, Index(edit.Key), edit.Value));
    var preview = await workbook.PreviewAsync(new MemoryStream(Rewrite(file, rowIndex, null, null)), organizationId);
    Console.WriteLine($"\nPredogled: PIM {preview.PimChangeCount}, SAOP {preview.SaopChangeCount}");
    foreach (var problem in preview.Problems) Console.WriteLine("  opozorilo: " + problem);
    var outcome = await workbook.ApplyAsync(preview, "test:PIM.F10.ArtikelKrogTests", "krog enega artikla");
    batches.AddRange(outcome.OutboundBatchIds);
    Console.WriteLine($"Uvoz: izdelkov {outcome.RowsTouched}, PIM {outcome.PimChanges}, ERP v PIM {outcome.ErpWritten}, SAOP v vrsti {outcome.SaopQueued} (skupine {string.Join(",", outcome.OutboundBatchIds)}), slik +{outcome.MediaAdded}/-{outcome.MediaRemoved}");
    foreach (var problem in outcome.Problems) Console.WriteLine("  težava: " + problem);

    var again = WorkbookTable.Read(new MemoryStream(await workbook.BuildAsync(filter)), null, ProductWorkbookContract.HeaderHints);
    var after = again.Rows.First(line => string.Equals(line[itemColumn], itemId, StringComparison.OrdinalIgnoreCase));
    foreach (var (header, wanted) in expected)
    {
      var stored = after[again.Headers.ToList().FindIndex(name => WorkbookHeader.Same(name, header))];
      var same = Normalize(stored) == Normalize(wanted);
      Console.WriteLine($"  {(same ? "OK  " : "FAIL")} {header}: v PIM '{Short(stored, 90)}'");
      if (!same) failures.Add(header);
    }
    var queued = await Rows(connectionString, """
      SELECT m.Status, m.OutboundBatchId, m.FieldSummary, m.PayloadJson
      FROM out.OutboxMessage m WHERE m.OutboundBatchId IN (SELECT CONVERT(bigint, value) FROM OPENJSON(@Ids));
      """, ("@Ids", System.Text.Json.JsonSerializer.Serialize(batches)));
    foreach (var message in queued)
      Console.WriteLine($"  vrsta SAOP: {message["Status"]}, skupina {message["OutboundBatchId"]}, polja: {message["FieldSummary"]}\n    {Short(Convert.ToString(message["PayloadJson"]) ?? "", 400)}");
    if (queued.Count == 0) failures.Add("ni sporočila v vrsti SAOP");

    // Aktivnost (David 2026-09-24): po uvozu »Aktiven = N« mora biti artikel neaktiven v PIM
    // (kartica bere canon.Product), v stanju za katalog.csv in v vrsti SAOP (zgoraj).
    var state = await Rows(connectionString, """
      SELECT p.ProductId, p.IsActive FROM canon.Product p WHERE p.OrganizationId = @Org AND p.ItemID = @Item;
      """, ("@Org", organizationId), ("@Item", itemId));
    var productId = Convert.ToInt64(state[0]["ProductId"]);
    Console.WriteLine($"  kartica (canon.Product.IsActive): {state[0]["IsActive"]}");
    if (Convert.ToBoolean(state[0]["IsActive"])) failures.Add("aktivnost na kartici");
    var web = await Rows(connectionString, "EXEC intranet.GetProductWebExportState @ProductId = @Id;", ("@Id", productId));
    if (web.Count > 0)
      Console.WriteLine("  katalog.csv: " + string.Join(", ", web[0].Where(pair => pair.Key is "WebExportState" or "IsWebReady" or "IsActive" or "Reason" or "ExportReason")
        .Select(pair => $"{pair.Key}={pair.Value}")));
  }
  finally
  {
    // Prvotna datoteka vrne vse prvotne vrednosti; kar je bilo prej prazno, izprazni »-« (prazna
    // celica pomeni »ne dotikaj se«). Slike se vrnejo, ker je celica cel seznam.
    var original = edits.Keys.Concat(expected.Keys).Distinct()
      .Where(header => Index(header) >= 0 && row[Index(header)].Length == 0)
      .Aggregate(sheet, (current, header) => With(current, Index(header), "-"));
    var restore = await workbook.PreviewAsync(new MemoryStream(Rewrite(original, rowIndex, null, null)), organizationId);
    var back = await workbook.ApplyAsync(restore, "test:PIM.F10.ArtikelKrogTests", "vrnitev po krogu enega artikla");
    batches.AddRange(back.OutboundBatchIds);
    Console.WriteLine($"\nVrnitev: PIM {back.PimChanges}, ERP {back.ErpWritten}, slik -{back.MediaRemoved}");
    foreach (var batch in batches.Distinct())
      await Rows(connectionString, "EXEC out.CancelOutboundBatch @OutboundBatchId = @Id, @Actor = N'test:PIM.F10.ArtikelKrogTests';", ("@Id", batch));
    Console.WriteLine($"Preklicane skupine SAOP: {string.Join(", ", batches.Distinct())}");
    var check = await workbook.PreviewAsync(new MemoryStream(Rewrite(original, rowIndex, null, null)), organizationId);
    Console.WriteLine(check.Rows.Count == 0 ? "Artikel je spet v prvotnem stanju." : "!! Artikel NI v prvotnem stanju: " + string.Join("; ", check.Rows.SelectMany(line => line.PimValues.Concat(line.SaopValues)).Select(pair => pair.Key)));
    if (check.Rows.Count > 0) failures.Add("vrnitev");
  }
  Console.WriteLine(failures.Count == 0 ? "Zapis: vse OK." : "Zapis PADLO: " + string.Join(", ", failures));
  return failures.Count == 0 ? 0 : 1;
}

// Faza »datoteka«: za ročni test (uporabnik 2026-09-24) zapiše dve datoteki za ta artikel — testno,
// kjer je izpolnjen VSAK stolpec, ki ga uvoz piše, in vrnitveno s prvotnimi vrednostmi (»-« kjer je
// bilo prazno). V bazo ne piše nič.
async Task<int> WriteTestFilesAsync(string folder)
{
  Directory.CreateDirectory(folder);
  var fixedValues = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
  {
    ["Naziv 1"] = "TEST LED svečka E14 5W", ["Naziv 2"] = "TEST 4000K 450lm", ["Merska enota"] = "pkt",
    ["DDV (stopnja)"] = "02", ["Skupina artikla"] = "BA2", ["Knjižna skupina"] = "BA2", ["Objava na spletu"] = "D",
    ["Oddelek (ABC)"] = "B", ["EAN"] = Ean13("594909770463"), ["Iskalni naziv"] = "TEST iskalni naziv",
    ["Rabatna skupina 1"] = "BA2", ["Garancija"] = "3 leta", ["Aktiven"] = "D", ["Dobavitelj"] = "0001053",
    ["Proizvajalec"] = "0000081", ["Kljukica za rezervacijo"] = "D",
    ["Carinska tarifa"] = "85395100", ["Neto teža na enoto"] = "0,04", ["Bruto teža"] = "0,06", ["Širina"] = "45",
    ["Višina"] = "115", ["Enota dimenzij"] = "cm", ["Država porekla"] = "DE", ["Količina v pakiranju"] = "2",
    ["Količina v pakiranju 2"] = "20",
    ["S koda"] = "S3", ["Posebni S — tipi strank"] = "TRGOVEC\\S4", ["Posebni S — stranke"] = "0000014\\S2",
    ["Kategorije — Svetila.si"] = "Svetlobni viri in dodatki > E14",
    ["Kategorije — Svetila.si (ANG)"] = "Svetlobni viri in dodatki > E14",
    ["Kategorije — Videlektro"] = "Razsvetljava > Sijalke > LED sijalke E27",
    ["Kategorije — Videlektro (ANG)"] = "Lighting > Bulbs > LED Bulbs E27",
    ["Spletne strani"] = "Videlektro | Svetila.si",
    ["Slike"] = row[Index("Slike")] + " | https://cdn.braytron.center/images/BA09-00511-5.webp",
    ["Dokumenti"] = row[Index("Dokumenti")] + " | https://example.com/TEST-tehnicni-list.pdf",
    ["Dolžina paketa I"] = "45 mm",
  };
  var test = sheet;
  var restore = sheet;
  var filled = new List<string>();
  for (var index = 0; index < sheet.Headers.Count; index++)
  {
    var header = sheet.Headers[index];
    var group = sheet.GroupOf(index);
    if (group == ProductWorkbookContract.GroupKey || group.StartsWith("Stanje", StringComparison.Ordinal)
      || header == "Dodatna lastnost 1") continue;
    var current = row[index];
    var value = fixedValues.TryGetValue(header, out var chosen) ? chosen
      : header.StartsWith("Spletni naziv", StringComparison.Ordinal) ? $"TEST spletni naziv {header[^3..^1]}"
      : header.StartsWith("Spletni opis", StringComparison.Ordinal) ? $"TEST spletni opis {header[^3..^1]}"
      : header.StartsWith("Enota ", StringComparison.Ordinal) ? (current == "cm" ? "mm" : "cm")
      : decimal.TryParse(current.Replace(',', '.'), NumberStyles.Number, CultureInfo.InvariantCulture, out var number)
        ? (number + 1).ToString(CultureInfo.InvariantCulture)
      : $"TEST {header}";
    test = With(test, index, value);
    filled.Add($"{group} | {header} | {current} | {value}");
    // Vrnitev: prvotna vrednost; prazno polje PIM se izprazni z »-« (ERP polj uvoz ne prazni).
    if (current.Length == 0 && !group.StartsWith("ERP", StringComparison.Ordinal) && !group.StartsWith("Komerciala", StringComparison.Ordinal))
      restore = With(restore, index, "-");
  }
  File.WriteAllBytes(Path.Combine(folder, $"TEST_uvoz_{itemId}.xlsx"), Rewrite(test, rowIndex, null, null));
  File.WriteAllBytes(Path.Combine(folder, $"VRNITEV_{itemId}.xlsx"), Rewrite(restore, rowIndex, null, null));
  File.WriteAllLines(Path.Combine(folder, $"TEST_uvoz_{itemId}_vrednosti.csv"),
    new[] { "Skupina | Stolpec | Prej | Test" }.Concat(filled), new System.Text.UTF8Encoding(true));

  // Preverba brez zapisa: kaj bi uvoz testne datoteke naredil.
  var preview = await workbook.PreviewAsync(new MemoryStream(Rewrite(test, rowIndex, null, null)), organizationId);
  Console.WriteLine($"Izpolnjenih stolpcev: {filled.Count}; predogled: PIM {preview.PimChangeCount}, SAOP {preview.SaopChangeCount}, novih atributov {preview.NewAttributes?.Count ?? 0}, manjkajočih kategorij {preview.MissingCategories?.Count ?? 0}");
  foreach (var problem in preview.Problems) Console.WriteLine("  opozorilo: " + problem);
  var changed = preview.Rows.SelectMany(line => line.PimValues.Keys.Concat(line.SaopValues.Keys)).ToHashSet();
  Console.WriteLine($"Zapisanih datotek: {folder}");
  return 0;
}

static string Ean13(string twelve) =>
  twelve + ((10 - twelve.Select((digit, at) => (digit - '0') * (at % 2 == 0 ? 1 : 3)).Sum() % 10) % 10);

int Index(string header) => sheet.Headers.ToList().FindIndex(name => WorkbookHeader.Same(name, header));

WorkbookSheet With(WorkbookSheet source, int column, string value) => source with
{
  Rows = source.Rows.Select((line, index) => index != rowIndex ? line
    : (IReadOnlyList<string>)line.Select((cell, at) => at == column ? value : cell).ToList()).ToList(),
};

static string Normalize(string value) => string.Join("|", value.Split('|').Select(part => part.Trim()).Order(StringComparer.OrdinalIgnoreCase)).Replace(",", ".");

static string? Between(string text, string start, string end)
{
  var from = text.IndexOf(start, StringComparison.Ordinal);
  if (from < 0) return null;
  from += start.Length;
  var to = text.IndexOf(end, from, StringComparison.Ordinal);
  return to < 0 ? null : text[from..to];
}

static async Task<List<Dictionary<string, object?>>> Rows(string connectionString, string sql, params (string Name, object Value)[] parameters)
{
  await using var connection = new Microsoft.Data.SqlClient.SqlConnection(connectionString);
  await connection.OpenAsync();
  await using var command = new Microsoft.Data.SqlClient.SqlCommand(sql, connection);
  foreach (var (name, value) in parameters) command.Parameters.AddWithValue(name, value);
  await using var reader = await command.ExecuteReaderAsync();
  var rows = new List<Dictionary<string, object?>>();
  do
    while (await reader.ReadAsync())
      rows.Add(Enumerable.Range(0, reader.FieldCount).ToDictionary(reader.GetName, index => reader.IsDBNull(index) ? null : reader.GetValue(index)));
  while (await reader.NextResultAsync());
  return rows;
}

static string Short(string value, int length = 60) =>
  value.Length <= length ? value : value[..length] + "…";

// Vrednost, ki se od trenutne razlikuje in je po obliki smiselna za stolpec.
static string Different(string header, string current)
{
  if (header.Contains("S koda", StringComparison.Ordinal)) return current == "S3" ? "S2" : "S3";
  if (header.StartsWith("Posebni S", StringComparison.Ordinal)) return header.Contains("tipi") ? "TRGOVEC\\S3" : "00000001\\S3";
  if (decimal.TryParse(current.Replace(',', '.'), NumberStyles.Number, CultureInfo.InvariantCulture, out var number))
    return (number + 1).ToString(CultureInfo.InvariantCulture);
  if (ProductWorkbookContract.ParseYesNo(current) is { } flag) return ProductWorkbookContract.SheetYesNo(!flag);
  if (header == "Spletne strani") return current.Contains("Videlektro") ? "Svetila.si" : "Videlektro";
  if (header.StartsWith("Kategorije", StringComparison.Ordinal)) return current.Length > 0 ? current.Split('|')[0].Trim() + " > PREIZKUS" : "PREIZKUS > Nova";
  if (header is "Slike" or "Dokumenti") return (current.Length > 0 ? current + " | " : "") + "https://example.com/preizkus.jpg";
  return current.Length > 0 ? current + " X" : "PREIZKUS";
}

// Zvezek z isto glavo (skupine ostanejo, da uvoz prepozna atribute) in eno samo vrstico artikla.
static byte[] Rewrite(WorkbookSheet sheet, int rowIndex, int? column, string? value)
{
  var columns = sheet.Headers.Select((name, index) => new WorkbookColumn(name, Group: sheet.GroupOf(index))).ToList();
  var cells = sheet.Rows[rowIndex].Select(cell => (object?)(cell.Length == 0 ? null : cell)).ToList();
  if (column is { } at) cells[at] = value;
  return WorkbookWriter.Write("Izdelki", columns, [cells]);
}
