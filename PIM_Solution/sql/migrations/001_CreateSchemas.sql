SET XACT_ABORT ON;

IF OBJECT_ID(N'dbo.SchemaMigration', N'U') IS NULL
BEGIN
  CREATE TABLE dbo.SchemaMigration
  (
    MigrationId nvarchar(255) NOT NULL,
    ScriptHash char(64) NOT NULL,
    AppliedUtc datetime2(3) NOT NULL CONSTRAINT DF_SchemaMigration_AppliedUtc DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_SchemaMigration PRIMARY KEY CLUSTERED (MigrationId)
  );
END;

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'raw') EXEC(N'CREATE SCHEMA raw');
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'map') EXEC(N'CREATE SCHEMA map');
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'canon') EXEC(N'CREATE SCHEMA canon');
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'val') EXEC(N'CREATE SCHEMA val');
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'pim') EXEC(N'CREATE SCHEMA pim');
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'out') EXEC(N'CREATE SCHEMA out');
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'ops') EXEC(N'CREATE SCHEMA ops');
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'sec') EXEC(N'CREATE SCHEMA sec');
