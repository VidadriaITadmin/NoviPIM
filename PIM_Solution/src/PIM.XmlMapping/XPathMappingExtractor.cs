using System.Xml;
using System.Xml.XPath;

namespace PIM.XmlMapping;

public sealed record FieldMapping(
  int FieldMappingId,
  int MappingVersion,
  string FieldXPath,
  string TargetFieldCode,
  bool IsRequired);

public sealed record ExtractedValue(
  int RecordOrdinal,
  int FieldMappingId,
  int MappingVersion,
  string TargetFieldCode,
  string? Value);

public sealed class XPathMappingExtractor
{
  public IReadOnlyList<ExtractedValue> Extract(
    string payloadXml,
    string recordXPath,
    IReadOnlyList<FieldMapping> mappings)
  {
    using var reader = XmlReader.Create(
      new StringReader(payloadXml),
      new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit });
    var document = new XPathDocument(reader);
    var records = document.CreateNavigator().Select(recordXPath);
    var result = new List<ExtractedValue>();
    var ordinal = 0;

    while (records.MoveNext())
    {
      ordinal++;
      var record = records.Current!;
      foreach (var mapping in mappings)
      {
        var value = record.SelectSingleNode(mapping.FieldXPath)?.Value;
        result.Add(new ExtractedValue(
          ordinal,
          mapping.FieldMappingId,
          mapping.MappingVersion,
          mapping.TargetFieldCode,
          string.IsNullOrEmpty(value) ? null : value));
      }
    }

    return result;
  }
}
