using Microsoft.Data.SqlClient;

namespace PIM.Intranet.Services;

/// <param name="CreatedUtc">Cas vnosa v PIM (migracija 249); null pomeni pred zacetkom belezenja.</param>
public sealed record MediaRow(
  string Source, long SourceId, long ProductId, string ItemId, string Url, string Role, int SortOrder, string? Title, string Kind,
  int OrganizationId, string OrganizationName, string? ProductName, bool ProductActive, DateTime? CreatedUtc)
{
  /// <summary>Enolicen kljuc cez oba vira; sam ProductMediaId bi trcil z ProductDocumentId.</summary>
  public string Key => Source + "-" + SourceId.ToString(System.Globalization.CultureInfo.InvariantCulture);
}
public sealed record MediaKindCount(string Kind, long RowCount);
/// <param name="AddedLastWeek">Slike in dokumenti, vneseni v zadnjih sedmih dneh.</param>
public sealed record MediaSummary(long ProductsWithMedia, long ProductsWithoutMedia, long TotalMedia, long AddedLastWeek);

/// <summary>
/// Filtri strani Mediji. Prazno ali null pomeni "brez omejitve"; podjetje null pomeni vsa
/// aktivna podjetja iz <c>dbo.OrganizationConfig</c>.
/// </summary>
/// <param name="Host">Streznik brez "www."; <see cref="CatalogReadService.NoMediaHost"/> pomeni naslov brez streznika.</param>
/// <param name="Activity"><c>AKTIVNI</c> ali <c>NEAKTIVNI</c> izdelki.</param>
/// <param name="AddedDays">Samo mediji, vneseni v zadnjih toliko dneh.</param>
public sealed record MediaFilter(
  int? OrganizationId = null, string? Search = null, string? Role = null, string? AddressState = null, string? Kind = null,
  string? Host = null, string? Activity = null, int? AddedDays = null, string? Sort = null);
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
public sealed record ReservationExclusionRow(int OrganizationId, string OrganizationName, string ItemId, string? Name, DateTime UpdatedUtc);

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

  /// <summary>Vrednost filtra streznika za naslove brez streznika (relativne ali pokvarjene).</summary>
  public const string NoMediaHost = "-";

  public Task<(IReadOnlyList<MediaRow> Rows, long TotalCount)> GetMediaAsync(
    MediaFilter filter, int skip, int take, CancellationToken cancellationToken = default)
  {
    var terms = SearchTerms(filter.Search);
    var source = MediaSource(terms);
    var query = MediaQuery(terms);
    var order = MediaOrderBy(filter.Sort);
    // Naziv izdelka se prebere sele za vrstice na strani: za vse zapise bi bil to en OUTER APPLY
    // na vrstico, na zaslonu pa jih je najvec 50.
    return database.PageAsync($"""
      {query}, stran AS (
        SELECT Source, SourceId, ProductId, ItemID, OrganizationId, OrganizationName, ProductActive,
               Url, Role, SortOrder, Title, Kind, CreatedUtc
        FROM medij
        WHERE (@Kind IS NULL OR Kind = @Kind)
        ORDER BY {order}
        OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY
      )
      SELECT stran.Source, stran.SourceId, stran.ProductId, stran.ItemID, stran.OrganizationId, stran.OrganizationName,
             stran.ProductActive, stran.Url, stran.Role, stran.SortOrder, stran.Title, stran.Kind, stran.CreatedUtc,
             naziv.Value AS ProductName
      FROM stran
      OUTER APPLY
      (
        SELECT TOP (1) besedilo.Value
        FROM canon.ProductText AS besedilo
        WHERE besedilo.ProductId = stran.ProductId AND besedilo.TextType IN (N'WEB_TITLE', N'TITLE_ERP')
        ORDER BY CASE WHEN besedilo.TextType = N'WEB_TITLE' THEN 0 ELSE 1 END,
          CASE WHEN besedilo.Lang = N'sl' THEN 0 ELSE 1 END, besedilo.Lang
      ) AS naziv
      ORDER BY {order}
      {Recompile};

      {source}
      SELECT COUNT_BIG(*) FROM medij WHERE (@Kind IS NULL OR Kind = @Kind) {Recompile};
      """,
      reader => new MediaRow(
        PimDb.TextOrEmpty(reader, "Source"), PimDb.Int64(reader, "SourceId"), PimDb.Int64(reader, "ProductId"),
        PimDb.TextOrEmpty(reader, "ItemID"), PimDb.TextOrEmpty(reader, "Url"), PimDb.TextOrEmpty(reader, "Role"),
        PimDb.Int32(reader, "SortOrder"), PimDb.Text(reader, "Title"), PimDb.TextOrEmpty(reader, "Kind"),
        PimDb.Int32(reader, "OrganizationId"), PimDb.TextOrEmpty(reader, "OrganizationName"), PimDb.Text(reader, "ProductName"),
        PimDb.Bool(reader, "ProductActive"), PimDb.NullableDateTime(reader, "CreatedUtc")),
      command => BindMedia(command, filter, terms, skip, take), cancellationToken);
  }

  /// <summary>
  /// Stevci po vrsti medija za isto zozitev, brez filtra vrste. Stran jih pokaze kot filtre,
  /// zato morajo povedati, koliko zapisov bo klik dejansko prinesel.
  /// </summary>
  public Task<IReadOnlyList<MediaKindCount>> GetMediaKindCountsAsync(MediaFilter filter, CancellationToken cancellationToken = default)
  {
    var terms = SearchTerms(filter.Search);
    return database.QueryAsync($"""
      {MediaQuery(terms)}
      SELECT Kind, COUNT_BIG(*) AS RowCountValue FROM medij GROUP BY Kind {Recompile};
      """,
      reader => new MediaKindCount(PimDb.TextOrEmpty(reader, "Kind"), PimDb.Int64(reader, "RowCountValue")),
      command => BindMedia(command, filter with { Kind = null }, terms, 0, 0), cancellationToken);
  }

  /// <summary>
  /// Skupni izvor vseh poizvedb medijev.
  ///
  /// Tri odlocitve so tu namerne. Prva: slike (<c>canon.ProductMedia</c>) in dokumenti
  /// (<c>canon.ProductDocument</c>) sta dve tabeli, uporabnik pa ju vidi kot en predal —
  /// zato <c>UNION ALL</c> in stolpec <c>Source</c>, ne dve locni strani. Druga: vrsta se
  /// izracuna v skupnem izrazu <see cref="MediaKindPolicy.SqlKindExpression"/>, ki nastane iz
  /// istih seznamov kot razvrstitev v C#, da se ploscica in filter ne moreta raziti. Tretja:
  /// obseg so aktivna podjetja iz <c>dbo.OrganizationConfig</c>, ne prvo podjetje po sifri.
  /// Uporabnik 2026-09-22: stran je privzeto pokazala DEMO, 82 slik Vidadrie, uvozenih isti dan,
  /// pa se ni dalo najti — zdelo se je, da jih v bazi ni.
  /// </summary>
  /// <summary>
  /// Zadetki iskanja na ravni izdelka, izracunani enkrat pred poizvedbo medijev: za vsako besedo
  /// tabela izdelkov, pri katerih jo najde sifra, EAN, dobavitelj, proizvajalec, podjetje ali
  /// naziv. Na vrstico medija ostanejo samo naslov, vloga in naziv dokumenta.
  ///
  /// Hitrost (merjeno 2026-09-22, ~48.000 medijev pri ~7.700 izdelkih): EXISTS po nazivu za
  /// vsak medij je trajal ~9 s; tudi kot CTE ga je optimizator ponavljal za vsako vrstico
  /// (~2 s). Tabelna spremenljivka je izracunana enkrat. Primerjave so LOWER + binarna kolacija
  /// — vzorec pride v malih crkah, zato iskanje ostane neobcutljivo na velikost crk.
  /// </summary>
  static string MediaSearchPrelude(IReadOnlyList<string> terms) => string.Concat(terms.Select((_, index) => $"""
    DECLARE @Zadetki{index} TABLE (ProductId bigint NOT NULL PRIMARY KEY);
    INSERT @Zadetki{index} (ProductId)
    SELECT product.ProductId
    FROM canon.Product product
    INNER JOIN dbo.OrganizationConfig organization
      ON organization.OrganizationId = product.OrganizationId AND organization.IsActive = 1
    WHERE (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
      AND product.ProductId IN (SELECT ProductId FROM canon.ProductMedia UNION SELECT ProductId FROM canon.ProductDocument)
      AND ({Lowered("product.ItemID")} LIKE @Term{index} OR {Lowered("product.EAN")} LIKE @Term{index}
        OR {Lowered("product.Supplier")} LIKE @Term{index} OR {Lowered("product.Manufacturer")} LIKE @Term{index}
        OR {Lowered("organization.Name")} LIKE @Term{index}
        OR EXISTS (SELECT 1 FROM canon.ProductText besedilo
                   WHERE besedilo.ProductId = product.ProductId
                     AND besedilo.TextType IN (N'WEB_TITLE', N'TITLE_ERP', N'SEARCH_NAME')
                     AND {Lowered("besedilo.Value")} LIKE @Term{index}))
    {Recompile};

    """));

  /// <summary>Uvod in izvor skupaj — za poizvedbo, ki izvor uporabi enkrat.</summary>
  static string MediaQuery(IReadOnlyList<string> terms) => "SET NOCOUNT ON;\n" + MediaSearchPrelude(terms) + MediaSource(terms);

  static string MediaSource(IReadOnlyList<string> terms)
  {
    var kind = MediaKindPolicy.SqlKindExpression("Url", "Role");
    // Vsaka beseda mora najti zadetek v katerem koli polju: sifra, EAN, naslov, vloga, naziv
    // dokumenta, dobavitelj, proizvajalec, podjetje ali naziv izdelka. Polja izdelka so
    // izracunana vnaprej (MediaSearchPrelude), polja medija se primerjajo tu.
    var nameJoins = string.Concat(terms.Select((_, index) =>
      $"\n        LEFT JOIN @Zadetki{index} zadetek{index} ON zadetek{index}.ProductId = vsi.ProductId"));
    var search = string.Concat(terms.Select((_, index) =>
      $"\n          AND (zadetek{index}.ProductId IS NOT NULL"
      + string.Concat(new[] { "Url", "Role", "Title" }.Select(column => $" OR {Lowered("vsi." + column)} LIKE @Term{index}"))
      + ")"));

    return $"""
      WITH vsi AS (
        SELECT N'MEDIJ' AS Source, media.ProductMediaId AS SourceId, media.ProductId, product.ItemID,
               product.IsActive AS ProductActive,
               product.OrganizationId, organization.Name AS OrganizationName,
               media.Url, media.Role, media.SortOrder, CONVERT(nvarchar(400), NULL) AS Title, media.CreatedUtc
        FROM canon.ProductMedia media
        INNER JOIN canon.Product product ON product.ProductId = media.ProductId
        INNER JOIN dbo.OrganizationConfig organization
          ON organization.OrganizationId = product.OrganizationId AND organization.IsActive = 1
        WHERE (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
        UNION ALL
        SELECT N'DOKUMENT', document.ProductDocumentId, document.ProductId, product.ItemID,
               product.IsActive,
               product.OrganizationId, organization.Name,
               document.Url, document.Role, document.SortOrder, CONVERT(nvarchar(400), document.Title), document.CreatedUtc
        FROM canon.ProductDocument document
        INNER JOIN canon.Product product ON product.ProductId = document.ProductId
        INNER JOIN dbo.OrganizationConfig organization
          ON organization.OrganizationId = product.OrganizationId AND organization.IsActive = 1
        WHERE (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
      ), medij AS (
        SELECT vsi.Source, vsi.SourceId, vsi.ProductId, vsi.ItemID, vsi.OrganizationId, vsi.OrganizationName,
               vsi.ProductActive, vsi.Url, vsi.Role, vsi.SortOrder, vsi.Title, vsi.CreatedUtc,
               {kind} AS Kind, gostitelj.Host
        FROM vsi{nameJoins}
        {MediaHostApply}
        WHERE (@Role IS NULL OR vsi.Role = @Role)
          AND (@Activity IS NULL
            OR (@Activity = N'AKTIVNI' AND vsi.ProductActive = 1)
            OR (@Activity = N'NEAKTIVNI' AND vsi.ProductActive = 0))
          AND (@AddedSince IS NULL OR vsi.CreatedUtc >= @AddedSince)
          AND (@Host IS NULL OR gostitelj.Host = @Host)
          AND (@AddressState IS NULL
            OR (@AddressState = N'OK' AND vsi.Url LIKE N'https://%')
            OR (@AddressState = N'CORRECTED' AND (vsi.Url LIKE N'//%' OR vsi.Url LIKE N'www.%'))
            OR (@AddressState = N'HTTP' AND vsi.Url LIKE N'http://%')
            OR (@AddressState = N'INVALID' AND vsi.Url NOT LIKE N'https://%' AND vsi.Url NOT LIKE N'http://%'
                AND vsi.Url NOT LIKE N'//%' AND vsi.Url NOT LIKE N'www.%')){search}
      )
      """;
  }

  static string Lowered(string column) => $"LOWER({column}) COLLATE Latin1_General_BIN2";

  /// <summary>
  /// Vsak stavek medijev se prevede za dane vrednosti. Filtri so oblike <c>@X IS NULL OR …</c>;
  /// z obstojecim nacrtom bi baza vrsto in streznik racunala za vseh ~48.000 zapisov tudi takrat,
  /// ko filter ni izbran. Prevajanje je poceni v primerjavi s tem.
  /// </summary>
  const string Recompile = "OPTION (RECOMPILE)";

  /// <summary>
  /// Streznik naslova brez sheme in brez "www." (<c>vipelektro.si</c>). Naslov brez streznika
  /// (relativna pot, pokvarjen zapis) da prazen niz — tak medij se v brskalniku ne nalozi.
  /// Binarna kolacija iz istega razloga kot v <see cref="MediaKindPolicy.SqlKindExpression"/>.
  /// </summary>
  const string MediaHostApply = """
        CROSS APPLY (SELECT U = LOWER(LTRIM(RTRIM(vsi.Url))) COLLATE Latin1_General_BIN2) AS naslov
        CROSS APPLY (SELECT Rest = CASE
            WHEN naslov.U LIKE N'%://%' THEN SUBSTRING(naslov.U, CHARINDEX(N'://', naslov.U) + 3, 4000)
            WHEN naslov.U LIKE N'//%' THEN SUBSTRING(naslov.U, 3, 4000)
            WHEN naslov.U LIKE N'www.%' THEN naslov.U
            ELSE N'' END) AS pot
        CROSS APPLY (SELECT Name = LEFT(pot.Rest, PATINDEX(N'%[/?#:]%', pot.Rest + N'/') - 1)) AS surovi
        CROSS APPLY (SELECT Host = CONVERT(nvarchar(200),
            CASE WHEN surovi.Name LIKE N'www.%' THEN SUBSTRING(surovi.Name, 5, 200) ELSE surovi.Name END)) AS gostitelj
""";

  /// <summary>
  /// Vsak vrstni red se konca z virom in sifro zapisa. Brez enolicnega konca SQL Server vrstic
  /// z enakim kljucem ne vrne vedno v istem zaporedju in ista slika bi se pojavila na dveh
  /// straneh, druga pa na nobeni.
  /// </summary>
  /// <remarks>
  /// Znotraj izdelka gredo slike (MEDIJ) pred dokumente in po svojem zaporedju — izracunane
  /// vrste tu namerno ni: v kljucu razvrscanja bi jo baza morala izracunati za vse zapise.
  /// </remarks>
  static string MediaOrderBy(string? sort) => sort switch
  {
    "STARI" => "CreatedUtc, ItemID, OrganizationId, Source DESC, SortOrder, Role, SourceId",
    "ARTIKEL" => "ItemID, OrganizationId, Source DESC, SortOrder, Role, SourceId",
    "ARTIKEL_DESC" => "ItemID DESC, OrganizationId, Source DESC, SortOrder, Role, SourceId",
    "VLOGA" => "Role, ItemID, OrganizationId, SortOrder, Source DESC, SourceId",
    "VRSTA" => "Kind, ItemID, OrganizationId, Source DESC, SortOrder, Role, SourceId",
    "NASLOV" => "Url, ItemID, OrganizationId, Source DESC, SourceId",
    // Privzeto: najnovejsi najprej. Brez casa (pred belezenjem) pade na konec.
    _ => "CreatedUtc DESC, ItemID, OrganizationId, Source DESC, SortOrder, Role, SourceId"
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

  static void BindMedia(SqlCommand command, MediaFilter filter, IReadOnlyList<string> terms, int skip, int take)
  {
    command.Parameters.Add("@OrganizationId", System.Data.SqlDbType.Int).Value =
      filter.OrganizationId is int organizationId ? organizationId : DBNull.Value;
    command.Parameters.AddWithValue("@Role", NullIfBlank(filter.Role));
    command.Parameters.AddWithValue("@AddressState", NullIfBlank(filter.AddressState));
    command.Parameters.AddWithValue("@Kind", NullIfBlank(filter.Kind));
    command.Parameters.AddWithValue("@Host", filter.Host == NoMediaHost ? string.Empty : NullIfBlank(filter.Host));
    command.Parameters.AddWithValue("@Activity", NullIfBlank(filter.Activity));
    command.Parameters.Add("@AddedSince", System.Data.SqlDbType.DateTime2).Value =
      filter.AddedDays is int days and > 0 ? DateTime.UtcNow.AddDays(-days) : DBNull.Value;
    command.Parameters.AddWithValue("@Skip", skip);
    command.Parameters.AddWithValue("@Take", take);
    // Stolpci se primerjajo kot LOWER(...) v binarni kolaciji, zato mora biti tudi vzorec v malih crkah.
    for (var index = 0; index < terms.Count; index++)
      command.Parameters.AddWithValue($"@Term{index}", "%" + LikeSafe(terms[index].ToLowerInvariant()) + "%");
  }

  static object NullIfBlank(string? value) => string.IsNullOrWhiteSpace(value) ? DBNull.Value : value.Trim();

  /// <summary>Vloge obeh virov v enem sifrantu — dokumenti nosijo vecino pomenljivih vlog.</summary>
  public Task<IReadOnlyList<PimOption>> GetMediaRolesAsync(int? organizationId, CancellationToken cancellationToken = default) =>
    database.QueryAsync($"""
      {MediaSource([])}
      SELECT Role, COUNT_BIG(*) AS RowCountValue FROM medij GROUP BY Role ORDER BY Role {Recompile};
      """,
      reader => new PimOption(PimDb.TextOrEmpty(reader, "Role"),
        $"{PimDb.TextOrEmpty(reader, "Role")} ({PimDb.Int64(reader, "RowCountValue"):N0})"),
      command => BindMedia(command, new MediaFilter(OrganizationId: organizationId), [], 0, 0), cancellationToken);

  /// <summary>Strezniki, s katerih prihajajo mediji, najpogostejsi najprej.</summary>
  public Task<IReadOnlyList<PimOption>> GetMediaHostsAsync(int? organizationId, CancellationToken cancellationToken = default) =>
    database.QueryAsync($"""
      {MediaSource([])}
      SELECT Host, COUNT_BIG(*) AS RowCountValue FROM medij GROUP BY Host ORDER BY COUNT_BIG(*) DESC, Host {Recompile};
      """,
      reader =>
      {
        var host = PimDb.TextOrEmpty(reader, "Host");
        var count = PimDb.Int64(reader, "RowCountValue");
        return host.Length == 0
          ? new PimOption(NoMediaHost, $"Brez strežnika ({count:N0})")
          : new PimOption(host, $"{host} ({count:N0})");
      },
      command => BindMedia(command, new MediaFilter(OrganizationId: organizationId), [], 0, 0), cancellationToken);

  public async Task<MediaSummary> GetMediaSummaryAsync(int? organizationId, CancellationToken cancellationToken = default)
  {
    var rows = await database.QueryAsync("""
      WITH izdelki AS (
        SELECT product.ProductId, product.IsActive
        FROM canon.Product product
        INNER JOIN dbo.OrganizationConfig organization
          ON organization.OrganizationId = product.OrganizationId AND organization.IsActive = 1
        WHERE (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
      )
      SELECT
        (SELECT COUNT_BIG(DISTINCT media.ProductId) FROM canon.ProductMedia media
         INNER JOIN izdelki ON izdelki.ProductId = media.ProductId) AS WithMedia,
        (SELECT COUNT_BIG(*) FROM izdelki
         WHERE izdelki.IsActive = 1
           AND NOT EXISTS (SELECT 1 FROM canon.ProductMedia media WHERE media.ProductId = izdelki.ProductId)) AS WithoutMedia,
        (SELECT COUNT_BIG(*) FROM canon.ProductMedia media INNER JOIN izdelki ON izdelki.ProductId = media.ProductId)
        + (SELECT COUNT_BIG(*) FROM canon.ProductDocument document INNER JOIN izdelki ON izdelki.ProductId = document.ProductId) AS TotalMedia,
        (SELECT COUNT_BIG(*) FROM canon.ProductMedia media INNER JOIN izdelki ON izdelki.ProductId = media.ProductId
         WHERE media.CreatedUtc >= @Since)
        + (SELECT COUNT_BIG(*) FROM canon.ProductDocument document INNER JOIN izdelki ON izdelki.ProductId = document.ProductId
           WHERE document.CreatedUtc >= @Since) AS AddedLastWeek;
      """,
      reader => new MediaSummary(PimDb.Int64(reader, "WithMedia"), PimDb.Int64(reader, "WithoutMedia"),
        PimDb.Int64(reader, "TotalMedia"), PimDb.Int64(reader, "AddedLastWeek")),
      command =>
      {
        command.Parameters.Add("@OrganizationId", System.Data.SqlDbType.Int).Value =
          organizationId is int id ? id : DBNull.Value;
        command.Parameters.Add("@Since", System.Data.SqlDbType.DateTime2).Value = DateTime.UtcNow.AddDays(-7);
      }, cancellationToken);
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

  /// <summary>
  /// Izdelki, ki jih je SAOP oznacil kot izlocene iz rezervacije zaloge (planiranje).
  /// Bere neposredno canon.ProductPlanning — polje se danes ne pretaka v canon.FieldValue.
  /// Arhivirani izdelki (IsActive = 0) se ne prikazejo — sprozilec/backfill migracije 190 jim
  /// zastavico ze pobrise, filter tu je samo se dodatna varovalka.
  /// </summary>
  /// <param name="organizationId">null pomeni vsa podjetja (isti vzorec kot StockReadService.GetOverviewAsync).</param>
  public Task<IReadOnlyList<ReservationExclusionRow>> GetReservationExclusionsAsync(
    int? organizationId, CancellationToken cancellationToken = default) =>
    database.QueryAsync("""
      SELECT product.OrganizationId, organization.Name AS OrganizationName, product.ItemID, text.Value AS Name, planning.UpdatedUtc
      FROM canon.ProductPlanning planning
      INNER JOIN canon.Product product ON product.ProductId = planning.ProductId
      INNER JOIN dbo.OrganizationConfig organization ON organization.OrganizationId = product.OrganizationId
      LEFT JOIN canon.ProductText text
        ON text.ProductId = product.ProductId AND text.TextType = N'TITLE_ERP' AND text.Lang = N'sl'
      WHERE (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
        AND planning.ExcludeQuantityReservation = 1 AND product.IsActive = 1
      ORDER BY organization.Name, product.ItemID;
      """,
      reader => new ReservationExclusionRow(
        PimDb.Int32(reader, "OrganizationId"), PimDb.TextOrEmpty(reader, "OrganizationName"), PimDb.TextOrEmpty(reader, "ItemID"),
        PimDb.Text(reader, "Name"), PimDb.DateTimeValue(reader, "UpdatedUtc")),
      command => command.Parameters.AddWithValue("@OrganizationId", organizationId is null ? DBNull.Value : organizationId.Value),
      cancellationToken);

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
