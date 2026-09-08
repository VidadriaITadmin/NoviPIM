namespace PIM.Operations;

/// <summary>Kdo je lastnik stolpca in kam gre vrednost pri uvozu.</summary>
public enum ProductWorkbookTarget
{
  /// <summary>Uvoz stolpca ne bere. Je v listu, ker brez njega vrstice ni mogoče brati.</summary>
  ReadOnly,

  /// <summary>Podatek je last PIM; uvoz ga zapiše takoj.</summary>
  Pim,

  /// <summary>Podatek piše SAOP; uvoz ga uvrsti v odhodno vrsto in čaka odobritev.</summary>
  Saop,
}

/// <param name="FieldKey">Kanonična koda vrednosti. Hkrati drugi sprejeti naslov stolpca:
/// uporabnik, ki si naredi svojo datoteko, sme pisati kodo namesto slovenskega naslova.</param>
/// <param name="Aliases">Dodatni sprejeti naslovi (pri poljih SAOP ime elementa).</param>
/// <param name="IsMultiValue">Ali celica nosi seznam, ločen z »|«.</param>
public sealed record ProductWorkbookColumn(
  string Group,
  string Header,
  string FieldKey,
  ProductWorkbookTarget Target,
  WorkbookCellKind Kind = WorkbookCellKind.Text,
  double Width = 0,
  IReadOnlyList<string>? Aliases = null,
  bool IsMultiValue = false)
{
  /// <summary>Vsi naslovi, po katerih uvoz prepozna ta stolpec.</summary>
  public IEnumerable<string> AcceptedHeaders =>
    new[] { Header, FieldKey }.Concat(Aliases ?? []).Where(name => !string.IsNullOrWhiteSpace(name));
}

/// <param name="FieldKey">Kanonična koda, npr. <c>Product.UoM</c>.</param>
/// <param name="ElementName">Ime elementa v SAOP; drugi sprejeti naslov stolpca.</param>
/// <param name="Label">Slovenski naslov, če je znan; sicer ime elementa.</param>
public sealed record SaopWritableField(string FieldKey, string ElementName, string Label, string ValueFormat);

/// <param name="Code">Koda v <c>canon.WebSite</c>, npr. <c>svetila_si</c> ali <c>B2C</c>.</param>
/// <param name="Name">Ime, ki ga uporabnik bere in piše, npr. <c>Svetila.si</c>.</param>
public sealed record WorkbookWebSite(string Code, string Name);

/// <param name="Code">Koda atributa v <c>canon.ProductAttribute</c>.</param>
/// <param name="Name">Ime za naslov stolpca; kadar prevoda ni, je enako kodi.</param>
public sealed record WorkbookAttribute(string Code, string Name);

/// <param name="TextTypes">Vrste spletnih besedil brez ERP naziva, npr. WEB_TITLE, DESCRIPTION.</param>
/// <param name="Languages">Jeziki nazivov in opisov v vrstnem redu lista.</param>
public sealed record ProductWorkbookSpec(
  IReadOnlyList<SaopWritableField> SaopFields,
  IReadOnlyList<WorkbookWebSite> WebSites,
  IReadOnlyList<string> TextTypes,
  IReadOnlyList<string> Languages,
  IReadOnlyList<WorkbookAttribute> Attributes);

/// <param name="Column">Stolpec pogodbe; null pomeni naslov, ki mu ne ustreza noben stolpec.</param>
public sealed record ProductWorkbookHeaderMatch(int Index, string Header, ProductWorkbookColumn? Column);

/// <summary>
/// Ena sama pogodba stolpcev za izvoz in uvoz delovnega lista izdelkov.
///
/// Doslej sta bila izvoz in uvoz dva različna seznama. Izvoz »pregled« je imel slovenske
/// naslove (»Naziv ERP (sl)«), uvoz pa je poznal samo kanonične kode in imena elementov SAOP —
/// zato izvožene datoteke ni bilo mogoče vrniti nazaj: vsak stolpec razen šifre je padel med
/// neprepoznane. Ta razred je odgovor: <see cref="Build"/> vrne seznam, ki ga uporabita
/// <b>obe</b> smeri. Kar izvoz izpiše, uvoz prebere; naslov ne more zdrsniti samo na eni strani.
///
/// Vsak stolpec ve, kdo je njegov lastnik (<see cref="ProductWorkbookTarget"/>). Ločnica ni
/// mnenje te kode: polja SAOP prihajajo iz registra <c>out.SaopXmlField</c> in tam je zapisano,
/// katero polje sme PIM pisati. Uvoz zato ne piše ERP podatka mimo odhodne vrste — uvrsti ga
/// vanjo, kjer čaka odobritev.
///
/// Dve pravili, ki veljata povsod na listu:
///   1. <b>Prazna celica pomeni »tega polja se ne dotakni«</b>, ne »izprazni ga«. List ima
///      stotine stolpcev in večina celic je praznih; sicer bi en uvoz izbrisal cel katalog.
///   2. <b>Seznam v celici je ločen z »|«</b> — spletne strani, kategorije, slike. Podpičje je
///      odpadlo, ker se pojavlja v imenih kategorij.
/// </summary>
public static class ProductWorkbookContract
{
  public const string ListSeparator = "|";

  /// <summary>Kar piše v celici, kadar je vrednost logična.</summary>
  public const string Yes = "da";
  public const string No = "ne";

  public const string GroupKey = "Ključ";
  public const string GroupErp = "ERP — gre v vrsto za SAOP";
  public const string GroupWeb = "Splet — zapiše se takoj";
  public const string GroupAttributes = "Spletni atributi — zapišejo se takoj";
  public const string GroupState = "Stanje — samo za branje";

  /// <summary>Naslova, ki povesta, katera vrstica lista je naslovna vrstica.</summary>
  public static readonly string[] HeaderHints = ["Šifra artikla", "Podjetje", "ItemID"];

  public const string OrganizationField = "Row.OrganizationName";
  public const string ItemIdField = "Product.ItemID";
  public const string WebPublishField = "Product.WebPublish";
  public const string WebSitesField = "Product.WebSites";
  public const string CategoryFieldPrefix = "ProductCategory.";
  public const string TextFieldPrefix = "ProductText.";
  public const string AttributeFieldPrefix = "ProductAttribute.";

  /// <summary>Naslov stolpca kategorij za dano spletno stran.</summary>
  public static string CategoryHeader(WorkbookWebSite site) => $"Kategorije — {site.Name}";

  /// <summary>Kanonična koda stolpca kategorij za dano spletno stran.</summary>
  public static string CategoryFieldKey(string webSiteCode) => CategoryFieldPrefix + webSiteCode;

  /// <summary>Slovenski naslov vrste besedila; neznana vrsta ostane taka, kot je v podatkih.</summary>
  public static string TextTypeLabel(string textType) => textType.ToUpperInvariant() switch
  {
    "WEB_TITLE" => "Spletni naziv",
    "DESCRIPTION" => "Spletni opis",
    "SHORT_DESCRIPTION" => "Kratek spletni opis",
    "TITLE_ERP" => "Naziv ERP",
    _ => textType,
  };

  /// <summary>
  /// Stolpci delovnega lista. Vrstni red je vrstni red v datoteki in je namenoma tak, da so
  /// levo stvari, po katerih se vrstica najde, potem pa tisto, kar uporabnik vpisuje.
  /// </summary>
  public static IReadOnlyList<ProductWorkbookColumn> Build(ProductWorkbookSpec spec)
  {
    ArgumentNullException.ThrowIfNull(spec);
    var columns = new List<ProductWorkbookColumn>
    {
      // Podjetje je prvi stolpec, ker je šifra artikla enolična samo znotraj podjetja. Hkrati
      // je to stolpec, pod katerega WorkbookWriter zapiše opombe — zato ključ ni v njem.
      new(GroupKey, "Podjetje", OrganizationField, ProductWorkbookTarget.ReadOnly, Width: 18),
      new(GroupKey, "Šifra artikla", ItemIdField, ProductWorkbookTarget.ReadOnly, Width: 20,
        Aliases: ["ItemID", "Sifra artikla", "Šifra", "Artikel"]),
      new(GroupKey, "Naziv", "Row.Name", ProductWorkbookTarget.ReadOnly, Width: 44),
    };

    // --- ERP: stolpci pridejo iz registra, ne iz tega seznama ---------------------------
    // Če register dobi novo polje, ga dobi tudi list; če polje izgubi pravico pisanja, izgine
    // iz lista. Seznam v kodi bi se z registrom slej ko prej razšel.
    foreach (var field in spec.SaopFields)
      columns.Add(new(GroupErp, field.Label, field.FieldKey, ProductWorkbookTarget.Saop,
        field.ValueFormat is "decimal4" or "decimal8" ? WorkbookCellKind.Number : WorkbookCellKind.Text,
        Width: Math.Clamp(field.Label.Length + 3, 14, 32),
        Aliases: [field.ElementName]));

    // --- Splet: last PIM, zapiše se takoj ----------------------------------------------
    // Zastavice »Za splet« tu ni: register out.SaopXmlField jo pozna kot element WebPublish,
    // torej potuje v SAOP in mora skozi odhodno vrsto kot vsako drugo ERP polje. Dva stolpca
    // za isto polje bi bila pri uvozu dvoumna in bi eno vrednost pisala dvakrat, vsakič drugam.
    columns.Add(new(GroupWeb, "Spletne strani", WebSitesField, ProductWorkbookTarget.Pim, Width: 30,
      Aliases: ["Spletna stran", "Strani"], IsMultiValue: true));

    foreach (var site in spec.WebSites)
      columns.Add(new(GroupWeb, CategoryHeader(site), CategoryFieldKey(site.Code), ProductWorkbookTarget.Pim,
        Width: 44, Aliases: [$"Kategorije {site.Code}"], IsMultiValue: true));

    foreach (var textType in spec.TextTypes)
      foreach (var language in spec.Languages)
        columns.Add(new(GroupWeb, $"{TextTypeLabel(textType)} ({language})",
          $"{TextFieldPrefix}{textType}.{language}", ProductWorkbookTarget.Pim,
          Width: textType.Contains("DESCRIPTION", StringComparison.OrdinalIgnoreCase) ? 48 : 34));

    columns.Add(new(GroupWeb, "Slike", "ProductMedia.Url", ProductWorkbookTarget.ReadOnly, Width: 44,
      IsMultiValue: true));

    // --- Atributi ----------------------------------------------------------------------
    foreach (var attribute in spec.Attributes)
      columns.Add(new(GroupAttributes, attribute.Name, AttributeFieldPrefix + attribute.Code,
        ProductWorkbookTarget.Pim, Width: Math.Clamp(attribute.Name.Length + 3, 14, 32),
        Aliases: ["Attr." + attribute.Code]));

    // --- Stanje ------------------------------------------------------------------------
    columns.Add(new(GroupState, "ERP", "Row.ErpStatus", ProductWorkbookTarget.ReadOnly, Width: 16));
    columns.Add(new(GroupState, "Splet", "Row.WebStatus", ProductWorkbookTarget.ReadOnly, Width: 16));
    columns.Add(new(GroupState, "Popolnost", "Row.Completeness", ProductWorkbookTarget.ReadOnly, WorkbookCellKind.Percent, 12));
    columns.Add(new(GroupState, "Odprte težave", "Row.OpenIssueCount", ProductWorkbookTarget.ReadOnly, WorkbookCellKind.Number, 14));
    columns.Add(new(GroupState, "Zadnja sprememba", "Row.LastChangedUtc", ProductWorkbookTarget.ReadOnly, WorkbookCellKind.DateTime, 18));

    return Disambiguate(columns);
  }

  /// <summary>
  /// Dva stolpca z istim naslovom sta pri uvozu dvoumna: drugi bi bil tiho prezrt in uporabnik
  /// bi vpisoval v celico, ki nikamor ne gre. Do tega pride, ker imena atributov niso ločena od
  /// slovenskih oznak polj SAOP — atribut »Garancija« in element z isto oznako sta dva stolpca.
  /// Kdor pride drugi, dobi za naslov še svojo kanonično kodo; s tem je naslov spet enoličen in
  /// hkrati pove, od kod vrednost pride.
  /// </summary>
  static IReadOnlyList<ProductWorkbookColumn> Disambiguate(IReadOnlyList<ProductWorkbookColumn> columns)
  {
    var used = new HashSet<string>(StringComparer.Ordinal);
    var result = new List<ProductWorkbookColumn>(columns.Count);
    foreach (var column in columns)
    {
      var header = column.Header;
      if (!used.Add(WorkbookHeader.Normalize(header)))
      {
        header = $"{column.Header} [{column.FieldKey}]";
        used.Add(WorkbookHeader.Normalize(header));
      }
      result.Add(column with { Header = header });
    }
    return result;
  }

  /// <summary>
  /// Poveže naslove iz datoteke s stolpci pogodbe. Kar se ne ujame, dobi <c>Column = null</c> —
  /// uvoz to izpiše, namesto da bi tiho spregledal stolpec, ki ga je uporabnik izpolnjeval.
  /// </summary>
  public static IReadOnlyList<ProductWorkbookHeaderMatch> Match(
    IReadOnlyList<string> headers, IReadOnlyList<ProductWorkbookColumn> columns)
  {
    ArgumentNullException.ThrowIfNull(headers);
    ArgumentNullException.ThrowIfNull(columns);

    var byHeader = new Dictionary<string, ProductWorkbookColumn>(StringComparer.Ordinal);
    foreach (var column in columns)
      foreach (var accepted in column.AcceptedHeaders)
      {
        var key = WorkbookHeader.Normalize(accepted);
        // Prvi stolpec, ki si naslov lasti, ga obdrži. Dvoumnost se rešuje v pogodbi, ne tu.
        if (key.Length > 0) byHeader.TryAdd(key, column);
      }

    var used = new HashSet<string>(StringComparer.Ordinal);
    var matches = new List<ProductWorkbookHeaderMatch>(headers.Count);
    for (var index = 0; index < headers.Count; index++)
    {
      var key = WorkbookHeader.Normalize(headers[index]);
      // Isti naslov dvakrat v datoteki: upošteva se prvi. Drugi bi tiho povozil prvega.
      var column = key.Length > 0 && byHeader.TryGetValue(key, out var found) && used.Add(key) ? found : null;
      matches.Add(new(index, headers[index], column));
    }
    return matches;
  }

  /// <summary>Razbije celico s seznamom; prazna celica da prazen seznam.</summary>
  public static IReadOnlyList<string> SplitList(string? cell) =>
    string.IsNullOrWhiteSpace(cell)
      ? []
      : cell.Split(ListSeparator, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
          .Distinct(StringComparer.OrdinalIgnoreCase).ToArray();

  /// <summary>Sestavi celico iz seznama; prazen seznam da prazno celico.</summary>
  public static string? JoinList(IEnumerable<string>? values)
  {
    var list = (values ?? []).Where(value => !string.IsNullOrWhiteSpace(value)).Select(value => value.Trim()).ToArray();
    return list.Length == 0 ? null : string.Join(" " + ListSeparator + " ", list);
  }

  /// <summary>
  /// Prebere logično celico. Sprejme, kar ljudje res pišejo; česar ne razume, vrne kot null in
  /// uvoz to prijavi kot napako vrstice — tiho ugibanje bi objavilo napačne izdelke.
  /// </summary>
  public static bool? ParseYesNo(string? cell) => WorkbookHeader.Normalize(cell) switch
  {
    "da" or "ja" or "1" or "true" or "yes" or "x" or "ok" => true,
    "ne" or "0" or "false" or "no" => false,
    _ => null,
  };

  public static string YesNo(bool value) => value ? Yes : No;
}
