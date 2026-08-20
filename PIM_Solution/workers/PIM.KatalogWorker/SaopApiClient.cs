using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Xml;
using System.Xml.Linq;

namespace PIM.KatalogWorker;

/// <summary>Ena prebrana stran: surov XML in koliko zapisov je v njej.</summary>
public sealed record SaopPage(string EndpointKey, int PageNumber, string PayloadXml, int RecordCount);

/// <summary>
/// Živ odjemalec za SAOP iCenter API.
///
/// Kar je moralo biti tu in prej ni bilo: Basic avtentikacija, glava <c>OrganisationId</c>
/// (brez nje API vrne podatke napačnega podjetja ali 401), paginacija prek
/// <c>searchQuery.page</c>/<c>pageSize</c>, delta filter <c>searchQuery.recordDtModifiedFrom</c>
/// in ponovni poskusi ob prehodnih napakah. Prejšnja izvedba je klicala eno samo stran, zato je
/// zajela prvih nekaj tisoč artiklov in tiho izpustila ostalo.
/// </summary>
public sealed class SaopApiClient : IDisposable
{
  private readonly HttpClient http;
  private readonly SaopSettings settings;

  public SaopApiClient(SaopSettings settings)
    : this(settings, CreateHandler(settings))
  {
  }

  /// <summary>Testni konstruktor — sprejme poljuben <see cref="HttpMessageHandler"/> brez TLS nastavitev.</summary>
  public SaopApiClient(SaopSettings settings, HttpMessageHandler handler)
  {
    this.settings = settings;
    http = new HttpClient(handler)
    {
      BaseAddress = new Uri(settings.BaseUrl.TrimEnd('/') + "/"),
      Timeout = TimeSpan.FromSeconds(Math.Max(30, settings.TimeoutSeconds))
    };

    var credentials = Convert.ToBase64String(Encoding.ASCII.GetBytes($"{settings.Username}:{settings.Password}"));
    http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Basic", credentials);
    http.DefaultRequestHeaders.Accept.Clear();
    http.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/xml"));
  }

  private static HttpMessageHandler CreateHandler(SaopSettings settings)
  {
    var handler = new HttpClientHandler();
    if (settings.AcceptUntrustedCertificate)
    {
      // SAOP iCenter na lokalnem omrežju ima lasten certifikat. Velja samo za ta odjemalec in
      // samo, kadar je izrecno vklopljeno v lokalni konfiguraciji (AcceptUntrustedCertificate: true).
      // Privzeto je izklopljeno — ne vklapljaj v produkciji.
      handler.ServerCertificateCustomValidationCallback = (_, _, _, _) => true;
    }

    return handler;
  }

  /// <summary>Bere stran za stranjo, dokler ena ne pride prazna ali dokler ni dosežena varovalka MaxPagesPerEndpoint.</summary>
  public async IAsyncEnumerable<SaopPage> ReadAsync(
    SaopEndpoint endpoint,
    int organizationId,
    DateTime? modifiedFromUtc,
    string? priceListId,
    DateTime? priceListDate,
    [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken cancellationToken = default)
  {
    if (endpoint.Kind == SaopEndpointKind.Lookup)
    {
      var xml = await SendAsync(organizationId, endpoint.Path, cancellationToken);
      var (lookupRecords, lookupError) = TryCountRecords(xml);
      yield return new SaopPage(endpoint.Key, 1, xml, lookupRecords);
      if (lookupError is not null)
      {
        throw new InvalidOperationException(
          $"Lookup končna točka {endpoint.Key} je vrnila nepraven XML: {lookupError.Message}", lookupError);
      }

      yield break;
    }

    var pageSize = Math.Max(1, settings.PageSize);
    var maxPages = Math.Max(1, settings.MaxPagesPerEndpoint);
    for (var page = 1; page <= maxPages; page++)
    {
      cancellationToken.ThrowIfCancellationRequested();
      var relativeUrl = BuildPagedUrl(endpoint, page, pageSize, modifiedFromUtc, priceListId, priceListDate);
      var xml = await SendAsync(organizationId, relativeUrl, cancellationToken);
      var (records, parseError) = TryCountRecords(xml);

      if (parseError is not null)
      {
        // Ohrani surov payload v raw.Inbox (karantena v preslikavi bo razlog videla);
        // nato vrži napako, da watermark ostane pri miru in zajem ni tiho napačen.
        yield return new SaopPage(endpoint.Key, page, xml, 0);
        throw new InvalidOperationException(
          $"Stran {page} končne točke {endpoint.Key} vsebuje nepraven XML. "
          + $"Vsebina je shranjena v raw.Inbox za karanteno. Napaka razčlenjevanja: {parseError.Message}",
          parseError);
      }

      if (records == 0)
      {
        yield break;
      }

      yield return new SaopPage(endpoint.Key, page, xml, records);

      // Krajša stran od zahtevane pomeni zadnjo stran; brez tega bi vedno naredili en prazen klic več.
      if (records < pageSize)
      {
        yield break;
      }
    }

    // Dosegli smo varovalko MaxPagesPerEndpoint, a zadnja stran ni bila niti prazna niti krajša.
    // Podatki so nepopolni — ne smemo premakniti watermark in ne smemo tega tiho zamuzniti.
    throw new InvalidOperationException(
      $"Dosežena varovalka MaxPagesPerEndpoint ({maxPages}) za {endpoint.Key}: zadnja stran ni bila prazna "
      + "ali krajša od pageSize. Podatki so verjetno nepopolni. Povečaj MaxPagesPerEndpoint ali preveri obseg sprememb.");
  }

  private string BuildPagedUrl(
    SaopEndpoint endpoint,
    int page,
    int pageSize,
    DateTime? modifiedFromUtc,
    string? priceListId,
    DateTime? priceListDate)
  {
    var query = new List<string>
    {
      $"searchQuery.page={page}",
      $"searchQuery.pageSize={pageSize}"
    };

    if (endpoint.Kind == SaopEndpointKind.Prices)
    {
      if (string.IsNullOrWhiteSpace(priceListId))
      {
        throw new InvalidOperationException($"{endpoint.Key} zahteva priceListID.");
      }

      query.Add($"searchQuery.priceListID={Uri.EscapeDataString(priceListId)}");
      query.Add($"searchQuery.priceListDate={Uri.EscapeDataString((priceListDate ?? DateTime.Today).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture))}");
    }

    if (endpoint.SupportsWatermark && modifiedFromUtc is not null)
    {
      var formatted = modifiedFromUtc.Value.ToString("yyyy-MM-ddTHH:mm:ss", CultureInfo.InvariantCulture);
      query.Add($"searchQuery.recordDtModifiedFrom={Uri.EscapeDataString(formatted)}");
    }

    if (endpoint.SupportsIncludeNonActive && settings.IncludeNonActiveItems)
    {
      query.Add("searchQuery.includeNonActiveItems=true");
    }

    return endpoint.Path.TrimStart('/') + "?" + string.Join("&", query);
  }

  private async Task<string> SendAsync(int organizationId, string relativeUrl, CancellationToken cancellationToken)
  {
    var maxExtra = Math.Max(0, settings.RetryMaxExtraAttempts);
    var delayMilliseconds = Math.Max(50, settings.RetryBaseDelayMilliseconds);

    for (var attempt = 0; ; attempt++)
    {
      using var request = new HttpRequestMessage(HttpMethod.Get, relativeUrl);
      request.Headers.Add("OrganisationId", organizationId.ToString(CultureInfo.InvariantCulture));

      using var response = await http.SendAsync(request, cancellationToken);
      var body = await response.Content.ReadAsStringAsync(cancellationToken);

      if (response.IsSuccessStatusCode)
      {
        if (settings.DelayAfterSuccessMilliseconds > 0)
        {
          await Task.Delay(settings.DelayAfterSuccessMilliseconds, cancellationToken);
        }

        return body;
      }

      if (attempt < maxExtra && IsTransient(response.StatusCode))
      {
        await Task.Delay(delayMilliseconds, cancellationToken);
        delayMilliseconds *= 2;
        continue;
      }

      // Uporabniško ime navedemo, ker je prva napaka pri postavitvi skoraj vedno napačen račun;
      // gesla ne izpisujemo nikoli.
      var snippet = string.IsNullOrWhiteSpace(body)
        ? "<prazno telo>"
        : body[..Math.Min(300, body.Length)];
      throw new InvalidOperationException(
        $"SAOP klic ni uspel. Podjetje={organizationId} Url={new Uri(http.BaseAddress!, relativeUrl)} "
        + $"Status={(int)response.StatusCode} {response.ReasonPhrase} Uporabnik={settings.Username}. Odlomek odgovora:{Environment.NewLine}{snippet}");
    }
  }

  private static bool IsTransient(HttpStatusCode code) =>
    code is HttpStatusCode.RequestTimeout
      or HttpStatusCode.BadGateway
      or HttpStatusCode.ServiceUnavailable
      or HttpStatusCode.GatewayTimeout
      or (HttpStatusCode)429;

  /// <summary>
  /// Šteje neposredne otroke korena. Vsi SAOP odgovori so oblike koren → seznam zapisov
  /// (<c>ItemsGeneralData/ItemGeneralData</c>, <c>ArrayOfCurrency/Currency</c> …), zato je to
  /// zanesljiv znak za konec paginacije.
  /// </summary>
  public static int CountRecords(string xml)
  {
    if (string.IsNullOrWhiteSpace(xml))
    {
      return 0;
    }

    try
    {
      var document = XDocument.Parse(xml);
      return document.Root?.Elements().Count() ?? 0;
    }
    catch (XmlException)
    {
      return 0;
    }
  }

  /// <summary>
  /// Kot <see cref="CountRecords"/>, a namesto 0 vrne napako razčlenjevanja, da jo klicatelj
  /// loči od veljavnega praznega odgovora (ki pomeni konec paginacije).
  /// </summary>
  private static (int Records, XmlException? ParseError) TryCountRecords(string xml)
  {
    if (string.IsNullOrWhiteSpace(xml))
    {
      return (0, null);
    }

    try
    {
      var document = XDocument.Parse(xml);
      return (document.Root?.Elements().Count() ?? 0, null);
    }
    catch (XmlException ex)
    {
      return (0, ex);
    }
  }

  public void Dispose() => http.Dispose();
}
