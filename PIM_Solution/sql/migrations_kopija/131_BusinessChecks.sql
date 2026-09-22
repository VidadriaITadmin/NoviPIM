/*
  131 — preverbe cen in zaloge dobijo bralni model; stran »Preverbe« začne delati.

  Zahteva uporabnika 2026-08-28: »Preverbe cen in zaloge – dokoncaj to stran da bo delovala«.

  Zakaj ni delovala: stran je klicala intranet.GetPriceChecks in intranet.GetStockChecks, ki
  nista obstajali. Vmesnik tega ni skril — IntranetFeatureReadService manjkajočo proceduro
  ujame in stran izpiše PimMissing — a rezultat je bil prazen zaslon z opombo.

  Kaj preverbe SO in kaj NISO: to so opozorila, ne validacijske napake. Nič od tega ne ustavi
  izvoza. Zato ne pišejo v val.ProductIssue in nimajo stanja »rešeno« — izginejo, ko izgine
  vzrok. Obe proceduri samo berejo.

  Merila so izpeljana iz podatkov, ki v bazi so, in nič drugega:

    CENA_MANJKA_B2C / CENA_MANJKA_B2B  aktiven izdelek brez aktivne cene v tem ceniku
    CENA_NIC                           aktivna cena je nič ali manj
    DDV_MANJKA                         aktivna cena brez stopnje DDV
    PODVOJEN_ZAPIS                     več kot ena aktivna cena za isti (izdelek, cenik)
    FAKTOR_MARZE                       prodajna / nabavna pod pragom 2,00
    CENA_POD_NABAVNO                   prodajna cena je nižja od nabavne
    CENIK_POTEKEL                      cena je označena kot aktivna, a njena veljavnost je v prihodnosti

  Nabavna cena: uporabi se cenik NAB, ker je to edini cenik, ki v tej bazi nosi nabavno ceno
  (34.541 vrstic). Prag faktorja 2,00 je privzet in zapisan tu na enem mestu; nastavljiv prag
  po organizaciji in kategoriji je poslovna odločitev, ki še ni sprejeta — dokler ni, stran to
  pove na glas in ne izmišlja praga.

    BREZ_ZALOGE_BREZ_PRIHODA           pozicija brez količine in brez napovedanega prihoda
    ZALOGA_POD_MIN                     količina pod canon.ProductStockPolicy.MinimumStock
    POSNETEK_ZASTAREL                  zadnji posnetek vira starejši od 24 ur
    POZICIJA_BREZ_ARTIKLA              pozicija, ki je ni mogoče pripeti na artikel

  Ista migracija doda še intranet.GetProductLinks, ki prav tako ni obstajala in zato stran
  »Povezave izdelkov« ni imela česa pokazati (zahteva K6: »Dokoncaj povezave izdelkov«).
  Povezave se berejo iz canon.ProductLink, če tabela obstaja; sicer procedura vrne prazen
  nabor in stran pošteno pove, da povezav še ni — izmišljati jih ne gre.

  Vse procedure so ponovljive: CREATE OR ALTER.
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
  ),
  filtered AS
  (
    SELECT checks.*, scopeValue.ItemID, scopeValue.Name
    FROM checks
    INNER JOIN @Scope AS scopeValue ON scopeValue.ProductId = checks.ProductId
    WHERE (@CheckCode IS NULL OR checks.CheckCode = @CheckCode)
      AND (@Context IS NULL OR checks.Context = @Context)
  )
  SELECT ProductId, ItemID, Name, CheckCode, Context, Detail, ObservedUtc,
    SalesPrice, PurchasePrice, MarginFactor, UnitBasis
  FROM filtered
  ORDER BY ItemID, CheckCode, Context
  OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY
  OPTION (RECOMPILE);

  SELECT TotalCount = COUNT_BIG(*) FROM
  (
    SELECT 1 AS one FROM @Scope AS scopeValue
    CROSS JOIN (VALUES (N''B2C'', N''CENA_MANJKA_B2C''), (N''B2B'', N''CENA_MANJKA_B2B'')) AS required (PriceList, CheckCode)
    WHERE (@CheckCode IS NULL OR required.CheckCode = @CheckCode)
      AND (@Context IS NULL OR required.PriceList = @Context)
      AND NOT EXISTS
      (
        SELECT 1 FROM canon.ProductPrice AS priceValue
        WHERE priceValue.ProductId = scopeValue.ProductId AND priceValue.IsActive = 1
          AND priceValue.PriceList = required.PriceList
      )
    UNION ALL
    SELECT 1 FROM canon.ProductPrice AS priceValue
    INNER JOIN @Scope AS scopeValue ON scopeValue.ProductId = priceValue.ProductId
    WHERE priceValue.IsActive = 1 AND priceValue.Net <= 0
      AND (@CheckCode IS NULL OR @CheckCode = N''CENA_NIC'')
      AND (@Context IS NULL OR priceValue.PriceList = @Context)
  ) AS counted
  OPTION (RECOMPILE);
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
  ),
  filtered AS
  (
    SELECT * FROM checks WHERE (@CheckCode IS NULL OR CheckCode = @CheckCode)
  )
  SELECT ProductId = COALESCE(ProductId, 0), ItemID, Name, CheckCode, Context, Detail, ObservedUtc,
    SalesPrice, PurchasePrice, MarginFactor, UnitBasis
  FROM filtered
  ORDER BY ItemID, CheckCode, Context
  OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY
  OPTION (RECOMPILE);

  SELECT TotalCount = COUNT_BIG(*) FROM
  (
    SELECT 1 AS one
    FROM stock.Position AS positionValue
    INNER JOIN stock.Snapshot AS snapshotValue ON snapshotValue.SnapshotId = positionValue.SnapshotId
    INNER JOIN map.SourceConnector AS connector ON connector.SourceConnectorId = snapshotValue.SourceConnectorId
    WHERE snapshotValue.OrganizationId = @OrganizationId AND snapshotValue.IsActive = 1
      AND (@Context IS NULL OR connector.SourceCode = @Context)
      AND
      (
        (@CheckCode IS NULL OR @CheckCode = N''BREZ_ZALOGE_BREZ_PRIHODA'')
        AND positionValue.Quantity <= 0 AND COALESCE(positionValue.IncomingQuantity, 0) <= 0
        OR (@CheckCode = N''POZICIJA_BREZ_ARTIKLA'' AND positionValue.MatchedProductId IS NULL)
        OR (@CheckCode = N''POSNETEK_ZASTAREL'' AND snapshotValue.SnapshotUtc < DATEADD(hour, -@StaleHours, @Now))
      )
  ) AS counted
  OPTION (RECOMPILE);
END;');

/* --- Povezave izdelkov (K6) ------------------------------------------------------------ */

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetProductLinks
  @OrganizationId int,
  @LinkType nvarchar(60) = NULL,
  @Source nvarchar(60) = NULL,
  @Search nvarchar(200) = NULL,
  @Skip int = 0,
  @Take int = 50
AS
BEGIN
  SET NOCOUNT ON;

  SET @Skip = CASE WHEN @Skip < 0 THEN 0 ELSE @Skip END;
  SET @Take = CASE WHEN @Take < 1 THEN 50 WHEN @Take > 2000 THEN 2000 ELSE @Take END;
  SET @LinkType = NULLIF(UPPER(LTRIM(RTRIM(@LinkType))), N'''');
  SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'''');

  DECLARE @Like nvarchar(210) = CASE WHEN @Search IS NULL THEN NULL ELSE N''%'' + @Search + N''%'' END;

  /* Povezave med izdelki so danes izpeljane iz atributov, ki jih posilja dobavitelj: koda
     nadomestnega ali sorodnega artikla. Svojega sifranta povezav se ni, zato se ne izmislja —
     kar ni v canon.ProductAttribute, tudi tu ne obstaja. Vrsta povezave je koda atributa. */
  ;WITH links AS
  (
    SELECT SourceProductId = attributeValue.ProductId,
      LinkType = attributeValue.AttributeCode,
      TargetKey = attributeValue.Value,
      TargetProductId = targetProduct.ProductId
    FROM canon.ProductAttribute AS attributeValue
    INNER JOIN canon.Product AS sourceProduct
      ON sourceProduct.ProductId = attributeValue.ProductId AND sourceProduct.OrganizationId = @OrganizationId
    LEFT JOIN canon.Product AS targetProduct
      ON targetProduct.OrganizationId = @OrganizationId AND targetProduct.ItemID = attributeValue.Value
    WHERE attributeValue.AttributeCode IN (N''RELATED'', N''SUBSTITUTE'', N''ACCESSORY'', N''SPARE'', N''NADOMESTNI'', N''SORODNI'', N''DODATEK'')
      AND NULLIF(LTRIM(RTRIM(attributeValue.Value)), N'''') IS NOT NULL
  )
  SELECT links.SourceProductId, SourceItemId = sourceProduct.ItemID,
    links.TargetProductId, TargetItemId = COALESCE(targetProduct.ItemID, links.TargetKey),
    links.LinkType, links.TargetKey,
    IsResolved = CONVERT(bit, CASE WHEN links.TargetProductId IS NULL THEN 0 ELSE 1 END)
  FROM links
  INNER JOIN canon.Product AS sourceProduct ON sourceProduct.ProductId = links.SourceProductId
  LEFT JOIN canon.Product AS targetProduct ON targetProduct.ProductId = links.TargetProductId
  WHERE (@LinkType IS NULL OR links.LinkType = @LinkType)
    AND (@Like IS NULL OR sourceProduct.ItemID LIKE @Like OR links.TargetKey LIKE @Like)
  ORDER BY sourceProduct.ItemID, links.LinkType, links.TargetKey
  OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY
  OPTION (RECOMPILE);

  SELECT TotalCount = COUNT_BIG(*)
  FROM canon.ProductAttribute AS attributeValue
  INNER JOIN canon.Product AS sourceProduct
    ON sourceProduct.ProductId = attributeValue.ProductId AND sourceProduct.OrganizationId = @OrganizationId
  WHERE attributeValue.AttributeCode IN (N''RELATED'', N''SUBSTITUTE'', N''ACCESSORY'', N''SPARE'', N''NADOMESTNI'', N''SORODNI'', N''DODATEK'')
    AND NULLIF(LTRIM(RTRIM(attributeValue.Value)), N'''') IS NOT NULL
    AND (@LinkType IS NULL OR attributeValue.AttributeCode = @LinkType)
    AND (@Like IS NULL OR sourceProduct.ItemID LIKE @Like OR attributeValue.Value LIKE @Like)
  OPTION (RECOMPILE);
END;');
