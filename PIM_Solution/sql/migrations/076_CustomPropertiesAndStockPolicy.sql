/*
  076 — lastnosti po meri in pravilo najmanjse/najvecje zaloge.

  Dve entiteti, ki sta od prvega zajema cakali v raw.Inbox (10 in 5 strani), ker zanju ni bilo
  preslikave. Obe sta iste oblike kot nazivi po jezikih: kljuc pride iz podatka, ne iz imena
  ciljne kode, zato imata svoj postopek in ne gresta skozi map.ProcessRawInbox.

  1. Lastnosti po meri (GetItemsCustomProperties). Zapis je par: PropertyID in PropertyValue.
     Ime lastnosti se ne prevaja — kar SAOP imenuje BUG, se v katalogu imenuje BUG. Prevod v
     naso kodo je stvar slovarja in odlocitve, ne tega postopka.

  2. Najmanjsa in najvecja zaloga (GetItemsStockData). To NI kolicina na zalogi: kolicine
     pridejo z locenega vmesnika (065). To je pravilo po skladiscu — koliko naj bi bilo.
     Zato svoja tabela canon.ProductStockPolicy in ne stock.*, kjer zivijo posnetki kolicin.

  Naslov sifre artikla je pri obeh en nivo visje od zapisa ('../../ItemID'), enako kot pri
  nazivih (072).
*/

SET XACT_ABORT ON;

/* --- 1) pravilo zaloge po skladiscu ----------------------------------------- */

IF OBJECT_ID(N'canon.ProductStockPolicy') IS NULL
BEGIN
  CREATE TABLE canon.ProductStockPolicy
  (
    ProductStockPolicyId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_ProductStockPolicy PRIMARY KEY,
    ProductId bigint NOT NULL,
    WarehouseCode nvarchar(50) NOT NULL,
    MinimumStock decimal(19,4) NULL,
    MaximumStock decimal(19,4) NULL,
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_ProductStockPolicy_UpdatedUtc DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_ProductStockPolicy UNIQUE (ProductId, WarehouseCode),
    CONSTRAINT FK_ProductStockPolicy_Product FOREIGN KEY (ProductId) REFERENCES canon.Product(ProductId)
  );
END;

/* --- 2) dva nova svetova v registru ----------------------------------------- */

IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_EntityMapping_TargetDomain')
  ALTER TABLE map.EntityMapping DROP CONSTRAINT CK_EntityMapping_TargetDomain;

ALTER TABLE map.EntityMapping WITH CHECK
  ADD CONSTRAINT CK_EntityMapping_TargetDomain
  CHECK (TargetDomain IN (N'Product', N'Warehouse', N'Language', N'ProductText',
                          N'ProductAttributePair', N'ProductStockPolicy'));

/* --- 3) preslikave na vseh stirih SAOP konektorjih -------------------------- */

/* --- SAOP_DEMO --- */
EXEC(N'
DECLARE @ConnectorId int = (SELECT SourceConnectorId FROM map.SourceConnector WHERE SourceCode = N''SAOP_DEMO'' AND OrganizationId = 1);
IF @ConnectorId IS NOT NULL
BEGIN
  MERGE map.EntityMapping AS target
  USING (VALUES
    (N''GetItemsCustomProperties'', N''/ItemsCustProperties/ItemCustProperties/CustProperties/CustProperty'', N''ProductAttributePair''),
    (N''GetItemsStockData'',        N''/ItemsStockData/ItemStockData/ItemWarehousesData/ItemWarehouseData'',  N''ProductStockPolicy'')
  ) AS source(EntityType, RecordXPath, TargetDomain)
    ON target.SourceConnectorId = @ConnectorId AND target.EntityType = source.EntityType
  WHEN MATCHED THEN UPDATE SET RecordXPath = source.RecordXPath, TargetDomain = source.TargetDomain, IsActive = 1
  WHEN NOT MATCHED THEN INSERT (SourceConnectorId, EntityType, RecordXPath, TargetDomain, IsActive)
    VALUES (@ConnectorId, source.EntityType, source.RecordXPath, source.TargetDomain, 1);

  MERGE map.FieldMapping AS target
  USING (VALUES
    (N''GetItemsCustomProperties'', N''../../ItemID/text()[1]'',   N''Record.ItemID'',         CONVERT(bit,1)),
    (N''GetItemsCustomProperties'', N''PropertyID/text()[1]'',     N''Record.AttributeCode'',  CONVERT(bit,1)),
    (N''GetItemsCustomProperties'', N''PropertyValue/text()[1]'',  N''Record.AttributeValue'', CONVERT(bit,0)),
    (N''GetItemsStockData'',        N''../../ItemID/text()[1]'',   N''Record.ItemID'',              CONVERT(bit,1)),
    (N''GetItemsStockData'',        N''WarehouseID/text()[1]'',    N''Record.WarehouseCode'',       CONVERT(bit,1)),
    (N''GetItemsStockData'',        N''MinimumStock/text()[1]'',   N''StockPolicy.MinimumStock'',   CONVERT(bit,0)),
    (N''GetItemsStockData'',        N''MaximumStock/text()[1]'',   N''StockPolicy.MaximumStock'',   CONVERT(bit,0))
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
    (N''GetItemsCustomProperties'', N''/ItemsCustProperties/ItemCustProperties/CustProperties/CustProperty'', N''ProductAttributePair''),
    (N''GetItemsStockData'',        N''/ItemsStockData/ItemStockData/ItemWarehousesData/ItemWarehouseData'',  N''ProductStockPolicy'')
  ) AS source(EntityType, RecordXPath, TargetDomain)
    ON target.SourceConnectorId = @ConnectorId AND target.EntityType = source.EntityType
  WHEN MATCHED THEN UPDATE SET RecordXPath = source.RecordXPath, TargetDomain = source.TargetDomain, IsActive = 1
  WHEN NOT MATCHED THEN INSERT (SourceConnectorId, EntityType, RecordXPath, TargetDomain, IsActive)
    VALUES (@ConnectorId, source.EntityType, source.RecordXPath, source.TargetDomain, 1);

  MERGE map.FieldMapping AS target
  USING (VALUES
    (N''GetItemsCustomProperties'', N''../../ItemID/text()[1]'',   N''Record.ItemID'',         CONVERT(bit,1)),
    (N''GetItemsCustomProperties'', N''PropertyID/text()[1]'',     N''Record.AttributeCode'',  CONVERT(bit,1)),
    (N''GetItemsCustomProperties'', N''PropertyValue/text()[1]'',  N''Record.AttributeValue'', CONVERT(bit,0)),
    (N''GetItemsStockData'',        N''../../ItemID/text()[1]'',   N''Record.ItemID'',              CONVERT(bit,1)),
    (N''GetItemsStockData'',        N''WarehouseID/text()[1]'',    N''Record.WarehouseCode'',       CONVERT(bit,1)),
    (N''GetItemsStockData'',        N''MinimumStock/text()[1]'',   N''StockPolicy.MinimumStock'',   CONVERT(bit,0)),
    (N''GetItemsStockData'',        N''MaximumStock/text()[1]'',   N''StockPolicy.MaximumStock'',   CONVERT(bit,0))
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
    (N''GetItemsCustomProperties'', N''/ItemsCustProperties/ItemCustProperties/CustProperties/CustProperty'', N''ProductAttributePair''),
    (N''GetItemsStockData'',        N''/ItemsStockData/ItemStockData/ItemWarehousesData/ItemWarehouseData'',  N''ProductStockPolicy'')
  ) AS source(EntityType, RecordXPath, TargetDomain)
    ON target.SourceConnectorId = @ConnectorId AND target.EntityType = source.EntityType
  WHEN MATCHED THEN UPDATE SET RecordXPath = source.RecordXPath, TargetDomain = source.TargetDomain, IsActive = 1
  WHEN NOT MATCHED THEN INSERT (SourceConnectorId, EntityType, RecordXPath, TargetDomain, IsActive)
    VALUES (@ConnectorId, source.EntityType, source.RecordXPath, source.TargetDomain, 1);

  MERGE map.FieldMapping AS target
  USING (VALUES
    (N''GetItemsCustomProperties'', N''../../ItemID/text()[1]'',   N''Record.ItemID'',         CONVERT(bit,1)),
    (N''GetItemsCustomProperties'', N''PropertyID/text()[1]'',     N''Record.AttributeCode'',  CONVERT(bit,1)),
    (N''GetItemsCustomProperties'', N''PropertyValue/text()[1]'',  N''Record.AttributeValue'', CONVERT(bit,0)),
    (N''GetItemsStockData'',        N''../../ItemID/text()[1]'',   N''Record.ItemID'',              CONVERT(bit,1)),
    (N''GetItemsStockData'',        N''WarehouseID/text()[1]'',    N''Record.WarehouseCode'',       CONVERT(bit,1)),
    (N''GetItemsStockData'',        N''MinimumStock/text()[1]'',   N''StockPolicy.MinimumStock'',   CONVERT(bit,0)),
    (N''GetItemsStockData'',        N''MaximumStock/text()[1]'',   N''StockPolicy.MaximumStock'',   CONVERT(bit,0))
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
    (N''GetItemsCustomProperties'', N''/ItemsCustProperties/ItemCustProperties/CustProperties/CustProperty'', N''ProductAttributePair''),
    (N''GetItemsStockData'',        N''/ItemsStockData/ItemStockData/ItemWarehousesData/ItemWarehouseData'',  N''ProductStockPolicy'')
  ) AS source(EntityType, RecordXPath, TargetDomain)
    ON target.SourceConnectorId = @ConnectorId AND target.EntityType = source.EntityType
  WHEN MATCHED THEN UPDATE SET RecordXPath = source.RecordXPath, TargetDomain = source.TargetDomain, IsActive = 1
  WHEN NOT MATCHED THEN INSERT (SourceConnectorId, EntityType, RecordXPath, TargetDomain, IsActive)
    VALUES (@ConnectorId, source.EntityType, source.RecordXPath, source.TargetDomain, 1);

  MERGE map.FieldMapping AS target
  USING (VALUES
    (N''GetItemsCustomProperties'', N''../../ItemID/text()[1]'',   N''Record.ItemID'',         CONVERT(bit,1)),
    (N''GetItemsCustomProperties'', N''PropertyID/text()[1]'',     N''Record.AttributeCode'',  CONVERT(bit,1)),
    (N''GetItemsCustomProperties'', N''PropertyValue/text()[1]'',  N''Record.AttributeValue'', CONVERT(bit,0)),
    (N''GetItemsStockData'',        N''../../ItemID/text()[1]'',   N''Record.ItemID'',              CONVERT(bit,1)),
    (N''GetItemsStockData'',        N''WarehouseID/text()[1]'',    N''Record.WarehouseCode'',       CONVERT(bit,1)),
    (N''GetItemsStockData'',        N''MinimumStock/text()[1]'',   N''StockPolicy.MinimumStock'',   CONVERT(bit,0)),
    (N''GetItemsStockData'',        N''MaximumStock/text()[1]'',   N''StockPolicy.MaximumStock'',   CONVERT(bit,0))
  ) AS source(EntityType, SourceElement, TargetFieldCode, IsRequired)
    ON target.SourceConnectorId = @ConnectorId AND target.EntityType = source.EntityType
      AND target.TargetFieldCode = source.TargetFieldCode
  WHEN MATCHED THEN UPDATE SET SourceElement = source.SourceElement, IsRequired = source.IsRequired, IsActive = 1
  WHEN NOT MATCHED THEN INSERT (SourceConnectorId, EntityType, SourceElement, TargetFieldCode, IsRequired, IsActive)
    VALUES (@ConnectorId, source.EntityType, source.SourceElement, source.TargetFieldCode, source.IsRequired, 1);
END;
');

/* --- 4) postopka ------------------------------------------------------------- */

EXEC(N'
CREATE OR ALTER PROCEDURE map.ProcessAttributePairInbox
  @RunId uniqueidentifier,
  @OrganizationId int,
  @SourceCode nvarchar(100)
AS
BEGIN
  /*
    Lastnosti po meri iz SAOP. Vsak zapis je par: ime lastnosti (PropertyID) in vrednost.

    map.ProcessRawInbox tega ne zna, ker ime lastnosti pozna samo kot del ciljne kode
    (ProductAttribute.Grlo), tukaj pa ime pride iz podatka in je na vsakem zapisu drugacno —
    isti razlog kot pri nazivih po jezikih (072).

    Ime lastnosti se ne prevaja: kar SAOP imenuje BUG, se v katalogu imenuje BUG. Prevod v
    naso kodo je stvar slovarja in odlocitve, ne tega postopka.
  */
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  DECLARE @InboxId bigint;
  DECLARE pair_cursor CURSOR LOCAL FAST_FORWARD FOR
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
          AND entityMapping.TargetDomain=''ProductAttributePair''
      )
    ORDER BY inbox.InboxId;

  OPEN pair_cursor;
  FETCH NEXT FROM pair_cursor INTO @InboxId;
  WHILE @@FETCH_STATUS=0
  BEGIN
    BEGIN TRY
      BEGIN TRANSACTION;

      IF OBJECT_ID(''tempdb..#Par'') IS NOT NULL DROP TABLE #Par;

      SELECT izdelek.ProductId, zapis.AttributeCode, zapis.AttributeValue, zapis.RecordOrdinal
      INTO #Par
      FROM
      (
        SELECT value.RecordOrdinal,
          MAX(CASE WHEN value.TargetFieldCode=''Record.ItemID'' THEN CONVERT(nvarchar(100),value.Value) END) AS ItemID,
          MAX(CASE WHEN value.TargetFieldCode=''Record.AttributeCode'' THEN CONVERT(nvarchar(200),value.Value) END) AS AttributeCode,
          MAX(CASE WHEN value.TargetFieldCode=''Record.AttributeValue'' THEN CONVERT(nvarchar(max),value.Value) END) AS AttributeValue
        FROM map.ExtractedValue value
        WHERE value.InboxId=@InboxId
          AND EXISTS(SELECT 1 FROM map.FieldMapping mapping
                     WHERE mapping.FieldMappingId=value.FieldMappingId AND mapping.IsActive=1)
        GROUP BY value.RecordOrdinal
      ) zapis
      INNER JOIN canon.Product izdelek
        ON izdelek.OrganizationId=@OrganizationId AND izdelek.ItemID=LTRIM(RTRIM(zapis.ItemID))
      WHERE NULLIF(LTRIM(RTRIM(zapis.AttributeCode)),'''') IS NOT NULL
        AND NULLIF(LTRIM(RTRIM(zapis.AttributeValue)),'''') IS NOT NULL;

      MERGE canon.ProductAttribute AS target
      USING
      (
        SELECT ProductId, LTRIM(RTRIM(AttributeCode)) AS AttributeCode, AttributeValue
        FROM
        (
          SELECT ProductId, AttributeCode, AttributeValue,
            ROW_NUMBER() OVER(PARTITION BY ProductId, LTRIM(RTRIM(AttributeCode)) ORDER BY RecordOrdinal DESC) AS Mesto
          FROM #Par
        ) zadnji
        WHERE Mesto=1
      ) source
        ON target.ProductId=source.ProductId AND target.AttributeCode=source.AttributeCode
      WHEN MATCHED THEN UPDATE SET Value=source.AttributeValue
      WHEN NOT MATCHED THEN INSERT(ProductId,AttributeCode,Value)
        VALUES(source.ProductId,source.AttributeCode,source.AttributeValue);

      DECLARE @Zapisov int = (SELECT COUNT(DISTINCT value.RecordOrdinal) FROM map.ExtractedValue value WHERE value.InboxId=@InboxId);
      DECLARE @Uporabljenih int = (SELECT COUNT(DISTINCT RecordOrdinal) FROM #Par);

      UPDATE raw.Inbox
      SET Status=''Processed'', ProcessedUtc=SYSUTCDATETIME(),
          FailureReason=CASE WHEN @Uporabljenih=@Zapisov THEN NULL
            ELSE CONCAT(''Lastnosti uporabljenih: '', @Uporabljenih, '' od '', @Zapisov,
                        ''. Preostali nimajo artikla v katalogu ali so brez imena oziroma vrednosti.'') END
      WHERE InboxId=@InboxId;

      DROP TABLE #Par;
      COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
      IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
      DECLARE @Napaka nvarchar(500)=ERROR_MESSAGE();
      UPDATE raw.Inbox SET Status=''Quarantined'', ProcessedUtc=SYSUTCDATETIME(), FailureReason=LEFT(@Napaka,2000)
      WHERE InboxId=@InboxId;
    END CATCH;

    FETCH NEXT FROM pair_cursor INTO @InboxId;
  END;
  CLOSE pair_cursor;
  DEALLOCATE pair_cursor;
END;
');

EXEC(N'
CREATE OR ALTER PROCEDURE map.ProcessStockPolicyInbox
  @RunId uniqueidentifier,
  @OrganizationId int,
  @SourceCode nvarchar(100)
AS
BEGIN
  /*
    Najmanjsa in najvecja zaloga po skladiscu (GetItemsStockData). To ni kolicina na zalogi —
    kolicine pridejo z locenega vmesnika (065) — ampak pravilo, koliko naj je bi bilo.

    Skladisce se veze na sifrant canon.Warehouse (064). Vrstica za skladisce, ki ga v sifrantu
    ni, se vseeno shrani: pravilo je vezano na sifro skladisca in ne izgine, ce sifrant zaostaja.
  */
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  DECLARE @InboxId bigint;
  DECLARE policy_cursor CURSOR LOCAL FAST_FORWARD FOR
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
          AND entityMapping.TargetDomain=''ProductStockPolicy''
      )
    ORDER BY inbox.InboxId;

  OPEN policy_cursor;
  FETCH NEXT FROM policy_cursor INTO @InboxId;
  WHILE @@FETCH_STATUS=0
  BEGIN
    BEGIN TRY
      BEGIN TRANSACTION;

      IF OBJECT_ID(''tempdb..#Pravilo'') IS NOT NULL DROP TABLE #Pravilo;

      SELECT izdelek.ProductId, LTRIM(RTRIM(zapis.WarehouseCode)) AS WarehouseCode,
        TRY_CONVERT(decimal(19,4), zapis.MinimumStock) AS MinimumStock,
        TRY_CONVERT(decimal(19,4), zapis.MaximumStock) AS MaximumStock,
        zapis.RecordOrdinal
      INTO #Pravilo
      FROM
      (
        SELECT value.RecordOrdinal,
          MAX(CASE WHEN value.TargetFieldCode=''Record.ItemID'' THEN CONVERT(nvarchar(100),value.Value) END) AS ItemID,
          MAX(CASE WHEN value.TargetFieldCode=''Record.WarehouseCode'' THEN CONVERT(nvarchar(50),value.Value) END) AS WarehouseCode,
          MAX(CASE WHEN value.TargetFieldCode=''StockPolicy.MinimumStock'' THEN CONVERT(nvarchar(50),value.Value) END) AS MinimumStock,
          MAX(CASE WHEN value.TargetFieldCode=''StockPolicy.MaximumStock'' THEN CONVERT(nvarchar(50),value.Value) END) AS MaximumStock
        FROM map.ExtractedValue value
        WHERE value.InboxId=@InboxId
          AND EXISTS(SELECT 1 FROM map.FieldMapping mapping
                     WHERE mapping.FieldMappingId=value.FieldMappingId AND mapping.IsActive=1)
        GROUP BY value.RecordOrdinal
      ) zapis
      INNER JOIN canon.Product izdelek
        ON izdelek.OrganizationId=@OrganizationId AND izdelek.ItemID=LTRIM(RTRIM(zapis.ItemID))
      WHERE NULLIF(LTRIM(RTRIM(zapis.WarehouseCode)),'''') IS NOT NULL;

      MERGE canon.ProductStockPolicy AS target
      USING
      (
        SELECT ProductId, WarehouseCode, MinimumStock, MaximumStock
        FROM
        (
          SELECT ProductId, WarehouseCode, MinimumStock, MaximumStock,
            ROW_NUMBER() OVER(PARTITION BY ProductId, WarehouseCode ORDER BY RecordOrdinal DESC) AS Mesto
          FROM #Pravilo
        ) zadnji
        WHERE Mesto=1
      ) source
        ON target.ProductId=source.ProductId AND target.WarehouseCode=source.WarehouseCode
      WHEN MATCHED THEN UPDATE SET MinimumStock=source.MinimumStock, MaximumStock=source.MaximumStock,
        UpdatedUtc=SYSUTCDATETIME()
      WHEN NOT MATCHED THEN INSERT(ProductId,WarehouseCode,MinimumStock,MaximumStock)
        VALUES(source.ProductId,source.WarehouseCode,source.MinimumStock,source.MaximumStock);

      DECLARE @Zapisov int = (SELECT COUNT(DISTINCT value.RecordOrdinal) FROM map.ExtractedValue value WHERE value.InboxId=@InboxId);
      DECLARE @Uporabljenih int = (SELECT COUNT(DISTINCT RecordOrdinal) FROM #Pravilo);

      UPDATE raw.Inbox
      SET Status=''Processed'', ProcessedUtc=SYSUTCDATETIME(),
          FailureReason=CASE WHEN @Uporabljenih=@Zapisov THEN NULL
            ELSE CONCAT(''Pravil zaloge uporabljenih: '', @Uporabljenih, '' od '', @Zapisov,
                        ''. Preostali nimajo artikla v katalogu.'') END
      WHERE InboxId=@InboxId;

      DROP TABLE #Pravilo;
      COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
      IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
      DECLARE @Napaka nvarchar(500)=ERROR_MESSAGE();
      UPDATE raw.Inbox SET Status=''Quarantined'', ProcessedUtc=SYSUTCDATETIME(), FailureReason=LEFT(@Napaka,2000)
      WHERE InboxId=@InboxId;
    END CATCH;

    FETCH NEXT FROM policy_cursor INTO @InboxId;
  END;
  CLOSE policy_cursor;
  DEALLOCATE policy_cursor;
END;
');

/* --- 5) preverbe ------------------------------------------------------------- */

EXEC(N'
IF (SELECT COUNT(*) FROM map.EntityMapping WHERE EntityType = N''GetItemsCustomProperties'' AND TargetDomain = N''ProductAttributePair'' AND IsActive = 1) < 4
  THROW 52761, ''Lastnosti po meri niso nastavljene na vseh stirih konektorjih.'', 1;
IF (SELECT COUNT(*) FROM map.EntityMapping WHERE EntityType = N''GetItemsStockData'' AND TargetDomain = N''ProductStockPolicy'' AND IsActive = 1) < 4
  THROW 52762, ''Pravilo zaloge ni nastavljeno na vseh stirih konektorjih.'', 1;
');

IF OBJECT_ID(N'map.ProcessAttributePairInbox') IS NULL
  THROW 52763, 'Postopek map.ProcessAttributePairInbox ne obstaja.', 1;
IF OBJECT_ID(N'map.ProcessStockPolicyInbox') IS NULL
  THROW 52764, 'Postopek map.ProcessStockPolicyInbox ne obstaja.', 1;
