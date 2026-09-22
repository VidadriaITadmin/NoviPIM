/*
  242 — Pripravljenost za splet po dejanskih izvoznih pravilih; povzetek kataloga; zadnji uspeh cikla.

  Uporabnik 2026-09-21: »uporabnik mora v aplikaciji videti dejansko izdelan CSV, iskati artikle in
  razumeti, zakaj artikel je ali ni objavljen« ter »uskladi prikaz /kakovost/artikli z dejanskimi
  izvoznimi pravili: canon.Product.WebPublish; pim.ProductWebShop.IsPublished; ročni zadržki; aktivne
  blokirajoče napake; pravila kategorij; posebno pravilo za artikle brez spletnih mest«.

  Do te migracije je pogled val.ProductChannelReadiness (194/218/236) pripravljenost za splet računal
  iz canon.Product.WebPublish (oznaka iz SAOP), izvoz out.GetExportRows pa vrstico v katalog.csv
  določa po kljukicah spletišč (pim.ProductWebShop.IsPublished, 201), kategoriji na spletišču
  (pim.ProductCategory + canon.WebSite), ročnem zadržku (val.ProductHold ALL/WEB, 194), izključitvi
  (pim.CatalogPolicy.IsExcluded, 204), veljavnosti v profilih, ki blokirajo splet
  (val.ProductValidationState, RequireWebValid) in pravilu 220 (aktiven izdelek brez vsake kljukice
  gre v datoteko s praznim stolpcem »Spletne strani« kot signal za umik). Stran /kakovost/artikli je
  zato lahko kazala »Ni za objavo« pri artiklu, ki je v datoteki, in »Pripravljen« pri artiklu, ki ga
  izvoz izpusti.

  Kaj naredi:
    1. val.ProductChannelReadiness dobi stolpce, izpeljane po ISTIH pravilih kot out.GetExportRows:
         IsPromoted, IsExcludedFromCatalog, SiteFlagCount, SiteCategoryCount, AllowedSiteCount,
         WebExportState (INACTIVE | NOT_PROMOTED | EXCLUDED | HOLD | NO_SITE | PUBLISHED |
                         NO_CATEGORY | BLOCKED_ERRORS) in IsInCatalogCsv.
       IsWebReady odslej zahteva kljukico spletišča namesto WebPublish; WebPublish ostane
       informativen stolpec (»ERP: za splet«). IsErpReady je nespremenjen (236: sveža validacija).
       Pravilo 220 ostane: NO_SITE pomeni vrstico v katalog.csv s praznimi spletnimi stranmi.
    2. intranet.GetQualityProducts vrne nove stolpce, stanje WEB_BLOCKED/READY šteje po kljukicah,
       nova stanja filtra: IN_CSV, NOT_IN_CSV, NO_SITE, PUBLISHED. Seštevki dobijo InCsvCount,
       NoSiteCount, PublishedCount.
    3. intranet.GetProductWebExportState @ProductId: stanje enega artikla in razlog po spletiščih
       (kljukica, kategorija, blokirajoči neveljavni profili) — za kartico artikla.
    4. intranet.GetWebExportSummary @OrganizationId: sestava kataloga za /splet (aktivni, objavljivi,
       vrstic v CSV, brez spletnega mesta, blokirani po razlogu, stranke v stranke.csv).
    5. intranet.GetWorkerCycles vrne LastSucceededUtc (zadnji uspešen zagon, ne samo zadnji poskus).
    6. Podatki: razmik cikla magento-csv 300 -> 900 s in posla WEB_CATALOG_EXPORT 300 -> 3600 s, samo
       kadar je vrednost še privzeta. Izvoz podjetja 2 (89.491 vrstic × 180 stolpcev) traja minute;
       ops.ClaimWorkerCycle prekrivanje sicer prepreči, a pri 300 s bi izvoz tekel neprekinjeno.
       Posel WEB_CATALOG_EXPORT sproži uspešna objava (TriggersDependent), razmik je le rezerva.

  Migrator ne pozna GO, zato CREATE OR ALTER v EXEC(N'...').
*/
SET XACT_ABORT ON;

/* --- 1) Pogled pripravljenosti po izvoznih pravilih ------------------------------------------ */
EXEC(N'CREATE OR ALTER VIEW val.ProductChannelReadiness
AS
/*
  242: stolpci IsPromoted, IsExcludedFromCatalog, SiteFlagCount, SiteCategoryCount, AllowedSiteCount,
  WebExportState, IsInCatalogCsv so izpeljani po istih pravilih kot out.GetExportRows (#Site in veja
  NoSiteStillExported220). IsWebReady zahteva kljukico spletisca (pim.ProductWebShop.IsPublished),
  ne canon.Product.WebPublish. Ostalo kot 218/236 (mnozicni stevci, sveza validacija).
*/
SELECT product.ProductId,product.OrganizationId,product.ItemID,product.EAN,
  ProductName=COALESCE(NULLIF(title.Value,N''''),product.ItemID),
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
  IsPromoted=CONVERT(bit,CASE WHEN promoted.PimProductId IS NULL THEN 0 ELSE 1 END),
  IsExcludedFromCatalog=CONVERT(bit,ISNULL(policy.IsExcluded,0)),
  SiteFlagCount=CONVERT(int,ISNULL(sites.FlagCount,0)),
  SiteCategoryCount=CONVERT(int,ISNULL(sites.CategoryCount,0)),
  AllowedSiteCount=CONVERT(int,ISNULL(sites.AllowedCount,0)),
  WebExportState=CONVERT(nvarchar(20),
    CASE WHEN product.IsActive=0 THEN N''INACTIVE''
         WHEN promoted.PimProductId IS NULL THEN N''NOT_PROMOTED''
         WHEN ISNULL(policy.IsExcluded,0)=1 THEN N''EXCLUDED''
         WHEN ISNULL(holdCount.HasGlobalHold,0)=1 OR ISNULL(holdCount.HasWebHold,0)=1 THEN N''HOLD''
         WHEN ISNULL(sites.FlagCount,0)=0 THEN N''NO_SITE''
         WHEN ISNULL(sites.AllowedCount,0)>0 THEN N''PUBLISHED''
         WHEN ISNULL(sites.CategoryCount,0)=0 THEN N''NO_CATEGORY''
         ELSE N''BLOCKED_ERRORS'' END),
  IsInCatalogCsv=CONVERT(bit,
    CASE WHEN product.IsActive=1 AND promoted.PimProductId IS NOT NULL AND ISNULL(policy.IsExcluded,0)=0
          AND ISNULL(holdCount.HasGlobalHold,0)=0 AND ISNULL(holdCount.HasWebHold,0)=0
          AND (ISNULL(sites.FlagCount,0)=0 OR ISNULL(sites.AllowedCount,0)>0) THEN 1 ELSE 0 END),
  IsErpReady=CONVERT(bit,CASE WHEN product.IsActive=1 AND product.LastValidatedUtc >= DATEADD(hour,-2,SYSUTCDATETIME())
    AND ISNULL(issueCount.ErpBlockingCount,0)=0
    AND ISNULL(holdCount.HasGlobalHold,0)=0 AND ISNULL(holdCount.HasErpHold,0)=0 THEN 1 ELSE 0 END),
  IsWebReady=CONVERT(bit,CASE WHEN product.IsActive=1 AND ISNULL(sites.FlagCount,0)>0
    AND product.LastValidatedUtc >= DATEADD(hour,-2,SYSUTCDATETIME())
    AND ISNULL(issueCount.WebBlockingCount,0)=0
    AND ISNULL(holdCount.HasGlobalHold,0)=0 AND ISNULL(holdCount.HasWebHold,0)=0
    AND ISNULL(policy.IsExcluded,0)=0 THEN 1 ELSE 0 END)
FROM canon.Product AS product
LEFT JOIN canon.ProductText AS title
  ON title.ProductId=product.ProductId AND title.TextType=N''TITLE_ERP'' AND title.Lang=N''sl''
LEFT JOIN pim.Product AS promoted
  ON promoted.OrganizationId=product.OrganizationId AND promoted.ItemID=product.ItemID
LEFT JOIN pim.CatalogPolicy AS policy ON policy.ProductId=product.ProductId
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
) AS issueCount ON issueCount.ProductId=product.ProductId
LEFT JOIN
(
  SELECT ProductId,
    HasGlobalHold=MAX(CASE WHEN ChannelCode=N''ALL'' THEN 1 ELSE 0 END),
    HasErpHold=MAX(CASE WHEN ChannelCode=N''ERP'' THEN 1 ELSE 0 END),
    HasWebHold=MAX(CASE WHEN ChannelCode=N''WEB'' THEN 1 ELSE 0 END)
  FROM val.ProductHold WHERE IsActive=1
  GROUP BY ProductId
) AS holdCount ON holdCount.ProductId=product.ProductId
LEFT JOIN
(
  /* Ista pravila kot #Site v out.GetExportRows: kljukica spletisca (201), kategorija na spletiscu
     istega drevesa (146), VALID v vseh aktivnih profilih, ki blokirajo splet in veljajo za drevo
     (RequireWebValid). Zadrzek, izkljucitev in aktivnost so v WebExportState zgoraj. */
  SELECT shop.ProductId,
    FlagCount=COUNT(*),
    CategoryCount=SUM(siteRule.HasCategory),
    AllowedCount=SUM(CASE WHEN siteRule.HasCategory=1 AND siteRule.InvalidBlocking=0 THEN 1 ELSE 0 END)
  FROM pim.ProductWebShop AS shop
  INNER JOIN canon.Product AS flagProduct ON flagProduct.ProductId=shop.ProductId
  LEFT JOIN pim.Product AS pimProduct
    ON pimProduct.OrganizationId=flagProduct.OrganizationId AND pimProduct.ItemID=flagProduct.ItemID
  CROSS APPLY
  (
    SELECT
      HasCategory=CASE WHEN pimProduct.PimProductId IS NOT NULL AND EXISTS
        (SELECT 1 FROM pim.ProductCategory AS category
         INNER JOIN canon.WebSite AS site ON site.WebSiteCode=category.WebSite AND site.IsActive=1 AND site.CategoryTreeCode=shop.WebShopCode
         WHERE category.PimProductId=pimProduct.PimProductId) THEN 1 ELSE 0 END,
      InvalidBlocking=CASE WHEN EXISTS
        (SELECT 1 FROM val.ValidationProfile AS profile
         LEFT JOIN val.ProductValidationState AS state
           ON state.ProductId=shop.ProductId AND state.ValidationProfileId=profile.ValidationProfileId
         WHERE profile.IsActive=1 AND profile.BlocksWeb=1
           AND (profile.CategoryTreeCode IS NULL OR profile.CategoryTreeCode=shop.WebShopCode)
           AND ISNULL(state.Status,N''INVALID'')<>N''VALID'') THEN 1 ELSE 0 END
  ) AS siteRule
  WHERE shop.IsPublished=1
  GROUP BY shop.ProductId
) AS sites ON sites.ProductId=product.ProductId;');

/* --- 2) Seznam artiklov za /kakovost/artikli ------------------------------------------------ */
EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetQualityProducts
  @OrganizationId int=NULL,@Search nvarchar(200)=NULL,@State nvarchar(30)=NULL,
  @Skip int=0,@Take int=50
AS
BEGIN
  SET NOCOUNT ON;
  SET @Take=CASE WHEN @Take<1 THEN 50 WHEN @Take>200 THEN 200 ELSE @Take END;
  SET @Skip=CASE WHEN @Skip<0 THEN 0 ELSE @Skip END;
  SET @Search=NULLIF(LTRIM(RTRIM(@Search)),N'''');
  DECLARE @Like nvarchar(204)=CASE WHEN @Search IS NULL THEN NULL ELSE N''%''+@Search+N''%'' END;
  /* 242: splet se steje po kljukicah spletisc in WebExportState, ne po WebPublish. */
  SELECT * INTO #Rows FROM val.ProductChannelReadiness
  WHERE IsActive=1 AND (@OrganizationId IS NULL OR OrganizationId=@OrganizationId)
    AND (@Like IS NULL OR ItemID LIKE @Like OR EAN LIKE @Like OR ProductName LIKE @Like)
    AND (@State IS NULL OR @State=N''''
      OR (@State=N''ERP_BLOCKED'' AND IsErpReady=0)
      OR (@State=N''WEB_BLOCKED'' AND SiteFlagCount>0 AND IsWebReady=0)
      OR (@State=N''READY'' AND IsErpReady=1 AND (SiteFlagCount=0 OR IsWebReady=1))
      OR (@State=N''HOLD'' AND (HasGlobalHold=1 OR HasErpHold=1 OR HasWebHold=1))
      OR (@State=N''STALE'' AND IsValidationStale=1)
      OR (@State=N''IN_CSV'' AND IsInCatalogCsv=1)
      OR (@State=N''NOT_IN_CSV'' AND IsInCatalogCsv=0)
      OR (@State=N''NO_SITE'' AND WebExportState=N''NO_SITE'')
      OR (@State=N''PUBLISHED'' AND WebExportState=N''PUBLISHED''));
  SELECT * FROM #Rows ORDER BY
    CASE WHEN HasGlobalHold=1 OR HasErpHold=1 OR HasWebHold=1 THEN 0
         WHEN IsErpReady=0 OR (SiteFlagCount>0 AND IsWebReady=0) THEN 1 ELSE 2 END,
    ItemID OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY;
  SELECT COUNT_BIG(*) TotalCount,
    SUM(CASE WHEN IsErpReady=1 THEN 1 ELSE 0 END) ErpReadyCount,
    SUM(CASE WHEN IsErpReady=0 THEN 1 ELSE 0 END) ErpBlockedCount,
    SUM(CASE WHEN IsWebReady=1 THEN 1 ELSE 0 END) WebReadyCount,
    SUM(CASE WHEN SiteFlagCount>0 AND IsWebReady=0 THEN 1 ELSE 0 END) WebBlockedCount,
    SUM(CASE WHEN HasGlobalHold=1 OR HasErpHold=1 OR HasWebHold=1 THEN 1 ELSE 0 END) HoldCount,
    SUM(CASE WHEN IsValidationStale=1 THEN 1 ELSE 0 END) StaleCount,
    SUM(CASE WHEN IsInCatalogCsv=1 THEN 1 ELSE 0 END) InCsvCount,
    SUM(CASE WHEN WebExportState=N''NO_SITE'' THEN 1 ELSE 0 END) NoSiteCount,
    SUM(CASE WHEN WebExportState=N''PUBLISHED'' THEN 1 ELSE 0 END) PublishedCount
  FROM #Rows;
END;');

/* --- 3) En artikel: stanje in razlog po spletiscih (kartica artikla) ------------------------ */
EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetProductWebExportState
  @ProductId bigint
AS
BEGIN
  SET NOCOUNT ON;
  /* 1. nabor: vrstica pogleda (isti stolpci kot na /kakovost/artikli). */
  SELECT * FROM val.ProductChannelReadiness WHERE ProductId=@ProductId;

  /* 2. nabor: vsako aktivno spletisce posebej — kljukica, kategorija, neveljavni blokirajoci profili.
     IsAllowed pomeni: to spletisce bi bilo v stolpcu "Spletne strani" (brez zadrzka/izkljucitve,
     ki veljata za cel artikel in sta v 1. naboru). */
  DECLARE @PimProductId bigint=
    (SELECT TOP(1) promoted.PimProductId FROM canon.Product AS product
     INNER JOIN pim.Product AS promoted ON promoted.OrganizationId=product.OrganizationId AND promoted.ItemID=product.ItemID
     WHERE product.ProductId=@ProductId);
  SELECT site.WebSiteCode, site.WebSiteName, site.CategoryTreeCode, site.TreeLabel, site.SortOrder,
    IsChecked=CONVERT(bit,CASE WHEN EXISTS (SELECT 1 FROM pim.ProductWebShop AS shop
      WHERE shop.ProductId=@ProductId AND shop.WebShopCode=site.CategoryTreeCode AND shop.IsPublished=1) THEN 1 ELSE 0 END),
    HasCategory=CONVERT(bit,CASE WHEN @PimProductId IS NOT NULL AND EXISTS (SELECT 1 FROM pim.ProductCategory AS category
      WHERE category.PimProductId=@PimProductId AND category.WebSite=site.WebSiteCode) THEN 1 ELSE 0 END),
    InvalidBlockingProfiles=(SELECT STRING_AGG(profile.ProfileCode, N'', '') WITHIN GROUP (ORDER BY profile.ProfileCode)
      FROM val.ValidationProfile AS profile
      LEFT JOIN val.ProductValidationState AS state
        ON state.ProductId=@ProductId AND state.ValidationProfileId=profile.ValidationProfileId
      WHERE profile.IsActive=1 AND profile.BlocksWeb=1
        AND (profile.CategoryTreeCode IS NULL OR profile.CategoryTreeCode=site.CategoryTreeCode)
        AND ISNULL(state.Status,N''INVALID'')<>N''VALID'')
  INTO #Sites
  FROM canon.WebSite AS site
  WHERE site.IsActive=1;
  SELECT WebSiteCode, WebSiteName, CategoryTreeCode, TreeLabel, IsChecked, HasCategory, InvalidBlockingProfiles,
    IsAllowed=CONVERT(bit,CASE WHEN IsChecked=1 AND HasCategory=1 AND InvalidBlockingProfiles IS NULL THEN 1 ELSE 0 END)
  FROM #Sites ORDER BY SortOrder, WebSiteCode;
END;');

/* --- 4) Sestava kataloga za /splet ---------------------------------------------------------- */
EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetWebExportSummary
  @OrganizationId int
AS
BEGIN
  SET NOCOUNT ON;
  SELECT
    ActiveCount=COUNT_BIG(*),
    PromotedCount=SUM(CASE WHEN IsPromoted=1 THEN 1 ELSE 0 END),
    PublishedCount=SUM(CASE WHEN WebExportState=N''PUBLISHED'' THEN 1 ELSE 0 END),
    InCsvCount=SUM(CASE WHEN IsInCatalogCsv=1 THEN 1 ELSE 0 END),
    NoSiteCount=SUM(CASE WHEN WebExportState=N''NO_SITE'' THEN 1 ELSE 0 END),
    NotPromotedCount=SUM(CASE WHEN WebExportState=N''NOT_PROMOTED'' THEN 1 ELSE 0 END),
    ExcludedCount=SUM(CASE WHEN WebExportState=N''EXCLUDED'' THEN 1 ELSE 0 END),
    HoldCount=SUM(CASE WHEN WebExportState=N''HOLD'' THEN 1 ELSE 0 END),
    NoCategoryCount=SUM(CASE WHEN WebExportState=N''NO_CATEGORY'' THEN 1 ELSE 0 END),
    BlockedErrorsCount=SUM(CASE WHEN WebExportState=N''BLOCKED_ERRORS'' THEN 1 ELSE 0 END),
    StaleCount=SUM(CASE WHEN IsValidationStale=1 THEN 1 ELSE 0 END),
    OldestValidationUtc=MIN(LastValidatedUtc),
    CustomerCount=(SELECT COUNT_BIG(*) FROM b2b.Customer AS customer
      INNER JOIN pim.CustomerWebProfile AS profile ON profile.CustomerId=customer.CustomerId
      WHERE customer.OrganizationId=@OrganizationId AND customer.IsActive=1)
  FROM val.ProductChannelReadiness
  WHERE OrganizationId=@OrganizationId AND IsActive=1;
END;');

/* --- 5) Cikli: zadnji uspeh poleg zadnjega poskusa ------------------------------------------ */
EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetWorkerCycles
AS
BEGIN
  SET NOCOUNT ON;
  SELECT c.CycleKey, c.Label, c.SortOrder, c.IsEnabled, c.IntervalSeconds, c.DailyAtLocal, c.WarnAfterMultiplier,
         c.NextDueUtc, c.RunningRunId, c.RunningSinceUtc, c.RunningHost,
         c.LastStartedUtc, c.LastEndedUtc, c.LastStatus, c.LastExitCode, c.LastDurationMs, c.LastTriggeredBy, c.LastHost,
         c.LastStepsFailed, c.LastError, c.UpdatedUtc, c.UpdatedBy,
         run.CurrentStep AS RunningStep, run.HeartbeatUtc AS RunningHeartbeatUtc,
         (SELECT COUNT(*) FROM ops.Alert a WHERE a.AlertKind = N''CycleOverdue'' AND a.Pipeline = CONCAT(N''CIKEL:'', c.CycleKey) AND a.ResolvedUtc IS NULL) AS OpenOverdueAlerts,
         /* 242: zadnji USPESEN zagon, ne samo zadnji poskus (LastStartedUtc/LastStatus). */
         (SELECT MAX(ok.EndedUtc) FROM ops.WorkerCycleRun ok WHERE ok.CycleKey = c.CycleKey AND ok.Status = N''Succeeded'') AS LastSucceededUtc
  FROM ops.WorkerCycle c
  LEFT JOIN ops.WorkerCycleRun run ON run.WorkerCycleRunId = c.RunningRunId
  ORDER BY c.SortOrder, c.CycleKey;
END;');

/* --- 6) Realen razmik: samo, kadar je vrednost se privzeta ---------------------------------- */
UPDATE ops.WorkerCycle SET IntervalSeconds = 900, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = N'migracija 242'
WHERE CycleKey = N'magento-csv' AND IntervalSeconds = 300;

IF OBJECT_ID(N'ops.JobDefinition', N'U') IS NOT NULL
  UPDATE ops.JobDefinition SET IntervalSeconds = 3600, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = N'migracija 242'
  WHERE JobKey = N'WEB_CATALOG_EXPORT' AND IntervalSeconds = 300;
