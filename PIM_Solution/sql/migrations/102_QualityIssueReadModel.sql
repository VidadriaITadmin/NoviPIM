/*
  102 — bralni model kakovosti: strani se po izdelku, ne po tezavi.

  Zakaj: stran /kakovost/napake je klicala intranet.GetValidationIssues, ki vrne VSE odprte
  tezave podjetja brez stranicenja, iskanje in filtriranje pa sta se dogajala v pomnilniku
  streznika. Merjeno 2026-08-26: val.ProductIssue ima 3.004.688 aktivnih vrstic, od tega
  1.809.828 za podjetje 2. Taka stran ni pocasna, ampak neuporabna.

  Enota strani je izdelek. Urednik dela po izdelkih (odpre kartico in popravi polje), tezave
  pa so njegov opis: izdelkov z vsaj eno odprto tezavo je v najvecjem podjetju 96.847, ne
  1,8 milijona. Drugi nabor vrne tezave samo za izdelke na trenutni strani.

  Merjeno po tej migraciji (podjetje 2): privzeta stran 181 ms, filtrirana po resnosti in
  obsegu blokade 176 ms, stran 5.000 s profilom 212 ms, pregled kakovosti 452 ms.

  intranet.GetValidationIssues ostane nedotaknjena — uporablja jo nadzorna plosca za drug
  namen (najpogostejse tezave in profili). Nicesar ne brisemo, dokler ni odlocitve.
*/

SET XACT_ABORT ON;

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetQualityIssues
  @OrganizationId int,
  @Skip int = 0,
  @Take int = 50,
  @Search nvarchar(200) = NULL,
  @ProfileCode nvarchar(100) = NULL,
  @Severity nvarchar(20) = NULL,
  @Blocks nvarchar(20) = NULL,
  @FieldCode nvarchar(200) = NULL,
  @Language nvarchar(20) = N''sl''
AS
BEGIN
  SET NOCOUNT ON;

  SET @Skip = CASE WHEN @Skip < 0 THEN 0 ELSE @Skip END;
  SET @Take = CASE WHEN @Take < 1 THEN 50 WHEN @Take > 200 THEN 200 ELSE @Take END;
  SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'''');
  SET @ProfileCode = NULLIF(LTRIM(RTRIM(@ProfileCode)), N'''');
  SET @Severity = NULLIF(UPPER(LTRIM(RTRIM(@Severity))), N'''');
  SET @Blocks = NULLIF(UPPER(LTRIM(RTRIM(@Blocks))), N'''');
  SET @FieldCode = NULLIF(LTRIM(RTRIM(@FieldCode)), N'''');
  SET @Language = COALESCE(NULLIF(LTRIM(RTRIM(@Language)), N''''), N''sl'');
  IF @Severity NOT IN (N''ERROR'', N''WARNING'') SET @Severity = NULL;
  IF @Blocks NOT IN (N''ERP'', N''WEB'', N''NONE'') SET @Blocks = NULL;

  DECLARE @Like nvarchar(210) = CASE WHEN @Search IS NULL THEN NULL ELSE N''%'' + @Search + N''%'' END;

  /* Stranicenje je po izdelku, ne po tezavi: tezav je 3,0 milijona, izdelkov z odprto tezavo
     pa 96.847 v najvecjem podjetju. Urednik dela po izdelkih, zato je izdelek tudi enota strani. */
  CREATE TABLE #Page (ProductId bigint NOT NULL PRIMARY KEY, ItemID nvarchar(100) NOT NULL);

  INSERT #Page (ProductId, ItemID)
  SELECT product.ProductId, product.ItemID
  FROM canon.Product AS product
  WHERE product.OrganizationId = @OrganizationId
    AND (@Like IS NULL OR product.ItemID LIKE @Like OR product.EAN LIKE @Like)
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
          OR (@Blocks = N''ERP'' AND profileValue.BlocksErp = 1)
          OR (@Blocks = N''WEB'' AND profileValue.BlocksWeb = 1)
          OR (@Blocks = N''NONE'' AND profileValue.BlocksErp = 0 AND profileValue.BlocksWeb = 0)
        )
    )
  ORDER BY product.ItemID
  OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY
  OPTION (RECOMPILE);

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
      ErrorCount = SUM(CASE WHEN requirement.Severity = N''ERROR'' THEN 1 ELSE 0 END),
      WarningCount = SUM(CASE WHEN requirement.Severity = N''WARNING'' THEN 1 ELSE 0 END),
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
    WHERE textValue.ProductId = product.ProductId AND textValue.TextType = N''WEB_TITLE''
    ORDER BY CASE WHEN textValue.Lang = @Language THEN 0 WHEN textValue.Lang = N''sl'' THEN 1 ELSE 2 END, textValue.Lang
  ) AS webTitle
  OUTER APPLY
  (
    SELECT TOP (1) textValue.Value FROM canon.ProductText AS textValue
    WHERE textValue.ProductId = product.ProductId AND textValue.TextType = N''TITLE_ERP''
    ORDER BY CASE WHEN textValue.Lang = @Language THEN 0 WHEN textValue.Lang = N''sl'' THEN 1 ELSE 2 END, textValue.Lang
  ) AS erpTitle
  ORDER BY product.ItemID;

  /* Tezave samo za izdelke na strani: brez tega bi seznam znova prebral milijone vrstic. */
  SELECT issueValue.ProductIssueId, issueValue.ProductId,
    profileValue.ProfileCode, profileValue.BlocksErp, profileValue.BlocksWeb,
    FieldCode = requirement.FieldCode,
    Severity = COALESCE(requirement.Severity, N''ERROR''),
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
      OR (@Blocks = N''ERP'' AND profileValue.BlocksErp = 1)
      OR (@Blocks = N''WEB'' AND profileValue.BlocksWeb = 1)
      OR (@Blocks = N''NONE'' AND profileValue.BlocksErp = 0 AND profileValue.BlocksWeb = 0)
    )
  ORDER BY pageRow.ItemID, profileValue.ProfileCode, requirement.FieldCode
  OPTION (RECOMPILE);

  SELECT TotalCount = COUNT_BIG(*)
  FROM canon.Product AS product
  WHERE product.OrganizationId = @OrganizationId
    AND (@Like IS NULL OR product.ItemID LIKE @Like OR product.EAN LIKE @Like)
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
          OR (@Blocks = N''ERP'' AND profileValue.BlocksErp = 1)
          OR (@Blocks = N''WEB'' AND profileValue.BlocksWeb = 1)
          OR (@Blocks = N''NONE'' AND profileValue.BlocksErp = 0 AND profileValue.BlocksWeb = 0)
        )
    )
  OPTION (RECOMPILE);

  DROP TABLE #Page;
END;');

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetQualityOverview
  @OrganizationId int,
  @TopRules int = 15
AS
BEGIN
  SET NOCOUNT ON;
  SET @TopRules = CASE WHEN @TopRules < 1 THEN 15 WHEN @TopRules > 100 THEN 100 ELSE @TopRules END;

  /* 1 — koliko je odprtega in kaj od tega zares blokira. */
  SELECT
    OpenIssueCount = COUNT_BIG(*),
    ErrorCount = SUM(CASE WHEN COALESCE(requirement.Severity, N''ERROR'') = N''ERROR'' THEN 1 ELSE 0 END),
    WarningCount = SUM(CASE WHEN requirement.Severity = N''WARNING'' THEN 1 ELSE 0 END),
    BlockingErpCount = SUM(CASE WHEN profileValue.BlocksErp = 1 THEN 1 ELSE 0 END),
    BlockingWebCount = SUM(CASE WHEN profileValue.BlocksWeb = 1 THEN 1 ELSE 0 END),
    AdvisoryCount = SUM(CASE WHEN profileValue.BlocksErp = 0 AND profileValue.BlocksWeb = 0 THEN 1 ELSE 0 END),
    AffectedProductCount = COUNT_BIG(DISTINCT issueValue.ProductId)
  FROM val.ProductIssue AS issueValue
  INNER JOIN canon.Product AS product ON product.ProductId = issueValue.ProductId AND product.OrganizationId = @OrganizationId
  INNER JOIN val.ValidationProfile AS profileValue ON profileValue.ValidationProfileId = issueValue.ValidationProfileId
  LEFT JOIN val.FieldRequirement AS requirement ON requirement.FieldRequirementId = issueValue.FieldRequirementId
  WHERE issueValue.IsActive = 1;

  /* 2 — katera zahteva ustavi najvec izdelkov; to je delovni seznam, ne statistika. */
  SELECT TOP (@TopRules)
    FieldCode = COALESCE(requirement.FieldCode, issueValue.IssueCode),
    profileValue.ProfileCode, profileValue.BlocksErp, profileValue.BlocksWeb,
    Severity = COALESCE(requirement.Severity, N''ERROR''),
    IssueCount = COUNT_BIG(*),
    ProductCount = COUNT_BIG(DISTINCT issueValue.ProductId)
  FROM val.ProductIssue AS issueValue
  INNER JOIN canon.Product AS product ON product.ProductId = issueValue.ProductId AND product.OrganizationId = @OrganizationId
  INNER JOIN val.ValidationProfile AS profileValue ON profileValue.ValidationProfileId = issueValue.ValidationProfileId
  LEFT JOIN val.FieldRequirement AS requirement ON requirement.FieldRequirementId = issueValue.FieldRequirementId
  WHERE issueValue.IsActive = 1
  GROUP BY COALESCE(requirement.FieldCode, issueValue.IssueCode), profileValue.ProfileCode,
    profileValue.BlocksErp, profileValue.BlocksWeb, COALESCE(requirement.Severity, N''ERROR'')
  ORDER BY COUNT_BIG(DISTINCT issueValue.ProductId) DESC, COUNT_BIG(*) DESC;

  /* 3 — pri katerem dobavitelju se napake kopicijo. */
  SELECT TOP (@TopRules)
    Supplier = COALESCE(product.Supplier, N''(brez dobavitelja)''),
    ProductCount = COUNT_BIG(*),
    WithIssuesCount = SUM(CASE WHEN issueCounter.IssueCount > 0 THEN 1 ELSE 0 END),
    IssueCount = SUM(issueCounter.IssueCount)
  FROM canon.Product AS product
  CROSS APPLY
  (
    SELECT IssueCount = COUNT_BIG(*)
    FROM val.ProductIssue AS issueValue
    WHERE issueValue.ProductId = product.ProductId AND issueValue.IsActive = 1
  ) AS issueCounter
  WHERE product.OrganizationId = @OrganizationId
  GROUP BY COALESCE(product.Supplier, N''(brez dobavitelja)'')
  HAVING SUM(issueCounter.IssueCount) > 0
  ORDER BY SUM(CASE WHEN issueCounter.IssueCount > 0 THEN 1 ELSE 0 END) DESC, COUNT_BIG(*) DESC;
END;');
