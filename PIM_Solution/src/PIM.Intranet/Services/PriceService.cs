using System.Data;
using System.Globalization;
using System.Text.Json;
using Microsoft.Data.SqlClient;

namespace PIM.Intranet.Services;

/// <summary>
/// Filter strani /cene, izvoza /izvoz/cene.xlsx in povezav med zavihki — en zapis za vse tri, da je
/// datoteka natanko to, kar uporabnik vidi (isti vzorec kot <see cref="CustomerListQuery"/>).
/// </summary>
/// <param name="OrganizationId">Null pomeni vsa aktivna podjetja.</param>
/// <param name="MinPriceLists">Izdelki z vsaj toliko ceniki (1 = vsi s ceno).</param>
/// <param name="Queue">QUEUED = samo izdelki s ceno, ki čaka v vrsti za SAOP.</param>
public sealed record PriceQuery(int? OrganizationId, string? PriceList, string? Search, int MinPriceLists = 1, string? Queue = null)
{
  public static PriceQuery FromQuery(Func<string, string?> value) => new(
    int.TryParse(value("podjetje"), out var organization) && organization > 0 ? organization : null,
    Blank(value("cenik")), Blank(value("isci")),
    int.TryParse(value("cenikov"), out var minimum) && minimum > 1 ? minimum : 1,
    Blank(value("vrsta")));

  public string ToQueryString()
  {
    var parts = new List<string>();
    void Add(string name, string? text) { if (!string.IsNullOrWhiteSpace(text)) parts.Add($"{name}={Uri.EscapeDataString(text)}"); }
    Add("podjetje", OrganizationId?.ToString(CultureInfo.InvariantCulture));
    Add("cenik", PriceList);
    Add("isci", Search);
    Add("cenikov", MinPriceLists > 1 ? MinPriceLists.ToString(CultureInfo.InvariantCulture) : null);
    Add("vrsta", Queue);
    return string.Join("&", parts);
  }

  static string? Blank(string? text) => string.IsNullOrWhiteSpace(text) ? null : text.Trim();
}

/// <summary>Ena vrstica seznama: izdelek z vsemi ceniki, zgoščen v eno vrstico.</summary>
public sealed record PriceProductRow(
  long ProductId, int OrganizationId, string OrganizationName, string ItemId, string? Name,
  int PriceListCount, string PriceListPreview, decimal? MinNet, decimal? MaxNet, DateTime? LastValidFrom, int QueuedCount);

/// <summary>Ena cena (cenik × izdelek) z morebitno spremembo, ki čaka v vrsti za SAOP.</summary>
/// <param name="QueuedNet">Neto, ki čaka v vrsti (neodposlan ali poslan, a še ne zajet nazaj).</param>
/// <param name="QueueStatus">Stanje v vrsti: PendingApproval, Pending, Retry, Sending, Sent ali Dead.</param>
/// <param name="InSaop">Ali cena v zajemu iz SAOP že obstaja; false = nova cena, ki še ni v SAOP.</param>
public sealed record PriceLine(
  int OrganizationId, string OrganizationName, long ProductId, string ItemId, string? Title, string? Ean,
  string PriceList, string? PriceListName, decimal? Net, decimal? VatRate, DateTime? ValidFrom, bool IsActive,
  decimal? QueuedNet, decimal? QueuedVatRate, string? QueueStatus, string? QueueError, bool InSaop)
{
  public decimal? Gross => Net is { } net && VatRate is { } vat ? Math.Round(net * (1 + vat / 100), 2) : null;
}

/// <summary>Cenik podjetja: iz šifranta SAOP ali nov, ki še čaka v vrsti.</summary>
/// <param name="InSaop">Cenik je v šifrantu SAOP (zajem api/pricelists) ali ga je PIM že uspešno poslal.</param>
/// <param name="QueueStatus">Stanje glave cenika v vrsti za SAOP; null = nič ne čaka.</param>
public sealed record PriceListRow(
  int OrganizationId, string OrganizationName, string Code, string? Name, string? Currency, bool IsActive, bool InSaop,
  long Prices, long Products, DateTime? LastValidFrom, int QueuedPrices, string? QueueStatus, string? QueueError);

/// <summary>Serija cen ali cenikov v vrsti za SAOP; števci so po cenah/cenikih (dokumentih), ne po poljih.</summary>
public sealed record PriceBatchRow(
  long BatchId, int OrganizationId, string OrganizationName, string TargetKind, string Source, string? Note,
  string CreatedBy, DateTime CreatedUtc, int Documents, int AwaitingApproval, int Queued, int Waiting, int Sent, int Failed, int Cancelled)
{
  public bool HasPriceList => TargetKind == "SAOP_PRICELIST";
}

/// <summary>Ena cena ali cenik v seriji z vrednostmi, kot bodo odšle.</summary>
/// <param name="WaitsForPriceList">Cena čaka, ker SAOP njenega cenika še ne pozna.</param>
public sealed record PriceBatchEntity(
  string TargetKind, string EntityKey, string Operation, string Status, string? Net, string? VatRate, string? Active,
  string? ValidFrom, string? Description, string? LastError, DateTime UpdatedUtc, bool WaitsForPriceList)
{
  public string? PriceList => TargetKind == "SAOP_PRICE" ? EntityKey.Split('|')[0] : EntityKey;
  public string? ItemId => TargetKind == "SAOP_PRICE" && EntityKey.Contains('|') ? EntityKey[(EntityKey.IndexOf('|') + 1)..] : null;
}

/// <summary>Ena cena za vrsto — cena je vedno cela; null pri DDV/datumu/aktivnosti pomeni »kot zdaj«.</summary>
public sealed record PriceChange(string PriceList, string ItemId, decimal Net, decimal? VatRate = null, DateTime? ValidFrom = null, bool? Active = null);

/// <param name="Status">Queued, Duplicate, Unchanged ali Rejected.</param>
/// <param name="Intent">ADD (nova cena) ali UPDATE (sprememba obstoječe).</param>
public sealed record PriceEnqueueRow(int Ordinal, string? PriceList, string? ItemId, string Status, string? Reason, string Intent, decimal? OldNet, decimal? NewNet);

public sealed record PriceEnqueueOutcome(long? BatchId, IReadOnlyList<PriceEnqueueRow> Rows)
{
  public int Queued => Rows.Count(row => row.Status == "Queued");
  public int Duplicates => Rows.Count(row => row.Status == "Duplicate");
  public int Unchanged => Rows.Count(row => row.Status == "Unchanged");
  public int Rejected => Rows.Count(row => row.Status == "Rejected");
}

/// <summary>
/// Cene in ceniki (265): branje za stran in izvoz, vpis sprememb v vrsto za SAOP, nov cenik, odobritev.
///
/// SAOP ostane vir resnice o ceni: PIM spremembe ne zapiše v canon.ProductPrice, ampak jo uvrsti v
/// out.OutboxMessage (SAOP_PRICE / SAOP_PRICELIST). Ko jo SAOP sprejme, jo naslednji zajem cen
/// (GetPrices) prinese nazaj — do takrat stran pokaže »čaka SAOP« ob stari ceni. Tako ista cena
/// nikoli nima dveh virov in katalog.csv ne more oditi s ceno, ki je SAOP ne pozna.
///
/// Nič ne odide brez odobritve: profila sta ManualApproval, pošiljanje sproži »Odobri in pošlji«
/// (<see cref="PriceSendJobs"/>), najprej ceniki in šele nato cene.
/// </summary>
public sealed class PriceService(IConfiguration configuration, PimWriteGuard guard, PriceSendJobs sendJobs)
{
  string ConnectionString => ConnectionStringResolver.Resolve(configuration)
    ?? throw new InvalidOperationException("Povezava PIM ni nastavljena.");

  /// <summary>Aktivna podjetja; »vsa podjetja« nikoli ne zajame neaktivnega (264: DEMO).</summary>
  const string ActiveOrganizations = "SELECT OrganizationId, Name FROM dbo.OrganizationConfig WHERE IsActive = 1";

  /// <summary>Odprta (še ne zajeta nazaj) sporočila cen: ključ razbit na cenik in šifro, zadnja vrednost po polju.</summary>
  const string OpenPriceMessages = """
    SELECT message.OrganizationId, message.EntityKey,
      PriceList = LEFT(message.EntityKey, CHARINDEX(N'|', message.EntityKey) - 1),
      ItemID = SUBSTRING(message.EntityKey, CHARINDEX(N'|', message.EntityKey) + 1, 450),
      QueuedNet = MAX(CASE WHEN message.FieldSummary = N'Price.Net' THEN TRY_CONVERT(decimal(19,4), JSON_VALUE(message.PayloadJson, N'$.value')) END),
      QueuedVat = MAX(CASE WHEN message.FieldSummary = N'Price.VatRate' THEN TRY_CONVERT(decimal(5,2), JSON_VALUE(message.PayloadJson, N'$.value')) END),
      QueueStatus = MIN(message.Status),
      QueueError = MAX(message.LastError)
    FROM out.OutboxMessage AS message
    WHERE message.TargetKind = N'SAOP_PRICE' AND CHARINDEX(N'|', message.EntityKey) > 1
      AND (message.Status IN (N'PendingApproval', N'Pending', N'Retry', N'Sending', N'Dead')
        OR (message.Status = N'Sent' AND message.SentUtc >= DATEADD(day, -2, SYSUTCDATETIME())))
    GROUP BY message.OrganizationId, message.EntityKey
    """;

  /* --- branje: seznam po izdelkih -------------------------------------------------------------- */

  public async Task<(IReadOnlyList<PriceProductRow> Rows, long Total, long Lines)> GetProductsAsync(
    PriceQuery query, int skip, int take, CancellationToken cancellationToken = default)
  {
    var sql = $"""
      WITH org AS ({ActiveOrganizations}),
      open_price AS ({OpenPriceMessages}),
      grouped AS
      (
        SELECT price.ProductId,
          PriceListCount = COUNT(DISTINCT price.PriceList), Lines = COUNT_BIG(*),
          MinNet = MIN(price.Net), MaxNet = MAX(price.Net), LastValidFrom = MAX(price.ValidFrom)
        FROM canon.ProductPrice AS price
        INNER JOIN canon.Product AS product ON product.ProductId = price.ProductId
        INNER JOIN org ON org.OrganizationId = product.OrganizationId
        WHERE (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
          AND (@PriceList IS NULL OR price.PriceList = @PriceList)
          AND (@Search IS NULL OR product.ItemID LIKE N'%' + @Search + N'%' OR product.EAN = @Search)
          AND (@Queue IS NULL OR EXISTS (SELECT 1 FROM open_price WHERE open_price.OrganizationId = product.OrganizationId
            AND open_price.ItemID = product.ItemID AND open_price.QueueStatus <> N'Sent'))
        GROUP BY price.ProductId
        HAVING COUNT(DISTINCT price.PriceList) >= @MinPriceLists
      )
      SELECT grouped.ProductId, product.OrganizationId, OrganizationName = org.Name, product.ItemID, Name = title.Value,
        grouped.PriceListCount, grouped.MinNet, grouped.MaxNet, grouped.LastValidFrom,
        PriceListPreview = STUFF((
          SELECT TOP (3) N', ' + preview.PriceList
          FROM (SELECT DISTINCT inner_price.PriceList FROM canon.ProductPrice inner_price WHERE inner_price.ProductId = grouped.ProductId) AS preview
          ORDER BY preview.PriceList
          FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''),
        QueuedCount = (SELECT COUNT(*) FROM open_price WHERE open_price.OrganizationId = product.OrganizationId
          AND open_price.ItemID = product.ItemID AND open_price.QueueStatus <> N'Sent')
      FROM grouped
      INNER JOIN canon.Product AS product ON product.ProductId = grouped.ProductId
      INNER JOIN org ON org.OrganizationId = product.OrganizationId
      OUTER APPLY
      (
        SELECT TOP (1) textValue.Value
        FROM canon.ProductText textValue
        WHERE textValue.ProductId = grouped.ProductId AND textValue.TextType IN (N'WEB_TITLE', N'TITLE_ERP')
        ORDER BY CASE WHEN textValue.TextType = N'WEB_TITLE' THEN 0 ELSE 1 END,
          CASE WHEN textValue.Lang = N'sl' THEN 0 ELSE 1 END, textValue.Lang
      ) AS title
      ORDER BY product.ItemID, product.OrganizationId
      OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY;
      """;
    var countSql = $"""
      WITH org AS ({ActiveOrganizations}),
      open_price AS ({OpenPriceMessages}),
      grouped AS
      (
        SELECT price.ProductId, Lines = COUNT_BIG(*)
        FROM canon.ProductPrice AS price
        INNER JOIN canon.Product AS product ON product.ProductId = price.ProductId
        INNER JOIN org ON org.OrganizationId = product.OrganizationId
        WHERE (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
          AND (@PriceList IS NULL OR price.PriceList = @PriceList)
          AND (@Search IS NULL OR product.ItemID LIKE N'%' + @Search + N'%' OR product.EAN = @Search)
          AND (@Queue IS NULL OR EXISTS (SELECT 1 FROM open_price WHERE open_price.OrganizationId = product.OrganizationId
            AND open_price.ItemID = product.ItemID AND open_price.QueueStatus <> N'Sent'))
        GROUP BY price.ProductId
        HAVING COUNT(DISTINCT price.PriceList) >= @MinPriceLists
      )
      SELECT Total = COUNT_BIG(*), Lines = ISNULL(SUM(Lines), 0) FROM grouped;
      """;

    await using var connection = await OpenAsync(cancellationToken);
    var rows = new List<PriceProductRow>();
    await using (var command = Command(connection, sql, query))
    {
      command.Parameters.Add("@Skip", SqlDbType.Int).Value = Math.Max(0, skip);
      command.Parameters.Add("@Take", SqlDbType.Int).Value = Math.Clamp(take, 1, 500);
      await using var reader = await command.ExecuteReaderAsync(cancellationToken);
      while (await reader.ReadAsync(cancellationToken))
        rows.Add(new(
          PimDb.Int64(reader, "ProductId"), PimDb.Int32(reader, "OrganizationId"), PimDb.TextOrEmpty(reader, "OrganizationName"),
          PimDb.TextOrEmpty(reader, "ItemID"), PimDb.Text(reader, "Name"), PimDb.Int32(reader, "PriceListCount"),
          PimDb.TextOrEmpty(reader, "PriceListPreview"), PimDb.NullableDecimal(reader, "MinNet"), PimDb.NullableDecimal(reader, "MaxNet"),
          PimDb.NullableDateTime(reader, "LastValidFrom"), PimDb.Int32(reader, "QueuedCount")));
    }

    await using (var command = Command(connection, countSql, query))
    {
      await using var reader = await command.ExecuteReaderAsync(cancellationToken);
      await reader.ReadAsync(cancellationToken);
      return (rows, PimDb.Int64(reader, "Total"), PimDb.Int64(reader, "Lines"));
    }
  }

  /// <summary>Vse cene enega izdelka, skupaj z novimi cenami, ki čakajo v vrsti in jih SAOP še nima.</summary>
  public async Task<IReadOnlyList<PriceLine>> GetProductLinesAsync(long productId, CancellationToken cancellationToken = default)
  {
    var sql = $"""
      WITH open_price AS ({OpenPriceMessages}),
      product AS
      (
        SELECT product.ProductId, product.OrganizationId, product.ItemID, product.EAN, OrganizationName = org.Name
        FROM canon.Product AS product
        INNER JOIN dbo.OrganizationConfig AS org ON org.OrganizationId = product.OrganizationId
        WHERE product.ProductId = @ProductId
      ),
      current_price AS
      (
        SELECT price.PriceList, price.Net, price.VatRate, price.ValidFrom, price.IsActive,
          ranked = ROW_NUMBER() OVER (PARTITION BY price.PriceList ORDER BY price.ValidFrom DESC)
        FROM canon.ProductPrice AS price WHERE price.ProductId = @ProductId
      ),
      lists AS
      (
        SELECT PriceList FROM current_price WHERE ranked = 1
        UNION
        SELECT open_price.PriceList FROM open_price INNER JOIN product
          ON open_price.OrganizationId = product.OrganizationId AND open_price.ItemID = product.ItemID
      )
      SELECT product.OrganizationId, product.OrganizationName, product.ProductId, product.ItemID, Title = CONVERT(nvarchar(400), NULL), product.EAN,
        lists.PriceList, PriceListName = codebook.Name,
        current_price.Net, current_price.VatRate, current_price.ValidFrom, IsActive = ISNULL(current_price.IsActive, CONVERT(bit, 1)),
        open_price.QueuedNet, open_price.QueuedVat, open_price.QueueStatus, open_price.QueueError,
        InSaop = CONVERT(bit, CASE WHEN current_price.PriceList IS NULL THEN 0 ELSE 1 END)
      FROM lists
      CROSS JOIN product
      LEFT JOIN current_price ON current_price.PriceList = lists.PriceList AND current_price.ranked = 1
      LEFT JOIN open_price ON open_price.OrganizationId = product.OrganizationId AND open_price.ItemID = product.ItemID
        AND open_price.PriceList = lists.PriceList
      LEFT JOIN canon.Codebook AS codebook ON codebook.OrganizationId = product.OrganizationId
        AND codebook.CodebookCode = N'PRICELIST' AND codebook.EntryCode = lists.PriceList
      ORDER BY lists.PriceList;
      """;
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand(sql, connection) { CommandTimeout = 60 };
    command.Parameters.Add("@ProductId", SqlDbType.BigInt).Value = productId;
    return await ReadLinesAsync(command, cancellationToken);
  }

  /// <summary>
  /// Vse cene pogleda (ena vrstica = cenik × izdelek) za izvoz. Brez strani: datoteka je cel pogled,
  /// tako kot pri strankah. Meja je Excelova (milijon vrstic).
  /// </summary>
  public async Task<IReadOnlyList<PriceLine>> GetLinesAsync(PriceQuery query, CancellationToken cancellationToken = default)
  {
    var sql = $"""
      WITH org AS ({ActiveOrganizations}),
      open_price AS ({OpenPriceMessages}),
      products AS
      (
        SELECT price.ProductId
        FROM canon.ProductPrice AS price
        INNER JOIN canon.Product AS product ON product.ProductId = price.ProductId
        INNER JOIN org ON org.OrganizationId = product.OrganizationId
        WHERE (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
          AND (@Search IS NULL OR product.ItemID LIKE N'%' + @Search + N'%' OR product.EAN = @Search)
        GROUP BY price.ProductId
        HAVING COUNT(DISTINCT price.PriceList) >= @MinPriceLists
      ),
      current_price AS
      (
        SELECT price.ProductId, price.PriceList, price.Net, price.VatRate, price.ValidFrom, price.IsActive,
          ranked = ROW_NUMBER() OVER (PARTITION BY price.ProductId, price.PriceList ORDER BY price.ValidFrom DESC)
        FROM canon.ProductPrice AS price
        INNER JOIN products ON products.ProductId = price.ProductId
        WHERE (@PriceList IS NULL OR price.PriceList = @PriceList)
      )
      SELECT product.OrganizationId, OrganizationName = org.Name, product.ProductId, product.ItemID, Title = title.Value, product.EAN,
        current_price.PriceList, PriceListName = codebook.Name,
        current_price.Net, current_price.VatRate, current_price.ValidFrom, current_price.IsActive,
        open_price.QueuedNet, open_price.QueuedVat, open_price.QueueStatus, open_price.QueueError, InSaop = CONVERT(bit, 1)
      FROM current_price
      INNER JOIN canon.Product AS product ON product.ProductId = current_price.ProductId
      INNER JOIN org ON org.OrganizationId = product.OrganizationId
      LEFT JOIN open_price ON open_price.OrganizationId = product.OrganizationId AND open_price.ItemID = product.ItemID
        AND open_price.PriceList = current_price.PriceList
      LEFT JOIN canon.Codebook AS codebook ON codebook.OrganizationId = product.OrganizationId
        AND codebook.CodebookCode = N'PRICELIST' AND codebook.EntryCode = current_price.PriceList
      OUTER APPLY
      (
        SELECT TOP (1) textValue.Value
        FROM canon.ProductText textValue
        WHERE textValue.ProductId = product.ProductId AND textValue.TextType IN (N'WEB_TITLE', N'TITLE_ERP')
        ORDER BY CASE WHEN textValue.TextType = N'WEB_TITLE' THEN 0 ELSE 1 END,
          CASE WHEN textValue.Lang = N'sl' THEN 0 ELSE 1 END, textValue.Lang
      ) AS title
      WHERE current_price.ranked = 1
        AND (@Queue IS NULL OR (open_price.EntityKey IS NOT NULL AND open_price.QueueStatus <> N'Sent'))
      ORDER BY org.Name, current_price.PriceList, product.ItemID;
      """;
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = Command(connection, sql, query);
    command.CommandTimeout = 300;
    return await ReadLinesAsync(command, cancellationToken);
  }

  /// <summary>Trenutne cene za ključe iz uvoza — primerjava »prej/potem« brez nalaganja celega cenika.</summary>
  public async Task<IReadOnlyDictionary<(int OrganizationId, string PriceList, string ItemId), PriceLine>> GetCurrentAsync(
    int organizationId, IReadOnlyCollection<string> itemIds, CancellationToken cancellationToken = default)
  {
    var result = new Dictionary<(int, string, string), PriceLine>(new PriceKeyComparer());
    if (itemIds.Count == 0) return result;
    const string sql = """
      WITH items AS (SELECT DISTINCT ItemID = value FROM OPENJSON(@ItemIds)),
      current_price AS
      (
        SELECT product.OrganizationId, product.ProductId, product.ItemID, product.EAN, price.PriceList, price.Net, price.VatRate,
          price.ValidFrom, price.IsActive,
          ranked = ROW_NUMBER() OVER (PARTITION BY price.ProductId, price.PriceList ORDER BY price.ValidFrom DESC)
        FROM canon.Product AS product
        INNER JOIN items ON items.ItemID = product.ItemID
        INNER JOIN canon.ProductPrice AS price ON price.ProductId = product.ProductId
        WHERE product.OrganizationId = @OrganizationId
      )
      SELECT current_price.OrganizationId, OrganizationName = N'', current_price.ProductId, current_price.ItemID,
        Title = CONVERT(nvarchar(400), NULL), current_price.EAN, current_price.PriceList, PriceListName = CONVERT(nvarchar(400), NULL),
        current_price.Net, current_price.VatRate, current_price.ValidFrom, current_price.IsActive,
        QueuedNet = CONVERT(decimal(19,4), NULL), QueuedVat = CONVERT(decimal(5,2), NULL), QueueStatus = CONVERT(nvarchar(30), NULL),
        QueueError = CONVERT(nvarchar(4000), NULL), InSaop = CONVERT(bit, 1)
      FROM current_price WHERE ranked = 1;
      """;
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand(sql, connection) { CommandTimeout = 120 };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@ItemIds", SqlDbType.NVarChar, -1).Value = JsonSerializer.Serialize(itemIds);
    foreach (var line in await ReadLinesAsync(command, cancellationToken))
      result[(line.OrganizationId, line.PriceList, line.ItemId)] = line;
    return result;
  }

  /// <summary>Artikli podjetja po šifri — uvoz z njimi loči »nova cena« od »artikla ni«.</summary>
  public async Task<IReadOnlyDictionary<string, (long ProductId, string? Ean)>> GetItemsAsync(
    int organizationId, IReadOnlyCollection<string> itemIds, CancellationToken cancellationToken = default)
  {
    var result = new Dictionary<string, (long, string?)>(StringComparer.OrdinalIgnoreCase);
    if (itemIds.Count == 0) return result;
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("""
      SELECT product.ProductId, product.ItemID, product.EAN
      FROM canon.Product AS product
      INNER JOIN (SELECT DISTINCT ItemID = value FROM OPENJSON(@ItemIds)) AS items ON items.ItemID = product.ItemID
      WHERE product.OrganizationId = @OrganizationId;
      """, connection) { CommandTimeout = 120 };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@ItemIds", SqlDbType.NVarChar, -1).Value = JsonSerializer.Serialize(itemIds);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    while (await reader.ReadAsync(cancellationToken))
      result[PimDb.TextOrEmpty(reader, "ItemID")] = (PimDb.Int64(reader, "ProductId"), PimDb.Text(reader, "EAN"));
    return result;
  }

  /* --- branje: ceniki ------------------------------------------------------------------------- */

  public async Task<IReadOnlyList<PriceListRow>> GetPriceListsAsync(int? organizationId, CancellationToken cancellationToken = default)
  {
    var sql = $"""
      WITH org AS ({ActiveOrganizations}),
      open_price AS ({OpenPriceMessages}),
      counted AS
      (
        SELECT product.OrganizationId, price.PriceList, Prices = COUNT_BIG(*), Products = COUNT_BIG(DISTINCT price.ProductId),
          LastValidFrom = MAX(price.ValidFrom)
        FROM canon.ProductPrice AS price
        INNER JOIN canon.Product AS product ON product.ProductId = price.ProductId
        WHERE (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
        GROUP BY product.OrganizationId, price.PriceList
      ),
      head AS
      (
        SELECT message.OrganizationId, message.EntityKey,
          Description = MAX(CASE WHEN message.FieldSummary = N'PriceList.PriceListDescription' THEN JSON_VALUE(message.PayloadJson, N'$.value') END),
          Currency = MAX(CASE WHEN message.FieldSummary = N'PriceList.CurrencyId' THEN JSON_VALUE(message.PayloadJson, N'$.value') END),
          Active = MAX(CASE WHEN message.FieldSummary = N'PriceList.Active' THEN JSON_VALUE(message.PayloadJson, N'$.value') END),
          QueueStatus = MIN(message.Status), QueueError = MAX(message.LastError),
          Sent = MAX(CASE WHEN message.SentUtc IS NOT NULL AND message.Status IN (N'Sent', N'Verified', N'Superseded') THEN 1 ELSE 0 END)
        FROM out.OutboxMessage AS message
        WHERE message.TargetKind = N'SAOP_PRICELIST'
          AND (message.Status IN (N'PendingApproval', N'Pending', N'Retry', N'Sending', N'Dead', N'Sent'))
        GROUP BY message.OrganizationId, message.EntityKey
      ),
      lists AS
      (
        SELECT OrganizationId, Code = EntryCode FROM canon.Codebook WHERE CodebookCode = N'PRICELIST'
        UNION SELECT OrganizationId, PriceList FROM counted
        UNION SELECT OrganizationId, EntityKey FROM head
      )
      SELECT lists.OrganizationId, OrganizationName = org.Name, lists.Code,
        Name = COALESCE(head.Description, codebook.Name), Currency = COALESCE(head.Currency, codebook.ExtraCode),
        IsActive = CONVERT(bit, CASE WHEN head.Active = N'false' THEN 0 WHEN head.Active = N'true' THEN 1 ELSE ISNULL(codebook.IsActive, 1) END),
        InSaop = CONVERT(bit, CASE WHEN codebook.EntryCode IS NOT NULL OR counted.PriceList IS NOT NULL OR head.Sent = 1 THEN 1 ELSE 0 END),
        Prices = ISNULL(counted.Prices, 0), Products = ISNULL(counted.Products, 0), counted.LastValidFrom,
        QueuedPrices = (SELECT COUNT(*) FROM open_price WHERE open_price.OrganizationId = lists.OrganizationId
          AND open_price.PriceList = lists.Code AND open_price.QueueStatus <> N'Sent'),
        QueueStatus = CASE WHEN head.QueueStatus = N'Sent' THEN NULL ELSE head.QueueStatus END,
        head.QueueError
      FROM lists
      INNER JOIN org ON org.OrganizationId = lists.OrganizationId
      LEFT JOIN canon.Codebook AS codebook ON codebook.OrganizationId = lists.OrganizationId
        AND codebook.CodebookCode = N'PRICELIST' AND codebook.EntryCode = lists.Code
      LEFT JOIN counted ON counted.OrganizationId = lists.OrganizationId AND counted.PriceList = lists.Code
      LEFT JOIN head ON head.OrganizationId = lists.OrganizationId AND head.EntityKey = lists.Code
      WHERE (@OrganizationId IS NULL OR lists.OrganizationId = @OrganizationId)
      ORDER BY org.Name, CASE WHEN counted.Prices IS NULL THEN 1 ELSE 0 END, counted.Prices DESC, lists.Code;
      """;
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand(sql, connection) { CommandTimeout = 120 };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = (object?)organizationId ?? DBNull.Value;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var rows = new List<PriceListRow>();
    while (await reader.ReadAsync(cancellationToken))
      rows.Add(new(
        PimDb.Int32(reader, "OrganizationId"), PimDb.TextOrEmpty(reader, "OrganizationName"), PimDb.TextOrEmpty(reader, "Code"),
        PimDb.Text(reader, "Name"), PimDb.Text(reader, "Currency"), PimDb.Bool(reader, "IsActive"), PimDb.Bool(reader, "InSaop"),
        PimDb.Int64(reader, "Prices"), PimDb.Int64(reader, "Products"), PimDb.NullableDateTime(reader, "LastValidFrom"),
        PimDb.Int32(reader, "QueuedPrices"), PimDb.Text(reader, "QueueStatus"), PimDb.Text(reader, "QueueError")));
    return rows;
  }

  /* --- branje: vrsta za SAOP ------------------------------------------------------------------ */

  public async Task<IReadOnlyList<PriceBatchRow>> GetBatchesAsync(int? organizationId, int top = 50, CancellationToken cancellationToken = default)
  {
    var sql = $"""
      WITH org AS ({ActiveOrganizations}),
      documents AS
      (
        SELECT message.OutboundBatchId, message.TargetKind, message.EntityKey,
          Status = CASE
            WHEN SUM(CASE WHEN message.Status = N'PendingApproval' THEN 1 ELSE 0 END) > 0 THEN N'PendingApproval'
            WHEN SUM(CASE WHEN message.Status IN (N'Pending', N'Retry', N'Sending') THEN 1 ELSE 0 END) > 0 THEN N'Queued'
            WHEN SUM(CASE WHEN message.Status IN (N'Dead', N'Error', N'Drift') THEN 1 ELSE 0 END) > 0 THEN N'Failed'
            WHEN SUM(CASE WHEN message.Status IN (N'Sent', N'Verified') THEN 1 ELSE 0 END) > 0 THEN N'Sent'
            WHEN SUM(CASE WHEN message.Status = N'Cancelled' THEN 1 ELSE 0 END) > 0 THEN N'Cancelled'
            ELSE N'Superseded' END,
          Waiting = MAX(CASE WHEN message.TargetKind = N'SAOP_PRICE' AND message.Status IN (N'Pending', N'Retry')
            AND out.SaopEntityExists(message.OrganizationId, N'SAOP_PRICELIST', LEFT(message.EntityKey, CHARINDEX(N'|', message.EntityKey) - 1)) = 0
            THEN 1 ELSE 0 END)
        FROM out.OutboxMessage AS message
        WHERE message.TargetKind IN (N'SAOP_PRICE', N'SAOP_PRICELIST') AND message.OutboundBatchId IS NOT NULL
          AND (message.TargetKind = N'SAOP_PRICELIST' OR CHARINDEX(N'|', message.EntityKey) > 1)
        GROUP BY message.OutboundBatchId, message.TargetKind, message.EntityKey
      )
      SELECT TOP (@Top) batch.OutboundBatchId, batch.OrganizationId, OrganizationName = org.Name, batch.TargetKind, batch.Source, batch.Note,
        batch.CreatedBy, batch.CreatedUtc,
        Documents = COUNT(documents.EntityKey),
        AwaitingApproval = SUM(CASE WHEN documents.Status = N'PendingApproval' THEN 1 ELSE 0 END),
        Queued = SUM(CASE WHEN documents.Status = N'Queued' THEN 1 ELSE 0 END),
        Waiting = SUM(CASE WHEN documents.Status = N'Queued' AND documents.Waiting = 1 THEN 1 ELSE 0 END),
        Sent = SUM(CASE WHEN documents.Status = N'Sent' THEN 1 ELSE 0 END),
        Failed = SUM(CASE WHEN documents.Status = N'Failed' THEN 1 ELSE 0 END),
        Cancelled = SUM(CASE WHEN documents.Status IN (N'Cancelled', N'Superseded') THEN 1 ELSE 0 END)
      FROM out.OutboundBatch AS batch
      INNER JOIN org ON org.OrganizationId = batch.OrganizationId
      LEFT JOIN documents ON documents.OutboundBatchId = batch.OutboundBatchId
      WHERE batch.TargetKind IN (N'SAOP_PRICE', N'SAOP_PRICELIST')
        AND (@OrganizationId IS NULL OR batch.OrganizationId = @OrganizationId)
      GROUP BY batch.OutboundBatchId, batch.OrganizationId, org.Name, batch.TargetKind, batch.Source, batch.Note, batch.CreatedBy, batch.CreatedUtc
      ORDER BY batch.OutboundBatchId DESC;
      """;
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand(sql, connection) { CommandTimeout = 60 };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = (object?)organizationId ?? DBNull.Value;
    command.Parameters.Add("@Top", SqlDbType.Int).Value = top;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var rows = new List<PriceBatchRow>();
    while (await reader.ReadAsync(cancellationToken))
      rows.Add(new(
        PimDb.Int64(reader, "OutboundBatchId"), PimDb.Int32(reader, "OrganizationId"), PimDb.TextOrEmpty(reader, "OrganizationName"),
        PimDb.TextOrEmpty(reader, "TargetKind"), PimDb.TextOrEmpty(reader, "Source"), PimDb.Text(reader, "Note"),
        PimDb.TextOrEmpty(reader, "CreatedBy"), PimDb.DateTimeValue(reader, "CreatedUtc"),
        PimDb.Int32(reader, "Documents"), PimDb.Int32(reader, "AwaitingApproval"), PimDb.Int32(reader, "Queued"),
        PimDb.Int32(reader, "Waiting"), PimDb.Int32(reader, "Sent"), PimDb.Int32(reader, "Failed"), PimDb.Int32(reader, "Cancelled")));
    return rows;
  }

  public async Task<IReadOnlyList<PriceBatchEntity>> GetBatchEntitiesAsync(long batchId, int top = 500, CancellationToken cancellationToken = default)
  {
    const string sql = """
      SELECT TOP (@Top) message.TargetKind, message.EntityKey, Operation = MAX(message.Operation),
        Status = CASE
          WHEN SUM(CASE WHEN message.Status = N'PendingApproval' THEN 1 ELSE 0 END) > 0 THEN N'PendingApproval'
          WHEN SUM(CASE WHEN message.Status IN (N'Pending', N'Retry', N'Sending') THEN 1 ELSE 0 END) > 0 THEN N'Queued'
          WHEN SUM(CASE WHEN message.Status IN (N'Dead', N'Error', N'Drift') THEN 1 ELSE 0 END) > 0 THEN N'Failed'
          WHEN SUM(CASE WHEN message.Status IN (N'Sent', N'Verified') THEN 1 ELSE 0 END) > 0 THEN N'Sent'
          WHEN SUM(CASE WHEN message.Status = N'Cancelled' THEN 1 ELSE 0 END) > 0 THEN N'Cancelled'
          ELSE N'Superseded' END,
        Net = MAX(CASE WHEN message.FieldSummary = N'Price.Net' THEN JSON_VALUE(message.PayloadJson, N'$.value') END),
        VatRate = MAX(CASE WHEN message.FieldSummary = N'Price.VatRate' THEN JSON_VALUE(message.PayloadJson, N'$.value') END),
        Active = MAX(CASE WHEN message.FieldSummary IN (N'Price.Active', N'PriceList.Active') THEN JSON_VALUE(message.PayloadJson, N'$.value') END),
        ValidFrom = MAX(CASE WHEN message.FieldSummary = N'Price.ValidFrom' THEN JSON_VALUE(message.PayloadJson, N'$.value') END),
        Description = MAX(CASE WHEN message.FieldSummary = N'PriceList.PriceListDescription' THEN JSON_VALUE(message.PayloadJson, N'$.value') END),
        LastError = MAX(message.LastError), UpdatedUtc = MAX(message.UpdatedUtc),
        WaitsForPriceList = CONVERT(bit, MAX(CASE WHEN message.TargetKind = N'SAOP_PRICE' AND message.Status IN (N'Pending', N'Retry', N'PendingApproval')
          AND out.SaopEntityExists(message.OrganizationId, N'SAOP_PRICELIST', LEFT(message.EntityKey, CHARINDEX(N'|', message.EntityKey) - 1)) = 0
          THEN 1 ELSE 0 END))
      FROM out.OutboxMessage AS message
      WHERE message.OutboundBatchId = @BatchId AND message.TargetKind IN (N'SAOP_PRICE', N'SAOP_PRICELIST')
        AND (message.TargetKind = N'SAOP_PRICELIST' OR CHARINDEX(N'|', message.EntityKey) > 1)
      GROUP BY message.TargetKind, message.EntityKey
      ORDER BY CASE message.TargetKind WHEN N'SAOP_PRICELIST' THEN 0 ELSE 1 END, message.EntityKey;
      """;
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand(sql, connection) { CommandTimeout = 60 };
    command.Parameters.Add("@BatchId", SqlDbType.BigInt).Value = batchId;
    command.Parameters.Add("@Top", SqlDbType.Int).Value = top;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var rows = new List<PriceBatchEntity>();
    while (await reader.ReadAsync(cancellationToken))
      rows.Add(new(
        PimDb.TextOrEmpty(reader, "TargetKind"), PimDb.TextOrEmpty(reader, "EntityKey"), PimDb.TextOrEmpty(reader, "Operation"),
        PimDb.TextOrEmpty(reader, "Status"), PimDb.Text(reader, "Net"), PimDb.Text(reader, "VatRate"), PimDb.Text(reader, "Active"),
        PimDb.Text(reader, "ValidFrom"), PimDb.Text(reader, "Description"), PimDb.Text(reader, "LastError"),
        PimDb.DateTimeValue(reader, "UpdatedUtc"), PimDb.Bool(reader, "WaitsForPriceList")));
    return rows;
  }

  /* --- pisanje: vrsta za SAOP ----------------------------------------------------------------- */

  /// <param name="source">EXCEL (uvoz), CARD (ena cena na strani) ali BULK (napolnjen nov cenik).</param>
  /// <param name="batchId">Obstoječa serija (nov cenik s cenami gre v eno serijo, ena odobritev).</param>
  public async Task<PriceEnqueueOutcome> EnqueueAsync(
    int organizationId, IEnumerable<PriceChange> changes, string actor, string source, string? note,
    long? batchId = null, CancellationToken cancellationToken = default)
  {
    await guard.RequireAsync(PimPolicies.SaopWrite);
    var payload = JsonSerializer.Serialize(changes.Select(change => new
    {
      priceList = change.PriceList,
      itemId = change.ItemId,
      net = change.Net.ToString(CultureInfo.InvariantCulture),
      vatRate = change.VatRate?.ToString(CultureInfo.InvariantCulture),
      validFrom = change.ValidFrom?.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
      active = change.Active is { } active ? (active ? "true" : "false") : null,
    }));

    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand(
      "EXEC out.EnqueueSaopPriceChanges @OrganizationId, @ChangesJson, @Actor, @Source, @Note, @OutboundBatchId OUTPUT;", connection)
    { CommandTimeout = 600 };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@ChangesJson", SqlDbType.NVarChar, -1).Value = payload;
    command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
    command.Parameters.Add("@Source", SqlDbType.NVarChar, 30).Value = source;
    command.Parameters.Add("@Note", SqlDbType.NVarChar, 400).Value = (object?)Shorten(note, 400) ?? DBNull.Value;
    var batch = command.Parameters.Add("@OutboundBatchId", SqlDbType.BigInt);
    batch.Direction = ParameterDirection.InputOutput;
    batch.Value = (object?)batchId ?? DBNull.Value;

    var rows = new List<PriceEnqueueRow>();
    await using (var reader = await command.ExecuteReaderAsync(cancellationToken))
      while (await reader.ReadAsync(cancellationToken))
        rows.Add(new(
          PimDb.Int32(reader, "Zaporedna"), PimDb.Text(reader, "PriceList"), PimDb.Text(reader, "ItemID"),
          PimDb.TextOrEmpty(reader, "Status"), PimDb.Text(reader, "Reason"), PimDb.TextOrEmpty(reader, "Intent"),
          PimDb.NullableDecimal(reader, "OldNet"), PimDb.NullableDecimal(reader, "NewNet")));
    return new(batch.Value is DBNull ? null : Convert.ToInt64(batch.Value, CultureInfo.InvariantCulture), rows);
  }

  /// <summary>Nov cenik ali sprememba glave obstoječega; vrne serijo, v katero se lahko dodajo še cene.</summary>
  public async Task<(long? BatchId, string Operation)> EnqueuePriceListAsync(
    int organizationId, string code, string description, string? currency, bool vatIncluded, bool active, string actor,
    CancellationToken cancellationToken = default)
  {
    await guard.RequireAsync(PimPolicies.SaopWrite);
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("""
      EXEC out.EnqueueSaopPriceList @OrganizationId = @OrganizationId, @PriceListId = @Code, @Description = @Description,
        @CurrencyId = @Currency, @VatIncluded = @VatIncluded, @Active = @Active, @Actor = @Actor, @OutboundBatchId = @OutboundBatchId OUTPUT;
      """, connection);
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@Code", SqlDbType.NVarChar, 100).Value = code;
    command.Parameters.Add("@Description", SqlDbType.NVarChar, 400).Value = description;
    command.Parameters.Add("@Currency", SqlDbType.NVarChar, 20).Value = string.IsNullOrWhiteSpace(currency) ? DBNull.Value : currency.Trim();
    command.Parameters.Add("@VatIncluded", SqlDbType.Bit).Value = vatIncluded;
    command.Parameters.Add("@Active", SqlDbType.Bit).Value = active;
    command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
    var batch = command.Parameters.Add("@OutboundBatchId", SqlDbType.BigInt);
    batch.Direction = ParameterDirection.InputOutput;
    batch.Value = DBNull.Value;
    var operation = "ADD";
    await using (var reader = await command.ExecuteReaderAsync(cancellationToken))
      if (await reader.ReadAsync(cancellationToken)) operation = PimDb.TextOrEmpty(reader, "Operation");
    return (batch.Value is DBNull ? null : Convert.ToInt64(batch.Value, CultureInfo.InvariantCulture), operation);
  }

  /// <summary>
  /// Cene iz drugega cenika istega podjetja, pomnožene s faktorjem in zaokrožene na cent — za
  /// polnjenje novega cenika (npr. B2C × 0,90). DDV ostane izvorni.
  /// </summary>
  public async Task<IReadOnlyList<PriceChange>> CopyFromPriceListAsync(
    int organizationId, string sourcePriceList, string targetPriceList, decimal factor, CancellationToken cancellationToken = default)
  {
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand("""
      WITH current_price AS
      (
        SELECT product.ItemID, price.Net, price.VatRate, price.IsActive,
          ranked = ROW_NUMBER() OVER (PARTITION BY price.ProductId ORDER BY price.ValidFrom DESC)
        FROM canon.ProductPrice AS price
        INNER JOIN canon.Product AS product ON product.ProductId = price.ProductId
        WHERE product.OrganizationId = @OrganizationId AND price.PriceList = @PriceList
      )
      SELECT ItemID, Net, VatRate FROM current_price WHERE ranked = 1 AND IsActive = 1 ORDER BY ItemID;
      """, connection) { CommandTimeout = 120 };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = organizationId;
    command.Parameters.Add("@PriceList", SqlDbType.NVarChar, 100).Value = sourcePriceList;
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var rows = new List<PriceChange>();
    while (await reader.ReadAsync(cancellationToken))
      rows.Add(new(targetPriceList, PimDb.TextOrEmpty(reader, "ItemID"),
        Math.Round(PimDb.Decimal(reader, "Net") * factor, 2, MidpointRounding.AwayFromZero), PimDb.Decimal(reader, "VatRate")));
    return rows;
  }

  public async Task<int> CancelBatchAsync(long batchId, string actor, CancellationToken cancellationToken = default) =>
    await BatchCommandAsync("EXEC out.CancelOutboundBatch @Batch, @Actor;", batchId, actor, cancellationToken);

  /// <summary>Odobri serijo in začne pošiljanje v ozadju (najprej ceniki, nato cene) za podjetje serije.</summary>
  public async Task<(int Approved, PriceSendJob? Job, bool NotConfigured)> ApproveAndSendAsync(
    long batchId, int organizationId, string actor, CancellationToken cancellationToken = default)
  {
    var approved = await BatchCommandAsync("EXEC out.ApproveOutboundBatch @Batch, @Actor;", batchId, actor, cancellationToken);
    var (job, notConfigured) = await StartSendingAsync(organizationId, actor);
    return (approved, job, notConfigured);
  }

  /// <summary>Pošlje vse odobrene cene in cenike podjetja, ki še čakajo (tudi po ponovnem poskusu).</summary>
  public async Task<(PriceSendJob? Job, bool NotConfigured)> StartSendingAsync(int organizationId, string actor)
  {
    await guard.RequireAsync(PimPolicies.SaopWrite);
    return sendJobs.Start(ConnectionString, organizationId, actor);
  }

  public PriceSendJob? CurrentJob(int organizationId) => sendJobs.Current(organizationId);

  /* --- pomožno ------------------------------------------------------------------------------- */

  async Task<int> BatchCommandAsync(string sql, long batchId, string actor, CancellationToken cancellationToken)
  {
    await guard.RequireAsync(PimPolicies.SaopWrite);
    await using var connection = await OpenAsync(cancellationToken);
    await using var command = new SqlCommand(sql, connection);
    command.Parameters.Add("@Batch", SqlDbType.BigInt).Value = batchId;
    command.Parameters.Add("@Actor", SqlDbType.NVarChar, 200).Value = actor;
    var value = await command.ExecuteScalarAsync(cancellationToken);
    return value is null or DBNull ? 0 : Convert.ToInt32(value, CultureInfo.InvariantCulture);
  }

  static SqlCommand Command(SqlConnection connection, string sql, PriceQuery query)
  {
    var command = new SqlCommand(sql, connection) { CommandTimeout = 120 };
    command.Parameters.Add("@OrganizationId", SqlDbType.Int).Value = (object?)query.OrganizationId ?? DBNull.Value;
    command.Parameters.Add("@PriceList", SqlDbType.NVarChar, 100).Value = (object?)query.PriceList ?? DBNull.Value;
    command.Parameters.Add("@Search", SqlDbType.NVarChar, 200).Value = (object?)query.Search ?? DBNull.Value;
    command.Parameters.Add("@MinPriceLists", SqlDbType.Int).Value = Math.Max(1, query.MinPriceLists);
    command.Parameters.Add("@Queue", SqlDbType.NVarChar, 20).Value = (object?)query.Queue ?? DBNull.Value;
    return command;
  }

  static async Task<IReadOnlyList<PriceLine>> ReadLinesAsync(SqlCommand command, CancellationToken cancellationToken)
  {
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var rows = new List<PriceLine>();
    while (await reader.ReadAsync(cancellationToken))
      rows.Add(new(
        PimDb.Int32(reader, "OrganizationId"), PimDb.TextOrEmpty(reader, "OrganizationName"), PimDb.Int64(reader, "ProductId"),
        PimDb.TextOrEmpty(reader, "ItemID"), PimDb.Text(reader, "Title"), PimDb.Text(reader, "EAN"),
        PimDb.TextOrEmpty(reader, "PriceList"), PimDb.Text(reader, "PriceListName"),
        PimDb.NullableDecimal(reader, "Net"), PimDb.NullableDecimal(reader, "VatRate"), PimDb.NullableDateTime(reader, "ValidFrom"),
        PimDb.Bool(reader, "IsActive"), PimDb.NullableDecimal(reader, "QueuedNet"), PimDb.NullableDecimal(reader, "QueuedVat"),
        PimDb.Text(reader, "QueueStatus"), PimDb.Text(reader, "QueueError"), PimDb.Bool(reader, "InSaop")));
    return rows;
  }

  static string? Shorten(string? text, int length) =>
    string.IsNullOrWhiteSpace(text) ? null : text.Length <= length ? text : text[..length];

  async Task<SqlConnection> OpenAsync(CancellationToken cancellationToken)
  {
    var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    return connection;
  }

  sealed class PriceKeyComparer : IEqualityComparer<(int, string, string)>
  {
    public bool Equals((int, string, string) left, (int, string, string) right) =>
      left.Item1 == right.Item1 && string.Equals(left.Item2, right.Item2, StringComparison.OrdinalIgnoreCase)
        && string.Equals(left.Item3, right.Item3, StringComparison.OrdinalIgnoreCase);

    public int GetHashCode((int, string, string) key) =>
      HashCode.Combine(key.Item1, StringComparer.OrdinalIgnoreCase.GetHashCode(key.Item2), StringComparer.OrdinalIgnoreCase.GetHashCode(key.Item3));
  }

  /// <summary>Stanje v vrsti, kot ga bere uporabnik.</summary>
  public static string QueueLabel(string? status) => status switch
  {
    "PendingApproval" => "čaka odobritev",
    "Pending" or "Queued" => "odobreno, čaka pošiljanje",
    "Retry" => "ponovni poskus",
    "Sending" => "pošilja se",
    "Sent" => "poslano, čaka zajem iz SAOP",
    "Dead" or "Failed" => "SAOP je zavrnil",
    "Cancelled" => "preklicano",
    "Superseded" => "nadomeščeno",
    null or "" => "",
    _ => status,
  };

  public static string? QueueTone(string? status) => status switch
  {
    "Dead" or "Failed" => "bad",
    "PendingApproval" or "Retry" => "warn",
    "Sent" => "good",
    _ => null,
  };
}
