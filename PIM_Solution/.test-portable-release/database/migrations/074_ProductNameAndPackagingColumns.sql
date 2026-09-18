/*
  074 — naziv artikla in mere pakiranja pridejo v izvoz.

  Dvoje, kar je po 072/073 postalo vidno v stevilkah:

  1. pim.Product.Name je bil NULL pri vseh izdelkih. val.Promote ga je bral samo iz spletnega
     naziva (WEB_TITLE, sl), teh pa je v katalogu ena sama vrstica. Stolpec 'Naziv artikla' v
     izvozu je bil zato prazen pri vseh 43.503 izdelkih, ceprav naziv obstaja — 196.515 vrstic
     TITLE_ERP. Odslej velja: spletni naziv, ce obstaja, sicer ERP naziv istega jezika.

  2. Trgovinski podatki so od ponovne preslikave v katalogu (canon.ProductCommercial ima
     196.513 vrstic namesto ene), stolpci predloge pa so bili brez kanonicne kode, zato so
     ostali prazni: volumen, dolzina/sirina/visina paketa in njihove enote ter kolicina v
     osnovnem pakiranju.

  Enoti teze (stolpca 13 in 15) namenoma ostajata brez vira: SAOP poslje tezo brez enote in
  ugibati je ne smemo. Ce je vedno kilogram, je to ena vrstica registra in tvoja beseda.
*/

SET XACT_ABORT ON;

/* --- 1) naziv artikla ------------------------------------------------------- */

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
    WHEN MATCHED THEN UPDATE SET EAN = source.EAN, Name = source.Name, Manufacturer = source.Manufacturer, PromotedUtc = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT (OrganizationId, ItemID, EAN, Name, Manufacturer)
      VALUES (source.OrganizationId, source.ItemID, source.EAN, source.Name, source.Manufacturer);

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
      SELECT o.PimProductId, a.AttributeCode, a.Value
      FROM @Objavljeni o INNER JOIN canon.ProductAttribute a ON a.ProductId = o.ProductId
    ) AS source ON target.PimProductId = source.PimProductId AND target.AttributeCode = source.AttributeCode
    WHEN MATCHED THEN UPDATE SET Value = source.Value
    WHEN NOT MATCHED THEN INSERT (PimProductId, AttributeCode, Value)
      VALUES (source.PimProductId, source.AttributeCode, source.Value);

    MERGE pim.ProductCommercial AS target
    USING
    (
      SELECT o.PimProductId, k.NetWeight, k.GrossWeight, k.CustomsTariff, k.CountryOfOrigin, k.Pak1, k.Pak2, k.Dimensions
      FROM @Objavljeni o INNER JOIN canon.ProductCommercial k ON k.ProductId = o.ProductId
    ) AS source ON target.PimProductId = source.PimProductId
    WHEN MATCHED THEN UPDATE SET NetWeight = source.NetWeight, GrossWeight = source.GrossWeight,
      CustomsTariff = source.CustomsTariff, CountryOfOrigin = source.CountryOfOrigin,
      Pak1 = source.Pak1, Pak2 = source.Pak2, Dimensions = source.Dimensions
    WHEN NOT MATCHED THEN INSERT (PimProductId, NetWeight, GrossWeight, CustomsTariff, CountryOfOrigin, Pak1, Pak2, Dimensions)
      VALUES (source.PimProductId, source.NetWeight, source.GrossWeight, source.CustomsTariff, source.CountryOfOrigin,
              source.Pak1, source.Pak2, source.Dimensions);

    COMMIT TRANSACTION;
  END TRY
  BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
  END CATCH;
END;
');

/* --- 2) stolpci mer in pakiranja dobijo vir --------------------------------- */

DECLARE @ProductProfileId int =
  (SELECT ExportProfileId FROM out.ExportProfile WHERE ProfileCode = N'MAGENTO_PRODUCTS');

MERGE out.ExportColumn AS target
USING (VALUES
  (N'Volumen',              N'Product.Volume'),
  (N'Dolžina paketa',       N'Product.PackageLength'),
  (N'Širina paketa',        N'Product.PackageWidth'),
  (N'Višina paketa',        N'Product.PackageHeight'),
  (N'Enota dolžine paketa', N'Product.DimensionUnit'),
  (N'Enota širine paketa',  N'Product.DimensionUnit'),
  (N'Enota višine paketa',  N'Product.DimensionUnit'),
  (N'PAK1',                 N'Product.Pak1')
) AS source(OutputColumnName, CanonicalFieldCode)
  ON target.ExportProfileId = @ProductProfileId AND target.OutputColumnName = source.OutputColumnName
WHEN MATCHED THEN UPDATE SET CanonicalFieldCode = source.CanonicalFieldCode;

/* --- 3) preverbi ------------------------------------------------------------ */

IF NOT EXISTS
(
  SELECT 1 FROM sys.sql_modules
  WHERE object_id = OBJECT_ID(N'val.Promote') AND definition LIKE N'%TITLE_ERP%'
)
  THROW 52741, 'val.Promote ne pozna ERP naziva kot rezerve.', 1;

IF
(
  SELECT COUNT(*) FROM out.ExportColumn
  WHERE ExportProfileId = @ProductProfileId AND IsActive = 1
    AND CanonicalFieldCode IN (N'Product.Volume', N'Product.PackageLength', N'Product.PackageWidth',
                               N'Product.PackageHeight', N'Product.DimensionUnit')
) < 7
  THROW 52742, 'Stolpci mer pakiranja niso dobili vira.', 1;
