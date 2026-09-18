/*
  196 — out.CompleteItemDocument ne sme vec padati na ops.OutboundEvent.FieldName.

  Najdeno pri resnicnem posiljanju (2026-09-11, po 195): dokument z 23 spremenjenimi polji je
  uspesno prisel do SAOP in nazaj, potem pa je out.CompleteItemDocument padel z
  "String or binary data would be truncated in table 'ops.OutboundEvent', column 'FieldName'."
  Vzrok: obvestilo za en dokument (migracija 090) v FieldName zdruzi imena VSEH spremenjenih
  polj s STRING_AGG — za dokument z dovolj polji je seznam dalj kot stolpec (nvarchar(200)).
  Ker se to zgodi ZNOTRAJ iste transakcije kot zakljucek sporocila, je padel cel zakljucek in je
  sporocilo ostalo obticalo v 'Sending' (razresi ga sele 195).

  Napaka ni bila odvisna od uspeha/neuspeha posiljanja — prizadel bi vsak dovolj velik dokument,
  ne glede na to, ali ga SAOP sprejme ali zavrne. Popravek: stolpec je sirsi (400 namesto 200) IN
  seznam polj se, ce je le potreben, obreze s stevilom preostalih polj namesto da se odreze sredi
  imena ali povzroci napako — tako se to ne more ponoviti tudi za se vecji dokument.
*/

SET XACT_ABORT ON;

IF (SELECT max_length FROM sys.columns WHERE object_id = OBJECT_ID(N'ops.OutboundEvent') AND name = N'FieldName') < 800
  ALTER TABLE ops.OutboundEvent ALTER COLUMN FieldName nvarchar(400) NULL;

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

IF (SELECT max_length FROM sys.columns WHERE object_id = OBJECT_ID(N'ops.OutboundEvent') AND name = N'FieldName') < 800
  THROW 51494, N'196: ops.OutboundEvent.FieldName ni razsirjen.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'out.CompleteItemDocument')) NOT LIKE N'%skupaj%'
  THROW 51495, N'196: out.CompleteItemDocument se ne obrezuje seznama polj.', 1;
