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
}
public sealed record NormalizedStockPosition(string? NormalizedItemId, string? Ean, decimal Quantity, DateOnly? AvailabilityDate, decimal? IncomingQuantity, string PreferredMatchKey);
public sealed record StockQuarantine(string ReasonCode, string Detail);
public sealed record StockNormalizationResult(NormalizedStockPosition? Position, StockQuarantine? Quarantine);
