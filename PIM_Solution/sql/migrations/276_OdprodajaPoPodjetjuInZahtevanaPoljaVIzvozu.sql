/* 276: Uvoz odprodaje po podjetju, brez podvojenih šifer; rumene glave v izvozu izdelkov.

   Testiranje 2026-09-24 (docs/S_popusti/NAPAKE.md, A1, A2, A4, E1):

   A1  pim.SaveClearanceItems je zaključeval vrstice istega vira v VSEH podjetjih: pim.ClearanceItem
       nima OrganizationId, cilj MERGE pa je bil cela tabela, omejena samo z Vir. Uvoz seznama
       »Azzardo« v IQLighting je zaključil odprodajo »Azzardo« v Vidadria. Cilj je zdaj omejen na
       vrstice artiklov tega podjetja.
   A2  Ista šifra dvakrat v datoteki je podrla cel uvoz (UQ_ClearanceItem_ProductVir). Upošteva se
       prva vrstica šifre (tako kot pri delovnem listu izdelkov); predogled to pove.
   A4  Uvoz iz Excela ni preverjal popusta 0–100 (ročni vnos 275 ga je). Vrstica izven meja ustavi
       uvoz z berljivim sporočilom in seznamom šifer.
   E1  intranet.GetProductExportSheet (127) je zahtevana polja iskal prek out.ExportProfile, vsi
       validacijski profili pa imajo od prenove ExportProfileId = NULL in sami nosijo BlocksErp /
       BlocksWeb. JOIN je izločil vse zahteve: v zvezku ni bilo nobene rumene glave in rdeče celice.
       Upoštevajo se zahteve, ki veljajo za vsak izdelek (brez kategorije in brez porekla); zahteva
       samo za kategorijo ali poreklo bi obarvala celice izdelkov, za katere ne velja.
   D2  intranet.GetProductWorkbook je vrednosti atributa (vec jezikov v eni celici) zdruzeval z
       STRING_AGG ... ORDER BY Value; v kolaciji brez razlikovanja velikih crk sta »Satine Chocolate« (en)
       in »Satine chocolate« (sl) enaka, vrstni red je bil nakljucen - nespremenjena datoteka je ob
       uvozu pokazala spremembo. Dodan je binarni drugi kljuc razvrscanja. Isti popravek E1 velja
       za rumene glave delovnega lista (6. rezultat te procedure). */
SET XACT_ABORT ON;
GO

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

  DECLARE @Parsed TABLE (
    Ordinal int NOT NULL,
    Sifra nvarchar(100) NOT NULL,
    ProductId bigint NULL,
    Kolicina decimal(19,4) NULL,
    RednaCena decimal(19,4) NULL,
    PopustOdstotek decimal(19,4) NULL,
    OdprodajnaCena decimal(19,4) NULL,
    Razstavni bit NULL
  );
  INSERT @Parsed (Ordinal, Sifra, ProductId, Kolicina, RednaCena, PopustOdstotek, OdprodajnaCena, Razstavni)
  SELECT CONVERT(int, item.[key]), LTRIM(RTRIM(parsed.sifra)), product.ProductId,
         parsed.kolicina, parsed.rednaCena, parsed.popustOdstotek, parsed.odprodajnaCena, parsed.razstavni
  FROM OPENJSON(@ItemsJson) AS item
  CROSS APPLY OPENJSON(item.value)
  WITH (
    sifra nvarchar(100) N'$.sifra',
    kolicina decimal(19,4) N'$.kolicina',
    rednaCena decimal(19,4) N'$.rednaCena',
    popustOdstotek decimal(19,4) N'$.popustOdstotek',
    odprodajnaCena decimal(19,4) N'$.odprodajnaCena',
    razstavni bit N'$.razstavni'
  ) AS parsed
  LEFT JOIN canon.Product product ON product.OrganizationId = @OrganizationId AND product.ItemID = LTRIM(RTRIM(parsed.sifra))
  WHERE NULLIF(LTRIM(RTRIM(parsed.sifra)), N'') IS NOT NULL;

  DECLARE @OutOfRange nvarchar(max) = (
    /* Brez znaka odstotka: THROW ga razume kot oblikovni znak in vrne prazno sporočilo. */
    SELECT STRING_AGG(CONVERT(nvarchar(max), CONCAT(Sifra, N' (', CONVERT(nvarchar(40), CONVERT(decimal(19,2), PopustOdstotek)), N')')), N', ')
    FROM @Parsed WHERE PopustOdstotek < 0 OR PopustOdstotek > 100);
  IF @OutOfRange IS NOT NULL
  BEGIN
    DECLARE @RangeMessage nvarchar(2048) = LEFT(CONCAT(N'Popust mora biti med 0 in 100 (odstotkov): ', @OutOfRange), 2048);
    THROW 52604, @RangeMessage, 1;
  END;

  /* Ena vrstica na artikel: prva v datoteki. Neujemajoče šifre ostanejo po ena, za poročilo. */
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
  SELECT Sifra, ProductId, Kolicina, RednaCena, PopustOdstotek, OdprodajnaCena, Razstavni
  FROM (
    SELECT parsed.*, ROW_NUMBER() OVER (
      PARTITION BY ISNULL(CONVERT(nvarchar(100), parsed.ProductId), N'#' + parsed.Sifra) ORDER BY parsed.Ordinal) AS Rn
    FROM @Parsed AS parsed
  ) AS ranked
  WHERE ranked.Rn = 1;

  DECLARE @Ean TABLE (ProductId bigint PRIMARY KEY, Ean nvarchar(100));
  INSERT @Ean (ProductId, Ean) SELECT ProductId, EAN FROM canon.Product WHERE ProductId IN (SELECT ProductId FROM @Rows WHERE ProductId IS NOT NULL);

  DECLARE @Merged TABLE (ProductId bigint, WasActive bit, IsActive bit);

  BEGIN TRANSACTION;
  BEGIN TRY
    /* Cilj: samo vrstice tega vira pri artiklih TEGA podjetja (A1). */
    WITH target AS (
      SELECT item.*
      FROM pim.ClearanceItem AS item
      WHERE item.Vir = @Vir
        AND EXISTS (SELECT 1 FROM canon.Product AS owner
                    WHERE owner.ProductId = item.ProductId AND owner.OrganizationId = @OrganizationId)
    )
    MERGE target
    USING (SELECT * FROM @Rows WHERE ProductId IS NOT NULL) AS source
      ON target.ProductId = source.ProductId
    WHEN MATCHED THEN UPDATE SET
      Sifra = source.Sifra, Kolicina = source.Kolicina, RednaCena = source.RednaCena,
      PopustOdstotek = source.PopustOdstotek, OdprodajnaCena = source.OdprodajnaCena,
      IsActive = 1, EndedUtc = NULL, EndedBy = NULL,
      IzvornaDatoteka = @IzvornaDatoteka, ImportiranoUtc = SYSUTCDATETIME()
    WHEN NOT MATCHED BY TARGET THEN INSERT
      (ProductId, Vir, Sifra, Ean, NaSvetila, NaVidelektro, Kolicina, RednaCena, PopustOdstotek, OdprodajnaCena, IzvornaDatoteka)
      VALUES (source.ProductId, @Vir, source.Sifra, (SELECT Ean FROM @Ean WHERE ProductId = source.ProductId), 0, 0,
              source.Kolicina, source.RednaCena, source.PopustOdstotek, source.OdprodajnaCena, @IzvornaDatoteka)
    WHEN NOT MATCHED BY SOURCE AND target.IsActive = 1 THEN UPDATE SET
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

/* Za predogled uvoza (A5): koliko aktivnih vrstic vira v tem podjetju bi uvoz zaključil. */
CREATE OR ALTER PROCEDURE intranet.GetClearanceItemsToEnd
  @OrganizationId int,
  @Vir nvarchar(100),
  @ProductIdsJson nvarchar(max)
AS
BEGIN
  SET NOCOUNT ON;
  SELECT item.Sifra
  FROM pim.ClearanceItem AS item
  JOIN canon.Product AS product ON product.ProductId = item.ProductId AND product.OrganizationId = @OrganizationId
  WHERE item.Vir = @Vir AND item.IsActive = 1
    AND NOT EXISTS (SELECT 1 FROM OPENJSON(@ProductIdsJson) AS kept WHERE TRY_CONVERT(bigint, kept.value) = item.ProductId)
  ORDER BY item.Sifra;
END;
GO

CREATE OR ALTER PROCEDURE intranet.GetProductExportSheet
  @ProductIdsJson nvarchar(max),
  @FieldCodesJson nvarchar(max)
AS
BEGIN
  SET NOCOUNT ON;

  DECLARE @Products TABLE (ProductId bigint NOT NULL PRIMARY KEY);
  INSERT @Products (ProductId)
  SELECT DISTINCT CONVERT(bigint, parsed.value) FROM OPENJSON(@ProductIdsJson) AS parsed
  WHERE ISJSON(parsed.value) = 0 AND TRY_CONVERT(bigint, parsed.value) IS NOT NULL;

  DECLARE @Fields TABLE (FieldCode nvarchar(200) NOT NULL PRIMARY KEY);
  INSERT @Fields (FieldCode)
  SELECT DISTINCT CONVERT(nvarchar(200), parsed.value) FROM OPENJSON(@FieldCodesJson) AS parsed
  WHERE ISJSON(parsed.value) = 0 AND NULLIF(LTRIM(RTRIM(parsed.value)), N'') IS NOT NULL;

  /* 1) Vrednosti. Vec vrstic na isto kodo se zdruzi; zvezek ima en stolpec na polje. */
  SELECT
    fieldValue.ProductId,
    fieldValue.FieldCode,
    Value = STRING_AGG(CONVERT(nvarchar(max), fieldValue.Value), N'; ') WITHIN GROUP (ORDER BY fieldValue.Value),
    ValueCount = COUNT(*)
  FROM canon.FieldValue AS fieldValue
  INNER JOIN @Products AS product ON product.ProductId = fieldValue.ProductId
  INNER JOIN @Fields AS field ON field.FieldCode = fieldValue.FieldCode
  WHERE fieldValue.Value IS NOT NULL
  GROUP BY fieldValue.ProductId, fieldValue.FieldCode;

  /* 2) Register zahtevanih polj (276): kanal nosi validacijski profil sam (BlocksErp/BlocksWeb).
     Samo zahteve, ki veljajo za vsak izdelek — brez kategorije in brez porekla. */
  SELECT
    requirement.FieldCode,
    BlocksErp = CONVERT(bit, MAX(CONVERT(int, validationProfile.BlocksErp))),
    BlocksWeb = CONVERT(bit, MAX(CONVERT(int, validationProfile.BlocksWeb))),
    Severity = MIN(requirement.Severity),
    Profiles = STRING_AGG(validationProfile.ProfileCode, N', ') WITHIN GROUP (ORDER BY validationProfile.ProfileCode)
  FROM val.FieldRequirement AS requirement
  INNER JOIN val.ValidationProfile AS validationProfile
    ON validationProfile.ValidationProfileId = requirement.ValidationProfileId
  WHERE requirement.IsActive = 1 AND requirement.IsRequired = 1 AND validationProfile.IsActive = 1
    AND requirement.CategoryCode IS NULL AND requirement.OriginScope IS NULL
    AND validationProfile.OriginScope IS NULL
  GROUP BY requirement.FieldCode;
END;
GO

CREATE OR ALTER PROCEDURE intranet.GetProductWorkbook
  @ProductIdsJson nvarchar(max),
  @FieldCodesJson nvarchar(max),
  @CategoryTreeCode nvarchar(100) = NULL,
  @CategoryCode nvarchar(200) = NULL
AS
BEGIN
  SET NOCOUNT ON;

  DECLARE @Products TABLE (ProductId bigint NOT NULL PRIMARY KEY);
  INSERT @Products (ProductId)
  SELECT DISTINCT CONVERT(bigint, parsed.value) FROM OPENJSON(@ProductIdsJson) AS parsed
  WHERE ISJSON(parsed.value) = 0 AND TRY_CONVERT(bigint, parsed.value) IS NOT NULL;

  DECLARE @VsiIzdelki bit = CASE WHEN EXISTS (SELECT 1 FROM @Products) THEN 0 ELSE 1 END;

  DECLARE @Fields TABLE (FieldCode nvarchar(200) NOT NULL PRIMARY KEY);
  INSERT @Fields (FieldCode)
  SELECT DISTINCT CONVERT(nvarchar(200), parsed.value) FROM OPENJSON(@FieldCodesJson) AS parsed
  WHERE ISJSON(parsed.value) = 0 AND NULLIF(LTRIM(RTRIM(parsed.value)), N'') IS NOT NULL;

  SET @CategoryCode = NULLIF(LTRIM(RTRIM(@CategoryCode)), N'');
  SET @CategoryTreeCode = NULLIF(LTRIM(RTRIM(@CategoryTreeCode)), N'');

  /* 1) Vrednosti polj.
     218: polja se berejo neposredno iz tabel, ne prek pogleda canon.FieldValue: stik pogleda
     (35 vej UNION ALL) s tabelno spremenljivko izdelkov je optimizer izvedel kot polni pregled
     vseh vej za vsako polje - izmerjeno 89 s od 90 s za 2.000 izdelkov. Kode polj in oblika
     vrednosti so DOBESEDNO iste kot v canon.FieldValue (migracija 124); ce se pogled dopolni,
     se dopolni tudi ta seznam. Vsaka veja seka po ProductId in vzame samo zahtevana polja. */
  SELECT vrednost.ProductId, vrednost.FieldCode,
    Value = STRING_AGG(CONVERT(nvarchar(max), vrednost.Value), N' | ') WITHIN GROUP (ORDER BY vrednost.Value, vrednost.Value COLLATE Latin1_General_BIN2)
  FROM
  (
    SELECT polje.ProductId, polje.FieldCode, polje.Value
    FROM @Products AS product
    INNER JOIN canon.Product AS izdelek ON izdelek.ProductId = product.ProductId
    CROSS APPLY
    (VALUES
      (izdelek.ProductId, N'Product.ItemID', NULLIF(izdelek.ItemID, N'')),
      (izdelek.ProductId, N'Product.EAN', NULLIF(izdelek.EAN, N'')),
      (izdelek.ProductId, N'Product.UoM', NULLIF(izdelek.UoM, N'')),
      (izdelek.ProductId, N'Product.Supplier', NULLIF(izdelek.Supplier, N'')),
      (izdelek.ProductId, N'Product.Manufacturer', NULLIF(izdelek.Manufacturer, N'')),
      (izdelek.ProductId, N'Product.AccountingGroup', NULLIF(izdelek.AccountingGroup, N'')),
      (izdelek.ProductId, N'Product.DiscountGroup', NULLIF(izdelek.DiscountGroup, N'')),
      (izdelek.ProductId, N'Product.ItemGroup', NULLIF(izdelek.ItemGroup, N'')),
      (izdelek.ProductId, N'Product.Department', NULLIF(izdelek.Department, N'')),
      (izdelek.ProductId, N'Product.VatRateId', NULLIF(izdelek.VatRateId, N'')),
      (izdelek.ProductId, N'Product.PriceListCode', NULLIF(izdelek.PriceListCode, N'')),
      (izdelek.ProductId, N'Product.HasSeries', CONVERT(nvarchar(10), izdelek.HasSeries)),
      (izdelek.ProductId, N'Product.IsActive', CONVERT(nvarchar(10), izdelek.IsActive)),
      (izdelek.ProductId, N'Product.WebPublish', CONVERT(nvarchar(10), izdelek.WebPublish))
    ) AS polje (ProductId, FieldCode, Value)
    WHERE EXISTS (SELECT 1 FROM @Fields AS field WHERE field.FieldCode = polje.FieldCode)
    UNION ALL
    SELECT polje.ProductId, polje.FieldCode, polje.Value
    FROM @Products AS product
    INNER JOIN canon.ProductCommercial AS komerciala ON komerciala.ProductId = product.ProductId
    CROSS APPLY
    (VALUES
      (komerciala.ProductId, N'ProductCommercial.NetWeight', NULLIF(CONVERT(nvarchar(50), komerciala.NetWeight), N'')),
      (komerciala.ProductId, N'ProductCommercial.GrossWeight', NULLIF(CONVERT(nvarchar(50), komerciala.GrossWeight), N'')),
      (komerciala.ProductId, N'ProductCommercial.CustomsTariff', NULLIF(komerciala.CustomsTariff, N'')),
      (komerciala.ProductId, N'ProductCommercial.CountryOfOrigin', NULLIF(komerciala.CountryOfOrigin, N'')),
      (komerciala.ProductId, N'ProductCommercial.Pak1', NULLIF(CONVERT(nvarchar(50), komerciala.Pak1), N'')),
      (komerciala.ProductId, N'ProductCommercial.Pak2', NULLIF(CONVERT(nvarchar(50), komerciala.Pak2), N'')),
      (komerciala.ProductId, N'ProductCommercial.Volume', NULLIF(CONVERT(nvarchar(50), komerciala.Volume), N'')),
      (komerciala.ProductId, N'ProductCommercial.PackageLength', NULLIF(CONVERT(nvarchar(50), komerciala.PackageLength), N'')),
      (komerciala.ProductId, N'ProductCommercial.PackageWidth', NULLIF(CONVERT(nvarchar(50), komerciala.PackageWidth), N'')),
      (komerciala.ProductId, N'ProductCommercial.PackageHeight', NULLIF(CONVERT(nvarchar(50), komerciala.PackageHeight), N'')),
      (komerciala.ProductId, N'ProductCommercial.DimensionUnit', NULLIF(komerciala.DimensionUnit, N''))
    ) AS polje (ProductId, FieldCode, Value)
    WHERE EXISTS (SELECT 1 FROM @Fields AS field WHERE field.FieldCode = polje.FieldCode)
    UNION ALL
    SELECT besedilo.ProductId, CONCAT(N'ProductText.', besedilo.TextType, N'.', besedilo.Lang), NULLIF(besedilo.Value, N'')
    FROM @Products AS product
    INNER JOIN canon.ProductText AS besedilo ON besedilo.ProductId = product.ProductId
    WHERE EXISTS (SELECT 1 FROM @Fields AS field WHERE field.FieldCode = CONCAT(N'ProductText.', besedilo.TextType, N'.', besedilo.Lang))
    UNION ALL
    SELECT atribut.ProductId, CONCAT(N'ProductAttribute.', atribut.AttributeCode), NULLIF(atribut.Value, N'')
    FROM @Products AS product
    INNER JOIN canon.ProductAttribute AS atribut ON atribut.ProductId = product.ProductId
    WHERE EXISTS (SELECT 1 FROM @Fields AS field WHERE field.FieldCode = CONCAT(N'ProductAttribute.', atribut.AttributeCode))
    UNION ALL
    SELECT atribut.ProductId, CONCAT(N'ProductAttribute.', atribut.AttributeCode, N'.', atribut.LanguageCode), NULLIF(atribut.Value, N'')
    FROM @Products AS product
    INNER JOIN canon.ProductAttribute AS atribut ON atribut.ProductId = product.ProductId
    WHERE atribut.LanguageCode IS NOT NULL
      AND EXISTS (SELECT 1 FROM @Fields AS field WHERE field.FieldCode = CONCAT(N'ProductAttribute.', atribut.AttributeCode, N'.', atribut.LanguageCode))
    UNION ALL
    SELECT kategorija.ProductId, N'ProductCategory.CategoryPath', NULLIF(kategorija.CategoryPath, N'')
    FROM @Products AS product
    INNER JOIN canon.ProductCategory AS kategorija ON kategorija.ProductId = product.ProductId
    WHERE EXISTS (SELECT 1 FROM @Fields AS field WHERE field.FieldCode = N'ProductCategory.CategoryPath')
    UNION ALL
    SELECT medij.ProductId, N'ProductMedia.Url', NULLIF(medij.Url, N'')
    FROM @Products AS product
    INNER JOIN canon.ProductMedia AS medij ON medij.ProductId = product.ProductId
    WHERE EXISTS (SELECT 1 FROM @Fields AS field WHERE field.FieldCode = N'ProductMedia.Url')
    UNION ALL
    SELECT cena.ProductId, N'ProductPrice.VatRate', CONVERT(nvarchar(50), cena.VatRate)
    FROM @Products AS product
    INNER JOIN canon.ProductPrice AS cena ON cena.ProductId = product.ProductId
    WHERE cena.IsActive = 1
      AND EXISTS (SELECT 1 FROM @Fields AS field WHERE field.FieldCode = N'ProductPrice.VatRate')
    UNION ALL
    SELECT cena.ProductId, N'ProductPrice.Gross', CONVERT(nvarchar(50), cena.Net * (1 + cena.VatRate / 100))
    FROM @Products AS product
    INNER JOIN canon.ProductPrice AS cena ON cena.ProductId = product.ProductId
    WHERE cena.IsActive = 1 AND cena.Net * (1 + cena.VatRate / 100) > 0
      AND EXISTS (SELECT 1 FROM @Fields AS field WHERE field.FieldCode = N'ProductPrice.Gross')
  ) AS vrednost
  WHERE vrednost.Value IS NOT NULL
  GROUP BY vrednost.ProductId, vrednost.FieldCode;

  /* 2) Kategorije po spletnih straneh. */
  SELECT
    category.ProductId,
    category.WebSite,
    CategoryPaths = STRING_AGG(CONVERT(nvarchar(max), category.CategoryPath), N' | ') WITHIN GROUP (ORDER BY category.CategoryPath, category.CategoryPath COLLATE Latin1_General_BIN2)
  FROM canon.ProductCategory AS category
  INNER JOIN @Products AS product ON product.ProductId = category.ProductId
  GROUP BY category.ProductId, category.WebSite;

  /* 3) Atributi. */
  SELECT
    attributeValue.ProductId,
    attributeValue.AttributeCode,
    Value = STRING_AGG(CONVERT(nvarchar(max), attributeValue.Value), N' | ') WITHIN GROUP (ORDER BY attributeValue.Value, attributeValue.Value COLLATE Latin1_General_BIN2)
  FROM canon.ProductAttribute AS attributeValue
  INNER JOIN @Products AS product ON product.ProductId = attributeValue.ProductId
  WHERE attributeValue.Value IS NOT NULL
  GROUP BY attributeValue.ProductId, attributeValue.AttributeCode;

  /* 4) Mediji - surovo, brez STRING_AGG in brez razvrstitve slika/dokument. C# razvrsti z
        MediaKindPolicy.Classify (isto pravilo kot stran Mediji) in sele nato zdruzi v celico. */
  SELECT media.ProductId, media.Url, media.Role, media.SortOrder
  FROM canon.ProductMedia AS media
  INNER JOIN @Products AS product ON product.ProductId = media.ProductId
  UNION ALL
  SELECT document.ProductId, document.Url, document.Role, document.SortOrder
  FROM canon.ProductDocument AS document
  INNER JOIN @Products AS product ON product.ProductId = document.ProductId
  ORDER BY ProductId, SortOrder;

  /*
    5) Sifrant atributov za naslove stolpcev.

    Trije viri, zdruzeni po slovenskem imenu, ker je to kljuc v canon.ProductAttribute:
      NABOR    - ucinkoviti nabor kategorije (dedovanje da canon.CategoryAttributeEffective);
                 kadar je kategorija dana, samo zanjo, sicer za vse kategorije danih izdelkov,
      VREDNOST - kar dani izdelki ze imajo zapisano,
      ZAHTEVA  - kar zahteva validacija.

    Prazen seznam izdelkov in brez kategorije pomeni ves sifrant: uvoz ne ve vnaprej, katere
    izdelke datoteka nosi, in mora prepoznati vsak stolpec, ki ga je izvoz izpisal.
  */
  DECLARE @Kategorije TABLE (CategoryTreeCode nvarchar(100) NOT NULL, CategoryCode nvarchar(200) NOT NULL,
    PRIMARY KEY (CategoryTreeCode, CategoryCode));

  IF @CategoryCode IS NOT NULL
  BEGIN
    INSERT @Kategorije (CategoryTreeCode, CategoryCode)
    SELECT DISTINCT node.CategoryTreeCode, node.CategoryCode
    FROM canon.Category AS node
    WHERE node.CategoryCode = @CategoryCode
      AND (@CategoryTreeCode IS NULL OR node.CategoryTreeCode = @CategoryTreeCode);
  END
  ELSE IF @VsiIzdelki = 0
  BEGIN
    INSERT @Kategorije (CategoryTreeCode, CategoryCode)
    SELECT DISTINCT node.CategoryTreeCode, node.CategoryCode
    FROM canon.ProductCategory AS productCategory
    INNER JOIN @Products AS product ON product.ProductId = productCategory.ProductId
    INNER JOIN canon.WebSite AS site ON site.WebSiteCode = productCategory.WebSite
    INNER JOIN canon.Category AS node
      ON node.CategoryTreeCode = site.CategoryTreeCode AND node.CategoryPath = productCategory.CategoryPath;
  END

  ;WITH nabor AS
  (
    SELECT effective.AttributeCode, effective.Level, MinSort = MIN(effective.SortOrder)
    FROM @Kategorije AS kategorija
    CROSS APPLY canon.CategoryAttributeEffective(kategorija.CategoryTreeCode, kategorija.CategoryCode) AS effective
    WHERE effective.Level <> N'EXCLUDED'
    GROUP BY effective.AttributeCode, effective.Level
  ),
  imena AS
  (
    SELECT
      AttributeName = COALESCE(translation.Name, nabor.AttributeCode),
      /* Ista koda v dveh kategorijah z razlicno ravnijo: obvelja strozja. REQUIRED je po
         abecedi za RECOMMENDED, zato MAX in ne MIN. */
      Level = MAX(nabor.Level),
      SortOrder = MIN(nabor.MinSort)
    FROM nabor
    LEFT JOIN canon.AttributeTranslation AS translation
      ON translation.AttributeCode = nabor.AttributeCode AND translation.LanguageCode = N'sl'
    GROUP BY COALESCE(translation.Name, nabor.AttributeCode)
  ),
  vsi AS
  (
    SELECT AttributeName, IsRequired = 0, InSet = 1, SetLevel = Level, SortOrder FROM imena
    UNION ALL
    SELECT DISTINCT attributeValue.AttributeCode, 0, 0, NULL, 1000
    FROM canon.ProductAttribute AS attributeValue
    WHERE (@VsiIzdelki = 1 AND @CategoryCode IS NULL)
       OR EXISTS (SELECT 1 FROM @Products AS product WHERE product.ProductId = attributeValue.ProductId)
    UNION ALL
    SELECT DISTINCT SUBSTRING(requirement.FieldCode, 18, 200), 1, 0, NULL, 0
    FROM val.FieldRequirement AS requirement
    INNER JOIN val.ValidationProfile AS validationProfile
      ON validationProfile.ValidationProfileId = requirement.ValidationProfileId
    WHERE requirement.IsActive = 1 AND requirement.IsRequired = 1 AND validationProfile.IsActive = 1
      AND requirement.FieldCode LIKE N'ProductAttribute.%'
      AND CHARINDEX(N'.', SUBSTRING(requirement.FieldCode, 18, 200)) = 0
  )
  SELECT
    AttributeCode = vsi.AttributeName,
    Name = vsi.AttributeName,
    IsRequired = CONVERT(bit, MAX(vsi.IsRequired)),
    InSet = CONVERT(bit, MAX(vsi.InSet)),
    SetLevel = MAX(vsi.SetLevel),
    SortOrder = MIN(vsi.SortOrder)
  FROM vsi
  WHERE NULLIF(LTRIM(RTRIM(vsi.AttributeName)), N'') IS NOT NULL
  GROUP BY vsi.AttributeName;

  /* 6) Register zahtevanih polj (276): kanal nosi validacijski profil sam; samo zahteve za vsak izdelek. */
  SELECT
    requirement.FieldCode,
    BlocksErp = CONVERT(bit, MAX(CONVERT(int, validationProfile.BlocksErp))),
    BlocksWeb = CONVERT(bit, MAX(CONVERT(int, validationProfile.BlocksWeb)))
  FROM val.FieldRequirement AS requirement
  INNER JOIN val.ValidationProfile AS validationProfile
    ON validationProfile.ValidationProfileId = requirement.ValidationProfileId
  WHERE requirement.IsActive = 1 AND requirement.IsRequired = 1 AND validationProfile.IsActive = 1
    AND requirement.CategoryCode IS NULL AND requirement.OriginScope IS NULL
    AND validationProfile.OriginScope IS NULL
  GROUP BY requirement.FieldCode;
END;
GO

IF OBJECT_DEFINITION(OBJECT_ID(N'pim.SaveClearanceItems')) NOT LIKE N'%owner.OrganizationId = @OrganizationId%'
  THROW 52920, N'276: pim.SaveClearanceItems ni omejen na podjetje.', 1;
IF OBJECT_ID(N'intranet.GetClearanceItemsToEnd', N'P') IS NULL
  THROW 52921, N'276: intranet.GetClearanceItemsToEnd manjka.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'intranet.GetProductExportSheet')) LIKE N'%out.ExportProfile%'
  THROW 52922, N'276: intranet.GetProductExportSheet še bere out.ExportProfile.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'intranet.GetProductWorkbook')) LIKE N'%out.ExportProfile%'
  THROW 52923, N'276: intranet.GetProductWorkbook še bere out.ExportProfile.', 1;
GO
