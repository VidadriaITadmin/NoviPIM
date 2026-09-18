/*
  Validation runs once per organization across every active product and required
  field. The original PK/unique indexes optimize identity writes but not the
  active issue lookups used by val.RunValidation, which caused F3/F5's 120s
  command timeouts with the local 6k-product organization.
*/
IF NOT EXISTS
(
  SELECT 1 FROM sys.indexes
  WHERE object_id = OBJECT_ID(N'canon.Product')
    AND name = N'IX_CanonProduct_Organization_Active'
)
  CREATE INDEX IX_CanonProduct_Organization_Active
    ON canon.Product(OrganizationId, IsActive, ProductId)
    INCLUDE(ValidationStatus);

IF NOT EXISTS
(
  SELECT 1 FROM sys.indexes
  WHERE object_id = OBJECT_ID(N'val.ProductIssue')
    AND name = N'IX_ProductIssue_Active_ProductRequirement'
)
  CREATE INDEX IX_ProductIssue_Active_ProductRequirement
    ON val.ProductIssue(ProductId, FieldRequirementId)
    WHERE IsActive = 1;

IF NOT EXISTS
(
  SELECT 1 FROM sys.indexes
  WHERE object_id = OBJECT_ID(N'val.FieldRequirement')
    AND name = N'IX_FieldRequirement_Active_Profile'
)
  CREATE INDEX IX_FieldRequirement_Active_Profile
    ON val.FieldRequirement(ValidationProfileId, FieldRequirementId, FieldCode)
    WHERE IsActive = 1 AND IsRequired = 1;
