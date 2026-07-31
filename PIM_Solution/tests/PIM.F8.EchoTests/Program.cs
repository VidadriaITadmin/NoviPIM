using PIM.Outbound;

var sent = new SentEchoExpectation("abc", new DateTime(2026, 7, 31, 12, 0, 0, DateTimeKind.Utc));
Equal(EchoDecision.Missing, EchoVerifier.Decide(sent, null), "Manjkajoč echo ostane Sent");
Equal(EchoDecision.Stale, EchoVerifier.Decide(sent, new("abc", sent.SentUtc.AddSeconds(-1))), "Starejši echo se prezre");
Equal(EchoDecision.Verified, EchoVerifier.Decide(sent, new("abc", sent.SentUtc)), "Ujemanje potrdi");
Equal(EchoDecision.Drift, EchoVerifier.Decide(sent, new("def", sent.SentUtc.AddSeconds(1))), "Neujemanje je drift brez resenda");
Equal(false, EchoVerifier.ShouldAutomaticallyResend(EchoDecision.Drift), "Drift se ne pošlje samodejno");
Equal(false, EchoAntiLoop.ShouldEnqueue("abc", "abc"), "Točno potrjeni hash prepreči zanko");
Equal(true, EchoAntiLoop.ShouldEnqueue("def", "abc"), "Poznejša uporabniška/SAOP divergenca je nova sprememba");
Console.WriteLine("F8 echo: verified, stale, missing, drift in anti-loop PASS.");

static void Equal<T>(T expected, T actual, string message)
{
  if (!EqualityComparer<T>.Default.Equals(expected, actual)) throw new InvalidOperationException(message);
}
