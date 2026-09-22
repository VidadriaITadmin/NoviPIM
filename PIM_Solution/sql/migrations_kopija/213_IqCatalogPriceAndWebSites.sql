/*
  213 — en katalog za splet (podjetje 2): B2B cena iz VID cenika, stolpec "Spletne strani" iz kljukic.

  Uporabnik 2026-09-15 (tri odlocitve, zapisane tudi v docs/DATABASE.md):

  1. katalog.csv in stranke.csv sta EN par datotek, samo za podjetje 2 (IQLighting) — ne po en
     katalog na podjetje. Vidadriini artikli (podjetje 3) v ta katalog ne gredo. To ni sprememba
     baze, ampak skript in intraneta (Katalog-cikel.ps1, Nocno-vse.ps1, gumb "Izvoz kataloga za
     splet"); zapisano tu, ker sta tocki 2 in 3 smiselni samo v tem okviru.

  2. Cena B2B za IQ artikle pride iz VID-ovega (podjetje 3) cenika B2B, cena B2C iz IQ-jevega
     lastnega. Migracija 208 je bila zacasna resitev: IQLighting v ERP nima cenika B2B, zato je
     stolpec "Cena B2B" bral IQ-jev B2C. Pravi vir je VID-ov B2B po isti sifri artikla (ItemID) —
     isti vzorec, kot ga zaloga ze uporablja od 146 (out.ExportStockSource.StockOrganizationId:
     izvoz podjetja 2 seteje IQ + VID zalogo po ItemID). Register out.ExportPriceList zato dobi
     PriceOrganizationId (NULL = isto podjetje, kot doslej); out.GetExportRows bere cenik iz
     ISNULL(PriceOrganizationId, @OrganizationId). Izmerjeno pred pisanjem (lokalna baza,
     2026-09-15): od 2.569 objavljenih IQ artiklov jih ima VID B2B ceno 2.385 (93 %); preostali
     ostanejo brez B2B cene, enako kot ze danes velja za manjkajoc cenik (083: prazen register ni
     napaka). Ista procedura polni tudi MAGENTO_STOCK_PRICES, zato je B2B cena v petminutni
     datoteki ista kot v katalogu.

  3. Stolpec "Spletne strani" (Product.WebSites) je do zdaj nasteval kode strani iz
     pim.ProductCategory (svetila_si, svetila_si_en, B2C, B2C_EN). Uporabnik: »te fore imamo samo
     svetila pa samo videlektro« — stolpec bere kljukici spletisc s kartice artikla
     (pim.ProductWebShop, 182/201), izpise "svetila", "videlektro" ali "svetila|videlektro".
     Oznaka za drevo je podatek v canon.WebSite.TreeLabel (jezikovni razlicici iste strani delita
     drevo in zato isto oznako); interne kode (svetila_si, videlektro) ostanejo nespremenjene —
     zapisane so v 16 tabelah, validacijskih profilih in testih, preimenovanje bi bilo tveganje
     brez koristi za uporabnika, ki vidi samo oznako. Kartica artikla (intranet.GetProductWebShops)
     kaze isto oznako kot kljukico. Pogoj, KDAJ je izdelek v katalogu (aktiven + kljukica +
     kategorija na strani + veljaven, 146/201), se NE spremeni — spremeni se samo vsebina stolpca.
     Izmerjeno: pri podjetju 2 ni artikla samo z videlektro kljukico (0), 2.479 jih ima obe, 90
     samo svetila.

  Procedura out.GetExportRows se od 171 naprej popravlja z zamenjavo besedila zive definicije
  (194, 201, 202, 204, 205, 206, 207) — enako tu, z oznakama /* PriceOrg213 */ in
  /* WebSitesFromFlags213 */, da je migracija ponovljiva in da ne pade, ce je bila ze uporabljena.
  Migrator ne pozna GO (061), zato CREATE OR ALTER v EXEC(N'...').
*/

SET XACT_ABORT ON;

/* --- 1) Register cenikov: vir cene je lahko drugo podjetje ------------------------------ */

IF COL_LENGTH(N'out.ExportPriceList', N'PriceOrganizationId') IS NULL
  ALTER TABLE out.ExportPriceList
    ADD PriceOrganizationId int NULL
      CONSTRAINT FK_ExportPriceList_PriceOrganization FOREIGN KEY REFERENCES dbo.OrganizationConfig(OrganizationId);

/* --- 2) Oznaka drevesa za izvoz in kartico ---------------------------------------------- */

IF COL_LENGTH(N'canon.WebSite', N'TreeLabel') IS NULL
  ALTER TABLE canon.WebSite ADD TreeLabel nvarchar(50) NULL;

EXEC(N'
UPDATE canon.WebSite SET TreeLabel = N''svetila''    WHERE CategoryTreeCode = N''svetila_si'';
UPDATE canon.WebSite SET TreeLabel = N''videlektro'' WHERE CategoryTreeCode = N''videlektro'';
UPDATE canon.WebSite SET TreeLabel = CategoryTreeCode WHERE TreeLabel IS NULL;
');

/* --- 3) out.GetExportRows: cenik iz PriceOrganizationId, spletne strani iz kljukic ------ */

DECLARE @definition nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows'));
IF @definition IS NULL THROW 52131, N'213: out.GetExportRows ne obstaja.', 1;
IF @definition NOT LIKE N'%/* CatalogLifecycle204 */%' THROW 52132, N'213: out.GetExportRows nima popravka 204 (cene).', 1;

DECLARE @old nvarchar(max), @new nvarchar(max);

IF @definition NOT LIKE N'%/* PriceOrg213 */%'
BEGIN
  /*
    Ista vezava (FROM #Page ... canon.Product ... out.ExportPriceList) je v proceduri veckrat:
    v cenovnem bloku iz 204 (Net -> Cena B2B/B2C), v bloku DDV/valute (#CatalogPriceMetadata) in
    v blokih odprodaje/zaloge. Zamenja se SAMO blok iz 204. Blok DDV/valute namenoma ostane na
    lastnem podjetju: DDV in valuta sta dejstvo podjetja, ki izvaza (IQ), ne cenika, iz katerega
    pride znesek; ker vrstica registra za B2B zdaj kaze na cenik, ki ga IQ nima, tisti blok sam
    pade na vrstico B2C (ORDER BY ... PriceFieldCode) — DDV in valuta ostaneta IQ-jeva.
  */
  DECLARE @blockStart int = CHARINDEX(N'/* Prices are volatile', @definition);
  DECLARE @blockEndMarker nvarchar(100) = N') prices WHERE PickRank=1;';
  DECLARE @blockEnd int = CASE WHEN @blockStart > 0 THEN CHARINDEX(@blockEndMarker, @definition, @blockStart) ELSE 0 END;
  IF @blockStart = 0 OR @blockEnd = 0
    THROW 52133, N'213: cenovni blok iz migracije 204 v out.GetExportRows ni najden.', 1;
  DECLARE @blockLen int = @blockEnd + LEN(@blockEndMarker) - @blockStart;
  DECLARE @block nvarchar(max) = SUBSTRING(@definition, @blockStart, @blockLen);

  /* a) register se veze pred izdelek, izdelek se isce v podjetju iz registra */
  SET @old = N'FROM #Page page JOIN canon.Product product ON product.OrganizationId=@OrganizationId AND product.ItemID=page.RowKey';
  SET @new = N'FROM #Page page JOIN out.ExportPriceList registry ON registry.OrganizationId=@OrganizationId AND registry.IsActive=1 AND registry.PriceFieldCode IN(N''Product.PriceB2B'',N''Product.PriceB2C'') /* PriceOrg213 */
      JOIN canon.Product product ON product.OrganizationId=ISNULL(registry.PriceOrganizationId,@OrganizationId) AND product.ItemID=page.RowKey';
  IF CHARINDEX(@old, @block) = 0 OR CHARINDEX(@old, @block, CHARINDEX(@old, @block) + 1) <> 0
    THROW 52134, N'213: vezava izdelka v cenovnem bloku 204 ni najdena natanko enkrat.', 1;
  SET @block = REPLACE(@block, @old, @new);

  /* b) stara vezava registra na cenik postane pogoj na ceni */
  SET @old = N'JOIN out.ExportPriceList registry ON registry.OrganizationId=@OrganizationId AND registry.PriceListCode=price.PriceList';
  SET @new = N'AND price.PriceList=registry.PriceListCode';
  IF CHARINDEX(@old, @block) = 0 OR CHARINDEX(@old, @block, CHARINDEX(@old, @block) + 1) <> 0
    THROW 52145, N'213: vezava registra cenikov v cenovnem bloku 204 ni najdena natanko enkrat.', 1;
  SET @block = REPLACE(@block, @old, @new);

  SET @definition = STUFF(@definition, @blockStart, @blockLen, @block);
END;

IF @definition NOT LIKE N'%/* WebSitesFromFlags213 */%'
BEGIN
  SET @old = N'STRING_AGG(CONVERT(nvarchar(max), site.WebSite), N''|'') WITHIN GROUP (ORDER BY site.WebSite)';
  SET @new = N'STRING_AGG(CONVERT(nvarchar(max), site.TreeLabel), N''|'') WITHIN GROUP (ORDER BY site.SortOrder, site.TreeLabel) /* WebSitesFromFlags213 */';
  IF CHARINDEX(@old, @definition) = 0 OR CHARINDEX(@old, @definition, CHARINDEX(@old, @definition) + 1) <> 0
    THROW 52135, N'213: sestavljanje stolpca Product.WebSites v out.GetExportRows ni najdeno natanko enkrat.', 1;
  SET @definition = REPLACE(@definition, @old, @new);

  SET @old = N'FROM (SELECT DISTINCT RowKey, WebSite FROM #Category) AS site';
  SET @new = N'FROM (
      SELECT page.RowKey, ISNULL(MIN(web.TreeLabel), web.CategoryTreeCode) AS TreeLabel, MIN(web.SortOrder) AS SortOrder
      FROM #Page AS page
      INNER JOIN canon.Product AS flagProduct ON flagProduct.OrganizationId = @OrganizationId AND flagProduct.ItemID = page.RowKey
      INNER JOIN pim.ProductWebShop AS shop ON shop.ProductId = flagProduct.ProductId AND shop.IsPublished = 1
      INNER JOIN canon.WebSite AS web ON web.CategoryTreeCode = shop.WebShopCode AND web.IsActive = 1
      GROUP BY page.RowKey, web.CategoryTreeCode
    ) AS site';
  IF CHARINDEX(@old, @definition) = 0 OR CHARINDEX(@old, @definition, CHARINDEX(@old, @definition) + 1) <> 0
    THROW 52136, N'213: vir stolpca Product.WebSites v out.GetExportRows ni najden natanko enkrat.', 1;
  SET @definition = REPLACE(@definition, @old, @new);
END;

IF @definition LIKE N'%/* PriceOrg213 */%' AND @definition LIKE N'%/* WebSitesFromFlags213 */%'
  AND OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows')) <> @definition
BEGIN
  SET @definition = N'ALTER ' + SUBSTRING(@definition, CHARINDEX(N'PROCEDURE', @definition), 2147483647);
  EXEC sys.sp_executesql @definition;
END;

/* --- 4) Kartica artikla: kljukica nosi oznako drevesa ----------------------------------- */

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetProductWebShops
  @ProductId bigint
AS
BEGIN
  SET NOCOUNT ON;
  SELECT shop.WebShopCode,
         shop.WebShopName,
         CAST(CASE WHEN flag.IsPublished = 1 THEN 1 ELSE 0 END AS bit) AS IsPublished,
         flag.ChangedBy,
         flag.ChangedUtc
  FROM (
    SELECT site.CategoryTreeCode AS WebShopCode,
           /* 213: ista oznaka kot v stolpcu "Spletne strani" (svetila, videlektro), ne ime strani */
           ISNULL(MIN(site.TreeLabel), MIN(site.WebSiteName)) AS WebShopName,
           MIN(site.SortOrder) AS SortOrder
    FROM canon.WebSite site
    WHERE site.IsActive = 1
    GROUP BY site.CategoryTreeCode
  ) AS shop
  LEFT JOIN pim.ProductWebShop flag
    ON flag.ProductId = @ProductId AND flag.WebShopCode = shop.WebShopCode
  ORDER BY shop.SortOrder, shop.WebShopCode;
END;
');

/* --- 5) Podjetje 2: B2B iz VID cenika B2B ----------------------------------------------- */

IF NOT EXISTS (SELECT 1 FROM dbo.OrganizationConfig WHERE OrganizationId = 2)
  THROW 52137, N'213: organizacija 2 ne obstaja.', 1;
IF NOT EXISTS (SELECT 1 FROM dbo.OrganizationConfig WHERE OrganizationId = 3)
  THROW 52138, N'213: organizacija 3 ne obstaja.', 1;
IF NOT EXISTS (SELECT 1 FROM canon.Codebook WHERE OrganizationId = 3 AND CodebookCode = N'PRICELIST' AND EntryCode = N'B2B' AND IsActive = 1)
  THROW 52139, N'213: cenik B2B za organizacijo 3 ni zajet v sifrantu.', 1;

/* Zacasna vrstica iz 208 (B2B <- IQ-jev B2C) se izklopi, ne izbrise: zgodovina ostane berljiva.
   V EXEC(N'...'), ker je cela migracija en paket: stolpec PriceOrganizationId nastane sele med
   izvajanjem (korak 1), prevajalnik pa bi neposreden stavek zavrnil z 207 (najdeno ob prvem zagonu). */
EXEC(N'
UPDATE out.ExportPriceList
  SET IsActive = 0, UpdatedUtc = SYSUTCDATETIME()
WHERE OrganizationId = 2 AND PriceFieldCode = N''Product.PriceB2B'' AND IsActive = 1
  AND NOT (PriceListCode = N''B2B'' AND PriceOrganizationId = 3);

MERGE out.ExportPriceList AS target
USING (SELECT 2 AS OrganizationId, N''Product.PriceB2B'' AS PriceFieldCode, N''B2B'' AS PriceListCode) AS source
  ON target.OrganizationId = source.OrganizationId AND target.PriceFieldCode = source.PriceFieldCode AND target.PriceListCode = source.PriceListCode
WHEN MATCHED THEN
  UPDATE SET PriceOrganizationId = 3, SortOrder = 10, IsActive = 1, UpdatedUtc = SYSUTCDATETIME()
WHEN NOT MATCHED THEN
  INSERT (OrganizationId, PriceFieldCode, PriceListCode, PriceOrganizationId, SortOrder, IsActive)
  VALUES (source.OrganizationId, source.PriceFieldCode, source.PriceListCode, 3, 10, 1);
');

/* --- 5b) Razpored MAGENTO_PRODUCTS samo za podjetje kataloga ---------------------------- */

/*
  Poln izvoz (--export-magento, postopek MAGENTO_PRODUCTS) od te odlocitve tece samo za podjetje 2
  (Katalog-cikel.ps1, Zaloga-cikel.ps1, Nocno-vse.ps1: -PodjetjeKataloga; gumb na /sistem/workerji:
  FixedOrganizationId). Razpored za podjetja 1, 3 in 4 se zato izklopi: nadzornik (WatchdogRules)
  bi sicer vklopljen razpored brez zagona po StaleAfterSeconds (2 h) vsakic razglasil za zastalega.
  Vrstica ostane (201 zahteva, da obstaja za vsa podjetja); rocen zagon za drugo podjetje pade z
  51100 »Razpored ni omogocen« — namerno, to ni vec podprta pot. MAGENTO_STOCK_PRICES ostane za
  vsa stiri. Ritem podjetja 2 ostane 3600/7200: skripte poln izvoz klicejo brez --po-urniku, zato
  petminutna obnova iz Zaloga-cikel.ps1 ni omejena z razporedom, socasnost pa varuje ops.BeginRun.
*/
UPDATE ops.ScheduleProfile
  SET IsEnabled = 0, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = N'migracija 213'
WHERE Pipeline = N'MAGENTO_PRODUCTS' AND OrganizationId <> 2 AND IsEnabled = 1;

UPDATE ops.ScheduleProfile
  SET IsEnabled = 1, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = N'migracija 213'
WHERE Pipeline = N'MAGENTO_PRODUCTS' AND OrganizationId = 2 AND IsEnabled = 0;

/* --- 6) Dokaz ---------------------------------------------------------------------------- */

IF NOT EXISTS (SELECT 1 FROM ops.ScheduleProfile WHERE Pipeline = N'MAGENTO_PRODUCTS' AND OrganizationId = 2 AND IsEnabled = 1)
  THROW 52146, N'213: razpored MAGENTO_PRODUCTS za podjetje 2 ni vklopljen.', 1;
IF EXISTS (SELECT 1 FROM ops.ScheduleProfile WHERE Pipeline = N'MAGENTO_PRODUCTS' AND OrganizationId <> 2 AND IsEnabled = 1)
  THROW 52147, N'213: razpored MAGENTO_PRODUCTS je se vklopljen za podjetje, ki kataloga nima.', 1;

IF OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows')) NOT LIKE N'%/* PriceOrg213 */%'
  THROW 52140, N'213: out.GetExportRows nima popravka cenika po podjetju.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows')) NOT LIKE N'%/* WebSitesFromFlags213 */%'
  THROW 52141, N'213: out.GetExportRows nima popravka spletnih strani iz kljukic.', 1;
/* Dokazi nad novima stolpcema prav tako v EXEC(N'...') — isti razlog kot pri koraku 5. */
EXEC(N'
IF EXISTS (SELECT 1 FROM canon.WebSite WHERE IsActive = 1 AND NULLIF(TreeLabel, N'''') IS NULL)
  THROW 52142, N''213: aktivna spletna stran brez oznake drevesa.'', 1;
IF (SELECT COUNT(*) FROM out.ExportPriceList WHERE OrganizationId = 2 AND PriceFieldCode = N''Product.PriceB2B'' AND IsActive = 1) <> 1
  THROW 52143, N''213: podjetje 2 nima natanko enega aktivnega vira za Cena B2B.'', 1;
IF NOT EXISTS (SELECT 1 FROM out.ExportPriceList WHERE OrganizationId = 2 AND PriceFieldCode = N''Product.PriceB2B'' AND IsActive = 1 AND PriceOrganizationId = 3 AND PriceListCode = N''B2B'')
  THROW 52144, N''213: Cena B2B podjetja 2 ne kaze na VID cenik B2B.'', 1;
');
