using System.Xml;

namespace PIM.StockMapping;

public sealed class StockMappingExtractor
{
  public IReadOnlyList<ExtractedStockRow> ExtractCsv(string payload, CsvStockSchema schema)
  {
    var lines = payload.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n');
    var start = schema.HasHeader ? 1 : 0;
    var result = new List<ExtractedStockRow>();
    for (var lineIndex = start; lineIndex < lines.Length; lineIndex++)
    {
      if (lines[lineIndex].Length == 0) continue;
      var columns = lines[lineIndex].Split(schema.Delimiter);
      var values = schema.Fields.ToDictionary(
        field => field.Key,
        field =>
        {
          if (field.Value.Kind != SelectorKind.Ordinal || !int.TryParse(field.Value.Selector, out var ordinal) || ordinal >= columns.Length) return null;
          return Clean(columns[ordinal]);
        });
      result.Add(new(lineIndex - start + 1, values));
    }
    return result;
  }

  public IReadOnlyList<ExtractedStockRow> ExtractXml(string payload, XmlStockSchema schema)
  {
    var document = new XmlDocument { XmlResolver = null };
    document.LoadXml(payload);
    var nodes = document.SelectNodes(schema.RecordXPath) ?? throw new InvalidOperationException("Record XPath ni veljaven.");
    var rows = new List<ExtractedStockRow>(nodes.Count);
    for (var index = 0; index < nodes.Count; index++)
    {
      var node = nodes[index]!;
      var values = schema.Fields.ToDictionary(field => field.Key,
        field => field.Value.Kind == SelectorKind.XPath ? Clean(node.SelectSingleNode(field.Value.Selector)?.Value) : null);
      rows.Add(new(index + 1, values));
    }
    return rows;
  }

  static string? Clean(string? value)
  {
    var cleaned = value?.Replace("\0", "", StringComparison.Ordinal).Trim();
    return string.IsNullOrEmpty(cleaned) ? null : cleaned;
  }
}

public sealed class StockNormalizer
{
  public StockNormalizationResult Normalize(ExtractedStockRow row, StockIdentityRule rule, string dateFormat, StockFieldContract? fields = null)
  {
    fields ??= new();
    row.Values.TryGetValue(rule.SourceKeyField, out var sourceKey);
    row.Values.TryGetValue(fields.EanField, out var ean);
    if (string.IsNullOrWhiteSpace(sourceKey) && string.IsNullOrWhiteSpace(ean)) return Reject("MissingIdentity");
    if (!row.Values.TryGetValue(fields.QuantityField, out var quantityText)
      || !decimal.TryParse(quantityText, System.Globalization.NumberStyles.Number, System.Globalization.CultureInfo.InvariantCulture, out var quantity)) return Reject("InvalidQuantity");
    if (quantity < 0) return Reject("NegativeQuantity");
    DateOnly? date = null;
    if (row.Values.TryGetValue(fields.AvailabilityDateField, out var dateText) && !string.IsNullOrWhiteSpace(dateText))
    {
      if (!DateOnly.TryParseExact(dateText, dateFormat, System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.None, out var parsed)) return Reject("InvalidDate");
      date = parsed;
    }
    decimal? incoming = null;
    if (row.Values.TryGetValue(fields.IncomingQuantityField, out var incomingText) && !string.IsNullOrWhiteSpace(incomingText))
    {
      if (!decimal.TryParse(incomingText, System.Globalization.NumberStyles.Number, System.Globalization.CultureInfo.InvariantCulture, out var parsed) || parsed < 0) return Reject("InvalidIncomingQuantity");
      incoming = parsed;
    }
    var normalized = sourceKey is null ? null : rule.Prefix + (string.IsNullOrEmpty(rule.ReplaceOld) ? sourceKey : sourceKey.Replace(rule.ReplaceOld, rule.ReplaceNew ?? "", StringComparison.Ordinal));
    return new(new(normalized, ean, quantity, date, incoming, rule.PreferredMatchKey), null);
  }

  static StockNormalizationResult Reject(string reason) => new(null, new(reason, "Zapis ni prestal generične normalizacije."));
}
