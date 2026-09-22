SET XACT_ABORT ON;

EXEC(N'CREATE OR ALTER PROCEDURE out.EnqueueMessage
  @OrganizationId int, @TargetKind nvarchar(100), @Operation nvarchar(100),
  @EntityType nvarchar(100), @PayloadJson nvarchar(max), @Actor nvarchar(200), @OutboxMessageId bigint OUTPUT
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  DECLARE @EntityKey nvarchar(450), @Field nvarchar(200), @Value nvarchar(4000), @Qualifier nvarchar(450),
    @CanonicalPayload nvarchar(max), @PayloadHash char(64), @Status nvarchar(30), @PropertyCount int;
  IF NULLIF(LTRIM(RTRIM(@Actor)),N'''') IS NULL THROW 51006, ''Akter je obvezen.'', 1;
  IF NULLIF(LTRIM(RTRIM(@Operation)),N'''') IS NULL THROW 51007, ''Operacija je obvezna.'', 1;
  IF ISJSON(@PayloadJson)<>1 OR JSON_QUERY(@PayloadJson,N''$'') IS NULL THROW 51000, ''PayloadJson mora biti JSON objekt.'', 1;
  SELECT @PropertyCount=COUNT(*) FROM OPENJSON(@PayloadJson);
  IF @PropertyCount NOT IN(3,4) OR EXISTS(SELECT 1 FROM OPENJSON(@PayloadJson) WHERE [key] NOT IN(N''entityKey'',N''field'',N''value'',N''qualifier''))
    OR (SELECT COUNT(*) FROM OPENJSON(@PayloadJson) WHERE [key]=N''entityKey'' AND [type]=1)<>1
    OR (SELECT COUNT(*) FROM OPENJSON(@PayloadJson) WHERE [key]=N''field'' AND [type]=1)<>1
    OR (SELECT COUNT(*) FROM OPENJSON(@PayloadJson) WHERE [key]=N''value'' AND [type]=1)<>1
    OR (SELECT COUNT(*) FROM OPENJSON(@PayloadJson) WHERE [key]=N''qualifier'')>1
    OR EXISTS(SELECT 1 FROM OPENJSON(@PayloadJson) WHERE [key]=N''qualifier'' AND [type]<>1)
    THROW 51008, ''PayloadJson ne ustreza dovoljeni pogodbi odhodne spremembe.'', 1;
  SELECT @EntityKey=JSON_VALUE(@PayloadJson,N''$.entityKey''),@Field=JSON_VALUE(@PayloadJson,N''$.field''),@Value=JSON_VALUE(@PayloadJson,N''$.value''),@Qualifier=JSON_VALUE(@PayloadJson,N''$.qualifier'');
  IF NULLIF(LTRIM(RTRIM(@EntityKey)),N'''') IS NULL OR NULLIF(LTRIM(RTRIM(@Field)),N'''') IS NULL OR @Value IS NULL
    THROW 51009, ''PayloadJson vsebuje manjkajočo obvezno vrednost.'', 1;
  SELECT @Status=CASE WHEN ApprovalMode=N''Automatic'' THEN N''Pending'' ELSE N''PendingApproval'' END
  FROM dbo.IntegrationProfile WHERE OrganizationId=@OrganizationId AND TargetKind=@TargetKind AND IsEnabled=1;
  IF @Status IS NULL THROW 51001, ''Integracijski profil ni omogočen.'', 1;
  IF NOT EXISTS
  (
    SELECT 1 FROM out.OwnershipPolicy policy
    WHERE policy.OrganizationId=@OrganizationId AND policy.TargetKind=@TargetKind AND policy.EntityType=@EntityType
      AND policy.FieldName=@Field AND policy.Owner=N''PIM'' AND policy.IsEnabled=1
      AND (policy.ConstraintKind IS NULL
        OR (policy.ConstraintKind=N''PriceList'' AND policy.ConstraintValue=@Qualifier)
        OR (policy.ConstraintKind=N''ExactValue'' AND policy.ConstraintValue=@Value))
  ) THROW 51010, ''Polje ni dovoljeno za PIM odhodno spremembo.'', 1;
  SELECT @CanonicalPayload=(SELECT @EntityKey AS [entityKey],@Field AS [field],@Value AS [value],@Qualifier AS [qualifier] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
  SET @PayloadHash=CONVERT(char(64),HASHBYTES(''SHA2_256'',CONVERT(varbinary(max),@CanonicalPayload)),2);
  BEGIN TRY
    INSERT out.OutboxMessage(OrganizationId,TargetKind,Operation,EntityType,EntityKey,FieldSummary,PayloadJson,PayloadHash,ExpectedEchoHash,DedupKey,Status,NextAttemptUtc,CreatedBy)
    VALUES(@OrganizationId,@TargetKind,@Operation,@EntityType,@EntityKey,@Field,@CanonicalPayload,@PayloadHash,@PayloadHash,@PayloadHash,@Status,
      CASE WHEN @Status=N''Pending'' THEN DATEADD(millisecond,-1,SYSUTCDATETIME()) END,@Actor);
    SET @OutboxMessageId=SCOPE_IDENTITY();
  END TRY
  BEGIN CATCH
    IF ERROR_NUMBER() IN(2601,2627)
    BEGIN
      SELECT @OutboxMessageId=OutboxMessageId FROM out.OutboxMessage
      WHERE OrganizationId=@OrganizationId AND DedupKey=@PayloadHash AND Status IN(N''PendingApproval'',N''Pending'',N''Sending'',N''Sent'',N''Error'',N''Retry'');
      RETURN;
    END;
    THROW;
  END CATCH;
END;');

EXEC(N'CREATE OR ALTER PROCEDURE out.ClaimMessage @WorkerId nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON; BEGIN TRAN;
  DECLARE @Now datetime2(3)=SYSUTCDATETIME();
  DECLARE @Recovered TABLE(OutboxMessageId bigint NOT NULL,AttemptNumber int NOT NULL);
  ;WITH expired AS
  (
    SELECT TOP(1) message.*,profile.MaxAttempts FROM out.OutboxMessage message WITH(UPDLOCK,READPAST,ROWLOCK)
    INNER JOIN dbo.IntegrationProfile profile ON profile.OrganizationId=message.OrganizationId AND profile.TargetKind=message.TargetKind AND profile.IsEnabled=1
    WHERE message.Status=N''Sending'' AND message.LeaseUntilUtc<=@Now
    ORDER BY message.LeaseUntilUtc,message.OutboxMessageId
  )
  UPDATE expired SET Status=CASE WHEN AttemptCount>=MaxAttempts THEN N''Dead'' ELSE N''Retry'' END,
    NextAttemptUtc=CASE WHEN AttemptCount>=MaxAttempts THEN NULL ELSE @Now END,LeaseOwner=NULL,LeaseUntilUtc=NULL,
    LastError=N''Lease je potekel; poskus je bil varno zaključen za ponovno obdelavo.'',UpdatedUtc=@Now
  OUTPUT inserted.OutboxMessageId,deleted.AttemptCount INTO @Recovered;
  UPDATE attempt SET Outcome=CASE WHEN message.Status=N''Dead'' THEN N''Dead'' ELSE N''Retry'' END,CompletedUtc=@Now,
    FailureReason=N''Lease je potekel pred zaključkom workerja.''
  FROM out.OutboxAttempt attempt INNER JOIN @Recovered recovered ON recovered.OutboxMessageId=attempt.OutboxMessageId AND recovered.AttemptNumber=attempt.AttemptNumber
    INNER JOIN out.OutboxMessage message ON message.OutboxMessageId=attempt.OutboxMessageId
  WHERE attempt.Outcome=N''Sending'';
  DECLARE @Claimed TABLE(OutboxMessageId bigint);
  ;WITH candidate AS
  (
    SELECT TOP(1) message.*,profile.TimeoutSeconds FROM out.OutboxMessage message WITH(UPDLOCK,READPAST,ROWLOCK)
    INNER JOIN dbo.IntegrationProfile profile ON profile.OrganizationId=message.OrganizationId AND profile.TargetKind=message.TargetKind AND profile.IsEnabled=1
    WHERE message.Status IN(N''Pending'',N''Retry'') AND (message.NextAttemptUtc IS NULL OR message.NextAttemptUtc<=@Now)
    ORDER BY message.OutboxMessageId
  )
  UPDATE candidate SET Status=N''Sending'',AttemptCount=AttemptCount+1,LeaseOwner=@WorkerId,
    LeaseUntilUtc=DATEADD(second,TimeoutSeconds+30,@Now),UpdatedUtc=@Now
  OUTPUT inserted.OutboxMessageId INTO @Claimed;
  INSERT out.OutboxAttempt(OutboxMessageId,AttemptNumber,WorkerId)
  SELECT message.OutboxMessageId,message.AttemptCount,@WorkerId FROM out.OutboxMessage message INNER JOIN @Claimed claimed ON claimed.OutboxMessageId=message.OutboxMessageId;
  SELECT message.*,profile.EndpointTemplate,profile.HttpOperation,profile.TimeoutSeconds,profile.MaxAttempts,profile.BaseRetrySeconds
  FROM out.OutboxMessage message INNER JOIN @Claimed claimed ON claimed.OutboxMessageId=message.OutboxMessageId
  INNER JOIN dbo.IntegrationProfile profile ON profile.OrganizationId=message.OrganizationId AND profile.TargetKind=message.TargetKind;
  COMMIT;
END;');

EXEC(N'CREATE OR ALTER PROCEDURE out.CompleteAttempt
  @OutboxMessageId bigint,@WorkerId nvarchar(200),@Succeeded bit,@PermanentFailure bit,
  @ResponseStatusCode int=NULL,@ResponseBodyRedacted nvarchar(4000)=NULL,@ResponseCorrelationId nvarchar(200)=NULL,@FailureReason nvarchar(2000)=NULL
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON; BEGIN TRAN;
  DECLARE @Attempt int,@MaxAttempts int,@BaseRetrySeconds int,@Status nvarchar(30);
  SELECT @Attempt=message.AttemptCount,@MaxAttempts=profile.MaxAttempts,@BaseRetrySeconds=profile.BaseRetrySeconds
  FROM out.OutboxMessage message WITH(UPDLOCK,ROWLOCK) INNER JOIN dbo.IntegrationProfile profile ON profile.OrganizationId=message.OrganizationId AND profile.TargetKind=message.TargetKind
  WHERE message.OutboxMessageId=@OutboxMessageId AND message.Status=N''Sending'' AND message.LeaseOwner=@WorkerId;
  IF @Attempt IS NULL BEGIN ROLLBACK; THROW 51005, ''Lease ni veljaven.'', 1; END;
  SET @Status=CASE WHEN @Succeeded=1 THEN N''Sent'' WHEN @PermanentFailure=1 OR @Attempt>=@MaxAttempts THEN N''Dead'' ELSE N''Retry'' END;
  UPDATE out.OutboxMessage SET Status=@Status,SentUtc=CASE WHEN @Status=N''Sent'' THEN SYSUTCDATETIME() ELSE SentUtc END,
    NextAttemptUtc=CASE WHEN @Status=N''Retry'' THEN DATEADD(second,@BaseRetrySeconds*CONVERT(int,POWER(CONVERT(float,2),@Attempt-1)),SYSUTCDATETIME()) END,
    LeaseOwner=NULL,LeaseUntilUtc=NULL,LastError=@FailureReason,ResponseStatusCode=@ResponseStatusCode,ResponseBodyRedacted=@ResponseBodyRedacted,ResponseCorrelationId=@ResponseCorrelationId,UpdatedUtc=SYSUTCDATETIME()
  WHERE OutboxMessageId=@OutboxMessageId;
  UPDATE out.OutboxAttempt SET Outcome=@Status,CompletedUtc=SYSUTCDATETIME(),ResponseStatusCode=@ResponseStatusCode,ResponseBodyRedacted=@ResponseBodyRedacted,ResponseCorrelationId=@ResponseCorrelationId,FailureReason=@FailureReason
  WHERE OutboxMessageId=@OutboxMessageId AND AttemptNumber=@Attempt AND WorkerId=@WorkerId AND Outcome=N''Sending'';
  COMMIT;
END;');
