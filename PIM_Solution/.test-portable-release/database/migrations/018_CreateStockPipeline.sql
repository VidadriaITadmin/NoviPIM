SET XACT_ABORT ON;

IF SCHEMA_ID(N'stock') IS NULL EXEC(N'CREATE SCHEMA stock');

IF OBJECT_ID(N'stock.SaopProviderProfile', N'U') IS NULL
CREATE TABLE stock.SaopProviderProfile
(
  SaopProviderProfileId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_SaopProviderProfile PRIMARY KEY,
  OrganizationId int NOT NULL,
  ProfileCode nvarchar(100) NOT NULL,
  ProviderKind nvarchar(40) NOT NULL,
  Priority int NOT NULL,
  Enabled bit NOT NULL,
  RegisteredViewId nvarchar(200) NULL,
  WarehouseSelectionMode nvarchar(40) NULL,
  WarehouseIdsJson nvarchar(max) NULL,
  LastSuccessUtc datetime2(3) NULL,
  CONSTRAINT UQ_SaopProviderProfile UNIQUE (OrganizationId, ProfileCode),
  CONSTRAINT CK_SaopProviderProfile_Kind CHECK (ProviderKind IN (N'RegisteredViewData',N'StockAdvance',N'GetStocks')),
  CONSTRAINT FK_SaopProviderProfile_Organization FOREIGN KEY (OrganizationId) REFERENCES dbo.OrganizationConfig(OrganizationId)
);

IF OBJECT_ID(N'map.StockIdentityRule', N'U') IS NULL
CREATE TABLE map.StockIdentityRule
(
  StockIdentityRuleId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_StockIdentityRule PRIMARY KEY,
  SourceConnectorId int NOT NULL,
  SourceKeyField nvarchar(100) NOT NULL,
  Prefix nvarchar(100) NOT NULL CONSTRAINT DF_StockIdentityRule_Prefix DEFAULT N'',
  ReplaceOld nvarchar(20) NULL,
  ReplaceNew nvarchar(20) NULL,
  MatchPriority nvarchar(20) NOT NULL,
  IsActive bit NOT NULL CONSTRAINT DF_StockIdentityRule_IsActive DEFAULT 1,
  CONSTRAINT UQ_StockIdentityRule UNIQUE (SourceConnectorId, SourceKeyField),
  CONSTRAINT CK_StockIdentityRule_Match CHECK (MatchPriority IN (N'ItemID',N'EAN')),
  CONSTRAINT FK_StockIdentityRule_Connector FOREIGN KEY (SourceConnectorId) REFERENCES map.SourceConnector(SourceConnectorId)
);

IF OBJECT_ID(N'stock.SyncRun', N'U') IS NULL
CREATE TABLE stock.SyncRun
(
  SyncRunId uniqueidentifier NOT NULL CONSTRAINT PK_StockSyncRun PRIMARY KEY,
  OrganizationId int NOT NULL,
  SourceConnectorId int NOT NULL,
  SaopProviderProfileId int NULL,
  Status nvarchar(30) NOT NULL,
  Endpoint nvarchar(1000) NOT NULL,
  QueryParametersHash char(64) NULL,
  HttpStatus int NULL,
  StartedUtc datetime2(3) NOT NULL,
  FetchedUtc datetime2(3) NULL,
  CompletedUtc datetime2(3) NULL,
  RecordsRead int NOT NULL CONSTRAINT DF_StockSyncRun_Read DEFAULT 0,
  RecordsApplied int NOT NULL CONSTRAINT DF_StockSyncRun_Applied DEFAULT 0,
  RecordsQuarantined int NOT NULL CONSTRAINT DF_StockSyncRun_Quarantine DEFAULT 0,
  CONSTRAINT FK_StockSyncRun_Organization FOREIGN KEY (OrganizationId) REFERENCES dbo.OrganizationConfig(OrganizationId),
  CONSTRAINT FK_StockSyncRun_Connector FOREIGN KEY (SourceConnectorId) REFERENCES map.SourceConnector(SourceConnectorId),
  CONSTRAINT FK_StockSyncRun_Profile FOREIGN KEY (SaopProviderProfileId) REFERENCES stock.SaopProviderProfile(SaopProviderProfileId)
);

IF OBJECT_ID(N'stock.LandingRecord', N'U') IS NULL
CREATE TABLE stock.LandingRecord
(
  LandingRecordId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_StockLandingRecord PRIMARY KEY,
  SyncRunId uniqueidentifier NOT NULL,
  OrganizationId int NOT NULL,
  SourceConnectorId int NOT NULL,
  SourceRecordKey nvarchar(450) NOT NULL,
  SnapshotUtc datetime2(3) NOT NULL,
  SourceTimestampUtc datetime2(3) NULL,
  Endpoint nvarchar(1000) NOT NULL,
  RawPayload nvarchar(max) NOT NULL,
  PayloadHash char(64) NOT NULL,
  Ean nvarchar(100) NULL,
  SourceItemId nvarchar(450) NULL,
  NormalizedItemId nvarchar(450) NULL,
  QuantityText nvarchar(100) NULL,
  AvailabilityDateText nvarchar(100) NULL,
  IncomingQuantityText nvarchar(100) NULL,
  Status nvarchar(30) NOT NULL CONSTRAINT DF_StockLandingRecord_Status DEFAULT N'Pending',
  FailureReason nvarchar(2000) NULL,
  CONSTRAINT UQ_StockLandingRecord_Immutable UNIQUE (OrganizationId, SourceConnectorId, SourceRecordKey, SnapshotUtc),
  CONSTRAINT FK_StockLandingRecord_Run FOREIGN KEY (SyncRunId) REFERENCES stock.SyncRun(SyncRunId)
);
-- Immutable identity: OrganizationId, SourceConnectorId, SourceRecordKey, SnapshotUtc.

IF OBJECT_ID(N'stock.Snapshot', N'U') IS NULL
CREATE TABLE stock.Snapshot
(
  SnapshotId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_StockSnapshot PRIMARY KEY,
  SyncRunId uniqueidentifier NOT NULL,
  OrganizationId int NOT NULL,
  SourceConnectorId int NOT NULL,
  ProviderKind nvarchar(40) NULL,
  Endpoint nvarchar(1000) NOT NULL,
  SnapshotUtc datetime2(3) NOT NULL,
  IsActive bit NOT NULL CONSTRAINT DF_StockSnapshot_Active DEFAULT 0,
  CONSTRAINT UQ_StockSnapshot UNIQUE (OrganizationId, SourceConnectorId, SnapshotUtc),
  CONSTRAINT FK_StockSnapshot_Run FOREIGN KEY (SyncRunId) REFERENCES stock.SyncRun(SyncRunId)
);

IF OBJECT_ID(N'stock.Position', N'U') IS NULL
CREATE TABLE stock.Position
(
  PositionId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_StockPosition PRIMARY KEY,
  SnapshotId bigint NOT NULL,
  LandingRecordId bigint NOT NULL,
  NormalizedItemId nvarchar(450) NULL,
  Ean nvarchar(100) NULL,
  Quantity decimal(19,4) NOT NULL,
  AvailabilityDate date NULL,
  IncomingQuantity decimal(19,4) NULL,
  MatchKey nvarchar(20) NOT NULL,
  MatchedProductId bigint NULL,
  CONSTRAINT UQ_StockPosition_Landing UNIQUE (LandingRecordId),
  CONSTRAINT FK_StockPosition_Snapshot FOREIGN KEY (SnapshotId) REFERENCES stock.Snapshot(SnapshotId),
  CONSTRAINT FK_StockPosition_Landing FOREIGN KEY (LandingRecordId) REFERENCES stock.LandingRecord(LandingRecordId),
  CONSTRAINT FK_StockPosition_Product FOREIGN KEY (MatchedProductId) REFERENCES canon.Product(ProductId)
);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID(N'stock.Position') AND name=N'IX_stock_Position_Identity')
  CREATE INDEX IX_stock_Position_Identity ON stock.Position(NormalizedItemId,Ean) INCLUDE(Quantity,SnapshotId);

IF OBJECT_ID(N'stock.UnmatchedPosition', N'U') IS NULL
CREATE TABLE stock.UnmatchedPosition
(
  UnmatchedPositionId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_StockUnmatchedPosition PRIMARY KEY,
  LandingRecordId bigint NOT NULL CONSTRAINT UQ_StockUnmatchedPosition UNIQUE,
  ReasonCode nvarchar(50) NOT NULL,
  Detail nvarchar(2000) NOT NULL,
  CreatedUtc datetime2(3) NOT NULL CONSTRAINT DF_StockUnmatchedPosition_Created DEFAULT SYSUTCDATETIME(),
  CONSTRAINT FK_StockUnmatchedPosition_Landing FOREIGN KEY (LandingRecordId) REFERENCES stock.LandingRecord(LandingRecordId)
);

EXEC(N'
CREATE OR ALTER PROCEDURE stock.ApplyLandingRecord @LandingRecordId bigint, @DateFormat nvarchar(30)=N''yyyy-MM-dd''
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  DECLARE @Quantity decimal(19,4), @Incoming decimal(19,4), @Date date, @Identity nvarchar(450), @Ean nvarchar(100), @Reason nvarchar(50);
  SELECT @Quantity=TRY_CONVERT(decimal(19,4),NULLIF(REPLACE(QuantityText,NCHAR(0),N''''),N'''')),
    @Incoming=TRY_CONVERT(decimal(19,4),NULLIF(REPLACE(IncomingQuantityText,NCHAR(0),N''''),N'''')),
    @Date=CASE WHEN NULLIF(REPLACE(AvailabilityDateText,NCHAR(0),N''''),N'''') IS NULL THEN NULL
      WHEN @DateFormat=N''yyyy-MM-dd'' THEN TRY_CONVERT(date,REPLACE(AvailabilityDateText,NCHAR(0),N''''),23)
      WHEN @DateFormat=N''dd.MM.yyyy'' THEN TRY_CONVERT(date,REPLACE(AvailabilityDateText,NCHAR(0),N''''),104) END,
    @Identity=NULLIF(LTRIM(RTRIM(NormalizedItemId)),N''''), @Ean=NULLIF(LTRIM(RTRIM(Ean)),N'''')
  FROM stock.LandingRecord WHERE LandingRecordId=@LandingRecordId AND Status=N''Pending'';
  IF @@ROWCOUNT=0 RETURN;
  SET @Reason=CASE WHEN @Identity IS NULL AND @Ean IS NULL THEN N''MissingIdentity''
    WHEN @Quantity IS NULL THEN N''InvalidQuantity'' WHEN @Quantity<0 THEN N''NegativeQuantity''
    WHEN NULLIF(REPLACE((SELECT AvailabilityDateText FROM stock.LandingRecord WHERE LandingRecordId=@LandingRecordId),NCHAR(0),N''''),N'''') IS NOT NULL AND @Date IS NULL THEN N''InvalidDate'' END;
  IF @Reason IS NOT NULL
  BEGIN
    INSERT stock.UnmatchedPosition(LandingRecordId,ReasonCode,Detail) VALUES(@LandingRecordId,@Reason,N''Zapis ni prestal generične normalizacije.'');
    UPDATE stock.LandingRecord SET Status=N''Quarantined'',FailureReason=@Reason WHERE LandingRecordId=@LandingRecordId; RETURN;
  END;
  DECLARE @SnapshotId bigint=(SELECT SnapshotId FROM stock.Snapshot s JOIN stock.LandingRecord l ON l.SyncRunId=s.SyncRunId AND l.OrganizationId=s.OrganizationId AND l.SourceConnectorId=s.SourceConnectorId AND l.SnapshotUtc=s.SnapshotUtc WHERE l.LandingRecordId=@LandingRecordId);
  DECLARE @ProductId bigint=(SELECT TOP(1) ProductId FROM canon.Product WHERE ItemID=@Identity OR (@Identity IS NULL AND EAN=@Ean) ORDER BY CASE WHEN ItemID=@Identity THEN 0 ELSE 1 END);
  INSERT stock.Position(SnapshotId,LandingRecordId,NormalizedItemId,Ean,Quantity,AvailabilityDate,IncomingQuantity,MatchKey,MatchedProductId)
  VALUES(@SnapshotId,@LandingRecordId,@Identity,@Ean,@Quantity,@Date,@Incoming,CASE WHEN @ProductId IS NULL THEN N''Unmatched'' WHEN EXISTS(SELECT 1 FROM canon.Product WHERE ProductId=@ProductId AND ItemID=@Identity) THEN N''ItemID'' ELSE N''EAN'' END,@ProductId);
  UPDATE stock.LandingRecord SET Status=N''Applied'' WHERE LandingRecordId=@LandingRecordId;
END');

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetStocks @OrganizationId int
AS
BEGIN
  SET NOCOUNT ON;
  SELECT p.PositionId,p.NormalizedItemId,p.Ean,p.Quantity,p.AvailabilityDate,p.IncomingQuantity,c.SourceCode,s.SnapshotUtc,
    p.MatchKey,s.ProviderKind,s.Endpoint,DATEDIFF(minute,s.SnapshotUtc,SYSUTCDATETIME()) FreshnessMinutes,p.MatchedProductId
  FROM stock.Position p JOIN stock.Snapshot s ON s.SnapshotId=p.SnapshotId
  JOIN map.SourceConnector c ON c.SourceConnectorId=s.SourceConnectorId
  WHERE s.OrganizationId=@OrganizationId AND s.IsActive=1 ORDER BY c.SourceCode,p.NormalizedItemId,p.Ean;
END');

EXEC(N'
CREATE OR ALTER PROCEDURE out.ExportStockCsv @OrganizationId int
AS
BEGIN
  SET NOCOUNT ON;
  SELECT COALESCE(p.NormalizedItemId,N'''' ) ProductKey,p.Ean,p.Quantity,p.AvailabilityDate,p.IncomingQuantity,c.SourceCode,s.ProviderKind,s.SnapshotUtc
  FROM stock.Position p JOIN stock.Snapshot s ON s.SnapshotId=p.SnapshotId JOIN map.SourceConnector c ON c.SourceConnectorId=s.SourceConnectorId
  WHERE s.OrganizationId=@OrganizationId AND s.IsActive=1 ORDER BY c.SourceCode,ProductKey;
END');

MERGE sec.NavigationItem AS target
USING (SELECT g.NavigationGroupId,N'STOCKS' ItemCode,N'Zaloge' Name,N'/zaloge' Route,60 SortOrder FROM sec.NavigationGroup g WHERE g.GroupCode=N'PIM') source
ON target.ItemCode=source.ItemCode
WHEN MATCHED THEN UPDATE SET Name=source.Name,Route=source.Route,SortOrder=source.SortOrder,IsActive=1
WHEN NOT MATCHED THEN INSERT(NavigationGroupId,ItemCode,Name,Route,SortOrder) VALUES(source.NavigationGroupId,source.ItemCode,source.Name,source.Route,source.SortOrder);
MERGE sec.NavigationItemRole target
USING (SELECT i.NavigationItemId,r.RoleId FROM sec.NavigationItem i CROSS JOIN sec.Role r WHERE i.ItemCode=N'STOCKS') source
ON target.NavigationItemId=source.NavigationItemId AND target.RoleId=source.RoleId
WHEN NOT MATCHED THEN INSERT(NavigationItemId,RoleId) VALUES(source.NavigationItemId,source.RoleId);
