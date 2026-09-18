/* Complete fields whose sources already exist. Unknown units remain unknown. */
SET XACT_ABORT ON;
DECLARE @definition nvarchar(max)=OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows'));
IF @definition IS NULL THROW 52601,N'GetExportRows manjka.',1;
IF @definition NOT LIKE N'%/* CatalogFields206 */%'
BEGIN
 DECLARE @anchor nvarchar(max)=N'CREATE CLUSTERED INDEX IX_Value ON #Value (RowKey);';
 IF CHARINDEX(@anchor,@definition)=0 THROW 52602,N'Nepricakovana definicija izvoznih vrednosti.',1;
 DECLARE @values nvarchar(max)=N'
  /* CatalogFields206 */
  IF @ValueSource=N''PIM_PRODUCT'' BEGIN
    /* Main document: explicit MAIN/PRIMARY first, then the stored ordering.
       Roles and other URLs retain the same deterministic order. */
    SELECT page.RowKey,document.Url,document.Role,
      ROW_NUMBER() OVER(PARTITION BY page.RowKey ORDER BY
        CASE WHEN UPPER(document.Role) IN(N''PRIMARY'',N''MAIN'') THEN 0 ELSE 1 END,
        document.SortOrder,document.ProductDocumentId) Ordinal
    INTO #CatalogDocument
    FROM #Page page JOIN canon.Product product ON product.OrganizationId=@OrganizationId AND product.ItemID=page.RowKey
    JOIN canon.ProductDocument document ON document.ProductId=product.ProductId;
    INSERT #Value(RowKey,FieldCode,Value)
    SELECT RowKey,N''Product.MainDocument'',Url FROM #CatalogDocument WHERE Ordinal=1;
    INSERT #Value(RowKey,FieldCode,Value)
    SELECT RowKey,N''Product.OtherDocuments'',STRING_AGG(CONVERT(nvarchar(max),Url),N''|'') WITHIN GROUP(ORDER BY Ordinal)
    FROM #CatalogDocument WHERE Ordinal>1 GROUP BY RowKey;
    INSERT #Value(RowKey,FieldCode,Value)
    SELECT RowKey,N''Product.DocumentRoles'',STRING_AGG(CONVERT(nvarchar(max),Role),N''|'') WITHIN GROUP(ORDER BY Ordinal)
    FROM #CatalogDocument GROUP BY RowKey;

    INSERT #Value(RowKey,FieldCode,Value)
    SELECT delivery.RowKey,field.FieldCode,field.Value FROM (
      SELECT page.RowKey,MIN(delivery.DeliveryDate) DeliveryDate,SUM(delivery.Quantity) Quantity
      FROM #Page page JOIN stock.ItemDeliveryDate delivery ON delivery.NormalizedItemId=page.RowKey
      WHERE delivery.DeliveryDate>=CONVERT(date,SYSUTCDATETIME())
        AND EXISTS(SELECT 1 FROM out.ExportStockSource source WHERE source.OrganizationId=@OrganizationId
          AND source.IsActive=1 AND source.Contribution IN(N''BASE'',N''ADD'') AND source.StockOrganizationId=delivery.OrganizationId)
      GROUP BY page.RowKey
    ) delivery CROSS APPLY(VALUES
      (N''Stock.ErpDeliveryDate'',CONVERT(nvarchar(max),CONVERT(nvarchar(10),delivery.DeliveryDate,104))),
      (N''Stock.ErpIncoming'',CONVERT(nvarchar(max),out.MagentoNumber(delivery.Quantity)))
    ) field(FieldCode,Value);

    /* VAT and currency must follow current prices as well. */
    SELECT page.RowKey,price.VatRate,currency.ExtraCode CurrencyCode,
      ROW_NUMBER() OVER(PARTITION BY page.RowKey ORDER BY
        CASE registry.PriceFieldCode WHEN N''Product.PriceB2B'' THEN 0 ELSE 1 END,
        registry.SortOrder,price.ValidFrom DESC,price.ProductPriceId DESC) PickRank
    INTO #CatalogPriceMetadata
    FROM #Page page JOIN canon.Product product ON product.OrganizationId=@OrganizationId AND product.ItemID=page.RowKey
    JOIN canon.ProductPrice price ON price.ProductId=product.ProductId AND price.IsActive=1 AND price.ValidFrom<=SYSUTCDATETIME()
    JOIN out.ExportPriceList registry ON registry.OrganizationId=@OrganizationId AND registry.PriceListCode=price.PriceList
      AND registry.IsActive=1 AND registry.PriceFieldCode IN(N''Product.PriceB2B'',N''Product.PriceB2C'')
    LEFT JOIN canon.Codebook list ON list.OrganizationId=@OrganizationId AND list.CodebookCode=N''PRICELIST'' AND list.EntryCode=price.PriceList AND list.IsActive=1
    LEFT JOIN canon.Codebook currency ON currency.OrganizationId=@OrganizationId AND currency.CodebookCode=N''CURRENCY'' AND currency.EntryCode=list.ExtraCode AND currency.IsActive=1;
    DELETE value FROM #Value value WHERE value.FieldCode=N''Product.VatRate''
      AND EXISTS(SELECT 1 FROM #CatalogPriceMetadata price WHERE price.RowKey=value.RowKey);
    INSERT #Value(RowKey,FieldCode,Value)
    SELECT price.RowKey,field.FieldCode,field.Value FROM #CatalogPriceMetadata price
    CROSS APPLY(VALUES
      (N''Product.VatRate'',CONVERT(nvarchar(max),out.MagentoNumber(price.VatRate))),
      (N''Product.Currency'',CONVERT(nvarchar(max),price.CurrencyCode))
    ) field(FieldCode,Value) WHERE price.PickRank=1;
  END;
 ';
 SET @definition=REPLACE(@definition,@anchor,@values+@anchor);
 SET @definition=N'ALTER '+SUBSTRING(@definition,CHARINDEX(N'PROCEDURE',@definition),2147483647);
 EXEC sys.sp_executesql @definition;
END;
UPDATE c SET CanonicalFieldCode=m.FieldCode
FROM out.ExportColumn c JOIN out.ExportProfile p ON p.ExportProfileId=c.ExportProfileId
JOIN (VALUES(N'COL031',N'Product.Currency'),(N'COL040',N'Product.MainDocument'),
 (N'COL041',N'Product.DocumentRoles'),(N'COL042',N'Product.OtherDocuments'),
 (N'COL048',N'Stock.ErpDeliveryDate'),(N'COL049',N'Stock.ErpIncoming')) m(ColumnCode,FieldCode) ON m.ColumnCode=c.ColumnCode
WHERE p.ProfileCode=N'MAGENTO_PRODUCTS' AND NULLIF(c.CanonicalFieldCode,N'') IS NULL;

/* Keep the /splet readiness counts consistent with explicit exclusions. */
SET @definition=OBJECT_DEFINITION(OBJECT_ID(N'intranet.GetExportReadiness'));
IF @definition IS NULL THROW 52603,N'GetExportReadiness manjka.',1;
IF @definition NOT LIKE N'%/* CatalogReadiness206 */%'
BEGIN
 DECLARE @old nvarchar(max)=N'HasAllowedSite = CASE WHEN';
 IF CHARINDEX(@old,@definition)=0 THROW 52604,N'Nepricakovana definicija pripravljenosti.',1;
 SET @definition=REPLACE(@definition,@old,@old+N'
        NOT EXISTS(SELECT 1 FROM pim.CatalogPolicy policy WHERE policy.ProductId=product.ProductId AND policy.IsExcluded=1) AND /* CatalogReadiness206 */');
 SET @definition=N'ALTER '+SUBSTRING(@definition,CHARINDEX(N'PROCEDURE',@definition),2147483647);
 EXEC sys.sp_executesql @definition;
END;
