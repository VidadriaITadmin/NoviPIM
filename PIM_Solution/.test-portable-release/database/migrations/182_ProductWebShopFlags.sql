-- D2 iz pregleda 2026-09-08 in uporabnikova odlocitev 2026-09-08.
--
-- Pregled je izmeril, da spletna profila validirata tudi izdelke, ki na splet ne gredo:
-- 883.587 + 873.812 odprtih napak na 162.669 oziroma 162.444 izdelkih z WebPublish = 0.
-- Predlog pregleda je bil obseg omejiti na WebPublish = 1.
--
-- Uporabnik je to zavrnil, dobesedno: »ta webpublish to ne bomo vec uporabljali in bomo imeli
-- polje oz morajo biti nekje check boxi ki bodo povedali, da gre artikel na svetila ali
-- videlektro in to se bo gledalo. Ta webpublish je iz SAOPja in je BV da ga pisemo nazaj lahko
-- pa naredimo nek programcek, ki gleda in samo posatvi na 1, ce ima artikel check box oznacen.«
--
-- Zato merilo ni vec polje iz SAOP, ampak odlocitev cloveka v PIM: ena potrditvena oznaka na
-- spletisce. Koda spletisca je `CategoryTreeCode` (`svetila_si`, `videlektro`) — isti kljuc, ki
-- ga `val.ValidationProfile` ze nosi za spletna profila in `canon.WebSite` za svoje jezikovne
-- razlicice, zato nov register ni potreben.
--
-- Ta migracija NE pozene validacije nad celotnim katalogom. Ucinek se pokaze, ko tece
-- `val.RunValidation` (za posamezen izdelek ga pozene ze `pim.SaveProductWebShops`).

SET XACT_ABORT ON;

IF OBJECT_ID(N'pim.ProductWebShop', N'U') IS NULL
BEGIN
  CREATE TABLE pim.ProductWebShop
  (
    ProductId bigint NOT NULL,
    WebShopCode nvarchar(100) NOT NULL,
    IsPublished bit NOT NULL CONSTRAINT DF_ProductWebShop_IsPublished DEFAULT (1),
    ChangedBy nvarchar(200) NOT NULL CONSTRAINT DF_ProductWebShop_ChangedBy DEFAULT (N'sistem'),
    ChangedUtc datetime2(3) NOT NULL CONSTRAINT DF_ProductWebShop_ChangedUtc DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_ProductWebShop PRIMARY KEY (ProductId, WebShopCode),
    CONSTRAINT FK_ProductWebShop_Product FOREIGN KEY (ProductId) REFERENCES canon.Product (ProductId)
  );
END;

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'pim.ProductWebShop') AND name = N'IX_ProductWebShop_Shop')
  CREATE INDEX IX_ProductWebShop_Shop ON pim.ProductWebShop(WebShopCode, IsPublished) INCLUDE (ProductId);

-- Zacetno stanje. Edini obstojeci dokaz »ta izdelek je za to spletisce« je dodeljena kategorija
-- v drevesu tega spletisca; WebPublish tega ne pove, ker ne loci spletisc. Zato se `svetila_si`
-- napolni iz dodeljenih kategorij, `videlektro` pa ostane prazen — tam dodeljenih kategorij ni
-- nobene in nihce ne more vedeti, kateri izdelki tja sodijo. To je namerno: dokler nekdo ne
-- oznaci, na videlektro ne gre nic in spletni profil zanj nima kaj validirati.
INSERT pim.ProductWebShop (ProductId, WebShopCode, IsPublished, ChangedBy)
SELECT DISTINCT productCategory.ProductId, site.CategoryTreeCode, 1, N'migracija 182'
FROM canon.ProductCategory AS productCategory
INNER JOIN canon.WebSite AS site ON site.WebSiteCode = productCategory.WebSite
INNER JOIN canon.Product AS product ON product.ProductId = productCategory.ProductId
WHERE product.IsActive = 1
  AND NOT EXISTS (SELECT 1 FROM pim.ProductWebShop existing
                  WHERE existing.ProductId = productCategory.ProductId
                    AND existing.WebShopCode = site.CategoryTreeCode);

-- Branje oznak za kartico izdelka. Vrne vsa aktivna spletisca, ne samo oznacena, ker mora
-- obrazec pokazati tudi prazno potrditveno polje.
EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetProductWebShops
  @ProductId bigint
AS
BEGIN
  SET NOCOUNT ON;
  SELECT shop.WebShopCode,
         shop.WebShopName,
         CAST(CASE WHEN flag.IsPublished = 1 THEN 1 ELSE 0 END AS bit) AS IsPublished,
         flag.ChangedBy,
         flag.ChangedUtc
  FROM (
    SELECT site.CategoryTreeCode AS WebShopCode,
           MIN(site.WebSiteName) AS WebShopName,
           MIN(site.SortOrder) AS SortOrder
    FROM canon.WebSite site
    WHERE site.IsActive = 1
    GROUP BY site.CategoryTreeCode
  ) AS shop
  LEFT JOIN pim.ProductWebShop flag
    ON flag.ProductId = @ProductId AND flag.WebShopCode = shop.WebShopCode
  ORDER BY shop.SortOrder, shop.WebShopCode;
END;
');

-- Zapis oznak. Vhod je JSON [{"webShopCode":"svetila_si","isPublished":true}, ...]; kar v njem
-- ni nasteto, ostane nespremenjeno. Vsaka sprememba pusti vrstico v pim.ProductFieldHistory,
-- ker je to odlocitev cloveka in mora biti vidno, kdo je izdelek dal na splet ali ga umaknil.
EXEC(N'
CREATE OR ALTER PROCEDURE pim.SaveProductWebShops
  @OrganizationId int,
  @ProductId bigint,
  @ChangesJson nvarchar(max),
  @Actor nvarchar(200),
  @Note nvarchar(400) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  IF NOT EXISTS (SELECT 1 FROM canon.Product WHERE ProductId = @ProductId AND OrganizationId = @OrganizationId)
    THROW 52401, N''Izdelek ne pripada temu podjetju.'', 1;

  DECLARE @Changes TABLE (WebShopCode nvarchar(100) NOT NULL PRIMARY KEY, IsPublished bit NOT NULL);
  INSERT @Changes (WebShopCode, IsPublished)
  SELECT DISTINCT parsed.webShopCode, CASE WHEN parsed.isPublished IN (N''1'', N''true'') THEN 1 ELSE 0 END
  FROM OPENJSON(@ChangesJson)
  WITH (webShopCode nvarchar(100) N''$.webShopCode'', isPublished nvarchar(10) N''$.isPublished'') AS parsed
  WHERE NULLIF(parsed.webShopCode, N'''') IS NOT NULL;

  IF EXISTS (SELECT 1 FROM @Changes changed
             WHERE NOT EXISTS (SELECT 1 FROM canon.WebSite site
                               WHERE site.CategoryTreeCode = changed.WebShopCode AND site.IsActive = 1))
    THROW 52403, N''Neznano spletisce.'', 1;

  DECLARE @ItemID nvarchar(50) = (SELECT ItemID FROM canon.Product WHERE ProductId = @ProductId);
  DECLARE @BatchId bigint;

  BEGIN TRANSACTION;
  BEGIN TRY
    DECLARE @Changed TABLE (WebShopCode nvarchar(100), OldValue nvarchar(10), NewValue nvarchar(10));

    MERGE pim.ProductWebShop AS target
    USING @Changes AS source ON target.ProductId = @ProductId AND target.WebShopCode = source.WebShopCode
    WHEN MATCHED AND target.IsPublished <> source.IsPublished
      THEN UPDATE SET IsPublished = source.IsPublished, ChangedBy = @Actor, ChangedUtc = SYSUTCDATETIME()
    WHEN NOT MATCHED BY TARGET
      THEN INSERT (ProductId, WebShopCode, IsPublished, ChangedBy) VALUES (@ProductId, source.WebShopCode, source.IsPublished, @Actor)
    OUTPUT inserted.WebShopCode,
           CASE WHEN deleted.IsPublished IS NULL THEN N''ne'' WHEN deleted.IsPublished = 1 THEN N''da'' ELSE N''ne'' END,
           CASE WHEN inserted.IsPublished = 1 THEN N''da'' ELSE N''ne'' END
    INTO @Changed (WebShopCode, OldValue, NewValue);

    DELETE @Changed WHERE OldValue = NewValue;

    IF EXISTS (SELECT 1 FROM @Changed)
    BEGIN
      INSERT pim.ProductChangeBatch (BatchId, ChangeSource, ChangedBy, OrganizationId, Note)
      VALUES (NEWID(), N''CARD'', @Actor, @OrganizationId, @Note);
      SET @BatchId = SCOPE_IDENTITY();

      INSERT pim.ProductFieldHistory (ChangeBatchId, OrganizationId, ProductId, ItemID, FieldKey, CanonTable, CanonColumn, Owner, OldValue, NewValue)
      SELECT @BatchId, @OrganizationId, @ProductId, @ItemID,
             CONCAT(N''ProductWebShop.'', changed.WebShopCode), N''pim.ProductWebShop'', N''IsPublished'', N''PIM'',
             changed.OldValue, changed.NewValue
      FROM @Changed changed;
    END;

    COMMIT;
  END TRY
  BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    THROW;
  END CATCH

  EXEC val.RunValidation @OrganizationId = @OrganizationId, @ProductId = @ProductId;

  SELECT (SELECT COUNT(*) FROM @Changes) AS RequestedCount,
         (SELECT COUNT(*) FROM pim.ProductWebShop WHERE ProductId = @ProductId AND IsPublished = 1) AS PublishedCount;
END;
');

-- Obseg spletne validacije. Spremenjena so stiri mesta: izbor zahtev, zapiranje zastarelih
-- napak, izracun popolnosti po profilu in koncni izracun stanja izdelka. Vsa stiri uporabijo isto
-- pravilo: profil s Scope = 'WEB' velja samo za izdelek, ki je za njegovo spletisce oznacen.
EXEC(N'
CREATE OR ALTER PROCEDURE val.RunValidation
  @OrganizationId int = NULL,
  @ProductId bigint = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  BEGIN TRY
    /* 147: obseg zahteve. Za vsak izdelek in vsak atribut, ki ga kaksna kategorija po verigi
       prednikov omenja, obvelja najblizja vrstica nabora (EXCLUDED pri otroku prekrije REQUIRED
       pri starsu). Zahteva z obsegom velja za izdelek, kadar je njena kategorija tista, kjer
       obveljala vrstica stoji, in raven ni EXCLUDED. */
    CREATE TABLE #Effective
      (ProductId bigint NOT NULL, CategoryTreeCode nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL,
       AttributeCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
       DefinedAtCategoryCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
       Level nvarchar(20) COLLATE DATABASE_DEFAULT NOT NULL,
       PRIMARY KEY (ProductId, CategoryTreeCode, AttributeCode));

    ;WITH assigned AS
    (
      SELECT DISTINCT product.ProductId, node.CategoryTreeCode, node.CategoryCode, node.ParentCategoryCode
      FROM canon.Product AS product
      INNER JOIN canon.ProductCategory AS productCategory ON productCategory.ProductId = product.ProductId
      INNER JOIN canon.WebSite AS site ON site.WebSiteCode = productCategory.WebSite
      INNER JOIN canon.Category AS node
        ON node.CategoryTreeCode = site.CategoryTreeCode AND node.CategoryPath = productCategory.CategoryPath
      WHERE product.IsActive = 1
        AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
        AND (@ProductId IS NULL OR product.ProductId = @ProductId)
    ),
    chain AS
    (
      SELECT ProductId, CategoryTreeCode, CategoryCode, ParentCategoryCode, 0 AS Depth FROM assigned
      UNION ALL
      SELECT chain.ProductId, parent.CategoryTreeCode, parent.CategoryCode, parent.ParentCategoryCode, chain.Depth + 1
      FROM chain
      INNER JOIN canon.Category AS parent
        ON parent.CategoryTreeCode = chain.CategoryTreeCode AND parent.CategoryCode = chain.ParentCategoryCode
      WHERE chain.Depth < 12
    ),
    ranked AS
    (
      SELECT chain.ProductId, chain.CategoryTreeCode, setRow.AttributeCode, chain.CategoryCode AS DefinedAtCategoryCode, setRow.Level,
        ROW_NUMBER() OVER (PARTITION BY chain.ProductId, chain.CategoryTreeCode, setRow.AttributeCode ORDER BY chain.Depth) AS PickRank
      FROM chain
      INNER JOIN canon.CategoryAttributeSet AS setRow
        ON setRow.CategoryTreeCode = chain.CategoryTreeCode AND setRow.CategoryCode = chain.CategoryCode AND setRow.IsActive = 1
    )
    INSERT #Effective (ProductId, CategoryTreeCode, AttributeCode, DefinedAtCategoryCode, Level)
    SELECT ProductId, CategoryTreeCode, AttributeCode, DefinedAtCategoryCode, Level FROM ranked WHERE PickRank = 1;

    /* Zahteva z obsegom -> koda atributa v registru (zahteva nosi slovensko ime). */
    CREATE TABLE #ScopedRequirement
      (FieldRequirementId int NOT NULL PRIMARY KEY, CategoryTreeCode nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL,
       CategoryCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL, AttributeCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL);
    INSERT #ScopedRequirement (FieldRequirementId, CategoryTreeCode, CategoryCode, AttributeCode)
    SELECT requirement.FieldRequirementId, requirement.CategoryTreeCode, requirement.CategoryCode, definition.AttributeCode
    FROM val.FieldRequirement AS requirement
    INNER JOIN canon.AttributeDefinition AS definition
      ON CONCAT(N''ProductAttribute.'', COALESCE(
           (SELECT TOP (1) Name FROM canon.AttributeTranslation WHERE AttributeCode = definition.AttributeCode AND LanguageCode = N''sl''),
           definition.AttributeCode)) = requirement.FieldCode
    WHERE requirement.CategoryCode IS NOT NULL;

    BEGIN TRANSACTION;
    ;WITH RequiredField AS
    (
      SELECT product.ProductId, profile.ValidationProfileId, requirement.FieldRequirementId, requirement.FieldCode
      FROM canon.Product product
      CROSS JOIN val.ValidationProfile profile
      INNER JOIN val.FieldRequirement requirement ON requirement.ValidationProfileId = profile.ValidationProfileId
      WHERE product.IsActive = 1 AND profile.IsActive = 1 AND requirement.IsActive = 1 AND requirement.IsRequired = 1
        AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
        AND (@ProductId IS NULL OR product.ProductId = @ProductId)
        /* 182: spletni profil velja samo za izdelek, ki je za to spletisce oznacen v PIM.
           Prej je CROSS JOIN vsak profil pripel na vsak izdelek, zato sta spletna profila
           odpirala napake tudi na 162.000 izdelkih, ki na splet sploh ne gredo. */
        AND (profile.Scope <> N''WEB'' OR EXISTS
          (SELECT 1 FROM pim.ProductWebShop shop
           WHERE shop.ProductId = product.ProductId
             AND shop.WebShopCode = profile.CategoryTreeCode
             AND shop.IsPublished = 1))
        AND (requirement.CategoryCode IS NULL OR EXISTS
          (SELECT 1 FROM #ScopedRequirement scoped
           INNER JOIN #Effective effective ON effective.ProductId = product.ProductId
             AND effective.CategoryTreeCode = scoped.CategoryTreeCode AND effective.AttributeCode = scoped.AttributeCode
             AND effective.DefinedAtCategoryCode = scoped.CategoryCode AND effective.Level <> N''EXCLUDED''
           WHERE scoped.FieldRequirementId = requirement.FieldRequirementId))
    ), MissingField AS
    (
      SELECT requiredField.*
      FROM RequiredField requiredField
      WHERE NOT EXISTS
      (
        SELECT 1 FROM canon.FieldValue fieldValue
        WHERE fieldValue.ProductId = requiredField.ProductId
          AND fieldValue.FieldCode = requiredField.FieldCode
          AND NULLIF(fieldValue.Value, N'''') IS NOT NULL
      )
    )
    MERGE val.ProductIssue AS target
    USING MissingField AS source
    ON target.ProductId = source.ProductId AND target.FieldRequirementId = source.FieldRequirementId
    WHEN MATCHED THEN UPDATE SET ValidationProfileId = source.ValidationProfileId, IssueCode = N''MISSING_REQUIRED_FIELD'', Message = CONCAT(N''Manjka obvezno polje: '', source.FieldCode), IsActive = 1, LastDetectedUtc = SYSUTCDATETIME(), ResolvedUtc = NULL
    WHEN NOT MATCHED THEN INSERT (ProductId, ValidationProfileId, FieldRequirementId, IssueCode, Message) VALUES (source.ProductId, source.ValidationProfileId, source.FieldRequirementId, N''MISSING_REQUIRED_FIELD'', CONCAT(N''Manjka obvezno polje: '', source.FieldCode));

    UPDATE issue SET IsActive = 0, ResolvedUtc = SYSUTCDATETIME()
    FROM val.ProductIssue issue
    INNER JOIN canon.Product product ON product.ProductId = issue.ProductId
    INNER JOIN val.ValidationProfile profile ON profile.ValidationProfileId = issue.ValidationProfileId
    WHERE issue.IsActive = 1
      AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
      AND (@ProductId IS NULL OR product.ProductId = @ProductId)
      /* 182: napaka se zapre tudi takrat, ko profil za ta izdelek ne velja vec — brez tega bi
         obstojece spletne napake ostale odprte, ceprav izdelek na to spletisce ne gre. */
      AND (NOT (profile.Scope <> N''WEB'' OR EXISTS
            (SELECT 1 FROM pim.ProductWebShop shop
             WHERE shop.ProductId = product.ProductId
               AND shop.WebShopCode = profile.CategoryTreeCode
               AND shop.IsPublished = 1))
      OR NOT EXISTS
      (
        SELECT 1 FROM val.FieldRequirement requirement
        WHERE requirement.FieldRequirementId = issue.FieldRequirementId AND requirement.IsActive = 1 AND requirement.IsRequired = 1
          AND (requirement.CategoryCode IS NULL OR EXISTS
            (SELECT 1 FROM #ScopedRequirement scoped
             INNER JOIN #Effective effective ON effective.ProductId = product.ProductId
               AND effective.CategoryTreeCode = scoped.CategoryTreeCode AND effective.AttributeCode = scoped.AttributeCode
               AND effective.DefinedAtCategoryCode = scoped.CategoryCode AND effective.Level <> N''EXCLUDED''
             WHERE scoped.FieldRequirementId = requirement.FieldRequirementId))
          AND NOT EXISTS (SELECT 1 FROM canon.FieldValue fieldValue WHERE fieldValue.ProductId = product.ProductId AND fieldValue.FieldCode = requirement.FieldCode AND NULLIF(fieldValue.Value, N'''') IS NOT NULL)
      ));

    ;WITH ProfileScore AS
    (
      SELECT product.ProductId, profile.ValidationProfileId,
        CAST(100.0 * (COUNT(requirement.FieldRequirementId) - SUM(CASE WHEN issue.ProductIssueId IS NULL THEN 0 ELSE 1 END)) / NULLIF(COUNT(requirement.FieldRequirementId), 0) AS decimal(5,2)) AS Completeness,
        CASE WHEN SUM(CASE WHEN issue.ProductIssueId IS NOT NULL AND requirement.Severity = N''ERROR'' THEN 1 ELSE 0 END) = 0
          THEN N''VALID'' ELSE N''INVALID'' END AS Status
      FROM canon.Product product
      CROSS JOIN val.ValidationProfile profile
      INNER JOIN val.FieldRequirement requirement ON requirement.ValidationProfileId = profile.ValidationProfileId AND requirement.IsActive = 1 AND requirement.IsRequired = 1
        AND (requirement.CategoryCode IS NULL OR EXISTS
          (SELECT 1 FROM #ScopedRequirement scoped
           INNER JOIN #Effective effective ON effective.ProductId = product.ProductId
             AND effective.CategoryTreeCode = scoped.CategoryTreeCode AND effective.AttributeCode = scoped.AttributeCode
             AND effective.DefinedAtCategoryCode = scoped.CategoryCode AND effective.Level <> N''EXCLUDED''
           WHERE scoped.FieldRequirementId = requirement.FieldRequirementId))
      LEFT JOIN val.ProductIssue issue ON issue.ProductId = product.ProductId AND issue.FieldRequirementId = requirement.FieldRequirementId AND issue.IsActive = 1
      WHERE product.IsActive = 1 AND profile.IsActive = 1
        AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
        AND (@ProductId IS NULL OR product.ProductId = @ProductId)
        AND (profile.Scope <> N''WEB'' OR EXISTS
          (SELECT 1 FROM pim.ProductWebShop shop
           WHERE shop.ProductId = product.ProductId
             AND shop.WebShopCode = profile.CategoryTreeCode
             AND shop.IsPublished = 1))
        GROUP BY product.ProductId, profile.ValidationProfileId
    )
    MERGE val.ProductValidationState AS target
    USING ProfileScore AS source ON target.ProductId = source.ProductId AND target.ValidationProfileId = source.ValidationProfileId
    WHEN MATCHED THEN UPDATE SET Status = source.Status, Completeness = source.Completeness, ValidatedUtc = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT (ProductId, ValidationProfileId, Status, Completeness, ValidatedUtc) VALUES (source.ProductId, source.ValidationProfileId, source.Status, source.Completeness, SYSUTCDATETIME());

    UPDATE product
    SET ValidationStatus =
        CASE WHEN EXISTS
        (
          SELECT 1 FROM val.ProductIssue issue
          INNER JOIN val.FieldRequirement requirement ON requirement.FieldRequirementId = issue.FieldRequirementId
          INNER JOIN val.ValidationProfile profile ON profile.ValidationProfileId = issue.ValidationProfileId
          WHERE issue.ProductId = product.ProductId AND issue.IsActive = 1
            AND requirement.Severity = N''ERROR''
            AND (profile.BlocksErp = 1 OR profile.BlocksWeb = 1)
            /* 182: profil, ki za ta izdelek ne velja, ne sme dolocati njegovega stanja. */
            AND (profile.Scope <> N''WEB'' OR EXISTS
              (SELECT 1 FROM pim.ProductWebShop shop
               WHERE shop.ProductId = product.ProductId
                 AND shop.WebShopCode = profile.CategoryTreeCode
                 AND shop.IsPublished = 1))
        ) THEN N''INVALID'' ELSE N''VALID'' END,
        Completeness = ISNULL
        ((
          SELECT MIN(state.Completeness) FROM val.ProductValidationState state
          INNER JOIN val.ValidationProfile profile ON profile.ValidationProfileId = state.ValidationProfileId
          WHERE state.ProductId = product.ProductId AND (profile.BlocksErp = 1 OR profile.BlocksWeb = 1)
            AND (profile.Scope <> N''WEB'' OR EXISTS
              (SELECT 1 FROM pim.ProductWebShop shop
               WHERE shop.ProductId = product.ProductId
                 AND shop.WebShopCode = profile.CategoryTreeCode
                 AND shop.IsPublished = 1))
        ), 0),
        LastValidatedUtc = SYSUTCDATETIME()
    FROM canon.Product product
    WHERE product.IsActive = 1
      AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
      AND (@ProductId IS NULL OR product.ProductId = @ProductId);

    COMMIT TRANSACTION;
  END TRY
  BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    DECLARE @ErrorMessage nvarchar(4000) = ERROR_MESSAGE();
    EXEC ops.LogError @Layer = N''val'', @Severity = N''Error'', @ErrorCode = N''RUN_VALIDATION_FAILED'', @Message = @ErrorMessage;
    THROW;
  END CATCH;
END;
');
