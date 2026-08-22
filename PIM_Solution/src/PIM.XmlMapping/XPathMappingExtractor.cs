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

    // Pot prevedemo enkrat na preslikavo, ne enkrat na zapis. SelectSingleNode(string) vsakic
    // znova prevede izraz; pri dobaviteljevi datoteki s 2.619 izdelki in 112 preslikavami je to
    // 293.000 prevodov istih 112 izrazov. Prevedeni izraz je isti objekt in se uporablja zaporedno.
    var compiled = new XPathExpression[mappings.Count];
    for (var index = 0; index < mappings.Count; index++)
    {
      compiled[index] = XPathExpression.Compile(mappings[index].FieldXPath);
    }

    while (records.MoveNext())
    {
      ordinal++;
      var record = records.Current!;
      for (var index = 0; index < mappings.Count; index++)
      {
        var mapping = mappings[index];
        var value = record.SelectSingleNode(compiled[index])?.Value;
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
