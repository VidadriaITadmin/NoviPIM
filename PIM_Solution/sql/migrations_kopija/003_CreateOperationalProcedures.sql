SET XACT_ABORT ON;

EXEC(N'
CREATE OR ALTER PROCEDURE ops.LogError
  @Layer nvarchar(50),
  @Severity nvarchar(20),
  @ErrorCode nvarchar(100),
  @Message nvarchar(4000),
  @BatchId uniqueidentifier = NULL,
  @RunId uniqueidentifier = NULL,
  @Detail nvarchar(max) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  IF @Layer IS NULL OR LEN(LTRIM(RTRIM(@Layer))) = 0 THROW 51001, ''Layer je obvezen.'', 1;
  IF @Severity NOT IN (N''Info'', N''Warning'', N''Error'', N''Critical'') THROW 51002, ''Severity ni veljaven.'', 1;
  IF @ErrorCode IS NULL OR LEN(LTRIM(RTRIM(@ErrorCode))) = 0 THROW 51003, ''ErrorCode je obvezen.'', 1;
  IF @Message IS NULL OR LEN(LTRIM(RTRIM(@Message))) = 0 THROW 51004, ''Message je obvezen.'', 1;

  INSERT ops.ErrorLog (Layer, Severity, ErrorCode, Message, BatchId, RunId, Detail)
  VALUES (@Layer, @Severity, @ErrorCode, @Message, @BatchId, @RunId, @Detail);
END;
');

EXEC(N'
CREATE OR ALTER PROCEDURE ops.EnqueueDeadLetter
  @Layer nvarchar(50),
  @SourceCode nvarchar(100) = NULL,
  @OrganizationId int = NULL,
  @EntityType nvarchar(100) = NULL,
  @NaturalKey nvarchar(450) = NULL,
  @PayloadJson nvarchar(max) = NULL,
  @FailureReason nvarchar(2000)
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  IF @Layer IS NULL OR LEN(LTRIM(RTRIM(@Layer))) = 0 THROW 51005, ''Layer je obvezen.'', 1;
  IF @FailureReason IS NULL OR LEN(LTRIM(RTRIM(@FailureReason))) = 0 THROW 51006, ''FailureReason je obvezen.'', 1;
  IF @OrganizationId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.OrganizationConfig WHERE OrganizationId = @OrganizationId) THROW 51007, ''OrganizationId ne obstaja.'', 1;

  INSERT ops.DeadLetterQueue (Layer, SourceCode, OrganizationId, EntityType, NaturalKey, PayloadJson, FailureReason)
  VALUES (@Layer, @SourceCode, @OrganizationId, @EntityType, @NaturalKey, @PayloadJson, @FailureReason);
END;
');
