/*
  202 — dobaviteljevo ime v stock.GetBelowMidReplenishment (uporabnikova zahteva 2026-09-15).

  canon.Product.Supplier je surova SAOP šifra partnerja (npr. "91086973"), ne ime. Ime je ze
  loceno sinhronizirano v canon.PartnerName (OrganizationId, PartnerCode, PartnerName) — ista
  sifra kot pri strankah/dobaviteljih, preverjeno na zivih podatkih (91086973 -> "ViD Adria
  d.o.o.", 33199795 -> "EDIITO d.o.o.", 00001504 -> "UAB Lighting Line").

  IncomingPurchaseQty ostaja NULL za vse vrstice, dokler je purch.PurchaseOrderLine prazna (VND
  zajem je blokiran na dostopu servisnega racuna ApiMagento do SAOP Order/PurchaseOrders modulov,
  glej docs/DATABASE.md migracija 199/200) — to ni napaka te migracije.

  Kolicinski stolpci se tu pretvorijo na decimal(19,2) samo za izpis tega porocila (uporabnikova
  zahteva 2026-09-15: "dve decimalki, ne stiri") — osnovne tabele (canon.ProductStockPolicy ipd.)
  ostanejo pri decimal(19,4), to ni sprememba podatkovnega modela.

  Naziv artikla (canon.ProductText, TextType TITLE_ERP/WEB_TITLE) je vec-jezicen (Lang stolpec).
  Prejsnja razlicica te procedure (znotraj iste migracije, popravljeno pred uporabo) ni izbirala
  po jeziku, zato je TOP(1) nakljucno vrnil nemski/anglaski/slovenski zapis — popravljeno tako, da
  po tipu besedila prednost dobi Lang=''sl'' (isti vzorec kot obstojeci intranet.GetStockPositions).
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
    CurrentStock = CONVERT(decimal(19,2), ISNULL(trenutna.CurrentStock, 0)),
    MaximumStock = CONVERT(decimal(19,2), policy.MaximumStock),
    MidStock = CONVERT(decimal(19,2), policy.MidStock),
    MinimumStock = CONVERT(decimal(19,2), policy.MinimumStock),
    AvailableStock = CONVERT(decimal(19,2), ISNULL(trenutna.CurrentStock, 0) - ISNULL(vnk.OpenQty, 0)),
    IncomingPurchaseQty = CONVERT(decimal(19,2), vnd.OpenQty)
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
  THROW 52940, N'202: stock.GetBelowMidReplenishment manjka.', 1;
IF OBJECT_ID(N'canon.PartnerName') IS NULL
  THROW 52941, N'202: canon.PartnerName ne obstaja; SupplierName se ne bi izpolnil.', 1;
