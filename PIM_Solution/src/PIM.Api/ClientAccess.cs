using System.Data;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Caching.Memory;

namespace PIM.Api;

/// <summary>Prijavljen odjemalec: katera podjetja in področja sme brati.</summary>
public sealed record ApiClient(int ClientId, string Name, int[]? OrganizationIds, IReadOnlySet<string> Scopes, int RequestsPerMinute)
{
  public bool HasScope(string scope) => scope.Length == 0 || Scopes.Contains(scope);
}

public sealed record Organization(int OrganizationId, string Name, bool IsActive);

/// <summary>
/// Ključi odjemalcev. V bazi je samo SHA-256 ključa (api.Client.KeyHash); čistopis vidi skrbnik enkrat,
/// ob ustvarjanju. Rezultat prijave je v pomnilniku <see cref="ApiSettings.AuthCacheSeconds"/> sekund, zato
/// preklic ključa začne veljati najkasneje po tem času (privzeto 60 s).
/// </summary>
public sealed class ClientAccess(ApiSettings settings, IMemoryCache cache)
{
  public const string KeyHeader = "X-Api-Key";

  public static byte[] Hash(string key) => SHA256.HashData(Encoding.UTF8.GetBytes(key.Trim()));

  /// <summary>Nov ključ: pim_ + 43 naključnih znakov (256 bitov).</summary>
  public static string NewKey()
  {
    const string alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    var chars = new char[43];
    for (var i = 0; i < chars.Length; i++) chars[i] = alphabet[RandomNumberGenerator.GetInt32(alphabet.Length)];
    return "pim_" + new string(chars);
  }

  public static string? ReadKey(HttpRequest request)
  {
    if (request.Headers.TryGetValue(KeyHeader, out var header) && !string.IsNullOrWhiteSpace(header)) return header.ToString().Trim();
    var authorization = request.Headers.Authorization.ToString();
    return authorization.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase) ? authorization[7..].Trim() : null;
  }

  public async Task<ApiClient?> AuthenticateAsync(string key, string? remoteIp, CancellationToken cancellationToken)
  {
    var hash = Hash(key);
    var cacheKey = "auth:" + Convert.ToHexString(hash);
    if (cache.TryGetValue(cacheKey, out ApiClient? cached)) return cached;

    ApiClient? client = null;
    await using (var connection = new SqlConnection(settings.ConnectionString))
    {
      await connection.OpenAsync(cancellationToken);
      await using var command = new SqlCommand("api.AuthenticateClient", connection) { CommandType = CommandType.StoredProcedure };
      command.Parameters.Add("@KeyHash", SqlDbType.Binary, 32).Value = hash;
      command.Parameters.Add("@RemoteIp", SqlDbType.NVarChar, 64).Value = (object?)remoteIp ?? DBNull.Value;
      await using var reader = await command.ExecuteReaderAsync(cancellationToken);
      if (await reader.ReadAsync(cancellationToken))
      {
        var organizations = reader.IsDBNull(2) ? null : reader.GetString(2)
          .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
          .Select(int.Parse).ToArray();
        var scopes = reader.GetString(3).Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
          .ToHashSet(StringComparer.OrdinalIgnoreCase);
        client = new ApiClient(reader.GetInt32(0), reader.GetString(1), organizations, scopes, reader.GetInt32(4));
      }
    }

    // Napačen ključ se hrani krajše, da popravljen ključ (npr. po ponovnem vpisu) hitro začne delovati.
    cache.Set(cacheKey, client, TimeSpan.FromSeconds(client is null ? Math.Min(10, settings.AuthCacheSeconds) : settings.AuthCacheSeconds));
    return client;
  }

  public async Task<IReadOnlyList<Organization>> OrganizationsAsync(CancellationToken cancellationToken)
  {
    return (await cache.GetOrCreateAsync("organizations", async entry =>
    {
      entry.AbsoluteExpirationRelativeToNow = TimeSpan.FromMinutes(5);
      var list = new List<Organization>();
      await using var connection = new SqlConnection(settings.ConnectionString);
      await connection.OpenAsync(cancellationToken);
      await using var command = new SqlCommand("api.GetOrganizations", connection) { CommandType = CommandType.StoredProcedure };
      await using var reader = await command.ExecuteReaderAsync(cancellationToken);
      while (await reader.ReadAsync(cancellationToken))
        list.Add(new Organization(reader.GetInt32(0), reader.GetString(1), reader.GetBoolean(2)));
      return list;
    }))!;
  }

  /// <summary>Podjetja, ki jih odjemalec sme brati: njegov seznam ali (brez seznama) vsa aktivna.</summary>
  public async Task<int[]> AllowedOrganizationsAsync(ApiClient client, CancellationToken cancellationToken)
  {
    var organizations = await OrganizationsAsync(cancellationToken);
    return client.OrganizationIds is { } ids
      ? organizations.Where(o => ids.Contains(o.OrganizationId)).Select(o => o.OrganizationId).ToArray()
      : organizations.Where(o => o.IsActive).Select(o => o.OrganizationId).ToArray();
  }

  public async Task LogAsync(int? clientId, DateTime requestUtc, string method, string path, string? query, int? organizationId,
    int statusCode, int durationMs, int? rows, string? remoteIp)
  {
    await using var connection = new SqlConnection(settings.ConnectionString);
    await connection.OpenAsync();
    await using var command = new SqlCommand("api.LogRequest", connection) { CommandType = CommandType.StoredProcedure };
    command.Parameters.AddWithValue("@ClientId", (object?)clientId ?? DBNull.Value);
    command.Parameters.Add("@RequestUtc", SqlDbType.DateTime2).Value = requestUtc;
    command.Parameters.AddWithValue("@Method", method);
    command.Parameters.AddWithValue("@Path", path);
    command.Parameters.AddWithValue("@QueryString", (object?)query ?? DBNull.Value);
    command.Parameters.AddWithValue("@OrganizationId", (object?)organizationId ?? DBNull.Value);
    command.Parameters.AddWithValue("@StatusCode", statusCode);
    command.Parameters.AddWithValue("@DurationMs", durationMs);
    command.Parameters.AddWithValue("@RowsReturned", (object?)rows ?? DBNull.Value);
    command.Parameters.AddWithValue("@RemoteIp", (object?)remoteIp ?? DBNull.Value);
    await command.ExecuteNonQueryAsync();
  }
}
