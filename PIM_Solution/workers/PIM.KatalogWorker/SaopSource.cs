using System.Text.Json.Serialization;
using System.Xml.Linq;

namespace PIM.KatalogWorker;

public enum SaopSourceMode
{
  Disabled,
  Fixture,
  Live
}

public sealed record SaopSourceOptions(SaopSourceMode Mode, string FixtureRoot, Uri? BaseUrl);
public sealed record RawPage(string Endpoint, int PageNumber, string PayloadXml);
public sealed record FixtureFactCounts(int GeneralProducts, int Prices, int Descriptions);

public interface ISaopSource
{
  Task<IReadOnlyList<RawPage>> ReadAsync(CancellationToken cancellationToken = default);
}

public static class SaopSource
{
  internal static readonly string[] Endpoints =
    ["ItemGeneralData", "Prices", "Descriptions", "Currencies", "PriceLists"];

  public static ISaopSource Create(SaopSourceOptions options, HttpClient httpClient) => options.Mode switch
  {
    SaopSourceMode.Disabled => new DisabledSaopSource(),
    SaopSourceMode.Fixture => new FixtureSaopSource(options.FixtureRoot),
    SaopSourceMode.Live => new LiveSaopSource(httpClient, options.BaseUrl
      ?? throw new InvalidOperationException("Za Live manjka SAOP osnovni URL.")),
    _ => throw new ArgumentOutOfRangeException(nameof(options))
  };
}

internal sealed class DisabledSaopSource : ISaopSource
{
  public Task<IReadOnlyList<RawPage>> ReadAsync(CancellationToken cancellationToken = default) =>
    Task.FromResult<IReadOnlyList<RawPage>>([]);
}

/// <summary>
/// Bere strani, kot jih navaja fixtures/saop/iqlighting/manifest.json — ne predpostavlja natanko ene
/// datoteke "page-001.xml" na končno točko, ker je resnični SAOP odgovor lahko straničen na več strani.
/// Manifest ustvari ali osveži PIM.FixtureExport (glej tools/PIM.FixtureExport).
/// </summary>
internal sealed class FixtureSaopSource(string fixtureRoot) : ISaopSource
{
  public async Task<IReadOnlyList<RawPage>> ReadAsync(CancellationToken cancellationToken = default)
  {
    var manifest = await FixtureManifest.LoadAsync(Path.Combine(fixtureRoot, "manifest.json"), cancellationToken);

    var pages = new List<RawPage>();
    foreach (var endpoint in SaopSource.Endpoints)
    {
      var endpointManifest = manifest.Endpoints.FirstOrDefault(candidate => candidate.Endpoint == endpoint)
        ?? throw new InvalidOperationException($"Manifest ne vsebuje končne točke {endpoint}.");
      if (endpointManifest.Pages.Count == 0)
      {
        throw new InvalidOperationException($"Manifest za končno točko {endpoint} ne navaja nobene strani.");
      }

      foreach (var page in endpointManifest.Pages.OrderBy(page => page.Page))
      {
        var path = Path.Combine(fixtureRoot, endpoint, page.FileName);
        pages.Add(new RawPage(endpoint, page.Page, await File.ReadAllTextAsync(path, cancellationToken)));
      }
    }

    return pages;
  }
}

internal sealed class LiveSaopSource(HttpClient httpClient, Uri baseUrl) : ISaopSource
{
  public async Task<IReadOnlyList<RawPage>> ReadAsync(CancellationToken cancellationToken = default)
  {
    var pages = new List<RawPage>(SaopSource.Endpoints.Length);
    foreach (var endpoint in SaopSource.Endpoints)
    {
      var requestUri = new Uri(baseUrl, $"{endpoint}?organizationId=2&page=1");
      using var response = await httpClient.GetAsync(requestUri, cancellationToken);
      response.EnsureSuccessStatusCode();
      pages.Add(new RawPage(endpoint, 1, await response.Content.ReadAsStringAsync(cancellationToken)));
    }

    return pages;
  }
}

public static class FixtureFacts
{
  public static FixtureFactCounts Count(IReadOnlyList<RawPage> pages)
  {
    static IEnumerable<XElement> DirectRows(IEnumerable<RawPage> endpointPages, string name) =>
      endpointPages.Where(page => !string.IsNullOrWhiteSpace(page.PayloadXml)).SelectMany(page =>
        XDocument.Parse(page.PayloadXml).Root!.Elements().Where(element => element.Name.LocalName == name));

    var byEndpoint = pages
      .GroupBy(page => page.Endpoint, StringComparer.Ordinal)
      .ToDictionary(group => group.Key, group => (IReadOnlyList<RawPage>)group.ToArray(), StringComparer.Ordinal);

    return new FixtureFactCounts(
      DirectRows(byEndpoint["ItemGeneralData"], "ItemGeneralData")
        .Count(row => row.Elements().Any(element => element.Name.LocalName == "ItemID" && !string.IsNullOrWhiteSpace(element.Value))),
      DirectRows(byEndpoint["Prices"], "Price").Count(),
      byEndpoint["Descriptions"]
        .Where(page => !string.IsNullOrWhiteSpace(page.PayloadXml))
        .Sum(page => XDocument.Parse(page.PayloadXml).Descendants().Count(element => element.Name.LocalName == "Description")));
  }
}

/// <summary>Bralna oblika fixtures/saop/iqlighting/manifest.json — piše jo PIM.FixtureExport.</summary>
public sealed record FixtureManifest(IReadOnlyList<FixtureManifestEndpoint> Endpoints)
{
  public static async Task<FixtureManifest> LoadAsync(string path, CancellationToken cancellationToken = default)
  {
    if (!File.Exists(path))
    {
      throw new InvalidOperationException($"Manjka fixture manifest: {path}. Poženi tools/PIM.FixtureExport.");
    }

    await using var stream = File.OpenRead(path);
    var document = await System.Text.Json.JsonSerializer.DeserializeAsync(
      stream, FixtureManifestJsonContext.Default.FixtureManifestDocument, cancellationToken);
    if (document is null)
    {
      throw new InvalidOperationException($"Manifest {path} je prazen ali neveljaven.");
    }

    return new FixtureManifest(document.Endpoints
      .Select(endpoint => new FixtureManifestEndpoint(
        endpoint.Endpoint,
        endpoint.EndpointKey,
        endpoint.RunId,
        endpoint.Pages.Select(page => new FixtureManifestPage(page.Page, page.FileName)).ToArray()))
      .ToArray());
  }
}

public sealed record FixtureManifestEndpoint(string Endpoint, string? EndpointKey, string? RunId, IReadOnlyList<FixtureManifestPage> Pages);
public sealed record FixtureManifestPage(int Page, string FileName);

public sealed class FixtureManifestDocument
{
  public string? GeneratedUtc { get; set; }
  public int? SourceOrganizationId { get; set; }
  public string? SourceOrganizationName { get; set; }
  public string? Note { get; set; }
  public List<FixtureManifestEndpointDocument> Endpoints { get; set; } = [];
}

public sealed class FixtureManifestEndpointDocument
{
  public string Endpoint { get; set; } = "";
  public string? EndpointKey { get; set; }
  public string? RunId { get; set; }
  public string? IngestedAtUtc { get; set; }
  public List<FixtureManifestPageDocument> Pages { get; set; } = [];
}

public sealed class FixtureManifestPageDocument
{
  public int Page { get; set; }
  public string FileName { get; set; } = "";
  public string? ResponseHash { get; set; }
}

[JsonSourceGenerationOptions(PropertyNameCaseInsensitive = true)]
[JsonSerializable(typeof(FixtureManifestDocument))]
internal sealed partial class FixtureManifestJsonContext : JsonSerializerContext
{
}
