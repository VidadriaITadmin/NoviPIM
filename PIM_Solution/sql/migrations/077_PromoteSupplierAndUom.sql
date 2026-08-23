/*
  077 — dobavitelj in merska enota prideta do izvoza.

  Stolpca 7 ('Dobavitelj') in 9 ('Merska enota') sta bila prazna, cepravta podatka v katalogu
  obstajata od prvega zajema: canon.Product.Supplier in canon.Product.UoM sta preslikana iz
  StockData/SupplierID in GeneralData/ItemUnitOfMeas.

  Zakaj nista prisla skozi: objava (pim.Product) ju ni poznala. Tabela ima sifro, EAN, naziv in
  proizvajalca — dobavitelja in enote ni bilo, izvoz pa bere objavo, ne kataloga. Isti razred
  napake kot 058 in 075: podatek je v katalogu, objava ga ne nese naprej.

  Merska enota je hkrati obvezno polje profila ERP_L1_SLO, zato je bila njena odsotnost v izvozu
  se posebej zavajajoca: validacija je izdelek priznala, izvoz pa je stolpec pustil prazen.
*/

SET XACT_ABORT ON;

IF COL_LENGTH(N'pim.Product', N'Supplier') IS NULL
  ALTER TABLE pim.Product ADD Supplier nvarchar(100) NULL;
IF COL_LENGTH(N'pim.Product', N'UoM') IS NULL
  ALTER TABLE pim.Product ADD UoM nvarchar(50) NULL;

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
      SELECT o.PimProductId, a.AttributeCode, a.Value
      FROM @Objavljeni o INNER JOIN canon.ProductAttribute a ON a.ProductId = o.ProductId
    ) AS source ON target.PimProductId = source.PimProductId AND target.AttributeCode = source.AttributeCode
    WHEN MATCHED THEN UPDATE SET Value = source.Value
    WHEN NOT MATCHED THEN INSERT (PimProductId, AttributeCode, Value)
      VALUES (source.PimProductId, source.AttributeCode, source.Value);

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

DECLARE @ProductProfileId int =
  (SELECT ExportProfileId FROM out.ExportProfile WHERE ProfileCode = N'MAGENTO_PRODUCTS');

MERGE out.ExportColumn AS target
USING (VALUES
  (N'Dobavitelj',   N'Product.Supplier'),
  (N'Merska enota', N'Product.UoM')
) AS source(OutputColumnName, CanonicalFieldCode)
  ON target.ExportProfileId = @ProductProfileId AND target.OutputColumnName = source.OutputColumnName
WHEN MATCHED THEN UPDATE SET CanonicalFieldCode = source.CanonicalFieldCode;

/* --- preverbi ---------------------------------------------------------------- */

IF COL_LENGTH(N'pim.Product', N'UoM') IS NULL OR COL_LENGTH(N'pim.Product', N'Supplier') IS NULL
  THROW 52771, 'Objava se vedno ne pozna dobavitelja ali merske enote.', 1;

IF
(
  SELECT COUNT(*) FROM out.ExportColumn
  WHERE ExportProfileId = @ProductProfileId AND IsActive = 1
    AND CanonicalFieldCode IN (N'Product.Supplier', N'Product.UoM')
) <> 2
  THROW 52772, 'Stolpca dobavitelja in merske enote nista dobila vira.', 1;
