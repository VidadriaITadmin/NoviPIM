using System.Text.RegularExpressions;
using Microsoft.Data.SqlClient;
using PIM.Intranet.Services;
using PIM.SaopAnalyticsWorker;

// Analitika prodaje, zalog in nabave (migracija 284):
//   A1  razčlenjevalnik SAOP odgovorov (računi, Barkawi CO/PO/SKU) — tudi z imenskim prostorom, atributi in vejico
//   A2  pravice, meni in politika (samo ADMIN in COMMERCIAL privzeto; zapis nastavitev skozi politiko)
//   A3  pogodba strani /analitika* (dostopnost, stanja, brez Bootstrapa, base-relativne povezave)
//   A4  formula v bazi: izmišljena prodaja v transakciji, ki se na koncu razveljavi (samo razvojna baza)

var failures = 0;
var passed = 0;
void Check(string name, bool condition, string? detail = null)
{
  if (condition) { passed++; Console.WriteLine($"  OK   {name}"); }
  else { failures++; Console.WriteLine($"  NAPAKA {name}{(detail is null ? "" : " — " + detail)}"); }
}

// ─── A1 razčlenjevalnik ──────────────────────────────────────────────────────
Console.WriteLine("A1 razčlenjevalnik SAOP");
var invoicesXml = """
  <ArrayOfInvoice xmlns="http://schemas.datacontract.org/2004/07/Icenter">
    <Invoice>
      <InvoiceYear>2026</InvoiceYear><InvoiceBook>IR</InvoiceBook><InvoiceNumber>15</InvoiceNumber>
      <InvoiceDate>2026-09-01T00:00:00</InvoiceDate><CustomerID>0000123</CustomerID><RecipientTitle1>Elektro d.o.o.</RecipientTitle1>
      <CurrencyID>EUR</CurrencyID><Status>Izdan</Status><ModifiedTime>2026-09-02T10:11:12</ModifiedTime>
      <InvoiceLines>
        <InvoiceLine><LineNumber>1</LineNumber><ItemID>ABC-1</ItemID><Quantity>3</Quantity><Price>10.5</Price><NetAmount>31.50</NetAmount></InvoiceLine>
        <InvoiceLine><LineNumber>2</LineNumber><TextLine>Samo besedilo</TextLine></InvoiceLine>
        <InvoiceLine LineNumber="3"><ItemID>XYZ</ItemID><Quantity>1,5</Quantity><NetAmount>12,30</NetAmount></InvoiceLine>
      </InvoiceLines>
    </Invoice>
    <Invoice><InvoiceYear>2026</InvoiceYear><InvoiceBook>IR</InvoiceBook><InvoiceNumber>16</InvoiceNumber><InvoiceDate>2026-09-03</InvoiceDate></Invoice>
  </ArrayOfInvoice>
  """;
var invoices = AnalyticsParsers.ParseInvoices(AnalyticsParsers.Parse(invoicesXml, "test"));
Check("dva računa, dve vrstici z artiklom (besedilna vrstica izpuščena)", invoices.Invoices == 2 && invoices.Lines.Count == 2, $"{invoices.Invoices}/{invoices.Lines.Count}");
Check("račun brez vrstic gre na klic po ključu", invoices.WithoutLines.SingleOrDefault() == new InvoiceKey(2026, "IR", 16));
var first = invoices.Lines[0];
Check("polja glave in vrstice", first.CustomerId == "0000123" && first.CustomerName == "Elektro d.o.o." && first.Quantity == 3 && first.NetAmount == 31.50m
  && first.InvoiceDate == new DateTime(2026, 9, 1) && first.SourceModifiedUtc == new DateTime(2026, 9, 2, 10, 11, 12));
Check("atribut LineNumber in decimalna vejica", invoices.Lines[1].LineNumber == 3 && invoices.Lines[1].Quantity == 1.5m && invoices.Lines[1].NetAmount == 12.30m);

var coXml = """
  <CO><CUSTOMER_ORDERS><CUSTOMER_ORDER>
    <CUSTOMER_ORDER_ID>2026-VNK-7</CUSTOMER_ORDER_ID><ORDER_TYPE>VNK</ORDER_TYPE><ORDER_DATE>2026-08-10</ORDER_DATE><CUSTOMER_ID>0000999</CUSTOMER_ID>
    <ORDER_LINES>
      <ORDER_LINE><ORDER_LINE_NUMBER>1</ORDER_LINE_NUMBER><DEALER_ITEM_ID>ABC-1</DEALER_ITEM_ID><REQUESTED_QUANTITY>10</REQUESTED_QUANTITY><SHIPPED_QUANTITY>8</SHIPPED_QUANTITY><SHIPED_DATE>2026-08-12</SHIPED_DATE></ORDER_LINE>
      <ORDER_LINE><ORDER_LINE_NUMBER>2</ORDER_LINE_NUMBER><DEALER_ITEM_ID></DEALER_ITEM_ID></ORDER_LINE>
    </ORDER_LINES>
  </CUSTOMER_ORDER></CUSTOMER_ORDERS></CO>
  """;
var co = AnalyticsParsers.ParseCustomerOrders(AnalyticsParsers.Parse(coXml, "co"), out var coOrders);
Check("Barkawi CO: eno naročilo, ena vrstica z artiklom", coOrders == 1 && co.Count == 1 && co[0].ShippedQty == 8 && co[0].ShippedDate == new DateTime(2026, 8, 12)
  && co[0].OrderId == "2026-VNK-7" && co[0].CustomerId == "0000999");

var poXml = """
  <PO><PURCHASE_ORDERS><PURCHASE_ORDER>
    <PURCHASE_ORDER_ID>2026-VND-3</PURCHASE_ORDER_ID><PURCHASE_ORDER_DATE>2026-07-01</PURCHASE_ORDER_DATE><SUPPLIER>0001209</SUPPLIER>
    <PURCHASE_ORDER_LINES><PURCHASE_ORDER_LINE><ORDER_LINE_NUMBER>1</ORDER_LINE_NUMBER><DEALER_ITEM_ID>ABC-1</DEALER_ITEM_ID>
      <REQUESTED_QUANTITY>100</REQUESTED_QUANTITY><RECEIVED_QUANTITY>100</RECEIVED_QUANTITY><RECEIVED_DATE>2026-07-29</RECEIVED_DATE></PURCHASE_ORDER_LINE></PURCHASE_ORDER_LINES>
  </PURCHASE_ORDER></PURCHASE_ORDERS></PO>
  """;
var po = AnalyticsParsers.ParsePurchaseOrders(AnalyticsParsers.Parse(poXml, "po"), out var poOrders);
Check("Barkawi PO: datum prevzema in dobavitelj", poOrders == 1 && po.Count == 1 && po[0].ReceivedDate == new DateTime(2026, 7, 29) && po[0].SupplierId == "0001209");

var skuXml = """
  <SKU><Item><DEALER_ITEM_ID>ABC-1</DEALER_ITEM_ID><PREFERRED_SUPPLIER>0001209</PREFERRED_SUPPLIER><AVARAGE_PURCHASE_PRICE>4.25</AVARAGE_PURCHASE_PRICE>
    <LAST_PURCHASE_PRICE>4.40</LAST_PURCHASE_PRICE><MULTIPLES>0</MULTIPLES></Item></SKU>
  """;
var sku = AnalyticsParsers.ParseSku(AnalyticsParsers.Parse(skuXml, "sku"));
Check("Barkawi SKU: cena in večkratnik 0 = brez", sku.Count == 1 && sku[0].AveragePurchasePrice == 4.25m && sku[0].OrderMultiple is null);
Check("datum 0001-01-01 ni datum", AnalyticsParsers.Date("0001-01-01T00:00:00") is null && AnalyticsParsers.Date("24.09.2026") == new DateTime(2026, 9, 24));
Check("neveljaven XML da razumljivo napako", Throws(() => AnalyticsParsers.Parse("<a>", "GetInvoices")));

// ─── A2 pravice ──────────────────────────────────────────────────────────────
Console.WriteLine("A2 pravice in meni");
foreach (var (path, key) in new[] { ("analitika", "tab.analytics.overview"), ("analitika/artikli", "tab.analytics.items"), ("analitika/artikli/48200", "tab.analytics.items"),
  ("analitika/dobavitelji", "tab.analytics.suppliers"), ("analitika/nastavitve", "tab.analytics.settings") })
  Check($"pot {path} zahteva {key}", PimAccessCatalog.Resolve(path) == key, PimAccessCatalog.Resolve(path));
Check("zavihki analitike spadajo pod page.analytics", PimAccessCatalog.ChildrenOf(PimAccessCatalog.Analytics).Count == 4
  && PIM.Intranet.Components.Shared.AnalyticsTabs.Tabs.All(t => PimAccessCatalog.Resolve(t.Href) == t.PermissionKey));
var navItem = PimNavigation.Sections.SelectMany(s => s.Items).SingleOrDefault(i => i.Route == "analitika");
Check("meni: Analitika samo za ADMIN in COMMERCIAL", navItem?.Roles is { } roles && roles.OrderBy(r => r).SequenceEqual(["ADMIN", "COMMERCIAL"]));
Check("politika nastavitev: ADMIN in COMMERCIAL, ne VIEWER", PimPolicies.RolesFor(PimPolicies.AnalyticsSettings).OrderBy(r => r).SequenceEqual(["ADMIN", "COMMERCIAL"]));

// ─── A3 pogodba strani ───────────────────────────────────────────────────────
Console.WriteLine("A3 strani");
var root = Directory.GetCurrentDirectory();
while (root.Length > 0 && !File.Exists(Path.Combine(root, "PIM.sln"))) root = Path.GetDirectoryName(root) ?? "";
var pages = Path.Combine(root, "src", "PIM.Intranet", "Components", "Pages");
foreach (var name in new[] { "AnalyticsHome", "AnalyticsItems", "AnalyticsItemCard", "AnalyticsSuppliers", "AnalyticsSettingsPage" })
{
  var markup = File.ReadAllText(Path.Combine(pages, name + ".razor"));
  Check($"{name}: omejen na vlogi", markup.Contains("@attribute [Authorize(Roles = \"ADMIN,COMMERCIAL\")]"));
  Check($"{name}: PimPage z izbiro podjetja in PimState", markup.Contains("<PimPage") && markup.Contains("OrganizationScope=\"true\"") && markup.Contains("<PimState"));
  Check($"{name}: vsaka tabela ima <caption>", Regex.Matches(markup, "<table").Count == Regex.Matches(markup, "<caption").Count);
  Check($"{name}: potrditvena polja imajo aria-label ali oznako", !Regex.IsMatch(markup, "(?<!<label class=\"check-field\">)<input type=\"checkbox\"(?![^>]*aria-label)"));
  Check($"{name}: brez Bootstrapa", !Regex.IsMatch(markup, "class=\"(?:[^\"]*\\s)?(btn|row|col-[\\w-]+|form-control|card-body)(?:\\s[^\"]*)?\""));
  Check($"{name}: povezave so base-relativne", !Regex.IsMatch(markup, "href=\"/"));
}
// 120: ob praznih ana.* je bil preklop podjetja neviden (vsa podjetja enako prazno stanje) — prazno stanje mora imenovati podjetje.
foreach (var name in new[] { "AnalyticsHome", "AnalyticsItems", "AnalyticsSuppliers" })
{
  var markup = File.ReadAllText(Path.Combine(pages, name + ".razor"));
  Check($"{name}: prazno stanje imenuje izbrano podjetje", markup.Contains("EmptyText=\"@EmptyText\"")
    && Regex.IsMatch(markup, @"string EmptyText =>[\s\S]{0,400}\{OrganizationName\}") && markup.Contains("OrganizationName = organization.Name"));
}
Check("Pregled: stanje zajema iz SAOP je vidno tudi brez preračuna", Regex.IsMatch(File.ReadAllText(Path.Combine(pages, "AnalyticsHome.razor")),
  @"</PimState>[\s\S]*aria-labelledby=""ana-streams"""));
var items = File.ReadAllText(Path.Combine(pages, "AnalyticsItems.razor"));
Check("Artikli: označi vse na strani in vse po filtru, izvoz izbranih", items.Contains("Označi vse na tej strani") && items.Contains("ki ustrezajo filtru")
  && items.Contains("Izvozi izbrane v Excel") && items.Contains("<PimPager"));
var settings = File.ReadAllText(Path.Combine(pages, "AnalyticsSettingsPage.razor"));
Check("Nastavitve: opozorilo ob odhodu, gumb onemogočen med shranjevanjem, samo za branje",
  settings.Contains("<NavigationLock") && settings.Contains("disabled=\"@(Saving") && settings.Contains("Samo za branje"));

// ─── A4 formula v bazi ───────────────────────────────────────────────────────
Console.WriteLine("A4 formula v bazi");
var connectionString = Environment.GetEnvironmentVariable("PIM_CONNECTION_STRING")
  ?? "Server=DAVID\\MSSQL19;Database=PIM;Integrated Security=True;Encrypt=True;TrustServerCertificate=True";
var server = new SqlConnectionStringBuilder(connectionString).DataSource;
if (!server.Equals("DAVID\\MSSQL19", StringComparison.OrdinalIgnoreCase) && Environment.GetEnvironmentVariable("PIM_F12_DB") != "1")
{
  Console.WriteLine($"  preskočeno: {server} ni razvojna baza (za drugo nastavi PIM_F12_DB=1; nikoli produkcija)");
}
else
{
  await using var connection = new SqlConnection(connectionString);
  await connection.OpenAsync();
  await using var transaction = (SqlTransaction)await connection.BeginTransactionAsync();
  async Task<T?> Scalar<T>(string sql)
  {
    await using var command = new SqlCommand(sql, connection, transaction) { CommandTimeout = 600 };
    var value = await command.ExecuteScalarAsync();
    return value is null or DBNull ? default : (T)Convert.ChangeType(value, Nullable.GetUnderlyingType(typeof(T)) ?? typeof(T));
  }
  async Task Exec(string sql)
  {
    await using var command = new SqlCommand(sql, connection, transaction) { CommandTimeout = 600 };
    await command.ExecuteNonQueryAsync();
  }
  try
  {
    // Artikel z zalogo 20–200 v podjetju 3; 24 mesecev po 30 kosov, zadnji mesec 80.
    await Exec("EXEC ana.CaptureStockDaily @OrganizationId = 3, @Quiet = 1;");
    var productId = await Scalar<long?>("SELECT TOP 1 d.ProductId FROM ana.StockDaily d WHERE d.OrganizationId = 3 AND d.SnapshotDate = CONVERT(date, SYSDATETIME()) AND d.Quantity BETWEEN 20 AND 200 ORDER BY d.ProductId");
    Check("razvojna baza ima zalogo za test", productId is not null);
    if (productId is { } pid)
    {
      await Exec($"""
        DECLARE @item nvarchar(100) = (SELECT ItemID FROM canon.Product WHERE ProductId = {pid});
        DECLARE @j nvarchar(max) = (
          SELECT InvoiceYear = YEAR(d), InvoiceBook = N'F12', InvoiceNumber = n, LineNumber = 1, InvoiceDate = d, CustomerId = N'F12K', ItemId = @item,
                 Quantity = CASE WHEN n = 0 THEN 80 ELSE 30 END, NetAmount = CASE WHEN n = 0 THEN 800 ELSE 300 END, CurrencyId = N'EUR'
          FROM (SELECT n, d = DATEADD(month, -n, DATEADD(day, -1, CONVERT(date, SYSDATETIME())))
                FROM (VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9),(10),(11),(12),(13),(14),(15),(16),(17),(18),(19),(20),(21),(22),(23)) v(n)) x
          FOR JSON PATH);
        EXEC ana.UpsertSalesInvoiceLines @OrganizationId = 3, @Json = @j;
        EXEC ana.UpsertSalesInvoiceLines @OrganizationId = 3, @Json = @j;
        EXEC ana.RefreshAnalytics @OrganizationId = 3;
        """);
      Check("ponovljen zapis računov ne podvoji vrstic", await Scalar<int>("SELECT COUNT(*) FROM ana.SalesInvoiceLine WHERE OrganizationId = 3 AND InvoiceBook = N'F12'") == 24);
      Check("vir prodaje so računi", await Scalar<string>($"SELECT DemandSource FROM ana.ItemMetric WHERE OrganizationId = 3 AND ProductId = {pid}") == "RACUNI");
      var s365 = await Scalar<decimal>($"SELECT Sales365Qty FROM ana.ItemMetric WHERE OrganizationId = 3 AND ProductId = {pid}");
      Check("prodano 365 dni = 11 × 30 + 80 (+ mejni mesec)", s365 is >= 410 and <= 440, s365.ToString());
      var ok = await Scalar<int>($"""
        SELECT CASE WHEN ABS(ReorderPoint - (DailyDemand * LeadTimeDays + SafetyStock)) < 0.01
                     AND ABS(OrderUpToLevel - (DailyDemand * (LeadTimeDays + 30) + SafetyStock)) < 0.01
                     AND (SuggestedQty = 0 OR Available + OnOrder <= ReorderPoint OR PolicyMin IS NOT NULL) THEN 1 ELSE 0 END
        FROM ana.ItemMetric WHERE OrganizationId = 3 AND ProductId = {pid}
        """);
      Check("točka naročila in ciljna raven po formuli", ok == 1);
      Check("mesečni pregled vsebuje artikel", await Scalar<int>($"SELECT COUNT(*) FROM ana.ItemMonthly WHERE OrganizationId = 3 AND ProductId = {pid}") >= 24);
      Check("dobavitelj ima kazalnike", await Scalar<int>($"SELECT COUNT(*) FROM ana.SupplierMetric sm JOIN ana.ItemMetric im ON im.OrganizationId = sm.OrganizationId AND im.SupplierId = sm.SupplierId WHERE im.OrganizationId = 3 AND im.ProductId = {pid} AND sm.Sales365Net > 0") == 1);
    }
  }
  finally
  {
    await transaction.RollbackAsync();
  }
  await using var check = new SqlCommand("SELECT COUNT(*) FROM ana.SalesInvoiceLine WHERE InvoiceBook = N'F12'", connection);
  Check("test ni pustil podatkov v bazi", Convert.ToInt32(await check.ExecuteScalarAsync()) == 0);
  // Razveljavitev je vrnila tudi ana.ItemMetric v prejšnje stanje, preračun ostane tak, kot ga je naredil zadnji tek.
}

// ─── A5 zajem naročil po številkah (SaopOrdersWorker) ────────────────────────
// Lažen SAOP: dokumenti 1–5 in 8, številka 9 vrne 500, ostalo 404. Številka 3 je že v bazi (se ne kliče).
Console.WriteLine("A5 zajem naročil po številkah");
if (server.Equals("DAVID\\MSSQL19", StringComparison.OrdinalIgnoreCase) || Environment.GetEnvironmentVariable("PIM_F12_DB") == "1")
{
  var year = DateTime.Today.Year;
  var runId = Guid.NewGuid();
  var called = new List<int>();
  var handler = new FakeSaop(number =>
  {
    called.Add(number);
    return number is >= 1 and <= 5 or 8
      ? (200, $"<OrderHeader><OrderYear>{year}</OrderYear><OrderBook>F12</OrderBook><OrderNumber>{number}</OrderNumber><OrderLines /></OrderHeader>")
      : number == 9 ? (500, "Napaka strežnika") : (404, "");
  });
  var orderSettings = new PIM.SaopOrdersWorker.OrdersSettings
  {
    BaseUrl = "http://saop.test/", Username = "t", Password = "t", RetryMaxExtraAttempts = 0, DelayBetweenCallsMilliseconds = 0,
    SweepTailGap = 3, SweepHistoryGap = 3,
  };
  using var client = new PIM.SaopOrdersWorker.SaopOrdersApiClient(orderSettings, handler);
  var organization = new PIM.SaopOrdersWorker.SaopOrganization(1, "DEMO", "SAOP_DEMO");
  await using var connection = new SqlConnection(connectionString);
  await connection.OpenAsync();
  async Task Sql(string sql) { await using var c = new SqlCommand(sql, connection); await c.ExecuteNonQueryAsync(); }
  try
  {
    await Sql($"INSERT ops.PipelineRun (RunId, Pipeline, OrganizationId, Status) VALUES ('{runId}', N'F12_TEST', 1, N'Succeeded');");
    await Sql($"INSERT sales.OrderHeader (OrganizationId, OrderYear, OrderBook, OrderNumber) VALUES (1, {year}, N'F12', 3);");

    var history = await PIM.SaopOrdersWorker.OrderSweep.SweepAsync(client, connection, orderSettings, organization, runId, PIM.SaopOrdersWorker.OrderSweep.Sales, "F12", year);
    Check("zgodovina: najde 1, 2, 4, 5 in 8 (3 je že v bazi, luknja 6–7 ni konec)", history == 5, history.ToString());
    Check("zgodovina: znane številke ne kliče, ustavi se po 3 zaporednih manjkajočih", !called.Contains(3) && called.Max() == 11 && called.Count == 10,
      string.Join(",", called));

    called.Clear();
    var tail = await PIM.SaopOrdersWorker.OrderSweep.SweepAsync(client, connection, orderSettings, organization, runId, PIM.SaopOrdersWorker.OrderSweep.Sales, "F12", null);
    Check("redni tek: začne pri največji znani + 1", called.FirstOrDefault() == 4 && tail == 3, $"{string.Join(",", called)} → {tail}");

    await using var count = new SqlCommand($"SELECT COUNT(*) FROM raw.Inbox WHERE RunId = '{runId}' AND EntityType = N'GetOrder'", connection);
    Check("dokumenti pristanejo v raw.Inbox za obstoječo preslikavo", Convert.ToInt32(await count.ExecuteScalarAsync()) >= 5);
  }
  finally
  {
    await Sql($"DELETE raw.Inbox WHERE RunId = '{runId}'; DELETE ops.PipelineRun WHERE RunId = '{runId}'; "
      + "DELETE sales.OrderHeader WHERE OrganizationId = 1 AND OrderBook = N'F12';");
  }
}

Console.WriteLine(failures == 0 ? $"F12 analitika PASS ({passed})." : $"F12 analitika: {failures} napak, {passed} uspešnih.");
return failures == 0 ? 0 : 1;

static bool Throws(Action action)
{
  try { action(); return false; }
  catch (InvalidOperationException exception) { return exception.Message.Contains("GetInvoices"); }
}

/// <summary>Lažen SAOP za zajem po številkah: odgovor je odvisen samo od zadnje številke v poti.</summary>
sealed class FakeSaop(Func<int, (int Status, string Body)> respond) : HttpMessageHandler
{
  protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
  {
    var number = int.Parse(request.RequestUri!.Segments[^1]);
    var (status, body) = respond(number);
    return Task.FromResult(new HttpResponseMessage((System.Net.HttpStatusCode)status) { Content = new StringContent(body) });
  }
}
