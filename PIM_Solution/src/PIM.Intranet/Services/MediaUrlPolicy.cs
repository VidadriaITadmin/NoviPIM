using System.Globalization;

namespace PIM.Intranet.Services;

public sealed record MediaUrl(string? Href, string Display, string? Note);

/// <summary>Enotna varnostna in prikazna politika za naslove medijev iz zunanjih virov.</summary>
public static class MediaUrlPolicy
{
  public const string AddedHttpsNote = "Dodan https:";
  public const string InsecureNote = "Nešifrirana povezava";
  public const string UnsafeNote = "Naslov ni varna spletna povezava";

  public static MediaUrl Normalize(string? raw)
  {
    var value = TrimEdges(raw);
    if (value.Length == 0) return new(null, "—", "Naslov ni zapisan");

    string? note = null;
    if (value.StartsWith("//", StringComparison.Ordinal))
    {
      value = "https:" + value;
      note = AddedHttpsNote;
    }
    else if (value.StartsWith("www.", StringComparison.OrdinalIgnoreCase))
    {
      value = "https://" + value;
      note = AddedHttpsNote;
    }

    if (!Uri.TryCreate(value, UriKind.Absolute, out var parsed)
        || !(parsed.Scheme.Equals(Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase)
             || parsed.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase)))
      return new(null, value, UnsafeNote);

    if (parsed.Scheme.Equals(Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase))
      note = InsecureNote;

    return new(parsed.AbsoluteUri, parsed.AbsoluteUri, note);
  }

  static string TrimEdges(string? raw)
  {
    if (string.IsNullOrEmpty(raw)) return string.Empty;
    var start = 0;
    var end = raw.Length - 1;
    while (start <= end && IsEdgeNoise(raw[start])) start++;
    while (end >= start && IsEdgeNoise(raw[end])) end--;
    return start > end ? string.Empty : raw[start..(end + 1)];
  }

  static bool IsEdgeNoise(char value)
  {
    var category = char.GetUnicodeCategory(value);
    return char.IsWhiteSpace(value) || category is UnicodeCategory.Control or UnicodeCategory.Format;
  }
}
