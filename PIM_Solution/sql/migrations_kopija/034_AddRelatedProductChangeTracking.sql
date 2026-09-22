SET XACT_ABORT ON;

/* S7: set-based history for text, attributes and media. */
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE parent_object_id=OBJECT_ID(N'pim.FieldOwnership') AND name=N'CK_PimFieldOwnership_Location')
  ALTER TABLE pim.FieldOwnership DROP CONSTRAINT CK_PimFieldOwnership_Location;
ALTER TABLE pim.FieldOwnership WITH CHECK ADD CONSTRAINT CK_PimFieldOwnership_Location
  CHECK (CanonTable IN (N'canon.Product',N'canon.ProductCommercial',N'canon.ProductText',N'canon.ProductAttribute',N'canon.ProductMedia'));

MERGE pim.FieldOwnership AS target
USING (VALUES
  (N'ProductText.Value',N'SHARED',N'canon.ProductText',N'Value'),
  (N'ProductAttribute.Value',N'SHARED',N'canon.ProductAttribute',N'Value'),
  (N'ProductMedia.Url',N'SHARED',N'canon.ProductMedia',N'Url')
) source(FieldKey,Owner,CanonTable,CanonColumn)
ON target.FieldKey=source.FieldKey
WHEN MATCHED THEN UPDATE SET Owner=source.Owner,CanonTable=source.CanonTable,CanonColumn=source.CanonColumn,TrackHistory=1,IsActive=1,UpdatedUtc=SYSUTCDATETIME(),UpdatedBy=N'MIGRATION'
WHEN NOT MATCHED THEN INSERT(FieldKey,Owner,CanonTable,CanonColumn,UpdatedBy) VALUES(source.FieldKey,source.Owner,source.CanonTable,source.CanonColumn,N'MIGRATION');

EXEC(N'
CREATE OR ALTER TRIGGER canon.TR_ProductText_FieldHistory ON canon.ProductText AFTER INSERT,UPDATE,DELETE
AS
BEGIN
  DECLARE @rows bigint=ROWCOUNT_BIG(); SET NOCOUNT ON; IF @rows=0 RETURN;
  DECLARE @batchId uniqueidentifier=COALESCE(TRY_CONVERT(uniqueidentifier,SESSION_CONTEXT(N''BatchId'')),NEWID()),@batch bigint,
    @source nvarchar(32)=COALESCE(CONVERT(nvarchar(32),SESSION_CONTEXT(N''ChangeSource'')),N''NEZNANO''),
    @actor nvarchar(128)=COALESCE(CONVERT(nvarchar(128),SESSION_CONTEXT(N''ChangedBy'')),SUSER_SNAME()),@note nvarchar(400)=CONVERT(nvarchar(400),SESSION_CONTEXT(N''ChangeNote''));
  SELECT @batch=ChangeBatchId FROM pim.ProductChangeBatch WITH(UPDLOCK,HOLDLOCK) WHERE BatchId=@batchId;
  IF @batch IS NULL BEGIN INSERT pim.ProductChangeBatch(BatchId,ChangeSource,ChangedBy,Note) VALUES(@batchId,@source,@actor,@note); SET @batch=SCOPE_IDENTITY(); END;
  INSERT pim.ProductFieldHistory(ChangeBatchId,OrganizationId,ProductId,ItemID,FieldKey,CanonTable,CanonColumn,Owner,OldValue,NewValue)
  SELECT @batch,p.OrganizationId,p.ProductId,p.ItemID,N''ProductText.Value'',N''canon.ProductText'',COALESCE(i.TextType,d.TextType)+N''.''+COALESCE(i.Lang,d.Lang),ownership.Owner,CONVERT(nvarchar(400),d.Value),CONVERT(nvarchar(400),i.Value)
  FROM inserted i FULL OUTER JOIN deleted d ON d.ProductTextId=i.ProductTextId
  INNER JOIN canon.Product p ON p.ProductId=COALESCE(i.ProductId,d.ProductId)
  INNER JOIN pim.FieldOwnership ownership ON ownership.FieldKey=N''ProductText.Value'' AND ownership.IsActive=1 AND ownership.TrackHistory=1
  WHERE EXISTS(SELECT CONVERT(nvarchar(400),d.Value) EXCEPT SELECT CONVERT(nvarchar(400),i.Value));
  IF NOT EXISTS(SELECT 1 FROM pim.ProductFieldHistory WHERE ChangeBatchId=@batch) DELETE pim.ProductChangeBatch WHERE ChangeBatchId=@batch;
END;');

EXEC(N'
CREATE OR ALTER TRIGGER canon.TR_ProductAttribute_FieldHistory ON canon.ProductAttribute AFTER INSERT,UPDATE,DELETE
AS
BEGIN
  DECLARE @rows bigint=ROWCOUNT_BIG(); SET NOCOUNT ON; IF @rows=0 RETURN;
  DECLARE @batchId uniqueidentifier=COALESCE(TRY_CONVERT(uniqueidentifier,SESSION_CONTEXT(N''BatchId'')),NEWID()),@batch bigint,
    @source nvarchar(32)=COALESCE(CONVERT(nvarchar(32),SESSION_CONTEXT(N''ChangeSource'')),N''NEZNANO''),
    @actor nvarchar(128)=COALESCE(CONVERT(nvarchar(128),SESSION_CONTEXT(N''ChangedBy'')),SUSER_SNAME()),@note nvarchar(400)=CONVERT(nvarchar(400),SESSION_CONTEXT(N''ChangeNote''));
  SELECT @batch=ChangeBatchId FROM pim.ProductChangeBatch WITH(UPDLOCK,HOLDLOCK) WHERE BatchId=@batchId;
  IF @batch IS NULL BEGIN INSERT pim.ProductChangeBatch(BatchId,ChangeSource,ChangedBy,Note) VALUES(@batchId,@source,@actor,@note); SET @batch=SCOPE_IDENTITY(); END;
  INSERT pim.ProductFieldHistory(ChangeBatchId,OrganizationId,ProductId,ItemID,FieldKey,CanonTable,CanonColumn,Owner,OldValue,NewValue)
  SELECT @batch,p.OrganizationId,p.ProductId,p.ItemID,N''ProductAttribute.Value'',N''canon.ProductAttribute'',COALESCE(i.AttributeCode,d.AttributeCode),ownership.Owner,CONVERT(nvarchar(400),d.Value),CONVERT(nvarchar(400),i.Value)
  FROM inserted i FULL OUTER JOIN deleted d ON d.ProductAttributeId=i.ProductAttributeId
  INNER JOIN canon.Product p ON p.ProductId=COALESCE(i.ProductId,d.ProductId)
  INNER JOIN pim.FieldOwnership ownership ON ownership.FieldKey=N''ProductAttribute.Value'' AND ownership.IsActive=1 AND ownership.TrackHistory=1
  WHERE EXISTS(SELECT CONVERT(nvarchar(400),d.Value) EXCEPT SELECT CONVERT(nvarchar(400),i.Value));
  IF NOT EXISTS(SELECT 1 FROM pim.ProductFieldHistory WHERE ChangeBatchId=@batch) DELETE pim.ProductChangeBatch WHERE ChangeBatchId=@batch;
END;');

EXEC(N'
CREATE OR ALTER TRIGGER canon.TR_ProductMedia_FieldHistory ON canon.ProductMedia AFTER INSERT,UPDATE,DELETE
AS
BEGIN
  DECLARE @rows bigint=ROWCOUNT_BIG(); SET NOCOUNT ON; IF @rows=0 RETURN;
  DECLARE @batchId uniqueidentifier=COALESCE(TRY_CONVERT(uniqueidentifier,SESSION_CONTEXT(N''BatchId'')),NEWID()),@batch bigint,
    @source nvarchar(32)=COALESCE(CONVERT(nvarchar(32),SESSION_CONTEXT(N''ChangeSource'')),N''NEZNANO''),
    @actor nvarchar(128)=COALESCE(CONVERT(nvarchar(128),SESSION_CONTEXT(N''ChangedBy'')),SUSER_SNAME()),@note nvarchar(400)=CONVERT(nvarchar(400),SESSION_CONTEXT(N''ChangeNote''));
  SELECT @batch=ChangeBatchId FROM pim.ProductChangeBatch WITH(UPDLOCK,HOLDLOCK) WHERE BatchId=@batchId;
  IF @batch IS NULL BEGIN INSERT pim.ProductChangeBatch(BatchId,ChangeSource,ChangedBy,Note) VALUES(@batchId,@source,@actor,@note); SET @batch=SCOPE_IDENTITY(); END;
  INSERT pim.ProductFieldHistory(ChangeBatchId,OrganizationId,ProductId,ItemID,FieldKey,CanonTable,CanonColumn,Owner,OldValue,NewValue)
  SELECT @batch,p.OrganizationId,p.ProductId,p.ItemID,N''ProductMedia.Url'',N''canon.ProductMedia'',COALESCE(i.Role,d.Role)+N''.''+CONVERT(nvarchar(20),COALESCE(i.SortOrder,d.SortOrder)),ownership.Owner,CONVERT(nvarchar(400),d.Url),CONVERT(nvarchar(400),i.Url)
  FROM inserted i FULL OUTER JOIN deleted d ON d.ProductMediaId=i.ProductMediaId
  INNER JOIN canon.Product p ON p.ProductId=COALESCE(i.ProductId,d.ProductId)
  INNER JOIN pim.FieldOwnership ownership ON ownership.FieldKey=N''ProductMedia.Url'' AND ownership.IsActive=1 AND ownership.TrackHistory=1
  WHERE EXISTS(SELECT CONVERT(nvarchar(400),d.Url) EXCEPT SELECT CONVERT(nvarchar(400),i.Url));
  IF NOT EXISTS(SELECT 1 FROM pim.ProductFieldHistory WHERE ChangeBatchId=@batch) DELETE pim.ProductChangeBatch WHERE ChangeBatchId=@batch;
END;');
