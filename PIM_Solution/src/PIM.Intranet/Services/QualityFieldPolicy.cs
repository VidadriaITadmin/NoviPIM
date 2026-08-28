namespace PIM.Intranet.Services;

/// <param name="Label">Kratko ime cilja, kot ga uporabnik pozna iz menija.</param>
/// <param name="Href">Base-relativna pot ali <c>null</c>, kadar posebne strani za to polje ni.</param>
/// <param name="Label">Ime ciljne strani.</param>
/// <param name="Href">Pot do nje; null pomeni, da cilj ni dolocen.</param>
/// <param name="Explanation">Kaj uporabnik tam dejansko naredi. Uporabnik je 2026-08-28
/// zahteval, da stolpec »Kje se popravi« razlozi pomen vsakega vnosa — samo ime strani pove,
/// kam pelje povezava, ne pa, kaj tam naredis.</param>
public sealed record QualityFixTarget(string Label, string? Href, string Explanation = "");

/// <summary>
/// Kako se koda polja pokaze cloveku in kam ga posljemo, da jo popravi.
///
/// Zakaj obstaja: <c>val.FieldRequirement.FieldCode</c> je koda oblike
/// <c>Entiteta.Ime</c> (<c>ProductMedia.Url</c>, <c>ProductText.WEB_TITLE.sl</c>).
/// Register izvoznih stolpcev ima za nekatera polja tudi ime, a so ta imena imena
/// stolpcev v CSV (<c>ean</c>, <c>images</c>, <c>name</c>) in za polovico polj jih ni.
/// Zato prevajamo samo <b>predpono entitete</b>, ki je stabilna in pride iz imen
/// kanonicnih tabel; ime polja ostane tako, kot je v registru. Izmisljenega
/// slovenskega slovarja polj namenoma ni — razsel bi se z registrom.
/// </summary>
public static class QualityFieldPolicy
{
  /// <summary>Prevedena predpona entitete: »Medij« iz <c>ProductMedia.Url</c>.</summary>
  public static string EntityLabel(string? fieldCode) => Entity(fieldCode) switch
  {
    "Product" => "Izdelek",
    "ProductText" => "Besedilo",
    "ProductAttribute" => "Lastnost",
    "ProductCategory" => "Kategorija",
    "ProductMedia" => "Medij",
    "ProductDocument" => "Dokument",
    "ProductCommercial" => "Trgovinski podatki",
    "ProductPrice" => "Cena",
    "ProductStock" => "Zaloga",
    var other => other
  };

  /// <summary>Ime polja brez predpone entitete: <c>WEB_TITLE.sl</c> iz <c>ProductText.WEB_TITLE.sl</c>.</summary>
  public static string FieldName(string? fieldCode)
  {
    var value = fieldCode ?? string.Empty;
    var dot = value.IndexOf('.');
    return dot < 0 || dot == value.Length - 1 ? value : value[(dot + 1)..];
  }

  /// <summary>
  /// Stran, na kateri se to polje dejansko popravi. Vracamo samo poti, ki v aplikaciji
  /// res obstajajo; kadar posebne strani ni, ostane <c>null</c> in stran ponudi le napake.
  /// </summary>
  public static QualityFixTarget FixTarget(string? fieldCode)
  {
    var value = fieldCode ?? string.Empty;
    var entity = Entity(value);
    var name = FieldName(value);

    if (entity == "ProductMedia" || entity == "ProductDocument")
      return new("Mediji", "mediji", "dodaj sliko ali dokument temu izdelku");
    if (entity == "ProductCategory" || value.Contains("Category", StringComparison.OrdinalIgnoreCase))
      return new("Nepreslikane kategorije", "kakovost/kategorije", "poveži dobaviteljevo pot z našo kategorijo");

    // Besedilo v tujem jeziku je manjkajoc prevod; besedilo v slovenscini je manjkajoc vnos.
    if (entity == "ProductText")
      return IsForeignLanguage(name)
        ? new("Manjkajoči prevodi", "kakovost/prevodi", "vpiši prevod besedila v ta jezik")
        : new("Množično urejanje", "izvozi/mnozicno", "izvozi izdelke v Excel, dopolni stolpec in vrni datoteko");

    // 2026-08-28: pri spletu se lastnosti imenujejo atributi; ime je poenoteno povsod.
    if (entity == "ProductAttribute") return new("Atributi", "nastavitve/atributi", "vpiši vrednost atributa oziroma dodaj atribut v register");
    if (entity == "ProductPrice") return new("Cene", "cene", "uredi ceno oziroma cenik izdelka");
    if (entity == "ProductStock") return new("Zaloge", "zaloge", "preveri zalogovni vir in preslikavo skladišča");
    if (entity == "Product" || entity == "ProductCommercial")
      return new("Polja SAOP", "saop/polja", "vrednost je last SAOP; popravi se v ERP in pride nazaj z zajemom");
    return new("—", null, "za to polje ciljna stran še ni določena");
  }

  /// <summary>Napake tega polja, kot jih razume obstojeci filter na strani napak.</summary>
  public static string IssuesHref(string? fieldCode) =>
    "kakovost/napake?polje=" + Uri.EscapeDataString(fieldCode ?? string.Empty);

  static string Entity(string? fieldCode)
  {
    var value = fieldCode ?? string.Empty;
    var dot = value.IndexOf('.');
    return dot <= 0 ? value : value[..dot];
  }

  /// <summary>»WEB_TITLE.en« je tuj jezik, »WEB_TITLE.sl« in »WEB_TITLE« nista.</summary>
  static bool IsForeignLanguage(string fieldName)
  {
    var dot = fieldName.LastIndexOf('.');
    if (dot < 0 || dot == fieldName.Length - 1) return false;
    var language = fieldName[(dot + 1)..];
    return language.Length == 2 && !language.Equals("sl", StringComparison.OrdinalIgnoreCase);
  }
}
