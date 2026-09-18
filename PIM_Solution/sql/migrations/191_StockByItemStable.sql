/*
  191 — popravek intranet.GetStockByItem (migracija 190): zaloga se je obesila za nekatera podjetja.

  Uporabnik, dobesedno: »zakaj zaloga dela smao za vidadrio podjetje mora delati za vse
  podjetja«. Vzrok ni bil manjkajoc podatek (vsa stiri podjetja imajo aktivne posnetke), ampak
  nestabilen nacrt poizvedbe:

    - intranet.GetStockByItem je isto zapleteno zdruzevanje (CTE "aggregated") sklicevala
      DVAKRAT — enkrat v "policy", enkrat v "withCombined" — SQL Server torej ni zajamcil, da se
      izracuna samo enkrat, in je pri nekaterih kombinacijah parametrov (opazovano: podjetje 1,
      DEMO, 16 SAOP pozicij proti ~4.150 dobaviteljevim — mocno neuravnotezeno) izbral nacrt s
      cakanjem CXCONSUMER, ki traja minute namesto milisekund.
    - Brez OPTION (RECOMPILE) na GLAVNI poizvedbi (bila je samo na stevcu) je SQL Server lahko
      ponovno uporabil nacrt, sestavljen za prejsnje, drugacno podjetje — klasicno "parameter
      sniffing": ista procedura, razlicno hitra glede na to, kdaj in za koga je bila nazadnje
      prevedena. To pojasni, zakaj je delalo "samo za Vidadrio" — ni bilo dosledno vezano na
      podjetje, ampak na to, kateri nacrt je bil nazadnje v predpomnilniku.
    - Blazor stran ujame VSE napake v en sam splosen "Zaloge trenutno ni mogoce nalozit." (glej
      Stocks.razor), zato je bilo casovno prekoracen klic (60 s) videti kot "za to podjetje ne
      dela", ne kot pocasna poizvedba.

  Popravek: zberi enkrat v zacasno tabelo #StockByItem (isti vzorec kot migracija 150,
  intranet.GetPriceChecks/#PriceChecks — "preverbe se zberejo enkrat v zacasno tabelo, seznam in
  stevec pa bereta iz nje"), z OPTION (RECOMPILE, MAXDOP 1) na zbiranju. En prehod, brez
  podvojenega izracuna, brez odvisnosti od prejsnjega predpomnjenega nacrta. MAXDOP 1 je dodan,
  ker je zbiranje z vzporednim nacrtom (STRING_AGG + tezke agregacije) med preizkusom te
  migracije samo sebe zaklenilo (napaka 1205, znotraj ene same seje) — brez vzporednosti tega
  vzorca ni.

  Migracija je ponovljiva: CREATE OR ALTER. Po popravku preveri vsa stiri podjetja, ne samo
  prvo — ravno to je bilo prej neopazeno, ker je "dokaz" preveril samo MIN(OrganizationId).
*/

SET XACT_ABORT ON;

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetStockByItem
  @OrganizationId int = NULL,
  @Skip int = 0,
  @Take int = 50,
  @Search nvarchar(200) = NULL,
  @SourceCode nvarchar(100) = NULL,
  @Availability nvarchar(20) = NULL,
  @MaxAgeHours int = NULL,
  @Language nvarchar(20) = N''sl''
AS
BEGIN
  SET NOCOUNT ON;

  SET @Skip = CASE WHEN @Skip < 0 THEN 0 ELSE @Skip END;
  SET @Take = CASE WHEN @Take < 1 THEN 50 WHEN @Take > 200 THEN 200 ELSE @Take END;
  SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'''');
  SET @SourceCode = NULLIF(LTRIM(RTRIM(@SourceCode)), N'''');
  SET @Availability = NULLIF(UPPER(LTRIM(RTRIM(@Availability))), N'''');
  SET @Language = COALESCE(NULLIF(LTRIM(RTRIM(@Language)), N''''), N''sl'');
  IF @Availability NOT IN (N''IN_STOCK'', N''OUT_OF_STOCK'', N''INCOMING'') SET @Availability = NULL;
  IF @MaxAgeHours IS NOT NULL AND @MaxAgeHours < 1 SET @MaxAgeHours = NULL;

  DECLARE @Like nvarchar(210) = CASE WHEN @Search IS NULL THEN NULL ELSE N''%'' + @Search + N''%'' END;
  DECLARE @Now datetime2(3) = SYSUTCDATETIME();

  CREATE TABLE #StockByItem
  (
    GroupKey nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY,
    OrganizationId int NOT NULL,
    OrganizationName nvarchar(200) NOT NULL,
    NormalizedItemId nvarchar(200) NULL,
    Ean nvarchar(100) NULL,
    MatchedProductId bigint NULL,
    ProductName nvarchar(1000) NULL,
    ProductItemId nvarchar(200) NULL,
    HasErp bit NOT NULL,
    ErpWarehouse nvarchar(1000) NULL,
    ErpQuantity decimal(18,4) NOT NULL,
    ErpAvailable decimal(18,4) NOT NULL,
    ErpOrdered decimal(18,4) NOT NULL,
    ErpForShipment decimal(18,4) NOT NULL,
    ErpSupplierOrdered decimal(18,4) NOT NULL,
    ErpIncomingQuantity decimal(18,4) NULL,
    ErpIncomingDate datetime2(3) NULL,
    ErpSnapshotUtc datetime2(3) NULL,
    HasSupplier bit NOT NULL,
    SupplierCode nvarchar(1000) NULL,
    SupplierQuantity decimal(18,4) NOT NULL,
    SupplierIncoming decimal(18,4) NULL,
    SupplierIncomingDate datetime2(3) NULL,
    SupplierSnapshotUtc datetime2(3) NULL,
    MinimumStock decimal(18,4) NULL,
    MaximumStock decimal(18,4) NULL,
    CombinedQuantity decimal(18,4) NOT NULL,
    CombinedIncoming decimal(18,4) NOT NULL
  );

  ;WITH filtered AS
  (
    SELECT position.PositionId, position.NormalizedItemId, position.Ean, position.MatchedProductId,
      position.Quantity, position.AvailabilityDate, position.IncomingQuantity, position.AvailableQuantity,
      position.OrderedQuantity, position.ForShipmentQuantity, position.SupplierOrderedQuantity,
      connector.ConnectorType, connector.SourceCode, snapshot.OrganizationId, snapshot.SnapshotUtc,
      GroupKey = ISNULL(CONVERT(nvarchar(20), position.MatchedProductId), CONCAT(N''U:'', connector.SourceCode, N'':'', position.NormalizedItemId)),
      Warehouse = CASE WHEN connector.ConnectorType = N''SAOP'' THEN registry.WarehouseLabel END
    FROM stock.Position AS position
    INNER JOIN stock.Snapshot AS snapshot ON snapshot.SnapshotId = position.SnapshotId AND snapshot.IsActive = 1
    INNER JOIN map.SourceConnector AS connector ON connector.SourceConnectorId = snapshot.SourceConnectorId
    LEFT JOIN out.ExportStockSource AS registry
      ON registry.OrganizationId = snapshot.OrganizationId AND registry.StockOrganizationId = snapshot.OrganizationId
     AND registry.SourceCode = connector.SourceCode AND registry.IsActive = 1
    WHERE (@OrganizationId IS NULL OR snapshot.OrganizationId = @OrganizationId)
      AND (@SourceCode IS NULL OR connector.SourceCode = @SourceCode)
      AND (@Like IS NULL OR position.NormalizedItemId LIKE @Like OR position.Ean LIKE @Like)
      AND (@MaxAgeHours IS NULL OR snapshot.SnapshotUtc >= DATEADD(hour, -@MaxAgeHours, @Now))
  ),
  delivery AS
  (
    SELECT OrganizationId, NormalizedItemId,
      DeliveryDate = MIN(DeliveryDate), Quantity = SUM(ISNULL(Quantity, 0))
    FROM stock.ItemDeliveryDate
    WHERE @OrganizationId IS NULL OR OrganizationId = @OrganizationId
    GROUP BY OrganizationId, NormalizedItemId
  ),
  -- Skladisce/dobavitelja zdruzi iz RAZLICNIH virov v skupini, ne enkrat na pozicijo: en
  -- dobavitelj lahko v isti skupini nastopi z vec pozicijami (vec njegovih sifer je pripetih na
  -- isti PIM izdelek) — STRING_AGG neposredno na "filtered" bi zato ponovil isto kodo vira
  -- tolikokrat, kolikor ima pozicij (opazovano: "BT_STOCK + BT_STOCK + ..." desetkrat), dokler
  -- ne bi podrl sirine stolpca. DISTINCT najprej odpravi to podvajanje.
  sourceLabels AS
  (
    SELECT DISTINCT f.GroupKey, f.ConnectorType, f.SourceCode, f.Warehouse
    FROM filtered AS f
  ),
  labels AS
  (
    SELECT GroupKey,
      ErpWarehouse = STRING_AGG(CASE WHEN ConnectorType = N''SAOP'' THEN ISNULL(Warehouse, SourceCode) END, N'' + ''),
      SupplierCode = STRING_AGG(CASE WHEN ConnectorType <> N''SAOP'' THEN SourceCode END, N'' + '')
    FROM sourceLabels
    GROUP BY GroupKey
  ),
  aggregated AS
  (
    SELECT
      f.GroupKey,
      OrganizationId = MAX(f.OrganizationId),
      NormalizedItemId = MAX(f.NormalizedItemId),
      Ean = MAX(f.Ean),
      MatchedProductId = MAX(f.MatchedProductId),
      HasErp = MAX(CASE WHEN f.ConnectorType = N''SAOP'' THEN 1 ELSE 0 END),
      ErpQuantity = SUM(CASE WHEN f.ConnectorType = N''SAOP'' THEN f.Quantity ELSE 0 END),
      -- ISNULL na vsakem polju, ne samo na vsoti: brez tega SUM cez vrstice enega vira, kjer
      -- polje sploh ni znano (navaden GetStocks nima Available/Ordered/ForShipment/SupplierOrdered
      -- — to poroca samo registrirani pogled, migracija 145), vrne NULL namesto 0 in podre NOT
      -- NULL stolpec. Prav to je bil razlog, da je stran delala samo za Vidadrio (registrirani
      -- pogled) in ne za druga podjetja (navaden GetStocks).
      ErpAvailable = SUM(CASE WHEN f.ConnectorType = N''SAOP'' THEN ISNULL(f.AvailableQuantity, 0) ELSE 0 END),
      ErpOrdered = SUM(CASE WHEN f.ConnectorType = N''SAOP'' THEN ISNULL(f.OrderedQuantity, 0) ELSE 0 END),
      ErpForShipment = SUM(CASE WHEN f.ConnectorType = N''SAOP'' THEN ISNULL(f.ForShipmentQuantity, 0) ELSE 0 END),
      ErpSupplierOrdered = SUM(CASE WHEN f.ConnectorType = N''SAOP'' THEN ISNULL(f.SupplierOrderedQuantity, 0) ELSE 0 END),
      ErpOwnIncoming = SUM(CASE WHEN f.ConnectorType = N''SAOP'' THEN f.IncomingQuantity ELSE 0 END),
      ErpOwnIncomingDate = MIN(CASE WHEN f.ConnectorType = N''SAOP'' THEN f.AvailabilityDate END),
      ErpSnapshotUtc = MAX(CASE WHEN f.ConnectorType = N''SAOP'' THEN f.SnapshotUtc END),
      HasSupplier = MAX(CASE WHEN f.ConnectorType <> N''SAOP'' THEN 1 ELSE 0 END),
      SupplierQuantity = SUM(CASE WHEN f.ConnectorType <> N''SAOP'' THEN f.Quantity ELSE 0 END),
      SupplierIncoming = SUM(CASE WHEN f.ConnectorType <> N''SAOP'' THEN f.IncomingQuantity ELSE 0 END),
      SupplierIncomingDate = MIN(CASE WHEN f.ConnectorType <> N''SAOP'' THEN f.AvailabilityDate END),
      SupplierSnapshotUtc = MAX(CASE WHEN f.ConnectorType <> N''SAOP'' THEN f.SnapshotUtc END)
    FROM filtered AS f
    GROUP BY f.GroupKey
  )
  INSERT #StockByItem
  (
    GroupKey, OrganizationId, OrganizationName, NormalizedItemId, Ean, MatchedProductId, ProductName, ProductItemId,
    HasErp, ErpWarehouse, ErpQuantity, ErpAvailable, ErpOrdered, ErpForShipment, ErpSupplierOrdered,
    ErpIncomingQuantity, ErpIncomingDate, ErpSnapshotUtc,
    HasSupplier, SupplierCode, SupplierQuantity, SupplierIncoming, SupplierIncomingDate, SupplierSnapshotUtc,
    MinimumStock, MaximumStock, CombinedQuantity, CombinedIncoming
  )
  SELECT
    aggregated.GroupKey, aggregated.OrganizationId, organization.Name,
    aggregated.NormalizedItemId, aggregated.Ean, aggregated.MatchedProductId,
    productTitle.Value, matched.ItemID,
    aggregated.HasErp, labels.ErpWarehouse, aggregated.ErpQuantity, aggregated.ErpAvailable,
    aggregated.ErpOrdered, aggregated.ErpForShipment, aggregated.ErpSupplierOrdered,
    ErpIncomingQuantity = COALESCE(NULLIF(aggregated.ErpOwnIncoming, 0), delivery.Quantity),
    ErpIncomingDate = COALESCE(aggregated.ErpOwnIncomingDate, delivery.DeliveryDate),
    aggregated.ErpSnapshotUtc,
    aggregated.HasSupplier, labels.SupplierCode, aggregated.SupplierQuantity,
    aggregated.SupplierIncoming, aggregated.SupplierIncomingDate, aggregated.SupplierSnapshotUtc,
    policyValue.MinimumStock, policyValue.MaximumStock,
    CombinedQuantity = aggregated.ErpQuantity + aggregated.SupplierQuantity,
    CombinedIncoming = ISNULL(COALESCE(NULLIF(aggregated.ErpOwnIncoming, 0), delivery.Quantity), 0) + ISNULL(aggregated.SupplierIncoming, 0)
  FROM aggregated
  INNER JOIN labels ON labels.GroupKey = aggregated.GroupKey
  LEFT JOIN delivery ON delivery.OrganizationId = aggregated.OrganizationId AND delivery.NormalizedItemId = aggregated.NormalizedItemId
  LEFT JOIN canon.Product AS matched ON matched.ProductId = aggregated.MatchedProductId
  INNER JOIN dbo.OrganizationConfig AS organization ON organization.OrganizationId = aggregated.OrganizationId
  OUTER APPLY
  (
    SELECT TOP (1) textValue.Value
    FROM canon.ProductText AS textValue
    WHERE textValue.ProductId = aggregated.MatchedProductId AND textValue.TextType IN (N''WEB_TITLE'', N''TITLE_ERP'')
    ORDER BY CASE WHEN textValue.TextType = N''WEB_TITLE'' THEN 0 ELSE 1 END,
      CASE WHEN textValue.Lang = @Language THEN 0 WHEN textValue.Lang = N''sl'' THEN 1 ELSE 2 END, textValue.Lang
  ) AS productTitle
  OUTER APPLY
  (
    SELECT TOP (1) top1.MinimumStock, top1.MaximumStock
    FROM canon.ProductStockPolicy AS top1
    WHERE top1.ProductId = aggregated.MatchedProductId
    ORDER BY top1.WarehouseCode
  ) AS policyValue
  OPTION (RECOMPILE, MAXDOP 1);

  SELECT GroupKey, OrganizationId, OrganizationName, NormalizedItemId, Ean, MatchedProductId, ProductName, ProductItemId,
    HasErp, ErpWarehouse, ErpQuantity, ErpAvailable, ErpOrdered, ErpForShipment, ErpSupplierOrdered,
    ErpIncomingQuantity, ErpIncomingDate, ErpSnapshotUtc,
    HasSupplier, SupplierCode, SupplierQuantity, SupplierIncoming, SupplierIncomingDate, SupplierSnapshotUtc,
    MinimumStock, MaximumStock
  FROM #StockByItem
  WHERE
  (
    @Availability IS NULL
    OR (@Availability = N''IN_STOCK'' AND CombinedQuantity > 0)
    OR (@Availability = N''OUT_OF_STOCK'' AND CombinedQuantity <= 0)
    OR (@Availability = N''INCOMING'' AND CombinedIncoming > 0)
  )
  ORDER BY NormalizedItemId, GroupKey
  OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY;

  SELECT TotalCount = COUNT_BIG(*)
  FROM #StockByItem
  WHERE
  (
    @Availability IS NULL
    OR (@Availability = N''IN_STOCK'' AND CombinedQuantity > 0)
    OR (@Availability = N''OUT_OF_STOCK'' AND CombinedQuantity <= 0)
    OR (@Availability = N''INCOMING'' AND CombinedIncoming > 0)
  );

  DROP TABLE #StockByItem;
END;');

/* --- dokaz: vsa stiri podjetja, ne samo prvo -------------------------------------------- */

IF OBJECT_ID(N'intranet.GetStockByItem', N'P') IS NULL THROW 51910, N'191: intranet.GetStockByItem ni nastala.', 1;

DECLARE @OrgCursor CURSOR;
DECLARE @Org int;
SET @OrgCursor = CURSOR FAST_FORWARD FOR SELECT OrganizationId FROM dbo.OrganizationConfig ORDER BY OrganizationId;
OPEN @OrgCursor;
FETCH NEXT FROM @OrgCursor INTO @Org;
WHILE @@FETCH_STATUS = 0
BEGIN
  EXEC intranet.GetStockByItem @OrganizationId = @Org, @Skip = 0, @Take = 5;
  FETCH NEXT FROM @OrgCursor INTO @Org;
END;
CLOSE @OrgCursor;
DEALLOCATE @OrgCursor;
