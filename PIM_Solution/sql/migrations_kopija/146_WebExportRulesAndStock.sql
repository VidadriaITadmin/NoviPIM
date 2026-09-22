/*
  146 — spletni izvoz: pravila, kaj gre na splet, in zaloga v datoteki.

  Uporabnik 2026-09-02: "Na splet ne gredo artikli, ce imajo prazen stolpec, kamor se pise
  svetila ali videlektro. V izvozu morajo biti cisti podatki. Zaloge in cene morajo biti zelo
  redno osvezene, tako da te ne gredo skozi validacije. K VID zalogi pristej IQLighting zalogo
  iz skladisca Brnciceva."

  Kaj je bilo do zdaj narobe (izmerjeno 2026-09-02 nad razvojno bazo PIM):
    - worker je klical out.GetExportRows z @OnlyPublished = 0 in brez spletne strani, zato je
      datoteka za podjetje 2 imela 43.504 vrstic, ceprav ima spletno stran samo 2.353 izdelkov,
      objavljenih in veljavnih za splet pa 1.957;
    - stolpci zaloge 43-53 ("VID trenutna zaloga" ... "Skladisce") so bili od migracije 045
      brez vira, torej vedno prazni;
    - zaloga podjetja 2 (skladisce 0000001, Brnciceva 13) ni imela poti do datoteke podjetja 3.

  Kaj ta migracija naredi:

    1. PRAVILO SPLETNE STRANI. Izdelek gre v produktni spletni izvoz samo, ce ima vsaj eno
       vrstico v pim.ProductCategory (stolpec "Spletne strani" ni prazen). Brezpogojno, tudi v
       predogledu: tak izdelek na splet ne sodi in ga ni smiselno kazati kot kandidata.

    2. CISTI PODATKI. Profil dobi zastavico out.ExportProfile.RequireWebValid. Kadar je 1,
       gre izdelek na spletno stran S samo, ce je objavljen (canon.Product.WebPublish = 1) in
       VALID v vsakem validacijskem profilu, ki blokira splet (BlocksWeb = 1) in velja za S:
       profil brez drevesa (SHARED_CORE) velja za vse strani, profil z drevesom (WEB_svetila_si,
       WEB_videlektro) samo za svojo. Zato val.ValidationProfile dobi stolpec CategoryTreeCode.
       Stolpec "Spletne strani" in stolpci kategorij nosijo samo strani, za katere je izdelek
       veljaven. Katero pravilo blokira, pove /kakovost; tu se samo uposteva.

    3. HITRI PROFIL MAGENTO_STOCK_PRICES (RequireWebValid = 0): sifra, EAN, ceni, DDV in zaloga.
       Namenjen je osvezitvi vsakih pet minut (Zaloga-cikel.ps1) in namenoma ne gre skozi
       validacijo — vsebuje samo izdelke, ki so ze na spletu (spletna stran + objava).

    4. ZALOGA V DATOTEKI. Register out.ExportStockSource pove, iz katerih posnetkov zaloge se
       sestavi zaloga v izvozu podjetja: BASE (lastna ERP zaloga), ADD (pristeta ERP zaloga
       drugega podjetja) in SUPPLIER (dobaviteljeva zaloga NW/BT). Za Vidadrio je BASE
       registrirani pogled (145), ADD pa IQLighting GetStocks nad skladiscem 0000001 =
       Glavno skladisce Brnciceva 13. Za IQLighting velja simetricno, da datoteki obeh podjetij
       pokazeta isto stevilko za isti artikel. Sestevek je na sifro artikla (ItemID), ker je
       sifra kljuc artikla na spletu (docs/EN_ARTIKEL_VEC_PODJETIJ.md).

       Stolpci: "VID trenutna zaloga" = vsota Quantity; "VID razpolozljiva kolicina" = vsota
       COALESCE(AvailableQuantity, Quantity) — GetStocks razpolozljive ne pozna, zato steje
       trenutna (isto pravilo kot v starem izvozu: fallback na AvailableStock); narocena, za
       odpremo in narocena dobaviteljem so vsote, kjer vir to pozna. Negativna ERP zaloga gre
       ven kot 0: splet ne prodaja minusa. "Dobavitelj zaloga/narocena/datum" pridejo iz
       SUPPLIER vrstic (NW: kolicina, prihajajoca kolicina, datum; BT: kolicina). "Skladisce"
       je oznaka iz registra (npr. "Glavno skladisce Rakovnik 9a + Glavno skladisce
       Brnciceva 13"). "VID datum dobave" in "VID koli. prihodnjih dobav" ostaneta brez vira:
       koncna tocka GetItemDeliveryDate v NoviPIM ni zajeta — to je zapisano v docs/EXPORTS.md.

    5. intranet.GetExportReadiness pove se dve stevilki: objavljeni izdelki brez spletne strani
       in izdelki s spletno stranjo, ki niso veljavni za splet.

  Kar ostaja nespremenjeno: kode in glave stolpcev (pogodba do Magenta), kanonicna pot
  (CANON) in profil strank.

  Migrator ne pozna locila GO; procedure so v EXEC(N'...').
*/

SET XACT_ABORT ON;

/* --- 1) Register: profil pove, ali zahteva veljavnost za splet -------------------------- */

IF COL_LENGTH(N'out.ExportProfile', N'RequireWebValid') IS NULL
  ALTER TABLE out.ExportProfile
    ADD RequireWebValid bit NOT NULL CONSTRAINT DF_ExportProfile_RequireWebValid DEFAULT (1);

IF COL_LENGTH(N'val.ValidationProfile', N'CategoryTreeCode') IS NULL
  ALTER TABLE val.ValidationProfile ADD CategoryTreeCode nvarchar(100) NULL;

EXEC(N'
UPDATE val.ValidationProfile SET CategoryTreeCode = N''svetila_si'' WHERE ProfileCode = N''WEB_svetila_si'' AND CategoryTreeCode IS NULL;
UPDATE val.ValidationProfile SET CategoryTreeCode = N''videlektro'' WHERE ProfileCode = N''WEB_videlektro'' AND CategoryTreeCode IS NULL;
');

/* --- 2) Register virov zaloge za izvoz --------------------------------------------------- */

IF OBJECT_ID(N'out.ExportStockSource', N'U') IS NULL
BEGIN
  CREATE TABLE out.ExportStockSource
  (
    ExportStockSourceId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_ExportStockSource PRIMARY KEY,
    OrganizationId int NOT NULL,            /* podjetje, katerega izvoz to je */
    StockOrganizationId int NOT NULL,       /* podjetje, katerega posnetek zaloge beremo */
    SourceCode nvarchar(100) NOT NULL,      /* map.SourceConnector.SourceCode pri StockOrganizationId */
    Contribution nvarchar(20) NOT NULL,     /* BASE | ADD | SUPPLIER */
    WarehouseLabel nvarchar(200) NULL,      /* kar pise v stolpcu "Skladisce" */
    SortOrder int NOT NULL CONSTRAINT DF_ExportStockSource_SortOrder DEFAULT (10),
    IsActive bit NOT NULL CONSTRAINT DF_ExportStockSource_IsActive DEFAULT (1),
    Note nvarchar(400) NULL,
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_ExportStockSource_UpdatedUtc DEFAULT (SYSUTCDATETIME()),
    UpdatedBy nvarchar(200) NOT NULL CONSTRAINT DF_ExportStockSource_UpdatedBy DEFAULT (N'migracija 146'),
    CONSTRAINT CK_ExportStockSource_Contribution CHECK (Contribution IN (N'BASE', N'ADD', N'SUPPLIER')),
    CONSTRAINT UQ_ExportStockSource UNIQUE (OrganizationId, StockOrganizationId, SourceCode),
    CONSTRAINT FK_ExportStockSource_Organization FOREIGN KEY (OrganizationId) REFERENCES dbo.OrganizationConfig(OrganizationId),
    CONSTRAINT FK_ExportStockSource_StockOrganization FOREIGN KEY (StockOrganizationId) REFERENCES dbo.OrganizationConfig(OrganizationId)
  );
END;

MERGE out.ExportStockSource AS target
USING (VALUES
  /* Vidadria: lastna zaloga iz registriranega pogleda + IQL Brnciceva 13 */
  (3, 3, N'SAOP_VIDADRIA_STOCK',  N'BASE',     N'Glavno skladišče Rakovnik 9a',  10, N'registrirani pogled (145)'),
  (3, 2, N'SAOP_IQLIGHTING_STOCK', N'ADD',      N'Glavno skladišče Brnčičeva 13', 20, N'uporabnik 2026-09-02: IQL Brnciceva se pristeje k VID zalogi'),
  (3, 3, N'NW_STOCK',              N'SUPPLIER', NULL, 30, NULL),
  (3, 3, N'BT_STOCK',              N'SUPPLIER', NULL, 40, NULL),
  /* IQLighting: simetricno, da ista sifra v obeh datotekah pokaze isto stevilko */
  (2, 2, N'SAOP_IQLIGHTING_STOCK', N'BASE',     N'Glavno skladišče Brnčičeva 13', 10, N'GetStocks nad skladiscem 0000001 (105)'),
  (2, 3, N'SAOP_VIDADRIA_STOCK',  N'ADD',      N'Glavno skladišče Rakovnik 9a',  20, N'simetricno k vrstici podjetja 3'),
  (2, 2, N'NW_STOCK',              N'SUPPLIER', NULL, 30, NULL),
  (2, 2, N'BT_STOCK',              N'SUPPLIER', NULL, 40, NULL),
  /* DEMO in Ediito: samo lastna zaloga in dobavitelji */
  (1, 1, N'SAOP_DEMO_STOCK',       N'BASE',     NULL, 10, NULL),
  (1, 1, N'NW_STOCK',              N'SUPPLIER', NULL, 30, NULL),
  (1, 1, N'BT_STOCK',              N'SUPPLIER', NULL, 40, NULL),
  (4, 4, N'SAOP_EDIITO_STOCK',     N'BASE',     NULL, 10, NULL),
  (4, 4, N'NW_STOCK',              N'SUPPLIER', NULL, 30, NULL),
  (4, 4, N'BT_STOCK',              N'SUPPLIER', NULL, 40, NULL)
) AS source (OrganizationId, StockOrganizationId, SourceCode, Contribution, WarehouseLabel, SortOrder, Note)
  ON target.OrganizationId = source.OrganizationId
 AND target.StockOrganizationId = source.StockOrganizationId
 AND target.SourceCode = source.SourceCode
WHEN NOT MATCHED THEN
  INSERT (OrganizationId, StockOrganizationId, SourceCode, Contribution, WarehouseLabel, SortOrder, Note)
  VALUES (source.OrganizationId, source.StockOrganizationId, source.SourceCode, source.Contribution, source.WarehouseLabel, source.SortOrder, source.Note);

/* --- 3) Stolpci zaloge v profilu MAGENTO_PRODUCTS dobijo vir --------------------------- */

DECLARE @ProductProfileId int =
  (SELECT ExportProfileId FROM out.ExportProfile WHERE ProfileCode = N'MAGENTO_PRODUCTS');
IF @ProductProfileId IS NULL THROW 51460, N'146: profil MAGENTO_PRODUCTS ne obstaja.', 1;

/* Samo stolpci brez kode: rocno spremenjen register se ne prepise. */
UPDATE exportColumn
SET CanonicalFieldCode = mapping.FieldCode
FROM out.ExportColumn AS exportColumn
INNER JOIN (VALUES
  (N'COL043', N'Stock.ErpCurrent'),
  (N'COL044', N'Stock.ErpOrdered'),
  (N'COL045', N'Stock.ErpForShipment'),
  (N'COL046', N'Stock.ErpAvailable'),
  (N'COL047', N'Stock.ErpSupplierOrdered'),
  (N'COL050', N'Stock.SupplierQuantity'),
  (N'COL051', N'Stock.SupplierIncoming'),
  (N'COL052', N'Stock.SupplierDate'),
  (N'COL053', N'Stock.Warehouse')
) AS mapping (ColumnCode, FieldCode) ON mapping.ColumnCode = exportColumn.ColumnCode
WHERE exportColumn.ExportProfileId = @ProductProfileId
  AND NULLIF(exportColumn.CanonicalFieldCode, N'') IS NULL;

/* --- 4) Hitri profil: cene in zaloga vsakih pet minut ------------------------------------ */

IF NOT EXISTS (SELECT 1 FROM out.ExportProfile WHERE ProfileCode = N'MAGENTO_STOCK_PRICES')
BEGIN
  EXEC(N'
  INSERT out.ExportProfile (ProfileCode, Name, ChannelCode, EntityType, IsActive, ValueSourceCode, RequireWebValid)
  VALUES (N''MAGENTO_STOCK_PRICES'', N''Magento - cene in zaloga (hitra osvezitev)'', N''MAGENTO'', N''PRODUCTS'', 1, N''PIM_PRODUCT'', 0);
  ');
END;
ELSE
  EXEC(N'UPDATE out.ExportProfile SET RequireWebValid = 0 WHERE ProfileCode = N''MAGENTO_STOCK_PRICES'' AND RequireWebValid = 1;');

DECLARE @FastProfileId int =
  (SELECT ExportProfileId FROM out.ExportProfile WHERE ProfileCode = N'MAGENTO_STOCK_PRICES');

/* Glave so prepisane iz produktnega profila, da je ime stolpca v obeh datotekah enako. */
INSERT out.ExportColumn (ExportProfileId, ColumnCode, OutputColumnName, CanonicalFieldCode, SortOrder, IsRequired, IsActive)
SELECT @FastProfileId, N'FST' + RIGHT(N'000' + CONVERT(nvarchar(10), pick.SortOrder), 3),
  source.OutputColumnName, source.CanonicalFieldCode, pick.SortOrder, 0, 1
FROM (VALUES
  (N'COL001', 1), (N'COL002', 2), (N'COL028', 3), (N'COL029', 4), (N'COL032', 5),
  (N'COL043', 6), (N'COL044', 7), (N'COL045', 8), (N'COL046', 9), (N'COL047', 10),
  (N'COL050', 11), (N'COL051', 12), (N'COL052', 13), (N'COL053', 14)
) AS pick (ColumnCode, SortOrder)
INNER JOIN out.ExportColumn AS source
  ON source.ExportProfileId = @ProductProfileId AND source.ColumnCode = pick.ColumnCode
WHERE NOT EXISTS (SELECT 1 FROM out.ExportColumn AS existing
                  WHERE existing.ExportProfileId = @FastProfileId AND existing.SortOrder = pick.SortOrder);

/* --- 5) Izvoz na zahtevo iz tabel, s pravili --------------------------------------------- */

EXEC(N'CREATE OR ALTER PROCEDURE out.GetExportRows
  @OrganizationId int,
  @ExportProfileId int,
  @WebSite nvarchar(100) = NULL,
  @OnlyPublished bit = 1,
  @Search nvarchar(200) = NULL,
  @Skip int = 0,
  @Take int = 200,
  @TotalCount int OUTPUT
AS
BEGIN
  SET NOCOUNT ON;

  IF @Skip < 0 THROW 52970, N''Odmik izvoza ne sme biti negativen.'', 1;
  IF @Take < 0 THROW 52971, N''Velikost strani izvoza ne sme biti negativna.'', 1;
  IF NOT EXISTS (SELECT 1 FROM dbo.OrganizationConfig WHERE OrganizationId = @OrganizationId)
    THROW 52972, N''Organizacija za izvoz ne obstaja.'', 1;

  DECLARE @EntityType nvarchar(200), @ProfileCode nvarchar(200), @ValueSource nvarchar(40), @RequireWebValid bit;
  SELECT @EntityType = EntityType, @ProfileCode = ProfileCode, @ValueSource = ValueSourceCode, @RequireWebValid = RequireWebValid
  FROM out.ExportProfile
  WHERE ExportProfileId = @ExportProfileId AND IsActive = 1;

  IF @ProfileCode IS NULL THROW 52973, N''Aktivni izvozni profil ne obstaja.'', 1;
  IF NOT EXISTS (SELECT 1 FROM out.ExportColumn WHERE ExportProfileId = @ExportProfileId AND IsActive = 1)
    THROW 52974, N''Izvozni profil nima aktivnih stolpcev.'', 1;

  SET @WebSite = NULLIF(LTRIM(RTRIM(@WebSite)), N'''');
  SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'''');
  DECLARE @SearchLike nvarchar(410) = CASE WHEN @Search IS NULL THEN NULL ELSE
    N''%'' + REPLACE(REPLACE(REPLACE(@Search, N''['', N''[[]''), N''%'', N''[%]''), N''_'', N''[_]'') + N''%'' END;

  DECLARE @Fetch bigint = CASE WHEN @Take = 0 THEN 2147483647 ELSE @Take END;

  CREATE TABLE #Page
    (RowKey nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY, EntityId bigint NOT NULL);
  CREATE TABLE #Value
    (RowKey nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
     FieldCode nvarchar(450) COLLATE DATABASE_DEFAULT NOT NULL,
     Value nvarchar(max) COLLATE DATABASE_DEFAULT NULL);

  /* ============================================================================
     A) KANONICNI VIR — nespremenjeno od 142.
     ============================================================================ */
  IF @ValueSource = N''CANON''
  BEGIN
    IF UPPER(@EntityType) NOT IN (N''PRODUCT'', N''PRODUCTS'')
      THROW 52975, N''Kanonicni izvoz na zahtevo podpira samo produktne profile.'', 1;

    SELECT @TotalCount = COUNT(*)
    FROM canon.Product AS product
    WHERE product.OrganizationId = @OrganizationId
      AND (@OnlyPublished = 0 OR product.WebPublish = 1)
      AND (@WebSite IS NULL OR EXISTS
        (SELECT 1 FROM canon.ProductCategory AS category
         WHERE category.ProductId = product.ProductId AND category.WebSite = @WebSite))
      AND (@SearchLike IS NULL
        OR product.ItemID LIKE @SearchLike
        OR product.EAN LIKE @SearchLike
        OR EXISTS
          (SELECT 1 FROM canon.ProductText AS textValue
           WHERE textValue.ProductId = product.ProductId AND textValue.Value LIKE @SearchLike));

    INSERT #Page (RowKey, EntityId)
    SELECT product.ItemID, product.ProductId
    FROM canon.Product AS product
    WHERE product.OrganizationId = @OrganizationId
      AND (@OnlyPublished = 0 OR product.WebPublish = 1)
      AND (@WebSite IS NULL OR EXISTS
        (SELECT 1 FROM canon.ProductCategory AS category
         WHERE category.ProductId = product.ProductId AND category.WebSite = @WebSite))
      AND (@SearchLike IS NULL
        OR product.ItemID LIKE @SearchLike
        OR product.EAN LIKE @SearchLike
        OR EXISTS
          (SELECT 1 FROM canon.ProductText AS textValue
           WHERE textValue.ProductId = product.ProductId AND textValue.Value LIKE @SearchLike))
    ORDER BY product.ItemID
    OFFSET @Skip ROWS FETCH NEXT @Fetch ROWS ONLY;

    INSERT #Value (RowKey, FieldCode, Value)
    SELECT source.RowKey, source.FieldCode,
      STRING_AGG(CONVERT(nvarchar(max), source.Value), N'' | '') WITHIN GROUP (ORDER BY source.Value)
    FROM
    (
      SELECT page.RowKey, fieldValue.FieldCode, fieldValue.Value
      FROM canon.FieldValue AS fieldValue
      INNER JOIN #Page AS page ON page.EntityId = fieldValue.ProductId
      WHERE fieldValue.FieldCode <> N''ProductCategory.CategoryPath''
        AND EXISTS (SELECT 1 FROM out.ExportColumn AS registryColumn
                    WHERE registryColumn.ExportProfileId = @ExportProfileId
                      AND registryColumn.IsActive = 1
                      AND registryColumn.CanonicalFieldCode = fieldValue.FieldCode)
      UNION ALL
      SELECT page.RowKey, N''ProductCategory.CategoryPath'', category.CategoryPath
      FROM canon.ProductCategory AS category
      INNER JOIN #Page AS page ON page.EntityId = category.ProductId
      WHERE EXISTS (SELECT 1 FROM out.ExportColumn AS registryColumn
                    WHERE registryColumn.ExportProfileId = @ExportProfileId
                      AND registryColumn.IsActive = 1
                      AND registryColumn.CanonicalFieldCode = N''ProductCategory.CategoryPath'')
        AND (@WebSite IS NULL OR category.WebSite = @WebSite)
    ) AS source
    WHERE NULLIF(source.Value, N'''') IS NOT NULL
    GROUP BY source.RowKey, source.FieldCode;
  END

  /* ============================================================================
     B) IZDELKI ZA MAGENTO — vir je sloj pim.*, s pravili spletne strani in veljavnosti.
     ============================================================================ */
  ELSE IF @ValueSource = N''PIM_PRODUCT''
  BEGIN
    /* B0) Katere strani so za kateri izdelek dovoljene.
       Stran S je dovoljena, ce ima izdelek kategorijo na S (pravilo "prazen stolpec = ne gre")
       in — kadar profil zahteva veljavnost — ce je izdelek objavljen ter VALID v vseh profilih,
       ki blokirajo splet in veljajo za S (brez drevesa = vse strani, z drevesom = samo S). */
    CREATE TABLE #Site
      (PimProductId bigint NOT NULL, WebSite nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
       PRIMARY KEY (PimProductId, WebSite));

    INSERT #Site (PimProductId, WebSite)
    SELECT DISTINCT category.PimProductId, category.WebSite
    FROM pim.ProductCategory AS category
    INNER JOIN pim.Product AS product ON product.PimProductId = category.PimProductId
    INNER JOIN canon.WebSite AS site ON site.WebSiteCode = category.WebSite AND site.IsActive = 1
    LEFT JOIN canon.Product AS canonProduct
      ON canonProduct.OrganizationId = product.OrganizationId AND canonProduct.ItemID = product.ItemID
    WHERE product.OrganizationId = @OrganizationId
      AND (@WebSite IS NULL OR category.WebSite = @WebSite)
      AND (@OnlyPublished = 0 OR canonProduct.WebPublish = 1)
      AND
      (
        @RequireWebValid = 0
        OR
        (
          canonProduct.WebPublish = 1
          AND NOT EXISTS
          (
            SELECT 1
            FROM val.ValidationProfile AS profile
            LEFT JOIN val.ProductValidationState AS state
              ON state.ProductId = canonProduct.ProductId AND state.ValidationProfileId = profile.ValidationProfileId
            WHERE profile.IsActive = 1 AND profile.BlocksWeb = 1
              AND (profile.CategoryTreeCode IS NULL OR profile.CategoryTreeCode = site.CategoryTreeCode)
              AND ISNULL(state.Status, N''INVALID'') <> N''VALID''
          )
        )
      );

    SELECT @TotalCount = COUNT(*)
    FROM pim.Product AS product
    WHERE product.OrganizationId = @OrganizationId
      AND EXISTS (SELECT 1 FROM #Site AS site WHERE site.PimProductId = product.PimProductId)
      AND (@SearchLike IS NULL
        OR product.ItemID LIKE @SearchLike
        OR product.EAN LIKE @SearchLike
        OR product.Name LIKE @SearchLike
        OR EXISTS
          (SELECT 1 FROM pim.ProductText AS textValue
           WHERE textValue.PimProductId = product.PimProductId AND textValue.Value LIKE @SearchLike));

    INSERT #Page (RowKey, EntityId)
    SELECT product.ItemID, product.PimProductId
    FROM pim.Product AS product
    WHERE product.OrganizationId = @OrganizationId
      AND EXISTS (SELECT 1 FROM #Site AS site WHERE site.PimProductId = product.PimProductId)
      AND (@SearchLike IS NULL
        OR product.ItemID LIKE @SearchLike
        OR product.EAN LIKE @SearchLike
        OR product.Name LIKE @SearchLike
        OR EXISTS
          (SELECT 1 FROM pim.ProductText AS textValue
           WHERE textValue.PimProductId = product.PimProductId AND textValue.Value LIKE @SearchLike))
    ORDER BY product.ItemID
    OFFSET @Skip ROWS FETCH NEXT @Fetch ROWS ONLY;

    /* --- B1) Osnovna polja, trgovinski podatki, popust polnega pakiranja in cene --- */
    INSERT #Value (RowKey, FieldCode, Value)
    SELECT core.RowKey, field.FieldCode, field.Value
    FROM
    (
      SELECT
        page.RowKey,
        product.EAN, product.Name, product.Manufacturer, product.Supplier, product.UoM,
        commercial.CustomsTariff, commercial.CountryOfOrigin, commercial.DimensionUnit,
        commercial.GrossWeight, commercial.NetWeight, commercial.Pak1, commercial.Pak2,
        commercial.Volume, commercial.PackageLength, commercial.PackageWidth, commercial.PackageHeight,
        packaging.DiscountCode AS PackagingDiscountCode,
        discountCatalog.PercentValue AS PackagingDiscountPercent,
        priceB2b.Net AS PriceB2B,
        priceB2c.Net AS PriceB2C,
        COALESCE(priceB2b.VatRate, priceB2c.VatRate, priceAny.VatRate) AS VatRate
      FROM #Page AS page
      INNER JOIN pim.Product AS product ON product.PimProductId = page.EntityId
      LEFT JOIN pim.ProductCommercial AS commercial ON commercial.PimProductId = product.PimProductId
      LEFT JOIN pim.ProductPackagingDiscount AS packaging ON packaging.PimProductId = product.PimProductId
      LEFT JOIN pim.PackagingDiscountCatalog AS discountCatalog
        ON discountCatalog.DiscountCode = packaging.DiscountCode AND discountCatalog.IsActive = 1
      LEFT JOIN
      (
        SELECT price.PimProductId, price.Net, price.VatRate,
          ROW_NUMBER() OVER (PARTITION BY price.PimProductId ORDER BY registry.SortOrder, price.ValidFrom DESC) AS PickRank
        FROM pim.ProductPrice AS price
        INNER JOIN out.ExportPriceList AS registry
          ON registry.PriceListCode = price.PriceList AND registry.OrganizationId = @OrganizationId
          AND registry.PriceFieldCode = N''Product.PriceB2B'' AND registry.IsActive = 1
        WHERE price.IsActive = 1 AND price.ValidFrom <= SYSUTCDATETIME()
      ) AS priceB2b ON priceB2b.PimProductId = product.PimProductId AND priceB2b.PickRank = 1
      LEFT JOIN
      (
        SELECT price.PimProductId, price.Net, price.VatRate,
          ROW_NUMBER() OVER (PARTITION BY price.PimProductId ORDER BY registry.SortOrder, price.ValidFrom DESC) AS PickRank
        FROM pim.ProductPrice AS price
        INNER JOIN out.ExportPriceList AS registry
          ON registry.PriceListCode = price.PriceList AND registry.OrganizationId = @OrganizationId
          AND registry.PriceFieldCode = N''Product.PriceB2C'' AND registry.IsActive = 1
        WHERE price.IsActive = 1 AND price.ValidFrom <= SYSUTCDATETIME()
      ) AS priceB2c ON priceB2c.PimProductId = product.PimProductId AND priceB2c.PickRank = 1
      LEFT JOIN
      (
        SELECT PimProductId, VatRate,
          ROW_NUMBER() OVER (PARTITION BY PimProductId ORDER BY ValidFrom DESC) AS PickRank
        FROM pim.ProductPrice WHERE IsActive = 1 AND ValidFrom <= SYSUTCDATETIME()
      ) AS priceAny ON priceAny.PimProductId = product.PimProductId AND priceAny.PickRank = 1
    ) AS core
    CROSS APPLY
    (
      VALUES
        (N''Product.ItemID'', CONVERT(nvarchar(max), core.RowKey)),
        (N''Product.EAN'', CONVERT(nvarchar(max), core.EAN)),
        (N''Product.ErpTitleSl'', CONVERT(nvarchar(max), core.Name)),
        (N''Product.Manufacturer'', CONVERT(nvarchar(max), core.Manufacturer)),
        (N''Product.Supplier'', CONVERT(nvarchar(max), core.Supplier)),
        (N''Product.UoM'', CONVERT(nvarchar(max), core.UoM)),
        (N''Product.CustomsTariff'', CONVERT(nvarchar(max), core.CustomsTariff)),
        (N''Product.CountryOfOrigin'', CONVERT(nvarchar(max), core.CountryOfOrigin)),
        (N''Product.GrossWeight'', CONVERT(nvarchar(max), out.MagentoNumber(core.GrossWeight))),
        (N''Product.NetWeight'', CONVERT(nvarchar(max), out.MagentoNumber(core.NetWeight))),
        (N''Product.Pak1'', CONVERT(nvarchar(max), out.MagentoNumber(core.Pak1))),
        (N''Product.Pak2'', CONVERT(nvarchar(max), out.MagentoNumber(core.Pak2))),
        (N''Product.Volume'', CONVERT(nvarchar(max), out.MagentoNumber(core.Volume))),
        (N''Product.PackageLength'', CONVERT(nvarchar(max), out.MagentoNumber(core.PackageLength))),
        (N''Product.PackageWidth'', CONVERT(nvarchar(max), out.MagentoNumber(core.PackageWidth))),
        (N''Product.PackageHeight'', CONVERT(nvarchar(max), out.MagentoNumber(core.PackageHeight))),
        (N''Product.DimensionUnit'', CONVERT(nvarchar(max), core.DimensionUnit)),
        (N''Product.PackagingDiscountCode'', CONVERT(nvarchar(max), core.PackagingDiscountCode)),
        (N''Product.PackagingDiscountPercent'', CONVERT(nvarchar(max), out.MagentoNumber(core.PackagingDiscountPercent))),
        (N''Product.PriceB2B'', CONVERT(nvarchar(max), out.MagentoNumber(core.PriceB2B))),
        (N''Product.PriceB2C'', CONVERT(nvarchar(max), out.MagentoNumber(core.PriceB2C))),
        (N''Product.VatRate'', CONVERT(nvarchar(max), out.MagentoNumber(core.VatRate)))
    ) AS field (FieldCode, Value)
    WHERE field.Value IS NOT NULL;

    /* --- B2) Besedila: spletni naziv in angleski ERP naziv --- */
    INSERT #Value (RowKey, FieldCode, Value)
    SELECT page.RowKey,
      CASE
        WHEN textValue.TextType = N''WEB_TITLE'' AND textValue.Lang = N''en'' THEN N''Product.WebTitleEn''
        WHEN textValue.TextType = N''WEB_TITLE'' AND textValue.Lang = N''sl'' THEN N''Product.WebTitleSl''
        ELSE N''Product.ErpTitleEn''
      END,
      textValue.Value
    FROM #Page AS page
    INNER JOIN pim.ProductText AS textValue ON textValue.PimProductId = page.EntityId
    WHERE (textValue.TextType = N''WEB_TITLE'' AND textValue.Lang IN (N''en'', N''sl''))
       OR (textValue.TextType = N''TITLE_ERP'' AND textValue.Lang = N''en'');

    /* --- B3) Mediji: prva slika z glavno vlogo je glavna, vse ostale so dodatne --- */
    CREATE TABLE #Media
      (RowKey nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
       Url nvarchar(4000) COLLATE DATABASE_DEFAULT NOT NULL,
       Ordinal int NOT NULL, IsPrimary bit NOT NULL);

    INSERT #Media (RowKey, Url, Ordinal, IsPrimary)
    SELECT page.RowKey, media.Url,
      ROW_NUMBER() OVER (PARTITION BY page.RowKey ORDER BY media.SortOrder, media.PimProductMediaId),
      CASE WHEN UPPER(media.Role) IN (N''PRIMARY'', N''MAIN'') THEN 1 ELSE 0 END
    FROM #Page AS page
    INNER JOIN pim.ProductMedia AS media ON media.PimProductId = page.EntityId;

    INSERT #Value (RowKey, FieldCode, Value)
    SELECT media.RowKey, N''Product.MainImage'', CONVERT(nvarchar(max), media.Url)
    FROM #Media AS media
    WHERE media.Ordinal = (SELECT MIN(first.Ordinal) FROM #Media AS first
                           WHERE first.RowKey = media.RowKey AND first.IsPrimary = 1);

    INSERT #Value (RowKey, FieldCode, Value)
    SELECT media.RowKey, N''Product.OtherImages'',
      STRING_AGG(CONVERT(nvarchar(max), media.Url), N''|'') WITHIN GROUP (ORDER BY media.Ordinal)
    FROM #Media AS media
    WHERE media.Ordinal <> ISNULL((SELECT MIN(first.Ordinal) FROM #Media AS first
                                   WHERE first.RowKey = media.RowKey AND first.IsPrimary = 1), -1)
    GROUP BY media.RowKey;

    /* --- B4) Spletna mesta in kategorije: samo strani, za katere je izdelek dovoljen --- */
    CREATE TABLE #Category
      (RowKey nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
       WebSite nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
       CategoryPath nvarchar(2000) COLLATE DATABASE_DEFAULT NOT NULL);

    INSERT #Category (RowKey, WebSite, CategoryPath)
    SELECT page.RowKey, category.WebSite, category.CategoryPath
    FROM #Page AS page
    INNER JOIN pim.ProductCategory AS category ON category.PimProductId = page.EntityId
    INNER JOIN #Site AS site ON site.PimProductId = category.PimProductId AND site.WebSite = category.WebSite;

    INSERT #Value (RowKey, FieldCode, Value)
    SELECT site.RowKey, N''Product.WebSites'',
      STRING_AGG(CONVERT(nvarchar(max), site.WebSite), N''|'') WITHIN GROUP (ORDER BY site.WebSite)
    FROM (SELECT DISTINCT RowKey, WebSite FROM #Category) AS site
    GROUP BY site.RowKey;

    INSERT #Value (RowKey, FieldCode, Value)
    SELECT path.RowKey, path.CategoryFieldCode,
      STRING_AGG(CONVERT(nvarchar(max), path.CategoryPath), N''|'') WITHIN GROUP (ORDER BY path.FirstSite, path.CategoryPath)
    FROM
    (
      SELECT category.RowKey, site.CategoryFieldCode, category.CategoryPath, MIN(category.WebSite) AS FirstSite
      FROM #Category AS category
      INNER JOIN canon.WebSite AS site ON site.WebSiteCode = category.WebSite AND site.IsActive = 1
      WHERE NULLIF(category.CategoryPath, N'''') IS NOT NULL
      GROUP BY category.RowKey, site.CategoryFieldCode, category.CategoryPath
    ) AS path
    GROUP BY path.RowKey, path.CategoryFieldCode;

    /* --- B5) Lastnosti izdelka --- */
    CREATE TABLE #Attribute
      (RowKey nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
       AttributeCode nvarchar(400) COLLATE DATABASE_DEFAULT NOT NULL,
       LanguageCode nvarchar(20) COLLATE DATABASE_DEFAULT NULL,
       Value nvarchar(max) COLLATE DATABASE_DEFAULT NULL, AttributeId bigint NOT NULL);

    INSERT #Attribute (RowKey, AttributeCode, LanguageCode, Value, AttributeId)
    SELECT page.RowKey, attribute.AttributeCode, attribute.LanguageCode, attribute.Value, attribute.PimProductAttributeId
    FROM #Page AS page
    INNER JOIN pim.ProductAttribute AS attribute ON attribute.PimProductId = page.EntityId;

    INSERT #Value (RowKey, FieldCode, Value)
    SELECT picked.RowKey, N''Attr.'' + picked.AttributeCode, picked.Value
    FROM
    (
      SELECT RowKey, AttributeCode, Value,
        ROW_NUMBER() OVER (PARTITION BY RowKey, AttributeCode ORDER BY AttributeId DESC) AS PickRank
      FROM #Attribute
    ) AS picked
    WHERE picked.PickRank = 1;

    INSERT #Value (RowKey, FieldCode, Value)
    SELECT RowKey,
      N''Attr.'' + AttributeCode + N'' '' + CASE LanguageCode WHEN N''sl'' THEN N''SLO'' ELSE N''ANG'' END,
      Value
    FROM #Attribute
    WHERE LanguageCode IN (N''sl'', N''en'');

    /* --- B6) Zaloga: iz registra out.ExportStockSource, sesteta po sifri artikla --- */
    CREATE TABLE #Stock
      (RowKey nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
       Contribution nvarchar(20) COLLATE DATABASE_DEFAULT NOT NULL,
       Quantity decimal(19,4) NULL, Available decimal(19,4) NULL, Ordered decimal(19,4) NULL,
       ForShipment decimal(19,4) NULL, SupplierOrdered decimal(19,4) NULL,
       Incoming decimal(19,4) NULL, AvailabilityDate date NULL);

    INSERT #Stock (RowKey, Contribution, Quantity, Available, Ordered, ForShipment, SupplierOrdered, Incoming, AvailabilityDate)
    SELECT page.RowKey, registry.Contribution,
      position.Quantity,
      COALESCE(position.AvailableQuantity, position.Quantity),
      position.OrderedQuantity, position.ForShipmentQuantity, position.SupplierOrderedQuantity,
      position.IncomingQuantity, position.AvailabilityDate
    FROM out.ExportStockSource AS registry
    INNER JOIN map.SourceConnector AS connector
      ON connector.OrganizationId = registry.StockOrganizationId AND connector.SourceCode = registry.SourceCode
    INNER JOIN stock.Snapshot AS snapshot
      ON snapshot.SourceConnectorId = connector.SourceConnectorId AND snapshot.IsActive = 1
    INNER JOIN stock.Position AS position ON position.SnapshotId = snapshot.SnapshotId
    INNER JOIN canon.Product AS stockProduct ON stockProduct.ProductId = position.MatchedProductId
    INNER JOIN #Page AS page ON page.RowKey = stockProduct.ItemID
    WHERE registry.OrganizationId = @OrganizationId AND registry.IsActive = 1;

    INSERT #Value (RowKey, FieldCode, Value)
    SELECT erp.RowKey, field.FieldCode, field.Value
    FROM
    (
      SELECT RowKey,
        /* Splet ne prodaja minusa: negativna ERP zaloga gre ven kot 0. */
        Quantity = CASE WHEN SUM(Quantity) < 0 THEN 0 ELSE SUM(Quantity) END,
        Available = CASE WHEN SUM(Available) < 0 THEN 0 ELSE SUM(Available) END,
        Ordered = SUM(Ordered), ForShipment = SUM(ForShipment), SupplierOrdered = SUM(SupplierOrdered)
      FROM #Stock
      WHERE Contribution IN (N''BASE'', N''ADD'')
      GROUP BY RowKey
    ) AS erp
    CROSS APPLY
    (
      VALUES
        (N''Stock.ErpCurrent'', out.MagentoNumber(erp.Quantity)),
        (N''Stock.ErpAvailable'', out.MagentoNumber(erp.Available)),
        (N''Stock.ErpOrdered'', out.MagentoNumber(erp.Ordered)),
        (N''Stock.ErpForShipment'', out.MagentoNumber(erp.ForShipment)),
        (N''Stock.ErpSupplierOrdered'', out.MagentoNumber(erp.SupplierOrdered))
    ) AS field (FieldCode, Value)
    WHERE field.Value IS NOT NULL;

    INSERT #Value (RowKey, FieldCode, Value)
    SELECT supplier.RowKey, field.FieldCode, field.Value
    FROM
    (
      SELECT RowKey,
        Quantity = SUM(Quantity), Incoming = SUM(Incoming), AvailabilityDate = MIN(AvailabilityDate)
      FROM #Stock
      WHERE Contribution = N''SUPPLIER''
      GROUP BY RowKey
    ) AS supplier
    CROSS APPLY
    (
      VALUES
        (N''Stock.SupplierQuantity'', out.MagentoNumber(supplier.Quantity)),
        (N''Stock.SupplierIncoming'', out.MagentoNumber(supplier.Incoming)),
        /* Oblika dd.MM.yyyy je pogodba iz starega izvoza (CONVERT 104). */
        (N''Stock.SupplierDate'', CONVERT(nvarchar(10), supplier.AvailabilityDate, 104))
    ) AS field (FieldCode, Value)
    WHERE field.Value IS NOT NULL;

    /* Skladisce: oznake ERP virov iz registra, v vrstnem redu registra, samo kadar je izdelek
       v tistem posnetku sploh prisoten. */
    INSERT #Value (RowKey, FieldCode, Value)
    SELECT labels.RowKey, N''Stock.Warehouse'',
      STRING_AGG(CONVERT(nvarchar(max), labels.WarehouseLabel), N'' + '') WITHIN GROUP (ORDER BY labels.SortOrder)
    FROM
    (
      SELECT DISTINCT page.RowKey, registry.WarehouseLabel, registry.SortOrder
      FROM out.ExportStockSource AS registry
      INNER JOIN map.SourceConnector AS connector
        ON connector.OrganizationId = registry.StockOrganizationId AND connector.SourceCode = registry.SourceCode
      INNER JOIN stock.Snapshot AS snapshot
        ON snapshot.SourceConnectorId = connector.SourceConnectorId AND snapshot.IsActive = 1
      INNER JOIN stock.Position AS position ON position.SnapshotId = snapshot.SnapshotId
      INNER JOIN canon.Product AS stockProduct ON stockProduct.ProductId = position.MatchedProductId
      INNER JOIN #Page AS page ON page.RowKey = stockProduct.ItemID
      WHERE registry.OrganizationId = @OrganizationId AND registry.IsActive = 1
        AND registry.Contribution IN (N''BASE'', N''ADD'') AND NULLIF(registry.WarehouseLabel, N'''') IS NOT NULL
    ) AS labels
    GROUP BY labels.RowKey;
  END

  /* ============================================================================
     C) STRANKE ZA MAGENTO — nespremenjeno od 142.
     ============================================================================ */
  ELSE IF @ValueSource = N''PIM_CUSTOMER''
  BEGIN
    SELECT @TotalCount = COUNT(*)
    FROM b2b.Customer AS customer
    INNER JOIN pim.CustomerWebProfile AS profile ON profile.CustomerId = customer.CustomerId
    WHERE customer.OrganizationId = @OrganizationId
      AND (@OnlyPublished = 0 OR profile.WebEnabled = 1)
      AND (@SearchLike IS NULL OR customer.CustomerKey LIKE @SearchLike OR customer.Name LIKE @SearchLike);

    INSERT #Page (RowKey, EntityId)
    SELECT customer.CustomerKey, customer.CustomerId
    FROM b2b.Customer AS customer
    INNER JOIN pim.CustomerWebProfile AS profile ON profile.CustomerId = customer.CustomerId
    WHERE customer.OrganizationId = @OrganizationId
      AND (@OnlyPublished = 0 OR profile.WebEnabled = 1)
      AND (@SearchLike IS NULL OR customer.CustomerKey LIKE @SearchLike OR customer.Name LIKE @SearchLike)
    ORDER BY customer.CustomerKey
    OFFSET @Skip ROWS FETCH NEXT @Fetch ROWS ONLY;

    INSERT #Value (RowKey, FieldCode, Value)
    SELECT core.RowKey, field.FieldCode, field.Value
    FROM
    (
      SELECT
        page.RowKey, customer.Name, magentoGroup.MagentoGroupKey, customer.PriceListCode,
        customer.PayerCode, customer.PayerName,
        profile.PackagingDiscountEnabled, profile.ValueDiscountEnabled,
        CONVERT(bit, CASE WHEN profile.B2bPlusEnabled = 1
          AND (profile.B2bPlusValidFrom IS NULL OR profile.B2bPlusValidFrom <= CONVERT(date, SYSUTCDATETIME()))
          AND (profile.B2bPlusValidTo IS NULL OR profile.B2bPlusValidTo >= CONVERT(date, SYSUTCDATETIME()))
          THEN 1 ELSE 0 END) AS B2bPlus,
        contact.Email, contact.Phone, contact.Mobile, contact.Persons,
        COALESCE(tier1.ThresholdGrossExVat, default1.ThresholdGrossExVat) AS Tier1Threshold,
        COALESCE(tier1.PercentValue, default1.PercentValue) AS Tier1Percent,
        COALESCE(tier2.ThresholdGrossExVat, default2.ThresholdGrossExVat) AS Tier2Threshold,
        COALESCE(tier2.PercentValue, default2.PercentValue) AS Tier2Percent,
        COALESCE(tier3.ThresholdGrossExVat, default3.ThresholdGrossExVat) AS Tier3Threshold,
        COALESCE(tier3.PercentValue, default3.PercentValue) AS Tier3Percent
      FROM #Page AS page
      INNER JOIN b2b.Customer AS customer ON customer.CustomerId = page.EntityId
      INNER JOIN pim.CustomerWebProfile AS profile ON profile.CustomerId = customer.CustomerId
      LEFT JOIN pim.CustomerTypeMagentoGroup AS magentoGroup ON magentoGroup.CustomerTypeCode = profile.CustomerTypeCode
      LEFT JOIN pim.CustomerContact AS contact
        ON contact.CustomerId = customer.CustomerId AND contact.OrganizationId = customer.OrganizationId
      LEFT JOIN pim.CustomerValueDiscountTier AS tier1 ON tier1.CustomerId = customer.CustomerId AND tier1.TierNumber = 1 AND tier1.IsActive = 1
      LEFT JOIN pim.CustomerValueDiscountTier AS tier2 ON tier2.CustomerId = customer.CustomerId AND tier2.TierNumber = 2 AND tier2.IsActive = 1
      LEFT JOIN pim.CustomerValueDiscountTier AS tier3 ON tier3.CustomerId = customer.CustomerId AND tier3.TierNumber = 3 AND tier3.IsActive = 1
      LEFT JOIN pim.ValueDiscountTier AS default1 ON default1.TierNumber = 1 AND default1.IsActive = 1
      LEFT JOIN pim.ValueDiscountTier AS default2 ON default2.TierNumber = 2 AND default2.IsActive = 1
      LEFT JOIN pim.ValueDiscountTier AS default3 ON default3.TierNumber = 3 AND default3.IsActive = 1
    ) AS core
    CROSS APPLY
    (
      VALUES
        (N''Customer.Key'', CONVERT(nvarchar(max), core.RowKey)),
        (N''Customer.Name'', CONVERT(nvarchar(max), core.Name)),
        (N''Customer.MagentoGroup'', CONVERT(nvarchar(max), core.MagentoGroupKey)),
        (N''Customer.PriceList'', CONVERT(nvarchar(max), core.PriceListCode)),
        (N''Customer.Payer'', CASE WHEN NULLIF(core.PayerCode, N'''') IS NULL AND NULLIF(core.PayerName, N'''') IS NULL
           THEN NULL ELSE CONVERT(nvarchar(max), ISNULL(core.PayerCode, N'''') + N''|'' + ISNULL(core.PayerName, N'''')) END),
        (N''Customer.Email'', CONVERT(nvarchar(max), core.Email)),
        (N''Customer.Phone'', CONVERT(nvarchar(max), COALESCE(NULLIF(core.Phone, N''''), NULLIF(core.Mobile, N'''')))),
        (N''Customer.Persons'', CONVERT(nvarchar(max), core.Persons)),
        (N''Customer.PackagingDiscountEnabled'', CASE WHEN core.PackagingDiscountEnabled = 1 THEN N''1'' ELSE N''0'' END),
        (N''Customer.ValueDiscountEnabled'', CASE WHEN core.ValueDiscountEnabled = 1 THEN N''1'' ELSE N''0'' END),
        (N''Customer.B2bPlus'', CASE WHEN core.B2bPlus = 1 THEN N''1'' ELSE N''0'' END),
        (N''Customer.Tier1Threshold'', CONVERT(nvarchar(max), out.MagentoNumber(core.Tier1Threshold))),
        (N''Customer.Tier1Percent'', CONVERT(nvarchar(max), out.MagentoNumber(core.Tier1Percent))),
        (N''Customer.Tier2Threshold'', CONVERT(nvarchar(max), out.MagentoNumber(core.Tier2Threshold))),
        (N''Customer.Tier2Percent'', CONVERT(nvarchar(max), out.MagentoNumber(core.Tier2Percent))),
        (N''Customer.Tier3Threshold'', CONVERT(nvarchar(max), out.MagentoNumber(core.Tier3Threshold))),
        (N''Customer.Tier3Percent'', CONVERT(nvarchar(max), out.MagentoNumber(core.Tier3Percent)))
    ) AS field (FieldCode, Value)
    WHERE field.Value IS NOT NULL;

    CREATE TABLE #GroupDiscount
      (RowKey nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
       ItemGroupCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
       PercentText nvarchar(50) COLLATE DATABASE_DEFAULT NULL);

    INSERT #GroupDiscount (RowKey, ItemGroupCode, PercentText)
    SELECT page.RowKey, discount.ItemGroupCode, out.MagentoNumber(discount.PercentValue)
    FROM #Page AS page
    INNER JOIN b2b.GroupDiscount AS discount ON discount.CustomerId = page.EntityId
    WHERE (discount.ValidFrom IS NULL OR discount.ValidFrom <= CONVERT(date, SYSUTCDATETIME()))
      AND (discount.ValidTo IS NULL OR discount.ValidTo >= CONVERT(date, SYSUTCDATETIME()));

    INSERT #Value (RowKey, FieldCode, Value)
    SELECT RowKey, N''Customer.GroupDiscounts'',
      STRING_AGG(CONVERT(nvarchar(max), ItemGroupCode + N''='' + ISNULL(PercentText, N'''') + N''%''), N'' | '')
        WITHIN GROUP (ORDER BY ItemGroupCode)
    FROM #GroupDiscount
    GROUP BY RowKey;

    INSERT #Value (RowKey, FieldCode, Value)
    SELECT RowKey, N''Customer.NwDiscount'', MIN(PercentText)
    FROM #GroupDiscount
    WHERE UPPER(ItemGroupCode) = N''NW''
    GROUP BY RowKey;
  END

  ELSE THROW 52976, N''Izvozni profil nima znanega vira vrednosti.'', 1;

  CREATE CLUSTERED INDEX IX_Value ON #Value (RowKey);

  /* ============================================================================
     D) Oblika rezultata pride iz registra: glave, vrstni red in kanonicne kode.
     ============================================================================ */
  DECLARE @Quote nchar(1) = NCHAR(39);
  DECLARE @SelectList nvarchar(max);
  SELECT @SelectList = STRING_AGG(CONVERT(nvarchar(max),
    CASE WHEN NULLIF(registryColumn.CanonicalFieldCode, N'''') IS NULL
      THEN N''CAST(NULL AS nvarchar(max)) AS '' + QUOTENAME(registryColumn.OutputColumnName)
      ELSE N''MAX(CASE WHEN fieldValue.FieldCode = N'' + @Quote
           + REPLACE(registryColumn.CanonicalFieldCode, @Quote, @Quote + @Quote) + @Quote
           + N'' THEN fieldValue.Value END) AS '' + QUOTENAME(registryColumn.OutputColumnName)
    END), N'','') WITHIN GROUP (ORDER BY registryColumn.SortOrder)
  FROM out.ExportColumn AS registryColumn
  WHERE registryColumn.ExportProfileId = @ExportProfileId AND registryColumn.IsActive = 1;

  DECLARE @Sql nvarchar(max) = N''
    SELECT '' + @SelectList + N''
    FROM #Page AS page
    LEFT JOIN #Value AS fieldValue ON fieldValue.RowKey = page.RowKey
    GROUP BY page.RowKey
    ORDER BY page.RowKey;'';

  EXEC sys.sp_executesql @Sql;
END');

/* --- 6) Pripravljenost pove se, koliko objavljenih nima spletne strani ------------------- */

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetExportReadiness
  @OrganizationId int,
  @TopReasons int = 20
AS
BEGIN
  SET NOCOUNT ON;
  SET @TopReasons = CASE WHEN @TopReasons < 1 THEN 20 WHEN @TopReasons > 100 THEN 100 ELSE @TopReasons END;

  /* Zastavice po izdelku najprej (podpoizvedbe v agregatu SQL Server ne dovoli), nato sestevek. */
  SELECT
    CanonicalCount = COUNT_BIG(*),
    ActiveCount = SUM(CASE WHEN flags.IsActive = 1 THEN 1 ELSE 0 END),
    PublishedCount = SUM(CASE WHEN flags.PimProductId IS NULL THEN 0 ELSE 1 END),
    NotPublishedCount = SUM(CASE WHEN flags.PimProductId IS NULL THEN 1 ELSE 0 END),
    WebFlaggedCount = SUM(CASE WHEN flags.WebPublish = 1 THEN 1 ELSE 0 END),
    PublishedWithOpenIssues = SUM(CASE WHEN flags.PimProductId IS NOT NULL AND flags.ValidationStatus <> N''VALID'' THEN 1 ELSE 0 END),
    /* 146: pravilo spletne strani in veljavnosti za splet — kar iz datoteke izpade. */
    WebSiteMissingCount = SUM(CASE WHEN flags.PimProductId IS NOT NULL AND flags.WebPublish = 1 AND flags.HasSite = 0 THEN 1 ELSE 0 END),
    WebInvalidCount = SUM(CASE WHEN flags.PimProductId IS NOT NULL AND flags.WebPublish = 1 AND flags.HasSite = 1 AND flags.WebBlocked = 1 THEN 1 ELSE 0 END),
    WebExportableCount = SUM(CASE WHEN flags.PimProductId IS NOT NULL AND flags.WebPublish = 1 AND flags.HasSite = 1 AND flags.WebBlocked = 0 THEN 1 ELSE 0 END)
  FROM
  (
    SELECT product.ProductId, product.IsActive, product.WebPublish, product.ValidationStatus, promoted.PimProductId,
      HasSite = CASE WHEN EXISTS (SELECT 1 FROM pim.ProductCategory AS category WHERE category.PimProductId = promoted.PimProductId) THEN 1 ELSE 0 END,
      WebBlocked = CASE WHEN EXISTS
        (SELECT 1 FROM val.ValidationProfile AS profile
         LEFT JOIN val.ProductValidationState AS state
           ON state.ProductId = product.ProductId AND state.ValidationProfileId = profile.ValidationProfileId
         WHERE profile.IsActive = 1 AND profile.BlocksWeb = 1
           AND (profile.CategoryTreeCode IS NULL OR EXISTS
             (SELECT 1 FROM pim.ProductCategory AS category
              INNER JOIN canon.WebSite AS site ON site.WebSiteCode = category.WebSite
              WHERE category.PimProductId = promoted.PimProductId AND site.CategoryTreeCode = profile.CategoryTreeCode))
           AND ISNULL(state.Status, N''INVALID'') <> N''VALID'') THEN 1 ELSE 0 END
    FROM canon.Product AS product
    LEFT JOIN pim.Product AS promoted
      ON promoted.OrganizationId = product.OrganizationId AND promoted.ItemID = product.ItemID
    WHERE product.OrganizationId = @OrganizationId
  ) AS flags;

  SELECT TOP (@TopReasons)
    FieldCode = COALESCE(requirement.FieldCode, issueValue.IssueCode),
    profileValue.ProfileCode, profileValue.BlocksErp, profileValue.BlocksWeb,
    Severity = COALESCE(requirement.Severity, N''ERROR''),
    ProductCount = COUNT_BIG(DISTINCT issueValue.ProductId)
  FROM val.ProductIssue AS issueValue
  INNER JOIN canon.Product AS product
    ON product.ProductId = issueValue.ProductId AND product.OrganizationId = @OrganizationId
  LEFT JOIN pim.Product AS promoted
    ON promoted.OrganizationId = product.OrganizationId AND promoted.ItemID = product.ItemID
  INNER JOIN val.ValidationProfile AS profileValue
    ON profileValue.ValidationProfileId = issueValue.ValidationProfileId
  LEFT JOIN val.FieldRequirement AS requirement
    ON requirement.FieldRequirementId = issueValue.FieldRequirementId
  WHERE issueValue.IsActive = 1
    AND promoted.PimProductId IS NULL
    AND (profileValue.BlocksErp = 1 OR profileValue.BlocksWeb = 1)
    AND COALESCE(requirement.Severity, N''ERROR'') = N''ERROR''
  GROUP BY COALESCE(requirement.FieldCode, issueValue.IssueCode), profileValue.ProfileCode,
    profileValue.BlocksErp, profileValue.BlocksWeb, COALESCE(requirement.Severity, N''ERROR'')
  ORDER BY COUNT_BIG(DISTINCT issueValue.ProductId) DESC;

  SELECT profile.ProfileCode, profile.Name, profile.ChannelCode, profile.EntityType, profile.IsActive,
    ColumnCount = COUNT_BIG(columnDefinition.ExportColumnId),
    MappedColumnCount = SUM(CASE WHEN NULLIF(columnDefinition.CanonicalFieldCode, N'''') IS NULL THEN 0 ELSE 1 END),
    UnmappedColumnCount = SUM(CASE WHEN NULLIF(columnDefinition.CanonicalFieldCode, N'''') IS NULL THEN 1 ELSE 0 END),
    RequiredUnmappedCount = SUM(CASE WHEN columnDefinition.IsRequired = 1 AND NULLIF(columnDefinition.CanonicalFieldCode, N'''') IS NULL THEN 1 ELSE 0 END)
  FROM out.ExportProfile AS profile
  LEFT JOIN out.ExportColumn AS columnDefinition
    ON columnDefinition.ExportProfileId = profile.ExportProfileId AND columnDefinition.IsActive = 1
  GROUP BY profile.ExportProfileId, profile.ProfileCode, profile.Name, profile.ChannelCode, profile.EntityType, profile.IsActive
  ORDER BY profile.ProfileCode;
END');

/* --- dokaz ------------------------------------------------------------------------------ */

IF (SELECT COUNT(*) FROM out.ExportStockSource WHERE OrganizationId = 3 AND Contribution IN (N'BASE', N'ADD') AND IsActive = 1) < 2
  THROW 51461, N'146: Vidadria nima obeh ERP virov zaloge (lastni + IQL Brnciceva).', 1;
IF EXISTS (SELECT 1 FROM out.ExportColumn WHERE ExportProfileId = @ProductProfileId
           AND ColumnCode IN (N'COL043', N'COL046', N'COL050', N'COL053') AND NULLIF(CanonicalFieldCode, N'') IS NULL)
  THROW 51462, N'146: stolpci zaloge v profilu MAGENTO_PRODUCTS so ostali brez vira.', 1;
IF (SELECT COUNT(*) FROM out.ExportColumn WHERE ExportProfileId = @FastProfileId AND IsActive = 1) <> 14
  THROW 51463, N'146: hitri profil MAGENTO_STOCK_PRICES nima 14 stolpcev.', 1;
/* Stolpec CategoryTreeCode nastane v tej isti seriji, zato gre njegov dokaz skozi EXEC. */
EXEC(N'
IF NOT EXISTS (SELECT 1 FROM val.ValidationProfile WHERE ProfileCode = N''WEB_svetila_si'' AND CategoryTreeCode = N''svetila_si'')
  THROW 51464, N''146: profil WEB_svetila_si ni vezan na drevo svetila_si.'', 1;
IF NOT EXISTS (SELECT 1 FROM out.ExportProfile WHERE ProfileCode = N''MAGENTO_STOCK_PRICES'' AND RequireWebValid = 0)
  THROW 51466, N''146: hitri profil zahteva veljavnost za splet, ceprav je ne sme.'', 1;
');
IF OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows')) NOT LIKE N'%out.ExportStockSource%'
  THROW 51465, N'146: out.GetExportRows ne bere registra virov zaloge.', 1;

/* Izvedba nad resnicnimi podatki: produktni profil, hitri profil in profil strank se morajo
   prevesti in izvesti. Migrator rezultat zavrze. */
DECLARE @ProbeTotal int;
DECLARE @CustomerProfileId int =
  (SELECT ExportProfileId FROM out.ExportProfile WHERE ProfileCode = N'MAGENTO_CUSTOMERS' AND IsActive = 1);
DECLARE @ProbeOrganizationId int = (SELECT MIN(OrganizationId) FROM dbo.OrganizationConfig);

EXEC out.GetExportRows @OrganizationId = @ProbeOrganizationId, @ExportProfileId = @ProductProfileId,
  @WebSite = NULL, @OnlyPublished = 1, @Search = NULL, @Skip = 0, @Take = 1, @TotalCount = @ProbeTotal OUTPUT;
EXEC out.GetExportRows @OrganizationId = @ProbeOrganizationId, @ExportProfileId = @FastProfileId,
  @WebSite = NULL, @OnlyPublished = 1, @Search = NULL, @Skip = 0, @Take = 1, @TotalCount = @ProbeTotal OUTPUT;
IF @CustomerProfileId IS NOT NULL
  EXEC out.GetExportRows @OrganizationId = @ProbeOrganizationId, @ExportProfileId = @CustomerProfileId,
    @WebSite = NULL, @OnlyPublished = 1, @Search = NULL, @Skip = 0, @Take = 1, @TotalCount = @ProbeTotal OUTPUT;
