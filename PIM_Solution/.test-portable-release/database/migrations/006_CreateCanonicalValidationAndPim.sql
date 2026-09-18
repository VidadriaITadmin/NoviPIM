SET XACT_ABORT ON;

IF OBJECT_ID(N'canon.Product', N'U') IS NULL
BEGIN
  CREATE TABLE canon.Product
  (
    ProductId bigint IDENTITY(1,1) NOT NULL,
    OrganizationId int NOT NULL,
    ItemID nvarchar(100) NOT NULL,
    EAN nvarchar(100) NULL,
    IsActive bit NOT NULL CONSTRAINT DF_CanonProduct_IsActive DEFAULT (1),
    WebPublish bit NOT NULL CONSTRAINT DF_CanonProduct_WebPublish DEFAULT (0),
    UoM nvarchar(50) NULL,
    ItemGroup nvarchar(100) NULL,
    Department nvarchar(100) NULL,
    Manufacturer nvarchar(200) NULL,
    Supplier nvarchar(200) NULL,
    DiscountGroup nvarchar(100) NULL,
    AccountingGroup nvarchar(100) NULL,
    BusinessHash char(64) NULL,
    ValidationStatus nvarchar(30) NOT NULL CONSTRAINT DF_CanonProduct_ValidationStatus DEFAULT (N'PENDING'),
    Completeness decimal(5,2) NOT NULL CONSTRAINT DF_CanonProduct_Completeness DEFAULT (0),
    LastValidatedUtc datetime2(3) NULL,
    CONSTRAINT PK_CanonProduct PRIMARY KEY CLUSTERED (ProductId),
    CONSTRAINT UQ_CanonProduct_OrganizationItem UNIQUE (OrganizationId, ItemID),
    CONSTRAINT CK_CanonProduct_ValidationStatus CHECK (ValidationStatus IN (N'PENDING', N'VALID', N'INVALID')),
    CONSTRAINT CK_CanonProduct_Completeness CHECK (Completeness >= 0 AND Completeness <= 100),
    CONSTRAINT FK_CanonProduct_Organization FOREIGN KEY (OrganizationId) REFERENCES dbo.OrganizationConfig (OrganizationId)
  );
END;

IF OBJECT_ID(N'canon.ProductText', N'U') IS NULL
BEGIN
  CREATE TABLE canon.ProductText
  (
    ProductTextId bigint IDENTITY(1,1) NOT NULL,
    ProductId bigint NOT NULL,
    Lang nvarchar(20) NOT NULL,
    TextType nvarchar(50) NOT NULL,
    Value nvarchar(max) NOT NULL,
    CONSTRAINT PK_CanonProductText PRIMARY KEY CLUSTERED (ProductTextId),
    CONSTRAINT UQ_CanonProductText_ProductLangType UNIQUE (ProductId, Lang, TextType),
    CONSTRAINT CK_CanonProductText_Type CHECK (TextType IN (N'TITLE_ERP', N'WEB_TITLE', N'DESCRIPTION')),
    CONSTRAINT FK_CanonProductText_Product FOREIGN KEY (ProductId) REFERENCES canon.Product (ProductId)
  );
END;

IF OBJECT_ID(N'canon.ProductAttribute', N'U') IS NULL
BEGIN
  CREATE TABLE canon.ProductAttribute
  (
    ProductAttributeId bigint IDENTITY(1,1) NOT NULL,
    ProductId bigint NOT NULL,
    AttributeCode nvarchar(200) NOT NULL,
    Value nvarchar(max) NOT NULL,
    CONSTRAINT PK_CanonProductAttribute PRIMARY KEY CLUSTERED (ProductAttributeId),
    CONSTRAINT UQ_CanonProductAttribute_ProductCode UNIQUE (ProductId, AttributeCode),
    CONSTRAINT FK_CanonProductAttribute_Product FOREIGN KEY (ProductId) REFERENCES canon.Product (ProductId)
  );
END;

IF OBJECT_ID(N'canon.ProductCategory', N'U') IS NULL
BEGIN
  CREATE TABLE canon.ProductCategory
  (
    ProductCategoryId bigint IDENTITY(1,1) NOT NULL,
    ProductId bigint NOT NULL,
    WebSite nvarchar(100) NOT NULL,
    CategoryPath nvarchar(1000) NOT NULL,
    CONSTRAINT PK_CanonProductCategory PRIMARY KEY CLUSTERED (ProductCategoryId),
    CONSTRAINT UQ_CanonProductCategory_ProductSitePath UNIQUE (ProductId, WebSite, CategoryPath),
    CONSTRAINT FK_CanonProductCategory_Product FOREIGN KEY (ProductId) REFERENCES canon.Product (ProductId)
  );
END;

IF OBJECT_ID(N'canon.ProductMedia', N'U') IS NULL
BEGIN
  CREATE TABLE canon.ProductMedia
  (
    ProductMediaId bigint IDENTITY(1,1) NOT NULL,
    ProductId bigint NOT NULL,
    Url nvarchar(2000) NOT NULL,
    Role nvarchar(100) NOT NULL,
    SortOrder int NOT NULL,
    CONSTRAINT PK_CanonProductMedia PRIMARY KEY CLUSTERED (ProductMediaId),
    CONSTRAINT UQ_CanonProductMedia_ProductRoleSort UNIQUE (ProductId, Role, SortOrder),
    CONSTRAINT CK_CanonProductMedia_SortOrder CHECK (SortOrder > 0),
    CONSTRAINT FK_CanonProductMedia_Product FOREIGN KEY (ProductId) REFERENCES canon.Product (ProductId)
  );
END;

IF OBJECT_ID(N'canon.ProductPrice', N'U') IS NULL
BEGIN
  CREATE TABLE canon.ProductPrice
  (
    ProductPriceId bigint IDENTITY(1,1) NOT NULL,
    ProductId bigint NOT NULL,
    PriceList nvarchar(100) NOT NULL,
    Net decimal(19,4) NOT NULL,
    VatRate decimal(5,2) NOT NULL,
    ValidFrom datetime2(3) NOT NULL,
    IsActive bit NOT NULL CONSTRAINT DF_CanonProductPrice_IsActive DEFAULT (1),
    CONSTRAINT PK_CanonProductPrice PRIMARY KEY CLUSTERED (ProductPriceId),
    CONSTRAINT UQ_CanonProductPrice_ProductListFrom UNIQUE (ProductId, PriceList, ValidFrom),
    CONSTRAINT CK_CanonProductPrice_Net CHECK (Net >= 0),
    CONSTRAINT CK_CanonProductPrice_VatRate CHECK (VatRate >= 0 AND VatRate <= 100),
    CONSTRAINT FK_CanonProductPrice_Product FOREIGN KEY (ProductId) REFERENCES canon.Product (ProductId)
  );
END;

IF OBJECT_ID(N'canon.ProductCommercial', N'U') IS NULL
BEGIN
  CREATE TABLE canon.ProductCommercial
  (
    ProductCommercialId bigint IDENTITY(1,1) NOT NULL,
    ProductId bigint NOT NULL,
    NetWeight decimal(19,4) NULL,
    GrossWeight decimal(19,4) NULL,
    CustomsTariff nvarchar(100) NULL,
    CountryOfOrigin nvarchar(100) NULL,
    Pak1 decimal(19,4) NULL,
    Pak2 decimal(19,4) NULL,
    Dimensions nvarchar(200) NULL,
    CONSTRAINT PK_CanonProductCommercial PRIMARY KEY CLUSTERED (ProductCommercialId),
    CONSTRAINT UQ_CanonProductCommercial_Product UNIQUE (ProductId),
    CONSTRAINT FK_CanonProductCommercial_Product FOREIGN KEY (ProductId) REFERENCES canon.Product (ProductId)
  );
END;

IF OBJECT_ID(N'val.ProductValidationState', N'U') IS NULL
BEGIN
  CREATE TABLE val.ProductValidationState
  (
    ProductValidationStateId bigint IDENTITY(1,1) NOT NULL,
    ProductId bigint NOT NULL,
    ValidationProfileId int NOT NULL,
    Status nvarchar(30) NOT NULL,
    Completeness decimal(5,2) NOT NULL,
    ValidatedUtc datetime2(3) NOT NULL,
    CONSTRAINT PK_ProductValidationState PRIMARY KEY CLUSTERED (ProductValidationStateId),
    CONSTRAINT UQ_ProductValidationState_ProductProfile UNIQUE (ProductId, ValidationProfileId),
    CONSTRAINT CK_ProductValidationState_Status CHECK (Status IN (N'VALID', N'INVALID')),
    CONSTRAINT CK_ProductValidationState_Completeness CHECK (Completeness >= 0 AND Completeness <= 100),
    CONSTRAINT FK_ProductValidationState_Product FOREIGN KEY (ProductId) REFERENCES canon.Product (ProductId),
    CONSTRAINT FK_ProductValidationState_Profile FOREIGN KEY (ValidationProfileId) REFERENCES val.ValidationProfile (ValidationProfileId)
  );
END;

IF OBJECT_ID(N'val.ProductIssue', N'U') IS NULL
BEGIN
  CREATE TABLE val.ProductIssue
  (
    ProductIssueId bigint IDENTITY(1,1) NOT NULL,
    ProductId bigint NOT NULL,
    ValidationProfileId int NOT NULL,
    FieldRequirementId int NOT NULL,
    IssueCode nvarchar(100) NOT NULL,
    Message nvarchar(1000) NOT NULL,
    IsActive bit NOT NULL CONSTRAINT DF_ProductIssue_IsActive DEFAULT (1),
    FirstDetectedUtc datetime2(3) NOT NULL CONSTRAINT DF_ProductIssue_FirstDetectedUtc DEFAULT SYSUTCDATETIME(),
    LastDetectedUtc datetime2(3) NOT NULL CONSTRAINT DF_ProductIssue_LastDetectedUtc DEFAULT SYSUTCDATETIME(),
    ResolvedUtc datetime2(3) NULL,
    CONSTRAINT PK_ProductIssue PRIMARY KEY CLUSTERED (ProductIssueId),
    CONSTRAINT UQ_ProductIssue_ProductRequirement UNIQUE (ProductId, FieldRequirementId),
    CONSTRAINT FK_ProductIssue_Product FOREIGN KEY (ProductId) REFERENCES canon.Product (ProductId),
    CONSTRAINT FK_ProductIssue_Profile FOREIGN KEY (ValidationProfileId) REFERENCES val.ValidationProfile (ValidationProfileId),
    CONSTRAINT FK_ProductIssue_Requirement FOREIGN KEY (FieldRequirementId) REFERENCES val.FieldRequirement (FieldRequirementId)
  );
END;

IF OBJECT_ID(N'pim.Product', N'U') IS NULL
BEGIN
  CREATE TABLE pim.Product
  (
    PimProductId bigint IDENTITY(1,1) NOT NULL,
    OrganizationId int NOT NULL,
    ItemID nvarchar(100) NOT NULL,
    EAN nvarchar(100) NULL,
    Name nvarchar(500) NULL,
    Manufacturer nvarchar(200) NULL,
    PromotedUtc datetime2(3) NOT NULL CONSTRAINT DF_PimProduct_PromotedUtc DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_PimProduct PRIMARY KEY CLUSTERED (PimProductId),
    CONSTRAINT UQ_PimProduct_OrganizationItem UNIQUE (OrganizationId, ItemID),
    CONSTRAINT FK_PimProduct_Organization FOREIGN KEY (OrganizationId) REFERENCES dbo.OrganizationConfig (OrganizationId)
  );
END;

IF OBJECT_ID(N'pim.ProductText', N'U') IS NULL
BEGIN
  CREATE TABLE pim.ProductText (PimProductTextId bigint IDENTITY(1,1) NOT NULL, PimProductId bigint NOT NULL, Lang nvarchar(20) NOT NULL, TextType nvarchar(50) NOT NULL, Value nvarchar(max) NOT NULL, CONSTRAINT PK_PimProductText PRIMARY KEY (PimProductTextId), CONSTRAINT UQ_PimProductText UNIQUE (PimProductId, Lang, TextType), CONSTRAINT FK_PimProductText_Product FOREIGN KEY (PimProductId) REFERENCES pim.Product (PimProductId));
END;
IF OBJECT_ID(N'pim.ProductAttribute', N'U') IS NULL
BEGIN
  CREATE TABLE pim.ProductAttribute (PimProductAttributeId bigint IDENTITY(1,1) NOT NULL, PimProductId bigint NOT NULL, AttributeCode nvarchar(200) NOT NULL, Value nvarchar(max) NOT NULL, CONSTRAINT PK_PimProductAttribute PRIMARY KEY (PimProductAttributeId), CONSTRAINT UQ_PimProductAttribute UNIQUE (PimProductId, AttributeCode), CONSTRAINT FK_PimProductAttribute_Product FOREIGN KEY (PimProductId) REFERENCES pim.Product (PimProductId));
END;
IF OBJECT_ID(N'pim.ProductCategory', N'U') IS NULL
BEGIN
  CREATE TABLE pim.ProductCategory (PimProductCategoryId bigint IDENTITY(1,1) NOT NULL, PimProductId bigint NOT NULL, WebSite nvarchar(100) NOT NULL, CategoryPath nvarchar(1000) NOT NULL, CONSTRAINT PK_PimProductCategory PRIMARY KEY (PimProductCategoryId), CONSTRAINT UQ_PimProductCategory UNIQUE (PimProductId, WebSite, CategoryPath), CONSTRAINT FK_PimProductCategory_Product FOREIGN KEY (PimProductId) REFERENCES pim.Product (PimProductId));
END;
IF OBJECT_ID(N'pim.ProductMedia', N'U') IS NULL
BEGIN
  CREATE TABLE pim.ProductMedia (PimProductMediaId bigint IDENTITY(1,1) NOT NULL, PimProductId bigint NOT NULL, Url nvarchar(2000) NOT NULL, Role nvarchar(100) NOT NULL, SortOrder int NOT NULL, CONSTRAINT PK_PimProductMedia PRIMARY KEY (PimProductMediaId), CONSTRAINT UQ_PimProductMedia UNIQUE (PimProductId, Role, SortOrder), CONSTRAINT FK_PimProductMedia_Product FOREIGN KEY (PimProductId) REFERENCES pim.Product (PimProductId));
END;
IF OBJECT_ID(N'pim.ProductPrice', N'U') IS NULL
BEGIN
  CREATE TABLE pim.ProductPrice (PimProductPriceId bigint IDENTITY(1,1) NOT NULL, PimProductId bigint NOT NULL, PriceList nvarchar(100) NOT NULL, Net decimal(19,4) NOT NULL, VatRate decimal(5,2) NOT NULL, ValidFrom datetime2(3) NOT NULL, IsActive bit NOT NULL, CONSTRAINT PK_PimProductPrice PRIMARY KEY (PimProductPriceId), CONSTRAINT UQ_PimProductPrice UNIQUE (PimProductId, PriceList, ValidFrom), CONSTRAINT FK_PimProductPrice_Product FOREIGN KEY (PimProductId) REFERENCES pim.Product (PimProductId));
END;
IF OBJECT_ID(N'pim.ProductCommercial', N'U') IS NULL
BEGIN
  CREATE TABLE pim.ProductCommercial (PimProductCommercialId bigint IDENTITY(1,1) NOT NULL, PimProductId bigint NOT NULL, NetWeight decimal(19,4) NULL, GrossWeight decimal(19,4) NULL, CustomsTariff nvarchar(100) NULL, CountryOfOrigin nvarchar(100) NULL, Pak1 decimal(19,4) NULL, Pak2 decimal(19,4) NULL, Dimensions nvarchar(200) NULL, CONSTRAINT PK_PimProductCommercial PRIMARY KEY (PimProductCommercialId), CONSTRAINT UQ_PimProductCommercial UNIQUE (PimProductId), CONSTRAINT FK_PimProductCommercial_Product FOREIGN KEY (PimProductId) REFERENCES pim.Product (PimProductId));
END;

EXEC(N'
CREATE OR ALTER VIEW canon.FieldValue
AS
SELECT ProductId, N''Product.ItemID'' AS FieldCode, NULLIF(ItemID, N'''') AS Value FROM canon.Product
UNION ALL SELECT ProductId, N''Product.EAN'', NULLIF(EAN, N'''') FROM canon.Product
UNION ALL SELECT ProductId, N''Product.UoM'', NULLIF(UoM, N'''') FROM canon.Product
UNION ALL SELECT ProductId, N''Product.Supplier'', NULLIF(Supplier, N'''') FROM canon.Product
UNION ALL SELECT ProductId, N''Product.Manufacturer'', NULLIF(Manufacturer, N'''') FROM canon.Product
UNION ALL SELECT ProductId, N''Product.AccountingGroup'', NULLIF(AccountingGroup, N'''') FROM canon.Product
UNION ALL SELECT ProductId, N''Product.DiscountGroup'', NULLIF(DiscountGroup, N'''') FROM canon.Product
UNION ALL SELECT textValue.ProductId, CONCAT(N''ProductText.'', textValue.TextType, N''.'', textValue.Lang), NULLIF(textValue.Value, N'''') FROM canon.ProductText textValue
UNION ALL SELECT attributeValue.ProductId, CONCAT(N''ProductAttribute.'', attributeValue.AttributeCode), NULLIF(attributeValue.Value, N'''') FROM canon.ProductAttribute attributeValue
UNION ALL SELECT ProductId, N''ProductCategory.CategoryPath'', NULLIF(CategoryPath, N'''') FROM canon.ProductCategory
UNION ALL SELECT ProductId, N''ProductMedia.Url'', NULLIF(Url, N'''') FROM canon.ProductMedia
UNION ALL SELECT ProductId, N''ProductPrice.VatRate'', CONVERT(nvarchar(50), VatRate) FROM canon.ProductPrice WHERE IsActive = 1
UNION ALL SELECT ProductId, N''ProductPrice.Gross'', CONVERT(nvarchar(50), Net * (1 + VatRate / 100)) FROM canon.ProductPrice WHERE IsActive = 1 AND Net * (1 + VatRate / 100) > 0;
');

EXEC(N'
CREATE OR ALTER PROCEDURE val.RunValidation
  @OrganizationId int = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  BEGIN TRY
    BEGIN TRANSACTION;
    ;WITH RequiredField AS
    (
      SELECT product.ProductId, profile.ValidationProfileId, requirement.FieldRequirementId, requirement.FieldCode
      FROM canon.Product product
      CROSS JOIN val.ValidationProfile profile
      INNER JOIN val.FieldRequirement requirement ON requirement.ValidationProfileId = profile.ValidationProfileId
      WHERE product.IsActive = 1 AND profile.IsActive = 1 AND requirement.IsActive = 1 AND requirement.IsRequired = 1
        AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
    ), MissingField AS
    (
      SELECT requiredField.*
      FROM RequiredField requiredField
      WHERE NOT EXISTS
      (
        SELECT 1 FROM canon.FieldValue fieldValue
        WHERE fieldValue.ProductId = requiredField.ProductId
          AND fieldValue.FieldCode = requiredField.FieldCode
          AND NULLIF(fieldValue.Value, N'''') IS NOT NULL
      )
    )
    MERGE val.ProductIssue AS target
    USING MissingField AS source
    ON target.ProductId = source.ProductId AND target.FieldRequirementId = source.FieldRequirementId
    WHEN MATCHED THEN UPDATE SET ValidationProfileId = source.ValidationProfileId, IssueCode = N''MISSING_REQUIRED_FIELD'', Message = CONCAT(N''Manjka obvezno polje: '', source.FieldCode), IsActive = 1, LastDetectedUtc = SYSUTCDATETIME(), ResolvedUtc = NULL
    WHEN NOT MATCHED THEN INSERT (ProductId, ValidationProfileId, FieldRequirementId, IssueCode, Message) VALUES (source.ProductId, source.ValidationProfileId, source.FieldRequirementId, N''MISSING_REQUIRED_FIELD'', CONCAT(N''Manjka obvezno polje: '', source.FieldCode));

    UPDATE issue SET IsActive = 0, ResolvedUtc = SYSUTCDATETIME()
    FROM val.ProductIssue issue
    INNER JOIN canon.Product product ON product.ProductId = issue.ProductId
    WHERE issue.IsActive = 1 AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
      AND NOT EXISTS
      (
        SELECT 1 FROM val.FieldRequirement requirement
        WHERE requirement.FieldRequirementId = issue.FieldRequirementId AND requirement.IsActive = 1 AND requirement.IsRequired = 1
          AND NOT EXISTS (SELECT 1 FROM canon.FieldValue fieldValue WHERE fieldValue.ProductId = product.ProductId AND fieldValue.FieldCode = requirement.FieldCode AND NULLIF(fieldValue.Value, N'''') IS NOT NULL)
      );

    ;WITH ProfileScore AS
    (
      SELECT product.ProductId, profile.ValidationProfileId,
        CAST(100.0 * (COUNT(requirement.FieldRequirementId) - SUM(CASE WHEN issue.ProductIssueId IS NULL THEN 0 ELSE 1 END)) / NULLIF(COUNT(requirement.FieldRequirementId), 0) AS decimal(5,2)) AS Completeness,
        CASE WHEN SUM(CASE WHEN issue.ProductIssueId IS NULL THEN 0 ELSE 1 END) = 0 THEN N''VALID'' ELSE N''INVALID'' END AS Status
      FROM canon.Product product
      CROSS JOIN val.ValidationProfile profile
      INNER JOIN val.FieldRequirement requirement ON requirement.ValidationProfileId = profile.ValidationProfileId AND requirement.IsActive = 1 AND requirement.IsRequired = 1
      LEFT JOIN val.ProductIssue issue ON issue.ProductId = product.ProductId AND issue.FieldRequirementId = requirement.FieldRequirementId AND issue.IsActive = 1
      WHERE product.IsActive = 1 AND profile.IsActive = 1 AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
      GROUP BY product.ProductId, profile.ValidationProfileId
    )
    MERGE val.ProductValidationState AS target
    USING ProfileScore AS source ON target.ProductId = source.ProductId AND target.ValidationProfileId = source.ValidationProfileId
    WHEN MATCHED THEN UPDATE SET Status = source.Status, Completeness = source.Completeness, ValidatedUtc = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT (ProductId, ValidationProfileId, Status, Completeness, ValidatedUtc) VALUES (source.ProductId, source.ValidationProfileId, source.Status, source.Completeness, SYSUTCDATETIME());

    UPDATE product
    SET ValidationStatus = CASE WHEN EXISTS (SELECT 1 FROM val.ProductIssue issue WHERE issue.ProductId = product.ProductId AND issue.IsActive = 1) THEN N''INVALID'' ELSE N''VALID'' END,
        Completeness = ISNULL((SELECT MIN(state.Completeness) FROM val.ProductValidationState state WHERE state.ProductId = product.ProductId), 0),
        LastValidatedUtc = SYSUTCDATETIME()
    FROM canon.Product product
    WHERE product.IsActive = 1 AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId);

    COMMIT TRANSACTION;
  END TRY
  BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    DECLARE @ErrorMessage nvarchar(4000) = ERROR_MESSAGE();
    EXEC ops.LogError @Layer = N''val'', @Severity = N''Error'', @ErrorCode = N''RUN_VALIDATION_FAILED'', @Message = @ErrorMessage;
    THROW;
  END CATCH;
END;
');

EXEC(N'
CREATE OR ALTER PROCEDURE val.Promote
  @OrganizationId int = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  BEGIN TRY
    BEGIN TRANSACTION;
    ;WITH Eligible AS
    (
      SELECT product.ProductId, product.OrganizationId, product.ItemID, product.EAN, product.Manufacturer,
             (SELECT TOP (1) textValue.Value FROM canon.ProductText textValue WHERE textValue.ProductId = product.ProductId AND textValue.TextType = N''WEB_TITLE'' AND textValue.Lang = N''sl'') AS Name
      FROM canon.Product product
      WHERE product.ValidationStatus = N''VALID'' AND product.IsActive = 1 AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
    )
    MERGE pim.Product AS target
    USING Eligible AS source ON target.OrganizationId = source.OrganizationId AND target.ItemID = source.ItemID
    WHEN MATCHED THEN UPDATE SET EAN = source.EAN, Name = source.Name, Manufacturer = source.Manufacturer, PromotedUtc = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT (OrganizationId, ItemID, EAN, Name, Manufacturer) VALUES (source.OrganizationId, source.ItemID, source.EAN, source.Name, source.Manufacturer);
    COMMIT TRANSACTION;
  END TRY
  BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    DECLARE @ErrorMessage nvarchar(4000) = ERROR_MESSAGE();
    EXEC ops.LogError @Layer = N''val'', @Severity = N''Error'', @ErrorCode = N''PROMOTE_FAILED'', @Message = @ErrorMessage;
    THROW;
  END CATCH;
END;
');
