/* Make the active CSV contract contiguous and identical to MagentoCsvContract:
   213 original fields + 2 clearance fields + 2 explicit item discount groups. */
SET XACT_ABORT ON;
DECLARE @profileId int=(SELECT ExportProfileId FROM out.ExportProfile WHERE ProfileCode=N'MAGENTO_PRODUCTS');
IF @profileId IS NULL THROW 52910,N'Profil MAGENTO_PRODUCTS manjka.',1;
/* COL055/COL058 so neaktivni ostanki starejsih migracij, ki se e vedno drzijo SortOrder 214/215 -
   UQ_ExportColumn_ProfileOrder ni filtriran po IsActive, zato ju je treba premakniti hkrati z zamenjavo. */
UPDATE out.ExportColumn SET SortOrder=CASE ColumnCode
  WHEN N'COL216' THEN 214 WHEN N'COL217' THEN 215
  WHEN N'CATALOG_ITEM_GROUP' THEN 216 WHEN N'CATALOG_DISCOUNT_GROUP' THEN 217
  WHEN N'COL055' THEN 218 WHEN N'COL058' THEN 219 END
WHERE ExportProfileId=@profileId AND ColumnCode IN(N'COL216',N'COL217',N'CATALOG_ITEM_GROUP',N'CATALOG_DISCOUNT_GROUP',N'COL055',N'COL058');
IF (SELECT COUNT(*) FROM out.ExportColumn WHERE ExportProfileId=@profileId AND IsActive=1)<>217
  THROW 52911,N'Profil MAGENTO_PRODUCTS nima pricakovanih 217 aktivnih stolpcev.',1;
IF EXISTS(SELECT SortOrder FROM out.ExportColumn WHERE ExportProfileId=@profileId AND IsActive=1 GROUP BY SortOrder HAVING COUNT(*)>1)
  THROW 52912,N'Aktivni stolpci kataloga nimajo enolicnega vrstnega reda.',1;
IF EXISTS(SELECT 1 FROM out.ExportColumn WHERE ExportProfileId=@profileId AND IsActive=1
  GROUP BY OutputColumnName HAVING COUNT(*)>1)
  THROW 52913,N'Katalog ima podvojene glave.',1;
