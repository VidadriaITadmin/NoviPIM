SET XACT_ABORT ON;

/*
  Sledenje sprememb je implementirano nad canon.*, ker NoviPIM nima stg.ProductCore/
  stg.ProductCommercial. canon.* je dejansko skupno zapisovalno križišče uvozov,
  XML preslikav in intranetnih read/write poti. Neznan vir se vedno zapiše kot NEZNANO.
*/
IF SCHEMA_ID(N'pim') IS NULL EXEC(N'CREATE SCHEMA pim');

IF OBJECT_ID(N'pim.FieldOwnership', N'U') IS NULL
BEGIN
  CREATE TABLE pim.FieldOwnership
  (
    FieldOwnershipId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_PimFieldOwnership PRIMARY KEY,
    FieldKey nvarchar(128) NOT NULL,
    Owner nvarchar(16) NOT NULL,
    CanonTable nvarchar(128) NOT NULL,
    CanonColumn nvarchar(128) NOT NULL,
    TrackHistory bit NOT NULL CONSTRAINT DF_PimFieldOwnership_TrackHistory DEFAULT (1),
    IsActive bit NOT NULL CONSTRAINT DF_PimFieldOwnership_IsActive DEFAULT (1),
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_PimFieldOwnership_UpdatedUtc DEFAULT SYSUTCDATETIME(),
    UpdatedBy nvarchar(200) NOT NULL CONSTRAINT DF_PimFieldOwnership_UpdatedBy DEFAULT N'MIGRATION',
    CONSTRAINT UQ_PimFieldOwnership_Field UNIQUE (FieldKey),
    CONSTRAINT CK_PimFieldOwnership_Owner CHECK (Owner IN (N'PIM', N'SAOP', N'SHARED')),
    CONSTRAINT CK_PimFieldOwnership_Location CHECK (CanonTable IN (N'canon.Product', N'canon.ProductCommercial'))
  );
END;

IF OBJECT_ID(N'pim.ProductChangeBatch', N'U') IS NULL
BEGIN
  CREATE TABLE pim.ProductChangeBatch
  (
    ChangeBatchId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_PimProductChangeBatch PRIMARY KEY,
    BatchId uniqueidentifier NOT NULL,
    ChangeSource nvarchar(32) NOT NULL,
    ChangedBy nvarchar(128) NOT NULL,
    ChangedAtUtc datetime2(3) NOT NULL CONSTRAINT DF_PimProductChangeBatch_ChangedAtUtc DEFAULT SYSUTCDATETIME(),
    OrganizationId int NULL,
    Note nvarchar(400) NULL,
    UndoOfBatchId bigint NULL,
    CONSTRAINT UQ_PimProductChangeBatch_Batch UNIQUE (BatchId),
    CONSTRAINT FK_PimProductChangeBatch_Undo FOREIGN KEY (UndoOfBatchId) REFERENCES pim.ProductChangeBatch(ChangeBatchId)
  );
END;

IF OBJECT_ID(N'pim.ProductFieldHistory', N'U') IS NULL
BEGIN
  CREATE TABLE pim.ProductFieldHistory
  (
    ChangeId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_PimProductFieldHistory PRIMARY KEY,
    ChangeBatchId bigint NOT NULL,
    OrganizationId int NOT NULL,
    ProductId bigint NOT NULL,
    ItemID nvarchar(100) NOT NULL,
    FieldKey nvarchar(128) NOT NULL,
    CanonTable nvarchar(128) NOT NULL,
    CanonColumn nvarchar(128) NOT NULL,
    Owner nvarchar(16) NOT NULL,
    OldValue nvarchar(400) NULL,
    NewValue nvarchar(400) NULL,
    ChangedAtUtc datetime2(3) NOT NULL CONSTRAINT DF_PimProductFieldHistory_ChangedAtUtc DEFAULT SYSUTCDATETIME(),
    OutboundQueueId bigint NULL,
    SentToSaopAtUtc datetime2(3) NULL,
    UndoOfChangeId bigint NULL,
    CONSTRAINT FK_PimProductFieldHistory_Batch FOREIGN KEY (ChangeBatchId) REFERENCES pim.ProductChangeBatch(ChangeBatchId),
    CONSTRAINT FK_PimProductFieldHistory_Product FOREIGN KEY (ProductId) REFERENCES canon.Product(ProductId),
    CONSTRAINT FK_PimProductFieldHistory_Undo FOREIGN KEY (UndoOfChangeId) REFERENCES pim.ProductFieldHistory(ChangeId)
  );
  CREATE INDEX IX_PimProductFieldHistory_Product ON pim.ProductFieldHistory(OrganizationId, ProductId, ChangedAtUtc DESC) INCLUDE(FieldKey, OldValue, NewValue, Owner, ChangeBatchId);
  CREATE INDEX IX_PimProductFieldHistory_Field ON pim.ProductFieldHistory(FieldKey, ChangedAtUtc DESC);
END;

/* Only verified columns are seeded. Field owner is deliberately SHARED until business ownership is explicitly configured. */
MERGE pim.FieldOwnership AS target
USING (VALUES
  (N'Product.EAN', N'SHARED', N'canon.Product', N'EAN'),
  (N'Product.IsActive', N'PIM', N'canon.Product', N'IsActive'),
  (N'Product.WebPublish', N'PIM', N'canon.Product', N'WebPublish'),
  (N'Product.UoM', N'SHARED', N'canon.Product', N'UoM'),
  (N'Product.ItemGroup', N'SHARED', N'canon.Product', N'ItemGroup'),
  (N'Product.Department', N'SHARED', N'canon.Product', N'Department'),
  (N'Product.Manufacturer', N'SHARED', N'canon.Product', N'Manufacturer'),
  (N'Product.Supplier', N'SHARED', N'canon.Product', N'Supplier'),
  (N'Product.DiscountGroup', N'SHARED', N'canon.Product', N'DiscountGroup'),
  (N'Product.AccountingGroup', N'SHARED', N'canon.Product', N'AccountingGroup'),
  (N'ProductCommercial.NetWeight', N'SHARED', N'canon.ProductCommercial', N'NetWeight'),
  (N'ProductCommercial.GrossWeight', N'SHARED', N'canon.ProductCommercial', N'GrossWeight'),
  (N'ProductCommercial.CustomsTariff', N'SHARED', N'canon.ProductCommercial', N'CustomsTariff'),
  (N'ProductCommercial.CountryOfOrigin', N'SHARED', N'canon.ProductCommercial', N'CountryOfOrigin'),
  (N'ProductCommercial.Pak1', N'SHARED', N'canon.ProductCommercial', N'Pak1'),
  (N'ProductCommercial.Pak2', N'SHARED', N'canon.ProductCommercial', N'Pak2'),
  (N'ProductCommercial.Dimensions', N'SHARED', N'canon.ProductCommercial', N'Dimensions')
) AS source(FieldKey, Owner, CanonTable, CanonColumn)
ON target.FieldKey = source.FieldKey
WHEN MATCHED THEN UPDATE SET Owner = source.Owner, CanonTable = source.CanonTable, CanonColumn = source.CanonColumn, TrackHistory = 1, IsActive = 1, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = N'MIGRATION'
WHEN NOT MATCHED THEN INSERT(FieldKey, Owner, CanonTable, CanonColumn, UpdatedBy) VALUES(source.FieldKey, source.Owner, source.CanonTable, source.CanonColumn, N'MIGRATION');

EXEC(N'
CREATE OR ALTER PROCEDURE pim.SetChangeContext
  @ChangeSource nvarchar(32), @ChangedBy nvarchar(128), @BatchId uniqueidentifier = NULL, @Note nvarchar(400) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  IF NULLIF(LTRIM(RTRIM(@ChangeSource)), N'''') IS NULL THROW 51200, ''Vir spremembe je obvezen.'', 1;
  IF NULLIF(LTRIM(RTRIM(@ChangedBy)), N'''') IS NULL THROW 51201, ''Izvajalec spremembe je obvezen.'', 1;
  DECLARE @EffectiveBatchId uniqueidentifier = COALESCE(@BatchId, NEWID());
  EXEC sys.sp_set_session_context @key=N''ChangeSource'', @value=@ChangeSource;
  EXEC sys.sp_set_session_context @key=N''ChangedBy'', @value=@ChangedBy;
  EXEC sys.sp_set_session_context @key=N''BatchId'', @value=@EffectiveBatchId;
  EXEC sys.sp_set_session_context @key=N''ChangeNote'', @value=@Note;
END;');

EXEC(N'
CREATE OR ALTER PROCEDURE pim.ClearChangeContext
AS
BEGIN
  SET NOCOUNT ON;
  EXEC sys.sp_set_session_context @key=N''ChangeSource'', @value=NULL;
  EXEC sys.sp_set_session_context @key=N''ChangedBy'', @value=NULL;
  EXEC sys.sp_set_session_context @key=N''BatchId'', @value=NULL;
  EXEC sys.sp_set_session_context @key=N''ChangeNote'', @value=NULL;
END;');

EXEC(N'
CREATE OR ALTER PROCEDURE pim.GetProductHistory @OrganizationId int, @ProductId bigint
AS
BEGIN
  SET NOCOUNT ON;
  SELECT history.ChangeId, history.ChangeBatchId, history.FieldKey, history.CanonTable, history.CanonColumn,
         history.Owner, history.OldValue, history.NewValue, history.ChangedAtUtc, history.SentToSaopAtUtc,
         batch.ChangeSource, batch.ChangedBy, batch.Note, history.UndoOfChangeId
  FROM pim.ProductFieldHistory history
  INNER JOIN pim.ProductChangeBatch batch ON batch.ChangeBatchId = history.ChangeBatchId
  WHERE history.OrganizationId = @OrganizationId AND history.ProductId = @ProductId
  ORDER BY history.ChangedAtUtc DESC, history.ChangeId DESC;
END;');

/* A real Ctrl+Z must call the normal save pipeline. No generic direct UPDATE is exposed here. */
EXEC(N'
CREATE OR ALTER PROCEDURE pim.RequestUndoProductField @OrganizationId int, @ChangeId bigint, @Actor nvarchar(128)
AS
BEGIN
  SET NOCOUNT ON;
  DECLARE @owner nvarchar(16), @newValue nvarchar(400), @undoOf bigint;
  SELECT @owner=Owner, @newValue=NewValue, @undoOf=UndoOfChangeId
  FROM pim.ProductFieldHistory WHERE ChangeId=@ChangeId AND OrganizationId=@OrganizationId;
  IF @owner IS NULL THROW 51210, ''Sprememba ne obstaja v aktivni organizaciji.'', 1;
  IF @undoOf IS NOT NULL THROW 51211, ''Izbrana sprememba je že razveljavitev; za redo izberi izvirno spremembo.'' , 1;
  IF @owner = N''SAOP'' THROW 51212, ''Polje je v lasti SAOP; razveljavitev bi se ob naslednjem zajemu prepisala.'', 1;
  THROW 51213, ''Razveljavitev zahteva namensko poslovno shranjevalno pot; neposredni UPDATE je namenoma prepovedan.'', 1;
END;');

EXEC(N'
CREATE OR ALTER TRIGGER canon.TR_Product_FieldHistory ON canon.Product AFTER UPDATE
AS
BEGIN
  SET NOCOUNT ON;
  IF ROWCOUNT_BIG() = 0 RETURN;
  DECLARE @batchId uniqueidentifier = TRY_CONVERT(uniqueidentifier, SESSION_CONTEXT(N''BatchId''));
  DECLARE @source nvarchar(32) = COALESCE(CONVERT(nvarchar(32), SESSION_CONTEXT(N''ChangeSource'')), N''NEZNANO'');
  DECLARE @actor nvarchar(128) = COALESCE(CONVERT(nvarchar(128), SESSION_CONTEXT(N''ChangedBy'')), SUSER_SNAME());
  DECLARE @note nvarchar(400) = CONVERT(nvarchar(400), SESSION_CONTEXT(N''ChangeNote''));
  DECLARE @batch bigint;
  SET @batchId = COALESCE(@batchId, NEWID());
  SELECT @batch = ChangeBatchId FROM pim.ProductChangeBatch WITH (UPDLOCK, HOLDLOCK) WHERE BatchId = @batchId;
  IF @batch IS NULL
  BEGIN
    INSERT pim.ProductChangeBatch(BatchId, ChangeSource, ChangedBy, OrganizationId, Note)
    VALUES(@batchId, @source, @actor, NULL, @note);
    SET @batch = SCOPE_IDENTITY();
  END;
  INSERT pim.ProductFieldHistory(ChangeBatchId, OrganizationId, ProductId, ItemID, FieldKey, CanonTable, CanonColumn, Owner, OldValue, NewValue)
  SELECT @batch, i.OrganizationId, i.ProductId, i.ItemID, mapped.FieldKey, N''canon.Product'', mapped.CanonColumn, ownership.Owner, mapped.OldValue, mapped.NewValue
  FROM inserted i INNER JOIN deleted d ON d.ProductId=i.ProductId
  CROSS APPLY (VALUES
    (N''Product.EAN'', N''EAN'', CONVERT(nvarchar(400),d.EAN), CONVERT(nvarchar(400),i.EAN)),
    (N''Product.IsActive'', N''IsActive'', CONVERT(nvarchar(400),d.IsActive), CONVERT(nvarchar(400),i.IsActive)),
    (N''Product.WebPublish'', N''WebPublish'', CONVERT(nvarchar(400),d.WebPublish), CONVERT(nvarchar(400),i.WebPublish)),
    (N''Product.UoM'', N''UoM'', CONVERT(nvarchar(400),d.UoM), CONVERT(nvarchar(400),i.UoM)),
    (N''Product.ItemGroup'', N''ItemGroup'', CONVERT(nvarchar(400),d.ItemGroup), CONVERT(nvarchar(400),i.ItemGroup)),
    (N''Product.Department'', N''Department'', CONVERT(nvarchar(400),d.Department), CONVERT(nvarchar(400),i.Department)),
    (N''Product.Manufacturer'', N''Manufacturer'', CONVERT(nvarchar(400),d.Manufacturer), CONVERT(nvarchar(400),i.Manufacturer)),
    (N''Product.Supplier'', N''Supplier'', CONVERT(nvarchar(400),d.Supplier), CONVERT(nvarchar(400),i.Supplier)),
    (N''Product.DiscountGroup'', N''DiscountGroup'', CONVERT(nvarchar(400),d.DiscountGroup), CONVERT(nvarchar(400),i.DiscountGroup)),
    (N''Product.AccountingGroup'', N''AccountingGroup'', CONVERT(nvarchar(400),d.AccountingGroup), CONVERT(nvarchar(400),i.AccountingGroup))
  ) mapped(FieldKey, CanonColumn, OldValue, NewValue)
  INNER JOIN pim.FieldOwnership ownership ON ownership.FieldKey=mapped.FieldKey AND ownership.IsActive=1 AND ownership.TrackHistory=1
  WHERE EXISTS(SELECT mapped.OldValue EXCEPT SELECT mapped.NewValue);
  IF NOT EXISTS(SELECT 1 FROM pim.ProductFieldHistory WHERE ChangeBatchId=@batch) DELETE pim.ProductChangeBatch WHERE ChangeBatchId=@batch;
END;');

EXEC(N'
CREATE OR ALTER TRIGGER canon.TR_ProductCommercial_FieldHistory ON canon.ProductCommercial AFTER UPDATE
AS
BEGIN
  SET NOCOUNT ON;
  IF ROWCOUNT_BIG() = 0 RETURN;
  DECLARE @batchId uniqueidentifier = TRY_CONVERT(uniqueidentifier, SESSION_CONTEXT(N''BatchId''));
  DECLARE @source nvarchar(32) = COALESCE(CONVERT(nvarchar(32), SESSION_CONTEXT(N''ChangeSource'')), N''NEZNANO'');
  DECLARE @actor nvarchar(128) = COALESCE(CONVERT(nvarchar(128), SESSION_CONTEXT(N''ChangedBy'')), SUSER_SNAME());
  DECLARE @note nvarchar(400) = CONVERT(nvarchar(400), SESSION_CONTEXT(N''ChangeNote''));
  DECLARE @batch bigint;
  SET @batchId = COALESCE(@batchId, NEWID());
  SELECT @batch = ChangeBatchId FROM pim.ProductChangeBatch WITH (UPDLOCK, HOLDLOCK) WHERE BatchId = @batchId;
  IF @batch IS NULL
  BEGIN
    INSERT pim.ProductChangeBatch(BatchId, ChangeSource, ChangedBy, Note) VALUES(@batchId, @source, @actor, @note);
    SET @batch = SCOPE_IDENTITY();
  END;
  INSERT pim.ProductFieldHistory(ChangeBatchId, OrganizationId, ProductId, ItemID, FieldKey, CanonTable, CanonColumn, Owner, OldValue, NewValue)
  SELECT @batch, product.OrganizationId, product.ProductId, product.ItemID, mapped.FieldKey, N''canon.ProductCommercial'', mapped.CanonColumn, ownership.Owner, mapped.OldValue, mapped.NewValue
  FROM inserted i INNER JOIN deleted d ON d.ProductCommercialId=i.ProductCommercialId
  INNER JOIN canon.Product product ON product.ProductId=i.ProductId
  CROSS APPLY (VALUES
    (N''ProductCommercial.NetWeight'', N''NetWeight'', CONVERT(nvarchar(400),d.NetWeight), CONVERT(nvarchar(400),i.NetWeight)),
    (N''ProductCommercial.GrossWeight'', N''GrossWeight'', CONVERT(nvarchar(400),d.GrossWeight), CONVERT(nvarchar(400),i.GrossWeight)),
    (N''ProductCommercial.CustomsTariff'', N''CustomsTariff'', CONVERT(nvarchar(400),d.CustomsTariff), CONVERT(nvarchar(400),i.CustomsTariff)),
    (N''ProductCommercial.CountryOfOrigin'', N''CountryOfOrigin'', CONVERT(nvarchar(400),d.CountryOfOrigin), CONVERT(nvarchar(400),i.CountryOfOrigin)),
    (N''ProductCommercial.Pak1'', N''Pak1'', CONVERT(nvarchar(400),d.Pak1), CONVERT(nvarchar(400),i.Pak1)),
    (N''ProductCommercial.Pak2'', N''Pak2'', CONVERT(nvarchar(400),d.Pak2), CONVERT(nvarchar(400),i.Pak2)),
    (N''ProductCommercial.Dimensions'', N''Dimensions'', CONVERT(nvarchar(400),d.Dimensions), CONVERT(nvarchar(400),i.Dimensions))
  ) mapped(FieldKey, CanonColumn, OldValue, NewValue)
  INNER JOIN pim.FieldOwnership ownership ON ownership.FieldKey=mapped.FieldKey AND ownership.IsActive=1 AND ownership.TrackHistory=1
  WHERE EXISTS(SELECT mapped.OldValue EXCEPT SELECT mapped.NewValue);
  IF NOT EXISTS(SELECT 1 FROM pim.ProductFieldHistory WHERE ChangeBatchId=@batch) DELETE pim.ProductChangeBatch WHERE ChangeBatchId=@batch;
END;');
