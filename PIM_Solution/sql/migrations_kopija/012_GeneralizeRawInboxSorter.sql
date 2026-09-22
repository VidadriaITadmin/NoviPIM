SET XACT_ABORT ON;

-- F5: konfiguracijsko vodena XPath sortirnica. Vir določa izključno map.SourceConnector,
-- map.EntityMapping in map.FieldMapping; jedro ne pozna imen ali struktur posameznih virov.
IF NOT EXISTS
(
  SELECT 1 FROM map.EntityMapping entityMapping
  INNER JOIN map.SourceConnector connector ON connector.SourceConnectorId=entityMapping.SourceConnectorId
  WHERE connector.ConnectorType=N'SAOP' AND connector.OrganizationId=2
)
BEGIN
  INSERT map.EntityMapping(SourceConnectorId,EntityType,RecordXPath,IsActive)
  SELECT connector.SourceConnectorId,value.EntityType,value.RecordXPath,CONVERT(bit,1)
  FROM map.SourceConnector connector
  CROSS APPLY (VALUES
    (N'ItemGeneralData',N'/*[local-name()="ItemsGeneralData"]/*[local-name()="ItemGeneralData"]'),
    (N'Prices',N'/*[local-name()="ArrayOfPrice"]/*[local-name()="Price"]'),
    (N'Descriptions',N'/*[local-name()="ItemsDescriptions"]/*[local-name()="itemDescriptions"]')
  ) value(EntityType,RecordXPath)
  WHERE connector.ConnectorType=N'SAOP' AND connector.OrganizationId=2;
END;

DELETE fieldMapping
FROM map.FieldMapping fieldMapping
INNER JOIN map.SourceConnector connector ON connector.SourceConnectorId=fieldMapping.SourceConnectorId
WHERE connector.ConnectorType=N'SAOP' AND connector.OrganizationId=2
  AND fieldMapping.EntityType IN (N'ItemGeneralData',N'Prices',N'Descriptions');

INSERT map.FieldMapping(SourceConnectorId,EntityType,SourceElement,TargetFieldCode,IsRequired,IsActive)
SELECT connector.SourceConnectorId,value.EntityType,value.SourceElement,value.TargetFieldCode,value.IsRequired,CONVERT(bit,1)
FROM map.SourceConnector connector
CROSS APPLY (VALUES
  (N'ItemGeneralData',N'ItemID/text()',N'Product.ItemID',CONVERT(bit,1)),
  (N'ItemGeneralData',N'ItemTitle1/text()',N'ProductText.TITLE_ERP.sl',CONVERT(bit,1)),
  (N'ItemGeneralData',N'GeneralData/ItemUnitOfMeas/text()',N'Product.UoM',CONVERT(bit,1)),
  (N'ItemGeneralData',N'GeneralData/AccountingBookGroupID/text()',N'Product.AccountingGroup',CONVERT(bit,1)),
  (N'ItemGeneralData',N'StockData/SupplierID/text()',N'Product.Supplier',CONVERT(bit,1)),
  (N'ItemGeneralData',N'SalesData/DiscountGroup1ID/text()',N'Product.DiscountGroup',CONVERT(bit,1)),
  (N'ItemGeneralData',N'StockData/ManufacturerID/text()',N'Product.Manufacturer',CONVERT(bit,1)),
  (N'Prices',N'ItemCode/text()',N'Product.ItemID',CONVERT(bit,1)),
  (N'Prices',N'ItemEAN/text()',N'Product.EAN',CONVERT(bit,0)),
  (N'Prices',N'PriceListId/text()',N'ProductPrice.PriceList',CONVERT(bit,1)),
  (N'Prices',N'Price/text()',N'ProductPrice.Net',CONVERT(bit,1)),
  (N'Prices',N'VATRate/text()',N'ProductPrice.VatRate',CONVERT(bit,1)),
  (N'Prices',N'PriceValidityFrom/text()',N'ProductPrice.ValidFrom',CONVERT(bit,0)),
  (N'Descriptions',N'ItemID/text()',N'Product.ItemID',CONVERT(bit,1)),
  (N'Descriptions',N'Descriptions/Description/text()',N'ProductText.DESCRIPTION.sl',CONVERT(bit,0))
) value(EntityType,SourceElement,TargetFieldCode,IsRequired)
WHERE connector.ConnectorType=N'SAOP' AND connector.OrganizationId=2;

EXEC(N'
CREATE OR ALTER PROCEDURE map.ProcessRawInbox
  @RunId uniqueidentifier,
  @OrganizationId int,
  @SourceCode nvarchar(100)
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  DECLARE @SourceConnectorId int=(SELECT SourceConnectorId FROM map.SourceConnector WHERE SourceCode=@SourceCode AND OrganizationId=@OrganizationId AND IsActive=1);
  IF @SourceConnectorId IS NULL THROW 52310,''Aktivni izvorni konektor ne obstaja.'',1;

  INSERT ops.DeadLetterQueue(Layer,SourceCode,OrganizationId,EntityType,NaturalKey,PayloadJson,FailureReason)
  SELECT N''raw'',SourceCode,OrganizationId,EntityType,CONVERT(nvarchar(450),InboxId),PayloadXml,N''Neveljaven XML.''
  FROM raw.Inbox
  WHERE RunId=@RunId AND OrganizationId=@OrganizationId AND SourceCode=@SourceCode AND Status=N''Pending''
    AND TRY_CONVERT(xml,map.StripXmlDeclaration(PayloadXml)) IS NULL;

  UPDATE raw.Inbox SET Status=N''Quarantined'',ProcessedUtc=SYSUTCDATETIME(),FailureReason=N''Neveljaven XML.''
  WHERE RunId=@RunId AND OrganizationId=@OrganizationId AND SourceCode=@SourceCode AND Status=N''Pending''
    AND TRY_CONVERT(xml,map.StripXmlDeclaration(PayloadXml)) IS NULL;

  CREATE TABLE #MappedValue
  (
    RecordOrdinal int NOT NULL,
    TargetFieldCode nvarchar(200) NOT NULL,
    Value nvarchar(max) NULL
  );

  DECLARE @InboxId bigint,@EntityType nvarchar(100),@Payload xml,@RecordXPath nvarchar(2000),@SourceElement nvarchar(2000),@TargetFieldCode nvarchar(200),@Sql nvarchar(max);
  DECLARE inbox_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT inbox.InboxId,inbox.EntityType,TRY_CONVERT(xml,map.StripXmlDeclaration(inbox.PayloadXml)),entityMapping.RecordXPath
    FROM raw.Inbox inbox
    INNER JOIN map.EntityMapping entityMapping ON entityMapping.SourceConnectorId=@SourceConnectorId AND entityMapping.EntityType=inbox.EntityType AND entityMapping.IsActive=1
    WHERE inbox.RunId=@RunId AND inbox.OrganizationId=@OrganizationId AND inbox.SourceCode=@SourceCode AND inbox.Status=N''Pending'';

  OPEN inbox_cursor;
  FETCH NEXT FROM inbox_cursor INTO @InboxId,@EntityType,@Payload,@RecordXPath;
  WHILE @@FETCH_STATUS=0
  BEGIN
    BEGIN TRY
      DELETE FROM #MappedValue;
      DECLARE mapping_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT SourceElement,TargetFieldCode FROM map.FieldMapping
        WHERE SourceConnectorId=@SourceConnectorId AND EntityType=@EntityType AND IsActive=1;
      OPEN mapping_cursor;
      FETCH NEXT FROM mapping_cursor INTO @SourceElement,@TargetFieldCode;
      WHILE @@FETCH_STATUS=0
      BEGIN
        SET @Sql=N'';WITH records AS
        (
          SELECT ROW_NUMBER() OVER (ORDER BY (SELECT 1)) RecordOrdinal,node.query(''''.'''') RecordXml
          FROM @InputPayload.nodes('''''' + REPLACE(@RecordXPath,'''''''','''''''''''') + N'''''') source(node)
        )
        INSERT #MappedValue(RecordOrdinal,TargetFieldCode,Value)
        SELECT records.RecordOrdinal,@InputTarget,NULLIF(records.RecordXml.value(''''('''' + REPLACE(@InputElement,'''''''','''''''''''') + '''')[1]'''',''''nvarchar(max)''''),N'''''''')
        FROM records;'';
        EXEC sp_executesql @Sql,N''@InputPayload xml,@InputTarget nvarchar(200),@InputElement nvarchar(2000)'',@InputPayload=@Payload,@InputTarget=@TargetFieldCode,@InputElement=@SourceElement;
        FETCH NEXT FROM mapping_cursor INTO @SourceElement,@TargetFieldCode;
      END;
      CLOSE mapping_cursor;
      DEALLOCATE mapping_cursor;

      DECLARE @RecordOrdinal int,@ItemID nvarchar(100),@EAN nvarchar(100),@ProductId bigint;
      DECLARE record_cursor CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT RecordOrdinal FROM #MappedValue ORDER BY RecordOrdinal;
      OPEN record_cursor;
      FETCH NEXT FROM record_cursor INTO @RecordOrdinal;
      WHILE @@FETCH_STATUS=0
      BEGIN
        SELECT @ItemID=CONVERT(nvarchar(100),MAX(CASE WHEN TargetFieldCode=N''Product.ItemID'' THEN Value END)),
               @EAN=CONVERT(nvarchar(100),MAX(CASE WHEN TargetFieldCode=N''Product.EAN'' THEN Value END))
        FROM #MappedValue WHERE RecordOrdinal=@RecordOrdinal;

        IF EXISTS
        (
          SELECT 1 FROM map.FieldMapping
          WHERE SourceConnectorId=@SourceConnectorId AND EntityType=@EntityType AND TargetFieldCode=N''Product.ItemID'' AND IsRequired=1 AND IsActive=1
        ) AND @ItemID IS NULL
        BEGIN
          INSERT ops.DeadLetterQueue(Layer,SourceCode,OrganizationId,EntityType,NaturalKey,PayloadJson,FailureReason)
          VALUES(N''raw'',@SourceCode,@OrganizationId,@EntityType,CONVERT(nvarchar(450),@InboxId),NULL,N''Vrstica nima obveznega identifikatorja izdelka.'' );
        END
        ELSE
        BEGIN
          SET @ProductId=(SELECT TOP(1) ProductId FROM canon.Product WHERE OrganizationId=@OrganizationId AND ((@ItemID IS NOT NULL AND ItemID=@ItemID) OR (@ItemID IS NULL AND @EAN IS NOT NULL AND EAN=@EAN)) ORDER BY CASE WHEN ItemID=@ItemID THEN 0 ELSE 1 END);
          IF @ProductId IS NULL AND @ItemID IS NOT NULL
          BEGIN
            INSERT canon.Product(OrganizationId,ItemID,EAN,BusinessHash) VALUES(@OrganizationId,@ItemID,@EAN,CONVERT(char(64),HASHBYTES(''SHA2_256'',CONCAT(@ItemID,N''|'',@EAN)),2));
            SET @ProductId=SCOPE_IDENTITY();
          END;
          IF @ProductId IS NULL
          BEGIN
            INSERT ops.DeadLetterQueue(Layer,SourceCode,OrganizationId,EntityType,NaturalKey,PayloadJson,FailureReason)
            VALUES(N''raw'',@SourceCode,@OrganizationId,@EntityType,COALESCE(@EAN,CONVERT(nvarchar(450),@InboxId)),NULL,N''Izdelek za konfigurirani identifikator ne obstaja.'' );
          END
          ELSE
          BEGIN
            UPDATE product SET
              EAN=COALESCE((SELECT MAX(Value) FROM #MappedValue WHERE RecordOrdinal=@RecordOrdinal AND TargetFieldCode=N''Product.EAN''),product.EAN),
              UoM=COALESCE((SELECT MAX(Value) FROM #MappedValue WHERE RecordOrdinal=@RecordOrdinal AND TargetFieldCode=N''Product.UoM''),product.UoM),
              AccountingGroup=COALESCE((SELECT MAX(Value) FROM #MappedValue WHERE RecordOrdinal=@RecordOrdinal AND TargetFieldCode=N''Product.AccountingGroup''),product.AccountingGroup),
              Supplier=COALESCE((SELECT MAX(Value) FROM #MappedValue WHERE RecordOrdinal=@RecordOrdinal AND TargetFieldCode=N''Product.Supplier''),product.Supplier),
              DiscountGroup=COALESCE((SELECT MAX(Value) FROM #MappedValue WHERE RecordOrdinal=@RecordOrdinal AND TargetFieldCode=N''Product.DiscountGroup''),product.DiscountGroup),
              Manufacturer=COALESCE((SELECT MAX(Value) FROM #MappedValue WHERE RecordOrdinal=@RecordOrdinal AND TargetFieldCode=N''Product.Manufacturer''),product.Manufacturer),
              ValidationStatus=N''PENDING''
            FROM canon.Product product WHERE product.ProductId=@ProductId;

            MERGE canon.ProductText AS target
            USING
            (
              SELECT SUBSTRING(TargetFieldCode,13,LEN(TargetFieldCode)-13-CHARINDEX(N''.'',REVERSE(TargetFieldCode))+1) TextType,
                     RIGHT(TargetFieldCode,CHARINDEX(N''.'',REVERSE(TargetFieldCode))-1) Lang,Value
              FROM #MappedValue WHERE RecordOrdinal=@RecordOrdinal AND TargetFieldCode LIKE N''ProductText.%'' AND Value IS NOT NULL
            ) source ON target.ProductId=@ProductId AND target.TextType=source.TextType AND target.Lang=source.Lang
            WHEN MATCHED THEN UPDATE SET Value=source.Value
            WHEN NOT MATCHED THEN INSERT(ProductId,Lang,TextType,Value) VALUES(@ProductId,source.Lang,source.TextType,source.Value);

            MERGE canon.ProductAttribute AS target
            USING (SELECT SUBSTRING(TargetFieldCode,18,200) AttributeCode,Value FROM #MappedValue WHERE RecordOrdinal=@RecordOrdinal AND TargetFieldCode LIKE N''ProductAttribute.%'' AND Value IS NOT NULL) source
            ON target.ProductId=@ProductId AND target.AttributeCode=source.AttributeCode
            WHEN MATCHED THEN UPDATE SET Value=source.Value
            WHEN NOT MATCHED THEN INSERT(ProductId,AttributeCode,Value) VALUES(@ProductId,source.AttributeCode,source.Value);

            MERGE canon.ProductCategory AS target
            USING (SELECT DISTINCT Value CategoryPath FROM #MappedValue WHERE RecordOrdinal=@RecordOrdinal AND TargetFieldCode=N''ProductCategory.CategoryPath'' AND Value IS NOT NULL) source
            ON target.ProductId=@ProductId AND target.WebSite=N''B2C'' AND target.CategoryPath=source.CategoryPath
            WHEN NOT MATCHED THEN INSERT(ProductId,WebSite,CategoryPath) VALUES(@ProductId,N''B2C'',source.CategoryPath);

            MERGE canon.ProductMedia AS target
            USING (SELECT MAX(Value) Url FROM #MappedValue WHERE RecordOrdinal=@RecordOrdinal AND TargetFieldCode=N''ProductMedia.Url'' AND Value IS NOT NULL) source
            ON target.ProductId=@ProductId AND target.Role=N''PRIMARY'' AND target.SortOrder=1
            WHEN MATCHED AND source.Url IS NOT NULL THEN UPDATE SET Url=source.Url
            WHEN NOT MATCHED AND source.Url IS NOT NULL THEN INSERT(ProductId,Url,Role,SortOrder) VALUES(@ProductId,source.Url,N''PRIMARY'',1);

            MERGE canon.ProductPrice AS target
            USING
            (
              SELECT MAX(CASE WHEN TargetFieldCode=N''ProductPrice.PriceList'' THEN CONVERT(nvarchar(100),Value) END) PriceList,
                     TRY_CONVERT(decimal(19,4),MAX(CASE WHEN TargetFieldCode=N''ProductPrice.Net'' THEN Value END)) Net,
                     TRY_CONVERT(decimal(5,2),MAX(CASE WHEN TargetFieldCode=N''ProductPrice.VatRate'' THEN Value END)) VatRate,
                     COALESCE(TRY_CONVERT(datetime2(3),MAX(CASE WHEN TargetFieldCode=N''ProductPrice.ValidFrom'' THEN Value END)),CONVERT(datetime2(3),''19000101'')) ValidFrom
              FROM #MappedValue WHERE RecordOrdinal=@RecordOrdinal
            ) source ON target.ProductId=@ProductId AND target.PriceList=source.PriceList AND target.ValidFrom=source.ValidFrom
            WHEN MATCHED AND source.PriceList IS NOT NULL AND source.Net IS NOT NULL AND source.VatRate IS NOT NULL THEN UPDATE SET Net=source.Net,VatRate=source.VatRate,IsActive=1
            WHEN NOT MATCHED AND source.PriceList IS NOT NULL AND source.Net IS NOT NULL AND source.VatRate IS NOT NULL THEN INSERT(ProductId,PriceList,Net,VatRate,ValidFrom,IsActive) VALUES(@ProductId,source.PriceList,source.Net,source.VatRate,source.ValidFrom,1);
          END;
        END;
        FETCH NEXT FROM record_cursor INTO @RecordOrdinal;
      END;
      CLOSE record_cursor;
      DEALLOCATE record_cursor;
      UPDATE raw.Inbox SET Status=N''Processed'',ProcessedUtc=SYSUTCDATETIME(),FailureReason=NULL WHERE InboxId=@InboxId;
    END TRY
    BEGIN CATCH
      DECLARE @Reason nvarchar(2000)=ERROR_MESSAGE();
      IF CURSOR_STATUS(''local'',''mapping_cursor'')>=-1 CLOSE mapping_cursor;
      IF CURSOR_STATUS(''local'',''mapping_cursor'')>-3 DEALLOCATE mapping_cursor;
      IF CURSOR_STATUS(''local'',''record_cursor'')>=-1 CLOSE record_cursor;
      IF CURSOR_STATUS(''local'',''record_cursor'')>-3 DEALLOCATE record_cursor;
      UPDATE raw.Inbox SET Status=N''Quarantined'',ProcessedUtc=SYSUTCDATETIME(),FailureReason=@Reason WHERE InboxId=@InboxId;
      EXEC ops.EnqueueDeadLetter @Layer=N''raw'',@SourceCode=@SourceCode,@OrganizationId=@OrganizationId,@EntityType=@EntityType,@NaturalKey=@InboxId,@PayloadJson=NULL,@FailureReason=@Reason;
    END CATCH;
    FETCH NEXT FROM inbox_cursor INTO @InboxId,@EntityType,@Payload,@RecordXPath;
  END;
  CLOSE inbox_cursor;
  DEALLOCATE inbox_cursor;
END;
');
