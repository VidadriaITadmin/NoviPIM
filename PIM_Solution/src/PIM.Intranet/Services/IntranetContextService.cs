using Microsoft.Data.SqlClient;

namespace PIM.Intranet.Services;

public sealed record OrganizationOption(int OrganizationId, string Name);
public sealed record ChannelOption(string WebSiteCode, string WebSiteName, string LanguageCode);
public sealed record LanguageOption(string LanguageCode, string Name);

/// <param name="Organization">Izbrana organizacija; nikoli null, kadar je vsaj ena aktivna.</param>
/// <param name="Channel">Izbran spletni kanal ali null, kadar registriranega kanala ni.</param>
/// <param name="Language">Izbran jezik ali null, kadar sifrant jezikov se ni napolnjen.</param>
public sealed record IntranetContext(
  OrganizationOption? Organization,
  ChannelOption? Channel,
  LanguageOption? Language,
  IReadOnlyList<OrganizationOption> Organizations,
  IReadOnlyList<ChannelOption> Channels,
  IReadOnlyList<LanguageOption> Languages);

/// <summary>
/// Delovni kontekst zgornje vrstice: katera organizacija, kateri spletni kanal in kateri jezik
/// uporabnik trenutno gleda.
///
/// Zakaj piskotek in ne stanje komponente: strani so staticni SSR (interaktiven je samo
/// posamezen otok), zato med zahtevkoma ni zivega vezja, ki bi izbiro drzalo. Piskotek prezivi
/// tudi popolno osvezitev in delo v vec zavihkih, kar je pri vec podjetjih dejanski nacin dela.
///
/// Izbira, ki je v bazi ni (na primer organizacija, ki je bila deaktivirana), se tiho zavrze in
/// nadomesti s prvo veljavno; nikoli ne prikazemo konteksta, ki ga baza ne pozna.
/// </summary>
public sealed class IntranetContextService(IConfiguration configuration, IHttpContextAccessor httpContextAccessor)
{
  public const string OrganizationCookie = "pim_organizacija";
  public const string ChannelCookie = "pim_kanal";
  public const string LanguageCookie = "pim_jezik";

  string ConnectionString => ConnectionStringResolver.Resolve(configuration)
    ?? throw new InvalidOperationException("Povezava PIM ni nastavljena.");

  public async Task<IntranetContext> GetAsync(CancellationToken cancellationToken = default)
  {
    var organizations = new List<OrganizationOption>();
    var channels = new List<ChannelOption>();
    var languages = new List<LanguageOption>();

    await using (var connection = new SqlConnection(ConnectionString))
    {
      await connection.OpenAsync(cancellationToken);

      await using (var command = new SqlCommand(
        "SELECT OrganizationId, Name FROM dbo.OrganizationConfig WHERE IsActive = 1 ORDER BY OrganizationId;", connection))
      await using (var reader = await command.ExecuteReaderAsync(cancellationToken))
        while (await reader.ReadAsync(cancellationToken))
          organizations.Add(new(reader.GetInt32(reader.GetOrdinal("OrganizationId")), reader.GetString(reader.GetOrdinal("Name"))));

      await using (var command = new SqlCommand(
        "SELECT WebSiteCode, WebSiteName, LanguageCode FROM canon.WebSite WHERE IsActive = 1 ORDER BY SortOrder, WebSiteCode;", connection))
      await using (var reader = await command.ExecuteReaderAsync(cancellationToken))
        while (await reader.ReadAsync(cancellationToken))
          channels.Add(new(
            reader.GetString(reader.GetOrdinal("WebSiteCode")),
            reader.GetString(reader.GetOrdinal("WebSiteName")),
            reader.GetString(reader.GetOrdinal("LanguageCode"))));

      // Sifrant jezikov je po organizacijah; za izbirnik jezika vmesnika steje unija kod.
      await using (var command = new SqlCommand(
        "SELECT LanguageCode, MIN(Name) AS Name FROM canon.Language WHERE IsActive = 1 GROUP BY LanguageCode ORDER BY LanguageCode;", connection))
      await using (var reader = await command.ExecuteReaderAsync(cancellationToken))
        while (await reader.ReadAsync(cancellationToken))
          languages.Add(new(reader.GetString(reader.GetOrdinal("LanguageCode")), reader.GetString(reader.GetOrdinal("Name"))));
    }

    var organization = Pick(organizations, ReadCookie(OrganizationCookie), option => option.OrganizationId.ToString());
    var channel = Pick(channels, ReadCookie(ChannelCookie), option => option.WebSiteCode);
    var language = Pick(languages, ReadCookie(LanguageCookie), option => option.LanguageCode);

    return new(organization, channel, language, organizations, channels, languages);
  }

  /// <summary>
  /// Stevilo nerazresenih alarmov izbrane organizacije. Zvonec v glavi je prej kazal nic in bil
  /// onemogocen; ta vrednost je resnicna vrstica iz <c>ops.Alert</c>, ne okras.
  /// </summary>
  public async Task<int> GetOpenAlertCountAsync(int organizationId, CancellationToken cancellationToken = default)
  {
    await using var connection = new SqlConnection(ConnectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand(
      "SELECT COUNT_BIG(*) FROM ops.Alert WHERE OrganizationId = @OrganizationId AND ResolvedUtc IS NULL;", connection);
    command.Parameters.AddWithValue("@OrganizationId", organizationId);
    return Convert.ToInt32(await command.ExecuteScalarAsync(cancellationToken));
  }

  static T? Pick<T>(IReadOnlyList<T> options, string? selected, Func<T, string> key) where T : class
  {
    if (options.Count == 0) return null;
    if (selected is { Length: > 0 })
    {
      var match = options.FirstOrDefault(option => string.Equals(key(option), selected, StringComparison.OrdinalIgnoreCase));
      if (match is not null) return match;
    }

    return options[0];
  }

  string? ReadCookie(string name) =>
    httpContextAccessor.HttpContext?.Request.Cookies.TryGetValue(name, out var value) == true ? value : null;
}
