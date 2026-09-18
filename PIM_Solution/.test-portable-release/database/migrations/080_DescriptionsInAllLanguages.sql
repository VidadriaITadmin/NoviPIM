/*
  080 — opisi artikla v vseh jezikih in slovenska druga vrstica naziva.

  Odlocitev uporabnika 2026-08-23: opisi morajo v katalog v vseh jezikih; slovenski je glavni,
  ostali so prevodi.

  Kaj je bilo narobe. Opisi so bili zajeti od prvega dne — 63 obdelanih strani — a v katalogu jih
  je bilo 0. Preslikava je brala pot 'Descriptions/Description/text()', besedilo pa je eno raven
  globlje, v 'Descriptions/Description/ItemDescription'. Izluscenih je bilo 84.466 vrednosti in
  vse do ene so bile prazne: prazna vrednost ne pade in ne opozori, zato tega ni bilo videti.

  Poleg tega ima vsak artikel vec opisov — po jeziku (LanguageID) in po vrsti (DescriptionType) —
  torej je to ista oblika kot nazivi po jezikih (072) in gre skozi isti postopek, ne skozi eno pot.

  Vrsta opisa: v podatkih so tri ('T' 1.980, 'O' 4, 'K' 2 na eni strani). 'T' je glavni in obdrzi
  ime DESCRIPTION; ostali dobijo pripono (DESCRIPTION_O, DESCRIPTION_K), da se nic ne izgubi in
  nic ne prepise glavnega opisa.

  Ob tem je popravljena se ena tiha vrzel: druga vrstica ERP naziva je bila prevzeta samo iz
  nazivov po jezikih, iz splosnih podatkov (kjer je slovenska) pa ne — zato je bil TITLE_ERP2.sl
  prazen, tuji jeziki pa polni.
*/

SET XACT_ABORT ON;

/* --- 1) vrsta besedila sme imeti pripono ------------------------------------ */

IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_CanonProductText_Type')
  ALTER TABLE canon.ProductText DROP CONSTRAINT CK_CanonProductText_Type;

/*
  Nasteti so nazivi, ker jih je koncno malo in so pogodba z izvozom. Opisi so dovoljeni kot
  druzina (DESCRIPTION, DESCRIPTION_O, DESCRIPTION_K ...), ker vrsto doloci vir in nova vrsta ne
  sme ustaviti zajema.
*/
ALTER TABLE canon.ProductText WITH CHECK
  ADD CONSTRAINT CK_CanonProductText_Type
  CHECK (TextType IN (N'WEB_TITLE', N'TITLE_ERP', N'TITLE_ERP2') OR TextType LIKE N'DESCRIPTION%');

/* --- 2) postopek za besedila pozna pripono vrste ---------------------------- */

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
        /*
          Vrsta besedila je v imenu ciljne kode (TITLE_ERP, DESCRIPTION). Nekateri viri jo se
          natancneje razlikujejo: SAOP poslje opise vec vrst (DescriptionType T, O, K). Kadar je
          ta vrednost preslikana v Record.TextTypeSuffix, se pripne k vrsti — razen privzete ''T'',
          ki ostane gola, da glavni opis obdrzi svoje ime.
        */
        REPLACE(besedilo.TargetFieldCode,''ProductTextByLanguage.'','''')
          + CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(zapis.TextTypeSuffix,''''))),'''') IS NULL
                   OR LTRIM(RTRIM(zapis.TextTypeSuffix))=''T'' THEN ''''
                 ELSE ''_'' + LTRIM(RTRIM(zapis.TextTypeSuffix)) END AS TextType,
        CONVERT(nvarchar(max),besedilo.Value) AS Value,
        zapis.RecordOrdinal
      INTO #Naziv
      FROM
      (
        SELECT value.RecordOrdinal,
          MAX(CASE WHEN value.TargetFieldCode=''Record.ItemID'' THEN CONVERT(nvarchar(100),value.Value) END) AS ItemID,
          MAX(CASE WHEN value.TargetFieldCode=''Record.LanguageId'' THEN CONVERT(nvarchar(50),value.Value) END) AS LanguageId,
          MAX(CASE WHEN value.TargetFieldCode=''Record.TextTypeSuffix'' THEN CONVERT(nvarchar(20),value.Value) END) AS TextTypeSuffix
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

/* --- 3) preslikave na vseh stirih SAOP konektorjih -------------------------- */

/* --- SAOP_DEMO --- */
EXEC(N'
DECLARE @ConnectorId int = (SELECT SourceConnectorId FROM map.SourceConnector WHERE SourceCode = N''SAOP_DEMO'' AND OrganizationId = 1);
IF @ConnectorId IS NOT NULL
BEGIN
  UPDATE map.EntityMapping
  SET RecordXPath = N''/ItemsDescriptions/itemDescriptions/Descriptions/Description'', TargetDomain = N''ProductText'', IsActive = 1
  WHERE SourceConnectorId = @ConnectorId AND EntityType = N''Descriptions'';

  /* Stara pot je brala <Description> namesto <ItemDescription> in je bila zato vedno prazna. */
  UPDATE map.FieldMapping SET IsActive = 0
  WHERE SourceConnectorId = @ConnectorId AND EntityType = N''Descriptions''
    AND TargetFieldCode IN (N''ProductText.DESCRIPTION.sl'', N''Product.ItemID'');

  MERGE map.FieldMapping AS target
  USING (VALUES
    (N''Descriptions'', N''../../ItemID/text()[1]'',        N''Record.ItemID'',                     CONVERT(bit,1)),
    (N''Descriptions'', N''LanguageID/text()[1]'',          N''Record.LanguageId'',                 CONVERT(bit,1)),
    (N''Descriptions'', N''DescriptionType/text()[1]'',     N''Record.TextTypeSuffix'',             CONVERT(bit,0)),
    (N''Descriptions'', N''ItemDescription/text()[1]'',     N''ProductTextByLanguage.DESCRIPTION'', CONVERT(bit,0)),
    (N''ItemGeneralData'', N''ItemTitle2/text()[1]'',       N''ProductText.TITLE_ERP2.sl'',         CONVERT(bit,0))
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
  UPDATE map.EntityMapping
  SET RecordXPath = N''/ItemsDescriptions/itemDescriptions/Descriptions/Description'', TargetDomain = N''ProductText'', IsActive = 1
  WHERE SourceConnectorId = @ConnectorId AND EntityType = N''Descriptions'';

  /* Stara pot je brala <Description> namesto <ItemDescription> in je bila zato vedno prazna. */
  UPDATE map.FieldMapping SET IsActive = 0
  WHERE SourceConnectorId = @ConnectorId AND EntityType = N''Descriptions''
    AND TargetFieldCode IN (N''ProductText.DESCRIPTION.sl'', N''Product.ItemID'');

  MERGE map.FieldMapping AS target
  USING (VALUES
    (N''Descriptions'', N''../../ItemID/text()[1]'',        N''Record.ItemID'',                     CONVERT(bit,1)),
    (N''Descriptions'', N''LanguageID/text()[1]'',          N''Record.LanguageId'',                 CONVERT(bit,1)),
    (N''Descriptions'', N''DescriptionType/text()[1]'',     N''Record.TextTypeSuffix'',             CONVERT(bit,0)),
    (N''Descriptions'', N''ItemDescription/text()[1]'',     N''ProductTextByLanguage.DESCRIPTION'', CONVERT(bit,0)),
    (N''ItemGeneralData'', N''ItemTitle2/text()[1]'',       N''ProductText.TITLE_ERP2.sl'',         CONVERT(bit,0))
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
  UPDATE map.EntityMapping
  SET RecordXPath = N''/ItemsDescriptions/itemDescriptions/Descriptions/Description'', TargetDomain = N''ProductText'', IsActive = 1
  WHERE SourceConnectorId = @ConnectorId AND EntityType = N''Descriptions'';

  /* Stara pot je brala <Description> namesto <ItemDescription> in je bila zato vedno prazna. */
  UPDATE map.FieldMapping SET IsActive = 0
  WHERE SourceConnectorId = @ConnectorId AND EntityType = N''Descriptions''
    AND TargetFieldCode IN (N''ProductText.DESCRIPTION.sl'', N''Product.ItemID'');

  MERGE map.FieldMapping AS target
  USING (VALUES
    (N''Descriptions'', N''../../ItemID/text()[1]'',        N''Record.ItemID'',                     CONVERT(bit,1)),
    (N''Descriptions'', N''LanguageID/text()[1]'',          N''Record.LanguageId'',                 CONVERT(bit,1)),
    (N''Descriptions'', N''DescriptionType/text()[1]'',     N''Record.TextTypeSuffix'',             CONVERT(bit,0)),
    (N''Descriptions'', N''ItemDescription/text()[1]'',     N''ProductTextByLanguage.DESCRIPTION'', CONVERT(bit,0)),
    (N''ItemGeneralData'', N''ItemTitle2/text()[1]'',       N''ProductText.TITLE_ERP2.sl'',         CONVERT(bit,0))
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
  UPDATE map.EntityMapping
  SET RecordXPath = N''/ItemsDescriptions/itemDescriptions/Descriptions/Description'', TargetDomain = N''ProductText'', IsActive = 1
  WHERE SourceConnectorId = @ConnectorId AND EntityType = N''Descriptions'';

  /* Stara pot je brala <Description> namesto <ItemDescription> in je bila zato vedno prazna. */
  UPDATE map.FieldMapping SET IsActive = 0
  WHERE SourceConnectorId = @ConnectorId AND EntityType = N''Descriptions''
    AND TargetFieldCode IN (N''ProductText.DESCRIPTION.sl'', N''Product.ItemID'');

  MERGE map.FieldMapping AS target
  USING (VALUES
    (N''Descriptions'', N''../../ItemID/text()[1]'',        N''Record.ItemID'',                     CONVERT(bit,1)),
    (N''Descriptions'', N''LanguageID/text()[1]'',          N''Record.LanguageId'',                 CONVERT(bit,1)),
    (N''Descriptions'', N''DescriptionType/text()[1]'',     N''Record.TextTypeSuffix'',             CONVERT(bit,0)),
    (N''Descriptions'', N''ItemDescription/text()[1]'',     N''ProductTextByLanguage.DESCRIPTION'', CONVERT(bit,0)),
    (N''ItemGeneralData'', N''ItemTitle2/text()[1]'',       N''ProductText.TITLE_ERP2.sl'',         CONVERT(bit,0))
  ) AS source(EntityType, SourceElement, TargetFieldCode, IsRequired)
    ON target.SourceConnectorId = @ConnectorId AND target.EntityType = source.EntityType
      AND target.TargetFieldCode = source.TargetFieldCode
  WHEN MATCHED THEN UPDATE SET SourceElement = source.SourceElement, IsRequired = source.IsRequired, IsActive = 1
  WHEN NOT MATCHED THEN INSERT (SourceConnectorId, EntityType, SourceElement, TargetFieldCode, IsRequired, IsActive)
    VALUES (@ConnectorId, source.EntityType, source.SourceElement, source.TargetFieldCode, source.IsRequired, 1);
END;
');

/* --- 4) preverbe ------------------------------------------------------------- */

EXEC(N'
IF (SELECT COUNT(*) FROM map.EntityMapping WHERE EntityType = N''Descriptions'' AND TargetDomain = N''ProductText'' AND IsActive = 1) < 4
  THROW 52801, ''Opisi niso nastavljeni kot besedilo po jezikih.'', 1;
IF (SELECT COUNT(*) FROM map.FieldMapping WHERE TargetFieldCode = N''ProductTextByLanguage.DESCRIPTION'' AND IsActive = 1) < 4
  THROW 52802, ''Preslikava opisa ni vpisana na vseh konektorjih.'', 1;
IF (SELECT COUNT(*) FROM map.FieldMapping WHERE TargetFieldCode = N''ProductText.DESCRIPTION.sl'' AND IsActive = 1) > 0
  THROW 52803, ''Stara, prazna pot opisa je se aktivna.'', 1;
');

IF NOT EXISTS
(
  SELECT 1 FROM sys.sql_modules
  WHERE object_id = OBJECT_ID(N'map.ProcessProductTextInbox') AND definition LIKE N'%TextTypeSuffix%'
)
  THROW 52804, 'Postopek za besedila ne pozna vrste opisa.', 1;
