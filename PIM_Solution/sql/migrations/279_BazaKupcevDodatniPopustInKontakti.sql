/*
  279 - Baza kupcev ViD v delovnem listu strank: referent iz SAOP, skrbnik, e-posta za dobavnice
  in obvescanje, opombe ter dodatni popust po skupini artiklov (P2, npr. NW-P2 7 %).

  Uporabnik 2026-09-24: »kar manjka dodaj k uvozom in izvozom strank« - po pregledu datoteke
  »Baza kupcev_ViD_2026.xlsx« (listi B2B, Tujina, Dodatna pravila za artikle, Opombe strank 2.2026).

  Stanje pred migracijo (lokalna baza DAVID\MSSQL19, 2026-09-24):
    - Vseh 364 sifer z lista B2B, 18 s Tujine in 183 z Opomb je v Vidadrii (podjetje 3).
    - Popusti R1-R7, VD1 ... TT v Excelu so kopija SAOP rabatnega cenika (1.818 enakih, 10 razlicnih):
      ostanejo v SAOP in se NE uvazajo.
    - Stolpec »NW-P2« (7 % pri 21 strankah) je DRUGI popust, ki ga prodaja vpise v SAOP polje P2 na
      naroCilu; v rabatnem ceniku ga ni (izjema NW5 pri eni stranki). PIM pozna en odstotek na skupino.
    - SAOP zapis Customers nosi <SalesClerkID> (referent), PIM ga ni bral (preslikave ni bilo).
      Imen referentov SAOP v zajetih entitetah ne nosi.
    - pim.CustomerNote obstaja (129), a je prazen in ga delovni list ne pozna.
    - Kontakt ima eno e-posto (140); Excel loci e-posto za dobavnice in kontakt za obvescanje.

  Kaj naredi:
    1. b2b.Customer.SalesClerkCode + preslikava SalesClerkID za vse SAOP konektorje + map.ProcessCustomerInbox
       ga zapise (popravek zive definicije, isti vzorec kot 253). Obstojece stranke dobijo vrednost iz
       zadnje ze zajete strani raw.Inbox - to je SAOP podatek, ne rocni vnos.
    2. pim.SalesClerk: sifrant imen referentov po podjetju. Vidadria je napolnjena iz Excela (sifra v
       stolpcu »Referent prodaje« + najpogostejse ime v »Naziv referenta prodaje«), ker SAOP imen ne da.
    3. pim.CustomerExtra + b2b.SaveCustomerExtra: skrbnik stranke (rocno), e-posta za dobavnice,
       e-posta in oseba za obvescanje. Loceno od pim.CustomerContact, ker ta gre v stranke.csv.
    4. b2b.CustomerExtraGroupDiscount + Save/Remove: dodatni popust stranke po skupini artiklov.
    5. b2b.CustomerGroupDiscounts: dodatni popust se obracuna ZA osnovnim (kot P2 za P1 v SAOP):
       skupno = 100 - (100 - osnovni) * (100 - dodatni) / 100; brez osnovnega velja sam. Tako gre v
       stranke.csv (Skupine popustov, Popust NW), na stran Stranke in na kartico (nabor 2).
    6. intranet.GetCustomerListExtra: nova polja za stran in delovni list (loceno branje, da se
       intranet.GetCustomerList ne prepisuje).

  Cesa NE naredi: ne uvaza nicesar iz Excela (to naredi uvoz /stranke/uvoz), ne spreminja SAOP
  rabatov, ne pozna privzetih popustov po tipu (vrstice TRGOVINE, INSTALATERJI ... v Excelu) in ne
  »Dodatnih pravil za artikle« - to ostane odprto.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

/* --- 1) Referent iz SAOP ----------------------------------------------------------------------- */
IF COL_LENGTH(N'b2b.Customer', N'SalesClerkCode') IS NULL
  ALTER TABLE b2b.Customer ADD SalesClerkCode nvarchar(20) NULL;

MERGE map.FieldMapping AS target
USING
(
  SELECT connector.SourceConnectorId, EntityType = N'Customers', SourceElement = N'SalesClerkID/text()[1]',
    TargetFieldCode = N'Customer.SalesClerkCode', IsRequired = CONVERT(bit, 0)
  FROM map.SourceConnector AS connector
  WHERE connector.ConnectorType = N'SAOP' AND connector.SourceCode NOT LIKE N'%[_]STOCK'
    AND EXISTS (SELECT 1 FROM map.EntityMapping AS entity
                WHERE entity.SourceConnectorId = connector.SourceConnectorId AND entity.EntityType = N'Customers')
) AS source
  ON target.SourceConnectorId = source.SourceConnectorId AND target.EntityType = source.EntityType
 AND target.TargetFieldCode = source.TargetFieldCode
WHEN MATCHED THEN UPDATE SET SourceElement = source.SourceElement, IsRequired = source.IsRequired, IsActive = 1
WHEN NOT MATCHED THEN INSERT (SourceConnectorId, EntityType, SourceElement, TargetFieldCode, IsRequired, IsActive)
  VALUES (source.SourceConnectorId, source.EntityType, source.SourceElement, source.TargetFieldCode, source.IsRequired, 1);

DECLARE @definition nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'map.ProcessCustomerInbox'));
IF @definition IS NULL THROW 52790, N'279: map.ProcessCustomerInbox ne obstaja.', 1;
IF @definition NOT LIKE N'%SalesClerkCode%'
BEGIN
  DECLARE @patches TABLE (Ordinal int PRIMARY KEY, OldText nvarchar(400), NewText nvarchar(800));
  INSERT @patches (Ordinal, OldText, NewText) VALUES
    (1, N'NULLIF(LTRIM(RTRIM(zapis.PayerCode)),'''')          AS PayerCode,',
        N'NULLIF(LTRIM(RTRIM(zapis.PayerCode)),'''')          AS PayerCode,
        NULLIF(LTRIM(RTRIM(zapis.SalesClerkCode)),'''')     AS SalesClerkCode,'),
    (2, N'THEN CONVERT(nvarchar(200),value.Value) END) AS PayerCode,',
        N'THEN CONVERT(nvarchar(200),value.Value) END) AS PayerCode,
          MAX(CASE WHEN value.TargetFieldCode=''Customer.SalesClerkCode''       THEN CONVERT(nvarchar(20),value.Value)  END) AS SalesClerkCode,'),
    (3, N'PayerCode=ISNULL(source.PayerCode,target.PayerCode),',
        N'PayerCode=ISNULL(source.PayerCode,target.PayerCode),
        SalesClerkCode=ISNULL(source.SalesClerkCode,target.SalesClerkCode),'),
    (4, N'IsActive, IsDefaulter, UpfrontPayment, SourceInboxId, SourceRecordOrdinal)',
        N'IsActive, IsDefaulter, UpfrontPayment, SourceInboxId, SourceRecordOrdinal, SalesClerkCode)'),
    (5, N'@InboxId, source.RecordOrdinal);',
        N'@InboxId, source.RecordOrdinal, source.SalesClerkCode);');

  DECLARE @ordinal int = 1, @old nvarchar(400), @new nvarchar(800);
  WHILE @ordinal <= 5
  BEGIN
    SELECT @old = OldText, @new = NewText FROM @patches WHERE Ordinal = @ordinal;
    IF CHARINDEX(@old, @definition) = 0
    BEGIN
      DECLARE @message nvarchar(400) = CONCAT(N'279: map.ProcessCustomerInbox nima pricakovanega besedila (popravek ', @ordinal, N').');
      THROW 52791, @message, 1;
    END;
    SET @definition = REPLACE(@definition, @old, @new);
    SET @ordinal += 1;
  END;
  SET @definition = N'ALTER ' + SUBSTRING(@definition, CHARINDEX(N'PROCEDURE', @definition), 2147483647);
  EXEC sys.sp_executesql @definition;
END;

/* Obstojece stranke: zadnja zajeta SAOP stran, na kateri je stranka. EXEC, ker je stolpec nov v
   istem paketu (brez tega se paket ne prevede). */
/* Stran po stran v zacasno tabelo: pretvorba v xml znotraj CTE se je izvajala po vozliscu (> 5 min). */
CREATE TABLE #Page279 (InboxId bigint NOT NULL PRIMARY KEY, OrganizationId int NOT NULL, Payload xml NULL);
CREATE TABLE #Record279 (OrganizationId int NOT NULL, InboxId bigint NOT NULL,
  CustomerKey nvarchar(200) COLLATE DATABASE_DEFAULT NULL, SalesClerkCode nvarchar(20) COLLATE DATABASE_DEFAULT NULL);

INSERT #Page279 (InboxId, OrganizationId, Payload)
SELECT inbox.InboxId, inbox.OrganizationId, TRY_CONVERT(xml, REPLACE(inbox.PayloadXml, N'encoding="utf-8"', N''))
FROM raw.Inbox AS inbox
WHERE inbox.EntityType = N'Customers' AND inbox.PayloadXml LIKE N'%<SalesClerkID>%';

DECLARE @pageId bigint = (SELECT MIN(InboxId) FROM #Page279);
WHILE @pageId IS NOT NULL
BEGIN
  DECLARE @payload xml, @pageOrganization int;
  SELECT @payload = Payload, @pageOrganization = OrganizationId FROM #Page279 WHERE InboxId = @pageId;
  INSERT #Record279 (OrganizationId, InboxId, CustomerKey, SalesClerkCode)
  SELECT @pageOrganization, @pageId,
    LTRIM(RTRIM(node.value(N'(Code/text())[1]', N'nvarchar(200)'))),
    NULLIF(LTRIM(RTRIM(node.value(N'(SalesClerkID/text())[1]', N'nvarchar(20)'))), N'')
  FROM @payload.nodes(N'/ArrayOfCustomer/Customer') AS item(node);
  SET @pageId = (SELECT MIN(InboxId) FROM #Page279 WHERE InboxId > @pageId);
END;

EXEC(N'WITH latest AS
(
  SELECT record.*, Pick = ROW_NUMBER() OVER (PARTITION BY record.OrganizationId, record.CustomerKey ORDER BY record.InboxId DESC)
  FROM #Record279 AS record
)
UPDATE customer SET SalesClerkCode = latest.SalesClerkCode
FROM b2b.Customer AS customer
INNER JOIN latest ON latest.Pick = 1 AND latest.OrganizationId = customer.OrganizationId AND latest.CustomerKey = customer.CustomerKey
WHERE latest.SalesClerkCode IS NOT NULL AND ISNULL(customer.SalesClerkCode, N'''') <> latest.SalesClerkCode;');
DROP TABLE #Record279;
DROP TABLE #Page279;

/* --- 2) Imena referentov ----------------------------------------------------------------------- */
IF OBJECT_ID(N'pim.SalesClerk', N'U') IS NULL
  CREATE TABLE pim.SalesClerk
  (
    OrganizationId int NOT NULL,
    SalesClerkCode nvarchar(20) NOT NULL,
    Name nvarchar(200) NOT NULL,
    IsActive bit NOT NULL CONSTRAINT DF_SalesClerk_IsActive DEFAULT (1),
    UpdatedBy nvarchar(200) NOT NULL,
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_SalesClerk_UpdatedUtc DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT PK_SalesClerk PRIMARY KEY (OrganizationId, SalesClerkCode),
    CONSTRAINT FK_SalesClerk_Organization FOREIGN KEY (OrganizationId) REFERENCES dbo.OrganizationConfig (OrganizationId)
  );

/* Vidadria: iz Excela »Baza kupcev_ViD_2026.xlsx«, list B2B (sifra CK + najpogostejse ime v O). */
MERGE pim.SalesClerk AS target
USING
(
  SELECT OrganizationId = 3, SalesClerkCode, Name
  FROM (VALUES
    (N'0000001', N'Damjan Zupančič'), (N'0000002', N'Matic Rodič'), (N'0000003', N'Gorazd Mohorko'),
    (N'0000004', N'Matic Paderšič'), (N'0000011', N'Natalija Škorjanc'), (N'0000014', N'Katja Kresal'),
    (N'0000016', N'Aljaž Kostevc'), (N'0000020', N'Gregor Zorman')
  ) AS seed(SalesClerkCode, Name)
  WHERE EXISTS (SELECT 1 FROM dbo.OrganizationConfig WHERE OrganizationId = 3)
) AS source
  ON target.OrganizationId = source.OrganizationId AND target.SalesClerkCode = source.SalesClerkCode
WHEN NOT MATCHED THEN INSERT (OrganizationId, SalesClerkCode, Name, UpdatedBy)
  VALUES (source.OrganizationId, source.SalesClerkCode, source.Name, N'migracija 279');

/* --- 3) Skrbnik, e-posta za dobavnice in obvescanje --------------------------------------------- */
IF OBJECT_ID(N'pim.CustomerExtra', N'U') IS NULL
  CREATE TABLE pim.CustomerExtra
  (
    OrganizationId int NOT NULL,
    CustomerId bigint NOT NULL,
    /* Skrbnik v prodaji, kot ga vodi prodaja - ni nujno isti kot SAOP referent. */
    AccountManager nvarchar(200) NULL,
    DeliveryNoteEmail nvarchar(400) NULL,
    NoticeEmail nvarchar(400) NULL,
    NoticePerson nvarchar(400) NULL,
    UpdatedBy nvarchar(200) NOT NULL,
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_CustomerExtra_UpdatedUtc DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT PK_CustomerExtra PRIMARY KEY (CustomerId),
    CONSTRAINT FK_CustomerExtra_Customer FOREIGN KEY (CustomerId) REFERENCES b2b.Customer (CustomerId)
  );

EXEC(N'CREATE OR ALTER PROCEDURE b2b.SaveCustomerExtra
  @OrganizationId int,
  @CustomerId bigint,
  @AccountManager nvarchar(200) = NULL,
  @DeliveryNoteEmail nvarchar(400) = NULL,
  @NoticeEmail nvarchar(400) = NULL,
  @NoticePerson nvarchar(400) = NULL,
  @ChangedBy nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  IF NOT EXISTS (SELECT 1 FROM b2b.Customer WHERE CustomerId = @CustomerId AND OrganizationId = @OrganizationId)
    THROW 52792, N''Stranka v tem podjetju ne obstaja.'', 1;

  SET @AccountManager = NULLIF(LTRIM(RTRIM(@AccountManager)), N'''');
  SET @DeliveryNoteEmail = NULLIF(LTRIM(RTRIM(@DeliveryNoteEmail)), N'''');
  SET @NoticeEmail = NULLIF(LTRIM(RTRIM(@NoticeEmail)), N'''');
  SET @NoticePerson = NULLIF(LTRIM(RTRIM(@NoticePerson)), N'''');

  BEGIN TRAN;
  DECLARE @old nvarchar(max) = (SELECT * FROM pim.CustomerExtra WHERE CustomerId = @CustomerId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

  MERGE pim.CustomerExtra AS target
  USING (SELECT @OrganizationId AS OrganizationId, @CustomerId AS CustomerId) AS source ON target.CustomerId = source.CustomerId
  WHEN MATCHED THEN UPDATE SET AccountManager = @AccountManager, DeliveryNoteEmail = @DeliveryNoteEmail,
    NoticeEmail = @NoticeEmail, NoticePerson = @NoticePerson, UpdatedBy = @ChangedBy, UpdatedUtc = SYSUTCDATETIME()
  WHEN NOT MATCHED THEN INSERT (OrganizationId, CustomerId, AccountManager, DeliveryNoteEmail, NoticeEmail, NoticePerson, UpdatedBy)
    VALUES (@OrganizationId, @CustomerId, @AccountManager, @DeliveryNoteEmail, @NoticeEmail, @NoticePerson, @ChangedBy);

  INSERT b2b.AuditLog (OrganizationId, EntityType, EntityKey, ActionCode, OldValueJson, NewValueJson, ChangedBy)
  SELECT @OrganizationId, N''CustomerExtra'', CONVERT(nvarchar(200), @CustomerId), N''UPSERT'', @old,
    (SELECT * FROM pim.CustomerExtra WHERE CustomerId = @CustomerId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER), @ChangedBy;
  COMMIT;
END;');

/* --- 4) Dodatni popust po skupini artiklov (P2) ------------------------------------------------ */
IF OBJECT_ID(N'b2b.CustomerExtraGroupDiscount', N'U') IS NULL
BEGIN
  CREATE TABLE b2b.CustomerExtraGroupDiscount
  (
    ExtraDiscountId bigint IDENTITY(1,1) NOT NULL,
    OrganizationId int NOT NULL,
    CustomerId bigint NOT NULL,
    ItemGroupCode nvarchar(100) NOT NULL,
    PercentValue decimal(9,4) NOT NULL,
    ValidFrom date NULL,
    ValidTo date NULL,
    IsActive bit NOT NULL CONSTRAINT DF_CustomerExtraGroupDiscount_IsActive DEFAULT (1),
    CreatedBy nvarchar(200) NOT NULL,
    CreatedUtc datetime2(3) NOT NULL CONSTRAINT DF_CustomerExtraGroupDiscount_CreatedUtc DEFAULT (SYSUTCDATETIME()),
    UpdatedBy nvarchar(200) NULL,
    UpdatedUtc datetime2(3) NULL,
    CONSTRAINT PK_CustomerExtraGroupDiscount PRIMARY KEY (ExtraDiscountId),
    CONSTRAINT FK_CustomerExtraGroupDiscount_Customer FOREIGN KEY (CustomerId) REFERENCES b2b.Customer (CustomerId),
    CONSTRAINT CK_CustomerExtraGroupDiscount_Percent CHECK (PercentValue > 0 AND PercentValue <= 100),
    CONSTRAINT CK_CustomerExtraGroupDiscount_Dates CHECK (ValidFrom IS NULL OR ValidTo IS NULL OR ValidTo >= ValidFrom)
  );
  CREATE UNIQUE INDEX UX_CustomerExtraGroupDiscount_Active ON b2b.CustomerExtraGroupDiscount (CustomerId, ItemGroupCode) WHERE IsActive = 1;
END;

EXEC(N'CREATE OR ALTER PROCEDURE b2b.SaveCustomerExtraGroupDiscount
  @OrganizationId int,
  @CustomerId bigint,
  @ItemGroupCode nvarchar(100),
  @PercentValue decimal(9,4),
  @ValidFrom date = NULL,
  @ValidTo date = NULL,
  @ChangedBy nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  SET @ItemGroupCode = NULLIF(LTRIM(RTRIM(@ItemGroupCode)), N'''');
  IF @ItemGroupCode IS NULL THROW 52793, N''Skupina artiklov je obvezna.'', 1;
  IF @PercentValue IS NULL OR @PercentValue <= 0 OR @PercentValue > 100 THROW 52794, N''Dodatni popust mora biti nad 0 in najvec 100 %.'', 1;
  IF NOT EXISTS (SELECT 1 FROM b2b.Customer WHERE CustomerId = @CustomerId AND OrganizationId = @OrganizationId)
    THROW 52795, N''Stranka v tem podjetju ne obstaja.'', 1;

  BEGIN TRAN;
  DECLARE @old nvarchar(max) = (SELECT * FROM b2b.CustomerExtraGroupDiscount
    WHERE CustomerId = @CustomerId AND ItemGroupCode = @ItemGroupCode AND IsActive = 1 FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

  UPDATE b2b.CustomerExtraGroupDiscount SET IsActive = 0, UpdatedBy = @ChangedBy, UpdatedUtc = SYSUTCDATETIME()
  WHERE CustomerId = @CustomerId AND ItemGroupCode = @ItemGroupCode AND IsActive = 1;

  INSERT b2b.CustomerExtraGroupDiscount (OrganizationId, CustomerId, ItemGroupCode, PercentValue, ValidFrom, ValidTo, CreatedBy)
  VALUES (@OrganizationId, @CustomerId, @ItemGroupCode, @PercentValue, @ValidFrom, @ValidTo, @ChangedBy);

  INSERT b2b.AuditLog (OrganizationId, EntityType, EntityKey, ActionCode, OldValueJson, NewValueJson, ChangedBy)
  SELECT @OrganizationId, N''CustomerExtraGroupDiscount'', CONCAT(@CustomerId, N'':'', @ItemGroupCode), N''UPSERT'', @old,
    (SELECT * FROM b2b.CustomerExtraGroupDiscount WHERE ExtraDiscountId = SCOPE_IDENTITY() FOR JSON PATH, WITHOUT_ARRAY_WRAPPER), @ChangedBy;
  COMMIT;
END;');

EXEC(N'CREATE OR ALTER PROCEDURE b2b.RemoveCustomerExtraGroupDiscount
  @OrganizationId int,
  @CustomerId bigint,
  @ItemGroupCode nvarchar(100),
  @ChangedBy nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  BEGIN TRAN;
  DECLARE @old nvarchar(max) = (SELECT * FROM b2b.CustomerExtraGroupDiscount
    WHERE OrganizationId = @OrganizationId AND CustomerId = @CustomerId AND ItemGroupCode = @ItemGroupCode AND IsActive = 1
    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
  UPDATE b2b.CustomerExtraGroupDiscount SET IsActive = 0, UpdatedBy = @ChangedBy, UpdatedUtc = SYSUTCDATETIME()
  WHERE OrganizationId = @OrganizationId AND CustomerId = @CustomerId AND ItemGroupCode = @ItemGroupCode AND IsActive = 1;
  IF @@ROWCOUNT > 0
    INSERT b2b.AuditLog (OrganizationId, EntityType, EntityKey, ActionCode, OldValueJson, NewValueJson, ChangedBy)
    VALUES (@OrganizationId, N''CustomerExtraGroupDiscount'', CONCAT(@CustomerId, N'':'', @ItemGroupCode), N''REMOVE'', @old, NULL, @ChangedBy);
  COMMIT;
END;');

/* --- 5) Pravilo skupin popustov z dodatnim popustom -------------------------------------------- */
EXEC(N'CREATE OR ALTER FUNCTION b2b.CustomerGroupDiscounts (@Today date)
RETURNS TABLE
AS
RETURN
(
  WITH customerValue AS
  (
    SELECT customer.CustomerId, customer.OrganizationId, customer.CustomerKey, profile.CustomerTypeCode,
      OwnList = COALESCE(generalOverride.DiscountPriceListCode, customer.DiscountPriceListCode),
      PayerCode = NULLIF(COALESCE(generalOverride.PayerCode, customer.PayerCode), customer.CustomerKey),
      PayerKind = COALESCE(profile.PayerKind, CASE
        WHEN profile.CustomerTypeCode LIKE N''%[_]BRANCH%'' THEN N''PE''
        WHEN profile.CustomerTypeCode LIKE N''%[_]TRANSIT%'' THEN N''TRANZIT'' END)
    FROM b2b.Customer AS customer
    LEFT JOIN pim.CustomerGeneralOverride AS generalOverride
      ON generalOverride.OrganizationId = customer.OrganizationId AND generalOverride.CustomerId = customer.CustomerId
    LEFT JOIN pim.CustomerWebProfile AS profile ON profile.CustomerId = customer.CustomerId
  ),
  listValue AS
  (
    SELECT customerValue.*,
      SaopList = CASE customerValue.PayerKind
        WHEN N''TRANZIT'' THEN NULL
        WHEN N''PE'' THEN COALESCE(payerValue.DiscountList, customerValue.OwnList)
        ELSE customerValue.OwnList END,
      FromPayer = CONVERT(bit, CASE WHEN customerValue.PayerKind = N''PE'' AND payerValue.DiscountList IS NOT NULL THEN 1 ELSE 0 END)
    FROM customerValue
    /* (OrganizationId, CustomerKey) je enolicen, zato je placnik najvec eden. */
    LEFT JOIN
    (
      SELECT payer.OrganizationId, payer.CustomerKey, DiscountList = COALESCE(payerOverride.DiscountPriceListCode, payer.DiscountPriceListCode)
      FROM b2b.Customer AS payer
      LEFT JOIN pim.CustomerGeneralOverride AS payerOverride
        ON payerOverride.OrganizationId = payer.OrganizationId AND payerOverride.CustomerId = payer.CustomerId
    ) AS payerValue ON payerValue.OrganizationId = customerValue.OrganizationId AND payerValue.CustomerKey = customerValue.PayerCode
  ),
  candidates AS
  (
    SELECT listValue.CustomerId, groupRule.ItemGroupCode, groupRule.PercentValue, groupRule.ValidFrom, groupRule.ValidTo,
      Priority = CASE groupRule.TargetKind WHEN N''CUSTOMER'' THEN 1 ELSE 2 END, RuleId = groupRule.OverrideId,
      SourceKind = groupRule.TargetKind, SourceCode = COALESCE(groupRule.CustomerTypeCode, listValue.CustomerKey)
    FROM listValue
    INNER JOIN b2b.GroupDiscountOverride AS groupRule
      ON groupRule.OrganizationId = listValue.OrganizationId AND groupRule.IsActive = 1
     AND ((groupRule.TargetKind = N''CUSTOMER'' AND groupRule.CustomerId = listValue.CustomerId)
       OR (groupRule.TargetKind = N''TYPE'' AND groupRule.CustomerTypeCode = listValue.CustomerTypeCode))
    WHERE (groupRule.ValidFrom IS NULL OR groupRule.ValidFrom <= @Today)
      AND (groupRule.ValidTo IS NULL OR groupRule.ValidTo >= @Today)
    UNION ALL
    SELECT listValue.CustomerId, legacy.ItemGroupCode, legacy.PercentValue, legacy.ValidFrom, legacy.ValidTo,
      3, legacy.GroupDiscountId, N''ERP'', listValue.CustomerKey
    FROM listValue
    INNER JOIN b2b.GroupDiscount AS legacy ON legacy.CustomerId = listValue.CustomerId
    WHERE (legacy.ValidFrom IS NULL OR legacy.ValidFrom <= @Today)
      AND (legacy.ValidTo IS NULL OR legacy.ValidTo >= @Today)
    UNION ALL
    SELECT listValue.CustomerId, saop.ItemGroupCode, saop.DiscountPercent, saop.ValidFrom, saop.ValidTo,
      4, saop.CustomerItemGroupDiscountId, CASE WHEN listValue.FromPayer = 1 THEN N''SAOP_PAYER'' ELSE N''SAOP'' END,
      CASE WHEN listValue.FromPayer = 1 THEN listValue.PayerCode ELSE listValue.SaopList END
    FROM listValue
    /* HASH: brez namiga je optimizator pri spoju po izracunanem ceniku izbral zanko z zacasnim
       zapisom - 340.000 branj in 14 s za vse stranke; z namigom 90 ms (izmerjeno 2026-09-22). */
    INNER HASH JOIN b2b.CustomerItemGroupDiscount AS saop
      ON saop.OrganizationId = listValue.OrganizationId AND saop.CustomerGroupCode = listValue.SaopList
    WHERE saop.ValidFrom <= @Today AND (saop.ValidTo IS NULL OR saop.ValidTo >= @Today)
      AND saop.DiscountPercent IS NOT NULL AND ISNULL(saop.MinQuantity, 0) = 0
  ),
  ranked AS
  (
    SELECT candidates.*,
      PickRank = ROW_NUMBER() OVER (PARTITION BY candidates.CustomerId, candidates.ItemGroupCode
        ORDER BY candidates.Priority, candidates.ValidFrom DESC, candidates.RuleId DESC)
    FROM candidates
  ),
  base AS
  (
    SELECT ranked.CustomerId, ranked.ItemGroupCode, ranked.PercentValue, ranked.ValidFrom, ranked.ValidTo, ranked.SourceKind, ranked.SourceCode
    FROM ranked WHERE ranked.PickRank = 1
  ),
  /* 279: dodatni popust stranke (P2) - obracuna se ZA osnovnim, kot drugi popust v SAOP. */
  extra AS
  (
    SELECT extraRule.CustomerId, extraRule.ItemGroupCode, extraRule.PercentValue, extraRule.ValidFrom, extraRule.ValidTo
    FROM b2b.CustomerExtraGroupDiscount AS extraRule
    WHERE extraRule.IsActive = 1
      AND (extraRule.ValidFrom IS NULL OR extraRule.ValidFrom <= @Today)
      AND (extraRule.ValidTo IS NULL OR extraRule.ValidTo >= @Today)
  ),
  combined AS
  (
    SELECT CustomerId = COALESCE(base.CustomerId, extra.CustomerId),
      ItemGroupCode = COALESCE(base.ItemGroupCode, extra.ItemGroupCode),
      PercentValue = CONVERT(decimal(9,4), CASE
        WHEN extra.PercentValue IS NULL THEN base.PercentValue
        ELSE 100 - (100 - ISNULL(base.PercentValue, 0)) * (100 - extra.PercentValue) / 100 END),
      ValidFrom = CASE WHEN base.CustomerId IS NULL THEN extra.ValidFrom ELSE base.ValidFrom END,
      ValidTo = CASE WHEN base.CustomerId IS NULL THEN extra.ValidTo ELSE base.ValidTo END,
      SourceKind = CASE WHEN base.CustomerId IS NULL OR base.PercentValue <= 0 THEN N''EXTRA'' ELSE base.SourceKind END,
      SourceCode = CASE WHEN base.CustomerId IS NULL OR base.PercentValue <= 0 THEN NULL ELSE base.SourceCode END,
      BasePercent = CASE WHEN base.PercentValue > 0 THEN base.PercentValue END,
      ExtraPercent = extra.PercentValue
    FROM base
    FULL OUTER JOIN extra ON extra.CustomerId = base.CustomerId AND extra.ItemGroupCode = base.ItemGroupCode
  )
  SELECT combined.CustomerId, combined.ItemGroupCode, combined.PercentValue, combined.ValidFrom, combined.ValidTo,
    combined.SourceKind, combined.SourceCode, combined.BasePercent, combined.ExtraPercent
  FROM combined
  WHERE combined.PercentValue > 0
);');

/* Kartica stranke, nabor 2: vir pove tudi dodatni popust. */
SET @definition = OBJECT_DEFINITION(OBJECT_ID(N'intranet.GetCustomerCard'));
IF @definition IS NULL THROW 52796, N'279: intranet.GetCustomerCard ne obstaja.', 1;
IF @definition NOT LIKE N'%/* ExtraGroup279 */%'
BEGIN
  DECLARE @cardOld nvarchar(400) = N'ELSE N''SAOP, rabatni cenik '' + effective.SourceCode END';
  IF CHARINDEX(@cardOld, @definition) = 0 THROW 52797, N'279: intranet.GetCustomerCard nima pricakovanega vira popusta (253).', 1;
  SET @definition = REPLACE(@definition, N'WHEN N''SAOP_PAYER'' THEN', N'WHEN N''EXTRA'' THEN N''dodatni popust stranke''
      WHEN N''SAOP_PAYER'' THEN');
  SET @definition = REPLACE(@definition, @cardOld, @cardOld + N' /* ExtraGroup279 */
      + CASE WHEN effective.ExtraPercent IS NOT NULL AND effective.SourceKind <> N''EXTRA''
          THEN N'' + dodatni '' + FORMAT(effective.ExtraPercent, N''0.##'') + N'' %'' ELSE N'''' END');
  SET @definition = N'ALTER ' + SUBSTRING(@definition, CHARINDEX(N'PROCEDURE', @definition), 2147483647);
  EXEC sys.sp_executesql @definition;
END;

/* --- 6) Dodatna polja seznama strank ------------------------------------------------------------ */
EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetCustomerListExtra
  @OrganizationId int = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SELECT customer.CustomerId, customer.SalesClerkCode, SalesClerkName = clerk.Name,
    extraValue.AccountManager, extraValue.DeliveryNoteEmail, extraValue.NoticeEmail, extraValue.NoticePerson,
    ExtraGroupDiscounts = (SELECT STRING_AGG(CONVERT(nvarchar(max), extraRule.ItemGroupCode + N''='' + FORMAT(extraRule.PercentValue, N''0.####'', ''en-US'')), N'' | '')
                             WITHIN GROUP (ORDER BY extraRule.ItemGroupCode)
                           FROM b2b.CustomerExtraGroupDiscount AS extraRule
                           WHERE extraRule.CustomerId = customer.CustomerId AND extraRule.IsActive = 1),
    Notes = (SELECT STRING_AGG(CONVERT(nvarchar(max), FORMAT(note.CreatedUtc, N''d. M. yyyy'') + N'': '' + note.Body), NCHAR(10))
               WITHIN GROUP (ORDER BY note.CreatedUtc DESC)
             FROM pim.CustomerNote AS note WHERE note.CustomerId = customer.CustomerId AND note.OrganizationId = customer.OrganizationId)
  FROM b2b.Customer AS customer
  LEFT JOIN pim.SalesClerk AS clerk ON clerk.OrganizationId = customer.OrganizationId AND clerk.SalesClerkCode = customer.SalesClerkCode
  LEFT JOIN pim.CustomerExtra AS extraValue ON extraValue.CustomerId = customer.CustomerId
  WHERE (@OrganizationId IS NULL OR customer.OrganizationId = @OrganizationId)
    AND (customer.SalesClerkCode IS NOT NULL OR extraValue.CustomerId IS NOT NULL
      OR EXISTS (SELECT 1 FROM b2b.CustomerExtraGroupDiscount AS extraRule WHERE extraRule.CustomerId = customer.CustomerId AND extraRule.IsActive = 1)
      OR EXISTS (SELECT 1 FROM pim.CustomerNote AS note WHERE note.CustomerId = customer.CustomerId));
END;');

/* --- 7) Preverjanje ------------------------------------------------------------------------------ */
IF OBJECT_DEFINITION(OBJECT_ID(N'map.ProcessCustomerInbox')) NOT LIKE N'%SalesClerkCode=ISNULL(source.SalesClerkCode%'
  THROW 52798, N'279: zajem strank ne pise referenta.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'b2b.CustomerGroupDiscounts')) NOT LIKE N'%CustomerExtraGroupDiscount%'
  THROW 52799, N'279: pravilo skupin popustov ne pozna dodatnega popusta.', 1;
