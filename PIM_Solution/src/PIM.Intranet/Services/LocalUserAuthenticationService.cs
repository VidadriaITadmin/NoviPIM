using Microsoft.Data.SqlClient;

namespace PIM.Intranet.Services;

public sealed record AuthenticatedLocalUser(string UserName, string DisplayName, IReadOnlyList<string> Roles);

public sealed class LocalUserAuthenticationService(IConfiguration configuration, ActiveDirectoryService activeDirectory)
{
  public async Task<AuthenticatedLocalUser?> AuthenticateAsync(string? userName, string? password, CancellationToken cancellationToken = default)
  {
    if (string.IsNullOrWhiteSpace(userName) || string.IsNullOrWhiteSpace(password)) return null;
    var connectionString = ConnectionStringResolver.Resolve(configuration);
    if (string.IsNullOrWhiteSpace(connectionString)) return null;

    await using var connection = new SqlConnection(connectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("""
      SELECT localUser.UserName, localUser.DisplayName, localUser.PasswordHash, localUser.AuthSource, localUser.DomainIdentity, roleValue.RoleCode
      FROM sec.LocalUser localUser
      LEFT JOIN sec.LocalUserRole userRole ON userRole.LocalUserId = localUser.LocalUserId
      LEFT JOIN sec.Role roleValue ON roleValue.RoleId = userRole.RoleId
      WHERE localUser.IsEnabled = 1
        AND ((localUser.AuthSource = N'LOCAL' AND localUser.UserName = @UserName)
          OR (localUser.AuthSource = N'DOMAIN' AND localUser.DomainIdentity = @DomainIdentity));
      """, connection);
    command.Parameters.AddWithValue("@UserName", userName.Trim());
    command.Parameters.AddWithValue("@DomainIdentity", (object?)ActiveDirectoryService.NormalizeIdentity(userName, configuration["ActiveDirectory:Domain"]?.Trim() ?? "AD") ?? DBNull.Value);

    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    string? resolvedUserName = null;
    string? displayName = null;
    string? passwordHash = null;
    string? authSource = null;
    string? domainIdentity = null;
    var roles = new List<string>();
    while (await reader.ReadAsync(cancellationToken))
    {
      resolvedUserName ??= reader.GetString(0);
      displayName ??= reader.GetString(1);
      passwordHash ??= reader.IsDBNull(2) ? null : reader.GetString(2);
      authSource ??= reader.GetString(3);
      domainIdentity ??= reader.IsDBNull(4) ? null : reader.GetString(4);
      if (!reader.IsDBNull(5)) roles.Add(reader.GetString(5));
    }

    if (resolvedUserName is null || displayName is null || authSource is null) return null;
    var authenticated = authSource == "DOMAIN"
      ? domainIdentity is not null && activeDirectory.Validate(domainIdentity, password)
      : passwordHash is not null && PasswordHasher.Verify(password, passwordHash);
    return authenticated ? new AuthenticatedLocalUser(resolvedUserName, displayName, roles) : null;
  }
}
