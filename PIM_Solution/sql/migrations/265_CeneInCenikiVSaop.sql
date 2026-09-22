/*
  265 — cene in ceniki gredo iz PIM v SAOP.

  Uporabnik 2026-09-22: cene iz SAOP zdaj prihajajo redno in zanesljivo; stran Cene naj ima izvoz
  in uvoz kot Izdelki in Stranke, cene naj gredo v SAOP, prav tako novi ceniki.

  Oblike dokumentov (out.SaopDocument, 085) in pogodba polj (out.SaopXmlField, 081) za SAOP_PRICE in
  SAOP_PRICELIST obstajajo od avgusta, pošiljatelj pa jih ni uporabljal: lastništvo polj je bilo SAOP,
  profila integracije ni bilo in prevzem iz vrste (out.ClaimItemDocument) pozna samo artikle.

  SAOP za cene in cenike PATCH-a nima (swagger v2): nova cena gre s POST api/Price/AddPrices, sprememba
  s POST api/V2/Price/ModifyPricesV2, cenik s POST api/pricelists/AddPriceLists oziroma ModifyPriceLists.
  Kaj od obojega, odloči out.SaopEntityExists (cena ali cenik je v zajemu ali pa ga je PIM že uspešno
  poslal); ob zavrnitvi »že obstaja / ne obstaja« pošiljatelj takoj poskusi z drugo potjo (kot pri artiklih).

  Kaj naredi:
    1. dbo.IntegrationProfile SAOP_PRICE in SAOP_PRICELIST za vsako podjetje s profilom artiklov,
       z ročno odobritvijo (ManualApproval) — nič ne odide brez klika »Odobri in pošlji«.
    2. out.OwnershipPolicy: polja cene in glave cenika so odslej v lasti PIM; nov element VatIncluded.
    3. out.SaopEntityExists, out.ClaimSaopDocument (prevzem cene/cenika; cena za nov cenik počaka,
       da cenik odide), out.PeekItemDocuments (suhi tek pozna obstoj cen in cenikov).
    4. out.EnqueueSaopPriceChanges (množično: ena vrstica = ena cena) in out.EnqueueSaopPriceList.

  Stari posamični pošiljatelj (out.ClaimMessage, PIM.OutboxDispatcher brez --saop-documents) bi
  prevzel tudi cene; posel je v avtomatiki izklopljen in cene pošilja samo intranet po dokumentu.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

IF NOT EXISTS (SELECT 1 FROM out.SaopDocument WHERE TargetKind = N'SAOP_PRICE' AND IsEnabled = 1
                 AND AddPath = N'api/Price/AddPrices' AND UpdatePath = N'api/V2/Price/ModifyPricesV2')
   OR NOT EXISTS (SELECT 1 FROM out.SaopDocument WHERE TargetKind = N'SAOP_PRICELIST' AND IsEnabled = 1
                 AND AddPath = N'api/pricelists/AddPriceLists' AND UpdatePath = N'api/pricelists/ModifyPriceLists')
  THROW 52639, N'265: out.SaopDocument nima pricakovanih oblik za SAOP_PRICE/SAOP_PRICELIST (085).', 1;

/* --- 1. pogodba glave cenika: VatIncluded, naziv obvezen ob ustvarjanju --------------------- */
IF NOT EXISTS (SELECT 1 FROM out.SaopXmlField WHERE TargetKind = N'SAOP_PRICELIST' AND Section = N'Item' AND ElementName = N'VatIncluded')
  INSERT out.SaopXmlField(TargetKind, Section, ElementName, FieldKey, SortOrder, IsAddMandatory, ValueFormat, TrueValue, FalseValue, IsEnabled, UpdatedBy)
  VALUES (N'SAOP_PRICELIST', N'Item', N'VatIncluded', N'PriceList.VatIncluded', 35, 0, N'bool', N'true', N'false', 1, N'migracija 265');

UPDATE out.SaopXmlField SET IsAddMandatory = 1, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = N'migracija 265'
WHERE TargetKind = N'SAOP_PRICELIST' AND FieldKey = N'PriceList.PriceListDescription' AND IsAddMandatory = 0;

/* --- 2. profila integracije, kopija naslova iz profila artiklov ----------------------------- */
INSERT dbo.IntegrationProfile(OrganizationId, TargetKind, EndpointTemplate, HttpOperation, ApprovalMode, IsEnabled,
  TimeoutSeconds, MaxAttempts, BaseRetrySeconds, UpdatedBy, AddPath, UpdatePath)
SELECT product.OrganizationId, document.TargetKind, product.EndpointTemplate, N'POST', N'ManualApproval', product.IsEnabled,
  product.TimeoutSeconds, product.MaxAttempts, product.BaseRetrySeconds, N'migracija 265', document.AddPath, document.UpdatePath
FROM dbo.IntegrationProfile AS product
CROSS JOIN out.SaopDocument AS document
WHERE product.TargetKind = N'SAOP_PRODUCT' AND document.TargetKind IN (N'SAOP_PRICE', N'SAOP_PRICELIST')
  AND NOT EXISTS (SELECT 1 FROM dbo.IntegrationProfile AS existing
    WHERE existing.OrganizationId = product.OrganizationId AND existing.TargetKind = document.TargetKind);

/* --- 3. lastništvo: cene in glave cenikov piše PIM ------------------------------------------ */
INSERT out.OwnershipPolicy(OrganizationId, TargetKind, EntityType, FieldName, Owner, ConstraintKind, ConstraintValue, IsEnabled, UpdatedBy)
SELECT organization.OrganizationId, N'SAOP_PRICELIST', N'PriceList', N'PriceList.VatIncluded', N'PIM', NULL, NULL, 1, N'migracija 265'
FROM (SELECT DISTINCT OrganizationId FROM out.OwnershipPolicy WHERE TargetKind = N'SAOP_PRICELIST') AS organization
WHERE NOT EXISTS (SELECT 1 FROM out.OwnershipPolicy AS existing
  WHERE existing.OrganizationId = organization.OrganizationId AND existing.TargetKind = N'SAOP_PRICELIST'
    AND existing.FieldName = N'PriceList.VatIncluded');

UPDATE out.OwnershipPolicy
SET Owner = N'PIM', UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = N'migracija 265'
WHERE TargetKind IN (N'SAOP_PRICE', N'SAOP_PRICELIST') AND Owner = N'SAOP' AND ConstraintKind IS NULL;

/* --- exists ------------------------------------------------------------ */
EXEC(N'CREATE OR ALTER FUNCTION out.SaopEntityExists (@OrganizationId int, @TargetKind nvarchar(100), @EntityKey nvarchar(450))
RETURNS bit
AS
BEGIN
  /* 265: ali SAOP zapis ze pozna - od tega je odvisno, ali gre dokument kot nov (Add) ali kot sprememba.
     Cenik ali cena, ki ju je PIM uspesno poslal, obstajata, se preden ju prinese naslednji zajem. */
  IF @TargetKind = N''SAOP_PRODUCT''
    RETURN CASE WHEN EXISTS (SELECT 1 FROM canon.Product WHERE OrganizationId = @OrganizationId
      AND ItemID = @EntityKey AND ErpExistence = N''CONFIRMED_IN_ERP'') THEN 1 ELSE 0 END;

  IF @TargetKind = N''SAOP_PRICELIST''
    RETURN CASE WHEN EXISTS (SELECT 1 FROM canon.Codebook WHERE OrganizationId = @OrganizationId
        AND CodebookCode = N''PRICELIST'' AND EntryCode = @EntityKey)
      OR EXISTS (SELECT 1 FROM out.OutboxMessage WHERE OrganizationId = @OrganizationId
        AND TargetKind = N''SAOP_PRICELIST'' AND EntityKey = @EntityKey AND SentUtc IS NOT NULL
        AND Status IN (N''Sent'', N''Verified'', N''Superseded''))
      THEN 1 ELSE 0 END;

  DECLARE @Split int = CHARINDEX(N''|'', @EntityKey);
  IF @TargetKind = N''SAOP_PRICE'' AND @Split > 1
    RETURN CASE WHEN EXISTS (SELECT 1 FROM canon.ProductPrice AS price
        INNER JOIN canon.Product AS product ON product.ProductId = price.ProductId
        WHERE product.OrganizationId = @OrganizationId
          AND product.ItemID = SUBSTRING(@EntityKey, @Split + 1, 450)
          AND price.PriceList = LEFT(@EntityKey, @Split - 1))
      OR EXISTS (SELECT 1 FROM out.OutboxMessage WHERE OrganizationId = @OrganizationId
        AND TargetKind = N''SAOP_PRICE'' AND EntityKey = @EntityKey AND SentUtc IS NOT NULL
        AND Status IN (N''Sent'', N''Verified'', N''Superseded''))
      THEN 1 ELSE 0 END;

  RETURN 0;
END;');

/* --- claim ------------------------------------------------------------ */
EXEC(N'CREATE OR ALTER PROCEDURE out.ClaimSaopDocument
  @WorkerId nvarchar(200), @LeaseSeconds int = 90, @TargetKind nvarchar(100),
  @OrganizationId int = NULL, @EntityKey nvarchar(450) = NULL
AS
BEGIN
  /* 265: prevzem enega dokumenta cene ali cenika. Izid ima isto obliko kot out.ClaimItemDocument
     (glava, spremembe, privzetki), da ga PIM.Outbound.SaopDocumentRunner bere po isti poti.
     Cena za cenik, ki ga SAOP se ne pozna, pocaka: najprej mora oditi cenik (AddPriceLists),
     sicer SAOP ceno zavrne. */
  SET NOCOUNT ON; SET XACT_ABORT ON;
  IF @TargetKind NOT IN (N''SAOP_PRICE'', N''SAOP_PRICELIST'')
    THROW 52650, N''265: out.ClaimSaopDocument prevzema samo cene in cenike; izdelki gredo prek out.ClaimItemDocument.'', 1;

  DECLARE @EntityType nvarchar(100) = CASE @TargetKind WHEN N''SAOP_PRICE'' THEN N''Price'' ELSE N''PriceList'' END;
  DECLARE @Org int, @Key nvarchar(450);

  BEGIN TRAN;

  SELECT TOP(1) @Org = message.OrganizationId, @Key = message.EntityKey
  FROM out.OutboxMessage AS message WITH (UPDLOCK, READPAST, ROWLOCK)
  INNER JOIN dbo.IntegrationProfile AS profile
    ON profile.OrganizationId = message.OrganizationId AND profile.TargetKind = message.TargetKind AND profile.IsEnabled = 1
  WHERE message.TargetKind = @TargetKind AND message.EntityType = @EntityType
    AND (@OrganizationId IS NULL OR message.OrganizationId = @OrganizationId)
    AND (@EntityKey IS NULL OR message.EntityKey = @EntityKey)
    AND message.Status IN (N''Pending'', N''Retry'', N''Sending'')
    AND (message.NextAttemptUtc IS NULL OR message.NextAttemptUtc <= SYSUTCDATETIME())
    AND (message.LeaseUntilUtc IS NULL OR message.LeaseUntilUtc < SYSUTCDATETIME())
    AND (@TargetKind = N''SAOP_PRICELIST''
      OR out.SaopEntityExists(message.OrganizationId, N''SAOP_PRICELIST'',
           CASE WHEN CHARINDEX(N''|'', message.EntityKey) > 1 THEN LEFT(message.EntityKey, CHARINDEX(N''|'', message.EntityKey) - 1) ELSE N'''' END) = 1)
  ORDER BY message.OutboxMessageId;

  IF @Key IS NULL BEGIN COMMIT; RETURN; END;

  DECLARE @Claimed TABLE(OutboxMessageId bigint PRIMARY KEY);

  UPDATE message
  SET Status = N''Sending'', AttemptCount = message.AttemptCount + 1,
      LeaseOwner = @WorkerId, LeaseUntilUtc = DATEADD(second, @LeaseSeconds, SYSUTCDATETIME()),
      UpdatedUtc = SYSUTCDATETIME()
  OUTPUT inserted.OutboxMessageId INTO @Claimed
  FROM out.OutboxMessage AS message WITH (UPDLOCK, ROWLOCK)
  WHERE message.OrganizationId = @Org AND message.EntityKey = @Key
    AND message.TargetKind = @TargetKind AND message.EntityType = @EntityType
    AND message.Status IN (N''Pending'', N''Retry'', N''Sending'')
    AND (message.NextAttemptUtc IS NULL OR message.NextAttemptUtc <= SYSUTCDATETIME())
    AND (message.LeaseUntilUtc IS NULL OR message.LeaseUntilUtc < SYSUTCDATETIME());

  INSERT out.OutboxAttempt(OutboxMessageId, AttemptNumber, WorkerId)
  SELECT message.OutboxMessageId, message.AttemptCount, @WorkerId
  FROM out.OutboxMessage AS message INNER JOIN @Claimed AS claimed ON claimed.OutboxMessageId = message.OutboxMessageId;

  SELECT
    OrganizationId = @Org,
    ItemID = @Key,
    BaseUrl = profile.EndpointTemplate,
    AddPath = ISNULL(profile.AddPath, document.AddPath),
    UpdatePath = ISNULL(profile.UpdatePath, document.UpdatePath),
    profile.TimeoutSeconds,
    profile.MaxAttempts,
    ExistsInSaop = out.SaopEntityExists(@Org, @TargetKind, @Key),
    LastErrorKind =
    (
      SELECT TOP(1) message.SaopErrorKind FROM out.OutboxMessage AS message
      INNER JOIN @Claimed AS claimed ON claimed.OutboxMessageId = message.OutboxMessageId
      WHERE message.SaopErrorKind IS NOT NULL ORDER BY message.OutboxMessageId DESC
    ),
    SourceKey = N''*''
  FROM dbo.IntegrationProfile AS profile
  INNER JOIN out.SaopDocument AS document ON document.TargetKind = profile.TargetKind
  WHERE profile.OrganizationId = @Org AND profile.TargetKind = @TargetKind;

  SELECT message.OutboxMessageId, FieldKey = message.FieldSummary,
    Value = JSON_VALUE(message.PayloadJson, N''$.value''),
    message.AttemptCount, message.OutboundBatchId
  FROM out.OutboxMessage AS message
  INNER JOIN @Claimed AS claimed ON claimed.OutboxMessageId = message.OutboxMessageId
  ORDER BY message.OutboxMessageId;

  /* Privzetkov za cene in cenike ni: out.SaopAddDefault je napisan za artikle in bi se po imenu
     elementa (Item/Active) lahko prijel tudi cene. Vse vrednosti nosi sporocilo samo. */
  SELECT Section = CONVERT(nvarchar(50), NULL), ElementName = CONVERT(nvarchar(100), NULL), Value = CONVERT(nvarchar(400), NULL)
  WHERE 1 = 0;

  COMMIT;
END;');

/* --- peek ------------------------------------------------------------ */
EXEC(N'CREATE OR ALTER PROCEDURE out.PeekItemDocuments
  @OrganizationId int = NULL, @TargetKind nvarchar(100) = N''SAOP_PRODUCT'', @Top int = 50
AS
BEGIN
  SET NOCOUNT ON;

  /* Dokumenti, ki bi bili prevzeti ob naslednjem zagonu, po istem merilu kot prevzem -
     brez pogoja o omogocenem profilu, ker je suhi tek namenjen prav preverjanju PRED tem,
     da se profil omogoci. 265: obstoj v SAOP po out.SaopEntityExists, da suhi tek cen in
     cenikov pokaze pravo metodo (Add/Modify). */
  ;WITH pripravljeni AS
  (
    SELECT message.OrganizationId, message.EntityKey,
      Sporocil = COUNT(*),
      Najstarejse = MIN(message.OutboxMessageId),
      Poskusov = MAX(message.AttemptCount),
      ZadnjaNapaka = MAX(message.SaopErrorKind)
    FROM out.OutboxMessage AS message
    WHERE message.TargetKind = @TargetKind
      AND (@OrganizationId IS NULL OR message.OrganizationId = @OrganizationId)
      AND message.Status IN (N''Pending'', N''Retry'')
      AND (message.NextAttemptUtc IS NULL OR message.NextAttemptUtc <= SYSUTCDATETIME())
    GROUP BY message.OrganizationId, message.EntityKey
  )
  SELECT TOP(@Top) pripravljeni.OrganizationId, pripravljeni.EntityKey, pripravljeni.Sporocil,
    pripravljeni.Poskusov, pripravljeni.ZadnjaNapaka,
    ExistsInSaop = out.SaopEntityExists(pripravljeni.OrganizationId, @TargetKind, pripravljeni.EntityKey),
    SourceKey = CASE WHEN @TargetKind = N''SAOP_PRODUCT'' AND CHARINDEX(N''.'', pripravljeni.EntityKey) > 1
      THEN UPPER(LEFT(pripravljeni.EntityKey, CHARINDEX(N''.'', pripravljeni.EntityKey) - 1)) ELSE N''*'' END
  FROM pripravljeni
  ORDER BY pripravljeni.Najstarejse;
END;');

/* --- enqueue_prices ------------------------------------------------------------ */
EXEC(N'CREATE OR ALTER PROCEDURE out.EnqueueSaopPriceChanges
  @OrganizationId int, @ChangesJson nvarchar(max), @Actor nvarchar(200),
  @Source nvarchar(30) = N''BULK'', @Note nvarchar(400) = NULL,
  @OutboundBatchId bigint = NULL OUTPUT
AS
BEGIN
  /* 265: cene v odhodno vrsto za SAOP - ena vrstica vhoda je ena cena (cenik + artikel). Vir: EXCEL (uvoz), CARD (ena cena), BULK.
     Vhod: [{"priceList","itemId","net","vatRate","validFrom","active"}], stevila z decimalno piko,
     datum yyyy-MM-dd, active true/false; prazno = ne spreminjaj (pri novi ceni: DDV brez, velja od danes, aktivna).

     Sporocilo je eno polje ene cene, kot pri artiklih (out.EnqueueMessage): isti kanonicni JSON,
     isti hash, isti dedup in ista zamenjava starejsih sporocil za isto polje. Tu je vse naenkrat
     (mnozicno), ker ima cenik lahko 80.000 cen in zanka po polju bi tekla minute.
     Cena gre vedno cela (neto, DDV, aktivnost): ModifyPricesV2 je POST s celim ItemPrice. */
  SET NOCOUNT ON; SET XACT_ABORT ON;
  IF NULLIF(LTRIM(RTRIM(@Actor)), N'''') IS NULL THROW 52651, N''Akter je obvezen.'', 1;
  IF ISJSON(@ChangesJson) <> 1 THROW 52652, N''Seznam cen ni veljaven JSON.'', 1;

  DECLARE @Status nvarchar(30) =
  (
    SELECT CASE WHEN ApprovalMode = N''Automatic'' THEN N''Pending'' ELSE N''PendingApproval'' END
    FROM dbo.IntegrationProfile WHERE OrganizationId = @OrganizationId AND TargetKind = N''SAOP_PRICE'' AND IsEnabled = 1
  );
  IF @Status IS NULL THROW 52653, N''Pošiljanje cen v SAOP za to podjetje ni omogočeno (dbo.IntegrationProfile SAOP_PRICE).'', 1;

  IF EXISTS
  (
    SELECT 1 FROM (VALUES (N''Price.Net''), (N''Price.VatRate''), (N''Price.Active''), (N''Price.ValidFrom'')) AS field (FieldName)
    WHERE NOT EXISTS (SELECT 1 FROM out.OwnershipPolicy AS policy
      WHERE policy.OrganizationId = @OrganizationId AND policy.TargetKind = N''SAOP_PRICE'' AND policy.EntityType = N''Price''
        AND policy.FieldName = field.FieldName AND policy.Owner = N''PIM'' AND policy.IsEnabled = 1 AND policy.ConstraintKind IS NULL)
  ) THROW 52654, N''Polja cene niso v lasti PIM (out.OwnershipPolicy); cene se ne smejo pošiljati v SAOP.'', 1;

  CREATE TABLE #Vhod
  (
    Zaporedna int NOT NULL PRIMARY KEY,
    PriceList nvarchar(100) COLLATE DATABASE_DEFAULT NULL, ItemID nvarchar(400) COLLATE DATABASE_DEFAULT NULL,
    NetText nvarchar(100) COLLATE DATABASE_DEFAULT NULL, VatText nvarchar(100) COLLATE DATABASE_DEFAULT NULL, ValidFromText nvarchar(100) COLLATE DATABASE_DEFAULT NULL, ActiveText nvarchar(20) COLLATE DATABASE_DEFAULT NULL,
    Net decimal(19,4) NULL, VatRate decimal(5,2) NULL, ValidFrom date NULL, Active bit NULL,
    ProductId bigint NULL, HasCurrent bit NOT NULL DEFAULT 0,
    CurrentNet decimal(19,4) NULL, CurrentVat decimal(5,2) NULL, CurrentFrom datetime2(3) NULL, CurrentActive bit NULL,
    HasOpen bit NOT NULL DEFAULT 0,
    Status nvarchar(20) COLLATE DATABASE_DEFAULT NULL, Reason nvarchar(400) COLLATE DATABASE_DEFAULT NULL,
    EntityKey AS (CONVERT(nvarchar(450), PriceList + N''|'' + ItemID))
  );

  INSERT #Vhod(Zaporedna, PriceList, ItemID, NetText, VatText, ValidFromText, ActiveText)
  SELECT CONVERT(int, row.[key]) + 1,
    NULLIF(LTRIM(RTRIM(value.priceList)), N''''), NULLIF(LTRIM(RTRIM(value.itemId)), N''''),
    NULLIF(LTRIM(RTRIM(value.net)), N''''), NULLIF(LTRIM(RTRIM(value.vatRate)), N''''),
    NULLIF(LTRIM(RTRIM(value.validFrom)), N''''), NULLIF(LTRIM(RTRIM(value.active)), N'''')
  FROM OPENJSON(@ChangesJson) AS row
  CROSS APPLY OPENJSON(row.value) WITH
  (
    priceList nvarchar(100) N''$.priceList'', itemId nvarchar(400) N''$.itemId'', net nvarchar(100) N''$.net'',
    vatRate nvarchar(100) N''$.vatRate'', validFrom nvarchar(100) N''$.validFrom'', active nvarchar(20) N''$.active''
  ) AS value;

  IF NOT EXISTS (SELECT 1 FROM #Vhod) THROW 52655, N''Seznam cen je prazen.'', 1;

  UPDATE #Vhod SET
    Net = TRY_CONVERT(decimal(19,4), NetText),
    VatRate = TRY_CONVERT(decimal(5,2), VatText),
    ValidFrom = TRY_CONVERT(date, ValidFromText, 23),
    Active = CASE WHEN ActiveText IN (N''true'', N''1'', N''D'', N''DA'') THEN 1 WHEN ActiveText IN (N''false'', N''0'', N''N'', N''NE'') THEN 0 END;

  UPDATE #Vhod SET Status = N''Rejected'', Reason = N''Manjka cenik ali šifra artikla.''
  WHERE PriceList IS NULL OR ItemID IS NULL;
  UPDATE #Vhod SET Status = N''Rejected'', Reason = N''Cenik ali šifra vsebuje znak |, ki ga ključ cene ne dopušča.''
  WHERE Status IS NULL AND (CHARINDEX(N''|'', PriceList) > 0 OR CHARINDEX(N''|'', ItemID) > 0);
  UPDATE #Vhod SET Status = N''Rejected'', Reason = CONCAT(N''Cena »'', NetText, N''« ni število, večje ali enako 0.'')
  WHERE Status IS NULL AND (Net IS NULL OR Net < 0);
  UPDATE #Vhod SET Status = N''Rejected'', Reason = CONCAT(N''DDV »'', VatText, N''« ni odstotek med 0 in 100.'')
  WHERE Status IS NULL AND VatText IS NOT NULL AND (VatRate IS NULL OR VatRate < 0 OR VatRate > 100);
  UPDATE #Vhod SET Status = N''Rejected'', Reason = CONCAT(N''Datum »'', ValidFromText, N''« ni datum (yyyy-MM-dd).'')
  WHERE Status IS NULL AND ValidFromText IS NOT NULL AND ValidFrom IS NULL;
  UPDATE #Vhod SET Status = N''Rejected'', Reason = CONCAT(N''Aktivnost »'', ActiveText, N''« ni D ali N.'')
  WHERE Status IS NULL AND ActiveText IS NOT NULL AND Active IS NULL;

  /* Podvojena cena v istem vhodu: velja prva, druge so zavrnjene - sicer bi odlocal vrstni red posiljanja. */
  ;WITH podvojene AS
  (
    SELECT Status, Reason, zaporedje = ROW_NUMBER() OVER (PARTITION BY PriceList, ItemID ORDER BY Zaporedna)
    FROM #Vhod WHERE Status IS NULL
  )
  UPDATE podvojene SET Status = N''Rejected'', Reason = N''Ista cena (cenik in artikel) je v vhodu že višje; ta vrstica je izpuščena.''
  WHERE zaporedje > 1;

  /* Cenik mora obstajati v SAOP ali cakati v vrsti (nov cenik gre pred svojimi cenami). */
  UPDATE vhod SET Status = N''Rejected'', Reason = CONCAT(N''Cenika '', vhod.PriceList, N'' ni v SAOP in ne čaka v vrsti. Najprej ga dodaj na zavihku Ceniki.'')
  FROM #Vhod AS vhod
  WHERE vhod.Status IS NULL
    AND out.SaopEntityExists(@OrganizationId, N''SAOP_PRICELIST'', vhod.PriceList) = 0
    AND NOT EXISTS (SELECT 1 FROM out.OutboxMessage AS message
      WHERE message.OrganizationId = @OrganizationId AND message.TargetKind = N''SAOP_PRICELIST''
        AND message.EntityKey = vhod.PriceList
        AND message.Status IN (N''PendingApproval'', N''Pending'', N''Sending'', N''Retry'', N''Sent''));

  UPDATE vhod SET ProductId = product.ProductId
  FROM #Vhod AS vhod
  INNER JOIN canon.Product AS product ON product.OrganizationId = @OrganizationId AND product.ItemID = vhod.ItemID
  WHERE vhod.Status IS NULL;

  UPDATE #Vhod SET Status = N''Rejected'', Reason = CONCAT(N''Artikla '', ItemID, N'' v tem podjetju ni.'')
  WHERE Status IS NULL AND ProductId IS NULL;

  UPDATE vhod SET HasCurrent = 1, CurrentNet = current_price.Net, CurrentVat = current_price.VatRate,
    CurrentFrom = current_price.ValidFrom, CurrentActive = current_price.IsActive
  FROM #Vhod AS vhod
  CROSS APPLY
  (
    SELECT TOP(1) price.Net, price.VatRate, price.ValidFrom, price.IsActive
    FROM canon.ProductPrice AS price
    WHERE price.ProductId = vhod.ProductId AND price.PriceList = vhod.PriceList
    ORDER BY price.ValidFrom DESC
  ) AS current_price
  WHERE vhod.Status IS NULL;

  UPDATE vhod SET HasOpen = 1
  FROM #Vhod AS vhod
  WHERE vhod.Status IS NULL AND EXISTS (SELECT 1 FROM out.OutboxMessage AS message
    WHERE message.OrganizationId = @OrganizationId AND message.TargetKind = N''SAOP_PRICE''
      AND message.EntityKey = vhod.EntityKey AND message.Status IN (N''PendingApproval'', N''Pending'', N''Retry''));

  /* Enaka kot v SAOP in nic odprtega v vrsti: ni kaj poslati. Ce v vrsti caka druga vrednost,
     gre tudi enaka vrednost - tako se ze uvrscena sprememba prekliče z vrnitvijo na staro ceno. */
  UPDATE #Vhod SET Status = N''Unchanged'', Reason = N''Cena je enaka kot v SAOP.''
  WHERE Status IS NULL AND HasCurrent = 1 AND HasOpen = 0 AND Net = CurrentNet
    AND (VatRate IS NULL OR VatRate = CurrentVat)
    AND (Active IS NULL OR Active = CurrentActive)
    AND (ValidFrom IS NULL OR ValidFrom = CONVERT(date, CurrentFrom));

  CREATE TABLE #Polje
  (
    Zaporedna int NOT NULL, EntityKey nvarchar(450) COLLATE DATABASE_DEFAULT NOT NULL, Qualifier nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL,
    FieldName nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL, Value nvarchar(400) COLLATE DATABASE_DEFAULT NOT NULL, Operation nvarchar(20) COLLATE DATABASE_DEFAULT NOT NULL,
    Payload nvarchar(max) COLLATE DATABASE_DEFAULT NULL, PayloadHash char(64) COLLATE DATABASE_DEFAULT NULL, IsDuplicate bit NOT NULL DEFAULT 0,
    PRIMARY KEY (Zaporedna, FieldName)
  );

  INSERT #Polje(Zaporedna, EntityKey, Qualifier, FieldName, Value, Operation)
  SELECT vhod.Zaporedna, vhod.EntityKey, vhod.PriceList, field.FieldName, field.Value,
    CASE WHEN vhod.HasCurrent = 1 THEN N''UPDATE'' ELSE N''ADD'' END
  FROM #Vhod AS vhod
  CROSS APPLY (VALUES
    (N''Price.Net'', CONVERT(nvarchar(400), vhod.Net)),
    (N''Price.VatRate'', CONVERT(nvarchar(400), COALESCE(vhod.VatRate, vhod.CurrentVat))),
    (N''Price.Active'', CASE COALESCE(vhod.Active, vhod.CurrentActive, CONVERT(bit, 1)) WHEN 1 THEN N''true'' ELSE N''false'' END),
    (N''Price.ValidFrom'', CASE
      WHEN vhod.ValidFrom IS NOT NULL THEN CONVERT(nvarchar(10), vhod.ValidFrom, 23) + N''T00:00:00''
      WHEN vhod.HasCurrent = 0 THEN CONVERT(nvarchar(10), CONVERT(date, SYSDATETIME()), 23) + N''T00:00:00'' END)
  ) AS field (FieldName, Value)
  WHERE vhod.Status IS NULL AND field.Value IS NOT NULL;

  /* Kanonicni JSON in hash natanko kot out.EnqueueMessage, da dedup in zamenjava veljata cez obe poti. */
  UPDATE #Polje SET Payload =
    (SELECT EntityKey AS [entityKey], FieldName AS [field], Value AS [value], Qualifier AS [qualifier] FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
  UPDATE #Polje SET PayloadHash = CONVERT(char(64), HASHBYTES(''SHA2_256'', CONVERT(varbinary(max), Payload)), 2);

  /* Cena je en dokument: gre cela ali nic. Dvojnik je samo cena, katere VSA polja z isto vrednostjo
     ze cakajo v vrsti (neodposlana). Sicer se vsa starejsa sporocila te cene - tudi tista v drugih,
     se neodobrenih serijah - zamenjajo z novim celim naborom; brez tega bi lahko odsel dokument z
     aktivnostjo in DDV, a brez cene (dvojnik v stari seriji, neto v novi). */
  UPDATE polje SET IsDuplicate = 1
  FROM #Polje AS polje
  WHERE EXISTS (SELECT 1 FROM out.OutboxMessage AS message
    WHERE message.OrganizationId = @OrganizationId AND message.DedupKey = polje.PayloadHash
      AND message.Status IN (N''PendingApproval'', N''Pending'', N''Retry''));

  UPDATE polje SET IsDuplicate = 0
  FROM #Polje AS polje
  WHERE EXISTS (SELECT 1 FROM #Polje AS sosed WHERE sosed.Zaporedna = polje.Zaporedna AND sosed.IsDuplicate = 0);

  /* Cena, ki jo pošiljatelj ravno pošilja, se ne sme zamenjati pod njegovimi rokami. */
  UPDATE vhod SET Status = N''Rejected'', Reason = N''Ta cena se ravno pošilja v SAOP; ponovi čez minuto.''
  FROM #Vhod AS vhod
  WHERE vhod.Status IS NULL AND EXISTS (SELECT 1 FROM out.OutboxMessage AS message
    WHERE message.OrganizationId = @OrganizationId AND message.TargetKind = N''SAOP_PRICE''
      AND message.EntityKey = vhod.EntityKey AND message.Status = N''Sending'');
  DELETE polje FROM #Polje AS polje
  WHERE EXISTS (SELECT 1 FROM #Vhod AS vhod WHERE vhod.Zaporedna = polje.Zaporedna AND vhod.Status = N''Rejected'');

  UPDATE vhod SET Status = CASE WHEN EXISTS (SELECT 1 FROM #Polje AS polje WHERE polje.Zaporedna = vhod.Zaporedna AND polje.IsDuplicate = 0)
    THEN N''Queued'' ELSE N''Duplicate'' END,
    Reason = CASE WHEN EXISTS (SELECT 1 FROM #Polje AS polje WHERE polje.Zaporedna = vhod.Zaporedna AND polje.IsDuplicate = 0)
      THEN NULL ELSE N''Enaka cena že čaka v vrsti; nova ni nastala.'' END
  FROM #Vhod AS vhod WHERE vhod.Status IS NULL;

  BEGIN TRAN;

  IF @OutboundBatchId IS NULL AND EXISTS (SELECT 1 FROM #Polje WHERE IsDuplicate = 0)
  BEGIN
    INSERT out.OutboundBatch(OrganizationId, TargetKind, Source, Note, CreatedBy)
    VALUES(@OrganizationId, N''SAOP_PRICE'', @Source, @Note, @Actor);
    SET @OutboundBatchId = SCOPE_IDENTITY();
  END;

  /* Vsa starejsa sporocila teh cen postanejo Superseded (O16) - tudi Sent, ki bi sicer za vedno cakal
     na potrditev vrednosti, ki je ni vec, in Error. Ista vrednost, ki je bila ze poslana, gre znova:
     ce jo je SAOP sprejel, je ponovitev neskodljiva, ce je ni, je prav, da gre. */
  UPDATE previous
  SET Status = N''Superseded'', NextAttemptUtc = NULL, LeaseOwner = NULL, LeaseUntilUtc = NULL,
      LastError = N''Nadomeščeno z novejšo ceno.'', UpdatedUtc = SYSUTCDATETIME()
  FROM out.OutboxMessage AS previous
  WHERE previous.OrganizationId = @OrganizationId AND previous.TargetKind = N''SAOP_PRICE'' AND previous.EntityType = N''Price''
    AND previous.Status IN (N''PendingApproval'', N''Pending'', N''Retry'', N''Sent'', N''Error'')
    AND EXISTS (SELECT 1 FROM #Polje AS polje WHERE polje.IsDuplicate = 0 AND polje.EntityKey = previous.EntityKey);

  INSERT out.OutboxMessage(OrganizationId, TargetKind, Operation, EntityType, EntityKey, FieldSummary, PayloadJson,
    PayloadHash, ExpectedEchoHash, DedupKey, Status, NextAttemptUtc, CreatedBy, OutboundBatchId)
  SELECT @OrganizationId, N''SAOP_PRICE'', polje.Operation, N''Price'', polje.EntityKey, polje.FieldName, polje.Payload,
    polje.PayloadHash, polje.PayloadHash, polje.PayloadHash, @Status,
    CASE WHEN @Status = N''Pending'' THEN DATEADD(millisecond, -1, SYSUTCDATETIME()) END, @Actor, @OutboundBatchId
  FROM #Polje AS polje
  WHERE polje.IsDuplicate = 0;

  COMMIT;

  SELECT vhod.Zaporedna, vhod.PriceList, ItemID = vhod.ItemID, vhod.Status, vhod.Reason,
    Intent = CASE WHEN vhod.HasCurrent = 1 THEN N''UPDATE'' ELSE N''ADD'' END,
    OldNet = vhod.CurrentNet, NewNet = vhod.Net
  FROM #Vhod AS vhod
  ORDER BY vhod.Zaporedna;
END;');

/* --- enqueue_pricelist ------------------------------------------------------------ */
EXEC(N'CREATE OR ALTER PROCEDURE out.EnqueueSaopPriceList
  @OrganizationId int, @PriceListId nvarchar(100), @Description nvarchar(400), @CurrencyId nvarchar(20) = NULL,
  @VatIncluded bit = 0, @Active bit = 1, @Actor nvarchar(200), @Note nvarchar(400) = NULL,
  @OutboundBatchId bigint = NULL OUTPUT
AS
BEGIN
  /* 265: nov cenik (AddPriceLists) ali sprememba glave obstojecega (ModifyPriceLists).
     Kaj od obojega, odloci prevzem po out.SaopEntityExists - tu je vsebina ista. Valuta brez
     vrednosti vzame najpogostejso valuto cenikov tega podjetja v SAOP (IQ in Vidadria: 978 = EUR). */
  SET NOCOUNT ON; SET XACT_ABORT ON;
  SET @PriceListId = UPPER(LTRIM(RTRIM(@PriceListId)));
  SET @Description = NULLIF(LTRIM(RTRIM(@Description)), N'''');
  SET @CurrencyId = NULLIF(LTRIM(RTRIM(@CurrencyId)), N'''');

  IF NULLIF(@PriceListId, N'''') IS NULL THROW 52656, N''Šifra cenika je obvezna.'', 1;
  IF LEN(@PriceListId) > 20 OR @PriceListId LIKE N''%[^A-Z0-9 _.-]%''
    THROW 52657, N''Šifra cenika sme imeti največ 20 znakov: črke brez šumnikov, številke, presledek, pika, pomišljaj ali podčrtaj.'', 1;
  IF @Description IS NULL THROW 52658, N''Naziv cenika je obvezen.'', 1;

  SET @CurrencyId = COALESCE(@CurrencyId,
    (SELECT TOP(1) ExtraCode FROM canon.Codebook
     WHERE OrganizationId = @OrganizationId AND CodebookCode = N''PRICELIST'' AND NULLIF(ExtraCode, N'''') IS NOT NULL
     GROUP BY ExtraCode ORDER BY COUNT(*) DESC, ExtraCode),
    N''978'');

  IF NOT EXISTS (SELECT 1 FROM dbo.IntegrationProfile WHERE OrganizationId = @OrganizationId AND TargetKind = N''SAOP_PRICELIST'' AND IsEnabled = 1)
    THROW 52659, N''Pošiljanje cenikov v SAOP za to podjetje ni omogočeno (dbo.IntegrationProfile SAOP_PRICELIST).'', 1;

  DECLARE @Fields TABLE (FieldName nvarchar(200) NOT NULL PRIMARY KEY, Value nvarchar(400) NOT NULL);
  INSERT @Fields(FieldName, Value) VALUES
    (N''PriceList.PriceListDescription'', @Description),
    (N''PriceList.CurrencyId'', @CurrencyId),
    (N''PriceList.VatIncluded'', CASE WHEN @VatIncluded = 1 THEN N''true'' ELSE N''false'' END),
    (N''PriceList.Active'', CASE WHEN @Active = 0 THEN N''false'' ELSE N''true'' END);

  DECLARE @Operation nvarchar(20) =
    CASE WHEN out.SaopEntityExists(@OrganizationId, N''SAOP_PRICELIST'', @PriceListId) = 1 THEN N''UPDATE'' ELSE N''ADD'' END;

  BEGIN TRAN;

  DECLARE @CreatedBatch bit = 0;
  IF @OutboundBatchId IS NULL
  BEGIN
    SET @CreatedBatch = 1;
    INSERT out.OutboundBatch(OrganizationId, TargetKind, Source, Note, CreatedBy)
    VALUES(@OrganizationId, N''SAOP_PRICELIST'', N''SINGLE'', COALESCE(@Note, CONCAT(N''Cenik '', @PriceListId, N'' — '', @Description)), @Actor);
    SET @OutboundBatchId = SCOPE_IDENTITY();
  END;

  DECLARE @Field nvarchar(200), @Value nvarchar(400), @Payload nvarchar(max), @MessageId bigint;
  DECLARE @Result TABLE (FieldName nvarchar(200), Value nvarchar(400), OutboxMessageId bigint);

  DECLARE polja CURSOR LOCAL FAST_FORWARD FOR SELECT FieldName, Value FROM @Fields ORDER BY FieldName;
  OPEN polja;
  FETCH NEXT FROM polja INTO @Field, @Value;
  WHILE @@FETCH_STATUS = 0
  BEGIN
    SET @MessageId = NULL;
    SET @Payload = (SELECT @PriceListId AS [entityKey], @Field AS [field], @Value AS [value] FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
    /* Enaka vrednost ze v vrsti: out.EnqueueMessage bi jo ujel v CATCH, a ta v odprti transakciji
       z XACT_ABORT transakcijo pokvari. Zato se dvojnik prepozna prej, po istem hashu. */
    SELECT @MessageId = OutboxMessageId FROM out.OutboxMessage
    WHERE OrganizationId = @OrganizationId
      AND DedupKey = CONVERT(char(64), HASHBYTES(''SHA2_256'', CONVERT(varbinary(max), @Payload)), 2)
      AND Status IN (N''PendingApproval'', N''Pending'', N''Sending'', N''Sent'', N''Error'', N''Retry'');
    IF @MessageId IS NULL
    EXEC out.EnqueueMessage @OrganizationId = @OrganizationId, @TargetKind = N''SAOP_PRICELIST'', @Operation = @Operation,
      @EntityType = N''PriceList'', @PayloadJson = @Payload, @Actor = @Actor, @OutboxMessageId = @MessageId OUTPUT;
    UPDATE out.OutboxMessage SET OutboundBatchId = @OutboundBatchId
    WHERE OutboxMessageId = @MessageId AND OutboundBatchId IS NULL;
    INSERT @Result VALUES (@Field, @Value, @MessageId);
    FETCH NEXT FROM polja INTO @Field, @Value;
  END;
  CLOSE polja;
  DEALLOCATE polja;

  IF @CreatedBatch = 1 AND NOT EXISTS (SELECT 1 FROM out.OutboxMessage WHERE OutboundBatchId = @OutboundBatchId)
  BEGIN
    DELETE out.OutboundBatch WHERE OutboundBatchId = @OutboundBatchId;
    SET @OutboundBatchId = NULL;
  END;

  COMMIT;

  SELECT PriceListId = @PriceListId, Operation = @Operation, OutboundBatchId = @OutboundBatchId, result.FieldName, result.Value, result.OutboxMessageId
  FROM @Result AS result ORDER BY result.FieldName;
END;');

/* --- preverjanje ------------------------------------------------------------------------------ */
IF EXISTS (SELECT 1 FROM dbo.IntegrationProfile AS product
           WHERE product.TargetKind = N'SAOP_PRODUCT'
             AND (SELECT COUNT(*) FROM dbo.IntegrationProfile AS price
                  WHERE price.OrganizationId = product.OrganizationId AND price.TargetKind IN (N'SAOP_PRICE', N'SAOP_PRICELIST')) <> 2)
  THROW 52660, N'265: podjetje s profilom artiklov nima obeh profilov za cene in cenike.', 1;

IF EXISTS (SELECT 1 FROM out.OwnershipPolicy WHERE TargetKind IN (N'SAOP_PRICE', N'SAOP_PRICELIST') AND Owner <> N'PIM')
  THROW 52661, N'265: ostalo je polje cene ali cenika v lasti SAOP.', 1;

IF OBJECT_ID(N'out.ClaimSaopDocument', N'P') IS NULL OR OBJECT_ID(N'out.EnqueueSaopPriceChanges', N'P') IS NULL
   OR OBJECT_ID(N'out.EnqueueSaopPriceList', N'P') IS NULL OR OBJECT_ID(N'out.SaopEntityExists', N'FN') IS NULL
  THROW 52662, N'265: manjka ena od novih procedur.', 1;
