/*
  316 — Lep zapis vrednosti ne velja za spremljevalne atribute enot (»Enota …«) — naloga #49.

  Preverba po 314 na razvojni bazi PIM (DESKTOP-TONVQHJ\MSSQLSERVER3), 2026-09-30: korak 4 (velika začetnica)
  je enoto »kgs« v atributih »Enota bruto teže (2)« in »Enota neto teže (2)« zapisal kot »Kgs« (2 x 1.365 vrstic
  v canon.ProductAttribute). Enota ni besedilo: »kg«, »mm«, »kgs« ostanejo, kot so. Spremljevalni atributi »Enota …«
  po zasnovi nosijo samo enote (glej /nastavitve/atributi/ciscenje), zato jih lep zapis v celoti preskoči
  (ostane pravilo 291: presledki).

  Kaj naredi 316 (ena transakcija):
    1. pim.PolishAttributeValue: atribut z imenom »Enota …« vrne vrednost, kot jo vrne pim.NormalizeAttributeValue.
       (REPLACE na živi definiciji iz 314; sidro mora biti natanko enkrat.)
    2. Ponovni izračun sprememb 314: vrstica, ki jo je spremenila 314 in je od takrat nihče ni spremenil
       (vrednost = NewValue), dobi vrednost, ki jo da popravljeno pravilo iz prvotne vrednosti (OldValue).
       Vsaka sprememba gre v dnevnik pim.AttributeValueNormalizationLog z ChangedBy = »migracija 316«
       (canon še v pim.ProductFieldHistory prek sprožilca, vir POENOTENJE).
  Nič ne gre v SAOP. Objekti: pim.PolishAttributeValue (ALTER); podatki canon/pim.ProductAttribute (+ dnevnik).
  Ročni korak: ne. Migrator ne pozna GO.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;

IF UNICODE(N'č') <> 269
  THROW 53160, N'316: datoteka ni prebrana kot UTF-8 (sqlcmd -f 65001 ali Invoke-PendingMigrations.ps1).', 1;
IF OBJECT_ID(N'pim.RevertAttributeValueNormalization', N'P') IS NULL
  THROW 53161, N'316 potrebuje 314 (vklop lepega zapisa).', 1;

BEGIN TRAN;

/* === 1. Pravilo: brez atributov »Enota …« ============================================================== */
DECLARE @Polish nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'pim.PolishAttributeValue'));
IF @Polish NOT LIKE N'%/* Enote316 */%'
BEGIN
  DECLARE @Anchor nvarchar(200) = N'IF EXISTS (SELECT 1 FROM out.SaopXmlField AS saop';
  IF (DATALENGTH(@Polish) - DATALENGTH(REPLACE(@Polish, @Anchor, N''))) / DATALENGTH(@Anchor) <> 1
    THROW 53162, N'316: pim.PolishAttributeValue ni v obliki iz 314; nič ni spremenjeno.', 1;
  SET @Polish = REPLACE(@Polish, @Anchor,
    N'/* Enote316 */ /* spremljevalni atributi enot (»Enota bruto teže (2)«: kgs) niso besedilo */
  IF @AttributeCode LIKE N''Enota%'' RETURN @v;
  ' + @Anchor);
  SET @Polish = N'ALTER ' + SUBSTRING(@Polish, CHARINDEX(N'FUNCTION', @Polish), 2147483647);
  EXEC sys.sp_executesql @Polish;
END;

DECLARE @Check TABLE (AttributeCode nvarchar(400), Input nvarchar(400), Expected nvarchar(400));
INSERT @Check VALUES
  (N'Enota bruto teže (2)', N'kgs', N'kgs'),
  (N'Enota neto teže (2)', N' kgs ', N'kgs'),
  (N'Enota', N'mm', N'mm'),
  (N'Barva', N'bela', N'Bela'),
  (N'Max moč sijalke', N'10W', N'10 W'),
  (N'Baterija', N'Li-Ion,Battery 18650 3.7V,6600mAh', N'Li-Ion, Battery 18650 3.7 V, 6600 mAh');
DECLARE @FailedMessage nvarchar(2000) =
  (SELECT TOP (1) N'316: »' + c.Input + N'« (' + c.AttributeCode + N') da »' + ISNULL(r.Value, N'NULL') + N'«, pričakovano »' + c.Expected + N'«.'
   FROM @Check c CROSS APPLY (SELECT Value = pim.PolishAttributeValue(c.AttributeCode, c.Input)) r
   WHERE r.Value IS NULL OR r.Value COLLATE Latin1_General_BIN2 <> c.Expected COLLATE Latin1_General_BIN2);
IF @FailedMessage IS NOT NULL
  THROW 53163, @FailedMessage, 1;

/* === 2. Ponovni izračun sprememb 314 ==================================================================== */
CREATE TABLE #Redo
  (TableName nvarchar(60) COLLATE DATABASE_DEFAULT NOT NULL, RowId bigint NOT NULL,
   AttributeCode nvarchar(400) COLLATE DATABASE_DEFAULT NOT NULL,
   OldValue nvarchar(max) NULL, Was314 nvarchar(max) NULL, Target nvarchar(max) NULL, PRIMARY KEY (TableName, RowId));
INSERT #Redo (TableName, RowId, AttributeCode, OldValue, Was314)
SELECT TableName, RowId, AttributeCode, OldValue, NewValue
FROM (SELECT TableName, RowId, AttributeCode, OldValue, NewValue,
             ROW_NUMBER() OVER (PARTITION BY TableName, RowId ORDER BY AttributeValueNormalizationLogId DESC) AS RowNo
      FROM pim.AttributeValueNormalizationLog WHERE ChangedBy = N'migracija 314') AS logged
WHERE logged.RowNo = 1;

/* Pravilo po različnih parih (atribut, prvotna vrednost), ne po vrstici. */
CREATE TABLE #Target
  (AttributeCode nvarchar(400) COLLATE DATABASE_DEFAULT NOT NULL, OldValue nvarchar(max) COLLATE Latin1_General_BIN2 NOT NULL,
   Target nvarchar(max) NULL);
INSERT #Target (AttributeCode, OldValue, Target)
SELECT pair.AttributeCode, pair.OldValue, pim.PolishAttributeValue(pair.AttributeCode, pair.OldValue)
FROM (SELECT DISTINCT AttributeCode, OldValue COLLATE Latin1_General_BIN2 AS OldValue FROM #Redo WHERE OldValue IS NOT NULL) AS pair;
UPDATE redo SET Target = target.Target
FROM #Redo redo
INNER JOIN #Target target ON target.AttributeCode = redo.AttributeCode AND target.OldValue = redo.OldValue COLLATE Latin1_General_BIN2;
DELETE FROM #Redo WHERE Target IS NULL OR Target COLLATE Latin1_General_BIN2 = Was314 COLLATE Latin1_General_BIN2;

EXEC sys.sp_set_session_context @key = N'ChangeSource', @value = N'POENOTENJE';
EXEC sys.sp_set_session_context @key = N'ChangedBy', @value = N'migracija 316';
EXEC sys.sp_set_session_context @key = N'ChangeNote', @value = N'316: enote v atributih »Enota …« ostanejo, kot so (popravek 314)';

DECLARE @CanonChanged TABLE (RowId bigint PRIMARY KEY, OldValue nvarchar(max), NewValue nvarchar(max));
UPDATE attribute SET Value = redo.Target
OUTPUT inserted.ProductAttributeId, deleted.Value, inserted.Value INTO @CanonChanged
FROM canon.ProductAttribute AS attribute
INNER JOIN #Redo AS redo ON redo.TableName = N'canon.ProductAttribute' AND redo.RowId = attribute.ProductAttributeId
WHERE attribute.Value COLLATE Latin1_General_BIN2 = redo.Was314 COLLATE Latin1_General_BIN2;

INSERT pim.AttributeValueNormalizationLog (TableName, RowId, OrganizationId, ItemID, AttributeCode, LanguageCode, OldValue, NewValue, ChangedBy)
SELECT N'canon.ProductAttribute', changed.RowId, product.OrganizationId, product.ItemID, attribute.AttributeCode,
       attribute.LanguageCode, changed.OldValue, changed.NewValue, N'migracija 316'
FROM @CanonChanged changed
INNER JOIN canon.ProductAttribute attribute ON attribute.ProductAttributeId = changed.RowId
INNER JOIN canon.Product product ON product.ProductId = attribute.ProductId;

DECLARE @PimChanged TABLE (RowId bigint PRIMARY KEY, OldValue nvarchar(max), NewValue nvarchar(max));
UPDATE attribute SET Value = redo.Target
OUTPUT inserted.PimProductAttributeId, deleted.Value, inserted.Value INTO @PimChanged
FROM pim.ProductAttribute AS attribute
INNER JOIN #Redo AS redo ON redo.TableName = N'pim.ProductAttribute' AND redo.RowId = attribute.PimProductAttributeId
WHERE attribute.Value COLLATE Latin1_General_BIN2 = redo.Was314 COLLATE Latin1_General_BIN2;

INSERT pim.AttributeValueNormalizationLog (TableName, RowId, OrganizationId, ItemID, AttributeCode, LanguageCode, OldValue, NewValue, ChangedBy)
SELECT N'pim.ProductAttribute', changed.RowId, product.OrganizationId, product.ItemID, attribute.AttributeCode,
       attribute.LanguageCode, changed.OldValue, changed.NewValue, N'migracija 316'
FROM @PimChanged changed
INNER JOIN pim.ProductAttribute attribute ON attribute.PimProductAttributeId = changed.RowId
INNER JOIN pim.Product product ON product.PimProductId = attribute.PimProductId;

EXEC sys.sp_set_session_context @key = N'ChangeSource', @value = NULL;
EXEC sys.sp_set_session_context @key = N'ChangedBy', @value = NULL;
EXEC sys.sp_set_session_context @key = N'ChangeNote', @value = NULL;

/* Po popravku ni več vrednosti, ki bi jo pravilo zapisalo drugače. */
IF EXISTS (SELECT 1 FROM (SELECT DISTINCT AttributeCode, Value COLLATE Latin1_General_BIN2 AS Value
                          FROM canon.ProductAttribute WHERE AttributeCode LIKE N'Enota%' AND Value IS NOT NULL
                          UNION SELECT DISTINCT AttributeCode, Value COLLATE Latin1_General_BIN2
                          FROM pim.ProductAttribute WHERE AttributeCode LIKE N'Enota%' AND Value IS NOT NULL) AS unitValue
           WHERE pim.PolishAttributeValue(unitValue.AttributeCode, unitValue.Value) COLLATE Latin1_General_BIN2 <> unitValue.Value)
  THROW 53164, N'316: atributi »Enota …« po popravku niso stabilni; nič ni spremenjeno.', 1;

COMMIT;
