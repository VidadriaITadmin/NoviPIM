/*
  151 — prenos zaloge (CSV) uposteva iste filtre kot tabela na /zaloge.

  Uporabnik 2026-09-03, dobesedno:

    »Zaloge: filtri malo niso jasni okej najprej izbereš podjetje, nato pa iz katerega vira
     je prišel ... Potem preneseš predlogo bi bilo vbolje da filtre nastaviš in potem predlogo
     prenesš ne pa da imaš filtre in nado lahko kar vse preneseš«

  Prenos je bil odvisen samo od podjetja (migracija 150): tri stalne povezave ERP / DOBAVITELJ /
  VSE in loceno polje »Obseg izvoza«, oboje mimo filtrov Vir / Vrsta vira / Svezina / iskanje, ki
  jih uporabnik nastavi nad tabelo. Zato je slo prenesti vse, tudi ko so bili filtri nastavljeni.

  out.GetStockExportRows dobi ista polja, kot jih ze pozna intranet.GetStockPositions (migracija
  134): @SourceCode (dolocen vir), @Search (artikel/EAN), @Availability (IN_STOCK/OUT_OF_STOCK/
  INCOMING) in @MaxAgeHours (svezina posnetka). @Source (ERP/DOBAVITELJ/VSE) in @OnlyWeb ostaneta,
  ker izvoz po njiju se vedno loci datoteko po vrsti vira. Intranet (loceno ozemlje) nato ukine
  loceno tri-gumbno izbiro in en gumb prenese natanko to, kar je filtrirano na strani.

  Procedura samo bere. Migracija je ponovljiva: CREATE OR ALTER.
*/

SET XACT_ABORT ON;

EXEC(N'CREATE OR ALTER PROCEDURE out.GetStockExportRows
  @OrganizationId int,
  @Source nvarchar(20) = N''VSE'',     /* ERP | DOBAVITELJ | VSE */
  @OnlyWeb bit = 0,                    /* samo izdelki s spletno stranjo in objavo */
  @SourceCode nvarchar(100) = NULL,    /* dolocen vir (npr. SAOP_DEMO_STOCK), NULL = vsi v obsegu @Source */
  @Search nvarchar(200) = NULL,        /* artikel ali EAN, kot iskanje na tabeli */
  @Availability nvarchar(20) = NULL,   /* IN_STOCK | OUT_OF_STOCK | INCOMING, NULL = vseeno */
  @MaxAgeHours int = NULL,             /* svezina posnetka, kot filter na tabeli */
  @Skip int = 0,
  @Take int = 0,                       /* 0 = vse */
  @TotalCount int OUTPUT
AS
BEGIN
  SET NOCOUNT ON;
  SET @Source = ISNULL(NULLIF(UPPER(LTRIM(RTRIM(@Source))), N''''), N''VSE'');
  IF @Source NOT IN (N''ERP'', N''DOBAVITELJ'', N''VSE'') THROW 51520, N''Vir mora biti ERP, DOBAVITELJ ali VSE.'', 1;
  SET @SourceCode = NULLIF(LTRIM(RTRIM(@SourceCode)), N'''');
  SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'''');
  SET @Availability = NULLIF(UPPER(LTRIM(RTRIM(@Availability))), N'''');
  IF @Availability NOT IN (N''IN_STOCK'', N''OUT_OF_STOCK'', N''INCOMING'') SET @Availability = NULL;
  IF @MaxAgeHours IS NOT NULL AND @MaxAgeHours < 1 SET @MaxAgeHours = NULL;
  IF @Skip < 0 SET @Skip = 0;
  DECLARE @Fetch bigint = CASE WHEN @Take <= 0 THEN 2147483647 ELSE @Take END;
  DECLARE @Like nvarchar(210) = CASE WHEN @Search IS NULL THEN NULL ELSE N''%'' + @Search + N''%'' END;
  DECLARE @Now datetime2(3) = SYSUTCDATETIME();

  ;WITH rows AS
  (
    SELECT position.PositionId,
      ItemID = COALESCE(product.ItemID, position.NormalizedItemId),
      EAN = COALESCE(product.EAN, position.Ean),
      Name = title.Value,
      SourceKind = CASE WHEN connector.ConnectorType = N''SAOP'' THEN N''ERP'' ELSE N''DOBAVITELJ'' END,
      connector.SourceCode,
      Warehouse = CASE WHEN connector.ConnectorType = N''SAOP'' THEN registry.WarehouseLabel END,
      position.Quantity,
      Available = COALESCE(position.AvailableQuantity, position.Quantity),
      position.OrderedQuantity, position.ForShipmentQuantity, position.SupplierOrderedQuantity,
      position.IncomingQuantity, position.AvailabilityDate,
      snapshot.SnapshotUtc,
      Matched = CASE WHEN position.MatchedProductId IS NULL THEN 0 ELSE 1 END
    FROM stock.Position AS position
    INNER JOIN stock.Snapshot AS snapshot ON snapshot.SnapshotId = position.SnapshotId AND snapshot.IsActive = 1
    INNER JOIN map.SourceConnector AS connector ON connector.SourceConnectorId = snapshot.SourceConnectorId
    LEFT JOIN canon.Product AS product ON product.ProductId = position.MatchedProductId
    LEFT JOIN out.ExportStockSource AS registry
      ON registry.OrganizationId = @OrganizationId AND registry.StockOrganizationId = snapshot.OrganizationId
     AND registry.SourceCode = connector.SourceCode AND registry.IsActive = 1
    OUTER APPLY
    (
      SELECT TOP (1) textValue.Value FROM canon.ProductText AS textValue
      WHERE textValue.ProductId = product.ProductId AND textValue.TextType IN (N''WEB_TITLE'', N''TITLE_ERP'')
      ORDER BY CASE WHEN textValue.TextType = N''WEB_TITLE'' THEN 0 ELSE 1 END, CASE WHEN textValue.Lang = N''sl'' THEN 0 ELSE 1 END, textValue.Lang
    ) AS title
    WHERE snapshot.OrganizationId = @OrganizationId
      AND (@Source = N''VSE'' OR (@Source = N''ERP'' AND connector.ConnectorType = N''SAOP'') OR (@Source = N''DOBAVITELJ'' AND connector.ConnectorType <> N''SAOP''))
      AND (@SourceCode IS NULL OR connector.SourceCode = @SourceCode)
      AND (@Like IS NULL OR position.NormalizedItemId LIKE @Like OR position.Ean LIKE @Like OR product.ItemID LIKE @Like OR product.EAN LIKE @Like)
      AND
      (
        @Availability IS NULL
        OR (@Availability = N''IN_STOCK'' AND position.Quantity > 0)
        OR (@Availability = N''OUT_OF_STOCK'' AND position.Quantity <= 0)
        OR (@Availability = N''INCOMING'' AND position.IncomingQuantity > 0)
      )
      AND (@MaxAgeHours IS NULL OR snapshot.SnapshotUtc >= DATEADD(hour, -@MaxAgeHours, @Now))
      AND (@OnlyWeb = 0 OR (product.WebPublish = 1 AND EXISTS
        (SELECT 1 FROM pim.Product AS promoted
         INNER JOIN pim.ProductCategory AS category ON category.PimProductId = promoted.PimProductId
         WHERE promoted.OrganizationId = product.OrganizationId AND promoted.ItemID = product.ItemID)))
  )
  SELECT @TotalCount = COUNT(*) FROM rows;

  ;WITH rows AS
  (
    SELECT position.PositionId,
      ItemID = COALESCE(product.ItemID, position.NormalizedItemId),
      EAN = COALESCE(product.EAN, position.Ean),
      Name = title.Value,
      SourceKind = CASE WHEN connector.ConnectorType = N''SAOP'' THEN N''ERP'' ELSE N''DOBAVITELJ'' END,
      connector.SourceCode,
      Warehouse = CASE WHEN connector.ConnectorType = N''SAOP'' THEN registry.WarehouseLabel END,
      position.Quantity,
      Available = COALESCE(position.AvailableQuantity, position.Quantity),
      position.OrderedQuantity, position.ForShipmentQuantity, position.SupplierOrderedQuantity,
      position.IncomingQuantity, position.AvailabilityDate,
      snapshot.SnapshotUtc,
      Matched = CASE WHEN position.MatchedProductId IS NULL THEN 0 ELSE 1 END
    FROM stock.Position AS position
    INNER JOIN stock.Snapshot AS snapshot ON snapshot.SnapshotId = position.SnapshotId AND snapshot.IsActive = 1
    INNER JOIN map.SourceConnector AS connector ON connector.SourceConnectorId = snapshot.SourceConnectorId
    LEFT JOIN canon.Product AS product ON product.ProductId = position.MatchedProductId
    LEFT JOIN out.ExportStockSource AS registry
      ON registry.OrganizationId = @OrganizationId AND registry.StockOrganizationId = snapshot.OrganizationId
     AND registry.SourceCode = connector.SourceCode AND registry.IsActive = 1
    OUTER APPLY
    (
      SELECT TOP (1) textValue.Value FROM canon.ProductText AS textValue
      WHERE textValue.ProductId = product.ProductId AND textValue.TextType IN (N''WEB_TITLE'', N''TITLE_ERP'')
      ORDER BY CASE WHEN textValue.TextType = N''WEB_TITLE'' THEN 0 ELSE 1 END, CASE WHEN textValue.Lang = N''sl'' THEN 0 ELSE 1 END, textValue.Lang
    ) AS title
    WHERE snapshot.OrganizationId = @OrganizationId
      AND (@Source = N''VSE'' OR (@Source = N''ERP'' AND connector.ConnectorType = N''SAOP'') OR (@Source = N''DOBAVITELJ'' AND connector.ConnectorType <> N''SAOP''))
      AND (@SourceCode IS NULL OR connector.SourceCode = @SourceCode)
      AND (@Like IS NULL OR position.NormalizedItemId LIKE @Like OR position.Ean LIKE @Like OR product.ItemID LIKE @Like OR product.EAN LIKE @Like)
      AND
      (
        @Availability IS NULL
        OR (@Availability = N''IN_STOCK'' AND position.Quantity > 0)
        OR (@Availability = N''OUT_OF_STOCK'' AND position.Quantity <= 0)
        OR (@Availability = N''INCOMING'' AND position.IncomingQuantity > 0)
      )
      AND (@MaxAgeHours IS NULL OR snapshot.SnapshotUtc >= DATEADD(hour, -@MaxAgeHours, @Now))
      AND (@OnlyWeb = 0 OR (product.WebPublish = 1 AND EXISTS
        (SELECT 1 FROM pim.Product AS promoted
         INNER JOIN pim.ProductCategory AS category ON category.PimProductId = promoted.PimProductId
         WHERE promoted.OrganizationId = product.OrganizationId AND promoted.ItemID = product.ItemID)))
  )
  SELECT ItemID, EAN, Name, SourceKind, SourceCode, Warehouse,
    Quantity = out.MagentoNumber(Quantity), Available = out.MagentoNumber(Available),
    OrderedQuantity = out.MagentoNumber(OrderedQuantity), ForShipmentQuantity = out.MagentoNumber(ForShipmentQuantity),
    SupplierOrderedQuantity = out.MagentoNumber(SupplierOrderedQuantity), IncomingQuantity = out.MagentoNumber(IncomingQuantity),
    AvailabilityDate = CONVERT(nvarchar(10), AvailabilityDate, 104),
    SnapshotUtc = CONVERT(nvarchar(19), SnapshotUtc, 120),
    Matched
  FROM rows
  ORDER BY SourceKind, SourceCode, ItemID, PositionId
  OFFSET @Skip ROWS FETCH NEXT @Fetch ROWS ONLY;
END');
