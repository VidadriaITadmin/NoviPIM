/*
  201 — katalog.csv in stranke.csv: na splet gre, kar ima kljukico, je aktivno in je validirano;
  B2B worker dobi razpored, brez katerega se sploh ne zazene.

  Popravek 2026-09-16: preverba za CustomerTypeCode v razdelku 4 (dokaz) je odstranjena, ker
  migracija 202 (dan kasneje) njeno pravilo namerno razveljavi - glej komentar tam.

  Uporabnik 2026-09-14: »Naredi to da se bo sam zaganjal in dal artikle v katalog. Ampak morajo
  iti artikli, ki so aktivni, ki imajo kljukico svetila ali videlektro in pa potem morajo imeti
  narejeno validacijo.« Nato: »in isto preveri in naredi da bo delalo za stranke«.

  Kaj je bilo narobe (preverjeno nad razvojno bazo 2026-09-14):

    1. out.GetExportRows (147 + zadrzek iz 194) je izdelek za splet izbiral po
       canon.Product.WebPublish, polju iz SAOP, ki ga je uporabnik 2026-09-08 zavrnil (182: »ta
       webpublish to ne bomo vec uporabljali ... check boxi ki bodo povedali, da gre artikel na
       svetila ali videlektro«). Kljukice so od 182 v pim.ProductWebShop, izvoz pa jih ni bral.
       Aktivnosti izdelka (canon.Product.IsActive) izvoz ni preverjal.

    2. Stranka je sla v datoteko samo po pim.CustomerWebProfile.WebEnabled. Neaktivna stranka je
       oznako obdrzala in ostala v izvozu; stranka brez tipa tudi, ceprav pravilo iz 098 pravi
       »stranka brez tipa v izvoz ne sme« — kartica (b2b.SaveCustomerWebProfile) oznako Splet
       dovoli tudi brez tipa. Tip je za stranko to, kar je za izdelek validacija: brez njega ni
       skupine v Magentu in ne pravil cen.

    3. PIM.B2bWorker od 2026-09-14 vsak zagon zacne z ops.BeginRun, ki brez vrstice v
       ops.ScheduleProfile vrze 51100 »Razpored ni omogocen«. Vrstici MAGENTO_PRODUCTS in
       MAGENTO_STOCK_PRICES sta bili dodani rocno samo v bazo namenskega streznika, zato v
       razvojni bazi urni katalog (Katalog-cikel.ps1) in petminutne cene padeta.

  Pravilo po tej migraciji. Spletna stran S (canon.WebSite) je za izdelek dovoljena, ce:
    - ima izdelek kategorijo na S (od 146, nespremenjeno),
    - je izdelek aktiven (canon.Product.IsActive = 1),
    - ima kljukico za drevo strani S (pim.ProductWebShop.WebShopCode = canon.WebSite.CategoryTreeCode,
      IsPublished = 1): svetila_si za svetila_si/svetila_si_en, videlektro za B2C/B2C_EN,
    - nima rocnega spletnega zadrzka (val.ProductHold, 194, nespremenjeno),
    - kadar profil zahteva veljavnost (RequireWebValid = 1, MAGENTO_PRODUCTS): je VALID v vsakem
      aktivnem profilu, ki blokira splet in velja za S (od 146, nespremenjeno; brez stanja = ni VALID).
  Stranka gre v datoteko, ce je aktivna (b2b.Customer.IsActive = 1), ima oznako Splet
  (WebEnabled = 1) in ima tip (CustomerTypeCode).

  out.GetExportRows se spremeni enako kot v 194: definicija se prebere iz baze in v njej se
  zamenjata dva enovrsticna izraza — postopek ima 600 vrstic in ga ne prepisujemo. Pred
  zamenjavo se prestejeta; ce definicija ni taka, kot jo je pustila 194, migracija pade, namesto
  da bi zamenjala napacno mesto. intranet.GetExportReadiness (stevci na /splet) se prepise v
  celoti z istim pravilom, sicer bi /splet kazal drugo stevilo, kot ga ima datoteka.

  Migrator ne pozna locila GO; procedure so v EXEC(N'...').
*/

SET XACT_ABORT ON;

/* --- 1) out.GetExportRows: kljukica in aktivnost izdelka, aktivnost in tip stranke --------- */

DECLARE @Definition nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows'));
IF @Definition IS NULL THROW 52201, N'201: out.GetExportRows ne obstaja.', 1;

IF @Definition NOT LIKE N'%ProductWebShop /* 201 */%'
BEGIN
  DECLARE @ProductOld nvarchar(100) = N'canonProduct.WebPublish = 1';
  DECLARE @ProductNew nvarchar(400) = N'(canonProduct.IsActive = 1 AND EXISTS (SELECT 1 FROM pim.ProductWebShop /* 201 */ AS shop WHERE shop.ProductId = canonProduct.ProductId AND shop.WebShopCode = site.CategoryTreeCode AND shop.IsPublished = 1))';
  DECLARE @CustomerOld nvarchar(100) = N'(@OnlyPublished = 0 OR profile.WebEnabled = 1)';
  DECLARE @CustomerNew nvarchar(400) = N'(@OnlyPublished = 0 OR (profile.WebEnabled = 1 AND customer.IsActive = 1 AND profile.CustomerTypeCode IS NOT NULL /* 201 */))';

  /* Izbor strani (B0) ima pogoj dvakrat — pri @OnlyPublished in pri @RequireWebValid; stranke
     imajo isti filter pri stevcu in pri strani. */
  IF (LEN(@Definition) - LEN(REPLACE(@Definition, @ProductOld, N''))) / LEN(@ProductOld) <> 2
    THROW 52202, N'201: out.GetExportRows nima pricakovanih dveh pogojev canonProduct.WebPublish = 1.', 1;
  IF (LEN(@Definition) - LEN(REPLACE(@Definition, @CustomerOld, N''))) / LEN(@CustomerOld) <> 2
    THROW 52203, N'201: out.GetExportRows nima pricakovanih dveh filtrov strank po WebEnabled.', 1;

  SET @Definition = REPLACE(REPLACE(@Definition, @ProductOld, @ProductNew), @CustomerOld, @CustomerNew);

  /* Shranjena definicija se zacne s CREATE [OR ALTER]; vse pred besedo PROCEDURE postane ALTER. */
  DECLARE @HeaderEnd int = CHARINDEX(N'PROCEDURE', @Definition);
  IF @HeaderEnd = 0 OR LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
       LEFT(@Definition, @HeaderEnd - 1), N'CREATE', N''), N'OR ALTER', N''), NCHAR(13), N''), NCHAR(10), N''), NCHAR(9), N''))) <> N''
    THROW 52204, N'201: glava out.GetExportRows ni CREATE [OR ALTER] PROCEDURE.', 1;
  SET @Definition = N'ALTER ' + SUBSTRING(@Definition, @HeaderEnd, 2147483647);

  EXEC sys.sp_executesql @Definition;
END;

/* --- 2) Stevci na /splet po istem pravilu ---------------------------------------------------- */

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetExportReadiness
  @OrganizationId int,
  @TopReasons int = 20
AS
BEGIN
  SET NOCOUNT ON;
  SET @TopReasons = CASE WHEN @TopReasons < 1 THEN 20 WHEN @TopReasons > 100 THEN 100 ELSE @TopReasons END;

  /* Zastavice po izdelku najprej (podpoizvedbe v agregatu SQL Server ne dovoli), nato sestevek.
     201: za splet je izdelek, ki je aktiven in ima kljukico spletisca (pim.ProductWebShop), ne
     vec zastavica iz SAOP. HasSite = kategorija na strani, katere drevo je oznaceno;
     HasAllowedSite = vsaj ena taka stran brez spletnega zadrzka in VALID v profilih, ki za to
     stran blokirajo splet. To je izbor strani iz out.GetExportRows, zato je WebExportableCount
     stevilo vrstic v katalog.csv. */
  SELECT
    CanonicalCount = COUNT_BIG(*),
    ActiveCount = SUM(CASE WHEN flags.IsActive = 1 THEN 1 ELSE 0 END),
    PublishedCount = SUM(CASE WHEN flags.PimProductId IS NULL THEN 0 ELSE 1 END),
    NotPublishedCount = SUM(CASE WHEN flags.PimProductId IS NULL THEN 1 ELSE 0 END),
    WebFlaggedCount = SUM(CASE WHEN flags.WebFlagged = 1 THEN 1 ELSE 0 END),
    PublishedWithOpenIssues = SUM(CASE WHEN flags.PimProductId IS NOT NULL AND flags.ValidationStatus <> N''VALID'' THEN 1 ELSE 0 END),
    WebSiteMissingCount = SUM(CASE WHEN flags.PimProductId IS NOT NULL AND flags.WebFlagged = 1 AND flags.HasSite = 0 THEN 1 ELSE 0 END),
    WebInvalidCount = SUM(CASE WHEN flags.PimProductId IS NOT NULL AND flags.WebFlagged = 1 AND flags.HasSite = 1 AND flags.HasAllowedSite = 0 THEN 1 ELSE 0 END),
    WebExportableCount = SUM(CASE WHEN flags.PimProductId IS NOT NULL AND flags.WebFlagged = 1 AND flags.HasAllowedSite = 1 THEN 1 ELSE 0 END)
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

/* --- 3) Razpored za B2B worker (ops.BeginRun brez vrstice vrze 51100) ----------------------- */

/* Samo manjkajoce vrstice: kjer razpored ze obstaja (namenski streznik), ostane, kakrsen je —
   tudi izklopljen, ce ga je kdo izklopil namenoma. Katalog na uro (uporabnik 2026-09-10),
   cene in zaloga na pet minut, enako kot Katalog-cikel.ps1 in Zaloga-cikel.ps1. */
MERGE ops.ScheduleProfile AS target
USING
(
  SELECT organization.OrganizationId, schedule.Pipeline, schedule.IntervalSeconds, schedule.StaleAfterSeconds
  FROM dbo.OrganizationConfig AS organization
  CROSS JOIN (VALUES (N'MAGENTO_PRODUCTS', 3600, 7200), (N'MAGENTO_STOCK_PRICES', 300, 900))
    AS schedule (Pipeline, IntervalSeconds, StaleAfterSeconds)
) AS source
  ON target.OrganizationId = source.OrganizationId AND target.Pipeline = source.Pipeline
WHEN NOT MATCHED THEN
  INSERT (OrganizationId, Provider, Pipeline, IsEnabled, IntervalSeconds, StaleAfterSeconds, LockTimeoutMilliseconds, UpdatedBy)
  VALUES (source.OrganizationId, N'MAGENTO', source.Pipeline, 1, source.IntervalSeconds,
          source.StaleAfterSeconds, 5000, N'migracija 201');

/* --- 4) dokaz ------------------------------------------------------------------------------- */

SET @Definition = OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows'));
IF @Definition NOT LIKE N'%ProductWebShop /* 201 */%'
  THROW 52205, N'201: out.GetExportRows ne bere kljukic spletisc.', 1;
IF @Definition LIKE N'%canonProduct.WebPublish%'
  THROW 52206, N'201: out.GetExportRows se vedno izbira izdelke po WebPublish.', 1;
/* 2026-09-16: preverba za oznako CustomerTypeCode-201 (glej @CustomerNew zgoraj) je odstranjena.
   Migracija 202 (dan kasneje) je uporabnikovo odlocitev iz te vrstice ("tip stranke je pogoj za
   izvoz") namerno razveljavila ("tip stranke ni vec pogoj za izvoz, samo aktivnost") - ta preverba
   je zato preverjala stanje, ki naj po 202 sploh ne bi vec obstajalo, in je 201 naredila trajno
   nemozno ponovno pognati na katerikoli bazi, kjer je 202 ze tekla. Zamenjava besedila tik nad
   to vrstico ostane nespremenjena (na svezi bazi 201 se vedno naredi vmesno stanje z oznako
   CustomerTypeCode-201, ki ga 202 takoj popravi naprej) - odstranjena je samo napacna trditev, da
   mora to vmesno stanje obveljati za trajno. */
IF @Definition NOT LIKE N'%ProductHold /* 194 */%'
  THROW 52208, N'201: spletni zadrzek iz 194 je izginil iz out.GetExportRows.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'intranet.GetExportReadiness')) LIKE N'%.WebPublish%'
  THROW 52209, N'201: stevci na /splet se vedno stejejo po WebPublish.', 1;
IF EXISTS (SELECT 1 FROM dbo.OrganizationConfig AS organization
           CROSS JOIN (VALUES (N'MAGENTO_PRODUCTS'), (N'MAGENTO_STOCK_PRICES')) AS required (Pipeline)
           WHERE NOT EXISTS (SELECT 1 FROM ops.ScheduleProfile AS schedule
                             WHERE schedule.OrganizationId = organization.OrganizationId
                               AND schedule.Pipeline = required.Pipeline))
  THROW 52210, N'201: B2B worker nima razporeda za vsa podjetja; ops.BeginRun bi vrgel 51100.', 1;

/* Izvedba nad resnicnimi podatki: oba spremenjena postopka se morata prevesti in izvesti.
   Migrator rezultat zavrze. */
DECLARE @ProbeOrganizationId int = (SELECT MIN(OrganizationId) FROM dbo.OrganizationConfig);
DECLARE @ProbeProductProfileId int =
  (SELECT ExportProfileId FROM out.ExportProfile WHERE ProfileCode = N'MAGENTO_PRODUCTS' AND IsActive = 1);
DECLARE @ProbeCustomerProfileId int =
  (SELECT ExportProfileId FROM out.ExportProfile WHERE ProfileCode = N'MAGENTO_CUSTOMERS' AND IsActive = 1);
DECLARE @ProbeTotal int;
IF @ProbeOrganizationId IS NOT NULL AND @ProbeProductProfileId IS NOT NULL
  EXEC out.GetExportRows @OrganizationId = @ProbeOrganizationId, @ExportProfileId = @ProbeProductProfileId,
    @Take = 1, @TotalCount = @ProbeTotal OUTPUT;
IF @ProbeOrganizationId IS NOT NULL AND @ProbeCustomerProfileId IS NOT NULL
  EXEC out.GetExportRows @OrganizationId = @ProbeOrganizationId, @ExportProfileId = @ProbeCustomerProfileId,
    @Take = 1, @TotalCount = @ProbeTotal OUTPUT;
IF @ProbeOrganizationId IS NOT NULL
  EXEC intranet.GetExportReadiness @OrganizationId = @ProbeOrganizationId;
