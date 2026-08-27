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
}

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
Assert(productPage.Contains("namenoma brez kategorije", StringComparison.Ordinal),
  "Prazen seznam mora biti razlozen kot odlocitev, ne kot manjkajoc podatek.");
Assert(productPage.Contains("ponovna preslikava", StringComparison.OrdinalIgnoreCase),
  "Stran mora povedati, da rocne uvrstitve ponovna preslikava ne povozi.");
Assert(productPage.Contains("ClearProductCategoryOverrideAsync", StringComparison.Ordinal),
  "Vrnitev pod vir mora biti mozna, sicer je rocna uvrstitev enosmerna.");

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
