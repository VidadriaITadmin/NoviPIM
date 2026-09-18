using System.Text.RegularExpressions;
using Microsoft.Data.SqlClient;

namespace PIM.Intranet.Services;

public sealed record ManagedRoleRow(
  int RoleId,
  string RoleCode,
  string Name,
  string? Description,
  long UserCount,
  bool IsSystem,
  int PermissionCount);

/// <summary>Upravljanje vlog in njihovih dovoljenj. ADMIN je varovana sistemska vloga.</summary>
public sealed class RoleAdministrationService(IConfiguration configuration)
{
  static readonly Regex CodePattern = new("^[A-Z][A-Z0-9_]{2,49}$", RegexOptions.CultureInvariant);
  string ConnectionString => ConnectionStringResolver.Resolve(configuration) ?? throw new InvalidOperationException("Manjka ConnectionStrings:Pim.");

  public async Task<IReadOnlyList<ManagedRoleRow>> GetRolesAsync(CancellationToken cancellationToken = default)
  {
    var result = new List<ManagedRoleRow>();
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("""
      SELECT roleValue.RoleId, roleValue.RoleCode, roleValue.Name, roleValue.Description,
        (SELECT COUNT_BIG(*) FROM sec.LocalUserRole link WHERE link.RoleId = roleValue.RoleId) AS UserCount,
        roleValue.IsSystem,
        (SELECT COUNT(*) FROM sec.RolePermission permission WHERE permission.RoleId = roleValue.RoleId) AS PermissionCount
      FROM sec.Role roleValue
      ORDER BY CASE WHEN roleValue.RoleCode = N'ADMIN' THEN 0 WHEN roleValue.IsSystem = 1 THEN 1 ELSE 2 END,
        roleValue.Name, roleValue.RoleCode;
      """, connection);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    while (await reader.ReadAsync(cancellationToken))
      result.Add(new(reader.GetInt32(0), reader.GetString(1), reader.GetString(2), reader.IsDBNull(3) ? null : reader.GetString(3),
        reader.GetInt64(4), reader.GetBoolean(5), reader.GetInt32(6)));
    return result;
  }

  public async Task<IReadOnlySet<string>> GetPermissionKeysAsync(int roleId, CancellationToken cancellationToken = default)
  {
    var result = new HashSet<string>(StringComparer.Ordinal);
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("SELECT PermissionKey FROM sec.RolePermission WHERE RoleId = @RoleId;", connection);
    command.Parameters.AddWithValue("@RoleId", roleId);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    while (await reader.ReadAsync(cancellationToken)) result.Add(reader.GetString(0));
    return result;
  }

  public async Task<int> CreateRoleAsync(string roleCode, string name, string? description, CancellationToken cancellationToken = default)
  {
    var code = NormalizeCode(roleCode);
    var normalizedName = Required(name, "Ime vloge");
    var normalizedDescription = Optional(description, 400);

    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("""
      IF EXISTS (SELECT 1 FROM sec.Role WHERE RoleCode = @RoleCode)
        THROW 51227, N'Vloga s to kodo že obstaja.', 1;
      INSERT sec.Role (RoleCode, Name, Description, IsSystem)
      OUTPUT inserted.RoleId
      VALUES (@RoleCode, @Name, @Description, 0);
      """, connection);
    command.Parameters.AddWithValue("@RoleCode", code);
    command.Parameters.AddWithValue("@Name", normalizedName);
    command.Parameters.AddWithValue("@Description", (object?)normalizedDescription ?? DBNull.Value);
    return Convert.ToInt32(await command.ExecuteScalarAsync(cancellationToken));
  }

  public async Task UpdateRoleAsync(int roleId, string name, string? description, CancellationToken cancellationToken = default)
  {
    var normalizedName = Required(name, "Ime vloge");
    var normalizedDescription = Optional(description, 400);
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("""
      UPDATE sec.Role SET Name = @Name, Description = @Description WHERE RoleId = @RoleId;
      IF @@ROWCOUNT = 0 THROW 51227, N'Vloga ne obstaja.', 1;
      """, connection);
    command.Parameters.AddWithValue("@RoleId", roleId);
    command.Parameters.AddWithValue("@Name", normalizedName);
    command.Parameters.AddWithValue("@Description", (object?)normalizedDescription ?? DBNull.Value);
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  public async Task SavePermissionsAsync(int roleId, IReadOnlyCollection<string> permissionKeys, CancellationToken cancellationToken = default)
  {
    var keys = permissionKeys.Distinct(StringComparer.Ordinal).ToArray();
    if (keys.Any(key => !PimAccessCatalog.Keys.Contains(key)))
      throw new InvalidOperationException("Izbor vsebuje neznano stran ali zavihek.");

    foreach (var child in keys.Select(key => (Key: key, Parent: PimAccessCatalog.ParentOf(key))).Where(value => value.Parent is not null))
      if (!keys.Contains(child.Parent!, StringComparer.Ordinal))
        throw new InvalidOperationException("Podstran ne more biti dovoljena, če njena glavna stran ni vključena.");

    foreach (var pageKey in keys.Where(key => PimAccessCatalog.ParentOf(key) is null))
    {
      var children = PimAccessCatalog.ChildrenOf(pageKey);
      if (children.Count > 0 && !children.Any(child => keys.Contains(child.Key, StringComparer.Ordinal)))
        throw new InvalidOperationException($"Za stran »{PimAccessCatalog.All.First(item => item.Key == pageKey).Name}« izberi vsaj en zavihek ali podstran.");
    }

    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var transaction = await connection.BeginTransactionAsync(cancellationToken);
    try
    {
      await using (var check = new SqlCommand("SELECT RoleCode FROM sec.Role WHERE RoleId = @RoleId;", connection, (SqlTransaction)transaction))
      {
        check.Parameters.AddWithValue("@RoleId", roleId);
        var code = await check.ExecuteScalarAsync(cancellationToken) as string;
        if (code is null) throw new InvalidOperationException("Vloga ne obstaja.");
        if (code == PimRoles.Admin) throw new InvalidOperationException("Skrbnik ima vedno dostop do vseh strani.");
      }

      await using (var delete = new SqlCommand("DELETE FROM sec.RolePermission WHERE RoleId = @RoleId;", connection, (SqlTransaction)transaction))
      {
        delete.Parameters.AddWithValue("@RoleId", roleId);
        await delete.ExecuteNonQueryAsync(cancellationToken);
      }

      foreach (var key in keys)
      {
        await using var insert = new SqlCommand("INSERT sec.RolePermission (RoleId, PermissionKey) VALUES (@RoleId, @PermissionKey);", connection, (SqlTransaction)transaction);
        insert.Parameters.AddWithValue("@RoleId", roleId);
        insert.Parameters.AddWithValue("@PermissionKey", key);
        await insert.ExecuteNonQueryAsync(cancellationToken);
      }

      await transaction.CommitAsync(cancellationToken);
    }
    catch
    {
      await transaction.RollbackAsync(cancellationToken);
      throw;
    }
  }

  public async Task DeleteRoleAsync(int roleId, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("""
      IF EXISTS (SELECT 1 FROM sec.Role WHERE RoleId = @RoleId AND IsSystem = 1)
        THROW 51227, N'Sistemske vloge ni mogoče izbrisati.', 1;
      IF EXISTS (SELECT 1 FROM sec.LocalUserRole WHERE RoleId = @RoleId)
        THROW 51227, N'Vloga je še dodeljena uporabnikom. Najprej jim izberi drugo vlogo.', 1;
      DELETE FROM sec.Role WHERE RoleId = @RoleId;
      IF @@ROWCOUNT = 0 THROW 51227, N'Vloga ne obstaja.', 1;
      """, connection);
    command.Parameters.AddWithValue("@RoleId", roleId);
    await command.ExecuteNonQueryAsync(cancellationToken);
  }

  static string NormalizeCode(string? value)
  {
    var code = (value ?? "").Trim().ToUpperInvariant().Replace(' ', '_').Replace('-', '_');
    if (!CodePattern.IsMatch(code))
      throw new InvalidOperationException("Koda naj ima 3–50 znakov: velike črke, številke in podčrtaj; začne naj se s črko.");
    return code;
  }

  static string Required(string? value, string label)
  {
    var normalized = (value ?? "").Trim();
    if (normalized.Length == 0) throw new InvalidOperationException($"{label} je obvezno.");
    if (normalized.Length > 200) throw new InvalidOperationException($"{label} je predolgo.");
    return normalized;
  }

  static string? Optional(string? value, int maxLength)
  {
    var normalized = string.IsNullOrWhiteSpace(value) ? null : value.Trim();
    if (normalized?.Length > maxLength) throw new InvalidOperationException($"Opis ima lahko največ {maxLength} znakov.");
    return normalized;
  }
}

/// <summary>Hitro preverjanje vidnosti poti za prijavljenega uporabnika.</summary>
public sealed class RoleAccessService(IConfiguration configuration)
{
  string ConnectionString => ConnectionStringResolver.Resolve(configuration) ?? throw new InvalidOperationException("Manjka ConnectionStrings:Pim.");

  public async Task<IReadOnlySet<string>> GetAllowedKeysAsync(System.Security.Claims.ClaimsPrincipal user, CancellationToken cancellationToken = default)
  {
    if (user.IsInRole(PimRoles.Admin)) return PimAccessCatalog.Keys;
    var roles = user.Claims.Where(claim => claim.Type == System.Security.Claims.ClaimTypes.Role)
      .Select(claim => claim.Value).Distinct(StringComparer.Ordinal).ToArray();
    if (roles.Length == 0) return new HashSet<string>(StringComparer.Ordinal);

    var result = new HashSet<string>(StringComparer.Ordinal);
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    var parameters = roles.Select((_, index) => $"@Role{index}").ToArray();
    await using var command = new SqlCommand($"""
      SELECT DISTINCT permission.PermissionKey
      FROM sec.RolePermission permission
      INNER JOIN sec.Role roleValue ON roleValue.RoleId = permission.RoleId
      WHERE roleValue.RoleCode IN ({string.Join(", ", parameters)});
      """, connection);
    for (var index = 0; index < roles.Length; index++) command.Parameters.AddWithValue(parameters[index], roles[index]);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    while (await reader.ReadAsync(cancellationToken)) result.Add(reader.GetString(0));
    return result;
  }

  public async Task<bool> CanAccessAsync(System.Security.Claims.ClaimsPrincipal user, string permissionKey, CancellationToken cancellationToken = default)
  {
    if (user.IsInRole(PimRoles.Admin)) return true;
    if (!PimAccessCatalog.Keys.Contains(permissionKey)) return false;
    var allowed = await GetAllowedKeysAsync(user, cancellationToken);
    if (!allowed.Contains(permissionKey)) return false;
    var parent = PimAccessCatalog.ParentOf(permissionKey);
    return parent is null || allowed.Contains(parent);
  }
}
