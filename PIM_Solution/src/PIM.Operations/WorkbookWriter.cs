using System.Globalization;
using System.IO.Compression;
using System.Text;

namespace PIM.Operations;

/// <summary>Kaj je v celici; iz tega sledita oblika in poravnava v Excelu.</summary>
public enum WorkbookCellKind
{
  /// <summary>Besedilo. Šifra artikla ostane besedilo, da Excel ne poje vodilnih ničel.</summary>
  Text,
  Number,
  Percent,
  DateTime,
}

/// <param name="Width">Širina stolpca v znakih; 0 pomeni privzeto.</param>
public sealed record WorkbookColumn(string Header, WorkbookCellKind Kind = WorkbookCellKind.Text, double Width = 0);

/// <summary>
/// Zapis delovnega zvezka (.xlsx) — nasprotna smer <see cref="WorkbookTable"/>.
///
/// Zakaj brez knjižnice: iz istega razloga kot pri branju. Zvezek je stisnjena mapa datotek
/// XML in za tabelo s podatki so potrebne štiri: tipi vsebine, dve povezavi, zvezek in list.
/// Oblike (krepka glava, zamrznjena prva vrstica, samodejni filter, oblika datuma in odstotka)
/// so peta datoteka. To je manj kode, kot je vzdrževanja ene odvisnosti več.
///
/// Zakaj ne CSV: CSV je za Excel dvoumen — ločilo, kodna stran in vodilne ničle v šifri
/// artikla so odvisni od nastavitev računalnika, ki datoteko odpre. Zvezek nosi tip vsake
/// celice s sabo, zato se šifra <c>0000000000001</c> odpre kot <c>0000000000001</c>.
///
/// Vrednosti celic so <c>string</c>, <c>decimal</c>/<c>double</c>/<c>int</c>/<c>long</c>,
/// <c>DateTime</c>, <c>bool</c> (»da«/»ne«) ali <c>null</c> (prazna celica).
/// </summary>
public static class WorkbookWriter
{
  /// <summary>Največ vrstic na list; ista varovalka kot pri branju.</summary>
  public const int MaxRows = WorkbookTable.MaxRows;

  /// <summary>Excelova ničla za datume. 1900 je namenoma prestopno leto, zato 30. december.</summary>
  static readonly DateTime SerialEpoch = new(1899, 12, 30);

  /// <param name="notes">Vrstice pod tabelo — tam pove, česa v datoteki ni in zakaj.</param>
  public static byte[] Write(
    string sheetName,
    IReadOnlyList<WorkbookColumn> columns,
    IEnumerable<IReadOnlyList<object?>> rows,
    IReadOnlyList<string>? notes = null)
  {
    ArgumentNullException.ThrowIfNull(columns);
    ArgumentNullException.ThrowIfNull(rows);
    if (columns.Count == 0) throw new ArgumentException("Zvezek brez stolpcev ni tabela.", nameof(columns));

    var sheet = new StringBuilder();
    sheet.Append("""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>""");
    sheet.Append("""<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">""");

    // Zamrznjena naslovna vrstica: pri 20.000 vrsticah je brez tega že tretja stran ugibanje.
    sheet.Append("""<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>""");

    sheet.Append("<cols>");
    for (var index = 0; index < columns.Count; index++)
    {
      var width = columns[index].Width > 0 ? columns[index].Width : DefaultWidth(columns[index]);
      sheet.Append(CultureInfo.InvariantCulture, $"""<col min="{index + 1}" max="{index + 1}" width="{width.ToString("0.##", CultureInfo.InvariantCulture)}" customWidth="1"/>""");
    }
    sheet.Append("</cols><sheetData>");

    sheet.Append("""<row r="1">""");
    for (var index = 0; index < columns.Count; index++)
      AppendCell(sheet, Reference(index, 1), columns[index].Header, WorkbookCellKind.Text, styleIndex: 1);
    sheet.Append("</row>");

    var rowNumber = 1;
    var truncated = false;
    foreach (var row in rows)
    {
      if (rowNumber - 1 >= MaxRows) { truncated = true; break; }
      rowNumber++;
      sheet.Append(CultureInfo.InvariantCulture, $"""<row r="{rowNumber}">""");
      for (var index = 0; index < columns.Count && index < row.Count; index++)
        AppendCell(sheet, Reference(index, rowNumber), row[index], columns[index].Kind, StyleOf(columns[index].Kind));
      sheet.Append("</row>");
    }

    var noteLines = new List<string>(notes ?? []);
    if (truncated) noteLines.Add($"Zapisanih je prvih {MaxRows:N0} vrstic; datoteka je odrezana.");
    if (noteLines.Count > 0)
    {
      rowNumber++;
      foreach (var note in noteLines)
      {
        rowNumber++;
        sheet.Append(CultureInfo.InvariantCulture, $"""<row r="{rowNumber}">""");
        AppendCell(sheet, Reference(0, rowNumber), note, WorkbookCellKind.Text, styleIndex: 0);
        sheet.Append("</row>");
      }
    }

    sheet.Append("</sheetData>");
    sheet.Append(CultureInfo.InvariantCulture, $"""<autoFilter ref="A1:{ColumnName(columns.Count - 1)}1"/>""");
    sheet.Append("</worksheet>");

    var stream = new MemoryStream();
    using (var archive = new ZipArchive(stream, ZipArchiveMode.Create, leaveOpen: true))
    {
      Put(archive, "[Content_Types].xml",
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="xml" ContentType="application/xml"/>
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
          <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
          <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
        </Types>
        """);
      Put(archive, "_rels/.rels",
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>
        """);
      Put(archive, "xl/workbook.xml",
        $"""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets><sheet name="{Escape(SheetName(sheetName))}" sheetId="1" r:id="rId1"/></sheets>
        </workbook>
        """);
      Put(archive, "xl/_rels/workbook.xml.rels",
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
          <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        </Relationships>
        """);
      Put(archive, "xl/styles.xml", Styles);
      Put(archive, "xl/worksheets/sheet1.xml", sheet.ToString());
    }

    return stream.ToArray();
  }

  /* Slog: 0 privzeto, 1 glava (krepko, siva podlaga, črta), 2 datum, 3 odstotek. */
  const string Styles =
    """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
      <numFmts count="2">
        <numFmt numFmtId="164" formatCode="dd.mm.yyyy\ hh:mm"/>
        <numFmt numFmtId="165" formatCode="0.0&quot; %&quot;"/>
      </numFmts>
      <fonts count="2">
        <font><sz val="11"/><name val="Calibri"/></font>
        <font><b/><sz val="11"/><name val="Calibri"/></font>
      </fonts>
      <fills count="3">
        <fill><patternFill patternType="none"/></fill>
        <fill><patternFill patternType="gray125"/></fill>
        <fill><patternFill patternType="solid"><fgColor rgb="FFEEF1F6"/><bgColor indexed="64"/></patternFill></fill>
      </fills>
      <borders count="2">
        <border><left/><right/><top/><bottom/><diagonal/></border>
        <border><left/><right/><top/><bottom style="thin"><color rgb="FFBFC7D2"/></bottom><diagonal/></border>
      </borders>
      <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
      <cellXfs count="4">
        <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
        <xf numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1"/>
        <xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
        <xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
      </cellXfs>
    </styleSheet>
    """;

  static int StyleOf(WorkbookCellKind kind) => kind switch
  {
    WorkbookCellKind.DateTime => 2,
    WorkbookCellKind.Percent => 3,
    _ => 0,
  };

  static double DefaultWidth(WorkbookColumn column) => column.Kind switch
  {
    WorkbookCellKind.DateTime => 18,
    WorkbookCellKind.Number or WorkbookCellKind.Percent => 12,
    _ => Math.Clamp(column.Header.Length + 4, 12, 42),
  };

  static void AppendCell(StringBuilder sheet, string reference, object? value, WorkbookCellKind kind, int styleIndex)
  {
    var style = styleIndex == 0 ? "" : $" s=\"{styleIndex}\"";
    if (value is null || (value is string empty && empty.Length == 0))
    {
      sheet.Append(CultureInfo.InvariantCulture, $"""<c r="{reference}"{style}/>""");
      return;
    }

    if (value is bool flag) value = flag ? "da" : "ne";

    if (kind is WorkbookCellKind.DateTime && value is DateTime moment)
    {
      var serial = (moment - SerialEpoch).TotalDays;
      sheet.Append(CultureInfo.InvariantCulture, $"""<c r="{reference}"{style}><v>{serial.ToString("0.######", CultureInfo.InvariantCulture)}</v></c>""");
      return;
    }

    if (kind is WorkbookCellKind.Number or WorkbookCellKind.Percent && TryNumber(value, out var number))
    {
      sheet.Append(CultureInfo.InvariantCulture, $"""<c r="{reference}"{style}><v>{number.ToString("0.##########", CultureInfo.InvariantCulture)}</v></c>""");
      return;
    }

    // Besedilo gre v celico samo (inlineStr): brez tabele deljenih nizov je zapis tekoč,
    // datoteka pa nekaj odstotkov večja. Pri izvozu, ki nastane in odide, je to prava menjava.
    sheet.Append(CultureInfo.InvariantCulture, $"""<c r="{reference}"{style} t="inlineStr"><is><t xml:space="preserve">{Escape(Convert.ToString(value, CultureInfo.InvariantCulture))}</t></is></c>""");
  }

  static bool TryNumber(object value, out decimal number)
  {
    switch (value)
    {
      case decimal decimalValue: number = decimalValue; return true;
      case double doubleValue: number = (decimal)doubleValue; return true;
      case float floatValue: number = (decimal)floatValue; return true;
      case int intValue: number = intValue; return true;
      case long longValue: number = longValue; return true;
      case short shortValue: number = shortValue; return true;
      case byte byteValue: number = byteValue; return true;
      default:
        return decimal.TryParse(Convert.ToString(value, CultureInfo.InvariantCulture),
          NumberStyles.Any, CultureInfo.InvariantCulture, out number);
    }
  }

  static string Reference(int columnIndex, int rowNumber) => ColumnName(columnIndex) + rowNumber.ToString(CultureInfo.InvariantCulture);

  static string ColumnName(int index)
  {
    var name = "";
    for (var value = index; value >= 0; value = value / 26 - 1) name = (char)('A' + value % 26) + name;
    return name;
  }

  /// <summary>Ime lista: Excel ne dovoli \ / ? * [ ] : in več kot 31 znakov.</summary>
  static string SheetName(string? value)
  {
    var cleaned = new string((value ?? "").Where(character => !"\\/?*[]:".Contains(character)).ToArray()).Trim();
    if (cleaned.Length == 0) cleaned = "Podatki";
    return cleaned.Length > 31 ? cleaned[..31] : cleaned;
  }

  /// <summary>
  /// Poleg petih znakov XML odstrani tudi krmilne znake. Naziv izdelka iz dobaviteljevega
  /// XML jih zna vsebovati, Excel pa tak zvezek zavrne kot pokvarjen.
  /// </summary>
  static string Escape(string? value)
  {
    if (string.IsNullOrEmpty(value)) return "";
    var builder = new StringBuilder(value.Length);
    foreach (var character in value)
      switch (character)
      {
        case '&': builder.Append("&amp;"); break;
        case '<': builder.Append("&lt;"); break;
        case '>': builder.Append("&gt;"); break;
        case '"': builder.Append("&quot;"); break;
        case '\'': builder.Append("&apos;"); break;
        case '\t' or '\n' or '\r': builder.Append(' '); break;
        default:
          if (character >= ' ' || character == '	') builder.Append(character);
          break;
      }

    return builder.ToString();
  }

  static void Put(ZipArchive archive, string path, string content)
  {
    var entry = archive.CreateEntry(path, CompressionLevel.Optimal);
    using var writer = new StreamWriter(entry.Open(), new UTF8Encoding(false));
    writer.Write(content);
  }
}
