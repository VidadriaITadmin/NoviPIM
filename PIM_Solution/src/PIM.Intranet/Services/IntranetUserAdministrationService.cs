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
  /// Nov lokalni racun. Geslo se zgosti tu in v bazo gre samo zgoscena vrednost — procedura
  /// sprejme <c>@PasswordHash</c>, ne gesla, zato cistopis nikoli ne zapusti tega procesa.
  /// </summary>
  public async Task CreateLocalUserAsync(string userName, string displayName, string password, string roleCode, string? email, CancellationToken cancellationToken = default)
  {
    ValidatePassword(password);
    var normalizedUser = (userName ?? "").Trim();
    var normalizedName = (displayName ?? "").Trim();
    if (normalizedUser.Length == 0 || normalizedName.Length == 0)
      throw new InvalidOperationException("Uporabniško ime in ime sta obvezna.");

    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using (var command = new SqlCommand("sec.CreateLocalUser", connection) { CommandType = System.Data.CommandType.StoredProcedure })
    {
      command.Parameters.AddWithValue("@UserName", normalizedUser);
      command.Parameters.AddWithValue("@DisplayName", normalizedName);
      command.Parameters.AddWithValue("@PasswordHash", PasswordHasher.Hash(password));
      command.Parameters.AddWithValue("@RoleCode", roleCode);
      await command.ExecuteNonQueryAsync(cancellationToken);
    }

    if (!string.IsNullOrWhiteSpace(email)) await SetEmailAsync(normalizedUser, email, cancellationToken);
  }

  /// <summary>
  /// Novo geslo lokalnega racuna. Domenskih gesel PIM ne hrani in jih zato ne more spremeniti —
  /// prijava takega uporabnika gre v Active Directory in tam tudi ostane.
  /// </summary>
  public async Task ResetPasswordAsync(string userName, string password, CancellationToken cancellationToken = default)
  {
    ValidatePassword(password);

    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("""
      UPDATE sec.LocalUser SET PasswordHash = @PasswordHash
      WHERE UserName = @UserName AND AuthSource = N'LOCAL';
      """, connection);
    command.Parameters.AddWithValue("@PasswordHash", PasswordHasher.Hash(password));
    command.Parameters.AddWithValue("@UserName", userName);
    if (await command.ExecuteNonQueryAsync(cancellationToken) != 1)
      throw new InvalidOperationException("Geslo je mogoče spremeniti samo lokalnemu uporabniku.");
  }

  /// <summary>Prikazno ime; velja za lokalne in domenske racune, ker je nase in ne AD-jevo.</summary>
  public async Task SetDisplayNameAsync(string userName, string displayName, CancellationToken cancellationToken = default)
  {
    var normalized = (displayName ?? "").Trim();
    if (normalized.Length == 0) throw new InvalidOperationException("Ime ne sme biti prazno.");

    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand(
      "UPDATE sec.LocalUser SET DisplayName = @DisplayName WHERE UserName = @UserName;", connection);
    command.Parameters.AddWithValue("@DisplayName", normalized);
    command.Parameters.AddWithValue("@UserName", userName);
    if (await command.ExecuteNonQueryAsync(cancellationToken) != 1)
      throw new InvalidOperationException("Uporabnika ni bilo mogoče najti.");
  }

  /// <summary>
  /// Vklop ali izklop racuna. Racunov ne brisemo: uporabnik je podpisan pod spremembami v
  /// zgodovini in pod odobritvami odhodne poti, zato mora ostati berljiv tudi potem, ko odide.
  /// </summary>
  public async Task SetEnabledAsync(string userName, bool enabled, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand(
      "UPDATE sec.LocalUser SET IsEnabled = @IsEnabled WHERE UserName = @UserName;", connection);
    command.Parameters.AddWithValue("@IsEnabled", enabled);
    command.Parameters.AddWithValue("@UserName", userName);
    if (await command.ExecuteNonQueryAsync(cancellationToken) != 1)
      throw new InvalidOperationException("Uporabnika ni bilo mogoče najti.");
  }

  /// <summary>
  /// Najmanjsa zahteva za geslo. Namenoma kratka in razumljiva: dolzina je edina lastnost, ki
  /// zanesljivo dela razliko, zapleteno pravilo pa ljudi prisili v zapisovanje na listek.
  /// </summary>
  static void ValidatePassword(string password)
  {
    if (string.IsNullOrWhiteSpace(password) || password.Trim().Length < 10)
      throw new InvalidOperationException("Geslo mora imeti vsaj 10 znakov.");
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
