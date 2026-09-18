/*
  189 — SAOP GetItemDeliveryDate: pravi datum in kolicina prihoda nase (SAOP) zaloge.

  Uporabnik, dobesedno: »ja iz SAOPja beremo datume samo je drug endpoint kot zaloge poisci ga
  ... ina ga morava brati te datume prihoda pa kolicine pri nas«.

  GetStocks in registrirani pogled (migracija 145) datuma in kolicine prihoda ne poznata — glej
  opombo v SaopStockRunner.cs ("EAN, datum razpolozljivosti in prihajajoca kolicina so pri
  dobaviteljih, ne tu"). Pravi vir je locen SAOP klic GET api/Item/GetItemDeliveryDate, en
  artikel naenkrat (referencna postavitev: Desktop/PIM_test, glej nacrt). Ta migracija postavi
  samo bralno-zapisovalno tabelo za tisti zajem in ju spoji v obstojeci izvoz zaloge; sam zajem
  (SaopStockRunner.RunItemDeliveryDatesAsync) je locena sprememba v PIM.SaopStockWorker.

  Zakaj dve tabeli:
    stock.ItemDeliveryDate  — vrstice dobav (lahko vec na artikel, kot GetItemDeliveryDate vrne).
    stock.ItemDeliveryCheck — kdaj je bil artikel nazadnje vprasan; brez GetStockAdvance kot
      filtra (uporabnik: "stock advance tega ne rabiva") zajem krozi cez cel katalog po
      CheckedUtc (nikoli vprasani najprej), zato rabi loceno sled tudi za artikle brez dobave.

  Migracija je ponovljiva: CREATE TABLE samo, ce ne obstaja; CREATE OR ALTER za proceduro.
*/

SET XACT_ABORT ON;

IF OBJECT_ID(N'stock.ItemDeliveryDate', N'U') IS NULL
BEGIN
  CREATE TABLE stock.ItemDeliveryDate
  (
    ItemDeliveryDateId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_ItemDeliveryDate PRIMARY KEY,
    OrganizationId int NOT NULL,
    NormalizedItemId nvarchar(200) NOT NULL,  -- isti kljuc kot stock.Position.NormalizedItemId
    DeliveryDate datetime2(3) NULL,
    Quantity decimal(18,4) NULL,
    CheckedUtc datetime2(3) NOT NULL,
    CONSTRAINT FK_ItemDeliveryDate_Organization FOREIGN KEY (OrganizationId) REFERENCES dbo.OrganizationConfig (OrganizationId)
  );
  CREATE INDEX IX_ItemDeliveryDate_Lookup ON stock.ItemDeliveryDate (OrganizationId, NormalizedItemId);
END;

IF OBJECT_ID(N'stock.ItemDeliveryCheck', N'U') IS NULL
BEGIN
  CREATE TABLE stock.ItemDeliveryCheck
  (
    OrganizationId int NOT NULL,
    NormalizedItemId nvarchar(200) NOT NULL,
    CheckedUtc datetime2(3) NOT NULL,
    CONSTRAINT PK_ItemDeliveryCheck PRIMARY KEY (OrganizationId, NormalizedItemId),
    CONSTRAINT FK_ItemDeliveryCheck_Organization FOREIGN KEY (OrganizationId) REFERENCES dbo.OrganizationConfig (OrganizationId)
  );
END;

/* out.GetStockExportRows (150, razsirjena v 151): za SAOP vrstice (position.AvailabilityDate in
   position.IncomingQuantity sta tam vedno NULL, glej zgoraj) doda COALESCE iz stock.ItemDeliveryDate.
   Dobaviteljeve vrstice imajo svoj pravi vir in ostanejo nespremenjene — COALESCE poseze samo,
   kadar je vrednost iz pozicije NULL. */
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

  ;WITH delivery AS
  (
    SELECT OrganizationId, NormalizedItemId,
      DeliveryDate = MIN(DeliveryDate), Quantity = SUM(ISNULL(Quantity, 0))
    FROM stock.ItemDeliveryDate
    WHERE OrganizationId = @OrganizationId
    GROUP BY OrganizationId, NormalizedItemId
  ),
  rows AS
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
      IncomingQuantity = COALESCE(position.IncomingQuantity, delivery.Quantity),
      AvailabilityDate = COALESCE(position.AvailabilityDate, delivery.DeliveryDate),
      snapshot.SnapshotUtc,
      Matched = CASE WHEN position.MatchedProductId IS NULL THEN 0 ELSE 1 END
    FROM stock.Position AS position
    INNER JOIN stock.Snapshot AS snapshot ON snapshot.SnapshotId = position.SnapshotId AND snapshot.IsActive = 1
    INNER JOIN map.SourceConnector AS connector ON connector.SourceConnectorId = snapshot.SourceConnectorId
    LEFT JOIN canon.Product AS product ON product.ProductId = position.MatchedProductId
    LEFT JOIN out.ExportStockSource AS registry
      ON registry.OrganizationId = @OrganizationId AND registry.StockOrganizationId = snapshot.OrganizationId
     AND registry.SourceCode = connector.SourceCode AND registry.IsActive = 1
    LEFT JOIN delivery ON delivery.OrganizationId = snapshot.OrganizationId AND delivery.NormalizedItemId = position.NormalizedItemId
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
        OR (@Availability = N''INCOMING'' AND COALESCE(position.IncomingQuantity, delivery.Quantity) > 0)
      )
      AND (@MaxAgeHours IS NULL OR snapshot.SnapshotUtc >= DATEADD(hour, -@MaxAgeHours, @Now))
      AND (@OnlyWeb = 0 OR (product.WebPublish = 1 AND EXISTS
        (SELECT 1 FROM pim.Product AS promoted
         INNER JOIN pim.ProductCategory AS category ON category.PimProductId = promoted.PimProductId
         WHERE promoted.OrganizationId = product.OrganizationId AND promoted.ItemID = product.ItemID)))
  )
  SELECT @TotalCount = COUNT(*) FROM rows;

  ;WITH delivery AS
  (
    SELECT OrganizationId, NormalizedItemId,
      DeliveryDate = MIN(DeliveryDate), Quantity = SUM(ISNULL(Quantity, 0))
    FROM stock.ItemDeliveryDate
    WHERE OrganizationId = @OrganizationId
    GROUP BY OrganizationId, NormalizedItemId
  ),
  rows AS
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
      IncomingQuantity = COALESCE(position.IncomingQuantity, delivery.Quantity),
      AvailabilityDate = COALESCE(position.AvailabilityDate, delivery.DeliveryDate),
      snapshot.SnapshotUtc,
      Matched = CASE WHEN position.MatchedProductId IS NULL THEN 0 ELSE 1 END
    FROM stock.Position AS position
    INNER JOIN stock.Snapshot AS snapshot ON snapshot.SnapshotId = position.SnapshotId AND snapshot.IsActive = 1
    INNER JOIN map.SourceConnector AS connector ON connector.SourceConnectorId = snapshot.SourceConnectorId
    LEFT JOIN canon.Product AS product ON product.ProductId = position.MatchedProductId
    LEFT JOIN out.ExportStockSource AS registry
      ON registry.OrganizationId = @OrganizationId AND registry.StockOrganizationId = snapshot.OrganizationId
     AND registry.SourceCode = connector.SourceCode AND registry.IsActive = 1
    LEFT JOIN delivery ON delivery.OrganizationId = snapshot.OrganizationId AND delivery.NormalizedItemId = position.NormalizedItemId
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
        OR (@Availability = N''INCOMING'' AND COALESCE(position.IncomingQuantity, delivery.Quantity) > 0)
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

/* --- dokaz ------------------------------------------------------------------------------ */

IF OBJECT_ID(N'stock.ItemDeliveryDate', N'U') IS NULL THROW 51890, N'189: stock.ItemDeliveryDate ni nastala.', 1;
IF OBJECT_ID(N'stock.ItemDeliveryCheck', N'U') IS NULL THROW 51891, N'189: stock.ItemDeliveryCheck ni nastala.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'out.GetStockExportRows')) NOT LIKE N'%stock.ItemDeliveryDate%'
  THROW 51892, N'189: out.GetStockExportRows ne bere stock.ItemDeliveryDate.', 1;

DECLARE @ProbeOrganizationId int = (SELECT MIN(OrganizationId) FROM dbo.OrganizationConfig);
IF @ProbeOrganizationId IS NOT NULL
BEGIN
  DECLARE @ProbeTotal int;
  EXEC out.GetStockExportRows @OrganizationId = @ProbeOrganizationId, @Source = N'VSE', @OnlyWeb = 0, @Skip = 0, @Take = 1, @TotalCount = @ProbeTotal OUTPUT;
END;
