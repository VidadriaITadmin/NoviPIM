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

/// <summary>
/// Kako se pri viru najde posamezen atribut. Vsak dobavitelj nosi atribute drugace, zato je to
/// vrstica registra (<c>map.SourceAttributeDiscovery</c>) in ne pogoj v programu.
/// </summary>
/// <param name="NameXPath">Prazno pomeni: ime atributa je ime elementa.</param>
public sealed record AttributeDiscovery(
  string NodeXPath,
  string? NameXPath,
  string? LabelXPath,
  string? ValueXPath,
  string? UnitXPath);

/// <param name="ProductCount">Pri koliko zapisih se je ta atribut pojavil, ne kolikokrat skupaj.</param>
public sealed record DiscoveredAttribute(
  string Name,
  string? Label,
  string? Value,
  string? Unit,
  int ProductCount);

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

  /// <summary>
  /// Prebere <b>vse</b> atribute zapisa, tudi tiste brez preslikave.
  ///
  /// Zakaj obstaja: <see cref="Extract"/> prebere natanko tisto, kar je v <c>map.FieldMapping</c>,
  /// zato nepreslikan atribut ni napaka in ni opozorilo - preprosto ga ni. Braytronova datoteka
  /// je imela sest takih in tega ne bi javil nihce.
  /// </summary>
  public IReadOnlyList<DiscoveredAttribute> Discover(
    string payloadXml,
    string recordXPath,
    AttributeDiscovery discovery)
  {
    using var reader = XmlReader.Create(
      new StringReader(payloadXml),
      new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit });
    var document = new XPathDocument(reader);
    var records = document.CreateNavigator().Select(recordXPath);

    var nodes = XPathExpression.Compile(discovery.NodeXPath);
    var name = Compile(discovery.NameXPath);
    var label = Compile(discovery.LabelXPath);
    var value = Compile(discovery.ValueXPath);
    var unit = Compile(discovery.UnitXPath);

    var found = new Dictionary<string, Accumulator>(StringComparer.Ordinal);

    while (records.MoveNext())
    {
      // Isti atribut se v enem zapisu lahko pojavi veckrat; register steje izdelke, ne pojavitev,
      // sicer bi bila pogostost odvisna od oblike zapisa in ne od tega, koliko izdelkov ga ima.
      var seenInRecord = new HashSet<string>(StringComparer.Ordinal);
      // Klon je previdnost, ne popravek: XPathNodeIterator.Current vrne navigator, ki ga iterator
      // sam premika, in vgnezden izbor nad njim je vzorec, ki se drugod res zlomi. Tu ne -
      // preverjeno s PIM.F5.AttributeDiscoveryTests, ki je zelen tudi brez klona. Ostaja, ker
      // ne stane nic in ker je namen vrstice tako viden.
      var attributes = records.Current!.Clone().Select(nodes);
      while (attributes.MoveNext())
      {
        var node = attributes.Current!;
        var key = name is null
          ? node.LocalName
          : node.SelectSingleNode(name)?.Value?.Trim() ?? string.Empty;
        if (string.IsNullOrWhiteSpace(key)) continue;

        if (!found.TryGetValue(key, out var accumulator))
        {
          accumulator = new Accumulator();
          found[key] = accumulator;
        }
        if (seenInRecord.Add(key)) accumulator.ProductCount++;

        // Vzorec je prvi neprazen, ne zadnji: prvi je iz zapisa, ki ga clovek najlazje najde.
        accumulator.Label ??= Text(node, label);
        accumulator.Value ??= Text(node, value);
        accumulator.Unit ??= Text(node, unit);
      }
    }

    return found
      .Select(pair => new DiscoveredAttribute(
        pair.Key, pair.Value.Label, pair.Value.Value, pair.Value.Unit, pair.Value.ProductCount))
      .OrderByDescending(attribute => attribute.ProductCount)
      .ToList();
  }

  static XPathExpression? Compile(string? xpath) =>
    string.IsNullOrWhiteSpace(xpath) ? null : XPathExpression.Compile(xpath);

  static string? Text(XPathNavigator node, XPathExpression? expression)
  {
    if (expression is null) return null;
    var text = node.SelectSingleNode(expression)?.Value?.Trim();
    return string.IsNullOrEmpty(text) ? null : text;
  }

  sealed class Accumulator
  {
    public string? Label;
    public string? Value;
    public string? Unit;
    public int ProductCount;
  }
}
