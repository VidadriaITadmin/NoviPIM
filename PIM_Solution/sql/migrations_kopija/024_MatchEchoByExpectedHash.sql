SET XACT_ABORT ON;

EXEC(N'CREATE OR ALTER PROCEDURE out.VerifyEcho @OrganizationId int,@EntityType nvarchar(100),@EntityKey nvarchar(450),@InboundHash char(64),@ObservedUtc datetime2(3)
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON; BEGIN TRAN;
  DECLARE @MessageId bigint,@Expected char(64),@SentUtc datetime2(3);
  SELECT TOP(1) @MessageId=OutboxMessageId,@Expected=ExpectedEchoHash,@SentUtc=SentUtc
  FROM out.OutboxMessage WITH(UPDLOCK,ROWLOCK)
  WHERE OrganizationId=@OrganizationId AND EntityType=@EntityType AND EntityKey=@EntityKey AND Status=N''Sent''
    AND @ObservedUtc>=SentUtc AND ExpectedEchoHash=@InboundHash
  ORDER BY SentUtc DESC,OutboxMessageId DESC;
  IF @MessageId IS NULL
    SELECT TOP(1) @MessageId=OutboxMessageId,@Expected=ExpectedEchoHash,@SentUtc=SentUtc
    FROM out.OutboxMessage WITH(UPDLOCK,ROWLOCK)
    WHERE OrganizationId=@OrganizationId AND EntityType=@EntityType AND EntityKey=@EntityKey AND Status=N''Sent'' AND @ObservedUtc>=SentUtc
    ORDER BY SentUtc DESC,OutboxMessageId DESC;
  IF @MessageId IS NOT NULL
    UPDATE out.OutboxMessage SET Status=CASE WHEN @InboundHash=@Expected THEN N''Verified'' ELSE N''Drift'' END,
      VerifiedUtc=CASE WHEN @InboundHash=@Expected THEN SYSUTCDATETIME() END,
      DriftDetail=CASE WHEN @InboundHash<>@Expected THEN N''Prejeti echo se ne ujema s pričakovanim hashom.'' END,UpdatedUtc=SYSUTCDATETIME()
    WHERE OutboxMessageId=@MessageId;
  COMMIT;
END;');
