/*
  317_SPosebniMnozicnoInRazveljavitev — naloga #33 (razvijalec #33, 2026-09-30).

  Posebni S (tip stranke / stranka) za vec izdelkov naenkrat s seznama /izdelki.
  Prej je stran za vsak izdelek posebej klicala b2b.SavePackagingDiscountRule ali
  b2b.RemovePackagingDiscountRule (274): pri celem pogledu do ~90.000 klicev, brez skupne sledi
  in brez poti nazaj.

  Kaj naredi:
    1. b2b.PackagingDiscountRuleBatch - en paket = en mnozicni zapis v enem podjetju za en cilj
       (tip ali stranka): kdo, kdaj, koda (NULL = umik), stevilo sprememb, razveljavitev.
    2. b2b.PackagingDiscountRuleBatchItem - vrstica na spremenjen izdelek: stanje pravila prej in
       potem (RuleId, koda, veljavnost) - iz tega razveljavitev vrne prejsnje stanje.
    3. b2b.SavePackagingDiscountRulesBulk - JSON sifer, ena transakcija, en paket; vsak spremenjen
       zapis gre tudi v b2b.AuditLog (EntityType PackagingDiscountRule, prej/potem; v NewValueJson
       je $.PackagingBatchId = stevilka paketa). Izdelki brez pim.Product (niso promovirani) se
       preskocijo z razlogom, zapis se ne ustavi. Enako vedenje po vrstici kot 274:
       nova koda -> pravilo ITEM se ustvari ali posodobi (veljavnost od/do se pobrise);
       prazna koda -> aktivno pravilo ITEM za ta cilj se umakne (IsActive = 0).
    4. b2b.UndoPackagingDiscountRuleBatch - vrne paket: prej ni bilo pravila -> umik; prej druga
       koda -> stara koda in veljavnost nazaj; prej umaknjeno -> pravilo spet aktivno. Vrstica, ki
       jo je kdo medtem spet spremenil, se ne povozi (vrne se kot preskocena z razlogom).
    5. intranet.GetPackagingDiscountRuleBatches - zadnji paketi (seznam na /izdelki za razveljavitev).

  Nic ne gre v SAOP. Posebni S gre v katalog.csv (stolpca COL037 / COL037B) ob naslednjem izvozu.
  Rocni korak: ne. Idempotentna (tabele IF NULL, procedure CREATE OR ALTER).
*/

SET XACT_ABORT ON;
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;

IF OBJECT_ID(N'b2b.PackagingDiscountRuleBatch', N'U') IS NULL
BEGIN
  CREATE TABLE b2b.PackagingDiscountRuleBatch
  (
    BatchId bigint IDENTITY(1, 1) NOT NULL CONSTRAINT PK_PackagingDiscountRuleBatch PRIMARY KEY,
    OrganizationId int NOT NULL,
    TargetKind nvarchar(10) NOT NULL,
    CustomerTypeCode nvarchar(60) NULL,
    CustomerId bigint NULL,
    DiscountCode nvarchar(10) NULL,
    RequestedCount int NOT NULL,
    ChangedCount int NOT NULL,
    UnchangedCount int NOT NULL,
    SkippedCount int NOT NULL,
    ChangeSource nvarchar(40) NOT NULL,
    Note nvarchar(400) NULL,
    CreatedUtc datetime2(3) NOT NULL CONSTRAINT DF_PackagingDiscountRuleBatch_Created DEFAULT SYSUTCDATETIME(),
    CreatedBy nvarchar(200) NOT NULL,
    UndoneUtc datetime2(3) NULL,
    UndoneBy nvarchar(200) NULL,
    UndoneCount int NULL,
    CONSTRAINT FK_PackagingDiscountRuleBatch_Organization FOREIGN KEY (OrganizationId) REFERENCES dbo.OrganizationConfig (OrganizationId),
    CONSTRAINT CK_PackagingDiscountRuleBatch_Target CHECK
      ((TargetKind = N'TYPE' AND CustomerTypeCode IS NOT NULL AND CustomerId IS NULL)
    OR (TargetKind = N'CUSTOMER' AND CustomerId IS NOT NULL AND CustomerTypeCode IS NULL))
  );
  CREATE INDEX IX_PackagingDiscountRuleBatch_Created ON b2b.PackagingDiscountRuleBatch (CreatedBy, CreatedUtc DESC);
END;

IF OBJECT_ID(N'b2b.PackagingDiscountRuleBatchItem', N'U') IS NULL
BEGIN
  CREATE TABLE b2b.PackagingDiscountRuleBatchItem
  (
    BatchId bigint NOT NULL,
    PimProductId bigint NOT NULL,
    ItemID nvarchar(100) NOT NULL,
    ActionCode nvarchar(12) NOT NULL,
    RuleId bigint NOT NULL,
    OldDiscountCode nvarchar(10) NULL,
    OldValidFrom date NULL,
    OldValidTo date NULL,
    NewDiscountCode nvarchar(10) NULL,
    CONSTRAINT PK_PackagingDiscountRuleBatchItem PRIMARY KEY (BatchId, PimProductId),
    CONSTRAINT FK_PackagingDiscountRuleBatchItem_Batch FOREIGN KEY (BatchId) REFERENCES b2b.PackagingDiscountRuleBatch (BatchId),
    CONSTRAINT CK_PackagingDiscountRuleBatchItem_Action CHECK (ActionCode IN (N'INSERT', N'UPDATE', N'DEACTIVATE'))
  );
END;
GO

/* --- mnozicni zapis posebnega S za en cilj ------------------------------------------------------ */

CREATE OR ALTER PROCEDURE b2b.SavePackagingDiscountRulesBulk
  @OrganizationId int,
  @TargetKind nvarchar(10),
  @CustomerTypeCode nvarchar(60) = NULL,
  @CustomerKey nvarchar(100) = NULL,
  @DiscountCode nvarchar(10) = NULL,
  @ItemsJson nvarchar(max),
  @Actor nvarchar(200),
  @Note nvarchar(400) = NULL,
  @ChangeSource nvarchar(40) = N'INTRANET'
AS
BEGIN
  /* @ItemsJson: ["BA.BC15.00300", "..."]; @DiscountCode NULL ali prazen = umik posebnega S.
     Vrne: 1) BatchId (NULL, ce ni bilo sprememb), ChangedCount, UnchangedCount, SkippedCount;
           2) preskocene vrstice (ItemID, Reason). */
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  SET @TargetKind = UPPER(LTRIM(RTRIM(@TargetKind)));
  SET @CustomerTypeCode = NULLIF(LTRIM(RTRIM(@CustomerTypeCode)), N'');
  SET @CustomerKey = NULLIF(LTRIM(RTRIM(@CustomerKey)), N'');
  SET @DiscountCode = NULLIF(UPPER(LTRIM(RTRIM(@DiscountCode))), N'');

  DECLARE @CustomerId bigint = NULL;
  IF @TargetKind = N'TYPE'
  BEGIN
    SET @CustomerTypeCode = (SELECT CustomerTypeCode FROM pim.CustomerTypeCatalog WHERE CustomerTypeCode = @CustomerTypeCode OR Name = @CustomerTypeCode);
    IF @CustomerTypeCode IS NULL THROW 52742, N'Tipa stranke ni v sifrantu.', 1;
  END
  ELSE IF @TargetKind = N'CUSTOMER'
  BEGIN
    SET @CustomerTypeCode = NULL;
    SET @CustomerId = (SELECT CustomerId FROM b2b.Customer WHERE OrganizationId = @OrganizationId AND CustomerKey = @CustomerKey);
    IF @CustomerId IS NULL THROW 52743, N'Stranke s to sifro ni v tem podjetju.', 1;
  END
  ELSE THROW 52740, N'Cilj pravila mora biti TYPE (tip stranke) ali CUSTOMER (stranka).', 1;

  IF @DiscountCode IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM pim.PackagingDiscountCatalog WHERE DiscountCode = @DiscountCode AND IsActive = 1)
    THROW 52748, N'Neznana ali neaktivna S koda.', 1;

  /* Zacasne tabele z DATABASE_DEFAULT: tempdb ima lahko drugo kolacijo kot baza. */
  CREATE TABLE #Wanted (ItemID nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY);
  INSERT #Wanted (ItemID)
  SELECT DISTINCT LTRIM(RTRIM(parsed.[value]))
  FROM OPENJSON(@ItemsJson) AS parsed
  WHERE NULLIF(LTRIM(RTRIM(parsed.[value])), N'') IS NOT NULL;
  DECLARE @Requested int = @@ROWCOUNT;

  CREATE TABLE #Skipped (ItemID nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY, Reason nvarchar(400) COLLATE DATABASE_DEFAULT NOT NULL);

  /* Posebni S se dodeli samo promoviranemu izdelku (enako kot 274 po vrstici) - v kodi, ker
     vrstica brez pim.Product nima PimProductId. Zapis se zaradi tega ne ustavi. */
  INSERT #Skipped (ItemID, Reason)
  SELECT wanted.ItemID,
    CASE WHEN NOT EXISTS (SELECT 1 FROM canon.Product AS canonProduct WHERE canonProduct.OrganizationId = @OrganizationId AND canonProduct.ItemID = wanted.ItemID)
      THEN N'Artikla ni v tem podjetju.'
      ELSE N'Izdelek se ni promoviran; posebni S se dodeli samo objavljenemu izdelku.' END
  FROM #Wanted AS wanted
  WHERE NOT EXISTS (SELECT 1 FROM pim.Product AS product WHERE product.OrganizationId = @OrganizationId AND product.ItemID = wanted.ItemID);

  CREATE TABLE #Change
  (
    PimProductId bigint NOT NULL PRIMARY KEY,
    ItemID nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL,
    ActionCode nvarchar(12) COLLATE DATABASE_DEFAULT NOT NULL,
    RuleId bigint NULL,
    OldDiscountCode nvarchar(10) COLLATE DATABASE_DEFAULT NULL,
    OldValidFrom date NULL,
    OldValidTo date NULL,
    OldJson nvarchar(max) COLLATE DATABASE_DEFAULT NULL
  );

  BEGIN TRANSACTION;

  /* Trenutno aktivno pravilo ITEM za ta cilj; zaklep, da vzporeden zapis istega cilja pocaka. */
  INSERT #Change (PimProductId, ItemID, ActionCode, RuleId, OldDiscountCode, OldValidFrom, OldValidTo, OldJson)
  SELECT product.PimProductId, product.ItemID,
    CASE WHEN active.RuleId IS NULL THEN N'INSERT' WHEN @DiscountCode IS NULL THEN N'DEACTIVATE' ELSE N'UPDATE' END,
    active.RuleId, active.DiscountCode, active.ValidFrom, active.ValidTo,
    CASE WHEN active.RuleId IS NULL THEN NULL ELSE
      (SELECT oldRule.* FROM b2b.PackagingDiscountRule AS oldRule WHERE oldRule.RuleId = active.RuleId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) END
  FROM #Wanted AS wanted
  INNER JOIN pim.Product AS product ON product.OrganizationId = @OrganizationId AND product.ItemID = wanted.ItemID
  LEFT JOIN b2b.PackagingDiscountRule AS active WITH (UPDLOCK, HOLDLOCK)
    ON active.OrganizationId = @OrganizationId AND active.TargetKind = @TargetKind AND active.ScopeKind = N'ITEM'
    AND active.IsActive = 1 AND active.PimProductId = product.PimProductId
    AND ISNULL(active.CustomerTypeCode, N'') = ISNULL(@CustomerTypeCode, N'') AND ISNULL(active.CustomerId, 0) = ISNULL(@CustomerId, 0)
  WHERE
    /* umik: samo tam, kjer pravilo obstaja */
    (@DiscountCode IS NULL AND active.RuleId IS NOT NULL)
    /* nova koda: kjer pravila ni ali je drugacno (koda ali omejena veljavnost) */
    OR (@DiscountCode IS NOT NULL AND (active.RuleId IS NULL OR active.DiscountCode <> @DiscountCode
        OR active.ValidFrom IS NOT NULL OR active.ValidTo IS NOT NULL))
  OPTION (RECOMPILE);

  DECLARE @Changed int = (SELECT COUNT(*) FROM #Change);
  DECLARE @SkippedCount int = (SELECT COUNT(*) FROM #Skipped);
  DECLARE @BatchId bigint = NULL;

  IF @Changed > 0
  BEGIN
    INSERT b2b.PackagingDiscountRuleBatch
      (OrganizationId, TargetKind, CustomerTypeCode, CustomerId, DiscountCode, RequestedCount, ChangedCount, UnchangedCount,
       SkippedCount, ChangeSource, Note, CreatedBy)
    VALUES
      (@OrganizationId, @TargetKind, @CustomerTypeCode, @CustomerId, @DiscountCode, @Requested, @Changed,
       @Requested - @Changed - @SkippedCount, @SkippedCount, @ChangeSource, @Note, @Actor);
    SET @BatchId = SCOPE_IDENTITY();

    UPDATE target317
    SET IsActive = 0, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = @Actor
    FROM b2b.PackagingDiscountRule AS target317
    INNER JOIN #Change AS change317 ON change317.RuleId = target317.RuleId
    WHERE change317.ActionCode = N'DEACTIVATE'
    OPTION (RECOMPILE);

    UPDATE target317
    SET DiscountCode = @DiscountCode, ValidFrom = NULL, ValidTo = NULL, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = @Actor
    FROM b2b.PackagingDiscountRule AS target317
    INNER JOIN #Change AS change317 ON change317.RuleId = target317.RuleId
    WHERE change317.ActionCode = N'UPDATE'
    OPTION (RECOMPILE);

    INSERT b2b.PackagingDiscountRule
      (OrganizationId, TargetKind, CustomerTypeCode, CustomerId, ScopeKind, PimProductId, DiscountCode, IsActive, Note, CreatedBy, UpdatedBy)
    SELECT @OrganizationId, @TargetKind, @CustomerTypeCode, @CustomerId, N'ITEM', change317.PimProductId, @DiscountCode, 1, @Note, @Actor, @Actor
    FROM #Change AS change317
    WHERE change317.ActionCode = N'INSERT';

    UPDATE change317
    SET RuleId = created.RuleId
    FROM #Change AS change317
    INNER JOIN b2b.PackagingDiscountRule AS created
      ON created.OrganizationId = @OrganizationId AND created.TargetKind = @TargetKind AND created.ScopeKind = N'ITEM'
      AND created.IsActive = 1 AND created.PimProductId = change317.PimProductId
      AND ISNULL(created.CustomerTypeCode, N'') = ISNULL(@CustomerTypeCode, N'') AND ISNULL(created.CustomerId, 0) = ISNULL(@CustomerId, 0)
    WHERE change317.ActionCode = N'INSERT'
    OPTION (RECOMPILE);

    INSERT b2b.PackagingDiscountRuleBatchItem
      (BatchId, PimProductId, ItemID, ActionCode, RuleId, OldDiscountCode, OldValidFrom, OldValidTo, NewDiscountCode)
    SELECT @BatchId, change317.PimProductId, change317.ItemID, change317.ActionCode, change317.RuleId,
      change317.OldDiscountCode, change317.OldValidFrom, change317.OldValidTo, @DiscountCode
    FROM #Change AS change317;

    INSERT b2b.AuditLog (OrganizationId, EntityType, EntityKey, ActionCode, OldValueJson, NewValueJson, ChangedBy)
    SELECT @OrganizationId, N'PackagingDiscountRule', CONVERT(nvarchar(30), change317.RuleId),
      CASE change317.ActionCode WHEN N'UPDATE' THEN N'UPSERT' ELSE change317.ActionCode END,
      change317.OldJson,
      JSON_MODIFY((SELECT newRule.* FROM b2b.PackagingDiscountRule AS newRule WHERE newRule.RuleId = change317.RuleId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
        N'$.PackagingBatchId', @BatchId),
      @Actor
    FROM #Change AS change317;
  END;

  COMMIT;

  SELECT BatchId = @BatchId, ChangedCount = @Changed, UnchangedCount = @Requested - @Changed - @SkippedCount, SkippedCount = @SkippedCount;
  SELECT ItemID, Reason FROM #Skipped ORDER BY ItemID;
END;
GO

/* --- razveljavitev paketa ---------------------------------------------------------------------- */

CREATE OR ALTER PROCEDURE b2b.UndoPackagingDiscountRuleBatch
  @OrganizationId int,
  @BatchId bigint,
  @Actor nvarchar(200)
AS
BEGIN
  /* Vrne: 1) UndoneCount, SkippedCount; 2) preskocene vrstice (ItemID, Reason). */
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  BEGIN TRANSACTION;

  DECLARE @UndoneUtc datetime2(3), @TargetKind nvarchar(10), @CustomerTypeCode nvarchar(60), @CustomerId bigint;
  SELECT @UndoneUtc = UndoneUtc, @TargetKind = TargetKind, @CustomerTypeCode = CustomerTypeCode, @CustomerId = CustomerId
  FROM b2b.PackagingDiscountRuleBatch WITH (UPDLOCK, HOLDLOCK)
  WHERE BatchId = @BatchId AND OrganizationId = @OrganizationId;
  IF @@ROWCOUNT = 0 THROW 52760, N'Paket ne obstaja ali ne pripada temu podjetju.', 1;
  IF @UndoneUtc IS NOT NULL THROW 52761, N'Paket je ze razveljavljen.', 1;

  CREATE TABLE #Undo
  (
    PimProductId bigint NOT NULL PRIMARY KEY,
    ItemID nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL,
    ActionCode nvarchar(12) COLLATE DATABASE_DEFAULT NOT NULL,
    RuleId bigint NOT NULL UNIQUE,
    OldDiscountCode nvarchar(10) COLLATE DATABASE_DEFAULT NULL,
    OldValidFrom date NULL,
    OldValidTo date NULL,
    NewDiscountCode nvarchar(10) COLLATE DATABASE_DEFAULT NULL,
    OldJson nvarchar(max) COLLATE DATABASE_DEFAULT NULL,
    Reason nvarchar(400) COLLATE DATABASE_DEFAULT NULL
  );

  /* Koraki so loceni in z RECOMPILE: tabela pravil je pogosto skoraj prazna (zastarela statistika),
     vgnezden pogoj na vrstico je na 6.000 izdelkih trajal 27 s, loceni koraki pod sekundo. */
  INSERT #Undo (PimProductId, ItemID, ActionCode, RuleId, OldDiscountCode, OldValidFrom, OldValidTo, NewDiscountCode)
  SELECT item.PimProductId, item.ItemID, item.ActionCode, item.RuleId, item.OldDiscountCode, item.OldValidFrom, item.OldValidTo, item.NewDiscountCode
  FROM b2b.PackagingDiscountRuleBatchItem AS item
  WHERE item.BatchId = @BatchId;

  UPDATE undo
  SET OldJson = (SELECT currentRule.* FROM b2b.PackagingDiscountRule AS currentRule WHERE currentRule.RuleId = rule317.RuleId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
    Reason = CASE
      WHEN undo.ActionCode IN (N'INSERT', N'UPDATE')
        AND NOT (rule317.IsActive = 1 AND rule317.DiscountCode = undo.NewDiscountCode AND rule317.ValidFrom IS NULL AND rule317.ValidTo IS NULL)
        THEN N'Posebni S je bil po paketu ze spremenjen; ne povozim.'
      WHEN undo.ActionCode = N'DEACTIVATE' AND rule317.IsActive = 1
        THEN N'Pravilo je ze spet aktivno.'
      ELSE NULL END
  FROM #Undo AS undo
  INNER JOIN b2b.PackagingDiscountRule AS rule317 WITH (UPDLOCK, HOLDLOCK) ON rule317.RuleId = undo.RuleId
  OPTION (RECOMPILE);

  /* umik s paketom: ce je bil medtem za isti izdelek in cilj zapisan nov posebni S, ga ne povozim */
  UPDATE undo
  SET Reason = N'Za ta izdelek je bil po paketu zapisan nov posebni S; ne povozim.'
  FROM #Undo AS undo
  INNER JOIN b2b.PackagingDiscountRule AS other
    ON other.PimProductId = undo.PimProductId AND other.RuleId <> undo.RuleId AND other.IsActive = 1
    AND other.OrganizationId = @OrganizationId AND other.TargetKind = @TargetKind AND other.ScopeKind = N'ITEM'
    AND ISNULL(other.CustomerTypeCode, N'') = ISNULL(@CustomerTypeCode, N'') AND ISNULL(other.CustomerId, 0) = ISNULL(@CustomerId, 0)
  WHERE undo.ActionCode = N'DEACTIVATE' AND undo.Reason IS NULL
  OPTION (RECOMPILE);

  /* prej ni bilo pravila -> umik */
  UPDATE rule317
  SET IsActive = 0, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = @Actor
  FROM b2b.PackagingDiscountRule AS rule317
  INNER JOIN #Undo AS undo ON undo.RuleId = rule317.RuleId
  WHERE undo.Reason IS NULL AND undo.ActionCode = N'INSERT'
  OPTION (RECOMPILE);

  /* prej druga koda -> stara koda in veljavnost nazaj */
  UPDATE rule317
  SET DiscountCode = undo.OldDiscountCode, ValidFrom = undo.OldValidFrom, ValidTo = undo.OldValidTo,
    UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = @Actor
  FROM b2b.PackagingDiscountRule AS rule317
  INNER JOIN #Undo AS undo ON undo.RuleId = rule317.RuleId
  WHERE undo.Reason IS NULL AND undo.ActionCode = N'UPDATE'
  OPTION (RECOMPILE);

  /* prej umaknjeno s paketom -> pravilo spet aktivno */
  UPDATE rule317
  SET IsActive = 1, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = @Actor
  FROM b2b.PackagingDiscountRule AS rule317
  INNER JOIN #Undo AS undo ON undo.RuleId = rule317.RuleId
  WHERE undo.Reason IS NULL AND undo.ActionCode = N'DEACTIVATE'
  OPTION (RECOMPILE);

  DECLARE @Undone int = (SELECT COUNT(*) FROM #Undo WHERE Reason IS NULL);

  INSERT b2b.AuditLog (OrganizationId, EntityType, EntityKey, ActionCode, OldValueJson, NewValueJson, ChangedBy)
  SELECT @OrganizationId, N'PackagingDiscountRule', CONVERT(nvarchar(30), undo.RuleId), N'UNDO', undo.OldJson,
    JSON_MODIFY((SELECT newRule.* FROM b2b.PackagingDiscountRule AS newRule WHERE newRule.RuleId = undo.RuleId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
      N'$.UndoOfPackagingBatchId', @BatchId),
    @Actor
  FROM #Undo AS undo
  WHERE undo.Reason IS NULL;

  UPDATE b2b.PackagingDiscountRuleBatch
  SET UndoneUtc = SYSUTCDATETIME(), UndoneBy = @Actor, UndoneCount = @Undone
  WHERE BatchId = @BatchId;

  COMMIT;

  SELECT UndoneCount = @Undone, SkippedCount = (SELECT COUNT(*) FROM #Undo WHERE Reason IS NOT NULL);
  SELECT ItemID, Reason FROM #Undo WHERE Reason IS NOT NULL ORDER BY ItemID;
END;
GO

/* --- zadnji paketi (seznam na /izdelki) ------------------------------------------------------- */

CREATE OR ALTER PROCEDURE intranet.GetPackagingDiscountRuleBatches
  @CreatedBy nvarchar(200) = NULL,
  @Take int = 10
AS
BEGIN
  SET NOCOUNT ON;
  SELECT TOP (@Take)
    batch.BatchId, batch.OrganizationId, OrganizationName = organization.Name,
    batch.TargetKind, batch.CustomerTypeCode, batch.CustomerId,
    TargetName = CASE WHEN batch.TargetKind = N'TYPE' THEN customerType.Name ELSE customer.Name END,
    TargetCode = CASE WHEN batch.TargetKind = N'TYPE' THEN batch.CustomerTypeCode ELSE customer.CustomerKey END,
    batch.DiscountCode, batch.RequestedCount, batch.ChangedCount, batch.UnchangedCount, batch.SkippedCount,
    batch.CreatedUtc, batch.CreatedBy, batch.UndoneUtc, batch.UndoneBy, batch.UndoneCount
  FROM b2b.PackagingDiscountRuleBatch AS batch
  LEFT JOIN dbo.OrganizationConfig AS organization ON organization.OrganizationId = batch.OrganizationId
  LEFT JOIN pim.CustomerTypeCatalog AS customerType ON customerType.CustomerTypeCode = batch.CustomerTypeCode
  LEFT JOIN b2b.Customer AS customer ON customer.CustomerId = batch.CustomerId
  WHERE @CreatedBy IS NULL OR batch.CreatedBy = @CreatedBy
  ORDER BY batch.BatchId DESC;
END;
GO
