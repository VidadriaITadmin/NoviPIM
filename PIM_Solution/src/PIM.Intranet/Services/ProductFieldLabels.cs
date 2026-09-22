namespace PIM.Intranet.Services;

/// <summary>
/// Kako je polje (koda iz canon.FieldValue / val.FieldRequirement) poimenovano na kartici
/// izdelka (/izdelki/{ProductId}), da ga uporabnik prepozna tudi izven kartice — najprej za
/// izvoz validacijskih profilov (uporabnik 2026-09-11: "Prevedeno Polje... tell me how it
/// shows on product card").
///
/// Zakaj ločen razred in ne klic v ProductCard.razor: ta oznaka je danes v enajstih ločenih
/// seznamih Channel(...)/TextField(...) po zavihkih kartice (ERP/Komerciala/Splet), zgrajenih iz
/// živih podatkov izdelka (vrednost, lastnik, ali manjka) — tu pa je vprašanje samo ime, brez
/// izdelka. Podvajanje kode kartice bi zahtevalo ponarejen ProductDetailView; ta razred namesto
/// tega prepiše iste nize enkrat, na enem mestu, kot že velja za SaopFieldLabels.cs (izvoz SAOP
/// polj) — če se kartica preimenuje, se popravi tu.
/// </summary>
public static class ProductFieldLabels
{
  /// <summary>Točna imena, prepisana iz Channel(...)/TextField(...) klicev v ProductCard.razor.</summary>
  static readonly Dictionary<string, string> Exact = new(StringComparer.Ordinal)
  {
    ["Product.ItemID"] = "Šifra artikla",
    ["Product.EAN"] = "EAN",
    ["Product.AccountingGroup"] = "Knjižna skupina",
    ["Product.DiscountGroup"] = "Skupina popusta",
    ["Product.UoM"] = "Merska enota",
    ["Product.Supplier"] = "Dobavitelj",
    ["Product.Manufacturer"] = "Proizvajalec",
    ["Product.VatRate"] = "Davčna stopnja",
    ["ProductPlanning"] = "Izloči iz rezervacije zaloge",
    ["ProductCommercial.NetWeight"] = "Neto teža",
    ["ProductCommercial.GrossWeight"] = "Bruto teža",
    ["ProductCommercial.CustomsTariff"] = "Carinska / tarifna oznaka",
    ["ProductCommercial.CountryOfOrigin"] = "Država porekla",
    ["ProductCommercial.Pak1"] = "Količina pakiranja",
    ["ProductCommercial.Pak2"] = "Količina pakiranja (2)",
    ["Product.PiecesInPackage"] = "Kosov v paketu",
    ["ProductCommercial.PackageLength"] = "Dolžina",
    ["ProductCommercial.PackageWidth"] = "Širina",
    ["ProductCommercial.PackageHeight"] = "Višina",
    ["ProductCommercial.DimensionUnit"] = "Enota mer",
    ["ProductCommercial.Volume"] = "Prostornina",
    ["ProductCommercial.Dimensions"] = "Dimenzije artikla",
    ["Product.Department"] = "ABC klasifikacija",
    ["Product.ItemGroup"] = "Rabatna / skupina artikla",
    ["Product.IsActive"] = "Aktivnost",
    ["ProductCommercial.Purchase"] = "Nabavni podatki",
    ["ProductStockAccounting"] = "Knjigovodske šifre",
    ["Product.WebPublish"] = "Objava na spletu",
    ["ProductMedia"] = "Slike za splet",
    ["canon.WebSite"] = "Spletni kanali",
  };

  /// <summary>Slovensko ime vrste besedila; enako ProductCard.razor.TextLabel.</summary>
  public static string TextTypeLabel(string textType) => textType switch
  {
    "WEB_TITLE" => "Spletni naziv",
    "TITLE_ERP" => "ERP naziv",
    "TITLE_ERP2" => "ERP naziv 2",
    "TITLE_SHORT" => "ERP kratki naziv",
    "SEARCH_NAME" => "Ime za iskanje",
    "DESCRIPTION" => "Spletni opis",
    "DESCRIPTION_K" => "Kratek spletni opis",
    "DESCRIPTION_KD" => "Kratek spletni opis (dodatni)",
    "DESCRIPTION_KK" => "Ključne lastnosti (splet)",
    "DESCRIPTION_O" => "Spletna opomba",
    // 239: opisi iz SAOP, loceni od spletnih.
    "DESCRIPTION_ERP" => "ERP opis",
    "DESCRIPTION_ERP_K" => "ERP kratek opis",
    "DESCRIPTION_ERP_KD" => "ERP kratek opis (dodatni)",
    "DESCRIPTION_ERP_KK" => "ERP ključne lastnosti",
    "DESCRIPTION_ERP_O" => "ERP opomba",
    _ => textType,
  };

  /// <summary>
  /// Ali je vrsta besedila last ERP-ja (SAOP jo piše in ob vsakem zajemu prepiše) ali spleta (piše
  /// jo PIM: urednik, delovni zvezek, AI). Uporabnik 2026-09-21: »ERP opisi se pojavijo na kartici
  /// pod Splet – opisi« — do 239 sta si vrsti delili ime DESCRIPTION, zato kartica ni mogla ločiti.
  /// Pravilo: ERP nazivi (TITLE_ERP*, TITLE_SHORT, SEARCH_NAME) in ERP opisi (DESCRIPTION_ERP*);
  /// vse ostalo (WEB_TITLE, DESCRIPTION*) je spletno.
  /// </summary>
  public static bool IsErpTextType(string? textType) =>
    !string.IsNullOrWhiteSpace(textType)
    && (textType.StartsWith("TITLE_ERP", StringComparison.OrdinalIgnoreCase)
      || string.Equals(textType, "TITLE_SHORT", StringComparison.OrdinalIgnoreCase)
      || string.Equals(textType, "SEARCH_NAME", StringComparison.OrdinalIgnoreCase)
      || textType.StartsWith("DESCRIPTION_ERP", StringComparison.OrdinalIgnoreCase));

  /// <summary>Spletna vrsta besedila, ki jo kartica ponudi tudi brez obstoječe vrstice (naziv in opis).</summary>
  public static readonly IReadOnlyList<string> CoreWebTextTypes = ["WEB_TITLE", "DESCRIPTION"];

  /// <summary>Preostala polja brez lastnega mesta na kartici; enako ProductCard.razor.FieldLabel.</summary>
  static string Generic(string fieldKey) => fieldKey switch
  {
    "Product.ItemID" => "Šifra artikla",
    "Product.EAN" => "EAN",
    "Product.UoM" => "Merska enota",
    "Product.ItemGroup" => "Skupina artikla",
    "Product.Department" => "ABC klasifikacija",
    "Product.DiscountGroup" => "Skupina popusta",
    "Product.AccountingGroup" => "Knjižna skupina",
    "Product.Supplier" => "Dobavitelj",
    "Product.Manufacturer" => "Proizvajalec",
    "Product.IsActive" => "Aktiven",
    "Product.WebPublish" => "Objava na spletu",
    "ProductAttribute.Garancija" => "Garancija",
    "ProductCommercial.NetWeight" => "Neto teža",
    "ProductCommercial.GrossWeight" => "Bruto teža",
    "ProductCommercial.CustomsTariff" => "Carinska tarifa",
    "ProductCommercial.CountryOfOrigin" => "Država porekla",
    "ProductCommercial.Dimensions" => "Dimenzije",
    "ProductCommercial.Volume" => "Volumen",
    "ProductCommercial.PackageLength" => "Dolžina paketa",
    "ProductCommercial.PackageWidth" => "Širina paketa",
    "ProductCommercial.PackageHeight" => "Višina paketa",
    "ProductCommercial.DimensionUnit" => "Enota mer",
    "ProductCommercial.Pak1" => "Pakiranje 1",
    "ProductCommercial.Pak2" => "Pakiranje 2",
    _ => fieldKey,
  };

  /// <summary>
  /// Prevedeno ime polja, kot ga vidi uporabnik na kartici izdelka. Vrstni red ujemanja:
  /// 1) točno ime (Exact); 2) ProductText.VRSTA.jezik → ime vrste; 3) ProductAttribute.koda →
  /// sama koda (v tem katalogu je "koda" atributa že njegovo slovensko ime — glej
  /// canon.ProductAttribute/AttributeField v ProductCard.razor, ki isto kodo uporabi kot
  /// nalepko); 4) ProductCategory.stran → "Kategorija (stran)"; 5) splošni seznam; 6) polje
  /// samo, nespremenjeno — enako, kot bi ga pokazala kartica sama.
  /// </summary>
  public static string For(string fieldCode)
  {
    if (Exact.TryGetValue(fieldCode, out var exact)) return exact;

    if (fieldCode.StartsWith("ProductText.", StringComparison.Ordinal))
    {
      var rest = fieldCode["ProductText.".Length..];
      var dot = rest.IndexOf('.');
      var textType = dot < 0 ? rest : rest[..dot];
      var language = dot < 0 ? null : rest[(dot + 1)..];
      return language is null ? TextTypeLabel(textType) : $"{TextTypeLabel(textType)} ({language})";
    }

    if (fieldCode.StartsWith("ProductAttribute.", StringComparison.Ordinal))
      return fieldCode["ProductAttribute.".Length..];

    if (fieldCode.StartsWith("ProductCategory.", StringComparison.Ordinal))
      return $"Kategorija ({fieldCode["ProductCategory.".Length..]})";

    return Generic(fieldCode);
  }
}
