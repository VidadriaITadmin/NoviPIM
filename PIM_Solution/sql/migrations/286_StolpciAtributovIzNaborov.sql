/*
  286 — katalog.csv: stolpci atributov nastanejo sami iz naborov atributov po kategorijah.

  Uporabnik 2026-09-25 (po prvem izvozu IQ + ViD, 285): »zakaj atributi niso šli v katalog.csv od vid izdelkov? vsa
  VD.OBM izdelki imajo prazno … sem dodal atribute na strani Nabori atributov po kategorijah in v PIMu so notri«;
  »to mora dodajat ali spreminjat glede na to katere atribute ima artikel«, »to ne sme biti fiksno«.

  Vzroka sta bila dva:
    1. Stolpci katalog.csv so bili stalen seznam v out.ExportColumn (181). Atribut, ki ga je kdo dodal v nabor
       (Premer objema, Družina, Način pakiranja, Število polov, RAL … — 34 na razvojni bazi), stolpca ni imel,
       zato ni šel ven, četudi je bil na kartici.
    2. Vrednost brez oznake jezika (ViD VD.OBM: »siva«, »PA«) ni prišla v stolpec »… SLO«, ki ga napolni samo
       vrednost z jezikom sl.

  Kaj naredi:
    - out.SyncAttributeExportColumns @ProfileCode: za vsak aktiven atribut iz aktivnih naborov (Level <> EXCLUDED),
      ki v profilu še nima stolpca, doda stolpec — prevedljiv atribut (canon.AttributeDefinition.IsTranslatable)
      dobi »Ime ANG« in »Ime SLO«, ostali »Ime« (z enoto v glavi, »Ime [mm]«, kot od 216). Kanonična koda je
      Attr.<slovensko ime>, kot jo polni out.GetExportRows. Novi stolpci gredo NA KONEC datoteke, obstoječi se ne
      premaknejo. Samodejni stolpec (ColumnCode ATTR_…) se ob preimenovanju atributa preimenuje, ob umiku iz vseh
      naborov izklopi, ob vrnitvi spet vklopi. Ročno določenih stolpcev se ne dotika. Vrne spremembe.
      Kliče ga PIM.B2bWorker pred vsakim izvozom katalog.csv; lahko ga pokliče tudi skrbnik.
    - out.GetExportRows: vrednost atributa brez jezika gre v stolpec »… SLO«, če artikel nima vrednosti v sl.
    - out.ExportColumnChange: zgodovina samodejnih sprememb (kdaj, kateri stolpec, kaj).

  Magento: nov stolpec je nov atribut v datoteki. Izvajalec spletne trgovine mora vedeti, da se glava lahko
  razširi (stolpci na koncu) in da imena stolpcev sledijo imenom atributov v PIM.

  Objekti: out.SyncAttributeExportColumns, out.ExportColumnChange, sprememba out.GetExportRows (dva izraza).
  Ročni korak: ne. Migrator ne pozna GO, zato procedure v EXEC(N'...').
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

IF UNICODE(N'č') <> 269
  THROW 52990, N'286: datoteka ni prebrana kot UTF-8 (sqlcmd -f 65001 ali Invoke-PendingMigrations.ps1).', 1;
IF OBJECT_ID(N'out.GetExportRows', N'P') IS NULL OR OBJECT_ID(N'canon.AttributeDefinition', N'U') IS NULL
  THROW 52991, N'286 potrebuje out.GetExportRows in canon.AttributeDefinition.', 1;

/* --- 1) Zgodovina samodejnih sprememb stolpcev ------------------------------------------------- */
IF OBJECT_ID(N'out.ExportColumnChange', N'U') IS NULL
  CREATE TABLE out.ExportColumnChange
  (
    ExportColumnChangeId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_ExportColumnChange PRIMARY KEY,
    ExportProfileId int NOT NULL,
    ColumnCode nvarchar(200) NOT NULL,
    ChangeKind nvarchar(20) NOT NULL,           /* DODAN, PREIMENOVAN, IZKLOPLJEN, VKLOPLJEN */
    OldOutputColumnName nvarchar(400) NULL,
    NewOutputColumnName nvarchar(400) NULL,
    AttributeCode nvarchar(400) NULL,
    ChangedUtc datetime2(3) NOT NULL CONSTRAINT DF_ExportColumnChange_ChangedUtc DEFAULT (SYSUTCDATETIME()),
    ChangedBy nvarchar(200) NOT NULL
  );

/* --- 2) Uskladitev stolpcev atributov z nabori ----------------------------------------------- */
EXEC(N'
CREATE OR ALTER PROCEDURE out.SyncAttributeExportColumns
  @ProfileCode nvarchar(200) = N''MAGENTO_PRODUCTS'',
  @Actor nvarchar(200) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  /* 286: stolpci katalog.csv za atribute iz naborov atributov po kategorijah (uporabnik 2026-09-25: »to ne sme
     biti fiksno«). Dodaja samo na konec; samodejni stolpec (ATTR_<koda>[_SLO|_ANG]) preimenuje in izklopi/vklopi,
     ročnih ne spreminja. Vrne spremembe tega klica. */
  SET @Actor = ISNULL(NULLIF(LTRIM(RTRIM(@Actor)), N''''), SUSER_SNAME());
  DECLARE @ProfileId int = (SELECT ExportProfileId FROM out.ExportProfile WHERE ProfileCode = @ProfileCode AND IsActive = 1);
  IF @ProfileId IS NULL THROW 52992, N''Aktivni izvozni profil ne obstaja.'', 1;

  /* Želeni stolpci: atribut iz aktivnega nabora, slovensko ime iz prevodov (tako ga hrani pim.ProductAttribute). */
  CREATE TABLE #Wanted
    (ColumnCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY,
     AttributeCode nvarchar(400) COLLATE DATABASE_DEFAULT NOT NULL,
     OutputColumnName nvarchar(400) COLLATE DATABASE_DEFAULT NOT NULL,
     CanonicalFieldCode nvarchar(400) COLLATE DATABASE_DEFAULT NOT NULL,
     SortKey int NOT NULL, Part int NOT NULL);

  ;WITH attributeInSet AS
  (
    SELECT DISTINCT definition.AttributeCode, definition.IsTranslatable, definition.Unit, definition.SortOrder,
      Name = LTRIM(RTRIM(COALESCE(slName.Name, definition.AttributeCode)))
    FROM canon.CategoryAttributeSet AS attributeSet
    INNER JOIN canon.AttributeDefinition AS definition
      ON definition.AttributeCode = attributeSet.AttributeCode AND definition.IsActive = 1
    LEFT JOIN canon.AttributeTranslation AS slName
      ON slName.AttributeCode = definition.AttributeCode AND slName.LanguageCode = N''sl''
    WHERE attributeSet.IsActive = 1 AND attributeSet.Level <> N''EXCLUDED''
  )
  INSERT #Wanted (ColumnCode, AttributeCode, OutputColumnName, CanonicalFieldCode, SortKey, Part)
  SELECT LEFT(N''ATTR_'' + attribute.AttributeCode + part.Suffix, 200), attribute.AttributeCode,
    LEFT(attribute.Name
      + CASE WHEN attribute.IsTranslatable = 0 AND NULLIF(LTRIM(RTRIM(attribute.Unit)), N'''') IS NOT NULL
                  AND CHARINDEX(N''['', attribute.Name) = 0
             THEN N'' ['' + LTRIM(RTRIM(attribute.Unit)) + N'']'' ELSE N'''' END
      + part.Header, 128),
    N''Attr.'' + attribute.Name + part.Header,
    ISNULL(attribute.SortOrder, 0), part.Part
  FROM attributeInSet AS attribute
  CROSS APPLY (SELECT N'''' AS Suffix, N'''' AS Header, 0 AS Part WHERE attribute.IsTranslatable = 0
               UNION ALL SELECT N''_ANG'', N'' ANG'', 1 WHERE attribute.IsTranslatable = 1
               UNION ALL SELECT N''_SLO'', N'' SLO'', 2 WHERE attribute.IsTranslatable = 1) AS part;

  CREATE TABLE #Change
    (ColumnCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL, ChangeKind nvarchar(20) COLLATE DATABASE_DEFAULT NOT NULL,
     OldName nvarchar(400) COLLATE DATABASE_DEFAULT NULL, NewName nvarchar(400) COLLATE DATABASE_DEFAULT NULL,
     AttributeCode nvarchar(400) COLLATE DATABASE_DEFAULT NULL);

  BEGIN TRANSACTION;
  /* Zaklep profila: dva sočasna izvoza ne dodata istega stolpca z isto zaporedno številko. */
  DECLARE @Lock int;
  EXEC @Lock = sys.sp_getapplock @Resource = N''out.SyncAttributeExportColumns'', @LockMode = N''Exclusive'', @LockOwner = N''Transaction'', @LockTimeout = 60000;
  IF @Lock < 0 THROW 52993, N''Uskladitev stolpcev atributov že teče.'', 1;

  /* Samodejni stolpec atributa, ki ni več v nobenem naboru: izklop. */
  UPDATE registryColumn SET IsActive = 0
  OUTPUT inserted.ColumnCode, N''IZKLOPLJEN'', deleted.OutputColumnName, NULL, NULL INTO #Change
  FROM out.ExportColumn AS registryColumn
  WHERE registryColumn.ExportProfileId = @ProfileId AND registryColumn.ColumnCode LIKE N''ATTR[_]%'' AND registryColumn.IsActive = 1
    AND NOT EXISTS (SELECT 1 FROM #Wanted AS wanted WHERE wanted.ColumnCode = registryColumn.ColumnCode);

  /* Samodejni stolpec, katerega ime atributa se je spremenilo, ali ki se je vrnil v nabor. Če bi novo ime
     trčilo z drugim aktivnim stolpcem, ostane staro. */
  UPDATE registryColumn
  SET OutputColumnName = wanted.OutputColumnName, CanonicalFieldCode = wanted.CanonicalFieldCode, IsActive = 1
  OUTPUT inserted.ColumnCode,
         CASE WHEN deleted.IsActive = 0 THEN N''VKLOPLJEN'' ELSE N''PREIMENOVAN'' END,
         deleted.OutputColumnName, inserted.OutputColumnName, NULL INTO #Change
  FROM out.ExportColumn AS registryColumn
  INNER JOIN #Wanted AS wanted ON wanted.ColumnCode = registryColumn.ColumnCode
  WHERE registryColumn.ExportProfileId = @ProfileId
    AND (registryColumn.IsActive = 0 OR registryColumn.OutputColumnName <> wanted.OutputColumnName
         OR registryColumn.CanonicalFieldCode <> wanted.CanonicalFieldCode)
    AND NOT EXISTS (SELECT 1 FROM out.ExportColumn AS other
                    WHERE other.ExportProfileId = @ProfileId AND other.IsActive = 1
                      AND other.ExportColumnId <> registryColumn.ExportColumnId
                      AND (other.OutputColumnName = wanted.OutputColumnName OR other.CanonicalFieldCode = wanted.CanonicalFieldCode));

  /* Nov stolpec: atribut, ki ga noben aktiven stolpec še ne nosi (ne ročni ne samodejni), na konec datoteke. */
  DECLARE @NextSort int = ISNULL((SELECT MAX(SortOrder) FROM out.ExportColumn WHERE ExportProfileId = @ProfileId), 0);
  INSERT out.ExportColumn (ExportProfileId, ColumnCode, OutputColumnName, CanonicalFieldCode, SortOrder, IsRequired, IsActive)
  OUTPUT inserted.ColumnCode, N''DODAN'', NULL, inserted.OutputColumnName, NULL INTO #Change
  SELECT @ProfileId, wanted.ColumnCode, wanted.OutputColumnName, wanted.CanonicalFieldCode,
    @NextSort + ROW_NUMBER() OVER (ORDER BY wanted.SortKey, wanted.OutputColumnName, wanted.Part), 0, 1
  FROM #Wanted AS wanted
  WHERE NOT EXISTS (SELECT 1 FROM out.ExportColumn AS existing
                    WHERE existing.ExportProfileId = @ProfileId
                      AND (existing.ColumnCode = wanted.ColumnCode
                           OR (existing.IsActive = 1 AND (existing.CanonicalFieldCode = wanted.CanonicalFieldCode
                                                          OR existing.OutputColumnName = wanted.OutputColumnName))));

  UPDATE change SET AttributeCode = wanted.AttributeCode
  FROM #Change AS change INNER JOIN #Wanted AS wanted ON wanted.ColumnCode = change.ColumnCode;

  INSERT out.ExportColumnChange (ExportProfileId, ColumnCode, ChangeKind, OldOutputColumnName, NewOutputColumnName, AttributeCode, ChangedBy)
  SELECT @ProfileId, ColumnCode, ChangeKind, OldName, NewName, AttributeCode, @Actor FROM #Change;
  COMMIT;

  SELECT ColumnCode, ChangeKind, OldName AS OldOutputColumnName, NewName AS NewOutputColumnName, AttributeCode
  FROM #Change ORDER BY ChangeKind, NewName, OldName;
END;');

/* --- 3) out.GetExportRows: vrednost brez jezika gre v stolpec SLO ----------------------------- */
DECLARE @Definition nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows'));
IF @Definition NOT LIKE N'%/* 286 */%'
BEGIN
  DECLARE @CaseOld nvarchar(200) = N'CASE LanguageCode WHEN N''sl'' THEN N''SLO'' ELSE N''ANG'' END';
  DECLARE @CaseNew nvarchar(200) = N'CASE WHEN LanguageCode = N''en'' THEN N''ANG'' ELSE N''SLO'' END';
  DECLARE @WhereOld nvarchar(200) = N'WHERE LanguageCode IN (N''sl'', N''en'');';
  DECLARE @WhereNew nvarchar(1000) = N'WHERE LanguageCode IN (N''sl'', N''en'')
       OR (LanguageCode IS NULL AND NOT EXISTS (SELECT 1 FROM #Attribute AS withSl286
             WHERE withSl286.RowKey = #Attribute.RowKey AND withSl286.AttributeCode = #Attribute.AttributeCode
               AND withSl286.LanguageCode = N''sl'')) /* 286 */;';

  IF (LEN(@Definition) - LEN(REPLACE(@Definition, @CaseOld, N''))) / LEN(@CaseOld) <> 1
     OR (LEN(@Definition) - LEN(REPLACE(@Definition, @WhereOld, N''))) / LEN(@WhereOld) <> 1
    THROW 52994, N'286: out.GetExportRows nima pričakovanega izraza za stolpce SLO/ANG (enkrat); nič ni spremenjeno.', 1;

  SET @Definition = REPLACE(REPLACE(@Definition, @CaseOld, @CaseNew), @WhereOld, @WhereNew);
  DECLARE @HeaderEnd int = CHARINDEX(N'PROCEDURE', @Definition);
  SET @Definition = N'ALTER ' + SUBSTRING(@Definition, @HeaderEnd, 2147483647);
  EXEC sys.sp_executesql @Definition;
END;

/* --- dokaz ------------------------------------------------------------------------------- */
IF OBJECT_ID(N'out.SyncAttributeExportColumns', N'P') IS NULL
  THROW 52995, N'286: out.SyncAttributeExportColumns ni nastala.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows')) NOT LIKE N'%/* 286 */%'
  THROW 52996, N'286: out.GetExportRows ne pošilja vrednosti brez jezika v stolpec SLO.', 1;
