using System.Security.Cryptography;
using System.Text;

namespace PIM.Operations;

public sealed record HealthSnapshot(int OrganizationId, string Pipeline, DateTimeOffset? LastHeartbeatUtc, DateTimeOffset? WatermarkUtc, bool Enabled, int StaleAfterSeconds, int DeadCount, int DriftCount);
public sealed record AlertCandidate(string Kind, string Severity, string DedupKey, string RedactedSummary);

public static class WatchdogRules
{
  public static IReadOnlyList<AlertCandidate> Evaluate(HealthSnapshot snapshot, DateTimeOffset now)
  {
    if (!snapshot.Enabled) return Array.Empty<AlertCandidate>();
    var result = new List<AlertCandidate>();
    if (snapshot.LastHeartbeatUtc is { } heartbeat && heartbeat.AddSeconds(snapshot.StaleAfterSeconds) < now)
      result.Add(Create(snapshot, "StaleHeartbeat", "Critical", "Worker nima pravočasnega srčnega utripa."));
    if (snapshot.WatermarkUtc is { } watermark && watermark.AddSeconds(snapshot.StaleAfterSeconds) < now)
      result.Add(Create(snapshot, "StalledWatermark", "Warning", "Vodni žig ni napredoval v dovoljenem času."));
    if (snapshot.DeadCount > 0)
      result.Add(Create(snapshot, "OutboundDead", "Critical", $"Mrtva odhodna sporočila: {snapshot.DeadCount}."));
    if (snapshot.DriftCount > 0)
      result.Add(Create(snapshot, "OutboundDrift", "Critical", $"Odhodna sporočila z odklonom: {snapshot.DriftCount}."));
    return result;
  }

  private static AlertCandidate Create(HealthSnapshot snapshot, string kind, string severity, string summary)
  {
    var bytes = SHA256.HashData(Encoding.UTF8.GetBytes($"{snapshot.OrganizationId}:{snapshot.Pipeline}:{kind}"));
    return new(kind, severity, Convert.ToHexString(bytes), summary);
  }
}
