namespace PIM.Intranet.Services;

// Čiščenje atributov (naloga #15). Ločeno od AttributeMappingService, da ga test preveri brez baze.

/// <param name="Name">Ime atributa, kot je shranjeno pri vrednostih izdelka.</param>
/// <param name="AttributeCode">Koda v registru; null = ime ni v registru atributov.</param>
/// <param name="ByOrganization">Število izdelkov po podjetju, npr. »IQLighting 2.176 · Vidadria 1.200«.</param>
public sealed record CleanupAttribute(
  string Name, string? AttributeCode, long Products, long DistinctValues, long InformativeValues,
  string? ByOrganization, string? Samples);

/// <param name="Kind">SAME_DATA (isti izdelki, iste vrednosti), SIMILAR_VALUES (drugi izdelki, iste
/// vrednosti), SIMILAR_NAME (skoraj isto ime).</param>
public sealed record DuplicateCandidate(
  string Kind, CleanupAttribute First, CleanupAttribute Second,
  long SharedProducts, long SameValueProducts, long CommonValues);

/// <summary>Kdaj sta dva atributa kandidata za združitev. Samo predlog; združi lastnik.</summary>
public static class AttributeDuplicatePolicy
{
  /// <summary>
  /// Pravila za kandidata (javno zaradi testa). Isti podatek: vsaj 5 skupnih izdelkov in pri vsaj 80 %
  /// ista pomenljiva vrednost. Podobne vrednosti: izdelki se skoraj ne prekrivajo (največ 20 %), skupnih
  /// vrednosti pa je vsaj 3 in vsaj polovica manjšega nabora. Podobno ime: enak ključ imena
  /// (<see cref="NameKey"/>) ali eno ime vsebuje drugo in imata vsaj eno skupno vrednost.
  /// </summary>
  public static IReadOnlyList<DuplicateCandidate> Classify(
    IReadOnlyList<CleanupAttribute> attributes,
    IReadOnlyList<(string First, string Second, long Shared, long Same, long Common)> pairs)
  {
    var byName = attributes.ToDictionary(attribute => attribute.Name, StringComparer.Ordinal);
    var stats = new Dictionary<(string, string), (long Shared, long Same, long Common)>();
    foreach (var pair in pairs) stats[Key(pair.First, pair.Second)] = (pair.Shared, pair.Same, pair.Common);

    var result = new List<DuplicateCandidate>();
    var seen = new HashSet<(string, string)>();
    foreach (var pair in pairs)
    {
      if (!byName.TryGetValue(pair.First, out var first) || !byName.TryGetValue(pair.Second, out var second)) continue;
      string? kind = null;
      if (pair.Shared >= 5 && pair.Same * 5 >= pair.Shared * 4) kind = "SAME_DATA";
      else
      {
        var smallerValues = Math.Min(first.InformativeValues, second.InformativeValues);
        var smallerProducts = Math.Min(first.Products, second.Products);
        if (pair.Common >= 3 && pair.Common * 2 >= smallerValues && pair.Shared * 5 <= smallerProducts) kind = "SIMILAR_VALUES";
      }
      if (kind is null && SimilarNames(first.Name, second.Name) && pair.Common >= 1) kind = "SIMILAR_NAME";
      if (kind is null) continue;
      seen.Add(Key(first.Name, second.Name));
      result.Add(new DuplicateCandidate(kind, first, second, pair.Shared, pair.Same, pair.Common));
    }

    // Enak ključ imena je kandidat tudi brez skupnih vrednosti (npr. »Bruto teža« in »Bruto teža (2)«).
    for (var i = 0; i < attributes.Count; i++)
      for (var j = i + 1; j < attributes.Count; j++)
      {
        var first = attributes[i];
        var second = attributes[j];
        if (seen.Contains(Key(first.Name, second.Name)) || NameKey(first.Name) != NameKey(second.Name) || NameKey(first.Name).Length == 0) continue;
        stats.TryGetValue(Key(first.Name, second.Name), out var found);
        result.Add(new DuplicateCandidate("SIMILAR_NAME", first, second, found.Shared, found.Same, found.Common));
      }

    return result
      .OrderBy(candidate => candidate.Kind switch { "SAME_DATA" => 0, "SIMILAR_VALUES" => 1, _ => 2 })
      .ThenByDescending(candidate => Math.Max(candidate.SameValueProducts, candidate.CommonValues))
      .ThenBy(candidate => candidate.First.Name, StringComparer.CurrentCulture)
      .ToList();

    static (string, string) Key(string a, string b) => string.CompareOrdinal(a, b) <= 0 ? (a, b) : (b, a);
  }

  /// <summary>Ključ imena: brez šumnikov in velikih črk, brez oklepajev (»(2)«), oznake jezika na koncu
  /// (»SLO«) in ločil. »Bruto teža (2)« in »Bruto teža« dasta isti ključ.</summary>
  public static string NameKey(string name)
  {
    var folded = PimText.Fold(System.Text.RegularExpressions.Regex.Replace(name, @"\([^)]*\)", " "));
    folded = System.Text.RegularExpressions.Regex.Replace(folded, @"\b(slo|sl|en|ang)\s*$", " ");
    return System.Text.RegularExpressions.Regex.Replace(folded, @"[^a-z0-9]+", "");
  }

  static bool SimilarNames(string first, string second)
  {
    var a = NameKey(first);
    var b = NameKey(second);
    if (a.Length < 4 || b.Length < 4) return a == b && a.Length > 0;
    return a == b || a.Contains(b, StringComparison.Ordinal) || b.Contains(a, StringComparison.Ordinal);
  }
}
