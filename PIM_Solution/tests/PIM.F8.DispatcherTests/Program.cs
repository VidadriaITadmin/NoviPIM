using System.Net;
using PIM.OutboxDispatcher;

var port = GetPort();
using var fixture = new HttpListener();
fixture.Prefixes.Add($"http://127.0.0.1:{port}/");
fixture.Start();
var received = new TaskCompletionSource<(string Method, string Body)>();
var server = Task.Run(async () =>
{
  var context = await fixture.GetContextAsync();
  using var reader = new StreamReader(context.Request.InputStream);
  received.SetResult((context.Request.HttpMethod, await reader.ReadToEndAsync()));
  context.Response.StatusCode = 202;
  context.Response.Headers["X-Correlation-ID"] = "fixture-42";
  var response = System.Text.Encoding.UTF8.GetBytes("{\"token\":\"secret-value\",\"accepted\":true}");
  await context.Response.OutputStream.WriteAsync(response);
  context.Response.Close();
});

using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(2) };
var handler = new SaopOutboundHandler(http, 80);
var payload = "{\"entityKey\":\"A-1\",\"field\":\"ERP_DESCRIPTION\",\"value\":\"Nova luč\"}";
var result = await handler.SendAsync(new(new Uri($"http://127.0.0.1:{port}/products/A-1"), "PATCH", payload), CancellationToken.None);
var request = await received.Task;
Equal("PATCH", request.Method, "Fixture metoda");
Equal(payload, request.Body, "Fixture payload");
Equal(DispatchOutcome.Sent, result.Outcome, "2xx pomeni Sent, ne Verified");
Equal("fixture-42", result.CorrelationId, "Korelacija");
Equal(false, result.RedactedBody.Contains("secret-value", StringComparison.Ordinal), "Skrivnost mora biti redigirana");
Equal(true, result.RedactedBody.Contains("[REDACTED]", StringComparison.Ordinal), "Oznaka redakcije");
await server;

Throws<InvalidOperationException>(() => handler.CreateRequest(new(new Uri($"http://127.0.0.1:{port}/"), "PUT", "{}")), "PUT je prepovedan");
Equal(DispatchOutcome.Dead, DispatchClassifier.Classify(HttpStatusCode.BadRequest, 1, 5), "Trajni 4xx");
Equal(DispatchOutcome.Retry, DispatchClassifier.Classify(HttpStatusCode.ServiceUnavailable, 1, 5), "Začasni 5xx");
Equal(DispatchOutcome.Dead, DispatchClassifier.Classify(HttpStatusCode.ServiceUnavailable, 5, 5), "Izčrpani poskusi");
Equal(TimeSpan.FromSeconds(30), RetryPolicy.Delay(1, 30, 3600), "Prvi backoff");
Equal(TimeSpan.FromSeconds(120), RetryPolicy.Delay(3, 30, 3600), "Eksponentni backoff");
Equal(TimeSpan.FromSeconds(3600), RetryPolicy.Delay(20, 30, 3600), "Omejen backoff");
Console.WriteLine("F8 dispatcher: lokalni HTTP fixture, retry in redakcija PASS.");

static int GetPort()
{
  var listener = new System.Net.Sockets.TcpListener(IPAddress.Loopback, 0);
  listener.Start(); var port = ((IPEndPoint)listener.LocalEndpoint).Port; listener.Stop(); return port;
}
static void Equal<T>(T expected, T actual, string message)
{
  if (!EqualityComparer<T>.Default.Equals(expected, actual)) throw new InvalidOperationException($"{message}: pričakovano {expected}, dejansko {actual}.");
}
static void Throws<T>(Action action, string message) where T : Exception
{
  try { action(); } catch (T) { return; }
  throw new InvalidOperationException(message);
}
