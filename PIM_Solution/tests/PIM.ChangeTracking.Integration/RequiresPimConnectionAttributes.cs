using PIM.KatalogWorker;
using Xunit;
using PIM.Operations;

namespace PIM.ChangeTracking.Integration;

public sealed class RequiresPimConnectionFactAttribute : FactAttribute
{
  public RequiresPimConnectionFactAttribute() => Skip = MissingConnectionReason();

  private static string? MissingConnectionReason() =>
    string.IsNullOrWhiteSpace(LocalSettings.ConnectionString())
      ? "ChangeTracking integracija preskočena: " + LocalSettings.MissingConnectionMessage()
      : null;
}

public sealed class RequiresPimConnectionTheoryAttribute : TheoryAttribute
{
  public RequiresPimConnectionTheoryAttribute() => Skip = MissingConnectionReason();

  private static string? MissingConnectionReason() =>
    string.IsNullOrWhiteSpace(LocalSettings.ConnectionString())
      ? "ChangeTracking integracija preskočena: " + LocalSettings.MissingConnectionMessage()
      : null;
}