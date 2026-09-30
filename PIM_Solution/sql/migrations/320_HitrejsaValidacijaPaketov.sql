/* 320_HitrejsaValidacijaPaketov — rezervirano za nalogo #105 (razvijalec #105, 2026-09-30 16:09). */
/*
  320 — val.RunValidationForProducts za pakete izdelkov brez minut cakanja in brez zaklepanja (naloga #105).

  Pri #10 je paketno urejanje 1.000 izdelkov IQ Lighting v val.RunValidationForProducts (zadnja definicija
  249) porabilo 9,5 min in 87 mio logicnih branj, ves cas v ENI transakciji: MERGE/UPDATE po
  val.ProductIssue (~30 vrstic na izdelek) je presegel mejo 5.000 zaklepov in jih povzdignil na celo tabelo,
  zato so druge seje (map.ProcessRawInbox, dnevnik aktivnosti, kartica) cakale (LCK_M_IX).

  Vzrok branj: pogoj "polje ni izpolnjeno" je bil NOT EXISTS na pogled canon.FieldValue (UNION ALL cez
  ~30 tabel, FieldCode je pri atributih in besedilih izracunan s CONCAT, zato brez iskanja po indeksu) za
  VSAK par (izdelek, zahteva) - pri 1.000 izdelkih in ~850 zahtevah skoraj milijon korelacij, dvakrat
  (odpiranje in zapiranje napak). Poleg tega CROSS JOIN canon.Product x val.ValidationProfile z EXISTS na
  #Izbrani, kar optimizator lahko izvede kot pregled vseh izdelkov.

  Zdaj (enaka pravila kot 249, drugacen postopek):
    1. izracun pred pisanjem, v zacasnih tabelah, samo za izbrane izdelke:
       #Active (izbrani aktivni), #Effective, #ScopedRequirement, #Origin (kot 249),
       #Shop (kljukice spletisc), #Req (aktivne obvezne zahteve),
       #FieldPresent (izdelek, polje) - pogled canon.FieldValue prebran ENKRAT za izbrane izdelke in samo za
         polja, ki jih zahteva kaksna zahteva; ista pravila "izpolnjeno" (prazno ni, 249: nicla pri
         ProductCommercial.* ni),
       #Applicable (izdelek, zahteva, ki zanj velja) in #Missing (od tega manjkajoce, brez potrditev skrbnika);
    2. pisanje po 25 izdelkov v svoji kratki transakciji (vsi koraki za teh 25 izdelkov: odpri/osvezi napake,
       zapri napake, stanje profilov, brisanje stanja izven obsega (248), stanje izdelka). Izdelki so med
       seboj neodvisni, zato je rezultat enak kot v eni transakciji; ob napaki ostanejo ze zapisani paketi
       pravilno validirani, ostali pa v prejsnjem stanju (klic vrne napako kot doslej).
  SET DEADLOCK_PRIORITY LOW ostane (validacija ob zastoju s preslikavo vedno izgubi, 211).
  Pravila 182 (spletni profil samo za objavljene), 248, 249 (poreklo, potrditev skrbnika, nicla = manjka)
  ostanejo enaka; zapiranje napak ostane dobesedno enako 249, le branje polja in kljukic gre iz #FieldPresent/#Shop.

  Parametri so enaki (@ProductIdsJson). Klicatelji: pim.SaveProductTextsBulk / SaveProductAttributesBulk,
  uvoz delovnega lista, samodejni umik (251), AttributeMappingService.
  DEV meritev in primerjava stara/nova: glej docs/DATABASE.md (320).
  SAOP: nic. Rocni korak: ne. Ponovljivo: da. Razveljavitev: ponovno zazeni definicijo procedure iz 249.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;

IF OBJECT_ID(N'val.ProductFieldWaiver', N'U') IS NULL OR OBJECT_ID(N'val.EuCountry', N'U') IS NULL
  THROW 53200, N'320: najprej mora biti uveljavljena 249 (poreklo in potrditve skrbnika).', 1;

EXEC(N'CREATE OR ALTER PROCEDURE val.RunValidationForProducts
  @ProductIdsJson nvarchar(max)   /* [1, 2, 3, ...] */
AS
BEGIN
  /*
    218: ista validacija kot val.RunValidationForProduct (195), za SEZNAM izdelkov v enem teku.
    320 (HitrejsaValidacijaPaketov320): izracun enkrat v zacasnih tabelah samo za izbrane izdelke,
    pisanje po @Paket izdelkov v kratkih transakcijah. Pravila so enaka kot 249.
  */
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  SET DEADLOCK_PRIORITY LOW;
  DECLARE @Paket int = 25;
  CREATE TABLE #Izbrani (ProductId bigint NOT NULL PRIMARY KEY, Paket int NULL);
  INSERT #Izbrani (ProductId)
  SELECT DISTINCT TRY_CONVERT(bigint, parsed.value) FROM OPENJSON(@ProductIdsJson) AS parsed
  WHERE ISJSON(parsed.value) = 0 AND TRY_CONVERT(bigint, parsed.value) IS NOT NULL;
  IF NOT EXISTS (SELECT 1 FROM #Izbrani) RETURN;
  BEGIN TRY
    /* Izdelki, ki ne obstajajo, niso del teka (249 je vse korake vezal na canon.Product). */
    DELETE izbrani FROM #Izbrani izbrani
    WHERE NOT EXISTS (SELECT 1 FROM canon.Product product WHERE product.ProductId = izbrani.ProductId);
    IF NOT EXISTS (SELECT 1 FROM #Izbrani) RETURN;
    ;WITH numbered AS (SELECT Paket, ROW_NUMBER() OVER (ORDER BY ProductId) - 1 AS Rn FROM #Izbrani)
    UPDATE numbered SET Paket = Rn / @Paket;

    CREATE TABLE #Active (ProductId bigint NOT NULL PRIMARY KEY);
    INSERT #Active (ProductId)
    SELECT product.ProductId FROM #Izbrani izbrani
    INNER JOIN canon.Product product ON product.ProductId = izbrani.ProductId
    WHERE product.IsActive = 1;

    /* 147: obseg zahteve (najblizja vrstica nabora po verigi prednikov; EXCLUDED pri otroku prekrije REQUIRED pri starsu). */
    CREATE TABLE #Effective
      (ProductId bigint NOT NULL, CategoryTreeCode nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL,
       AttributeCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
       DefinedAtCategoryCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
       Level nvarchar(20) COLLATE DATABASE_DEFAULT NOT NULL,
       PRIMARY KEY (ProductId, CategoryTreeCode, AttributeCode));

    ;WITH assigned AS
    (
      SELECT DISTINCT active.ProductId, node.CategoryTreeCode, node.CategoryCode, node.ParentCategoryCode
      FROM #Active AS active
      INNER JOIN canon.ProductCategory AS productCategory ON productCategory.ProductId = active.ProductId
      INNER JOIN canon.WebSite AS site ON site.WebSiteCode = productCategory.WebSite
      INNER JOIN canon.Category AS node
        ON node.CategoryTreeCode = site.CategoryTreeCode AND node.CategoryPath = productCategory.CategoryPath
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

    /* Zahteva z obsegom -> koda atributa v registru (zahteva nosi slovensko ime). Ime polja atributa se
       izracuna enkrat na atribut (canon.AttributeTranslation je enolicen po AttributeCode+LanguageCode),
       nato stik z zahtevami - prej korelirana poizvedba za vsak par (atribut, zahteva). */
    CREATE TABLE #AttributeField
      (AttributeCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL, FieldCode nvarchar(450) COLLATE DATABASE_DEFAULT NOT NULL);
    INSERT #AttributeField (AttributeCode, FieldCode)
    SELECT definition.AttributeCode, CONCAT(N''ProductAttribute.'', COALESCE(translation.Name, definition.AttributeCode))
    FROM canon.AttributeDefinition AS definition
    LEFT JOIN canon.AttributeTranslation AS translation
      ON translation.AttributeCode = definition.AttributeCode AND translation.LanguageCode = N''sl'';

    CREATE TABLE #ScopedRequirement
      (FieldRequirementId int NOT NULL PRIMARY KEY, CategoryTreeCode nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL,
       CategoryCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL, AttributeCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL);
    INSERT #ScopedRequirement (FieldRequirementId, CategoryTreeCode, CategoryCode, AttributeCode)
    SELECT requirement.FieldRequirementId, requirement.CategoryTreeCode, requirement.CategoryCode, attributeField.AttributeCode
    FROM val.FieldRequirement AS requirement
    INNER JOIN #AttributeField AS attributeField ON attributeField.FieldCode = requirement.FieldCode
    WHERE requirement.CategoryCode IS NOT NULL;

    /* 249: poreklo izdelka (SI, EU, THIRD, UNKNOWN = steje kot tuje). */
    CREATE TABLE #Origin (ProductId bigint NOT NULL PRIMARY KEY, Kind nvarchar(10) COLLATE DATABASE_DEFAULT NOT NULL);
    INSERT #Origin (ProductId, Kind)
    SELECT active.ProductId,
      CASE WHEN NULLIF(LTRIM(RTRIM(commercial.CountryOfOrigin)), N'''') IS NULL THEN N''UNKNOWN''
           WHEN UPPER(LTRIM(RTRIM(commercial.CountryOfOrigin))) = N''SI'' THEN N''SI''
           WHEN EXISTS (SELECT 1 FROM val.EuCountry eu WHERE eu.CountryCode = UPPER(LTRIM(RTRIM(commercial.CountryOfOrigin)))) THEN N''EU''
           ELSE N''THIRD'' END
    FROM #Active active
    LEFT JOIN canon.ProductCommercial commercial ON commercial.ProductId = active.ProductId;

    /* 182: kljukice spletisc izbranih izdelkov (spletni profil velja samo za objavljene). */
    CREATE TABLE #Shop (ProductId bigint NOT NULL, WebShopCode nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL,
      PRIMARY KEY (ProductId, WebShopCode));
    INSERT #Shop (ProductId, WebShopCode)
    SELECT DISTINCT shop.ProductId, shop.WebShopCode
    FROM #Izbrani izbrani
    INNER JOIN pim.ProductWebShop shop ON shop.ProductId = izbrani.ProductId AND shop.IsPublished = 1;

    /* Aktivne obvezne zahteve aktivnih profilov z ze izracunanim obsegom porekla (zahteva prekrije profil). */
    CREATE TABLE #Req
      (FieldRequirementId int NOT NULL PRIMARY KEY, ValidationProfileId int NOT NULL,
       FieldCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL, CategoryCode nvarchar(200) COLLATE DATABASE_DEFAULT NULL,
       OriginScope nvarchar(20) COLLATE DATABASE_DEFAULT NULL, ProfileScope nvarchar(50) COLLATE DATABASE_DEFAULT NULL,
       ProfileTree nvarchar(100) COLLATE DATABASE_DEFAULT NULL);
    INSERT #Req (FieldRequirementId, ValidationProfileId, FieldCode, CategoryCode, OriginScope, ProfileScope, ProfileTree)
    SELECT requirement.FieldRequirementId, profile.ValidationProfileId, requirement.FieldCode, requirement.CategoryCode,
      COALESCE(requirement.OriginScope, profile.OriginScope), profile.Scope, profile.CategoryTreeCode
    FROM val.ValidationProfile profile
    INNER JOIN val.FieldRequirement requirement ON requirement.ValidationProfileId = profile.ValidationProfileId
    WHERE profile.IsActive = 1 AND requirement.IsActive = 1 AND requirement.IsRequired = 1;

    /* Izpolnjena polja izbranih izdelkov: canon.FieldValue enkrat, samo za polja, ki jih kaksna aktivna
       obvezna zahteva sploh preverja (tudi zahteve neaktivnih profilov - po njih se zapirajo stare napake).
       249: SAOP prazno mero zapise kot 0 - nicla pri ProductCommercial.* ni izpolnjeno polje; besedilno polje
       (poreklo, carinska oznaka) se ne pretvori in ostane izpolnjeno. */
    /* Dva koraka namerno: pogled se prebere BREZ pogojev (preprost nacrt, ~70.000 vrstic za 1.000 izdelkov),
       pogoji pa se uporabijo sele na zacasni tabeli. En sam stavek s pogoji na pogledu je imel nestabilen nacrt
       (na DEV 20-145 s CPU zaradi vgnezdenih zank cez veje slik 312). */
    CREATE TABLE #FieldValueRaw (ProductId bigint NOT NULL, FieldCode nvarchar(450) COLLATE DATABASE_DEFAULT NOT NULL,
      Value nvarchar(max) COLLATE DATABASE_DEFAULT NULL);
    INSERT #FieldValueRaw (ProductId, FieldCode, Value)
    SELECT fieldValue.ProductId, fieldValue.FieldCode, fieldValue.Value
    FROM #Izbrani izbrani
    INNER JOIN canon.FieldValue fieldValue ON fieldValue.ProductId = izbrani.ProductId
    OPTION (RECOMPILE);

    CREATE TABLE #FieldPresent (ProductId bigint NOT NULL, FieldCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
      PRIMARY KEY (ProductId, FieldCode));
    INSERT #FieldPresent (ProductId, FieldCode)
    SELECT DISTINCT fieldValue.ProductId, fieldValue.FieldCode
    FROM #FieldValueRaw fieldValue
    WHERE NULLIF(fieldValue.Value, N'''') IS NOT NULL
      AND NOT (fieldValue.FieldCode LIKE N''ProductCommercial.%'' AND ISNULL(TRY_CONVERT(decimal(19,6), fieldValue.Value), 1) = 0)
      AND EXISTS (SELECT 1 FROM val.FieldRequirement requirement
                  WHERE requirement.FieldCode = fieldValue.FieldCode AND requirement.IsActive = 1 AND requirement.IsRequired = 1);
    DROP TABLE #FieldValueRaw;

    /* Zahteve, ki za izdelek veljajo (isti pogoji kot RequiredField v 249): zahteve brez obsega kategorije za
       vsak aktiven izdelek, zahteve z obsegom pa samo prek obveljale vrstice nabora (#Effective) - ta je za
       (izdelek, zahteva) najvec ena (kljuc #Effective), zato ni podvojitev. */
    CREATE TABLE #Applicable
      (ProductId bigint NOT NULL, FieldRequirementId int NOT NULL, ValidationProfileId int NOT NULL,
       FieldCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL, IsMissing bit NOT NULL,
       PRIMARY KEY (ProductId, FieldRequirementId));
    INSERT #Applicable (ProductId, FieldRequirementId, ValidationProfileId, FieldCode, IsMissing)
    SELECT candidate.ProductId, req.FieldRequirementId, req.ValidationProfileId, req.FieldCode, 0
    FROM
    (
      SELECT active.ProductId, req.FieldRequirementId
      FROM #Active active CROSS JOIN #Req req
      WHERE req.CategoryCode IS NULL
      UNION ALL
      SELECT effective.ProductId, scoped.FieldRequirementId
      FROM #ScopedRequirement scoped
      INNER JOIN #Effective effective
        ON effective.CategoryTreeCode = scoped.CategoryTreeCode AND effective.AttributeCode = scoped.AttributeCode
       AND effective.DefinedAtCategoryCode = scoped.CategoryCode AND effective.Level <> N''EXCLUDED''
    ) AS candidate
    INNER JOIN #Req req ON req.FieldRequirementId = candidate.FieldRequirementId
    INNER JOIN #Origin origin ON origin.ProductId = candidate.ProductId
    WHERE (req.ProfileScope <> N''WEB'' OR EXISTS
            (SELECT 1 FROM #Shop shop WHERE shop.ProductId = candidate.ProductId AND shop.WebShopCode = req.ProfileTree))
      AND (req.OriginScope IS NULL
        OR (req.OriginScope = N''FOREIGN'' AND origin.Kind <> N''SI'')
        OR (req.OriginScope = N''EU'' AND origin.Kind IN (N''EU'', N''UNKNOWN''))
        OR (req.OriginScope = N''THIRD'' AND origin.Kind = N''THIRD''))
    OPTION (RECOMPILE);

    /* Manjka = ni izpolnjeno in skrbnik ni potrdil, da artikel tega podatka nima (249). */
    UPDATE applicable SET IsMissing = 1
    FROM #Applicable applicable
    WHERE NOT EXISTS (SELECT 1 FROM #FieldPresent present
                      WHERE present.ProductId = applicable.ProductId AND present.FieldCode = applicable.FieldCode)
      AND NOT EXISTS (SELECT 1 FROM val.ProductFieldWaiver waiver
                      WHERE waiver.ProductId = applicable.ProductId AND waiver.FieldCode = applicable.FieldCode AND waiver.IsActive = 1);

    /* 248: izracun gre v #Score, ker mora po MERGE ostati na voljo (DELETE stanja izven obsega). */
    CREATE TABLE #Score
      (ProductId bigint NOT NULL, ValidationProfileId int NOT NULL,
       Completeness decimal(5,2) NOT NULL, Status nvarchar(20) COLLATE DATABASE_DEFAULT NOT NULL,
       PRIMARY KEY (ProductId, ValidationProfileId));
    CREATE TABLE #Chunk (ProductId bigint NOT NULL PRIMARY KEY);

    DECLARE @Current int = 0, @Last int = (SELECT MAX(Paket) FROM #Izbrani);
    WHILE @Current <= @Last
    BEGIN
      TRUNCATE TABLE #Chunk;
      INSERT #Chunk (ProductId) SELECT ProductId FROM #Izbrani WHERE Paket = @Current;

      BEGIN TRANSACTION;

      MERGE val.ProductIssue AS target
      USING (SELECT applicable.ProductId, applicable.ValidationProfileId, applicable.FieldRequirementId, applicable.FieldCode
             FROM #Applicable applicable INNER JOIN #Chunk chunk ON chunk.ProductId = applicable.ProductId
             WHERE applicable.IsMissing = 1) AS source
      ON target.ProductId = source.ProductId AND target.FieldRequirementId = source.FieldRequirementId
      WHEN MATCHED THEN UPDATE SET ValidationProfileId = source.ValidationProfileId, IssueCode = N''MISSING_REQUIRED_FIELD'', Message = CONCAT(N''Manjka obvezno polje: '', source.FieldCode), IsActive = 1, LastDetectedUtc = SYSUTCDATETIME(), ResolvedUtc = NULL
      WHEN NOT MATCHED THEN INSERT (ProductId, ValidationProfileId, FieldRequirementId, IssueCode, Message) VALUES (source.ProductId, source.ValidationProfileId, source.FieldRequirementId, N''MISSING_REQUIRED_FIELD'', CONCAT(N''Manjka obvezno polje: '', source.FieldCode));

      /* Zapiranje: dobesedno pogoji iz 249 (tudi za neaktiven izdelek in neaktiven profil), polja iz #FieldPresent. */
      UPDATE issue SET IsActive = 0, ResolvedUtc = SYSUTCDATETIME()
      FROM #Chunk chunk
      INNER JOIN val.ProductIssue issue ON issue.ProductId = chunk.ProductId AND issue.IsActive = 1
      INNER JOIN val.ValidationProfile profile ON profile.ValidationProfileId = issue.ValidationProfileId
      WHERE (NOT (profile.Scope <> N''WEB'' OR EXISTS
              (SELECT 1 FROM #Shop shop WHERE shop.ProductId = issue.ProductId AND shop.WebShopCode = profile.CategoryTreeCode))
        OR NOT EXISTS
        (
          SELECT 1 FROM val.FieldRequirement requirement
          WHERE requirement.FieldRequirementId = issue.FieldRequirementId AND requirement.IsActive = 1 AND requirement.IsRequired = 1
            AND (requirement.CategoryCode IS NULL OR EXISTS
              (SELECT 1 FROM #ScopedRequirement scoped
               INNER JOIN #Effective effective ON effective.ProductId = issue.ProductId
                 AND effective.CategoryTreeCode = scoped.CategoryTreeCode AND effective.AttributeCode = scoped.AttributeCode
                 AND effective.DefinedAtCategoryCode = scoped.CategoryCode AND effective.Level <> N''EXCLUDED''
               WHERE scoped.FieldRequirementId = requirement.FieldRequirementId))
            AND (COALESCE(requirement.OriginScope, profile.OriginScope) IS NULL OR EXISTS
              (SELECT 1 FROM #Origin origin
               WHERE origin.ProductId = issue.ProductId
                 AND ((COALESCE(requirement.OriginScope, profile.OriginScope) = N''FOREIGN'' AND origin.Kind <> N''SI'')
                   OR (COALESCE(requirement.OriginScope, profile.OriginScope) = N''EU'' AND origin.Kind IN (N''EU'', N''UNKNOWN''))
                   OR (COALESCE(requirement.OriginScope, profile.OriginScope) = N''THIRD'' AND origin.Kind = N''THIRD''))))
            AND NOT EXISTS (SELECT 1 FROM #FieldPresent present WHERE present.ProductId = issue.ProductId AND present.FieldCode = requirement.FieldCode)
            AND NOT EXISTS (SELECT 1 FROM val.ProductFieldWaiver waiver WHERE waiver.ProductId = issue.ProductId AND waiver.FieldCode = requirement.FieldCode AND waiver.IsActive = 1)
        ));

      INSERT #Score (ProductId, ValidationProfileId, Completeness, Status)
      SELECT applicable.ProductId, applicable.ValidationProfileId,
          CAST(100.0 * (COUNT(applicable.FieldRequirementId) - SUM(CASE WHEN issue.ProductIssueId IS NULL THEN 0 ELSE 1 END)) / NULLIF(COUNT(applicable.FieldRequirementId), 0) AS decimal(5,2)),
          CASE WHEN SUM(CASE WHEN issue.ProductIssueId IS NOT NULL AND requirement.Severity = N''ERROR'' THEN 1 ELSE 0 END) = 0
            THEN N''VALID'' ELSE N''INVALID'' END
      FROM #Applicable applicable
      INNER JOIN #Chunk chunk ON chunk.ProductId = applicable.ProductId
      INNER JOIN val.FieldRequirement requirement ON requirement.FieldRequirementId = applicable.FieldRequirementId
      LEFT JOIN val.ProductIssue issue ON issue.ProductId = applicable.ProductId AND issue.FieldRequirementId = applicable.FieldRequirementId AND issue.IsActive = 1
      GROUP BY applicable.ProductId, applicable.ValidationProfileId;

      MERGE val.ProductValidationState AS target
      USING (SELECT score.* FROM #Score score INNER JOIN #Chunk chunk ON chunk.ProductId = score.ProductId) AS source
        ON target.ProductId = source.ProductId AND target.ValidationProfileId = source.ValidationProfileId
      WHEN MATCHED THEN UPDATE SET Status = source.Status, Completeness = source.Completeness, ValidatedUtc = SYSUTCDATETIME()
      WHEN NOT MATCHED THEN INSERT (ProductId, ValidationProfileId, Status, Completeness, ValidatedUtc) VALUES (source.ProductId, source.ValidationProfileId, source.Status, source.Completeness, SYSUTCDATETIME());

      /* 248: stanje profila, ki za izdelek ne velja (vec), se izbrise. */
      DELETE state
      FROM val.ProductValidationState state
      INNER JOIN #Chunk chunk ON chunk.ProductId = state.ProductId
      INNER JOIN #Active active ON active.ProductId = state.ProductId
      WHERE NOT EXISTS
        (SELECT 1 FROM #Score score WHERE score.ProductId = state.ProductId AND score.ValidationProfileId = state.ValidationProfileId);

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
              AND (profile.Scope <> N''WEB'' OR EXISTS
                (SELECT 1 FROM #Shop shop WHERE shop.ProductId = product.ProductId AND shop.WebShopCode = profile.CategoryTreeCode))
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
                (SELECT 1 FROM #Shop shop WHERE shop.ProductId = product.ProductId AND shop.WebShopCode = profile.CategoryTreeCode))
          ), 0),
          LastValidatedUtc = SYSUTCDATETIME()
      FROM canon.Product product
      INNER JOIN #Chunk chunk ON chunk.ProductId = product.ProductId
      INNER JOIN #Active active ON active.ProductId = product.ProductId;

      COMMIT TRANSACTION;
      SET @Current += 1;
    END;
  END TRY
  BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    DECLARE @ErrorMessage nvarchar(4000) = ERROR_MESSAGE();
    EXEC ops.LogError @Layer = N''val'', @Severity = N''Error'', @ErrorCode = N''RUN_VALIDATION_FAILED'', @Message = @ErrorMessage;
    THROW;
  END CATCH;
END;');

/* Preverba: nova oblika in pravila 249 (poreklo, potrditve) so v zivi definiciji. */
IF OBJECT_DEFINITION(OBJECT_ID(N'val.RunValidationForProducts')) NOT LIKE N'%HitrejsaValidacijaPaketov320%'
  THROW 53201, N'320: val.RunValidationForProducts ni nova oblika.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'val.RunValidationForProducts')) NOT LIKE N'%#Origin%' OR OBJECT_DEFINITION(OBJECT_ID(N'val.RunValidationForProducts')) NOT LIKE N'%ProductFieldWaiver%'
  THROW 53202, N'320: val.RunValidationForProducts ne pozna porekla ali potrditev.', 1;
