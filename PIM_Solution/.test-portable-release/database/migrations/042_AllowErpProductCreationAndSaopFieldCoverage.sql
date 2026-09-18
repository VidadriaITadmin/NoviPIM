/*
  Trije popravki, vsi idempotentni. Skupni namen: da živ SAOP zajem sploh lahko pripelje
  izdelke v canon.Product, in da pripelje polja, ki jih danes izpušča.

  1) map.SourceConnector.CanCreateProducts

     Do migracije 017 je map.ProcessRawInbox neznan ItemID vstavila v canon.Product.
     017 je to odstranila in vsak neznan zapis zavrne z 'Izdelek za konfigurirani
     identifikator ne obstaja.'. Za dobaviteljski XML je to pravilno — NW ne sme ustvarjati
     artiklov. Za ERP je to zapora: SAOP je vir resnice o tem, kateri artikli obstajajo,
     zato bi ob živem zajemu vseh 200.000 zapisov končalo v map.UnmappedValue.

     Razlika je lastnost vira, ne posameznega zapisa, zato je zapisana na konektorju in ne
     v kodi. Privzeto 0 — obstoječi viri obdržijo dosedanje vedenje, vključno z NW_XML,
     na katerega se opira F5.

  2) Pokritost polj iz SAOP ItemGeneralData

     Preslikanih je bilo 7 polj. Manjkali so ItemEANCode, ItemGroup, ItemDepartment,
     WebPublish in IsActive, čeprav canon.Product zanje že ima stolpce. Posledica v bazi:
     EAN ima 788 od 6.143 izdelkov, ItemGroup nima nobeden. Ker se NW XML na izdelek veže
     prek EAN, brez tega odpade tudi obogatitev iz dobaviteljevega XML.

     Nova polja so IsRequired = 0. ItemEANCode v odgovoru ni pri vseh artiklih; če bi bilo
     obvezno, bi zapis brez njega izpadel v celoti — skupaj z nazivom in identifikatorjem.

  3) Viri za preostala tri podjetja

     map.SourceConnector je imel samo IQLighting. Vidadria, Ediito in DEMO dobijo enako
     konfiguracijo, ker gre za isti API z drugo glavo OrganisationId.

  Kaj ta migracija namenoma NE spremeni: IsRequired obstoječih sedmih preslikav. Med njimi
  sta SalesData/DiscountGroup1ID in GeneralData/AccountingBookGroupID, ki v odgovoru nista
  pri vseh artiklih — zapis brez njiju se zavrne v celoti. To je verjetno preostro, a mere
  na živih podatkih še ni; sprememba brez nje bi bila ugibanje.

  Migrator ne pozna ločil GO, zato so deli, ki se sklicujejo na pravkar dodani stolpec, in
  ustvarjanje procedure zaviti v EXEC(N'...') — enako kot v migraciji 017.
*/

SET XACT_ABORT ON;

/* --- 1) Zastavica na konektorju --------------------------------------- */

IF COL_LENGTH(N'map.SourceConnector', N'CanCreateProducts') IS NULL
  ALTER TABLE map.SourceConnector
    ADD CanCreateProducts bit NOT NULL
      CONSTRAINT DF_SourceConnector_CanCreateProducts DEFAULT(0);

/* ERP viri smejo ustvarjati artikle, dobaviteljski ne. */
EXEC(N'
UPDATE map.SourceConnector
SET CanCreateProducts = 1
WHERE ConnectorType = N''SAOP'' AND CanCreateProducts = 0;
');

/* --- 2) Viri za preostala podjetja ------------------------------------ */

EXEC(N'
MERGE map.SourceConnector AS target
USING (VALUES
  (1, N''SAOP_DEMO'',     N''SAOP''),
  (3, N''SAOP_VIDADRIA'', N''SAOP''),
  (4, N''SAOP_EDIITO'',   N''SAOP'')
) AS source(OrganizationId, SourceCode, ConnectorType)
  ON target.OrganizationId = source.OrganizationId AND target.SourceCode = source.SourceCode
WHEN NOT MATCHED THEN
  INSERT (SourceCode, OrganizationId, ConnectorType, IsActive, CanCreateProducts)
  VALUES (source.SourceCode, source.OrganizationId, source.ConnectorType, 1, 1);
');

/* --- 3) Preslikave ----------------------------------------------------- */

/* Nova polja na vseh SAOP konektorjih. */
MERGE map.FieldMapping AS target
USING
(
  SELECT connector.SourceConnectorId, mapping.EntityType, mapping.SourceElement,
         mapping.TargetFieldCode, mapping.IsRequired
  FROM map.SourceConnector connector
  CROSS JOIN (VALUES
    (N'ItemGeneralData', N'GeneralData/ItemEANCode/text()[1]',    N'Product.EAN',        CONVERT(bit, 0)),
    (N'ItemGeneralData', N'GeneralData/ItemGroup/text()[1]',      N'Product.ItemGroup',  CONVERT(bit, 0)),
    (N'ItemGeneralData', N'GeneralData/ItemDepartment/text()[1]', N'Product.Department', CONVERT(bit, 0)),
    (N'ItemGeneralData', N'GeneralData/WebPublish/text()[1]',     N'Product.WebPublish', CONVERT(bit, 0)),
    (N'ItemGeneralData', N'SalesData/IsActive/text()[1]',         N'Product.IsActive',   CONVERT(bit, 0))
  ) AS mapping(EntityType, SourceElement, TargetFieldCode, IsRequired)
  WHERE connector.ConnectorType = N'SAOP'
) AS source
  ON target.SourceConnectorId = source.SourceConnectorId
  AND target.EntityType = source.EntityType
  AND target.SourceElement = source.SourceElement
WHEN NOT MATCHED THEN
  INSERT (SourceConnectorId, EntityType, SourceElement, TargetFieldCode, IsRequired, IsActive, MappingVersion)
  VALUES (source.SourceConnectorId, source.EntityType, source.SourceElement, source.TargetFieldCode, source.IsRequired, 1, 1);

/*
  Novi SAOP konektorji dobijo enake entitete in polja kot IQLighting. Vzor je obstoječi
  konektor, ne ponovljen seznam — sicer bi se seznama razšla ob prvi naslednji spremembi.
*/
DECLARE @TemplateConnectorId int =
(
  SELECT TOP(1) SourceConnectorId FROM map.SourceConnector
  WHERE SourceCode = N'SAOP_IQLIGHTING' AND OrganizationId = 2
);

IF @TemplateConnectorId IS NOT NULL
BEGIN
  MERGE map.EntityMapping AS target
  USING
  (
    SELECT connector.SourceConnectorId, template.EntityType, template.RecordXPath
    FROM map.SourceConnector connector
    CROSS JOIN
    (
      SELECT EntityType, RecordXPath FROM map.EntityMapping
      WHERE SourceConnectorId = @TemplateConnectorId AND IsActive = 1
    ) template
    WHERE connector.ConnectorType = N'SAOP' AND connector.SourceConnectorId <> @TemplateConnectorId
  ) AS source
    ON target.SourceConnectorId = source.SourceConnectorId AND target.EntityType = source.EntityType
  WHEN NOT MATCHED THEN
    INSERT (SourceConnectorId, EntityType, RecordXPath, IsActive)
    VALUES (source.SourceConnectorId, source.EntityType, source.RecordXPath, 1);

  MERGE map.FieldMapping AS target
  USING
  (
    SELECT connector.SourceConnectorId, template.EntityType, template.SourceElement,
           template.TargetFieldCode, template.IsRequired, template.MappingVersion
    FROM map.SourceConnector connector
    CROSS JOIN
    (
      SELECT EntityType, SourceElement, TargetFieldCode, IsRequired, MappingVersion
      FROM map.FieldMapping
      WHERE SourceConnectorId = @TemplateConnectorId AND IsActive = 1
    ) template
    WHERE connector.ConnectorType = N'SAOP' AND connector.SourceConnectorId <> @TemplateConnectorId
  ) AS source
    ON target.SourceConnectorId = source.SourceConnectorId
    AND target.EntityType = source.EntityType
    AND target.SourceElement = source.SourceElement
  WHEN NOT MATCHED THEN
    INSERT (SourceConnectorId, EntityType, SourceElement, TargetFieldCode, IsRequired, IsActive, MappingVersion)
    VALUES (source.SourceConnectorId, source.EntityType, source.SourceElement,
            source.TargetFieldCode, source.IsRequired, 1, source.MappingVersion);
END;

/* --- 4) map.ProcessRawInbox ------------------------------------------- */

EXEC(N'
CREATE OR ALTER PROCEDURE map.ProcessRawInbox
  @RunId uniqueidentifier,
  @OrganizationId int,
  @SourceCode nvarchar(100)
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  DECLARE @CanCreateProducts bit =
  (
    SELECT TOP(1) CanCreateProducts FROM map.SourceConnector
    WHERE SourceCode=@SourceCode AND OrganizationId=@OrganizationId AND IsActive=1
  );

  IF @CanCreateProducts IS NULL THROW 52310,''Aktivni izvorni konektor ne obstaja.'',1;

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

      DECLARE @SuccessCount int=0,@RejectedCount int=0,@CreatedCount int=0,@LastFailureReason nvarchar(500)=NULL;
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

          /* Novost: ERP vir sme artikel ustvariti; dobaviteljski ga mora najti. */
          IF @ProductId IS NULL AND @CanCreateProducts=1 AND @ItemID IS NOT NULL
          BEGIN
            INSERT canon.Product(OrganizationId,ItemID,EAN,BusinessHash)
            VALUES(@OrganizationId,@ItemID,@EAN,
              CONVERT(char(64),HASHBYTES(''SHA2_256'',CONCAT(@ItemID,N''|'',@EAN)),2));
            SET @ProductId=SCOPE_IDENTITY();
            SET @CreatedCount=@CreatedCount+1;
          END;

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

          /*
            Novost: ItemGroup, Department, WebPublish in IsActive. Zadnja dva sta v ERP
            enocrkovni zastavici (D/N), v canon.Product pa bit, zato ju prevedemo tu —
            preslikava sme povedati, katero polje je vir, ne pa kaksen tip ima cilj.
          */
          UPDATE product SET
            EAN=COALESCE(source.EAN,product.EAN),
            UoM=COALESCE(source.UoM,product.UoM),
            AccountingGroup=COALESCE(source.AccountingGroup,product.AccountingGroup),
            Supplier=COALESCE(source.Supplier,product.Supplier),
            DiscountGroup=COALESCE(source.DiscountGroup,product.DiscountGroup),
            Manufacturer=COALESCE(source.Manufacturer,product.Manufacturer),
            ItemGroup=COALESCE(source.ItemGroup,product.ItemGroup),
            Department=COALESCE(source.Department,product.Department),
            WebPublish=COALESCE(source.WebPublish,product.WebPublish),
            IsActive=COALESCE(source.IsActive,product.IsActive),
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
              MAX(CASE WHEN TargetFieldCode=N''Product.Manufacturer'' THEN Value END) Manufacturer,
              NULLIF(LTRIM(RTRIM(MAX(CASE WHEN TargetFieldCode=N''Product.ItemGroup'' THEN Value END))),N'''') ItemGroup,
              NULLIF(LTRIM(RTRIM(MAX(CASE WHEN TargetFieldCode=N''Product.Department'' THEN Value END))),N'''') Department,
              CASE UPPER(LTRIM(RTRIM(MAX(CASE WHEN TargetFieldCode=N''Product.WebPublish'' THEN Value END))))
                WHEN N''D'' THEN CONVERT(bit,1) WHEN N''Y'' THEN CONVERT(bit,1)
                WHEN N''TRUE'' THEN CONVERT(bit,1) WHEN N''1'' THEN CONVERT(bit,1)
                WHEN N''N'' THEN CONVERT(bit,0) WHEN N''FALSE'' THEN CONVERT(bit,0) WHEN N''0'' THEN CONVERT(bit,0)
                ELSE NULL END WebPublish,
              CASE UPPER(LTRIM(RTRIM(MAX(CASE WHEN TargetFieldCode=N''Product.IsActive'' THEN Value END))))
                WHEN N''D'' THEN CONVERT(bit,1) WHEN N''Y'' THEN CONVERT(bit,1)
                WHEN N''TRUE'' THEN CONVERT(bit,1) WHEN N''1'' THEN CONVERT(bit,1)
                WHEN N''N'' THEN CONVERT(bit,0) WHEN N''FALSE'' THEN CONVERT(bit,0) WHEN N''0'' THEN CONVERT(bit,0)
                ELSE NULL END IsActive
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
            WHEN @SuccessCount=0 THEN CONVERT(nvarchar(2000),CONCAT(N''Vsi zapisi preskoceni ('',@RejectedCount,N''): '',COALESCE(@LastFailureReason,N''ni podrobnosti.'')))
            WHEN @RejectedCount>0 THEN CONVERT(nvarchar(2000),CONCAT(N''Delno obogateno: '',@SuccessCount,N'' uspeli, '',@RejectedCount,N'' preskocenih. Novih artiklov: '',@CreatedCount,N''. Zadnji razlog: '',@LastFailureReason))
            WHEN @CreatedCount>0 THEN CONVERT(nvarchar(2000),CONCAT(N''Obdelano; novih artiklov: '',@CreatedCount,N''.''))
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
