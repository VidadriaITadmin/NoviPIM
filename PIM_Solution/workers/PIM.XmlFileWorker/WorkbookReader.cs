using System.Globalization;
using System.IO.Compression;
using System.Text;
using System.Xml;
using System.Xml.Linq;

namespace PIM.XmlFileWorker;

/// <summary>
/// Delovni zvezek (.xlsx) prebran v isti generični XML, kot ga worker že zna zajeti.
///
/// Zakaj tako in ne nov worker: vsa pot za dobaviteljev XML — nabiralnik, izluščanje po XPath,
/// preslikave iz registra, karantena, mejnik — je že narejena in dokazana. Delovni zvezek je
/// samo druga oblika iste stvari, zato se pretvori v XML in gre po isti poti. Nova oblika je
/// pretvornik, ne nov tok podatkov.
///
/// Imena elementov nastanejo iz naslovov stolpcev: "Naziv angleški" postane &lt;NazivAngleski&gt;.
/// Pravilo je zapisano tu in je edino mesto, kjer se sme spremeniti — register se sklicuje nanj.
/// </summary>
public static class WorkbookReader
{
  const string Ns = "http://schemas.openxmlformats.org/spreadsheetml/2006/main";
  const string RelNs = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";

  /// <summary>Naslov stolpca, po katerem prepoznamo pravi list in pravo vrstico z naslovi.</summary>
  public const string KljucniNaslov = "Šifra artikla";

  public static string ToXml(string path)
  {
    // Zvezek je lahko odprt v Excelu; beremo ga v nacinu, ki to dopusca, sicer bi zajem padel
    // zaradi datoteke, ki jo je nekdo ravno gledal.
    using var stream = new FileStream(path, FileMode.Open, FileAccess.Read,
      FileShare.ReadWrite | FileShare.Delete);
    using var archive = new ZipArchive(stream, ZipArchiveMode.Read);
    var shared = ReadSharedStrings(archive);
    var listi = ReadSheets(archive);

    foreach (var (_, part) in listi)
    {
      var vrstice = ReadRows(archive, part, shared);
      var naslovi = NajdiNaslove(vrstice);
      if (naslovi < 0) continue;

      var imena = vrstice[naslovi].Select(SanitizeName).ToArray();
      var koren = new XElement("vrstice");
      for (var index = naslovi + 1; index < vrstice.Count; index++)
      {
        var vrstica = vrstice[index];
        var element = new XElement("vrstica");
        var prazna = true;
        for (var stolpec = 0; stolpec < imena.Length && stolpec < vrstica.Count; stolpec++)
        {
          var ime = imena[stolpec];
          var vrednost = vrstica[stolpec];
          if (ime.Length == 0 || vrednost.Length == 0) continue;
          element.Add(new XElement(ime, vrednost));
          prazna = false;
        }
        if (!prazna) koren.Add(element);
      }
      return new XDocument(koren).ToString(SaveOptions.DisableFormatting);
    }

    throw new InvalidOperationException(
      $"V zvezku {Path.GetFileName(path)} ni lista z naslovom stolpca '{KljucniNaslov}'.");
  }

  /// <summary>Vrstica z naslovi je prva, ki nosi ključni naslov; nad njo so lahko opombe.</summary>
  static int NajdiNaslove(IReadOnlyList<List<string>> vrstice)
  {
    for (var index = 0; index < vrstice.Count && index < 20; index++)
    {
      if (vrstice[index].Any(celica => string.Equals(celica, KljucniNaslov, StringComparison.OrdinalIgnoreCase)))
        return index;
    }
    return -1;
  }

  /// <summary>Naslov stolpca v ime elementa: brez sumnikov, brez presledkov in ločil.</summary>
  public static string SanitizeName(string naslov)
  {
    var builder = new StringBuilder();
    var velika = true;
    foreach (var znak in naslov.Trim())
    {
      var preslikan = znak switch
      {
        'š' or 'Š' => 's', 'č' or 'Č' => 'c', 'ž' or 'Ž' => 'z',
        'ć' or 'Ć' => 'c', 'đ' or 'Đ' => 'd',
        _ => znak
      };
      if (char.IsLetterOrDigit(preslikan))
      {
        builder.Append(velika ? char.ToUpperInvariant(preslikan) : preslikan);
        velika = false;
      }
      else
      {
        velika = true;
      }
    }
    var ime = builder.ToString();
    if (ime.Length == 0) return string.Empty;
    return char.IsDigit(ime[0]) ? "S" + ime : ime;
  }

  static string[] ReadSharedStrings(ZipArchive archive)
  {
    var entry = archive.GetEntry("xl/sharedStrings.xml");
    if (entry is null) return [];
    using var stream = entry.Open();
    var document = XDocument.Load(stream);
    return document.Root!.Elements(XName.Get("si", Ns))
      .Select(si => string.Concat(si.Descendants(XName.Get("t", Ns)).Select(t => t.Value)))
      .ToArray();
  }

  static List<(string Ime, string Part)> ReadSheets(ZipArchive archive)
  {
    using var workbookStream = archive.GetEntry("xl/workbook.xml")!.Open();
    var workbook = XDocument.Load(workbookStream);
    using var relStream = archive.GetEntry("xl/_rels/workbook.xml.rels")!.Open();
    var rels = XDocument.Load(relStream).Root!.Elements()
      .ToDictionary(r => r.Attribute("Id")!.Value, r => r.Attribute("Target")!.Value);

    var listi = new List<(string, string)>();
    foreach (var sheet in workbook.Root!.Descendants(XName.Get("sheet", Ns)))
    {
      var id = sheet.Attribute(XName.Get("id", RelNs))!.Value;
      var target = rels[id].TrimStart('/');
      listi.Add((sheet.Attribute("name")!.Value, target.StartsWith("xl/") ? target : "xl/" + target));
    }
    return listi;
  }

  static List<List<string>> ReadRows(ZipArchive archive, string part, string[] shared)
  {
    var entry = archive.GetEntry(part) ?? throw new InvalidOperationException($"Manjka del zvezka {part}.");
    using var stream = entry.Open();
    using var reader = XmlReader.Create(stream, new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit });
    var vrstice = new List<List<string>>();
    List<string>? trenutna = null;
    string? sklic = null;
    string? tip = null;

    while (reader.Read())
    {
      if (reader.NodeType == XmlNodeType.Element && reader.LocalName == "row")
      {
        trenutna = [];
        vrstice.Add(trenutna);
        if (reader.IsEmptyElement) trenutna = null;
      }
      else if (reader.NodeType == XmlNodeType.Element && reader.LocalName == "c" && trenutna is not null)
      {
        sklic = reader.GetAttribute("r");
        tip = reader.GetAttribute("t");
        // Prazne celice v XLSX ne obstajajo; stolpec pove sklic (A1, C1 ...), zato ga poravnamo.
        var stolpec = SklicVStolpec(sklic);
        while (trenutna.Count < stolpec) trenutna.Add(string.Empty);
        if (reader.IsEmptyElement) trenutna.Add(string.Empty);
      }
      else if (reader.NodeType == XmlNodeType.Element && reader.LocalName == "v" && trenutna is not null)
      {
        var besedilo = reader.ReadElementContentAsString();
        var vrednost = tip == "s" && int.TryParse(besedilo, NumberStyles.Integer, CultureInfo.InvariantCulture, out var kazalo)
          && kazalo >= 0 && kazalo < shared.Length ? shared[kazalo] : besedilo;
        vrednost = vrednost.Replace("\0", string.Empty).Trim();
        // Napaka formule v celici ni podatek: t="e" ali besedilo #N/A, #REF! in podobno pomeni,
        // da vrednosti ni. Brez tega bi v katalogu pristal spletni naziv "#N/A".
        if (tip == "e" || JeNapakaFormule(vrednost)) vrednost = string.Empty;
        trenutna.Add(vrednost);
      }
      else if (reader.NodeType == XmlNodeType.EndElement && reader.LocalName == "row")
      {
        trenutna = null;
      }
    }
    return vrstice;
  }

  static bool JeNapakaFormule(string vrednost) =>
    vrednost.Length > 1 && vrednost[0] == '#'
    && vrednost is "#N/A" or "#VALUE!" or "#REF!" or "#DIV/0!" or "#NAME?" or "#NULL!" or "#NUM!";

  static int SklicVStolpec(string? sklic)
  {
    if (string.IsNullOrEmpty(sklic)) return 0;
    var stolpec = 0;
    foreach (var znak in sklic)
    {
      if (!char.IsLetter(znak)) break;
      stolpec = stolpec * 26 + (char.ToUpperInvariant(znak) - 'A' + 1);
    }
    return Math.Max(stolpec - 1, 0);
  }
}
