/*
  072 — sifrant jezikov in nazivi artikla po jezikih.

  Zakaj zdaj: stolpca 4 in 5 Magento predloge ('Naziv artikla EN' in 'Naziv artikla') sta pri
  vseh 42.782 izvozenih izdelkih prazna. Vzrok ni izvoz — nazivi po jezikih so ze zajeti in
  cakajo v raw.Inbox (45 strani entitete GetItemsTitlesLanguage), le preslikave zanje ni bilo.

  Dvoje mora nastati hkrati, ker eno brez drugega ne dela:

  1. Sifrant jezikov (canon.Language). SAOP govori v sifrah (1, 2, 3), katalog pa v kodah
     jezika ('sl', 'en', 'de'), ker tako je zapisan canon.ProductText.Lang in tako ga bere
     izvoz. Prevod imena jezika v kodo je vrstica slovarja (map.ValueLookup, domena
     'SAOP jezik'), ne veja v programu: nov jezik je nova vrstica, ne nova namestitev.

  2. Nazivi po jezikih (canon.ProductText). map.ProcessRawInbox tega ne zna, ker jezik pozna
     samo kot del imena ciljne kode (ProductText.TITLE_ERP.sl); tu pa jezik pride iz podatka in
     je na vsakem zapisu drugacen. Zato svoj postopek, po vzorcu skladisc (064).

  Oblika odgovora ima naziv en nivo globlje od sifre artikla:
    <itemTitlesLanguage><ItemID>..</ItemID><Titles><Title><LanguageID>..</LanguageID>...
  Zapis je <Title>, sifra artikla pa se bere s potjo '../../ItemID' — XPath 1.0 to zna in
  izlusevalec ze uporablja XPathNavigator, zato nova koda ni potrebna.

  Kar ta migracija namenoma NE naredi: ne odloca, ali je ERP naziv v tujem jeziku hkrati
  spletni naziv. Nazivi pristanejo kot TITLE_ERP v svojem jeziku; ce naj bo iz njih tudi
  WEB_TITLE, je to ena vrstica vec in odlocitev uporabnika.
*/

SET XACT_ABORT ON;

/* --- 1) sifrant jezikov ------------------------------------------------------ */

IF OBJECT_ID(N'canon.Language') IS NULL
BEGIN
  CREATE TABLE canon.Language
  (
    LanguageRowId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Language PRIMARY KEY,
    OrganizationId int NOT NULL,
    LanguageId nvarchar(50) NOT NULL,
    Name nvarchar(200) NULL,
    LanguageCode nvarchar(20) NULL,
    IsActive bit NOT NULL CONSTRAINT DF_Language_IsActive DEFAULT(1),
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_Language_UpdatedUtc DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_Language UNIQUE (OrganizationId, LanguageId),
    CONSTRAINT FK_Language_Organization FOREIGN KEY (OrganizationId) REFERENCES dbo.OrganizationConfig(OrganizationId)
  );
END;

/* --- 2) ime jezika -> koda jezika, kot vrstice slovarja ---------------------- */

MERGE map.ValueLookup AS target
USING (VALUES
  (N'SLOVENSCINA',   N'sl'), (N'SLOVENŠČINA',   N'sl'),
  (N'ANGLESCINA',    N'en'), (N'ANGLEŠČINA',    N'en'),
  (N'NEMSCINA',      N'de'), (N'NEMŠČINA',      N'de'),
  (N'HRVASCINA',     N'hr'), (N'HRVAŠČINA',     N'hr'),
  (N'ITALIJANSCINA', N'it'), (N'ITALIJANŠČINA', N'it'),
  (N'SRBSCINA',      N'sr'), (N'SRBŠČINA',      N'sr'),
  (N'MADZARSCINA',   N'hu'), (N'MADŽARŠČINA',   N'hu')
) AS source(SourceValue, TargetValue)
  ON target.Domain = N'SAOP jezik' AND target.SourceValue = source.SourceValue AND target.Language = N'CODE'
WHEN MATCHED THEN UPDATE SET TargetValue = source.TargetValue, IsActive = 1
WHEN NOT MATCHED THEN INSERT (Domain, SourceValue, Language, TargetValue, Note, IsActive)
  VALUES (N'SAOP jezik', source.SourceValue, N'CODE', source.TargetValue, N'migracija 072', 1);

/* --- 3) entiteti smeta imeti svoj svet -------------------------------------- */

IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_EntityMapping_TargetDomain')
  ALTER TABLE map.EntityMapping DROP CONSTRAINT CK_EntityMapping_TargetDomain;

ALTER TABLE map.EntityMapping WITH CHECK
  ADD CONSTRAINT CK_EntityMapping_TargetDomain
  CHECK (TargetDomain IN (N'Product', N'Warehouse', N'Language', N'ProductText'));

/* --- 4) preslikave na vseh stirih SAOP konektorjih -------------------------- */

/* --- SAOP_DEMO --- */
EXEC(N'
DECLARE @ConnectorId int = (SELECT SourceConnectorId FROM map.SourceConnector WHERE SourceCode = N''SAOP_DEMO'' AND OrganizationId = 1);
IF @ConnectorId IS NOT NULL
BEGIN
  MERGE map.EntityMapping AS target
  USING (VALUES
    (N''GetLanguages'',           N''/ArrayOfLanguage/Language'',                          N''Language''),
    (N''GetItemsTitlesLanguage'', N''/itemsTitlesLanguage/itemTitlesLanguage/Titles/Title'', N''ProductText'')
  ) AS source(EntityType, RecordXPath, TargetDomain)
    ON target.SourceConnectorId = @ConnectorId AND target.EntityType = source.EntityType
  WHEN MATCHED THEN UPDATE SET RecordXPath = source.RecordXPath, TargetDomain = source.TargetDomain, IsActive = 1
  WHEN NOT MATCHED THEN INSERT (SourceConnectorId, EntityType, RecordXPath, TargetDomain, IsActive)
    VALUES (@ConnectorId, source.EntityType, source.RecordXPath, source.TargetDomain, 1);

  MERGE map.FieldMapping AS target
  USING (VALUES
    (N''GetLanguages'',           N''LanguageID/text()[1]'',          N''Language.Id'',   CONVERT(bit,1)),
    (N''GetLanguages'',           N''LanguageDescription/text()[1]'', N''Language.Name'', CONVERT(bit,0)),
    (N''GetItemsTitlesLanguage'', N''../../ItemID/text()[1]'',        N''Record.ItemID'',     CONVERT(bit,1)),
    (N''GetItemsTitlesLanguage'', N''LanguageID/text()[1]'',          N''Record.LanguageId'', CONVERT(bit,1)),
    (N''GetItemsTitlesLanguage'', N''ItemTitle1/text()[1]'',          N''ProductTextByLanguage.TITLE_ERP'',  CONVERT(bit,0)),
    (N''GetItemsTitlesLanguage'', N''ItemTitle2/text()[1]'',          N''ProductTextByLanguage.TITLE_ERP2'', CONVERT(bit,0))
  ) AS source(EntityType, SourceElement, TargetFieldCode, IsRequired)
    ON target.SourceConnectorId = @ConnectorId AND target.EntityType = source.EntityType
      AND target.TargetFieldCode = source.TargetFieldCode
  WHEN MATCHED THEN UPDATE SET SourceElement = source.SourceElement, IsRequired = source.IsRequired, IsActive = 1
  WHEN NOT MATCHED THEN INSERT (SourceConnectorId, EntityType, SourceElement, TargetFieldCode, IsRequired, IsActive)
    VALUES (@ConnectorId, source.EntityType, source.SourceElement, source.TargetFieldCode, source.IsRequired, 1);
END;
');

/* --- SAOP_IQLIGHTING --- */
EXEC(N'
DECLARE @ConnectorId int = (SELECT SourceConnectorId FROM map.SourceConnector WHERE SourceCode = N''SAOP_IQLIGHTING'' AND OrganizationId = 2);
IF @ConnectorId IS NOT NULL
BEGIN
  MERGE map.EntityMapping AS target
  USING (VALUES
    (N''GetLanguages'',           N''/ArrayOfLanguage/Language'',                          N''Language''),
    (N''GetItemsTitlesLanguage'', N''/itemsTitlesLanguage/itemTitlesLanguage/Titles/Title'', N''ProductText'')
  ) AS source(EntityType, RecordXPath, TargetDomain)
    ON target.SourceConnectorId = @ConnectorId AND target.EntityType = source.EntityType
  WHEN MATCHED THEN UPDATE SET RecordXPath = source.RecordXPath, TargetDomain = source.TargetDomain, IsActive = 1
  WHEN NOT MATCHED THEN INSERT (SourceConnectorId, EntityType, RecordXPath, TargetDomain, IsActive)
    VALUES (@ConnectorId, source.EntityType, source.RecordXPath, source.TargetDomain, 1);

  MERGE map.FieldMapping AS target
  USING (VALUES
    (N''GetLanguages'',           N''LanguageID/text()[1]'',          N''Language.Id'',   CONVERT(bit,1)),
    (N''GetLanguages'',           N''LanguageDescription/text()[1]'', N''Language.Name'', CONVERT(bit,0)),
    (N''GetItemsTitlesLanguage'', N''../../ItemID/text()[1]'',        N''Record.ItemID'',     CONVERT(bit,1)),
    (N''GetItemsTitlesLanguage'', N''LanguageID/text()[1]'',          N''Record.LanguageId'', CONVERT(bit,1)),
    (N''GetItemsTitlesLanguage'', N''ItemTitle1/text()[1]'',          N''ProductTextByLanguage.TITLE_ERP'',  CONVERT(bit,0)),
    (N''GetItemsTitlesLanguage'', N''ItemTitle2/text()[1]'',          N''ProductTextByLanguage.TITLE_ERP2'', CONVERT(bit,0))
  ) AS source(EntityType, SourceElement, TargetFieldCode, IsRequired)
    ON target.SourceConnectorId = @ConnectorId AND target.EntityType = source.EntityType
      AND target.TargetFieldCode = source.TargetFieldCode
  WHEN MATCHED THEN UPDATE SET SourceElement = source.SourceElement, IsRequired = source.IsRequired, IsActive = 1
  WHEN NOT MATCHED THEN INSERT (SourceConnectorId, EntityType, SourceElement, TargetFieldCode, IsRequired, IsActive)
    VALUES (@ConnectorId, source.EntityType, source.SourceElement, source.TargetFieldCode, source.IsRequired, 1);
END;
');

/* --- SAOP_VIDADRIA --- */
EXEC(N'
DECLARE @ConnectorId int = (SELECT SourceConnectorId FROM map.SourceConnector WHERE SourceCode = N''SAOP_VIDADRIA'' AND OrganizationId = 3);
IF @ConnectorId IS NOT NULL
BEGIN
  MERGE map.EntityMapping AS target
  USING (VALUES
    (N''GetLanguages'',           N''/ArrayOfLanguage/Language'',                          N''Language''),
    (N''GetItemsTitlesLanguage'', N''/itemsTitlesLanguage/itemTitlesLanguage/Titles/Title'', N''ProductText'')
  ) AS source(EntityType, RecordXPath, TargetDomain)
    ON target.SourceConnectorId = @ConnectorId AND target.EntityType = source.EntityType
  WHEN MATCHED THEN UPDATE SET RecordXPath = source.RecordXPath, TargetDomain = source.TargetDomain, IsActive = 1
  WHEN NOT MATCHED THEN INSERT (SourceConnectorId, EntityType, RecordXPath, TargetDomain, IsActive)
    VALUES (@ConnectorId, source.EntityType, source.RecordXPath, source.TargetDomain, 1);

  MERGE map.FieldMapping AS target
  USING (VALUES
    (N''GetLanguages'',           N''LanguageID/text()[1]'',          N''Language.Id'',   CONVERT(bit,1)),
    (N''GetLanguages'',           N''LanguageDescription/text()[1]'', N''Language.Name'', CONVERT(bit,0)),
    (N''GetItemsTitlesLanguage'', N''../../ItemID/text()[1]'',        N''Record.ItemID'',     CONVERT(bit,1)),
    (N''GetItemsTitlesLanguage'', N''LanguageID/text()[1]'',          N''Record.LanguageId'', CONVERT(bit,1)),
    (N''GetItemsTitlesLanguage'', N''ItemTitle1/text()[1]'',          N''ProductTextByLanguage.TITLE_ERP'',  CONVERT(bit,0)),
    (N''GetItemsTitlesLanguage'', N''ItemTitle2/text()[1]'',          N''ProductTextByLanguage.TITLE_ERP2'', CONVERT(bit,0))
  ) AS source(EntityType, SourceElement, TargetFieldCode, IsRequired)
    ON target.SourceConnectorId = @ConnectorId AND target.EntityType = source.EntityType
      AND target.TargetFieldCode = source.TargetFieldCode
  WHEN MATCHED THEN UPDATE SET SourceElement = source.SourceElement, IsRequired = source.IsRequired, IsActive = 1
  WHEN NOT MATCHED THEN INSERT (SourceConnectorId, EntityType, SourceElement, TargetFieldCode, IsRequired, IsActive)
    VALUES (@ConnectorId, source.EntityType, source.SourceElement, source.TargetFieldCode, source.IsRequired, 1);
END;
');

/* --- SAOP_EDIITO --- */
EXEC(N'
DECLARE @ConnectorId int = (SELECT SourceConnectorId FROM map.SourceConnector WHERE SourceCode = N''SAOP_EDIITO'' AND OrganizationId = 4);
IF @ConnectorId IS NOT NULL
BEGIN
  MERGE map.EntityMapping AS target
  USING (VALUES
    (N''GetLanguages'',           N''/ArrayOfLanguage/Language'',                          N''Language''),
    (N''GetItemsTitlesLanguage'', N''/itemsTitlesLanguage/itemTitlesLanguage/Titles/Title'', N''ProductText'')
  ) AS source(EntityType, RecordXPath, TargetDomain)
    ON target.SourceConnectorId = @ConnectorId AND target.EntityType = source.EntityType
  WHEN MATCHED THEN UPDATE SET RecordXPath = source.RecordXPath, TargetDomain = source.TargetDomain, IsActive = 1
  WHEN NOT MATCHED THEN INSERT (SourceConnectorId, EntityType, RecordXPath, TargetDomain, IsActive)
    VALUES (@ConnectorId, source.EntityType, source.RecordXPath, source.TargetDomain, 1);

  MERGE map.FieldMapping AS target
  USING (VALUES
    (N''GetLanguages'',           N''LanguageID/text()[1]'',          N''Language.Id'',   CONVERT(bit,1)),
    (N''GetLanguages'',           N''LanguageDescription/text()[1]'', N''Language.Name'', CONVERT(bit,0)),
    (N''GetItemsTitlesLanguage'', N''../../ItemID/text()[1]'',        N''Record.ItemID'',     CONVERT(bit,1)),
    (N''GetItemsTitlesLanguage'', N''LanguageID/text()[1]'',          N''Record.LanguageId'', CONVERT(bit,1)),
    (N''GetItemsTitlesLanguage'', N''ItemTitle1/text()[1]'',          N''ProductTextByLanguage.TITLE_ERP'',  CONVERT(bit,0)),
    (N''GetItemsTitlesLanguage'', N''ItemTitle2/text()[1]'',          N''ProductTextByLanguage.TITLE_ERP2'', CONVERT(bit,0))
  ) AS source(EntityType, SourceElement, TargetFieldCode, IsRequired)
    ON target.SourceConnectorId = @ConnectorId AND target.EntityType = source.EntityType
      AND target.TargetFieldCode = source.TargetFieldCode
  WHEN MATCHED THEN UPDATE SET SourceElement = source.SourceElement, IsRequired = source.IsRequired, IsActive = 1
  WHEN NOT MATCHED THEN INSERT (SourceConnectorId, EntityType, SourceElement, TargetFieldCode, IsRequired, IsActive)
    VALUES (@ConnectorId, source.EntityType, source.SourceElement, source.TargetFieldCode, source.IsRequired, 1);
END;
');

/* --- 5) postopka ------------------------------------------------------------- */

EXEC(N'
CREATE OR ALTER PROCEDURE map.ProcessLanguageInbox
  @RunId uniqueidentifier,
  @OrganizationId int,
  @SourceCode nvarchar(100)
AS
BEGIN
  /*
    Sifrant jezikov iz SAOP v canon.Language. Loceno od izdelkov, enako kot skladisca (064).

    SAOP poslje sifro in ime (''1'' + ''SLOVENSCINA''). Katalog pa govori v kodah jezika (''sl''),
    ker tako je zapisan canon.ProductText.Lang in tako ga bere izvoz. Prevod imena v kodo ni
    v kodi programa, ampak v slovarju vrednosti (map.ValueLookup, domena ''SAOP jezik''), da nov
    jezik ne pomeni nove razlicice programa.

    Jezik brez vpisa v slovarju se vseeno shrani, le brez kode — takrat je v canon.Language
    viden in ceka na eno vrstico slovarja. Nazivi v tem jeziku se do takrat ne preslikajo.
  */
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  DECLARE @InboxId bigint;
  DECLARE language_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT inbox.InboxId
    FROM raw.Inbox inbox
    WHERE inbox.RunId=@RunId AND inbox.OrganizationId=@OrganizationId
      AND inbox.SourceCode=@SourceCode AND inbox.Status=''Pending''
      AND EXISTS
      (
        SELECT 1
        FROM map.EntityMapping entityMapping
        INNER JOIN map.SourceConnector connector ON connector.SourceConnectorId=entityMapping.SourceConnectorId
        WHERE connector.SourceCode=inbox.SourceCode AND connector.OrganizationId=inbox.OrganizationId
          AND entityMapping.EntityType=inbox.EntityType AND entityMapping.IsActive=1
          AND entityMapping.TargetDomain=''Language''
      )
    ORDER BY inbox.InboxId;

  OPEN language_cursor;
  FETCH NEXT FROM language_cursor INTO @InboxId;
  WHILE @@FETCH_STATUS=0
  BEGIN
    BEGIN TRY
      BEGIN TRANSACTION;

      ;WITH zapis AS
      (
        SELECT value.RecordOrdinal,
          MAX(CASE WHEN value.TargetFieldCode=''Language.Id'' THEN CONVERT(nvarchar(50),value.Value) END) AS LanguageId,
          MAX(CASE WHEN value.TargetFieldCode=''Language.Name'' THEN CONVERT(nvarchar(200),value.Value) END) AS Name
        FROM map.ExtractedValue value
        WHERE value.InboxId=@InboxId
          AND EXISTS(SELECT 1 FROM map.FieldMapping mapping
                     WHERE mapping.FieldMappingId=value.FieldMappingId AND mapping.IsActive=1)
        GROUP BY value.RecordOrdinal
      )
      MERGE canon.Language AS target
      USING
      (
        SELECT @OrganizationId AS OrganizationId,
          LTRIM(RTRIM(zapis.LanguageId)) AS LanguageId,
          NULLIF(LTRIM(RTRIM(zapis.Name)),'''') AS Name,
          (
            SELECT TOP(1) slovar.TargetValue
            FROM map.ValueLookup slovar
            WHERE slovar.Domain=''SAOP jezik'' AND slovar.IsActive=1
              AND UPPER(slovar.SourceValue)=UPPER(LTRIM(RTRIM(zapis.Name)))
            ORDER BY slovar.ValueLookupId
          ) AS LanguageCode
        FROM zapis
        WHERE NULLIF(LTRIM(RTRIM(zapis.LanguageId)),'''') IS NOT NULL
      ) source
        ON target.OrganizationId=source.OrganizationId AND target.LanguageId=source.LanguageId
      WHEN MATCHED THEN UPDATE SET
        Name=ISNULL(source.Name,target.Name),
        LanguageCode=ISNULL(source.LanguageCode,target.LanguageCode),
        UpdatedUtc=SYSUTCDATETIME()
      WHEN NOT MATCHED THEN INSERT(OrganizationId,LanguageId,Name,LanguageCode)
        VALUES(source.OrganizationId,source.LanguageId,source.Name,source.LanguageCode);

      DECLARE @BrezKode int =
        (SELECT COUNT(*) FROM canon.Language WHERE OrganizationId=@OrganizationId AND LanguageCode IS NULL);

      UPDATE raw.Inbox
      SET Status=''Processed'', ProcessedUtc=SYSUTCDATETIME(),
          FailureReason=CASE WHEN @BrezKode=0 THEN NULL
            ELSE CONCAT(''Jezikov brez kode v slovarju: '', @BrezKode, ''.'') END
      WHERE InboxId=@InboxId;

      COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
      IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
      DECLARE @Napaka nvarchar(500)=ERROR_MESSAGE();
      UPDATE raw.Inbox SET Status=''Quarantined'', ProcessedUtc=SYSUTCDATETIME(), FailureReason=LEFT(@Napaka,2000)
      WHERE InboxId=@InboxId;
    END CATCH;

    FETCH NEXT FROM language_cursor INTO @InboxId;
  END;
  CLOSE language_cursor;
  DEALLOCATE language_cursor;
END;
');

EXEC(N'
CREATE OR ALTER PROCEDURE map.ProcessProductTextInbox
  @RunId uniqueidentifier,
  @OrganizationId int,
  @SourceCode nvarchar(100)
AS
BEGIN
  /*
    Nazivi artikla po jezikih. Loceno od map.ProcessRawInbox, ker ta pozna jezik samo v imenu
    ciljne kode (ProductText.TITLE_ERP.sl), tukaj pa jezik pride iz podatka (LanguageID) in je
    na vsakem zapisu drugacen.

    Kaj potrebuje:
      TargetDomain = ''ProductText'' na entiteti,
      Record.ItemID           sifra artikla (na tej obliki je en nivo visje: ../../ItemID),
      Record.LanguageId       sifra jezika iz SAOP,
      ProductTextByLanguage.<VRSTA>  vrednost; vrsta je del ciljne kode (TITLE_ERP, TITLE_ERP2).

    Jezik se prevede prek canon.Language; zapis v jeziku brez kode se preskoci in je prestet.
    Prazna vrednost ne prepise obstojece — SAOP poslje prazen naziv tudi tam, kjer ga ni.
  */
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  DECLARE @InboxId bigint;
  DECLARE text_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT inbox.InboxId
    FROM raw.Inbox inbox
    WHERE inbox.RunId=@RunId AND inbox.OrganizationId=@OrganizationId
      AND inbox.SourceCode=@SourceCode AND inbox.Status=''Pending''
      AND EXISTS
      (
        SELECT 1
        FROM map.EntityMapping entityMapping
        INNER JOIN map.SourceConnector connector ON connector.SourceConnectorId=entityMapping.SourceConnectorId
        WHERE connector.SourceCode=inbox.SourceCode AND connector.OrganizationId=inbox.OrganizationId
          AND entityMapping.EntityType=inbox.EntityType AND entityMapping.IsActive=1
          AND entityMapping.TargetDomain=''ProductText''
      )
    ORDER BY inbox.InboxId;

  OPEN text_cursor;
  FETCH NEXT FROM text_cursor INTO @InboxId;
  WHILE @@FETCH_STATUS=0
  BEGIN
    BEGIN TRY
      BEGIN TRANSACTION;

      IF OBJECT_ID(''tempdb..#Naziv'') IS NOT NULL DROP TABLE #Naziv;

      SELECT
        izdelek.ProductId,
        jezik.LanguageCode AS Lang,
        REPLACE(besedilo.TargetFieldCode,''ProductTextByLanguage.'','''') AS TextType,
        CONVERT(nvarchar(max),besedilo.Value) AS Value,
        zapis.RecordOrdinal
      INTO #Naziv
      FROM
      (
        SELECT value.RecordOrdinal,
          MAX(CASE WHEN value.TargetFieldCode=''Record.ItemID'' THEN CONVERT(nvarchar(100),value.Value) END) AS ItemID,
          MAX(CASE WHEN value.TargetFieldCode=''Record.LanguageId'' THEN CONVERT(nvarchar(50),value.Value) END) AS LanguageId
        FROM map.ExtractedValue value
        WHERE value.InboxId=@InboxId
        GROUP BY value.RecordOrdinal
      ) zapis
      INNER JOIN map.ExtractedValue besedilo
        ON besedilo.InboxId=@InboxId AND besedilo.RecordOrdinal=zapis.RecordOrdinal
        AND besedilo.TargetFieldCode LIKE ''ProductTextByLanguage.%''
        AND NULLIF(LTRIM(RTRIM(besedilo.Value)),'''') IS NOT NULL
      INNER JOIN canon.Language jezik
        ON jezik.OrganizationId=@OrganizationId AND jezik.LanguageId=LTRIM(RTRIM(zapis.LanguageId))
        AND jezik.LanguageCode IS NOT NULL
      INNER JOIN canon.Product izdelek
        ON izdelek.OrganizationId=@OrganizationId AND izdelek.ItemID=LTRIM(RTRIM(zapis.ItemID))
      WHERE EXISTS(SELECT 1 FROM map.FieldMapping mapping
                   WHERE mapping.FieldMappingId=besedilo.FieldMappingId AND mapping.IsActive=1);

      /* Ista trojica (izdelek, jezik, vrsta) se v eni strani lahko ponovi; obvelja zadnji zapis. */
      MERGE canon.ProductText AS target
      USING
      (
        SELECT ProductId, Lang, TextType, Value
        FROM
        (
          SELECT ProductId, Lang, TextType, Value,
            ROW_NUMBER() OVER(PARTITION BY ProductId, Lang, TextType ORDER BY RecordOrdinal DESC) AS Mesto
          FROM #Naziv
        ) zadnji
        WHERE Mesto=1
      ) source
        ON target.ProductId=source.ProductId AND target.Lang=source.Lang AND target.TextType=source.TextType
      WHEN MATCHED THEN UPDATE SET Value=source.Value
      WHEN NOT MATCHED THEN INSERT(ProductId,Lang,TextType,Value)
        VALUES(source.ProductId,source.Lang,source.TextType,source.Value);

      DECLARE @Zapisov int = (SELECT COUNT(DISTINCT value.RecordOrdinal) FROM map.ExtractedValue value WHERE value.InboxId=@InboxId);
      DECLARE @Uporabljenih int = (SELECT COUNT(DISTINCT RecordOrdinal) FROM #Naziv);

      UPDATE raw.Inbox
      SET Status=''Processed'', ProcessedUtc=SYSUTCDATETIME(),
          FailureReason=CASE WHEN @Uporabljenih=@Zapisov THEN NULL
            ELSE CONCAT(''Nazivov uporabljenih: '', @Uporabljenih, '' od '', @Zapisov,
                        ''. Preostali nimajo artikla v katalogu ali jezika v sifrantu.'') END
      WHERE InboxId=@InboxId;

      DROP TABLE #Naziv;
      COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
      IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
      DECLARE @Napaka nvarchar(500)=ERROR_MESSAGE();
      UPDATE raw.Inbox SET Status=''Quarantined'', ProcessedUtc=SYSUTCDATETIME(), FailureReason=LEFT(@Napaka,2000)
      WHERE InboxId=@InboxId;
    END CATCH;

    FETCH NEXT FROM text_cursor INTO @InboxId;
  END;
  CLOSE text_cursor;
  DEALLOCATE text_cursor;
END;
');

/* --- 6) preverbe ------------------------------------------------------------- */

EXEC(N'
IF (SELECT COUNT(*) FROM map.EntityMapping WHERE EntityType = N''GetLanguages'' AND TargetDomain = N''Language'' AND IsActive = 1) < 4
  THROW 52721, ''Sifrant jezikov ni nastavljen na vseh stirih konektorjih.'', 1;
IF (SELECT COUNT(*) FROM map.EntityMapping WHERE EntityType = N''GetItemsTitlesLanguage'' AND TargetDomain = N''ProductText'' AND IsActive = 1) < 4
  THROW 52722, ''Nazivi po jezikih niso nastavljeni na vseh stirih konektorjih.'', 1;
');

IF OBJECT_ID(N'map.ProcessLanguageInbox') IS NULL
  THROW 52723, 'Postopek map.ProcessLanguageInbox ne obstaja.', 1;
IF OBJECT_ID(N'map.ProcessProductTextInbox') IS NULL
  THROW 52724, 'Postopek map.ProcessProductTextInbox ne obstaja.', 1;
IF (SELECT COUNT(*) FROM map.ValueLookup WHERE Domain = N'SAOP jezik' AND IsActive = 1) < 10
  THROW 52725, 'Slovar imen jezikov ni vpisan.', 1;
