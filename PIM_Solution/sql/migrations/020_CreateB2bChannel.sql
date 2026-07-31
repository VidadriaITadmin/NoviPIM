SET XACT_ABORT ON;

IF SCHEMA_ID(N'b2b') IS NULL EXEC(N'CREATE SCHEMA b2b');

IF OBJECT_ID(N'b2b.Customer', N'U') IS NULL
BEGIN
  CREATE TABLE b2b.Customer
  (
    CustomerId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_b2b_Customer PRIMARY KEY,
    OrganizationId int NOT NULL,
    CustomerKey nvarchar(100) NOT NULL,
    Name nvarchar(300) NOT NULL,
    PayerCode nvarchar(100) NULL,
    PayerName nvarchar(300) NULL,
    PriceListCode nvarchar(100) NULL,
    DiscountPriceListCode nvarchar(100) NULL,
    SourceInboxId bigint NULL,
    SourceRecordOrdinal int NULL,
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_b2b_Customer_UpdatedUtc DEFAULT SYSUTCDATETIME(),
    CONSTRAINT FK_b2b_Customer_Organization FOREIGN KEY (OrganizationId) REFERENCES dbo.OrganizationConfig (OrganizationId),
    CONSTRAINT FK_b2b_Customer_Inbox FOREIGN KEY (SourceInboxId) REFERENCES raw.Inbox (InboxId)
  );
  CREATE UNIQUE INDEX IX_b2b_Customer_OrganizationCustomer ON b2b.Customer(OrganizationId, CustomerKey);
END;

IF OBJECT_ID(N'pim.CustomerTypeCatalog', N'U') IS NULL
BEGIN
  CREATE TABLE pim.CustomerTypeCatalog
  (
    CustomerTypeCode nvarchar(60) NOT NULL CONSTRAINT PK_CustomerTypeCatalog PRIMARY KEY,
    Name nvarchar(200) NOT NULL,
    SortOrder int NOT NULL CONSTRAINT UQ_CustomerTypeCatalog_Sort UNIQUE,
    IsActive bit NOT NULL CONSTRAINT DF_CustomerTypeCatalog_Active DEFAULT (1),
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_CustomerTypeCatalog_Updated DEFAULT SYSUTCDATETIME()
  );
END;

MERGE pim.CustomerTypeCatalog AS target
USING (VALUES
  (N'INSTALLER',N'INŠTALATER',1),(N'MAX_INSTALLER',N'MAX INŠTALATER',2),(N'CARPENTER',N'MIZAR',3),
  (N'RESELLER_TRANSIT',N'TRGOVEC – TRANZIT',4),(N'END_B2B',N'KONČNI KUPEC – B2B',5),(N'RESELLER',N'TRGOVEC',6),
  (N'INSTALLER_MAX',N'INŠTALATER MAX',7),(N'RESELLER_BRANCH',N'TRGOVEC – PE',8),(N'RESALE',N'NADALJNJA PRODAJA',9),
  (N'RESELLER_BRANCH_INACTIVE',N'TRGOVEC – PE – NEAKTIVEN',10),(N'END_B2B_BRANCH',N'KONČNI KUPEC – B2B – PE',11),
  (N'INSTALLER_BRANCH',N'INŠTALATER – PE',12),(N'INSTALLER_TRANSIT',N'INŠTALATER – TRANZIT',13),
  (N'RESELLER_TRANSIT_INACTIVE',N'TRGOVEC – TRANZIT – NEAKTIVEN',14),(N'RESELLER_INACTIVE',N'TRGOVEC – neaktiven',15),
  (N'DESIGNER',N'PROJEKTANT',16),(N'INACTIVE',N'NEAKTIVEN',17),(N'PUBLIC_SECTOR',N'JAVNI SEKTOR',18)
) source(CustomerTypeCode,Name,SortOrder)
ON target.CustomerTypeCode=source.CustomerTypeCode
WHEN MATCHED THEN UPDATE SET Name=source.Name,SortOrder=source.SortOrder
WHEN NOT MATCHED THEN INSERT(CustomerTypeCode,Name,SortOrder) VALUES(source.CustomerTypeCode,source.Name,source.SortOrder);

IF OBJECT_ID(N'pim.CustomerTypeMagentoGroup', N'U') IS NULL
BEGIN
  CREATE TABLE pim.CustomerTypeMagentoGroup
  (
    CustomerTypeCode nvarchar(60) NOT NULL CONSTRAINT PK_CustomerTypeMagentoGroup PRIMARY KEY,
    MagentoGroupKey nvarchar(100) NULL,
    IsActive bit NOT NULL CONSTRAINT DF_CustomerTypeMagentoGroup_Active DEFAULT (1),
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_CustomerTypeMagentoGroup_Updated DEFAULT SYSUTCDATETIME(),
    CONSTRAINT FK_CustomerTypeMagentoGroup_Type FOREIGN KEY(CustomerTypeCode) REFERENCES pim.CustomerTypeCatalog(CustomerTypeCode)
  );
END;
MERGE pim.CustomerTypeMagentoGroup target USING (SELECT CustomerTypeCode FROM pim.CustomerTypeCatalog) source
ON target.CustomerTypeCode=source.CustomerTypeCode
WHEN NOT MATCHED THEN INSERT(CustomerTypeCode,MagentoGroupKey) VALUES(source.CustomerTypeCode,NULL);

IF OBJECT_ID(N'pim.CustomerWebProfile', N'U') IS NULL
BEGIN
  CREATE TABLE pim.CustomerWebProfile
  (
    CustomerId bigint NOT NULL CONSTRAINT PK_CustomerWebProfile PRIMARY KEY,
    CustomerTypeCode nvarchar(60) NULL,
    CustomerKind nvarchar(20) NULL,
    PackagingDiscountEnabled bit NOT NULL CONSTRAINT DF_CustomerWebProfile_Pack DEFAULT(0),
    ValueDiscountEnabled bit NOT NULL CONSTRAINT DF_CustomerWebProfile_Value DEFAULT(0),
    B2bPlusEnabled bit NOT NULL CONSTRAINT DF_CustomerWebProfile_Plus DEFAULT(0),
    B2bPlusValidFrom date NULL,
    B2bPlusValidTo date NULL,
    WebEnabled bit NOT NULL CONSTRAINT DF_CustomerWebProfile_Web DEFAULT(0),
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_CustomerWebProfile_Updated DEFAULT SYSUTCDATETIME(),
    CONSTRAINT FK_CustomerWebProfile_Customer FOREIGN KEY(CustomerId) REFERENCES b2b.Customer(CustomerId),
    CONSTRAINT FK_CustomerWebProfile_Type FOREIGN KEY(CustomerTypeCode) REFERENCES pim.CustomerTypeCatalog(CustomerTypeCode),
    CONSTRAINT CK_CustomerWebProfile_Kind CHECK(CustomerKind IS NULL OR CustomerKind IN(N'CUSTOMER',N'SUPPLIER',N'BOTH')),
    CONSTRAINT CK_CustomerWebProfile_PlusDates CHECK(B2bPlusValidTo IS NULL OR B2bPlusValidFrom IS NULL OR B2bPlusValidTo>=B2bPlusValidFrom)
  );
END;

IF OBJECT_ID(N'pim.PackagingDiscountCatalog', N'U') IS NULL
BEGIN
  CREATE TABLE pim.PackagingDiscountCatalog(DiscountCode nvarchar(10) NOT NULL CONSTRAINT PK_PackagingDiscountCatalog PRIMARY KEY, PercentValue decimal(9,4) NOT NULL, IsActive bit NOT NULL CONSTRAINT DF_PackagingDiscountCatalog_Active DEFAULT(1), UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_PackagingDiscountCatalog_Updated DEFAULT SYSUTCDATETIME(), CONSTRAINT CK_PackagingDiscountCatalog_Percent CHECK(PercentValue>0 AND PercentValue<=100));
END;
MERGE pim.PackagingDiscountCatalog target USING(VALUES(N'S1', 3),(N'S2', 5),(N'S3', 10),(N'S4', 15)) source(DiscountCode,PercentValue)
ON target.DiscountCode=source.DiscountCode WHEN MATCHED THEN UPDATE SET PercentValue=source.PercentValue WHEN NOT MATCHED THEN INSERT(DiscountCode,PercentValue) VALUES(source.DiscountCode,source.PercentValue);

IF OBJECT_ID(N'pim.ProductPackagingDiscount', N'U') IS NULL
BEGIN
  CREATE TABLE pim.ProductPackagingDiscount(PimProductId bigint NOT NULL CONSTRAINT PK_ProductPackagingDiscount PRIMARY KEY,DiscountCode nvarchar(10) NOT NULL,PromotionGateState nvarchar(20) NOT NULL CONSTRAINT DF_ProductPackagingDiscount_Gate DEFAULT(N'Unknown'),UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_ProductPackagingDiscount_Updated DEFAULT SYSUTCDATETIME(),CONSTRAINT FK_ProductPackagingDiscount_Product FOREIGN KEY(PimProductId) REFERENCES pim.Product(PimProductId),CONSTRAINT FK_ProductPackagingDiscount_Catalog FOREIGN KEY(DiscountCode) REFERENCES pim.PackagingDiscountCatalog(DiscountCode),CONSTRAINT CK_ProductPackagingDiscount_Gate CHECK(PromotionGateState IN(N'Unknown',N'Regular',N'Promotional')));
END;

IF OBJECT_ID(N'pim.ValueDiscountTier', N'U') IS NULL
BEGIN
  CREATE TABLE pim.ValueDiscountTier(TierNumber tinyint NOT NULL CONSTRAINT PK_ValueDiscountTier PRIMARY KEY,ThresholdGrossExVat decimal(19,4) NOT NULL,PercentValue decimal(9,4) NOT NULL,IsActive bit NOT NULL CONSTRAINT DF_ValueDiscountTier_Active DEFAULT(1),UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_ValueDiscountTier_Updated DEFAULT SYSUTCDATETIME(),CONSTRAINT CK_ValueDiscountTier_Number CHECK(TierNumber BETWEEN 1 AND 3),CONSTRAINT CK_ValueDiscountTier_Values CHECK(ThresholdGrossExVat>=0 AND PercentValue>0 AND PercentValue<=100));
END;
MERGE pim.ValueDiscountTier target USING(VALUES(1,800, 1),(2,1500, 2),(3,3000, 3)) source(TierNumber,ThresholdGrossExVat,PercentValue)
ON target.TierNumber=source.TierNumber WHEN MATCHED THEN UPDATE SET ThresholdGrossExVat=source.ThresholdGrossExVat,PercentValue=source.PercentValue WHEN NOT MATCHED THEN INSERT(TierNumber,ThresholdGrossExVat,PercentValue) VALUES(source.TierNumber,source.ThresholdGrossExVat,source.PercentValue);

IF OBJECT_ID(N'pim.CustomerValueDiscountTier', N'U') IS NULL
BEGIN
  CREATE TABLE pim.CustomerValueDiscountTier(CustomerId bigint NOT NULL,TierNumber tinyint NOT NULL,ThresholdGrossExVat decimal(19,4) NOT NULL,PercentValue decimal(9,4) NOT NULL,IsActive bit NOT NULL CONSTRAINT DF_CustomerValueDiscountTier_Active DEFAULT(1),CONSTRAINT PK_CustomerValueDiscountTier PRIMARY KEY(CustomerId,TierNumber),CONSTRAINT FK_CustomerValueDiscountTier_Customer FOREIGN KEY(CustomerId) REFERENCES b2b.Customer(CustomerId),CONSTRAINT CK_CustomerValueDiscountTier_Values CHECK(TierNumber BETWEEN 1 AND 3 AND ThresholdGrossExVat>=0 AND PercentValue>0 AND PercentValue<=100));
END;

IF OBJECT_ID(N'pim.ShippingRuleCatalog', N'U') IS NULL
BEGIN
  CREATE TABLE pim.ShippingRuleCatalog(RuleCode nvarchar(40) NOT NULL CONSTRAINT PK_ShippingRuleCatalog PRIMARY KEY,OrderThreshold decimal(19,4) NULL,PackageLengthMeters decimal(9,3) NULL,ShippingNet decimal(19,4) NOT NULL,IsFree bit NOT NULL,Priority int NOT NULL,IsActive bit NOT NULL CONSTRAINT DF_ShippingRuleCatalog_Active DEFAULT(1),UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_ShippingRuleCatalog_Updated DEFAULT SYSUTCDATETIME());
END;
MERGE pim.ShippingRuleCatalog target USING(VALUES(N'STANDARD_PAID',150,NULL,4.10,0,10),(N'STANDARD_FREE',150,NULL,0,1,20),(N'OVERSIZE',300,2.000,10.00,0,30),(N'B2B_PLUS',NULL,NULL,0,1,100)) source(RuleCode,OrderThreshold,PackageLengthMeters,ShippingNet,IsFree,Priority)
ON target.RuleCode=source.RuleCode WHEN MATCHED THEN UPDATE SET OrderThreshold=source.OrderThreshold,PackageLengthMeters=source.PackageLengthMeters,ShippingNet=source.ShippingNet,IsFree=source.IsFree,Priority=source.Priority WHEN NOT MATCHED THEN INSERT(RuleCode,OrderThreshold,PackageLengthMeters,ShippingNet,IsFree,Priority) VALUES(source.RuleCode,source.OrderThreshold,source.PackageLengthMeters,source.ShippingNet,source.IsFree,source.Priority);

IF OBJECT_ID(N'b2b.GroupDiscount', N'U') IS NULL
BEGIN
  CREATE TABLE b2b.GroupDiscount(GroupDiscountId bigint IDENTITY NOT NULL CONSTRAINT PK_b2b_GroupDiscount PRIMARY KEY,CustomerId bigint NOT NULL,ItemGroupCode nvarchar(100) NOT NULL,PercentValue decimal(9,4) NOT NULL,ValidFrom date NULL,ValidTo date NULL,SourceInboxId bigint NULL,CONSTRAINT FK_b2b_GroupDiscount_Customer FOREIGN KEY(CustomerId) REFERENCES b2b.Customer(CustomerId),CONSTRAINT CK_b2b_GroupDiscount_Value CHECK(PercentValue>=0 AND PercentValue<=100));
  CREATE INDEX IX_b2b_GroupDiscount_Lookup ON b2b.GroupDiscount(CustomerId,ItemGroupCode,ValidFrom,ValidTo);
END;
IF OBJECT_ID(N'b2b.GroupDiscountOverride', N'U') IS NULL
BEGIN
  CREATE TABLE b2b.GroupDiscountOverride(OverrideId bigint IDENTITY NOT NULL CONSTRAINT PK_b2b_GroupDiscountOverride PRIMARY KEY,OrganizationId int NOT NULL,TargetKind nvarchar(20) NOT NULL,CustomerId bigint NULL,CustomerTypeCode nvarchar(60) NULL,ItemGroupCode nvarchar(100) NOT NULL,PercentValue decimal(9,4) NOT NULL,ValidFrom date NULL,ValidTo date NULL,IsActive bit NOT NULL CONSTRAINT DF_GroupDiscountOverride_Active DEFAULT(1),CONSTRAINT CK_GroupDiscountOverride_Target CHECK((TargetKind=N'CUSTOMER' AND CustomerId IS NOT NULL AND CustomerTypeCode IS NULL) OR (TargetKind=N'TYPE' AND CustomerId IS NULL AND CustomerTypeCode IS NOT NULL)),CONSTRAINT FK_GroupDiscountOverride_Customer FOREIGN KEY(CustomerId) REFERENCES b2b.Customer(CustomerId),CONSTRAINT FK_GroupDiscountOverride_Type FOREIGN KEY(CustomerTypeCode) REFERENCES pim.CustomerTypeCatalog(CustomerTypeCode));
END;
IF OBJECT_ID(N'b2b.CustomerPackagingDiscountOverride', N'U') IS NULL
BEGIN
  CREATE TABLE b2b.CustomerPackagingDiscountOverride(OverrideId bigint IDENTITY NOT NULL CONSTRAINT PK_CustomerPackagingDiscountOverride PRIMARY KEY,CustomerId bigint NOT NULL,PimProductId bigint NOT NULL,DiscountCode nvarchar(10) NOT NULL,ValidFrom date NULL,ValidTo date NULL,IsActive bit NOT NULL CONSTRAINT DF_CustomerPackagingOverride_Active DEFAULT(1),CONSTRAINT UQ_CustomerPackagingOverride UNIQUE(CustomerId,PimProductId,ValidFrom),CONSTRAINT FK_CustomerPackagingOverride_Customer FOREIGN KEY(CustomerId) REFERENCES b2b.Customer(CustomerId),CONSTRAINT FK_CustomerPackagingOverride_Product FOREIGN KEY(PimProductId) REFERENCES pim.Product(PimProductId),CONSTRAINT FK_CustomerPackagingOverride_Discount FOREIGN KEY(DiscountCode) REFERENCES pim.PackagingDiscountCatalog(DiscountCode));
END;

IF OBJECT_ID(N'b2b.AuditLog', N'U') IS NULL
BEGIN
  CREATE TABLE b2b.AuditLog(AuditLogId bigint IDENTITY NOT NULL CONSTRAINT PK_b2b_AuditLog PRIMARY KEY,OrganizationId int NOT NULL,EntityType nvarchar(100) NOT NULL,EntityKey nvarchar(200) NOT NULL,ActionCode nvarchar(50) NOT NULL,OldValueJson nvarchar(max) NULL,NewValueJson nvarchar(max) NULL,ChangedBy nvarchar(200) NOT NULL,ChangedUtc datetime2(3) NOT NULL CONSTRAINT DF_b2b_AuditLog_Changed DEFAULT SYSUTCDATETIME());
  CREATE INDEX IX_b2b_AuditLog_Entity ON b2b.AuditLog(OrganizationId,EntityType,EntityKey,ChangedUtc DESC);
END;

IF OBJECT_ID(N'b2b.LandingRecord', N'U') IS NULL
BEGIN
  CREATE TABLE b2b.LandingRecord(LandingRecordId bigint IDENTITY NOT NULL CONSTRAINT PK_b2b_LandingRecord PRIMARY KEY,OrganizationId int NOT NULL,SourceCode nvarchar(100) NOT NULL,EntityType nvarchar(100) NOT NULL,SourceRecordKey nvarchar(200) NOT NULL,PayloadJson nvarchar(max) NOT NULL,PayloadHash char(64) NOT NULL,Status nvarchar(30) NOT NULL CONSTRAINT DF_b2b_LandingRecord_Status DEFAULT(N'Pending'),ReceivedUtc datetime2(3) NOT NULL CONSTRAINT DF_b2b_LandingRecord_Received DEFAULT SYSUTCDATETIME(),ProcessedUtc datetime2(3) NULL,CONSTRAINT CK_b2b_LandingRecord_Status CHECK(Status IN(N'Pending',N'Applied',N'Rejected')));
  CREATE UNIQUE INDEX UX_b2b_LandingRecord_SourcePayloadHash ON b2b.LandingRecord(OrganizationId,SourceCode,EntityType,SourceRecordKey,PayloadHash);
END;
IF OBJECT_ID(N'map.B2bFieldMapping', N'U') IS NULL
BEGIN
  CREATE TABLE map.B2bFieldMapping(B2bFieldMappingId int IDENTITY NOT NULL CONSTRAINT PK_B2bFieldMapping PRIMARY KEY,SourceCode nvarchar(100) NOT NULL,EntityType nvarchar(100) NOT NULL,SourceField nvarchar(200) NOT NULL,TargetField nvarchar(200) NOT NULL,IsRequired bit NOT NULL CONSTRAINT DF_B2bFieldMapping_Required DEFAULT(0),IsActive bit NOT NULL CONSTRAINT DF_B2bFieldMapping_Active DEFAULT(1),CONSTRAINT UQ_B2bFieldMapping UNIQUE(SourceCode,EntityType,SourceField));
END;
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID(N'map.B2bFieldMapping') AND name=N'UX_B2bFieldMapping_Target')
  CREATE UNIQUE INDEX UX_B2bFieldMapping_Target ON map.B2bFieldMapping(SourceCode,EntityType,TargetField) WHERE IsActive=1;
IF OBJECT_ID(N'b2b.MappingRejection', N'U') IS NULL
BEGIN
  CREATE TABLE b2b.MappingRejection(MappingRejectionId bigint IDENTITY NOT NULL CONSTRAINT PK_b2b_MappingRejection PRIMARY KEY,LandingRecordId bigint NOT NULL,SourceField nvarchar(200) NULL,ReasonCode nvarchar(100) NOT NULL,ReasonDetail nvarchar(1000) NULL,RejectedUtc datetime2(3) NOT NULL CONSTRAINT DF_b2b_MappingRejection_Utc DEFAULT SYSUTCDATETIME(),CONSTRAINT UQ_b2b_MappingRejection UNIQUE(LandingRecordId,SourceField,ReasonCode),CONSTRAINT FK_b2b_MappingRejection_Landing FOREIGN KEY(LandingRecordId) REFERENCES b2b.LandingRecord(LandingRecordId));
END;
EXEC(N'CREATE OR ALTER TRIGGER b2b.TR_LandingRecord_ImmutableSource ON b2b.LandingRecord AFTER UPDATE AS
BEGIN
  SET NOCOUNT ON;
  IF EXISTS
  (
    SELECT 1 FROM inserted i JOIN deleted d ON d.LandingRecordId=i.LandingRecordId
    WHERE i.OrganizationId<>d.OrganizationId OR i.SourceCode<>d.SourceCode OR i.EntityType<>d.EntityType
       OR i.SourceRecordKey<>d.SourceRecordKey OR i.PayloadJson<>d.PayloadJson OR i.PayloadHash<>d.PayloadHash
       OR i.ReceivedUtc<>d.ReceivedUtc
  ) THROW 52010,N''Izvorni landing zapis je nespremenljiv.'',1;
END');
MERGE map.B2bFieldMapping target USING(VALUES
 (N'SAOP',N'Customers',N'CustomerCode',N'Customer.Key',1),(N'SAOP',N'Customers',N'CustomerName',N'Customer.Name',1),(N'SAOP',N'Customers',N'CustomerPayerCode',N'Customer.PayerCode',0),(N'SAOP',N'Customers',N'CustomerPayerName',N'Customer.PayerName',0),(N'SAOP',N'Customers',N'PriceList',N'Customer.PriceList',0),(N'SAOP',N'Customers',N'DiscountPriceList',N'Customer.DiscountPriceList',0),
 (N'SAOP',N'CustomerItemGroupDiscounts',N'CustomerCode',N'GroupDiscount.CustomerKey',1),(N'SAOP',N'CustomerItemGroupDiscounts',N'ItemGroupCode',N'GroupDiscount.ItemGroup',1),(N'SAOP',N'CustomerItemGroupDiscounts',N'DiscountPercent',N'GroupDiscount.Percent',1)
) source(SourceCode,EntityType,SourceField,TargetField,IsRequired)
ON target.SourceCode=source.SourceCode AND target.EntityType=source.EntityType AND target.SourceField=source.SourceField
WHEN MATCHED THEN UPDATE SET TargetField=source.TargetField,IsRequired=source.IsRequired,IsActive=1
WHEN NOT MATCHED THEN INSERT(SourceCode,EntityType,SourceField,TargetField,IsRequired) VALUES(source.SourceCode,source.EntityType,source.SourceField,source.TargetField,source.IsRequired);

MERGE out.ExportProfile target USING(VALUES(N'CUSTOMERS_B2B',N'B2B stranke',N'B2B',N'CUSTOMERS',1),(N'PRODUCTS_B2B',N'B2B izdelki',N'B2B',N'PRODUCTS',1)) source(ProfileCode,Name,ChannelCode,EntityType,IsActive)
ON target.ProfileCode=source.ProfileCode WHEN MATCHED THEN UPDATE SET Name=source.Name,ChannelCode=source.ChannelCode,EntityType=source.EntityType,IsActive=source.IsActive,UpdatedUtc=SYSUTCDATETIME() WHEN NOT MATCHED THEN INSERT(ProfileCode,Name,ChannelCode,EntityType,IsActive) VALUES(source.ProfileCode,source.Name,source.ChannelCode,source.EntityType,source.IsActive);
MERGE out.ExportColumn target USING(SELECT p.ExportProfileId,v.ColumnCode,v.OutputColumnName,v.CanonicalFieldCode,v.SortOrder,v.IsRequired,CONVERT(bit,1) IsActive FROM (VALUES
 (N'CUSTOMERS_B2B',N'KEY',N'customer_key',N'Customer.Key',10,1),(N'CUSTOMERS_B2B',N'GROUP',N'customer_group',N'Customer.MagentoGroupKey',20,1),(N'CUSTOMERS_B2B',N'TYPE',N'customer_type',N'Customer.Type',30,0),(N'CUSTOMERS_B2B',N'FLAGS',N'policy_flags',N'Customer.Flags',40,0),(N'CUSTOMERS_B2B',N'PRICE_LIST',N'price_list',N'Customer.PriceList',50,0),(N'CUSTOMERS_B2B',N'PAYER',N'payer',N'Customer.Payer',60,0),(N'CUSTOMERS_B2B',N'TIERS',N'value_tiers',N'Customer.ValueTiers',70,0),(N'CUSTOMERS_B2B',N'WEB_POLICY',N'web_discount_percent',N'Policy.B2bWebPercent',80,1),
 (N'PRODUCTS_B2B',N'ITEM',N'sku',N'Product.ItemID',10,1),(N'PRODUCTS_B2B',N'GROUP',N'customer_group',N'Customer.MagentoGroupKey',20,1),(N'PRODUCTS_B2B',N'PAK2',N'pak2',N'Product.Pak2',30,1),(N'PRODUCTS_B2B',N'S_CODE',N's_code',N'Product.PackagingDiscountCode',40,0),(N'PRODUCTS_B2B',N'S_PERCENT',N's_percent',N'Product.PackagingDiscountPercent',50,0),(N'PRODUCTS_B2B',N'PROMOTION',N'promotion_gate_state',N'Product.PromotionGateState',60,1)
) v(ProfileCode,ColumnCode,OutputColumnName,CanonicalFieldCode,SortOrder,IsRequired) JOIN out.ExportProfile p ON p.ProfileCode=v.ProfileCode) source
ON target.ExportProfileId=source.ExportProfileId AND target.ColumnCode=source.ColumnCode WHEN MATCHED THEN UPDATE SET OutputColumnName=source.OutputColumnName,CanonicalFieldCode=source.CanonicalFieldCode,SortOrder=source.SortOrder,IsRequired=source.IsRequired,IsActive=source.IsActive WHEN NOT MATCHED THEN INSERT(ExportProfileId,ColumnCode,OutputColumnName,CanonicalFieldCode,SortOrder,IsRequired,IsActive) VALUES(source.ExportProfileId,source.ColumnCode,source.OutputColumnName,source.CanonicalFieldCode,source.SortOrder,source.IsRequired,source.IsActive);

MERGE sec.Role target USING(VALUES(N'COMMERCIAL',N'Urednik komerciale')) source(RoleCode,Name) ON target.RoleCode=source.RoleCode WHEN MATCHED THEN UPDATE SET Name=source.Name WHEN NOT MATCHED THEN INSERT(RoleCode,Name) VALUES(source.RoleCode,source.Name);
MERGE sec.NavigationGroup target USING(VALUES(N'PRAVILA',N'Pravila',30,1)) source(GroupCode,Name,SortOrder,IsActive) ON target.GroupCode=source.GroupCode WHEN MATCHED THEN UPDATE SET Name=source.Name,SortOrder=source.SortOrder,IsActive=source.IsActive WHEN NOT MATCHED THEN INSERT(GroupCode,Name,SortOrder,IsActive) VALUES(source.GroupCode,source.Name,source.SortOrder,source.IsActive);
MERGE sec.NavigationItem target USING(SELECT g.NavigationGroupId,v.ItemCode,v.Name,v.Route,v.SortOrder FROM (VALUES(N'CUSTOMERS_B2B',N'Stranke',N'/stranke',10),(N'DISCOUNT_RULES_B2B',N'Pravila popustov',N'/pravila-popustov',20)) v(ItemCode,Name,Route,SortOrder) CROSS JOIN sec.NavigationGroup g WHERE g.GroupCode=N'PRAVILA') source ON target.ItemCode=source.ItemCode WHEN MATCHED THEN UPDATE SET NavigationGroupId=source.NavigationGroupId,Name=source.Name,Route=source.Route,SortOrder=source.SortOrder,IsActive=1 WHEN NOT MATCHED THEN INSERT(NavigationGroupId,ItemCode,Name,Route,SortOrder,IsActive) VALUES(source.NavigationGroupId,source.ItemCode,source.Name,source.Route,source.SortOrder,1);
MERGE sec.NavigationItemRole target USING(SELECT i.NavigationItemId,r.RoleId FROM sec.NavigationItem i JOIN sec.Role r ON r.RoleCode IN(N'ADMIN',N'CATALOG_EDITOR',N'COMMERCIAL') WHERE i.ItemCode IN(N'CUSTOMERS_B2B',N'DISCOUNT_RULES_B2B')) source ON target.NavigationItemId=source.NavigationItemId AND target.RoleId=source.RoleId WHEN NOT MATCHED THEN INSERT(NavigationItemId,RoleId) VALUES(source.NavigationItemId,source.RoleId);

EXEC(N'CREATE OR ALTER PROCEDURE b2b.ApplyLandingRecord @LandingRecordId bigint AS
BEGIN SET NOCOUNT ON; SET XACT_ABORT ON;
 DECLARE @payload nvarchar(max),@entity nvarchar(100),@source nvarchar(100),@org int;
 SELECT @payload=PayloadJson,@entity=EntityType,@source=SourceCode,@org=OrganizationId FROM b2b.LandingRecord WHERE LandingRecordId=@LandingRecordId;
 IF @payload IS NULL THROW 52011,N''Landing zapis ne obstaja.'',1;
 IF ISJSON(@payload)<>1 BEGIN INSERT b2b.MappingRejection(LandingRecordId,ReasonCode,ReasonDetail) VALUES(@LandingRecordId,N''InvalidJson'',N''Neveljaven JSON.''); UPDATE b2b.LandingRecord SET Status=N''Rejected'',ProcessedUtc=SYSUTCDATETIME() WHERE LandingRecordId=@LandingRecordId; RETURN; END;
 CREATE TABLE #Mapped(TargetField nvarchar(200) NOT NULL PRIMARY KEY,Value nvarchar(max) NULL);
 INSERT #Mapped(TargetField,Value)
 SELECT m.TargetField,j.value FROM OPENJSON(@payload) j JOIN map.B2bFieldMapping m ON m.SourceCode=@source AND m.EntityType=@entity AND m.SourceField=j.[key] AND m.IsActive=1;
 INSERT b2b.MappingRejection(LandingRecordId,SourceField,ReasonCode,ReasonDetail)
 SELECT @LandingRecordId,j.[key],N''UnmappedField'',N''Polje nima aktivne preslikave.'' FROM OPENJSON(@payload) j
 WHERE NOT EXISTS(SELECT 1 FROM map.B2bFieldMapping m WHERE m.SourceCode=@source AND m.EntityType=@entity AND m.SourceField=j.[key] AND m.IsActive=1);
 INSERT b2b.MappingRejection(LandingRecordId,SourceField,ReasonCode,ReasonDetail)
 SELECT @LandingRecordId,m.SourceField,N''MissingRequiredField'',N''Obvezno polje manjka ali je prazno.'' FROM map.B2bFieldMapping m
 LEFT JOIN OPENJSON(@payload) j ON j.[key]=m.SourceField
 WHERE m.SourceCode=@source AND m.EntityType=@entity AND m.IsActive=1 AND m.IsRequired=1 AND NULLIF(LTRIM(RTRIM(j.value)),N'''') IS NULL;
 IF EXISTS(SELECT 1 FROM b2b.MappingRejection WHERE LandingRecordId=@LandingRecordId)
 BEGIN UPDATE b2b.LandingRecord SET Status=N''Rejected'',ProcessedUtc=SYSUTCDATETIME() WHERE LandingRecordId=@LandingRecordId; RETURN; END;
 IF @entity=N''Customers'' BEGIN
  DECLARE @key nvarchar(100)=(SELECT Value FROM #Mapped WHERE TargetField=N''Customer.Key''),@name nvarchar(300)=(SELECT Value FROM #Mapped WHERE TargetField=N''Customer.Name'');
  IF NULLIF(@key,N'''') IS NULL OR NULLIF(@name,N'''') IS NULL THROW 52012,N''Konfiguracija Customers nima obveznih ciljnih polj.'',1;
  MERGE b2b.Customer t USING(SELECT @org OrganizationId,@key CustomerKey) s ON t.OrganizationId=s.OrganizationId AND t.CustomerKey=s.CustomerKey
  WHEN MATCHED THEN UPDATE SET Name=@name,PayerCode=(SELECT Value FROM #Mapped WHERE TargetField=N''Customer.PayerCode''),PayerName=(SELECT Value FROM #Mapped WHERE TargetField=N''Customer.PayerName''),PriceListCode=(SELECT Value FROM #Mapped WHERE TargetField=N''Customer.PriceList''),DiscountPriceListCode=(SELECT Value FROM #Mapped WHERE TargetField=N''Customer.DiscountPriceList''),UpdatedUtc=SYSUTCDATETIME()
  WHEN NOT MATCHED THEN INSERT(OrganizationId,CustomerKey,Name,PayerCode,PayerName,PriceListCode,DiscountPriceListCode) VALUES(@org,@key,@name,(SELECT Value FROM #Mapped WHERE TargetField=N''Customer.PayerCode''),(SELECT Value FROM #Mapped WHERE TargetField=N''Customer.PayerName''),(SELECT Value FROM #Mapped WHERE TargetField=N''Customer.PriceList''),(SELECT Value FROM #Mapped WHERE TargetField=N''Customer.DiscountPriceList''));
 END;
 UPDATE b2b.LandingRecord SET Status=N''Applied'',ProcessedUtc=SYSUTCDATETIME() WHERE LandingRecordId=@LandingRecordId;
END');
EXEC(N'CREATE OR ALTER PROCEDURE b2b.ReplayLandingRecord @LandingRecordId bigint AS BEGIN SET NOCOUNT ON; DELETE FROM b2b.MappingRejection WHERE LandingRecordId=@LandingRecordId; UPDATE b2b.LandingRecord SET Status=N''Pending'',ProcessedUtc=NULL WHERE LandingRecordId=@LandingRecordId; EXEC b2b.ApplyLandingRecord @LandingRecordId; END');
EXEC(N'CREATE OR ALTER PROCEDURE b2b.SaveCustomerWebProfile @OrganizationId int,@CustomerId bigint,@CustomerTypeCode nvarchar(60)=NULL,@CustomerKind nvarchar(20)=NULL,@PackagingDiscountEnabled bit,@ValueDiscountEnabled bit,@B2bPlusEnabled bit,@B2bPlusValidFrom date=NULL,@B2bPlusValidTo date=NULL,@WebEnabled bit,@ChangedBy nvarchar(200) AS BEGIN SET NOCOUNT ON; SET XACT_ABORT ON; BEGIN TRAN; IF NOT EXISTS(SELECT 1 FROM b2b.Customer WHERE CustomerId=@CustomerId AND OrganizationId=@OrganizationId) THROW 52000,N''Stranka ne obstaja.'',1; DECLARE @old nvarchar(max)=(SELECT * FROM pim.CustomerWebProfile WHERE CustomerId=@CustomerId FOR JSON PATH,WITHOUT_ARRAY_WRAPPER); MERGE pim.CustomerWebProfile t USING(SELECT @CustomerId CustomerId) s ON t.CustomerId=s.CustomerId WHEN MATCHED THEN UPDATE SET CustomerTypeCode=@CustomerTypeCode,CustomerKind=@CustomerKind,PackagingDiscountEnabled=@PackagingDiscountEnabled,ValueDiscountEnabled=@ValueDiscountEnabled,B2bPlusEnabled=@B2bPlusEnabled,B2bPlusValidFrom=@B2bPlusValidFrom,B2bPlusValidTo=@B2bPlusValidTo,WebEnabled=@WebEnabled,UpdatedUtc=SYSUTCDATETIME() WHEN NOT MATCHED THEN INSERT(CustomerId,CustomerTypeCode,CustomerKind,PackagingDiscountEnabled,ValueDiscountEnabled,B2bPlusEnabled,B2bPlusValidFrom,B2bPlusValidTo,WebEnabled) VALUES(@CustomerId,@CustomerTypeCode,@CustomerKind,@PackagingDiscountEnabled,@ValueDiscountEnabled,@B2bPlusEnabled,@B2bPlusValidFrom,@B2bPlusValidTo,@WebEnabled); INSERT b2b.AuditLog(OrganizationId,EntityType,EntityKey,ActionCode,OldValueJson,NewValueJson,ChangedBy) SELECT @OrganizationId,N''CustomerWebProfile'',CONVERT(nvarchar(30),@CustomerId),N''UPSERT'',@old,(SELECT * FROM pim.CustomerWebProfile WHERE CustomerId=@CustomerId FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),@ChangedBy; COMMIT; END');
EXEC(N'CREATE OR ALTER PROCEDURE b2b.SaveDiscountRule @OrganizationId int,@RuleCode nvarchar(40),@OrderThreshold decimal(19,4)=NULL,@PackageLengthMeters decimal(9,3)=NULL,@ShippingNet decimal(19,4),@IsFree bit,@Priority int,@ChangedBy nvarchar(200) AS BEGIN SET NOCOUNT ON; SET XACT_ABORT ON; BEGIN TRAN; DECLARE @old nvarchar(max)=(SELECT * FROM pim.ShippingRuleCatalog WHERE RuleCode=@RuleCode FOR JSON PATH,WITHOUT_ARRAY_WRAPPER); MERGE pim.ShippingRuleCatalog t USING(SELECT @RuleCode RuleCode) s ON t.RuleCode=s.RuleCode WHEN MATCHED THEN UPDATE SET OrderThreshold=@OrderThreshold,PackageLengthMeters=@PackageLengthMeters,ShippingNet=@ShippingNet,IsFree=@IsFree,Priority=@Priority,UpdatedUtc=SYSUTCDATETIME() WHEN NOT MATCHED THEN INSERT(RuleCode,OrderThreshold,PackageLengthMeters,ShippingNet,IsFree,Priority) VALUES(@RuleCode,@OrderThreshold,@PackageLengthMeters,@ShippingNet,@IsFree,@Priority); INSERT b2b.AuditLog(OrganizationId,EntityType,EntityKey,ActionCode,OldValueJson,NewValueJson,ChangedBy) SELECT @OrganizationId,N''ShippingRule'',@RuleCode,N''UPSERT'',@old,(SELECT * FROM pim.ShippingRuleCatalog WHERE RuleCode=@RuleCode FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),@ChangedBy; COMMIT; END');
EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetCustomers @OrganizationId int AS BEGIN SET NOCOUNT ON; SELECT c.CustomerId,c.CustomerKey,c.Name,p.CustomerKind,t.Name CustomerType,g.MagentoGroupKey,p.WebEnabled,p.PackagingDiscountEnabled,p.ValueDiscountEnabled,p.B2bPlusEnabled FROM b2b.Customer c LEFT JOIN pim.CustomerWebProfile p ON p.CustomerId=c.CustomerId LEFT JOIN pim.CustomerTypeCatalog t ON t.CustomerTypeCode=p.CustomerTypeCode LEFT JOIN pim.CustomerTypeMagentoGroup g ON g.CustomerTypeCode=p.CustomerTypeCode WHERE c.OrganizationId=@OrganizationId ORDER BY c.Name; END');
EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetCustomerDetail @OrganizationId int,@CustomerId bigint AS BEGIN SET NOCOUNT ON; SELECT c.CustomerId,c.CustomerKey,c.Name,c.PayerCode,c.PayerName,c.PriceListCode,c.DiscountPriceListCode,p.CustomerTypeCode,p.CustomerKind,p.PackagingDiscountEnabled,p.ValueDiscountEnabled,p.B2bPlusEnabled,p.B2bPlusValidFrom,p.B2bPlusValidTo,p.WebEnabled,g.MagentoGroupKey FROM b2b.Customer c LEFT JOIN pim.CustomerWebProfile p ON p.CustomerId=c.CustomerId LEFT JOIN pim.CustomerTypeMagentoGroup g ON g.CustomerTypeCode=p.CustomerTypeCode WHERE c.OrganizationId=@OrganizationId AND c.CustomerId=@CustomerId; SELECT TierNumber,ThresholdGrossExVat,PercentValue FROM pim.CustomerValueDiscountTier WHERE CustomerId=@CustomerId ORDER BY TierNumber; END');
EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetDiscountRules AS BEGIN SET NOCOUNT ON; SELECT RuleCode,OrderThreshold,PackageLengthMeters,ShippingNet,IsFree,Priority FROM pim.ShippingRuleCatalog WHERE IsActive=1 ORDER BY Priority; END');
EXEC(N'CREATE OR ALTER PROCEDURE out.ExportB2bCustomersCsv @OrganizationId int AS BEGIN SET NOCOUNT ON; SELECT c.CustomerKey,g.MagentoGroupKey,p.CustomerTypeCode,p.PackagingDiscountEnabled,p.ValueDiscountEnabled,p.B2bPlusEnabled,p.B2bPlusValidFrom,p.B2bPlusValidTo,c.PriceListCode,c.DiscountPriceListCode,c.PayerCode,c.PayerName,COALESCE(t1.ThresholdGrossExVat,d1.ThresholdGrossExVat) Tier1Threshold,COALESCE(t1.PercentValue,d1.PercentValue) Tier1Percent,COALESCE(t2.ThresholdGrossExVat,d2.ThresholdGrossExVat) Tier2Threshold,COALESCE(t2.PercentValue,d2.PercentValue) Tier2Percent,COALESCE(t3.ThresholdGrossExVat,d3.ThresholdGrossExVat) Tier3Threshold,COALESCE(t3.PercentValue,d3.PercentValue) Tier3Percent,CONVERT(decimal(9,4),2) B2bWebPercent FROM b2b.Customer c JOIN pim.CustomerWebProfile p ON p.CustomerId=c.CustomerId LEFT JOIN pim.CustomerTypeMagentoGroup g ON g.CustomerTypeCode=p.CustomerTypeCode LEFT JOIN pim.CustomerValueDiscountTier t1 ON t1.CustomerId=c.CustomerId AND t1.TierNumber=1 LEFT JOIN pim.CustomerValueDiscountTier t2 ON t2.CustomerId=c.CustomerId AND t2.TierNumber=2 LEFT JOIN pim.CustomerValueDiscountTier t3 ON t3.CustomerId=c.CustomerId AND t3.TierNumber=3 JOIN pim.ValueDiscountTier d1 ON d1.TierNumber=1 JOIN pim.ValueDiscountTier d2 ON d2.TierNumber=2 JOIN pim.ValueDiscountTier d3 ON d3.TierNumber=3 WHERE c.OrganizationId=@OrganizationId AND p.WebEnabled=1 ORDER BY c.CustomerKey; END');
EXEC(N'CREATE OR ALTER PROCEDURE out.ExportB2bProductsCsv @OrganizationId int AS BEGIN SET NOCOUNT ON; SELECT p.ItemID,g.MagentoGroupKey,pc.Pak2,pd.DiscountCode,dc.PercentValue,pd.PromotionGateState FROM pim.Product p JOIN pim.ProductCommercial pc ON pc.PimProductId=p.PimProductId LEFT JOIN pim.ProductPackagingDiscount pd ON pd.PimProductId=p.PimProductId LEFT JOIN pim.PackagingDiscountCatalog dc ON dc.DiscountCode=pd.DiscountCode CROSS JOIN pim.CustomerTypeMagentoGroup g WHERE p.OrganizationId=@OrganizationId AND g.IsActive=1 AND g.MagentoGroupKey IS NOT NULL ORDER BY p.ItemID,g.MagentoGroupKey; END');
