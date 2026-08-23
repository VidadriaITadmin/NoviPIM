using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace PIM.Outbound;

/// <summary>Vrsta zavrnitve SAOP — po njej se odloči, kaj naj uporabnik naredi.</summary>
public enum SaopErrorKind
{
  /// <summary>Artikel v SAOP že obstaja; poslan je bil ADD namesto PATCH.</summary>
  ItemAlreadyExists,
  /// <summary>Artikla v SAOP ni; poslan je bil PATCH namesto ADD.</summary>
  ItemNotFound,
  /// <summary>Vrednost polja ni v šifrantu SAOP.</summary>
  CodebookMissing,
  /// <summary>Šifra dobavitelja ne obstaja ali ni aktivna.</summary>
  SupplierMissing,
  /// <summary>Poverilnica ali pravica; napaka ni na artiklu, ampak na integraciji.</summary>
  AuthConfig,
  /// <summary>Sporočila ne poznamo; pokaže se dobesedno.</summary>
  Unknown
}

/// <param name="Kind">Vrsta zavrnitve.</param>
/// <param name="Field">Polje dokumenta, ki ga je treba popraviti, kadar je znano.</param>
/// <param name="ItemIds">Šifre artiklov, ki jih je SAOP naštel v sporočilu.</param>
/// <param name="Summary">Kaj se je zgodilo, v enem stavku.</param>
/// <param name="Instruction">Kaj naj uporabnik naredi.</param>
/// <param name="IsSelfHealing">Ali zna PIM to popraviti sam, brez uporabnika.</param>
public sealed record SaopErrorAdvice(
  SaopErrorKind Kind,
  string? Field,
  IReadOnlyList<string> ItemIds,
  string Summary,
  string Instruction,
  bool IsSelfHealing);

/// <summary>
/// Prevede sporočilo SAOP v navodilo, ki ga urednik lahko izvede.
///
/// Vzorci niso ugibani: vseh 130 napak stare vrste (<c>PIM_test</c>) pade v šest skupin, dve
/// od njih pa sta <b>118 od 130</b> — poslan ADD za obstoječ artikel in poslan PATCH za
/// neobstoječega. To sta edini vrsti, ki ju zna PIM popraviti sam, zato sta označeni kot
/// <see cref="SaopErrorAdvice.IsSelfHealing"/>: uporabnika ni treba buditi zaradi napake,
/// ki je pravzaprav napačna izbira metode.
///
/// Ujemanje teče po besedilu brez šumnikov. Ne zaradi lepote: odgovori SAOP pridejo v
/// <c>windows-1250</c> in so bili v starem sistemu shranjeni pokvarjeni. Prepoznava, ki bi se
/// zanašala na 'š' in 'č', bi odpovedala natanko takrat, ko je najbolj potrebna.
/// </summary>
public static class SaopErrorTranslator
{
  static readonly Regex ItemIdPattern = new(@"\b[A-Z0-9]{2,}(?:\.[A-Z0-9]+)+\b", RegexOptions.Compiled);

  public static SaopErrorAdvice Translate(SaopError error)
  {
    ArgumentNullException.ThrowIfNull(error);
    var text = Normalize(error.Message);
    var items = ReadItemIds(error.Message);
    var naming = items.Count == 0 ? "artikel" : string.Join(", ", items);

    if (text.Contains("obstaja/obstajajo") || text.Contains("ze obstaja"))
      return new(SaopErrorKind.ItemAlreadyExists, null, items,
        $"SAOP ima artikel {naming} že zaveden, poslan pa je bil kot nov.",
        "Popravka ni treba delati ročno: PIM bo isto spremembo poslal znova kot spremembo obstoječega artikla (PATCH). Če se ponovi, artikel v SAOP verjetno obstaja pod drugo šifro — preveri po EAN.",
        IsSelfHealing: true);

    if (text.Contains("carinske tarife"))
      return new(SaopErrorKind.CodebookMissing, "GeneralData/CustomsTariffNo", items,
        $"Carinska tarifa artikla {naming} ni v šifrantu SAOP.",
        "Popravi carinsko tarifo na artiklu v PIM na obstoječo iz šifranta SAOP, ali naj jo skrbnik doda v SAOP (Šifranti → Carinske tarife). Dokler ne bo ene ali druge, bo vsak poskus vrnil isto.",
        IsSelfHealing: false);

    if (text.Contains("skupina artikla"))
      return new(SaopErrorKind.CodebookMissing, "GeneralData/ItemGroup", items,
        $"Skupina artikla {naming} ni v šifrantu SAOP.",
        "Popravi skupino artikla v PIM na eno izmed obstoječih v SAOP, ali naj jo skrbnik doda v SAOP (Šifranti → Skupine artiklov).",
        IsSelfHealing: false);

    if (text.Contains("tip artikla"))
      return new(SaopErrorKind.CodebookMissing, "GeneralData/ItemType", items,
        $"Tip artikla {naming} ni v šifrantu SAOP.",
        $"Nastavi tip artikla na eno izmed dovoljenih oznak. SAOP je v odgovoru naštel: {AllowedCodes(error.Message)}. Privzetek za nove artikle je nastavljen v out.SaopAddDefault.",
        IsSelfHealing: false);

    if (text.Contains("dobavitelja"))
      return new(SaopErrorKind.SupplierMissing, "StockData/SupplierID", items,
        $"Šifra dobavitelja artikla {naming} v SAOP ne obstaja ali ni aktivna.",
        "Preveri dobavitelja na artiklu v PIM. Če je šifra pravilna, je dobavitelj v SAOP najbrž neaktiven — naj ga skrbnik aktivira (Šifranti → Poslovni partnerji).",
        IsSelfHealing: false);

    if (text.Contains("ne obstaja") && text.Contains("artikla"))
      return new(SaopErrorKind.ItemNotFound, null, items,
        $"Artikla {naming} v SAOP ni, poslan pa je bil kot sprememba.",
        "Popravka ni treba delati ročno: PIM bo isto vsebino poslal znova kot nov artikel (ADD). Če se ponovi, šifra artikla v PIM ne ustreza šifri v SAOP.",
        IsSelfHealing: true);

    if (text.Contains("unauthorized") || text.Contains("ni pravic") || text.Contains("dostop zavrnjen"))
      return new(SaopErrorKind.AuthConfig, null, items,
        "SAOP je zavrnil poverilnico ali pravico integracije.",
        "To ni napaka artikla. Kanal se ustavi, da ne nastane ista napaka na vsakem artiklu posebej. Preveri uporabnika in geslo integracije ter njegove pravice v SAOP, nato kanal znova omogoči.",
        IsSelfHealing: false);

    return new(SaopErrorKind.Unknown, null, items,
      $"SAOP je zavrnil spremembo artikla {naming}.",
      $"Sporočilo SAOP: {error.Message}",
      IsSelfHealing: false);
  }

  /// <summary>
  /// Kadar je napaka takšna, da jo PIM zna popraviti sam, pove, s katero metodo naj poskusi znova.
  /// </summary>
  public static SaopIntent? Retry(SaopErrorAdvice advice) => advice.Kind switch
  {
    SaopErrorKind.ItemAlreadyExists => SaopIntent.Update,
    SaopErrorKind.ItemNotFound => SaopIntent.Add,
    _ => null
  };

  /// <summary>Iz seznama napak izbere tisto, ki uporabniku največ pove; prazen seznam ne obstaja.</summary>
  public static SaopErrorAdvice Translate(IReadOnlyList<SaopError> errors)
  {
    ArgumentNullException.ThrowIfNull(errors);
    if (errors.Count == 0)
      return new(SaopErrorKind.Unknown, null, [], "SAOP je zavrnil zahtevo brez pojasnila.",
        "Odgovor SAOP ne vsebuje sporočila o napaki. Poglej surov odgovor na sporočilu.", false);

    var advices = errors.Select(Translate).ToArray();
    // Znana napaka pove več od neznane; med znanimi je prva dovolj, ker SAOP vse naštete
    // napake nanaša na isti dokument.
    return advices.FirstOrDefault(advice => advice.Kind != SaopErrorKind.Unknown) ?? advices[0];
  }

  static IReadOnlyList<string> ReadItemIds(string message) =>
    ItemIdPattern.Matches(message).Select(match => match.Value).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();

  static string AllowedCodes(string message)
  {
    var marker = message.IndexOf("oznake:", StringComparison.OrdinalIgnoreCase);
    return marker < 0 ? "glej šifrant SAOP" : message[(marker + "oznake:".Length)..].Trim().TrimEnd('.');
  }

  /// <summary>Male črke brez šumnikov in brez nadomestnih znakov pokvarjenega kodiranja.</summary>
  static string Normalize(string value)
  {
    var lowered = value.ToLower(CultureInfo.GetCultureInfo("sl-SI"));
    var decomposed = lowered.Normalize(NormalizationForm.FormD);
    var builder = new StringBuilder(decomposed.Length);
    foreach (var character in decomposed)
    {
      var category = CharUnicodeInfo.GetUnicodeCategory(character);
      if (category == UnicodeCategory.NonSpacingMark) continue;
      // Znak '�' in vse nad ASCII odpade: tako se 'šifra' in 'ifra' ujameta enako.
      builder.Append(character <= 127 ? character : ' ');
    }
    return string.Join(' ', builder.ToString().Split(' ', StringSplitOptions.RemoveEmptyEntries));
  }
}
