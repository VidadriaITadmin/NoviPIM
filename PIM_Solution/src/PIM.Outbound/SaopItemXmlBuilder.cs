using System.Globalization;
using System.Text;
using System.Xml;
using System.Xml.Linq;

namespace PIM.Outbound;

/// <summary>Ali gre za nov artikel (POST AddItemsGeneralData) ali za spremembo (PATCH UpdateItemsGeneralData).</summary>
public enum SaopIntent { Add, Update }

/// <summary>
/// En element dokumenta <c>ItemsGeneralData</c>, tak, kot ga opisuje <c>out.SaopXmlField</c>.
/// </summary>
/// <param name="Section"><c>Item</c> pomeni neposredno pod <c>ItemGeneralData</c>, sicer ime podelementa.</param>
/// <param name="FieldKey">Kanonična koda; <c>null</c> pomeni, da vrednost pride iz privzetkov.</param>
public sealed record SaopXmlField(
  string Section,
  string ElementName,
  string? FieldKey,
  int SortOrder,
  bool IsAddMandatory,
  string ValueFormat,
  string? TrueValue,
  string? FalseValue);

/// <param name="Xml">Dokument z UTF-8 prologom, pripravljen za pošiljanje.</param>
/// <param name="MissingMandatory">
/// ADD obvezna polja brez vrednosti. Dokument se vseeno sestavi — da ga je mogoče pogledati —
/// a pošiljati ga ni smiselno, ker ga SAOP zavrne z 409.
/// </param>
/// <param name="ElementCount">Koliko podatkovnih elementov je v dokumentu, brez ovojev in žiga.</param>
public sealed record SaopXmlBuildResult(string Xml, IReadOnlyList<string> MissingMandatory, int ElementCount);

public sealed class SaopXmlBuildException(string message) : InvalidOperationException(message);

/// <summary>
/// Sestavi dokument <c>ItemsGeneralData</c> za SAOP iCenter API.
///
/// Oblika ni vzeta iz swaggerja — ta pove imena tipov, ne pa vrstnega reda in ne tega, katera
/// polja SAOP dejansko sprejme. Vzeta je iz 427 resničnih dokumentov, ki jih je stari sistem
/// poslal in je SAOP nanje odgovoril (<c>pim.SaopItemOutboundQueue</c> v bazi <c>PIM_test</c>).
///
/// Razlika med ADD in PATCH ni le metoda:
///   ADD   nosi <c>ItemCreated</c>, vsa obvezna polja in po želji <c>SuggestFirstFreeCode</c>,
///         ob katerem šifro dodeli SAOP sam;
///   PATCH nosi <c>ItemLastModified</c> in <b>samo izpolnjena polja</b>. Vsako poslano polje
///         SAOP prepiše, zato bi polje brez vrednosti pomenilo tiho brisanje podatka v ERP.
///         Iz istega razloga se privzetki v PATCH ne vstavljajo: konstanta kot
///         <c>VATRateID</c> bi povozila vrednost, ki jo SAOP že ima.
/// </summary>
public sealed class SaopItemXmlBuilder
{
  /// <summary>Vrstni red ovojev; SAOP jih v odgovorih vrača v tem zaporedju.</summary>
  static readonly string[] SectionOrder = ["Item", "GeneralData", "SalesData", "StockData", "PropertiesData"];

  static readonly HashSet<string> TrueWords = new(StringComparer.OrdinalIgnoreCase) { "1", "true", "d", "y", "da" };
  static readonly HashSet<string> FalseWords = new(StringComparer.OrdinalIgnoreCase) { "0", "false", "n", "ne" };

  readonly IReadOnlyList<SaopXmlField> contract;

  public SaopItemXmlBuilder(IEnumerable<SaopXmlField> contract)
  {
    this.contract = contract.OrderBy(field => field.SortOrder).ToArray();
    if (this.contract.Count == 0) throw new SaopXmlBuildException("Pogodba XML je prazna; brez nje ni mogoče sestaviti dokumenta.");
    var unknown = this.contract.FirstOrDefault(field => !SectionOrder.Contains(field.Section));
    if (unknown is not null) throw new SaopXmlBuildException($"Ovoj {unknown.Section} ni del dokumenta ItemsGeneralData.");
  }

  /// <param name="values">Kanonične vrednosti po <c>FieldKey</c>; prazne se izpustijo.</param>
  /// <param name="defaults">Privzetki po ključu <c>Ovoj/Element</c>; upoštevajo se samo pri ADD.</param>
  /// <param name="stampUtc">Čas za <c>ItemCreated</c> oziroma <c>ItemLastModified</c>.</param>
  /// <param name="suggestFirstFreeCode">Samo pri ADD: naj šifro dodeli SAOP.</param>
  public SaopXmlBuildResult Build(
    SaopIntent intent,
    string itemId,
    IReadOnlyDictionary<string, string?> values,
    IReadOnlyDictionary<string, string> defaults,
    DateTime stampUtc,
    bool suggestFirstFreeCode = false)
  {
    if (string.IsNullOrWhiteSpace(itemId)) throw new SaopXmlBuildException("Brez šifre artikla dokumenta ni mogoče nasloviti.");

    var item = new XElement("ItemGeneralData");
    var sections = new Dictionary<string, XElement>(StringComparer.Ordinal);
    var missing = new List<string>();
    var elementCount = 0;

    foreach (var field in contract)
    {
      var raw = Resolve(intent, field, itemId, values, defaults);
      if (string.IsNullOrWhiteSpace(raw))
      {
        // Manjkajoče polje ustavi samo ADD. Pri PATCH je odsotnost polja njegov pomen:
        // "tega ne spreminjam", ne "izbriši".
        if (intent == SaopIntent.Add && field.IsAddMandatory) missing.Add($"{field.Section}/{field.ElementName}");
        continue;
      }

      var formatted = Format(field, raw!);
      Target(item, sections, field.Section).Add(new XElement(field.ElementName, formatted));
      elementCount++;

      // Žig gre takoj za šifro, ker tako stoji v vseh resničnih dokumentih.
      if (field.Section == "Item" && field.ElementName == "ItemID")
        item.Add(new XElement(intent == SaopIntent.Add ? "ItemCreated" : "ItemLastModified", Stamp(stampUtc)));
    }

    // Ovoji se dodajo šele zdaj in samo tisti z vsebino: prazen <SalesData/> je za SAOP
    // veljaven dokument, ki ne naredi ničesar, in v pregledu izgleda kot poslana sprememba.
    foreach (var section in SectionOrder.Where(name => name != "Item"))
      if (sections.TryGetValue(section, out var element) && element.HasElements) item.Add(element);

    if (intent == SaopIntent.Add && suggestFirstFreeCode) item.Add(new XElement("SuggestFirstFreeCode", "true"));

    var document = new XElement("ItemsGeneralData", item);
    return new(WithUtf8Prolog(Render(document)), missing, elementCount);
  }

  /// <summary>Vrednost polja: kanonična, sicer privzetek — ta pa samo pri ADD.</summary>
  static string? Resolve(
    SaopIntent intent,
    SaopXmlField field,
    string itemId,
    IReadOnlyDictionary<string, string?> values,
    IReadOnlyDictionary<string, string> defaults)
  {
    // Šifra artikla je naslov dokumenta, ne polje v lasti PIM; vzame se tista, ki je zahtevana.
    if (field.Section == "Item" && field.ElementName == "ItemID") return itemId;

    if (field.FieldKey is not null && values.TryGetValue(field.FieldKey, out var value) && !string.IsNullOrWhiteSpace(value))
      return value;

    if (intent != SaopIntent.Add) return null;
    return defaults.TryGetValue($"{field.Section}/{field.ElementName}", out var fallback) ? fallback : null;
  }

  static XElement Target(XElement item, Dictionary<string, XElement> sections, string section)
  {
    if (section == "Item") return item;
    if (!sections.TryGetValue(section, out var element)) sections[section] = element = new XElement(section);
    return element;
  }

  static string Format(SaopXmlField field, string raw)
  {
    var value = raw.Trim();
    switch (field.ValueFormat)
    {
      case "decimal4": return Decimal(field, value, 4);
      case "decimal8": return Decimal(field, value, 8);
      case "bool":
        // Kanonično je bit, SAOP pa hoče črko — in ne iste za obe polji: IsActive je 'D'/'N',
        // WebPublish 'd'/'N'. Zato črki nista izpeljani, ampak zapisani v pogodbi.
        if (TrueWords.Contains(value)) return field.TrueValue ?? throw new SaopXmlBuildException($"Polje {field.ElementName} nima zapisane vrednosti za DA.");
        if (FalseWords.Contains(value)) return field.FalseValue ?? throw new SaopXmlBuildException($"Polje {field.ElementName} nima zapisane vrednosti za NE.");
        throw new SaopXmlBuildException($"Polje {field.ElementName} ima vrednost '{value}', ki ni ne DA ne NE.");
      default: return value;
    }
  }

  static string Decimal(SaopXmlField field, string value, int decimals)
  {
    // Decimalke gredo v SAOP s piko in fiksnim številom mest; lokalna nastavitev strežnika
    // na to ne sme vplivati, sicer bi ista koda poslala '0,3800' in SAOP bi jo zavrnil.
    if (!decimal.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var number)
      && !decimal.TryParse(value, NumberStyles.Float, CultureInfo.GetCultureInfo("sl-SI"), out number))
      throw new SaopXmlBuildException($"Polje {field.ElementName} ima vrednost '{value}', ki ni število.");
    return number.ToString("F" + decimals.ToString(CultureInfo.InvariantCulture), CultureInfo.InvariantCulture);
  }

  /// <summary>Čas v obliki, v kakršni ga nosijo resnični dokumenti: ISO 8601 z Z in tremi decimalkami.</summary>
  static string Stamp(DateTime utc) =>
    DateTime.SpecifyKind(utc, DateTimeKind.Utc).ToString("yyyy-MM-ddTHH:mm:ss.fffZ", CultureInfo.InvariantCulture);

  static string Render(XElement root)
  {
    var builder = new StringBuilder();
    var settings = new XmlWriterSettings { Indent = true, IndentChars = "  ", OmitXmlDeclaration = true };
    using (var writer = XmlWriter.Create(builder, settings)) root.Save(writer);
    return builder.ToString();
  }

  /// <summary>
  /// SAOP hoče točno to deklaracijo. Stari sistem je iz istega razloga vsak dokument pred
  /// pošiljanjem obrezal in ji dodal svojo; brez nje odgovori niso bili zanesljivi.
  /// </summary>
  public static string WithUtf8Prolog(string? xml)
  {
    var body = (xml ?? string.Empty).TrimStart('﻿', ' ', '\t', '\r', '\n');
    if (body.StartsWith("<?xml", StringComparison.OrdinalIgnoreCase))
    {
      var end = body.IndexOf("?>", StringComparison.Ordinal);
      if (end >= 0) body = body[(end + 2)..].TrimStart();
    }
    return "<?xml version=\"1.0\" encoding=\"utf-8\"?>" + body;
  }
}
