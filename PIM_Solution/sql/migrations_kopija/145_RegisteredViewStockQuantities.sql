/*
  145 — zaloga iz registriranega pogleda SAOP: pet kolicin, ne ena.

  Zakaj. Uporabnik 2026-09-02: "zaloga VID se bere iz registeredview endpointa, za IQ pa iz
  GetStocks, ker SAOP registriranega pogleda za IQ ni omogocil." Stari sistem (PIM_test,
  SaopStockWorker) je registrirani pogled 16c34ea5-b65d-4954-a699-40f47af11243 bral vsako
  minuto in iz vsake vrstice vzel pet stevil:

      TrenutnaZalogaL, NarocenaKolicina, ZaOdpremoKolicina,
      RazpolozljivaKolicina, NarocenaKolicinaDobaviteljem

  To so natanko stolpci 43-47 spletnega izvoza ("VID trenutna zaloga" ... "VID narocena
  kolicina dobaviteljem"), ki so v registru out.ExportColumn od migracije 045 brez vira.

  NoviPIM je imel za Vidadrio vrstico SAOP_REGISTERED_VIEW v stock.SaopProviderProfile ze od
  migracije 065, a izklopljeno in brez RegisteredViewId; model zaloge pa pozna samo kolicino,
  datum razpolozljivosti in prihajajoco kolicino. Ta migracija:

    1. doda stock.LandingRecord stiri besedilne stolpce in stock.Position stiri stevilske
       stolpce za dodatne kolicine (NULL pri virih, ki jih ne poznajo — GetStocks, NW, BT);
    2. stock.ApplyLandingRecord jih prenese iz besedila v stevilo s TRY_CONVERT (tako kot
       stari usp_pim_LoadExportStock_FromRegisteredViewAndNw); neveljavno besedilo tu ni
       razlog za karanteno, ker je glavna kolicina se vedno TrenutnaZalogaL;
    3. vklopi registrirani pogled za Vidadrio (Priority 5 pred GetStocks 10, zato ga worker
       izbere sam); IQLighting ostane na GetStocks nad skladiscem 0000001 (Brnciceva 13);
    4. intranet.GetStockPositions vrne nove kolicine, da jih /zaloge lahko pokaze.

  Kar ta migracija namenoma NE dela: ne sesteva zalog med podjetji — to je pravilo izvoza
  in pride z migracijo 146, kjer stoji skupaj z registrom izvoza.

  Migrator ne pozna locila GO; procedure so v EXEC(N'...'), stolpci pa nastanejo pred
  njimi, zato se prevedejo.
*/

SET XACT_ABORT ON;

/* --- 1) Stolpci -------------------------------------------------------------------- */

IF COL_LENGTH(N'stock.LandingRecord', N'OrderedQuantityText') IS NULL
  ALTER TABLE stock.LandingRecord ADD
    OrderedQuantityText nvarchar(100) NULL,
    ForShipmentQuantityText nvarchar(100) NULL,
    AvailableQuantityText nvarchar(100) NULL,
    SupplierOrderedQuantityText nvarchar(100) NULL;

IF COL_LENGTH(N'stock.Position', N'OrderedQuantity') IS NULL
  ALTER TABLE stock.Position ADD
    OrderedQuantity decimal(19,4) NULL,
    ForShipmentQuantity decimal(19,4) NULL,
    AvailableQuantity decimal(19,4) NULL,
    SupplierOrderedQuantity decimal(19,4) NULL;

/* --- 2) stock.ApplyLandingRecord — enako kot 088, plus stiri kolicine --------------- */

EXEC(N'CREATE OR ALTER PROCEDURE stock.ApplyLandingRecord @LandingRecordId bigint, @DateFormat nvarchar(30)=N''yyyy-MM-dd''
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  DECLARE @Quantity decimal(19,4), @Incoming decimal(19,4), @Date date, @Identity nvarchar(450), @Ean nvarchar(100), @Reason nvarchar(50), @OrganizationId int;
  DECLARE @Ordered decimal(19,4), @ForShipment decimal(19,4), @Available decimal(19,4), @SupplierOrdered decimal(19,4);
  SELECT @Quantity=TRY_CONVERT(decimal(19,4),NULLIF(REPLACE(QuantityText,NCHAR(0),N''''),N'''')),
    @Incoming=TRY_CONVERT(decimal(19,4),NULLIF(REPLACE(IncomingQuantityText,NCHAR(0),N''''),N'''')),
    @Date=CASE WHEN NULLIF(REPLACE(AvailabilityDateText,NCHAR(0),N''''),N'''') IS NULL THEN NULL
      WHEN @DateFormat=N''yyyy-MM-dd'' THEN TRY_CONVERT(date,REPLACE(AvailabilityDateText,NCHAR(0),N''''),23)
      WHEN @DateFormat=N''dd.MM.yyyy'' THEN TRY_CONVERT(date,REPLACE(AvailabilityDateText,NCHAR(0),N''''),104) END,
    @Identity=NULLIF(LTRIM(RTRIM(NormalizedItemId)),N''''), @Ean=NULLIF(LTRIM(RTRIM(Ean)),N''''),
    @OrganizationId=OrganizationId,
    /* Dodatne kolicine registriranega pogleda. Neveljavno besedilo da NULL, ne karantene:
       vrstica je veljavna, dokler ima glavno kolicino. */
    @Ordered=TRY_CONVERT(decimal(19,4),NULLIF(REPLACE(OrderedQuantityText,NCHAR(0),N''''),N'''')),
    @ForShipment=TRY_CONVERT(decimal(19,4),NULLIF(REPLACE(ForShipmentQuantityText,NCHAR(0),N''''),N'''')),
    @Available=TRY_CONVERT(decimal(19,4),NULLIF(REPLACE(AvailableQuantityText,NCHAR(0),N''''),N'''')),
    @SupplierOrdered=TRY_CONVERT(decimal(19,4),NULLIF(REPLACE(SupplierOrderedQuantityText,NCHAR(0),N''''),N''''))
  FROM stock.LandingRecord WHERE LandingRecordId=@LandingRecordId AND Status=N''Pending'';
  IF @@ROWCOUNT=0 RETURN;
  SET @Reason=CASE WHEN @Identity IS NULL AND @Ean IS NULL THEN N''MissingIdentity''
    WHEN @Quantity IS NULL THEN N''InvalidQuantity'' WHEN @Quantity<0 THEN N''NegativeQuantity''
    WHEN NULLIF(REPLACE((SELECT AvailabilityDateText FROM stock.LandingRecord WHERE LandingRecordId=@LandingRecordId),NCHAR(0),N''''),N'''') IS NOT NULL AND @Date IS NULL THEN N''InvalidDate'' END;
  IF @Reason IS NOT NULL
  BEGIN
    INSERT stock.UnmatchedPosition(LandingRecordId,ReasonCode,Detail) VALUES(@LandingRecordId,@Reason,N''Zapis ni prestal genericne normalizacije.'');
    UPDATE stock.LandingRecord SET Status=N''Quarantined'',FailureReason=@Reason WHERE LandingRecordId=@LandingRecordId; RETURN;
  END;
  DECLARE @SnapshotId bigint=(SELECT SnapshotId FROM stock.Snapshot s JOIN stock.LandingRecord l ON l.SyncRunId=s.SyncRunId AND l.OrganizationId=s.OrganizationId AND l.SourceConnectorId=s.SourceConnectorId AND l.SnapshotUtc=s.SnapshotUtc WHERE l.LandingRecordId=@LandingRecordId);
  /* Artikel mora biti iz istega podjetja kot vhodna vrstica (088). */
  DECLARE @ProductId bigint=(SELECT TOP(1) ProductId FROM canon.Product
    WHERE OrganizationId=@OrganizationId AND (ItemID=@Identity OR (@Identity IS NULL AND EAN=@Ean))
    ORDER BY CASE WHEN ItemID=@Identity THEN 0 ELSE 1 END);
  INSERT stock.Position(SnapshotId,LandingRecordId,NormalizedItemId,Ean,Quantity,AvailabilityDate,IncomingQuantity,MatchKey,MatchedProductId,
    OrderedQuantity,ForShipmentQuantity,AvailableQuantity,SupplierOrderedQuantity)
  VALUES(@SnapshotId,@LandingRecordId,@Identity,@Ean,@Quantity,@Date,@Incoming,CASE WHEN @ProductId IS NULL THEN N''Unmatched'' WHEN EXISTS(SELECT 1 FROM canon.Product WHERE ProductId=@ProductId AND ItemID=@Identity) THEN N''ItemID'' ELSE N''EAN'' END,@ProductId,
    @Ordered,@ForShipment,@Available,@SupplierOrdered);
  UPDATE stock.LandingRecord SET Status=N''Applied'' WHERE LandingRecordId=@LandingRecordId;
END');

/* --- 3) Registrirani pogled za Vidadrio ---------------------------------------------- */

/* GUID pogleda je iz delujoce nastavitve starega sistema
   (PIM_test\Windows_services\SAOP_API_WS\SaopStockWorker\appsettings.json, RegisteredViewId).
   Vrstica obstaja od migracije 065; tu dobi ID in se vklopi. Ce bi je ne bilo, jo naredimo. */
IF EXISTS (SELECT 1 FROM stock.SaopProviderProfile WHERE OrganizationId = 3 AND ProfileCode = N'SAOP_REGISTERED_VIEW')
  UPDATE stock.SaopProviderProfile
  SET RegisteredViewId = N'16c34ea5-b65d-4954-a699-40f47af11243', Enabled = 1, Priority = 5
  WHERE OrganizationId = 3 AND ProfileCode = N'SAOP_REGISTERED_VIEW';
ELSE
  INSERT stock.SaopProviderProfile (OrganizationId, ProfileCode, ProviderKind, Priority, Enabled, RegisteredViewId, WarehouseSelectionMode)
  VALUES (3, N'SAOP_REGISTERED_VIEW', N'RegisteredViewData', 5, 1, N'16c34ea5-b65d-4954-a699-40f47af11243', N'List');

/* --- 4) Bralni model zalog vrne nove kolicine ---------------------------------------- */

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
        OR (@Availability = N''INCOMING'' AND (position.IncomingQuantity > 0 OR position.SupplierOrderedQuantity > 0))
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
    SourceKind = CASE WHEN connector.ConnectorType = N''SAOP'' THEN N''ERP'' ELSE N''DOBAVITELJ'' END,
    snapshot.ProviderKind, snapshot.Endpoint, snapshot.SnapshotUtc,
    FreshnessMinutes = DATEDIFF(minute, snapshot.SnapshotUtc, @Now),
    MinimumStock = policy.MinimumStock, MaximumStock = policy.MaximumStock,
    WarehouseCode = policy.WarehouseCode,
    /* Registrirani pogled (145): NULL pri virih, ki teh kolicin ne poznajo. */
    position.OrderedQuantity, position.ForShipmentQuantity, position.AvailableQuantity, position.SupplierOrderedQuantity
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
      OR (@Availability = N''INCOMING'' AND (position.IncomingQuantity > 0 OR position.SupplierOrderedQuantity > 0))
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

/* --- dokaz ----------------------------------------------------------------------- */

IF COL_LENGTH(N'stock.Position', N'AvailableQuantity') IS NULL
  THROW 51450, N'145: stock.Position nima stolpca AvailableQuantity.', 1;
IF COL_LENGTH(N'stock.LandingRecord', N'SupplierOrderedQuantityText') IS NULL
  THROW 51451, N'145: stock.LandingRecord nima stolpca SupplierOrderedQuantityText.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'stock.ApplyLandingRecord')) NOT LIKE N'%SupplierOrderedQuantityText%'
  THROW 51452, N'145: stock.ApplyLandingRecord ne prenasa dodatnih kolicin.', 1;
IF NOT EXISTS (SELECT 1 FROM stock.SaopProviderProfile
               WHERE OrganizationId = 3 AND ProfileCode = N'SAOP_REGISTERED_VIEW' AND Enabled = 1
                 AND RegisteredViewId = N'16c34ea5-b65d-4954-a699-40f47af11243' AND Priority < 10)
  THROW 51453, N'145: registrirani pogled za Vidadrio ni vklopljen pred GetStocks.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'intranet.GetStockPositions')) NOT LIKE N'%position.SupplierOrderedQuantity%'
  THROW 51454, N'145: intranet.GetStockPositions ne vraca dodatnih kolicin.', 1;
