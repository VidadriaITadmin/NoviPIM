namespace PIM.Outbound;

/// <summary>
/// Pogodba izdelka razdeljena na dva dokumenta: splošne podatke (<c>ItemsGeneralData</c>) in
/// planske podatke (<c>ItemsPlanningData</c>, migracija 263).
///
/// V <c>out.SaopXmlField</c> ostane ena pogodba za <c>SAOP_PRODUCT</c>: sporočila v vrsti,
/// odobritev in prevzem so po artiklu, ne po končni točki. Polja z ovojem
/// <see cref="Section"/> pa gredo v svoj dokument na <see cref="SaopKnownShapes.ProductPlanning"/>;
/// ključ (<c>ItemID</c>) je v obeh.
/// </summary>
public static class SaopPlanningDocument
{
  /// <summary>Ovoj planskih polj; v dokumentu planskih podatkov je hkrati ime podovoja.</summary>
  public const string Section = "PlanningData";

  public static bool AppliesTo(SaopDocumentShape shape) =>
    string.Equals(shape.TargetKind, SaopKnownShapes.Product.TargetKind, StringComparison.OrdinalIgnoreCase);

  /// <summary>Splošna pogodba brez planskih polj in planska pogodba s ključem; slednja je prazna, kadar planskih polj ni.</summary>
  public static (IReadOnlyList<SaopXmlField> General, IReadOnlyList<SaopXmlField> Planning) Split(
    SaopDocumentShape shape, IReadOnlyList<SaopXmlField> contract)
  {
    if (!AppliesTo(shape) || !contract.Any(IsPlanning)) return (contract, []);
    return (contract.Where(field => !IsPlanning(field)).ToArray(),
      contract.Where(field => field.IsKey || IsPlanning(field)).ToArray());
  }

  static bool IsPlanning(SaopXmlField field) => !field.IsKey && field.Section == Section;
}
