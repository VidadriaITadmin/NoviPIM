/*
  277 — Varovalke: katalog.csv se pred objavo primerja z zadnjo objavljeno datoteko.

  Uporabnik 2026-09-23: »katalog ni dal vejice cenam in smo imeli napačne cene na svetilih«, »kljukice
  za splet niso delovale«, varovalke »ne blokirajo procesov, ampak samo opozorijo in mora uporabnik
  ponovno potrditi spremembe«. 2026-09-24: »cene morajo imeti vejico, ne piko za ločilo«; »če je cena 0
  mora biti tudi varovalka«; »opozorilo, če je katero polje s ceno prazno — in če se potrdi, je potem
  v redu«; »koliko artiklov je bilo umaknjenih s spleta, zakaj in kateri«; »če imajo artikli kljukice,
  pa ne gredo na splet, da vemo zakaj ne«.

  2026-09-24 (popravek istega dne): »ločilo naj bo ; ne pa vejica« in »če ima en artikel prazno polje, se
  ostali pojavijo v CSV, ta pa ne sme biti v CSV in mora čakati odobritev«.

  Kako varovalka deluje: izvoz teče naprej kot doslej. Pred zamenjavo datotek worker pokliče
  ops.EvaluateCatalogSafeguards. Artikel s sumljivo spremembo (cena ×100, prazna, 0, velik skok, neveljavna
  oblika; množičen umik s spleta) je ZADRŽAN: njegove vrstice ni v objavljeni datoteki, ostali artikli gredo
  ven normalno. Zadržan artikel, ki je že na spletu, tam ostane s prejšnjimi podatki (Magento se artiklov,
  ki jih v datoteki ni, ne dotakne); nov artikel na splet ne pride. Na /varovalke je seznam (prej → zdaj,
  razlog); ko uporabnik ugotovitev potrdi (vse ali izbrane), gre artikel ven z naslednjim izvozom (zahteva za
  zagon se odda ob potrditvi) in ista ugotovitev 14 dni ne sprašuje več. Če uporabnik napako popravi (npr.
  ceno v SAOP), je naslednji izvoz ne najde več in artikel gre ven sam.

  Kaj naredi:
    1. out.ExportColumn.DecimalSeparator (',' = število v tem stolpcu z decimalno vejico) in GuardKind
       ('PRICE' = stolpec preverja varovalka cen). Cena B2B in Cena B2C (MAGENTO_PRODUCTS in
       MAGENTO_STOCK_PRICES) dobita vejico; ostala števila ostanejo s piko. out.GetExportRows ostane s piko
       (strojna oblika, po njej računa varovalka); vejico postavi pisalec datoteke (PIM.B2b ExportValueFormat).
    2. out.ExportProfile.FieldDelimiter: ločilo stolpcev po profilu; katalog.csv (MAGENTO_PRODUCTS) in
       stranke.csv (MAGENTO_CUSTOMERS) ';', ostali ',' kot doslej. S podpičjem je cena 29,78 v datoteki brez narekovajev.
    3. Okvir varovalk, skupen vsem področjem (katalog.csv je prvo; SAOP, zaloga in viri pridejo za njim):
         ops.SafeguardRule     pravilo, besedila, prag, ali zadrži artikel, vklop (/varovalke);
         ops.SafeguardCheck    eno preverjanje: CLEAN | WARNED | WAITING (so zadržani) | CONFIRMED | SUPERSEDED;
         ops.SafeguardFinding  ugotovitev po artiklu: prej, zdaj, sprememba, razlog, ali je artikel zadržan;
         ops.SafeguardApproval potrjene ugotovitve (prstni odtis, kdo, kdaj) — neodvisno od življenja preverjanj.
    4. out.CatalogPublishedValue: varovane vrednosti (cene) zadnjega objavljenega katalog.csv.
    5. pim.WebShopReason(@OrganizationId): za vsako kljukico, ali artikel na spletišče gre in zakaj ne —
       po istih pravilih kot #Site v out.GetExportRows.
    6. Procedure: ops.EvaluateCatalogSafeguards (worker pred zamenjavo; vrne zadržane artikle),
       out.RecordCatalogPublication (worker po objavi), ops.ApproveSafeguardFindings, ops.SaveSafeguardRule,
       bralne za intranet (intranet.GetSafeguard*, intranet.GetWebShopBlocked, intranet.GetWebWithdrawnItems).
    7. Opozorilo SafeguardPending (zvonec; podatkovna vrsta, zato ni na Nadzoru), naročnina skrbnikov,
       pravica page.safeguards.

  Ročni korak: ne v bazi. Izvajalec spletne trgovine mora uvoz katalog.csv in stranke.csv nastaviti na ločilo ';' PREDEN gre
  ta različica workerja na strežnik. Prvi izvoz po uvedbi še nima objavljenih cen za primerjavo: artikli s
  prazno ceno ali ceno 0 so enkrat zadržani do potrditve (/varovalke), po potrditvi ne več.

  Migrator ne pozna GO, zato CREATE OR ALTER v EXEC(N'...').
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

/* Besedila pravil in opozoril so s šumniki. Datoteka mora biti prebrana kot UTF-8 (sqlcmd -f 65001,
   Invoke-PendingMigrations.ps1 ali PIM.Migrator); brez tega bi nastalo »ÄŤaka« kot pri 217/234 (271). */
IF UNICODE(N'č') <> 269
  THROW 52700, N'277: datoteka ni bila prebrana kot UTF-8 (sqlcmd brez -f 65001). Poženi z Invoke-PendingMigrations.ps1 ali PIM.Migrator.', 1;

/* --- 1) Register stolpcev: decimalna vejica in varovani stolpci --------------------------------- */
IF COL_LENGTH(N'out.ExportColumn', N'DecimalSeparator') IS NULL
  ALTER TABLE out.ExportColumn ADD DecimalSeparator nchar(1) NULL
    CONSTRAINT CK_ExportColumn_DecimalSeparator CHECK (DecimalSeparator IN (N'.', N','));

IF COL_LENGTH(N'out.ExportColumn', N'GuardKind') IS NULL
  ALTER TABLE out.ExportColumn ADD GuardKind nvarchar(20) NULL
    CONSTRAINT CK_ExportColumn_GuardKind CHECK (GuardKind IN (N'PRICE'));

EXEC(N'UPDATE exportColumn
  SET DecimalSeparator = N'','',
      GuardKind = CASE WHEN exportProfile.ProfileCode = N''MAGENTO_PRODUCTS'' THEN N''PRICE'' ELSE exportColumn.GuardKind END
  FROM out.ExportColumn AS exportColumn
  INNER JOIN out.ExportProfile AS exportProfile ON exportProfile.ExportProfileId = exportColumn.ExportProfileId
  WHERE exportProfile.ProfileCode IN (N''MAGENTO_PRODUCTS'', N''MAGENTO_STOCK_PRICES'')
    AND exportColumn.CanonicalFieldCode IN (N''Product.PriceB2B'', N''Product.PriceB2C'');');

/* --- 2) Ločilo stolpcev po profilu: katalog.csv in stranke.csv s podpičjem (uporabnik 2026-09-24) ---- */
IF COL_LENGTH(N'out.ExportProfile', N'FieldDelimiter') IS NULL
  ALTER TABLE out.ExportProfile ADD FieldDelimiter nchar(1) NOT NULL
    CONSTRAINT DF_ExportProfile_FieldDelimiter DEFAULT (N',')
    CONSTRAINT CK_ExportProfile_FieldDelimiter CHECK (FieldDelimiter IN (N',', N';'));

EXEC(N'UPDATE out.ExportProfile SET FieldDelimiter = N'';'', UpdatedUtc = SYSUTCDATETIME()
  WHERE ProfileCode IN (N''MAGENTO_PRODUCTS'', N''MAGENTO_CUSTOMERS'') AND FieldDelimiter <> N'';'';');

/* --- 3) Okvir varovalk ------------------------------------------------------------------------------ */
IF OBJECT_ID(N'ops.SafeguardRule', N'U') IS NULL
  CREATE TABLE ops.SafeguardRule
  (
    RuleCode nvarchar(50) NOT NULL CONSTRAINT PK_SafeguardRule PRIMARY KEY,
    /* Področje: KATALOG_CSV (277); pozneje npr. SAOP_IZVOZ, ZALOGA, VIRI. */
    AreaCode nvarchar(50) NOT NULL,
    Title nvarchar(200) NOT NULL,
    /* Kratko ime za povzetek v zvoncu, npr. »prazna cena: 3«. */
    ShortLabel nvarchar(60) NOT NULL,
    Explanation nvarchar(1000) NOT NULL,
    WhatToDo nvarchar(1000) NOT NULL,
    /* 1 = artikel je zadržan (ni v datoteki), dokler kdo ugotovitve ne potrdi; 0 = samo opozorilo. */
    RequiresConfirmation bit NOT NULL,
    /* 1 = pravilo o artiklu, ki ga je mogoče zadržati; 0 = opozorilo o celoti ali artiklu, ki ga v datoteki ni. */
    CanHold bit NOT NULL CONSTRAINT DF_SafeguardRule_CanHold DEFAULT (1),
    /* 1 = samo informacija (npr. novi na spletu): preverjanje zaradi nje ni »z opozorili«. */
    IsInformational bit NOT NULL CONSTRAINT DF_SafeguardRule_IsInformational DEFAULT (0),
    IsEnabled bit NOT NULL CONSTRAINT DF_SafeguardRule_IsEnabled DEFAULT (1),
    ThresholdValue decimal(19,4) NULL CONSTRAINT CK_SafeguardRule_Threshold CHECK (ThresholdValue IS NULL OR ThresholdValue >= 0),
    ThresholdLabel nvarchar(200) NULL,
    /* Potrditev zahteva šele, ko ugotovitev prizadene vsaj toliko artiklov (npr. umik s spleta: 10). */
    MinCount int NOT NULL CONSTRAINT DF_SafeguardRule_MinCount DEFAULT (1)
      CONSTRAINT CK_SafeguardRule_MinCount CHECK (MinCount >= 1),
    SortOrder int NOT NULL,
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_SafeguardRule_UpdatedUtc DEFAULT (SYSUTCDATETIME()),
    UpdatedBy nvarchar(200) NOT NULL
  );

INSERT ops.SafeguardRule
  (RuleCode, AreaCode, Title, ShortLabel, Explanation, WhatToDo, RequiresConfirmation, CanHold, IsInformational,
   ThresholdValue, ThresholdLabel, MinCount, SortOrder, UpdatedBy)
SELECT seed.RuleCode, N'KATALOG_CSV', seed.Title, seed.ShortLabel, seed.Explanation, seed.WhatToDo,
  seed.RequiresConfirmation, seed.CanHold, seed.IsInformational, seed.ThresholdValue, seed.ThresholdLabel, seed.MinCount,
  seed.SortOrder, N'277_VarovalkeKatalogCsv'
FROM (VALUES
  (N'KAT_CENA_OBLIKA', N'Cena ni v pravi obliki', N'neveljavna cena',
   N'Cena gre v datoteko kot število z decimalno vejico (29,78), brez pike in brez ločila tisočic. Vrednost, ki ni število, bi Magento prebral narobe.',
   N'Artikel je zadržan (ni v datoteki). Preveri ceno v ceniku SAOP; če je tam pravilna, javi skrbniku — napaka je v izvozu.',
   1, 1, 0, CAST(NULL AS decimal(19,4)), CAST(NULL AS nvarchar(200)), 1, 10),
  (N'KAT_CENA_VEJICA', N'Cena se je spremenila za faktor 10, 100 ali 1000', N'cena ×10/×100',
   N'Tako se pokaže izgubljena ali premaknjena decimalna vejica (npr. 13,02 € postane 1302 €). Taka cena je skoraj zagotovo napačna.',
   N'Artikel je zadržan — na spletu ostane prejšnja cena. Napačno ceno popravi v SAOP (naslednji izvoz jo prebere in artikel gre ven sam) ali potrdi, če je nova cena res pravilna.',
   1, 1, 0, NULL, NULL, 1, 20),
  (N'KAT_CENA_NIC', N'Cena je 0 ali negativna', N'cena 0',
   N'Artikel bi šel na splet s ceno 0 € ali z negativno ceno.',
   N'Artikel je zadržan. Dodaj ali popravi ceno v ceniku SAOP ali potrdi, če je cena 0 namerna.',
   1, 1, 0, NULL, NULL, 1, 30),
  (N'KAT_CENA_PRAZNA', N'Cena je prazna', N'prazna cena',
   N'Artikel bi šel na splet brez cene v tem stolpcu. Prej je ceno imel ali pa je na spletu nov.',
   N'Artikel je zadržan, dokler ceno ne dodaš ali prazne cene ne potrdiš (npr. artikel se ne prodaja B2B). Potrjena prazna cena ne sprašuje več.',
   1, 1, 0, NULL, NULL, 1, 40),
  (N'KAT_CENA_SKOK', N'Velika sprememba cene', N'velika sprememba cene',
   N'Cena se je glede na zadnjo objavo spremenila za več, kot dovoljuje prag.',
   N'Artikel je zadržan — na spletu ostane prejšnja cena. Potrdi, če je sprememba namerna (nov cenik, akcija).',
   1, 1, 0, 25, N'sprememba cene v %', 1, 50),
  (N'KAT_VRSTICE', N'Na spletu je bistveno manj artiklov', N'manj artiklov na spletu',
   N'Število artiklov s spletno stranjo je glede na zadnjo objavo padlo za več, kot dovoljuje prag.',
   N'Opozorilo za pregled. Posamezne umike zadrži pravilo »Artikli gredo s spleta«.',
   0, 0, 0, 10, N'padec v %', 1, 60),
  (N'KAT_SPLET_UMIK', N'Artikli gredo s spleta', N'umik s spleta',
   N'Artikel je bil na spletu, zdaj pa bi bil umaknjen z enega ali obeh spletišč. Pri vsakem artiklu je razlog: odkljukan, brez kategorije spletišča, neveljaven (kaj manjka), neaktiven …',
   N'Ko gre s spleta vsaj toliko artiklov, kot je nastavljeno (privzeto 10), so zadržani: ostanejo na spletu, dokler umika ne potrdiš. Manjši umiki gredo ven z opozorilom. Če umik ni prav, odpravi razlog (kategorija, slika) ali vrni kljukice na strani Umaknjeni s spleta.',
   1, 1, 0, NULL, NULL, 10, 70),
  (N'KAT_KLJUKICA_NE_GRE', N'Kljukica je, na splet pa artikel ne gre', N'kljukica brez objave',
   N'Artikel je od zadnje objave dobil kljukico za spletišče, v katalog.csv pa ne gre. Kljukica ni dovolj: artikel mora biti aktiven, imeti kategorijo na tem spletišču in biti veljaven za splet.',
   N'Na kartici artikla dodaj kategorijo spletišča ali dopolni, kar manjka. Vsi taki artikli so na strani Umaknjeni s spleta, zavihek »S kljukico, a ne gredo na splet«.',
   0, 0, 0, NULL, NULL, 1, 80),
  (N'KAT_SPLET_NOVI', N'Novi artikli na spletu', N'novi na spletu',
   N'Artikli, ki so v tem izvozu prvič ali znova na spletu oziroma so dobili novo spletišče.',
   N'Nič — samo za pregled.',
   0, 0, 1, NULL, NULL, 1, 90)
) AS seed (RuleCode, Title, ShortLabel, Explanation, WhatToDo, RequiresConfirmation, CanHold, IsInformational,
           ThresholdValue, ThresholdLabel, MinCount, SortOrder)
WHERE NOT EXISTS (SELECT 1 FROM ops.SafeguardRule AS existing WHERE existing.RuleCode = seed.RuleCode);

IF OBJECT_ID(N'ops.SafeguardCheck', N'U') IS NULL
BEGIN
  CREATE TABLE ops.SafeguardCheck
  (
    SafeguardCheckId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_SafeguardCheck PRIMARY KEY,
    AreaCode nvarchar(50) NOT NULL,
    OrganizationId int NOT NULL,
    /* CLEAN brez ugotovitev · WARNED objavljeno z opozorili · WAITING objavljeno, zadržani artikli čakajo
       potrditev · CONFIRMED vsi zadržani potrjeni (gredo ven z naslednjim izvozom) · SUPERSEDED nadomestilo
       novejše preverjanje (npr. napaka je bila medtem popravljena). */
    Status nvarchar(20) NOT NULL
      CONSTRAINT CK_SafeguardCheck_Status CHECK (Status IN (N'CLEAN', N'WARNED', N'WAITING', N'CONFIRMED', N'SUPERSEDED')),
    SubjectLabel nvarchar(200) NOT NULL,
    /* Vrstice pripravljene datoteke (pred zadržanjem) in artikli s spletno stranjo v objavljeni datoteki. */
    RowCountValue int NULL,
    PublishedRows int NULL,
    PreviousPublishedRows int NULL,
    FindingCount int NOT NULL CONSTRAINT DF_SafeguardCheck_FindingCount DEFAULT (0),
    ConfirmCount int NOT NULL CONSTRAINT DF_SafeguardCheck_ConfirmCount DEFAULT (0),
    /* Artikli, ki jih ni v objavljeni datoteki, ker čakajo potrditev. */
    HeldCount int NOT NULL CONSTRAINT DF_SafeguardCheck_HeldCount DEFAULT (0),
    /* Povzetek v enem stavku, npr. »cena ×10/×100: 3, umik s spleta: 12«. */
    Headline nvarchar(400) NULL,
    /* Števila za prikaz (vrstice, objavljeni, odjave, kljukice brez objave po razlogu …). */
    SummaryJson nvarchar(max) NULL,
    ExportRunKey uniqueidentifier NULL,
    /* Isto čakajoče preverjanje se ob nespremenjenih ugotovitvah osveži, ne podvoji. */
    EvaluationCount int NOT NULL CONSTRAINT DF_SafeguardCheck_EvaluationCount DEFAULT (1),
    CreatedUtc datetime2(3) NOT NULL CONSTRAINT DF_SafeguardCheck_CreatedUtc DEFAULT (SYSUTCDATETIME()),
    LastEvaluatedUtc datetime2(3) NOT NULL CONSTRAINT DF_SafeguardCheck_LastEvaluatedUtc DEFAULT (SYSUTCDATETIME()),
    CreatedBy nvarchar(200) NOT NULL,
    /* Kdaj je bila datoteka tega preverjanja objavljena (NULL = ni bila). */
    PublishedUtc datetime2(3) NULL,
    DecidedUtc datetime2(3) NULL,
    DecidedBy nvarchar(200) NULL,
    DecisionNote nvarchar(1000) NULL,
    SupersededByCheckId bigint NULL,
    CONSTRAINT CK_SafeguardCheck_Decision CHECK ((DecidedUtc IS NULL AND DecidedBy IS NULL) OR (DecidedUtc IS NOT NULL AND DecidedBy IS NOT NULL))
  );
  CREATE INDEX IX_SafeguardCheck_Area ON ops.SafeguardCheck (AreaCode, OrganizationId, SafeguardCheckId DESC)
    INCLUDE (Status, PublishedUtc, DecidedUtc);
END;

IF OBJECT_ID(N'ops.SafeguardFinding', N'U') IS NULL
BEGIN
  CREATE TABLE ops.SafeguardFinding
  (
    SafeguardFindingId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_SafeguardFinding PRIMARY KEY,
    SafeguardCheckId bigint NOT NULL
      CONSTRAINT FK_SafeguardFinding_Check REFERENCES ops.SafeguardCheck (SafeguardCheckId) ON DELETE CASCADE,
    RuleCode nvarchar(50) NOT NULL,
    ItemID nvarchar(100) NULL,
    ProductId bigint NULL,
    FieldCode nvarchar(200) NULL,
    FieldLabel nvarchar(200) NULL,
    OldValue nvarchar(400) NULL,
    NewValue nvarchar(400) NULL,
    /* Kratko: »×100«, »+32 %«, »−18 %«. */
    ChangeText nvarchar(100) NULL,
    SiteLabel nvarchar(100) NULL,
    /* Zakaj artikel ne gre na spletišče: UNCHECKED, INACTIVE, EXCLUDED, HOLD, NO_CATEGORY, BLOCKED_ERRORS,
       NOT_VALIDATED, NOT_PROMOTED, NOT_IN_PIM, NOT_IN_FILE, PUBLISHED (med izvozom popravljen). */
    ReasonCode nvarchar(40) NULL,
    /* Kode polj z blokirajočo napako (|) pri BLOCKED_ERRORS. */
    ReasonFields nvarchar(1000) NULL,
    /* Kdo in kdaj je kljukico nazadnje spremenil (UNCHECKED, KAT_KLJUKICA_NE_GRE). */
    ReasonActor nvarchar(200) NULL,
    ReasonUtc datetime2(3) NULL,
    /* 1 = artikel je zadržan zaradi te ugotovitve (ni v datoteki) in čaka potrditev. */
    RequiresConfirmation bit NOT NULL,
    /* Enaka ugotovitev je že potrjena (ops.SafeguardApproval) — artikel zaradi nje ni zadržan. */
    ApprovalId bigint NULL,
    Fingerprint varbinary(32) NOT NULL,
    /* Vir ugotovitve v drugi tabeli, kadar ga področje potrebuje (SAOP: out.OutboxMessage.OutboxMessageId). */
    SourceRef bigint NULL
  );
  CREATE INDEX IX_SafeguardFinding_Check ON ops.SafeguardFinding (SafeguardCheckId, RuleCode);
  CREATE INDEX IX_SafeguardFinding_Fingerprint ON ops.SafeguardFinding (Fingerprint) INCLUDE (SafeguardCheckId, RequiresConfirmation);
END;

IF COL_LENGTH(N'ops.SafeguardFinding', N'SourceRef') IS NULL
  ALTER TABLE ops.SafeguardFinding ADD SourceRef bigint NULL;

/* Potrjene ugotovitve. Ločeno od preverjanj, ker se preverjanja nadomeščajo in čistijo, potrditev pa mora
   veljati, dokler potrjena sprememba ne gre ven (prstni odtis: pravilo, artikel, polje, spletišče, prej, zdaj). */
IF OBJECT_ID(N'ops.SafeguardApproval', N'U') IS NULL
BEGIN
  CREATE TABLE ops.SafeguardApproval
  (
    SafeguardApprovalId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_SafeguardApproval PRIMARY KEY,
    AreaCode nvarchar(50) NOT NULL,
    OrganizationId int NOT NULL,
    Fingerprint varbinary(32) NOT NULL,
    RuleCode nvarchar(50) NOT NULL,
    ItemID nvarchar(100) NULL,
    FieldCode nvarchar(200) NULL,
    OldValue nvarchar(400) NULL,
    NewValue nvarchar(400) NULL,
    SafeguardCheckId bigint NULL,
    ApprovedUtc datetime2(3) NOT NULL CONSTRAINT DF_SafeguardApproval_ApprovedUtc DEFAULT (SYSUTCDATETIME()),
    ApprovedBy nvarchar(200) NOT NULL,
    Note nvarchar(1000) NULL
  );
  CREATE INDEX IX_SafeguardApproval_Fingerprint ON ops.SafeguardApproval (AreaCode, OrganizationId, Fingerprint, ApprovedUtc DESC);
END;

/* --- 4) Kaj je bilo nazadnje objavljeno (varovane vrednosti) --------------------------------------- */
IF OBJECT_ID(N'out.CatalogPublishedValue', N'U') IS NULL
  CREATE TABLE out.CatalogPublishedValue
  (
    OrganizationId int NOT NULL,
    ItemID nvarchar(100) NOT NULL,
    /* Kanonična koda stolpca (Product.PriceB2B …); vrednost v invariantni obliki (pika), NULL = prazno. */
    FieldCode nvarchar(200) NOT NULL,
    Value nvarchar(400) NULL,
    PublishedUtc datetime2(3) NOT NULL,
    CONSTRAINT PK_CatalogPublishedValue PRIMARY KEY (OrganizationId, ItemID, FieldCode)
  );

/* --- 5) Zakaj artikel s kljukico ne gre na spletišče ---------------------------------------------- */
EXEC(N'CREATE OR ALTER FUNCTION pim.WebShopReason (@OrganizationId int)
RETURNS TABLE
AS
RETURN
/*
  277: ena vrstica na vrstico pim.ProductWebShop podjetja (tudi odkljukano). ReasonCode = PUBLISHED, kadar
  artikel na to spletišče gre; sicer prvi razlog po istem vrstnem redu kot #Site v out.GetExportRows:
  kljukica, aktiven, izključitev iz kataloga, ročni zadržek, kategorija spletišča (canon — kartica),
  veljavnost v profilih, ki blokirajo splet, objava v PIM (pim.ProductCategory — šele po objavi).
*/
SELECT shop.ProductId, product.OrganizationId, product.ItemID, shop.WebShopCode,
  SiteLabel = ISNULL(site.TreeLabel, shop.WebShopCode),
  shop.IsPublished, shop.ChangedBy, shop.ChangedUtc,
  ReasonCode = CASE
    WHEN shop.IsPublished = 0 THEN N''UNCHECKED''
    WHEN product.IsActive = 0 THEN N''INACTIVE''
    WHEN ISNULL(policy.IsExcluded, 0) = 1 THEN N''EXCLUDED''
    WHEN hold.HasHold = 1 THEN N''HOLD''
    WHEN category.HasCanonCategory = 0 THEN N''NO_CATEGORY''
    WHEN requirement.RequireWebValid = 1 AND validity.InvalidProfiles IS NOT NULL THEN N''BLOCKED_ERRORS''
    WHEN requirement.RequireWebValid = 1 AND validity.MissingStateCount > 0 THEN N''NOT_VALIDATED''
    WHEN category.HasPimCategory = 0 THEN N''NOT_PROMOTED''
    ELSE N''PUBLISHED'' END,
  validity.InvalidProfiles,
  MissingFields = CASE WHEN validity.InvalidProfiles IS NULL THEN NULL ELSE
    (SELECT STRING_AGG(CONVERT(nvarchar(max), missing.FieldCode), N''|'') WITHIN GROUP (ORDER BY missing.FieldCode)
     FROM (SELECT DISTINCT fieldRequirement.FieldCode
           FROM val.ProductIssue AS issue
           INNER JOIN val.FieldRequirement AS fieldRequirement
             ON fieldRequirement.FieldRequirementId = issue.FieldRequirementId
            AND fieldRequirement.IsActive = 1 AND fieldRequirement.Severity = N''ERROR''
           INNER JOIN val.ValidationProfile AS profile
             ON profile.ValidationProfileId = issue.ValidationProfileId AND profile.IsActive = 1 AND profile.BlocksWeb = 1
            AND (profile.CategoryTreeCode IS NULL OR profile.CategoryTreeCode = shop.WebShopCode)
           WHERE issue.ProductId = shop.ProductId AND issue.IsActive = 1) AS missing) END
FROM pim.ProductWebShop AS shop
INNER JOIN canon.Product AS product ON product.ProductId = shop.ProductId AND product.OrganizationId = @OrganizationId
OUTER APPLY (SELECT TreeLabel = MIN(web.TreeLabel) FROM canon.WebSite AS web
             WHERE web.CategoryTreeCode = shop.WebShopCode AND web.IsActive = 1) AS site
LEFT JOIN pim.CatalogPolicy AS policy ON policy.ProductId = shop.ProductId
CROSS APPLY (SELECT RequireWebValid = ISNULL((SELECT TOP (1) exportProfile.RequireWebValid FROM out.ExportProfile AS exportProfile
                                               WHERE exportProfile.ProfileCode = N''MAGENTO_PRODUCTS''), 1)) AS requirement
CROSS APPLY (SELECT HasHold = CASE WHEN EXISTS (SELECT 1 FROM val.ProductHold AS productHold
               WHERE productHold.ProductId = shop.ProductId AND productHold.IsActive = 1
                 AND productHold.ChannelCode IN (N''ALL'', N''WEB'')) THEN 1 ELSE 0 END) AS hold
CROSS APPLY (SELECT
    HasCanonCategory = CASE WHEN EXISTS (SELECT 1 FROM canon.ProductCategory AS canonCategory
      INNER JOIN canon.WebSite AS web
        ON web.WebSiteCode = canonCategory.WebSite AND web.IsActive = 1 AND web.CategoryTreeCode = shop.WebShopCode
      WHERE canonCategory.ProductId = shop.ProductId AND NULLIF(canonCategory.CategoryPath, N'''') IS NOT NULL) THEN 1 ELSE 0 END,
    HasPimCategory = CASE WHEN EXISTS (SELECT 1 FROM pim.Product AS pimProduct
      INNER JOIN pim.ProductCategory AS pimCategory ON pimCategory.PimProductId = pimProduct.PimProductId
      INNER JOIN canon.WebSite AS web
        ON web.WebSiteCode = pimCategory.WebSite AND web.IsActive = 1 AND web.CategoryTreeCode = shop.WebShopCode
      WHERE pimProduct.OrganizationId = product.OrganizationId AND pimProduct.ItemID = product.ItemID) THEN 1 ELSE 0 END) AS category
CROSS APPLY (SELECT
    InvalidProfiles =
      (SELECT STRING_AGG(profile.ProfileCode, N'', '') WITHIN GROUP (ORDER BY profile.ProfileCode)
       FROM val.ValidationProfile AS profile
       INNER JOIN val.ProductValidationState AS state
         ON state.ProductId = shop.ProductId AND state.ValidationProfileId = profile.ValidationProfileId
       WHERE profile.IsActive = 1 AND profile.BlocksWeb = 1
         AND (profile.CategoryTreeCode IS NULL OR profile.CategoryTreeCode = shop.WebShopCode)
         AND state.Status <> N''VALID''),
    MissingStateCount =
      (SELECT COUNT(*)
       FROM val.ValidationProfile AS profile
       LEFT JOIN val.ProductValidationState AS state
         ON state.ProductId = shop.ProductId AND state.ValidationProfileId = profile.ValidationProfileId
       WHERE profile.IsActive = 1 AND profile.BlocksWeb = 1
         AND (profile.CategoryTreeCode IS NULL OR profile.CategoryTreeCode = shop.WebShopCode)
         AND state.ProductId IS NULL)) AS validity;');

/* --- 6a) Preverjanje katalog.csv pred objavo ---------------------------------------------------------- */
EXEC(N'CREATE OR ALTER PROCEDURE ops.EvaluateCatalogSafeguards
  @OrganizationId int,
  @RowsJson nvarchar(max),              /* [{"i":"<šifra>","s":"svetila|videlektro","v":{"Product.PriceB2B":"13.02","Product.PriceB2C":null}}] */
  @RowCount int,
  @ExportRunKey uniqueidentifier = NULL,
  @Actor nvarchar(200) = N''PIM.B2bWorker''
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  /*
    277: worker poda vrstice pravkar zapisane, še neobjavljene datoteke (cene v invariantni obliki s piko,
    kot jih vrne out.GetExportRows). Primerjava je z zadnjo OBJAVO: out.CatalogPublishedValue (cene),
    out.WebPublication (spletne strani) in zadnje objavljeno preverjanje (artikli na spletu). Vrne:
      1) izid: preverjanje, stanje, ugotovitve, povzetek, število zadržanih artiklov;
      2) šifre ZADRŽANIH artiklov — worker jih izpusti iz objavljene datoteke, ostali gredo ven.
    Zadržan je artikel z nepotrjeno (ops.SafeguardApproval, 14 dni) ugotovitvijo pravila, ki zadrži
    (RequiresConfirmation, CanHold). Pravilo z MinCount (umik s spleta) zadrži, ko ugotovitev prizadene vsaj
    MinCount artiklov; artikel, zadržan v prejšnjem preverjanju, ostane zadržan do potrditve ali popravka.
  */
  DECLARE @Area nvarchar(50) = N''KATALOG_CSV'';
  DECLARE @Now datetime2(3) = SYSUTCDATETIME();
  IF @OrganizationId IS NULL OR ISNULL(ISJSON(@RowsJson), 0) <> 1
    THROW 52701, N''Varovalka katalog.csv potrebuje podjetje in vrstice datoteke (JSON).'', 1;
  SET @Actor = ISNULL(NULLIF(LTRIM(RTRIM(@Actor)), N''''), N''PIM.B2bWorker'');

  /* 1) Nova datoteka ------------------------------------------------------------------------------- */
  CREATE TABLE #Row
    (ItemID nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY,
     WebSites nvarchar(400) COLLATE DATABASE_DEFAULT NULL,
     ValuesJson nvarchar(max) COLLATE DATABASE_DEFAULT NULL);
  INSERT #Row (ItemID, WebSites, ValuesJson)
  SELECT parsed.i, MAX(NULLIF(LTRIM(RTRIM(parsed.s)), N'''')), MAX(parsed.v)
  FROM OPENJSON(@RowsJson) WITH (i nvarchar(100) N''$.i'', s nvarchar(400) N''$.s'', v nvarchar(max) N''$.v'' AS JSON) AS parsed
  WHERE NULLIF(LTRIM(RTRIM(parsed.i)), N'''') IS NOT NULL
  GROUP BY parsed.i;

  CREATE TABLE #Value
    (ItemID nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL,
     FieldCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
     RawValue nvarchar(400) COLLATE DATABASE_DEFAULT NULL,
     Number decimal(19,4) NULL,
     IsWithdrawalRow bit NOT NULL,
     PRIMARY KEY (ItemID, FieldCode));
  INSERT #Value (ItemID, FieldCode, RawValue, Number, IsWithdrawalRow)
  SELECT fileRow.ItemID, LEFT(field.[key], 200), MAX(LEFT(NULLIF(LTRIM(RTRIM(field.value)), N''''), 400)),
    MAX(TRY_CONVERT(decimal(19,4), NULLIF(LTRIM(RTRIM(field.value)), N''''))),
    MAX(CASE WHEN fileRow.WebSites IS NULL THEN 1 ELSE 0 END)
  FROM #Row AS fileRow
  CROSS APPLY OPENJSON(fileRow.ValuesJson) AS field
  WHERE fileRow.ValuesJson IS NOT NULL
  GROUP BY fileRow.ItemID, LEFT(field.[key], 200);

  CREATE TABLE #Finding
    (RuleCode nvarchar(50) COLLATE DATABASE_DEFAULT NOT NULL,
     ItemID nvarchar(100) COLLATE DATABASE_DEFAULT NULL,
     ProductId bigint NULL,
     FieldCode nvarchar(200) COLLATE DATABASE_DEFAULT NULL,
     FieldLabel nvarchar(200) COLLATE DATABASE_DEFAULT NULL,
     OldValue nvarchar(400) COLLATE DATABASE_DEFAULT NULL,
     NewValue nvarchar(400) COLLATE DATABASE_DEFAULT NULL,
     ChangeText nvarchar(100) COLLATE DATABASE_DEFAULT NULL,
     SiteLabel nvarchar(100) COLLATE DATABASE_DEFAULT NULL,
     ReasonCode nvarchar(40) COLLATE DATABASE_DEFAULT NULL,
     ReasonFields nvarchar(1000) COLLATE DATABASE_DEFAULT NULL,
     ReasonActor nvarchar(200) COLLATE DATABASE_DEFAULT NULL,
     ReasonUtc datetime2(3) NULL,
     RequiresConfirmation bit NOT NULL DEFAULT (0),
     ApprovalId bigint NULL,
     Fingerprint varbinary(32) NULL);

  DECLARE @JumpPercent decimal(19,4) = ISNULL((SELECT ThresholdValue FROM ops.SafeguardRule WHERE RuleCode = N''KAT_CENA_SKOK''), 25);
  DECLARE @RowDropPercent decimal(19,4) = ISNULL((SELECT ThresholdValue FROM ops.SafeguardRule WHERE RuleCode = N''KAT_VRSTICE''), 10);
  /* Izgubljena vejica: nova cena je stara × 10^k (k = ±1..±4) z odstopanjem največ 2 % (zaokrožitve). */
  DECLARE @FactorTolerance float = LOG10(1.02);

  /* 2) Cene (samo vrstice, ki gredo na splet; odjavna vrstica cene ne rabi) ------------------------ */
  INSERT #Finding (RuleCode, ItemID, FieldCode, OldValue, NewValue)
  SELECT N''KAT_CENA_OBLIKA'', value.ItemID, value.FieldCode, previous.Value, value.RawValue
  FROM #Value AS value
  LEFT JOIN out.CatalogPublishedValue AS previous
    ON previous.OrganizationId = @OrganizationId AND previous.ItemID = value.ItemID AND previous.FieldCode = value.FieldCode
  WHERE value.IsWithdrawalRow = 0 AND value.RawValue IS NOT NULL AND value.Number IS NULL
    AND NOT (previous.ItemID IS NOT NULL AND previous.Value = value.RawValue);

  /* 0 ali negativna — ne znova, če je bila taka že zadnja objavljena (in torej potrjena). */
  INSERT #Finding (RuleCode, ItemID, FieldCode, OldValue, NewValue)
  SELECT N''KAT_CENA_NIC'', value.ItemID, value.FieldCode, previous.Value, value.RawValue
  FROM #Value AS value
  LEFT JOIN out.CatalogPublishedValue AS previous
    ON previous.OrganizationId = @OrganizationId AND previous.ItemID = value.ItemID AND previous.FieldCode = value.FieldCode
  WHERE value.IsWithdrawalRow = 0 AND value.Number <= 0
    AND NOT (previous.ItemID IS NOT NULL AND ISNULL(TRY_CONVERT(decimal(19,4), previous.Value), 1) <= 0);

  /* Prazna — ne znova, če je bila prazna že zadnja objava tega artikla. */
  INSERT #Finding (RuleCode, ItemID, FieldCode, OldValue, NewValue)
  SELECT N''KAT_CENA_PRAZNA'', value.ItemID, value.FieldCode, previous.Value, NULL
  FROM #Value AS value
  LEFT JOIN out.CatalogPublishedValue AS previous
    ON previous.OrganizationId = @OrganizationId AND previous.ItemID = value.ItemID AND previous.FieldCode = value.FieldCode
  WHERE value.IsWithdrawalRow = 0 AND value.RawValue IS NULL
    AND NOT (previous.ItemID IS NOT NULL AND previous.Value IS NULL);

  /* Faktor 10/100/1000 (izgubljena vejica) ali velik skok glede na zadnjo objavo. */
  WITH changed AS
  (
    SELECT value.ItemID, value.FieldCode, previous.Value AS OldValue, value.RawValue AS NewValue,
      value.Number AS NewNumber, TRY_CONVERT(decimal(19,4), previous.Value) AS OldNumber
    FROM #Value AS value
    INNER JOIN out.CatalogPublishedValue AS previous
      ON previous.OrganizationId = @OrganizationId AND previous.ItemID = value.ItemID AND previous.FieldCode = value.FieldCode
    WHERE value.IsWithdrawalRow = 0 AND value.Number > 0 AND TRY_CONVERT(decimal(19,4), previous.Value) > 0
  ),
  scored AS
  (
    SELECT changed.*,
      Magnitude = ROUND(LOG10(CONVERT(float, NewNumber) / CONVERT(float, OldNumber)), 0),
      Deviation = ABS(LOG10(CONVERT(float, NewNumber) / CONVERT(float, OldNumber))
                      - ROUND(LOG10(CONVERT(float, NewNumber) / CONVERT(float, OldNumber)), 0)),
      ChangePercent = ABS(NewNumber - OldNumber) * 100.0 / OldNumber
    FROM changed
    WHERE NewNumber <> OldNumber
  ),
  classified AS
  (
    SELECT scored.*, IsFactor = CASE WHEN Magnitude <> 0 AND ABS(Magnitude) <= 4 AND Deviation <= @FactorTolerance THEN 1 ELSE 0 END
    FROM scored
  )
  INSERT #Finding (RuleCode, ItemID, FieldCode, OldValue, NewValue, ChangeText)
  SELECT CASE WHEN IsFactor = 1 THEN N''KAT_CENA_VEJICA'' ELSE N''KAT_CENA_SKOK'' END,
    ItemID, FieldCode, OldValue, NewValue,
    CASE WHEN IsFactor = 1
      THEN CONCAT(CASE WHEN Magnitude > 0 THEN NCHAR(215) ELSE NCHAR(247) END,
                  CONVERT(nvarchar(20), CONVERT(bigint, ROUND(POWER(CONVERT(float, 10), ABS(Magnitude)), 0))))
      ELSE CONCAT(CASE WHEN NewNumber > OldNumber THEN N''+'' ELSE NCHAR(8722) END, CONVERT(nvarchar(20), CONVERT(int, ROUND(ChangePercent, 0))), N'' %'') END
  FROM classified
  WHERE IsFactor = 1 OR ChangePercent >= @JumpPercent;

  /* 3) Artikli na spletu proti zadnji objavi (opozorilo) — odjavne vrstice ne štejejo: po odjavnem oknu
     izpadejo same in to ni padec kataloga. */
  DECLARE @PublishedNow int = (SELECT COUNT(*) FROM #Row WHERE WebSites IS NOT NULL);
  DECLARE @PreviousPublished int =
    (SELECT TOP (1) PublishedRows FROM ops.SafeguardCheck
     WHERE AreaCode = @Area AND OrganizationId = @OrganizationId AND PublishedUtc IS NOT NULL
     ORDER BY PublishedUtc DESC, SafeguardCheckId DESC);
  IF @PreviousPublished > 0 AND @PublishedNow < @PreviousPublished
     AND (@PublishedNow = 0 OR (@PreviousPublished - @PublishedNow) * 100.0 / @PreviousPublished >= @RowDropPercent)
    INSERT #Finding (RuleCode, OldValue, NewValue, ChangeText)
    VALUES (N''KAT_VRSTICE'', CONVERT(nvarchar(20), @PreviousPublished), CONVERT(nvarchar(20), @PublishedNow),
      CONCAT(NCHAR(8722), CONVERT(nvarchar(20), CONVERT(int, ROUND((@PreviousPublished - @PublishedNow) * 100.0 / @PreviousPublished, 0))), N'' %''));

  /* 4) Spletne strani: kdo gre s spleta (in zakaj), kdo je nov ------------------------------------------ */
  SELECT reason.ProductId, reason.ItemID, reason.WebShopCode, reason.SiteLabel, reason.IsPublished, reason.ChangedBy,
    reason.ChangedUtc, reason.ReasonCode, reason.MissingFields
  INTO #Reason
  FROM pim.WebShopReason(@OrganizationId) AS reason;

  CREATE TABLE #Tree
    (TreeLabel nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY,
     CategoryTreeCode nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL);
  INSERT #Tree (TreeLabel, CategoryTreeCode)
  SELECT ISNULL(TreeLabel, CategoryTreeCode), MIN(CategoryTreeCode)
  FROM canon.WebSite WHERE IsActive = 1
  GROUP BY ISNULL(TreeLabel, CategoryTreeCode);

  CREATE TABLE #Published
    (ItemID nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY,
     WebSites nvarchar(400) COLLATE DATABASE_DEFAULT NOT NULL);
  INSERT #Published (ItemID, WebSites)
  SELECT ItemID, WebSites FROM out.WebPublication
  WHERE OrganizationId = @OrganizationId AND WithdrawnUtc IS NULL AND NULLIF(LTRIM(RTRIM(WebSites)), N'''') IS NOT NULL;

  CREATE TABLE #Lost
    (ItemID nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL,
     SiteLabel nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL,
     OldSites nvarchar(400) COLLATE DATABASE_DEFAULT NULL,
     NewSites nvarchar(400) COLLATE DATABASE_DEFAULT NULL,
     InFile bit NOT NULL,
     PRIMARY KEY (ItemID, SiteLabel));
  INSERT #Lost (ItemID, SiteLabel, OldSites, NewSites, InFile)
  SELECT DISTINCT published.ItemID, LTRIM(RTRIM(oldSite.value)), published.WebSites, fileRow.WebSites,
    CASE WHEN fileRow.ItemID IS NULL THEN 0 ELSE 1 END
  FROM #Published AS published
  CROSS APPLY STRING_SPLIT(published.WebSites, N''|'') AS oldSite
  LEFT JOIN #Row AS fileRow ON fileRow.ItemID = published.ItemID
  WHERE NULLIF(LTRIM(RTRIM(oldSite.value)), N'''') IS NOT NULL
    AND (fileRow.ItemID IS NULL OR fileRow.WebSites IS NULL
         OR NOT EXISTS (SELECT 1 FROM STRING_SPLIT(fileRow.WebSites, N''|'') AS newSite
                        WHERE LTRIM(RTRIM(newSite.value)) = LTRIM(RTRIM(oldSite.value))));

  /* Artikel, ki ga v datoteki sploh ni (ni objavljen v pim.Product), ne dobi odjavne vrstice — Magento ga ne
     umakne sam. Razlog ostane pravi vzrok (npr. brez kategorije), sprememba pove »ni v datoteki«. */
  INSERT #Finding (RuleCode, ItemID, ProductId, FieldCode, OldValue, NewValue, ChangeText, SiteLabel, ReasonCode, ReasonFields, ReasonActor, ReasonUtc)
  SELECT N''KAT_SPLET_UMIK'', lost.ItemID, product.ProductId, N''Product.WebSites'', lost.OldSites, lost.NewSites,
    CASE WHEN lost.InFile = 0 THEN N''ni v datoteki'' END, lost.SiteLabel,
    CASE WHEN product.ProductId IS NULL THEN N''NOT_IN_PIM''
         ELSE ISNULL(reason.ReasonCode, N''UNCHECKED'') END,
    LEFT(reason.MissingFields, 1000), reason.ChangedBy, reason.ChangedUtc
  FROM #Lost AS lost
  LEFT JOIN #Tree AS tree ON tree.TreeLabel = lost.SiteLabel
  LEFT JOIN canon.Product AS product ON product.OrganizationId = @OrganizationId AND product.ItemID = lost.ItemID
  LEFT JOIN #Reason AS reason ON reason.ProductId = product.ProductId AND reason.WebShopCode = tree.CategoryTreeCode;

  INSERT #Finding (RuleCode, ItemID, FieldCode, OldValue, NewValue)
  SELECT N''KAT_SPLET_NOVI'', fileRow.ItemID, N''Product.WebSites'', published.WebSites, fileRow.WebSites
  FROM #Row AS fileRow
  LEFT JOIN #Published AS published ON published.ItemID = fileRow.ItemID
  WHERE fileRow.WebSites IS NOT NULL
    AND (published.ItemID IS NULL
         OR EXISTS (SELECT 1 FROM STRING_SPLIT(fileRow.WebSites, N''|'') AS newSite
                    WHERE NOT EXISTS (SELECT 1 FROM STRING_SPLIT(published.WebSites, N''|'') AS oldSite
                                      WHERE LTRIM(RTRIM(oldSite.value)) = LTRIM(RTRIM(newSite.value)))));

  /* 5) Kljukice od zadnje objave, s katerimi artikel ne gre na splet ------------------------------------ */
  DECLARE @Since datetime2(3) = (SELECT MAX(PublishedUtc) FROM ops.SafeguardCheck WHERE AreaCode = @Area AND OrganizationId = @OrganizationId);
  IF @Since IS NULL SET @Since = DATEADD(day, -7, @Now);
  INSERT #Finding (RuleCode, ItemID, ProductId, FieldCode, SiteLabel, ReasonCode, ReasonFields, ReasonActor, ReasonUtc)
  SELECT N''KAT_KLJUKICA_NE_GRE'', reason.ItemID, reason.ProductId, CONCAT(N''ProductWebShop.'', reason.WebShopCode), reason.SiteLabel,
    reason.ReasonCode, LEFT(reason.MissingFields, 1000), reason.ChangedBy, reason.ChangedUtc
  FROM #Reason AS reason
  WHERE reason.IsPublished = 1 AND reason.ReasonCode <> N''PUBLISHED'' AND reason.ChangedUtc >= @Since;

  /* 6) Pravila: izklopljena ven, oznake, prstni odtis, že potrjeno, prag potrditve --------------------- */
  DELETE finding FROM #Finding AS finding
  WHERE NOT EXISTS (SELECT 1 FROM ops.SafeguardRule AS safeguardRule
                    WHERE safeguardRule.RuleCode = finding.RuleCode AND safeguardRule.IsEnabled = 1);

  UPDATE finding SET ProductId = product.ProductId
  FROM #Finding AS finding
  INNER JOIN canon.Product AS product ON product.OrganizationId = @OrganizationId AND product.ItemID = finding.ItemID
  WHERE finding.ProductId IS NULL AND finding.ItemID IS NOT NULL;

  UPDATE finding SET FieldLabel = label.OutputColumnName
  FROM #Finding AS finding
  CROSS APPLY (SELECT TOP (1) exportColumn.OutputColumnName
               FROM out.ExportColumn AS exportColumn
               INNER JOIN out.ExportProfile AS exportProfile ON exportProfile.ExportProfileId = exportColumn.ExportProfileId
               WHERE exportProfile.ProfileCode = N''MAGENTO_PRODUCTS'' AND exportColumn.IsActive = 1
                 AND exportColumn.CanonicalFieldCode = finding.FieldCode
               ORDER BY exportColumn.SortOrder) AS label;

  /* Stara vrednost je del odtisa: ista napačna cena proti isti zadnji objavi je ista ugotovitev.
     Pri številu vrstic šteje samo izhodišče (nova številka niha od izvoza do izvoza). Razlog umika ni del
     odtisa: potrjeno je, da artikel gre s spletišča, ne zakaj. */
  UPDATE #Finding SET Fingerprint = HASHBYTES(''SHA2_256'', CONCAT(RuleCode, N''|'', ItemID, N''|'', FieldCode, N''|'', SiteLabel, N''|'',
    OldValue, N''|'', CASE WHEN RuleCode = N''KAT_VRSTICE'' THEN N'''' ELSE NewValue END));

  /* Potrjeno (ops.SafeguardApproval): ista ugotovitev 14 dni ne zadrži več. */
  UPDATE finding SET ApprovalId = approval.SafeguardApprovalId
  FROM #Finding AS finding
  CROSS APPLY (SELECT TOP (1) approval.SafeguardApprovalId
               FROM ops.SafeguardApproval AS approval
               WHERE approval.AreaCode = @Area AND approval.OrganizationId = @OrganizationId
                 AND approval.Fingerprint = finding.Fingerprint AND approval.ApprovedUtc >= DATEADD(day, -14, @Now)
               ORDER BY approval.ApprovedUtc DESC) AS approval;

  /* Zadržan artikel: pravilo zadrži in ugotovitev ni potrjena. MinCount šteje vse artikle pravila (tudi že
     potrjene), da potrditev dela umikov preostalih ne spusti ven; zadržan v prejšnjem preverjanju ostane zadržan. */
  DECLARE @PreviousCheckId bigint =
    (SELECT MAX(SafeguardCheckId) FROM ops.SafeguardCheck WHERE AreaCode = @Area AND OrganizationId = @OrganizationId);
  UPDATE finding SET RequiresConfirmation = 1
  FROM #Finding AS finding
  INNER JOIN ops.SafeguardRule AS safeguardRule
    ON safeguardRule.RuleCode = finding.RuleCode AND safeguardRule.RequiresConfirmation = 1
   AND safeguardRule.CanHold = 1 AND safeguardRule.IsInformational = 0
  WHERE finding.ApprovalId IS NULL AND finding.ItemID IS NOT NULL
    AND ((SELECT COUNT(DISTINCT other.ItemID) FROM #Finding AS other WHERE other.RuleCode = finding.RuleCode) >= safeguardRule.MinCount
         OR EXISTS (SELECT 1 FROM ops.SafeguardFinding AS earlier
                    WHERE earlier.SafeguardCheckId = @PreviousCheckId AND earlier.Fingerprint = finding.Fingerprint
                      AND earlier.RequiresConfirmation = 1));

  CREATE TABLE #Held (ItemID nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY);
  INSERT #Held (ItemID) SELECT DISTINCT ItemID FROM #Finding WHERE RequiresConfirmation = 1 AND ItemID IS NOT NULL;

  DECLARE @HeldCount int = (SELECT COUNT(*) FROM #Held);
  DECLARE @FindingCount int = (SELECT COUNT(*) FROM #Finding);
  DECLARE @ConfirmCount int = (SELECT COUNT(*) FROM #Finding WHERE RequiresConfirmation = 1);
  DECLARE @PublishedRows int =
    (SELECT COUNT(*) FROM #Row AS fileRow
     WHERE fileRow.WebSites IS NOT NULL AND NOT EXISTS (SELECT 1 FROM #Held AS held WHERE held.ItemID = fileRow.ItemID));
  DECLARE @Status nvarchar(20) =
    CASE WHEN @HeldCount > 0 THEN N''WAITING''
         WHEN EXISTS (SELECT 1 FROM #Finding AS finding
                      INNER JOIN ops.SafeguardRule AS safeguardRule ON safeguardRule.RuleCode = finding.RuleCode
                      WHERE safeguardRule.IsInformational = 0) THEN N''WARNED''
         ELSE N''CLEAN'' END;

  DECLARE @Headline nvarchar(400) =
    (SELECT LEFT(STRING_AGG(CONVERT(nvarchar(max), CONCAT(safeguardRule.ShortLabel, N'': '',
              CASE WHEN counted.RuleCode = N''KAT_VRSTICE'' THEN counted.ChangeText ELSE CONVERT(nvarchar(20), counted.ItemCount) END)),
            N'', '') WITHIN GROUP (ORDER BY safeguardRule.SortOrder), 400)
     FROM (SELECT RuleCode, ItemCount = COUNT(DISTINCT ISNULL(ItemID, N''*'')), ChangeText = MAX(ChangeText)
           FROM #Finding
           WHERE RequiresConfirmation = 1 OR @Status <> N''WAITING''
           GROUP BY RuleCode) AS counted
     INNER JOIN ops.SafeguardRule AS safeguardRule ON safeguardRule.RuleCode = counted.RuleCode
     WHERE @Status = N''WAITING'' OR safeguardRule.IsInformational = 0 OR NOT EXISTS
       (SELECT 1 FROM #Finding AS other INNER JOIN ops.SafeguardRule AS otherRule ON otherRule.RuleCode = other.RuleCode
        WHERE otherRule.IsInformational = 0));
  IF @Status = N''WAITING''
    SET @Headline = LEFT(CONCAT(N''zadržanih artiklov: '', @HeldCount, N'' ('', @Headline, N'')''), 400);

  DECLARE @Blocked nvarchar(max) =
    (SELECT reason.SiteLabel AS site, reason.ReasonCode AS reason, COUNT(*) AS [count]
     FROM #Reason AS reason
     WHERE reason.IsPublished = 1 AND reason.ReasonCode <> N''PUBLISHED''
     GROUP BY reason.SiteLabel, reason.ReasonCode
     FOR JSON PATH);
  DECLARE @Summary nvarchar(max) =
    (SELECT [rows] = @RowCount, previousPublished = @PreviousPublished, heldItems = @HeldCount,
       published = @PublishedRows,
       withdrawalRows = (SELECT COUNT(*) FROM #Row WHERE WebSites IS NULL),
       lostItems = (SELECT COUNT(DISTINCT ItemID) FROM #Finding WHERE RuleCode = N''KAT_SPLET_UMIK''),
       newItems = (SELECT COUNT(DISTINCT ItemID) FROM #Finding WHERE RuleCode = N''KAT_SPLET_NOVI''),
       priceFindings = (SELECT COUNT(*) FROM #Finding WHERE RuleCode LIKE N''KAT_CENA[_]%''),
       checkedNotPublished = (SELECT COUNT(*) FROM #Reason WHERE IsPublished = 1 AND ReasonCode <> N''PUBLISHED''),
       blocked = JSON_QUERY(ISNULL(@Blocked, N''[]''))
     FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

  /* Odprto čakajoče preverjanje z enakimi ugotovitvami za potrditev se osveži (ista stran ostane veljavna). */
  DECLARE @OpenCheckId bigint =
    (SELECT TOP (1) SafeguardCheckId FROM ops.SafeguardCheck
     WHERE AreaCode = @Area AND OrganizationId = @OrganizationId AND Status = N''WAITING''
     ORDER BY SafeguardCheckId DESC);
  DECLARE @SameAsOpen bit = 0;
  /* Primerjajo se zadržane ugotovitve, ki še niso potrjene: delna potrditev na odprti strani je ne razveljavi. */
  CREATE TABLE #OpenHeld (Fingerprint varbinary(32) NOT NULL PRIMARY KEY);
  IF @OpenCheckId IS NOT NULL
    INSERT #OpenHeld (Fingerprint)
    SELECT DISTINCT openFinding.Fingerprint
    FROM ops.SafeguardFinding AS openFinding
    WHERE openFinding.SafeguardCheckId = @OpenCheckId AND openFinding.RequiresConfirmation = 1
      AND NOT EXISTS (SELECT 1 FROM ops.SafeguardApproval AS approval
                      WHERE approval.AreaCode = @Area AND approval.OrganizationId = @OrganizationId
                        AND approval.Fingerprint = openFinding.Fingerprint AND approval.ApprovedUtc >= DATEADD(day, -14, @Now));
  IF @OpenCheckId IS NOT NULL AND @Status = N''WAITING''
     AND NOT EXISTS (SELECT Fingerprint FROM #Finding WHERE RequiresConfirmation = 1 EXCEPT SELECT Fingerprint FROM #OpenHeld)
     AND NOT EXISTS (SELECT Fingerprint FROM #OpenHeld EXCEPT SELECT Fingerprint FROM #Finding WHERE RequiresConfirmation = 1)
    SET @SameAsOpen = 1;

  /* 7) Zapis ------------------------------------------------------------------------------------------ */
  DECLARE @CheckId bigint = NULL;
  BEGIN TRANSACTION;
  IF @SameAsOpen = 1
  BEGIN
    UPDATE ops.SafeguardCheck
    SET RowCountValue = @RowCount, PublishedRows = @PublishedRows, PreviousPublishedRows = @PreviousPublished,
        FindingCount = @FindingCount, ConfirmCount = @ConfirmCount, HeldCount = @HeldCount,
        Headline = @Headline, SummaryJson = @Summary, ExportRunKey = @ExportRunKey,
        EvaluationCount = EvaluationCount + 1, LastEvaluatedUtc = @Now
    WHERE SafeguardCheckId = @OpenCheckId AND Status = N''WAITING'';
    IF @@ROWCOUNT = 1
    BEGIN
      SET @CheckId = @OpenCheckId;
      DELETE ops.SafeguardFinding WHERE SafeguardCheckId = @CheckId;
    END;
  END;
  IF @CheckId IS NULL
  BEGIN
    INSERT ops.SafeguardCheck
      (AreaCode, OrganizationId, Status, SubjectLabel, RowCountValue, PublishedRows, PreviousPublishedRows, FindingCount,
       ConfirmCount, HeldCount, Headline, SummaryJson, ExportRunKey, CreatedUtc, LastEvaluatedUtc, CreatedBy)
    VALUES (@Area, @OrganizationId, @Status, N''katalog.csv'', @RowCount, @PublishedRows, @PreviousPublished, @FindingCount,
       @ConfirmCount, @HeldCount, @Headline, @Summary, @ExportRunKey, @Now, @Now, @Actor);
    SET @CheckId = SCOPE_IDENTITY();
    UPDATE ops.SafeguardCheck SET Status = N''SUPERSEDED'', SupersededByCheckId = @CheckId
    WHERE AreaCode = @Area AND OrganizationId = @OrganizationId AND Status = N''WAITING'' AND SafeguardCheckId <> @CheckId;
  END;
  INSERT ops.SafeguardFinding
    (SafeguardCheckId, RuleCode, ItemID, ProductId, FieldCode, FieldLabel, OldValue, NewValue, ChangeText, SiteLabel,
     ReasonCode, ReasonFields, ReasonActor, ReasonUtc, RequiresConfirmation, ApprovalId, Fingerprint)
  SELECT @CheckId, RuleCode, ItemID, ProductId, FieldCode, FieldLabel, OldValue, NewValue, ChangeText, SiteLabel,
     ReasonCode, LEFT(ReasonFields, 1000), ReasonActor, ReasonUtc, RequiresConfirmation, ApprovalId, Fingerprint
  FROM #Finding;
  COMMIT;

  /* 8) Zvonec: eno opozorilo na področje in podjetje, dokler so artikli zadržani ------------------------- */
  DECLARE @DedupKey varchar(64) = CONVERT(varchar(64), HASHBYTES(''SHA2_256'', CONCAT(N''SafeguardPending|'', @Area, N''|'', @OrganizationId)), 2);
  IF @Status = N''WAITING''
  BEGIN
    /* Dvojina in množina: 1 artikel čaka, 2 artikla čakata, 3 artikli čakajo, 5 artiklov čaka. */
    DECLARE @Title nvarchar(300) = LEFT(CONCAT(N''katalog.csv: '', @HeldCount,
      CASE @HeldCount % 100 WHEN 1 THEN N'' artikel čaka'' WHEN 2 THEN N'' artikla čakata''
                            WHEN 3 THEN N'' artikli čakajo'' WHEN 4 THEN N'' artikli čakajo'' ELSE N'' artiklov čaka'' END,
      N'' potrditev — '', @Headline), 300);
    DECLARE @Payload nvarchar(2000) = LEFT(CONCAT(
      N''Datoteka je objavljena brez zadržanih artiklov; ti na spletu ostanejo s prejšnjimi podatki (nov artikel tja še ne pride). '',
      N''Preglej in potrdi ali popravi: Varovalke.''), 2000);
    EXEC ops.UpsertAlert @OrganizationId = @OrganizationId, @Pipeline = N''VAROVALKA:KATALOG_CSV'',
      @AlertKind = N''SafeguardPending'', @Severity = N''Warning'', @DedupKey = @DedupKey,
      @Title = @Title, @PayloadSummaryRedacted = @Payload, @Actor = @Actor;
  END
  ELSE
    UPDATE ops.Alert
    SET ResolvedUtc = @Now, ResolvedBy = N''SISTEM'', UpdatedUtc = @Now, UpdatedBy = N''SISTEM''
    WHERE OrganizationId = @OrganizationId AND DedupKey = @DedupKey AND ResolvedUtc IS NULL;
  /* Varovalka je spet tekla: opozorilo »ni tekla« (worker, CatalogSafeguard) se zapre samo. */
  UPDATE ops.Alert
  SET ResolvedUtc = @Now, ResolvedBy = N''SISTEM'', UpdatedUtc = @Now, UpdatedBy = N''SISTEM''
  WHERE OrganizationId = @OrganizationId AND DedupKey = CONCAT(''safeguard-error-katalog-'', @OrganizationId) AND ResolvedUtc IS NULL;

  /* 9) Čiščenje: nadomeščena preverjanja po 2 dneh, podrobnosti objavljenih po 30, vse po 120 dneh. ------ */
  DELETE finding FROM ops.SafeguardFinding AS finding
  INNER JOIN ops.SafeguardCheck AS safeguardCheck ON safeguardCheck.SafeguardCheckId = finding.SafeguardCheckId
  WHERE (safeguardCheck.Status = N''SUPERSEDED'' AND safeguardCheck.LastEvaluatedUtc < DATEADD(day, -2, @Now))
     OR (safeguardCheck.Status IN (N''CLEAN'', N''WARNED'') AND safeguardCheck.CreatedUtc < DATEADD(day, -30, @Now));
  DELETE ops.SafeguardCheck WHERE CreatedUtc < DATEADD(day, -120, @Now) AND Status <> N''WAITING'';
  DELETE ops.SafeguardApproval WHERE ApprovedUtc < DATEADD(day, -120, @Now);

  SELECT SafeguardCheckId = @CheckId, Status = @Status, FindingCount = @FindingCount, ConfirmCount = @ConfirmCount,
    Headline = @Headline, HeldCount = @HeldCount;
  SELECT ItemID FROM #Held ORDER BY ItemID;
END;');

/* --- 6b) Po objavi: kaj je šlo ven ------------------------------------------------------------------ */
EXEC(N'CREATE OR ALTER PROCEDURE out.RecordCatalogPublication
  @OrganizationId int,
  @RowsJson nvarchar(max),              /* vrstice OBJAVLJENE datoteke (brez zadržanih artiklov) */
  @SafeguardCheckId bigint = NULL,
  @HeldItemsJson nvarchar(max) = NULL   /* ["šifra", ...] zadržani artikli: izhodišče in evidenca objave ostaneta, kot sta bila */
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  /* 277: worker po uspešni zamenjavi datotek (za out.RecordWebPublication). Varovane vrednosti (cene) postanejo
     izhodišče za naslednji izvoz; artikel, ki ga v datoteki ni več, izpade (če se vrne, se primerja kot nov).
     Artikel, ki velja za objavljenega (out.WebPublication), v objavljeni datoteki pa ga sploh ni (ni v pim.Product),
     se zapiše kot umaknjen — varovalka ga je pred objavo pokazala (»ni v datoteki«). Brez tega bi ga vsak izvoz
     znova štel za umik. Primer: začetno stanje 251 je vse artikle s kljukico štelo za objavljene, tudi tiste, ki
     nikoli niso bili objavljeni v PIM (razvojna baza 2026-09-24: 33 artiklov). Zadržan artikel (ni v datoteki,
     ker čaka potrditev) obdrži prejšnjo ceno v izhodišču in prejšnje stanje objave. */
  IF @OrganizationId IS NULL OR ISNULL(ISJSON(@RowsJson), 0) <> 1
    THROW 52704, N''Zapis objave katalog.csv potrebuje podjetje in vrstice (JSON).'', 1;
  DECLARE @Now datetime2(3) = SYSUTCDATETIME();

  CREATE TABLE #Value
    (ItemID nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL,
     FieldCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
     Value nvarchar(400) COLLATE DATABASE_DEFAULT NULL,
     PRIMARY KEY (ItemID, FieldCode));
  INSERT #Value (ItemID, FieldCode, Value)
  SELECT parsed.i, field.[key], MAX(NULLIF(LTRIM(RTRIM(field.value)), N''''))
  FROM OPENJSON(@RowsJson) WITH (i nvarchar(100) N''$.i'', v nvarchar(max) N''$.v'' AS JSON) AS parsed
  CROSS APPLY OPENJSON(parsed.v) AS field
  WHERE NULLIF(LTRIM(RTRIM(parsed.i)), N'''') IS NOT NULL AND parsed.v IS NOT NULL
  GROUP BY parsed.i, field.[key];

  CREATE TABLE #FileItem (ItemID nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY);
  INSERT #FileItem (ItemID)
  SELECT DISTINCT parsed.i FROM OPENJSON(@RowsJson) WITH (i nvarchar(100) N''$.i'') AS parsed
  WHERE NULLIF(LTRIM(RTRIM(parsed.i)), N'''') IS NOT NULL;

  CREATE TABLE #Held (ItemID nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY);
  IF ISNULL(ISJSON(@HeldItemsJson), 0) = 1
    INSERT #Held (ItemID)
    SELECT DISTINCT CONVERT(nvarchar(100), held.value) FROM OPENJSON(@HeldItemsJson) AS held
    WHERE NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(100), held.value))), N'''') IS NOT NULL;

  BEGIN TRANSACTION;
  WITH publishedValue AS
    (SELECT * FROM out.CatalogPublishedValue AS stored
     WHERE stored.OrganizationId = @OrganizationId AND NOT EXISTS (SELECT 1 FROM #Held AS held WHERE held.ItemID = stored.ItemID))
  MERGE publishedValue
  USING #Value AS source ON publishedValue.ItemID = source.ItemID AND publishedValue.FieldCode = source.FieldCode
  WHEN MATCHED AND EXISTS (SELECT publishedValue.Value EXCEPT SELECT source.Value)
    THEN UPDATE SET Value = source.Value, PublishedUtc = @Now
  WHEN NOT MATCHED BY TARGET
    THEN INSERT (OrganizationId, ItemID, FieldCode, Value, PublishedUtc)
         VALUES (@OrganizationId, source.ItemID, source.FieldCode, source.Value, @Now)
  WHEN NOT MATCHED BY SOURCE
    THEN DELETE;

  UPDATE publication
  SET WithdrawnUtc = @Now, LastExportedUtc = @Now
  FROM out.WebPublication AS publication
  WHERE publication.OrganizationId = @OrganizationId AND publication.WithdrawnUtc IS NULL
    AND NOT EXISTS (SELECT 1 FROM #FileItem AS fileItem WHERE fileItem.ItemID = publication.ItemID)
    AND NOT EXISTS (SELECT 1 FROM #Held AS held WHERE held.ItemID = publication.ItemID);
  DECLARE @AbsentWithdrawn int = @@ROWCOUNT;

  IF @SafeguardCheckId IS NOT NULL
    UPDATE ops.SafeguardCheck SET PublishedUtc = @Now
    WHERE SafeguardCheckId = @SafeguardCheckId AND OrganizationId = @OrganizationId;
  COMMIT;

  SELECT StoredCount = (SELECT COUNT(*) FROM #Value), AbsentWithdrawnCount = @AbsentWithdrawn;
END;');

/* --- 6c) Potrditev in nastavitve ------------------------------------------------------------------- */
EXEC(N'CREATE OR ALTER PROCEDURE ops.ApproveSafeguardFindings
  @SafeguardCheckId bigint,
  @FindingIdsJson nvarchar(max) = NULL,   /* [1, 2, ...]; NULL = vse zadržane ugotovitve preverjanja */
  @Actor nvarchar(200),
  @Note nvarchar(1000) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  /* 277: uporabnik je zadržane ugotovitve pregledal in jih sprejme (vse ali izbrane). Potrditev velja za prstni
     odtis (pravilo, artikel, polje, spletišče, prej, zdaj) 14 dni: artikel gre ven z naslednjim izvozom — zahteva
     za zagon se odda takoj, če posel ta hip ne teče. Ko so potrjene vse, je preverjanje CONFIRMED. */
  IF NULLIF(LTRIM(RTRIM(@Actor)), N'''') IS NULL THROW 52702, N''Potrditev potrebuje uporabnika.'', 1;
  SET @Note = NULLIF(LTRIM(RTRIM(@Note)), N'''');

  DECLARE @Area nvarchar(50), @OrganizationId int, @Status nvarchar(20);
  DECLARE @Now datetime2(3) = SYSUTCDATETIME();

  BEGIN TRANSACTION;
  SELECT @Area = AreaCode, @OrganizationId = OrganizationId, @Status = Status
  FROM ops.SafeguardCheck WITH (UPDLOCK, HOLDLOCK)
  WHERE SafeguardCheckId = @SafeguardCheckId;
  IF @Area IS NULL
  BEGIN
    ROLLBACK;
    THROW 52703, N''Preverjanje ne obstaja.'', 1;
  END;
  IF @Status <> N''WAITING''
  BEGIN
    ROLLBACK;
    THROW 52704, N''To preverjanje ne čaka več potrditve: vse je že potrjeno ali pa je nastal novejši izvoz. Osveži stran.'', 1;
  END;

  INSERT ops.SafeguardApproval
    (AreaCode, OrganizationId, Fingerprint, RuleCode, ItemID, FieldCode, OldValue, NewValue, SafeguardCheckId, ApprovedUtc, ApprovedBy, Note)
  SELECT @Area, @OrganizationId, finding.Fingerprint, finding.RuleCode, finding.ItemID, finding.FieldCode,
    finding.OldValue, finding.NewValue, @SafeguardCheckId, @Now, @Actor, @Note
  FROM ops.SafeguardFinding AS finding
  WHERE finding.SafeguardCheckId = @SafeguardCheckId AND finding.RequiresConfirmation = 1
    AND (@FindingIdsJson IS NULL OR finding.SafeguardFindingId IN
          (SELECT TRY_CONVERT(bigint, selected.value) FROM OPENJSON(@FindingIdsJson) AS selected))
    AND NOT EXISTS (SELECT 1 FROM ops.SafeguardApproval AS approval
                    WHERE approval.AreaCode = @Area AND approval.OrganizationId = @OrganizationId
                      AND approval.Fingerprint = finding.Fingerprint AND approval.ApprovedUtc >= DATEADD(day, -14, @Now));
  DECLARE @Approved int = @@ROWCOUNT;

  DECLARE @Remaining int =
    (SELECT COUNT(*) FROM ops.SafeguardFinding AS finding
     WHERE finding.SafeguardCheckId = @SafeguardCheckId AND finding.RequiresConfirmation = 1
       AND NOT EXISTS (SELECT 1 FROM ops.SafeguardApproval AS approval
                       WHERE approval.AreaCode = @Area AND approval.OrganizationId = @OrganizationId
                         AND approval.Fingerprint = finding.Fingerprint AND approval.ApprovedUtc >= DATEADD(day, -14, @Now)));
  IF @Remaining = 0
    UPDATE ops.SafeguardCheck SET Status = N''CONFIRMED'', DecidedUtc = @Now, DecidedBy = @Actor, DecisionNote = @Note
    WHERE SafeguardCheckId = @SafeguardCheckId;
  /* Področje, ki ob potrditvi samo nekaj spusti naprej (SAOP: sporočila v vrsti), to naredi v isti transakciji. */
  IF @Approved > 0 AND OBJECT_ID(N''ops.OnSafeguardApproved'', N''P'') IS NOT NULL
    EXEC ops.OnSafeguardApproved @SafeguardCheckId = @SafeguardCheckId, @AreaCode = @Area, @OrganizationId = @OrganizationId,
      @ApprovedUtc = @Now, @Actor = @Actor;
  COMMIT;

  IF @Remaining = 0
  BEGIN
    DECLARE @DedupKey varchar(64) = CONVERT(varchar(64), HASHBYTES(''SHA2_256'', CONCAT(N''SafeguardPending|'', @Area, N''|'', @OrganizationId)), 2);
    UPDATE ops.Alert SET ResolvedUtc = @Now, ResolvedBy = @Actor, UpdatedUtc = @Now, UpdatedBy = @Actor
    WHERE OrganizationId = @OrganizationId AND DedupKey = @DedupKey AND ResolvedUtc IS NULL;
  END;

  DECLARE @JobKey nvarchar(60) = CASE @Area WHEN N''KATALOG_CSV'' THEN N''WEB_CATALOG_EXPORT'' WHEN N''SAOP'' THEN N''SAOP_OUTBOUND_DISPATCH'' WHEN N''ZALOGA_CSV'' THEN N''WEB_STOCK_EXPORT'' END;
  DECLARE @RunRequested bit = 0;
  IF @Approved > 0 AND @JobKey IS NOT NULL AND OBJECT_ID(N''ops.RequestJobRun'', N''P'') IS NOT NULL
     AND EXISTS (SELECT 1 FROM ops.JobDefinition WHERE JobKey = @JobKey AND IsEnabled = 1 AND RunningJobRunId IS NULL)
  BEGIN
    BEGIN TRY
      EXEC ops.RequestJobRun @JobKey = @JobKey, @Actor = @Actor;
      SET @RunRequested = 1;
    END TRY
    BEGIN CATCH
      /* Posel se je medtem zagnal: potrditev prebere ob koncu tega teka ali ob naslednjem. */
      SET @RunRequested = 0;
    END CATCH;
  END;

  SELECT ApprovedCount = @Approved, RemainingCount = @Remaining, RunRequested = @RunRequested;
END;');

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetSafeguardRules
  @AreaCode nvarchar(50) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SELECT RuleCode, AreaCode, Title, ShortLabel, Explanation, WhatToDo, RequiresConfirmation, CanHold, IsInformational, IsEnabled,
    ThresholdValue, ThresholdLabel, MinCount, SortOrder, UpdatedUtc, UpdatedBy
  FROM ops.SafeguardRule
  WHERE @AreaCode IS NULL OR AreaCode = @AreaCode
  ORDER BY AreaCode, SortOrder, RuleCode;
END;');

EXEC(N'CREATE OR ALTER PROCEDURE ops.SaveSafeguardRule
  @RuleCode nvarchar(50),
  @IsEnabled bit,
  @RequiresConfirmation bit,
  @ThresholdValue decimal(19,4) = NULL,
  @MinCount int,
  @Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  IF NULLIF(LTRIM(RTRIM(@Actor)), N'''') IS NULL THROW 52705, N''Sprememba pravila potrebuje uporabnika.'', 1;
  IF @MinCount IS NULL OR @MinCount < 1 THROW 52706, N''Najmanjše število artiklov mora biti vsaj 1.'', 1;
  IF @ThresholdValue < 0 THROW 52707, N''Prag ne sme biti negativen.'', 1;

  UPDATE ops.SafeguardRule
  SET IsEnabled = @IsEnabled,
      /* Zadrži lahko samo pravilo o artiklu (CanHold); opozorilo o celoti ostane opozorilo. */
      RequiresConfirmation = CASE WHEN IsInformational = 1 OR CanHold = 0 THEN 0 ELSE @RequiresConfirmation END,
      ThresholdValue = CASE WHEN ThresholdLabel IS NULL THEN ThresholdValue ELSE @ThresholdValue END,
      MinCount = @MinCount, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = @Actor
  WHERE RuleCode = @RuleCode;
  IF @@ROWCOUNT = 0 THROW 52708, N''Pravilo ne obstaja.'', 1;

  EXEC intranet.GetSafeguardRules @AreaCode = NULL;
END;');

/* --- 6d) Branje za intranet --------------------------------------------------------------------------- */
EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetSafeguardChecks
  @AreaCode nvarchar(50) = NULL,
  @OrganizationId int = NULL,
  @OnlyWithFindings bit = 0,
  @Take int = 50
AS
BEGIN
  SET NOCOUNT ON;
  SET @Take = CASE WHEN @Take IS NULL OR @Take < 1 THEN 50 WHEN @Take > 500 THEN 500 ELSE @Take END;
  SELECT TOP (@Take) safeguardCheck.SafeguardCheckId, safeguardCheck.AreaCode, safeguardCheck.OrganizationId,
    OrganizationName = COALESCE(organization.Name, CONCAT(N''podjetje '', safeguardCheck.OrganizationId)),
    safeguardCheck.Status, safeguardCheck.SubjectLabel, safeguardCheck.RowCountValue, safeguardCheck.PublishedRows,
    safeguardCheck.PreviousPublishedRows, safeguardCheck.HeldCount,
    safeguardCheck.FindingCount, safeguardCheck.ConfirmCount, safeguardCheck.Headline, safeguardCheck.SummaryJson,
    safeguardCheck.EvaluationCount, safeguardCheck.CreatedUtc, safeguardCheck.LastEvaluatedUtc, safeguardCheck.CreatedBy,
    safeguardCheck.PublishedUtc, safeguardCheck.DecidedUtc, safeguardCheck.DecidedBy, safeguardCheck.DecisionNote,
    safeguardCheck.SupersededByCheckId
  FROM ops.SafeguardCheck AS safeguardCheck
  LEFT JOIN dbo.OrganizationConfig AS organization ON organization.OrganizationId = safeguardCheck.OrganizationId
  WHERE (@AreaCode IS NULL OR safeguardCheck.AreaCode = @AreaCode)
    AND (@OrganizationId IS NULL OR safeguardCheck.OrganizationId = @OrganizationId)
    /* Nadomeščeno = bilo je zadržano, nato popravljeno (npr. cena ×100 popravljena v SAOP) — tudi to je zgodba. */
    AND (@OnlyWithFindings = 0 OR safeguardCheck.Status IN (N''WAITING'', N''CONFIRMED'', N''WARNED'', N''SUPERSEDED''))
  ORDER BY CASE WHEN safeguardCheck.Status = N''WAITING'' THEN 0 ELSE 1 END, safeguardCheck.SafeguardCheckId DESC;
END;');

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetSafeguardCheck
  @SafeguardCheckId bigint
AS
BEGIN
  SET NOCOUNT ON;
  SELECT safeguardCheck.SafeguardCheckId, safeguardCheck.AreaCode, safeguardCheck.OrganizationId,
    OrganizationName = COALESCE(organization.Name, CONCAT(N''podjetje '', safeguardCheck.OrganizationId)),
    safeguardCheck.Status, safeguardCheck.SubjectLabel, safeguardCheck.RowCountValue, safeguardCheck.PublishedRows,
    safeguardCheck.PreviousPublishedRows, safeguardCheck.HeldCount,
    safeguardCheck.FindingCount, safeguardCheck.ConfirmCount, safeguardCheck.Headline, safeguardCheck.SummaryJson,
    safeguardCheck.EvaluationCount, safeguardCheck.CreatedUtc, safeguardCheck.LastEvaluatedUtc, safeguardCheck.CreatedBy,
    safeguardCheck.PublishedUtc, safeguardCheck.DecidedUtc, safeguardCheck.DecidedBy, safeguardCheck.DecisionNote,
    safeguardCheck.SupersededByCheckId,
    LatestCheckId = (SELECT MAX(latest.SafeguardCheckId) FROM ops.SafeguardCheck AS latest
                     WHERE latest.AreaCode = safeguardCheck.AreaCode AND latest.OrganizationId = safeguardCheck.OrganizationId)
  FROM ops.SafeguardCheck AS safeguardCheck
  LEFT JOIN dbo.OrganizationConfig AS organization ON organization.OrganizationId = safeguardCheck.OrganizationId
  WHERE safeguardCheck.SafeguardCheckId = @SafeguardCheckId;

  SELECT finding.SafeguardFindingId, finding.RuleCode, finding.ItemID, finding.ProductId,
    ProductName = COALESCE(NULLIF(title.Value, N''''), finding.ItemID),
    finding.FieldCode, finding.FieldLabel, finding.OldValue, finding.NewValue, finding.ChangeText, finding.SiteLabel,
    finding.ReasonCode, finding.ReasonFields, finding.ReasonActor, finding.ReasonUtc,
    finding.RequiresConfirmation, finding.ApprovalId,
    ApprovedBy = approval.ApprovedBy, ApprovedUtc = approval.ApprovedUtc
  FROM ops.SafeguardFinding AS finding
  INNER JOIN ops.SafeguardCheck AS safeguardCheck ON safeguardCheck.SafeguardCheckId = finding.SafeguardCheckId
  LEFT JOIN ops.SafeguardRule AS safeguardRule ON safeguardRule.RuleCode = finding.RuleCode
  OUTER APPLY (SELECT TOP (1) approvalRow.ApprovedBy, approvalRow.ApprovedUtc
               FROM ops.SafeguardApproval AS approvalRow
               WHERE approvalRow.AreaCode = safeguardCheck.AreaCode AND approvalRow.OrganizationId = safeguardCheck.OrganizationId
                 AND approvalRow.Fingerprint = finding.Fingerprint
               ORDER BY approvalRow.ApprovedUtc DESC) AS approval
  LEFT JOIN canon.ProductText AS title
    ON title.ProductId = finding.ProductId AND title.TextType = N''TITLE_ERP'' AND title.Lang = N''sl''
  WHERE finding.SafeguardCheckId = @SafeguardCheckId
  ORDER BY ISNULL(safeguardRule.SortOrder, 999), finding.RequiresConfirmation DESC, finding.ItemID, finding.FieldCode, finding.SiteLabel;
END;');

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetWebShopBlocked
  @OrganizationId int,
  @WebShopCode nvarchar(100) = NULL,
  @ReasonCode nvarchar(40) = NULL,
  @Search nvarchar(200) = NULL,
  @Take int = 500
AS
BEGIN
  SET NOCOUNT ON;
  /* 277: kljukice, s katerimi artikel ta hip NE gre na spletišče — števila po razlogu in seznam. */
  SET @Take = CASE WHEN @Take IS NULL OR @Take < 1 THEN 500 WHEN @Take > 5000 THEN 5000 ELSE @Take END;
  SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'''');
  DECLARE @SearchLike nvarchar(410) = CASE WHEN @Search IS NULL THEN NULL ELSE
    N''%'' + REPLACE(REPLACE(REPLACE(@Search, N''['', N''[[]''), N''%'', N''[%]''), N''_'', N''[_]'') + N''%'' END;

  SELECT reason.ProductId, reason.ItemID, reason.WebShopCode, reason.SiteLabel, reason.ReasonCode,
    reason.InvalidProfiles, reason.MissingFields, reason.ChangedBy, reason.ChangedUtc
  INTO #Blocked
  FROM pim.WebShopReason(@OrganizationId) AS reason
  WHERE reason.IsPublished = 1 AND reason.ReasonCode <> N''PUBLISHED'';

  SELECT blocked.SiteLabel, blocked.WebShopCode, blocked.ReasonCode, ProductCount = COUNT(*)
  FROM #Blocked AS blocked
  GROUP BY blocked.SiteLabel, blocked.WebShopCode, blocked.ReasonCode
  ORDER BY COUNT(*) DESC, blocked.SiteLabel, blocked.ReasonCode;

  SELECT TOP (@Take) blocked.ProductId, blocked.ItemID, ProductName = COALESCE(NULLIF(title.Value, N''''), blocked.ItemID),
    blocked.WebShopCode, blocked.SiteLabel, blocked.ReasonCode, blocked.InvalidProfiles, blocked.MissingFields,
    blocked.ChangedBy, blocked.ChangedUtc
  FROM #Blocked AS blocked
  LEFT JOIN canon.ProductText AS title
    ON title.ProductId = blocked.ProductId AND title.TextType = N''TITLE_ERP'' AND title.Lang = N''sl''
  WHERE (@WebShopCode IS NULL OR blocked.WebShopCode = @WebShopCode)
    AND (@ReasonCode IS NULL OR blocked.ReasonCode = @ReasonCode)
    AND (@SearchLike IS NULL OR blocked.ItemID LIKE @SearchLike OR title.Value LIKE @SearchLike)
  ORDER BY blocked.ChangedUtc DESC, blocked.ItemID, blocked.WebShopCode;
END;');

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetWebWithdrawnItems
  @OrganizationId int,
  @Days int = 30,
  @ReasonCode nvarchar(40) = NULL,
  @Search nvarchar(200) = NULL,
  @Take int = 500
AS
BEGIN
  SET NOCOUNT ON;
  /* 277: artikli, ki so bili na spletu in jih je katalog.csv v zadnjih @Days dneh umaknil (odjavna vrstica),
     po spletišču z RAZLOGOM, kakršen je zdaj. Razlog UNCHECKED pomeni odkljukano — kljukico se da vrniti. */
  SET @Days = CASE WHEN @Days IS NULL OR @Days < 1 THEN 30 WHEN @Days > 365 THEN 365 ELSE @Days END;
  SET @Take = CASE WHEN @Take IS NULL OR @Take < 1 THEN 500 WHEN @Take > 5000 THEN 5000 ELSE @Take END;
  SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'''');
  DECLARE @SearchLike nvarchar(410) = CASE WHEN @Search IS NULL THEN NULL ELSE
    N''%'' + REPLACE(REPLACE(REPLACE(@Search, N''['', N''[[]''), N''%'', N''[%]''), N''_'', N''[_]'') + N''%'' END;

  SELECT reason.ProductId, reason.WebShopCode, reason.IsPublished, reason.ReasonCode, reason.InvalidProfiles,
    reason.MissingFields, reason.ChangedBy, reason.ChangedUtc
  INTO #Reason
  FROM pim.WebShopReason(@OrganizationId) AS reason;

  CREATE TABLE #Tree
    (TreeLabel nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY,
     CategoryTreeCode nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL);
  INSERT #Tree (TreeLabel, CategoryTreeCode)
  SELECT ISNULL(TreeLabel, CategoryTreeCode), MIN(CategoryTreeCode) FROM canon.WebSite WHERE IsActive = 1
  GROUP BY ISNULL(TreeLabel, CategoryTreeCode);

  SELECT publication.ItemID, product.ProductId, SiteLabel = LTRIM(RTRIM(site.value)), WebShopCode = tree.CategoryTreeCode,
    publication.WebSites, publication.WithdrawnUtc,
    ReasonCode = CASE WHEN product.ProductId IS NULL THEN N''NOT_IN_PIM'' ELSE ISNULL(reason.ReasonCode, N''UNCHECKED'') END,
    reason.InvalidProfiles, reason.MissingFields, reason.ChangedBy, reason.ChangedUtc,
    CanRestore = CONVERT(bit, CASE WHEN product.ProductId IS NOT NULL AND tree.CategoryTreeCode IS NOT NULL
      AND ISNULL(reason.IsPublished, 0) = 0 THEN 1 ELSE 0 END)
  INTO #Withdrawn
  FROM out.WebPublication AS publication
  CROSS APPLY STRING_SPLIT(publication.WebSites, N''|'') AS site
  LEFT JOIN #Tree AS tree ON tree.TreeLabel = LTRIM(RTRIM(site.value))
  LEFT JOIN canon.Product AS product ON product.OrganizationId = publication.OrganizationId AND product.ItemID = publication.ItemID
  LEFT JOIN #Reason AS reason ON reason.ProductId = product.ProductId AND reason.WebShopCode = tree.CategoryTreeCode
  WHERE publication.OrganizationId = @OrganizationId
    AND publication.WithdrawnUtc >= DATEADD(day, -@Days, SYSUTCDATETIME())
    AND NULLIF(LTRIM(RTRIM(site.value)), N'''') IS NOT NULL;

  SELECT withdrawn.ReasonCode, ProductCount = COUNT(DISTINCT withdrawn.ItemID)
  FROM #Withdrawn AS withdrawn
  GROUP BY withdrawn.ReasonCode
  ORDER BY COUNT(DISTINCT withdrawn.ItemID) DESC, withdrawn.ReasonCode;

  SELECT TOP (@Take) withdrawn.ItemID, withdrawn.ProductId, ProductName = COALESCE(NULLIF(title.Value, N''''), withdrawn.ItemID),
    withdrawn.SiteLabel, withdrawn.WebShopCode, withdrawn.WebSites, withdrawn.WithdrawnUtc, withdrawn.ReasonCode,
    withdrawn.InvalidProfiles, withdrawn.MissingFields, withdrawn.ChangedBy, withdrawn.ChangedUtc, withdrawn.CanRestore
  FROM #Withdrawn AS withdrawn
  LEFT JOIN canon.ProductText AS title
    ON title.ProductId = withdrawn.ProductId AND title.TextType = N''TITLE_ERP'' AND title.Lang = N''sl''
  WHERE (@ReasonCode IS NULL OR withdrawn.ReasonCode = @ReasonCode)
    AND (@SearchLike IS NULL OR withdrawn.ItemID LIKE @SearchLike OR title.Value LIKE @SearchLike)
  ORDER BY withdrawn.WithdrawnUtc DESC, withdrawn.ItemID, withdrawn.SiteLabel;
END;');

/* --- 7) Opozorilo v zvoncu, Nadzor, pravica ---------------------------------------------------------- */
DECLARE @kindDefinition nvarchar(max) = (SELECT definition FROM sys.check_constraints WHERE name = N'CK_UserAlertSubscription_Kind');
IF @kindDefinition IS NOT NULL AND CHARINDEX(N'SafeguardPending', @kindDefinition) = 0
BEGIN
  ALTER TABLE intranet.UserAlertSubscription DROP CONSTRAINT CK_UserAlertSubscription_Kind;
  DECLARE @kindSql nvarchar(max) = N'ALTER TABLE intranet.UserAlertSubscription ADD CONSTRAINT CK_UserAlertSubscription_Kind CHECK ('
    + @kindDefinition + N' OR [AlertKind]=N''SafeguardPending'')';
  EXEC sys.sp_executesql @kindSql;
END;

INSERT intranet.UserAlertSubscription (UserName, AlertKind, UpdatedBy)
SELECT localUser.UserName, N'SafeguardPending', N'277_VarovalkeKatalogCsv'
FROM sec.LocalUser AS localUser
INNER JOIN sec.LocalUserRole AS userRole ON userRole.LocalUserId = localUser.LocalUserId
INNER JOIN sec.Role AS roleValue ON roleValue.RoleId = userRole.RoleId AND roleValue.RoleCode = N'ADMIN'
WHERE NOT EXISTS (SELECT 1 FROM intranet.UserAlertSubscription AS existing
                  WHERE existing.UserName = localUser.UserName AND existing.AlertKind = N'SafeguardPending');

/* Seznam vrst za naročnine: dopolni se živa definicija (251 ali novejša), nič drugega se ne spremeni. */
DECLARE @subscriptions nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'intranet.GetUserAlertSubscriptions'));
IF @subscriptions IS NOT NULL AND CHARINDEX(N'SafeguardPending', @subscriptions) = 0
BEGIN
  DECLARE @subscriptionAnchor nvarchar(100) = N'(N''WebShopWithdrawn'')) AS vrsta(AlertKind)';
  IF CHARINDEX(@subscriptionAnchor, @subscriptions) = 0
    THROW 52709, N'277: intranet.GetUserAlertSubscriptions nima pričakovanega seznama vrst (251).', 1;
  SET @subscriptions = REPLACE(@subscriptions, @subscriptionAnchor,
    N'(N''WebShopWithdrawn''), /* 277 */ (N''SafeguardPending'')) AS vrsta(AlertKind)');
  SET @subscriptions = N'ALTER ' + SUBSTRING(@subscriptions, CHARINDEX(N'PROCEDURE', @subscriptions), 2147483647);
  EXEC sys.sp_executesql @subscriptions;
END;

/* Podatkovno opozorilo rešuje urednik na /varovalke, ne skrbnik s ponovnim zagonom — Nadzor ga ne kaže
   (isti seznam kot PIM.Automation.MonitorPolicy.IsDataAlert). */
DECLARE @monitorAlerts nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'intranet.GetMonitorAlerts'));
IF @monitorAlerts IS NOT NULL AND CHARINDEX(N'SafeguardPending', @monitorAlerts) = 0
BEGIN
  DECLARE @monitorAnchor nvarchar(100) = N'N''StockSnapshotEmpty'')';
  IF (LEN(@monitorAlerts) - LEN(REPLACE(@monitorAlerts, @monitorAnchor, N''))) / LEN(@monitorAnchor) <> 1
    THROW 52710, N'277: intranet.GetMonitorAlerts nima pričakovanega seznama podatkovnih vrst (259).', 1;
  SET @monitorAlerts = REPLACE(@monitorAlerts, @monitorAnchor, N'N''StockSnapshotEmpty'', N''SafeguardPending'')');
  SET @monitorAlerts = N'ALTER ' + SUBSTRING(@monitorAlerts, CHARINDEX(N'PROCEDURE', @monitorAlerts), 2147483647);
  EXEC sys.sp_executesql @monitorAlerts;
END;

INSERT sec.RolePermission (RoleId, PermissionKey)
SELECT roleValue.RoleId, N'page.safeguards'
FROM sec.Role AS roleValue
WHERE roleValue.RoleCode IN (N'ADMIN', N'CATALOG_EDITOR', N'VIEWER', N'COMMERCIAL')
  AND NOT EXISTS (SELECT 1 FROM sec.RolePermission AS existing
                  WHERE existing.RoleId = roleValue.RoleId AND existing.PermissionKey = N'page.safeguards');
