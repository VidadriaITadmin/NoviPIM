namespace PIM.Intranet.Services;

/// <summary>
/// Vrstni red jezikov v vmesniku.
///
/// Uporabnik ga je 2026-08-28 dolocil izrecno — »imena kategorij po jezikih mi daj po vrsti
/// sl, en, de, hr, it« — in isti red velja povsod, kjer se jeziki nastejejo: nazivi na kartici
/// izdelka, imena kategorij, stolpci izvoza. Abecedni red (de, en, hr, it, sl) je postavljal
/// slovenscino na konec, kar je pri slovenskem katalogu narobe.
///
/// Jezik, ki ga register vrne, pa v tem seznamu ne stoji, se ne izgubi: pripne se za znanimi,
/// po abecedi. Seznam je red, ne filter.
/// </summary>
public static class PimLanguages
{
  /// <summary>Prednostni vrstni red; kar ni na seznamu, gre za njim po abecedi.</summary>
  public static IReadOnlyList<string> Preferred { get; } = ["sl", "en", "de", "hr", "it"];

  /// <summary>Mesto jezika v prednostnem redu; neznani jezik dobi mesto za vsemi znanimi.</summary>
  public static int Rank(string? languageCode)
  {
    if (string.IsNullOrWhiteSpace(languageCode)) return Preferred.Count + 1;
    for (var index = 0; index < Preferred.Count; index++)
      if (string.Equals(Preferred[index], languageCode, StringComparison.OrdinalIgnoreCase)) return index;
    return Preferred.Count;
  }

  /// <summary>Uredi kode jezikov po prednostnem redu; enake kode se pojavijo enkrat.</summary>
  public static IReadOnlyList<string> Order(IEnumerable<string?> languageCodes) =>
    languageCodes
      .Where(code => !string.IsNullOrWhiteSpace(code))
      .Select(code => code!.Trim())
      .Distinct(StringComparer.OrdinalIgnoreCase)
      .OrderBy(Rank)
      .ThenBy(code => code, StringComparer.OrdinalIgnoreCase)
      .ToArray();

  /// <summary>Uredi poljubne vrstice po jeziku, ki ga nosi <paramref name="languageOf"/>.</summary>
  public static IOrderedEnumerable<T> OrderBy<T>(IEnumerable<T> rows, Func<T, string?> languageOf) =>
    rows.OrderBy(row => Rank(languageOf(row))).ThenBy(languageOf, StringComparer.OrdinalIgnoreCase);
}
