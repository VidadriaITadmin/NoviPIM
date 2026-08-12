using System.Globalization;
using System.Text;

namespace PIM.StockMapping;

public sealed record StockExportRow(string ProductKey, string? Ean, decimal Quantity, DateOnly? AvailabilityDate, decimal? IncomingQuantity, string Source, string? Provider, DateTime SnapshotUtc);

public static class StockCsvGenerator
{
  public static async Task WriteAsync(string path, IEnumerable<StockExportRow> rows, CancellationToken cancellationToken = default)
  {
    await using var writer = new StreamWriter(path, false, new UTF8Encoding(false))
    {
      NewLine = "\n"
    };
    await writer.WriteLineAsync("ProductKey,EAN,Quantity,AvailabilityDate,IncomingQuantity,Source,Provider,SnapshotUtc");
    foreach (var row in rows)
    {
      var values = new[]
      {
        row.ProductKey, row.Ean,
        row.Quantity.ToString(CultureInfo.InvariantCulture),
        row.AvailabilityDate?.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
        row.IncomingQuantity?.ToString(CultureInfo.InvariantCulture),
        row.Source, row.Provider, row.SnapshotUtc.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture)
      };
      await writer.WriteLineAsync(string.Join(",", values.Select(Escape)));
      cancellationToken.ThrowIfCancellationRequested();
    }
  }

  static string Escape(string? value)
  {
    value ??= "";
    return value.IndexOfAny([',','"','\r','\n']) < 0 ? value : $"\"{value.Replace("\"", "\"\"", StringComparison.Ordinal)}\"";
  }
}
