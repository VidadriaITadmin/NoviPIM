/*
  258 — viri poslov iz bloka 6 prenove nadzora (faze v preostalih workerjih).

  Uporabnik 2026-09-22: »jaz moram vsaki korak imeti pod nadzorom in videti da se vse izvede«. Blok 6 je
  naučil faze še PIM.XmlFileWorker, PIM.SaopOrdersWorker, PIM.B2bWorker in PIM.StockReplenishmentWorker
  (poleg PIM.KatalogWorker PRESLIKAVA/MEJNIK, nadzornika, razpošiljanja alarmov in SQL korakov gostitelja).
  Ta migracija pove, katere od teh faz so VIRI s pragom svežine — isti seznam kot JobCatalog.cs
  (JobCatalog.All[*].Sources); gostitelj ga ob zagonu uskladi sam (ops.EnsureJobSource, SortOrder po vrsti
  v kodi), tu je zasejan, da ga stran Nadzor in alarm SourceStale vidita že pred ponovnim zagonom.

  Viri (Pipeline | SourceCode — natanko to, kar worker zapiše v ops.JobPhaseRun):
    SAOP_ORDER_IMPORT          SAOP_ORDERS_VNK | SAOP_ORDERS_VNK        2 h, stik, po podjetjih
                               SAOP_ORDERS_VND | SAOP_ORDERS_VND        2 h, stik, po podjetjih
    WEB_CATALOG_EXPORT         MAGENTO_PRODUCTS | MAGENTO_PRODUCTS      2 h, stik, NE po podjetjih (izvoz je samo za podjetje 2)
    WEB_STOCK_EXPORT           MAGENTO_STOCK_PRICES | MAGENTO_STOCK_PRICES  1 h, stik, po podjetjih
    NIGHTLY_RECONCILIATION     GENERIC_XML | NW_XML                     7 dni, stik, po podjetjih
                               GENERIC_XML | BT_XML                     36 h, stik, po podjetjih
    STOCK_REPLENISHMENT_DIGEST STOCK_REPLENISHMENT_DIGEST | STOCK_REPLENISHMENT_DIGEST  36 h, stik, po podjetjih

  Stik (MeasureNewData = 0): šteje zadnja uspešna faza, tudi brez novih podatkov — ura brez novega naročila
  ali ista datoteka dobavitelja ni napaka. Preskok (npr. podjetje brez knjige naročil) NI stik.

  Idempotentno: ops.EnsureJobSource je MERGE; ponovni zagon ne spremeni ničesar.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

IF OBJECT_ID(N'ops.EnsureJobSource', N'P') IS NULL OR OBJECT_ID(N'ops.JobSourceState', N'IF') IS NULL
  THROW 52580, N'258: ops.EnsureJobSource ali ops.JobSourceState ne obstaja (najprej migracija 256).', 1;

DECLARE @kdo nvarchar(200) = N'258_ViriBloka6';
EXEC ops.EnsureJobSource N'SAOP_ORDER_IMPORT', N'SAOP_ORDERS_VNK', N'SAOP_ORDERS_VNK', N'Naročila kupcev (VNK)', 7200, 1, 0, 1, @kdo;
EXEC ops.EnsureJobSource N'SAOP_ORDER_IMPORT', N'SAOP_ORDERS_VND', N'SAOP_ORDERS_VND', N'Naročila dobaviteljem (VND)', 7200, 1, 0, 2, @kdo;
EXEC ops.EnsureJobSource N'WEB_CATALOG_EXPORT', N'MAGENTO_PRODUCTS', N'MAGENTO_PRODUCTS', N'katalog.csv za splet', 7200, 0, 0, 1, @kdo;
EXEC ops.EnsureJobSource N'WEB_STOCK_EXPORT', N'MAGENTO_STOCK_PRICES', N'MAGENTO_STOCK_PRICES', N'magento-stock-prices.csv za splet', 3600, 1, 0, 1, @kdo;
EXEC ops.EnsureJobSource N'NIGHTLY_RECONCILIATION', N'SAOP_DELIVERY', N'SAOP_DELIVERY', N'Datumi dobave iz SAOP', 129600, 1, 0, 1, @kdo;
EXEC ops.EnsureJobSource N'NIGHTLY_RECONCILIATION', N'NW_XML', N'GENERIC_XML', N'Nowodvorski XML (katalog)', 604800, 1, 0, 2, @kdo;
EXEC ops.EnsureJobSource N'NIGHTLY_RECONCILIATION', N'BT_XML', N'GENERIC_XML', N'Braytron XML (katalog)', 129600, 1, 0, 3, @kdo;
EXEC ops.EnsureJobSource N'STOCK_REPLENISHMENT_DIGEST', N'STOCK_REPLENISHMENT_DIGEST', N'STOCK_REPLENISHMENT_DIGEST', N'Dnevni mail o zalogi pod MID', 129600, 1, 0, 1, @kdo;

/* ── Preverjanje ────────────────────────────────────────────────────────────────── */
IF (SELECT COUNT(*) FROM ops.JobSource js
    INNER JOIN (VALUES
      (N'SAOP_ORDER_IMPORT', N'SAOP_ORDERS_VNK', N'SAOP_ORDERS_VNK'),
      (N'SAOP_ORDER_IMPORT', N'SAOP_ORDERS_VND', N'SAOP_ORDERS_VND'),
      (N'WEB_CATALOG_EXPORT', N'MAGENTO_PRODUCTS', N'MAGENTO_PRODUCTS'),
      (N'WEB_STOCK_EXPORT', N'MAGENTO_STOCK_PRICES', N'MAGENTO_STOCK_PRICES'),
      (N'NIGHTLY_RECONCILIATION', N'GENERIC_XML', N'NW_XML'),
      (N'NIGHTLY_RECONCILIATION', N'GENERIC_XML', N'BT_XML'),
      (N'STOCK_REPLENISHMENT_DIGEST', N'STOCK_REPLENISHMENT_DIGEST', N'STOCK_REPLENISHMENT_DIGEST')
    ) AS v (JobKey, Pipeline, SourceCode)
      ON v.JobKey = js.JobKey AND v.Pipeline = js.Pipeline AND v.SourceCode = js.SourceCode
    WHERE js.IsActive = 1) <> 7
  THROW 52581, N'258: viri bloka 6 niso vsi zasejani (manjka posel v ops.JobDefinition?).', 1;
