SET XACT_ABORT ON;

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetProducts
  @OrganizationId int,
  @Skip int = 0,
  @Take int = 50,
  @Search nvarchar(200) = NULL,
  @Status nvarchar(30) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SET @Skip = CASE WHEN @Skip < 0 THEN 0 ELSE @Skip END;
  SET @Take = CASE WHEN @Take < 1 THEN 50 WHEN @Take > 200 THEN 200 ELSE @Take END;
  SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'''');
  SET @Status = NULLIF(LTRIM(RTRIM(@Status)), N'''');

  SELECT productValue.ProductId AS ProductId, productValue.ItemID AS ItemId,
         productValue.EAN AS Ean, productValue.ValidationStatus AS Status,
         productValue.Completeness AS Completeness
  FROM canon.Product productValue
  WHERE productValue.OrganizationId = @OrganizationId
    AND (@Status IS NULL OR productValue.ValidationStatus = @Status)
    AND (@Search IS NULL OR productValue.ItemID LIKE N''%'' + @Search + N''%'' OR productValue.EAN LIKE N''%'' + @Search + N''%'')
  ORDER BY productValue.ItemID, productValue.ProductId
  OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY;

  SELECT COUNT_BIG(*) AS TotalCount
  FROM canon.Product productValue
  WHERE productValue.OrganizationId = @OrganizationId
    AND (@Status IS NULL OR productValue.ValidationStatus = @Status)
    AND (@Search IS NULL OR productValue.ItemID LIKE N''%'' + @Search + N''%'' OR productValue.EAN LIKE N''%'' + @Search + N''%'');
END;');

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
END;');

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetValidationIssues @OrganizationId int
AS
BEGIN
  SET NOCOUNT ON;
  SELECT issueValue.ProductIssueId AS ProductIssueId, productValue.ProductId AS ProductId,
         productValue.ItemID AS ItemId, profileValue.ProfileCode AS ProfileCode,
         issueValue.IssueCode AS IssueCode, issueValue.Message AS Message,
         issueValue.LastDetectedUtc AS LastDetectedUtc
  FROM val.ProductIssue issueValue
  INNER JOIN canon.Product productValue ON productValue.ProductId = issueValue.ProductId
  INNER JOIN val.ValidationProfile profileValue ON profileValue.ValidationProfileId = issueValue.ValidationProfileId
  WHERE productValue.OrganizationId = @OrganizationId AND issueValue.IsActive = 1
  ORDER BY issueValue.LastDetectedUtc DESC;

  SELECT profileValue.ProfileCode AS ProfileCode, COUNT_BIG(*) AS ProductCount,
         SUM(CASE WHEN stateValue.Status = N''VALID'' THEN CONVERT(bigint, 1) ELSE CONVERT(bigint, 0) END) AS ValidCount,
         SUM(CASE WHEN stateValue.Status = N''INVALID'' THEN CONVERT(bigint, 1) ELSE CONVERT(bigint, 0) END) AS InvalidCount,
         AVG(CONVERT(decimal(9,2), stateValue.Completeness)) AS AverageCompleteness
  FROM val.ProductValidationState stateValue
  INNER JOIN val.ValidationProfile profileValue ON profileValue.ValidationProfileId = stateValue.ValidationProfileId
  INNER JOIN canon.Product productValue ON productValue.ProductId = stateValue.ProductId
  WHERE productValue.OrganizationId = @OrganizationId
  GROUP BY profileValue.ProfileCode ORDER BY profileValue.ProfileCode;

  SELECT TOP (10) issueValue.IssueCode AS IssueCode, issueValue.Message AS Message, COUNT_BIG(*) AS OccurrenceCount
  FROM val.ProductIssue issueValue
  INNER JOIN canon.Product productValue ON productValue.ProductId = issueValue.ProductId
  WHERE productValue.OrganizationId = @OrganizationId AND issueValue.IsActive = 1
  GROUP BY issueValue.IssueCode, issueValue.Message
  ORDER BY COUNT_BIG(*) DESC, issueValue.IssueCode;
END;');

