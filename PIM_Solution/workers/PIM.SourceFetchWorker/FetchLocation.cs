using System.Text.Json;

namespace PIM.SourceFetchWorker;

/// <param name="OrganizationId">Null pomeni, da je prevzem skupen vsem podjetjem — ista datoteka.</param>
/// <param name="Kind">HTTP, FTP ali MAPA.</param>
/// <param name="Location">Naslov ali pot; pri HTTP/FTP je lahko prazen, kadar je cel naslov skrivnost.</param>
/// <param name="CredentialKey">Kljuc v appsettings.Local.json, na primer <c>Fetch:BT_STOCK</c>.</param>
/// <param name="FileNamePattern">Ime ciljne datoteke ali vzorec za mapo.</param>
public sealed record FetchLocation(
  int SourceFetchLocationId, int? OrganizationId, string SourceCode, string Kind,
  string? Location, string? CredentialKey, string? FileNamePattern, string? Note);

/// <summary>Kaj je bilo za en vir dejansko prevzeto.</summary>
public sealed record FetchOutcome(string SourceCode, string Kind, bool Fetched, long Bytes, string? TargetPath, string? Skipped, string? Error);

/// <summary>Poverilnice enega vira, prebrane iz <c>Fetch</c> v <c>appsettings.Local.json</c>.</summary>
public sealed record FetchCredential(string? Url, string? BaseUri, string? UserName, string? Password, string? RemoteDirectory, string? RemoteFileName, bool UsePassive)
{
  /// <summary>
  /// Vrednost je lahko gol niz (cel naslov je skrivnost, kot pri Braytronu z GUID-om) ali objekt
  /// s poverilnicami (FTP pri Nowodvorskem). Oboje je legitimno; oblika je odvisna od vira, ne
  /// od nase izbire, zato jo tu preberemo brez ugibanja.
  /// </summary>
  public static FetchCredential? Read(JsonElement fetch, string credentialKey)
  {
    var name = credentialKey.StartsWith("Fetch:", StringComparison.OrdinalIgnoreCase)
      ? credentialKey["Fetch:".Length..]
      : credentialKey;

    if (!fetch.TryGetProperty(name, out var value)) return null;

    if (value.ValueKind == JsonValueKind.String)
    {
      var url = value.GetString();
      return string.IsNullOrWhiteSpace(url) ? null : new(url, null, null, null, null, null, true);
    }

    if (value.ValueKind != JsonValueKind.Object) return null;

    return new(
      Text(value, "Url"), Text(value, "BaseUri"), Text(value, "UserName"), Text(value, "Password"),
      Text(value, "RemoteDirectory"), Text(value, "RemoteFileName"),
      !value.TryGetProperty("UsePassive", out var passive) || passive.ValueKind != JsonValueKind.False);
  }

  static string? Text(JsonElement element, string name) =>
    element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
      ? value.GetString()
      : null;
}
