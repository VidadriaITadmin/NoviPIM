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
builder.Services.AddScoped<PimDb>();
builder.Services.AddScoped<CatalogReadService>();
builder.Services.AddScoped<ProductWorkbenchService>();
builder.Services.AddScoped<PipelineReadService>();
builder.Services.AddScoped<GovernanceReadService>();
builder.Services.AddSingleton<ActiveDirectoryService>();
builder.Services.AddScoped<IntranetUserAdministrationService>();
builder.Services.AddScoped<SaopWriteService>();

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

// Izvoz trenutnega pogleda seznama izdelkov. Bralna pot: uporabi isto proceduro in iste
// filtre kot stran, zato je datoteka natanko to, kar uporabnik vidi. Zgornja meja je
// izrecna in zapisana v datoteko — tiho odrezan izvoz je huje kot majhen izvoz.
app.MapGet("/izvoz/izdelki.csv", async (
  HttpContext context, IntranetDataService data, ProductWorkbenchService workbench,
  CancellationToken cancellationToken) =>
{
  var organization = await data.GetCurrentOrganizationAsync();
  if (organization is null) return Results.BadRequest("Aktivna organizacija ni na voljo.");

  var query = context.Request.Query;
  string? Value(string name) => string.IsNullOrWhiteSpace(query[name]) ? null : query[name].ToString();

  const int pageSize = 200;
  const int maximumRows = 20_000;
  var rows = new List<ProductListRow>();
  long total = 0;

  while (rows.Count < maximumRows)
  {
    var page = await workbench.GetProductListAsync(new ProductListFilter(
      organization.OrganizationId, rows.Count, pageSize, Value("isci"), Value("pogled"),
      Value("proizvajalec"), Value("dobavitelj"), Value("skupina"), Value("erp"), Value("splet"),
      Value("sort"), string.Equals(Value("smer"), "desc", StringComparison.OrdinalIgnoreCase)),
      cancellationToken);

    total = page.TotalCount;
    if (page.Rows.Count == 0) break;
    rows.AddRange(page.Rows);
    if (page.Rows.Count < pageSize) break;
  }

  var builderCsv = new System.Text.StringBuilder();
  builderCsv.AppendLine("Sifra;EAN;Naziv;Proizvajalec;Dobavitelj;Skupina;ERP;Splet;Popolnost;OdprteTezave;Mediji;Kategorije;CakaSAOP;Objavljen;ZadnjaSprememba");
  foreach (var row in rows)
  {
    builderCsv.AppendLine(string.Join(';', new[]
    {
      Csv(row.ItemId), Csv(row.Ean), Csv(row.Name), Csv(row.Manufacturer), Csv(row.Supplier),
      Csv(row.ItemGroup), Csv(row.ErpStatus), Csv(row.WebStatus),
      row.Completeness.ToString("0.##", System.Globalization.CultureInfo.InvariantCulture),
      row.OpenIssueCount.ToString(System.Globalization.CultureInfo.InvariantCulture),
      row.MediaCount.ToString(System.Globalization.CultureInfo.InvariantCulture),
      row.CategoryCount.ToString(System.Globalization.CultureInfo.InvariantCulture),
      row.PendingOutboundCount.ToString(System.Globalization.CultureInfo.InvariantCulture),
      row.IsPromoted ? "da" : "ne",
      row.LastChangedUtc?.ToString("yyyy-MM-dd HH:mm", System.Globalization.CultureInfo.InvariantCulture) ?? "",
    }));
  }

  if (total > rows.Count)
    builderCsv.AppendLine($"# Izvozenih {rows.Count} od {total} vrstic pogleda; zgornja meja izvoza je {maximumRows}.");

  // UTF-8 z BOM, ker Excel brez njega slovenske crke prebere napacno.
  var bytes = new System.Text.UTF8Encoding(encoderShouldEmitUTF8Identifier: true).GetBytes(builderCsv.ToString());
  return Results.File(bytes, "text/csv; charset=utf-8", "izdelki.csv");

  static string Csv(string? value)
  {
    if (string.IsNullOrEmpty(value)) return "";
    var cleaned = value.Replace('\r', ' ').Replace('\n', ' ').Replace(';', ',');
    return cleaned.Replace("\"", "\"\"");
  }
});

app.MapRazorComponents<App>()
  .AddInteractiveServerRenderMode();

app.Run();
