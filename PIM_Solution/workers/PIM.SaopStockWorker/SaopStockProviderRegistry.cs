using System.Net;
using System.Net.Http.Json;
using System.Text.Json;

namespace PIM.SaopStockWorker;

public sealed record SaopProviderConfiguration(string ProviderKind, string? RegisteredViewId, IReadOnlyList<int> WarehouseIds);

public sealed class SaopStockProviderRegistry
{
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
    return new(HttpMethod.Get, new Uri(baseUri, $"api/registeredviews/data?viewId={WebUtility.UrlEncode(profile.RegisteredViewId)}"));
  }

  static HttpRequestMessage Warehouse(SaopProviderConfiguration profile, Uri baseUri, string endpoint)
  {
    if (profile.WarehouseIds.Count == 0) throw new InvalidOperationException("Vsaj en warehouse ID je obvezen.");
    var request = new HttpRequestMessage(HttpMethod.Post, new Uri(baseUri, endpoint));
    request.Content = JsonContent.Create(new { searchQuery = new { warehouseIdList = profile.WarehouseIds } });
    return request;
  }
}
