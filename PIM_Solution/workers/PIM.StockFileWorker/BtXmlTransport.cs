using System.Security.Cryptography;
using PIM.StockMapping;

namespace PIM.StockFileWorker;

public sealed class BtXmlTransport
{
  static readonly XmlStockSchema Schema = new("/Stoklar/Stok", new Dictionary<string, FieldSelector>
  {
    ["SourceItemId"] = new(SelectorKind.XPath, "ProductCode/text()"),
    ["Quantity"] = new(SelectorKind.XPath, "Quantity/text()")
  });

  public async Task<StockFixtureBatch> ReadFixtureAsync(string path, CancellationToken cancellationToken = default)
  {
    var bytes = await File.ReadAllBytesAsync(path, cancellationToken);
    var text = System.Text.Encoding.UTF8.GetString(bytes);
    return new(bytes, Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant(), new StockMappingExtractor().ExtractXml(text, Schema));
  }
}
