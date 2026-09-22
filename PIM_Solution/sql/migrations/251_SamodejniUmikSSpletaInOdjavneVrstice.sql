/*
  251 — Samodejni umik s spleta in odjavne vrstice v katalog.csv.

  Uporabnik 2026-09-22: »v katalog.csv samo artikli, ki so aktivni, imajo kljukico svetila ali
  videlektro in so veljavni za splet. Če artikel ni veljaven za splet (npr. se mu pobriše slika),
  se mora avtomatsko odkljukati iz obeh strani in uporabnik mora dobiti opozorilo, kaj manjka.«
  Prazno polje »Spletne strani« Magento razume kot umik z vseh spletišč (potrdil uporabnik), zato
  artikel, ki je bil na spletu, v datoteki ostane še nekaj dni s praznim poljem; artikel, ki ni bil
  nikoli na spletu, v datoteko ne gre.

  Stanje pred to migracijo (podjetje 2, 22. 9. 2026): katalog.csv 89.463 vrstic (25,6 MB, ~100 s),
  od tega 87.287 s praznimi »Spletne strani« (pravilo 220: vsak aktiven artikel brez kljukice) in
  2.176 objavljenih. 420 artiklov s kljukico, ki niso veljavni, je iz datoteke tiho izpadlo — brez
  signala za umik, zato jih Magento ni umaknil.

  Kaj naredi:
    1. out.WebPublication: kaj je bilo v zadnjem uspešnem katalog.csv objavljeno (šifra, spletne
       strani) in kdaj je šla prva odjavna vrstica. Piše jo worker po uspešni zamenjavi datotek
       (out.RecordWebPublication). Začetno stanje: vsi artikli s kljukico — tudi neveljavni, ki so
       morda še na Magentu iz starejših izvozov; ti dobijo odjavno vrstico.
    2. out.GetExportRows (profil z novim stolpcem out.ExportProfile.IncludeWithdrawals = 1, torej
       MAGENTO_PRODUCTS) namesto veje 220 (vsi aktivni brez kljukice):
         - objavljen artikel (#Site, pravila nespremenjena); »Spletne strani« so odslej samo
           spletišča, na katera artikel dejansko gre (kljukica + kategorija + veljaven), ne vse
           kljukice (213) — manjkajoče spletišče se v stolpcu ne pojavi;
         - odjavna vrstica: artikel, ki je bil objavljen, zdaj pa ne gre na nobeno spletišče
           (odkljukan, neveljaven, neaktiven, zadržek, izključen), s praznimi »Spletne strani«,
           še WithdrawalRowDays dni (privzeto 14) po prvem izvozu z odjavo.
       MAGENTO_STOCK_PRICES: RequireWebValid = 1 — cene in zaloga samo za objavljene artikle.
    3. pim.WebPublicationPolicy: po podjetju vklop samodejnega umika (privzeto IZKLOPLJEN — skrbnik
       ga vklopi na /splet/umaknjeni po pregledu predogleda) in dolžina odjavnega okna.
    4. pim.WebShopEligibility: za vsako kljukico, ali artikel na to spletišče sme — aktiven,
       kategorija na drevesu spletišča (canon, ne čaka na objavo v pim), VALID v vseh aktivnih
       profilih, ki blokirajo splet in veljajo za to drevo. Ročni zadržek in izključitev iz
       kataloga NISTA razlog za odkljukanje (namerni začasni odločitvi; artikel samo ne gre ven).
       Manjkajoče stanje validacije (validacija še ni tekla) ni razlog za odkljukanje.
    5. pim.WithdrawIneligibleWebShops: odkljuka kljukice, ki niso dovoljene. Razlog zapiše PREJ
       (pim.WebShopWithdrawal: polja z napako, neveljavni profili, brez kategorije, neaktiven), ker
       248 ob odkljukanju pobriše spletno stanje in zapre spletne napake. Nato odkljuka, zapiše
       zgodovino (pim.ProductFieldHistory, avtor SISTEM), ponovno validira in osveži opozorilo.
       Načini: AUTO (samo podjetje z vklopljenim umikom), PREVIEW (nič ne spremeni, vrne seznam),
       FORCE (ne glede na vklop — skrbnik, testi). @Revalidate = 1 kandidate najprej ponovno
       validira (stanje je lahko staro: kategorija s kartice, SAOP, uvoz).
    6. pim.SaveProductWebShops: nova kljukica na artiklu, ki na to spletišče ne sme, se ne obdrži;
       drugi nabor pove zakaj. Sprejeta kljukica zapre odprte umike tega spletišča.
    7. Opozorilo WebShopWithdrawn (ops.Alert, Warning, ena vrstica na podjetje, dokler kak umik ni
       pregledan ali popravljen); naročnine in pregled umikov (pim.ReviewWebShopWithdrawals).
    8. val.ProductChannelReadiness: IsInCatalogCsv šteje odjavne vrstice namesto pravila 220; nov
       stolpec IsWithdrawalRow.
    9. Bralne procedure za stran /splet/umaknjeni in kartico; pravica view.web.withdrawals.

  Migrator ne pozna GO, zato CREATE OR ALTER v EXEC(N'...'). Dolgo proceduro out.GetExportRows in
  pogled val.ProductChannelReadiness popravi zamenjava na živi definiciji s štetjem sider (201/220).
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

/* --- 1) Register: odjavne vrstice na profilu, politika podjetja, objava, umiki ------------------ */
IF COL_LENGTH(N'out.ExportProfile', N'IncludeWithdrawals') IS NULL
  ALTER TABLE out.ExportProfile ADD IncludeWithdrawals bit NOT NULL
    CONSTRAINT DF_ExportProfile_IncludeWithdrawals DEFAULT (0);

EXEC(N'UPDATE out.ExportProfile SET IncludeWithdrawals = 1, UpdatedUtc = SYSUTCDATETIME()
  WHERE ProfileCode = N''MAGENTO_PRODUCTS'' AND IncludeWithdrawals = 0;');

UPDATE out.ExportProfile SET RequireWebValid = 1, UpdatedUtc = SYSUTCDATETIME()
WHERE ProfileCode = N'MAGENTO_STOCK_PRICES' AND RequireWebValid = 0;

IF OBJECT_ID(N'pim.WebPublicationPolicy', N'U') IS NULL
  CREATE TABLE pim.WebPublicationPolicy
  (
    OrganizationId int NOT NULL CONSTRAINT PK_WebPublicationPolicy PRIMARY KEY
      CONSTRAINT FK_WebPublicationPolicy_Organization REFERENCES dbo.OrganizationConfig (OrganizationId),
    AutoWithdrawEnabled bit NOT NULL CONSTRAINT DF_WebPublicationPolicy_AutoWithdraw DEFAULT (0),
    WithdrawalRowDays int NOT NULL CONSTRAINT DF_WebPublicationPolicy_Days DEFAULT (14)
      CONSTRAINT CK_WebPublicationPolicy_Days CHECK (WithdrawalRowDays BETWEEN 1 AND 365),
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_WebPublicationPolicy_UpdatedUtc DEFAULT (SYSUTCDATETIME()),
    UpdatedBy nvarchar(200) NOT NULL
  );

INSERT pim.WebPublicationPolicy (OrganizationId, UpdatedBy)
SELECT organization.OrganizationId, N'251_SamodejniUmikSSpletaInOdjavneVrstice'
FROM dbo.OrganizationConfig AS organization
WHERE NOT EXISTS (SELECT 1 FROM pim.WebPublicationPolicy AS existing WHERE existing.OrganizationId = organization.OrganizationId);

IF OBJECT_ID(N'out.WebPublication', N'U') IS NULL
  CREATE TABLE out.WebPublication
  (
    OrganizationId int NOT NULL,
    ItemID nvarchar(100) NOT NULL,
    /* Zadnje objavljene spletne strani (oznake dreves, npr. svetila|videlektro); ostane tudi po umiku. */
    WebSites nvarchar(400) NOT NULL,
    FirstPublishedUtc datetime2(3) NOT NULL,
    LastPublishedUtc datetime2(3) NOT NULL,
    /* Prvi izvoz z odjavno vrstico; NULL = artikel je (bil v zadnjem izvozu) objavljen. */
    WithdrawnUtc datetime2(3) NULL,
    LastExportedUtc datetime2(3) NULL,
    Source nvarchar(40) NOT NULL CONSTRAINT DF_WebPublication_Source DEFAULT (N'IZVOZ'),
    CONSTRAINT PK_WebPublication PRIMARY KEY (OrganizationId, ItemID)
  );

/* Začetno stanje: vsak artikel s kljukico velja za objavljenega. Veljavni gredo v datoteko kot doslej,
   neveljavni (izpadli brez signala) dobijo odjavno vrstico. Artikli brez kljukice so od 220 vsak izvoz
   dobili prazne »Spletne strani« in so torej že umaknjeni. */
INSERT out.WebPublication (OrganizationId, ItemID, WebSites, FirstPublishedUtc, LastPublishedUtc, Source)
SELECT product.OrganizationId, product.ItemID,
  ISNULL((SELECT STRING_AGG(CONVERT(nvarchar(max), label.TreeLabel), N'|') WITHIN GROUP (ORDER BY label.SortOrder, label.TreeLabel)
          FROM (SELECT ISNULL(MIN(web.TreeLabel), web.CategoryTreeCode) AS TreeLabel, MIN(web.SortOrder) AS SortOrder
                FROM pim.ProductWebShop AS flag
                INNER JOIN canon.WebSite AS web ON web.CategoryTreeCode = flag.WebShopCode AND web.IsActive = 1
                WHERE flag.ProductId = product.ProductId AND flag.IsPublished = 1
                GROUP BY web.CategoryTreeCode) AS label), N''),
  SYSUTCDATETIME(), SYSUTCDATETIME(), N'ZACETNO_STANJE_251'
FROM canon.Product AS product
WHERE EXISTS (SELECT 1 FROM pim.ProductWebShop AS shop WHERE shop.ProductId = product.ProductId AND shop.IsPublished = 1)
  AND NOT EXISTS (SELECT 1 FROM out.WebPublication AS existing
                  WHERE existing.OrganizationId = product.OrganizationId AND existing.ItemID = product.ItemID);

IF OBJECT_ID(N'pim.WebShopWithdrawal', N'U') IS NULL
BEGIN
  CREATE TABLE pim.WebShopWithdrawal
  (
    WebShopWithdrawalId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_WebShopWithdrawal PRIMARY KEY,
    OrganizationId int NOT NULL,
    ProductId bigint NOT NULL,
    ItemID nvarchar(100) NOT NULL,
    WebShopCode nvarchar(100) NOT NULL,
    WasInactive bit NOT NULL,
    HadCategory bit NOT NULL,
    /* Profili, ki blokirajo splet in so bili ob umiku INVALID (npr. SHARED_CORE, WEB_svetila_si). */
    InvalidProfiles nvarchar(400) NULL,
    /* Kode polj z odprto blokirajočo napako ob umiku (val.FieldRequirement.FieldCode), ločene z |. */
    MissingFields nvarchar(max) NULL,
    TriggerSource nvarchar(50) NOT NULL,
    TriggeredBy nvarchar(200) NULL,
    WithdrawnUtc datetime2(3) NOT NULL CONSTRAINT DF_WebShopWithdrawal_WithdrawnUtc DEFAULT (SYSUTCDATETIME()),
    ReviewedUtc datetime2(3) NULL,
    ReviewedBy nvarchar(200) NULL,
    RestoredUtc datetime2(3) NULL,
    RestoredBy nvarchar(200) NULL
  );
  CREATE INDEX IX_WebShopWithdrawal_Organization ON pim.WebShopWithdrawal (OrganizationId, WithdrawnUtc DESC);
  CREATE INDEX IX_WebShopWithdrawal_Product ON pim.WebShopWithdrawal (ProductId, WebShopCode);
END;

/* --- 2) Kdaj artikel na spletišče sme (za odkljukanje in za novo kljukico) --------------------- */
EXEC(N'CREATE OR ALTER VIEW pim.WebShopEligibility
AS
/*
  251: ena vrstica na kljukico (pim.ProductWebShop.IsPublished = 1). Pravilo je isto kot #Site v
  out.GetExportRows, le da je kategorija iz canon (kartica jo zapise tja takoj, pim.ProductCategory
  pa jo dobi sele ob objavi) in da zadrzek/izkljucitev nista razlog za umik kljukice.
  IsWithdrawable = kljukico je treba umakniti; IsEligible = artikel na to spletisce gre.
*/
SELECT shop.ProductId, product.OrganizationId, product.ItemID, shop.WebShopCode,
  IsActive = CONVERT(bit, product.IsActive),
  HasCategory = CONVERT(bit, rule251.HasCategory),
  rule251.InvalidProfiles,
  rule251.MissingStateCount,
  IsEligible = CONVERT(bit, CASE WHEN product.IsActive = 1 AND rule251.HasCategory = 1
    AND rule251.InvalidProfiles IS NULL AND rule251.MissingStateCount = 0 THEN 1 ELSE 0 END),
  IsWithdrawable = CONVERT(bit, CASE WHEN product.IsActive = 0 OR rule251.HasCategory = 0
    OR rule251.InvalidProfiles IS NOT NULL THEN 1 ELSE 0 END)
FROM pim.ProductWebShop AS shop
INNER JOIN canon.Product AS product ON product.ProductId = shop.ProductId
CROSS APPLY
(
  SELECT
    HasCategory = CASE WHEN EXISTS
      (SELECT 1 FROM canon.ProductCategory AS category
       INNER JOIN canon.WebSite AS site
         ON site.WebSiteCode = category.WebSite AND site.IsActive = 1 AND site.CategoryTreeCode = shop.WebShopCode
       WHERE category.ProductId = shop.ProductId AND NULLIF(category.CategoryPath, N'''') IS NOT NULL) THEN 1 ELSE 0 END,
    InvalidProfiles =
      (SELECT STRING_AGG(profile.ProfileCode, N'', '') WITHIN GROUP (ORDER BY profile.ProfileCode)
       FROM val.ValidationProfile AS profile
       INNER JOIN val.ProductValidationState AS state
         ON state.ProductId = shop.ProductId AND state.ValidationProfileId = profile.ValidationProfileId
       WHERE profile.IsActive = 1 AND profile.BlocksWeb = 1
         AND (profile.CategoryTreeCode IS NULL OR profile.CategoryTreeCode = shop.WebShopCode)
         AND state.Status = N''INVALID''),
    MissingStateCount =
      (SELECT COUNT(*)
       FROM val.ValidationProfile AS profile
       LEFT JOIN val.ProductValidationState AS state
         ON state.ProductId = shop.ProductId AND state.ValidationProfileId = profile.ValidationProfileId
       WHERE profile.IsActive = 1 AND profile.BlocksWeb = 1
         AND (profile.CategoryTreeCode IS NULL OR profile.CategoryTreeCode = shop.WebShopCode)
         AND state.ProductId IS NULL)
) AS rule251
WHERE shop.IsPublished = 1;');

/* --- 3) Opozorilo v zvoncu: ena vrstica na podjetje, dokler kak umik ni pregledan --------------- */
DECLARE @kindDefinition nvarchar(max) = (SELECT definition FROM sys.check_constraints WHERE name = N'CK_UserAlertSubscription_Kind');
IF @kindDefinition IS NOT NULL AND CHARINDEX(N'WebShopWithdrawn', @kindDefinition) = 0
BEGIN
  ALTER TABLE intranet.UserAlertSubscription DROP CONSTRAINT CK_UserAlertSubscription_Kind;
  DECLARE @kindSql nvarchar(max) = N'ALTER TABLE intranet.UserAlertSubscription ADD CONSTRAINT CK_UserAlertSubscription_Kind CHECK ('
    + @kindDefinition + N' OR [AlertKind]=N''WebShopWithdrawn'')';
  EXEC sys.sp_executesql @kindSql;
END;

INSERT intranet.UserAlertSubscription (UserName, AlertKind, UpdatedBy)
SELECT localUser.UserName, N'WebShopWithdrawn', N'251_SamodejniUmikSSpletaInOdjavneVrstice'
FROM sec.LocalUser AS localUser
INNER JOIN sec.LocalUserRole AS userRole ON userRole.LocalUserId = localUser.LocalUserId
INNER JOIN sec.Role AS roleValue ON roleValue.RoleId = userRole.RoleId AND roleValue.RoleCode = N'ADMIN'
WHERE NOT EXISTS (SELECT 1 FROM intranet.UserAlertSubscription AS existing
                  WHERE existing.UserName = localUser.UserName AND existing.AlertKind = N'WebShopWithdrawn');

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetUserAlertSubscriptions
  @UserName nvarchar(100)
AS
BEGIN
  SET NOCOUNT ON;
  SELECT vrsta.AlertKind,
    CAST(CASE WHEN narocnina.AlertKind IS NULL THEN 0 ELSE 1 END AS bit) AS IsSubscribed
  FROM (VALUES
    (N''StaleHeartbeat''), (N''OutboundDead''), (N''OutboundDrift''), (N''StalledWatermark''),
    (N''PipelineDisabled''), (N''ReservationExcluded''), (N''OutboundUnacknowledged''),
    /* 251 */ (N''WebShopWithdrawn'')) AS vrsta(AlertKind)
  LEFT JOIN intranet.UserAlertSubscription narocnina
    ON narocnina.UserName = @UserName AND narocnina.AlertKind = vrsta.AlertKind
  ORDER BY vrsta.AlertKind;
END;');

EXEC(N'CREATE OR ALTER PROCEDURE pim.RefreshWebWithdrawalAlert
  @OrganizationId int
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  /* 251: odprt umik = ni pregledan in kljukica ni bila ponovno sprejeta. */
  DECLARE @DedupKey varchar(64) = CONVERT(varchar(64), HASHBYTES(''SHA2_256'', CONCAT(N''WebShopWithdrawn|'', @OrganizationId)), 2);
  DECLARE @OpenProducts int =
    (SELECT COUNT(DISTINCT ProductId) FROM pim.WebShopWithdrawal
     WHERE OrganizationId = @OrganizationId AND ReviewedUtc IS NULL AND RestoredUtc IS NULL);

  IF @OpenProducts > 0
  BEGIN
    DECLARE @Latest nvarchar(1000) =
      (SELECT STRING_AGG(CONVERT(nvarchar(max), latest.ItemID), N'', '') WITHIN GROUP (ORDER BY latest.LastUtc DESC)
       FROM (SELECT TOP (5) ItemID, MAX(WithdrawnUtc) AS LastUtc FROM pim.WebShopWithdrawal
             WHERE OrganizationId = @OrganizationId AND ReviewedUtc IS NULL AND RestoredUtc IS NULL
             GROUP BY ItemID ORDER BY MAX(WithdrawnUtc) DESC) AS latest);
    DECLARE @Title nvarchar(300) = CONCAT(N''Umaknjeni s spleta: '', @OpenProducts,
      CASE WHEN @OpenProducts % 100 = 1 THEN N'' artikel čaka'' WHEN @OpenProducts % 100 = 2 THEN N'' artikla čakata''
           WHEN @OpenProducts % 100 IN (3, 4) THEN N'' artikli čakajo'' ELSE N'' artiklov čaka'' END, N'' na pregled'');
    DECLARE @Payload nvarchar(2000) = LEFT(CONCAT(
      N''Samodejno odkljukani s spletišč, ker niso več veljavni za splet (manjka slika, kategorija, obvezno polje …) ali niso aktivni. Zadnji: '',
      @Latest, N''. Razlogi in pregled: Izhod na splet > Umaknjeni s spleta.''), 2000);
    EXEC ops.UpsertAlert @OrganizationId = @OrganizationId, @Pipeline = N''WEB_AUTO_WITHDRAW'',
      @AlertKind = N''WebShopWithdrawn'', @Severity = N''Warning'', @DedupKey = @DedupKey,
      @Title = @Title, @PayloadSummaryRedacted = @Payload, @Actor = N''SISTEM'';
  END
  ELSE
    UPDATE ops.Alert
    SET ResolvedUtc = SYSUTCDATETIME(), ResolvedBy = N''SISTEM'', UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = N''SISTEM''
    WHERE OrganizationId = @OrganizationId AND DedupKey = @DedupKey AND ResolvedUtc IS NULL;
END;');

/* --- 4) Samodejni umik kljukic ----------------------------------------------------------------- */
EXEC(N'CREATE OR ALTER PROCEDURE pim.WithdrawIneligibleWebShops
  @OrganizationId int = NULL,
  @ProductIdsJson nvarchar(max) = NULL,      /* [1, 2, ...]; NULL = vse kljukice podjetja */
  @TriggerSource nvarchar(50) = N''ROCNO'',  /* KARTICA | KATEGORIJE | DELOVNI_LIST | PREVERI | VALIDACIJA | IZVOZ | ROCNO */
  @TriggeredBy nvarchar(200) = NULL,
  @Revalidate bit = 0,
  @Mode nvarchar(10) = N''AUTO''             /* AUTO | PREVIEW | FORCE */
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  IF @Mode NOT IN (N''AUTO'', N''PREVIEW'', N''FORCE'') THROW 52511, N''Neznan nacin umika (AUTO, PREVIEW, FORCE).'', 1;
  IF @OrganizationId IS NULL AND @ProductIdsJson IS NULL THROW 52512, N''Umik potrebuje podjetje ali seznam izdelkov.'', 1;
  SET @TriggerSource = ISNULL(NULLIF(LTRIM(RTRIM(@TriggerSource)), N''''), N''ROCNO'');

  CREATE TABLE #Scope (ProductId bigint NOT NULL PRIMARY KEY);
  IF @ProductIdsJson IS NOT NULL
    INSERT #Scope (ProductId)
    SELECT DISTINCT TRY_CONVERT(bigint, value) FROM OPENJSON(@ProductIdsJson)
    WHERE TRY_CONVERT(bigint, value) IS NOT NULL;

  CREATE TABLE #Candidate
    (ProductId bigint NOT NULL, WebShopCode nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL,
     OrganizationId int NOT NULL, ItemID nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL,
     IsActive bit NOT NULL, HasCategory bit NOT NULL,
     InvalidProfiles nvarchar(400) COLLATE DATABASE_DEFAULT NULL,
     MissingFields nvarchar(max) COLLATE DATABASE_DEFAULT NULL,
     PRIMARY KEY (ProductId, WebShopCode));
  CREATE TABLE #Done (WebShopWithdrawalId bigint NOT NULL, ProductId bigint NOT NULL,
     WebShopCode nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL, WithdrawnUtc datetime2(3) NOT NULL);

  DECLARE @Pass int = 0, @Revalidated nvarchar(max);
  WHILE 1 = 1
  BEGIN
    DELETE #Candidate;
    INSERT #Candidate (ProductId, WebShopCode, OrganizationId, ItemID, IsActive, HasCategory, InvalidProfiles)
    SELECT eligibility.ProductId, eligibility.WebShopCode, eligibility.OrganizationId, eligibility.ItemID,
      eligibility.IsActive, eligibility.HasCategory, eligibility.InvalidProfiles
    FROM pim.WebShopEligibility AS eligibility
    WHERE eligibility.IsWithdrawable = 1
      AND (@OrganizationId IS NULL OR eligibility.OrganizationId = @OrganizationId)
      AND (@ProductIdsJson IS NULL OR EXISTS (SELECT 1 FROM #Scope AS scope WHERE scope.ProductId = eligibility.ProductId))
      AND (@Mode <> N''AUTO'' OR EXISTS (SELECT 1 FROM pim.WebPublicationPolicy AS policy
             WHERE policy.OrganizationId = eligibility.OrganizationId AND policy.AutoWithdrawEnabled = 1));

    SET @Pass += 1;
    IF @Pass > 1 OR @Revalidate = 0 OR @Mode = N''PREVIEW'' OR NOT EXISTS (SELECT 1 FROM #Candidate) BREAK;

    /* Stanje validacije je lahko staro (kategorija s kartice, SAOP, uvoz): kandidate najprej validiramo
       in odkljukamo samo, kar ostane neveljavno. */
    SET @Revalidated = (SELECT N''['' + STRING_AGG(CONVERT(nvarchar(max), candidate.ProductId), N'','') + N'']''
                        FROM (SELECT DISTINCT ProductId FROM #Candidate WHERE IsActive = 1) AS candidate);
    IF @Revalidated IS NOT NULL EXEC val.RunValidationForProducts @ProductIdsJson = @Revalidated;
  END;

  /* Razlog PRED odkljukanjem: 248 ob odkljukanju zapre spletne napake in pobrise spletno stanje. */
  UPDATE candidate
  SET MissingFields =
    (SELECT STRING_AGG(CONVERT(nvarchar(max), missing.FieldCode), N''|'') WITHIN GROUP (ORDER BY missing.FieldCode)
     FROM (SELECT DISTINCT requirement.FieldCode
           FROM val.ProductIssue AS issue
           INNER JOIN val.FieldRequirement AS requirement
             ON requirement.FieldRequirementId = issue.FieldRequirementId AND requirement.IsActive = 1 AND requirement.Severity = N''ERROR''
           INNER JOIN val.ValidationProfile AS profile
             ON profile.ValidationProfileId = issue.ValidationProfileId AND profile.IsActive = 1 AND profile.BlocksWeb = 1
             AND (profile.CategoryTreeCode IS NULL OR profile.CategoryTreeCode = candidate.WebShopCode)
           WHERE issue.ProductId = candidate.ProductId AND issue.IsActive = 1) AS missing)
  FROM #Candidate AS candidate;

  IF @Mode <> N''PREVIEW'' AND EXISTS (SELECT 1 FROM #Candidate)
  BEGIN
    DECLARE @Now datetime2(3) = SYSUTCDATETIME();
    DECLARE @Actor nvarchar(200) = N''SISTEM (samodejni umik s spleta)'';
    DECLARE @Batch TABLE (ChangeBatchId bigint NOT NULL, OrganizationId int NOT NULL);

    BEGIN TRANSACTION;
    INSERT pim.WebShopWithdrawal
      (OrganizationId, ProductId, ItemID, WebShopCode, WasInactive, HadCategory, InvalidProfiles, MissingFields,
       TriggerSource, TriggeredBy, WithdrawnUtc)
    OUTPUT inserted.WebShopWithdrawalId, inserted.ProductId, inserted.WebShopCode, inserted.WithdrawnUtc
      INTO #Done (WebShopWithdrawalId, ProductId, WebShopCode, WithdrawnUtc)
    SELECT candidate.OrganizationId, candidate.ProductId, candidate.ItemID, candidate.WebShopCode,
      CASE WHEN candidate.IsActive = 1 THEN 0 ELSE 1 END, candidate.HasCategory, candidate.InvalidProfiles,
      candidate.MissingFields, @TriggerSource, @TriggeredBy, @Now
    FROM #Candidate AS candidate;

    UPDATE shop SET IsPublished = 0, ChangedBy = @Actor, ChangedUtc = @Now
    FROM pim.ProductWebShop AS shop
    INNER JOIN #Candidate AS candidate ON candidate.ProductId = shop.ProductId AND candidate.WebShopCode = shop.WebShopCode
    WHERE shop.IsPublished = 1;

    INSERT pim.ProductChangeBatch (BatchId, ChangeSource, ChangedBy, OrganizationId, Note)
    OUTPUT inserted.ChangeBatchId, inserted.OrganizationId INTO @Batch (ChangeBatchId, OrganizationId)
    SELECT NEWID(), N''SISTEM'', @Actor, organization.OrganizationId,
      CONCAT(N''Samodejni umik s spleta: artikel ni vec veljaven za splet (sprozilec '', @TriggerSource, N'')'')
    FROM (SELECT DISTINCT OrganizationId FROM #Candidate) AS organization;

    INSERT pim.ProductFieldHistory
      (ChangeBatchId, OrganizationId, ProductId, ItemID, FieldKey, CanonTable, CanonColumn, Owner, OldValue, NewValue)
    SELECT batch.ChangeBatchId, candidate.OrganizationId, candidate.ProductId, candidate.ItemID,
      CONCAT(N''ProductWebShop.'', candidate.WebShopCode), N''pim.ProductWebShop'', N''IsPublished'', N''PIM'', N''da'', N''ne''
    FROM #Candidate AS candidate
    INNER JOIN @Batch AS batch ON batch.OrganizationId = candidate.OrganizationId;
    COMMIT;

    /* Odkljukan izdelek ni vec v obsegu spletnega profila: validacija pobrise spletno stanje (248). */
    DECLARE @Affected nvarchar(max) = (SELECT N''['' + STRING_AGG(CONVERT(nvarchar(max), affected.ProductId), N'','') + N'']''
                                       FROM (SELECT DISTINCT ProductId FROM #Candidate) AS affected);
    EXEC val.RunValidationForProducts @ProductIdsJson = @Affected;

    DECLARE @AlertOrganization int;
    DECLARE organizations CURSOR LOCAL FAST_FORWARD FOR SELECT DISTINCT OrganizationId FROM #Candidate;
    OPEN organizations;
    FETCH NEXT FROM organizations INTO @AlertOrganization;
    WHILE @@FETCH_STATUS = 0
    BEGIN
      EXEC pim.RefreshWebWithdrawalAlert @OrganizationId = @AlertOrganization;
      FETCH NEXT FROM organizations INTO @AlertOrganization;
    END;
    CLOSE organizations;
    DEALLOCATE organizations;
  END;

  SELECT done.WebShopWithdrawalId, candidate.OrganizationId, candidate.ProductId, candidate.ItemID, candidate.WebShopCode,
    ShopLabel = ISNULL((SELECT MIN(web.TreeLabel) FROM canon.WebSite AS web WHERE web.CategoryTreeCode = candidate.WebShopCode), candidate.WebShopCode),
    ProductName = COALESCE(NULLIF(title.Value, N''''), candidate.ItemID),
    WasInactive = CONVERT(bit, CASE WHEN candidate.IsActive = 1 THEN 0 ELSE 1 END),
    HadCategory = candidate.HasCategory, candidate.InvalidProfiles, candidate.MissingFields,
    WithdrawnUtc = done.WithdrawnUtc
  FROM #Candidate AS candidate
  LEFT JOIN #Done AS done ON done.ProductId = candidate.ProductId AND done.WebShopCode = candidate.WebShopCode
  LEFT JOIN canon.ProductText AS title
    ON title.ProductId = candidate.ProductId AND title.TextType = N''TITLE_ERP'' AND title.Lang = N''sl''
  ORDER BY candidate.OrganizationId, candidate.ItemID, candidate.WebShopCode;
END;');

EXEC(N'CREATE OR ALTER PROCEDURE pim.ReviewWebShopWithdrawals
  @OrganizationId int,
  @WithdrawalIdsJson nvarchar(max) = NULL,  /* [1, 2, ...]; NULL = vsi odprti umiki podjetja */
  @Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  IF NULLIF(LTRIM(RTRIM(@Actor)), N'''') IS NULL THROW 52513, N''Pregled umika potrebuje uporabnika.'', 1;

  UPDATE withdrawal SET ReviewedUtc = SYSUTCDATETIME(), ReviewedBy = @Actor
  FROM pim.WebShopWithdrawal AS withdrawal
  WHERE withdrawal.OrganizationId = @OrganizationId AND withdrawal.ReviewedUtc IS NULL AND withdrawal.RestoredUtc IS NULL
    AND (@WithdrawalIdsJson IS NULL OR withdrawal.WebShopWithdrawalId IN
          (SELECT TRY_CONVERT(bigint, value) FROM OPENJSON(@WithdrawalIdsJson)));
  DECLARE @Reviewed int = @@ROWCOUNT;

  EXEC pim.RefreshWebWithdrawalAlert @OrganizationId = @OrganizationId;
  SELECT @Reviewed AS ReviewedCount;
END;');

/* --- 5) Kljukica na kartici: neveljaven artikel je ne dobi -------------------------------------- */
EXEC(N'CREATE OR ALTER PROCEDURE pim.SaveProductWebShops
  @OrganizationId int,
  @ProductId bigint,
  @ChangesJson nvarchar(max),
  @Actor nvarchar(200),
  @Note nvarchar(400) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  IF NOT EXISTS (SELECT 1 FROM canon.Product WHERE ProductId = @ProductId AND OrganizationId = @OrganizationId)
    THROW 52401, N''Izdelek ne pripada temu podjetju.'', 1;

  DECLARE @Changes TABLE (WebShopCode nvarchar(100) NOT NULL PRIMARY KEY, IsPublished bit NOT NULL);
  INSERT @Changes (WebShopCode, IsPublished)
  SELECT DISTINCT parsed.webShopCode, CASE WHEN parsed.isPublished IN (N''1'', N''true'') THEN 1 ELSE 0 END
  FROM OPENJSON(@ChangesJson)
  WITH (webShopCode nvarchar(100) N''$.webShopCode'', isPublished nvarchar(10) N''$.isPublished'') AS parsed
  WHERE NULLIF(parsed.webShopCode, N'''') IS NOT NULL;

  IF EXISTS (SELECT 1 FROM @Changes changed
             WHERE NOT EXISTS (SELECT 1 FROM canon.WebSite site
                               WHERE site.CategoryTreeCode = changed.WebShopCode AND site.IsActive = 1))
    THROW 52403, N''Neznano spletisce.'', 1;

  DECLARE @ItemID nvarchar(100) = (SELECT ItemID FROM canon.Product WHERE ProductId = @ProductId);
  DECLARE @BatchId bigint;
  DECLARE @Changed TABLE (WebShopCode nvarchar(100), OldValue nvarchar(10), NewValue nvarchar(10));

  BEGIN TRANSACTION;
  BEGIN TRY
    MERGE pim.ProductWebShop AS target
    USING @Changes AS source ON target.ProductId = @ProductId AND target.WebShopCode = source.WebShopCode
    WHEN MATCHED AND target.IsPublished <> source.IsPublished
      THEN UPDATE SET IsPublished = source.IsPublished, ChangedBy = @Actor, ChangedUtc = SYSUTCDATETIME()
    WHEN NOT MATCHED BY TARGET
      THEN INSERT (ProductId, WebShopCode, IsPublished, ChangedBy) VALUES (@ProductId, source.WebShopCode, source.IsPublished, @Actor)
    OUTPUT inserted.WebShopCode,
           CASE WHEN deleted.IsPublished IS NULL THEN N''ne'' WHEN deleted.IsPublished = 1 THEN N''da'' ELSE N''ne'' END,
           CASE WHEN inserted.IsPublished = 1 THEN N''da'' ELSE N''ne'' END
    INTO @Changed (WebShopCode, OldValue, NewValue);

    DELETE @Changed WHERE OldValue = NewValue;

    IF EXISTS (SELECT 1 FROM @Changed)
    BEGIN
      INSERT pim.ProductChangeBatch (BatchId, ChangeSource, ChangedBy, OrganizationId, Note)
      VALUES (NEWID(), N''CARD'', @Actor, @OrganizationId, @Note);
      SET @BatchId = SCOPE_IDENTITY();

      INSERT pim.ProductFieldHistory (ChangeBatchId, OrganizationId, ProductId, ItemID, FieldKey, CanonTable, CanonColumn, Owner, OldValue, NewValue)
      SELECT @BatchId, @OrganizationId, @ProductId, @ItemID,
             CONCAT(N''ProductWebShop.'', changed.WebShopCode), N''pim.ProductWebShop'', N''IsPublished'', N''PIM'',
             changed.OldValue, changed.NewValue
      FROM @Changed changed;
    END;

    COMMIT;
  END TRY
  BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    THROW;
  END CATCH

  /* 218: hitra validacija enega izdelka (0,1-0,5 s) namesto val.RunValidation @ProductId (14-95 s, glej 195). */
  EXEC val.RunValidationForProduct @ProductId = @ProductId;

  /* 251: spletni profil validira samo oznacen izdelek (182/248), zato vrstni red: oznaci, validiraj,
     preveri. Nova kljukica na spletiscu, kamor artikel ne sme (neaktiven, brez kategorije na tem
     spletiscu, neveljaven), se vrne na "ne"; drugi nabor pove zakaj. */
  DECLARE @Rejected TABLE (WebShopCode nvarchar(100) NOT NULL PRIMARY KEY, IsActive bit NOT NULL, HasCategory bit NOT NULL,
    InvalidProfiles nvarchar(400) NULL, MissingFields nvarchar(max) NULL);
  INSERT @Rejected (WebShopCode, IsActive, HasCategory, InvalidProfiles)
  SELECT eligibility.WebShopCode, eligibility.IsActive, eligibility.HasCategory, eligibility.InvalidProfiles
  FROM pim.WebShopEligibility AS eligibility
  INNER JOIN @Changed AS changed ON changed.WebShopCode = eligibility.WebShopCode AND changed.NewValue = N''da''
  WHERE eligibility.ProductId = @ProductId AND eligibility.IsWithdrawable = 1;

  IF EXISTS (SELECT 1 FROM @Rejected)
  BEGIN
    UPDATE rejected
    SET MissingFields =
      (SELECT STRING_AGG(CONVERT(nvarchar(max), missing.FieldCode), N''|'') WITHIN GROUP (ORDER BY missing.FieldCode)
       FROM (SELECT DISTINCT requirement.FieldCode
             FROM val.ProductIssue AS issue
             INNER JOIN val.FieldRequirement AS requirement
               ON requirement.FieldRequirementId = issue.FieldRequirementId AND requirement.IsActive = 1 AND requirement.Severity = N''ERROR''
             INNER JOIN val.ValidationProfile AS profile
               ON profile.ValidationProfileId = issue.ValidationProfileId AND profile.IsActive = 1 AND profile.BlocksWeb = 1
               AND (profile.CategoryTreeCode IS NULL OR profile.CategoryTreeCode = rejected.WebShopCode)
             WHERE issue.ProductId = @ProductId AND issue.IsActive = 1) AS missing)
    FROM @Rejected AS rejected;

    BEGIN TRANSACTION;
    UPDATE shop SET IsPublished = 0, ChangedBy = @Actor, ChangedUtc = SYSUTCDATETIME()
    FROM pim.ProductWebShop AS shop
    INNER JOIN @Rejected AS rejected ON rejected.WebShopCode = shop.WebShopCode
    WHERE shop.ProductId = @ProductId;

    INSERT pim.ProductChangeBatch (BatchId, ChangeSource, ChangedBy, OrganizationId, Note)
    VALUES (NEWID(), N''CARD'', @Actor, @OrganizationId, N''Kljukica zavrnjena: artikel na to spletisce ne sme (251).'');
    DECLARE @RejectBatchId bigint = SCOPE_IDENTITY();
    INSERT pim.ProductFieldHistory (ChangeBatchId, OrganizationId, ProductId, ItemID, FieldKey, CanonTable, CanonColumn, Owner, OldValue, NewValue)
    SELECT @RejectBatchId, @OrganizationId, @ProductId, @ItemID,
           CONCAT(N''ProductWebShop.'', rejected.WebShopCode), N''pim.ProductWebShop'', N''IsPublished'', N''PIM'', N''da'', N''ne''
    FROM @Rejected AS rejected;
    COMMIT;

    EXEC val.RunValidationForProduct @ProductId = @ProductId;
  END;

  /* Sprejeta kljukica zapre odprte samodejne umike tega spletisca. */
  UPDATE withdrawal SET RestoredUtc = SYSUTCDATETIME(), RestoredBy = @Actor
  FROM pim.WebShopWithdrawal AS withdrawal
  INNER JOIN @Changed AS changed ON changed.WebShopCode = withdrawal.WebShopCode AND changed.NewValue = N''da''
  WHERE withdrawal.ProductId = @ProductId AND withdrawal.RestoredUtc IS NULL
    AND NOT EXISTS (SELECT 1 FROM @Rejected AS rejected WHERE rejected.WebShopCode = withdrawal.WebShopCode);
  IF @@ROWCOUNT > 0 EXEC pim.RefreshWebWithdrawalAlert @OrganizationId = @OrganizationId;

  SELECT (SELECT COUNT(*) FROM @Changes) AS RequestedCount,
         (SELECT COUNT(*) FROM pim.ProductWebShop WHERE ProductId = @ProductId AND IsPublished = 1) AS PublishedCount;

  SELECT rejected.WebShopCode,
    ShopLabel = ISNULL((SELECT MIN(web.TreeLabel) FROM canon.WebSite AS web WHERE web.CategoryTreeCode = rejected.WebShopCode), rejected.WebShopCode),
    rejected.IsActive, rejected.HasCategory, rejected.InvalidProfiles, rejected.MissingFields
  FROM @Rejected AS rejected
  ORDER BY rejected.WebShopCode;
END;');

/* --- 6) Objava v katalog.csv: kaj je slo ven ----------------------------------------------------- */
EXEC(N'CREATE OR ALTER PROCEDURE out.RecordWebPublication
  @OrganizationId int,
  @RowsJson nvarchar(max),                  /* [{"i":"<sifra>","s":"svetila|videlektro"}, ...] - vrstice zapisanega katalog.csv */
  @ExportedUtc datetime2(3) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  /* 251: klice ga worker PO uspesni zamenjavi datotek. Vrstica s spletnimi stranmi = objavljen;
     prazna vrstica = odjava (prva odjava postavi WithdrawnUtc, od katerega tece odjavno okno). */
  SET @ExportedUtc = ISNULL(@ExportedUtc, SYSUTCDATETIME());

  CREATE TABLE #Row (ItemID nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY,
                     WebSites nvarchar(400) COLLATE DATABASE_DEFAULT NULL);
  INSERT #Row (ItemID, WebSites)
  SELECT parsed.i, MAX(NULLIF(LTRIM(RTRIM(parsed.s)), N''''))
  FROM OPENJSON(@RowsJson) WITH (i nvarchar(100) N''$.i'', s nvarchar(400) N''$.s'') AS parsed
  WHERE NULLIF(LTRIM(RTRIM(parsed.i)), N'''') IS NOT NULL
  GROUP BY parsed.i;

  BEGIN TRANSACTION;
  UPDATE publication
  SET WebSites = exportRow.WebSites, LastPublishedUtc = @ExportedUtc, WithdrawnUtc = NULL, LastExportedUtc = @ExportedUtc
  FROM out.WebPublication AS publication
  INNER JOIN #Row AS exportRow ON exportRow.ItemID = publication.ItemID
  WHERE publication.OrganizationId = @OrganizationId AND exportRow.WebSites IS NOT NULL;

  INSERT out.WebPublication (OrganizationId, ItemID, WebSites, FirstPublishedUtc, LastPublishedUtc, LastExportedUtc)
  SELECT @OrganizationId, exportRow.ItemID, exportRow.WebSites, @ExportedUtc, @ExportedUtc, @ExportedUtc
  FROM #Row AS exportRow
  WHERE exportRow.WebSites IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM out.WebPublication AS existing
                    WHERE existing.OrganizationId = @OrganizationId AND existing.ItemID = exportRow.ItemID);

  DECLARE @NewlyWithdrawn int;
  UPDATE publication
  SET WithdrawnUtc = ISNULL(publication.WithdrawnUtc, @ExportedUtc), LastExportedUtc = @ExportedUtc
  FROM out.WebPublication AS publication
  INNER JOIN #Row AS exportRow ON exportRow.ItemID = publication.ItemID
  WHERE publication.OrganizationId = @OrganizationId AND exportRow.WebSites IS NULL;
  SET @NewlyWithdrawn = (SELECT COUNT(*) FROM out.WebPublication AS publication
                         INNER JOIN #Row AS exportRow ON exportRow.ItemID = publication.ItemID
                         WHERE publication.OrganizationId = @OrganizationId AND exportRow.WebSites IS NULL
                           AND publication.WithdrawnUtc = @ExportedUtc);
  COMMIT;

  SELECT PublishedCount = (SELECT COUNT(*) FROM #Row WHERE WebSites IS NOT NULL),
         WithdrawalRowCount = (SELECT COUNT(*) FROM #Row WHERE WebSites IS NULL),
         NewlyWithdrawnCount = @NewlyWithdrawn;
END;');

/* --- 7) Branje za stran /splet/umaknjeni in kartico --------------------------------------------- */
EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetWebShopWithdrawals
  @OrganizationId int,
  @State nvarchar(10) = N''OPEN'',          /* OPEN | ALL */
  @Search nvarchar(200) = NULL,
  @Take int = 500
AS
BEGIN
  SET NOCOUNT ON;
  SET @Take = CASE WHEN @Take IS NULL OR @Take < 1 THEN 500 WHEN @Take > 5000 THEN 5000 ELSE @Take END;
  SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'''');
  DECLARE @SearchLike nvarchar(410) = CASE WHEN @Search IS NULL THEN NULL ELSE
    N''%'' + REPLACE(REPLACE(REPLACE(@Search, N''['', N''[[]''), N''%'', N''[%]''), N''_'', N''[_]'') + N''%'' END;

  SELECT TOP (@Take) withdrawal.WebShopWithdrawalId, withdrawal.OrganizationId, withdrawal.ProductId, withdrawal.ItemID,
    withdrawal.WebShopCode,
    ShopLabel = ISNULL((SELECT MIN(web.TreeLabel) FROM canon.WebSite AS web WHERE web.CategoryTreeCode = withdrawal.WebShopCode), withdrawal.WebShopCode),
    ProductName = COALESCE(NULLIF(title.Value, N''''), withdrawal.ItemID),
    withdrawal.WasInactive, withdrawal.HadCategory, withdrawal.InvalidProfiles, withdrawal.MissingFields,
    withdrawal.TriggerSource, withdrawal.TriggeredBy, withdrawal.WithdrawnUtc,
    withdrawal.ReviewedUtc, withdrawal.ReviewedBy, withdrawal.RestoredUtc, withdrawal.RestoredBy,
    IsCheckedNow = CONVERT(bit, CASE WHEN EXISTS (SELECT 1 FROM pim.ProductWebShop AS shop
      WHERE shop.ProductId = withdrawal.ProductId AND shop.WebShopCode = withdrawal.WebShopCode AND shop.IsPublished = 1) THEN 1 ELSE 0 END)
  FROM pim.WebShopWithdrawal AS withdrawal
  LEFT JOIN canon.ProductText AS title
    ON title.ProductId = withdrawal.ProductId AND title.TextType = N''TITLE_ERP'' AND title.Lang = N''sl''
  WHERE withdrawal.OrganizationId = @OrganizationId
    AND (@State = N''ALL'' OR (withdrawal.ReviewedUtc IS NULL AND withdrawal.RestoredUtc IS NULL))
    AND (@SearchLike IS NULL OR withdrawal.ItemID LIKE @SearchLike OR title.Value LIKE @SearchLike)
  ORDER BY withdrawal.WithdrawnUtc DESC, withdrawal.ItemID, withdrawal.WebShopCode;
END;');

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetProductWebShopWithdrawals
  @ProductId bigint
AS
BEGIN
  SET NOCOUNT ON;
  /* Zadnji umik vsakega spletisca, ki ga uporabnik se ni popravil (kljukica ni ponovno sprejeta). */
  SELECT WebShopWithdrawalId, OrganizationId, ProductId, ItemID, WebShopCode, ShopLabel, ProductName,
    WasInactive, HadCategory, InvalidProfiles, MissingFields, TriggerSource, TriggeredBy, WithdrawnUtc,
    ReviewedUtc, ReviewedBy, RestoredUtc, RestoredBy, IsCheckedNow
  FROM
  (
    SELECT withdrawal.*,
      ShopLabel = ISNULL((SELECT MIN(web.TreeLabel) FROM canon.WebSite AS web WHERE web.CategoryTreeCode = withdrawal.WebShopCode), withdrawal.WebShopCode),
      ProductName = withdrawal.ItemID,
      IsCheckedNow = CONVERT(bit, CASE WHEN EXISTS (SELECT 1 FROM pim.ProductWebShop AS shop
        WHERE shop.ProductId = withdrawal.ProductId AND shop.WebShopCode = withdrawal.WebShopCode AND shop.IsPublished = 1) THEN 1 ELSE 0 END),
      PickRank = ROW_NUMBER() OVER (PARTITION BY withdrawal.WebShopCode ORDER BY withdrawal.WithdrawnUtc DESC, withdrawal.WebShopWithdrawalId DESC)
    FROM pim.WebShopWithdrawal AS withdrawal
    WHERE withdrawal.ProductId = @ProductId AND withdrawal.RestoredUtc IS NULL
  ) AS latest
  WHERE PickRank = 1 AND IsCheckedNow = 0
  ORDER BY WebShopCode;
END;');

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetWebPublicationPolicy
  @OrganizationId int
AS
BEGIN
  SET NOCOUNT ON;
  DECLARE @Days int = ISNULL((SELECT WithdrawalRowDays FROM pim.WebPublicationPolicy WHERE OrganizationId = @OrganizationId), 14);
  SELECT
    OrganizationId = @OrganizationId,
    AutoWithdrawEnabled = CONVERT(bit, ISNULL(policy.AutoWithdrawEnabled, 0)),
    WithdrawalRowDays = @Days,
    policy.UpdatedUtc, policy.UpdatedBy,
    OpenWithdrawalCount = (SELECT COUNT(*) FROM pim.WebShopWithdrawal
      WHERE OrganizationId = @OrganizationId AND ReviewedUtc IS NULL AND RestoredUtc IS NULL),
    PublishedCount = (SELECT COUNT(*) FROM out.WebPublication WHERE OrganizationId = @OrganizationId AND WithdrawnUtc IS NULL),
    WithdrawalRowCount = (SELECT COUNT(*) FROM out.WebPublication WHERE OrganizationId = @OrganizationId
      AND WithdrawnUtc >= DATEADD(day, -@Days, SYSUTCDATETIME())),
    LastExportedUtc = (SELECT MAX(LastExportedUtc) FROM out.WebPublication WHERE OrganizationId = @OrganizationId)
  FROM (SELECT 1 AS One) AS anchor
  LEFT JOIN pim.WebPublicationPolicy AS policy ON policy.OrganizationId = @OrganizationId;
END;');

EXEC(N'CREATE OR ALTER PROCEDURE intranet.SetWebPublicationPolicy
  @OrganizationId int,
  @AutoWithdrawEnabled bit,
  @WithdrawalRowDays int,
  @Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  IF NOT EXISTS (SELECT 1 FROM dbo.OrganizationConfig WHERE OrganizationId = @OrganizationId)
    THROW 52514, N''Podjetje ne obstaja.'', 1;
  IF @WithdrawalRowDays IS NULL OR @WithdrawalRowDays NOT BETWEEN 1 AND 365
    THROW 52515, N''Odjavno okno mora biti med 1 in 365 dnevi.'', 1;
  MERGE pim.WebPublicationPolicy AS target
  USING (SELECT @OrganizationId AS OrganizationId) AS source ON target.OrganizationId = source.OrganizationId
  WHEN MATCHED THEN UPDATE SET AutoWithdrawEnabled = @AutoWithdrawEnabled, WithdrawalRowDays = @WithdrawalRowDays,
    UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = @Actor
  WHEN NOT MATCHED THEN INSERT (OrganizationId, AutoWithdrawEnabled, WithdrawalRowDays, UpdatedBy)
    VALUES (@OrganizationId, @AutoWithdrawEnabled, @WithdrawalRowDays, @Actor);
  EXEC intranet.GetWebPublicationPolicy @OrganizationId = @OrganizationId;
END;');

/* --- 8) out.GetExportRows: odjavne vrstice namesto 220, »Spletne strani« samo dovoljena spletisca --- */
DECLARE @definition nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows'));
IF @definition IS NULL THROW 52516, N'251: out.GetExportRows ne obstaja.', 1;

IF @definition NOT LIKE N'%/* WithdrawalRows251 */%'
BEGIN
  SET @definition = REPLACE(@definition, NCHAR(13) + NCHAR(10), NCHAR(10));
  IF @definition NOT LIKE N'%/* NoSiteStillExported220 */%' OR @definition NOT LIKE N'%/* WebSitesFromFlags213 */%'
    THROW 52517, N'251: out.GetExportRows nima popravkov 213 in 220, na katerih gradi ta migracija.', 1;

  /* a) Spremenljivki odjavnega okna, takoj za @Fetch (enkrat). */
  DECLARE @fetchAnchor nvarchar(200) = N'  DECLARE @Fetch bigint = CASE WHEN @Take = 0 THEN 2147483647 ELSE @Take END;';
  IF (LEN(@definition) - LEN(REPLACE(@definition, @fetchAnchor, N''))) / LEN(@fetchAnchor) <> 1
    THROW 52518, N'251: sidro @Fetch v out.GetExportRows ni enkratno.', 1;
  SET @definition = REPLACE(@definition, @fetchAnchor, @fetchAnchor + NCHAR(10)
    + N'  /* 251: odjavne vrstice (profil z IncludeWithdrawals) in njihovo okno po podjetju. */' + NCHAR(10)
    + N'  DECLARE @IncludeWithdrawals251 bit = ISNULL((SELECT IncludeWithdrawals FROM out.ExportProfile WHERE ExportProfileId = @ExportProfileId), 0);' + NCHAR(10)
    + N'  DECLARE @WithdrawalSince251 datetime2(3) = DATEADD(day, -ISNULL((SELECT WithdrawalRowDays FROM pim.WebPublicationPolicy WHERE OrganizationId = @OrganizationId), 14), SYSUTCDATETIME());');

  /* b) Veja 220 (dvakrat: @TotalCount in #Page) -> odjavna vrstica za prej objavljen artikel. */
  DECLARE @branchStart nvarchar(200) = N'OR (@WebSite IS NULL AND EXISTS (SELECT 1 FROM canon.Product AS webProduct';
  DECLARE @branchEnd nvarchar(100) = N'/* NoSiteStillExported220 */';
  DECLARE @branchNew nvarchar(max) = N'OR (@WebSite IS NULL AND @IncludeWithdrawals251 = 1 AND EXISTS (SELECT 1 FROM out.WebPublication AS published251
              WHERE published251.OrganizationId = product.OrganizationId AND published251.ItemID = product.ItemID
                AND (published251.WithdrawnUtc IS NULL OR published251.WithdrawnUtc >= @WithdrawalSince251))))
      /* WithdrawalRows251 */';
  DECLARE @replaced int = 0, @at int, @endAt int;
  WHILE 1 = 1
  BEGIN
    SET @at = CHARINDEX(@branchStart, @definition);
    IF @at = 0 BREAK;
    SET @endAt = CHARINDEX(@branchEnd, @definition, @at);
    IF @endAt = 0 THROW 52519, N'251: veja 220 v out.GetExportRows nima konca.', 1;
    SET @definition = STUFF(@definition, @at, @endAt + LEN(@branchEnd) - @at, @branchNew);
    SET @replaced += 1;
    IF @replaced > 2 BREAK;
  END;
  IF @replaced <> 2 THROW 52520, N'251: out.GetExportRows nima pricakovanih dveh vej 220.', 1;

  /* c) »Spletne strani« iz dovoljenih spletisc (#Site), ne iz vseh kljukic (213). */
  DECLARE @sitesStart nvarchar(300) = N'INNER JOIN canon.Product AS flagProduct ON flagProduct.OrganizationId = @OrganizationId AND flagProduct.ItemID = page.RowKey';
  DECLARE @sitesEnd nvarchar(300) = N'INNER JOIN canon.WebSite AS web ON web.CategoryTreeCode = shop.WebShopCode AND web.IsActive = 1';
  IF (LEN(@definition) - LEN(REPLACE(@definition, @sitesStart, N''))) / LEN(@sitesStart) <> 1
     OR (LEN(@definition) - LEN(REPLACE(@definition, @sitesEnd, N''))) / LEN(@sitesEnd) <> 1
    THROW 52521, N'251: sidri stolpca Spletne strani (213) v out.GetExportRows nista enkratni.', 1;
  SET @at = CHARINDEX(@sitesStart, @definition);
  SET @endAt = CHARINDEX(@sitesEnd, @definition, @at);
  IF @endAt = 0 THROW 52522, N'251: stolpec Spletne strani (213) nima pricakovane oblike.', 1;
  SET @definition = STUFF(@definition, @at, @endAt + LEN(@sitesEnd) - @at,
    N'INNER JOIN #Site AS allowedSite251 ON allowedSite251.PimProductId = page.EntityId /* WebSitesFromAllowed251 */
      INNER JOIN canon.WebSite AS web ON web.WebSiteCode = allowedSite251.WebSite AND web.IsActive = 1');

  SET @definition = N'ALTER ' + SUBSTRING(@definition, CHARINDEX(N'PROCEDURE', @definition), 2147483647);
  EXEC sys.sp_executesql @definition;
END;

/* --- 9) Pripravljenost: IsInCatalogCsv po odjavnih vrsticah, ne po pravilu 220 ------------------ */
DECLARE @view nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'val.ProductChannelReadiness'));
IF @view IS NULL THROW 52523, N'251: val.ProductChannelReadiness ne obstaja.', 1;

IF @view NOT LIKE N'%/* WithdrawalRows251 */%'
BEGIN
  SET @view = REPLACE(@view, NCHAR(13) + NCHAR(10), NCHAR(10));
  DECLARE @csvStart nvarchar(100) = N'  IsInCatalogCsv=CONVERT(bit,';
  DECLARE @csvEnd nvarchar(100) = N'  IsErpReady=';
  IF (LEN(@view) - LEN(REPLACE(@view, @csvStart, N''))) / LEN(@csvStart) <> 1
    THROW 52524, N'251: IsInCatalogCsv v val.ProductChannelReadiness ni enkraten.', 1;
  SET @at = CHARINDEX(@csvStart, @view);
  SET @endAt = CHARINDEX(@csvEnd, @view, @at);
  IF @endAt = 0 THROW 52525, N'251: val.ProductChannelReadiness nima stolpca IsErpReady za IsInCatalogCsv.', 1;
  SET @view = STUFF(@view, @at, @endAt - @at,
N'  IsInCatalogCsv=CONVERT(bit,
    CASE WHEN product.IsActive=1 AND promoted.PimProductId IS NOT NULL AND ISNULL(policy.IsExcluded,0)=0
          AND ISNULL(holdCount.HasGlobalHold,0)=0 AND ISNULL(holdCount.HasWebHold,0)=0
          AND ISNULL(sites.AllowedCount,0)>0 THEN 1
         WHEN promoted.PimProductId IS NOT NULL AND withdrawal251.ItemID IS NOT NULL THEN 1 ELSE 0 END) /* WithdrawalRows251 */,
  IsWithdrawalRow=CONVERT(bit,
    CASE WHEN product.IsActive=1 AND promoted.PimProductId IS NOT NULL AND ISNULL(policy.IsExcluded,0)=0
          AND ISNULL(holdCount.HasGlobalHold,0)=0 AND ISNULL(holdCount.HasWebHold,0)=0
          AND ISNULL(sites.AllowedCount,0)>0 THEN 0
         WHEN promoted.PimProductId IS NOT NULL AND withdrawal251.ItemID IS NOT NULL THEN 1 ELSE 0 END),
');

  DECLARE @viewEnd nvarchar(100) = N') AS sites ON sites.ProductId=product.ProductId;';
  IF (LEN(@view) - LEN(REPLACE(@view, @viewEnd, N''))) / LEN(@viewEnd) <> 1
    THROW 52526, N'251: val.ProductChannelReadiness nima pricakovanega konca (sites).', 1;
  SET @view = REPLACE(@view, @viewEnd, N') AS sites ON sites.ProductId=product.ProductId
/* 251: odjavna vrstica - prej objavljen artikel, ki ni vec na nobenem spletiscu, v odjavnem oknu. */
LEFT JOIN out.WebPublication AS withdrawal251
  ON withdrawal251.OrganizationId=product.OrganizationId AND withdrawal251.ItemID=product.ItemID
  AND (withdrawal251.WithdrawnUtc IS NULL OR withdrawal251.WithdrawnUtc >= DATEADD(day,
    -ISNULL((SELECT policy251.WithdrawalRowDays FROM pim.WebPublicationPolicy AS policy251
             WHERE policy251.OrganizationId=product.OrganizationId),14), SYSUTCDATETIME()));');

  SET @view = N'ALTER ' + SUBSTRING(@view, CHARINDEX(N'VIEW', @view), 2147483647);
  EXEC sys.sp_executesql @view;
END;

/* --- 10) Pravica za stran /splet/umaknjeni -------------------------------------------------------- */
INSERT sec.RolePermission (RoleId, PermissionKey)
SELECT roleValue.RoleId, N'view.web.withdrawals'
FROM sec.Role AS roleValue
WHERE roleValue.RoleCode IN (N'ADMIN', N'CATALOG_EDITOR', N'VIEWER', N'COMMERCIAL')
  AND NOT EXISTS (SELECT 1 FROM sec.RolePermission AS existing
                  WHERE existing.RoleId = roleValue.RoleId AND existing.PermissionKey = N'view.web.withdrawals');
