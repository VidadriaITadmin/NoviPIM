/*
  267 — Zaloga: filtri po skladišču in dobavitelju, posebnosti, razvrščanje; pregled skladišč.

  Uporabnik 2026-09-22: »stran zaloge mi tudi preoblikuj kot izdelki in stranke, da ima izvoze …
  dodaj pametne in uporabne filtre, če ne drugega manjkajo skladišča. Pod stranjo skladišča bi
  lahko dodali seznam skladišč po podjetju in na vsakem skladišču celotno zalogo.«

  1. intranet.GetStockByItem dobi nove parametre (stari klici ostanejo veljavni):
       @ErpSource      SAOP vir (= skladišče podjetja). Za razliko od @SourceCode vrstice NE oklesti
                       na en vir: artikel ostane cel, z dobaviteljevim delom vred.
       @SupplierSource dobaviteljev vir (NW_STOCK, BT_STOCK …), enako — vrstica ostane cela.
       @Signal         BELOW_MIN (pod minimalno), ABOVE_MAX (nad maksimalno), NEGATIVE (negativna
                       SAOP količina), LATE (prihod je že mimo, količina pa še prihaja), UNMATCHED
                       (brez artikla v PIM), NO_ERP (artikel ni v SAOP zalogi, samo pri dobavitelju).
       @Sort           ITEM (privzeto), NAME, ERP_DESC, ERP_ASC, SUPPLIER_DESC, INCOMING.
     @Availability dobi še SUPPLIER_ONLY: pri nas ni, dobavitelj ima.
     Popravek je REPLACE nad živo definicijo (kot 262, 264), da se ne povozi vzporednih sprememb.

  2. intranet.GetWarehouseStock: skladišča vseh (aktivnih) podjetij in SAOP zaloga, ki jo PIM bere.
     Pozicije zaloge NIMAJO šifre skladišča — SAOP GetStocks vrne vsoto čez izbrana skladišča
     (IQ in Vidadria 0000001, Ediito vsa aktivna). Katero skladišče je v vsoti, se prebere iz
     naslova zadnjega posnetka (warehouseIdList=…), za registrirani pogled pa iz profila vira.
     Količina po posameznem skladišču je zato natančna samo, kadar se bere eno skladišče.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

DECLARE @definicija nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'intranet.GetStockByItem'));
IF @definicija IS NULL THROW 52670, N'267: intranet.GetStockByItem ne obstaja.', 1;

IF CHARINDEX(N'/* 267 */', @definicija) = 0
BEGIN
  DECLARE @zamenjava TABLE (Vrstni int IDENTITY, Staro nvarchar(1000) NOT NULL, Novo nvarchar(max) NOT NULL, Pojavitev int NOT NULL);
  INSERT @zamenjava (Staro, Novo, Pojavitev) VALUES
  (N'@Language nvarchar(20) = N''sl''',
   N'@Language nvarchar(20) = N''sl'',
  @ErpSource nvarchar(100) = NULL, /* 267 */
  @SupplierSource nvarchar(100) = NULL,
  @Signal nvarchar(20) = NULL,
  @Sort nvarchar(20) = NULL', 1),

  (N'IF @Availability NOT IN (N''IN_STOCK'', N''OUT_OF_STOCK'', N''INCOMING'')',
   N'SET @ErpSource = NULLIF(LTRIM(RTRIM(@ErpSource)), N''''); /* 267 */
  SET @SupplierSource = NULLIF(LTRIM(RTRIM(@SupplierSource)), N'''');
  SET @Signal = NULLIF(UPPER(LTRIM(RTRIM(@Signal))), N'''');
  IF @Signal NOT IN (N''BELOW_MIN'', N''ABOVE_MAX'', N''NEGATIVE'', N''LATE'', N''UNMATCHED'', N''NO_ERP'') SET @Signal = NULL;
  SET @Sort = COALESCE(NULLIF(UPPER(LTRIM(RTRIM(@Sort))), N''''), N''ITEM'');
  DECLARE @Today date = CAST(SYSUTCDATETIME() AS date);
  IF @Availability NOT IN (N''IN_STOCK'', N''OUT_OF_STOCK'', N''INCOMING'', N''SUPPLIER_ONLY'')', 1),

  (N'CombinedIncoming decimal(18,4) NOT NULL',
   N'CombinedIncoming decimal(18,4) NOT NULL,
    ErpSourceKeys nvarchar(1000) NULL, /* 267: |SAOP_X|, za filter brez okleščenja vrstice */
    SupplierSourceKeys nvarchar(1000) NULL', 1),

  (N'SupplierCode = STRING_AGG(CASE WHEN ConnectorType <> N''SAOP'' THEN SourceCode END, N'' + '')',
   N'SupplierCode = STRING_AGG(CASE WHEN ConnectorType <> N''SAOP'' THEN SourceCode END, N'' + ''),
      ErpSourceKeys = N''|'' + STRING_AGG(CASE WHEN ConnectorType = N''SAOP'' THEN SourceCode END, N''|'') + N''|'',
      SupplierSourceKeys = N''|'' + STRING_AGG(CASE WHEN ConnectorType <> N''SAOP'' THEN SourceCode END, N''|'') + N''|''', 1),

  (N'MinimumStock, MaximumStock, CombinedQuantity, CombinedIncoming',
   N'MinimumStock, MaximumStock, CombinedQuantity, CombinedIncoming, ErpSourceKeys, SupplierSourceKeys', 1),

  (N'CombinedIncoming = ISNULL(COALESCE(NULLIF(aggregated.ErpOwnIncoming, 0), delivery.Quantity), 0) + ISNULL(aggregated.SupplierIncoming, 0)',
   N'CombinedIncoming = ISNULL(COALESCE(NULLIF(aggregated.ErpOwnIncoming, 0), delivery.Quantity), 0) + ISNULL(aggregated.SupplierIncoming, 0),
    labels.ErpSourceKeys, labels.SupplierSourceKeys', 1),

  -- Oba koncna SELECT-a (vrstice in stetje) imata isti pogoj; novi pogoji gredo pred oklepaj
  -- razpolozljivosti, zaklepaj pa za zadnjo moznostjo razpolozljivosti.
  (N'@Availability IS NULL',
   N'(@ErpSource IS NULL OR ErpSourceKeys LIKE N''%|'' + @ErpSource + N''|%'') /* 267 */
    AND (@SupplierSource IS NULL OR SupplierSourceKeys LIKE N''%|'' + @SupplierSource + N''|%'')
    AND (@Signal IS NULL
      OR (@Signal = N''BELOW_MIN'' AND HasErp = 1 AND MinimumStock > 0 AND ErpQuantity < MinimumStock)
      OR (@Signal = N''ABOVE_MAX'' AND HasErp = 1 AND MaximumStock > 0 AND ErpQuantity > MaximumStock)
      OR (@Signal = N''NEGATIVE'' AND HasErp = 1 AND ErpQuantity < 0)
      OR (@Signal = N''LATE'' AND ((ErpIncomingQuantity > 0 AND ErpIncomingDate < @Today) OR (SupplierIncoming > 0 AND SupplierIncomingDate < @Today)))
      OR (@Signal = N''UNMATCHED'' AND MatchedProductId IS NULL)
      OR (@Signal = N''NO_ERP'' AND HasErp = 0))
    AND (@Availability IS NULL', 2),

  (N'OR (@Availability = N''INCOMING'' AND CombinedIncoming > 0)',
   N'OR (@Availability = N''INCOMING'' AND CombinedIncoming > 0)
    OR (@Availability = N''SUPPLIER_ONLY'' AND ErpQuantity <= 0 AND SupplierQuantity > 0))', 2),

  (N'ORDER BY NormalizedItemId, GroupKey',
   N'ORDER BY /* 267 */
    CASE WHEN @Sort = N''NAME'' THEN ProductName END,
    CASE WHEN @Sort = N''ERP_DESC'' THEN ErpQuantity END DESC,
    CASE WHEN @Sort = N''ERP_ASC'' THEN ErpQuantity END ASC,
    CASE WHEN @Sort = N''SUPPLIER_DESC'' THEN SupplierQuantity END DESC,
    CASE WHEN @Sort = N''INCOMING'' THEN CASE
      WHEN ErpIncomingDate IS NULL THEN ISNULL(SupplierIncomingDate, ''99991231'')
      WHEN SupplierIncomingDate IS NULL OR ErpIncomingDate <= SupplierIncomingDate THEN ErpIncomingDate
      ELSE SupplierIncomingDate END END ASC,
    NormalizedItemId, GroupKey', 1);

  DECLARE @vrstni int = 1, @staro nvarchar(1000), @novo nvarchar(max), @pojavitev int, @najdeno int, @sporocilo nvarchar(2000);
  WHILE EXISTS (SELECT 1 FROM @zamenjava WHERE Vrstni = @vrstni)
  BEGIN
    SELECT @staro = Staro, @novo = Novo, @pojavitev = Pojavitev FROM @zamenjava WHERE Vrstni = @vrstni;
    SET @najdeno = (DATALENGTH(@definicija) - DATALENGTH(REPLACE(@definicija, @staro, N''))) / DATALENGTH(@staro);
    IF @najdeno <> @pojavitev
    BEGIN
      SET @sporocilo = CONCAT(N'267: v intranet.GetStockByItem je »', LEFT(@staro, 80), N'« ', @najdeno, N'-krat, pričakovano ', @pojavitev, N'.');
      THROW 52671, @sporocilo, 1;
    END;
    SET @definicija = REPLACE(@definicija, @staro, @novo);
    SET @vrstni += 1;
  END;

  SET @definicija = STUFF(@definicija, CHARINDEX(N'CREATE', @definicija), LEN(N'CREATE'), N'CREATE OR ALTER');
  EXEC (@definicija);
END;
GO

CREATE OR ALTER PROCEDURE intranet.GetWarehouseStock
  @OrganizationId int = NULL
AS
BEGIN
  SET NOCOUNT ON;

  DECLARE @Organizations TABLE (OrganizationId int NOT NULL PRIMARY KEY, Name nvarchar(200) NOT NULL);
  INSERT @Organizations (OrganizationId, Name)
  SELECT OrganizationId, Name
  FROM dbo.OrganizationConfig
  WHERE (@OrganizationId IS NULL AND IsActive = 1) OR OrganizationId = @OrganizationId;

  /* Zadnji aktivni SAOP posnetek podjetja: iz njega sta vir in seznam prebranih skladišč. */
  DECLARE @Snapshots TABLE
  (
    OrganizationId int NOT NULL PRIMARY KEY, SnapshotId bigint NOT NULL, SourceCode nvarchar(100) NOT NULL,
    ProviderKind nvarchar(100) NULL, Endpoint nvarchar(max) NULL, SnapshotUtc datetime2(3) NULL, WarehouseList nvarchar(max) NULL
  );
  INSERT @Snapshots (OrganizationId, SnapshotId, SourceCode, ProviderKind, Endpoint, SnapshotUtc, WarehouseList)
  SELECT ranked.OrganizationId, ranked.SnapshotId, ranked.SourceCode, ranked.ProviderKind, ranked.Endpoint, ranked.SnapshotUtc,
    CASE WHEN CHARINDEX(N'warehouseIdList=', ranked.Endpoint) > 0 THEN
      REPLACE(REPLACE(
        SUBSTRING(ranked.Endpoint, CHARINDEX(N'warehouseIdList=', ranked.Endpoint) + 16,
          CHARINDEX(N'&', ranked.Endpoint + N'&', CHARINDEX(N'warehouseIdList=', ranked.Endpoint)) - CHARINDEX(N'warehouseIdList=', ranked.Endpoint) - 16),
        N'%2C', N','), N'%2c', N',')
    END
  FROM
  (
    SELECT snapshot.OrganizationId, snapshot.SnapshotId, connector.SourceCode, snapshot.ProviderKind, snapshot.Endpoint, snapshot.SnapshotUtc,
      Rang = ROW_NUMBER() OVER (PARTITION BY snapshot.OrganizationId ORDER BY snapshot.SnapshotUtc DESC, snapshot.SnapshotId DESC)
    FROM stock.Snapshot AS snapshot
    INNER JOIN map.SourceConnector AS connector ON connector.SourceConnectorId = snapshot.SourceConnectorId
    INNER JOIN @Organizations AS organization ON organization.OrganizationId = snapshot.OrganizationId
    WHERE snapshot.IsActive = 1 AND connector.ConnectorType = N'SAOP'
  ) AS ranked
  WHERE ranked.Rang = 1;

  /* Prebrana skladišča: iz naslova posnetka; če ga ni (registrirani pogled), iz omogočenih
     profilov GetStocks — seznam ali vsa aktivna skladišča iz šifranta. */
  DECLARE @ReadWarehouses TABLE (OrganizationId int NOT NULL, WarehouseCode nvarchar(50) NOT NULL, PRIMARY KEY (OrganizationId, WarehouseCode));
  INSERT @ReadWarehouses (OrganizationId, WarehouseCode)
  SELECT DISTINCT source.OrganizationId, LTRIM(RTRIM(part.value))
  FROM @Snapshots AS source
  CROSS APPLY STRING_SPLIT(source.WarehouseList, N',') AS part
  WHERE source.WarehouseList IS NOT NULL AND LTRIM(RTRIM(part.value)) <> N'';

  INSERT @ReadWarehouses (OrganizationId, WarehouseCode)
  SELECT DISTINCT profile.OrganizationId, CONVERT(nvarchar(50), listed.value)
  FROM stock.SaopProviderProfile AS profile
  INNER JOIN @Organizations AS organization ON organization.OrganizationId = profile.OrganizationId
  CROSS APPLY OPENJSON(ISNULL(profile.WarehouseIdsJson, N'[]')) AS listed
  WHERE profile.Enabled = 1 AND profile.WarehouseSelectionMode = N'List'
    AND NOT EXISTS (SELECT 1 FROM @Snapshots AS source WHERE source.OrganizationId = profile.OrganizationId AND source.WarehouseList IS NOT NULL)
    AND NOT EXISTS (SELECT 1 FROM @ReadWarehouses AS existing WHERE existing.OrganizationId = profile.OrganizationId AND existing.WarehouseCode = CONVERT(nvarchar(50), listed.value));

  INSERT @ReadWarehouses (OrganizationId, WarehouseCode)
  SELECT DISTINCT warehouse.OrganizationId, warehouse.WarehouseCode
  FROM canon.Warehouse AS warehouse
  INNER JOIN stock.SaopProviderProfile AS profile
    ON profile.OrganizationId = warehouse.OrganizationId AND profile.Enabled = 1 AND profile.WarehouseSelectionMode = N'ActiveFromRegister'
  WHERE warehouse.IsActive = 1
    AND NOT EXISTS (SELECT 1 FROM @Snapshots AS source WHERE source.OrganizationId = warehouse.OrganizationId AND source.WarehouseList IS NOT NULL)
    AND NOT EXISTS (SELECT 1 FROM @ReadWarehouses AS existing WHERE existing.OrganizationId = warehouse.OrganizationId AND existing.WarehouseCode = warehouse.WarehouseCode);

  /* 1. Skladišča po podjetju. */
  SELECT warehouse.OrganizationId, OrganizationName = organization.Name, warehouse.WarehouseCode, warehouse.Name,
    warehouse.WarehouseType, warehouse.GroupCode, warehouse.IsActive, warehouse.UpdatedUtc,
    IsRead = CAST(CASE WHEN readWarehouse.WarehouseCode IS NULL THEN 0 ELSE 1 END AS bit)
  FROM canon.Warehouse AS warehouse
  INNER JOIN @Organizations AS organization ON organization.OrganizationId = warehouse.OrganizationId
  LEFT JOIN @ReadWarehouses AS readWarehouse
    ON readWarehouse.OrganizationId = warehouse.OrganizationId AND readWarehouse.WarehouseCode = warehouse.WarehouseCode
  ORDER BY organization.Name, warehouse.WarehouseCode;

  /* 2. SAOP zaloga, ki jo PIM bere, po podjetju (vsota čez prebrana skladišča). */
  SELECT organization.OrganizationId, OrganizationName = organization.Name,
    source.SourceCode, source.ProviderKind, source.SnapshotUtc, registry.WarehouseLabel,
    ItemCount = COUNT(position.PositionId),
    InStockCount = COUNT(CASE WHEN position.Quantity > 0 THEN 1 END),
    NegativeCount = COUNT(CASE WHEN position.Quantity < 0 THEN 1 END),
    MatchedCount = COUNT(position.MatchedProductId),
    Quantity = ISNULL(SUM(position.Quantity), 0),
    AvailableQuantity = SUM(position.AvailableQuantity),
    IncomingCount = (SELECT COUNT(DISTINCT delivery.NormalizedItemId) FROM stock.ItemDeliveryDate AS delivery
                     WHERE delivery.OrganizationId = organization.OrganizationId AND delivery.Quantity > 0)
  FROM @Organizations AS organization
  LEFT JOIN @Snapshots AS source ON source.OrganizationId = organization.OrganizationId
  LEFT JOIN stock.Position AS position ON position.SnapshotId = source.SnapshotId
  LEFT JOIN out.ExportStockSource AS registry
    ON registry.OrganizationId = organization.OrganizationId AND registry.StockOrganizationId = organization.OrganizationId
   AND registry.SourceCode = source.SourceCode AND registry.IsActive = 1
  GROUP BY organization.OrganizationId, organization.Name, source.SourceCode, source.ProviderKind, source.SnapshotUtc, registry.WarehouseLabel
  ORDER BY organization.Name;

  /* 3. Dobaviteljski viri zaloge (za filter na strani Zaloga). */
  SELECT DISTINCT connector.SourceCode
  FROM stock.Snapshot AS snapshot
  INNER JOIN map.SourceConnector AS connector ON connector.SourceConnectorId = snapshot.SourceConnectorId
  INNER JOIN @Organizations AS organization ON organization.OrganizationId = snapshot.OrganizationId
  WHERE snapshot.IsActive = 1 AND connector.ConnectorType <> N'SAOP'
  ORDER BY connector.SourceCode;
END;
GO

IF CHARINDEX(N'/* 267 */', OBJECT_DEFINITION(OBJECT_ID(N'intranet.GetStockByItem'))) = 0
  THROW 52672, N'267: intranet.GetStockByItem ni posodobljen.', 1;
IF OBJECT_ID(N'intranet.GetWarehouseStock', N'P') IS NULL
  THROW 52673, N'267: intranet.GetWarehouseStock ni nastala.', 1;
GO
