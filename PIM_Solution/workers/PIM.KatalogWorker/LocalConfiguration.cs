using System.Text.Json;

namespace PIM.KatalogWorker;

public static class LocalConfiguration
{
  public static string? GetConnectionString(string environmentVariable, string localSettingName)
  {
    var environmentValue = Environment.GetEnvironmentVariable(environmentVariable);
    if (!string.IsNullOrWhiteSpace(environmentValue))
    {
      return environmentValue;
    }

    var localPath = Path.Combine(Directory.GetCurrentDirectory(), "appsettings.Local.json");
    if (!File.Exists(localPath))
    {
      return null;
    }

    using var document = JsonDocument.Parse(File.ReadAllText(localPath));
    if (!document.RootElement.TryGetProperty("ConnectionStrings", out var connectionStrings)
      || !connectionStrings.TryGetProperty(localSettingName, out var setting))
    {
      return null;
    }

    return setting.GetString();
  }
}
