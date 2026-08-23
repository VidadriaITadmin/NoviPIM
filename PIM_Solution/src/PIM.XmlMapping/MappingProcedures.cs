namespace PIM.XmlMapping;

/// <summary>
/// Kateri postopek obdela kateri svet iz <c>map.EntityMapping.TargetDomain</c>.
///
/// Zakaj je ta seznam tu in ne samo v <see cref="SqlMappingPipeline"/>: migracija 082 je
/// zapisala preslikave za sifrante, konte zaloge in planiranje ter zanje ustvarila tri
/// postopke — poklical pa jih ni nihce. Vrstice so bile v registru, tabele prazne, in nihce
/// tega ni videl, dokler ni nekdo prestel vrstic v <c>canon</c>. Seznam je zato eno mesto,
/// ki ga preveri test (<c>PIM.F5.Integration</c>): vsak dejaven <c>TargetDomain</c> v bazi
/// mora imeti tu svoj postopek.
/// </summary>
public static class MappingProcedures
{
  /// <summary>Svet, ki ga obdela <c>map.ProcessRawInbox</c> sam — nima svojega postopka.</summary>
  public const string ProductDomain = "Product";

  /// <param name="TargetDomain">Vrednost iz <c>map.EntityMapping.TargetDomain</c>.</param>
  /// <param name="ProcedureName">Postopek, ki ta svet prenese iz izluscenih vrednosti v katalog.</param>
  public sealed record Step(string TargetDomain, string ProcedureName);

  /// <summary>
  /// Vrstni red ni nakljucen in ni abecedni:
  ///   1. sifranti (skladisca, jeziki, valute/ceniki/tehnoloski proces) — nanje se ostalo sklicuje;
  ///   2. svetovi, vezani na izdelek — tecejo po <c>map.ProcessRawInbox</c>, ki je izdelek ze
  ///      nasel ali ustvaril;
  ///   3. stranke pred artiklom pri stranki, da je ime stranke znano, preden se nanjo veze artikel.
  /// Postopek nad virom brez svoje entitete ne naredi nicesar, zato jih klicemo brezpogojno.
  /// </summary>
  public static readonly IReadOnlyList<Step> All =
  [
    new("Warehouse", "map.ProcessWarehouseInbox"),
    new("Language", "map.ProcessLanguageInbox"),
    new("Codebook", "map.ProcessCodebookInbox"),
    new("ProductText", "map.ProcessProductTextInbox"),
    new("ProductAttributePair", "map.ProcessAttributePairInbox"),
    new("ProductStockPolicy", "map.ProcessStockPolicyInbox"),
    new("ProductStockAccounting", "map.ProcessStockAccountingInbox"),
    new("ProductPlanning", "map.ProcessPlanningInbox"),
    new("Customer", "map.ProcessCustomerInbox"),
    new("CustomerGroupDiscount", "map.ProcessCustomerGroupDiscountInbox"),
    new("CustomerItem", "map.ProcessCustomerItemInbox")
  ];

  /// <summary>Svetovi, ki jih ta seznam pokriva, skupaj s tistim, ki ga obdela ProcessRawInbox.</summary>
  public static IReadOnlySet<string> CoveredDomains =>
    All.Select(step => step.TargetDomain).Append(ProductDomain).ToHashSet(StringComparer.OrdinalIgnoreCase);
}
