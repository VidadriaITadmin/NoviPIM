/* 315_HitrejsiPredogledIzvoza - naloga #80: predogled /splet/izvoz (intranet.GetWebExportRows ->
   out.GetExportRows, profil MAGENTO_PRODUCTS) je trajal 8-55 s za 200 vrstic.

   Meritev (razvojna baza, 30. 9. 2026, dm_exec_query_stats + dm_os_waiting_tasks):
   - streznik ima "cost threshold for parallelism" = 5 in MAXDOP 10, zato vec majhnih stavkov nad
     zacasnimi tabelami (#UnitValue292 SELECT INTO, osnovni INSERT #Value, #Attribute, #SpecialAll274)
     tece vzporedno z 10 nitmi. Porabijo 0,1-0,5 s CPU, cakajo pa do 46 s (CXPACKET/CXCONSUMER,
     LATCH_EX NESTING_TRANSACTION_FULL), kadar je streznik obremenjen z drugimi poizvedbami;
   - osnovni INSERT #Value je za 200 vrstic trikrat razvrscal VSE cene pim.ProductPrice
     (ROW_NUMBER cez celo tabelo), preden jih je spojil s stranjo;
   - #ValidPath291 je vsakic sestavil vse veljavne poti vseh spletisc (pogled z UNION);
   - stetje (@TotalCount) in izbira strani sta isti filter (vkljucno z iskanjem LIKE po besedilih)
     izvedla dvakrat.

   Popravek (samo PIM_PRODUCT veja in skupni rep; vsebina in vrstni red stolpcev se ne spremenita):
   1. filter izdelkov se izvede enkrat v #Match80 (z zaporedno stevilko po ItemID); stetje in stran
      prideta iz nje. Preverjeno: filter stetja in filter strani sta bila besedilno enaka;
   2. cene za osnovni INSERT #Value se razvrscajo samo za izdelke strani (PARTITION BY PimProductId,
      zato je rezultat enak);
   3. #ValidPath291 vsebuje samo poti, ki jih izdelki strani sploh imajo (uporablja se samo v EXISTS
      z istimi potmi, rezultat enak);
   4. OPTION (MAXDOP 1) na stavkih nad majhnimi zacasnimi tabelami, ki so se izvajali vzporedno.

   Isto proceduro uporablja nocni katalog.csv (@Take = 0); primerjava izhoda pred/po je v
   docs/DATABASE.md (315). Popravek bere zivo definicijo (kot 304/305) in preveri vsa sidra. */
SET XACT_ABORT ON;

DECLARE @d nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows'));
IF @d IS NULL THROW 53150, N'315: out.GetExportRows manjka.', 1;

IF @d NOT LIKE N'%HitrejsiPredogled80%'
BEGIN
  DECLARE @b int = CHARINDEX(N'ELSE IF @ValueSource = N''PIM_PRODUCT''', @d);
  IF @b = 0 THROW 53151, N'315: veja PIM_PRODUCT ni v pricakovani obliki.', 1;

  /* ---- 1) Stetje + stran iz enega filtra ------------------------------------------------ */
  DECLARE @where nvarchar(100) = N'WHERE product.OrganizationId = @OrganizationId';
  DECLARE @offset nvarchar(100) = N'OFFSET @Skip ROWS FETCH NEXT @Fetch ROWS ONLY;';
  DECLARE @c1 int = CHARINDEX(N'SELECT @TotalCount = COUNT(*)', @d, @b);
  DECLARE @cw int = CHARINDEX(@where, @d, @c1);
  DECLARE @ce int = CHARINDEX(N';', @d, @cw);
  DECLARE @p1 int = CHARINDEX(N'INSERT #Page (RowKey, EntityId)', @d, @ce);
  DECLARE @pw int = CHARINDEX(@where, @d, @p1);
  DECLARE @po int = CHARINDEX(N'ORDER BY product.ItemID', @d, @pw);
  DECLARE @pe int = CHARINDEX(@offset, @d, @po);
  IF @c1 = 0 OR @cw = 0 OR @ce = 0 OR @p1 = 0 OR @pw = 0 OR @po = 0 OR @pe = 0
    THROW 53152, N'315: stetje/stran v veji PIM_PRODUCT nista v pricakovani obliki.', 1;

  DECLARE @countHead nvarchar(max) = SUBSTRING(@d, @c1, @cw - @c1);
  DECLARE @gap nvarchar(max) = SUBSTRING(@d, @ce + 1, @p1 - @ce - 1);
  DECLARE @pageHead nvarchar(max) = SUBSTRING(@d, @p1, @pw - @p1);
  DECLARE @countWhere nvarchar(max) = SUBSTRING(@d, @cw, @ce - @cw);
  DECLARE @pageWhere nvarchar(max) = SUBSTRING(@d, @pw, @po - @pw);
  DECLARE @orderPart nvarchar(max) = SUBSTRING(@d, @po, @pe - @po);

  /* primerjava brez presledkov, novih vrstic in tabulatorjev, binarno */
  IF REPLACE(REPLACE(REPLACE(REPLACE(@countHead, N' ', N''), NCHAR(13), N''), NCHAR(10), N''), NCHAR(9), N'') COLLATE Latin1_General_BIN2
       <> N'SELECT@TotalCount=COUNT(*)FROMpim.ProductASproduct'
    OR REPLACE(REPLACE(REPLACE(REPLACE(@gap, N' ', N''), NCHAR(13), N''), NCHAR(10), N''), NCHAR(9), N'') <> N''
    OR REPLACE(REPLACE(REPLACE(REPLACE(@pageHead, N' ', N''), NCHAR(13), N''), NCHAR(10), N''), NCHAR(9), N'') COLLATE Latin1_General_BIN2
       <> N'INSERT#Page(RowKey,EntityId)SELECTproduct.ItemID,product.PimProductIdFROMpim.ProductASproduct'
    OR REPLACE(REPLACE(REPLACE(REPLACE(@orderPart, N' ', N''), NCHAR(13), N''), NCHAR(10), N''), NCHAR(9), N'') COLLATE Latin1_General_BIN2
       <> N'ORDERBYproduct.ItemID'
    THROW 53153, N'315: glava stetja ali strani v veji PIM_PRODUCT se je spremenila.', 1;
  IF REPLACE(REPLACE(REPLACE(REPLACE(@countWhere, N' ', N''), NCHAR(13), N''), NCHAR(10), N''), NCHAR(9), N'') COLLATE Latin1_General_BIN2
     <> REPLACE(REPLACE(REPLACE(REPLACE(@pageWhere, N' ', N''), NCHAR(13), N''), NCHAR(10), N''), NCHAR(9), N'') COLLATE Latin1_General_BIN2
    THROW 53154, N'315: filter stetja in filter strani nista enaka - zdruzitev ne bi bila varna.', 1;
  IF @countWhere NOT LIKE N'%WithdrawalRows251%' OR @countWhere NOT LIKE N'%@SearchLike%'
    THROW 53155, N'315: filter izdelkov nima pricakovanih delov (251, iskanje).', 1;

  DECLARE @newBlock nvarchar(max) =
N'/* HitrejsiPredogled80: filter (strani, odjave 251, iskanje) se izvede enkrat; stetje in stran
       prideta iz #Match80. Vrstni red strani je ROW_NUMBER po product.ItemID - isti kot prej. */
    CREATE TABLE #Match80 (RowNo bigint NOT NULL PRIMARY KEY,
      RowKey nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL, EntityId bigint NOT NULL);
    INSERT #Match80 (RowNo, RowKey, EntityId)
    SELECT ROW_NUMBER() OVER (ORDER BY product.ItemID), product.ItemID, product.PimProductId
    FROM pim.Product AS product
    ' + @countWhere + N';

    SELECT @TotalCount = COUNT(*) FROM #Match80;

    INSERT #Page (RowKey, EntityId)
    SELECT match80.RowKey, match80.EntityId
    FROM #Match80 AS match80
    ORDER BY match80.RowNo
    ' + @offset;

  SET @d = STUFF(@d, @c1, @pe + LEN(@offset) - @c1, @newBlock);

  /* ---- 2..4) Posamezna sidra (vsako mora biti natanko enkrat) ---------------------------- */
  DECLARE @anchor TABLE (No int PRIMARY KEY, Old nvarchar(max), New nvarchar(max));
  INSERT @anchor (No, Old, New) VALUES
   (1, N'AND registry.PriceFieldCode = N''Product.PriceB2B'' AND registry.IsActive = 1',
       N'AND registry.PriceFieldCode = N''Product.PriceB2B'' AND registry.IsActive = 1
          AND price.PimProductId IN (SELECT page80.EntityId FROM #Page AS page80) /* HitrejsiPredogled80 */'),
   (2, N'AND registry.PriceFieldCode = N''Product.PriceB2C'' AND registry.IsActive = 1',
       N'AND registry.PriceFieldCode = N''Product.PriceB2C'' AND registry.IsActive = 1
          AND price.PimProductId IN (SELECT page80.EntityId FROM #Page AS page80) /* HitrejsiPredogled80 */'),
   (3, N'FROM pim.ProductPrice WHERE IsActive = 1 AND ValidFrom <= SYSUTCDATETIME()',
       N'FROM pim.ProductPrice WHERE IsActive = 1 AND ValidFrom <= SYSUTCDATETIME()
          AND PimProductId IN (SELECT page80.EntityId FROM #Page AS page80) /* HitrejsiPredogled80 */'),
   (4, N'WHERE EXISTS (SELECT 1 FROM #Page AS page274 WHERE page274.EntityId = special.PimProductId);',
       N'WHERE EXISTS (SELECT 1 FROM #Page AS page274 WHERE page274.EntityId = special.PimProductId)
    OPTION (MAXDOP 1) /* HitrejsiPredogled80 */;'),
   (5, N'AND filter.AttributeName = attribute.AttributeCode);',
       N'AND filter.AttributeName = attribute.AttributeCode)
    OPTION (MAXDOP 1) /* HitrejsiPredogled80 */;'),
   (6, N'AND NULLIF(unitValue.Value, N'''') IS NOT NULL;',
       N'AND NULLIF(unitValue.Value, N'''') IS NOT NULL
    OPTION (MAXDOP 1) /* HitrejsiPredogled80 */;'),
   (7, N'SELECT DISTINCT WebSiteCode, CategoryPath FROM canon.WebSiteCategoryPath;',
       N'SELECT DISTINCT valid80.WebSiteCode, valid80.CategoryPath
    FROM canon.WebSiteCategoryPath AS valid80
    /* HitrejsiPredogled80: samo poti, ki jih izdelki strani imajo (#ValidPath291 se bere samo z njimi). */
    WHERE EXISTS (SELECT 1 FROM #Page AS page80
                  INNER JOIN pim.ProductCategory AS category80 ON category80.PimProductId = page80.EntityId
                  WHERE category80.WebSite = valid80.WebSiteCode AND category80.CategoryPath = valid80.CategoryPath);'),
   (8, N'INNER JOIN b2b.CustomerGroupDiscounts(CONVERT(date, SYSUTCDATETIME())) AS effective ON effective.CustomerId = page.EntityId;',
       N'INNER JOIN b2b.CustomerGroupDiscounts(CONVERT(date, SYSUTCDATETIME())) AS effective ON effective.CustomerId = page.EntityId
    OPTION (MAXDOP 1) /* HitrejsiPredogled80 */;');

  DECLARE @no int = 0, @old nvarchar(max), @new nvarchar(max), @count int, @msg nvarchar(200);
  WHILE 1 = 1
  BEGIN
    SELECT TOP (1) @no = No, @old = Old, @new = New FROM @anchor WHERE No > @no ORDER BY No;
    IF @@ROWCOUNT = 0 BREAK;
    SET @count = (LEN(@d) - LEN(REPLACE(@d, @old, N''))) / LEN(@old);
    IF @count <> 1
    BEGIN
      SET @msg = CONCAT(N'315: sidro ', @no, N' je v GetExportRows ', @count, N'-krat (pricakovano 1).');
      THROW 53156, @msg, 1;
    END;
    SET @d = REPLACE(@d, @old, @new);
  END;

  /* ---- 5) Osnovni INSERT #Value (B1) brez vzporednosti ------------------------------------ */
  DECLARE @vat nvarchar(200) = N'(N''Product.VatRate'', CONVERT(nvarchar(max), out.MagentoNumber(core.VatRate)))';
  DECLARE @fieldEnd nvarchar(100) = N'WHERE field.Value IS NOT NULL;';
  DECLARE @v1 int = CHARINDEX(@vat, @d);
  DECLARE @v2 int = CASE WHEN @v1 > 0 THEN CHARINDEX(@fieldEnd, @d, @v1) ELSE 0 END;
  IF @v1 = 0 OR @v2 = 0 OR CHARINDEX(@vat, @d, @v1 + 1) > 0
    OR REPLACE(REPLACE(REPLACE(REPLACE(SUBSTRING(@d, @v1 + LEN(@vat), @v2 - @v1 - LEN(@vat)), N' ', N''), NCHAR(13), N''), NCHAR(10), N''), NCHAR(9), N'')
       COLLATE Latin1_General_BIN2 <> N')ASfield(FieldCode,Value)'
    THROW 53157, N'315: osnovni INSERT #Value (B1) ni v pricakovani obliki.', 1;
  SET @d = STUFF(@d, @v2, LEN(@fieldEnd), N'WHERE field.Value IS NOT NULL
    OPTION (MAXDOP 1) /* HitrejsiPredogled80 */;');

  SET @d = N'ALTER ' + SUBSTRING(@d, CHARINDEX(N'PROCEDURE', @d), 2147483647);
  EXEC sys.sp_executesql @d;
END;

DECLARE @after nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows'));
IF @after NOT LIKE N'%#Match80%'
  OR (LEN(@after) - LEN(REPLACE(@after, N'HitrejsiPredogled80', N''))) / LEN(N'HitrejsiPredogled80') < 10
  THROW 53158, N'315: popravek ni v out.GetExportRows.', 1;
