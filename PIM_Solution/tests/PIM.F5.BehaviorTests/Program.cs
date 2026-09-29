using PIM.XmlMapping;

var extractor = new XPathMappingExtractor();
var mappings = new[]
{
  new FieldMapping(11, 3, "sku/text()", "Product.ItemID", true),
  new FieldMapping(12, 3, "details/ean/text()", "Product.EAN", false),
  new FieldMapping(13, 3, "details/tags/tag/text()", "Future.Tags", false)
};
var xml = """
  <feed>
    <row><sku>A-1</sku><details><ean>3830001</ean><tags><tag>first</tag><tag>second</tag></tags></details></row>
    <row><sku>A-2</sku><details><ean>3830002</ean></details></row>
  </feed>
  """;

var values = extractor.Extract(xml, "/feed/row", mappings);
Equal(6, values.Count, "Extractor mora ohraniti tudi manjkajočo vrednost.");
Equal(new ExtractedValue(1, 11, 3, "Product.ItemID", "A-1"), values[0], "Prva sled ni pravilna.");
Equal("first", values.Single(value => value.RecordOrdinal == 1 && value.FieldMappingId == 13).Value, "XPath uporablja prvo ujemanje.");
Equal(null, values.Single(value => value.RecordOrdinal == 2 && value.FieldMappingId == 13).Value, "Manjkajoča vrednost ni NULL.");

// Večvrednostna preslikava (slike NW): vsi zadetki v zaporedju, prazni izpuščeni; brez zadetka ena NULL vrstica.
var mediaXml = """
  <feed>
    <row><media><image_i><image_i_path>//a/1.jpg</image_i_path></image_i><file><file_path>//a/1.pdf</file_path></file>
      <image_ii><image_ii_path></image_ii_path></image_ii><image_iii><image_iii_path>//a/3.jpg</image_iii_path></image_iii></media></row>
    <row><media /></row>
  </feed>
  """;
var mediaMapping = new[] { new FieldMapping(21, 1, "media/*[starts-with(local-name(),'image_')]/*[substring(local-name(),string-length(local-name())-4)='_path']/text()",
  "ProductMedia.Url", false, IsMultiValue: true) };
var media = extractor.Extract(mediaXml, "/feed/row", mediaMapping);
Equal("//a/1.jpg|1;//a/3.jpg|2", string.Join(";", media.Where(v => v.RecordOrdinal == 1).Select(v => $"{v.Value}|{v.ValueOrdinal}")),
  "Večvrednostna preslikava vrne vse slike v zaporedju.");
Equal(1, media.Count(v => v.RecordOrdinal == 2 && v.Value is null && v.ValueOrdinal == 1), "Zapis brez slik ima eno NULL vrstico.");
Equal(1, extractor.Extract(mediaXml, "/feed/row", [mediaMapping[0] with { IsMultiValue = false }]).Count(v => v.RecordOrdinal == 1),
  "Enovrednostna preslikava ostane pri prvem zadetku.");

var futureMappings = new[] { new FieldMapping(91, 8, "@code", "Product.ItemID", true) };
var futureValues = extractor.Extract("<catalog><entry code=\"BT-1\" /></catalog>", "/catalog/entry", futureMappings);
Equal("BT-1", futureValues.Single().Value, "Nov vir mora delovati samo s konfiguracijo.");

Console.WriteLine("F5 behavior: generična XPath ekstrakcija in config-only prihodnji vir PASS.");
return 0;

static void Equal<T>(T expected, T actual, string message)
{
  if (!EqualityComparer<T>.Default.Equals(expected, actual))
  {
    throw new InvalidOperationException($"{message} Pričakovano: {expected}; dejansko: {actual}.");
  }
}
