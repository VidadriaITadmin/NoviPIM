SET XACT_ABORT ON;

IF OBJECT_ID(N'out.ExportProfile', N'U') IS NULL
BEGIN
  CREATE TABLE out.ExportProfile
  (
    ExportProfileId int IDENTITY(1,1) NOT NULL,
    ProfileCode nvarchar(100) NOT NULL,
    Name nvarchar(200) NOT NULL,
    ChannelCode nvarchar(100) NOT NULL,
    EntityType nvarchar(100) NOT NULL,
    IsActive bit NOT NULL CONSTRAINT DF_ExportProfile_IsActive DEFAULT (1),
    CreatedUtc datetime2(3) NOT NULL CONSTRAINT DF_ExportProfile_CreatedUtc DEFAULT SYSUTCDATETIME(),
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_ExportProfile_UpdatedUtc DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_ExportProfile PRIMARY KEY CLUSTERED (ExportProfileId),
    CONSTRAINT UQ_ExportProfile_ProfileCode UNIQUE (ProfileCode)
  );
END;

IF OBJECT_ID(N'out.ExportColumn', N'U') IS NULL
BEGIN
  CREATE TABLE out.ExportColumn
  (
    ExportColumnId int IDENTITY(1,1) NOT NULL,
    ExportProfileId int NOT NULL,
    ColumnCode nvarchar(100) NOT NULL,
    OutputColumnName nvarchar(200) NOT NULL,
    CanonicalFieldCode nvarchar(200) NOT NULL,
    SortOrder int NOT NULL,
    IsRequired bit NOT NULL CONSTRAINT DF_ExportColumn_IsRequired DEFAULT (0),
    IsActive bit NOT NULL CONSTRAINT DF_ExportColumn_IsActive DEFAULT (1),
    CONSTRAINT PK_ExportColumn PRIMARY KEY CLUSTERED (ExportColumnId),
    CONSTRAINT UQ_ExportColumn_ProfileCode UNIQUE (ExportProfileId, ColumnCode),
    CONSTRAINT UQ_ExportColumn_ProfileOrder UNIQUE (ExportProfileId, SortOrder),
    CONSTRAINT CK_ExportColumn_SortOrder CHECK (SortOrder > 0),
    CONSTRAINT FK_ExportColumn_ExportProfile FOREIGN KEY (ExportProfileId) REFERENCES out.ExportProfile (ExportProfileId)
  );
END;

IF OBJECT_ID(N'val.ValidationProfile', N'U') IS NULL
BEGIN
  CREATE TABLE val.ValidationProfile
  (
    ValidationProfileId int IDENTITY(1,1) NOT NULL,
    ProfileCode nvarchar(100) NOT NULL,
    Name nvarchar(200) NOT NULL,
    ExportProfileId int NOT NULL,
    IsActive bit NOT NULL CONSTRAINT DF_ValidationProfile_IsActive DEFAULT (1),
    CONSTRAINT PK_ValidationProfile PRIMARY KEY CLUSTERED (ValidationProfileId),
    CONSTRAINT UQ_ValidationProfile_ProfileCode UNIQUE (ProfileCode),
    CONSTRAINT UQ_ValidationProfile_ExportProfile UNIQUE (ExportProfileId),
    CONSTRAINT FK_ValidationProfile_ExportProfile FOREIGN KEY (ExportProfileId) REFERENCES out.ExportProfile (ExportProfileId)
  );
END;

IF OBJECT_ID(N'val.FieldRequirement', N'U') IS NULL
BEGIN
  CREATE TABLE val.FieldRequirement
  (
    FieldRequirementId int IDENTITY(1,1) NOT NULL,
    ValidationProfileId int NOT NULL,
    SourceExportColumnId int NOT NULL,
    FieldCode nvarchar(200) NOT NULL,
    IsRequired bit NOT NULL,
    IsActive bit NOT NULL CONSTRAINT DF_FieldRequirement_IsActive DEFAULT (1),
    CONSTRAINT PK_FieldRequirement PRIMARY KEY CLUSTERED (FieldRequirementId),
    CONSTRAINT UQ_FieldRequirement_ProfileColumn UNIQUE (ValidationProfileId, SourceExportColumnId),
    CONSTRAINT FK_FieldRequirement_ValidationProfile FOREIGN KEY (ValidationProfileId) REFERENCES val.ValidationProfile (ValidationProfileId),
    CONSTRAINT FK_FieldRequirement_ExportColumn FOREIGN KEY (SourceExportColumnId) REFERENCES out.ExportColumn (ExportColumnId)
  );
END;

MERGE out.ExportProfile AS target
USING (VALUES
  (N'ERP_L1', N'ERP L1 — osnovni katalog', N'ERP', N'PRODUCTS', CONVERT(bit, 1)),
  (N'WEB_B2C_PRODUCTS', N'Products CSV — svetila.si B2C', N'SVETILA_SI_B2C', N'PRODUCTS', CONVERT(bit, 1))
) AS source (ProfileCode, Name, ChannelCode, EntityType, IsActive)
ON target.ProfileCode = source.ProfileCode
WHEN MATCHED AND (target.Name <> source.Name OR target.ChannelCode <> source.ChannelCode OR target.EntityType <> source.EntityType OR target.IsActive <> source.IsActive) THEN
  UPDATE SET Name = source.Name, ChannelCode = source.ChannelCode, EntityType = source.EntityType, IsActive = source.IsActive, UpdatedUtc = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN
  INSERT (ProfileCode, Name, ChannelCode, EntityType, IsActive) VALUES (source.ProfileCode, source.Name, source.ChannelCode, source.EntityType, source.IsActive);

MERGE out.ExportColumn AS target
USING (
  SELECT profile.ExportProfileId, source.ColumnCode, source.OutputColumnName, source.CanonicalFieldCode, source.SortOrder, source.IsRequired, source.IsActive
  FROM (VALUES
    (N'ERP_L1', N'ITEM_ID', N'sku', N'Product.ItemID', 10, CONVERT(bit, 1), CONVERT(bit, 1)),
    (N'ERP_L1', N'EAN', N'ean', N'Product.EAN', 20, CONVERT(bit, 1), CONVERT(bit, 1)),
    (N'ERP_L1', N'TITLE_SL', N'name_sl', N'ProductText.TITLE_ERP.sl', 30, CONVERT(bit, 1), CONVERT(bit, 1)),
    (N'ERP_L1', N'UOM', N'uom', N'Product.UoM', 40, CONVERT(bit, 1), CONVERT(bit, 1)),
    (N'ERP_L1', N'SUPPLIER', N'supplier', N'Product.Supplier', 50, CONVERT(bit, 1), CONVERT(bit, 1)),
    (N'ERP_L1', N'MANUFACTURER', N'manufacturer', N'Product.Manufacturer', 60, CONVERT(bit, 1), CONVERT(bit, 1)),
    (N'ERP_L1', N'ACCOUNTING_GROUP', N'accounting_group', N'Product.AccountingGroup', 70, CONVERT(bit, 1), CONVERT(bit, 1)),
    (N'ERP_L1', N'DISCOUNT_GROUP', N'discount_group', N'Product.DiscountGroup', 80, CONVERT(bit, 1), CONVERT(bit, 1)),
    (N'ERP_L1', N'VAT_RATE', N'vat_rate', N'ProductPrice.VatRate', 90, CONVERT(bit, 1), CONVERT(bit, 1)),
    (N'WEB_B2C_PRODUCTS', N'WEB_TITLE_SL', N'name', N'ProductText.WEB_TITLE.sl', 10, CONVERT(bit, 1), CONVERT(bit, 1)),
    (N'WEB_B2C_PRODUCTS', N'EAN', N'ean', N'Product.EAN', 20, CONVERT(bit, 1), CONVERT(bit, 1)),
    (N'WEB_B2C_PRODUCTS', N'CATEGORY_PATH', N'categories', N'ProductCategory.CategoryPath', 30, CONVERT(bit, 1), CONVERT(bit, 1)),
    (N'WEB_B2C_PRODUCTS', N'MEDIA_URL', N'images', N'ProductMedia.Url', 40, CONVERT(bit, 1), CONVERT(bit, 1)),
    (N'WEB_B2C_PRODUCTS', N'B2C_PRICE_GROSS', N'price', N'ProductPrice.Gross', 50, CONVERT(bit, 1), CONVERT(bit, 1)),
    (N'WEB_B2C_PRODUCTS', N'MANUFACTURER', N'manufacturer', N'Product.Manufacturer', 60, CONVERT(bit, 1), CONVERT(bit, 1)),
    (N'WEB_B2C_PRODUCTS', N'KEY_CATEGORY_ATTRIBUTES', N'attributes', N'ProductAttribute.CategoryRequired', 70, CONVERT(bit, 1), CONVERT(bit, 1))
  ) AS source (ProfileCode, ColumnCode, OutputColumnName, CanonicalFieldCode, SortOrder, IsRequired, IsActive)
  INNER JOIN out.ExportProfile profile ON profile.ProfileCode = source.ProfileCode
) AS source
ON target.ExportProfileId = source.ExportProfileId AND target.ColumnCode = source.ColumnCode
WHEN MATCHED AND (target.OutputColumnName <> source.OutputColumnName OR target.CanonicalFieldCode <> source.CanonicalFieldCode OR target.SortOrder <> source.SortOrder OR target.IsRequired <> source.IsRequired OR target.IsActive <> source.IsActive) THEN
  UPDATE SET OutputColumnName = source.OutputColumnName, CanonicalFieldCode = source.CanonicalFieldCode, SortOrder = source.SortOrder, IsRequired = source.IsRequired, IsActive = source.IsActive
WHEN NOT MATCHED BY TARGET THEN
  INSERT (ExportProfileId, ColumnCode, OutputColumnName, CanonicalFieldCode, SortOrder, IsRequired, IsActive)
  VALUES (source.ExportProfileId, source.ColumnCode, source.OutputColumnName, source.CanonicalFieldCode, source.SortOrder, source.IsRequired, source.IsActive);

MERGE val.ValidationProfile AS target
USING (
  SELECT N'ERP_L1' AS ProfileCode, N'ERP L1 — obvezna polja' AS Name, ExportProfileId, CONVERT(bit, 1) AS IsActive FROM out.ExportProfile WHERE ProfileCode = N'ERP_L1'
  UNION ALL
  SELECT N'WEB_B2C' AS ProfileCode, N'Splet B2C — obvezna polja' AS Name, ExportProfileId, CONVERT(bit, 1) AS IsActive FROM out.ExportProfile WHERE ProfileCode = N'WEB_B2C_PRODUCTS'
) AS source
ON target.ProfileCode = source.ProfileCode
WHEN MATCHED AND (target.Name <> source.Name OR target.ExportProfileId <> source.ExportProfileId OR target.IsActive <> source.IsActive) THEN
  UPDATE SET Name = source.Name, ExportProfileId = source.ExportProfileId, IsActive = source.IsActive
WHEN NOT MATCHED BY TARGET THEN
  INSERT (ProfileCode, Name, ExportProfileId, IsActive) VALUES (source.ProfileCode, source.Name, source.ExportProfileId, source.IsActive);

EXEC(N'
CREATE OR ALTER PROCEDURE val.SyncFieldRequirementsFromExportProfiles
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  BEGIN TRY
    BEGIN TRANSACTION;

    UPDATE requirement
    SET FieldCode = exportColumn.CanonicalFieldCode,
        IsRequired = exportColumn.IsRequired,
        IsActive = exportColumn.IsActive
    FROM val.FieldRequirement requirement
    INNER JOIN val.ValidationProfile validationProfile ON validationProfile.ValidationProfileId = requirement.ValidationProfileId
    INNER JOIN out.ExportColumn exportColumn ON exportColumn.ExportColumnId = requirement.SourceExportColumnId
    WHERE validationProfile.ExportProfileId = exportColumn.ExportProfileId;

    INSERT val.FieldRequirement (ValidationProfileId, SourceExportColumnId, FieldCode, IsRequired, IsActive)
    SELECT validationProfile.ValidationProfileId,
           exportColumn.ExportColumnId,
           exportColumn.CanonicalFieldCode,
           exportColumn.IsRequired,
           exportColumn.IsActive
    FROM val.ValidationProfile validationProfile
    INNER JOIN out.ExportColumn exportColumn ON exportColumn.ExportProfileId = validationProfile.ExportProfileId
    WHERE NOT EXISTS
    (
      SELECT 1
      FROM val.FieldRequirement requirement
      WHERE requirement.ValidationProfileId = validationProfile.ValidationProfileId
        AND requirement.SourceExportColumnId = exportColumn.ExportColumnId
    );

    UPDATE requirement
    SET IsActive = 0
    FROM val.FieldRequirement requirement
    INNER JOIN val.ValidationProfile validationProfile ON validationProfile.ValidationProfileId = requirement.ValidationProfileId
    WHERE NOT EXISTS
    (
      SELECT 1
      FROM out.ExportColumn exportColumn
      WHERE exportColumn.ExportColumnId = requirement.SourceExportColumnId
        AND exportColumn.ExportProfileId = validationProfile.ExportProfileId
    );

    COMMIT TRANSACTION;
  END TRY
  BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

    DECLARE @ErrorMessage nvarchar(4000) = ERROR_MESSAGE();
    DECLARE @ErrorDetail nvarchar(2000) = CONCAT(N''Procedure=val.SyncFieldRequirementsFromExportProfiles; ErrorNumber='', ERROR_NUMBER());
    EXEC ops.LogError
      @Layer = N''val'',
      @Severity = N''Error'',
      @ErrorCode = N''SYNC_FIELD_REQUIREMENTS_FAILED'',
      @Message = @ErrorMessage,
      @Detail = @ErrorDetail;
    THROW;
  END CATCH;
END;
');

EXEC val.SyncFieldRequirementsFromExportProfiles;
