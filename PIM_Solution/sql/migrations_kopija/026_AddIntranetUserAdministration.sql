SET XACT_ABORT ON;

IF COL_LENGTH(N'sec.LocalUser', N'AuthSource') IS NULL
BEGIN
  ALTER TABLE sec.LocalUser ADD AuthSource nvarchar(20) NOT NULL CONSTRAINT DF_LocalUser_AuthSource DEFAULT (N'LOCAL');
END;

IF COL_LENGTH(N'sec.LocalUser', N'DomainIdentity') IS NULL
BEGIN
  ALTER TABLE sec.LocalUser ADD DomainIdentity nvarchar(256) NULL;
END;

IF EXISTS (
  SELECT 1 FROM sys.columns
  WHERE object_id = OBJECT_ID(N'sec.LocalUser') AND name = N'PasswordHash' AND is_nullable = 0
)
BEGIN
  ALTER TABLE sec.LocalUser ALTER COLUMN PasswordHash nvarchar(500) NULL;
END;

EXEC(N'UPDATE sec.LocalUser SET AuthSource = N''LOCAL'' WHERE AuthSource IS NULL OR AuthSource NOT IN (N''LOCAL'', N''DOMAIN'');');

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_LocalUser_AuthSource')
BEGIN
  EXEC(N'ALTER TABLE sec.LocalUser ADD CONSTRAINT CK_LocalUser_AuthSource CHECK (AuthSource IN (N''LOCAL'', N''DOMAIN''));');
END;

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'sec.LocalUser') AND name = N'UX_LocalUser_DomainIdentity')
BEGIN
  EXEC(N'CREATE UNIQUE INDEX UX_LocalUser_DomainIdentity ON sec.LocalUser(DomainIdentity) WHERE DomainIdentity IS NOT NULL;');
END;

EXEC(N'
CREATE OR ALTER PROCEDURE sec.CreateLocalUser
  @UserName nvarchar(100),
  @DisplayName nvarchar(200),
  @PasswordHash nvarchar(500),
  @RoleCode nvarchar(100) = N''ADMIN''
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  SET @UserName = LTRIM(RTRIM(@UserName));
  SET @DisplayName = LTRIM(RTRIM(@DisplayName));
  IF @UserName = N'''' OR @DisplayName = N'''' OR @PasswordHash IS NULL OR LEN(@PasswordHash) = 0
    THROW 51026, N''Uporabniško ime, prikazno ime in hash gesla so obvezni.'', 1;

  BEGIN TRANSACTION;
  BEGIN TRY
    IF EXISTS (SELECT 1 FROM sec.LocalUser WHERE UserName = @UserName)
      THROW 51026, N''Uporabnik s tem imenom že obstaja.'', 1;

    DECLARE @RoleId int = (SELECT RoleId FROM sec.Role WHERE RoleCode = @RoleCode);
    IF @RoleId IS NULL THROW 51026, N''Zahtevana vloga ne obstaja.'', 1;

    INSERT sec.LocalUser(UserName, DisplayName, PasswordHash, AuthSource, DomainIdentity)
    VALUES(@UserName, @DisplayName, @PasswordHash, N''LOCAL'', NULL);
    DECLARE @LocalUserId int = SCOPE_IDENTITY();
    INSERT sec.LocalUserRole(LocalUserId, RoleId) VALUES(@LocalUserId, @RoleId);
    COMMIT;
    SELECT @LocalUserId AS LocalUserId;
  END TRY
  BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    THROW;
  END CATCH
END;
');

EXEC(N'
CREATE OR ALTER PROCEDURE sec.CreateDomainUser
  @DomainIdentity nvarchar(256),
  @DisplayName nvarchar(200),
  @RoleCode nvarchar(100) = N''VIEWER''
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  SET @DomainIdentity = LTRIM(RTRIM(@DomainIdentity));
  SET @DisplayName = LTRIM(RTRIM(@DisplayName));
  IF @DomainIdentity = N'''' OR @DisplayName = N''''
    THROW 51026, N''Domenska identiteta in prikazno ime sta obvezna.'', 1;

  BEGIN TRANSACTION;
  BEGIN TRY
    IF EXISTS (SELECT 1 FROM sec.LocalUser WHERE DomainIdentity = @DomainIdentity)
      THROW 51026, N''Domenski uporabnik že obstaja.'', 1;

    DECLARE @RoleId int = (SELECT RoleId FROM sec.Role WHERE RoleCode = @RoleCode);
    IF @RoleId IS NULL THROW 51026, N''Zahtevana vloga ne obstaja.'', 1;

    INSERT sec.LocalUser(UserName, DisplayName, PasswordHash, AuthSource, DomainIdentity)
    VALUES(@DomainIdentity, @DisplayName, NULL, N''DOMAIN'', @DomainIdentity);
    DECLARE @LocalUserId int = SCOPE_IDENTITY();
    INSERT sec.LocalUserRole(LocalUserId, RoleId) VALUES(@LocalUserId, @RoleId);
    COMMIT;
    SELECT @LocalUserId AS LocalUserId;
  END TRY
  BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    THROW;
  END CATCH
END;
');

DECLARE @NavigationGroupId int = (SELECT NavigationGroupId FROM sec.NavigationGroup WHERE GroupCode = N'NADZOR');
DECLARE @AdminRoleId int = (SELECT RoleId FROM sec.Role WHERE RoleCode = N'ADMIN');
IF @NavigationGroupId IS NULL OR @AdminRoleId IS NULL THROW 51026, N'Administratorska navigacija zahteva obstoječo skupino NADZOR in vlogo ADMIN.', 1;

MERGE sec.NavigationItem AS target
USING (SELECT @NavigationGroupId AS NavigationGroupId, N'USERS' AS ItemCode, N'Uporabniki' AS Name, N'/system/uporabniki' AS Route, 90 AS SortOrder) AS source
ON target.ItemCode = source.ItemCode
WHEN MATCHED THEN UPDATE SET NavigationGroupId = source.NavigationGroupId, Name = source.Name, Route = source.Route, SortOrder = source.SortOrder, IsActive = 1
WHEN NOT MATCHED THEN INSERT(NavigationGroupId, ItemCode, Name, Route, SortOrder) VALUES(source.NavigationGroupId, source.ItemCode, source.Name, source.Route, source.SortOrder);

MERGE sec.NavigationItemRole AS target
USING (SELECT NavigationItemId, @AdminRoleId AS RoleId FROM sec.NavigationItem WHERE ItemCode = N'USERS') AS source
ON target.NavigationItemId = source.NavigationItemId AND target.RoleId = source.RoleId
WHEN NOT MATCHED THEN INSERT(NavigationItemId, RoleId) VALUES(source.NavigationItemId, source.RoleId);
