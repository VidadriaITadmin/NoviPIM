using System.Text;
using PIM.Outbound;

// F8 — pogodba XML za pisanje artiklov v SAOP.
//
// Zakaj ti testi obstajajo: XML za SAOP se ne da preveriti z branjem swaggerja. Swagger pove
// imena tipov, ne pa vrstnega reda elementov, ne katera polja SAOP dejansko sprejme in ne
// tega, kako izgleda odgovor. Zato je merilo tu drugačno — dokument, ki ga gradnik sestavi,
// se primerja z RESNIČNIM dokumentom, ki ga je stari sistem poslal in ga je SAOP sprejel
// (pim.SaopItemOutboundQueue v bazi PIM_test, artikel NW.12603, odgovor Created).
//
// Isti vir velja za napake: vseh šest sporočil spodaj je dobesedno prepisanih iz 130 zavrnitev
// v tej vrsti, vključno s pokvarjenim kodiranjem, v kakršnem so tam shranjena.

var contract = Contract();
var builder = new SaopItemXmlBuilder(contract);
var stamp = new DateTime(2026, 7, 23, 11, 31, 22, 1, DateTimeKind.Utc);

// --- 1) ADD: dokument mora biti enak resničnemu -------------------------------------

var values = new Dictionary<string, string?>
{
  ["ProductText.TITLE_ERP.sl"] = "SATURN S Beige",
  ["Product.UoM"] = "kom",
  ["Product.ItemGroup"] = "Nowodvorski",
  ["Product.AccountingGroup"] = "Nowodvorski",
  ["Product.WebPublish"] = "True",
  ["ProductCommercial.CustomsTariff"] = "94051990",
  ["Product.Department"] = "C",
  ["Product.EAN"] = "5903139126038",
  ["Product.DiscountGroup"] = "Nowodvorski",
  ["Product.IsActive"] = "True",
  ["Product.Supplier"] = "91086973",
  ["Product.Manufacturer"] = "00001625",
  ["ProductCommercial.NetWeight"] = "0.3800",
  ["ProductCommercial.GrossWeight"] = "0.6550",
  ["ProductCommercial.PackageWidth"] = "18.5000",
  ["ProductCommercial.PackageHeight"] = "25.0000",
  ["ProductCommercial.DimensionUnit"] = "cm",
  ["ProductCommercial.CountryOfOrigin"] = "PL"
};
var defaults = new Dictionary<string, string>
{
  ["GeneralData/ItemType"] = "B",
  ["GeneralData/VATRateID"] = "02",
  ["SalesData/AdditionalProperty4ID"] = "B2B"
};

var add = builder.Build(SaopIntent.Add, "NW.12603", values, defaults, stamp, suggestFirstFreeCode: true);

const string Resnicni = """
<ItemsGeneralData>
  <ItemGeneralData>
    <ItemID>NW.12603</ItemID>
    <ItemCreated>2026-07-23T11:31:22.001Z</ItemCreated>
    <ItemTitle1>SATURN S Beige</ItemTitle1>
    <GeneralData>
      <ItemType>B</ItemType>
      <ItemUnitOfMeas>kom</ItemUnitOfMeas>
      <VATRateID>02</VATRateID>
      <ItemGroup>Nowodvorski</ItemGroup>
      <AccountingBookGroupID>Nowodvorski</AccountingBookGroupID>
      <WebPublish>d</WebPublish>
      <CustomsTariffNo>94051990</CustomsTariffNo>
      <ItemDepartment>C</ItemDepartment>
      <ItemEANCode>5903139126038</ItemEANCode>
    </GeneralData>
    <SalesData>
      <DiscountGroup1ID>Nowodvorski</DiscountGroup1ID>
      <IsActive>D</IsActive>
      <AdditionalProperty1ID>C</AdditionalProperty1ID>
      <AdditionalProperty4ID>B2B</AdditionalProperty4ID>
    </SalesData>
    <StockData>
      <SupplierID>91086973</SupplierID>
      <ManufacturerID>00001625</ManufacturerID>
    </StockData>
    <PropertiesData>
      <ItemWeightPerUnit>0.3800</ItemWeightPerUnit>
      <ItemGrossWeight>0.6550</ItemGrossWeight>
      <ItemWidth>18.50000000</ItemWidth>
      <ItemHeight>25.00000000</ItemHeight>
      <ItemDimensionUOM>cm</ItemDimensionUOM>
      <ItemCountryOfOrigin>PL</ItemCountryOfOrigin>
    </PropertiesData>
    <SuggestFirstFreeCode>true</SuggestFirstFreeCode>
  </ItemGeneralData>
</ItemsGeneralData>
""";

Equal(Normalize("<?xml version=\"1.0\" encoding=\"utf-8\"?>" + Resnicni), Normalize(add.Xml),
  "ADD dokument se mora ujemati z resničnim, ki ga je SAOP sprejel");
Equal(0, add.MissingMandatory.Count, "Poln nabor podatkov ne sme javljati manjkajočih obveznih polj");

// --- 2) PATCH nosi samo izpolnjena polja --------------------------------------------
//
// To ni kozmetika: vsako poslano polje SAOP prepiše. Polje brez vrednosti bi pomenilo
// tiho brisanje podatka v ERP, konstanta iz privzetkov pa bi povozila vrednost, ki jo
// SAOP že ima in je PIM nikoli ni videl.

var samoEan = new Dictionary<string, string?> { ["Product.EAN"] = "5903139126038" };
var patch = builder.Build(SaopIntent.Update, "NW.12603", samoEan, defaults, stamp);

Equal(true, patch.Xml.Contains("<ItemLastModified>2026-07-23T11:31:22.001Z</ItemLastModified>"),
  "PATCH nosi ItemLastModified, ne ItemCreated");
Equal(false, patch.Xml.Contains("ItemCreated"), "PATCH ne sme nositi ItemCreated");
Equal(false, patch.Xml.Contains("SuggestFirstFreeCode"), "PATCH ne sme predlagati nove šifre");
Equal(false, patch.Xml.Contains("VATRateID"), "Privzetek ne sme povoziti vrednosti, ki jo SAOP že ima");
Equal(false, patch.Xml.Contains("<SalesData"), "Prazen ovoj ne sme v dokument");
Equal(false, patch.Xml.Contains("<PropertiesData"), "Prazen ovoj ne sme v dokument");
Equal(true, patch.Xml.Contains("<ItemEANCode>5903139126038</ItemEANCode>"), "Spremenjeno polje mora biti v dokumentu");
Equal(2, patch.ElementCount, "PATCH z eno spremembo nosi samo šifro in to polje");
Equal(0, patch.MissingMandatory.Count, "Za PATCH obveznost ADD polj ne velja");

// --- 3) ADK brez obveznih polj se ne pretvarja, da je v redu ------------------------

var prazen = builder.Build(SaopIntent.Add, "NW.99999", new Dictionary<string, string?>(), defaults, stamp);
Equal(true, prazen.MissingMandatory.Contains("Item/ItemTitle1"), "Manjkajoč naziv mora biti naveden");
Equal(true, prazen.MissingMandatory.Contains("GeneralData/ItemGroup"), "Manjkajoča skupina mora biti navedena");
Equal(false, prazen.MissingMandatory.Contains("GeneralData/ItemType"), "Polje s privzetkom ne manjka");
Equal(false, prazen.MissingMandatory.Contains("Item/ItemID"), "Šifra je naslov dokumenta in je vedno prisotna");

// --- 4) Oblika vrednosti -------------------------------------------------------------
//
// Decimalka s piko in fiksnimi mesti ne glede na nastavitev strežnika: ista koda bi sicer
// na slovenskem strežniku poslala '0,3800' in SAOP bi jo zavrnil.

var tuja = System.Globalization.CultureInfo.GetCultureInfo("sl-SI");
System.Globalization.CultureInfo.CurrentCulture = tuja;
var vejica = builder.Build(SaopIntent.Update, "X.1",
  new Dictionary<string, string?> { ["ProductCommercial.NetWeight"] = "0,38", ["ProductCommercial.PackageWidth"] = "18,5" },
  defaults, stamp);
Equal(true, vejica.Xml.Contains("<ItemWeightPerUnit>0.3800</ItemWeightPerUnit>"), "Teža gre s piko in štirimi mesti");
Equal(true, vejica.Xml.Contains("<ItemWidth>18.50000000</ItemWidth>"), "Dimenzija gre z osmimi mesti");

foreach (var (vhod, izhod) in new[] { ("1", "D"), ("True", "D"), ("D", "D"), ("0", "N"), ("False", "N"), ("N", "N") })
{
  var logicno = builder.Build(SaopIntent.Update, "X.1",
    new Dictionary<string, string?> { ["Product.IsActive"] = vhod }, defaults, stamp);
  Equal(true, logicno.Xml.Contains($"<IsActive>{izhod}</IsActive>"), $"IsActive '{vhod}' mora postati '{izhod}'");
}

// WebPublish je 'd' z malo, IsActive pa 'D' z veliko — tako je v resničnih dokumentih.
var splet = builder.Build(SaopIntent.Update, "X.1",
  new Dictionary<string, string?> { ["Product.WebPublish"] = "1", ["Product.IsActive"] = "1" }, defaults, stamp);
Equal(true, splet.Xml.Contains("<WebPublish>d</WebPublish>"), "WebPublish je 'd' z malo začetnico");
Equal(true, splet.Xml.Contains("<IsActive>D</IsActive>"), "IsActive je 'D' z veliko začetnico");

Throws(() => builder.Build(SaopIntent.Update, "X.1",
  new Dictionary<string, string?> { ["Product.IsActive"] = "mogoce" }, defaults, stamp),
  "Vrednost, ki ni ne DA ne NE, ne sme tiho odpasti");
Throws(() => builder.Build(SaopIntent.Update, "X.1",
  new Dictionary<string, string?> { ["ProductCommercial.NetWeight"] = "težka" }, defaults, stamp),
  "Vrednost, ki ni število, ne sme tiho odpasti");
Throws(() => builder.Build(SaopIntent.Update, "  ", new Dictionary<string, string?>(), defaults, stamp),
  "Dokument brez šifre artikla ni naslovljiv");

// --- 5) Branje odgovora ---------------------------------------------------------------

const string CreateOk = """
<?xml version="1.0" encoding="utf-8"?><CreateResult xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema"><Keys><Key><Name>SifraArtikla</Name><Value>NW.12606</Value></Key></Keys><ResultCode>Created</ResultCode><Errors /></CreateResult>
""";
var created = SaopResponseReader.Read(CreateOk);
Equal(SaopResultCode.Created, created.ResultCode, "Created je uspeh ustvarjanja");
Equal(true, created.IsSuccess, "Created mora šteti kot uspeh");
// Stari worker je iskal element ItemID in ga ni nikoli našel; šifra je pod Keys/Key.
Equal("NW.12606", created.AssignedItemId, "Dodeljena šifra pride iz Keys/Key[Name=SifraArtikla]/Value");

var updated = SaopResponseReader.Read("""
<?xml version="1.0" encoding="utf-8"?><UpdateResult xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema"><ResultCode>Ok</ResultCode><Errors /></UpdateResult>
""");
Equal(SaopResultCode.Ok, updated.ResultCode, "Ok je uspeh spremembe");
Equal(true, updated.IsSuccess, "Ok mora šteti kot uspeh");
Equal(null, updated.AssignedItemId, "Sprememba ne dodeli nove šifre");

// HTTP 200 z ResultCode Error je zavrnitev. Stari sistem je gledal samo HTTP kodo.
var lazniUspeh = SaopResponseReader.Read("<UpdateResult><ResultCode>Error</ResultCode><Errors><Error><Level>ValidationError</Level><Message>Napaka</Message></Error></Errors></UpdateResult>");
Equal(false, lazniUspeh.IsSuccess, "ResultCode Error je zavrnitev, tudi kadar je HTTP koda 200");
Equal(1, lazniUspeh.Errors.Count, "Napaka znotraj odgovora mora biti prebrana");

var neberljiv = SaopResponseReader.Read("to ni xml");
Equal(false, neberljiv.IsSuccess, "Neberljiv odgovor ne sme veljati za potrjeno spremembo");
Equal(false, SaopResponseReader.Read("").IsSuccess, "Prazen odgovor ne sme veljati za potrjeno spremembo");

// --- 6) Kodiranje odgovora -------------------------------------------------------------
//
// V stari vrsti so sporočila shranjena kot "?ifra carinske tarife": odgovor je bil prebran
// kot UTF-8, čeprav to ni bil. Uporabnik bi namesto navodila dobil zmazek.
Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
var cp1250 = Encoding.GetEncoding("windows-1250").GetBytes("šifra artikla ne obstaja");
Equal("šifra artikla ne obstaja", SaopResponseReader.DecodeBody(cp1250),
  "Odgovor v windows-1250 mora ohraniti šumnike");
Equal("šifra artikla ne obstaja", SaopResponseReader.DecodeBody(Encoding.UTF8.GetBytes("šifra artikla ne obstaja")),
  "Odgovor v UTF-8 mora ostati nedotaknjen");
Equal("šifra", SaopResponseReader.DecodeBody(cp1250[..5], "windows-1250"),
  "Kodiranje iz glave Content-Type ima prednost");

// --- 7) Prevod napak v navodilo ---------------------------------------------------------
//
// Vseh šest sporočil je dobesedno iz stare vrste. Prvi dve sta 118 od 130 vseh napak.

var zeObstaja = Advice("Zapis/zapisi za artikel/artikle :  BA.BA09.00723 že obstaja/obstajajo!");
Equal(SaopErrorKind.ItemAlreadyExists, zeObstaja.Kind, "Poslan ADD za obstoječ artikel");
Equal(true, zeObstaja.IsSelfHealing, "To zna PIM popraviti sam");
Equal(SaopIntent.Update, SaopErrorTranslator.Retry(zeObstaja), "Popravek je ponovno pošiljanje kot PATCH");
Equal(true, zeObstaja.ItemIds.Contains("BA.BA09.00723"), "Šifra artikla iz sporočila mora biti izluščena");

var neObstaja = Advice("šifra artikla  BA.BH85.00030 ne obstaja!");
Equal(SaopErrorKind.ItemNotFound, neObstaja.Kind, "Poslan PATCH za neobstoječ artikel");
Equal(SaopIntent.Add, SaopErrorTranslator.Retry(neObstaja), "Popravek je ponovno pošiljanje kot ADD");

// Isti sporočili s pokvarjenim kodiranjem, natanko kot sta zapisani v stari bazi.
Equal(SaopErrorKind.ItemAlreadyExists, Advice("Zapis/zapisi za artikel/artikle :  BA.BH85.00040 �e obstaja/obstajajo!").Kind,
  "Prepoznava ne sme biti odvisna od šumnikov");
Equal(SaopErrorKind.ItemNotFound, Advice("�ifra artikla  BA.BH85.00030 ne obstaja!").Kind,
  "Prepoznava ne sme biti odvisna od šumnikov");

var tarifa = Advice("Za naslednje artikle:  BA.BH85.00030, šifra carinske tarife ne obstaja v šifrantu!");
Equal(SaopErrorKind.CodebookMissing, tarifa.Kind, "Carinska tarifa ni v šifrantu");
Equal("GeneralData/CustomsTariffNo", tarifa.Field, "Navesti je treba, katero polje popraviti");
Equal(false, tarifa.IsSelfHealing, "Šifranta PIM ne sme popravljati sam");

Equal("GeneralData/ItemGroup", Advice("Za naslednje artikle:  BA.BH85.00040, skupina artikla ne obstaja v šifrantu!").Field,
  "Skupina artikla ni v šifrantu");
Equal("StockData/SupplierID", Advice("Za naslednje artikle:  BA.BH85.00040, šifra dobavitelja ne obstaja v šifrantu ali ni aktivna!").Field,
  "Dobavitelj ni v šifrantu ali ni aktiven");

var tip = Advice("Za naslednje artikle:  BA.BH85.00040, tip artikla ne obstaja v šifrantu! Dovoljene oznake: A, B, D, I,E, K, M, O, P, S, V.");
Equal("GeneralData/ItemType", tip.Field, "Tip artikla ni v šifrantu");
Equal(true, tip.Instruction.Contains("A, B, D"), "Navodilo mora našteti dovoljene oznake, ki jih je povedal SAOP");

var neznana = Advice("Nekaj popolnoma drugega se je zgodilo.");
Equal(SaopErrorKind.Unknown, neznana.Kind, "Nepoznanega sporočila ne smemo razlagati po svoje");
Equal(true, neznana.Instruction.Contains("Nekaj popolnoma drugega"), "Nepoznano sporočilo se pokaže dobesedno");

// Iz celotnega odgovora SAOP se izbere napaka, ki največ pove.
var izOdgovora = SaopErrorTranslator.Translate(SaopResponseReader.Read("""
<ArrayOfError><Error><Level>ValidationError</Level><Message>Zapis/zapisi za artikel/artikle :  BA.BA09.00723 že obstaja/obstajajo!</Message></Error></ArrayOfError>
""").Errors);
Equal(SaopErrorKind.ItemAlreadyExists, izOdgovora.Kind, "Napaka se prebere iz ovoja ArrayOfError");

// --- 8) Izbira med ADD in PATCH ----------------------------------------------------------

Equal(SaopIntent.Update, SaopIntentResolver.Resolve(new(ExistsInSaop: true)).Intent,
  "Artikel, ki ga poznamo iz zajema SAOP, gre kot sprememba");
Equal(SaopIntent.Add, SaopIntentResolver.Resolve(new(ExistsInSaop: false)).Intent,
  "Artikla, ki ga SAOP ne pozna, je treba ustvariti");
Equal(SaopIntent.Update, SaopIntentResolver.Resolve(new(false, SaopErrorKind.ItemAlreadyExists)).Intent,
  "Zavrnitev SAOP prevlada nad tem, kar sklepamo iz baze");
Equal(SaopIntent.Add, SaopIntentResolver.Resolve(new(true, SaopErrorKind.ItemNotFound)).Intent,
  "Zavrnitev SAOP prevlada nad tem, kar sklepamo iz baze");
Equal("POST", SaopIntentResolver.HttpOperation(SaopIntent.Add), "Nov artikel gre s POST");
Equal("PATCH", SaopIntentResolver.HttpOperation(SaopIntent.Update), "Sprememba gre s PATCH");
Equal("api/Item/AddItemsGeneralData", SaopIntentResolver.Endpoint(SaopIntent.Add), "Končna točka za nov artikel");
Equal("api/Item/UpdateItemsGeneralData", SaopIntentResolver.Endpoint(SaopIntent.Update), "Končna točka za spremembo");

Console.WriteLine("F8 SAOP XML: ADD proti resničnemu dokumentu, PATCH samo izpolnjena polja, oblika vrednosti, "
  + "branje odgovora, kodiranje, prevod vseh šestih napak in izbira ADD/PATCH PASS.");
return 0;

static SaopErrorAdvice Advice(string message) => SaopErrorTranslator.Translate(new SaopError("ValidationError", message));

static string Normalize(string value) => value.Replace("\r\n", "\n").Trim();

static void Equal<T>(T expected, T actual, string message)
{
  if (!EqualityComparer<T>.Default.Equals(expected, actual))
    throw new InvalidOperationException($"{message}\n  pričakovano: {expected}\n  dobljeno:    {actual}");
}

static void Throws(Action action, string message)
{
  try { action(); }
  catch (SaopXmlBuildException) { return; }
  throw new InvalidOperationException(message);
}

// Pogodba je tu zapisana enako kot v migraciji 081; da ne moreta razpasti narazen, jo
// integracijski test PIM.F8.Integration prebere iz baze in primerja s tem seznamom.
static SaopXmlField[] Contract() =>
[
  new("Item", "ItemID", "Product.ItemID", 10, true, "text", null, null),
  new("Item", "ItemTitle1", "ProductText.TITLE_ERP.sl", 30, true, "text", null, null),
  new("Item", "ItemTitle2", "ProductText.TITLE_ERP2.sl", 40, false, "text", null, null),
  new("GeneralData", "ItemType", null, 110, true, "text", null, null),
  new("GeneralData", "ItemUnitOfMeas", "Product.UoM", 120, true, "text", null, null),
  new("GeneralData", "VATRateID", null, 130, true, "text", null, null),
  new("GeneralData", "ItemGroup", "Product.ItemGroup", 140, true, "text", null, null),
  new("GeneralData", "AccountingBookGroupID", "Product.AccountingGroup", 150, true, "text", null, null),
  new("GeneralData", "WebPublish", "Product.WebPublish", 160, false, "bool", "d", "N"),
  new("GeneralData", "CustomsTariffNo", "ProductCommercial.CustomsTariff", 170, false, "text", null, null),
  new("GeneralData", "ItemDepartment", "Product.Department", 180, true, "text", null, null),
  new("GeneralData", "ItemEANCode", "Product.EAN", 190, false, "text", null, null),
  new("SalesData", "DiscountGroup1ID", "Product.DiscountGroup", 210, true, "text", null, null),
  new("SalesData", "IsActive", "Product.IsActive", 220, true, "bool", "D", "N"),
  new("SalesData", "AdditionalProperty1ID", "Product.Department", 230, false, "text", null, null),
  new("SalesData", "AdditionalProperty4ID", null, 240, false, "text", null, null),
  new("StockData", "SupplierID", "Product.Supplier", 310, true, "text", null, null),
  new("StockData", "ManufacturerID", "Product.Manufacturer", 320, false, "text", null, null),
  new("PropertiesData", "ItemWeightPerUnit", "ProductCommercial.NetWeight", 410, false, "decimal4", null, null),
  new("PropertiesData", "ItemGrossWeight", "ProductCommercial.GrossWeight", 420, false, "decimal4", null, null),
  new("PropertiesData", "ItemWidth", "ProductCommercial.PackageWidth", 430, false, "decimal8", null, null),
  new("PropertiesData", "ItemHeight", "ProductCommercial.PackageHeight", 440, false, "decimal8", null, null),
  new("PropertiesData", "ItemDimensionUOM", "ProductCommercial.DimensionUnit", 450, false, "text", null, null),
  new("PropertiesData", "ItemCountryOfOrigin", "ProductCommercial.CountryOfOrigin", 460, false, "text", null, null)
];
