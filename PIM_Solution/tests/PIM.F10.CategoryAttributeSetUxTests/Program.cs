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

// --- Polnjenje iz mastrov (173): samo skozi postopek, register nedotaknjen, ravni zapisane -------
var seed = Read(Path.Combine(root, "sql", "migrations", "173_CategoryAttributeSetsFromMastri.sql"));
Assert(seed.Contains("EXEC canon.SaveCategoryAttributeSetBulk", StringComparison.Ordinal),
  "Nabori iz mastrov morajo iti skozi canon.SaveCategoryAttributeSetBulk, ne z INSERT v register.");
foreach (var forbidden in new[] { "INSERT canon.", "INSERT INTO canon.", "INSERT val.", "canon.AttributeDefinition", "DELETE canon.", "DELETE val." })
  Assert(!seed.Contains(forbidden, StringComparison.Ordinal),
    "Migracija 173 ne sme pisati v tabele mimo postopka niti siriti registra atributov: " + forbidden);
Assert(seed.Contains("N'REQUIRED'", StringComparison.Ordinal) && seed.Contains("N'RECOMMENDED'", StringComparison.Ordinal)
  && !seed.Contains("WithValue", StringComparison.Ordinal),
  "Ravni so v migraciji zapisane kot vrednosti, ne izracunane iz stanja baze - rezultat mora biti enak v vsakem okolju.");
Assert(seed.Contains("existing.IsActive = 1", StringComparison.Ordinal) && seed.Contains("UpdatedBy <> N'mastri 2026-09-08'", StringComparison.Ordinal),
  "Rocno urejena aktivna vrstica mora preziveti ponovni zagon migracije.");
Assert(File.Exists(Path.Combine(root, "tools", "Mastri", "build_category_attribute_sets.py")),
  "Generator preslikave mastrov mora biti v repozitoriju, da je polnjenje ponovljivo.");

// --- 177: ustvarjanje v registru iz nabora, kakovost po kategorijah (vecnivojsko) ----------------
var register = Read(Path.Combine(root, "sql", "migrations", "177_AttributeRegisterFromSetsAndQualityByCategory.sql"));
foreach (var procedure in new[] { "canon.EnsureAttributeDefinition", "canon.ResolveAttributeNames", "intranet.GetQualityByCategory", "intranet.GetQualityIssues" })
  Assert(register.Contains("CREATE OR ALTER PROCEDURE " + procedure, StringComparison.Ordinal),
    "Migracija 177 mora ustvariti " + procedure + " (idempotentno).");
Assert(register.Contains("EXEC canon.SaveCategoryAttributeSetBulk", StringComparison.Ordinal) && register.Contains("EXEC canon.EnsureAttributeDefinition", StringComparison.Ordinal),
  "Atributi iz mastrov gredo v register in nabore samo skozi postopke.");
Assert(register.Contains("ParentCategoryCode = subtree.CategoryCode", StringComparison.Ordinal) && register.Contains("parent.CategoryCode = chain.ParentCategoryCode", StringComparison.Ordinal),
  "Obseg kategorije mora biti vecnivojski po ParentCategoryCode, ne po nizu poti.");
foreach (var method in new[] { "ResolveAttributeNamesAsync", "EnsureAttributeDefinitionAsync", "GetCategoryOptionsAsync" })
  Assert(service.Contains(method, StringComparison.Ordinal), "CategoryTreeService mora imeti " + method + ".");
Assert(page.Contains("CreateAndAddAsync", StringComparison.Ordinal) && page.Contains("CreateUnknownAndSaveAsync", StringComparison.Ordinal) && page.Contains("SaveKnownOnlyAsync", StringComparison.Ordinal),
  "Neznano ime ni napaka, ampak ponudba: ustvari v registru (eno ali vsa) ali dodaj samo znana.");
Assert(page.Contains("ResolveAttributeNamesAsync", StringComparison.Ordinal),
  "Prilepljen seznam se najprej razresi, sele nato zapise.");

var quality = Read(Path.Combine(pages, "Quality.razor"));
var qualityService = Read(Path.Combine(services, "QualityReadService.cs"));
var issues = Read(Path.Combine(pages, "ValidationErrors.razor"));
// Zavihek Po kategorijah je zdaj del skupnega seznama QualityTabs (PimTab.cs, prenova
// 2026-09-10), ne vec lokalnega <nav> v Quality.razor — pot je zato lahko v enem ali drugem.
var pimTabSource = Read(Path.Combine(Path.Combine(root, "src", "PIM.Intranet", "Components", "Shared"), "PimTab.cs"));
Assert((quality.Contains("kakovost?pogled=kategorije", StringComparison.Ordinal) || pimTabSource.Contains("kakovost?pogled=kategorije", StringComparison.Ordinal))
    && quality.Contains("GetByCategoryAsync", StringComparison.Ordinal),
  "/kakovost mora imeti zavihek Po kategorijah iz intranet.GetQualityByCategory.");
Assert(quality.Contains("CollapseTo(", StringComparison.Ordinal) && quality.Contains("Collapsed", StringComparison.Ordinal),
  "Pogled po kategorijah mora biti vecnivojski: veje se zlagajo po ravneh.");
Assert(quality.Contains("kakovost/napake?drevo=", StringComparison.Ordinal),
  "Vrstica kategorije mora voditi na seznam napak z obsegom te kategorije.");
Assert(qualityService.Contains("intranet.GetQualityByCategory", StringComparison.Ordinal) && qualityService.Contains("@CategoryTreeCode", StringComparison.Ordinal),
  "QualityReadService mora klicati bralni model po kategorijah in prenasati obseg kategorije.");
Assert(issues.Contains("QueryCategory", StringComparison.Ordinal) && issues.Contains("CategoryTreeCode: QueryTree, CategoryCode: QueryCategory", StringComparison.Ordinal),
  "Napake validacije morajo sprejeti drevo in kategorijo iz naslova in ju prenesti v filter.");
Assert(issues.Contains("option.LevelNo - 1", StringComparison.Ordinal),
  "Izbirnik kategorije mora pokazati ravni z zamikom, sicer vecnivojskost ni vidna.");

// --- Izbirnik s tipkanjem (PimPicker) in preverba podvajanja --------------------------------------
var shared = Path.Combine(root, "src", "PIM.Intranet", "Components", "Shared");
var picker = Read(Path.Combine(shared, "PimPicker.razor"));
var text = Read(Path.Combine(services, "PimText.cs"));
Assert(File.Exists(Path.Combine(shared, "PimPicker.razor.css")), "PimPicker mora imeti svoj CSS (seznam nad vsebino).");
Assert(picker.Contains("role=\"combobox\"", StringComparison.Ordinal) && picker.Contains("role=\"listbox\"", StringComparison.Ordinal) && picker.Contains("aria-activedescendant", StringComparison.Ordinal),
  "Izbirnik mora biti dostopen: combobox + listbox + aktivna moznost za bralnike.");
Assert(picker.Contains("ExactExisting", StringComparison.Ordinal) && picker.Contains("Similar", StringComparison.Ordinal) && picker.Contains("CanOfferCreate", StringComparison.Ordinal),
  "Pred ustvarjanjem mora izbirnik opozoriti na enako ime (brez ustvarjanja) in na podobna imena.");
Assert(!picker.Contains("IJSRuntime", StringComparison.Ordinal) && !picker.Contains("<script", StringComparison.Ordinal),
  "Izbirnik je brez JavaScripta, da dela povsod, kjer dela stran.");
Assert(text.Contains("public static string Fold", StringComparison.Ordinal) && text.Contains("NormalizationForm.FormD", StringComparison.Ordinal),
  "Primerjava imen mora biti brez sumnikov in velikosti crk (Fold).");
foreach (var (file, control) in new[]
{
  ("MissingCategories.razor", "<PimPicker"), ("IngestAttributes.razor", "AllowCreate=\"true\""),
  ("ValidationErrors.razor", "<PimPicker"), ("CategoryAttributeSets.razor", "Id=\"copy-category\" Options=\"CopySourceOptions"),
})
  Assert(Read(Path.Combine(pages, file)).Contains(control, StringComparison.Ordinal),
    "Stran " + file + " mora uporabljati izbirnik s tipkanjem namesto spustnega seznama z vsemi moznostmi: " + control);
Assert(!Read(Path.Combine(pages, "MissingCategories.razor")).Contains("<option value=\"@node.CategoryCode\">", StringComparison.Ordinal),
  "Spustni seznam z vsemi kategorijami je zamenjan z izbirnikom.");

// --- 178: nova kategorija iz aplikacije, s preverbo podvajanja ------------------------------------
var saveCategory = Read(Path.Combine(root, "sql", "migrations", "178_SaveCategoryWithDuplicateCheck.sql"));
Assert(saveCategory.Contains("CREATE OR ALTER PROCEDURE canon.SaveCategory", StringComparison.Ordinal) && saveCategory.Contains("CREATE OR ALTER FUNCTION canon.CategoryCodeFromName", StringComparison.Ordinal),
  "Migracija 178 mora dati postopek za novo kategorijo in kodo iz imena.");
Assert(saveCategory.Contains("THROW 51781", StringComparison.Ordinal) && saveCategory.Contains("canon.CategoryCodeFromName(CategoryName) = @Slug", StringComparison.Ordinal),
  "Isto ime pod istim starsem (brez sumnikov in velikosti crk) mora postopek zavrniti, ne podvojiti.");
Assert(service.Contains("CreateCategoryAsync", StringComparison.Ordinal) && service.Contains("canon.SaveCategory", StringComparison.Ordinal),
  "CategoryTreeService mora klicati canon.SaveCategory.");
var catalogCategories = Read(Path.Combine(pages, "CatalogCategories.razor"));
Assert(catalogCategories.Contains("NewSiblingDuplicate", StringComparison.Ordinal) && catalogCategories.Contains("NewSimilar", StringComparison.Ordinal) && catalogCategories.Contains("CreateCategoryAsync", StringComparison.Ordinal),
  "/nastavitve/kategorije mora omogociti novo kategorijo z opozorilom na isto in podobno ime.");
var missing = Read(Path.Combine(pages, "MissingCategories.razor"));
Assert(missing.Contains("CreateLabel=\"Ustvari novo kategorijo\"", StringComparison.Ordinal) && missing.Contains("SiblingDuplicate", StringComparison.Ordinal),
  "Preslikava kategorij mora ponuditi ustvarjanje manjkajoce kategorije z izbiro starsa in preverbo podvajanja.");
Assert(Read(Path.Combine(pages, "ProductCategories.razor")).Contains("<PimPicker", StringComparison.Ordinal),
  "Dodeljevanje kategorij izdelku mora uporabljati izbirnik s tipkanjem.");

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
