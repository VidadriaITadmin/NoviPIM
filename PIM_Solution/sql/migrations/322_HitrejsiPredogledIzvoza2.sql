/* 322_HitrejsiPredogledIzvoza2 - naloga #114 (nadaljevanje #80 / 315): preostali stroski predogleda
   /splet/izvoz v out.GetExportRows (veja PIM_PRODUCT).

   Meritev pred popravkom (razvojna baza, 30. 9. 2026, org 2, MAGENTO_PRODUCTS, 200 vrstic,
   dm_exec_query_stats, zadnja izvedba):
   - INSERT #ValidPath291 ~290-370 ms, ~48.000 branj: pogled canon.WebSiteCategoryPath sestavi vse
     prevedene poti vseh dreves in jezikov z rekurzivnim pogledom canon.CategoryPathTranslated, ki v
     vsakem koraku rekurzije znova racuna imena (Category x jeziki x prevodi); predikata strani vanj
     ni mogoce potisniti;
   - stirje stavki zaloge (#Stock, Stock.Warehouse in dvakrat out.CatalogStock za
     Product.ClearancePercent / Clearance.Quantity) ~40-135 ms in ~38.000-100.000 branj VSAK:
     vsak bere vse pozicije aktivnih posnetkov (stock.Position) in sele nato stakne s stranjo.

   Popravek (izhod - vrstice, stolpci, vrednosti - se ne spremeni):
   1. #ValidPath291: namesto pogleda se imena kategorij (samo drevesa in jeziki, ki jih imajo poti
      izdelkov strani) preberejo ENKRAT v #CatName114, pot se sestavi rekurzivno nad zacasno tabelo.
      Logika je prepis canon.CategoryPathTranslated + canon.WebSiteCategoryPath (291): imena z
      jezikovno zamenjavo ISNULL(prevod, slovensko), CONVERT na nvarchar(400)/(1000), samo aktivne
      kategorije in spletisca, jeziki iz canon.CategoryTranslation, plus neprevedena pot
      canon.Category za slovenska spletisca. #ValidPath291 se bere samo v EXISTS z enakostjo
      (WebSite, CategoryPath), zato je rezultat enak. ZATO: ce se kdaj spremeni pogled
      canon.CategoryPathTranslated ali canon.WebSiteCategoryPath, je treba enako spremeniti tudi ta
      del (oznaka HitrejsiPredogled114 v out.GetExportRows).
   2. Zaloga: pozicije se preberejo ENKRAT v #StockPos114, od strani navzdol (sifra strani ->
      canon.Product.ItemID (vsa podjetja, kot prej) -> stock.Position.MatchedProductId prek
      IX_stock_Position_MatchedProduct -> aktiven posnetek -> vir -> register izvoza podjetja).
      #Stock, Stock.Warehouse in #CatalogStock114 (namesto pogleda out.CatalogStock, isti izrazi
      OwnAvailable in OwnSnapshotUtc) se napolnijo iz nje.

   Brez spremembe sheme. Ne dotika se veje CANON in PIM_CUSTOMER. Isto proceduro uporablja nocni
   katalog.csv (@Take = 0); primerjava izhoda pred/po je v docs/DATABASE.md (322).
   Popravek bere zivo definicijo (kot 315) in preveri vsa sidra; ce jih ne najde, se ustavi. */
SET XACT_ABORT ON;

DECLARE @d nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows'));
IF @d IS NULL THROW 53220, N'322: out.GetExportRows manjka.', 1;

IF @d NOT LIKE N'%HitrejsiPredogled114%'
BEGIN
  IF @d NOT LIKE N'%HitrejsiPredogled80%'
    THROW 53221, N'322: najprej mora biti uveljavljena 315 (HitrejsiPredogled80).', 1;

  DECLARE @s int, @e int, @cut nvarchar(max), @expect nvarchar(max), @msg nvarchar(300);

  /* ---- 1) #ValidPath291 brez rekurzivnega pogleda --------------------------------------- */
  DECLARE @vpStart nvarchar(100) = N'INSERT #ValidPath291 (WebSite, CategoryPath)';
  DECLARE @vpEnd nvarchar(200) = N'category80.CategoryPath = valid80.CategoryPath);';
  SET @s = CHARINDEX(@vpStart, @d);
  SET @e = CASE WHEN @s > 0 THEN CHARINDEX(@vpEnd, @d, @s) ELSE 0 END;
  IF @s = 0 OR @e = 0 OR CHARINDEX(@vpStart, @d, @s + 1) > 0
    THROW 53222, N'322: INSERT #ValidPath291 ni v pricakovani obliki.', 1;
  SET @cut = SUBSTRING(@d, @s, @e + LEN(@vpEnd) - @s);
  /* primerjava brez presledkov, novih vrstic in tabulatorjev; komentar 315 izpustimo */
  SET @cut = STUFF(@cut, CHARINDEX(N'/*', @cut), CHARINDEX(N'*/', @cut) - CHARINDEX(N'/*', @cut) + 2, N'');
  SET @expect = N'INSERT#ValidPath291(WebSite,CategoryPath)SELECTDISTINCTvalid80.WebSiteCode,valid80.CategoryPath'
    + N'FROMcanon.WebSiteCategoryPathASvalid80WHEREEXISTS(SELECT1FROM#PageASpage80'
    + N'INNERJOINpim.ProductCategoryAScategory80ONcategory80.PimProductId=page80.EntityId'
    + N'WHEREcategory80.WebSite=valid80.WebSiteCodeANDcategory80.CategoryPath=valid80.CategoryPath);';
  IF REPLACE(REPLACE(REPLACE(REPLACE(@cut, N' ', N''), NCHAR(13), N''), NCHAR(10), N''), NCHAR(9), N'') COLLATE Latin1_General_BIN2
     <> @expect COLLATE Latin1_General_BIN2
    THROW 53223, N'322: INSERT #ValidPath291 se je spremenil - popravek ni varen.', 1;

  DECLARE @newValidPath nvarchar(max) =
N'/* HitrejsiPredogled114: veljavne poti brez rekurzivnega pogleda canon.WebSiteCategoryPath.
       Enaka logika kot canon.CategoryPathTranslated + canon.WebSiteCategoryPath (291), samo za
       drevesa in jezike poti izdelkov strani. Ob spremembi teh pogledov spremeni tudi to. */
    CREATE TABLE #PagePath114
      (WebSite nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
       CategoryPath nvarchar(2000) COLLATE DATABASE_DEFAULT NOT NULL,
       CategoryTreeCode nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL,
       LanguageCode nvarchar(20) COLLATE DATABASE_DEFAULT NOT NULL);
    INSERT #PagePath114 (WebSite, CategoryPath, CategoryTreeCode, LanguageCode)
    SELECT DISTINCT category114.WebSite, category114.CategoryPath, site114.CategoryTreeCode, site114.LanguageCode
    FROM #Page AS page114
    INNER JOIN pim.ProductCategory AS category114 ON category114.PimProductId = page114.EntityId
    INNER JOIN canon.WebSite AS site114 ON site114.WebSiteCode = category114.WebSite AND site114.IsActive = 1
    OPTION (MAXDOP 1);

    CREATE TABLE #CatName114
      (CategoryTreeCode nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL,
       CategoryCode nvarchar(400) COLLATE DATABASE_DEFAULT NOT NULL,
       ParentCategoryCode nvarchar(400) COLLATE DATABASE_DEFAULT NULL,
       LanguageCode nvarchar(20) COLLATE DATABASE_DEFAULT NOT NULL,
       CategoryName nvarchar(400) COLLATE DATABASE_DEFAULT NULL);
    INSERT #CatName114 (CategoryTreeCode, CategoryCode, ParentCategoryCode, LanguageCode, CategoryName)
    SELECT category114.CategoryTreeCode, category114.CategoryCode, category114.ParentCategoryCode,
      jezik114.LanguageCode,
      CONVERT(nvarchar(400), ISNULL(prevod114.CategoryName, category114.CategoryName))
    FROM canon.Category AS category114
    CROSS JOIN (SELECT DISTINCT LanguageCode FROM canon.CategoryTranslation) AS jezik114
    LEFT JOIN canon.CategoryTranslation AS prevod114
      ON prevod114.CategoryTreeCode = category114.CategoryTreeCode AND prevod114.CategoryCode = category114.CategoryCode
        AND prevod114.LanguageCode = jezik114.LanguageCode
    WHERE category114.IsActive = 1
      AND EXISTS (SELECT 1 FROM #PagePath114 AS need114
                  WHERE need114.CategoryTreeCode = category114.CategoryTreeCode AND need114.LanguageCode = jezik114.LanguageCode)
    OPTION (MAXDOP 1);
    CREATE CLUSTERED INDEX IX_CatName114 ON #CatName114 (CategoryTreeCode, LanguageCode, ParentCategoryCode);

    CREATE TABLE #TransPath114
      (CategoryTreeCode nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL,
       LanguageCode nvarchar(20) COLLATE DATABASE_DEFAULT NOT NULL,
       CategoryPath nvarchar(1000) COLLATE DATABASE_DEFAULT NULL);
    WITH veriga114 AS
    (
      SELECT ime.CategoryTreeCode, ime.CategoryCode, ime.LanguageCode,
        CONVERT(nvarchar(1000), ime.CategoryName) AS CategoryPath
      FROM #CatName114 AS ime
      WHERE ime.ParentCategoryCode IS NULL
      UNION ALL
      SELECT ime.CategoryTreeCode, ime.CategoryCode, ime.LanguageCode,
        CONVERT(nvarchar(1000), starsi.CategoryPath + N'' > '' + ime.CategoryName)
      FROM #CatName114 AS ime
      INNER JOIN veriga114 AS starsi
        ON starsi.CategoryTreeCode = ime.CategoryTreeCode AND starsi.CategoryCode = ime.ParentCategoryCode
          AND starsi.LanguageCode = ime.LanguageCode
    )
    INSERT #TransPath114 (CategoryTreeCode, LanguageCode, CategoryPath)
    SELECT CategoryTreeCode, LanguageCode, CategoryPath FROM veriga114
    OPTION (MAXDOP 1);

    INSERT #ValidPath291 (WebSite, CategoryPath)
    SELECT DISTINCT need114.WebSite, need114.CategoryPath
    FROM #PagePath114 AS need114
    WHERE EXISTS (SELECT 1 FROM #TransPath114 AS path114
                  WHERE path114.CategoryTreeCode = need114.CategoryTreeCode AND path114.LanguageCode = need114.LanguageCode
                    AND path114.CategoryPath = need114.CategoryPath)
       OR (need114.LanguageCode = N''sl'' AND EXISTS (SELECT 1 FROM canon.Category AS raw114
                  WHERE raw114.CategoryTreeCode = need114.CategoryTreeCode AND raw114.IsActive = 1
                    AND raw114.CategoryPath = need114.CategoryPath))
    OPTION (MAXDOP 1);';

  SET @d = STUFF(@d, @s, @e + LEN(@vpEnd) - @s, @newValidPath);

  /* ---- 2) Zaloga: #StockPos114 enkrat, od strani navzdol ------------------------------ */
  DECLARE @stockTable nvarchar(100) = N'CREATE TABLE #Stock';
  SET @s = CHARINDEX(@stockTable, @d);
  IF @s = 0 OR CHARINDEX(@stockTable, @d, @s + 1) > 0
    THROW 53224, N'322: CREATE TABLE #Stock ni v pricakovani obliki.', 1;
  DECLARE @stockPos nvarchar(max) =
N'/* HitrejsiPredogled114: pozicije zaloge izdelkov strani se preberejo enkrat, od strani navzdol
       (sifra -> canon.Product vseh podjetij -> stock.Position.MatchedProductId). Iz #StockPos114 se
       polnijo #Stock, Stock.Warehouse in #CatalogStock114 (namesto pogleda out.CatalogStock). */
    CREATE TABLE #StockProduct114
      (RowKey nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL, ProductId bigint NOT NULL,
       PRIMARY KEY (ProductId, RowKey));
    INSERT #StockProduct114 (RowKey, ProductId)
    SELECT page114.RowKey, stockProduct114.ProductId
    FROM #Page AS page114
    INNER JOIN canon.Product AS stockProduct114 ON stockProduct114.ItemID = page114.RowKey
    OPTION (MAXDOP 1);

    SELECT product114.RowKey, registry114.Contribution, registry114.WarehouseLabel, registry114.SortOrder,
      snapshot114.SnapshotUtc,
      position114.Quantity, position114.AvailableQuantity, position114.OrderedQuantity,
      position114.ForShipmentQuantity, position114.SupplierOrderedQuantity,
      position114.IncomingQuantity, position114.AvailabilityDate
    INTO #StockPos114
    FROM #StockProduct114 AS product114
    INNER JOIN stock.Position AS position114 ON position114.MatchedProductId = product114.ProductId
    INNER JOIN stock.Snapshot AS snapshot114
      ON snapshot114.SnapshotId = position114.SnapshotId AND snapshot114.IsActive = 1
    INNER JOIN map.SourceConnector AS connector114 ON connector114.SourceConnectorId = snapshot114.SourceConnectorId
    INNER JOIN out.ExportStockSource AS registry114
      ON registry114.StockOrganizationId = connector114.OrganizationId AND registry114.SourceCode = connector114.SourceCode
    WHERE registry114.OrganizationId = @OrganizationId AND registry114.IsActive = 1
    OPTION (MAXDOP 1);

    /* Enako kot out.CatalogStock (Sources + GROUP BY), samo za sifre strani tega podjetja. */
    SELECT ItemID = stock114.RowKey,
      OwnAvailable = SUM(CASE WHEN stock114.Contribution IN (N''BASE'', N''ADD'') THEN COALESCE(stock114.AvailableQuantity, stock114.Quantity) ELSE 0 END),
      OwnSnapshotUtc = MIN(CASE WHEN stock114.Contribution IN (N''BASE'', N''ADD'') THEN stock114.SnapshotUtc END)
    INTO #CatalogStock114
    FROM #StockPos114 AS stock114
    GROUP BY stock114.RowKey;

    ';
  SET @d = STUFF(@d, @s, 0, @stockPos);

  /* #Stock iz #StockPos114 */
  DECLARE @stInsert nvarchar(200) = N'INSERT #Stock (RowKey, Contribution, Quantity, Available, Ordered, ForShipment, SupplierOrdered, Incoming, AvailabilityDate)';
  DECLARE @stEnd nvarchar(200) = N'WHERE registry.OrganizationId = @OrganizationId AND registry.IsActive = 1;';
  SET @s = CHARINDEX(@stInsert, @d);
  SET @e = CASE WHEN @s > 0 THEN CHARINDEX(@stEnd, @d, @s) ELSE 0 END;
  IF @s = 0 OR @e = 0 OR CHARINDEX(@stInsert, @d, @s + 1) > 0
    THROW 53225, N'322: INSERT #Stock ni v pricakovani obliki.', 1;
  SET @cut = SUBSTRING(@d, @s, @e + LEN(@stEnd) - @s);
  SET @expect = N'INSERT#Stock(RowKey,Contribution,Quantity,Available,Ordered,ForShipment,SupplierOrdered,Incoming,AvailabilityDate)'
    + N'SELECTpage.RowKey,registry.Contribution,position.Quantity,COALESCE(position.AvailableQuantity,position.Quantity),'
    + N'position.OrderedQuantity,position.ForShipmentQuantity,position.SupplierOrderedQuantity,'
    + N'position.IncomingQuantity,position.AvailabilityDate'
    + N'FROMout.ExportStockSourceASregistry'
    + N'INNERJOINmap.SourceConnectorASconnectorONconnector.OrganizationId=registry.StockOrganizationIdANDconnector.SourceCode=registry.SourceCode'
    + N'INNERJOINstock.SnapshotASsnapshotONsnapshot.SourceConnectorId=connector.SourceConnectorIdANDsnapshot.IsActive=1'
    + N'INNERJOINstock.PositionASpositionONposition.SnapshotId=snapshot.SnapshotId'
    + N'INNERJOINcanon.ProductASstockProductONstockProduct.ProductId=position.MatchedProductId'
    + N'INNERJOIN#PageASpageONpage.RowKey=stockProduct.ItemID'
    + N'WHEREregistry.OrganizationId=@OrganizationIdANDregistry.IsActive=1;';
  IF REPLACE(REPLACE(REPLACE(REPLACE(@cut, N' ', N''), NCHAR(13), N''), NCHAR(10), N''), NCHAR(9), N'') COLLATE Latin1_General_BIN2
     <> @expect COLLATE Latin1_General_BIN2
    THROW 53226, N'322: INSERT #Stock se je spremenil - popravek ni varen.', 1;
  SET @d = STUFF(@d, @s, @e + LEN(@stEnd) - @s,
N'INSERT #Stock (RowKey, Contribution, Quantity, Available, Ordered, ForShipment, SupplierOrdered, Incoming, AvailabilityDate)
    SELECT stock114.RowKey, stock114.Contribution,
      stock114.Quantity,
      COALESCE(stock114.AvailableQuantity, stock114.Quantity),
      stock114.OrderedQuantity, stock114.ForShipmentQuantity, stock114.SupplierOrderedQuantity,
      stock114.IncomingQuantity, stock114.AvailabilityDate
    FROM #StockPos114 AS stock114 /* HitrejsiPredogled114 */;');

  /* Stock.Warehouse iz #StockPos114 */
  DECLARE @whStart nvarchar(200) = N'SELECT DISTINCT page.RowKey, registry.WarehouseLabel, registry.SortOrder';
  DECLARE @whEnd nvarchar(200) = N'AND NULLIF(registry.WarehouseLabel, N'''') IS NOT NULL';
  SET @s = CHARINDEX(@whStart, @d);
  SET @e = CASE WHEN @s > 0 THEN CHARINDEX(@whEnd, @d, @s) ELSE 0 END;
  IF @s = 0 OR @e = 0 OR CHARINDEX(@whStart, @d, @s + 1) > 0
    THROW 53227, N'322: stavek Stock.Warehouse ni v pricakovani obliki.', 1;
  SET @cut = SUBSTRING(@d, @s, @e + LEN(@whEnd) - @s);
  SET @expect = N'SELECTDISTINCTpage.RowKey,registry.WarehouseLabel,registry.SortOrder'
    + N'FROMout.ExportStockSourceASregistry'
    + N'INNERJOINmap.SourceConnectorASconnectorONconnector.OrganizationId=registry.StockOrganizationIdANDconnector.SourceCode=registry.SourceCode'
    + N'INNERJOINstock.SnapshotASsnapshotONsnapshot.SourceConnectorId=connector.SourceConnectorIdANDsnapshot.IsActive=1'
    + N'INNERJOINstock.PositionASpositionONposition.SnapshotId=snapshot.SnapshotId'
    + N'INNERJOINcanon.ProductASstockProductONstockProduct.ProductId=position.MatchedProductId'
    + N'INNERJOIN#PageASpageONpage.RowKey=stockProduct.ItemID'
    + N'WHEREregistry.OrganizationId=@OrganizationIdANDregistry.IsActive=1'
    + N'ANDregistry.ContributionIN(N''BASE'',N''ADD'')ANDNULLIF(registry.WarehouseLabel,N'''')ISNOTNULL';
  IF REPLACE(REPLACE(REPLACE(REPLACE(@cut, N' ', N''), NCHAR(13), N''), NCHAR(10), N''), NCHAR(9), N'') COLLATE Latin1_General_BIN2
     <> @expect COLLATE Latin1_General_BIN2
    THROW 53228, N'322: stavek Stock.Warehouse se je spremenil - popravek ni varen.', 1;
  SET @d = STUFF(@d, @s, @e + LEN(@whEnd) - @s,
N'SELECT DISTINCT stock114.RowKey, stock114.WarehouseLabel, stock114.SortOrder
      FROM #StockPos114 AS stock114 /* HitrejsiPredogled114 */
      WHERE stock114.Contribution IN (N''BASE'', N''ADD'') AND NULLIF(stock114.WarehouseLabel, N'''') IS NOT NULL');

  /* out.CatalogStock -> #CatalogStock114 (natanko dvakrat: 204 ClearancePercent, 207 Clearance.Quantity) */
  DECLARE @oldCs nvarchar(300) = N'LEFT JOIN out.CatalogStock stock ON stock.OrganizationId=product.OrganizationId AND stock.ItemID=product.ItemID';
  DECLARE @count int = (LEN(@d) - LEN(REPLACE(@d, @oldCs, N''))) / LEN(@oldCs);
  IF @count <> 2
  BEGIN
    SET @msg = CONCAT(N'322: out.CatalogStock je v GetExportRows ', @count, N'-krat (pricakovano 2).');
    THROW 53229, @msg, 1;
  END;
  IF CHARINDEX(N'product.OrganizationId=@OrganizationId AND product.ItemID=page.RowKey', @d) = 0
    THROW 53230, N'322: stik canon.Product ob out.CatalogStock ni v pricakovani obliki.', 1;
  SET @d = REPLACE(@d, @oldCs,
    N'LEFT JOIN #CatalogStock114 stock ON stock.ItemID=product.ItemID /* HitrejsiPredogled114 */');

  SET @d = N'ALTER ' + SUBSTRING(@d, CHARINDEX(N'PROCEDURE', @d), 2147483647);
  EXEC sys.sp_executesql @d;
END;

DECLARE @after nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows'));
IF @after NOT LIKE N'%#StockPos114%' OR @after NOT LIKE N'%#CatName114%' OR @after LIKE N'%JOIN out.CatalogStock%'
  OR @after LIKE N'%canon.WebSiteCategoryPath AS valid80%'
  THROW 53231, N'322: popravek ni v out.GetExportRows.', 1;
