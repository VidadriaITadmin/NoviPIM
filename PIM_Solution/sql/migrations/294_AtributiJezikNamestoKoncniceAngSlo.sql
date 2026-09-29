/*
  294 — atributi »… ANG« / »… SLO« niso atributi PIM: jezik gre v stolpec, ime ostane eno.

  Uporabnik 2026-09-28: »Prevladujoča barva ANG« in »Prevladujoča barva SLO« ne smeta biti atributa v PIM,
  ampak samo stolpca v katalog.csv (tam rabimo osnovo in prevod in je tako poimenovano).

  Stanje pred 294 (razvojna baza, 2026-09-28):
    - 124 (27. 8.) je končnico SLO/ANG enkrat prenesla v LanguageCode, zajem pa ni bil prilagojen:
      map.FieldMapping ima še 160 ciljev »ProductAttribute.<ime> ANG/SLO« (NW_XML, BT_XML), map.ProcessRawInbox
      pa ime zapiše, kot je. Vsak uvoz XML je zato pisal stara imena (canon: ~66.000 vrstic, 17 lastnosti),
      pravilne vrstice z jezikom pa so ostale pri stanju 27. 8. — razen ~34 ročnih popravkov v intranetu
      (21.–22. 9., npr. »Metal« -> »Aluminium«), ki so bili samo v pravilnih vrsticah.
    - Izvoz je stolpec »Prevladujoča barva ANG« polnil iz obeh (stara vrstica brez jezika in vrstica en) —
      katera obvelja, je bilo naključje.

  Kaj naredi 294:
    1. map.ProcessRawInbox: cilj »ProductAttribute.<ime> SLO/ANG«, pri katerem je <ime> atribut v registru
       (canon.AttributeTranslation, sl), se zapiše kot <ime> z LanguageCode sl/en; MERGE primerja tudi jezik.
       Preslikave (map.FieldMapping) ostanejo, kot so — končnica v cilju pomeni jezik.
    2. canon in pim: iz vsake stare vrstice se vrednost prenese v vrstico <ime> + jezik:
         - pravilne vrstice ni -> nastane;
         - pravilna je drugačna -> dobi vrednost stare (sveži uvoz), RAZEN če je bila pravilna ročno
           popravljena v intranetu (pim.ProductFieldHistory, vir INTRANET) — ročna vrednost ostane;
       nato se stara vrstica odstrani. Vse spremembe in odstranitve so v pim.AttributeValueNormalizationLog
       (ChangedBy »migracija 294«; odstranjena vrstica ima NewValue NULL), canon še v pim.ProductFieldHistory.
       Imena brez atributa v registru (npr. testni »F5 … SLO«) ostanejo nedotaknjena.

  Stolpci katalog.csv »… ANG« / »… SLO« ostanejo in se polnijo iz vrstic z jezikom (216/286/287).

  Objekti: sprememba map.ProcessRawInbox; podatki canon.ProductAttribute, pim.ProductAttribute.
  Ročni korak: ne. Migrator ne pozna GO.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;

IF UNICODE(N'č') <> 269
  THROW 52940, N'294: datoteka ni prebrana kot UTF-8 (sqlcmd -f 65001 ali Invoke-PendingMigrations.ps1).', 1;
IF OBJECT_ID(N'pim.AttributeValueNormalizationLog', N'U') IS NULL
  THROW 52941, N'294: najprej 291 (pim.AttributeValueNormalizationLog).', 1;

/* === 1. Zajem: končnica SLO/ANG -> jezik ============================================================== */
DECLARE @Inbox nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'map.ProcessRawInbox'));
IF @Inbox NOT LIKE N'%/* Jezik294:%'
BEGIN
  DECLARE @Anchors TABLE (Anchor nvarchar(400), Replacement nvarchar(max));
  INSERT @Anchors VALUES
  (N'SELECT ProductId,CONVERT(nvarchar(200),SUBSTRING(TargetFieldCode,18,200)) AttributeCode,MAX(Value) Value',
   N'/* Jezik294: »<ime> SLO/ANG« je <ime> v jeziku sl/en, ce je <ime> atribut v registru (124 je to naredila
           enkrat za obstojece vrstice, zajem pa je do 294 pisal stara imena). */
        SELECT ProductId,AttributeCode,LanguageCode,MAX(Value) Value
        FROM (SELECT attributeValue.ProductId, attributeValue.Value,
                CONVERT(nvarchar(200),COALESCE(suffix294.BaseName,SUBSTRING(attributeValue.TargetFieldCode,18,200))) AttributeCode,
                CONVERT(nvarchar(10),suffix294.LanguageCode) LanguageCode
              FROM #Value attributeValue
              OUTER APPLY (SELECT BaseName=LEFT(SUBSTRING(attributeValue.TargetFieldCode,18,200),LEN(SUBSTRING(attributeValue.TargetFieldCode,18,200))-4),
                                  LanguageCode=CASE RIGHT(attributeValue.TargetFieldCode,4) WHEN N'' SLO'' THEN N''sl'' ELSE N''en'' END
                           WHERE RIGHT(attributeValue.TargetFieldCode,4) IN (N'' SLO'',N'' ANG'')
                             AND EXISTS(SELECT 1 FROM canon.AttributeTranslation registered
                                        WHERE registered.LanguageCode=N''sl''
                                          AND registered.Name=LEFT(SUBSTRING(attributeValue.TargetFieldCode,18,200),LEN(SUBSTRING(attributeValue.TargetFieldCode,18,200))-4))) suffix294
              WHERE attributeValue.TargetFieldCode LIKE ''ProductAttribute.%'') attribute294'),
  (N'GROUP BY ProductId,SUBSTRING(TargetFieldCode,18,200)',
   N'GROUP BY ProductId,AttributeCode,LanguageCode'),
  (N'ON target.ProductId=source.ProductId AND target.AttributeCode=source.AttributeCode',
   N'ON target.ProductId=source.ProductId AND target.AttributeCode=source.AttributeCode
          AND ISNULL(target.LanguageCode,N'''')=ISNULL(source.LanguageCode,N'''')'),
  (N'WHEN NOT MATCHED THEN INSERT(ProductId,AttributeCode,Value)',
   N'WHEN NOT MATCHED THEN INSERT(ProductId,AttributeCode,LanguageCode,Value)'),
  (N'VALUES(source.ProductId,source.AttributeCode,source.Value);',
   N'VALUES(source.ProductId,source.AttributeCode,source.LanguageCode,source.Value);');

  DECLARE @MissingAnchor nvarchar(400) = (SELECT TOP (1) Anchor FROM @Anchors
    WHERE (DATALENGTH(@Inbox) - DATALENGTH(REPLACE(@Inbox, Anchor, N''))) / DATALENGTH(Anchor) <> 1);
  IF @MissingAnchor IS NOT NULL
  BEGIN
    DECLARE @AnchorMessage nvarchar(600) = CONCAT(N'294: map.ProcessRawInbox nima natanko enega sidra »', @MissingAnchor, N'«; nič ni spremenjeno.');
    THROW 52942, @AnchorMessage, 1;
  END;
  /* Vrstni red sidra »WHERE TargetFieldCode LIKE 'ProductAttribute.%'« za prvim sidrom: preverimo, da je
     izvirni stavek res SELECT … FROM #Value WHERE … GROUP BY (sicer bi stari WHERE ostal ob novem FROM). */
  DECLARE @First int = CHARINDEX(N'SELECT ProductId,CONVERT(nvarchar(200),SUBSTRING(TargetFieldCode,18,200)) AttributeCode,MAX(Value) Value', @Inbox);
  DECLARE @Group int = CHARINDEX(N'GROUP BY ProductId,SUBSTRING(TargetFieldCode,18,200)', @Inbox);
  DECLARE @Between nvarchar(max) = SUBSTRING(@Inbox, @First + 104, @Group - @First - 104);
  IF REPLACE(REPLACE(REPLACE(REPLACE(@Between, NCHAR(13), N''), NCHAR(10), N''), N' ', N''), NCHAR(9), N'')
       <> N'FROM#ValueWHERETargetFieldCodeLIKE''ProductAttribute.%'''
    THROW 52943, N'294: stavek atributov v map.ProcessRawInbox ni v pričakovani obliki; nič ni spremenjeno.', 1;
  /* Stari »FROM #Value WHERE …« med sidroma odstranimo — novi SELECT ima svoj FROM. */
  SET @Inbox = STUFF(@Inbox, @First + 104, @Group - @First - 104, NCHAR(10) + N'        ');

  DECLARE @Anchor nvarchar(400), @Replacement nvarchar(max);
  DECLARE anchors CURSOR LOCAL FAST_FORWARD FOR SELECT Anchor, Replacement FROM @Anchors;
  OPEN anchors;
  FETCH NEXT FROM anchors INTO @Anchor, @Replacement;
  WHILE @@FETCH_STATUS = 0
  BEGIN
    SET @Inbox = REPLACE(@Inbox, @Anchor, @Replacement);
    FETCH NEXT FROM anchors INTO @Anchor, @Replacement;
  END;
  CLOSE anchors; DEALLOCATE anchors;

  IF @Inbox NOT LIKE N'%/* Jezik294:%' OR @Inbox NOT LIKE N'%INSERT(ProductId,AttributeCode,LanguageCode,Value)%'
    THROW 52944, N'294: zamenjave v map.ProcessRawInbox niso vse uspele; nič ni spremenjeno.', 1;
  SET @Inbox = N'ALTER ' + SUBSTRING(@Inbox, CHARINDEX(N'PROCEDURE', @Inbox), 2147483647);
  EXEC sys.sp_executesql @Inbox;
END;

/* === 2. Podatki: stara imena -> ime + jezik ========================================================== */
CREATE TABLE #Old
  (TableName nvarchar(60) COLLATE DATABASE_DEFAULT NOT NULL, RowId bigint NOT NULL, OwnerId bigint NOT NULL,
   OrganizationId int NULL, ItemID nvarchar(200) COLLATE DATABASE_DEFAULT NULL,
   OldName nvarchar(400) COLLATE DATABASE_DEFAULT NOT NULL, BaseName nvarchar(400) COLLATE DATABASE_DEFAULT NOT NULL,
   LanguageCode nvarchar(10) COLLATE DATABASE_DEFAULT NOT NULL, Value nvarchar(max) COLLATE DATABASE_DEFAULT NULL);

INSERT #Old (TableName, RowId, OwnerId, OrganizationId, ItemID, OldName, BaseName, LanguageCode, Value)
SELECT N'canon.ProductAttribute', a.ProductAttributeId, a.ProductId, p.OrganizationId, p.ItemID, a.AttributeCode,
       LEFT(a.AttributeCode, LEN(a.AttributeCode) - 4), CASE RIGHT(a.AttributeCode, 4) WHEN N' SLO' THEN N'sl' ELSE N'en' END, a.Value
FROM canon.ProductAttribute a
INNER JOIN canon.Product p ON p.ProductId = a.ProductId
WHERE RIGHT(a.AttributeCode, 4) IN (N' SLO', N' ANG') AND a.LanguageCode IS NULL
  AND EXISTS (SELECT 1 FROM canon.AttributeTranslation t WHERE t.LanguageCode = N'sl' AND t.Name = LEFT(a.AttributeCode, LEN(a.AttributeCode) - 4))
UNION ALL
SELECT N'pim.ProductAttribute', a.PimProductAttributeId, a.PimProductId, p.OrganizationId, p.ItemID, a.AttributeCode,
       LEFT(a.AttributeCode, LEN(a.AttributeCode) - 4), CASE RIGHT(a.AttributeCode, 4) WHEN N' SLO' THEN N'sl' ELSE N'en' END, a.Value
FROM pim.ProductAttribute a
INNER JOIN pim.Product p ON p.PimProductId = a.PimProductId
WHERE RIGHT(a.AttributeCode, 4) IN (N' SLO', N' ANG') AND a.LanguageCode IS NULL
  AND EXISTS (SELECT 1 FROM canon.AttributeTranslation t WHERE t.LanguageCode = N'sl' AND t.Name = LEFT(a.AttributeCode, LEN(a.AttributeCode) - 4));

/* Ročno popravljene pravilne vrstice (intranet) — njihova vrednost ostane. */
CREATE TABLE #Manual
  (OrganizationId int NOT NULL, ItemID nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL, BaseName nvarchar(400) COLLATE DATABASE_DEFAULT NOT NULL);
INSERT #Manual (OrganizationId, ItemID, BaseName)
SELECT DISTINCT history.OrganizationId, history.ItemID, history.CanonColumn
FROM pim.ProductFieldHistory history
INNER JOIN pim.ProductChangeBatch batch ON batch.ChangeBatchId = history.ChangeBatchId
WHERE history.FieldKey = N'ProductAttribute.Value' AND batch.ChangeSource = N'INTRANET'
  AND history.CanonColumn IN (SELECT DISTINCT BaseName FROM #Old);

BEGIN TRANSACTION;
  EXEC sys.sp_set_session_context @key = N'ChangeSource', @value = N'POENOTENJE';
  EXEC sys.sp_set_session_context @key = N'ChangedBy', @value = N'migracija 294';
  EXEC sys.sp_set_session_context @key = N'ChangeNote', @value = N'294: »<ime> SLO/ANG« -> <ime> z jezikom sl/en';

  /* canon: posodobi pravilno vrstico (razen ročne) */
  DECLARE @CanonUpdated TABLE (RowId bigint, OldValue nvarchar(max), NewValue nvarchar(max));
  UPDATE target SET Value = old.Value
  OUTPUT inserted.ProductAttributeId, deleted.Value, inserted.Value INTO @CanonUpdated
  FROM canon.ProductAttribute target
  INNER JOIN #Old old ON old.TableName = N'canon.ProductAttribute' AND old.OwnerId = target.ProductId
    AND old.BaseName = target.AttributeCode AND old.LanguageCode = target.LanguageCode
  WHERE ISNULL(target.Value, N'') COLLATE Latin1_General_BIN2 <> ISNULL(old.Value, N'') COLLATE Latin1_General_BIN2
    AND NOT EXISTS (SELECT 1 FROM #Manual m WHERE m.OrganizationId = old.OrganizationId AND m.ItemID = old.ItemID AND m.BaseName = old.BaseName);
  /* canon: manjkajoča pravilna vrstica nastane */
  DECLARE @CanonInserted TABLE (RowId bigint, NewValue nvarchar(max));
  INSERT canon.ProductAttribute (ProductId, AttributeCode, LanguageCode, Value)
  OUTPUT inserted.ProductAttributeId, inserted.Value INTO @CanonInserted
  SELECT old.OwnerId, old.BaseName, old.LanguageCode, old.Value
  FROM #Old old
  WHERE old.TableName = N'canon.ProductAttribute'
    AND NOT EXISTS (SELECT 1 FROM canon.ProductAttribute t WHERE t.ProductId = old.OwnerId AND t.AttributeCode = old.BaseName AND t.LanguageCode = old.LanguageCode);
  /* canon: stara vrstica gre */
  DELETE target FROM canon.ProductAttribute target
  INNER JOIN #Old old ON old.TableName = N'canon.ProductAttribute' AND old.RowId = target.ProductAttributeId;

  /* pim: enako */
  DECLARE @PimUpdated TABLE (RowId bigint, OldValue nvarchar(max), NewValue nvarchar(max));
  UPDATE target SET Value = old.Value
  OUTPUT inserted.PimProductAttributeId, deleted.Value, inserted.Value INTO @PimUpdated
  FROM pim.ProductAttribute target
  INNER JOIN #Old old ON old.TableName = N'pim.ProductAttribute' AND old.OwnerId = target.PimProductId
    AND old.BaseName = target.AttributeCode AND old.LanguageCode = target.LanguageCode
  WHERE ISNULL(target.Value, N'') COLLATE Latin1_General_BIN2 <> ISNULL(old.Value, N'') COLLATE Latin1_General_BIN2
    AND NOT EXISTS (SELECT 1 FROM #Manual m WHERE m.OrganizationId = old.OrganizationId AND m.ItemID = old.ItemID AND m.BaseName = old.BaseName);
  DECLARE @PimInserted TABLE (RowId bigint, NewValue nvarchar(max));
  INSERT pim.ProductAttribute (PimProductId, AttributeCode, LanguageCode, Value)
  OUTPUT inserted.PimProductAttributeId, inserted.Value INTO @PimInserted
  SELECT old.OwnerId, old.BaseName, old.LanguageCode, old.Value
  FROM #Old old
  WHERE old.TableName = N'pim.ProductAttribute'
    AND NOT EXISTS (SELECT 1 FROM pim.ProductAttribute t WHERE t.PimProductId = old.OwnerId AND t.AttributeCode = old.BaseName AND t.LanguageCode = old.LanguageCode);
  DELETE target FROM pim.ProductAttribute target
  INNER JOIN #Old old ON old.TableName = N'pim.ProductAttribute' AND old.RowId = target.PimProductAttributeId;

  /* Dnevnik: posodobljene, nove in odstranjene vrstice (odstranjena: NewValue NULL, ime staro). */
  INSERT pim.AttributeValueNormalizationLog (TableName, RowId, OrganizationId, ItemID, AttributeCode, LanguageCode, OldValue, NewValue, ChangedBy)
  SELECT N'canon.ProductAttribute', u.RowId, p.OrganizationId, p.ItemID, a.AttributeCode, a.LanguageCode, u.OldValue, u.NewValue, N'migracija 294'
  FROM @CanonUpdated u INNER JOIN canon.ProductAttribute a ON a.ProductAttributeId = u.RowId INNER JOIN canon.Product p ON p.ProductId = a.ProductId
  UNION ALL
  SELECT N'canon.ProductAttribute', i.RowId, p.OrganizationId, p.ItemID, a.AttributeCode, a.LanguageCode, NULL, i.NewValue, N'migracija 294'
  FROM @CanonInserted i INNER JOIN canon.ProductAttribute a ON a.ProductAttributeId = i.RowId INNER JOIN canon.Product p ON p.ProductId = a.ProductId
  UNION ALL
  SELECT N'pim.ProductAttribute', u.RowId, p.OrganizationId, p.ItemID, a.AttributeCode, a.LanguageCode, u.OldValue, u.NewValue, N'migracija 294'
  FROM @PimUpdated u INNER JOIN pim.ProductAttribute a ON a.PimProductAttributeId = u.RowId INNER JOIN pim.Product p ON p.PimProductId = a.PimProductId
  UNION ALL
  SELECT N'pim.ProductAttribute', i.RowId, p.OrganizationId, p.ItemID, a.AttributeCode, a.LanguageCode, NULL, i.NewValue, N'migracija 294'
  FROM @PimInserted i INNER JOIN pim.ProductAttribute a ON a.PimProductAttributeId = i.RowId INNER JOIN pim.Product p ON p.PimProductId = a.PimProductId
  UNION ALL
  SELECT old.TableName, old.RowId, old.OrganizationId, old.ItemID, old.OldName, NULL, old.Value, NULL, N'migracija 294'
  FROM #Old old;

  EXEC sys.sp_set_session_context @key = N'ChangeSource', @value = NULL;
  EXEC sys.sp_set_session_context @key = N'ChangedBy', @value = NULL;
  EXEC sys.sp_set_session_context @key = N'ChangeNote', @value = NULL;
COMMIT TRANSACTION;

/* === dokaz ============================================================================================ */
IF OBJECT_DEFINITION(OBJECT_ID(N'map.ProcessRawInbox')) NOT LIKE N'%/* Jezik294:%'
  THROW 52945, N'294: map.ProcessRawInbox ni posodobljena.', 1;
IF EXISTS (SELECT 1 FROM canon.ProductAttribute a
           WHERE RIGHT(a.AttributeCode, 4) IN (N' SLO', N' ANG') AND a.LanguageCode IS NULL
             AND EXISTS (SELECT 1 FROM canon.AttributeTranslation t WHERE t.LanguageCode = N'sl' AND t.Name = LEFT(a.AttributeCode, LEN(a.AttributeCode) - 4)))
  THROW 52946, N'294: v canon so še atributi s končnico SLO/ANG.', 1;
