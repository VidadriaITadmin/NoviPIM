using System.Security.Cryptography;
using System.Text.Json;

namespace PIM.B2bWorker;

public sealed record B2bFixture(string EntityType, string PayloadHash, IReadOnlyList<string> Records);

public static class B2bFixtureSource
{
  public static async Task<B2bFixture> ReadAsync(string path, CancellationToken cancellationToken = default)
  {
    await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 4096, FileOptions.Asynchronous | FileOptions.SequentialScan);
    using var buffer = new MemoryStream();
    await stream.CopyToAsync(buffer, cancellationToken);
    var bytes = buffer.ToArray();
    using var document = JsonDocument.Parse(bytes);
    var entityType = document.RootElement.GetProperty("entityType").GetString() ?? throw new InvalidDataException("Manjka entityType.");
    if (string.IsNullOrWhiteSpace(entityType)) throw new InvalidDataException("Prazen entityType ni dovoljen.");
    var records = document.RootElement.GetProperty("records").EnumerateArray().Select(record => record.GetRawText()).ToArray();
    return new(entityType, Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant(), records);
  }
}
