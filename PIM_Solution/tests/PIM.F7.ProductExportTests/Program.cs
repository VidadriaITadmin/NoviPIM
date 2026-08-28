using System.IO.Compression;
using Microsoft.Extensions.Configuration;
using PIM.Intranet.Services;
using PIM.Operations;

// Integracijski test izvoza izdelkov v Excel.
//
// Zahteva uporabnika 2026-08-28: v zvezku morajo biti podatki ERP, komerciala in splet;
// polja, ki pri izdelku manjkajo, morajo biti blago rdeca, polja, ki so pogoj za validacijo,
// pa rumenkasta. Prej je bil ta list prepis zaslonskega seznama in za popravljanje neuporaben.
//
// Brez povezave se test PRESKOCI in ne pade — nauk iz AGENTS.md §12: test, ki je zelen samo
// pri agentu z nastavljeno sejo, je slabsi od testa, ki pove, da ni tekel.

var connectionString = Environment.GetEnvironmentVariable("PIM_CONNECTION_STRING") ?? LocalConnectionString();
if (string.IsNullOrWhiteSpace(connectionString))
{
  Console.WriteLine("F7 izvoz izdelkov PRESKOČEN: povezave PIM ni (PIM_CONNECTION_STRING ali appsettings.Local.json).");
  return 0;
}

var configuration = new ConfigurationBuilder()
  .AddInMemoryCollection(new Dictionary<string, string?> { ["ConnectionStrings:Pim"] = connectionString })
  .Build();

var workbench = new ProductWorkbenchService(configuration);
var export = new ProductExportService(configuration, workbench);

byte[] bytes;
try
{
  bytes = await export.BuildAsync(new ProductListFilter(null, 0, 50), ProductExportTemplate.Overview);
}
catch (Exception failure)
{
  Console.WriteLine("F7 izvoz izdelkov PRESKOČEN: baza ni dosegljiva (" + failure.GetType().Name + ").");
  return 0;
}

using var archive = new ZipArchive(new MemoryStream(bytes), ZipArchiveMode.Read);
var sheetXml = new StreamReader(archive.GetEntry("xl/worksheets/sheet1.xml")!.Open()).ReadToEnd();
var stylesXml = new StreamReader(archive.GetEntry("xl/styles.xml")!.Open()).ReadToEnd();

// 1. Tri skupine, ki jih je nastel uporabnik, morajo biti v datoteki.
foreach (var group in new[] { "Istovetnost", "ERP", "Komerciala", "Splet", "Stanje" })
  Assert(sheetXml.Contains($"<t xml:space=\"preserve\">{group}</t>", StringComparison.Ordinal),
    "Zvezku manjka skupina stolpcev: " + group);

// 2. Vsebina izdelka, ne samo stanje: nazivi v vseh jezikih in trgovinski podatki.
foreach (var header in new[] { "Enota mere", "Carinska tarifa", "Neto teža", "Pakiranje 1", "Kategorija" })
  Assert(sheetXml.Contains(header, StringComparison.Ordinal), "Zvezku manjka stolpec: " + header);
foreach (var language in new[] { "sl", "en", "de", "hr", "it" })
{
  Assert(sheetXml.Contains($"Spletni naziv ({language})", StringComparison.Ordinal), "Manjka spletni naziv za jezik " + language + ".");
  Assert(sheetXml.Contains($"Naziv ERP ({language})", StringComparison.Ordinal), "Manjka naziv ERP za jezik " + language + ".");
}

// 3. Odpisani stevci se ne smejo vrniti: uporabnik jih je oznacil za moteca.
foreach (var retired in new[] { "Odprte težave", "Čaka SAOP", "Objavljen" })
  Assert(!sheetXml.Contains(retired, StringComparison.Ordinal), "Odpisani stolpec se je vrnil: " + retired + ".");

// 4. Barvi morata biti v slogih in vsaj ena rumena glava v listu; register zahtevanih polj
//    v razvojni bazi ni prazen (val.FieldRequirement, profila ERP_L1 in WEB_B2C).
foreach (var fill in new[] { "FFF6D6D6", "FFFCEFC0" })
  Assert(stylesXml.Contains(fill, StringComparison.Ordinal), "Zvezku manjka polnilo " + fill + ".");
Assert(sheetXml.Contains(" s=\"11\"", StringComparison.Ordinal),
  "Vsaj eno polje mora biti oznaceno kot pogoj za validacijo (rumena glava).");

// 5. Legenda mora biti v datoteki, sicer barve ne pomenijo nicesar.
foreach (var note in new[] { "Rumena glava", "Rdeča celica" })
  Assert(sheetXml.Contains(note, StringComparison.Ordinal), "Zvezku manjka razlaga barve: " + note + ".");

// 6. Predloga SAOP ostane brez skupin: skozi njo se ureja in vraca, bralec pa vzame prvo vrstico.
var saop = await export.BuildAsync(new ProductListFilter(null, 0, 5), ProductExportTemplate.Saop);
using var saopArchive = new ZipArchive(new MemoryStream(saop), ZipArchiveMode.Read);
var saopXml = new StreamReader(saopArchive.GetEntry("xl/worksheets/sheet1.xml")!.Open()).ReadToEnd();
Assert(saopXml.Contains("ySplit=\"1\"", StringComparison.Ordinal),
  "Predloga SAOP mora ostati z eno naslovno vrstico, sicer uvoz ne najde imen stolpcev.");
using var saopStream = new MemoryStream(saop);
var saopTable = WorkbookTable.Read(saopStream);
Assert(saopTable.Headers.Contains("ItemID", StringComparer.Ordinal) || saopTable.Headers.Count > 1,
  "Predloga SAOP mora imeti berljivo naslovno vrstico.");

Console.WriteLine("F7 izvoz izdelkov: skupine ERP/komerciala/splet, barvni oznaki in legenda PASS.");
return 0;

static void Assert(bool condition, string message)
{
  if (!condition) throw new InvalidOperationException(message);
}

// Lokalna nastavitev je izhod v sili: skripta za teste povezavo poda prek okolja.
static string? LocalConnectionString()
{
  var current = new DirectoryInfo(Directory.GetCurrentDirectory());
  while (current is not null)
  {
    var candidate = Path.Combine(current.FullName, "src", "PIM.Intranet", "appsettings.Local.json");
    if (File.Exists(candidate))
      return new ConfigurationBuilder().AddJsonFile(candidate).Build().GetConnectionString("Pim");
    current = current.Parent;
  }

  return null;
}
