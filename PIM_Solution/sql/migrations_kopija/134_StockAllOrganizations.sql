/*
  134 — zaloga zna prikazati vsa podjetja hkrati.

  Zahteva uporabnika 2026-08-31:

    »Zakaj zalogo prikazuje samo dobavitelja in SAOP DEMO, dej da bo se ostale zaloge
     prikazovalo od SAOP (IQ, VID, Ediito)«

  Merjeno stanje: SAOP zaloga obstaja pri vseh stirih podjetjih —
  SAOP_DEMO_STOCK 16 pozicij, SAOP_IQLIGHTING_STOCK 8.719, SAOP_VIDADRIA_STOCK 7.002 in
  SAOP_EDIITO_STOCK 3.105. Stran je videla samo prvo podjetje po sifri, ker je proceduri
  vedno podala eno organizacijo.

  Popravek je isti kot pri seznamu izdelkov (migracija 108): @OrganizationId sme biti NULL
  in takrat pomeni vsa podjetja. Vrstica dobi se podjetje, ker pri vec podjetjih brez njega
  ni jasno, cigava zaloga je to.

  Obe proceduri samo bereta. Migracija je ponovljiva: CREATE OR ALTER.
*/

SET XACT_ABORT ON;

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetStockPositions
  @OrganizationId int = NULL,
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
    WHERE (@OrganizationId IS NULL OR snapshot.OrganizationId = @OrganizationId) AND snapshot.IsActive = 1
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
    snapshot.OrganizationId,
    OrganizationName = COALESCE(organizationValue.Name, CONVERT(nvarchar(200), snapshot.OrganizationId)),
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
  LEFT JOIN dbo.OrganizationConfig AS organizationValue ON organizationValue.OrganizationId = snapshot.OrganizationId
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
  WHERE (@OrganizationId IS NULL OR snapshot.OrganizationId = @OrganizationId) AND snapshot.IsActive = 1
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

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetStockOverview
  @OrganizationId int = NULL
AS
BEGIN
  SET NOCOUNT ON;
  DECLARE @Now datetime2(3) = SYSUTCDATETIME();

  /* 1 — koliko je zaloge in koliko je od nje uporabne. */
  SELECT
    PositionCount = COUNT_BIG(*),
    MatchedCount = SUM(CASE WHEN position.MatchedProductId IS NULL THEN 0 ELSE 1 END),
    UnmatchedCount = SUM(CASE WHEN position.MatchedProductId IS NULL THEN 1 ELSE 0 END),
    InStockCount = SUM(CASE WHEN position.Quantity > 0 THEN 1 ELSE 0 END),
    OutOfStockCount = SUM(CASE WHEN position.Quantity <= 0 THEN 1 ELSE 0 END),
    IncomingCount = SUM(CASE WHEN position.IncomingQuantity > 0 THEN 1 ELSE 0 END),
    OldestSnapshotUtc = MIN(snapshot.SnapshotUtc),
    NewestSnapshotUtc = MAX(snapshot.SnapshotUtc)
  FROM stock.Position AS position
  INNER JOIN stock.Snapshot AS snapshot ON snapshot.SnapshotId = position.SnapshotId
  WHERE (@OrganizationId IS NULL OR snapshot.OrganizationId = @OrganizationId) AND snapshot.IsActive = 1;

  /* 2 — po viru: svezina je lastnost vira, ne celotne zaloge. */
  SELECT connector.SourceCode, snapshot.ProviderKind, snapshot.Endpoint,
    SnapshotUtc = MAX(snapshot.SnapshotUtc),
    FreshnessMinutes = DATEDIFF(minute, MAX(snapshot.SnapshotUtc), @Now),
    PositionCount = COUNT_BIG(*),
    MatchedCount = SUM(CASE WHEN position.MatchedProductId IS NULL THEN 0 ELSE 1 END),
    InStockCount = SUM(CASE WHEN position.Quantity > 0 THEN 1 ELSE 0 END)
  FROM stock.Position AS position
  INNER JOIN stock.Snapshot AS snapshot ON snapshot.SnapshotId = position.SnapshotId
  INNER JOIN map.SourceConnector AS connector ON connector.SourceConnectorId = snapshot.SourceConnectorId
  WHERE (@OrganizationId IS NULL OR snapshot.OrganizationId = @OrganizationId) AND snapshot.IsActive = 1
  GROUP BY connector.SourceCode, snapshot.ProviderKind, snapshot.Endpoint
  ORDER BY connector.SourceCode, snapshot.Endpoint;

  /* 3 — izpeljane tezave: nastanejo iz podatka in izginejo z njim, zato jih ni mogoce
     rocno zapreti. Zavrnjena pozicija pove razlog, ne le da je bila zavrnjena. */
  SELECT unmatched.ReasonCode,
    PositionCount = COUNT_BIG(*),
    FirstSeenUtc = MIN(unmatched.CreatedUtc),
    LastSeenUtc = MAX(unmatched.CreatedUtc),
    SampleDetail = MIN(unmatched.Detail)
  FROM stock.UnmatchedPosition AS unmatched
  INNER JOIN stock.LandingRecord AS landing ON landing.LandingRecordId = unmatched.LandingRecordId
  WHERE landing.OrganizationId = @OrganizationId
  GROUP BY unmatched.ReasonCode
  ORDER BY COUNT_BIG(*) DESC, unmatched.ReasonCode;
END;');
