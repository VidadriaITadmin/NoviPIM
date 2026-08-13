namespace PIM.Intranet.Services;

public static class ConnectionStringResolver
{
  public static string? Resolve(IConfiguration configuration)
  {
    var environmentValue = Environment.GetEnvironmentVariable("PIM_CONNECTION_STRING");
    return !string.IsNullOrWhiteSpace(environmentValue) ? environmentValue : configuration.GetConnectionString("Pim");
  }
}
