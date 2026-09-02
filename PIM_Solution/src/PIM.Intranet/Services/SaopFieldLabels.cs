namespace PIM.Intranet.Services;

/// <summary>
/// Slovenska imena elementov dokumenta <c>ItemsGeneralData</c> in njegovih ovojev.
///
/// Zakaj tu in ne v bazi: <c>out.SaopXmlField</c> opisuje OBLIKO dokumenta — kje v XML stoji
/// kateri element. Kako se element imenuje v slovenščini, je vprašanje vmesnika in ne pogodbe
/// s SAOP; register zaradi preimenovanja oznake ne sme dobiti migracije.
///
/// Imena so prepisana iz kataloga starega sistema (<c>..\PIM_test\src\Services\
/// SaopItemFieldCatalog.cs</c>, samo branje po AGENTS.md §1), ker jih uporabniki poznajo že
/// desetletje in bi vsak nov prevod pomenil, da isto polje v dveh sistemih ni isto polje.
/// Seznam je namenoma daljši od današnje pogodbe: ko register dobi novo polje, ima oznako
/// takoj in ne šele ob naslednji spremembi kode.
///
/// Element brez zapisane oznake ne pokvari vmesnika — pokaže se njegovo ime iz SAOP.
/// </summary>
public static class SaopFieldLabels
{
  static readonly Dictionary<string, string> Elements = new(StringComparer.OrdinalIgnoreCase)
  {
    // Sistemski elementi (v pogodbi nastopajo kot ključ ali žig)
    ["ItemID"] = "Šifra artikla",
    ["ItemCreated"] = "Datum nastanka",
    ["ItemLastModified"] = "Datum spremembe",
    ["SuggestFirstFreeCode"] = "SAOP naj predlaga prvo prosto šifro",

    // Neposredno pod <ItemGeneralData>
    ["ItemTitle1"] = "Naziv 1",
    ["ItemTitle2"] = "Naziv 2",

    // GeneralData
    ["ItemTitleShort"] = "Kratek naziv",
    ["ItemType"] = "Tip artikla",
    ["ItemUnitOfMeas"] = "Merska enota",
    ["VATRateID"] = "DDV (stopnja)",
    ["VATRefund"] = "Povračilo DDV",
    ["ExciseTaxID"] = "Trošarina",
    ["ExciseConverter"] = "Trošarina — pretvornik",
    ["ItemGroup"] = "Skupina artikla",
    ["WebPublish"] = "Objava na spletu",
    ["ItemFirstPublished"] = "Prvič objavljeno",
    ["VATInvoiceType"] = "Tip računa DDV",
    ["ItemComparisonCode"] = "Primerjalna koda",
    ["ItemSearchName"] = "Iskalni naziv",
    ["ItemClassification"] = "Klasifikacija",
    ["CustomsTariffNo"] = "Carinska tarifa",
    ["ClassOEEO"] = "Razred OEEO",
    ["ItemEANCode"] = "EAN",
    ["ItemDepartment"] = "Oddelek (ABC)",
    ["AccountingBookGroupID"] = "Knjižna skupina",
    ["ExtraUOM"] = "Dodatna merska enota",
    ["ItemQuantityExtraUOM"] = "Količina dodatne ME",
    ["Priority"] = "Prioriteta",
    ["ParentItemID"] = "Nadrejeni artikel",
    ["ParentItemQtyConverter"] = "Pretvornik količine (nadrejeni)",
    ["ParentItemPriceConverter"] = "Pretvornik cene (nadrejeni)",

    // SalesData
    ["Warranty"] = "Garancija",
    ["DiscountGroup1ID"] = "Rabatna skupina 1",
    ["DiscountGroup2ID"] = "Rabatna skupina 2",
    ["DiscountGroup3ID"] = "Rabatna skupina 3",
    ["DiscountGroup4ID"] = "Rabatna skupina 4",
    ["DiscountGroup5ID"] = "Rabatna skupina 5",
    ["CommissionGroupID"] = "Provizijska skupina",
    ["PeriodicID"] = "Periodika",
    ["FastCode"] = "Hitra koda",
    ["MinSalesPrice"] = "Najnižja prodajna cena",
    ["IsActive"] = "Aktiven",
    ["ItemStatus"] = "Status artikla",
    ["SalesPricePercentage"] = "Prodajni pribitek %",
    ["RetailPricePercentage"] = "Maloprodajni pribitek %",
    ["RebateCalculation"] = "Obračun rabata",
    ["SalesPriceChange"] = "Sprememba prodajne cene",
    ["RetailPriceChange"] = "Sprememba maloprodajne cene",
    ["MaintainTradeMargin"] = "Ohrani maržo",
    ["PlannedPrice"] = "Planirana cena",
    ["AdditionalProperty1ID"] = "Dodatna lastnost 1",
    ["AdditionalProperty2ID"] = "Dodatna lastnost 2",
    ["AdditionalProperty3ID"] = "Dodatna lastnost 3",
    ["AdditionalProperty4ID"] = "Dodatna lastnost 4",

    // StockData
    ["ItemHasSeries"] = "Ima serije",
    ["WarningDays"] = "Dni opozorila",
    ["MandatorySampling"] = "Obvezno vzorčenje",
    ["SerialNo"] = "Serijska številka",
    ["FixedPrice"] = "Fiksna cena",
    ["WithoutSharedCosts"] = "Brez skupnih stroškov",
    ["SharedCostID"] = "Skupni strošek",
    ["UllageID"] = "Kalo",
    ["CooperationAddOnID"] = "Kooperacija",
    ["ConsignorID"] = "Konsignator",
    ["SupplierID"] = "Dobavitelj",
    ["ManufacturerID"] = "Proizvajalec",
    ["TemplateGroupID"] = "Skupina predlog",

    // PropertiesData
    ["ItemWeightPerUnit"] = "Neto teža na enoto",
    ["ItemVolumePerUnit"] = "Volumen na enoto",
    ["ItemQuantityOfPackaging"] = "Količina v pakiranju",
    ["ItemQuantityOfPackaging2"] = "Količina v pakiranju 2",
    ["PaperWeight"] = "Teža papirja",
    ["ItemGrossWeight"] = "Bruto teža",
    ["ItemUOMPriceList"] = "ME za cenik",
    ["ItemQuantityUOMPriceList"] = "Količina ME za cenik",
    ["Package"] = "Embalaža",
    ["Voucher"] = "Vrednostni bon",
    ["ItemSequenceNumber"] = "Zaporedna številka",
    ["EnvironmentalTax"] = "Okoljska dajatev",
    ["ItemCountryOfOrigin"] = "Država porekla",
    ["OriginFromCustomerUser"] = "Poreklo od stranke",
    ["Contribution"] = "Prispevek",
    ["ContributionType"] = "Tip prispevka",
    ["ItemPackageID"] = "Embalaža (šifra)",
    ["ItemPackageUOM"] = "ME embalaže",
    ["ItemLength"] = "Dolžina",
    ["ItemWidth"] = "Širina",
    ["ItemHeight"] = "Višina",
    ["ItemDimensionUOM"] = "Enota dimenzij",
    ["ADRID"] = "ADR",
  };

  static readonly Dictionary<string, string> Sections = new(StringComparer.OrdinalIgnoreCase)
  {
    ["Item"] = "Osnovno",
    ["GeneralData"] = "Splošni podatki",
    ["SalesData"] = "Prodajni podatki",
    ["StockData"] = "Zaloga in dobavitelj",
    ["PropertiesData"] = "Lastnosti",
  };

  /// <summary>Slovenska oznaka elementa; kadar je ni, ostane ime iz SAOP.</summary>
  public static string For(string elementName) =>
    Elements.TryGetValue(elementName, out var label) ? label : elementName;

  /// <summary>Slovensko ime ovoja; kadar ga ni, ostane ime iz SAOP.</summary>
  public static string Section(string section) =>
    Sections.TryGetValue(section, out var label) ? label : section;
}
