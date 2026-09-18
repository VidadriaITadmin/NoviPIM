using PIM.Operations;

namespace PIM.Intranet.Services;

/// <summary>
/// Povezava na bazo PIM za intranet. Ime spremenljivke in pravilo »okolje pred datoteko« sta
/// skupna celi rešitvi (<see cref="LocalSettings"/>); tu se razrešuje samo iz že sestavljene
/// konfiguracije, ker jo intranet ima, workerji pa ne.
///
/// Prazen niz šteje kot »ni nastavljena«: <c>appsettings.Production.json</c> ima
/// <c>"Pim": ""</c> kot mesto za izpolniti, prazna povezava pa mora pasti z razumljivim
/// sporočilom in ne šele v gonilniku SQL.
/// </summary>
public static class ConnectionStringResolver
{
  public static string? Resolve(IConfiguration configuration)
  {
    var environmentValue = Environment.GetEnvironmentVariable(LocalSettings.ConnectionVariable);
    if (!string.IsNullOrWhiteSpace(environmentValue))
      return environmentValue;

    var configured = configuration.GetConnectionString("Pim");
    return string.IsNullOrWhiteSpace(configured) ? null : configured;
  }
}
