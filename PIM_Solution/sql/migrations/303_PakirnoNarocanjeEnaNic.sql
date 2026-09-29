/*
  303 — »Pakirno naročanje« v katalog.csv kot 1/0 namesto DA/NE.

  Odločitev lastnika 2026-09-29 16:59 (naloga #13, vključena v #5): stolpec »Pakirno naročanje« v
  katalog.csv ima vrednost 1 (artikel se na spletu naroča samo po celih paketih) ali 0 (ne). Na kartici
  izdelka in v delovnem listu Excel ostane za uporabnika Da/Ne oziroma D/N.

  Kaj naredi:
    1. out.GetExportRows: v bloku, ki ga je dodala 302 (/* PakirnoNarocanje302 */), vrednost
       CASE ... N'DA' ELSE N'NE' zamenja s CASE ... N'1' ELSE N'0'. Artikel brez oznake = 0.
       Popravi se živa definicija (REPLACE na natanko enem mestu), ostala procedura ostane nespremenjena.

  Ne spreminja: »Razstavni eksponat« in »Odprodaja« ostaneta DA/NE (o njiju ni odločitve).
  SAOP: nič. Ročni korak: ne. Ponovljivo: da (marker /* PakirnoNarocanje303 */).
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;

IF UNICODE(N'č') <> 269
  THROW 53030, N'303: datoteka ni prebrana kot UTF-8 (sqlcmd -f 65001 ali Invoke-PendingMigrations.ps1).', 1;

DECLARE @definition nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows'));
IF @definition IS NULL THROW 53031, N'303: out.GetExportRows manjka.', 1;
IF @definition NOT LIKE N'%/* PakirnoNarocanje302 */%'
  THROW 53032, N'303: najprej mora biti uveljavljena 302 (Pakirno naročanje).', 1;

IF @definition NOT LIKE N'%/* PakirnoNarocanje303 */%'
BEGIN
  DECLARE @old nvarchar(400) = N'N''ProductFlag.PakirnoNarocanje'',CASE WHEN flag.IsSet=1 THEN N''DA'' ELSE N''NE'' END';
  DECLARE @new nvarchar(400) = N'N''ProductFlag.PakirnoNarocanje''/* PakirnoNarocanje303 */,CASE WHEN flag.IsSet=1 THEN N''1'' ELSE N''0'' END';
  DECLARE @first int = CHARINDEX(@old, @definition);
  IF @first = 0 OR CHARINDEX(@old, @definition, @first + 1) > 0
    THROW 53033, N'303: v out.GetExportRows ni natanko enega izraza DA/NE za Pakirno naročanje; nič ni spremenjeno.', 1;

  SET @definition = REPLACE(@definition, @old, @new);
  SET @definition = N'ALTER ' + SUBSTRING(@definition, CHARINDEX(N'PROCEDURE', @definition), 2147483647);
  EXEC sys.sp_executesql @definition;
END;

/* Preverba */
SET @definition = OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows'));
IF @definition NOT LIKE N'%/* PakirnoNarocanje303 */,CASE WHEN flag.IsSet=1 THEN N''1'' ELSE N''0'' END%'
  THROW 53034, N'303: Pakirno naročanje v out.GetExportRows ni 1/0.', 1;
IF @definition LIKE N'%ProductFlag.PakirnoNarocanje'',CASE WHEN flag.IsSet=1 THEN N''DA''%'
  THROW 53035, N'303: v out.GetExportRows je še DA/NE za Pakirno naročanje.', 1;
