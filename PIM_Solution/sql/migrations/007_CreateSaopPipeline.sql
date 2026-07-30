SET XACT_ABORT ON;

IF OBJECT_ID(N'raw.Inbox', N'U') IS NULL
BEGIN
  CREATE TABLE raw.Inbox
  (
    InboxId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_RawInbox PRIMARY KEY,
    RunId uniqueidentifier NOT NULL,
    OrganizationId int NOT NULL,
    SourceCode nvarchar(100) NOT NULL,
    EntityType nvarchar(100) NOT NULL,
    PageNumber int NOT NULL,
    PayloadXml nvarchar(max) NOT NULL,
    PayloadHash char(64) NOT NULL,
    Status nvarchar(30) NOT NULL CONSTRAINT DF_RawInbox_Status DEFAULT (N'Pending'),
    ReceivedUtc datetime2(3) NOT NULL CONSTRAINT DF_RawInbox_ReceivedUtc DEFAULT SYSUTCDATETIME(),
    ProcessedUtc datetime2(3) NULL,
    FailureReason nvarchar(2000) NULL,
    CONSTRAINT UQ_RawInbox_SourcePageHash UNIQUE (OrganizationId, SourceCode, EntityType, PageNumber, PayloadHash),
    CONSTRAINT CK_RawInbox_Status CHECK (Status IN (N'Pending', N'Processed', N'Quarantined')),
    CONSTRAINT FK_RawInbox_Run FOREIGN KEY (RunId) REFERENCES ops.PipelineRun (RunId),
    CONSTRAINT FK_RawInbox_Organization FOREIGN KEY (OrganizationId) REFERENCES dbo.OrganizationConfig (OrganizationId)
  );
END;

IF OBJECT_ID(N'map.SourceConnector', N'U') IS NULL
BEGIN
  CREATE TABLE map.SourceConnector
  (
    SourceConnectorId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_SourceConnector PRIMARY KEY,
    SourceCode nvarchar(100) NOT NULL,
    OrganizationId int NOT NULL,
    ConnectorType nvarchar(50) NOT NULL,
    IsActive bit NOT NULL CONSTRAINT DF_SourceConnector_IsActive DEFAULT (1),
    CONSTRAINT UQ_SourceConnector UNIQUE (SourceCode, OrganizationId),
    CONSTRAINT FK_SourceConnector_Organization FOREIGN KEY (OrganizationId) REFERENCES dbo.OrganizationConfig (OrganizationId)
  );
END;

IF OBJECT_ID(N'map.FieldMapping', N'U') IS NULL
BEGIN
  CREATE TABLE map.FieldMapping
  (
    FieldMappingId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_FieldMapping PRIMARY KEY,
    SourceConnectorId int NOT NULL,
    EntityType nvarchar(100) NOT NULL,
    SourceElement nvarchar(200) NOT NULL,
    TargetFieldCode nvarchar(200) NOT NULL,
    IsRequired bit NOT NULL CONSTRAINT DF_FieldMapping_IsRequired DEFAULT (0),
    IsActive bit NOT NULL CONSTRAINT DF_FieldMapping_IsActive DEFAULT (1),
    CONSTRAINT UQ_FieldMapping UNIQUE (SourceConnectorId, EntityType, SourceElement, TargetFieldCode),
    CONSTRAINT FK_FieldMapping_Connector FOREIGN KEY (SourceConnectorId) REFERENCES map.SourceConnector (SourceConnectorId)
  );
END;

IF OBJECT_ID(N'map.Watermark', N'U') IS NULL
BEGIN
  CREATE TABLE map.Watermark
  (
    WatermarkId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Watermark PRIMARY KEY,
    SourceConnectorId int NOT NULL,
    EntityType nvarchar(100) NOT NULL,
    WatermarkValue nvarchar(500) NULL,
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_Watermark_UpdatedUtc DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_Watermark UNIQUE (SourceConnectorId, EntityType),
    CONSTRAINT FK_Watermark_Connector FOREIGN KEY (SourceConnectorId) REFERENCES map.SourceConnector (SourceConnectorId)
  );
END;

IF OBJECT_ID(N'map.PipelineStep', N'U') IS NULL
BEGIN
  CREATE TABLE map.PipelineStep
  (
    PipelineStepId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_MapPipelineStep PRIMARY KEY,
    PipelineCode nvarchar(100) NOT NULL,
    StepCode nvarchar(100) NOT NULL,
    ProcedureName nvarchar(256) NOT NULL,
    SortOrder int NOT NULL,
    IsActive bit NOT NULL CONSTRAINT DF_MapPipelineStep_IsActive DEFAULT (1),
    CONSTRAINT UQ_MapPipelineStep_Code UNIQUE (PipelineCode, StepCode),
    CONSTRAINT UQ_MapPipelineStep_Order UNIQUE (PipelineCode, SortOrder)
  );
END;

MERGE map.SourceConnector AS target
USING (VALUES (N'SAOP_IQLIGHTING', 2, N'SAOP', CONVERT(bit, 1))) AS source (SourceCode, OrganizationId, ConnectorType, IsActive)
ON target.SourceCode=source.SourceCode AND target.OrganizationId=source.OrganizationId
WHEN MATCHED THEN UPDATE SET ConnectorType=source.ConnectorType, IsActive=source.IsActive
WHEN NOT MATCHED THEN INSERT (SourceCode, OrganizationId, ConnectorType, IsActive) VALUES (source.SourceCode, source.OrganizationId, source.ConnectorType, source.IsActive);

MERGE map.FieldMapping AS target
USING
(
  SELECT connector.SourceConnectorId, value.EntityType, value.SourceElement, value.TargetFieldCode, value.IsRequired, CONVERT(bit, 1) IsActive
  FROM map.SourceConnector connector
  CROSS APPLY (VALUES
    (N'ItemGeneralData',N'ItemID',N'Product.ItemID',1),
    (N'ItemGeneralData',N'ItemTitle1',N'ProductText.TITLE_ERP.sl',1),
    (N'ItemGeneralData',N'ItemUnitOfMeas',N'Product.UoM',1),
    (N'ItemGeneralData',N'AccountingBookGroupID',N'Product.AccountingGroup',1),
    (N'Prices',N'ItemCode',N'Product.ItemID',1),
    (N'Prices',N'ItemEAN',N'Product.EAN',0),
    (N'Prices',N'Price',N'ProductPrice.Net',1),
    (N'Prices',N'VATRate',N'ProductPrice.VatRate',1),
    (N'Descriptions',N'ItemID',N'Product.ItemID',1),
    (N'Descriptions',N'ItemDescription',N'ProductText.DESCRIPTION.sl',0)
  ) value(EntityType,SourceElement,TargetFieldCode,IsRequired)
  WHERE connector.SourceCode=N'SAOP_IQLIGHTING' AND connector.OrganizationId=2
) source
ON target.SourceConnectorId=source.SourceConnectorId AND target.EntityType=source.EntityType AND target.SourceElement=source.SourceElement AND target.TargetFieldCode=source.TargetFieldCode
WHEN MATCHED THEN UPDATE SET IsRequired=source.IsRequired,IsActive=source.IsActive
WHEN NOT MATCHED THEN INSERT (SourceConnectorId,EntityType,SourceElement,TargetFieldCode,IsRequired,IsActive) VALUES (source.SourceConnectorId,source.EntityType,source.SourceElement,source.TargetFieldCode,source.IsRequired,source.IsActive);

MERGE map.Watermark AS target
USING
(
  SELECT connector.SourceConnectorId, value.EntityType
  FROM map.SourceConnector connector
  CROSS APPLY (VALUES (N'ItemGeneralData'),(N'Prices'),(N'Descriptions'),(N'Currencies'),(N'PriceLists')) value(EntityType)
  WHERE connector.SourceCode=N'SAOP_IQLIGHTING' AND connector.OrganizationId=2
) source
ON target.SourceConnectorId=source.SourceConnectorId AND target.EntityType=source.EntityType
WHEN NOT MATCHED THEN INSERT(SourceConnectorId,EntityType,WatermarkValue) VALUES(source.SourceConnectorId,source.EntityType,NULL);

MERGE map.PipelineStep AS target
USING (VALUES
  (N'SAOP_PRODUCTS',N'MAP_RAW',N'map.ProcessRawInbox',10,CONVERT(bit,1)),
  (N'SAOP_PRODUCTS',N'VALIDATE',N'val.RunValidation',20,CONVERT(bit,1)),
  (N'SAOP_PRODUCTS',N'PROMOTE',N'val.Promote',30,CONVERT(bit,1))
) source(PipelineCode,StepCode,ProcedureName,SortOrder,IsActive)
ON target.PipelineCode=source.PipelineCode AND target.StepCode=source.StepCode
WHEN MATCHED THEN UPDATE SET ProcedureName=source.ProcedureName,SortOrder=source.SortOrder,IsActive=source.IsActive
WHEN NOT MATCHED THEN INSERT(PipelineCode,StepCode,ProcedureName,SortOrder,IsActive) VALUES(source.PipelineCode,source.StepCode,source.ProcedureName,source.SortOrder,source.IsActive);

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
  WHERE RunId=@RunId AND Status=N''Pending'' AND TRY_CONVERT(xml,PayloadXml) IS NULL;

  UPDATE raw.Inbox
  SET Status=N''Quarantined'', ProcessedUtc=SYSUTCDATETIME(), FailureReason=N''Neveljaven XML.''
  WHERE RunId=@RunId AND Status=N''Pending'' AND TRY_CONVERT(xml,PayloadXml) IS NULL;

  DECLARE @InboxId bigint, @EntityType nvarchar(100), @Payload xml;
  DECLARE inbox_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT InboxId,EntityType,TRY_CONVERT(xml,PayloadXml) FROM raw.Inbox
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
                 node.value(''(GeneralData/AccountingBookGroupID/text())[1]'',''nvarchar(100)'') AccountingGroup
          FROM @Payload.nodes(''/*[local-name()="ItemsGeneralData"]/*[local-name()="ItemGeneralData"]'') data(node)
        )
        MERGE canon.Product AS target USING (SELECT * FROM rows WHERE NULLIF(ItemID,N'''') IS NOT NULL) source
        ON target.OrganizationId=@OrganizationId AND target.ItemID=source.ItemID
        WHEN MATCHED THEN UPDATE SET
          UoM=CASE WHEN EXISTS(SELECT 1 FROM map.FieldMapping WHERE SourceConnectorId=@SourceConnectorId AND EntityType=@EntityType AND TargetFieldCode=N''Product.UoM'' AND IsActive=1) THEN source.UoM ELSE target.UoM END,
          AccountingGroup=CASE WHEN EXISTS(SELECT 1 FROM map.FieldMapping WHERE SourceConnectorId=@SourceConnectorId AND EntityType=@EntityType AND TargetFieldCode=N''Product.AccountingGroup'' AND IsActive=1) THEN source.AccountingGroup ELSE target.AccountingGroup END,
          BusinessHash=CONVERT(char(64),HASHBYTES(''SHA2_256'',CONCAT(source.ItemID,N''|'',source.Title,N''|'',source.UoM,N''|'',source.AccountingGroup)),2),ValidationStatus=N''PENDING''
        WHEN NOT MATCHED THEN INSERT(OrganizationId,ItemID,UoM,AccountingGroup,BusinessHash)
          VALUES(@OrganizationId,source.ItemID,
            CASE WHEN EXISTS(SELECT 1 FROM map.FieldMapping WHERE SourceConnectorId=@SourceConnectorId AND EntityType=@EntityType AND TargetFieldCode=N''Product.UoM'' AND IsActive=1) THEN source.UoM END,
            CASE WHEN EXISTS(SELECT 1 FROM map.FieldMapping WHERE SourceConnectorId=@SourceConnectorId AND EntityType=@EntityType AND TargetFieldCode=N''Product.AccountingGroup'' AND IsActive=1) THEN source.AccountingGroup END,
            CONVERT(char(64),HASHBYTES(''SHA2_256'',CONCAT(source.ItemID,N''|'',source.Title,N''|'',source.UoM,N''|'',source.AccountingGroup)),2));

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

EXEC(N'
CREATE OR ALTER PROCEDURE map.RunSaopProducts
  @RunId uniqueidentifier,
  @OrganizationId int=2,
  @SourceCode nvarchar(100)=N''SAOP_IQLIGHTING''
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  BEGIN TRY
    DECLARE @StepCode nvarchar(100),@ProcedureName nvarchar(256);
    DECLARE step_cursor CURSOR LOCAL FAST_FORWARD FOR
      SELECT StepCode,ProcedureName FROM map.PipelineStep
      WHERE PipelineCode=N''SAOP_PRODUCTS'' AND IsActive=1 ORDER BY SortOrder;
    OPEN step_cursor;
    FETCH NEXT FROM step_cursor INTO @StepCode,@ProcedureName;
    WHILE @@FETCH_STATUS=0
    BEGIN
      EXEC ops.RecordPipelineStep @RunId=@RunId,@StepCode=@StepCode,@Status=N''Running'';
      IF @ProcedureName=N''map.ProcessRawInbox'' EXEC map.ProcessRawInbox @RunId,@OrganizationId,@SourceCode;
      ELSE IF @ProcedureName=N''val.RunValidation'' EXEC val.RunValidation @OrganizationId=@OrganizationId;
      ELSE IF @ProcedureName=N''val.Promote'' EXEC val.Promote @OrganizationId=@OrganizationId;
      ELSE THROW 52311,''Registrirani postopek ni dovoljen.'',1;
      EXEC ops.RecordPipelineStep @RunId=@RunId,@StepCode=@StepCode,@Status=N''Succeeded'';
      FETCH NEXT FROM step_cursor INTO @StepCode,@ProcedureName;
    END;
    CLOSE step_cursor;
    DEALLOCATE step_cursor;
    UPDATE ops.PipelineRun SET Status=N''Succeeded'',EndedUtc=SYSUTCDATETIME(),
      RowsRead=(SELECT COUNT(*) FROM raw.Inbox WHERE RunId=@RunId),
      RowsSucceeded=(SELECT COUNT(*) FROM raw.Inbox WHERE RunId=@RunId AND Status=N''Processed''),
      RowsFailed=(SELECT COUNT(*) FROM raw.Inbox WHERE RunId=@RunId AND Status=N''Quarantined'')
    WHERE RunId=@RunId;
  END TRY
  BEGIN CATCH
    UPDATE ops.PipelineRun SET Status=N''Failed'',EndedUtc=SYSUTCDATETIME() WHERE RunId=@RunId;
    THROW;
  END CATCH;
END;
');

EXEC(N'
CREATE OR ALTER PROCEDURE out.ExportProductsCsv
  @OrganizationId int=2,
  @ProfileCode nvarchar(100)=N''WEB_B2C_PRODUCTS''
AS
BEGIN
  SET NOCOUNT ON;
  IF NOT EXISTS(SELECT 1 FROM out.ExportProfile WHERE ProfileCode=@ProfileCode AND IsActive=1)
    THROW 52301,''Izvozni profil ni aktiven.'',1;

  SELECT STRING_AGG(''"''+REPLACE(value.ColumnValue,''"'',''""'')+''"'','','') WITHIN GROUP (ORDER BY value.SortOrder) AS CsvLine
  FROM pim.Product product
  CROSS APPLY
  (
    SELECT columnDefinition.SortOrder,
      COALESCE(CASE columnDefinition.CanonicalFieldCode
        WHEN N''Product.ItemID'' THEN product.ItemID
        WHEN N''Product.EAN'' THEN product.EAN
        WHEN N''Product.Manufacturer'' THEN product.Manufacturer
        WHEN N''ProductText.WEB_TITLE.sl'' THEN product.Name
        WHEN N''ProductCategory.CategoryPath'' THEN (SELECT TOP(1) CategoryPath FROM pim.ProductCategory WHERE PimProductId=product.PimProductId ORDER BY CategoryPath)
        WHEN N''ProductMedia.Url'' THEN (SELECT TOP(1) Url FROM pim.ProductMedia WHERE PimProductId=product.PimProductId ORDER BY SortOrder)
        WHEN N''ProductPrice.Gross'' THEN (SELECT TOP(1) CONVERT(nvarchar(100),Net*(1+VatRate/100)) FROM pim.ProductPrice WHERE PimProductId=product.PimProductId AND IsActive=1 ORDER BY ValidFrom DESC)
        WHEN N''ProductAttribute.CategoryRequired'' THEN (SELECT TOP(1) Value FROM pim.ProductAttribute WHERE PimProductId=product.PimProductId AND AttributeCode=N''CategoryRequired'')
      END,N'''') ColumnValue
    FROM out.ExportColumn columnDefinition
    INNER JOIN out.ExportProfile profile ON profile.ExportProfileId=columnDefinition.ExportProfileId
    WHERE profile.ProfileCode=@ProfileCode AND profile.IsActive=1 AND columnDefinition.IsActive=1
  ) value
  WHERE product.OrganizationId=@OrganizationId
  GROUP BY product.PimProductId
  ORDER BY product.PimProductId;
END;
');
