using PIM.Intranet.Components;
using PIM.Intranet.Services;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using System.Security.Claims;

var builder = WebApplication.CreateBuilder(args);
builder.WebHost.UseStaticWebAssets();
var repositoryRootLocalSettingsPath = LocalSettingsLocator.FindRepositoryRootLocalSettingsPath(builder.Environment.ContentRootPath);
if (repositoryRootLocalSettingsPath is not null)
  builder.Configuration.AddJsonFile(repositoryRootLocalSettingsPath, optional: true, reloadOnChange: false);

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
builder.Services.AddSingleton<ActiveDirectoryService>();
builder.Services.AddScoped<IntranetUserAdministrationService>();

var app = builder.Build();

// IIS virtual application and local-root hosting are both supported. UsePathBase
// only consumes /PIM when it is present and leaves root requests unchanged.
app.UsePathBase("/PIM");

// Configure the HTTP request pipeline.
if (!app.Environment.IsDevelopment())
{
  app.UseExceptionHandler("/Error", createScopeForErrors: true);
}

app.UseStaticFiles();
app.UseAntiforgery();
app.UseAuthentication();
app.UseAuthorization();

app.MapPost("/auth/prijava", async (HttpContext context, LocalUserAuthenticationService authenticationService, Microsoft.AspNetCore.Antiforgery.IAntiforgery antiforgery) =>
{
  await antiforgery.ValidateRequestAsync(context);
  var form = await context.Request.ReadFormAsync();
  var user = await authenticationService.AuthenticateAsync(form["uporabniskoIme"], form["geslo"], context.RequestAborted);
  if (user is null) return Results.Redirect($"{context.Request.PathBase}/prijava?napaka=1");
  var rememberMe = form.ContainsKey("zapomniMe");
  var claims = new List<Claim>
  {
    new(ClaimTypes.Name, user.UserName),
    new(ClaimTypes.GivenName, user.DisplayName),
  };
  claims.AddRange(user.Roles.Select(role => new Claim(ClaimTypes.Role, role)));
  await context.SignInAsync(
    CookieAuthenticationDefaults.AuthenticationScheme,
    new ClaimsPrincipal(new ClaimsIdentity(claims, CookieAuthenticationDefaults.AuthenticationScheme)),
    new AuthenticationProperties
    {
      IsPersistent = rememberMe,
      ExpiresUtc = rememberMe ? DateTimeOffset.UtcNow.AddDays(14) : null,
    });
  return Results.Redirect($"{context.Request.PathBase}/nadzorna-plosca");
}).AllowAnonymous();
app.MapPost("/odjava", async (HttpContext context) =>
{
  await context.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme);
  return Results.Redirect($"{context.Request.PathBase}/prijava");
});
app.MapGet("/health", () => Results.Ok(new { stanje = "zdravo" })).AllowAnonymous();

app.MapRazorComponents<App>()
  .AddInteractiveServerRenderMode();

app.Run();
