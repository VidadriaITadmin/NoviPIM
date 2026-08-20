/*
  Pregled podatkov v razvojni bazi PIM.
  Odpri v SSMS (strežnik: lokalna instanca, baza: PIM) in poženi celoto (F5).
  Skripta samo bere; ničesar ne spreminja.
*/
SET NOCOUNT ON;

PRINT '=== 1. Kdaj je kateri worker nazadnje tekel (ops.PipelineRun) ===';
SELECT Pipeline, OrganizationId, SourceCode, Status,
       COUNT(*)            AS Zagonov,
       SUM(RowsRead)       AS PrebranihVrstic,
       SUM(RowsSucceeded)  AS UspesnihVrstic,
       CONVERT(varchar(19), MAX(StartedUtc), 120) AS ZadnjiZagonUtc
FROM ops.PipelineRun
GROUP BY Pipeline, OrganizationId, SourceCode, Status
ORDER BY MAX(StartedUtc) DESC;

PRINT ' ';
PRINT '=== 2. Surovi zajem (raw.Inbox) — kaj je prišlo noter ===';
SELECT OrganizationId, SourceCode, EntityType, Status, COUNT(*) AS Zapisov,
       CONVERT(varchar(19), MAX(ReceivedUtc), 120) AS ZadnjiUtc
FROM raw.Inbox
GROUP BY OrganizationId, SourceCode, EntityType, Status
ORDER BY OrganizationId, SourceCode, EntityType;

PRINT ' ';
PRINT '=== 3. Kanonicni katalog (canon.Product) — koliko izdelkov na podjetje ===';
SELECT p.OrganizationId, o.Name AS Podjetje, COUNT(*) AS Izdelkov,
       SUM(CASE WHEN p.ValidationStatus = 'VALID'   THEN 1 ELSE 0 END) AS Veljavnih,
       SUM(CASE WHEN p.ValidationStatus = 'INVALID' THEN 1 ELSE 0 END) AS Neveljavnih,
       SUM(CASE WHEN p.EAN IS NOT NULL AND p.EAN <> '' THEN 1 ELSE 0 END) AS ZEan
FROM canon.Product p
LEFT JOIN dbo.OrganizationConfig o ON o.OrganizationId = p.OrganizationId
GROUP BY p.OrganizationId, o.Name
ORDER BY COUNT(*) DESC;

PRINT ' ';
PRINT '=== 4. Napolnjenost polj v canon.Product ===';
SELECT COUNT(*) AS Vseh,
       SUM(CASE WHEN EAN          IS NOT NULL AND EAN          <> '' THEN 1 ELSE 0 END) AS EAN,
       SUM(CASE WHEN Manufacturer IS NOT NULL AND Manufacturer <> '' THEN 1 ELSE 0 END) AS Proizvajalec,
       SUM(CASE WHEN Supplier     IS NOT NULL AND Supplier     <> '' THEN 1 ELSE 0 END) AS Dobavitelj,
       SUM(CASE WHEN ItemGroup    IS NOT NULL AND ItemGroup    <> '' THEN 1 ELSE 0 END) AS Skupina,
       SUM(CASE WHEN UoM          IS NOT NULL AND UoM          <> '' THEN 1 ELSE 0 END) AS EnotaMere
FROM canon.Product;

PRINT ' ';
PRINT '=== 5. Kaj visi na izdelkih (koliko izdelkov ima naziv/ceno/medij/kategorijo/atribut) ===';
SELECT (SELECT COUNT(DISTINCT ProductId) FROM canon.ProductText)      AS ZNazivom,
       (SELECT COUNT(DISTINCT ProductId) FROM canon.ProductPrice)     AS SCeno,
       (SELECT COUNT(DISTINCT ProductId) FROM canon.ProductMedia)     AS ZMedijem,
       (SELECT COUNT(DISTINCT ProductId) FROM canon.ProductCategory)  AS SKategorijo,
       (SELECT COUNT(DISTINCT ProductId) FROM canon.ProductAttribute) AS ZAtributom;

PRINT ' ';
PRINT '=== 6. Kaj se NI preslikalo (map.UnmappedValue) ===';
SELECT Reason AS Razlog, COUNT(*) AS Zapisov
FROM map.UnmappedValue
GROUP BY Reason
ORDER BY COUNT(*) DESC;

PRINT ' ';
PRINT '=== 7. Validacijske napake (val.ProductIssue) ===';
SELECT IssueCode, COUNT(*) AS Vseh, SUM(CASE WHEN IsActive = 1 THEN 1 ELSE 0 END) AS Aktivnih
FROM val.ProductIssue
GROUP BY IssueCode
ORDER BY COUNT(*) DESC;

PRINT ' ';
PRINT '=== 8. Potrjeni katalog (pim.Product) ===';
SELECT OrganizationId, COUNT(*) AS Izdelkov,
       CONVERT(varchar(19), MAX(PromotedUtc), 120) AS ZadnjaPromocijaUtc
FROM pim.Product
GROUP BY OrganizationId;

PRINT ' ';
PRINT '=== 9. Zaloge (stock) ===';
SELECT (SELECT COUNT(*) FROM stock.LandingRecord)     AS SurovihVrstic,
       (SELECT COUNT(*) FROM stock.Snapshot)          AS Posnetkov,
       (SELECT COUNT(*) FROM stock.Position)          AS Pozicij,
       (SELECT COUNT(*) FROM stock.Position WHERE MatchedProductId IS NOT NULL) AS UjetihNaIzdelek,
       (SELECT COUNT(*) FROM stock.UnmatchedPosition) AS Neujetih;

PRINT ' ';
PRINT '=== 10. Konfigurirani viri (map.SourceConnector) in podjetja ===';
SELECT c.SourceConnectorId, c.OrganizationId, o.Name AS Podjetje,
       c.SourceCode, c.ConnectorType, c.IsActive
FROM map.SourceConnector c
LEFT JOIN dbo.OrganizationConfig o ON o.OrganizationId = c.OrganizationId
ORDER BY c.OrganizationId, c.SourceCode;

PRINT ' ';
PRINT '=== 11. Zadnjih 20 izdelkov, da vidis kako izgledajo ===';
SELECT TOP 20 p.ProductId, p.OrganizationId, p.ItemID, p.EAN, p.Manufacturer, p.UoM, p.ValidationStatus,
       (SELECT TOP 1 t.Value FROM canon.ProductText t WHERE t.ProductId = p.ProductId ORDER BY t.ProductTextId) AS Naziv
FROM canon.Product p
ORDER BY p.ProductId DESC;
