using PIM.SaopStockWorker;

var registry = SaopStockProviderRegistry.CreateDefault();

// Registrirani pogled je POST z XML telesom in stranjenjem (Swagger: ApiRegisteredView_GetDataFromRegisteredView).
// Do 2026-09-02 je test zahteval GET ?viewId=…, ki ga API ne pozna; zahteva se je spremenila, ker je
// uporabnik zalogo Vidadrie preusmeril na registrirani pogled (migracija 145).
var registered = registry.CreateRequest(new("RegisteredViewData","rv-stock",[], PageSize: 250, Page: 3), new Uri("https://example.invalid/"));
Equal("api/registeredviews/data", registered.RequestUri!.AbsolutePath.TrimStart('/'), "RegisteredView endpoint");
Equal(HttpMethod.Post, registered.Method, "RegisteredView mora biti POST");
var body = await registered.Content!.ReadAsStringAsync();
if (!body.Contains("<RegisteredViewID>rv-stock</RegisteredViewID>", StringComparison.Ordinal)) throw new InvalidOperationException("RegisteredViewId ni v telesu zahteve.");
if (!body.Contains("<ResultPageNumber>3</ResultPageNumber>", StringComparison.Ordinal)) throw new InvalidOperationException("Stran ni v telesu zahteve.");
if (!body.Contains("<ResultPageSize>250</ResultPageSize>", StringComparison.Ordinal)) throw new InvalidOperationException("Velikost strani ni v telesu zahteve.");
if (!body.Contains("<Filter />", StringComparison.Ordinal) || !body.Contains("<OrderBy />", StringComparison.Ordinal)) throw new InvalidOperationException("Prazna Filter/OrderBy morata biti samozakljucena, kot v delujoci zahtevi.");
Equal("application/xml", registered.Content.Headers.ContentType?.MediaType, "Telo mora biti application/xml");
// Brez izrecne velikosti strani velja privzeta 1000 (enako kot stari sistem).
var privzeta = await registry.CreateRequest(new("RegisteredViewData","rv-stock",[]), new Uri("https://example.invalid/")).Content!.ReadAsStringAsync();
if (!privzeta.Contains("<ResultPageSize>1000</ResultPageSize>", StringComparison.Ordinal)) throw new InvalidOperationException("Privzeta velikost strani ni 1000.");
Throws(() => registry.CreateRequest(new("RegisteredViewData",null,[]), new("https://example.invalid/")), "RegisteredViewId");
Throws(() => registry.CreateRequest(new("StockAdvance",null,[]), new("https://example.invalid/")), "warehouse");
Throws(() => registry.CreateRequest(new("GetStocks",null,[]), new("https://example.invalid/")), "warehouse");
var advance=registry.CreateRequest(new("StockAdvance",null,["0000004","0000008"]),new("https://example.invalid/"));
Equal("api/Stock/GetStockAdvance",advance.RequestUri!.AbsolutePath.TrimStart('/'),"Advance endpoint");

// Sifra skladisca mora ostati niz z vodilnimi niclami. Izmerjeno na zivem SAOP 2026-08-27:
// "0000003" vrne 138 zapisov, "3" pa HTTP 200 z enim praznim <Item>.
var stocks=registry.CreateRequest(new("GetStocks",null,["0000003","0000112"]),new("https://example.invalid/"));
if (!stocks.RequestUri!.Query.Contains("0000003", StringComparison.Ordinal))
  throw new InvalidOperationException("Vodilne nicle sifre skladisca so izgubljene.");
Equal(HttpMethod.Get, stocks.Method, "GetStocks ostane GET");
if (typeof(SaopStockProviderRegistry).GetMethods().Any(m=>m.Name.Contains("Organization",StringComparison.OrdinalIgnoreCase))) throw new InvalidOperationException("Registry vsebuje org vejo.");
Console.WriteLine("F6 SAOP: konfiguracijska izbira providerja in zahtev PASS.");

static void Equal<T>(T e,T a,string m){if(!EqualityComparer<T>.Default.Equals(e,a))throw new InvalidOperationException($"{m}: {a}");}
static void Throws(Action action,string expected){try{action();throw new InvalidOperationException("Pričakovana izjema.");}catch(InvalidOperationException e){if(!e.Message.Contains(expected,StringComparison.OrdinalIgnoreCase))throw;}}
