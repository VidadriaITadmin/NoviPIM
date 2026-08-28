/*
  124 — jezik z imena atributa na svoj stolpec. Prvi del ciscenja podatka o atributih.

  --- Kaj je bilo narobe ---------------------------------------------------------------------

  canon.ProductAttribute ni imel stolpca za jezik, zato je jezik pristal v imenu lastnosti:
  "Prevladujoc material SLO" in "Prevladujoc material ANG" sta bila dva atributa za eno
  lastnost. Izmerjeno 2026-08-27: 33 kod za 17 lastnosti, 97.244 vrstic - 45.450 slovenskih
  in 51.794 angleskih.

  Posledica ni bila samo podvojen sifrant. Vsak nov jezik bi pomenil novo kodo pri vsaki
  prevedljivi lastnosti, izvozni profil pa bi moral nasteti vse tri oblike istega podatka.

  --- Kaj ta migracija naredi ------------------------------------------------------------------

  Koncnici " SLO" in " ANG" gresta z imena v stolpec LanguageCode ('sl', 'en'). Ime lastnosti
  ostane slovensko - preimenovanje v stalne kode (122) je locen korak, ker se dotakne
  validacijskih zahtev in izvoznih stolpcev, ta pa se jih ne.

  Doda se stolpec Unit. Ostane prazen: "Enota napetosti" pripada "Napetosti", "Enota dolzine
  paketa II" pa "Dolzini paketa II", in ta pretvorba v slovenscini ni mehanska. 34 takih kod
  je v sifrantu oznacenih z IsUnitCandidate in cakajo cloveka. Stolpec obstaja, da bo imel
  podatek kam, ko bo par znan.

  --- Zakaj se zamenjata enolicna kljuca ------------------------------------------------------

  UQ_CanonProductAttribute_ProductCode je bil (ProductId, AttributeCode). Po zlozitvi ima
  izdelek dve vrstici z isto kodo in razlicnim jezikom, zato mora biti jezik del kljuca.
  Enako pri pim.ProductAttribute.

  To je edini DROP v tej migraciji in ne izgubi nobene vrstice: kljuc se v isti transakciji
  ustvari znova, sirsi. Preverjeno pred pisanjem: po zlozitvi ni nobenega podvojenega para
  (ProductId, koda, jezik) - 0 od 312.257 vrstic.

  --- Cesa se ta migracija namenoma NE dotakne -------------------------------------------------

  Validacijskih zahtev in izvoznih stolpcev. Edine tri zahteve, ki berejo atribut, so
  ProductAttribute.CategoryRequired in ProductAttribute.Garancija (dvakrat); edini izvozni
  stolpec je KEY_CATEGORY_ATTRIBUTES. Nobeno od teh imen nima jezikovne koncnice, zato se
  nobeno ne spremeni.

  --- Kaj se spremeni za bralca ----------------------------------------------------------------

  canon.FieldValue odslej odda dve obliki: ProductAttribute.<koda> za vsako vrstico in
  ProductAttribute.<koda>.<jezik> tam, kjer je jezik znan - isto pravilo kot pri
  ProductText.<vrsta>.<jezik>. Zahteva na golo kodo tako obvelja za katerikoli jezik,
  zahteva na jezikovno obliko pa za natanko enega.

  Znana posledica za kartico izdelka: prevedljiva lastnost ima odslej dve vrstici namesto dveh
  razlicnih imen. Kartica dobi stolpca LanguageCode in Unit, da ju lahko pokaze; prikaz je
  naloga strani in ne te migracije.
*/

SET XACT_ABORT ON;

/* --- 1) Stolpca ------------------------------------------------------------------------------ */

EXEC(N'
IF COL_LENGTH(N''canon.ProductAttribute'', N''LanguageCode'') IS NULL
  ALTER TABLE canon.ProductAttribute ADD LanguageCode nvarchar(10) NULL;
');
EXEC(N'
IF COL_LENGTH(N''canon.ProductAttribute'', N''Unit'') IS NULL
  ALTER TABLE canon.ProductAttribute ADD Unit nvarchar(50) NULL;
');
EXEC(N'
IF COL_LENGTH(N''pim.ProductAttribute'', N''LanguageCode'') IS NULL
  ALTER TABLE pim.ProductAttribute ADD LanguageCode nvarchar(10) NULL;
');

/* --- 2) Jezik z imena v stolpec ---------------------------------------------------------------

   Vrstni red je pomemben in prvi poskus ga je imel narobe: odrez pripone pred razsiritvijo
   kljuca pade z napako 2627, ker imata "X SLO" in "X ANG" po odrezu isto kodo pri istem
   izdelku. Zato najprej jezik (koda se ne spremeni, kljuc drzi), nato sirsi kljuc, sele nato
   odrez.
   ---------------------------------------------------------------------------------------- */

EXEC(N'
UPDATE canon.ProductAttribute
SET LanguageCode = CASE WHEN AttributeCode LIKE N''% SLO'' THEN N''sl'' ELSE N''en'' END
WHERE LanguageCode IS NULL AND (AttributeCode LIKE N''% SLO'' OR AttributeCode LIKE N''% ANG'');

UPDATE pim.ProductAttribute
SET LanguageCode = CASE WHEN AttributeCode LIKE N''% SLO'' THEN N''sl'' ELSE N''en'' END
WHERE LanguageCode IS NULL AND (AttributeCode LIKE N''% SLO'' OR AttributeCode LIKE N''% ANG'');
');

/* --- 3) Enolicna kljuca dobita jezik ----------------------------------------------------------- */

EXEC(N'
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N''UQ_CanonProductAttribute_ProductCode''
             AND object_id = OBJECT_ID(N''canon.ProductAttribute''))
BEGIN
  ALTER TABLE canon.ProductAttribute DROP CONSTRAINT UQ_CanonProductAttribute_ProductCode;
END;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N''UQ_CanonProductAttribute_ProductCodeLang''
                 AND object_id = OBJECT_ID(N''canon.ProductAttribute''))
BEGIN
  ALTER TABLE canon.ProductAttribute
    ADD CONSTRAINT UQ_CanonProductAttribute_ProductCodeLang UNIQUE (ProductId, AttributeCode, LanguageCode);
END;
');

EXEC(N'
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N''UQ_PimProductAttribute''
             AND object_id = OBJECT_ID(N''pim.ProductAttribute''))
BEGIN
  ALTER TABLE pim.ProductAttribute DROP CONSTRAINT UQ_PimProductAttribute;
END;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N''UQ_PimProductAttribute_Lang''
                 AND object_id = OBJECT_ID(N''pim.ProductAttribute''))
BEGIN
  ALTER TABLE pim.ProductAttribute
    ADD CONSTRAINT UQ_PimProductAttribute_Lang UNIQUE (PimProductId, AttributeCode, LanguageCode);
END;
');

/* --- 3b) Sele zdaj odrez pripone --------------------------------------------------------------- */

EXEC(N'
UPDATE canon.ProductAttribute
SET AttributeCode = LTRIM(RTRIM(LEFT(AttributeCode, LEN(AttributeCode) - 4)))
WHERE AttributeCode LIKE N''% SLO'' OR AttributeCode LIKE N''% ANG'';

UPDATE pim.ProductAttribute
SET AttributeCode = LTRIM(RTRIM(LEFT(AttributeCode, LEN(AttributeCode) - 4)))
WHERE AttributeCode LIKE N''% SLO'' OR AttributeCode LIKE N''% ANG'';
');

/* --- 4) canon.FieldValue odda tudi jezikovno obliko --------------------------------------------- */

EXEC(N'
CREATE OR ALTER VIEW canon.FieldValue
AS
SELECT ProductId, N''Product.ItemID'' AS FieldCode, NULLIF(ItemID, N'''') AS Value FROM canon.Product
UNION ALL SELECT ProductId, N''Product.EAN'', NULLIF(EAN, N'''') FROM canon.Product
UNION ALL SELECT ProductId, N''Product.UoM'', NULLIF(UoM, N'''') FROM canon.Product
UNION ALL SELECT ProductId, N''Product.Supplier'', NULLIF(Supplier, N'''') FROM canon.Product
UNION ALL SELECT ProductId, N''Product.Manufacturer'', NULLIF(Manufacturer, N'''') FROM canon.Product
UNION ALL SELECT ProductId, N''Product.AccountingGroup'', NULLIF(AccountingGroup, N'''') FROM canon.Product
UNION ALL SELECT ProductId, N''Product.DiscountGroup'', NULLIF(DiscountGroup, N'''') FROM canon.Product
UNION ALL SELECT ProductId, N''Product.ItemGroup'', NULLIF(ItemGroup, N'''') FROM canon.Product
UNION ALL SELECT ProductId, N''Product.Department'', NULLIF(Department, N'''') FROM canon.Product
UNION ALL SELECT ProductId, N''Product.IsActive'', CONVERT(nvarchar(10), IsActive) FROM canon.Product
UNION ALL SELECT ProductId, N''Product.WebPublish'', CONVERT(nvarchar(10), WebPublish) FROM canon.Product
UNION ALL SELECT ProductId, N''ProductCommercial.NetWeight'', NULLIF(CONVERT(nvarchar(50), NetWeight), N'''') FROM canon.ProductCommercial
UNION ALL SELECT ProductId, N''ProductCommercial.GrossWeight'', NULLIF(CONVERT(nvarchar(50), GrossWeight), N'''') FROM canon.ProductCommercial
UNION ALL SELECT ProductId, N''ProductCommercial.CustomsTariff'', NULLIF(CustomsTariff, N'''') FROM canon.ProductCommercial
UNION ALL SELECT ProductId, N''ProductCommercial.CountryOfOrigin'', NULLIF(CountryOfOrigin, N'''') FROM canon.ProductCommercial
UNION ALL SELECT ProductId, N''ProductCommercial.Pak1'', NULLIF(CONVERT(nvarchar(50), Pak1), N'''') FROM canon.ProductCommercial
UNION ALL SELECT ProductId, N''ProductCommercial.Pak2'', NULLIF(CONVERT(nvarchar(50), Pak2), N'''') FROM canon.ProductCommercial
UNION ALL SELECT ProductId, N''ProductCommercial.Volume'', NULLIF(CONVERT(nvarchar(50), Volume), N'''') FROM canon.ProductCommercial
UNION ALL SELECT ProductId, N''ProductCommercial.PackageLength'', NULLIF(CONVERT(nvarchar(50), PackageLength), N'''') FROM canon.ProductCommercial
UNION ALL SELECT ProductId, N''ProductCommercial.PackageWidth'', NULLIF(CONVERT(nvarchar(50), PackageWidth), N'''') FROM canon.ProductCommercial
UNION ALL SELECT ProductId, N''ProductCommercial.PackageHeight'', NULLIF(CONVERT(nvarchar(50), PackageHeight), N'''') FROM canon.ProductCommercial
UNION ALL SELECT ProductId, N''ProductCommercial.DimensionUnit'', NULLIF(DimensionUnit, N'''') FROM canon.ProductCommercial
UNION ALL SELECT textValue.ProductId, CONCAT(N''ProductText.'', textValue.TextType, N''.'', textValue.Lang), NULLIF(textValue.Value, N'''') FROM canon.ProductText textValue
/*
  124: gola koda velja za katerikoli jezik, jezikovna oblika za natanko enega. Isto pravilo kot
  pri ProductText zgoraj. Zahteva, zapisana pred to migracijo, se nanasa na golo kodo in zato
  deluje naprej brez spremembe.
*/
UNION ALL SELECT attributeValue.ProductId, CONCAT(N''ProductAttribute.'', attributeValue.AttributeCode), NULLIF(attributeValue.Value, N'''') FROM canon.ProductAttribute attributeValue
UNION ALL SELECT attributeValue.ProductId, CONCAT(N''ProductAttribute.'', attributeValue.AttributeCode, N''.'', attributeValue.LanguageCode), NULLIF(attributeValue.Value, N'''')
  FROM canon.ProductAttribute attributeValue WHERE attributeValue.LanguageCode IS NOT NULL
UNION ALL SELECT ProductId, N''ProductCategory.CategoryPath'', NULLIF(CategoryPath, N'''') FROM canon.ProductCategory
UNION ALL SELECT ProductId, N''ProductMedia.Url'', NULLIF(Url, N'''') FROM canon.ProductMedia
UNION ALL SELECT ProductId, N''ProductPrice.VatRate'', CONVERT(nvarchar(50), VatRate) FROM canon.ProductPrice WHERE IsActive = 1
UNION ALL SELECT ProductId, N''ProductPrice.Gross'', CONVERT(nvarchar(50), Net * (1 + VatRate / 100)) FROM canon.ProductPrice WHERE IsActive = 1 AND Net * (1 + VatRate / 100) > 0;
');

/* --- 5) Objava nosi jezik ------------------------------------------------------------------------ */

EXEC(N'
CREATE OR ALTER PROCEDURE val.Promote
  @OrganizationId int = NULL,
  @ValidationProfileCode nvarchar(100) = N''ERP_L1''
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  BEGIN TRY
    BEGIN TRANSACTION;

    /* Kateri artikli so upraviceni do objave po izbranem profilu. */
    DECLARE @Eligible TABLE(ProductId bigint PRIMARY KEY, OrganizationId int, ItemID nvarchar(200));
    INSERT @Eligible(ProductId, OrganizationId, ItemID)
    SELECT product.ProductId, product.OrganizationId, product.ItemID
    FROM canon.Product product
    INNER JOIN val.ProductValidationState validationState ON validationState.ProductId = product.ProductId
    INNER JOIN val.ValidationProfile profile ON profile.ValidationProfileId = validationState.ValidationProfileId
    WHERE profile.ProfileCode = @ValidationProfileCode AND validationState.Status = N''VALID''
      AND product.IsActive = 1 AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId);

    MERGE pim.Product AS target
    USING
    (
      SELECT e.ProductId, e.OrganizationId, e.ItemID, product.EAN, product.Manufacturer,
             product.Supplier, product.UoM,
             /*
               Naziv: spletni, ce obstaja, sicer ERP naziv v istem jeziku. Do 074 je bil pogoj
               samo WEB_TITLE in ker spletnih nazivov (se) ni, je pim.Product.Name ostal NULL pri
               vseh izdelkih — stolpec ''Naziv artikla'' v izvozu je bil zato prazen, ceprav naziv
               obstaja. Prazno ime ni resnica; ERP naziv je.
             */
             COALESCE(
               (SELECT TOP (1) textValue.Value FROM canon.ProductText textValue
                WHERE textValue.ProductId = e.ProductId AND textValue.TextType = N''WEB_TITLE'' AND textValue.Lang = N''sl''),
               (SELECT TOP (1) textValue.Value FROM canon.ProductText textValue
                WHERE textValue.ProductId = e.ProductId AND textValue.TextType = N''TITLE_ERP'' AND textValue.Lang = N''sl'')
             ) AS Name
      FROM @Eligible e
      INNER JOIN canon.Product product ON product.ProductId = e.ProductId
    ) AS source ON target.OrganizationId = source.OrganizationId AND target.ItemID = source.ItemID
    WHEN MATCHED THEN UPDATE SET EAN = source.EAN, Name = source.Name, Manufacturer = source.Manufacturer,
      Supplier = source.Supplier, UoM = source.UoM, PromotedUtc = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT (OrganizationId, ItemID, EAN, Name, Manufacturer, Supplier, UoM)
      VALUES (source.OrganizationId, source.ItemID, source.EAN, source.Name, source.Manufacturer,
              source.Supplier, source.UoM);

    /*
      Novost 058: objava ni bila koncana. val.Promote je do zdaj zapisala samo glavo izdelka,
      pim.ProductText, pim.ProductPrice, pim.ProductMedia, pim.ProductCategory,
      pim.ProductAttribute in pim.ProductCommercial pa so ostale prazne — vseh sest je imelo
      0 vrstic. Magento izvoz bere prav te tabele, zato bi izvozil skoraj prazne vrstice.

      Spodaj je za vsako otrosko tabelo isti vzorec: preberi iz canon za objavljene izdelke in
      uskladi z MERGE po naravnem kljucu.

      Kar to NAMENOMA se ne naredi: ne brise vrstic, ki so v pim, v canon pa jih ni vec.
      Brisanje je na zaprtem seznamu pravil in zahteva odlocitev cloveka; do takrat lahko v
      objavljenem sloju ostane zapis, ki je bil v katalogu odstranjen. Pri cenah to ni
      problem, ker ima pim.ProductPrice IsActive.
    */
    DECLARE @Objavljeni TABLE(PimProductId bigint PRIMARY KEY, ProductId bigint);
    INSERT @Objavljeni(PimProductId, ProductId)
    SELECT pimProduct.PimProductId, e.ProductId
    FROM @Eligible e
    INNER JOIN pim.Product pimProduct ON pimProduct.OrganizationId = e.OrganizationId AND pimProduct.ItemID = e.ItemID;

    MERGE pim.ProductText AS target
    USING
    (
      SELECT o.PimProductId, t.Lang, t.TextType, t.Value
      FROM @Objavljeni o INNER JOIN canon.ProductText t ON t.ProductId = o.ProductId
    ) AS source ON target.PimProductId = source.PimProductId AND target.Lang = source.Lang AND target.TextType = source.TextType
    WHEN MATCHED THEN UPDATE SET Value = source.Value
    WHEN NOT MATCHED THEN INSERT (PimProductId, Lang, TextType, Value)
      VALUES (source.PimProductId, source.Lang, source.TextType, source.Value);

    MERGE pim.ProductPrice AS target
    USING
    (
      SELECT o.PimProductId, p.PriceList, p.Net, p.VatRate, p.ValidFrom, p.IsActive
      FROM @Objavljeni o INNER JOIN canon.ProductPrice p ON p.ProductId = o.ProductId
    ) AS source ON target.PimProductId = source.PimProductId AND target.PriceList = source.PriceList AND target.ValidFrom = source.ValidFrom
    WHEN MATCHED THEN UPDATE SET Net = source.Net, VatRate = source.VatRate, IsActive = source.IsActive
    WHEN NOT MATCHED THEN INSERT (PimProductId, PriceList, Net, VatRate, ValidFrom, IsActive)
      VALUES (source.PimProductId, source.PriceList, source.Net, source.VatRate, source.ValidFrom, source.IsActive);

    MERGE pim.ProductMedia AS target
    USING
    (
      SELECT o.PimProductId, m.Url, m.Role, m.SortOrder
      FROM @Objavljeni o INNER JOIN canon.ProductMedia m ON m.ProductId = o.ProductId
    ) AS source ON target.PimProductId = source.PimProductId AND target.Role = source.Role AND target.SortOrder = source.SortOrder
    WHEN MATCHED THEN UPDATE SET Url = source.Url
    WHEN NOT MATCHED THEN INSERT (PimProductId, Url, Role, SortOrder)
      VALUES (source.PimProductId, source.Url, source.Role, source.SortOrder);

    MERGE pim.ProductCategory AS target
    USING
    (
      SELECT o.PimProductId, c.WebSite, c.CategoryPath
      FROM @Objavljeni o INNER JOIN canon.ProductCategory c ON c.ProductId = o.ProductId
    ) AS source ON target.PimProductId = source.PimProductId AND target.WebSite = source.WebSite AND target.CategoryPath = source.CategoryPath
    WHEN NOT MATCHED THEN INSERT (PimProductId, WebSite, CategoryPath)
      VALUES (source.PimProductId, source.WebSite, source.CategoryPath);

    MERGE pim.ProductAttribute AS target
    USING
    (
      /*
        124: jezik je odslej stolpec, ne del imena. Brez njega bi ista lastnost v dveh jezikih
        dala dve izvorni vrstici za isti cilj in MERGE bi padel z napako 8672.
      */
      SELECT o.PimProductId, a.AttributeCode, a.LanguageCode, a.Value
      FROM @Objavljeni o INNER JOIN canon.ProductAttribute a ON a.ProductId = o.ProductId
    ) AS source ON target.PimProductId = source.PimProductId AND target.AttributeCode = source.AttributeCode
      AND ISNULL(target.LanguageCode, N''~'') = ISNULL(source.LanguageCode, N''~'')
    WHEN MATCHED THEN UPDATE SET Value = source.Value
    WHEN NOT MATCHED THEN INSERT (PimProductId, AttributeCode, LanguageCode, Value)
      VALUES (source.PimProductId, source.AttributeCode, source.LanguageCode, source.Value);

    MERGE pim.ProductCommercial AS target
    USING
    (
      /*
        Volumen, mere pakiranja in enota so v katalogu od migracije 057, v objavi pa jih do 075
        ni bilo — objava je nesla samo tisto, kar je tabela poznala prej. Izvoz bere objavo, zato
        so stolpci predloge ostali prazni, ceprav podatek obstaja pri 196.513 izdelkih.
      */
      SELECT o.PimProductId, k.NetWeight, k.GrossWeight, k.CustomsTariff, k.CountryOfOrigin, k.Pak1, k.Pak2, k.Dimensions,
             k.Volume, k.PackageLength, k.PackageWidth, k.PackageHeight, k.DimensionUnit
      FROM @Objavljeni o INNER JOIN canon.ProductCommercial k ON k.ProductId = o.ProductId
    ) AS source ON target.PimProductId = source.PimProductId
    WHEN MATCHED THEN UPDATE SET NetWeight = source.NetWeight, GrossWeight = source.GrossWeight,
      CustomsTariff = source.CustomsTariff, CountryOfOrigin = source.CountryOfOrigin,
      Pak1 = source.Pak1, Pak2 = source.Pak2, Dimensions = source.Dimensions,
      Volume = source.Volume, PackageLength = source.PackageLength, PackageWidth = source.PackageWidth,
      PackageHeight = source.PackageHeight, DimensionUnit = source.DimensionUnit
    WHEN NOT MATCHED THEN INSERT (PimProductId, NetWeight, GrossWeight, CustomsTariff, CountryOfOrigin, Pak1, Pak2, Dimensions,
                                  Volume, PackageLength, PackageWidth, PackageHeight, DimensionUnit)
      VALUES (source.PimProductId, source.NetWeight, source.GrossWeight, source.CustomsTariff, source.CountryOfOrigin,
              source.Pak1, source.Pak2, source.Dimensions,
              source.Volume, source.PackageLength, source.PackageWidth, source.PackageHeight, source.DimensionUnit);

    COMMIT TRANSACTION;
  END TRY
  BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
  END CATCH;
END;
');

/* --- 6) Kartica izdelka vidi jezik in enoto ------------------------------------------------------ */

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetProductCard
  @OrganizationId int,
  @ProductId bigint,
  @Language nvarchar(20) = N''sl''
AS
BEGIN
  SET NOCOUNT ON;

  DECLARE @ItemID nvarchar(450), @ItemGroup nvarchar(100);
  SELECT @ItemID = product.ItemID, @ItemGroup = product.ItemGroup
  FROM canon.Product AS product
  WHERE product.OrganizationId = @OrganizationId AND product.ProductId = @ProductId;

  /* 1 — glava in locena pripravljenost ERP/splet. */
  SELECT product.ProductId, product.ItemID,
    product.EAN,
    Name = COALESCE(webTitle.Value, erpTitle.Value, product.ItemID),
    ThumbnailUrl = thumbnail.Url,
    product.IsActive, product.WebPublish,
    IsPromoted = CONVERT(bit, CASE WHEN promoted.PimProductId IS NULL THEN 0 ELSE 1 END),
    ErpStatus = CASE
      WHEN NOT EXISTS
      (
        SELECT 1 FROM val.ValidationProfile profileValue
        WHERE profileValue.IsActive = 1 AND profileValue.BlocksErp = 1
      ) THEN N''NOT_CONFIGURED''
      WHEN EXISTS
      (
        SELECT 1 FROM val.ValidationProfile profileValue
        LEFT JOIN val.ProductValidationState stateValue
          ON stateValue.ValidationProfileId = profileValue.ValidationProfileId
         AND stateValue.ProductId = product.ProductId
        WHERE profileValue.IsActive = 1 AND profileValue.BlocksErp = 1
          AND (stateValue.ProductValidationStateId IS NULL OR stateValue.Status <> N''VALID'')
      ) THEN N''INVALID'' ELSE N''VALID'' END,
    WebStatus = CASE
      WHEN NOT EXISTS
      (
        SELECT 1 FROM val.ValidationProfile profileValue
        WHERE profileValue.IsActive = 1 AND profileValue.BlocksWeb = 1
      ) THEN N''NOT_CONFIGURED''
      WHEN EXISTS
      (
        SELECT 1 FROM val.ValidationProfile profileValue
        LEFT JOIN val.ProductValidationState stateValue
          ON stateValue.ValidationProfileId = profileValue.ValidationProfileId
         AND stateValue.ProductId = product.ProductId
        WHERE profileValue.IsActive = 1 AND profileValue.BlocksWeb = 1
          AND (stateValue.ProductValidationStateId IS NULL OR stateValue.Status <> N''VALID'')
      ) THEN N''INVALID'' ELSE N''VALID'' END,
    product.ValidationStatus, product.Completeness, product.UoM, product.ItemGroup,
    product.Department, product.Manufacturer, product.Supplier, product.DiscountGroup,
    product.AccountingGroup, product.LastValidatedUtc,
    OpenIssueCount =
    (
      SELECT COUNT_BIG(*) FROM val.ProductIssue issueValue
      WHERE issueValue.ProductId = product.ProductId AND issueValue.IsActive = 1
    )
  FROM canon.Product AS product
  OUTER APPLY
  (
    SELECT TOP (1) textValue.Value
    FROM canon.ProductText AS textValue
    WHERE textValue.ProductId = product.ProductId
      AND textValue.TextType = N''WEB_TITLE''
      AND (@Language IS NULL OR textValue.Lang = @Language)
    ORDER BY CASE WHEN textValue.Lang = @Language THEN 0 ELSE 1 END, textValue.Lang
  ) AS webTitle
  OUTER APPLY
  (
    SELECT TOP (1) textValue.Value
    FROM canon.ProductText AS textValue
    WHERE textValue.ProductId = product.ProductId AND textValue.TextType = N''TITLE_ERP''
    ORDER BY CASE WHEN textValue.Lang = @Language THEN 0 WHEN textValue.Lang = N''sl'' THEN 1 ELSE 2 END,
      textValue.Lang
  ) AS erpTitle
  OUTER APPLY
  (
    SELECT TOP (1) media.Url
    FROM canon.ProductMedia AS media
    WHERE media.ProductId = product.ProductId
    ORDER BY CASE WHEN media.Role IN (N''MAIN'', N''Glavna'', N''Primary'') THEN 0 ELSE 1 END,
      media.SortOrder, media.ProductMediaId
  ) AS thumbnail
  LEFT JOIN pim.Product AS promoted
    ON promoted.OrganizationId = product.OrganizationId AND promoted.ItemID = product.ItemID
  WHERE product.OrganizationId = @OrganizationId AND product.ProductId = @ProductId;

  IF @ItemID IS NULL RETURN;

  /* 2 — kljucna polja z dejanskim lastnikom. */
  SELECT fieldValue.FieldKey, fieldValue.Label, fieldValue.Value,
    Owner = COALESCE(policyValue.Owner, ownership.Owner, N''SHARED'')
  FROM canon.Product AS product
  LEFT JOIN canon.ProductCommercial AS commercial ON commercial.ProductId = product.ProductId
  CROSS APPLY
  (
    VALUES
      (N''Product.ItemID'', N''Artikel'', CONVERT(nvarchar(4000), product.ItemID)),
      (N''Product.EAN'', N''EAN'', CONVERT(nvarchar(4000), product.EAN)),
      (N''Product.IsActive'', N''Aktiven'', CONVERT(nvarchar(4000), product.IsActive)),
      (N''Product.WebPublish'', N''Za splet'', CONVERT(nvarchar(4000), product.WebPublish)),
      (N''Product.UoM'', N''Enota mere'', CONVERT(nvarchar(4000), product.UoM)),
      (N''Product.ItemGroup'', N''Skupina'', CONVERT(nvarchar(4000), product.ItemGroup)),
      (N''Product.Department'', N''Oddelek'', CONVERT(nvarchar(4000), product.Department)),
      (N''Product.Manufacturer'', N''Proizvajalec'', CONVERT(nvarchar(4000), product.Manufacturer)),
      (N''Product.Supplier'', N''Dobavitelj'', CONVERT(nvarchar(4000), product.Supplier)),
      (N''Product.DiscountGroup'', N''Skupina popusta'', CONVERT(nvarchar(4000), product.DiscountGroup)),
      (N''Product.AccountingGroup'', N''Kontna skupina'', CONVERT(nvarchar(4000), product.AccountingGroup)),
      (N''ProductCommercial.NetWeight'', N''Neto teza'', CONVERT(nvarchar(4000), commercial.NetWeight)),
      (N''ProductCommercial.GrossWeight'', N''Bruto teza'', CONVERT(nvarchar(4000), commercial.GrossWeight)),
      (N''ProductCommercial.CustomsTariff'', N''Carinska tarifa'', CONVERT(nvarchar(4000), commercial.CustomsTariff)),
      (N''ProductCommercial.CountryOfOrigin'', N''Drzava porekla'', CONVERT(nvarchar(4000), commercial.CountryOfOrigin))
  ) AS fieldValue(FieldKey, Label, Value)
  OUTER APPLY
  (
    SELECT TOP (1) policy.Owner
    FROM out.OwnershipPolicy AS policy
    WHERE policy.OrganizationId = @OrganizationId AND policy.TargetKind = N''SAOP_PRODUCT''
      AND policy.FieldName = fieldValue.FieldKey AND policy.IsEnabled = 1
      AND policy.ConstraintKind IS NULL AND policy.ConstraintValue IS NULL
    ORDER BY policy.OwnershipPolicyId DESC
  ) AS policyValue
  LEFT JOIN pim.FieldOwnership AS ownership
    ON ownership.FieldKey = fieldValue.FieldKey AND ownership.IsActive = 1
  WHERE product.OrganizationId = @OrganizationId AND product.ProductId = @ProductId
  ORDER BY CASE fieldValue.FieldKey
    WHEN N''Product.ItemID'' THEN 1 WHEN N''Product.EAN'' THEN 2
    WHEN N''Product.IsActive'' THEN 3 WHEN N''Product.WebPublish'' THEN 4
    WHEN N''Product.UoM'' THEN 5 WHEN N''Product.ItemGroup'' THEN 6
    WHEN N''Product.Department'' THEN 7 WHEN N''Product.Manufacturer'' THEN 8
    WHEN N''Product.Supplier'' THEN 9 ELSE 20 END;

  /* 3 — cakajoce, poslane ali odklonjene vrednosti; logika ostane v obstojeci proceduri. */
  DECLARE @ItemIdsJson nvarchar(max) = N''["'' + STRING_ESCAPE(@ItemID, N''json'') + N''"]'';
  EXEC intranet.GetPendingOverlay
    @OrganizationId = @OrganizationId, @ItemIdsJson = @ItemIdsJson, @TargetKind = N''SAOP_PRODUCT'';

  /* 4 — besedila. */
  SELECT textValue.ProductTextId, textValue.Lang, textValue.TextType, textValue.Value,
    FieldKey = CONCAT(N''ProductText.'', textValue.TextType, N''.'', textValue.Lang),
    Owner = COALESCE(policyValue.Owner, N''SHARED'')
  FROM canon.ProductText AS textValue
  OUTER APPLY
  (
    SELECT TOP (1) policy.Owner
    FROM out.OwnershipPolicy AS policy
    WHERE policy.OrganizationId = @OrganizationId AND policy.TargetKind = N''SAOP_PRODUCT''
      AND policy.FieldName = CONCAT(N''ProductText.'', textValue.TextType, N''.'', textValue.Lang)
      AND policy.IsEnabled = 1
    ORDER BY policy.OwnershipPolicyId DESC
  ) AS policyValue
  WHERE textValue.ProductId = @ProductId
  ORDER BY textValue.Lang, textValue.TextType;

  /* 5 — lastnosti. */
  SELECT attributeValue.ProductAttributeId, attributeValue.AttributeCode, attributeValue.Value,
    /*
      124: jezik in enota sta odslej stolpca. Kartica ju dobi, da se dve vrstici iste lastnosti
      v dveh jezikih ne pokazeta kot dve enaki vrstici brez razlage.
    */
    attributeValue.LanguageCode, attributeValue.Unit,
    FieldKey = CONCAT(N''ProductAttribute.'', attributeValue.AttributeCode),
    Owner = COALESCE(policyValue.Owner, N''SHARED'')
  FROM canon.ProductAttribute AS attributeValue
  OUTER APPLY
  (
    SELECT TOP (1) policy.Owner
    FROM out.OwnershipPolicy AS policy
    WHERE policy.OrganizationId = @OrganizationId AND policy.TargetKind = N''SAOP_PRODUCT''
      AND policy.FieldName = CONCAT(N''ProductAttribute.'', attributeValue.AttributeCode)
      AND policy.IsEnabled = 1
    ORDER BY policy.OwnershipPolicyId DESC
  ) AS policyValue
  WHERE attributeValue.ProductId = @ProductId
  ORDER BY attributeValue.AttributeCode, attributeValue.LanguageCode;

  /* 6 — kategorije z razresenim imenom, kadar register vsebuje pot. */
  SELECT productCategory.ProductCategoryId, productCategory.WebSite, productCategory.CategoryPath,
    category.CategoryTreeCode, category.CategoryCode, category.CategoryName,
    Owner = COALESCE(policyValue.Owner, N''SHARED'')
  FROM canon.ProductCategory AS productCategory
  OUTER APPLY
  (
    SELECT TOP (1) categoryValue.CategoryTreeCode, categoryValue.CategoryCode, categoryValue.CategoryName
    FROM canon.Category AS categoryValue
    WHERE categoryValue.CategoryPath = productCategory.CategoryPath
      AND (categoryValue.CategoryTreeCode = productCategory.WebSite
        OR categoryValue.CategoryCode = productCategory.WebSite)
    ORDER BY CASE WHEN categoryValue.CategoryTreeCode = productCategory.WebSite THEN 0 ELSE 1 END,
      categoryValue.CategoryId
  ) AS category
  OUTER APPLY
  (
    SELECT TOP (1) policy.Owner
    FROM out.OwnershipPolicy AS policy
    WHERE policy.OrganizationId = @OrganizationId AND policy.TargetKind = N''SAOP_PRODUCT''
      AND policy.FieldName = N''ProductCategory.CategoryPath'' AND policy.IsEnabled = 1
    ORDER BY policy.OwnershipPolicyId DESC
  ) AS policyValue
  WHERE productCategory.ProductId = @ProductId
  ORDER BY productCategory.WebSite, productCategory.CategoryPath;

  /* 7 — slike in povezani mediji. */
  SELECT media.ProductMediaId, media.Url, media.Role, media.SortOrder,
    Owner = COALESCE(policyValue.Owner, N''SHARED'')
  FROM canon.ProductMedia AS media
  OUTER APPLY
  (
    SELECT TOP (1) policy.Owner
    FROM out.OwnershipPolicy AS policy
    WHERE policy.OrganizationId = @OrganizationId AND policy.TargetKind = N''SAOP_PRODUCT''
      AND policy.FieldName = N''ProductMedia.Url'' AND policy.IsEnabled = 1
    ORDER BY policy.OwnershipPolicyId DESC
  ) AS policyValue
  WHERE media.ProductId = @ProductId
  ORDER BY media.SortOrder, media.ProductMediaId;

  /* 8 — dokumenti so loceni od slik. */
  SELECT document.ProductDocumentId, document.Role, document.Url, document.Title, document.SortOrder
  FROM canon.ProductDocument AS document
  WHERE document.ProductId = @ProductId
  ORDER BY document.SortOrder, document.Role, document.ProductDocumentId;

  /* 9 — cene. */
  SELECT price.ProductPriceId, price.PriceList, price.Net, price.VatRate,
    Gross = CONVERT(decimal(19,4), price.Net * (1 + price.VatRate / 100)),
    price.ValidFrom, price.IsActive
  FROM canon.ProductPrice AS price
  WHERE price.ProductId = @ProductId
  ORDER BY price.IsActive DESC, price.PriceList, price.ValidFrom DESC;

  /* 10 — dejanska zaloga in pravilo min/max po skladiscu. */
  SELECT position.PositionId, snapshot.SnapshotId, snapshot.ProviderKind, snapshot.Endpoint,
    snapshot.SnapshotUtc, position.Quantity, position.AvailabilityDate, position.IncomingQuantity,
    position.MatchKey, warehouse.WarehouseCode, warehouse.Name AS WarehouseName,
    policy.MinimumStock, policy.MaximumStock
  FROM stock.Position AS position
  INNER JOIN stock.Snapshot AS snapshot ON snapshot.SnapshotId = position.SnapshotId
  LEFT JOIN canon.Warehouse AS warehouse
    ON warehouse.OrganizationId = snapshot.OrganizationId
   AND (warehouse.WarehouseCode = position.MatchKey OR warehouse.WarehouseCode = snapshot.Endpoint)
  LEFT JOIN canon.ProductStockPolicy AS policy
    ON policy.ProductId = position.MatchedProductId
   AND policy.WarehouseCode = COALESCE(warehouse.WarehouseCode, position.MatchKey)
  WHERE position.MatchedProductId = @ProductId AND snapshot.OrganizationId = @OrganizationId
    AND snapshot.IsActive = 1
  ORDER BY snapshot.SnapshotUtc DESC, position.PositionId DESC;

  /* 11 — trgovinski podatki. */
  SELECT commercial.ProductCommercialId, commercial.NetWeight, commercial.GrossWeight,
    commercial.CustomsTariff, commercial.CountryOfOrigin, commercial.Pak1, commercial.Pak2,
    commercial.Dimensions, commercial.Volume, commercial.PackageLength,
    commercial.PackageWidth, commercial.PackageHeight, commercial.DimensionUnit
  FROM canon.ProductCommercial AS commercial
  WHERE commercial.ProductId = @ProductId;

  /* 12 — profili povedo tudi, kaj blokirajo. */
  SELECT profileValue.ValidationProfileId, profileValue.ProfileCode, profileValue.Name,
    profileValue.Scope, profileValue.BlocksErp, profileValue.BlocksWeb,
    Status = COALESCE(stateValue.Status, N''PENDING''),
    Completeness = COALESCE(stateValue.Completeness, CONVERT(decimal(5,2), 0)),
    stateValue.ValidatedUtc,
    OpenIssueCount =
    (
      SELECT COUNT_BIG(*) FROM val.ProductIssue issueValue
      WHERE issueValue.ProductId = @ProductId
        AND issueValue.ValidationProfileId = profileValue.ValidationProfileId
        AND issueValue.IsActive = 1
    )
  FROM val.ValidationProfile AS profileValue
  LEFT JOIN val.ProductValidationState AS stateValue
    ON stateValue.ValidationProfileId = profileValue.ValidationProfileId
   AND stateValue.ProductId = @ProductId
  WHERE profileValue.IsActive = 1
  ORDER BY profileValue.BlocksErp DESC, profileValue.BlocksWeb DESC, profileValue.ProfileCode;

  /* 13 — tezava pove manjkajoce polje, resnost in posledico. */
  SELECT issueValue.ProductIssueId, profileValue.ProfileCode, requirement.FieldCode,
    requirement.Severity, profileValue.BlocksErp, profileValue.BlocksWeb,
    issueValue.IssueCode, issueValue.Message, issueValue.FirstDetectedUtc,
    issueValue.LastDetectedUtc
  FROM val.ProductIssue AS issueValue
  INNER JOIN val.ValidationProfile AS profileValue
    ON profileValue.ValidationProfileId = issueValue.ValidationProfileId
  INNER JOIN val.FieldRequirement AS requirement
    ON requirement.FieldRequirementId = issueValue.FieldRequirementId
  WHERE issueValue.ProductId = @ProductId AND issueValue.IsActive = 1
  ORDER BY CASE requirement.Severity WHEN N''ERROR'' THEN 0 ELSE 1 END,
    profileValue.ProfileCode, requirement.FieldCode;

  /* 14 — odhodna pot z zadnjim dejanskim poskusom. */
  SELECT message.OutboxMessageId, message.Operation, message.EntityType, message.EntityKey,
    message.FieldSummary, message.Status, message.AttemptCount, message.LastError,
    message.DriftDetail, message.CreatedUtc, message.ApprovedUtc, message.SentUtc,
    message.VerifiedUtc, message.UpdatedUtc, message.OutboundBatchId,
    attempt.AttemptNumber, attempt.Outcome AS AttemptOutcome,
    attempt.StartedUtc AS AttemptStartedUtc, attempt.CompletedUtc AS AttemptCompletedUtc,
    attempt.FailureReason AS AttemptFailureReason
  FROM out.OutboxMessage AS message
  OUTER APPLY
  (
    SELECT TOP (1) attemptValue.AttemptNumber, attemptValue.Outcome,
      attemptValue.StartedUtc, attemptValue.CompletedUtc, attemptValue.FailureReason
    FROM out.OutboxAttempt AS attemptValue
    WHERE attemptValue.OutboxMessageId = message.OutboxMessageId
    ORDER BY attemptValue.AttemptNumber DESC, attemptValue.OutboxAttemptId DESC
  ) AS attempt
  WHERE message.OrganizationId = @OrganizationId AND message.TargetKind = N''SAOP_PRODUCT''
    AND message.EntityKey = @ItemID
  ORDER BY message.CreatedUtc DESC, message.OutboxMessageId DESC;

  /* 15 — zgodovina z avtorjem, paketom in razlogom. */
  SELECT history.ChangeId, history.ChangeBatchId, history.FieldKey, history.Owner,
    history.OldValue, history.NewValue, history.ChangedAtUtc, history.SentToSaopAtUtc,
    history.UndoOfChangeId, batch.BatchId, batch.ChangeSource, batch.ChangedBy, batch.Note
  FROM pim.ProductFieldHistory AS history
  INNER JOIN pim.ProductChangeBatch AS batch ON batch.ChangeBatchId = history.ChangeBatchId
  WHERE history.OrganizationId = @OrganizationId AND history.ProductId = @ProductId
  ORDER BY history.ChangedAtUtc DESC, history.ChangeId DESC;
END;
');
