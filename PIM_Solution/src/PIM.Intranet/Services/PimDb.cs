using System.Data;
using Microsoft.Data.SqlClient;

namespace PIM.Intranet.Services;

/// <summary>
/// Tanek dostop do baze za bralne modele intraneta.
///
/// Zakaj obstaja: brez njega ima vsaka poizvedba petnajst vrstic enake priprave povezave,
/// ukaza in bralca. Stara aplikacija je imela to prepisano v devetindvajsetih delnih
/// datotekah in prav zato so se poizvedbe za isto stvar razsle.
///
/// Preslikava je vedno po <b>imenu</b> stolpca. Ordinalna preslikava se tiho pokvari, ko
/// poizvedbi dodamo stolpec, in tega ne opazi noben test.
/// </summary>
public sealed class PimDb(IConfiguration configuration)
{
  string ConnectionString => ConnectionStringResolver.Resolve(configuration)
    ?? throw new InvalidOperationException("Povezava PIM ni nastavljena.");

  public async Task<IReadOnlyList<T>> QueryAsync<T>(
    string sql,
    Func<SqlDataReader, T> map,
    Action<SqlCommand>? bind = null,
    CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand(sql, connection);
    bind?.Invoke(command);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var rows = new List<T>();
    while (await reader.ReadAsync(cancellationToken)) rows.Add(map(reader));
    return rows;
  }

  /// <summary>Dva rezultata iz enega obiska baze: seznam in njegovo skupno stevilo.</summary>
  public async Task<(IReadOnlyList<T> Rows, long TotalCount)> PageAsync<T>(
    string sql,
    Func<SqlDataReader, T> map,
    Action<SqlCommand>? bind = null,
    CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand(sql, connection);
    bind?.Invoke(command);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    var rows = new List<T>();
    while (await reader.ReadAsync(cancellationToken)) rows.Add(map(reader));
    long total = 0;
    if (await reader.NextResultAsync(cancellationToken) && await reader.ReadAsync(cancellationToken))
      total = Convert.ToInt64(reader.GetValue(0));
    return (rows, total);
  }

  public async Task<long> CountAsync(string sql, Action<SqlCommand>? bind = null, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand(sql, connection);
    bind?.Invoke(command);
    var value = await command.ExecuteScalarAsync(cancellationToken);
    return value is null or DBNull ? 0 : Convert.ToInt64(value);
  }

  public static string? Text(SqlDataReader reader, string column)
  {
    var ordinal = reader.GetOrdinal(column);
    return reader.IsDBNull(ordinal) ? null : reader.GetString(ordinal);
  }

  public static string TextOrEmpty(SqlDataReader reader, string column) => Text(reader, column) ?? string.Empty;

  public static int Int32(SqlDataReader reader, string column) => Convert.ToInt32(reader.GetValue(reader.GetOrdinal(column)));

  public static long Int64(SqlDataReader reader, string column) => Convert.ToInt64(reader.GetValue(reader.GetOrdinal(column)));

  public static long? NullableInt64(SqlDataReader reader, string column)
  {
    var ordinal = reader.GetOrdinal(column);
    return reader.IsDBNull(ordinal) ? null : Convert.ToInt64(reader.GetValue(ordinal));
  }

  public static decimal Decimal(SqlDataReader reader, string column) => Convert.ToDecimal(reader.GetValue(reader.GetOrdinal(column)));

  public static decimal? NullableDecimal(SqlDataReader reader, string column)
  {
    var ordinal = reader.GetOrdinal(column);
    return reader.IsDBNull(ordinal) ? null : Convert.ToDecimal(reader.GetValue(ordinal));
  }

  public static bool Bool(SqlDataReader reader, string column) => Convert.ToBoolean(reader.GetValue(reader.GetOrdinal(column)));

  public static DateTime DateTimeValue(SqlDataReader reader, string column) => reader.GetDateTime(reader.GetOrdinal(column));

  public static DateTime? NullableDateTime(SqlDataReader reader, string column)
  {
    var ordinal = reader.GetOrdinal(column);
    return reader.IsDBNull(ordinal) ? null : reader.GetDateTime(ordinal);
  }
}
