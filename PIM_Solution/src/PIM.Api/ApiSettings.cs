using System.Net;

namespace PIM.Api;

/// <summary>
/// Nastavitve API-ja. Povezava do baze po prednosti: okoljska spremenljivka PIM_API_CONNECTION_STRING,
/// appsettings.Local.json ob PIM.Api.exe (ConnectionStrings:PimApi), appsettings.json. Na razvojnem
/// računalniku še PIM_CONNECTION_STRING (ista kot za ostala orodja), da ni treba nove datoteke.
///
/// Povezava mora biti z uporabnikom v vlogi pim_api_reader (migracija 287), ne z intranetovim: API je
/// odprt navzven in sme samo brati.
/// </summary>
public sealed class ApiSettings
{
  public const string ConnectionVariable = "PIM_API_CONNECTION_STRING";
  public const string AdminConnectionVariable = "PIM_API_ADMIN_CONNECTION_STRING";

  public required string ConnectionString { get; init; }
  public IReadOnlyList<IPNetwork> AllowedNetworks { get; init; } = [];
  public int RequestLogDays { get; init; } = 90;
  public int AuthCacheSeconds { get; init; } = 60;
  public int CommandTimeoutSeconds { get; init; } = 60;
  public string? PublicBaseUrl { get; init; }

  public static void AddLocalFiles(ConfigurationManager configuration, string contentRoot)
  {
    foreach (var directory in new[] { contentRoot, AppContext.BaseDirectory }.Distinct(StringComparer.OrdinalIgnoreCase))
      configuration.AddJsonFile(Path.Combine(directory, "appsettings.Local.json"), optional: true, reloadOnChange: false);
    configuration.AddEnvironmentVariables();
  }

  public static string? ResolveConnectionString(IConfiguration configuration) =>
    NullIfEmpty(Environment.GetEnvironmentVariable(ConnectionVariable))
    ?? NullIfEmpty(configuration.GetConnectionString("PimApi"))
    ?? NullIfEmpty(Environment.GetEnvironmentVariable("PIM_CONNECTION_STRING"));

  public static ApiSettings Load(IConfiguration configuration)
  {
    var connection = ResolveConnectionString(configuration)
      ?? throw new InvalidOperationException(
        $"Manjka povezava do baze: nastavi ConnectionStrings:PimApi v appsettings.Local.json ob PIM.Api.exe ali okoljsko spremenljivko {ConnectionVariable}.");

    var networks = new List<IPNetwork>();
    foreach (var entry in configuration.GetSection("Api:AllowedRemoteIps").Get<string[]>() ?? [])
    {
      var text = entry.Trim();
      if (text.Length == 0) continue;
      if (!text.Contains('/')) text += IPAddress.TryParse(text, out var address) && address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetworkV6 ? "/128" : "/32";
      networks.Add(IPNetwork.Parse(text));
    }

    return new ApiSettings
    {
      ConnectionString = connection,
      AllowedNetworks = networks,
      RequestLogDays = configuration.GetValue("Api:RequestLogDays", 90),
      AuthCacheSeconds = Math.Clamp(configuration.GetValue("Api:AuthCacheSeconds", 60), 0, 600),
      CommandTimeoutSeconds = Math.Clamp(configuration.GetValue("Api:CommandTimeoutSeconds", 60), 5, 600),
      PublicBaseUrl = NullIfEmpty(configuration["Api:PublicBaseUrl"])?.TrimEnd('/'),
    };
  }

  public bool IsAllowed(IPAddress? remote)
  {
    if (AllowedNetworks.Count == 0) return true;
    if (remote is null) return false;
    if (remote.IsIPv4MappedToIPv6) remote = remote.MapToIPv4();
    return IPAddress.IsLoopback(remote) || AllowedNetworks.Any(network => network.Contains(remote));
  }

  static string? NullIfEmpty(string? value) => string.IsNullOrWhiteSpace(value) ? null : value;
}
