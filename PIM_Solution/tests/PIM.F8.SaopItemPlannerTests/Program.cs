using PIM.Outbound;

// Vedenjski test nacrta dokumenta za en artikel (SaopItemPlanner).
//
// Zakaj je ta test pomembnejsi od videza strani: nacrt je edino mesto, kjer se odloci, ali gre
// artikel v SAOP kot nov (POST) ali kot sprememba (PATCH), in kaj tak dokument nosi. V stari
// vrsti (..\PIM_test, pim.SaopItemOutboundQueue) je 118 od 130 napak natanko ta odlocitev,
// ker jo je izbral clovek ob vnosu. Tu je izpeljana in mora ostati izpeljana.
//
// Druga stvar, ki jo test varuje: sprememba sme nositi SAMO vpisano. Vsako poslano polje SAOP
// prepise, zato bi dopolnjevanje spremembe s kanonicnimi vrednostmi pomenilo tiho vracanje
// starih podatkov v ERP.

var shape = SaopKnownShapes.Product;

// Ozka pogodba z natanko tistim, kar test potrebuje: kljuc, obvezni naziv, obvezni tip brez
// kljuca (pride iz privzetkov), neobvezni EAN, bool in decimalka.
SaopXmlField[] contract =
[
  new("Item", "ItemID", "Product.ItemID", 10, true, "text", null, null, IsKey: true),
  new("Item", "ItemTitle1", "ProductText.TITLE_ERP.sl", 30, true, "text", null, null),
  new("GeneralData", "ItemType", null, 110, true, "text", null, null),
  new("GeneralData", "ItemEANCode", "Product.EAN", 190, false, "text", null, null),
  new("SalesData", "IsActive", "Product.IsActive", 220, true, "bool", "D", "N"),
  new("PropertiesData", "ItemWeightPerUnit", "ProductCommercial.NetWeight", 410, false, "decimal4", null, null),
];

var defaults = new Dictionary<string, string> { ["GeneralData/ItemType"] = "B" };
var stamp = new DateTime(2026, 9, 2, 10, 30, 0, DateTimeKind.Utc);

// --- 1. Novega artikla SAOP ne pozna: POST, zig nastanka, sifro dodeli SAOP ----------------
var novi = SaopItemPlanner.Plan(shape, contract, "TEST.NOVI.1", existsInSaop: false,
  canonical: new Dictionary<string, string?>(),
  defaults: defaults,
  changes: new Dictionary<string, string?>
  {
    ["ProductText.TITLE_ERP.sl"] = "Nova svetilka",
    ["Product.IsActive"] = "da",
  },
  stampUtc: stamp);

Assert(novi.Intent == SaopIntent.Add, "Artikla, ki ga v kanonicnem modelu ni, SAOP se ne pozna — mora iti POST.");
Assert(novi.Operation == "POST" && novi.Path == "api/Item/AddItemsGeneralData", "Nov artikel gre na pot za ustvarjanje.");
Assert(novi.Error is null, "Nov artikel z izpolnjenimi obveznimi polji se mora sestaviti: " + novi.Error);
Assert(novi.MissingMandatory.Count == 0, "Obvezna polja so izpolnjena ali pokrita s privzetkom: " + string.Join(", ", novi.MissingMandatory));
Assert(novi.Xml.Contains("<ItemCreated>2026-09-02T10:30:00.000Z</ItemCreated>", StringComparison.Ordinal), "Ustvarjanje mora nositi zig nastanka.");
Assert(!novi.Xml.Contains("ItemLastModified", StringComparison.Ordinal), "Ustvarjanje ne nosi ziga spremembe.");
Assert(novi.Xml.Contains("<SuggestFirstFreeCode>true</SuggestFirstFreeCode>", StringComparison.Ordinal), "Ob ustvarjanju sifro dodeli SAOP — enako kot pri posiljanju.");
Assert(novi.Xml.Contains("<ItemType>B</ItemType>", StringComparison.Ordinal), "Polje, ki ga PIM ne hrani, mora priti iz privzetka.");
Assert(novi.Xml.Contains("<IsActive>D</IsActive>", StringComparison.Ordinal), "DA se mora zapisati s crko, ki jo SAOP sprejme, ne s 'True'.");
Assert(novi.CanSend, "Popoln nov artikel mora biti pripravljen za poslati.");

// --- 2. Nov artikel brez obveznega naziva: dokument obstaja, poslati se ne sme -------------
var nepopoln = SaopItemPlanner.Plan(shape, contract, "TEST.NOVI.2", existsInSaop: false,
  canonical: new Dictionary<string, string?>(),
  defaults: defaults,
  changes: new Dictionary<string, string?> { ["Product.EAN"] = "3830000000001" },
  stampUtc: stamp);

Assert(nepopoln.MissingMandatory.Contains("Item/ItemTitle1"), "Manjkajoci obvezni naziv mora biti imenovan.");
Assert(nepopoln.MissingMandatory.Contains("SalesData/IsActive"), "Manjkajoca obvezna oznaka aktivnosti mora biti imenovana.");
Assert(!nepopoln.CanSend, "Nepopoln dokument ne sme oditi — SAOP bi ga zavrnil, poskus pa bi bil porabljen.");
Assert(nepopoln.Xml.Length > 0, "Nepopoln dokument mora biti vseeno viden, sicer se ne vidi, kaj manjka.");

// --- 3. Nov artikel dopolni manjkajoce iz kanonicnega stanja -------------------------------
var novIzPim = SaopItemPlanner.Plan(shape, contract, "TEST.NOVI.3", existsInSaop: false,
  canonical: new Dictionary<string, string?>
  {
    ["ProductText.TITLE_ERP.sl"] = "Naziv iz PIM",
    ["Product.IsActive"] = "1",
    ["Product.EAN"] = "3830000000002",
  },
  defaults: defaults,
  changes: new Dictionary<string, string?> { ["ProductText.TITLE_ERP.sl"] = "Vpisani naziv" },
  stampUtc: stamp);

Assert(novIzPim.MissingMandatory.Count == 0, "Ustvarjanje mora manjkajoca obvezna polja dopolniti iz kanonicnega stanja.");
Assert(novIzPim.Xml.Contains("<ItemTitle1>Vpisani naziv</ItemTitle1>", StringComparison.Ordinal), "Vpisano ima prednost pred kanonicnim.");
Assert(novIzPim.Xml.Contains("<ItemEANCode>3830000000002</ItemEANCode>", StringComparison.Ordinal), "Kanonicna vrednost, ki je urednik ni spreminjal, gre pri ustvarjanju vseeno v dokument.");

// --- 4. Obstojec artikel: PATCH in SAMO vpisano --------------------------------------------
var sprememba = SaopItemPlanner.Plan(shape, contract, "BA.BP07.20380", existsInSaop: true,
  canonical: new Dictionary<string, string?>
  {
    ["ProductText.TITLE_ERP.sl"] = "Stari naziv",
    ["Product.EAN"] = "5949097749636",
    ["Product.IsActive"] = "1",
  },
  defaults: defaults,
  changes: new Dictionary<string, string?> { ["Product.EAN"] = "3830000000003" },
  stampUtc: stamp);

Assert(sprememba.Intent == SaopIntent.Update, "Artikel iz kanonicnega modela pride samo iz zajema SAOP — mora iti PATCH.");
Assert(sprememba.Operation == "PATCH" && sprememba.Path == "api/Item/UpdateItemsGeneralData", "Sprememba gre na pot za spremembo.");
Assert(sprememba.Xml.Contains("<ItemEANCode>3830000000003</ItemEANCode>", StringComparison.Ordinal), "Vpisana vrednost mora biti v dokumentu.");
Assert(!sprememba.Xml.Contains("Stari naziv", StringComparison.Ordinal), "Sprememba ne sme nositi kanonicnih vrednosti — poslano polje SAOP prepise.");
Assert(!sprememba.Xml.Contains("<IsActive>", StringComparison.Ordinal), "Sprememba ne sme nositi polja, ki ga urednik ni vpisal.");
Assert(!sprememba.Xml.Contains("<ItemType>", StringComparison.Ordinal), "Privzetki ob spremembi ne smejo povoziti tega, kar SAOP ze ima.");
Assert(sprememba.Xml.Contains("<ItemLastModified>2026-09-02T10:30:00.000Z</ItemLastModified>", StringComparison.Ordinal), "Sprememba mora nositi zig spremembe.");
Assert(!sprememba.Xml.Contains("SuggestFirstFreeCode", StringComparison.Ordinal), "Ob spremembi sifre ne dodeljuje nihce.");
Assert(sprememba.MissingMandatory.Count == 0, "Pri spremembi obveznost ADD polj ne velja.");
Assert(sprememba.ChangeCount == 1, "Steti se morajo samo vpisana polja.");

// --- 5. Prazna celica pomeni "ne dotikaj se", ne "izprazni" --------------------------------
var prazna = SaopItemPlanner.Plan(shape, contract, "BA.BP07.20380", existsInSaop: true,
  canonical: new Dictionary<string, string?>(),
  defaults: defaults,
  changes: new Dictionary<string, string?> { ["Product.EAN"] = "   ", ["ProductText.TITLE_ERP.sl"] = null },
  stampUtc: stamp);

Assert(prazna.ChangeCount == 0, "Prazna celica ni sprememba.");
Assert(!prazna.Xml.Contains("<ItemEANCode", StringComparison.Ordinal), "Prazna celica ne sme v SAOP izbrisati vrednosti.");
Assert(!prazna.CanSend, "Dokument brez vsebine ni za poslati.");

// --- 6. Zavrnitev SAOP prevlada nad stanjem baze -------------------------------------------
var poZavrnitvi = SaopItemPlanner.Plan(shape, contract, "TEST.NOVI.4", existsInSaop: false,
  canonical: new Dictionary<string, string?>(),
  defaults: defaults,
  changes: new Dictionary<string, string?> { ["Product.EAN"] = "3830000000004" },
  stampUtc: stamp,
  previousRejection: SaopErrorKind.ItemAlreadyExists);

Assert(poZavrnitvi.Intent == SaopIntent.Update, "Ce je SAOP rekel, da artikel ima, je naslednji poskus PATCH — tudi ce ga v nasi bazi ni.");

// --- 7. Vrednost, ki ni stevilo, ne sme tiho oditi -----------------------------------------
var napacna = SaopItemPlanner.Plan(shape, contract, "BA.BP07.20380", existsInSaop: true,
  canonical: new Dictionary<string, string?>(),
  defaults: defaults,
  changes: new Dictionary<string, string?> { ["ProductCommercial.NetWeight"] = "priblizno pol kile" },
  stampUtc: stamp);

Assert(napacna.Error is not null, "Vrednost, ki ni stevilo, mora dati napako in ne dokumenta.");
Assert(napacna.Xml.Length == 0, "Ob napaki dokumenta ni.");
Assert(!napacna.CanSend, "Ob napaki se ne posilja.");

// Decimalka mora iti s piko ne glede na obmocne nastavitve streznika.
var decimalka = SaopItemPlanner.Plan(shape, contract, "BA.BP07.20380", existsInSaop: true,
  canonical: new Dictionary<string, string?>(), defaults: defaults,
  changes: new Dictionary<string, string?> { ["ProductCommercial.NetWeight"] = "0,62" }, stampUtc: stamp);
Assert(decimalka.Xml.Contains("<ItemWeightPerUnit>0.6200</ItemWeightPerUnit>", StringComparison.Ordinal),
  "Decimalka mora iti s piko in fiksnim stevilom mest: " + decimalka.Xml);

// --- 8. Brez sifre dokumenta ni mogoce nasloviti -------------------------------------------
var brezSifre = SaopItemPlanner.Plan(shape, contract, "   ", existsInSaop: false,
  canonical: new Dictionary<string, string?>(), defaults: defaults,
  changes: new Dictionary<string, string?> { ["Product.EAN"] = "3830000000005" }, stampUtc: stamp);

Assert(brezSifre.Error is not null, "Brez sifre artikla mora nacrt povedati napako, ne vreci izjeme.");
Assert(!brezSifre.CanSend, "Brez sifre se ne posilja.");

Console.WriteLine("F8 SAOP item planner PASS.");

static void Assert(bool condition, string message)
{
  if (!condition) throw new InvalidOperationException(message);
}
