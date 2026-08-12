SET XACT_ABORT ON;

/* Harden undo failure handling: session context must never leak past a failed undo. */
EXEC(N'
CREATE OR ALTER PROCEDURE pim.UndoProductField
  @OrganizationId int,
  @ChangeId bigint,
  @Actor nvarchar(128),
  @UndoBatchGuid uniqueidentifier = NULL,
  @UndoOfBatchId bigint = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  IF NULLIF(LTRIM(RTRIM(@Actor)),N'''') IS NULL THROW 51220, ''Izvajalec razveljavitve je obvezen.'', 1;

  DECLARE @ProductId bigint,@FieldKey nvarchar(128),@CanonTable nvarchar(128),@CanonColumn nvarchar(128),
    @Owner nvarchar(16),@OldValue nvarchar(400),@NewValue nvarchar(400),@OriginalBatchId bigint,
    @CurrentValue nvarchar(400),@UndoBatchId bigint,@UndoNote nvarchar(400);
  SET @UndoBatchGuid=COALESCE(@UndoBatchGuid,NEWID());

  BEGIN TRY
    BEGIN TRANSACTION;
    SELECT @ProductId=history.ProductId,@FieldKey=history.FieldKey,@CanonTable=history.CanonTable,@CanonColumn=history.CanonColumn,
      @Owner=history.Owner,@OldValue=history.OldValue,@NewValue=history.NewValue,@OriginalBatchId=history.ChangeBatchId
    FROM pim.ProductFieldHistory history WITH(UPDLOCK,HOLDLOCK)
    WHERE history.ChangeId=@ChangeId AND history.OrganizationId=@OrganizationId;

    IF @ProductId IS NULL THROW 51221, ''Sprememba ne obstaja v aktivni organizaciji.'', 1;
    IF EXISTS(SELECT 1 FROM pim.ProductFieldHistory WHERE UndoOfChangeId=@ChangeId) THROW 51222, ''Sprememba je že razveljavljena; za redo razveljavi njen undo zapis.'', 1;
    IF @Owner<>N''PIM'' THROW 51223, ''Razveljavitev je dovoljena samo za polja v lasti PIM; SAOP in skupna polja se ne prepisujejo.'', 1;
    IF @CanonTable<>N''canon.Product'' OR @CanonColumn NOT IN(N''WebPublish'',N''IsActive'') THROW 51224, ''Za to PIM polje še ni konfigurirana varna poslovna pot razveljavitve.'', 1;

    SELECT @CurrentValue=CASE @CanonColumn WHEN N''WebPublish'' THEN CONVERT(nvarchar(400),product.WebPublish) WHEN N''IsActive'' THEN CONVERT(nvarchar(400),product.IsActive) END
    FROM canon.Product product WITH(UPDLOCK,HOLDLOCK) WHERE product.ProductId=@ProductId AND product.OrganizationId=@OrganizationId;
    IF NOT EXISTS(SELECT @NewValue EXCEPT SELECT @CurrentValue) THROW 51225, ''Razveljavitev je ustavljena: trenutna vrednost ni več vrednost izbrane spremembe.'', 1;
    IF TRY_CONVERT(bit,@OldValue) IS NULL THROW 51226, ''Stara vrednost ni veljavna za varno razveljavitev logičnega polja.'', 1;

    SET @UndoNote=N''Razveljavitev spremembe ''+CONVERT(nvarchar(30),@ChangeId);
    EXEC pim.SetChangeContext @ChangeSource=N''UNDO'',@ChangedBy=@Actor,@BatchId=@UndoBatchGuid,@Note=@UndoNote;
    UPDATE canon.Product SET WebPublish=CASE WHEN @CanonColumn=N''WebPublish'' THEN CONVERT(bit,@OldValue) ELSE WebPublish END,
      IsActive=CASE WHEN @CanonColumn=N''IsActive'' THEN CONVERT(bit,@OldValue) ELSE IsActive END
    WHERE ProductId=@ProductId AND OrganizationId=@OrganizationId;
    EXEC pim.ClearChangeContext;

    SELECT @UndoBatchId=ChangeBatchId FROM pim.ProductChangeBatch WITH(UPDLOCK,HOLDLOCK) WHERE BatchId=@UndoBatchGuid;
    IF @UndoBatchId IS NULL THROW 51227, ''Razveljavitev ni ustvarila zgodovinskega paketa.'', 1;
    UPDATE pim.ProductChangeBatch SET UndoOfBatchId=COALESCE(@UndoOfBatchId,@OriginalBatchId) WHERE ChangeBatchId=@UndoBatchId;
    UPDATE pim.ProductFieldHistory SET UndoOfChangeId=@ChangeId
    WHERE ChangeBatchId=@UndoBatchId AND ProductId=@ProductId AND FieldKey=@FieldKey AND UndoOfChangeId IS NULL;
    IF @@ROWCOUNT<>1 THROW 51228, ''Razveljavitev ni ustvarila natanko ene sledljive spremembe polja.'', 1;
    COMMIT TRANSACTION;
  END TRY
  BEGIN CATCH
    IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
    EXEC pim.ClearChangeContext;
    THROW;
  END CATCH
END;');

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
  BEGIN TRY
    BEGIN TRANSACTION;
    IF NOT EXISTS(SELECT 1 FROM pim.ProductChangeBatch WITH(UPDLOCK,HOLDLOCK) WHERE ChangeBatchId=@ChangeBatchId AND (OrganizationId=@OrganizationId OR OrganizationId IS NULL)) THROW 51229, ''Paket sprememb ne obstaja v aktivni organizaciji.'', 1;
    IF NOT EXISTS(SELECT 1 FROM pim.ProductFieldHistory WHERE ChangeBatchId=@ChangeBatchId AND OrganizationId=@OrganizationId) THROW 51236, ''Paket ne vsebuje razveljavljivih sprememb aktivne organizacije.'', 1;
    IF EXISTS(SELECT 1 FROM pim.ProductFieldHistory history WHERE history.ChangeBatchId=@ChangeBatchId AND history.OrganizationId=@OrganizationId AND (history.Owner<>N''PIM'' OR history.CanonTable<>N''canon.Product'' OR history.CanonColumn NOT IN(N''WebPublish'',N''IsActive''))) THROW 51230, ''Paket vsebuje polje brez varne PIM poti razveljavitve.'', 1;
    IF EXISTS(SELECT 1 FROM pim.ProductFieldHistory history WHERE history.ChangeBatchId=@ChangeBatchId AND history.OrganizationId=@OrganizationId AND EXISTS(SELECT 1 FROM pim.ProductFieldHistory undoHistory WHERE undoHistory.UndoOfChangeId=history.ChangeId)) THROW 51231, ''Paket vsebuje že razveljavljeno spremembo.'', 1;

    DECLARE undo_cursor CURSOR LOCAL FAST_FORWARD FOR SELECT ChangeId FROM pim.ProductFieldHistory WHERE ChangeBatchId=@ChangeBatchId AND OrganizationId=@OrganizationId ORDER BY ChangeId DESC;
    OPEN undo_cursor;
    FETCH NEXT FROM undo_cursor INTO @ChangeId;
    WHILE @@FETCH_STATUS=0
    BEGIN
      EXEC pim.UndoProductField @OrganizationId=@OrganizationId,@ChangeId=@ChangeId,@Actor=@Actor,@UndoBatchGuid=@UndoBatchGuid,@UndoOfBatchId=@ChangeBatchId;
      FETCH NEXT FROM undo_cursor INTO @ChangeId;
    END;
    CLOSE undo_cursor;
    DEALLOCATE undo_cursor;
    EXEC pim.ClearChangeContext;
    COMMIT TRANSACTION;
  END TRY
  BEGIN CATCH
    IF CURSOR_STATUS(''local'',''undo_cursor'')>=-1 CLOSE undo_cursor;
    IF CURSOR_STATUS(''local'',''undo_cursor'')>-3 DEALLOCATE undo_cursor;
    IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
    EXEC pim.ClearChangeContext;
    THROW;
  END CATCH
END;');
