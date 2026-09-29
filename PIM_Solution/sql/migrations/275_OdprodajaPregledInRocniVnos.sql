/* 275: Odprodaja kot en pregleden sistem — pregled, ročni vnos in razstavni eksponat.

   Uporabnik 2026-09-23: »zrihtej mi sistem v PIMu, kjer bomo lahko dali artikle v odprodajo, jih
   označimo kot odprodajo in kot razstavni eksponat in določimo popust za odprodajo, da bo te
   podatke katalog.csv bral.«

   Kar je že obstajalo in ostane nespremenjeno:
     - pim.ClearanceItem (153/232) in uvoz iz Excela (/izdelki/uvoz-odprodaje, pim.SaveClearanceItems),
     - oznaka RAZSTAVNI_EKSPONAT (233, pim.ProductFlag),
     - stolpci v katalog.csv (234, out.GetExportRows): »Odprodaja« (DA, kadar ima artikel aktivno
       vrstico s količino > 0), »Odprodaja - popust %«, »Odprodaja - količina«, »Razstavni eksponat«.
       Izvoza ta migracija ne spreminja.

   Kaj manjka in ga ta migracija doda:
     - pim.SaveClearanceItem: en artikel ročno (s strani Odprodaja ali s kartice) — količina, popust
       in razstavni eksponat v enem zapisu, brez Excela.
     - pim.SaveClearanceItems: uvoz iz Excela bere še stolpec »Razstavni eksponat« (JSON "razstavni").
       Telo je iz 232, dodana sta samo razstavni eksponat in čiščenje oznake ob samodejni zaključitvi.
     - pim.EndClearanceItem: ob zaključitvi odprodaje artikel izgubi oznako razstavni eksponat, kadar
       nima nobene druge aktivne odprodaje — na spletu sicer ostane »Razstavni eksponat: DA« brez
       odprodaje.
     - intranet.GetClearanceOverview: ena tabela za stran /izdelki/odprodaja — aktivne vrstice z
       nazivom, spletnimi stranmi in tem, ali gredo v katalog.csv; plus razstavni eksponati brez
       odprodaje (da jih je mogoče najti in počistiti).
     - Pravica view.products.clearance za novo stran (ADMIN, CATALOG_EDITOR, COMMERCIAL — isto kot
       [Authorize] na strani uvoza odprodaje). */
SET XACT_ABORT ON;
GO

/* Skupni zapis oznake RAZSTAVNI_EKSPONAT za več artiklov naenkrat, z zgodovino. Kliče se znotraj
   transakcije klicatelja. Vhod: [{"productId":123,"isSet":1}, ...]. */
CREATE OR ALTER PROCEDURE pim.SetShowcaseFlags
  @OrganizationId int,
  @ChangesJson nvarchar(max),
  @Actor nvarchar(200),
  @ChangeSource nvarchar(50),
  @Note nvarchar(400) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  DECLARE @Changes TABLE (ProductId bigint NOT NULL PRIMARY KEY, IsSet bit NOT NULL);
  INSERT @Changes (ProductId, IsSet)
  SELECT parsed.productId, MAX(CAST(parsed.isSet AS int))
  FROM OPENJSON(@ChangesJson) WITH (productId bigint N'$.productId', isSet bit N'$.isSet') AS parsed
  JOIN canon.Product product ON product.ProductId = parsed.productId AND product.OrganizationId = @OrganizationId
  WHERE parsed.productId IS NOT NULL AND parsed.isSet IS NOT NULL
  GROUP BY parsed.productId;

  DECLARE @Changed TABLE (ProductId bigint, OldValue nvarchar(10), NewValue nvarchar(10));
  MERGE pim.ProductFlag AS target
  USING @Changes AS source ON target.ProductId = source.ProductId AND target.FlagCode = N'RAZSTAVNI_EKSPONAT'
  WHEN MATCHED AND target.IsSet <> source.IsSet
    THEN UPDATE SET IsSet = source.IsSet, ChangedBy = @Actor, ChangedUtc = SYSUTCDATETIME()
  WHEN NOT MATCHED BY TARGET AND source.IsSet = 1
    THEN INSERT (ProductId, FlagCode, IsSet, ChangedBy) VALUES (source.ProductId, N'RAZSTAVNI_EKSPONAT', 1, @Actor)
  OUTPUT inserted.ProductId,
         CASE WHEN deleted.IsSet = 1 THEN N'da' ELSE N'ne' END,
         CASE WHEN inserted.IsSet = 1 THEN N'da' ELSE N'ne' END
  INTO @Changed (ProductId, OldValue, NewValue);

  DELETE @Changed WHERE OldValue = NewValue;
  IF NOT EXISTS (SELECT 1 FROM @Changed) RETURN;

  DECLARE @BatchId bigint;
  INSERT pim.ProductChangeBatch (BatchId, ChangeSource, ChangedBy, OrganizationId, Note)
  VALUES (NEWID(), @ChangeSource, @Actor, @OrganizationId, @Note);
  SET @BatchId = SCOPE_IDENTITY();

  INSERT pim.ProductFieldHistory (ChangeBatchId, OrganizationId, ProductId, ItemID, FieldKey, CanonTable, CanonColumn, Owner, OldValue, NewValue)
  SELECT @BatchId, @OrganizationId, changed.ProductId, product.ItemID,
         N'ProductFlag.RAZSTAVNI_EKSPONAT', N'pim.ProductFlag', N'IsSet', N'PIM', changed.OldValue, changed.NewValue
  FROM @Changed changed
  JOIN canon.Product product ON product.ProductId = changed.ProductId;
END;
GO

/* En artikel v odprodajo (ali popravek obstoječe vrstice istega vira). Vrstica se znova aktivira in
   postane najnovejša, zato jo izvoz vzame (234 vzame najnovejšo aktivno vrstico artikla).
   @Razstavni NULL = oznake ne spreminjaj. */
CREATE OR ALTER PROCEDURE pim.SaveClearanceItem
  @OrganizationId int,
  @ItemID nvarchar(100),
  @Vir nvarchar(100),
  @Kolicina decimal(10,2),
  @PopustOdstotek decimal(5,2),
  @Razstavni bit = NULL,
  @Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  SET @ItemID = NULLIF(LTRIM(RTRIM(@ItemID)), N'');
  SET @Vir = NULLIF(LTRIM(RTRIM(@Vir)), N'');
  IF @ItemID IS NULL THROW 52901, N'Vnesi šifro artikla.', 1;
  IF @Vir IS NULL THROW 52902, N'Vnesi vir odprodaje.', 1;
  IF NULLIF(@Actor, N'') IS NULL THROW 52903, N'Manjka izvajalec.', 1;
  IF @Kolicina IS NULL OR @Kolicina < 0 THROW 52904, N'Količina mora biti 0 ali več.', 1;
  IF @PopustOdstotek IS NULL OR @PopustOdstotek < 0 OR @PopustOdstotek > 100 THROW 52905, N'Popust mora biti med 0 in 100 (odstotkov).', 1;

  DECLARE @ProductId bigint, @Ean nvarchar(100);
  SELECT @ProductId = ProductId, @Ean = EAN FROM canon.Product WHERE OrganizationId = @OrganizationId AND ItemID = @ItemID;
  IF @ProductId IS NULL THROW 52906, N'Artikla s to šifro v tem podjetju ni.', 1;

  DECLARE @Old nvarchar(200) = (
    SELECT CONCAT(N'kolicina=', CONVERT(nvarchar(50), Kolicina), N', popust=', CONVERT(nvarchar(50), PopustOdstotek), N'%',
                  CASE WHEN IsActive = 0 THEN N' (zaključena)' ELSE N'' END)
    FROM pim.ClearanceItem WHERE ProductId = @ProductId AND Vir = @Vir);

  BEGIN TRANSACTION;
  BEGIN TRY
    MERGE pim.ClearanceItem AS target
    USING (SELECT @ProductId AS ProductId) AS source ON target.ProductId = source.ProductId AND target.Vir = @Vir
    WHEN MATCHED THEN UPDATE SET
      Kolicina = @Kolicina, PopustOdstotek = @PopustOdstotek,
      OdprodajnaCena = CASE WHEN target.RednaCena IS NULL THEN NULL ELSE ROUND(target.RednaCena * (1 - @PopustOdstotek / 100), 2) END,
      IsActive = 1, EndedUtc = NULL, EndedBy = NULL, ImportiranoUtc = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT
      (ProductId, Vir, Sifra, Ean, NaSvetila, NaVidelektro, Kolicina, PopustOdstotek, IzvornaDatoteka)
      VALUES (@ProductId, @Vir, @ItemID, @Ean, 0, 0, @Kolicina, @PopustOdstotek, N'ročni vnos');

    DECLARE @BatchId bigint;
    INSERT pim.ProductChangeBatch (BatchId, ChangeSource, ChangedBy, OrganizationId, Note)
    VALUES (NEWID(), N'CLEARANCE_EDIT', @Actor, @OrganizationId, CONCAT(N'Odprodaja: ', @Vir));
    SET @BatchId = SCOPE_IDENTITY();
    INSERT pim.ProductFieldHistory (ChangeBatchId, OrganizationId, ProductId, ItemID, FieldKey, CanonTable, CanonColumn, Owner, OldValue, NewValue)
    VALUES (@BatchId, @OrganizationId, @ProductId, @ItemID, CONCAT(N'ClearanceItem.', @Vir), N'pim.ClearanceItem', N'Kolicina/PopustOdstotek', N'PIM',
            @Old, CONCAT(N'kolicina=', CONVERT(nvarchar(50), @Kolicina), N', popust=', CONVERT(nvarchar(50), @PopustOdstotek), N'%'));

    IF @Razstavni IS NOT NULL
    BEGIN
      DECLARE @Flag nvarchar(100) = CONCAT(N'[{"productId":', @ProductId, N',"isSet":', CASE WHEN @Razstavni = 1 THEN N'true' ELSE N'false' END, N'}]');
      EXEC pim.SetShowcaseFlags @OrganizationId, @Flag, @Actor, N'CLEARANCE_EDIT', N'Odprodaja: razstavni eksponat';
    END;

    COMMIT;
  END TRY
  BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    THROW;
  END CATCH

  SELECT ClearanceItemId FROM pim.ClearanceItem WHERE ProductId = @ProductId AND Vir = @Vir;
END;
GO

/* Uvoz iz Excela (232) + razstavni eksponat. JSON vrstica ima lahko "razstavni": true/false/null
   (null = stolpca v datoteki ni, oznake ne spreminjaj). Samodejno zaključene vrstice (šifra je iz
   datoteke izpadla) počistijo oznako, kadar artikel nima druge aktivne odprodaje. */
CREATE OR ALTER PROCEDURE pim.SaveClearanceItems
  @OrganizationId int,
  @Vir nvarchar(100),
  @ItemsJson nvarchar(max),
  @Actor nvarchar(200),
  @IzvornaDatoteka nvarchar(260) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  IF NULLIF(LTRIM(RTRIM(@Vir)), N'') IS NULL
    THROW 52601, N'Vnesi vir odprodajnega seznama.', 1;
  IF NULLIF(@Actor, N'') IS NULL
    THROW 52602, N'Manjka izvajalec.', 1;

  DECLARE @Rows TABLE (
    Sifra nvarchar(100) NOT NULL,
    ProductId bigint NULL,
    Kolicina decimal(19,4) NULL,
    RednaCena decimal(19,4) NULL,
    PopustOdstotek decimal(5,2) NULL,
    OdprodajnaCena decimal(19,4) NULL,
    Razstavni bit NULL
  );
  INSERT @Rows (Sifra, ProductId, Kolicina, RednaCena, PopustOdstotek, OdprodajnaCena, Razstavni)
  SELECT parsed.sifra, product.ProductId, parsed.kolicina, parsed.rednaCena, parsed.popustOdstotek, parsed.odprodajnaCena, parsed.razstavni
  FROM OPENJSON(@ItemsJson)
  WITH (
    sifra nvarchar(100) N'$.sifra',
    kolicina decimal(19,4) N'$.kolicina',
    rednaCena decimal(19,4) N'$.rednaCena',
    popustOdstotek decimal(5,2) N'$.popustOdstotek',
    odprodajnaCena decimal(19,4) N'$.odprodajnaCena',
    razstavni bit N'$.razstavni'
  ) AS parsed
  LEFT JOIN canon.Product product ON product.OrganizationId = @OrganizationId AND product.ItemID = parsed.sifra
  WHERE NULLIF(parsed.sifra, N'') IS NOT NULL;

  DECLARE @Ean TABLE (ProductId bigint PRIMARY KEY, Ean nvarchar(100));
  INSERT @Ean (ProductId, Ean) SELECT ProductId, EAN FROM canon.Product WHERE ProductId IN (SELECT ProductId FROM @Rows WHERE ProductId IS NOT NULL);

  DECLARE @Merged TABLE (ProductId bigint, WasActive bit, IsActive bit);

  BEGIN TRANSACTION;
  BEGIN TRY
    MERGE pim.ClearanceItem AS target
    USING (SELECT * FROM @Rows WHERE ProductId IS NOT NULL) AS source
      ON target.ProductId = source.ProductId AND target.Vir = @Vir
    WHEN MATCHED THEN UPDATE SET
      Sifra = source.Sifra, Kolicina = source.Kolicina, RednaCena = source.RednaCena,
      PopustOdstotek = source.PopustOdstotek, OdprodajnaCena = source.OdprodajnaCena,
      IsActive = 1, EndedUtc = NULL, EndedBy = NULL,
      IzvornaDatoteka = @IzvornaDatoteka, ImportiranoUtc = SYSUTCDATETIME()
    WHEN NOT MATCHED BY TARGET THEN INSERT
      (ProductId, Vir, Sifra, Ean, NaSvetila, NaVidelektro, Kolicina, RednaCena, PopustOdstotek, OdprodajnaCena, IzvornaDatoteka)
      VALUES (source.ProductId, @Vir, source.Sifra, (SELECT Ean FROM @Ean WHERE ProductId = source.ProductId), 0, 0,
              source.Kolicina, source.RednaCena, source.PopustOdstotek, source.OdprodajnaCena, @IzvornaDatoteka)
    WHEN NOT MATCHED BY SOURCE AND target.Vir = @Vir AND target.IsActive = 1 THEN UPDATE SET
      IsActive = 0, EndedUtc = SYSUTCDATETIME(), EndedBy = CONCAT(N'uvoz: ', @Vir)
    OUTPUT inserted.ProductId, deleted.IsActive, inserted.IsActive INTO @Merged (ProductId, WasActive, IsActive);

    DECLARE @BatchId bigint;
    IF EXISTS (SELECT 1 FROM @Rows WHERE ProductId IS NOT NULL)
    BEGIN
      INSERT pim.ProductChangeBatch (BatchId, ChangeSource, ChangedBy, OrganizationId, Note)
      VALUES (NEWID(), N'CLEARANCE_IMPORT', @Actor, @OrganizationId, CONCAT(N'Uvoz odprodaje: ', @Vir));
      SET @BatchId = SCOPE_IDENTITY();

      INSERT pim.ProductFieldHistory (ChangeBatchId, OrganizationId, ProductId, ItemID, FieldKey, CanonTable, CanonColumn, Owner, OldValue, NewValue)
      SELECT @BatchId, @OrganizationId, r.ProductId, r.Sifra, CONCAT(N'ClearanceItem.', @Vir), N'pim.ClearanceItem', N'Kolicina/PopustOdstotek', N'PIM', NULL,
        CONCAT(N'kolicina=', ISNULL(CONVERT(nvarchar(50), r.Kolicina), N'-'), N', popust=', ISNULL(CONVERT(nvarchar(50), r.PopustOdstotek), N'-'), N'%')
      FROM @Rows r WHERE r.ProductId IS NOT NULL;
    END;

    /* Razstavni eksponat: iz datoteke, kjer je stolpec; sicer počisti pri samodejno zaključenih. */
    DECLARE @Flags nvarchar(max) = (
      SELECT flags.productId, flags.isSet
      FROM (
        SELECT r.ProductId AS productId, MAX(CAST(r.Razstavni AS int)) AS isSet
        FROM @Rows r WHERE r.ProductId IS NOT NULL AND r.Razstavni IS NOT NULL
        GROUP BY r.ProductId
        UNION ALL
        SELECT m.ProductId, 0
        FROM @Merged m
        WHERE m.WasActive = 1 AND m.IsActive = 0
          AND NOT EXISTS (SELECT 1 FROM @Rows r WHERE r.ProductId = m.ProductId)
          AND NOT EXISTS (SELECT 1 FROM pim.ClearanceItem other WHERE other.ProductId = m.ProductId AND other.IsActive = 1)
      ) flags
      FOR JSON PATH);
    IF @Flags IS NOT NULL
      EXEC pim.SetShowcaseFlags @OrganizationId, @Flags, @Actor, N'CLEARANCE_IMPORT', N'Uvoz odprodaje: razstavni eksponat';

    COMMIT;
  END TRY
  BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    THROW;
  END CATCH

  SELECT
    (SELECT COUNT(*) FROM @Rows) AS RequestedCount,
    (SELECT COUNT(*) FROM @Rows WHERE ProductId IS NOT NULL) AS MatchedCount,
    (SELECT COUNT(*) FROM @Rows WHERE ProductId IS NULL) AS UnmatchedCount;
  SELECT Sifra AS NeujemajocaSifra FROM @Rows WHERE ProductId IS NULL;
END;
GO

/* Ročna zaključitev (232) + počisti razstavni eksponat, kadar artikel nima druge aktivne odprodaje. */
CREATE OR ALTER PROCEDURE pim.EndClearanceItem
  @ClearanceItemId bigint,
  @Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  IF NULLIF(@Actor, N'') IS NULL THROW 52603, N'Manjka izvajalec.', 1;

  DECLARE @ProductId bigint, @OrganizationId int;
  SELECT @ProductId = item.ProductId, @OrganizationId = product.OrganizationId
  FROM pim.ClearanceItem item JOIN canon.Product product ON product.ProductId = item.ProductId
  WHERE item.ClearanceItemId = @ClearanceItemId AND item.IsActive = 1;
  IF @ProductId IS NULL RETURN;

  BEGIN TRANSACTION;
    UPDATE pim.ClearanceItem
      SET IsActive = 0, EndedUtc = SYSUTCDATETIME(), EndedBy = @Actor
    WHERE ClearanceItemId = @ClearanceItemId AND IsActive = 1;

    IF NOT EXISTS (SELECT 1 FROM pim.ClearanceItem WHERE ProductId = @ProductId AND IsActive = 1)
    BEGIN
      DECLARE @Flag nvarchar(100) = CONCAT(N'[{"productId":', @ProductId, N',"isSet":false}]');
      EXEC pim.SetShowcaseFlags @OrganizationId, @Flag, @Actor, N'CLEARANCE_EDIT', N'Odprodaja zaključena';
    END;
  COMMIT;
END;
GO

/* Pregled za /izdelki/odprodaja. Ena vrstica na vrstico odprodaje; artikel z oznako razstavni
   eksponat brez aktivne odprodaje pride kot vrstica brez ClearanceItemId. VKatalogu pove isto, kar
   izvoz (234): najnovejša aktivna vrstica artikla s količino > 0. */
CREATE OR ALTER PROCEDURE intranet.GetClearanceOverview
  @OrganizationId int,
  @IncludeEnded bit = 0
AS
BEGIN
  SET NOCOUNT ON;

  WITH Items AS (
    SELECT item.*,
           ROW_NUMBER() OVER (PARTITION BY item.ProductId, item.IsActive ORDER BY item.ImportiranoUtc DESC) AS Rn
    FROM pim.ClearanceItem item
    JOIN canon.Product product ON product.ProductId = item.ProductId AND product.OrganizationId = @OrganizationId
    WHERE item.IsActive = 1 OR @IncludeEnded = 1
  )
  SELECT items.ClearanceItemId, product.ProductId, product.ItemID, title.Value AS Naziv,
         items.Vir, items.Kolicina, items.PopustOdstotek, items.RednaCena, items.OdprodajnaCena,
         CAST(ISNULL(flag.IsSet, 0) AS bit) AS Razstavni,
         shops.Strani AS SpletneStrani,
         CAST(CASE WHEN items.IsActive = 1 AND items.Rn = 1 AND ISNULL(items.Kolicina, 0) > 0 THEN 1 ELSE 0 END AS bit) AS VKatalogu,
         items.ImportiranoUtc, CAST(ISNULL(items.IsActive, 0) AS bit) AS IsActive, items.EndedUtc, items.EndedBy,
         items.IzvornaDatoteka
  FROM canon.Product product
  LEFT JOIN Items items ON items.ProductId = product.ProductId
  LEFT JOIN pim.ProductFlag flag ON flag.ProductId = product.ProductId AND flag.FlagCode = N'RAZSTAVNI_EKSPONAT'
  LEFT JOIN canon.ProductText title ON title.ProductId = product.ProductId AND title.TextType = N'TITLE_ERP' AND title.Lang = N'sl'
  OUTER APPLY (
    SELECT STRING_AGG(shop.WebShopCode, N'|') WITHIN GROUP (ORDER BY shop.WebShopCode) AS Strani
    FROM pim.ProductWebShop shop WHERE shop.ProductId = product.ProductId AND shop.IsPublished = 1
  ) shops
  WHERE product.OrganizationId = @OrganizationId
    AND (items.ClearanceItemId IS NOT NULL
         OR (flag.IsSet = 1 AND NOT EXISTS (SELECT 1 FROM pim.ClearanceItem active WHERE active.ProductId = product.ProductId AND active.IsActive = 1)))
  ORDER BY CASE WHEN items.ClearanceItemId IS NULL THEN 1 ELSE 0 END, ISNULL(items.IsActive, 0) DESC, product.ItemID, items.Vir;
END;
GO

INSERT sec.RolePermission (RoleId, PermissionKey)
SELECT roleValue.RoleId, N'view.products.clearance'
FROM sec.Role AS roleValue
WHERE roleValue.RoleCode IN (N'ADMIN', N'CATALOG_EDITOR', N'COMMERCIAL')
  AND NOT EXISTS (SELECT 1 FROM sec.RolePermission AS existing
                  WHERE existing.RoleId = roleValue.RoleId AND existing.PermissionKey = N'view.products.clearance');
GO

IF OBJECT_ID(N'pim.SetShowcaseFlags', N'P') IS NULL THROW 52910, N'275: pim.SetShowcaseFlags manjka.', 1;
IF OBJECT_ID(N'pim.SaveClearanceItem', N'P') IS NULL THROW 52911, N'275: pim.SaveClearanceItem manjka.', 1;
IF OBJECT_ID(N'intranet.GetClearanceOverview', N'P') IS NULL THROW 52912, N'275: intranet.GetClearanceOverview manjka.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'pim.SaveClearanceItems')) NOT LIKE N'%razstavni%' THROW 52913, N'275: pim.SaveClearanceItems ne bere razstavnega eksponata.', 1;
GO
