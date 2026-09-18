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

  /// <summary>
  /// Kdaj je bil racun nazadnje viden (migracija 224); null, ce se nikoli ali ne obstaja. Namenoma
  /// locena poizvedba od <see cref="GetAsync"/> zgoraj — tista ob vsakem klicu "zadnjic viden"
  /// prepise na zdaj, tu pa gre za prijavo, ki mora prebrati vrednost izpred TEGA poskusa.
  /// </summary>
  public async Task<DateTime?> GetLastSeenUtcAsync(string userName, CancellationToken cancellationToken = default)
  {
    var connectionString = ConnectionStringResolver.Resolve(configuration);
    if (string.IsNullOrWhiteSpace(connectionString)) return null;

    await using var connection = new SqlConnection(connectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("sec.GetUserPresence", connection)
    {
      CommandType = System.Data.CommandType.StoredProcedure,
      CommandTimeout = 15,
    };
    command.Parameters.AddWithValue("@UserName", userName);
    var result = await command.ExecuteScalarAsync(cancellationToken);
    return result is DateTime lastSeen ? lastSeen : null;
  }

  /// <summary>
  /// Prevzem seje (migracija 224): nov zig prekine vse obstojece seje tega uporabnika, ker jih
  /// <see cref="PimSessionValidator"/> ob njihovi naslednji zahtevi zavrne. Vrne novi zig, da ga
  /// klicatelj takoj vpise v piskotek nove seje — stari <c>AuthenticatedLocalUser.SecurityStamp</c>
  /// bi po tem klicu ze bil neveljaven.
  /// </summary>
  public async Task<Guid> ForceSignOutAsync(string userName, CancellationToken cancellationToken = default)
  {
    var connectionString = ConnectionStringResolver.Resolve(configuration);
    if (string.IsNullOrWhiteSpace(connectionString)) throw new InvalidOperationException("Manjka ConnectionStrings:Pim.");

    await using var connection = new SqlConnection(connectionString);
    await connection.OpenAsync(cancellationToken);
    await using var command = new SqlCommand("sec.ForceSignOutUser", connection)
    {
      CommandType = System.Data.CommandType.StoredProcedure,
      CommandTimeout = 15,
    };
    command.Parameters.AddWithValue("@UserName", userName);
    var result = await command.ExecuteScalarAsync(cancellationToken);
    return result is Guid newStamp ? newStamp : throw new InvalidOperationException("Prevzem seje ni uspel.");
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

    if (state is null || !state.IsEnabled) { await RejectAsync(context, "onemogocen"); return; }

    var stampInCookie = principal!.FindFirst(PimClaims.SecurityStamp)?.Value;
    if (!Guid.TryParse(stampInCookie, out var cookieStamp) || cookieStamp != state.SecurityStamp)
    {
      // Zig se ne ujema: nekdo drug se je prijavil s tem racunom (224) ali so se vloge/geslo
      // spremenili (181). Locenega vzroka za ti dve vejici ne poznamo, a obe sta "seja",
      // ne "racun izklopljen" — /prijava zato pokaze splosno, a razumljivo sporocilo.
      await RejectAsync(context, "seja");
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

  /// <summary>
  /// <paramref name="reason"/> potuje naprej do <c>OnRedirectToLogin</c> (Program.cs) prek
  /// <see cref="HttpContext.Items"/> — edini prostor, ki prezivi od tega preverjanja piskotka do
  /// izziva za avtorizacijo znotraj iste zahteve. Prazen "razlog" pomeni "ni bilo seje", ne napako.
  /// </summary>
  static async Task RejectAsync(CookieValidatePrincipalContext context, string? reason = null)
  {
    if (reason is not null) context.HttpContext.Items["pim:razlogOdjave"] = reason;
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
/// Kratkozivi zeton za prevzem seje na strani prijave (migracija 224, A3-slog: ista logika kot
/// SecurityStamp, samo za en drug sprozilec — "nekdo drug se prijavlja s tem racunom", ne
/// "vloga se je spremenila"). Prvi POST na /auth/prijava preveri geslo in ob ze aktivnem racunu
/// namesto piskotka vrne ta zeton; drugi POST (po potrditvi "Da, prevzemi") ga porabi. Geslo se
/// med tema koraki namenoma ne prenasa nazaj v obrazec — ostalo bi v HTML-ju in dnevnikih. Zeton
/// sam je dovolj: je nakljucen (Guid), enkraten, kratek (2 min) in vezan na eno uporabnisko ime,
/// torej dokazuje "to geslo je bilo pravkar preverjeno" brez ponovnega vnosa.
/// </summary>
public sealed class PimLoginTakeover
{
  public static readonly TimeSpan ActiveWindow = TimeSpan.FromMinutes(3);
  static readonly TimeSpan TokenLifetime = TimeSpan.FromMinutes(2);

  readonly ConcurrentDictionary<Guid, (string UserName, bool RememberMe, DateTime ExpiresUtc)> pending = new();

  public Guid Issue(string userName, bool rememberMe)
  {
    var token = Guid.NewGuid();
    pending[token] = (userName, rememberMe, DateTime.UtcNow + TokenLifetime);
    return token;
  }

  /// <summary>Porabi zeton (enkraten); null, ce ne obstaja ali je potekel.</summary>
  public (string UserName, bool RememberMe)? Consume(Guid token)
  {
    if (!pending.TryRemove(token, out var entry) || entry.ExpiresUtc < DateTime.UtcNow) return null;
    return (entry.UserName, entry.RememberMe);
  }
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
