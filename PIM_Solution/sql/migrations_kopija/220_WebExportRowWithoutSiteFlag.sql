/*
  220 — katalog.csv: izdelek brez oznacene spletne strani ostane v datoteki, stolpec "Spletne
  strani" pa je zanj prazen.

  Uporabnik 2026-09-15 (po 201/213): »Magento potem ne bo vedu kateri gre vn. Tako da artikel
  mora priti v katalog.csv tudi ce nima nobene spletne strani oznacene, samo to polje je prazno in
  na podlagi tega bo on videl kako in kaj.«

  Do te migracije (201): izdelek je sel v katalog.csv samo, ce je imel vsaj eno vrstico v #Site —
  kar je zahtevalo kljukico (pim.ProductWebShop.IsPublished = 1) za vsaj eno spletno stran.
  Izdelek brez ANY kljukice zato v datoteki ni obstajal — cela vrstica je izpadla, ne samo stolpec
  "Spletne strani". Magento tako ni imel signala, da je bil izdelek nekoc na strani in ga je zdaj
  treba umakniti: iz praznega feeda se ne da razlikovati med »se ni bil nikoli objavljen« in
  »ravnokar odjavljen«.

  Pravilo po tej migraciji. Vrstica gre v katalog.csv, ce:
    - ustreza obstojecemu pravilu (vsaj ena stran v #Site: kategorija + kljukica + veljavnost,
      146/201/213 — nespremenjeno), ALI
    - (novo) izdelek nima NOBENE kljukice v pim.ProductWebShop, JE aktiven, nima rocnega spletnega
      zadrzka (val.ProductHold) in ni izkljucen s politiko kataloga (pim.CatalogPolicy) — takrat
      pride v datoteko brez nobene site v #Site, stolpec "Spletne strani" (Product.WebSites, ze od
      213 neodvisno racunan iz istih kljukic) pa ostane prazen, ker STRING_AGG nad praznim naborom
      vrne NULL.
  Nova veja se namerno NE sprozi, ce ima izdelek kljukico za katero koli stran, pa je ta stran
  izpadla iz #Site iz DRUGEGA razloga (kategorija manjka, zadrzek, ni veljaven) — to ostaja
  obstojece pravilo iz 201/146 in se s to migracijo ne spremeni. Ravno tako se ne sprozi, kadar
  klicatelj filtrira na eno konkretno stran (@WebSite ni NULL): izdelek brez nobene site takrat ni
  del filtrirane množice tiste konkretne strani.

  Ista sprememba gre v intranet.GetExportReadiness (WebExportableCount), da /splet kaze isto
  stevilo vrstic, kot jih bo imela datoteka — enako pravilo kot v 201.

  Procedura out.GetExportRows se od 171 popravlja z zamenjavo besedila zive definicije
  (194/201/202/204/205/206/207/213); enako tu, z oznako /* NoSiteStillExported220 */.
  Migrator ne pozna GO, zato CREATE OR ALTER v EXEC(N'...').
*/

SET XACT_ABORT ON;

/* --- 1) out.GetExportRows: brez kljukice ne izpade cela vrstica, samo Spletne strani ------- */

DECLARE @definition nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows'));
IF @definition IS NULL THROW 52201, N'220: out.GetExportRows ne obstaja.', 1;
IF @definition NOT LIKE N'%/* WebSitesFromFlags213 */%'
  THROW 52202, N'220: out.GetExportRows nima popravka 213 (Spletne strani iz kljukic).', 1;

IF @definition NOT LIKE N'%/* NoSiteStillExported220 */%'
BEGIN
  DECLARE @old nvarchar(max) = N'      AND EXISTS (SELECT 1 FROM #Site AS site WHERE site.PimProductId = product.PimProductId)';
  DECLARE @new nvarchar(max) = N'      AND (EXISTS (SELECT 1 FROM #Site AS site WHERE site.PimProductId = product.PimProductId)
        OR (@WebSite IS NULL AND EXISTS (SELECT 1 FROM canon.Product AS webProduct
              WHERE webProduct.OrganizationId = product.OrganizationId AND webProduct.ItemID = product.ItemID
                AND webProduct.IsActive = 1
                AND NOT EXISTS (SELECT 1 FROM pim.ProductWebShop AS shop WHERE shop.ProductId = webProduct.ProductId AND shop.IsPublished = 1)
                AND NOT EXISTS (SELECT 1 FROM pim.CatalogPolicy AS policy WHERE policy.ProductId = webProduct.ProductId AND policy.IsExcluded = 1)
                AND NOT EXISTS (SELECT 1 FROM val.ProductHold AS hold WHERE hold.ProductId = webProduct.ProductId AND hold.IsActive = 1 AND hold.ChannelCode IN (N''ALL'', N''WEB'')))))
      /* NoSiteStillExported220 */';

  /* Isti izraz nastopi dvakrat: enkrat za @TotalCount, enkrat za dejanski #Page. */
  IF (LEN(@definition) - LEN(REPLACE(@definition, @old, N''))) / LEN(@old) <> 2
    THROW 52203, N'220: out.GetExportRows nima pricakovanih dveh pogojev EXISTS (#Site).', 1;
  SET @definition = REPLACE(@definition, @old, @new);

  SET @definition = N'ALTER ' + SUBSTRING(@definition, CHARINDEX(N'PROCEDURE', @definition), 2147483647);
  EXEC sys.sp_executesql @definition;
END;

/* --- 2) intranet.GetExportReadiness: WebExportableCount naj se ujema s katalog.csv --------- */

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetExportReadiness
  @OrganizationId int,
  @TopReasons int = 20
AS
BEGIN
  SET NOCOUNT ON;
  SET @TopReasons = CASE WHEN @TopReasons < 1 THEN 20 WHEN @TopReasons > 100 THEN 100 ELSE @TopReasons END;

  /* Zastavice po izdelku najprej (podpoizvedbe v agregatu SQL Server ne dovoli), nato sestevek.
     220: izdelek brez nobene kljukice spletisca gre v katalog.csv tudi sam (Spletne strani prazne),
     ce je aktiven, brez zadrzka in ni izkljucen s politiko kataloga — NoSiteExportable. Sicer
     nespremenjeno od 201/206: WebExportableCount je stevilo vrstic v katalog.csv. */
  SELECT
    CanonicalCount = COUNT_BIG(*),
    ActiveCount = SUM(CASE WHEN flags.IsActive = 1 THEN 1 ELSE 0 END),
    PublishedCount = SUM(CASE WHEN flags.PimProductId IS NULL THEN 0 ELSE 1 END),
    NotPublishedCount = SUM(CASE WHEN flags.PimProductId IS NULL THEN 1 ELSE 0 END),
    WebFlaggedCount = SUM(CASE WHEN flags.WebFlagged = 1 THEN 1 ELSE 0 END),
    PublishedWithOpenIssues = SUM(CASE WHEN flags.PimProductId IS NOT NULL AND flags.ValidationStatus <> N''VALID'' THEN 1 ELSE 0 END),
    WebSiteMissingCount = SUM(CASE WHEN flags.PimProductId IS NOT NULL AND flags.WebFlagged = 1 AND flags.HasSite = 0 THEN 1 ELSE 0 END),
    WebInvalidCount = SUM(CASE WHEN flags.PimProductId IS NOT NULL AND flags.WebFlagged = 1 AND flags.HasSite = 1 AND flags.HasAllowedSite = 0 THEN 1 ELSE 0 END),
    WebExportableCount = SUM(CASE WHEN flags.PimProductId IS NOT NULL
      AND ((flags.WebFlagged = 1 AND flags.HasAllowedSite = 1) OR flags.NoSiteExportable = 1)
      THEN 1 ELSE 0 END) /* NoSiteStillExported220 */
  FROM
  (
    SELECT product.ProductId, product.IsActive, product.ValidationStatus, promoted.PimProductId,
      WebFlagged = CASE WHEN product.IsActive = 1 AND EXISTS
        (SELECT 1 FROM pim.ProductWebShop AS shop
         WHERE shop.ProductId = product.ProductId AND shop.IsPublished = 1) THEN 1 ELSE 0 END,
      HasSite = CASE WHEN EXISTS
        (SELECT 1 FROM pim.ProductCategory AS category
         INNER JOIN canon.WebSite AS site ON site.WebSiteCode = category.WebSite AND site.IsActive = 1
         INNER JOIN pim.ProductWebShop AS shop
           ON shop.ProductId = product.ProductId AND shop.WebShopCode = site.CategoryTreeCode AND shop.IsPublished = 1
         WHERE category.PimProductId = promoted.PimProductId) THEN 1 ELSE 0 END,
      HasAllowedSite = CASE WHEN
        NOT EXISTS(SELECT 1 FROM pim.CatalogPolicy policy WHERE policy.ProductId=product.ProductId AND policy.IsExcluded=1) AND /* CatalogReadiness206 */
        NOT EXISTS (SELECT 1 FROM val.ProductHold AS hold
                    WHERE hold.ProductId = product.ProductId AND hold.IsActive = 1 AND hold.ChannelCode IN (N''ALL'', N''WEB''))
        AND EXISTS
        (SELECT 1 FROM pim.ProductCategory AS category
         INNER JOIN canon.WebSite AS site ON site.WebSiteCode = category.WebSite AND site.IsActive = 1
         INNER JOIN pim.ProductWebShop AS shop
           ON shop.ProductId = product.ProductId AND shop.WebShopCode = site.CategoryTreeCode AND shop.IsPublished = 1
         WHERE category.PimProductId = promoted.PimProductId
           AND NOT EXISTS
             (SELECT 1 FROM val.ValidationProfile AS profile
              LEFT JOIN val.ProductValidationState AS state
                ON state.ProductId = product.ProductId AND state.ValidationProfileId = profile.ValidationProfileId
              WHERE profile.IsActive = 1 AND profile.BlocksWeb = 1
                AND (profile.CategoryTreeCode IS NULL OR profile.CategoryTreeCode = site.CategoryTreeCode)
                AND ISNULL(state.Status, N''INVALID'') <> N''VALID''))
        THEN 1 ELSE 0 END,
      NoSiteExportable = CASE WHEN product.IsActive = 1
        AND NOT EXISTS (SELECT 1 FROM pim.ProductWebShop AS shop WHERE shop.ProductId = product.ProductId AND shop.IsPublished = 1)
        AND NOT EXISTS (SELECT 1 FROM pim.CatalogPolicy AS policy WHERE policy.ProductId = product.ProductId AND policy.IsExcluded = 1)
        AND NOT EXISTS (SELECT 1 FROM val.ProductHold AS hold WHERE hold.ProductId = product.ProductId AND hold.IsActive = 1 AND hold.ChannelCode IN (N''ALL'', N''WEB''))
        THEN 1 ELSE 0 END
    FROM canon.Product AS product
    LEFT JOIN pim.Product AS promoted
      ON promoted.OrganizationId = product.OrganizationId AND promoted.ItemID = product.ItemID
    WHERE product.OrganizationId = @OrganizationId
  ) AS flags;

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

  SELECT profile.ProfileCode, profile.Name, profile.ChannelCode, profile.EntityType, profile.IsActive,
    ColumnCount = COUNT_BIG(columnDefinition.ExportColumnId),
    MappedColumnCount = SUM(CASE WHEN NULLIF(columnDefinition.CanonicalFieldCode, N'''') IS NULL THEN 0 ELSE 1 END),
    UnmappedColumnCount = SUM(CASE WHEN NULLIF(columnDefinition.CanonicalFieldCode, N'''') IS NULL THEN 1 ELSE 0 END),
    RequiredUnmappedCount = SUM(CASE WHEN columnDefinition.IsRequired = 1 AND NULLIF(columnDefinition.CanonicalFieldCode, N'''') IS NULL THEN 1 ELSE 0 END)
  FROM out.ExportProfile AS profile
  LEFT JOIN out.ExportColumn AS columnDefinition
    ON columnDefinition.ExportProfileId = profile.ExportProfileId AND columnDefinition.IsActive = 1
  GROUP BY profile.ExportProfileId, profile.ProfileCode, profile.Name, profile.ChannelCode, profile.EntityType, profile.IsActive
  ORDER BY profile.ProfileCode;
END');

/* --- 3) Dokaz ------------------------------------------------------------------------------- */

IF OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows')) NOT LIKE N'%/* NoSiteStillExported220 */%'
  THROW 52204, N'220: out.GetExportRows se vedno izpusca cele vrstice brez kljukice.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'intranet.GetExportReadiness')) NOT LIKE N'%/* NoSiteStillExported220 */%'
  THROW 52205, N'220: intranet.GetExportReadiness ne steje izdelkov brez kljukice.', 1;

/* Izvedba nad resnicnimi podatki: obe spremenjeni proceduri se morata prevesti in izvesti brez
   napake. Migrator rezultat zavrze. */
DECLARE @probeOrganizationId int = (SELECT MIN(OrganizationId) FROM dbo.OrganizationConfig);
DECLARE @probeProductProfileId int =
  (SELECT ExportProfileId FROM out.ExportProfile WHERE ProfileCode = N'MAGENTO_PRODUCTS' AND IsActive = 1);
DECLARE @probeTotal int;
IF @probeOrganizationId IS NOT NULL AND @probeProductProfileId IS NOT NULL
  EXEC out.GetExportRows @OrganizationId = @probeOrganizationId, @ExportProfileId = @probeProductProfileId,
    @OnlyPublished = 1, @Take = 1, @TotalCount = @probeTotal OUTPUT;
IF @probeOrganizationId IS NOT NULL
  EXEC intranet.GetExportReadiness @OrganizationId = @probeOrganizationId;
