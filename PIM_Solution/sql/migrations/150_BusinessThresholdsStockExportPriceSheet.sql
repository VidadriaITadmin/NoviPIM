/*
  150 — poslovanje: nastavljiv prag faktorja, izvoz zaloge z izbiro vira, cenik za tisk.

  Trije uporabnikovi zahtevki z 2026-09-02, vsi bralni ali registrski:

    1. "Prepracunanje cen s faktorjem 2 mora imeti uporabnik pod nadzorom." Prag 2,00 je bil v
       migraciji 131 zapisan v proceduro. Zdaj je vrstica registra pim.CheckThreshold
       (po podjetju ali privzeto); intranet.GetPriceChecks ga bere, /preverbe ga ureja s
       revizijo v b2b.AuditLog. Predlagana prodajna cena (nabavna x faktor) je v izpisu
       preverbe, da uporabnik vidi racun; zapis cene v SAOP ostaja stvar lastnistva
       (out.OwnershipPolicy: cene pise SAOP) in tu ni vkljucen.

    2. "Izvoz zalog mora imeti uporabnik omogocen in lahko izbere SAOP ali dobavitelj."
       out.GetStockExportRows vrne zalogovne pozicije podjetja iz aktivnih posnetkov, z izbiro
       vira ERP / DOBAVITELJ / VSE in po zelji samo za izdelke na spletu. Datoteko pretocno
       pise intranet (/izvoz/zaloge.csv), gumb je na /zaloge.

    3. "Iz dolocenih kategorij ali posameznih artiklov naredi digitalni cenik, ki ga lahko
       natisnemo ali posljemo kot PDF." intranet.GetPriceListSheet vrne vrstice za tiskani cenik:
       naziv v jeziku, kategorija, cena iz izbranega cenika, DDV, bruto, zaloga (isti register
       virov kot spletni izvoz, migracija 146) in glavna slika. Stran /cene/tisk ga izrise s
       slogom za tisk; PDF nastane s tiskanjem v brskalniku (Shrani kot PDF), brez dodatnih
       knjiznic.

  Migrator ne pozna locila GO; procedure so v EXEC(N'...').
*/

SET XACT_ABORT ON;

/* --- 1) Register pragov ------------------------------------------------------------------ */

IF OBJECT_ID(N'pim.CheckThreshold', N'U') IS NULL
BEGIN
  CREATE TABLE pim.CheckThreshold
  (
    CheckThresholdId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_CheckThreshold PRIMARY KEY,
    OrganizationId int NULL,               /* NULL = privzeto za vsa podjetja */
    CheckCode nvarchar(60) NOT NULL,
    Threshold decimal(18,4) NOT NULL,
    IsActive bit NOT NULL CONSTRAINT DF_CheckThreshold_IsActive DEFAULT (1),
    Note nvarchar(400) NULL,
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_CheckThreshold_UpdatedUtc DEFAULT (SYSUTCDATETIME()),
    UpdatedBy nvarchar(200) NOT NULL CONSTRAINT DF_CheckThreshold_UpdatedBy DEFAULT (N'migracija 150'),
    CONSTRAINT FK_CheckThreshold_Organization FOREIGN KEY (OrganizationId) REFERENCES dbo.OrganizationConfig (OrganizationId)
  );
  /* Enolicnost s filtrom: en privzeti prag na preverbo in en prag na podjetje in preverbo. */
  CREATE UNIQUE INDEX UQ_CheckThreshold_Organization ON pim.CheckThreshold (CheckCode, OrganizationId) WHERE OrganizationId IS NOT NULL;
  CREATE UNIQUE INDEX UQ_CheckThreshold_Default ON pim.CheckThreshold (CheckCode) WHERE OrganizationId IS NULL;
END;

IF NOT EXISTS (SELECT 1 FROM pim.CheckThreshold WHERE CheckCode = N'FAKTOR_MARZE' AND OrganizationId IS NULL)
  INSERT pim.CheckThreshold (OrganizationId, CheckCode, Threshold, Note)
  VALUES (NULL, N'FAKTOR_MARZE', 2.0, N'Privzeti prag iz migracije 131 (uporabnik: faktor 2).');

EXEC(N'CREATE OR ALTER PROCEDURE pim.SaveCheckThreshold
  @CheckCode nvarchar(60),
  @OrganizationId int = NULL,
  @Threshold decimal(18,4),
  @Actor nvarchar(200),
  @Note nvarchar(400) = NULL
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  SET @CheckCode = NULLIF(UPPER(LTRIM(RTRIM(@CheckCode))), N'''');
  IF @CheckCode IS NULL THROW 51510, N''Koda preverbe je obvezna.'', 1;
  IF @Threshold IS NULL OR @Threshold <= 0 THROW 51511, N''Prag mora biti pozitivno stevilo.'', 1;
  IF NULLIF(LTRIM(RTRIM(@Actor)), N'''') IS NULL THROW 51512, N''Kdo spreminja prag, mora biti znano.'', 1;
  IF @OrganizationId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.OrganizationConfig WHERE OrganizationId = @OrganizationId)
    THROW 51513, N''Podjetje ne obstaja.'', 1;

  DECLARE @OldJson nvarchar(max) = (SELECT Threshold, IsActive, Note FROM pim.CheckThreshold
    WHERE CheckCode = @CheckCode AND ((@OrganizationId IS NULL AND OrganizationId IS NULL) OR OrganizationId = @OrganizationId)
    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

  IF @OldJson IS NULL
    INSERT pim.CheckThreshold (OrganizationId, CheckCode, Threshold, Note, UpdatedBy) VALUES (@OrganizationId, @CheckCode, @Threshold, @Note, @Actor);
  ELSE
    UPDATE pim.CheckThreshold SET Threshold = @Threshold, IsActive = 1, Note = COALESCE(@Note, Note), UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = @Actor
    WHERE CheckCode = @CheckCode AND ((@OrganizationId IS NULL AND OrganizationId IS NULL) OR OrganizationId = @OrganizationId);

  INSERT b2b.AuditLog (OrganizationId, EntityType, EntityKey, ActionCode, OldValueJson, NewValueJson, ChangedBy, ChangedUtc)
  VALUES (ISNULL(@OrganizationId, 0), N''CheckThreshold'', @CheckCode + N''/'' + ISNULL(CONVERT(nvarchar(20), @OrganizationId), N''*''),
    CASE WHEN @OldJson IS NULL THEN N''ADD'' ELSE N''UPDATE'' END, @OldJson,
    (SELECT Threshold, IsActive, Note FROM pim.CheckThreshold
     WHERE CheckCode = @CheckCode AND ((@OrganizationId IS NULL AND OrganizationId IS NULL) OR OrganizationId = @OrganizationId)
     FOR JSON PATH, WITHOUT_ARRAY_WRAPPER), @Actor, SYSUTCDATETIME());
END');

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetCheckThresholds
AS
BEGIN
  SET NOCOUNT ON;
  SELECT threshold.CheckThresholdId, threshold.CheckCode, threshold.OrganizationId,
    OrganizationName = organization.Name, threshold.Threshold, threshold.IsActive, threshold.Note, threshold.UpdatedUtc, threshold.UpdatedBy
  FROM pim.CheckThreshold AS threshold
  LEFT JOIN dbo.OrganizationConfig AS organization ON organization.OrganizationId = threshold.OrganizationId
  ORDER BY threshold.CheckCode, CASE WHEN threshold.OrganizationId IS NULL THEN 0 ELSE 1 END, threshold.OrganizationId;
END');

/* --- 2) Preverbe cen berejo prag iz registra --------------------------------------------- */

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

  /* 150: prag faktorja je vrstica registra pim.CheckThreshold — najprej vrstica podjetja,
     sicer privzeta (OrganizationId NULL), sicer 2,00. Uporabnik ga ureja na /preverbe. */
  DECLARE @MarginThreshold decimal(18,4) = COALESCE(
    (SELECT TOP (1) Threshold FROM pim.CheckThreshold WHERE CheckCode = N''FAKTOR_MARZE'' AND OrganizationId = @OrganizationId AND IsActive = 1),
    (SELECT TOP (1) Threshold FROM pim.CheckThreshold WHERE CheckCode = N''FAKTOR_MARZE'' AND OrganizationId IS NULL AND IsActive = 1),
    2.0);
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
  )
  /* 132: preverbe se zberejo enkrat v zacasno tabelo, seznam in stevec pa bereta iz nje. */
  SELECT checks.ProductId, scopeValue.ItemID, scopeValue.Name, checks.CheckCode, checks.Context,
    checks.Detail, checks.ObservedUtc, checks.SalesPrice, checks.PurchasePrice,
    checks.MarginFactor, checks.UnitBasis
  INTO #PriceChecks
  FROM checks
  INNER JOIN @Scope AS scopeValue ON scopeValue.ProductId = checks.ProductId
  WHERE (@CheckCode IS NULL OR checks.CheckCode = @CheckCode)
    AND (@Context IS NULL OR checks.Context = @Context)
  OPTION (RECOMPILE);

  SELECT ProductId, ItemID, Name, CheckCode, Context, Detail, ObservedUtc,
    SalesPrice, PurchasePrice, MarginFactor, UnitBasis
  FROM #PriceChecks
  ORDER BY ItemID, CheckCode, Context
  OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY;

  SELECT TotalCount = COUNT_BIG(*) FROM #PriceChecks;

  DROP TABLE #PriceChecks;
END;');

/* --- 3) Izvoz zaloge z izbiro vira ------------------------------------------------------- */

EXEC(N'CREATE OR ALTER PROCEDURE out.GetStockExportRows
  @OrganizationId int,
  @Source nvarchar(20) = N''VSE'',     /* ERP | DOBAVITELJ | VSE */
  @OnlyWeb bit = 0,                    /* samo izdelki s spletno stranjo in objavo */
  @Skip int = 0,
  @Take int = 0,                       /* 0 = vse */
  @TotalCount int OUTPUT
AS
BEGIN
  SET NOCOUNT ON;
  SET @Source = ISNULL(NULLIF(UPPER(LTRIM(RTRIM(@Source))), N''''), N''VSE'');
  IF @Source NOT IN (N''ERP'', N''DOBAVITELJ'', N''VSE'') THROW 51520, N''Vir mora biti ERP, DOBAVITELJ ali VSE.'', 1;
  IF @Skip < 0 SET @Skip = 0;
  DECLARE @Fetch bigint = CASE WHEN @Take <= 0 THEN 2147483647 ELSE @Take END;

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

/* --- 4) Cenik za tisk -------------------------------------------------------------------- */

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetPriceListSheet
  @OrganizationId int,
  @PriceList nvarchar(50) = N''B2C'',
  @LanguageCode nvarchar(20) = N''sl'',
  @WebSite nvarchar(100) = NULL,
  @CategoryPathPrefix nvarchar(2000) = NULL,  /* kategorija in vse pod njo (po poti) */
  @ItemIds nvarchar(max) = NULL,              /* JSON seznam sifer, npr. ["NW.10157","BA.BC15.00310"] */
  @OnlyPublished bit = 1,
  @Take int = 2000
AS
BEGIN
  SET NOCOUNT ON;
  SET @Take = CASE WHEN @Take < 1 THEN 2000 WHEN @Take > 5000 THEN 5000 ELSE @Take END;
  SET @LanguageCode = LOWER(ISNULL(NULLIF(@LanguageCode, N''''), N''sl''));
  SET @WebSite = NULLIF(LTRIM(RTRIM(@WebSite)), N'''');
  SET @CategoryPathPrefix = NULLIF(LTRIM(RTRIM(@CategoryPathPrefix)), N'''');
  DECLARE @Items TABLE (ItemID nvarchar(200) COLLATE DATABASE_DEFAULT PRIMARY KEY);
  IF NULLIF(LTRIM(RTRIM(@ItemIds)), N'''') IS NOT NULL AND ISJSON(@ItemIds) = 1
    INSERT @Items (ItemID) SELECT DISTINCT LTRIM(RTRIM(value)) FROM OPENJSON(@ItemIds) WHERE NULLIF(LTRIM(RTRIM(value)), N'''') IS NOT NULL;
  DECLARE @HasItems bit = CASE WHEN EXISTS (SELECT 1 FROM @Items) THEN 1 ELSE 0 END;

  SELECT TOP (@Take)
    product.ProductId, product.ItemID, product.EAN,
    Title = COALESCE(webTitle.Value, erpTitle.Value, product.ItemID),
    CategoryPath = category.CategoryPath,
    Manufacturer = partner.PartnerName,
    UoM = product.UoM,
    PriceList = @PriceList,
    Net = price.Net, VatRate = price.VatRate,
    Gross = CASE WHEN price.Net IS NULL THEN NULL ELSE CONVERT(decimal(18,2), price.Net * (1 + ISNULL(price.VatRate, 0) / 100.0)) END,
    Stock = stock.Quantity,
    ImageUrl = media.Url
  FROM canon.Product AS product
  LEFT JOIN canon.PartnerName AS partner ON partner.OrganizationId = product.OrganizationId AND partner.PartnerCode = product.Manufacturer
  OUTER APPLY
  (
    SELECT TOP (1) productCategory.CategoryPath, productCategory.WebSite
    FROM canon.ProductCategory AS productCategory
    INNER JOIN canon.WebSite AS site ON site.WebSiteCode = productCategory.WebSite
    WHERE productCategory.ProductId = product.ProductId AND (@WebSite IS NULL OR productCategory.WebSite = @WebSite)
    ORDER BY site.SortOrder
  ) AS category
  OUTER APPLY
  (
    SELECT TOP (1) textValue.Value FROM canon.ProductText AS textValue
    WHERE textValue.ProductId = product.ProductId AND textValue.TextType = N''WEB_TITLE'' AND NULLIF(textValue.Value, N'''') IS NOT NULL
    ORDER BY CASE WHEN LOWER(textValue.Lang) = @LanguageCode THEN 0 WHEN textValue.Lang = N''sl'' THEN 1 ELSE 2 END
  ) AS webTitle
  OUTER APPLY
  (
    SELECT TOP (1) textValue.Value FROM canon.ProductText AS textValue
    WHERE textValue.ProductId = product.ProductId AND textValue.TextType = N''TITLE_ERP'' AND NULLIF(textValue.Value, N'''') IS NOT NULL
    ORDER BY CASE WHEN LOWER(textValue.Lang) = @LanguageCode THEN 0 WHEN textValue.Lang = N''sl'' THEN 1 ELSE 2 END
  ) AS erpTitle
  OUTER APPLY
  (
    SELECT TOP (1) priceValue.Net, priceValue.VatRate FROM canon.ProductPrice AS priceValue
    WHERE priceValue.ProductId = product.ProductId AND priceValue.PriceList = @PriceList AND priceValue.IsActive = 1
      AND priceValue.ValidFrom <= SYSUTCDATETIME()
    ORDER BY priceValue.ValidFrom DESC
  ) AS price
  OUTER APPLY
  (
    /* ista zaloga kot v spletnem izvozu: BASE + ADD viri iz registra (146), negativno = 0 */
    SELECT Quantity = CASE WHEN SUM(position.Quantity) < 0 THEN 0 ELSE SUM(position.Quantity) END
    FROM out.ExportStockSource AS registry
    INNER JOIN map.SourceConnector AS connector ON connector.OrganizationId = registry.StockOrganizationId AND connector.SourceCode = registry.SourceCode
    INNER JOIN stock.Snapshot AS snapshot ON snapshot.SourceConnectorId = connector.SourceConnectorId AND snapshot.IsActive = 1
    INNER JOIN stock.Position AS position ON position.SnapshotId = snapshot.SnapshotId
    INNER JOIN canon.Product AS stockProduct ON stockProduct.ProductId = position.MatchedProductId AND stockProduct.ItemID = product.ItemID
    WHERE registry.OrganizationId = @OrganizationId AND registry.IsActive = 1 AND registry.Contribution IN (N''BASE'', N''ADD'')
  ) AS stock
  OUTER APPLY
  (
    SELECT TOP (1) mediaValue.Url FROM canon.ProductMedia AS mediaValue
    WHERE mediaValue.ProductId = product.ProductId
    ORDER BY CASE WHEN UPPER(mediaValue.Role) IN (N''PRIMARY'', N''MAIN'') THEN 0 ELSE 1 END, mediaValue.SortOrder
  ) AS media
  WHERE product.OrganizationId = @OrganizationId AND product.IsActive = 1
    AND (@OnlyPublished = 0 OR product.WebPublish = 1)
    AND (@HasItems = 0 OR product.ItemID IN (SELECT ItemID FROM @Items))
    AND (@HasItems = 1 OR category.CategoryPath IS NOT NULL)
    AND (@CategoryPathPrefix IS NULL OR category.CategoryPath = @CategoryPathPrefix OR category.CategoryPath LIKE @CategoryPathPrefix + N'' > %'')
  ORDER BY category.CategoryPath, product.ItemID;
END');

/* --- dokaz ------------------------------------------------------------------------------ */

IF NOT EXISTS (SELECT 1 FROM pim.CheckThreshold WHERE CheckCode = N'FAKTOR_MARZE' AND OrganizationId IS NULL AND Threshold = 2.0)
  THROW 51530, N'150: privzeti prag faktorja ni vpisan.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'intranet.GetPriceChecks')) NOT LIKE N'%pim.CheckThreshold%'
  THROW 51531, N'150: intranet.GetPriceChecks ne bere praga iz registra.', 1;
IF OBJECT_ID(N'out.GetStockExportRows', N'P') IS NULL THROW 51532, N'150: out.GetStockExportRows ni nastala.', 1;
IF OBJECT_ID(N'intranet.GetPriceListSheet', N'P') IS NULL THROW 51533, N'150: intranet.GetPriceListSheet ni nastala.', 1;

DECLARE @ProbeOrganizationId int = (SELECT MIN(OrganizationId) FROM dbo.OrganizationConfig);
DECLARE @ProbeTotal int;
IF @ProbeOrganizationId IS NOT NULL
BEGIN
  EXEC out.GetStockExportRows @OrganizationId = @ProbeOrganizationId, @Source = N'VSE', @OnlyWeb = 0, @Skip = 0, @Take = 1, @TotalCount = @ProbeTotal OUTPUT;
  EXEC intranet.GetPriceListSheet @OrganizationId = @ProbeOrganizationId, @PriceList = N'B2C', @LanguageCode = N'sl', @Take = 1;
  EXEC intranet.GetCheckThresholds;
END;
