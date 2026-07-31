using PIM.Operations;

var now = new DateTimeOffset(2026, 7, 31, 14, 0, 0, TimeSpan.Zero);
var stale = WatchdogRules.Evaluate(new(7, "Katalog", now.AddMinutes(-11), now.AddMinutes(-11), true, 600, 0, 0), now);
Assert(stale.Select(x => x.Kind).SequenceEqual(new[] { "StaleHeartbeat", "StalledWatermark" }), "stale in watermark alarma nista ločena");
var outbound = WatchdogRules.Evaluate(new(7, "Outbound", now, now, true, 600, 2, 3), now);
Assert(outbound.Select(x => x.Kind).SequenceEqual(new[] { "OutboundDead", "OutboundDrift" }), "Dead in Drift alarma nista ločena");
Assert(outbound.Select(x => x.DedupKey).Distinct().Count() == 2, "dedup ključa nista različna");
Assert(WatchdogRules.Evaluate(new(7, "Katalog", now, now, true, 600, 0, 0), now).Count == 0, "zdrav heartbeat ustvarja alarm");
Console.WriteLine("F9 behavior: watchdog pravila in deduplikacija PASS.");

static void Assert(bool condition, string message)
{
  if (!condition) throw new InvalidOperationException(message);
}
