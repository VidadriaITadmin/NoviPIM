using System.Net;
using PIM.AlertDispatcher;

var disabledClient = new WebhookAlertSender(new HttpClient(), new(false, null));
var disabled = await disabledClient.SendAsync(new(1, "Kritično opozorilo", "Povzetek brez skrivnosti"));
Assert(disabled == AlertSendOutcome.Disabled, "privzeta dostava ni izključena");

var port = Random.Shared.Next(20000, 40000);
var prefix = $"http://127.0.0.1:{port}/";
using var fixture = new HttpListener();
fixture.Prefixes.Add(prefix);
fixture.Start();
var received = fixture.GetContextAsync();
var sender = new WebhookAlertSender(new HttpClient(), new(true, new Uri(prefix)));
var sendTask = sender.SendAsync(new(2, "Opozorilo", "Lokalni fixture"));
var context = await received.WaitAsync(TimeSpan.FromSeconds(5));
using var bodyReader = new StreamReader(context.Request.InputStream);
var body = await bodyReader.ReadToEndAsync();
context.Response.StatusCode = 204;
context.Response.Close();
var outcome = await sendTask;
Assert(outcome == AlertSendOutcome.Delivered, "fixture webhook ni dostavljen");
Assert(body.Contains("Lokalni fixture", StringComparison.Ordinal), "fixture ni prejel redigiranega povzetka");
Console.WriteLine("F9 alerts: disabled-default in lokalni webhook fixture PASS.");

static void Assert(bool condition, string message)
{
  if (!condition) throw new InvalidOperationException(message);
}
