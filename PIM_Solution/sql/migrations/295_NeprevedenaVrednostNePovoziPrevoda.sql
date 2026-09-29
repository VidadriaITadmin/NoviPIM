/*
  295 — neprevedena vrednost iz uvoza ne povozi slovenskega prevoda.

  Pri 294 je slovenska vrednost iz uvoza XML, ki je slovar ni prevedel (vrednost »SLO« enaka »ANG«, npr.
  »Nickle«, »Plastic ABS«), povozila obstoječi prevod v PIM (»Nikelj«, »Plastika«): 13 vrstic v canon in
  13 v pim (razvojna baza 2026-09-28). Neprevedena vrednost pride v seznam manjkajočih prevodov
  (map.MissingTranslation, /kakovost/prevodi) — to je mesto, kjer se prevede, ne kartica izdelka.

  Kaj naredi 295:
    1. map.ProcessRawInbox (atributi, 294): vrstica v jeziku sl se ne posodobi, če je nova vrednost enaka
       angleški vrednosti istega atributa v istem zapisu in ima izdelek že drugačno slovensko vrednost.
    2. 26 vrstic, ki jih je 294 tako povozila, dobi nazaj prejšnjo slovensko vrednost (iz dnevnika
       pim.AttributeValueNormalizationLog); sprememba je v dnevniku (»migracija 295«) in za canon še v
       pim.ProductFieldHistory.

  Objekti: sprememba map.ProcessRawInbox; podatki canon/pim.ProductAttribute. Ročni korak: ne.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;

IF UNICODE(N'č') <> 269
  THROW 52950, N'295: datoteka ni prebrana kot UTF-8 (sqlcmd -f 65001 ali Invoke-PendingMigrations.ps1).', 1;

DECLARE @Inbox nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'map.ProcessRawInbox'));
IF @Inbox NOT LIKE N'%/* Jezik294:%'
  THROW 52951, N'295: najprej 294.', 1;

IF @Inbox NOT LIKE N'%/* Prevod295:%'
BEGIN
  DECLARE @SelectText nvarchar(200) = N'SELECT ProductId,AttributeCode,LanguageCode,MAX(Value) Value';
  DECLARE @OnText nvarchar(200) = N'AND ISNULL(target.LanguageCode,N'''')=ISNULL(source.LanguageCode,N'''')';
  DECLARE @UpdateText nvarchar(200) = N'WHEN MATCHED THEN UPDATE SET Value=source.Value';
  DECLARE @OnAt int = CHARINDEX(@OnText, @Inbox);
  DECLARE @UpdateAt int = CHARINDEX(@UpdateText, @Inbox, @OnAt);
  IF (DATALENGTH(@Inbox) - DATALENGTH(REPLACE(@Inbox, @SelectText, N''))) / DATALENGTH(@SelectText) <> 1
     OR (DATALENGTH(@Inbox) - DATALENGTH(REPLACE(@Inbox, @OnText, N''))) / DATALENGTH(@OnText) <> 1
     OR @OnAt = 0 OR @UpdateAt = 0
     OR LTRIM(REPLACE(REPLACE(SUBSTRING(@Inbox, @OnAt + LEN(@OnText), @UpdateAt - @OnAt - LEN(@OnText)), NCHAR(13), N''), NCHAR(10), N'')) <> N''
    THROW 52952, N'295: stavek atributov v map.ProcessRawInbox ni v pričakovani obliki; nič ni spremenjeno.', 1;

  /* Najprej zadnji del (pozicija se ne premakne za prvo zamenjavo, ker je ta pred njim) */
  SET @Inbox = STUFF(@Inbox, @UpdateAt, LEN(@UpdateText),
    N'/* Prevod295: neprevedena sl vrednost (enaka en) ne povozi obstojecega prevoda */
      WHEN MATCHED AND NOT (source.LanguageCode=N''sl'' AND source.Value=source.EnValue
                            AND target.Value IS NOT NULL AND target.Value<>source.Value)
        THEN UPDATE SET Value=source.Value');
  SET @Inbox = REPLACE(@Inbox, @SelectText,
    N'SELECT ProductId,AttributeCode,LanguageCode,MAX(Value) Value,
          MAX(MAX(CASE WHEN LanguageCode=N''en'' THEN Value END)) OVER (PARTITION BY ProductId,AttributeCode) EnValue');

  IF @Inbox NOT LIKE N'%/* Prevod295:%' OR @Inbox NOT LIKE N'%EnValue%'
    THROW 52953, N'295: zamenjave v map.ProcessRawInbox niso uspele; nič ni spremenjeno.', 1;
  SET @Inbox = N'ALTER ' + SUBSTRING(@Inbox, CHARINDEX(N'PROCEDURE', @Inbox), 2147483647);
  EXEC sys.sp_executesql @Inbox;
END;

/* === Popravek podatkov iz 294 ========================================================================= */
CREATE TABLE #Restore
  (TableName nvarchar(60) COLLATE DATABASE_DEFAULT NOT NULL, RowId bigint NOT NULL,
   Wrong nvarchar(max) COLLATE DATABASE_DEFAULT NULL, Previous nvarchar(max) COLLATE DATABASE_DEFAULT NULL);
INSERT #Restore (TableName, RowId, Wrong, Previous)
SELECT changed.TableName, changed.RowId, changed.NewValue, changed.OldValue
FROM pim.AttributeValueNormalizationLog AS changed
WHERE changed.ChangedBy = N'migracija 294' AND changed.LanguageCode = N'sl'
  AND changed.OldValue IS NOT NULL AND changed.NewValue IS NOT NULL
  AND EXISTS (SELECT 1 FROM pim.AttributeValueNormalizationLog AS english
              WHERE english.ChangedBy = N'migracija 294' AND english.TableName = changed.TableName
                AND english.OrganizationId = changed.OrganizationId AND english.ItemID = changed.ItemID
                AND english.AttributeCode = changed.AttributeCode + N' ANG' AND english.NewValue IS NULL
                AND english.OldValue = changed.NewValue)
  AND NOT EXISTS (SELECT 1 FROM pim.AttributeValueNormalizationLog AS done WHERE done.ChangedBy = N'migracija 295'
                    AND done.TableName = changed.TableName AND done.RowId = changed.RowId);

BEGIN TRANSACTION;
  EXEC sys.sp_set_session_context @key = N'ChangeSource', @value = N'POENOTENJE';
  EXEC sys.sp_set_session_context @key = N'ChangedBy', @value = N'migracija 295';
  EXEC sys.sp_set_session_context @key = N'ChangeNote', @value = N'295: vrnjen slovenski prevod, ki ga je 294 povozila z neprevedeno vrednostjo';

  UPDATE target SET Value = vrni.Previous
  FROM canon.ProductAttribute target
  INNER JOIN #Restore vrni ON vrni.TableName = N'canon.ProductAttribute' AND vrni.RowId = target.ProductAttributeId
  WHERE target.Value = vrni.Wrong;
  UPDATE target SET Value = vrni.Previous
  FROM pim.ProductAttribute target
  INNER JOIN #Restore vrni ON vrni.TableName = N'pim.ProductAttribute' AND vrni.RowId = target.PimProductAttributeId
  WHERE target.Value = vrni.Wrong;

  INSERT pim.AttributeValueNormalizationLog (TableName, RowId, OrganizationId, ItemID, AttributeCode, LanguageCode, OldValue, NewValue, ChangedBy)
  SELECT log294.TableName, log294.RowId, log294.OrganizationId, log294.ItemID, log294.AttributeCode, log294.LanguageCode,
         vrni.Wrong, vrni.Previous, N'migracija 295'
  FROM #Restore vrni
  INNER JOIN pim.AttributeValueNormalizationLog log294
    ON log294.ChangedBy = N'migracija 294' AND log294.TableName = vrni.TableName AND log294.RowId = vrni.RowId AND log294.LanguageCode = N'sl';

  EXEC sys.sp_set_session_context @key = N'ChangeSource', @value = NULL;
  EXEC sys.sp_set_session_context @key = N'ChangedBy', @value = NULL;
  EXEC sys.sp_set_session_context @key = N'ChangeNote', @value = NULL;
COMMIT TRANSACTION;

IF OBJECT_DEFINITION(OBJECT_ID(N'map.ProcessRawInbox')) NOT LIKE N'%/* Prevod295:%'
  THROW 52954, N'295: map.ProcessRawInbox ni posodobljena.', 1;
