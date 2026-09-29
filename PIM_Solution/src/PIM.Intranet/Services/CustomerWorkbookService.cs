using System.Data;
using System.Globalization;
using Microsoft.Data.SqlClient;
using PIM.Operations;

namespace PIM.Intranet.Services;

/// <param name="Editable">Ali uvoz stolpec bere; ostali so samo za branje in jih uvoz prezre.</param>
public sealed record CustomerWorkbookColumn(
  string Key, string Header, string Group, bool Editable,
  WorkbookCellKind Kind = WorkbookCellKind.Text, double Width = 0);

public sealed record CustomerFieldChange(string Label, string? OldValue, string? NewValue);

/// <summary>
/// Kaj bo uvoz naredil z eno stranko. Polja z vrednostjo <c>null</c> se ne spreminjajo; primerjava
/// s trenutnim stanjem je že narejena, zato so tu samo prave spremembe.
/// </summary>
public sealed class CustomerWorkbookRowChange(int rowNumber, CustomerListRow current)
{
  public int RowNumber { get; } = rowNumber;
  public CustomerListRow Current { get; } = current;
  public List<CustomerFieldChange> Changes { get; } = [];

  /// <summary>Nove vrednosti B2B profila, kadar se je spremenilo katerokoli njegovo polje.</summary>
  public ProfileTarget? Profile { get; set; }

  /// <summary>Stopnja → nov prag in rabat; null pomeni »umakni lastni prag, velja splošna lestvica«.</summary>
  public Dictionary<byte, (decimal Threshold, decimal Percent)?> Tiers { get; } = [];

  /// <summary>Skupina artiklov → nov odstotek; null pomeni »umakni«.</summary>
  public Dictionary<string, decimal?> Groups { get; } = new(StringComparer.OrdinalIgnoreCase);

  /// <summary>Šifra artikla → nova S koda; null pomeni »umakni«.</summary>
  public Dictionary<string, string?> Specials { get; } = new(StringComparer.OrdinalIgnoreCase);

  /// <summary>Novi ročni kontakti (vsi štirje), kadar se je spremenil katerikoli.</summary>
  public ContactTarget? Contact { get; set; }

  /// <summary>279: skrbnik, e-pošta za dobavnice in obveščanje (vsi štirje), kadar se je spremenil katerikoli.</summary>
  public ExtraTarget? Extra { get; set; }

  /// <summary>279: skupina artiklov → nov dodatni popust (P2); null pomeni »umakni«.</summary>
  public Dictionary<string, decimal?> ExtraGroups { get; } = new(StringComparer.OrdinalIgnoreCase);

  /// <summary>279: nov zaznamek, ki se doda k obstoječim.</summary>
  public string? Note { get; set; }

  public sealed record ProfileTarget(
    string? Kind, string? TypeCode, bool Packaging, bool Value, bool Plus, DateTime? PlusFrom, DateTime? PlusTo);

  public sealed record ContactTarget(string? Email, string? Phone, string? Mobile, string? Persons);

  public sealed record ExtraTarget(string? AccountManager, string? DeliveryNoteEmail, string? NoticeEmail, string? NoticePerson);
}

/// <summary>
/// Vrstica lista »S po tipih strank« (274): pravilo posebnega S za tip stranke. <paramref name="RemoveRuleId"/>
/// je nastavljen, kadar vrstica pravilo ukinja (stolpec »Ukini« = D).
/// </summary>
public sealed record CustomerTypeRuleChange(
  int RowNumber, int OrganizationId, string OrganizationName, PackagingRuleInput Input, long? RemoveRuleId, string Description);

public sealed record CustomerWorkbookPreview(
  IReadOnlyList<CustomerWorkbookRowChange> Rows, int RowsRead, int UnchangedRows,
  IReadOnlyList<string> Problems, IReadOnlyList<string> Warnings,
  IReadOnlyList<string> UnknownColumns, IReadOnlyList<string> ReadOnlyColumns,
  IReadOnlyList<CustomerTypeRuleChange>? TypeRules = null)
{
  public int ChangeCount => Rows.Sum(row => row.Changes.Count) + (TypeRules?.Count ?? 0);
}

/// <param name="CustomerExportRows">Spremenjene stranke, ki gredo v stranke.csv (aktivne z B2B profilom).</param>
/// <param name="CatalogProducts">Izdelki, katerih stolpec »Posebni popust za stranko« v katalog.csv se je spremenil.</param>
public sealed record CustomerWorkbookOutcome(
  int CustomersTouched, int ValuesWritten, int CustomerExportRows, int CatalogProducts,
  IReadOnlyList<string> Organizations, IReadOnlyList<string> Problems);

/// <summary>
/// Delovni list strank: izvoz v Excel in uvoz nazaj, po vzoru delovnega lista izdelkov
/// (uporabnik 2026-09-22: »opcije izvoza strank, da jih lahko paketno urejajo kot izdelke«).
///
/// Ena pogodba stolpcev (<see cref="Columns"/>) za obe smeri: kar izvoz zapiše, uvoz prebere.
/// Uvoz piše skozi iste procedure kot kartica stranke (b2b.SaveCustomerWebProfile,
/// SaveCustomerValueTier, SaveGroupDiscountOverride, SaveCustomerPackagingDiscountOverride,
/// SaveCustomerContact) in njihove umike (250) — z isto revizijsko sledjo in iz istih tabel, ki jih
/// bere out.GetExportRows za stranke.csv in katalog.csv.
///
/// Pravila celic: prazna celica pomeni »ne spreminjaj« (isto kot pri izdelkih); »-« pomeni
/// »izprazni« — brez tega se popusta ali tipa z uvozom ne bi dalo odstraniti. Seznam v celici je
/// ločen z »|« in je CEL seznam: skupina ali izdelek, ki ga v celici ni več, se umakne.
/// </summary>
public sealed class CustomerWorkbookService(IConfiguration configuration, CustomerListService customers,
  PackagingDiscountService? packagingService = null)
{
  /// <summary>Pravila S (274); v testih brez DI se ustvari iz iste konfiguracije.</summary>
  readonly PackagingDiscountService packaging = packagingService ?? new PackagingDiscountService(configuration);

  /// <summary>Drugi list zvezka: pravila posebnega S po tipu stranke (274).</summary>
  public const string TypeRulesSheetName = "S po tipih strank";
  public const string ClearToken = "-";
  public const string SheetName = "Stranke";

  const string GroupKey = "Ključ";
  const string GroupRole = "Vloga — izračunana, samo za branje";
  const string GroupKind = "Vrsta — ročna odločitev";
  const string GroupB2b = "B2B — v stranke.csv";
  const string GroupTiers = "Vrednostni rabat stranke — v stranke.csv";
  const string GroupDiscounts = "Popusti po skupinah in izdelkih";
  const string GroupContacts = "Kontakti — v stranke.csv";
  const string GroupInternal = "Prodaja — samo v PIM";
  const string GroupState = "Stanje — samo za branje";

  public const string OrganizationKey = "ORG";
  public const string CustomerKeyKey = "KEY";
  const string NameKey = "NAME";
  const string KindKey = "KIND";
  const string TypeKey = "TYPE";
  const string PackagingKey = "PACK";
  const string ValueKey = "VALUE";
  const string PlusKey = "PLUS";
  const string PlusFromKey = "PLUS_FROM";
  const string PlusToKey = "PLUS_TO";
  const string GroupsKey = "GROUPS";
  const string SpecialKey = "SPECIAL";
  const string EmailKey = "EMAIL";
  const string PhoneKey = "PHONE";
  const string MobileKey = "MOBILE";
  const string PersonsKey = "PERSONS";
  const string ExtraGroupsKey = "EXTRA_GROUPS";
  const string ManagerKey = "MANAGER";
  const string DeliveryEmailKey = "DELIVERY_EMAIL";
  const string NoticeEmailKey = "NOTICE_EMAIL";
  const string NoticePersonKey = "NOTICE_PERSON";
  const string AddNoteKey = "ADD_NOTE";
  static string ThresholdKey(int tier) => "T" + tier + "_THRESHOLD";
  static string PercentKey(int tier) => "T" + tier + "_PERCENT";

  public static readonly IReadOnlyList<CustomerWorkbookColumn> Columns =
  [
    new(OrganizationKey, "Podjetje", GroupKey, false, Width: 14),
    new(CustomerKeyKey, "Šifra stranke", GroupKey, false, Width: 14),
    new(NameKey, "Naziv", GroupKey, false, Width: 40),

    new("ROLE", "Vloga", GroupRole, false, Width: 26),
    new("ROLE_SOURCE", "Vir vloge", GroupRole, false, Width: 14),
    new("SUPPLIED", "Dobavlja izdelkov", GroupRole, false, WorkbookCellKind.Number, 12),
    new("MADE", "Proizvaja izdelkov", GroupRole, false, WorkbookCellKind.Number, 12),
    new("SAOP_TYPE", "Vrsta partnerja v SAOP", GroupRole, false, Width: 12),

    new(KindKey, "Vrsta (ročno)", GroupKind, true, Width: 20),

    new(TypeKey, "Tip stranke", GroupB2b, true, Width: 18),
    new(PackagingKey, "Popust polno pakiranje", GroupB2b, true, Width: 12),
    new(ValueKey, "Vrednostni rabat", GroupB2b, true, Width: 12),
    new(PlusKey, "B2B+", GroupB2b, true, Width: 8),
    new(PlusFromKey, "B2B+ velja od", GroupB2b, true, WorkbookCellKind.DateTime),
    new(PlusToKey, "B2B+ velja do", GroupB2b, true, WorkbookCellKind.DateTime),

    new(ThresholdKey(1), "Prag 1 (€ brez DDV)", GroupTiers, true, WorkbookCellKind.Number),
    new(PercentKey(1), "Rabat 1 (%)", GroupTiers, true, WorkbookCellKind.Number),
    new(ThresholdKey(2), "Prag 2 (€ brez DDV)", GroupTiers, true, WorkbookCellKind.Number),
    new(PercentKey(2), "Rabat 2 (%)", GroupTiers, true, WorkbookCellKind.Number),
    new(ThresholdKey(3), "Prag 3 (€ brez DDV)", GroupTiers, true, WorkbookCellKind.Number),
    new(PercentKey(3), "Rabat 3 (%)", GroupTiers, true, WorkbookCellKind.Number),

    new(GroupsKey, "Skupinski popusti stranke", GroupDiscounts, true, Width: 30),
    new(SpecialKey, "Posebni S po izdelku (katalog.csv)", GroupDiscounts, true, Width: 36),
    new(ExtraGroupsKey, "Dodatni popust po skupinah (P2)", GroupDiscounts, true, Width: 24),

    new(EmailKey, "E-pošta", GroupContacts, true, Width: 26),
    new(PhoneKey, "Telefon", GroupContacts, true, Width: 16),
    new(MobileKey, "Mobitel", GroupContacts, true, Width: 16),
    new(PersonsKey, "Osebe", GroupContacts, true, Width: 26),

    new("CLERK", "Referent (SAOP)", GroupInternal, false, Width: 22),
    new(ManagerKey, "Skrbnik", GroupInternal, true, Width: 20),
    new(DeliveryEmailKey, "E-pošta za dobavnice", GroupInternal, true, Width: 26),
    new(NoticeEmailKey, "E-pošta za obveščanje", GroupInternal, true, Width: 26),
    new(NoticePersonKey, "Oseba za obveščanje", GroupInternal, true, Width: 20),
    new(AddNoteKey, "Dodaj opombo", GroupInternal, true, Width: 30),
    new("NOTES", "Opombe", GroupInternal, false, Width: 40),

    new("MAGENTO", "Magento skupina", GroupState, false, Width: 16),
    new("ACTIVE", "Aktivna", GroupState, false, Width: 9),
    new("IN_CSV", "V stranke.csv", GroupState, false, Width: 11),
    new("CITY", "Kraj", GroupState, false, Width: 16),
    new("TAX", "Davčna številka", GroupState, false, Width: 14),
    new("PRICE_LIST", "Cenik", GroupState, false, Width: 10),
    new("DISCOUNT_LIST", "Rabatni cenik", GroupState, false, Width: 12),
    new("PAYER_KIND", "PE / tranzit", GroupState, false, Width: 14),
    new("EXPORT_GROUPS", "Skupine popustov v stranke.csv", GroupState, false, Width: 40),
  ];

  static readonly IReadOnlyList<string> Notes =
  [
    "Prazna celica pomeni »ne spreminjaj«. Znak »-« pomeni »izprazni«: odstrani vrsto, tip, datum, kontakt, lastni prag (velja splošna lestvica), vse skupinske popuste ali vse posebne S.",
    "Vrsta (ročno): Kupec, Dobavitelj, Kupec in dobavitelj ali Proizvajalec. Brez ročne vrste se vloga izračuna znotraj podjetja: dobavitelj = dobavitelj vsaj enega izdelka ali SAOP vrsta D; proizvajalec = proizvajalec vsaj enega izdelka; kupec = tip stranke, SAOP vrsta K ali brez druge vloge.",
    "Tip stranke: koda ali ime iz šifranta (npr. INSTALLER ali INŠTALATER). Magento skupino določa preslikava tipa na strani Pravila popustov.",
    "Popust polno pakiranje, Vrednostni rabat, B2B+: D ali N.",
    "Prag in rabat iste stopnje vpiši skupaj; prazna stopnja pomeni splošno lestvico.",
    "Skupinski popusti stranke: ročni popust SKUPINA=% ločeno z |, npr. NW=10 | AR=5. Celica je cel seznam — skupina, ki je ni več, se umakne. Ročni popust prevlada nad SAOP.",
    "Skupine popustov v stranke.csv (samo za branje): kar gre na splet v stolpca Skupine popustov in Popust NW — ročni popust stranke, ročni popust tipa, sicer SAOP rabatni cenik; poslovna enota (PE) ga podeduje od plačnika, tranzit ga nima. Samo danes veljavni popusti nad 0 %.",
    "Dodatni popust po skupinah (P2): SKUPINA=% ločeno z |, npr. NW=7. Obračuna se ZA osnovnim popustom skupine (kot P2 za P1 v SAOP): NW 39 % in dodatni 7 % = 43,27 % v stranke.csv; brez osnovnega velja sam. Celica je cel seznam.",
    "Prodaja — samo v PIM: Referent je iz SAOP (samo za branje). Skrbnik, e-pošta za dobavnice, e-pošta in oseba za obveščanje ne gredo v stranke.csv. »Dodaj opombo« doda nov zaznamek na kartico (obstoječi ostanejo in so vidni v stolpcu Opombe); v izvozu je vedno prazna.",
    "Posebni S (katalog.csv, stolpec Posebni popust za stranko kot ŠIFRA_STRANKE\\S2): ločeno z |. ARTIKEL\\S2 = en artikel (objavljen izdelek istega podjetja); SKUPINA:BRAYTRON\\S3 = vsi artikli rabatne skupine; S:S2\\S3 = vsi artikli, ki imajo privzeto S2; *\\S3 = vsi artikli. Velja najbolj specifično: artikel, S koda, skupina, vsi. Posebni S stranke ima prednost pred pravilom njenega tipa (list »S po tipih strank«).",
    "V stranke.csv gre aktivna stranka z B2B profilom. Stolpci pod »samo za branje« se pri uvozu prezrejo. Ključ vrstice je Podjetje + Šifra stranke.",
  ];

  string ConnectionString => ConnectionStringResolver.Resolve(configuration)
    ?? throw new InvalidOperationException("Povezava PIM ni nastavljena.");

  public static string FileName(DateTime utc) => $"PIM_stranke_{utc:yyyyMMdd_HHmm}.xlsx";

  /* --- Izvoz ------------------------------------------------------------------------------- */

  public static byte[] Build(IReadOnlyList<CustomerListRow> rows, IReadOnlyList<(string Organization, PackagingRule Rule)>? typeRules = null)
  {
    var columns = Columns.Select(column => new WorkbookColumn(column.Header, column.Kind, column.Width, column.Group)).ToArray();
    var sheets = new List<WorkbookWriteSheet> { new(SheetName, columns, rows.Select(Cells), Notes) };
    if (typeRules is not null)
      sheets.Add(new(TypeRulesSheetName,
        TypeRuleColumns.Select(column => new WorkbookColumn(column.Header, column.Kind, column.Width, column.Group)).ToArray(),
        typeRules.Select(pair => (IReadOnlyList<object?>)
        [
          pair.Organization, pair.Rule.TargetCode, pair.Rule.TargetName,
          PackagingDiscountService.ScopeText(pair.Rule.ScopeKind, pair.Rule.ItemId, pair.Rule.ItemGroupCode, pair.Rule.FromDiscountCode),
          pair.Rule.DiscountCode, pair.Rule.ValidFrom, pair.Rule.ValidTo, pair.Rule.Note, "N",
          pair.Rule.MagentoGroupKey, pair.Rule.ProductCount, pair.Rule.CustomerCount,
        ]), TypeRuleNotes));
    return WorkbookWriter.Write(sheets);
  }

  /// <summary>Delovni list strank z listom pravil S po tipih za podjetja, ki so v vrsticah (ali izbrano podjetje).</summary>
  public async Task<byte[]> BuildAsync(IReadOnlyList<CustomerListRow> rows, int? organizationId, CancellationToken cancellationToken = default)
  {
    var organizations = await OrganizationsAsync(cancellationToken);
    var ids = organizationId is { } one ? [one] : rows.Select(row => row.OrganizationId).Distinct().ToList();
    var typeRules = new List<(string, PackagingRule)>();
    foreach (var id in ids)
      foreach (var rule in (await packaging.GetRulesAsync(id, cancellationToken: cancellationToken)).Where(rule => rule.TargetKind == PackagingDiscountService.TargetType))
        typeRules.Add((organizations.GetValueOrDefault(id, id.ToString(CultureInfo.InvariantCulture)), rule));
    return Build(rows, typeRules);
  }

  const string TypeRuleGroupKey = "Pravilo";
  const string TypeRuleGroupState = "Stanje — samo za branje";

  static readonly IReadOnlyList<CustomerWorkbookColumn> TypeRuleColumns =
  [
    new(OrganizationKey, "Podjetje", TypeRuleGroupKey, true, Width: 14),
    new("TR_TYPE", "Tip stranke", TypeRuleGroupKey, true, Width: 20),
    new("TR_TYPE_NAME", "Ime tipa", TypeRuleGroupState, false, Width: 24),
    new("TR_SCOPE", "Za artikle", TypeRuleGroupKey, true, Width: 26),
    new("TR_CODE", "S koda", TypeRuleGroupKey, true, Width: 9),
    new("TR_FROM", "Velja od", TypeRuleGroupKey, true, WorkbookCellKind.DateTime),
    new("TR_TO", "Velja do", TypeRuleGroupKey, true, WorkbookCellKind.DateTime),
    new("TR_NOTE", "Opomba", TypeRuleGroupKey, true, Width: 24),
    new("TR_REMOVE", "Ukini", TypeRuleGroupKey, true, Width: 8),
    new("TR_MAGENTO", "Magento skupina", TypeRuleGroupState, false, Width: 20),
    new("TR_PRODUCTS", "Artiklov danes", TypeRuleGroupState, false, WorkbookCellKind.Number, 12),
    new("TR_CUSTOMERS", "Strank tega tipa", TypeRuleGroupState, false, WorkbookCellKind.Number, 12),
  ];

  static readonly IReadOnlyList<string> TypeRuleNotes =
  [
    "Pravila posebnega S za TIP stranke: vse stranke tega tipa (npr. vsi inštalaterji) dobijo na izbranih artiklih namesto privzetega S izdelka to S kodo. V katalog.csv gredo v stolpec »Posebni S za skupino strank« kot MAGENTO_SKUPINA\\S3.",
    "Za artikle: ARTIKEL (en artikel), SKUPINA:BRAYTRON (rabatna skupina), S:S2 (vsi artikli s privzetim S2), * (vsi artikli). Velja najbolj specifično pravilo; pravilo posamezne stranke (list Stranke) ima prednost pred pravilom tipa.",
    "Nova vrstica doda pravilo, spremenjena S koda ali datum ga posodobi. Ukini = D pravilo umakne. Vrstic, ki jih v datoteki ni, uvoz ne spremeni.",
  ];

  static IReadOnlyList<object?> Cells(CustomerListRow row) =>
  [
    row.OrganizationName, row.CustomerKey, row.Name,
    row.RoleLabel, row.RoleSourceLabel,
    row.SuppliedProductCount == 0 ? null : row.SuppliedProductCount,
    row.ManufacturedProductCount == 0 ? null : row.ManufacturedProductCount,
    row.SaopPartnerType,
    Blank(CustomerRoles.KindLabel(row.ManualKind)),
    row.CustomerTypeCode,
    ProductWorkbookContract.SheetYesNo(row.PackagingDiscountEnabled),
    ProductWorkbookContract.SheetYesNo(row.ValueDiscountEnabled),
    ProductWorkbookContract.SheetYesNo(row.B2bPlusEnabled),
    row.B2bPlusValidFrom, row.B2bPlusValidTo,
    row.Tier1Threshold, row.Tier1Percent, row.Tier2Threshold, row.Tier2Percent, row.Tier3Threshold, row.Tier3Percent,
    row.GroupDiscounts, row.SpecialDiscounts,
    row.ExtraGroupDiscounts,
    row.Email, row.Phone, row.Mobile, row.Persons,
    row.SalesClerkLabel, row.AccountManager, row.DeliveryNoteEmail, row.NoticeEmail, row.NoticePerson, null, row.Notes,
    row.MagentoGroupKey,
    ProductWorkbookContract.SheetYesNo(row.IsActive),
    ProductWorkbookContract.SheetYesNo(row.InCustomerExport),
    row.City, row.TaxNumber, row.PriceListCode, row.DiscountPriceListCode, row.PayerKindLabel, row.ExportGroupDiscounts,
  ];

  static string? Blank(string value) => string.IsNullOrEmpty(value) ? null : value;

  /* --- Uvoz: predogled ---------------------------------------------------------------------- */

  public async Task<CustomerWorkbookPreview> PreviewAsync(Stream stream, int? fallbackOrganizationId, CancellationToken cancellationToken = default)
  {
    var sheetNames = WorkbookTable.SheetNames(stream);
    stream.Position = 0;
    var sheet = WorkbookTable.Read(stream, headerHints: ["Šifra stranke", "Podjetje"]);

    var byHeader = Columns.ToDictionary(column => WorkbookHeader.Normalize(column.Header));
    var matched = new Dictionary<string, int>(StringComparer.Ordinal);
    var unknown = new List<string>();
    var readOnly = new List<string>();
    for (var index = 0; index < sheet.Headers.Count; index++)
    {
      var header = sheet.Headers[index];
      if (string.IsNullOrWhiteSpace(header)) continue;
      if (!byHeader.TryGetValue(WorkbookHeader.Normalize(header), out var column)) { unknown.Add(header); continue; }
      if (column.Editable || column.Key is OrganizationKey or CustomerKeyKey) matched.TryAdd(column.Key, index);
      else readOnly.Add(header);
    }

    if (!matched.ContainsKey(CustomerKeyKey))
      throw new WorkbookReadException("Datoteka nima stolpca »Šifra stranke« — po njem uvoz najde stranko. Izvozi datoteko s strani Stranke in jo uredi.");
    if (!matched.ContainsKey(OrganizationKey) && fallbackOrganizationId is null)
      throw new WorkbookReadException("Datoteka nima stolpca »Podjetje«. Izberi podjetje, ki mu pripadajo vse vrstice.");

    var organizations = await OrganizationsAsync(cancellationToken);
    var current = (await customers.GetAsync(null, cancellationToken))
      .ToDictionary(row => (row.OrganizationId, row.CustomerKey));
    var types = await CustomerTypesAsync(cancellationToken);
    var packagingCodes = await PackagingCodesAsync(cancellationToken);
    var itemGroups = await ItemGroupsAsync(cancellationToken);

    var rows = new List<CustomerWorkbookRowChange>();
    var problems = new List<string>();
    var warnings = new List<string>();
    var seen = new HashSet<(int, string)>();
    var read = 0;
    var unchanged = 0;

    for (var index = 0; index < sheet.Rows.Count; index++)
    {
      var cells = sheet.Rows[index];
      var rowNumber = sheet.RowNumber(index);
      string Cell(string key) => matched.TryGetValue(key, out var at) && at < cells.Count ? (cells[at] ?? "").Trim() : "";

      var customerKey = Cell(CustomerKeyKey);
      if (customerKey.Length == 0) continue;
      read++;

      var organizationText = Cell(OrganizationKey);
      int? organizationId = organizationText.Length == 0 ? fallbackOrganizationId : ResolveOrganization(organizations, organizationText);
      if (organizationId is null)
      {
        problems.Add($"Vrstica {rowNumber}: podjetja »{organizationText}« ni — vrstica je izpuščena.");
        continue;
      }
      var organizationName = organizations.GetValueOrDefault(organizationId.Value, organizationId.Value.ToString(CultureInfo.InvariantCulture));
      if (!current.TryGetValue((organizationId.Value, customerKey), out var row))
      {
        problems.Add($"Vrstica {rowNumber}: stranke {customerKey} v podjetju {organizationName} ni — vrstica je izpuščena. Šifra mora biti besedilo z vodilnimi ničlami, kot jo izvozi PIM.");
        continue;
      }
      if (!seen.Add((organizationId.Value, customerKey)))
      {
        problems.Add($"Vrstica {rowNumber}: stranka {organizationName} {customerKey} je v datoteki že višje — ta vrstica je izpuščena.");
        continue;
      }

      var change = new CustomerWorkbookRowChange(rowNumber, row);
      var where = $"Vrstica {rowNumber} ({organizationName} {customerKey})";
      ReadProfile(change, Cell, types, where, problems);
      ReadTiers(change, Cell, where, problems);
      ReadGroups(change, Cell(GroupsKey), itemGroups, where, problems, warnings);
      ReadSpecials(change, Cell(SpecialKey), packagingCodes, where, problems);
      ReadContacts(change, Cell);
      ReadExtraGroups(change, Cell(ExtraGroupsKey), itemGroups, where, problems, warnings);
      ReadExtra(change, Cell);

      if (change.Changes.Count == 0) unchanged++;
      else rows.Add(change);
    }

    // 274: drugi list — pravila posebnega S po tipu stranke.
    var typeRules = new List<CustomerTypeRuleChange>();
    if (sheetNames.Any(name => WorkbookHeader.Same(name, TypeRulesSheetName)))
    {
      stream.Position = 0;
      var ruleSheet = WorkbookTable.Read(stream, sheetNames.First(name => WorkbookHeader.Same(name, TypeRulesSheetName)),
        headerHints: ["Tip stranke", "Za artikle"]);
      await ReadTypeRulesAsync(ruleSheet, fallbackOrganizationId, organizations, types, packagingCodes, typeRules, problems, cancellationToken);
    }

    return new(rows, read, unchanged, problems, warnings, unknown, readOnly, typeRules);
  }

  async Task ReadTypeRulesAsync(WorkbookSheet sheet, int? fallbackOrganizationId, IReadOnlyDictionary<int, string> organizations,
    IReadOnlyDictionary<string, string> types, IReadOnlySet<string> packagingCodes, List<CustomerTypeRuleChange> result,
    List<string> problems, CancellationToken cancellationToken)
  {
    var index = TypeRuleColumns.ToDictionary(column => column.Key, column => sheet.Headers.ToList()
      .FindIndex(header => WorkbookHeader.Same(header, column.Header)));
    if (index["TR_TYPE"] < 0 || index["TR_SCOPE"] < 0 || index["TR_CODE"] < 0)
    {
      problems.Add($"List »{TypeRulesSheetName}« nima stolpcev Tip stranke, Za artikle in S koda — list je prezrt.");
      return;
    }
    var existing = new Dictionary<int, IReadOnlyList<PackagingRule>>();
    for (var row = 0; row < sheet.Rows.Count; row++)
    {
      var cells = sheet.Rows[row];
      var rowNumber = sheet.RowNumber(row);
      string Cell(string key) => index[key] is var at && at >= 0 && at < cells.Count ? (cells[at] ?? "").Trim() : "";
      var where = $"List »{TypeRulesSheetName}«, vrstica {rowNumber}";
      var typeText = Cell("TR_TYPE");
      var scopeText = Cell("TR_SCOPE");
      if (typeText.Length == 0 && scopeText.Length == 0) continue;

      var organizationText = Cell(OrganizationKey);
      int? organizationId = organizationText.Length == 0 ? fallbackOrganizationId : ResolveOrganization(organizations, organizationText);
      if (organizationId is null) { problems.Add($"{where}: podjetje ni znano — vrstica je izpuščena."); continue; }
      if (ParseType(types, typeText) is not { } typeCode) { problems.Add($"{where}: tipa stranke »{typeText}« ni v šifrantu."); continue; }
      if (PackagingDiscountService.ParseScope(scopeText) is not { } scope) { problems.Add($"{where}: »Za artikle« je prazno — vpiši ARTIKEL, SKUPINA:koda, S:S2 ali *."); continue; }

      if (!existing.TryGetValue(organizationId.Value, out var rules))
        existing[organizationId.Value] = rules = (await packaging.GetRulesAsync(organizationId.Value, cancellationToken: cancellationToken))
          .Where(rule => rule.TargetKind == PackagingDiscountService.TargetType).ToList();
      var current = rules.FirstOrDefault(rule => string.Equals(rule.TargetCode, typeCode, StringComparison.OrdinalIgnoreCase)
        && new PackagingScope(rule.ScopeKind, rule.ItemId, rule.ItemGroupCode, rule.FromDiscountCode).Key == scope.Key);
      var organizationName = organizations.GetValueOrDefault(organizationId.Value, organizationId.Value.ToString(CultureInfo.InvariantCulture));
      var label = $"{types[typeCode]} · {PackagingDiscountService.ScopeLabel(scope.ScopeKind, scope.ItemId, scope.ItemGroupCode, scope.FromDiscountCode)}";

      if (ProductWorkbookContract.ParseYesNo(Cell("TR_REMOVE")) == true)
      {
        if (current is null) continue;
        result.Add(new(rowNumber, organizationId.Value, organizationName,
          new(PackagingDiscountService.TargetType, typeCode, null, null, scope.ScopeKind, scope.ItemId, scope.ItemGroupCode, scope.FromDiscountCode, current.DiscountCode),
          current.RuleId, $"{label}: ukini ({current.DiscountCode})"));
        continue;
      }

      var code = Cell("TR_CODE").ToUpperInvariant();
      if (!packagingCodes.Contains(code)) { problems.Add($"{where}: S koda »{code}« ni v šifrantu ({string.Join(", ", packagingCodes.Order())})."); continue; }
      DateTime? from = null, to = null;
      if (!ReadDate(Cell("TR_FROM"), "Velja od", ref from, where, problems) || !ReadDate(Cell("TR_TO"), "Velja do", ref to, where, problems)) continue;
      var note = Cell("TR_NOTE") is { Length: > 0 } text ? text : null;
      if (current is not null && string.Equals(current.DiscountCode, code, StringComparison.OrdinalIgnoreCase)
        && current.ValidFrom?.Date == from?.Date && current.ValidTo?.Date == to?.Date) continue;

      result.Add(new(rowNumber, organizationId.Value, organizationName,
        new(PackagingDiscountService.TargetType, typeCode, null, null, scope.ScopeKind, scope.ItemId, scope.ItemGroupCode, scope.FromDiscountCode,
          code, from, to, note),
        null, current is null ? $"{label}: nov {code}" : $"{label}: {current.DiscountCode} → {code}"));
    }
  }

  static void ReadProfile(CustomerWorkbookRowChange change, Func<string, string> cell,
    IReadOnlyDictionary<string, string> types, string where, List<string> problems)
  {
    var row = change.Current;
    var kind = row.ManualKind;
    var typeCode = row.CustomerTypeCode;
    var packaging = row.PackagingDiscountEnabled;
    var value = row.ValueDiscountEnabled;
    var plus = row.B2bPlusEnabled;
    var plusFrom = row.B2bPlusValidFrom;
    var plusTo = row.B2bPlusValidTo;
    var valid = true;

    var kindCell = cell(KindKey);
    if (kindCell.Length > 0)
    {
      if (kindCell == ClearToken) kind = null;
      else if (ParseKind(kindCell) is { } parsed) kind = parsed;
      else { problems.Add($"{where}: vrste »{kindCell}« ni — dovoljene so Kupec, Dobavitelj, Kupec in dobavitelj, Proizvajalec ali »-«."); valid = false; }
    }

    var typeCell = cell(TypeKey);
    if (typeCell.Length > 0)
    {
      if (typeCell == ClearToken) typeCode = null;
      else if (ParseType(types, typeCell) is { } parsed) typeCode = parsed;
      else { problems.Add($"{where}: tipa stranke »{typeCell}« ni v šifrantu."); valid = false; }
    }

    valid &= ReadFlag(cell(PackagingKey), "Popust polno pakiranje", ref packaging, where, problems);
    valid &= ReadFlag(cell(ValueKey), "Vrednostni rabat", ref value, where, problems);
    valid &= ReadFlag(cell(PlusKey), "B2B+", ref plus, where, problems);
    valid &= ReadDate(cell(PlusFromKey), "B2B+ velja od", ref plusFrom, where, problems);
    valid &= ReadDate(cell(PlusToKey), "B2B+ velja do", ref plusTo, where, problems);
    if (plusFrom is { } from && plusTo is { } to && to < from)
    {
      problems.Add($"{where}: B2B+ velja do {to:d. M. yyyy} je pred začetkom {from:d. M. yyyy}.");
      valid = false;
    }
    if (!valid) return;

    var before = change.Changes.Count;
    if (!string.Equals(kind, row.ManualKind, StringComparison.Ordinal))
      change.Changes.Add(new("Vrsta (ročno)", Blank(CustomerRoles.KindLabel(row.ManualKind)), Blank(CustomerRoles.KindLabel(kind))));
    if (!string.Equals(typeCode, row.CustomerTypeCode, StringComparison.Ordinal))
      change.Changes.Add(new("Tip stranke", row.CustomerTypeCode, typeCode));
    if (packaging != row.PackagingDiscountEnabled) change.Changes.Add(new("Popust polno pakiranje", YesNo(row.PackagingDiscountEnabled), YesNo(packaging)));
    if (value != row.ValueDiscountEnabled) change.Changes.Add(new("Vrednostni rabat", YesNo(row.ValueDiscountEnabled), YesNo(value)));
    if (plus != row.B2bPlusEnabled) change.Changes.Add(new("B2B+", YesNo(row.B2bPlusEnabled), YesNo(plus)));
    if (plusFrom != row.B2bPlusValidFrom) change.Changes.Add(new("B2B+ velja od", Day(row.B2bPlusValidFrom), Day(plusFrom)));
    if (plusTo != row.B2bPlusValidTo) change.Changes.Add(new("B2B+ velja do", Day(row.B2bPlusValidTo), Day(plusTo)));
    if (change.Changes.Count == before) return;

    change.Profile = new(kind, typeCode, packaging, value, plus, plusFrom, plusTo);
    // Brez profila ga shranjevanje ustvari; aktivna stranka z B2B profilom gre v stranke.csv (202).
    if (!row.HasProfile)
      change.Changes.Add(new("B2B profil", "ni", row.SourceIsActive ? "ustvarjen — stranka gre odslej v stranke.csv" : "ustvarjen"));
  }

  static void ReadTiers(CustomerWorkbookRowChange change, Func<string, string> cell, string where, List<string> problems)
  {
    var row = change.Current;
    var own = new (decimal? Threshold, decimal? Percent)[]
    {
      (row.Tier1Threshold, row.Tier1Percent), (row.Tier2Threshold, row.Tier2Percent), (row.Tier3Threshold, row.Tier3Percent),
    };

    for (var tier = 1; tier <= 3; tier++)
    {
      var thresholdCell = cell(ThresholdKey(tier));
      var percentCell = cell(PercentKey(tier));
      if (thresholdCell.Length == 0 && percentCell.Length == 0) continue;
      var (currentThreshold, currentPercent) = own[tier - 1];
      var label = $"Prag {tier}";

      if (thresholdCell == ClearToken || percentCell == ClearToken)
      {
        if (currentThreshold is null) continue;
        change.Tiers[(byte)tier] = null;
        change.Changes.Add(new(label, Tier(currentThreshold, currentPercent), "splošna lestvica"));
        continue;
      }

      decimal? threshold = currentThreshold, percent = currentPercent;
      if (thresholdCell.Length > 0)
      {
        if (ParseDecimal(thresholdCell) is not { } parsed) { problems.Add($"{where}: prag {tier} »{thresholdCell}« ni število."); continue; }
        threshold = parsed;
      }
      if (percentCell.Length > 0)
      {
        if (ParseDecimal(percentCell) is not { } parsed) { problems.Add($"{where}: rabat {tier} »{percentCell}« ni število."); continue; }
        percent = parsed;
      }
      if (threshold is null || percent is null)
      {
        problems.Add($"{where}: stopnja {tier} potrebuje prag in rabat — vpiši oba.");
        continue;
      }
      if (threshold < 0 || percent <= 0 || percent > 100)
      {
        problems.Add($"{where}: stopnja {tier} — prag mora biti 0 ali več, rabat med 0 in 100 %.");
        continue;
      }
      if (threshold == currentThreshold && percent == currentPercent) continue;
      change.Tiers[(byte)tier] = (threshold.Value, percent.Value);
      change.Changes.Add(new(label, currentThreshold is null ? "splošna lestvica" : Tier(currentThreshold, currentPercent), Tier(threshold, percent)));
    }
  }

  static void ReadGroups(CustomerWorkbookRowChange change, string text, IReadOnlyDictionary<(int, string), string> itemGroups,
    string where, List<string> problems, List<string> warnings)
  {
    if (text.Length == 0) return;
    var current = ParseGroupList(change.Current.GroupDiscounts, out _);
    var wanted = new Dictionary<string, decimal>(StringComparer.OrdinalIgnoreCase);
    if (text != ClearToken)
    {
      var typed = ParseGroupList(text, out var error);
      if (error is not null) { problems.Add($"{where}: skupinski popusti — {error}"); return; }
      foreach (var (group, percent) in typed)
      {
        if (itemGroups.TryGetValue((change.Current.OrganizationId, group.ToUpperInvariant()), out var canonical))
          wanted[canonical] = percent;
        else
        {
          wanted[group] = percent;
          warnings.Add($"{where}: skupina »{group}« ni skupina artiklov nobenega izdelka tega podjetja — popust se zapiše, a v Magentu ne bo zadel izdelka.");
        }
      }
    }

    foreach (var (group, percent) in wanted)
      if (!current.TryGetValue(group, out var old) || old != percent) change.Groups[group] = percent;
    foreach (var group in current.Keys)
      if (!wanted.ContainsKey(group)) change.Groups[group] = null;

    if (change.Groups.Count > 0)
      change.Changes.Add(new("Skupinski popusti", change.Current.GroupDiscounts, FormatGroups(wanted)));
  }

  static void ReadSpecials(CustomerWorkbookRowChange change, string text, IReadOnlySet<string> packagingCodes,
    string where, List<string> problems)
  {
    if (text.Length == 0) return;
    var current = ParseSpecialList(change.Current.SpecialDiscounts, out _);
    Dictionary<string, string> wanted;
    if (text == ClearToken) wanted = new(StringComparer.OrdinalIgnoreCase);
    else
    {
      wanted = ParseSpecialList(text, out var error);
      if (error is not null) { problems.Add($"{where}: posebni S — {error}"); return; }
      var unknown = wanted.Values.Where(code => !packagingCodes.Contains(code)).Distinct().ToArray();
      if (unknown.Length > 0)
      {
        problems.Add($"{where}: posebni S — neznana koda {string.Join(", ", unknown)}; dovoljene so {string.Join(", ", packagingCodes.Order())}.");
        return;
      }
    }

    // 274: levo je obseg — artikel, SKUPINA:koda, S:S2 ali *. Ključ je enoten zapis obsega.
    wanted = wanted.ToDictionary(pair => PackagingDiscountService.ParseScope(pair.Key)?.Text ?? pair.Key, pair => pair.Value,
      StringComparer.OrdinalIgnoreCase);
    current = current.ToDictionary(pair => PackagingDiscountService.ParseScope(pair.Key)?.Text ?? pair.Key, pair => pair.Value,
      StringComparer.OrdinalIgnoreCase);
    foreach (var (item, code) in wanted)
      if (!current.TryGetValue(item, out var old) || !string.Equals(old, code, StringComparison.OrdinalIgnoreCase)) change.Specials[item] = code;
    foreach (var item in current.Keys)
      if (!wanted.ContainsKey(item)) change.Specials[item] = null;

    if (change.Specials.Count > 0)
      change.Changes.Add(new("Posebni S", change.Current.SpecialDiscounts, FormatSpecials(wanted)));
  }

  static void ReadContacts(CustomerWorkbookRowChange change, Func<string, string> cell)
  {
    var row = change.Current;
    string? Next(string key, string? old)
    {
      var text = cell(key);
      return text.Length == 0 ? old : text == ClearToken ? null : text;
    }

    var email = Next(EmailKey, row.Email);
    var phone = Next(PhoneKey, row.Phone);
    var mobile = Next(MobileKey, row.Mobile);
    var persons = Next(PersonsKey, row.Persons);
    var before = change.Changes.Count;
    if (email != row.Email) change.Changes.Add(new("E-pošta", row.Email, email));
    if (phone != row.Phone) change.Changes.Add(new("Telefon", row.Phone, phone));
    if (mobile != row.Mobile) change.Changes.Add(new("Mobitel", row.Mobile, mobile));
    if (persons != row.Persons) change.Changes.Add(new("Osebe", row.Persons, persons));
    if (change.Changes.Count > before) change.Contact = new(email, phone, mobile, persons);
  }

  /// <summary>279: dodatni popust (P2) — isti zapis in ista pravila celice kot skupinski popusti.</summary>
  static void ReadExtraGroups(CustomerWorkbookRowChange change, string text, IReadOnlyDictionary<(int, string), string> itemGroups,
    string where, List<string> problems, List<string> warnings)
  {
    if (text.Length == 0) return;
    var current = ParseGroupList(change.Current.ExtraGroupDiscounts, out _);
    var wanted = new Dictionary<string, decimal>(StringComparer.OrdinalIgnoreCase);
    if (text != ClearToken)
    {
      var typed = ParseGroupList(text, out var error);
      if (error is not null) { problems.Add($"{where}: dodatni popust — {error}"); return; }
      foreach (var (group, percent) in typed)
      {
        if (itemGroups.TryGetValue((change.Current.OrganizationId, group.ToUpperInvariant()), out var canonical))
          wanted[canonical] = percent;
        else
        {
          wanted[group] = percent;
          warnings.Add($"{where}: skupina »{group}« ni skupina artiklov nobenega izdelka tega podjetja — dodatni popust se zapiše, a v Magentu ne bo zadel izdelka.");
        }
      }
    }

    foreach (var (group, percent) in wanted)
      if (!current.TryGetValue(group, out var old) || old != percent) change.ExtraGroups[group] = percent;
    foreach (var group in current.Keys)
      if (!wanted.ContainsKey(group)) change.ExtraGroups[group] = null;

    if (change.ExtraGroups.Count > 0)
      change.Changes.Add(new("Dodatni popust (P2)", change.Current.ExtraGroupDiscounts, FormatGroups(wanted)));
  }

  static void ReadExtra(CustomerWorkbookRowChange change, Func<string, string> cell)
  {
    var row = change.Current;
    string? Next(string key, string? old)
    {
      var text = cell(key);
      return text.Length == 0 ? old : text == ClearToken ? null : text;
    }

    var manager = Next(ManagerKey, row.AccountManager);
    var delivery = Next(DeliveryEmailKey, row.DeliveryNoteEmail);
    var noticeEmail = Next(NoticeEmailKey, row.NoticeEmail);
    var noticePerson = Next(NoticePersonKey, row.NoticePerson);
    var before = change.Changes.Count;
    if (manager != row.AccountManager) change.Changes.Add(new("Skrbnik", row.AccountManager, manager));
    if (delivery != row.DeliveryNoteEmail) change.Changes.Add(new("E-pošta za dobavnice", row.DeliveryNoteEmail, delivery));
    if (noticeEmail != row.NoticeEmail) change.Changes.Add(new("E-pošta za obveščanje", row.NoticeEmail, noticeEmail));
    if (noticePerson != row.NoticePerson) change.Changes.Add(new("Oseba za obveščanje", row.NoticePerson, noticePerson));
    if (change.Changes.Count > before) change.Extra = new(manager, delivery, noticeEmail, noticePerson);

    // Opomba se doda, ne prepiše. Besedilo, ki ga zaznamki že nosijo, se ne podvoji (ponovni uvoz iste datoteke).
    var note = cell(AddNoteKey);
    if (note.Length > 0 && note != ClearToken && !Collapse(row.Notes ?? "").Contains(Collapse(note), StringComparison.Ordinal))
    {
      change.Note = note;
      change.Changes.Add(new("Nova opomba", null, note));
    }

    static string Collapse(string text) => string.Join(' ', text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
  }

  /* --- Uvoz: zapis ---------------------------------------------------------------------------- */

  public async Task<CustomerWorkbookOutcome> ApplyAsync(CustomerWorkbookPreview preview, string actor,
    IProgress<string>? progress = null, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);

    var problems = new List<string>();
    var touched = 0;
    var written = 0;
    var exportRows = 0;
    var catalogProducts = new HashSet<(int, string)>();
    var organizations = new SortedSet<string>(StringComparer.CurrentCulture);

    for (var index = 0; index < preview.Rows.Count; index++)
    {
      var change = preview.Rows[index];
      var row = change.Current;
      var where = $"Vrstica {change.RowNumber} ({row.OrganizationName} {row.CustomerKey})";
      var before = written;
      if (index % 25 == 0) progress?.Report($"Zapisujem stranko {index + 1:N0} od {preview.Rows.Count:N0} …");

      if (change.Profile is { } profile)
        await TryAsync("B2B nastavitve", () => SaveProfileAsync(connection, row, profile, actor, cancellationToken));

      foreach (var (tier, target) in change.Tiers)
        await TryAsync($"prag {tier}", () => target is { } value
          ? ExecAsync(connection, "b2b.SaveCustomerValueTier", command =>
            {
              AddCustomer(command, row);
              command.Parameters.Add("@TierNumber", SqlDbType.TinyInt).Value = tier;
              AddDecimal(command, "@ThresholdGrossExVat", value.Threshold, 19, 4);
              AddDecimal(command, "@PercentValue", value.Percent, 9, 4);
              command.Parameters.Add("@ChangedBy", SqlDbType.NVarChar, 200).Value = actor;
            }, cancellationToken)
          : ExecAsync(connection, "b2b.RemoveCustomerValueTier", command =>
            {
              AddCustomer(command, row);
              command.Parameters.Add("@TierNumber", SqlDbType.TinyInt).Value = tier;
              command.Parameters.Add("@ChangedBy", SqlDbType.NVarChar, 200).Value = actor;
            }, cancellationToken));

      if (change.Groups.Count > 0)
      {
        var active = await ActiveGroupOverridesAsync(connection, row, cancellationToken);
        foreach (var (group, percent) in change.Groups)
          await TryAsync($"skupinski popust {group}", () => ReplaceGroupAsync(connection, row, group, percent,
            active.Where(item => string.Equals(item.Group, group, StringComparison.OrdinalIgnoreCase)).Select(item => item.Id).ToArray(),
            actor, cancellationToken));
      }

      if (change.Specials.Count > 0)
      {
        var active = await ActiveSpecialOverridesAsync(connection, row, cancellationToken);
        foreach (var (item, code) in change.Specials)
        {
          var scope = PackagingDiscountService.ParseScope(item);
          var ok = scope is not null && await TryAsync($"posebni S za {item}", () => code is not null
            ? packaging.SaveRuleAsync(row.OrganizationId, new(PackagingDiscountService.TargetCustomer, null, row.CustomerId, null,
                scope.ScopeKind, scope.ItemId, scope.ItemGroupCode, scope.FromDiscountCode, code), actor, cancellationToken, connection)
            : RemoveSpecialsAsync(connection, row,
                active.Where(entry => string.Equals(entry.ItemId, item, StringComparison.OrdinalIgnoreCase)).Select(entry => entry.Id).ToArray(),
                actor, cancellationToken));
          if (ok) catalogProducts.Add((row.OrganizationId, item.ToUpperInvariant()));
        }
      }

      if (change.Contact is { } contact)
        await TryAsync("kontakti", () => ExecAsync(connection, "b2b.SaveCustomerContact", command =>
        {
          AddCustomer(command, row);
          command.Parameters.Add("@Email", SqlDbType.NVarChar, 400).Value = (object?)contact.Email ?? DBNull.Value;
          command.Parameters.Add("@Phone", SqlDbType.NVarChar, 200).Value = (object?)contact.Phone ?? DBNull.Value;
          command.Parameters.Add("@Mobile", SqlDbType.NVarChar, 200).Value = (object?)contact.Mobile ?? DBNull.Value;
          command.Parameters.Add("@Persons", SqlDbType.NVarChar, 1000).Value = (object?)contact.Persons ?? DBNull.Value;
          command.Parameters.Add("@ChangedBy", SqlDbType.NVarChar, 200).Value = actor;
        }, cancellationToken));

      if (change.Extra is { } extra)
        await TryAsync("skrbnik in e-pošta za dobavnice/obveščanje", () => ExecAsync(connection, "b2b.SaveCustomerExtra", command =>
        {
          AddCustomer(command, row);
          command.Parameters.Add("@AccountManager", SqlDbType.NVarChar, 200).Value = (object?)extra.AccountManager ?? DBNull.Value;
          command.Parameters.Add("@DeliveryNoteEmail", SqlDbType.NVarChar, 400).Value = (object?)extra.DeliveryNoteEmail ?? DBNull.Value;
          command.Parameters.Add("@NoticeEmail", SqlDbType.NVarChar, 400).Value = (object?)extra.NoticeEmail ?? DBNull.Value;
          command.Parameters.Add("@NoticePerson", SqlDbType.NVarChar, 400).Value = (object?)extra.NoticePerson ?? DBNull.Value;
          command.Parameters.Add("@ChangedBy", SqlDbType.NVarChar, 200).Value = actor;
        }, cancellationToken));

      foreach (var (group, percent) in change.ExtraGroups)
        await TryAsync($"dodatni popust {group}", () => percent is { } value
          ? ExecAsync(connection, "b2b.SaveCustomerExtraGroupDiscount", command =>
            {
              AddCustomer(command, row);
              command.Parameters.Add("@ItemGroupCode", SqlDbType.NVarChar, 100).Value = group;
              AddDecimal(command, "@PercentValue", value, 9, 4);
              command.Parameters.Add("@ChangedBy", SqlDbType.NVarChar, 200).Value = actor;
            }, cancellationToken)
          : ExecAsync(connection, "b2b.RemoveCustomerExtraGroupDiscount", command =>
            {
              AddCustomer(command, row);
              command.Parameters.Add("@ItemGroupCode", SqlDbType.NVarChar, 100).Value = group;
              command.Parameters.Add("@ChangedBy", SqlDbType.NVarChar, 200).Value = actor;
            }, cancellationToken));

      if (change.Note is { } note)
        await TryAsync("opomba", () => ExecAsync(connection, "intranet.AddCustomerNote", command =>
        {
          AddCustomer(command, row);
          command.Parameters.Add("@Body", SqlDbType.NVarChar, 4000).Value = note;
          command.Parameters.Add("@CreatedBy", SqlDbType.NVarChar, 200).Value = actor;
        }, cancellationToken));

      if (written > before)
      {
        touched++;
        organizations.Add(row.OrganizationName);
        if (row.InCustomerExport || (change.Profile is not null && row.SourceIsActive)) exportRows++;
      }

      async Task<bool> TryAsync(string what, Func<Task> action)
      {
        try
        {
          await action();
          written++;
          return true;
        }
        catch (SqlException failure)
        {
          problems.Add($"{where}: {what} ni zapisan — {failure.Message}");
          return false;
        }
      }
    }

    // 274: pravila posebnega S po tipu stranke (drugi list).
    foreach (var rule in preview.TypeRules ?? [])
    {
      try
      {
        if (rule.RemoveRuleId is { } removeId) await packaging.RemoveRuleAsync(rule.OrganizationId, removeId, actor, cancellationToken, connection);
        else await packaging.SaveRuleAsync(rule.OrganizationId, rule.Input, actor, cancellationToken, connection);
        written++;
        organizations.Add(rule.OrganizationName);
      }
      catch (SqlException failure) { problems.Add($"List »{TypeRulesSheetName}«, vrstica {rule.RowNumber}: {rule.Description} ni zapisano — {failure.Message}"); }
    }

    return new(touched, written, exportRows, catalogProducts.Count, organizations.ToArray(), problems);
  }

  static Task SaveProfileAsync(SqlConnection connection, CustomerListRow row,
    CustomerWorkbookRowChange.ProfileTarget profile, string actor, CancellationToken cancellationToken) =>
    // Procedura prepiše vseh devet stolpcev profila (020), zato gre vanjo celoten profil —
    // nespremenjena polja s trenutno vrednostjo, WebEnabled vedno trenutni.
    ExecAsync(connection, "b2b.SaveCustomerWebProfile", command =>
    {
      AddCustomer(command, row);
      command.Parameters.Add("@CustomerTypeCode", SqlDbType.NVarChar, 60).Value = (object?)profile.TypeCode ?? DBNull.Value;
      command.Parameters.Add("@CustomerKind", SqlDbType.NVarChar, 20).Value = (object?)profile.Kind ?? DBNull.Value;
      command.Parameters.Add("@PackagingDiscountEnabled", SqlDbType.Bit).Value = profile.Packaging;
      command.Parameters.Add("@ValueDiscountEnabled", SqlDbType.Bit).Value = profile.Value;
      command.Parameters.Add("@B2bPlusEnabled", SqlDbType.Bit).Value = profile.Plus;
      command.Parameters.Add("@B2bPlusValidFrom", SqlDbType.Date).Value = (object?)profile.PlusFrom?.Date ?? DBNull.Value;
      command.Parameters.Add("@B2bPlusValidTo", SqlDbType.Date).Value = (object?)profile.PlusTo?.Date ?? DBNull.Value;
      command.Parameters.Add("@WebEnabled", SqlDbType.Bit).Value = row.WebEnabled;
      command.Parameters.Add("@ChangedBy", SqlDbType.NVarChar, 200).Value = actor;
    }, cancellationToken);

  /// <summary>
  /// Sprememba skupinskega popusta je umik starega in vpis novega (b2b.SaveGroupDiscountOverride
  /// zna samo dodati). Oboje v eni transakciji, da skupina ob napaki vpisa ne ostane brez popusta.
  /// </summary>
  static async Task ReplaceGroupAsync(SqlConnection connection, CustomerListRow row, string group, decimal? percent,
    IReadOnlyList<long> activeIds, string actor, CancellationToken cancellationToken)
  {
    await using var transaction = (SqlTransaction)await connection.BeginTransactionAsync(cancellationToken);
    try
    {
      foreach (var id in activeIds)
        await ExecAsync(connection, "b2b.RemoveGroupDiscountOverride", command =>
        {
          command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = row.OrganizationId;
          command.Parameters.Add("@OverrideId", SqlDbType.BigInt).Value = id;
          command.Parameters.Add("@ChangedBy", SqlDbType.NVarChar, 200).Value = actor;
        }, cancellationToken, transaction);

      if (percent is { } value)
        await ExecAsync(connection, "b2b.SaveGroupDiscountOverride", command =>
        {
          command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = row.OrganizationId;
          command.Parameters.Add("@TargetKind", SqlDbType.NVarChar, 20).Value = "CUSTOMER";
          command.Parameters.Add("@CustomerId", SqlDbType.BigInt).Value = row.CustomerId;
          command.Parameters.Add("@ItemGroupCode", SqlDbType.NVarChar, 100).Value = group;
          AddDecimal(command, "@PercentValue", value, 9, 4);
          command.Parameters.Add("@ChangedBy", SqlDbType.NVarChar, 200).Value = actor;
        }, cancellationToken, transaction);

      await transaction.CommitAsync(cancellationToken);
    }
    catch
    {
      // Napaka v proceduri z XACT_ABORT transakcijo že razveljavi; drugi preklic bi vrgel svojo napako.
      try { await transaction.RollbackAsync(CancellationToken.None); } catch (InvalidOperationException) { }
      throw;
    }
  }

  static async Task RemoveSpecialsAsync(SqlConnection connection, CustomerListRow row, IReadOnlyList<long> ids,
    string actor, CancellationToken cancellationToken)
  {
    foreach (var id in ids)
      await ExecAsync(connection, "b2b.RemovePackagingDiscountRule", command =>
      {
        command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = row.OrganizationId;
        command.Parameters.Add("@RuleId", SqlDbType.BigInt).Value = id;
        command.Parameters.Add("@ChangedBy", SqlDbType.NVarChar, 200).Value = actor;
      }, cancellationToken);
  }

  static async Task<IReadOnlyList<(long Id, string Group)>> ActiveGroupOverridesAsync(
    SqlConnection connection, CustomerListRow row, CancellationToken cancellationToken)
  {
    await using var command = new SqlCommand("""
      SELECT OverrideId, ItemGroupCode FROM b2b.GroupDiscountOverride
      WHERE OrganizationId = @OrganizationId AND TargetKind = N'CUSTOMER' AND CustomerId = @CustomerId AND IsActive = 1;
      """, connection);
    AddCustomer(command, row);
    var rows = new List<(long, string)>();
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    while (await reader.ReadAsync(cancellationToken)) rows.Add((reader.GetInt64(0), reader.GetString(1)));
    return rows;
  }

  static async Task<IReadOnlyList<(long Id, string ItemId)>> ActiveSpecialOverridesAsync(
    SqlConnection connection, CustomerListRow row, CancellationToken cancellationToken)
  {
    // 274: vsa pravila stranke (artikel, rabatna skupina, S koda, vsi) v zapisu obsega iz celice.
    await using var command = new SqlCommand("""
      SELECT rule274.RuleId, ScopeText = CASE rule274.ScopeKind WHEN N'ITEM' THEN product.ItemID
        WHEN N'ITEM_GROUP' THEN N'SKUPINA:' + rule274.ItemGroupCode WHEN N'S_CODE' THEN N'S:' + rule274.FromDiscountCode ELSE N'*' END
      FROM b2b.PackagingDiscountRule AS rule274
      LEFT JOIN pim.Product AS product ON product.PimProductId = rule274.PimProductId
      WHERE rule274.TargetKind = N'CUSTOMER' AND rule274.CustomerId = @CustomerId
        AND rule274.OrganizationId = @OrganizationId AND rule274.IsActive = 1;
      """, connection);
    AddCustomer(command, row);
    var rows = new List<(long, string)>();
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    while (await reader.ReadAsync(cancellationToken)) rows.Add((reader.GetInt64(0), reader.GetString(1)));
    return rows;
  }

  static async Task ExecAsync(SqlConnection connection, string procedure, Action<SqlCommand> bind,
    CancellationToken cancellationToken, SqlTransaction? transaction = null)
  {
    await using var command = new SqlCommand(procedure, connection, transaction) { CommandType = CommandType.StoredProcedure };
    bind(command);
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  static void AddCustomer(SqlCommand command, CustomerListRow row)
  {
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = row.OrganizationId;
    command.Parameters.Add("@CustomerId", SqlDbType.BigInt).Value = row.CustomerId;
  }

  static void AddDecimal(SqlCommand command, string name, decimal value, byte precision, byte scale)
  {
    var parameter = command.Parameters.Add(name, SqlDbType.Decimal);
    parameter.Precision = precision;
    parameter.Scale = scale;
    parameter.Value = value;
  }

  /* --- Šifranti za preverjanje ------------------------------------------------------------- */

  async Task<IReadOnlyDictionary<int, string>> OrganizationsAsync(CancellationToken cancellationToken) =>
    (await ReadAsync("SELECT OrganizationId, Name FROM dbo.OrganizationConfig;",
      reader => (reader.GetInt32(0), reader.GetString(1)), cancellationToken))
      .ToDictionary(row => row.Item1, row => row.Item2);

  /// <summary>Koda → ime tipa stranke.</summary>
  async Task<IReadOnlyDictionary<string, string>> CustomerTypesAsync(CancellationToken cancellationToken) =>
    (await ReadAsync("SELECT CustomerTypeCode, Name FROM pim.CustomerTypeCatalog WHERE IsActive = 1;",
      reader => (reader.GetString(0), reader.GetString(1)), cancellationToken))
      .ToDictionary(row => row.Item1, row => row.Item2, StringComparer.OrdinalIgnoreCase);

  async Task<IReadOnlySet<string>> PackagingCodesAsync(CancellationToken cancellationToken) =>
    (await ReadAsync("SELECT DiscountCode FROM pim.PackagingDiscountCatalog WHERE IsActive = 1;",
      reader => reader.GetString(0), cancellationToken)).ToHashSet(StringComparer.OrdinalIgnoreCase);

  /// <summary>
  /// Skupine artiklov po podjetju (velike črke → zapis v katalogu). Skupinski popust v stranke.csv
  /// zadene izdelek po tej kodi, zato uvoz zapiše kodo tako, kot jo nosi izdelek.
  /// </summary>
  async Task<IReadOnlyDictionary<(int, string), string>> ItemGroupsAsync(CancellationToken cancellationToken)
  {
    var rows = await ReadAsync("""
      SELECT OrganizationId, ItemGroup FROM canon.Product WHERE ItemGroup IS NOT NULL GROUP BY OrganizationId, ItemGroup
      UNION SELECT OrganizationId, DiscountGroup FROM canon.Product WHERE DiscountGroup IS NOT NULL GROUP BY OrganizationId, DiscountGroup;
      """, reader => (reader.GetInt32(0), reader.GetString(1)), cancellationToken);
    var groups = new Dictionary<(int, string), string>();
    foreach (var (organizationId, code) in rows) groups.TryAdd((organizationId, code.ToUpperInvariant()), code);
    return groups;
  }

  async Task<List<T>> ReadAsync<T>(string sql, Func<SqlDataReader, T> map, CancellationToken cancellationToken)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand(sql, connection) { CommandTimeout = 120 };
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var rows = new List<T>();
    while (await reader.ReadAsync(cancellationToken)) rows.Add(map(reader));
    return rows;
  }

  /* --- Branje celic -------------------------------------------------------------------------- */

  static int? ResolveOrganization(IReadOnlyDictionary<int, string> organizations, string text)
  {
    if (int.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out var id) && organizations.ContainsKey(id)) return id;
    foreach (var (key, name) in organizations)
      if (WorkbookHeader.Same(name, text)) return key;
    return null;
  }

  static string? ParseKind(string text)
  {
    foreach (var (code, label) in CustomerRoles.Kinds)
      if (WorkbookHeader.Same(code, text) || WorkbookHeader.Same(label, text)) return code;
    return null;
  }

  static string? ParseType(IReadOnlyDictionary<string, string> types, string text)
  {
    if (types.ContainsKey(text)) return types.Keys.First(code => string.Equals(code, text, StringComparison.OrdinalIgnoreCase));
    foreach (var (code, name) in types)
      if (WorkbookHeader.Same(name, text)) return code;
    return null;
  }

  static bool ReadFlag(string text, string label, ref bool target, string where, List<string> problems)
  {
    if (text.Length == 0) return true;
    if (ProductWorkbookContract.ParseYesNo(text) is { } parsed) { target = parsed; return true; }
    problems.Add($"{where}: {label} »{text}« ni D ali N.");
    return false;
  }

  static bool ReadDate(string text, string label, ref DateTime? target, string where, List<string> problems)
  {
    if (text.Length == 0) return true;
    if (text == ClearToken) { target = null; return true; }
    if (ParseDate(text) is { } parsed) { target = parsed; return true; }
    problems.Add($"{where}: {label} »{text}« ni datum (npr. 1. 10. 2026).");
    return false;
  }

  /// <summary>Excel datum pride kot zaporedna številka (46296), ročno vpisan pa kot besedilo.</summary>
  public static DateTime? ParseDate(string text)
  {
    if (double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var serial) && serial is > 20_000 and < 80_000)
      return DateTime.FromOADate(serial).Date;
    var compact = text.Replace(" ", "", StringComparison.Ordinal);
    string[] formats = ["d.M.yyyy", "dd.MM.yyyy", "yyyy-MM-dd", "d.M.yy", "yyyy-MM-ddTHH:mm:ss"];
    return DateTime.TryParseExact(compact, formats, CultureInfo.InvariantCulture, DateTimeStyles.None, out var parsed)
      ? parsed.Date : null;
  }

  /// <summary>Sprejme »10«, »10,5«, »10.5«, »1.500,00«, »10 %«, »800 €«.</summary>
  public static decimal? ParseDecimal(string text)
  {
    var value = text.Replace("%", "", StringComparison.Ordinal).Replace("€", "", StringComparison.Ordinal)
      .Replace(" ", "", StringComparison.Ordinal).Replace(" ", "", StringComparison.Ordinal);
    if (value.Length == 0) return null;
    var comma = value.LastIndexOf(',');
    var dot = value.LastIndexOf('.');
    if (comma >= 0 && dot >= 0)
      value = comma > dot ? value.Replace(".", "", StringComparison.Ordinal).Replace(',', '.') : value.Replace(",", "", StringComparison.Ordinal);
    else if (comma >= 0)
      value = value.Replace(',', '.');
    return decimal.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out var parsed) ? parsed : null;
  }

  /// <summary>»NW=10 | AR=5« → skupina → odstotek. Zapis je isti kot v stranke.csv, samo brez »%«.</summary>
  public static Dictionary<string, decimal> ParseGroupList(string? text, out string? error)
  {
    error = null;
    var result = new Dictionary<string, decimal>(StringComparer.OrdinalIgnoreCase);
    foreach (var item in Items(text))
    {
      var separator = item.LastIndexOf('=');
      var group = separator > 0 ? item[..separator].Trim() : "";
      var percent = separator > 0 ? ParseDecimal(item[(separator + 1)..]) : null;
      if (group.Length == 0 || percent is null) { error = $"»{item}« ni v obliki SKUPINA=%, npr. NW=10."; return result; }
      if (percent <= 0 || percent > 100) { error = $"»{item}«: odstotek mora biti med 0 in 100."; return result; }
      if (!result.TryAdd(group, percent.Value)) { error = $"skupina {group} je v celici dvakrat."; return result; }
    }
    return result;
  }

  /// <summary>»ART1\S2 | ART2\S3« → artikel → S koda. Isti zapis kot stolpec v katalog.csv, le da je tu artikel namesto stranke.</summary>
  public static Dictionary<string, string> ParseSpecialList(string? text, out string? error)
  {
    error = null;
    var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    foreach (var item in Items(text))
    {
      var separator = item.LastIndexOf('\\');
      var itemId = separator > 0 ? item[..separator].Trim() : "";
      var code = separator > 0 ? item[(separator + 1)..].Trim().ToUpperInvariant() : "";
      if (itemId.Length == 0 || code.Length == 0) { error = $"»{item}« ni v obliki ARTIKEL\\S2."; return result; }
      if (!result.TryAdd(itemId, code)) { error = $"artikel {itemId} je v celici dvakrat."; return result; }
    }
    return result;
  }

  static IEnumerable<string> Items(string? text) =>
    string.IsNullOrWhiteSpace(text)
      ? []
      : text.Split(ProductWorkbookContract.ListSeparator, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

  static string? FormatGroups(IReadOnlyDictionary<string, decimal> groups) =>
    groups.Count == 0 ? null : string.Join(" | ", groups.OrderBy(pair => pair.Key, StringComparer.OrdinalIgnoreCase)
      .Select(pair => pair.Key + "=" + pair.Value.ToString("0.####", CultureInfo.InvariantCulture)));

  static string? FormatSpecials(IReadOnlyDictionary<string, string> specials) =>
    specials.Count == 0 ? null : string.Join(" | ", specials.OrderBy(pair => pair.Key, StringComparer.OrdinalIgnoreCase)
      .Select(pair => pair.Key + "\\" + pair.Value));

  static string YesNo(bool value) => ProductWorkbookContract.SheetYesNo(value);
  static string? Day(DateTime? value) => value?.ToString("d. M. yyyy", CultureInfo.InvariantCulture);
  static string? Tier(decimal? threshold, decimal? percent) =>
    threshold is null ? null
      : $"{threshold.Value.ToString("0.##", CultureInfo.InvariantCulture)} € → {percent?.ToString("0.##", CultureInfo.InvariantCulture)} %";
}
