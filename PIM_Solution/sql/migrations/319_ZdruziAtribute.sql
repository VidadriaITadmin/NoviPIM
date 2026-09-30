/*
  319_ZdruziAtribute — naloga #48 (razvijalec #48, 2026-09-30).

  Nadaljevanje #15 (stran /nastavitve/atributi/ciscenje je bila samo pregled). Lastnik 2026-09-29:
  »Grlo« in »Podnožje / socket« sta isti podatek — ostane Grlo, angleško ime socket; ostale pare
  izbere lastnik sam v seznamu. Nič se ne združi samodejno: združitev sproži uporabnik s pravico
  CatalogWrite (ADMIN, CATALOG_EDITOR) na strani, vsaka ima povratek.

  Kaj naredi:
    1. pim.AttributeMerge — ena združitev: izvorni (opuščeni) in ciljni atribut, kdo, kdaj, povzetek,
       razveljavitev (kdo, kdaj, povzetek).
    2. pim.AttributeMergeItem — vrstica na vsako spremembo (prej/potem): vrednosti pri izdelkih v
       canon.ProductAttribute in pim.ProductAttribute ter nastavitve (preslikave, nabori, zahteve,
       izvozni stolpci, par enote, register). Iz tega razveljavitev vrne prejšnje stanje.
    3. canon.MergeAttributeDefinitions — @DryRun = 1 samo prešteje (predogled za potrditev: po
       podjetjih, trki, nastavitve). Sicer v ENI transakciji:
         vrednosti (po slovenskem imenu atributa, 125), na izdelek in jezik:
           - cilj nima vrednosti              -> vrstica se preimenuje na cilj (MOVED);
           - cilj je prazen niz               -> cilj dobi izvorno vrednost, izvorna vrstica gre (FILLED);
           - cilj ima isto vrednost           -> izvorna vrstica gre (DROPPED_SAME);
           - cilj ima drugo vrednost          -> CILJ ZMAGA, izvorna vrstica gre, zapisana je kot trk
                                                 (DROPPED_CONFLICT) in se da vrniti;
         map.FieldMapping (zajem XML: ProductAttribute.<ime>[ SLO| ANG]) -> na cilj; če ista preslikava
           na cilj že obstaja (npr. BT socket gre danes v oba), se izvorna izklopi — sicer bi naslednji
           zajem opuščeni atribut spet napolnil;
         map.AttributeMap (register virov) -> na cilj (+ map.AttributeMapHistory);
         canon.CategoryAttributeSet -> na cilj; če ga kategorija že ima, se izvorna vrstica izklopi;
         val.FieldRequirement (ProductAttribute.<ime>) -> na cilj; ob enaki zahtevi se izvorna izklopi;
         out.ExportColumn (Attr.<ime>) -> na cilj, če profil cilja še nima; sicer stolpec OSTANE (glava
           katalog.csv se ne spremeni, stolpec ostane prazen) in je v povzetku kot »ostane prazen«;
         canon.AttributeDefinition.UnitOfAttributeCode (par »Enota …«) -> na cilj, če ga cilj še nima;
         izvorni atribut se DEAKTIVIRA (ne izbriše), opomba pove, v kaj je združen;
         angleško ime cilja (npr. »Socket«), če je podano (+ canon.AttributeTranslationHistory).
       Zgodovina izdelka: sprožilec canon.TR_ProductAttribute_FieldHistory, vir ZDRUZITEV_ATRIBUTOV;
       b2b.AuditLog (EntityType AttributeMerge). Vrne povzetek, štetje po podjetjih, primere trkov in
       izdelke (canon ProductId), pri katerih se je ciljna vrednost spremenila (za validacijo).
    4. canon.RevertAttributeMerge — vrne združitev: vrednost, ki jo je kdo po združitvi spremenil, in
       nastavitev, ki je ni več v stanju »potem«, ostane (preskočena s štetjem). Razveljaviti je treba
       od zadnje proti prvi, če si združitve delijo atribut. Vir zgodovine POVRAT_ZDRUZITVE.
    5. intranet.GetAttributeMerges — zadnje združitve za stran (s povzetkom in stanjem povratka).

  Nič ne gre v SAOP (vrednosti atributov niso v out.SaopXmlField). katalog.csv: ciljni stolpec ima
  vrednosti takoj ob naslednjem izvozu; validacija prizadetih izdelkov teče po združitvi iz strani.
  Ročni korak: ne. Idempotentna (tabele IF NULL, procedure CREATE OR ALTER).
*/

SET XACT_ABORT ON;
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;

IF OBJECT_ID(N'pim.AttributeMerge', N'U') IS NULL
BEGIN
  CREATE TABLE pim.AttributeMerge
  (
    AttributeMergeId bigint IDENTITY(1, 1) NOT NULL CONSTRAINT PK_AttributeMerge PRIMARY KEY,
    SourceAttributeCode nvarchar(200) NOT NULL,
    TargetAttributeCode nvarchar(200) NOT NULL,
    SourceName nvarchar(400) NOT NULL,
    TargetName nvarchar(400) NOT NULL,
    SummaryJson nvarchar(max) NULL,
    MergedBy nvarchar(200) NOT NULL,
    MergedUtc datetime2(3) NOT NULL CONSTRAINT DF_AttributeMerge_MergedUtc DEFAULT SYSUTCDATETIME(),
    RevertedBy nvarchar(200) NULL,
    RevertedUtc datetime2(3) NULL,
    RevertSummaryJson nvarchar(max) NULL
  );
END;

IF OBJECT_ID(N'pim.AttributeMergeItem', N'U') IS NULL
BEGIN
  CREATE TABLE pim.AttributeMergeItem
  (
    AttributeMergeItemId bigint IDENTITY(1, 1) NOT NULL CONSTRAINT PK_AttributeMergeItem PRIMARY KEY,
    AttributeMergeId bigint NOT NULL
      CONSTRAINT FK_AttributeMergeItem_Merge FOREIGN KEY REFERENCES pim.AttributeMerge (AttributeMergeId),
    /* canon.ProductAttribute, pim.ProductAttribute, map.FieldMapping, map.AttributeMap, canon.CategoryAttributeSet,
       val.FieldRequirement, out.ExportColumn, canon.AttributeDefinition, canon.AttributeTranslation */
    TableName nvarchar(60) NOT NULL,
    RowId bigint NOT NULL,
    /* MOVED, FILLED, DROPPED_SAME, DROPPED_CONFLICT, RETARGETED, DEACTIVATED, KEPT, UNIT_RETARGETED, RENAMED */
    Action nvarchar(30) NOT NULL,
    ProductKey bigint NULL,          /* canon ProductId ali pim PimProductId (po TableName) */
    CanonProductId bigint NULL,      /* za validacijo */
    OrganizationId int NULL,
    ItemID nvarchar(200) NULL,
    LanguageCode nvarchar(20) NULL,
    TargetRowId bigint NULL,         /* ciljna vrstica vrednosti (FILLED, DROPPED_*) */
    OldValue nvarchar(max) NULL,     /* vrednosti: izvorna vrednost; nastavitve: stanje prej */
    NewValue nvarchar(max) NULL      /* vrednosti: ciljna vrednost; nastavitve: stanje potem */
  );
  CREATE INDEX IX_AttributeMergeItem_Merge ON pim.AttributeMergeItem (AttributeMergeId, TableName, Action);
END;
GO

CREATE OR ALTER PROCEDURE canon.MergeAttributeDefinitions
  @SourceAttributeCode nvarchar(200),
  @TargetAttributeCode nvarchar(200),
  @TargetEnglishName nvarchar(400) = NULL,
  @Actor nvarchar(200),
  @DryRun bit = 0,
  @AttributeMergeId bigint = NULL OUTPUT
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  SET @Actor = NULLIF(LTRIM(RTRIM(@Actor)), N'');
  SET @SourceAttributeCode = NULLIF(LTRIM(RTRIM(@SourceAttributeCode)), N'');
  SET @TargetAttributeCode = NULLIF(LTRIM(RTRIM(@TargetAttributeCode)), N'');
  SET @TargetEnglishName = NULLIF(LTRIM(RTRIM(@TargetEnglishName)), N'');
  SET @AttributeMergeId = NULL;

  IF @Actor IS NULL THROW 53190, N'Kdo zdruzuje atribute, mora biti znano (Actor).', 1;
  IF @SourceAttributeCode IS NULL OR @TargetAttributeCode IS NULL
    THROW 53191, N'Izberi atribut, ki se opusti, in atribut, ki ostane.', 1;
  IF @SourceAttributeCode = @TargetAttributeCode THROW 53192, N'Atributa ni mogoce zdruziti samega vase.', 1;
  IF NOT EXISTS (SELECT 1 FROM canon.AttributeDefinition WHERE AttributeCode = @SourceAttributeCode)
    THROW 53193, N'Atributa, ki naj se opusti, ni v registru.', 1;
  IF NOT EXISTS (SELECT 1 FROM canon.AttributeDefinition WHERE AttributeCode = @TargetAttributeCode AND IsActive = 1)
    THROW 53194, N'Atribut, ki naj ostane, ni v registru ali ni aktiven.', 1;

  DECLARE @SourceName nvarchar(400) = (SELECT Name FROM canon.AttributeTranslation WHERE AttributeCode = @SourceAttributeCode AND LanguageCode = N'sl');
  DECLARE @TargetName nvarchar(400) = (SELECT Name FROM canon.AttributeTranslation WHERE AttributeCode = @TargetAttributeCode AND LanguageCode = N'sl');
  IF @SourceName IS NULL OR @TargetName IS NULL
    THROW 53195, N'Oba atributa morata imeti slovensko ime (vrednosti se hranijo po imenu).', 1;
  DECLARE @OldEnglishName nvarchar(400) = (SELECT Name FROM canon.AttributeTranslation WHERE AttributeCode = @TargetAttributeCode AND LanguageCode = N'en');
  IF @TargetEnglishName IS NOT NULL AND @OldEnglishName IS NOT NULL AND @OldEnglishName COLLATE Latin1_General_BIN2 = @TargetEnglishName COLLATE Latin1_General_BIN2
    SET @TargetEnglishName = NULL;   /* brez spremembe */

  /* --- 1. vrednosti pri izdelkih: razvrstitev (ista za predogled in zapis) ----------------------- */
  CREATE TABLE #V
  (
    TableName nvarchar(60) COLLATE DATABASE_DEFAULT NOT NULL, RowId bigint NOT NULL, ProductKey bigint NOT NULL,
    CanonProductId bigint NULL, OrganizationId int NULL, ItemID nvarchar(200) COLLATE DATABASE_DEFAULT NULL,
    LanguageCode nvarchar(20) COLLATE DATABASE_DEFAULT NULL, SourceValue nvarchar(max) COLLATE DATABASE_DEFAULT NULL,
    TargetRowId bigint NULL, TargetValue nvarchar(max) COLLATE DATABASE_DEFAULT NULL,
    Action nvarchar(30) COLLATE DATABASE_DEFAULT NOT NULL,
    PRIMARY KEY (TableName, RowId)
  );

  INSERT #V (TableName, RowId, ProductKey, CanonProductId, OrganizationId, ItemID, LanguageCode, SourceValue, TargetRowId, TargetValue, Action)
  SELECT N'canon.ProductAttribute', source.ProductAttributeId, source.ProductId, source.ProductId, product.OrganizationId, product.ItemID,
         source.LanguageCode, source.Value, target.ProductAttributeId, target.Value,
         CASE WHEN target.ProductAttributeId IS NULL THEN N'MOVED'
              WHEN LTRIM(RTRIM(target.Value)) = N'' THEN N'FILLED'
              WHEN LTRIM(RTRIM(target.Value)) = LTRIM(RTRIM(source.Value)) THEN N'DROPPED_SAME'
              ELSE N'DROPPED_CONFLICT' END
  FROM canon.ProductAttribute AS source
  INNER JOIN canon.Product AS product ON product.ProductId = source.ProductId
  OUTER APPLY (SELECT TOP (1) candidate.ProductAttributeId, candidate.Value
               FROM canon.ProductAttribute AS candidate
               WHERE candidate.ProductId = source.ProductId AND candidate.AttributeCode = @TargetName
                 AND ISNULL(candidate.LanguageCode, N'') = ISNULL(source.LanguageCode, N'')) AS target
  WHERE source.AttributeCode = @SourceName;

  INSERT #V (TableName, RowId, ProductKey, CanonProductId, OrganizationId, ItemID, LanguageCode, SourceValue, TargetRowId, TargetValue, Action)
  SELECT N'pim.ProductAttribute', source.PimProductAttributeId, source.PimProductId, canonProduct.ProductId, product.OrganizationId, product.ItemID,
         source.LanguageCode, source.Value, target.PimProductAttributeId, target.Value,
         CASE WHEN target.PimProductAttributeId IS NULL THEN N'MOVED'
              WHEN LTRIM(RTRIM(target.Value)) = N'' THEN N'FILLED'
              WHEN LTRIM(RTRIM(target.Value)) = LTRIM(RTRIM(source.Value)) THEN N'DROPPED_SAME'
              ELSE N'DROPPED_CONFLICT' END
  FROM pim.ProductAttribute AS source
  INNER JOIN pim.Product AS product ON product.PimProductId = source.PimProductId
  OUTER APPLY (SELECT TOP (1) c.ProductId FROM canon.Product AS c
               WHERE c.OrganizationId = product.OrganizationId AND c.ItemID = product.ItemID) AS canonProduct
  OUTER APPLY (SELECT TOP (1) candidate.PimProductAttributeId, candidate.Value
               FROM pim.ProductAttribute AS candidate
               WHERE candidate.PimProductId = source.PimProductId AND candidate.AttributeCode = @TargetName
                 AND ISNULL(candidate.LanguageCode, N'') = ISNULL(source.LanguageCode, N'')) AS target
  WHERE source.AttributeCode = @SourceName;

  /* --- 2. nastavitve: razvrstitev --------------------------------------------------------------- */
  CREATE TABLE #C
  (
    TableName nvarchar(60) COLLATE DATABASE_DEFAULT NOT NULL, RowId bigint NOT NULL,
    Action nvarchar(30) COLLATE DATABASE_DEFAULT NOT NULL,
    OldValue nvarchar(max) COLLATE DATABASE_DEFAULT NULL, NewValue nvarchar(max) COLLATE DATABASE_DEFAULT NULL,
    PRIMARY KEY (TableName, RowId)
  );

  /* zajem XML: ProductAttribute.<ime>, <ime> SLO, <ime> ANG */
  INSERT #C (TableName, RowId, Action, OldValue, NewValue)
  SELECT N'map.FieldMapping', mapping.FieldMappingId,
         CASE WHEN EXISTS (SELECT 1 FROM map.FieldMapping AS other
                           WHERE other.SourceConnectorId = mapping.SourceConnectorId AND other.EntityType = mapping.EntityType
                             AND other.SourceElement = mapping.SourceElement AND other.TargetFieldCode = renamed.NewCode)
              THEN N'DEACTIVATED' ELSE N'RETARGETED' END,
         mapping.TargetFieldCode, renamed.NewCode
  FROM map.FieldMapping AS mapping
  CROSS APPLY (SELECT CASE mapping.TargetFieldCode
                        WHEN N'ProductAttribute.' + @SourceName THEN N'ProductAttribute.' + @TargetName
                        WHEN N'ProductAttribute.' + @SourceName + N' SLO' THEN N'ProductAttribute.' + @TargetName + N' SLO'
                        WHEN N'ProductAttribute.' + @SourceName + N' ANG' THEN N'ProductAttribute.' + @TargetName + N' ANG' END AS NewCode) AS renamed
  WHERE mapping.TargetFieldCode IN (N'ProductAttribute.' + @SourceName, N'ProductAttribute.' + @SourceName + N' SLO', N'ProductAttribute.' + @SourceName + N' ANG');
  /* izklop je sprememba samo pri aktivni preslikavi */
  DELETE c FROM #C AS c INNER JOIN map.FieldMapping AS mapping ON mapping.FieldMappingId = c.RowId
  WHERE c.TableName = N'map.FieldMapping' AND c.Action = N'DEACTIVATED' AND mapping.IsActive = 0;

  INSERT #C (TableName, RowId, Action, OldValue, NewValue)
  SELECT N'map.AttributeMap', AttributeMapId, N'RETARGETED', @SourceAttributeCode, @TargetAttributeCode
  FROM map.AttributeMap WHERE AttributeCode = @SourceAttributeCode;

  INSERT #C (TableName, RowId, Action, OldValue, NewValue)
  SELECT N'canon.CategoryAttributeSet', setRow.CategoryAttributeSetId,
         CASE WHEN EXISTS (SELECT 1 FROM canon.CategoryAttributeSet AS other
                           WHERE other.CategoryTreeCode = setRow.CategoryTreeCode AND other.CategoryCode = setRow.CategoryCode
                             AND other.AttributeCode = @TargetAttributeCode)
              THEN N'DEACTIVATED' ELSE N'RETARGETED' END,
         @SourceAttributeCode, @TargetAttributeCode
  FROM canon.CategoryAttributeSet AS setRow
  WHERE setRow.AttributeCode = @SourceAttributeCode;
  DELETE c FROM #C AS c INNER JOIN canon.CategoryAttributeSet AS setRow ON setRow.CategoryAttributeSetId = c.RowId
  WHERE c.TableName = N'canon.CategoryAttributeSet' AND c.Action = N'DEACTIVATED' AND setRow.IsActive = 0;

  INSERT #C (TableName, RowId, Action, OldValue, NewValue)
  SELECT N'val.FieldRequirement', requirement.FieldRequirementId,
         CASE WHEN EXISTS (SELECT 1 FROM val.FieldRequirement AS other
                           WHERE other.ValidationProfileId = requirement.ValidationProfileId
                             AND other.FieldCode = N'ProductAttribute.' + @TargetName
                             AND ISNULL(other.CategoryTreeCode, N'') = ISNULL(requirement.CategoryTreeCode, N'')
                             AND ISNULL(other.CategoryCode, N'') = ISNULL(requirement.CategoryCode, N''))
              THEN N'DEACTIVATED' ELSE N'RETARGETED' END,
         requirement.FieldCode, N'ProductAttribute.' + @TargetName
  FROM val.FieldRequirement AS requirement
  WHERE requirement.FieldCode = N'ProductAttribute.' + @SourceName;
  DELETE c FROM #C AS c INNER JOIN val.FieldRequirement AS requirement ON requirement.FieldRequirementId = c.RowId
  WHERE c.TableName = N'val.FieldRequirement' AND c.Action = N'DEACTIVATED' AND requirement.IsActive = 0;

  INSERT #C (TableName, RowId, Action, OldValue, NewValue)
  SELECT N'out.ExportColumn', exportColumn.ExportColumnId,
         CASE WHEN EXISTS (SELECT 1 FROM out.ExportColumn AS other
                           WHERE other.ExportProfileId = exportColumn.ExportProfileId AND other.CanonicalFieldCode = renamed.NewCode)
              THEN N'KEPT' ELSE N'RETARGETED' END,
         exportColumn.CanonicalFieldCode, renamed.NewCode
  FROM out.ExportColumn AS exportColumn
  CROSS APPLY (SELECT CASE exportColumn.CanonicalFieldCode
                        WHEN N'Attr.' + @SourceName THEN N'Attr.' + @TargetName
                        WHEN N'Attr.' + @SourceName + N' SLO' THEN N'Attr.' + @TargetName + N' SLO'
                        WHEN N'Attr.' + @SourceName + N' ANG' THEN N'Attr.' + @TargetName + N' ANG' END AS NewCode) AS renamed
  WHERE exportColumn.CanonicalFieldCode IN (N'Attr.' + @SourceName, N'Attr.' + @SourceName + N' SLO', N'Attr.' + @SourceName + N' ANG');

  IF NOT EXISTS (SELECT 1 FROM canon.AttributeDefinition WHERE UnitOfAttributeCode = @TargetAttributeCode)
    INSERT #C (TableName, RowId, Action, OldValue, NewValue)
    SELECT N'canon.AttributeDefinition', AttributeDefinitionId, N'UNIT_RETARGETED', @SourceAttributeCode, @TargetAttributeCode
    FROM canon.AttributeDefinition WHERE UnitOfAttributeCode = @SourceAttributeCode;

  /* --- 3. povzetek (predogled in rezultat) ------------------------------------------------------ */
  DECLARE @Summary nvarchar(max) =
    (SELECT @SourceAttributeCode AS sourceCode, @SourceName AS sourceName, @TargetAttributeCode AS targetCode, @TargetName AS targetName,
            @OldEnglishName AS englishNameBefore, COALESCE(@TargetEnglishName, @OldEnglishName) AS englishNameAfter,
            (SELECT COUNT(DISTINCT CONCAT(OrganizationId, N'|', ItemID)) FROM #V) AS products,
            (SELECT COUNT(*) FROM #V WHERE Action = N'MOVED') AS moved,
            (SELECT COUNT(*) FROM #V WHERE Action = N'FILLED') AS filled,
            (SELECT COUNT(*) FROM #V WHERE Action = N'DROPPED_SAME') AS same,
            (SELECT COUNT(*) FROM #V WHERE Action = N'DROPPED_CONFLICT') AS conflicts,
            (SELECT COUNT(*) FROM #C WHERE TableName = N'map.FieldMapping' AND Action = N'RETARGETED') AS fieldMappingsRetargeted,
            (SELECT COUNT(*) FROM #C WHERE TableName = N'map.FieldMapping' AND Action = N'DEACTIVATED') AS fieldMappingsDeactivated,
            (SELECT COUNT(*) FROM #C WHERE TableName = N'map.AttributeMap') AS attributeMaps,
            (SELECT COUNT(*) FROM #C WHERE TableName = N'canon.CategoryAttributeSet' AND Action = N'RETARGETED') AS categorySetsRetargeted,
            (SELECT COUNT(*) FROM #C WHERE TableName = N'canon.CategoryAttributeSet' AND Action = N'DEACTIVATED') AS categorySetsDeactivated,
            (SELECT COUNT(*) FROM #C WHERE TableName = N'val.FieldRequirement' AND Action = N'RETARGETED') AS requirementsRetargeted,
            (SELECT COUNT(*) FROM #C WHERE TableName = N'val.FieldRequirement' AND Action = N'DEACTIVATED') AS requirementsDeactivated,
            (SELECT COUNT(*) FROM #C WHERE TableName = N'out.ExportColumn' AND Action = N'RETARGETED') AS exportColumnsRetargeted,
            (SELECT COUNT(*) FROM #C WHERE TableName = N'out.ExportColumn' AND Action = N'KEPT') AS exportColumnsKeptEmpty,
            (SELECT STRING_AGG(CONVERT(nvarchar(max), exportColumn.OutputColumnName), N', ')
             FROM #C AS c INNER JOIN out.ExportColumn AS exportColumn ON exportColumn.ExportColumnId = c.RowId
             WHERE c.TableName = N'out.ExportColumn' AND c.Action = N'KEPT' AND exportColumn.IsActive = 1) AS exportColumnsKeptNames,
            (SELECT COUNT(*) FROM #C WHERE TableName = N'canon.AttributeDefinition') AS unitPairs,
            CAST(@DryRun AS bit) AS dryRun
     FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

  IF @DryRun = 1
  BEGIN
    SELECT CAST(NULL AS bigint) AS AttributeMergeId, @Summary AS SummaryJson;
    SELECT v.OrganizationId, COALESCE(organization.Name, CONCAT(N'Podjetje ', v.OrganizationId)) AS OrganizationName,
           CAST(ISNULL(organization.IsActive, 0) AS bit) AS IsActive,
           COUNT(DISTINCT v.ItemID) AS Products,
           SUM(CASE WHEN v.Action IN (N'MOVED', N'FILLED') THEN 1 ELSE 0 END) AS Moved,
           SUM(CASE WHEN v.Action = N'DROPPED_SAME' THEN 1 ELSE 0 END) AS Same,
           SUM(CASE WHEN v.Action = N'DROPPED_CONFLICT' THEN 1 ELSE 0 END) AS Conflicts
    FROM #V AS v LEFT JOIN dbo.OrganizationConfig AS organization ON organization.OrganizationId = v.OrganizationId
    GROUP BY v.OrganizationId, organization.Name, organization.IsActive
    ORDER BY COUNT(DISTINCT v.ItemID) DESC;
    SELECT TOP (50) COALESCE(organization.Name, CONCAT(N'Podjetje ', v.OrganizationId)) AS OrganizationName, v.ItemID, v.LanguageCode,
           v.SourceValue, v.TargetValue
    FROM #V AS v LEFT JOIN dbo.OrganizationConfig AS organization ON organization.OrganizationId = v.OrganizationId
    WHERE v.Action = N'DROPPED_CONFLICT'
    ORDER BY CASE v.TableName WHEN N'pim.ProductAttribute' THEN 0 ELSE 1 END, v.OrganizationId, v.ItemID;
    RETURN;
  END;

  /* --- 4. zapis v eni transakciji ---------------------------------------------------------------- */
  DECLARE @Now datetime2(3) = SYSUTCDATETIME();
  DECLARE @Note nvarchar(200) = LEFT(CONCAT(N'Zdruzitev atributa ', @SourceName, N' v ', @TargetName), 200);

  BEGIN TRANSACTION;
    /* zaklep obeh definicij: dve hkratni zdruzitvi istega para ne tečeta vzporedno */
    IF NOT EXISTS (SELECT 1 FROM canon.AttributeDefinition WITH (UPDLOCK, HOLDLOCK)
                   WHERE AttributeCode = @TargetAttributeCode AND IsActive = 1)
      THROW 53194, N'Atribut, ki naj ostane, ni v registru ali ni aktiven.', 1;
    IF NOT EXISTS (SELECT 1 FROM canon.AttributeDefinition WITH (UPDLOCK, HOLDLOCK) WHERE AttributeCode = @SourceAttributeCode)
      THROW 53193, N'Atributa, ki naj se opusti, ni v registru.', 1;

    INSERT pim.AttributeMerge (SourceAttributeCode, TargetAttributeCode, SourceName, TargetName, SummaryJson, MergedBy, MergedUtc)
    VALUES (@SourceAttributeCode, @TargetAttributeCode, @SourceName, @TargetName, @Summary, @Actor, @Now);
    SET @AttributeMergeId = SCOPE_IDENTITY();

    EXEC sys.sp_set_session_context @key = N'ChangeSource', @value = N'ZDRUZITEV_ATRIBUTOV';
    EXEC sys.sp_set_session_context @key = N'ChangedBy', @value = @Actor;
    EXEC sys.sp_set_session_context @key = N'ChangeNote', @value = @Note;

    /* canon */
    UPDATE attribute SET AttributeCode = @TargetName
    FROM canon.ProductAttribute AS attribute
    INNER JOIN #V AS v ON v.TableName = N'canon.ProductAttribute' AND v.RowId = attribute.ProductAttributeId AND v.Action = N'MOVED';
    UPDATE attribute SET Value = v.SourceValue
    FROM canon.ProductAttribute AS attribute
    INNER JOIN #V AS v ON v.TableName = N'canon.ProductAttribute' AND v.TargetRowId = attribute.ProductAttributeId AND v.Action = N'FILLED';
    DELETE attribute
    FROM canon.ProductAttribute AS attribute
    INNER JOIN #V AS v ON v.TableName = N'canon.ProductAttribute' AND v.RowId = attribute.ProductAttributeId
      AND v.Action IN (N'FILLED', N'DROPPED_SAME', N'DROPPED_CONFLICT');

    /* pim */
    UPDATE attribute SET AttributeCode = @TargetName
    FROM pim.ProductAttribute AS attribute
    INNER JOIN #V AS v ON v.TableName = N'pim.ProductAttribute' AND v.RowId = attribute.PimProductAttributeId AND v.Action = N'MOVED';
    UPDATE attribute SET Value = v.SourceValue
    FROM pim.ProductAttribute AS attribute
    INNER JOIN #V AS v ON v.TableName = N'pim.ProductAttribute' AND v.TargetRowId = attribute.PimProductAttributeId AND v.Action = N'FILLED';
    DELETE attribute
    FROM pim.ProductAttribute AS attribute
    INNER JOIN #V AS v ON v.TableName = N'pim.ProductAttribute' AND v.RowId = attribute.PimProductAttributeId
      AND v.Action IN (N'FILLED', N'DROPPED_SAME', N'DROPPED_CONFLICT');

    INSERT pim.AttributeMergeItem (AttributeMergeId, TableName, RowId, Action, ProductKey, CanonProductId, OrganizationId, ItemID,
                                   LanguageCode, TargetRowId, OldValue, NewValue)
    SELECT @AttributeMergeId, TableName, RowId, Action, ProductKey, CanonProductId, OrganizationId, ItemID,
           LanguageCode, TargetRowId, SourceValue, TargetValue
    FROM #V;

    EXEC sys.sp_set_session_context @key = N'ChangeSource', @value = NULL;
    EXEC sys.sp_set_session_context @key = N'ChangedBy', @value = NULL;
    EXEC sys.sp_set_session_context @key = N'ChangeNote', @value = NULL;

    /* nastavitve */
    UPDATE mapping SET TargetFieldCode = c.NewValue, UpdatedBy = @Actor, UpdatedUtc = @Now
    FROM map.FieldMapping AS mapping INNER JOIN #C AS c ON c.TableName = N'map.FieldMapping' AND c.RowId = mapping.FieldMappingId AND c.Action = N'RETARGETED';
    UPDATE mapping SET IsActive = 0, UpdatedBy = @Actor, UpdatedUtc = @Now
    FROM map.FieldMapping AS mapping INNER JOIN #C AS c ON c.TableName = N'map.FieldMapping' AND c.RowId = mapping.FieldMappingId AND c.Action = N'DEACTIVATED';

    INSERT map.AttributeMapHistory (SourceCode, SourceAttributeName, OldAttributeCode, NewAttributeCode, OldIsActive, NewIsActive, ChangedBy, ChangedUtc, Note)
    SELECT am.SourceCode, am.SourceAttributeName, am.AttributeCode, @TargetAttributeCode, am.IsActive, am.IsActive, @Actor, @Now, @Note
    FROM map.AttributeMap AS am INNER JOIN #C AS c ON c.TableName = N'map.AttributeMap' AND c.RowId = am.AttributeMapId;
    UPDATE am SET AttributeCode = @TargetAttributeCode, UpdatedBy = @Actor, UpdatedUtc = @Now
    FROM map.AttributeMap AS am INNER JOIN #C AS c ON c.TableName = N'map.AttributeMap' AND c.RowId = am.AttributeMapId;

    UPDATE setRow SET AttributeCode = @TargetAttributeCode, UpdatedBy = @Actor, UpdatedUtc = @Now
    FROM canon.CategoryAttributeSet AS setRow INNER JOIN #C AS c ON c.TableName = N'canon.CategoryAttributeSet' AND c.RowId = setRow.CategoryAttributeSetId AND c.Action = N'RETARGETED';
    UPDATE setRow SET IsActive = 0, UpdatedBy = @Actor, UpdatedUtc = @Now
    FROM canon.CategoryAttributeSet AS setRow INNER JOIN #C AS c ON c.TableName = N'canon.CategoryAttributeSet' AND c.RowId = setRow.CategoryAttributeSetId AND c.Action = N'DEACTIVATED';

    UPDATE requirement SET FieldCode = c.NewValue
    FROM val.FieldRequirement AS requirement INNER JOIN #C AS c ON c.TableName = N'val.FieldRequirement' AND c.RowId = requirement.FieldRequirementId AND c.Action = N'RETARGETED';
    UPDATE requirement SET IsActive = 0
    FROM val.FieldRequirement AS requirement INNER JOIN #C AS c ON c.TableName = N'val.FieldRequirement' AND c.RowId = requirement.FieldRequirementId AND c.Action = N'DEACTIVATED';

    UPDATE exportColumn SET CanonicalFieldCode = c.NewValue
    FROM out.ExportColumn AS exportColumn INNER JOIN #C AS c ON c.TableName = N'out.ExportColumn' AND c.RowId = exportColumn.ExportColumnId AND c.Action = N'RETARGETED';

    UPDATE definition SET UnitOfAttributeCode = @TargetAttributeCode, UpdatedBy = @Actor, UpdatedUtc = @Now
    FROM canon.AttributeDefinition AS definition INNER JOIN #C AS c ON c.TableName = N'canon.AttributeDefinition' AND c.RowId = definition.AttributeDefinitionId;

    /* izvorni atribut: deaktiviran, ne izbrisan */
    INSERT #C (TableName, RowId, Action, OldValue, NewValue)
    SELECT N'canon.AttributeDefinition', AttributeDefinitionId, N'DEACTIVATED',
           (SELECT IsActive AS isActive, Note AS note FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES),
           (SELECT CAST(0 AS bit) AS isActive FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM canon.AttributeDefinition WHERE AttributeCode = @SourceAttributeCode;
    UPDATE canon.AttributeDefinition
    SET IsActive = 0, UpdatedBy = @Actor, UpdatedUtc = @Now,
        Note = LEFT(CONCAT(N'Zdruzen v ', @TargetName, N' (', CONVERT(nvarchar(10), @Now, 120), N', ', @Actor, N', zdruzitev ', @AttributeMergeId, N'). ', Note), 600)
    WHERE AttributeCode = @SourceAttributeCode;

    /* angleško ime cilja */
    IF @TargetEnglishName IS NOT NULL
    BEGIN
      INSERT canon.AttributeTranslationHistory (AttributeCode, LanguageCode, OldName, NewName, ChangedBy)
      VALUES (@TargetAttributeCode, N'en', @OldEnglishName, @TargetEnglishName, @Actor);
      IF @OldEnglishName IS NULL
        INSERT canon.AttributeTranslation (AttributeCode, LanguageCode, Name) VALUES (@TargetAttributeCode, N'en', @TargetEnglishName);
      ELSE
        UPDATE canon.AttributeTranslation SET Name = @TargetEnglishName WHERE AttributeCode = @TargetAttributeCode AND LanguageCode = N'en';
      INSERT #C (TableName, RowId, Action, OldValue, NewValue)
      SELECT N'canon.AttributeTranslation', AttributeTranslationId, N'RENAMED', @OldEnglishName, @TargetEnglishName
      FROM canon.AttributeTranslation WHERE AttributeCode = @TargetAttributeCode AND LanguageCode = N'en';
    END;

    INSERT pim.AttributeMergeItem (AttributeMergeId, TableName, RowId, Action, OldValue, NewValue)
    SELECT @AttributeMergeId, TableName, RowId, Action, OldValue, NewValue FROM #C;

    INSERT b2b.AuditLog (OrganizationId, EntityType, EntityKey, ActionCode, OldValueJson, NewValueJson, ChangedBy, ChangedUtc)
    VALUES (0, N'AttributeMerge', CONVERT(nvarchar(40), @AttributeMergeId), N'MERGE',
            (SELECT @SourceAttributeCode AS code, @SourceName AS name, CAST(1 AS bit) AS active FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
            @Summary, @Actor, @Now);
  COMMIT TRANSACTION;

  SELECT @AttributeMergeId AS AttributeMergeId, @Summary AS SummaryJson;
  /* izdelki, pri katerih se je ciljna vrednost spremenila -> validacija */
  SELECT DISTINCT CanonProductId AS ProductId FROM #V WHERE Action IN (N'MOVED', N'FILLED') AND CanonProductId IS NOT NULL;
END;
GO

CREATE OR ALTER PROCEDURE canon.RevertAttributeMerge
  @AttributeMergeId bigint,
  @Actor nvarchar(200),
  @DryRun bit = 0
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  SET @Actor = NULLIF(LTRIM(RTRIM(@Actor)), N'');
  IF @Actor IS NULL THROW 53196, N'Kdo razveljavlja zdruzitev, mora biti znano (Actor).', 1;

  DECLARE @SourceCode nvarchar(200), @TargetCode nvarchar(200), @SourceName nvarchar(400), @TargetName nvarchar(400), @RevertedUtc datetime2(3), @MergedUtc datetime2(3);
  SELECT @SourceCode = SourceAttributeCode, @TargetCode = TargetAttributeCode, @SourceName = SourceName, @TargetName = TargetName,
         @RevertedUtc = RevertedUtc, @MergedUtc = MergedUtc
  FROM pim.AttributeMerge WHERE AttributeMergeId = @AttributeMergeId;
  IF @SourceCode IS NULL THROW 53197, N'Te zdruzitve ni.', 1;
  IF @RevertedUtc IS NOT NULL THROW 53198, N'Ta zdruzitev je ze razveljavljena.', 1;
  DECLARE @Later bigint = (SELECT TOP (1) AttributeMergeId FROM pim.AttributeMerge
                           WHERE AttributeMergeId > @AttributeMergeId AND RevertedUtc IS NULL
                             AND (SourceAttributeCode IN (@SourceCode, @TargetCode) OR TargetAttributeCode IN (@SourceCode, @TargetCode))
                           ORDER BY AttributeMergeId DESC);
  IF @Later IS NOT NULL
  BEGIN
    DECLARE @LaterMessage nvarchar(400) = CONCAT(N'Najprej razveljavi poznejso zdruzitev st. ', @Later, N', ki uporablja isti atribut.');
    THROW 53199, @LaterMessage, 1;
  END;

  CREATE TABLE #I
  (
    AttributeMergeItemId bigint NOT NULL PRIMARY KEY, TableName nvarchar(60) COLLATE DATABASE_DEFAULT NOT NULL, RowId bigint NOT NULL,
    Action nvarchar(30) COLLATE DATABASE_DEFAULT NOT NULL, ProductKey bigint NULL, CanonProductId bigint NULL,
    LanguageCode nvarchar(20) COLLATE DATABASE_DEFAULT NULL, TargetRowId bigint NULL,
    OldValue nvarchar(max) COLLATE DATABASE_DEFAULT NULL, NewValue nvarchar(max) COLLATE DATABASE_DEFAULT NULL,
    Done bit NOT NULL DEFAULT 0
  );
  INSERT #I (AttributeMergeItemId, TableName, RowId, Action, ProductKey, CanonProductId, LanguageCode, TargetRowId, OldValue, NewValue)
  SELECT AttributeMergeItemId, TableName, RowId, Action, ProductKey, CanonProductId, LanguageCode, TargetRowId, OldValue, NewValue
  FROM pim.AttributeMergeItem WHERE AttributeMergeId = @AttributeMergeId;

  /* Kaj se da vrniti (vrstica je še v stanju »potem«). */
  UPDATE i SET Done = 1 FROM #I AS i
  WHERE i.TableName = N'canon.ProductAttribute' AND i.Action = N'MOVED'
    AND EXISTS (SELECT 1 FROM canon.ProductAttribute AS a WHERE a.ProductAttributeId = i.RowId AND a.AttributeCode = @TargetName
                  AND a.Value COLLATE Latin1_General_BIN2 = i.OldValue COLLATE Latin1_General_BIN2)
    AND NOT EXISTS (SELECT 1 FROM canon.ProductAttribute AS a WHERE a.ProductId = i.ProductKey AND a.AttributeCode = @SourceName
                      AND ISNULL(a.LanguageCode, N'') = ISNULL(i.LanguageCode, N''));
  UPDATE i SET Done = 1 FROM #I AS i
  WHERE i.TableName = N'pim.ProductAttribute' AND i.Action = N'MOVED'
    AND EXISTS (SELECT 1 FROM pim.ProductAttribute AS a WHERE a.PimProductAttributeId = i.RowId AND a.AttributeCode = @TargetName
                  AND a.Value COLLATE Latin1_General_BIN2 = i.OldValue COLLATE Latin1_General_BIN2)
    AND NOT EXISTS (SELECT 1 FROM pim.ProductAttribute AS a WHERE a.PimProductId = i.ProductKey AND a.AttributeCode = @SourceName
                      AND ISNULL(a.LanguageCode, N'') = ISNULL(i.LanguageCode, N''));
  UPDATE i SET Done = 1 FROM #I AS i
  WHERE i.TableName = N'canon.ProductAttribute' AND i.Action IN (N'FILLED', N'DROPPED_SAME', N'DROPPED_CONFLICT')
    AND EXISTS (SELECT 1 FROM canon.Product AS p WHERE p.ProductId = i.ProductKey)
    AND NOT EXISTS (SELECT 1 FROM canon.ProductAttribute AS a WHERE a.ProductId = i.ProductKey AND a.AttributeCode = @SourceName
                      AND ISNULL(a.LanguageCode, N'') = ISNULL(i.LanguageCode, N''));
  UPDATE i SET Done = 1 FROM #I AS i
  WHERE i.TableName = N'pim.ProductAttribute' AND i.Action IN (N'FILLED', N'DROPPED_SAME', N'DROPPED_CONFLICT')
    AND EXISTS (SELECT 1 FROM pim.Product AS p WHERE p.PimProductId = i.ProductKey)
    AND NOT EXISTS (SELECT 1 FROM pim.ProductAttribute AS a WHERE a.PimProductId = i.ProductKey AND a.AttributeCode = @SourceName
                      AND ISNULL(a.LanguageCode, N'') = ISNULL(i.LanguageCode, N''));

  UPDATE i SET Done = 1 FROM #I AS i INNER JOIN map.FieldMapping AS m ON m.FieldMappingId = i.RowId
  WHERE i.TableName = N'map.FieldMapping'
    AND ((i.Action = N'RETARGETED' AND m.TargetFieldCode = i.NewValue
          AND NOT EXISTS (SELECT 1 FROM map.FieldMapping AS o WHERE o.SourceConnectorId = m.SourceConnectorId AND o.EntityType = m.EntityType
                            AND o.SourceElement = m.SourceElement AND o.TargetFieldCode = i.OldValue))
      OR (i.Action = N'DEACTIVATED' AND m.IsActive = 0));
  UPDATE i SET Done = 1 FROM #I AS i INNER JOIN map.AttributeMap AS m ON m.AttributeMapId = i.RowId
  WHERE i.TableName = N'map.AttributeMap' AND m.AttributeCode = i.NewValue;
  UPDATE i SET Done = 1 FROM #I AS i INNER JOIN canon.CategoryAttributeSet AS s ON s.CategoryAttributeSetId = i.RowId
  WHERE i.TableName = N'canon.CategoryAttributeSet'
    AND ((i.Action = N'RETARGETED' AND s.AttributeCode = i.NewValue
          AND NOT EXISTS (SELECT 1 FROM canon.CategoryAttributeSet AS o WHERE o.CategoryTreeCode = s.CategoryTreeCode
                            AND o.CategoryCode = s.CategoryCode AND o.AttributeCode = i.OldValue))
      OR (i.Action = N'DEACTIVATED' AND s.IsActive = 0));
  UPDATE i SET Done = 1 FROM #I AS i INNER JOIN val.FieldRequirement AS r ON r.FieldRequirementId = i.RowId
  WHERE i.TableName = N'val.FieldRequirement'
    AND ((i.Action = N'RETARGETED' AND r.FieldCode = i.NewValue
          AND NOT EXISTS (SELECT 1 FROM val.FieldRequirement AS o WHERE o.ValidationProfileId = r.ValidationProfileId AND o.FieldCode = i.OldValue
                            AND ISNULL(o.CategoryTreeCode, N'') = ISNULL(r.CategoryTreeCode, N'') AND ISNULL(o.CategoryCode, N'') = ISNULL(r.CategoryCode, N'')))
      OR (i.Action = N'DEACTIVATED' AND r.IsActive = 0));
  UPDATE i SET Done = 1 FROM #I AS i INNER JOIN out.ExportColumn AS e ON e.ExportColumnId = i.RowId
  WHERE i.TableName = N'out.ExportColumn' AND i.Action = N'RETARGETED' AND e.CanonicalFieldCode = i.NewValue;
  UPDATE i SET Done = 1 FROM #I AS i INNER JOIN canon.AttributeDefinition AS d ON d.AttributeDefinitionId = i.RowId
  WHERE i.TableName = N'canon.AttributeDefinition'
    AND ((i.Action = N'UNIT_RETARGETED' AND d.UnitOfAttributeCode = @TargetCode) OR i.Action = N'DEACTIVATED');
  UPDATE i SET Done = 1 FROM #I AS i INNER JOIN canon.AttributeTranslation AS t ON t.AttributeTranslationId = i.RowId
  WHERE i.TableName = N'canon.AttributeTranslation' AND i.Action = N'RENAMED' AND t.Name COLLATE Latin1_General_BIN2 = i.NewValue COLLATE Latin1_General_BIN2;

  DECLARE @Summary nvarchar(max) =
    (SELECT (SELECT COUNT(*) FROM #I WHERE TableName IN (N'canon.ProductAttribute', N'pim.ProductAttribute') AND Done = 1) AS valuesReverted,
            (SELECT COUNT(*) FROM #I WHERE TableName IN (N'canon.ProductAttribute', N'pim.ProductAttribute') AND Done = 0) AS valuesSkipped,
            (SELECT COUNT(*) FROM #I WHERE TableName NOT IN (N'canon.ProductAttribute', N'pim.ProductAttribute') AND Action <> N'KEPT' AND Done = 1) AS settingsReverted,
            (SELECT COUNT(*) FROM #I WHERE TableName NOT IN (N'canon.ProductAttribute', N'pim.ProductAttribute') AND Action <> N'KEPT' AND Done = 0) AS settingsSkipped,
            CAST(@DryRun AS bit) AS dryRun
     FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

  IF @DryRun = 1
  BEGIN
    SELECT @AttributeMergeId AS AttributeMergeId, @Summary AS SummaryJson;
    RETURN;
  END;

  DECLARE @Now datetime2(3) = SYSUTCDATETIME();
  DECLARE @Note nvarchar(200) = LEFT(CONCAT(N'Povratek zdruzitve ', @AttributeMergeId, N' (', @SourceName, N' iz ', @TargetName, N')'), 200);

  BEGIN TRANSACTION;
    UPDATE pim.AttributeMerge WITH (UPDLOCK, HOLDLOCK) SET RevertedBy = @Actor, RevertedUtc = @Now, RevertSummaryJson = @Summary
    WHERE AttributeMergeId = @AttributeMergeId AND RevertedUtc IS NULL;
    IF @@ROWCOUNT = 0 THROW 53198, N'Ta zdruzitev je ze razveljavljena.', 1;

    EXEC sys.sp_set_session_context @key = N'ChangeSource', @value = N'POVRAT_ZDRUZITVE';
    EXEC sys.sp_set_session_context @key = N'ChangedBy', @value = @Actor;
    EXEC sys.sp_set_session_context @key = N'ChangeNote', @value = @Note;

    /* vrednosti: MOVED nazaj na izvorno ime; FILLED cilj nazaj na prazno; izbrisane izvorne vrstice nazaj */
    UPDATE a SET AttributeCode = @SourceName
    FROM canon.ProductAttribute AS a INNER JOIN #I AS i ON i.TableName = N'canon.ProductAttribute' AND i.Action = N'MOVED' AND i.Done = 1 AND i.RowId = a.ProductAttributeId;
    UPDATE a SET Value = i.NewValue
    FROM canon.ProductAttribute AS a INNER JOIN #I AS i ON i.TableName = N'canon.ProductAttribute' AND i.Action = N'FILLED' AND i.Done = 1 AND i.TargetRowId = a.ProductAttributeId
    WHERE a.AttributeCode = @TargetName AND a.Value COLLATE Latin1_General_BIN2 = i.OldValue COLLATE Latin1_General_BIN2;
    INSERT canon.ProductAttribute (ProductId, AttributeCode, LanguageCode, Value)
    SELECT i.ProductKey, @SourceName, i.LanguageCode, i.OldValue
    FROM #I AS i WHERE i.TableName = N'canon.ProductAttribute' AND i.Action IN (N'FILLED', N'DROPPED_SAME', N'DROPPED_CONFLICT') AND i.Done = 1;

    UPDATE a SET AttributeCode = @SourceName
    FROM pim.ProductAttribute AS a INNER JOIN #I AS i ON i.TableName = N'pim.ProductAttribute' AND i.Action = N'MOVED' AND i.Done = 1 AND i.RowId = a.PimProductAttributeId;
    UPDATE a SET Value = i.NewValue
    FROM pim.ProductAttribute AS a INNER JOIN #I AS i ON i.TableName = N'pim.ProductAttribute' AND i.Action = N'FILLED' AND i.Done = 1 AND i.TargetRowId = a.PimProductAttributeId
    WHERE a.AttributeCode = @TargetName AND a.Value COLLATE Latin1_General_BIN2 = i.OldValue COLLATE Latin1_General_BIN2;
    INSERT pim.ProductAttribute (PimProductId, AttributeCode, LanguageCode, Value)
    SELECT i.ProductKey, @SourceName, i.LanguageCode, i.OldValue
    FROM #I AS i WHERE i.TableName = N'pim.ProductAttribute' AND i.Action IN (N'FILLED', N'DROPPED_SAME', N'DROPPED_CONFLICT') AND i.Done = 1;

    EXEC sys.sp_set_session_context @key = N'ChangeSource', @value = NULL;
    EXEC sys.sp_set_session_context @key = N'ChangedBy', @value = NULL;
    EXEC sys.sp_set_session_context @key = N'ChangeNote', @value = NULL;

    /* nastavitve */
    UPDATE m SET TargetFieldCode = i.OldValue, UpdatedBy = @Actor, UpdatedUtc = @Now
    FROM map.FieldMapping AS m INNER JOIN #I AS i ON i.TableName = N'map.FieldMapping' AND i.Action = N'RETARGETED' AND i.Done = 1 AND i.RowId = m.FieldMappingId;
    UPDATE m SET IsActive = 1, UpdatedBy = @Actor, UpdatedUtc = @Now
    FROM map.FieldMapping AS m INNER JOIN #I AS i ON i.TableName = N'map.FieldMapping' AND i.Action = N'DEACTIVATED' AND i.Done = 1 AND i.RowId = m.FieldMappingId;

    INSERT map.AttributeMapHistory (SourceCode, SourceAttributeName, OldAttributeCode, NewAttributeCode, OldIsActive, NewIsActive, ChangedBy, ChangedUtc, Note)
    SELECT m.SourceCode, m.SourceAttributeName, m.AttributeCode, i.OldValue, m.IsActive, m.IsActive, @Actor, @Now, @Note
    FROM map.AttributeMap AS m INNER JOIN #I AS i ON i.TableName = N'map.AttributeMap' AND i.Done = 1 AND i.RowId = m.AttributeMapId;
    UPDATE m SET AttributeCode = i.OldValue, UpdatedBy = @Actor, UpdatedUtc = @Now
    FROM map.AttributeMap AS m INNER JOIN #I AS i ON i.TableName = N'map.AttributeMap' AND i.Done = 1 AND i.RowId = m.AttributeMapId;

    UPDATE s SET AttributeCode = i.OldValue, UpdatedBy = @Actor, UpdatedUtc = @Now
    FROM canon.CategoryAttributeSet AS s INNER JOIN #I AS i ON i.TableName = N'canon.CategoryAttributeSet' AND i.Action = N'RETARGETED' AND i.Done = 1 AND i.RowId = s.CategoryAttributeSetId;
    UPDATE s SET IsActive = 1, UpdatedBy = @Actor, UpdatedUtc = @Now
    FROM canon.CategoryAttributeSet AS s INNER JOIN #I AS i ON i.TableName = N'canon.CategoryAttributeSet' AND i.Action = N'DEACTIVATED' AND i.Done = 1 AND i.RowId = s.CategoryAttributeSetId;

    UPDATE r SET FieldCode = i.OldValue
    FROM val.FieldRequirement AS r INNER JOIN #I AS i ON i.TableName = N'val.FieldRequirement' AND i.Action = N'RETARGETED' AND i.Done = 1 AND i.RowId = r.FieldRequirementId;
    UPDATE r SET IsActive = 1
    FROM val.FieldRequirement AS r INNER JOIN #I AS i ON i.TableName = N'val.FieldRequirement' AND i.Action = N'DEACTIVATED' AND i.Done = 1 AND i.RowId = r.FieldRequirementId;

    UPDATE e SET CanonicalFieldCode = i.OldValue
    FROM out.ExportColumn AS e INNER JOIN #I AS i ON i.TableName = N'out.ExportColumn' AND i.Action = N'RETARGETED' AND i.Done = 1 AND i.RowId = e.ExportColumnId;

    UPDATE d SET UnitOfAttributeCode = @SourceCode, UpdatedBy = @Actor, UpdatedUtc = @Now
    FROM canon.AttributeDefinition AS d INNER JOIN #I AS i ON i.TableName = N'canon.AttributeDefinition' AND i.Action = N'UNIT_RETARGETED' AND i.Done = 1 AND i.RowId = d.AttributeDefinitionId;
    UPDATE d SET IsActive = ISNULL(TRY_CONVERT(bit, JSON_VALUE(i.OldValue, N'$.isActive')), 1),
                 Note = JSON_VALUE(i.OldValue, N'$.note'), UpdatedBy = @Actor, UpdatedUtc = @Now
    FROM canon.AttributeDefinition AS d INNER JOIN #I AS i ON i.TableName = N'canon.AttributeDefinition' AND i.Action = N'DEACTIVATED' AND i.Done = 1 AND i.RowId = d.AttributeDefinitionId;

    INSERT canon.AttributeTranslationHistory (AttributeCode, LanguageCode, OldName, NewName, ChangedBy)
    SELECT t.AttributeCode, t.LanguageCode, t.Name, ISNULL(i.OldValue, N''), @Actor   /* prej ni bilo imena: izbris = prazno ime */
    FROM canon.AttributeTranslation AS t INNER JOIN #I AS i ON i.TableName = N'canon.AttributeTranslation' AND i.Action = N'RENAMED' AND i.Done = 1 AND i.RowId = t.AttributeTranslationId;
    UPDATE t SET Name = i.OldValue
    FROM canon.AttributeTranslation AS t INNER JOIN #I AS i ON i.TableName = N'canon.AttributeTranslation' AND i.Action = N'RENAMED' AND i.Done = 1 AND i.RowId = t.AttributeTranslationId
    WHERE i.OldValue IS NOT NULL;
    DELETE t
    FROM canon.AttributeTranslation AS t INNER JOIN #I AS i ON i.TableName = N'canon.AttributeTranslation' AND i.Action = N'RENAMED' AND i.Done = 1 AND i.RowId = t.AttributeTranslationId
    WHERE i.OldValue IS NULL;

    INSERT b2b.AuditLog (OrganizationId, EntityType, EntityKey, ActionCode, OldValueJson, NewValueJson, ChangedBy, ChangedUtc)
    VALUES (0, N'AttributeMerge', CONVERT(nvarchar(40), @AttributeMergeId), N'REVERT',
            (SELECT SummaryJson FROM pim.AttributeMerge WHERE AttributeMergeId = @AttributeMergeId), @Summary, @Actor, @Now);
  COMMIT TRANSACTION;

  SELECT @AttributeMergeId AS AttributeMergeId, @Summary AS SummaryJson;
  SELECT DISTINCT CanonProductId AS ProductId FROM #I
  WHERE Done = 1 AND Action IN (N'MOVED', N'FILLED') AND CanonProductId IS NOT NULL;
END;
GO

CREATE OR ALTER PROCEDURE intranet.GetAttributeMerges
  @Top int = 50
AS
BEGIN
  SET NOCOUNT ON;
  SELECT TOP (@Top) attributeMerge.AttributeMergeId, attributeMerge.SourceAttributeCode, attributeMerge.TargetAttributeCode, attributeMerge.SourceName, attributeMerge.TargetName,
         attributeMerge.SummaryJson, attributeMerge.MergedBy, attributeMerge.MergedUtc, attributeMerge.RevertedBy, attributeMerge.RevertedUtc, attributeMerge.RevertSummaryJson,
         CAST(CASE WHEN attributeMerge.RevertedUtc IS NULL AND NOT EXISTS
                     (SELECT 1 FROM pim.AttributeMerge AS later
                      WHERE later.AttributeMergeId > attributeMerge.AttributeMergeId AND later.RevertedUtc IS NULL
                        AND (later.SourceAttributeCode IN (attributeMerge.SourceAttributeCode, attributeMerge.TargetAttributeCode)
                             OR later.TargetAttributeCode IN (attributeMerge.SourceAttributeCode, attributeMerge.TargetAttributeCode)))
                   THEN 1 ELSE 0 END AS bit) AS CanRevert
  FROM pim.AttributeMerge AS attributeMerge
  ORDER BY attributeMerge.AttributeMergeId DESC;
END;
GO
