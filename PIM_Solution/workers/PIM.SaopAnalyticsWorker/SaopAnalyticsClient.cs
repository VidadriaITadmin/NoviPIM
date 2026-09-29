using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Text;

namespace PIM.SaopAnalyticsWorker;

/// <summary>
/// Samo bralni (GET) klici v SAOP za analitiko. Avtentikacija in glava OrganisationId kot pri ostalih
/// SAOP workerjih — brez glave SAOP vrne napačno podjetje ali 401. Pisanja v SAOP ta razred ne zna.
/// </summary>
public sealed class SaopAnalyticsClient : IDisposable
{
  readonly HttpClient http;
  readonly AnalyticsSettings settings;

  public SaopAnalyticsClient(AnalyticsSettings settings) : this(settings, CreateHandler(settings)) { }

  public SaopAnalyticsClient(AnalyticsSettings settings, HttpMessageHandler handler)
  {
    this.settings = settings;
    http = new HttpClient(handler)
    {
      BaseAddress = new Uri(settings.BaseUrl.TrimEnd('/') + "/"),
      Timeout = TimeSpan.FromSeconds(Math.Max(30, settings.TimeoutSeconds)),
    };
    var credentials = Convert.ToBase64String(Encoding.ASCII.GetBytes($"{settings.Username}:{settings.Password}"));
    http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Basic", credentials);
    http.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/xml"));
  }

  static HttpMessageHandler CreateHandler(AnalyticsSettings settings)
  {
    var handler = new HttpClientHandler();
    if (settings.AcceptUntrustedCertificate) handler.ServerCertificateCustomValidationCallback = (_, _, _, _) => true;
    return handler;
  }

  public Uri BaseAddress => http.BaseAddress!;

  public static string Query(string path, params (string Name, string? Value)[] parameters)
  {
    var parts = parameters.Where(p => !string.IsNullOrEmpty(p.Value)).Select(p => $"{p.Name}={Uri.EscapeDataString(p.Value!)}").ToArray();
    return parts.Length == 0 ? path : path + "?" + string.Join("&", parts);
  }

  public static string Stamp(DateTime utc) => utc.ToString("yyyy-MM-ddTHH:mm:ss", CultureInfo.InvariantCulture);

  public async Task<string> GetAsync(int organizationId, string relativeUrl, CancellationToken cancellationToken)
  {
    var maxExtra = Math.Max(0, settings.RetryMaxExtraAttempts);
    var delay = Math.Max(100, settings.RetryBaseDelayMilliseconds);
    for (var attempt = 0; ; attempt++)
    {
      using var request = new HttpRequestMessage(HttpMethod.Get, relativeUrl);
      request.Headers.Add("OrganisationId", organizationId.ToString(CultureInfo.InvariantCulture));
      HttpResponseMessage response;
      try
      {
        response = await http.SendAsync(request, cancellationToken);
      }
      catch (HttpRequestException exception) when (attempt < maxExtra)
      {
        Console.Error.WriteLine($"    SAOP ni odgovoril ({exception.Message}); ponovni poskus čez {delay} ms.");
        await Task.Delay(delay, cancellationToken);
        delay *= 2;
        continue;
      }

      using (response)
      {
        var body = await response.Content.ReadAsStringAsync(cancellationToken);
        if (response.IsSuccessStatusCode)
        {
          if (settings.DelayBetweenCallsMilliseconds > 0) await Task.Delay(settings.DelayBetweenCallsMilliseconds, cancellationToken);
          return body;
        }
        if (attempt < maxExtra && IsTransient(response.StatusCode))
        {
          await Task.Delay(delay, cancellationToken);
          delay *= 2;
          continue;
        }
        var snippet = string.IsNullOrWhiteSpace(body) ? "<prazno telo>" : body[..Math.Min(400, body.Length)];
        throw new SaopCallException((int)response.StatusCode,
          $"SAOP klic ni uspel. Podjetje={organizationId} Url={new Uri(http.BaseAddress!, relativeUrl)} "
          + $"Status={(int)response.StatusCode} {response.ReasonPhrase}. Odlomek odgovora: {snippet}");
      }
    }
  }

  static bool IsTransient(HttpStatusCode code) =>
    code is HttpStatusCode.RequestTimeout or HttpStatusCode.BadGateway or HttpStatusCode.ServiceUnavailable
      or HttpStatusCode.GatewayTimeout or (HttpStatusCode)429;

  public void Dispose() => http.Dispose();
}

public sealed class SaopCallException(int statusCode, string message) : Exception(message)
{
  public int StatusCode { get; } = statusCode;
}
