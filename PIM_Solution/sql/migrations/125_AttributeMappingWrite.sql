/*
  125 — urejanje preslikav atributov in imen v vseh jezikih; par za enoto.

  Register (121) in sifrant (122) sta pokazala, kaj je in kaj manjka. Ta migracija da cloveku
  pot, da to popravi iz vmesnika, in isto obliko kot pri kategorijah (109, 113): postopek s
  pravili in zgodovino, stran brez lastne presoje.

  --- Par za enoto ---------------------------------------------------------------------------

  34 kod v sifrantu je oznacenih z IsUnitCandidate: "Enota napetosti", "Enota dolzine paketa II"
  in podobno. Migracija 124 je dodala stolpec Unit v canon.ProductAttribute, a ga je pustila
  praznega, ker pretvorba "Enota napetosti" -> "Napetost" v slovenscini ni mehanska.

  Tu nastane UnitOfAttributeCode: clovek pove, cigava enota je. Sele ko par obstaja, je prenos
  vrednosti mehanski - in to je naslednji korak, ne ta. Zapisan par sam po sebi ne premakne
  nobene vrednosti.
*/

SET XACT_ABORT ON;

/* --- 1) Cigava enota je ta lastnost --------------------------------------------------------- */

EXEC(N'
IF COL_LENGTH(N''canon.AttributeDefinition'', N''UnitOfAttributeCode'') IS NULL
  ALTER TABLE canon.AttributeDefinition ADD UnitOfAttributeCode nvarchar(200) NULL;
');

/* --- 2) Urejanje preslikave ------------------------------------------------------------------ */

EXEC(N'
CREATE OR ALTER PROCEDURE map.SaveAttributeMap
  @SourceCode nvarchar(100),
  @SourceAttributeName nvarchar(400),
  @AttributeCode nvarchar(200),
  @LanguageCode nvarchar(10) = NULL,
  @IsUnit bit = 0,
  @Actor nvarchar(200),
  @Note nvarchar(600) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  IF NULLIF(LTRIM(RTRIM(@Actor)), N'''') IS NULL
    THROW 125001, N''Akter je obvezen: brez njega sprememba nima lastnika.'', 1;

  IF NOT EXISTS (SELECT 1 FROM canon.AttributeDefinition
                 WHERE AttributeCode = @AttributeCode AND IsActive = 1)
    THROW 125002, N''Ciljna lastnost ne obstaja v sifrantu ali ni aktivna.'', 1;

  IF @LanguageCode IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM canon.Language WHERE LanguageCode = @LanguageCode AND IsActive = 1)
    THROW 125003, N''Jezik ni v sifrantu ali ni aktiven.'', 1;

  /*
    Preslikava na izvorni atribut, ki ga register ne pozna, je ugibanje: vir ga ni poslal in
    nihce ne ve, ali sploh obstaja. Register je edini dokaz, kaj je prislo.
  */
  IF NOT EXISTS (SELECT 1 FROM map.SourceAttribute
                 WHERE SourceCode = @SourceCode AND SourceAttributeName = @SourceAttributeName)
    THROW 125004, N''Tega izvornega atributa register ne pozna; vir ga se ni poslal.'', 1;

  DECLARE @StaraKoda nvarchar(200) = NULL, @StaroAktivno bit = NULL;
  SELECT @StaraKoda = AttributeCode, @StaroAktivno = IsActive
  FROM map.AttributeMap
  WHERE SourceCode = @SourceCode AND SourceAttributeName = @SourceAttributeName;

  IF @StaraKoda IS NOT NULL AND @StaraKoda = @AttributeCode AND @StaroAktivno = 1
     AND EXISTS (SELECT 1 FROM map.AttributeMap
                 WHERE SourceCode = @SourceCode AND SourceAttributeName = @SourceAttributeName
                   AND ISNULL(LanguageCode, N''~'') = ISNULL(@LanguageCode, N''~'') AND IsUnit = @IsUnit)
  BEGIN
    SELECT N''Unchanged'' AS Outcome;
    RETURN;
  END

  BEGIN TRANSACTION;

  IF @StaraKoda IS NULL
    INSERT map.AttributeMap
      (SourceCode, SourceAttributeName, AttributeCode, LanguageCode, IsUnit, IsActive, UpdatedUtc, UpdatedBy, Note)
    VALUES (@SourceCode, @SourceAttributeName, @AttributeCode, @LanguageCode, @IsUnit, 1,
            SYSUTCDATETIME(), @Actor, @Note);
  ELSE
    UPDATE map.AttributeMap
    SET AttributeCode = @AttributeCode, LanguageCode = @LanguageCode, IsUnit = @IsUnit,
        IsActive = 1, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = @Actor, Note = @Note
    WHERE SourceCode = @SourceCode AND SourceAttributeName = @SourceAttributeName;

  INSERT map.AttributeMapHistory
    (SourceCode, SourceAttributeName, OldAttributeCode, NewAttributeCode, OldIsActive, NewIsActive, ChangedBy, Note)
  VALUES (@SourceCode, @SourceAttributeName, @StaraKoda, @AttributeCode, @StaroAktivno, 1, @Actor, @Note);

  COMMIT TRANSACTION;

  SELECT CASE WHEN @StaraKoda IS NULL THEN N''Created'' ELSE N''Updated'' END AS Outcome;
END;
');

EXEC(N'
CREATE OR ALTER PROCEDURE map.DeactivateAttributeMap
  @SourceCode nvarchar(100), @SourceAttributeName nvarchar(400),
  @Actor nvarchar(200), @Note nvarchar(600) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  IF NULLIF(LTRIM(RTRIM(@Actor)), N'''') IS NULL
    THROW 125001, N''Akter je obvezen: brez njega sprememba nima lastnika.'', 1;

  DECLARE @StaraKoda nvarchar(200) = NULL, @StaroAktivno bit = NULL;
  SELECT @StaraKoda = AttributeCode, @StaroAktivno = IsActive
  FROM map.AttributeMap WHERE SourceCode = @SourceCode AND SourceAttributeName = @SourceAttributeName;

  IF @StaraKoda IS NULL BEGIN SELECT N''NotFound'' AS Outcome; RETURN; END
  IF @StaroAktivno = 0 BEGIN SELECT N''Unchanged'' AS Outcome; RETURN; END

  BEGIN TRANSACTION;
  /* Ugasnjena preslikava pove, da je bila odlocitev sprejeta in preklicana; izbrisana pove
     samo, da je ni, in atribut bi se naslednjic spet prijavil kot nov. */
  UPDATE map.AttributeMap
  SET IsActive = 0, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = @Actor, Note = @Note
  WHERE SourceCode = @SourceCode AND SourceAttributeName = @SourceAttributeName;

  INSERT map.AttributeMapHistory
    (SourceCode, SourceAttributeName, OldAttributeCode, NewAttributeCode, OldIsActive, NewIsActive, ChangedBy, Note)
  VALUES (@SourceCode, @SourceAttributeName, @StaraKoda, @StaraKoda, @StaroAktivno, 0, @Actor, @Note);
  COMMIT TRANSACTION;
  SELECT N''Deactivated'' AS Outcome;
END;
');

/* --- 3) Urejanje lastnosti v sifrantu -------------------------------------------------------- */

EXEC(N'
CREATE OR ALTER PROCEDURE canon.SaveAttributeDefinition
  @AttributeCode nvarchar(200),
  @AttributeGroup nvarchar(100) = NULL,
  @DataType nvarchar(20) = NULL,
  @Unit nvarchar(50) = NULL,
  @IsTranslatable bit = NULL,
  @UnitOfAttributeCode nvarchar(200) = NULL,
  @Actor nvarchar(200),
  @Note nvarchar(600) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  IF NULLIF(LTRIM(RTRIM(@Actor)), N'''') IS NULL
    THROW 125001, N''Akter je obvezen: brez njega sprememba nima lastnika.'', 1;
  IF NOT EXISTS (SELECT 1 FROM canon.AttributeDefinition WHERE AttributeCode = @AttributeCode)
    THROW 125005, N''Te lastnosti v sifrantu ni.'', 1;
  IF @DataType IS NOT NULL AND @DataType NOT IN (N''TEXT'', N''NUMBER'', N''BOOL'', N''ENUM'')
    THROW 125006, N''Neznan tip podatka.'', 1;

  IF @UnitOfAttributeCode IS NOT NULL
  BEGIN
    IF @UnitOfAttributeCode = @AttributeCode
      THROW 125007, N''Lastnost ne more biti enota same sebe.'', 1;
    IF NOT EXISTS (SELECT 1 FROM canon.AttributeDefinition
                   WHERE AttributeCode = @UnitOfAttributeCode AND IsActive = 1)
      THROW 125008, N''Lastnost, katere enota naj bi to bila, ne obstaja.'', 1;
    /*
      Veriga enot nima pomena in bi jo bilo tezko razvozlati nazaj: enota enote ni nic.
    */
    IF EXISTS (SELECT 1 FROM canon.AttributeDefinition
               WHERE AttributeCode = @UnitOfAttributeCode AND UnitOfAttributeCode IS NOT NULL)
      THROW 125009, N''Ciljna lastnost je sama oznacena kot enota; veriga enot ni dovoljena.'', 1;
  END

  UPDATE canon.AttributeDefinition
  SET AttributeGroup = COALESCE(@AttributeGroup, AttributeGroup),
      DataType = COALESCE(@DataType, DataType),
      Unit = COALESCE(@Unit, Unit),
      IsTranslatable = COALESCE(@IsTranslatable, IsTranslatable),
      UnitOfAttributeCode = @UnitOfAttributeCode,
      Note = COALESCE(@Note, Note),
      UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = @Actor
  WHERE AttributeCode = @AttributeCode;

  SELECT N''Updated'' AS Outcome;
END;
');

/* --- 4) Imena lastnosti v vec jezikih hkrati -------------------------------------------------- */

EXEC(N'
CREATE OR ALTER PROCEDURE canon.SaveAttributeTranslations
  @AttributeCode nvarchar(200),
  @TranslationsJson nvarchar(max),   /* [{"lang":"en","name":"Dominant material"}, ...] */
  @Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  IF NULLIF(LTRIM(RTRIM(@Actor)), N'''') IS NULL
    THROW 125001, N''Akter je obvezen: brez njega sprememba nima lastnika.'', 1;
  IF NOT EXISTS (SELECT 1 FROM canon.AttributeDefinition WHERE AttributeCode = @AttributeCode)
    THROW 125005, N''Te lastnosti v sifrantu ni.'', 1;

  DECLARE @Vhod TABLE(LanguageCode nvarchar(10) NOT NULL PRIMARY KEY, Name nvarchar(400) NOT NULL);
  INSERT @Vhod(LanguageCode, Name)
  SELECT LTRIM(RTRIM(vrstica.lang)), LTRIM(RTRIM(vrstica.name))
  FROM OPENJSON(@TranslationsJson)
    WITH (lang nvarchar(10) N''$.lang'', name nvarchar(400) N''$.name'') vrstica
  WHERE NULLIF(LTRIM(RTRIM(vrstica.name)), N'''') IS NOT NULL;

  DECLARE @Neznan nvarchar(10) = NULL;
  SELECT TOP (1) @Neznan = v.LanguageCode FROM @Vhod v
  WHERE NOT EXISTS (SELECT 1 FROM canon.Language WHERE LanguageCode = v.LanguageCode AND IsActive = 1);
  IF @Neznan IS NOT NULL THROW 125003, N''Jezik ni v sifrantu ali ni aktiven.'', 1;

  /* Ce en jezik pade, ne obvelja noben - delno shranjen prevod izgleda opravljen. */
  BEGIN TRANSACTION;

  INSERT canon.AttributeTranslationHistory (AttributeCode, LanguageCode, OldName, NewName, ChangedBy)
  SELECT @AttributeCode, v.LanguageCode, staro.Name, v.Name, @Actor
  FROM @Vhod v
  LEFT JOIN canon.AttributeTranslation staro
    ON staro.AttributeCode = @AttributeCode AND staro.LanguageCode = v.LanguageCode
  WHERE staro.Name IS NULL OR staro.Name <> v.Name;

  MERGE canon.AttributeTranslation AS target
  USING (SELECT LanguageCode, Name FROM @Vhod) AS source
    ON target.AttributeCode = @AttributeCode AND target.LanguageCode = source.LanguageCode
  WHEN MATCHED AND target.Name <> source.Name THEN UPDATE SET Name = source.Name
  WHEN NOT MATCHED THEN INSERT (AttributeCode, LanguageCode, Name)
    VALUES (@AttributeCode, source.LanguageCode, source.Name);

  DECLARE @Spremenjenih int = @@ROWCOUNT;
  COMMIT TRANSACTION;
  SELECT @Spremenjenih AS Changed;
END;
');

/* --- 5) Bralna modela dobita jezike in par enote ---------------------------------------------- */

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetAttributeDefinitions
  @Iskanje nvarchar(200) = NULL,
  @SamoEnote bit = 0,
  @SamoBrezVira bit = 0,
  @SamoBrezPara bit = 0
AS
BEGIN
  SET NOCOUNT ON;
  SELECT
    definicija.AttributeCode,
    ime.Name AS AttributeName,
    definicija.AttributeGroup,
    definicija.DataType,
    definicija.Unit,
    definicija.IsTranslatable,
    definicija.IsUnitCandidate,
    definicija.UnitOfAttributeCode,
    definicija.IsActive,
    ISNULL(viri.Virov, 0) AS SourceCount,
    viri.Seznam AS SourceList,
    ISNULL(uporaba.Izdelkov, 0) AS ProductCount,
    prevodi.Json AS TranslationsJson,
    (SELECT COUNT(DISTINCT LanguageCode) FROM canon.Language WHERE IsActive = 1) AS LanguageCount
  FROM canon.AttributeDefinition definicija
  LEFT JOIN canon.AttributeTranslation ime
    ON ime.AttributeCode = definicija.AttributeCode AND ime.LanguageCode = N''sl''
  OUTER APPLY
  (
    SELECT (SELECT p.LanguageCode AS lang, p.Name AS name
            FROM canon.AttributeTranslation p
            WHERE p.AttributeCode = definicija.AttributeCode
            ORDER BY p.LanguageCode FOR JSON PATH) AS Json
  ) prevodi
  OUTER APPLY
  (
    SELECT COUNT(*) AS Virov, STRING_AGG(x.SourceCode, N'', '') AS Seznam
    FROM (SELECT DISTINCT SourceCode FROM map.AttributeMap
          WHERE AttributeCode = definicija.AttributeCode AND IsActive = 1) x
  ) viri
  OUTER APPLY
  (
    /* Stevec se bere po slovenskem imenu, ker canon.ProductAttribute se hrani ime in ne kode. */
    SELECT COUNT_BIG(DISTINCT vrednost.ProductId) AS Izdelkov
    FROM canon.ProductAttribute vrednost
    WHERE vrednost.AttributeCode = ime.Name
  ) uporaba
  WHERE (@Iskanje IS NULL
         OR definicija.AttributeCode LIKE N''%'' + @Iskanje + N''%''
         OR ISNULL(ime.Name, N'''') LIKE N''%'' + @Iskanje + N''%'')
    AND (@SamoEnote = 0 OR definicija.IsUnitCandidate = 1)
    AND (@SamoBrezVira = 0 OR ISNULL(viri.Virov, 0) = 0)
    AND (@SamoBrezPara = 0 OR (definicija.IsUnitCandidate = 1 AND definicija.UnitOfAttributeCode IS NULL))
  ORDER BY ISNULL(uporaba.Izdelkov, 0) DESC, definicija.AttributeCode;
END;
');
