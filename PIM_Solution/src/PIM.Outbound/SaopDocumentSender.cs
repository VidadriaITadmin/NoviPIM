using System.Net;
using System.Net.Http.Headers;
using System.Text;

namespace PIM.Outbound;

/// <summary>Nastavitve povezave na SAOP. Poverilnice pridejo iz git-ignorirane lokalne datoteke ali okolja.</summary>
/// <param name="AcceptUntrustedCertificate">
/// SAOP iCenter na lokalnem omrežju ima lasten certifikat. Velja samo za tega odjemalca in samo,
/// kadar je izrecno vklopljeno. Privzeto izklopljeno.
/// </param>
public sealed record SaopConnection(
  string BaseUrl,
  string Username,
  string Password,
  int TimeoutSeconds = 120,
  bool AcceptUntrustedCertificate = false);

/// <param name="Sent">Ali je zahteva sploh odšla. V suhem teku je vedno <c>false</c>.</param>
public sealed record SaopSendOutcome(
  bool Sent,
  int StatusCode,
  SaopResponse Response,
  string RawResponse,
  string? CorrelationId);

/// <summary>
/// Pošlje en dokument SAOP.
///
/// Kar je moralo biti tu in v dosedanjem <see cref="SaopOutboundHandler"/> ni bilo:
///
/// - <b>Basic avtentikacija.</b> Dosedanji dispatcher je uporabljal gol <c>HttpClient</c> brez
///   poverilnice; vsaka zahteva bi se končala s 401.
/// - <b>Glava <c>OrganisationId</c>.</b> Brez nje SAOP vrne podatke napačnega podjetja ali 401.
/// - <b>Tip vsebine <c>application/xml</c>.</b> Dosedanji je pošiljal <c>application/json</c>,
///   česar zapisovalne končne točke SAOP sploh ne sprejmejo.
/// - <b>Pravilno kodiranje odgovora.</b> Odgovori pridejo v <c>windows-1250</c>; brani kot UTF-8
///   so v stari bazi shranjeni pokvarjeni in navodila iz njih ni bilo mogoče prebrati.
///
/// Vse štiri stvari je stari worker <c>SAOP_Insert_products</c> imel prav; tu so prepisane iz
/// njega, razen kodiranja, ki ga tudi on ni imel.
/// </summary>
public sealed class SaopDocumentSender : IDisposable
{
  readonly HttpClient http;
  readonly SaopConnection connection;

  public SaopDocumentSender(SaopConnection connection) : this(connection, CreateHandler(connection)) { }

  /// <summary>Testni konstruktor — sprejme poljuben <see cref="HttpMessageHandler"/>.</summary>
  public SaopDocumentSender(SaopConnection connection, HttpMessageHandler handler)
  {
    this.connection = connection;
    http = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(Math.Max(30, connection.TimeoutSeconds)) };
    if (!string.IsNullOrWhiteSpace(connection.BaseUrl))
      http.BaseAddress = new Uri(connection.BaseUrl.TrimEnd('/') + "/");
    var credentials = Convert.ToBase64String(Encoding.ASCII.GetBytes($"{connection.Username}:{connection.Password}"));
    http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Basic", credentials);
    http.DefaultRequestHeaders.Accept.Clear();
    http.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/xml"));
  }

  static HttpMessageHandler CreateHandler(SaopConnection connection)
  {
    var handler = new HttpClientHandler();
    if (connection.AcceptUntrustedCertificate)
      handler.ServerCertificateCustomValidationCallback = (_, _, _, _) => true;
    return handler;
  }

  /// <param name="baseUrlOverride">
  /// Naslov iz integracijskega profila organizacije. Vsaka organizacija ima lahko svoj SAOP in
  /// svoje okolje (produkcija ali test); stari sistem je to reševal prek pim.IntegrationEndpoint.
  /// Kadar ni podan, velja naslov iz nastavitev odjemalca.
  /// </param>
  public async Task<SaopSendOutcome> SendAsync(
    int organizationId, string path, string operation, string xml, CancellationToken cancellationToken,
    string? baseUrlOverride = null)
  {
    var method = operation switch
    {
      "POST" => HttpMethod.Post,
      "PATCH" => HttpMethod.Patch,
      _ => throw new InvalidOperationException($"SAOP dovoljuje samo POST in PATCH, ne {operation}.")
    };

    var baseAddress = string.IsNullOrWhiteSpace(baseUrlOverride)
      ? http.BaseAddress ?? throw new InvalidOperationException("Naslov SAOP ni nastavljen ne v profilu ne v nastavitvah.")
      : new Uri(baseUrlOverride!.TrimEnd('/') + "/");
    using var request = new HttpRequestMessage(method, new Uri(baseAddress, path.TrimStart('/')));
    request.Headers.Add("OrganisationId", organizationId.ToString(System.Globalization.CultureInfo.InvariantCulture));
    request.Content = new StringContent(SaopDocumentBuilder.WithUtf8Prolog(xml), Encoding.UTF8, "application/xml");

    using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
    var bytes = await response.Content.ReadAsByteArrayAsync(cancellationToken);
    var body = SaopResponseReader.DecodeBody(bytes, response.Content.Headers.ContentType?.CharSet);
    var parsed = SaopResponseReader.Read(body);

    // Uspeh je presek obojega: HTTP mora biti 2xx IN SAOP mora v telesu reci Ok ali Created.
    // Odgovor 200 z ResultCode=Error je zavrnitev, HTTP 409 pa nosi ArrayOfError brez ResultCode.
    var httpOk = (int)response.StatusCode is >= 200 and <= 299;
    var effective = httpOk && parsed.IsSuccess
      ? parsed
      : parsed with { IsSuccess = false };

    return new(true, (int)response.StatusCode, effective, body, Header(response, "X-Correlation-ID") ?? Header(response, "Request-ID"));
  }

  static string? Header(HttpResponseMessage response, string name) =>
    response.Headers.TryGetValues(name, out var values) ? values.FirstOrDefault() : null;

  /// <summary>Razred napake iz HTTP kode in iz tega, kaj je povedal SAOP.</summary>
  public static OutboundErrorClass Classify(int statusCode, SaopResponse response)
  {
    if (response.ResultCode == SaopResultCode.Unauthorized) return OutboundErrorClass.AuthConfig;
    var status = (HttpStatusCode)statusCode;
    if (status is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden or HttpStatusCode.ProxyAuthenticationRequired)
      return OutboundErrorClass.AuthConfig;
    if (status is HttpStatusCode.RequestTimeout or HttpStatusCode.TooManyRequests || statusCode >= 500)
      return OutboundErrorClass.Transient;
    // Zavrnitev, ki jo je SAOP razumel in pojasnil, je poslovna: ponavljanje da isti odgovor.
    return OutboundErrorClass.Business;
  }

  public void Dispose() => http.Dispose();
}
