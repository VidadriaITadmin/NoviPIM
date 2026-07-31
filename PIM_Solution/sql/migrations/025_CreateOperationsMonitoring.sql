SET XACT_ABORT ON;

IF SCHEMA_ID(N'ops') IS NULL EXEC(N'CREATE SCHEMA ops');
IF SCHEMA_ID(N'intranet') IS NULL EXEC(N'CREATE SCHEMA intranet');

IF OBJECT_ID(N'ops.ScheduleProfile', N'U') IS NULL
BEGIN
  CREATE TABLE ops.ScheduleProfile
  (
    ScheduleProfileId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_ScheduleProfile PRIMARY KEY,
    OrganizationId int NOT NULL,
    Provider nvarchar(100) NOT NULL,
    Pipeline nvarchar(100) NOT NULL,
    IsEnabled bit NOT NULL CONSTRAINT DF_ScheduleProfile_IsEnabled DEFAULT (0),
    IntervalSeconds int NOT NULL,
    StaleAfterSeconds int NOT NULL,
    LockTimeoutMilliseconds int NOT NULL CONSTRAINT DF_ScheduleProfile_LockTimeout DEFAULT (0),
    NextScheduledUtc datetime2(3) NULL,
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_ScheduleProfile_UpdatedUtc DEFAULT SYSUTCDATETIME(),
    UpdatedBy nvarchar(200) NOT NULL,
    CONSTRAINT FK_ScheduleProfile_Organization FOREIGN KEY (OrganizationId) REFERENCES dbo.OrganizationConfig(OrganizationId),
    CONSTRAINT UQ_ScheduleProfile UNIQUE (OrganizationId, Pipeline),
    CONSTRAINT CK_ScheduleProfile_Intervals CHECK (IntervalSeconds BETWEEN 1 AND 86400 AND StaleAfterSeconds >= IntervalSeconds AND LockTimeoutMilliseconds BETWEEN 0 AND 60000)
  );
END;

IF OBJECT_ID(N'ops.IntegrationHealth', N'U') IS NULL
BEGIN
  CREATE TABLE ops.IntegrationHealth
  (
    IntegrationHealthId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_IntegrationHealth PRIMARY KEY,
    OrganizationId int NOT NULL,
    Pipeline nvarchar(100) NOT NULL,
    RunId uniqueidentifier NULL,
    WorkerId nvarchar(200) NULL,
    Status nvarchar(30) NOT NULL CONSTRAINT DF_IntegrationHealth_Status DEFAULT N'NeverRun',
    LastHeartbeatUtc datetime2(3) NULL,
    LastSuccessfulRunUtc datetime2(3) NULL,
    LastFailedRunUtc datetime2(3) NULL,
    WatermarkUtc datetime2(3) NULL,
    LastErrorRedacted nvarchar(2000) NULL,
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_IntegrationHealth_UpdatedUtc DEFAULT SYSUTCDATETIME(),
    CONSTRAINT FK_IntegrationHealth_Organization FOREIGN KEY (OrganizationId) REFERENCES dbo.OrganizationConfig(OrganizationId),
    CONSTRAINT UQ_IntegrationHealth UNIQUE (OrganizationId, Pipeline),
    CONSTRAINT CK_IntegrationHealth_Status CHECK (Status IN (N'NeverRun',N'Running',N'Healthy',N'Failed',N'Stale'))
  );
END;

IF OBJECT_ID(N'ops.Alert', N'U') IS NULL
BEGIN
  CREATE TABLE ops.Alert
  (
    AlertId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_Alert PRIMARY KEY,
    OrganizationId int NOT NULL,
    Pipeline nvarchar(100) NOT NULL,
    AlertKind nvarchar(50) NOT NULL,
    Severity nvarchar(20) NOT NULL,
    DedupKey varchar(64) NOT NULL,
    Title nvarchar(300) NOT NULL,
    PayloadSummaryRedacted nvarchar(2000) NOT NULL,
    OccurrenceCount int NOT NULL CONSTRAINT DF_Alert_OccurrenceCount DEFAULT (1),
    FirstSeenUtc datetime2(3) NOT NULL CONSTRAINT DF_Alert_FirstSeenUtc DEFAULT SYSUTCDATETIME(),
    LastSeenUtc datetime2(3) NOT NULL CONSTRAINT DF_Alert_LastSeenUtc DEFAULT SYSUTCDATETIME(),
    AcknowledgedUtc datetime2(3) NULL,
    AcknowledgedBy nvarchar(200) NULL,
    ResolvedUtc datetime2(3) NULL,
    ResolvedBy nvarchar(200) NULL,
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_Alert_UpdatedUtc DEFAULT SYSUTCDATETIME(),
    UpdatedBy nvarchar(200) NOT NULL,
    CONSTRAINT FK_Alert_Organization FOREIGN KEY (OrganizationId) REFERENCES dbo.OrganizationConfig(OrganizationId),
    CONSTRAINT CK_Alert_Severity CHECK (Severity IN (N'Info',N'Warning',N'Critical')),
    CONSTRAINT CK_Alert_Audit CHECK (((AcknowledgedUtc IS NULL AND AcknowledgedBy IS NULL) OR (AcknowledgedUtc IS NOT NULL AND AcknowledgedBy IS NOT NULL)) AND ((ResolvedUtc IS NULL AND ResolvedBy IS NULL) OR (ResolvedUtc IS NOT NULL AND ResolvedBy IS NOT NULL)))
  );
END;

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID(N'ops.Alert') AND name=N'UX_Alert_OpenDedup')
  CREATE UNIQUE INDEX UX_Alert_OpenDedup ON ops.Alert(OrganizationId, DedupKey) WHERE ResolvedUtc IS NULL;

IF OBJECT_ID(N'ops.AlertDelivery', N'U') IS NULL
BEGIN
  CREATE TABLE ops.AlertDelivery
  (
    AlertDeliveryId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_AlertDelivery PRIMARY KEY,
    AlertId bigint NOT NULL,
    Channel nvarchar(20) NOT NULL,
    RecipientKey nvarchar(300) NOT NULL,
    Status nvarchar(20) NOT NULL CONSTRAINT DF_AlertDelivery_Status DEFAULT N'Pending',
    AttemptCount int NOT NULL CONSTRAINT DF_AlertDelivery_Attempts DEFAULT (0),
    NextAttemptUtc datetime2(3) NULL,
    LeaseOwner nvarchar(200) NULL,
    LeaseUntilUtc datetime2(3) NULL,
    LastErrorRedacted nvarchar(2000) NULL,
    DeliveredUtc datetime2(3) NULL,
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_AlertDelivery_UpdatedUtc DEFAULT SYSUTCDATETIME(),
    CONSTRAINT FK_AlertDelivery_Alert FOREIGN KEY (AlertId) REFERENCES ops.Alert(AlertId),
    CONSTRAINT UQ_AlertDelivery UNIQUE (AlertId, Channel, RecipientKey),
    CONSTRAINT CK_AlertDelivery_Channel CHECK (Channel IN (N'Webhook',N'Email')),
    CONSTRAINT CK_AlertDelivery_Status CHECK (Status IN (N'Pending',N'Sending',N'Retry',N'Delivered',N'Dead')),
    CONSTRAINT CK_AlertDelivery_Lease CHECK ((LeaseOwner IS NULL AND LeaseUntilUtc IS NULL) OR (LeaseOwner IS NOT NULL AND LeaseUntilUtc IS NOT NULL))
  );
END;

IF OBJECT_ID(N'ops.AlertRecipientConfig', N'U') IS NULL
BEGIN
  CREATE TABLE ops.AlertRecipientConfig
  (
    AlertRecipientConfigId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_AlertRecipientConfig PRIMARY KEY,
    OrganizationId int NOT NULL,
    RoleName nvarchar(100) NOT NULL,
    Channel nvarchar(20) NOT NULL,
    RecipientKey nvarchar(300) NOT NULL,
    MinimumSeverity nvarchar(20) NOT NULL CONSTRAINT DF_AlertRecipient_Severity DEFAULT N'Critical',
    IsEnabled bit NOT NULL CONSTRAINT DF_AlertRecipient_IsEnabled DEFAULT (0),
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_AlertRecipient_UpdatedUtc DEFAULT SYSUTCDATETIME(),
    UpdatedBy nvarchar(200) NOT NULL,
    CONSTRAINT FK_AlertRecipient_Organization FOREIGN KEY (OrganizationId) REFERENCES dbo.OrganizationConfig(OrganizationId),
    CONSTRAINT UQ_AlertRecipient UNIQUE (OrganizationId,RoleName,Channel,RecipientKey),
    CONSTRAINT CK_AlertRecipient_Channel CHECK (Channel IN (N'Webhook',N'Email')),
    CONSTRAINT CK_AlertRecipient_Severity CHECK (MinimumSeverity IN (N'Info',N'Warning',N'Critical'))
  );
END;

IF OBJECT_ID(N'ops.DeploymentRun', N'U') IS NULL
BEGIN
  CREATE TABLE ops.DeploymentRun
  (
    DeploymentRunId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_DeploymentRun PRIMARY KEY,
    Version nvarchar(100) NOT NULL,
    EnvironmentName nvarchar(100) NOT NULL,
    Status nvarchar(30) NOT NULL,
    StartedUtc datetime2(3) NOT NULL CONSTRAINT DF_DeploymentRun_StartedUtc DEFAULT SYSUTCDATETIME(),
    CompletedUtc datetime2(3) NULL,
    Actor nvarchar(200) NOT NULL,
    BackupPath nvarchar(1000) NULL,
    DetailRedacted nvarchar(2000) NULL,
    CONSTRAINT CK_DeploymentRun_Status CHECK (Status IN (N'Started',N'Succeeded',N'Failed',N'RolledBack',N'DryRun'))
  );
END;

EXEC(N'CREATE OR ALTER PROCEDURE ops.BeginRun
  @OrganizationId int, @Pipeline nvarchar(100), @WorkerId nvarchar(200), @RunId uniqueidentifier OUTPUT
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  DECLARE @LockTimeout int, @LockResult int, @Resource nvarchar(255)=CONCAT(N''PIM:ops:'',@OrganizationId,N'':'',@Pipeline);
  SELECT @LockTimeout=LockTimeoutMilliseconds FROM ops.ScheduleProfile WHERE OrganizationId=@OrganizationId AND Pipeline=@Pipeline AND IsEnabled=1;
  IF @LockTimeout IS NULL THROW 51100, ''Razpored ni omogočen.'', 1;
  EXEC @LockResult=sys.sp_getapplock @Resource=@Resource,@LockMode=N''Exclusive'',@LockOwner=N''Session'',@LockTimeout=@LockTimeout,@DbPrincipal=N''public'';
  IF @LockResult<0 THROW 51101, ''Izvajanje za organizacijo in pipeline že poteka.'', 1;
  SET @RunId=NEWID();
  MERGE ops.IntegrationHealth AS target USING (SELECT @OrganizationId OrganizationId,@Pipeline Pipeline) source
    ON target.OrganizationId=source.OrganizationId AND target.Pipeline=source.Pipeline
  WHEN MATCHED THEN UPDATE SET RunId=@RunId,WorkerId=@WorkerId,Status=N''Running'',LastHeartbeatUtc=SYSUTCDATETIME(),LastErrorRedacted=NULL,UpdatedUtc=SYSUTCDATETIME()
  WHEN NOT MATCHED THEN INSERT(OrganizationId,Pipeline,RunId,WorkerId,Status,LastHeartbeatUtc) VALUES(@OrganizationId,@Pipeline,@RunId,@WorkerId,N''Running'',SYSUTCDATETIME());
END;');

EXEC(N'CREATE OR ALTER PROCEDURE ops.Heartbeat @OrganizationId int,@Pipeline nvarchar(100),@RunId uniqueidentifier,@WatermarkUtc datetime2(3)=NULL
AS
BEGIN
  SET NOCOUNT ON;
  UPDATE ops.IntegrationHealth SET LastHeartbeatUtc=SYSUTCDATETIME(),WatermarkUtc=COALESCE(@WatermarkUtc,WatermarkUtc),UpdatedUtc=SYSUTCDATETIME()
  WHERE OrganizationId=@OrganizationId AND Pipeline=@Pipeline AND RunId=@RunId AND Status=N''Running'';
  IF @@ROWCOUNT<>1 THROW 51102, ''Aktivno izvajanje ne obstaja.'', 1;
END;');

EXEC(N'CREATE OR ALTER PROCEDURE ops.CompleteRun @OrganizationId int,@Pipeline nvarchar(100),@RunId uniqueidentifier,@Succeeded bit,@ErrorRedacted nvarchar(2000)=NULL
AS
BEGIN
  SET NOCOUNT ON;
  UPDATE ops.IntegrationHealth SET Status=CASE WHEN @Succeeded=1 THEN N''Healthy'' ELSE N''Failed'' END,
    LastSuccessfulRunUtc=CASE WHEN @Succeeded=1 THEN SYSUTCDATETIME() ELSE LastSuccessfulRunUtc END,
    LastFailedRunUtc=CASE WHEN @Succeeded=0 THEN SYSUTCDATETIME() ELSE LastFailedRunUtc END,
    LastHeartbeatUtc=SYSUTCDATETIME(),LastErrorRedacted=CASE WHEN @Succeeded=0 THEN @ErrorRedacted END,UpdatedUtc=SYSUTCDATETIME()
  WHERE OrganizationId=@OrganizationId AND Pipeline=@Pipeline AND RunId=@RunId;
  IF @@ROWCOUNT<>1 THROW 51103, ''Izvajanja ni mogoče zaključiti.'', 1;
  UPDATE ops.ScheduleProfile SET NextScheduledUtc=DATEADD(second,IntervalSeconds,SYSUTCDATETIME()) WHERE OrganizationId=@OrganizationId AND Pipeline=@Pipeline;
END;');

EXEC(N'CREATE OR ALTER PROCEDURE ops.UpsertAlert @OrganizationId int,@Pipeline nvarchar(100),@AlertKind nvarchar(50),@Severity nvarchar(20),@DedupKey varchar(64),@Title nvarchar(300),@PayloadSummaryRedacted nvarchar(2000),@Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  UPDATE ops.Alert SET OccurrenceCount=OccurrenceCount+1,LastSeenUtc=SYSUTCDATETIME(),Severity=@Severity,Title=@Title,PayloadSummaryRedacted=@PayloadSummaryRedacted,UpdatedUtc=SYSUTCDATETIME(),UpdatedBy=@Actor
  WHERE OrganizationId=@OrganizationId AND DedupKey=@DedupKey AND ResolvedUtc IS NULL;
  IF @@ROWCOUNT=0
    INSERT ops.Alert(OrganizationId,Pipeline,AlertKind,Severity,DedupKey,Title,PayloadSummaryRedacted,UpdatedBy)
    VALUES(@OrganizationId,@Pipeline,@AlertKind,@Severity,@DedupKey,@Title,@PayloadSummaryRedacted,@Actor);
END;');

EXEC(N'CREATE OR ALTER PROCEDURE ops.RunWatchdog @Actor nvarchar(200)=N''PIM.Watchdog''
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  DECLARE @now datetime2(3)=SYSUTCDATETIME();
  UPDATE health SET Status=N''Stale'',UpdatedUtc=@now FROM ops.IntegrationHealth health INNER JOIN ops.ScheduleProfile profile ON profile.OrganizationId=health.OrganizationId AND profile.Pipeline=health.Pipeline
  WHERE profile.IsEnabled=1 AND health.LastHeartbeatUtc<DATEADD(second,-profile.StaleAfterSeconds,@now) AND health.Status=N''Running'';
  MERGE ops.Alert AS target USING
  (
    SELECT profile.OrganizationId,profile.Pipeline,N''StaleHeartbeat'' AlertKind,N''Critical'' Severity,
      CONVERT(varchar(64),HASHBYTES(''SHA2_256'',CONCAT(profile.OrganizationId,N'':'',profile.Pipeline,N'':stale'')),2) DedupKey,
      N''Zastarel srčni utrip'' Title,N''Worker nima pravočasnega srčnega utripa.'' PayloadSummaryRedacted
    FROM ops.ScheduleProfile profile INNER JOIN ops.IntegrationHealth health ON health.OrganizationId=profile.OrganizationId AND health.Pipeline=profile.Pipeline
    WHERE profile.IsEnabled=1 AND health.Status=N''Stale''
    UNION ALL
    SELECT message.OrganizationId,N''Outbound'',CASE WHEN message.Status=N''Dead'' THEN N''OutboundDead'' ELSE N''OutboundDrift'' END,N''Critical'',
      CONVERT(varchar(64),HASHBYTES(''SHA2_256'',CONCAT(message.OrganizationId,N'':outbound:'',message.Status)),2),
      CASE WHEN message.Status=N''Dead'' THEN N''Odhodno sporočilo je mrtvo'' ELSE N''Zaznan je odklon'' END,
      CONCAT(N''Število sporočil: '',COUNT_BIG(*))
    FROM out.OutboxMessage message WHERE message.Status IN(N''Dead'',N''Drift'') GROUP BY message.OrganizationId,message.Status
    UNION ALL
    SELECT profile.OrganizationId,profile.Pipeline,N''StalledWatermark'',N''Warning'',
      CONVERT(varchar(64),HASHBYTES(''SHA2_256'',CONCAT(profile.OrganizationId,N'':'',profile.Pipeline,N'':watermark'')),2),
      N''Vodni žig miruje'',N''Vodni žig ni napredoval v dovoljenem času.''
    FROM ops.ScheduleProfile profile INNER JOIN ops.IntegrationHealth health ON health.OrganizationId=profile.OrganizationId AND health.Pipeline=profile.Pipeline
    WHERE profile.IsEnabled=1 AND health.WatermarkUtc IS NOT NULL AND health.WatermarkUtc<DATEADD(second,-profile.StaleAfterSeconds,@now)
  ) source ON target.OrganizationId=source.OrganizationId AND target.DedupKey=source.DedupKey AND target.ResolvedUtc IS NULL
  WHEN MATCHED THEN UPDATE SET LastSeenUtc=@now,OccurrenceCount=target.OccurrenceCount+1,UpdatedUtc=@now,UpdatedBy=@Actor
  WHEN NOT MATCHED THEN INSERT(OrganizationId,Pipeline,AlertKind,Severity,DedupKey,Title,PayloadSummaryRedacted,UpdatedBy)
    VALUES(source.OrganizationId,source.Pipeline,source.AlertKind,source.Severity,source.DedupKey,source.Title,source.PayloadSummaryRedacted,@Actor);
  UPDATE alert SET ResolvedUtc=@now,ResolvedBy=@Actor,UpdatedUtc=@now,UpdatedBy=@Actor FROM ops.Alert alert
  INNER JOIN ops.IntegrationHealth health ON health.OrganizationId=alert.OrganizationId AND health.Pipeline=alert.Pipeline
  WHERE alert.AlertKind=N''StaleHeartbeat'' AND alert.ResolvedUtc IS NULL AND health.Status IN(N''Healthy'',N''Running'') AND health.LastHeartbeatUtc>=DATEADD(second,-(SELECT StaleAfterSeconds FROM ops.ScheduleProfile WHERE OrganizationId=health.OrganizationId AND Pipeline=health.Pipeline),@now);
END;');

EXEC(N'CREATE OR ALTER PROCEDURE ops.ClaimAlertDelivery @WorkerId nvarchar(200),@LeaseSeconds int=60
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON; BEGIN TRAN;
  ;WITH candidate AS (SELECT TOP(1) * FROM ops.AlertDelivery WITH(UPDLOCK,READPAST,ROWLOCK) WHERE Status IN(N''Pending'',N''Retry'') AND (NextAttemptUtc IS NULL OR NextAttemptUtc<=SYSUTCDATETIME()) AND (LeaseUntilUtc IS NULL OR LeaseUntilUtc<SYSUTCDATETIME()) ORDER BY AlertDeliveryId)
  UPDATE candidate SET Status=N''Sending'',AttemptCount=AttemptCount+1,LeaseOwner=@WorkerId,LeaseUntilUtc=DATEADD(second,@LeaseSeconds,SYSUTCDATETIME()),UpdatedUtc=SYSUTCDATETIME()
  OUTPUT inserted.*; COMMIT;
END;');

EXEC(N'CREATE OR ALTER PROCEDURE ops.QueueAlertDeliveries
AS
BEGIN
  SET NOCOUNT ON;
  INSERT ops.AlertDelivery(AlertId,Channel,RecipientKey,NextAttemptUtc)
  SELECT alert.AlertId,recipient.Channel,recipient.RecipientKey,SYSUTCDATETIME()
  FROM ops.Alert alert INNER JOIN ops.AlertRecipientConfig recipient ON recipient.OrganizationId=alert.OrganizationId AND recipient.IsEnabled=1
  WHERE alert.ResolvedUtc IS NULL
    AND CASE alert.Severity WHEN N''Critical'' THEN 3 WHEN N''Warning'' THEN 2 ELSE 1 END >= CASE recipient.MinimumSeverity WHEN N''Critical'' THEN 3 WHEN N''Warning'' THEN 2 ELSE 1 END
    AND NOT EXISTS (SELECT 1 FROM ops.AlertDelivery delivery WHERE delivery.AlertId=alert.AlertId AND delivery.Channel=recipient.Channel AND delivery.RecipientKey=recipient.RecipientKey);
END;');

EXEC(N'CREATE OR ALTER PROCEDURE ops.CompleteAlertDelivery @AlertDeliveryId bigint,@WorkerId nvarchar(200),@Succeeded bit,@PermanentFailure bit,@BaseRetrySeconds int=30,@MaxAttempts int=5,@ErrorRedacted nvarchar(2000)=NULL
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  UPDATE ops.AlertDelivery SET Status=CASE WHEN @Succeeded=1 THEN N''Delivered'' WHEN @PermanentFailure=1 OR AttemptCount>=@MaxAttempts THEN N''Dead'' ELSE N''Retry'' END,
    DeliveredUtc=CASE WHEN @Succeeded=1 THEN SYSUTCDATETIME() END,
    NextAttemptUtc=CASE WHEN @Succeeded=0 AND @PermanentFailure=0 AND AttemptCount<@MaxAttempts THEN DATEADD(second,@BaseRetrySeconds*CONVERT(int,POWER(CONVERT(float,2),AttemptCount-1)),SYSUTCDATETIME()) END,
    LeaseOwner=NULL,LeaseUntilUtc=NULL,LastErrorRedacted=@ErrorRedacted,UpdatedUtc=SYSUTCDATETIME()
  WHERE AlertDeliveryId=@AlertDeliveryId AND Status=N''Sending'' AND LeaseOwner=@WorkerId AND LeaseUntilUtc>=SYSUTCDATETIME();
  IF @@ROWCOUNT<>1 THROW 51104, ''Lease dostave ni veljaven.'', 1;
END;');

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetSystemIntegrations @OrganizationId int
AS
  SELECT profile.OrganizationId,organization.OrganizationCode,profile.Provider,profile.Pipeline,profile.IsEnabled,health.Status,health.LastHeartbeatUtc,health.LastSuccessfulRunUtc,health.LastFailedRunUtc,health.WatermarkUtc,profile.NextScheduledUtc,
    (SELECT COUNT(*) FROM ops.Alert alert WHERE alert.OrganizationId=profile.OrganizationId AND alert.Pipeline=profile.Pipeline AND alert.ResolvedUtc IS NULL) OpenAlerts,
    (SELECT COUNT(*) FROM out.OutboxMessage message WHERE message.OrganizationId=profile.OrganizationId AND message.Status=N''Dead'') OutboxDeadCount,
    (SELECT COUNT(*) FROM out.OutboxMessage message WHERE message.OrganizationId=profile.OrganizationId AND message.Status=N''Drift'') OutboxDriftCount
  FROM ops.ScheduleProfile profile INNER JOIN dbo.OrganizationConfig organization ON organization.OrganizationId=profile.OrganizationId
  LEFT JOIN ops.IntegrationHealth health ON health.OrganizationId=profile.OrganizationId AND health.Pipeline=profile.Pipeline
  WHERE profile.OrganizationId=@OrganizationId ORDER BY profile.Provider,profile.Pipeline;
  SELECT AlertId,Pipeline,AlertKind,Severity,Title,PayloadSummaryRedacted,OccurrenceCount,FirstSeenUtc,LastSeenUtc,AcknowledgedUtc,AcknowledgedBy,ResolvedUtc,ResolvedBy
  FROM ops.Alert WHERE OrganizationId=@OrganizationId ORDER BY CASE Severity WHEN N''Critical'' THEN 0 WHEN N''Warning'' THEN 1 ELSE 2 END,LastSeenUtc DESC;');

EXEC(N'CREATE OR ALTER PROCEDURE intranet.AcknowledgeAlert @OrganizationId int,@AlertId bigint,@Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON; UPDATE ops.Alert SET AcknowledgedUtc=SYSUTCDATETIME(),AcknowledgedBy=@Actor,UpdatedUtc=SYSUTCDATETIME(),UpdatedBy=@Actor WHERE OrganizationId=@OrganizationId AND AlertId=@AlertId AND AcknowledgedUtc IS NULL AND ResolvedUtc IS NULL;
  IF @@ROWCOUNT<>1 THROW 51105, ''Opozorila ni mogoče potrditi.'', 1;
END;');

EXEC(N'CREATE OR ALTER PROCEDURE intranet.ResolveAlert @OrganizationId int,@AlertId bigint,@Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON; UPDATE ops.Alert SET ResolvedUtc=SYSUTCDATETIME(),ResolvedBy=@Actor,UpdatedUtc=SYSUTCDATETIME(),UpdatedBy=@Actor WHERE OrganizationId=@OrganizationId AND AlertId=@AlertId AND ResolvedUtc IS NULL;
  IF @@ROWCOUNT<>1 THROW 51106, ''Opozorila ni mogoče razrešiti.'', 1;
END;');
