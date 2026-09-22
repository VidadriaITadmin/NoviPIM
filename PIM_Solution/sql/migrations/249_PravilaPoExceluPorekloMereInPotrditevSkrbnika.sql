/*
  249 - Pravila validacije po Excelu sodelavke (validacijski-profili-20260911-0943.xlsx, komentarji).

  Uporabnik 2026-09-22: atributov po kategorijah ne spreminjaj (ostanejo opozorila), "druge liste
  pa naredi tako, kot so napisani". Komentarji na listih ERP_SLO, ERP_EU_THIRD in KOMERCIALA:

    1. "Obvezno za proizvajalce izven SLO" (poreklo, carinska oznaka, bruto/neto teza) - doslej sta
       profila ERP_L1_EU in ERP_L1_THIRD (blokirata ERP) veljala za VSE izdelke (CROSS JOIN), tudi za
       6.256 slovenskih, in oba hkrati za isti izdelek (iste stiri napake trikrat: EU, THIRD,
       COMMERCIAL_L2). Nov stolpec OriginScope na val.ValidationProfile (EU / THIRD) in na
       val.FieldRequirement (FOREIGN za stiri zahteve v COMMERCIAL_L2); val.EuCountry je seznam
       clanic. Poreklo izdelka = canon.ProductCommercial.CountryOfOrigin (drzave partnerja PIM nima):
       SI -> EU/THIRD/FOREIGN ne veljajo; clanica EU -> EU; druga znana drzava -> THIRD; prazno ->
       EU in FOREIGN (poreklo mora nekdo vpisati, dokler ga ni, velja kot tuje).
    2. "Ne obvezno" - COMMERCIAL_L2.ProductCommercial.Volume ni vec obvezen; odprte tezave se zaprejo.
    3. "Obvezno za splet, da se bo lahko racunala postnina" - dolzina/sirina/visina paketa gredo v
       WEB_svetila_si in WEB_videlektro kot OBVEZNO OPOZORILO, ne blokirajoca napaka: 4.182 od 11.702
       artiklov s kljukico teh mer nima in bi kot napaka cez noc izpadli iz katalog.csv. Ko so mere
       vpisane, se resnost na /pravila/validacija preklopi na napako z enim klikom.
    4. Nicla ni mera: SAOP prazno decimalno polje zapise kot 0 (178.348 artiklov ima mere paketa 0),
       validacija pa je "0.0000" stela kot izpolnjeno. Za polja ProductCommercial.* zdaj 0 pomeni
       manjka (teze, mere, prostornina, kolicina pakiranja).
    5. "Obstajali bodo artikli, ki ne bodo imeli EAN kode, ampak to lahko potrdi samo skrbnik"
       (isto za proizvajalca in dobavitelja) - val.ProductFieldWaiver: skrbnik na kartici potrdi,
       da artikel tega podatka nima; validacija polje steje kot izpolnjeno, dokler potrditev velja.
       Katera polja smejo biti potrjena, pove val.WaivableField (EAN, Manufacturer, Supplier).

  Stevila po celotni validaciji (urni cikel; ta migracija validacije ne pozene, ker traja > 10 min
  na podjetje - glej 211): SI izdelki brez napak porekla, EU/THIRD napake brez podvajanja, nove
  tezave za nicelne teze pri tujem poreklu in nicelne mere paketa pri artiklih s kljukico.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

/* --- 1) Registri: clanice EU, obseg po poreklu, potrdljiva polja, potrditve --------------------- */
IF OBJECT_ID(N'val.EuCountry', N'U') IS NULL
  CREATE TABLE val.EuCountry
  (
    CountryCode nchar(2) NOT NULL CONSTRAINT PK_EuCountry PRIMARY KEY,
    Name nvarchar(100) NOT NULL
  );
MERGE val.EuCountry AS target
USING (VALUES
  (N'AT', N'Avstrija'), (N'BE', N'Belgija'), (N'BG', N'Bolgarija'), (N'HR', N'Hrvaska'), (N'CY', N'Ciper'),
  (N'CZ', N'Ceska'), (N'DK', N'Danska'), (N'EE', N'Estonija'), (N'FI', N'Finska'), (N'FR', N'Francija'),
  (N'DE', N'Nemcija'), (N'GR', N'Grcija'), (N'EL', N'Grcija (koda EU)'), (N'HU', N'Madzarska'), (N'IE', N'Irska'),
  (N'IT', N'Italija'), (N'LV', N'Latvija'), (N'LT', N'Litva'), (N'LU', N'Luksemburg'), (N'MT', N'Malta'),
  (N'NL', N'Nizozemska'), (N'PL', N'Poljska'), (N'PT', N'Portugalska'), (N'RO', N'Romunija'), (N'SK', N'Slovaska'),
  (N'SI', N'Slovenija'), (N'ES', N'Spanija'), (N'SE', N'Svedska')) AS source (CountryCode, Name)
ON target.CountryCode = source.CountryCode
WHEN NOT MATCHED THEN INSERT (CountryCode, Name) VALUES (source.CountryCode, source.Name);

IF COL_LENGTH(N'val.ValidationProfile', N'OriginScope') IS NULL
  ALTER TABLE val.ValidationProfile ADD OriginScope nvarchar(20) NULL
    CONSTRAINT CK_ValidationProfile_OriginScope CHECK (OriginScope IN (N'EU', N'THIRD', N'FOREIGN'));
IF COL_LENGTH(N'val.FieldRequirement', N'OriginScope') IS NULL
  ALTER TABLE val.FieldRequirement ADD OriginScope nvarchar(20) NULL
    CONSTRAINT CK_FieldRequirement_OriginScope CHECK (OriginScope IN (N'EU', N'THIRD', N'FOREIGN'));

IF OBJECT_ID(N'val.WaivableField', N'U') IS NULL
  CREATE TABLE val.WaivableField
  (
    FieldCode nvarchar(200) NOT NULL CONSTRAINT PK_WaivableField PRIMARY KEY,
    Label nvarchar(200) NOT NULL,
    SortOrder int NOT NULL
  );
MERGE val.WaivableField AS target
USING (VALUES (N'Product.EAN', N'Artikel nima EAN kode', 1),
              (N'Product.Manufacturer', N'Artikel nima proizvajalca', 2),
              (N'Product.Supplier', N'Artikel nima dobavitelja', 3)) AS source (FieldCode, Label, SortOrder)
ON target.FieldCode = source.FieldCode
WHEN NOT MATCHED THEN INSERT (FieldCode, Label, SortOrder) VALUES (source.FieldCode, source.Label, source.SortOrder);

IF OBJECT_ID(N'val.ProductFieldWaiver', N'U') IS NULL
BEGIN
  CREATE TABLE val.ProductFieldWaiver
  (
    ProductFieldWaiverId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_ProductFieldWaiver PRIMARY KEY,
    ProductId bigint NOT NULL CONSTRAINT FK_ProductFieldWaiver_Product REFERENCES canon.Product (ProductId),
    FieldCode nvarchar(200) NOT NULL CONSTRAINT FK_ProductFieldWaiver_WaivableField REFERENCES val.WaivableField (FieldCode),
    Reason nvarchar(500) NULL,
    IsActive bit NOT NULL CONSTRAINT DF_ProductFieldWaiver_IsActive DEFAULT (1),
    CreatedUtc datetime2(3) NOT NULL CONSTRAINT DF_ProductFieldWaiver_CreatedUtc DEFAULT SYSUTCDATETIME(),
    CreatedBy nvarchar(200) NOT NULL,
    ReleasedUtc datetime2(3) NULL,
    ReleasedBy nvarchar(200) NULL
  );
  CREATE UNIQUE INDEX UX_ProductFieldWaiver_Active ON val.ProductFieldWaiver (ProductId, FieldCode) WHERE IsActive = 1;
END;

/* --- 2) Pravila po komentarjih ---------------------------------------------------------------- */
DECLARE @CommercialProfileId int = (SELECT ValidationProfileId FROM val.ValidationProfile WHERE ProfileCode = N'COMMERCIAL_L2');
IF @CommercialProfileId IS NULL THROW 52511, N'249: profil COMMERCIAL_L2 ne obstaja.', 1;

/* Stolpec OriginScope je nov v tem paketu: stavki, ki ga uporabljajo, gredo skozi EXEC, da se
   prevedejo sele ob izvedbi (migracije so en paket brez GO - C# migrator locnice ne pozna). */
EXEC(N'
UPDATE val.ValidationProfile SET OriginScope = N''EU'' WHERE ProfileCode = N''ERP_L1_EU'';
UPDATE val.ValidationProfile SET OriginScope = N''THIRD'' WHERE ProfileCode = N''ERP_L1_THIRD'';
UPDATE requirement SET OriginScope = N''FOREIGN''
FROM val.FieldRequirement AS requirement
INNER JOIN val.ValidationProfile AS profile ON profile.ValidationProfileId = requirement.ValidationProfileId
WHERE profile.ProfileCode = N''COMMERCIAL_L2'' AND requirement.CategoryCode IS NULL
  AND requirement.FieldCode IN (N''ProductCommercial.NetWeight'', N''ProductCommercial.GrossWeight'',
                                N''ProductCommercial.CustomsTariff'', N''ProductCommercial.CountryOfOrigin'');');

UPDATE val.FieldRequirement SET IsRequired = 0
WHERE ValidationProfileId = @CommercialProfileId AND FieldCode = N'ProductCommercial.Volume' AND CategoryCode IS NULL;
UPDATE issue SET IsActive = 0, ResolvedUtc = SYSUTCDATETIME()
FROM val.ProductIssue AS issue
INNER JOIN val.FieldRequirement AS requirement ON requirement.FieldRequirementId = issue.FieldRequirementId
WHERE issue.IsActive = 1 AND requirement.ValidationProfileId = @CommercialProfileId
  AND requirement.FieldCode = N'ProductCommercial.Volume';

INSERT val.FieldRequirement (ValidationProfileId, SourceExportColumnId, FieldCode, IsRequired, IsActive, Severity, CategoryTreeCode, CategoryCode)
SELECT profile.ValidationProfileId, NULL, dimension.FieldCode, 1, 1, N'WARNING', NULL, NULL
FROM val.ValidationProfile AS profile
CROSS JOIN (VALUES (N'ProductCommercial.PackageLength'), (N'ProductCommercial.PackageWidth'), (N'ProductCommercial.PackageHeight')) AS dimension (FieldCode)
WHERE profile.Scope = N'WEB' AND profile.IsActive = 1
  AND NOT EXISTS (SELECT 1 FROM val.FieldRequirement AS existing
                  WHERE existing.ValidationProfileId = profile.ValidationProfileId AND existing.FieldCode = dimension.FieldCode
                    AND existing.CategoryTreeCode IS NULL AND existing.CategoryCode IS NULL);

/* --- 3) Validacija: poreklo, nicla ni mera, potrditve skrbnika --------------------------------- */
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

    /* 249: poreklo izdelka za obseg profilov/zahtev z OriginScope. SI = Slovenija, EU = clanica EU
       (val.EuCountry) razen Slovenije, THIRD = znana drzava izven EU, UNKNOWN = poreklo ni vpisano
       (steje kot tuje: dokler poreklo ni znano, mora nekdo vpisati vsaj njega). Sodelavka (Excel
       11. 9.): poreklo, carinska oznaka in tezi so obvezni za proizvajalce izven Slovenije; drzave
       partnerja PIM nima, zato je poreklo izdelka edini podatek, po katerem se to da presoditi. */
    CREATE TABLE #Origin (ProductId bigint NOT NULL PRIMARY KEY, Kind nvarchar(10) COLLATE DATABASE_DEFAULT NOT NULL);
    INSERT #Origin (ProductId, Kind)
    SELECT product.ProductId,
      CASE WHEN NULLIF(LTRIM(RTRIM(commercial.CountryOfOrigin)), N'''') IS NULL THEN N''UNKNOWN''
           WHEN UPPER(LTRIM(RTRIM(commercial.CountryOfOrigin))) = N''SI'' THEN N''SI''
           WHEN EXISTS (SELECT 1 FROM val.EuCountry eu WHERE eu.CountryCode = UPPER(LTRIM(RTRIM(commercial.CountryOfOrigin)))) THEN N''EU''
           ELSE N''THIRD'' END
    FROM canon.Product product
    LEFT JOIN canon.ProductCommercial commercial ON commercial.ProductId = product.ProductId
    WHERE product.IsActive = 1
      AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
      AND (@ProductId IS NULL OR product.ProductId = @ProductId);

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
        /* 249: poreklo - profil (ERP_L1_EU/THIRD) ali zahteva (COMMERCIAL_L2) z OriginScope velja samo za
           ustrezno poreklo izdelka (#Origin iz canon.ProductCommercial.CountryOfOrigin). */
        AND (COALESCE(requirement.OriginScope, profile.OriginScope) IS NULL OR EXISTS
          (SELECT 1 FROM #Origin origin
           WHERE origin.ProductId = product.ProductId
             AND ((COALESCE(requirement.OriginScope, profile.OriginScope) = N''FOREIGN'' AND origin.Kind <> N''SI'')
               OR (COALESCE(requirement.OriginScope, profile.OriginScope) = N''EU'' AND origin.Kind IN (N''EU'', N''UNKNOWN''))
               OR (COALESCE(requirement.OriginScope, profile.OriginScope) = N''THIRD'' AND origin.Kind = N''THIRD''))))
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
          /* 249: SAOP prazno mero zapise kot 0 - nicla ni teza, mera, prostornina ali kolicina pakiranja.
             ISNULL(..., 1): besedilno polje (poreklo, carinska oznaka) se ne pretvori in ostane izpolnjeno. */
          AND NOT (fieldValue.FieldCode LIKE N''ProductCommercial.%'' AND ISNULL(TRY_CONVERT(decimal(19,6), fieldValue.Value), 1) = 0)
      )
      /* 249: skrbnik je potrdil, da artikel tega podatka nima (val.ProductFieldWaiver) - polje velja za izpolnjeno. */
      AND NOT EXISTS
      (
        SELECT 1 FROM val.ProductFieldWaiver waiver
        WHERE waiver.ProductId = requiredField.ProductId AND waiver.FieldCode = requiredField.FieldCode AND waiver.IsActive = 1
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
          /* 249: poreklo - profil (ERP_L1_EU/THIRD) ali zahteva (COMMERCIAL_L2) z OriginScope velja samo za
             ustrezno poreklo izdelka (#Origin iz canon.ProductCommercial.CountryOfOrigin). */
          AND (COALESCE(requirement.OriginScope, profile.OriginScope) IS NULL OR EXISTS
            (SELECT 1 FROM #Origin origin
             WHERE origin.ProductId = product.ProductId
               AND ((COALESCE(requirement.OriginScope, profile.OriginScope) = N''FOREIGN'' AND origin.Kind <> N''SI'')
                 OR (COALESCE(requirement.OriginScope, profile.OriginScope) = N''EU'' AND origin.Kind IN (N''EU'', N''UNKNOWN''))
                 OR (COALESCE(requirement.OriginScope, profile.OriginScope) = N''THIRD'' AND origin.Kind = N''THIRD''))))
          AND NOT EXISTS (SELECT 1 FROM canon.FieldValue fieldValue WHERE fieldValue.ProductId = product.ProductId AND fieldValue.FieldCode = requirement.FieldCode AND NULLIF(fieldValue.Value, N'''') IS NOT NULL AND NOT (fieldValue.FieldCode LIKE N''ProductCommercial.%'' AND ISNULL(TRY_CONVERT(decimal(19,6), fieldValue.Value), 1) = 0))
          AND NOT EXISTS (SELECT 1 FROM val.ProductFieldWaiver waiver WHERE waiver.ProductId = product.ProductId AND waiver.FieldCode = requirement.FieldCode AND waiver.IsActive = 1)
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
        /* 249: poreklo - profil (ERP_L1_EU/THIRD) ali zahteva (COMMERCIAL_L2) z OriginScope velja samo za
           ustrezno poreklo izdelka (#Origin iz canon.ProductCommercial.CountryOfOrigin). */
        AND (COALESCE(requirement.OriginScope, profile.OriginScope) IS NULL OR EXISTS
          (SELECT 1 FROM #Origin origin
           WHERE origin.ProductId = product.ProductId
             AND ((COALESCE(requirement.OriginScope, profile.OriginScope) = N''FOREIGN'' AND origin.Kind <> N''SI'')
               OR (COALESCE(requirement.OriginScope, profile.OriginScope) = N''EU'' AND origin.Kind IN (N''EU'', N''UNKNOWN''))
               OR (COALESCE(requirement.OriginScope, profile.OriginScope) = N''THIRD'' AND origin.Kind = N''THIRD''))))
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
            /* 249: poreklo - profil (ERP_L1_EU/THIRD) ali zahteva (COMMERCIAL_L2) z OriginScope velja samo za
               ustrezno poreklo izdelka (#Origin iz canon.ProductCommercial.CountryOfOrigin). */
            AND (COALESCE(requirement.OriginScope, profile.OriginScope) IS NULL OR EXISTS
              (SELECT 1 FROM #Origin origin
               WHERE origin.ProductId = product.ProductId
                 AND ((COALESCE(requirement.OriginScope, profile.OriginScope) = N''FOREIGN'' AND origin.Kind <> N''SI'')
                   OR (COALESCE(requirement.OriginScope, profile.OriginScope) = N''EU'' AND origin.Kind IN (N''EU'', N''UNKNOWN''))
                   OR (COALESCE(requirement.OriginScope, profile.OriginScope) = N''THIRD'' AND origin.Kind = N''THIRD''))))
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

    /* 249: poreklo izdelka za obseg profilov/zahtev z OriginScope. SI = Slovenija, EU = clanica EU
       (val.EuCountry) razen Slovenije, THIRD = znana drzava izven EU, UNKNOWN = poreklo ni vpisano
       (steje kot tuje: dokler poreklo ni znano, mora nekdo vpisati vsaj njega). Sodelavka (Excel
       11. 9.): poreklo, carinska oznaka in tezi so obvezni za proizvajalce izven Slovenije; drzave
       partnerja PIM nima, zato je poreklo izdelka edini podatek, po katerem se to da presoditi. */
    CREATE TABLE #Origin (ProductId bigint NOT NULL PRIMARY KEY, Kind nvarchar(10) COLLATE DATABASE_DEFAULT NOT NULL);
    INSERT #Origin (ProductId, Kind)
    SELECT product.ProductId,
      CASE WHEN NULLIF(LTRIM(RTRIM(commercial.CountryOfOrigin)), N'''') IS NULL THEN N''UNKNOWN''
           WHEN UPPER(LTRIM(RTRIM(commercial.CountryOfOrigin))) = N''SI'' THEN N''SI''
           WHEN EXISTS (SELECT 1 FROM val.EuCountry eu WHERE eu.CountryCode = UPPER(LTRIM(RTRIM(commercial.CountryOfOrigin)))) THEN N''EU''
           ELSE N''THIRD'' END
    FROM canon.Product product
    LEFT JOIN canon.ProductCommercial commercial ON commercial.ProductId = product.ProductId
    WHERE product.IsActive = 1
      AND product.ProductId = @ProductId;

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
        /* 249: poreklo - profil (ERP_L1_EU/THIRD) ali zahteva (COMMERCIAL_L2) z OriginScope velja samo za
           ustrezno poreklo izdelka (#Origin iz canon.ProductCommercial.CountryOfOrigin). */
        AND (COALESCE(requirement.OriginScope, profile.OriginScope) IS NULL OR EXISTS
          (SELECT 1 FROM #Origin origin
           WHERE origin.ProductId = product.ProductId
             AND ((COALESCE(requirement.OriginScope, profile.OriginScope) = N''FOREIGN'' AND origin.Kind <> N''SI'')
               OR (COALESCE(requirement.OriginScope, profile.OriginScope) = N''EU'' AND origin.Kind IN (N''EU'', N''UNKNOWN''))
               OR (COALESCE(requirement.OriginScope, profile.OriginScope) = N''THIRD'' AND origin.Kind = N''THIRD''))))
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
          /* 249: SAOP prazno mero zapise kot 0 - nicla ni teza, mera, prostornina ali kolicina pakiranja.
             ISNULL(..., 1): besedilno polje (poreklo, carinska oznaka) se ne pretvori in ostane izpolnjeno. */
          AND NOT (fieldValue.FieldCode LIKE N''ProductCommercial.%'' AND ISNULL(TRY_CONVERT(decimal(19,6), fieldValue.Value), 1) = 0)
      )
      /* 249: skrbnik je potrdil, da artikel tega podatka nima (val.ProductFieldWaiver) - polje velja za izpolnjeno. */
      AND NOT EXISTS
      (
        SELECT 1 FROM val.ProductFieldWaiver waiver
        WHERE waiver.ProductId = requiredField.ProductId AND waiver.FieldCode = requiredField.FieldCode AND waiver.IsActive = 1
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
          /* 249: poreklo - profil (ERP_L1_EU/THIRD) ali zahteva (COMMERCIAL_L2) z OriginScope velja samo za
             ustrezno poreklo izdelka (#Origin iz canon.ProductCommercial.CountryOfOrigin). */
          AND (COALESCE(requirement.OriginScope, profile.OriginScope) IS NULL OR EXISTS
            (SELECT 1 FROM #Origin origin
             WHERE origin.ProductId = product.ProductId
               AND ((COALESCE(requirement.OriginScope, profile.OriginScope) = N''FOREIGN'' AND origin.Kind <> N''SI'')
                 OR (COALESCE(requirement.OriginScope, profile.OriginScope) = N''EU'' AND origin.Kind IN (N''EU'', N''UNKNOWN''))
                 OR (COALESCE(requirement.OriginScope, profile.OriginScope) = N''THIRD'' AND origin.Kind = N''THIRD''))))
          AND NOT EXISTS (SELECT 1 FROM canon.FieldValue fieldValue WHERE fieldValue.ProductId = product.ProductId AND fieldValue.FieldCode = requirement.FieldCode AND NULLIF(fieldValue.Value, N'''') IS NOT NULL AND NOT (fieldValue.FieldCode LIKE N''ProductCommercial.%'' AND ISNULL(TRY_CONVERT(decimal(19,6), fieldValue.Value), 1) = 0))
          AND NOT EXISTS (SELECT 1 FROM val.ProductFieldWaiver waiver WHERE waiver.ProductId = product.ProductId AND waiver.FieldCode = requirement.FieldCode AND waiver.IsActive = 1)
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
        /* 249: poreklo - profil (ERP_L1_EU/THIRD) ali zahteva (COMMERCIAL_L2) z OriginScope velja samo za
           ustrezno poreklo izdelka (#Origin iz canon.ProductCommercial.CountryOfOrigin). */
        AND (COALESCE(requirement.OriginScope, profile.OriginScope) IS NULL OR EXISTS
          (SELECT 1 FROM #Origin origin
           WHERE origin.ProductId = product.ProductId
             AND ((COALESCE(requirement.OriginScope, profile.OriginScope) = N''FOREIGN'' AND origin.Kind <> N''SI'')
               OR (COALESCE(requirement.OriginScope, profile.OriginScope) = N''EU'' AND origin.Kind IN (N''EU'', N''UNKNOWN''))
               OR (COALESCE(requirement.OriginScope, profile.OriginScope) = N''THIRD'' AND origin.Kind = N''THIRD''))))
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
            /* 249: poreklo - profil (ERP_L1_EU/THIRD) ali zahteva (COMMERCIAL_L2) z OriginScope velja samo za
               ustrezno poreklo izdelka (#Origin iz canon.ProductCommercial.CountryOfOrigin). */
            AND (COALESCE(requirement.OriginScope, profile.OriginScope) IS NULL OR EXISTS
              (SELECT 1 FROM #Origin origin
               WHERE origin.ProductId = product.ProductId
                 AND ((COALESCE(requirement.OriginScope, profile.OriginScope) = N''FOREIGN'' AND origin.Kind <> N''SI'')
                   OR (COALESCE(requirement.OriginScope, profile.OriginScope) = N''EU'' AND origin.Kind IN (N''EU'', N''UNKNOWN''))
                   OR (COALESCE(requirement.OriginScope, profile.OriginScope) = N''THIRD'' AND origin.Kind = N''THIRD''))))
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

    /* 249: poreklo izdelka za obseg profilov/zahtev z OriginScope. SI = Slovenija, EU = clanica EU
       (val.EuCountry) razen Slovenije, THIRD = znana drzava izven EU, UNKNOWN = poreklo ni vpisano
       (steje kot tuje: dokler poreklo ni znano, mora nekdo vpisati vsaj njega). Sodelavka (Excel
       11. 9.): poreklo, carinska oznaka in tezi so obvezni za proizvajalce izven Slovenije; drzave
       partnerja PIM nima, zato je poreklo izdelka edini podatek, po katerem se to da presoditi. */
    CREATE TABLE #Origin (ProductId bigint NOT NULL PRIMARY KEY, Kind nvarchar(10) COLLATE DATABASE_DEFAULT NOT NULL);
    INSERT #Origin (ProductId, Kind)
    SELECT product.ProductId,
      CASE WHEN NULLIF(LTRIM(RTRIM(commercial.CountryOfOrigin)), N'''') IS NULL THEN N''UNKNOWN''
           WHEN UPPER(LTRIM(RTRIM(commercial.CountryOfOrigin))) = N''SI'' THEN N''SI''
           WHEN EXISTS (SELECT 1 FROM val.EuCountry eu WHERE eu.CountryCode = UPPER(LTRIM(RTRIM(commercial.CountryOfOrigin)))) THEN N''EU''
           ELSE N''THIRD'' END
    FROM canon.Product product
    LEFT JOIN canon.ProductCommercial commercial ON commercial.ProductId = product.ProductId
    WHERE product.IsActive = 1
      AND EXISTS (SELECT 1 FROM #Izbrani AS izbrani WHERE izbrani.ProductId = product.ProductId);

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
        /* 249: poreklo - profil (ERP_L1_EU/THIRD) ali zahteva (COMMERCIAL_L2) z OriginScope velja samo za
           ustrezno poreklo izdelka (#Origin iz canon.ProductCommercial.CountryOfOrigin). */
        AND (COALESCE(requirement.OriginScope, profile.OriginScope) IS NULL OR EXISTS
          (SELECT 1 FROM #Origin origin
           WHERE origin.ProductId = product.ProductId
             AND ((COALESCE(requirement.OriginScope, profile.OriginScope) = N''FOREIGN'' AND origin.Kind <> N''SI'')
               OR (COALESCE(requirement.OriginScope, profile.OriginScope) = N''EU'' AND origin.Kind IN (N''EU'', N''UNKNOWN''))
               OR (COALESCE(requirement.OriginScope, profile.OriginScope) = N''THIRD'' AND origin.Kind = N''THIRD''))))
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
          /* 249: SAOP prazno mero zapise kot 0 - nicla ni teza, mera, prostornina ali kolicina pakiranja.
             ISNULL(..., 1): besedilno polje (poreklo, carinska oznaka) se ne pretvori in ostane izpolnjeno. */
          AND NOT (fieldValue.FieldCode LIKE N''ProductCommercial.%'' AND ISNULL(TRY_CONVERT(decimal(19,6), fieldValue.Value), 1) = 0)
      )
      /* 249: skrbnik je potrdil, da artikel tega podatka nima (val.ProductFieldWaiver) - polje velja za izpolnjeno. */
      AND NOT EXISTS
      (
        SELECT 1 FROM val.ProductFieldWaiver waiver
        WHERE waiver.ProductId = requiredField.ProductId AND waiver.FieldCode = requiredField.FieldCode AND waiver.IsActive = 1
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
          /* 249: poreklo - profil (ERP_L1_EU/THIRD) ali zahteva (COMMERCIAL_L2) z OriginScope velja samo za
             ustrezno poreklo izdelka (#Origin iz canon.ProductCommercial.CountryOfOrigin). */
          AND (COALESCE(requirement.OriginScope, profile.OriginScope) IS NULL OR EXISTS
            (SELECT 1 FROM #Origin origin
             WHERE origin.ProductId = product.ProductId
               AND ((COALESCE(requirement.OriginScope, profile.OriginScope) = N''FOREIGN'' AND origin.Kind <> N''SI'')
                 OR (COALESCE(requirement.OriginScope, profile.OriginScope) = N''EU'' AND origin.Kind IN (N''EU'', N''UNKNOWN''))
                 OR (COALESCE(requirement.OriginScope, profile.OriginScope) = N''THIRD'' AND origin.Kind = N''THIRD''))))
          AND NOT EXISTS (SELECT 1 FROM canon.FieldValue fieldValue WHERE fieldValue.ProductId = product.ProductId AND fieldValue.FieldCode = requirement.FieldCode AND NULLIF(fieldValue.Value, N'''') IS NOT NULL AND NOT (fieldValue.FieldCode LIKE N''ProductCommercial.%'' AND ISNULL(TRY_CONVERT(decimal(19,6), fieldValue.Value), 1) = 0))
          AND NOT EXISTS (SELECT 1 FROM val.ProductFieldWaiver waiver WHERE waiver.ProductId = product.ProductId AND waiver.FieldCode = requirement.FieldCode AND waiver.IsActive = 1)
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
        /* 249: poreklo - profil (ERP_L1_EU/THIRD) ali zahteva (COMMERCIAL_L2) z OriginScope velja samo za
           ustrezno poreklo izdelka (#Origin iz canon.ProductCommercial.CountryOfOrigin). */
        AND (COALESCE(requirement.OriginScope, profile.OriginScope) IS NULL OR EXISTS
          (SELECT 1 FROM #Origin origin
           WHERE origin.ProductId = product.ProductId
             AND ((COALESCE(requirement.OriginScope, profile.OriginScope) = N''FOREIGN'' AND origin.Kind <> N''SI'')
               OR (COALESCE(requirement.OriginScope, profile.OriginScope) = N''EU'' AND origin.Kind IN (N''EU'', N''UNKNOWN''))
               OR (COALESCE(requirement.OriginScope, profile.OriginScope) = N''THIRD'' AND origin.Kind = N''THIRD''))))
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
            /* 249: poreklo - profil (ERP_L1_EU/THIRD) ali zahteva (COMMERCIAL_L2) z OriginScope velja samo za
               ustrezno poreklo izdelka (#Origin iz canon.ProductCommercial.CountryOfOrigin). */
            AND (COALESCE(requirement.OriginScope, profile.OriginScope) IS NULL OR EXISTS
              (SELECT 1 FROM #Origin origin
               WHERE origin.ProductId = product.ProductId
                 AND ((COALESCE(requirement.OriginScope, profile.OriginScope) = N''FOREIGN'' AND origin.Kind <> N''SI'')
                   OR (COALESCE(requirement.OriginScope, profile.OriginScope) = N''EU'' AND origin.Kind IN (N''EU'', N''UNKNOWN''))
                   OR (COALESCE(requirement.OriginScope, profile.OriginScope) = N''THIRD'' AND origin.Kind = N''THIRD''))))
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

/* --- 4) Potrditev skrbnika in branje za kartico ----------------------------------------------- */
EXEC(N'CREATE OR ALTER PROCEDURE val.SetProductFieldWaiver
  @ProductId bigint,
  @FieldCode nvarchar(200),
  @Reason nvarchar(500) = NULL,
  @IsActive bit,
  @Actor nvarchar(200)
AS
BEGIN
  /* 249: skrbnik potrdi, da artikel tega podatka nima (EAN, proizvajalec, dobavitelj - val.WaivableField).
     Isti vzorec kot val.SetProductHold; po zapisu se artikel takoj ponovno validira, kot ob kljukici
     spletisca (pim.SaveProductWebShops), da kartica nikoli ne kaze napake za potrjeno polje. */
  SET NOCOUNT ON; SET XACT_ABORT ON;
  SET @FieldCode = NULLIF(LTRIM(RTRIM(@FieldCode)), N'''');
  SET @Reason = NULLIF(LTRIM(RTRIM(@Reason)), N'''');
  IF NOT EXISTS (SELECT 1 FROM val.WaivableField WHERE FieldCode = @FieldCode)
    THROW 52512, N''Tega polja skrbnik ne more potrditi kot manjkajocega.'', 1;
  IF NOT EXISTS (SELECT 1 FROM canon.Product WHERE ProductId = @ProductId)
    THROW 52513, N''Artikel ne obstaja.'', 1;
  IF @IsActive = 1
  BEGIN
    IF EXISTS (SELECT 1 FROM val.ProductFieldWaiver WHERE ProductId = @ProductId AND FieldCode = @FieldCode AND IsActive = 1)
      UPDATE val.ProductFieldWaiver SET Reason = @Reason, CreatedUtc = SYSUTCDATETIME(), CreatedBy = @Actor
      WHERE ProductId = @ProductId AND FieldCode = @FieldCode AND IsActive = 1;
    ELSE
      INSERT val.ProductFieldWaiver (ProductId, FieldCode, Reason, CreatedBy) VALUES (@ProductId, @FieldCode, @Reason, @Actor);
  END
  ELSE
    UPDATE val.ProductFieldWaiver SET IsActive = 0, ReleasedUtc = SYSUTCDATETIME(), ReleasedBy = @Actor
    WHERE ProductId = @ProductId AND FieldCode = @FieldCode AND IsActive = 1;
  EXEC val.RunValidationForProduct @ProductId = @ProductId;
END;');

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetProductFieldWaivers
  @ProductId bigint
AS
BEGIN
  /* 249: vsa potrdljiva polja z morebitno veljavno potrditvijo za ta artikel (kartica izdelka). */
  SET NOCOUNT ON;
  SELECT waivable.FieldCode, waivable.Label,
    IsWaived = CONVERT(bit, CASE WHEN waiver.ProductFieldWaiverId IS NULL THEN 0 ELSE 1 END),
    waiver.Reason, waiver.CreatedBy, waiver.CreatedUtc
  FROM val.WaivableField AS waivable
  LEFT JOIN val.ProductFieldWaiver AS waiver
    ON waiver.FieldCode = waivable.FieldCode AND waiver.ProductId = @ProductId AND waiver.IsActive = 1
  ORDER BY waivable.SortOrder;
END;');

/* --- 5) Preverba ------------------------------------------------------------------------------ */
IF (SELECT COUNT(*) FROM val.EuCountry) < 27 THROW 52521, N'249: val.EuCountry ni popoln.', 1;
EXEC(N'
IF NOT EXISTS (SELECT 1 FROM val.ValidationProfile WHERE ProfileCode = N''ERP_L1_EU'' AND OriginScope = N''EU'')
  THROW 52522, N''249: ERP_L1_EU nima obsega EU.'', 1;
IF NOT EXISTS (SELECT 1 FROM val.ValidationProfile WHERE ProfileCode = N''ERP_L1_THIRD'' AND OriginScope = N''THIRD'')
  THROW 52523, N''249: ERP_L1_THIRD nima obsega THIRD.'', 1;
IF (SELECT COUNT(*) FROM val.FieldRequirement WHERE OriginScope = N''FOREIGN'') <> 4
  THROW 52524, N''249: COMMERCIAL_L2 nima stirih zahtev z obsegom FOREIGN.'', 1;');
IF EXISTS (SELECT 1 FROM val.FieldRequirement WHERE FieldCode = N'ProductCommercial.Volume' AND IsRequired = 1 AND CategoryCode IS NULL)
  THROW 52525, N'249: Volume je se vedno obvezen.', 1;
IF (SELECT COUNT(*) FROM val.FieldRequirement AS requirement INNER JOIN val.ValidationProfile AS profile ON profile.ValidationProfileId = requirement.ValidationProfileId
    WHERE profile.Scope = N'WEB' AND requirement.FieldCode LIKE N'ProductCommercial.Package%' AND requirement.CategoryCode IS NULL AND requirement.IsActive = 1) <> 6
  THROW 52526, N'249: mere paketa niso v obeh spletnih profilih.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'val.RunValidation')) NOT LIKE N'%#Origin%' OR OBJECT_DEFINITION(OBJECT_ID(N'val.RunValidation')) NOT LIKE N'%ProductFieldWaiver%'
  THROW 52527, N'249: val.RunValidation ne pozna porekla ali potrditev.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'val.RunValidationForProduct')) NOT LIKE N'%#Origin%' OR OBJECT_DEFINITION(OBJECT_ID(N'val.RunValidationForProduct')) NOT LIKE N'%ProductFieldWaiver%'
  THROW 52528, N'249: val.RunValidationForProduct ne pozna porekla ali potrditev.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'val.RunValidationForProducts')) NOT LIKE N'%#Origin%' OR OBJECT_DEFINITION(OBJECT_ID(N'val.RunValidationForProducts')) NOT LIKE N'%ProductFieldWaiver%'
  THROW 52529, N'249: val.RunValidationForProducts ne pozna porekla ali potrditev.', 1;
IF OBJECT_ID(N'val.SetProductFieldWaiver', N'P') IS NULL OR OBJECT_ID(N'intranet.GetProductFieldWaivers', N'P') IS NULL
  THROW 52530, N'249: proceduri za potrditev skrbnika nista ustvarjeni.', 1;
