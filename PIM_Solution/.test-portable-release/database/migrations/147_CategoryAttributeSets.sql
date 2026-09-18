/*
  147 — nabor atributov po kategoriji: kateri atributi veljajo za izdelke neke kategorije.

  Uporabnik 2026-09-02: "Pri spletni validaciji je potrebno se dolociti, kateri artikli po
  kategorijah imajo dolocene atribute; samo te bomo prikazovali in samo ti bodo pri izvozu."
  Stari sistem je imel za to pim.CategoryAttributeMap z ravnmi REQUIRED / RECOMMENDED /
  OPTIONAL / EXCLUDED, dedovanjem navzdol in pravilom "najblizji prednik zmaga"
  (docs/specifikacije/Nacrt_Atributi_Po_Kategorijah.md v PIM_test). Tu je isto, brez nove
  logike v programu:

    1. canon.CategoryAttributeSet — vrstica na (drevo, kategorija, atribut) z ravnjo
       REQUIRED, RECOMMENDED ali EXCLUDED. Atribut je stabilna koda iz canon.AttributeDefinition;
       artikli nosijo slovensko ime (canon.AttributeTranslation.Name), zato se povezava dela
       prek imena, kot jo dela canon.FieldValue (ProductAttribute.<ime>).

    2. canon.CategoryAttributeEffective(drevo, kategorija) — ucinkoviti nabor: po verigi
       prednikov navzgor, za vsak atribut obvelja najblizja vrstica. EXCLUDED pri otroku
       razveljavi REQUIRED pri starsu.

    3. Validacija ne dobi novega mehanizma. val.FieldRequirement dobi obseg (CategoryTreeCode,
       CategoryCode): zahteva brez obsega velja za vse izdelke profila (kot doslej), zahteva z
       obsegom pa samo za izdelke, ki so v tisti kategoriji ali pod njo in pri katerih ta
       vrstica se vedno obvelja (ni je prekril EXCLUDED nizje). REQUIRED je zahteva ERROR,
       RECOMMENDED je WARNING. canon.SaveCategoryAttributeSet vrstice zahtev vzdrzuje sama;
       profil je spletni profil drevesa (val.ValidationProfile.CategoryTreeCode iz 146).
       Enolicnost zahteve se zato razsiri z obsegom.

    4. val.RunValidation uposteva obseg. Vse, kar sledi (val.ProductIssue, stanje profila,
       /kakovost, kartica izdelka, pravilo izvoza iz 146), dela nespremenjeno.

    5. out.GetExportRows: kadar kategorija izdelka doloca nabor, gredo v datoteko samo atributi
       iz nabora; izdelek brez nabora obdrzi vse. Kartica izdelka nabor bere prek
       intranet.GetProductAttributeSet, stran kategorij prek intranet.GetCategoryAttributeSet.

  Migrator ne pozna locila GO; procedure so v EXEC(N'...').
*/

SET XACT_ABORT ON;

/* --- 1) Register nabora ------------------------------------------------------------------ */

IF OBJECT_ID(N'canon.CategoryAttributeSet', N'U') IS NULL
BEGIN
  CREATE TABLE canon.CategoryAttributeSet
  (
    CategoryAttributeSetId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_CategoryAttributeSet PRIMARY KEY,
    /* Tipi so enaki kot v canon.Category in canon.AttributeDefinition, sicer tuji kljuc ne nastane (1753). */
    CategoryTreeCode nvarchar(50) NOT NULL,
    CategoryCode nvarchar(200) NOT NULL,
    AttributeCode nvarchar(200) NOT NULL,
    Level nvarchar(20) NOT NULL,
    SortOrder int NOT NULL CONSTRAINT DF_CategoryAttributeSet_SortOrder DEFAULT (100),
    IsActive bit NOT NULL CONSTRAINT DF_CategoryAttributeSet_IsActive DEFAULT (1),
    Note nvarchar(400) NULL,
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_CategoryAttributeSet_UpdatedUtc DEFAULT (SYSUTCDATETIME()),
    UpdatedBy nvarchar(200) NOT NULL CONSTRAINT DF_CategoryAttributeSet_UpdatedBy DEFAULT (N'migracija 147'),
    CONSTRAINT UQ_CategoryAttributeSet UNIQUE (CategoryTreeCode, CategoryCode, AttributeCode),
    CONSTRAINT CK_CategoryAttributeSet_Level CHECK (Level IN (N'REQUIRED', N'RECOMMENDED', N'EXCLUDED')),
    CONSTRAINT FK_CategoryAttributeSet_Category FOREIGN KEY (CategoryTreeCode, CategoryCode)
      REFERENCES canon.Category (CategoryTreeCode, CategoryCode)
  );
END;

/* --- 2) Ucinkoviti nabor po verigi prednikov -------------------------------------------- */

EXEC(N'CREATE OR ALTER FUNCTION canon.CategoryAttributeEffective
  (@CategoryTreeCode nvarchar(100), @CategoryCode nvarchar(200))
RETURNS TABLE
AS
RETURN
(
  WITH chain AS
  (
    SELECT node.CategoryTreeCode, node.CategoryCode, node.ParentCategoryCode, 0 AS Depth
    FROM canon.Category AS node
    WHERE node.CategoryTreeCode = @CategoryTreeCode AND node.CategoryCode = @CategoryCode
    UNION ALL
    SELECT parent.CategoryTreeCode, parent.CategoryCode, parent.ParentCategoryCode, chain.Depth + 1
    FROM chain
    INNER JOIN canon.Category AS parent
      ON parent.CategoryTreeCode = chain.CategoryTreeCode AND parent.CategoryCode = chain.ParentCategoryCode
    WHERE chain.Depth < 12
  ),
  ranked AS
  (
    SELECT setRow.AttributeCode, setRow.Level, setRow.SortOrder, setRow.Note,
      chain.CategoryCode AS DefinedAtCategoryCode, chain.Depth,
      ROW_NUMBER() OVER (PARTITION BY setRow.AttributeCode ORDER BY chain.Depth) AS PickRank
    FROM chain
    INNER JOIN canon.CategoryAttributeSet AS setRow
      ON setRow.CategoryTreeCode = chain.CategoryTreeCode AND setRow.CategoryCode = chain.CategoryCode
     AND setRow.IsActive = 1
  )
  SELECT AttributeCode, Level, SortOrder, Note, DefinedAtCategoryCode, Depth,
    IsInherited = CASE WHEN Depth > 0 THEN CONVERT(bit, 1) ELSE CONVERT(bit, 0) END
  FROM ranked
  WHERE PickRank = 1
)');

/* --- 3) Zahteva z obsegom ----------------------------------------------------------------- */

IF COL_LENGTH(N'val.FieldRequirement', N'CategoryTreeCode') IS NULL
  ALTER TABLE val.FieldRequirement ADD CategoryTreeCode nvarchar(100) NULL, CategoryCode nvarchar(200) NULL;

/* Enolicnost (profil, polje) je bila prava, dokler je zahteva veljala za vse izdelke profila.
   Z obsegom je isti atribut lahko zahtevan v vec kategorijah istega profila. Omejitev se
   nadomesti z razsirjeno; vrstice ostanejo. */
IF EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = N'UQ_FieldRequirement_ProfileField' AND parent_object_id = OBJECT_ID(N'val.FieldRequirement'))
  ALTER TABLE val.FieldRequirement DROP CONSTRAINT UQ_FieldRequirement_ProfileField;
IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = N'UQ_FieldRequirement_ProfileFieldScope' AND parent_object_id = OBJECT_ID(N'val.FieldRequirement'))
  EXEC(N'ALTER TABLE val.FieldRequirement ADD CONSTRAINT UQ_FieldRequirement_ProfileFieldScope UNIQUE (ValidationProfileId, FieldCode, CategoryTreeCode, CategoryCode);');

/* --- 4) Shranjevanje nabora in vzdrzevanje zahtev ---------------------------------------- */

EXEC(N'CREATE OR ALTER PROCEDURE canon.SaveCategoryAttributeSet
  @CategoryTreeCode nvarchar(100),
  @CategoryCode nvarchar(200),
  @AttributeCode nvarchar(200),
  @Level nvarchar(20),          /* REQUIRED | RECOMMENDED | EXCLUDED | NULL = odstrani iz nabora */
  @Actor nvarchar(200),
  @Note nvarchar(400) = NULL
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;

  SET @Level = NULLIF(UPPER(LTRIM(RTRIM(@Level))), N'''');
  SET @Actor = NULLIF(LTRIM(RTRIM(@Actor)), N'''');
  IF @Actor IS NULL THROW 51470, N''Kdo shranjuje nabor, mora biti znano (Actor).'', 1;
  IF @Level IS NOT NULL AND @Level NOT IN (N''REQUIRED'', N''RECOMMENDED'', N''EXCLUDED'')
    THROW 51471, N''Raven mora biti REQUIRED, RECOMMENDED ali EXCLUDED.'', 1;
  IF NOT EXISTS (SELECT 1 FROM canon.Category WHERE CategoryTreeCode = @CategoryTreeCode AND CategoryCode = @CategoryCode)
    THROW 51472, N''Kategorija ne obstaja v tem drevesu.'', 1;
  IF NOT EXISTS (SELECT 1 FROM canon.AttributeDefinition WHERE AttributeCode = @AttributeCode AND IsActive = 1)
    THROW 51473, N''Atribut ne obstaja v registru ali ni aktiven.'', 1;

  DECLARE @ProfileId int =
    (SELECT TOP (1) ValidationProfileId FROM val.ValidationProfile
     WHERE CategoryTreeCode = @CategoryTreeCode AND IsActive = 1 AND BlocksWeb = 1
     ORDER BY ValidationProfileId);
  IF @ProfileId IS NULL THROW 51474, N''Drevo nima spletnega validacijskega profila (val.ValidationProfile.CategoryTreeCode).'', 1;

  /* Zahteva se veze na slovensko ime atributa, ker tako ime nosijo artikli (canon.FieldValue). */
  DECLARE @AttributeName nvarchar(400) =
    COALESCE((SELECT TOP (1) Name FROM canon.AttributeTranslation WHERE AttributeCode = @AttributeCode AND LanguageCode = N''sl''), @AttributeCode);
  DECLARE @FieldCode nvarchar(450) = CONCAT(N''ProductAttribute.'', @AttributeName);

  DECLARE @OldJson nvarchar(max) =
    (SELECT Level, IsActive, Note FROM canon.CategoryAttributeSet
     WHERE CategoryTreeCode = @CategoryTreeCode AND CategoryCode = @CategoryCode AND AttributeCode = @AttributeCode
     FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

  BEGIN TRANSACTION;

  IF @Level IS NULL
  BEGIN
    UPDATE canon.CategoryAttributeSet SET IsActive = 0, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = @Actor, Note = COALESCE(@Note, Note)
    WHERE CategoryTreeCode = @CategoryTreeCode AND CategoryCode = @CategoryCode AND AttributeCode = @AttributeCode;
  END
  ELSE IF EXISTS (SELECT 1 FROM canon.CategoryAttributeSet
                  WHERE CategoryTreeCode = @CategoryTreeCode AND CategoryCode = @CategoryCode AND AttributeCode = @AttributeCode)
  BEGIN
    UPDATE canon.CategoryAttributeSet SET Level = @Level, IsActive = 1, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = @Actor, Note = COALESCE(@Note, Note)
    WHERE CategoryTreeCode = @CategoryTreeCode AND CategoryCode = @CategoryCode AND AttributeCode = @AttributeCode;
  END
  ELSE
  BEGIN
    INSERT canon.CategoryAttributeSet (CategoryTreeCode, CategoryCode, AttributeCode, Level, Note, UpdatedBy)
    VALUES (@CategoryTreeCode, @CategoryCode, @AttributeCode, @Level, @Note, @Actor);
  END;

  /* Zahteva v spletnem profilu drevesa z obsegom te kategorije: REQUIRED = ERROR,
     RECOMMENDED = WARNING, EXCLUDED ali odstranitev = zahteva ugasne. */
  IF @Level IN (N''REQUIRED'', N''RECOMMENDED'')
  BEGIN
    IF EXISTS (SELECT 1 FROM val.FieldRequirement
               WHERE ValidationProfileId = @ProfileId AND FieldCode = @FieldCode
                 AND CategoryTreeCode = @CategoryTreeCode AND CategoryCode = @CategoryCode)
      UPDATE val.FieldRequirement SET IsRequired = 1, IsActive = 1,
        Severity = CASE WHEN @Level = N''REQUIRED'' THEN N''ERROR'' ELSE N''WARNING'' END
      WHERE ValidationProfileId = @ProfileId AND FieldCode = @FieldCode
        AND CategoryTreeCode = @CategoryTreeCode AND CategoryCode = @CategoryCode;
    ELSE
      INSERT val.FieldRequirement (ValidationProfileId, SourceExportColumnId, FieldCode, IsRequired, IsActive, Severity, CategoryTreeCode, CategoryCode)
      VALUES (@ProfileId, NULL, @FieldCode, 1, 1, CASE WHEN @Level = N''REQUIRED'' THEN N''ERROR'' ELSE N''WARNING'' END, @CategoryTreeCode, @CategoryCode);
  END
  ELSE
  BEGIN
    UPDATE val.FieldRequirement SET IsActive = 0
    WHERE ValidationProfileId = @ProfileId AND FieldCode = @FieldCode
      AND CategoryTreeCode = @CategoryTreeCode AND CategoryCode = @CategoryCode;
  END;

  INSERT b2b.AuditLog (OrganizationId, EntityType, EntityKey, ActionCode, OldValueJson, NewValueJson, ChangedBy, ChangedUtc)
  VALUES (0, N''CategoryAttributeSet'', CONCAT(@CategoryTreeCode, N''/'', @CategoryCode, N''/'', @AttributeCode),
    CASE WHEN @Level IS NULL THEN N''REMOVE'' WHEN @OldJson IS NULL THEN N''ADD'' ELSE N''UPDATE'' END,
    @OldJson,
    (SELECT Level, IsActive, Note FROM canon.CategoryAttributeSet
     WHERE CategoryTreeCode = @CategoryTreeCode AND CategoryCode = @CategoryCode AND AttributeCode = @AttributeCode
     FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
    @Actor, SYSUTCDATETIME());

  COMMIT TRANSACTION;
END');

/* --- 5) Validacija z obsegom ------------------------------------------------------------- */

EXEC(N'CREATE OR ALTER PROCEDURE val.RunValidation
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
    WHERE issue.IsActive = 1
      AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
      AND (@ProductId IS NULL OR product.ProductId = @ProductId)
      AND NOT EXISTS
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
      );

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
        ) THEN N''INVALID'' ELSE N''VALID'' END,
        Completeness = ISNULL
        ((
          SELECT MIN(state.Completeness) FROM val.ProductValidationState state
          INNER JOIN val.ValidationProfile profile ON profile.ValidationProfileId = state.ValidationProfileId
          WHERE state.ProductId = product.ProductId AND (profile.BlocksErp = 1 OR profile.BlocksWeb = 1)
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

/* --- 6) Bralna modela ------------------------------------------------------------------- */

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetCategoryAttributeSet
  @CategoryTreeCode nvarchar(100),
  @CategoryCode nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON;

  /* 1 — ucinkoviti nabor kategorije: lastne in podedovane vrstice, s pokritostjo pri izdelkih
     v tej kategoriji in pod njo. */
  ;WITH subtree AS
  (
    SELECT CategoryTreeCode, CategoryCode FROM canon.Category WHERE CategoryTreeCode = @CategoryTreeCode AND CategoryCode = @CategoryCode
    UNION ALL
    SELECT child.CategoryTreeCode, child.CategoryCode FROM subtree
    INNER JOIN canon.Category AS child ON child.CategoryTreeCode = subtree.CategoryTreeCode AND child.ParentCategoryCode = subtree.CategoryCode
  ),
  products AS
  (
    SELECT DISTINCT productCategory.ProductId
    FROM subtree
    INNER JOIN canon.Category AS node ON node.CategoryTreeCode = subtree.CategoryTreeCode AND node.CategoryCode = subtree.CategoryCode
    INNER JOIN canon.WebSite AS site ON site.CategoryTreeCode = node.CategoryTreeCode
    INNER JOIN canon.ProductCategory AS productCategory ON productCategory.WebSite = site.WebSiteCode AND productCategory.CategoryPath = node.CategoryPath
  )
  SELECT effective.AttributeCode,
    AttributeName = COALESCE(translation.Name, effective.AttributeCode),
    effective.Level, effective.SortOrder, effective.Note, effective.DefinedAtCategoryCode, effective.IsInherited,
    DefinedAtCategoryName = definedAt.CategoryName,
    ProductCount = (SELECT COUNT(*) FROM products),
    ProductsWithValue = (SELECT COUNT(*) FROM products
      WHERE EXISTS (SELECT 1 FROM canon.ProductAttribute AS attributeValue
                    WHERE attributeValue.ProductId = products.ProductId
                      AND attributeValue.AttributeCode = COALESCE(translation.Name, effective.AttributeCode)
                      AND NULLIF(attributeValue.Value, N'''') IS NOT NULL))
  FROM canon.CategoryAttributeEffective(@CategoryTreeCode, @CategoryCode) AS effective
  LEFT JOIN canon.AttributeTranslation AS translation ON translation.AttributeCode = effective.AttributeCode AND translation.LanguageCode = N''sl''
  LEFT JOIN canon.Category AS definedAt ON definedAt.CategoryTreeCode = @CategoryTreeCode AND definedAt.CategoryCode = effective.DefinedAtCategoryCode
  ORDER BY CASE effective.Level WHEN N''REQUIRED'' THEN 0 WHEN N''RECOMMENDED'' THEN 1 ELSE 2 END, effective.SortOrder, AttributeName;

  /* 2 — atributi, ki jih izdelki te kategorije dejansko nosijo, a jih nabor ne omenja:
     predlog, kaj dodati. */
  ;WITH subtree AS
  (
    SELECT CategoryTreeCode, CategoryCode FROM canon.Category WHERE CategoryTreeCode = @CategoryTreeCode AND CategoryCode = @CategoryCode
    UNION ALL
    SELECT child.CategoryTreeCode, child.CategoryCode FROM subtree
    INNER JOIN canon.Category AS child ON child.CategoryTreeCode = subtree.CategoryTreeCode AND child.ParentCategoryCode = subtree.CategoryCode
  ),
  products AS
  (
    SELECT DISTINCT productCategory.ProductId
    FROM subtree
    INNER JOIN canon.Category AS node ON node.CategoryTreeCode = subtree.CategoryTreeCode AND node.CategoryCode = subtree.CategoryCode
    INNER JOIN canon.WebSite AS site ON site.CategoryTreeCode = node.CategoryTreeCode
    INNER JOIN canon.ProductCategory AS productCategory ON productCategory.WebSite = site.WebSiteCode AND productCategory.CategoryPath = node.CategoryPath
  )
  SELECT TOP (60)
    AttributeCode = COALESCE(definition.AttributeCode, attributeValue.AttributeCode),
    AttributeName = attributeValue.AttributeCode,
    ProductsWithValue = COUNT(DISTINCT attributeValue.ProductId),
    InRegister = CASE WHEN definition.AttributeCode IS NULL THEN CONVERT(bit, 0) ELSE CONVERT(bit, 1) END
  FROM products
  INNER JOIN canon.ProductAttribute AS attributeValue ON attributeValue.ProductId = products.ProductId
  LEFT JOIN canon.AttributeTranslation AS translation ON translation.LanguageCode = N''sl'' AND translation.Name = attributeValue.AttributeCode
  LEFT JOIN canon.AttributeDefinition AS definition ON definition.AttributeCode = COALESCE(translation.AttributeCode, attributeValue.AttributeCode) AND definition.IsActive = 1
  WHERE NULLIF(attributeValue.Value, N'''') IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM canon.CategoryAttributeEffective(@CategoryTreeCode, @CategoryCode) AS effective
                    WHERE effective.AttributeCode = COALESCE(definition.AttributeCode, attributeValue.AttributeCode))
  GROUP BY COALESCE(definition.AttributeCode, attributeValue.AttributeCode), attributeValue.AttributeCode, definition.AttributeCode
  ORDER BY COUNT(DISTINCT attributeValue.ProductId) DESC, attributeValue.AttributeCode;
END');

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetProductAttributeSet
  @ProductId bigint
AS
BEGIN
  SET NOCOUNT ON;
  /* Ucinkoviti nabor za izdelek: unija naborov vseh njegovih kategorij (po straneh), najblizja
     vrstica na atribut. Kartica s tem pove, kateri atributi sodijo k izdelku in kateri manjkajo. */
  ;WITH assigned AS
  (
    SELECT DISTINCT node.CategoryTreeCode, node.CategoryCode, node.CategoryName, node.ParentCategoryCode
    FROM canon.ProductCategory AS productCategory
    INNER JOIN canon.WebSite AS site ON site.WebSiteCode = productCategory.WebSite
    INNER JOIN canon.Category AS node ON node.CategoryTreeCode = site.CategoryTreeCode AND node.CategoryPath = productCategory.CategoryPath
    WHERE productCategory.ProductId = @ProductId
  )
  SELECT effective.AttributeCode,
    AttributeName = COALESCE(translation.Name, effective.AttributeCode),
    effective.Level, effective.IsInherited, assigned.CategoryTreeCode, assigned.CategoryCode, assigned.CategoryName,
    HasValue = CASE WHEN EXISTS (SELECT 1 FROM canon.ProductAttribute AS attributeValue
      WHERE attributeValue.ProductId = @ProductId AND attributeValue.AttributeCode = COALESCE(translation.Name, effective.AttributeCode)
        AND NULLIF(attributeValue.Value, N'''') IS NOT NULL) THEN CONVERT(bit, 1) ELSE CONVERT(bit, 0) END
  FROM assigned
  CROSS APPLY canon.CategoryAttributeEffective(assigned.CategoryTreeCode, assigned.CategoryCode) AS effective
  LEFT JOIN canon.AttributeTranslation AS translation ON translation.AttributeCode = effective.AttributeCode AND translation.LanguageCode = N''sl''
  ORDER BY CASE effective.Level WHEN N''REQUIRED'' THEN 0 WHEN N''RECOMMENDED'' THEN 1 ELSE 2 END, effective.SortOrder, AttributeName;
END');

/* --- 7) Izvoz uposteva nabor ------------------------------------------------------------- */

EXEC(N'CREATE OR ALTER PROCEDURE out.GetExportRows
  @OrganizationId int,
  @ExportProfileId int,
  @WebSite nvarchar(100) = NULL,
  @OnlyPublished bit = 1,
  @Search nvarchar(200) = NULL,
  @Skip int = 0,
  @Take int = 200,
  @TotalCount int OUTPUT
AS
BEGIN
  SET NOCOUNT ON;

  IF @Skip < 0 THROW 52970, N''Odmik izvoza ne sme biti negativen.'', 1;
  IF @Take < 0 THROW 52971, N''Velikost strani izvoza ne sme biti negativna.'', 1;
  IF NOT EXISTS (SELECT 1 FROM dbo.OrganizationConfig WHERE OrganizationId = @OrganizationId)
    THROW 52972, N''Organizacija za izvoz ne obstaja.'', 1;

  DECLARE @EntityType nvarchar(200), @ProfileCode nvarchar(200), @ValueSource nvarchar(40), @RequireWebValid bit;
  SELECT @EntityType = EntityType, @ProfileCode = ProfileCode, @ValueSource = ValueSourceCode, @RequireWebValid = RequireWebValid
  FROM out.ExportProfile
  WHERE ExportProfileId = @ExportProfileId AND IsActive = 1;

  IF @ProfileCode IS NULL THROW 52973, N''Aktivni izvozni profil ne obstaja.'', 1;
  IF NOT EXISTS (SELECT 1 FROM out.ExportColumn WHERE ExportProfileId = @ExportProfileId AND IsActive = 1)
    THROW 52974, N''Izvozni profil nima aktivnih stolpcev.'', 1;

  SET @WebSite = NULLIF(LTRIM(RTRIM(@WebSite)), N'''');
  SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'''');
  DECLARE @SearchLike nvarchar(410) = CASE WHEN @Search IS NULL THEN NULL ELSE
    N''%'' + REPLACE(REPLACE(REPLACE(@Search, N''['', N''[[]''), N''%'', N''[%]''), N''_'', N''[_]'') + N''%'' END;

  DECLARE @Fetch bigint = CASE WHEN @Take = 0 THEN 2147483647 ELSE @Take END;

  CREATE TABLE #Page
    (RowKey nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY, EntityId bigint NOT NULL);
  CREATE TABLE #Value
    (RowKey nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
     FieldCode nvarchar(450) COLLATE DATABASE_DEFAULT NOT NULL,
     Value nvarchar(max) COLLATE DATABASE_DEFAULT NULL);

  /* ============================================================================
     A) KANONICNI VIR — nespremenjeno od 142.
     ============================================================================ */
  IF @ValueSource = N''CANON''
  BEGIN
    IF UPPER(@EntityType) NOT IN (N''PRODUCT'', N''PRODUCTS'')
      THROW 52975, N''Kanonicni izvoz na zahtevo podpira samo produktne profile.'', 1;

    SELECT @TotalCount = COUNT(*)
    FROM canon.Product AS product
    WHERE product.OrganizationId = @OrganizationId
      AND (@OnlyPublished = 0 OR product.WebPublish = 1)
      AND (@WebSite IS NULL OR EXISTS
        (SELECT 1 FROM canon.ProductCategory AS category
         WHERE category.ProductId = product.ProductId AND category.WebSite = @WebSite))
      AND (@SearchLike IS NULL
        OR product.ItemID LIKE @SearchLike
        OR product.EAN LIKE @SearchLike
        OR EXISTS
          (SELECT 1 FROM canon.ProductText AS textValue
           WHERE textValue.ProductId = product.ProductId AND textValue.Value LIKE @SearchLike));

    INSERT #Page (RowKey, EntityId)
    SELECT product.ItemID, product.ProductId
    FROM canon.Product AS product
    WHERE product.OrganizationId = @OrganizationId
      AND (@OnlyPublished = 0 OR product.WebPublish = 1)
      AND (@WebSite IS NULL OR EXISTS
        (SELECT 1 FROM canon.ProductCategory AS category
         WHERE category.ProductId = product.ProductId AND category.WebSite = @WebSite))
      AND (@SearchLike IS NULL
        OR product.ItemID LIKE @SearchLike
        OR product.EAN LIKE @SearchLike
        OR EXISTS
          (SELECT 1 FROM canon.ProductText AS textValue
           WHERE textValue.ProductId = product.ProductId AND textValue.Value LIKE @SearchLike))
    ORDER BY product.ItemID
    OFFSET @Skip ROWS FETCH NEXT @Fetch ROWS ONLY;

    INSERT #Value (RowKey, FieldCode, Value)
    SELECT source.RowKey, source.FieldCode,
      STRING_AGG(CONVERT(nvarchar(max), source.Value), N'' | '') WITHIN GROUP (ORDER BY source.Value)
    FROM
    (
      SELECT page.RowKey, fieldValue.FieldCode, fieldValue.Value
      FROM canon.FieldValue AS fieldValue
      INNER JOIN #Page AS page ON page.EntityId = fieldValue.ProductId
      WHERE fieldValue.FieldCode <> N''ProductCategory.CategoryPath''
        AND EXISTS (SELECT 1 FROM out.ExportColumn AS registryColumn
                    WHERE registryColumn.ExportProfileId = @ExportProfileId
                      AND registryColumn.IsActive = 1
                      AND registryColumn.CanonicalFieldCode = fieldValue.FieldCode)
      UNION ALL
      SELECT page.RowKey, N''ProductCategory.CategoryPath'', category.CategoryPath
      FROM canon.ProductCategory AS category
      INNER JOIN #Page AS page ON page.EntityId = category.ProductId
      WHERE EXISTS (SELECT 1 FROM out.ExportColumn AS registryColumn
                    WHERE registryColumn.ExportProfileId = @ExportProfileId
                      AND registryColumn.IsActive = 1
                      AND registryColumn.CanonicalFieldCode = N''ProductCategory.CategoryPath'')
        AND (@WebSite IS NULL OR category.WebSite = @WebSite)
    ) AS source
    WHERE NULLIF(source.Value, N'''') IS NOT NULL
    GROUP BY source.RowKey, source.FieldCode;
  END

  /* ============================================================================
     B) IZDELKI ZA MAGENTO — vir je sloj pim.*, s pravili spletne strani in veljavnosti.
     ============================================================================ */
  ELSE IF @ValueSource = N''PIM_PRODUCT''
  BEGIN
    /* B0) Katere strani so za kateri izdelek dovoljene.
       Stran S je dovoljena, ce ima izdelek kategorijo na S (pravilo "prazen stolpec = ne gre")
       in — kadar profil zahteva veljavnost — ce je izdelek objavljen ter VALID v vseh profilih,
       ki blokirajo splet in veljajo za S (brez drevesa = vse strani, z drevesom = samo S). */
    CREATE TABLE #Site
      (PimProductId bigint NOT NULL, WebSite nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
       PRIMARY KEY (PimProductId, WebSite));

    INSERT #Site (PimProductId, WebSite)
    SELECT DISTINCT category.PimProductId, category.WebSite
    FROM pim.ProductCategory AS category
    INNER JOIN pim.Product AS product ON product.PimProductId = category.PimProductId
    INNER JOIN canon.WebSite AS site ON site.WebSiteCode = category.WebSite AND site.IsActive = 1
    LEFT JOIN canon.Product AS canonProduct
      ON canonProduct.OrganizationId = product.OrganizationId AND canonProduct.ItemID = product.ItemID
    WHERE product.OrganizationId = @OrganizationId
      AND (@WebSite IS NULL OR category.WebSite = @WebSite)
      AND (@OnlyPublished = 0 OR canonProduct.WebPublish = 1)
      AND
      (
        @RequireWebValid = 0
        OR
        (
          canonProduct.WebPublish = 1
          AND NOT EXISTS
          (
            SELECT 1
            FROM val.ValidationProfile AS profile
            LEFT JOIN val.ProductValidationState AS state
              ON state.ProductId = canonProduct.ProductId AND state.ValidationProfileId = profile.ValidationProfileId
            WHERE profile.IsActive = 1 AND profile.BlocksWeb = 1
              AND (profile.CategoryTreeCode IS NULL OR profile.CategoryTreeCode = site.CategoryTreeCode)
              AND ISNULL(state.Status, N''INVALID'') <> N''VALID''
          )
        )
      );

    SELECT @TotalCount = COUNT(*)
    FROM pim.Product AS product
    WHERE product.OrganizationId = @OrganizationId
      AND EXISTS (SELECT 1 FROM #Site AS site WHERE site.PimProductId = product.PimProductId)
      AND (@SearchLike IS NULL
        OR product.ItemID LIKE @SearchLike
        OR product.EAN LIKE @SearchLike
        OR product.Name LIKE @SearchLike
        OR EXISTS
          (SELECT 1 FROM pim.ProductText AS textValue
           WHERE textValue.PimProductId = product.PimProductId AND textValue.Value LIKE @SearchLike));

    INSERT #Page (RowKey, EntityId)
    SELECT product.ItemID, product.PimProductId
    FROM pim.Product AS product
    WHERE product.OrganizationId = @OrganizationId
      AND EXISTS (SELECT 1 FROM #Site AS site WHERE site.PimProductId = product.PimProductId)
      AND (@SearchLike IS NULL
        OR product.ItemID LIKE @SearchLike
        OR product.EAN LIKE @SearchLike
        OR product.Name LIKE @SearchLike
        OR EXISTS
          (SELECT 1 FROM pim.ProductText AS textValue
           WHERE textValue.PimProductId = product.PimProductId AND textValue.Value LIKE @SearchLike))
    ORDER BY product.ItemID
    OFFSET @Skip ROWS FETCH NEXT @Fetch ROWS ONLY;

    /* --- B1) Osnovna polja, trgovinski podatki, popust polnega pakiranja in cene --- */
    INSERT #Value (RowKey, FieldCode, Value)
    SELECT core.RowKey, field.FieldCode, field.Value
    FROM
    (
      SELECT
        page.RowKey,
        product.EAN, product.Name, product.Manufacturer, product.Supplier, product.UoM,
        commercial.CustomsTariff, commercial.CountryOfOrigin, commercial.DimensionUnit,
        commercial.GrossWeight, commercial.NetWeight, commercial.Pak1, commercial.Pak2,
        commercial.Volume, commercial.PackageLength, commercial.PackageWidth, commercial.PackageHeight,
        packaging.DiscountCode AS PackagingDiscountCode,
        discountCatalog.PercentValue AS PackagingDiscountPercent,
        priceB2b.Net AS PriceB2B,
        priceB2c.Net AS PriceB2C,
        COALESCE(priceB2b.VatRate, priceB2c.VatRate, priceAny.VatRate) AS VatRate
      FROM #Page AS page
      INNER JOIN pim.Product AS product ON product.PimProductId = page.EntityId
      LEFT JOIN pim.ProductCommercial AS commercial ON commercial.PimProductId = product.PimProductId
      LEFT JOIN pim.ProductPackagingDiscount AS packaging ON packaging.PimProductId = product.PimProductId
      LEFT JOIN pim.PackagingDiscountCatalog AS discountCatalog
        ON discountCatalog.DiscountCode = packaging.DiscountCode AND discountCatalog.IsActive = 1
      LEFT JOIN
      (
        SELECT price.PimProductId, price.Net, price.VatRate,
          ROW_NUMBER() OVER (PARTITION BY price.PimProductId ORDER BY registry.SortOrder, price.ValidFrom DESC) AS PickRank
        FROM pim.ProductPrice AS price
        INNER JOIN out.ExportPriceList AS registry
          ON registry.PriceListCode = price.PriceList AND registry.OrganizationId = @OrganizationId
          AND registry.PriceFieldCode = N''Product.PriceB2B'' AND registry.IsActive = 1
        WHERE price.IsActive = 1 AND price.ValidFrom <= SYSUTCDATETIME()
      ) AS priceB2b ON priceB2b.PimProductId = product.PimProductId AND priceB2b.PickRank = 1
      LEFT JOIN
      (
        SELECT price.PimProductId, price.Net, price.VatRate,
          ROW_NUMBER() OVER (PARTITION BY price.PimProductId ORDER BY registry.SortOrder, price.ValidFrom DESC) AS PickRank
        FROM pim.ProductPrice AS price
        INNER JOIN out.ExportPriceList AS registry
          ON registry.PriceListCode = price.PriceList AND registry.OrganizationId = @OrganizationId
          AND registry.PriceFieldCode = N''Product.PriceB2C'' AND registry.IsActive = 1
        WHERE price.IsActive = 1 AND price.ValidFrom <= SYSUTCDATETIME()
      ) AS priceB2c ON priceB2c.PimProductId = product.PimProductId AND priceB2c.PickRank = 1
      LEFT JOIN
      (
        SELECT PimProductId, VatRate,
          ROW_NUMBER() OVER (PARTITION BY PimProductId ORDER BY ValidFrom DESC) AS PickRank
        FROM pim.ProductPrice WHERE IsActive = 1 AND ValidFrom <= SYSUTCDATETIME()
      ) AS priceAny ON priceAny.PimProductId = product.PimProductId AND priceAny.PickRank = 1
    ) AS core
    CROSS APPLY
    (
      VALUES
        (N''Product.ItemID'', CONVERT(nvarchar(max), core.RowKey)),
        (N''Product.EAN'', CONVERT(nvarchar(max), core.EAN)),
        (N''Product.ErpTitleSl'', CONVERT(nvarchar(max), core.Name)),
        (N''Product.Manufacturer'', CONVERT(nvarchar(max), core.Manufacturer)),
        (N''Product.Supplier'', CONVERT(nvarchar(max), core.Supplier)),
        (N''Product.UoM'', CONVERT(nvarchar(max), core.UoM)),
        (N''Product.CustomsTariff'', CONVERT(nvarchar(max), core.CustomsTariff)),
        (N''Product.CountryOfOrigin'', CONVERT(nvarchar(max), core.CountryOfOrigin)),
        (N''Product.GrossWeight'', CONVERT(nvarchar(max), out.MagentoNumber(core.GrossWeight))),
        (N''Product.NetWeight'', CONVERT(nvarchar(max), out.MagentoNumber(core.NetWeight))),
        (N''Product.Pak1'', CONVERT(nvarchar(max), out.MagentoNumber(core.Pak1))),
        (N''Product.Pak2'', CONVERT(nvarchar(max), out.MagentoNumber(core.Pak2))),
        (N''Product.Volume'', CONVERT(nvarchar(max), out.MagentoNumber(core.Volume))),
        (N''Product.PackageLength'', CONVERT(nvarchar(max), out.MagentoNumber(core.PackageLength))),
        (N''Product.PackageWidth'', CONVERT(nvarchar(max), out.MagentoNumber(core.PackageWidth))),
        (N''Product.PackageHeight'', CONVERT(nvarchar(max), out.MagentoNumber(core.PackageHeight))),
        (N''Product.DimensionUnit'', CONVERT(nvarchar(max), core.DimensionUnit)),
        (N''Product.PackagingDiscountCode'', CONVERT(nvarchar(max), core.PackagingDiscountCode)),
        (N''Product.PackagingDiscountPercent'', CONVERT(nvarchar(max), out.MagentoNumber(core.PackagingDiscountPercent))),
        (N''Product.PriceB2B'', CONVERT(nvarchar(max), out.MagentoNumber(core.PriceB2B))),
        (N''Product.PriceB2C'', CONVERT(nvarchar(max), out.MagentoNumber(core.PriceB2C))),
        (N''Product.VatRate'', CONVERT(nvarchar(max), out.MagentoNumber(core.VatRate)))
    ) AS field (FieldCode, Value)
    WHERE field.Value IS NOT NULL;

    /* --- B2) Besedila: spletni naziv in angleski ERP naziv --- */
    INSERT #Value (RowKey, FieldCode, Value)
    SELECT page.RowKey,
      CASE
        WHEN textValue.TextType = N''WEB_TITLE'' AND textValue.Lang = N''en'' THEN N''Product.WebTitleEn''
        WHEN textValue.TextType = N''WEB_TITLE'' AND textValue.Lang = N''sl'' THEN N''Product.WebTitleSl''
        ELSE N''Product.ErpTitleEn''
      END,
      textValue.Value
    FROM #Page AS page
    INNER JOIN pim.ProductText AS textValue ON textValue.PimProductId = page.EntityId
    WHERE (textValue.TextType = N''WEB_TITLE'' AND textValue.Lang IN (N''en'', N''sl''))
       OR (textValue.TextType = N''TITLE_ERP'' AND textValue.Lang = N''en'');

    /* --- B3) Mediji: prva slika z glavno vlogo je glavna, vse ostale so dodatne --- */
    CREATE TABLE #Media
      (RowKey nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
       Url nvarchar(4000) COLLATE DATABASE_DEFAULT NOT NULL,
       Ordinal int NOT NULL, IsPrimary bit NOT NULL);

    INSERT #Media (RowKey, Url, Ordinal, IsPrimary)
    SELECT page.RowKey, media.Url,
      ROW_NUMBER() OVER (PARTITION BY page.RowKey ORDER BY media.SortOrder, media.PimProductMediaId),
      CASE WHEN UPPER(media.Role) IN (N''PRIMARY'', N''MAIN'') THEN 1 ELSE 0 END
    FROM #Page AS page
    INNER JOIN pim.ProductMedia AS media ON media.PimProductId = page.EntityId;

    INSERT #Value (RowKey, FieldCode, Value)
    SELECT media.RowKey, N''Product.MainImage'', CONVERT(nvarchar(max), media.Url)
    FROM #Media AS media
    WHERE media.Ordinal = (SELECT MIN(first.Ordinal) FROM #Media AS first
                           WHERE first.RowKey = media.RowKey AND first.IsPrimary = 1);

    INSERT #Value (RowKey, FieldCode, Value)
    SELECT media.RowKey, N''Product.OtherImages'',
      STRING_AGG(CONVERT(nvarchar(max), media.Url), N''|'') WITHIN GROUP (ORDER BY media.Ordinal)
    FROM #Media AS media
    WHERE media.Ordinal <> ISNULL((SELECT MIN(first.Ordinal) FROM #Media AS first
                                   WHERE first.RowKey = media.RowKey AND first.IsPrimary = 1), -1)
    GROUP BY media.RowKey;

    /* --- B4) Spletna mesta in kategorije: samo strani, za katere je izdelek dovoljen --- */
    CREATE TABLE #Category
      (RowKey nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
       WebSite nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
       CategoryPath nvarchar(2000) COLLATE DATABASE_DEFAULT NOT NULL);

    INSERT #Category (RowKey, WebSite, CategoryPath)
    SELECT page.RowKey, category.WebSite, category.CategoryPath
    FROM #Page AS page
    INNER JOIN pim.ProductCategory AS category ON category.PimProductId = page.EntityId
    INNER JOIN #Site AS site ON site.PimProductId = category.PimProductId AND site.WebSite = category.WebSite;

    INSERT #Value (RowKey, FieldCode, Value)
    SELECT site.RowKey, N''Product.WebSites'',
      STRING_AGG(CONVERT(nvarchar(max), site.WebSite), N''|'') WITHIN GROUP (ORDER BY site.WebSite)
    FROM (SELECT DISTINCT RowKey, WebSite FROM #Category) AS site
    GROUP BY site.RowKey;

    INSERT #Value (RowKey, FieldCode, Value)
    SELECT path.RowKey, path.CategoryFieldCode,
      STRING_AGG(CONVERT(nvarchar(max), path.CategoryPath), N''|'') WITHIN GROUP (ORDER BY path.FirstSite, path.CategoryPath)
    FROM
    (
      SELECT category.RowKey, site.CategoryFieldCode, category.CategoryPath, MIN(category.WebSite) AS FirstSite
      FROM #Category AS category
      INNER JOIN canon.WebSite AS site ON site.WebSiteCode = category.WebSite AND site.IsActive = 1
      WHERE NULLIF(category.CategoryPath, N'''') IS NOT NULL
      GROUP BY category.RowKey, site.CategoryFieldCode, category.CategoryPath
    ) AS path
    GROUP BY path.RowKey, path.CategoryFieldCode;

    /* --- B5) Lastnosti izdelka --- */
    CREATE TABLE #Attribute
      (RowKey nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
       AttributeCode nvarchar(400) COLLATE DATABASE_DEFAULT NOT NULL,
       LanguageCode nvarchar(20) COLLATE DATABASE_DEFAULT NULL,
       Value nvarchar(max) COLLATE DATABASE_DEFAULT NULL, AttributeId bigint NOT NULL);

    /* 147: nabor atributov po kategoriji. Ce katera od dovoljenih kategorij izdelka (ali njen
       prednik) doloca nabor, gredo v izvoz samo atributi iz nabora (REQUIRED/RECOMMENDED);
       EXCLUDED izpade. Izdelek brez dolocenega nabora obdrzi vse atribute — nabor je
       filter, ne pogoj. Ime atributa v pim.ProductAttribute je slovensko ime registra. */
    CREATE TABLE #AttributeFilter
      (PimProductId bigint NOT NULL, AttributeName nvarchar(400) COLLATE DATABASE_DEFAULT NOT NULL,
       Level nvarchar(20) COLLATE DATABASE_DEFAULT NOT NULL);

    INSERT #AttributeFilter (PimProductId, AttributeName, Level)
    SELECT DISTINCT page.EntityId, COALESCE(translation.Name, effective.AttributeCode), effective.Level
    FROM #Page AS page
    INNER JOIN #Site AS site ON site.PimProductId = page.EntityId
    INNER JOIN pim.ProductCategory AS category ON category.PimProductId = page.EntityId AND category.WebSite = site.WebSite
    INNER JOIN canon.WebSite AS webSite ON webSite.WebSiteCode = category.WebSite
    INNER JOIN canon.Category AS node
      ON node.CategoryTreeCode = webSite.CategoryTreeCode AND node.CategoryPath = category.CategoryPath
    CROSS APPLY canon.CategoryAttributeEffective(node.CategoryTreeCode, node.CategoryCode) AS effective
    LEFT JOIN canon.AttributeTranslation AS translation
      ON translation.AttributeCode = effective.AttributeCode AND translation.LanguageCode = N''sl'';

    INSERT #Attribute (RowKey, AttributeCode, LanguageCode, Value, AttributeId)
    SELECT page.RowKey, attribute.AttributeCode, attribute.LanguageCode, attribute.Value, attribute.PimProductAttributeId
    FROM #Page AS page
    INNER JOIN pim.ProductAttribute AS attribute ON attribute.PimProductId = page.EntityId
    WHERE NOT EXISTS (SELECT 1 FROM #AttributeFilter AS filter
                      WHERE filter.PimProductId = page.EntityId AND filter.Level <> N''EXCLUDED'')
       OR EXISTS (SELECT 1 FROM #AttributeFilter AS filter
                  WHERE filter.PimProductId = page.EntityId AND filter.Level <> N''EXCLUDED''
                    AND filter.AttributeName = attribute.AttributeCode);

    INSERT #Value (RowKey, FieldCode, Value)
    SELECT picked.RowKey, N''Attr.'' + picked.AttributeCode, picked.Value
    FROM
    (
      SELECT RowKey, AttributeCode, Value,
        ROW_NUMBER() OVER (PARTITION BY RowKey, AttributeCode ORDER BY AttributeId DESC) AS PickRank
      FROM #Attribute
    ) AS picked
    WHERE picked.PickRank = 1;

    INSERT #Value (RowKey, FieldCode, Value)
    SELECT RowKey,
      N''Attr.'' + AttributeCode + N'' '' + CASE LanguageCode WHEN N''sl'' THEN N''SLO'' ELSE N''ANG'' END,
      Value
    FROM #Attribute
    WHERE LanguageCode IN (N''sl'', N''en'');

    /* --- B6) Zaloga: iz registra out.ExportStockSource, sesteta po sifri artikla --- */
    CREATE TABLE #Stock
      (RowKey nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
       Contribution nvarchar(20) COLLATE DATABASE_DEFAULT NOT NULL,
       Quantity decimal(19,4) NULL, Available decimal(19,4) NULL, Ordered decimal(19,4) NULL,
       ForShipment decimal(19,4) NULL, SupplierOrdered decimal(19,4) NULL,
       Incoming decimal(19,4) NULL, AvailabilityDate date NULL);

    INSERT #Stock (RowKey, Contribution, Quantity, Available, Ordered, ForShipment, SupplierOrdered, Incoming, AvailabilityDate)
    SELECT page.RowKey, registry.Contribution,
      position.Quantity,
      COALESCE(position.AvailableQuantity, position.Quantity),
      position.OrderedQuantity, position.ForShipmentQuantity, position.SupplierOrderedQuantity,
      position.IncomingQuantity, position.AvailabilityDate
    FROM out.ExportStockSource AS registry
    INNER JOIN map.SourceConnector AS connector
      ON connector.OrganizationId = registry.StockOrganizationId AND connector.SourceCode = registry.SourceCode
    INNER JOIN stock.Snapshot AS snapshot
      ON snapshot.SourceConnectorId = connector.SourceConnectorId AND snapshot.IsActive = 1
    INNER JOIN stock.Position AS position ON position.SnapshotId = snapshot.SnapshotId
    INNER JOIN canon.Product AS stockProduct ON stockProduct.ProductId = position.MatchedProductId
    INNER JOIN #Page AS page ON page.RowKey = stockProduct.ItemID
    WHERE registry.OrganizationId = @OrganizationId AND registry.IsActive = 1;

    INSERT #Value (RowKey, FieldCode, Value)
    SELECT erp.RowKey, field.FieldCode, field.Value
    FROM
    (
      SELECT RowKey,
        /* Splet ne prodaja minusa: negativna ERP zaloga gre ven kot 0. */
        Quantity = CASE WHEN SUM(Quantity) < 0 THEN 0 ELSE SUM(Quantity) END,
        Available = CASE WHEN SUM(Available) < 0 THEN 0 ELSE SUM(Available) END,
        Ordered = SUM(Ordered), ForShipment = SUM(ForShipment), SupplierOrdered = SUM(SupplierOrdered)
      FROM #Stock
      WHERE Contribution IN (N''BASE'', N''ADD'')
      GROUP BY RowKey
    ) AS erp
    CROSS APPLY
    (
      VALUES
        (N''Stock.ErpCurrent'', out.MagentoNumber(erp.Quantity)),
        (N''Stock.ErpAvailable'', out.MagentoNumber(erp.Available)),
        (N''Stock.ErpOrdered'', out.MagentoNumber(erp.Ordered)),
        (N''Stock.ErpForShipment'', out.MagentoNumber(erp.ForShipment)),
        (N''Stock.ErpSupplierOrdered'', out.MagentoNumber(erp.SupplierOrdered))
    ) AS field (FieldCode, Value)
    WHERE field.Value IS NOT NULL;

    INSERT #Value (RowKey, FieldCode, Value)
    SELECT supplier.RowKey, field.FieldCode, field.Value
    FROM
    (
      SELECT RowKey,
        Quantity = SUM(Quantity), Incoming = SUM(Incoming), AvailabilityDate = MIN(AvailabilityDate)
      FROM #Stock
      WHERE Contribution = N''SUPPLIER''
      GROUP BY RowKey
    ) AS supplier
    CROSS APPLY
    (
      VALUES
        (N''Stock.SupplierQuantity'', out.MagentoNumber(supplier.Quantity)),
        (N''Stock.SupplierIncoming'', out.MagentoNumber(supplier.Incoming)),
        /* Oblika dd.MM.yyyy je pogodba iz starega izvoza (CONVERT 104). */
        (N''Stock.SupplierDate'', CONVERT(nvarchar(10), supplier.AvailabilityDate, 104))
    ) AS field (FieldCode, Value)
    WHERE field.Value IS NOT NULL;

    /* Skladisce: oznake ERP virov iz registra, v vrstnem redu registra, samo kadar je izdelek
       v tistem posnetku sploh prisoten. */
    INSERT #Value (RowKey, FieldCode, Value)
    SELECT labels.RowKey, N''Stock.Warehouse'',
      STRING_AGG(CONVERT(nvarchar(max), labels.WarehouseLabel), N'' + '') WITHIN GROUP (ORDER BY labels.SortOrder)
    FROM
    (
      SELECT DISTINCT page.RowKey, registry.WarehouseLabel, registry.SortOrder
      FROM out.ExportStockSource AS registry
      INNER JOIN map.SourceConnector AS connector
        ON connector.OrganizationId = registry.StockOrganizationId AND connector.SourceCode = registry.SourceCode
      INNER JOIN stock.Snapshot AS snapshot
        ON snapshot.SourceConnectorId = connector.SourceConnectorId AND snapshot.IsActive = 1
      INNER JOIN stock.Position AS position ON position.SnapshotId = snapshot.SnapshotId
      INNER JOIN canon.Product AS stockProduct ON stockProduct.ProductId = position.MatchedProductId
      INNER JOIN #Page AS page ON page.RowKey = stockProduct.ItemID
      WHERE registry.OrganizationId = @OrganizationId AND registry.IsActive = 1
        AND registry.Contribution IN (N''BASE'', N''ADD'') AND NULLIF(registry.WarehouseLabel, N'''') IS NOT NULL
    ) AS labels
    GROUP BY labels.RowKey;
  END

  /* ============================================================================
     C) STRANKE ZA MAGENTO — nespremenjeno od 142.
     ============================================================================ */
  ELSE IF @ValueSource = N''PIM_CUSTOMER''
  BEGIN
    SELECT @TotalCount = COUNT(*)
    FROM b2b.Customer AS customer
    INNER JOIN pim.CustomerWebProfile AS profile ON profile.CustomerId = customer.CustomerId
    WHERE customer.OrganizationId = @OrganizationId
      AND (@OnlyPublished = 0 OR profile.WebEnabled = 1)
      AND (@SearchLike IS NULL OR customer.CustomerKey LIKE @SearchLike OR customer.Name LIKE @SearchLike);

    INSERT #Page (RowKey, EntityId)
    SELECT customer.CustomerKey, customer.CustomerId
    FROM b2b.Customer AS customer
    INNER JOIN pim.CustomerWebProfile AS profile ON profile.CustomerId = customer.CustomerId
    WHERE customer.OrganizationId = @OrganizationId
      AND (@OnlyPublished = 0 OR profile.WebEnabled = 1)
      AND (@SearchLike IS NULL OR customer.CustomerKey LIKE @SearchLike OR customer.Name LIKE @SearchLike)
    ORDER BY customer.CustomerKey
    OFFSET @Skip ROWS FETCH NEXT @Fetch ROWS ONLY;

    INSERT #Value (RowKey, FieldCode, Value)
    SELECT core.RowKey, field.FieldCode, field.Value
    FROM
    (
      SELECT
        page.RowKey, customer.Name, magentoGroup.MagentoGroupKey, customer.PriceListCode,
        customer.PayerCode, customer.PayerName,
        profile.PackagingDiscountEnabled, profile.ValueDiscountEnabled,
        CONVERT(bit, CASE WHEN profile.B2bPlusEnabled = 1
          AND (profile.B2bPlusValidFrom IS NULL OR profile.B2bPlusValidFrom <= CONVERT(date, SYSUTCDATETIME()))
          AND (profile.B2bPlusValidTo IS NULL OR profile.B2bPlusValidTo >= CONVERT(date, SYSUTCDATETIME()))
          THEN 1 ELSE 0 END) AS B2bPlus,
        contact.Email, contact.Phone, contact.Mobile, contact.Persons,
        COALESCE(tier1.ThresholdGrossExVat, default1.ThresholdGrossExVat) AS Tier1Threshold,
        COALESCE(tier1.PercentValue, default1.PercentValue) AS Tier1Percent,
        COALESCE(tier2.ThresholdGrossExVat, default2.ThresholdGrossExVat) AS Tier2Threshold,
        COALESCE(tier2.PercentValue, default2.PercentValue) AS Tier2Percent,
        COALESCE(tier3.ThresholdGrossExVat, default3.ThresholdGrossExVat) AS Tier3Threshold,
        COALESCE(tier3.PercentValue, default3.PercentValue) AS Tier3Percent
      FROM #Page AS page
      INNER JOIN b2b.Customer AS customer ON customer.CustomerId = page.EntityId
      INNER JOIN pim.CustomerWebProfile AS profile ON profile.CustomerId = customer.CustomerId
      LEFT JOIN pim.CustomerTypeMagentoGroup AS magentoGroup ON magentoGroup.CustomerTypeCode = profile.CustomerTypeCode
      LEFT JOIN pim.CustomerContact AS contact
        ON contact.CustomerId = customer.CustomerId AND contact.OrganizationId = customer.OrganizationId
      LEFT JOIN pim.CustomerValueDiscountTier AS tier1 ON tier1.CustomerId = customer.CustomerId AND tier1.TierNumber = 1 AND tier1.IsActive = 1
      LEFT JOIN pim.CustomerValueDiscountTier AS tier2 ON tier2.CustomerId = customer.CustomerId AND tier2.TierNumber = 2 AND tier2.IsActive = 1
      LEFT JOIN pim.CustomerValueDiscountTier AS tier3 ON tier3.CustomerId = customer.CustomerId AND tier3.TierNumber = 3 AND tier3.IsActive = 1
      LEFT JOIN pim.ValueDiscountTier AS default1 ON default1.TierNumber = 1 AND default1.IsActive = 1
      LEFT JOIN pim.ValueDiscountTier AS default2 ON default2.TierNumber = 2 AND default2.IsActive = 1
      LEFT JOIN pim.ValueDiscountTier AS default3 ON default3.TierNumber = 3 AND default3.IsActive = 1
    ) AS core
    CROSS APPLY
    (
      VALUES
        (N''Customer.Key'', CONVERT(nvarchar(max), core.RowKey)),
        (N''Customer.Name'', CONVERT(nvarchar(max), core.Name)),
        (N''Customer.MagentoGroup'', CONVERT(nvarchar(max), core.MagentoGroupKey)),
        (N''Customer.PriceList'', CONVERT(nvarchar(max), core.PriceListCode)),
        (N''Customer.Payer'', CASE WHEN NULLIF(core.PayerCode, N'''') IS NULL AND NULLIF(core.PayerName, N'''') IS NULL
           THEN NULL ELSE CONVERT(nvarchar(max), ISNULL(core.PayerCode, N'''') + N''|'' + ISNULL(core.PayerName, N'''')) END),
        (N''Customer.Email'', CONVERT(nvarchar(max), core.Email)),
        (N''Customer.Phone'', CONVERT(nvarchar(max), COALESCE(NULLIF(core.Phone, N''''), NULLIF(core.Mobile, N'''')))),
        (N''Customer.Persons'', CONVERT(nvarchar(max), core.Persons)),
        (N''Customer.PackagingDiscountEnabled'', CASE WHEN core.PackagingDiscountEnabled = 1 THEN N''1'' ELSE N''0'' END),
        (N''Customer.ValueDiscountEnabled'', CASE WHEN core.ValueDiscountEnabled = 1 THEN N''1'' ELSE N''0'' END),
        (N''Customer.B2bPlus'', CASE WHEN core.B2bPlus = 1 THEN N''1'' ELSE N''0'' END),
        (N''Customer.Tier1Threshold'', CONVERT(nvarchar(max), out.MagentoNumber(core.Tier1Threshold))),
        (N''Customer.Tier1Percent'', CONVERT(nvarchar(max), out.MagentoNumber(core.Tier1Percent))),
        (N''Customer.Tier2Threshold'', CONVERT(nvarchar(max), out.MagentoNumber(core.Tier2Threshold))),
        (N''Customer.Tier2Percent'', CONVERT(nvarchar(max), out.MagentoNumber(core.Tier2Percent))),
        (N''Customer.Tier3Threshold'', CONVERT(nvarchar(max), out.MagentoNumber(core.Tier3Threshold))),
        (N''Customer.Tier3Percent'', CONVERT(nvarchar(max), out.MagentoNumber(core.Tier3Percent)))
    ) AS field (FieldCode, Value)
    WHERE field.Value IS NOT NULL;

    CREATE TABLE #GroupDiscount
      (RowKey nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
       ItemGroupCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
       PercentText nvarchar(50) COLLATE DATABASE_DEFAULT NULL);

    INSERT #GroupDiscount (RowKey, ItemGroupCode, PercentText)
    SELECT page.RowKey, discount.ItemGroupCode, out.MagentoNumber(discount.PercentValue)
    FROM #Page AS page
    INNER JOIN b2b.GroupDiscount AS discount ON discount.CustomerId = page.EntityId
    WHERE (discount.ValidFrom IS NULL OR discount.ValidFrom <= CONVERT(date, SYSUTCDATETIME()))
      AND (discount.ValidTo IS NULL OR discount.ValidTo >= CONVERT(date, SYSUTCDATETIME()));

    INSERT #Value (RowKey, FieldCode, Value)
    SELECT RowKey, N''Customer.GroupDiscounts'',
      STRING_AGG(CONVERT(nvarchar(max), ItemGroupCode + N''='' + ISNULL(PercentText, N'''') + N''%''), N'' | '')
        WITHIN GROUP (ORDER BY ItemGroupCode)
    FROM #GroupDiscount
    GROUP BY RowKey;

    INSERT #Value (RowKey, FieldCode, Value)
    SELECT RowKey, N''Customer.NwDiscount'', MIN(PercentText)
    FROM #GroupDiscount
    WHERE UPPER(ItemGroupCode) = N''NW''
    GROUP BY RowKey;
  END

  ELSE THROW 52976, N''Izvozni profil nima znanega vira vrednosti.'', 1;

  CREATE CLUSTERED INDEX IX_Value ON #Value (RowKey);

  /* ============================================================================
     D) Oblika rezultata pride iz registra: glave, vrstni red in kanonicne kode.
     ============================================================================ */
  DECLARE @Quote nchar(1) = NCHAR(39);
  DECLARE @SelectList nvarchar(max);
  SELECT @SelectList = STRING_AGG(CONVERT(nvarchar(max),
    CASE WHEN NULLIF(registryColumn.CanonicalFieldCode, N'''') IS NULL
      THEN N''CAST(NULL AS nvarchar(max)) AS '' + QUOTENAME(registryColumn.OutputColumnName)
      ELSE N''MAX(CASE WHEN fieldValue.FieldCode = N'' + @Quote
           + REPLACE(registryColumn.CanonicalFieldCode, @Quote, @Quote + @Quote) + @Quote
           + N'' THEN fieldValue.Value END) AS '' + QUOTENAME(registryColumn.OutputColumnName)
    END), N'','') WITHIN GROUP (ORDER BY registryColumn.SortOrder)
  FROM out.ExportColumn AS registryColumn
  WHERE registryColumn.ExportProfileId = @ExportProfileId AND registryColumn.IsActive = 1;

  DECLARE @Sql nvarchar(max) = N''
    SELECT '' + @SelectList + N''
    FROM #Page AS page
    LEFT JOIN #Value AS fieldValue ON fieldValue.RowKey = page.RowKey
    GROUP BY page.RowKey
    ORDER BY page.RowKey;'';

  EXEC sys.sp_executesql @Sql;
END');

/* --- dokaz ------------------------------------------------------------------------------ */

IF OBJECT_ID(N'canon.CategoryAttributeSet', N'U') IS NULL THROW 51475, N'147: canon.CategoryAttributeSet ni nastal.', 1;
IF OBJECT_ID(N'canon.CategoryAttributeEffective', N'IF') IS NULL THROW 51476, N'147: canon.CategoryAttributeEffective ni nastala.', 1;
IF COL_LENGTH(N'val.FieldRequirement', N'CategoryCode') IS NULL THROW 51477, N'147: val.FieldRequirement nima obsega.', 1;
IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = N'UQ_FieldRequirement_ProfileFieldScope')
  THROW 51478, N'147: enolicnost zahteve z obsegom ni nastala.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'val.RunValidation')) NOT LIKE N'%#Effective%'
  THROW 51479, N'147: val.RunValidation ne uposteva obsega.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows')) NOT LIKE N'%#AttributeFilter%'
  THROW 51480, N'147: out.GetExportRows ne uposteva nabora.', 1;

/* Funkcija se mora izvesti nad resnicnim drevesom; prazen nabor je pravilen rezultat. */
DECLARE @ProbeTree nvarchar(100), @ProbeCategory nvarchar(200);
SELECT TOP (1) @ProbeTree = CategoryTreeCode, @ProbeCategory = CategoryCode FROM canon.Category WHERE IsActive = 1 ORDER BY CategoryId;
IF @ProbeTree IS NOT NULL
BEGIN
  IF EXISTS (SELECT 1 FROM canon.CategoryAttributeEffective(@ProbeTree, @ProbeCategory))
    THROW 51481, N'147: nov register ne sme imeti vrstic pred prvim vnosom.', 1;
  EXEC intranet.GetCategoryAttributeSet @CategoryTreeCode = @ProbeTree, @CategoryCode = @ProbeCategory;
END;
