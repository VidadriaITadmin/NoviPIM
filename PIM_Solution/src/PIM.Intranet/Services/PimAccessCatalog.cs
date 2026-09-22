namespace PIM.Intranet.Services;

/// <summary>
/// Ena pravica do strani ali njenega pogleda. Hierarhija je namenoma v kodi: poti in zavihki
/// so del aplikacije, dodelitve vlog pa so podatki v <c>sec.RolePermission</c>.
/// </summary>
public sealed record PimPermissionDefinition(
  string Key,
  string Name,
  string Description,
  string Route,
  string Group,
  string? ParentKey = null,
  bool IsTab = false);

/// <summary>
/// Enoten katalog strani, podstrani in zavihkov, ki jih lahko skrbnik dodeli vlogi. Isti ključi
/// se uporabljajo v upravljanju vlog, stranskem meniju, vrsticah zavihkov in varovalu poti.
/// </summary>
public static class PimAccessCatalog
{
  public const string Dashboard = "page.dashboard";
  public const string Ingest = "page.ingest";
  public const string Products = "page.products";
  public const string Media = "page.media";
  public const string Quality = "page.quality";
  public const string Saop = "page.saop";
  public const string Web = "page.web";
  public const string Customers = "page.customers";
  public const string Stocks = "page.stocks";
  public const string Prices = "page.prices";
  public const string Checks = "page.checks";
  public const string CatalogSettings = "page.catalog-settings";
  public const string Rules = "page.rules";
  public const string System = "page.system";
  public const string Administration = "page.administration";

  public static readonly IReadOnlyList<PimPermissionDefinition> All =
  [
    Page(Dashboard, "Nadzorna plošča", "Operativni pregled celotnega podatkovnega toka.", "nadzorna-plosca", "Nadzor"),

    Page(Ingest, "Zajem podatkov", "Viri, teki in težave pri prevzemu podatkov.", "zajem", "Vhodni podatki"),
    View("tab.ingest.overview", "Vhodi", "Viri, stanje in svežina.", "zajem", Ingest, true),
    View("tab.ingest.runs", "Teki", "Izvedbe, koraki in dnevnik obdelave.", "zajem/teki", Ingest, true),
    View("tab.ingest.issues", "Težave", "Napake, karantena in čakalne vrste.", "zajem/tezave", Ingest, true),
    View("view.ingest.candidates", "Novi artikli", "Kandidati dobaviteljev pred sprejemom.", "zajem/novi-artikli", Ingest),
    View("view.ingest.queue", "Čakalna vrsta", "Zapisi, ki še čakajo na obdelavo.", "zajem/cakalna-vrsta", Ingest),
    View("view.ingest.unmapped", "Neujemanja", "Neprepoznane vrednosti in preslikave.", "zajem/neujemanja", Ingest),
    View("view.ingest.attributes", "Atributi vira", "Odkriti atributi vhodnih virov.", "zajem/atributi", Ingest),

    Page(Products, "Izdelki", "Delovni seznam in kartice izdelkov.", "izdelki", "PIM katalog"),
    View("view.products.list", "Seznam in kartica", "Iskanje, pregled ter podrobnosti izdelka.", "izdelki", Products),
    View("view.products.import", "Uvoz delovnega zvezka", "Množično urejanje iz Excela.", "izdelki/uvoz", Products),
    View("view.products.categories", "Kategorije izdelka", "Uvrstitev izdelkov v kategorije.", "izdelki/kategorije", Products),
    Page(Media, "Mediji", "Slike in dokumenti izdelkov.", "mediji", "PIM katalog"),

    Page(Quality, "Kakovost podatkov", "Popravki, blokade in manjkajoče vrednosti.", "kakovost", "Kakovost"),
    View("tab.quality.products", "Artikli za popravilo", "Pripravljenost in blokade po kanalih.", "kakovost/artikli", Quality, true),
    View("tab.quality.validation", "Napake validacije", "Izdelek obstaja, a mu manjka zahtevano polje.", "kakovost/napake", Quality, true),
    View("tab.quality.quarantine", "Napake uvoza", "Zapisi, ki jih preslikava ni sprejela.", "kakovost/karantena", Quality, true),
    View("tab.quality.translations", "Manjkajoči prevodi", "Vrednosti brez zahtevanega prevoda.", "kakovost/prevodi", Quality, true),
    View("tab.quality.categories", "Nepreslikane kategorije", "Dobaviteljeve poti brez naše kategorije.", "kakovost/kategorije", Quality, true),
    View("tab.quality.by-category", "Po kategorijah", "Odprte zahteve po kategorijskem drevesu.", "kakovost?pogled=kategorije", Quality, true),
    View("view.quality.profiles", "Validacijski profili", "Pregled profilov in njihovih zahtev.", "kakovost?pogled=profili", Quality),

    Page(Saop, "Izhod v SAOP", "Nadzorovani zapisi nazaj v ERP.", "saop/artikli", "Izhodi ERP in splet"),
    View("tab.saop.items", "Artikli", "Nov artikel in sprememba.", "saop/artikli", Saop, true),
    View("tab.saop.queue", "Čakalna vrsta", "Odobritev in ponovni poskus.", "outbound", Saop, true),
    View("tab.saop.history", "Zgodovina", "Operacija in odgovor ERP.", "saop/zgodovina", Saop, true),
    View("tab.saop.overview", "Pregled", "Stanje po vrstah entitet.", "saop", Saop, true),
    View("view.saop.drifts", "Odkloni", "Odstopanja med PIM in ERP.", "saop/odkloni", Saop),
    View("view.saop.fields", "Polja SAOP", "Pregled pogodbe polj.", "saop/polja", Saop),

    Page(Web, "Izhod na splet", "Datoteke in nadzor spletnega kataloga.", "splet", "Izhodi ERP in splet"),
    View("view.web.overview", "Datoteke in dostave", "Predogled datotek ter zgodovina dostav.", "splet", Web),
    View("view.web.build", "Pripravi izvoz", "Ročna priprava spletnega izvoza.", "splet/izvoz", Web),
    View("view.web.catalog", "Nadzor kataloga", "Objava, odprodaja in blokade.", "splet/katalog", Web),
    View("view.web.withdrawals", "Umaknjeni s spleta", "Artikli, ki jim je PIM odstranil kljukico spletišča, in razlog.", "splet/umaknjeni", Web),
    View("view.web.profiles", "Izvozni profili", "Stolpci posameznega izvoznega profila.", "izvozi/profili", Web),
    View("view.web.events", "Odhodna obvestila", "Napake in dogodki spletnega izvoza.", "izvozi/obvestila", Web),
    View("view.web.bulk", "Množični izhod", "Množična priprava odhodnih podatkov.", "izvozi/mnozicno", Web),

    Page(Customers, "Stranke", "Kupci, dobavitelji in proizvajalci.", "stranke", "Poslovanje"),
    View("view.customers.list", "Stranke in kartice", "Seznam ter podrobnosti strank.", "stranke", Customers),
    Page(Stocks, "Zaloga", "Količine, svežina in razpoložljivost.", "zaloge", "Poslovanje"),
    Page(Prices, "Cene in ceniki", "Cene, ceniki in tisk.", "cene", "Poslovanje"),
    Page(Checks, "Preverbe cen in zaloge", "Opozorila o cenah, maržah in zalogi.", "preverbe", "Poslovanje"),

    Page(CatalogSettings, "Nastavitve kataloga", "Šifranti in strukture kataloga.", "nastavitve", "Upravljanje"),
    View("view.catalog.attributes", "Atributi", "Šifrant atributov in prevodi.", "nastavitve/atributi", CatalogSettings),
    View("view.catalog.categories", "Kategorije", "Drevesa in vozlišča kategorij.", "nastavitve/kategorije", CatalogSettings),
    View("view.catalog.attribute-sets", "Nabori atributov", "Atributi po kategorijah.", "nastavitve/nabori-atributov", CatalogSettings),
    View("view.catalog.product-links", "Povezave izdelkov", "Variante, pribor in podobni izdelki.", "nastavitve/povezave-izdelkov", CatalogSettings),
    View("view.catalog.channels", "Spletni kanali", "Spletna mesta, jeziki in cilji.", "nastavitve/kanali", CatalogSettings),
    View("view.catalog.languages", "Jeziki", "Jezikovne šifre in preslikave.", "nastavitve/jeziki", CatalogSettings),
    View("view.catalog.warehouses", "Skladišča", "Šifranti skladišč po podjetjih.", "nastavitve/skladisca", CatalogSettings),
    View("view.catalog.reservations", "Rezervacija zaloge", "Izjeme pri rezervaciji zaloge.", "nastavitve/rezervacija-zaloge", CatalogSettings),

    Page(Rules, "Pravila in izvor podatkov", "Validacija, slovar in preslikave.", "pravila", "Upravljanje"),
    View("view.rules.validation", "Validacijski profili", "Obvezna polja, resnost in blokade.", "pravila/validacija", Rules, true),
    View("view.rules.dictionary", "Slovar vrednosti", "Prevodi in normalizacije vrednosti.", "pravila/slovar", Rules, true),
    View("view.rules.mappings", "Izvor in preslikave", "Izvorna in ciljna polja.", "pravila/preslikave", Rules, true),
    View("view.rules.discounts", "Komercialna pravila", "Popusti, pragovi in izjeme.", "pravila-popustov", Rules, true),
    View("view.rules.titles", "Spletni nazivi", "Sestava spletnih nazivov.", "pravila/nazivi", Rules, true),

    // Blok 7 prenove nadzora (2026-09-22): Opravila, Zagoni, Postopki, Alarmi, Izvozi, Zmogljivost in
    // Sistemske napake so odstranjeni — vse o poslu je na Nadzoru in strani posla (sistem/posel/<KEY>),
    // ki ju pokriva ista pravica. Osirotele ključe iz sec.RolePermission briše migracija 259 (259_NadzorPoslov.sql).
    Page(System, "Nadzor sistema", "Ali podatki prihajajo, kje je napaka in kaj narediti.", "sistem", "Administracija"),
    View("tab.system.overview", "Nadzor", "Posli, njihovi koraki, faze, izpis in urnik.", "sistem", System, true),
    View("view.system.self-test", "Samotest", "Rezultati nočnega samotesta.", "sistem/samotest", System, true),
    View("view.system.activity", "Sled sprememb", "Kdo je kaj spremenil in kdaj.", "sistem/sled", System, true),

    Page(Administration, "Sistemske zadeve", "Uporabniki, vloge in mesta shranjevanja.", "administracija", "Administracija"),
    View("tab.admin.users", "Uporabniki", "Lokalni in domenski računi.", "administracija", Administration, true),
    View("tab.admin.roles", "Vloge", "Vloge in dovoljenja za dostop.", "administracija/vloge", Administration, true),
    View("tab.admin.paths", "Mesta shranjevanja", "Kam gredo datoteke in izvozi.", "administracija/mape", Administration, true),
  ];

  public static IReadOnlyList<PimPermissionDefinition> Pages { get; } = All.Where(item => item.ParentKey is null).ToArray();
  public static IReadOnlySet<string> Keys { get; } = All.Select(item => item.Key).ToHashSet(StringComparer.Ordinal);

  public static IReadOnlyList<PimPermissionDefinition> ChildrenOf(string pageKey) =>
    All.Where(item => item.ParentKey == pageKey).ToArray();

  public static string? ParentOf(string key) =>
    All.FirstOrDefault(item => item.Key == key)?.ParentKey;

  /// <summary>Pravica za dejansko pot. Daljše in bolj določene poti imajo prednost.</summary>
  public static string? Resolve(string? baseRelativePath)
  {
    var raw = (baseRelativePath ?? "").Trim().TrimStart('/');
    var split = raw.Split('?', 2);
    var path = split[0].TrimEnd('/').ToLowerInvariant();
    var query = split.Length == 2 ? split[1].ToLowerInvariant() : "";

    if (path is "" or "prijava" or "brez-dostopa" or "error") return null;
    if (path == "nadzorna-plosca") return Dashboard;

    if (path == "administracija") return "tab.admin.users";
    if (path == "administracija/vloge") return "tab.admin.roles";
    if (path == "administracija/mape") return "tab.admin.paths";

    if (path == "sistem" || path.StartsWith("sistem/posel/", StringComparison.Ordinal)) return "tab.system.overview";
    if (path == "sistem/sled") return "view.system.activity";
    if (path == "sistem/samotest") return "view.system.self-test";

    if (path == "zajem") return "tab.ingest.overview";
    if (path.StartsWith("zajem/teki", StringComparison.Ordinal)) return "tab.ingest.runs";
    if (path.StartsWith("zajem/tezave", StringComparison.Ordinal)) return "tab.ingest.issues";
    if (path == "zajem/novi-artikli") return "view.ingest.candidates";
    if (path == "zajem/cakalna-vrsta") return "view.ingest.queue";
    if (path == "zajem/neujemanja") return "view.ingest.unmapped";
    if (path == "zajem/atributi") return "view.ingest.attributes";
    if (path.StartsWith("zajem/viri/", StringComparison.Ordinal)) return "tab.ingest.overview";

    if (path == "izdelki/uvoz") return "view.products.import";
    if (path == "izdelki/kategorije" || (path.StartsWith("izdelki/", StringComparison.Ordinal) && path.EndsWith("/kategorije", StringComparison.Ordinal))) return "view.products.categories";
    if (path == "izdelki" || path.StartsWith("izdelki/", StringComparison.Ordinal)) return "view.products.list";
    if (path == "mediji") return Media;

    if (path == "kakovost")
    {
      if (query.Contains("pogled=kategorije", StringComparison.Ordinal)) return "tab.quality.by-category";
      if (query.Contains("pogled=profili", StringComparison.Ordinal)) return "view.quality.profiles";
      return Quality;
    }
    if (path == "kakovost/artikli") return "tab.quality.products";
    if (path == "kakovost/napake") return "tab.quality.validation";
    if (path == "kakovost/karantena") return "tab.quality.quarantine";
    if (path == "kakovost/prevodi") return "tab.quality.translations";
    if (path == "kakovost/kategorije") return "tab.quality.categories";

    if (path == "saop/artikli") return "tab.saop.items";
    if (path == "outbound") return "tab.saop.queue";
    if (path == "saop/zgodovina") return "tab.saop.history";
    if (path == "saop") return "tab.saop.overview";
    if (path == "saop/odkloni") return "view.saop.drifts";
    if (path == "saop/polja") return "view.saop.fields";

    if (path == "splet") return "view.web.overview";
    if (path == "splet/izvoz") return "view.web.build";
    if (path == "splet/katalog") return "view.web.catalog";
    if (path == "splet/umaknjeni") return "view.web.withdrawals";
    if (path.StartsWith("izvozi/profili/", StringComparison.Ordinal)) return "view.web.profiles";
    if (path == "izvozi/obvestila") return "view.web.events";
    if (path == "izvozi/mnozicno") return "view.web.bulk";

    if (path == "stranke" || path.StartsWith("stranke/", StringComparison.Ordinal)) return "view.customers.list";
    if (path == "zaloge") return Stocks;
    if (path == "cene" || path == "cene/tisk" || path == "cene/uvoz") return Prices;
    if (path == "preverbe") return Checks;

    if (path == "nastavitve") return CatalogSettings;
    if (path.StartsWith("nastavitve/atributi", StringComparison.Ordinal)) return "view.catalog.attributes";
    if (path == "nastavitve/kategorije") return "view.catalog.categories";
    if (path == "nastavitve/nabori-atributov") return "view.catalog.attribute-sets";
    if (path == "nastavitve/povezave-izdelkov") return "view.catalog.product-links";
    if (path == "nastavitve/kanali") return "view.catalog.channels";
    if (path == "nastavitve/jeziki") return "view.catalog.languages";
    if (path == "nastavitve/skladisca") return "view.catalog.warehouses";
    if (path == "nastavitve/rezervacija-zaloge") return "view.catalog.reservations";

    if (path == "pravila") return Rules;
    if (path == "pravila/validacija") return "view.rules.validation";
    if (path == "pravila/slovar") return "view.rules.dictionary";
    if (path == "pravila/preslikave") return "view.rules.mappings";
    if (path == "pravila-popustov") return "view.rules.discounts";
    if (path == "pravila/nazivi") return "view.rules.titles";

    return "__unknown__";
  }

  static PimPermissionDefinition Page(string key, string name, string description, string route, string group) =>
    new(key, name, description, route, group);

  static PimPermissionDefinition View(string key, string name, string description, string route, string parentKey, bool isTab = false) =>
    new(key, name, description, route, "", parentKey, isTab);
}
