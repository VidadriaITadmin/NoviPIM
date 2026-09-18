/*
  203 — stock.GetBelowMidReplenishment vrne cela stevila, ne decimalke (uporabnikova zahteva
  2026-09-15: "ne moremo imeti pol kosa na zalogi"). Prejsnja migracija (202) je izpis samo
  skrajsala na decimal(19,2) — to je bil premajhen popravek, uporabnik hoce int.

  Nameščenih migracij se ne ureja (glej docs/DATABASE.md); popravek je nova stevilka, ne urejanje
  migracije 202.
*/

SET XACT_ABORT ON;

EXEC(N'
CREATE OR ALTER PROCEDURE stock.GetBelowMidReplenishment @OrganizationId int
AS
BEGIN
  SET NOCOUNT ON;

  ;WITH trenutna AS
  (
    SELECT position.MatchedProductId AS ProductId, SUM(position.Quantity) AS CurrentStock
    FROM stock.Position position
    INNER JOIN stock.Snapshot snapshot ON snapshot.SnapshotId = position.SnapshotId
    WHERE snapshot.OrganizationId = @OrganizationId AND snapshot.IsActive = 1 AND position.MatchedProductId IS NOT NULL
    GROUP BY position.MatchedProductId
  ),
  odprtoVnk AS
  (
    SELECT product.ProductId, SUM(line.Qty - line.ShippedQTY) AS OpenQty
    FROM sales.OrderLine line
    INNER JOIN sales.OrderHeader header ON header.OrderHeaderId = line.OrderHeaderId
    INNER JOIN canon.Product product ON product.OrganizationId = header.OrganizationId AND product.ItemID = line.ItemID
    WHERE header.OrganizationId = @OrganizationId AND ISNULL(line.ClosedLine, 0) = 0
    GROUP BY product.ProductId
  ),
  odprtoVnd AS
  (
    SELECT product.ProductId, SUM(line.OrderedQuantity) AS OpenQty
    FROM purch.PurchaseOrderLine line
    INNER JOIN purch.PurchaseOrderHeader header ON header.PurchaseOrderHeaderId = line.PurchaseOrderHeaderId
    INNER JOIN canon.Product product ON product.OrganizationId = header.OrganizationId AND product.ItemID = line.ItemID
    WHERE header.OrganizationId = @OrganizationId AND ISNULL(line.CanceledLine, 0) = 0
      AND ISNULL(header.Status, N'''') <> N''Zaključeno''
    GROUP BY product.ProductId
  )
  SELECT
    product.ItemID,
    ItemName = imeArtikla.Value,
    Supplier = product.Supplier,
    SupplierName = partner.PartnerName,
    Department = product.Department,
    CurrentStock = CONVERT(int, ROUND(ISNULL(trenutna.CurrentStock, 0), 0)),
    MaximumStock = CONVERT(int, ROUND(policy.MaximumStock, 0)),
    MidStock = CONVERT(int, ROUND(policy.MidStock, 0)),
    MinimumStock = CONVERT(int, ROUND(policy.MinimumStock, 0)),
    AvailableStock = CONVERT(int, ROUND(ISNULL(trenutna.CurrentStock, 0) - ISNULL(vnk.OpenQty, 0), 0)),
    IncomingPurchaseQty = CONVERT(int, ROUND(vnd.OpenQty, 0))
  FROM canon.Product product
  OUTER APPLY
  (
    SELECT TOP(1) policyValue.MinimumStock, policyValue.MaximumStock, policyValue.MidStock
    FROM canon.ProductStockPolicy policyValue
    WHERE policyValue.ProductId = product.ProductId
    ORDER BY policyValue.WarehouseCode
  ) policy
  LEFT JOIN trenutna ON trenutna.ProductId = product.ProductId
  LEFT JOIN odprtoVnk vnk ON vnk.ProductId = product.ProductId
  LEFT JOIN odprtoVnd vnd ON vnd.ProductId = product.ProductId
  LEFT JOIN canon.PartnerName partner ON partner.OrganizationId = product.OrganizationId AND partner.PartnerCode = product.Supplier
  OUTER APPLY
  (
    SELECT TOP(1) textValue.Value
    FROM canon.ProductText textValue
    WHERE textValue.ProductId = product.ProductId AND textValue.TextType IN (N''TITLE_ERP'', N''WEB_TITLE'')
    ORDER BY CASE WHEN textValue.TextType = N''TITLE_ERP'' THEN 0 ELSE 1 END,
      CASE WHEN textValue.Lang = N''sl'' THEN 0 ELSE 1 END, textValue.Lang
  ) imeArtikla
  WHERE product.OrganizationId = @OrganizationId
    AND policy.MidStock IS NOT NULL
    AND (ISNULL(trenutna.CurrentStock, 0) - ISNULL(vnk.OpenQty, 0)) <= policy.MidStock
  ORDER BY product.Supplier, product.Department, product.ItemID;
END;
');

IF OBJECT_ID(N'stock.GetBelowMidReplenishment') IS NULL
  THROW 52950, N'203: stock.GetBelowMidReplenishment manjka.', 1;
