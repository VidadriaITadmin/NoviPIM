using System.Globalization;
using System.Text;
using System.Xml;
using System.Xml.Linq;

namespace PIM.Outbound;

/// <summary>
/// Ali gre za nov zapis ali za spremembo obstoječega. Metoda in pot sta odvisni od tega,
/// pri strankah pa tudi koren dokumenta.
/// </summary>
public enum SaopIntent { Add, Update }

/// <summary>
/// Oblika dokumenta ene entitete, tako kot jo opisuje <c>out.SaopDocument</c>.
/// </summary>
/// <param name="RootElementAdd">Koren ob ustvarjanju; pri strankah se razlikuje od korena spremembe.</param>
/// <param name="ItemElement">Gnezdeni ovoj pod korenom; <c>null</c> pomeni plosk dokument.</param>
/// <param name="KeyElements">Elementi naravnega ključa; vrednosti pridejo iz ključa entitete.</param>
/// <param name="SuggestCodeElement">Element, s katerim šifro dodeli SAOP; <c>null</c>, kadar entiteta tega ne pozna.</param>
public sealed record SaopDocumentShape(
  string TargetKind,
  string EntityType,
  string RootElementAdd,
  string RootElementUpdate,
  string? ItemElement,
  IReadOnlyList<string> KeyElements,
  string AddPath,
  string AddOperation,
  string UpdatePath,
  string UpdateOperation,
  string? StampAddElement,
  string? StampUpdateElement,
  string? SuggestCodeElement)
{
  /// <summary>Ločilo sestavljenega ključa; cena je naslovljena s <c>PriceListId|ItemCode</c>.</summary>
  public const char KeySeparator = '|';

  public string Path(SaopIntent intent) => intent == SaopIntent.Add ? AddPath : UpdatePath;
  public string Operation(SaopIntent intent) => intent == SaopIntent.Add ? AddOperation : UpdateOperation;
  public string RootElement(SaopIntent intent) => intent == SaopIntent.Add ? RootElementAdd : RootElementUpdate;
  public string? StampElement(SaopIntent intent) => intent == SaopIntent.Add ? StampAddElement : StampUpdateElement;
}

/// <summary>En element dokumenta, tak, kot ga opisuje <c>out.SaopXmlField</c>.</summary>
/// <param name="Section"><c>Item</c> pomeni neposredno pod korenom oziroma pod ovojem; sicer ime podovoja.</param>
/// <param name="FieldKey">Kanonična koda; <c>null</c> pomeni, da vrednost pride iz privzetkov.</param>
/// <param name="IsKey">Element naravnega ključa; vrednost pride iz ključa, ne iz podatkov.</param>
public sealed record SaopXmlField(
  string Section,
  string ElementName,
  string? FieldKey,
  int SortOrder,
  bool IsAddMandatory,
  string ValueFormat,
  string? TrueValue,
  string? FalseValue,
  bool IsKey = false);

/// <param name="MissingMandatory">
/// Obvezna polja brez vrednosti pri ustvarjanju. Dokument se vseeno sestavi — da ga je mogoče
/// pogledati — pošiljati pa ga ni smiselno, ker ga SAOP zavrne.
/// </param>
public sealed record SaopXmlBuildResult(string Xml, IReadOnlyList<string> MissingMandatory, int ElementCount);

public sealed class SaopXmlBuildException(string message) : InvalidOperationException(message);

/// <summary>
/// Sestavi dokument za SAOP iCenter API za katerokoli entiteto: izdelek, stranko, cenik ali ceno.
///
/// Oblika ni vzeta iz swaggerja — ta pove imena tipov, ne pa vrstnega reda elementov in ne tega,
/// kaj SAOP dejansko sprejme. Vzeta je iz resničnih dokumentov, ki jih je stari sistem poslal in
/// je SAOP nanje odgovoril (<c>PIM_test</c>), in iz preglednice <c>Mapiranje_SAOP_API_PIM.xlsx</c>.
///
/// Razlika med ustvarjanjem in spremembo ni le metoda:
///   ustvarjanje nosi žig, vsa obvezna polja in po želji element, s katerim šifro dodeli SAOP;
///   sprememba  nosi <b>samo izpolnjena polja</b>. Vsako poslano polje SAOP prepiše, zato bi
///              polje brez vrednosti pomenilo tiho brisanje podatka v ERP. Iz istega razloga se
///              privzetki ob spremembi ne vstavljajo: konstanta bi povozila vrednost, ki jo SAOP
///              že ima in je PIM nikoli ni videl.
/// </summary>
public sealed class SaopDocumentBuilder
{
  static readonly HashSet<string> TrueWords = new(StringComparer.OrdinalIgnoreCase) { "1", "true", "d", "y", "da" };
  static readonly HashSet<string> FalseWords = new(StringComparer.OrdinalIgnoreCase) { "0", "false", "n", "ne" };

  /// <summary>Ovoj, ki pomeni »neposredno pod korenom oziroma pod gnezdenim ovojem«.</summary>
  const string RootSection = "Item";

  readonly SaopDocumentShape shape;
  readonly IReadOnlyList<SaopXmlField> contract;

  public SaopDocumentBuilder(SaopDocumentShape shape, IEnumerable<SaopXmlField> contract)
  {
    ArgumentNullException.ThrowIfNull(shape);
    this.shape = shape;
    this.contract = contract.OrderBy(field => field.SortOrder).ToArray();
    if (this.contract.Count == 0) throw new SaopXmlBuildException($"Pogodba za {shape.TargetKind} je prazna.");
    if (shape.KeyElements.Count == 0) throw new SaopXmlBuildException($"Dokument {shape.TargetKind} nima naravnega ključa.");

    var keys = this.contract.Where(field => field.IsKey).Select(field => field.ElementName).ToArray();
    if (keys.Length != shape.KeyElements.Count)
      throw new SaopXmlBuildException($"Dokument {shape.TargetKind} ima {shape.KeyElements.Count} ključnih elementov, pogodba pa {keys.Length}.");
  }

  /// <param name="entityKey">Naravni ključ; sestavljen ključ je ločen z <see cref="SaopDocumentShape.KeySeparator"/>.</param>
  /// <param name="values">Vrednosti po <c>FieldKey</c>; prazne se izpustijo.</param>
  /// <param name="defaults">Privzetki po ključu <c>Ovoj/Element</c>; upoštevajo se samo pri ustvarjanju.</param>
  public SaopXmlBuildResult Build(
    SaopIntent intent,
    string entityKey,
    IReadOnlyDictionary<string, string?> values,
    IReadOnlyDictionary<string, string> defaults,
    DateTime stampUtc,
    bool suggestFirstFreeCode = false)
  {
    var keyValues = SplitKey(entityKey);

    // Pri ploskem dokumentu je koren hkrati nosilec polj; pri gnezdenem je nosilec ovoj.
    var root = new XElement(shape.RootElement(intent));
    var carrier = shape.ItemElement is null ? root : new XElement(shape.ItemElement);
    var sections = new Dictionary<string, XElement>(StringComparer.Ordinal);
    var sectionOrder = new List<string>();
    var missing = new List<string>();
    var elementCount = 0;
    var stampWritten = false;

    foreach (var field in contract)
    {
      var raw = Resolve(intent, field, keyValues, values, defaults);
      if (string.IsNullOrWhiteSpace(raw))
      {
        // Manjkajoče polje ustavi samo ustvarjanje. Pri spremembi je odsotnost polja njegov
        // pomen: »tega ne spreminjam«, ne »izbriši«.
        if (intent == SaopIntent.Add && field.IsAddMandatory) missing.Add($"{field.Section}/{field.ElementName}");
        continue;
      }

      Target(carrier, sections, sectionOrder, field.Section).Add(new XElement(field.ElementName, Format(field, raw!)));
      elementCount++;

      // Žig gre takoj za ključem, ker tako stoji v vseh resničnih dokumentih.
      if (!stampWritten && field.IsKey && shape.StampElement(intent) is { } stampElement)
      {
        carrier.Add(new XElement(stampElement, Stamp(stampUtc)));
        stampWritten = true;
      }
    }

    // Ovoji se dodajo šele zdaj in samo tisti z vsebino: prazen ovoj je za SAOP veljaven
    // dokument, ki ne naredi ničesar, v pregledu pa izgleda kot poslana sprememba.
    foreach (var section in sectionOrder)
      if (sections.TryGetValue(section, out var element) && element.HasElements) carrier.Add(element);

    if (intent == SaopIntent.Add && suggestFirstFreeCode && shape.SuggestCodeElement is { } suggestElement)
      carrier.Add(new XElement(suggestElement, "true"));

    if (!ReferenceEquals(carrier, root)) root.Add(carrier);
    return new(WithUtf8Prolog(Render(root)), missing, elementCount);
  }

  /// <summary>
  /// Ključ v vrednosti posameznih ključnih elementov. Sestavljen ključ mora imeti natanko toliko
  /// delov, kolikor je ključnih elementov — manj bi pomenilo dokument, ki naslavlja napačen zapis.
  /// </summary>
  Dictionary<string, string> SplitKey(string entityKey)
  {
    if (string.IsNullOrWhiteSpace(entityKey))
      throw new SaopXmlBuildException("Brez naravnega ključa dokumenta ni mogoče nasloviti.");

    var parts = entityKey.Split(SaopDocumentShape.KeySeparator);
    if (parts.Length != shape.KeyElements.Count)
      throw new SaopXmlBuildException(
        $"Ključ '{entityKey}' ima {parts.Length} delov, dokument {shape.TargetKind} pa jih pričakuje {shape.KeyElements.Count}.");

    var result = new Dictionary<string, string>(StringComparer.Ordinal);
    for (var index = 0; index < parts.Length; index++)
    {
      var part = parts[index].Trim();
      if (part.Length == 0) throw new SaopXmlBuildException($"Del ključa '{shape.KeyElements[index]}' je prazen.");
      result[shape.KeyElements[index]] = part;
    }
    return result;
  }

  string? Resolve(
    SaopIntent intent,
    SaopXmlField field,
    IReadOnlyDictionary<string, string> keyValues,
    IReadOnlyDictionary<string, string?> values,
    IReadOnlyDictionary<string, string> defaults)
  {
    // Ključ je naslov dokumenta, ne polje v lasti PIM; vzame se tisti, ki je bil zahtevan.
    if (field.IsKey) return keyValues.GetValueOrDefault(field.ElementName);

    if (field.FieldKey is not null && values.TryGetValue(field.FieldKey, out var value) && !string.IsNullOrWhiteSpace(value))
      return value;

    if (intent != SaopIntent.Add) return null;
    return defaults.TryGetValue($"{field.Section}/{field.ElementName}", out var fallback) ? fallback : null;
  }

  static XElement Target(XElement carrier, Dictionary<string, XElement> sections, List<string> order, string section)
  {
    if (section == RootSection) return carrier;
    if (!sections.TryGetValue(section, out var element))
    {
      sections[section] = element = new XElement(section);
      // Vrstni red ovojev je vrstni red njihovega prvega polja, torej vrstni red iz pogodbe.
      order.Add(section);
    }
    return element;
  }

  static string Format(SaopXmlField field, string raw)
  {
    var value = raw.Trim();
    return field.ValueFormat switch
    {
      "decimal4" => Decimal(field, value, 4),
      "decimal8" => Decimal(field, value, 8),
      // Kanonično je bit, SAOP pa hoče svojo obliko — in ne iste za vsa polja: IsActive je
      // 'D'/'N', WebPublish 'd'/'N', cene in ceniki 'true'/'false'. Zato sta obliki zapisani
      // v pogodbi in ne izpeljani.
      "bool" => TrueWords.Contains(value)
          ? field.TrueValue ?? throw new SaopXmlBuildException($"Polje {field.ElementName} nima zapisane vrednosti za DA.")
          : FalseWords.Contains(value)
            ? field.FalseValue ?? throw new SaopXmlBuildException($"Polje {field.ElementName} nima zapisane vrednosti za NE.")
            : throw new SaopXmlBuildException($"Polje {field.ElementName} ima vrednost '{value}', ki ni ne DA ne NE."),
      _ => value
    };
  }

  static string Decimal(SaopXmlField field, string value, int decimals)
  {
    // Decimalke gredo v SAOP s piko in fiksnim številom mest; nastavitev strežnika na to ne sme
    // vplivati, sicer bi ista koda poslala '0,3800' in SAOP bi jo zavrnil.
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
  /// pošiljanjem obrezal in mu dodal svojo; brez nje odgovori niso bili zanesljivi.
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
