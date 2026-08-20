namespace PIM.KatalogWorker;

/// <summary>
/// Kako se posamezna SAOP končna točka kliče. Trije vzorci, ne eden — to je lastnost API-ja,
/// ne naša izbira:
///
///   Paged  — Item končne točke sprejmejo searchQuery.page/pageSize in vračajo strani, dokler
///            ena ne pride prazna. Brez tega dobimo samo prvo stran (past prejšnje izvedbe).
///   Lookup — šifranti (valute, skladišča, jeziki, kupci) vrnejo vse naenkrat, brez paginacije.
///   Prices — kot Paged, a zahteva še priceListID in priceListDate; kliče se enkrat na cenik.
/// </summary>
public enum SaopEndpointKind
{
  Paged,
  Lookup,
  Prices
}

/// <param name="Key">Stabilen ključ za CLI izbiro končnih točk.</param>
/// <param name="Path">Relativna pot pod base URL.</param>
/// <param name="Kind">Vzorec klica.</param>
/// <param name="SupportsIncludeNonActive">Ali končna točka razume searchQuery.includeNonActiveItems.</param>
/// <param name="SupportsWatermark">Ali končna točka razume searchQuery.recordDtModifiedFrom (delta zajem).</param>
public sealed record SaopEndpoint(
  string Key,
  string Path,
  SaopEndpointKind Kind,
  bool SupportsIncludeNonActive = false,
  bool SupportsWatermark = false)
{
  /// <summary>
  /// Vrednost, ki gre v <c>raw.Inbox.EntityType</c> in v <c>map.EntityMapping.EntityType</c>.
  /// Za večino končnih točk je enaka <see cref="Key"/>; tam kjer se CLI ime razlikuje od DB entitete
  /// (GetItemsGeneralData→ItemGeneralData, GetPrices→Prices, GetItemsDescriptions→Descriptions)
  /// je nastavljena eksplicitno v <see cref="SaopEndpoints.All"/>.
  /// </summary>
  public string EntityType { get; init; } = Key;
}

/// <summary>
/// Vseh 16 bralnih končnih točk SAOP iCenter API. Seznam in poti so povzeti po delujočem
/// starem sistemu (<c>PIM_test\Windows_services\SAOP_API_WS\SaopCatalogWorker</c>) in potrjeni
/// z odgovori, posnetimi 27. 7. 2026 (vsi HTTP 200).
/// </summary>
public static class SaopEndpoints
{
  public const string GetItemsGeneralData = "GetItemsGeneralData";
  public const string GetItemsDescriptions = "GetItemsDescriptions";
  public const string GetItemsTitlesLanguage = "GetItemsTitlesLanguage";
  public const string GetItemsStockAccountingData = "GetItemsStockAccountingData";
  public const string GetItemsStockData = "GetItemsStockData";
  public const string GetItemsCustomProperties = "GetItemsCustomProperties";
  public const string GetItemsPlanningData = "GetItemsPlanningData";
  public const string GetItemCustomerDataV2 = "GetItemCustomerDataV2";
  public const string GetPrices = "GetPrices";
  public const string GetLanguages = "GetLanguages";
  public const string Currencies = "Currencies";
  public const string PriceLists = "PriceLists";
  public const string Warehouses = "Warehouses";
  public const string Customers = "Customers";
  public const string CustomerItemGroupDiscounts = "CustomerItemGroupDiscounts";
  public const string TechnologicalProcess = "TechnologicalProcess";

  public static readonly IReadOnlyList<SaopEndpoint> All =
  [
    new(GetItemsGeneralData, "api/Item/GetItemsGeneralData", SaopEndpointKind.Paged, SupportsIncludeNonActive: true, SupportsWatermark: true) { EntityType = "ItemGeneralData" },
    new(GetItemsDescriptions, "api/Item/GetItemsDescriptions", SaopEndpointKind.Paged, SupportsIncludeNonActive: true, SupportsWatermark: true) { EntityType = "Descriptions" },
    new(GetItemsTitlesLanguage, "api/Item/GetItemsTitlesLanguage", SaopEndpointKind.Paged, SupportsIncludeNonActive: true, SupportsWatermark: true),
    new(GetItemsCustomProperties, "api/Item/GetItemsCustomProperties", SaopEndpointKind.Paged, SupportsIncludeNonActive: true, SupportsWatermark: true),
    new(GetItemsPlanningData, "api/Item/GetItemsPlanningData", SaopEndpointKind.Paged, SupportsIncludeNonActive: true, SupportsWatermark: true),
    new(GetItemsStockData, "api/Item/GetItemsStockData", SaopEndpointKind.Paged, SupportsWatermark: true),
    new(GetItemsStockAccountingData, "api/Item/GetItemsStockAccountingData", SaopEndpointKind.Paged, SupportsWatermark: true),
    new(GetItemCustomerDataV2, "api/V2/Item/GetItemCustomerData", SaopEndpointKind.Paged, SupportsWatermark: true),
    new(GetPrices, "api/Price/GetPrices", SaopEndpointKind.Prices, SupportsWatermark: true) { EntityType = "Prices" },
    new(GetLanguages, "api/Language/GetLanguages", SaopEndpointKind.Lookup),
    new(Currencies, "api/currencies", SaopEndpointKind.Lookup),
    new(PriceLists, "api/pricelists", SaopEndpointKind.Lookup),
    new(Warehouses, "api/warehouses", SaopEndpointKind.Lookup),
    new(Customers, "api/Customers/GetCustomers", SaopEndpointKind.Lookup),
    new(CustomerItemGroupDiscounts, "api/V2/ComercialTerms/GetCustomerItemGroupDiscountsComercialTerms", SaopEndpointKind.Lookup),
    new(TechnologicalProcess, "api/TechnologicalProcess/GetTechnologicalProcess", SaopEndpointKind.Lookup)
  ];

  /// <summary>Končne točke, ki so bile v obtoku pred to razširitvijo — za primerjavo pred/po.</summary>
  public static readonly IReadOnlyList<string> Legacy =
    [GetItemsGeneralData, GetPrices, GetItemsDescriptions, Currencies, PriceLists];

  public static SaopEndpoint? Find(string key) =>
    All.FirstOrDefault(endpoint => string.Equals(endpoint.Key, key, StringComparison.OrdinalIgnoreCase));

  /// <summary>
  /// Razreši seznam ključev iz argumenta/konfiguracije. Prazno = vse. Neznan ključ je napaka,
  /// ne tiho preskočena vrstica — tipkarska napaka v Scheduled Tasku sicer pomeni endpoint,
  /// ki se nikoli ne zajame, in tega nihče ne opazi.
  /// </summary>
  public static IReadOnlyList<SaopEndpoint> Resolve(IReadOnlyList<string>? keys)
  {
    if (keys is null || keys.Count == 0)
    {
      return All;
    }

    var resolved = new List<SaopEndpoint>(keys.Count);
    var unknown = new List<string>();
    foreach (var key in keys)
    {
      var endpoint = Find(key);
      if (endpoint is null)
      {
        unknown.Add(key);
        continue;
      }

      if (!resolved.Contains(endpoint))
      {
        resolved.Add(endpoint);
      }
    }

    if (unknown.Count > 0)
    {
      throw new InvalidOperationException(
        $"Neznane končne točke: {string.Join(", ", unknown)}. Znane: {string.Join(", ", All.Select(endpoint => endpoint.Key))}.");
    }

    return resolved;
  }
}
