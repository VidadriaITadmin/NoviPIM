CREATE OR ALTER PROCEDURE ops.RecordPipelineStep
  @RunId uniqueidentifier,
  @StepCode nvarchar(100),
  @Status nvarchar(30),
  @Attempt smallint = 1,
  @RowsIn bigint = 0,
  @RowsMerged bigint = 0,
  @DurationMs bigint = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  IF @RunId IS NULL
    THROW 51010, 'RunId je obvezen.', 1;
  IF @StepCode IS NULL OR LEN(LTRIM(RTRIM(@StepCode))) = 0
    THROW 51011, 'StepCode je obvezen.', 1;
  IF @Attempt < 1
    THROW 51012, 'Attempt mora biti pozitiven.', 1;
  IF @RowsIn < 0 OR @RowsMerged < 0
    THROW 51013, 'Stevci ne smejo biti negativni.', 1;
  IF @DurationMs IS NOT NULL AND @DurationMs < 0
    THROW 51014, 'DurationMs ne sme biti negativen.', 1;
  IF @Status NOT IN (N'Pending', N'Running', N'Succeeded', N'Failed', N'Skipped')
    THROW 51015, 'Status koraka ni veljaven.', 1;
  IF NOT EXISTS (SELECT 1 FROM ops.PipelineRun WHERE RunId = @RunId)
    THROW 51016, 'PipelineRun ne obstaja.', 1;

  BEGIN TRY
    BEGIN TRANSACTION;

    UPDATE ops.PipelineStepLog WITH (UPDLOCK, SERIALIZABLE)
    SET RowsIn = @RowsIn,
        RowsMerged = @RowsMerged,
        DurationMs = @DurationMs,
        Status = @Status,
        RecordedUtc = SYSUTCDATETIME()
    WHERE RunId = @RunId
      AND StepCode = @StepCode
      AND Attempt = @Attempt;

    IF @@ROWCOUNT = 0
    BEGIN
      INSERT ops.PipelineStepLog (RunId, StepCode, Attempt, RowsIn, RowsMerged, DurationMs, Status)
      VALUES (@RunId, @StepCode, @Attempt, @RowsIn, @RowsMerged, @DurationMs, @Status);
    END;

    COMMIT TRANSACTION;
  END TRY
  BEGIN CATCH
    IF XACT_STATE() <> 0
      ROLLBACK TRANSACTION;

    DECLARE @ErrorMessage nvarchar(4000) = ERROR_MESSAGE();
    DECLARE @ErrorDetail nvarchar(2000) = CONCAT(N'Procedure=ops.RecordPipelineStep; ErrorNumber=', ERROR_NUMBER());

    EXEC ops.LogError
      @Layer = N'ops',
      @Severity = N'Error',
      @ErrorCode = N'RECORD_PIPELINE_STEP_FAILED',
      @Message = @ErrorMessage,
      @RunId = @RunId,
      @Detail = @ErrorDetail;

    THROW;
  END CATCH;
END;
