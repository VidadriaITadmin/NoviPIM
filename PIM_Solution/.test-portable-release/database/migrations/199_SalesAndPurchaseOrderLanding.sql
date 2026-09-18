/*
  199 — pristajanje naročil kupcev (VNK) in naročil dobaviteljem (VND) iz SAOP.

  Izhodisce: MIN_MAX_proces.docx + preverjanje v zivem SAOP swaggerju (2026-09-14). Za MIN/MID/MAX
  formulo in ABC klasifikacijo rabimo: prodajno zgodovino, odprta naročila kupcev (VNK, da jih
  odstejemo od razpolozljive kolicine) in odprta naročila dobaviteljem (VND, da jih pristejemo).
  Noben od teh ni prej obstajal nikjer v PIM.

  Locen klic GetOrderRealisation (prodajna realizacija) je bil sprva nacrtovan kot tretji tok, a se
  je izkazal za odvecnega: GetOrder ze vrne Qty (narocena kolicina) in ShippedQTY (dejansko
  odpremljena) na vsaki vrstici VNK narocila — natanko to, kar bi realizacija dodatno prinesla.
  Uporabnik je to opazil (2026-09-14) in odlocil, da se locen tok ne gradi: prodajna zgodovina za
  ABC/formulo se racuna neposredno iz sales.OrderLine (Faza 3/4 nacrta), ne iz posebne tabele. To je
  bil tudi edini del nacrta brez zivega primera (ugibana oblika XML) — odstranitev pomeni manj kode
  IN manj tveganja hkrati.

  Endpointi in oblika XML za VNK/VND sta bila PREVERJENA z zivimi primeri (ne samo swagger shemo), ker
  se je prvi poskus ze enkrat izjalovil (VND je bil najprej narobe iskan pod /api/Order, dejansko je
  v ločenem modulu /api/PurchaseOrders) in ker shema swaggerja zavaja glede korena elementa:
    - Shema imenuje koren "OrderHeaderDetail" / "PurchaseOrderHeaderDetail", ziv odgovor pa ima koren
      <OrderHeader> / <PurchaseOrderHeader> (potrjeno z resnicnima primeroma: narocilo VNK 2026/3495
      in narocilo VND 2026/218).
    - <OrderLine OrderLineNo="1"> nosi zaporedno stevilko vrstice kot XML ATRIBUT, ne element.
      <PurchaseOrderLine><LineSEQNumber>1</LineSEQNumber> pa isto stevilko nosi kot navaden element.
      Torej isti koncept (zaporedje vrstice), a dve razlicni XML obliki med VNK in VND.

  Glava in vrstice se pristanejo iz ISTEGA raw.Inbox zapisa: ker ima map.EntityMapping en RecordXPath
  na EntityType, RecordXPath kaze na PONAVLJAJOCO se vrstico (Order/PurchaseOrderLine), polja glave pa
  se berejo relativno navzgor (vzorec ../../ItemID iz migracije 076/072) — podvojena na vsako vrstico
  istega narocila. Narocilo brez vrstic (ce sploh obstaja) se s tem ne bi pristalo — sprejemljiva
  omejitev, ker taksno narocilo tudi nima kolicin, pomembnih za MIN/MID/MAX.

  Samo za trenutno odprta narocila hodimo Status->Detail (glej nacrt, Faza 2) — zato tu ni locene
  tabele za GetOrderStatus/GetPurchaseOrdersStatus: to sta samo odkritvena klica, ki jih delavec
  uporabi v pomnilniku, da ve, katere kljuce (leto/knjiga/stevilka) sploh poklicati; v bazo pristane
  samo polni odgovor (GetOrder/GetPurchaseOrder).

  Atributni XPath (@OrderLineNo) je z izluscevalnikom (System.Xml.XPath, PIM.XmlMapping) tehnicno
  podprt, a v tem cevovodu doslej ni bil uporabljen — prva raba, preveriti z resnicnim tekom.
*/

SET XACT_ABORT ON;

/* --- 1) sheme in tabele ------------------------------------------------------- */

IF SCHEMA_ID(N'sales') IS NULL EXEC(N'CREATE SCHEMA sales');
IF SCHEMA_ID(N'purch') IS NULL EXEC(N'CREATE SCHEMA purch');

IF OBJECT_ID(N'sales.OrderHeader') IS NULL
BEGIN
  CREATE TABLE sales.OrderHeader
  (
    OrderHeaderId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_SalesOrderHeader PRIMARY KEY,
    OrganizationId int NOT NULL,
    OrderYear int NOT NULL,
    OrderBook nvarchar(20) NOT NULL,
    OrderNumber int NOT NULL,
    CustomerId nvarchar(50) NULL,
    CustomerTitle1 nvarchar(200) NULL,
    WarehouseId nvarchar(50) NULL,
    OrderDate datetime2(3) NULL,
    DeliveryDate datetime2(3) NULL,
    OrderStatus nvarchar(50) NULL,
    OrderDetailsStatus nvarchar(50) NULL,
    GrossAmount decimal(19,4) NULL,
    NetAmount decimal(19,4) NULL,
    SourceModifiedUtc datetime2(3) NULL,
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_SalesOrderHeader_UpdatedUtc DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_SalesOrderHeader UNIQUE (OrganizationId, OrderYear, OrderBook, OrderNumber),
    CONSTRAINT FK_SalesOrderHeader_Organization FOREIGN KEY (OrganizationId) REFERENCES dbo.OrganizationConfig(OrganizationId)
  );
END;

IF OBJECT_ID(N'sales.OrderLine') IS NULL
BEGIN
  CREATE TABLE sales.OrderLine
  (
    OrderLineId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_SalesOrderLine PRIMARY KEY,
    OrderHeaderId bigint NOT NULL,
    OrderLineNo int NOT NULL,
    ItemID nvarchar(100) NULL,
    ItemTitle1 nvarchar(200) NULL,
    ItemTitle2 nvarchar(200) NULL,
    Qty decimal(19,4) NULL,
    ShippedQTY decimal(19,4) NULL,
    UnitOfMeasure nvarchar(20) NULL,
    WareHouseId nvarchar(50) NULL,
    DeliveryDate datetime2(3) NULL,
    Status nvarchar(50) NULL,
    ClosedLine bit NULL,
    NetAmount decimal(19,4) NULL,
    ItemBarCode nvarchar(100) NULL,
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_SalesOrderLine_UpdatedUtc DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_SalesOrderLine UNIQUE (OrderHeaderId, OrderLineNo),
    CONSTRAINT FK_SalesOrderLine_Header FOREIGN KEY (OrderHeaderId) REFERENCES sales.OrderHeader(OrderHeaderId)
  );
  CREATE INDEX IX_SalesOrderLine_Item ON sales.OrderLine(ItemID) INCLUDE(Qty, ShippedQTY, ClosedLine, Status);
END;

IF OBJECT_ID(N'purch.PurchaseOrderHeader') IS NULL
BEGIN
  CREATE TABLE purch.PurchaseOrderHeader
  (
    PurchaseOrderHeaderId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_PurchaseOrderHeader PRIMARY KEY,
    OrganizationId int NOT NULL,
    PurchaseOrderYear int NOT NULL,
    PurchaseOrderBook nvarchar(20) NOT NULL,
    PurchaseOrderNumber int NOT NULL,
    SupplierID nvarchar(50) NULL,
    Status nvarchar(100) NULL,
    OrderDate datetime2(3) NULL,
    ForeseenDeliveryDate datetime2(3) NULL,
    WarehouseID nvarchar(50) NULL,
    NetAmountOrder decimal(19,4) NULL,
    GrossAmountOrder decimal(19,4) NULL,
    SourceModifiedUtc datetime2(3) NULL,
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_PurchaseOrderHeader_UpdatedUtc DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_PurchaseOrderHeader UNIQUE (OrganizationId, PurchaseOrderYear, PurchaseOrderBook, PurchaseOrderNumber),
    CONSTRAINT FK_PurchaseOrderHeader_Organization FOREIGN KEY (OrganizationId) REFERENCES dbo.OrganizationConfig(OrganizationId)
  );
END;

IF OBJECT_ID(N'purch.PurchaseOrderLine') IS NULL
BEGIN
  CREATE TABLE purch.PurchaseOrderLine
  (
    PurchaseOrderLineId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_PurchaseOrderLine PRIMARY KEY,
    PurchaseOrderHeaderId bigint NOT NULL,
    LineSEQNumber int NOT NULL,
    ItemID nvarchar(100) NULL,
    ItemTitle1 nvarchar(200) NULL,
    OrderedQuantity decimal(19,4) NULL,
    ForeseenDeliveryDate datetime2(3) NULL,
    UnitOfMeasure nvarchar(20) NULL,
    Status nvarchar(100) NULL,
    CanceledLine bit NULL,
    NetAmountOrdered decimal(19,4) NULL,
    ItemEAN nvarchar(100) NULL,
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_PurchaseOrderLine_UpdatedUtc DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_PurchaseOrderLine UNIQUE (PurchaseOrderHeaderId, LineSEQNumber),
    CONSTRAINT FK_PurchaseOrderLine_Header FOREIGN KEY (PurchaseOrderHeaderId) REFERENCES purch.PurchaseOrderHeader(PurchaseOrderHeaderId)
  );
  CREATE INDEX IX_PurchaseOrderLine_Item ON purch.PurchaseOrderLine(ItemID) INCLUDE(OrderedQuantity, Status, CanceledLine);
END;

/* --- 2) dva nova svetova v registru -------------------------------------------- */

IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE parent_object_id=OBJECT_ID(N'map.EntityMapping') AND name=N'CK_EntityMapping_TargetDomain')
  ALTER TABLE map.EntityMapping DROP CONSTRAINT CK_EntityMapping_TargetDomain;
ALTER TABLE map.EntityMapping WITH CHECK ADD CONSTRAINT CK_EntityMapping_TargetDomain
  CHECK (TargetDomain IN (N'Product', N'Warehouse', N'Language', N'ProductText', N'ProductAttributePair',
    N'ProductStockPolicy', N'Codebook', N'ProductStockAccounting', N'ProductPlanning', N'Customer',
    N'CustomerItem', N'CustomerGroupDiscount', N'Document', N'SalesOrder', N'PurchaseOrder'));

/* --- 3) preslikave na vseh aktivnih SAOP konektorjih (eno mesto za vse organizacije) --- */

MERGE map.EntityMapping AS target
USING
(
  SELECT connector.SourceConnectorId, entity.EntityType, entity.RecordXPath, entity.TargetDomain
  FROM map.SourceConnector connector
  CROSS JOIN (VALUES
    (N'GetOrder',            N'/OrderHeader/OrderLines/OrderLine',                       N'SalesOrder'),
    (N'GetPurchaseOrder',    N'/PurchaseOrderHeader/PurchaseOrderLines/PurchaseOrderLine', N'PurchaseOrder')
  ) entity(EntityType, RecordXPath, TargetDomain)
  WHERE connector.ConnectorType = N'SAOP' AND connector.IsActive = 1
) source
  ON target.SourceConnectorId = source.SourceConnectorId AND target.EntityType = source.EntityType
WHEN MATCHED THEN UPDATE SET RecordXPath = source.RecordXPath, TargetDomain = source.TargetDomain, IsActive = 1
WHEN NOT MATCHED THEN INSERT (SourceConnectorId, EntityType, RecordXPath, TargetDomain, IsActive)
  VALUES (source.SourceConnectorId, source.EntityType, source.RecordXPath, source.TargetDomain, 1);

MERGE map.FieldMapping AS target
USING
(
  SELECT connector.SourceConnectorId, field.EntityType, field.SourceElement, field.TargetFieldCode, field.IsRequired
  FROM map.SourceConnector connector
  CROSS JOIN (VALUES
    /* --- GetOrder (VNK): glava relativno navzgor iz OrderLine, vrstica relativno na samo sebo --- */
    (N'GetOrder', N'../../OrderYear/text()[1]',           N'Record.OrderYear',           CONVERT(bit,1)),
    (N'GetOrder', N'../../OrderBook/text()[1]',            N'Record.OrderBook',           CONVERT(bit,1)),
    (N'GetOrder', N'../../OrderNumber/text()[1]',          N'Record.OrderNumber',         CONVERT(bit,1)),
    (N'GetOrder', N'@OrderLineNo',                         N'Record.OrderLineNo',         CONVERT(bit,1)),
    (N'GetOrder', N'../../CustomerId/text()[1]',           N'Order.CustomerId',           CONVERT(bit,0)),
    (N'GetOrder', N'../../CustomerTitle1/text()[1]',       N'Order.CustomerTitle1',       CONVERT(bit,0)),
    (N'GetOrder', N'../../WarehouseId/text()[1]',          N'Order.WarehouseId',          CONVERT(bit,0)),
    (N'GetOrder', N'../../OrderDate/text()[1]',            N'Order.OrderDate',            CONVERT(bit,0)),
    (N'GetOrder', N'../../DeliveryDate/text()[1]',         N'Order.DeliveryDate',         CONVERT(bit,0)),
    (N'GetOrder', N'../../OrderStatus/text()[1]',          N'Order.OrderStatus',          CONVERT(bit,0)),
    (N'GetOrder', N'../../OrderDetailsStatus/text()[1]',   N'Order.OrderDetailsStatus',   CONVERT(bit,0)),
    (N'GetOrder', N'../../GrossAmount/text()[1]',          N'Order.GrossAmount',          CONVERT(bit,0)),
    (N'GetOrder', N'../../NetAmount/text()[1]',            N'Order.NetAmount',            CONVERT(bit,0)),
    (N'GetOrder', N'../../ModifiedTime/text()[1]',         N'Order.ModifiedTime',         CONVERT(bit,0)),
    (N'GetOrder', N'ItemID/text()[1]',                     N'OrderLine.ItemID',           CONVERT(bit,0)),
    (N'GetOrder', N'ItemTitle1/text()[1]',                 N'OrderLine.ItemTitle1',       CONVERT(bit,0)),
    (N'GetOrder', N'ItemTitle2/text()[1]',                 N'OrderLine.ItemTitle2',       CONVERT(bit,0)),
    (N'GetOrder', N'Qty/text()[1]',                        N'OrderLine.Qty',              CONVERT(bit,0)),
    (N'GetOrder', N'ShippedQTY/text()[1]',                 N'OrderLine.ShippedQTY',       CONVERT(bit,0)),
    (N'GetOrder', N'UnitOfMeasure/text()[1]',              N'OrderLine.UnitOfMeasure',    CONVERT(bit,0)),
    (N'GetOrder', N'WareHouseId/text()[1]',                N'OrderLine.WareHouseId',      CONVERT(bit,0)),
    (N'GetOrder', N'DeliveryDate/text()[1]',               N'OrderLine.DeliveryDate',     CONVERT(bit,0)),
    (N'GetOrder', N'Status/text()[1]',                     N'OrderLine.Status',           CONVERT(bit,0)),
    (N'GetOrder', N'ClosedLine/text()[1]',                 N'OrderLine.ClosedLine',       CONVERT(bit,0)),
    (N'GetOrder', N'NetAmount/text()[1]',                  N'OrderLine.NetAmount',        CONVERT(bit,0)),
    (N'GetOrder', N'ItemBarCode/text()[1]',                N'OrderLine.ItemBarCode',      CONVERT(bit,0)),
    /* --- GetPurchaseOrder (VND): enak vzorec, LineSEQNumber je tu element, ne atribut --- */
    (N'GetPurchaseOrder', N'../../PurchaseOrderYear/text()[1]',    N'Record.PurchaseOrderYear',        CONVERT(bit,1)),
    (N'GetPurchaseOrder', N'../../PurchaseOrderBook/text()[1]',    N'Record.PurchaseOrderBook',        CONVERT(bit,1)),
    (N'GetPurchaseOrder', N'../../PurchaseOrderNumber/text()[1]',  N'Record.PurchaseOrderNumber',      CONVERT(bit,1)),
    (N'GetPurchaseOrder', N'LineSEQNumber/text()[1]',              N'Record.LineSEQNumber',            CONVERT(bit,1)),
    (N'GetPurchaseOrder', N'../../SupplierID/text()[1]',           N'PurchaseOrder.SupplierID',        CONVERT(bit,0)),
    (N'GetPurchaseOrder', N'../../Status/text()[1]',               N'PurchaseOrder.Status',            CONVERT(bit,0)),
    (N'GetPurchaseOrder', N'../../OrderDate/text()[1]',            N'PurchaseOrder.OrderDate',         CONVERT(bit,0)),
    (N'GetPurchaseOrder', N'../../ForeseenDeliveryDate/text()[1]', N'PurchaseOrder.ForeseenDeliveryDate', CONVERT(bit,0)),
    (N'GetPurchaseOrder', N'../../WarehouseID/text()[1]',          N'PurchaseOrder.WarehouseID',       CONVERT(bit,0)),
    (N'GetPurchaseOrder', N'../../NetAmountOrder/text()[1]',       N'PurchaseOrder.NetAmountOrder',    CONVERT(bit,0)),
    (N'GetPurchaseOrder', N'../../GrossAmountOrder/text()[1]',     N'PurchaseOrder.GrossAmountOrder',  CONVERT(bit,0)),
    (N'GetPurchaseOrder', N'../../ModifiedTime/text()[1]',         N'PurchaseOrder.ModifiedTime',      CONVERT(bit,0)),
    (N'GetPurchaseOrder', N'ItemID/text()[1]',                     N'PurchaseOrderLine.ItemID',        CONVERT(bit,0)),
    (N'GetPurchaseOrder', N'ItemTitle1/text()[1]',                 N'PurchaseOrderLine.ItemTitle1',    CONVERT(bit,0)),
    (N'GetPurchaseOrder', N'OrderedQuantity/text()[1]',            N'PurchaseOrderLine.OrderedQuantity', CONVERT(bit,0)),
    (N'GetPurchaseOrder', N'ForeseenDeliveryDate/text()[1]',       N'PurchaseOrderLine.ForeseenDeliveryDate', CONVERT(bit,0)),
    (N'GetPurchaseOrder', N'UnitOfMeasure/text()[1]',              N'PurchaseOrderLine.UnitOfMeasure', CONVERT(bit,0)),
    (N'GetPurchaseOrder', N'Status/text()[1]',                     N'PurchaseOrderLine.Status',        CONVERT(bit,0)),
    (N'GetPurchaseOrder', N'CanceledLine/text()[1]',                N'PurchaseOrderLine.CanceledLine',  CONVERT(bit,0)),
    (N'GetPurchaseOrder', N'NetAmountOrdered/text()[1]',           N'PurchaseOrderLine.NetAmountOrdered', CONVERT(bit,0)),
    (N'GetPurchaseOrder', N'ItemEAN/text()[1]',                    N'PurchaseOrderLine.ItemEAN',       CONVERT(bit,0))
  ) field(EntityType, SourceElement, TargetFieldCode, IsRequired)
  WHERE connector.ConnectorType = N'SAOP' AND connector.IsActive = 1
) source
  ON target.SourceConnectorId = source.SourceConnectorId AND target.EntityType = source.EntityType
    AND target.TargetFieldCode = source.TargetFieldCode
WHEN MATCHED THEN UPDATE SET SourceElement = source.SourceElement, IsRequired = source.IsRequired, IsActive = 1
WHEN NOT MATCHED THEN INSERT (SourceConnectorId, EntityType, SourceElement, TargetFieldCode, IsRequired, IsActive)
  VALUES (source.SourceConnectorId, source.EntityType, source.SourceElement, source.TargetFieldCode, source.IsRequired, 1);

/* --- 4) postopki: glava+vrstice iz istih izluscenih vrednosti (vzorec 076) ----- */

EXEC(N'
CREATE OR ALTER PROCEDURE map.ProcessSalesOrderInbox
  @RunId uniqueidentifier,
  @OrganizationId int,
  @SourceCode nvarchar(100)
AS
BEGIN
  /*
    Narocilo kupca (VNK). En raw.Inbox zapis = en klic GetOrder = eno narocilo z N vrsticami.
    RecordXPath kaze na vrstico (OrderLine); polja glave se berejo relativno navzgor (../../) in so
    zato podvojena na vsaki vrstici — glava se zapise enkrat (zadnji zapis zmaga, ce bi kdaj prislo
    do neskladja), vrstice ena na vrstico.
  */
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  DECLARE @InboxId bigint;
  DECLARE order_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT inbox.InboxId
    FROM raw.Inbox inbox
    WHERE inbox.RunId=@RunId AND inbox.OrganizationId=@OrganizationId
      AND inbox.SourceCode=@SourceCode AND inbox.Status=''Pending''
      AND EXISTS
      (
        SELECT 1
        FROM map.EntityMapping entityMapping
        INNER JOIN map.SourceConnector connector ON connector.SourceConnectorId=entityMapping.SourceConnectorId
        WHERE connector.SourceCode=inbox.SourceCode AND connector.OrganizationId=inbox.OrganizationId
          AND entityMapping.EntityType=inbox.EntityType AND entityMapping.IsActive=1
          AND entityMapping.TargetDomain=''SalesOrder''
      )
    ORDER BY inbox.InboxId;

  OPEN order_cursor;
  FETCH NEXT FROM order_cursor INTO @InboxId;
  WHILE @@FETCH_STATUS=0
  BEGIN
    BEGIN TRY
      IF OBJECT_ID(''tempdb..#Vrstica'') IS NOT NULL DROP TABLE #Vrstica;
      BEGIN TRANSACTION;

      SELECT
        value.RecordOrdinal,
        TRY_CONVERT(int, MAX(CASE WHEN value.TargetFieldCode=''Record.OrderYear'' THEN value.Value END)) AS OrderYear,
        LTRIM(RTRIM(MAX(CASE WHEN value.TargetFieldCode=''Record.OrderBook'' THEN value.Value END))) COLLATE DATABASE_DEFAULT AS OrderBook,
        TRY_CONVERT(int, MAX(CASE WHEN value.TargetFieldCode=''Record.OrderNumber'' THEN value.Value END)) AS OrderNumber,
        TRY_CONVERT(int, MAX(CASE WHEN value.TargetFieldCode=''Record.OrderLineNo'' THEN value.Value END)) AS OrderLineNo,
        NULLIF(LTRIM(RTRIM(MAX(CASE WHEN value.TargetFieldCode=''Order.CustomerId'' THEN value.Value END))),'''') COLLATE DATABASE_DEFAULT AS CustomerId,
        MAX(CASE WHEN value.TargetFieldCode=''Order.CustomerTitle1'' THEN value.Value END) COLLATE DATABASE_DEFAULT AS CustomerTitle1,
        NULLIF(LTRIM(RTRIM(MAX(CASE WHEN value.TargetFieldCode=''Order.WarehouseId'' THEN value.Value END))),'''') COLLATE DATABASE_DEFAULT AS HeaderWarehouseId,
        TRY_CONVERT(datetime2(3), MAX(CASE WHEN value.TargetFieldCode=''Order.OrderDate'' THEN value.Value END)) AS OrderDate,
        TRY_CONVERT(datetime2(3), MAX(CASE WHEN value.TargetFieldCode=''Order.DeliveryDate'' THEN value.Value END)) AS HeaderDeliveryDate,
        NULLIF(LTRIM(RTRIM(MAX(CASE WHEN value.TargetFieldCode=''Order.OrderStatus'' THEN value.Value END))),'''') COLLATE DATABASE_DEFAULT AS OrderStatus,
        NULLIF(LTRIM(RTRIM(MAX(CASE WHEN value.TargetFieldCode=''Order.OrderDetailsStatus'' THEN value.Value END))),'''') COLLATE DATABASE_DEFAULT AS OrderDetailsStatus,
        TRY_CONVERT(decimal(19,4), MAX(CASE WHEN value.TargetFieldCode=''Order.GrossAmount'' THEN value.Value END)) AS GrossAmount,
        TRY_CONVERT(decimal(19,4), MAX(CASE WHEN value.TargetFieldCode=''Order.NetAmount'' THEN value.Value END)) AS HeaderNetAmount,
        TRY_CONVERT(datetime2(3), MAX(CASE WHEN value.TargetFieldCode=''Order.ModifiedTime'' THEN value.Value END)) AS SourceModifiedUtc,
        NULLIF(LTRIM(RTRIM(MAX(CASE WHEN value.TargetFieldCode=''OrderLine.ItemID'' THEN value.Value END))),'''') COLLATE DATABASE_DEFAULT AS ItemID,
        MAX(CASE WHEN value.TargetFieldCode=''OrderLine.ItemTitle1'' THEN value.Value END) COLLATE DATABASE_DEFAULT AS ItemTitle1,
        MAX(CASE WHEN value.TargetFieldCode=''OrderLine.ItemTitle2'' THEN value.Value END) COLLATE DATABASE_DEFAULT AS ItemTitle2,
        TRY_CONVERT(decimal(19,4), MAX(CASE WHEN value.TargetFieldCode=''OrderLine.Qty'' THEN value.Value END)) AS Qty,
        TRY_CONVERT(decimal(19,4), MAX(CASE WHEN value.TargetFieldCode=''OrderLine.ShippedQTY'' THEN value.Value END)) AS ShippedQTY,
        NULLIF(LTRIM(RTRIM(MAX(CASE WHEN value.TargetFieldCode=''OrderLine.UnitOfMeasure'' THEN value.Value END))),'''') COLLATE DATABASE_DEFAULT AS UnitOfMeasure,
        NULLIF(LTRIM(RTRIM(MAX(CASE WHEN value.TargetFieldCode=''OrderLine.WareHouseId'' THEN value.Value END))),'''') COLLATE DATABASE_DEFAULT AS LineWarehouseId,
        TRY_CONVERT(datetime2(3), MAX(CASE WHEN value.TargetFieldCode=''OrderLine.DeliveryDate'' THEN value.Value END)) AS LineDeliveryDate,
        NULLIF(LTRIM(RTRIM(MAX(CASE WHEN value.TargetFieldCode=''OrderLine.Status'' THEN value.Value END))),'''') COLLATE DATABASE_DEFAULT AS LineStatus,
        CASE LOWER(LTRIM(RTRIM(MAX(CASE WHEN value.TargetFieldCode=''OrderLine.ClosedLine'' THEN value.Value END))))
          WHEN ''true'' THEN CONVERT(bit,1) WHEN ''false'' THEN CONVERT(bit,0) END AS ClosedLine,
        TRY_CONVERT(decimal(19,4), MAX(CASE WHEN value.TargetFieldCode=''OrderLine.NetAmount'' THEN value.Value END)) AS LineNetAmount,
        NULLIF(LTRIM(RTRIM(MAX(CASE WHEN value.TargetFieldCode=''OrderLine.ItemBarCode'' THEN value.Value END))),'''') COLLATE DATABASE_DEFAULT AS ItemBarCode
      INTO #Vrstica
      FROM map.ExtractedValue value
      WHERE value.InboxId=@InboxId
        AND EXISTS(SELECT 1 FROM map.FieldMapping mapping WHERE mapping.FieldMappingId=value.FieldMappingId AND mapping.IsActive=1)
      GROUP BY value.RecordOrdinal;

      DELETE FROM #Vrstica WHERE OrderYear IS NULL OR NULLIF(OrderBook,'''') IS NULL OR OrderNumber IS NULL OR OrderLineNo IS NULL;

      ;WITH glava AS
      (
        SELECT *, ROW_NUMBER() OVER(PARTITION BY OrderYear,OrderBook,OrderNumber ORDER BY RecordOrdinal DESC) AS Mesto
        FROM #Vrstica
      )
      MERGE sales.OrderHeader AS target
      USING (SELECT * FROM glava WHERE Mesto=1) source
        ON target.OrganizationId=@OrganizationId AND target.OrderYear=source.OrderYear
          AND target.OrderBook=source.OrderBook AND target.OrderNumber=source.OrderNumber
      WHEN MATCHED THEN UPDATE SET
        CustomerId=source.CustomerId, CustomerTitle1=source.CustomerTitle1, WarehouseId=source.HeaderWarehouseId,
        OrderDate=source.OrderDate, DeliveryDate=source.HeaderDeliveryDate, OrderStatus=source.OrderStatus,
        OrderDetailsStatus=source.OrderDetailsStatus, GrossAmount=source.GrossAmount, NetAmount=source.HeaderNetAmount,
        SourceModifiedUtc=source.SourceModifiedUtc, UpdatedUtc=SYSUTCDATETIME()
      WHEN NOT MATCHED THEN INSERT
        (OrganizationId,OrderYear,OrderBook,OrderNumber,CustomerId,CustomerTitle1,WarehouseId,OrderDate,DeliveryDate,
         OrderStatus,OrderDetailsStatus,GrossAmount,NetAmount,SourceModifiedUtc)
        VALUES(@OrganizationId,source.OrderYear,source.OrderBook,source.OrderNumber,source.CustomerId,source.CustomerTitle1,
         source.HeaderWarehouseId,source.OrderDate,source.HeaderDeliveryDate,source.OrderStatus,source.OrderDetailsStatus,
         source.GrossAmount,source.HeaderNetAmount,source.SourceModifiedUtc);

      MERGE sales.OrderLine AS target
      USING
      (
        SELECT header.OrderHeaderId, v.OrderLineNo, v.ItemID, v.ItemTitle1, v.ItemTitle2, v.Qty, v.ShippedQTY,
          v.UnitOfMeasure, v.LineWarehouseId, v.LineDeliveryDate, v.LineStatus, v.ClosedLine, v.LineNetAmount, v.ItemBarCode
        FROM #Vrstica v
        INNER JOIN sales.OrderHeader header ON header.OrganizationId=@OrganizationId
          AND header.OrderYear=v.OrderYear AND header.OrderBook=v.OrderBook AND header.OrderNumber=v.OrderNumber
      ) source
        ON target.OrderHeaderId=source.OrderHeaderId AND target.OrderLineNo=source.OrderLineNo
      WHEN MATCHED THEN UPDATE SET
        ItemID=source.ItemID, ItemTitle1=source.ItemTitle1, ItemTitle2=source.ItemTitle2, Qty=source.Qty,
        ShippedQTY=source.ShippedQTY, UnitOfMeasure=source.UnitOfMeasure, WareHouseId=source.LineWarehouseId,
        DeliveryDate=source.LineDeliveryDate, Status=source.LineStatus, ClosedLine=source.ClosedLine,
        NetAmount=source.LineNetAmount, ItemBarCode=source.ItemBarCode, UpdatedUtc=SYSUTCDATETIME()
      WHEN NOT MATCHED THEN INSERT
        (OrderHeaderId,OrderLineNo,ItemID,ItemTitle1,ItemTitle2,Qty,ShippedQTY,UnitOfMeasure,WareHouseId,DeliveryDate,
         Status,ClosedLine,NetAmount,ItemBarCode)
        VALUES(source.OrderHeaderId,source.OrderLineNo,source.ItemID,source.ItemTitle1,source.ItemTitle2,source.Qty,
         source.ShippedQTY,source.UnitOfMeasure,source.LineWarehouseId,source.LineDeliveryDate,source.LineStatus,
         source.ClosedLine,source.LineNetAmount,source.ItemBarCode);

      UPDATE raw.Inbox SET Status=''Processed'', PayloadXml=NULL, ProcessedUtc=SYSUTCDATETIME() WHERE InboxId=@InboxId;
      DROP TABLE #Vrstica;
      COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
      IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
      DECLARE @Napaka nvarchar(2000)=LEFT(ERROR_MESSAGE(),2000);
      UPDATE raw.Inbox SET Status=''Quarantined'', ProcessedUtc=SYSUTCDATETIME(), FailureReason=@Napaka WHERE InboxId=@InboxId;
    END CATCH;
    FETCH NEXT FROM order_cursor INTO @InboxId;
  END;
  CLOSE order_cursor;
  DEALLOCATE order_cursor;
END;
');

EXEC(N'
CREATE OR ALTER PROCEDURE map.ProcessPurchaseOrderInbox
  @RunId uniqueidentifier,
  @OrganizationId int,
  @SourceCode nvarchar(100)
AS
BEGIN
  /* Narocilo dobavitelju (VND). Enak vzorec kot map.ProcessSalesOrderInbox, glej tam. */
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  DECLARE @InboxId bigint;
  DECLARE po_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT inbox.InboxId
    FROM raw.Inbox inbox
    WHERE inbox.RunId=@RunId AND inbox.OrganizationId=@OrganizationId
      AND inbox.SourceCode=@SourceCode AND inbox.Status=''Pending''
      AND EXISTS
      (
        SELECT 1
        FROM map.EntityMapping entityMapping
        INNER JOIN map.SourceConnector connector ON connector.SourceConnectorId=entityMapping.SourceConnectorId
        WHERE connector.SourceCode=inbox.SourceCode AND connector.OrganizationId=inbox.OrganizationId
          AND entityMapping.EntityType=inbox.EntityType AND entityMapping.IsActive=1
          AND entityMapping.TargetDomain=''PurchaseOrder''
      )
    ORDER BY inbox.InboxId;

  OPEN po_cursor;
  FETCH NEXT FROM po_cursor INTO @InboxId;
  WHILE @@FETCH_STATUS=0
  BEGIN
    BEGIN TRY
      IF OBJECT_ID(''tempdb..#Vrstica'') IS NOT NULL DROP TABLE #Vrstica;
      BEGIN TRANSACTION;

      SELECT
        value.RecordOrdinal,
        TRY_CONVERT(int, MAX(CASE WHEN value.TargetFieldCode=''Record.PurchaseOrderYear'' THEN value.Value END)) AS PurchaseOrderYear,
        LTRIM(RTRIM(MAX(CASE WHEN value.TargetFieldCode=''Record.PurchaseOrderBook'' THEN value.Value END))) COLLATE DATABASE_DEFAULT AS PurchaseOrderBook,
        TRY_CONVERT(int, MAX(CASE WHEN value.TargetFieldCode=''Record.PurchaseOrderNumber'' THEN value.Value END)) AS PurchaseOrderNumber,
        TRY_CONVERT(int, MAX(CASE WHEN value.TargetFieldCode=''Record.LineSEQNumber'' THEN value.Value END)) AS LineSEQNumber,
        NULLIF(LTRIM(RTRIM(MAX(CASE WHEN value.TargetFieldCode=''PurchaseOrder.SupplierID'' THEN value.Value END))),'''') COLLATE DATABASE_DEFAULT AS SupplierID,
        NULLIF(LTRIM(RTRIM(MAX(CASE WHEN value.TargetFieldCode=''PurchaseOrder.Status'' THEN value.Value END))),'''') COLLATE DATABASE_DEFAULT AS HeaderStatus,
        TRY_CONVERT(datetime2(3), MAX(CASE WHEN value.TargetFieldCode=''PurchaseOrder.OrderDate'' THEN value.Value END)) AS OrderDate,
        TRY_CONVERT(datetime2(3), MAX(CASE WHEN value.TargetFieldCode=''PurchaseOrder.ForeseenDeliveryDate'' THEN value.Value END)) AS HeaderForeseenDeliveryDate,
        NULLIF(LTRIM(RTRIM(MAX(CASE WHEN value.TargetFieldCode=''PurchaseOrder.WarehouseID'' THEN value.Value END))),'''') COLLATE DATABASE_DEFAULT AS WarehouseID,
        TRY_CONVERT(decimal(19,4), MAX(CASE WHEN value.TargetFieldCode=''PurchaseOrder.NetAmountOrder'' THEN value.Value END)) AS NetAmountOrder,
        TRY_CONVERT(decimal(19,4), MAX(CASE WHEN value.TargetFieldCode=''PurchaseOrder.GrossAmountOrder'' THEN value.Value END)) AS GrossAmountOrder,
        TRY_CONVERT(datetime2(3), MAX(CASE WHEN value.TargetFieldCode=''PurchaseOrder.ModifiedTime'' THEN value.Value END)) AS SourceModifiedUtc,
        NULLIF(LTRIM(RTRIM(MAX(CASE WHEN value.TargetFieldCode=''PurchaseOrderLine.ItemID'' THEN value.Value END))),'''') COLLATE DATABASE_DEFAULT AS ItemID,
        MAX(CASE WHEN value.TargetFieldCode=''PurchaseOrderLine.ItemTitle1'' THEN value.Value END) COLLATE DATABASE_DEFAULT AS ItemTitle1,
        TRY_CONVERT(decimal(19,4), MAX(CASE WHEN value.TargetFieldCode=''PurchaseOrderLine.OrderedQuantity'' THEN value.Value END)) AS OrderedQuantity,
        TRY_CONVERT(datetime2(3), MAX(CASE WHEN value.TargetFieldCode=''PurchaseOrderLine.ForeseenDeliveryDate'' THEN value.Value END)) AS LineForeseenDeliveryDate,
        NULLIF(LTRIM(RTRIM(MAX(CASE WHEN value.TargetFieldCode=''PurchaseOrderLine.UnitOfMeasure'' THEN value.Value END))),'''') COLLATE DATABASE_DEFAULT AS UnitOfMeasure,
        NULLIF(LTRIM(RTRIM(MAX(CASE WHEN value.TargetFieldCode=''PurchaseOrderLine.Status'' THEN value.Value END))),'''') COLLATE DATABASE_DEFAULT AS LineStatus,
        CASE LOWER(LTRIM(RTRIM(MAX(CASE WHEN value.TargetFieldCode=''PurchaseOrderLine.CanceledLine'' THEN value.Value END))))
          WHEN ''true'' THEN CONVERT(bit,1) WHEN ''false'' THEN CONVERT(bit,0) END AS CanceledLine,
        TRY_CONVERT(decimal(19,4), MAX(CASE WHEN value.TargetFieldCode=''PurchaseOrderLine.NetAmountOrdered'' THEN value.Value END)) AS NetAmountOrdered,
        NULLIF(LTRIM(RTRIM(MAX(CASE WHEN value.TargetFieldCode=''PurchaseOrderLine.ItemEAN'' THEN value.Value END))),'''') COLLATE DATABASE_DEFAULT AS ItemEAN
      INTO #Vrstica
      FROM map.ExtractedValue value
      WHERE value.InboxId=@InboxId
        AND EXISTS(SELECT 1 FROM map.FieldMapping mapping WHERE mapping.FieldMappingId=value.FieldMappingId AND mapping.IsActive=1)
      GROUP BY value.RecordOrdinal;

      DELETE FROM #Vrstica WHERE PurchaseOrderYear IS NULL OR NULLIF(PurchaseOrderBook,'''') IS NULL OR PurchaseOrderNumber IS NULL OR LineSEQNumber IS NULL;

      ;WITH glava AS
      (
        SELECT *, ROW_NUMBER() OVER(PARTITION BY PurchaseOrderYear,PurchaseOrderBook,PurchaseOrderNumber ORDER BY RecordOrdinal DESC) AS Mesto
        FROM #Vrstica
      )
      MERGE purch.PurchaseOrderHeader AS target
      USING (SELECT * FROM glava WHERE Mesto=1) source
        ON target.OrganizationId=@OrganizationId AND target.PurchaseOrderYear=source.PurchaseOrderYear
          AND target.PurchaseOrderBook=source.PurchaseOrderBook AND target.PurchaseOrderNumber=source.PurchaseOrderNumber
      WHEN MATCHED THEN UPDATE SET
        SupplierID=source.SupplierID, Status=source.HeaderStatus, OrderDate=source.OrderDate,
        ForeseenDeliveryDate=source.HeaderForeseenDeliveryDate, WarehouseID=source.WarehouseID,
        NetAmountOrder=source.NetAmountOrder, GrossAmountOrder=source.GrossAmountOrder,
        SourceModifiedUtc=source.SourceModifiedUtc, UpdatedUtc=SYSUTCDATETIME()
      WHEN NOT MATCHED THEN INSERT
        (OrganizationId,PurchaseOrderYear,PurchaseOrderBook,PurchaseOrderNumber,SupplierID,Status,OrderDate,
         ForeseenDeliveryDate,WarehouseID,NetAmountOrder,GrossAmountOrder,SourceModifiedUtc)
        VALUES(@OrganizationId,source.PurchaseOrderYear,source.PurchaseOrderBook,source.PurchaseOrderNumber,source.SupplierID,
         source.HeaderStatus,source.OrderDate,source.HeaderForeseenDeliveryDate,source.WarehouseID,source.NetAmountOrder,
         source.GrossAmountOrder,source.SourceModifiedUtc);

      MERGE purch.PurchaseOrderLine AS target
      USING
      (
        SELECT header.PurchaseOrderHeaderId, v.LineSEQNumber, v.ItemID, v.ItemTitle1, v.OrderedQuantity,
          v.LineForeseenDeliveryDate, v.UnitOfMeasure, v.LineStatus, v.CanceledLine, v.NetAmountOrdered, v.ItemEAN
        FROM #Vrstica v
        INNER JOIN purch.PurchaseOrderHeader header ON header.OrganizationId=@OrganizationId
          AND header.PurchaseOrderYear=v.PurchaseOrderYear AND header.PurchaseOrderBook=v.PurchaseOrderBook
          AND header.PurchaseOrderNumber=v.PurchaseOrderNumber
      ) source
        ON target.PurchaseOrderHeaderId=source.PurchaseOrderHeaderId AND target.LineSEQNumber=source.LineSEQNumber
      WHEN MATCHED THEN UPDATE SET
        ItemID=source.ItemID, ItemTitle1=source.ItemTitle1, OrderedQuantity=source.OrderedQuantity,
        ForeseenDeliveryDate=source.LineForeseenDeliveryDate, UnitOfMeasure=source.UnitOfMeasure, Status=source.LineStatus,
        CanceledLine=source.CanceledLine, NetAmountOrdered=source.NetAmountOrdered, ItemEAN=source.ItemEAN, UpdatedUtc=SYSUTCDATETIME()
      WHEN NOT MATCHED THEN INSERT
        (PurchaseOrderHeaderId,LineSEQNumber,ItemID,ItemTitle1,OrderedQuantity,ForeseenDeliveryDate,UnitOfMeasure,
         Status,CanceledLine,NetAmountOrdered,ItemEAN)
        VALUES(source.PurchaseOrderHeaderId,source.LineSEQNumber,source.ItemID,source.ItemTitle1,source.OrderedQuantity,
         source.LineForeseenDeliveryDate,source.UnitOfMeasure,source.LineStatus,source.CanceledLine,source.NetAmountOrdered,source.ItemEAN);

      UPDATE raw.Inbox SET Status=''Processed'', PayloadXml=NULL, ProcessedUtc=SYSUTCDATETIME() WHERE InboxId=@InboxId;
      DROP TABLE #Vrstica;
      COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
      IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
      DECLARE @Napaka nvarchar(2000)=LEFT(ERROR_MESSAGE(),2000);
      UPDATE raw.Inbox SET Status=''Quarantined'', ProcessedUtc=SYSUTCDATETIME(), FailureReason=@Napaka WHERE InboxId=@InboxId;
    END CATCH;
    FETCH NEXT FROM po_cursor INTO @InboxId;
  END;
  CLOSE po_cursor;
  DEALLOCATE po_cursor;
END;
');

/* --- 5) razpored (ops.BeginRun brez vrstice v ops.ScheduleProfile z IsEnabled=1 vrze 51100) --- */

MERGE ops.ScheduleProfile AS target
USING
(
  SELECT organization.OrganizationId, N'SAOP' AS Provider, N'SAOP_ORDERS' AS Pipeline, 3600 AS IntervalSeconds,
    7200 AS StaleAfterSeconds, 5000 AS LockTimeoutMilliseconds
  FROM dbo.OrganizationConfig organization
  WHERE EXISTS (SELECT 1 FROM map.SourceConnector connector WHERE connector.OrganizationId=organization.OrganizationId AND connector.ConnectorType=N'SAOP' AND connector.IsActive=1)
) source
  ON target.OrganizationId = source.OrganizationId AND target.Pipeline = source.Pipeline
WHEN NOT MATCHED THEN
  INSERT (OrganizationId, Provider, Pipeline, IsEnabled, IntervalSeconds, StaleAfterSeconds, LockTimeoutMilliseconds, UpdatedBy)
  VALUES (source.OrganizationId, source.Provider, source.Pipeline, 1, source.IntervalSeconds,
          source.StaleAfterSeconds, source.LockTimeoutMilliseconds, N'migracija 199');

/* --- 6) preverbe --------------------------------------------------------------- */

IF OBJECT_ID(N'sales.OrderHeader', N'U') IS NULL THROW 52910, N'199: sales.OrderHeader manjka.', 1;
IF OBJECT_ID(N'sales.OrderLine', N'U') IS NULL THROW 52911, N'199: sales.OrderLine manjka.', 1;
IF OBJECT_ID(N'purch.PurchaseOrderHeader', N'U') IS NULL THROW 52912, N'199: purch.PurchaseOrderHeader manjka.', 1;
IF OBJECT_ID(N'purch.PurchaseOrderLine', N'U') IS NULL THROW 52913, N'199: purch.PurchaseOrderLine manjka.', 1;
IF OBJECT_ID(N'map.ProcessSalesOrderInbox') IS NULL THROW 52915, N'199: map.ProcessSalesOrderInbox manjka.', 1;
IF OBJECT_ID(N'map.ProcessPurchaseOrderInbox') IS NULL THROW 52916, N'199: map.ProcessPurchaseOrderInbox manjka.', 1;
IF (SELECT COUNT(*) FROM map.EntityMapping WHERE EntityType IN (N'GetOrder',N'GetPurchaseOrder') AND IsActive=1) < 2
  THROW 52918, N'199: novi svetovi niso registrirani na vsaj enem aktivnem SAOP konektorju.', 1;
IF (SELECT COUNT(DISTINCT EntityType) FROM map.FieldMapping WHERE EntityType IN (N'GetOrder',N'GetPurchaseOrder') AND IsActive=1) < 2
  THROW 52919, N'199: preslikave polj za nove svetove manjkajo.', 1;
IF (SELECT COUNT(*) FROM ops.ScheduleProfile WHERE Pipeline=N'SAOP_ORDERS' AND IsEnabled=1) < 1
  THROW 52920, N'199: razpored SAOP_ORDERS ni omogocen za nobeno organizacijo; ops.BeginRun bi vrgel 51100.', 1;
