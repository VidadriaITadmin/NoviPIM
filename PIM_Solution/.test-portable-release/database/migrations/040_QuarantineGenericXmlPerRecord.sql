SET XACT_ABORT ON;

-- Karantena po posameznem zapisu, ne po celotni raw.Inbox datoteki. Prej je en sam
-- neujemajoč ali nepopoln zapis (RecordOrdinal) zavrnil ves paket (glej 017); zdaj se
-- vsak zapis presoja posamično, ujemajoči se obogatijo, neujemajoči se tiho preskočijo
-- (dobaviteljev XML normalno vsebuje izdelke, ki jih ne vodimo — to ni napaka, zato
-- gre samo v števec, ne v ops.DeadLetterQueue in ne v map.UnmappedValue). XML izdelkov
-- nikoli ne ustvarja niti ne podvaja: ujemanje je izključno po (OrganizationId, ItemID)
-- ali (OrganizationId, EAN), oba normalizirana prek NULLIF(LTRIM(RTRIM(...)),N'''') --
-- tudi v update viru, da presledki v surovem EAN ne prepišejo veljavne vrednosti.
-- raw.Inbox po obdelavi vseh zapisov konča kot Processed tudi če je SuccessCount 0
-- (FailureReason nosi povzetek preskočenih); Quarantined ostane samo za sistemske
-- izjeme, ujete v CATCH.
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

  DECLARE @InboxId bigint;
  DECLARE inbox_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT inbox.InboxId
    FROM raw.Inbox inbox
    WHERE inbox.RunId=@RunId AND inbox.OrganizationId=@OrganizationId
      AND inbox.SourceCode=@SourceCode AND inbox.Status=N''Pending''
      AND EXISTS(SELECT 1 FROM map.ExtractedValue value WHERE value.InboxId=inbox.InboxId)
    ORDER BY inbox.InboxId;
  OPEN inbox_cursor;
  FETCH NEXT FROM inbox_cursor INTO @InboxId;
  WHILE @@FETCH_STATUS=0
  BEGIN
    BEGIN TRY
      BEGIN TRANSACTION;

      DECLARE @SuccessCount int=0,@RejectedCount int=0,@LastFailureReason nvarchar(500)=NULL;
      DECLARE @RecordOrdinal int,@ItemID nvarchar(100),@EAN nvarchar(100),@ProductId bigint,@RecordRejectionReason nvarchar(500);
      DECLARE record_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT value.RecordOrdinal
        FROM map.ExtractedValue value
        WHERE value.InboxId=@InboxId
        GROUP BY value.RecordOrdinal
        ORDER BY value.RecordOrdinal;
      OPEN record_cursor;
      FETCH NEXT FROM record_cursor INTO @RecordOrdinal;
      WHILE @@FETCH_STATUS=0
      BEGIN
        SET @RecordRejectionReason=NULL;

        SELECT
          @ItemID=NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(100),MAX(CASE WHEN TargetFieldCode=N''Product.ItemID'' THEN Value END)))),N''''),
          @EAN=NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(100),MAX(CASE WHEN TargetFieldCode=N''Product.EAN'' THEN Value END)))),N'''')
        FROM map.ExtractedValue
        WHERE InboxId=@InboxId AND RecordOrdinal=@RecordOrdinal;

        IF EXISTS
        (
          SELECT 1
          FROM map.ExtractedValue value
          INNER JOIN map.FieldMapping mapping ON mapping.FieldMappingId=value.FieldMappingId
            AND mapping.MappingVersion=value.MappingVersion
          WHERE value.InboxId=@InboxId AND value.RecordOrdinal=@RecordOrdinal
            AND mapping.IsActive=1 AND mapping.IsRequired=1
            AND NULLIF(LTRIM(RTRIM(value.Value)),N'''') IS NULL
        )
          SET @RecordRejectionReason=N''Obvezna preslikana vrednost manjka.'';

        IF @RecordRejectionReason IS NULL
        BEGIN
          SET @ProductId=
          (
            SELECT TOP(1) ProductId FROM canon.Product
            WHERE OrganizationId=@OrganizationId
              AND ((@ItemID IS NOT NULL AND ItemID=@ItemID) OR (@EAN IS NOT NULL AND EAN=@EAN))
            ORDER BY CASE WHEN ItemID=@ItemID THEN 0 ELSE 1 END,ProductId
          );
          IF @ProductId IS NULL
            SET @RecordRejectionReason=N''Izdelek za konfigurirani identifikator ne obstaja.'';
        END;

        IF @RecordRejectionReason IS NULL AND EXISTS
        (
          SELECT 1 FROM map.ExtractedValue value
          WHERE value.InboxId=@InboxId AND value.RecordOrdinal=@RecordOrdinal AND value.Value IS NOT NULL
            AND
            (
              (value.TargetFieldCode=N''ProductPrice.Net''
                AND (TRY_CONVERT(decimal(19,4),value.Value) IS NULL OR TRY_CONVERT(decimal(19,4),value.Value)<0))
              OR (value.TargetFieldCode=N''ProductPrice.VatRate''
                AND (TRY_CONVERT(decimal(5,2),value.Value) IS NULL
                  OR TRY_CONVERT(decimal(5,2),value.Value)<0 OR TRY_CONVERT(decimal(5,2),value.Value)>100))
              OR (value.TargetFieldCode=N''ProductPrice.ValidFrom''
                AND TRY_CONVERT(datetime2(3),value.Value) IS NULL)
            )
        )
          SET @RecordRejectionReason=N''Neveljavna cena, DDV ali datum veljavnosti.'';

        IF @RecordRejectionReason IS NOT NULL
        BEGIN
          SET @LastFailureReason=@RecordRejectionReason;
          SET @RejectedCount=@RejectedCount+1;
        END
        ELSE
        BEGIN
          SET @SuccessCount=@SuccessCount+1;

          UPDATE product SET
            EAN=COALESCE(source.EAN,product.EAN),
            UoM=COALESCE(source.UoM,product.UoM),
            AccountingGroup=COALESCE(source.AccountingGroup,product.AccountingGroup),
            Supplier=COALESCE(source.Supplier,product.Supplier),
            DiscountGroup=COALESCE(source.DiscountGroup,product.DiscountGroup),
            Manufacturer=COALESCE(source.Manufacturer,product.Manufacturer),
            ValidationStatus=N''PENDING''
          FROM canon.Product product
          CROSS APPLY
          (
            SELECT
              NULLIF(LTRIM(RTRIM(MAX(CASE WHEN TargetFieldCode=N''Product.EAN'' THEN Value END))),N'''') EAN,
              MAX(CASE WHEN TargetFieldCode=N''Product.UoM'' THEN Value END) UoM,
              MAX(CASE WHEN TargetFieldCode=N''Product.AccountingGroup'' THEN Value END) AccountingGroup,
              MAX(CASE WHEN TargetFieldCode=N''Product.Supplier'' THEN Value END) Supplier,
              MAX(CASE WHEN TargetFieldCode=N''Product.DiscountGroup'' THEN Value END) DiscountGroup,
              MAX(CASE WHEN TargetFieldCode=N''Product.Manufacturer'' THEN Value END) Manufacturer
            FROM map.ExtractedValue
            WHERE InboxId=@InboxId AND RecordOrdinal=@RecordOrdinal
          ) source
          WHERE product.ProductId=@ProductId;

          MERGE canon.ProductText AS target
          USING
          (
            SELECT parsed.TextType,parsed.Lang,MAX(parsed.Value) Value
            FROM
            (
              SELECT SUBSTRING(TargetFieldCode,13,LEN(TargetFieldCode)-13-CHARINDEX(N''.'',REVERSE(TargetFieldCode))+1) TextType,
                RIGHT(TargetFieldCode,CHARINDEX(N''.'',REVERSE(TargetFieldCode))-1) Lang,Value
              FROM map.ExtractedValue
              WHERE InboxId=@InboxId AND RecordOrdinal=@RecordOrdinal
                AND TargetFieldCode LIKE N''ProductText.%'' AND Value IS NOT NULL
            ) parsed
            GROUP BY parsed.TextType,parsed.Lang
          ) source ON target.ProductId=@ProductId AND target.TextType=source.TextType AND target.Lang=source.Lang
          WHEN MATCHED THEN UPDATE SET Value=source.Value
          WHEN NOT MATCHED THEN INSERT(ProductId,Lang,TextType,Value)
            VALUES(@ProductId,source.Lang,source.TextType,source.Value);

          MERGE canon.ProductAttribute AS target
          USING
          (
            SELECT SUBSTRING(TargetFieldCode,18,200) AttributeCode,MAX(Value) Value
            FROM map.ExtractedValue
            WHERE InboxId=@InboxId AND RecordOrdinal=@RecordOrdinal
              AND TargetFieldCode LIKE N''ProductAttribute.%'' AND Value IS NOT NULL
            GROUP BY SUBSTRING(TargetFieldCode,18,200)
          ) source ON target.ProductId=@ProductId AND target.AttributeCode=source.AttributeCode
          WHEN MATCHED THEN UPDATE SET Value=source.Value
          WHEN NOT MATCHED THEN INSERT(ProductId,AttributeCode,Value)
            VALUES(@ProductId,source.AttributeCode,source.Value);

          MERGE canon.ProductCategory AS target
          USING
          (
            SELECT Value CategoryPath
            FROM map.ExtractedValue
            WHERE InboxId=@InboxId AND RecordOrdinal=@RecordOrdinal
              AND TargetFieldCode=N''ProductCategory.CategoryPath'' AND Value IS NOT NULL
            GROUP BY Value
          ) source ON target.ProductId=@ProductId AND target.WebSite=N''B2C'' AND target.CategoryPath=source.CategoryPath
          WHEN NOT MATCHED THEN INSERT(ProductId,WebSite,CategoryPath)
            VALUES(@ProductId,N''B2C'',source.CategoryPath);

          MERGE canon.ProductMedia AS target
          USING
          (
            SELECT MAX(Value) Url FROM map.ExtractedValue
            WHERE InboxId=@InboxId AND RecordOrdinal=@RecordOrdinal
              AND TargetFieldCode=N''ProductMedia.Url''
          ) source ON target.ProductId=@ProductId AND target.Role=N''PRIMARY'' AND target.SortOrder=1
          WHEN MATCHED AND source.Url IS NOT NULL THEN UPDATE SET Url=source.Url
          WHEN NOT MATCHED AND source.Url IS NOT NULL THEN INSERT(ProductId,Url,Role,SortOrder)
            VALUES(@ProductId,source.Url,N''PRIMARY'',1);

          MERGE canon.ProductPrice AS target
          USING
          (
            SELECT
              MAX(CASE WHEN TargetFieldCode=N''ProductPrice.PriceList'' THEN CONVERT(nvarchar(100),Value) END) PriceList,
              TRY_CONVERT(decimal(19,4),MAX(CASE WHEN TargetFieldCode=N''ProductPrice.Net'' THEN Value END)) Net,
              TRY_CONVERT(decimal(5,2),MAX(CASE WHEN TargetFieldCode=N''ProductPrice.VatRate'' THEN Value END)) VatRate,
              COALESCE(TRY_CONVERT(datetime2(3),MAX(CASE WHEN TargetFieldCode=N''ProductPrice.ValidFrom'' THEN Value END)),CONVERT(datetime2(3),''19000101'')) ValidFrom
            FROM map.ExtractedValue
            WHERE InboxId=@InboxId AND RecordOrdinal=@RecordOrdinal
          ) source ON target.ProductId=@ProductId AND target.PriceList=source.PriceList AND target.ValidFrom=source.ValidFrom
          WHEN MATCHED AND source.PriceList IS NOT NULL AND source.Net IS NOT NULL AND source.VatRate IS NOT NULL
            THEN UPDATE SET Net=source.Net,VatRate=source.VatRate,IsActive=1
          WHEN NOT MATCHED AND source.PriceList IS NOT NULL AND source.Net IS NOT NULL AND source.VatRate IS NOT NULL
            THEN INSERT(ProductId,PriceList,Net,VatRate,ValidFrom,IsActive)
              VALUES(@ProductId,source.PriceList,source.Net,source.VatRate,source.ValidFrom,1);
        END;

        FETCH NEXT FROM record_cursor INTO @RecordOrdinal;
      END;
      CLOSE record_cursor;
      DEALLOCATE record_cursor;

      UPDATE raw.Inbox
      SET Status=N''Processed'',ProcessedUtc=SYSUTCDATETIME(),
        FailureReason=
          CASE
            WHEN @SuccessCount=0 THEN CONVERT(nvarchar(2000),CONCAT(N''Vsi zapisi preskočeni ('',@RejectedCount,N''): '',COALESCE(@LastFailureReason,N''ni podrobnosti.'')))
            WHEN @RejectedCount>0 THEN CONVERT(nvarchar(2000),CONCAT(N''Delno obogateno: '',@SuccessCount,N'' uspeli, '',@RejectedCount,N'' preskočenih. Zadnji razlog: '',@LastFailureReason))
            ELSE NULL
          END
      WHERE InboxId=@InboxId;

      COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
      IF CURSOR_STATUS(''local'',''record_cursor'')>=0 CLOSE record_cursor;
      IF CURSOR_STATUS(''local'',''record_cursor'')>-3 DEALLOCATE record_cursor;
      IF XACT_STATE()<>0 ROLLBACK TRANSACTION;

      DECLARE @FailureReason nvarchar(2000)=LEFT(ERROR_MESSAGE(),2000);
      BEGIN TRANSACTION;
      INSERT map.UnmappedValue(ExtractedValueId,TargetFieldCode,Value,Reason)
      SELECT value.ExtractedValueId,value.TargetFieldCode,value.Value,@FailureReason
      FROM map.ExtractedValue value
      WHERE value.InboxId=@InboxId
        AND NOT EXISTS
        (
          SELECT 1 FROM map.UnmappedValue rejected
          WHERE rejected.ExtractedValueId=value.ExtractedValueId
        );
      UPDATE raw.Inbox
      SET Status=N''Quarantined'',ProcessedUtc=SYSUTCDATETIME(),FailureReason=@FailureReason
      WHERE InboxId=@InboxId;
      COMMIT TRANSACTION;
    END CATCH;

    FETCH NEXT FROM inbox_cursor INTO @InboxId;
  END;
  CLOSE inbox_cursor;
  DEALLOCATE inbox_cursor;
END;
');
