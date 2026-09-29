/*
  293 — popravek 292: sestavljanje vrstic katalog.csv po številkah stolpcev brez slabega načrta.

  292 je v dinamičnem SELECT (razdelek D) stik #Value × #FieldNo291 postavil v izpeljano tabelo pod
  LEFT JOIN iz #Page. Na razvojni bazi (2026-09-28) je SQL Server tak stik ponavljal za vsako vrstico
  #Page: izvoz podjetja 2 je po 10 min (609 s CPU) še tekel in je bil ustavljen. Nočni izvoz ni bil
  prizadet (zadnji je tekel pred 292).

  293: vrednosti s številko stolpca se enkrat prepišejo v #ValueNo293 (gručni indeks po RowKey),
  sestavljanje pa ima isto obliko kot pred 292 (#Page LEFT JOIN vrednosti po RowKey), le da stolpci
  primerjajo celo število namesto niza v Slovenian_CI_AS.

  Objekti: sprememba out.GetExportRows (razdelek D). Ročni korak: ne. Migrator ne pozna GO.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;

IF UNICODE(N'č') <> 269
  THROW 52930, N'293: datoteka ni prebrana kot UTF-8 (sqlcmd -f 65001 ali Invoke-PendingMigrations.ps1).', 1;

DECLARE @Export nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows'));
IF @Export NOT LIKE N'%/* Stolpci293:%'
BEGIN
  DECLARE @StartText nvarchar(100) = N'/* Stolpci292:';
  DECLARE @EndText nvarchar(100) = N'EXEC sys.sp_executesql @Sql;';
  DECLARE @Start int = CHARINDEX(@StartText, @Export);
  DECLARE @End int = CHARINDEX(@EndText, @Export) + LEN(@EndText);
  DECLARE @Old nvarchar(max) = CASE WHEN @Start > 0 AND @End > @Start THEN SUBSTRING(@Export, @Start, @End - @Start) END;
  IF @Old IS NULL
     OR CHARINDEX(@EndText, @Export, @End) > 0
     OR @Old NOT LIKE N'%FROM #Value AS value INNER JOIN #FieldNo291 AS fieldNo%'
     OR LEN(@Old) > 2500
    THROW 52931, N'293: razdelek D iz 292 v out.GetExportRows ni v pričakovani obliki; nič ni spremenjeno.', 1;

  DECLARE @NewD nvarchar(max) = N'/* Stolpci293: stolpec se izbere po stevilki kanonicne kode (292), vrednosti s stevilko so v
     #ValueNo293 z grucnim indeksom po RowKey — sestavljanje ima isto obliko kot pred 292. */
  CREATE TABLE #FieldNo291
    (FieldCode nvarchar(450) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY, ColumnNo int NOT NULL);
  INSERT #FieldNo291 (FieldCode, ColumnNo)
  SELECT code.CanonicalFieldCode, ROW_NUMBER() OVER (ORDER BY code.CanonicalFieldCode)
  FROM (SELECT DISTINCT registryColumn.CanonicalFieldCode FROM out.ExportColumn AS registryColumn
        WHERE registryColumn.ExportProfileId = @ExportProfileId AND registryColumn.IsActive = 1
          AND NULLIF(registryColumn.CanonicalFieldCode, N'''') IS NOT NULL) AS code;

  CREATE TABLE #ValueNo293
    (RowKey nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL, ColumnNo int NOT NULL, Value nvarchar(max) COLLATE DATABASE_DEFAULT NULL);
  INSERT #ValueNo293 (RowKey, ColumnNo, Value)
  SELECT value.RowKey, fieldNo.ColumnNo, value.Value
  FROM #Value AS value INNER JOIN #FieldNo291 AS fieldNo ON fieldNo.FieldCode = value.FieldCode;
  CREATE CLUSTERED INDEX IX_ValueNo293 ON #ValueNo293 (RowKey);

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
    LEFT JOIN #ValueNo293 AS fieldValue ON fieldValue.RowKey = page.RowKey
    GROUP BY page.RowKey
    ORDER BY page.RowKey;'';

  EXEC sys.sp_executesql @Sql;';
  SET @Export = STUFF(@Export, @Start, @End - @Start, @NewD);
  IF @Export NOT LIKE N'%/* Stolpci293:%' OR @Export LIKE N'%/* Stolpci292:%' OR @Export NOT LIKE N'%/* VsiAtributi291 */%'
     OR @Export NOT LIKE N'%#UnitValue292 unitValue%'
    THROW 52932, N'293: zamenjava v out.GetExportRows ni uspela; nič ni spremenjeno.', 1;
  SET @Export = N'ALTER ' + SUBSTRING(@Export, CHARINDEX(N'PROCEDURE', @Export), 2147483647);
  EXEC sys.sp_executesql @Export;
END;

IF OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows')) NOT LIKE N'%/* Stolpci293:%'
  THROW 52933, N'293: out.GetExportRows ni posodobljena.', 1;
