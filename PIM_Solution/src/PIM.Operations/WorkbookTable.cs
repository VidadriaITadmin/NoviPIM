using System.Globalization;
using System.IO.Compression;
using System.Text.RegularExpressions;
using System.Xml.Linq;

namespace PIM.Operations;

/// <param name="Headers">Naslovi stolpcev v vrstnem redu, kot so v zvezku.</param>
/// <param name="Rows">Vrstice; vsaka ima toliko celic, kolikor je naslovov.</param>
public sealed record WorkbookSheet(string Name, IReadOnlyList<string> Headers, IReadOnlyList<IReadOnlyList<string>> Rows);

public sealed class WorkbookReadException(string message) : InvalidOperationException(message);

/// <summary>
/// Delovni zvezek (.xlsx) prebran kot tabela: naslovi stolpcev in vrstice celic.
///
/// Zakaj brez knjižnice: zvezek je stisnjena mapa datotek XML, branje pa potrebuje natanko dve
/// stvari — deljene nize in celice lista. Za to ni razloga dodajati odvisnosti, ki bi jo bilo
/// treba vzdrževati in nadgrajevati.
///
/// Kako se razlikuje od <c>PIM.XmlFileWorker.WorkbookReader</c>: tisti pretvori zvezek v XML,
/// da gre skozi obstoječo pot za dobaviteljev XML, in zato zahteva točno določen naslovni
/// stolpec. Ta bere poljubno tabelo, ki jo uporabnik prinese, in ne ve, kaj stolpci pomenijo —
/// pomen jim da uvoz.
///
/// Kar zna in je pomembno: prazne celice v sredini vrstice (Excel jih izpusti in jih je treba
/// razbrati iz sklica celice), deljene nize, in datoteko, ki jo ima nekdo odprto v Excelu.
/// </summary>
public static class WorkbookTable
{
  const string Ns = "http://schemas.openxmlformats.org/spreadsheetml/2006/main";
  const string RelNs = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";

  /// <summary>Največ vrstic na list; varovalka pred zvezkom, ki bi pojedel ves pomnilnik.</summary>
  public const int MaxRows = 50_000;

  public static WorkbookSheet Read(Stream stream, string? sheetName = null)
  {
    ArgumentNullException.ThrowIfNull(stream);
    using var archive = new ZipArchive(stream, ZipArchiveMode.Read, leaveOpen: true);
    var shared = ReadSharedStrings(archive);
    var sheets = ReadSheetIndex(archive);
    if (sheets.Count == 0) throw new WorkbookReadException("Zvezek nima nobenega lista.");

    var (name, part) = sheetName is null
      ? sheets[0]
      : sheets.FirstOrDefault(sheet => string.Equals(sheet.Name, sheetName, StringComparison.OrdinalIgnoreCase));
    if (part is null) throw new WorkbookReadException($"Lista '{sheetName}' ni v zvezku.");

    var rows = ReadRows(archive, part, shared);
    var headerIndex = rows.FindIndex(row => row.Count(cell => !string.IsNullOrWhiteSpace(cell)) >= 2);
    if (headerIndex < 0) throw new WorkbookReadException("Na listu ni vrstice z naslovi stolpcev.");

    var headers = rows[headerIndex].Select(cell => cell.Trim()).ToArray();
    var width = headers.Length;
    var data = new List<IReadOnlyList<string>>();

    for (var index = headerIndex + 1; index < rows.Count; index++)
    {
      var row = rows[index];
      if (row.All(string.IsNullOrWhiteSpace)) continue;
      // Vrstica je lahko krajša ali daljša od naslovov; poravna se na širino naslovov, da
      // uvoz nikoli ne bere stolpca, ki ga ni.
      var cells = new string[width];
      for (var column = 0; column < width; column++) cells[column] = column < row.Count ? row[column].Trim() : string.Empty;
      data.Add(cells);
    }

    return new(name ?? "list1", headers, data);
  }

  public static WorkbookSheet Read(string path, string? sheetName = null)
  {
    // Zvezek je lahko odprt v Excelu; brez tega načina bi uvoz padel zaradi datoteke, ki jo
    // nekdo ravno gleda.
    using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
    return Read(stream, sheetName);
  }

  static List<string> ReadSharedStrings(ZipArchive archive)
  {
    var entry = archive.GetEntry("xl/sharedStrings.xml");
    if (entry is null) return [];
    using var stream = entry.Open();
    var root = XDocument.Load(stream).Root;
    return root is null
      ? []
      : root.Elements(XName.Get("si", Ns))
          .Select(item => string.Concat(item.Descendants(XName.Get("t", Ns)).Select(text => text.Value)))
          .ToList();
  }

  static List<(string? Name, string? Part)> ReadSheetIndex(ZipArchive archive)
  {
    var workbook = archive.GetEntry("xl/workbook.xml");
    var relations = archive.GetEntry("xl/_rels/workbook.xml.rels");
    if (workbook is null || relations is null) throw new WorkbookReadException("Datoteka ni delovni zvezek Excel.");

    Dictionary<string, string> targets;
    using (var stream = relations.Open())
      targets = XDocument.Load(stream).Root!.Elements()
        .ToDictionary(element => element.Attribute("Id")!.Value, element => element.Attribute("Target")!.Value);

    using var workbookStream = workbook.Open();
    return XDocument.Load(workbookStream).Root!
      .Element(XName.Get("sheets", Ns))!
      .Elements(XName.Get("sheet", Ns))
      .Select(sheet =>
      {
        var id = sheet.Attribute(XName.Get("id", RelNs))?.Value;
        var target = id is not null && targets.TryGetValue(id, out var value) ? value : null;
        return ((string?)sheet.Attribute("name")?.Value, target is null ? null : "xl/" + target.TrimStart('/').Replace("xl/", string.Empty));
      })
      .ToList();
  }

  static List<List<string>> ReadRows(ZipArchive archive, string part, List<string> shared)
  {
    var entry = archive.GetEntry(part) ?? throw new WorkbookReadException($"Lista {part} ni v zvezku.");
    using var stream = entry.Open();
    var root = XDocument.Load(stream).Root ?? throw new WorkbookReadException("List je prazen.");

    var rows = new List<List<string>>();
    foreach (var row in root.Descendants(XName.Get("row", Ns)))
    {
      if (rows.Count >= MaxRows) throw new WorkbookReadException($"Zvezek ima več kot {MaxRows} vrstic; razdeli ga na več datotek.");
      var cells = new List<string>();
      foreach (var cell in row.Elements(XName.Get("c", Ns)))
      {
        // Excel prazne celice izpusti; iz sklica (A1, C1) se razbere, koliko jih manjka.
        var column = ColumnIndex(cell.Attribute("r")?.Value);
        if (column >= 0) while (cells.Count < column) cells.Add(string.Empty);
        cells.Add(CellValue(cell, shared));
      }
      rows.Add(cells);
    }
    return rows;
  }

  static string CellValue(XElement cell, List<string> shared)
  {
    var type = cell.Attribute("t")?.Value;
    if (type == "inlineStr")
      return string.Concat(cell.Descendants(XName.Get("t", Ns)).Select(text => text.Value));

    var value = cell.Element(XName.Get("v", Ns))?.Value;
    if (value is null) return string.Empty;
    if (type != "s") return value;
    return int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var index)
      && index >= 0 && index < shared.Count ? shared[index] : string.Empty;
  }

  static int ColumnIndex(string? reference)
  {
    if (string.IsNullOrEmpty(reference)) return -1;
    var letters = Regex.Match(reference, "^[A-Za-z]+").Value;
    if (letters.Length == 0) return -1;
    var index = 0;
    foreach (var letter in letters) index = index * 26 + (char.ToUpperInvariant(letter) - 'A' + 1);
    return index - 1;
  }
}
