using PIM.Intranet.Components;
using PIM.Intranet.Services;
using PIM.Operations;
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
builder.Services.AddScoped<ProductEditService>();
builder.Services.AddScoped<PipelineReadService>();
builder.Services.AddScoped<QualityReadService>();
builder.Services.AddScoped<StockReadService>();
builder.Services.AddScoped<GovernanceReadService>();
builder.Services.AddScoped<IntranetFeatureReadService>();
builder.Services.AddSingleton<ActiveDirectoryService>();
builder.Services.AddScoped<IntranetUserAdministrationService>();
builder.Services.AddScoped<SaopWriteService>();
builder.Services.AddScoped<CategoryMappingService>();
builder.Services.AddScoped<CategoryTreeService>();

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
  HttpContext context, ProductWorkbenchService workbench,
  CancellationToken cancellationToken) =>
{
  var query = context.Request.Query;
  string? Value(string name) => string.IsNullOrWhiteSpace(query[name]) ? null : query[name].ToString();

  // Brez podjetja v naslovu je obseg enak kot na strani: vsa podjetja.
  int? organizationId = int.TryParse(Value("podjetje"), out var parsedOrganization) ? parsedOrganization : null;

  const int pageSize = 200;
  const int maximumRows = 20_000;
  var rows = new List<ProductListRow>();
  long total = 0;

  while (rows.Count < maximumRows)
  {
    var page = await workbench.GetProductListAsync(new ProductListFilter(
      organizationId, rows.Count, pageSize, Value("isci"), Value("pogled"),
      Value("proizvajalec"), Value("dobavitelj"), Value("skupina"), Value("erp"), Value("splet"),
      Value("sort"), string.Equals(Value("smer"), "desc", StringComparison.OrdinalIgnoreCase),
      "sl", Value("oddelek"), Value("aktivnost"), Value("objava"), Value("popolnost")),
      cancellationToken);

    total = page.TotalCount;
    if (page.Rows.Count == 0) break;
    rows.AddRange(page.Rows);
    if (page.Rows.Count < pageSize) break;
  }

  var builderCsv = new System.Text.StringBuilder();
  builderCsv.AppendLine("Podjetje;Sifra;EAN;Naziv;Proizvajalec;Dobavitelj;Skupina;Oddelek;ERP;Splet;Popolnost;OdprteTezave;Mediji;Kategorije;CakaSAOP;Objavljen;ZadnjaSprememba");
  foreach (var row in rows)
  {
    builderCsv.AppendLine(string.Join(';', new[]
    {
      Csv(row.OrganizationName), Csv(row.ItemId), Csv(row.Ean), Csv(row.Name), Csv(row.Manufacturer),
      Csv(row.Supplier), Csv(row.ItemGroup), Csv(row.Department), Csv(row.ErpStatus), Csv(row.WebStatus),
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

// Izvoz istega pogleda v delovni zvezek. Excel je oblika, ki jo uporabnik dejansko odpre:
// CSV je pri sifri 0000000000001 in slovenskih crkah odvisen od nastavitev racunalnika,
// zvezek pa nosi tip vsake celice s sabo. CSV pot ostaja za skripte, ki jo ze uporabljajo.
app.MapGet("/izvoz/izdelki.xlsx", async (
  HttpContext context, ProductWorkbenchService workbench, CancellationToken cancellationToken) =>
{
  var query = context.Request.Query;
  string? Value(string name) => string.IsNullOrWhiteSpace(query[name]) ? null : query[name].ToString();
  int? organizationId = int.TryParse(Value("podjetje"), out var parsedOrganization) ? parsedOrganization : null;

  const int pageSize = 200;
  const int maximumRows = 20_000;
  var rows = new List<ProductListRow>();
  long total = 0;

  while (rows.Count < maximumRows)
  {
    var page = await workbench.GetProductListAsync(new ProductListFilter(
      organizationId, rows.Count, pageSize, Value("isci"), Value("pogled"),
      Value("proizvajalec"), Value("dobavitelj"), Value("skupina"), Value("erp"), Value("splet"),
      Value("sort"), string.Equals(Value("smer"), "desc", StringComparison.OrdinalIgnoreCase),
      "sl", Value("oddelek"), Value("aktivnost"), Value("objava"), Value("popolnost")),
      cancellationToken);

    total = page.TotalCount;
    if (page.Rows.Count == 0) break;
    rows.AddRange(page.Rows);
    if (page.Rows.Count < pageSize) break;
  }

  WorkbookColumn[] columns =
  [
    new("Podjetje"), new("Šifra artikla"), new("EAN"), new("Naziv", Width: 46), new("Proizvajalec"),
    new("Dobavitelj"), new("Skupina"), new("Oddelek"), new("ERP"), new("Splet"),
    new("Popolnost", WorkbookCellKind.Percent), new("Odprte težave", WorkbookCellKind.Number),
    new("Mediji", WorkbookCellKind.Number), new("Kategorije", WorkbookCellKind.Number),
    new("Čaka SAOP", WorkbookCellKind.Number), new("Objavljen"), new("Aktiven"), new("Za splet"),
    new("Zadnja sprememba", WorkbookCellKind.DateTime),
  ];

  var cells = rows.Select(row => new object?[]
  {
    row.OrganizationName, row.ItemId, row.Ean, row.Name, row.Manufacturer, row.Supplier,
    row.ItemGroup, row.Department, StatusText(row.ErpStatus), StatusText(row.WebStatus),
    row.Completeness, row.OpenIssueCount, row.MediaCount, row.CategoryCount,
    row.PendingOutboundCount, row.IsPromoted, row.IsActive, row.WebPublish, row.LastChangedUtc,
  }).ToArray();

  // Odrezan izvoz mora biti zapisan v datoteki, ne samo na zaslonu, sicer nihce ne ve zanj.
  var notes = new List<string>();
  if (total > rows.Count)
    notes.Add($"Izvoženih {rows.Count:N0} od {total:N0} vrstic pogleda; zgornja meja izvoza je {maximumRows:N0}.");

  var bytes = WorkbookWriter.Write("Izdelki", columns, cells, notes);
  return Results.File(bytes, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "izdelki.xlsx");

  static string StatusText(string status) => status switch
  {
    "VALID" => "pripravljen",
    "INVALID" => "blokiran",
    "PENDING" => "čaka validacijo",
    "NOT_CONFIGURED" => "ni profila",
    _ => status,
  };
});

app.MapRazorComponents<App>()
  .AddInteractiveServerRenderMode();

app.Run();
