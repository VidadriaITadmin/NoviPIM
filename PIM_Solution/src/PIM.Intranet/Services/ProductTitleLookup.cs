using System.Data;
using System.Text.Json;
using Microsoft.Data.SqlClient;

namespace PIM.Intranet.Services;

/// <summary>
/// Oba slovenska naziva artikla: spletni (canon.ProductText WEB_TITLE, sl) in naziv iz SAOP
/// (canon.ProductText TITLE_ERP, sl). null = artikel ga nima — brez skritega nadomeščanja z drugim.
/// </summary>
public sealed record ProductTitles(string? WebTitle, string? ErpTitle)
{
  public static readonly ProductTitles None = new(null, null);
}

/// <summary>
/// #99: izvozi zaloge, analitike, napak kakovosti in neskladij imajo, kot ceniki (#62), dva ločena
/// stolpca »Spletni naziv (sl)« in »Naziv ERP (sl)«. Namesto da bi vsaka procedura (GetStockByItem,
/// GetQualityIssues, ana.ItemMetric, GetOrganizationMismatches) dobila nova stolpca, izvoz po branju
/// vrstic prebere oba naziva za vse artikle naenkrat: ena poizvedba na paket (OPENJSON + iskanje po
/// UQ_CanonProductText_ProductLangType), nikoli poizvedba na vrstico. Zaslon ostane nespremenjen.
/// </summary>
public static class ProductTitleLookup
{
  /// <summary>Velikost paketa ključev v eni poizvedbi (parametri JSON ostanejo majhni, načrt stabilen).</summary>
  const int BatchSize = 20_000;

  public const string WebHeader = "Spletni naziv (sl)";
  public const string ErpHeader = "Naziv ERP (sl)";

  const string ByProductIdSql = """
    SELECT ids.ProductId,
      WebTitle = MAX(CASE WHEN textValue.TextType = N'WEB_TITLE' THEN NULLIF(textValue.Value, N'') END),
      ErpTitle = MAX(CASE WHEN textValue.TextType = N'TITLE_ERP' THEN NULLIF(textValue.Value, N'') END)
    FROM (SELECT DISTINCT ProductId = TRY_CONVERT(bigint, value) FROM OPENJSON(@Ids)) AS ids
    INNER JOIN canon.ProductText AS textValue
      ON textValue.ProductId = ids.ProductId AND textValue.Lang = N'sl' AND textValue.TextType IN (N'WEB_TITLE', N'TITLE_ERP')
    GROUP BY ids.ProductId
    OPTION (RECOMPILE);
    """;

  const string ByItemSql = """
    SELECT keys_.OrganizationId, ItemId = keys_.ItemId,
      WebTitle = MAX(CASE WHEN textValue.TextType = N'WEB_TITLE' THEN NULLIF(textValue.Value, N'') END),
      ErpTitle = MAX(CASE WHEN textValue.TextType = N'TITLE_ERP' THEN NULLIF(textValue.Value, N'') END)
    FROM (SELECT DISTINCT OrganizationId, ItemId
          FROM OPENJSON(@Keys) WITH (OrganizationId int '$.o', ItemId nvarchar(200) '$.i')) AS keys_
    INNER JOIN canon.Product AS product
      ON product.OrganizationId = keys_.OrganizationId AND product.ItemID = keys_.ItemId COLLATE DATABASE_DEFAULT
    INNER JOIN canon.ProductText AS textValue
      ON textValue.ProductId = product.ProductId AND textValue.Lang = N'sl' AND textValue.TextType IN (N'WEB_TITLE', N'TITLE_ERP')
    GROUP BY keys_.OrganizationId, keys_.ItemId
    OPTION (RECOMPILE);
    """;

  /// <summary>Nazivi po ProductId (canon.Product). Manjkajoč ključ v slovarju = artikel nima nobenega naziva.</summary>
  public static async Task<IReadOnlyDictionary<long, ProductTitles>> ByProductIdAsync(
    string connectionString, IEnumerable<long> productIds, CancellationToken cancellationToken = default)
  {
    var result = new Dictionary<long, ProductTitles>();
    var ids = productIds.Distinct().ToArray();
    if (ids.Length == 0) return result;

    await using var connection = new SqlConnection(connectionString);
    await connection.OpenAsync(cancellationToken);
    foreach (var batch in ids.Chunk(BatchSize))
    {
      await using var command = new SqlCommand(ByProductIdSql, connection) { CommandTimeout = 120 };
      command.Parameters.Add("@Ids", SqlDbType.NVarChar, -1).Value = JsonSerializer.Serialize(batch);
      await using var reader = await command.ExecuteReaderAsync(cancellationToken);
      while (await reader.ReadAsync(cancellationToken))
        result[reader.GetInt64(0)] = new(Text(reader, 1), Text(reader, 2));
    }
    return result;
  }

  /// <summary>
  /// Nazivi po (podjetje, šifra) — za poglede, ki ne nosijo ProductId (neskladja med podjetji).
  /// Primerjava šifre je po pravilih baze (enako kot UQ_CanonProduct_OrganizationItem).
  /// </summary>
  public static async Task<IReadOnlyDictionary<(int OrganizationId, string ItemId), ProductTitles>> ByItemAsync(
    string connectionString, IEnumerable<(int OrganizationId, string ItemId)> keys, CancellationToken cancellationToken = default)
  {
    var result = new Dictionary<(int, string), ProductTitles>(ItemKeyComparer.Instance);
    var distinct = keys.Where(key => !string.IsNullOrWhiteSpace(key.ItemId)).Distinct(ItemKeyComparer.Instance).ToArray();
    if (distinct.Length == 0) return result;

    await using var connection = new SqlConnection(connectionString);
    await connection.OpenAsync(cancellationToken);
    foreach (var batch in distinct.Chunk(BatchSize))
    {
      await using var command = new SqlCommand(ByItemSql, connection) { CommandTimeout = 120 };
      command.Parameters.Add("@Keys", SqlDbType.NVarChar, -1).Value =
        JsonSerializer.Serialize(batch.Select(key => new { o = key.OrganizationId, i = key.ItemId }));
      await using var reader = await command.ExecuteReaderAsync(cancellationToken);
      while (await reader.ReadAsync(cancellationToken))
        result[(reader.GetInt32(0), reader.GetString(1))] = new(Text(reader, 2), Text(reader, 3));
    }
    return result;
  }

  public static ProductTitles Find(IReadOnlyDictionary<long, ProductTitles> titles, long? productId) =>
    productId is { } id && titles.TryGetValue(id, out var found) ? found : ProductTitles.None;

  static string? Text(SqlDataReader reader, int ordinal) => reader.IsDBNull(ordinal) ? null : reader.GetString(ordinal);

  /// <summary>Šifre primerja brez razlike v veliki/mali črki, kot privzeta kolacija baze.</summary>
  sealed class ItemKeyComparer : IEqualityComparer<(int OrganizationId, string ItemId)>
  {
    public static readonly ItemKeyComparer Instance = new();
    public bool Equals((int OrganizationId, string ItemId) x, (int OrganizationId, string ItemId) y) =>
      x.OrganizationId == y.OrganizationId && string.Equals(x.ItemId, y.ItemId, StringComparison.OrdinalIgnoreCase);
    public int GetHashCode((int OrganizationId, string ItemId) key) =>
      HashCode.Combine(key.OrganizationId, StringComparer.OrdinalIgnoreCase.GetHashCode(key.ItemId));
  }
}
