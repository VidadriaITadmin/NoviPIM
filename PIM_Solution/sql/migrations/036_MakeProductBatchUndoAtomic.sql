SET XACT_ABORT ON;

/* S6 uses one new undo batch for every field in the original batch. */
DECLARE @fieldDefinition nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'pim.UndoProductField'));
IF @fieldDefinition IS NULL THROW 51234, 'Manjka procedura pim.UndoProductField.', 1;

SET @fieldDefinition = REPLACE(
  @fieldDefinition,
  N'  @Actor nvarchar(128)' + CHAR(10) + N'AS',
  N'  @Actor nvarchar(128), @UndoBatchGuid uniqueidentifier = NULL, @UndoOfBatchId bigint = NULL' + CHAR(10) + N'AS');
SET @fieldDefinition = REPLACE(
  @fieldDefinition,
  N'@CurrentValue nvarchar(400), @UndoBatchGuid uniqueidentifier = NEWID(), @UndoBatchId bigint,',
  N'@CurrentValue nvarchar(400), @UndoBatchId bigint,');
SET @fieldDefinition = REPLACE(
  @fieldDefinition,
  N'  BEGIN TRANSACTION;',
  N'  SET @UndoBatchGuid=COALESCE(@UndoBatchGuid,NEWID());' + CHAR(10) + N'  BEGIN TRANSACTION;');
SET @fieldDefinition = REPLACE(
  @fieldDefinition,
  N'UPDATE pim.ProductChangeBatch SET UndoOfBatchId=@OriginalBatchId WHERE ChangeBatchId=@UndoBatchId;',
  N'UPDATE pim.ProductChangeBatch SET UndoOfBatchId=COALESCE(@UndoOfBatchId,@OriginalBatchId) WHERE ChangeBatchId=@UndoBatchId;');
IF @fieldDefinition NOT LIKE N'%@UndoBatchGuid uniqueidentifier = NULL%'
  OR @fieldDefinition NOT LIKE N'%UndoOfBatchId=COALESCE(@UndoOfBatchId,@OriginalBatchId)%'
  THROW 51235, 'Podpisa skupnega undo batcha ni bilo mogoče pripraviti.', 1;
SET @fieldDefinition = STUFF(@fieldDefinition, CHARINDEX(N'PROCEDURE', @fieldDefinition), 9, N'OR ALTER PROCEDURE');
EXEC sys.sp_executesql @fieldDefinition;

EXEC(N'
CREATE OR ALTER PROCEDURE pim.UndoProductBatch
  @OrganizationId int,
  @ChangeBatchId bigint,
  @Actor nvarchar(128)
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  DECLARE @UndoBatchGuid uniqueidentifier=NEWID(),@ChangeId bigint;
  IF NOT EXISTS(SELECT 1 FROM pim.ProductChangeBatch WHERE ChangeBatchId=@ChangeBatchId AND (OrganizationId=@OrganizationId OR OrganizationId IS NULL))
    THROW 51229, ''Paket sprememb ne obstaja v aktivni organizaciji.'', 1;
  IF EXISTS
  (
    SELECT 1 FROM pim.ProductFieldHistory history
    WHERE history.ChangeBatchId=@ChangeBatchId AND history.OrganizationId=@OrganizationId
      AND (history.Owner<>N''PIM'' OR history.CanonTable<>N''canon.Product'' OR history.CanonColumn NOT IN(N''WebPublish'',N''IsActive''))
  ) THROW 51230, ''Paket vsebuje polje brez varne PIM poti razveljavitve.'', 1;
  IF EXISTS
  (
    SELECT 1 FROM pim.ProductFieldHistory history
    WHERE history.ChangeBatchId=@ChangeBatchId AND history.OrganizationId=@OrganizationId
      AND EXISTS(SELECT 1 FROM pim.ProductFieldHistory undoHistory WHERE undoHistory.UndoOfChangeId=history.ChangeId)
  ) THROW 51231, ''Paket vsebuje že razveljavljeno spremembo.'', 1;

  BEGIN TRANSACTION;
  DECLARE undo_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT ChangeId FROM pim.ProductFieldHistory
    WHERE ChangeBatchId=@ChangeBatchId AND OrganizationId=@OrganizationId
    ORDER BY ChangeId DESC;
  OPEN undo_cursor;
  FETCH NEXT FROM undo_cursor INTO @ChangeId;
  WHILE @@FETCH_STATUS=0
  BEGIN
    EXEC pim.UndoProductField @OrganizationId=@OrganizationId,@ChangeId=@ChangeId,@Actor=@Actor,
      @UndoBatchGuid=@UndoBatchGuid,@UndoOfBatchId=@ChangeBatchId;
    FETCH NEXT FROM undo_cursor INTO @ChangeId;
  END;
  CLOSE undo_cursor;
  DEALLOCATE undo_cursor;
  EXEC pim.ClearChangeContext;
  COMMIT TRANSACTION;
END;');
