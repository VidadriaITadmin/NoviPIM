using PIM.Intranet.Components;
using PIM.Intranet.Services;
using PIM.Operations;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using System.Security.Claims;
using System.Threading.RateLimiting;

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
    // A5, pregled 2026-09-08: zavrnjen dostop je vodil na prijavni obrazec, zato je prijavljen
    // uporabnik brez vloge videl prijavo in ni izvedel, da je stran zanj zaprta.
    options.AccessDeniedPath = "/brez-dostopa";
    // A3: piskotek se ob vsaki zahtevi primerja z zigom v bazi, zato izklop racuna in odvzem
    // vloge veljata takoj in ne sele cez 14 dni.
    options.Events.OnValidatePrincipal = PimSessionValidator.ValidateAsync;
  });
builder.Services.AddAuthorization(options =>
{
  options.FallbackPolicy = new Microsoft.AspNetCore.Authorization.AuthorizationPolicyBuilder()
    .RequireAuthenticatedUser()
    .Build();

  // Zapisovalne politike (A1, A4). Ena politika = ena poslovna pravica; strani in servisi berejo
  // isti seznam vlog iz PimPolicies, da se ne razideta.
  foreach (var policy in PimPolicies.Names)
    options.AddPolicy(policy, builderPolicy => builderPolicy
      .RequireAuthenticatedUser()
      .RequireRole(PimPolicies.RolesFor(policy)));
});

// A3, drugi del: prijava je bila brez vsakrsne omejitve poskusov. Zunanji obroc je omejevalnik
// zahtev po naslovu (varovalka pred poplavo), notranji pa PimLoginThrottle, ki steje samo
// neuspele poskuse na par uporabnisko ime + naslov.
builder.Services.AddRateLimiter(options =>
{
  options.RejectionStatusCode = StatusCodes.Status429TooManyRequests;
  options.AddPolicy(PimRateLimits.Login, context => RateLimitPartition.GetFixedWindowLimiter(
    context.Connection.RemoteIpAddress?.ToString() ?? "neznan",
    _ => new FixedWindowRateLimiterOptions
    {
      PermitLimit = PimRateLimits.LoginRequestsPerWindow,
      Window = PimRateLimits.Window,
      QueueLimit = 0,
    }));
  options.OnRejected = async (context, cancellationToken) =>
  {
    context.HttpContext.Response.ContentType = "text/plain; charset=utf-8";
    await context.HttpContext.Response.WriteAsync(
      "Preveč poskusov prijave s te naprave. Počakaj 15 minut in poskusi znova.", cancellationToken);
  };
});
builder.Services.AddHttpContextAccessor();
builder.Services.AddScoped<LocalUserAuthenticationService>();
builder.Services.AddScoped<UserSecurityStateService>();
builder.Services.AddScoped<PimWriteGuard>();
builder.Services.AddSingleton<PimLoginThrottle>();
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
app.UseRateLimiter();

app.MapPost("/auth/prijava", async (HttpContext context, LocalUserAuthenticationService authenticationService, PimLoginThrottle throttle, Microsoft.AspNetCore.Antiforgery.IAntiforgery antiforgery) =>
{
  await antiforgery.ValidateRequestAsync(context);
  var form = await context.Request.ReadFormAsync();
  var userName = form["uporabniskoIme"].ToString();
  var remoteAddress = context.Connection.RemoteIpAddress?.ToString();

  // Ugibanje gesla se ustavi tu in ne v bazi: po desetih neuspelih poskusih v petnajstih minutah
  // enajsti dobi 429 in do konca okna ne pride vec do preverjanja gesla.
  var retryAfter = throttle.RetryAfter(userName, remoteAddress);
  if (retryAfter is not null)
  {
    context.Response.Headers.RetryAfter = ((int)retryAfter.Value.TotalSeconds).ToString(System.Globalization.CultureInfo.InvariantCulture);
    return Results.Text(
      $"Preveč neuspelih poskusov prijave. Poskusi znova čez {Math.Ceiling(retryAfter.Value.TotalMinutes)} minut.",
      "text/plain; charset=utf-8", statusCode: StatusCodes.Status429TooManyRequests);
  }

  var user = await authenticationService.AuthenticateAsync(userName, form["geslo"], context.RequestAborted);
  if (user is null)
  {
    throttle.RegisterFailure(userName, remoteAddress);
    return Results.Redirect($"{context.Request.PathBase}/prijava?napaka=1");
  }

  throttle.RegisterSuccess(userName, remoteAddress);
  var rememberMe = form.ContainsKey("zapomniMe");
  var principal = PimSessionValidator.BuildPrincipal(
    new PimUserSecurityState(user.UserName, user.DisplayName, true, user.SecurityStamp, user.Roles));
  await context.SignInAsync(CookieAuthenticationDefaults.AuthenticationScheme, principal,
    new AuthenticationProperties
    {
      IsPersistent = rememberMe,
      ExpiresUtc = rememberMe ? DateTimeOffset.UtcNow.AddDays(14) : null,
    });
  return Results.Redirect($"{context.Request.PathBase}/nadzorna-plosca");
}).AllowAnonymous().RequireRateLimiting(PimRateLimits.Login);
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
    "sl", Value("oddelek"), Value("aktivnost"), Value("objava"), Value("popolnost"), Value("slika"),
    // Kategorija pride kot »drevo:koda«, ker sta kodi v dveh drevesih lahko enaki. Poleg vrstic
    // doloca tudi stolpce atributov: delovni list dobi nabor te kategorije.
    Value("kategorija")?.Split(':', 2) is { Length: 2 } category ? category[0] : null,
    Value("kategorija")?.Split(':', 2) is { Length: 2 } code ? code[1] : Value("kategorija"));

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
