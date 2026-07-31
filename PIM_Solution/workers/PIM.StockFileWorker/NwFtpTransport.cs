using System.Security.Cryptography;
using PIM.StockMapping;

namespace PIM.StockFileWorker;

public sealed record StockFixtureBatch(byte[] RawPayload, string PayloadHash, IReadOnlyList<ExtractedStockRow> Records);

public sealed class NwFtpTransport
{
  static readonly CsvStockSchema Schema = new(',', false, new Dictionary<string, FieldSelector>
  {
    ["Ean"] = new(SelectorKind.Ordinal, "0"),
    ["SourceItemId"] = new(SelectorKind.Ordinal, "1"),
    ["Quantity"] = new(SelectorKind.Ordinal, "2"),
    ["AvailabilityDate"] = new(SelectorKind.Ordinal, "3"),
    ["IncomingQuantity"] = new(SelectorKind.Ordinal, "4")
  });

  public async Task<StockFixtureBatch> ReadFixtureAsync(string path, CancellationToken cancellationToken = default)
  {
    var bytes = await File.ReadAllBytesAsync(path, cancellationToken);
    var text = System.Text.Encoding.UTF8.GetString(bytes);
    return new(bytes, Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant(), new StockMappingExtractor().ExtractCsv(text, Schema));
  }
}
