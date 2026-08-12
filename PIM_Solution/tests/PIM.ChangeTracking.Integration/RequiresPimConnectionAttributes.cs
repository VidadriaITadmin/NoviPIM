using PIM.KatalogWorker;
using Xunit;

namespace PIM.ChangeTracking.Integration;

public sealed class RequiresPimConnectionFactAttribute : FactAttribute
{
  public RequiresPimConnectionFactAttribute() => Skip = MissingConnectionReason();

  private static string? MissingConnectionReason() =>
    string.IsNullOrWhiteSpace(LocalConfiguration.GetConnectionString("PIM_CONNECTION_STRING", "Pim"))
      ? "ChangeTracking integracija preskočena: manjka PIM_CONNECTION_STRING oziroma ConnectionStrings:Pim v appsettings.Local.json."
      : null;
}

public sealed class RequiresPimConnectionTheoryAttribute : TheoryAttribute
{
  public RequiresPimConnectionTheoryAttribute() => Skip = MissingConnectionReason();

  private static string? MissingConnectionReason() =>
    string.IsNullOrWhiteSpace(LocalConfiguration.GetConnectionString("PIM_CONNECTION_STRING", "Pim"))
      ? "ChangeTracking integracija preskočena: manjka PIM_CONNECTION_STRING oziroma ConnectionStrings:Pim v appsettings.Local.json."
      : null;
}