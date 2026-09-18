using System.Text.Json;
using PIM.Operations;

namespace PIM.KatalogWorker;

/// <param name="Id">OrganizationId, isti kot v <c>dbo.OrganizationConfig</c>.</param>
/// <param name="Name">Berljivo ime, uporabljeno samo v izpisih.</param>
/// <param name="SourceCode">Koda vira; mora obstajati v <c>map.SourceConnector</c>, sicer preslikave ni.</param>
public sealed record SaopOrganization(int Id, string Name, string SourceCode, bool IsActive = true);

/// <summary>Nastavitve živega SAOP zajema. Poverilnice pridejo iz lokalne konfiguracije ali okolja — nikoli iz kode.</summary>
public sealed record SaopSettings
{
  public string BaseUrl { get; init; } = "";
  public string Username { get; init; } = "";
  public string Password { get; init; } = "";
  public int TimeoutSeconds { get; init; } = 120;
  public int PageSize { get; init; } = 1000;
  public int MaxPagesPerEndpoint { get; init; } = 1000;
  public bool IncludeNonActiveItems { get; init; } = true;

  /// <summary>
  /// Privzeto izklopljeno (varne TLS nastavitve). Za razvojno okolje s samo-podpisanim certifikatom
  /// nastavi AcceptUntrustedCertificate: true v lokalni konfiguraciji — nikoli v produkciji.
  /// </summary>
  public bool AcceptUntrustedCertificate { get; init; } = false;

  /// <summary>Prekrivanje delta zajema: bere se od (mejnik − LookbackDays), da se pozno prispele vrstice ne izgubijo.</summary>
  public int LookbackDays { get; init; } = 7;

  /// <summary>Premor po uspešnem odgovoru (ms), da zajem ne obremeni ERP. 0 = brez premora.</summary>
  public int DelayAfterSuccessMilliseconds { get; init; }

  public int RetryMaxExtraAttempts { get; init; } = 3;
  public int RetryBaseDelayMilliseconds { get; init; } = 1000;

  /// <summary>Ceniki za GetPrices. Prazno = worker jih poizve v živo prek api/pricelists.</summary>
  public IReadOnlyList<string> PriceListIds { get; init; } = [];

  public IReadOnlyList<SaopOrganization> Organizations { get; init; } = [];

  public bool HasCredentials =>
    !string.IsNullOrWhiteSpace(BaseUrl)
    && !string.IsNullOrWhiteSpace(Username)
    && !string.IsNullOrWhiteSpace(Password);
}

public static class SaopWorkerConfiguration
{
  /// <summary>Povezava na bazo; iskanje datoteke je skupno celi rešitvi.</summary>
  public static string? GetConnectionString() => LocalSettings.ConnectionString();

  public static SaopSettings Read()
  {
    var saop = LocalSettings.Section("Saop");
    var organizations = ReadOrganizations(saop);

    return new SaopSettings
    {
      BaseUrl = Env("PIM_SAOP_BASE_URL") ?? String(saop, "BaseUrl") ?? "",
      Username = Env("PIM_SAOP_USERNAME") ?? String(saop, "Username") ?? "",
      Password = Env("PIM_SAOP_PASSWORD") ?? String(saop, "Password") ?? "",
      TimeoutSeconds = Int(saop, "TimeoutSeconds") ?? 120,
      PageSize = Int(saop, "PageSize") ?? 1000,
      MaxPagesPerEndpoint = Int(saop, "MaxPagesPerEndpoint") ?? 1000,
      IncludeNonActiveItems = Bool(saop, "IncludeNonActiveItems") ?? true,
      AcceptUntrustedCertificate = Bool(saop, "AcceptUntrustedCertificate") ?? false,
      LookbackDays = Int(saop, "LookbackDays") ?? 7,
      DelayAfterSuccessMilliseconds = Int(saop, "DelayAfterSuccessMilliseconds") ?? 0,
      RetryMaxExtraAttempts = Int(saop, "RetryMaxExtraAttempts") ?? 3,
      RetryBaseDelayMilliseconds = Int(saop, "RetryBaseDelayMilliseconds") ?? 1000,
      PriceListIds = StringArray(saop, "PriceListIds"),
      Organizations = organizations
    };
  }

  private static IReadOnlyList<SaopOrganization> ReadOrganizations(JsonElement? saop)
  {
    if (saop is null
      || !saop.Value.TryGetProperty("Organizations", out var array)
      || array.ValueKind != JsonValueKind.Array)
    {
      return [];
    }

    var organizations = new List<SaopOrganization>();
    foreach (var element in array.EnumerateArray())
    {
      var id = element.TryGetProperty("Id", out var idElement) && idElement.TryGetInt32(out var parsed) ? parsed : 0;
      var sourceCode = element.TryGetProperty("SourceCode", out var codeElement) ? codeElement.GetString() : null;
      if (id <= 0 || string.IsNullOrWhiteSpace(sourceCode))
      {
        continue;
      }

      var name = element.TryGetProperty("Name", out var nameElement) ? nameElement.GetString() ?? "" : "";
      var isActive = !element.TryGetProperty("IsActive", out var activeElement)
        || activeElement.ValueKind != JsonValueKind.False;
      organizations.Add(new SaopOrganization(id, name, sourceCode, isActive));
    }

    return organizations;
  }

  private static string? Env(string name)
  {
    var value = Environment.GetEnvironmentVariable(name);
    return string.IsNullOrWhiteSpace(value) ? null : value;
  }

  private static string? String(JsonElement? element, string name) =>
    element is not null && element.Value.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
      ? value.GetString()
      : null;

  private static int? Int(JsonElement? element, string name) =>
    element is not null && element.Value.TryGetProperty(name, out var value) && value.TryGetInt32(out var parsed)
      ? parsed
      : null;

  private static bool? Bool(JsonElement? element, string name) =>
    element is not null && element.Value.TryGetProperty(name, out var value)
      && value.ValueKind is JsonValueKind.True or JsonValueKind.False
        ? value.GetBoolean()
        : null;

  private static IReadOnlyList<string> StringArray(JsonElement? element, string name)
  {
    if (element is null
      || !element.Value.TryGetProperty(name, out var array)
      || array.ValueKind != JsonValueKind.Array)
    {
      return [];
    }

    return array.EnumerateArray()
      .Where(item => item.ValueKind == JsonValueKind.String)
      .Select(item => item.GetString()!)
      .Where(value => !string.IsNullOrWhiteSpace(value))
      .ToArray();
  }
}
