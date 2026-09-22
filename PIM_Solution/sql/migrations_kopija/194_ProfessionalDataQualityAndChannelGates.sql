/*
  194 - profesionalna kakovost podatkov in neobhodne kanalske zapore.

  Tehnicna karantena raw.Inbox ostane namenjena zapisom, ki niso prisli do PIM-a.
  Artikel, ki v PIM-u obstaja, dobi pripravljenost po kanalu in po potrebi rocni zadrzek.
  ERP_L1 je stari profil; nasledniki ERP_L1_SLO / ERP_L1_EU / ERP_L1_THIRD so vir resnice.
*/
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET ARITHABORT ON;
SET NUMERIC_ROUNDABORT OFF;

/* Starega profila ne brisemo fizicno: nanj so vezane revizijske in zgodovinske vrstice. */
DECLARE @RetiredLegacyErp bit=CASE WHEN EXISTS
  (SELECT 1 FROM val.ValidationProfile WHERE ProfileCode=N'ERP_L1' AND IsActive=1) THEN 1 ELSE 0 END;
UPDATE val.ValidationProfile SET IsActive = 0
WHERE ProfileCode = N'ERP_L1' AND IsActive = 1;

UPDATE issue
SET IsActive = 0, ResolvedUtc = COALESCE(ResolvedUtc, SYSUTCDATETIME())
FROM val.ProductIssue AS issue
INNER JOIN val.ValidationProfile AS profile ON profile.ValidationProfileId = issue.ValidationProfileId
WHERE profile.ProfileCode = N'ERP_L1' AND issue.IsActive = 1;

IF OBJECT_ID(N'val.ProductHold', N'U') IS NULL
BEGIN
  CREATE TABLE val.ProductHold
  (
    ProductHoldId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_ProductHold PRIMARY KEY,
    ProductId bigint NOT NULL,
    ChannelCode nvarchar(20) NOT NULL,
    Reason nvarchar(500) NOT NULL,
    IsActive bit NOT NULL CONSTRAINT DF_ProductHold_IsActive DEFAULT 1,
    CreatedUtc datetime2(3) NOT NULL CONSTRAINT DF_ProductHold_CreatedUtc DEFAULT SYSUTCDATETIME(),
    CreatedBy nvarchar(200) NOT NULL,
    ReleasedUtc datetime2(3) NULL,
    ReleasedBy nvarchar(200) NULL,
    CONSTRAINT FK_ProductHold_Product FOREIGN KEY(ProductId) REFERENCES canon.Product(ProductId),
    CONSTRAINT CK_ProductHold_Channel CHECK(ChannelCode IN (N'ALL',N'ERP',N'WEB')),
    CONSTRAINT CK_ProductHold_Reason CHECK(NULLIF(LTRIM(RTRIM(Reason)),N'') IS NOT NULL)
  );
  CREATE UNIQUE INDEX UX_ProductHold_ActiveChannel
    ON val.ProductHold(ProductId,ChannelCode) WHERE IsActive = 1;
  CREATE INDEX IX_ProductHold_ProductActive ON val.ProductHold(ProductId,IsActive)
    INCLUDE(ChannelCode,Reason,CreatedUtc,CreatedBy);
END;

EXEC(N'
CREATE OR ALTER FUNCTION val.IsProductChannelReady
(
  @OrganizationId int, @ItemId nvarchar(450), @ChannelCode nvarchar(20)
)
RETURNS bit
AS
BEGIN
  DECLARE @ProductId bigint, @LastValidatedUtc datetime2(3);
  SELECT @ProductId=ProductId,@LastValidatedUtc=LastValidatedUtc
  FROM canon.Product WHERE OrganizationId=@OrganizationId AND ItemID=@ItemId AND IsActive=1;
  IF @ProductId IS NULL OR @LastValidatedUtc IS NULL
    OR @LastValidatedUtc<DATEADD(hour,-2,SYSUTCDATETIME()) RETURN 0;

  IF EXISTS(SELECT 1 FROM val.ProductHold
            WHERE ProductId=@ProductId AND IsActive=1
              AND (ChannelCode=N''ALL'' OR ChannelCode=@ChannelCode)) RETURN 0;

  IF EXISTS
  (
    SELECT 1 FROM val.ProductIssue AS issue
    INNER JOIN val.FieldRequirement AS requirement ON requirement.FieldRequirementId=issue.FieldRequirementId
    INNER JOIN val.ValidationProfile AS profile ON profile.ValidationProfileId=issue.ValidationProfileId
    WHERE issue.ProductId=@ProductId AND issue.IsActive=1 AND requirement.IsActive=1
      AND requirement.Severity=N''ERROR'' AND profile.IsActive=1
      AND ((@ChannelCode=N''ERP'' AND profile.BlocksErp=1)
        OR (@ChannelCode=N''WEB'' AND profile.BlocksWeb=1))
  ) RETURN 0;
  RETURN 1;
END;');

/* Obstojeci spletni gradnik je velik pogodbeni postopek. Vanj idempotentno dodamo rocni
   zadrzek tik ob izboru spletne strani; tako ga upostevata intranet in B2B worker. */
DECLARE @WebExportDefinition nvarchar(max)=OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows'));
IF @WebExportDefinition IS NOT NULL AND @WebExportDefinition NOT LIKE N'%ProductHold /* 194 */%'
BEGIN
  SET @WebExportDefinition=REPLACE(@WebExportDefinition,N'CREATE OR ALTER PROCEDURE',N'ALTER PROCEDURE');
  SET @WebExportDefinition=REPLACE(@WebExportDefinition,N'CREATE   PROCEDURE',N'ALTER PROCEDURE');
  SET @WebExportDefinition=REPLACE(@WebExportDefinition,N'CREATE PROCEDURE',N'ALTER PROCEDURE');
  SET @WebExportDefinition=REPLACE(@WebExportDefinition,
    N'WHERE product.OrganizationId = @OrganizationId
      AND (@WebSite IS NULL OR category.WebSite = @WebSite)',
    N'WHERE product.OrganizationId = @OrganizationId
      AND NOT EXISTS (SELECT 1 FROM val.ProductHold /* 194 */ AS hold
        WHERE hold.ProductId=canonProduct.ProductId AND hold.IsActive=1 AND hold.ChannelCode IN(N''ALL'',N''WEB''))
      AND (@WebSite IS NULL OR category.WebSite = @WebSite)');
  IF @WebExportDefinition NOT LIKE N'%ProductHold /* 194 */%'
    THROW 51500,N'194: spletne zapore ni bilo mogoce vstaviti v out.GetExportRows.',1;
  EXEC sys.sp_executesql @WebExportDefinition;
END;

EXEC(N'
CREATE OR ALTER VIEW val.ProductChannelReadiness
AS
SELECT product.ProductId,product.OrganizationId,product.ItemID,product.EAN,
  ProductName=COALESCE((SELECT TOP(1) NULLIF(fieldValue.Value,N'''') FROM canon.FieldValue AS fieldValue
    WHERE fieldValue.ProductId=product.ProductId AND fieldValue.FieldCode IN(N''Product.Name'',N''ProductText.TITLE_ERP.sl'')
    ORDER BY CASE fieldValue.FieldCode WHEN N''Product.Name'' THEN 0 ELSE 1 END),product.ItemID),
  product.IsActive,product.WebPublish,product.ValidationStatus,product.Completeness,product.LastValidatedUtc,
  IsValidationStale=CONVERT(bit,CASE WHEN product.LastValidatedUtc IS NULL
    OR product.LastValidatedUtc<DATEADD(hour,-2,SYSUTCDATETIME()) THEN 1 ELSE 0 END),
  ErrorCount=CONVERT(bigint,ISNULL(issueCount.ErrorCount,0)),
  WarningCount=CONVERT(bigint,ISNULL(issueCount.WarningCount,0)),
  ErpBlockingCount=CONVERT(bigint,ISNULL(issueCount.ErpBlockingCount,0)),
  WebBlockingCount=CONVERT(bigint,ISNULL(issueCount.WebBlockingCount,0)),
  HasGlobalHold=CONVERT(bit,ISNULL(holdCount.HasGlobalHold,0)),
  HasErpHold=CONVERT(bit,ISNULL(holdCount.HasErpHold,0)),
  HasWebHold=CONVERT(bit,ISNULL(holdCount.HasWebHold,0)),
  IsErpReady=CONVERT(bit,CASE WHEN product.IsActive=1 AND product.LastValidatedUtc IS NOT NULL
    AND ISNULL(issueCount.ErpBlockingCount,0)=0
    AND ISNULL(holdCount.HasGlobalHold,0)=0 AND ISNULL(holdCount.HasErpHold,0)=0 THEN 1 ELSE 0 END),
  IsWebReady=CONVERT(bit,CASE WHEN product.IsActive=1 AND product.WebPublish=1 AND product.LastValidatedUtc IS NOT NULL
    AND ISNULL(issueCount.WebBlockingCount,0)=0
    AND ISNULL(holdCount.HasGlobalHold,0)=0 AND ISNULL(holdCount.HasWebHold,0)=0 THEN 1 ELSE 0 END)
FROM canon.Product AS product
OUTER APPLY
(
  SELECT ErrorCount=SUM(CASE WHEN requirement.Severity=N''ERROR'' THEN 1 ELSE 0 END),
    WarningCount=SUM(CASE WHEN requirement.Severity=N''WARNING'' THEN 1 ELSE 0 END),
    ErpBlockingCount=SUM(CASE WHEN requirement.Severity=N''ERROR'' AND profile.BlocksErp=1 THEN 1 ELSE 0 END),
    WebBlockingCount=SUM(CASE WHEN requirement.Severity=N''ERROR'' AND profile.BlocksWeb=1 THEN 1 ELSE 0 END)
  FROM val.ProductIssue AS issue
  INNER JOIN val.FieldRequirement AS requirement ON requirement.FieldRequirementId=issue.FieldRequirementId AND requirement.IsActive=1
  INNER JOIN val.ValidationProfile AS profile ON profile.ValidationProfileId=issue.ValidationProfileId AND profile.IsActive=1
  WHERE issue.ProductId=product.ProductId AND issue.IsActive=1
) AS issueCount
OUTER APPLY
(
  SELECT HasGlobalHold=MAX(CASE WHEN ChannelCode=N''ALL'' THEN 1 ELSE 0 END),
    HasErpHold=MAX(CASE WHEN ChannelCode=N''ERP'' THEN 1 ELSE 0 END),
    HasWebHold=MAX(CASE WHEN ChannelCode=N''WEB'' THEN 1 ELSE 0 END)
  FROM val.ProductHold WHERE ProductId=product.ProductId AND IsActive=1
) AS holdCount;');

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetQualityProducts
  @OrganizationId int=NULL,@Search nvarchar(200)=NULL,@State nvarchar(30)=NULL,
  @Skip int=0,@Take int=50
AS
BEGIN
  SET NOCOUNT ON;
  SET @Take=CASE WHEN @Take<1 THEN 50 WHEN @Take>200 THEN 200 ELSE @Take END;
  SET @Skip=CASE WHEN @Skip<0 THEN 0 ELSE @Skip END;
  SET @Search=NULLIF(LTRIM(RTRIM(@Search)),N'''');
  DECLARE @Like nvarchar(204)=CASE WHEN @Search IS NULL THEN NULL ELSE N''%''+@Search+N''%'' END;
  SELECT * INTO #Rows FROM val.ProductChannelReadiness
  WHERE IsActive=1 AND (@OrganizationId IS NULL OR OrganizationId=@OrganizationId)
    AND (@Like IS NULL OR ItemID LIKE @Like OR EAN LIKE @Like OR ProductName LIKE @Like)
    AND (@State IS NULL OR @State=N''''
      OR (@State=N''ERP_BLOCKED'' AND IsErpReady=0)
      OR (@State=N''WEB_BLOCKED'' AND WebPublish=1 AND IsWebReady=0)
      OR (@State=N''READY'' AND IsErpReady=1 AND (WebPublish=0 OR IsWebReady=1))
      OR (@State=N''HOLD'' AND (HasGlobalHold=1 OR HasErpHold=1 OR HasWebHold=1))
      OR (@State=N''STALE'' AND IsValidationStale=1));
  SELECT * FROM #Rows ORDER BY
    CASE WHEN HasGlobalHold=1 OR HasErpHold=1 OR HasWebHold=1 THEN 0
         WHEN IsErpReady=0 OR (WebPublish=1 AND IsWebReady=0) THEN 1 ELSE 2 END,
    ItemID OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY;
  SELECT COUNT_BIG(*) TotalCount,
    SUM(CASE WHEN IsErpReady=1 THEN 1 ELSE 0 END) ErpReadyCount,
    SUM(CASE WHEN IsErpReady=0 THEN 1 ELSE 0 END) ErpBlockedCount,
    SUM(CASE WHEN WebPublish=1 AND IsWebReady=1 THEN 1 ELSE 0 END) WebReadyCount,
    SUM(CASE WHEN WebPublish=1 AND IsWebReady=0 THEN 1 ELSE 0 END) WebBlockedCount,
    SUM(CASE WHEN HasGlobalHold=1 OR HasErpHold=1 OR HasWebHold=1 THEN 1 ELSE 0 END) HoldCount,
    SUM(CASE WHEN IsValidationStale=1 THEN 1 ELSE 0 END) StaleCount
  FROM #Rows;
END;');

EXEC(N'
CREATE OR ALTER PROCEDURE val.SetProductHold
  @ProductId bigint,@ChannelCode nvarchar(20),@Reason nvarchar(500)=NULL,
  @IsActive bit,@Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  SET @ChannelCode=UPPER(NULLIF(LTRIM(RTRIM(@ChannelCode)),N''''));
  SET @Reason=NULLIF(LTRIM(RTRIM(@Reason)),N'''');
  IF @ChannelCode NOT IN(N''ALL'',N''ERP'',N''WEB'') THROW 51494,N''Neznan kanal zadrzka.'',1;
  IF NOT EXISTS(SELECT 1 FROM canon.Product WHERE ProductId=@ProductId) THROW 51495,N''Artikel ne obstaja.'',1;
  IF @IsActive=1 AND @Reason IS NULL THROW 51496,N''Zadrzek potrebuje razlog.'',1;
  IF @IsActive=1
  BEGIN
    IF EXISTS(SELECT 1 FROM val.ProductHold WHERE ProductId=@ProductId AND ChannelCode=@ChannelCode AND IsActive=1)
      UPDATE val.ProductHold SET Reason=@Reason,CreatedUtc=SYSUTCDATETIME(),CreatedBy=@Actor
      WHERE ProductId=@ProductId AND ChannelCode=@ChannelCode AND IsActive=1;
    ELSE INSERT val.ProductHold(ProductId,ChannelCode,Reason,CreatedBy) VALUES(@ProductId,@ChannelCode,@Reason,@Actor);
  END
  ELSE UPDATE val.ProductHold SET IsActive=0,ReleasedUtc=SYSUTCDATETIME(),ReleasedBy=@Actor
    WHERE ProductId=@ProductId AND ChannelCode=@ChannelCode AND IsActive=1;
END;');

/* Zadnja, neobhodna ERP varovalka. Pokrije enqueue, odobritev, retry in oba claim postopka. */
EXEC(N'
CREATE OR ALTER TRIGGER out.TR_OutboxMessage_ErpQualityGate ON out.OutboxMessage
AFTER INSERT,UPDATE AS
BEGIN
  SET NOCOUNT ON;
  IF EXISTS
  (
    SELECT 1 FROM inserted AS message
    INNER JOIN canon.Product AS product
      ON product.OrganizationId=message.OrganizationId AND product.ItemID=message.EntityKey
    WHERE message.TargetKind=N''SAOP_PRODUCT'' AND message.EntityType=N''Product''
      AND message.Status IN(N''PendingApproval'',N''Pending'',N''Retry'',N''Sending'')
      AND val.IsProductChannelReady(message.OrganizationId,message.EntityKey,N''ERP'')=0
  ) THROW 51497,N''Artikel ni pripravljen za ERP. Najprej odpravite blokirajoce napake ali sprostite rocni zadrzek.'',1;
END;');

/* Cel katalog ponovno ovrednotimo samo ob dejanski upokojitvi. Ponovni idempotentni zagon
   migracije ne sme po nepotrebnem sproziti vecminutnega polnega izracuna. */
IF @RetiredLegacyErp=1 EXEC val.RunValidation;

IF EXISTS(SELECT 1 FROM val.ValidationProfile WHERE ProfileCode=N'ERP_L1' AND IsActive=1)
  THROW 51498,N'194: stari ERP_L1 je se aktiven.',1;
IF OBJECT_ID(N'val.ProductChannelReadiness',N'V') IS NULL
  THROW 51499,N'194: manjka bralni model pripravljenosti.',1;
