// Pogodba zapisovalne poti za atribute (migracije 121-125).
//
// Stran /nastavitve/atributi je imela pred tem tri filtre, onemogocene z besedilom "bralni model
// manjka", in seznam brez virov in prevodov. Ta test drzi tisto, kar se v pregledu kode zlahka
// izgubi in se v teku ne pokaze kot napaka, ampak kot tiho napacno vedenje.
var root = FindRoot();
var pages = Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages");
var services = Path.Combine(root, "src", "PIM.Intranet", "Services");
var worklist = Read(Path.Combine(pages, "IngestAttributes.razor"));
var catalog = Read(Path.Combine(pages, "CatalogAttributes.razor"));
var service = Read(Path.Combine(services, "AttributeMappingService.cs"));
var program = Read(Path.Combine(root, "src", "PIM.Intranet", "Program.cs"));

Assert(program.Contains("AddScoped<AttributeMappingService>", StringComparison.Ordinal),
  "AttributeMappingService mora biti registriran.");

foreach (var markup in new[] { worklist, catalog })
{
  Assert(markup.Contains("Roles = \"ADMIN,CATALOG_EDITOR\"", StringComparison.Ordinal),
    "Urejanje atributov spreminja katalog, zato ni dovolj samo prijava.");
  Assert(markup.Contains("@rendermode InteractiveServer", StringComparison.Ordinal),
    "Brez interaktivnega nacina urejanje ne dela.");
  Assert(markup.Contains("ActorAsync", StringComparison.Ordinal),
    "Vsaka sprememba mora imeti akterja iz prijave.");
  Assert(markup.Contains("catch (Exception exception) { Error = exception.Message; }", StringComparison.Ordinal),
    "Napaka iz baze mora priti do uporabnika; prazen catch skrije zavrnitev pravila.");
  // Pravila so podatek v bazi. Ce jih stran podvoji, se bosta razsla.
  foreach (var forbidden in new[] { "canon.AttributeDefinition", "map.AttributeMap", "INSERT ", "UPDATE " })
    Assert(!markup.Contains(forbidden, StringComparison.Ordinal),
      "Stran ne sme sama pisati v bazo niti presojati sifranta: " + forbidden);
}

foreach (var procedure in new[]
{
  "intranet.GetSourceAttributes", "intranet.GetAttributeDefinitions",
  "map.SaveAttributeMap", "map.DeactivateAttributeMap",
  "canon.SaveAttributeDefinition", "canon.SaveAttributeTranslations"
})
  Assert(service.Contains(procedure, StringComparison.Ordinal),
    "Servis mora klicati postopek " + procedure + ".");

// Delovni seznam obstaja zaradi nepreslikanih; privzeto mora pokazati nalogo, ne registra.
Assert(worklist.Contains("string State = \"Nepreslikano\"", StringComparison.Ordinal),
  "Privzeti filter delovnega seznama mora biti Nepreslikano.");
Assert(worklist.Contains("row.ProductCount", StringComparison.Ordinal),
  "Vrstica mora povedati, koliko izdelkov je za tem atributom - brez tega ni prioritete.");
Assert(worklist.Contains("row.SampleValue", StringComparison.Ordinal),
  "Vzorec vrednosti je edino, po cemer clovek prepozna, kaj atribut sploh je.");

// Vir lahko nosi jezik ali enoto lastnosti, ne njene vrednosti - oboje mora biti izbirno.
Assert(worklist.Contains("ChosenLanguage", StringComparison.Ordinal)
  && worklist.Contains("ChosenIsUnit", StringComparison.Ordinal),
  "Preslikava mora omogociti jezik in oznako enote.");

// Sifrant: imena v vseh jezikih hkrati, enako kot pri kategorijah.
Assert(catalog.Contains("foreach (var language in Languages)", StringComparison.Ordinal)
  && catalog.Contains("row.Translations.TryGetValue", StringComparison.Ordinal),
  "Sifrant mora pokazati stanje vseh jezikov, ne samo enega.");
Assert(catalog.Contains("SaveTranslationsAsync", StringComparison.Ordinal),
  "Imena se morajo shraniti v enem koraku za vse jezike.");
Assert(catalog.Contains("!string.IsNullOrWhiteSpace(pair.Value)", StringComparison.Ordinal),
  "Prazno polje ne sme brisati imena.");

// Par enote je razlog, da ta stran obstaja: 34 kod ceka, cigava enota so.
Assert(catalog.Contains("ChosenPair", StringComparison.Ordinal)
  && catalog.Contains("row.IsUnitCandidate", StringComparison.Ordinal),
  "Enota mora biti povezljiva z lastnostjo, ki ji pripada.");
Assert(catalog.Contains("OnlyWithoutPair", StringComparison.Ordinal),
  "Enote brez para morajo biti svoj filter - to je delovni seznam koraka 3b.");
// Dve odlocitvi v isti vrstici; ena ne sme pojesti druge.
Assert(catalog.Contains("if (row.IsUnitCandidate)", StringComparison.Ordinal)
  && catalog.Contains("SaveDefinitionAsync", StringComparison.Ordinal),
  "Par enote se mora shraniti tudi, kadar se imena niso spremenila.");

// Obe strani morata voditi ena na drugo; loceni seznam brez povezave se ne uporablja.
Assert(worklist.Contains("nastavitve/atributi", StringComparison.Ordinal)
  && catalog.Contains("zajem/atributi", StringComparison.Ordinal),
  "Delovni seznam in sifrant morata biti povezana.");

// Prej so bili tu trije onemogoceni filtri z besedilom, da bralni model manjka.
Assert(!catalog.Contains("bralni model manjka", StringComparison.OrdinalIgnoreCase),
  "Onemogocenih filtrov z opravicilom ne sme biti vec - bralni model obstaja.");
Assert(!catalog.Contains("PimMissing", StringComparison.Ordinal),
  "Oznake manjkajocega bralnega modela ne sme biti vec.");


/* ─── Bralni model vrednosti atributa (P2-15, pregled 2026-09-08) ─────────────
   Stran /nastavitve/atributi/{koda} je bila brez vsebine, ker je manjkal intranet.GetAttributeValues.
   Migracija 184 ga je dodala, 185 pa popravila: vir vrednosti je iskala s korelirano podpoizvedbo
   nad map.ExtractedValue (20,25 mio vrstic, brez indeksa na TargetFieldCode) in je pri @Take = 50
   tekla 96.506 ms za podjetje 1 in 271.595 ms za podjetje 2. Vir odslej pride iz registra
   preslikav; merjeno 75 ms oziroma 64 ms, stran 60,1 s -> 0,1 s. */
var migrations = Path.Combine(root, "sql", "migrations");
Assert(File.Exists(Path.Combine(migrations, "184_AttributeValuesReadModel.sql")),
  "Manjka migracija 184 z bralnim modelom vrednosti atributa.");
var registrySource = Path.Combine(migrations, "185_AttributeValuesSourceFromRegistry.sql");
Assert(File.Exists(registrySource), "Manjka migracija 185, ki vir vzame iz registra.");
var registrySql = File.ReadAllText(registrySource);
Assert(!registrySql.Contains("FROM map.ExtractedValue", StringComparison.Ordinal),
  "Bralni model vrednosti atributa ne sme brati iz map.ExtractedValue: tabela ima cez 20 milijonov "
  + "vrstic in nima indeksa na TargetFieldCode, zato je bila stran neuporabna.");
Assert(registrySql.Contains("map.FieldMapping", StringComparison.Ordinal)
    && registrySql.Contains("map.SourceConnector", StringComparison.Ordinal),
  "Vir mora priti iz registra preslikav.");
Assert(registrySql.Contains("OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY", StringComparison.Ordinal),
  "Bralni model mora podpirati strani, ker jih stran uporablja.");

Console.WriteLine("PIM.F10.AttributeUxTests: vse pogodbe drzijo.");
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
