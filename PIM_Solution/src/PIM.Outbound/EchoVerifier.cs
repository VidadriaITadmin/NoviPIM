namespace PIM.Outbound;

public enum EchoDecision { Missing, Stale, Verified, Drift }
public sealed record SentEchoExpectation(string ExpectedHash, DateTime SentUtc);
public sealed record InboundEcho(string CanonicalHash, DateTime ObservedUtc);

public static class EchoVerifier
{
  public static EchoDecision Decide(SentEchoExpectation sent, InboundEcho? inbound)
  {
    if (inbound is null) return EchoDecision.Missing;
    if (inbound.ObservedUtc < sent.SentUtc) return EchoDecision.Stale;
    return string.Equals(inbound.CanonicalHash, sent.ExpectedHash, StringComparison.OrdinalIgnoreCase)
      ? EchoDecision.Verified
      : EchoDecision.Drift;
  }

  public static bool ShouldAutomaticallyResend(EchoDecision decision) => false;
}
