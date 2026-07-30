using Microsoft.Data.SqlClient;

namespace PIM.Intranet.Services;

public sealed record AuthenticatedLocalUser(string UserName, string DisplayName, IReadOnlyList<string> Roles);

public sealed class LocalUserAuthenticationService(IConfiguration configuration)
{
  public async Task<AuthenticatedLocalUser?> AuthenticateAsync(string? userName, string? password, CancellationToken cancellationToken = default)
  {
    if (string.IsNullOrWhiteSpace(userName) || string.IsNullOrWhiteSpace(password)) return null;
    var connectionString = configuration.GetConnectionString("Pim");
    if (string.IsNullOrWhiteSpace(connectionString)) return null;

    await using var connection = new SqlConnection(connectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("""
      SELECT localUser.UserName, localUser.DisplayName, localUser.PasswordHash, roleValue.RoleCode
      FROM sec.LocalUser localUser
      LEFT JOIN sec.LocalUserRole userRole ON userRole.LocalUserId = localUser.LocalUserId
      LEFT JOIN sec.Role roleValue ON roleValue.RoleId = userRole.RoleId
      WHERE localUser.UserName = @UserName AND localUser.IsEnabled = 1;
      """, connection);
    command.Parameters.AddWithValue("@UserName", userName.Trim());

    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    string? resolvedUserName = null;
    string? displayName = null;
    string? passwordHash = null;
    var roles = new List<string>();
    while (await reader.ReadAsync(cancellationToken))
    {
      resolvedUserName ??= reader.GetString(0);
      displayName ??= reader.GetString(1);
      passwordHash ??= reader.GetString(2);
      if (!reader.IsDBNull(3)) roles.Add(reader.GetString(3));
    }

    return resolvedUserName is not null && passwordHash is not null && PasswordHasher.Verify(password, passwordHash)
      ? new AuthenticatedLocalUser(resolvedUserName, displayName!, roles)
      : null;
  }
}
