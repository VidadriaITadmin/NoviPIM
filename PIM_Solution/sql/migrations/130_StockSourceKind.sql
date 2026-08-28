/*
  130 — zaloga loci ERP (SAOP) od dobaviteljevih virov.

  Zahteva uporabnika 2026-08-28:

    »Zaloga – tukaj mi zalogo prikazuje samo od dobaviteljev, kje je pa se SAOP zaloga«

  Merjeno stanje: SAOP zaloga JE v bazi in JE bila na strani — pri organizaciji 1 ima
  SAOP_DEMO_STOCK 16 pozicij, BT_STOCK in NW_STOCK pa skupaj 4.155. SAOP zaloga se je torej
  izgubila med dobaviteljevimi vrsticami in je ni bilo mogoce lociti: seznam je poznal samo
  sifro vira (SAOP_DEMO_STOCK, NW_STOCK), ne pa vrste vira.

  Ta migracija zato doda vrsto vira: SAOP konektor je ERP, vsak drug je dobaviteljev.
  Vrsta pride v izpis kot stolpec in postane filter, ki se sestavlja z vsemi ostalimi.
  Merilo je map.SourceConnector.ConnectorType — isti stolpec, po katerem je vir registriran;
  seznam sifer v kodi bi se z registrom slej ko prej razsel.

  Procedura nicesar ne pise. Migracija je ponovljiva: CREATE OR ALTER.
*/

SET XACT_ABORT ON;

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetStockPositions
  @OrganizationId int,
  @Skip int = 0,
  @Take int = 50,
  @Search nvarchar(200) = NULL,
  @SourceCode nvarchar(100) = NULL,
  @Availability nvarchar(20) = NULL,
  @Matched nvarchar(20) = NULL,
  @MaxAgeHours int = NULL,
  @Language nvarchar(20) = N''sl'',
  @SourceKind nvarchar(20) = NULL
AS
BEGIN
  SET NOCOUNT ON;

  SET @Skip = CASE WHEN @Skip < 0 THEN 0 ELSE @Skip END;
  SET @Take = CASE WHEN @Take < 1 THEN 50 WHEN @Take > 200 THEN 200 ELSE @Take END;
  SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'''');
  SET @SourceCode = NULLIF(LTRIM(RTRIM(@SourceCode)), N'''');
  SET @Availability = NULLIF(UPPER(LTRIM(RTRIM(@Availability))), N'''');
  SET @Matched = NULLIF(UPPER(LTRIM(RTRIM(@Matched))), N'''');
  SET @Language = COALESCE(NULLIF(LTRIM(RTRIM(@Language)), N''''), N''sl'');
  IF @Availability NOT IN (N''IN_STOCK'', N''OUT_OF_STOCK'', N''INCOMING'') SET @Availability = NULL;
  IF @Matched NOT IN (N''MATCHED'', N''UNMATCHED'') SET @Matched = NULL;
  IF @MaxAgeHours IS NOT NULL AND @MaxAgeHours < 1 SET @MaxAgeHours = NULL;
  SET @SourceKind = NULLIF(UPPER(LTRIM(RTRIM(@SourceKind))), N'''');
  IF @SourceKind NOT IN (N''ERP'', N''DOBAVITELJ'') SET @SourceKind = NULL;

  DECLARE @Like nvarchar(210) = CASE WHEN @Search IS NULL THEN NULL ELSE N''%'' + @Search + N''%'' END;
  DECLARE @Now datetime2(3) = SYSUTCDATETIME();

  ;WITH filtered AS
  (
    SELECT position.PositionId, position.NormalizedItemId, position.Ean, connector.SourceCode
    FROM stock.Position AS position
    INNER JOIN stock.Snapshot AS snapshot ON snapshot.SnapshotId = position.SnapshotId
    INNER JOIN map.SourceConnector AS connector ON connector.SourceConnectorId = snapshot.SourceConnectorId
    WHERE snapshot.OrganizationId = @OrganizationId AND snapshot.IsActive = 1
      AND (@Like IS NULL OR position.NormalizedItemId LIKE @Like OR position.Ean LIKE @Like)
      AND (@SourceCode IS NULL OR connector.SourceCode = @SourceCode)
      AND
      (
        @SourceKind IS NULL
        OR (@SourceKind = N''ERP'' AND connector.ConnectorType = N''SAOP'')
        OR (@SourceKind = N''DOBAVITELJ'' AND connector.ConnectorType <> N''SAOP'')
      )
      AND
      (
        @Availability IS NULL
        OR (@Availability = N''IN_STOCK'' AND position.Quantity > 0)
        OR (@Availability = N''OUT_OF_STOCK'' AND position.Quantity <= 0)
        OR (@Availability = N''INCOMING'' AND position.IncomingQuantity > 0)
      )
      AND
      (
        @Matched IS NULL
        OR (@Matched = N''MATCHED'' AND position.MatchedProductId IS NOT NULL)
        OR (@Matched = N''UNMATCHED'' AND position.MatchedProductId IS NULL)
      )
      AND (@MaxAgeHours IS NULL OR snapshot.SnapshotUtc >= DATEADD(hour, -@MaxAgeHours, @Now))
  ),
  paged AS
  (
    SELECT filtered.PositionId
    FROM filtered
    ORDER BY filtered.SourceCode, filtered.NormalizedItemId, filtered.Ean, filtered.PositionId
    OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY
  )
  SELECT position.PositionId, position.NormalizedItemId, position.Ean,
    position.Quantity, position.AvailabilityDate, position.IncomingQuantity,
    position.MatchKey, position.MatchedProductId,
    ProductName = productTitle.Value,
    ProductItemId = matched.ItemID,
    connector.SourceCode,
    /* Vrsta vira: SAOP je ERP, vse ostalo je dobaviteljev vir. Uporabnik je 2026-08-28
       vprasal, kje je SAOP zaloga — bila je v seznamu, a je ni bilo mogoce lociti. */
    SourceKind = CASE WHEN connector.ConnectorType = N''SAOP'' THEN N''ERP'' ELSE N''DOBAVITELJ'' END,
    snapshot.ProviderKind, snapshot.Endpoint, snapshot.SnapshotUtc,
    FreshnessMinutes = DATEDIFF(minute, snapshot.SnapshotUtc, @Now),
    MinimumStock = policy.MinimumStock, MaximumStock = policy.MaximumStock,
    WarehouseCode = policy.WarehouseCode
  FROM paged
  INNER JOIN stock.Position AS position ON position.PositionId = paged.PositionId
  INNER JOIN stock.Snapshot AS snapshot ON snapshot.SnapshotId = position.SnapshotId
  INNER JOIN map.SourceConnector AS connector ON connector.SourceConnectorId = snapshot.SourceConnectorId
  LEFT JOIN canon.Product AS matched ON matched.ProductId = position.MatchedProductId
  OUTER APPLY
  (
    SELECT TOP (1) textValue.Value
    FROM canon.ProductText AS textValue
    WHERE textValue.ProductId = position.MatchedProductId AND textValue.TextType IN (N''WEB_TITLE'', N''TITLE_ERP'')
    ORDER BY CASE WHEN textValue.TextType = N''WEB_TITLE'' THEN 0 ELSE 1 END,
      CASE WHEN textValue.Lang = @Language THEN 0 WHEN textValue.Lang = N''sl'' THEN 1 ELSE 2 END, textValue.Lang
  ) AS productTitle
  OUTER APPLY
  (
    SELECT TOP (1) policyValue.WarehouseCode, policyValue.MinimumStock, policyValue.MaximumStock
    FROM canon.ProductStockPolicy AS policyValue
    WHERE policyValue.ProductId = position.MatchedProductId
    ORDER BY policyValue.WarehouseCode
  ) AS policy
  ORDER BY connector.SourceCode, position.NormalizedItemId, position.Ean, position.PositionId
  OPTION (RECOMPILE);

  SELECT TotalCount = COUNT_BIG(*)
  FROM stock.Position AS position
  INNER JOIN stock.Snapshot AS snapshot ON snapshot.SnapshotId = position.SnapshotId
  INNER JOIN map.SourceConnector AS connector ON connector.SourceConnectorId = snapshot.SourceConnectorId
  WHERE snapshot.OrganizationId = @OrganizationId AND snapshot.IsActive = 1
    AND (@Like IS NULL OR position.NormalizedItemId LIKE @Like OR position.Ean LIKE @Like)
    AND (@SourceCode IS NULL OR connector.SourceCode = @SourceCode)
    AND
    (
      @SourceKind IS NULL
      OR (@SourceKind = N''ERP'' AND connector.ConnectorType = N''SAOP'')
      OR (@SourceKind = N''DOBAVITELJ'' AND connector.ConnectorType <> N''SAOP'')
    )
    AND
    (
      @Availability IS NULL
      OR (@Availability = N''IN_STOCK'' AND position.Quantity > 0)
      OR (@Availability = N''OUT_OF_STOCK'' AND position.Quantity <= 0)
      OR (@Availability = N''INCOMING'' AND position.IncomingQuantity > 0)
    )
    AND
    (
      @Matched IS NULL
      OR (@Matched = N''MATCHED'' AND position.MatchedProductId IS NOT NULL)
      OR (@Matched = N''UNMATCHED'' AND position.MatchedProductId IS NULL)
    )
    AND (@MaxAgeHours IS NULL OR snapshot.SnapshotUtc >= DATEADD(hour, -@MaxAgeHours, @Now))
  OPTION (RECOMPILE);
END;');
