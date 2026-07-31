using System.Security.Cryptography;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;

namespace PIM.Outbound;

public sealed record OutboundChange(
  string TargetKind,
  string HttpOperation,
  string EntityType,
  string EntityKey,
  string FieldName,
  string Value,
  string? Qualifier = null);

public sealed record OutboundPayload(string CanonicalJson, string PayloadHash, string DedupKey);

public sealed class OutboundPayloadBuilder(OwnershipPolicy policy)
{
  public OutboundPayload Build(OutboundChange change)
  {
    if (change.HttpOperation is not ("POST" or "PATCH"))
      throw new OwnershipViolationException("Dovoljeni sta samo operaciji POST in PATCH.");
    policy.DemandPimOwnership(change.EntityType, change.FieldName, change.Value, change.Qualifier);
    using var stream = new MemoryStream();
    using (var writer = new Utf8JsonWriter(stream, new JsonWriterOptions { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping }))
    {
      writer.WriteStartObject();
      writer.WriteString("entityKey", change.EntityKey);
      writer.WriteString("field", change.FieldName);
      writer.WriteString("value", change.Value);
      writer.WriteEndObject();
    }
    var canonical = Encoding.UTF8.GetString(stream.ToArray());
    var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(canonical))).ToLowerInvariant();
    return new(canonical, hash, hash);
  }
}
