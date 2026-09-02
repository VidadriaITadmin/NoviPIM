namespace PIM.StockMapping;

public enum SelectorKind { Ordinal, XPath }
public sealed record FieldSelector(SelectorKind Kind, string Selector);
public sealed record CsvStockSchema(char Delimiter, bool HasHeader, IReadOnlyDictionary<string, FieldSelector> Fields);
public sealed record XmlStockSchema(string RecordXPath, IReadOnlyDictionary<string, FieldSelector> Fields);
public sealed record ExtractedStockRow(int RecordOrdinal, IReadOnlyDictionary<string, string?> Values);
public sealed record StockIdentityRule(string SourceKeyField, string Prefix, string? ReplaceOld, string? ReplaceNew, string PreferredMatchKey);
public sealed record StockFieldContract
{
  public string EanField { get; init; } = "Ean";
  public string QuantityField { get; init; } = "Quantity";
  public string AvailabilityDateField { get; init; } = "AvailabilityDate";
  public string IncomingQuantityField { get; init; } = "IncomingQuantity";
  // Dodatne kolicine registriranega pogleda SAOP (migracija 145). Viri, ki jih ne poznajo
  // (GetStocks, NW, BT), teh kljucev v vrstici nimajo in stolpci ostanejo NULL.
  public string OrderedQuantityField { get; init; } = "OrderedQuantity";
  public string ForShipmentQuantityField { get; init; } = "ForShipmentQuantity";
  public string AvailableQuantityField { get; init; } = "AvailableQuantity";
  public string SupplierOrderedQuantityField { get; init; } = "SupplierOrderedQuantity";
}
public sealed record NormalizedStockPosition(string? NormalizedItemId, string? Ean, decimal Quantity, DateOnly? AvailabilityDate, decimal? IncomingQuantity, string PreferredMatchKey);
public sealed record StockQuarantine(string ReasonCode, string Detail);
public sealed record StockNormalizationResult(NormalizedStockPosition? Position, StockQuarantine? Quarantine);
