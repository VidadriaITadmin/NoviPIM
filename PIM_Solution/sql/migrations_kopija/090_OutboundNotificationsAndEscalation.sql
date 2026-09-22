/*
  090 — obvestila po korakih odhodne poti in stopnjevanje na e-posto.

  Zahteva: vsak korak mora pustiti sled. Ce je vse v redu, je obvestilo tiho. Ce je napaka,
  mora biti vidna in sporocena uporabniku z natancnim navodilom. Ce uporabnik pet minut ne
  reagira, mu je treba poslati e-posto. Naslov se dobi na strani Uporabniki.

  Kaj je ze obstajalo in se NE podvaja:
    ops.Alert + ops.AlertDelivery + ops.AlertRecipientConfig (migracija 025) — dedup, resnost,
    lease, ponovni poskusi in kanal Email so ze tam in preverjeni. Stopnjevanje zato ne gradi
    svoje dostave, ampak uporabi to.

  Kaj manjka in nastane tukaj:

  1) sec.LocalUser.Email — uporabniki danes nimajo naslova. Brez njega ni komu pisati.

  2) ops.OutboundEvent — sled po korakih. Alarm ni isto kot obvestilo: alarm je zdruzen po
     dedup kljucu in pove "nekaj je narobe s to potjo", obvestilo pa je vezano na konkreten
     artikel in konkretno polje in pove, kaj naj uporabnik naredi. Za tiho potrditev uspeha
     alarm sploh ni primeren — ustvaril bi hrup, ki bi ubil zaupanje v prave alarme.

  3) Stopnjevanje. Napaka, ki je uporabnik pet minut ne potrdi, postane alarm in gre v vrsto za
     e-posto. Prag je nastavljiv, ne v kodi.

  Zakaj se obvestilo zapise v bazi in ne v aplikaciji: da se ga ne da pozabiti. Vsaka pot, ki
  zakljuci odhodni dokument, gre skozi out.CompleteItemDocument; ce obvestilo nastane tam, ga
  ni mogoce obiti z novim klicateljem.

  Migrator ne pozna locila GO; procedure so v EXEC(N'...').
*/

SET XACT_ABORT ON;

/* --- 1) Uporabnik ima naslov -------------------------------------------- */

IF COL_LENGTH(N'sec.LocalUser', N'Email') IS NULL
  ALTER TABLE sec.LocalUser ADD Email nvarchar(320) NULL;

/* --- 2) Sled po korakih ------------------------------------------------- */

IF OBJECT_ID(N'ops.OutboundEvent', N'U') IS NULL
BEGIN
  CREATE TABLE ops.OutboundEvent
  (
    OutboundEventId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_OutboundEvent PRIMARY KEY,
    OrganizationId int NOT NULL,
    OutboundBatchId bigint NULL,
    OutboxMessageId bigint NULL,
    EntityType nvarchar(100) NOT NULL,
    EntityKey nvarchar(450) NOT NULL,
    /* Korak poti; vsak od njih je nekaj, kar uporabnik lahko vidi in razume. */
    Step nvarchar(30) NOT NULL,
    Severity nvarchar(20) NOT NULL,
    Title nvarchar(300) NOT NULL,
    /* Navodilo, ne surov izpis. Pri napaki je to prevod sporocila SAOP. */
    Detail nvarchar(2000) NULL,
    FieldName nvarchar(200) NULL,
    ActorUserName nvarchar(200) NULL,
    CreatedUtc datetime2(3) NOT NULL CONSTRAINT DF_OutboundEvent_CreatedUtc DEFAULT SYSUTCDATETIME(),
    /* Dokler je NULL in je resnost Error, ura za stopnjevanje tece. */
    AcknowledgedUtc datetime2(3) NULL,
    AcknowledgedBy nvarchar(200) NULL,
    EscalatedUtc datetime2(3) NULL,
    CONSTRAINT FK_OutboundEvent_Organization FOREIGN KEY (OrganizationId) REFERENCES dbo.OrganizationConfig(OrganizationId),
    CONSTRAINT CK_OutboundEvent_Step CHECK (Step IN
      (N'Queued', N'Approved', N'Cancelled', N'Sent', N'Verified', N'Drift', N'Failed', N'SelfHealed')),
    CONSTRAINT CK_OutboundEvent_Severity CHECK (Severity IN (N'Info', N'Warning', N'Error'))
  );
END;

/* Zvoncek bere neprebrane napake; stopnjevanje bere nepotrjene starejse od praga. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'ops.OutboundEvent') AND name = N'IX_OutboundEvent_Open')
  CREATE INDEX IX_OutboundEvent_Open ON ops.OutboundEvent(OrganizationId, Severity, AcknowledgedUtc, CreatedUtc)
  INCLUDE (EntityKey, Title, EscalatedUtc);

EXEC(N'
CREATE OR ALTER PROCEDURE ops.RecordOutboundEvent
  @OrganizationId int, @EntityType nvarchar(100), @EntityKey nvarchar(450),
  @Step nvarchar(30), @Severity nvarchar(20), @Title nvarchar(300),
  @Detail nvarchar(2000) = NULL, @FieldName nvarchar(200) = NULL,
  @OutboundBatchId bigint = NULL, @OutboxMessageId bigint = NULL, @Actor nvarchar(200) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  INSERT ops.OutboundEvent
    (OrganizationId, OutboundBatchId, OutboxMessageId, EntityType, EntityKey, Step, Severity, Title, Detail, FieldName, ActorUserName)
  VALUES
    (@OrganizationId, @OutboundBatchId, @OutboxMessageId, @EntityType, @EntityKey, @Step, @Severity, @Title, @Detail, @FieldName, @Actor);
END;');

/* --- 3) Obvestilo nastane tam, kjer se korak konca ---------------------- */

/*
  out.CompleteItemDocument iz migracije 084, dopolnjen z zapisom obvestila. Telo je enako;
  dodan je samo zadnji odstavek. Obvestilo nastane v isti transakciji kot sprememba stanja,
  zato ne more biti stanja brez sledi.
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

  IF @Succeeded = 1 AND NULLIF(@AssignedItemId, N'''') IS NOT NULL
  BEGIN
    DECLARE @FirstId bigint = (SELECT MIN(OutboxMessageId) FROM @Ids);
    DECLARE @Method nvarchar(40), @Assigned nvarchar(200);
    EXEC out.ResolveSaopItemAssignment
      @OutboxMessageId = @FirstId, @ResponseItemId = @AssignedItemId, @RequestedIdentifier = NULL,
      @EAN = NULL, @Actor = @WorkerId, @MatchMethod = @Method OUTPUT, @AssignedSaopItemId = @Assigned OUTPUT;
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
     dogaja, a ni treba nicesar narediti. */
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
    /* Polj je lahko vec; kadar so, se nastejejo, da uporabnik ve, cesa se obvestilo tice. */
    (SELECT STRING_AGG(vsa.FieldSummary, N'', '') FROM out.OutboxMessage AS vsa
      INNER JOIN @Ids AS vsi ON vsi.OutboxMessageId = vsa.OutboxMessageId),
    @WorkerId
  FROM out.OutboxMessage AS message
  INNER JOIN @Ids AS candidate ON candidate.OutboxMessageId = message.OutboxMessageId
  ORDER BY message.OutboxMessageId;

  COMMIT;
END;');

/* --- 4) Stopnjevanje na e-posto ----------------------------------------- */

/*
  Prejemniki so uporabniki z naslovom in z vlogo, ki je za to odgovorna. Vzdrzevanje seznama
  na dveh mestih bi pomenilo, da nekdo dobi pravico in ne dobi obvestil; zato se prejemniki
  izpeljejo iz uporabnikov, ne vpisujejo rocno.
*/
EXEC(N'
CREATE OR ALTER PROCEDURE ops.SyncAlertRecipientsFromUsers
  @RoleName nvarchar(100) = N''ADMIN'', @MinimumSeverity nvarchar(20) = N''Warning'', @Actor nvarchar(200) = N''ops.Sync''
AS
BEGIN
  SET NOCOUNT ON;
  MERGE ops.AlertRecipientConfig AS target
  USING
  (
    SELECT DISTINCT organization.OrganizationId, @RoleName AS RoleName, N''Email'' AS Channel,
      LTRIM(RTRIM(uporabnik.Email)) AS RecipientKey
    FROM dbo.OrganizationConfig AS organization
    CROSS JOIN sec.LocalUser AS uporabnik
    INNER JOIN sec.LocalUserRole AS povezava ON povezava.LocalUserId = uporabnik.LocalUserId
    INNER JOIN sec.Role AS vloga ON vloga.RoleId = povezava.RoleId AND vloga.RoleCode = @RoleName
    WHERE uporabnik.IsEnabled = 1 AND NULLIF(LTRIM(RTRIM(uporabnik.Email)), N'''') IS NOT NULL
  ) AS source
    ON target.OrganizationId = source.OrganizationId AND target.Channel = source.Channel
      AND target.RecipientKey = source.RecipientKey
  WHEN MATCHED THEN UPDATE SET IsEnabled = 1, MinimumSeverity = @MinimumSeverity,
    UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = @Actor
  WHEN NOT MATCHED THEN INSERT (OrganizationId, RoleName, Channel, RecipientKey, MinimumSeverity, IsEnabled, UpdatedBy)
    VALUES (source.OrganizationId, source.RoleName, source.Channel, source.RecipientKey, @MinimumSeverity, 1, @Actor);

  SELECT Prejemnikov = COUNT(*) FROM ops.AlertRecipientConfig WHERE Channel = N''Email'' AND IsEnabled = 1;
END;');

/*
  Napaka, ki je uporabnik po pragu (privzeto 5 minut) ni potrdil, postane alarm in gre v vrsto
  za e-posto. Prag je parameter, ne konstanta v kodi.

  Zakaj prek ops.Alert in ne z lastno vrsto: dostava, ponovni poskusi, lease in mrtve dostave
  so tam ze resene in preverjene (migracija 025). Druga vrsta bi pomenila druga pravila
  ponavljanja in drugo mesto, kjer se da izgubiti sporocilo.
*/
EXEC(N'
CREATE OR ALTER PROCEDURE ops.EscalateOutboundEvents
  @AfterSeconds int = 300, @Actor nvarchar(200) = N''ops.Escalate''
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  DECLARE @Prag datetime2(3) = DATEADD(second, -@AfterSeconds, SYSUTCDATETIME());

  DECLARE @ZaStopnjevanje TABLE
  (
    OutboundEventId bigint PRIMARY KEY, OrganizationId int, EntityKey nvarchar(450),
    Title nvarchar(300), Detail nvarchar(2000), FieldName nvarchar(200)
  );

  UPDATE dogodek SET EscalatedUtc = SYSUTCDATETIME()
  OUTPUT inserted.OutboundEventId, inserted.OrganizationId, inserted.EntityKey,
         inserted.Title, inserted.Detail, inserted.FieldName INTO @ZaStopnjevanje
  FROM ops.OutboundEvent AS dogodek
  WHERE dogodek.Severity = N''Error'' AND dogodek.AcknowledgedUtc IS NULL
    AND dogodek.EscalatedUtc IS NULL AND dogodek.CreatedUtc <= @Prag;

  IF NOT EXISTS(SELECT 1 FROM @ZaStopnjevanje) BEGIN SELECT Stopnjevanih = 0; RETURN; END;

  DECLARE @EventId bigint, @OrganizationId int, @EntityKey nvarchar(450),
          @Title nvarchar(300), @Detail nvarchar(2000), @FieldName nvarchar(200);

  DECLARE dogodki CURSOR LOCAL FAST_FORWARD FOR
    SELECT OutboundEventId, OrganizationId, EntityKey, Title, Detail, FieldName FROM @ZaStopnjevanje;
  OPEN dogodki;
  FETCH NEXT FROM dogodki INTO @EventId, @OrganizationId, @EntityKey, @Title, @Detail, @FieldName;

  WHILE @@FETCH_STATUS = 0
  BEGIN
    /* Dedup po dogodku: isti dogodek ne sme poslati dveh e-post. */
    DECLARE @DedupKey varchar(64) =
      CONVERT(varchar(64), HASHBYTES(''SHA2_256'', CONCAT(N''outbound-event:'', @EventId)), 2);

    EXEC ops.UpsertAlert
      @OrganizationId = @OrganizationId, @Pipeline = N''OUTBOUND'', @AlertKind = N''OutboundUnacknowledged'',
      @Severity = N''Critical'', @DedupKey = @DedupKey,
      @Title = @Title,
      @PayloadSummaryRedacted = @Detail,
      @Actor = @Actor;

    FETCH NEXT FROM dogodki INTO @EventId, @OrganizationId, @EntityKey, @Title, @Detail, @FieldName;
  END;

  CLOSE dogodki;
  DEALLOCATE dogodki;

  EXEC ops.QueueAlertDeliveries;
  SELECT Stopnjevanih = (SELECT COUNT(*) FROM @ZaStopnjevanje);
END;');

/* --- 5) Branje in potrditev v vmesniku ---------------------------------- */

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetOutboundEvents
  @OrganizationId int, @OnlyOpen bit = 0, @Top int = 100
AS
BEGIN
  SET NOCOUNT ON;
  SELECT TOP(@Top) OutboundEventId, OutboundBatchId, OutboxMessageId, EntityType, EntityKey,
    Step, Severity, Title, Detail, FieldName, CreatedUtc, AcknowledgedUtc, AcknowledgedBy, EscalatedUtc
  FROM ops.OutboundEvent
  WHERE OrganizationId = @OrganizationId
    AND (@OnlyOpen = 0 OR (Severity <> N''Info'' AND AcknowledgedUtc IS NULL))
  ORDER BY OutboundEventId DESC;
END;');

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetOutboundEventCounts @OrganizationId int
AS
BEGIN
  SET NOCOUNT ON;
  SELECT
    Napak = SUM(CASE WHEN Severity = N''Error'' AND AcknowledgedUtc IS NULL THEN 1 ELSE 0 END),
    Opozoril = SUM(CASE WHEN Severity = N''Warning'' AND AcknowledgedUtc IS NULL THEN 1 ELSE 0 END),
    Stopnjevanih = SUM(CASE WHEN EscalatedUtc IS NOT NULL AND AcknowledgedUtc IS NULL THEN 1 ELSE 0 END),
    TihihDanes = SUM(CASE WHEN Severity = N''Info'' AND CreatedUtc >= DATEADD(day, -1, SYSUTCDATETIME()) THEN 1 ELSE 0 END)
  FROM ops.OutboundEvent WHERE OrganizationId = @OrganizationId;
END;');

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.AcknowledgeOutboundEvent @OutboundEventId bigint, @Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  UPDATE ops.OutboundEvent
  SET AcknowledgedUtc = SYSUTCDATETIME(), AcknowledgedBy = @Actor
  WHERE OutboundEventId = @OutboundEventId AND AcknowledgedUtc IS NULL;
  IF @@ROWCOUNT <> 1 THROW 52901, ''Obvestila ni mogoce potrditi.'', 1;
END;');

/* Potrditev cele skupine: pri uvozu s stotinami vrstic je potrjevanje po eni neuporabno. */
EXEC(N'
CREATE OR ALTER PROCEDURE intranet.AcknowledgeOutboundBatchEvents @OutboundBatchId bigint, @Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON;
  UPDATE ops.OutboundEvent
  SET AcknowledgedUtc = SYSUTCDATETIME(), AcknowledgedBy = @Actor
  WHERE OutboundBatchId = @OutboundBatchId AND AcknowledgedUtc IS NULL;
  SELECT Potrjenih = @@ROWCOUNT;
END;');

/* --- 6) Preverbe -------------------------------------------------------- */

IF COL_LENGTH(N'sec.LocalUser', N'Email') IS NULL
  THROW 52902, 'Uporabniki nimajo naslova; stopnjevanje ne bi imelo komu pisati.', 1;

IF OBJECT_ID(N'ops.OutboundEvent', N'U') IS NULL OR OBJECT_ID(N'ops.RecordOutboundEvent', N'P') IS NULL
  THROW 52903, 'Sled po korakih odhodne poti ni nastala.', 1;

IF OBJECT_ID(N'ops.EscalateOutboundEvents', N'P') IS NULL OR OBJECT_ID(N'ops.SyncAlertRecipientsFromUsers', N'P') IS NULL
  THROW 52904, 'Stopnjevanje na e-posto ni nastalo.', 1;

/* Kanal Email mora biti dovoljen ze v shemi iz 025; ce ni, stopnjevanje ne bi imelo poti. */
IF NOT EXISTS
(
  SELECT 1 FROM sys.check_constraints
  WHERE name = N'CK_AlertDelivery_Channel' AND definition LIKE N'%Email%'
)
  THROW 52905, 'Kanal Email ni dovoljen v ops.AlertDelivery.', 1;
