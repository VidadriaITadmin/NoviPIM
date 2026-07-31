SET XACT_ABORT ON;

EXEC(N'CREATE OR ALTER PROCEDURE out.EnqueueMessage
  @OrganizationId int, @TargetKind nvarchar(100), @Operation nvarchar(100),
  @EntityType nvarchar(100), @EntityKey nvarchar(450), @FieldSummary nvarchar(1000),
  @PayloadJson nvarchar(max), @PayloadHash char(64), @ExpectedEchoHash char(64),
  @DedupKey varchar(64), @Actor nvarchar(200), @OutboxMessageId bigint OUTPUT
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  IF ISJSON(@PayloadJson) <> 1 THROW 51000, ''PayloadJson ni veljaven JSON.'', 1;
  DECLARE @Status nvarchar(30);
  SELECT @Status = CASE WHEN ApprovalMode = N''Automatic'' THEN N''Pending'' ELSE N''PendingApproval'' END
  FROM dbo.IntegrationProfile WHERE OrganizationId=@OrganizationId AND TargetKind=@TargetKind AND IsEnabled=1;
  IF @Status IS NULL THROW 51001, ''Integracijski profil ni omogočen.'', 1;
  BEGIN TRY
    INSERT out.OutboxMessage(OrganizationId,TargetKind,Operation,EntityType,EntityKey,FieldSummary,PayloadJson,PayloadHash,ExpectedEchoHash,DedupKey,Status,NextAttemptUtc,CreatedBy)
    VALUES(@OrganizationId,@TargetKind,@Operation,@EntityType,@EntityKey,@FieldSummary,@PayloadJson,@PayloadHash,@ExpectedEchoHash,@DedupKey,@Status,
      CASE WHEN @Status=N''Pending'' THEN DATEADD(millisecond,-1,SYSUTCDATETIME()) END,@Actor);
    SET @OutboxMessageId=SCOPE_IDENTITY();
  END TRY
  BEGIN CATCH
    IF ERROR_NUMBER() IN (2601,2627)
    BEGIN
      SELECT @OutboxMessageId=OutboxMessageId FROM out.OutboxMessage WHERE OrganizationId=@OrganizationId AND DedupKey=@DedupKey AND Status IN (N''PendingApproval'',N''Pending'',N''Sending'',N''Sent'',N''Error'',N''Retry'');
      RETURN;
    END;
    THROW;
  END CATCH;
END;');
