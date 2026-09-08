using System.Security.Claims;
using Microsoft.AspNetCore.Components.Authorization;

namespace PIM.Intranet.Services;

/// <summary>
/// Avtorizacijske politike zapisovalnih poti. Ena politika = ena poslovna pravica, ne ena stran.
///
/// Zakaj obstaja: pregled 2026-09-08 (ugotovitvi A1 in A4) je pokazal, da je bila vloga
/// preverjena samo z <c>[Authorize]</c> na strani, urejivost polj pa se je odlocala po vrsti
/// polja. Bralna vloga <c>VIEWER</c> je zato na kartici izdelka dobila 14 urejivih polj in gumb
/// »Shrani spremembe«, strezniska pot zapisa pa vloge sploh ni pogledala. Stran je videz;
/// meja je servis.
/// </summary>
public static class PimPolicies
{
  /// <summary>Urejanje kataloga: besedila, lastnosti, kategorije in povezave izdelkov.</summary>
  public const string CatalogWrite = "CatalogWrite";

  /// <summary>Uvrscanje sprememb v odhodno vrsto za SAOP in ponovno posiljanje.</summary>
  public const string SaopWrite = "SaopWrite";

  /// <summary>Komercialni zapisi: uvoz delovnega lista, pravila in pragovi.</summary>
  public const string BusinessWrite = "BusinessWrite";

  /// <summary>Potrjevanje in resevanje alarmov.</summary>
  public const string AlertWrite = "AlertWrite";

  static readonly Dictionary<string, string[]> PolicyRoles = new(StringComparer.Ordinal)
  {
    [CatalogWrite] = [PimRoles.Admin, PimRoles.CatalogEditor],
    [SaopWrite] = [PimRoles.Admin, PimRoles.CatalogEditor],
    [BusinessWrite] = [PimRoles.Admin, PimRoles.CatalogEditor, PimRoles.Commercial],
    [AlertWrite] = [PimRoles.Admin, PimRoles.Commercial],
  };

  public static IReadOnlyCollection<string> Names => PolicyRoles.Keys;

  /// <summary>Vloge, ki politiko izpolnjujejo. Neznano ime je napaka v kodi, ne prazna pravica.</summary>
  public static string[] RolesFor(string policy) =>
    PolicyRoles.TryGetValue(policy, out var roles)
      ? roles
      : throw new ArgumentOutOfRangeException(nameof(policy), policy, "Neznana avtorizacijska politika.");

  /// <summary>Ali dani uporabnik izpolnjuje politiko.</summary>
  public static bool Allows(ClaimsPrincipal? user, string policy) =>
    user?.Identity?.IsAuthenticated == true && RolesFor(policy).Any(user.IsInRole);
}

/// <summary>
/// Preverjanje vloge na zapisovalni meji.
///
/// Uporabnika poisce tam, kjer v tej aplikaciji dejansko je: pri zahtevi minimalnega API-ja v
/// <see cref="HttpContext"/>, v Blazor Server vezju pa v <see cref="AuthenticationStateProvider"/>
/// (tam je <c>HttpContext</c> null in bi ga bilo napacno uporabiti). Ce uporabnika ni ali nima
/// vloge, zapisovalna metoda vrze <see cref="UnauthorizedAccessException"/> **pred** klicem baze.
/// </summary>
public sealed class PimWriteGuard
{
  readonly IServiceProvider? services;
  readonly IHttpContextAccessor? httpContext;
  readonly string? trustedReason;

  public PimWriteGuard(IServiceProvider services, IHttpContextAccessor httpContext)
  {
    this.services = services;
    this.httpContext = httpContext;
  }

  PimWriteGuard(string reason) => trustedReason = reason;

  /// <summary>
  /// Varovalka za procese brez prijavljenega uporabnika (konzolni testi, orodja, workerji).
  /// V <c>src/PIM.Intranet</c> se ne sme uporabiti — to varuje pogodbeni test
  /// <c>PIM.F10.AuthTests</c>, sicer bi bila to zadnja vrata mimo vseh politik.
  /// </summary>
  public static PimWriteGuard Trusted(string reason) => new(reason);

  public async Task<ClaimsPrincipal?> CurrentUserAsync()
  {
    // Vrstni red ni okrasen. Pri zahtevi HTTP (minimalni API, predupodabljanje strani) je
    // HttpContext.User avtoritativen in dokoncen — tudi kadar je anonimen. Sele ko HttpContext
    // ni na voljo, smo v vezju Blazor Server in uporabnik je pri ponudniku stanja prijave.
    // Obratni vrstni red bi bil past: ServerAuthenticationStateProvider v zahtevi HTTP nikoli
    // ne dobi stanja, zato bi cakanje nanj obviselo.
    var context = httpContext?.HttpContext;
    if (context is not null) return context.User;
    if (services?.GetService(typeof(AuthenticationStateProvider)) is not AuthenticationStateProvider provider) return null;
    var state = await provider.GetAuthenticationStateAsync();
    return state.User;
  }

  /// <summary>Ali sme trenutni uporabnik to poceti; za izris gumbov in polj, ne kot varovalka.</summary>
  public async Task<bool> AllowsAsync(string policy)
  {
    if (trustedReason is not null) return true;
    return PimPolicies.Allows(await CurrentUserAsync(), policy);
  }

  /// <summary>
  /// Varovalka zapisovalne poti. Vrne izvajalca, ki ga zapis zabelezi, ali vrze
  /// <see cref="UnauthorizedAccessException"/>.
  /// </summary>
  public async Task<string> RequireAsync(string policy)
  {
    if (trustedReason is not null) return trustedReason;

    var user = await CurrentUserAsync();
    if (user?.Identity?.IsAuthenticated != true)
      throw new UnauthorizedAccessException("Za to dejanje je potrebna prijava.");
    if (!PimPolicies.RolesFor(policy).Any(user.IsInRole))
      throw new UnauthorizedAccessException(
        $"Dejanje zahteva eno od vlog: {string.Join(", ", PimPolicies.RolesFor(policy))}. Tvoje vloge tega ne dovolijo.");

    return user.Identity.Name ?? "neznan";
  }
}
