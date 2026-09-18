/*
  195 - val.RunValidationForProduct: hitra validacija enega izdelka ob dogodku, brez cakanja
  na razporejeno opravilo.

  Zahteva uporabnika 2026-09-11: validacija naj se izvede takoj, ko pride nov izdelek v sistem
  ali ko se popravijo obstojece napake na obstojecem izdelku - brez casovnega intervala
  ("res raje nebi imel avtomatsko validacijo na casovnem intervalu").

  Zakaj obstojeca val.RunValidation ni dovolj hitra za to: @OrganizationId in @ProductId sta
  neobvezna parametra (= NULL), zato se povsod v proceduri pojavlja vzorec
  "(@ProductId IS NULL OR stolpec = @ProductId)". SQL Server to prevede v EN sam izvedbeni
  nacrt, ki mora delovati pravilno tako za "en izdelek" kot za "ves katalog" - in izbere
  nacrt, varen za najslabsi primer (cel katalog, ~196.558 izdelkov), tudi ko je @ProductId
  podan. Izmerjeno: EXEC val.RunValidation @ProductId = 555 traja ~25s, skoraj enako kot
  polni tek za ves katalog (~81s).

  Preverjeno pred tem popravkom:
  - Manjkajocih indeksov ni. canon.Product, val.ProductIssue, pim.ProductWebShop,
    canon.ProductCommercial/Text/Attribute/Media/Price imajo vsi ze indeks, ki se zacne z
    ProductId.
  - OPTION (RECOMPILE) na obstojeci proceduri je bil poskusen popravek, a se je na zivem
    testu (locena kopija procedure, ne ta) izkazal za nevaren: v kombinaciji z zacasnimi
    tabelami (#Effective, #ScopedRequirement) in vzporedno izvedbo je povzrocil, da se je
    seja sama zaklenila (self-lock na schema-modification zaklepu) in obticala v
    KILLED/ROLLBACK stanju. Ni bila resitev.

  Prava resitev: locena, namenska procedura samo za en izdelek, kjer je @ProductId edini in
  OBVEZEN parameter (brez "IS NULL OR" vzorca). Brez te dvoumnosti SQL Server od zacetka
  zgradi nacrt, ki dejansko uporabi obstojece indekse (seek namesto scan) - brez potrebe po
  recompile triku in brez njegovega tveganja. Obstojeca val.RunValidation (@OrganizationId/
  @ProductId oba NULL-ni, za polni/organizacijski tek) ostane NESPREMENJENA.

  Kam se ta procedura poklice (naslednji korak, se ni del te migracije): po shranitvi izdelka
  na kartici izdelka in po uvozu iz workbooka - oba dogodka ze obstajata v kodi, zato ne
  potrebujemo novega casovnega urnika.

  POMEMBNO PRED VNOSOM: te skripte se ni testiralo v zivo na tej bazi (uporabnik je zahteval
  samo pregled kode). Priporocilo: pred uporabo v produkciji izmeriti cas enkratnega klica
  EXEC val.RunValidationForProduct @ProductId = 555; v SSMS z omejenim query timeoutom
  (Query > Query Options > Execution > "Execution time-out" na npr. 60s), da se izognemo
  morebitnemu nepricakovanemu obticanju brez nadzora.
*/
SET XACT_ABORT ON;

EXEC(N'
CREATE OR ALTER PROCEDURE val.RunValidationForProduct
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
        AND product.ProductId = @ProductId
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
      AND product.ProductId = @ProductId;

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
