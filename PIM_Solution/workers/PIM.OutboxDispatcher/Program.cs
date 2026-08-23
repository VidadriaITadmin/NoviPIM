using System.Globalization;
using PIM.OutboxDispatcher;

// Odhodna pot v SAOP.
//
// Brez argumentov teče stara, splošna pot po enem sporočilu (obstoječi F8 testi jo pokrivajo).
// Z --saop-documents teče pot na ravni dokumenta: čakajoče spremembe enega zapisa se združijo
// v en dokument za SAOP.
//
// POŠILJANJE JE ZAPRTO. Privzeto je suhi tek: dokumenti se sestavijo in zapišejo v datoteke,
// nič ne odide in v bazi se nič ne spremeni. Za pravo pošiljanje sta potrebna OBA pogoja —
// zastavica --send IN nastavljene poverilnice v okolju. Navodila so v
// docs\ODHODNA_POT_SAOP.md.

var arguments = args.ToList();

if (!arguments.Contains("--saop-documents"))
  return await RunLegacyAsync();

var connectionString = Environment.GetEnvironmentVariable("PIM_CONNECTION_STRING");
if (string.IsNullOrWhiteSpace(connectionString))
{
  Console.Error.WriteLine("PIM_CONNECTION_STRING ni nastavljen.");
  return 2;
}

var send = arguments.Contains("--send");
var targetKind = Value("--target") ?? "SAOP_PRODUCT";
var organizationId = Value("--org") is { } org ? int.Parse(org, CultureInfo.InvariantCulture) : (int?)null;
var maxDocuments = Value("--max") is { } max ? int.Parse(max, CultureInfo.InvariantCulture) : 100;
var outputDirectory = Value("--out") ?? (send ? null : Path.Combine(Directory.GetCurrentDirectory(), "saop-dokumenti"));

var options = new SaopDocumentRunOptions(targetKind, DryRun: !send, outputDirectory, maxDocuments, organizationId);
SaopDocumentSender? sender = null;

if (send)
{
  // Dve neodvisni varovalki. Zastavica sama ne zadošča: brez poverilnic se ne pošlje nič in
  // se to jasno pove, namesto da bi vsaka zahteva vrnila 401 in porabila poskus.
  var baseUrl = Environment.GetEnvironmentVariable("SAOP_BASE_URL");
  var username = Environment.GetEnvironmentVariable("SAOP_USERNAME");
  var password = Environment.GetEnvironmentVariable("SAOP_PASSWORD");
  if (string.IsNullOrWhiteSpace(baseUrl) || string.IsNullOrWhiteSpace(username) || string.IsNullOrWhiteSpace(password))
  {
    Console.Error.WriteLine("Za --send morajo biti nastavljeni SAOP_BASE_URL, SAOP_USERNAME in SAOP_PASSWORD.");
    Console.Error.WriteLine("Brez njih ni bilo poslano nič. Navodila: docs\\ODHODNA_POT_SAOP.md");
    return 2;
  }

  sender = new SaopDocumentSender(new(baseUrl!, username!, password!,
    TimeoutSeconds: 120,
    AcceptUntrustedCertificate: string.Equals(Environment.GetEnvironmentVariable("SAOP_ACCEPT_UNTRUSTED_CERT"), "true", StringComparison.OrdinalIgnoreCase)));

  Console.WriteLine($"POZOR: pošiljanje v SAOP je vklopljeno. Naslov: {baseUrl}");
}
else
{
  Console.WriteLine("Suhi tek: nič ne bo poslano in v bazi se nič ne spremeni.");
}

using (sender)
{
  var workerId = $"{Environment.MachineName}:{Environment.ProcessId}";
  var runner = new SaopDocumentRunner(connectionString!, workerId, options, sender);
  var result = await runner.RunAsync();

  foreach (var note in result.Notes) Console.WriteLine("  " + note);
  Console.WriteLine();
  Console.WriteLine($"Dokumentov: {result.Documents}, poslanih: {result.Sent}, neuspešnih: {result.Failed}, nepopolnih: {result.Incomplete}.");
  if (outputDirectory is not null && result.Documents > 0)
    Console.WriteLine($"Dokumenti so zapisani v {outputDirectory}.");
  if (!send) Console.WriteLine("Nič ni bilo poslano — to je bil suhi tek.");

  // Nepopoln dokument v suhem teku ni napaka zagona, je pa razlog, da se ga ne pošlje.
  return result.Failed > 0 ? 1 : 0;
}

string? Value(string name)
{
  var index = arguments.IndexOf(name);
  return index >= 0 && index + 1 < arguments.Count ? arguments[index + 1] : null;
}

// --- stara pot po enem sporočilu ----------------------------------------------------------

async Task<int> RunLegacyAsync()
{
  var legacyConnection = Environment.GetEnvironmentVariable("PIM_CONNECTION_STRING");
  if (string.IsNullOrWhiteSpace(legacyConnection))
  {
    Console.WriteLine("PIM_CONNECTION_STRING ni nastavljen; dispatcher ni izvedel nobenega HTTP klica.");
    return 0;
  }

  var workerId = $"{Environment.MachineName}:{Environment.ProcessId}";
  using var http = new HttpClient();

  var runner = new OutboxDispatchRunner(legacyConnection, workerId, async (message, cancellationToken) =>
  {
    http.Timeout = TimeSpan.FromSeconds(message.TimeoutSeconds);
    return await new SaopOutboundHandler(http).SendAsync(
      new(new Uri(message.EndpointTemplate), message.HttpOperation, message.PayloadJson), cancellationToken);
  });

  var result = await runner.RunAsync();

  if (result.ScheduleMissing)
  {
    Console.Error.WriteLine($"Za pipeline {OutboxDispatchRunner.Pipeline} ni omogocenega razporeda v ops.ScheduleProfile; nobeno sporocilo ni bilo prevzeto.");
    return 1;
  }

  if (result.AlreadyRunning)
  {
    // Prekrivanje nacrtovanega workerja s samim sabo ni napaka; prejsnji zagon se tece.
    Console.WriteLine("Odhodna pot: prejsnji zagon se tece, ta se je umaknil.");
    return 0;
  }

  Console.WriteLine($"Odhodna pot: prevzeto {result.Claimed}, poslano {result.Sent}, neuspesno {result.Failed}.");
  // Meja se izpise, da odrezana vrsta ne izgleda kot prazna.
  if (result.Truncated) Console.WriteLine("Odhodna pot: dosezena meja sporocil na zagon; v vrsti je lahko se kaj.");
  return 0;
}
