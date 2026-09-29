using System.Security.Claims;
using System.Text.Encodings.Web;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

// Klikalnik: intranet na razvojni bazi z vgrajenim uporabnikom "klikalnik" (vloga ADMIN), brez prijave.
// Varovalka: zažene se samo, če PIM_CONNECTION_STRING kaže na razvojni strežnik (privzeto DAVID\MSSQL19).
// Vrata: privzeto 5000; KLIKALNIK_PORT omogoči več hkratnih testnih intranetov (vzporedni agenti).
var port = int.TryParse(Environment.GetEnvironmentVariable("KLIKALNIK_PORT"), out var p) ? p : 5000;
Environment.SetEnvironmentVariable("ASPNETCORE_URLS", $"http://localhost:{port}");
Environment.SetEnvironmentVariable("ASPNETCORE_HTTP_PORTS", null);
var dovoljenStreznik = Environment.GetEnvironmentVariable("KLIKALNIK_STREZNIK") ?? @"DAVID\MSSQL19";
var povezava = Environment.GetEnvironmentVariable("PIM_CONNECTION_STRING")
  ?? $"Server={dovoljenStreznik};Database=PIM;Integrated Security=True;Encrypt=True;TrustServerCertificate=True";
if (!povezava.Contains($"Server={dovoljenStreznik};", StringComparison.OrdinalIgnoreCase))
{
  Console.Error.WriteLine($"Ustavljeno: povezava ne kaže na {dovoljenStreznik}. Klikalnik ne sme na produkcijo.");
  return 2;
}
Environment.SetEnvironmentVariable("PIM_CONNECTION_STRING", povezava);

var intranet = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "../../../../../src/PIM.Intranet"));
Environment.SetEnvironmentVariable("ASPNETCORE_TEST_CONTENTROOT_PIM_INTRANET", intranet);

using var factory = new WebApplicationFactory<PIM.Intranet.Services.ProductEditService>()
  .WithWebHostBuilder(b =>
  {
    b.UseEnvironment("Development");
    b.UseSetting(WebHostDefaults.ServerUrlsKey, $"http://localhost:{port}");
    b.ConfigureTestServices(s =>
    {
      s.AddAuthentication().AddScheme<AuthenticationSchemeOptions, KlikalnikAuth>(KlikalnikAuth.Shema, _ => { });
      s.PostConfigure<AuthenticationOptions>(o =>
      {
        o.DefaultScheme = KlikalnikAuth.Shema;
        o.DefaultAuthenticateScheme = KlikalnikAuth.Shema;
        o.DefaultChallengeScheme = KlikalnikAuth.Shema;
        o.DefaultForbidScheme = KlikalnikAuth.Shema;
      });
    });
  });
factory.UseKestrel(port);
factory.StartServer();
Console.WriteLine($"Klikalnik intranet teče: http://localhost:{port}/  (baza {dovoljenStreznik}). Ctrl+C za konec.");
var konec = new TaskCompletionSource();
Console.CancelKeyPress += (_, e) => { e.Cancel = true; konec.TrySetResult(); };
await konec.Task;
return 0;

sealed class KlikalnikAuth(IOptionsMonitor<AuthenticationSchemeOptions> o, ILoggerFactory l, UrlEncoder e)
  : AuthenticationHandler<AuthenticationSchemeOptions>(o, l, e)
{
  public const string Shema = "Klikalnik";
  protected override Task<AuthenticateResult> HandleAuthenticateAsync()
  {
    var id = new ClaimsIdentity(
      [new(ClaimTypes.Name, "klikalnik"), new(ClaimTypes.GivenName, "Klikalnik (test)"), new(ClaimTypes.Role, "ADMIN")], Shema);
    return Task.FromResult(AuthenticateResult.Success(new AuthenticationTicket(new ClaimsPrincipal(id), Shema)));
  }
}
