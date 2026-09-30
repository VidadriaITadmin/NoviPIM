/*
  321_HitrejseNapakeKakovosti — naloga #122 (razvijalec #122, 2026-09-30).

  /kakovost/napake se je v vratih #108 nalagala 15 s, v vratih #112 106 s in filtri so javili
  »Odprtih težav trenutno ni mogoče naložiti«. Meritev na DEV brez druge obremenitve: seznam
  1,1-5,7 s (odvisno od filtra), pregled 1,2-2,1 s. Dva vzroka:

    1. Baza nima READ_COMMITTED_SNAPSHOT. Validacija (PRODUCT_VALIDATION, vsako uro, in ročni
       zagoni) piše val.ProductIssue za celo podjetje; branje pod READ COMMITTED medtem čaka na
       zaklepe vrstic in pade na 60 s časovni omejitvi ukaza. Isti vzorec je bil popravljen v #44
       (sled uporabnikov): bralni pregled bere READ UNCOMMITTED, LOCK_TIMEOUT pa omeji čakanje na
       zaklep sheme (npr. gradnja indeksa), da stran dobi jasno napako 1222 namesto molka.
       Seznam je bralni model za človeka; v najslabšem primeru med tekom validacije pokaže stanje
       sredi preračuna, ki ga naslednja osvežitev popravi. Ničesar ne zapiše in ne pošlje naprej.

    2. intranet.GetQualityIssues (zadnja definicija 177) je isti pogoj EXISTS nad ~1,8 M odprtimi
       težavami izračunal dvakrat: enkrat za stran (ORDER BY ItemID + OFFSET, kar je optimizator
       pri redkem filtru polja izvedel kot zanko po izdelkih v vrstnem redu šifre — 4,7 s za
       0 zadetkov) in enkrat za TotalCount. Zdaj se ujemajoči izdelki izračunajo ENKRAT v #Match
       (ProductId, ItemID); stran je OFFSET nad #Match, TotalCount je @@ROWCOUNT.

  Pomen je nespremenjen: isti parametri, isti trije nabori, isti stolpci, isti pogoji (tudi
  requirement.Severity brez COALESCE in @Blocks kot v 177). Primerjava stara/nova na DEV v tem
  zapisu spodaj (docs/DATABASE.md, 321).

  intranet.GetQualityOverview: telo iz 218 nespremenjeno, dodano samo READ UNCOMMITTED + LOCK_TIMEOUT.

  Vgrajena poizvedba za izbrani nivo (QualityReadService.GetIssuesForProfilesAsync) je popravljena
  po istem vzorcu v kodi.

  SAOP: nič (samo branje). Ročni korak: ne. Ponovljivo: da (CREATE OR ALTER).
  Razveljavitev: ponovno zaženi definicijo GetQualityIssues iz 177 in GetQualityOverview iz 218.
*/
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

CREATE OR ALTER PROCEDURE intranet.GetQualityIssues
  @OrganizationId int,
  @Skip int = 0,
  @Take int = 50,
  @Search nvarchar(200) = NULL,
  @ProfileCode nvarchar(100) = NULL,
  @Severity nvarchar(20) = NULL,
  @Blocks nvarchar(20) = NULL,
  @FieldCode nvarchar(200) = NULL,
  @Language nvarchar(20) = N'sl',
  @CategoryTreeCode nvarchar(100) = NULL,   /* 177: obseg = kategorija in vse njene podkategorije */
  @CategoryCode nvarchar(200) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  /* 321: bralni pregled ne caka na zaklepe validacije (baza nima READ_COMMITTED_SNAPSHOT).
     Nastavitvi veljata samo do konca procedure. */
  SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
  SET LOCK_TIMEOUT 20000;

  SET @Skip = CASE WHEN @Skip < 0 THEN 0 ELSE @Skip END;
  SET @Take = CASE WHEN @Take < 1 THEN 50 WHEN @Take > 200 THEN 200 ELSE @Take END;
  SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'');
  SET @ProfileCode = NULLIF(LTRIM(RTRIM(@ProfileCode)), N'');
  SET @Severity = NULLIF(UPPER(LTRIM(RTRIM(@Severity))), N'');
  SET @Blocks = NULLIF(UPPER(LTRIM(RTRIM(@Blocks))), N'');
  SET @FieldCode = NULLIF(LTRIM(RTRIM(@FieldCode)), N'');
  SET @Language = COALESCE(NULLIF(LTRIM(RTRIM(@Language)), N''), N'sl');
  IF @Severity NOT IN (N'ERROR', N'WARNING') SET @Severity = NULL;
  IF @Blocks NOT IN (N'ERP', N'WEB', N'NONE') SET @Blocks = NULL;

  /* 177: vecnivojski obseg kategorije (po ParentCategoryCode, v vseh jezikih). */
  SET @CategoryTreeCode = NULLIF(LTRIM(RTRIM(@CategoryTreeCode)), N'');
  SET @CategoryCode = NULLIF(LTRIM(RTRIM(@CategoryCode)), N'');
  IF @CategoryTreeCode IS NULL SET @CategoryCode = NULL;
  CREATE TABLE #Scope (ProductId bigint NOT NULL PRIMARY KEY);
  IF @CategoryCode IS NOT NULL
  BEGIN
    ;WITH subtree AS
    (
      SELECT CategoryCode FROM canon.Category WHERE CategoryTreeCode = @CategoryTreeCode AND CategoryCode = @CategoryCode
      UNION ALL
      SELECT child.CategoryCode FROM subtree
      INNER JOIN canon.Category AS child ON child.CategoryTreeCode = @CategoryTreeCode AND child.ParentCategoryCode = subtree.CategoryCode
    )
    INSERT #Scope (ProductId)
    SELECT DISTINCT productCategory.ProductId
    FROM subtree
    INNER JOIN canon.CategoryPathTranslated AS translated ON translated.CategoryTreeCode = @CategoryTreeCode AND translated.CategoryCode = subtree.CategoryCode
    INNER JOIN canon.WebSite AS site ON site.CategoryTreeCode = @CategoryTreeCode AND site.LanguageCode = translated.LanguageCode
    INNER JOIN canon.ProductCategory AS productCategory ON productCategory.WebSite = site.WebSiteCode AND productCategory.CategoryPath = translated.CategoryPath;
  END;

  DECLARE @Like nvarchar(210) = CASE WHEN @Search IS NULL THEN NULL ELSE N'%' + @Search + N'%' END;

  /* 321: ujemajoci izdelki ENKRAT (brez ORDER BY/OFFSET, zato optimizator izbere zdruzitev nad
     filtriranim indeksom odprtih tezav namesto zanke po sifrah); stran in TotalCount iz #Match. */
  CREATE TABLE #Match (ProductId bigint NOT NULL PRIMARY KEY, ItemID nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL);

  INSERT #Match (ProductId, ItemID)
  SELECT product.ProductId, product.ItemID
  FROM canon.Product AS product
  WHERE product.OrganizationId = @OrganizationId
    AND (@Like IS NULL OR product.ItemID LIKE @Like OR product.EAN LIKE @Like)
    AND (@CategoryCode IS NULL OR EXISTS (SELECT 1 FROM #Scope AS scope WHERE scope.ProductId = product.ProductId))
    AND EXISTS
    (
      SELECT 1
      FROM val.ProductIssue AS issueValue
      INNER JOIN val.ValidationProfile AS profileValue ON profileValue.ValidationProfileId = issueValue.ValidationProfileId
      LEFT JOIN val.FieldRequirement AS requirement ON requirement.FieldRequirementId = issueValue.FieldRequirementId
      WHERE issueValue.ProductId = product.ProductId AND issueValue.IsActive = 1
        AND (@ProfileCode IS NULL OR profileValue.ProfileCode = @ProfileCode)
        AND (@Severity IS NULL OR requirement.Severity = @Severity)
        AND (@FieldCode IS NULL OR requirement.FieldCode = @FieldCode)
        AND
        (
          @Blocks IS NULL
          OR (@Blocks = N'ERP' AND profileValue.BlocksErp = 1)
          OR (@Blocks = N'WEB' AND profileValue.BlocksWeb = 1)
          OR (@Blocks = N'NONE' AND profileValue.BlocksErp = 0 AND profileValue.BlocksWeb = 0)
        )
    )
  OPTION (RECOMPILE);
  DECLARE @TotalCount bigint = @@ROWCOUNT;

  /* Stranicenje je po izdelku, ne po tezavi: urednik dela po izdelkih. */
  CREATE TABLE #Page (ProductId bigint NOT NULL PRIMARY KEY, ItemID nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL);
  INSERT #Page (ProductId, ItemID)
  SELECT ProductId, ItemID FROM #Match
  ORDER BY ItemID
  OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY;

  SELECT product.ProductId, product.ItemID, product.EAN,
    Name = COALESCE(webTitle.Value, erpTitle.Value, product.ItemID),
    product.ValidationStatus, product.Completeness, product.IsActive, product.WebPublish,
    IssueCount = counters.IssueCount, ErrorCount = counters.ErrorCount,
    WarningCount = counters.WarningCount, BlockingErpCount = counters.BlockingErpCount,
    BlockingWebCount = counters.BlockingWebCount, LastDetectedUtc = counters.LastDetectedUtc
  FROM #Page AS pageRow
  INNER JOIN canon.Product AS product ON product.ProductId = pageRow.ProductId
  CROSS APPLY
  (
    SELECT IssueCount = COUNT_BIG(*),
      ErrorCount = SUM(CASE WHEN requirement.Severity = N'ERROR' THEN 1 ELSE 0 END),
      WarningCount = SUM(CASE WHEN requirement.Severity = N'WARNING' THEN 1 ELSE 0 END),
      BlockingErpCount = SUM(CASE WHEN profileValue.BlocksErp = 1 THEN 1 ELSE 0 END),
      BlockingWebCount = SUM(CASE WHEN profileValue.BlocksWeb = 1 THEN 1 ELSE 0 END),
      LastDetectedUtc = MAX(issueValue.LastDetectedUtc)
    FROM val.ProductIssue AS issueValue
    INNER JOIN val.ValidationProfile AS profileValue ON profileValue.ValidationProfileId = issueValue.ValidationProfileId
    LEFT JOIN val.FieldRequirement AS requirement ON requirement.FieldRequirementId = issueValue.FieldRequirementId
    WHERE issueValue.ProductId = product.ProductId AND issueValue.IsActive = 1
  ) AS counters
  OUTER APPLY
  (
    SELECT TOP (1) textValue.Value FROM canon.ProductText AS textValue
    WHERE textValue.ProductId = product.ProductId AND textValue.TextType = N'WEB_TITLE'
    ORDER BY CASE WHEN textValue.Lang = @Language THEN 0 WHEN textValue.Lang = N'sl' THEN 1 ELSE 2 END, textValue.Lang
  ) AS webTitle
  OUTER APPLY
  (
    SELECT TOP (1) textValue.Value FROM canon.ProductText AS textValue
    WHERE textValue.ProductId = product.ProductId AND textValue.TextType = N'TITLE_ERP'
    ORDER BY CASE WHEN textValue.Lang = @Language THEN 0 WHEN textValue.Lang = N'sl' THEN 1 ELSE 2 END, textValue.Lang
  ) AS erpTitle
  ORDER BY product.ItemID;

  /* Tezave samo za izdelke na strani: brez tega bi seznam znova prebral milijone vrstic. */
  SELECT issueValue.ProductIssueId, issueValue.ProductId,
    profileValue.ProfileCode, profileValue.BlocksErp, profileValue.BlocksWeb,
    FieldCode = requirement.FieldCode,
    Severity = COALESCE(requirement.Severity, N'ERROR'),
    issueValue.IssueCode, issueValue.Message,
    issueValue.FirstDetectedUtc, issueValue.LastDetectedUtc
  FROM #Page AS pageRow
  INNER JOIN val.ProductIssue AS issueValue ON issueValue.ProductId = pageRow.ProductId AND issueValue.IsActive = 1
  INNER JOIN val.ValidationProfile AS profileValue ON profileValue.ValidationProfileId = issueValue.ValidationProfileId
  LEFT JOIN val.FieldRequirement AS requirement ON requirement.FieldRequirementId = issueValue.FieldRequirementId
  WHERE (@ProfileCode IS NULL OR profileValue.ProfileCode = @ProfileCode)
    AND (@Severity IS NULL OR requirement.Severity = @Severity)
    AND (@FieldCode IS NULL OR requirement.FieldCode = @FieldCode)
    AND
    (
      @Blocks IS NULL
      OR (@Blocks = N'ERP' AND profileValue.BlocksErp = 1)
      OR (@Blocks = N'WEB' AND profileValue.BlocksWeb = 1)
      OR (@Blocks = N'NONE' AND profileValue.BlocksErp = 0 AND profileValue.BlocksWeb = 0)
    )
  ORDER BY pageRow.ItemID, profileValue.ProfileCode, requirement.FieldCode
  OPTION (RECOMPILE);

  SELECT TotalCount = @TotalCount;

  DROP TABLE #Page;
  DROP TABLE #Match;
  DROP TABLE #Scope;
END;
GO

CREATE OR ALTER PROCEDURE intranet.GetQualityOverview
  @OrganizationId int,
  @TopRules int = 15
AS
BEGIN
  SET NOCOUNT ON;
  /* 321: bralni pregled ne caka na zaklepe validacije (glej glavo migracije). */
  SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
  SET LOCK_TIMEOUT 20000;
  SET @TopRules = CASE WHEN @TopRules < 1 THEN 15 WHEN @TopRules > 100 THEN 100 ELSE @TopRules END;

  /* 218: odprte napake podjetja se preberejo enkrat v ozko zacasno tabelo (samo kljuci; opisna
     polja pridejo iz majhnih registrov ob branju), trije nabori spodaj jo berejo. */
  CREATE TABLE #Odprte
  (
    ProductId bigint NOT NULL,
    ValidationProfileId int NOT NULL,
    FieldRequirementId int NULL,
    /* Koda tezave je potrebna samo, kadar zahteve ni (COALESCE spodaj); sicer ostane prazna. */
    IssueCode nvarchar(100) COLLATE DATABASE_DEFAULT NULL
  );
  INSERT #Odprte (ProductId, ValidationProfileId, FieldRequirementId, IssueCode)
  SELECT issueValue.ProductId, issueValue.ValidationProfileId, issueValue.FieldRequirementId,
    CASE WHEN issueValue.FieldRequirementId IS NULL THEN issueValue.IssueCode END
  FROM val.ProductIssue AS issueValue
  INNER JOIN canon.Product AS product ON product.ProductId = issueValue.ProductId AND product.OrganizationId = @OrganizationId
  WHERE issueValue.IsActive = 1;

  /* 1 - koliko je odprtega in kaj od tega zares blokira. */
  SELECT
    OpenIssueCount = COUNT_BIG(*),
    ErrorCount = SUM(CASE WHEN COALESCE(requirement.Severity, N'ERROR') = N'ERROR' THEN 1 ELSE 0 END),
    WarningCount = SUM(CASE WHEN requirement.Severity = N'WARNING' THEN 1 ELSE 0 END),
    BlockingErpCount = SUM(CASE WHEN profileValue.BlocksErp = 1 THEN 1 ELSE 0 END),
    BlockingWebCount = SUM(CASE WHEN profileValue.BlocksWeb = 1 THEN 1 ELSE 0 END),
    AdvisoryCount = SUM(CASE WHEN profileValue.BlocksErp = 0 AND profileValue.BlocksWeb = 0 THEN 1 ELSE 0 END),
    AffectedProductCount = COUNT_BIG(DISTINCT odprta.ProductId)
  FROM #Odprte AS odprta
  INNER JOIN val.ValidationProfile AS profileValue ON profileValue.ValidationProfileId = odprta.ValidationProfileId
  LEFT JOIN val.FieldRequirement AS requirement ON requirement.FieldRequirementId = odprta.FieldRequirementId;

  /* 2 - katera zahteva ustavi najvec izdelkov; to je delovni seznam, ne statistika. */
  SELECT TOP (@TopRules)
    FieldCode = COALESCE(requirement.FieldCode, odprta.IssueCode),
    profileValue.ProfileCode, profileValue.BlocksErp, profileValue.BlocksWeb,
    Severity = COALESCE(requirement.Severity, N'ERROR'),
    IssueCount = COUNT_BIG(*),
    ProductCount = COUNT_BIG(DISTINCT odprta.ProductId)
  FROM #Odprte AS odprta
  INNER JOIN val.ValidationProfile AS profileValue ON profileValue.ValidationProfileId = odprta.ValidationProfileId
  LEFT JOIN val.FieldRequirement AS requirement ON requirement.FieldRequirementId = odprta.FieldRequirementId
  GROUP BY COALESCE(requirement.FieldCode, odprta.IssueCode), profileValue.ProfileCode,
    profileValue.BlocksErp, profileValue.BlocksWeb, COALESCE(requirement.Severity, N'ERROR')
  ORDER BY COUNT_BIG(DISTINCT odprta.ProductId) DESC, COUNT_BIG(*) DESC;

  /* 3 - pri katerem dobavitelju se napake kopicijo. Izdelek brez napak steje v ProductCount
     z IssueCount 0. */
  SELECT TOP (@TopRules)
    Supplier = COALESCE(product.Supplier, N'(brez dobavitelja)'),
    ProductCount = COUNT_BIG(*),
    WithIssuesCount = SUM(CASE WHEN ISNULL(issueCounter.IssueCount, 0) > 0 THEN 1 ELSE 0 END),
    IssueCount = SUM(ISNULL(issueCounter.IssueCount, 0))
  FROM canon.Product AS product
  LEFT JOIN
  (
    SELECT ProductId, IssueCount = COUNT_BIG(*)
    FROM #Odprte
    GROUP BY ProductId
  ) AS issueCounter ON issueCounter.ProductId = product.ProductId
  WHERE product.OrganizationId = @OrganizationId
  GROUP BY COALESCE(product.Supplier, N'(brez dobavitelja)')
  HAVING SUM(ISNULL(issueCounter.IssueCount, 0)) > 0
  ORDER BY SUM(CASE WHEN ISNULL(issueCounter.IssueCount, 0) > 0 THEN 1 ELSE 0 END) DESC, COUNT_BIG(*) DESC;

  DROP TABLE #Odprte;
END;
GO
