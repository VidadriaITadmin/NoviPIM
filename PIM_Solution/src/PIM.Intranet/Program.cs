using PIM.Automation;
using PIM.Intranet.Components;
using PIM.Intranet.Services;
using PIM.Operations;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using System.Security.Claims;
using System.Threading.RateLimiting;

var builder = WebApplication.CreateBuilder(args);
builder.WebHost.UseStaticWebAssets();
// Lokalne nastavitve: mapa ob .exe (produkcija — tako datoteko ohranja Publish-Intranet.ps1),
// nato skupna datoteka v korenu rešitve (razvoj). Zadnji vir prepiše prejšnje; na strežniku
// korena rešitve ni, zato tam ostane samo prva. Iskanje je v PIM.Operations.LocalSettings, ker
// isto potrebujejo workerji, orodja in testi — šest kopij te logike je našlo šest datotek.
foreach (var localSettingsPath in LocalSettings.Sources(builder.Environment.ContentRootPath))
  builder.Configuration.AddJsonFile(localSettingsPath, optional: true, reloadOnChange: false);

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
    // 224: "razlog", ki ga je PimSessionValidator.RejectAsync pustil v HttpContext.Items, potuje
    // do prijavne strani, da uporabnik vidi, zakaj je ven ("nekdo drug se je prijavil s tem
    // racunom"), ne samo da je spet na /prijava.
    options.Events.OnRedirectToLogin = context =>
    {
      var reason = context.HttpContext.Items.TryGetValue("pim:razlogOdjave", out var value) ? value as string : null;
      context.Response.Redirect(reason is null
        ? context.RedirectUri
        : Microsoft.AspNetCore.WebUtilities.QueryHelpers.AddQueryString(context.RedirectUri, "razlog", reason));
      return Task.CompletedTask;
    };
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
builder.Services.AddSingleton<PimLoginTakeover>();
builder.Services.AddScoped<IntranetDataService>();
builder.Services.AddScoped<PimDb>();
builder.Services.AddScoped<CatalogReadService>();
builder.Services.AddScoped<ProductWorkbenchService>();
builder.Services.AddScoped<CustomerCardService>();
builder.Services.AddScoped<CustomerListService>();
builder.Services.AddScoped<CustomerWorkbookService>();
builder.Services.AddScoped<PackagingDiscountService>();
// Cene in ceniki v SAOP (265): branje, vrsta, delovni list; posiljanje tece v ozadju (en tek na podjetje).
builder.Services.AddScoped<PriceService>();
builder.Services.AddScoped<PriceWorkbookService>();
builder.Services.AddSingleton<PriceSendJobs>();
builder.Services.AddScoped<ProductLinkReadService>();
builder.Services.AddScoped<RulesWriteService>();
builder.Services.AddScoped<TitleRuleService>();
builder.Services.AddScoped<PriceSheetService>();
builder.Services.AddScoped<WebExportBuildService>();
builder.Services.AddScoped<MagentoArtifactService>();
builder.Services.AddScoped<CatalogControlService>();
builder.Services.AddScoped<SaopEndpointSnapshotService>();
builder.Services.AddScoped<ProductEditService>();
builder.Services.AddScoped<ProductExportService>();
builder.Services.AddScoped<QualityIssueExportService>();
builder.Services.AddScoped<ProductWorkbookService>();
builder.Services.AddScoped<ClearanceService>();
// AI predlog spletnega naziva in opisa na kartici izdelka (kljuc Ai:ApiKey v appsettings.Local.json).
builder.Services.AddScoped<AiTextService>();
// Kandidati za nove artikle iz dobaviteljevih XML (219/240). Do 2026-09-21 servisa nista bila
// registrirana, zato je stran /zajem/novi-artikli padla ze ob odprtju.
builder.Services.AddScoped<SupplierCandidateReadService>();
builder.Services.AddScoped<SupplierCandidateWriteService>();
// 241: potisk uvozenega kandidata v cakalno vrsto SAOP (isti gradnik dokumenta in ista pot kot /saop/artikli).
builder.Services.AddScoped<SupplierCandidateSaopService>();
// Izvoz delovnega lista v ozadju (/izdelki, gumb "Izvozi Excel"): singleton, ker opravilo zivi
// dlje od kroga, ki ga je sprozilo — uporabnik lahko stran zapre in se vrne, izvoz tece dalje.
builder.Services.AddSingleton<ExportResultStore>();
builder.Services.AddSingleton<ExportJobService>();
// Vrata za tezka opravila (izvoz celega kataloga, uvoz delovnega lista): hkrati jih tece
// najvec toliko, kolikor dovolijo nastavitve (privzeto 2 + 2), ostala cakajo v vrsti — glej
// HeavyWorkGate za izmerjeni razlog (analiza 2026-09-17).
builder.Services.AddSingleton<HeavyWorkGate>();
// Predpomnilnik procesa za redko spreminjajoce se registre (izbirnik kategorij na /izdelki, 5 min).
builder.Services.AddMemoryCache();
builder.Services.AddScoped<PipelineReadService>();
builder.Services.AddScoped<QualityReadService>();
builder.Services.AddScoped<QualityWriteService>();
// 251: samodejni umik kljukic spletisc, predogled, pregled in nastavitev (stran /splet/umaknjeni, kartica).
builder.Services.AddScoped<WebWithdrawalService>();
// 290: neskladja med podjetji kataloga (stran /splet/neskladja, izvoz v Excel).
builder.Services.AddScoped<OrganizationMismatchService>();
builder.Services.AddScoped<SafeguardService>();
builder.Services.AddScoped<ImportHistoryService>();
builder.Services.AddScoped<StockReadService>();
// 284: analitika prodaje, zalog in nabave (shema ana; polni PIM.SaopAnalyticsWorker).
builder.Services.AddScoped<AnalyticsService>();
builder.Services.AddScoped<GovernanceReadService>();
builder.Services.AddScoped<IntranetFeatureReadService>();
builder.Services.AddSingleton<ActiveDirectoryService>();
builder.Services.AddScoped<IntranetUserAdministrationService>();
builder.Services.AddScoped<RoleAdministrationService>();
builder.Services.AddScoped<RoleAccessService>();
builder.Services.AddScoped<SaopWriteService>();
builder.Services.AddScoped<SaopItemWriteService>();
builder.Services.AddScoped<SaopOrganizationContext>();
builder.Services.AddScoped<CategoryMappingService>();
builder.Services.AddScoped<CategoryTreeService>();
builder.Services.AddScoped<AttributeMappingService>();
builder.Services.AddScoped<AdminConsoleService>();
// Branje dnevnikov zagonov za izpis na /sistem/posel/<posel> (zagone vodi PIM.AutomationHost, ne intranet).
builder.Services.AddSingleton<WorkerConsoleService>();
// Enotni model opravil (237): intranet je nadzorna konzola gostitelja avtomatike (PIM.AutomationHost) —
// bere ops.JobDefinition/JobRun in oddaja zahteve (zagon, ustavitev, urnik), ki jih prevzame gostitelj.
builder.Services.AddSingleton(provider =>
  new AutomationStore(ConnectionStringResolver.Resolve(provider.GetRequiredService<IConfiguration>()) ?? ""));
// Nadzor (/sistem, /sistem/posel/{posel}), blok 5: sestavi posle, vire, postopke in alarme ter izreče sodbo
// (MonitorPolicy). Scoped, ker preverja vlogo prijavljenega uporabnika (PimWriteGuard) in piše sled.
builder.Services.AddScoped<MonitorService>();

// Naša ura je izbrana enkrat ob zagonu, ne podedovana od strežnika. Na IIS, nastavljenem na
// UTC, bi ToLocalTime() kazal dve uri prej — in to bi se pokazalo šele po objavi.
PimTime.Configure(builder.Configuration);

var app = builder.Build();

// IIS virtual application and local-root hosting are both supported. UsePathBase
// only consumes /PIM when it is present and leaves root requests unchanged.
app.UsePathBase("/PIM");

// Configure the HTTP request pipeline.
if (!app.Environment.IsDevelopment())
{
  app.UseExceptionHandler("/Error", createScopeForErrors: true);
}

// #65: neznan naslov je vracal 404 z 0 bajti (bela stran brez menija). Brskalnik zdaj dobi stran
// "Strani ni (vec)" v postavitvi intraneta; koda ostane 404. Samo za GET zahteve brskalnika, ki
// pricakujejo HTML: izvozi, prenosi, prijava in Blazorjevi viri ohranijo svoj kratek 404 brez strani
// (pim-export.js in prenosi v ozadju ne smejo dobiti HTML-ja intraneta namesto datoteke).
app.UseStatusCodePagesWithReExecute("/ni-najdeno", createScopeForStatusCodePages: true);
app.Use(async (context, next) =>
{
  if (!PimNotFoundScope.WantsPage(context.Request.Method, context.Request.Path, context.Request.Headers.Accept.ToString())
      && context.Features.Get<Microsoft.AspNetCore.Diagnostics.IStatusCodePagesFeature>() is { } statusPages)
    statusPages.Enabled = false;
  await next();
});

app.UseStaticFiles();
app.UseAntiforgery();
app.UseAuthentication();
app.UseAuthorization();

// #65: pri ponovni izvedbi za stran 404 Blazor odda HTML, ne da bi pocakal asinhrone komponente
// postavitve, zato je bil levi meni za ne-skrbnika prazen (dovoljenja bere iz sec.RolePermission).
// Dovoljenja zato nalozimo tu, preden se stran izrise; NavMenu jih vzame iz HttpContext.Items.
app.Use(async (context, next) =>
{
  if (context.Features.Get<Microsoft.AspNetCore.Diagnostics.IStatusCodeReExecuteFeature>() is not null
      && context.User.Identity?.IsAuthenticated == true)
  {
    try
    {
      context.Items[PimNotFoundScope.NavPermissionsItem] = await context.RequestServices
        .GetRequiredService<RoleAccessService>().GetAllowedKeysAsync(context.User, context.RequestAborted);
    }
    catch (Exception ex) when (ex is not OperationCanceledException)
    {
      // Baza ni dosegljiva: meni ostane prazen (kot prej), stran 404 se vseeno izrise.
      context.RequestServices.GetRequiredService<ILoggerFactory>().CreateLogger("PIM.NotFound")
        .LogWarning(ex, "Dovoljenj za meni na strani 404 ni bilo mogoce naloziti.");
    }
  }
  await next();
});
app.UseRateLimiter();

app.MapPost("/auth/prijava", async (
  HttpContext context, LocalUserAuthenticationService authenticationService, UserSecurityStateService security,
  PimLoginThrottle throttle, PimLoginTakeover takeover, Microsoft.AspNetCore.Antiforgery.IAntiforgery antiforgery) =>
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

  // 224: en racun, ena ziva seja. Ce je racun trenutno aktiven drugje, ga NE prijavimo tiho mimo
  // — namesto piskotka dobi zeton za prevzem, ki ga /prijava ponudi kot potrditev. Geslo je s tem
  // ze preverjeno (zgoraj); drugi krog (spodaj, /auth/prijava/prevzemi) ga zato ne zahteva znova.
  var lastSeenUtc = await security.GetLastSeenUtcAsync(user.UserName, context.RequestAborted);
  if (lastSeenUtc is not null && DateTime.UtcNow - lastSeenUtc.Value < PimLoginTakeover.ActiveWindow)
  {
    var takeoverToken = takeover.Issue(user.UserName, rememberMe);
    var lastSeenLocal = PimTime.FormatTime(lastSeenUtc);
    return Results.Redirect($"{context.Request.PathBase}/prijava?zasedeno={takeoverToken}&ime={Uri.EscapeDataString(user.DisplayName)}&ob={Uri.EscapeDataString(lastSeenLocal)}");
  }

  var principal = PimSessionValidator.BuildPrincipal(
    new PimUserSecurityState(user.UserName, user.DisplayName, true, user.SecurityStamp, user.Roles));
  var properties = new AuthenticationProperties
  {
    IsPersistent = rememberMe,
    ExpiresUtc = rememberMe ? DateTimeOffset.UtcNow.AddDays(14) : null,
  };
  await context.SignInAsync(CookieAuthenticationDefaults.AuthenticationScheme, principal, properties);
  return Results.Redirect($"{context.Request.PathBase}/nadzorna-plosca");
}).AllowAnonymous().RequireRateLimiting(PimRateLimits.Login);

// Drugi korak prevzema seje: uporabnik je na /prijava potrdil "Da, prevzemi". Zeton (ne geslo!)
// dokazuje, da je bilo geslo ze preverjeno zgoraj — glej PimLoginTakeover za razlog. Prevzem =
// nov SecurityStamp (sec.ForceSignOutUser), ki stari seji odvzame veljavnost ob njeni naslednji
// zahtevi (PimSessionValidator, 181), tukaj pa ga takoj uporabimo za novo prijavo.
app.MapPost("/auth/prijava/prevzemi", async (
  HttpContext context, UserSecurityStateService security, PimLoginTakeover takeover,
  Microsoft.AspNetCore.Antiforgery.IAntiforgery antiforgery) =>
{
  await antiforgery.ValidateRequestAsync(context);
  var form = await context.Request.ReadFormAsync();
  if (!Guid.TryParse(form["zeton"].ToString(), out var parsedToken) || takeover.Consume(parsedToken) is not { } prevzem)
    return Results.Redirect($"{context.Request.PathBase}/prijava?razlog=potekel");

  var state = await security.GetAsync(prevzem.UserName, context.RequestAborted);
  if (state is null || !state.IsEnabled)
    return Results.Redirect($"{context.Request.PathBase}/prijava?napaka=1");

  var newStamp = await security.ForceSignOutAsync(prevzem.UserName, context.RequestAborted);
  var principal = PimSessionValidator.BuildPrincipal(state with { SecurityStamp = newStamp });
  var properties = new AuthenticationProperties
  {
    IsPersistent = prevzem.RememberMe,
    ExpiresUtc = prevzem.RememberMe ? DateTimeOffset.UtcNow.AddDays(14) : null,
  };
  await context.SignInAsync(CookieAuthenticationDefaults.AuthenticationScheme, principal, properties);
  return Results.Redirect($"{context.Request.PathBase}/nadzorna-plosca");
}).AllowAnonymous().RequireRateLimiting(PimRateLimits.Login);
app.MapPost("/odjava", async (HttpContext context) =>
{
  await context.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme);
  return Results.Redirect($"{context.Request.PathBase}/prijava");
});

// Zvonec v glavi: navadna <form> objava (glava strani ostaja staticna SSR), zato preverba
// vira in ciljne poti sledi isti obliki kot /odjava zgoraj. "vrniNa" je pot brez PathBase, kot
// jo vrne Navigation.ToBaseRelativePath — nikoli absoluten ali navzkrizen naslov.
static string PimReturnPath(HttpContext context)
{
  var value = context.Request.Form["vrniNa"].ToString();
  if (string.IsNullOrWhiteSpace(value) || !Uri.IsWellFormedUriString(value, UriKind.Relative) || value.StartsWith('/'))
    return $"{context.Request.PathBase}/";
  return $"{context.Request.PathBase}/{value}";
}
app.MapPost("/obvestila/precitaj-vse", async (HttpContext context, AdminConsoleService nadzor, Microsoft.AspNetCore.Antiforgery.IAntiforgery antiforgery) =>
{
  await antiforgery.ValidateRequestAsync(context);
  await nadzor.MarkAlertsSeenAsync(context.User.Identity?.Name ?? "neznan", context.RequestAborted);
  return Results.Redirect(PimReturnPath(context));
}).RequireAuthorization(policy => policy.RequireRole(PimRoles.Admin));
app.MapPost("/obvestila/precitaj/{id:long}", async (HttpContext context, long id, AdminConsoleService nadzor, Microsoft.AspNetCore.Antiforgery.IAntiforgery antiforgery) =>
{
  await antiforgery.ValidateRequestAsync(context);
  await nadzor.MarkAlertSeenAsync(context.User.Identity?.Name ?? "neznan", id, context.RequestAborted);
  return Results.Redirect(PimReturnPath(context));
}).RequireAuthorization(policy => policy.RequireRole(PimRoles.Admin));

// Podjetje strani, ki delajo z enim podjetjem (PimOrganizationScope). Piškotek bere
// IntranetDataService.GetCurrentOrganizationAsync; neaktivno ali neznano podjetje se tam zavrže.
app.MapPost("/kontekst/podjetje", async (HttpContext context, Microsoft.AspNetCore.Antiforgery.IAntiforgery antiforgery) =>
{
  await antiforgery.ValidateRequestAsync(context);
  if (int.TryParse(context.Request.Form["podjetje"].ToString(), out var organizationId) && organizationId > 0)
    context.Response.Cookies.Append(OrganizationScope.CookieName, organizationId.ToString(System.Globalization.CultureInfo.InvariantCulture), new CookieOptions
    {
      HttpOnly = true,
      IsEssential = true,
      SameSite = SameSiteMode.Lax,
      Secure = context.Request.IsHttps,
      Path = context.Request.PathBase.HasValue ? context.Request.PathBase.Value : "/",
      Expires = DateTimeOffset.UtcNow.AddYears(1),
    });
  return Results.Redirect(PimReturnPath(context));
}).RequireAuthorization();

app.MapGet("/health", () => Results.Ok(new { stanje = "zdravo" })).AllowAnonymous();

// Izvoz zaloge, ena vrstica na artikel (migracija 190/191) — isti vir in isti filtri kot tabela
// na strani, zato je datoteka natanko to, kar je uporabnik filtriral. Podjetje ni vec obvezno:
// uporabnik 2026-09-11, dobesedno, »naredi da se bodo za vsa podjetja zaloge izpisovale in da se
// bo lahko vse kar bos filtreral izvozilo v excel« — prazno/manjkajoce "podjetje" pomeni vsa,
// enako kot na tabeli. Samo Excel (2026-09-10: »naj bo samo Excel«) — CSV je odpadel.
app.MapGet("/izvoz/zaloge.xlsx", async (HttpContext context, StockReadService stocks, HeavyWorkGate gate, CancellationToken cancellationToken) =>
{
  using var lease = await gate.Exports.EnterAsync(cancellationToken);
  var query = context.Request.Query;
  // 267: isti filtri in razvrstitev kot na /zaloge (skladisce, dobavitelj, posebnost, razvrsti).
  var filter = StockQuery.FromQuery(name => string.IsNullOrWhiteSpace(query[name]) ? null : query[name].ToString());
  var workbook = await stocks.BuildStockWorkbookAsync(filter, cancellationToken);
  return Results.File(workbook,
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    $"PIM_zaloga_{filter.OrganizationId?.ToString() ?? "vsa"}_{DateTime.UtcNow:yyyyMMdd_HHmm}.xlsx");
}).RequireAuthorization();

// Delovni list strank (250): isti filtri kot na /stranke (podjetje, vloga, iskanje, tip, …), zato je
// datoteka natanko to, kar uporabnik vidi. Uvoz nazaj je na /stranke/uvoz. Podjetje ni obvezno —
// prazno pomeni vsa, vsaka vrstica nosi svoje podjetje.
app.MapGet("/izvoz/stranke.xlsx", async (HttpContext context, CustomerListService customers, CustomerWorkbookService customerWorkbook,
  HeavyWorkGate gate, CancellationToken cancellationToken) =>
{
  using var lease = await gate.Exports.EnterAsync(cancellationToken);
  var query = context.Request.Query;
  var filter = CustomerListQuery.FromQuery(name => string.IsNullOrWhiteSpace(query[name]) ? null : query[name].ToString());
  var rows = CustomerListService.Apply(await customers.GetAsync(filter.OrganizationId, cancellationToken), filter).ToList();
  // 274: drugi list »S po tipih strank« — pravila posebnega S po tipu stranke, vračljiva z uvozom.
  return Results.File(await customerWorkbook.BuildAsync(rows, filter.OrganizationId, cancellationToken),
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    CustomerWorkbookService.FileName(DateTime.UtcNow));
}).RequireAuthorization(policy => policy.RequireRole(PimRoles.Admin, PimRoles.CatalogEditor, PimRoles.Commercial));

// Delovni list cen (265): isti filtri kot na /cene (podjetje, cenik, iskanje, stevilo cenikov, vrsta),
// ena vrstica na ceno. Uvoz nazaj je na /cene/uvoz in gre v vrsto za SAOP, ne v PIM.
app.MapGet("/izvoz/cene.xlsx", async (HttpContext context, PriceService prices, HeavyWorkGate gate, CancellationToken cancellationToken) =>
{
  using var lease = await gate.Exports.EnterAsync(cancellationToken);
  var query = context.Request.Query;
  var filter = PriceQuery.FromQuery(name => string.IsNullOrWhiteSpace(query[name]) ? null : query[name].ToString());
  var rows = await prices.GetLinesAsync(filter, cancellationToken);
  return Results.File(PriceWorkbookService.Build(rows),
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    PriceWorkbookService.FileName(DateTime.UtcNow));
}).RequireAuthorization();

app.MapGet("/izvoz/izdelki.csv", async (
  HttpContext context, ProductWorkbenchService workbench, HeavyWorkGate gate,
  CancellationToken cancellationToken) =>
{
  using var lease = await gate.Exports.EnterAsync(cancellationToken);
  var query = context.Request.Query;
  string? Value(string name) => string.IsNullOrWhiteSpace(query[name]) ? null : query[name].ToString();

  // Brez podjetja v naslovu je obseg enak kot na strani: vsa podjetja.
  int? organizationId = int.TryParse(Value("podjetje"), out var parsedOrganization) ? parsedOrganization : null;

  const int maximumRows = ProductExportService.MaxRows;
  var page = await workbench.GetProductListAsync(new ProductListFilter(
    organizationId, 0, maximumRows, Value("isci"), Value("pogled"),
    Value("proizvajalec"), Value("dobavitelj"), Value("skupina"), Value("erp"), Value("splet"),
    Value("sort"), string.Equals(Value("smer"), "desc", StringComparison.OrdinalIgnoreCase),
    "sl", Value("oddelek"), Value("aktivnost"), Value("objava"), Value("popolnost"), Value("slika"),
    PackagingDiscount: Value("spopust"), DiscountGroup: Value("rabatna"), SpecialFor: Value("posebni")),
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
  HttpContext context, ProductExportService export, ProductWorkbookService workbook, HeavyWorkGate gate,
  ExportResultStore results, CancellationToken cancellationToken) =>
{
  // Ista vrata kot izvoz v ozadju: neposredna povezava ne sme obiti omejitve socasnosti.
  using var lease = await gate.Exports.EnterAsync(cancellationToken);
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

  // "prazna=1" izrecno zahteva prazno predlogo (samo glava, brez vrstic) — uporablja jo delovna
  // predloga SAOP, kadar tabela na strani se ne vsebuje artiklov. Brez tega bi manjkajoc "items"
  // padel na privzeto vejo spodaj, ki vrne cel pogled, kar tu ni zeleno (glej ProductExportService.BuildAsync).
  var selected = string.Equals(Value("prazna"), "1", StringComparison.Ordinal)
    ? Array.Empty<string>()
    : Value("items")?.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

  var filter = new ProductListFilter(
    organizationId, 0, ProductExportService.MaxRows, Value("isci"), Value("pogled"),
    Value("proizvajalec"), Value("dobavitelj"), Value("skupina"), Value("erp"), Value("splet"),
    Value("sort"), string.Equals(Value("smer"), "desc", StringComparison.OrdinalIgnoreCase),
    "sl", Value("oddelek"), Value("aktivnost"), Value("objava"), Value("popolnost"), Value("slika"),
    // Kategorija pride kot »drevo:koda«, ker sta kodi v dveh drevesih lahko enaki. Poleg vrstic
    // doloca tudi stolpce atributov: delovni list dobi nabor te kategorije.
    Value("kategorija")?.Split(':', 2) is { Length: 2 } category ? category[0] : null,
    Value("kategorija")?.Split(':', 2) is { Length: 2 } code ? code[1] : Value("kategorija"),
    // 274: filtri S-popustov, isti kot na strani /izdelki.
    Value("spopust"), Value("rabatna"), Value("posebni"));

  if (workbookTemplate)
  {
    // Zvezek gre na disk (ExportResultStore), ne v byte[]: cel katalog je 120 MB in dva socasna
    // izvoza v pomnilniku sta bila izmerjena kot 1,3 GB delovnega pomnilnika procesa (2026-09-17).
    // Datoteka ostane 2 uri v zacasni mapi in jo pobrise ista hramba kot pri izvozu v ozadju.
    const string workbookContentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
    var tempPath = results.CreateTempFile();
    await using (var stream = new FileStream(tempPath, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16, useAsync: true))
      await workbook.BuildToAsync(stream, filter, selected, includeFieldKeys: null, progress: null, cancellationToken);
    var token = results.Put(tempPath, ProductWorkbookService.FileName(DateTime.UtcNow), workbookContentType);
    return results.TryGet(token, out var path, out var fileName, out var contentType)
      ? Results.File(path, contentType, fileName)
      : Results.Problem("Izvoz je bil zgrajen, a datoteke ni mogoce najti.");
  }

  var bytes = await export.BuildAsync(filter, template, selected, cancellationToken);
  return Results.File(bytes, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    ProductExportService.FileName(template, DateTime.UtcNow));
});

// Prevzem zvezka, ki ga je zgradil ExportJobService v ozadju (/izdelki, gumb "Izvozi Excel").
// Token zivi v ExportResultStore, datoteka na disku v zacasni mapi procesa — glej ExportJobService
// za razlog, da gradnja sploh tece loceno od tega klica. Odgovor pretaka datoteko z diska.
app.MapGet("/izvoz/prenos/{token:guid}", (Guid token, ExportResultStore results, ExportJobService exports) =>
{
  if (!results.TryGet(token, out var path, out var fileName, out var contentType))
    return Results.NotFound("Izvoz ni (vec) na voljo; morda je potekel ali ga je ze prevzel kdo drug.");
  exports.MarkDownloaded(token);
  return Results.File(path, contentType, fileName);
});

// Prenos, ki ga odpre klik na »Izvozi Excel« (/izdelki): brskalnik ga pokaze takoj, datoteka pride,
// ko je zvezek gotov — glej ExportDownloadEndpoint, zakaj ne sele ob koncu gradnje.
app.MapGet("/izvoz/zvezek/{jobId:guid}", ExportDownloadEndpoint.StreamWorkbookAsync);

// Okno izvozov v kotu vsake strani (MainLayout #pim-export-tray, wwwroot/js/pim-export.js) bere
// stanje tu, ne prek vezja strani: izvoz pripada uporabniku, zato ga vidi na /izdelki/uvoz in na
// kateri koli drugi strani, tudi po osvezitvi — glej ExportJobService, zakaj.
app.MapGet("/izvoz/opravila", (HttpContext context, ExportJobService exports) =>
{
  var now = DateTime.UtcNow;
  context.Response.Headers.CacheControl = "no-store";
  return Results.Json(exports.ForOwner(context.User.Identity?.Name ?? "").Select(job => new
  {
    id = job.JobId,
    status = job.Status.ToString(),
    phase = job.Phase.ToString(),
    done = job.RowCount,
    total = job.TotalRows,
    queuePosition = job.QueuePosition,
    remainingSeconds = job.RemainingSeconds(now),
    elapsedSeconds = (int)((job.FinishedUtc ?? now) - job.StartedUtc).TotalSeconds,
    fileName = job.FileName,
    error = job.Error,
    downloadUrl = job.DownloadToken is { } token ? $"izvoz/prenos/{token}" : null,
    downloaded = job.Downloaded,
    browserWaiting = job.BrowserWaiting,
  }));
});

app.MapPost("/izvoz/opravila/{jobId:guid}/skrij", (Guid jobId, HttpContext context, ExportJobService exports) =>
  exports.Dismiss(jobId, context.User.Identity?.Name ?? "") ? Results.NoContent() : Results.NotFound());

// Gumb »Prekliči« v oknu izvozov: ustavi tekoc ali cakajoc izvoz (npr. klik na »Izvozi« po pomoti).
app.MapPost("/izvoz/opravila/{jobId:guid}/preklici", (Guid jobId, HttpContext context, ExportJobService exports) =>
  exports.Cancel(jobId, context.User.Identity?.Name ?? "") ? Results.NoContent() : Results.NotFound());

// Izvoz odprtih napak validacije: isti filtri kot na /kakovost/napake, enaka oblika zvezka kot
// na /izdelki. Vrstica je obarvana po resnosti (rdeca = napaka, bleda oranzna = opozorilo) —
// uporabnikova zahteva 2026-09-10.
app.MapGet("/izvoz/kakovost-napake.xlsx", async (
  HttpContext context, QualityIssueExportService export, CancellationToken cancellationToken) =>
{
  var query = context.Request.Query;
  string? Value(string name) => string.IsNullOrWhiteSpace(query[name]) ? null : query[name].ToString();
  if (!int.TryParse(Value("podjetje"), out var organizationId))
    return Results.BadRequest("Izberi podjetje: izvoz napak je po podjetju.");

  var filter = new QualityIssueFilter(
    organizationId, 0, QualityIssueExportService.MaxRows, Value("isci"), Value("profil"),
    Value("resnost"), Value("blokira"), Value("polje"), "sl",
    Value("drevo"), Value("kategorija"));

  var bytes = await export.BuildAsync(filter, Value("nivo"), Value("spletisce"), cancellationToken);
  return Results.File(bytes, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    QualityIssueExportService.FileName(DateTime.UtcNow));
}).RequireAuthorization();

// Izvoz karantenskih zapisov: isti filtri kot na /kakovost/karantena.
app.MapGet("/izvoz/karantena.xlsx", async (
  HttpContext context, IntranetDataService data, CancellationToken cancellationToken) =>
{
  var query = context.Request.Query;
  string? Value(string name) => string.IsNullOrWhiteSpace(query[name]) ? null : query[name].ToString();
  if (!int.TryParse(Value("podjetje"), out var organizationId))
    return Results.BadRequest("Izberi podjetje: izvoz karantene je po podjetju.");

  var rows = await data.GetQuarantineAsync(organizationId, cancellationToken);
  var search = Value("isci");
  var source = Value("vir");
  var entity = Value("entiteta");
  var filtered = rows
    .Where(row => string.IsNullOrWhiteSpace(source) || string.Equals(row.SourceCode, source, StringComparison.OrdinalIgnoreCase))
    .Where(row => string.IsNullOrWhiteSpace(entity) || string.Equals(row.EntityType, entity, StringComparison.OrdinalIgnoreCase))
    .Where(row => string.IsNullOrWhiteSpace(search)
      || row.SourceCode.Contains(search, StringComparison.OrdinalIgnoreCase)
      || row.EntityType.Contains(search, StringComparison.OrdinalIgnoreCase)
      || (row.FailureReason?.Contains(search, StringComparison.OrdinalIgnoreCase) ?? false))
    .ToList();

  var columns = new WorkbookColumn[]
  {
    new("Vir", Width: 16), new("Entiteta", Width: 20), new("Stran", WorkbookCellKind.Number, 10),
    new("Razlog izločitve", Width: 60), new("Prejeto", WorkbookCellKind.DateTime, 18),
  };
  var cells = filtered.Select(row => (IReadOnlyList<object?>)new object?[]
  {
    row.SourceCode, row.EntityType, row.PageNumber, row.FailureReason ?? "Razlog ni podan", row.ReceivedUtc,
  });
  var bytes = WorkbookWriter.Write("Karantena", columns, cells);
  return Results.File(bytes, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "karantena-" + DateTime.UtcNow.ToPimLocal().ToString("yyyyMMdd-HHmm", System.Globalization.CultureInfo.InvariantCulture) + ".xlsx");
}).RequireAuthorization();

// 290: neskladja med podjetji — isti filtri kot na strani (OrganizationMismatchQuery) ali izbrane šifre (izbrani=a,b).
// Pravico strani preveri tudi tu: povezava na datoteko obide stran.
app.MapGet("/izvoz/neskladja-med-podjetji.xlsx", async (HttpContext context, OrganizationMismatchService mismatches,
  RoleAccessService access, HeavyWorkGate gate, CancellationToken cancellationToken) =>
{
  if (!await access.CanAccessAsync(context.User, "view.web.mismatches", cancellationToken)) return Results.Forbid();
  using var lease = await gate.Exports.EnterAsync(cancellationToken);
  var query = context.Request.Query;
  var filter = OrganizationMismatchQuery.FromQuery(name => string.IsNullOrWhiteSpace(query[name]) ? null : query[name].ToString());
  var items = query["izbrani"].ToString().Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
    .Distinct(StringComparer.Ordinal).Take(WorkbookTable.MaxRows).ToArray();
  var workbook = await mismatches.BuildWorkbookAsync(items.Length > 0 ? new OrganizationMismatchFilter() : filter,
    items.Length > 0 ? items : null, cancellationToken);
  return Results.File(workbook, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    $"PIM_neskladja_med_podjetji_{DateTime.UtcNow.ToPimLocal():yyyyMMdd_HHmm}.xlsx");
}).RequireAuthorization();

// 284: izvoz analitike artiklov/dobaviteljev — isti filtri kot na strani (AnalyticsQuery), podjetje iz izbire
// na strani. Prodajne številke so občutljive, zato poleg prijave preveri še pravico zavihka (ne samo RequireAuthorization).
app.MapGet("/izvoz/analitika-artikli.xlsx", async (HttpContext context, AnalyticsService analytics, IntranetDataService data,
  RoleAccessService access, HeavyWorkGate gate, CancellationToken cancellationToken) =>
{
  if (!await access.CanAccessAsync(context.User, "tab.analytics.items", cancellationToken)) return Results.Forbid();
  var organization = await data.GetCurrentOrganizationAsync(cancellationToken);
  if (organization is null) return Results.BadRequest("Aktivna organizacija ni na voljo.");
  using var lease = await gate.Exports.EnterAsync(cancellationToken);
  var query = context.Request.Query;
  var filter = AnalyticsQuery.FromQuery(name => string.IsNullOrWhiteSpace(query[name]) ? null : query[name].ToString());
  var ids = query["izbrani"].ToString().Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
    .Select(value => long.TryParse(value, out var id) ? id : 0).Where(id => id > 0).Distinct().ToArray();
  var workbook = await analytics.BuildItemsWorkbookAsync(organization.OrganizationId, ids.Length > 0 ? new AnalyticsItemFilter() : filter,
    ids.Length > 0 ? ids : null, cancellationToken);
  return Results.File(workbook, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    $"PIM_analitika_artikli_{organization.OrganizationId}_{DateTime.UtcNow.ToPimLocal():yyyyMMdd_HHmm}.xlsx");
}).RequireAuthorization();

app.MapGet("/izvoz/analitika-dobavitelji.xlsx", async (HttpContext context, AnalyticsService analytics, IntranetDataService data,
  RoleAccessService access, HeavyWorkGate gate, CancellationToken cancellationToken) =>
{
  if (!await access.CanAccessAsync(context.User, "tab.analytics.suppliers", cancellationToken)) return Results.Forbid();
  var organization = await data.GetCurrentOrganizationAsync(cancellationToken);
  if (organization is null) return Results.BadRequest("Aktivna organizacija ni na voljo.");
  using var lease = await gate.Exports.EnterAsync(cancellationToken);
  var query = context.Request.Query;
  var workbook = await analytics.BuildSuppliersWorkbookAsync(organization.OrganizationId,
    query["isci"].ToString(), query["razvrsti"].ToString(), query["smer"] != "nar", query["vsi"] != "1", cancellationToken);
  return Results.File(workbook, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    $"PIM_analitika_dobavitelji_{organization.OrganizationId}_{DateTime.UtcNow.ToPimLocal():yyyyMMdd_HHmm}.xlsx");
}).RequireAuthorization();

// Izvoz validacijskih profilov (/pravila/validacija): en list na poslovni nivo (ERP_SLO,
// ERP_EU/THIRD, KOMERCIALA, SPLET), enak nabor aktivnih zahtev, ki jih ta stran že prikazuje
// po nivoju (ValidationLayer.Resolve). "Prevedeno polje" je ime, kot ga uporabnik vidi na
// kartici izdelka (ProductFieldLabels) — surova koda sama po sebi pove premalo.
app.MapGet("/izvoz/validacijski-profili.xlsx", async (
  HttpContext context, GovernanceReadService governance, IntranetDataService data, CancellationToken cancellationToken) =>
{
  var organization = await data.GetCurrentOrganizationAsync(cancellationToken);
  if (organization is null) return Results.BadRequest("Aktivna organizacija ni na voljo.");

  var profiles = await governance.GetValidationProfilesAsync(organization.OrganizationId, cancellationToken);
  var rows = new List<(ValidationProfileRow Profile, FieldRequirementRow Requirement)>();
  var requirementsByProfile = await governance.GetFieldRequirementsAsync(organization.OrganizationId, cancellationToken);
  foreach (var profile in profiles)
    if (requirementsByProfile.TryGetValue(profile.ValidationProfileId, out var requirements))
      foreach (var requirement in requirements)
        if (requirement.IsActive) rows.Add((profile, requirement));

  static string Severity(string? severity) => string.Equals(severity, "WARNING", StringComparison.OrdinalIgnoreCase) ? "Opozorilo" : "Napaka";
  static string Impact(ValidationProfileRow profile) => (profile.BlocksErp, profile.BlocksWeb) switch
  {
    (true, true) => "ERP in splet", (true, false) => "ERP", (false, true) => "Splet", _ => "Ne blokira",
  };

  var columns = new WorkbookColumn[]
  {
    new("Profil", Width: 18), new("Polje", Width: 28), new("Prevedeno polje", Width: 32),
    new("Resnost", Width: 14), new("Obvezno", Width: 12), new("Vpliv", Width: 16),
  };

  var sheets = Enum.GetValues<PimValidationLayer>().Select(layer =>
  {
    var layerRows = rows
      .Where(row => ValidationLayer.Resolve(row.Profile.ProfileCode, row.Profile.Scope, row.Profile.BlocksErp, row.Profile.BlocksWeb).Contains(layer))
      .OrderBy(row => row.Profile.ProfileCode, StringComparer.Ordinal).ThenBy(row => row.Requirement.FieldCode, StringComparer.Ordinal);
    var cells = layerRows.Select(row => (IReadOnlyList<object?>)new object?[]
    {
      row.Profile.ProfileCode, row.Requirement.FieldCode, ProductFieldLabels.For(row.Requirement.FieldCode),
      Severity(row.Requirement.Severity), row.Requirement.IsRequired ? "Obvezno" : "Neobvezno", Impact(row.Profile),
    });
    // Code(), ne Label(): Excel ne dovoli "/" v imenu lista, Label() pa ga nosi (ERP_EU/THIRD).
    return new WorkbookWriteSheet(ValidationLayer.Code(layer), columns, cells);
  }).ToArray();

  var bytes = WorkbookWriter.Write(sheets);
  return Results.File(bytes, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "validacijski-profili-" + DateTime.UtcNow.ToPimLocal().ToString("yyyyMMdd-HHmm", System.Globalization.CultureInfo.InvariantCulture) + ".xlsx");
}).RequireAuthorization(policy => policy.RequireRole(PimRoles.Admin, PimRoles.CatalogEditor, PimRoles.Commercial));

// Izvoz trenutnega stanja po registrskem profilu. Vsebina gre neposredno iz SqlDataReader
// v odziv; tudi 100.000 vrstic zato ne postane en velik byte[] v pomnilniku.
//
// Do migracije 142 je poleg tega obstajala se pot /izvoz/splet/{fileName}, ki je datoteko
// brala z diska iz mape WebExport:Directory. Mape ni vec: datoteko in predogled sestavi
// ista procedura, ki jo uporabi tudi PIM.B2bWorker, zato razhajanja med tem, kar uporabnik
// vidi, in tem, kar odide na splet, ne more biti.
app.MapGet("/izvoz/splet-na-zahtevo", async (
  HttpContext context, WebExportBuildService export, GovernanceReadService governance, AdminConsoleService console, CancellationToken cancellationToken) =>
{
  var query = context.Request.Query;
  if (!int.TryParse(query["podjetje"], out var organizationId) || organizationId <= 0
    || !int.TryParse(query["profil"], out var profileId) || profileId <= 0)
    return Results.BadRequest("Manjka veljavno podjetje ali izvozni profil.");

  var onlyPublished = !bool.TryParse(query["objavljeni"], out var parsedPublished) || parsedPublished;
  string? Optional(string name) => string.IsNullOrWhiteSpace(query[name]) ? null : query[name].ToString();
  var profileCode = Optional("koda");
  if (profileCode is null) return Results.BadRequest("Manjka koda izvoznega profila.");
  var profile = (await governance.GetExportProfilesAsync(cancellationToken))
    .SingleOrDefault(value => value.ExportProfileId == profileId && value.ProfileCode == profileCode && value.IsActive && value.CanBuildOnDemand);
  if (profile is null) return Results.BadRequest("Profil in njegova koda se ne ujemata ali profil ni aktiven.");
  // "ime" pride iz /splet za stalni par katalog.csv/stranke.csv; brez njega (npr. splet/izvoz
  // z izbranim poljubnim profilom) ostane privzeto, casovno zigosano ime.
  // #92: čas v imenu datoteke je v naši uri (kot ura na računalniku), ne UTC.
  var localNow = PimTime.Local(DateTime.UtcNow);
  var fileName = Optional("ime") is { } requestedFileName
    ? WebExportBuildService.SafeFileName(requestedFileName, profileCode, localNow)
    : WebExportBuildService.FileName(profileCode, localNow);
  context.Response.ContentType = "text/csv; charset=utf-8";
  context.Response.Headers.ContentDisposition =
    $"attachment; filename*=UTF-8''{Uri.EscapeDataString(fileName)}";
  // Sled izvoza (migracija 172): datoteka, ki jo je uporabnik prenesel, je enakovreden dogodek
  // kot datoteka, ki jo je ponoci sestavil urnik. Zapis ne sme ustaviti prenosa, zato so
  // njegove napake pozrte v servisu.
  var actor = context.User.Identity?.Name ?? "neznan";
  var runKey = await console.BeginExportRunAsync(profileCode, organizationId, actor, cancellationToken);
  try
  {
    var rows = await export.WriteCsvAsync(organizationId, profileId, Optional("spletisce"), onlyPublished,
      Optional("isci"), context.Response.Body, cancellationToken);
    await console.CompleteExportRunAsync(runKey, succeeded: true, rowCount: rows, fileName: fileName,
      cancellationToken: cancellationToken);
  }
  catch (Exception exception)
  {
    // Glava je ze poslana, zato odgovora ni mogoce spremeniti v napako; zabelezimo pa jo,
    // sicer bi bil skrajsan CSV videti kot uspesen izvoz.
    await console.CompleteExportRunAsync(runKey, succeeded: false, error: exception.Message,
      cancellationToken: CancellationToken.None);
    throw;
  }

  return Results.Empty;
}).RequireAuthorization();

app.MapGet("/izvoz/magento-datoteka/{profile}", async (string profile, MagentoArtifactService artifacts, CancellationToken ct) =>
{
  if (profile is not ("MAGENTO_PRODUCTS" or "MAGENTO_CUSTOMERS")) return Results.NotFound();
  try
  {
    var opened = await artifacts.OpenAsync(profile, ct);
    return Results.Stream(opened.Stream, "text/csv; charset=utf-8", opened.Artifact.FileName,
      lastModified: new DateTimeOffset(opened.Artifact.PublishedUtc));
  }
  catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidOperationException)
  {
    return Results.Problem("Dokončana datoteka trenutno ni dosegljiva. Preveri stanje na strani Izhod na splet.", statusCode: 409);
  }
}).RequireAuthorization();

// Ista izdelana datoteka kot zvezek za Excel: CSV je za Magento (decimalna pika, UTF-8 brez BOM),
// slovenski Excel pa iz njega pokvari šumnike in decimalke.
app.MapGet("/izvoz/magento-datoteka/{profile}/excel", async (string profile, MagentoArtifactService artifacts, CancellationToken ct) =>
{
  if (profile is not ("MAGENTO_PRODUCTS" or "MAGENTO_CUSTOMERS")) return Results.NotFound();
  try
  {
    var (bytes, fileName) = await artifacts.ExcelAsync(profile, ct);
    return Results.File(bytes, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", fileName);
  }
  catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidOperationException)
  {
    return Results.Problem("Dokončana datoteka trenutno ni dosegljiva. Preveri stanje na strani Izhod na splet.", statusCode: 409);
  }
}).RequireAuthorization();

// 277: ugotovitve varovalke kot zvezek za Excel — prvo preverjanje po uvedbi ima lahko sto in več vrstic.
app.MapGet("/varovalke/{id:long}/excel", async (long id, SafeguardService safeguards, CancellationToken ct) =>
{
  if (await safeguards.ExcelAsync(id, ct) is not { } workbook) return Results.NotFound();
  return Results.File(workbook.Bytes, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", workbook.FileName);
}).RequireAuthorization();

app.MapRazorComponents<App>()
  .AddInteractiveServerRenderMode();

app.Run();
