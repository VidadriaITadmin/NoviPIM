using Microsoft.Data.SqlClient;

namespace PIM.Intranet.Services;

public sealed record MediaRow(string Source, long SourceId, long ProductId, string ItemId, string Url, string Role, int SortOrder, string? Title, string Kind)
{
  /// <summary>Enolicen kljuc cez oba vira; sam ProductMediaId bi trcil z ProductDocumentId.</summary>
  public string Key => Source + "-" + SourceId.ToString(System.Globalization.CultureInfo.InvariantCulture);
}
public sealed record MediaKindCount(string Kind, long RowCount);
public sealed record MediaSummary(long ProductsWithMedia, long ProductsWithoutMedia, long TotalMedia, long SchemeLessCount);
public sealed record PriceRow(long ProductPriceId, long ProductId, string ItemId, string PriceList, decimal Net, decimal VatRate, DateTime ValidFrom, bool IsActive);

/// <summary>
/// Ena vrstica na izdelek, ne na ceno.
///
/// Uporabnik 2026-08-28: »mogoce bi bilo bolje, da bi bil samo en artikel in potem v tabeli
/// stevilo cenikov ali pa napis max treh cenikov, potem se doda pluse, ker je prevec potem
/// artiklov«. Merjeno: 300.197 cenovnih vrstic pri 157.216 izdelkih — seznam po cenah je isti
/// izdelek ponovil do dvajsetkrat.
/// </summary>
/// <param name="PriceListCount">Koliko cenikov ima izdelek; iz njega nastane napis »+N«.</param>
/// <param name="PriceListPreview">Prvi trije ceniki po abecedi, loceni z vejico.</param>
public sealed record ProductPriceGroupRow(
  long ProductId, string ItemId, string? Name, int PriceListCount, string PriceListPreview,
  decimal? MinNet, decimal? MaxNet, DateTime? LastValidFrom, int ActiveCount);
public sealed record PartnerRow(string Name, long ProductCount, long ActiveCount);
public sealed record AttributeRow(string AttributeCode, long ProductCount, long ValueCount, string? SampleValue);
public sealed record CategoryRow(int CategoryId, string CategoryTreeCode, string CategoryCode, string? ParentCategoryCode, int LevelNo, string CategoryName, string CategoryPath, bool IsActive, long ProductCount, long DescendantProductCount);
public sealed record WarehouseRow(int WarehouseId, string WarehouseCode, string? Name, string? WarehouseType, string? GroupCode, bool IsActive, DateTime UpdatedUtc);
public sealed record WebSiteRow(int WebSiteId, string WebSiteCode, string WebSiteName, string CategoryTreeCode, string LanguageCode, string CategoryFieldCode, int SortOrder, bool IsActive, long CategoryCount);
public sealed record LanguageRow(int LanguageRowId, string SaopLanguageId, string LanguageCode, string Name, int OrganizationId, bool IsActive, DateTime UpdatedUtc);

/// <summary>
/// Bralni model kataloskih strani: mediji, cene, partnerji, atributi, kategorije, sifranti.
///
/// SQL je tu in ne v <c>intranet.*</c> proceduri zato, ker je baza tuje ozemlje (BAZA) in so
/// v njej ta hip nastajale migracije. Poizvedbe so parametrizirane in preslikane po imenu
/// stolpca; prenos v procedure je zapisan kot nadaljnji korak v nacrtu.
/// </summary>
public sealed class CatalogReadService(PimDb database)
{
  // ─── Mediji ───────────────────────────────────────────────────────────────
  // Uporabnik je odlocil, da medij za zdaj ostane naslov v bazi; datotecno skladisce pride
  // pozneje. Stran zato prikazuje povezavo, vlogo in vrstni red, ne pa nalaganja datotek.
  public Task<(IReadOnlyList<MediaRow> Rows, long TotalCount)> GetMediaAsync(
    int organizationId, string? search, string? role, string? addressState, string? kind, string? sort,
    int skip, int take, CancellationToken cancellationToken = default)
  {
    var terms = SearchTerms(search);
    var source = MediaSource(terms);
    return database.PageAsync($"""
      {source}
      SELECT Source, SourceId, ProductId, ItemID, Url, Role, SortOrder, Title, Kind
      FROM medij
      WHERE (@Kind IS NULL OR Kind = @Kind)
      ORDER BY {MediaOrderBy(sort)}
      OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY;

      {source}
      SELECT COUNT_BIG(*) FROM medij WHERE (@Kind IS NULL OR Kind = @Kind);
      """,
      reader => new MediaRow(
        PimDb.TextOrEmpty(reader, "Source"), PimDb.Int64(reader, "SourceId"), PimDb.Int64(reader, "ProductId"),
        PimDb.TextOrEmpty(reader, "ItemID"), PimDb.TextOrEmpty(reader, "Url"), PimDb.TextOrEmpty(reader, "Role"),
        PimDb.Int32(reader, "SortOrder"), PimDb.Text(reader, "Title"), PimDb.TextOrEmpty(reader, "Kind")),
      command => BindMedia(command, organizationId, terms, role, addressState, kind, skip, take), cancellationToken);
  }

  /// <summary>
  /// Stevci po vrsti medija za isto zozitev, brez filtra vrste. Stran jih pokaze kot filtre,
  /// zato morajo povedati, koliko zapisov bo klik dejansko prinesel.
  /// </summary>
  public Task<IReadOnlyList<MediaKindCount>> GetMediaKindCountsAsync(
    int organizationId, string? search, string? role, string? addressState, CancellationToken cancellationToken = default)
  {
    var terms = SearchTerms(search);
    return database.QueryAsync($"""
      {MediaSource(terms)}
      SELECT Kind, COUNT_BIG(*) AS RowCountValue FROM medij GROUP BY Kind;
      """,
      reader => new MediaKindCount(PimDb.TextOrEmpty(reader, "Kind"), PimDb.Int64(reader, "RowCountValue")),
      command => BindMedia(command, organizationId, terms, role, addressState, null, 0, 0), cancellationToken);
  }

  /// <summary>
  /// Skupni izvor vseh poizvedb medijev.
  ///
  /// Dve odlocitvi sta tu namerni. Prva: slike (<c>canon.ProductMedia</c>) in dokumenti
  /// (<c>canon.ProductDocument</c>) sta dve tabeli, uporabnik pa ju vidi kot en predal —
  /// zato <c>UNION ALL</c> in stolpec <c>Source</c>, ne dve locni strani. Druga: vrsta se
  /// izracuna v skupnem izrazu <see cref="MediaKindPolicy.SqlKindExpression"/>, ki nastane iz
  /// istih seznamov kot razvrstitev v C#, da se ploscica in filter ne moreta raziti.
  /// </summary>
  static string MediaSource(IReadOnlyList<string> terms)
  {
    var kind = MediaKindPolicy.SqlKindExpression("Url", "Role");
    var search = terms.Count == 0
      ? string.Empty
      : string.Concat(terms.Select((_, index) =>
          $"\n          AND (ItemID LIKE @Term{index} OR Url LIKE @Term{index} OR Role LIKE @Term{index}"
          + $" OR (Title IS NOT NULL AND Title LIKE @Term{index}))"));

    return $"""
      WITH vsi AS (
        SELECT N'MEDIJ' AS Source, media.ProductMediaId AS SourceId, media.ProductId, product.ItemID,
               media.Url, media.Role, media.SortOrder, CONVERT(nvarchar(400), NULL) AS Title
        FROM canon.ProductMedia media
        INNER JOIN canon.Product product ON product.ProductId = media.ProductId
        WHERE product.OrganizationId = @OrganizationId
        UNION ALL
        SELECT N'DOKUMENT', document.ProductDocumentId, document.ProductId, product.ItemID,
               document.Url, document.Role, document.SortOrder, CONVERT(nvarchar(400), document.Title)
        FROM canon.ProductDocument document
        INNER JOIN canon.Product product ON product.ProductId = document.ProductId
        WHERE product.OrganizationId = @OrganizationId
      ), medij AS (
        SELECT Source, SourceId, ProductId, ItemID, Url, Role, SortOrder, Title, {kind} AS Kind
        FROM vsi
        WHERE (@Role IS NULL OR Role = @Role)
          AND (@AddressState IS NULL
            OR (@AddressState = N'OK' AND Url LIKE N'https://%')
            OR (@AddressState = N'CORRECTED' AND (Url LIKE N'//%' OR Url LIKE N'www.%'))
            OR (@AddressState = N'HTTP' AND Url LIKE N'http://%')
            OR (@AddressState = N'INVALID' AND Url NOT LIKE N'https://%' AND Url NOT LIKE N'http://%'
                AND Url NOT LIKE N'//%' AND Url NOT LIKE N'www.%')){search}
      )
      """;
  }

  static string MediaOrderBy(string? sort) => sort switch
  {
    "ARTIKEL_DESC" => "ItemID DESC, Kind, Role, SortOrder",
    "VLOGA" => "Role, ItemID, SortOrder",
    "VRSTA" => "Kind, ItemID, Role, SortOrder",
    "NASLOV" => "Url, ItemID",
    _ => "ItemID, Kind, Role, SortOrder"
  };

  /// <summary>Vzorec LIKE nastane v kodi, zato morajo nadomestni znaki iz vnosa ostati navadni znaki.</summary>
  static string LikeSafe(string value) => value.Replace("[", "[[]").Replace("%", "[%]").Replace("_", "[_]");

  /// <summary>Vsaka beseda vnosa je svoja zahteva — »203 navodila« najde dokument artikla 203.</summary>
  static IReadOnlyList<string> SearchTerms(string? search)
  {
    if (string.IsNullOrWhiteSpace(search)) return [];
    return search.Split([' ', '\t', ','], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
      .Take(6).ToArray();
  }

  static void BindMedia(SqlCommand command, int organizationId, IReadOnlyList<string> terms,
    string? role, string? addressState, string? kind, int skip, int take)
  {
    command.Parameters.AddWithValue("@OrganizationId", organizationId);
    command.Parameters.AddWithValue("@Role", string.IsNullOrWhiteSpace(role) ? DBNull.Value : role);
    command.Parameters.AddWithValue("@AddressState", string.IsNullOrWhiteSpace(addressState) ? DBNull.Value : addressState);
    command.Parameters.AddWithValue("@Kind", string.IsNullOrWhiteSpace(kind) ? DBNull.Value : kind);
    command.Parameters.AddWithValue("@Skip", skip);
    command.Parameters.AddWithValue("@Take", take);
    for (var index = 0; index < terms.Count; index++)
      command.Parameters.AddWithValue($"@Term{index}", "%" + LikeSafe(terms[index]) + "%");
  }

  /// <summary>Vloge obeh virov v enem sifrantu — dokumenti nosijo vecino pomenljivih vlog.</summary>
  public Task<IReadOnlyList<PimOption>> GetMediaRolesAsync(int organizationId, CancellationToken cancellationToken = default) =>
    database.QueryAsync("""
      SELECT Role, SUM(RowCountValue) AS RowCountValue FROM (
        SELECT media.Role, COUNT_BIG(*) AS RowCountValue
        FROM canon.ProductMedia media
        INNER JOIN canon.Product product ON product.ProductId = media.ProductId
        WHERE product.OrganizationId = @OrganizationId
        GROUP BY media.Role
        UNION ALL
        SELECT document.Role, COUNT_BIG(*)
        FROM canon.ProductDocument document
        INNER JOIN canon.Product product ON product.ProductId = document.ProductId
        WHERE product.OrganizationId = @OrganizationId
        GROUP BY document.Role
      ) AS vloge
      GROUP BY Role ORDER BY Role;
      """,
      reader => new PimOption(PimDb.TextOrEmpty(reader, "Role"),
        $"{PimDb.TextOrEmpty(reader, "Role")} ({PimDb.Int64(reader, "RowCountValue"):N0})"),
      command => command.Parameters.AddWithValue("@OrganizationId", organizationId), cancellationToken);

  public async Task<MediaSummary> GetMediaSummaryAsync(int organizationId, CancellationToken cancellationToken = default)
  {
    var rows = await database.QueryAsync("""
      SELECT
        (SELECT COUNT_BIG(DISTINCT media.ProductId) FROM canon.ProductMedia media
         INNER JOIN canon.Product product ON product.ProductId = media.ProductId
         WHERE product.OrganizationId = @OrganizationId) AS WithMedia,
        (SELECT COUNT_BIG(*) FROM canon.Product product
         WHERE product.OrganizationId = @OrganizationId AND product.IsActive = 1
           AND NOT EXISTS (SELECT 1 FROM canon.ProductMedia media WHERE media.ProductId = product.ProductId)) AS WithoutMedia,
        (SELECT COUNT_BIG(*) FROM canon.ProductMedia media
         INNER JOIN canon.Product product ON product.ProductId = media.ProductId
         WHERE product.OrganizationId = @OrganizationId) AS TotalMedia,
        (SELECT COUNT_BIG(*) FROM canon.ProductMedia media
         INNER JOIN canon.Product product ON product.ProductId = media.ProductId
         WHERE product.OrganizationId = @OrganizationId
           AND (media.Url LIKE N'//%' OR media.Url LIKE N'www.%'))
        + (SELECT COUNT_BIG(*) FROM canon.ProductDocument document
           INNER JOIN canon.Product product ON product.ProductId = document.ProductId
           WHERE product.OrganizationId = @OrganizationId
             AND (document.Url LIKE N'//%' OR document.Url LIKE N'www.%')) AS SchemeLessCount;
      """,
      reader => new MediaSummary(PimDb.Int64(reader, "WithMedia"), PimDb.Int64(reader, "WithoutMedia"),
        PimDb.Int64(reader, "TotalMedia"), PimDb.Int64(reader, "SchemeLessCount")),
      command => command.Parameters.AddWithValue("@OrganizationId", organizationId), cancellationToken);
    return rows.Count > 0 ? rows[0] : new(0, 0, 0, 0);
  }

  // ─── Cene ─────────────────────────────────────────────────────────────────
  public Task<IReadOnlyList<PimOption>> GetPriceListsAsync(int organizationId, CancellationToken cancellationToken = default) =>
    database.QueryAsync("""
      SELECT price.PriceList, COUNT_BIG(*) AS RowCountValue
      FROM canon.ProductPrice price
      INNER JOIN canon.Product product ON product.ProductId = price.ProductId
      WHERE product.OrganizationId = @OrganizationId
      GROUP BY price.PriceList
      ORDER BY price.PriceList;
      """,
      reader => new PimOption(PimDb.TextOrEmpty(reader, "PriceList"),
        $"{PimDb.TextOrEmpty(reader, "PriceList")} ({PimDb.Int64(reader, "RowCountValue"):N0})"),
      command => command.Parameters.AddWithValue("@OrganizationId", organizationId), cancellationToken);

  public Task<(IReadOnlyList<PriceRow> Rows, long TotalCount)> GetPricesAsync(
    int organizationId, string? priceList, string? search, int skip, int take, CancellationToken cancellationToken = default) =>
    database.PageAsync("""
      SELECT price.ProductPriceId, price.ProductId, product.ItemID, price.PriceList, price.Net, price.VatRate, price.ValidFrom, price.IsActive
      FROM canon.ProductPrice price
      INNER JOIN canon.Product product ON product.ProductId = price.ProductId
      WHERE product.OrganizationId = @OrganizationId
        AND (@PriceList IS NULL OR price.PriceList = @PriceList)
        AND (@Search IS NULL OR product.ItemID LIKE '%' + @Search + '%')
      ORDER BY product.ItemID, price.PriceList, price.ValidFrom DESC
      OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY;

      SELECT COUNT_BIG(*)
      FROM canon.ProductPrice price
      INNER JOIN canon.Product product ON product.ProductId = price.ProductId
      WHERE product.OrganizationId = @OrganizationId
        AND (@PriceList IS NULL OR price.PriceList = @PriceList)
        AND (@Search IS NULL OR product.ItemID LIKE '%' + @Search + '%');
      """,
      reader => new PriceRow(
        PimDb.Int64(reader, "ProductPriceId"), PimDb.Int64(reader, "ProductId"), PimDb.TextOrEmpty(reader, "ItemID"),
        PimDb.TextOrEmpty(reader, "PriceList"), PimDb.Decimal(reader, "Net"), PimDb.Decimal(reader, "VatRate"),
        PimDb.DateTimeValue(reader, "ValidFrom"), PimDb.Bool(reader, "IsActive")),
      command =>
      {
        Bind(command, organizationId, search, skip, take);
        command.Parameters.AddWithValue("@PriceList", string.IsNullOrWhiteSpace(priceList) ? DBNull.Value : priceList);
      }, cancellationToken);

  /// <summary>Cene, zgoscene na izdelek. Podrobnost cenikov se odpre v vrstici, brez odhoda s strani.</summary>
  /// <param name="minPriceLists">Zozi na izdelke z vsaj toliko ceniki; 0 pomeni brez omejitve.</param>
  public Task<(IReadOnlyList<ProductPriceGroupRow> Rows, long TotalCount)> GetProductPriceGroupsAsync(
    int organizationId, string? priceList, string? search, int minPriceLists, int skip, int take,
    CancellationToken cancellationToken = default) =>
    database.PageAsync("""
      WITH grouped AS
      (
        SELECT price.ProductId,
          PriceListCount = COUNT(DISTINCT price.PriceList),
          ActiveCount = COUNT(DISTINCT CASE WHEN price.IsActive = 1 THEN price.PriceList END),
          MinNet = MIN(price.Net), MaxNet = MAX(price.Net), LastValidFrom = MAX(price.ValidFrom)
        FROM canon.ProductPrice price
        INNER JOIN canon.Product product ON product.ProductId = price.ProductId
        WHERE product.OrganizationId = @OrganizationId
          AND (@PriceList IS NULL OR price.PriceList = @PriceList)
          AND (@Search IS NULL OR product.ItemID LIKE '%' + @Search + '%')
        GROUP BY price.ProductId
        HAVING COUNT(DISTINCT price.PriceList) >= @MinPriceLists
      )
      SELECT grouped.ProductId, product.ItemID, Name = title.Value,
        grouped.PriceListCount, grouped.ActiveCount, grouped.MinNet, grouped.MaxNet, grouped.LastValidFrom,
        PriceListPreview = STUFF((
          SELECT TOP (3) ', ' + preview.PriceList
          FROM (SELECT DISTINCT inner_price.PriceList FROM canon.ProductPrice inner_price WHERE inner_price.ProductId = grouped.ProductId) AS preview
          ORDER BY preview.PriceList
          FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, '')
      FROM grouped
      INNER JOIN canon.Product product ON product.ProductId = grouped.ProductId
      OUTER APPLY
      (
        SELECT TOP (1) textValue.Value
        FROM canon.ProductText textValue
        WHERE textValue.ProductId = grouped.ProductId AND textValue.TextType IN ('WEB_TITLE', 'TITLE_ERP')
        ORDER BY CASE WHEN textValue.TextType = 'WEB_TITLE' THEN 0 ELSE 1 END,
          CASE WHEN textValue.Lang = 'sl' THEN 0 ELSE 1 END, textValue.Lang
      ) AS title
      ORDER BY product.ItemID
      OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY;

      SELECT COUNT_BIG(*) FROM
      (
        SELECT price.ProductId
        FROM canon.ProductPrice price
        INNER JOIN canon.Product product ON product.ProductId = price.ProductId
        WHERE product.OrganizationId = @OrganizationId
          AND (@PriceList IS NULL OR price.PriceList = @PriceList)
          AND (@Search IS NULL OR product.ItemID LIKE '%' + @Search + '%')
        GROUP BY price.ProductId
        HAVING COUNT(DISTINCT price.PriceList) >= @MinPriceLists
      ) AS counted;
      """,
      reader => new ProductPriceGroupRow(
        PimDb.Int64(reader, "ProductId"), PimDb.TextOrEmpty(reader, "ItemID"), PimDb.Text(reader, "Name"),
        PimDb.Int32(reader, "PriceListCount"), PimDb.TextOrEmpty(reader, "PriceListPreview"),
        PimDb.Decimal(reader, "MinNet"), PimDb.Decimal(reader, "MaxNet"),
        PimDb.NullableDateTime(reader, "LastValidFrom"), PimDb.Int32(reader, "ActiveCount")),
      command =>
      {
        Bind(command, organizationId, search, skip, take);
        command.Parameters.AddWithValue("@PriceList", string.IsNullOrWhiteSpace(priceList) ? DBNull.Value : priceList);
        command.Parameters.AddWithValue("@MinPriceLists", Math.Max(1, minPriceLists));
      }, cancellationToken);

  /// <summary>Vsi ceniki enega izdelka; odpre se v vrstici seznama, ne na drugi strani.</summary>
  public Task<IReadOnlyList<PriceRow>> GetPricesForProductAsync(
    long productId, CancellationToken cancellationToken = default) =>
    database.QueryAsync("""
      SELECT price.ProductPriceId, price.ProductId, product.ItemID, price.PriceList,
        price.Net, price.VatRate, price.ValidFrom, price.IsActive
      FROM canon.ProductPrice price
      INNER JOIN canon.Product product ON product.ProductId = price.ProductId
      WHERE price.ProductId = @ProductId
      ORDER BY price.PriceList, price.ValidFrom DESC;
      """,
      reader => new PriceRow(
        PimDb.Int64(reader, "ProductPriceId"), PimDb.Int64(reader, "ProductId"), PimDb.TextOrEmpty(reader, "ItemID"),
        PimDb.TextOrEmpty(reader, "PriceList"), PimDb.Decimal(reader, "Net"), PimDb.Decimal(reader, "VatRate"),
        PimDb.DateTimeValue(reader, "ValidFrom"), PimDb.Bool(reader, "IsActive")),
      command => command.Parameters.AddWithValue("@ProductId", productId), cancellationToken);

  // ─── Partnerji ────────────────────────────────────────────────────────────
  // Dobavitelj in proizvajalec sta danes polji na izdelku, ne svoja sifranta. Stran zato
  // pokaze, kar dejansko obstaja: imena in koliko izdelkov stoji za njimi.
  public Task<IReadOnlyList<PartnerRow>> GetPartnersAsync(int organizationId, bool suppliers, CancellationToken cancellationToken = default) =>
    database.QueryAsync($"""
      SELECT {(suppliers ? "product.Supplier" : "product.Manufacturer")} AS Name,
             COUNT_BIG(*) AS ProductCount,
             SUM(CASE WHEN product.IsActive = 1 THEN 1 ELSE 0 END) AS ActiveCount
      FROM canon.Product product
      WHERE product.OrganizationId = @OrganizationId
        AND NULLIF({(suppliers ? "product.Supplier" : "product.Manufacturer")}, N'') IS NOT NULL
      GROUP BY {(suppliers ? "product.Supplier" : "product.Manufacturer")}
      ORDER BY COUNT_BIG(*) DESC;
      """,
      reader => new PartnerRow(PimDb.TextOrEmpty(reader, "Name"), PimDb.Int64(reader, "ProductCount"), PimDb.Int64(reader, "ActiveCount")),
      command => command.Parameters.AddWithValue("@OrganizationId", organizationId), cancellationToken);

  // ─── Atributi ─────────────────────────────────────────────────────────────
  public Task<IReadOnlyList<AttributeRow>> GetAttributesAsync(int organizationId, CancellationToken cancellationToken = default) =>
    database.QueryAsync("""
      SELECT attribute.AttributeCode,
             COUNT_BIG(DISTINCT attribute.ProductId) AS ProductCount,
             COUNT_BIG(*) AS ValueCount,
             MIN(attribute.Value) AS SampleValue
      FROM canon.ProductAttribute attribute
      INNER JOIN canon.Product product ON product.ProductId = attribute.ProductId
      WHERE product.OrganizationId = @OrganizationId
      GROUP BY attribute.AttributeCode
      ORDER BY COUNT_BIG(DISTINCT attribute.ProductId) DESC, attribute.AttributeCode;
      """,
      reader => new AttributeRow(PimDb.TextOrEmpty(reader, "AttributeCode"), PimDb.Int64(reader, "ProductCount"),
        PimDb.Int64(reader, "ValueCount"), PimDb.Text(reader, "SampleValue")),
      command => command.Parameters.AddWithValue("@OrganizationId", organizationId), cancellationToken);

  // ─── Kategorije ───────────────────────────────────────────────────────────
  // Drevo je skupno vsem organizacijam, stevilo izdelkov pa je vezano na izbrano.
  public Task<IReadOnlyList<CategoryRow>> GetCategoriesAsync(int organizationId, string? treeCode, CancellationToken cancellationToken = default) =>
    database.QueryAsync("""
      SELECT category.CategoryId, category.CategoryTreeCode, category.CategoryCode, category.ParentCategoryCode,
             category.LevelNo, category.CategoryName, category.CategoryPath, category.IsActive,
             ISNULL(usage.ProductCount, 0) AS ProductCount,
             ISNULL(descendantUsage.ProductCount, 0) AS DescendantProductCount
      FROM canon.Category category
      OUTER APPLY
      (
        SELECT COUNT_BIG(*) AS ProductCount
        FROM canon.ProductCategory productCategory
        INNER JOIN canon.Product product ON product.ProductId = productCategory.ProductId
        WHERE product.OrganizationId = @OrganizationId AND productCategory.CategoryPath = category.CategoryPath
      ) usage
      OUTER APPLY
      (
        SELECT COUNT_BIG(DISTINCT productCategory.ProductId) AS ProductCount
        FROM canon.ProductCategory productCategory
        INNER JOIN canon.Product product ON product.ProductId = productCategory.ProductId
        WHERE product.OrganizationId = @OrganizationId
          AND (productCategory.CategoryPath = category.CategoryPath
            OR productCategory.CategoryPath LIKE category.CategoryPath + N'/%')
      ) descendantUsage
      WHERE (@TreeCode IS NULL OR category.CategoryTreeCode = @TreeCode)
      ORDER BY category.CategoryTreeCode, category.CategoryPath;
      """,
      reader => new CategoryRow(
        PimDb.Int32(reader, "CategoryId"), PimDb.TextOrEmpty(reader, "CategoryTreeCode"), PimDb.TextOrEmpty(reader, "CategoryCode"),
        PimDb.Text(reader, "ParentCategoryCode"), PimDb.Int32(reader, "LevelNo"), PimDb.TextOrEmpty(reader, "CategoryName"),
        PimDb.TextOrEmpty(reader, "CategoryPath"), PimDb.Bool(reader, "IsActive"), PimDb.Int64(reader, "ProductCount"), PimDb.Int64(reader, "DescendantProductCount")),
      command =>
      {
        command.Parameters.AddWithValue("@OrganizationId", organizationId);
        command.Parameters.AddWithValue("@TreeCode", string.IsNullOrWhiteSpace(treeCode) ? DBNull.Value : treeCode);
      }, cancellationToken);

  public Task<IReadOnlyList<PimOption>> GetCategoryTreesAsync(CancellationToken cancellationToken = default) =>
    database.QueryAsync("""
      SELECT CategoryTreeCode, COUNT_BIG(*) AS NodeCount
      FROM canon.Category GROUP BY CategoryTreeCode ORDER BY CategoryTreeCode;
      """,
      reader => new PimOption(PimDb.TextOrEmpty(reader, "CategoryTreeCode"),
        $"{PimDb.TextOrEmpty(reader, "CategoryTreeCode")} ({PimDb.Int64(reader, "NodeCount"):N0})"),
      cancellationToken: cancellationToken);

  // ─── Sifranti ─────────────────────────────────────────────────────────────
  public Task<IReadOnlyList<WarehouseRow>> GetWarehousesAsync(int organizationId, CancellationToken cancellationToken = default) =>
    database.QueryAsync("""
      SELECT WarehouseId, WarehouseCode, Name, WarehouseType, GroupCode, IsActive, UpdatedUtc
      FROM canon.Warehouse WHERE OrganizationId = @OrganizationId ORDER BY WarehouseCode;
      """,
      reader => new WarehouseRow(PimDb.Int32(reader, "WarehouseId"), PimDb.TextOrEmpty(reader, "WarehouseCode"),
        PimDb.Text(reader, "Name"), PimDb.Text(reader, "WarehouseType"), PimDb.Text(reader, "GroupCode"),
        PimDb.Bool(reader, "IsActive"), PimDb.DateTimeValue(reader, "UpdatedUtc")),
      command => command.Parameters.AddWithValue("@OrganizationId", organizationId), cancellationToken);

  public Task<IReadOnlyList<WebSiteRow>> GetWebSitesAsync(CancellationToken cancellationToken = default) =>
    database.QueryAsync("""
      SELECT site.WebSiteId, site.WebSiteCode, site.WebSiteName, site.CategoryTreeCode, site.LanguageCode,
             site.CategoryFieldCode, site.SortOrder, site.IsActive,
             (SELECT COUNT_BIG(*) FROM canon.Category category WHERE category.CategoryTreeCode = site.CategoryTreeCode) AS CategoryCount
      FROM canon.WebSite site ORDER BY site.SortOrder, site.WebSiteCode;
      """,
      reader => new WebSiteRow(PimDb.Int32(reader, "WebSiteId"), PimDb.TextOrEmpty(reader, "WebSiteCode"),
        PimDb.TextOrEmpty(reader, "WebSiteName"), PimDb.TextOrEmpty(reader, "CategoryTreeCode"), PimDb.TextOrEmpty(reader, "LanguageCode"),
        PimDb.TextOrEmpty(reader, "CategoryFieldCode"), PimDb.Int32(reader, "SortOrder"), PimDb.Bool(reader, "IsActive"),
        PimDb.Int64(reader, "CategoryCount")),
      cancellationToken: cancellationToken);

  public Task<IReadOnlyList<LanguageRow>> GetLanguagesAsync(int? organizationId, CancellationToken cancellationToken = default) =>
    database.QueryAsync("""
      SELECT LanguageRowId, LanguageId AS SaopLanguageId, LanguageCode, Name, OrganizationId, IsActive, UpdatedUtc
      FROM canon.Language
      WHERE (@OrganizationId IS NULL OR OrganizationId = @OrganizationId)
      ORDER BY OrganizationId, LanguageCode;
      """,
      reader => new LanguageRow(PimDb.Int32(reader, "LanguageRowId"), PimDb.TextOrEmpty(reader, "SaopLanguageId"),
        PimDb.TextOrEmpty(reader, "LanguageCode"), PimDb.TextOrEmpty(reader, "Name"), PimDb.Int32(reader, "OrganizationId"), PimDb.Bool(reader, "IsActive"),
        PimDb.DateTimeValue(reader, "UpdatedUtc")),
      command => command.Parameters.AddWithValue("@OrganizationId", organizationId is null ? DBNull.Value : organizationId.Value),
      cancellationToken);

  static void Bind(SqlCommand command, int organizationId, string? search, int skip, int take)
  {
    command.Parameters.AddWithValue("@OrganizationId", organizationId);
    command.Parameters.AddWithValue("@Search", string.IsNullOrWhiteSpace(search) ? DBNull.Value : search.Trim());
    command.Parameters.AddWithValue("@Skip", skip);
    command.Parameters.AddWithValue("@Take", take);
  }
}
