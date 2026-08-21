using PIM.Outbound;

var sent = new SentEchoExpectation("abc", new DateTime(2026, 7, 31, 12, 0, 0, DateTimeKind.Utc));
Equal(EchoDecision.Missing, EchoVerifier.Decide(sent, null), "Manjkajoč echo ostane Sent");
Equal(EchoDecision.Stale, EchoVerifier.Decide(sent, new("abc", sent.SentUtc.AddSeconds(-1))), "Starejši echo se prezre");
Equal(EchoDecision.Verified, EchoVerifier.Decide(sent, new("abc", sent.SentUtc)), "Ujemanje potrdi");
Equal(EchoDecision.Drift, EchoVerifier.Decide(sent, new("def", sent.SentUtc.AddSeconds(1))), "Neujemanje je drift brez resenda");
Equal(false, EchoVerifier.ShouldAutomaticallyResend(EchoDecision.Drift), "Drift se ne pošlje samodejno");
Equal(false, EchoAntiLoop.ShouldEnqueue("abc", "abc"), "Točno potrjeni hash prepreči zanko");
Equal(true, EchoAntiLoop.ShouldEnqueue("def", "abc"), "Poznejša uporabniška/SAOP divergenca je nova sprememba");

// --- Vrzel O16: nadomeščeno sporočilo ni razhajanje ---------------------------------
//
// Zaporedje "pošlji A → urednik popravi na B → pošlji B → SAOP potrdi B". Brez pojma
// Superseded je A videti kot poslano, a nepotrjeno — kar je laž: SAOP je potrdil tisto,
// kar je bilo poslano nazadnje. Alarm o tem je lažen in ubija zaupanje v prave alarme.
var superseded = sent with { SupersededBySentUtc = sent.SentUtc.AddMinutes(5) };
Equal(EchoDecision.Superseded, EchoVerifier.Decide(superseded, new("def", sent.SentUtc.AddSeconds(1))),
  "Neujemanje ob novejšem pošiljanju je nadomestitev, ne razhajanje");
Equal(EchoDecision.Verified, EchoVerifier.Decide(superseded, new("abc", sent.SentUtc.AddSeconds(1))),
  "Echo, ki se ujema s tem sporočilom, ga potrdi tudi ob novejšem pošiljanju");
Equal(EchoDecision.Drift, EchoVerifier.Decide(sent with { SupersededBySentUtc = sent.SentUtc.AddMinutes(-5) }, new("def", sent.SentUtc.AddSeconds(1))),
  "Starejše pošiljanje ne nadomesti novejšega");
Equal(EchoDecision.Missing, EchoVerifier.Decide(superseded, null), "Brez echa ni o čem odločati");

// --- Vrzel O19: uskladitev nove šifre --------------------------------------------
//
// Vrstni red je odgovor SAOP → zahtevana šifra → EAN → človek. Doslej je bil samo EAN.
Equal(SaopItemMatchMethod.Response,
  SaopItemAssignmentResolver.Resolve(new("SAOP-77", "REQ-1", "3830000000001", 1, "REQ-1")).Method,
  "Odgovor SAOP prevlada nad vsem");
Equal("SAOP-77",
  SaopItemAssignmentResolver.Resolve(new("SAOP-77", "REQ-1", "3830000000001", 1, "REQ-1")).AssignedSaopItemId,
  "Uporabi se šifra iz odgovora");
Equal(SaopItemMatchMethod.RequestedIdentifier,
  SaopItemAssignmentResolver.Resolve(new(null, "REQ-1", "3830000000001", 1, "DRUG-1")).Method,
  "Brez odgovora obvelja zahtevana šifra, ne EAN");
Equal(SaopItemMatchMethod.Ean,
  SaopItemAssignmentResolver.Resolve(new(null, null, "3830000000001", 1, "EAN-1")).Method,
  "EAN velja, kadar je enoličen");
Equal(SaopItemMatchMethod.Unresolved,
  SaopItemAssignmentResolver.Resolve(new(null, null, "3830000000001", 2, null)).Method,
  "Dvoumen EAN ni ujemanje — napačna povezava je slabša od nobene");
Equal(null,
  SaopItemAssignmentResolver.Resolve(new(null, null, "3830000000001", 2, null)).AssignedSaopItemId,
  "Dvoumen EAN ne sme dodeliti šifre");
Equal(SaopItemMatchMethod.Unresolved,
  SaopItemAssignmentResolver.Resolve(new(null, null, null, 0, null)).Method,
  "Brez vsega ostane človek");
Equal(SaopItemMatchMethod.RequestedIdentifier,
  SaopItemAssignmentResolver.Resolve(new("   ", "REQ-1", null, 0, null)).Method,
  "Prazen odgovor ni odgovor");

Console.WriteLine("F8 echo: verified, stale, missing, drift, superseded, anti-loop in uskladitev šifre PASS.");

static void Equal<T>(T expected, T actual, string message)
{
  if (!EqualityComparer<T>.Default.Equals(expected, actual)) throw new InvalidOperationException(message);
}
