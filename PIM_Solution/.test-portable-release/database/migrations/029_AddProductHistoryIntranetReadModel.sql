SET XACT_ABORT ON;

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetProductDetail @OrganizationId int, @ProductId bigint
AS
BEGIN
  SET NOCOUNT ON;
  SELECT productValue.ProductId AS ProductId, productValue.ItemID AS ItemId, productValue.EAN AS Ean,
         productValue.ValidationStatus AS Status, productValue.Completeness AS Completeness,
         productValue.IsActive AS IsActive, productValue.WebPublish AS WebPublish,
         productValue.UoM AS Uom, productValue.ItemGroup AS ItemGroup,
         productValue.Department AS Department, productValue.Manufacturer AS Manufacturer,
         productValue.Supplier AS Supplier, productValue.LastValidatedUtc AS LastValidatedUtc
  FROM canon.Product productValue
  WHERE productValue.OrganizationId = @OrganizationId AND productValue.ProductId = @ProductId;

  SELECT profileValue.ProfileCode AS ProfileCode, stateValue.Status AS Status,
         stateValue.Completeness AS Completeness, stateValue.ValidatedUtc AS ValidatedUtc
  FROM val.ProductValidationState stateValue
  INNER JOIN val.ValidationProfile profileValue ON profileValue.ValidationProfileId = stateValue.ValidationProfileId
  INNER JOIN canon.Product productValue ON productValue.ProductId = stateValue.ProductId
  WHERE productValue.OrganizationId = @OrganizationId AND productValue.ProductId = @ProductId
  ORDER BY profileValue.ProfileCode;

  SELECT issueValue.ProductIssueId AS ProductIssueId, profileValue.ProfileCode AS ProfileCode,
         issueValue.IssueCode AS IssueCode, issueValue.Message AS Message,
         issueValue.FirstDetectedUtc AS FirstDetectedUtc, issueValue.LastDetectedUtc AS LastDetectedUtc
  FROM val.ProductIssue issueValue
  INNER JOIN val.ValidationProfile profileValue ON profileValue.ValidationProfileId = issueValue.ValidationProfileId
  INNER JOIN canon.Product productValue ON productValue.ProductId = issueValue.ProductId
  WHERE productValue.OrganizationId = @OrganizationId AND productValue.ProductId = @ProductId AND issueValue.IsActive = 1
  ORDER BY issueValue.LastDetectedUtc DESC;

  EXEC pim.GetProductHistory @OrganizationId=@OrganizationId, @ProductId=@ProductId;
END;');
