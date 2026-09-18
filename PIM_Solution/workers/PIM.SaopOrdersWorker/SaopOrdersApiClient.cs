using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Runtime.CompilerServices;
using System.Text;
using System.Xml.Linq;

namespace PIM.SaopOrdersWorker;

/// <summary>Naravni ključ naročila/naročilnice: leto, knjiga, številka.</summary>
public sealed record OrderKey(int Year, string Book, int Number);

/// <summary>Ena stran odkritvenega (Status) klica: surov XML in ključi, razčlenjeni iz nje.</summary>
public sealed record StatusPage(string PayloadXml, IReadOnlyList<OrderKey> Keys);

/// <summary>
/// Živ odjemalec za SAOP klice, ki jih ta delavec rabi: odkritje odprtih/spremenjenih naročil
/// (GetOrderStatus, GetPurchaseOrdersStatus) in podrobnosti po ključu (GetOrder, GetPurchaseOrder).
/// Prodajna zgodovina za ABC/MIN-MID-MAX se računa iz teh istih vrstic (Qty/ShippedQTY), ne iz
/// ločenega klica GetOrderRealisation — ta bi vrnil isti podatek, ki ga tu že imamo.
///
/// Avtentikacija in glava OrganisationId sta enaka kot pri PIM.KatalogWorker.SaopApiClient — brez
/// glave SAOP vrne napačno podjetje ali 401.
/// </summary>
public sealed class SaopOrdersApiClient : IDisposable
{
  private readonly HttpClient http;
  private readonly OrdersSettings settings;

  public SaopOrdersApiClient(OrdersSettings settings) : this(settings, CreateHandler(settings))
  {
  }

  public SaopOrdersApiClient(OrdersSettings settings, HttpMessageHandler handler)
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

  private static HttpMessageHandler CreateHandler(OrdersSettings settings)
  {
    var handler = new HttpClientHandler();
    if (settings.AcceptUntrustedCertificate)
    {
      handler.ServerCertificateCustomValidationCallback = (_, _, _, _) => true;
    }
    return handler;
  }

  /// <summary>Odkritje odprtih/spremenjenih naročil kupcev (VNK) po straneh.</summary>
  public IAsyncEnumerable<StatusPage> ReadSalesOrderKeysAsync(
    int organizationId, string orderBook, DateTime? modifiedFromUtc, CancellationToken cancellationToken = default) =>
    ReadStatusPagesAsync(
      organizationId, "api/Order/GetOrderStatus", "searchQuery.orderBook", orderBook, modifiedFromUtc,
      "OrderYear", "OrderBook", "OrderNumber", cancellationToken);

  /// <summary>Odkritje odprtih/spremenjenih naročil dobaviteljem (VND) po straneh.</summary>
  public IAsyncEnumerable<StatusPage> ReadPurchaseOrderKeysAsync(
    int organizationId, string purchaseOrderBook, DateTime? modifiedFromUtc, CancellationToken cancellationToken = default) =>
    ReadStatusPagesAsync(
      organizationId, "api/PurchaseOrders/GetPurchaseOrdersStatus", "searchQuery.purchaseOrderBook", purchaseOrderBook,
      modifiedFromUtc, "PurchaseOrderYear", "PurchaseOrderBook", "PurchaseOrderNumber", cancellationToken);

  /// <summary>
  /// Skupno jedro za oba odkritvena klica: prebere stran za stranjo, razčleni ključe po IMENU
  /// elementa (ne po korenu ovojnice, ki ga swagger shema zavajajoče poimenuje) — zato ni odvisno
  /// od tega, ali je pravi koren "ArrayOfOrdersStatus" ali kaj drugega.
  /// </summary>
  private async IAsyncEnumerable<StatusPage> ReadStatusPagesAsync(
    int organizationId, string path, string bookParam, string bookValue, DateTime? modifiedFromUtc,
    string yearElement, string bookElement, string numberElement,
    [EnumeratorCancellation] CancellationToken cancellationToken)
  {
    var pageSize = Math.Max(1, settings.PageSize);
    for (var page = 1; page <= settings.MaxPagesPerCall; page++)
    {
      cancellationToken.ThrowIfCancellationRequested();
      var query = new List<string> { $"searchQuery.page={page}", $"searchQuery.pageSize={pageSize}", $"{bookParam}={Uri.EscapeDataString(bookValue)}" };
      if (modifiedFromUtc is { } from)
      {
        query.Add($"searchQuery.recordDtModifiedFrom={Uri.EscapeDataString(from.ToString("yyyy-MM-ddTHH:mm:ss", CultureInfo.InvariantCulture))}");
      }

      var xml = await SendAsync(organizationId, path + "?" + string.Join("&", query), cancellationToken);
      var document = ParseOrThrow(xml, path, page);
      var records = document.Root?.Elements().ToList() ?? [];
      if (records.Count == 0) yield break;

      var keys = new List<OrderKey>();
      foreach (var record in records)
      {
        var year = ChildValue(record, yearElement);
        var book = ChildValue(record, bookElement);
        var number = ChildValue(record, numberElement);
        if (int.TryParse(year, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsedYear)
          && !string.IsNullOrWhiteSpace(book)
          && int.TryParse(number, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsedNumber))
        {
          keys.Add(new OrderKey(parsedYear, book, parsedNumber));
        }
      }

      yield return new StatusPage(xml, keys);
      if (records.Count < pageSize) yield break;
    }

    throw new InvalidOperationException(
      $"Dosežena varovalka MaxPagesPerCall ({settings.MaxPagesPerCall}) za {path}. Podatki so verjetno nepopolni.");
  }

  /// <summary>Podrobnosti enega naročila kupca (glava + vse vrstice), po ključu.</summary>
  public Task<string> GetSalesOrderDetailAsync(int organizationId, OrderKey key, CancellationToken cancellationToken = default) =>
    SendAsync(organizationId, $"api/Order/GetOrder/{key.Year}/{Uri.EscapeDataString(key.Book)}/{key.Number}", cancellationToken);

  /// <summary>Podrobnosti enega naročila dobavitelju (glava + vse vrstice), po ključu.</summary>
  public Task<string> GetPurchaseOrderDetailAsync(int organizationId, OrderKey key, CancellationToken cancellationToken = default) =>
    SendAsync(organizationId, $"api/PurchaseOrders/GetPurchaseOrder/{key.Year}/{Uri.EscapeDataString(key.Book)}/{key.Number}", cancellationToken);

  private static XDocument ParseOrThrow(string xml, string path, int page)
  {
    try
    {
      return XDocument.Parse(xml);
    }
    catch (System.Xml.XmlException ex)
    {
      throw new InvalidOperationException($"Stran {page} klica {path} vsebuje neveljaven XML: {ex.Message}", ex);
    }
  }

  private static string? ChildValue(XElement record, string localName) =>
    record.Elements().FirstOrDefault(e => e.Name.LocalName == localName)?.Value;

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

      if (response.IsSuccessStatusCode) return body;

      if (attempt < maxExtra && IsTransient(response.StatusCode))
      {
        await Task.Delay(delayMilliseconds, cancellationToken);
        delayMilliseconds *= 2;
        continue;
      }

      var snippet = string.IsNullOrWhiteSpace(body) ? "<prazno telo>" : body[..Math.Min(300, body.Length)];
      throw new InvalidOperationException(
        $"SAOP klic ni uspel. Podjetje={organizationId} Url={new Uri(http.BaseAddress!, relativeUrl)} "
        + $"Status={(int)response.StatusCode} {response.ReasonPhrase} Uporabnik={settings.Username}. Odlomek odgovora:{Environment.NewLine}{snippet}");
    }
  }

  private static bool IsTransient(HttpStatusCode code) =>
    code is HttpStatusCode.RequestTimeout or HttpStatusCode.BadGateway or HttpStatusCode.ServiceUnavailable
      or HttpStatusCode.GatewayTimeout or (HttpStatusCode)429;

  public void Dispose() => http.Dispose();
}
