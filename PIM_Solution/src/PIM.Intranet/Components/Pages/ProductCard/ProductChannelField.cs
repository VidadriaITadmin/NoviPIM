namespace PIM.Intranet.Components.Pages.ProductCardParts;

/// <summary>Kam gre sprememba polja. Ločnica ni okrasna: od nje je odvisno, ali vrednost potuje
/// skozi odhodno vrsto z odobritvijo ali naravnost v PIM. Kartica jo izbere sama iz registra
/// <c>out.SaopXmlField</c> — uporabnik ne izbira poti, samo vidi, kam bo šla sprememba.</summary>
public enum ProductFieldEdit
{
  /// <summary>Ni urejivo na kartici; <see cref="ProductChannelField.LockReason"/> pove zakaj in kje se ureja.</summary>
  None,

  /// <summary>Polje, ki ga PIM piše nazaj v SAOP; v PIM velja takoj, v SAOP gre po odobritvi.</summary>
  Saop,

  /// <summary>Besedilo, ki se piše naravnost v katalog PIM.</summary>
  Text,

  /// <summary>Lastnost izdelka; piše se naravnost v katalog.</summary>
  Attribute,
}

/// <param name="Edit">Kam gre sprememba; <see cref="ProductFieldEdit.None"/> pomeni samo prikaz.</param>
/// <param name="Format">text, multiline, decimal ali bool — določi kontrolo v obrazcu.</param>
/// <param name="Required">Polje ima odprto napako (ERROR) — objavo ustavi.</param>
/// <param name="Missing">Polje je prazno; obrazec ga pokaže tudi, če vrstice v katalogu ni.</param>
/// <param name="Recommended">Polje ima samo opozorilo (WARNING) — priporočeno, objave ne ustavi.</param>
/// <param name="SaopOrigin">
/// Vrednost pride iz SAOP, SAOP pa je od PIM ne sprejme (ni v registru pisljivih polj). Sprememba
/// velja v PIM, ob naslednjem zajemu tega artikla jo SAOP lahko prepiše — kartica to pove ob polju.
/// </param>
/// <param name="LockReason">Pri <see cref="ProductFieldEdit.None"/>: zakaj polja ni mogoče urediti tu in kje se ureja.</param>
public sealed record ProductChannelField(
  string Label, string FieldKey, string? Value, string Owner, string? Source,
  DateTime? FreshnessUtc, bool Pending, bool InReadModel = true,
  ProductFieldEdit Edit = ProductFieldEdit.None, string Format = "text",
  bool Required = false, bool Missing = false,
  string? Language = null, string? TextType = null, string? AttributeCode = null,
  string? Hint = null, bool Recommended = false,
  bool SaopOrigin = false, string? LockReason = null, string? PendingStatus = null);
