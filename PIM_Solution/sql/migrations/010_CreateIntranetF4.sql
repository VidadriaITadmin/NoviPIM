SET XACT_ABORT ON;

IF SCHEMA_ID(N'intranet') IS NULL EXEC(N'CREATE SCHEMA intranet');

IF OBJECT_ID(N'sec.LocalUser', N'U') IS NULL
BEGIN
  CREATE TABLE sec.LocalUser
  (
    LocalUserId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_LocalUser PRIMARY KEY,
    UserName nvarchar(100) NOT NULL,
    DisplayName nvarchar(200) NOT NULL,
    PasswordHash nvarchar(500) NOT NULL,
    IsEnabled bit NOT NULL CONSTRAINT DF_LocalUser_IsEnabled DEFAULT (1),
    CreatedUtc datetime2(3) NOT NULL CONSTRAINT DF_LocalUser_CreatedUtc DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_LocalUser_UserName UNIQUE (UserName)
  );
END;

IF OBJECT_ID(N'sec.Role', N'U') IS NULL
BEGIN
  CREATE TABLE sec.Role
  (
    RoleId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_SecRole PRIMARY KEY,
    RoleCode nvarchar(100) NOT NULL,
    Name nvarchar(200) NOT NULL,
    CONSTRAINT UQ_SecRole_RoleCode UNIQUE (RoleCode)
  );
END;

IF OBJECT_ID(N'sec.LocalUserRole', N'U') IS NULL
BEGIN
  CREATE TABLE sec.LocalUserRole
  (
    LocalUserId int NOT NULL,
    RoleId int NOT NULL,
    CONSTRAINT PK_LocalUserRole PRIMARY KEY (LocalUserId, RoleId),
    CONSTRAINT FK_LocalUserRole_User FOREIGN KEY (LocalUserId) REFERENCES sec.LocalUser (LocalUserId),
    CONSTRAINT FK_LocalUserRole_Role FOREIGN KEY (RoleId) REFERENCES sec.Role (RoleId)
  );
END;

IF OBJECT_ID(N'sec.NavigationGroup', N'U') IS NULL
BEGIN
  CREATE TABLE sec.NavigationGroup
  (
    NavigationGroupId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_NavigationGroup PRIMARY KEY,
    GroupCode nvarchar(100) NOT NULL,
    Name nvarchar(200) NOT NULL,
    SortOrder int NOT NULL,
    IsActive bit NOT NULL CONSTRAINT DF_NavigationGroup_IsActive DEFAULT (1),
    CONSTRAINT UQ_NavigationGroup_GroupCode UNIQUE (GroupCode)
  );
END;

IF OBJECT_ID(N'sec.NavigationItem', N'U') IS NULL
BEGIN
  CREATE TABLE sec.NavigationItem
  (
    NavigationItemId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_NavigationItem PRIMARY KEY,
    NavigationGroupId int NOT NULL,
    ItemCode nvarchar(100) NOT NULL,
    Name nvarchar(200) NOT NULL,
    Route nvarchar(300) NOT NULL,
    SortOrder int NOT NULL,
    IsActive bit NOT NULL CONSTRAINT DF_NavigationItem_IsActive DEFAULT (1),
    CONSTRAINT UQ_NavigationItem_ItemCode UNIQUE (ItemCode),
    CONSTRAINT FK_NavigationItem_Group FOREIGN KEY (NavigationGroupId) REFERENCES sec.NavigationGroup (NavigationGroupId)
  );
END;

IF OBJECT_ID(N'sec.NavigationItemRole', N'U') IS NULL
BEGIN
  CREATE TABLE sec.NavigationItemRole
  (
    NavigationItemId int NOT NULL,
    RoleId int NOT NULL,
    CONSTRAINT PK_NavigationItemRole PRIMARY KEY (NavigationItemId, RoleId),
    CONSTRAINT FK_NavigationItemRole_Item FOREIGN KEY (NavigationItemId) REFERENCES sec.NavigationItem (NavigationItemId),
    CONSTRAINT FK_NavigationItemRole_Role FOREIGN KEY (RoleId) REFERENCES sec.Role (RoleId)
  );
END;

MERGE sec.Role AS target
USING (VALUES (N'ADMIN', N'Skrbnik'), (N'CATALOG_EDITOR', N'Urednik kataloga'), (N'VIEWER', N'Pregledovalec')) AS source (RoleCode, Name)
ON target.RoleCode = source.RoleCode
WHEN MATCHED AND target.Name <> source.Name THEN UPDATE SET Name = source.Name
WHEN NOT MATCHED THEN INSERT (RoleCode, Name) VALUES (source.RoleCode, source.Name);

MERGE sec.NavigationGroup AS target
USING (VALUES (N'KATALOG', N'Katalog', 10), (N'NADZOR', N'Nadzor', 20)) AS source (GroupCode, Name, SortOrder)
ON target.GroupCode = source.GroupCode
WHEN MATCHED AND (target.Name <> source.Name OR target.SortOrder <> source.SortOrder) THEN UPDATE SET Name = source.Name, SortOrder = source.SortOrder
WHEN NOT MATCHED THEN INSERT (GroupCode, Name, SortOrder) VALUES (source.GroupCode, source.Name, source.SortOrder);

MERGE sec.NavigationItem AS target
USING
(
  SELECT navigationGroup.NavigationGroupId, source.ItemCode, source.Name, source.Route, source.SortOrder
  FROM (VALUES
    (N'NADZOR', N'DASHBOARD', N'Nadzorna plošča', N'/nadzorna-plosca', 10),
    (N'KATALOG', N'PRODUCTS', N'Izdelki', N'/izdelki', 10),
    (N'NADZOR', N'ISSUES', N'Napake validacije', N'/napake-validacije', 20),
    (N'NADZOR', N'QUARANTINE', N'Karantena', N'/karantena', 30),
    (N'NADZOR', N'RUNS', N'Teki obdelave', N'/teki-obdelave', 40)
  ) AS source (GroupCode, ItemCode, Name, Route, SortOrder)
  INNER JOIN sec.NavigationGroup navigationGroup ON navigationGroup.GroupCode = source.GroupCode
) AS source
ON target.ItemCode = source.ItemCode
WHEN MATCHED AND (target.Name <> source.Name OR target.Route <> source.Route OR target.SortOrder <> source.SortOrder) THEN
  UPDATE SET NavigationGroupId = source.NavigationGroupId, Name = source.Name, Route = source.Route, SortOrder = source.SortOrder
WHEN NOT MATCHED THEN INSERT (NavigationGroupId, ItemCode, Name, Route, SortOrder) VALUES (source.NavigationGroupId, source.ItemCode, source.Name, source.Route, source.SortOrder);

MERGE sec.NavigationItemRole AS target
USING (SELECT navigationItem.NavigationItemId, roleValue.RoleId FROM sec.NavigationItem navigationItem CROSS JOIN sec.Role roleValue) AS source
ON target.NavigationItemId = source.NavigationItemId AND target.RoleId = source.RoleId
WHEN NOT MATCHED THEN INSERT (NavigationItemId, RoleId) VALUES (source.NavigationItemId, source.RoleId);

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetDashboard @OrganizationId int
AS
BEGIN
  SET NOCOUNT ON;
  SELECT
    (SELECT COUNT(*) FROM canon.Product WHERE OrganizationId = @OrganizationId) AS CanonProductCount,
    (SELECT COUNT(*) FROM pim.Product WHERE OrganizationId = @OrganizationId) AS PimProductCount,
    (SELECT COUNT(*) FROM val.ProductValidationState stateValue INNER JOIN val.ValidationProfile profileValue ON profileValue.ValidationProfileId = stateValue.ValidationProfileId INNER JOIN canon.Product productValue ON productValue.ProductId = stateValue.ProductId WHERE productValue.OrganizationId = @OrganizationId AND profileValue.ProfileCode = N''ERP_L1'' AND stateValue.Status = N''VALID'') AS ErpValidCount,
    (SELECT COUNT(*) FROM val.ProductValidationState stateValue INNER JOIN val.ValidationProfile profileValue ON profileValue.ValidationProfileId = stateValue.ValidationProfileId INNER JOIN canon.Product productValue ON productValue.ProductId = stateValue.ProductId WHERE productValue.OrganizationId = @OrganizationId AND profileValue.ProfileCode = N''WEB_B2C'' AND stateValue.Status = N''INVALID'') AS WebInvalidCount,
    (SELECT COUNT(*) FROM raw.Inbox WHERE OrganizationId = @OrganizationId AND Status = N''Quarantined'') AS QuarantineCount;
END;

');

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetProducts @OrganizationId int, @Skip int = 0, @Take int = 50
AS
BEGIN
  SET NOCOUNT ON;
  SELECT productValue.ProductId, productValue.ItemID, productValue.EAN, productValue.ValidationStatus, productValue.Completeness
  FROM canon.Product productValue WHERE productValue.OrganizationId = @OrganizationId
  ORDER BY productValue.ItemID OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY;
END;

');

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetProductDetail @OrganizationId int, @ProductId bigint
AS
BEGIN
  SET NOCOUNT ON;
  SELECT productValue.ProductId, productValue.ItemID, productValue.EAN, productValue.ValidationStatus, productValue.Completeness,
         profileValue.ProfileCode, stateValue.Status AS ProfileStatus, stateValue.Completeness AS ProfileCompleteness
  FROM canon.Product productValue
  LEFT JOIN val.ProductValidationState stateValue ON stateValue.ProductId = productValue.ProductId
  LEFT JOIN val.ValidationProfile profileValue ON profileValue.ValidationProfileId = stateValue.ValidationProfileId
  WHERE productValue.OrganizationId = @OrganizationId AND productValue.ProductId = @ProductId;
END;

');

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetValidationIssues @OrganizationId int
AS
BEGIN
  SET NOCOUNT ON;
  SELECT issueValue.ProductIssueId, productValue.ProductId, productValue.ItemID, profileValue.ProfileCode, issueValue.IssueCode, issueValue.Message, issueValue.LastDetectedUtc
  FROM val.ProductIssue issueValue INNER JOIN canon.Product productValue ON productValue.ProductId = issueValue.ProductId INNER JOIN val.ValidationProfile profileValue ON profileValue.ValidationProfileId = issueValue.ValidationProfileId
  WHERE productValue.OrganizationId = @OrganizationId AND issueValue.IsActive = 1 ORDER BY issueValue.LastDetectedUtc DESC;
END;

');

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetRawQuarantine @OrganizationId int
AS
BEGIN
  SET NOCOUNT ON;
  SELECT InboxId, RunId, SourceCode, EntityType, PageNumber, FailureReason, ReceivedUtc
  FROM raw.Inbox WHERE OrganizationId = @OrganizationId AND Status = N''Quarantined'' ORDER BY ReceivedUtc DESC;
END;

');

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetPipelineRuns @OrganizationId int
AS
BEGIN
  SET NOCOUNT ON;
  SELECT TOP (100) RunId, Pipeline, SourceCode, Status, RowsRead, RowsSucceeded, RowsFailed, StartedUtc, EndedUtc
  FROM ops.PipelineRun WHERE OrganizationId = @OrganizationId ORDER BY StartedUtc DESC;
END;
');
