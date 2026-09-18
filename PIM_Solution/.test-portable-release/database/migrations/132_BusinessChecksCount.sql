/*
  132 — števec preverb sešteje iste vrstice, kot jih vrne seznam.

  Napaka v migraciji 131: seznam in števec sta bila dva ločena izraza. Seznam je pokrival vseh
  sedem cenovnih in vse štiri zalogovne preverbe, števec pa samo dve oziroma tri. Stran bi zato
  obljubljala drugačno število, kot ga pokaže — najhuje pri filtru, ki ga števec sploh ni poznal
  (npr. FAKTOR_MARZE je vrnil vrstice in števec 0).

  Popravek: preverbe se zberejo enkrat v začasno tabelo, seznam in števec pa bereta iz nje.
  Dva izraza, ki morata dati isto množico, se slej ko prej razideta; en izraz se ne more.

  Migracija 131 ostane nedotaknjena (AGENTS.md §5.7: migracije so samo dodajanje). Obe
  proceduri samo bereta. Migracija je ponovljiva: CREATE OR ALTER.
*/

SET XACT_ABORT ON;

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetPriceChecks
  @OrganizationId int,
  @ProductId bigint = NULL,
  @CheckCode nvarchar(60) = NULL,
  @Context nvarchar(100) = NULL,
  @Search nvarchar(200) = NULL,
  @Skip int = 0,
  @Take int = 50
AS
BEGIN
  SET NOCOUNT ON;

  SET @Skip = CASE WHEN @Skip < 0 THEN 0 ELSE @Skip END;
  SET @Take = CASE WHEN @Take < 1 THEN 50 WHEN @Take > 2000 THEN 2000 ELSE @Take END;
  SET @CheckCode = NULLIF(UPPER(LTRIM(RTRIM(@CheckCode))), N'''');
  SET @Context = NULLIF(LTRIM(RTRIM(@Context)), N'''');
  SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'''');

  /* Prag faktorja je privzet in na enem mestu; nastavljivega praga v bazi se ni. */
  DECLARE @MarginThreshold decimal(18,4) = 2.0;
  DECLARE @Like nvarchar(210) = CASE WHEN @Search IS NULL THEN NULL ELSE N''%'' + @Search + N''%'' END;

  /* Aktivni izdelki tega podjetja z nazivom; ozek nabor, na katerem se racunajo vse preverbe. */
  DECLARE @Scope TABLE (ProductId bigint PRIMARY KEY, ItemID nvarchar(200), Name nvarchar(1000));
  INSERT @Scope (ProductId, ItemID, Name)
  SELECT product.ProductId, product.ItemID, COALESCE(title.Value, product.ItemID)
  FROM canon.Product AS product
  OUTER APPLY
  (
    SELECT TOP (1) textValue.Value
    FROM canon.ProductText AS textValue
    WHERE textValue.ProductId = product.ProductId AND textValue.TextType IN (N''WEB_TITLE'', N''TITLE_ERP'')
    ORDER BY CASE WHEN textValue.TextType = N''WEB_TITLE'' THEN 0 ELSE 1 END,
      CASE WHEN textValue.Lang = N''sl'' THEN 0 ELSE 1 END, textValue.Lang
  ) AS title
  WHERE product.OrganizationId = @OrganizationId AND product.IsActive = 1
    AND (@ProductId IS NULL OR product.ProductId = @ProductId)
    AND (@Like IS NULL OR product.ItemID LIKE @Like OR product.EAN LIKE @Like OR title.Value LIKE @Like);

  ;WITH activePrice AS
  (
    SELECT price.ProductId, price.PriceList, price.Net, price.VatRate, price.ValidFrom,
      Duplicates = COUNT(*) OVER (PARTITION BY price.ProductId, price.PriceList),
      Ordinal = ROW_NUMBER() OVER (PARTITION BY price.ProductId, price.PriceList ORDER BY price.ValidFrom DESC)
    FROM canon.ProductPrice AS price
    INNER JOIN @Scope AS scopeValue ON scopeValue.ProductId = price.ProductId
    WHERE price.IsActive = 1
  ),
  purchase AS
  (
    SELECT ProductId, PurchaseNet = MIN(Net)
    FROM activePrice WHERE PriceList = N''NAB'' AND Net > 0
    GROUP BY ProductId
  ),
  checks AS
  (
    /* Manjka aktivna cena v obveznem ceniku. */
    SELECT scopeValue.ProductId, CheckCode = required.CheckCode, Context = required.PriceList,
      Detail = N''Izdelek nima aktivne cene v ceniku '' + required.PriceList + N''.'',
      SalesPrice = CONVERT(decimal(18,4), NULL), PurchasePrice = CONVERT(decimal(18,4), NULL),
      MarginFactor = CONVERT(decimal(18,4), NULL), UnitBasis = CONVERT(nvarchar(40), NULL),
      ObservedUtc = CONVERT(datetime2(3), NULL)
    FROM @Scope AS scopeValue
    CROSS JOIN (VALUES (N''B2C'', N''CENA_MANJKA_B2C''), (N''B2B'', N''CENA_MANJKA_B2B'')) AS required (PriceList, CheckCode)
    WHERE NOT EXISTS
    (
      SELECT 1 FROM activePrice AS priceValue
      WHERE priceValue.ProductId = scopeValue.ProductId AND priceValue.PriceList = required.PriceList
    )

    UNION ALL

    /* Aktivna cena je nic ali manj. */
    SELECT priceValue.ProductId, N''CENA_NIC'', priceValue.PriceList,
      N''Aktivna cena v ceniku '' + priceValue.PriceList + N'' je '' + CONVERT(nvarchar(40), priceValue.Net) + N''.'',
      priceValue.Net, NULL, NULL, NULL, NULL
    FROM activePrice AS priceValue
    WHERE priceValue.Ordinal = 1 AND priceValue.Net <= 0

    UNION ALL

    /* Aktivna cena brez stopnje DDV. */
    SELECT priceValue.ProductId, N''DDV_MANJKA'', priceValue.PriceList,
      N''Aktivna cena v ceniku '' + priceValue.PriceList + N'' nima stopnje DDV.'',
      priceValue.Net, NULL, NULL, NULL, NULL
    FROM activePrice AS priceValue
    WHERE priceValue.Ordinal = 1 AND (priceValue.VatRate IS NULL OR priceValue.VatRate = 0)

    UNION ALL

    /* Vec kot ena aktivna cena za isti izdelek in cenik. */
    SELECT priceValue.ProductId, N''PODVOJEN_ZAPIS'', priceValue.PriceList,
      N''Cenik '' + priceValue.PriceList + N'' ima '' + CONVERT(nvarchar(20), priceValue.Duplicates) + N'' aktivnih zapisov cene.'',
      priceValue.Net, NULL, NULL, NULL, NULL
    FROM activePrice AS priceValue
    WHERE priceValue.Ordinal = 1 AND priceValue.Duplicates > 1

    UNION ALL

    /* Cena je oznacena kot aktivna, njena veljavnost pa se ni nastopila. */
    SELECT priceValue.ProductId, N''CENIK_POTEKEL'', priceValue.PriceList,
      N''Cena velja od '' + CONVERT(nvarchar(20), priceValue.ValidFrom, 104) + N'', a je ze oznacena kot aktivna.'',
      priceValue.Net, NULL, NULL, NULL, CONVERT(datetime2(3), priceValue.ValidFrom)
    FROM activePrice AS priceValue
    WHERE priceValue.Ordinal = 1 AND priceValue.ValidFrom > SYSUTCDATETIME()

    UNION ALL

    /* Faktor prodajne in nabavne cene pod pragom. */
    SELECT priceValue.ProductId, N''FAKTOR_MARZE'', priceValue.PriceList,
      N''Faktor '' + CONVERT(nvarchar(20), CONVERT(decimal(18,2), priceValue.Net / purchaseValue.PurchaseNet))
        + N'' je pod pragom '' + CONVERT(nvarchar(20), CONVERT(decimal(18,2), @MarginThreshold)) + N''.'',
      priceValue.Net, purchaseValue.PurchaseNet,
      CONVERT(decimal(18,4), priceValue.Net / purchaseValue.PurchaseNet), N''cenik NAB'', NULL
    FROM activePrice AS priceValue
    INNER JOIN purchase AS purchaseValue ON purchaseValue.ProductId = priceValue.ProductId
    WHERE priceValue.Ordinal = 1 AND priceValue.PriceList IN (N''B2B'', N''B2C'')
      AND priceValue.Net > 0 AND priceValue.Net / purchaseValue.PurchaseNet < @MarginThreshold
      AND priceValue.Net >= purchaseValue.PurchaseNet

    UNION ALL

    /* Prodajna cena pod nabavno je svoja preverba, ne le nizek faktor. */
    SELECT priceValue.ProductId, N''CENA_POD_NABAVNO'', priceValue.PriceList,
      N''Prodajna cena '' + CONVERT(nvarchar(40), priceValue.Net) + N'' je nizja od nabavne ''
        + CONVERT(nvarchar(40), purchaseValue.PurchaseNet) + N''.'',
      priceValue.Net, purchaseValue.PurchaseNet,
      CONVERT(decimal(18,4), priceValue.Net / NULLIF(purchaseValue.PurchaseNet, 0)), N''cenik NAB'', NULL
    FROM activePrice AS priceValue
    INNER JOIN purchase AS purchaseValue ON purchaseValue.ProductId = priceValue.ProductId
    WHERE priceValue.Ordinal = 1 AND priceValue.PriceList IN (N''B2B'', N''B2C'')
      AND priceValue.Net > 0 AND priceValue.Net < purchaseValue.PurchaseNet
  )
  /* 132: preverbe se zberejo enkrat v zacasno tabelo, seznam in stevec pa bereta iz nje. */
  SELECT checks.ProductId, scopeValue.ItemID, scopeValue.Name, checks.CheckCode, checks.Context,
    checks.Detail, checks.ObservedUtc, checks.SalesPrice, checks.PurchasePrice,
    checks.MarginFactor, checks.UnitBasis
  INTO #PriceChecks
  FROM checks
  INNER JOIN @Scope AS scopeValue ON scopeValue.ProductId = checks.ProductId
  WHERE (@CheckCode IS NULL OR checks.CheckCode = @CheckCode)
    AND (@Context IS NULL OR checks.Context = @Context)
  OPTION (RECOMPILE);

  SELECT ProductId, ItemID, Name, CheckCode, Context, Detail, ObservedUtc,
    SalesPrice, PurchasePrice, MarginFactor, UnitBasis
  FROM #PriceChecks
  ORDER BY ItemID, CheckCode, Context
  OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY;

  SELECT TotalCount = COUNT_BIG(*) FROM #PriceChecks;

  DROP TABLE #PriceChecks;
END;');

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetStockChecks
  @OrganizationId int,
  @ProductId bigint = NULL,
  @CheckCode nvarchar(60) = NULL,
  @Context nvarchar(100) = NULL,
  @Search nvarchar(200) = NULL,
  @Skip int = 0,
  @Take int = 50
AS
BEGIN
  SET NOCOUNT ON;

  SET @Skip = CASE WHEN @Skip < 0 THEN 0 ELSE @Skip END;
  SET @Take = CASE WHEN @Take < 1 THEN 50 WHEN @Take > 2000 THEN 2000 ELSE @Take END;
  SET @CheckCode = NULLIF(UPPER(LTRIM(RTRIM(@CheckCode))), N'''');
  SET @Context = NULLIF(LTRIM(RTRIM(@Context)), N'''');
  SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'''');

  /* Ista meja zastarelosti kot na strani zaloge: 24 ur. */
  DECLARE @StaleHours int = 24;
  DECLARE @Now datetime2(3) = SYSUTCDATETIME();
  DECLARE @Like nvarchar(210) = CASE WHEN @Search IS NULL THEN NULL ELSE N''%'' + @Search + N''%'' END;

  ;WITH position AS
  (
    SELECT positionValue.PositionId, positionValue.MatchedProductId, positionValue.Quantity,
      positionValue.IncomingQuantity, positionValue.NormalizedItemId, positionValue.Ean,
      snapshotValue.SnapshotUtc, connector.SourceCode
    FROM stock.Position AS positionValue
    INNER JOIN stock.Snapshot AS snapshotValue ON snapshotValue.SnapshotId = positionValue.SnapshotId
    INNER JOIN map.SourceConnector AS connector ON connector.SourceConnectorId = snapshotValue.SourceConnectorId
    WHERE snapshotValue.OrganizationId = @OrganizationId AND snapshotValue.IsActive = 1
      AND (@Context IS NULL OR connector.SourceCode = @Context)
  ),
  named AS
  (
    SELECT position.*, ItemID = COALESCE(product.ItemID, position.NormalizedItemId, position.Ean, N''?''),
      Name = COALESCE(title.Value, product.ItemID, position.NormalizedItemId, N''brez artikla'')
    FROM position
    LEFT JOIN canon.Product AS product ON product.ProductId = position.MatchedProductId
    OUTER APPLY
    (
      SELECT TOP (1) textValue.Value
      FROM canon.ProductText AS textValue
      WHERE textValue.ProductId = position.MatchedProductId AND textValue.TextType IN (N''WEB_TITLE'', N''TITLE_ERP'')
      ORDER BY CASE WHEN textValue.TextType = N''WEB_TITLE'' THEN 0 ELSE 1 END, textValue.Lang
    ) AS title
    WHERE (@ProductId IS NULL OR position.MatchedProductId = @ProductId)
      AND (@Like IS NULL OR position.NormalizedItemId LIKE @Like OR position.Ean LIKE @Like OR product.ItemID LIKE @Like)
  ),
  checks AS
  (
    SELECT named.MatchedProductId AS ProductId, named.ItemID, named.Name,
      CheckCode = N''BREZ_ZALOGE_BREZ_PRIHODA'', Context = named.SourceCode,
      Detail = N''Ni zaloge in ni napovedanega prihoda.'',
      ObservedUtc = named.SnapshotUtc, SalesPrice = CONVERT(decimal(18,4), NULL),
      PurchasePrice = CONVERT(decimal(18,4), NULL), MarginFactor = CONVERT(decimal(18,4), NULL),
      UnitBasis = CONVERT(nvarchar(40), NULL)
    FROM named
    WHERE named.Quantity <= 0 AND COALESCE(named.IncomingQuantity, 0) <= 0

    UNION ALL

    SELECT named.MatchedProductId, named.ItemID, named.Name, N''ZALOGA_POD_MIN'', named.SourceCode,
      N''Kolicina '' + CONVERT(nvarchar(40), named.Quantity) + N'' je pod minimumom ''
        + CONVERT(nvarchar(40), policy.MinimumStock) + N''.'',
      named.SnapshotUtc, NULL, NULL, NULL, policy.WarehouseCode
    FROM named
    INNER JOIN canon.ProductStockPolicy AS policy ON policy.ProductId = named.MatchedProductId
    WHERE policy.MinimumStock IS NOT NULL AND named.Quantity < policy.MinimumStock

    UNION ALL

    SELECT named.MatchedProductId, named.ItemID, named.Name, N''POSNETEK_ZASTAREL'', named.SourceCode,
      N''Zadnji posnetek vira je star '' + CONVERT(nvarchar(20), DATEDIFF(hour, named.SnapshotUtc, @Now)) + N'' ur.'',
      named.SnapshotUtc, NULL, NULL, NULL, NULL
    FROM named
    WHERE named.SnapshotUtc < DATEADD(hour, -@StaleHours, @Now)

    UNION ALL

    SELECT named.MatchedProductId, named.ItemID, named.Name, N''POZICIJA_BREZ_ARTIKLA'', named.SourceCode,
      N''Pozicije ni mogoce pripeti na artikel.'', named.SnapshotUtc, NULL, NULL, NULL, NULL
    FROM named
    WHERE named.MatchedProductId IS NULL
  )
  /* 132: isto pravilo kot pri cenah — seznam in stevec bereta isto zbrano mnozico. */
  SELECT ProductId = COALESCE(ProductId, 0), ItemID, Name, CheckCode, Context, Detail, ObservedUtc,
    SalesPrice, PurchasePrice, MarginFactor, UnitBasis
  INTO #StockChecks
  FROM checks
  WHERE (@CheckCode IS NULL OR CheckCode = @CheckCode)
  OPTION (RECOMPILE);

  SELECT ProductId, ItemID, Name, CheckCode, Context, Detail, ObservedUtc,
    SalesPrice, PurchasePrice, MarginFactor, UnitBasis
  FROM #StockChecks
  ORDER BY ItemID, CheckCode, Context
  OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY;

  SELECT TotalCount = COUNT_BIG(*) FROM #StockChecks;

  DROP TABLE #StockChecks;
END;');
