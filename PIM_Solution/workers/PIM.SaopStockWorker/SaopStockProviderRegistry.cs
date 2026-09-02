using System.Globalization;
using System.Net;
using System.Security;
using System.Text;

namespace PIM.SaopStockWorker;

public sealed record SaopProviderConfiguration(
  string ProviderKind,
  string? RegisteredViewId,
  IReadOnlyList<string> WarehouseIds,
  int? PageSize = null,
  int Page = 1,
  DateTime? ModifiedFromUtc = null);

public sealed class SaopStockProviderRegistry
{
  /// <summary>Pot registriranega pogleda; ista za zahtevo in za zapis v stock.Snapshot.Endpoint.</summary>
  public const string RegisteredViewPath = "api/registeredviews/data";

  /// <summary>Privzeta velikost strani registriranega pogleda — enaka kot v starem sistemu (1000).</summary>
  public const int RegisteredViewDefaultPageSize = 1000;

  readonly IReadOnlyDictionary<string, Func<SaopProviderConfiguration, Uri, HttpRequestMessage>> providers;
  SaopStockProviderRegistry(IReadOnlyDictionary<string, Func<SaopProviderConfiguration, Uri, HttpRequestMessage>> providers) => this.providers = providers;

  public static SaopStockProviderRegistry CreateDefault() => new(new Dictionary<string, Func<SaopProviderConfiguration, Uri, HttpRequestMessage>>(StringComparer.Ordinal)
  {
    ["RegisteredViewData"] = RegisteredView,
    ["StockAdvance"] = (profile, baseUri) => Warehouse(profile, baseUri, "api/Stock/GetStockAdvance"),
    ["GetStocks"] = (profile, baseUri) => Warehouse(profile, baseUri, "api/Stock/GetStocks")
  });

  public HttpRequestMessage CreateRequest(SaopProviderConfiguration profile, Uri baseUri)
  {
    if (!providers.TryGetValue(profile.ProviderKind, out var provider)) throw new InvalidOperationException($"Neznan ProviderKind: {profile.ProviderKind}.");
    return provider(profile, baseUri);
  }

  static HttpRequestMessage RegisteredView(SaopProviderConfiguration profile, Uri baseUri)
  {
    if (string.IsNullOrWhiteSpace(profile.RegisteredViewId)) throw new InvalidOperationException("RegisteredViewId je obvezen.");
    // Pogodba je iz Swaggerja SAOP (ApiRegisteredView_GetDataFromRegisteredView): POST z XML
    // telesom GetDataFromRegisteredViewRequest, stranjenje s ResultPageNumber/ResultPageSize.
    // Prejsnja razlicica je posiljala GET ?viewId=…, ki ga API ne pozna; napaka je bila
    // nevidna, ker je bil profil izklopljen. Telo je prepisano z delujoce zahteve starega
    // sistema (PIM_test SaopStockWorker, RegisteredViewRequestBuilder).
    var request = new HttpRequestMessage(HttpMethod.Post, new Uri(baseUri, RegisteredViewPath))
    {
      Content = new StringContent(RegisteredViewBody(profile.RegisteredViewId, profile.Page, profile.PageSize ?? RegisteredViewDefaultPageSize), Encoding.UTF8, "application/xml")
    };
    return request;
  }

  /// <summary>Telo zahteve za registrirani pogled; javno, da ga test primerja dobesedno.</summary>
  public static string RegisteredViewBody(string registeredViewId, int page, int pageSize)
  {
    if (page < 1) page = 1;
    if (pageSize < 1) pageSize = RegisteredViewDefaultPageSize;
    var id = SecurityElement.Escape(registeredViewId.Trim());
    var builder = new StringBuilder(512);
    builder.AppendLine("<?xml version=\"1.0\" encoding=\"utf-8\"?>");
    builder.AppendLine("<GetDataFromRegisteredViewRequest xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\">");
    builder.Append("  <RegisteredViewID>").Append(id).AppendLine("</RegisteredViewID>");
    builder.AppendLine("  <Filter />");
    builder.Append("  <ResultPageNumber>").Append(page.ToString(CultureInfo.InvariantCulture)).AppendLine("</ResultPageNumber>");
    builder.Append("  <ResultPageSize>").Append(pageSize.ToString(CultureInfo.InvariantCulture)).AppendLine("</ResultPageSize>");
    builder.AppendLine("  <OrderBy />");
    builder.AppendLine("</GetDataFromRegisteredViewRequest>");
    return builder.ToString();
  }

  static HttpRequestMessage Warehouse(SaopProviderConfiguration profile, Uri baseUri, string endpoint)
  {
    if (profile.WarehouseIds.Count == 0) throw new InvalidOperationException("Vsaj en warehouse ID je obvezen.");
    // Pogodba je iz Swaggerja SAOP (docs\Povezave_virov_in_sistemov\SAOP_API_swagger_v2.json):
    // GetStocks in GetStockAdvance sta GET s parametri v naslovu in vrneta XML. Prej je bil tu
    // POST z JSON telesom — oblika, ki je API ne pozna; napaka je bila nevidna, ker klica ni
    // nikoli nihce izvedel.
    //
    // Sifra skladisca gre v zahtevo kot NIZ z vodilnimi niclami ("0000003"). Izmerjeno na zivem
    // SAOP 2026-08-27: "0000003" vrne 138 zapisov, "3" pa HTTP 200 z enim praznim <Item>. Swagger
    // pravi type=string in to je treba vzeti dobesedno — pretvorba v int tiho izprazni rezultat.
    var query = new List<string>
    {
      $"searchQuery.warehouseIdList={WebUtility.UrlEncode(string.Join(',', profile.WarehouseIds))}",
      "searchQuery.includeZeroQuantities=true"
    };
    if (profile.PageSize is int pageSize && pageSize > 0)
    {
      query.Add($"searchQuery.page={profile.Page}");
      query.Add($"searchQuery.pageSize={pageSize}");
    }
    if (profile.ModifiedFromUtc is DateTime modifiedFrom)
    {
      query.Add($"searchQuery.recordDtModifiedFrom={WebUtility.UrlEncode(modifiedFrom.ToString("O"))}");
    }
    return new(HttpMethod.Get, new Uri(baseUri, $"{endpoint}?{string.Join('&', query)}"));
  }
}
