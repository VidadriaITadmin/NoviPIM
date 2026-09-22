namespace PIM.Outbound;

/// <summary>
/// Oblike dokumentov, zapisane v kodi.
///
/// Merodajna je baza (<c>out.SaopDocument</c>, migracija 085) — od tam jo bere pošiljatelj.
/// Ta seznam obstaja zato, da se lahko test brez baze prepriča, da se pogodbi nista razšli:
/// migracija, ki bi zamenjala pot ali koren dokumenta, bi tu padla in ne šele ob pošiljanju.
///
/// Vrednosti so prepisane iz resničnih poslanih dokumentov in iz swaggerja SAOP; kje je kaj,
/// pojasnjuje glava migracije 085.
/// </summary>
public static class SaopKnownShapes
{
  /// <summary>Izdelek — edini z gnezdenim ovojem pod korenom.</summary>
  public static readonly SaopDocumentShape Product = new(
    TargetKind: "SAOP_PRODUCT",
    EntityType: "Product",
    RootElementAdd: "ItemsGeneralData",
    RootElementUpdate: "ItemsGeneralData",
    ItemElement: "ItemGeneralData",
    KeyElements: ["ItemID"],
    AddPath: "api/Item/AddItemsGeneralData",
    AddOperation: "POST",
    UpdatePath: "api/Item/UpdateItemsGeneralData",
    UpdateOperation: "PATCH",
    StampAddElement: "ItemCreated",
    StampUpdateElement: "ItemLastModified",
    SuggestCodeElement: "SuggestFirstFreeCode");

  /// <summary>Stranka — edina, ki ima ob spremembi drug koren kot ob ustvarjanju.</summary>
  public static readonly SaopDocumentShape Customer = new(
    TargetKind: "SAOP_CUSTOMER",
    EntityType: "Customer",
    RootElementAdd: "Customer",
    RootElementUpdate: "CustomerV2",
    ItemElement: null,
    KeyElements: ["Code"],
    AddPath: "api/Customers/AddCustomer",
    AddOperation: "POST",
    UpdatePath: "api/V2/Customers/UpdateCustomer",
    UpdateOperation: "PATCH",
    StampAddElement: null,
    StampUpdateElement: null,
    SuggestCodeElement: "SuggestFirstFreeCode");

  /// <summary>Cenik — sprememba gre s POST, ne s PATCH.</summary>
  public static readonly SaopDocumentShape PriceList = new(
    TargetKind: "SAOP_PRICELIST",
    EntityType: "PriceList",
    RootElementAdd: "PriceList",
    RootElementUpdate: "PriceList",
    ItemElement: null,
    KeyElements: ["PriceListId"],
    AddPath: "api/pricelists/AddPriceLists",
    AddOperation: "POST",
    UpdatePath: "api/pricelists/ModifyPriceLists",
    UpdateOperation: "POST",
    StampAddElement: null,
    StampUpdateElement: null,
    SuggestCodeElement: null);

  /// <summary>Cena — edina s sestavljenim naravnim ključem.</summary>
  public static readonly SaopDocumentShape Price = new(
    TargetKind: "SAOP_PRICE",
    EntityType: "Price",
    RootElementAdd: "ItemPrice",
    RootElementUpdate: "ItemPrice",
    ItemElement: null,
    KeyElements: ["PriceListId", "ItemCode"],
    AddPath: "api/Price/AddPrices",
    AddOperation: "POST",
    UpdatePath: "api/V2/Price/ModifyPricesV2",
    UpdateOperation: "POST",
    StampAddElement: null,
    StampUpdateElement: null,
    SuggestCodeElement: null);

  /// <summary>
  /// Planski podatki izdelka — svoj dokument na svoji končni točki, ne del <see cref="Product"/>.
  /// SAOP pozna <c>ItemExcludeQtyReservation</c> samo v <c>PlanningData</c> (swagger); poslan v
  /// <c>ItemsGeneralData</c> je vrnil 500 (ACB.C3986100N, 22.9.2026). Stari PIM je kljukico
  /// pošiljal enako (<c>PIM_test/src/Services/SaopPlanningXmlBuilder.cs</c>). Končna točka pozna
  /// samo PATCH, zato ima ustvarjanje isto pot: planski podatki gredo šele, ko artikel obstaja.
  /// Ni v <see cref="All"/>, ker ima isti cilj kot izdelek — glej <see cref="SaopPlanningDocument"/>.
  /// </summary>
  public static readonly SaopDocumentShape ProductPlanning = new(
    TargetKind: "SAOP_PRODUCT",
    EntityType: "Product",
    RootElementAdd: "ItemsPlanningData",
    RootElementUpdate: "ItemsPlanningData",
    ItemElement: "ItemPlanningData",
    KeyElements: ["ItemID"],
    AddPath: "api/Item/UpdateItemsPlanningData",
    AddOperation: "PATCH",
    UpdatePath: "api/Item/UpdateItemsPlanningData",
    UpdateOperation: "PATCH",
    StampAddElement: null,
    StampUpdateElement: null,
    SuggestCodeElement: null);

  public static IReadOnlyList<SaopDocumentShape> All => [Product, Customer, PriceList, Price];

  public static SaopDocumentShape ByTargetKind(string targetKind) =>
    All.FirstOrDefault(shape => string.Equals(shape.TargetKind, targetKind, StringComparison.OrdinalIgnoreCase))
      ?? throw new SaopXmlBuildException($"Cilj {targetKind} ni znana entiteta SAOP.");
}
