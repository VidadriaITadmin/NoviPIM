/*
  200 — MID izracun, poizvedba "pod MID" in dnevni e-mail po dobavitelju (MIN_MAX_proces.docx).

  Uporabnik je 2026-09-14 dal konkretno v1 formulo (ni vec odprto vprasanje iz nacrta):
  MidStock = zaokrozeno na celo stevilo povprecje MinimumStock in MaximumStock (obstojeci, iz SAOP
  prek migracije 076). Opozorilo gre, ko RazpolozljivaZaloga <= MidStock.

  RazpolozljivaZaloga = trenutna zaloga (stock.Position, migracija 065/103) MINUS odprta kolicina
  na naročilih kupcev (sales.OrderLine, migracija 199; vrstica je "odprta", ko ClosedLine=0).
  Odprta kolicina na naročilih dobaviteljem (purch.PurchaseOrderLine) je SAMO informativni stolpec
  v mailu (uporabnik je to izrecno tako povedal) — ne vstopa v primerjavo z MID.

  "Zakljuceno" kot merilo za odprt VND je hevristika iz edinega zivega primera, ki smo ga videli
  (PurchaseOrderHeader.Status = "Zakljuceno" za popolnoma prevzeto narocilo) — ce se v praksi pojavi
  vec vrednosti statusa, jih je treba dodati sem.

  "ABC klasifikacija" v mailu je namenoma canon.Product.Department: prava izracunana ABC
  klasifikacija (Faza 3 nacrta) se sploh se ne obstaja, Department pa je ze v obstojecem UI
  oznacen kot "ABC klasifikacija/Oddelek" (SaopFieldLabels.cs) — ista poenostavitev, ne nova.

  Prejemniki: NE dobaviteljevi kontakti (tistih ne hranimo), ampak PIM uporabniki, ki so za to
  izrecno odkljukani (sec.LocalUser.ReceivesStockReplenishmentEmail) — uporabnikova zahteva.
*/

SET XACT_ABORT ON;

/* --- 1) odkljukanje prejemnika na uporabniku ----------------------------------- */

IF COL_LENGTH(N'sec.LocalUser', N'ReceivesStockReplenishmentEmail') IS NULL
  ALTER TABLE sec.LocalUser ADD ReceivesStockReplenishmentEmail bit NOT NULL CONSTRAINT DF_LocalUser_ReceivesStockReplenishmentEmail DEFAULT (0);

/* --- 2) MID = zaokrozeno povprecje MIN/MAX ------------------------------------- */

EXEC(N'
CREATE OR ALTER PROCEDURE stock.RefreshStockPolicyMid
AS
BEGIN
  SET NOCOUNT ON;
  UPDATE canon.ProductStockPolicy
  SET MidStock = ROUND((MinimumStock + MaximumStock) / 2.0, 0), UpdatedUtc = SYSUTCDATETIME()
  WHERE MinimumStock IS NOT NULL AND MaximumStock IS NOT NULL
    AND (MidStock IS NULL OR MidStock <> ROUND((MinimumStock + MaximumStock) / 2.0, 0));
  SELECT Posodobljenih = @@ROWCOUNT;
END;
');

/* --- 3) artikli, kjer je razpolozljiva zaloga <= MID --------------------------- */

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
    Department = product.Department,
    CurrentStock = ISNULL(trenutna.CurrentStock, 0),
    policy.MaximumStock, policy.MidStock, policy.MinimumStock,
    AvailableStock = ISNULL(trenutna.CurrentStock, 0) - ISNULL(vnk.OpenQty, 0),
    IncomingPurchaseQty = vnd.OpenQty
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
  OUTER APPLY
  (
    SELECT TOP(1) textValue.Value
    FROM canon.ProductText textValue
    WHERE textValue.ProductId = product.ProductId AND textValue.TextType IN (N''TITLE_ERP'', N''WEB_TITLE'')
    ORDER BY CASE WHEN textValue.TextType = N''TITLE_ERP'' THEN 0 ELSE 1 END
  ) imeArtikla
  WHERE product.OrganizationId = @OrganizationId
    AND policy.MidStock IS NOT NULL
    AND (ISNULL(trenutna.CurrentStock, 0) - ISNULL(vnk.OpenQty, 0)) <= policy.MidStock
  ORDER BY product.Supplier, product.Department, product.ItemID;
END;
');

/* --- 4) razpored (enkrat na dan, ponoci) ---------------------------------------- */

MERGE ops.ScheduleProfile AS target
USING
(
  SELECT organization.OrganizationId, N'LOCAL' AS Provider, N'STOCK_REPLENISHMENT_DIGEST' AS Pipeline,
    86400 AS IntervalSeconds, 129600 AS StaleAfterSeconds, 5000 AS LockTimeoutMilliseconds
  FROM dbo.OrganizationConfig organization
  WHERE EXISTS (SELECT 1 FROM map.SourceConnector connector WHERE connector.OrganizationId=organization.OrganizationId AND connector.ConnectorType=N'SAOP' AND connector.IsActive=1)
) source
  ON target.OrganizationId = source.OrganizationId AND target.Pipeline = source.Pipeline
WHEN NOT MATCHED THEN
  INSERT (OrganizationId, Provider, Pipeline, IsEnabled, IntervalSeconds, StaleAfterSeconds, LockTimeoutMilliseconds, UpdatedBy)
  VALUES (source.OrganizationId, source.Provider, source.Pipeline, 1, source.IntervalSeconds,
          source.StaleAfterSeconds, source.LockTimeoutMilliseconds, N'migracija 200');

/* --- 5) preverbe ----------------------------------------------------------------- */

IF COL_LENGTH(N'sec.LocalUser', N'ReceivesStockReplenishmentEmail') IS NULL
  THROW 52930, N'200: sec.LocalUser.ReceivesStockReplenishmentEmail manjka.', 1;
IF OBJECT_ID(N'stock.RefreshStockPolicyMid') IS NULL
  THROW 52931, N'200: stock.RefreshStockPolicyMid manjka.', 1;
IF OBJECT_ID(N'stock.GetBelowMidReplenishment') IS NULL
  THROW 52932, N'200: stock.GetBelowMidReplenishment manjka.', 1;
IF (SELECT COUNT(*) FROM ops.ScheduleProfile WHERE Pipeline=N'STOCK_REPLENISHMENT_DIGEST' AND IsEnabled=1) < 1
  THROW 52933, N'200: razpored STOCK_REPLENISHMENT_DIGEST ni omogocen za nobeno organizacijo.', 1;
