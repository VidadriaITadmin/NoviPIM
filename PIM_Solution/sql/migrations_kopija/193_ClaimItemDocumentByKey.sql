/*
  193 — out.ClaimItemDocumentByKey: prevzem enega DOLOCENEGA artikla, ne najstarejsega v vrsti.

  Uporabnik je opozoril, da posiljanje iz vmesnika (klik "Odobri" ali "Poslji zdaj" na eni
  vrstici) prevzame najstarejsi artikel v CELI vrsti (out.ClaimItemDocument, migracija 084) —
  ne tistega, ki ga je uporabnik pravkar odobril ali oznacil. Za avtomatiziran worker, ki
  prazni vrsto v ozadju, je to pravilno (pravicno, po vrstnem redu). Za klik na eno vrstico v
  vmesniku pa uporabnik pricakuje natanko to, kar je izbral.

  Ta procedura je enaka out.ClaimItemDocument, samo da namesto TOP(1) po CreatedUtc / OutboxMessageId
  po celi vrsti prevzame vsa cakajoca sporocila DANEGA artikla (organizacija + sifra). Ce jih
  ni (npr. drug proces jih je ravnokar prevzel), vrne prazno — natanko tako, kot ce v vrsti ne
  bi bilo nicesar za ta artikel.

  out.ClaimItemDocument (za worker CLI/ozadje) ostane nedotaknjen.
*/

SET XACT_ABORT ON;

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
      AND message.Status IN (N''Pending'', N''Retry'')
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

IF OBJECT_ID(N'out.ClaimItemDocumentByKey', N'P') IS NULL
  THROW 51491, N'193: out.ClaimItemDocumentByKey manjka.', 1;
