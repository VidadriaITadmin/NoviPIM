SET XACT_ABORT ON;

-- F5: generični konfiguracijski model za kateri koli XML vir. Ne vsebuje NW-specifične kode.
IF COL_LENGTH(N'map.FieldMapping', N'SourceElement') < 2000
  ALTER TABLE map.FieldMapping ALTER COLUMN SourceElement nvarchar(2000) NOT NULL;

IF OBJECT_ID(N'map.EntityMapping', N'U') IS NULL
BEGIN
  CREATE TABLE map.EntityMapping
  (
    EntityMappingId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_EntityMapping PRIMARY KEY,
    SourceConnectorId int NOT NULL,
    EntityType nvarchar(100) NOT NULL,
    RecordXPath nvarchar(2000) NOT NULL,
    IsActive bit NOT NULL CONSTRAINT DF_EntityMapping_IsActive DEFAULT (1),
    CONSTRAINT UQ_EntityMapping UNIQUE (SourceConnectorId, EntityType),
    CONSTRAINT FK_EntityMapping_Connector FOREIGN KEY (SourceConnectorId) REFERENCES map.SourceConnector(SourceConnectorId)
  );
END;

MERGE map.SourceConnector AS target
USING (VALUES (N'NW_XML', 2, N'FILE_XML', CONVERT(bit, 1))) AS source (SourceCode, OrganizationId, ConnectorType, IsActive)
ON target.SourceCode = source.SourceCode AND target.OrganizationId = source.OrganizationId
WHEN MATCHED THEN UPDATE SET ConnectorType=source.ConnectorType, IsActive=source.IsActive
WHEN NOT MATCHED THEN INSERT (SourceCode, OrganizationId, ConnectorType, IsActive) VALUES(source.SourceCode,source.OrganizationId,source.ConnectorType,source.IsActive);

MERGE map.EntityMapping AS target
USING
(
  SELECT connector.SourceConnectorId, value.EntityType, value.RecordXPath, CONVERT(bit, 1) IsActive
  FROM map.SourceConnector connector
  CROSS APPLY (VALUES
    (N'Attribute',N'/channel/products/product'),
    (N'Classification',N'/channel/products/product'),
    (N'Media',N'/channel/products/product')
  ) value(EntityType,RecordXPath)
  WHERE connector.SourceCode=N'NW_XML' AND connector.OrganizationId=2
) source
ON target.SourceConnectorId=source.SourceConnectorId AND target.EntityType=source.EntityType
WHEN MATCHED THEN UPDATE SET RecordXPath=source.RecordXPath, IsActive=source.IsActive
WHEN NOT MATCHED THEN INSERT(SourceConnectorId,EntityType,RecordXPath,IsActive) VALUES(source.SourceConnectorId,source.EntityType,source.RecordXPath,source.IsActive);

MERGE map.FieldMapping AS target
USING
(
  SELECT connector.SourceConnectorId, value.EntityType, value.SourceElement, value.TargetFieldCode, CONVERT(bit, 1) IsRequired, CONVERT(bit, 1) IsActive
  FROM map.SourceConnector connector
  CROSS APPLY (VALUES
    (N'Attribute',N'ean/text()',N'Product.EAN'),
    (N'Attribute',N'attributes/attribute_symbol/text()',N'ProductAttribute.CategoryRequired'),
    (N'Classification',N'ean/text()',N'Product.EAN'),
    (N'Classification',N'product_classification/product_classification_i/i/text()',N'ProductCategory.CategoryPath'),
    (N'Media',N'ean/text()',N'Product.EAN'),
    (N'Media',N'media/image_i/image_i_path/text()',N'ProductMedia.Url')
  ) value(EntityType,SourceElement,TargetFieldCode)
  WHERE connector.SourceCode=N'NW_XML' AND connector.OrganizationId=2
) source
ON target.SourceConnectorId=source.SourceConnectorId AND target.EntityType=source.EntityType AND target.SourceElement=source.SourceElement AND target.TargetFieldCode=source.TargetFieldCode
WHEN MATCHED THEN UPDATE SET IsRequired=source.IsRequired, IsActive=source.IsActive
WHEN NOT MATCHED THEN INSERT(SourceConnectorId,EntityType,SourceElement,TargetFieldCode,IsRequired,IsActive) VALUES(source.SourceConnectorId,source.EntityType,source.SourceElement,source.TargetFieldCode,source.IsRequired,source.IsActive);
