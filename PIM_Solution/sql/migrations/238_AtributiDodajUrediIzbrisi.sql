/* 238: register atributov - dodajanje, urejanje in brisanje iz intraneta.

   Uporabnik 2026-09-21 (»nemore se dodajat atributov«): »treba dodat da se dodaja piše briše«.

   Stran /nastavitve/atributi je do zdaj znala samo prevesti ime in povezati enoto z atributom.
   Nov atribut je nastajal stransko (canon.EnsureAttributeDefinition iz naborov, 177), osnovne
   lastnosti (skupina, tip, enota, prevedljivost, opomba) ni bilo mogoce urediti (canon.
   SaveAttributeDefinition iz 125 s COALESCE prazne vrednosti ne zna pobrisati), brisanja ni bilo.

   Kaj ta migracija doda (vse v canon, revizija v b2b.AuditLog kot pri 177/178):
     canon.CreateAttributeDefinition  - nov atribut: slovensko ime (obvezno; iz njega koda, ce je
                                        klicatelj ne poda), skupina, tip, enota, prevedljivost,
                                        opomba in imena v ostalih jezikih v eni transakciji. Zavrne
                                        obstojeco kodo in obstojece slovensko ime.
     canon.UpdateAttributeDefinition  - urejanje z izrecnim pomenom: NULL POBRISE skupino/enoto/
                                        opombo/par enote (za razliko od SaveAttributeDefinition, ki
                                        NULL bere kot »pusti«). Ista pravila za verigo enot (125).
     intranet.GetAttributeUsage       - kje vse atribut zivi, preden ga kdo izbrise: vrednosti pri
                                        izdelkih (canon + pim; po SLOVENSKEM imenu, ker
                                        canon.ProductAttribute hrani ime in ne kode - glej 125),
                                        nabori kategorij, preslikave virov, pari enot, zahteve
                                        validacije, prevodi.
     canon.DeleteAttributeDefinition  - trajni izbris. Brez @Force zavrne atribut, ki ima vrednosti
                                        pri izdelkih (izbira: deaktiviraj ali potrdi brisanje z
                                        vrednostmi). Odstrani prevode in vrstice naborov, deaktivira
                                        preslikave virov (vrstica ostane zaradi zgodovine) in zahteve
                                        validacije, pocisti pare enot, zapise revizijo.

   Migrator ne pozna GO (061), zato je vsak postopek v EXEC(N'...'). */
SET XACT_ABORT ON;

/* --- 1) nov atribut ----------------------------------------------------------------------- */
EXEC(N'CREATE OR ALTER PROCEDURE canon.CreateAttributeDefinition
  @Name nvarchar(400),
  @AttributeCode nvarchar(200) = NULL,
  @AttributeGroup nvarchar(100) = NULL,
  @DataType nvarchar(20) = NULL,
  @Unit nvarchar(50) = NULL,
  @IsTranslatable bit = 0,
  @Note nvarchar(600) = NULL,
  @TranslationsJson nvarchar(max) = NULL,
  @Actor nvarchar(200),
  @CreatedCode nvarchar(200) OUTPUT
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  SET @Name = NULLIF(LTRIM(RTRIM(@Name)), N'''');
  SET @Actor = NULLIF(LTRIM(RTRIM(@Actor)), N'''');
  SET @AttributeCode = NULLIF(LTRIM(RTRIM(@AttributeCode)), N'''');
  SET @AttributeGroup = NULLIF(LTRIM(RTRIM(@AttributeGroup)), N'''');
  SET @Unit = NULLIF(LTRIM(RTRIM(@Unit)), N'''');
  SET @Note = NULLIF(LTRIM(RTRIM(@Note)), N'''');
  SET @DataType = COALESCE(NULLIF(UPPER(LTRIM(RTRIM(@DataType))), N''''), N''TEXT'');
  SET @TranslationsJson = NULLIF(LTRIM(RTRIM(@TranslationsJson)), N'''');
  IF @Name IS NULL THROW 52380, N''Slovensko ime atributa je prazno.'', 1;
  IF @Actor IS NULL THROW 52381, N''Kdo ustvarja atribut, mora biti znano (Actor).'', 1;
  IF @DataType NOT IN (N''TEXT'', N''NUMBER'', N''BOOL'', N''ENUM'') THROW 52382, N''Neznan tip podatka (TEXT, NUMBER, BOOL, ENUM).'', 1;
  IF @TranslationsJson IS NOT NULL AND ISJSON(@TranslationsJson) = 0 THROW 52383, N''Imena po jezikih niso veljaven JSON.'', 1;

  /* Koda: klicateljeva (poenotena z istim pravilom kot iz imena) ali iz slovenskega imena. */
  SET @CreatedCode = COALESCE(NULLIF(canon.AttributeCodeFromName(@AttributeCode), N''''), canon.AttributeCodeFromName(@Name));
  IF NULLIF(@CreatedCode, N'''') IS NULL THROW 52384, N''Iz imena ni mogoce narediti kode atributa.'', 1;

  IF EXISTS (SELECT 1 FROM canon.AttributeDefinition WHERE AttributeCode = @CreatedCode)
  BEGIN
    DECLARE @CodeMessage nvarchar(1000) = CONCAT(N''Atribut s kodo '', @CreatedCode, N'' ze obstaja'',
      CASE WHEN EXISTS (SELECT 1 FROM canon.AttributeDefinition WHERE AttributeCode = @CreatedCode AND IsActive = 0) THEN N'' (neaktiven - vklopi ga v podrobnostih)'' ELSE N'''' END,
      N''. Uredi obstojecega ali izberi drugo kodo.'');
    THROW 52385, @CodeMessage, 1;
  END;

  DECLARE @SameName nvarchar(200) =
    (SELECT TOP (1) translation.AttributeCode FROM canon.AttributeTranslation translation
     INNER JOIN canon.AttributeDefinition definition ON definition.AttributeCode = translation.AttributeCode
     WHERE translation.LanguageCode = N''sl'' AND translation.Name = @Name
     ORDER BY definition.IsActive DESC, translation.AttributeCode);
  IF @SameName IS NOT NULL
  BEGIN
    DECLARE @NameMessage nvarchar(1000) = CONCAT(N''Atribut s slovenskim imenom "'', @Name, N''" ze obstaja (koda '', @SameName, N''). Isto ime bi pomesalo vrednosti pri izdelkih, ki se hranijo po imenu.'');
    THROW 52386, @NameMessage, 1;
  END;

  DECLARE @Vhod TABLE (LanguageCode nvarchar(10) NOT NULL PRIMARY KEY, Name nvarchar(400) NOT NULL);
  IF @TranslationsJson IS NOT NULL
    INSERT @Vhod (LanguageCode, Name)
    SELECT LTRIM(RTRIM(vrstica.lang)), LTRIM(RTRIM(MAX(vrstica.name)))
    FROM OPENJSON(@TranslationsJson) WITH (lang nvarchar(10) N''$.lang'', name nvarchar(400) N''$.name'') vrstica
    WHERE NULLIF(LTRIM(RTRIM(vrstica.name)), N'''') IS NOT NULL AND NULLIF(LTRIM(RTRIM(vrstica.lang)), N'''') IS NOT NULL
      AND LTRIM(RTRIM(vrstica.lang)) <> N''sl''
    GROUP BY LTRIM(RTRIM(vrstica.lang));
  DECLARE @NeznanJezik nvarchar(10) =
    (SELECT TOP (1) vhod.LanguageCode FROM @Vhod vhod
     WHERE NOT EXISTS (SELECT 1 FROM canon.Language WHERE LanguageCode = vhod.LanguageCode AND IsActive = 1));
  IF @NeznanJezik IS NOT NULL
  BEGIN
    DECLARE @LangMessage nvarchar(400) = CONCAT(N''Jezik "'', @NeznanJezik, N''" ni v sifrantu ali ni aktiven.'');
    THROW 52387, @LangMessage, 1;
  END;

  BEGIN TRANSACTION;
  INSERT canon.AttributeDefinition (AttributeCode, AttributeGroup, DataType, Unit, IsTranslatable, IsUnitCandidate, IsActive, SortOrder, Note, UpdatedUtc, UpdatedBy)
  VALUES (@CreatedCode, @AttributeGroup, @DataType, @Unit, ISNULL(@IsTranslatable, 0),
    CASE WHEN @Name LIKE N''Enota %'' THEN 1 ELSE 0 END, 1, 100, @Note, SYSUTCDATETIME(), @Actor);
  INSERT canon.AttributeTranslation (AttributeCode, LanguageCode, Name) VALUES (@CreatedCode, N''sl'', @Name);
  INSERT canon.AttributeTranslation (AttributeCode, LanguageCode, Name)
  SELECT @CreatedCode, LanguageCode, Name FROM @Vhod;
  INSERT b2b.AuditLog (OrganizationId, EntityType, EntityKey, ActionCode, OldValueJson, NewValueJson, ChangedBy, ChangedUtc)
  VALUES (0, N''AttributeDefinition'', @CreatedCode, N''ADD'', NULL,
    (SELECT @Name AS name, @AttributeGroup AS [group], @DataType AS dataType, @Unit AS unit, @IsTranslatable AS translatable,
            (SELECT LanguageCode AS lang, Name AS name FROM @Vhod FOR JSON PATH) AS translations
     FOR JSON PATH, WITHOUT_ARRAY_WRAPPER), @Actor, SYSUTCDATETIME());
  COMMIT TRANSACTION;
END');

/* --- 2) urejanje z izrecnim pomenom (NULL pobrise) -------------------------------------- */
EXEC(N'CREATE OR ALTER PROCEDURE canon.UpdateAttributeDefinition
  @AttributeCode nvarchar(200),
  @AttributeGroup nvarchar(100) = NULL,
  @DataType nvarchar(20),
  @Unit nvarchar(50) = NULL,
  @IsTranslatable bit,
  @IsUnitCandidate bit,
  @UnitOfAttributeCode nvarchar(200) = NULL,
  @IsActive bit,
  @Note nvarchar(600) = NULL,
  @Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  SET @Actor = NULLIF(LTRIM(RTRIM(@Actor)), N'''');
  SET @AttributeGroup = NULLIF(LTRIM(RTRIM(@AttributeGroup)), N'''');
  SET @Unit = NULLIF(LTRIM(RTRIM(@Unit)), N'''');
  SET @Note = NULLIF(LTRIM(RTRIM(@Note)), N'''');
  SET @UnitOfAttributeCode = NULLIF(LTRIM(RTRIM(@UnitOfAttributeCode)), N'''');
  SET @DataType = UPPER(LTRIM(RTRIM(@DataType)));
  IF @Actor IS NULL THROW 52390, N''Akter je obvezen: brez njega sprememba nima lastnika.'', 1;
  IF NOT EXISTS (SELECT 1 FROM canon.AttributeDefinition WHERE AttributeCode = @AttributeCode)
    THROW 52391, N''Te lastnosti v sifrantu ni.'', 1;
  IF @DataType NOT IN (N''TEXT'', N''NUMBER'', N''BOOL'', N''ENUM'') THROW 52392, N''Neznan tip podatka (TEXT, NUMBER, BOOL, ENUM).'', 1;
  IF @UnitOfAttributeCode IS NOT NULL
  BEGIN
    IF @UnitOfAttributeCode = @AttributeCode THROW 52393, N''Lastnost ne more biti enota same sebe.'', 1;
    IF NOT EXISTS (SELECT 1 FROM canon.AttributeDefinition WHERE AttributeCode = @UnitOfAttributeCode AND IsActive = 1)
      THROW 52394, N''Lastnost, katere enota naj bi to bila, ne obstaja ali ni aktivna.'', 1;
    IF EXISTS (SELECT 1 FROM canon.AttributeDefinition WHERE AttributeCode = @UnitOfAttributeCode AND UnitOfAttributeCode IS NOT NULL)
      THROW 52395, N''Ciljna lastnost je sama oznacena kot enota; veriga enot ni dovoljena.'', 1;
  END;

  DECLARE @Old nvarchar(max) =
    (SELECT AttributeGroup AS [group], DataType AS dataType, Unit AS unit, IsTranslatable AS translatable,
            IsUnitCandidate AS unitCandidate, UnitOfAttributeCode AS unitOf, IsActive AS active, Note AS note
     FROM canon.AttributeDefinition WHERE AttributeCode = @AttributeCode FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

  BEGIN TRANSACTION;
  UPDATE canon.AttributeDefinition
  SET AttributeGroup = @AttributeGroup, DataType = @DataType, Unit = @Unit,
      IsTranslatable = @IsTranslatable, IsUnitCandidate = @IsUnitCandidate,
      UnitOfAttributeCode = @UnitOfAttributeCode, IsActive = @IsActive, Note = @Note,
      UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = @Actor
  WHERE AttributeCode = @AttributeCode;
  INSERT b2b.AuditLog (OrganizationId, EntityType, EntityKey, ActionCode, OldValueJson, NewValueJson, ChangedBy, ChangedUtc)
  VALUES (0, N''AttributeDefinition'', @AttributeCode, N''UPDATE'', @Old,
    (SELECT @AttributeGroup AS [group], @DataType AS dataType, @Unit AS unit, @IsTranslatable AS translatable,
            @IsUnitCandidate AS unitCandidate, @UnitOfAttributeCode AS unitOf, @IsActive AS active, @Note AS note
     FOR JSON PATH, WITHOUT_ARRAY_WRAPPER), @Actor, SYSUTCDATETIME());
  COMMIT TRANSACTION;
END');

/* --- 3) kje atribut zivi ------------------------------------------------------------------ */
EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetAttributeUsage
  @AttributeCode nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON;
  DECLARE @SlName nvarchar(400) =
    (SELECT TOP (1) Name FROM canon.AttributeTranslation WHERE AttributeCode = @AttributeCode AND LanguageCode = N''sl'');
  SELECT
    AttributeCode = @AttributeCode,
    SloveneName = @SlName,
    Note = definition.Note,
    SortOrder = definition.SortOrder,
    /* Vrednosti pri izdelkih se hranijo po slovenskem imenu (125). */
    ProductValues = (SELECT COUNT_BIG(*) FROM canon.ProductAttribute WHERE @SlName IS NOT NULL AND AttributeCode = @SlName),
    ProductsWithValue = (SELECT COUNT_BIG(DISTINCT ProductId) FROM canon.ProductAttribute WHERE @SlName IS NOT NULL AND AttributeCode = @SlName),
    PimValues = (SELECT COUNT_BIG(*) FROM pim.ProductAttribute WHERE @SlName IS NOT NULL AND AttributeCode = @SlName),
    CategorySets = (SELECT COUNT_BIG(*) FROM canon.CategoryAttributeSet WHERE AttributeCode = @AttributeCode),
    SourceMaps = (SELECT COUNT_BIG(*) FROM map.AttributeMap WHERE AttributeCode = @AttributeCode AND IsActive = 1),
    UnitPairs = (SELECT COUNT_BIG(*) FROM canon.AttributeDefinition WHERE UnitOfAttributeCode = @AttributeCode),
    Requirements = (SELECT COUNT_BIG(*) FROM val.FieldRequirement WHERE @SlName IS NOT NULL AND FieldCode = N''ProductAttribute.'' + @SlName AND IsActive = 1),
    Translations = (SELECT COUNT_BIG(*) FROM canon.AttributeTranslation WHERE AttributeCode = @AttributeCode)
  FROM canon.AttributeDefinition definition
  WHERE definition.AttributeCode = @AttributeCode;
END');

/* --- 4) trajni izbris ---------------------------------------------------------------------- */
EXEC(N'CREATE OR ALTER PROCEDURE canon.DeleteAttributeDefinition
  @AttributeCode nvarchar(200),
  @Actor nvarchar(200),
  @Force bit = 0,
  @DeletedValues bigint = NULL OUTPUT
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  SET @Actor = NULLIF(LTRIM(RTRIM(@Actor)), N'''');
  IF @Actor IS NULL THROW 52400, N''Kdo brise atribut, mora biti znano (Actor).'', 1;
  IF NOT EXISTS (SELECT 1 FROM canon.AttributeDefinition WHERE AttributeCode = @AttributeCode)
    THROW 52401, N''Te lastnosti v sifrantu ni.'', 1;

  DECLARE @SlName nvarchar(400) =
    (SELECT TOP (1) Name FROM canon.AttributeTranslation WHERE AttributeCode = @AttributeCode AND LanguageCode = N''sl'');
  DECLARE @CanonValues bigint = (SELECT COUNT_BIG(*) FROM canon.ProductAttribute WHERE @SlName IS NOT NULL AND AttributeCode = @SlName);
  DECLARE @PimValues bigint = (SELECT COUNT_BIG(*) FROM pim.ProductAttribute WHERE @SlName IS NOT NULL AND AttributeCode = @SlName);
  DECLARE @Products bigint = (SELECT COUNT_BIG(DISTINCT ProductId) FROM canon.ProductAttribute WHERE @SlName IS NOT NULL AND AttributeCode = @SlName);
  IF (@CanonValues + @PimValues) > 0 AND ISNULL(@Force, 0) = 0
  BEGIN
    DECLARE @Blocked nvarchar(1000) = CONCAT(N''Atribut "'', ISNULL(@SlName, @AttributeCode), N''" ima vrednosti pri '', @Products,
      N'' izdelkih ('', @CanonValues + @PimValues, N'' vrednosti). Deaktiviraj ga ali potrdi brisanje skupaj z vrednostmi.'');
    THROW 52402, @Blocked, 1;
  END;

  DECLARE @Old nvarchar(max) =
    (SELECT definition.AttributeCode AS code, @SlName AS name, definition.AttributeGroup AS [group], definition.DataType AS dataType,
            definition.Unit AS unit, definition.IsActive AS active,
            (SELECT LanguageCode AS lang, Name AS name FROM canon.AttributeTranslation WHERE AttributeCode = @AttributeCode FOR JSON PATH) AS translations,
            (SELECT CategoryTreeCode AS tree, CategoryCode AS category, Level AS level FROM canon.CategoryAttributeSet WHERE AttributeCode = @AttributeCode FOR JSON PATH) AS categorySets,
            @CanonValues AS canonValues, @PimValues AS pimValues
     FROM canon.AttributeDefinition definition WHERE definition.AttributeCode = @AttributeCode
     FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

  BEGIN TRANSACTION;
  SET @DeletedValues = 0;
  IF ISNULL(@Force, 0) = 1 AND @SlName IS NOT NULL
  BEGIN
    DELETE FROM canon.ProductAttribute WHERE AttributeCode = @SlName;
    SET @DeletedValues = @DeletedValues + @@ROWCOUNT;
    DELETE FROM pim.ProductAttribute WHERE AttributeCode = @SlName;
    SET @DeletedValues = @DeletedValues + @@ROWCOUNT;
  END;
  DELETE FROM canon.CategoryAttributeSet WHERE AttributeCode = @AttributeCode;
  UPDATE map.AttributeMap
  SET IsActive = 0, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = @Actor,
      Note = LEFT(CONCAT(N''Atribut '', @AttributeCode, N'' izbrisan '', CONVERT(nvarchar(10), SYSUTCDATETIME(), 120), N''. '', ISNULL(Note, N'''')), 600)
  WHERE AttributeCode = @AttributeCode AND IsActive = 1;
  UPDATE canon.AttributeDefinition SET UnitOfAttributeCode = NULL, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = @Actor
  WHERE UnitOfAttributeCode = @AttributeCode;
  IF @SlName IS NOT NULL
    UPDATE val.FieldRequirement SET IsActive = 0 WHERE FieldCode = N''ProductAttribute.'' + @SlName AND IsActive = 1;
  DELETE FROM canon.AttributeTranslation WHERE AttributeCode = @AttributeCode;
  DELETE FROM canon.AttributeDefinition WHERE AttributeCode = @AttributeCode;
  INSERT b2b.AuditLog (OrganizationId, EntityType, EntityKey, ActionCode, OldValueJson, NewValueJson, ChangedBy, ChangedUtc)
  VALUES (0, N''AttributeDefinition'', @AttributeCode, N''DELETE'', @Old,
    (SELECT @Force AS force, @DeletedValues AS deletedValues FOR JSON PATH, WITHOUT_ARRAY_WRAPPER), @Actor, SYSUTCDATETIME());
  COMMIT TRANSACTION;
END');

/* --- Dokaz ------------------------------------------------------------------------------- */
IF OBJECT_ID(N'canon.CreateAttributeDefinition', N'P') IS NULL THROW 52410, N'238: canon.CreateAttributeDefinition ni nastala.', 1;
IF OBJECT_ID(N'canon.UpdateAttributeDefinition', N'P') IS NULL THROW 52411, N'238: canon.UpdateAttributeDefinition ni nastala.', 1;
IF OBJECT_ID(N'intranet.GetAttributeUsage', N'P') IS NULL THROW 52412, N'238: intranet.GetAttributeUsage ni nastala.', 1;
IF OBJECT_ID(N'canon.DeleteAttributeDefinition', N'P') IS NULL THROW 52413, N'238: canon.DeleteAttributeDefinition ni nastala.', 1;
