using System.Globalization;
using System.Text;

namespace PIM.Intranet.Services;

/// <summary>
/// Primerjava besedila, kakor jo dela clovek: brez sumnikov, velikosti crk, locil in odvecnih
/// presledkov. Uporabljajo jo izbirniki (iskanje med tipkanjem) in preverba podvajanja
/// (»Vidna dim.« in »vidna dim« sta isto ime).
/// </summary>
public static class PimText
{
  /// <summary>»Šírina paketa I« → »sirina paketa i«.</summary>
  public static string Fold(string? value)
  {
    if (string.IsNullOrWhiteSpace(value)) return "";
    var decomposed = value.Normalize(NormalizationForm.FormD);
    var builder = new StringBuilder(decomposed.Length);
    var pendingSpace = false;
    foreach (var character in decomposed)
    {
      var category = CharUnicodeInfo.GetUnicodeCategory(character);
      if (category == UnicodeCategory.NonSpacingMark) continue;
      if (char.IsLetterOrDigit(character))
      {
        if (pendingSpace && builder.Length > 0) builder.Append(' ');
        pendingSpace = false;
        builder.Append(char.ToLowerInvariant(character));
      }
      else pendingSpace = true;
    }
    return builder.ToString();
  }

  /// <summary>Vsaka beseda iskanja mora biti v besedilu; vrstni red ni pomemben.</summary>
  public static bool Matches(string? text, string? search)
  {
    var folded = Fold(text);
    var terms = Fold(search).Split(' ', StringSplitOptions.RemoveEmptyEntries);
    return terms.Length == 0 || terms.All(term => folded.Contains(term, StringComparison.Ordinal));
  }

  /// <summary>Isto ime, kakor ga vidi clovek: enako po zlozitvi (brez sumnikov, velikosti crk, locil).</summary>
  public static bool SameName(string? left, string? right) =>
    Fold(left).Length > 0 && Fold(left) == Fold(right);

  /// <summary>Podobno ime: eno vsebuje drugo (vsaj tri znake), na primer »Presek« in »Presek kabla«.</summary>
  public static bool SimilarName(string? left, string? right)
  {
    var a = Fold(left);
    var b = Fold(right);
    if (a.Length < 3 || b.Length < 3) return false;
    return a.Contains(b, StringComparison.Ordinal) || b.Contains(a, StringComparison.Ordinal);
  }
}
