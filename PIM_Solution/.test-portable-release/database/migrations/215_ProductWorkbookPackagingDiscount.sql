/*
  215 — S koda (popust na polno pakiranje) v delovnem listu izdelkov.

  Uporabnik 2026-09-15: »pa se ta S pojavi tudi, ko damo izvozni excel pri izdelkih?« Doslej
  jo je nosil samo izvoz za Magento (katalog.csv, stolpec »S popust %«); delovni list
  (Nastavitve -> Izdelki -> Izvozi Excel) je ni izpisal in je uvoz ni znal zapisati.

  Procedura vrne S kodo in odstotek za dane izdelke po canon.ProductId. Tabela
  pim.ProductPackagingDiscount je kljucena na pim.Product (promoviran izdelek), zato gre
  preslikava prek (OrganizationId, ItemID); nepromoviran izdelek vrstice nima.
  Zapis ob uvozu gre skozi pim.SaveProductPackagingDiscount (214).
*/

SET XACT_ABORT ON;

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetProductPackagingDiscounts
  @ProductIdsJson nvarchar(max)
AS
BEGIN
  SET NOCOUNT ON;

  DECLARE @Products TABLE (ProductId bigint NOT NULL PRIMARY KEY);
  INSERT @Products (ProductId)
  SELECT DISTINCT CONVERT(bigint, parsed.value) FROM OPENJSON(@ProductIdsJson) AS parsed
  WHERE ISJSON(parsed.value) = 0 AND TRY_CONVERT(bigint, parsed.value) IS NOT NULL;

  SELECT
    ProductId = product.ProductId,
    DiscountCode = packaging.DiscountCode,
    PercentValue = catalog.PercentValue
  FROM @Products AS wanted
  INNER JOIN canon.Product AS product ON product.ProductId = wanted.ProductId
  INNER JOIN pim.Product AS promoted
    ON promoted.OrganizationId = product.OrganizationId AND promoted.ItemID = product.ItemID
  INNER JOIN pim.ProductPackagingDiscount AS packaging ON packaging.PimProductId = promoted.PimProductId
  LEFT JOIN pim.PackagingDiscountCatalog AS catalog ON catalog.DiscountCode = packaging.DiscountCode;
END;');

IF OBJECT_ID(N'intranet.GetProductPackagingDiscounts', N'P') IS NULL
  THROW 53030, 'intranet.GetProductPackagingDiscounts ni nastala.', 1;
