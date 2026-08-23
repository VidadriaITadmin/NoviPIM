/*
  084 — proizvajalec odhodnih sporocil in prevzem po ARTIKLU namesto po polju.

  Zakaj: po migraciji 081 znamo sestaviti dokument za SAOP, nihce pa ga ne narocilo. V
  out.OutboxMessage je 0 vrstic in edini klicatelj out.EnqueueMessage je bil doslej test.

  Dve stvari, ki ju ta migracija razresi:

  1) NAROCILO. out.EnqueueSaopItemChange sprejme eno spremembo enega polja enega artikla in
     jo uvrsti v vrsto prek obstojece out.EnqueueMessage. S tem podeduje vse varovalke, ki
     tam ze so: pogodbo payloada (51008), obvezne vrednosti (51009), lastnistvo polja iz
     migracije 068 (51010), kanonicni hash in dedup. Nobene od njih ne obide in nobene ne
     podvaja.

  2) PREVZEM PO ARTIKLU. Sporocilo ostane ena sprememba enega polja — tako mora biti, ker se
     echo, dedup in razveljavitev vodijo po polju. SAOP pa ne sprejema polj, ampak dokument
     na artikel. Zato out.ClaimItemDocument prevzame VSA cakajoca sporocila istega artikla
     naenkrat in jih vrne kot en dokument. Brez tega bi sprememba petih polj enega artikla
     pomenila pet HTTP klicev in pet priloznosti, da SAOP eno od njih zavrne.

  Skupina (out.OutboundBatch) je tu zato, ker uporabnik ne dela po enem artiklu. Uvoz Excela
  s 500 artikli je ena skupina; brez nje bi bilo v pregledu 500 nepovezanih sporocil in
  nemogoce bi bilo povedati "uvoz je koncan" ali "uvoz je delno padel".

  Kaj ta migracija NAMENOMA NE naredi:
    - Ne omogoci nobenega kanala. dbo.IntegrationProfile ostane, kakrsen je.
    - Ne posilja. Prevzem brez omogocenega profila ne vrne nicesar, enako kot doslej.
    - Ne spremeni out.ClaimMessage ne out.CompleteAttempt. Stara pot po enem sporocilu
      ostane nedotaknjena, ker jo uporabljajo obstojeci F8 testi in generični cilji, ki
      niso SAOP.

  Migrator ne pozna locila GO; procedure so zato v EXEC(N'...').
*/

SET XACT_ABORT ON;

/* --- 1) Skupina odhodnih sprememb --------------------------------------- */

IF OBJECT_ID(N'out.OutboundBatch', N'U') IS NULL
BEGIN
  CREATE TABLE out.OutboundBatch
  (
    OutboundBatchId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_OutboundBatch PRIMARY KEY,
    OrganizationId int NOT NULL,
    TargetKind nvarchar(100) NOT NULL CONSTRAINT DF_OutboundBatch_TargetKind DEFAULT N'SAOP_PRODUCT',
    /* Od kod je skupina prisla; uporabnik v pregledu loci rocni popravek od uvoza. */
    Source nvarchar(30) NOT NULL,
    Note nvarchar(400) NULL,
    CreatedBy nvarchar(200) NOT NULL,
    CreatedUtc datetime2(3) NOT NULL CONSTRAINT DF_OutboundBatch_CreatedUtc DEFAULT SYSUTCDATETIME(),
    ClosedUtc datetime2(3) NULL,
    CONSTRAINT FK_OutboundBatch_Organization FOREIGN KEY (OrganizationId) REFERENCES dbo.OrganizationConfig(OrganizationId),
    CONSTRAINT CK_OutboundBatch_Source CHECK (Source IN (N'SINGLE', N'BULK', N'EXCEL'))
  );
END;

IF COL_LENGTH(N'out.OutboxMessage', N'OutboundBatchId') IS NULL
  ALTER TABLE out.OutboxMessage ADD OutboundBatchId bigint NULL
    CONSTRAINT FK_OutboxMessage_Batch FOREIGN KEY REFERENCES out.OutboundBatch(OutboundBatchId);

/*
  Zadnja vrsta zavrnitve SAOP na tem sporocilu. Hrani se zato, ker je od nje odvisna izbira
  med ADD in PATCH ob naslednjem poskusu: ce je SAOP rekel "artikel ze obstaja", je naslednji
  poskus PATCH, tudi ce v nasi bazi artikla ni. To je 118 od 130 napak stare vrste.
*/
IF COL_LENGTH(N'out.OutboxMessage', N'SaopErrorKind') IS NULL
  ALTER TABLE out.OutboxMessage ADD SaopErrorKind nvarchar(40) NULL;

/* Prevzem isce po (organizacija, artikel); brez tega indeksa bi vsak prevzem bral vso vrsto. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'out.OutboxMessage') AND name = N'IX_OutboxMessage_ItemDocument')
  CREATE INDEX IX_OutboxMessage_ItemDocument
    ON out.OutboxMessage(OrganizationId, TargetKind, EntityKey, Status, NextAttemptUtc)
    INCLUDE (LeaseUntilUtc, OutboxMessageId);

/* Stolpec je nastal v tem paketu, zato ga naslednji stavki ne vidijo pri prevajanju;
   indeks nad njim mora biti v EXEC — enako kot procedure. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'out.OutboxMessage') AND name = N'IX_OutboxMessage_Batch')
  EXEC(N'CREATE INDEX IX_OutboxMessage_Batch ON out.OutboxMessage(OutboundBatchId) WHERE OutboundBatchId IS NOT NULL;');

/* --- 2) Poti za ADD in PATCH ------------------------------------------- */

/*
  Doslej je profil imel eno koncno tocko in eno metodo. Za artikle to ne zadosca: nov artikel
  gre s POST na AddItemsGeneralData, sprememba pa s PATCH na UpdateItemsGeneralData. Zato se
  EndpointTemplate za cilj SAOP_PRODUCT bere kot OSNOVNI naslov, pot pa doda metoda.

  Privzetka sta zapisana iz resnicnih nastavitev starega sistema, ne izmisljena.
*/
IF COL_LENGTH(N'dbo.IntegrationProfile', N'AddPath') IS NULL
  ALTER TABLE dbo.IntegrationProfile ADD AddPath nvarchar(400) NULL
    CONSTRAINT DF_IntegrationProfile_AddPath DEFAULT N'api/Item/AddItemsGeneralData';

IF COL_LENGTH(N'dbo.IntegrationProfile', N'UpdatePath') IS NULL
  ALTER TABLE dbo.IntegrationProfile ADD UpdatePath nvarchar(400) NULL
    CONSTRAINT DF_IntegrationProfile_UpdatePath DEFAULT N'api/Item/UpdateItemsGeneralData';

/* --- 3) Narocilo spremembe --------------------------------------------- */

EXEC(N'
CREATE OR ALTER PROCEDURE out.BeginOutboundBatch
  @OrganizationId int, @Source nvarchar(30), @Note nvarchar(400), @Actor nvarchar(200),
  @OutboundBatchId bigint OUTPUT
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  INSERT out.OutboundBatch(OrganizationId, Source, Note, CreatedBy)
  VALUES(@OrganizationId, @Source, @Note, @Actor);
  SET @OutboundBatchId = SCOPE_IDENTITY();
END;');

/*
  Ena sprememba enega polja enega artikla.

  Payload je natanko tak, kot ga zahteva pogodba iz migracije 023 — {entityKey, field, value}
  in po potrebi qualifier. Vse ostalo (kanonicni zapis, hash, dedup, preverba lastnistva)
  naredi out.EnqueueMessage. Ta procedura je ovoj, ne druga pot.

  @OutboxMessageId vrne id; kadar enako sporocilo ze caka, out.EnqueueMessage vrne obstojeci
  id in nova vrstica ne nastane. To je zeleno: dvakrat kliknjen gumb ne sme poslati dvakrat.
*/
EXEC(N'
CREATE OR ALTER PROCEDURE out.EnqueueSaopItemChange
  @OrganizationId int, @ItemID nvarchar(450), @FieldKey nvarchar(200), @Value nvarchar(4000),
  @Actor nvarchar(200), @OutboundBatchId bigint = NULL, @OutboxMessageId bigint OUTPUT
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;

  IF NULLIF(LTRIM(RTRIM(@ItemID)), N'''') IS NULL THROW 52840, ''Sprememba brez sifre artikla ni naslovljiva.'', 1;
  IF NULLIF(LTRIM(RTRIM(@FieldKey)), N'''') IS NULL THROW 52841, ''Sprememba brez polja ni sprememba.'', 1;

  /* Polje mora biti del dokumenta, sicer bi sporocilo cakalo v vrsti in nikoli ne bi odslo. */
  IF NOT EXISTS
  (
    SELECT 1 FROM out.SaopXmlField
    WHERE TargetKind = N''SAOP_PRODUCT'' AND IsEnabled = 1 AND FieldKey = @FieldKey
  )
    THROW 52842, ''Polje ni del dokumenta ItemsGeneralData; sprememba ne bi mogla oditi.'', 1;

  DECLARE @Payload nvarchar(max) =
    (SELECT @ItemID AS [entityKey], @FieldKey AS [field], ISNULL(@Value, N'''') AS [value] FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

  EXEC out.EnqueueMessage
    @OrganizationId = @OrganizationId, @TargetKind = N''SAOP_PRODUCT'', @Operation = N''UPDATE'',
    @EntityType = N''Product'', @PayloadJson = @Payload, @Actor = @Actor,
    @OutboxMessageId = @OutboxMessageId OUTPUT;

  IF @OutboundBatchId IS NOT NULL AND @OutboxMessageId IS NOT NULL
    UPDATE out.OutboxMessage SET OutboundBatchId = @OutboundBatchId
    WHERE OutboxMessageId = @OutboxMessageId AND OutboundBatchId IS NULL;
END;');

/* --- 4) Prevzem celega dokumenta enega artikla -------------------------- */

/*
  Vrne tri rezultatne mnozice ali nic, kadar ni kaj prevzeti:
    1) glava    — organizacija, sifra artikla, naslov, poti, casovna omejitev, ali artikel
                  v SAOP ze obstaja in kaj je SAOP nazadnje zavrnil
    2) polja    — prevzeta sporocila (id, polje, vrednost)
    3) privzetki— iz out.SaopAddDefault, za primer, da gre za ADD

  Vsa sporocila istega artikla se prevzamejo v ISTI transakciji. Ce bi se prevzemala posebej,
  bi lahko dva workerja gradila dva dokumenta za isti artikel in bi drugi povozil prvega.
*/
EXEC(N'
CREATE OR ALTER PROCEDURE out.ClaimItemDocument @WorkerId nvarchar(200), @LeaseSeconds int = 90
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON; BEGIN TRAN;

  DECLARE @OrganizationId int, @EntityKey nvarchar(450);

  SELECT TOP(1) @OrganizationId = message.OrganizationId, @EntityKey = message.EntityKey
  FROM out.OutboxMessage AS message WITH (UPDLOCK, READPAST, ROWLOCK)
  INNER JOIN dbo.IntegrationProfile AS profile
    ON profile.OrganizationId = message.OrganizationId AND profile.TargetKind = message.TargetKind AND profile.IsEnabled = 1
  WHERE message.TargetKind = N''SAOP_PRODUCT'' AND message.EntityType = N''Product''
    AND message.Status IN (N''Pending'', N''Retry'')
    AND (message.NextAttemptUtc IS NULL OR message.NextAttemptUtc <= SYSUTCDATETIME())
    AND (message.LeaseUntilUtc IS NULL OR message.LeaseUntilUtc < SYSUTCDATETIME())
  ORDER BY message.OutboxMessageId;

  IF @EntityKey IS NULL BEGIN COMMIT; RETURN; END;

  DECLARE @Claimed TABLE(OutboxMessageId bigint PRIMARY KEY);

  UPDATE message
  SET Status = N''Sending'', AttemptCount = message.AttemptCount + 1,
      LeaseOwner = @WorkerId, LeaseUntilUtc = DATEADD(second, @LeaseSeconds, SYSUTCDATETIME()),
      UpdatedUtc = SYSUTCDATETIME()
  OUTPUT inserted.OutboxMessageId INTO @Claimed
  FROM out.OutboxMessage AS message WITH (UPDLOCK, ROWLOCK)
  WHERE message.OrganizationId = @OrganizationId AND message.EntityKey = @EntityKey
    AND message.TargetKind = N''SAOP_PRODUCT'' AND message.EntityType = N''Product''
    AND message.Status IN (N''Pending'', N''Retry'')
    AND (message.NextAttemptUtc IS NULL OR message.NextAttemptUtc <= SYSUTCDATETIME())
    AND (message.LeaseUntilUtc IS NULL OR message.LeaseUntilUtc < SYSUTCDATETIME());

  INSERT out.OutboxAttempt(OutboxMessageId, AttemptNumber, WorkerId)
  SELECT message.OutboxMessageId, message.AttemptCount, @WorkerId
  FROM out.OutboxMessage AS message INNER JOIN @Claimed AS claimed ON claimed.OutboxMessageId = message.OutboxMessageId;

  SELECT
    OrganizationId = @OrganizationId,
    ItemID = @EntityKey,
    BaseUrl = profile.EndpointTemplate,
    AddPath = ISNULL(profile.AddPath, N''api/Item/AddItemsGeneralData''),
    UpdatePath = ISNULL(profile.UpdatePath, N''api/Item/UpdateItemsGeneralData''),
    profile.TimeoutSeconds,
    profile.MaxAttempts,
    ExistsInSaop = CONVERT(bit, CASE WHEN EXISTS
      (SELECT 1 FROM canon.Product WHERE OrganizationId = @OrganizationId AND ItemID = @EntityKey) THEN 1 ELSE 0 END),
    LastErrorKind =
    (
      SELECT TOP(1) message.SaopErrorKind FROM out.OutboxMessage AS message
      INNER JOIN @Claimed AS claimed ON claimed.OutboxMessageId = message.OutboxMessageId
      WHERE message.SaopErrorKind IS NOT NULL ORDER BY message.OutboxMessageId DESC
    ),
    SourceKey = CASE WHEN CHARINDEX(N''.'', @EntityKey) > 1
      THEN UPPER(LEFT(@EntityKey, CHARINDEX(N''.'', @EntityKey) - 1)) ELSE N''*'' END
  FROM dbo.IntegrationProfile AS profile
  WHERE profile.OrganizationId = @OrganizationId AND profile.TargetKind = N''SAOP_PRODUCT'';

  SELECT message.OutboxMessageId, FieldKey = message.FieldSummary,
    Value = JSON_VALUE(message.PayloadJson, N''$.value''),
    message.AttemptCount, message.OutboundBatchId
  FROM out.OutboxMessage AS message
  INNER JOIN @Claimed AS claimed ON claimed.OutboxMessageId = message.OutboxMessageId
  ORDER BY message.OutboxMessageId;

  SELECT Section, ElementName, Value
  FROM out.SaopAddDefault
  WHERE OrganizationId = @OrganizationId AND IsEnabled = 1
    AND SourceKey IN (N''*'', CASE WHEN CHARINDEX(N''.'', @EntityKey) > 1
      THEN UPPER(LEFT(@EntityKey, CHARINDEX(N''.'', @EntityKey) - 1)) ELSE N''*'' END)
  ORDER BY CASE WHEN SourceKey = N''*'' THEN 1 ELSE 0 END;

  COMMIT;
END;');

/* --- 5) Zakljucek celega dokumenta -------------------------------------- */

/*
  En izid za vsa sporocila dokumenta, ker je bil en HTTP klic. Delnega uspeha ni: SAOP
  dokument sprejme ali zavrne v celoti.

  @OutboxMessageIdsJson je polje idjev, na primer [12,13,14]. Uporabljen je OPENJSON in ne
  locila, ker je JSON v tej shemi ze povsod in ker ga preveri ISJSON.

  @SaopErrorKind se zapise na sporocilo, da ob naslednjem poskusu izbira med ADD in PATCH ve,
  kaj je SAOP zadnjic rekel. Kadar je napaka taksna, da jo zna PIM popraviti sam
  (ItemAlreadyExists, ItemNotFound), se sporocilo vrne v Retry ne glede na razred napake —
  to ni poslovna zavrnitev, ampak napacno izbrana metoda.
*/
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
  IF ISJSON(@OutboxMessageIdsJson) <> 1 THROW 52843, ''Seznam sporocil ni veljaven JSON.'', 1;

  DECLARE @Ids TABLE(OutboxMessageId bigint PRIMARY KEY);
  INSERT @Ids(OutboxMessageId) SELECT DISTINCT CONVERT(bigint, value) FROM OPENJSON(@OutboxMessageIdsJson);
  IF NOT EXISTS(SELECT 1 FROM @Ids) THROW 52844, ''Zakljucek brez sporocil ni mogoc.'', 1;

  BEGIN TRAN;

  /* Lease mora biti nas. Brez tega bi worker, ki mu je lease potekel in ga je medtem
     prevzel drug, zakljucil tuj poskus. */
  IF EXISTS
  (
    SELECT 1 FROM @Ids AS candidate
    LEFT JOIN out.OutboxMessage AS message WITH(UPDLOCK, ROWLOCK)
      ON message.OutboxMessageId = candidate.OutboxMessageId
      AND message.Status = N''Sending'' AND message.LeaseOwner = @WorkerId AND message.LeaseUntilUtc >= SYSUTCDATETIME()
    WHERE message.OutboxMessageId IS NULL
  )
  BEGIN ROLLBACK; THROW 52845, ''Lease ni veljaven za vsa sporocila dokumenta.'', 1; END;

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

  /* Sifro, ki jo je SAOP dodelil ob ADD, zapisemo prek obstojece poti iz migracije 046. */
  IF @Succeeded = 1 AND NULLIF(@AssignedItemId, N'''') IS NOT NULL
  BEGIN
    DECLARE @FirstId bigint = (SELECT MIN(OutboxMessageId) FROM @Ids);
    DECLARE @Method nvarchar(40), @Assigned nvarchar(200);
    EXEC out.ResolveSaopItemAssignment
      @OutboxMessageId = @FirstId, @ResponseItemId = @AssignedItemId, @RequestedIdentifier = NULL,
      @EAN = NULL, @Actor = @WorkerId, @MatchMethod = @Method OUTPUT, @AssignedSaopItemId = @Assigned OUTPUT;
  END;

  /* Ob napaki poverilnice se kanal ustavi in nastane en alarm na integracijo, ne na artikel. */
  IF @Succeeded = 0 AND @ErrorClass = N''AuthConfig''
  BEGIN
    DECLARE @OrganizationId int = (SELECT TOP(1) message.OrganizationId FROM out.OutboxMessage AS message
      INNER JOIN @Ids AS candidate ON candidate.OutboxMessageId = message.OutboxMessageId);
    UPDATE dbo.IntegrationProfile SET IsEnabled = 0, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = N''out.CompleteItemDocument''
    WHERE OrganizationId = @OrganizationId AND TargetKind = N''SAOP_PRODUCT'' AND IsEnabled = 1;
  END;

  COMMIT;
END;');

/* --- 6) Pregled skupine ------------------------------------------------- */

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetOutboundBatches @OrganizationId int, @Top int = 50
AS
BEGIN
  SET NOCOUNT ON;
  SELECT TOP(@Top)
    batch.OutboundBatchId, batch.Source, batch.Note, batch.CreatedBy, batch.CreatedUtc, batch.ClosedUtc,
    Artiklov = COUNT(DISTINCT message.EntityKey),
    Sporocil = COUNT(message.OutboxMessageId),
    CakaOdobritev = SUM(CASE WHEN message.Status = N''PendingApproval'' THEN 1 ELSE 0 END),
    VVrsti = SUM(CASE WHEN message.Status IN (N''Pending'', N''Retry'', N''Sending'') THEN 1 ELSE 0 END),
    Poslanih = SUM(CASE WHEN message.Status IN (N''Sent'', N''Verified'', N''Superseded'') THEN 1 ELSE 0 END),
    Napak = SUM(CASE WHEN message.Status IN (N''Dead'', N''Error'', N''Drift'') THEN 1 ELSE 0 END)
  FROM out.OutboundBatch AS batch
  LEFT JOIN out.OutboxMessage AS message ON message.OutboundBatchId = batch.OutboundBatchId
  WHERE batch.OrganizationId = @OrganizationId
  GROUP BY batch.OutboundBatchId, batch.Source, batch.Note, batch.CreatedBy, batch.CreatedUtc, batch.ClosedUtc
  ORDER BY batch.OutboundBatchId DESC;
END;');

/* --- 7) Preverbe -------------------------------------------------------- */

IF OBJECT_ID(N'out.EnqueueSaopItemChange', N'P') IS NULL
  THROW 52846, 'Proizvajalec odhodnih sprememb ni nastal.', 1;

IF OBJECT_ID(N'out.ClaimItemDocument', N'P') IS NULL OR OBJECT_ID(N'out.CompleteItemDocument', N'P') IS NULL
  THROW 52847, 'Prevzem ali zakljucek dokumenta ni nastal.', 1;

/* Prevzem po artiklu je smiseln samo, ce pozna pogodbo dokumenta iz migracije 081. */
IF OBJECT_ID(N'out.SaopXmlField', N'U') IS NULL
  THROW 52848, 'Pogodba dokumenta iz migracije 081 manjka.', 1;
