namespace PIM.Intranet.Services;

public static class LocalSettingsLocator
{
  public const string FileName = "appsettings.Local.json";

  // Depth-independent: works from repo root, project folder, or a `dotnet publish` output. Returns null off-repo.
  public static string? FindRepositoryRootLocalSettingsPath(string startDirectory)
  {
    for (var directory = new DirectoryInfo(startDirectory); directory is not null; directory = directory.Parent)
    {
      if (File.Exists(Path.Combine(directory.FullName, "PIM_Solution", "PIM.sln")))
        return Path.Combine(directory.FullName, FileName);
    }

    return null;
  }
}
