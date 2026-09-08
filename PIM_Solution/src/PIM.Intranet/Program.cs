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
builder.Services.AddScoped<CustomerCardService>();
builder.Services.AddScoped<ProductLinkReadService>();
builder.Services.AddScoped<RulesWriteService>();
builder.Services.AddScoped<TitleRuleService>();
builder.Services.AddScoped<PriceSheetService>();
builder.Services.AddScoped<WebExportBuildService>();
builder.Services.AddScoped<SaopEndpointSnapshotService>();
builder.Services.AddScoped<ProductEditService>();
builder.Services.AddScoped<ProductExportService>();
builder.Services.AddScoped<ProductWorkbookService>();
builder.Services.AddScoped<PipelineReadService>();
builder.Services.AddScoped<QualityReadService>();
builder.Services.AddScoped<StockReadService>();
builder.Services.AddScoped<GovernanceReadService>();
builder.Services.AddScoped<IntranetFeatureReadService>();
builder.Services.AddSingleton<ActiveDirectoryService>();
builder.Services.AddScoped<IntranetUserAdministrationService>();
builder.Services.AddScoped<SaopWriteService>();
builder.Services.AddScoped<SaopItemWriteService>();
builder.Services.AddScoped<CategoryMappingService>();
builder.Services.AddScoped<CategoryTreeService>();
builder.Services.AddScoped<AttributeMappingService>();

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
// Izvoz zaloge z izbiro vira (migracija 150, filtri iz migracije 151): SAOP (ERP), dobavitelj
// ali oboje, po zelji se dolocen vir, iskanje, ima zalogo in svezina — isti filtri kot na
// tabeli /zaloge, ker gumb ne sme prenesti vec, kot je uporabnik filtriral. "splet" ostane brez
// kontrole na strani (dropdown Obseg izvoza je odpadel 2026-09-03), a ostaja veljaven parameter.
app.MapGet("/izvoz/zaloge.csv", async (HttpContext context, StockReadService stocks, CancellationToken cancellationToken) =>
{
  var query = context.Request.Query;
  if (!int.TryParse(query["podjetje"], out var organizationId) || organizationId <= 0)
    return Results.BadRequest("Izberi podjetje: izvoz zaloge je po podjetju.");
  var source = (query["vir"].ToString() ?? "VSE").ToUpperInvariant();
  if (source is not ("ERP" or "DOBAVITELJ" or "VSE")) source = "VSE";
  var onlyWeb = string.Equals(query["splet"], "1", StringComparison.Ordinal);
  var sourceCode = query["virsifra"].ToString();
  var search = query["isci"].ToString();
  var availability = query["zaloga"].ToString();
  var maxAgeHours = int.TryParse(query["starost"], out var age) ? age : (int?)null;
  context.Response.ContentType = "text/csv; charset=utf-8";
  context.Response.Headers.ContentDisposition =
    $"attachment; filename=\"PIM_zaloga_{organizationId}_{source.ToLowerInvariant()}_{DateTime.UtcNow:yyyyMMdd_HHmm}.csv\"";
  await stocks.WriteStockCsvAsync(
    organizationId, source, onlyWeb, sourceCode, search, availability, maxAgeHours,
    context.Response.Body, cancellationToken);
  return Results.Empty;
}).RequireAuthorization();

app.MapGet("/izvoz/izdelki.csv", async (
  HttpContext context, ProductWorkbenchService workbench,
  CancellationToken cancellationToken) =>
{
  var query = context.Request.Query;
  string? Value(string name) => string.IsNullOrWhiteSpace(query[name]) ? null : query[name].ToString();

  // Brez podjetja v naslovu je obseg enak kot na strani: vsa podjetja.
  int? organizationId = int.TryParse(Value("podjetje"), out var parsedOrganization) ? parsedOrganization : null;

  const int maximumRows = ProductExportService.MaxRows;
  var page = await workbench.GetProductListAsync(new ProductListFilter(
    organizationId, 0, maximumRows, Value("isci"), Value("pogled"),
    Value("proizvajalec"), Value("dobavitelj"), Value("skupina"), Value("erp"), Value("splet"),
    Value("sort"), string.Equals(Value("smer"), "desc", StringComparison.OrdinalIgnoreCase),
    "sl", Value("oddelek"), Value("aktivnost"), Value("objava"), Value("popolnost"), Value("slika")),
    cancellationToken);
  var rows = page.Rows;
  var total = page.TotalCount;

  var builderCsv = new System.Text.StringBuilder();
  builderCsv.AppendLine("Podjetje;Sifra;EAN;Naziv;Proizvajalec;Dobavitelj;Skupina;ABCKlasifikacija;ERP;Splet;Popolnost;OdprteTezave;Mediji;Kategorije;CakaSAOP;Objavljen;ZadnjaSprememba");
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

// Izvoz pogleda v delovni zvezek. Tri predloge:
//   predloga=delovni — delovni list izdelkov: ERP, splet, kategorije, spletne strani in
//     atributi v eni datoteki, ki jo je mogoce urediti in vrniti na /izdelki/uvoz;
//   predloga=saop    — samo ERP polja iz registra out.SaopXmlField (vrne se na /saop/artikli);
//   brez predloge    — pregled, enosmeren.
// Obseg je bodisi cel pogled bodisi samo izbrani izdelki.
app.MapGet("/izvoz/izdelki.xlsx", async (
  HttpContext context, ProductExportService export, ProductWorkbookService workbook,
  CancellationToken cancellationToken) =>
{
  var query = context.Request.Query;
  string? Value(string name) => string.IsNullOrWhiteSpace(query[name]) ? null : query[name].ToString();
  int? organizationId = int.TryParse(Value("podjetje"), out var parsedOrganization) ? parsedOrganization : null;

  var requested = Value("predloga");
  var template = string.Equals(requested, "saop", StringComparison.OrdinalIgnoreCase)
    ? ProductExportTemplate.Saop
    : ProductExportTemplate.Overview;
  // Delovni list je tretja predloga in edina, ki gre ven in se vrne nazaj skozi isto pogodbo
  // stolpcev (ProductWorkbookContract). Zato ni vejica v ProductExportService, ampak svoj
  // servis: izvoz in uvoz morata brati isti seznam, sicer se datoteka ne da vrniti.
  var workbookTemplate = string.Equals(requested, "delovni", StringComparison.OrdinalIgnoreCase);

  var selected = Value("items")?.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

  var filter = new ProductListFilter(
    organizationId, 0, ProductExportService.MaxRows, Value("isci"), Value("pogled"),
    Value("proizvajalec"), Value("dobavitelj"), Value("skupina"), Value("erp"), Value("splet"),
    Value("sort"), string.Equals(Value("smer"), "desc", StringComparison.OrdinalIgnoreCase),
    "sl", Value("oddelek"), Value("aktivnost"), Value("objava"), Value("popolnost"), Value("slika"));

  if (workbookTemplate)
  {
    var workbookBytes = await workbook.BuildAsync(filter, selected, cancellationToken);
    return Results.File(workbookBytes, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      ProductWorkbookService.FileName(DateTime.UtcNow));
  }

  var bytes = await export.BuildAsync(filter, template, selected, cancellationToken);
  return Results.File(bytes, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    ProductExportService.FileName(template, DateTime.UtcNow));
});

// Izvoz trenutnega stanja po registrskem profilu. Vsebina gre neposredno iz SqlDataReader
// v odziv; tudi 100.000 vrstic zato ne postane en velik byte[] v pomnilniku.
//
// Do migracije 142 je poleg tega obstajala se pot /izvoz/splet/{fileName}, ki je datoteko
// brala z diska iz mape WebExport:Directory. Mape ni vec: datoteko in predogled sestavi
// ista procedura, ki jo uporabi tudi PIM.B2bWorker, zato razhajanja med tem, kar uporabnik
// vidi, in tem, kar odide na splet, ne more biti.
app.MapGet("/izvoz/splet-na-zahtevo", async (
  HttpContext context, WebExportBuildService export, CancellationToken cancellationToken) =>
{
  var query = context.Request.Query;
  if (!int.TryParse(query["podjetje"], out var organizationId) || organizationId <= 0
    || !int.TryParse(query["profil"], out var profileId) || profileId <= 0)
    return Results.BadRequest("Manjka veljavno podjetje ali izvozni profil.");

  var onlyPublished = !bool.TryParse(query["objavljeni"], out var parsedPublished) || parsedPublished;
  string? Optional(string name) => string.IsNullOrWhiteSpace(query[name]) ? null : query[name].ToString();
  var profileCode = Optional("koda");
  if (profileCode is null) return Results.BadRequest("Manjka koda izvoznega profila.");
  var fileName = WebExportBuildService.FileName(profileCode, DateTime.UtcNow);
  context.Response.ContentType = "text/csv; charset=utf-8";
  context.Response.Headers.ContentDisposition =
    $"attachment; filename*=UTF-8''{Uri.EscapeDataString(fileName)}";
  await export.WriteCsvAsync(organizationId, profileId, Optional("spletisce"), onlyPublished,
    Optional("isci"), context.Response.Body, cancellationToken);
  return Results.Empty;
}).RequireAuthorization();

app.MapRazorComponents<App>()
  .AddInteractiveServerRenderMode();

app.Run();
