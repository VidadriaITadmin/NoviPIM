/* 318_HitrejsaKakovostArtikli — rezervirano za nalogo #102 (razvijalec #102, 2026-09-30 14:09). */
/*
  318 — /kakovost in /kakovost/artikli brez 26-73 s cakanja (naloga #102).

  intranet.GetQualityProducts (zadnja definicija 264) je naredil SELECT * INTO #Rows iz pogleda
  val.ProductChannelReadiness za vse aktivne izdelke (~160.000) in sele nato razvrstil in presteval.
  Pogled za vsak izdelek sestavi naziv, stevce napak, zadrzke, kljukice spletisc s kategorijo in
  veljavnostjo profilov ter odjavno okno 251 (korelirana poizvedba na out.WebPublication za vsako
  vrstico). Na DEV: CPU 13-14 s, cas 5-73 s (odvisno od obremenitve baze). Gola /kakovost preusmeri
  na /kakovost/artikli, zato je bila pocasna tudi ona.

  Zdaj procedura po korakih v ozkih zacasnih tabelah izracuna samo tisto, kar potrebujeta
  razvrstitev, filter stanja in stevci na vrhu strani:
    #Org, #P (izdelki v obsegu + iskanje), #Issue (samo blokirajoce napake), #Shop/#Sites (~12.000 kljukic),
    #Hold, #Withdrawal (odjavno okno enkrat na podjetje), #R (stanje na izdelek).
  Polne vrstice pogleda (isti stolpci kot doslej) se preberejo samo za @Take izdelkov na strani.
  Pravila so enaka kot v val.ProductChannelReadiness (242/251); pogled ostane nespremenjen
  (bere ga tudi kartica izdelka). Ob spremembi pravil v pogledu popravi tudi to proceduro.

  Novo: stanje, ki ni eno od zgornjih, se primerja s stanjem za katalog.csv (WebExportState), zato
  povezave s /splet in /splet/umaknjeni (npr. stanje=BLOCKED_ERRORS, NO_CATEGORY) vrnejo artikle
  namesto praznega seznama. Parametri in izhodni stolpci so enaki kot v 264.

  DEV (primerjava stara/nova, 7 kombinacij filtrov): enaki stevci in enake vrstice;
  cas vsa podjetja 2,0-4,0 s (prej 5-30 s), PUBLISHED 3,7 s (prej 47 s), iskanje 1,0 s (prej 7,4 s),
  merjeno pod obremenitvijo drugih sej.
  SAOP: nic (samo branje). Rocni korak: ne. Ponovljivo: da.
  Razveljavitev: ponovno zazeni definicijo procedure iz 264.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;

IF OBJECT_ID(N'val.ProductChannelReadiness', N'V') IS NULL
  THROW 53180, N'318: najprej mora biti uveljavljena 242 (val.ProductChannelReadiness).', 1;
IF OBJECT_ID(N'out.WebPublication', N'U') IS NULL
  THROW 53181, N'318: najprej mora biti uveljavljena 251 (out.WebPublication).', 1;

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetQualityProducts
  @OrganizationId int=NULL,@Search nvarchar(200)=NULL,@State nvarchar(30)=NULL,
  @Skip int=0,@Take int=50
AS
BEGIN
  SET NOCOUNT ON;
  SET @Take=CASE WHEN @Take<1 THEN 50 WHEN @Take>200 THEN 200 ELSE @Take END;
  SET @Skip=CASE WHEN @Skip<0 THEN 0 ELSE @Skip END;
  SET @Search=NULLIF(LTRIM(RTRIM(@Search)),N'''');
  SET @State=NULLIF(LTRIM(RTRIM(@State)),N'''');
  DECLARE @Like nvarchar(204)=CASE WHEN @Search IS NULL THEN NULL ELSE N''%''+@Search+N''%'' END;
  DECLARE @Now datetime2(7)=SYSUTCDATETIME();
  DECLARE @Fresh datetime2(7)=DATEADD(hour,-2,@Now);

  /* Izdelki v obsegu (aktivni; vsa podjetja = samo aktivna podjetja, 264). Podjetja najprej v
     zacasno tabelo: IN (SELECT ...) je sicer prebral OrganizationConfig enkrat na izdelek. */
  CREATE TABLE #Org (OrganizationId int NOT NULL PRIMARY KEY);
  INSERT #Org (OrganizationId)
  SELECT aktivno.OrganizationId FROM dbo.OrganizationConfig AS aktivno
  WHERE (@OrganizationId IS NULL AND aktivno.IsActive=1) OR aktivno.OrganizationId=@OrganizationId;
  IF @OrganizationId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM #Org) INSERT #Org (OrganizationId) VALUES (@OrganizationId);

  CREATE TABLE #P (ProductId bigint NOT NULL PRIMARY KEY, OrganizationId int NOT NULL,
    ItemID nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL, LastValidatedUtc datetime2(7) NULL);
  INSERT #P (ProductId,OrganizationId,ItemID,LastValidatedUtc)
  SELECT product.ProductId,product.OrganizationId,product.ItemID,product.LastValidatedUtc
  FROM #Org AS org
  INNER JOIN canon.Product AS product ON product.OrganizationId=org.OrganizationId
  WHERE product.IsActive=1
    AND (@Like IS NULL OR product.ItemID LIKE @Like OR product.EAN LIKE @Like
      OR EXISTS (SELECT 1 FROM canon.ProductText AS title WHERE title.ProductId=product.ProductId
                 AND title.TextType=N''TITLE_ERP'' AND title.Lang=N''sl'' AND NULLIF(title.Value,N'''') LIKE @Like));

  /* Stevci blokad (kot issueCount v val.ProductChannelReadiness; stejejo samo napake). */
  CREATE TABLE #Issue (ProductId bigint NOT NULL PRIMARY KEY, ErpBlocking int NOT NULL, WebBlocking int NOT NULL);
  INSERT #Issue (ProductId,ErpBlocking,WebBlocking)
  SELECT issue.ProductId,
    SUM(CASE WHEN profile.BlocksErp=1 THEN 1 ELSE 0 END),
    SUM(CASE WHEN profile.BlocksWeb=1 THEN 1 ELSE 0 END)
  FROM val.ProductIssue AS issue
  INNER JOIN #P AS p ON p.ProductId=issue.ProductId
  INNER JOIN val.FieldRequirement AS requirement ON requirement.FieldRequirementId=issue.FieldRequirementId
    AND requirement.IsActive=1 AND requirement.Severity=N''ERROR''
  INNER JOIN val.ValidationProfile AS profile ON profile.ValidationProfileId=issue.ValidationProfileId AND profile.IsActive=1
  WHERE issue.IsActive=1 AND (profile.BlocksErp=1 OR profile.BlocksWeb=1)
  GROUP BY issue.ProductId;

  /* Kljukice spletisc (kot sites v pogledu = #Site v out.GetExportRows): kljukica spletisca (201),
     kategorija na spletiscu istega drevesa (146), VALID v vseh aktivnih profilih, ki blokirajo splet in
     veljajo za drevo. Po korakih nad ~12.000 kljukicami namesto korelirane poizvedbe cez ves pogled. */
  CREATE TABLE #Shop (ProductId bigint NOT NULL, WebShopCode nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL,
    PimProductId bigint NULL, HasCategory bit NOT NULL DEFAULT 0, InvalidBlocking bit NOT NULL DEFAULT 0,
    PRIMARY KEY (ProductId,WebShopCode));
  INSERT #Shop (ProductId,WebShopCode,PimProductId)
  SELECT shop.ProductId,shop.WebShopCode,pimProduct.PimProductId
  FROM pim.ProductWebShop AS shop
  INNER JOIN #P AS p ON p.ProductId=shop.ProductId
  LEFT JOIN pim.Product AS pimProduct ON pimProduct.OrganizationId=p.OrganizationId AND pimProduct.ItemID=p.ItemID
  WHERE shop.IsPublished=1;

  UPDATE s SET HasCategory=1
  FROM #Shop AS s
  WHERE s.PimProductId IS NOT NULL AND EXISTS
    (SELECT 1 FROM pim.ProductCategory AS category
     INNER JOIN canon.WebSite AS site ON site.WebSiteCode=category.WebSite AND site.IsActive=1 AND site.CategoryTreeCode=s.WebShopCode
     WHERE category.PimProductId=s.PimProductId);

  UPDATE s SET InvalidBlocking=1
  FROM #Shop AS s
  WHERE EXISTS
    (SELECT 1 FROM val.ValidationProfile AS profile
     WHERE profile.IsActive=1 AND profile.BlocksWeb=1
       AND (profile.CategoryTreeCode IS NULL OR profile.CategoryTreeCode=s.WebShopCode)
       AND NOT EXISTS (SELECT 1 FROM val.ProductValidationState AS state
                       WHERE state.ProductId=s.ProductId AND state.ValidationProfileId=profile.ValidationProfileId
                         AND state.Status=N''VALID''));

  CREATE TABLE #Sites (ProductId bigint NOT NULL PRIMARY KEY, FlagCount int NOT NULL, CategoryCount int NOT NULL, AllowedCount int NOT NULL);
  INSERT #Sites (ProductId,FlagCount,CategoryCount,AllowedCount)
  SELECT ProductId, COUNT(*), SUM(CONVERT(int,HasCategory)),
    SUM(CASE WHEN HasCategory=1 AND InvalidBlocking=0 THEN 1 ELSE 0 END)
  FROM #Shop GROUP BY ProductId;

  /* Rocni in samodejni zadrzki (malo vrstic). */
  CREATE TABLE #Hold (ProductId bigint NOT NULL PRIMARY KEY, HasGlobalHold bit NOT NULL, HasErpHold bit NOT NULL, HasWebHold bit NOT NULL);
  INSERT #Hold (ProductId,HasGlobalHold,HasErpHold,HasWebHold)
  SELECT hold.ProductId,
    MAX(CASE WHEN hold.ChannelCode=N''ALL'' THEN 1 ELSE 0 END),
    MAX(CASE WHEN hold.ChannelCode=N''ERP'' THEN 1 ELSE 0 END),
    MAX(CASE WHEN hold.ChannelCode=N''WEB'' THEN 1 ELSE 0 END)
  FROM val.ProductHold AS hold WHERE hold.IsActive=1
  GROUP BY hold.ProductId;

  /* Odjavne vrstice 251: prej objavljeni v odjavnem oknu podjetja. */
  CREATE TABLE #Withdrawal (OrganizationId int NOT NULL, ItemID nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL, PRIMARY KEY (OrganizationId,ItemID));
  INSERT #Withdrawal (OrganizationId,ItemID)
  SELECT publication.OrganizationId,publication.ItemID
  FROM out.WebPublication AS publication
  LEFT JOIN pim.WebPublicationPolicy AS policy251 ON policy251.OrganizationId=publication.OrganizationId
  WHERE publication.WithdrawnUtc IS NULL
     OR publication.WithdrawnUtc>=DATEADD(day,-ISNULL(policy251.WithdrawalRowDays,14),@Now);

  /* En prehod: ista pravila kot val.ProductChannelReadiness (242/251) za aktivne izdelke. */
  CREATE TABLE #R (ProductId bigint NOT NULL PRIMARY KEY, ItemID nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL,
    SortGroup tinyint NOT NULL, IsErpReady bit NOT NULL, IsWebReady bit NOT NULL, SiteFlagCount int NOT NULL,
    HasHold bit NOT NULL, IsStale bit NOT NULL, IsInCatalogCsv bit NOT NULL, WebExportState nvarchar(20) COLLATE DATABASE_DEFAULT NOT NULL);
  INSERT #R (ProductId,ItemID,SortGroup,IsErpReady,IsWebReady,SiteFlagCount,HasHold,IsStale,IsInCatalogCsv,WebExportState)
  SELECT x.ProductId,x.ItemID,
    CASE WHEN x.HasHold=1 THEN 0 WHEN x.IsErpReady=0 OR (x.FlagCount>0 AND x.IsWebReady=0) THEN 1 ELSE 2 END,
    x.IsErpReady,x.IsWebReady,x.FlagCount,x.HasHold,x.IsStale,x.IsInCatalogCsv,x.WebExportState
  FROM #P AS p
  LEFT JOIN #Issue AS issue ON issue.ProductId=p.ProductId
  LEFT JOIN #Sites AS sites ON sites.ProductId=p.ProductId
  LEFT JOIN pim.Product AS promoted ON promoted.OrganizationId=p.OrganizationId AND promoted.ItemID=p.ItemID
  LEFT JOIN pim.CatalogPolicy AS policy ON policy.ProductId=p.ProductId
  LEFT JOIN #Withdrawal AS withdrawal251 ON withdrawal251.OrganizationId=p.OrganizationId AND withdrawal251.ItemID=p.ItemID
  LEFT JOIN #Hold AS holdCount ON holdCount.ProductId=p.ProductId
  CROSS APPLY
  (
    SELECT p.ProductId,p.ItemID,
      FlagCount=ISNULL(sites.FlagCount,0),
      HasHold=CONVERT(bit,CASE WHEN ISNULL(holdCount.HasGlobalHold,0)=1 OR ISNULL(holdCount.HasErpHold,0)=1 OR ISNULL(holdCount.HasWebHold,0)=1 THEN 1 ELSE 0 END),
      IsStale=CONVERT(bit,CASE WHEN p.LastValidatedUtc IS NULL OR p.LastValidatedUtc<@Fresh THEN 1 ELSE 0 END),
      IsErpReady=CONVERT(bit,CASE WHEN p.LastValidatedUtc>=@Fresh AND ISNULL(issue.ErpBlocking,0)=0
        AND ISNULL(holdCount.HasGlobalHold,0)=0 AND ISNULL(holdCount.HasErpHold,0)=0 THEN 1 ELSE 0 END),
      IsWebReady=CONVERT(bit,CASE WHEN ISNULL(sites.FlagCount,0)>0 AND p.LastValidatedUtc>=@Fresh
        AND ISNULL(issue.WebBlocking,0)=0 AND ISNULL(holdCount.HasGlobalHold,0)=0 AND ISNULL(holdCount.HasWebHold,0)=0
        AND ISNULL(policy.IsExcluded,0)=0 THEN 1 ELSE 0 END),
      WebExportState=CONVERT(nvarchar(20),
        CASE WHEN promoted.PimProductId IS NULL THEN N''NOT_PROMOTED''
             WHEN ISNULL(policy.IsExcluded,0)=1 THEN N''EXCLUDED''
             WHEN ISNULL(holdCount.HasGlobalHold,0)=1 OR ISNULL(holdCount.HasWebHold,0)=1 THEN N''HOLD''
             WHEN ISNULL(sites.FlagCount,0)=0 THEN N''NO_SITE''
             WHEN ISNULL(sites.AllowedCount,0)>0 THEN N''PUBLISHED''
             WHEN ISNULL(sites.CategoryCount,0)=0 THEN N''NO_CATEGORY''
             ELSE N''BLOCKED_ERRORS'' END),
      IsInCatalogCsv=CONVERT(bit,
        CASE WHEN promoted.PimProductId IS NOT NULL AND ISNULL(policy.IsExcluded,0)=0
              AND ISNULL(holdCount.HasGlobalHold,0)=0 AND ISNULL(holdCount.HasWebHold,0)=0
              AND ISNULL(sites.AllowedCount,0)>0 THEN 1
             WHEN promoted.PimProductId IS NOT NULL AND withdrawal251.ItemID IS NOT NULL THEN 1 ELSE 0 END)
  ) AS x
  WHERE @State IS NULL
    OR (@State=N''ERP_BLOCKED'' AND x.IsErpReady=0)
    OR (@State=N''WEB_BLOCKED'' AND x.FlagCount>0 AND x.IsWebReady=0)
    OR (@State=N''READY'' AND x.IsErpReady=1 AND (x.FlagCount=0 OR x.IsWebReady=1))
    OR (@State=N''HOLD'' AND x.HasHold=1)
    OR (@State=N''STALE'' AND x.IsStale=1)
    OR (@State=N''IN_CSV'' AND x.IsInCatalogCsv=1)
    OR (@State=N''NOT_IN_CSV'' AND x.IsInCatalogCsv=0)
    /* Povezave z /splet in /splet/umaknjeni: stanje katalog.csv po imenu (NO_SITE, PUBLISHED, NO_CATEGORY, BLOCKED_ERRORS, ...). */
    OR (@State NOT IN (N''ERP_BLOCKED'',N''WEB_BLOCKED'',N''READY'',N''HOLD'',N''STALE'',N''IN_CSV'',N''NOT_IN_CSV'') AND x.WebExportState=@State);

  /* Stran: samo @Take vrstic iz pogleda (isti stolpci kot kartica izdelka). */
  CREATE TABLE #Page (ProductId bigint NOT NULL PRIMARY KEY, RowNo int NOT NULL);
  INSERT #Page (ProductId,RowNo)
  SELECT r.ProductId, ROW_NUMBER() OVER (ORDER BY r.SortGroup,r.ItemID)
  FROM #R AS r ORDER BY r.SortGroup,r.ItemID OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY;

  SELECT readiness.*
  FROM #Page AS page
  CROSS APPLY (SELECT v.* FROM val.ProductChannelReadiness AS v WHERE v.ProductId=page.ProductId) AS readiness
  ORDER BY page.RowNo
  OPTION (RECOMPILE);

  SELECT COUNT_BIG(*) TotalCount,
    ISNULL(SUM(CASE WHEN IsErpReady=1 THEN 1 ELSE 0 END),0) ErpReadyCount,
    ISNULL(SUM(CASE WHEN IsErpReady=0 THEN 1 ELSE 0 END),0) ErpBlockedCount,
    ISNULL(SUM(CASE WHEN IsWebReady=1 THEN 1 ELSE 0 END),0) WebReadyCount,
    ISNULL(SUM(CASE WHEN SiteFlagCount>0 AND IsWebReady=0 THEN 1 ELSE 0 END),0) WebBlockedCount,
    ISNULL(SUM(CASE WHEN HasHold=1 THEN 1 ELSE 0 END),0) HoldCount,
    ISNULL(SUM(CASE WHEN IsStale=1 THEN 1 ELSE 0 END),0) StaleCount,
    ISNULL(SUM(CASE WHEN IsInCatalogCsv=1 THEN 1 ELSE 0 END),0) InCsvCount,
    ISNULL(SUM(CASE WHEN WebExportState=N''NO_SITE'' THEN 1 ELSE 0 END),0) NoSiteCount,
    ISNULL(SUM(CASE WHEN WebExportState=N''PUBLISHED'' THEN 1 ELSE 0 END),0) PublishedCount
  FROM #R;
END;');
