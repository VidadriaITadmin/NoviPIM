using PIM.Intranet.Services;

namespace PIM.Intranet.Components.Pages.IngestParts;

/// <summary>Aktivni filter kot čip: ime, ki ga uporabnik bere, in povezava brez tega filtra.</summary>
public sealed record IngestChip(string Label, string RemoveHref);

/// <summary>Stolpec tabele področja Zajem; <paramref name="SortKey"/> null pomeni, da se po njem ne razvršča.</summary>
public sealed record IngestColumn(string Label, bool Numeric = false, string? SortKey = null);

/// <summary>
/// Sestavljanje base-relativnih povezav s filtri (prenova 2026-09-26). Stanje seznamov na straneh
/// Zajema živi v URL-ju: povezava se da deliti, Nazaj v brskalniku vrne prejšnji pogled. Prazne
/// vrednosti se izpustijo, da je naslov kratek in berljiv.
/// </summary>
public static class IngestQuery
{
  public static string Build(string path, params (string Key, string? Value)[] pairs)
  {
    var parts = pairs
      .Where(pair => !string.IsNullOrWhiteSpace(pair.Value))
      .Select(pair => pair.Key + "=" + Uri.EscapeDataString(pair.Value!.Trim()))
      .ToArray();
    return parts.Length == 0 ? path : path + "?" + string.Join("&", parts);
  }

  /// <summary>Klik na stolpec: isti stolpec obrne smer, nov stolpec začne v privzeti smeri.</summary>
  public static (string Sort, string? Direction) Toggle(string? currentSort, bool currentDescending, string key, bool defaultDescending)
  {
    if (string.Equals(currentSort, key, StringComparison.Ordinal))
      return (key, currentDescending ? "nar" : "pad");
    return (key, defaultDescending ? "pad" : "nar");
  }

  /// <summary>Slovenska dvojina in množina: 1 tek, 2 teka, 3 teki, 5 tekov (101 kot 1).</summary>
  public static string Count(long count, string one, string two, string few, string many) =>
    $"{count:N0} " + ((count % 100) switch { 1 => one, 2 => two, 3 or 4 => few, _ => many });

  public static string Moment(DateTime? value) => value is null ? "—" : value.Value.ToPimLocal().ToString("d. M. yyyy HH:mm");

  public static string Duration(DateTime start, DateTime? end)
  {
    if (end is null) return "teče";
    var span = end.Value - start;
    if (span.TotalSeconds < 0) span = TimeSpan.Zero;
    return span.TotalMinutes >= 60 ? $"{(int)span.TotalHours} h {span.Minutes} min"
      : span.TotalSeconds >= 60 ? $"{(int)span.TotalMinutes} min {span.Seconds} s"
      : $"{span.TotalSeconds:N0} s";
  }
}
