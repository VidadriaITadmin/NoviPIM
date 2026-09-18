using System.Text.Json;
using PIM.Operations;

namespace PIM.SaopOrdersWorker;

/// <param name="Id">OrganizationId, isti kot v <c>dbo.OrganizationConfig</c>.</param>
/// <param name="Name">Berljivo ime, uporabljeno samo v izpisih.</param>
/// <param name="SourceCode">Koda vira; mora obstajati v <c>map.SourceConnector</c>, sicer preslikave ni.</param>
/// <param name="SalesOrderBook">
/// Šifra "knjige" naročil kupcev v SAOP (npr. "VNK"). Knjige so nastavitev posameznega podjetja, ne
/// univerzalna konstanta — organizacija brez te nastavitve (null/prazno) se pri zajemu naročil
/// kupcev preskoči, ne pade.
/// </param>
/// <param name="PurchaseOrderBook">Enako za naročila dobaviteljem (npr. "VND").</param>
public sealed record SaopOrganization(
  int Id, string Name, string SourceCode, bool IsActive = true,
  string? SalesOrderBook = null, string? PurchaseOrderBook = null);

/// <summary>
/// Nastavitve za ta delavec. Bere isto sekcijo "Saop" kot PIM.KatalogWorker (ista poverilnica,
/// isti seznam organizacij) — ni razloga za ločeno konfiguracijsko datoteko za isti SAOP dostop.
/// </summary>
public sealed record OrdersSettings
{
  public string BaseUrl { get; init; } = "";
  public string Username { get; init; } = "";
  public string Password { get; init; } = "";
  public int TimeoutSeconds { get; init; } = 120;
  public int PageSize { get; init; } = 200;
  public int MaxPagesPerCall { get; init; } = 1000;
  public bool AcceptUntrustedCertificate { get; init; } = false;

  /// <summary>Prekrivanje delta zajema, enako kot pri PIM.KatalogWorker.</summary>
  public int LookbackDays { get; init; } = 7;

  /// <summary>
  /// Privzeto okno za PRVI zajem (ko za entiteto še ni vodnega žiga): zadnjih N mesecev, ne vsa
  /// zgodovina. Za ABC/MIN-MID-MAX formulo zadostujejo cca. 12-24 mesecev prodaje/naročil.
  /// </summary>
  public int InitialBackfillMonths { get; init; } = 24;

  public int RetryMaxExtraAttempts { get; init; } = 3;
  public int RetryBaseDelayMilliseconds { get; init; } = 1000;

  public IReadOnlyList<SaopOrganization> Organizations { get; init; } = [];

  public bool HasCredentials =>
    !string.IsNullOrWhiteSpace(BaseUrl) && !string.IsNullOrWhiteSpace(Username) && !string.IsNullOrWhiteSpace(Password);
}

public static class OrdersWorkerConfiguration
{
  public static string? GetConnectionString() => LocalSettings.ConnectionString();

  public static OrdersSettings Read()
  {
    var saop = LocalSettings.Section("Saop");
    return new OrdersSettings
    {
      BaseUrl = Env("PIM_SAOP_BASE_URL") ?? String(saop, "BaseUrl") ?? "",
      Username = Env("PIM_SAOP_USERNAME") ?? String(saop, "Username") ?? "",
      Password = Env("PIM_SAOP_PASSWORD") ?? String(saop, "Password") ?? "",
      TimeoutSeconds = Int(saop, "TimeoutSeconds") ?? 120,
      AcceptUntrustedCertificate = Bool(saop, "AcceptUntrustedCertificate") ?? false,
      LookbackDays = Int(saop, "LookbackDays") ?? 7,
      RetryMaxExtraAttempts = Int(saop, "RetryMaxExtraAttempts") ?? 3,
      RetryBaseDelayMilliseconds = Int(saop, "RetryBaseDelayMilliseconds") ?? 1000,
      Organizations = ReadOrganizations(saop)
    };
  }

  private static IReadOnlyList<SaopOrganization> ReadOrganizations(JsonElement? saop)
  {
    if (saop is null || !saop.Value.TryGetProperty("Organizations", out var array) || array.ValueKind != JsonValueKind.Array)
    {
      return [];
    }

    var organizations = new List<SaopOrganization>();
    foreach (var element in array.EnumerateArray())
    {
      var id = element.TryGetProperty("Id", out var idElement) && idElement.TryGetInt32(out var parsed) ? parsed : 0;
      var sourceCode = element.TryGetProperty("SourceCode", out var codeElement) ? codeElement.GetString() : null;
      if (id <= 0 || string.IsNullOrWhiteSpace(sourceCode)) continue;

      var name = element.TryGetProperty("Name", out var nameElement) ? nameElement.GetString() ?? "" : "";
      var isActive = !element.TryGetProperty("IsActive", out var activeElement) || activeElement.ValueKind != JsonValueKind.False;
      var salesOrderBook = element.TryGetProperty("SalesOrderBook", out var salesBookElement) ? salesBookElement.GetString() : null;
      var purchaseOrderBook = element.TryGetProperty("PurchaseOrderBook", out var purchBookElement) ? purchBookElement.GetString() : null;
      organizations.Add(new SaopOrganization(id, name, sourceCode, isActive, salesOrderBook, purchaseOrderBook));
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
      ? value.GetString() : null;

  private static int? Int(JsonElement? element, string name) =>
    element is not null && element.Value.TryGetProperty(name, out var value) && value.TryGetInt32(out var parsed) ? parsed : null;

  private static bool? Bool(JsonElement? element, string name) =>
    element is not null && element.Value.TryGetProperty(name, out var value) && value.ValueKind is JsonValueKind.True or JsonValueKind.False
      ? value.GetBoolean() : null;
}
