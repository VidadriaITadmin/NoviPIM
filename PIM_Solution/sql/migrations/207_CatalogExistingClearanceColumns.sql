/* Some installations already added clearance columns through the registry editor.
   Keep those headers and avoid exporting the same name twice. */
SET XACT_ABORT ON;
UPDATE existing SET CanonicalFieldCode=N'Product.ClearancePercent'
FROM out.ExportColumn existing JOIN out.ExportProfile profile ON profile.ExportProfileId=existing.ExportProfileId
WHERE profile.ProfileCode=N'MAGENTO_PRODUCTS' AND existing.IsActive=1
  AND existing.OutputColumnName=N'Popust odprodaje %' AND existing.ColumnCode<>N'CATALOG_CLEARANCE'
  AND existing.CanonicalFieldCode IN(N'Clearance.DiscountPercent',N'Product.ClearancePercent');
UPDATE added SET IsActive=0
FROM out.ExportColumn added JOIN out.ExportProfile profile ON profile.ExportProfileId=added.ExportProfileId
WHERE profile.ProfileCode=N'MAGENTO_PRODUCTS' AND added.ColumnCode=N'CATALOG_CLEARANCE'
  AND EXISTS(SELECT 1 FROM out.ExportColumn existing WHERE existing.ExportProfileId=added.ExportProfileId
    AND existing.IsActive=1 AND existing.ColumnCode<>added.ColumnCode
    AND existing.OutputColumnName=added.OutputColumnName AND existing.CanonicalFieldCode=N'Product.ClearancePercent');

DECLARE @definition nvarchar(max)=OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows'));
IF @definition IS NULL THROW 52701,N'GetExportRows manjka.',1;
IF @definition NOT LIKE N'%/* ClearanceQuantity207 */%'
BEGIN
 DECLARE @anchor nvarchar(max)=N'CREATE CLUSTERED INDEX IX_Value ON #Value (RowKey);';
 IF CHARINDEX(@anchor,@definition)=0 THROW 52702,N'Nepricakovana definicija izvoznih vrednosti.',1;
 DECLARE @values nvarchar(max)=N'
  IF @ValueSource=N''PIM_PRODUCT'' BEGIN
    /* ClearanceQuantity207: effective stock, never the quantity from an old spreadsheet. */
    DECLARE @ClearanceFresh bit=out.CatalogOwnStockFresh(@OrganizationId);
    INSERT #Value(RowKey,FieldCode,Value)
    SELECT page.RowKey,N''Clearance.Quantity'',out.MagentoNumber(CASE
      WHEN product.Department IN(N''X'',N''O'') AND stock.OwnAvailable>0 AND @ClearanceFresh=1
        AND stock.OwnSnapshotUtc>=DATEADD(minute,-30,SYSUTCDATETIME()) THEN stock.OwnAvailable ELSE 0 END)
    FROM #Page page JOIN canon.Product product ON product.OrganizationId=@OrganizationId AND product.ItemID=page.RowKey
    LEFT JOIN out.CatalogStock stock ON stock.OrganizationId=product.OrganizationId AND stock.ItemID=product.ItemID;
  END;
 ';
 SET @definition=REPLACE(@definition,@anchor,@values+@anchor);
 SET @definition=N'ALTER '+SUBSTRING(@definition,CHARINDEX(N'PROCEDURE',@definition),2147483647);
 EXEC sys.sp_executesql @definition;
END;
IF EXISTS(SELECT 1 FROM out.ExportColumn c JOIN out.ExportProfile p ON p.ExportProfileId=c.ExportProfileId
  WHERE p.ProfileCode IN(N'MAGENTO_PRODUCTS',N'MAGENTO_STOCK_PRICES') AND c.IsActive=1
  GROUP BY p.ExportProfileId,c.OutputColumnName HAVING COUNT(*)>1)
  THROW 52703,N'Izvoz ima podvojene glave stolpcev.',1;
