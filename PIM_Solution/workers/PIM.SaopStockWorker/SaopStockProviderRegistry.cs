using System.Net;
using System.Net.Http.Json;
using System.Text.Json;

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
