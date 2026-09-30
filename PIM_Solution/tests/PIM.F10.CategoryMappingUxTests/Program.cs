// Pogodba zapisovalne poti za kategorije, 2026-08-27.
//
// Do migracije 109 je bil intranet za kategorije v celoti bralen. Ta test drzi tri stvari, ki
// se v pregledu kode zlahka izgubijo in se v teku ne pokazejo kot napaka, ampak kot tiho
// napacno vedenje:
//
//   1. zapisovalna stran mora zahtevati prijavo in imeti akterja pri vsakem klicu,
//   2. pravila ostanejo v bazi - stran ne sme sama presojati, kaj je veljavna kategorija,
//   3. napaka iz baze mora priti do uporabnika, ne v prazen catch.
var root = FindRoot();
var pages = Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages");
var services = Path.Combine(root, "src", "PIM.Intranet", "Services");
var mappingPage = Read(Path.Combine(pages, "MissingCategories.razor"));
var productPage = Read(Path.Combine(pages, "ProductCategories.razor"));
// Od 2026-09-28 je urejanje uvrstitve v skupnem gradniku (tudi na kartici izdelka); stran ga samo vgradi.
var productEditor = Read(Path.Combine(pages, "ProductCard", "ProductCategoryEditor.razor"));
var service = Read(Path.Combine(services, "CategoryMappingService.cs"));
var program = Read(Path.Combine(root, "src", "PIM.Intranet", "Program.cs"));

Assert(program.Contains("AddScoped<CategoryMappingService>", StringComparison.Ordinal),
  "CategoryMappingService mora biti registriran, sicer stran pade sele ob prvem odprtju.");

foreach (var markup in new[] { mappingPage, productPage })
{
  Assert(markup.Contains("[Authorize", StringComparison.Ordinal),
    "Zapisovalna stran mora zahtevati prijavo.");
  Assert(markup.Contains("@rendermode InteractiveServer", StringComparison.Ordinal),
    "Brez interaktivnega nacina gumbi ne delajo, stran pa izgleda delujoca.");
}

Assert(productPage.Contains("<ProductCategoryEditor", StringComparison.Ordinal),
  "/izdelki/kategorije mora vgraditi skupni gradnik ProductCategoryEditor, sicer urejanje tiho izgine s strani.");

foreach (var markup in new[] { mappingPage, productEditor })
{
  Assert(markup.Contains("ActorAsync", StringComparison.Ordinal),
    "Vsaka sprememba mora imeti akterja iz prijave, ne privzete vrednosti v postopku.");
  Assert(markup.Contains("catch (Exception exception) { Error = exception.Message; }", StringComparison.Ordinal),
    "Napaka iz baze mora priti do uporabnika; prazen catch skrije zavrnitev pravila.");
}

// Uvrstitev izdelka spreminja katalog, zato ni dovolj samo prijava.
Assert(productPage.Contains("Roles = \"ADMIN,CATALOG_EDITOR\"", StringComparison.Ordinal),
  "Rocno uvrstitev izdelka smeta samo ADMIN in CATALOG_EDITOR.");

// Pravila so podatek v bazi. Ce jih stran podvoji, se bosta razsla.
foreach (var forbidden in new[] { "canon.Category", "map.CategoryPathMap", "INSERT ", "UPDATE " })
{
  Assert(!mappingPage.Contains(forbidden, StringComparison.Ordinal),
    "Stran ne sme sama pisati v bazo niti presojati drevesa: " + forbidden);
  Assert(!productPage.Contains(forbidden, StringComparison.Ordinal),
    "Stran ne sme sama pisati v bazo niti presojati drevesa: " + forbidden);
  Assert(!productEditor.Contains(forbidden, StringComparison.Ordinal),
    "Gradnik uvrstitve ne sme sam pisati v bazo niti presojati drevesa: " + forbidden);
}

// Varovanje je v servisu, ne v skrivanju gumbov: vsi zapisi uvrstitve zahtevajo CatalogWrite.
Assert(service.Contains("guard.RequireAsync(PimPolicies.CatalogWrite)", StringComparison.Ordinal),
  "CategoryMappingService mora zapise varovati s politiko CatalogWrite.");

foreach (var procedure in new[]
{
  "intranet.GetCategoryMappings", "intranet.GetCategoryTreeNodes", "intranet.GetProductCategories",
  "map.SaveCategoryPathMap", "map.DeactivateCategoryPathMap",
  "pim.SetProductCategories", "pim.ClearProductCategoryOverride"
})
  Assert(service.Contains(procedure, StringComparison.Ordinal),
    "Servis mora klicati postopek " + procedure + " iz migracije 109.");

// Delovni seznam mora privzeto pokazati nalogo, ne celotnega registra.
Assert(mappingPage.Contains("string State = \"Nepreslikano\"", StringComparison.Ordinal),
  "Privzeti filter mora biti Nepreslikano - stran obstaja zaradi tega dela.");
Assert(mappingPage.Contains("PimPager", StringComparison.Ordinal)
  && mappingPage.Contains("@Stran", StringComparison.Ordinal) == false,
  "Stranjenje mora biti strezniško, prek PimPager in parametrov postopka.");
Assert(service.Contains("SkupajVrstic", StringComparison.Ordinal),
  "Skupno stevilo mora priti iz iste poizvedbe kot vrstice, sicer polozaj strani zaostaja.");

// Prazen seznam kategorij je odlocitev, ne pomota - uporabnik mora to videti.
Assert(productEditor.Contains("namenoma brez kategorije", StringComparison.Ordinal),
  "Prazen seznam mora biti razlozen kot odlocitev, ne kot manjkajoc podatek.");
Assert(productPage.Contains("ponovna preslikava", StringComparison.OrdinalIgnoreCase),
  "Stran mora povedati, da rocne uvrstitve ponovna preslikava ne povozi.");
Assert(productEditor.Contains("ClearProductCategoryOverrideAsync", StringComparison.Ordinal),
  "Vrnitev pod vir mora biti mozna, sicer je rocna uvrstitev enosmerna.");


// --- Drevo kategorij in prevodi (110, 113) -------------------------------------------------
var treePage = Read(Path.Combine(pages, "CatalogCategories.razor"));
var treeStyle = Read(Path.Combine(pages, "CatalogCategories.razor.css"));
var treeService = Read(Path.Combine(services, "CategoryTreeService.cs"));

Assert(program.Contains("AddScoped<CategoryTreeService>", StringComparison.Ordinal),
  "CategoryTreeService mora biti registriran.");
// Komerciala (COMMERCIAL) sme drevo gledati; vsak zapis v CategoryTreeService varuje politika CatalogWrite
// (samo ADMIN in CATALOG_EDITOR). Skrivanje gumbov je samo videz, zato test drzi pravico v servisu.
Assert(treePage.Contains("Roles = \"ADMIN,CATALOG_EDITOR,COMMERCIAL\"", StringComparison.Ordinal),
  "Urejanje imen spreminja katalog, zato ni dovolj samo prijava.");
foreach (var writer in new[] { "SaveTranslationsAsync", "CreateCategoryAsync", "MoveCategoriesAsync", "DeleteCategoriesAsync" })
{
  var at = treeService.IndexOf(" " + writer + "(", StringComparison.Ordinal);
  Assert(at >= 0, "CategoryTreeService mora imeti " + writer + ".");
  var guardAt = treeService.IndexOf("guard.RequireAsync(PimPolicies.CatalogWrite)", at, StringComparison.Ordinal);
  var nextMethod = treeService.IndexOf("public async", at + 1, StringComparison.Ordinal);
  Assert(guardAt >= 0 && (nextMethod < 0 || guardAt < nextMethod),
    writer + " mora zahtevati politiko CatalogWrite, ker drevo vidi tudi komerciala.");
}
Assert(treePage.Contains("@rendermode InteractiveServer", StringComparison.Ordinal),
  "Brez interaktivnega nacina zlaganje in urejanje ne delata.");
Assert(treePage.Contains("ActorAsync", StringComparison.Ordinal),
  "Prevod mora imeti akterja iz prijave.");
Assert(treePage.Contains("catch (Exception exception) { Error = exception.Message; }", StringComparison.Ordinal),
  "Napaka iz baze mora priti do uporabnika.");

foreach (var procedure in new[]
  { "intranet.GetCategoryTree", "intranet.GetCategoryTranslationCoverage", "canon.SaveCategoryTranslations" })
  Assert(treeService.Contains(procedure, StringComparison.Ordinal),
    "Servis mora klicati postopek " + procedure + ".");

// Drevo brez zamika je tabela. Zamik mora izhajati iz nivoja, ne iz rocno vpisanih presledkov.
Assert(treePage.Contains("Indent(row.LevelNo)", StringComparison.Ordinal)
  && treePage.Contains("(level - 1) *", StringComparison.Ordinal),
  "Zamik mora izhajati iz LevelNo.");

// Drevo se bere navpicno; tabela s stolpci hierarhije ne pokaze.
Assert(treePage.Contains("role=\"tree\"", StringComparison.Ordinal)
  && treePage.Contains("role=\"treeitem\"", StringComparison.Ordinal)
  && treePage.Contains("aria-level=\"@row.LevelNo\"", StringComparison.Ordinal),
  "Drevo mora biti oznaceno kot drevo, ne kot tabela.");

// Zlaganje vej je bistvo pregleda pri 209 vozliscih.
Assert(treePage.Contains("ExpandAll", StringComparison.Ordinal)
  && treePage.Contains("CollapseAll", StringComparison.Ordinal)
  && treePage.Contains("Collapsed", StringComparison.Ordinal),
  "Veje mora biti mogoce zloziti in razpreti.");
Assert(treePage.Contains("Collapsed.Clear();", StringComparison.Ordinal)
  && treePage.Contains("!string.IsNullOrWhiteSpace(Search) || OnlyMissing", StringComparison.Ordinal),
  "Ob filtru se mora zlaganje sprostiti, sicer je zadetek skrit pod zlozeno vejo.");

// Zadetek brez prednikov je iztrgan iz drevesa.
Assert(treePage.Contains("row.IsMatch", StringComparison.Ordinal)
  && treePage.Contains("is-context", StringComparison.Ordinal),
  "Predniki zadetkov morajo biti prikazani in loceni od zadetkov.");

// Vsi jeziki hkrati: vprasanje "kateri manjka" je pomembnejse od vrednosti enega.
Assert(treePage.Contains("foreach (var language in Languages)", StringComparison.Ordinal)
  && treePage.Contains("row.Translations.TryGetValue", StringComparison.Ordinal),
  "Vrstica mora pokazati stanje vseh jezikov, ne samo izbranega.");
Assert(treeService.Contains("IReadOnlyDictionary<string, string> Translations", StringComparison.Ordinal),
  "Servis mora vrniti vse prevode vrstice, ne samo enega.");
Assert(treePage.Contains("SaveTranslationsAsync", StringComparison.Ordinal)
  && treePage.Contains("editor-grid", StringComparison.Ordinal),
  "Urejanje mora odpreti vsa jezikovna polja naenkrat.");

// Prazno polje ne sme brisati imena - to je pravilo, ki mora biti tudi povedano.
Assert(treePage.Contains("!string.IsNullOrWhiteSpace(pair.Value)", StringComparison.Ordinal),
  "Prazna polja se ne smejo poslati kot brisanje imena.");

// Deset kartic KPI je zasedlo cel zaslon pred prvo kategorijo.
Assert(!treePage.Contains("<PimStat ", StringComparison.Ordinal),
  "Pokritost ne sme biti niz kartic KPI.");
Assert(treePage.Contains("coverage-row", StringComparison.Ordinal)
  && treeStyle.Contains(".coverage-fill", StringComparison.Ordinal),
  "Pokritost mora biti kompakten trak z deleziem, ki je hkrati filter.");
Assert(!treePage.Contains("<PimChip ", StringComparison.Ordinal),
  "V drevesu ni oblackov; stanje nosita znacka jezika in stevec.");

// Prej je stolpec Prevod izpisoval pomisljaj za vsako vrstico.
Assert(!treePage.Contains("<td>\u2014</td>", StringComparison.Ordinal),
  "Stolpec ne sme izpisovati mrtvega pomisljaja namesto podatka.");

// Locilo poti je " > ". Stara formula je iskala potomce z "/%" in zato ni nasla nobenega.
Assert(!treeService.Contains("+ N'/%'", StringComparison.Ordinal),
  "Potomci se ne smejo iskati po locilu posevnica.");


// Izbira jezika mora spremeniti drevo. Ce naslov vozlisca ostane slovenski, izbira jezika ne
// pomeni nicesar in uporabnik jo prebere kot okvaro.
Assert(treePage.Contains("@DisplayName(row)", StringComparison.Ordinal)
  && treePage.Contains("row.Translations.TryGetValue(Language, out var name)", StringComparison.Ordinal),
  "Naslov vozlisca mora biti ime v izbranem jeziku.");
Assert(treePage.Contains("@DisplayName(root)", StringComparison.Ordinal),
  "Izbirnik veje mora brati v istem jeziku kot drevo.");
Assert(treePage.Contains("IsFallback(row)", StringComparison.Ordinal)
  && treeStyle.Contains(".node-title.is-fallback", StringComparison.Ordinal),
  "Slovensko ime namesto manjkajocega prevoda mora biti oznaceno kot nadomestek.");
Assert(!treeStyle.Contains("outline: 2px solid var(--pim-primary)", StringComparison.Ordinal),
  "Znacka izbranega jezika ne sme biti obrobljena - barva je motila in ni nosila informacije.");

// --- #34: paketna preslikava poti na /kakovost/kategorije ------------------------------------------
// Izbira vrstic je skupni gradnik (PimBulkBar + PimRowSelection), ne kopija na strani.
Assert(mappingPage.Contains("<PimBulkBar", StringComparison.Ordinal)
  && mappingPage.Contains("PimRowSelection<", StringComparison.Ordinal),
  "Paketna preslikava mora uporabljati skupna gradnika PimBulkBar in PimRowSelection.");
Assert(mappingPage.Contains("aria-label=\"@($\"Izberi pot", StringComparison.Ordinal),
  "Potrditveno polje na vrstici mora imeti aria-label.");
Assert(mappingPage.Contains("Selection.UpdateFilter(FilterSignature, Total)", StringComparison.Ordinal),
  "»Vse, ki ustrezajo filtru« se mora sprostiti ob spremembi filtra.");
// Potrditev pove koliko in kam, pred zapisom.
Assert(mappingPage.Contains("Preslikati @PathCount(BulkRows.Count) v »@BulkCategoryLabel«?", StringComparison.Ordinal),
  "Potrditev mora povedati število poti in ciljno kategorijo.");
Assert(mappingPage.Contains("Samo za branje", StringComparison.Ordinal)
  && mappingPage.Contains("Mapping.CanWriteAsync()", StringComparison.Ordinal),
  "Brez pravice stran pokaže »Samo za branje« in ne ponudi izbire.");
Assert(mappingPage.Contains("catch (Exception exception) { BulkError = exception.Message", StringComparison.Ordinal),
  "Zavrnitev paketa iz baze mora priti do uporabnika.");

// Servis: ista politika za posamično, paketno preslikavo in ugašanje; en paket = ena transakcija.
foreach (var writer in new[] { "SaveMappingAsync", "SaveMappingsAsync", "DeactivateMappingAsync" })
{
  var at = service.IndexOf(" " + writer + "(", StringComparison.Ordinal);
  Assert(at >= 0, "CategoryMappingService mora imeti " + writer + ".");
  var guardAt = service.IndexOf("guard.RequireAsync(PimPolicies.CatalogWrite)", at, StringComparison.Ordinal);
  var nextMethod = service.IndexOf("public ", at + 1, StringComparison.Ordinal);
  Assert(guardAt >= 0 && (nextMethod < 0 || guardAt < nextMethod),
    writer + " mora zahtevati politiko CatalogWrite (stran je samo videz).");
}
var bulkAt = service.IndexOf(" SaveMappingsAsync(", StringComparison.Ordinal);
var bulkBody = service[bulkAt..service.IndexOf("static void BindSave", bulkAt, StringComparison.Ordinal)];
Assert(bulkBody.Contains("BeginTransactionAsync", StringComparison.Ordinal)
  && bulkBody.Contains("CommitAsync", StringComparison.Ordinal)
  && bulkBody.Contains("RollbackAsync", StringComparison.Ordinal),
  "Paketna preslikava mora biti ena transakcija: vse ali nič.");
Assert(bulkBody.Contains("map.SaveCategoryPathMap", StringComparison.Ordinal),
  "Paket mora iti čez isti postopek kot posamična preslikava (pravila in zgodovina v bazi).");
Assert(bulkBody.Contains("MaxBulkPaths", StringComparison.Ordinal),
  "Paket mora imeti izrecno zgornjo mejo.");
Assert(bulkBody.Contains("Izbrane poti so iz več dreves", StringComparison.Ordinal),
  "Servis mora zavrniti poti iz drugega drevesa kot ciljna kategorija.");

Console.WriteLine("PIM.F10.CategoryMappingUxTests: vse pogodbe drzijo.");
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
