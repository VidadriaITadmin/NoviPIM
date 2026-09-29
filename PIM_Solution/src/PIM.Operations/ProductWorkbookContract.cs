namespace PIM.Operations;

/// <summary>Kdo je lastnik stolpca in kam gre vrednost pri uvozu.</summary>
public enum ProductWorkbookTarget
{
  /// <summary>Uvoz stolpca ne bere. Je v listu, ker brez njega vrstice ni mogoče brati.</summary>
  ReadOnly,

  /// <summary>Podatek je last PIM; uvoz ga zapiše takoj.</summary>
  Pim,

  /// <summary>
  /// Podatek je last SAOP (register <c>out.SaopXmlField</c>). Uvoz ga zapiše v PIM takoj IN ga
  /// uvrsti v odhodno vrsto za SAOP, kjer čaka odobritev. Do 245 je šel samo v vrsto in se je v
  /// PIM pokazal šele, ko ga je zajem prinesel nazaj iz SAOP; uporabnik 2026-09-22: »ERP brez
  /// čakanja SAOPa«.
  /// </summary>
  Saop,
}

/// <param name="FieldKey">Kanonična koda vrednosti. Hkrati drugi sprejeti naslov stolpca:
/// uporabnik, ki si naredi svojo datoteko, sme pisati kodo namesto slovenskega naslova.</param>
/// <param name="Aliases">Dodatni sprejeti naslovi (pri poljih SAOP ime elementa).</param>
/// <param name="IsMultiValue">Ali celica nosi seznam, ločen z »|«.</param>
/// <param name="ValueFormat">Oblika vrednosti iz registra SAOP (<c>text</c>, <c>decimal4</c>,
/// <c>decimal8</c>, <c>bool</c>); null pri stolpcih, ki niso ERP.</param>
public sealed record ProductWorkbookColumn(
  string Group,
  string Header,
  string FieldKey,
  ProductWorkbookTarget Target,
  WorkbookCellKind Kind = WorkbookCellKind.Text,
  double Width = 0,
  IReadOnlyList<string>? Aliases = null,
  bool IsMultiValue = false,
  string? ValueFormat = null)
{
  /// <summary>Vsi naslovi, po katerih uvoz prepozna ta stolpec.</summary>
  public IEnumerable<string> AcceptedHeaders =>
    new[] { Header, FieldKey }.Concat(Aliases ?? []).Where(name => !string.IsNullOrWhiteSpace(name));

  /// <summary>Logično polje (da/ne): primerja se po pomenu, ne po zapisu (»da« je isto kot »1«).</summary>
  public bool IsBool => string.Equals(ValueFormat, "bool", StringComparison.OrdinalIgnoreCase);

  /// <summary>Številsko polje: primerja se po vrednosti (»1.5« je isto kot »1,5000«). Vse drugo je
  /// besedilo in se primerja točno — »02« ni »2« (DDV, dobavitelj, skupine so šifre).</summary>
  public bool IsNumber => ValueFormat is "decimal4" or "decimal8";
}

/// <param name="FieldKey">Kanonična koda, npr. <c>Product.UoM</c>.</param>
/// <param name="ElementName">Ime elementa v SAOP; drugi sprejeti naslov stolpca.</param>
/// <param name="Label">Slovenski naslov, če je znan; sicer ime elementa.</param>
public sealed record SaopWritableField(string FieldKey, string ElementName, string Label, string ValueFormat);

/// <param name="Code">Koda v <c>canon.WebSite</c>, npr. <c>svetila_si</c> ali <c>B2C</c>.</param>
/// <param name="Name">Ime, ki ga uporabnik bere in piše, npr. <c>Svetila.si</c>.</param>
/// <param name="CategoryTreeCode">Deli ga jezikovna različica iste strani (npr. <c>svetila_si</c>
/// in <c>svetila_si_en</c>) — po tem se strani na izpisu združijo v eno ime.</param>
public sealed record WorkbookWebSite(string Code, string Name, string CategoryTreeCode);

/// <param name="Code">Koda atributa v <c>canon.ProductAttribute</c>.</param>
/// <param name="Name">Ime za naslov stolpca; kadar prevoda ni, je enako kodi.</param>
/// <param name="InSet">Ali atribut sodi v nabor kategorije, po kateri je list narejen.</param>
/// <param name="SetLevel">REQUIRED ali RECOMMENDED; null, kadar atribut ni v naboru.</param>
public sealed record WorkbookAttribute(string Code, string Name, bool InSet = false, string? SetLevel = null);

/// <param name="TextTypes">Vrste spletnih besedil brez ERP naziva, npr. WEB_TITLE, DESCRIPTION.</param>
/// <param name="Languages">Jeziki nazivov in opisov v vrstnem redu lista.</param>
public sealed record ProductWorkbookSpec(
  IReadOnlyList<SaopWritableField> SaopFields,
  IReadOnlyList<WorkbookWebSite> WebSites,
  IReadOnlyList<string> TextTypes,
  IReadOnlyList<string> Languages,
  IReadOnlyList<WorkbookAttribute> Attributes,
  IReadOnlyList<WorkbookFlag>? Flags = null);

/// <param name="Code">Koda oznake v <c>pim.ProductFlagDefinition</c>, npr. PAKIRNO_NAROCANJE.</param>
/// <param name="Name">Prikazno ime oznake; naslov stolpca.</param>
public sealed record WorkbookFlag(string Code, string Name);

/// <param name="Column">Stolpec pogodbe; null pomeni naslov, ki mu ne ustreza noben stolpec.</param>
/// <param name="Ambiguous">Naslov je na seznamu dvoumnih (<see cref="ProductWorkbookContract.AmbiguousHeaders"/>):
/// stolpec se namenoma preskoči — ne gre v polje, ne v atribut, ne v okno za izbiro atributa.</param>
public sealed record ProductWorkbookHeaderMatch(int Index, string Header, ProductWorkbookColumn? Column, bool Ambiguous = false);

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
/// katero polje sme PIM pisati. ERP podatek uvoz zapiše v PIM takoj in ga hkrati uvrsti v
/// odhodno vrsto, kjer za pot v SAOP čaka odobritev (245).
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
  public const string GroupErp = "ERP — v PIM takoj, v SAOP prek vrste";
  /// <summary>Teže, dimenzije, pakiranje, poreklo, tarifa: polja SAOP (ProductCommercial.*), ki gredo
  /// po isti poti kot ERP, a jih uporabnik išče skupaj s S-popustom (David 2026-09-24).</summary>
  public const string GroupCommercial = "Komerciala — v PIM takoj, v SAOP prek vrste";
  public const string CommercialFieldPrefix = "ProductCommercial.";
  public const string GroupWeb = "Splet — zapiše se takoj";
  /// <summary>Atributi, ki jih kategorija izdelka predpisuje (nabor iz <c>canon.CategoryAttributeSet</c>).</summary>
  public const string GroupAttributesInSet = "Atributi kategorije — nabor";

  /// <summary>Atributi, ki jih nabor kategorije ne omenja; na splet ne gredo, vrednost pa obstaja.</summary>
  public const string GroupAttributesOutside = "Atributi izven nabora — ne gredo na splet";
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
  public const string ImagesField = "ProductMedia.Url";
  public const string DocumentsField = "ProductMedia.Documents";

  /// <summary>S-popust na polno pakiranje (274): last PIM, gre v katalog.csv, v SAOP ne.</summary>
  public const string GroupPackaging = "S-popust na polno pakiranje — PIM, v katalog.csv";
  /// <summary>Privzeta S koda izdelka (S1–S4); »-« pomeni »brez S«.</summary>
  public const string PackagingCodeField = "Discount.PackagingCode";
  /// <summary>Posebni S na tem izdelku po tipu stranke: »TIP\S3 | TIP\S2«; »-« odstrani vse.</summary>
  public const string TypeSpecialsField = "Discount.TypeSpecials";
  /// <summary>Posebni S na tem izdelku po stranki: »ŠIFRA_STRANKE\S2 | …«; »-« odstrani vse.</summary>
  public const string CustomerSpecialsField = "Discount.CustomerSpecials";
  /// <summary>Znak v celici, ki izprazni polje S (prazna celica pomeni »ne dotikaj se«).</summary>
  public const string ClearToken = "-";

  /// <summary>Oznake artikla (233/302): last PIM, D/N, gredo v katalog.csv, v SAOP ne.</summary>
  public const string GroupFlags = "Oznake — PIM, v katalog.csv";
  public const string FlagFieldPrefix = "ProductFlag.";

  /// <summary>Ali je polje oznaka artikla (bere in piše jih pim.ProductFlag, ne canon.FieldValue).</summary>
  public static bool IsFlagField(string fieldKey) => fieldKey.StartsWith(FlagFieldPrefix, StringComparison.Ordinal);

  /// <summary>Koda oznake iz kode stolpca: »ProductFlag.PAKIRNO_NAROCANJE« → »PAKIRNO_NAROCANJE«.</summary>
  public static string FlagCode(string fieldKey) => fieldKey[FlagFieldPrefix.Length..];

  static bool IsCommercial(SaopWritableField field) =>
    field.FieldKey.StartsWith(CommercialFieldPrefix, StringComparison.Ordinal);

  /// <summary>Ali je polje eno od polj S-popusta (bere in piše jih PackagingDiscountService, ne canon.FieldValue).</summary>
  public static bool IsPackagingField(string fieldKey) =>
    fieldKey is PackagingCodeField or TypeSpecialsField or CustomerSpecialsField;

  /// <summary>
  /// Ali je skupina nad naslovom ena od skupin atributov (»Atributi kategorije — nabor«, »Atributi
  /// izven nabora …«). Stolpec pod tako skupino je atribut, tudi kadar ga šifrant ne pozna — tak
  /// stolpec je prej tiho padel med neprepoznane in vrednosti so se izgubile (Objemke.xlsx:
  /// Družina, Premer objema, Cev …); zdaj uvoz atribut ustvari.
  /// </summary>
  public static bool IsAttributeGroup(string? group) =>
    WorkbookHeader.Normalize(group).StartsWith("atribut", StringComparison.Ordinal);

  /// <summary>Stolpec za atribut, ki ga pogodba ni poznala vnaprej (nov ali brez vrednosti in nabora).</summary>
  /// <param name="attributeName">Slovensko ime atributa — ključ vrednosti v <c>canon.ProductAttribute</c>.</param>
  public static ProductWorkbookColumn AttributeColumn(string group, string header, string attributeName) =>
    new(IsAttributeGroup(group) ? group : GroupAttributesOutside, header, AttributeFieldPrefix + attributeName,
      ProductWorkbookTarget.Pim, Width: Math.Clamp(header.Length + 3, 14, 32));

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
      // »Naziv« (spletni naziv, sicer naziv ERP, sicer šifra) je bil tu do 2026-09-29. Uporabnik ga je
      // odstranil: mešal je dva podatka in se je iz Excela prepisal v »Spletni naziv (sl)«. Naziv ERP
      // in spletni naziv sta svoja stolpca. Uvoz ga v stari datoteki preskoči kot dvoumen naslov in to pove (AmbiguousHeaders, naloga #6).
    };

    // --- ERP: stolpci pridejo iz registra, ne iz tega seznama ---------------------------
    // Če register dobi novo polje, ga dobi tudi list; če polje izgubi pravico pisanja, izgine
    // iz lista. Seznam v kodi bi se z registrom slej ko prej razšel.
    // Register lahko isto kanonično polje pošlje v več elementov SAOP (AdditionalProperty1ID je
    // po 081 vedno enak oddelku, ItemDepartment). Zapisljiv je samo prvi stolpec; ostali so samo
    // za branje. Prej sta bila oba zapisljiva in pri uvozu je drugi tiho povozil prvega:
    // »Oddelek (ABC)« B -> A se ni zaznal, ker je »Dodatna lastnost 1« v isti vrstici še nosila B.
    // Vrstni red skupin je vrstni red, v katerem uporabnik list izpolnjuje: ERP, komerciala
    // (teže, pakiranje, nato S-popust), splet (kategorije, strani, besedila, slike), atributi.
    var saopKeys = new HashSet<string>(StringComparer.Ordinal);
    var saopFields = spec.SaopFields.Where(field => !IsCommercial(field))
      .Concat(spec.SaopFields.Where(IsCommercial));
    foreach (var field in saopFields)
      columns.Add(new(IsCommercial(field) ? GroupCommercial : GroupErp, field.Label, field.FieldKey,
        saopKeys.Add(field.FieldKey) ? ProductWorkbookTarget.Saop : ProductWorkbookTarget.ReadOnly,
        field.ValueFormat is "decimal4" or "decimal8" ? WorkbookCellKind.Number : WorkbookCellKind.Text,
        Width: Math.Clamp(field.Label.Length + 3, 14, 32),
        Aliases: [field.ElementName, $"{field.Label} [{field.FieldKey}]"], ValueFormat: field.ValueFormat));

    // --- S-popust na polno pakiranje (274): last PIM, gre v katalog.csv ------------------------
    // »Skupina popusta« je naslov istega podatka v ceniku in v katalog.csv, zato uvoz sprejme tudi
    // cenik (Šifra | Skupina popusta | VPAK). Rabatna skupina ERP ima svoj naslov (»Rabatna skupina 1«).
    columns.Add(new(GroupPackaging, "S koda", PackagingCodeField, ProductWorkbookTarget.Pim, Width: 10,
      Aliases: ["Skupina popusta", "S-koda", "S popust", "Product.PackagingDiscountCode"]));
    columns.Add(new(GroupPackaging, "Posebni S — tipi strank", TypeSpecialsField, ProductWorkbookTarget.Pim, Width: 30,
      Aliases: ["Posebni S - tipi strank", "Posebni S tipi strank"], IsMultiValue: true));
    columns.Add(new(GroupPackaging, "Posebni S — stranke", CustomerSpecialsField, ProductWorkbookTarget.Pim, Width: 30,
      Aliases: ["Posebni S - stranke", "Posebni S stranke", "Posebni popust za stranko"], IsMultiValue: true));

    // --- Oznake artikla (233/302): last PIM, D/N ------------------------------------------
    // »Pakirno naročanje« (katalog.csv: na spletu samo po celih paketih po Pakiranju 2),
    // »Razstavni eksponat«. Nova oznaka v registru dobi stolpec sama.
    foreach (var flag in spec.Flags ?? [])
      columns.Add(new(GroupFlags, flag.Name, FlagFieldPrefix + flag.Code, ProductWorkbookTarget.Pim,
        Width: Math.Clamp(flag.Name.Length + 3, 12, 24), Aliases: [flag.Code], ValueFormat: "bool"));

    // --- Splet: last PIM, zapiše se takoj ----------------------------------------------
    // Zastavice »Za splet« tu ni: register out.SaopXmlField jo pozna kot element WebPublish,
    // torej potuje v SAOP in mora skozi odhodno vrsto kot vsako drugo ERP polje. Dva stolpca
    // za isto polje bi bila pri uvozu dvoumna in bi eno vrednost pisala dvakrat, vsakič drugam.
    foreach (var site in spec.WebSites)
      columns.Add(new(GroupWeb, CategoryHeader(site), CategoryFieldKey(site.Code), ProductWorkbookTarget.Pim,
        Width: 44, Aliases: [$"Kategorije {site.Code}"], IsMultiValue: true));

    columns.Add(new(GroupWeb, "Spletne strani", WebSitesField, ProductWorkbookTarget.Pim, Width: 30,
      Aliases: ["Spletna stran", "Strani"], IsMultiValue: true));

    foreach (var textType in spec.TextTypes)
      foreach (var language in spec.Languages)
        columns.Add(new(GroupWeb, $"{TextTypeLabel(textType)} ({language})",
          $"{TextFieldPrefix}{textType}.{language}", ProductWorkbookTarget.Pim,
          Width: textType.Contains("DESCRIPTION", StringComparison.OrdinalIgnoreCase) ? 48 : 34));

    // Slike in dokumenti sta bila do 245 samo za branje: uvoz ju je prezrl, čeprav ju uporabnik
    // v Excelu dopolnjuje (Objemke.xlsx). Celica je cel seznam izdelka, v vrstnem redu — prva
    // slika je glavna; naslov, ki ga v celici ni več, izdelek izgubi. Prazna celica: ne dotikaj se.
    columns.Add(new(GroupWeb, "Slike", ImagesField, ProductWorkbookTarget.Pim, Width: 44,
      IsMultiValue: true));

    // Vse, kar canon.ProductMedia in canon.ProductDocument nosita in ni slika (dokumenti, videi,
    // arhivi …) — ista razvrstitev kot na strani Mediji (MediaKindPolicy.Classify), da izvoz in
    // stran nikoli ne kažeta različnih stvari za isti izdelek.
    columns.Add(new(GroupWeb, "Dokumenti", DocumentsField, ProductWorkbookTarget.Pim, Width: 44,
      IsMultiValue: true));

    // --- Atributi ----------------------------------------------------------------------
    // Dve skupini, ista razdelitev kot na kartici izdelka: kar kategorija predpisuje, in kar
    // izdelek nosi mimo nabora. Brez te ločnice je list z vsemi 148 atributi za eno svetilko
    // večinoma hrup — stolpci o preseku kabla pri stropni svetilki niso vprašanje, ampak šum.
    // Atribut iz nabora dobi stolpec tudi takrat, kadar izdelek zanj še nima vrednosti; ravno
    // ta je tisti, ki ga je treba vpisati.
    var inSet = spec.Attributes.Where(attribute => attribute.InSet).ToList();
    var outside = spec.Attributes.Where(attribute => !attribute.InSet).ToList();
    // Atribut, ki ga že piše polje SAOP (Garancija ← Warranty), nima svojega stolpca: dva stolpca
    // za isto polje sta pri uvozu zavrnila vrstico, kadar je uporabnik popravil samo enega.
    foreach (var attribute in inSet.Concat(outside).Where(attribute => !saopKeys.Contains(AttributeFieldPrefix + attribute.Code)))
      columns.Add(new(attribute.InSet ? GroupAttributesInSet : GroupAttributesOutside,
        attribute.Name, AttributeFieldPrefix + attribute.Code,
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
    // Dvoumen naslov (npr. atribut z imenom »Naziv«) izvoz nikoli ne izpiše golega: uvoz bi ga preskočil.
    var used = new HashSet<string>(AmbiguousHeaderSet, StringComparer.Ordinal);
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
  /// Naslovi, ki ne povedo, v katero polje sodijo (naloga #6, uporabnik 2026-09-29). Stari stolpec
  /// »Naziv« je izpisal spletni naziv, sicer naziv ERP, sicer šifro — ob uvozu se je vpisal v
  /// »Spletni naziv (sl)« in tako spletni naziv prepisal z nazivom ERP. Tak stolpec uvoz preskoči
  /// in to pove; ne ujame ga ne pogodba ne atribut (»Naziv« ≠ »Nazivna napetost«). Primerjava je
  /// natančna (<see cref="WorkbookHeader.Normalize"/>), ne po »vsebuje«. »Ime« ni na seznamu, ker
  /// je pravi atribut (IME).
  /// </summary>
  public static readonly IReadOnlyList<string> AmbiguousHeaders =
  [
    "Naziv", "Naziv artikla", "Naziv izdelka", "Ime artikla", "Ime izdelka", "Naslov",
    "Name", "Title", "Product name", "Item name",
  ];

  static readonly HashSet<string> AmbiguousHeaderSet =
    AmbiguousHeaders.Select(WorkbookHeader.Normalize).ToHashSet(StringComparer.Ordinal);

  /// <summary>Ali je naslov na seznamu dvoumnih (<see cref="AmbiguousHeaders"/>).</summary>
  public static bool IsAmbiguousHeader(string? header) => AmbiguousHeaderSet.Contains(WorkbookHeader.Normalize(header));

  /// <summary>Opozorilo za preskočen dvoumen stolpec; gre v predogled, izid in ops.ImportRun.Problems.</summary>
  public static string AmbiguousHeaderWarning(string header) =>
    $"Stolpec »{header.Trim()}« je preskočen, ker je dvoumen (spletni naziv ali naziv ERP?). "
    + "Uporabi »Spletni naziv (sl)« ali »Naziv ERP (sl)«.";

  /// <summary>
  /// Poveže naslove iz datoteke s stolpci pogodbe. Kar se ne ujame, dobi <c>Column = null</c> —
  /// uvoz to izpiše, namesto da bi tiho spregledal stolpec, ki ga je uporabnik izpolnjeval.
  /// Dvoumen naslov (<see cref="AmbiguousHeaders"/>) dobi <c>Ambiguous = true</c> in nikoli stolpca.
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
      if (AmbiguousHeaderSet.Contains(key)) { matches.Add(new(index, headers[index], null, Ambiguous: true)); continue; }
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
    // D/N je zapis iz SAOP (POST/PATCH) in od 2026-09-22 tudi zapis v delovnem listu.
    "d" or "da" or "ja" or "y" or "1" or "true" or "yes" or "x" or "ok" => true,
    "n" or "ne" or "0" or "false" or "no" => false,
    _ => null,
  };

  /// <summary>Logična vrednost v delovnem listu: D ali N, kot jo SAOP pozna v dokumentih POST/PATCH
  /// (uporabnik 2026-09-22: »v izvozu pa uvozu artiklov tudi D pa N, da bo enako kot na SAOP«).</summary>
  public static string SheetYesNo(bool value) => value ? "D" : "N";

  public static string YesNo(bool value) => value ? Yes : No;

  /// <summary>
  /// Logična celica v obliki, ki jo hrani katalog in razume SaopDocumentBuilder: »1« ali »0«.
  /// Prej je v vrsto za SAOP šlo besedilo iz celice (»da«, »x«) — »x« je graditelj dokumenta
  /// zavrnil, »da« pa se ni nikoli ujel s kanonično »1« pri potrditvi odmeva (243).
  /// </summary>
  public static string? BoolValue(string? cell) => ParseYesNo(cell) switch
  {
    true => "1",
    false => "0",
    null => null,
  };
}
