SET XACT_ABORT ON;

IF COL_LENGTH(N'map.FieldMapping', N'MappingVersion') IS NULL
  ALTER TABLE map.FieldMapping ADD MappingVersion int NOT NULL
    CONSTRAINT DF_FieldMapping_MappingVersion DEFAULT (1);

IF OBJECT_ID(N'map.ExtractedValue', N'U') IS NULL
BEGIN
  CREATE TABLE map.ExtractedValue
  (
    ExtractedValueId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_ExtractedValue PRIMARY KEY,
    InboxId bigint NOT NULL,
    FieldMappingId int NOT NULL,
    MappingVersion int NOT NULL,
    RecordOrdinal int NOT NULL,
    TargetFieldCode nvarchar(200) NOT NULL,
    Value nvarchar(max) NULL,
    ExtractedUtc datetime2(3) NOT NULL CONSTRAINT DF_ExtractedValue_ExtractedUtc DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_ExtractedValue_Trace UNIQUE (InboxId, FieldMappingId, MappingVersion, RecordOrdinal),
    CONSTRAINT FK_ExtractedValue_Inbox FOREIGN KEY (InboxId) REFERENCES raw.Inbox(InboxId),
    CONSTRAINT FK_ExtractedValue_FieldMapping FOREIGN KEY (FieldMappingId) REFERENCES map.FieldMapping(FieldMappingId)
  );
END;

IF OBJECT_ID(N'map.UnmappedValue', N'U') IS NULL
BEGIN
  CREATE TABLE map.UnmappedValue
  (
    UnmappedValueId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_UnmappedValue PRIMARY KEY,
    ExtractedValueId bigint NOT NULL,
    TargetFieldCode nvarchar(200) NOT NULL,
    Value nvarchar(max) NULL,
    Reason nvarchar(500) NOT NULL,
    RecordedUtc datetime2(3) NOT NULL CONSTRAINT DF_UnmappedValue_RecordedUtc DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_UnmappedValue_Extracted UNIQUE (ExtractedValueId),
    CONSTRAINT FK_UnmappedValue_Extracted FOREIGN KEY (ExtractedValueId) REFERENCES map.ExtractedValue(ExtractedValueId)
  );
END;

EXEC(N'
CREATE OR ALTER PROCEDURE map.ProcessRawInbox
  @RunId uniqueidentifier,
  @OrganizationId int,
  @SourceCode nvarchar(100)
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  IF NOT EXISTS
  (
    SELECT 1 FROM map.SourceConnector
    WHERE SourceCode=@SourceCode AND OrganizationId=@OrganizationId AND IsActive=1
  ) THROW 52310,''Aktivni izvorni konektor ne obstaja.'',1;

  INSERT map.UnmappedValue(ExtractedValueId,TargetFieldCode,Value,Reason)
  SELECT value.ExtractedValueId,value.TargetFieldCode,value.Value,N''Ciljna koda v SQL apply ni podprta.''
  FROM map.ExtractedValue value
  INNER JOIN raw.Inbox inbox ON inbox.InboxId=value.InboxId
  WHERE inbox.RunId=@RunId AND inbox.OrganizationId=@OrganizationId AND inbox.SourceCode=@SourceCode
    AND value.TargetFieldCode NOT IN
    (
      N''Product.ItemID'',N''Product.EAN'',N''Product.UoM'',N''Product.AccountingGroup'',
      N''Product.Supplier'',N''Product.DiscountGroup'',N''Product.Manufacturer'',
      N''ProductCategory.CategoryPath'',N''ProductMedia.Url'',
      N''ProductPrice.PriceList'',N''ProductPrice.Net'',N''ProductPrice.VatRate'',N''ProductPrice.ValidFrom''
    )
    AND value.TargetFieldCode NOT LIKE N''ProductText.%''
    AND value.TargetFieldCode NOT LIKE N''ProductAttribute.%''
    AND NOT EXISTS(SELECT 1 FROM map.UnmappedValue queued WHERE queued.ExtractedValueId=value.ExtractedValueId);

  DECLARE @InboxId bigint,@RecordOrdinal int,@ItemID nvarchar(100),@EAN nvarchar(100),@ProductId bigint;
  DECLARE record_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT value.InboxId,value.RecordOrdinal
    FROM map.ExtractedValue value
    INNER JOIN raw.Inbox inbox ON inbox.InboxId=value.InboxId
    WHERE inbox.RunId=@RunId AND inbox.OrganizationId=@OrganizationId AND inbox.SourceCode=@SourceCode
    GROUP BY value.InboxId,value.RecordOrdinal
    ORDER BY value.InboxId,value.RecordOrdinal;
  OPEN record_cursor;
  FETCH NEXT FROM record_cursor INTO @InboxId,@RecordOrdinal;
  WHILE @@FETCH_STATUS=0
  BEGIN
    SELECT
      @ItemID=CONVERT(nvarchar(100),MAX(CASE WHEN TargetFieldCode=N''Product.ItemID'' THEN Value END)),
      @EAN=CONVERT(nvarchar(100),MAX(CASE WHEN TargetFieldCode=N''Product.EAN'' THEN Value END))
    FROM map.ExtractedValue WHERE InboxId=@InboxId AND RecordOrdinal=@RecordOrdinal;

    SET @ProductId=
    (
      SELECT TOP(1) ProductId FROM canon.Product
      WHERE OrganizationId=@OrganizationId
        AND ((@ItemID IS NOT NULL AND ItemID=@ItemID) OR (@EAN IS NOT NULL AND EAN=@EAN))
      ORDER BY CASE WHEN ItemID=@ItemID THEN 0 ELSE 1 END
    );
    IF @ProductId IS NULL AND @ItemID IS NOT NULL
    BEGIN
      INSERT canon.Product(OrganizationId,ItemID,EAN,BusinessHash)
      VALUES(@OrganizationId,@ItemID,@EAN,CONVERT(char(64),HASHBYTES(''SHA2_256'',CONCAT(@ItemID,N''|'',@EAN)),2));
      SET @ProductId=SCOPE_IDENTITY();
    END;

    IF @ProductId IS NOT NULL
    BEGIN
      UPDATE product SET
        EAN=COALESCE((SELECT MAX(Value) FROM map.ExtractedValue WHERE InboxId=@InboxId AND RecordOrdinal=@RecordOrdinal AND TargetFieldCode=N''Product.EAN''),product.EAN),
        UoM=COALESCE((SELECT MAX(Value) FROM map.ExtractedValue WHERE InboxId=@InboxId AND RecordOrdinal=@RecordOrdinal AND TargetFieldCode=N''Product.UoM''),product.UoM),
        AccountingGroup=COALESCE((SELECT MAX(Value) FROM map.ExtractedValue WHERE InboxId=@InboxId AND RecordOrdinal=@RecordOrdinal AND TargetFieldCode=N''Product.AccountingGroup''),product.AccountingGroup),
        Supplier=COALESCE((SELECT MAX(Value) FROM map.ExtractedValue WHERE InboxId=@InboxId AND RecordOrdinal=@RecordOrdinal AND TargetFieldCode=N''Product.Supplier''),product.Supplier),
        DiscountGroup=COALESCE((SELECT MAX(Value) FROM map.ExtractedValue WHERE InboxId=@InboxId AND RecordOrdinal=@RecordOrdinal AND TargetFieldCode=N''Product.DiscountGroup''),product.DiscountGroup),
        Manufacturer=COALESCE((SELECT MAX(Value) FROM map.ExtractedValue WHERE InboxId=@InboxId AND RecordOrdinal=@RecordOrdinal AND TargetFieldCode=N''Product.Manufacturer''),product.Manufacturer),
        ValidationStatus=N''PENDING''
      FROM canon.Product product WHERE product.ProductId=@ProductId;

      MERGE canon.ProductText AS target
      USING
      (
        SELECT SUBSTRING(TargetFieldCode,13,LEN(TargetFieldCode)-13-CHARINDEX(N''.'',REVERSE(TargetFieldCode))+1) TextType,
          RIGHT(TargetFieldCode,CHARINDEX(N''.'',REVERSE(TargetFieldCode))-1) Lang,Value
        FROM map.ExtractedValue
        WHERE InboxId=@InboxId AND RecordOrdinal=@RecordOrdinal AND TargetFieldCode LIKE N''ProductText.%'' AND Value IS NOT NULL
      ) source ON target.ProductId=@ProductId AND target.TextType=source.TextType AND target.Lang=source.Lang
      WHEN MATCHED THEN UPDATE SET Value=source.Value
      WHEN NOT MATCHED THEN INSERT(ProductId,Lang,TextType,Value) VALUES(@ProductId,source.Lang,source.TextType,source.Value);

      MERGE canon.ProductAttribute AS target
      USING
      (
        SELECT SUBSTRING(TargetFieldCode,18,200) AttributeCode,Value FROM map.ExtractedValue
        WHERE InboxId=@InboxId AND RecordOrdinal=@RecordOrdinal AND TargetFieldCode LIKE N''ProductAttribute.%'' AND Value IS NOT NULL
      ) source ON target.ProductId=@ProductId AND target.AttributeCode=source.AttributeCode
      WHEN MATCHED THEN UPDATE SET Value=source.Value
      WHEN NOT MATCHED THEN INSERT(ProductId,AttributeCode,Value) VALUES(@ProductId,source.AttributeCode,source.Value);

      MERGE canon.ProductCategory AS target
      USING
      (
        SELECT DISTINCT Value CategoryPath FROM map.ExtractedValue
        WHERE InboxId=@InboxId AND RecordOrdinal=@RecordOrdinal AND TargetFieldCode=N''ProductCategory.CategoryPath'' AND Value IS NOT NULL
      ) source ON target.ProductId=@ProductId AND target.WebSite=N''B2C'' AND target.CategoryPath=source.CategoryPath
      WHEN NOT MATCHED THEN INSERT(ProductId,WebSite,CategoryPath) VALUES(@ProductId,N''B2C'',source.CategoryPath);

      MERGE canon.ProductMedia AS target
      USING
      (
        SELECT MAX(Value) Url FROM map.ExtractedValue
        WHERE InboxId=@InboxId AND RecordOrdinal=@RecordOrdinal AND TargetFieldCode=N''ProductMedia.Url''
      ) source ON target.ProductId=@ProductId AND target.Role=N''PRIMARY'' AND target.SortOrder=1
      WHEN MATCHED AND source.Url IS NOT NULL THEN UPDATE SET Url=source.Url
      WHEN NOT MATCHED AND source.Url IS NOT NULL THEN INSERT(ProductId,Url,Role,SortOrder) VALUES(@ProductId,source.Url,N''PRIMARY'',1);

      MERGE canon.ProductPrice AS target
      USING
      (
        SELECT
          MAX(CASE WHEN TargetFieldCode=N''ProductPrice.PriceList'' THEN CONVERT(nvarchar(100),Value) END) PriceList,
          TRY_CONVERT(decimal(19,4),MAX(CASE WHEN TargetFieldCode=N''ProductPrice.Net'' THEN Value END)) Net,
          TRY_CONVERT(decimal(5,2),MAX(CASE WHEN TargetFieldCode=N''ProductPrice.VatRate'' THEN Value END)) VatRate,
          COALESCE(TRY_CONVERT(datetime2(3),MAX(CASE WHEN TargetFieldCode=N''ProductPrice.ValidFrom'' THEN Value END)),CONVERT(datetime2(3),''19000101'')) ValidFrom
        FROM map.ExtractedValue WHERE InboxId=@InboxId AND RecordOrdinal=@RecordOrdinal
      ) source ON target.ProductId=@ProductId AND target.PriceList=source.PriceList AND target.ValidFrom=source.ValidFrom
      WHEN MATCHED AND source.PriceList IS NOT NULL AND source.Net IS NOT NULL AND source.VatRate IS NOT NULL
        THEN UPDATE SET Net=source.Net,VatRate=source.VatRate,IsActive=1
      WHEN NOT MATCHED AND source.PriceList IS NOT NULL AND source.Net IS NOT NULL AND source.VatRate IS NOT NULL
        THEN INSERT(ProductId,PriceList,Net,VatRate,ValidFrom,IsActive) VALUES(@ProductId,source.PriceList,source.Net,source.VatRate,source.ValidFrom,1);
    END;
    FETCH NEXT FROM record_cursor INTO @InboxId,@RecordOrdinal;
  END;
  CLOSE record_cursor;
  DEALLOCATE record_cursor;

  UPDATE inbox SET Status=N''Processed'',ProcessedUtc=SYSUTCDATETIME(),FailureReason=NULL
  FROM raw.Inbox inbox
  WHERE inbox.RunId=@RunId AND inbox.OrganizationId=@OrganizationId AND inbox.SourceCode=@SourceCode
    AND inbox.Status=N''Pending''
    AND EXISTS(SELECT 1 FROM map.ExtractedValue value WHERE value.InboxId=inbox.InboxId);
END;
');
