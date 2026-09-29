/*
  287 — Bralni API za analize in AI (shema api)

  Uporabnik 2026-09-26: »preglej bazo … ali je dobra baza za API, da se bo lahko AI na API povezal in bral
  podatke. Sestavi API za branje in iskanje artiklov, strank, cen in zaloge, da bo za analize, poročanje
  o zalogah, poročanje o cenah itd.«

  Kaj naredi:
    - shema api z BRALNIMI postopki nad canon/b2b/stock/purch/ana (izdelki, cene, zaloga, stranke,
      naročila dobaviteljem, analitika, svežina podatkov). Nič od tega ne piše v katalog, ne v SAOP.
    - api.Client: odjemalci API-ja (ključ je shranjen samo kot SHA-256, nikoli v čistopisu), dovoljena
      podjetja in področja; api.ClientHistory: kdo je ključ ustvaril, spremenil, preklical;
    - api.RequestLog: vsak klic (kdo, kdaj, kaj, koliko vrstic, koliko ms); hrani se 90 dni;
    - vloga pim_api_reader: sme SAMO izvajati postopke v shemi api (brez SELECT na tabele), skrbniški
      postopki api.Admin_* so ji izrecno prepovedani. API teče z uporabnikom v tej vlogi.

  Ročni korak: na strežniku dodaj uporabnika API-ja v vlogo (docs/API.md, razdelek »Namestitev«):
    CREATE USER [IIS APPPOOL\PIM-API] FOR LOGIN [IIS APPPOOL\PIM-API];
    ALTER ROLE pim_api_reader ADD MEMBER [IIS APPPOOL\PIM-API];
  Migrator ne pozna GO, zato CREATE OR ALTER v EXEC(N'...') (datoteka je sestavljena iz izvornika).
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

IF UNICODE(N'č') <> 269 THROW 52870, N'287: datoteka ni prebrana kot UTF-8 (šumniki).', 1;
IF OBJECT_ID(N'canon.Product', N'U') IS NULL OR OBJECT_ID(N'stock.Position', N'U') IS NULL
   OR OBJECT_ID(N'b2b.Customer', N'U') IS NULL OR OBJECT_ID(N'purch.PurchaseOrderLine', N'U') IS NULL
   OR OBJECT_ID(N'ana.ItemMetric', N'U') IS NULL OR OBJECT_ID(N'out.ExportPriceList', N'U') IS NULL
  THROW 52871, N'287 potrebuje migracije do 284 (ana.ItemMetric, purch, out.ExportPriceList).', 1;

IF SCHEMA_ID(N'api') IS NULL EXEC(N'CREATE SCHEMA api AUTHORIZATION dbo');

IF OBJECT_ID(N'api.Client', N'U') IS NULL
CREATE TABLE api.Client
(
  ClientId int IDENTITY(1, 1) NOT NULL CONSTRAINT PK_ApiClient PRIMARY KEY,
  Name nvarchar(200) NOT NULL,
  KeyPrefix nvarchar(16) NOT NULL,              /* prvih nekaj znakov ključa, samo za prepoznavo v seznamu */
  KeyHash binary(32) NOT NULL CONSTRAINT UQ_ApiClient_KeyHash UNIQUE,
  OrganizationIds nvarchar(200) NULL,           /* '2,3'; NULL = vsa aktivna podjetja */
  Scopes nvarchar(400) NOT NULL,                /* izdelki,cene,zaloga,stranke,nabava,analitika */
  RequestsPerMinute int NOT NULL CONSTRAINT DF_ApiClient_Rpm DEFAULT (120),
  IsActive bit NOT NULL CONSTRAINT DF_ApiClient_IsActive DEFAULT (1),
  ExpiresUtc datetime2(0) NULL,
  Note nvarchar(400) NULL,
  CreatedUtc datetime2(3) NOT NULL CONSTRAINT DF_ApiClient_Created DEFAULT (SYSUTCDATETIME()),
  CreatedBy nvarchar(200) NOT NULL,
  RevokedUtc datetime2(3) NULL,
  RevokedBy nvarchar(200) NULL,
  LastUsedUtc datetime2(3) NULL,
  LastIp nvarchar(64) NULL,
  CONSTRAINT CK_ApiClient_Rpm CHECK (RequestsPerMinute BETWEEN 1 AND 10000)
);

IF OBJECT_ID(N'api.ClientHistory', N'U') IS NULL
CREATE TABLE api.ClientHistory
(
  ClientHistoryId bigint IDENTITY(1, 1) NOT NULL CONSTRAINT PK_ApiClientHistory PRIMARY KEY,
  ClientId int NOT NULL CONSTRAINT FK_ApiClientHistory_Client REFERENCES api.Client (ClientId),
  Action nvarchar(40) NOT NULL,                 /* USTVARJEN, SPREMENJEN, PREKLICAN */
  Detail nvarchar(1000) NULL,
  ChangedUtc datetime2(3) NOT NULL CONSTRAINT DF_ApiClientHistory_Changed DEFAULT (SYSUTCDATETIME()),
  ChangedBy nvarchar(200) NOT NULL
);

IF OBJECT_ID(N'api.RequestLog', N'U') IS NULL
BEGIN
  CREATE TABLE api.RequestLog
  (
    RequestLogId bigint IDENTITY(1, 1) NOT NULL CONSTRAINT PK_ApiRequestLog PRIMARY KEY,
    ClientId int NULL,
    RequestUtc datetime2(3) NOT NULL,
    Method nvarchar(10) NOT NULL,
    Path nvarchar(400) NOT NULL,
    QueryString nvarchar(2000) NULL,
    OrganizationId int NULL,
    StatusCode int NOT NULL,
    DurationMs int NOT NULL,
    RowsReturned int NULL,
    RemoteIp nvarchar(64) NULL
  );
  CREATE INDEX IX_ApiRequestLog_Utc ON api.RequestLog (RequestUtc);
  CREATE INDEX IX_ApiRequestLog_Client ON api.RequestLog (ClientId, RequestUtc);
END;

IF DATABASE_PRINCIPAL_ID(N'pim_api_reader') IS NULL EXEC(N'CREATE ROLE pim_api_reader AUTHORIZATION dbo');

/* ===================================================================================================
   Pomožne funkcije
   =================================================================================================== */

/* Zaloga podjetja po izdelku iz aktivnih posnetkov: ERP (SAOP) in dobavitelji (NW, BT, datoteke).
   Enako kot /zaloge in ana.CaptureStockDaily: samo posnetki istega podjetja, samo ujeti artikli. */
EXEC(N'CREATE OR ALTER FUNCTION api.StockByProduct (@OrganizationId int)
RETURNS TABLE
AS
RETURN
  SELECT position.MatchedProductId AS ProductId,
    ErpQuantity = SUM(CASE WHEN connector.ConnectorType = N''SAOP'' THEN position.Quantity END),
    ErpCustomerOrdered = SUM(CASE WHEN connector.ConnectorType = N''SAOP'' THEN position.OrderedQuantity END),
    ErpForShipment = SUM(CASE WHEN connector.ConnectorType = N''SAOP'' THEN position.ForShipmentQuantity END),
    ErpAvailable = SUM(CASE WHEN connector.ConnectorType = N''SAOP'' THEN COALESCE(position.AvailableQuantity, position.Quantity) END),
    ErpSupplierOrdered = SUM(CASE WHEN connector.ConnectorType = N''SAOP'' THEN position.SupplierOrderedQuantity END),
    ErpSnapshotUtc = MAX(CASE WHEN connector.ConnectorType = N''SAOP'' THEN snapshot.SnapshotUtc END),
    SupplierQuantity = SUM(CASE WHEN connector.ConnectorType <> N''SAOP'' THEN position.Quantity END),
    SupplierIncoming = SUM(CASE WHEN connector.ConnectorType <> N''SAOP'' THEN position.IncomingQuantity END),
    SupplierAvailabilityDate = MIN(CASE WHEN connector.ConnectorType <> N''SAOP'' THEN position.AvailabilityDate END),
    SupplierSnapshotUtc = MAX(CASE WHEN connector.ConnectorType <> N''SAOP'' THEN snapshot.SnapshotUtc END)
  FROM stock.Snapshot AS snapshot
  INNER JOIN map.SourceConnector AS connector ON connector.SourceConnectorId = snapshot.SourceConnectorId
  INNER JOIN stock.Position AS position ON position.SnapshotId = snapshot.SnapshotId
  WHERE snapshot.OrganizationId = @OrganizationId AND snapshot.IsActive = 1
    AND position.MatchedProductId IS NOT NULL
  GROUP BY position.MatchedProductId;');

/* Veljavna cena po (izdelek, cenik) na dan @AsOf in cena pred njo. */
EXEC(N'CREATE OR ALTER FUNCTION api.CurrentPrice (@OrganizationId int, @AsOf datetime2(3))
RETURNS TABLE
AS
RETURN
  SELECT ranked.ProductId, ranked.PriceList, ranked.Net, ranked.VatRate, ranked.ValidFrom,
    ranked.PreviousNet, ranked.PreviousValidFrom
  FROM
  (
    SELECT price.ProductId, price.PriceList, price.Net, price.VatRate, price.ValidFrom,
      PreviousNet = LEAD(price.Net) OVER (PARTITION BY price.ProductId, price.PriceList ORDER BY price.ValidFrom DESC),
      PreviousValidFrom = LEAD(price.ValidFrom) OVER (PARTITION BY price.ProductId, price.PriceList ORDER BY price.ValidFrom DESC),
      RowNo = ROW_NUMBER() OVER (PARTITION BY price.ProductId, price.PriceList ORDER BY price.ValidFrom DESC)
    FROM canon.ProductPrice AS price
    INNER JOIN canon.Product AS product ON product.ProductId = price.ProductId
    WHERE product.OrganizationId = @OrganizationId AND price.IsActive = 1 AND price.ValidFrom <= @AsOf
  ) AS ranked
  WHERE ranked.RowNo = 1;');

/* ===================================================================================================
   Odjemalci API-ja (prijava, dnevnik)
   =================================================================================================== */
EXEC(N'CREATE OR ALTER PROCEDURE api.AuthenticateClient
  @KeyHash binary(32),
  @RemoteIp nvarchar(64) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  DECLARE @Now datetime2(3) = SYSUTCDATETIME();

  UPDATE api.Client
  SET LastUsedUtc = @Now, LastIp = @RemoteIp
  WHERE KeyHash = @KeyHash AND IsActive = 1 AND RevokedUtc IS NULL
    AND (ExpiresUtc IS NULL OR ExpiresUtc > @Now)
    AND (LastUsedUtc IS NULL OR LastUsedUtc < DATEADD(second, -60, @Now) OR ISNULL(LastIp, N'''') <> ISNULL(@RemoteIp, N''''));

  SELECT client.ClientId, client.Name, client.OrganizationIds, client.Scopes, client.RequestsPerMinute, client.ExpiresUtc
  FROM api.Client AS client
  WHERE client.KeyHash = @KeyHash AND client.IsActive = 1 AND client.RevokedUtc IS NULL
    AND (client.ExpiresUtc IS NULL OR client.ExpiresUtc > @Now);
END;');

EXEC(N'CREATE OR ALTER PROCEDURE api.LogRequest
  @ClientId int = NULL,
  @RequestUtc datetime2(3),
  @Method nvarchar(10),
  @Path nvarchar(400),
  @QueryString nvarchar(2000) = NULL,
  @OrganizationId int = NULL,
  @StatusCode int,
  @DurationMs int,
  @RowsReturned int = NULL,
  @RemoteIp nvarchar(64) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  INSERT api.RequestLog (ClientId, RequestUtc, Method, Path, QueryString, OrganizationId, StatusCode, DurationMs, RowsReturned, RemoteIp)
  VALUES (@ClientId, @RequestUtc, LEFT(@Method, 10), LEFT(@Path, 400), LEFT(@QueryString, 2000), @OrganizationId,
    @StatusCode, @DurationMs, @RowsReturned, LEFT(@RemoteIp, 64));
END;');

EXEC(N'CREATE OR ALTER PROCEDURE api.PurgeRequestLog @KeepDays int = 90
AS
BEGIN
  SET NOCOUNT ON;
  IF @KeepDays < 7 SET @KeepDays = 7;
  DELETE TOP (50000) api.RequestLog WHERE RequestUtc < DATEADD(day, -@KeepDays, SYSUTCDATETIME());
  SELECT Deleted = @@ROWCOUNT;
END;');

/* Skrbniški postopki: vloga pim_api_reader jih NE sme izvajati (DENY na koncu). */
EXEC(N'CREATE OR ALTER PROCEDURE api.Admin_CreateClient
  @Name nvarchar(200),
  @KeyPrefix nvarchar(16),
  @KeyHash binary(32),
  @OrganizationIds nvarchar(200) = NULL,
  @Scopes nvarchar(400),
  @RequestsPerMinute int = 120,
  @ExpiresUtc datetime2(0) = NULL,
  @Note nvarchar(400) = NULL,
  @CreatedBy nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  IF NULLIF(LTRIM(RTRIM(@Name)), N'''') IS NULL THROW 52872, N''Ime odjemalca je obvezno.'', 1;
  IF EXISTS (SELECT 1 FROM STRING_SPLIT(@Scopes, N'','') AS scope
             WHERE LTRIM(RTRIM(scope.value)) NOT IN (N''izdelki'', N''cene'', N''zaloga'', N''stranke'', N''nabava'', N''analitika''))
    THROW 52873, N''Neznano področje. Dovoljena: izdelki, cene, zaloga, stranke, nabava, analitika.'', 1;
  IF @OrganizationIds IS NOT NULL AND EXISTS
    (SELECT 1 FROM STRING_SPLIT(@OrganizationIds, N'','') AS id
     WHERE TRY_CONVERT(int, id.value) IS NULL
        OR NOT EXISTS (SELECT 1 FROM dbo.OrganizationConfig AS org WHERE org.OrganizationId = TRY_CONVERT(int, id.value)))
    THROW 52874, N''Seznam podjetij vsebuje neznano podjetje.'', 1;

  BEGIN TRANSACTION;
    INSERT api.Client (Name, KeyPrefix, KeyHash, OrganizationIds, Scopes, RequestsPerMinute, ExpiresUtc, Note, CreatedBy)
    VALUES (LTRIM(RTRIM(@Name)), @KeyPrefix, @KeyHash, NULLIF(@OrganizationIds, N''''), @Scopes, @RequestsPerMinute, @ExpiresUtc, @Note, @CreatedBy);
    DECLARE @ClientId int = SCOPE_IDENTITY();
    INSERT api.ClientHistory (ClientId, Action, Detail, ChangedBy)
    VALUES (@ClientId, N''USTVARJEN'', CONCAT(N''podjetja='', ISNULL(@OrganizationIds, N''vsa''), N''; področja='', @Scopes,
      N''; poteče='', ISNULL(CONVERT(nvarchar(30), @ExpiresUtc, 120), N''nikoli'')), @CreatedBy);
  COMMIT;

  SELECT ClientId = @ClientId;
END;');

EXEC(N'CREATE OR ALTER PROCEDURE api.Admin_UpdateClient
  @ClientId int,
  @OrganizationIds nvarchar(200) = NULL,
  @Scopes nvarchar(400) = NULL,
  @RequestsPerMinute int = NULL,
  @ExpiresUtc datetime2(0) = NULL,
  @ClearExpiry bit = 0,
  @ChangedBy nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  IF NOT EXISTS (SELECT 1 FROM api.Client WHERE ClientId = @ClientId) THROW 52875, N''Odjemalec ne obstaja.'', 1;
  IF @Scopes IS NOT NULL AND EXISTS (SELECT 1 FROM STRING_SPLIT(@Scopes, N'','') AS scope
             WHERE LTRIM(RTRIM(scope.value)) NOT IN (N''izdelki'', N''cene'', N''zaloga'', N''stranke'', N''nabava'', N''analitika''))
    THROW 52873, N''Neznano področje. Dovoljena: izdelki, cene, zaloga, stranke, nabava, analitika.'', 1;

  DECLARE @Before nvarchar(1000) = (SELECT CONCAT(N''podjetja='', ISNULL(OrganizationIds, N''vsa''), N''; področja='', Scopes,
    N''; na minuto='', RequestsPerMinute, N''; poteče='', ISNULL(CONVERT(nvarchar(30), ExpiresUtc, 120), N''nikoli'')) FROM api.Client WHERE ClientId = @ClientId);

  BEGIN TRANSACTION;
    UPDATE api.Client
    SET OrganizationIds = CASE WHEN @OrganizationIds IS NULL THEN OrganizationIds WHEN @OrganizationIds = N''vsa'' THEN NULL ELSE @OrganizationIds END,
        Scopes = COALESCE(@Scopes, Scopes),
        RequestsPerMinute = COALESCE(@RequestsPerMinute, RequestsPerMinute),
        ExpiresUtc = CASE WHEN @ClearExpiry = 1 THEN NULL ELSE COALESCE(@ExpiresUtc, ExpiresUtc) END
    WHERE ClientId = @ClientId;
    INSERT api.ClientHistory (ClientId, Action, Detail, ChangedBy)
    SELECT @ClientId, N''SPREMENJEN'', LEFT(CONCAT(N''prej: '', @Before, N'' | zdaj: podjetja='', ISNULL(OrganizationIds, N''vsa''), N''; področja='', Scopes,
      N''; na minuto='', RequestsPerMinute, N''; poteče='', ISNULL(CONVERT(nvarchar(30), ExpiresUtc, 120), N''nikoli'')), 1000), @ChangedBy
    FROM api.Client WHERE ClientId = @ClientId;
  COMMIT;
END;');

EXEC(N'CREATE OR ALTER PROCEDURE api.Admin_RevokeClient @ClientId int, @RevokedBy nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  IF NOT EXISTS (SELECT 1 FROM api.Client WHERE ClientId = @ClientId) THROW 52875, N''Odjemalec ne obstaja.'', 1;
  BEGIN TRANSACTION;
    UPDATE api.Client SET IsActive = 0, RevokedUtc = SYSUTCDATETIME(), RevokedBy = @RevokedBy
    WHERE ClientId = @ClientId AND RevokedUtc IS NULL;
    INSERT api.ClientHistory (ClientId, Action, Detail, ChangedBy) VALUES (@ClientId, N''PREKLICAN'', NULL, @RevokedBy);
  COMMIT;
END;');

EXEC(N'CREATE OR ALTER PROCEDURE api.Admin_ListClients
AS
BEGIN
  SET NOCOUNT ON;
  SELECT client.ClientId, client.Name, client.KeyPrefix, client.OrganizationIds, client.Scopes, client.RequestsPerMinute,
    client.IsActive, client.ExpiresUtc, client.CreatedUtc, client.CreatedBy, client.RevokedUtc, client.RevokedBy,
    client.LastUsedUtc, client.LastIp, client.Note,
    Requests7d = (SELECT COUNT(*) FROM api.RequestLog AS log WHERE log.ClientId = client.ClientId AND log.RequestUtc >= DATEADD(day, -7, SYSUTCDATETIME()))
  FROM api.Client AS client
  ORDER BY client.IsActive DESC, client.Name;
END;');

/* ===================================================================================================
   Šifranti in svežina
   =================================================================================================== */
EXEC(N'CREATE OR ALTER PROCEDURE api.GetOrganizations
AS
BEGIN
  SET NOCOUNT ON;
  SELECT org.OrganizationId, org.Name, org.IsActive,
    Products = (SELECT COUNT(*) FROM canon.Product AS product WHERE product.OrganizationId = org.OrganizationId),
    ActiveProducts = (SELECT COUNT(*) FROM canon.Product AS product WHERE product.OrganizationId = org.OrganizationId AND product.IsActive = 1),
    Customers = (SELECT COUNT(*) FROM b2b.Customer AS customer WHERE customer.OrganizationId = org.OrganizationId)
  FROM dbo.OrganizationConfig AS org
  ORDER BY org.OrganizationId;
END;');

/* Kako stari so podatki: AI mora vedeti, ali poroča o današnji zalogi ali o tisti izpred tedna. */
EXEC(N'CREATE OR ALTER PROCEDURE api.GetDataFreshness @OrganizationId int
AS
BEGIN
  SET NOCOUNT ON;
  DECLARE @Now datetime2(3) = SYSUTCDATETIME();

  SELECT Area, Source, LastUtc, AgeHours = CASE WHEN LastUtc IS NULL THEN NULL ELSE DATEDIFF(minute, LastUtc, @Now) / 60.0 END, Rows
  FROM
  (
    SELECT Area = N''zaloga'', Source = connector.SourceCode, LastUtc = MAX(snapshot.SnapshotUtc),
      Rows = (SELECT COUNT(*) FROM stock.Position AS position WHERE position.SnapshotId = MAX(snapshot.SnapshotId))
    FROM stock.Snapshot AS snapshot
    INNER JOIN map.SourceConnector AS connector ON connector.SourceConnectorId = snapshot.SourceConnectorId
    WHERE snapshot.OrganizationId = @OrganizationId AND snapshot.IsActive = 1
    GROUP BY connector.SourceCode
    UNION ALL
    SELECT N''cene'', N''canon.ProductPrice (zadnja veljavnost)'', MAX(price.ValidFrom), COUNT(*)
    FROM canon.ProductPrice AS price INNER JOIN canon.Product AS product ON product.ProductId = price.ProductId
    WHERE product.OrganizationId = @OrganizationId AND price.ValidFrom <= @Now
    UNION ALL
    SELECT N''stranke'', N''b2b.Customer'', MAX(customer.UpdatedUtc), COUNT(*)
    FROM b2b.Customer AS customer WHERE customer.OrganizationId = @OrganizationId
    UNION ALL
    SELECT N''nabava'', N''purch.PurchaseOrderHeader'', MAX(header.UpdatedUtc), COUNT(*)
    FROM purch.PurchaseOrderHeader AS header WHERE header.OrganizationId = @OrganizationId
    UNION ALL
    SELECT N''izdelki'', N''canon.Product (zadnja validacija)'', MAX(product.LastValidatedUtc), COUNT(*)
    FROM canon.Product AS product WHERE product.OrganizationId = @OrganizationId
    UNION ALL
    SELECT N''analitika'', N''ana.'' + stream.Stream, stream.LastSuccessUtc, stream.LastRowCount
    FROM ana.StreamState AS stream WHERE stream.OrganizationId = @OrganizationId
    UNION ALL
    SELECT N''analitika'', N''ana.ItemMetric (izračun)'', MAX(metric.CalculatedUtc), COUNT(*)
    FROM ana.ItemMetric AS metric WHERE metric.OrganizationId = @OrganizationId
  ) AS freshness
  ORDER BY Area, Source;
END;');

EXEC(N'CREATE OR ALTER PROCEDURE api.GetPartners @OrganizationId int, @Role nvarchar(20) = N''dobavitelj'', @Search nvarchar(200) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  DECLARE @Like nvarchar(210) = CASE WHEN NULLIF(LTRIM(RTRIM(@Search)), N'''') IS NULL THEN NULL
    ELSE N''%'' + REPLACE(REPLACE(REPLACE(LTRIM(RTRIM(@Search)), N''['', N''[[]''), N''%'', N''[%]''), N''_'', N''[_]'') + N''%'' END;

  SELECT PartnerCode = partner.Code, PartnerName = name.PartnerName, partner.Products, partner.ActiveProducts
  FROM
  (
    SELECT Code = CASE WHEN @Role = N''proizvajalec'' THEN product.Manufacturer ELSE product.Supplier END,
      Products = COUNT(*), ActiveProducts = SUM(CAST(product.IsActive AS int))
    FROM canon.Product AS product
    WHERE product.OrganizationId = @OrganizationId
      AND (CASE WHEN @Role = N''proizvajalec'' THEN product.Manufacturer ELSE product.Supplier END) IS NOT NULL
    GROUP BY CASE WHEN @Role = N''proizvajalec'' THEN product.Manufacturer ELSE product.Supplier END
  ) AS partner
  OUTER APPLY (SELECT TOP (1) pn.PartnerName FROM canon.PartnerName AS pn
               WHERE pn.OrganizationId = @OrganizationId AND pn.PartnerCode = partner.Code) AS name
  WHERE @Like IS NULL
     OR partner.Code COLLATE Latin1_General_100_CI_AI LIKE @Like COLLATE Latin1_General_100_CI_AI
     OR name.PartnerName COLLATE Latin1_General_100_CI_AI LIKE @Like COLLATE Latin1_General_100_CI_AI
  ORDER BY partner.Products DESC;
END;');

/* ===================================================================================================
   Izdelki
   =================================================================================================== */

/*
  Iskanje: vsaka beseda iz @Search se mora pojaviti v šifri, EAN ali enem od nazivov (brez šumnikov in
  velikih črk). @ItemIds = seznam šifer, ločenih z vejico (natančno ujemanje, do 500).
  Sortiranje: itemId (privzeto), name, stock (največ zaloge najprej), -stock.
*/
EXEC(N'CREATE OR ALTER PROCEDURE api.SearchProducts
  @OrganizationId int,
  @Search nvarchar(200) = NULL,
  @ItemIds nvarchar(max) = NULL,
  @Ean nvarchar(40) = NULL,
  @Supplier nvarchar(100) = NULL,
  @Manufacturer nvarchar(100) = NULL,
  @ItemGroup nvarchar(100) = NULL,
  @Department nvarchar(100) = NULL,
  @IsActive bit = NULL,
  @WebPublish bit = NULL,
  @InStock bit = NULL,
  @Lang nvarchar(10) = N''sl'',
  @Sort nvarchar(20) = N''itemId'',
  @Skip int = 0,
  @Take int = 50,
  @TotalCount int = NULL OUTPUT
AS
BEGIN
  SET NOCOUNT ON;
  IF @Skip < 0 SET @Skip = 0;
  IF @Take IS NULL OR @Take < 1 SET @Take = 50;
  IF @Take > 500 SET @Take = 500;
  DECLARE @Now datetime2(3) = SYSUTCDATETIME();
  DECLARE @CostList nvarchar(40) = ISNULL((SELECT CostPriceList FROM ana.Setting WHERE OrganizationId = @OrganizationId), N''NAB'');

  CREATE TABLE #stock
  (
    ProductId bigint NOT NULL PRIMARY KEY, ErpQuantity decimal(19, 4) NULL, ErpAvailable decimal(19, 4) NULL,
    ErpCustomerOrdered decimal(19, 4) NULL, ErpSupplierOrdered decimal(19, 4) NULL, SupplierQuantity decimal(19, 4) NULL,
    SupplierIncoming decimal(19, 4) NULL, SupplierAvailabilityDate date NULL
  );
  INSERT #stock
  SELECT ProductId, ErpQuantity, ErpAvailable, ErpCustomerOrdered, ErpSupplierOrdered, SupplierQuantity, SupplierIncoming, SupplierAvailabilityDate
  FROM api.StockByProduct(@OrganizationId);

  CREATE TABLE #item (ItemID nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY);
  IF NULLIF(LTRIM(RTRIM(@ItemIds)), N'''') IS NOT NULL
    INSERT #item (ItemID)
    SELECT DISTINCT TOP (500) LTRIM(RTRIM(value)) FROM STRING_SPLIT(@ItemIds, N'','') WHERE LTRIM(RTRIM(value)) <> N'''';

  CREATE TABLE #hit (ProductId bigint NOT NULL PRIMARY KEY);
  INSERT #hit (ProductId)
  SELECT product.ProductId
  FROM canon.Product AS product
  WHERE product.OrganizationId = @OrganizationId
    AND (@IsActive IS NULL OR product.IsActive = @IsActive)
    AND (@WebPublish IS NULL OR product.WebPublish = @WebPublish)
    AND (@Supplier IS NULL OR product.Supplier = @Supplier)
    AND (@Manufacturer IS NULL OR product.Manufacturer = @Manufacturer)
    AND (@ItemGroup IS NULL OR product.ItemGroup = @ItemGroup)
    AND (@Department IS NULL OR product.Department = @Department)
    AND (@Ean IS NULL OR product.EAN = @Ean)
    AND (NOT EXISTS (SELECT 1 FROM #item) OR product.ItemID IN (SELECT ItemID FROM #item))
  OPTION (RECOMPILE);

  IF @InStock = 1
    DELETE hit FROM #hit AS hit WHERE NOT EXISTS (SELECT 1 FROM #stock AS s WHERE s.ProductId = hit.ProductId AND s.ErpQuantity > 0);
  ELSE IF @InStock = 0
    DELETE hit FROM #hit AS hit WHERE EXISTS (SELECT 1 FROM #stock AS s WHERE s.ProductId = hit.ProductId AND s.ErpQuantity > 0);

  /* Besede iskanja: ena po ena zoži zadetke (zanka po besedah, ne po izdelkih; največ 8 besed). */
  DECLARE @words TABLE (WordNo int IDENTITY(1, 1) PRIMARY KEY, Pattern nvarchar(210) COLLATE Latin1_General_100_CI_AI NOT NULL);
  IF NULLIF(LTRIM(RTRIM(@Search)), N'''') IS NOT NULL
    INSERT @words (Pattern)
    SELECT TOP (8) N''%'' + REPLACE(REPLACE(REPLACE(LTRIM(RTRIM(value)), N''['', N''[[]''), N''%'', N''[%]''), N''_'', N''[_]'') + N''%''
    FROM STRING_SPLIT(@Search, N'' '') WHERE LTRIM(RTRIM(value)) <> N'''';

  DECLARE @WordNo int = 1, @Pattern nvarchar(210);
  WHILE EXISTS (SELECT 1 FROM @words WHERE WordNo = @WordNo)
  BEGIN
    SELECT @Pattern = Pattern FROM @words WHERE WordNo = @WordNo;
    DELETE hit
    FROM #hit AS hit
    INNER JOIN canon.Product AS product ON product.ProductId = hit.ProductId
    WHERE NOT (
      product.ItemID COLLATE Latin1_General_100_CI_AI LIKE @Pattern
      OR ISNULL(product.EAN, N'''') COLLATE Latin1_General_100_CI_AI LIKE @Pattern
      OR EXISTS (SELECT 1 FROM canon.ProductText AS text
                 WHERE text.ProductId = hit.ProductId
                   AND text.TextType IN (N''TITLE_ERP'', N''TITLE_ERP2'', N''WEB_TITLE'', N''SEARCH_NAME'', N''TITLE_SHORT'')
                   AND text.Value COLLATE Latin1_General_100_CI_AI LIKE @Pattern));
    SET @WordNo += 1;
  END;

  SELECT @TotalCount = COUNT(*) FROM #hit;

  CREATE TABLE #page (ProductId bigint NOT NULL PRIMARY KEY, RowNo int NOT NULL);
  INSERT #page (ProductId, RowNo)
  SELECT ProductId, RowNo FROM
  (
    SELECT hit.ProductId,
      RowNo = ROW_NUMBER() OVER (ORDER BY
        CASE WHEN @Sort = N''stock'' THEN -ISNULL(s.ErpQuantity, 0) WHEN @Sort = N''-stock'' THEN ISNULL(s.ErpQuantity, 0) END,
        CASE WHEN @Sort = N''name'' THEN name.Value END,
        product.ItemID)
    FROM #hit AS hit
    INNER JOIN canon.Product AS product ON product.ProductId = hit.ProductId
    LEFT JOIN #stock AS s ON s.ProductId = hit.ProductId
    OUTER APPLY (SELECT TOP (1) CAST(t.Value AS nvarchar(400)) AS Value FROM canon.ProductText AS t
                 WHERE @Sort = N''name'' AND t.ProductId = hit.ProductId AND t.TextType = N''TITLE_ERP''
                 ORDER BY CASE WHEN t.Lang = @Lang THEN 0 ELSE 1 END) AS name
  ) AS ordered
  WHERE RowNo > @Skip AND RowNo <= @Skip + @Take;

  SELECT product.ProductId, product.OrganizationId, ItemId = product.ItemID, Ean = product.EAN,
    Name = title.Value, WebTitle = web.Value,
    product.IsActive, product.WebPublish, Uom = product.UoM, product.ItemGroup, product.Department,
    ManufacturerCode = product.Manufacturer, ManufacturerName = manufacturer.PartnerName,
    SupplierCode = product.Supplier, SupplierName = supplier.PartnerName,
    product.DiscountGroup, product.ValidationStatus, product.Completeness, product.ErpExistence,
    s.ErpQuantity, s.ErpAvailable, s.ErpCustomerOrdered, s.ErpSupplierOrdered,
    s.SupplierQuantity, s.SupplierIncoming, s.SupplierAvailabilityDate,
    CostPrice = cost.Net, RetailPrice = retail.Net, WholesalePrice = wholesale.Net, VatRate = COALESCE(retail.VatRate, wholesale.VatRate, cost.VatRate)
  FROM #page AS page
  INNER JOIN canon.Product AS product ON product.ProductId = page.ProductId
  LEFT JOIN #stock AS s ON s.ProductId = page.ProductId
  OUTER APPLY (SELECT TOP (1) t.Value FROM canon.ProductText AS t WHERE t.ProductId = page.ProductId AND t.TextType = N''TITLE_ERP''
               ORDER BY CASE WHEN t.Lang = @Lang THEN 0 WHEN t.Lang = N''sl'' THEN 1 ELSE 2 END) AS title
  OUTER APPLY (SELECT TOP (1) t.Value FROM canon.ProductText AS t WHERE t.ProductId = page.ProductId AND t.TextType = N''WEB_TITLE''
               ORDER BY CASE WHEN t.Lang = @Lang THEN 0 WHEN t.Lang = N''sl'' THEN 1 ELSE 2 END) AS web
  OUTER APPLY (SELECT TOP (1) pn.PartnerName FROM canon.PartnerName AS pn WHERE pn.OrganizationId = @OrganizationId AND pn.PartnerCode = product.Manufacturer) AS manufacturer
  OUTER APPLY (SELECT TOP (1) pn.PartnerName FROM canon.PartnerName AS pn WHERE pn.OrganizationId = @OrganizationId AND pn.PartnerCode = product.Supplier) AS supplier
  OUTER APPLY (SELECT TOP (1) price.Net, price.VatRate FROM canon.ProductPrice AS price
               WHERE price.ProductId = page.ProductId AND price.PriceList = @CostList AND price.IsActive = 1 AND price.ValidFrom <= @Now
               ORDER BY price.ValidFrom DESC) AS cost
  OUTER APPLY (SELECT TOP (1) price.Net, price.VatRate FROM out.ExportPriceList AS map
               INNER JOIN canon.Product AS priceProduct ON priceProduct.OrganizationId = COALESCE(map.PriceOrganizationId, @OrganizationId) AND priceProduct.ItemID = product.ItemID
               INNER JOIN canon.ProductPrice AS price ON price.ProductId = priceProduct.ProductId AND price.PriceList = map.PriceListCode AND price.IsActive = 1 AND price.ValidFrom <= @Now
               WHERE map.OrganizationId = @OrganizationId AND map.PriceFieldCode = N''Product.PriceB2C'' AND map.IsActive = 1
               ORDER BY map.SortOrder, price.ValidFrom DESC) AS retail
  OUTER APPLY (SELECT TOP (1) price.Net, price.VatRate FROM out.ExportPriceList AS map
               INNER JOIN canon.Product AS priceProduct ON priceProduct.OrganizationId = COALESCE(map.PriceOrganizationId, @OrganizationId) AND priceProduct.ItemID = product.ItemID
               INNER JOIN canon.ProductPrice AS price ON price.ProductId = priceProduct.ProductId AND price.PriceList = map.PriceListCode AND price.IsActive = 1 AND price.ValidFrom <= @Now
               WHERE map.OrganizationId = @OrganizationId AND map.PriceFieldCode = N''Product.PriceB2B'' AND map.IsActive = 1
               ORDER BY map.SortOrder, price.ValidFrom DESC) AS wholesale
  ORDER BY page.RowNo;
END;');

/* Kartica izdelka: več naborov (izdelek, besedila, atributi, kategorije, cene, zaloga po virih,
   slike, dokumenti, odprta naročila dobaviteljem, ista šifra v drugih podjetjih, validacija). */
EXEC(N'CREATE OR ALTER PROCEDURE api.GetProduct
  @OrganizationId int,
  @ItemId nvarchar(100) = NULL,
  @ProductId bigint = NULL,
  @Lang nvarchar(10) = N''sl''
AS
BEGIN
  SET NOCOUNT ON;
  DECLARE @Now datetime2(3) = SYSUTCDATETIME();
  IF @ProductId IS NULL
    SELECT @ProductId = ProductId FROM canon.Product WHERE OrganizationId = @OrganizationId AND ItemID = @ItemId;
  ELSE IF NOT EXISTS (SELECT 1 FROM canon.Product WHERE ProductId = @ProductId AND OrganizationId = @OrganizationId)
    SET @ProductId = NULL;
  SELECT @ItemId = ItemID FROM canon.Product WHERE ProductId = @ProductId;

  /* 1 izdelek */
  SELECT product.ProductId, product.OrganizationId, ItemId = product.ItemID, Ean = product.EAN,
    Name = (SELECT TOP (1) t.Value FROM canon.ProductText AS t WHERE t.ProductId = product.ProductId AND t.TextType = N''TITLE_ERP''
            ORDER BY CASE WHEN t.Lang = @Lang THEN 0 WHEN t.Lang = N''sl'' THEN 1 ELSE 2 END),
    product.IsActive, product.WebPublish, Uom = product.UoM, product.ItemGroup, product.Department,
    ManufacturerCode = product.Manufacturer,
    ManufacturerName = (SELECT TOP (1) PartnerName FROM canon.PartnerName WHERE OrganizationId = @OrganizationId AND PartnerCode = product.Manufacturer),
    SupplierCode = product.Supplier,
    SupplierName = (SELECT TOP (1) PartnerName FROM canon.PartnerName WHERE OrganizationId = @OrganizationId AND PartnerCode = product.Supplier),
    product.DiscountGroup, product.AccountingGroup, product.VatRateId, product.PriceListCode, product.HasSeries,
    product.ValidationStatus, product.Completeness, product.LastValidatedUtc, product.ErpExistence,
    commercial.NetWeight, commercial.GrossWeight, commercial.CustomsTariff, commercial.CountryOfOrigin,
    commercial.Pak1, commercial.Pak2, commercial.Dimensions, commercial.Volume,
    commercial.PackageLength, commercial.PackageWidth, commercial.PackageHeight, commercial.DimensionUnit,
    planning.LeadTimeDays, planning.PurchaseLeadTimeDays,
    MinimumStock = policy.MinimumStock, MaximumStock = policy.MaximumStock
  FROM canon.Product AS product
  LEFT JOIN canon.ProductCommercial AS commercial ON commercial.ProductId = product.ProductId
  LEFT JOIN canon.ProductPlanning AS planning ON planning.ProductId = product.ProductId
  OUTER APPLY (SELECT MinimumStock = SUM(p.MinimumStock), MaximumStock = SUM(p.MaximumStock)
               FROM canon.ProductStockPolicy AS p WHERE p.ProductId = product.ProductId) AS policy
  WHERE product.ProductId = @ProductId;

  /* 2 besedila */
  SELECT Lang = text.Lang, TextType = text.TextType, text.Value
  FROM canon.ProductText AS text WHERE text.ProductId = @ProductId
  ORDER BY text.TextType, text.Lang;

  /* 3 atributi */
  SELECT attribute.AttributeCode,
    AttributeName = COALESCE(nameLang.Name, nameSl.Name, attribute.AttributeCode),
    attribute.Value, attribute.Unit, attribute.LanguageCode
  FROM canon.ProductAttribute AS attribute
  LEFT JOIN canon.AttributeTranslation AS nameLang ON nameLang.AttributeCode = attribute.AttributeCode AND nameLang.LanguageCode = @Lang
  LEFT JOIN canon.AttributeTranslation AS nameSl ON nameSl.AttributeCode = attribute.AttributeCode AND nameSl.LanguageCode = N''sl''
  WHERE attribute.ProductId = @ProductId
  ORDER BY attribute.AttributeCode, attribute.LanguageCode;

  /* 4 kategorije */
  SELECT category.WebSite, category.CategoryPath FROM canon.ProductCategory AS category WHERE category.ProductId = @ProductId;

  /* 5 cene po cenikih (veljavna in prejšnja) */
  SELECT price.PriceList, PriceListName = codebook.Name, NetPrice = price.Net, price.VatRate,
    GrossPrice = CAST(price.Net * (1 + ISNULL(price.VatRate, 0) / 100.0) AS decimal(19, 4)),
    price.ValidFrom, PreviousNetPrice = price.PreviousNet, price.PreviousValidFrom,
    ChangePct = CASE WHEN price.PreviousNet > 0 THEN CAST((price.Net - price.PreviousNet) * 100.0 / price.PreviousNet AS decimal(9, 2)) END
  FROM api.CurrentPrice(@OrganizationId, @Now) AS price
  OUTER APPLY (SELECT TOP (1) c.Name FROM canon.Codebook AS c WHERE c.OrganizationId = @OrganizationId AND c.CodebookCode = N''PRICELIST'' AND c.EntryCode = price.PriceList) AS codebook
  WHERE price.ProductId = @ProductId
  ORDER BY price.PriceList;

  /* 6 zaloga po virih */
  SELECT Source = connector.SourceCode, SourceKind = CASE WHEN connector.ConnectorType = N''SAOP'' THEN N''ERP'' ELSE N''DOBAVITELJ'' END,
    Quantity = SUM(position.Quantity), CustomerOrdered = SUM(position.OrderedQuantity), ForShipment = SUM(position.ForShipmentQuantity),
    Available = SUM(COALESCE(position.AvailableQuantity, position.Quantity)), SupplierOrdered = SUM(position.SupplierOrderedQuantity),
    Incoming = SUM(position.IncomingQuantity), AvailabilityDate = MIN(position.AvailabilityDate), SnapshotUtc = MAX(snapshot.SnapshotUtc)
  FROM stock.Snapshot AS snapshot
  INNER JOIN map.SourceConnector AS connector ON connector.SourceConnectorId = snapshot.SourceConnectorId
  INNER JOIN stock.Position AS position ON position.SnapshotId = snapshot.SnapshotId
  WHERE snapshot.OrganizationId = @OrganizationId AND snapshot.IsActive = 1 AND position.MatchedProductId = @ProductId
  GROUP BY connector.SourceCode, connector.ConnectorType
  ORDER BY SourceKind DESC, Source;

  /* 7 slike, 8 dokumenti */
  SELECT media.Url, media.Role, media.SortOrder FROM canon.ProductMedia AS media WHERE media.ProductId = @ProductId ORDER BY media.SortOrder;
  SELECT document.Url, document.Role, document.Title, document.SortOrder FROM canon.ProductDocument AS document WHERE document.ProductId = @ProductId ORDER BY document.SortOrder;

  /* 9 odprta naročila dobaviteljem */
  SELECT header.PurchaseOrderYear, header.PurchaseOrderBook, header.PurchaseOrderNumber, header.SupplierID,
    SupplierName = (SELECT TOP (1) PartnerName FROM canon.PartnerName WHERE OrganizationId = @OrganizationId AND PartnerCode = header.SupplierID),
    header.Status, header.OrderDate, ForeseenDeliveryDate = COALESCE(line.ForeseenDeliveryDate, header.ForeseenDeliveryDate),
    line.OrderedQuantity, line.UnitOfMeasure, line.NetAmountOrdered, LineStatus = line.Status
  FROM purch.PurchaseOrderLine AS line
  INNER JOIN purch.PurchaseOrderHeader AS header ON header.PurchaseOrderHeaderId = line.PurchaseOrderHeaderId
  WHERE header.OrganizationId = @OrganizationId AND line.ItemID = @ItemId AND ISNULL(line.CanceledLine, 0) = 0
    AND header.Status NOT IN (N''Zaključeno'', N''Stornirano'')
  ORDER BY COALESCE(line.ForeseenDeliveryDate, header.ForeseenDeliveryDate);

  /* 10 ista šifra v drugih podjetjih */
  SELECT other.OrganizationId, OrganizationName = org.Name, other.ProductId, other.IsActive, other.WebPublish
  FROM canon.Product AS other
  INNER JOIN dbo.OrganizationConfig AS org ON org.OrganizationId = other.OrganizationId
  WHERE other.ItemID = @ItemId AND other.OrganizationId <> @OrganizationId;

  /* 11 validacija po profilih */
  SELECT profile.ProfileCode, ProfileName = profile.Name, state.Status, state.Completeness, state.ValidatedUtc
  FROM val.ProductValidationState AS state
  INNER JOIN val.ValidationProfile AS profile ON profile.ValidationProfileId = state.ValidationProfileId
  WHERE state.ProductId = @ProductId AND profile.IsActive = 1
  ORDER BY profile.ProfileCode;
END;');

/* ===================================================================================================
   Cene
   =================================================================================================== */
EXEC(N'CREATE OR ALTER PROCEDURE api.GetPriceLists @OrganizationId int
AS
BEGIN
  SET NOCOUNT ON;
  DECLARE @Now datetime2(3) = SYSUTCDATETIME();
  SELECT PriceList = lists.PriceList, PriceListName = codebook.Name, lists.Products, lists.LastValidFrom, lists.FuturePrices,
    UsedAs = (SELECT STRING_AGG(REPLACE(map.PriceFieldCode, N''Product.'', N''''), N'', '') FROM out.ExportPriceList AS map
              WHERE map.OrganizationId = @OrganizationId AND map.IsActive = 1 AND map.PriceListCode = lists.PriceList
                AND map.PriceOrganizationId IS NULL)
  FROM
  (
    SELECT price.PriceList, Products = COUNT(DISTINCT price.ProductId),
      LastValidFrom = MAX(CASE WHEN price.ValidFrom <= @Now THEN price.ValidFrom END),
      FuturePrices = SUM(CASE WHEN price.ValidFrom > @Now THEN 1 ELSE 0 END)
    FROM canon.ProductPrice AS price INNER JOIN canon.Product AS product ON product.ProductId = price.ProductId
    WHERE product.OrganizationId = @OrganizationId AND price.IsActive = 1
    GROUP BY price.PriceList
  ) AS lists
  OUTER APPLY (SELECT TOP (1) c.Name FROM canon.Codebook AS c WHERE c.OrganizationId = @OrganizationId AND c.CodebookCode = N''PRICELIST'' AND c.EntryCode = lists.PriceList) AS codebook
  ORDER BY lists.Products DESC;
END;');

/* Veljavne cene: po ceniku, izdelku, dobavitelju; @ChangedSince = samo cene, ki veljajo od tega dne naprej
   (poročilo o spremembah cen). @IncludeFuture = 1 doda še napovedane cene (veljavnost v prihodnosti). */
EXEC(N'CREATE OR ALTER PROCEDURE api.GetPrices
  @OrganizationId int,
  @PriceList nvarchar(40) = NULL,
  @Search nvarchar(200) = NULL,
  @ItemIds nvarchar(max) = NULL,
  @Supplier nvarchar(100) = NULL,
  @ChangedSince datetime2(3) = NULL,
  @IncludeFuture bit = 0,
  @Lang nvarchar(10) = N''sl'',
  @Skip int = 0,
  @Take int = 100,
  @TotalCount int = NULL OUTPUT
AS
BEGIN
  SET NOCOUNT ON;
  IF @Skip < 0 SET @Skip = 0;
  IF @Take IS NULL OR @Take < 1 SET @Take = 100;
  IF @Take > 1000 SET @Take = 1000;
  DECLARE @Now datetime2(3) = SYSUTCDATETIME();
  DECLARE @Like nvarchar(210) = CASE WHEN NULLIF(LTRIM(RTRIM(@Search)), N'''') IS NULL THEN NULL
    ELSE N''%'' + REPLACE(REPLACE(REPLACE(LTRIM(RTRIM(@Search)), N''['', N''[[]''), N''%'', N''[%]''), N''_'', N''[_]'') + N''%'' END;

  CREATE TABLE #item (ItemID nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY);
  IF NULLIF(LTRIM(RTRIM(@ItemIds)), N'''') IS NOT NULL
    INSERT #item (ItemID) SELECT DISTINCT TOP (500) LTRIM(RTRIM(value)) FROM STRING_SPLIT(@ItemIds, N'','') WHERE LTRIM(RTRIM(value)) <> N'''';

  CREATE TABLE #row
  (
    RowNo int IDENTITY(1, 1) NOT NULL PRIMARY KEY, ProductId bigint NOT NULL, PriceList nvarchar(40) COLLATE DATABASE_DEFAULT NOT NULL,
    Net decimal(19, 6) NULL, VatRate decimal(9, 4) NULL, ValidFrom datetime2(3) NOT NULL, PreviousNet decimal(19, 6) NULL,
    PreviousValidFrom datetime2(3) NULL, IsFuture bit NOT NULL
  );

  INSERT #row (ProductId, PriceList, Net, VatRate, ValidFrom, PreviousNet, PreviousValidFrom, IsFuture)
  SELECT price.ProductId, price.PriceList, price.Net, price.VatRate, price.ValidFrom, price.PreviousNet, price.PreviousValidFrom, price.IsFuture
  FROM
  (
    SELECT ranked.ProductId, ranked.PriceList, ranked.Net, ranked.VatRate, ranked.ValidFrom, ranked.PreviousNet, ranked.PreviousValidFrom,
      IsFuture = CAST(CASE WHEN ranked.ValidFrom > @Now THEN 1 ELSE 0 END AS bit), ranked.CurrentRowNo
    FROM
    (
      SELECT price.ProductId, price.PriceList, price.Net, price.VatRate, price.ValidFrom,
        PreviousNet = LEAD(price.Net) OVER (PARTITION BY price.ProductId, price.PriceList ORDER BY price.ValidFrom DESC),
        PreviousValidFrom = LEAD(price.ValidFrom) OVER (PARTITION BY price.ProductId, price.PriceList ORDER BY price.ValidFrom DESC),
        CurrentRowNo = ROW_NUMBER() OVER (PARTITION BY price.ProductId, price.PriceList, CASE WHEN price.ValidFrom > @Now THEN 1 ELSE 0 END ORDER BY price.ValidFrom DESC)
      FROM canon.ProductPrice AS price
      INNER JOIN canon.Product AS product ON product.ProductId = price.ProductId
      WHERE product.OrganizationId = @OrganizationId AND price.IsActive = 1
        AND (@PriceList IS NULL OR price.PriceList = @PriceList)
        AND (@Supplier IS NULL OR product.Supplier = @Supplier)
        AND (NOT EXISTS (SELECT 1 FROM #item) OR product.ItemID IN (SELECT ItemID FROM #item))
        AND (@Like IS NULL
             OR product.ItemID COLLATE Latin1_General_100_CI_AI LIKE @Like COLLATE Latin1_General_100_CI_AI
             OR EXISTS (SELECT 1 FROM canon.ProductText AS t WHERE t.ProductId = product.ProductId
                          AND t.TextType IN (N''TITLE_ERP'', N''WEB_TITLE'', N''SEARCH_NAME'')
                          AND t.Value COLLATE Latin1_General_100_CI_AI LIKE @Like COLLATE Latin1_General_100_CI_AI))
    ) AS ranked
  ) AS price
  INNER JOIN canon.Product AS product ON product.ProductId = price.ProductId
  WHERE (price.IsFuture = 0 AND price.CurrentRowNo = 1 OR price.IsFuture = 1 AND @IncludeFuture = 1)
    AND (@ChangedSince IS NULL OR price.ValidFrom >= @ChangedSince)
  ORDER BY product.ItemID, price.PriceList, price.ValidFrom
  OPTION (RECOMPILE);

  SELECT @TotalCount = COUNT(*) FROM #row;

  SELECT ItemId = product.ItemID, row.ProductId,
    Name = (SELECT TOP (1) t.Value FROM canon.ProductText AS t WHERE t.ProductId = row.ProductId AND t.TextType = N''TITLE_ERP''
            ORDER BY CASE WHEN t.Lang = @Lang THEN 0 WHEN t.Lang = N''sl'' THEN 1 ELSE 2 END),
    SupplierCode = product.Supplier, row.PriceList, NetPrice = row.Net, row.VatRate,
    GrossPrice = CAST(row.Net * (1 + ISNULL(row.VatRate, 0) / 100.0) AS decimal(19, 4)),
    row.ValidFrom, row.IsFuture, PreviousNetPrice = row.PreviousNet, row.PreviousValidFrom,
    ChangePct = CASE WHEN row.PreviousNet > 0 THEN CAST((row.Net - row.PreviousNet) * 100.0 / row.PreviousNet AS decimal(9, 2)) END
  FROM #row AS row
  INNER JOIN canon.Product AS product ON product.ProductId = row.ProductId
  WHERE row.RowNo > @Skip AND row.RowNo <= @Skip + @Take
  ORDER BY row.RowNo;
END;');

EXEC(N'CREATE OR ALTER PROCEDURE api.GetPriceHistory @OrganizationId int, @ItemId nvarchar(100), @PriceList nvarchar(40) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SELECT price.PriceList, NetPrice = price.Net, price.VatRate, price.ValidFrom, price.IsActive,
    ChangePct = CASE WHEN LAG(price.Net) OVER (PARTITION BY price.PriceList ORDER BY price.ValidFrom) > 0
      THEN CAST((price.Net - LAG(price.Net) OVER (PARTITION BY price.PriceList ORDER BY price.ValidFrom)) * 100.0
                / LAG(price.Net) OVER (PARTITION BY price.PriceList ORDER BY price.ValidFrom) AS decimal(9, 2)) END
  FROM canon.ProductPrice AS price
  INNER JOIN canon.Product AS product ON product.ProductId = price.ProductId
  WHERE product.OrganizationId = @OrganizationId AND product.ItemID = @ItemId
    AND (@PriceList IS NULL OR price.PriceList = @PriceList)
  ORDER BY price.PriceList, price.ValidFrom DESC;
END;');

/* Primerjava prodajne in nabavne cene (faktor marže). Prag FAKTOR_MARZE iz pim.CheckThreshold. */
EXEC(N'CREATE OR ALTER PROCEDURE api.GetPriceComparison
  @OrganizationId int,
  @SellList nvarchar(40) = N''B2C'',
  @CostList nvarchar(40) = NULL,
  @MinFactor decimal(9, 4) = NULL,
  @MaxFactor decimal(9, 4) = NULL,
  @BelowThreshold bit = NULL,
  @Supplier nvarchar(100) = NULL,
  @OnlyActive bit = 1,
  @Sort nvarchar(20) = N''factor'',
  @Lang nvarchar(10) = N''sl'',
  @Skip int = 0,
  @Take int = 100,
  @TotalCount int = NULL OUTPUT
AS
BEGIN
  SET NOCOUNT ON;
  IF @Skip < 0 SET @Skip = 0;
  IF @Take IS NULL OR @Take < 1 SET @Take = 100;
  IF @Take > 1000 SET @Take = 1000;
  DECLARE @Now datetime2(3) = SYSUTCDATETIME();
  IF @CostList IS NULL SET @CostList = ISNULL((SELECT CostPriceList FROM ana.Setting WHERE OrganizationId = @OrganizationId), N''NAB'');
  DECLARE @Threshold decimal(19, 4) = (SELECT TOP (1) Threshold FROM pim.CheckThreshold
    WHERE CheckCode = N''FAKTOR_MARZE'' AND IsActive = 1 AND (OrganizationId = @OrganizationId OR OrganizationId IS NULL)
    ORDER BY CASE WHEN OrganizationId IS NULL THEN 1 ELSE 0 END);

  CREATE TABLE #cmp
  (
    RowNo int NULL, ProductId bigint NOT NULL PRIMARY KEY, CostNet decimal(19, 6) NULL, SellNet decimal(19, 6) NULL,
    Factor decimal(19, 4) NULL, SellValidFrom datetime2(3) NULL, CostValidFrom datetime2(3) NULL
  );
  INSERT #cmp (ProductId, CostNet, SellNet, Factor, SellValidFrom, CostValidFrom)
  SELECT sell.ProductId, cost.Net, sell.Net,
    Factor = CASE WHEN cost.Net > 0 THEN CAST(sell.Net / cost.Net AS decimal(19, 4)) END, sell.ValidFrom, cost.ValidFrom
  FROM api.CurrentPrice(@OrganizationId, @Now) AS sell
  INNER JOIN api.CurrentPrice(@OrganizationId, @Now) AS cost ON cost.ProductId = sell.ProductId AND cost.PriceList = @CostList
  INNER JOIN canon.Product AS product ON product.ProductId = sell.ProductId
  WHERE sell.PriceList = @SellList
    AND (@OnlyActive = 0 OR product.IsActive = 1)
    AND (@Supplier IS NULL OR product.Supplier = @Supplier);

  DELETE #cmp WHERE (@MinFactor IS NOT NULL AND (Factor IS NULL OR Factor < @MinFactor))
    OR (@MaxFactor IS NOT NULL AND (Factor IS NULL OR Factor > @MaxFactor))
    OR (@BelowThreshold = 1 AND (Factor IS NULL OR @Threshold IS NULL OR Factor >= @Threshold))
    OR (@BelowThreshold = 0 AND Factor < @Threshold);

  SELECT @TotalCount = COUNT(*) FROM #cmp;

  WITH ordered AS
  (
    SELECT cmp.RowNo, NewRowNo = ROW_NUMBER() OVER (ORDER BY
      CASE WHEN @Sort = N''factor'' THEN cmp.Factor END ASC,
      CASE WHEN @Sort = N''-factor'' THEN cmp.Factor END DESC,
      product.ItemID)
    FROM #cmp AS cmp INNER JOIN canon.Product AS product ON product.ProductId = cmp.ProductId
  )
  UPDATE ordered SET RowNo = NewRowNo;

  SELECT ItemId = product.ItemID, cmp.ProductId,
    Name = (SELECT TOP (1) t.Value FROM canon.ProductText AS t WHERE t.ProductId = cmp.ProductId AND t.TextType = N''TITLE_ERP''
            ORDER BY CASE WHEN t.Lang = @Lang THEN 0 WHEN t.Lang = N''sl'' THEN 1 ELSE 2 END),
    SupplierCode = product.Supplier, product.IsActive,
    CostPriceList = @CostList, CostNetPrice = cmp.CostNet, cmp.CostValidFrom,
    SellPriceList = @SellList, SellNetPrice = cmp.SellNet, cmp.SellValidFrom,
    cmp.Factor, MarginPct = CASE WHEN cmp.SellNet > 0 THEN CAST((cmp.SellNet - cmp.CostNet) * 100.0 / cmp.SellNet AS decimal(9, 2)) END,
    Threshold = @Threshold, BelowThreshold = CAST(CASE WHEN cmp.Factor < @Threshold THEN 1 ELSE 0 END AS bit)
  FROM #cmp AS cmp
  INNER JOIN canon.Product AS product ON product.ProductId = cmp.ProductId
  WHERE cmp.RowNo > @Skip AND cmp.RowNo <= @Skip + @Take
  ORDER BY cmp.RowNo;
END;');

/* ===================================================================================================
   Zaloga
   =================================================================================================== */

/* Zaloga po izdelkih podjetja. @Source: ERP (lastna, SAOP), DOBAVITELJ (NW, BT), VSE.
   @BelowMinimum = 1: ERP zaloga pod minimalno zalogo iz SAOP (canon.ProductStockPolicy). */
EXEC(N'CREATE OR ALTER PROCEDURE api.GetStock
  @OrganizationId int,
  @Source nvarchar(20) = N''ERP'',
  @Search nvarchar(200) = NULL,
  @ItemIds nvarchar(max) = NULL,
  @Supplier nvarchar(100) = NULL,
  @ItemGroup nvarchar(100) = NULL,
  @OnlyPositive bit = 0,
  @OnlyNegative bit = 0,
  @BelowMinimum bit = 0,
  @OnlyActive bit = NULL,
  @Sort nvarchar(20) = N''-quantity'',
  @Lang nvarchar(10) = N''sl'',
  @Skip int = 0,
  @Take int = 100,
  @TotalCount int = NULL OUTPUT
AS
BEGIN
  SET NOCOUNT ON;
  IF @Skip < 0 SET @Skip = 0;
  IF @Take IS NULL OR @Take < 1 SET @Take = 100;
  IF @Take > 1000 SET @Take = 1000;
  IF @Source NOT IN (N''ERP'', N''DOBAVITELJ'', N''VSE'') SET @Source = N''ERP'';
  DECLARE @Now datetime2(3) = SYSUTCDATETIME();
  DECLARE @CostList nvarchar(40) = ISNULL((SELECT CostPriceList FROM ana.Setting WHERE OrganizationId = @OrganizationId), N''NAB'');
  DECLARE @Like nvarchar(210) = CASE WHEN NULLIF(LTRIM(RTRIM(@Search)), N'''') IS NULL THEN NULL
    ELSE N''%'' + REPLACE(REPLACE(REPLACE(LTRIM(RTRIM(@Search)), N''['', N''[[]''), N''%'', N''[%]''), N''_'', N''[_]'') + N''%'' END;

  CREATE TABLE #item (ItemID nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY);
  IF NULLIF(LTRIM(RTRIM(@ItemIds)), N'''') IS NOT NULL
    INSERT #item (ItemID) SELECT DISTINCT TOP (500) LTRIM(RTRIM(value)) FROM STRING_SPLIT(@ItemIds, N'','') WHERE LTRIM(RTRIM(value)) <> N'''';

  CREATE TABLE #s
  (
    RowNo int NULL, ProductId bigint NOT NULL PRIMARY KEY,
    ErpQuantity decimal(19, 4) NULL, ErpCustomerOrdered decimal(19, 4) NULL, ErpForShipment decimal(19, 4) NULL,
    ErpAvailable decimal(19, 4) NULL, ErpSupplierOrdered decimal(19, 4) NULL, ErpSnapshotUtc datetime2(3) NULL,
    SupplierQuantity decimal(19, 4) NULL, SupplierIncoming decimal(19, 4) NULL, SupplierAvailabilityDate date NULL, SupplierSnapshotUtc datetime2(3) NULL,
    MinimumStock decimal(19, 4) NULL, MaximumStock decimal(19, 4) NULL
  );
  INSERT #s (ProductId, ErpQuantity, ErpCustomerOrdered, ErpForShipment, ErpAvailable, ErpSupplierOrdered, ErpSnapshotUtc,
    SupplierQuantity, SupplierIncoming, SupplierAvailabilityDate, SupplierSnapshotUtc)
  SELECT stock.ProductId, stock.ErpQuantity, stock.ErpCustomerOrdered, stock.ErpForShipment, stock.ErpAvailable, stock.ErpSupplierOrdered, stock.ErpSnapshotUtc,
    stock.SupplierQuantity, stock.SupplierIncoming, stock.SupplierAvailabilityDate, stock.SupplierSnapshotUtc
  FROM api.StockByProduct(@OrganizationId) AS stock
  INNER JOIN canon.Product AS product ON product.ProductId = stock.ProductId
  WHERE (@Source = N''VSE'' OR @Source = N''ERP'' AND stock.ErpSnapshotUtc IS NOT NULL OR @Source = N''DOBAVITELJ'' AND stock.SupplierSnapshotUtc IS NOT NULL)
    AND (@Supplier IS NULL OR product.Supplier = @Supplier)
    AND (@ItemGroup IS NULL OR product.ItemGroup = @ItemGroup)
    AND (@OnlyActive IS NULL OR product.IsActive = @OnlyActive)
    AND (NOT EXISTS (SELECT 1 FROM #item) OR product.ItemID IN (SELECT ItemID FROM #item));

  /* Pod minimalno zalogo morajo priti tudi izdelki z MIN in brez vsake pozicije (zaloga 0). */
  IF @BelowMinimum = 1
    INSERT #s (ProductId)
    SELECT product.ProductId
    FROM canon.Product AS product
    WHERE product.OrganizationId = @OrganizationId AND product.IsActive = 1
      AND EXISTS (SELECT 1 FROM canon.ProductStockPolicy AS p WHERE p.ProductId = product.ProductId AND p.MinimumStock > 0)
      AND NOT EXISTS (SELECT 1 FROM #s WHERE #s.ProductId = product.ProductId)
      AND (@Supplier IS NULL OR product.Supplier = @Supplier)
      AND (@ItemGroup IS NULL OR product.ItemGroup = @ItemGroup)
      AND (NOT EXISTS (SELECT 1 FROM #item) OR product.ItemID IN (SELECT ItemID FROM #item));

  UPDATE s SET MinimumStock = policy.MinimumStock, MaximumStock = policy.MaximumStock
  FROM #s AS s
  CROSS APPLY (SELECT MinimumStock = SUM(p.MinimumStock), MaximumStock = SUM(p.MaximumStock)
               FROM canon.ProductStockPolicy AS p WHERE p.ProductId = s.ProductId) AS policy;

  IF @Like IS NOT NULL
    DELETE s FROM #s AS s INNER JOIN canon.Product AS product ON product.ProductId = s.ProductId
    WHERE NOT (product.ItemID COLLATE Latin1_General_100_CI_AI LIKE @Like COLLATE Latin1_General_100_CI_AI
      OR ISNULL(product.EAN, N'''') LIKE @Like
      OR EXISTS (SELECT 1 FROM canon.ProductText AS t WHERE t.ProductId = s.ProductId
                   AND t.TextType IN (N''TITLE_ERP'', N''WEB_TITLE'', N''SEARCH_NAME'')
                   AND t.Value COLLATE Latin1_General_100_CI_AI LIKE @Like COLLATE Latin1_General_100_CI_AI));

  DELETE #s WHERE (@OnlyPositive = 1 AND ISNULL(CASE WHEN @Source = N''DOBAVITELJ'' THEN SupplierQuantity ELSE ErpQuantity END, 0) <= 0)
    OR (@OnlyNegative = 1 AND ISNULL(ErpQuantity, 0) >= 0)
    OR (@BelowMinimum = 1 AND (ISNULL(MinimumStock, 0) <= 0 OR ISNULL(ErpQuantity, 0) >= MinimumStock));

  SELECT @TotalCount = COUNT(*) FROM #s;

  WITH ordered AS
  (
    SELECT s.RowNo, NewRowNo = ROW_NUMBER() OVER (ORDER BY
      CASE WHEN @Sort = N''-quantity'' THEN -ISNULL(CASE WHEN @Source = N''DOBAVITELJ'' THEN s.SupplierQuantity ELSE s.ErpQuantity END, 0)
           WHEN @Sort = N''quantity'' THEN ISNULL(CASE WHEN @Source = N''DOBAVITELJ'' THEN s.SupplierQuantity ELSE s.ErpQuantity END, 0) END,
      product.ItemID)
    FROM #s AS s INNER JOIN canon.Product AS product ON product.ProductId = s.ProductId
  )
  UPDATE ordered SET RowNo = NewRowNo;

  SELECT ItemId = product.ItemID, s.ProductId, Ean = product.EAN,
    Name = (SELECT TOP (1) t.Value FROM canon.ProductText AS t WHERE t.ProductId = s.ProductId AND t.TextType = N''TITLE_ERP''
            ORDER BY CASE WHEN t.Lang = @Lang THEN 0 WHEN t.Lang = N''sl'' THEN 1 ELSE 2 END),
    product.IsActive, SupplierCode = product.Supplier, product.ItemGroup, Uom = product.UoM,
    s.ErpQuantity, s.ErpCustomerOrdered, s.ErpForShipment, s.ErpAvailable, s.ErpSupplierOrdered, s.ErpSnapshotUtc,
    s.SupplierQuantity, s.SupplierIncoming, s.SupplierAvailabilityDate, s.SupplierSnapshotUtc,
    s.MinimumStock, s.MaximumStock,
    CostPrice = cost.Net, StockValue = CAST(CASE WHEN s.ErpQuantity > 0 THEN s.ErpQuantity * cost.Net END AS decimal(19, 2))
  FROM #s AS s
  INNER JOIN canon.Product AS product ON product.ProductId = s.ProductId
  OUTER APPLY (SELECT TOP (1) price.Net FROM canon.ProductPrice AS price
               WHERE price.ProductId = s.ProductId AND price.PriceList = @CostList AND price.IsActive = 1 AND price.ValidFrom <= @Now
               ORDER BY price.ValidFrom DESC) AS cost
  WHERE s.RowNo > @Skip AND s.RowNo <= @Skip + @Take
  ORDER BY s.RowNo;
END;');

/* Povzetek zaloge po skupinah: skupno, dobavitelj, proizvajalec, skupina (ItemGroup), oddelek.
   Vrednost po nabavni ceni (NAB ali ana.Setting.CostPriceList) in po maloprodajni (B2C). */
EXEC(N'CREATE OR ALTER PROCEDURE api.GetStockSummary
  @OrganizationId int,
  @GroupBy nvarchar(20) = N''skupno'',
  @Top int = 100
AS
BEGIN
  SET NOCOUNT ON;
  IF @Top IS NULL OR @Top < 1 SET @Top = 100;
  IF @Top > 1000 SET @Top = 1000;
  DECLARE @Now datetime2(3) = SYSUTCDATETIME();
  DECLARE @CostList nvarchar(40) = ISNULL((SELECT CostPriceList FROM ana.Setting WHERE OrganizationId = @OrganizationId), N''NAB'');

  CREATE TABLE #s (ProductId bigint NOT NULL PRIMARY KEY, ErpQuantity decimal(19, 4) NULL, ErpAvailable decimal(19, 4) NULL,
    SupplierQuantity decimal(19, 4) NULL, CostNet decimal(19, 6) NULL, RetailNet decimal(19, 6) NULL);
  INSERT #s (ProductId, ErpQuantity, ErpAvailable, SupplierQuantity)
  SELECT ProductId, ErpQuantity, ErpAvailable, SupplierQuantity FROM api.StockByProduct(@OrganizationId);

  UPDATE s SET CostNet = cost.Net, RetailNet = retail.Net
  FROM #s AS s
  LEFT JOIN api.CurrentPrice(@OrganizationId, @Now) AS cost ON cost.ProductId = s.ProductId AND cost.PriceList = @CostList
  LEFT JOIN api.CurrentPrice(@OrganizationId, @Now) AS retail ON retail.ProductId = s.ProductId AND retail.PriceList = N''B2C'';

  SELECT TOP (@Top)
    GroupCode = grouped.GroupCode,
    GroupName = CASE WHEN @GroupBy IN (N''dobavitelj'', N''proizvajalec'')
      THEN (SELECT TOP (1) PartnerName FROM canon.PartnerName WHERE OrganizationId = @OrganizationId AND PartnerCode = grouped.GroupCode) END,
    grouped.Items, grouped.ItemsInStock, grouped.ItemsNegative, grouped.Quantity, grouped.AvailableQuantity,
    grouped.CostValue, grouped.RetailValue, grouped.ItemsWithoutCost, grouped.SupplierQuantity
  FROM
  (
    SELECT GroupCode = CASE @GroupBy WHEN N''dobavitelj'' THEN product.Supplier WHEN N''proizvajalec'' THEN product.Manufacturer
                         WHEN N''skupina'' THEN product.ItemGroup WHEN N''oddelek'' THEN product.Department ELSE N''SKUPAJ'' END,
      Items = COUNT(*),
      ItemsInStock = SUM(CASE WHEN s.ErpQuantity > 0 THEN 1 ELSE 0 END),
      ItemsNegative = SUM(CASE WHEN s.ErpQuantity < 0 THEN 1 ELSE 0 END),
      Quantity = SUM(CASE WHEN s.ErpQuantity > 0 THEN s.ErpQuantity ELSE 0 END),
      AvailableQuantity = SUM(CASE WHEN s.ErpAvailable > 0 THEN s.ErpAvailable ELSE 0 END),
      CostValue = CAST(SUM(CASE WHEN s.ErpQuantity > 0 THEN s.ErpQuantity * s.CostNet ELSE 0 END) AS decimal(19, 2)),
      RetailValue = CAST(SUM(CASE WHEN s.ErpQuantity > 0 THEN s.ErpQuantity * s.RetailNet ELSE 0 END) AS decimal(19, 2)),
      ItemsWithoutCost = SUM(CASE WHEN s.ErpQuantity > 0 AND s.CostNet IS NULL THEN 1 ELSE 0 END),
      SupplierQuantity = SUM(CASE WHEN s.SupplierQuantity > 0 THEN s.SupplierQuantity ELSE 0 END)
    FROM #s AS s
    INNER JOIN canon.Product AS product ON product.ProductId = s.ProductId
    GROUP BY CASE @GroupBy WHEN N''dobavitelj'' THEN product.Supplier WHEN N''proizvajalec'' THEN product.Manufacturer
                 WHEN N''skupina'' THEN product.ItemGroup WHEN N''oddelek'' THEN product.Department ELSE N''SKUPAJ'' END
  ) AS grouped
  ORDER BY grouped.CostValue DESC, grouped.Quantity DESC;
END;');

/* ===================================================================================================
   Stranke
   =================================================================================================== */
EXEC(N'CREATE OR ALTER PROCEDURE api.SearchCustomers
  @OrganizationId int,
  @Search nvarchar(200) = NULL,
  @IsActive bit = NULL,
  @CustomerType nvarchar(20) = NULL,
  @PriceList nvarchar(40) = NULL,
  @SalesClerk nvarchar(40) = NULL,
  @City nvarchar(100) = NULL,
  @Country nvarchar(100) = NULL,
  @Skip int = 0,
  @Take int = 50,
  @TotalCount int = NULL OUTPUT
AS
BEGIN
  SET NOCOUNT ON;
  IF @Skip < 0 SET @Skip = 0;
  IF @Take IS NULL OR @Take < 1 SET @Take = 50;
  IF @Take > 500 SET @Take = 500;
  DECLARE @Like nvarchar(210) = CASE WHEN NULLIF(LTRIM(RTRIM(@Search)), N'''') IS NULL THEN NULL
    ELSE N''%'' + REPLACE(REPLACE(REPLACE(LTRIM(RTRIM(@Search)), N''['', N''[[]''), N''%'', N''[%]''), N''_'', N''[_]'') + N''%'' END;

  CREATE TABLE #c (RowNo int IDENTITY(1, 1) PRIMARY KEY, CustomerId bigint NOT NULL);
  INSERT #c (CustomerId)
  SELECT customer.CustomerId
  FROM b2b.Customer AS customer
  WHERE customer.OrganizationId = @OrganizationId
    AND (@IsActive IS NULL OR ISNULL(customer.IsActive, 1) = @IsActive)
    AND (@CustomerType IS NULL OR customer.CustomerType = @CustomerType)
    AND (@PriceList IS NULL OR customer.PriceListCode = @PriceList)
    AND (@SalesClerk IS NULL OR customer.SalesClerkCode = @SalesClerk)
    AND (@City IS NULL OR customer.City COLLATE Latin1_General_100_CI_AI = @City COLLATE Latin1_General_100_CI_AI)
    AND (@Country IS NULL OR customer.Country = @Country)
    AND (@Like IS NULL
      OR customer.Name COLLATE Latin1_General_100_CI_AI LIKE @Like COLLATE Latin1_General_100_CI_AI
      OR customer.CustomerKey LIKE @Like
      OR ISNULL(customer.TaxNumber, N'''') LIKE @Like
      OR ISNULL(customer.RegistrationNumber, N'''') LIKE @Like
      OR ISNULL(customer.City, N'''') COLLATE Latin1_General_100_CI_AI LIKE @Like COLLATE Latin1_General_100_CI_AI)
  ORDER BY customer.Name
  OPTION (RECOMPILE);

  SELECT @TotalCount = COUNT(*) FROM #c;

  SELECT customer.CustomerId, customer.CustomerKey, customer.Name, customer.IsActive, customer.CustomerType, customer.LegalForm,
    customer.Street, customer.HouseNumber, customer.PostalCode, customer.City, customer.Country, customer.Address,
    customer.TaxNumber, customer.RegistrationNumber, customer.SubjectToVat, customer.ActivityCode,
    customer.PayerCode, customer.PayerName, customer.PriceListCode, customer.DiscountPriceListCode,
    customer.PaymentDays, customer.RebatePercent, customer.IsDefaulter, customer.UpfrontPayment,
    customer.CurrencyCode, customer.LanguageId, customer.SalesClerkCode, SalesClerkName = clerk.Name, customer.UpdatedUtc,
    CustomerItems = (SELECT COUNT(*) FROM b2b.CustomerItem AS item WHERE item.OrganizationId = @OrganizationId AND item.CustomerKey = customer.CustomerKey)
  FROM #c AS c
  INNER JOIN b2b.Customer AS customer ON customer.CustomerId = c.CustomerId
  LEFT JOIN pim.SalesClerk AS clerk ON clerk.OrganizationId = customer.OrganizationId AND clerk.SalesClerkCode = customer.SalesClerkCode
  WHERE c.RowNo > @Skip AND c.RowNo <= @Skip + @Take
  ORDER BY c.RowNo;
END;');

/* Kartica stranke: stranka, popusti po skupinah artiklov (veljavni danes), artikli stranke (šifre in cene). */
EXEC(N'CREATE OR ALTER PROCEDURE api.GetCustomer @OrganizationId int, @CustomerKey nvarchar(100), @Lang nvarchar(10) = N''sl''
AS
BEGIN
  SET NOCOUNT ON;
  DECLARE @Today date = CONVERT(date, SYSDATETIME());
  DECLARE @DiscountGroup nvarchar(100) = (SELECT TOP (1) DiscountPriceListCode FROM b2b.Customer WHERE OrganizationId = @OrganizationId AND CustomerKey = @CustomerKey);

  SELECT TOP (1) customer.CustomerId, customer.CustomerKey, customer.Name, customer.IsActive, customer.CustomerType, customer.LegalForm,
    customer.Street, customer.HouseNumber, customer.PostalCode, customer.City, customer.Country, customer.Address,
    customer.TaxNumber, customer.RegistrationNumber, customer.SubjectToVat, customer.ActivityCode,
    customer.PayerCode, customer.PayerName, customer.PriceListCode, customer.DiscountPriceListCode,
    customer.PaymentDays, customer.RebatePercent, customer.IsDefaulter, customer.UpfrontPayment,
    customer.CurrencyCode, customer.LanguageId, customer.SalesClerkCode, SalesClerkName = clerk.Name, customer.UpdatedUtc
  FROM b2b.Customer AS customer
  LEFT JOIN pim.SalesClerk AS clerk ON clerk.OrganizationId = customer.OrganizationId AND clerk.SalesClerkCode = customer.SalesClerkCode
  WHERE customer.OrganizationId = @OrganizationId AND customer.CustomerKey = @CustomerKey;

  SELECT discount.CustomerGroupCode, discount.ItemGroupCode, discount.DiscountPercent, discount.MinQuantity, discount.ValidFrom, discount.ValidTo
  FROM b2b.CustomerItemGroupDiscount AS discount
  WHERE discount.OrganizationId = @OrganizationId AND discount.CustomerGroupCode = @DiscountGroup
    AND (discount.ValidFrom IS NULL OR discount.ValidFrom <= @Today) AND (discount.ValidTo IS NULL OR discount.ValidTo >= @Today)
  ORDER BY discount.ItemGroupCode, discount.MinQuantity;

  SELECT TOP (1000) ItemId = product.ItemID, item.ProductId,
    Name = (SELECT TOP (1) t.Value FROM canon.ProductText AS t WHERE t.ProductId = item.ProductId AND t.TextType = N''TITLE_ERP''
            ORDER BY CASE WHEN t.Lang = @Lang THEN 0 WHEN t.Lang = N''sl'' THEN 1 ELSE 2 END),
    item.CustomerItemCode, item.OrderingAllowed, item.OrderingPrice, item.OrderingDiscount, item.OrderingCurrencyCode,
    item.ConvertFactor, item.MinimalOrderQuantity, item.OrderingMultiplier, item.OrderingStep, item.LeadTimeDays, item.UpdatedUtc
  FROM b2b.CustomerItem AS item
  INNER JOIN canon.Product AS product ON product.ProductId = item.ProductId
  WHERE item.OrganizationId = @OrganizationId AND item.CustomerKey = @CustomerKey
  ORDER BY product.ItemID;
END;');

/* ===================================================================================================
   Nabava (naročila dobaviteljem) in analitika
   =================================================================================================== */
EXEC(N'CREATE OR ALTER PROCEDURE api.GetPurchaseOrderLines
  @OrganizationId int,
  @Supplier nvarchar(100) = NULL,
  @ItemId nvarchar(100) = NULL,
  @Status nvarchar(40) = NULL,
  @OpenOnly bit = 1,
  @DueBefore date = NULL,
  @OrderedSince date = NULL,
  @Skip int = 0,
  @Take int = 100,
  @TotalCount int = NULL OUTPUT
AS
BEGIN
  SET NOCOUNT ON;
  IF @Skip < 0 SET @Skip = 0;
  IF @Take IS NULL OR @Take < 1 SET @Take = 100;
  IF @Take > 1000 SET @Take = 1000;

  CREATE TABLE #l (RowNo int IDENTITY(1, 1) PRIMARY KEY, PurchaseOrderLineId bigint NOT NULL);
  INSERT #l (PurchaseOrderLineId)
  SELECT line.PurchaseOrderLineId
  FROM purch.PurchaseOrderLine AS line
  INNER JOIN purch.PurchaseOrderHeader AS header ON header.PurchaseOrderHeaderId = line.PurchaseOrderHeaderId
  WHERE header.OrganizationId = @OrganizationId
    AND (@Supplier IS NULL OR header.SupplierID = @Supplier)
    AND (@ItemId IS NULL OR line.ItemID = @ItemId)
    AND (@Status IS NULL OR header.Status = @Status)
    AND (@OpenOnly = 0 OR (header.Status NOT IN (N''Zaključeno'', N''Stornirano'') AND ISNULL(line.CanceledLine, 0) = 0))
    AND (@DueBefore IS NULL OR COALESCE(line.ForeseenDeliveryDate, header.ForeseenDeliveryDate) < @DueBefore)
    AND (@OrderedSince IS NULL OR header.OrderDate >= @OrderedSince)
  ORDER BY COALESCE(line.ForeseenDeliveryDate, header.ForeseenDeliveryDate), header.PurchaseOrderNumber, line.LineSEQNumber
  OPTION (RECOMPILE);

  SELECT @TotalCount = COUNT(*) FROM #l;

  SELECT header.PurchaseOrderYear, header.PurchaseOrderBook, header.PurchaseOrderNumber, header.SupplierID,
    SupplierName = (SELECT TOP (1) PartnerName FROM canon.PartnerName WHERE OrganizationId = @OrganizationId AND PartnerCode = header.SupplierID),
    header.Status, header.OrderDate, HeaderDeliveryDate = header.ForeseenDeliveryDate, header.WarehouseID,
    header.NetAmountOrder, line.LineSEQNumber, ItemId = line.ItemID, ItemTitle = line.ItemTitle1, Ean = line.ItemEAN,
    line.OrderedQuantity, line.UnitOfMeasure, LineDeliveryDate = line.ForeseenDeliveryDate, LineStatus = line.Status,
    line.CanceledLine, line.NetAmountOrdered,
    IsOverdue = CAST(CASE WHEN header.Status NOT IN (N''Zaključeno'', N''Stornirano'')
      AND COALESCE(line.ForeseenDeliveryDate, header.ForeseenDeliveryDate) < CONVERT(date, SYSDATETIME()) THEN 1 ELSE 0 END AS bit)
  FROM #l AS l
  INNER JOIN purch.PurchaseOrderLine AS line ON line.PurchaseOrderLineId = l.PurchaseOrderLineId
  INNER JOIN purch.PurchaseOrderHeader AS header ON header.PurchaseOrderHeaderId = line.PurchaseOrderHeaderId
  WHERE l.RowNo > @Skip AND l.RowNo <= @Skip + @Take
  ORDER BY l.RowNo;
END;');

/* Kazalniki artiklov iz analitike (ana.ItemMetric; polni jo posel SAOP_ANALYTICS). */
EXEC(N'CREATE OR ALTER PROCEDURE api.GetItemMetrics
  @OrganizationId int,
  @Signal nvarchar(40) = NULL,
  @AbcClass char(1) = NULL,
  @Supplier nvarchar(100) = NULL,
  @Search nvarchar(200) = NULL,
  @OnlySuggested bit = 0,
  @Sort nvarchar(30) = N''-suggestedValue'',
  @Skip int = 0,
  @Take int = 100,
  @TotalCount int = NULL OUTPUT
AS
BEGIN
  SET NOCOUNT ON;
  IF @Skip < 0 SET @Skip = 0;
  IF @Take IS NULL OR @Take < 1 SET @Take = 100;
  IF @Take > 1000 SET @Take = 1000;
  DECLARE @Like nvarchar(210) = CASE WHEN NULLIF(LTRIM(RTRIM(@Search)), N'''') IS NULL THEN NULL
    ELSE N''%'' + REPLACE(REPLACE(REPLACE(LTRIM(RTRIM(@Search)), N''['', N''[[]''), N''%'', N''[%]''), N''_'', N''[_]'') + N''%'' END;

  CREATE TABLE #m (RowNo int IDENTITY(1, 1) PRIMARY KEY, ProductId bigint NOT NULL);
  INSERT #m (ProductId)
  SELECT metric.ProductId
  FROM ana.ItemMetric AS metric
  WHERE metric.OrganizationId = @OrganizationId
    AND (@Signal IS NULL OR metric.Signal = @Signal)
    AND (@AbcClass IS NULL OR metric.AbcClass = @AbcClass)
    AND (@Supplier IS NULL OR metric.SupplierId = @Supplier)
    AND (@OnlySuggested = 0 OR metric.SuggestedQty > 0)
    AND (@Like IS NULL OR metric.ItemId LIKE @Like
         OR ISNULL(metric.ItemName, N'''') COLLATE Latin1_General_100_CI_AI LIKE @Like COLLATE Latin1_General_100_CI_AI)
  ORDER BY
    CASE WHEN @Sort = N''-suggestedValue'' THEN metric.SuggestedValue END DESC,
    CASE WHEN @Sort = N''-sales365'' THEN metric.Sales365Net END DESC,
    CASE WHEN @Sort = N''-excessValue'' THEN metric.ExcessValue END DESC,
    CASE WHEN @Sort = N''-stockValue'' THEN metric.StockValue END DESC,
    CASE WHEN @Sort = N''coverDays'' THEN metric.CoverDays END ASC,
    metric.ItemId
  OPTION (RECOMPILE);

  SELECT @TotalCount = COUNT(*) FROM #m;

  SELECT metric.ItemId, metric.ProductId, metric.ItemName, metric.Ean, metric.SupplierId, metric.SupplierName, metric.ItemGroup, metric.Department,
    metric.IsActive, metric.Stock, metric.Reserved, metric.Available, metric.OnOrder, metric.OnOrderSource, metric.NextDeliveryDate,
    metric.UnitCost, metric.CostSource, metric.StockValue, metric.Sales30Qty, metric.Sales90Qty, metric.Sales365Qty, metric.Sales365Net,
    metric.SalesPrev365Qty, metric.SalesPrev365Net, metric.Sales365Margin, metric.AvgSellPrice, metric.Customers365,
    metric.TrendPct, metric.YoyPct, metric.DailyDemand, metric.DemandCv, metric.LastSaleDate, metric.LastReceiptDate, metric.CoverDays,
    metric.LeadTimeDays, metric.LeadTimeSource, metric.SafetyStock, metric.ReorderPoint, metric.OrderUpToLevel, metric.OrderMultiple,
    metric.PolicyMin, metric.PolicyMax, metric.SuggestedQty, metric.SuggestedValue, metric.SuggestionReason,
    metric.ExcessQty, metric.ExcessValue, metric.AbcClass, metric.XyzClass, metric.Signal, metric.DemandSource, metric.CalculatedUtc
  FROM #m AS m
  INNER JOIN ana.ItemMetric AS metric ON metric.OrganizationId = @OrganizationId AND metric.ProductId = m.ProductId
  WHERE m.RowNo > @Skip AND m.RowNo <= @Skip + @Take
  ORDER BY m.RowNo;
END;');

EXEC(N'CREATE OR ALTER PROCEDURE api.GetSupplierMetrics @OrganizationId int, @Top int = 200
AS
BEGIN
  SET NOCOUNT ON;
  IF @Top IS NULL OR @Top < 1 SET @Top = 200;
  IF @Top > 2000 SET @Top = 2000;
  SELECT TOP (@Top) metric.SupplierId, metric.SupplierName, metric.Items, metric.ItemsInStock, metric.ItemsSold365, metric.StockValue,
    metric.Sales365Net, metric.SalesPrev365Net, metric.Sales365Margin, metric.YoyPct, metric.ItemsToOrder, metric.SuggestedOrderValue,
    metric.StockoutItems, metric.DeadItems, metric.DeadStockValue, metric.OverstockValue, metric.LeadTimeAvgDays, metric.LeadTimeSamples,
    metric.OpenPurchaseLines, metric.OverduePurchaseLines, metric.LastPurchaseOrderDate, metric.CalculatedUtc
  FROM ana.SupplierMetric AS metric
  WHERE metric.OrganizationId = @OrganizationId
  ORDER BY metric.Sales365Net DESC, metric.StockValue DESC;
END;');

/* ===================================================================================================
   Pravice: vloga API-ja sme samo izvajati postopke sheme api, skrbniških ne.
   =================================================================================================== */
GRANT EXECUTE ON SCHEMA::api TO pim_api_reader;
DENY EXECUTE ON OBJECT::api.Admin_CreateClient TO pim_api_reader;
DENY EXECUTE ON OBJECT::api.Admin_UpdateClient TO pim_api_reader;
DENY EXECUTE ON OBJECT::api.Admin_RevokeClient TO pim_api_reader;
DENY EXECUTE ON OBJECT::api.Admin_ListClients TO pim_api_reader;
DENY SELECT ON OBJECT::api.Client TO pim_api_reader;
DENY SELECT ON OBJECT::api.ClientHistory TO pim_api_reader;
DENY SELECT ON OBJECT::api.RequestLog TO pim_api_reader;
