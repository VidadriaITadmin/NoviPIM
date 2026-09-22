/*
  248 - Stanje profila, ki za izdelek ne velja, ne sme ostati v bazi ("Neveljavno" brez napak).

  Simptom (uporabnik 2026-09-22, artikel VD.OBM8WH.B, podjetje 3): zavihek Splet na kartici kaze
  "Neveljavno", 0 blokirajocih napak, 0 opozoril, popolnost izdelka 100 %. Seznam izdelkov kaze
  "Stanje splet: Blokiran" pri vsakem izdelku brez kljukice spletisca; pregled profilov steje
  ~171.000 neveljavnih izdelkov na spletisce (podjetja imajo skupaj ~11.700 kljukic).

  Vzrok: migracija 182 je spletni profil omejila na izdelke s kljukico spletisca
  (pim.ProductWebShop.IsPublished). val.RunValidation od takrat za izdelek brez kljukice spletnih
  napak ne odpira in obstojece zapre (UPDATE IsActive = 0) - vrstice v val.ProductValidationState
  pa ne izbrise in ne osvezi, ker MERGE tece samo cez pare (izdelek, profil) v obsegu. Za 343.000
  parov (izdelek, spletni profil) je tako obstalo stanje INVALID 70 % z dne 2026-09-08 15:54 (dan
  uveljavitve 182), ceprav so bile vse napake zaprte 2026-09-09. Kartica (intranet.GetProductCard,
  nabor 12) in seznam (intranet.GetProductList) stanje profila bereta iz te tabele, napake pa iz
  val.ProductIssue - zato "Neveljavno" z nic napakami. Popolnost 100 % je bila pravilna: canon.Product
  jo racuna samo iz profilov v obsegu.

  Kaj naredi ta migracija:
    1. val.RunValidation, val.RunValidationForProduct, val.RunValidationForProducts: izracun gre v
       #Score; po MERGE se izbrise vsako stanje validiranega izdelka, ki ga ta tek ni izracunal
       (spletni profil brez kljukice, neaktiven profil, profil brez veljavne zahteve). Odstranitev
       kljukice (pim.SaveProductWebShops -> RunValidationForProduct) tako takoj pobrise spletno stanje.
    2. Enkratno ciscenje zastarelih stanj aktivnih izdelkov (v paketih po 50.000).
    3. intranet.GetProductCard in intranet.GetProductList: stanje "splet" izdelka brez kljukice je
       NOT_ON_WEB ("Ni na spletu"), ne INVALID; pri izdelku s kljukico stejejo samo profili, ki zanj
       veljajo (skupni + profil oznacenega spletisca). Filter seznama "Pripravljeni/Blokirani za
       splet" po istem pravilu - prej je "pripravljen" zahteval VALID v OBEH spletnih profilih.
       Kartica na nivoju profila (nabor 12) vrne NOT_ON_WEB namesto PENDING za spletisce brez kljukice.

  Cesa NE naredi: pravil (val.FieldRequirement, val.ValidationProfile) ne spreminja; stanja
  neaktivnih izdelkov (IsActive = 0) pusti, ker jih validacija ne obravnava. Kar Excel sodelavke
  z 11. 9. zahteva drugace (Volume neobvezen, dimenzije paketa za splet, EU/THIRD samo za tuje
  proizvajalce, potrditev "brez EAN"), je locena odlocitev - glej pogovor 2026-09-22.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

/* --- 1) Validacija: stanje obstaja natanko za pare (izdelek, profil) v obsegu ------------------- */
EXEC(N'CREATE OR ALTER PROCEDURE val.RunValidation
  @OrganizationId int = NULL,
  @ProductId bigint = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  /* 211: ob zastoju z map.ProcessRawInbox naj vedno izgubi validacija, ne preslikava - glej
     glavo migracije 211 za razlago, zakaj namesto cakanja na kljucavnico. */
  SET DEADLOCK_PRIORITY LOW;
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
      /* 182: napaka se zapre tudi takrat, ko profil za ta izdelek ne velja vec - brez tega bi
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

    /* 248: izracun gre v #Score, ker mora po MERGE ostati na voljo: stanje profila obstaja
       natanko za pare (izdelek, profil), ki jih je ta tek izracunal - glej DELETE spodaj. */
    CREATE TABLE #Score
      (ProductId bigint NOT NULL, ValidationProfileId int NOT NULL,
       Completeness decimal(5,2) NOT NULL, Status nvarchar(20) COLLATE DATABASE_DEFAULT NOT NULL,
       PRIMARY KEY (ProductId, ValidationProfileId));
    INSERT #Score (ProductId, ValidationProfileId, Completeness, Status)
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
        GROUP BY product.ProductId, profile.ValidationProfileId;

    MERGE val.ProductValidationState AS target
    USING #Score AS source ON target.ProductId = source.ProductId AND target.ValidationProfileId = source.ValidationProfileId
    WHEN MATCHED THEN UPDATE SET Status = source.Status, Completeness = source.Completeness, ValidatedUtc = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT (ProductId, ValidationProfileId, Status, Completeness, ValidatedUtc) VALUES (source.ProductId, source.ValidationProfileId, source.Status, source.Completeness, SYSUTCDATETIME());

    /* 248: profil, ki za izdelek ne velja (vec) - spletni profil brez kljukice spletisca,
       neaktiven profil, profil brez ene same veljavne zahteve - v #Score ni in ga MERGE zgoraj
       ne osvezi. Do 248 je taka vrstica obstala z dnem, ko je bil izdelek se v obsegu (INVALID
       70 % z 8. 9.): kartica je kazala "Neveljavno" z 0 napakami, pregled profilov pa 171.000
       neveljavnih izdelkov na spletisce. Napake (val.ProductIssue) 182 ze zapira - stanje ne. */
    DELETE state
    FROM val.ProductValidationState state
    INNER JOIN canon.Product product ON product.ProductId = state.ProductId
    WHERE product.IsActive = 1
      AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
      AND (@ProductId IS NULL OR product.ProductId = @ProductId)
      AND NOT EXISTS
      (
        SELECT 1 FROM #Score score
        WHERE score.ProductId = state.ProductId AND score.ValidationProfileId = state.ValidationProfileId
      );

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
END;');

EXEC(N'CREATE OR ALTER PROCEDURE val.RunValidationForProduct
  @ProductId bigint
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
        AND product.ProductId = @ProductId
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
        AND product.ProductId = @ProductId
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
      AND product.ProductId = @ProductId
      /* 182: napaka se zapre tudi takrat, ko profil za ta izdelek ne velja vec - brez tega bi
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

    /* 248: izracun gre v #Score, ker mora po MERGE ostati na voljo: stanje profila obstaja
       natanko za pare (izdelek, profil), ki jih je ta tek izracunal - glej DELETE spodaj. */
    CREATE TABLE #Score
      (ProductId bigint NOT NULL, ValidationProfileId int NOT NULL,
       Completeness decimal(5,2) NOT NULL, Status nvarchar(20) COLLATE DATABASE_DEFAULT NOT NULL,
       PRIMARY KEY (ProductId, ValidationProfileId));
    INSERT #Score (ProductId, ValidationProfileId, Completeness, Status)
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
        AND product.ProductId = @ProductId
        AND (profile.Scope <> N''WEB'' OR EXISTS
          (SELECT 1 FROM pim.ProductWebShop shop
           WHERE shop.ProductId = product.ProductId
             AND shop.WebShopCode = profile.CategoryTreeCode
             AND shop.IsPublished = 1))
        GROUP BY product.ProductId, profile.ValidationProfileId;

    MERGE val.ProductValidationState AS target
    USING #Score AS source ON target.ProductId = source.ProductId AND target.ValidationProfileId = source.ValidationProfileId
    WHEN MATCHED THEN UPDATE SET Status = source.Status, Completeness = source.Completeness, ValidatedUtc = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT (ProductId, ValidationProfileId, Status, Completeness, ValidatedUtc) VALUES (source.ProductId, source.ValidationProfileId, source.Status, source.Completeness, SYSUTCDATETIME());

    /* 248: profil, ki za izdelek ne velja (vec) - spletni profil brez kljukice spletisca,
       neaktiven profil, profil brez ene same veljavne zahteve - v #Score ni in ga MERGE zgoraj
       ne osvezi. Do 248 je taka vrstica obstala z dnem, ko je bil izdelek se v obsegu (INVALID
       70 % z 8. 9.): kartica je kazala "Neveljavno" z 0 napakami, pregled profilov pa 171.000
       neveljavnih izdelkov na spletisce. Napake (val.ProductIssue) 182 ze zapira - stanje ne. */
    DELETE state
    FROM val.ProductValidationState state
    INNER JOIN canon.Product product ON product.ProductId = state.ProductId
    WHERE product.IsActive = 1
      AND product.ProductId = @ProductId
      AND NOT EXISTS
      (
        SELECT 1 FROM #Score score
        WHERE score.ProductId = state.ProductId AND score.ValidationProfileId = state.ValidationProfileId
      );

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
      AND product.ProductId = @ProductId;

    COMMIT TRANSACTION;
  END TRY
  BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    DECLARE @ErrorMessage nvarchar(4000) = ERROR_MESSAGE();
    EXEC ops.LogError @Layer = N''val'', @Severity = N''Error'', @ErrorCode = N''RUN_VALIDATION_FAILED'', @Message = @ErrorMessage;
    THROW;
  END CATCH;
END;');

EXEC(N'CREATE OR ALTER PROCEDURE val.RunValidationForProducts
  @ProductIdsJson nvarchar(max)   /* [1, 2, 3, ...] */
AS
BEGIN
  /*
    218: ista validacija kot val.RunValidationForProduct (195), za SEZNAM izdelkov v enem teku -
    za mnozicni uvoz delovnega lista (pim.SaveProductTextsBulk, pim.SaveProductAttributesBulk).
    Besedilo je izpeljano iz 195: vsak pogoj "izdelek = @ProductId" je zamenjan s clanstvom
    izdelka v zacasni tabeli #Izbrani (EXISTS). Kot v 211 validacija ob zastoju s preslikavo (map.ProcessRawInbox) vedno izgubi.
  */
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  SET DEADLOCK_PRIORITY LOW;
  CREATE TABLE #Izbrani (ProductId bigint NOT NULL PRIMARY KEY);
  INSERT #Izbrani (ProductId)
  SELECT DISTINCT TRY_CONVERT(bigint, parsed.value) FROM OPENJSON(@ProductIdsJson) AS parsed
  WHERE ISJSON(parsed.value) = 0 AND TRY_CONVERT(bigint, parsed.value) IS NOT NULL;
  IF NOT EXISTS (SELECT 1 FROM #Izbrani) RETURN;
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
        AND EXISTS (SELECT 1 FROM #Izbrani AS izbrani WHERE izbrani.ProductId = product.ProductId)
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
        AND EXISTS (SELECT 1 FROM #Izbrani AS izbrani WHERE izbrani.ProductId = product.ProductId)
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
      AND EXISTS (SELECT 1 FROM #Izbrani AS izbrani WHERE izbrani.ProductId = product.ProductId)
      /* 182: napaka se zapre tudi takrat, ko profil za ta izdelek ne velja vec - brez tega bi
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

    /* 248: izracun gre v #Score, ker mora po MERGE ostati na voljo: stanje profila obstaja
       natanko za pare (izdelek, profil), ki jih je ta tek izracunal - glej DELETE spodaj. */
    CREATE TABLE #Score
      (ProductId bigint NOT NULL, ValidationProfileId int NOT NULL,
       Completeness decimal(5,2) NOT NULL, Status nvarchar(20) COLLATE DATABASE_DEFAULT NOT NULL,
       PRIMARY KEY (ProductId, ValidationProfileId));
    INSERT #Score (ProductId, ValidationProfileId, Completeness, Status)
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
        AND EXISTS (SELECT 1 FROM #Izbrani AS izbrani WHERE izbrani.ProductId = product.ProductId)
        AND (profile.Scope <> N''WEB'' OR EXISTS
          (SELECT 1 FROM pim.ProductWebShop shop
           WHERE shop.ProductId = product.ProductId
             AND shop.WebShopCode = profile.CategoryTreeCode
             AND shop.IsPublished = 1))
        GROUP BY product.ProductId, profile.ValidationProfileId;

    MERGE val.ProductValidationState AS target
    USING #Score AS source ON target.ProductId = source.ProductId AND target.ValidationProfileId = source.ValidationProfileId
    WHEN MATCHED THEN UPDATE SET Status = source.Status, Completeness = source.Completeness, ValidatedUtc = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT (ProductId, ValidationProfileId, Status, Completeness, ValidatedUtc) VALUES (source.ProductId, source.ValidationProfileId, source.Status, source.Completeness, SYSUTCDATETIME());

    /* 248: profil, ki za izdelek ne velja (vec) - spletni profil brez kljukice spletisca,
       neaktiven profil, profil brez ene same veljavne zahteve - v #Score ni in ga MERGE zgoraj
       ne osvezi. Do 248 je taka vrstica obstala z dnem, ko je bil izdelek se v obsegu (INVALID
       70 % z 8. 9.): kartica je kazala "Neveljavno" z 0 napakami, pregled profilov pa 171.000
       neveljavnih izdelkov na spletisce. Napake (val.ProductIssue) 182 ze zapira - stanje ne. */
    DELETE state
    FROM val.ProductValidationState state
    INNER JOIN canon.Product product ON product.ProductId = state.ProductId
    WHERE product.IsActive = 1
      AND EXISTS (SELECT 1 FROM #Izbrani AS izbrani WHERE izbrani.ProductId = product.ProductId)
      AND NOT EXISTS
      (
        SELECT 1 FROM #Score score
        WHERE score.ProductId = state.ProductId AND score.ValidationProfileId = state.ValidationProfileId
      );

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
      AND EXISTS (SELECT 1 FROM #Izbrani AS izbrani WHERE izbrani.ProductId = product.ProductId);

    COMMIT TRANSACTION;
  END TRY
  BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    DECLARE @ErrorMessage nvarchar(4000) = ERROR_MESSAGE();
    EXEC ops.LogError @Layer = N''val'', @Severity = N''Error'', @ErrorCode = N''RUN_VALIDATION_FAILED'', @Message = @ErrorMessage;
    THROW;
  END CATCH;
END;');

/* --- 2) Enkratno ciscenje zastarelih stanj aktivnih izdelkov ----------------------------------- */
DECLARE @CleanupBatch int = 1, @CleanupTotal int = 0;
WHILE @CleanupBatch > 0
BEGIN
  DELETE TOP (50000) state
  FROM val.ProductValidationState AS state
  INNER JOIN canon.Product AS product ON product.ProductId = state.ProductId
  INNER JOIN val.ValidationProfile AS profile ON profile.ValidationProfileId = state.ValidationProfileId
  WHERE product.IsActive = 1
    AND (profile.IsActive = 0
      OR (profile.Scope = N'WEB' AND NOT EXISTS
        (SELECT 1 FROM pim.ProductWebShop AS shop
         WHERE shop.ProductId = product.ProductId
           AND shop.WebShopCode = profile.CategoryTreeCode
           AND shop.IsPublished = 1)));
  SET @CleanupBatch = @@ROWCOUNT;
  SET @CleanupTotal += @CleanupBatch;
END;
PRINT CONCAT(N'248: izbrisanih zastarelih stanj profilov: ', @CleanupTotal);

/* --- 3) Kartica in seznam: brez kljukice ni "Neveljavno", ampak "Ni na spletu" ----------------- */
DECLARE @Card nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'intranet.GetProductCard'));
IF @Card IS NULL THROW 52481, N'248: intranet.GetProductCard ne obstaja.', 1;
IF @Card NOT LIKE N'%/* 248 */%'
BEGIN
  /* Shranjena definicija ima mesane konce vrstic; sidra so zapisana z NCHAR(10). */
  SET @Card = REPLACE(@Card, NCHAR(13) + NCHAR(10), NCHAR(10));
  DECLARE @CardC1Old nvarchar(max) = N'WHERE profileValue.IsActive = 1 AND profileValue.BlocksWeb = 1' + NCHAR(10) + N'      ) THEN N''NOT_CONFIGURED''';
  DECLARE @CardC1New nvarchar(max) = N'WHERE profileValue.IsActive = 1 AND profileValue.BlocksWeb = 1' + NCHAR(10) + N'      ) THEN N''NOT_CONFIGURED''' + NCHAR(10) + N'      WHEN NOT EXISTS (SELECT 1 FROM pim.ProductWebShop webFlag /* 248 */ WHERE webFlag.ProductId = product.ProductId AND webFlag.IsPublished = 1) THEN N''NOT_ON_WEB''';
  IF (LEN(@Card) - LEN(REPLACE(@Card, @CardC1Old, N''))) / LEN(@CardC1Old) <> 1
    THROW 52482, N'248: intranet.GetProductCard nima pricakovanega besedila (C1).', 1;
  DECLARE @CardC2Old nvarchar(max) = N'WHERE profileValue.IsActive = 1 AND profileValue.BlocksWeb = 1' + NCHAR(10) + N'          AND (stateValue.ProductValidationStateId IS NULL OR stateValue.Status <> N''VALID'')';
  DECLARE @CardC2New nvarchar(max) = N'WHERE profileValue.IsActive = 1 AND profileValue.BlocksWeb = 1' + NCHAR(10) + N'          AND (profileValue.Scope <> N''WEB'' OR EXISTS (SELECT 1 FROM pim.ProductWebShop siteFlag /* 248 */ WHERE siteFlag.ProductId = product.ProductId AND siteFlag.WebShopCode = profileValue.CategoryTreeCode AND siteFlag.IsPublished = 1))' + NCHAR(10) + N'          AND (stateValue.ProductValidationStateId IS NULL OR stateValue.Status <> N''VALID'')';
  IF (LEN(@Card) - LEN(REPLACE(@Card, @CardC2Old, N''))) / LEN(@CardC2Old) <> 1
    THROW 52483, N'248: intranet.GetProductCard nima pricakovanega besedila (C2).', 1;
  DECLARE @CardC3Old nvarchar(max) = N'    Status = COALESCE(stateValue.Status, N''PENDING''),';
  DECLARE @CardC3New nvarchar(max) = N'    Status = COALESCE(stateValue.Status, CASE WHEN profileValue.Scope = N''WEB'' AND NOT EXISTS (SELECT 1 FROM pim.ProductWebShop siteFlag /* 248 */ WHERE siteFlag.ProductId = @ProductId AND siteFlag.WebShopCode = profileValue.CategoryTreeCode AND siteFlag.IsPublished = 1) THEN N''NOT_ON_WEB'' ELSE N''PENDING'' END),';
  IF (LEN(@Card) - LEN(REPLACE(@Card, @CardC3Old, N''))) / LEN(@CardC3Old) <> 1
    THROW 52484, N'248: intranet.GetProductCard nima pricakovanega besedila (C3).', 1;
  SET @Card = REPLACE(@Card, @CardC1Old, @CardC1New);
  SET @Card = REPLACE(@Card, @CardC2Old, @CardC2New);
  SET @Card = REPLACE(@Card, @CardC3Old, @CardC3New);
  DECLARE @CardHeaderEnd int = CHARINDEX(N'PROCEDURE', @Card);
  IF @CardHeaderEnd = 0 OR LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
       LEFT(@Card, @CardHeaderEnd - 1), N'CREATE', N''), N'OR ALTER', N''), NCHAR(13), N''), NCHAR(10), N''), NCHAR(9), N''))) <> N''
    THROW 52485, N'248: glava intranet.GetProductCard ni CREATE [OR ALTER] PROCEDURE.', 1;
  SET @Card = N'ALTER ' + SUBSTRING(@Card, @CardHeaderEnd, 2147483647);
  EXEC sys.sp_executesql @Card;
END;

DECLARE @List nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'intranet.GetProductList'));
IF @List IS NULL THROW 52491, N'248: intranet.GetProductList ne obstaja.', 1;
IF @List NOT LIKE N'%/* 248 */%'
BEGIN
  /* Shranjena definicija ima mesane konce vrstic; sidra so zapisana z NCHAR(10). */
  SET @List = REPLACE(@List, NCHAR(13) + NCHAR(10), NCHAR(10));
  DECLARE @ListL1Old nvarchar(max) = N'WHEN @WebProfiles = 0 THEN N''NOT_CONFIGURED''';
  DECLARE @ListL1New nvarchar(max) = N'WHEN @WebProfiles = 0 THEN N''NOT_CONFIGURED''' + NCHAR(10) + N'      WHEN NOT EXISTS (SELECT 1 FROM pim.ProductWebShop AS webFlag /* 248 */ WHERE webFlag.ProductId = product.ProductId AND webFlag.IsPublished = 1) THEN N''NOT_ON_WEB''';
  IF (LEN(@List) - LEN(REPLACE(@List, @ListL1Old, N''))) / LEN(@ListL1Old) <> 1
    THROW 52492, N'248: intranet.GetProductList nima pricakovanega besedila (L1).', 1;
  DECLARE @ListL2Old nvarchar(max) = N'WHERE profileValue.IsActive = 1 AND profileValue.BlocksWeb = 1' + NCHAR(10) + N'          AND (stateValue.ProductValidationStateId IS NULL OR stateValue.Status <> N''VALID'')';
  DECLARE @ListL2New nvarchar(max) = N'WHERE profileValue.IsActive = 1 AND profileValue.BlocksWeb = 1' + NCHAR(10) + N'          AND (profileValue.Scope <> N''WEB'' OR EXISTS (SELECT 1 FROM pim.ProductWebShop AS siteFlag /* 248 */ WHERE siteFlag.ProductId = product.ProductId AND siteFlag.WebShopCode = profileValue.CategoryTreeCode AND siteFlag.IsPublished = 1))' + NCHAR(10) + N'          AND (stateValue.ProductValidationStateId IS NULL OR stateValue.Status <> N''VALID'')';
  IF (LEN(@List) - LEN(REPLACE(@List, @ListL2Old, N''))) / LEN(@ListL2Old) <> 1
    THROW 52493, N'248: intranet.GetProductList nima pricakovanega besedila (L2).', 1;
  DECLARE @ListL3Old nvarchar(max) = N'  IF @WebStatus IS NOT NULL AND @WebProfiles > 0' + NCHAR(10) + N'    INSERT #WebValid (ProductId)' + NCHAR(10) + N'    SELECT stateValue.ProductId' + NCHAR(10) + N'    FROM val.ProductValidationState AS stateValue' + NCHAR(10) + N'    INNER JOIN val.ValidationProfile AS profileValue' + NCHAR(10) + N'      ON profileValue.ValidationProfileId = stateValue.ValidationProfileId' + NCHAR(10) + N'     AND profileValue.IsActive = 1 AND profileValue.BlocksWeb = 1' + NCHAR(10) + N'    INNER JOIN canon.Product AS product' + NCHAR(10) + N'      ON product.ProductId = stateValue.ProductId' + NCHAR(10) + N'     AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)' + NCHAR(10) + N'    WHERE stateValue.Status = N''VALID''' + NCHAR(10) + N'    GROUP BY stateValue.ProductId' + NCHAR(10) + N'    HAVING COUNT(*) = @WebProfiles;';
  DECLARE @ListL3New nvarchar(max) = N'  /* 248: kljukica spletisca doloca, kateri spletni profili za izdelek veljajo. "Pripravljen za' + NCHAR(10) + N'     splet" je izdelek s kljukico, ki je VALID v vseh profilih, ki zanj blokirajo splet; brez' + NCHAR(10) + N'     kljukice ni ne pripravljen ne blokiran (NOT_ON_WEB). Prej je HAVING COUNT(*) = @WebProfiles' + NCHAR(10) + N'     zahteval VALID v OBEH spletnih profilih, torej kljukico na obeh spletiscih - izdelek enega' + NCHAR(10) + N'     spletisca ni bil nikoli pripravljen, izdelek brez kljukice pa je bil vedno blokiran. */' + NCHAR(10) + N'  CREATE TABLE #WebFlagged (ProductId bigint NOT NULL PRIMARY KEY);' + NCHAR(10) + N'  IF @WebStatus IS NOT NULL' + NCHAR(10) + N'    INSERT #WebFlagged (ProductId)' + NCHAR(10) + N'    SELECT DISTINCT shop.ProductId' + NCHAR(10) + N'    FROM pim.ProductWebShop AS shop' + NCHAR(10) + N'    INNER JOIN canon.Product AS product ON product.ProductId = shop.ProductId' + NCHAR(10) + N'    WHERE shop.IsPublished = 1' + NCHAR(10) + N'      AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId);' + NCHAR(10) + N'  IF @WebStatus IS NOT NULL AND @WebProfiles > 0' + NCHAR(10) + N'    INSERT #WebValid (ProductId)' + NCHAR(10) + N'    SELECT flagged.ProductId' + NCHAR(10) + N'    FROM #WebFlagged AS flagged' + NCHAR(10) + N'    WHERE NOT EXISTS' + NCHAR(10) + N'    (' + NCHAR(10) + N'      SELECT 1 FROM val.ValidationProfile AS profileValue' + NCHAR(10) + N'      LEFT JOIN val.ProductValidationState AS stateValue' + NCHAR(10) + N'        ON stateValue.ValidationProfileId = profileValue.ValidationProfileId' + NCHAR(10) + N'       AND stateValue.ProductId = flagged.ProductId' + NCHAR(10) + N'      WHERE profileValue.IsActive = 1 AND profileValue.BlocksWeb = 1' + NCHAR(10) + N'        AND (profileValue.Scope <> N''WEB'' OR EXISTS (SELECT 1 FROM pim.ProductWebShop AS siteFlag WHERE siteFlag.ProductId = flagged.ProductId AND siteFlag.WebShopCode = profileValue.CategoryTreeCode AND siteFlag.IsPublished = 1))' + NCHAR(10) + N'        AND (stateValue.ProductValidationStateId IS NULL OR stateValue.Status <> N''VALID'')' + NCHAR(10) + N'    );';
  IF (LEN(@List) - LEN(REPLACE(@List, @ListL3Old, N''))) / LEN(@ListL3Old) <> 1
    THROW 52494, N'248: intranet.GetProductList nima pricakovanega besedila (L3).', 1;
  DECLARE @ListL4Old nvarchar(max) = N'OR (@WebStatus = N''INVALID'' AND NOT EXISTS (SELECT 1 FROM #WebValid AS webValid WHERE webValid.ProductId = product.ProductId))';
  DECLARE @ListL4New nvarchar(max) = N'OR (@WebStatus = N''INVALID'' AND EXISTS (SELECT 1 FROM #WebFlagged AS webFlagged /* 248 */ WHERE webFlagged.ProductId = product.ProductId) AND NOT EXISTS (SELECT 1 FROM #WebValid AS webValid WHERE webValid.ProductId = product.ProductId))';
  IF (LEN(@List) - LEN(REPLACE(@List, @ListL4Old, N''))) / LEN(@ListL4Old) <> 2
    THROW 52495, N'248: intranet.GetProductList nima pricakovanega besedila (L4).', 1;
  DECLARE @ListL5Old nvarchar(max) = N'  DROP TABLE #WebValid;';
  DECLARE @ListL5New nvarchar(max) = N'  DROP TABLE #WebValid;' + NCHAR(10) + N'  DROP TABLE #WebFlagged;';
  IF (LEN(@List) - LEN(REPLACE(@List, @ListL5Old, N''))) / LEN(@ListL5Old) <> 1
    THROW 52496, N'248: intranet.GetProductList nima pricakovanega besedila (L5).', 1;
  SET @List = REPLACE(@List, @ListL1Old, @ListL1New);
  SET @List = REPLACE(@List, @ListL2Old, @ListL2New);
  SET @List = REPLACE(@List, @ListL3Old, @ListL3New);
  SET @List = REPLACE(@List, @ListL4Old, @ListL4New);
  SET @List = REPLACE(@List, @ListL5Old, @ListL5New);
  DECLARE @ListHeaderEnd int = CHARINDEX(N'PROCEDURE', @List);
  IF @ListHeaderEnd = 0 OR LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
       LEFT(@List, @ListHeaderEnd - 1), N'CREATE', N''), N'OR ALTER', N''), NCHAR(13), N''), NCHAR(10), N''), NCHAR(9), N''))) <> N''
    THROW 52497, N'248: glava intranet.GetProductList ni CREATE [OR ALTER] PROCEDURE.', 1;
  SET @List = N'ALTER ' + SUBSTRING(@List, @ListHeaderEnd, 2147483647);
  EXEC sys.sp_executesql @List;
END;

/* --- 4) Preverba ------------------------------------------------------------------------------ */
IF OBJECT_DEFINITION(OBJECT_ID(N'val.RunValidation')) NOT LIKE N'%#Score%'
  THROW 52501, N'248: val.RunValidation ne brise stanja izven obsega.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'val.RunValidationForProduct')) NOT LIKE N'%#Score%'
  THROW 52502, N'248: val.RunValidationForProduct ne brise stanja izven obsega.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'val.RunValidationForProducts')) NOT LIKE N'%#Score%'
  THROW 52503, N'248: val.RunValidationForProducts ne brise stanja izven obsega.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'val.RunValidation')) NOT LIKE N'%DEADLOCK_PRIORITY LOW%'
  THROW 52504, N'248: val.RunValidation je izgubil DEADLOCK_PRIORITY LOW iz 211.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'intranet.GetProductCard')) NOT LIKE N'%NOT_ON_WEB%'
  THROW 52505, N'248: intranet.GetProductCard ne pozna NOT_ON_WEB.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'intranet.GetProductList')) NOT LIKE N'%#WebFlagged%'
  THROW 52506, N'248: intranet.GetProductList ne filtrira po kljukici spletisca.', 1;
IF EXISTS
(
  SELECT 1 FROM val.ProductValidationState AS state
  INNER JOIN canon.Product AS product ON product.ProductId = state.ProductId
  INNER JOIN val.ValidationProfile AS profile ON profile.ValidationProfileId = state.ValidationProfileId
  WHERE product.IsActive = 1 AND profile.Scope = N'WEB'
    AND NOT EXISTS (SELECT 1 FROM pim.ProductWebShop AS shop
                    WHERE shop.ProductId = product.ProductId AND shop.WebShopCode = profile.CategoryTreeCode AND shop.IsPublished = 1)
)
  THROW 52507, N'248: zastarelo spletno stanje je ostalo.', 1;
