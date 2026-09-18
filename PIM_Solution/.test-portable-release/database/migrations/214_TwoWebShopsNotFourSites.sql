/*
  214 — filter "Spletno mesto" v intranetu pozna dve spletisci (svetila, videlektro), ne stiri
  jezikovne kombinacije iz canon.WebSite.

  Uporabnik 2026-09-15: »spletna mesta imamo samo dva in to sta svetila pa videlektro nič
  druigega tako da popravi v tabeli«. Slikan zaslon kaze spustni seznam na kartici izdelka
  (/izdelek, zavihek Splet) s stirimi vrsticami: svetila_si, svetila_si_en, B2C, B2C_EN.

  Kaj je bilo narobe. canon.WebSite ima namenoma 4 vrstice — to ni napaka in migracija jih ne
  brise: vsaka jezikovna razlicica (sl/en) istega spletisca potrebuje svoj CategoryFieldCode
  (Product.CategorySvetilaSl/En, Product.CategorySl/En) in svoj LanguageCode za /nastavitve/kanali
  (CatalogChannels.razor), ki ostaja tak, kot je. Napaka je bila, da je vsak drug filter "Spletno
  mesto" v intranetu (kartica izdelka, /splet, cenik, odprte tezave, izvoz na zahtevo) bral isti
  register naravnost in userju ponudil vse 4 vrstice — ceprav je clovesko vprasanje vedno »svetila
  ali videlektro«, ne »katera jezikovna razlicica«. Migracija 213 je isto locitev ze naredila za
  proceduro intranet.GetProductWebShops (kljukica na kartici) — ta migracija isto locitev doda za
  filtre in za dve preostali proceduri, ki filter dejansko izvedeta.

  Zakaj je bil B2C celo tiho pokvarjen filter. val.ValidationProfile.CategoryTreeCode za
  videlektro je 'videlektro', WEB_videlektro pa edini profil, ki blokira to stran. Filter na
  /kakovost (ValidationErrors.razor, SiteMatches) primerja izbrano spletno mesto s kodo profila
  kot podniz: "b2c" ni podniz "webvidelektro", zato izbira B2C v tistem filtru ni pokazala
  NOBENE od tezav profila WEB_videlektro. Filter, ki zdaj namesto B2C/B2C_EN ponudi 'videlektro',
  to popravi mimogrede — ni bil poseben cilj te migracije, je pa neposredna posledica.

  Kaj ta migracija naredi:
    1. out.GetExportRows (@WebSite): trije pogoji, ki so primerjali pim.ProductCategory.WebSite /
       canon.ProductCategory.WebSite naravnost z vhodnim parametrom, zdaj gredo prek
       canon.WebSite.CategoryTreeCode — isti vzorec, ki ga @WebSite = 'svetila_si'/'videlektro'
       ze uporablja v pim.ProductWebShop (182/201). Klicatelji (Web.razor, WebExportBuild.razor)
       nespremenjeni: `EffectiveSite`/`SiteFilterFor` sta ze prej posiljala WebSiteRow.WebSiteCode,
       zdaj bo to WebShopRow.ShopCode iz nove procedure spodaj — ista spremenljivka, drugacna
       vsebina.
    2. intranet.GetPriceListSheet (@WebSite): isti vzorec, ena vrstica; alias na canon.WebSite je
       ze sklopljen (site), popravek samo zamenja stolpec primerjave.
    3. Nova intranet.GetWebShops: seznam dveh spletisc za spustne sezname (ista poizvedba, ki jo
       213 ze uporablja znotraj intranet.GetProductWebShops za isti namen, tu samostojna).

  Kaj ta migracija NE naredi: canon.WebSite ostane pri 4 vrsticah (schema, registri, /nastavitve/
  kanali), pim.ProductCategory.WebSite in canon.ProductCategory.WebSite ostaneta pri 4 kodah
  (kategorija je se vedno vezana na jezik). Spremeni se samo POMEN vrednosti, ki jo intranet
  ponudi uporabniku v filtru in ki jo ta filter posreduje procedurama iz tocke 1 in 2.

  Procedura out.GetExportRows se od 171 naprej popravlja z zamenjavo besedila zive definicije
  (194, 201, 202, 204, 205, 206, 207, 213) — enako tu, z oznako /* ShopFilter214 */, da je
  migracija ponovljiva in da ne pade, ce je bila ze uporabljena. Migrator ne pozna GO (061),
  zato CREATE OR ALTER v EXEC(N'...').
*/

SET XACT_ABORT ON;

/* --- 1) out.GetExportRows: @WebSite je drevo (svetila_si/videlektro), ne stiri kode ------ */

DECLARE @old nvarchar(max), @new nvarchar(max), @definition nvarchar(max);

SET @definition = OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows'));
IF @definition IS NULL THROW 52220, N'214: out.GetExportRows ne obstaja.', 1;

IF @definition NOT LIKE N'%/* ShopFilter214 */%'
BEGIN
  /* a) kanonicni blok (CANON, profila ERP_L1/WEB_B2C_PRODUCTS): dva enaka pojava, oba EXISTS
     nad canon.ProductCategory brez ze sklopljenega canon.WebSite. */
  SET @old = N'category.ProductId = product.ProductId AND category.WebSite = @WebSite';
  IF @old IS NULL OR LEN(@old) = 0 OR (LEN(@definition) - LEN(REPLACE(@definition, @old, N''))) / LEN(@old) <> 2
    THROW 52221, N'214: out.GetExportRows nima pricakovanih dveh pogojev category.WebSite = @WebSite (CANON).', 1;
  SET @new = N'category.ProductId = product.ProductId AND EXISTS (SELECT 1 FROM canon.WebSite AS shopSite214 WHERE shopSite214.WebSiteCode = category.WebSite AND shopSite214.CategoryTreeCode = @WebSite) /* ShopFilter214 */';
  SET @definition = REPLACE(@definition, @old, @new);

  /* b) isti CANON blok, tretjic: stolpec ProductCategory.CategoryPath v #Value (8-presledkov
     zamik — locen pojav od (c) spodaj, ki ima 6). */
  SET @old = NCHAR(10) + N'        AND (@WebSite IS NULL OR category.WebSite = @WebSite)' + NCHAR(10);
  IF (LEN(@definition) - LEN(REPLACE(@definition, @old, N''))) / LEN(@old) <> 1
    THROW 52222, N'214: out.GetExportRows nima pricakovanega filtra ProductCategory.CategoryPath po @WebSite.', 1;
  SET @new = NCHAR(10) + N'        AND (@WebSite IS NULL OR EXISTS (SELECT 1 FROM canon.WebSite AS shopSite214b WHERE shopSite214b.WebSiteCode = category.WebSite AND shopSite214b.CategoryTreeCode = @WebSite))' + NCHAR(10);
  SET @definition = REPLACE(@definition, @old, @new);

  /* c) PIM_PRODUCT blok (#Site, izdelki za Magento): canon.WebSite je tu ze sklopljen kot "site"
     (ON site.WebSiteCode = category.WebSite) — popravek samo zamenja primerjavo. */
  SET @old = NCHAR(10) + N'      AND (@WebSite IS NULL OR category.WebSite = @WebSite)' + NCHAR(10);
  IF (LEN(@definition) - LEN(REPLACE(@definition, @old, N''))) / LEN(@old) <> 1
    THROW 52223, N'214: out.GetExportRows nima pricakovanega filtra #Site po @WebSite.', 1;
  SET @new = NCHAR(10) + N'      AND (@WebSite IS NULL OR site.CategoryTreeCode = @WebSite)' + NCHAR(10);
  SET @definition = REPLACE(@definition, @old, @new);

  /* Shranjena definicija se zacne s CREATE [OR ALTER]/ALTER; vse pred besedo PROCEDURE postane
     ALTER (enak postopek kot 201/213). */
  DECLARE @headerEndA int = CHARINDEX(N'PROCEDURE', @definition);
  IF @headerEndA = 0 THROW 52224, N'214: glava out.GetExportRows ni najdena.', 1;
  SET @definition = N'ALTER ' + SUBSTRING(@definition, @headerEndA, 2147483647);
  EXEC sys.sp_executesql @definition;
END;

/* --- 2) intranet.GetPriceListSheet: ista sprememba, en pojav ----------------------------- */

SET @definition = OBJECT_DEFINITION(OBJECT_ID(N'intranet.GetPriceListSheet'));
IF @definition IS NULL THROW 52225, N'214: intranet.GetPriceListSheet ne obstaja.', 1;

IF @definition NOT LIKE N'%/* ShopFilter214 */%'
BEGIN
  SET @old = N'productCategory.WebSite = @WebSite';
  IF (LEN(@definition) - LEN(REPLACE(@definition, @old, N''))) / LEN(@old) <> 1
    THROW 52226, N'214: intranet.GetPriceListSheet nima pricakovanega filtra po @WebSite.', 1;
  SET @new = N'site.CategoryTreeCode = @WebSite /* ShopFilter214 */';
  SET @definition = REPLACE(@definition, @old, @new);

  DECLARE @headerEndB int = CHARINDEX(N'PROCEDURE', @definition);
  IF @headerEndB = 0 THROW 52227, N'214: glava intranet.GetPriceListSheet ni najdena.', 1;
  SET @definition = N'ALTER ' + SUBSTRING(@definition, @headerEndB, 2147483647);
  EXEC sys.sp_executesql @definition;
END;

/* --- 3) Nova procedura: seznam dveh spletisc za spustne sezname -------------------------- */

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetWebShops
AS
BEGIN
  SET NOCOUNT ON;
  /* 214: isti izracun kot v intranet.GetProductWebShops (213) — tam vrne kljukico za en
     izdelek, tu vrne sam seznam. Namerno brez jezikovnih vrstic canon.WebSite: uporabnik vidi
     spletisce (svetila, videlektro), ne kombinacijo jezika. */
  SELECT site.CategoryTreeCode AS ShopCode,
         ISNULL(MIN(site.TreeLabel), MIN(site.WebSiteName)) AS ShopName,
         MIN(site.SortOrder) AS SortOrder
  FROM canon.WebSite AS site
  WHERE site.IsActive = 1
  GROUP BY site.CategoryTreeCode
  ORDER BY MIN(site.SortOrder), site.CategoryTreeCode;
END;
');

/* --- 4) Dokaz ----------------------------------------------------------------------------- */

IF OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows')) NOT LIKE N'%/* ShopFilter214 */%'
  THROW 52228, N'214: out.GetExportRows nima popravka filtra spletisca.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'intranet.GetPriceListSheet')) NOT LIKE N'%/* ShopFilter214 */%'
  THROW 52229, N'214: intranet.GetPriceListSheet nima popravka filtra spletisca.', 1;
IF OBJECT_ID(N'intranet.GetWebShops', N'P') IS NULL
  THROW 52230, N'214: intranet.GetWebShops ni nastala.', 1;
DECLARE @ShopCount int;
CREATE TABLE #Shops (ShopCode nvarchar(100), ShopName nvarchar(200), SortOrder int);
INSERT #Shops EXEC intranet.GetWebShops;
SELECT @ShopCount = COUNT(*) FROM #Shops;
IF @ShopCount <> 2
  THROW 52231, N'214: intranet.GetWebShops mora vrniti natanko dve spletisci (svetila, videlektro).', 1;
DROP TABLE #Shops;
