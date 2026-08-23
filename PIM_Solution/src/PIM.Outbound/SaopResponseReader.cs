using System.Text;
using System.Xml.Linq;

namespace PIM.Outbound;

/// <summary>Izid, kot ga pove SAOP sam — ne HTTP koda.</summary>
public enum SaopResultCode { None, Ok, Created, Error, Conflict, Unauthorized, NotFound, Unknown }

public sealed record SaopError(string Level, string Message);

/// <param name="AssignedItemId">Šifra, ki jo je SAOP dodelil ob ustvarjanju artikla, če jo je.</param>
public sealed record SaopResponse(
  SaopResultCode ResultCode,
  string? AssignedItemId,
  IReadOnlyList<SaopError> Errors,
  bool IsSuccess);

/// <summary>
/// Bere odgovor SAOP na ADD ali PATCH.
///
/// Dve stvari, ki ju je stari sistem naredil narobe in se tu ne ponovita:
///
/// 1. <b>Dodeljena šifra.</b> Stari worker jo je iskal kot element <c>ItemID</c>. SAOP je
///    nikoli ni tako vrnil — vrne jo kot <c>Keys/Key[Name='SifraArtikla']/Value</c>. Zato je
///    stolpec <c>AssignedItemID</c> v stari vrsti ostajal prazen, čeprav je SAOP šifro povedal.
///
/// 2. <b>HTTP 200 ni dokaz.</b> Odgovor nosi svoj <c>ResultCode</c>
///    (<c>None|Error|Ok|Conflict|Created|Unauthorized|NotFound</c>). Uspeh sta samo <c>Ok</c>
///    in <c>Created</c>; vse drugo je zavrnitev, tudi kadar je HTTP koda 200.
///
/// Napake pridejo v dveh oblikah: kot <c>Errors</c> znotraj <c>CreateResult</c>/<c>UpdateResult</c>
/// ali — kot v vseh 130 resničnih napakah stare vrste — kot samostojen <c>ArrayOfError</c> ob
/// HTTP 409.
/// </summary>
public static class SaopResponseReader
{
  /// <summary>Ime ključa, pod katerim SAOP vrne dodeljeno šifro artikla.</summary>
  const string AssignedKeyName = "SifraArtikla";

  public static SaopResponse Read(string? xml)
  {
    if (string.IsNullOrWhiteSpace(xml))
      return new(SaopResultCode.Unknown, null, [], false);

    XElement root;
    try { root = XDocument.Parse(xml).Root ?? throw new InvalidOperationException(); }
    catch (Exception)
    {
      // Odgovor, ki ni XML, je še vedno odgovor. Ne sme podreti obdelave, mora pa šteti
      // kot neuspeh — sicer bi neberljiv odgovor veljal za potrjeno spremembo.
      return new(SaopResultCode.Unknown, null, [new("ParseError", Shorten(xml))], false);
    }

    var errors = ReadErrors(root);
    var resultCode = ReadResultCode(root, errors.Count);
    var assigned = ReadAssignedItemId(root);
    var success = resultCode is SaopResultCode.Ok or SaopResultCode.Created && errors.Count == 0;
    return new(resultCode, assigned, errors, success);
  }

  static SaopResultCode ReadResultCode(XElement root, int errorCount)
  {
    var text = Local(root, "ResultCode")?.Value?.Trim();
    if (!string.IsNullOrEmpty(text) && Enum.TryParse<SaopResultCode>(text, ignoreCase: true, out var parsed)) return parsed;
    if (!string.IsNullOrEmpty(text)) return SaopResultCode.Unknown;
    // ArrayOfError nima ResultCode; sam obstoj ovoja pomeni zavrnitev.
    return errorCount > 0 ? SaopResultCode.Error : SaopResultCode.Unknown;
  }

  static IReadOnlyList<SaopError> ReadErrors(XElement root) =>
    root.Descendants().Where(element => element.Name.LocalName == "Error")
      .Select(element => new SaopError(
        Local(element, "Level")?.Value?.Trim() ?? "Error",
        Local(element, "Message")?.Value?.Trim()
          ?? Local(element, "Description")?.Value?.Trim()
          ?? element.Value.Trim()))
      .Where(error => error.Message.Length > 0)
      .ToArray();

  static string? ReadAssignedItemId(XElement root)
  {
    var keys = root.Descendants().Where(element => element.Name.LocalName == "Key").ToArray();
    var named = keys.FirstOrDefault(key =>
      string.Equals(Local(key, "Name")?.Value?.Trim(), AssignedKeyName, StringComparison.OrdinalIgnoreCase));
    var value = Local(named ?? (keys.Length == 1 ? keys[0] : null), "Value")?.Value?.Trim();
    return string.IsNullOrWhiteSpace(value) ? null : value;
  }

  static XElement? Local(XElement? parent, string name) =>
    parent?.Descendants().FirstOrDefault(element => element.Name.LocalName == name);

  static string Shorten(string value) =>
    value.Length <= 500 ? value.Trim() : value[..500].Trim() + " …";

  /// <summary>
  /// Pretvori surove bajte odgovora v besedilo.
  ///
  /// Zakaj to sploh obstaja: v stari vrsti so sporočila SAOP shranjena kot
  /// »<c>šifra carinske tarife</c>« namesto »šifra carinske tarife«. Odgovor je bil prebran
  /// kot UTF-8, čeprav to ni bil. Uporabnik bi tako namesto navodila dobil zmazek, iskanje po
  /// napakah pa ne bi delovalo.
  ///
  /// Vrstni red je zato: kodiranje iz glave <c>Content-Type</c>, sicer strogi UTF-8, in šele
  /// ko ta na bajtih ne vzdrži, <c>windows-1250</c> — kodna stran, ki jo SAOP iCenter uporablja
  /// za slovenščino.
  /// </summary>
  public static string DecodeBody(byte[] body, string? charset = null)
  {
    ArgumentNullException.ThrowIfNull(body);
    if (body.Length == 0) return string.Empty;

    if (!string.IsNullOrWhiteSpace(charset))
    {
      var declared = TryGetEncoding(charset!);
      if (declared is not null) return declared.GetString(body);
    }

    try { return new UTF8Encoding(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true).GetString(body); }
    catch (DecoderFallbackException) { return (TryGetEncoding("windows-1250") ?? Encoding.Latin1).GetString(body); }
  }

  static Encoding? TryGetEncoding(string name)
  {
    try
    {
      // windows-1250 v .NET Core ni vgrajen; brez te registracije bi tiho padli na Latin1
      // in izgubili š, č in ž.
      Encoding.RegisterProvider(System.Text.CodePagesEncodingProvider.Instance);
      return Encoding.GetEncoding(name.Trim().Trim('"'));
    }
    catch (ArgumentException) { return null; }
    catch (NotSupportedException) { return null; }
  }
}
