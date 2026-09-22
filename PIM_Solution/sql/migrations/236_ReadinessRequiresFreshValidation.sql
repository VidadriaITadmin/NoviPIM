/* 236: Pripravljenost ne sme biti zelena, ko je validacija starejša od dveh ur.
   Ista meja kot val.IsProductChannelReady; napak in ročnih zadržkov ne sprošča. */
SET XACT_ABORT ON;
EXEC(N'CREATE OR ALTER VIEW val.ProductChannelReadiness
AS
/*
  218: isti stolpci in isti pomen kot prej (migracija 194), a mnozicno: stevci napak in zadrzkov
  pridejo iz enega GROUP BY po izdelku, ne iz OUTER APPLY za vsak izdelek posebej, in naziv
  pride naravnost iz canon.ProductText (TITLE_ERP, sl) namesto prek pogleda canon.FieldValue za
  vsak izdelek posebej. Izmerjeno pred: intranet.GetQualityProducts (SELECT * INTO #Rows iz tega
  pogleda za eno podjetje) 24-39 s; stran /kakovost/artikli je padla na 30 s meji ukaza.
  Opomba: prejsnji COALESCE je najprej iskal kodo "Product.Name", ki je v canon.FieldValue ni,
  zato je vedno obveljal ProductText.TITLE_ERP.sl - tu je to zapisano neposredno.
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
  IsErpReady=CONVERT(bit,CASE WHEN product.IsActive=1 AND product.LastValidatedUtc >= DATEADD(hour,-2,SYSUTCDATETIME())
    AND ISNULL(issueCount.ErpBlockingCount,0)=0
    AND ISNULL(holdCount.HasGlobalHold,0)=0 AND ISNULL(holdCount.HasErpHold,0)=0 THEN 1 ELSE 0 END),
  IsWebReady=CONVERT(bit,CASE WHEN product.IsActive=1 AND product.WebPublish=1 AND product.LastValidatedUtc >= DATEADD(hour,-2,SYSUTCDATETIME())
    AND ISNULL(issueCount.WebBlockingCount,0)=0
    AND ISNULL(holdCount.HasGlobalHold,0)=0 AND ISNULL(holdCount.HasWebHold,0)=0 THEN 1 ELSE 0 END)
FROM canon.Product AS product
LEFT JOIN canon.ProductText AS title
  ON title.ProductId=product.ProductId AND title.TextType=N''TITLE_ERP'' AND title.Lang=N''sl''
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
) AS holdCount ON holdCount.ProductId=product.ProductId;');
