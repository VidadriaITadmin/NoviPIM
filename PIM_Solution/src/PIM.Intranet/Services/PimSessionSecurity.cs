using System.Collections.Concurrent;
using System.Security.Claims;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.Data.SqlClient;

namespace PIM.Intranet.Services;

/// <summary>Zahtevki, ki jih PIM doda poleg standardnih.</summary>
public static class PimClaims
{
  /// <summary>Žig seje iz <c>sec.LocalUser.SecurityStamp</c> (migracija 181).</summary>
  public const string SecurityStamp = "pim:zig";
}

/// <param name="Roles">Vloge ob preverjanju; seja jih dobi tudi, če so se od prijave spremenile.</param>
public sealed record PimUserSecurityState(string UserName, string DisplayName, bool IsEnabled, Guid SecurityStamp, IReadOnlyList<string> Roles);

/// <summary>
/// Bere <c>sec.GetUserSecurityState</c>. Ločen od <see cref="LocalUserAuthenticationService"/>,
/// ker to ni prijava: piškotek že obstaja in vprašanje je samo, ali še sme veljati.
/// </summary>
public sealed class UserSecurityStateService(IConfiguration configuration)
{
  public async Task<PimUserSecurityState?> GetAsync(string userName, CancellationToken cancellationToken = default)
  {
    var connectionString = ConnectionStringResolver.Resolve(configuration);
    if (string.IsNullOrWhiteSpace(connectionString)) return null;

    await using var connection = new SqlConnection(connectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("sec.GetUserSecurityState", connection)
    {
      CommandType = System.Data.CommandType.StoredProcedure,
      CommandTimeout = 15,
    };
    command.Parameters.AddWithValue("@UserName", userName);
    await using var reader = await command.ExecuteReaderAsync(cancellationToken);
    if (!await reader.ReadAsync(cancellationToken)) return null;

    var roles = reader.GetString(reader.GetOrdinal("Roles"));
    return new(
      reader.GetString(reader.GetOrdinal("UserName")),
      reader.GetString(reader.GetOrdinal("DisplayName")),
      reader.GetBoolean(reader.GetOrdinal("IsEnabled")),
      reader.GetGuid(reader.GetOrdinal("SecurityStamp")),
      roles.Length == 0 ? [] : roles.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries));
  }
}

/// <summary>
/// Preverjanje piškotka ob zahtevi (ugotovitev A3, pregled 2026-09-08).
///
/// Brez tega je bil izklop računa zgolj priporočilo: <c>IsEnabled</c> in vloge so se prebrale
/// samo ob prijavi, piškotek pa je veljal še 14 dni. Dokaz pregleda je bil
/// <c>DISABLED_ACCOUNT_COOKIE {"Status":200,"Path":"/izdelki"}</c>.
///
/// Preverja se ob **vsaki** zahtevi, ki nosi piškotek. Prvi poskus je imel petminutni interval,
/// a je zahtevo »izklop računa velja takoj« zgrešil: dokaz A3 je bil narejen tako, da se račun
/// izklopi in se takoj zatem odpre stran. Poizvedba je ena vrstica po enoličnem ključu; statične
/// datoteke sem sploh ne pridejo, ker <c>UseStaticFiles</c> stoji pred <c>UseAuthentication</c>,
/// vezje Blazor Server pa se overi enkrat ob vzpostavitvi.
///
/// Ob neujemanju žiga, izbrisanem ali onemogočenem računu se seja zavrne; ob spremenjenih vlogah
/// se piškotek prepiše z novimi, da odvzeta vloga velja takoj in brez ponovne prijave.
/// </summary>
public static class PimSessionValidator
{
  public static async Task ValidateAsync(CookieValidatePrincipalContext context)
  {
    var principal = context.Principal;
    var userName = principal?.Identity?.Name;
    if (string.IsNullOrWhiteSpace(userName)) { await RejectAsync(context); return; }

    var services = context.HttpContext.RequestServices;
    if (services.GetService(typeof(UserSecurityStateService)) is not UserSecurityStateService lookup) return;

    PimUserSecurityState? state;
    try
    {
      state = await lookup.GetAsync(userName, context.HttpContext.RequestAborted);
    }
    catch (SqlException)
    {
      // Baza je trenutno nedosegljiva. Odjava vseh prijavljenih ob vsakem izpadu povezave bi
      // bila hujša od zamude: seja ostane, preverjanje se ponovi ob naslednjem intervalu.
      return;
    }

    if (state is null || !state.IsEnabled) { await RejectAsync(context); return; }

    var stampInCookie = principal!.FindFirst(PimClaims.SecurityStamp)?.Value;
    if (!Guid.TryParse(stampInCookie, out var cookieStamp) || cookieStamp != state.SecurityStamp)
    {
      await RejectAsync(context);
      return;
    }

    // Vloge se lahko spremenijo brez spremembe ziga samo takrat, ko piskotek nosi starejso
    // sliko; takrat ga prepisemo, sicer ga pustimo pri miru, da vsak odgovor ne nosi Set-Cookie.
    var currentRoles = principal.FindAll(ClaimTypes.Role).Select(claim => claim.Value).ToHashSet(StringComparer.Ordinal);
    if (currentRoles.SetEquals(state.Roles)) return;
    context.ReplacePrincipal(BuildPrincipal(state));
    context.ShouldRenew = true;
  }

  /// <summary>Piškotek prijavljenega uporabnika; ena sama pot, da se prijava in obnova ne razideta.</summary>
  public static ClaimsPrincipal BuildPrincipal(PimUserSecurityState state)
  {
    var claims = new List<Claim>
    {
      new(ClaimTypes.Name, state.UserName),
      new(ClaimTypes.GivenName, state.DisplayName),
      new(PimClaims.SecurityStamp, state.SecurityStamp.ToString()),
    };
    claims.AddRange(state.Roles.Select(role => new Claim(ClaimTypes.Role, role)));
    return new ClaimsPrincipal(new ClaimsIdentity(claims, CookieAuthenticationDefaults.AuthenticationScheme));
  }

  static async Task RejectAsync(CookieValidatePrincipalContext context)
  {
    context.RejectPrincipal();
    await context.HttpContext.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme);
  }
}

/// <summary>
/// Omejitev neuspelih prijav (ugotovitev A3, drugi del: <c>grep -ri 'Lockout|RateLimit|
/// FailedAttempts'</c> v intranetu ni našel ničesar).
///
/// Šteje samo **neuspele** poskuse na par uporabniško ime + naslov, ker vsaka uspešna prijava
/// števec počisti; človek, ki se prijavi pravilno, tako nikoli ne trči ob mejo. Hramba je v
/// pomnilniku procesa in namenoma ne v bazi: gre za varovalko pred ugibanjem gesla v eni
/// namestitvi, ne za revizijsko sled.
/// </summary>
public sealed class PimLoginThrottle
{
  public const int MaxFailures = 10;
  public static readonly TimeSpan Window = TimeSpan.FromMinutes(15);

  readonly ConcurrentDictionary<string, (int Failures, DateTime WindowStartUtc)> attempts = new(StringComparer.OrdinalIgnoreCase);

  static string Key(string? userName, string? remoteAddress) =>
    (userName ?? "").Trim().ToLowerInvariant() + "|" + (remoteAddress ?? "neznan");

  /// <summary>Koliko časa je še blokirano; <c>null</c> pomeni, da poskus sme naprej.</summary>
  public TimeSpan? RetryAfter(string? userName, string? remoteAddress)
  {
    if (!attempts.TryGetValue(Key(userName, remoteAddress), out var entry)) return null;
    var elapsed = DateTime.UtcNow - entry.WindowStartUtc;
    if (elapsed >= Window || entry.Failures < MaxFailures) return null;
    return Window - elapsed;
  }

  public void RegisterFailure(string? userName, string? remoteAddress)
  {
    var key = Key(userName, remoteAddress);
    attempts.AddOrUpdate(key,
      _ => (1, DateTime.UtcNow),
      (_, entry) => DateTime.UtcNow - entry.WindowStartUtc >= Window
        ? (1, DateTime.UtcNow)
        : (entry.Failures + 1, entry.WindowStartUtc));
  }

  public void RegisterSuccess(string? userName, string? remoteAddress) => attempts.TryRemove(Key(userName, remoteAddress), out _);
}

/// <summary>
/// Imena in meje omejevalnika zahtev. Zunanji obroč pred <see cref="PimLoginThrottle"/>: ta šteje
/// vse zahteve na prijavno pot z enega naslova, ne glede na uporabniško ime, in ustavi poplavo.
/// </summary>
public static class PimRateLimits
{
  public const string Login = "prijava";

  /// <summary>Zgornja meja zahtev na prijavno pot z enega naslova v enem oknu.</summary>
  public const int LoginRequestsPerWindow = 30;

  public static readonly TimeSpan Window = TimeSpan.FromMinutes(15);
}
