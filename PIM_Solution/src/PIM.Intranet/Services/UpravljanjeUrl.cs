namespace PIM.Intranet.Services;

/// <summary>
/// Base-relativne povezave s poizvedbo za strani področja Upravljanje (prenova 2026-09-26).
/// Filtri teh strani živijo v URL-ju: povezava se da deliti, Nazaj v brskalniku vrne prejšnji
/// pogled. Prazne vrednosti se izpustijo, da je naslov kratek in berljiv.
/// </summary>
public static class UpravljanjeUrl
{
  /// <summary><c>Href("pravila/slovar", ("domena", "Barva"), ("stran", null))</c> → <c>pravila/slovar?domena=Barva</c>.</summary>
  public static string Href(string path, params (string Key, string? Value)[] query)
  {
    var parts = query
      .Where(pair => !string.IsNullOrWhiteSpace(pair.Value))
      .Select(pair => Uri.EscapeDataString(pair.Key) + "=" + Uri.EscapeDataString(pair.Value!.Trim()))
      .ToArray();
    return parts.Length == 0 ? path : path + "?" + string.Join("&", parts);
  }

  /// <summary>»1«, »da«, »true« → true; vse drugo false.</summary>
  public static bool Flag(string? value) =>
    value is not null && (value == "1" || value.Equals("da", StringComparison.OrdinalIgnoreCase) || value.Equals("true", StringComparison.OrdinalIgnoreCase));

  /// <summary>Številka strani iz URL-ja (1 = prva) v zamik vrstic.</summary>
  public static int Skip(int? page, int take) => page is > 1 ? (page.Value - 1) * take : 0;

  /// <summary>Zamik vrstic v številko strani za URL; prva stran se ne piše.</summary>
  public static string? Page(int skip, int take) => skip <= 0 ? null : (skip / take + 1).ToString(System.Globalization.CultureInfo.InvariantCulture);
}
