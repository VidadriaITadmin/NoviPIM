/* 234: katalog.csv dobi "Odprodaja" (232), "Odprodaja - popust %", "Odprodaja - kolicina" in
   "Razstavni eksponat" (233). Uporabnik 2026-09-18: cena se ne izvaza in ne spreminja; izvozita se
   samo kolicina, popust % in dve zastavici (DA/NE). Namerno LOCENO od Product.ClearancePercent/
   Clearance.Quantity (204/207), ki je oddelcni popust za Magento po department X/O - ta stolpca
   ostaneta nedotaknjena, nova polja uporabljajo svoja imena (ClearanceItem.*, ProductFlag.*).

   Kolicina je danes pim.ClearanceItem.Kolicina (iz uvozene datoteke). Zivi vir iz skladisca
   ODPRODAJA (nacrtovan kot naslednji korak, zahteva majhno spremembo kode v PIM.SaopStockWorker,
   ker ta danes bere en profil na podjetje - glej pogovor 2026-09-18) bo kasneje dodan kot dodaten
   LEFT JOIN pred to isto CROSS APPLY, brez spremembe imen izvozenih polj. */
SET XACT_ABORT ON;

DECLARE @definition nvarchar(max)=OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows'));
IF @definition IS NULL THROW 52801,N'234: GetExportRows manjka.',1;
IF @definition NOT LIKE N'%/* OdprodajaExport234 */%'
BEGIN
  DECLARE @anchor nvarchar(max)=N'CREATE CLUSTERED INDEX IX_Value ON #Value (RowKey);';
  IF CHARINDEX(@anchor,@definition)=0 THROW 52802,N'234: nepricakovana definicija izvoznih vrednosti.',1;
  DECLARE @values nvarchar(max)=N'
  IF @ValueSource=N''PIM_PRODUCT'' BEGIN
    /* OdprodajaExport234: samostojen sistem "Odprodaja"/"Razstavni eksponat" (232/233), loceno od
       Product.ClearancePercent/Clearance.Quantity (204/207). */
    INSERT #Value(RowKey,FieldCode,Value)
    SELECT page.RowKey,field.FieldCode,field.Value
    FROM #Page page
    JOIN canon.Product product ON product.OrganizationId=@OrganizationId AND product.ItemID=page.RowKey
    LEFT JOIN (
      SELECT *,ROW_NUMBER() OVER(PARTITION BY ProductId ORDER BY ImportiranoUtc DESC) AS Rn
      FROM pim.ClearanceItem WHERE IsActive=1
    ) ci ON ci.ProductId=product.ProductId AND ci.Rn=1
    LEFT JOIN pim.ProductFlag flag ON flag.ProductId=product.ProductId AND flag.FlagCode=N''RAZSTAVNI_EKSPONAT''
    CROSS APPLY(VALUES
      (N''ClearanceItem.IsActive'',CASE WHEN ci.ProductId IS NOT NULL AND ISNULL(ci.Kolicina,0)>0 THEN N''DA'' ELSE N''NE'' END),
      (N''ClearanceItem.DiscountPercent'',CASE WHEN ci.ProductId IS NOT NULL AND ISNULL(ci.Kolicina,0)>0 THEN out.MagentoNumber(ISNULL(ci.PopustOdstotek,0)) ELSE N''0'' END),
      (N''ClearanceItem.Quantity'',out.MagentoNumber(CASE WHEN ci.ProductId IS NOT NULL THEN ISNULL(ci.Kolicina,0) ELSE 0 END)),
      (N''ProductFlag.RazstavniEksponat'',CASE WHEN flag.IsSet=1 THEN N''DA'' ELSE N''NE'' END)
    ) field(FieldCode,Value);
  END;
  ';
  SET @definition=REPLACE(@definition,@anchor,@values+@anchor);
  SET @definition=N'ALTER '+SUBSTRING(@definition,CHARINDEX(N'PROCEDURE',@definition),2147483647);
  EXEC sys.sp_executesql @definition;
END;

INSERT out.ExportColumn(ExportProfileId,ColumnCode,OutputColumnName,CanonicalFieldCode,SortOrder,IsRequired,IsActive)
SELECT p.ExportProfileId,m.Code,m.Label,m.FieldCode,ISNULL(lastColumn.LastOrder,0)+m.Ordinal,0,1
FROM out.ExportProfile p
CROSS APPLY(SELECT MAX(SortOrder) LastOrder FROM out.ExportColumn WHERE ExportProfileId=p.ExportProfileId) lastColumn
CROSS JOIN(VALUES(N'CLEARANCE_ACTIVE',N'Odprodaja',N'ClearanceItem.IsActive',1),
                 (N'CLEARANCE_DISCOUNT',N'Odprodaja - popust %',N'ClearanceItem.DiscountPercent',2),
                 (N'CLEARANCE_STOCK',N'Odprodaja - količina',N'ClearanceItem.Quantity',3),
                 (N'SHOWCASE_FLAG',N'Razstavni eksponat',N'ProductFlag.RazstavniEksponat',4)) m(Code,Label,FieldCode,Ordinal)
WHERE p.ProfileCode=N'MAGENTO_PRODUCTS'
AND NOT EXISTS(SELECT 1 FROM out.ExportColumn c WHERE c.ExportProfileId=p.ExportProfileId AND c.ColumnCode=m.Code);

IF EXISTS(SELECT 1 FROM out.ExportColumn c JOIN out.ExportProfile p ON p.ExportProfileId=c.ExportProfileId
  WHERE p.ProfileCode IN(N'MAGENTO_PRODUCTS',N'MAGENTO_STOCK_PRICES') AND c.IsActive=1
  GROUP BY p.ExportProfileId,c.OutputColumnName HAVING COUNT(*)>1)
  THROW 52803,N'234: izvoz ima podvojene glave stolpcev.',1;
IF NOT EXISTS(SELECT 1 FROM out.ExportColumn c JOIN out.ExportProfile p ON p.ExportProfileId=c.ExportProfileId
  WHERE p.ProfileCode=N'MAGENTO_PRODUCTS' AND c.IsActive=1 AND c.ColumnCode IN(N'CLEARANCE_ACTIVE',N'CLEARANCE_DISCOUNT',N'CLEARANCE_STOCK',N'SHOWCASE_FLAG')
  GROUP BY p.ProfileCode HAVING COUNT(*)=4)
  THROW 52804,N'234: manjkajo stolpci odprodaje/eksponata.',1;
