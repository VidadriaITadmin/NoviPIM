/*
  142 — spletni CSV (katalog in stranke) nastane iz tabel, ne vec iz datoteke na disku.

  Zakaj: kaj gre v Magento, je doslej sestavljala koda. MagentoExportCommand je imel osem
  poizvedb nad pim.* in b2b.*, iz njih zlozil slovar kanonicnih vrednosti in zapisal
  magento-products.csv ter magento-customers.csv v mapo. Intranet je nato bral tisti dve
  datoteki z diska (WebExportFileService). Kdor ni imel dostopa do mape, ni videl nicesar,
  vsebine pa ni bilo mogoce niti filtrirati niti pogledati brez zagona workerja.

  Izvoz na zahtevo iz baze sicer ze obstaja od migracije 139 (intranet.GetWebExportRows),
  a bere izkljucno canon.FieldValue. Magento profil ima 213 stolpcev in izmerjeno
  2026-09-02 nad razvojno bazo PIM jih 186 od 191 preslikanih v canon.FieldValue nima
  nobene vrstice — kanonicni sloj uporablja druge kode (ProductCommercial.GrossWeight,
  ProductText.WEB_TITLE.sl, ProductAttribute.<ime>), Magento register pa Product.GrossWeight,
  Product.WebTitleSl in Attr.<koda>. Predogled bi bil torej skoraj prazna datoteka.
  Profile strank je 139 celo izrecno zavrnila.

  Ta migracija zato naredi troje:

    1. Register pove, iz katerega vira profil dobi vrednosti — out.ExportProfile
       .ValueSourceCode: CANON (kanonicni sloj, kot doslej), PIM_PRODUCT (izdelki iz
       pim.*) in PIM_CUSTOMER (stranke iz b2b.* in pim.CustomerWebProfile). Nov kanal
       je s tem se vedno vrstica v bazi in ne veja v proceduri.

    2. out.GetExportRows prenese poizvedbe iz MagentoExportCommand v bazo in jih zlozi
       v obliko registra: glave, vrstni red in kanonicne kode pridejo iz out.ExportColumn.
       Ista procedura streze predogled (stranicenje) in pretocni prenos cele datoteke
       (@Take = 0). Od tu naprej je en sam vir resnice: intranet in worker bereta isto
       proceduro, zato datoteka na spletu in predogled v intranetu ne moreta razhajati.

    3. Trije stolpci profila MAGENTO_CUSTOMERS (E-posta, Tel. stevilko, Uporabniki) so
       bili brez kanonicne kode, ker vira zanje ni bilo. Migracija 140 je vir naredila
       (pim.CustomerContact), zato ga tu se povezemo; brez tega bi trije obvezni stolpci
       izvoza strank ostali prazni tudi potem, ko so podatki vpisani.

  Kaj ta migracija NAMENOMA NE spremeni:
    - Vsebine datoteke, ki danes odide. Izvoz za Magento je doslej jemal vse izdelke
      podjetja brez filtra objave, zato worker klice proceduro z @OnlyPublished = 0;
      filter objave (canon.Product.WebPublish) obstaja samo za predogled v intranetu.
    - Kod stolpcev in glav. Predloga Magenta je zunanja pogodba in ostane v registru
      tocno taka, kot je bila po migracijah 045, 050-053 in 124.

  Ena razlika je namerna in je izboljsava: kadar ima ista lastnost slovensko in angleško
  vrstico, je stolpec brez jezikovne pripone (Attr.<koda>) v C# dobil vrednost tiste, ki
  jo je nacrt poizvedbe prebral zadnjo — torej ni bila ponovljiva. Tu zmaga zadnji zapisani
  zapis (najvisji PimProductAttributeId): isto pravilo, a vedno isti rezultat.

  Migrator ne pozna locila GO; procedure in funkcija so v EXEC(N'...') kot v 020, 081, 129,
  139 in 140.
*/

SET XACT_ABORT ON;

/* --- 1) Register pove, iz katerega vira profil dobi vrednosti --------------------------- */

IF COL_LENGTH(N'out.ExportProfile', N'ValueSourceCode') IS NULL
BEGIN
  ALTER TABLE out.ExportProfile
    ADD ValueSourceCode nvarchar(40) NOT NULL
      CONSTRAINT DF_ExportProfile_ValueSourceCode DEFAULT (N'CANON');
END;

/* Stolpec nastane v tej isti seriji, zato omejitve in posodobitve nad njim ne morejo biti
   preveden del iste serije; gredo skozi EXEC. */
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_ExportProfile_ValueSourceCode')
BEGIN
  EXEC(N'
  ALTER TABLE out.ExportProfile
    ADD CONSTRAINT CK_ExportProfile_ValueSourceCode
      CHECK (ValueSourceCode IN (N''CANON'', N''PIM_PRODUCT'', N''PIM_CUSTOMER''));
  ');
END;

EXEC(N'
UPDATE out.ExportProfile SET ValueSourceCode = N''PIM_PRODUCT'', UpdatedUtc = SYSUTCDATETIME()
WHERE ProfileCode = N''MAGENTO_PRODUCTS'' AND ValueSourceCode <> N''PIM_PRODUCT'';

UPDATE out.ExportProfile SET ValueSourceCode = N''PIM_CUSTOMER'', UpdatedUtc = SYSUTCDATETIME()
WHERE ProfileCode = N''MAGENTO_CUSTOMERS'' AND ValueSourceCode <> N''PIM_CUSTOMER'';
');

/* --- 2) Kontakti stranke dobijo svoje stolpce v profilu MAGENTO_CUSTOMERS --------------- */

/* Vir je pim.CustomerContact iz migracije 140 — rocni vnos, dokler zajema kontaktov ni.
   Posodobimo samo stolpce, ki so danes brez kanonicne kode: rocno spremenjen register
   se ne prepise. */
UPDATE exportColumn
SET CanonicalFieldCode = mapping.FieldCode
FROM out.ExportColumn AS exportColumn
INNER JOIN out.ExportProfile AS profile ON profile.ExportProfileId = exportColumn.ExportProfileId
INNER JOIN (VALUES
  (N'CUC03', N'Customer.Email'),
  (N'CUC04', N'Customer.Phone'),
  (N'CUC05', N'Customer.Persons')
) AS mapping (ColumnCode, FieldCode) ON mapping.ColumnCode = exportColumn.ColumnCode
WHERE profile.ProfileCode = N'MAGENTO_CUSTOMERS'
  AND NULLIF(exportColumn.CanonicalFieldCode, N'') IS NULL;

/* --- 3) Zapis stevila, enak kot v C# --------------------------------------------------- */

EXEC(N'CREATE OR ALTER FUNCTION out.MagentoNumber(@Value decimal(38,6))
RETURNS nvarchar(50)
WITH SCHEMABINDING
AS
BEGIN
  /* Zapis stevila v izvozu je pogodba do Magenta, ne stvar jezika: enako kot
     ToString("0.####") v C# — najvec stiri decimalke, brez koncnih nicel, brez
     locila tisocic in vedno s piko. Brez tega bi ista cena odsla kot "12,3400"
     ali "12.3400", odvisno od jezikovnih nastavitev seje, in Magento bi jo
     zavrnil ali prebral napacno.

     Postopek: CAST na decimal(38,4) da zapis s stirimi decimalkami ("12.3400"),
     obrat + PATINDEX odrezeta koncne nicle, zadnji CASE se piko, ce je ostala
     sama ("12." -> "12"). Vrednost 0 se tako zapise kot "0". */
  DECLARE @Fixed nvarchar(50) = CONVERT(nvarchar(50), CAST(ROUND(ISNULL(@Value, 0), 4) AS decimal(38,4)));
  DECLARE @Trimmed nvarchar(50) = REVERSE(SUBSTRING(REVERSE(@Fixed), PATINDEX(N''%[^0]%'', REVERSE(@Fixed)), 50));
  RETURN CASE
    WHEN @Value IS NULL THEN NULL
    WHEN RIGHT(@Trimmed, 1) = N''.'' THEN LEFT(@Trimmed, LEN(@Trimmed) - 1)
    ELSE @Trimmed
  END;
END');

/* --- 4) Izvoz na zahtevo iz tabel ------------------------------------------------------- */

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

  DECLARE @EntityType nvarchar(200), @ProfileCode nvarchar(200), @ValueSource nvarchar(40);
  SELECT @EntityType = EntityType, @ProfileCode = ProfileCode, @ValueSource = ValueSourceCode
  FROM out.ExportProfile
  WHERE ExportProfileId = @ExportProfileId AND IsActive = 1;

  IF @ProfileCode IS NULL THROW 52973, N''Aktivni izvozni profil ne obstaja.'', 1;
  IF NOT EXISTS (SELECT 1 FROM out.ExportColumn WHERE ExportProfileId = @ExportProfileId AND IsActive = 1)
    THROW 52974, N''Izvozni profil nima aktivnih stolpcev.'', 1;

  SET @WebSite = NULLIF(LTRIM(RTRIM(@WebSite)), N'''');
  SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'''');
  DECLARE @SearchLike nvarchar(410) = CASE WHEN @Search IS NULL THEN NULL ELSE
    N''%'' + REPLACE(REPLACE(REPLACE(@Search, N''['', N''[[]''), N''%'', N''[%]''), N''_'', N''[_]'') + N''%'' END;

  /* @Take = 0 pomeni "brez stranicenja" in je namenjen pretocnemu prenosu cele datoteke.
     OFFSET/FETCH zahteva stevilo, zato je meja izrecna in ne skrita v dinamicnem nizu. */
  DECLARE @Fetch bigint = CASE WHEN @Take = 0 THEN 2147483647 ELSE @Take END;

  /* Kljuc vrstice je poslovni kljuc (sifra artikla oziroma sifra stranke), ne notranji ID:
     po njem se izvoz razvrsca in po njem se vrednosti sestavijo nazaj v eno vrstico. */
  /* COLLATE DATABASE_DEFAULT ni okras: zacasna tabela privzame ureditev tempdb, ta pa je
     na tem strezniku Slovenian_CI_AS, medtem ko je baza PIM SQL_Latin1_General_CP1_CI_AS.
     Brez izrecne ureditve vsak stik zacasne tabele s tabelo baze pade z napako 468. */
  CREATE TABLE #Page
    (RowKey nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY, EntityId bigint NOT NULL);
  CREATE TABLE #Value
    (RowKey nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
     FieldCode nvarchar(450) COLLATE DATABASE_DEFAULT NOT NULL,
     Value nvarchar(max) COLLATE DATABASE_DEFAULT NULL);

  /* ============================================================================
     A) KANONICNI VIR — profili, katerih stolpci berejo canon.FieldValue.
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

    /* Vec vrednosti istega polja zdruzi " | " — tako je bilo od migracije 139 in
       tako je predogled v intranetu ze bral. */
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
     B) IZDELKI ZA MAGENTO — vir je sloj pim.*, ne kanonicni sloj.
     Poizvedbe so prenesene iz MagentoExportCommand.LoadProductRowsAsync; kar je
     bilo v C# sestavljanje slovarja, je tu vrstica v #Value.
     ============================================================================ */
  ELSE IF @ValueSource = N''PIM_PRODUCT''
  BEGIN
    /* Objava: pim.Product zastavice objave nima, ima jo canon.Product. Izvoz za
       Magento je doslej jemal vse izdelke podjetja, zato je @OnlyPublished = 0
       pot, ki ohranja obstojeco datoteko; filter obstaja za predogled v intranetu. */
    SELECT @TotalCount = COUNT(*)
    FROM pim.Product AS product
    WHERE product.OrganizationId = @OrganizationId
      AND (@OnlyPublished = 0 OR EXISTS
        (SELECT 1 FROM canon.Product AS canonProduct
         WHERE canonProduct.OrganizationId = product.OrganizationId
           AND canonProduct.ItemID = product.ItemID AND canonProduct.WebPublish = 1))
      AND (@WebSite IS NULL OR EXISTS
        (SELECT 1 FROM pim.ProductCategory AS category
         WHERE category.PimProductId = product.PimProductId AND category.WebSite = @WebSite))
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
      AND (@OnlyPublished = 0 OR EXISTS
        (SELECT 1 FROM canon.Product AS canonProduct
         WHERE canonProduct.OrganizationId = product.OrganizationId
           AND canonProduct.ItemID = product.ItemID AND canonProduct.WebPublish = 1))
      AND (@WebSite IS NULL OR EXISTS
        (SELECT 1 FROM pim.ProductCategory AS category
         WHERE category.PimProductId = product.PimProductId AND category.WebSite = @WebSite))
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
      /* IsActive = 1: izklopljena akcija v katalogu se ne sme izvoziti kot veljaven popust. */
      LEFT JOIN pim.PackagingDiscountCatalog AS discountCatalog
        ON discountCatalog.DiscountCode = packaging.DiscountCode AND discountCatalog.IsActive = 1
      /* Katera sifra cenika je "Cena B2B", pove out.ExportPriceList za to podjetje (migracija 083).
         ValidFrom <= zdaj prepreci, da bi vnaprej pripravljena cena odsla, preden zacne veljati. */
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
      /* Stopnja DDV je last izdelka in ne cenika; ce izdelek nima ne B2B ne B2C cene,
         jo vzamemo iz katerekoli veljavne cene, da stolpec ne ostane prazen. */
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
        /* pim.Product.Name je ERP naziv. V spletni stolpec ne gre: ERP naziv in spletni
           naziv sta razlicna (odlocitev uporabnika 2026-08-23). */
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
      /* Kanonicni sloj pise PRIMARY, starejse vrstice Primary, Magento pravi MAIN;
         primerjava je zato neobcutljiva na velikost crk in sprejme oba izraza. */
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

    /* --- B4) Spletna mesta in kategorije --- */
    CREATE TABLE #Category
      (RowKey nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
       WebSite nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
       CategoryPath nvarchar(2000) COLLATE DATABASE_DEFAULT NOT NULL);

    INSERT #Category (RowKey, WebSite, CategoryPath)
    SELECT page.RowKey, category.WebSite, category.CategoryPath
    FROM #Page AS page
    INNER JOIN pim.ProductCategory AS category ON category.PimProductId = page.EntityId;

    INSERT #Value (RowKey, FieldCode, Value)
    SELECT site.RowKey, N''Product.WebSites'',
      STRING_AGG(CONVERT(nvarchar(max), site.WebSite), N''|'') WITHIN GROUP (ORDER BY site.WebSite)
    FROM (SELECT DISTINCT RowKey, WebSite FROM #Category) AS site
    GROUP BY site.RowKey;

    /* Katera spletna stran gre v kateri stolpec, pove register canon.WebSite, ne koda.
       Dve strani lahko kazeta v isti stolpec; takrat se poti zdruzijo v en seznam,
       urejen po strani in nato po poti — enako, kot jih je zlagal C#. */
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

    /* Stolpec brez jezikovne pripone: isto lastnost lahko nosita slovenska in angleska
       vrstica. C# je pisal v slovar v vrstnem redu branja in je zmagala zadnja prebrana,
       kar je bilo odvisno od nacrta poizvedbe. Tu zmaga zadnji zapisan zapis (najvisji ID)
       — enako pravilo, a ponovljivo. */
    INSERT #Value (RowKey, FieldCode, Value)
    SELECT picked.RowKey, N''Attr.'' + picked.AttributeCode, picked.Value
    FROM
    (
      SELECT RowKey, AttributeCode, Value,
        ROW_NUMBER() OVER (PARTITION BY RowKey, AttributeCode ORDER BY AttributeId DESC) AS PickRank
      FROM #Attribute
    ) AS picked
    WHERE picked.PickRank = 1;

    /* Do migracije 124 je bil jezik del imena lastnosti in glava v datoteki se vedno je:
       stolpec se imenuje "Prevladujoc material SLO", ker je to pogodba do Magenta. */
    INSERT #Value (RowKey, FieldCode, Value)
    SELECT RowKey,
      N''Attr.'' + AttributeCode + N'' '' + CASE LanguageCode WHEN N''sl'' THEN N''SLO'' ELSE N''ANG'' END,
      Value
    FROM #Attribute
    WHERE LanguageCode IN (N''sl'', N''en'');
  END

  /* ============================================================================
     C) STRANKE ZA MAGENTO — preneseno iz MagentoExportCommand.LoadCustomerRowsAsync.
     ============================================================================ */
  ELSE IF @ValueSource = N''PIM_CUSTOMER''
  BEGIN
    /* Spletni profil je pogoj, ne filter: stranka brez WebEnabled na splet ne sodi.
       @OnlyPublished = 0 je zato namenjen samo pregledu v intranetu. */
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
      /* Kontakti so rocni vnos iz migracije 140; zajema zanje se ni. */
      LEFT JOIN pim.CustomerContact AS contact
        ON contact.CustomerId = customer.CustomerId AND contact.OrganizationId = customer.OrganizationId
      /* IsActive = 1 je obvezen: brez njega bi izklopljen override stranke povozil
         privzeti prag iz pim.ValueDiscountTier in izvozili bi zastarel rabat. */
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
        /* Placnik je par sifra|naziv; prazen je samo, kadar ni ne enega ne drugega. */
        (N''Customer.Payer'', CASE WHEN NULLIF(core.PayerCode, N'''') IS NULL AND NULLIF(core.PayerName, N'''') IS NULL
           THEN NULL ELSE CONVERT(nvarchar(max), ISNULL(core.PayerCode, N'''') + N''|'' + ISNULL(core.PayerName, N'''')) END),
        (N''Customer.Email'', CONVERT(nvarchar(max), core.Email)),
        /* Stolpec predloge je en sam; kadar stacionarne stevilke ni, gre vanj mobilna,
           ker je prazen stolpec ob vpisanem mobitelu izguba podatka, ne resnica. */
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

    /* Veljavnostno okno: potekel ali sele prihodnji rabat ne sme v izvoz.
       NULL pomeni "brez omejitve" na tisti strani. */
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
     Stolpec brez kanonicne kode ostane prazen — to je vidna vrzel registra,
     ne razlog za izmisljeno vrednost.
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

/* --- 5) Ime iz 139 ostane, izvedba se preseli ------------------------------------------- */

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetWebExportRows
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
  /* Ime iz migracije 139 ostaja, ker ga klice intranet; izvedba se je preselila v
     out.GetExportRows, kjer stoji skupaj z izvoznim registrom. Razlika proti 139:
     vir vrednosti ni vec vedno canon.FieldValue, ampak ga pove out.ExportProfile
     .ValueSourceCode, in profil strank ni vec zavrnjen. */
  EXEC out.GetExportRows
    @OrganizationId = @OrganizationId,
    @ExportProfileId = @ExportProfileId,
    @WebSite = @WebSite,
    @OnlyPublished = @OnlyPublished,
    @Search = @Search,
    @Skip = @Skip,
    @Take = @Take,
    @TotalCount = @TotalCount OUTPUT;
END');

/* --- 6) Izvedbeni dokaz ----------------------------------------------------------------- */

IF OBJECT_ID(N'out.MagentoNumber', N'FN') IS NULL
  THROW 52977, 'Funkcija out.MagentoNumber ni nastala.', 1;
IF OBJECT_ID(N'out.GetExportRows', N'P') IS NULL
  THROW 52978, 'Procedura out.GetExportRows ni nastala.', 1;
IF OBJECT_ID(N'intranet.GetWebExportRows', N'P') IS NULL
  THROW 52979, 'Procedura intranet.GetWebExportRows ni nastala.', 1;

/* Zapis stevila je pogodba do Magenta; preverimo jo na mejnih vrednostih in ne na oko. */
IF out.MagentoNumber(12.34) <> N'12.34' OR out.MagentoNumber(12) <> N'12'
  OR out.MagentoNumber(0) <> N'0' OR out.MagentoNumber(-0.5) <> N'-0.5'
  OR out.MagentoNumber(1.23456) <> N'1.2346' OR out.MagentoNumber(NULL) IS NOT NULL
  THROW 52980, 'out.MagentoNumber ne zapise stevila enako kot ToString("0.####").', 1;

DECLARE @ProductProfileId int =
  (SELECT ExportProfileId FROM out.ExportProfile WHERE ProfileCode = N'MAGENTO_PRODUCTS' AND IsActive = 1);
DECLARE @CustomerProfileId int =
  (SELECT ExportProfileId FROM out.ExportProfile WHERE ProfileCode = N'MAGENTO_CUSTOMERS' AND IsActive = 1);
DECLARE @ProbeOrganizationId int = (SELECT MIN(OrganizationId) FROM dbo.OrganizationConfig);

IF @ProductProfileId IS NULL OR @CustomerProfileId IS NULL OR @ProbeOrganizationId IS NULL
  THROW 52981, 'Manjka izvozni profil za Magento ali organizacija za dokaz.', 1;

/* Stolpec ValueSourceCode nastane v tej isti seriji, zato gre tudi njegov dokaz skozi EXEC. */
EXEC(N'
IF NOT EXISTS (SELECT 1 FROM out.ExportProfile
               WHERE ProfileCode = N''MAGENTO_PRODUCTS'' AND ValueSourceCode = N''PIM_PRODUCT'')
  OR NOT EXISTS (SELECT 1 FROM out.ExportProfile
                 WHERE ProfileCode = N''MAGENTO_CUSTOMERS'' AND ValueSourceCode = N''PIM_CUSTOMER'')
  THROW 52982, ''Magento profila nimata vira vrednosti iz sloja pim.'', 1;
');

IF EXISTS (SELECT 1 FROM out.ExportColumn
           WHERE ExportProfileId = @CustomerProfileId AND IsActive = 1
             AND ColumnCode IN (N'CUC03', N'CUC04', N'CUC05')
             AND NULLIF(CanonicalFieldCode, N'') IS NULL)
  THROW 52983, 'Stolpci kontaktov v profilu strank so ostali brez kanonicne kode.', 1;

/* Kontrolno iskanje mora vrniti prazen nabor: procedura se v celoti prevede in izvede,
   pri tem pa ne obljubi vrstic, ki jih morda v razvojni bazi ni. */
DECLARE @ProbeTotal int;

EXEC out.GetExportRows
  @OrganizationId = @ProbeOrganizationId, @ExportProfileId = @ProductProfileId,
  @WebSite = NULL, @OnlyPublished = 0, @Search = N'__MIGRACIJA_142_BREZ_ZADETKA__',
  @Skip = 0, @Take = 1, @TotalCount = @ProbeTotal OUTPUT;
IF @ProbeTotal <> 0 THROW 52984, 'Kontrolno iskanje izdelkov mora vrniti prazen nabor.', 1;

EXEC out.GetExportRows
  @OrganizationId = @ProbeOrganizationId, @ExportProfileId = @CustomerProfileId,
  @WebSite = NULL, @OnlyPublished = 1, @Search = N'__MIGRACIJA_142_BREZ_ZADETKA__',
  @Skip = 0, @Take = 1, @TotalCount = @ProbeTotal OUTPUT;
IF @ProbeTotal <> 0 THROW 52985, 'Kontrolno iskanje strank mora vrniti prazen nabor.', 1;

/* In se enkrat brez iskanja, z eno vrstico: dinamicni izbor stolpcev se mora sestaviti in
   izvesti nad resnicnimi podatki, ne samo nad praznim naborom. Migrator rezultat zavrze. */
EXEC out.GetExportRows
  @OrganizationId = @ProbeOrganizationId, @ExportProfileId = @ProductProfileId,
  @WebSite = NULL, @OnlyPublished = 0, @Search = NULL,
  @Skip = 0, @Take = 1, @TotalCount = @ProbeTotal OUTPUT;

EXEC intranet.GetWebExportRows
  @OrganizationId = @ProbeOrganizationId, @ExportProfileId = @CustomerProfileId,
  @WebSite = NULL, @OnlyPublished = 1, @Search = NULL,
  @Skip = 0, @Take = 1, @TotalCount = @ProbeTotal OUTPUT;
