SET XACT_ABORT ON;

EXEC(N'
CREATE OR ALTER FUNCTION map.StripXmlDeclaration(@Payload nvarchar(max))
RETURNS nvarchar(max)
AS
BEGIN
  DECLARE @Trimmed nvarchar(max) = LTRIM(@Payload);
  IF LEFT(@Trimmed, 5) = N''<?xml'' AND CHARINDEX(N''?>'', @Trimmed) > 0
    RETURN LTRIM(STUFF(@Trimmed, 1, CHARINDEX(N''?>'', @Trimmed) + 1, N''''));
  RETURN @Payload;
END;
');

MERGE map.FieldMapping AS target
USING
(
  SELECT connector.SourceConnectorId, value.EntityType, value.SourceElement, value.TargetFieldCode, value.IsRequired, CONVERT(bit, 1) IsActive
  FROM map.SourceConnector connector
  CROSS APPLY (VALUES
    (N'ItemGeneralData',N'SupplierID',N'Product.Supplier',1),
    (N'ItemGeneralData',N'DiscountGroup1ID',N'Product.DiscountGroup',1),
    (N'ItemGeneralData',N'ManufacturerID',N'Product.Manufacturer',1)
  ) value(EntityType,SourceElement,TargetFieldCode,IsRequired)
  WHERE connector.SourceCode=N'SAOP_IQLIGHTING' AND connector.OrganizationId=2
) source
ON target.SourceConnectorId=source.SourceConnectorId AND target.EntityType=source.EntityType AND target.SourceElement=source.SourceElement AND target.TargetFieldCode=source.TargetFieldCode
WHEN MATCHED THEN UPDATE SET IsRequired=source.IsRequired,IsActive=source.IsActive
WHEN NOT MATCHED THEN INSERT (SourceConnectorId,EntityType,SourceElement,TargetFieldCode,IsRequired,IsActive) VALUES (source.SourceConnectorId,source.EntityType,source.SourceElement,source.TargetFieldCode,source.IsRequired,source.IsActive);

EXEC(N'
CREATE OR ALTER PROCEDURE map.ProcessRawInbox
  @RunId uniqueidentifier,
  @OrganizationId int,
  @SourceCode nvarchar(100)
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  DECLARE @SourceConnectorId int=
  (
    SELECT SourceConnectorId FROM map.SourceConnector
    WHERE SourceCode=@SourceCode AND OrganizationId=@OrganizationId AND IsActive=1
  );
  IF @SourceConnectorId IS NULL THROW 52310,''Aktivni izvorni konektor ne obstaja.'',1;

  INSERT ops.DeadLetterQueue(Layer,SourceCode,OrganizationId,EntityType,NaturalKey,PayloadJson,FailureReason)
  SELECT N''raw'', SourceCode, OrganizationId, EntityType, CONVERT(nvarchar(450),InboxId), PayloadXml, N''Neveljaven XML.''
  FROM raw.Inbox
  WHERE RunId=@RunId AND Status=N''Pending'' AND TRY_CONVERT(xml,map.StripXmlDeclaration(PayloadXml)) IS NULL;

  UPDATE raw.Inbox
  SET Status=N''Quarantined'', ProcessedUtc=SYSUTCDATETIME(), FailureReason=N''Neveljaven XML.''
  WHERE RunId=@RunId AND Status=N''Pending'' AND TRY_CONVERT(xml,map.StripXmlDeclaration(PayloadXml)) IS NULL;

  DECLARE @InboxId bigint, @EntityType nvarchar(100), @Payload xml;
  DECLARE inbox_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT InboxId,EntityType,TRY_CONVERT(xml,map.StripXmlDeclaration(PayloadXml)) FROM raw.Inbox
    WHERE RunId=@RunId AND OrganizationId=@OrganizationId AND SourceCode=@SourceCode AND Status=N''Pending'';
  OPEN inbox_cursor;
  FETCH NEXT FROM inbox_cursor INTO @InboxId,@EntityType,@Payload;
  WHILE @@FETCH_STATUS=0
  BEGIN
    BEGIN TRY
      IF @EntityType=N''ItemGeneralData''
      BEGIN
        INSERT ops.DeadLetterQueue(Layer,SourceCode,OrganizationId,EntityType,NaturalKey,PayloadJson,FailureReason)
        SELECT N''raw'',@SourceCode,@OrganizationId,@EntityType,CONVERT(nvarchar(450),@InboxId),
               node.query(''.'').value(''.'',''nvarchar(max)''),N''Vrstica nima obveznega ItemID.''
        FROM @Payload.nodes(''/*[local-name()="ItemsGeneralData"]/*[local-name()="ItemGeneralData"]'') data(node)
        WHERE EXISTS
        (
          SELECT 1 FROM map.FieldMapping
          WHERE SourceConnectorId=@SourceConnectorId AND EntityType=@EntityType
            AND SourceElement=N''ItemID'' AND IsRequired=1 AND IsActive=1
        )
          AND NULLIF(node.value(''(ItemID/text())[1]'',''nvarchar(100)''),N'''') IS NULL;

        ;WITH rows AS
        (
          SELECT node.value(''(ItemID/text())[1]'',''nvarchar(100)'') ItemID,
                 node.value(''(ItemTitle1/text())[1]'',''nvarchar(500)'') Title,
                 node.value(''(GeneralData/ItemUnitOfMeas/text())[1]'',''nvarchar(50)'') UoM,
                 node.value(''(GeneralData/AccountingBookGroupID/text())[1]'',''nvarchar(100)'') AccountingGroup,
                 node.value(''(StockData/SupplierID/text())[1]'',''nvarchar(200)'') Supplier,
                 node.value(''(SalesData/DiscountGroup1ID/text())[1]'',''nvarchar(100)'') DiscountGroup,
                 node.value(''(StockData/ManufacturerID/text())[1]'',''nvarchar(200)'') Manufacturer
          FROM @Payload.nodes(''/*[local-name()="ItemsGeneralData"]/*[local-name()="ItemGeneralData"]'') data(node)
        )
        MERGE canon.Product AS target USING (SELECT * FROM rows WHERE NULLIF(ItemID,N'''') IS NOT NULL) source
        ON target.OrganizationId=@OrganizationId AND target.ItemID=source.ItemID
        WHEN MATCHED THEN UPDATE SET
          UoM=CASE WHEN EXISTS(SELECT 1 FROM map.FieldMapping WHERE SourceConnectorId=@SourceConnectorId AND EntityType=@EntityType AND TargetFieldCode=N''Product.UoM'' AND IsActive=1) THEN source.UoM ELSE target.UoM END,
          AccountingGroup=CASE WHEN EXISTS(SELECT 1 FROM map.FieldMapping WHERE SourceConnectorId=@SourceConnectorId AND EntityType=@EntityType AND TargetFieldCode=N''Product.AccountingGroup'' AND IsActive=1) THEN source.AccountingGroup ELSE target.AccountingGroup END,
          Supplier=CASE WHEN EXISTS(SELECT 1 FROM map.FieldMapping WHERE SourceConnectorId=@SourceConnectorId AND EntityType=@EntityType AND TargetFieldCode=N''Product.Supplier'' AND IsActive=1) THEN source.Supplier ELSE target.Supplier END,
          DiscountGroup=CASE WHEN EXISTS(SELECT 1 FROM map.FieldMapping WHERE SourceConnectorId=@SourceConnectorId AND EntityType=@EntityType AND TargetFieldCode=N''Product.DiscountGroup'' AND IsActive=1) THEN source.DiscountGroup ELSE target.DiscountGroup END,
          Manufacturer=CASE WHEN EXISTS(SELECT 1 FROM map.FieldMapping WHERE SourceConnectorId=@SourceConnectorId AND EntityType=@EntityType AND TargetFieldCode=N''Product.Manufacturer'' AND IsActive=1) THEN source.Manufacturer ELSE target.Manufacturer END,
          BusinessHash=CONVERT(char(64),HASHBYTES(''SHA2_256'',CONCAT(source.ItemID,N''|'',source.Title,N''|'',source.UoM,N''|'',source.AccountingGroup,N''|'',source.Supplier,N''|'',source.DiscountGroup,N''|'',source.Manufacturer)),2),ValidationStatus=N''PENDING''
        WHEN NOT MATCHED THEN INSERT(OrganizationId,ItemID,UoM,AccountingGroup,Supplier,DiscountGroup,Manufacturer,BusinessHash)
          VALUES(@OrganizationId,source.ItemID,
            CASE WHEN EXISTS(SELECT 1 FROM map.FieldMapping WHERE SourceConnectorId=@SourceConnectorId AND EntityType=@EntityType AND TargetFieldCode=N''Product.UoM'' AND IsActive=1) THEN source.UoM END,
            CASE WHEN EXISTS(SELECT 1 FROM map.FieldMapping WHERE SourceConnectorId=@SourceConnectorId AND EntityType=@EntityType AND TargetFieldCode=N''Product.AccountingGroup'' AND IsActive=1) THEN source.AccountingGroup END,
            CASE WHEN EXISTS(SELECT 1 FROM map.FieldMapping WHERE SourceConnectorId=@SourceConnectorId AND EntityType=@EntityType AND TargetFieldCode=N''Product.Supplier'' AND IsActive=1) THEN source.Supplier END,
            CASE WHEN EXISTS(SELECT 1 FROM map.FieldMapping WHERE SourceConnectorId=@SourceConnectorId AND EntityType=@EntityType AND TargetFieldCode=N''Product.DiscountGroup'' AND IsActive=1) THEN source.DiscountGroup END,
            CASE WHEN EXISTS(SELECT 1 FROM map.FieldMapping WHERE SourceConnectorId=@SourceConnectorId AND EntityType=@EntityType AND TargetFieldCode=N''Product.Manufacturer'' AND IsActive=1) THEN source.Manufacturer END,
            CONVERT(char(64),HASHBYTES(''SHA2_256'',CONCAT(source.ItemID,N''|'',source.Title,N''|'',source.UoM,N''|'',source.AccountingGroup,N''|'',source.Supplier,N''|'',source.DiscountGroup,N''|'',source.Manufacturer)),2));

        MERGE canon.ProductText AS target
        USING
        (
          SELECT product.ProductId,node.value(''(ItemTitle1/text())[1]'',''nvarchar(500)'') Value
          FROM @Payload.nodes(''/*[local-name()="ItemsGeneralData"]/*[local-name()="ItemGeneralData"]'') data(node)
          INNER JOIN canon.Product product ON product.OrganizationId=@OrganizationId AND product.ItemID=node.value(''(ItemID/text())[1]'',''nvarchar(100)'')
          WHERE NULLIF(node.value(''(ItemTitle1/text())[1]'',''nvarchar(500)''),N'''') IS NOT NULL
            AND EXISTS(SELECT 1 FROM map.FieldMapping WHERE SourceConnectorId=@SourceConnectorId AND EntityType=@EntityType AND TargetFieldCode=N''ProductText.TITLE_ERP.sl'' AND IsActive=1)
        ) source ON target.ProductId=source.ProductId AND target.Lang=N''sl'' AND target.TextType=N''TITLE_ERP''
        WHEN MATCHED THEN UPDATE SET Value=source.Value
        WHEN NOT MATCHED THEN INSERT(ProductId,Lang,TextType,Value) VALUES(source.ProductId,N''sl'',N''TITLE_ERP'',source.Value);
      END;

      IF @EntityType=N''Prices''
      BEGIN
        INSERT ops.DeadLetterQueue(Layer,SourceCode,OrganizationId,EntityType,NaturalKey,PayloadJson,FailureReason)
        SELECT N''raw'',@SourceCode,@OrganizationId,@EntityType,CONVERT(nvarchar(450),@InboxId),
               node.query(''.'').value(''.'',''nvarchar(max)''),N''Vrstica cene je neveljavna.''
        FROM @Payload.nodes(''/*[local-name()="ArrayOfPrice"]/*[local-name()="Price"]'') data(node)
        WHERE NULLIF(node.value(''(ItemCode/text())[1]'',''nvarchar(100)''),N'''') IS NULL
           OR TRY_CONVERT(decimal(19,4),node.value(''(Price/text())[1]'',''nvarchar(100)'')) IS NULL
           OR TRY_CONVERT(decimal(5,2),node.value(''(VATRate/text())[1]'',''nvarchar(100)'')) IS NULL;

        MERGE canon.Product AS target
        USING
        (
          SELECT DISTINCT ItemID, EAN
          FROM
          (
            SELECT node.value(''(ItemCode/text())[1]'',''nvarchar(100)'') ItemID,
                   NULLIF(node.value(''(ItemEAN/text())[1]'',''nvarchar(100)''),N'''') EAN
            FROM @Payload.nodes(''/*[local-name()="ArrayOfPrice"]/*[local-name()="Price"]'') data(node)
          ) priceItem
        ) source ON target.OrganizationId=@OrganizationId AND target.ItemID=source.ItemID
        WHEN MATCHED THEN UPDATE SET EAN=COALESCE(source.EAN,target.EAN)
        WHEN NOT MATCHED THEN INSERT(OrganizationId,ItemID,EAN) VALUES(@OrganizationId,source.ItemID,source.EAN);

        MERGE canon.ProductPrice AS target
        USING
        (
          SELECT product.ProductId,node.value(''(PriceListId/text())[1]'',''nvarchar(100)'') PriceList,
                 TRY_CONVERT(decimal(19,4),node.value(''(Price/text())[1]'',''nvarchar(100)'')) Net,
                 TRY_CONVERT(decimal(5,2),node.value(''(VATRate/text())[1]'',''nvarchar(100)'')) VatRate,
                 COALESCE(TRY_CONVERT(datetime2(3),node.value(''(PriceValidityFrom/text())[1]'',''nvarchar(100)'')),CONVERT(datetime2(3),''19000101'')) ValidFrom
          FROM @Payload.nodes(''/*[local-name()="ArrayOfPrice"]/*[local-name()="Price"]'') data(node)
          INNER JOIN canon.Product product ON product.OrganizationId=@OrganizationId AND product.ItemID=node.value(''(ItemCode/text())[1]'',''nvarchar(100)'')
        ) source ON target.ProductId=source.ProductId AND target.PriceList=source.PriceList AND target.ValidFrom=source.ValidFrom
        WHEN MATCHED THEN UPDATE SET Net=source.Net,VatRate=source.VatRate,IsActive=1
        WHEN NOT MATCHED AND source.Net IS NOT NULL AND source.VatRate IS NOT NULL THEN INSERT(ProductId,PriceList,Net,VatRate,ValidFrom,IsActive) VALUES(source.ProductId,source.PriceList,source.Net,source.VatRate,source.ValidFrom,1);
      END;

      IF @EntityType=N''Descriptions''
      BEGIN
        MERGE canon.ProductText AS target
        USING
        (
          SELECT product.ProductId,descriptionNode.value(''(ItemDescription/text())[1]'',''nvarchar(max)'') Value
          FROM @Payload.nodes(''/*[local-name()="ItemsDescriptions"]/*[local-name()="itemDescriptions"]'') item(itemNode)
          CROSS APPLY itemNode.nodes(''Descriptions/Description'') descriptions(descriptionNode)
          INNER JOIN canon.Product product ON product.OrganizationId=@OrganizationId AND product.ItemID=itemNode.value(''(ItemID/text())[1]'',''nvarchar(100)'')
        ) source ON target.ProductId=source.ProductId AND target.Lang=N''sl'' AND target.TextType=N''DESCRIPTION''
        WHEN MATCHED THEN UPDATE SET Value=source.Value
        WHEN NOT MATCHED THEN INSERT(ProductId,Lang,TextType,Value) VALUES(source.ProductId,N''sl'',N''DESCRIPTION'',source.Value);
      END;

      UPDATE raw.Inbox SET Status=N''Processed'',ProcessedUtc=SYSUTCDATETIME(),FailureReason=NULL WHERE InboxId=@InboxId;
    END TRY
    BEGIN CATCH
      DECLARE @Reason nvarchar(2000)=ERROR_MESSAGE();
      UPDATE raw.Inbox SET Status=N''Quarantined'',ProcessedUtc=SYSUTCDATETIME(),FailureReason=@Reason WHERE InboxId=@InboxId;
      EXEC ops.EnqueueDeadLetter @Layer=N''raw'',@SourceCode=@SourceCode,@OrganizationId=@OrganizationId,@EntityType=@EntityType,@NaturalKey=@InboxId,@PayloadJson=NULL,@FailureReason=@Reason;
    END CATCH;
    FETCH NEXT FROM inbox_cursor INTO @InboxId,@EntityType,@Payload;
  END;
  CLOSE inbox_cursor;
  DEALLOCATE inbox_cursor;
END;
');
