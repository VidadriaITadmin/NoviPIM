SET XACT_ABORT ON;

IF SCHEMA_ID(N'out') IS NULL EXEC(N'CREATE SCHEMA out');
IF SCHEMA_ID(N'intranet') IS NULL EXEC(N'CREATE SCHEMA intranet');

IF OBJECT_ID(N'dbo.IntegrationProfile', N'U') IS NULL
BEGIN
  CREATE TABLE dbo.IntegrationProfile
  (
    IntegrationProfileId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_IntegrationProfile PRIMARY KEY,
    OrganizationId int NOT NULL,
    TargetKind nvarchar(100) NOT NULL,
    EndpointTemplate nvarchar(2000) NULL,
    HttpOperation nvarchar(10) NULL,
    ApprovalMode nvarchar(30) NOT NULL CONSTRAINT DF_IntegrationProfile_ApprovalMode DEFAULT N'ManualApproval',
    IsEnabled bit NOT NULL CONSTRAINT DF_IntegrationProfile_IsEnabled DEFAULT (0),
    TimeoutSeconds int NOT NULL CONSTRAINT DF_IntegrationProfile_Timeout DEFAULT (30),
    MaxAttempts int NOT NULL CONSTRAINT DF_IntegrationProfile_MaxAttempts DEFAULT (5),
    BaseRetrySeconds int NOT NULL CONSTRAINT DF_IntegrationProfile_Retry DEFAULT (30),
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_IntegrationProfile_UpdatedUtc DEFAULT SYSUTCDATETIME(),
    UpdatedBy nvarchar(200) NOT NULL,
    CONSTRAINT UQ_IntegrationProfile_OrganizationTarget UNIQUE (OrganizationId, TargetKind),
    CONSTRAINT FK_IntegrationProfile_Organization FOREIGN KEY (OrganizationId) REFERENCES dbo.OrganizationConfig(OrganizationId),
    CONSTRAINT CK_IntegrationProfile_ApprovalMode CHECK (ApprovalMode IN (N'ManualApproval', N'Automatic')),
    CONSTRAINT CK_IntegrationProfile_Operation CHECK (HttpOperation IS NULL OR HttpOperation IN (N'POST', N'PATCH')),
    CONSTRAINT CK_IntegrationProfile_Retry CHECK (TimeoutSeconds BETWEEN 1 AND 300 AND MaxAttempts BETWEEN 1 AND 20 AND BaseRetrySeconds BETWEEN 1 AND 86400),
    CONSTRAINT CK_IntegrationProfile_EnabledContract CHECK (IsEnabled = 0 OR (EndpointTemplate IS NOT NULL AND HttpOperation IN (N'POST', N'PATCH')))
  );
END;

IF OBJECT_ID(N'out.OwnershipPolicy', N'U') IS NULL
BEGIN
  CREATE TABLE out.OwnershipPolicy
  (
    OwnershipPolicyId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_OwnershipPolicy PRIMARY KEY,
    OrganizationId int NOT NULL,
    TargetKind nvarchar(100) NOT NULL,
    EntityType nvarchar(100) NOT NULL,
    FieldName nvarchar(200) NOT NULL,
    Owner nvarchar(20) NOT NULL,
    ConstraintKind nvarchar(30) NULL,
    ConstraintValue nvarchar(450) NULL,
    IsEnabled bit NOT NULL CONSTRAINT DF_OwnershipPolicy_IsEnabled DEFAULT (0),
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_OwnershipPolicy_UpdatedUtc DEFAULT SYSUTCDATETIME(),
    UpdatedBy nvarchar(200) NOT NULL,
    CONSTRAINT UQ_OwnershipPolicy_Field UNIQUE (OrganizationId, TargetKind, EntityType, FieldName, ConstraintValue),
    CONSTRAINT FK_OwnershipPolicy_Organization FOREIGN KEY (OrganizationId) REFERENCES dbo.OrganizationConfig(OrganizationId),
    CONSTRAINT CK_OwnershipPolicy_Owner CHECK (Owner IN (N'PIM', N'SAOP')),
    CONSTRAINT CK_OwnershipPolicy_Constraint CHECK (ConstraintKind IS NULL OR ConstraintKind IN (N'PriceList', N'ExactValue'))
  );
END;

IF OBJECT_ID(N'out.OutboxMessage', N'U') IS NULL
BEGIN
  CREATE TABLE out.OutboxMessage
  (
    OutboxMessageId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_OutboxMessage PRIMARY KEY,
    OrganizationId int NOT NULL,
    TargetKind nvarchar(100) NOT NULL,
    Operation nvarchar(100) NOT NULL,
    EntityType nvarchar(100) NOT NULL,
    EntityKey nvarchar(450) NOT NULL,
    FieldSummary nvarchar(1000) NOT NULL,
    PayloadJson nvarchar(max) NOT NULL,
    PayloadHash char(64) NOT NULL,
    ExpectedEchoHash char(64) NOT NULL,
    DedupKey varchar(64) NOT NULL,
    Status nvarchar(30) NOT NULL,
    CorrelationId uniqueidentifier NOT NULL CONSTRAINT DF_OutboxMessage_Correlation DEFAULT NEWID(),
    AttemptCount int NOT NULL CONSTRAINT DF_OutboxMessage_AttemptCount DEFAULT (0),
    NextAttemptUtc datetime2(3) NULL,
    LeaseOwner nvarchar(200) NULL,
    LeaseUntilUtc datetime2(3) NULL,
    LastError nvarchar(2000) NULL,
    ResponseStatusCode int NULL,
    ResponseBodyRedacted nvarchar(4000) NULL,
    ResponseCorrelationId nvarchar(200) NULL,
    DriftDetail nvarchar(2000) NULL,
    CreatedUtc datetime2(3) NOT NULL CONSTRAINT DF_OutboxMessage_CreatedUtc DEFAULT SYSUTCDATETIME(),
    CreatedBy nvarchar(200) NOT NULL,
    ApprovedUtc datetime2(3) NULL,
    ApprovedBy nvarchar(200) NULL,
    SentUtc datetime2(3) NULL,
    VerifiedUtc datetime2(3) NULL,
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_OutboxMessage_UpdatedUtc DEFAULT SYSUTCDATETIME(),
    CONSTRAINT FK_OutboxMessage_Organization FOREIGN KEY (OrganizationId) REFERENCES dbo.OrganizationConfig(OrganizationId),
    CONSTRAINT CK_OutboxMessage_Status CHECK (Status IN (N'PendingApproval', N'Pending', N'Sending', N'Sent', N'Verified', N'Error', N'Retry', N'Dead', N'Cancelled', N'Drift')),
    CONSTRAINT CK_OutboxMessage_PayloadJson CHECK (ISJSON(PayloadJson) = 1),
    CONSTRAINT CK_OutboxMessage_AttemptCount CHECK (AttemptCount >= 0),
    CONSTRAINT CK_OutboxMessage_Lease CHECK ((LeaseOwner IS NULL AND LeaseUntilUtc IS NULL) OR (LeaseOwner IS NOT NULL AND LeaseUntilUtc IS NOT NULL))
  );
END;

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'out.OutboxMessage') AND name = N'UX_OutboxMessage_ActiveDedup')
  CREATE UNIQUE INDEX UX_OutboxMessage_ActiveDedup ON out.OutboxMessage(OrganizationId, DedupKey)
  WHERE Status IN (N'PendingApproval', N'Pending', N'Sending', N'Sent', N'Error', N'Retry');

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'out.OutboxMessage') AND name = N'IX_OutboxMessage_Dispatch')
  CREATE INDEX IX_OutboxMessage_Dispatch ON out.OutboxMessage(Status, NextAttemptUtc, LeaseUntilUtc, OutboxMessageId);

IF OBJECT_ID(N'out.OutboxAttempt', N'U') IS NULL
BEGIN
  CREATE TABLE out.OutboxAttempt
  (
    OutboxAttemptId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_OutboxAttempt PRIMARY KEY,
    OutboxMessageId bigint NOT NULL,
    AttemptNumber int NOT NULL,
    WorkerId nvarchar(200) NOT NULL,
    StartedUtc datetime2(3) NOT NULL CONSTRAINT DF_OutboxAttempt_StartedUtc DEFAULT SYSUTCDATETIME(),
    CompletedUtc datetime2(3) NULL,
    Outcome nvarchar(30) NOT NULL CONSTRAINT DF_OutboxAttempt_Outcome DEFAULT N'Sending',
    ResponseStatusCode int NULL,
    ResponseBodyRedacted nvarchar(4000) NULL,
    ResponseCorrelationId nvarchar(200) NULL,
    FailureReason nvarchar(2000) NULL,
    CONSTRAINT FK_OutboxAttempt_Message FOREIGN KEY (OutboxMessageId) REFERENCES out.OutboxMessage(OutboxMessageId),
    CONSTRAINT UQ_OutboxAttempt_Number UNIQUE (OutboxMessageId, AttemptNumber),
    CONSTRAINT CK_OutboxAttempt_Outcome CHECK (Outcome IN (N'Sending', N'Sent', N'Retry', N'Dead'))
  );
END;
GO

CREATE OR ALTER PROCEDURE out.EnqueueMessage
  @OrganizationId int, @TargetKind nvarchar(100), @Operation nvarchar(100),
  @EntityType nvarchar(100), @EntityKey nvarchar(450), @FieldSummary nvarchar(1000),
  @PayloadJson nvarchar(max), @PayloadHash char(64), @ExpectedEchoHash char(64),
  @DedupKey varchar(64), @Actor nvarchar(200), @OutboxMessageId bigint OUTPUT
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  IF ISJSON(@PayloadJson) <> 1 THROW 51000, 'PayloadJson ni veljaven JSON.', 1;
  DECLARE @Status nvarchar(30);
  SELECT @Status = CASE WHEN ApprovalMode = N'Automatic' THEN N'Pending' ELSE N'PendingApproval' END
  FROM dbo.IntegrationProfile WHERE OrganizationId=@OrganizationId AND TargetKind=@TargetKind AND IsEnabled=1;
  IF @Status IS NULL THROW 51001, 'Integracijski profil ni omogočen.', 1;
  BEGIN TRY
    INSERT out.OutboxMessage(OrganizationId,TargetKind,Operation,EntityType,EntityKey,FieldSummary,PayloadJson,PayloadHash,ExpectedEchoHash,DedupKey,Status,NextAttemptUtc,CreatedBy)
    VALUES(@OrganizationId,@TargetKind,@Operation,@EntityType,@EntityKey,@FieldSummary,@PayloadJson,@PayloadHash,@ExpectedEchoHash,@DedupKey,@Status,CASE WHEN @Status=N'Pending' THEN SYSUTCDATETIME() END,@Actor);
    SET @OutboxMessageId=SCOPE_IDENTITY();
  END TRY
  BEGIN CATCH
    IF ERROR_NUMBER() IN (2601,2627)
    BEGIN
      SELECT @OutboxMessageId=OutboxMessageId FROM out.OutboxMessage WHERE OrganizationId=@OrganizationId AND DedupKey=@DedupKey AND Status IN (N'PendingApproval',N'Pending',N'Sending',N'Sent',N'Error',N'Retry');
      RETURN;
    END;
    THROW;
  END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE out.ApproveMessage @OutboxMessageId bigint, @Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON; BEGIN TRAN;
  UPDATE out.OutboxMessage SET Status=N'Pending',ApprovedUtc=SYSUTCDATETIME(),ApprovedBy=@Actor,NextAttemptUtc=SYSUTCDATETIME(),UpdatedUtc=SYSUTCDATETIME()
  WHERE OutboxMessageId=@OutboxMessageId AND Status=N'PendingApproval';
  IF @@ROWCOUNT<>1 BEGIN ROLLBACK; THROW 51002, 'Sporočila ni mogoče odobriti.', 1; END;
  COMMIT;
END;
GO

CREATE OR ALTER PROCEDURE out.CancelMessage @OutboxMessageId bigint, @Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON; BEGIN TRAN;
  UPDATE out.OutboxMessage SET Status=N'Cancelled',LastError=N'Preklical: '+@Actor,NextAttemptUtc=NULL,UpdatedUtc=SYSUTCDATETIME()
  WHERE OutboxMessageId=@OutboxMessageId AND Status IN(N'PendingApproval',N'Pending',N'Error',N'Retry');
  IF @@ROWCOUNT<>1 BEGIN ROLLBACK; THROW 51003, 'Sporočila ni mogoče preklicati.', 1; END;
  COMMIT;
END;
GO

CREATE OR ALTER PROCEDURE out.RetryMessage @OutboxMessageId bigint, @Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON; BEGIN TRAN;
  UPDATE out.OutboxMessage SET Status=N'Retry',LastError=N'Ročni ponovni poskus: '+@Actor,NextAttemptUtc=SYSUTCDATETIME(),LeaseOwner=NULL,LeaseUntilUtc=NULL,UpdatedUtc=SYSUTCDATETIME()
  WHERE OutboxMessageId=@OutboxMessageId AND Status IN(N'Error',N'Dead');
  IF @@ROWCOUNT<>1 BEGIN ROLLBACK; THROW 51004, 'Ponovni poskus ni dovoljen.', 1; END;
  COMMIT;
END;
GO

CREATE OR ALTER PROCEDURE out.ClaimMessage @WorkerId nvarchar(200), @LeaseSeconds int=60
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON; BEGIN TRAN;
  DECLARE @Claimed TABLE(OutboxMessageId bigint);
  ;WITH candidate AS
  (
    SELECT TOP(1) message.* FROM out.OutboxMessage message WITH (UPDLOCK, READPAST, ROWLOCK)
    INNER JOIN dbo.IntegrationProfile profile ON profile.OrganizationId=message.OrganizationId AND profile.TargetKind=message.TargetKind AND profile.IsEnabled=1
    WHERE message.Status IN(N'Pending',N'Retry') AND (message.NextAttemptUtc IS NULL OR message.NextAttemptUtc<=SYSUTCDATETIME())
      AND (message.LeaseUntilUtc IS NULL OR message.LeaseUntilUtc<SYSUTCDATETIME())
    ORDER BY message.OutboxMessageId
  )
  UPDATE candidate SET Status=N'Sending',AttemptCount=AttemptCount+1,LeaseOwner=@WorkerId,LeaseUntilUtc=DATEADD(second,@LeaseSeconds,SYSUTCDATETIME()),UpdatedUtc=SYSUTCDATETIME()
  OUTPUT inserted.OutboxMessageId INTO @Claimed;
  INSERT out.OutboxAttempt(OutboxMessageId,AttemptNumber,WorkerId)
  SELECT message.OutboxMessageId,message.AttemptCount,@WorkerId FROM out.OutboxMessage message INNER JOIN @Claimed claimed ON claimed.OutboxMessageId=message.OutboxMessageId;
  SELECT message.*,profile.EndpointTemplate,profile.HttpOperation,profile.TimeoutSeconds,profile.MaxAttempts,profile.BaseRetrySeconds
  FROM out.OutboxMessage message INNER JOIN @Claimed claimed ON claimed.OutboxMessageId=message.OutboxMessageId
  INNER JOIN dbo.IntegrationProfile profile ON profile.OrganizationId=message.OrganizationId AND profile.TargetKind=message.TargetKind;
  COMMIT;
END;
GO

CREATE OR ALTER PROCEDURE out.CompleteAttempt
  @OutboxMessageId bigint,@WorkerId nvarchar(200),@Succeeded bit,@PermanentFailure bit,
  @ResponseStatusCode int=NULL,@ResponseBodyRedacted nvarchar(4000)=NULL,@ResponseCorrelationId nvarchar(200)=NULL,@FailureReason nvarchar(2000)=NULL
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON; BEGIN TRAN;
  DECLARE @Attempt int,@MaxAttempts int,@BaseRetrySeconds int,@Status nvarchar(30);
  SELECT @Attempt=message.AttemptCount,@MaxAttempts=profile.MaxAttempts,@BaseRetrySeconds=profile.BaseRetrySeconds
  FROM out.OutboxMessage message WITH(UPDLOCK,ROWLOCK) INNER JOIN dbo.IntegrationProfile profile ON profile.OrganizationId=message.OrganizationId AND profile.TargetKind=message.TargetKind
  WHERE message.OutboxMessageId=@OutboxMessageId AND message.Status=N'Sending' AND message.LeaseOwner=@WorkerId AND message.LeaseUntilUtc>=SYSUTCDATETIME();
  IF @Attempt IS NULL BEGIN ROLLBACK; THROW 51005, 'Lease ni veljaven.', 1; END;
  SET @Status=CASE WHEN @Succeeded=1 THEN N'Sent' WHEN @PermanentFailure=1 OR @Attempt>=@MaxAttempts THEN N'Dead' ELSE N'Retry' END;
  UPDATE out.OutboxMessage SET Status=@Status,SentUtc=CASE WHEN @Status=N'Sent' THEN SYSUTCDATETIME() ELSE SentUtc END,
    NextAttemptUtc=CASE WHEN @Status=N'Retry' THEN DATEADD(second,@BaseRetrySeconds*CONVERT(int,POWER(CONVERT(float,2),@Attempt-1)),SYSUTCDATETIME()) END,
    LeaseOwner=NULL,LeaseUntilUtc=NULL,LastError=@FailureReason,ResponseStatusCode=@ResponseStatusCode,ResponseBodyRedacted=@ResponseBodyRedacted,ResponseCorrelationId=@ResponseCorrelationId,UpdatedUtc=SYSUTCDATETIME()
  WHERE OutboxMessageId=@OutboxMessageId;
  UPDATE out.OutboxAttempt SET Outcome=@Status,CompletedUtc=SYSUTCDATETIME(),ResponseStatusCode=@ResponseStatusCode,ResponseBodyRedacted=@ResponseBodyRedacted,ResponseCorrelationId=@ResponseCorrelationId,FailureReason=@FailureReason
  WHERE OutboxMessageId=@OutboxMessageId AND AttemptNumber=@Attempt AND WorkerId=@WorkerId AND Outcome=N'Sending';
  COMMIT;
END;
GO

CREATE OR ALTER PROCEDURE out.VerifyEcho @OrganizationId int,@EntityType nvarchar(100),@EntityKey nvarchar(450),@InboundHash char(64),@ObservedUtc datetime2(3)
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON; BEGIN TRAN;
  DECLARE @MessageId bigint,@Expected char(64),@SentUtc datetime2(3);
  SELECT TOP(1) @MessageId=OutboxMessageId,@Expected=ExpectedEchoHash,@SentUtc=SentUtc FROM out.OutboxMessage WITH(UPDLOCK,ROWLOCK)
  WHERE OrganizationId=@OrganizationId AND EntityType=@EntityType AND EntityKey=@EntityKey AND Status=N'Sent' ORDER BY SentUtc;
  IF @MessageId IS NOT NULL AND @ObservedUtc>=@SentUtc
    UPDATE out.OutboxMessage SET Status=CASE WHEN @InboundHash=@Expected THEN N'Verified' ELSE N'Drift' END,
      VerifiedUtc=CASE WHEN @InboundHash=@Expected THEN SYSUTCDATETIME() END,
      DriftDetail=CASE WHEN @InboundHash<>@Expected THEN N'Prejeti echo se ne ujema s pričakovanim hashom.' END,UpdatedUtc=SYSUTCDATETIME()
    WHERE OutboxMessageId=@MessageId;
  COMMIT;
END;
GO

CREATE OR ALTER PROCEDURE intranet.GetOutboundMessages @OrganizationId int
AS
  SELECT OutboxMessageId,TargetKind,Operation,EntityType,EntityKey,FieldSummary,DedupKey,Status,AttemptCount,NextAttemptUtc,ResponseStatusCode,ResponseCorrelationId,DriftDetail,CreatedUtc
  FROM out.OutboxMessage WHERE OrganizationId=@OrganizationId ORDER BY CreatedUtc DESC;
GO

CREATE OR ALTER PROCEDURE intranet.GetOutboundMessage @OrganizationId int,@OutboxMessageId bigint
AS
BEGIN
  SELECT * FROM out.OutboxMessage WHERE OrganizationId=@OrganizationId AND OutboxMessageId=@OutboxMessageId;
  SELECT AttemptNumber,WorkerId,StartedUtc,CompletedUtc,Outcome,ResponseStatusCode,ResponseBodyRedacted,ResponseCorrelationId,FailureReason
  FROM out.OutboxAttempt WHERE OutboxMessageId=@OutboxMessageId ORDER BY AttemptNumber DESC;
END;
GO
