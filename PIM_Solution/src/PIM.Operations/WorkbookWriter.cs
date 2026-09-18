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

/// <summary>
/// Barva ozadja celice. Ni okras: uporabnik je 2026-08-28 zahteval, da se v Excelu vidi,
/// katero polje pri izdelku manjka in katero polje sploh je pogoj za validacijo — brez tega
/// je treba vsak stolpec preverjati rocno.
/// </summary>
public enum WorkbookCellTone
{
  /// <summary>Brez podlage.</summary>
  None,

  /// <summary>Blaga vinsko rdeca: vrednost manjka, pa bi morala biti.</summary>
  Missing,

  /// <summary>Rumenkasta: polje je pogoj za validacijo.</summary>
  Required,

  /// <summary>Bleda oranzna: opozorilo — ne blokira, a je vredno pogledati (kakovost, napake).</summary>
  Warning,
}

/// <param name="Value">Vrednost celice; enaka pravila kot pri golih vrednostih.</param>
/// <param name="Tone">Podlaga celice.</param>
public sealed record WorkbookCell(object? Value, WorkbookCellTone Tone = WorkbookCellTone.None);

/// <param name="Width">Širina stolpca v znakih; 0 pomeni privzeto.</param>
/// <param name="Group">Naslov skupine nad stolpcem; kadar ga ima vsaj en stolpec, dobi list
/// dve naslovni vrstici — skupine in imena stolpcev.</param>
/// <param name="HeaderTone">Podlaga naslovne celice; z njo se oznaci zahtevano polje.</param>
public sealed record WorkbookColumn(
  string Header, WorkbookCellKind Kind = WorkbookCellKind.Text, double Width = 0,
  string? Group = null, WorkbookCellTone HeaderTone = WorkbookCellTone.None);

/// <summary>
/// En list zvezka z več listi za pisanje; glej <see cref="WorkbookWriter.Write(IReadOnlyList{WorkbookWriteSheet})"/>.
/// Ime se razlikuje od bralnega <see cref="WorkbookSheet"/> (WorkbookTable.cs), da se ne prekrivata.
/// </summary>
/// <param name="Notes">Vrstice pod tabelo tega lista — tam pove, česa v datoteki ni in zakaj.</param>
public sealed record WorkbookWriteSheet(
  string Name, IReadOnlyList<WorkbookColumn> Columns,
  IEnumerable<IReadOnlyList<object?>> Rows, IReadOnlyList<string>? Notes = null);

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
/// Vrstice se pišejo naravnost v stisnjen vnos zvezka, ne najprej v en niz: list s sto tisoč
/// vrsticami bi kot niz pojedel gigabajte, stisnjen pa je nekaj deset megabajtov. Zato
/// vrstice pridejo kot zaporedje (<see cref="IEnumerable{T}"/> ali <see cref="IAsyncEnumerable{T}"/>),
/// ki ga zapisovalnik prebere natanko enkrat — vir jih lahko bere iz baze po paketih, medtem
/// ko se datoteka ze pise.
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
    IReadOnlyList<string>? notes = null) =>
    Write([new WorkbookWriteSheet(sheetName, columns, rows, notes)]);

  /// <summary>Zvezek z enim ali več listi; vsak list ima svoje stolpce, vrstice in opombe.</summary>
  public static byte[] Write(IReadOnlyList<WorkbookWriteSheet> sheets)
  {
    ArgumentNullException.ThrowIfNull(sheets);
    if (sheets.Count == 0) throw new ArgumentException("Zvezek brez listov ni zvezek.", nameof(sheets));
    foreach (var sheet in sheets)
      if (sheet.Columns.Count == 0) throw new ArgumentException("Zvezek brez stolpcev ni tabela.", nameof(sheets));

    var stream = new MemoryStream();
    using (var archive = new ZipArchive(stream, ZipArchiveMode.Create, leaveOpen: true))
    {
      PutEnvelope(archive, sheets.Select(sheet => SheetName(sheet.Name)).ToArray());
      for (var index = 0; index < sheets.Count; index++)
      {
        using var writer = OpenSheet(archive, index + 1);
        WriteSheet(writer, sheets[index]);
      }
    }

    return stream.ToArray();
  }

  /// <summary>
  /// En list, vrstice iz asinhronega vira: izvoz, ki vrstice bere iz baze po paketih
  /// (ProductWorkbookService), jih pise sproti, ne da bi jih najprej vse zbral v pomnilniku.
  /// </summary>
  /// <param name="notes">Vrstice pod tabelo — tam pove, česa v datoteki ni in zakaj.</param>
  public static async Task<byte[]> WriteAsync(
    string sheetName,
    IReadOnlyList<WorkbookColumn> columns,
    IAsyncEnumerable<IReadOnlyList<object?>> rows,
    IReadOnlyList<string>? notes = null,
    CancellationToken cancellationToken = default)
  {
    using var stream = new MemoryStream();
    await WriteAsync(stream, sheetName, columns, rows, notes, cancellationToken);
    return stream.ToArray();
  }

  /// <summary>
  /// Isto kot <see cref="WriteAsync(string, IReadOnlyList{WorkbookColumn}, IAsyncEnumerable{IReadOnlyList{object?}}, IReadOnlyList{string}?, CancellationToken)"/>,
  /// a zapise naravnost v dani tok (datoteko na disku): zvezek celega kataloga meri desetine
  /// megabajtov in vec hkratnih izvozov v pomnilniku bi pojedlo delovni pomnilnik streznika.
  /// Tok mora dovoliti iskanje (ZipArchive pise osrednji imenik na koncu).
  /// </summary>
  public static async Task WriteAsync(
    Stream destination,
    string sheetName,
    IReadOnlyList<WorkbookColumn> columns,
    IAsyncEnumerable<IReadOnlyList<object?>> rows,
    IReadOnlyList<string>? notes = null,
    CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(destination);
    ArgumentNullException.ThrowIfNull(columns);
    ArgumentNullException.ThrowIfNull(rows);
    if (columns.Count == 0) throw new ArgumentException("Zvezek brez stolpcev ni tabela.", nameof(columns));

    using var archive = new ZipArchive(destination, ZipArchiveMode.Create, leaveOpen: true);
    PutEnvelope(archive, [SheetName(sheetName)]);
    using var writer = OpenSheet(archive, 1);
    var headerRows = WriteSheetHead(writer, columns);
    var rowNumber = headerRows;
    var truncated = false;
    await foreach (var row in rows.WithCancellation(cancellationToken))
    {
      if (rowNumber - headerRows >= MaxRows) { truncated = true; break; }
      rowNumber++;
      WriteRow(writer, columns, row, rowNumber);
    }
    WriteSheetTail(writer, columns, notes, headerRows, rowNumber, truncated);
  }

  /// <summary>Stalni deli zvezka: tipi vsebine, povezave, seznam listov in slogi.</summary>
  static void PutEnvelope(ZipArchive archive, IReadOnlyList<string> sheetNames)
  {
    Put(archive, "[Content_Types].xml",
      $$"""
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="xml" ContentType="application/xml"/>
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        {{string.Join("\n  ", Enumerable.Range(1, sheetNames.Count).Select(index =>
          $"""<Override PartName="/xl/worksheets/sheet{index}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"""))}}
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
      $$"""
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <sheets>{{string.Join("", sheetNames.Select((name, index) =>
          $"""<sheet name="{Escape(name)}" sheetId="{index + 1}" r:id="rId{index + 1}"/>"""))}}</sheets>
      </workbook>
      """);
    // rId(sheetNames.Count + 1) je slog; vsak list dobi svoj rId po vrstnem redu pred njim.
    Put(archive, "xl/_rels/workbook.xml.rels",
      $$"""
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        {{string.Join("\n  ", Enumerable.Range(1, sheetNames.Count).Select(index =>
          $"""<Relationship Id="rId{index}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet{index}.xml"/>"""))}}
        <Relationship Id="rId{{sheetNames.Count + 1}}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
      </Relationships>
      """);
    Put(archive, "xl/styles.xml", Styles);
  }

  static void WriteSheet(TextWriter writer, WorkbookWriteSheet workbookSheet)
  {
    var columns = workbookSheet.Columns;
    var headerRows = WriteSheetHead(writer, columns);
    var rowNumber = headerRows;
    var truncated = false;
    foreach (var row in workbookSheet.Rows)
    {
      if (rowNumber - headerRows >= MaxRows) { truncated = true; break; }
      rowNumber++;
      WriteRow(writer, columns, row, rowNumber);
    }
    WriteSheetTail(writer, columns, workbookSheet.Notes, headerRows, rowNumber, truncated);
  }

  /// <summary>Zacetek lista do prve podatkovne vrstice; vrne stevilo naslovnih vrstic.</summary>
  static int WriteSheetHead(TextWriter writer, IReadOnlyList<WorkbookColumn> columns)
  {
    writer.Write("""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>""");
    writer.Write("""<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">""");

    // Kadar stolpci nosijo skupine, ima list dve naslovni vrstici: skupine in imena.
    var hasGroups = columns.Any(column => !string.IsNullOrWhiteSpace(column.Group));
    var headerRows = hasGroups ? 2 : 1;

    // Zamrznjena naslovna vrstica: pri 20.000 vrsticah je brez tega že tretja stran ugibanje.
    writer.Write(FormattableString.Invariant($"""<sheetViews><sheetView workbookViewId="0"><pane ySplit="{headerRows}" topLeftCell="A{headerRows + 1}" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>"""));

    writer.Write("<cols>");
    for (var index = 0; index < columns.Count; index++)
    {
      var width = columns[index].Width > 0 ? columns[index].Width : DefaultWidth(columns[index]);
      writer.Write(FormattableString.Invariant($"""<col min="{index + 1}" max="{index + 1}" width="{width.ToString("0.##", CultureInfo.InvariantCulture)}" customWidth="1"/>"""));
    }
    writer.Write("</cols><sheetData>");

    if (hasGroups)
    {
      writer.Write("""<row r="1">""");
      for (var index = 0; index < columns.Count; index++)
      {
        // Skupina se izpise samo nad prvim stolpcem skupine; sicer bi se ime ponavljalo
        // pri vsakem stolpcu in bi vrstica postala hrup namesto orientacije.
        var group = columns[index].Group;
        var repeats = index > 0 && string.Equals(columns[index - 1].Group, group, StringComparison.Ordinal);
        WriteCell(writer, Reference(index, 1), repeats ? null : group, WorkbookCellKind.Text, styleIndex: 1);
      }
      writer.Write("</row>");
    }

    writer.Write(FormattableString.Invariant($"""<row r="{headerRows}">"""));
    for (var index = 0; index < columns.Count; index++)
      WriteCell(writer, Reference(index, headerRows), columns[index].Header, WorkbookCellKind.Text,
        styleIndex: columns[index].HeaderTone == WorkbookCellTone.Required ? 11 : 1);
    writer.Write("</row>");

    return headerRows;
  }

  static void WriteRow(TextWriter writer, IReadOnlyList<WorkbookColumn> columns, IReadOnlyList<object?> row, int rowNumber)
  {
    writer.Write(FormattableString.Invariant($"""<row r="{rowNumber}">"""));
    for (var index = 0; index < columns.Count && index < row.Count; index++)
    {
      var raw = row[index];
      var tone = raw is WorkbookCell toned ? toned.Tone : WorkbookCellTone.None;
      if (raw is WorkbookCell cell) raw = cell.Value;
      WriteCell(writer, Reference(index, rowNumber), raw, columns[index].Kind, StyleOf(columns[index].Kind, tone));
    }
    writer.Write("</row>");
  }

  /// <summary>Opombe pod tabelo, konec podatkov in samodejni filter nad naslovno vrstico.</summary>
  static void WriteSheetTail(
    TextWriter writer, IReadOnlyList<WorkbookColumn> columns, IReadOnlyList<string>? notes,
    int headerRows, int rowNumber, bool truncated)
  {
    var noteLines = new List<string>(notes ?? []);
    if (truncated) noteLines.Add($"Zapisanih je prvih {MaxRows:N0} vrstic; datoteka je odrezana.");
    if (noteLines.Count > 0)
    {
      rowNumber++;
      foreach (var note in noteLines)
      {
        rowNumber++;
        writer.Write(FormattableString.Invariant($"""<row r="{rowNumber}">"""));
        WriteCell(writer, Reference(0, rowNumber), note, WorkbookCellKind.Text, styleIndex: 0);
        writer.Write("</row>");
      }
    }

    writer.Write("</sheetData>");
    writer.Write(FormattableString.Invariant($"""<autoFilter ref="A{headerRows}:{ColumnName(columns.Count - 1)}{headerRows}"/>"""));
    writer.Write("</worksheet>");
  }

  /* Slog: 0 privzeto, 1 glava, 2 datum, 3 odstotek; 4–6 manjkajoca vrednost (vinsko rdeca)
     v istih treh oblikah, 7–9 zahtevano polje (rumenkasta), 11 zahtevana glava,
     12–14 opozorilo (bleda oranzna) v istih treh oblikah. */
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
      <fills count="6">
        <fill><patternFill patternType="none"/></fill>
        <fill><patternFill patternType="gray125"/></fill>
        <fill><patternFill patternType="solid"><fgColor rgb="FFEEF1F6"/><bgColor indexed="64"/></patternFill></fill>
        <fill><patternFill patternType="solid"><fgColor rgb="FFF6D6D6"/><bgColor indexed="64"/></patternFill></fill>
        <fill><patternFill patternType="solid"><fgColor rgb="FFFCEFC0"/><bgColor indexed="64"/></patternFill></fill>
        <fill><patternFill patternType="solid"><fgColor rgb="FFFCE0C2"/><bgColor indexed="64"/></patternFill></fill>
      </fills>
      <borders count="2">
        <border><left/><right/><top/><bottom/><diagonal/></border>
        <border><left/><right/><top/><bottom style="thin"><color rgb="FFBFC7D2"/></bottom><diagonal/></border>
      </borders>
      <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
      <cellXfs count="15">
        <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
        <xf numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1"/>
        <xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
        <xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
        <xf numFmtId="0" fontId="0" fillId="3" borderId="0" xfId="0" applyFill="1"/>
        <xf numFmtId="164" fontId="0" fillId="3" borderId="0" xfId="0" applyNumberFormat="1" applyFill="1"/>
        <xf numFmtId="165" fontId="0" fillId="3" borderId="0" xfId="0" applyNumberFormat="1" applyFill="1"/>
        <xf numFmtId="0" fontId="0" fillId="4" borderId="0" xfId="0" applyFill="1"/>
        <xf numFmtId="164" fontId="0" fillId="4" borderId="0" xfId="0" applyNumberFormat="1" applyFill="1"/>
        <xf numFmtId="165" fontId="0" fillId="4" borderId="0" xfId="0" applyNumberFormat="1" applyFill="1"/>
        <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
        <xf numFmtId="0" fontId="1" fillId="4" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1"/>
        <xf numFmtId="0" fontId="0" fillId="5" borderId="0" xfId="0" applyFill="1"/>
        <xf numFmtId="164" fontId="0" fillId="5" borderId="0" xfId="0" applyNumberFormat="1" applyFill="1"/>
        <xf numFmtId="165" fontId="0" fillId="5" borderId="0" xfId="0" applyNumberFormat="1" applyFill="1"/>
      </cellXfs>
    </styleSheet>
    """;

  static int StyleOf(WorkbookCellKind kind, WorkbookCellTone tone = WorkbookCellTone.None)
  {
    var offset = kind switch { WorkbookCellKind.DateTime => 1, WorkbookCellKind.Percent => 2, _ => 0 };
    return tone switch
    {
      WorkbookCellTone.Missing => 4 + offset,
      WorkbookCellTone.Required => 7 + offset,
      WorkbookCellTone.Warning => 12 + offset,
      // Brez podlage ostane stara razporeditev slogov: 0 besedilo in stevilo, 2 datum, 3 odstotek.
      _ => offset == 0 ? 0 : offset + 1,
    };
  }

  static double DefaultWidth(WorkbookColumn column) => column.Kind switch
  {
    WorkbookCellKind.DateTime => 18,
    WorkbookCellKind.Number or WorkbookCellKind.Percent => 12,
    _ => Math.Clamp(column.Header.Length + 4, 12, 42),
  };

  static void WriteCell(TextWriter writer, string reference, object? value, WorkbookCellKind kind, int styleIndex)
  {
    var style = styleIndex == 0 ? "" : $" s=\"{styleIndex}\"";
    if (value is null || (value is string empty && empty.Length == 0))
    {
      // Prazna celica obdrzi svoj slog: prav pri njej podlaga nekaj pove — vrednost manjka.
      writer.Write(FormattableString.Invariant($"""<c r="{reference}"{style}/>"""));
      return;
    }

    if (value is bool flag) value = flag ? "da" : "ne";

    if (kind is WorkbookCellKind.DateTime && value is DateTime moment)
    {
      var serial = (moment - SerialEpoch).TotalDays;
      writer.Write(FormattableString.Invariant($"""<c r="{reference}"{style}><v>{serial.ToString("0.######", CultureInfo.InvariantCulture)}</v></c>"""));
      return;
    }

    if (kind is WorkbookCellKind.Number or WorkbookCellKind.Percent && TryNumber(value, out var number))
    {
      writer.Write(FormattableString.Invariant($"""<c r="{reference}"{style}><v>{number.ToString("0.##########", CultureInfo.InvariantCulture)}</v></c>"""));
      return;
    }

    // Besedilo gre v celico samo (inlineStr): brez tabele deljenih nizov je zapis tekoč,
    // datoteka pa nekaj odstotkov večja. Pri izvozu, ki nastane in odide, je to prava menjava.
    writer.Write(FormattableString.Invariant($"""<c r="{reference}"{style} t="inlineStr"><is><t xml:space="preserve">{Escape(Convert.ToString(value, CultureInfo.InvariantCulture))}</t></is></c>"""));
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
        // Prelom vrstice ostane prelom. Doslej je postal presledek in vecvrsticen opis se je
        // iz zvezka vrnil sploscen — pri listu, ki gre ven in se vrne nazaj, je to izguba
        // podatka. Excel prelom v <t xml:space="preserve"> pokaze kot prelom v celici.
        case '\n': builder.Append('\n'); break;
        // CR se zavrze: CRLF bi sicer dal dva preloma, LF+CR pa vrstni red, ki ga Excel ne
        // pozna. Zapis je enoten LF.
        case '\r': break;
        case '\t': builder.Append(' '); break;
        default:
          if (character >= ' ' || character == '\t') builder.Append(character);
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

  /// <summary>Odpre vnos lista za pisanje; vrstice gredo vanj sproti, stisnjene, ne prek niza.</summary>
  static StreamWriter OpenSheet(ZipArchive archive, int sheetIndex)
  {
    var entry = archive.CreateEntry($"xl/worksheets/sheet{sheetIndex}.xml", CompressionLevel.Optimal);
    return new StreamWriter(entry.Open(), new UTF8Encoding(false), bufferSize: 1 << 16);
  }
}
