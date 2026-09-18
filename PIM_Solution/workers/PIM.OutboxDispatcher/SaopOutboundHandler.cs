using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using PIM.Outbound;

namespace PIM.OutboxDispatcher;

public enum DispatchOutcome { Sent, Retry, Dead }

public sealed record OutboundHttpRequest(Uri Endpoint, string Operation, string PayloadJson);
public sealed record DispatchResult(DispatchOutcome Outcome, int StatusCode, string RedactedBody, string? CorrelationId, OutboundErrorClass ErrorClass = OutboundErrorClass.None);

public sealed class SaopOutboundHandler(HttpClient httpClient, int responseLimit = 4000)
{
  static readonly HashSet<string> SecretNames = new(StringComparer.OrdinalIgnoreCase)
  { "token", "access_token", "refresh_token", "password", "secret", "authorization", "apiKey" };

  public HttpRequestMessage CreateRequest(OutboundHttpRequest outbound)
  {
    var method = outbound.Operation switch
    {
      "POST" => HttpMethod.Post,
      "PATCH" => HttpMethod.Patch,
      _ => throw new InvalidOperationException("Dispatcher dovoljuje samo HTTP POST in PATCH.")
    };
    return new HttpRequestMessage(method, outbound.Endpoint)
    {
      Content = new StringContent(outbound.PayloadJson, Encoding.UTF8, "application/json")
    };
  }

  public async Task<DispatchResult> SendAsync(OutboundHttpRequest outbound, CancellationToken cancellationToken)
  {
    using var request = CreateRequest(outbound);
    using var response = await httpClient.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
    var raw = await response.Content.ReadAsStringAsync(cancellationToken);
    var correlation = Header(response.Headers, "X-Correlation-ID") ?? Header(response.Headers, "Request-ID");
    return new(DispatchClassifier.Classify(response.StatusCode, 1, int.MaxValue), (int)response.StatusCode, Redact(raw), correlation,
      DispatchClassifier.ClassifyError(response.StatusCode));
  }

  string Redact(string body)
  {
    string redacted;
    try
    {
      var node = JsonNode.Parse(body);
      RedactNode(node);
      redacted = node?.ToJsonString(new JsonSerializerOptions { WriteIndented = false }) ?? string.Empty;
    }
    catch (JsonException) { redacted = body; }
    return redacted.Length <= responseLimit ? redacted : redacted[..responseLimit];
  }

  static void RedactNode(JsonNode? node)
  {
    if (node is JsonObject value)
      foreach (var key in value.Select(pair => pair.Key).ToArray())
        if (SecretNames.Contains(key)) value[key] = "[REDACTED]"; else RedactNode(value[key]);
    else if (node is JsonArray array)
      foreach (var child in array) RedactNode(child);
  }

  static string? Header(HttpResponseHeaders headers, string name) =>
    headers.TryGetValues(name, out var values) ? values.FirstOrDefault() : null;
}

public static class DispatchClassifier
{
  public static DispatchOutcome Classify(HttpStatusCode status, int attempt, int maxAttempts)
  {
    var code = (int)status;
    if (code is >= 200 and <= 299) return DispatchOutcome.Sent;
    if (attempt >= maxAttempts) return DispatchOutcome.Dead;
    if (IsTransient(status)) return DispatchOutcome.Retry;
    return DispatchOutcome.Dead;
  }

  /// <summary>
  /// Vrzel O18: doslej je bila zavrnitev 400 in napaka poverilnice 401 ista stvar — sporocilo
  /// je umrlo, razloga pa ni bilo nikjer zapisanega. Razred napake se shrani na sporocilo in
  /// na poskus, ob <see cref="OutboundErrorClass.AuthConfig"/> pa <c>out.CompleteAttempt</c>
  /// ustavi kanal in sprozi en sam alarm na integracijo.
  /// </summary>
  public static OutboundErrorClass ClassifyError(HttpStatusCode status)
  {
    var code = (int)status;
    if (code is >= 200 and <= 299) return OutboundErrorClass.None;
    if (status is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden or HttpStatusCode.ProxyAuthenticationRequired)
      return OutboundErrorClass.AuthConfig;
    if (IsTransient(status)) return OutboundErrorClass.Transient;
    return OutboundErrorClass.Business;
  }

  /// <summary>Omrezna ali zacasna napaka; edina, ki jo je smiselno ponoviti z isto vsebino.</summary>
  static bool IsTransient(HttpStatusCode status)
  {
    var code = (int)status;
    return status is HttpStatusCode.RequestTimeout or HttpStatusCode.TooManyRequests || code >= 500;
  }
}

public static class RetryPolicy
{
  public static TimeSpan Delay(int attempt, int baseSeconds, int maximumSeconds)
  {
    var multiplier = Math.Pow(2, Math.Clamp(attempt - 1, 0, 30));
    return TimeSpan.FromSeconds(Math.Min(maximumSeconds, baseSeconds * multiplier));
  }
}
