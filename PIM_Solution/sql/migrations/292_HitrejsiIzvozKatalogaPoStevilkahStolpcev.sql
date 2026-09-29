/*
  292 — out.GetExportRows: hitrejše sestavljanje katalog.csv (po 291 je vrednosti več).

  Meritev 2026-09-28 na razvojni bazi (DAVID\MSSQL19), podjetje 2, cel katalog (@Take = 0), po 291:
  80 s (pred 291 36 s). 291 v izvoz vrne ~80.000 vrednosti atributov, ki jih je nabor po kategoriji prej
  izpuščal, zato so trije stavki, ki gredo čez vse vrednosti, zrasli:
    - sestavljanje vrstic (D, dinamični SELECT): 220 stolpcev × vse vrednosti, vsak stolpec s primerjavo
      niza FieldCode v Slovenian_CI_AS — 30 s CPU;
    - pretvorba enot v glavo (216d): enota vrstice se je iskala med vsemi vrednostmi artikla — 13 s;
    - velika začetnica v stolpcih SLO/ANG (216c): prepis vseh 160.000 vrednosti, tudi že pravilnih — 4 s,
      in SUBSTRING(…, 2, 4000) je daljše besedilo odrezal pri 4001 znakih.

  Kaj naredi 292 (pomen ostane enak):
    - D: vsaka kanonična koda dobi številko (#FieldNo291); vrednost dobi številko enkrat (stik), stolpci pa
      primerjajo celo število namesto niza;
    - 216d: enote vrstic se najprej izločijo v #UnitValue292 (le polja z enoto) in se iščejo tam;
    - 216c: prepiše se samo vrednost, ki se začne z malo črko; STUFF namesto SUBSTRING(…, 4000) — nič se ne odreže.

  Objekti: sprememba out.GetExportRows. Ročni korak: ne. Migrator ne pozna GO.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;

IF UNICODE(N'č') <> 269
  THROW 52922, N'292: datoteka ni prebrana kot UTF-8 (sqlcmd -f 65001 ali Invoke-PendingMigrations.ps1).', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows')) NOT LIKE N'%/* VsiAtributi291 */%'
  THROW 52923, N'292: najprej 291.', 1;

DECLARE @Export nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows'));
IF @Export NOT LIKE N'%/* Stolpci292:%'
BEGIN
  /* --- D: od »DECLARE @Quote« do »EXEC sys.sp_executesql @Sql;« se zamenja v celoti ------------------- */
  DECLARE @StartText nvarchar(100) = N'DECLARE @Quote nchar(1) = NCHAR(39);';
  DECLARE @EndText nvarchar(100) = N'EXEC sys.sp_executesql @Sql;';
  DECLARE @Start int = CHARINDEX(@StartText, @Export);
  DECLARE @End int = CHARINDEX(@EndText, @Export) + LEN(@EndText);
  DECLARE @Old nvarchar(max) = CASE WHEN @Start > 0 AND @End > @Start THEN SUBSTRING(@Export, @Start, @End - @Start) END;
  IF @Old IS NULL
     OR CHARINDEX(@StartText, @Export, @Start + 1) > 0 OR CHARINDEX(@EndText, @Export, @End) > 0
     OR @Old NOT LIKE N'%MAX(CASE WHEN fieldValue.FieldCode = N%' OR @Old NOT LIKE N'%LEFT JOIN #Value AS fieldValue ON fieldValue.RowKey = page.RowKey%'
     OR LEN(@Old) > 1500
    THROW 52924, N'292: razdelek D v out.GetExportRows ni v pričakovani obliki; nič ni spremenjeno.', 1;

  DECLARE @NewD nvarchar(max) = N'/* Stolpci292: stolpec se izbere po stevilki kanonicne kode, ne s primerjavo niza za vsako vrednost. */
  CREATE TABLE #FieldNo291
    (FieldCode nvarchar(450) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY, ColumnNo int NOT NULL);
  INSERT #FieldNo291 (FieldCode, ColumnNo)
  SELECT code.CanonicalFieldCode, ROW_NUMBER() OVER (ORDER BY code.CanonicalFieldCode)
  FROM (SELECT DISTINCT registryColumn.CanonicalFieldCode FROM out.ExportColumn AS registryColumn
        WHERE registryColumn.ExportProfileId = @ExportProfileId AND registryColumn.IsActive = 1
          AND NULLIF(registryColumn.CanonicalFieldCode, N'''') IS NOT NULL) AS code;

  DECLARE @SelectList nvarchar(max);
  SELECT @SelectList = STRING_AGG(CONVERT(nvarchar(max),
    CASE WHEN fieldNo.ColumnNo IS NULL
      THEN N''CAST(NULL AS nvarchar(max)) AS '' + QUOTENAME(registryColumn.OutputColumnName)
      ELSE N''MAX(CASE WHEN fieldValue.ColumnNo = '' + CONVERT(nvarchar(10), fieldNo.ColumnNo)
           + N'' THEN fieldValue.Value END) AS '' + QUOTENAME(registryColumn.OutputColumnName)
    END), N'','') WITHIN GROUP (ORDER BY registryColumn.SortOrder)
  FROM out.ExportColumn AS registryColumn
  LEFT JOIN #FieldNo291 AS fieldNo ON fieldNo.FieldCode = registryColumn.CanonicalFieldCode
  WHERE registryColumn.ExportProfileId = @ExportProfileId AND registryColumn.IsActive = 1;

  DECLARE @Sql nvarchar(max) = N''
    SELECT '' + @SelectList + N''
    FROM #Page AS page
    LEFT JOIN (SELECT value.RowKey, value.Value, fieldNo.ColumnNo
               FROM #Value AS value INNER JOIN #FieldNo291 AS fieldNo ON fieldNo.FieldCode = value.FieldCode) AS fieldValue
      ON fieldValue.RowKey = page.RowKey
    GROUP BY page.RowKey
    ORDER BY page.RowKey;'';

  EXEC sys.sp_executesql @Sql;';
  SET @Export = STUFF(@Export, @Start, @End - @Start, @NewD);

  /* --- 216d: enote vrstic vnaprej, iskanje samo med njimi ------------------------------------------ */
  DECLARE @Anchors TABLE (Anchor nvarchar(400), Replacement nvarchar(max));
  INSERT @Anchors VALUES
  (N'UPDATE value SET Value=converted.Value',
   N'SELECT unitValue.RowKey, unitValue.FieldCode, unitValue.Value
    INTO #UnitValue292
    FROM #Value AS unitValue
    WHERE unitValue.FieldCode IN (SELECT UnitFieldCode FROM out.CatalogUnitRule WHERE IsActive = 1 AND UnitFieldCode IS NOT NULL)
      AND NULLIF(unitValue.Value, N'''') IS NOT NULL;
    CREATE CLUSTERED INDEX IX_UnitValue292 ON #UnitValue292 (RowKey);
    UPDATE value SET Value=converted.Value'),
  (N'OUTER APPLY(SELECT TOP(1) unitValue.Value AS Unit FROM #Value unitValue',
   N'OUTER APPLY(SELECT TOP(1) unitValue.Value AS Unit FROM #UnitValue292 unitValue'),
  /* --- 216c: le vrednosti z malo začetnico, brez rezanja pri 4000 znakih ---------------------------- */
  (N'UPDATE #Value SET Value=UPPER(LEFT(Value,1))+SUBSTRING(Value,2,4000)',
   N'UPDATE #Value SET Value=STUFF(Value,1,1,UPPER(LEFT(Value,1)))'),
  (N'WHERE (FieldCode LIKE N''Attr.% SLO'' OR FieldCode LIKE N''Attr.% ANG'') AND NULLIF(Value,N'''') IS NOT NULL;',
   N'WHERE (FieldCode LIKE N''Attr.% SLO'' OR FieldCode LIKE N''Attr.% ANG'') AND NULLIF(Value,N'''') IS NOT NULL
      AND LEFT(Value,1) COLLATE Latin1_General_BIN2 <> UPPER(LEFT(Value,1)) COLLATE Latin1_General_BIN2 /* 292 */;');

  DECLARE @MissingAnchor nvarchar(400) = (SELECT TOP (1) Anchor FROM @Anchors
    WHERE (DATALENGTH(@Export) - DATALENGTH(REPLACE(@Export, Anchor, N''))) / DATALENGTH(Anchor) <> 1);
  IF @MissingAnchor IS NOT NULL
  BEGIN
    DECLARE @AnchorMessage nvarchar(600) = CONCAT(N'292: out.GetExportRows nima natanko enega sidra »', @MissingAnchor, N'«; nič ni spremenjeno.');
    THROW 52925, @AnchorMessage, 1;
  END;

  DECLARE @Anchor nvarchar(400), @Replacement nvarchar(max);
  DECLARE anchors CURSOR LOCAL FAST_FORWARD FOR SELECT Anchor, Replacement FROM @Anchors;
  OPEN anchors;
  FETCH NEXT FROM anchors INTO @Anchor, @Replacement;
  WHILE @@FETCH_STATUS = 0
  BEGIN
    SET @Export = REPLACE(@Export, @Anchor, @Replacement);
    FETCH NEXT FROM anchors INTO @Anchor, @Replacement;
  END;
  CLOSE anchors; DEALLOCATE anchors;

  IF @Export NOT LIKE N'%/* Stolpci292:%' OR @Export NOT LIKE N'%#UnitValue292 unitValue%' OR @Export NOT LIKE N'%/* 292 */;%'
     OR @Export NOT LIKE N'%/* VsiAtributi291 */%' OR @Export NOT LIKE N'%/* 287 */%' OR @Export NOT LIKE N'%/* 288 */%'
    THROW 52926, N'292: zamenjave v out.GetExportRows niso vse uspele; nič ni spremenjeno.', 1;
  SET @Export = N'ALTER ' + SUBSTRING(@Export, CHARINDEX(N'PROCEDURE', @Export), 2147483647);
  EXEC sys.sp_executesql @Export;
END;

/* --- dokaz ------------------------------------------------------------------------------------------ */
IF OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows')) NOT LIKE N'%/* Stolpci292:%'
   OR OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows')) LIKE N'%MAX(CASE WHEN fieldValue.FieldCode = N%'
  THROW 52927, N'292: out.GetExportRows ni posodobljena.', 1;
