/* 241: novi artikli iz XML - potisk uvozenega artikla v cakalno vrsto SAOP in prevzem sifre iz SAOP.

   Uporabnik 2026-09-21: »rabimo neko stran kjer bodo zaznani novi artikli ki so samo v XMLju in
   jih urednik lahko porine v PIM in nato tudi v SAOP cakalno vrsto.«

   Stanje pred 241 (razvojna baza, po 240): kandidat iz dobaviteljevega XML gre z »Uvozi« v
   canon.Product (ItemID = EAN, ErpExistence = NOT_YET_IN_ERP) s podatki iz XML-ja. Pot naprej v
   SAOP je obstajala samo posredno: urednik je moral odpreti kartico artikla ali stran
   /saop/artikli, tam vpisati obvezna polja in jih uvrstiti. Stran kandidatov o stanju v SAOP ni
   vedela nic. Po uspesnem ADD pa artikel v PIM ni dobil sifre, ki jo je dodelil SAOP:
   out.SaopItemAssignment (046) jo je zabelezil, canon.Product pa je ostal na EAN in na
   NOT_YET_IN_ERP - zastavica iz 169 se ni nikjer postavila na CONFIRMED_IN_ERP. Posledici:
   naslednje posiljanje bi spet slo kot ADD (ItemAlreadyExists, samopopravek), naslednji zajem
   SAOP pa bi z novo sifro ustvaril DRUG artikel (SAOP sme ustvarjati artikle), EAN-ski bi ostal
   sirota.

   Kaj ta migracija spremeni:
     1. CK_OutboundBatch_Source dovoli vir 'XML' - skupine, ki jih uvrsti stran kandidatov, so v
        pregledih /outbound in /saop razpoznavne (kot 'CARD' iz 152).
     2. intranet.GetSupplierProductCandidates: telo iz 240, dodatno za odobrene kandidate stanje v
        SAOP (ProductItemId, ErpExistence, SaopState, sporocila v vrsti, zadnja skupina, zadnja
        napaka, sifra iz SAOP), filter @SaopState in stevci v povzetku. Sporocila se iscejo po
        trenutni sifri artikla IN po kljucu kandidata (EAN), ker po prevzemu sifre stara
        sporocila ostanejo pod EAN.
     3. out.CompleteItemDocument: telo iz 196, dodatno ob uspehu: artikel z NOT_YET_IN_ERP postane
        CONFIRMED_IN_ERP; ce je SAOP ob ADD dodelil drugo sifro (SuggestFirstFreeCode), jo
        canon.Product.ItemID prevzame (EAN ostane, sporocila v vrsti ostanejo pod staro sifro kot
        zgodovina). Ce sifro v PIM ze ima drug artikel, se artikel NE preimenuje in ostane
        NOT_YET_IN_ERP; nastane opozorilo v ops.OutboundEvent, da ju urednik zdruzi rocno -
        napacna povezava je slabsa od nobene (isto nacelo kot v 046).

   Cesa NE spreminja: map.ProcessRawInbox (240), out.EnqueueSaopItemChanges (089), izbira
   ADD/PATCH (SaopIntentResolver) - stran kandidatov uvrsca prek iste poti kot /saop/artikli in
   kartica (out.EnqueueSaopItemChanges), dokument sestavi isti gradnik (SaopItemPlanner).
*/

/* out.OutboxMessage ima filtriran indeks (UX_OutboxMessage_ActiveDedup); procedura, ki jo pise, mora
   nastati s QUOTED_IDENTIFIER ON (230) - nastavitev velja tudi znotraj EXEC(N'...'). */
SET QUOTED_IDENTIFIER ON;
SET XACT_ABORT ON;

/* --- 1) Vir skupine 'XML' ------------------------------------------------------------------ */
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_OutboundBatch_Source' AND definition NOT LIKE N'%XML%')
  ALTER TABLE out.OutboundBatch DROP CONSTRAINT CK_OutboundBatch_Source;

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_OutboundBatch_Source')
  ALTER TABLE out.OutboundBatch ADD CONSTRAINT CK_OutboundBatch_Source
    CHECK (Source IN (N'SINGLE', N'BULK', N'EXCEL', N'CARD', N'XML'));

/* --- 2) Pregled kandidatov s stanjem v SAOP --------------------------------------------------- */
EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetSupplierProductCandidates
  @OrganizationId int=NULL, @SourceCode nvarchar(100)=NULL, @Status nvarchar(20)=NULL,
  @Search nvarchar(200)=NULL, @Skip int=0, @Take int=50,
  @SaopState nvarchar(20)=NULL   /* 241: NOT_QUEUED | QUEUED | SENT | FAILED | CONFIRMED (samo odobreni) */
AS
BEGIN
  SET NOCOUNT ON;
  SET @Take=CASE WHEN @Take<1 THEN 50 WHEN @Take>200 THEN 200 ELSE @Take END;
  SET @Skip=CASE WHEN @Skip<0 THEN 0 ELSE @Skip END;
  SET @Search=NULLIF(LTRIM(RTRIM(@Search)),'''');
  SET @SaopState=NULLIF(LTRIM(RTRIM(@SaopState)),'''');
  DECLARE @Like nvarchar(204)=CASE WHEN @Search IS NULL THEN NULL ELSE ''%''+@Search+''%'' END;

  SELECT candidate.SupplierProductCandidateId, candidate.OrganizationId, organization.Name AS OrganizationName,
    candidate.SourceCode, candidate.ItemID, candidate.EAN, candidate.Status, candidate.IsActive,
    candidate.FirstSeenUtc, candidate.LastSeenUtc, candidate.OccurrenceCount,
    candidate.DecidedUtc, candidate.DecidedBy, candidate.DecisionReason, candidate.CreatedProductId,
    candidate.ItemIdFromEan, inbox.RunId, inbox.EntityType,
    ProductItemId=product.ItemID, product.ErpExistence
  INTO #Base
  FROM map.SupplierProductCandidate candidate
  INNER JOIN dbo.OrganizationConfig organization ON organization.OrganizationId=candidate.OrganizationId
  INNER JOIN raw.Inbox inbox ON inbox.InboxId=candidate.InboxId
  LEFT JOIN canon.Product product ON product.ProductId=candidate.CreatedProductId
  WHERE (@OrganizationId IS NULL OR candidate.OrganizationId=@OrganizationId)
    AND (@SourceCode IS NULL OR candidate.SourceCode=@SourceCode)
    AND (@Status IS NULL OR candidate.Status=@Status)
    AND (@Like IS NULL OR candidate.ItemID LIKE @Like OR candidate.EAN LIKE @Like OR product.ItemID LIKE @Like);

  /* Stanje v odhodni vrsti za ustvarjeni artikel: po trenutni sifri artikla ALI po kljucu
     kandidata (EAN) - po prevzemu sifre iz SAOP stara sporocila ostanejo pod EAN. */
  SELECT base.SupplierProductCandidateId,
    Live=SUM(CASE WHEN message.Status IN (N''PendingApproval'',N''Pending'',N''Retry'',N''Sending'') THEN 1 ELSE 0 END),
    PendingApproval=SUM(CASE WHEN message.Status=N''PendingApproval'' THEN 1 ELSE 0 END),
    LastMessageId=MAX(message.OutboxMessageId),
    LastUpdatedUtc=MAX(message.UpdatedUtc)
  INTO #Vrsta
  FROM #Base base
  INNER JOIN out.OutboxMessage message
    ON message.OrganizationId=base.OrganizationId AND message.TargetKind=N''SAOP_PRODUCT'' AND message.EntityType=N''Product''
   AND message.EntityKey IN (base.ProductItemId, base.ItemID)
  WHERE base.CreatedProductId IS NOT NULL
  GROUP BY base.SupplierProductCandidateId;

  SELECT base.*,
    SaopLiveMessages=ISNULL(vrsta.Live,0),
    SaopPendingApproval=ISNULL(vrsta.PendingApproval,0),
    SaopLastStatus=zadnje.Status,
    SaopLastBatchId=zadnje.OutboundBatchId,
    SaopLastUpdatedUtc=vrsta.LastUpdatedUtc,
    SaopLastError=zadnje.LastError,
    SaopState=CASE
      WHEN base.Status<>N''APPROVED'' OR base.CreatedProductId IS NULL THEN NULL
      WHEN base.ErpExistence=N''CONFIRMED_IN_ERP'' THEN N''CONFIRMED''
      WHEN ISNULL(vrsta.Live,0)>0 THEN N''QUEUED''
      WHEN zadnje.Status IN (N''Dead'',N''Error'',N''Drift'') THEN N''FAILED''
      WHEN zadnje.Status IN (N''Sent'',N''Verified'') THEN N''SENT''
      ELSE N''NOT_QUEUED'' END
  INTO #Rows
  FROM #Base base
  LEFT JOIN #Vrsta vrsta ON vrsta.SupplierProductCandidateId=base.SupplierProductCandidateId
  LEFT JOIN out.OutboxMessage zadnje ON zadnje.OutboxMessageId=vrsta.LastMessageId;

  IF @SaopState IS NOT NULL DELETE #Rows WHERE ISNULL(SaopState,N'''')<>@SaopState;

  SELECT * INTO #Page FROM #Rows
  ORDER BY CASE Status WHEN ''PENDING'' THEN 0 ELSE 1 END, LastSeenUtc DESC, SupplierProductCandidateId DESC
  OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY;

  /* Dobaviteljev naziv (240): kljuci (sifra/EAN) zapisov v zajemih te strani se preberejo enkrat,
     naziv pa prek indeksa po ciljni kodi (IX_ExtractedValue_Identity). Vir brez preslikanega
     naziva (danes NW_XML/BT_XML) dobi NULL - nic se ne izmislja. */
  SELECT inbox.RunId, value.InboxId, value.RecordOrdinal, CONVERT(nvarchar(100), value.Value) AS Kljuc
  INTO #Kljuc
  FROM raw.Inbox inbox
  INNER JOIN map.ExtractedValue value
    ON value.InboxId=inbox.InboxId AND value.TargetFieldCode IN (N''Product.ItemID'', N''Product.EAN'')
  WHERE inbox.RunId IN (SELECT DISTINCT RunId FROM #Page)
    AND NULLIF(LTRIM(RTRIM(value.Value)), N'''') IS NOT NULL;

  SELECT page.*,
    SupplierTitle =
    (
      SELECT TOP (1) CONVERT(nvarchar(400), naziv.Value)
      FROM #Kljuc kljuc
      INNER JOIN map.ExtractedValue naziv
        ON naziv.TargetFieldCode LIKE N''ProductText.%TITLE%'' AND naziv.InboxId=kljuc.InboxId AND naziv.RecordOrdinal=kljuc.RecordOrdinal
      WHERE kljuc.RunId=page.RunId AND kljuc.Kljuc IN (page.ItemID, page.EAN)
        AND NULLIF(LTRIM(RTRIM(naziv.Value)), N'''') IS NOT NULL
      ORDER BY CASE WHEN naziv.TargetFieldCode LIKE N''%.sl'' THEN 0 WHEN naziv.TargetFieldCode LIKE N''%.en'' THEN 1 ELSE 2 END,
               CASE WHEN naziv.TargetFieldCode LIKE N''ProductText.WEB_TITLE.%'' THEN 0 ELSE 1 END
    ),
    /* Sifra, ki jo je SAOP dodelil ob ADD (046/084): po prevzemu je enaka ProductItemId, ob koliziji
       (drug artikel v PIM ze ima to sifro) pa je to edino mesto, kjer jo urednik vidi. */
    SaopAssignedItemId =
    (
      SELECT TOP (1) assignment.AssignedSaopItemId
      FROM out.SaopItemAssignment assignment
      INNER JOIN out.OutboxMessage message ON message.OutboxMessageId=assignment.OutboxMessageId
      WHERE message.OrganizationId=page.OrganizationId AND message.TargetKind=N''SAOP_PRODUCT'' AND message.EntityType=N''Product''
        AND message.EntityKey IN (page.ProductItemId, page.ItemID) AND assignment.AssignedSaopItemId IS NOT NULL
      ORDER BY assignment.OutboxMessageId DESC
    )
  FROM #Page page
  ORDER BY CASE page.Status WHEN ''PENDING'' THEN 0 ELSE 1 END, page.LastSeenUtc DESC, page.SupplierProductCandidateId DESC;

  SELECT COUNT_BIG(*) TotalCount,
    ISNULL(SUM(CASE WHEN Status=''PENDING'' THEN 1 ELSE 0 END),0) PendingCount,
    ISNULL(SUM(CASE WHEN Status=''APPROVED'' THEN 1 ELSE 0 END),0) ApprovedCount,
    ISNULL(SUM(CASE WHEN Status=''REJECTED'' THEN 1 ELSE 0 END),0) RejectedCount,
    ISNULL(SUM(CASE WHEN SaopState=N''NOT_QUEUED'' THEN 1 ELSE 0 END),0) ImportedWaitingCount,
    ISNULL(SUM(CASE WHEN SaopState=N''QUEUED'' THEN 1 ELSE 0 END),0) QueuedCount,
    ISNULL(SUM(CASE WHEN SaopState=N''SENT'' THEN 1 ELSE 0 END),0) SentCount,
    ISNULL(SUM(CASE WHEN SaopState=N''FAILED'' THEN 1 ELSE 0 END),0) FailedCount,
    ISNULL(SUM(CASE WHEN SaopState=N''CONFIRMED'' THEN 1 ELSE 0 END),0) ConfirmedCount
  FROM #Rows;

  DROP TABLE #Kljuc; DROP TABLE #Page; DROP TABLE #Rows; DROP TABLE #Vrsta; DROP TABLE #Base;
END;
');

/* --- 3) Zakljucek dokumenta: nov artikel po uspehu obstaja v SAOP ------------------------------ */
/* Telo iz 196 (obrezovanje seznama polj, obvestilo na dokument) je nespremenjeno; dodan je samo
   blok »241« pred obvestilom. Preverjeno, da je ziva definicija v bazi enaka 196 (sys.sql_modules). */
EXEC(N'
CREATE OR ALTER PROCEDURE out.CompleteItemDocument
  @OutboxMessageIdsJson nvarchar(max), @WorkerId nvarchar(200), @Succeeded bit,
  @ResponseStatusCode int = NULL, @ResponseBodyRedacted nvarchar(4000) = NULL,
  @ResponseCorrelationId nvarchar(200) = NULL, @FailureReason nvarchar(2000) = NULL,
  @ErrorClass nvarchar(20) = NULL, @SaopErrorKind nvarchar(40) = NULL,
  @Retryable bit = 0, @AssignedItemId nvarchar(200) = NULL
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  IF ISJSON(@OutboxMessageIdsJson) <> 1 THROW 52843, N''Seznam sporocil ni veljaven JSON.'', 1;

  DECLARE @Ids TABLE(OutboxMessageId bigint PRIMARY KEY);
  INSERT @Ids(OutboxMessageId) SELECT DISTINCT CONVERT(bigint, value) FROM OPENJSON(@OutboxMessageIdsJson);
  IF NOT EXISTS(SELECT 1 FROM @Ids) THROW 52844, N''Zakljucek brez sporocil ni mogoc.'', 1;

  BEGIN TRAN;

  IF EXISTS
  (
    SELECT 1 FROM @Ids AS candidate
    LEFT JOIN out.OutboxMessage AS message WITH(UPDLOCK, ROWLOCK)
      ON message.OutboxMessageId = candidate.OutboxMessageId
      AND message.Status = N''Sending'' AND message.LeaseOwner = @WorkerId AND message.LeaseUntilUtc >= SYSUTCDATETIME()
    WHERE message.OutboxMessageId IS NULL
  )
  BEGIN ROLLBACK; THROW 52845, N''Lease ni veljaven za vsa sporocila dokumenta.'', 1; END;

  DECLARE @BaseRetrySeconds int, @MaxAttempts int;
  SELECT TOP(1) @BaseRetrySeconds = profile.BaseRetrySeconds, @MaxAttempts = profile.MaxAttempts
  FROM out.OutboxMessage AS message
  INNER JOIN @Ids AS candidate ON candidate.OutboxMessageId = message.OutboxMessageId
  INNER JOIN dbo.IntegrationProfile AS profile
    ON profile.OrganizationId = message.OrganizationId AND profile.TargetKind = message.TargetKind;

  UPDATE message
  SET Status = CASE
        WHEN @Succeeded = 1 THEN N''Sent''
        WHEN @Retryable = 1 AND message.AttemptCount < @MaxAttempts THEN N''Retry''
        WHEN @ErrorClass = N''Transient'' AND message.AttemptCount < @MaxAttempts THEN N''Retry''
        ELSE N''Dead'' END,
      SentUtc = CASE WHEN @Succeeded = 1 THEN SYSUTCDATETIME() ELSE message.SentUtc END,
      NextAttemptUtc = CASE
        WHEN @Succeeded = 0 AND (@Retryable = 1 OR @ErrorClass = N''Transient'') AND message.AttemptCount < @MaxAttempts
        THEN DATEADD(second,
          CASE WHEN @Retryable = 1 THEN 0
               ELSE @BaseRetrySeconds * CONVERT(int, POWER(CONVERT(float, 2), message.AttemptCount - 1)) END,
          SYSUTCDATETIME()) END,
      LeaseOwner = NULL, LeaseUntilUtc = NULL,
      LastError = CASE WHEN @Succeeded = 1 THEN NULL ELSE @FailureReason END,
      ErrorClass = CASE WHEN @Succeeded = 1 THEN NULL ELSE @ErrorClass END,
      SaopErrorKind = CASE WHEN @Succeeded = 1 THEN NULL ELSE @SaopErrorKind END,
      ResponseStatusCode = @ResponseStatusCode,
      ResponseBodyRedacted = @ResponseBodyRedacted,
      ResponseCorrelationId = @ResponseCorrelationId,
      UpdatedUtc = SYSUTCDATETIME()
  FROM out.OutboxMessage AS message
  INNER JOIN @Ids AS candidate ON candidate.OutboxMessageId = message.OutboxMessageId;

  UPDATE attempt
  SET Outcome = CASE WHEN @Succeeded = 1 THEN N''Sent'' ELSE message.Status END,
      CompletedUtc = SYSUTCDATETIME(), ResponseStatusCode = @ResponseStatusCode,
      ResponseBodyRedacted = @ResponseBodyRedacted, ResponseCorrelationId = @ResponseCorrelationId,
      FailureReason = @FailureReason, ErrorClass = @ErrorClass
  FROM out.OutboxAttempt AS attempt
  INNER JOIN out.OutboxMessage AS message ON message.OutboxMessageId = attempt.OutboxMessageId
  INNER JOIN @Ids AS candidate ON candidate.OutboxMessageId = attempt.OutboxMessageId
  WHERE attempt.AttemptNumber = message.AttemptCount AND attempt.WorkerId = @WorkerId AND attempt.Outcome = N''Sending'';

  IF @Succeeded = 1 AND NULLIF(@AssignedItemId, N'''') IS NOT NULL
  BEGIN
    DECLARE @FirstId bigint = (SELECT MIN(OutboxMessageId) FROM @Ids);
    DECLARE @Method nvarchar(40), @Assigned nvarchar(200);
    EXEC out.ResolveSaopItemAssignment
      @OutboxMessageId = @FirstId, @ResponseItemId = @AssignedItemId, @RequestedIdentifier = NULL,
      @EAN = NULL, @Actor = @WorkerId, @MatchMethod = @Method OUTPUT, @AssignedSaopItemId = @Assigned OUTPUT;
  END;

  /* --- 241: artikel, ki ga je ustvaril PIM, po uspehu obstaja v SAOP ----------------------
     ErpExistence (169) se doslej ni nikjer postavil na CONFIRMED_IN_ERP: artikel iz XML bi
     ostal »se ni v ERP« tudi po uspesnem ADD in bi ob naslednjem posiljanju spet sel kot ADD.
     Ce je SAOP dodelil svojo sifro (SuggestFirstFreeCode), jo artikel prevzame - naslednji
     zajem SAOP ga po njej najde in posodobi, namesto da bi ustvaril drugega. EAN ostane;
     sporocila v vrsti ostanejo pod staro sifro (zgodovina). Ce sifro v PIM ze ima drug
     artikel, se ne preimenuje nic: opozorilo in rocna uskladitev (napacna povezava je slabsa
     od nobene, 046). */
  IF @Succeeded = 1
  BEGIN
    DECLARE @DocOrganizationId int, @DocEntityKey nvarchar(450), @DocBatchId bigint, @DocMessageId bigint;
    SELECT TOP(1) @DocOrganizationId = message.OrganizationId, @DocEntityKey = message.EntityKey,
      @DocBatchId = message.OutboundBatchId, @DocMessageId = message.OutboxMessageId
    FROM out.OutboxMessage AS message
    INNER JOIN @Ids AS candidate ON candidate.OutboxMessageId = message.OutboxMessageId
    WHERE message.TargetKind = N''SAOP_PRODUCT'' AND message.EntityType = N''Product''
    ORDER BY message.OutboxMessageId;

    IF @DocEntityKey IS NOT NULL
    BEGIN
      DECLARE @NewProductId bigint, @NewErpExistence nvarchar(20);
      SELECT @NewProductId = ProductId, @NewErpExistence = ErpExistence
      FROM canon.Product WHERE OrganizationId = @DocOrganizationId AND ItemID = @DocEntityKey;

      IF @NewProductId IS NOT NULL AND @NewErpExistence = N''NOT_YET_IN_ERP''
      BEGIN
        DECLARE @SaopItemId nvarchar(200) = NULLIF(LTRIM(RTRIM(@AssignedItemId)), N'''');
        IF @SaopItemId IS NOT NULL AND @SaopItemId <> @DocEntityKey
           AND EXISTS (SELECT 1 FROM canon.Product WHERE OrganizationId = @DocOrganizationId AND ItemID = @SaopItemId AND ProductId <> @NewProductId)
        BEGIN
          INSERT ops.OutboundEvent
            (OrganizationId, OutboundBatchId, OutboxMessageId, EntityType, EntityKey, Step, Severity, Title, Detail, FieldName, ActorUserName)
          VALUES
            (@DocOrganizationId, @DocBatchId, @DocMessageId, N''Product'', @DocEntityKey, N''Sent'', N''Warning'',
             N''SAOP je dodelil sifro, ki jo v PIM ze ima drug artikel.'',
             CONCAT(N''SAOP je nov artikel '', @DocEntityKey, N'' zapisal pod sifro '', @SaopItemId,
                    N'', ki jo v PIM ze ima drug artikel. Artikel v PIM ostaja »se ni v ERP«; zdruzi ju rocno.''),
             N''Product.ItemID'', @WorkerId);
        END
        ELSE
        BEGIN
          UPDATE canon.Product
          SET ItemID = COALESCE(@SaopItemId, ItemID), ErpExistence = N''CONFIRMED_IN_ERP''
          WHERE ProductId = @NewProductId;

          IF @SaopItemId IS NOT NULL AND @SaopItemId <> @DocEntityKey
            INSERT ops.OutboundEvent
              (OrganizationId, OutboundBatchId, OutboxMessageId, EntityType, EntityKey, Step, Severity, Title, Detail, FieldName, ActorUserName)
            VALUES
              (@DocOrganizationId, @DocBatchId, @DocMessageId, N''Product'', @DocEntityKey, N''Sent'', N''Info'',
               N''Artikel je prevzel sifro iz SAOP.'',
               CONCAT(N''Artikel '', @DocEntityKey, N'' je v SAOP dobil sifro '', @SaopItemId, N''; v PIM je sifra zamenjana, EAN ostaja.''),
               N''Product.ItemID'', @WorkerId);
        END;
      END;
    END;
  END;

  IF @Succeeded = 0 AND @ErrorClass = N''AuthConfig''
  BEGIN
    DECLARE @AuthOrganizationId int = (SELECT TOP(1) message.OrganizationId FROM out.OutboxMessage AS message
      INNER JOIN @Ids AS candidate ON candidate.OutboxMessageId = message.OutboxMessageId);
    UPDATE dbo.IntegrationProfile SET IsEnabled = 0, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = N''out.CompleteItemDocument''
    WHERE OrganizationId = @AuthOrganizationId AND TargetKind = N''SAOP_PRODUCT'' AND IsEnabled = 1;
  END;

  /* --- obvestilo: eno na dokument, ne na polje ---------------------------
     Uporabnika ne zanima pet vrstic za en artikel; zanima ga, ali je artikel sel skozi.
     Uspeh je Info in tih, zavrnitev je Error in vidna. Ponovni poskus je Warning: nekaj se
     dogaja, a ni treba nicesar narediti.

     Seznam polj (FieldName) je lahko dalj kot stolpec pri dokumentu z veliko polji (migracija
     196: 23-poljski dokument je to podrl in vzel s sabo cel zakljucek sporocila). Namesto da bi
     SQL Server vrgel napako sredi transakcije, se seznam tu obreze in dopolni s stevilom
     preostalih polj — nikoli ne presega stolpca, ne glede na to, koliko polj ima dokument. */
  DECLARE @FieldCount int = (SELECT COUNT(*) FROM @Ids);
  DECLARE @FieldList nvarchar(400) =
    (SELECT STRING_AGG(vsa.FieldSummary, N'', '') FROM out.OutboxMessage AS vsa
      INNER JOIN @Ids AS vsi ON vsi.OutboxMessageId = vsa.OutboxMessageId);
  IF @FieldList IS NOT NULL AND LEN(@FieldList) > 380
    SET @FieldList = LEFT(@FieldList, 350) + N'' … (skupaj '' + CONVERT(nvarchar(10), @FieldCount) + N'' polj)'';

  INSERT ops.OutboundEvent
    (OrganizationId, OutboundBatchId, OutboxMessageId, EntityType, EntityKey, Step, Severity, Title, Detail, FieldName, ActorUserName)
  SELECT TOP(1)
    message.OrganizationId, message.OutboundBatchId, message.OutboxMessageId, message.EntityType, message.EntityKey,
    CASE WHEN @Succeeded = 1 THEN N''Sent'' WHEN message.Status = N''Retry'' THEN N''SelfHealed'' ELSE N''Failed'' END,
    CASE WHEN @Succeeded = 1 THEN N''Info'' WHEN message.Status = N''Retry'' THEN N''Warning'' ELSE N''Error'' END,
    CASE WHEN @Succeeded = 1 THEN N''Sprememba je sprejeta v SAOP.''
         WHEN message.Status = N''Retry'' THEN N''SAOP je zavrnil; poskus se ponovi.''
         ELSE N''SAOP je zavrnil spremembo.'' END,
    @FailureReason,
    @FieldList,
    @WorkerId
  FROM out.OutboxMessage AS message
  INNER JOIN @Ids AS candidate ON candidate.OutboxMessageId = message.OutboxMessageId
  ORDER BY message.OutboxMessageId;

  COMMIT;
END;');

/* --- Dokaz --------------------------------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_OutboundBatch_Source' AND definition LIKE N'%XML%')
  THROW 52460, N'241: CK_OutboundBatch_Source ne dovoli vira XML.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'intranet.GetSupplierProductCandidates')) NOT LIKE N'%SaopState%'
  THROW 52461, N'241: intranet.GetSupplierProductCandidates ne vraca stanja v SAOP.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'intranet.GetSupplierProductCandidates')) NOT LIKE N'%SupplierTitle%'
  THROW 52462, N'241: telo iz 240 (dobaviteljev naziv) je izgubljeno.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'out.CompleteItemDocument')) NOT LIKE N'%CONFIRMED_IN_ERP%'
  THROW 52463, N'241: out.CompleteItemDocument ne potrdi obstoja artikla v SAOP.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'out.CompleteItemDocument')) NOT LIKE N'%skupaj%'
  THROW 52464, N'241: telo iz 196 (obrezovanje seznama polj) je izgubljeno.', 1;
