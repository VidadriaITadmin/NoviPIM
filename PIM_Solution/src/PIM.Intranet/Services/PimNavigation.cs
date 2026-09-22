namespace PIM.Intranet.Services;

/// <param name="Label">Vidno ime v meniju.</param>
/// <param name="Route">Base-relativna pot, brez zacetne posevnice (zaradi IIS /PIM).</param>
/// <param name="Icon">Kljuc CSS ikone (razred <c>icon-*</c>).</param>
/// <param name="Description">Kratek opis pomembnega delovnega cilja; null ohrani kompaktno postavko.</param>
/// <param name="Roles">Vloge, ki postavko vidijo; prazno pomeni vse prijavljene.</param>
/// <param name="IsHub">Ali cilj razdeli področje na podstrani; v meniju dobi puščico.</param>
public sealed record PimNavItem(string Label, string Route, string Icon, string? Description = null, string[]? Roles = null, bool IsHub = false, string? PermissionKey = null);

/// <param name="Title">Naslov skupine v meniju; null pomeni skupino brez naslova (vrh).</param>
public sealed record PimNavSection(string? Title, IReadOnlyList<PimNavItem> Items);

/// <summary>Trajna faza podatkovnega toka, prikazana v skupni lupini aplikacije.</summary>
public sealed record PimLifecycleArea(string Code, string Label, string Description, IReadOnlyList<string> RoutePrefixes);

/// <summary>
/// Operativna področja PIM-a. To niso dovoljenja in ne poslovne vrednosti, ampak orientacija:
/// uporabnik mora na vsaki poti vedeti, v katerem delu toka dela.
/// </summary>
public static class PimLifecycle
{
  public static PimLifecycleArea Oversight { get; } = new("NADZOR", "Nadzor", "Skupni operativni pregled vseh podatkovnih tokov.", ["nadzorna-plosca"]);
  public static PimLifecycleArea Inputs { get; } = new("VHODI", "Vhodni podatki", "Zajem, preslikave in neujemanja iz SAOP, XML-jev in datotek.", ["zajem", "pravila/preslikave", "pravila/slovar"]);
  public static PimLifecycleArea Catalog { get; } = new("PIM", "PIM katalog", "Kanonični in PIM-lastni podatki kataloga.", ["izdelki", "mediji", "nastavitve/atributi", "nastavitve/kategorije", "nastavitve/nabori-atributov", "nastavitve/povezave-izdelkov", "nastavitve/jeziki", "nastavitve/skladisca", "nastavitve/kanali"]);
  public static PimLifecycleArea Quality { get; } = new("KAKOVOST", "Kakovost", "Validacija, vrzeli, prevodi, kategorije in karantena.", ["kakovost"]);
  public static PimLifecycleArea Outputs { get; } = new("IZHODI", "Izhodi ERP in splet", "Nadzorovani zapisi v SAOP ter profili in datoteke za splet.", ["saop", "splet", "izvozi", "outbound"]);
  public static PimLifecycleArea Business { get; } = new("POSLOVANJE", "Poslovanje", "Stranke, popusti, cene, ceniki in zaloga.", ["stranke", "zaloge", "cene", "preverbe", "pravila-popustov"]);
  public static PimLifecycleArea Governance { get; } = new("UPRAVLJANJE", "Upravljanje", "Pravila, lastništvo in izvor podatkov ter nastavitve kataloga.", ["nastavitve", "pravila"]);
  public static PimLifecycleArea Administration { get; } = new("ADMIN", "Administracija", "Uporabniki, vloge, integracije, alarmi in tehnično zdravje.", ["sistem", "administracija"]);

  public static IReadOnlyList<PimLifecycleArea> Areas { get; } =
  [
    Oversight, Inputs, Catalog, Quality, Outputs, Business, Governance, Administration,
  ];

  public static PimLifecycleArea ResolveLifecycleArea(string? baseRelativePath)
  {
    var path = (baseRelativePath ?? "").Split('?', '#')[0].Trim('/');
    if (path.Length == 0) return Oversight;

    return Areas.FirstOrDefault(area => area.RoutePrefixes.Any(prefix =>
      path.Equals(prefix, StringComparison.OrdinalIgnoreCase)
      || path.StartsWith(prefix + "/", StringComparison.OrdinalIgnoreCase))) ?? Oversight;
  }
}

/// <summary>
/// Informacijska arhitektura intraneta.
///
/// Zakaj v kodi in ne v <c>sec.Navigation*</c>: navigacija je del izdelka, ne konfiguracija.
/// V bazi je bila razdrobljena na sest postavk, ki niso pokrivale niti obstojecih strani, vsaka
/// nova stran pa bi zahtevala migracijo. Tu je celotna arhitektura vidna na enem zaslonu in se
/// spremeni skupaj s stranmi, ki jih opisuje. Bralni model v bazi ostaja nedotaknjen.
///
/// Skupine sledijo trajnemu podatkovnemu toku iz <c>docs/PRODUKTNI_MODEL_PIM.md</c>:
/// vhodni podatki, PIM katalog, kakovost, izhodi ERP/splet, poslovanje in upravljanje.
/// Vsaka postavka je ena destinacija; podstrani so dosegljive z razdelilne strani, nikoli
/// iz menija — tako je vsaka stran v meniju natanko enkrat.
/// </summary>
public static class PimNavigation
{
  public static IReadOnlyList<PimNavSection> Sections { get; } =
  [
    new(null,
    [
      new("Nadzorna plošča", "nadzorna-plosca", "icon-dashboard", "Operativno stanje vseh podatkovnih tokov.", PermissionKey: PimAccessCatalog.Dashboard),
    ]),
    new(PimLifecycle.Inputs.Label,
    [
      new("Zajem podatkov", "zajem", "icon-import", "Viri, teki, čakalne vrste in neujemanja.", IsHub: true, PermissionKey: PimAccessCatalog.Ingest),
    ]),
    new(PimLifecycle.Catalog.Label,
    [
      new("Izdelki", "izdelki", "icon-products", "Iskanje, kakovost in stanje izdelkov.", PermissionKey: PimAccessCatalog.Products),
      new("Mediji", "mediji", "icon-media", PermissionKey: PimAccessCatalog.Media),
    ]),
    new(PimLifecycle.Quality.Label,
    [
      new("Kakovost podatkov", "kakovost", "icon-quality", "Kaj manjka, kaj blokira izhod in kje se popravi.", IsHub: true, PermissionKey: PimAccessCatalog.Quality),
    ]),
    new(PimLifecycle.Outputs.Label,
    [
      // A5, pregled 2026-09-08: meni je bralni vlogi kazal postavki, ki ji vrneta 403. Vloge tu
      // morajo ustrezati [Authorize] na ciljni strani, sicer je meni obljuba, ki je ne drzi.
      // Cilj je zavihek Artikli, ne Pregled: to je delo, ki se z njim dejansko zacne (isti vrstni
      // red zavihkov kot SaopTabs.Tabs, uporabnikova zahteva 2026-09-11).
      new("Izhod v SAOP", "saop/artikli", "icon-export", "Kaj gre nazaj v ERP, v kakšnem stanju in kaj je ERP potrdil.", [PimRoles.Admin, PimRoles.CatalogEditor], IsHub: true, PermissionKey: PimAccessCatalog.Saop),
      new("Izhod na splet", "splet", "icon-export", "Datoteke za splet: artikli in stranke, predogled in prenos.", IsHub: true, PermissionKey: PimAccessCatalog.Web),
    ]),
    new(PimLifecycle.Business.Label,
    [
      new("Stranke", "stranke", "icon-users", "Kupci, dobavitelji in proizvajalci.", [PimRoles.Admin, PimRoles.CatalogEditor, PimRoles.Commercial], PermissionKey: PimAccessCatalog.Customers),
      new("Zaloga", "zaloge", "icon-stock", PermissionKey: PimAccessCatalog.Stocks),
      new("Cene in ceniki", "cene", "icon-price", PermissionKey: PimAccessCatalog.Prices),
      new("Preverbe cen in zaloge", "preverbe", "icon-quality", "Opozorila o cenah, maržah in zalogi — ne blokirajo izvoza.", PermissionKey: PimAccessCatalog.Checks),
    ]),
    new(PimLifecycle.Governance.Label,
    [
      new("Nastavitve kataloga", "nastavitve", "icon-settings", "Atributi, kategorije, kanali in jeziki.", [PimRoles.Admin, PimRoles.CatalogEditor, PimRoles.Commercial], IsHub: true, PermissionKey: PimAccessCatalog.CatalogSettings),
      new("Pravila in izvor podatkov", "pravila", "icon-rules", "Validacija, slovar in preslikave polj.", [PimRoles.Admin, PimRoles.CatalogEditor, PimRoles.Commercial], IsHub: true, PermissionKey: PimAccessCatalog.Rules),
    ]),
    new("Administracija",
    [
      new("Nadzor sistema", "sistem", "icon-system", "Ali podatki prihajajo, kje je napaka in kaj narediti.", [PimRoles.Admin], IsHub: true, PermissionKey: PimAccessCatalog.System),
      // Locen vnos od "Nadzor sistema" (uporabnikova zahteva 2026-09-10): dostop in nastavitve
      // niso vprasanje "ali sistem dela", zato ne sodijo med zavihke z alarmi in postopki.
      new("Sistemske zadeve", "administracija", "icon-users", "Uporabniki, vloge in mesta shranjevanja.", [PimRoles.Admin], IsHub: true, PermissionKey: PimAccessCatalog.Administration),
    ]),
  ];

  /// <summary>Postavke, ki jih dana mnozica vlog sme videti; skupine brez postavk odpadejo.</summary>
  public static IReadOnlyList<PimNavSection> For(IReadOnlyCollection<string> roles)
  {
    var visible = new List<PimNavSection>(Sections.Count);
    foreach (var section in Sections)
    {
      var items = section.Items.Where(item => CanSee(roles, item)).ToList();
      if (items.Count > 0) visible.Add(section with { Items = items });
    }

    return visible;
  }

  public static bool CanSee(IReadOnlyCollection<string> roles, PimNavItem item) =>
    item.Roles is null || item.Roles.Length == 0 || item.Roles.Any(roles.Contains);

  /// <summary>Vidnost menija iz podatkovnih dovoljenj vloge.</summary>
  public static IReadOnlyList<PimNavSection> ForPermissions(IReadOnlySet<string> permissions)
  {
    var visible = new List<PimNavSection>(Sections.Count);
    foreach (var section in Sections)
    {
      var items = new List<PimNavItem>();
      foreach (var item in section.Items)
      {
        if (item.PermissionKey is not null && !permissions.Contains(item.PermissionKey)) continue;

        // Nekatere menijske povezave vodijo neposredno na prvi pogled področja (npr. SAOP →
        // Artikli). Če vloga tega pogleda nima, jo peljemo na prvi dovoljen pogled in ne na 403.
        var entryPermission = PimAccessCatalog.Resolve(item.Route);
        if (entryPermission is not null && entryPermission != item.PermissionKey && !permissions.Contains(entryPermission))
        {
          var fallback = item.PermissionKey is null
            ? null
            : PimAccessCatalog.ChildrenOf(item.PermissionKey).FirstOrDefault(child => permissions.Contains(child.Key));
          if (fallback is null) continue;
          items.Add(item with { Route = fallback.Route });
        }
        else items.Add(item);
      }
      if (items.Count > 0) visible.Add(section with { Items = items });
    }
    return visible;
  }
}

/// <summary>Kode vlog iz <c>sec.Role</c>. Zapisane enkrat, da se ne razhajajo po straneh.</summary>
public static class PimRoles
{
  public const string Admin = "ADMIN";
  public const string CatalogEditor = "CATALOG_EDITOR";
  public const string Commercial = "COMMERCIAL";
  public const string Viewer = "VIEWER";

  /// <summary>Kdor sme urejati katalog.</summary>
  public const string CatalogWrite = Admin + "," + CatalogEditor;

  /// <summary>Kdor sme urejati katalog ali komercialne podatke.</summary>
  public const string BusinessWrite = Admin + "," + CatalogEditor + "," + Commercial;
}
