/*
  Vsem NW. artiklom podjetja 2 (IQLighting) nastavi kljukici "svetila" (svetila_si) in "videlektro".
  Brez preverjanj: aktiven ali ne, s kategorijo ali brez.

  sqlcmd -S <streznik> -d PIM -E -C -I -f 65001 -i NW-kljukici-svetila-videlektro.sql
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRANSACTION;

MERGE pim.ProductWebShop AS target
USING (
  SELECT product.ProductId, shop.WebShopCode
  FROM canon.Product AS product
  CROSS JOIN (VALUES (N'svetila_si'), (N'videlektro')) AS shop(WebShopCode)
  WHERE product.OrganizationId = 2 AND product.ItemID LIKE N'NW.%'
) AS source
  ON target.ProductId = source.ProductId AND target.WebShopCode = source.WebShopCode
WHEN MATCHED AND target.IsPublished = 0
  THEN UPDATE SET IsPublished = 1, ChangedBy = N'skripta NW', ChangedUtc = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
  THEN INSERT (ProductId, WebShopCode, IsPublished, ChangedBy) VALUES (source.ProductId, source.WebShopCode, 1, N'skripta NW');

PRINT CONCAT(N'Spremenjenih kljukic: ', @@ROWCOUNT);

COMMIT;

SELECT shop.WebShopCode, COUNT(*) AS NwSKljukico
FROM pim.ProductWebShop AS shop
INNER JOIN canon.Product AS product ON product.ProductId = shop.ProductId
WHERE product.OrganizationId = 2 AND product.ItemID LIKE N'NW.%' AND shop.IsPublished = 1
GROUP BY shop.WebShopCode;
