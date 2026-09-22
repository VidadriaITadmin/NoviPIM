SET XACT_ABORT ON;

IF OBJECT_ID(N'dbo.OrganizationConfig', N'U') IS NULL
BEGIN
  CREATE TABLE dbo.OrganizationConfig
  (
    OrganizationId int NOT NULL,
    Name nvarchar(200) NOT NULL,
    SaopPrefix nvarchar(100) NOT NULL,
    IsActive bit NOT NULL CONSTRAINT DF_OrganizationConfig_IsActive DEFAULT (1),
    CreatedUtc datetime2(3) NOT NULL CONSTRAINT DF_OrganizationConfig_CreatedUtc DEFAULT SYSUTCDATETIME(),
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_OrganizationConfig_UpdatedUtc DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_OrganizationConfig PRIMARY KEY CLUSTERED (OrganizationId),
    CONSTRAINT UQ_OrganizationConfig_Name UNIQUE (Name)
  );
END;

MERGE dbo.OrganizationConfig AS target
USING (VALUES
  (1, N'DEMO', N'DEMO', CONVERT(bit, 1)),
  (2, N'IQLighting', N'IQLighting', CONVERT(bit, 1)),
  (3, N'Vidadria', N'Vidadria', CONVERT(bit, 1)),
  (4, N'Ediito', N'Ediito', CONVERT(bit, 1))
) AS source (OrganizationId, Name, SaopPrefix, IsActive)
ON target.OrganizationId = source.OrganizationId
WHEN MATCHED AND (target.Name <> source.Name OR target.SaopPrefix <> source.SaopPrefix OR target.IsActive <> source.IsActive) THEN
  UPDATE SET Name = source.Name, SaopPrefix = source.SaopPrefix, IsActive = source.IsActive, UpdatedUtc = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN
  INSERT (OrganizationId, Name, SaopPrefix, IsActive) VALUES (source.OrganizationId, source.Name, source.SaopPrefix, source.IsActive);

IF OBJECT_ID(N'ops.PipelineRun', N'U') IS NULL
BEGIN
  CREATE TABLE ops.PipelineRun
  (
    RunId uniqueidentifier NOT NULL CONSTRAINT DF_PipelineRun_RunId DEFAULT NEWSEQUENTIALID(),
    Pipeline nvarchar(100) NOT NULL,
    OrganizationId int NULL,
    SourceCode nvarchar(100) NULL,
    StartedUtc datetime2(3) NOT NULL CONSTRAINT DF_PipelineRun_StartedUtc DEFAULT SYSUTCDATETIME(),
    EndedUtc datetime2(3) NULL,
    Status nvarchar(30) NOT NULL,
    RowsRead bigint NOT NULL CONSTRAINT DF_PipelineRun_RowsRead DEFAULT (0),
    RowsSucceeded bigint NOT NULL CONSTRAINT DF_PipelineRun_RowsSucceeded DEFAULT (0),
    RowsFailed bigint NOT NULL CONSTRAINT DF_PipelineRun_RowsFailed DEFAULT (0),
    CorrelationId uniqueidentifier NULL,
    CONSTRAINT PK_PipelineRun PRIMARY KEY CLUSTERED (RunId),
    CONSTRAINT CK_PipelineRun_Status CHECK (Status IN (N'Pending', N'Running', N'Succeeded', N'Failed', N'Cancelled')),
    CONSTRAINT FK_PipelineRun_OrganizationConfig FOREIGN KEY (OrganizationId) REFERENCES dbo.OrganizationConfig (OrganizationId)
  );
END;

IF OBJECT_ID(N'ops.PipelineStepLog', N'U') IS NULL
BEGIN
  CREATE TABLE ops.PipelineStepLog
  (
    PipelineStepLogId bigint IDENTITY(1,1) NOT NULL,
    RunId uniqueidentifier NOT NULL,
    StepCode nvarchar(100) NOT NULL,
    Attempt smallint NOT NULL CONSTRAINT DF_PipelineStepLog_Attempt DEFAULT (1),
    RowsIn bigint NOT NULL CONSTRAINT DF_PipelineStepLog_RowsIn DEFAULT (0),
    RowsMerged bigint NOT NULL CONSTRAINT DF_PipelineStepLog_RowsMerged DEFAULT (0),
    DurationMs bigint NULL,
    Status nvarchar(30) NOT NULL,
    RecordedUtc datetime2(3) NOT NULL CONSTRAINT DF_PipelineStepLog_RecordedUtc DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_PipelineStepLog PRIMARY KEY CLUSTERED (PipelineStepLogId),
    CONSTRAINT UQ_PipelineStepLog_RunStepAttempt UNIQUE (RunId, StepCode, Attempt),
    CONSTRAINT CK_PipelineStepLog_Attempt CHECK (Attempt > 0),
    CONSTRAINT CK_PipelineStepLog_Status CHECK (Status IN (N'Pending', N'Running', N'Succeeded', N'Failed', N'Skipped')),
    CONSTRAINT FK_PipelineStepLog_PipelineRun FOREIGN KEY (RunId) REFERENCES ops.PipelineRun (RunId)
  );
END;

IF OBJECT_ID(N'ops.DeadLetterQueue', N'U') IS NULL
BEGIN
  CREATE TABLE ops.DeadLetterQueue
  (
    DeadLetterId bigint IDENTITY(1,1) NOT NULL,
    Layer nvarchar(50) NOT NULL,
    SourceCode nvarchar(100) NULL,
    OrganizationId int NULL,
    EntityType nvarchar(100) NULL,
    NaturalKey nvarchar(450) NULL,
    PayloadJson nvarchar(max) NULL,
    FailureReason nvarchar(2000) NOT NULL,
    RetryCount int NOT NULL CONSTRAINT DF_DeadLetterQueue_RetryCount DEFAULT (0),
    Status nvarchar(30) NOT NULL CONSTRAINT DF_DeadLetterQueue_Status DEFAULT (N'Pending'),
    FirstFailedUtc datetime2(3) NOT NULL CONSTRAINT DF_DeadLetterQueue_FirstFailedUtc DEFAULT SYSUTCDATETIME(),
    LastFailedUtc datetime2(3) NOT NULL CONSTRAINT DF_DeadLetterQueue_LastFailedUtc DEFAULT SYSUTCDATETIME(),
    ResolvedUtc datetime2(3) NULL,
    CONSTRAINT PK_DeadLetterQueue PRIMARY KEY CLUSTERED (DeadLetterId),
    CONSTRAINT CK_DeadLetterQueue_RetryCount CHECK (RetryCount >= 0),
    CONSTRAINT CK_DeadLetterQueue_Status CHECK (Status IN (N'Pending', N'Retrying', N'Resolved', N'Dead')),
    CONSTRAINT FK_DeadLetterQueue_OrganizationConfig FOREIGN KEY (OrganizationId) REFERENCES dbo.OrganizationConfig (OrganizationId)
  );
END;

IF OBJECT_ID(N'ops.ErrorLog', N'U') IS NULL
BEGIN
  CREATE TABLE ops.ErrorLog
  (
    ErrorLogId bigint IDENTITY(1,1) NOT NULL,
    OccurredUtc datetime2(3) NOT NULL CONSTRAINT DF_ErrorLog_OccurredUtc DEFAULT SYSUTCDATETIME(),
    Layer nvarchar(50) NOT NULL,
    Severity nvarchar(20) NOT NULL,
    ErrorCode nvarchar(100) NOT NULL,
    Message nvarchar(4000) NOT NULL,
    BatchId uniqueidentifier NULL,
    RunId uniqueidentifier NULL,
    Detail nvarchar(max) NULL,
    CONSTRAINT PK_ErrorLog PRIMARY KEY CLUSTERED (ErrorLogId),
    CONSTRAINT CK_ErrorLog_Severity CHECK (Severity IN (N'Info', N'Warning', N'Error', N'Critical')),
    CONSTRAINT FK_ErrorLog_PipelineRun FOREIGN KEY (RunId) REFERENCES ops.PipelineRun (RunId)
  );
END;

IF OBJECT_ID(N'ops.Heartbeat', N'U') IS NULL
BEGIN
  CREATE TABLE ops.Heartbeat
  (
    HeartbeatId bigint IDENTITY(1,1) NOT NULL,
    ComponentName nvarchar(200) NOT NULL,
    OrganizationId int NULL,
    SourceCode nvarchar(100) NULL,
    LastSucceededUtc datetime2(3) NOT NULL,
    LastStatus nvarchar(30) NOT NULL,
    Details nvarchar(2000) NULL,
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_Heartbeat_UpdatedUtc DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_Heartbeat PRIMARY KEY CLUSTERED (HeartbeatId),
    CONSTRAINT CK_Heartbeat_Status CHECK (LastStatus IN (N'Succeeded', N'Failed', N'Degraded')),
    CONSTRAINT FK_Heartbeat_OrganizationConfig FOREIGN KEY (OrganizationId) REFERENCES dbo.OrganizationConfig (OrganizationId)
  );
END;

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'ops.PipelineRun') AND name = N'IX_PipelineRun_StatusStartedUtc')
  CREATE INDEX IX_PipelineRun_StatusStartedUtc ON ops.PipelineRun (Status, StartedUtc DESC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'ops.PipelineRun') AND name = N'IX_PipelineRun_OrganizationSourceStartedUtc')
  CREATE INDEX IX_PipelineRun_OrganizationSourceStartedUtc ON ops.PipelineRun (OrganizationId, SourceCode, StartedUtc DESC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'ops.DeadLetterQueue') AND name = N'IX_DeadLetterQueue_StatusLastFailedUtc')
  CREATE INDEX IX_DeadLetterQueue_StatusLastFailedUtc ON ops.DeadLetterQueue (Status, LastFailedUtc DESC);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'ops.ErrorLog') AND name = N'IX_ErrorLog_OccurredUtcSeverity')
  CREATE INDEX IX_ErrorLog_OccurredUtcSeverity ON ops.ErrorLog (OccurredUtc DESC, Severity);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'ops.Heartbeat') AND name = N'UX_Heartbeat_ComponentOrganizationSource')
  CREATE UNIQUE INDEX UX_Heartbeat_ComponentOrganizationSource ON ops.Heartbeat (ComponentName, OrganizationId, SourceCode) WHERE OrganizationId IS NOT NULL AND SourceCode IS NOT NULL;
