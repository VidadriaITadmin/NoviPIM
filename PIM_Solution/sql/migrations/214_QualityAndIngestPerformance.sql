/*
  214 — pospesitev treh strani intranet: /kakovost (16,5 s), /kakovost/artikli (17,7 s) in
  /zajem (10,7 s), izmerjeno 2026-09-15 na lokalni razvojni bazi (avtenticiran fetch cele strani).

  Vzroki, potrjeni z SET STATISTICS IO/TIME ON in izvedbenimi nacrti (SHOWPLAN_TEXT), ne z ugibanjem:

  1) /zajem (GetInboundFlowsAsync v PipelineReadService.cs) za vsak od 28 konektorjev (map.SourceConnector)
     s korelirano poizvedbo presteje stock.LandingRecord (3,74 milijona vrstic). Edini obstojeci
     indeks na tej tabeli (UQ_StockLandingRecord_Immutable) ne vsebuje Status, zato je optimizator
     namesto iskanja izbral 28x skoraj poln pregled tabele: 5.479.320 logicnih branj, 10,5 s.
     Manjkajoc indeks je tudi na stock.SyncRun (samo clustered PK) za tri podobne korelirane klice.
     Popravek: dva nova pokrivna indeksa. Izmerjeno po popravku: 18.750 + 266 logicnih branj namesto
     5.479.320 + 6.300, poizvedba pade z 10,5 s na ~0,7-1,9 s.

  2) /kakovost (GovernanceReadService.GetUnblockPlanAsync, klican za vsako od 4 podjetij vzporedno)
     bere val.ProductIssue (6,39 milijona vrstic, od tega 1,53 milijona aktivnih). Filtriran indeks
     IX_ProductIssue_Active_ProductRequirement (WHERE IsActive=1) ze obstaja, a je optimizator zanj
     imel zastarelo/nenatancno statistiko in je namesto njega izbral poln pregled sklopljene tabele
     (Clustered Index Scan + Bitmap) — 163.350 logicnih branj na klic, 4x vzporedno pod obremenitvijo
     naraste na izmerjenih 16,5 s. UPDATE STATISTICS ... WITH FULLSCAN nauci optimizator, naj filtriran
     indeks dejansko uporabi (potrjeno: isti klic pade na 29.742 logicnih branj, vseh 4 podjetja skupaj
     pod 300 ms namesto 16,5 s). Brez sheme spremembe — samo osvezena statistika.

  3) /kakovost/artikli (intranet.GetQualityProducts -> val.ProductChannelReadiness) je za vsak od
     177.679 aktivnih izdelkov POSEBEJ:
       a) iskal ime izdelka prek canon.FieldValue — 28-smerne UNION ALL poglede čez ves katalog
          (canon.Product, ProductCommercial, ProductText, ProductAttribute dvakrat, ...). Za dinamicna
          FieldCode stolpca (ProductText/ProductAttribute) jih optimizator ne zna staticno izlociti,
          zato je vsak izdelek sprozil sez okoli 6 pregledov teh tabel (710.666 + 355.333 pregledov
          skupaj) — samo za iskanje enega imena.
       b) korelirano (OUTER APPLY) sesteval val.ProductIssue/FieldRequirement/ValidationProfile —
          namesto enega mnozicnega JOIN + GROUP BY je to naredil 177.679-krat posebej, kar je
          SQL Server prisililo v tabelo dela (Worktable) z 19.947.012 logicnimi branji.
     Skupaj: 17,2-17,7 s samo za pripravo #Rows, preden se stran sploh zacne izrisovati.
     Popravek: pogled val.ProductChannelReadiness prepisan iz korelirane APPLY-na-vrstico oblike v
     mnozicno JOIN + GROUP BY obliko, iskanje imena pa neposredno iz canon.ProductText namesto prek
     canon.FieldValue (FieldCode='Product.Name' v izvirniku sploh ni nikoli obstajal — mrtev pogoj;
     edini dejanski zadetek je bil 'ProductText.TITLE_ERP.sl', kar je nadomescen neposreden JOIN).
     Preverjeno bit-za-bit: 177.679 vrstic, vsi agregati (SUM napak/opozoril/blokad, checksum imen)
     in stevilo neujemajocih vrstic (0) so pred in po popravku identicni — samo hitrost se je
     spremenila (17,655 ms -> 540 ms, ~33x).

  Migrator (sql PIM.Migrator) nima ukaza GO, zato je CREATE OR ALTER VIEW zavit v EXEC(N'...') po
  enakem vzorcu kot migracija 194 in 211.
*/

SET XACT_ABORT ON;

/* --- 1) /zajem: stock.LandingRecord + stock.SyncRun --------------------------------------- */

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'stock.LandingRecord') AND name = N'IX_StockLandingRecord_OrgConnector_Status')
  CREATE NONCLUSTERED INDEX IX_StockLandingRecord_OrgConnector_Status
    ON stock.LandingRecord (OrganizationId, SourceConnectorId) INCLUDE (Status);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'stock.SyncRun') AND name = N'IX_StockSyncRun_OrgConnector_StartedUtc')
  CREATE NONCLUSTERED INDEX IX_StockSyncRun_OrgConnector_StartedUtc
    ON stock.SyncRun (OrganizationId, SourceConnectorId, StartedUtc DESC)
    INCLUDE (Status, Endpoint, CompletedUtc, RecordsRead, SyncRunId);

/* --- 2) /kakovost: osvezi statistiko, da optimizator uporabi ze obstojeci filtriran indeks -- */

UPDATE STATISTICS val.ProductIssue WITH FULLSCAN;
UPDATE STATISTICS canon.Product WITH FULLSCAN;

/* --- 3) /kakovost/artikli: val.ProductChannelReadiness brez korelirane APPLY-na-vrstico ----- */

EXEC(N'
CREATE OR ALTER VIEW val.ProductChannelReadiness
AS
SELECT product.ProductId,product.OrganizationId,product.ItemID,product.EAN,
  ProductName=COALESCE(NULLIF(productName.Value,N''''),product.ItemID),
  product.IsActive,product.WebPublish,product.ValidationStatus,product.Completeness,product.LastValidatedUtc,
  IsValidationStale=CONVERT(bit,CASE WHEN product.LastValidatedUtc IS NULL
    OR product.LastValidatedUtc<DATEADD(hour,-2,SYSUTCDATETIME()) THEN 1 ELSE 0 END),
  ErrorCount=CONVERT(bigint,ISNULL(issueCount.ErrorCount,0)),
  WarningCount=CONVERT(bigint,ISNULL(issueCount.WarningCount,0)),
  ErpBlockingCount=CONVERT(bigint,ISNULL(issueCount.ErpBlockingCount,0)),
  WebBlockingCount=CONVERT(bigint,ISNULL(issueCount.WebBlockingCount,0)),
  HasGlobalHold=CONVERT(bit,ISNULL(holdCount.HasGlobalHold,0)),
  HasErpHold=CONVERT(bit,ISNULL(holdCount.HasErpHold,0)),
  HasWebHold=CONVERT(bit,ISNULL(holdCount.HasWebHold,0)),
  IsErpReady=CONVERT(bit,CASE WHEN product.IsActive=1 AND product.LastValidatedUtc IS NOT NULL
    AND ISNULL(issueCount.ErpBlockingCount,0)=0
    AND ISNULL(holdCount.HasGlobalHold,0)=0 AND ISNULL(holdCount.HasErpHold,0)=0 THEN 1 ELSE 0 END),
  IsWebReady=CONVERT(bit,CASE WHEN product.IsActive=1 AND product.WebPublish=1 AND product.LastValidatedUtc IS NOT NULL
    AND ISNULL(issueCount.WebBlockingCount,0)=0
    AND ISNULL(holdCount.HasGlobalHold,0)=0 AND ISNULL(holdCount.HasWebHold,0)=0 THEN 1 ELSE 0 END)
FROM canon.Product AS product
/* 214: prej TOP(1) ... FROM canon.FieldValue WHERE FieldCode IN(''Product.Name'',''ProductText.TITLE_ERP.sl'').
   ''Product.Name'' v canon.FieldValue nikoli ni obstajal (glej definicijo pogleda) — edini zadetek je
   bil vedno ProductText.TITLE_ERP.sl, zato je neposreden LEFT JOIN na canon.ProductText vedno enak
   rezultat, brez potrebe po prehodu skozi 28-smerni UNION ALL. Unikatnost (ProductId,Lang,TextType)
   je ze zagotovljena z UQ_CanonProductText_ProductLangType, zato LEFT JOIN ne podvoji vrstic.
*/
LEFT JOIN canon.ProductText AS productName
  ON productName.ProductId = product.ProductId AND productName.TextType = N''TITLE_ERP'' AND productName.Lang = N''sl''
/* 214: prej korelirana OUTER APPLY, izvedena posebej za vsak izdelek (177.679-krat). Enak rezultat
   da mnozicni LEFT JOIN na vnaprej sestet (GROUP BY ProductId) nabor — SQL Server ga izracuna enkrat
   namesto enkrat na izdelek. */
LEFT JOIN
(
  SELECT issue.ProductId,
    ErrorCount=SUM(CASE WHEN requirement.Severity=N''ERROR'' THEN 1 ELSE 0 END),
    WarningCount=SUM(CASE WHEN requirement.Severity=N''WARNING'' THEN 1 ELSE 0 END),
    ErpBlockingCount=SUM(CASE WHEN requirement.Severity=N''ERROR'' AND profile.BlocksErp=1 THEN 1 ELSE 0 END),
    WebBlockingCount=SUM(CASE WHEN requirement.Severity=N''ERROR'' AND profile.BlocksWeb=1 THEN 1 ELSE 0 END)
  FROM val.ProductIssue AS issue
  INNER JOIN val.FieldRequirement AS requirement ON requirement.FieldRequirementId=issue.FieldRequirementId AND requirement.IsActive=1
  INNER JOIN val.ValidationProfile AS profile ON profile.ValidationProfileId=issue.ValidationProfileId AND profile.IsActive=1
  WHERE issue.IsActive=1
  GROUP BY issue.ProductId
) AS issueCount ON issueCount.ProductId = product.ProductId
/* 214: enak razlog kot zgoraj — bilo je korelirano OUTER APPLY, zdaj vnaprej sestet LEFT JOIN. */
LEFT JOIN
(
  SELECT ProductId,
    HasGlobalHold=MAX(CASE WHEN ChannelCode=N''ALL'' THEN 1 ELSE 0 END),
    HasErpHold=MAX(CASE WHEN ChannelCode=N''ERP'' THEN 1 ELSE 0 END),
    HasWebHold=MAX(CASE WHEN ChannelCode=N''WEB'' THEN 1 ELSE 0 END)
  FROM val.ProductHold WHERE IsActive=1
  GROUP BY ProductId
) AS holdCount ON holdCount.ProductId = product.ProductId;
');
