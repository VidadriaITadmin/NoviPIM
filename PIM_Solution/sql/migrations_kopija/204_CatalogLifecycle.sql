/* Catalog lifecycle. ERP identity remains scoped to the organization; stock is
   joined by ItemID using the existing, explicitly configured stock sources. */
SET XACT_ABORT ON;

IF OBJECT_ID(N'pim.CatalogPolicy', N'U') IS NULL
CREATE TABLE pim.CatalogPolicy (
  ProductId bigint NOT NULL PRIMARY KEY REFERENCES canon.Product(ProductId),
  IsExcluded bit NOT NULL DEFAULT 0,
  ClearancePercent decimal(5,2) NOT NULL DEFAULT 0 CHECK (ClearancePercent BETWEEN 0 AND 100),
  UpdatedUtc datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  UpdatedBy nvarchar(200) NOT NULL
);
IF OBJECT_ID(N'pim.CatalogReview', N'U') IS NULL
CREATE TABLE pim.CatalogReview (
  ProductId bigint NOT NULL PRIMARY KEY REFERENCES canon.Product(ProductId),
  OpenedUtc datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME(),
  ResolvedUtc datetime2(3) NULL,
  ResolvedBy nvarchar(200) NULL,
  Resolution nvarchar(1000) NULL
);
IF OBJECT_ID(N'pim.CatalogPolicyHistory', N'U') IS NULL
CREATE TABLE pim.CatalogPolicyHistory (
  ChangeId bigint IDENTITY PRIMARY KEY, ProductId bigint NOT NULL,
  IsExcluded bit NOT NULL, ClearancePercent decimal(5,2) NOT NULL,
  ChangedUtc datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME(), ChangedBy nvarchar(200) NOT NULL
);

EXEC(N'CREATE OR ALTER VIEW out.CatalogStock AS
WITH Sources AS (
 SELECT registry.OrganizationId, registry.Contribution, snapshot.SnapshotUtc,
   product.ItemID, position.Quantity, COALESCE(position.AvailableQuantity,position.Quantity) Available
 FROM out.ExportStockSource registry
 JOIN map.SourceConnector connector ON connector.OrganizationId=registry.StockOrganizationId AND connector.SourceCode=registry.SourceCode
 JOIN stock.Snapshot snapshot ON snapshot.SourceConnectorId=connector.SourceConnectorId AND snapshot.IsActive=1
 JOIN stock.Position position ON position.SnapshotId=snapshot.SnapshotId
 JOIN canon.Product product ON product.ProductId=position.MatchedProductId
 WHERE registry.IsActive=1
)
SELECT OrganizationId,ItemID,
 OwnAvailable=SUM(CASE WHEN Contribution IN (N''BASE'',N''ADD'') THEN Available ELSE 0 END),
 SupplierAvailable=SUM(CASE WHEN Contribution=N''SUPPLIER'' THEN Quantity ELSE 0 END),
 OwnObserved=SUM(CASE WHEN Contribution IN (N''BASE'',N''ADD'') THEN 1 ELSE 0 END),
 OwnSnapshotUtc=MIN(CASE WHEN Contribution IN (N''BASE'',N''ADD'') THEN SnapshotUtc END),
 SupplierSnapshotUtc=MIN(CASE WHEN Contribution=N''SUPPLIER'' THEN SnapshotUtc END)
FROM Sources GROUP BY OrganizationId,ItemID');

EXEC(N'CREATE OR ALTER FUNCTION out.CatalogOwnStockFresh(@OrganizationId int)
RETURNS bit AS BEGIN
 IF NOT EXISTS(SELECT 1 FROM out.ExportStockSource WHERE OrganizationId=@OrganizationId AND IsActive=1 AND Contribution IN(N''BASE'',N''ADD'')) RETURN 0;
 IF EXISTS(SELECT 1 FROM out.ExportStockSource registry
   WHERE registry.OrganizationId=@OrganizationId AND registry.IsActive=1 AND registry.Contribution IN(N''BASE'',N''ADD'')
   AND NOT EXISTS(SELECT 1 FROM map.SourceConnector connector JOIN stock.Snapshot snapshot ON snapshot.SourceConnectorId=connector.SourceConnectorId
     WHERE connector.OrganizationId=registry.StockOrganizationId AND connector.SourceCode=registry.SourceCode
       AND snapshot.IsActive=1 AND snapshot.SnapshotUtc>=DATEADD(minute,-30,SYSUTCDATETIME()))) RETURN 0;
 RETURN 1;
END');

EXEC(N'CREATE OR ALTER PROCEDURE pim.RefreshCatalogReview @OrganizationId int AS
BEGIN
 SET NOCOUNT ON;
 SET XACT_ABORT ON;
 IF out.CatalogOwnStockFresh(@OrganizationId)=0 RETURN;
 /* Missing or old stock is unknown, never evidence of depletion. */
 MERGE pim.CatalogReview WITH (HOLDLOCK) AS target
 USING (SELECT p.ProductId FROM canon.Product p
   JOIN out.CatalogStock s ON s.OrganizationId=p.OrganizationId AND s.ItemID=p.ItemID
   WHERE p.OrganizationId=@OrganizationId AND p.Department=N''O'' AND p.IsActive=1
     AND NOT EXISTS(SELECT 1 FROM pim.CatalogPolicy policy WHERE policy.ProductId=p.ProductId AND policy.IsExcluded=1)
     AND s.OwnObserved>0 AND s.OwnAvailable<=0
     AND s.OwnSnapshotUtc>=DATEADD(minute,-30,SYSUTCDATETIME())) source
 ON target.ProductId=source.ProductId
 WHEN NOT MATCHED THEN INSERT(ProductId) VALUES(source.ProductId)
 WHEN MATCHED AND target.ResolvedUtc IS NOT NULL THEN
   UPDATE SET OpenedUtc=SYSUTCDATETIME(),ResolvedUtc=NULL,ResolvedBy=NULL,Resolution=NULL;
END');

EXEC(N'CREATE OR ALTER PROCEDURE pim.SaveCatalogPolicy
 @OrganizationId int,@ProductId bigint,@IsExcluded bit,@ClearancePercent decimal(5,2),@Actor nvarchar(200)
AS BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 IF NOT EXISTS(SELECT 1 FROM canon.Product WHERE ProductId=@ProductId AND OrganizationId=@OrganizationId)
   THROW 52401,N''Artikel ne pripada izbranemu podjetju.'',1;
 IF @ClearancePercent IS NULL OR @ClearancePercent<0 OR @ClearancePercent>100 OR NULLIF(@Actor,N'''') IS NULL
   THROW 52402,N''Vnesi popust med 0 in 100 ter izvajalca.'',1;
 BEGIN TRANSACTION;
 MERGE pim.CatalogPolicy WITH(HOLDLOCK) target USING(SELECT @ProductId ProductId) source ON target.ProductId=source.ProductId
 WHEN MATCHED THEN UPDATE SET IsExcluded=@IsExcluded,ClearancePercent=@ClearancePercent,UpdatedUtc=SYSUTCDATETIME(),UpdatedBy=@Actor
 WHEN NOT MATCHED THEN INSERT(ProductId,IsExcluded,ClearancePercent,UpdatedBy) VALUES(@ProductId,@IsExcluded,@ClearancePercent,@Actor);
 INSERT pim.CatalogPolicyHistory(ProductId,IsExcluded,ClearancePercent,ChangedBy) VALUES(@ProductId,@IsExcluded,@ClearancePercent,@Actor);
 COMMIT;
END');

EXEC(N'CREATE OR ALTER PROCEDURE pim.ResolveCatalogReview
 @OrganizationId int,@ProductId bigint,@Resolution nvarchar(1000),@Actor nvarchar(200)
AS BEGIN
 SET NOCOUNT ON;
 IF NULLIF(LTRIM(RTRIM(@Resolution)),N'''') IS NULL THROW 52403,N''Vnesi opis opravljenega pregleda.'',1;
 IF EXISTS(SELECT 1 FROM canon.Product p LEFT JOIN pim.CatalogPolicy policy ON policy.ProductId=p.ProductId
   WHERE p.ProductId=@ProductId AND p.OrganizationId=@OrganizationId AND p.Department=N''O'' AND p.IsActive=1 AND ISNULL(policy.IsExcluded,0)=0)
   THROW 52404,N''Najprej spremeni ABC oznako ali aktivnost na kartici artikla oziroma ga izkljuci iz kataloga.'',1;
 UPDATE review SET ResolvedUtc=SYSUTCDATETIME(),ResolvedBy=@Actor,Resolution=@Resolution
 FROM pim.CatalogReview review JOIN canon.Product p ON p.ProductId=review.ProductId
 WHERE p.ProductId=@ProductId AND p.OrganizationId=@OrganizationId AND review.ResolvedUtc IS NULL;
END');

/* Preserve the existing gates, column order and customer contract. */
DECLARE @definition nvarchar(max)=OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows'));
IF @definition IS NULL THROW 52405,N'GetExportRows manjka.',1;
IF @definition NOT LIKE N'%/* CatalogLifecycle204 */%'
BEGIN
 DECLARE @anchor nvarchar(max)=N'AND (@WebSite IS NULL OR category.WebSite = @WebSite)';
 DECLARE @siteStart int=CHARINDEX(N'INSERT #Site (PimProductId, WebSite)',@definition);
 DECLARE @siteFilter int=CHARINDEX(@anchor,@definition,@siteStart);
 IF @siteStart=0 OR @siteFilter=0 OR CHARINDEX(@anchor,@definition,@siteFilter+LEN(@anchor))<>0
   THROW 52406,N'Nepricakovana definicija spletnega izbora.',1;
 SET @definition=STUFF(@definition,@siteFilter+LEN(@anchor),0,N'
      AND NOT EXISTS(SELECT 1 FROM pim.CatalogPolicy policy WHERE policy.ProductId=canonProduct.ProductId AND policy.IsExcluded=1) /* CatalogLifecycle204 */');
 DECLARE @values nvarchar(max)=N'
  IF @ValueSource=N''PIM_PRODUCT''
  BEGIN
    DECLARE @CatalogOwnFresh bit=out.CatalogOwnStockFresh(@OrganizationId);
    /* Prices are volatile: read the current canonical price lists without waiting
       for a full content promotion. Preserve the configured price-list priority. */
    DELETE FROM #Value WHERE FieldCode IN(N''Product.PriceB2B'',N''Product.PriceB2C'');
    INSERT #Value(RowKey,FieldCode,Value)
    SELECT RowKey,PriceFieldCode,out.MagentoNumber(Net) FROM (
      SELECT page.RowKey,registry.PriceFieldCode,price.Net,
        ROW_NUMBER() OVER(PARTITION BY page.RowKey,registry.PriceFieldCode
          ORDER BY registry.SortOrder,price.ValidFrom DESC,price.ProductPriceId DESC) PickRank
      FROM #Page page JOIN canon.Product product ON product.OrganizationId=@OrganizationId AND product.ItemID=page.RowKey
      JOIN canon.ProductPrice price ON price.ProductId=product.ProductId AND price.IsActive=1 AND price.ValidFrom<=SYSUTCDATETIME()
      JOIN out.ExportPriceList registry ON registry.OrganizationId=@OrganizationId AND registry.PriceListCode=price.PriceList
        AND registry.IsActive=1 AND registry.PriceFieldCode IN(N''Product.PriceB2B'',N''Product.PriceB2C'')
    ) prices WHERE PickRank=1;
    INSERT #Value(RowKey,FieldCode,Value)
    SELECT page.RowKey,field.FieldCode,field.Value
    FROM #Page page
    JOIN canon.Product product ON product.OrganizationId=@OrganizationId AND product.ItemID=page.RowKey
    LEFT JOIN pim.CatalogPolicy policy ON policy.ProductId=product.ProductId
    LEFT JOIN out.CatalogStock stock ON stock.OrganizationId=product.OrganizationId AND stock.ItemID=product.ItemID
    CROSS APPLY(VALUES
      (N''Product.Department'',CONVERT(nvarchar(max),product.Department)),
      (N''Product.ItemGroup'',CONVERT(nvarchar(max),product.ItemGroup)),
      (N''Product.DiscountGroup'',CONVERT(nvarchar(max),product.DiscountGroup)),
      (N''Product.ClearancePercent'',CONVERT(nvarchar(max),out.MagentoNumber(
        CASE WHEN product.Department IN(N''X'',N''O'') AND stock.OwnAvailable>0 AND @CatalogOwnFresh=1
          AND stock.OwnSnapshotUtc>=DATEADD(minute,-30,SYSUTCDATETIME())
        THEN ISNULL(policy.ClearancePercent,0) ELSE 0 END)))
    ) field(FieldCode,Value);
  END;
  ';
 SET @anchor=N'CREATE CLUSTERED INDEX IX_Value ON #Value (RowKey);';
 IF CHARINDEX(@anchor,@definition)=0 THROW 52407,N'Nepricakovana definicija izvoznih vrednosti.',1;
 SET @definition=REPLACE(@definition,@anchor,@values+@anchor);
 SET @definition=N'ALTER '+SUBSTRING(@definition,CHARINDEX(N'PROCEDURE',@definition),2147483647);
  EXEC sys.sp_executesql @definition;
END;

UPDATE c SET CanonicalFieldCode=m.FieldCode
FROM out.ExportColumn c JOIN out.ExportProfile p ON p.ExportProfileId=c.ExportProfileId
JOIN (VALUES(N'COL008',N'Product.Department'),(N'COL030',N'Product.ClearancePercent')) m(ColumnCode,FieldCode) ON m.ColumnCode=c.ColumnCode
WHERE p.ProfileCode=N'MAGENTO_PRODUCTS' AND NULLIF(c.CanonicalFieldCode,N'') IS NULL;
/* A separate item-group column avoids overwriting the existing packaging group. */
INSERT out.ExportColumn(ExportProfileId,ColumnCode,OutputColumnName,CanonicalFieldCode,SortOrder,IsRequired,IsActive)
SELECT p.ExportProfileId,m.Code,m.Label,m.FieldCode,ISNULL(lastColumn.LastOrder,0)+m.Ordinal,0,1
FROM out.ExportProfile p
CROSS APPLY(SELECT MAX(SortOrder) LastOrder FROM out.ExportColumn WHERE ExportProfileId=p.ExportProfileId) lastColumn
CROSS JOIN(VALUES(N'CATALOG_ITEM_GROUP',N'Rabatna skupina artikla',N'Product.ItemGroup',1),
                 (N'CATALOG_DISCOUNT_GROUP',N'Rabatna skupina ERP',N'Product.DiscountGroup',2),
                 (N'CATALOG_CLEARANCE',N'Popust odprodaje %',N'Product.ClearancePercent',3)) m(Code,Label,FieldCode,Ordinal)
WHERE p.ProfileCode IN(N'MAGENTO_PRODUCTS',N'MAGENTO_STOCK_PRICES')
AND NOT EXISTS(SELECT 1 FROM out.ExportColumn c WHERE c.ExportProfileId=p.ExportProfileId AND c.ColumnCode=m.Code);
