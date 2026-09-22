using System.Text;

namespace PIM.Intranet.Services;

/// <summary>
/// Enotna razvrstitev medija v sliko, video, dokument ali drugo.
///
/// Zakaj obstaja: <c>canon.ProductMedia</c> nima stolpca z vrsto — ima samo naslov in vlogo.
/// Stran je zato dolgo prikazovala vse kot sliko in video ter dokument sta bila nevidna.
/// Vrsta se izpelje iz koncnice, gostitelja in vloge; ista pravila potrebuje tudi baza,
/// ker se po vrsti filtrira in steje. Da se izpis in filter ne bi razsla, SQL izraz
/// <see cref="SqlKindExpression"/> nastane iz istih seznamov kot <see cref="Classify"/>.
/// </summary>
public static class MediaKindPolicy
{
  public const string ImageCode = "SLIKA";
  public const string VideoCode = "VIDEO";
  public const string DocumentCode = "DOKUMENT";
  public const string OtherCode = "DRUGO";

  static readonly string[] ImageExtensions = [".jpg", ".jpeg", ".png", ".gif", ".webp", ".avif", ".bmp", ".svg", ".tif", ".tiff"];
  static readonly string[] VideoExtensions = [".mp4", ".webm", ".mov", ".m4v", ".avi", ".mkv", ".ogv", ".wmv"];
  // Poleg pisarniskih datotek so tu tudi tehnicne priloge, ki jih dobavitelji dejansko posiljajo:
  // 3D in DIALux datoteke v arhivih ter CAD/svetlobni formati. Brez njih so padle v DRUGO.
  static readonly string[] DocumentExtensions =
    [".pdf", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx", ".csv", ".txt", ".rtf",
     ".zip", ".rar", ".7z", ".dwg", ".dxf", ".ies", ".ldt", ".stp", ".step", ".3ds", ".skp"];

  static readonly string[] VideoHosts = ["youtube.com", "youtu.be", "vimeo.com", "dailymotion.com"];

  static readonly string[] VideoRoleHints = ["VIDEO", "POSNET", "FILM", "YOUTUBE"];
  static readonly string[] DocumentRoleHints =
    ["DOKUMENT", "DOC", "PDF", "NAVODIL", "MANUAL", "IZJAV", "CERT", "DATASHEET", "PODATKOVN",
     "SPECIFIKAC", "VARNOSTN", "KATALOG", "GARANC", "SHEMA", "RISB", "DIALUX", "3D", "ENERG"];
  static readonly string[] ImageRoleHints = ["SLIKA", "IMAGE", "FOTO", "PHOTO", "MAIN", "GLAV", "PRIMARY", "GALER", "GALLERY", "THUMB"];

  /// <summary>Vrne eno od <see cref="ImageCode"/>, <see cref="VideoCode"/>, <see cref="DocumentCode"/>, <see cref="OtherCode"/>.</summary>
  public static string Classify(string? url, string? role)
  {
    var extension = Extension(url);
    if (extension.Length > 0)
    {
      if (Contains(ImageExtensions, extension)) return ImageCode;
      if (Contains(VideoExtensions, extension)) return VideoCode;
      if (Contains(DocumentExtensions, extension)) return DocumentCode;
    }

    var lowered = (url ?? string.Empty).ToLowerInvariant();
    foreach (var host in VideoHosts)
      if (lowered.Contains(host, StringComparison.Ordinal)) return VideoCode;

    var upperRole = (role ?? string.Empty).ToUpperInvariant();
    if (upperRole.Length > 0)
    {
      foreach (var hint in VideoRoleHints) if (upperRole.Contains(hint, StringComparison.Ordinal)) return VideoCode;
      foreach (var hint in DocumentRoleHints) if (upperRole.Contains(hint, StringComparison.Ordinal)) return DocumentCode;
      foreach (var hint in ImageRoleHints) if (upperRole.Contains(hint, StringComparison.Ordinal)) return ImageCode;
    }

    return OtherCode;
  }

  public static string Label(string? kind) => kind switch
  {
    ImageCode => "Slike",
    VideoCode => "Videi",
    DocumentCode => "Dokumenti",
    OtherCode => "Drugo",
    _ => "Vse"
  };

  /// <summary>Koncnica z piko in v malih crkah, brez poizvedbenega niza in sidra. Prazna, kadar je ni.</summary>
  public static string Extension(string? url)
  {
    var path = PathPart(url);
    var dot = path.LastIndexOf('.');
    if (dot < 0 || dot == path.Length - 1) return string.Empty;
    var extension = path[dot..].ToLowerInvariant();
    foreach (var character in extension.AsSpan(1))
      if (!char.IsLetterOrDigit(character)) return string.Empty;
    return extension;
  }

  /// <summary>Zadnji del poti — berljiva oznaka ploscice, kadar naslov ne gre cez.</summary>
  public static string FileName(string? url)
  {
    var path = PathPart(url);
    var slash = path.LastIndexOf('/');
    var name = slash < 0 ? path : path[(slash + 1)..];
    return name.Length == 0 ? (url ?? string.Empty) : name;
  }

  /// <summary>
  /// Ali zna brskalnik ta naslov pokazati kar v strani, brez prenosa v nov zavihek.
  ///
  /// Danes je to samo PDF: brskalnik ima svoj pregledovalnik in izrise prvo stran. Za .rar,
  /// .dwg ali .ldt tega ne zna nihce, zato tam ostane povezava. Odlocitev je namerno ozka —
  /// vgrajen predogled je odvisen od tujega streznika (glava X-Frame-Options ga sme zavrniti),
  /// zato mora biti povezava do izvirnika vedno se vedno vidna kot zasilni izhod.
  /// </summary>
  public static bool IsInlineViewable(string? url) => Extension(url) == ".pdf";

  /// <summary>Naslov s pripisom, ki skrije orodno vrstico bralnika in stran umeri na sirino okna.</summary>
  public static string InlineViewerHref(string href) => href + "#toolbar=0&navpanes=0&view=FitH";

  /// <summary>Slika predogleda za video, kadar jo je mogoce izpeljati iz naslova (YouTube).</summary>
  public static string? VideoPoster(string? url)
  {
    var id = YouTubeId(url);
    return id is null ? null : $"https://i.ytimg.com/vi/{id}/hqdefault.jpg";
  }

  public static string? YouTubeId(string? url)
  {
    if (string.IsNullOrWhiteSpace(url)) return null;
    if (!Uri.TryCreate(MediaUrlPolicy.Normalize(url).Href ?? url, UriKind.Absolute, out var parsed)) return null;
    var host = parsed.Host.ToLowerInvariant();

    if (host.EndsWith("youtu.be", StringComparison.Ordinal))
      return Sanitize(parsed.AbsolutePath.Trim('/'));

    if (!host.EndsWith("youtube.com", StringComparison.Ordinal)) return null;

    foreach (var pair in parsed.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries))
      if (pair.StartsWith("v=", StringComparison.OrdinalIgnoreCase)) return Sanitize(pair[2..]);

    var path = parsed.AbsolutePath.Trim('/');
    foreach (var prefix in new[] { "embed/", "shorts/", "v/" })
      if (path.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) return Sanitize(path[prefix.Length..]);

    return null;
  }

  /// <summary>
  /// Isti razvrscevalnik, izpisan kot SQL <c>CASE</c>. Nastane iz zgornjih seznamov, zato
  /// dodana koncnica velja hkrati za ploscico in za filter. V izrazu ni nobene uporabnikove
  /// vrednosti — samo imeni stolpcev, ki ju poda klicatelj, in nase konstante.
  /// </summary>
  /// <remarks>
  /// Primerjave tecejo v binarni kolaciji. Izraz ima vec kot sto <c>LIKE '%…'</c> na vrstico;
  /// v slovenski kolaciji je to pri ~48.000 medijih pomenilo ~3 s na branje strani (merjeno
  /// 2026-09-22), binarno ~0,3 s. Pomen se ne spremeni: naslov je ze v malih, vloga v velikih
  /// crkah, <see cref="Classify"/> pa primerja ordinalno — binarno je temu celo blize.
  /// </remarks>
  public static string SqlKindExpression(string urlColumn, string roleColumn)
  {
    var url = $"LOWER({urlColumn}) COLLATE Latin1_General_BIN2";
    var role = $"UPPER({roleColumn}) COLLATE Latin1_General_BIN2";
    var builder = new StringBuilder("CASE");
    Branch(builder, ExtensionTest(url, ImageExtensions), ImageCode);
    Branch(builder, ExtensionTest(url, VideoExtensions), VideoCode);
    Branch(builder, ExtensionTest(url, DocumentExtensions), DocumentCode);
    Branch(builder, ContainsTest(url, VideoHosts), VideoCode);
    Branch(builder, ContainsTest(role, VideoRoleHints), VideoCode);
    Branch(builder, ContainsTest(role, DocumentRoleHints), DocumentCode);
    Branch(builder, ContainsTest(role, ImageRoleHints), ImageCode);
    builder.Append(" ELSE N'").Append(OtherCode).Append("' END");
    return builder.ToString();
  }

  static void Branch(StringBuilder builder, string test, string code) =>
    builder.Append(" WHEN ").Append(test).Append(" THEN N'").Append(code).Append('\'');

  static string ExtensionTest(string column, IReadOnlyList<string> extensions) =>
    string.Join(" OR ", extensions.SelectMany(extension => new[]
    {
      $"{column} LIKE N'%{extension}'",
      $"{column} LIKE N'%{extension}?%'",
      $"{column} LIKE N'%{extension}#%'"
    }));

  static string ContainsTest(string column, IReadOnlyList<string> needles) =>
    string.Join(" OR ", needles.Select(needle => $"{column} LIKE N'%{needle}%'"));

  static string PathPart(string? url)
  {
    var value = (url ?? string.Empty).Trim();
    var cut = value.IndexOfAny(['?', '#']);
    return cut < 0 ? value : value[..cut];
  }

  static bool Contains(IReadOnlyList<string> values, string candidate)
  {
    foreach (var value in values) if (value == candidate) return true;
    return false;
  }

  static string? Sanitize(string? id)
  {
    if (string.IsNullOrWhiteSpace(id)) return null;
    foreach (var character in id)
      if (!char.IsLetterOrDigit(character) && character != '-' && character != '_') return null;
    return id.Length is >= 6 and <= 24 ? id : null;
  }
}
