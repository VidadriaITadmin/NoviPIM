using PIM.XmlMapping;

// Odkrivanje izvornih atributov (migracija 121) nad pravima datotekama obeh dobaviteljev.
//
// Zakaj ta test obstaja. Ob prvem zagonu je register dobil EN atribut s stevcem ENA namesto
// sestdesetih. To ni izgledalo kot napaka, ampak kot prazen vir. Vzrok ni bil v tem razredu -
// worker je tekel z --no-build in staro knjiznico - a natanko zato mora odkrivanje imeti svoj
// test s stevilkami: prazen register in prazen vir sta na zaslonu isto in ju loci samo meritev.
//
// Test tece nad pravima datotekama obeh dobaviteljev in ne nad izmisljenim XML: oblika zapisa
// je pri vsakem dobavitelju drugacna in prav ta razlika je tisto, kar se lahko pokvari.

var root = FindRoot();
var extractor = new XPathMappingExtractor();

// --- Braytron: ena oblika za vse atribute, razlocevalec je slug ---------------------------
var braytron = ReadFixture(Path.Combine(root, "fixtures", "bt"));
var btFound = extractor.Discover(
  braytron,
  "/response/products/product",
  new AttributeDiscovery(".//attribute", "slug/text()", "title/text()", "value/text()", null));

Assert(btFound.Count >= 60,
  $"Braytronova datoteka ima cez 60 atributov; odkritih {btFound.Count}. Ena sama vrstica pomeni, da se je zunanja zanka koncala po prvem zapisu.");

// Sest atributov, ki jih danes nobena preslikava ne bere; register je edini, ki jih pokaze.
foreach (var expected in new[] { "type", "sensor_type", "led_quantity", "capacity_watt", "weight", "ean" })
  Assert(btFound.Any(attribute => attribute.Name == expected),
    "Braytron mora imeti odkrit atribut " + expected + " tudi brez preslikave.");

var slug = btFound.Single(attribute => attribute.Name == "ip");
Assert(slug.ProductCount > 100,
  $"Atribut ip mora biti stet cez veliko izdelkov, ne enkrat; steto {slug.ProductCount}.");
Assert(slug.Label is not null && slug.Value is not null,
  "Braytronov zapis nosi oznako in vrednost; register mora oboje zajeti.");

// --- Nowodvorski: en element na atribut, ime atributa je ime elementa ---------------------
var nowodvorski = ReadFixture(Path.Combine(root, "fixtures", "nw"));
var nwFound = extractor.Discover(
  nowodvorski,
  "/channel/products/product",
  new AttributeDiscovery(
    "attributes/*",
    null,
    "*[substring(local-name(), string-length(local-name()) - 4) = \"_name\"]",
    "*[substring(local-name(), string-length(local-name()) - 5) = \"_value\"]",
    "*[substring(local-name(), string-length(local-name()) - 4) = \"_unit\"]"));

Assert(nwFound.Count >= 20,
  $"Nowodvorski nosi cez dvajset atributov; odkritih {nwFound.Count}.");
Assert(nwFound.Any(attribute => attribute.Name == "attribute_ip"),
  "Ime atributa mora biti ime elementa, kadar NameXPath ni podan.");

// Enota je pri Nowodvorskem del zapisa atributa. Prav to je dokaz, da enota ne sodi v ime
// atributa - vir jo nosi loceno in tako jo mora videti tudi register.
Assert(nwFound.Any(attribute => attribute.Unit is not null),
  "Vsaj en Nowodvorski atribut nosi enoto; register jo mora zajeti.");
Assert(nwFound.Any(attribute => attribute.Label is not null),
  "Nowodvorski nosi cloveku berljivo oznako v otroku s pripono _name.");

var najpogostejsi = nwFound.OrderByDescending(attribute => attribute.ProductCount).First();
Assert(najpogostejsi.ProductCount > 1,
  $"Najpogostejsi atribut mora biti stet cez vec zapisov; steto {najpogostejsi.ProductCount}.");

Console.WriteLine(
  $"PIM.F5.AttributeDiscoveryTests: Braytron {btFound.Count} atributov, Nowodvorski {nwFound.Count}. Vse pogodbe drzijo.");
return 0;

static string ReadFixture(string folder)
{
  if (!Directory.Exists(folder)) throw new InvalidOperationException("Manjka mapa: " + folder);
  var file = Directory.EnumerateFiles(folder, "*.xml").OrderBy(path => path).FirstOrDefault()
    ?? throw new InvalidOperationException("V mapi ni datoteke XML: " + folder);
  return File.ReadAllText(file);
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
