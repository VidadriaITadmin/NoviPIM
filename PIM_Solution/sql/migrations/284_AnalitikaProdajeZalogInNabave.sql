/*
  284 — Analitika prodaje, zalog in nabave (shema ana)

  Uporabnik 2026-09-24: »naredi analitiko v PIM-u … glede zalog, cen, prodaje (naročila kupcev),
  naročil dobaviteljev, koliko robe, kdaj pride … določena vloga vidi, koliko se kaj proda, mesečni
  trend po dobaviteljih in artiklih … PIM predlaga, koliko česa naročiti in katera zaloga je zaležana.«
  In: »naredi worker, ki prebere vse te podatke, da se samo priklopim v omrežje in dobiva podatke.«

  Kaj naredi:
    - shema ana z vhodnimi tabelami, ki jih polni PIM.SaopAnalyticsWorker (samo GET klici v SAOP):
        ana.SalesInvoiceLine    Invoice/GetInvoices        dejanska prodaja (vrstice računov)
        ana.CustomerOrderLine   Barkawi/GetCO              naročila kupcev (naročeno / odpremljeno)
        ana.PurchaseOrderLine   Barkawi/GetPO              naročila dobaviteljem z datumom prevzema
        ana.ItemPurchaseInfo    Barkawi/GetSKU             povprečna / zadnja nabavna cena, večkratnik
        ana.SourcePage          surovi odgovori (30 dni) za ponovno razčlenitev brez novega klica
        ana.StreamState         vodni žig in svežina vsakega toka
    - ana.StockDaily: dnevni posnetek lastne zaloge (vir BASE iz out.ExportStockSource; zaloga
      dobaviteljev NW/BT se NE šteje) — stock.Position hrani samo zadnje stanje;
    - ana.RefreshAnalytics: preračun ana.ItemMonthly, ana.ItemMetric, ana.SupplierMetric (predlog
      naročila, zaležano, preveč zaloge, ABC/XYZ, trend, dobavni čas); formula v glavi postopka;
    - ana.Setting (+ ana.SettingHistory): parametri formule po podjetju, sprememba z zgodovino;
    - bralni postopki za intranet (ana.GetOverview, ana.GetItemMetrics, ana.GetSupplierMetrics,
      ana.GetItemDetail, ana.GetSettings, ana.SaveSettings);
    - razpored SAOP_ANALYTICS (podjetja 2, 3, 4 vklopljena, DEMO izklopljen);
    - pravice page.analytics + zavihki za ADMIN in COMMERCIAL (drugim vlogam jih dodeli skrbnik).

  Nič od tega ne piše v SAOP in ne spreminja canon/pim/out tabel.
  Ročni korak: ne (worker PIM.SaopAnalyticsWorker se objavi z ostalimi workerji; posel SAOP_ANALYTICS_IMPORT).
  Migrator ne pozna GO, zato CREATE OR ALTER v EXEC(N'...').
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

IF UNICODE(N'č') <> 269 THROW 52840, N'284: datoteka ni prebrana kot UTF-8 (šumniki).', 1;
IF OBJECT_ID(N'out.ExportStockSource', N'U') IS NULL OR OBJECT_ID(N'purch.PurchaseOrderLine', N'U') IS NULL
   OR OBJECT_ID(N'sec.RolePermission', N'U') IS NULL OR OBJECT_ID(N'canon.PartnerName', N'V') IS NULL
  THROW 52849, N'284 potrebuje migracije 146, 199, 227 in pogled canon.PartnerName.', 1;

IF SCHEMA_ID(N'ana') IS NULL EXEC(N'CREATE SCHEMA ana AUTHORIZATION dbo');

/* --- 1) Nastavitve izračuna po podjetju + zgodovina ------------------------------------------------ */
IF OBJECT_ID(N'ana.Setting', N'U') IS NULL
CREATE TABLE ana.Setting
(
  OrganizationId int NOT NULL CONSTRAINT PK_AnaSetting PRIMARY KEY
    CONSTRAINT FK_AnaSetting_Organization REFERENCES dbo.OrganizationConfig (OrganizationId),
  ServiceLevelZ decimal(5, 2) NOT NULL CONSTRAINT DF_AnaSetting_Z DEFAULT (1.65),
  ReviewPeriodDays int NOT NULL CONSTRAINT DF_AnaSetting_Review DEFAULT (30),
  DefaultLeadTimeDays int NOT NULL CONSTRAINT DF_AnaSetting_Lead DEFAULT (30),
  DemandWindowDays int NOT NULL CONSTRAINT DF_AnaSetting_Window DEFAULT (180),
  DeadStockDays int NOT NULL CONSTRAINT DF_AnaSetting_Dead DEFAULT (180),
  OverstockCoverDays int NOT NULL CONSTRAINT DF_AnaSetting_Over DEFAULT (365),
  CostPriceList nvarchar(40) NOT NULL CONSTRAINT DF_AnaSetting_Cost DEFAULT (N'NAB'),
  UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_AnaSetting_Updated DEFAULT (SYSUTCDATETIME()),
  UpdatedBy nvarchar(200) NOT NULL CONSTRAINT DF_AnaSetting_By DEFAULT (N'migracija 284'),
  CONSTRAINT CK_AnaSetting_Ranges CHECK (ServiceLevelZ BETWEEN 0 AND 4 AND ReviewPeriodDays BETWEEN 1 AND 365
    AND DefaultLeadTimeDays BETWEEN 1 AND 365 AND DemandWindowDays BETWEEN 30 AND 730 AND DeadStockDays BETWEEN 30 AND 1095
    AND OverstockCoverDays BETWEEN 30 AND 1825)
);

IF OBJECT_ID(N'ana.SettingHistory', N'U') IS NULL
CREATE TABLE ana.SettingHistory
(
  SettingHistoryId bigint IDENTITY(1, 1) NOT NULL CONSTRAINT PK_AnaSettingHistory PRIMARY KEY,
  OrganizationId int NOT NULL,
  OldValueJson nvarchar(max) NULL,
  NewValueJson nvarchar(max) NOT NULL,
  ChangedUtc datetime2(3) NOT NULL CONSTRAINT DF_AnaSettingHistory_Changed DEFAULT (SYSUTCDATETIME()),
  ChangedBy nvarchar(200) NOT NULL
);

INSERT ana.Setting (OrganizationId)
SELECT organization.OrganizationId FROM dbo.OrganizationConfig AS organization
WHERE NOT EXISTS (SELECT 1 FROM ana.Setting AS existing WHERE existing.OrganizationId = organization.OrganizationId);

/* --- 2) Stanje tokov iz SAOP (vodni žig, zadnji uspeh, napaka) ------------------------------------- */
IF OBJECT_ID(N'ana.StreamState', N'U') IS NULL
CREATE TABLE ana.StreamState
(
  OrganizationId int NOT NULL,
  Stream nvarchar(40) NOT NULL,
  LastAttemptUtc datetime2(3) NULL,
  LastSuccessUtc datetime2(3) NULL,
  WatermarkUtc datetime2(3) NULL,
  LastRowCount int NULL,
  LastError nvarchar(2000) NULL,
  CONSTRAINT PK_AnaStreamState PRIMARY KEY (OrganizationId, Stream),
  CONSTRAINT CK_AnaStreamState_Stream CHECK (Stream IN (N'RACUNI', N'NAROCILA_KUPCEV', N'NAROCILA_DOBAVITELJEM', N'NABAVNI_PODATKI', N'IZRACUN'))
);

/* --- 3) Surovi odgovori SAOP (za ponovno razčlenitev brez novega klica; hrani se 30 dni) ------------ */
IF OBJECT_ID(N'ana.SourcePage', N'U') IS NULL
CREATE TABLE ana.SourcePage
(
  SourcePageId bigint IDENTITY(1, 1) NOT NULL CONSTRAINT PK_AnaSourcePage PRIMARY KEY,
  OrganizationId int NOT NULL,
  Stream nvarchar(40) NOT NULL,
  RunId uniqueidentifier NULL,
  PageNumber int NOT NULL,
  RequestUrl nvarchar(1000) NOT NULL,
  PayloadXml nvarchar(max) NOT NULL,
  RecordCount int NOT NULL,
  FetchedUtc datetime2(3) NOT NULL CONSTRAINT DF_AnaSourcePage_Fetched DEFAULT (SYSUTCDATETIME()),
  ParseError nvarchar(2000) NULL
);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_AnaSourcePage_Org_Stream' AND object_id = OBJECT_ID(N'ana.SourcePage'))
  CREATE INDEX IX_AnaSourcePage_Org_Stream ON ana.SourcePage (OrganizationId, Stream, FetchedUtc);

/* --- 4) Dejanska prodaja: vrstice izdanih računov (Invoice/GetInvoices) ----------------------------- */
IF OBJECT_ID(N'ana.SalesInvoiceLine', N'U') IS NULL
CREATE TABLE ana.SalesInvoiceLine
(
  OrganizationId int NOT NULL,
  InvoiceYear int NOT NULL,
  InvoiceBook nvarchar(20) NOT NULL,
  InvoiceNumber int NOT NULL,
  LineNumber int NOT NULL,
  InvoiceDate date NOT NULL,
  CustomerId nvarchar(100) NULL,
  CustomerName nvarchar(300) NULL,
  ClerkId nvarchar(50) NULL,
  ItemId nvarchar(100) NULL,
  ProductId bigint NULL,
  Quantity decimal(19, 4) NOT NULL,
  UnitOfMeasure nvarchar(20) NULL,
  Price decimal(19, 6) NULL,
  DiscountPercent decimal(9, 4) NULL,
  NetAmount decimal(19, 4) NULL,
  CurrencyId nvarchar(10) NULL,
  NetAmountEur decimal(19, 4) NULL,
  Status nvarchar(60) NULL,
  IsCancelled bit NOT NULL CONSTRAINT DF_AnaSalesInvoiceLine_Cancelled DEFAULT (0),
  SourceModifiedUtc datetime2(3) NULL,
  UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_AnaSalesInvoiceLine_Updated DEFAULT (SYSUTCDATETIME()),
  CONSTRAINT PK_AnaSalesInvoiceLine PRIMARY KEY (OrganizationId, InvoiceYear, InvoiceBook, InvoiceNumber, LineNumber)
);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_AnaSalesInvoiceLine_Date' AND object_id = OBJECT_ID(N'ana.SalesInvoiceLine'))
  CREATE INDEX IX_AnaSalesInvoiceLine_Date ON ana.SalesInvoiceLine (OrganizationId, InvoiceDate)
    INCLUDE (ItemId, ProductId, Quantity, NetAmountEur, CustomerId, IsCancelled);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_AnaSalesInvoiceLine_Product' AND object_id = OBJECT_ID(N'ana.SalesInvoiceLine'))
  CREATE INDEX IX_AnaSalesInvoiceLine_Product ON ana.SalesInvoiceLine (OrganizationId, ProductId, InvoiceDate)
    INCLUDE (Quantity, NetAmountEur, CustomerId, IsCancelled);

/* --- 5) Naročila kupcev po vrsticah (Barkawi/GetCO): povpraševanje tudi, kadar ni bilo dobavljeno --- */
IF OBJECT_ID(N'ana.CustomerOrderLine', N'U') IS NULL
CREATE TABLE ana.CustomerOrderLine
(
  OrganizationId int NOT NULL,
  OrderId nvarchar(60) NOT NULL,
  LineNumber int NOT NULL,
  OrderType nvarchar(40) NULL,
  OrderDate date NULL,
  CustomerId nvarchar(100) NULL,
  SiteId nvarchar(40) NULL,
  ItemId nvarchar(100) NOT NULL,
  ProductId bigint NULL,
  RequestedQty decimal(19, 4) NULL,
  ShippedQty decimal(19, 4) NULL,
  DemandDate date NULL,
  RequestedDate date NULL,
  ShippedDate date NULL,
  LineStatus nvarchar(40) NULL,
  UnitOfMeasure nvarchar(20) NULL,
  UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_AnaCustomerOrderLine_Updated DEFAULT (SYSUTCDATETIME()),
  CONSTRAINT PK_AnaCustomerOrderLine PRIMARY KEY (OrganizationId, OrderId, LineNumber)
);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_AnaCustomerOrderLine_Item' AND object_id = OBJECT_ID(N'ana.CustomerOrderLine'))
  CREATE INDEX IX_AnaCustomerOrderLine_Item ON ana.CustomerOrderLine (OrganizationId, ItemId, OrderDate)
    INCLUDE (RequestedQty, ShippedQty, ShippedDate, CustomerId);

/* --- 6) Naročila dobaviteljem po vrsticah (Barkawi/GetPO): datum prevzema = dejanski dobavni čas ---- */
IF OBJECT_ID(N'ana.PurchaseOrderLine', N'U') IS NULL
CREATE TABLE ana.PurchaseOrderLine
(
  OrganizationId int NOT NULL,
  PurchaseOrderId nvarchar(60) NOT NULL,
  LineNumber int NOT NULL,
  OrderType nvarchar(40) NULL,
  DeliveryType nvarchar(40) NULL,
  OrderDate date NULL,
  SupplierId nvarchar(100) NULL,
  SiteId nvarchar(40) NULL,
  ItemId nvarchar(100) NOT NULL,
  SupplierItemId nvarchar(100) NULL,
  ProductId bigint NULL,
  RequestedQty decimal(19, 4) NULL,
  ReceivedQty decimal(19, 4) NULL,
  ReceivedDate date NULL,
  LineStatus nvarchar(40) NULL,
  UnitOfMeasure nvarchar(20) NULL,
  LeadTimeDays AS (DATEDIFF(day, OrderDate, ReceivedDate)) PERSISTED,
  UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_AnaPurchaseOrderLine_Updated DEFAULT (SYSUTCDATETIME()),
  CONSTRAINT PK_AnaPurchaseOrderLine PRIMARY KEY (OrganizationId, PurchaseOrderId, LineNumber)
);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_AnaPurchaseOrderLine_Item' AND object_id = OBJECT_ID(N'ana.PurchaseOrderLine'))
  CREATE INDEX IX_AnaPurchaseOrderLine_Item ON ana.PurchaseOrderLine (OrganizationId, ItemId, ReceivedDate)
    INCLUDE (OrderDate, SupplierId, RequestedQty, ReceivedQty);

/* --- 7) Nabavni podatki artikla (Barkawi/GetSKU): povprečna in zadnja nabavna cena, večkratnik ------ */
IF OBJECT_ID(N'ana.ItemPurchaseInfo', N'U') IS NULL
CREATE TABLE ana.ItemPurchaseInfo
(
  OrganizationId int NOT NULL,
  ItemId nvarchar(100) NOT NULL,
  ProductId bigint NULL,
  PreferredSupplier nvarchar(100) NULL,
  Supplier nvarchar(300) NULL,
  SupplierItemId nvarchar(100) NULL,
  AveragePurchasePrice decimal(19, 6) NULL,
  LastPurchasePrice decimal(19, 6) NULL,
  ListPrice decimal(19, 6) NULL,
  OrderMultiple decimal(19, 4) NULL,
  Brand nvarchar(200) NULL,
  Ean nvarchar(50) NULL,
  UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_AnaItemPurchaseInfo_Updated DEFAULT (SYSUTCDATETIME()),
  CONSTRAINT PK_AnaItemPurchaseInfo PRIMARY KEY (OrganizationId, ItemId)
);

/* --- 8) Dnevni posnetek lastne zaloge (zgodovina; stock.Position hrani samo zadnje stanje) --------- */
IF OBJECT_ID(N'ana.StockDaily', N'U') IS NULL
CREATE TABLE ana.StockDaily
(
  OrganizationId int NOT NULL,
  SnapshotDate date NOT NULL,
  ProductId bigint NOT NULL,
  Quantity decimal(19, 4) NOT NULL,
  ReservedQuantity decimal(19, 4) NULL,
  AvailableQuantity decimal(19, 4) NULL,
  SupplierOrderedQuantity decimal(19, 4) NULL,
  UnitCost decimal(19, 6) NULL,
  CONSTRAINT PK_AnaStockDaily PRIMARY KEY (OrganizationId, SnapshotDate, ProductId)
);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_AnaStockDaily_Product' AND object_id = OBJECT_ID(N'ana.StockDaily'))
  CREATE INDEX IX_AnaStockDaily_Product ON ana.StockDaily (OrganizationId, ProductId, SnapshotDate) INCLUDE (Quantity, AvailableQuantity);

/* --- 9) Prodaja po mesecih in artiklih (preračun, vir za trende) ------------------------------------ */
IF OBJECT_ID(N'ana.ItemMonthly', N'U') IS NULL
CREATE TABLE ana.ItemMonthly
(
  OrganizationId int NOT NULL,
  ItemId nvarchar(100) NOT NULL,
  MonthStart date NOT NULL,
  ProductId bigint NULL,
  SupplierId nvarchar(100) NULL,
  QtySold decimal(19, 4) NOT NULL CONSTRAINT DF_AnaItemMonthly_Qty DEFAULT (0),
  NetSales decimal(19, 4) NULL,
  CostOfSales decimal(19, 4) NULL,
  Documents int NOT NULL CONSTRAINT DF_AnaItemMonthly_Docs DEFAULT (0),
  Customers int NOT NULL CONSTRAINT DF_AnaItemMonthly_Customers DEFAULT (0),
  QtyOrdered decimal(19, 4) NULL,
  CONSTRAINT PK_AnaItemMonthly PRIMARY KEY (OrganizationId, ItemId, MonthStart)
);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_AnaItemMonthly_Month' AND object_id = OBJECT_ID(N'ana.ItemMonthly'))
  CREATE INDEX IX_AnaItemMonthly_Month ON ana.ItemMonthly (OrganizationId, MonthStart)
    INCLUDE (SupplierId, QtySold, NetSales, CostOfSales, QtyOrdered);

/* --- 10) Kazalniki po artiklu (preračun) ------------------------------------------------------------ */
IF OBJECT_ID(N'ana.ItemMetric', N'U') IS NULL
CREATE TABLE ana.ItemMetric
(
  OrganizationId int NOT NULL,
  ProductId bigint NOT NULL,
  ItemId nvarchar(100) NOT NULL,
  ItemName nvarchar(400) NULL,
  Ean nvarchar(50) NULL,
  SupplierId nvarchar(100) NOT NULL,
  SupplierName nvarchar(300) NULL,
  ItemGroup nvarchar(100) NULL,
  Department nvarchar(100) NULL,
  IsActive bit NOT NULL,
  Stock decimal(19, 4) NOT NULL,
  Reserved decimal(19, 4) NOT NULL,
  Available decimal(19, 4) NOT NULL,
  OnOrder decimal(19, 4) NOT NULL,
  OnOrderSource nvarchar(20) NULL,
  NextDeliveryDate date NULL,
  UnitCost decimal(19, 6) NULL,
  CostSource nvarchar(20) NULL,
  StockValue decimal(19, 2) NULL,
  Sales30Qty decimal(19, 4) NOT NULL,
  Sales90Qty decimal(19, 4) NOT NULL,
  Sales365Qty decimal(19, 4) NOT NULL,
  Sales365Net decimal(19, 2) NULL,
  SalesPrev365Qty decimal(19, 4) NOT NULL,
  SalesPrev365Net decimal(19, 2) NULL,
  Sales365Margin decimal(19, 2) NULL,
  AvgSellPrice decimal(19, 6) NULL,
  Customers365 int NOT NULL,
  Last3mQty decimal(19, 4) NOT NULL,
  Prev3mQty decimal(19, 4) NOT NULL,
  TrendPct decimal(9, 1) NULL,
  YoyPct decimal(9, 1) NULL,
  DailyDemand decimal(19, 6) NOT NULL,
  DemandCv decimal(9, 3) NULL,
  LastSaleDate date NULL,
  LastReceiptDate date NULL,
  CoverDays int NULL,
  LeadTimeDays int NOT NULL,
  LeadTimeSource nvarchar(20) NOT NULL,
  LeadTimeSamples int NOT NULL,
  SafetyStock decimal(19, 4) NOT NULL,
  ReorderPoint decimal(19, 4) NOT NULL,
  OrderUpToLevel decimal(19, 4) NOT NULL,
  OrderMultiple decimal(19, 4) NOT NULL,
  PolicyMin decimal(19, 4) NULL,
  PolicyMax decimal(19, 4) NULL,
  SuggestedQty decimal(19, 4) NOT NULL,
  SuggestedValue decimal(19, 2) NULL,
  SuggestionReason nvarchar(300) NULL,
  ExcessQty decimal(19, 4) NOT NULL,
  ExcessValue decimal(19, 2) NULL,
  AbcClass char(1) NULL,
  XyzClass char(1) NULL,
  Signal nvarchar(20) NOT NULL,
  DemandSource nvarchar(20) NOT NULL,
  CalculatedUtc datetime2(3) NOT NULL,
  CONSTRAINT PK_AnaItemMetric PRIMARY KEY (OrganizationId, ProductId),
  CONSTRAINT CK_AnaItemMetric_Signal CHECK (Signal IN (N'BREZ_ZALOGE', N'NAROCI', N'ZALEZANO', N'PREVEC', N'V_REDU', N'NEAKTIVNO'))
);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_AnaItemMetric_Signal' AND object_id = OBJECT_ID(N'ana.ItemMetric'))
  CREATE INDEX IX_AnaItemMetric_Signal ON ana.ItemMetric (OrganizationId, Signal)
    INCLUDE (SupplierId, StockValue, Sales365Net, SuggestedValue, ExcessValue);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_AnaItemMetric_Supplier' AND object_id = OBJECT_ID(N'ana.ItemMetric'))
  CREATE INDEX IX_AnaItemMetric_Supplier ON ana.ItemMetric (OrganizationId, SupplierId)
    INCLUDE (Signal, StockValue, Sales365Net, SuggestedValue, ExcessValue);

/* --- 11) Kazalniki po dobavitelju (preračun) --------------------------------------------------------- */
IF OBJECT_ID(N'ana.SupplierMetric', N'U') IS NULL
CREATE TABLE ana.SupplierMetric
(
  OrganizationId int NOT NULL,
  SupplierId nvarchar(100) NOT NULL,
  SupplierName nvarchar(300) NULL,
  Items int NOT NULL,
  ItemsInStock int NOT NULL,
  ItemsSold365 int NOT NULL,
  StockValue decimal(19, 2) NULL,
  Sales365Net decimal(19, 2) NULL,
  SalesPrev365Net decimal(19, 2) NULL,
  Sales365Margin decimal(19, 2) NULL,
  YoyPct decimal(9, 1) NULL,
  ItemsToOrder int NOT NULL,
  SuggestedOrderValue decimal(19, 2) NULL,
  StockoutItems int NOT NULL,
  DeadItems int NOT NULL,
  DeadStockValue decimal(19, 2) NULL,
  OverstockValue decimal(19, 2) NULL,
  LeadTimeAvgDays decimal(9, 1) NULL,
  LeadTimeSamples int NOT NULL,
  OpenPurchaseLines int NOT NULL,
  OverduePurchaseLines int NOT NULL,
  LastPurchaseOrderDate date NULL,
  CalculatedUtc datetime2(3) NOT NULL,
  CONSTRAINT PK_AnaSupplierMetric PRIMARY KEY (OrganizationId, SupplierId)
);

/* --- Postopki ---------------------------------------------------------------------------------------- */
EXEC(N'CREATE OR ALTER PROCEDURE ana.SaveSourcePage
  @OrganizationId int, @Stream nvarchar(40), @RunId uniqueidentifier, @PageNumber int,
  @RequestUrl nvarchar(1000), @PayloadXml nvarchar(max), @RecordCount int
AS
BEGIN
  SET NOCOUNT ON;
  INSERT ana.SourcePage (OrganizationId, Stream, RunId, PageNumber, RequestUrl, PayloadXml, RecordCount)
  VALUES (@OrganizationId, @Stream, @RunId, @PageNumber, @RequestUrl, @PayloadXml, @RecordCount);
  SELECT SourcePageId = CONVERT(bigint, SCOPE_IDENTITY());
END;');

EXEC(N'CREATE OR ALTER PROCEDURE ana.SetStreamState
  @OrganizationId int, @Stream nvarchar(40), @Succeeded bit, @RowCount int = NULL,
  @WatermarkUtc datetime2(3) = NULL, @Error nvarchar(2000) = NULL
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  DECLARE @Now datetime2(3) = SYSUTCDATETIME();
  MERGE ana.StreamState AS target
  USING (SELECT @OrganizationId AS OrganizationId, @Stream AS Stream) AS source
    ON target.OrganizationId = source.OrganizationId AND target.Stream = source.Stream
  WHEN MATCHED THEN UPDATE SET
    LastAttemptUtc = @Now,
    LastSuccessUtc = CASE WHEN @Succeeded = 1 THEN @Now ELSE target.LastSuccessUtc END,
    WatermarkUtc = CASE WHEN @Succeeded = 1 AND @WatermarkUtc IS NOT NULL THEN @WatermarkUtc ELSE target.WatermarkUtc END,
    LastRowCount = CASE WHEN @Succeeded = 1 THEN @RowCount ELSE target.LastRowCount END,
    LastError = CASE WHEN @Succeeded = 1 THEN NULL ELSE LEFT(@Error, 2000) END
  WHEN NOT MATCHED THEN INSERT (OrganizationId, Stream, LastAttemptUtc, LastSuccessUtc, WatermarkUtc, LastRowCount, LastError)
    VALUES (@OrganizationId, @Stream, @Now, CASE WHEN @Succeeded = 1 THEN @Now END,
      CASE WHEN @Succeeded = 1 THEN @WatermarkUtc END, @RowCount, CASE WHEN @Succeeded = 0 THEN LEFT(@Error, 2000) END);
END;');

/* Račun se zamenja v celoti (vse vrstice), da izbrisana vrstica v SAOP ne ostane v PIM. */
EXEC(N'CREATE OR ALTER PROCEDURE ana.UpsertSalesInvoiceLines @OrganizationId int, @Json nvarchar(max)
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  IF ISJSON(@Json) <> 1 THROW 52841, N''284: vrstice računov niso veljaven JSON.'', 1;

  CREATE TABLE #line
  (
    InvoiceYear int NOT NULL, InvoiceBook nvarchar(20) COLLATE DATABASE_DEFAULT NOT NULL, InvoiceNumber int NOT NULL,
    LineNumber int NOT NULL, InvoiceDate date NOT NULL, CustomerId nvarchar(100) COLLATE DATABASE_DEFAULT NULL,
    CustomerName nvarchar(300) COLLATE DATABASE_DEFAULT NULL, ClerkId nvarchar(50) COLLATE DATABASE_DEFAULT NULL,
    ItemId nvarchar(100) COLLATE DATABASE_DEFAULT NULL, Quantity decimal(19, 4) NOT NULL,
    UnitOfMeasure nvarchar(20) COLLATE DATABASE_DEFAULT NULL, Price decimal(19, 6) NULL, DiscountPercent decimal(9, 4) NULL,
    NetAmount decimal(19, 4) NULL, CurrencyId nvarchar(10) COLLATE DATABASE_DEFAULT NULL, ExchangeRate decimal(19, 6) NULL,
    ExchangeRateBase decimal(19, 6) NULL, Status nvarchar(60) COLLATE DATABASE_DEFAULT NULL, SourceModifiedUtc datetime2(3) NULL,
    Ordinal int NOT NULL
  );

  INSERT #line
  SELECT line.InvoiceYear, LEFT(line.InvoiceBook, 20), line.InvoiceNumber, line.LineNumber, line.InvoiceDate,
    NULLIF(LTRIM(RTRIM(line.CustomerId)), N''''), LEFT(line.CustomerName, 300), LEFT(line.ClerkId, 50),
    NULLIF(LTRIM(RTRIM(line.ItemId)), N''''), ISNULL(line.Quantity, 0), LEFT(line.UnitOfMeasure, 20), line.Price,
    line.DiscountPercent, line.NetAmount, NULLIF(LTRIM(RTRIM(line.CurrencyId)), N''''), line.ExchangeRate,
    line.ExchangeRateBase, LEFT(line.Status, 60), line.SourceModifiedUtc, CONVERT(int, [key])
  FROM OPENJSON(@Json) AS item
  CROSS APPLY OPENJSON(item.value) WITH
  (
    InvoiceYear int, InvoiceBook nvarchar(40), InvoiceNumber int, LineNumber int, InvoiceDate date,
    CustomerId nvarchar(100), CustomerName nvarchar(400), ClerkId nvarchar(100), ItemId nvarchar(100),
    Quantity decimal(19, 4), UnitOfMeasure nvarchar(40), Price decimal(19, 6), DiscountPercent decimal(9, 4),
    NetAmount decimal(19, 4), CurrencyId nvarchar(10), ExchangeRate decimal(19, 6), ExchangeRateBase decimal(19, 6),
    Status nvarchar(100), SourceModifiedUtc datetime2(3)
  ) AS line
  WHERE line.InvoiceYear IS NOT NULL AND line.InvoiceBook IS NOT NULL AND line.InvoiceNumber IS NOT NULL
    AND line.LineNumber IS NOT NULL AND line.InvoiceDate IS NOT NULL;

  -- Ista vrstica dvakrat (prekrivanje strani): obvelja zadnja.
  ;WITH dvojniki AS (SELECT rn = ROW_NUMBER() OVER (PARTITION BY InvoiceYear, InvoiceBook, InvoiceNumber, LineNumber ORDER BY Ordinal DESC) FROM #line)
  DELETE FROM dvojniki WHERE rn > 1;

  BEGIN TRANSACTION;
    DELETE target
    FROM ana.SalesInvoiceLine AS target
    WHERE target.OrganizationId = @OrganizationId
      AND EXISTS (SELECT 1 FROM #line AS line WHERE line.InvoiceYear = target.InvoiceYear
                  AND line.InvoiceBook = target.InvoiceBook AND line.InvoiceNumber = target.InvoiceNumber);

    INSERT ana.SalesInvoiceLine (OrganizationId, InvoiceYear, InvoiceBook, InvoiceNumber, LineNumber, InvoiceDate, CustomerId,
      CustomerName, ClerkId, ItemId, ProductId, Quantity, UnitOfMeasure, Price, DiscountPercent, NetAmount, CurrencyId,
      NetAmountEur, Status, IsCancelled, SourceModifiedUtc)
    SELECT @OrganizationId, line.InvoiceYear, line.InvoiceBook, line.InvoiceNumber, line.LineNumber, line.InvoiceDate,
      line.CustomerId, line.CustomerName, line.ClerkId, line.ItemId, product.ProductId, line.Quantity, line.UnitOfMeasure,
      line.Price, line.DiscountPercent, line.NetAmount, line.CurrencyId,
      CASE WHEN line.CurrencyId IS NULL OR line.CurrencyId IN (N''EUR'', N''978'') THEN line.NetAmount
           WHEN ISNULL(line.ExchangeRate, 0) > 0 THEN line.NetAmount * line.ExchangeRate / COALESCE(NULLIF(line.ExchangeRateBase, 0), 1)
      END,
      line.Status,
      CASE WHEN line.Status LIKE N''%storn%'' OR line.Status LIKE N''%cancel%'' THEN 1 ELSE 0 END,
      line.SourceModifiedUtc
    FROM #line AS line
    LEFT JOIN canon.Product AS product ON product.OrganizationId = @OrganizationId AND product.ItemID = line.ItemId;
  COMMIT;

  SELECT Invoices = (SELECT COUNT(*) FROM (SELECT DISTINCT InvoiceYear, InvoiceBook, InvoiceNumber FROM #line) AS x),
         Lines = (SELECT COUNT(*) FROM #line);
END;');

EXEC(N'CREATE OR ALTER PROCEDURE ana.UpsertCustomerOrderLines @OrganizationId int, @Json nvarchar(max)
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  IF ISJSON(@Json) <> 1 THROW 52842, N''284: vrstice naročil kupcev niso veljaven JSON.'', 1;

  CREATE TABLE #line
  (
    OrderId nvarchar(60) COLLATE DATABASE_DEFAULT NOT NULL, LineNumber int NOT NULL, OrderType nvarchar(40) COLLATE DATABASE_DEFAULT NULL,
    OrderDate date NULL, CustomerId nvarchar(100) COLLATE DATABASE_DEFAULT NULL, SiteId nvarchar(40) COLLATE DATABASE_DEFAULT NULL,
    ItemId nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL, RequestedQty decimal(19, 4) NULL, ShippedQty decimal(19, 4) NULL,
    DemandDate date NULL, RequestedDate date NULL, ShippedDate date NULL, LineStatus nvarchar(40) COLLATE DATABASE_DEFAULT NULL,
    UnitOfMeasure nvarchar(20) COLLATE DATABASE_DEFAULT NULL, Ordinal int NOT NULL
  );
  INSERT #line
  SELECT LEFT(line.OrderId, 60), line.LineNumber, LEFT(line.OrderType, 40), line.OrderDate, NULLIF(LTRIM(RTRIM(line.CustomerId)), N''''),
    LEFT(line.SiteId, 40), LTRIM(RTRIM(line.ItemId)), line.RequestedQty, line.ShippedQty, line.DemandDate, line.RequestedDate,
    line.ShippedDate, LEFT(line.LineStatus, 40), LEFT(line.UnitOfMeasure, 20), CONVERT(int, [key])
  FROM OPENJSON(@Json) AS item
  CROSS APPLY OPENJSON(item.value) WITH
  (
    OrderId nvarchar(100), LineNumber int, OrderType nvarchar(100), OrderDate date, CustomerId nvarchar(100), SiteId nvarchar(100),
    ItemId nvarchar(100), RequestedQty decimal(19, 4), ShippedQty decimal(19, 4), DemandDate date, RequestedDate date,
    ShippedDate date, LineStatus nvarchar(100), UnitOfMeasure nvarchar(40)
  ) AS line
  WHERE NULLIF(LTRIM(RTRIM(line.OrderId)), N'''') IS NOT NULL AND line.LineNumber IS NOT NULL
    AND NULLIF(LTRIM(RTRIM(line.ItemId)), N'''') IS NOT NULL;

  ;WITH dvojniki AS (SELECT rn = ROW_NUMBER() OVER (PARTITION BY OrderId, LineNumber ORDER BY Ordinal DESC) FROM #line)
  DELETE FROM dvojniki WHERE rn > 1;

  MERGE ana.CustomerOrderLine AS target
  USING (SELECT line.*, product.ProductId FROM #line AS line
         LEFT JOIN canon.Product AS product ON product.OrganizationId = @OrganizationId AND product.ItemID = line.ItemId) AS source
    ON target.OrganizationId = @OrganizationId AND target.OrderId = source.OrderId AND target.LineNumber = source.LineNumber
  WHEN MATCHED THEN UPDATE SET OrderType = source.OrderType, OrderDate = source.OrderDate, CustomerId = source.CustomerId,
    SiteId = source.SiteId, ItemId = source.ItemId, ProductId = source.ProductId, RequestedQty = source.RequestedQty,
    ShippedQty = source.ShippedQty, DemandDate = source.DemandDate, RequestedDate = source.RequestedDate,
    ShippedDate = source.ShippedDate, LineStatus = source.LineStatus, UnitOfMeasure = source.UnitOfMeasure, UpdatedUtc = SYSUTCDATETIME()
  WHEN NOT MATCHED THEN INSERT (OrganizationId, OrderId, LineNumber, OrderType, OrderDate, CustomerId, SiteId, ItemId, ProductId,
    RequestedQty, ShippedQty, DemandDate, RequestedDate, ShippedDate, LineStatus, UnitOfMeasure)
    VALUES (@OrganizationId, source.OrderId, source.LineNumber, source.OrderType, source.OrderDate, source.CustomerId, source.SiteId,
      source.ItemId, source.ProductId, source.RequestedQty, source.ShippedQty, source.DemandDate, source.RequestedDate,
      source.ShippedDate, source.LineStatus, source.UnitOfMeasure);

  SELECT Lines = (SELECT COUNT(*) FROM #line);
END;');

EXEC(N'CREATE OR ALTER PROCEDURE ana.UpsertPurchaseOrderLines @OrganizationId int, @Json nvarchar(max)
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  IF ISJSON(@Json) <> 1 THROW 52843, N''284: vrstice naročil dobaviteljem niso veljaven JSON.'', 1;

  CREATE TABLE #line
  (
    PurchaseOrderId nvarchar(60) COLLATE DATABASE_DEFAULT NOT NULL, LineNumber int NOT NULL,
    OrderType nvarchar(40) COLLATE DATABASE_DEFAULT NULL, DeliveryType nvarchar(40) COLLATE DATABASE_DEFAULT NULL, OrderDate date NULL,
    SupplierId nvarchar(100) COLLATE DATABASE_DEFAULT NULL, SiteId nvarchar(40) COLLATE DATABASE_DEFAULT NULL,
    ItemId nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL, SupplierItemId nvarchar(100) COLLATE DATABASE_DEFAULT NULL,
    RequestedQty decimal(19, 4) NULL, ReceivedQty decimal(19, 4) NULL, ReceivedDate date NULL,
    LineStatus nvarchar(40) COLLATE DATABASE_DEFAULT NULL, UnitOfMeasure nvarchar(20) COLLATE DATABASE_DEFAULT NULL, Ordinal int NOT NULL
  );
  INSERT #line
  SELECT LEFT(line.PurchaseOrderId, 60), line.LineNumber, LEFT(line.OrderType, 40), LEFT(line.DeliveryType, 40), line.OrderDate,
    NULLIF(LTRIM(RTRIM(line.SupplierId)), N''''), LEFT(line.SiteId, 40), LTRIM(RTRIM(line.ItemId)), LEFT(line.SupplierItemId, 100),
    line.RequestedQty, line.ReceivedQty, line.ReceivedDate, LEFT(line.LineStatus, 40), LEFT(line.UnitOfMeasure, 20), CONVERT(int, [key])
  FROM OPENJSON(@Json) AS item
  CROSS APPLY OPENJSON(item.value) WITH
  (
    PurchaseOrderId nvarchar(100), LineNumber int, OrderType nvarchar(100), DeliveryType nvarchar(100), OrderDate date,
    SupplierId nvarchar(100), SiteId nvarchar(100), ItemId nvarchar(100), SupplierItemId nvarchar(200),
    RequestedQty decimal(19, 4), ReceivedQty decimal(19, 4), ReceivedDate date, LineStatus nvarchar(100), UnitOfMeasure nvarchar(40)
  ) AS line
  WHERE NULLIF(LTRIM(RTRIM(line.PurchaseOrderId)), N'''') IS NOT NULL AND line.LineNumber IS NOT NULL
    AND NULLIF(LTRIM(RTRIM(line.ItemId)), N'''') IS NOT NULL;

  ;WITH dvojniki AS (SELECT rn = ROW_NUMBER() OVER (PARTITION BY PurchaseOrderId, LineNumber ORDER BY Ordinal DESC) FROM #line)
  DELETE FROM dvojniki WHERE rn > 1;

  MERGE ana.PurchaseOrderLine AS target
  USING (SELECT line.*, product.ProductId FROM #line AS line
         LEFT JOIN canon.Product AS product ON product.OrganizationId = @OrganizationId AND product.ItemID = line.ItemId) AS source
    ON target.OrganizationId = @OrganizationId AND target.PurchaseOrderId = source.PurchaseOrderId AND target.LineNumber = source.LineNumber
  WHEN MATCHED THEN UPDATE SET OrderType = source.OrderType, DeliveryType = source.DeliveryType, OrderDate = source.OrderDate,
    SupplierId = source.SupplierId, SiteId = source.SiteId, ItemId = source.ItemId, SupplierItemId = source.SupplierItemId,
    ProductId = source.ProductId, RequestedQty = source.RequestedQty, ReceivedQty = source.ReceivedQty,
    ReceivedDate = source.ReceivedDate, LineStatus = source.LineStatus, UnitOfMeasure = source.UnitOfMeasure, UpdatedUtc = SYSUTCDATETIME()
  WHEN NOT MATCHED THEN INSERT (OrganizationId, PurchaseOrderId, LineNumber, OrderType, DeliveryType, OrderDate, SupplierId, SiteId,
    ItemId, SupplierItemId, ProductId, RequestedQty, ReceivedQty, ReceivedDate, LineStatus, UnitOfMeasure)
    VALUES (@OrganizationId, source.PurchaseOrderId, source.LineNumber, source.OrderType, source.DeliveryType, source.OrderDate,
      source.SupplierId, source.SiteId, source.ItemId, source.SupplierItemId, source.ProductId, source.RequestedQty,
      source.ReceivedQty, source.ReceivedDate, source.LineStatus, source.UnitOfMeasure);

  SELECT Lines = (SELECT COUNT(*) FROM #line);
END;');

EXEC(N'CREATE OR ALTER PROCEDURE ana.UpsertItemPurchaseInfo @OrganizationId int, @Json nvarchar(max)
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  IF ISJSON(@Json) <> 1 THROW 52844, N''284: nabavni podatki niso veljaven JSON.'', 1;

  CREATE TABLE #item
  (
    ItemId nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL, PreferredSupplier nvarchar(100) COLLATE DATABASE_DEFAULT NULL,
    Supplier nvarchar(300) COLLATE DATABASE_DEFAULT NULL, SupplierItemId nvarchar(100) COLLATE DATABASE_DEFAULT NULL,
    AveragePurchasePrice decimal(19, 6) NULL, LastPurchasePrice decimal(19, 6) NULL, ListPrice decimal(19, 6) NULL,
    OrderMultiple decimal(19, 4) NULL, Brand nvarchar(200) COLLATE DATABASE_DEFAULT NULL, Ean nvarchar(50) COLLATE DATABASE_DEFAULT NULL,
    Ordinal int NOT NULL
  );
  INSERT #item
  SELECT LTRIM(RTRIM(item.ItemId)), NULLIF(LTRIM(RTRIM(item.PreferredSupplier)), N''''), LEFT(item.Supplier, 300),
    LEFT(item.SupplierItemId, 100), item.AveragePurchasePrice, item.LastPurchasePrice, item.ListPrice, item.OrderMultiple,
    LEFT(item.Brand, 200), LEFT(item.Ean, 50), CONVERT(int, [key])
  FROM OPENJSON(@Json) AS row_
  CROSS APPLY OPENJSON(row_.value) WITH
  (
    ItemId nvarchar(100), PreferredSupplier nvarchar(100), Supplier nvarchar(400), SupplierItemId nvarchar(200),
    AveragePurchasePrice decimal(19, 6), LastPurchasePrice decimal(19, 6), ListPrice decimal(19, 6), OrderMultiple decimal(19, 4),
    Brand nvarchar(400), Ean nvarchar(100)
  ) AS item
  WHERE NULLIF(LTRIM(RTRIM(item.ItemId)), N'''') IS NOT NULL;

  ;WITH dvojniki AS (SELECT rn = ROW_NUMBER() OVER (PARTITION BY ItemId ORDER BY Ordinal DESC) FROM #item)
  DELETE FROM dvojniki WHERE rn > 1;

  MERGE ana.ItemPurchaseInfo AS target
  USING (SELECT item.*, product.ProductId FROM #item AS item
         LEFT JOIN canon.Product AS product ON product.OrganizationId = @OrganizationId AND product.ItemID = item.ItemId) AS source
    ON target.OrganizationId = @OrganizationId AND target.ItemId = source.ItemId
  WHEN MATCHED THEN UPDATE SET ProductId = source.ProductId, PreferredSupplier = source.PreferredSupplier, Supplier = source.Supplier,
    SupplierItemId = source.SupplierItemId, AveragePurchasePrice = source.AveragePurchasePrice,
    LastPurchasePrice = source.LastPurchasePrice, ListPrice = source.ListPrice, OrderMultiple = source.OrderMultiple,
    Brand = source.Brand, Ean = source.Ean, UpdatedUtc = SYSUTCDATETIME()
  WHEN NOT MATCHED THEN INSERT (OrganizationId, ItemId, ProductId, PreferredSupplier, Supplier, SupplierItemId, AveragePurchasePrice,
    LastPurchasePrice, ListPrice, OrderMultiple, Brand, Ean)
    VALUES (@OrganizationId, source.ItemId, source.ProductId, source.PreferredSupplier, source.Supplier, source.SupplierItemId,
      source.AveragePurchasePrice, source.LastPurchasePrice, source.ListPrice, source.OrderMultiple, source.Brand, source.Ean);

  SELECT Items = (SELECT COUNT(*) FROM #item);
END;');

/*
  Dnevni posnetek lastne zaloge: aktivni posnetek vira BASE (out.ExportStockSource), nikoli zaloga dobaviteljev.
  Ponovni klic isti dan posnetek zamenja.
*/
EXEC(N'CREATE OR ALTER PROCEDURE ana.CaptureStockDaily @OrganizationId int, @Today date = NULL, @Quiet bit = 0
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  IF @Today IS NULL SET @Today = CONVERT(date, SYSDATETIME());

  CREATE TABLE #source (SourceCode nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY);
  INSERT #source (SourceCode)
  SELECT DISTINCT stockSource.SourceCode FROM out.ExportStockSource AS stockSource
  WHERE stockSource.OrganizationId = @OrganizationId AND stockSource.StockOrganizationId = @OrganizationId
    AND stockSource.Contribution = N''BASE'' AND stockSource.IsActive = 1;
  IF NOT EXISTS (SELECT 1 FROM #source)
    INSERT #source (SourceCode)
    SELECT connector.SourceCode FROM map.SourceConnector AS connector
    WHERE connector.OrganizationId = @OrganizationId AND connector.IsActive = 1
      AND connector.SourceCode LIKE N''SAOP[_]%[_]STOCK'';

  BEGIN TRANSACTION;
    DELETE ana.StockDaily WHERE OrganizationId = @OrganizationId AND SnapshotDate = @Today;

    INSERT ana.StockDaily (OrganizationId, SnapshotDate, ProductId, Quantity, ReservedQuantity, AvailableQuantity, SupplierOrderedQuantity)
    SELECT @OrganizationId, @Today, position.MatchedProductId, SUM(ISNULL(position.Quantity, 0)),
      SUM(position.OrderedQuantity), SUM(position.AvailableQuantity), SUM(position.SupplierOrderedQuantity)
    FROM stock.Snapshot AS snapshot
    INNER JOIN map.SourceConnector AS connector ON connector.SourceConnectorId = snapshot.SourceConnectorId
    INNER JOIN #source AS source ON source.SourceCode = connector.SourceCode
    INNER JOIN stock.Position AS position ON position.SnapshotId = snapshot.SnapshotId
    INNER JOIN canon.Product AS product ON product.ProductId = position.MatchedProductId AND product.OrganizationId = @OrganizationId
    WHERE snapshot.OrganizationId = @OrganizationId AND snapshot.IsActive = 1
    GROUP BY position.MatchedProductId
    HAVING SUM(ISNULL(position.Quantity, 0)) <> 0 OR ISNULL(SUM(position.OrderedQuantity), 0) <> 0
      OR ISNULL(SUM(position.SupplierOrderedQuantity), 0) <> 0;
    DECLARE @Rows int = @@ROWCOUNT;

    -- Zgodovina ~26 mesecev je dovolj za primerjavo z lanskim letom.
    DELETE ana.StockDaily WHERE OrganizationId = @OrganizationId AND SnapshotDate < DATEADD(day, -800, @Today);
  COMMIT;

  IF @Quiet = 0 SELECT Items = @Rows;
END;');

/*
  Preračun analitike enega podjetja. Samo bere vhodne tabele in v celoti prepiše ana.ItemMonthly,
  ana.ItemMetric in ana.SupplierMetric tega podjetja (ena transakcija na tabelo). Brez zanke po artiklih.

  Vir prodaje (DemandSource), po prednosti:
    RACUNI      ana.SalesInvoiceLine (dejansko izdani računi)
    VNK         sales.OrderLine.ShippedQTY (odpremljeno po naročilih kupcev)
    BARKAWI_CO  ana.CustomerOrderLine.ShippedQty
    BREZ        ni podatkov o prodaji: predlogi in zaležana zaloga se ne računajo.

  Formula (periodično naročanje): d = prodano v zadnjih DemandWindowDays / DemandWindowDays,
  varnostna zaloga SS = z · σ_dan · √(LT + R), točka naročila ROP = d·LT + SS,
  ciljna raven S = d·(LT + R) + SS, položaj zaloge IP = razpoložljivo + naročeno pri dobaviteljih.
  Predlog = S − IP, ko je IP ≤ ROP, zaokroženo navzgor na večkratnik naročila. SAOP MIN (ročna
  nastavitev) ima prednost: pod MIN predlog dvigne vsaj do MAX (ali MIN, če MAX ni).
*/
EXEC(N'CREATE OR ALTER PROCEDURE ana.RefreshAnalytics @OrganizationId int, @Today date = NULL
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  IF @Today IS NULL SET @Today = CONVERT(date, SYSDATETIME());
  DECLARE @Now datetime2(3) = SYSUTCDATETIME();

  IF NOT EXISTS (SELECT 1 FROM dbo.OrganizationConfig WHERE OrganizationId = @OrganizationId)
    THROW 52845, N''284: neznano podjetje.'', 1;
  INSERT ana.Setting (OrganizationId) SELECT @OrganizationId
  WHERE NOT EXISTS (SELECT 1 FROM ana.Setting WHERE OrganizationId = @OrganizationId);

  DECLARE @Z decimal(5, 2), @Review int, @DefaultLead int, @Window int, @Dead int, @Over int, @CostList nvarchar(40);
  SELECT @Z = ServiceLevelZ, @Review = ReviewPeriodDays, @DefaultLead = DefaultLeadTimeDays, @Window = DemandWindowDays,
         @Dead = DeadStockDays, @Over = OverstockCoverDays, @CostList = CostPriceList
  FROM ana.Setting WHERE OrganizationId = @OrganizationId;

  DECLARE @MonthStart date = DATEFROMPARTS(YEAR(@Today), MONTH(@Today), 1);
  DECLARE @From date = DATEADD(month, -24, @MonthStart);

  /* --- Zaloga danes (posnetek) --------------------------------------------------------------------- */
  EXEC ana.CaptureStockDaily @OrganizationId = @OrganizationId, @Today = @Today, @Quiet = 1;

  /* --- Vir prodaje ------------------------------------------------------------------------------------ */
  DECLARE @Source nvarchar(20) =
    CASE
      WHEN EXISTS (SELECT 1 FROM ana.SalesInvoiceLine WHERE OrganizationId = @OrganizationId AND InvoiceDate >= DATEADD(day, -400, @Today)) THEN N''RACUNI''
      WHEN EXISTS (SELECT 1 FROM sales.OrderLine AS line INNER JOIN sales.OrderHeader AS header ON header.OrderHeaderId = line.OrderHeaderId
                   WHERE header.OrganizationId = @OrganizationId AND header.OrderDate >= DATEADD(day, -400, @Today) AND line.ShippedQTY <> 0) THEN N''VNK''
      WHEN EXISTS (SELECT 1 FROM ana.CustomerOrderLine WHERE OrganizationId = @OrganizationId AND ShippedQty <> 0
                   AND COALESCE(ShippedDate, OrderDate) >= DATEADD(day, -400, @Today)) THEN N''BARKAWI_CO''
      ELSE N''BREZ''
    END;

  CREATE TABLE #sale
  (
    ItemId nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL, SaleDate date NOT NULL, Qty decimal(19, 4) NOT NULL,
    Net decimal(19, 4) NULL, CustomerId nvarchar(100) COLLATE DATABASE_DEFAULT NULL, DocKey nvarchar(120) COLLATE DATABASE_DEFAULT NULL
  );
  IF @Source = N''RACUNI''
    INSERT #sale SELECT line.ItemId, line.InvoiceDate, line.Quantity, line.NetAmountEur, line.CustomerId,
      CONCAT(line.InvoiceYear, N''/'', line.InvoiceBook, N''/'', line.InvoiceNumber)
    FROM ana.SalesInvoiceLine AS line
    WHERE line.OrganizationId = @OrganizationId AND line.InvoiceDate >= @From AND line.IsCancelled = 0 AND line.ItemId IS NOT NULL;
  ELSE IF @Source = N''VNK''
    INSERT #sale SELECT line.ItemID, CONVERT(date, COALESCE(line.DeliveryDate, header.DeliveryDate, header.OrderDate)), line.ShippedQTY,
      CASE WHEN line.Qty <> 0 THEN line.NetAmount * line.ShippedQTY / line.Qty END, header.CustomerId,
      CONCAT(header.OrderYear, N''/'', header.OrderBook, N''/'', header.OrderNumber)
    FROM sales.OrderLine AS line INNER JOIN sales.OrderHeader AS header ON header.OrderHeaderId = line.OrderHeaderId
    WHERE header.OrganizationId = @OrganizationId AND line.ShippedQTY <> 0 AND line.ItemID IS NOT NULL
      AND COALESCE(line.DeliveryDate, header.DeliveryDate, header.OrderDate) >= @From;
  ELSE IF @Source = N''BARKAWI_CO''
    INSERT #sale SELECT line.ItemId, COALESCE(line.ShippedDate, line.RequestedDate, line.OrderDate), line.ShippedQty, NULL,
      line.CustomerId, line.OrderId
    FROM ana.CustomerOrderLine AS line
    WHERE line.OrganizationId = @OrganizationId AND line.ShippedQty <> 0
      AND COALESCE(line.ShippedDate, line.RequestedDate, line.OrderDate) >= @From;
  CREATE CLUSTERED INDEX IX_sale ON #sale (ItemId, SaleDate);

  -- Mrtve zaloge ne razglasimo, če zgodovina prodaje ne sega vsaj DeadStockDays nazaj.
  DECLARE @HistoryFrom date = (SELECT MIN(SaleDate) FROM #sale);
  DECLARE @CanJudgeDead bit = CASE WHEN @Source <> N''BREZ'' AND @HistoryFrom <= DATEADD(day, -@Dead, @Today) THEN 1 ELSE 0 END;

  -- Naročeno (povpraševanje), tudi kar ni bilo dobavljeno.
  CREATE TABLE #ordered (ItemId nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL, MonthStart date NOT NULL, Qty decimal(19, 4) NOT NULL);
  IF EXISTS (SELECT 1 FROM ana.CustomerOrderLine WHERE OrganizationId = @OrganizationId)
    INSERT #ordered SELECT ItemId, DATEFROMPARTS(YEAR(OrderDate), MONTH(OrderDate), 1), SUM(ISNULL(RequestedQty, 0))
    FROM ana.CustomerOrderLine WHERE OrganizationId = @OrganizationId AND OrderDate >= @From
    GROUP BY ItemId, DATEFROMPARTS(YEAR(OrderDate), MONTH(OrderDate), 1);
  ELSE
    INSERT #ordered SELECT line.ItemID, DATEFROMPARTS(YEAR(header.OrderDate), MONTH(header.OrderDate), 1), SUM(ISNULL(line.Qty, 0))
    FROM sales.OrderLine AS line INNER JOIN sales.OrderHeader AS header ON header.OrderHeaderId = line.OrderHeaderId
    WHERE header.OrganizationId = @OrganizationId AND header.OrderDate >= @From AND line.ItemID IS NOT NULL
    GROUP BY line.ItemID, DATEFROMPARTS(YEAR(header.OrderDate), MONTH(header.OrderDate), 1);

  /* --- Artikli podjetja -------------------------------------------------------------------------------- */
  CREATE TABLE #product
  (
    ProductId bigint NOT NULL PRIMARY KEY, ItemId nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL,
    Ean nvarchar(50) COLLATE DATABASE_DEFAULT NULL, SupplierId nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL,
    ItemGroup nvarchar(100) COLLATE DATABASE_DEFAULT NULL, Department nvarchar(100) COLLATE DATABASE_DEFAULT NULL, IsActive bit NOT NULL
  );
  INSERT #product
  SELECT product.ProductId, product.ItemID, LEFT(product.EAN, 50),
    COALESCE(NULLIF(LTRIM(RTRIM(product.Supplier)), N''''), purchaseInfo.PreferredSupplier, N''''),
    LEFT(product.ItemGroup, 100), LEFT(product.Department, 100), ISNULL(product.IsActive, 0)
  FROM canon.Product AS product
  LEFT JOIN ana.ItemPurchaseInfo AS purchaseInfo ON purchaseInfo.OrganizationId = @OrganizationId AND purchaseInfo.ItemId = product.ItemID
  WHERE product.OrganizationId = @OrganizationId;
  CREATE UNIQUE INDEX IX_product_item ON #product (ItemId);

  /* --- Nabavna cena ------------------------------------------------------------------------------------ */
  CREATE TABLE #cost (ProductId bigint NOT NULL PRIMARY KEY, UnitCost decimal(19, 6) NULL, CostSource nvarchar(20) COLLATE DATABASE_DEFAULT NULL, OrderMultiple decimal(19, 4) NULL);
  INSERT #cost
  SELECT product.ProductId,
    COALESCE(NULLIF(purchaseInfo.AveragePurchasePrice, 0), priceList.Net, NULLIF(purchaseInfo.LastPurchasePrice, 0)),
    CASE WHEN NULLIF(purchaseInfo.AveragePurchasePrice, 0) IS NOT NULL THEN N''POVPRECNA''
         WHEN priceList.Net IS NOT NULL THEN N''CENIK''
         WHEN NULLIF(purchaseInfo.LastPurchasePrice, 0) IS NOT NULL THEN N''ZADNJA'' END,
    CASE WHEN purchaseInfo.OrderMultiple > 1 THEN purchaseInfo.OrderMultiple END
  FROM #product AS product
  LEFT JOIN ana.ItemPurchaseInfo AS purchaseInfo ON purchaseInfo.OrganizationId = @OrganizationId AND purchaseInfo.ItemId = product.ItemId
  OUTER APPLY (SELECT TOP (1) price.Net FROM canon.ProductPrice AS price
               WHERE price.ProductId = product.ProductId AND price.PriceList = @CostList AND price.IsActive = 1 AND price.Net > 0
               ORDER BY price.ValidFrom DESC) AS priceList;

  UPDATE daily SET UnitCost = cost.UnitCost
  FROM ana.StockDaily AS daily INNER JOIN #cost AS cost ON cost.ProductId = daily.ProductId
  WHERE daily.OrganizationId = @OrganizationId AND daily.SnapshotDate = @Today;

  /* --- Prodaja po mesecih ------------------------------------------------------------------------------ */
  CREATE TABLE #monthly
  (
    ItemId nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL, MonthStart date NOT NULL, QtySold decimal(19, 4) NOT NULL,
    NetSales decimal(19, 4) NULL, Documents int NOT NULL, Customers int NOT NULL, QtyOrdered decimal(19, 4) NULL,
    PRIMARY KEY (ItemId, MonthStart)
  );
  INSERT #monthly
  SELECT COALESCE(sold.ItemId, ordered.ItemId), COALESCE(sold.MonthStart, ordered.MonthStart), ISNULL(sold.QtySold, 0),
    sold.NetSales, ISNULL(sold.Documents, 0), ISNULL(sold.Customers, 0), ordered.Qty
  FROM (SELECT ItemId, MonthStart = DATEFROMPARTS(YEAR(SaleDate), MONTH(SaleDate), 1), QtySold = SUM(Qty), NetSales = SUM(Net),
               Documents = COUNT(DISTINCT DocKey), Customers = COUNT(DISTINCT CustomerId)
        FROM #sale GROUP BY ItemId, DATEFROMPARTS(YEAR(SaleDate), MONTH(SaleDate), 1)) AS sold
  FULL JOIN #ordered AS ordered ON ordered.ItemId = sold.ItemId AND ordered.MonthStart = sold.MonthStart;

  BEGIN TRANSACTION;
    DELETE ana.ItemMonthly WHERE OrganizationId = @OrganizationId;
    INSERT ana.ItemMonthly (OrganizationId, ItemId, MonthStart, ProductId, SupplierId, QtySold, NetSales, CostOfSales, Documents, Customers, QtyOrdered)
    SELECT @OrganizationId, monthly.ItemId, monthly.MonthStart, product.ProductId, product.SupplierId, monthly.QtySold, monthly.NetSales,
      monthly.QtySold * cost.UnitCost, monthly.Documents, monthly.Customers, monthly.QtyOrdered
    FROM #monthly AS monthly
    LEFT JOIN #product AS product ON product.ItemId = monthly.ItemId
    LEFT JOIN #cost AS cost ON cost.ProductId = product.ProductId;
  COMMIT;

  /* --- Kazalniki prodaje po artiklu --------------------------------------------------------------------- */
  CREATE TABLE #sales
  (
    ItemId nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY, S30 decimal(19, 4) NOT NULL, S90 decimal(19, 4) NOT NULL,
    S365 decimal(19, 4) NOT NULL, N365 decimal(19, 4) NULL, P365 decimal(19, 4) NOT NULL, PN365 decimal(19, 4) NULL,
    SWindow decimal(19, 4) NOT NULL, L3 decimal(19, 4) NOT NULL, P3 decimal(19, 4) NOT NULL, LastSale date NULL, Customers365 int NOT NULL
  );
  INSERT #sales
  SELECT ItemId,
    ISNULL(SUM(CASE WHEN SaleDate > DATEADD(day, -30, @Today) THEN Qty END), 0),
    ISNULL(SUM(CASE WHEN SaleDate > DATEADD(day, -90, @Today) THEN Qty END), 0),
    ISNULL(SUM(CASE WHEN SaleDate > DATEADD(day, -365, @Today) THEN Qty END), 0),
    SUM(CASE WHEN SaleDate > DATEADD(day, -365, @Today) THEN Net END),
    ISNULL(SUM(CASE WHEN SaleDate > DATEADD(day, -730, @Today) AND SaleDate <= DATEADD(day, -365, @Today) THEN Qty END), 0),
    SUM(CASE WHEN SaleDate > DATEADD(day, -730, @Today) AND SaleDate <= DATEADD(day, -365, @Today) THEN Net END),
    ISNULL(SUM(CASE WHEN SaleDate > DATEADD(day, -@Window, @Today) THEN Qty END), 0),
    ISNULL(SUM(CASE WHEN SaleDate >= DATEADD(month, -3, @MonthStart) AND SaleDate < @MonthStart THEN Qty END), 0),
    ISNULL(SUM(CASE WHEN SaleDate >= DATEADD(month, -6, @MonthStart) AND SaleDate < DATEADD(month, -3, @MonthStart) THEN Qty END), 0),
    MAX(CASE WHEN Qty > 0 THEN SaleDate END),
    COUNT(DISTINCT CASE WHEN SaleDate > DATEADD(day, -365, @Today) THEN CustomerId END)
  FROM #sale GROUP BY ItemId;

  -- Nihanje mesečne prodaje v zadnjih 12 zaključenih mesecih (meseci brez prodaje štejejo kot 0).
  CREATE TABLE #variability (ItemId nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY, MeanMonth decimal(19, 6) NOT NULL, SigmaMonth decimal(19, 6) NOT NULL);
  INSERT #variability
  SELECT ItemId, SUM(QtySold) / 12.0,
    SQRT(CASE WHEN SUM(QtySold * QtySold) / 12.0 - SQUARE(SUM(QtySold) / 12.0) > 0
              THEN SUM(QtySold * QtySold) / 12.0 - SQUARE(SUM(QtySold) / 12.0) ELSE 0 END)
  FROM #monthly
  WHERE MonthStart >= DATEADD(month, -12, @MonthStart) AND MonthStart < @MonthStart
  GROUP BY ItemId;

  /* --- Dobavni čas iz dejanskih prevzemov ---------------------------------------------------------------- */
  CREATE TABLE #receipt (ItemId nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL, SupplierId nvarchar(100) COLLATE DATABASE_DEFAULT NULL, LeadTime int NOT NULL);
  INSERT #receipt
  SELECT ItemId, SupplierId, LeadTimeDays FROM ana.PurchaseOrderLine
  WHERE OrganizationId = @OrganizationId AND ReceivedDate IS NOT NULL AND ReceivedDate >= DATEADD(month, -24, @Today)
    AND LeadTimeDays BETWEEN 0 AND 365;

  SELECT DISTINCT ItemId,
    Median = PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY LeadTime) OVER (PARTITION BY ItemId),
    Samples = COUNT(*) OVER (PARTITION BY ItemId)
  INTO #leadItem FROM #receipt;
  SELECT SupplierId = ISNULL(SupplierId, N''''), AvgLead = AVG(CONVERT(decimal(9, 2), LeadTime)), Samples = COUNT(*)
  INTO #leadSupplier FROM #receipt GROUP BY ISNULL(SupplierId, N'''');

  SELECT ItemId, LastReceipt = MAX(ReceivedDate)
  INTO #lastReceipt FROM ana.PurchaseOrderLine
  WHERE OrganizationId = @OrganizationId AND ReceivedDate IS NOT NULL GROUP BY ItemId;

  /* --- Naročeno pri dobaviteljih ------------------------------------------------------------------------ */
  SELECT ItemId = line.ItemID, Qty = SUM(line.OrderedQuantity),
    NextDate = MIN(CONVERT(date, COALESCE(line.ForeseenDeliveryDate, header.ForeseenDeliveryDate)))
  INTO #openPurch
  FROM purch.PurchaseOrderLine AS line INNER JOIN purch.PurchaseOrderHeader AS header ON header.PurchaseOrderHeaderId = line.PurchaseOrderHeaderId
  WHERE header.OrganizationId = @OrganizationId AND ISNULL(line.CanceledLine, 0) = 0 AND line.ItemID IS NOT NULL
    AND ISNULL(header.Status, N'''') NOT IN (N''Zaključeno'', N''Stornirano'') AND ISNULL(line.Status, N'''') NOT IN (N''Zaključeno'', N''Stornirano'')
  GROUP BY line.ItemID;

  SELECT ItemId, Qty = SUM(RequestedQty - ISNULL(ReceivedQty, 0))
  INTO #openBarkawi FROM ana.PurchaseOrderLine
  WHERE OrganizationId = @OrganizationId AND RequestedQty > ISNULL(ReceivedQty, 0) AND OrderDate >= DATEADD(day, -365, @Today)
  GROUP BY ItemId;

  SELECT ItemId = delivery.NormalizedItemId, NextDate = MIN(CONVERT(date, delivery.DeliveryDate))
  INTO #nextDelivery FROM stock.ItemDeliveryDate AS delivery
  WHERE delivery.OrganizationId = @OrganizationId AND delivery.DeliveryDate >= @Today
  GROUP BY delivery.NormalizedItemId;

  /* --- Zbir po artiklu ---------------------------------------------------------------------------------- */
  CREATE TABLE #metric
  (
    ProductId bigint NOT NULL PRIMARY KEY, ItemId nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL,
    SupplierId nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL, IsActive bit NOT NULL,
    Stock decimal(19, 4) NOT NULL, Reserved decimal(19, 4) NOT NULL, Available decimal(19, 4) NOT NULL,
    OnOrder decimal(19, 4) NOT NULL, OnOrderSource nvarchar(20) COLLATE DATABASE_DEFAULT NULL, NextDeliveryDate date NULL,
    UnitCost decimal(19, 6) NULL, CostSource nvarchar(20) COLLATE DATABASE_DEFAULT NULL, OrderMultiple decimal(19, 4) NOT NULL,
    S30 decimal(19, 4) NOT NULL, S90 decimal(19, 4) NOT NULL, S365 decimal(19, 4) NOT NULL, N365 decimal(19, 4) NULL,
    P365 decimal(19, 4) NOT NULL, PN365 decimal(19, 4) NULL, L3 decimal(19, 4) NOT NULL, P3 decimal(19, 4) NOT NULL,
    Customers365 int NOT NULL, LastSale date NULL, LastReceipt date NULL,
    DailyDemand decimal(19, 6) NOT NULL, SigmaDaily decimal(19, 6) NOT NULL, DemandCv decimal(9, 3) NULL,
    LeadTime int NOT NULL, LeadTimeSource nvarchar(20) COLLATE DATABASE_DEFAULT NOT NULL, LeadTimeSamples int NOT NULL,
    PolicyMin decimal(19, 4) NULL, PolicyMax decimal(19, 4) NULL,
    SafetyStock decimal(19, 4) NULL, ReorderPoint decimal(19, 4) NULL, OrderUpTo decimal(19, 4) NULL,
    SuggestedQty decimal(19, 4) NULL, SuggestionReason nvarchar(300) COLLATE DATABASE_DEFAULT NULL,
    ExcessQty decimal(19, 4) NULL, Signal nvarchar(20) COLLATE DATABASE_DEFAULT NULL, AbcClass char(1) COLLATE DATABASE_DEFAULT NULL,
    XyzClass char(1) COLLATE DATABASE_DEFAULT NULL
  );

  INSERT #metric (ProductId, ItemId, SupplierId, IsActive, Stock, Reserved, Available, OnOrder, OnOrderSource, NextDeliveryDate,
    UnitCost, CostSource, OrderMultiple, S30, S90, S365, N365, P365, PN365, L3, P3, Customers365, LastSale, LastReceipt,
    DailyDemand, SigmaDaily, DemandCv, LeadTime, LeadTimeSource, LeadTimeSamples, PolicyMin, PolicyMax)
  SELECT product.ProductId, product.ItemId, product.SupplierId, product.IsActive,
    ISNULL(onHand.Quantity, 0),
    ISNULL(onHand.ReservedQuantity, 0),
    COALESCE(onHand.AvailableQuantity, ISNULL(onHand.Quantity, 0) - ISNULL(onHand.ReservedQuantity, 0)),
    COALESCE(onHand.SupplierOrderedQuantity, openPurch.Qty, openBarkawi.Qty, 0),
    CASE WHEN onHand.SupplierOrderedQuantity IS NOT NULL THEN N''SAOP_ZALOGA'' WHEN openPurch.Qty IS NOT NULL THEN N''NAROCILA''
         WHEN openBarkawi.Qty IS NOT NULL THEN N''BARKAWI'' END,
    COALESCE(nextDelivery.NextDate, openPurch.NextDate),
    cost.UnitCost, cost.CostSource, ISNULL(cost.OrderMultiple, 1),
    ISNULL(sales.S30, 0), ISNULL(sales.S90, 0), ISNULL(sales.S365, 0), sales.N365, ISNULL(sales.P365, 0), sales.PN365,
    ISNULL(sales.L3, 0), ISNULL(sales.P3, 0), ISNULL(sales.Customers365, 0), sales.LastSale, lastReceipt.LastReceipt,
    CASE WHEN ISNULL(sales.SWindow, 0) > 0 THEN sales.SWindow / @Window ELSE 0 END,
    ISNULL(variability.SigmaMonth, 0) / SQRT(30.4),
    CASE WHEN variability.MeanMonth > 0 THEN variability.SigmaMonth / variability.MeanMonth END,
    COALESCE(CASE WHEN leadItem.Samples >= 2 THEN CONVERT(int, ROUND(leadItem.Median, 0)) END,
             CASE WHEN leadSupplier.Samples >= 3 THEN CONVERT(int, ROUND(leadSupplier.AvgLead, 0)) END,
             NULLIF(planning.PurchaseLeadTimeDays, 0), @DefaultLead),
    CASE WHEN leadItem.Samples >= 2 THEN N''IZMERJEN'' WHEN leadSupplier.Samples >= 3 THEN N''DOBAVITELJ''
         WHEN NULLIF(planning.PurchaseLeadTimeDays, 0) IS NOT NULL THEN N''SAOP'' ELSE N''PRIVZETO'' END,
    COALESCE(CASE WHEN leadItem.Samples >= 2 THEN leadItem.Samples END, CASE WHEN leadSupplier.Samples >= 3 THEN leadSupplier.Samples END, 0),
    NULLIF(policy.MinimumStock, 0), NULLIF(policy.MaximumStock, 0)
  FROM #product AS product
  LEFT JOIN ana.StockDaily AS onHand ON onHand.OrganizationId = @OrganizationId AND onHand.SnapshotDate = @Today AND onHand.ProductId = product.ProductId
  LEFT JOIN #cost AS cost ON cost.ProductId = product.ProductId
  LEFT JOIN #sales AS sales ON sales.ItemId = product.ItemId
  LEFT JOIN #variability AS variability ON variability.ItemId = product.ItemId
  LEFT JOIN #leadItem AS leadItem ON leadItem.ItemId = product.ItemId
  LEFT JOIN #leadSupplier AS leadSupplier ON leadSupplier.SupplierId = product.SupplierId
  LEFT JOIN #lastReceipt AS lastReceipt ON lastReceipt.ItemId = product.ItemId
  LEFT JOIN #openPurch AS openPurch ON openPurch.ItemId = product.ItemId
  LEFT JOIN #openBarkawi AS openBarkawi ON openBarkawi.ItemId = product.ItemId
  LEFT JOIN #nextDelivery AS nextDelivery ON nextDelivery.ItemId = product.ItemId
  OUTER APPLY (SELECT TOP (1) plan_.PurchaseLeadTimeDays FROM canon.ProductPlanning AS plan_ WHERE plan_.ProductId = product.ProductId) AS planning
  OUTER APPLY (SELECT TOP (1) stockPolicy.MinimumStock, stockPolicy.MaximumStock FROM canon.ProductStockPolicy AS stockPolicy
               WHERE stockPolicy.ProductId = product.ProductId ORDER BY stockPolicy.WarehouseCode) AS policy
  WHERE product.IsActive = 1 OR onHand.ProductId IS NOT NULL OR sales.ItemId IS NOT NULL OR openPurch.ItemId IS NOT NULL;

  -- Formula: varnostna zaloga, točka naročila, ciljna raven.
  UPDATE #metric SET
    SafetyStock = @Z * SigmaDaily * SQRT(CONVERT(float, LeadTime + @Review)),
    ReorderPoint = DailyDemand * LeadTime + @Z * SigmaDaily * SQRT(CONVERT(float, LeadTime + @Review)),
    OrderUpTo = DailyDemand * (LeadTime + @Review) + @Z * SigmaDaily * SQRT(CONVERT(float, LeadTime + @Review));

  -- Predlog naročila (samo, kadar poznamo prodajo ali je v SAOP nastavljen MIN).
  UPDATE metric SET
    SuggestedQty = CASE WHEN need.Qty > 0 THEN CEILING(need.Qty / metric.OrderMultiple) * metric.OrderMultiple ELSE 0 END,
    SuggestionReason = CASE
      WHEN need.Qty <= 0 THEN NULL
      WHEN need.ByPolicy = 1 THEN CONCAT(N''Pod SAOP minimumom (MIN '', FORMAT(metric.PolicyMin, N''0.##''), N'')'')
      WHEN metric.Stock <= 0 THEN N''Ni zaloge, artikel se prodaja''
      ELSE CONCAT(N''Pod točko naročila ('', FORMAT(metric.ReorderPoint, N''0.#''), N'')'') END
  FROM #metric AS metric
  CROSS APPLY (SELECT Position = metric.Available + metric.OnOrder) AS inventory
  CROSS APPLY (SELECT FormulaNeed = CASE WHEN @Source <> N''BREZ'' AND metric.DailyDemand > 0 AND inventory.Position <= metric.ReorderPoint
                                         THEN metric.OrderUpTo - inventory.Position ELSE 0 END,
                      PolicyNeed = CASE WHEN metric.PolicyMin IS NOT NULL AND inventory.Position < metric.PolicyMin
                                        THEN COALESCE(metric.PolicyMax, metric.PolicyMin) - inventory.Position ELSE 0 END) AS parts
  CROSS APPLY (SELECT Qty = CASE WHEN parts.PolicyNeed > parts.FormulaNeed THEN parts.PolicyNeed ELSE parts.FormulaNeed END,
                      ByPolicy = CASE WHEN parts.PolicyNeed > parts.FormulaNeed THEN 1 ELSE 0 END) AS need;

  -- Presežek: nad ciljno ravnijo pri počasnem obratu, ali vsa zaloga, ko se ne prodaja.
  UPDATE #metric SET ExcessQty = CASE
    WHEN Stock <= 0 OR SuggestedQty > 0 THEN 0
    WHEN @CanJudgeDead = 1 AND (LastSale IS NULL OR LastSale <= DATEADD(day, -@Dead, @Today))
         AND (LastReceipt IS NULL OR LastReceipt <= DATEADD(day, -@Dead, @Today)) THEN Stock
    WHEN DailyDemand > 0 AND Available / DailyDemand > @Over AND Available > OrderUpTo THEN Available - OrderUpTo
    ELSE 0 END;

  UPDATE #metric SET Signal = CASE
    WHEN Stock <= 0 AND DailyDemand > 0 THEN N''BREZ_ZALOGE''
    WHEN SuggestedQty > 0 THEN N''NAROCI''
    WHEN Stock > 0 AND @CanJudgeDead = 1 AND (LastSale IS NULL OR LastSale <= DATEADD(day, -@Dead, @Today))
         AND (LastReceipt IS NULL OR LastReceipt <= DATEADD(day, -@Dead, @Today)) THEN N''ZALEZANO''
    WHEN Stock > 0 AND DailyDemand > 0 AND Available / DailyDemand > @Over THEN N''PREVEC''
    WHEN Stock > 0 OR DailyDemand > 0 OR S365 > 0 THEN N''V_REDU''
    ELSE N''NEAKTIVNO'' END;

  -- ABC po vrednosti prodaje v 365 dneh (brez neto zneska: količina × nabavna cena); XYZ po nihanju.
  ;WITH value_ AS (SELECT ProductId, Value = COALESCE(N365, S365 * UnitCost, 0) FROM #metric WHERE S365 > 0),
  ranked AS (SELECT ProductId, Value,
               Before = SUM(Value) OVER (ORDER BY Value DESC, ProductId ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),
               Total = SUM(Value) OVER ()
             FROM value_)
  UPDATE metric SET AbcClass = CASE WHEN ranked.Total <= 0 THEN N''C''
                                    WHEN ISNULL(ranked.Before, 0) / ranked.Total < 0.80 THEN N''A''
                                    WHEN ISNULL(ranked.Before, 0) / ranked.Total < 0.95 THEN N''B'' ELSE N''C'' END
  FROM #metric AS metric INNER JOIN ranked ON ranked.ProductId = metric.ProductId;

  UPDATE #metric SET XyzClass = CASE WHEN DemandCv IS NULL THEN NULL WHEN DemandCv < 0.5 THEN N''X'' WHEN DemandCv < 1.0 THEN N''Y'' ELSE N''Z'' END;

  /* --- Zapis kazalnikov artiklov ------------------------------------------------------------------------ */
  BEGIN TRANSACTION;
    DELETE ana.ItemMetric WHERE OrganizationId = @OrganizationId;
    INSERT ana.ItemMetric (OrganizationId, ProductId, ItemId, ItemName, Ean, SupplierId, SupplierName, ItemGroup, Department, IsActive,
      Stock, Reserved, Available, OnOrder, OnOrderSource, NextDeliveryDate, UnitCost, CostSource, StockValue,
      Sales30Qty, Sales90Qty, Sales365Qty, Sales365Net, SalesPrev365Qty, SalesPrev365Net, Sales365Margin, AvgSellPrice, Customers365,
      Last3mQty, Prev3mQty, TrendPct, YoyPct, DailyDemand, DemandCv, LastSaleDate, LastReceiptDate, CoverDays,
      LeadTimeDays, LeadTimeSource, LeadTimeSamples, SafetyStock, ReorderPoint, OrderUpToLevel, OrderMultiple, PolicyMin, PolicyMax,
      SuggestedQty, SuggestedValue, SuggestionReason, ExcessQty, ExcessValue, AbcClass, XyzClass, Signal, DemandSource, CalculatedUtc)
    SELECT @OrganizationId, metric.ProductId, metric.ItemId, LEFT(name_.Value, 400), product.Ean, metric.SupplierId, LEFT(partner.PartnerName, 300),
      product.ItemGroup, product.Department, metric.IsActive,
      metric.Stock, metric.Reserved, metric.Available, metric.OnOrder, metric.OnOrderSource, metric.NextDeliveryDate,
      metric.UnitCost, metric.CostSource, CASE WHEN metric.Stock > 0 THEN metric.Stock * metric.UnitCost END,
      metric.S30, metric.S90, metric.S365, metric.N365, metric.P365, metric.PN365,
      CASE WHEN metric.N365 IS NOT NULL AND metric.UnitCost IS NOT NULL THEN metric.N365 - metric.S365 * metric.UnitCost END,
      CASE WHEN metric.S365 > 0 AND metric.N365 IS NOT NULL THEN metric.N365 / metric.S365 END,
      metric.Customers365, metric.L3, metric.P3,
      CASE WHEN metric.P3 > 0 THEN CONVERT(decimal(9, 1), CASE WHEN (metric.L3 - metric.P3) / metric.P3 * 100 > 99999 THEN 99999 ELSE (metric.L3 - metric.P3) / metric.P3 * 100 END) END,
      CASE WHEN metric.P365 > 0 THEN CONVERT(decimal(9, 1), CASE WHEN (metric.S365 - metric.P365) / metric.P365 * 100 > 99999 THEN 99999 ELSE (metric.S365 - metric.P365) / metric.P365 * 100 END) END,
      metric.DailyDemand, metric.DemandCv, metric.LastSale, metric.LastReceipt,
      CASE WHEN metric.DailyDemand > 0 THEN CONVERT(int, CASE WHEN metric.Available / metric.DailyDemand > 99999 THEN 99999
                                                        WHEN metric.Available < 0 THEN 0 ELSE metric.Available / metric.DailyDemand END) END,
      metric.LeadTime, metric.LeadTimeSource, metric.LeadTimeSamples,
      ISNULL(metric.SafetyStock, 0), ISNULL(metric.ReorderPoint, 0), ISNULL(metric.OrderUpTo, 0), metric.OrderMultiple,
      metric.PolicyMin, metric.PolicyMax,
      ISNULL(metric.SuggestedQty, 0), metric.SuggestedQty * metric.UnitCost, metric.SuggestionReason,
      ISNULL(metric.ExcessQty, 0), metric.ExcessQty * metric.UnitCost,
      metric.AbcClass, metric.XyzClass, metric.Signal, @Source, @Now
    FROM #metric AS metric
    INNER JOIN #product AS product ON product.ProductId = metric.ProductId
    LEFT JOIN canon.PartnerName AS partner ON partner.OrganizationId = @OrganizationId AND partner.PartnerCode = metric.SupplierId
    OUTER APPLY (SELECT TOP (1) text_.Value FROM canon.ProductText AS text_
                 WHERE text_.ProductId = metric.ProductId AND text_.TextType IN (N''TITLE_ERP'', N''WEB_TITLE'')
                 ORDER BY CASE WHEN text_.TextType = N''TITLE_ERP'' THEN 0 ELSE 1 END,
                          CASE WHEN text_.Lang = N''sl'' THEN 0 ELSE 1 END, text_.Lang) AS name_;
  COMMIT;

  /* --- Kazalniki po dobavitelju ------------------------------------------------------------------------- */
  SELECT SupplierId = ISNULL(header.SupplierID, N''''),
    OpenLines = SUM(CASE WHEN ISNULL(line.CanceledLine, 0) = 0 AND ISNULL(header.Status, N'''') NOT IN (N''Zaključeno'', N''Stornirano'')
                          AND ISNULL(line.Status, N'''') NOT IN (N''Zaključeno'', N''Stornirano'') THEN 1 ELSE 0 END),
    OverdueLines = SUM(CASE WHEN ISNULL(line.CanceledLine, 0) = 0 AND ISNULL(header.Status, N'''') NOT IN (N''Zaključeno'', N''Stornirano'')
                             AND ISNULL(line.Status, N'''') NOT IN (N''Zaključeno'', N''Stornirano'')
                             AND COALESCE(line.ForeseenDeliveryDate, header.ForeseenDeliveryDate) < @Today THEN 1 ELSE 0 END),
    LastOrder = MAX(CONVERT(date, header.OrderDate))
  INTO #purchSupplier
  FROM purch.PurchaseOrderHeader AS header
  LEFT JOIN purch.PurchaseOrderLine AS line ON line.PurchaseOrderHeaderId = header.PurchaseOrderHeaderId
  WHERE header.OrganizationId = @OrganizationId
  GROUP BY ISNULL(header.SupplierID, N'''');

  SELECT SupplierId = ISNULL(SupplierId, N''''), LastOrder = MAX(OrderDate)
  INTO #barkawiSupplier FROM ana.PurchaseOrderLine WHERE OrganizationId = @OrganizationId GROUP BY ISNULL(SupplierId, N'''');

  BEGIN TRANSACTION;
    DELETE ana.SupplierMetric WHERE OrganizationId = @OrganizationId;
    INSERT ana.SupplierMetric (OrganizationId, SupplierId, SupplierName, Items, ItemsInStock, ItemsSold365, StockValue, Sales365Net,
      SalesPrev365Net, Sales365Margin, YoyPct, ItemsToOrder, SuggestedOrderValue, StockoutItems, DeadItems, DeadStockValue,
      OverstockValue, LeadTimeAvgDays, LeadTimeSamples, OpenPurchaseLines, OverduePurchaseLines, LastPurchaseOrderDate, CalculatedUtc)
    SELECT @OrganizationId, item.SupplierId, MAX(item.SupplierName), COUNT(*),
      SUM(CASE WHEN item.Stock > 0 THEN 1 ELSE 0 END), SUM(CASE WHEN item.Sales365Qty > 0 THEN 1 ELSE 0 END),
      SUM(item.StockValue), SUM(item.Sales365Net), SUM(item.SalesPrev365Net), SUM(item.Sales365Margin),
      CASE WHEN SUM(item.SalesPrev365Net) > 0
           THEN CONVERT(decimal(9, 1), CASE WHEN (SUM(item.Sales365Net) - SUM(item.SalesPrev365Net)) / SUM(item.SalesPrev365Net) * 100 > 99999 THEN 99999
                ELSE (SUM(item.Sales365Net) - SUM(item.SalesPrev365Net)) / SUM(item.SalesPrev365Net) * 100 END) END,
      SUM(CASE WHEN item.SuggestedQty > 0 THEN 1 ELSE 0 END), SUM(item.SuggestedValue),
      SUM(CASE WHEN item.Signal = N''BREZ_ZALOGE'' THEN 1 ELSE 0 END),
      SUM(CASE WHEN item.Signal = N''ZALEZANO'' THEN 1 ELSE 0 END),
      SUM(CASE WHEN item.Signal = N''ZALEZANO'' THEN item.StockValue END),
      SUM(CASE WHEN item.Signal = N''PREVEC'' THEN item.ExcessValue END),
      MAX(leadSupplier.AvgLead), ISNULL(MAX(leadSupplier.Samples), 0),
      ISNULL(MAX(purchSupplier.OpenLines), 0), ISNULL(MAX(purchSupplier.OverdueLines), 0),
      CASE WHEN MAX(barkawiSupplier.LastOrder) IS NULL OR MAX(purchSupplier.LastOrder) >= MAX(barkawiSupplier.LastOrder) THEN MAX(purchSupplier.LastOrder) ELSE MAX(barkawiSupplier.LastOrder) END,
      @Now
    FROM ana.ItemMetric AS item
    LEFT JOIN #leadSupplier AS leadSupplier ON leadSupplier.SupplierId = item.SupplierId
    LEFT JOIN #purchSupplier AS purchSupplier ON purchSupplier.SupplierId = item.SupplierId
    LEFT JOIN #barkawiSupplier AS barkawiSupplier ON barkawiSupplier.SupplierId = item.SupplierId
    WHERE item.OrganizationId = @OrganizationId
    GROUP BY item.SupplierId;
  COMMIT;

  /* --- Čiščenje surovih strani in zapis stanja ----------------------------------------------------------- */
  DELETE ana.SourcePage WHERE OrganizationId = @OrganizationId AND FetchedUtc < DATEADD(day, -30, @Now);

  DECLARE @Items int = (SELECT COUNT(*) FROM #metric);
  EXEC ana.SetStreamState @OrganizationId = @OrganizationId, @Stream = N''IZRACUN'', @Succeeded = 1, @RowCount = @Items;

  SELECT DemandSource = @Source, Items = @Items,
    ToOrder = (SELECT COUNT(*) FROM #metric WHERE SuggestedQty > 0),
    Stockouts = (SELECT COUNT(*) FROM #metric WHERE Signal = N''BREZ_ZALOGE''),
    Dead = (SELECT COUNT(*) FROM #metric WHERE Signal = N''ZALEZANO''),
    Overstock = (SELECT COUNT(*) FROM #metric WHERE Signal = N''PREVEC'');
END;');

/* Pregled: kazalniki, trend 24 mesecev, signali, vrh dobaviteljev/artiklov/kupcev, svežina tokov. */
EXEC(N'CREATE OR ALTER PROCEDURE ana.GetOverview @OrganizationId int, @SupplierId nvarchar(100) = NULL, @Today date = NULL
AS
BEGIN
  SET NOCOUNT ON;
  IF @Today IS NULL SET @Today = CONVERT(date, SYSDATETIME());
  DECLARE @MonthStart date = DATEFROMPARTS(YEAR(@Today), MONTH(@Today), 1);
  DECLARE @From12 date = DATEADD(month, -11, @MonthStart);
  DECLARE @YearStart date = DATEFROMPARTS(YEAR(@Today), 1, 1);

  -- 1) Kazalniki
  SELECT
    Sales12Net = (SELECT SUM(NetSales) FROM ana.ItemMonthly WHERE OrganizationId = @OrganizationId AND MonthStart >= @From12
                  AND (@SupplierId IS NULL OR SupplierId = @SupplierId)),
    SalesPrev12Net = (SELECT SUM(NetSales) FROM ana.ItemMonthly WHERE OrganizationId = @OrganizationId
                  AND MonthStart >= DATEADD(month, -12, @From12) AND MonthStart < DATEADD(month, -12, DATEADD(month, 1, @MonthStart))
                  AND (@SupplierId IS NULL OR SupplierId = @SupplierId)),
    Sales12Qty = (SELECT SUM(QtySold) FROM ana.ItemMonthly WHERE OrganizationId = @OrganizationId AND MonthStart >= @From12
                  AND (@SupplierId IS NULL OR SupplierId = @SupplierId)),
    Sales12Margin = (SELECT SUM(NetSales - CostOfSales) FROM ana.ItemMonthly WHERE OrganizationId = @OrganizationId AND MonthStart >= @From12
                  AND NetSales IS NOT NULL AND CostOfSales IS NOT NULL AND (@SupplierId IS NULL OR SupplierId = @SupplierId)),
    SalesYtdNet = (SELECT SUM(NetSales) FROM ana.ItemMonthly WHERE OrganizationId = @OrganizationId AND MonthStart >= @YearStart
                  AND (@SupplierId IS NULL OR SupplierId = @SupplierId)),
    StockValue = SUM(metric.StockValue),
    ItemsInStock = SUM(CASE WHEN metric.Stock > 0 THEN 1 ELSE 0 END),
    StockWithoutCost = SUM(CASE WHEN metric.Stock > 0 AND metric.UnitCost IS NULL THEN 1 ELSE 0 END),
    DeadStockValue = SUM(CASE WHEN metric.Signal = N''ZALEZANO'' THEN metric.StockValue END),
    DeadItems = SUM(CASE WHEN metric.Signal = N''ZALEZANO'' THEN 1 ELSE 0 END),
    OverstockValue = SUM(CASE WHEN metric.Signal = N''PREVEC'' THEN metric.ExcessValue END),
    OverstockItems = SUM(CASE WHEN metric.Signal = N''PREVEC'' THEN 1 ELSE 0 END),
    ToOrderItems = SUM(CASE WHEN metric.SuggestedQty > 0 THEN 1 ELSE 0 END),
    ToOrderValue = SUM(metric.SuggestedValue),
    StockoutItems = SUM(CASE WHEN metric.Signal = N''BREZ_ZALOGE'' THEN 1 ELSE 0 END),
    CalculatedUtc = MAX(metric.CalculatedUtc),
    DemandSource = MAX(metric.DemandSource)
  FROM ana.ItemMetric AS metric
  WHERE metric.OrganizationId = @OrganizationId AND (@SupplierId IS NULL OR metric.SupplierId = @SupplierId);

  -- 2) Trend: 24 mesecev z ničlami za mesece brez prodaje
  ;WITH months AS (SELECT MonthStart = DATEADD(month, -n.n, @MonthStart)
                   FROM (VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9),(10),(11),(12),(13),(14),(15),(16),(17),(18),(19),(20),(21),(22),(23)) AS n(n)),
  sums AS (SELECT MonthStart, Qty = SUM(QtySold), Net = SUM(NetSales), Cost = SUM(CostOfSales), Ordered = SUM(QtyOrdered)
           FROM ana.ItemMonthly WHERE OrganizationId = @OrganizationId AND MonthStart >= DATEADD(month, -35, @MonthStart)
             AND (@SupplierId IS NULL OR SupplierId = @SupplierId)
           GROUP BY MonthStart)
  SELECT months.MonthStart, Qty = ISNULL(cur.Qty, 0), Net = cur.Net, Margin = cur.Net - cur.Cost, Ordered = cur.Ordered,
    PrevYearQty = prev.Qty, PrevYearNet = prev.Net
  FROM months
  LEFT JOIN sums AS cur ON cur.MonthStart = months.MonthStart
  LEFT JOIN sums AS prev ON prev.MonthStart = DATEADD(month, -12, months.MonthStart)
  ORDER BY months.MonthStart;

  -- 3) Signali
  SELECT Signal, Items = COUNT(*), StockValue = SUM(StockValue), SuggestedValue = SUM(SuggestedValue), ExcessValue = SUM(ExcessValue)
  FROM ana.ItemMetric
  WHERE OrganizationId = @OrganizationId AND (@SupplierId IS NULL OR SupplierId = @SupplierId)
  GROUP BY Signal;

  -- 4) Vrh dobaviteljev
  SELECT TOP (10) SupplierId, SupplierName, Sales365Net, SalesPrev365Net, YoyPct, StockValue, ItemsToOrder, SuggestedOrderValue, DeadStockValue
  FROM ana.SupplierMetric
  WHERE OrganizationId = @OrganizationId AND @SupplierId IS NULL AND ISNULL(Sales365Net, 0) > 0
  ORDER BY Sales365Net DESC;

  -- 5) Vrh artiklov
  SELECT TOP (10) ProductId, ItemId, ItemName, Sales365Qty, Sales365Net, YoyPct, Stock, Signal
  FROM ana.ItemMetric
  WHERE OrganizationId = @OrganizationId AND (@SupplierId IS NULL OR SupplierId = @SupplierId) AND Sales365Qty > 0
  ORDER BY ISNULL(Sales365Net, Sales365Qty * ISNULL(UnitCost, 0)) DESC, Sales365Qty DESC;

  -- 6) Vrh kupcev (samo iz računov)
  SELECT TOP (10) line.CustomerId, CustomerName = COALESCE(MAX(partner.PartnerName), MAX(line.CustomerName)),
    Net = SUM(line.NetAmountEur), Invoices = COUNT(DISTINCT CONCAT(line.InvoiceYear, N''/'', line.InvoiceBook, N''/'', line.InvoiceNumber))
  FROM ana.SalesInvoiceLine AS line
  LEFT JOIN canon.PartnerName AS partner ON partner.OrganizationId = line.OrganizationId AND partner.PartnerCode = line.CustomerId
  WHERE line.OrganizationId = @OrganizationId AND line.IsCancelled = 0 AND line.InvoiceDate > DATEADD(day, -365, @Today)
    AND (@SupplierId IS NULL OR EXISTS (SELECT 1 FROM ana.ItemMetric AS metric WHERE metric.OrganizationId = line.OrganizationId
                                        AND metric.ProductId = line.ProductId AND metric.SupplierId = @SupplierId))
  GROUP BY line.CustomerId
  ORDER BY SUM(line.NetAmountEur) DESC;

  -- 7) Svežina tokov
  SELECT Stream, LastAttemptUtc, LastSuccessUtc, WatermarkUtc, LastRowCount, LastError
  FROM ana.StreamState WHERE OrganizationId = @OrganizationId;

  -- 8) Ime dobavitelja v filtru
  SELECT SupplierName = COALESCE((SELECT TOP (1) SupplierName FROM ana.SupplierMetric WHERE OrganizationId = @OrganizationId AND SupplierId = @SupplierId),
                                 (SELECT TOP (1) PartnerName FROM canon.PartnerName WHERE OrganizationId = @OrganizationId AND PartnerCode = @SupplierId))
  WHERE @SupplierId IS NOT NULL;
END;');

/* Artikli: iskanje (brez šumnikov), filtri, razvrščanje in strežniško listanje; tretji niz = števci po signalih. */
EXEC(N'CREATE OR ALTER PROCEDURE ana.GetItemMetrics
  @OrganizationId int, @Search nvarchar(200) = NULL, @SupplierId nvarchar(100) = NULL, @Signal nvarchar(20) = NULL,
  @Abc char(1) = NULL, @Sort nvarchar(20) = NULL, @Descending bit = 1, @Skip int = 0, @Take int = 50,
  @ProductIdsJson nvarchar(max) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'''');
  DECLARE @Like nvarchar(210) = CASE WHEN @Search IS NULL THEN NULL
    ELSE N''%'' + REPLACE(REPLACE(REPLACE(@Search, N''['', N''[[]''), N''%'', N''[%]''), N''_'', N''[_]'') + N''%'' END;
  IF @Take IS NULL OR @Take < 1 SET @Take = 50;
  IF @Take > 100000 SET @Take = 100000;
  IF @Skip IS NULL OR @Skip < 0 SET @Skip = 0;

  CREATE TABLE #ids (ProductId bigint NOT NULL PRIMARY KEY);
  IF @ProductIdsJson IS NOT NULL AND ISJSON(@ProductIdsJson) = 1
    INSERT #ids SELECT DISTINCT TRY_CONVERT(bigint, value) FROM OPENJSON(@ProductIdsJson) WHERE TRY_CONVERT(bigint, value) IS NOT NULL;
  DECLARE @ById bit = CASE WHEN @ProductIdsJson IS NOT NULL THEN 1 ELSE 0 END;

  SELECT metric.*
  INTO #filtered
  FROM ana.ItemMetric AS metric
  WHERE metric.OrganizationId = @OrganizationId
    AND (@ById = 0 OR EXISTS (SELECT 1 FROM #ids WHERE #ids.ProductId = metric.ProductId))
    AND (@SupplierId IS NULL OR metric.SupplierId = @SupplierId)
    AND (@Abc IS NULL OR metric.AbcClass = @Abc)
    AND (@Like IS NULL OR metric.ItemId LIKE @Like OR metric.Ean LIKE @Like
         OR metric.ItemName COLLATE Latin1_General_CI_AI LIKE @Like COLLATE Latin1_General_CI_AI
         OR metric.SupplierName COLLATE Latin1_General_CI_AI LIKE @Like COLLATE Latin1_General_CI_AI);

  SELECT f.ProductId, f.ItemId, f.ItemName, f.Ean, f.SupplierId, f.SupplierName, f.AbcClass, f.XyzClass, f.Signal,
    f.Stock, f.Available, f.OnOrder, f.NextDeliveryDate, f.UnitCost, f.StockValue, f.Sales30Qty, f.Sales90Qty, f.Sales365Qty,
    f.Sales365Net, f.Sales365Margin, f.TrendPct, f.YoyPct, f.CoverDays, f.LastSaleDate, f.LeadTimeDays, f.LeadTimeSource,
    f.ReorderPoint, f.OrderUpToLevel, f.SuggestedQty, f.SuggestedValue, f.SuggestionReason, f.ExcessQty, f.ExcessValue,
    f.PolicyMin, f.PolicyMax, f.OrderMultiple, f.SafetyStock, f.DailyDemand
  FROM #filtered AS f
  WHERE (@Signal IS NULL AND (@ById = 1 OR f.Signal <> N''NEAKTIVNO'')) OR f.Signal = @Signal
  ORDER BY
    CASE WHEN @Descending = 0 THEN CASE @Sort WHEN N''sifra'' THEN f.ItemId WHEN N''naziv'' THEN f.ItemName WHEN N''dobavitelj'' THEN f.SupplierName END END ASC,
    CASE WHEN @Descending = 1 THEN CASE @Sort WHEN N''sifra'' THEN f.ItemId WHEN N''naziv'' THEN f.ItemName WHEN N''dobavitelj'' THEN f.SupplierName END END DESC,
    CASE WHEN @Descending = 0 THEN CASE @Sort WHEN N''zaloga'' THEN f.Stock WHEN N''vrednost'' THEN f.StockValue WHEN N''prodaja'' THEN f.Sales365Qty
      WHEN N''promet'' THEN f.Sales365Net WHEN N''trend'' THEN f.TrendPct WHEN N''pokritost'' THEN f.CoverDays WHEN N''predlog'' THEN f.SuggestedValue
      WHEN N''presezek'' THEN f.ExcessValue WHEN N''zadnja'' THEN DATEDIFF(day, ''2000-01-01'', f.LastSaleDate) WHEN N''dobava'' THEN f.LeadTimeDays END END ASC,
    CASE WHEN @Descending = 1 THEN CASE @Sort WHEN N''zaloga'' THEN f.Stock WHEN N''vrednost'' THEN f.StockValue WHEN N''prodaja'' THEN f.Sales365Qty
      WHEN N''promet'' THEN f.Sales365Net WHEN N''trend'' THEN f.TrendPct WHEN N''pokritost'' THEN f.CoverDays WHEN N''predlog'' THEN f.SuggestedValue
      WHEN N''presezek'' THEN f.ExcessValue WHEN N''zadnja'' THEN DATEDIFF(day, ''2000-01-01'', f.LastSaleDate) WHEN N''dobava'' THEN f.LeadTimeDays END END DESC,
    f.Sales365Qty DESC, f.ItemId
  OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY;

  SELECT Total = COUNT(*) FROM #filtered AS f
  WHERE (@Signal IS NULL AND (@ById = 1 OR f.Signal <> N''NEAKTIVNO'')) OR f.Signal = @Signal;

  SELECT Signal, Items = COUNT(*) FROM #filtered GROUP BY Signal;
END;');

EXEC(N'CREATE OR ALTER PROCEDURE ana.GetSupplierMetrics
  @OrganizationId int, @Search nvarchar(200) = NULL, @Sort nvarchar(20) = NULL, @Descending bit = 1, @Skip int = 0, @Take int = 50,
  @OnlyActive bit = 1
AS
BEGIN
  SET NOCOUNT ON;
  SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'''');
  DECLARE @Like nvarchar(210) = CASE WHEN @Search IS NULL THEN NULL
    ELSE N''%'' + REPLACE(REPLACE(REPLACE(@Search, N''['', N''[[]''), N''%'', N''[%]''), N''_'', N''[_]'') + N''%'' END;
  IF @Take IS NULL OR @Take < 1 SET @Take = 50;
  IF @Take > 100000 SET @Take = 100000;
  IF @Skip IS NULL OR @Skip < 0 SET @Skip = 0;

  SELECT supplier.*
  INTO #filtered
  FROM ana.SupplierMetric AS supplier
  WHERE supplier.OrganizationId = @OrganizationId
    AND (@OnlyActive = 0 OR supplier.ItemsInStock > 0 OR ISNULL(supplier.Sales365Net, 0) <> 0 OR supplier.ItemsSold365 > 0 OR supplier.OpenPurchaseLines > 0)
    AND (@Like IS NULL OR supplier.SupplierId LIKE @Like
         OR supplier.SupplierName COLLATE Latin1_General_CI_AI LIKE @Like COLLATE Latin1_General_CI_AI);

  SELECT SupplierId, SupplierName, Items, ItemsInStock, ItemsSold365, StockValue, Sales365Net, SalesPrev365Net, Sales365Margin, YoyPct,
    ItemsToOrder, SuggestedOrderValue, StockoutItems, DeadItems, DeadStockValue, OverstockValue, LeadTimeAvgDays, LeadTimeSamples,
    OpenPurchaseLines, OverduePurchaseLines, LastPurchaseOrderDate, CalculatedUtc
  FROM #filtered AS f
  ORDER BY
    CASE WHEN @Descending = 0 THEN CASE @Sort WHEN N''naziv'' THEN ISNULL(f.SupplierName, f.SupplierId) WHEN N''sifra'' THEN f.SupplierId END END ASC,
    CASE WHEN @Descending = 1 THEN CASE @Sort WHEN N''naziv'' THEN ISNULL(f.SupplierName, f.SupplierId) WHEN N''sifra'' THEN f.SupplierId END END DESC,
    CASE WHEN @Descending = 0 THEN CASE @Sort WHEN N''promet'' THEN f.Sales365Net WHEN N''trend'' THEN f.YoyPct WHEN N''zaloga'' THEN f.StockValue
      WHEN N''predlog'' THEN f.SuggestedOrderValue WHEN N''zalezano'' THEN f.DeadStockValue WHEN N''dobava'' THEN f.LeadTimeAvgDays
      WHEN N''zamude'' THEN f.OverduePurchaseLines WHEN N''marza'' THEN f.Sales365Margin END END ASC,
    CASE WHEN @Descending = 1 THEN CASE @Sort WHEN N''promet'' THEN f.Sales365Net WHEN N''trend'' THEN f.YoyPct WHEN N''zaloga'' THEN f.StockValue
      WHEN N''predlog'' THEN f.SuggestedOrderValue WHEN N''zalezano'' THEN f.DeadStockValue WHEN N''dobava'' THEN f.LeadTimeAvgDays
      WHEN N''zamude'' THEN f.OverduePurchaseLines WHEN N''marza'' THEN f.Sales365Margin END END DESC,
    f.Sales365Net DESC, f.SupplierId
  OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY;

  SELECT Total = COUNT(*) FROM #filtered;
END;');

/* Kartica artikla: kazalniki, mesečni trend, nabava (prevzemi in odprta naročila), kupci, gibanje zaloge. */
EXEC(N'CREATE OR ALTER PROCEDURE ana.GetItemDetail @OrganizationId int, @ProductId bigint, @Today date = NULL
AS
BEGIN
  SET NOCOUNT ON;
  IF @Today IS NULL SET @Today = CONVERT(date, SYSDATETIME());
  DECLARE @MonthStart date = DATEFROMPARTS(YEAR(@Today), MONTH(@Today), 1);
  DECLARE @ItemId nvarchar(100) = (SELECT ItemID FROM canon.Product WHERE ProductId = @ProductId AND OrganizationId = @OrganizationId);

  SELECT metric.*, setting.ServiceLevelZ, setting.ReviewPeriodDays, setting.DemandWindowDays, setting.DeadStockDays, setting.OverstockCoverDays
  FROM ana.ItemMetric AS metric
  CROSS JOIN ana.Setting AS setting
  WHERE metric.OrganizationId = @OrganizationId AND metric.ProductId = @ProductId AND setting.OrganizationId = @OrganizationId;

  ;WITH months AS (SELECT MonthStart = DATEADD(month, -n.n, @MonthStart)
                   FROM (VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9),(10),(11),(12),(13),(14),(15),(16),(17),(18),(19),(20),(21),(22),(23)) AS n(n))
  SELECT months.MonthStart, Qty = ISNULL(cur.QtySold, 0), Net = cur.NetSales, Ordered = cur.QtyOrdered, PrevYearQty = prev.QtySold
  FROM months
  LEFT JOIN ana.ItemMonthly AS cur ON cur.OrganizationId = @OrganizationId AND cur.ItemId = @ItemId AND cur.MonthStart = months.MonthStart
  LEFT JOIN ana.ItemMonthly AS prev ON prev.OrganizationId = @OrganizationId AND prev.ItemId = @ItemId AND prev.MonthStart = DATEADD(month, -12, months.MonthStart)
  ORDER BY months.MonthStart;

  SELECT TOP (30) Source, Document, SupplierId, OrderDate, Qty, ReceivedQty, ExpectedDate, ReceivedDate, LeadTimeDays, Status
  FROM (
    SELECT Source = N''SAOP naročilo'', Document = CONCAT(header.PurchaseOrderYear, N''/'', header.PurchaseOrderBook, N''/'', header.PurchaseOrderNumber),
      SupplierId = header.SupplierID, OrderDate = CONVERT(date, header.OrderDate), Qty = line.OrderedQuantity, ReceivedQty = CONVERT(decimal(19, 4), NULL),
      ExpectedDate = CONVERT(date, COALESCE(line.ForeseenDeliveryDate, header.ForeseenDeliveryDate)), ReceivedDate = CONVERT(date, NULL),
      LeadTimeDays = CONVERT(int, NULL), Status = COALESCE(line.Status, header.Status)
    FROM purch.PurchaseOrderLine AS line INNER JOIN purch.PurchaseOrderHeader AS header ON header.PurchaseOrderHeaderId = line.PurchaseOrderHeaderId
    WHERE header.OrganizationId = @OrganizationId AND line.ItemID = @ItemId
    UNION ALL
    SELECT N''Prevzem'', PurchaseOrderId, SupplierId, OrderDate, RequestedQty, ReceivedQty, NULL, ReceivedDate, LeadTimeDays, LineStatus
    FROM ana.PurchaseOrderLine WHERE OrganizationId = @OrganizationId AND ItemId = @ItemId
  ) AS purchase
  ORDER BY OrderDate DESC;

  SELECT TOP (10) line.CustomerId, CustomerName = COALESCE(MAX(partner.PartnerName), MAX(line.CustomerName)),
    Qty = SUM(line.Quantity), Net = SUM(line.NetAmountEur), LastDate = MAX(line.InvoiceDate)
  FROM ana.SalesInvoiceLine AS line
  LEFT JOIN canon.PartnerName AS partner ON partner.OrganizationId = line.OrganizationId AND partner.PartnerCode = line.CustomerId
  WHERE line.OrganizationId = @OrganizationId AND line.ItemId = @ItemId AND line.IsCancelled = 0 AND line.InvoiceDate > DATEADD(day, -365, @Today)
  GROUP BY line.CustomerId
  ORDER BY SUM(line.Quantity) DESC;

  SELECT SnapshotDate, Quantity, AvailableQuantity
  FROM ana.StockDaily WHERE OrganizationId = @OrganizationId AND ProductId = @ProductId AND SnapshotDate > DATEADD(day, -365, @Today)
  ORDER BY SnapshotDate;
END;');

EXEC(N'CREATE OR ALTER PROCEDURE ana.GetSettings @OrganizationId int
AS
BEGIN
  SET NOCOUNT ON;
  INSERT ana.Setting (OrganizationId) SELECT @OrganizationId
  WHERE EXISTS (SELECT 1 FROM dbo.OrganizationConfig WHERE OrganizationId = @OrganizationId)
    AND NOT EXISTS (SELECT 1 FROM ana.Setting WHERE OrganizationId = @OrganizationId);

  SELECT OrganizationId, ServiceLevelZ, ReviewPeriodDays, DefaultLeadTimeDays, DemandWindowDays, DeadStockDays, OverstockCoverDays,
    CostPriceList, UpdatedUtc, UpdatedBy
  FROM ana.Setting WHERE OrganizationId = @OrganizationId;

  SELECT TOP (20) SettingHistoryId, OldValueJson, NewValueJson, ChangedUtc, ChangedBy
  FROM ana.SettingHistory WHERE OrganizationId = @OrganizationId ORDER BY SettingHistoryId DESC;

  SELECT DISTINCT price.PriceList
  FROM canon.ProductPrice AS price INNER JOIN canon.Product AS product ON product.ProductId = price.ProductId
  WHERE product.OrganizationId = @OrganizationId AND price.IsActive = 1
  ORDER BY price.PriceList;
END;');

EXEC(N'CREATE OR ALTER PROCEDURE ana.SaveSettings
  @OrganizationId int, @ServiceLevelZ decimal(5, 2), @ReviewPeriodDays int, @DefaultLeadTimeDays int, @DemandWindowDays int,
  @DeadStockDays int, @OverstockCoverDays int, @CostPriceList nvarchar(40), @Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  IF NULLIF(LTRIM(RTRIM(@Actor)), N'''') IS NULL THROW 52846, N''284: manjka uporabnik, ki shranjuje nastavitve.'', 1;
  SET @CostPriceList = NULLIF(LTRIM(RTRIM(@CostPriceList)), N'''');
  IF @CostPriceList IS NULL THROW 52847, N''284: cenik nabavne cene je obvezen.'', 1;

  DECLARE @Old nvarchar(max) = (SELECT ServiceLevelZ, ReviewPeriodDays, DefaultLeadTimeDays, DemandWindowDays, DeadStockDays,
    OverstockCoverDays, CostPriceList FROM ana.Setting WHERE OrganizationId = @OrganizationId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

  BEGIN TRANSACTION;
    MERGE ana.Setting AS target
    USING (SELECT @OrganizationId AS OrganizationId) AS source ON target.OrganizationId = source.OrganizationId
    WHEN MATCHED THEN UPDATE SET ServiceLevelZ = @ServiceLevelZ, ReviewPeriodDays = @ReviewPeriodDays,
      DefaultLeadTimeDays = @DefaultLeadTimeDays, DemandWindowDays = @DemandWindowDays, DeadStockDays = @DeadStockDays,
      OverstockCoverDays = @OverstockCoverDays, CostPriceList = @CostPriceList, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = @Actor
    WHEN NOT MATCHED THEN INSERT (OrganizationId, ServiceLevelZ, ReviewPeriodDays, DefaultLeadTimeDays, DemandWindowDays, DeadStockDays,
      OverstockCoverDays, CostPriceList, UpdatedBy)
      VALUES (@OrganizationId, @ServiceLevelZ, @ReviewPeriodDays, @DefaultLeadTimeDays, @DemandWindowDays, @DeadStockDays,
        @OverstockCoverDays, @CostPriceList, @Actor);

    DECLARE @New nvarchar(max) = (SELECT ServiceLevelZ, ReviewPeriodDays, DefaultLeadTimeDays, DemandWindowDays, DeadStockDays,
      OverstockCoverDays, CostPriceList FROM ana.Setting WHERE OrganizationId = @OrganizationId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    IF ISNULL(@Old, N'''') <> @New
      INSERT ana.SettingHistory (OrganizationId, OldValueJson, NewValueJson, ChangedBy) VALUES (@OrganizationId, @Old, @New, @Actor);
  COMMIT;
END;');


/* --- Razpored: en dnevni tek na podjetje (zajem + preračun) ------------------------------------------ */
MERGE ops.ScheduleProfile AS target
USING (VALUES
  (1, N'LOCAL', N'SAOP_ANALYTICS', 0, 86400, 129600, 5000, N'migracija 284'),
  (2, N'LOCAL', N'SAOP_ANALYTICS', 1, 86400, 129600, 5000, N'migracija 284'),
  (3, N'LOCAL', N'SAOP_ANALYTICS', 1, 86400, 129600, 5000, N'migracija 284'),
  (4, N'LOCAL', N'SAOP_ANALYTICS', 1, 86400, 129600, 5000, N'migracija 284')
) AS source (OrganizationId, Provider, Pipeline, IsEnabled, IntervalSeconds, StaleAfterSeconds, LockTimeoutMilliseconds, UpdatedBy)
ON target.OrganizationId = source.OrganizationId AND target.Pipeline = source.Pipeline
WHEN NOT MATCHED THEN
  INSERT (OrganizationId, Provider, Pipeline, IsEnabled, IntervalSeconds, StaleAfterSeconds, LockTimeoutMilliseconds, UpdatedBy)
  VALUES (source.OrganizationId, source.Provider, source.Pipeline, source.IsEnabled, source.IntervalSeconds, source.StaleAfterSeconds,
          source.LockTimeoutMilliseconds, source.UpdatedBy);

/* --- Pravice: prodajne številke so občutljive, zato privzeto samo skrbnik in komerciala ------------ */
INSERT sec.RolePermission (RoleId, PermissionKey)
SELECT roleValue.RoleId, keys_.PermissionKey
FROM sec.Role AS roleValue
CROSS JOIN (VALUES (N'page.analytics'), (N'tab.analytics.overview'), (N'tab.analytics.items'),
                   (N'tab.analytics.suppliers'), (N'tab.analytics.settings')) AS keys_ (PermissionKey)
WHERE roleValue.RoleCode IN (N'ADMIN', N'COMMERCIAL')
  AND NOT EXISTS (SELECT 1 FROM sec.RolePermission AS existing
                  WHERE existing.RoleId = roleValue.RoleId AND existing.PermissionKey = keys_.PermissionKey);

/* --- Preverba --------------------------------------------------------------------------------------- */
IF OBJECT_ID(N'ana.RefreshAnalytics', N'P') IS NULL OR OBJECT_ID(N'ana.GetItemMetrics', N'P') IS NULL
   OR OBJECT_ID(N'ana.UpsertSalesInvoiceLines', N'P') IS NULL OR OBJECT_ID(N'ana.SaveSettings', N'P') IS NULL
   OR OBJECT_ID(N'ana.ItemMetric', N'U') IS NULL OR OBJECT_ID(N'ana.StockDaily', N'U') IS NULL
  THROW 52848, N'284: objekti analitike manjkajo.', 1;
IF NOT EXISTS (SELECT 1 FROM ops.ScheduleProfile WHERE Pipeline = N'SAOP_ANALYTICS')
  THROW 52848, N'284: razpored SAOP_ANALYTICS manjka.', 1;
