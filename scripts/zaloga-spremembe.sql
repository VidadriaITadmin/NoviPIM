/*
  Kaj se je pri zalogi spremenilo med zadnjima posnetkoma istega vira in podjetja (2026-09-15).

  Zaloga nima tabele sprememb. Vsak zajem (NW_STOCK, BT_STOCK, SAOP_*_STOCK) zapiše cel posnetek:

    stock.SyncRun            en tek: prebranih, uporabljenih, v karanteni, čas, stanje
    stock.Snapshot           posnetek tega teka; IsActive = 1 je tisti, ki ga berejo izvoz in strani
    stock.LandingRecord      vsaka prebrana vrstica, tako kot je prišla (besedilo)
    stock.Position           ista vrstica kot število, vezana na artikel (MatchedProductId)
    stock.UnmatchedPosition  vrstica, ki ni našla artikla

  Sprememba je zato razlika med dvema posnetkoma. Ista nespremenjena datoteka ni nov posnetek
  (worker izpiše »Ta posnetek je že v bazi«), zato se primerjata zadnja dva, ki res obstajata.

  Uporaba: v SSMS ali
    sqlcmd -E -S "DAVID\MSSQL19" -d PIM -C -W -i scripts\zaloga-spremembe.sql
  Samo bere. Začasni tabeli izgineta s sejo.
*/
SET NOCOUNT ON;

DECLARE @Vir nvarchar(100) = NULL;   -- npr. N'NW_STOCK' ali N'SAOP_VIDADRIA_STOCK'; NULL = vsi viri
DECLARE @Podjetje int = NULL;        -- npr. 2; NULL = vsa podjetja
DECLARE @Primerov int = 20;          -- koliko artiklov z največjo spremembo izpisati

PRINT '--- 1. Zadnji teki zaloge (stock.SyncRun)';
SELECT TOP (30)
  CONVERT(varchar(19), sr.StartedUtc, 120) AS ZacetekUtc, sc.SourceCode AS Vir, sr.OrganizationId AS Podjetje,
  sr.Status AS Stanje, sr.RecordsRead AS Prebranih, sr.RecordsApplied AS Uporabljenih, sr.RecordsQuarantined AS VKaranteni
FROM stock.SyncRun sr
JOIN map.SourceConnector sc ON sc.SourceConnectorId = sr.SourceConnectorId
WHERE (@Vir IS NULL OR sc.SourceCode = @Vir) AND (@Podjetje IS NULL OR sr.OrganizationId = @Podjetje)
ORDER BY sr.StartedUtc DESC;

IF OBJECT_ID('tempdb..#par') IS NOT NULL DROP TABLE #par;
IF OBJECT_ID('tempdb..#poz') IS NOT NULL DROP TABLE #poz;
IF OBJECT_ID('tempdb..#razlika') IS NOT NULL DROP TABLE #razlika;

WITH ranked AS (
  SELECT s.SnapshotId, s.OrganizationId, s.SourceConnectorId, s.SnapshotUtc,
         ROW_NUMBER() OVER (PARTITION BY s.OrganizationId, s.SourceConnectorId ORDER BY s.SnapshotUtc DESC, s.SnapshotId DESC) AS rn
  FROM stock.Snapshot s
  JOIN map.SourceConnector sc ON sc.SourceConnectorId = s.SourceConnectorId
  WHERE (@Vir IS NULL OR sc.SourceCode = @Vir) AND (@Podjetje IS NULL OR s.OrganizationId = @Podjetje)
)
SELECT cur.OrganizationId, cur.SourceConnectorId, cur.SnapshotId AS CurId, cur.SnapshotUtc AS CurUtc,
       prev.SnapshotId AS PrevId, prev.SnapshotUtc AS PrevUtc
INTO #par
FROM ranked cur
LEFT JOIN ranked prev
  ON prev.OrganizationId = cur.OrganizationId AND prev.SourceConnectorId = cur.SourceConnectorId AND prev.rn = 2
WHERE cur.rn = 1;

-- stock.Position ima milijone vrstic; prebere se enkrat, samo za posnetke, ki se primerjajo.
-- SAOP ima za isti artikel več vrstic (po skladiščih), zato se količina sešteje na artikel.
SELECT p.SnapshotId, p.NormalizedItemId, SUM(p.Quantity) AS Quantity
INTO #poz
FROM stock.Position p
WHERE p.SnapshotId IN (SELECT CurId FROM #par UNION SELECT PrevId FROM #par WHERE PrevId IS NOT NULL)
GROUP BY p.SnapshotId, p.NormalizedItemId;
CREATE INDEX IX_poz ON #poz (SnapshotId) INCLUDE (NormalizedItemId, Quantity);

SELECT par.OrganizationId, par.SourceConnectorId, par.PrevUtc, par.CurUtc,
       COALESCE(d.CurItem, d.PrevItem) AS Artikel,
       d.PrevQuantity AS Prej, d.CurQuantity AS Zdaj,
       CASE WHEN d.PrevItem IS NULL THEN 0 ELSE 1 END AS BilPrej,
       CASE WHEN d.CurItem IS NULL THEN 0 ELSE 1 END AS JeZdaj
INTO #razlika
FROM #par par
CROSS APPLY (
  SELECT c.NormalizedItemId AS CurItem, c.Quantity AS CurQuantity, p.NormalizedItemId AS PrevItem, p.Quantity AS PrevQuantity
  FROM (SELECT NormalizedItemId, Quantity FROM #poz WHERE SnapshotId = par.CurId) c
  FULL JOIN (SELECT NormalizedItemId, Quantity FROM #poz WHERE SnapshotId = par.PrevId) p
    ON p.NormalizedItemId = c.NormalizedItemId
) d;

PRINT '--- 2. Zadnji posnetek proti prejsnjemu, po viru in podjetju';
SELECT r.OrganizationId AS Podjetje, sc.SourceCode AS Vir,
  CONVERT(varchar(16), r.PrevUtc, 120) AS PrejsnjiPosnetekUtc, CONVERT(varchar(16), r.CurUtc, 120) AS ZadnjiPosnetekUtc,
  SUM(CASE WHEN r.BilPrej = 0 AND r.JeZdaj = 1 THEN 1 ELSE 0 END) AS Novih,
  SUM(CASE WHEN r.BilPrej = 1 AND r.JeZdaj = 0 THEN 1 ELSE 0 END) AS Izginilo,
  SUM(CASE WHEN r.BilPrej = 1 AND r.JeZdaj = 1 AND ISNULL(r.Prej, -1) <> ISNULL(r.Zdaj, -1) THEN 1 ELSE 0 END) AS Spremenjenih,
  SUM(CASE WHEN r.BilPrej = 1 AND r.JeZdaj = 1 AND ISNULL(r.Prej, -1) = ISNULL(r.Zdaj, -1) THEN 1 ELSE 0 END) AS Enakih
FROM #razlika r
JOIN map.SourceConnector sc ON sc.SourceConnectorId = r.SourceConnectorId
GROUP BY r.OrganizationId, sc.SourceCode, r.PrevUtc, r.CurUtc
ORDER BY sc.SourceCode, r.OrganizationId;

PRINT '--- 3. Artikli z najvecjo spremembo';
SELECT TOP (@Primerov) sc.SourceCode AS Vir, r.OrganizationId AS Podjetje, r.Artikel,
  r.Prej, r.Zdaj, ISNULL(r.Zdaj, 0) - ISNULL(r.Prej, 0) AS Razlika,
  CASE WHEN r.BilPrej = 0 THEN N'nov' WHEN r.JeZdaj = 0 THEN N'izginil' ELSE N'spremenjen' END AS Kaj
FROM #razlika r
JOIN map.SourceConnector sc ON sc.SourceConnectorId = r.SourceConnectorId
WHERE r.BilPrej = 0 OR r.JeZdaj = 0 OR ISNULL(r.Prej, -1) <> ISNULL(r.Zdaj, -1)
ORDER BY ABS(ISNULL(r.Zdaj, 0) - ISNULL(r.Prej, 0)) DESC, r.Artikel;
