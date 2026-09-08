// Pogodba strani /nastavitve/nabori-atributov (migracija 170).
//
// Register naborov, dedovanje, validacija in izvoz so iz migracije 147 in jih ta stran ne podvaja:
// bere jih prek intranet.* bralnih modelov in pise samo prek canon.* postopkov. Ta test drzi tisto,
// kar se v pregledu kode zlahka izgubi: da stran ne pise v bazo sama, da ima vsak zapis akterja, da
// napaka iz baze pride do uporabnika in da so vse tri zapisovalne poti (ena vrstica, seznam,
// kopiranje) res vezane na postopke.
var root = FindRoot();
var pages = Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages");
var services = Path.Combine(root, "src", "PIM.Intranet", "Services");
var page = Read(Path.Combine(pages, "CategoryAttributeSets.razor"));
var hub = Read(Path.Combine(pages, "CatalogSettings.razor"));
var service = Read(Path.Combine(services, "CategoryTreeService.cs"));
var navigation = Read(Path.Combine(services, "PimNavigation.cs"));
var migration = Read(Path.Combine(root, "sql", "migrations", "170_CategoryAttributeSetOverview.sql"));

Assert(File.Exists(Path.Combine(pages, "CategoryAttributeSets.razor.css")),
  "Stran mora imeti svoj CSS (izolirani slogi urejevalnika in izbire drevesa).");

// --- Pot, vloge, nacin -------------------------------------------------------------------------
Assert(page.Contains("@page \"/nastavitve/nabori-atributov\"", StringComparison.Ordinal),
  "Stran mora biti na /nastavitve/nabori-atributov.");
Assert(page.Contains("Roles = \"ADMIN,CATALOG_EDITOR\"", StringComparison.Ordinal),
  "Nabor spreminja katalog in validacijo, zato ni dovolj samo prijava.");
Assert(page.Contains("@rendermode InteractiveServer", StringComparison.Ordinal),
  "Brez interaktivnega nacina urejanje ne dela.");
Assert(page.Contains("ActorAsync", StringComparison.Ordinal),
  "Vsaka sprememba mora imeti akterja iz prijave.");
Assert(page.Contains("catch (Exception exception) { Error = exception.Message; }", StringComparison.Ordinal),
  "Napaka iz baze (npr. seznam neznanih atributov) mora priti do uporabnika.");

// --- Stran ne presoja pravil in ne pise sama -------------------------------------------------
foreach (var forbidden in new[] { "canon.CategoryAttributeSet", "val.FieldRequirement", "INSERT ", "UPDATE ", "SqlConnection" })
  Assert(!page.Contains(forbidden, StringComparison.Ordinal),
    "Stran ne sme sama pisati v bazo niti poznati tabel: " + forbidden);

// --- Servis klice postopke iz 147 in 170 ------------------------------------------------------
foreach (var procedure in new[]
{
  "intranet.GetCategoryAttributeSetTrees", "intranet.GetCategoryAttributeSetOverview", "intranet.GetCategoryAttributeSet",
  "canon.SaveCategoryAttributeSet", "canon.SaveCategoryAttributeSetBulk", "canon.CopyCategoryAttributeSet",
})
  Assert(service.Contains(procedure, StringComparison.Ordinal), "Servis mora klicati postopek " + procedure + ".");

foreach (var method in new[] { "GetAttributeSetTreesAsync", "GetAttributeSetOverviewAsync", "GetAttributeSetAsync", "SaveAttributeSetAsync", "SaveAttributeSetBulkAsync", "CopyAttributeSetAsync" })
  Assert(page.Contains(method, StringComparison.Ordinal), "Stran mora uporabljati " + method + ".");

// --- Kar je uporabnik zahteval: po drevesu, koliko in kateri ----------------------------------
Assert(page.Contains("SelectTreeAsync", StringComparison.Ordinal) && page.Contains("TreeLabel", StringComparison.Ordinal),
  "Drevo (svetila, videlektro) mora biti izbira na strani, ne skrit parameter.");
foreach (var column in new[] { "row.EffectiveRequired", "row.EffectiveRecommended", "row.EffectiveExcluded", "row.EffectiveNames", "row.UsedNotInSetCount" })
  Assert(page.Contains(column, StringComparison.Ordinal),
    "Vrstica mora povedati, koliko in katere atribute ima kategorija ter koliko jih izdelki nosijo izven nabora: " + column);
Assert(page.Contains("WebProfileCode is null", StringComparison.Ordinal),
  "Drevo brez spletnega profila ne more shraniti nabora (147, 51474) - to mora biti vidno pred klikom, ne kot napaka po njem.");

// --- Mnozicne poti: izbira vec, lepljenje seznama, kopiranje ------------------------------------
Assert(page.Contains("Picked", StringComparison.Ordinal) && page.Contains("AddPickedAsync", StringComparison.Ordinal),
  "Vec atributov naenkrat iz registra.");
Assert(page.Contains("ImportPasteAsync", StringComparison.Ordinal) && page.Contains("ParseLevel", StringComparison.Ordinal),
  "Lepljenje seznama iz mastrov: ime ali koda, po zelji raven v slovenscini.");
Assert(page.Contains("CopyAsync", StringComparison.Ordinal) && page.Contains("CopyIncludeInherited", StringComparison.Ordinal),
  "Kopiranje nabora druge kategorije (tudi iz drugega drevesa).");

// --- Dosegljivost: hub in obmocje toka ----------------------------------------------------------
Assert(hub.Contains("nastavitve/nabori-atributov", StringComparison.Ordinal),
  "Razdelilna stran /nastavitve mora voditi na nabore.");
Assert(navigation.Contains("\"nastavitve/nabori-atributov\"", StringComparison.Ordinal),
  "Pot mora biti v PimLifecycle.Catalog, sicer pade v Nadzor.");
Assert(page.Contains("nastavitve/kategorije", StringComparison.Ordinal) && page.Contains("nastavitve/atributi", StringComparison.Ordinal),
  "Stran mora voditi na drugi dve mesti, kjer se isti nabor in register urejata.");

// --- Migracija: samo dodajanje, brez spremembe registra iz 147 ---------------------------------
foreach (var procedure in new[] { "intranet.GetCategoryAttributeSetTrees", "intranet.GetCategoryAttributeSetOverview", "canon.SaveCategoryAttributeSetBulk", "canon.CopyCategoryAttributeSet" })
  Assert(migration.Contains("CREATE OR ALTER PROCEDURE " + procedure, StringComparison.Ordinal),
    "Migracija 170 mora ustvariti " + procedure + " (idempotentno).");
foreach (var forbidden in new[] { "ALTER TABLE canon.CategoryAttributeSet", "DROP TABLE", "TRUNCATE", "CREATE OR ALTER PROCEDURE canon.SaveCategoryAttributeSet\n" })
  Assert(!migration.Contains(forbidden, StringComparison.Ordinal),
    "Migracija 170 ne sme spreminjati registra ali postopka iz 147: " + forbidden);
Assert(migration.Contains("EXEC canon.SaveCategoryAttributeSet @", StringComparison.Ordinal),
  "Mnozicni vnos in kopiranje morata iti skozi canon.SaveCategoryAttributeSet, da zahteve in revizija ostanejo na enem mestu.");
Assert(migration.Contains("translation.Name = item.Given", StringComparison.Ordinal),
  "Seznam sme navesti slovensko ime atributa, ker ga mastri nosijo tako.");

Console.WriteLine("PIM.F10.CategoryAttributeSetUxTests: vse pogodbe drzijo.");
return 0;

static string Read(string path)
{
  if (!File.Exists(path)) throw new InvalidOperationException("Manjka datoteka: " + path);
  return File.ReadAllText(path);
}

static void Assert(bool condition, string message)
{
  if (!condition) throw new InvalidOperationException(message);
}

static string FindRoot()
{
  foreach (var start in new[] { Directory.GetCurrentDirectory(), AppContext.BaseDirectory })
  {
    var current = new DirectoryInfo(start);
    while (current is not null)
    {
      if (File.Exists(Path.Combine(current.FullName, "PIM.sln"))) return current.FullName;
      current = current.Parent;
    }
  }
  throw new InvalidOperationException("PIM_Solution ni najden.");
}
