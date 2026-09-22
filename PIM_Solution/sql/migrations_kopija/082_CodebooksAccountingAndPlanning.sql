/*
  082 — valute, ceniki, konti zaloge in planiranje: zadnje entitete, ki so cakale brez cilja.

  Odlocitev uporabnika 2026-08-23: beremo vse, kar zajamemo. S temi stirimi je preslikanih vseh
  petnajst koncnih tock SAOP, ki kaj vrnejo (sestnajsta, tehnoloski proces, vraca prazen seznam).

  Kaj nastane:
    canon.Codebook               valute in ceniki v eni tabeli; katera sifranta je vrstica, pove
                                 map.EntityMapping.CodebookCode
    canon.ProductStockAccounting konti po vrsti skladisca (par izdelek + vrsta skladisca)
    canon.ProductPlanning        dobavni rok in kolicine, ena vrstica na artikel

  Zakaj ena tabela za sifrante: oblika je ista (sifra, ime, druga sifra, aktivnost) in nihce jih
  se ne bere po imenu stolpca. Ko jih bo kdo bral, je pogled ali svoja tabela stvar enega stavka
  — podatek pa bo takrat ze v bazi.

  Pri planiranju je prenesenih sedem polj od sedemindvajsetih; ostalo je notranje racunovodstvo
  proizvodnje (pretvorniki, povrsine, MIT). Dodajanje je vrstica registra in stolpec, ne nov zajem.
*/

SET XACT_ABORT ON;

/* --- 1) tabele --------------------------------------------------------------- */

IF OBJECT_ID(N'canon.Codebook') IS NULL
BEGIN
  CREATE TABLE canon.Codebook
  (
    CodebookId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Codebook PRIMARY KEY,
    OrganizationId int NOT NULL,
    CodebookCode nvarchar(50) NOT NULL,
    EntryCode nvarchar(100) NOT NULL,
    Name nvarchar(400) NULL,
    ExtraCode nvarchar(100) NULL,
    IsActive bit NOT NULL CONSTRAINT DF_Codebook_IsActive DEFAULT(1),
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_Codebook_UpdatedUtc DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_Codebook UNIQUE (OrganizationId, CodebookCode, EntryCode),
    CONSTRAINT FK_Codebook_Organization FOREIGN KEY (OrganizationId) REFERENCES dbo.OrganizationConfig(OrganizationId)
  );
END;

IF OBJECT_ID(N'canon.ProductStockAccounting') IS NULL
BEGIN
  CREATE TABLE canon.ProductStockAccounting
  (
    ProductStockAccountingId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_ProductStockAccounting PRIMARY KEY,
    ProductId bigint NOT NULL,
    WarehouseType nvarchar(20) NOT NULL,
    InventoryAccount nvarchar(50) NULL,
    BillingAccount nvarchar(50) NULL,
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_ProductStockAccounting_UpdatedUtc DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_ProductStockAccounting UNIQUE (ProductId, WarehouseType),
    CONSTRAINT FK_ProductStockAccounting_Product FOREIGN KEY (ProductId) REFERENCES canon.Product(ProductId)
  );
END;

IF OBJECT_ID(N'canon.ProductPlanning') IS NULL
BEGIN
  CREATE TABLE canon.ProductPlanning
  (
    ProductPlanningId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_ProductPlanning PRIMARY KEY,
    ProductId bigint NOT NULL,
    LeadTimeDays int NULL,
    PurchaseLeadTimeDays int NULL,
    AggregationPeriodDays int NULL,
    LeadTimeQuantity decimal(19,4) NULL,
    OptimumProductionQuantity decimal(19,4) NULL,
    ExcludeQuantityReservation bit NOT NULL CONSTRAINT DF_ProductPlanning_Exclude DEFAULT(0),
    IsPhantom bit NOT NULL CONSTRAINT DF_ProductPlanning_Phantom DEFAULT(0),
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_ProductPlanning_UpdatedUtc DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_ProductPlanning UNIQUE (ProductId),
    CONSTRAINT FK_ProductPlanning_Product FOREIGN KEY (ProductId) REFERENCES canon.Product(ProductId)
  );
END;

/* --- 2) register: kateri svet in kateri sifrant ------------------------------ */

IF COL_LENGTH(N'map.EntityMapping', N'CodebookCode') IS NULL
  ALTER TABLE map.EntityMapping ADD CodebookCode nvarchar(50) NULL;

IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_EntityMapping_TargetDomain')
  ALTER TABLE map.EntityMapping DROP CONSTRAINT CK_EntityMapping_TargetDomain;

ALTER TABLE map.EntityMapping WITH CHECK
  ADD CONSTRAINT CK_EntityMapping_TargetDomain
  CHECK (TargetDomain IN (N'Product', N'Warehouse', N'Language', N'ProductText',
                          N'ProductAttributePair', N'ProductStockPolicy',
                          N'Codebook', N'ProductStockAccounting', N'ProductPlanning'));

/* --- 3) preslikave na vseh stirih SAOP konektorjih -------------------------- */

/* --- SAOP_DEMO --- */
EXEC(N'
DECLARE @ConnectorId int = (SELECT SourceConnectorId FROM map.SourceConnector WHERE SourceCode = N''SAOP_DEMO'' AND OrganizationId = 1);
IF @ConnectorId IS NOT NULL
BEGIN
  MERGE map.EntityMapping AS target
  USING (VALUES
    (N''Currencies'',                  N''/ArrayOfCurrency/Currency'',                                                    N''Codebook'',                N''CURRENCY''),
    (N''PriceLists'',                  N''/ArrayOfPriceList/PriceList'',                                                  N''Codebook'',                N''PRICELIST''),
    (N''GetItemsStockAccountingData'', N''/ItemsStockAccountingData/ItemStockAccountingData/WarehouseTypesData/WarehouseTypeData'', N''ProductStockAccounting'', NULL),
    (N''GetItemsPlanningData'',        N''/ItemsPlanningData/ItemPlanningData'',                                          N''ProductPlanning'',         NULL)
  ) AS source(EntityType, RecordXPath, TargetDomain, CodebookCode)
    ON target.SourceConnectorId = @ConnectorId AND target.EntityType = source.EntityType
  WHEN MATCHED THEN UPDATE SET RecordXPath = source.RecordXPath, TargetDomain = source.TargetDomain,
    CodebookCode = source.CodebookCode, IsActive = 1
  WHEN NOT MATCHED THEN INSERT (SourceConnectorId, EntityType, RecordXPath, TargetDomain, CodebookCode, IsActive)
    VALUES (@ConnectorId, source.EntityType, source.RecordXPath, source.TargetDomain, source.CodebookCode, 1);

  MERGE map.FieldMapping AS target
  USING (VALUES
    (N''Currencies'', N''CurrencyId/text()[1]'',          N''Codebook.EntryCode'', CONVERT(bit,1)),
    (N''Currencies'', N''CurrencyDescription/text()[1]'', N''Codebook.Name'',      CONVERT(bit,0)),
    (N''Currencies'', N''CurrencyCode/text()[1]'',        N''Codebook.ExtraCode'', CONVERT(bit,0)),
    (N''PriceLists'', N''PriceListId/text()[1]'',          N''Codebook.EntryCode'', CONVERT(bit,1)),
    (N''PriceLists'', N''PriceListDescription/text()[1]'', N''Codebook.Name'',      CONVERT(bit,0)),
    (N''PriceLists'', N''CurrencyId/text()[1]'',           N''Codebook.ExtraCode'', CONVERT(bit,0)),
    (N''PriceLists'', N''Active/text()[1]'',               N''Codebook.IsActive'',  CONVERT(bit,0)),
    (N''GetItemsStockAccountingData'', N''../../ItemID/text()[1]'',      N''Record.ItemID'',                    CONVERT(bit,1)),
    (N''GetItemsStockAccountingData'', N''WarehouseType/text()[1]'',     N''StockAccounting.WarehouseType'',    CONVERT(bit,1)),
    (N''GetItemsStockAccountingData'', N''InventoryAccount/text()[1]'',  N''StockAccounting.InventoryAccount'', CONVERT(bit,0)),
    (N''GetItemsStockAccountingData'', N''BillingAccount/text()[1]'',    N''StockAccounting.BillingAccount'',   CONVERT(bit,0)),
    (N''GetItemsPlanningData'', N''ItemID/text()[1]'',                                 N''Record.ItemID'',                    CONVERT(bit,1)),
    (N''GetItemsPlanningData'', N''PlanningData/ItemLeadTime/text()[1]'',              N''Planning.LeadTime'',                CONVERT(bit,0)),
    (N''GetItemsPlanningData'', N''PlanningData/ItemPurchaseLeadTime/text()[1]'',      N''Planning.PurchaseLeadTime'',        CONVERT(bit,0)),
    (N''GetItemsPlanningData'', N''PlanningData/ItemAggregationPeriodDays/text()[1]'', N''Planning.AggregationPeriodDays'',   CONVERT(bit,0)),
    (N''GetItemsPlanningData'', N''PlanningData/ItemLeadTimeQty/text()[1]'',           N''Planning.LeadTimeQty'',             CONVERT(bit,0)),
    (N''GetItemsPlanningData'', N''PlanningData/ItemOptimumProductionQty/text()[1]'',  N''Planning.OptimumProductionQty'',    CONVERT(bit,0)),
    (N''GetItemsPlanningData'', N''PlanningData/ItemExcludeQtyReservation/text()[1]'', N''Planning.ExcludeQtyReservation'',   CONVERT(bit,0)),
    (N''GetItemsPlanningData'', N''PlanningData/Phantom/text()[1]'',                   N''Planning.Phantom'',                 CONVERT(bit,0))
  ) AS source(EntityType, SourceElement, TargetFieldCode, IsRequired)
    ON target.SourceConnectorId = @ConnectorId AND target.EntityType = source.EntityType
      AND target.TargetFieldCode = source.TargetFieldCode
  WHEN MATCHED THEN UPDATE SET SourceElement = source.SourceElement, IsRequired = source.IsRequired, IsActive = 1
  WHEN NOT MATCHED THEN INSERT (SourceConnectorId, EntityType, SourceElement, TargetFieldCode, IsRequired, IsActive)
    VALUES (@ConnectorId, source.EntityType, source.SourceElement, source.TargetFieldCode, source.IsRequired, 1);
END;
');

/* --- SAOP_IQLIGHTING --- */
EXEC(N'
DECLARE @ConnectorId int = (SELECT SourceConnectorId FROM map.SourceConnector WHERE SourceCode = N''SAOP_IQLIGHTING'' AND OrganizationId = 2);
IF @ConnectorId IS NOT NULL
BEGIN
  MERGE map.EntityMapping AS target
  USING (VALUES
    (N''Currencies'',                  N''/ArrayOfCurrency/Currency'',                                                    N''Codebook'',                N''CURRENCY''),
    (N''PriceLists'',                  N''/ArrayOfPriceList/PriceList'',                                                  N''Codebook'',                N''PRICELIST''),
    (N''GetItemsStockAccountingData'', N''/ItemsStockAccountingData/ItemStockAccountingData/WarehouseTypesData/WarehouseTypeData'', N''ProductStockAccounting'', NULL),
    (N''GetItemsPlanningData'',        N''/ItemsPlanningData/ItemPlanningData'',                                          N''ProductPlanning'',         NULL)
  ) AS source(EntityType, RecordXPath, TargetDomain, CodebookCode)
    ON target.SourceConnectorId = @ConnectorId AND target.EntityType = source.EntityType
  WHEN MATCHED THEN UPDATE SET RecordXPath = source.RecordXPath, TargetDomain = source.TargetDomain,
    CodebookCode = source.CodebookCode, IsActive = 1
  WHEN NOT MATCHED THEN INSERT (SourceConnectorId, EntityType, RecordXPath, TargetDomain, CodebookCode, IsActive)
    VALUES (@ConnectorId, source.EntityType, source.RecordXPath, source.TargetDomain, source.CodebookCode, 1);

  MERGE map.FieldMapping AS target
  USING (VALUES
    (N''Currencies'', N''CurrencyId/text()[1]'',          N''Codebook.EntryCode'', CONVERT(bit,1)),
    (N''Currencies'', N''CurrencyDescription/text()[1]'', N''Codebook.Name'',      CONVERT(bit,0)),
    (N''Currencies'', N''CurrencyCode/text()[1]'',        N''Codebook.ExtraCode'', CONVERT(bit,0)),
    (N''PriceLists'', N''PriceListId/text()[1]'',          N''Codebook.EntryCode'', CONVERT(bit,1)),
    (N''PriceLists'', N''PriceListDescription/text()[1]'', N''Codebook.Name'',      CONVERT(bit,0)),
    (N''PriceLists'', N''CurrencyId/text()[1]'',           N''Codebook.ExtraCode'', CONVERT(bit,0)),
    (N''PriceLists'', N''Active/text()[1]'',               N''Codebook.IsActive'',  CONVERT(bit,0)),
    (N''GetItemsStockAccountingData'', N''../../ItemID/text()[1]'',      N''Record.ItemID'',                    CONVERT(bit,1)),
    (N''GetItemsStockAccountingData'', N''WarehouseType/text()[1]'',     N''StockAccounting.WarehouseType'',    CONVERT(bit,1)),
    (N''GetItemsStockAccountingData'', N''InventoryAccount/text()[1]'',  N''StockAccounting.InventoryAccount'', CONVERT(bit,0)),
    (N''GetItemsStockAccountingData'', N''BillingAccount/text()[1]'',    N''StockAccounting.BillingAccount'',   CONVERT(bit,0)),
    (N''GetItemsPlanningData'', N''ItemID/text()[1]'',                                 N''Record.ItemID'',                    CONVERT(bit,1)),
    (N''GetItemsPlanningData'', N''PlanningData/ItemLeadTime/text()[1]'',              N''Planning.LeadTime'',                CONVERT(bit,0)),
    (N''GetItemsPlanningData'', N''PlanningData/ItemPurchaseLeadTime/text()[1]'',      N''Planning.PurchaseLeadTime'',        CONVERT(bit,0)),
    (N''GetItemsPlanningData'', N''PlanningData/ItemAggregationPeriodDays/text()[1]'', N''Planning.AggregationPeriodDays'',   CONVERT(bit,0)),
    (N''GetItemsPlanningData'', N''PlanningData/ItemLeadTimeQty/text()[1]'',           N''Planning.LeadTimeQty'',             CONVERT(bit,0)),
    (N''GetItemsPlanningData'', N''PlanningData/ItemOptimumProductionQty/text()[1]'',  N''Planning.OptimumProductionQty'',    CONVERT(bit,0)),
    (N''GetItemsPlanningData'', N''PlanningData/ItemExcludeQtyReservation/text()[1]'', N''Planning.ExcludeQtyReservation'',   CONVERT(bit,0)),
    (N''GetItemsPlanningData'', N''PlanningData/Phantom/text()[1]'',                   N''Planning.Phantom'',                 CONVERT(bit,0))
  ) AS source(EntityType, SourceElement, TargetFieldCode, IsRequired)
    ON target.SourceConnectorId = @ConnectorId AND target.EntityType = source.EntityType
      AND target.TargetFieldCode = source.TargetFieldCode
  WHEN MATCHED THEN UPDATE SET SourceElement = source.SourceElement, IsRequired = source.IsRequired, IsActive = 1
  WHEN NOT MATCHED THEN INSERT (SourceConnectorId, EntityType, SourceElement, TargetFieldCode, IsRequired, IsActive)
    VALUES (@ConnectorId, source.EntityType, source.SourceElement, source.TargetFieldCode, source.IsRequired, 1);
END;
');

/* --- SAOP_VIDADRIA --- */
EXEC(N'
DECLARE @ConnectorId int = (SELECT SourceConnectorId FROM map.SourceConnector WHERE SourceCode = N''SAOP_VIDADRIA'' AND OrganizationId = 3);
IF @ConnectorId IS NOT NULL
BEGIN
  MERGE map.EntityMapping AS target
  USING (VALUES
    (N''Currencies'',                  N''/ArrayOfCurrency/Currency'',                                                    N''Codebook'',                N''CURRENCY''),
    (N''PriceLists'',                  N''/ArrayOfPriceList/PriceList'',                                                  N''Codebook'',                N''PRICELIST''),
    (N''GetItemsStockAccountingData'', N''/ItemsStockAccountingData/ItemStockAccountingData/WarehouseTypesData/WarehouseTypeData'', N''ProductStockAccounting'', NULL),
    (N''GetItemsPlanningData'',        N''/ItemsPlanningData/ItemPlanningData'',                                          N''ProductPlanning'',         NULL)
  ) AS source(EntityType, RecordXPath, TargetDomain, CodebookCode)
    ON target.SourceConnectorId = @ConnectorId AND target.EntityType = source.EntityType
  WHEN MATCHED THEN UPDATE SET RecordXPath = source.RecordXPath, TargetDomain = source.TargetDomain,
    CodebookCode = source.CodebookCode, IsActive = 1
  WHEN NOT MATCHED THEN INSERT (SourceConnectorId, EntityType, RecordXPath, TargetDomain, CodebookCode, IsActive)
    VALUES (@ConnectorId, source.EntityType, source.RecordXPath, source.TargetDomain, source.CodebookCode, 1);

  MERGE map.FieldMapping AS target
  USING (VALUES
    (N''Currencies'', N''CurrencyId/text()[1]'',          N''Codebook.EntryCode'', CONVERT(bit,1)),
    (N''Currencies'', N''CurrencyDescription/text()[1]'', N''Codebook.Name'',      CONVERT(bit,0)),
    (N''Currencies'', N''CurrencyCode/text()[1]'',        N''Codebook.ExtraCode'', CONVERT(bit,0)),
    (N''PriceLists'', N''PriceListId/text()[1]'',          N''Codebook.EntryCode'', CONVERT(bit,1)),
    (N''PriceLists'', N''PriceListDescription/text()[1]'', N''Codebook.Name'',      CONVERT(bit,0)),
    (N''PriceLists'', N''CurrencyId/text()[1]'',           N''Codebook.ExtraCode'', CONVERT(bit,0)),
    (N''PriceLists'', N''Active/text()[1]'',               N''Codebook.IsActive'',  CONVERT(bit,0)),
    (N''GetItemsStockAccountingData'', N''../../ItemID/text()[1]'',      N''Record.ItemID'',                    CONVERT(bit,1)),
    (N''GetItemsStockAccountingData'', N''WarehouseType/text()[1]'',     N''StockAccounting.WarehouseType'',    CONVERT(bit,1)),
    (N''GetItemsStockAccountingData'', N''InventoryAccount/text()[1]'',  N''StockAccounting.InventoryAccount'', CONVERT(bit,0)),
    (N''GetItemsStockAccountingData'', N''BillingAccount/text()[1]'',    N''StockAccounting.BillingAccount'',   CONVERT(bit,0)),
    (N''GetItemsPlanningData'', N''ItemID/text()[1]'',                                 N''Record.ItemID'',                    CONVERT(bit,1)),
    (N''GetItemsPlanningData'', N''PlanningData/ItemLeadTime/text()[1]'',              N''Planning.LeadTime'',                CONVERT(bit,0)),
    (N''GetItemsPlanningData'', N''PlanningData/ItemPurchaseLeadTime/text()[1]'',      N''Planning.PurchaseLeadTime'',        CONVERT(bit,0)),
    (N''GetItemsPlanningData'', N''PlanningData/ItemAggregationPeriodDays/text()[1]'', N''Planning.AggregationPeriodDays'',   CONVERT(bit,0)),
    (N''GetItemsPlanningData'', N''PlanningData/ItemLeadTimeQty/text()[1]'',           N''Planning.LeadTimeQty'',             CONVERT(bit,0)),
    (N''GetItemsPlanningData'', N''PlanningData/ItemOptimumProductionQty/text()[1]'',  N''Planning.OptimumProductionQty'',    CONVERT(bit,0)),
    (N''GetItemsPlanningData'', N''PlanningData/ItemExcludeQtyReservation/text()[1]'', N''Planning.ExcludeQtyReservation'',   CONVERT(bit,0)),
    (N''GetItemsPlanningData'', N''PlanningData/Phantom/text()[1]'',                   N''Planning.Phantom'',                 CONVERT(bit,0))
  ) AS source(EntityType, SourceElement, TargetFieldCode, IsRequired)
    ON target.SourceConnectorId = @ConnectorId AND target.EntityType = source.EntityType
      AND target.TargetFieldCode = source.TargetFieldCode
  WHEN MATCHED THEN UPDATE SET SourceElement = source.SourceElement, IsRequired = source.IsRequired, IsActive = 1
  WHEN NOT MATCHED THEN INSERT (SourceConnectorId, EntityType, SourceElement, TargetFieldCode, IsRequired, IsActive)
    VALUES (@ConnectorId, source.EntityType, source.SourceElement, source.TargetFieldCode, source.IsRequired, 1);
END;
');

/* --- SAOP_EDIITO --- */
EXEC(N'
DECLARE @ConnectorId int = (SELECT SourceConnectorId FROM map.SourceConnector WHERE SourceCode = N''SAOP_EDIITO'' AND OrganizationId = 4);
IF @ConnectorId IS NOT NULL
BEGIN
  MERGE map.EntityMapping AS target
  USING (VALUES
    (N''Currencies'',                  N''/ArrayOfCurrency/Currency'',                                                    N''Codebook'',                N''CURRENCY''),
    (N''PriceLists'',                  N''/ArrayOfPriceList/PriceList'',                                                  N''Codebook'',                N''PRICELIST''),
    (N''GetItemsStockAccountingData'', N''/ItemsStockAccountingData/ItemStockAccountingData/WarehouseTypesData/WarehouseTypeData'', N''ProductStockAccounting'', NULL),
    (N''GetItemsPlanningData'',        N''/ItemsPlanningData/ItemPlanningData'',                                          N''ProductPlanning'',         NULL)
  ) AS source(EntityType, RecordXPath, TargetDomain, CodebookCode)
    ON target.SourceConnectorId = @ConnectorId AND target.EntityType = source.EntityType
  WHEN MATCHED THEN UPDATE SET RecordXPath = source.RecordXPath, TargetDomain = source.TargetDomain,
    CodebookCode = source.CodebookCode, IsActive = 1
  WHEN NOT MATCHED THEN INSERT (SourceConnectorId, EntityType, RecordXPath, TargetDomain, CodebookCode, IsActive)
    VALUES (@ConnectorId, source.EntityType, source.RecordXPath, source.TargetDomain, source.CodebookCode, 1);

  MERGE map.FieldMapping AS target
  USING (VALUES
    (N''Currencies'', N''CurrencyId/text()[1]'',          N''Codebook.EntryCode'', CONVERT(bit,1)),
    (N''Currencies'', N''CurrencyDescription/text()[1]'', N''Codebook.Name'',      CONVERT(bit,0)),
    (N''Currencies'', N''CurrencyCode/text()[1]'',        N''Codebook.ExtraCode'', CONVERT(bit,0)),
    (N''PriceLists'', N''PriceListId/text()[1]'',          N''Codebook.EntryCode'', CONVERT(bit,1)),
    (N''PriceLists'', N''PriceListDescription/text()[1]'', N''Codebook.Name'',      CONVERT(bit,0)),
    (N''PriceLists'', N''CurrencyId/text()[1]'',           N''Codebook.ExtraCode'', CONVERT(bit,0)),
    (N''PriceLists'', N''Active/text()[1]'',               N''Codebook.IsActive'',  CONVERT(bit,0)),
    (N''GetItemsStockAccountingData'', N''../../ItemID/text()[1]'',      N''Record.ItemID'',                    CONVERT(bit,1)),
    (N''GetItemsStockAccountingData'', N''WarehouseType/text()[1]'',     N''StockAccounting.WarehouseType'',    CONVERT(bit,1)),
    (N''GetItemsStockAccountingData'', N''InventoryAccount/text()[1]'',  N''StockAccounting.InventoryAccount'', CONVERT(bit,0)),
    (N''GetItemsStockAccountingData'', N''BillingAccount/text()[1]'',    N''StockAccounting.BillingAccount'',   CONVERT(bit,0)),
    (N''GetItemsPlanningData'', N''ItemID/text()[1]'',                                 N''Record.ItemID'',                    CONVERT(bit,1)),
    (N''GetItemsPlanningData'', N''PlanningData/ItemLeadTime/text()[1]'',              N''Planning.LeadTime'',                CONVERT(bit,0)),
    (N''GetItemsPlanningData'', N''PlanningData/ItemPurchaseLeadTime/text()[1]'',      N''Planning.PurchaseLeadTime'',        CONVERT(bit,0)),
    (N''GetItemsPlanningData'', N''PlanningData/ItemAggregationPeriodDays/text()[1]'', N''Planning.AggregationPeriodDays'',   CONVERT(bit,0)),
    (N''GetItemsPlanningData'', N''PlanningData/ItemLeadTimeQty/text()[1]'',           N''Planning.LeadTimeQty'',             CONVERT(bit,0)),
    (N''GetItemsPlanningData'', N''PlanningData/ItemOptimumProductionQty/text()[1]'',  N''Planning.OptimumProductionQty'',    CONVERT(bit,0)),
    (N''GetItemsPlanningData'', N''PlanningData/ItemExcludeQtyReservation/text()[1]'', N''Planning.ExcludeQtyReservation'',   CONVERT(bit,0)),
    (N''GetItemsPlanningData'', N''PlanningData/Phantom/text()[1]'',                   N''Planning.Phantom'',                 CONVERT(bit,0))
  ) AS source(EntityType, SourceElement, TargetFieldCode, IsRequired)
    ON target.SourceConnectorId = @ConnectorId AND target.EntityType = source.EntityType
      AND target.TargetFieldCode = source.TargetFieldCode
  WHEN MATCHED THEN UPDATE SET SourceElement = source.SourceElement, IsRequired = source.IsRequired, IsActive = 1
  WHEN NOT MATCHED THEN INSERT (SourceConnectorId, EntityType, SourceElement, TargetFieldCode, IsRequired, IsActive)
    VALUES (@ConnectorId, source.EntityType, source.SourceElement, source.TargetFieldCode, source.IsRequired, 1);
END;
');

/* --- 4) postopki -------------------------------------------------------------- */

EXEC(N'
CREATE OR ALTER PROCEDURE map.ProcessCodebookInbox
  @RunId uniqueidentifier,
  @OrganizationId int,
  @SourceCode nvarchar(100)
AS
BEGIN
  /*
    Sifranti brez lastne tabele: valute in ceniki. Ena tabela za vse, ker je oblika ista —
    sifra, ime, morebitna druga sifra in aktivnost. Katera sifranta je vrstica, pove
    map.EntityMapping.CodebookCode, ne ime entitete.

    Zakaj ne po tabeli na sifrant: nihce jih se ne bere po imenu stolpca. Ko jih bo kdo bral
    (na primer intranet za izbiro cenika), je iz te tabele pogled ali svoja tabela stvar enega
    stavka — podatek pa je takrat ze v bazi in ne caka na nov zajem.
  */
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  DECLARE @InboxId bigint;
  DECLARE zajem_cursor CURSOR LOCAL FAST_FORWARD FOR
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
          AND entityMapping.TargetDomain=''Codebook''
      )
    ORDER BY inbox.InboxId;

  OPEN zajem_cursor;
  FETCH NEXT FROM zajem_cursor INTO @InboxId;
  WHILE @@FETCH_STATUS=0
  BEGIN
    BEGIN TRY
      BEGIN TRANSACTION;

      IF OBJECT_ID(''tempdb..#Zapis'') IS NOT NULL DROP TABLE #Zapis;

      DECLARE @CodebookCode nvarchar(50) =
      (
        SELECT TOP(1) entityMapping.CodebookCode
        FROM raw.Inbox inbox
        INNER JOIN map.SourceConnector connector
          ON connector.SourceCode=inbox.SourceCode AND connector.OrganizationId=inbox.OrganizationId
        INNER JOIN map.EntityMapping entityMapping
          ON entityMapping.SourceConnectorId=connector.SourceConnectorId AND entityMapping.EntityType=inbox.EntityType
        WHERE inbox.InboxId=@InboxId
      );

      SELECT
        LTRIM(RTRIM(zapis.EntryCode)) AS EntryCode,
        NULLIF(LTRIM(RTRIM(zapis.Name)),'''') AS Name,
        NULLIF(LTRIM(RTRIM(zapis.ExtraCode)),'''') AS ExtraCode,
        CASE WHEN LOWER(LTRIM(RTRIM(ISNULL(zapis.IsActiveText,'''')))) IN (''false'',''0'',''ne'') THEN 0 ELSE 1 END AS IsActive
      INTO #Zapis
      FROM
      (
        SELECT value.RecordOrdinal,
          MAX(CASE WHEN value.TargetFieldCode=''Codebook.EntryCode'' THEN CONVERT(nvarchar(100),value.Value) END) AS EntryCode,
          MAX(CASE WHEN value.TargetFieldCode=''Codebook.Name'' THEN CONVERT(nvarchar(400),value.Value) END) AS Name,
          MAX(CASE WHEN value.TargetFieldCode=''Codebook.ExtraCode'' THEN CONVERT(nvarchar(100),value.Value) END) AS ExtraCode,
          MAX(CASE WHEN value.TargetFieldCode=''Codebook.IsActive'' THEN CONVERT(nvarchar(20),value.Value) END) AS IsActiveText
        FROM map.ExtractedValue value
        WHERE value.InboxId=@InboxId
          AND EXISTS(SELECT 1 FROM map.FieldMapping mapping
                     WHERE mapping.FieldMappingId=value.FieldMappingId AND mapping.IsActive=1)
        GROUP BY value.RecordOrdinal
      ) zapis
      WHERE NULLIF(LTRIM(RTRIM(zapis.EntryCode)),'''') IS NOT NULL;

      MERGE canon.Codebook AS target
      USING (SELECT @OrganizationId AS OrganizationId, @CodebookCode AS CodebookCode, EntryCode, Name, ExtraCode, IsActive FROM #Zapis) source
        ON target.OrganizationId=source.OrganizationId AND target.CodebookCode=source.CodebookCode
          AND target.EntryCode=source.EntryCode
      WHEN MATCHED THEN UPDATE SET Name=ISNULL(source.Name,target.Name), ExtraCode=source.ExtraCode,
        IsActive=source.IsActive, UpdatedUtc=SYSUTCDATETIME()
      WHEN NOT MATCHED THEN INSERT(OrganizationId,CodebookCode,EntryCode,Name,ExtraCode,IsActive)
        VALUES(source.OrganizationId,source.CodebookCode,source.EntryCode,source.Name,source.ExtraCode,source.IsActive);

      DECLARE @Zapisov int = (SELECT COUNT(DISTINCT value.RecordOrdinal) FROM map.ExtractedValue value WHERE value.InboxId=@InboxId);
      DECLARE @Uporabljenih int = (SELECT COUNT(*) FROM #Zapis);

      UPDATE raw.Inbox
      SET Status=''Processed'', ProcessedUtc=SYSUTCDATETIME(),
          FailureReason=CASE WHEN @Uporabljenih=@Zapisov THEN NULL
            ELSE CONCAT(''Uporabljenih: '', @Uporabljenih, '' od '', @Zapisov, ''. Vrstice brez sifre se ne shranijo.'') END
      WHERE InboxId=@InboxId;

      DROP TABLE #Zapis;
      COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
      IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
      DECLARE @Napaka nvarchar(500)=ERROR_MESSAGE();
      UPDATE raw.Inbox SET Status=''Quarantined'', ProcessedUtc=SYSUTCDATETIME(), FailureReason=LEFT(@Napaka,2000)
      WHERE InboxId=@InboxId;
    END CATCH;

    FETCH NEXT FROM zajem_cursor INTO @InboxId;
  END;
  CLOSE zajem_cursor;
  DEALLOCATE zajem_cursor;
END;
');

EXEC(N'
CREATE OR ALTER PROCEDURE map.ProcessStockAccountingInbox
  @RunId uniqueidentifier,
  @OrganizationId int,
  @SourceCode nvarchar(100)
AS
BEGIN
  /*
    Konti zaloge po vrsti skladisca. En artikel ima lahko vec vrst skladisca (V, K ...), zato
    je kljuc par (izdelek, vrsta skladisca).

    Ti podatki niso za splet: rabi jih knjigovodstvo in preverba, ali je artikel sploh
    pripravljen za ERP. V katalogu so zato, ker je zajem ze narejen in ker jih brez tega ni
    mogoce videti nikjer razen v SAOP.
  */
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  DECLARE @InboxId bigint;
  DECLARE zajem_cursor CURSOR LOCAL FAST_FORWARD FOR
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
          AND entityMapping.TargetDomain=''ProductStockAccounting''
      )
    ORDER BY inbox.InboxId;

  OPEN zajem_cursor;
  FETCH NEXT FROM zajem_cursor INTO @InboxId;
  WHILE @@FETCH_STATUS=0
  BEGIN
    BEGIN TRY
      BEGIN TRANSACTION;

      IF OBJECT_ID(''tempdb..#Zapis'') IS NOT NULL DROP TABLE #Zapis;

      SELECT izdelek.ProductId, LTRIM(RTRIM(zapis.WarehouseType)) AS WarehouseType,
        NULLIF(LTRIM(RTRIM(zapis.InventoryAccount)),'''') AS InventoryAccount,
        NULLIF(LTRIM(RTRIM(zapis.BillingAccount)),'''') AS BillingAccount
      INTO #Zapis
      FROM
      (
        SELECT value.RecordOrdinal,
          MAX(CASE WHEN value.TargetFieldCode=''Record.ItemID'' THEN CONVERT(nvarchar(100),value.Value) END) AS ItemID,
          MAX(CASE WHEN value.TargetFieldCode=''StockAccounting.WarehouseType'' THEN CONVERT(nvarchar(20),value.Value) END) AS WarehouseType,
          MAX(CASE WHEN value.TargetFieldCode=''StockAccounting.InventoryAccount'' THEN CONVERT(nvarchar(50),value.Value) END) AS InventoryAccount,
          MAX(CASE WHEN value.TargetFieldCode=''StockAccounting.BillingAccount'' THEN CONVERT(nvarchar(50),value.Value) END) AS BillingAccount
        FROM map.ExtractedValue value
        WHERE value.InboxId=@InboxId
          AND EXISTS(SELECT 1 FROM map.FieldMapping mapping
                     WHERE mapping.FieldMappingId=value.FieldMappingId AND mapping.IsActive=1)
        GROUP BY value.RecordOrdinal
      ) zapis
      INNER JOIN canon.Product izdelek
        ON izdelek.OrganizationId=@OrganizationId AND izdelek.ItemID=LTRIM(RTRIM(zapis.ItemID))
      WHERE NULLIF(LTRIM(RTRIM(zapis.WarehouseType)),'''') IS NOT NULL;

      MERGE canon.ProductStockAccounting AS target
      USING (SELECT DISTINCT ProductId, WarehouseType, InventoryAccount, BillingAccount FROM #Zapis) source
        ON target.ProductId=source.ProductId AND target.WarehouseType=source.WarehouseType
      WHEN MATCHED THEN UPDATE SET InventoryAccount=source.InventoryAccount, BillingAccount=source.BillingAccount,
        UpdatedUtc=SYSUTCDATETIME()
      WHEN NOT MATCHED THEN INSERT(ProductId,WarehouseType,InventoryAccount,BillingAccount)
        VALUES(source.ProductId,source.WarehouseType,source.InventoryAccount,source.BillingAccount);

      DECLARE @Zapisov int = (SELECT COUNT(DISTINCT value.RecordOrdinal) FROM map.ExtractedValue value WHERE value.InboxId=@InboxId);
      DECLARE @Uporabljenih int = (SELECT COUNT(*) FROM #Zapis);

      UPDATE raw.Inbox
      SET Status=''Processed'', ProcessedUtc=SYSUTCDATETIME(),
          FailureReason=CASE WHEN @Uporabljenih=@Zapisov THEN NULL
            ELSE CONCAT(''Uporabljenih: '', @Uporabljenih, '' od '', @Zapisov, ''. Preostali nimajo artikla v katalogu.'') END
      WHERE InboxId=@InboxId;

      DROP TABLE #Zapis;
      COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
      IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
      DECLARE @Napaka nvarchar(500)=ERROR_MESSAGE();
      UPDATE raw.Inbox SET Status=''Quarantined'', ProcessedUtc=SYSUTCDATETIME(), FailureReason=LEFT(@Napaka,2000)
      WHERE InboxId=@InboxId;
    END CATCH;

    FETCH NEXT FROM zajem_cursor INTO @InboxId;
  END;
  CLOSE zajem_cursor;
  DEALLOCATE zajem_cursor;
END;
');

EXEC(N'
CREATE OR ALTER PROCEDURE map.ProcessPlanningInbox
  @RunId uniqueidentifier,
  @OrganizationId int,
  @SourceCode nvarchar(100)
AS
BEGIN
  /*
    Planiranje: dobavni rok, kolicine in stikala, po katerih ERP odloca o narocanju. Ena vrstica
    na artikel.

    Prenesenih je sedem polj od sedemindvajsetih, ki jih SAOP poslje. Ostalo je notranje
    racunovodstvo proizvodnje (pretvorniki, povrsine, MIT) in ga PIM ne rabi; ce se izkaze, da
    ga kdo potrebuje, je dodajanje vrstica registra in stolpec, ne nov zajem.
  */
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  DECLARE @InboxId bigint;
  DECLARE zajem_cursor CURSOR LOCAL FAST_FORWARD FOR
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
          AND entityMapping.TargetDomain=''ProductPlanning''
      )
    ORDER BY inbox.InboxId;

  OPEN zajem_cursor;
  FETCH NEXT FROM zajem_cursor INTO @InboxId;
  WHILE @@FETCH_STATUS=0
  BEGIN
    BEGIN TRY
      BEGIN TRANSACTION;

      IF OBJECT_ID(''tempdb..#Zapis'') IS NOT NULL DROP TABLE #Zapis;

      SELECT izdelek.ProductId,
        TRY_CONVERT(int, zapis.LeadTime) AS LeadTimeDays,
        TRY_CONVERT(int, zapis.PurchaseLeadTime) AS PurchaseLeadTimeDays,
        TRY_CONVERT(int, zapis.AggregationPeriodDays) AS AggregationPeriodDays,
        TRY_CONVERT(decimal(19,4), zapis.LeadTimeQty) AS LeadTimeQuantity,
        TRY_CONVERT(decimal(19,4), zapis.OptimumProductionQty) AS OptimumProductionQuantity,
        CASE WHEN LOWER(LTRIM(RTRIM(ISNULL(zapis.ExcludeQtyReservation,'''')))) IN (''true'',''1'',''da'') THEN 1 ELSE 0 END AS ExcludeQuantityReservation,
        CASE WHEN LOWER(LTRIM(RTRIM(ISNULL(zapis.Phantom,'''')))) IN (''true'',''1'',''da'') THEN 1 ELSE 0 END AS IsPhantom
      INTO #Zapis
      FROM
      (
        SELECT value.RecordOrdinal,
          MAX(CASE WHEN value.TargetFieldCode=''Record.ItemID'' THEN CONVERT(nvarchar(100),value.Value) END) AS ItemID,
          MAX(CASE WHEN value.TargetFieldCode=''Planning.LeadTime'' THEN CONVERT(nvarchar(50),value.Value) END) AS LeadTime,
          MAX(CASE WHEN value.TargetFieldCode=''Planning.PurchaseLeadTime'' THEN CONVERT(nvarchar(50),value.Value) END) AS PurchaseLeadTime,
          MAX(CASE WHEN value.TargetFieldCode=''Planning.AggregationPeriodDays'' THEN CONVERT(nvarchar(50),value.Value) END) AS AggregationPeriodDays,
          MAX(CASE WHEN value.TargetFieldCode=''Planning.LeadTimeQty'' THEN CONVERT(nvarchar(50),value.Value) END) AS LeadTimeQty,
          MAX(CASE WHEN value.TargetFieldCode=''Planning.OptimumProductionQty'' THEN CONVERT(nvarchar(50),value.Value) END) AS OptimumProductionQty,
          MAX(CASE WHEN value.TargetFieldCode=''Planning.ExcludeQtyReservation'' THEN CONVERT(nvarchar(20),value.Value) END) AS ExcludeQtyReservation,
          MAX(CASE WHEN value.TargetFieldCode=''Planning.Phantom'' THEN CONVERT(nvarchar(20),value.Value) END) AS Phantom
        FROM map.ExtractedValue value
        WHERE value.InboxId=@InboxId
          AND EXISTS(SELECT 1 FROM map.FieldMapping mapping
                     WHERE mapping.FieldMappingId=value.FieldMappingId AND mapping.IsActive=1)
        GROUP BY value.RecordOrdinal
      ) zapis
      INNER JOIN canon.Product izdelek
        ON izdelek.OrganizationId=@OrganizationId AND izdelek.ItemID=LTRIM(RTRIM(zapis.ItemID));

      MERGE canon.ProductPlanning AS target
      USING (SELECT DISTINCT ProductId, LeadTimeDays, PurchaseLeadTimeDays, AggregationPeriodDays,
                    LeadTimeQuantity, OptimumProductionQuantity, ExcludeQuantityReservation, IsPhantom FROM #Zapis) source
        ON target.ProductId=source.ProductId
      WHEN MATCHED THEN UPDATE SET LeadTimeDays=source.LeadTimeDays, PurchaseLeadTimeDays=source.PurchaseLeadTimeDays,
        AggregationPeriodDays=source.AggregationPeriodDays, LeadTimeQuantity=source.LeadTimeQuantity,
        OptimumProductionQuantity=source.OptimumProductionQuantity,
        ExcludeQuantityReservation=source.ExcludeQuantityReservation, IsPhantom=source.IsPhantom,
        UpdatedUtc=SYSUTCDATETIME()
      WHEN NOT MATCHED THEN INSERT(ProductId,LeadTimeDays,PurchaseLeadTimeDays,AggregationPeriodDays,
        LeadTimeQuantity,OptimumProductionQuantity,ExcludeQuantityReservation,IsPhantom)
        VALUES(source.ProductId,source.LeadTimeDays,source.PurchaseLeadTimeDays,source.AggregationPeriodDays,
               source.LeadTimeQuantity,source.OptimumProductionQuantity,source.ExcludeQuantityReservation,source.IsPhantom);

      DECLARE @Zapisov int = (SELECT COUNT(DISTINCT value.RecordOrdinal) FROM map.ExtractedValue value WHERE value.InboxId=@InboxId);
      DECLARE @Uporabljenih int = (SELECT COUNT(*) FROM #Zapis);

      UPDATE raw.Inbox
      SET Status=''Processed'', ProcessedUtc=SYSUTCDATETIME(),
          FailureReason=CASE WHEN @Uporabljenih=@Zapisov THEN NULL
            ELSE CONCAT(''Uporabljenih: '', @Uporabljenih, '' od '', @Zapisov, ''. Preostali nimajo artikla v katalogu.'') END
      WHERE InboxId=@InboxId;

      DROP TABLE #Zapis;
      COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
      IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
      DECLARE @Napaka nvarchar(500)=ERROR_MESSAGE();
      UPDATE raw.Inbox SET Status=''Quarantined'', ProcessedUtc=SYSUTCDATETIME(), FailureReason=LEFT(@Napaka,2000)
      WHERE InboxId=@InboxId;
    END CATCH;

    FETCH NEXT FROM zajem_cursor INTO @InboxId;
  END;
  CLOSE zajem_cursor;
  DEALLOCATE zajem_cursor;
END;
');

/* --- 5) preverbe -------------------------------------------------------------- */

EXEC(N'
IF (SELECT COUNT(*) FROM map.EntityMapping WHERE TargetDomain = N''Codebook'' AND IsActive = 1) < 8
  THROW 52821, ''Valute in ceniki niso nastavljeni na vseh stirih konektorjih.'', 1;
IF (SELECT COUNT(*) FROM map.EntityMapping WHERE TargetDomain = N''ProductStockAccounting'' AND IsActive = 1) < 4
  THROW 52822, ''Konti zaloge niso nastavljeni na vseh stirih konektorjih.'', 1;
IF (SELECT COUNT(*) FROM map.EntityMapping WHERE TargetDomain = N''ProductPlanning'' AND IsActive = 1) < 4
  THROW 52823, ''Planiranje ni nastavljeno na vseh stirih konektorjih.'', 1;
IF EXISTS (SELECT 1 FROM map.EntityMapping WHERE TargetDomain = N''Codebook'' AND CodebookCode IS NULL)
  THROW 52824, ''Sifrant brez oznake, katera sifranta je.'', 1;
');

IF OBJECT_ID(N'map.ProcessCodebookInbox') IS NULL OR OBJECT_ID(N'map.ProcessStockAccountingInbox') IS NULL
  OR OBJECT_ID(N'map.ProcessPlanningInbox') IS NULL
  THROW 52825, 'Manjka eden od novih postopkov.', 1;
