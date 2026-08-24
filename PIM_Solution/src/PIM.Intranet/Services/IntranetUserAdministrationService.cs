using Microsoft.Data.SqlClient;

namespace PIM.Intranet.Services;

/// <param name="Email">
/// Naslov za opozorila. Napaka odhodne poti, ki je uporabnik pet minut ne potrdi, gre sem;
/// brez naslova ni komu pisati in stopnjevanje tiho odpade.
/// </param>
public sealed record IntranetUserRow(string UserName, string DisplayName, string AuthSource, string? DomainIdentity, bool IsEnabled, string Roles, string? Email);

public sealed class IntranetUserAdministrationService(IConfiguration configuration, ActiveDirectoryService activeDirectory)
{
  string ConnectionString => ConnectionStringResolver.Resolve(configuration) ?? throw new InvalidOperationException("Manjka ConnectionStrings:Pim.");

  public ActiveDirectoryLookupResult FindDomainUser(string identity) => activeDirectory.Lookup(identity);

  public async Task AddDomainUserAsync(string identity, string roleCode, CancellationToken cancellationToken = default)
  {
    var lookup = activeDirectory.Lookup(identity);
    if (!lookup.Success) throw new InvalidOperationException(lookup.Error);

    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("sec.CreateDomainUser", connection) { CommandType = System.Data.CommandType.StoredProcedure };
    command.Parameters.AddWithValue("@DomainIdentity", lookup.User!.DomainIdentity);
    command.Parameters.AddWithValue("@DisplayName", lookup.User.DisplayName);
    command.Parameters.AddWithValue("@RoleCode", roleCode);
    await command.ExecuteScalarAsync(cancellationToken);
  }

  public async Task<IReadOnlyList<IntranetUserRow>> GetUsersAsync(CancellationToken cancellationToken = default)
  {
    var users = new List<IntranetUserRow>();
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("""
      SELECT localUser.UserName, localUser.DisplayName, localUser.AuthSource, localUser.DomainIdentity, localUser.IsEnabled,
        STRING_AGG(roleValue.RoleCode, N', ') WITHIN GROUP (ORDER BY roleValue.RoleCode) AS Roles,
        localUser.Email
      FROM sec.LocalUser localUser
      LEFT JOIN sec.LocalUserRole userRole ON userRole.LocalUserId = localUser.LocalUserId
      LEFT JOIN sec.Role roleValue ON roleValue.RoleId = userRole.RoleId
      GROUP BY localUser.UserName, localUser.DisplayName, localUser.AuthSource, localUser.DomainIdentity, localUser.IsEnabled, localUser.Email
      ORDER BY localUser.UserName;
      """, connection);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    while (await reader.ReadAsync(cancellationToken))
    {
      users.Add(new(reader.GetString(0), reader.GetString(1), reader.GetString(2), reader.IsDBNull(3) ? null : reader.GetString(3), reader.GetBoolean(4), reader.IsDBNull(5) ? "—" : reader.GetString(5), reader.IsDBNull(6) ? null : reader.GetString(6)));
    }

    return users;
  }

  /// <summary>
  /// Zapise ali pobrise naslov za opozorila. Prazen naslov je dovoljen in pomeni, da uporabnik
  /// e-poste ne prejema; to je odlocitev, ne napaka, zato se ne zavrne.
  /// </summary>
  public async Task SetEmailAsync(string userName, string? email, CancellationToken cancellationToken = default)
  {
    var normalized = string.IsNullOrWhiteSpace(email) ? null : email.Trim();
    if (normalized is not null && (!normalized.Contains('@') || normalized.Length > 320))
      throw new InvalidOperationException("Naslov e-poste ni veljaven.");

    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand(
      "UPDATE sec.LocalUser SET Email = @Email WHERE UserName = @UserName;", connection);
    command.Parameters.AddWithValue("@Email", (object?)normalized ?? DBNull.Value);
    command.Parameters.AddWithValue("@UserName", userName);
    if (await command.ExecuteNonQueryAsync(cancellationToken) != 1)
      throw new InvalidOperationException("Uporabnika ni bilo mogoce najti.");
  }
}
