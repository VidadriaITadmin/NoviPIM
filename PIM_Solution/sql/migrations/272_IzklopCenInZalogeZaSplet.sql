/*
  272 — izklop posla WEB_STOCK_EXPORT (Cene in zaloga za splet).

  Uporabnik 2026-09-23: »jaz rabim samo katalog.csv in stranke.csv«. Posel je vsakih ~15 min pisal
  magento-stock-prices.csv v podmape <EXPORT_ROOT>\2, \3, \4 — splet jih ne bere, cene in zaloga
  so že v katalog.csv. V kodi (JobCatalog) je posel odslej privzeto izklopljen, Nadzor ga kaže sivo.

  Ročni korak: po uvedbi lahko pobrišeš podmape 2, 3 in 4 v EXPORT_ROOT (na PRD
  C:\inetpub\wwwroot\PIM_exports_csv). katalog.csv in stranke.csv ostaneta v korenu.
*/
SET XACT_ABORT ON;

UPDATE ops.JobDefinition
SET IsEnabled = 0, NextDueUtc = NULL, RequestedRunUtc = NULL,
    UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = N'272_IzklopCenInZalogeZaSplet'
WHERE JobKey = N'WEB_STOCK_EXPORT' AND IsEnabled = 1;
