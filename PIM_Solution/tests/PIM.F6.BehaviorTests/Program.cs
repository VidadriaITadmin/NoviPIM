using PIM.StockMapping;

var csvFields = new Dictionary<string, FieldSelector>
{
  ["Ean"] = new(SelectorKind.Ordinal, "0"),
  ["SourceItemId"] = new(SelectorKind.Ordinal, "1"),
  ["Quantity"] = new(SelectorKind.Ordinal, "2"),
  ["AvailabilityDate"] = new(SelectorKind.Ordinal, "3"),
  ["IncomingQuantity"] = new(SelectorKind.Ordinal, "4")
};
var csv = new StockMappingExtractor().ExtractCsv("5900000000000;10168;0;\0;\0\n", new(';', false, csvFields)).Single();
Equal("5900000000000", csv.Values["Ean"], "NW EAN");
Equal("0", csv.Values["Quantity"], "Ničelna količina mora ostati.");
Equal(null, csv.Values["AvailabilityDate"], "NUL opcijska vrednost mora postati NULL.");

var xml = "<Stoklar><Stok><ProductCode>BA09-00510</ProductCode><Quantity>7300</Quantity><ListPrice>1,10</ListPrice></Stok></Stoklar>";
var xmlRows = new StockMappingExtractor().ExtractXml(xml, new("/Stoklar/Stok", new Dictionary<string, FieldSelector>
{
  ["SourceItemId"] = new(SelectorKind.XPath, "ProductCode/text()"),
  ["Quantity"] = new(SelectorKind.XPath, "Quantity/text()")
}));
Equal(1, xmlRows.Count, "BT vrstica");
Equal(2, xmlRows[0].Values.Count, "Cena ne sme postati stock polje.");

var normalizer = new StockNormalizer();
var nw = normalizer.Normalize(csv, new("SourceItemId", "NW.", null, null, "ItemID"), "yyyy-MM-dd");
Equal("NW.10168", nw.Position?.NormalizedItemId, "NW identiteta");
Equal(0m, nw.Position?.Quantity, "Ničelna količina");
var bt = normalizer.Normalize(xmlRows[0], new("SourceItemId", "BA.", "-", ".", "ItemID"), "yyyy-MM-dd");
Equal("BA.BA09.00510", bt.Position?.NormalizedItemId, "BT identiteta");
Equal("ItemID", bt.Position?.PreferredMatchKey, "ItemID mora imeti prednost.");

Equal("InvalidQuantity", normalizer.Normalize(Row(("SourceItemId","x"),("Quantity","abc")), new("SourceItemId","","","","ItemID"), "yyyy-MM-dd").Quarantine?.ReasonCode, "Neveljavna količina");
Equal("NegativeQuantity", normalizer.Normalize(Row(("SourceItemId","x"),("Quantity","-1")), new("SourceItemId","","","","ItemID"), "yyyy-MM-dd").Quarantine?.ReasonCode, "Negativna količina");
Equal("MissingIdentity", normalizer.Normalize(Row(("Quantity","1")), new("SourceItemId","","","","ItemID"), "yyyy-MM-dd").Quarantine?.ReasonCode, "Manjkajoča identiteta");
Equal("InvalidDate", normalizer.Normalize(Row(("SourceItemId","x"),("Quantity","1"),("AvailabilityDate","31/99")), new("SourceItemId","","","","ItemID"), "yyyy-MM-dd").Quarantine?.ReasonCode, "Neveljaven datum");

var third = normalizer.Normalize(Row(("sku","C-7"),("amount","4")), new("sku","THIRD-","-","/","ItemID"), "yyyy-MM-dd", new() { QuantityField="amount" });
Equal("THIRD-C/7", third.Position?.NormalizedItemId, "Tretji vir deluje le s konfiguracijo.");
Console.WriteLine("F6 behavior: generična normalizacija CSV/XML in karantena PASS.");

static ExtractedStockRow Row(params (string Key,string? Value)[] values) => new(1, values.ToDictionary(x=>x.Key,x=>x.Value));
static void Equal<T>(T expected,T actual,string message)
{
  if (!EqualityComparer<T>.Default.Equals(expected,actual)) throw new InvalidOperationException($"{message}: pričakovano {expected}, dejansko {actual}.");
}
