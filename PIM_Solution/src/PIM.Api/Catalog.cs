namespace PIM.Api;

public enum ParamType { String, Int, Bool, Date, DateTime, Decimal, List }

public enum EndpointKind
{
  /// <summary>Stran vrstic + skupno število (izhodni parameter @TotalCount).</summary>
  Paged,
  /// <summary>Vrstice brez listanja (povzetki, šifranti).</summary>
  Rows,
  /// <summary>Več naborov: prvi je en zapis, ostali so seznami pod imeni iz <see cref="EndpointDef.Sets"/>.</summary>
  Detail,
}

/// <summary>Parameter končne točke: ime v URL-ju (in v orodju MCP) in ime parametra postopka.</summary>
public sealed record ParamDef(string Name, string Sql, ParamType Type, string Description, bool Required = false, string[]? Values = null);

/// <summary>Nabor kartice (Detail). <see cref="Scope"/> = področje, brez katerega se nabor izpusti.</summary>
public sealed record SetDef(string Name, string? Scope = null);

public sealed record EndpointDef(
  string Path,
  string Tool,
  string Scope,
  string Procedure,
  EndpointKind Kind,
  string Summary,
  string Description,
  ParamDef[] Params,
  bool NeedsOrganization = true,
  bool HasLanguage = false,
  SetDef[]? Sets = null);

/// <summary>
/// Vse končne točke API-ja na enem mestu. Iz tega seznama nastanejo poti, preverjanje parametrov, opis
/// OpenAPI (/openapi.json), navodila za AI (/api/v1/guide) in orodja MCP (/mcp) — zato opis ne more zaostati
/// za kodo. Nova končna točka = nov postopek v shemi api (migracija) + ena vrstica tukaj.
/// </summary>
public static class Catalog
{
  public const string Version = "1.0";

  public static readonly string[] Scopes = ["izdelki", "cene", "zaloga", "stranke", "nabava", "analitika"];

  static ParamDef Search(string what) => new("search", "@Search", ParamType.String,
    $"Iskanje brez šumnikov in velikih črk po {what}. Več besed = vse morajo biti najdene.");
  static readonly ParamDef ItemIds = new("itemIds", "@ItemIds", ParamType.List, "Seznam šifer artiklov (ItemID), ločenih z vejico; natančno ujemanje, največ 500.");
  static readonly ParamDef Supplier = new("supplier", "@Supplier", ParamType.String, "Šifra dobavitelja (partnerja), npr. 00000320. Šifre vrne /api/v1/partners.");

  public static readonly EndpointDef[] Endpoints =
  [
    new("/api/v1/organizations", "list_organizations", "", "api.GetOrganizations", EndpointKind.Rows,
      "Podjetja", "Podjetja, do katerih ima ključ dostop, s številom izdelkov in strank. Vsi ostali klici zahtevajo organizationId.",
      [], NeedsOrganization: false),

    new("/api/v1/freshness", "data_freshness", "", "api.GetDataFreshness", EndpointKind.Rows,
      "Svežina podatkov", "Kdaj so bili podatki (zaloga po virih, cene, stranke, naročila, analitika) nazadnje osveženi in koliko ur so stari. Pred poročilom preveri, ali so podatki dovolj sveži.",
      []),

    new("/api/v1/partners", "list_partners", "izdelki", "api.GetPartners", EndpointKind.Rows,
      "Dobavitelji in proizvajalci", "Šifre in imena dobaviteljev ali proizvajalcev s številom izdelkov. Uporabi za pretvorbo imena v šifro za filter supplier.",
      [
        new("role", "@Role", ParamType.String, "dobavitelj (privzeto) ali proizvajalec.", Values: ["dobavitelj", "proizvajalec"]),
        Search("šifri ali imenu partnerja"),
      ]),

    new("/api/v1/products", "search_products", "izdelki", "api.SearchProducts", EndpointKind.Paged,
      "Iskanje izdelkov", "Seznam izdelkov z nazivom, dobaviteljem, lastno (ERP) zalogo, zalogo dobaviteljev ter nabavno, maloprodajno (B2C) in veleprodajno (B2B) ceno brez DDV.",
      [
        Search("šifri, EAN in nazivih"),
        ItemIds,
        new("ean", "@Ean", ParamType.String, "Natančen EAN."),
        Supplier,
        new("manufacturer", "@Manufacturer", ParamType.String, "Šifra proizvajalca (/api/v1/partners?role=proizvajalec)."),
        new("itemGroup", "@ItemGroup", ParamType.String, "Skupina artikla (npr. AZZARDO, VD0)."),
        new("department", "@Department", ParamType.String, "Oddelek."),
        new("isActive", "@IsActive", ParamType.Bool, "true = samo aktivni v ERP, false = samo neaktivni."),
        new("webPublish", "@WebPublish", ParamType.Bool, "true = samo izdelki s kljukico za splet."),
        new("inStock", "@InStock", ParamType.Bool, "true = samo z lastno zalogo > 0, false = samo brez zaloge."),
        new("sort", "@Sort", ParamType.String, "itemId (privzeto), name, stock (največ zaloge najprej), -stock.", Values: ["itemId", "name", "stock", "-stock"]),
      ], HasLanguage: true),

    new("/api/v1/products/detail", "get_product", "izdelki", "api.GetProduct", EndpointKind.Detail,
      "Kartica izdelka", "Vse o enem izdelku: osnovni in komercialni podatki, besedila v vseh jezikih, atributi, kategorije, cene po vseh cenikih, zaloga po virih, slike, dokumenti, odprta naročila dobaviteljem, ista šifra v drugih podjetjih, validacija.",
      [new("itemId", "@ItemId", ParamType.String, "Šifra artikla (ItemID).", Required: true)],
      HasLanguage: true,
      Sets:
      [
        new("product"), new("texts"), new("attributes"), new("categories"), new("prices", "cene"), new("stock", "zaloga"),
        new("media"), new("documents"), new("openPurchaseOrders", "nabava"), new("otherOrganizations"), new("validation"),
      ]),

    new("/api/v1/prices/lists", "list_price_lists", "cene", "api.GetPriceLists", EndpointKind.Rows,
      "Ceniki", "Ceniki podjetja (šifra, ime, število izdelkov, zadnja veljavnost, napovedane cene) in kateri cenik je maloprodajni (PriceB2C) oziroma veleprodajni (PriceB2B). NAB = nabavni, PRC = prevzemni.",
      []),

    new("/api/v1/prices", "search_prices", "cene", "api.GetPrices", EndpointKind.Paged,
      "Cene", "Veljavne cene brez DDV po cenikih, z bruto ceno, prejšnjo ceno in odstotkom spremembe. changedSince = poročilo o spremembah cen od datuma.",
      [
        new("priceList", "@PriceList", ParamType.String, "Šifra cenika (B2C, B2B, NAB, PRC …). Brez = vsi ceniki."),
        Search("šifri in nazivu"),
        ItemIds,
        Supplier,
        new("changedSince", "@ChangedSince", ParamType.Date, "Samo cene, ki veljajo od tega dne naprej (yyyy-MM-dd)."),
        new("includeFuture", "@IncludeFuture", ParamType.Bool, "true = dodaj še napovedane cene z veljavnostjo v prihodnosti."),
      ], HasLanguage: true),

    new("/api/v1/prices/history", "price_history", "cene", "api.GetPriceHistory", EndpointKind.Rows,
      "Zgodovina cen", "Vse cene enega artikla skozi čas po cenikih, z odstotkom spremembe glede na prejšnjo.",
      [
        new("itemId", "@ItemId", ParamType.String, "Šifra artikla.", Required: true),
        new("priceList", "@PriceList", ParamType.String, "Samo ta cenik."),
      ]),

    new("/api/v1/prices/comparison", "price_margin_comparison", "cene", "api.GetPriceComparison", EndpointKind.Paged,
      "Primerjava cen (marža)", "Prodajna cena proti nabavni: faktor (prodajna / nabavna), marža v % in ali je faktor pod pragom FAKTOR_MARZE (privzeto 2).",
      [
        new("sellList", "@SellList", ParamType.String, "Prodajni cenik (privzeto B2C)."),
        new("costList", "@CostList", ParamType.String, "Nabavni cenik (privzeto NAB)."),
        new("minFactor", "@MinFactor", ParamType.Decimal, "Samo faktor >= te vrednosti."),
        new("maxFactor", "@MaxFactor", ParamType.Decimal, "Samo faktor <= te vrednosti."),
        new("belowThreshold", "@BelowThreshold", ParamType.Bool, "true = samo pod pragom marže, false = samo nad njim."),
        Supplier,
        new("onlyActive", "@OnlyActive", ParamType.Bool, "Samo aktivni izdelki (privzeto true)."),
        new("sort", "@Sort", ParamType.String, "factor (najnižji najprej, privzeto), -factor, itemId.", Values: ["factor", "-factor", "itemId"]),
      ], HasLanguage: true),

    new("/api/v1/stock", "search_stock", "zaloga", "api.GetStock", EndpointKind.Paged,
      "Zaloga", "Zaloga po izdelkih iz zadnjih posnetkov: lastna ERP zaloga (trenutna, rezervirana za kupce, za odpremo, razpoložljiva, naročena pri dobaviteljih), zaloga dobaviteljev (NW, Braytron), MIN/MAX iz SAOP in vrednost po nabavni ceni.",
      [
        new("source", "@Source", ParamType.String, "ERP (privzeto, lastna zaloga), DOBAVITELJ, VSE.", Values: ["ERP", "DOBAVITELJ", "VSE"]),
        Search("šifri, EAN in nazivu"),
        ItemIds,
        Supplier,
        new("itemGroup", "@ItemGroup", ParamType.String, "Skupina artikla."),
        new("onlyPositive", "@OnlyPositive", ParamType.Bool, "true = samo zaloga > 0."),
        new("onlyNegative", "@OnlyNegative", ParamType.Bool, "true = samo negativna ERP zaloga (napaka v evidenci)."),
        new("belowMinimum", "@BelowMinimum", ParamType.Bool, "true = ERP zaloga pod minimalno zalogo iz SAOP (vključno z artikli brez zaloge)."),
        new("onlyActive", "@OnlyActive", ParamType.Bool, "true = samo aktivni izdelki."),
        new("sort", "@Sort", ParamType.String, "-quantity (največ najprej, privzeto), quantity, itemId.", Values: ["-quantity", "quantity", "itemId"]),
      ], HasLanguage: true),

    new("/api/v1/stock/summary", "stock_summary", "zaloga", "api.GetStockSummary", EndpointKind.Rows,
      "Povzetek zaloge", "Količina in vrednost lastne zaloge (po nabavni in maloprodajni ceni) skupno ali po dobavitelju, proizvajalcu, skupini ali oddelku; tudi število artiklov z negativno zalogo in brez nabavne cene.",
      [
        new("groupBy", "@GroupBy", ParamType.String, "skupno (privzeto), dobavitelj, proizvajalec, skupina, oddelek.", Values: ["skupno", "dobavitelj", "proizvajalec", "skupina", "oddelek"]),
        new("top", "@Top", ParamType.Int, "Največ skupin (privzeto 100, največ 1000), razvrščeno po vrednosti."),
      ]),

    new("/api/v1/customers", "search_customers", "stranke", "api.SearchCustomers", EndpointKind.Paged,
      "Stranke", "Stranke iz SAOP: naslov, davčna, cenik, skupina popustov, plačilni rok, rabat, komercialist, število artiklov stranke.",
      [
        Search("imenu, šifri, davčni, matični, kraju"),
        new("isActive", "@IsActive", ParamType.Bool, "true = samo aktivne."),
        new("customerType", "@CustomerType", ParamType.String, "Tip stranke iz SAOP (O, K, S, D)."),
        new("priceList", "@PriceList", ParamType.String, "Cenik stranke (B2B, B2C …)."),
        new("salesClerk", "@SalesClerk", ParamType.String, "Šifra komercialista."),
        new("city", "@City", ParamType.String, "Kraj (natančno, brez šumnikov)."),
        new("country", "@Country", ParamType.String, "Država (SI, HR, AT …)."),
      ]),

    new("/api/v1/customers/detail", "get_customer", "stranke", "api.GetCustomer", EndpointKind.Detail,
      "Kartica stranke", "Ena stranka: podatki, veljavni popusti po skupinah artiklov in artikli stranke (njene šifre, cene, minimalne količine).",
      [new("customerKey", "@CustomerKey", ParamType.String, "Šifra stranke v SAOP.", Required: true)],
      HasLanguage: true,
      Sets: [new("customer"), new("groupDiscounts"), new("customerItems")]),

    new("/api/v1/purchase-orders", "purchase_order_lines", "nabava", "api.GetPurchaseOrderLines", EndpointKind.Paged,
      "Naročila dobaviteljem", "Vrstice naročil dobaviteljem: kaj je naročeno, pri kom, kdaj pride, ali zamuja. Privzeto samo odprta.",
      [
        Supplier,
        new("itemId", "@ItemId", ParamType.String, "Šifra artikla."),
        new("status", "@Status", ParamType.String, "Status naročila (Odprt, Delno, Potrjeno, Poslano, Zaključeno, Stornirano)."),
        new("openOnly", "@OpenOnly", ParamType.Bool, "true (privzeto) = brez zaključenih, storniranih in preklicanih vrstic."),
        new("dueBefore", "@DueBefore", ParamType.Date, "Predviden prevzem pred tem dnem (yyyy-MM-dd)."),
        new("orderedSince", "@OrderedSince", ParamType.Date, "Naročeno od tega dne (yyyy-MM-dd)."),
      ]),

    new("/api/v1/analytics/items", "item_metrics", "analitika", "api.GetItemMetrics", EndpointKind.Paged,
      "Analitika artiklov", "Izračunani kazalniki (posel SAOP_ANALYTICS): prodaja 30/90/365 dni, trend, pokritost v dneh, ABC/XYZ, varnostna zaloga, predlog naročila, zaležana zaloga. Prazno, dokler posel ne teče.",
      [
        new("signal", "@Signal", ParamType.String, "Signal artikla iz izračuna."),
        new("abcClass", "@AbcClass", ParamType.String, "A, B ali C.", Values: ["A", "B", "C"]),
        Supplier,
        Search("šifri in nazivu"),
        new("onlySuggested", "@OnlySuggested", ParamType.Bool, "true = samo artikli s predlogom naročila."),
        new("sort", "@Sort", ParamType.String, "-suggestedValue (privzeto), -sales365, -excessValue, -stockValue, coverDays.",
          Values: ["-suggestedValue", "-sales365", "-excessValue", "-stockValue", "coverDays"]),
      ]),

    new("/api/v1/analytics/suppliers", "supplier_metrics", "analitika", "api.GetSupplierMetrics", EndpointKind.Rows,
      "Analitika dobaviteljev", "Kazalniki po dobaviteljih: vrednost zaloge, prodaja 365 dni in lani, marža, predlog naročila, zaležana zaloga, dobavni čas, zamude.",
      [new("top", "@Top", ParamType.Int, "Največ dobaviteljev (privzeto 200).")]),
  ];

  public static EndpointDef? ByPath(string path) =>
    Endpoints.FirstOrDefault(e => string.Equals(e.Path, path.TrimEnd('/'), StringComparison.OrdinalIgnoreCase));

  public static EndpointDef? ByTool(string tool) =>
    Endpoints.FirstOrDefault(e => string.Equals(e.Tool, tool, StringComparison.Ordinal));

  /// <summary>Vsi parametri, ki jih končna točka sprejme (vključno s skupnimi).</summary>
  public static IEnumerable<ParamDef> AllParams(EndpointDef endpoint)
  {
    if (endpoint.NeedsOrganization)
      yield return new("organizationId", "@OrganizationId", ParamType.Int,
        "Podjetje (številka iz /api/v1/organizations). Obvezno, razen če ima ključ dostop do enega samega podjetja.");
    foreach (var parameter in endpoint.Params) yield return parameter;
    if (endpoint.HasLanguage)
      yield return new("lang", "@Lang", ParamType.String, "Jezik nazivov: sl (privzeto), en, de, hr, it.");
    if (endpoint.Kind == EndpointKind.Paged)
    {
      yield return new("skip", "@Skip", ParamType.Int, "Koliko zadetkov preskočiti (listanje), privzeto 0.");
      yield return new("take", "@Take", ParamType.Int, "Koliko zadetkov vrniti, privzeto 50–100, največ 500–1000.");
    }
  }
}
