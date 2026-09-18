using System.Globalization;

namespace PIM.Intranet.Services;

/// <param name="Kind">Kaj je v datoteki: izdelki ali stranke.</param>
/// <param name="RowCount">Vrstic brez glave; -1 pomeni, da datoteke ni bilo mogoce prebrati.</param>
public sealed record WebExportFile(
  string FileName, string Kind, long SizeBytes, DateTime ModifiedUtc, long RowCount);

/// <param name="Truncated">Ali je predogled odrezan; datoteka ima vec vrstic.</param>
public sealed record WebExportPreview(
  IReadOnlyList<string> Columns, IReadOnlyList<IReadOnlyList<string>> Rows, bool Truncated);

/// <summary>
/// Datoteke, ki gredo na splet, kot so na disku.
///
/// Uporabnik 2026-08-28: »Tukaj sem mislil, da bi oni dejansko CSV videli, ki ga bomo dali za
/// splet in da si ga lahko potegnejo dol«, ter »imeli bomo vec CSVjev za splet — artikli in pa
/// stranke, tako da bi mogli oba omogociti za pogled«.
///
/// Zakaj bere z diska in ne sestavi CSV znova: datoteko izdela <c>PIM.B2bWorker</c> in prav ta
/// gre na splet. Drugi izvoz v intranetu bi bil druga datoteka in bi lahko kazal drugacno
/// vsebino od tiste, ki je dejansko odsla — to je natanko tisto, cesar uporabnik ne sme videti.
///
/// Mapa se nastavi z <c>WebExport:Directory</c>. Kadar ni nastavljena ali je prazna, servis
/// vrne prazen seznam in stran to pove naravnost; izmisljene datoteke ni.
/// </summary>
public sealed class WebExportFileService(IConfiguration configuration)
{
  /// <summary>Najvec vrstic v predogledu; datoteka ima lahko 100.000 vrstic in cela ne sodi na zaslon.</summary>
  public const int PreviewRows = 50;

  /// <summary>Nastavljena mapa izvoza; null pomeni, da ni nastavljena.</summary>
  public string? Directory => Normalize(configuration["WebExport:Directory"]);

  public IReadOnlyList<WebExportFile> List()
  {
    var directory = Directory;
    if (directory is null || !System.IO.Directory.Exists(directory)) return [];

    return System.IO.Directory.EnumerateFiles(directory, "*.csv")
      .Select(path => new FileInfo(path))
      .OrderBy(file => file.Name, StringComparer.OrdinalIgnoreCase)
      .Select(file => new WebExportFile(file.Name, KindOf(file.Name), file.Length, file.LastWriteTimeUtc, CountRows(file.FullName)))
      .ToArray();
  }

  /// <summary>Prvih <see cref="PreviewRows"/> vrstic datoteke; null pomeni, da datoteke ni.</summary>
  public WebExportPreview? Preview(string fileName)
  {
    var path = Resolve(fileName);
    if (path is null) return null;

    using var reader = new StreamReader(path);
    var header = reader.ReadLine();
    if (header is null) return new([], [], false);

    var separator = DetectSeparator(header);
    var columns = Split(header, separator);
    var rows = new List<IReadOnlyList<string>>();
    string? line;
    while (rows.Count < PreviewRows && (line = reader.ReadLine()) is not null)
      rows.Add(Split(line, separator));

    return new(columns, rows, reader.ReadLine() is not null);
  }

  /// <summary>
  /// Polna pot datoteke znotraj nastavljene mape; null pomeni, da je ime neveljavno ali datoteke ni.
  ///
  /// Ime se namenoma ne sestavlja iz uporabnikovega niza: sprejeta so samo imena, ki jih je
  /// servis sam nasel v mapi. Tako pot z dvema pikama nikoli ne more postati veljavna.
  /// </summary>
  public string? Resolve(string? fileName)
  {
    var directory = Directory;
    if (directory is null || string.IsNullOrWhiteSpace(fileName)) return null;
    if (!List().Any(file => string.Equals(file.FileName, fileName, StringComparison.Ordinal))) return null;

    var path = Path.Combine(directory, fileName);
    return File.Exists(path) ? path : null;
  }

  /// <summary>Kaj je v datoteki. Merilo je ime, ki ga zapise PIM.B2bWorker.</summary>
  static string KindOf(string fileName) =>
    fileName.Contains("customer", StringComparison.OrdinalIgnoreCase) || fileName.Contains("stranke", StringComparison.OrdinalIgnoreCase)
      ? "Stranke"
      : fileName.Contains("product", StringComparison.OrdinalIgnoreCase) || fileName.Contains("izdelk", StringComparison.OrdinalIgnoreCase)
        || fileName.Contains("katalog", StringComparison.OrdinalIgnoreCase)
        ? "Izdelki"
        : "Drugo";

  static long CountRows(string path)
  {
    try
    {
      var lines = File.ReadLines(path).Count();
      return lines == 0 ? 0 : lines - 1;
    }
    catch
    {
      // Datoteka, ki jo izvoz prav zdaj pise, se ne da prebrati. To ni napaka strani.
      return -1;
    }
  }

  /// <summary>Locilo: Magento CSV uporablja vejico, SAOP izvozi podpicje.</summary>
  static char DetectSeparator(string header) =>
    header.Count(character => character == ';') > header.Count(character => character == ',') ? ';' : ',';

  /// <summary>Razdeli vrstico CSV ob upostevanju narekovajev; podvojen narekovaj je znak sam.</summary>
  static IReadOnlyList<string> Split(string line, char separator)
  {
    var values = new List<string>();
    var current = new System.Text.StringBuilder();
    var quoted = false;
    for (var index = 0; index < line.Length; index++)
    {
      var character = line[index];
      if (character == '"')
      {
        if (quoted && index + 1 < line.Length && line[index + 1] == '"') { current.Append('"'); index++; }
        else quoted = !quoted;
      }
      else if (character == separator && !quoted) { values.Add(current.ToString()); current.Clear(); }
      else current.Append(character);
    }

    values.Add(current.ToString());
    return values;
  }

  public static string Size(long bytes) => bytes switch
  {
    < 1024 => bytes.ToString(CultureInfo.InvariantCulture) + " B",
    < 1024 * 1024 => (bytes / 1024m).ToString("N0", CultureInfo.CurrentCulture) + " KB",
    _ => (bytes / 1024m / 1024m).ToString("N1", CultureInfo.CurrentCulture) + " MB",
  };

  static string? Normalize(string? value) => string.IsNullOrWhiteSpace(value) ? null : Path.GetFullPath(value.Trim());
}
