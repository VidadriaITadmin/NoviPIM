using PIM.B2bWorker;

var mappings = new[]
{
  new B2bFieldMapping("CustomerCode", "Customer.Key", true),
  new B2bFieldMapping("CustomerName", "Customer.Name", true),
  new B2bFieldMapping("PriceList", "Customer.PriceList", false)
};
var mapper = new ConfiguredB2bMapper();
var first = mapper.Map("Customers", "{\"CustomerCode\":\"C-1\",\"CustomerName\":\"Topdom\",\"PriceList\":\"B2B\",\"FutureField\":\"x\"}", mappings);
Equal("C-1", first.Values["Customer.Key"], "Customer key");
Equal("Topdom", first.Values["Customer.Name"], "Customer name");
Equal("B2B", first.Values["Customer.PriceList"], "Price list");
Equal("FutureField", first.Rejections.Single().SourceField, "Neznano polje mora v queue.");
Equal("UnmappedField", first.Rejections.Single().ReasonCode, "Stabilna šifra zavrnitve.");
Equal(false, first.IsAccepted, "Nepreslikan zapis je strogo zavrnjen.");

var replay = mapper.Map("Customers", first.RawPayload, mappings.Append(new("FutureField", "Customer.Future", false)));
Equal("x", replay.Values["Customer.Future"], "Replay uporabi novo konfiguracijo.");
Equal(0, replay.Rejections.Count, "Replay razreši neznano polje.");
Equal(first.RawPayload, replay.RawPayload, "Replay ne spremeni raw payload-a.");
Equal(true, replay.IsAccepted, "Replay je sprejet šele po popolni preslikavi.");

var configuration = new List<B2bFieldMapping> { new("ExternalId", "Any.Key", true) };
var generic = mapper.Map("CompletelyNewEntity", "{\"ExternalId\":42}", configuration);
configuration[0] = new("Other", "Other.Key", true);
Equal("42", generic.Values["Any.Key"], "Rezultat je nespremenljiv posnetek generične konfiguracije.");
Equal(0, generic.Rejections.Count, "Entiteta in imena polj niso kodirana v mapperju.");
Throws<NotSupportedException>(() => ((IDictionary<string, string?>)generic.Values).Add("Changed", "x"), "Rezultat preslikave mora biti read-only.");

var missing = mapper.Map("Customers", "{\"CustomerName\":\"Brez kode\"}", mappings);
Equal("MissingRequiredField", missing.Rejections.Single(x => x.SourceField == "CustomerCode").ReasonCode, "Obvezno polje.");

Throws<ArgumentException>(() => mapper.Map("Customers", "{\"A\":\"1\"}", new[]
{
  new B2bFieldMapping("A", "One", false),
  new B2bFieldMapping("a", "Two", false)
}), "Dvoumna konfiguracija mora biti zavrnjena.");

var discounts = mapper.Map("CustomerItemGroupDiscounts", "{\"Partner\":\"C-1\",\"Skupina\":\"BA\",\"Rabat\":\"12.5\"}", new[]
{
  new B2bFieldMapping("Partner", "GroupDiscount.CustomerKey", true),
  new B2bFieldMapping("Skupina", "GroupDiscount.ItemGroup", true),
  new B2bFieldMapping("Rabat", "GroupDiscount.Percent", true)
});
Equal("12.5", discounts.Values["GroupDiscount.Percent"], "Poljubna source imena delujejo le prek konfiguracije.");

var fixturePath = Path.Combine(FindRoot(), "fixtures/b2b/customers.json");
var before = File.GetLastWriteTimeUtc(fixturePath);
var fixture = await B2bFixtureSource.ReadAsync(fixturePath);
Equal("Customers", fixture.EntityType, "Fixture entity");
Equal(2, fixture.Records.Count, "Fixture records");
Equal(64, fixture.PayloadHash.Length, "SHA-256");
Equal(before, File.GetLastWriteTimeUtc(fixturePath), "Fixture vir ostane read-only.");
// Naloga 6 (odlocitev uporabnika 2026-08-22): MagentoExportRunner.cs ostane v repozitoriju, ceprav
// je mrtva koda — priklopljen je MagentoExportCommand. Dokler ga nihce ne klice, sta dve izvedbi
// istega izvoza nevarnost samo na papirju; nevarna postane takrat, ko ga kdo prikljuci in se izvedbi
// tiho razideta. Ta trditev pade prav takrat in odlocitev o brisanju pride nazaj z vec podatki.
var runnerUsages = Directory
  .EnumerateFiles(FindRoot(), "*.cs", SearchOption.AllDirectories)
  .Where(path => !path.Contains($"{Path.DirectorySeparatorChar}bin{Path.DirectorySeparatorChar}")
    && !path.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}")
    && !path.EndsWith("MagentoExportRunner.cs", StringComparison.OrdinalIgnoreCase)
    && !path.Contains("PIM.F7.MappingTests"))
  // Omemba v komentarju ni uporaba: MagentoExportCommand ga navaja v SQL komentarju kot vir istega
  // pravila. Steje samo vrstica kode, zato komentarji (C# in SQL) izpadejo iz iskanja.
  .Where(path => File.ReadLines(path).Any(line =>
  {
    var trimmed = line.TrimStart();
    if (trimmed.StartsWith("//", StringComparison.Ordinal) || trimmed.StartsWith("--", StringComparison.Ordinal)
      || trimmed.StartsWith("*", StringComparison.Ordinal) || trimmed.StartsWith("/*", StringComparison.Ordinal))
      return false;
    return line.Contains("MagentoExportRunner", StringComparison.Ordinal);
  }))
  .Select(path => Path.GetFileName(path))
  .OrderBy(name => name, StringComparer.Ordinal)
  .ToArray();
Equal(0, runnerUsages.Length,
  $"MagentoExportRunner je mrtva koda in mora tako ostati; sklicujejo se nanj: {string.Join(", ", runnerUsages)}");

Console.WriteLine("F7 mapping: konfiguracijski landing, replay in zavrnitve PASS.");
await MagentoExportTests.RunAllAsync();

static string FindRoot()
{
  var directory = new DirectoryInfo(Directory.GetCurrentDirectory());
  while (directory is not null)
  {
    if (File.Exists(Path.Combine(directory.FullName, "PIM.sln"))) return directory.FullName;
    var solution = Path.Combine(directory.FullName, "PIM_Solution");
    if (File.Exists(Path.Combine(solution, "PIM.sln"))) return solution;
    directory = directory.Parent;
  }
  throw new InvalidOperationException("PIM_Solution ni najden.");
}
static void Equal<T>(T expected,T actual,string message) { if(!EqualityComparer<T>.Default.Equals(expected,actual))throw new InvalidOperationException($"{message}: pričakovano {expected}, dejansko {actual}."); }
static void Throws<T>(Action action,string message) where T : Exception { try { action(); } catch(T) { return; } throw new InvalidOperationException(message); }
