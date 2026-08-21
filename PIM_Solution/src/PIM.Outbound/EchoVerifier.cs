namespace PIM.Outbound;

public enum EchoDecision { Missing, Stale, Verified, Drift, Superseded }

/// <param name="ExpectedHash">Kanonični hash tega, kar je bilo poslano — ne trenutnega stanja PIM.</param>
/// <param name="SentUtc">Kdaj je bilo poslano.</param>
/// <param name="SupersededBySentUtc">
/// Kdaj je bilo poslano novejše sporočilo za isto polje istega izdelka, če obstaja.
/// </param>
public sealed record SentEchoExpectation(string ExpectedHash, DateTime SentUtc, DateTime? SupersededBySentUtc = null);
public sealed record InboundEcho(string CanonicalHash, DateTime ObservedUtc);

public static class EchoVerifier
{
  /// <summary>
  /// Odloči, kaj pomeni prejeti echo za poslano sporočilo.
  ///
  /// Vrzel O16: brez pojma <see cref="EchoDecision.Superseded"/> je zaporedje
  /// »pošlji A → urednik popravi na B → pošlji B → SAOP potrdi B« pustilo A brez odgovora,
  /// ki bi mu ustrezal. Neujemanje je zato razhajanje samo takrat, kadar za isto polje ni
  /// bilo poslano nič novejšega; sicer je A preprosto nadomeščen.
  ///
  /// Vrstni red je pomemben: ujemanje po hashu prevlada nad nadomestitvijo, ker echo, ki se
  /// ujema s tem sporočilom, potrjuje prav to sporočilo — tudi če je medtem že šlo novejše.
  /// Tako se ta odločitev ujema z <c>out.VerifyEcho</c>, ki prav tako najprej išče po hashu.
  /// </summary>
  public static EchoDecision Decide(SentEchoExpectation sent, InboundEcho? inbound)
  {
    if (inbound is null) return EchoDecision.Missing;
    if (inbound.ObservedUtc < sent.SentUtc) return EchoDecision.Stale;
    if (string.Equals(inbound.CanonicalHash, sent.ExpectedHash, StringComparison.OrdinalIgnoreCase))
      return EchoDecision.Verified;
    if (sent.SupersededBySentUtc is { } newerSentUtc && newerSentUtc > sent.SentUtc)
      return EchoDecision.Superseded;
    return EchoDecision.Drift;
  }

  public static bool ShouldAutomaticallyResend(EchoDecision decision) => false;
}
