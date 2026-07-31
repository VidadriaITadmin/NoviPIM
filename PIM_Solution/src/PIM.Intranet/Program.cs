using PIM.Intranet.Components;
using PIM.Intranet.Services;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using System.Security.Claims;

var builder = WebApplication.CreateBuilder(args);
builder.Configuration.AddJsonFile("appsettings.Local.json", optional: true, reloadOnChange: false);

// Add services to the container.
builder.Services.AddRazorComponents()
  .AddInteractiveServerComponents();
builder.Services.AddCascadingAuthenticationState();
builder.Services.AddAuthentication(CookieAuthenticationDefaults.AuthenticationScheme)
  .AddCookie(options =>
  {
    options.LoginPath = "/prijava";
    options.AccessDeniedPath = "/prijava";
  });
builder.Services.AddAuthorization(options =>
{
  options.FallbackPolicy = new Microsoft.AspNetCore.Authorization.AuthorizationPolicyBuilder()
    .RequireAuthenticatedUser()
    .Build();
});
builder.Services.AddScoped<LocalUserAuthenticationService>();
builder.Services.AddScoped<IntranetDataService>();

var app = builder.Build();

// Configure the HTTP request pipeline.
if (!app.Environment.IsDevelopment())
{
  app.UseExceptionHandler("/Error", createScopeForErrors: true);
}

app.UseStaticFiles();
app.UseAntiforgery();
app.UseAuthentication();
app.UseAuthorization();

app.MapPost("/prijava", async (HttpContext context, LocalUserAuthenticationService authenticationService) =>
{
  var form = await context.Request.ReadFormAsync();
  var user = await authenticationService.AuthenticateAsync(form["uporabniskoIme"], form["geslo"], context.RequestAborted);
  if (user is null) return Results.Redirect("/prijava?napaka=1");
  var claims = new List<Claim>
  {
    new(ClaimTypes.Name, user.UserName),
    new(ClaimTypes.GivenName, user.DisplayName),
  };
  claims.AddRange(user.Roles.Select(role => new Claim(ClaimTypes.Role, role)));
  await context.SignInAsync(CookieAuthenticationDefaults.AuthenticationScheme, new ClaimsPrincipal(new ClaimsIdentity(claims, CookieAuthenticationDefaults.AuthenticationScheme)));
  return Results.Redirect("/nadzorna-plosca");
});
app.MapPost("/odjava", async (HttpContext context) =>
{
  await context.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme);
  return Results.Redirect("/prijava");
});
app.MapGet("/health", () => Results.Ok(new { stanje = "zdravo" })).AllowAnonymous();

app.MapRazorComponents<App>()
  .AddInteractiveServerRenderMode();

app.Run();
