/*
  288 — Števci hitrih izborov na seznamu izdelkov (intranet.GetProductListSegmentCounts)

  Uporabnik 2026-09-26: prenova v slogu Akeneo, »pametni filtri«. Seznam /izdelki ima vrstico hitrih
  izborov (Vsi / Za dopolniti / Pripravljeni za splet / Niso na spletu / Čakajo SAOP / Brez slike) s
  števci. Števce je doslej štela poizvedba v C# (ProductWorkbenchService.SegmentCountsSql); ta migracija
  jo premakne v proceduro, da je pogoj seznama in števcev na enem mestu v bazi in ga pregled vidi.

  Pogoji so prepisani iz intranet.GetProductList (stanje po 274) brez @View in @WebStatus — ta dva
  izbira prav hitri izbor. Ob spremembi GetProductList popravi tudi to proceduro.

  Samo branje: ne piše v katalog, ne v SAOP. En prehod čez canon.Product v obsegu podjetja, brez
  validacije po vrstici; #WebValid je isti skupinski izračun kot v seznamu (248).

  Ročnega koraka ni. Migrator ne pozna GO, zato CREATE OR ALTER v EXEC(N'...').
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

IF UNICODE(N'č') <> 269 THROW 52880, N'288: datoteka ni prebrana kot UTF-8 (šumniki).', 1;
IF OBJECT_ID(N'intranet.GetProductList', N'P') IS NULL OR OBJECT_ID(N'b2b.PackagingDiscountSpecials') IS NULL
  THROW 52881, N'288 potrebuje intranet.GetProductList in b2b.PackagingDiscountSpecials (274).', 1;

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetProductListSegmentCounts
  @OrganizationId int = NULL,
  @Search nvarchar(200) = NULL,
  @Manufacturer nvarchar(200) = NULL,
  @Supplier nvarchar(200) = NULL,
  @ItemGroup nvarchar(100) = NULL,
  @Department nvarchar(100) = NULL,
  @ErpStatus nvarchar(30) = NULL,
  @Activity nvarchar(20) = NULL,
  @WebPublish nvarchar(20) = NULL,
  @Completeness nvarchar(20) = NULL,
  @HasImage nvarchar(20) = NULL,
  @CategoryTreeCode nvarchar(100) = NULL,
  @CategoryCode nvarchar(200) = NULL,
  @PackagingDiscount nvarchar(20) = NULL,
  @DiscountGroup nvarchar(100) = NULL,
  @SpecialFor nvarchar(120) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  DECLARE @Like nvarchar(210) = CASE WHEN @Search IS NULL THEN NULL ELSE N''%'' + @Search + N''%'' END;

  CREATE TABLE #Scope (OrganizationId int NOT NULL PRIMARY KEY);
  INSERT #Scope (OrganizationId)
  SELECT organizationValue.OrganizationId FROM dbo.OrganizationConfig AS organizationValue
  WHERE (@OrganizationId IS NULL AND organizationValue.IsActive = 1) OR organizationValue.OrganizationId = @OrganizationId;

  DECLARE @ErpProfiles int = (SELECT COUNT(*) FROM val.ValidationProfile WHERE IsActive = 1 AND BlocksErp = 1);
  DECLARE @WebProfiles int = (SELECT COUNT(*) FROM val.ValidationProfile WHERE IsActive = 1 AND BlocksWeb = 1);

  CREATE TABLE #ErpValid (ProductId bigint NOT NULL PRIMARY KEY);
  IF @ErpStatus IS NOT NULL AND @ErpProfiles > 0
    INSERT #ErpValid (ProductId)
    SELECT stateValue.ProductId
    FROM val.ProductValidationState AS stateValue
    INNER JOIN val.ValidationProfile AS profileValue
      ON profileValue.ValidationProfileId = stateValue.ValidationProfileId AND profileValue.IsActive = 1 AND profileValue.BlocksErp = 1
    INNER JOIN canon.Product AS product ON product.ProductId = stateValue.ProductId
    INNER JOIN #Scope AS scope ON scope.OrganizationId = product.OrganizationId
    WHERE stateValue.Status = N''VALID''
    GROUP BY stateValue.ProductId
    HAVING COUNT(*) = @ErpProfiles;
  IF @ErpStatus IS NOT NULL AND @ErpProfiles = 0
    INSERT #ErpValid (ProductId)
    SELECT product.ProductId FROM canon.Product AS product
    INNER JOIN #Scope AS scope ON scope.OrganizationId = product.OrganizationId;

  /* Pripravljen za splet (248): s kljukico spletisca in VALID v vseh profilih, ki zanj blokirajo splet. */
  CREATE TABLE #WebValid (ProductId bigint NOT NULL PRIMARY KEY);
  IF @WebProfiles > 0
    INSERT #WebValid (ProductId)
    SELECT flagged.ProductId
    FROM
    (
      SELECT DISTINCT shop.ProductId
      FROM pim.ProductWebShop AS shop
      INNER JOIN canon.Product AS product ON product.ProductId = shop.ProductId
      INNER JOIN #Scope AS scope ON scope.OrganizationId = product.OrganizationId
      WHERE shop.IsPublished = 1
    ) AS flagged
    WHERE NOT EXISTS
    (
      SELECT 1 FROM val.ValidationProfile AS profileValue
      LEFT JOIN val.ProductValidationState AS stateValue
        ON stateValue.ValidationProfileId = profileValue.ValidationProfileId AND stateValue.ProductId = flagged.ProductId
      WHERE profileValue.IsActive = 1 AND profileValue.BlocksWeb = 1
        AND (profileValue.Scope <> N''WEB'' OR EXISTS (SELECT 1 FROM pim.ProductWebShop AS siteFlag WHERE siteFlag.ProductId = flagged.ProductId AND siteFlag.WebShopCode = profileValue.CategoryTreeCode AND siteFlag.IsPublished = 1))
        AND (stateValue.ProductValidationStateId IS NULL OR stateValue.Status <> N''VALID'')
    );
  ELSE
    INSERT #WebValid (ProductId)
    SELECT product.ProductId FROM canon.Product AS product
    INNER JOIN #Scope AS scope ON scope.OrganizationId = product.OrganizationId;

  CREATE TABLE #CategoryProduct (ProductId bigint NOT NULL PRIMARY KEY);
  IF @CategoryCode IS NOT NULL
  BEGIN
    ;WITH veja AS
    (
      SELECT koren.CategoryTreeCode, koren.CategoryCode
      FROM canon.Category AS koren
      WHERE koren.CategoryCode = @CategoryCode AND (@CategoryTreeCode IS NULL OR koren.CategoryTreeCode = @CategoryTreeCode)
      UNION ALL
      SELECT otrok.CategoryTreeCode, otrok.CategoryCode
      FROM canon.Category AS otrok
      INNER JOIN veja ON veja.CategoryTreeCode = otrok.CategoryTreeCode AND veja.CategoryCode = otrok.ParentCategoryCode
    )
    INSERT #CategoryProduct (ProductId)
    SELECT DISTINCT productCategory.ProductId
    FROM canon.ProductCategory AS productCategory
    INNER JOIN canon.WebSite AS site ON site.WebSiteCode = productCategory.WebSite
    INNER JOIN canon.CategoryPathTranslated AS prevod
      ON prevod.CategoryTreeCode = site.CategoryTreeCode AND prevod.LanguageCode = site.LanguageCode AND prevod.CategoryPath = productCategory.CategoryPath
    INNER JOIN veja ON veja.CategoryTreeCode = prevod.CategoryTreeCode AND veja.CategoryCode = prevod.CategoryCode
    OPTION (MAXRECURSION 20);
  END;

  DECLARE @DiscountFilter bit = CASE WHEN @PackagingDiscount IS NULL AND @DiscountGroup IS NULL AND @SpecialFor IS NULL THEN 0 ELSE 1 END;
  CREATE TABLE #DiscountProduct (ProductId bigint NOT NULL PRIMARY KEY);
  IF @DiscountFilter = 1
  BEGIN
    DECLARE @SpecialKind nvarchar(10) = CASE WHEN UPPER(@SpecialFor) = N''ANY'' THEN N''ANY''
      WHEN @SpecialFor LIKE N''TYPE:%'' THEN N''TYPE'' WHEN @SpecialFor LIKE N''CUSTOMER:%'' THEN N''CUSTOMER'' END;
    DECLARE @SpecialCode nvarchar(120) = CASE WHEN CHARINDEX(N'':'', @SpecialFor) > 0
      THEN LTRIM(RTRIM(SUBSTRING(@SpecialFor, CHARINDEX(N'':'', @SpecialFor) + 1, 120))) END;
    CREATE TABLE #SpecialHit (PimProductId bigint NOT NULL PRIMARY KEY);
    IF @SpecialFor IS NOT NULL
      INSERT #SpecialHit (PimProductId)
      SELECT DISTINCT special.PimProductId
      FROM #Scope AS scope
      CROSS APPLY b2b.PackagingDiscountSpecials(scope.OrganizationId, CONVERT(date, SYSUTCDATETIME())) AS special
      LEFT JOIN b2b.Customer AS customer ON customer.CustomerId = special.CustomerId
      WHERE @SpecialKind = N''ANY''
        OR (@SpecialKind = N''TYPE'' AND special.TargetKind = N''TYPE'' AND special.CustomerTypeCode = @SpecialCode)
        OR (@SpecialKind = N''CUSTOMER'' AND special.TargetKind = N''CUSTOMER'' AND customer.CustomerKey = @SpecialCode)
        OR (@SpecialKind = N''CUSTOMER'' AND special.TargetKind = N''TYPE'' AND special.CustomerTypeCode IN
             (SELECT profile.CustomerTypeCode FROM pim.CustomerWebProfile AS profile
              INNER JOIN b2b.Customer AS member ON member.CustomerId = profile.CustomerId
              WHERE member.OrganizationId = scope.OrganizationId AND member.CustomerKey = @SpecialCode));

    INSERT #DiscountProduct (ProductId)
    SELECT product.ProductId
    FROM canon.Product AS product
    INNER JOIN #Scope AS scope ON scope.OrganizationId = product.OrganizationId
    LEFT JOIN pim.Product AS promoted ON promoted.OrganizationId = product.OrganizationId AND promoted.ItemID = product.ItemID
    LEFT JOIN pim.ProductPackagingDiscount AS packaging ON packaging.PimProductId = promoted.PimProductId
    WHERE (@DiscountGroup IS NULL OR product.DiscountGroup = @DiscountGroup)
      AND (@PackagingDiscount IS NULL
        OR (@PackagingDiscount = N''NONE'' AND packaging.DiscountCode IS NULL)
        OR (@PackagingDiscount = N''ANY'' AND packaging.DiscountCode IS NOT NULL)
        OR packaging.DiscountCode = @PackagingDiscount)
      AND (@SpecialFor IS NULL OR EXISTS (SELECT 1 FROM #SpecialHit AS hit WHERE hit.PimProductId = promoted.PimProductId))
    OPTION (RECOMPILE);
  END;

  ;WITH flags AS
  (
    SELECT
      ToFix = CASE WHEN product.ValidationStatus <> N''VALID'' THEN 1 ELSE 0 END,
      WebReady = CASE WHEN EXISTS (SELECT 1 FROM #WebValid AS webValid WHERE webValid.ProductId = product.ProductId) THEN 1 ELSE 0 END,
      NotPublished = CASE WHEN NOT EXISTS (SELECT 1 FROM pim.Product AS promoted WHERE promoted.OrganizationId = product.OrganizationId AND promoted.ItemID = product.ItemID) THEN 1 ELSE 0 END,
      WaitingSaop = CASE WHEN EXISTS (SELECT 1 FROM out.OutboxMessage AS message WHERE message.OrganizationId = product.OrganizationId AND message.TargetKind = N''SAOP_PRODUCT'' AND message.EntityKey = product.ItemID AND message.Status IN (N''PendingApproval'', N''Pending'', N''Sending'', N''Sent'', N''Error'', N''Retry'', N''Drift'')) THEN 1 ELSE 0 END,
      NoImage = CASE WHEN NOT EXISTS (SELECT 1 FROM canon.ProductMedia AS media WHERE media.ProductId = product.ProductId) THEN 1 ELSE 0 END
    FROM canon.Product AS product
    INNER JOIN #Scope AS scope ON scope.OrganizationId = product.OrganizationId
    WHERE (@Like IS NULL OR product.ItemID LIKE @Like OR product.EAN LIKE @Like)
      AND (@Manufacturer IS NULL OR product.Manufacturer = @Manufacturer)
      AND (@Supplier IS NULL OR product.Supplier = @Supplier)
      AND (@ItemGroup IS NULL OR product.ItemGroup = @ItemGroup)
      AND (@Department IS NULL OR product.Department = @Department)
      AND (@Activity IS NULL OR product.IsActive = CASE WHEN @Activity = N''ACTIVE'' THEN 1 ELSE 0 END)
      AND (@WebPublish IS NULL OR product.WebPublish = CASE WHEN @WebPublish = N''YES'' THEN 1 ELSE 0 END)
      AND
      (
        @HasImage IS NULL
        OR (@HasImage = N''YES'' AND EXISTS (SELECT 1 FROM canon.ProductMedia AS imageValue WHERE imageValue.ProductId = product.ProductId))
        OR (@HasImage = N''NO'' AND NOT EXISTS (SELECT 1 FROM canon.ProductMedia AS imageValue WHERE imageValue.ProductId = product.ProductId))
      )
      AND (@DiscountFilter = 0 OR EXISTS (SELECT 1 FROM #DiscountProduct AS discount WHERE discount.ProductId = product.ProductId))
      AND (@CategoryCode IS NULL OR EXISTS (SELECT 1 FROM #CategoryProduct AS kategorija WHERE kategorija.ProductId = product.ProductId))
      AND
      (
        @Completeness IS NULL
        OR (@Completeness = N''EMPTY'' AND product.Completeness = 0)
        OR (@Completeness = N''LOW'' AND product.Completeness > 0 AND product.Completeness < 50)
        OR (@Completeness = N''MID'' AND product.Completeness >= 50 AND product.Completeness < 100)
        OR (@Completeness = N''FULL'' AND product.Completeness >= 100)
      )
      AND
      (
        @ErpStatus IS NULL
        OR (@ErpStatus = N''VALID'' AND EXISTS (SELECT 1 FROM #ErpValid AS erpValid WHERE erpValid.ProductId = product.ProductId))
        OR (@ErpStatus = N''INVALID'' AND NOT EXISTS (SELECT 1 FROM #ErpValid AS erpValid WHERE erpValid.ProductId = product.ProductId))
      )
  )
  SELECT
    AllCount = COUNT_BIG(*),
    ToFixCount = ISNULL(SUM(CONVERT(bigint, ToFix)), 0),
    WebReadyCount = ISNULL(SUM(CONVERT(bigint, WebReady)), 0),
    NotPublishedCount = ISNULL(SUM(CONVERT(bigint, NotPublished)), 0),
    WaitingSaopCount = ISNULL(SUM(CONVERT(bigint, WaitingSaop)), 0),
    NoImageCount = ISNULL(SUM(CONVERT(bigint, NoImage)), 0)
  FROM flags
  OPTION (RECOMPILE);
END');
