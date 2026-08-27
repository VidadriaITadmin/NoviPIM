namespace PIM.Intranet.Services;

public enum PimValidationLayer
{
  ErpSlo,
  ErpEuThird,
  Komerciala,
  Splet,
}

public static class ValidationLayer
{
  public static IReadOnlyList<PimValidationLayer> Resolve(
    string profileCode, string? scope, bool blocksErp, bool blocksWeb)
  {
    if (string.Equals(scope, "COMMERCIAL", StringComparison.OrdinalIgnoreCase))
      return [PimValidationLayer.Komerciala];
    if (string.Equals(scope, "WEB", StringComparison.OrdinalIgnoreCase))
      return [PimValidationLayer.Splet];
    if (string.Equals(scope, "ERP", StringComparison.OrdinalIgnoreCase))
      return [profileCode.Contains("EU", StringComparison.OrdinalIgnoreCase)
              || profileCode.Contains("THIRD", StringComparison.OrdinalIgnoreCase)
        ? PimValidationLayer.ErpEuThird
        : PimValidationLayer.ErpSlo];
    if (!string.Equals(scope, "SHARED", StringComparison.OrdinalIgnoreCase)) return [];

    var layers = new List<PimValidationLayer>(3);
    if (blocksErp)
    {
      layers.Add(PimValidationLayer.ErpSlo);
      layers.Add(PimValidationLayer.ErpEuThird);
    }
    if (blocksWeb) layers.Add(PimValidationLayer.Splet);
    return layers;
  }

  public static string Code(PimValidationLayer layer) => layer switch
  {
    PimValidationLayer.ErpSlo => "ERP_SLO",
    PimValidationLayer.ErpEuThird => "ERP_EU_THIRD",
    PimValidationLayer.Komerciala => "KOMERCIALA",
    PimValidationLayer.Splet => "SPLET",
    _ => layer.ToString().ToUpperInvariant(),
  };

  public static string Label(PimValidationLayer layer) => layer switch
  {
    PimValidationLayer.ErpSlo => "ERP_SLO",
    PimValidationLayer.ErpEuThird => "ERP_EU/THIRD",
    PimValidationLayer.Komerciala => "KOMERCIALA",
    PimValidationLayer.Splet => "SPLET",
    _ => layer.ToString(),
  };

  public static bool IsShared(string? scope) =>
    string.Equals(scope, "SHARED", StringComparison.OrdinalIgnoreCase);
}
