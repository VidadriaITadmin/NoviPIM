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
builder.Services.AddHttpContextAccessor();
builder.Services.AddScoped<LocalUserAuthenticationService>();
builder.Services.AddScoped<IntranetDataService>();
builder.Services.AddScoped<IntranetContextService>();
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
// Preklop delovnega konteksta v zgornji vrstici. Zakaj POST in ne povezava: izbira spremeni
// stanje seje, zato mora skozi antiforgery. Zakaj piskotek in ne vezje: strani so staticni SSR.
app.MapPost("/kontekst", async (HttpContext context, Microsoft.AspNetCore.Antiforgery.IAntiforgery antiforgery) =>
{
  await antiforgery.ValidateRequestAsync(context);
  var form = await context.Request.ReadFormAsync();
  var options = new CookieOptions { HttpOnly = true, IsEssential = true, SameSite = SameSiteMode.Lax, Expires = DateTimeOffset.UtcNow.AddDays(180) };
  foreach (var (field, cookie) in new[]
  {
    ("organizacija", IntranetContextService.OrganizationCookie),
    ("kanal", IntranetContextService.ChannelCookie),
    ("jezik", IntranetContextService.LanguageCookie),
  })
  {
    var value = form[field].ToString();
    if (!string.IsNullOrWhiteSpace(value)) context.Response.Cookies.Append(cookie, value, options);
  }

  // Vrnemo se tja, od koder je uporabnik prisel, a samo znotraj te aplikacije: zunanji naslov
  // v skritem polju bi bil odprta preusmeritev.
  var back = form["nazaj"].ToString();
  var safe = !string.IsNullOrWhiteSpace(back) && back.StartsWith('/') && !back.StartsWith("//", StringComparison.Ordinal);
  return Results.Redirect(safe ? back : $"{context.Request.PathBase}/nadzorna-plosca");
});
app.MapGet("/health", () => Results.Ok(new { stanje = "zdravo" })).AllowAnonymous();

app.MapRazorComponents<App>()
  .AddInteractiveServerRenderMode();

app.Run();
