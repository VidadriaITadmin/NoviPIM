/*
  290 — Neskladja med podjetji: ista šifra v IQ in ViD (viri kataloga, out.CatalogSource) z različnimi karticami
  ali kljukicami spletišč. Stran /splet/neskladja.

  Uporabnik 2026-09-28: »fino bi bilo, če bi te neskladja imela kje v PIM-u, da imajo pregled in nadzor nad ERP-jem«.
  Dogovor s komercialo (isti dan): svetila vodi IQ; ViD kartica je za videlektro; artikel na obeh spletiščih ima
  ERP urejen v obeh podjetjih; NW artikli so v obeh podjetjih in na obeh spletiščih.

  Vrste (ena na šifro in drugo podjetje, v tem vrstnem redu):
    MANJKA_GLAVNA     drugo podjetje (ViD) ima kljukico spletišča, ki ga samo ne sme prispevati (svetila), glavno
                      podjetje (IQ) pa artikla nima ali je neaktiven → na to spletišče artikel NE gre.
    MANJKA_DRUGA      glavno podjetje ima kljukico spletišča, ki ga sme prispevati tudi drugo (videlektro), drugo pa
                      artikla nima ali je neaktiven → splet dela (prispeva IQ), ERP v drugem podjetju ni urejen.
    RAZLICNE_KLJUKICE obe kartici aktivni, kljukice različne → v katalogu je unija; preveri, ali je tako prav.
  Stolpec »V katalogu po kljukicah« je unija po pravilu 285 brez kategorije in validacije (te razloge kaže
  /splet/umaknjeni?pogled=kljukice).

  Objekti: intranet.GetOrganizationMismatches (samo bere), pravica view.web.mismatches (vse štiri vloge, kot
  view.web.withdrawals). Ročni korak: ne.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

IF UNICODE(N'č') <> 269
  THROW 52900, N'290: datoteka ni prebrana kot UTF-8 (sqlcmd -f 65001 ali Invoke-PendingMigrations.ps1).', 1;
IF OBJECT_ID(N'out.CatalogSource', N'U') IS NULL
  THROW 52901, N'290 potrebuje out.CatalogSource (285).', 1;
GO

CREATE OR ALTER PROCEDURE intranet.GetOrganizationMismatches
  @CatalogOrganizationId int = 2,
  @Kind nvarchar(30) = NULL,
  @Search nvarchar(200) = NULL,
  @Prefix nvarchar(50) = NULL,
  @Sort nvarchar(20) = NULL,
  @Descending bit = 0,
  @Skip int = 0,
  @Take int = 50,
  @ItemIdsJson nvarchar(max) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  /* 290: bralni pogled; vse v #temp s COLLATE DATABASE_DEFAULT (razvojni tempdb ima drugo zbirko). */
  SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
  SET @Prefix = NULLIF(LTRIM(RTRIM(@Prefix)), N'');
  SET @Kind = NULLIF(LTRIM(RTRIM(@Kind)), N'');
  IF @Skip < 0 SET @Skip = 0;
  IF @Take IS NULL OR @Take <= 0 SET @Take = 50;
  DECLARE @SearchLike nvarchar(410) = CASE WHEN @Search IS NULL THEN NULL ELSE
    N'%' + REPLACE(REPLACE(REPLACE(@Search, N'[', N'[[]'), N'%', N'[%]'), N'_', N'[_]') + N'%' END;

  CREATE TABLE #Src
    (OrganizationId int NOT NULL PRIMARY KEY, Priority int NOT NULL, IsPrimary bit NOT NULL,
     Allowed nvarchar(400) COLLATE DATABASE_DEFAULT NULL, Name nvarchar(200) COLLATE DATABASE_DEFAULT NULL);
  INSERT #Src (OrganizationId, Priority, IsPrimary, Allowed, Name)
  SELECT source.SourceOrganizationId, source.Priority, 0, source.WebSiteLabels, organization.Name
  FROM out.CatalogSource AS source
  LEFT JOIN dbo.OrganizationConfig AS organization ON organization.OrganizationId = source.SourceOrganizationId
  WHERE source.CatalogOrganizationId = @CatalogOrganizationId AND source.IsActive = 1;
  UPDATE #Src SET IsPrimary = 1
  WHERE OrganizationId = (SELECT TOP (1) OrganizationId FROM #Src ORDER BY Priority, OrganizationId);
  DECLARE @Primary int = (SELECT OrganizationId FROM #Src WHERE IsPrimary = 1);

  /* Dovoljena spletišča drugih podjetij (NULL = vsa). */
  CREATE TABLE #Allowed (OrganizationId int NOT NULL, Label nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL, PRIMARY KEY (OrganizationId, Label));
  INSERT #Allowed (OrganizationId, Label)
  SELECT DISTINCT source.OrganizationId, LTRIM(RTRIM(part.value))
  FROM #Src AS source CROSS APPLY STRING_SPLIT(REPLACE(source.Allowed, N',', N'|'), N'|') AS part
  WHERE source.Allowed IS NOT NULL AND LTRIM(RTRIM(part.value)) <> N'';
  INSERT #Allowed (OrganizationId, Label)
  SELECT DISTINCT source.OrganizationId, ISNULL(site.TreeLabel, site.CategoryTreeCode)
  FROM #Src AS source CROSS JOIN canon.WebSite AS site
  WHERE source.Allowed IS NULL AND site.IsActive = 1
    AND NOT EXISTS (SELECT 1 FROM #Allowed AS existing WHERE existing.OrganizationId = source.OrganizationId
                      AND existing.Label = ISNULL(site.TreeLabel, site.CategoryTreeCode));

  CREATE TABLE #SiteOrder (Label nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY, SortOrder int NOT NULL);
  INSERT #SiteOrder (Label, SortOrder)
  SELECT ISNULL(TreeLabel, CategoryTreeCode), MIN(SortOrder) FROM canon.WebSite WHERE IsActive = 1 GROUP BY ISNULL(TreeLabel, CategoryTreeCode);

  /* Kljukice po šifri in podjetju (oznaka spletišča kot v katalog.csv). */
  CREATE TABLE #Flag
    (ItemID nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL, OrganizationId int NOT NULL,
     Label nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL, PRIMARY KEY (ItemID, OrganizationId, Label));
  INSERT #Flag (ItemID, OrganizationId, Label)
  SELECT DISTINCT product.ItemID, product.OrganizationId, ISNULL(site.Label, shop.WebShopCode)
  FROM pim.ProductWebShop AS shop
  INNER JOIN canon.Product AS product ON product.ProductId = shop.ProductId
  INNER JOIN #Src AS source ON source.OrganizationId = product.OrganizationId
  OUTER APPLY (SELECT TOP (1) ISNULL(web.TreeLabel, web.CategoryTreeCode) AS Label FROM canon.WebSite AS web
               WHERE web.CategoryTreeCode = shop.WebShopCode ORDER BY web.SortOrder) AS site
  WHERE shop.IsPublished = 1;

  /* Kartice šifer s kljukico v vseh virih. */
  CREATE TABLE #Card
    (ItemID nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL, OrganizationId int NOT NULL, IsActive bit NOT NULL,
     PimProductId bigint NULL, Name nvarchar(1000) COLLATE DATABASE_DEFAULT NULL, PRIMARY KEY (ItemID, OrganizationId));
  INSERT #Card (ItemID, OrganizationId, IsActive, PimProductId, Name)
  /* Od šifer s kljukico (nekaj tisoč) po UQ_CanonProduct_OrganizationItem — ne čez vse izdelke. */
  SELECT items.ItemID, source.OrganizationId, product.IsActive, promoted.PimProductId, promoted.Name
  FROM (SELECT DISTINCT ItemID FROM #Flag) AS items
  CROSS JOIN #Src AS source
  INNER JOIN canon.Product AS product ON product.OrganizationId = source.OrganizationId AND product.ItemID = items.ItemID
  LEFT JOIN pim.Product AS promoted ON promoted.OrganizationId = product.OrganizationId AND promoted.ItemID = product.ItemID;

  /* Ena vrstica na šifro in drugo podjetje. */
  CREATE TABLE #Row
    (ItemID nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL, OtherOrganizationId int NOT NULL,
     Kind nvarchar(30) COLLATE DATABASE_DEFAULT NOT NULL, PRIMARY KEY (ItemID, OtherOrganizationId));

  /* Za vsako šifro in drugo podjetje: ima glavno aktivno kartico, ima drugo, ima drugo kljukico, ki je ne sme
     prispevati, ima glavno kljukico, ki bi jo smelo prispevati tudi drugo, in ali se kljukici razlikujeta. */
  INSERT #Row (ItemID, OtherOrganizationId, Kind)
  SELECT classified.ItemID, classified.OrganizationId, classified.Kind
  FROM
  (
    SELECT items.ItemID, other.OrganizationId,
      CASE
        WHEN fact.OtherHasForeignFlag = 1 AND fact.PrimaryActive = 0 THEN N'MANJKA_GLAVNA'
        WHEN fact.PrimaryHasSharedFlag = 1 AND fact.PrimaryActive = 1 AND fact.OtherActive = 0 THEN N'MANJKA_DRUGA'
        WHEN fact.PrimaryActive = 1 AND fact.OtherActive = 1 AND fact.FlagsDiffer = 1 THEN N'RAZLICNE_KLJUKICE'
      END AS Kind
    FROM (SELECT DISTINCT ItemID FROM #Flag) AS items
    CROSS JOIN #Src AS other
    CROSS APPLY
    (
      SELECT
        PrimaryActive = CASE WHEN EXISTS (SELECT 1 FROM #Card AS card WHERE card.ItemID = items.ItemID
                                            AND card.OrganizationId = @Primary AND card.IsActive = 1) THEN 1 ELSE 0 END,
        OtherActive = CASE WHEN EXISTS (SELECT 1 FROM #Card AS card WHERE card.ItemID = items.ItemID
                                          AND card.OrganizationId = other.OrganizationId AND card.IsActive = 1) THEN 1 ELSE 0 END,
        OtherHasForeignFlag = CASE WHEN EXISTS (SELECT 1 FROM #Flag AS flag WHERE flag.ItemID = items.ItemID AND flag.OrganizationId = other.OrganizationId
            AND NOT EXISTS (SELECT 1 FROM #Allowed AS allowed WHERE allowed.OrganizationId = other.OrganizationId AND allowed.Label = flag.Label)) THEN 1 ELSE 0 END,
        PrimaryHasSharedFlag = CASE WHEN EXISTS (SELECT 1 FROM #Flag AS flag WHERE flag.ItemID = items.ItemID AND flag.OrganizationId = @Primary
            AND EXISTS (SELECT 1 FROM #Allowed AS allowed WHERE allowed.OrganizationId = other.OrganizationId AND allowed.Label = flag.Label)) THEN 1 ELSE 0 END,
        FlagsDiffer = CASE WHEN EXISTS (SELECT Label FROM #Flag AS flag WHERE flag.ItemID = items.ItemID AND flag.OrganizationId = @Primary
                                          EXCEPT SELECT Label FROM #Flag AS flag WHERE flag.ItemID = items.ItemID AND flag.OrganizationId = other.OrganizationId)
                             OR EXISTS (SELECT Label FROM #Flag AS flag WHERE flag.ItemID = items.ItemID AND flag.OrganizationId = other.OrganizationId
                                          EXCEPT SELECT Label FROM #Flag AS flag WHERE flag.ItemID = items.ItemID AND flag.OrganizationId = @Primary)
                           THEN 1 ELSE 0 END
    ) AS fact
    WHERE other.IsPrimary = 0
  ) AS classified
  WHERE classified.Kind IS NOT NULL;

  /* Podrobnosti vrstice: kartici, kljukice in kaj gre po kljukicah v katalog (unija po pravilu 285). */
  CREATE TABLE #Detail
    (ItemID nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL, OtherOrganizationId int NOT NULL,
     Kind nvarchar(30) COLLATE DATABASE_DEFAULT NOT NULL, Name nvarchar(1000) COLLATE DATABASE_DEFAULT NULL,
     Prefix nvarchar(50) COLLATE DATABASE_DEFAULT NOT NULL,
     PrimaryCard bit NOT NULL, PrimaryActive bit NOT NULL, PrimaryPimProductId bigint NULL, PrimaryFlags nvarchar(400) COLLATE DATABASE_DEFAULT NULL,
     OtherCard bit NOT NULL, OtherActive bit NOT NULL, OtherPimProductId bigint NULL, OtherFlags nvarchar(400) COLLATE DATABASE_DEFAULT NULL,
     CatalogSites nvarchar(400) COLLATE DATABASE_DEFAULT NULL, LostSites nvarchar(400) COLLATE DATABASE_DEFAULT NULL,
     PRIMARY KEY (ItemID, OtherOrganizationId));

  INSERT #Detail
  SELECT row.ItemID, row.OtherOrganizationId, row.Kind,
    COALESCE(primaryCard.Name, otherCard.Name),
    CASE WHEN CHARINDEX(N'.', row.ItemID) > 1 THEN LEFT(row.ItemID, CHARINDEX(N'.', row.ItemID)) ELSE N'' END,
    CASE WHEN primaryCard.ItemID IS NULL THEN 0 ELSE 1 END, ISNULL(primaryCard.IsActive, 0), primaryCard.PimProductId,
    (SELECT STRING_AGG(flag.Label, N'|') WITHIN GROUP (ORDER BY siteOrder.SortOrder, flag.Label)
     FROM #Flag AS flag LEFT JOIN #SiteOrder AS siteOrder ON siteOrder.Label = flag.Label
     WHERE flag.ItemID = row.ItemID AND flag.OrganizationId = @Primary),
    CASE WHEN otherCard.ItemID IS NULL THEN 0 ELSE 1 END, ISNULL(otherCard.IsActive, 0), otherCard.PimProductId,
    (SELECT STRING_AGG(flag.Label, N'|') WITHIN GROUP (ORDER BY siteOrder.SortOrder, flag.Label)
     FROM #Flag AS flag LEFT JOIN #SiteOrder AS siteOrder ON siteOrder.Label = flag.Label
     WHERE flag.ItemID = row.ItemID AND flag.OrganizationId = row.OtherOrganizationId),
    (SELECT STRING_AGG(site.Label, N'|') WITHIN GROUP (ORDER BY site.SortOrder, site.Label)
     FROM (SELECT DISTINCT flag.Label, ISNULL(siteOrder.SortOrder, 999) AS SortOrder
           FROM #Flag AS flag LEFT JOIN #SiteOrder AS siteOrder ON siteOrder.Label = flag.Label
           WHERE flag.ItemID = row.ItemID
             AND ((flag.OrganizationId = @Primary AND ISNULL(primaryCard.IsActive, 0) = 1)
               OR (flag.OrganizationId = row.OtherOrganizationId AND ISNULL(otherCard.IsActive, 0) = 1
                   AND EXISTS (SELECT 1 FROM #Allowed AS allowed WHERE allowed.OrganizationId = row.OtherOrganizationId AND allowed.Label = flag.Label)))) AS site),
    (SELECT STRING_AGG(site.Label, N'|') WITHIN GROUP (ORDER BY site.SortOrder, site.Label)
     FROM (SELECT DISTINCT flag.Label, ISNULL(siteOrder.SortOrder, 999) AS SortOrder
           FROM #Flag AS flag LEFT JOIN #SiteOrder AS siteOrder ON siteOrder.Label = flag.Label
           WHERE flag.ItemID = row.ItemID
             AND NOT ((flag.OrganizationId = @Primary AND ISNULL(primaryCard.IsActive, 0) = 1)
               OR (flag.OrganizationId = row.OtherOrganizationId AND ISNULL(otherCard.IsActive, 0) = 1
                   AND EXISTS (SELECT 1 FROM #Allowed AS allowed WHERE allowed.OrganizationId = row.OtherOrganizationId AND allowed.Label = flag.Label)))
             AND NOT EXISTS (SELECT 1 FROM #Flag AS kept WHERE kept.ItemID = row.ItemID AND kept.Label = flag.Label
               AND ((kept.OrganizationId = @Primary AND ISNULL(primaryCard.IsActive, 0) = 1)
                 OR (kept.OrganizationId = row.OtherOrganizationId AND ISNULL(otherCard.IsActive, 0) = 1
                     AND EXISTS (SELECT 1 FROM #Allowed AS allowed WHERE allowed.OrganizationId = row.OtherOrganizationId AND allowed.Label = kept.Label))))) AS site)
  FROM #Row AS row
  LEFT JOIN #Card AS primaryCard ON primaryCard.ItemID = row.ItemID AND primaryCard.OrganizationId = @Primary
  LEFT JOIN #Card AS otherCard ON otherCard.ItemID = row.ItemID AND otherCard.OrganizationId = row.OtherOrganizationId;

  /* Filtri: iskanje (brez šumnikov), predpona, izbrane šifre; vrsta velja za seznam, ne za števce vrst. */
  CREATE TABLE #Picked (ItemID nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY);
  IF @ItemIdsJson IS NOT NULL
    INSERT #Picked (ItemID) SELECT DISTINCT CONVERT(nvarchar(200), value) FROM OPENJSON(@ItemIdsJson) WHERE value IS NOT NULL;

  DELETE FROM #Detail
  WHERE (@SearchLike IS NOT NULL AND NOT (ItemID COLLATE Latin1_General_CI_AI LIKE @SearchLike COLLATE Latin1_General_CI_AI
                                          OR ISNULL(Name, N'') COLLATE Latin1_General_CI_AI LIKE @SearchLike COLLATE Latin1_General_CI_AI))
     OR (@Prefix IS NOT NULL AND Prefix <> @Prefix)
     OR (@ItemIdsJson IS NOT NULL AND NOT EXISTS (SELECT 1 FROM #Picked AS picked WHERE picked.ItemID = #Detail.ItemID));

  SELECT detail.ItemID, detail.Name, detail.Kind, detail.Prefix, detail.OtherOrganizationId,
    detail.PrimaryCard, detail.PrimaryActive, detail.PrimaryPimProductId, detail.PrimaryFlags,
    detail.OtherCard, detail.OtherActive, detail.OtherPimProductId, detail.OtherFlags,
    detail.CatalogSites, detail.LostSites
  FROM #Detail AS detail
  WHERE @Kind IS NULL OR detail.Kind = @Kind
  ORDER BY
    CASE WHEN @Descending = 0 THEN CASE @Sort WHEN N'naziv' THEN detail.Name WHEN N'vrsta' THEN detail.Kind WHEN N'predpona' THEN detail.Prefix ELSE detail.ItemID END END ASC,
    CASE WHEN @Descending = 1 THEN CASE @Sort WHEN N'naziv' THEN detail.Name WHEN N'vrsta' THEN detail.Kind WHEN N'predpona' THEN detail.Prefix ELSE detail.ItemID END END DESC,
    detail.ItemID, detail.OtherOrganizationId
  OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY;

  SELECT COUNT_BIG(*) AS Total FROM #Detail WHERE @Kind IS NULL OR Kind = @Kind;

  SELECT Kind, COUNT(*) AS Items FROM #Detail GROUP BY Kind;

  /* Predpone (dobavitelj po šifri) iz vseh neskladij, brez filtrov — za izbirnik. */
  SELECT Prefix, COUNT(*) AS Items
  FROM #Row AS row
  CROSS APPLY (SELECT CASE WHEN CHARINDEX(N'.', row.ItemID) > 1 THEN LEFT(row.ItemID, CHARINDEX(N'.', row.ItemID)) ELSE N'' END AS Prefix) AS p
  GROUP BY Prefix ORDER BY COUNT(*) DESC, Prefix;

  SELECT OrganizationId, Name, IsPrimary, Allowed FROM #Src ORDER BY Priority, OrganizationId;
END;
GO

/* Pravica: bralna stran, iste vloge kot /splet/umaknjeni (view.web.withdrawals). */
INSERT sec.RolePermission (RoleId, PermissionKey)
SELECT roleValue.RoleId, N'view.web.mismatches'
FROM sec.Role AS roleValue
WHERE roleValue.RoleCode IN (N'ADMIN', N'CATALOG_EDITOR', N'COMMERCIAL', N'VIEWER')
  AND NOT EXISTS (SELECT 1 FROM sec.RolePermission AS existing
                  WHERE existing.RoleId = roleValue.RoleId AND existing.PermissionKey = N'view.web.mismatches');
GO

IF OBJECT_ID(N'intranet.GetOrganizationMismatches', N'P') IS NULL
  THROW 52902, N'290: intranet.GetOrganizationMismatches ni nastala.', 1;
GO
