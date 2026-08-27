namespace PIM.Intranet.Components.Pages.ProductCardParts;

/// <summary>Kam gre sprememba polja. Ločnica ni okrasna: od nje je odvisno, ali vrednost potuje
/// skozi odhodno vrsto z odobritvijo ali naravnost v PIM.</summary>
public enum ProductFieldEdit
{
  /// <summary>Ni urejivo — vrednost pripada viru, ki ga PIM ne piše.</summary>
  None,

  /// <summary>Polje, ki ga PIM piše nazaj v SAOP; sprememba gre v odhodno vrsto.</summary>
  Saop,

  /// <summary>Besedilo, ki je last PIM (spletni naziv, opis); piše se naravnost v katalog.</summary>
  Text,

  /// <summary>Lastnost izdelka; piše se naravnost v katalog.</summary>
  Attribute,
}

/// <param name="Edit">Kam gre sprememba; <see cref="ProductFieldEdit.None"/> pomeni samo prikaz.</param>
/// <param name="Format">text, multiline, decimal ali bool — določi kontrolo v obrazcu.</param>
/// <param name="Required">Ali zahteva obstaja v validacijskem profilu, ki blokira.</param>
/// <param name="Missing">Polje je zahtevano in prazno; obrazec ga pokaže tudi, če vrstice v katalogu ni.</param>
public sealed record ProductChannelField(
  string Label, string FieldKey, string? Value, string Owner, string? Source,
  DateTime? FreshnessUtc, bool Pending, bool InReadModel = true,
  ProductFieldEdit Edit = ProductFieldEdit.None, string Format = "text",
  bool Required = false, bool Missing = false,
  string? Language = null, string? TextType = null, string? AttributeCode = null,
  string? Hint = null);
