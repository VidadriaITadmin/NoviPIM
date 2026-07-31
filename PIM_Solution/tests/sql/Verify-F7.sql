SET NOCOUNT ON;
IF OBJECT_ID(N'b2b.Customer',N'U') IS NULL THROW 52701,N'Manjka b2b.Customer.',1;
IF OBJECT_ID(N'b2b.ApplyLandingRecord',N'P') IS NULL THROW 52702,N'Manjka landing apply.',1;
IF (SELECT COUNT(*) FROM pim.CustomerTypeCatalog WHERE IsActive=1)<>18 THROW 52703,N'Ni 18 tipov strank.',1;
IF (SELECT COUNT(*) FROM pim.PackagingDiscountCatalog WHERE IsActive=1)<>4 THROW 52704,N'Ni štirih S-stopenj.',1;
IF (SELECT COUNT(*) FROM pim.ValueDiscountTier WHERE IsActive=1)<>3 THROW 52705,N'Ni treh vrednostnih pragov.',1;
IF (SELECT COUNT(*) FROM out.ExportProfile WHERE ProfileCode IN(N'CUSTOMERS_B2B',N'PRODUCTS_B2B') AND IsActive=1)<>2 THROW 52706,N'B2B profila nista aktivna.',1;
IF EXISTS(SELECT 1 FROM pim.CustomerTypeMagentoGroup WHERE MagentoGroupKey=N'UNASSIGNED') THROW 52707,N'Neodobrena Magento skupina je bila izmišljena.',1;
SELECT N'F7 SQL pogodba PASS' Result;
