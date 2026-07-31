using PIM.SaopStockWorker;

var registry = SaopStockProviderRegistry.CreateDefault();
var registered = registry.CreateRequest(new("RegisteredViewData","rv-stock",[]), new Uri("https://example.invalid/"));
Equal("api/registeredviews/data", registered.RequestUri!.AbsolutePath.TrimStart('/'), "RegisteredView endpoint");
if (!registered.RequestUri.Query.Contains("viewId=rv-stock", StringComparison.Ordinal)) throw new InvalidOperationException("RegisteredViewId ni v zahtevi.");
Throws(() => registry.CreateRequest(new("RegisteredViewData",null,[]), new("https://example.invalid/")), "RegisteredViewId");
Throws(() => registry.CreateRequest(new("StockAdvance",null,[]), new("https://example.invalid/")), "warehouse");
Throws(() => registry.CreateRequest(new("GetStocks",null,[]), new("https://example.invalid/")), "warehouse");
var advance=registry.CreateRequest(new("StockAdvance",null,[4,8]),new("https://example.invalid/"));
Equal("api/Stock/GetStockAdvance",advance.RequestUri!.AbsolutePath.TrimStart('/'),"Advance endpoint");
if (typeof(SaopStockProviderRegistry).GetMethods().Any(m=>m.Name.Contains("Organization",StringComparison.OrdinalIgnoreCase))) throw new InvalidOperationException("Registry vsebuje org vejo.");
Console.WriteLine("F6 SAOP: konfiguracijska izbira providerja in zahtev PASS.");

static void Equal<T>(T e,T a,string m){if(!EqualityComparer<T>.Default.Equals(e,a))throw new InvalidOperationException($"{m}: {a}");}
static void Throws(Action action,string expected){try{action();throw new InvalidOperationException("Pričakovana izjema.");}catch(InvalidOperationException e){if(!e.Message.Contains(expected,StringComparison.OrdinalIgnoreCase))throw;}}
