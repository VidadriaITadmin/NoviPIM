using System.Data;
using Microsoft.Data.SqlClient;
using PIM.Operations;

namespace PIM.Intranet.Services;

/// <param name="ItemIdFromEan">Dobavitelj sifre ne posilja; kandidat (in ob odobritvi artikel) je kljucan po EAN (240).</param>
/// <param name="SupplierTitle">Dobaviteljev naziv iz istega zajema, kadar ga vir sploh preslika; sicer null.</param>
/// <param name="ProductItemId">Trenutna sifra ustvarjenega artikla (241): po prevzemu sifre iz SAOP se razlikuje od kljuca kandidata.</param>
/// <param name="ErpExistence"><c>NOT_YET_IN_ERP</c> ali <c>CONFIRMED_IN_ERP</c> ustvarjenega artikla; null, dokler artikla ni.</param>
/// <param name="SaopState">Stanje odobrenega kandidata na poti v SAOP (241): NOT_QUEUED, QUEUED, SENT, FAILED, CONFIRMED; null za neodobrene.</param>
/// <param name="SaopLiveMessages">Sporocila artikla, ki v vrsti se cakajo (odobritev, posiljanje, ponovni poskus).</param>
/// <param name="SaopPendingApproval">Od tega taka, ki cakajo na odobritev.</param>
/// <param name="SaopLastStatus">Stanje zadnjega sporocila artikla v odhodni vrsti.</param>
/// <param name="SaopAssignedItemId">Sifra, ki jo je SAOP dodelil ob ADD; ob koliziji edino mesto, kjer jo urednik vidi.</param>
public sealed record SupplierProductCandidateRow(
  long SupplierProductCandidateId, int OrganizationId, string OrganizationName, string SourceCode,
  string ItemId, string? Ean, string Status, bool IsActive, DateTime FirstSeenUtc, DateTime LastSeenUtc,
  int OccurrenceCount, DateTime? DecidedUtc, string? DecidedBy, string? DecisionReason, long? CreatedProductId,
  bool ItemIdFromEan, Guid RunId, string EntityType, string? SupplierTitle,
  string? ProductItemId, string? ErpExistence, string? SaopState, int SaopLiveMessages, int SaopPendingApproval,
  string? SaopLastStatus, long? SaopLastBatchId, DateTime? SaopLastUpdatedUtc, string? SaopLastError, string? SaopAssignedItemId)
{
  /// <summary>Sifra, pod katero je artikel danes v PIM; pred uvozom kljuc kandidata.</summary>
  public string CurrentItemId => ProductItemId ?? ItemId;

  /// <summary>Ali je kandidat uvozen, artikla pa v SAOP se ni in v vrsti ne caka nic (241) — »porini v SAOP«.</summary>
  public bool CanQueueForSaop => Status == "PENDING" && CreatedProductId is null && SaopState is "NOT_QUEUED" or "FAILED";

  /// <summary>Ali je kandidat uvozen, SAOP pa artikla se ne pozna (ne glede na vrsto).</summary>
  public bool IsNotYetInErp => CreatedProductId is null || ErpExistence == "NOT_YET_IN_ERP";
}

/// <param name="ImportedWaitingCount">Uvozeni artikli, ki v SAOP se niso in ne cakajo v vrsti (241).</param>
/// <param name="QueuedCount">Uvozeni artikli s sporocili v vrsti (cakajo odobritev ali posiljanje).</param>
/// <param name="SentCount">Poslani, SAOP pa jih se ni potrdil (sifra/zastavica se ni prevzeta).</param>
/// <param name="FailedCount">Zadnji poskus v SAOP je bil zavrnjen.</param>
/// <param name="ConfirmedCount">Artikel obstaja v SAOP (CONFIRMED_IN_ERP).</param>
public sealed record SupplierProductCandidateTotals(
  long TotalCount, long PendingCount, long ApprovedCount, long RejectedCount,
  long ImportedWaitingCount = 0, long QueuedCount = 0, long SentCount = 0, long FailedCount = 0, long ConfirmedCount = 0);

public sealed record SupplierProductCandidatePage(
  IReadOnlyList<SupplierProductCandidateRow> Rows, SupplierProductCandidateTotals Totals);

/// <summary>Ena izluscena vrednost iz dobaviteljevega XML-ja za pregled kandidata (240).</summary>
public sealed record SupplierCandidateValueRow(string EntityType, string TargetFieldCode, int ValueOrdinal, string Value)
{
  public bool IsMedia => TargetFieldCode.StartsWith("ProductMedia.", StringComparison.OrdinalIgnoreCase);
  public bool IsDocument => TargetFieldCode.StartsWith("ProductDocument.", StringComparison.OrdinalIgnoreCase);
  public bool IsCategory => TargetFieldCode.StartsWith("ProductCategory.", StringComparison.OrdinalIgnoreCase);
  public bool IsAttribute => TargetFieldCode.StartsWith("ProductAttribute.", StringComparison.OrdinalIgnoreCase);
  public bool IsText => TargetFieldCode.StartsWith("ProductText.", StringComparison.OrdinalIgnoreCase);
  public bool IsUrl => Value.StartsWith("http://", StringComparison.OrdinalIgnoreCase) || Value.StartsWith("https://", StringComparison.OrdinalIgnoreCase) || Value.StartsWith("//", StringComparison.Ordinal);

  /// <summary>Ime brez predpone entitete: »ProductAttribute.Nazivna moč« → »Nazivna moč«.</summary>
  public string Label
  {
    get
    {
      var dot = TargetFieldCode.IndexOf('.');
      var rest = dot < 0 ? TargetFieldCode : TargetFieldCode[(dot + 1)..];
      return IsText ? ProductFieldLabels.TextTypeLabel(rest.Split('.')[0]) + (rest.Contains('.') ? " (" + rest.Split('.')[1] + ")" : "") : rest;
    }
  }

  /// <summary>Skupina za prikaz: besedila, kategorija, atributi, slike, dokumenti, ostalo.</summary>
  public string Group => IsText ? "Nazivi in opisi" : IsCategory ? "Kategorija dobavitelja" : IsAttribute ? "Atributi"
    : IsMedia ? "Slike" : IsDocument ? "Dokumenti" : "Identiteta in ostalo";
}

/// <summary>
/// Kam bi preslikava uvrstila kandidata (#7b): dobaviteljeva pot iz zadnjega zajema in naša
/// kategorija po drevesu. Isto pravilo kot <c>map.ResolveProductCategories</c> (ključ poti,
/// <c>map.CategoryPathMap</c>), zato stran pove natanko to, kar bo naredil zajem, ko bo artikel
/// ustvarjen v SAOP in ga naslednji XML obogati.
/// </summary>
/// <param name="SupplierPath">»Interior lighting / Ceiling lamps / Plafonds«; null, kadar dobavitelj kategorije ne pošlje.</param>
/// <param name="Trees">Po drevesu: naša pot ali null (preslikave ni).</param>
public sealed record SupplierCategoryPrediction(string? SupplierPath, string? SourcePathKey, IReadOnlyList<SupplierCategoryTarget> Trees)
{
  public IEnumerable<SupplierCategoryTarget> Mapped => Trees.Where(tree => tree.CategoryPath is not null);
  public IEnumerable<SupplierCategoryTarget> Unmapped => Trees.Where(tree => tree.CategoryPath is null);

  /// <summary>Dobavitelj pošlje kategorijo, preslikave pa ni v nobenem drevesu — artikel ostane brez uvrstitve.</summary>
  public bool IsError => SupplierPath is not null && !Mapped.Any();
}

public sealed record SupplierCategoryTarget(string CategoryTreeCode, string? CategoryPath);

/// <summary>Filter pregleda »Spremembe iz XML« (#7a); vse je v naslovu strani.</summary>
/// <param name="Kind">ATTRIBUTE, TEXT, MEDIA ali null (vse).</param>
/// <param name="Days">Zadnjih N dni; null = vsa zgodovina.</param>
/// <param name="Sort">novejse (privzeto), starejse, sifra.</param>
public sealed record SupplierXmlChangeFilter(
  int? OrganizationId = null, string? SourceCode = null, string? Kind = null, string? Search = null,
  int? Days = null, string Sort = "novejse", int Skip = 0, int Take = 50);

/// <summary>Ena sprememba polja, ki jo je naredil zajem dobaviteljevega XML (pim.ProductFieldHistory).</summary>
public sealed record SupplierXmlChangeRow(
  long ChangeId, int OrganizationId, string OrganizationName, string SourceCode, long ProductId, string ItemId,
  string FieldKey, string? CanonColumn, string? OldValue, string? NewValue, DateTime ChangedAtUtc)
{
  /// <summary>Zgodovina hrani največ 400 znakov (sprožilci 034); daljša vrednost je odrezana.</summary>
  public const int StoredLength = 400;

  public string Kind => SupplierXmlChangeKinds.KindOf(FieldKey);
  public bool IsMedia => Kind == SupplierXmlChangeKinds.Media;
  public bool OldTruncated => (OldValue?.Length ?? 0) >= StoredLength;
  public bool NewTruncated => (NewValue?.Length ?? 0) >= StoredLength;

  /// <summary>Kaj se je spremenilo, v besedah urednika: ime atributa, vrsta besedila z jezikom, slika z mestom.</summary>
  public string FieldLabel => SupplierXmlChangeKinds.FieldLabel(FieldKey, CanonColumn);

  /// <summary>Dodano, odstranjeno ali spremenjeno — iz prazne stare oz. nove vrednosti.</summary>
  public string Change => OldValue is null ? "dodano" : NewValue is null ? "odstranjeno" : "spremenjeno";
}

/// <param name="KindCounts">Število sprememb po vrsti pri istih ostalih filtrih (za čipe nad seznamom).</param>
/// <param name="LastReceived">Zadnji prevzem datoteke po viru (raw.Inbox) — ali XML sploh prihaja.</param>
public sealed record SupplierXmlChangePage(
  IReadOnlyList<SupplierXmlChangeRow> Rows, long Total, long ProductCount, DateTime? LastChangedUtc,
  IReadOnlyDictionary<string, long> KindCounts, IReadOnlyList<(string SourceCode, DateTime ReceivedUtc)> LastReceived);

/// <summary>Skupna pravila pregleda sprememb iz XML: vrste polj in njihova imena.</summary>
public static class SupplierXmlChangeKinds
{
  public const string Attribute = "ATTRIBUTE", Text = "TEXT", Media = "MEDIA", Other = "OTHER";

  public static readonly IReadOnlyList<(string Code, string Label)> Kinds =
    [(Attribute, "Atributi"), (Text, "Nazivi in opisi"), (Media, "Slike")];

  public static readonly IReadOnlyList<(string Code, string Label)> Sorts =
    [("novejse", "Najnovejše najprej"), ("starejse", "Najstarejše najprej"), ("sifra", "Po šifri")];

  public static readonly IReadOnlyList<int> DayOptions = [1, 7, 30, 90];

  /// <summary>
  /// »35 sprememb pri 1 artiklu« — s sklanjatvijo (preverjalec #7 je videl »pri 1 artiklih«).
  /// Po »pri« je mestnik: 1 artiklu, 2/3/5 artiklih; število sprememb je v imenovalniku/rodilniku.
  /// </summary>
  public static string Summary(long changes, long products)
  {
    var sl = System.Globalization.CultureInfo.GetCultureInfo("sl-SI");
    static string Form(long value, string one, string two, string few, string many) =>
      (Math.Abs(value) % 100) switch { 1 => one, 2 => two, 3 or 4 => few, _ => many };
    return $"{changes.ToString("N0", sl)} {Form(changes, "sprememba", "spremembi", "spremembe", "sprememb")} pri "
      + $"{products.ToString("N0", sl)} {Form(products, "artiklu", "artiklih", "artiklih", "artiklih")}";
  }

  public static string KindOf(string fieldKey) => fieldKey switch
  {
    "ProductAttribute.Value" => Attribute,
    "ProductText.Value" => Text,
    "ProductMedia.Url" => Media,
    _ => Other,
  };

  public static string? FieldKeyOf(string? kind) => kind switch
  {
    Attribute => "ProductAttribute.Value",
    Text => "ProductText.Value",
    Media => "ProductMedia.Url",
    _ => null,
  };

  public static string KindLabel(string kind) => kind switch
  {
    Attribute => "Atribut", Text => "Besedilo", Media => "Slika", _ => "Polje",
  };

  /// <summary>
  /// Sprožilci 034 v <c>CanonColumn</c> hranijo, KATERO polje: kodo/ime atributa, »VRSTA.jezik« pri
  /// besedilu, »VLOGA.mesto« pri sliki. Tu to postane ime, ki ga urednik pozna.
  /// </summary>
  public static string FieldLabel(string fieldKey, string? canonColumn)
  {
    var column = canonColumn ?? "";
    switch (KindOf(fieldKey))
    {
      case Text:
        {
          var dot = column.LastIndexOf('.');
          return dot < 0 ? ProductFieldLabels.TextTypeLabel(column) : $"{ProductFieldLabels.TextTypeLabel(column[..dot])} ({column[(dot + 1)..]})";
        }
      case Media:
        {
          var dot = column.LastIndexOf('.');
          return dot < 0 ? MediaLabel(column, null) : MediaLabel(column[..dot], column[(dot + 1)..]);
        }
      case Attribute:
        return column.Length == 0 ? "Atribut" : column;
      default:
        return ProductFieldLabels.For(fieldKey);
    }
  }

  /// <summary>
  /// Vloga slike iz zajema (PRIMARY, GALLERY, IMAGE …) po domače — preverjalec #7 je videl surovo
  /// »GALLERY 2«. Neznana vloga ostane vidna v oklepaju, da se ne izgubi, kaj je dobavitelj poslal.
  /// </summary>
  public static string MediaLabel(string? role, string? place)
  {
    var number = string.IsNullOrWhiteSpace(place) ? "" : " " + place.Trim();
    return (role ?? "").Trim().ToUpperInvariant() switch
    {
      "" or "IMAGE" or "SLIKA" => "Slika" + number,
      "PRIMARY" or "MAIN" => place is null or "1" ? "Glavna slika" : "Glavna slika" + number,
      "GALLERY" => "Dodatna slika" + number,
      "AMBIENT" => "Ambientna slika" + number,
      "THUMB" or "THUMBNAIL" => "Sličica" + number,
      var other => $"Slika{number} ({other.ToLowerInvariant()})",
    };
  }
}

/// <summary>
/// Bralni model kandidatov za nove artikle od dobaviteljev (219, 240, 241). SQL ostane v migraciji;
/// tu je samo klic procedure in preslikava stolpcev po imenu. Izjemi (#7, brez migracije, ker je
/// <c>docs/DATABASE.md</c> med delom zaklenjen): pregled sprememb iz XML in predlagana kategorija
/// kandidata sta parametrizirana SELECT-a nad obstoječimi tabelami.
/// </summary>
public sealed class SupplierCandidateReadService(IConfiguration configuration)
{
  string ConnectionString => ConnectionStringResolver.Resolve(configuration)
    ?? throw new InvalidOperationException("Povezava PIM ni nastavljena.");

  /// <param name="saopState">241: NOT_QUEUED, QUEUED, SENT, FAILED ali CONFIRMED; null = brez filtra. Velja samo za odobrene.</param>
  public async Task<SupplierProductCandidatePage> GetCandidatesAsync(
    int? organizationId, string? sourceCode, string? status, string? search, int skip, int take,
    string? saopState = null, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.GetSupplierProductCandidates", connection)
    { CommandType = CommandType.StoredProcedure, CommandTimeout = 60 };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = (object?)organizationId ?? DBNull.Value;
    command.Parameters.Add("@SourceCode", SqlDbType.NVarChar, 100).Value = Optional(sourceCode);
    command.Parameters.Add("@Status", SqlDbType.NVarChar, 20).Value = Optional(status);
    command.Parameters.Add("@Search", SqlDbType.NVarChar, 200).Value = Optional(search);
    command.Parameters.Add("@Skip", SqlDbType.Int).Value = skip;
    command.Parameters.Add("@Take", SqlDbType.Int).Value = take;
    command.Parameters.Add("@SaopState", SqlDbType.NVarChar, 20).Value = Optional(saopState);

    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var rows = new List<SupplierProductCandidateRow>();
    while (await reader.ReadAsync(cancellationToken))
      rows.Add(new(
        PimDb.Int64(reader, "SupplierProductCandidateId"), PimDb.Int32(reader, "OrganizationId"),
        PimDb.TextOrEmpty(reader, "OrganizationName"), PimDb.TextOrEmpty(reader, "SourceCode"),
        PimDb.TextOrEmpty(reader, "ItemID"), PimDb.Text(reader, "EAN"), PimDb.TextOrEmpty(reader, "Status"),
        PimDb.Bool(reader, "IsActive"), PimDb.DateTimeValue(reader, "FirstSeenUtc"), PimDb.DateTimeValue(reader, "LastSeenUtc"),
        PimDb.Int32(reader, "OccurrenceCount"), PimDb.NullableDateTime(reader, "DecidedUtc"), PimDb.Text(reader, "DecidedBy"),
        PimDb.Text(reader, "DecisionReason"), PimDb.NullableInt64(reader, "CreatedProductId"),
        PimDb.Bool(reader, "ItemIdFromEan"), reader.GetGuid(reader.GetOrdinal("RunId")),
        PimDb.TextOrEmpty(reader, "EntityType"), PimDb.Text(reader, "SupplierTitle"),
        PimDb.Text(reader, "ProductItemId"), PimDb.Text(reader, "ErpExistence"), PimDb.Text(reader, "SaopState"),
        PimDb.Int32(reader, "SaopLiveMessages"), PimDb.Int32(reader, "SaopPendingApproval"),
        PimDb.Text(reader, "SaopLastStatus"), PimDb.NullableInt64(reader, "SaopLastBatchId"),
        PimDb.NullableDateTime(reader, "SaopLastUpdatedUtc"), PimDb.Text(reader, "SaopLastError"),
        PimDb.Text(reader, "SaopAssignedItemId")));

    if (!await reader.NextResultAsync(cancellationToken))
      throw new InvalidOperationException("Bralna procedura kandidatov ni vrnila povzetka.");
    var totals = new SupplierProductCandidateTotals(0, 0, 0, 0);
    if (await reader.ReadAsync(cancellationToken))
      totals = new(
        PimDb.Int64(reader, "TotalCount"), PimDb.Int64(reader, "PendingCount"),
        PimDb.Int64(reader, "ApprovedCount"), PimDb.Int64(reader, "RejectedCount"),
        PimDb.Int64(reader, "ImportedWaitingCount"), PimDb.Int64(reader, "QueuedCount"),
        PimDb.Int64(reader, "SentCount"), PimDb.Int64(reader, "FailedCount"), PimDb.Int64(reader, "ConfirmedCount"));
    return new(rows, totals);
  }

  /// <summary>Vse, kar je dobavitelj v tem zajemu poslal za ta artikel (240) — pregled pred odlocitvijo.</summary>
  public async Task<IReadOnlyList<SupplierCandidateValueRow>> GetValuesAsync(long candidateId, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("intranet.GetSupplierProductCandidateValues", connection)
    { CommandType = CommandType.StoredProcedure, CommandTimeout = 120 };
    command.Parameters.Add("@SupplierProductCandidateId", SqlDbType.BigInt).Value = candidateId;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var rows = new List<SupplierCandidateValueRow>();
    while (await reader.ReadAsync(cancellationToken))
      rows.Add(new(
        PimDb.TextOrEmpty(reader, "EntityType"), PimDb.TextOrEmpty(reader, "TargetFieldCode"),
        PimDb.Int32(reader, "ValueOrdinal"), PimDb.TextOrEmpty(reader, "Value")));
    return rows;
  }

  static object Optional(string? value) => string.IsNullOrWhiteSpace(value) ? DBNull.Value : value.Trim();

  /* --- #7a: spremembe iz XML dobaviteljev po šifri ----------------------- */

  /// <summary>
  /// Paketi zgodovine, ki jih je naredil zajem dobaviteljevega XML. Ne po <c>ChangeSource='XML_FEED'</c>:
  /// isto oznako nosi tudi preslikava SAOP (<c>PIM.XmlMapping:SAOP_*</c>), ki bi se sicer pokazala kot
  /// »novost dobavitelja«. Dobavitelj = vir z vrsto <c>FILE_XML</c> v <c>map.SourceConnector</c>.
  /// Podjetje je v vrstici zgodovine, ne v paketu (paket XML ga nima).
  /// Branje brez deljenih zaklepov: zgodovina se samo dopisuje, zajem XML in drugi pisci pa jo polnijo
  /// v dolgih transakcijah — bralec (ta pregled) bi bil sicer žrtev zastoja (napaka 1205).
  /// </summary>
  internal const string SupplierXmlBatchesSql = """
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
    DECLARE @Paket TABLE (ChangeBatchId bigint NOT NULL PRIMARY KEY, SourceCode nvarchar(100) NOT NULL);
    INSERT @Paket (ChangeBatchId, SourceCode)
    SELECT paket.ChangeBatchId, vir.SourceCode
    FROM pim.ProductChangeBatch paket
    INNER JOIN (SELECT DISTINCT SourceCode FROM map.SourceConnector WHERE ConnectorType = N'FILE_XML') vir
      ON paket.ChangedBy = N'PIM.XmlMapping:' + vir.SourceCode
    WHERE paket.ChangeSource = N'XML_FEED' AND (@SourceCode IS NULL OR vir.SourceCode = @SourceCode);
    """;

  const string SupplierXmlFilterSql = """
      (@OrganizationId IS NULL OR h.OrganizationId = @OrganizationId)
      AND (@FromUtc IS NULL OR h.ChangedAtUtc >= @FromUtc)
      AND (@Search IS NULL OR h.ItemID LIKE @Search ESCAPE N'\')
    """;

  public async Task<SupplierXmlChangePage> GetXmlChangesAsync(SupplierXmlChangeFilter filter, CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(filter);
    var orderBy = XmlChangesOrderBy(filter.Sort);
    var sql = SupplierXmlBatchesSql + $"""

      SELECT h.FieldKey, COUNT_BIG(*) AS Changes
      FROM pim.ProductFieldHistory h
      INNER JOIN @Paket paket ON paket.ChangeBatchId = h.ChangeBatchId
      WHERE {SupplierXmlFilterSql}
      GROUP BY h.FieldKey
      OPTION (RECOMPILE);

      SELECT COUNT_BIG(*) AS Total, COUNT_BIG(DISTINCT h.ProductId) AS Products, MAX(h.ChangedAtUtc) AS LastChangedUtc
      FROM pim.ProductFieldHistory h
      INNER JOIN @Paket paket ON paket.ChangeBatchId = h.ChangeBatchId
      WHERE {SupplierXmlFilterSql} AND (@FieldKey IS NULL OR h.FieldKey = @FieldKey)
      OPTION (RECOMPILE);

      SELECT h.ChangeId, h.OrganizationId, COALESCE(organizacija.Name, CONCAT(N'Podjetje ', h.OrganizationId)) AS OrganizationName,
        paket.SourceCode, h.ProductId, h.ItemID, h.FieldKey, h.CanonColumn, h.OldValue, h.NewValue, h.ChangedAtUtc
      FROM pim.ProductFieldHistory h
      INNER JOIN @Paket paket ON paket.ChangeBatchId = h.ChangeBatchId
      LEFT JOIN dbo.OrganizationConfig organizacija ON organizacija.OrganizationId = h.OrganizationId
      WHERE {SupplierXmlFilterSql} AND (@FieldKey IS NULL OR h.FieldKey = @FieldKey)
      ORDER BY {orderBy}
      OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY
      OPTION (RECOMPILE);

      SELECT inbox.SourceCode, MAX(inbox.ReceivedUtc) AS ReceivedUtc
      FROM raw.Inbox inbox
      WHERE inbox.SourceCode IN (SELECT DISTINCT SourceCode FROM map.SourceConnector WHERE ConnectorType = N'FILE_XML')
        AND (@OrganizationId IS NULL OR inbox.OrganizationId = @OrganizationId)
      GROUP BY inbox.SourceCode
      ORDER BY inbox.SourceCode;
      """;

    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand(sql, connection) { CommandTimeout = 120 };
    AddXmlChangeParameters(command, filter);
    command.Parameters.Add("@Skip", SqlDbType.Int).Value = Math.Max(0, filter.Skip);
    command.Parameters.Add("@Take", SqlDbType.Int).Value = Math.Clamp(filter.Take, 1, 500);

    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var kinds = new Dictionary<string, long>(StringComparer.Ordinal);
    while (await reader.ReadAsync(cancellationToken))
    {
      var kind = SupplierXmlChangeKinds.KindOf(PimDb.TextOrEmpty(reader, "FieldKey"));
      kinds[kind] = kinds.GetValueOrDefault(kind) + PimDb.Int64(reader, "Changes");
    }

    await reader.NextResultAsync(cancellationToken);
    long total = 0, products = 0;
    DateTime? last = null;
    if (await reader.ReadAsync(cancellationToken))
    {
      total = PimDb.Int64(reader, "Total");
      products = PimDb.Int64(reader, "Products");
      last = PimDb.NullableDateTime(reader, "LastChangedUtc");
    }

    await reader.NextResultAsync(cancellationToken);
    var rows = new List<SupplierXmlChangeRow>();
    while (await reader.ReadAsync(cancellationToken))
      rows.Add(ReadXmlChangeRow(reader));

    await reader.NextResultAsync(cancellationToken);
    var received = new List<(string, DateTime)>();
    while (await reader.ReadAsync(cancellationToken))
      received.Add((PimDb.TextOrEmpty(reader, "SourceCode"), PimDb.DateTimeValue(reader, "ReceivedUtc")));

    return new(rows, total, products, last, kinds, received);
  }

  /// <summary>
  /// Izvoz v Excel (#7, odločitev lastnika pri #27: »pregled s filtri in izvozom v Excel«): iste vrstice
  /// in isti vrstni red kot na zaslonu, a vse strani, ne le trenutna. Vrstice se berejo iz baze sproti
  /// in se pišejo naravnost v dani tok (datoteko), zato cela zgodovina (več sto tisoč vrstic) ne gre v pomnilnik.
  /// Vrne število zapisanih vrstic.
  /// </summary>
  public async Task<long> WriteXmlChangesWorkbookAsync(
    SupplierXmlChangeFilter filter, Stream destination, CancellationToken cancellationToken = default)
  {
    ArgumentNullException.ThrowIfNull(filter);
    ArgumentNullException.ThrowIfNull(destination);
    static WorkbookColumn Text(string header, double width) => new(header, WorkbookCellKind.Text, width);
    IReadOnlyList<WorkbookColumn> columns =
    [
      Text("Šifra", 20), Text("Podjetje", 16), Text("Vir", 10), Text("Vrsta", 10), Text("Kaj", 30),
      Text("Sprememba", 13), Text("Prej", 50), Text("Potem", 50),
      new("Kdaj", WorkbookCellKind.DateTime, 17),
    ];
    long written = 0;
    var notes = new List<string>();

    async IAsyncEnumerable<IReadOnlyList<object?>> Rows([System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken token = default)
    {
      await foreach (var row in ReadXmlChangesAsync(filter, token))
      {
        written++;
        yield return
        [
          row.ItemId, row.OrganizationName, row.SourceCode, SupplierXmlChangeKinds.KindLabel(row.Kind), row.FieldLabel,
          row.Change, row.OldValue, row.NewValue, row.ChangedAtUtc.ToPimLocal(),
        ];
      }
      notes.Add($"Izvoženo {DateTime.UtcNow.ToPimLocal():dd.MM.yyyy HH:mm}; sprememb {written:N0}. Filtri: {DescribeFilter(filter)}.");
      notes.Add("Samo spremembe, ki jih je naredil zajem dobaviteljevega XML (NW_XML, BT_XML). Spremembe iz SAOP in ročni popravki so na kartici artikla pod Zgodovina.");
      notes.Add($"Zgodovina hrani prvih {SupplierXmlChangeRow.StoredLength} znakov vrednosti; daljše besedilo je odrezano (celo je na kartici artikla).");
    }

    await WorkbookWriter.WriteAsync(destination, "Spremembe iz XML", columns, Rows(cancellationToken), notes, cancellationToken);
    return written;
  }

  /// <summary>Filtri z besedami za opombo v izvozu (kdo datoteko odpre čez teden, ve, kaj gleda).</summary>
  public static string DescribeFilter(SupplierXmlChangeFilter filter)
  {
    var parts = new List<string>();
    if (filter.OrganizationId is int organization) parts.Add($"podjetje {organization}");
    if (filter.SourceCode is { } source) parts.Add($"vir {source}");
    if (filter.Kind is { } kind) parts.Add(SupplierXmlChangeKinds.Kinds.FirstOrDefault(item => item.Code == kind).Label?.ToLowerInvariant() ?? kind);
    if (filter.Search is { } search) parts.Add($"šifra vsebuje »{search}«");
    if (filter.Days is int days) parts.Add(days == 1 ? "zadnji dan" : $"zadnjih {days} dni");
    return parts.Count == 0 ? "brez (vse spremembe iz XML)" : string.Join(", ", parts);
  }

  /// <summary>Vse vrstice filtra v vrstnem redu zaslona, brez listanja — za izvoz; bere sproti (brez zbiranja v pomnilniku).</summary>
  async IAsyncEnumerable<SupplierXmlChangeRow> ReadXmlChangesAsync(
    SupplierXmlChangeFilter filter, [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken cancellationToken = default)
  {
    var sql = SupplierXmlBatchesSql + $"""

      SELECT TOP (@Max) h.ChangeId, h.OrganizationId, COALESCE(organizacija.Name, CONCAT(N'Podjetje ', h.OrganizationId)) AS OrganizationName,
        paket.SourceCode, h.ProductId, h.ItemID, h.FieldKey, h.CanonColumn, h.OldValue, h.NewValue, h.ChangedAtUtc
      FROM pim.ProductFieldHistory h
      INNER JOIN @Paket paket ON paket.ChangeBatchId = h.ChangeBatchId
      LEFT JOIN dbo.OrganizationConfig organizacija ON organizacija.OrganizationId = h.OrganizationId
      WHERE {SupplierXmlFilterSql} AND (@FieldKey IS NULL OR h.FieldKey = @FieldKey)
      ORDER BY {XmlChangesOrderBy(filter.Sort)}
      OPTION (RECOMPILE);
      """;
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand(sql, connection) { CommandTimeout = 600 };
    AddXmlChangeParameters(command, filter);
    command.Parameters.Add("@Max", SqlDbType.Int).Value = WorkbookWriter.MaxRows;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    while (await reader.ReadAsync(cancellationToken))
      yield return ReadXmlChangeRow(reader);
  }

  static string XmlChangesOrderBy(string sort) => sort switch
  {
    "starejse" => "h.ChangeId ASC",
    "sifra" => "h.ItemID ASC, h.ChangeId DESC",
    _ => "h.ChangeId DESC",
  };

  static void AddXmlChangeParameters(SqlCommand command, SupplierXmlChangeFilter filter)
  {
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = (object?)filter.OrganizationId ?? DBNull.Value;
    command.Parameters.Add("@SourceCode", SqlDbType.NVarChar, 100).Value = Optional(filter.SourceCode);
    command.Parameters.Add("@FieldKey", SqlDbType.NVarChar, 256).Value = (object?)SupplierXmlChangeKinds.FieldKeyOf(filter.Kind) ?? DBNull.Value;
    command.Parameters.Add("@Search", SqlDbType.NVarChar, 210).Value = LikePattern(filter.Search);
    command.Parameters.Add("@FromUtc", SqlDbType.DateTime2).Value = filter.Days is int days && days > 0 ? DateTime.UtcNow.AddDays(-days) : DBNull.Value;
  }

  /// <summary>Ena vrstica iz SELECT-a sprememb (isti stolpci na zaslonu in v izvozu).</summary>
  static SupplierXmlChangeRow ReadXmlChangeRow(SqlDataReader reader) => new(
    PimDb.Int64(reader, "ChangeId"), PimDb.Int32(reader, "OrganizationId"), PimDb.TextOrEmpty(reader, "OrganizationName"),
    PimDb.TextOrEmpty(reader, "SourceCode"), PimDb.Int64(reader, "ProductId"), PimDb.TextOrEmpty(reader, "ItemID"),
    PimDb.TextOrEmpty(reader, "FieldKey"), PimDb.Text(reader, "CanonColumn"), PimDb.Text(reader, "OldValue"),
    PimDb.Text(reader, "NewValue"), PimDb.DateTimeValue(reader, "ChangedAtUtc"));

  /// <summary>Iskanje po delu šifre: »%x%« z ubežnimi znaki, da »_« v šifri ne pomeni poljubnega znaka.</summary>
  internal static object LikePattern(string? search)
  {
    if (string.IsNullOrWhiteSpace(search)) return DBNull.Value;
    var text = search.Trim();
    if (text.Length > 200) text = text[..200];
    return "%" + text.Replace(@"\", @"\\").Replace("%", @"\%").Replace("_", @"\_").Replace("[", @"\[") + "%";
  }

  /* --- #7b: kam bo uvrščen kandidat -------------------------------------- */

  /// <summary>
  /// Za kandidate na strani (ena poizvedba, ne ena na vrstico) prebere dobaviteljevo pot iz zadnjega
  /// zajema (zapis <c>Classification</c> z isto šifro ali EAN) in jo prevede po <c>map.CategoryPathMap</c>
  /// v vsakem dejavnem drevesu — enako kot <c>map.ResolveProductCategories</c>, ki to naredi, ko artikel
  /// obstaja. Kandidati, za katere dobavitelj kategorije ne pošlje, v slovarju nimajo vnosa poti.
  /// </summary>
  public async Task<IReadOnlyDictionary<long, SupplierCategoryPrediction>> GetCategoryPredictionsAsync(
    IEnumerable<long> candidateIds, CancellationToken cancellationToken = default)
  {
    var ids = candidateIds.Distinct().ToArray();
    if (ids.Length == 0) return new Dictionary<long, SupplierCategoryPrediction>();

    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand(CategoryPredictionSql, connection) { CommandTimeout = 60 };
    command.Parameters.Add("@Ids", SqlDbType.NVarChar, -1).Value = System.Text.Json.JsonSerializer.Serialize(ids);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);

    var paths = new Dictionary<long, (string? Path, string? Key)>();
    var trees = new Dictionary<long, List<SupplierCategoryTarget>>();
    while (await reader.ReadAsync(cancellationToken))
    {
      var id = PimDb.Int64(reader, "SupplierProductCandidateId");
      var levels = new[] { PimDb.Text(reader, "Level1"), PimDb.Text(reader, "Level2"), PimDb.Text(reader, "Level3") }
        .Where(level => !string.IsNullOrWhiteSpace(level)).ToArray();
      paths[id] = (levels.Length == 0 ? null : string.Join(" / ", levels), PimDb.Text(reader, "SourcePathKey"));
      var tree = PimDb.Text(reader, "CategoryTreeCode");
      if (tree is null) continue;
      if (!trees.TryGetValue(id, out var list)) trees[id] = list = [];
      list.Add(new(tree, PimDb.Text(reader, "CategoryPath")));
    }

    var result = new Dictionary<long, SupplierCategoryPrediction>();
    foreach (var id in ids)
    {
      var (path, key) = paths.GetValueOrDefault(id);
      result[id] = new(path, key, path is null ? [] : trees.GetValueOrDefault(id) ?? []);
    }
    return result;
  }

  /// <summary>
  /// Ključ poti je natanko formula iz <c>map.ResolveProductCategories</c> (ravni, »___«, presledki v »_«,
  /// male črke). Zapisi zajema se izberejo prek indeksa <c>IX_ExtractedValue_Identity</c> (vrsta polja,
  /// zapis) — najprej zapisi tega vira in podjetja, ki sploh nosijo kategorijo, nato ujemanje ključa.
  /// </summary>
  internal const string CategoryPredictionSql = """
    SET NOCOUNT ON;
    DECLARE @Kandidat TABLE (SupplierProductCandidateId bigint NOT NULL PRIMARY KEY, OrganizationId int NOT NULL, SourceCode nvarchar(100) NOT NULL);
    DECLARE @Kljuc TABLE (SupplierProductCandidateId bigint NOT NULL, OrganizationId int NOT NULL, SourceCode nvarchar(100) NOT NULL, KeyValue nvarchar(100) NOT NULL);
    DECLARE @Zapis TABLE (InboxId bigint NOT NULL PRIMARY KEY, OrganizationId int NOT NULL, SourceCode nvarchar(100) NOT NULL);

    INSERT @Kandidat (SupplierProductCandidateId, OrganizationId, SourceCode)
    SELECT kandidat.SupplierProductCandidateId, kandidat.OrganizationId, kandidat.SourceCode
    FROM map.SupplierProductCandidate kandidat
    WHERE kandidat.SupplierProductCandidateId IN (SELECT CONVERT(bigint, [value]) FROM OPENJSON(@Ids));

    INSERT @Kljuc (SupplierProductCandidateId, OrganizationId, SourceCode, KeyValue)
    SELECT DISTINCT kandidat.SupplierProductCandidateId, kandidat.OrganizationId, kandidat.SourceCode, kljuc.KeyValue
    FROM map.SupplierProductCandidate kandidat
    CROSS APPLY (VALUES (kandidat.ItemID), (kandidat.EAN)) kljuc(KeyValue)
    WHERE kandidat.SupplierProductCandidateId IN (SELECT SupplierProductCandidateId FROM @Kandidat)
      AND NULLIF(LTRIM(RTRIM(kljuc.KeyValue)), N'') IS NOT NULL;

    INSERT @Zapis (InboxId, OrganizationId, SourceCode)
    SELECT inbox.InboxId, inbox.OrganizationId, inbox.SourceCode
    FROM raw.Inbox inbox
    WHERE EXISTS (SELECT 1 FROM @Kandidat kandidat WHERE kandidat.OrganizationId = inbox.OrganizationId AND kandidat.SourceCode = inbox.SourceCode)
      AND EXISTS (SELECT 1 FROM map.ExtractedValue vrednost
                  WHERE vrednost.TargetFieldCode = N'ProductCategory.SourceLevel1' AND vrednost.InboxId = inbox.InboxId);

    WITH Zadetek AS
    (
      SELECT kljuc.SupplierProductCandidateId, vrednost.InboxId, vrednost.RecordOrdinal,
        ROW_NUMBER() OVER (PARTITION BY kljuc.SupplierProductCandidateId ORDER BY vrednost.InboxId DESC, vrednost.RecordOrdinal DESC) AS Mesto
      FROM @Zapis zapis
      INNER JOIN map.ExtractedValue vrednost WITH (FORCESEEK (IX_ExtractedValue_Identity (TargetFieldCode, InboxId)))
        ON vrednost.TargetFieldCode IN (N'Product.ItemID', N'Product.EAN') AND vrednost.InboxId = zapis.InboxId
      INNER JOIN @Kljuc kljuc
        ON kljuc.OrganizationId = zapis.OrganizationId AND kljuc.SourceCode = zapis.SourceCode
       AND kljuc.KeyValue = CONVERT(nvarchar(100), vrednost.Value)
    ),
    Pot AS
    (
      SELECT zadetek.SupplierProductCandidateId, kandidat.SourceCode,
        LTRIM(RTRIM(MAX(CASE WHEN vrednost.TargetFieldCode = N'ProductCategory.SourceLevel1' THEN CONVERT(nvarchar(400), vrednost.Value) END))) AS Level1,
        NULLIF(LTRIM(RTRIM(MAX(CASE WHEN vrednost.TargetFieldCode = N'ProductCategory.SourceLevel2' THEN CONVERT(nvarchar(400), vrednost.Value) END))), N'') AS Level2,
        NULLIF(LTRIM(RTRIM(MAX(CASE WHEN vrednost.TargetFieldCode = N'ProductCategory.SourceLevel3' THEN CONVERT(nvarchar(400), vrednost.Value) END))), N'') AS Level3
      FROM Zadetek zadetek
      INNER JOIN @Kandidat kandidat ON kandidat.SupplierProductCandidateId = zadetek.SupplierProductCandidateId
      INNER JOIN map.ExtractedValue vrednost
        ON vrednost.TargetFieldCode IN (N'ProductCategory.SourceLevel1', N'ProductCategory.SourceLevel2', N'ProductCategory.SourceLevel3')
       AND vrednost.InboxId = zadetek.InboxId AND vrednost.RecordOrdinal = zadetek.RecordOrdinal
      WHERE zadetek.Mesto = 1
      GROUP BY zadetek.SupplierProductCandidateId, kandidat.SourceCode
    ),
    Kljuc AS
    (
      SELECT pot.*, LOWER(CONCAT(
          REPLACE(pot.Level1, N' ', N'_'),
          CASE WHEN pot.Level2 IS NULL THEN N'' ELSE N'___' + REPLACE(pot.Level2, N' ', N'_') END,
          CASE WHEN pot.Level3 IS NULL THEN N'' ELSE N'___' + REPLACE(pot.Level3, N' ', N'_') END)) AS SourcePathKey
      FROM Pot pot
      WHERE NULLIF(pot.Level1, N'') IS NOT NULL
    ),
    Drevo AS
    (
      SELECT DISTINCT spletisce.CategoryTreeCode
      FROM canon.WebSite spletisce
      WHERE spletisce.IsActive = 1
        AND EXISTS (SELECT 1 FROM canon.Category kategorija WHERE kategorija.CategoryTreeCode = spletisce.CategoryTreeCode AND kategorija.IsActive = 1)
    )
    SELECT kljuc.SupplierProductCandidateId, kljuc.Level1, kljuc.Level2, kljuc.Level3, kljuc.SourcePathKey,
      drevo.CategoryTreeCode, cilj.CategoryPath
    FROM Kljuc kljuc
    CROSS JOIN Drevo drevo
    OUTER APPLY
    (
      SELECT TOP (1) prevod.CategoryPath
      FROM map.CategoryPathMap slovar
      INNER JOIN canon.WebSite spletisce ON spletisce.CategoryTreeCode = slovar.CategoryTreeCode AND spletisce.IsActive = 1
      INNER JOIN canon.CategoryPathTranslated prevod
        ON prevod.CategoryTreeCode = slovar.CategoryTreeCode AND prevod.CategoryCode = slovar.CategoryCode
       AND prevod.LanguageCode = spletisce.LanguageCode
      WHERE slovar.SourceCode = kljuc.SourceCode AND slovar.CategoryTreeCode = drevo.CategoryTreeCode
        AND slovar.SourcePathKey = kljuc.SourcePathKey AND slovar.IsActive = 1
      ORDER BY CASE WHEN spletisce.LanguageCode = N'sl' THEN 0 ELSE 1 END, spletisce.WebSiteCode
    ) cilj
    ORDER BY kljuc.SupplierProductCandidateId, drevo.CategoryTreeCode;
    """;
}
