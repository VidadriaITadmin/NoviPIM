/*
  104 — pripravljenost izvoza: kaj do datoteke sploh ne pride in zakaj.

  Nacrt (§5.6) zahteva: »Nic ne sme tiho odpasti. Ce izvoz izpusti vrstice, mora biti to vidno
  kot stevilo in razlog.« Predogleda same datoteke ta procedura namenoma NE dela: resnica o
  Magento izvozu zivi v PIM.B2bWorker in MagentoCsvContract, in drugi zapis iste logike v SQL
  bi bil druga resnica — natanko to, kar je stari sistem ze imel.

  Kar je mogoce povedati tocno, je vstopnica: v datoteko gre samo to, kar je val.Promote
  prenesla v pim.*. Procedura zato pove, koliko kanonicnih izdelkov je objavljenih, koliko ni,
  katera zahteva jih ustavi in koliko stolpcev profila sploh nima kanonicnega vira.

  Merjeno 2026-08-26 (podjetje 2): 234 ms. Rezultat: 111.068 kanonicnih, 43.503 objavljenih,
  67.565 neobjavljenih; najpogostejsi razlogi so manjkajoca kategorija (54.766), manjkajoca
  slika (54.758) in manjkajoc spletni naziv (52.649); 22 od 213 stolpcev profila
  MAGENTO_PRODUCTS nima kanonicnega vira.
*/

SET XACT_ABORT ON;

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetExportReadiness
  @OrganizationId int,
  @TopReasons int = 20
AS
BEGIN
  SET NOCOUNT ON;
  SET @TopReasons = CASE WHEN @TopReasons < 1 THEN 20 WHEN @TopReasons > 100 THEN 100 ELSE @TopReasons END;

  /* Vstopnica za izvoz je objava: v datoteko gre samo to, kar je val.Promote prenesla v pim.*.
     Ta procedura zato ne ugiba, kaj bo v datoteki — pove, kaj do datoteke sploh ne pride. */
  SELECT
    CanonicalCount = COUNT_BIG(*),
    ActiveCount = SUM(CASE WHEN product.IsActive = 1 THEN 1 ELSE 0 END),
    PublishedCount = SUM(CASE WHEN promoted.PimProductId IS NULL THEN 0 ELSE 1 END),
    NotPublishedCount = SUM(CASE WHEN promoted.PimProductId IS NULL THEN 1 ELSE 0 END),
    WebFlaggedCount = SUM(CASE WHEN product.WebPublish = 1 THEN 1 ELSE 0 END),
    PublishedWithOpenIssues = SUM(CASE WHEN promoted.PimProductId IS NOT NULL AND product.ValidationStatus <> N''VALID'' THEN 1 ELSE 0 END)
  FROM canon.Product AS product
  LEFT JOIN pim.Product AS promoted
    ON promoted.OrganizationId = product.OrganizationId AND promoted.ItemID = product.ItemID
  WHERE product.OrganizationId = @OrganizationId;

  /* Zakaj izdelek ni objavljen: zahteva, ki mu manjka, in profil, ki jo postavlja. */
  SELECT TOP (@TopReasons)
    FieldCode = COALESCE(requirement.FieldCode, issueValue.IssueCode),
    profileValue.ProfileCode, profileValue.BlocksErp, profileValue.BlocksWeb,
    Severity = COALESCE(requirement.Severity, N''ERROR''),
    ProductCount = COUNT_BIG(DISTINCT issueValue.ProductId)
  FROM val.ProductIssue AS issueValue
  INNER JOIN canon.Product AS product
    ON product.ProductId = issueValue.ProductId AND product.OrganizationId = @OrganizationId
  LEFT JOIN pim.Product AS promoted
    ON promoted.OrganizationId = product.OrganizationId AND promoted.ItemID = product.ItemID
  INNER JOIN val.ValidationProfile AS profileValue
    ON profileValue.ValidationProfileId = issueValue.ValidationProfileId
  LEFT JOIN val.FieldRequirement AS requirement
    ON requirement.FieldRequirementId = issueValue.FieldRequirementId
  WHERE issueValue.IsActive = 1
    AND promoted.PimProductId IS NULL
    AND (profileValue.BlocksErp = 1 OR profileValue.BlocksWeb = 1)
    AND COALESCE(requirement.Severity, N''ERROR'') = N''ERROR''
  GROUP BY COALESCE(requirement.FieldCode, issueValue.IssueCode), profileValue.ProfileCode,
    profileValue.BlocksErp, profileValue.BlocksWeb, COALESCE(requirement.Severity, N''ERROR'')
  ORDER BY COUNT_BIG(DISTINCT issueValue.ProductId) DESC;

  /* Stolpec brez kanonicnega vira ne bo nikoli izpolnjen, ne glede na katalog. */
  SELECT profile.ProfileCode, profile.Name, profile.ChannelCode, profile.EntityType, profile.IsActive,
    ColumnCount = COUNT_BIG(*),
    MappedColumnCount = SUM(CASE WHEN NULLIF(columnDefinition.CanonicalFieldCode, N'''') IS NULL THEN 0 ELSE 1 END),
    UnmappedColumnCount = SUM(CASE WHEN NULLIF(columnDefinition.CanonicalFieldCode, N'''') IS NULL THEN 1 ELSE 0 END),
    RequiredUnmappedCount = SUM(CASE WHEN columnDefinition.IsRequired = 1 AND NULLIF(columnDefinition.CanonicalFieldCode, N'''') IS NULL THEN 1 ELSE 0 END)
  FROM out.ExportProfile AS profile
  INNER JOIN out.ExportColumn AS columnDefinition
    ON columnDefinition.ExportProfileId = profile.ExportProfileId AND columnDefinition.IsActive = 1
  GROUP BY profile.ProfileCode, profile.Name, profile.ChannelCode, profile.EntityType, profile.IsActive
  ORDER BY profile.IsActive DESC, profile.ProfileCode;
END;');
