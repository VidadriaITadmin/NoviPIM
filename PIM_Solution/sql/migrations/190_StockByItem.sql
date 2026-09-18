/*
  190 — zaloga: ena vrstica na artikel, s stolpci za nas (SAOP) in dobaviteljev del hkrati.

  Uporabnik, dobesedno, po pregledu strani z locenima vrsticama za isti artikel: »pa ne da so
  dve vrstice amapk da se doda stolpce v tabeli majstr da ima eno vrstico z vsemi temi podatki.
  Sepravi eno vrstico na artikel in da ima SAOP podatke in pa dobaviteljeve in tudi pri izvozu
  enako velja.«

  Zakaj nova procedura in ne prirejena intranet.GetStockPositions:
    Ta stran pagina po POZICIJAH (ena vrstica na artikel na vir), z ORDER BY SourceCode najprej —
    SAOP in dobaviteljeva pozicija istega artikla zato skoraj nikoli ne padeta na isto stran.
    Zdruzevanje v C# po tem, ko je stran ze prebrana, bi zato lomilo artikle na robu strani.
    Stranicenje mora zato teci NAD ze zdruzenimi vrsticami, ne nad pozicijami — to je druga
    poizvedba, ne popravek stare.

  Kako se zdruzi: skupina je MatchedProductId, kadar je artikel pripet (SAOP in dobaviteljeva
  pozicija istega artikla se ujemata na isti ProductId — to ze naredi obstojeci prevzem);
  nepripeta pozicija ostane sama v svoji skupini (vir + normalizirana sifra), ker brez pripetja
  ni zanesljivega skupnega kljuca med viroma.

  Prihodnja kolicina/datum za SAOP del: iz stock.ItemDeliveryDate (migracija 189), kadar jih
  position sama ne pozna (SAOP GetStocks/registrirani pogled ju ne poznata).

  Migracija je ponovljiva: CREATE OR ALTER.
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
      ErpAvailable = SUM(CASE WHEN f.ConnectorType = N''SAOP'' THEN f.AvailableQuantity ELSE 0 END),
      ErpOrdered = SUM(CASE WHEN f.ConnectorType = N''SAOP'' THEN f.OrderedQuantity ELSE 0 END),
      ErpForShipment = SUM(CASE WHEN f.ConnectorType = N''SAOP'' THEN f.ForShipmentQuantity ELSE 0 END),
      ErpSupplierOrdered = SUM(CASE WHEN f.ConnectorType = N''SAOP'' THEN f.SupplierOrderedQuantity ELSE 0 END),
      ErpOwnIncoming = SUM(CASE WHEN f.ConnectorType = N''SAOP'' THEN f.IncomingQuantity ELSE 0 END),
      ErpOwnIncomingDate = MIN(CASE WHEN f.ConnectorType = N''SAOP'' THEN f.AvailabilityDate END),
      ErpWarehouse = STRING_AGG(CASE WHEN f.ConnectorType = N''SAOP'' THEN ISNULL(f.Warehouse, f.SourceCode) END, N'' + ''),
      ErpSnapshotUtc = MAX(CASE WHEN f.ConnectorType = N''SAOP'' THEN f.SnapshotUtc END),
      HasSupplier = MAX(CASE WHEN f.ConnectorType <> N''SAOP'' THEN 1 ELSE 0 END),
      SupplierQuantity = SUM(CASE WHEN f.ConnectorType <> N''SAOP'' THEN f.Quantity ELSE 0 END),
      SupplierIncoming = SUM(CASE WHEN f.ConnectorType <> N''SAOP'' THEN f.IncomingQuantity ELSE 0 END),
      SupplierIncomingDate = MIN(CASE WHEN f.ConnectorType <> N''SAOP'' THEN f.AvailabilityDate END),
      SupplierCode = STRING_AGG(CASE WHEN f.ConnectorType <> N''SAOP'' THEN f.SourceCode END, N'' + ''),
      SupplierSnapshotUtc = MAX(CASE WHEN f.ConnectorType <> N''SAOP'' THEN f.SnapshotUtc END)
    FROM filtered AS f
    GROUP BY f.GroupKey
  ),
  policy AS
  (
    SELECT aggregated.GroupKey, policyValue.MinimumStock, policyValue.MaximumStock
    FROM aggregated
    OUTER APPLY
    (
      SELECT TOP (1) top1.MinimumStock, top1.MaximumStock
      FROM canon.ProductStockPolicy AS top1
      WHERE top1.ProductId = aggregated.MatchedProductId
      ORDER BY top1.WarehouseCode
    ) AS policyValue
  ),
  withCombined AS
  (
    SELECT aggregated.*, policy.MinimumStock, policy.MaximumStock,
      ErpIncomingQuantity = COALESCE(NULLIF(aggregated.ErpOwnIncoming, 0), delivery.Quantity),
      ErpIncomingDate = COALESCE(aggregated.ErpOwnIncomingDate, delivery.DeliveryDate),
      ProductName = productTitle.Value,
      ProductItemId = matched.ItemID,
      OrganizationName = organization.Name
    FROM aggregated
    LEFT JOIN policy ON policy.GroupKey = aggregated.GroupKey
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
  ),
  final AS
  (
    SELECT *,
      CombinedQuantity = ErpQuantity + SupplierQuantity,
      CombinedIncoming = ISNULL(ErpIncomingQuantity, 0) + ISNULL(SupplierIncoming, 0)
    FROM withCombined
  )
  SELECT GroupKey, OrganizationId, OrganizationName, NormalizedItemId, Ean, MatchedProductId, ProductName, ProductItemId,
    HasErp, ErpWarehouse, ErpQuantity, ErpAvailable, ErpOrdered, ErpForShipment, ErpSupplierOrdered,
    ErpIncomingQuantity, ErpIncomingDate, ErpSnapshotUtc,
    HasSupplier, SupplierCode, SupplierQuantity, SupplierIncoming, SupplierIncomingDate, SupplierSnapshotUtc,
    MinimumStock, MaximumStock
  FROM final
  WHERE
  (
    @Availability IS NULL
    OR (@Availability = N''IN_STOCK'' AND CombinedQuantity > 0)
    OR (@Availability = N''OUT_OF_STOCK'' AND CombinedQuantity <= 0)
    OR (@Availability = N''INCOMING'' AND CombinedIncoming > 0)
  )
  ORDER BY NormalizedItemId, GroupKey
  OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY;

  ;WITH filtered AS
  (
    SELECT position.PositionId, position.NormalizedItemId, position.MatchedProductId,
      position.Quantity, position.IncomingQuantity,
      connector.ConnectorType, connector.SourceCode, snapshot.OrganizationId,
      GroupKey = ISNULL(CONVERT(nvarchar(20), position.MatchedProductId), CONCAT(N''U:'', connector.SourceCode, N'':'', position.NormalizedItemId))
    FROM stock.Position AS position
    INNER JOIN stock.Snapshot AS snapshot ON snapshot.SnapshotId = position.SnapshotId AND snapshot.IsActive = 1
    INNER JOIN map.SourceConnector AS connector ON connector.SourceConnectorId = snapshot.SourceConnectorId
    WHERE (@OrganizationId IS NULL OR snapshot.OrganizationId = @OrganizationId)
      AND (@SourceCode IS NULL OR connector.SourceCode = @SourceCode)
      AND (@Like IS NULL OR position.NormalizedItemId LIKE @Like OR position.Ean LIKE @Like)
      AND (@MaxAgeHours IS NULL OR snapshot.SnapshotUtc >= DATEADD(hour, -@MaxAgeHours, @Now))
  ),
  delivery AS
  (
    SELECT OrganizationId, NormalizedItemId, Quantity = SUM(ISNULL(Quantity, 0))
    FROM stock.ItemDeliveryDate
    WHERE @OrganizationId IS NULL OR OrganizationId = @OrganizationId
    GROUP BY OrganizationId, NormalizedItemId
  ),
  aggregated AS
  (
    SELECT f.GroupKey, OrganizationId = MAX(f.OrganizationId), NormalizedItemId = MAX(f.NormalizedItemId),
      ErpQuantity = SUM(CASE WHEN f.ConnectorType = N''SAOP'' THEN f.Quantity ELSE 0 END),
      ErpOwnIncoming = SUM(CASE WHEN f.ConnectorType = N''SAOP'' THEN f.IncomingQuantity ELSE 0 END),
      SupplierQuantity = SUM(CASE WHEN f.ConnectorType <> N''SAOP'' THEN f.Quantity ELSE 0 END),
      SupplierIncoming = SUM(CASE WHEN f.ConnectorType <> N''SAOP'' THEN f.IncomingQuantity ELSE 0 END)
    FROM filtered AS f
    GROUP BY f.GroupKey
  ),
  final AS
  (
    SELECT aggregated.*,
      CombinedQuantity = aggregated.ErpQuantity + aggregated.SupplierQuantity,
      CombinedIncoming = ISNULL(NULLIF(aggregated.ErpOwnIncoming, 0), delivery.Quantity) + ISNULL(aggregated.SupplierIncoming, 0)
    FROM aggregated
    LEFT JOIN delivery ON delivery.OrganizationId = aggregated.OrganizationId AND delivery.NormalizedItemId = aggregated.NormalizedItemId
  )
  SELECT TotalCount = COUNT_BIG(*)
  FROM final
  WHERE
  (
    @Availability IS NULL
    OR (@Availability = N''IN_STOCK'' AND CombinedQuantity > 0)
    OR (@Availability = N''OUT_OF_STOCK'' AND CombinedQuantity <= 0)
    OR (@Availability = N''INCOMING'' AND CombinedIncoming > 0)
  )
  OPTION (RECOMPILE);
END;');

/* --- dokaz ------------------------------------------------------------------------------ */

IF OBJECT_ID(N'intranet.GetStockByItem', N'P') IS NULL THROW 51900, N'190: intranet.GetStockByItem ni nastala.', 1;

DECLARE @ProbeOrganizationId int = (SELECT MIN(OrganizationId) FROM dbo.OrganizationConfig);
IF @ProbeOrganizationId IS NOT NULL
  EXEC intranet.GetStockByItem @OrganizationId = @ProbeOrganizationId, @Skip = 0, @Take = 5;
