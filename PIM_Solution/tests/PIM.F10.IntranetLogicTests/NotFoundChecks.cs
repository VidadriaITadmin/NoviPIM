using PIM.Intranet.Services;

/// <summary>
/// #65: neznana ali odstranjena pot je vracala 404 z 0 bajti in brskalnik je pokazal belo stran.
/// Test drzi na mestu stran "Strani ni (vec)", njeno vezavo v Router/Program in to, da izvozi in
/// prenosi ohranijo kratek 404 brez HTML-ja intraneta.
/// </summary>
static class NotFoundChecks
{
  public static void Run(string solutionRoot)
  {
    var intranet = Path.Combine(solutionRoot, "src", "PIM.Intranet");
    var routes = File.ReadAllText(Path.Combine(intranet, "Components", "Routes.razor"));
    var program = File.ReadAllText(Path.Combine(intranet, "Program.cs"));
    var pagePath = Path.Combine(intranet, "Components", "Pages", "NotFound.razor");
    Check(File.Exists(pagePath), "Manjka stran Components/Pages/NotFound.razor.");
    var page = File.ReadAllText(pagePath);
    var routeView = File.ReadAllText(Path.Combine(intranet, "Components", "Shared", "PimAccessRouteView.razor"));

    Check(routes.Contains("NotFoundPage=\"typeof(Pages.NotFound)\"", StringComparison.Ordinal), "Router mora imeti NotFoundPage.");
    Check(program.Contains("UseStatusCodePagesWithReExecute(\"/ni-najdeno\"", StringComparison.Ordinal), "Program.cs mora 404 brskalnika pripeljati na /ni-najdeno.");
    Check(program.IndexOf("UseStatusCodePagesWithReExecute", StringComparison.Ordinal) < program.IndexOf("app.UseStaticFiles()", StringComparison.Ordinal),
      "Strani za 404 morajo biti nastavljene pred staticnimi datotekami in avtorizacijo.");
    Check(program.Contains("PimNotFoundScope.WantsPage", StringComparison.Ordinal), "Izvozi in prenosi morajo biti izvzeti iz strani 404.");

    Check(page.Contains("@page \"/ni-najdeno\"", StringComparison.Ordinal), "Stran mora imeti pot /ni-najdeno.");
    Check(page.Contains("<PimPage Title=\"Strani ni (več)\"", StringComparison.Ordinal), "Stran mora imeti naslov (h1) prek PimPage.");
    Check(page.Contains("role=\"status\"", StringComparison.Ordinal), "Sporocilo mora imeti role=status.");
    Check(page.Contains("href=\"nadzorna-plosca\"", StringComparison.Ordinal) && page.Contains("href=\"izdelki\"", StringComparison.Ordinal),
      "Povezavi na nadzorno plosco in iskanje izdelkov morata biti base-relativni.");
    Check(!page.Contains("NavigateTo", StringComparison.Ordinal), "Stran ne preusmerja (odlocitev lastnika).");
    Check(page.Contains("Status404NotFound", StringComparison.Ordinal), "Stran mora ohraniti kodo 404.");
    Check(routeView.Contains("typeof(Pages.NotFound)", StringComparison.Ordinal), "Preverjanje dostopa ne sme zapreti strani 404.");

    Check(PimAccessCatalog.Resolve("ni-najdeno") is null, "Stran 404 vidijo vsi prijavljeni.");
    Check(PimAccessCatalog.Resolve("karkoli-xyz") == "__unknown__", "Neznana pot ostane privzeto zaprta.");

    Check(PimNotFoundScope.WantsPage("GET", "/karkoli-xyz", "text/html,application/xhtml+xml"), "Brskalnik dobi stran 404.");
    Check(PimNotFoundScope.WantsPage("GET", "/sistem/opravila", "text/html; blazor-enhanced-nav=on"), "Tudi izboljsana navigacija dobi stran 404.");
    Check(!PimNotFoundScope.WantsPage("GET", "/izvoz/prenos/00000000-0000-0000-0000-000000000000", "text/html"), "Prenos izvoza ohrani kratek 404.");
    Check(!PimNotFoundScope.WantsPage("POST", "/izvoz/opravila/x/skrij", "*/*"), "POST ne dobi strani 404.");
    Check(!PimNotFoundScope.WantsPage("GET", "/izvoz/opravila", "application/json"), "JSON zahteva ne dobi HTML-ja.");
    Check(!PimNotFoundScope.WantsPage("GET", "/manjka.png", "text/html"), "Manjkajoca datoteka ni stran.");
    Check(!PimNotFoundScope.WantsPage("GET", "/_blazor/negotiate", "text/html"), "Blazorjevi viri ne dobijo strani.");
    Check(PimNotFoundScope.WantsPage("GET", "/izvozi/mnozicno-xyz", "text/html"), "/izvozi (strani) ni isto kot /izvoz (prenosi).");
    // Preverjalec #65: ne-skrbnik (COMMERCIAL, CATALOG_EDITOR, VIEWER) je na strani 404 dobil prazen meni,
    // ker Blazor pri ponovni izvedbi ne pocaka asinhronega NavMenu (poizvedba v sec.RolePermission).
    // Program.cs mora dovoljenja naloziti pred izrisom, NavMenu pa jih vzeti brez await.
    var navMenu = File.ReadAllText(Path.Combine(intranet, "Components", "Layout", "NavMenu.razor"));
    var preload = program.IndexOf("PimNotFoundScope.NavPermissionsItem", StringComparison.Ordinal);
    Check(preload > 0, "Program.cs mora za stran 404 vnaprej naloziti dovoljenja menija.");
    Check(program.IndexOf("IStatusCodeReExecuteFeature", StringComparison.Ordinal) is var feature && feature > 0 && feature < preload,
      "Vnaprejsnje nalaganje velja samo za ponovno izvedbo (stran 404), ne za vsako zahtevo.");
    Check(program.IndexOf("app.UseAuthorization();", StringComparison.Ordinal) < preload,
      "Dovoljenja se nalozijo sele po prijavi (UseAuthentication/UseAuthorization).");
    Check(program.IndexOf("GetAllowedKeysAsync(context.User", StringComparison.Ordinal) > preload - 400,
      "Vnaprej nalozena dovoljenja morajo priti iz istega vira kot meni (RoleAccessService).");
    var sync = navMenu.IndexOf("PimNotFoundScope.NavPermissionsItem", StringComparison.Ordinal);
    Check(sync > 0, "NavMenu mora uporabiti vnaprej nalozena dovoljenja.");
    Check(sync < navMenu.IndexOf("await AuthenticationStateProvider", StringComparison.Ordinal),
      "NavMenu mora vnaprej nalozena dovoljenja uporabiti pred prvim await, sicer je meni na 404 spet prazen.");

    // Ne-skrbniski nabor dovoljenj (brez sistema in vlog) mora dati neprazen meni brez skrbniskih povezav.
    var nonAdmin = PimAccessCatalog.Keys
      .Where(key => !key.StartsWith(PimAccessCatalog.System, StringComparison.Ordinal) && !key.StartsWith(PimAccessCatalog.Administration, StringComparison.Ordinal))
      .ToHashSet(StringComparer.Ordinal);
    var sections = PimNavigation.ForPermissions(nonAdmin);
    Check(sections.Sum(section => section.Items.Count) > 0, "Meni za ne-skrbnika ne sme biti prazen.");
    Check(sections.SelectMany(section => section.Items).All(item => !item.Route.StartsWith("sistem", StringComparison.Ordinal)),
      "Ne-skrbnik brez dovoljenja za sistem ne vidi povezav na sistem.");
    Check(PimNavigation.ForPermissions(new HashSet<string>(StringComparer.Ordinal)).Sum(section => section.Items.Count) == 0,
      "Brez dovoljenj meni ne kaze povezav (varovalka ostane).");

    Console.WriteLine("Stran ni najdeno (#65) PASS.");
  }

  static void Check(bool condition, string message)
  {
    if (!condition) throw new InvalidOperationException("Ni najdeno (#65): " + message);
  }
}
