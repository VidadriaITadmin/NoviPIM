/*
  216 — posebni S-popust stranke na posameznem izdelku: vnos na kartici stranke in izpis v
  izvozu za Magento.

  Uporabnik 2026-09-15: »naredi vnos posebnega S na kartici stranke«. Pravilo iz dokumenta
  Magento_Pravila_Cene_Popusti_Postnine §4.5: stolpec »Posebni S – stranka / popust« v obliki
  sifra\Skoda | sifra\Skoda (npr. 303\S2 | 304\S3) pomeni, da za navedeno stranko na tem izdelku
  velja drugacen S kot privzeti S izdelka.

  Stanje pred migracijo: tabela b2b.CustomerPackagingDiscountOverride (020) in prikaz na kartici
  stranke (129/200, »Posebni popusti za stranko«) sta obstajala, vpisnega mesta ni bilo, izvozni
  stolpec COL037 »Posebni popust za stranko« (045) pa ni imel vira in je bil vedno prazen.

  Kaj ta migracija naredi:
    1. out.GetExportRows: jedro izdelka dobi stolpec SpecialCustomerDiscounts (STRING_AGG po
       aktivnih, danes veljavnih odstopanjih; sifra stranke = b2b.Customer.CustomerKey) in polje
       Product.SpecialCustomerDiscounts v seznamu polj. Popravek gre z zamenjavo besedila zive
       definicije z oznako /* SpecialS216 */ — enako kot 194–214, ker CREATE OR ALTER zahteva
       celoten ponovni zapis 43.000 znakov dolge procedure.
    2. out.ExportColumn COL037 dobi vir Product.SpecialCustomerDiscounts.
    3. b2b.SaveCustomerPackagingDiscountOverride — vpis (sifra artikla, S koda, veljavnost),
       b2b.RemoveCustomerPackagingDiscountOverride — ukinitev; oba z revizijsko sledjo b2b.AuditLog.
    4. intranet.GetPackagingDiscountCatalog — sifrant S kod za izbirnik.
*/

SET XACT_ABORT ON;

/* --- 1) out.GetExportRows: posebni S po stranki v jedru izdelka ------------------------- */

DECLARE @old nvarchar(max), @new nvarchar(max), @definition nvarchar(max);

SET @definition = OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows'));
IF @definition IS NULL THROW 52240, N'216: out.GetExportRows ne obstaja.', 1;

IF @definition NOT LIKE N'%/* SpecialS216 */%'
BEGIN
  /* a) jedro: stolpec za STRING_AGG odstopanj. Sidro je vrstica z odstotkom S kode izdelka. */
  SET @old = NCHAR(10) + N'        discountCatalog.PercentValue AS PackagingDiscountPercent,' + NCHAR(10);
  IF (LEN(@definition) - LEN(REPLACE(@definition, @old, N''))) / LEN(@old) <> 1
    THROW 52241, N'216: out.GetExportRows nima pricakovane vrstice PackagingDiscountPercent v jedru.', 1;
  SET @new = NCHAR(10) + N'        discountCatalog.PercentValue AS PackagingDiscountPercent,' + NCHAR(10)
    + N'        SpecialCustomerDiscounts = /* SpecialS216 */ (SELECT STRING_AGG(CONVERT(nvarchar(max), special216.CustomerKey + N''\'' + special216.DiscountCode), N'' | '') WITHIN GROUP (ORDER BY special216.CustomerKey)' + NCHAR(10)
    + N'          FROM (SELECT DISTINCT customer216.CustomerKey, override216.DiscountCode' + NCHAR(10)
    + N'                FROM b2b.CustomerPackagingDiscountOverride AS override216' + NCHAR(10)
    + N'                INNER JOIN b2b.Customer AS customer216 ON customer216.CustomerId = override216.CustomerId' + NCHAR(10)
    + N'                WHERE override216.PimProductId = product.PimProductId AND override216.IsActive = 1' + NCHAR(10)
    + N'                  AND (override216.ValidFrom IS NULL OR override216.ValidFrom <= CONVERT(date, SYSUTCDATETIME()))' + NCHAR(10)
    + N'                  AND (override216.ValidTo IS NULL OR override216.ValidTo >= CONVERT(date, SYSUTCDATETIME()))) AS special216),' + NCHAR(10);
  SET @definition = REPLACE(@definition, @old, @new);

  /* b) seznam polj: novo polje takoj za odstotkom S kode. */
  SET @old = NCHAR(10) + N'        (N''Product.PackagingDiscountPercent'', CONVERT(nvarchar(max), out.MagentoNumber(core.PackagingDiscountPercent))),' + NCHAR(10);
  IF (LEN(@definition) - LEN(REPLACE(@definition, @old, N''))) / LEN(@old) <> 1
    THROW 52242, N'216: out.GetExportRows nima pricakovanega polja Product.PackagingDiscountPercent v seznamu polj.', 1;
  SET @new = @old + N'        (N''Product.SpecialCustomerDiscounts'', CONVERT(nvarchar(max), core.SpecialCustomerDiscounts)),' + NCHAR(10);
  SET @definition = REPLACE(@definition, @old, @new);

  /* Shranjena definicija se zacne s CREATE [OR ALTER]/ALTER; vse pred besedo PROCEDURE postane
     ALTER (enak postopek kot 201/213/214). */
  DECLARE @headerEnd int = CHARINDEX(N'PROCEDURE', @definition);
  IF @headerEnd = 0 THROW 52243, N'216: glava out.GetExportRows ni najdena.', 1;
  SET @definition = N'ALTER ' + SUBSTRING(@definition, @headerEnd, 2147483647);
  EXEC sys.sp_executesql @definition;
END;

/* --- 2) register stolpcev: COL037 dobi vir ---------------------------------------------- */

UPDATE column216
SET CanonicalFieldCode = N'Product.SpecialCustomerDiscounts'
FROM out.ExportColumn AS column216
INNER JOIN out.ExportProfile AS profile216 ON profile216.ExportProfileId = column216.ExportProfileId
WHERE profile216.ProfileCode = N'MAGENTO_PRODUCTS' AND column216.ColumnCode = N'COL037'
  AND ISNULL(column216.CanonicalFieldCode, N'') <> N'Product.SpecialCustomerDiscounts';

/* --- 3) vpis in ukinitev ----------------------------------------------------------------- */

EXEC(N'CREATE OR ALTER PROCEDURE b2b.SaveCustomerPackagingDiscountOverride
  @OrganizationId int,
  @CustomerId bigint,
  @ItemID nvarchar(50),
  @DiscountCode nvarchar(10),
  @ValidFrom date = NULL,
  @ValidTo date = NULL,
  @ChangedBy nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  SET @ItemID = NULLIF(LTRIM(RTRIM(@ItemID)), N'''');
  SET @DiscountCode = NULLIF(UPPER(LTRIM(RTRIM(@DiscountCode))), N'''');

  IF NOT EXISTS (SELECT 1 FROM b2b.Customer WHERE CustomerId = @CustomerId AND OrganizationId = @OrganizationId)
    THROW 52000, N''Stranka ne obstaja.'', 1;
  IF @ItemID IS NULL THROW 52420, N''Vpisi sifro artikla.'', 1;

  DECLARE @PimProductId bigint = (SELECT PimProductId FROM pim.Product WHERE OrganizationId = @OrganizationId AND ItemID = @ItemID);
  IF @PimProductId IS NULL
    THROW 52421, N''Artikla s to sifro ni med objavljenimi izdelki tega podjetja; posebni S se dodeli samo promoviranemu izdelku.'', 1;

  IF @DiscountCode IS NULL OR NOT EXISTS (SELECT 1 FROM pim.PackagingDiscountCatalog WHERE DiscountCode = @DiscountCode AND IsActive = 1)
    THROW 52422, N''Neznana ali neaktivna S koda.'', 1;
  IF @ValidFrom IS NOT NULL AND @ValidTo IS NOT NULL AND @ValidTo < @ValidFrom
    THROW 52423, N''Konec veljavnosti je pred zacetkom.'', 1;

  BEGIN TRANSACTION;

  /* Za stranko in izdelek velja eno odstopanje: druga (z drugim zacetkom) se ukinejo. */
  UPDATE b2b.CustomerPackagingDiscountOverride
  SET IsActive = 0
  WHERE CustomerId = @CustomerId AND PimProductId = @PimProductId AND IsActive = 1
    AND NOT EXISTS (SELECT ValidFrom INTERSECT SELECT @ValidFrom);

  DECLARE @Id bigint = (SELECT OverrideId FROM b2b.CustomerPackagingDiscountOverride
    WHERE CustomerId = @CustomerId AND PimProductId = @PimProductId AND EXISTS (SELECT ValidFrom INTERSECT SELECT @ValidFrom));
  DECLARE @Old nvarchar(max) = (SELECT * FROM b2b.CustomerPackagingDiscountOverride WHERE OverrideId = @Id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

  IF @Id IS NULL
  BEGIN
    INSERT b2b.CustomerPackagingDiscountOverride (CustomerId, PimProductId, DiscountCode, ValidFrom, ValidTo, IsActive)
    VALUES (@CustomerId, @PimProductId, @DiscountCode, @ValidFrom, @ValidTo, 1);
    SET @Id = SCOPE_IDENTITY();
  END
  ELSE
    UPDATE b2b.CustomerPackagingDiscountOverride
    SET DiscountCode = @DiscountCode, ValidTo = @ValidTo, IsActive = 1
    WHERE OverrideId = @Id;

  INSERT b2b.AuditLog (OrganizationId, EntityType, EntityKey, ActionCode, OldValueJson, NewValueJson, ChangedBy)
  SELECT @OrganizationId, N''CustomerPackagingOverride'', CONVERT(nvarchar(30), @Id),
    CASE WHEN @Old IS NULL THEN N''INSERT'' ELSE N''UPSERT'' END, @Old,
    (SELECT * FROM b2b.CustomerPackagingDiscountOverride WHERE OverrideId = @Id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
    @ChangedBy;

  COMMIT;
  SELECT OverrideId = @Id;
END;');

EXEC(N'CREATE OR ALTER PROCEDURE b2b.RemoveCustomerPackagingDiscountOverride
  @OrganizationId int,
  @CustomerId bigint,
  @OverrideId bigint,
  @ChangedBy nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  IF NOT EXISTS (SELECT 1 FROM b2b.Customer WHERE CustomerId = @CustomerId AND OrganizationId = @OrganizationId)
    THROW 52000, N''Stranka ne obstaja.'', 1;

  DECLARE @Old nvarchar(max) = (SELECT * FROM b2b.CustomerPackagingDiscountOverride
    WHERE OverrideId = @OverrideId AND CustomerId = @CustomerId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
  IF @Old IS NULL THROW 52424, N''Posebni popust ne obstaja ali ne pripada tej stranki.'', 1;

  BEGIN TRANSACTION;
  UPDATE b2b.CustomerPackagingDiscountOverride SET IsActive = 0 WHERE OverrideId = @OverrideId AND CustomerId = @CustomerId;
  INSERT b2b.AuditLog (OrganizationId, EntityType, EntityKey, ActionCode, OldValueJson, NewValueJson, ChangedBy)
  SELECT @OrganizationId, N''CustomerPackagingOverride'', CONVERT(nvarchar(30), @OverrideId), N''DEACTIVATE'', @Old,
    (SELECT * FROM b2b.CustomerPackagingDiscountOverride WHERE OverrideId = @OverrideId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
    @ChangedBy;
  COMMIT;
END;');

/* --- 4) sifrant S kod za izbirnik -------------------------------------------------------- */

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetPackagingDiscountCatalog
AS
BEGIN
  SET NOCOUNT ON;
  SELECT DiscountCode, PercentValue FROM pim.PackagingDiscountCatalog WHERE IsActive = 1 ORDER BY PercentValue, DiscountCode;
END;');

/* --- Preverbe ---------------------------------------------------------------------------- */

IF OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows')) NOT LIKE N'%/* SpecialS216 */%'
  THROW 52244, N'216: out.GetExportRows nima posebnega S po stranki.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows')) NOT LIKE N'%N''Product.SpecialCustomerDiscounts''%'
  THROW 52245, N'216: out.GetExportRows ne oddaja polja Product.SpecialCustomerDiscounts.', 1;
IF NOT EXISTS (SELECT 1 FROM out.ExportColumn AS column216
  INNER JOIN out.ExportProfile AS profile216 ON profile216.ExportProfileId = column216.ExportProfileId
  WHERE profile216.ProfileCode = N'MAGENTO_PRODUCTS' AND column216.ColumnCode = N'COL037'
    AND column216.CanonicalFieldCode = N'Product.SpecialCustomerDiscounts')
  THROW 52246, N'216: stolpec COL037 nima vira Product.SpecialCustomerDiscounts.', 1;
IF OBJECT_ID(N'b2b.SaveCustomerPackagingDiscountOverride', N'P') IS NULL
  OR OBJECT_ID(N'b2b.RemoveCustomerPackagingDiscountOverride', N'P') IS NULL
  OR OBJECT_ID(N'intranet.GetPackagingDiscountCatalog', N'P') IS NULL
  THROW 52247, N'216: procedure za posebni S niso nastale.', 1;
