/*
  287 — out.GetExportRows: pravilo 286 (vrednost atributa brez jezika gre v stolpec »… SLO«) v enem prehodu.

  Meritev 2026-09-28 na razvojni bazi (DAVID\MSSQL19, mirna, cel katalog, @Take = 0): izvoz podjetja 2 je
  trajal 325–341 s, podjetja 3 460 s; od tega ~310 s en sam stavek — 286 je v vstavljanje stolpcev SLO/ANG
  dodal NOT EXISTS nad istim #Attribute (kopica brez indeksa, pogoj v OR), kar SQL izvede kot iskanje po vseh
  vrednostih za vsako vrednost. Isto pravilo z okensko funkcijo (MAX … OVER PARTITION BY RowKey, AttributeCode):
  podjetje 2 37 s. Pred 286 je izvoz trajal 20–65 s.

  Uporabnik 2026-09-28 je vprašal, ali je počasno preverjanje nabora atributov po artiklu (#AttributeFilter, 147):
  ni — 0,5–0,8 s; ostane.

  Pomen je nespremenjen: vrednost z jezikom sl/en gre v SLO/ANG; vrednost brez jezika gre v SLO, če artikel za
  isti atribut nima vrednosti v sl. Oznaka /* 286 */ ostane v proceduri (286 po njej prepozna, da je že uveljavljena).

  Objekti: sprememba out.GetExportRows (en stavek). Ročni korak: ne. Migrator ne pozna GO.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

IF UNICODE(N'č') <> 269
  THROW 52980, N'287: datoteka ni prebrana kot UTF-8 (sqlcmd -f 65001 ali Invoke-PendingMigrations.ps1).', 1;
IF OBJECT_ID(N'out.GetExportRows', N'P') IS NULL
  THROW 52981, N'287 potrebuje out.GetExportRows.', 1;

DECLARE @Definition nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows'));
IF @Definition NOT LIKE N'%/* 287 */%'
BEGIN
  IF @Definition NOT LIKE N'%withSl286%/* 286 */;%'
    THROW 52982, N'287: out.GetExportRows nima izraza iz 286 (withSl286); najprej 286.', 1;

  /* Stavek od »FROM #Attribute« pred »WHERE LanguageCode IN (N'sl', N'en')« (zadnji pred oznako 286; v podpoizvedbi
     286 je še en »FROM #Attribute«, zato sidro na WHERE) do oznake »/* 286 */;« zamenjamo v celoti.
     DATALENGTH, ne LEN: LEN ne šteje presledkov na koncu, REVERSE pa jih. */
  DECLARE @Marker nvarchar(20) = N'/* 286 */;';
  DECLARE @MarkerAt int = CHARINDEX(@Marker, @Definition);
  DECLARE @End int = @MarkerAt + LEN(@Marker);
  DECLARE @WhereText nvarchar(80) = N'WHERE LanguageCode IN (N''sl'', N''en'')';
  DECLARE @FromText nvarchar(40) = N'FROM #Attribute';
  DECLARE @Head nvarchar(max) = LEFT(@Definition, @MarkerAt - 1);
  DECLARE @WhereAt int = DATALENGTH(@Head) / 2 - CHARINDEX(REVERSE(@WhereText), REVERSE(@Head)) - LEN(@WhereText) + 2;
  SET @Head = LEFT(@Definition, @WhereAt - 1);
  DECLARE @Start int = DATALENGTH(@Head) / 2 - CHARINDEX(REVERSE(@FromText), REVERSE(@Head)) - LEN(@FromText) + 2;
  DECLARE @Old nvarchar(max) = SUBSTRING(@Definition, @Start, @End - @Start);

  IF CHARINDEX(@Marker, @Definition, @End) > 0
     OR LEFT(@Old, LEN(@FromText)) <> @FromText
     OR LTRIM(REPLACE(REPLACE(SUBSTRING(@Old, LEN(@FromText) + 1, @WhereAt - @Start - LEN(@FromText)), NCHAR(13), N''), NCHAR(10), N'')) <> N''
     OR @Old NOT LIKE N'%withSl286%'
     OR LEN(@Old) > 600
     OR @Old LIKE N'%INSERT%'
    THROW 52983, N'287: izraz 286 v out.GetExportRows ni v pričakovani obliki; nič ni spremenjeno.', 1;

  DECLARE @New nvarchar(max) = N'FROM (SELECT RowKey, AttributeCode, LanguageCode, Value,
                 MAX(CASE WHEN LanguageCode = N''sl'' THEN 1 ELSE 0 END)
                   OVER (PARTITION BY RowKey, AttributeCode) AS HasSl287
          FROM #Attribute) AS attribute287
    WHERE LanguageCode IN (N''sl'', N''en'')
       OR (LanguageCode IS NULL AND attribute287.HasSl287 = 0) /* 286 */ /* 287 */;';

  SET @Definition = STUFF(@Definition, @Start, @End - @Start, @New);
  DECLARE @HeaderEnd int = CHARINDEX(N'PROCEDURE', @Definition);
  SET @Definition = N'ALTER ' + SUBSTRING(@Definition, @HeaderEnd, 2147483647);
  EXEC sys.sp_executesql @Definition;
END;

/* --- dokaz ------------------------------------------------------------------------------- */
IF OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows')) NOT LIKE N'%/* 287 */%'
   OR OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows')) LIKE N'%withSl286%'
  THROW 52984, N'287: out.GetExportRows ni posodobljena.', 1;
