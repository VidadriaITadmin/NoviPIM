/*
  195 — out.ClaimItemDocument / out.ClaimItemDocumentByKey ponovno prevzameta obticalo "Sending".

  Najden pri resnicnem posiljanju iz vmesnika (2026-09-11): klik "Odobri"/"Poslji zdaj" postavi
  90-sekundni lease in status 'Sending', nato poklice SAOP. Ce klic ne dokonca (casovna omejitev
  na strani vmesnika, padec povezave, ponovni zagon strežnika sredi klica) se out.CompleteItemDocument
  nikoli ne izvede — sporocilo ostane v 'Sending' TRAJNO, ker obe prevzemni proceduri (084, 193)
  isceta samo Status IN ('Pending','Retry'). Lease sam po sebi to ni resil: pogoj
  "LeaseUntilUtc < SYSUTCDATETIME()" je bil ze prisoten in bi obticalo vrstico pravilno spustil
  skozi — manjkalo je samo, da 'Sending' sploh pride v postev kot kandidat.

  Sporocilo iz TrySendBatchAsync/TrySendArticleAsync ("poskus bo ponovil naslednji zagon workerja")
  je bilo zato neresnicno: noben zagon ga ni nikoli pobral. Ta migracija popravi obe proceduri
  tako, da 'Sending' z zapadlim lease-om velja enako kot 'Pending'/'Retry' — ista zascita
  (LeaseUntilUtc < SYSUTCDATETIME()) ze preprecuje, da bi se ukradel se aktiven prevzem.

  Namerno NE popravlja ze obticalih vrstic z UPDATE — popravljena procedura jih ob naslednjem
  klicu prevzame sama, brez posebnega podatkovnega popravka.
*/

SET XACT_ABORT ON;

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
    AND message.Status IN (N''Pending'', N''Retry'', N''Sending'')
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
    AND message.Status IN (N''Pending'', N''Retry'', N''Sending'')
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

EXEC(N'
CREATE OR ALTER PROCEDURE out.ClaimItemDocumentByKey
  @WorkerId nvarchar(200), @LeaseSeconds int = 90, @OrganizationId int, @EntityKey nvarchar(450)
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON; BEGIN TRAN;

  IF NOT EXISTS
  (
    SELECT 1 FROM out.OutboxMessage AS message WITH (UPDLOCK, READPAST, ROWLOCK)
    WHERE message.OrganizationId = @OrganizationId AND message.EntityKey = @EntityKey
      AND message.TargetKind = N''SAOP_PRODUCT'' AND message.EntityType = N''Product''
      AND message.Status IN (N''Pending'', N''Retry'', N''Sending'')
      AND (message.NextAttemptUtc IS NULL OR message.NextAttemptUtc <= SYSUTCDATETIME())
      AND (message.LeaseUntilUtc IS NULL OR message.LeaseUntilUtc < SYSUTCDATETIME())
  )
  BEGIN COMMIT; RETURN; END;

  DECLARE @Claimed TABLE(OutboxMessageId bigint PRIMARY KEY);

  UPDATE message
  SET Status = N''Sending'', AttemptCount = message.AttemptCount + 1,
      LeaseOwner = @WorkerId, LeaseUntilUtc = DATEADD(second, @LeaseSeconds, SYSUTCDATETIME()),
      UpdatedUtc = SYSUTCDATETIME()
  OUTPUT inserted.OutboxMessageId INTO @Claimed
  FROM out.OutboxMessage AS message WITH (UPDLOCK, ROWLOCK)
  WHERE message.OrganizationId = @OrganizationId AND message.EntityKey = @EntityKey
    AND message.TargetKind = N''SAOP_PRODUCT'' AND message.EntityType = N''Product''
    AND message.Status IN (N''Pending'', N''Retry'', N''Sending'')
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

IF OBJECT_ID(N'out.ClaimItemDocument', N'P') IS NULL OR OBJECT_ID(N'out.ClaimItemDocumentByKey', N'P') IS NULL
  THROW 51492, N'195: prevzemni proceduri manjkata.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'out.ClaimItemDocument')) NOT LIKE N'%Sending%'
  THROW 51493, N'195: out.ClaimItemDocument se ne pobira obticalih Sending.', 1;
