/*
  217 — kategorije VID pod nadkategorijo "Razsvetljava"; glavi "Popust na artikel" in "Pakirna kolicina".

  Sestanek 2026-09-16 (popravki_kataloga.csv), uporabnik:
    1. Opomba pri "Kategorije vid ANG": »Doda se nadkategorija Razsvetljava.«
       216 je drevo svetila_si zrcalila v KOREN drevesa videlektro (Notranja svetila > ...). Spletna
       stran videlektro.com pa ima svetila pod oddelkom "Razsvetljava" (092: razsvetljava, en
       "Lighting"). Zrcaljene kategorije se prestavijo pod razsvetljava: pot postane
       "Razsvetljava > Notranja svetila > Stropna svetila > ..." oz. "Lighting > Interior lighting > ...".
       Posebnost: "Tracni sistemi" pod razsvetljava ze obstaja (razsvetljava___tracni_sistemi, s
       spletne strani: Enofazni/Magnetni/Trofazni). Zrcaljena kopija (tracni_sistemi) bi dala dve
       kategoriji z istim imenom pod istim starsem, zato se njeni otroci (1-fazni 48V LVM, 3-fazni
       CTLS, ...) prestavijo pod obstojeco, kopija se izklopi, preslikava dobavitelja, ki je kazala
       nanjo, pa na obstojeco. Pot je enaka, kot bi bila sicer: "Razsvetljava > Tracni sistemi > ...".
    2. Glava stolpca 30 "Popust" -> "Popust na artikel" (vir Product.ClearancePercent nespremenjen).
    3. Glava stolpca 33 "PAK2" -> "Pakirna kolicina" (vir Product.Pak2 nespremenjen).
  Tocke 3, 4 in 6 s sestanka (Izpostavljeno, Razstavni eksponat, skupina popusta) se najprej
  uredijo v PIM-u in niso del te migracije.

  Uvrstitve izdelkov (canon/pim.ProductCategory, strani B2C/B2C_EN) so bile v 216 prepisane s
  svetil kot kopija poti. Tu se za vsako tako vrstico pot izracuna znova iz drevesa
  (canon.CategoryPathTranslated), ker se pri tracnih sistemih ne spremeni samo predpona, ampak tudi
  angleski naziv vozlisca ("Track systems" -> "Track Systems" obstojece kategorije). Stara vrstica
  se izbrise, nova vstavi; stevilo uvrstitev ostane enako. Rocna uvrstitev
  (pim.ProductCategoryOverride) ima prednost (109) in se ne dotakne.

  Migracija je ponovljiva: vsak korak preveri, ali je ze narejen. Migrator ne pozna GO.
*/

SET XACT_ABORT ON;

IF NOT EXISTS (SELECT 1 FROM canon.Category WHERE CategoryTreeCode = N'videlektro' AND CategoryCode = N'razsvetljava' AND IsActive = 1)
  THROW 52170, N'217: kategorija razsvetljava v drevesu videlektro ne obstaja (092).', 1;
IF NOT EXISTS (SELECT 1 FROM canon.Category WHERE CategoryTreeCode = N'videlektro' AND CategoryCode = N'notranja_svetila')
  THROW 52171, N'217: zrcaljene kategorije svetil v drevesu videlektro ne obstajajo (216).', 1;
IF NOT EXISTS (SELECT 1 FROM canon.Category WHERE CategoryTreeCode = N'videlektro' AND CategoryCode = N'razsvetljava___tracni_sistemi' AND IsActive = 1)
  THROW 52172, N'217: kategorija razsvetljava___tracni_sistemi v drevesu videlektro ne obstaja (092).', 1;

DECLARE @Prefix nvarchar(50) = N'Razsvetljava > ';

/* --- 0) Izhodisce za dokaz: stevilo uvrstitev na straneh videlektro pred spremembo -------- */
DECLARE @CanonBefore int = (SELECT COUNT(*) FROM canon.ProductCategory pc INNER JOIN canon.WebSite w ON w.WebSiteCode = pc.WebSite WHERE w.CategoryTreeCode = N'videlektro');
DECLARE @PimBefore int = (SELECT COUNT(*) FROM pim.ProductCategory pc INNER JOIN canon.WebSite w ON w.WebSiteCode = pc.WebSite WHERE w.CategoryTreeCode = N'videlektro');

/* --- 1) Stare poti uvrstitev si zapomnimo, dokler drevo se ni prestavljeno ---------------- */
/* Vrstica na strani videlektro je kopija svetil (216), ce ima izdelek isto pot na strani svetila_si
   v istem jeziku. Koda kategorije se poisce v drevesu svetila_si po prevedeni poti. */
CREATE TABLE #Uvrstitev
  (ProductId bigint NOT NULL, WebSite nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
   LanguageCode nvarchar(20) COLLATE DATABASE_DEFAULT NOT NULL,
   OldPath nvarchar(2000) COLLATE DATABASE_DEFAULT NOT NULL,
   CategoryCode nvarchar(400) COLLATE DATABASE_DEFAULT NULL);

INSERT #Uvrstitev (ProductId, WebSite, LanguageCode, OldPath, CategoryCode)
SELECT vidRow.ProductId, vidRow.WebSite, vid.LanguageCode, vidRow.CategoryPath,
  (SELECT TOP (1) node.CategoryCode FROM canon.CategoryPathTranslated node
   WHERE node.CategoryTreeCode = N'svetila_si' AND node.LanguageCode = vid.LanguageCode AND node.CategoryPath = vidRow.CategoryPath
   ORDER BY node.CategoryCode)
FROM canon.ProductCategory vidRow
INNER JOIN canon.WebSite vid ON vid.WebSiteCode = vidRow.WebSite AND vid.CategoryTreeCode = N'videlektro'
INNER JOIN canon.WebSite svetila ON svetila.CategoryTreeCode = N'svetila_si' AND svetila.LanguageCode = vid.LanguageCode
WHERE vidRow.CategoryPath NOT LIKE @Prefix + N'%' AND vidRow.CategoryPath NOT LIKE N'Lighting > %'
  AND EXISTS (SELECT 1 FROM canon.ProductCategory svetilaRow
              WHERE svetilaRow.ProductId = vidRow.ProductId AND svetilaRow.WebSite = svetila.WebSiteCode AND svetilaRow.CategoryPath = vidRow.CategoryPath);

/* Pot, ki je v drevesu svetila_si ni (izmerjeno: 1 testna vrstica "Svetila/Test"), ni kopija iz 216 — ostane pri miru. */
DELETE FROM #Uvrstitev WHERE CategoryCode IS NULL;

CREATE TABLE #UvrstitevPim
  (PimProductId bigint NOT NULL, ProductId bigint NULL, WebSite nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
   LanguageCode nvarchar(20) COLLATE DATABASE_DEFAULT NOT NULL,
   OldPath nvarchar(2000) COLLATE DATABASE_DEFAULT NOT NULL,
   CategoryCode nvarchar(400) COLLATE DATABASE_DEFAULT NULL);

INSERT #UvrstitevPim (PimProductId, ProductId, WebSite, LanguageCode, OldPath, CategoryCode)
SELECT vidRow.PimProductId, canonProduct.ProductId, vidRow.WebSite, vid.LanguageCode, vidRow.CategoryPath,
  (SELECT TOP (1) node.CategoryCode FROM canon.CategoryPathTranslated node
   WHERE node.CategoryTreeCode = N'svetila_si' AND node.LanguageCode = vid.LanguageCode AND node.CategoryPath = vidRow.CategoryPath
   ORDER BY node.CategoryCode)
FROM pim.ProductCategory vidRow
INNER JOIN pim.Product pimProduct ON pimProduct.PimProductId = vidRow.PimProductId
LEFT JOIN canon.Product canonProduct ON canonProduct.OrganizationId = pimProduct.OrganizationId AND canonProduct.ItemID = pimProduct.ItemID
INNER JOIN canon.WebSite vid ON vid.WebSiteCode = vidRow.WebSite AND vid.CategoryTreeCode = N'videlektro'
INNER JOIN canon.WebSite svetila ON svetila.CategoryTreeCode = N'svetila_si' AND svetila.LanguageCode = vid.LanguageCode
WHERE vidRow.CategoryPath NOT LIKE @Prefix + N'%' AND vidRow.CategoryPath NOT LIKE N'Lighting > %'
  AND EXISTS (SELECT 1 FROM pim.ProductCategory svetilaRow
              WHERE svetilaRow.PimProductId = vidRow.PimProductId AND svetilaRow.WebSite = svetila.WebSiteCode AND svetilaRow.CategoryPath = vidRow.CategoryPath);

DELETE FROM #UvrstitevPim WHERE CategoryCode IS NULL;

/* --- 2) Drevo: zrcaljene kategorije pod razsvetljava ----------------------------------------- */
/* Zrcaljena = koda obstaja tudi v drevesu svetila_si. Se ne prestavljena = pot brez predpone. */

/* 2a) Tracni sistemi: otroci kopije pod obstojeco kategorijo s spletne strani, kopija se izklopi. */
UPDATE canon.Category
  SET ParentCategoryCode = N'razsvetljava___tracni_sistemi'
WHERE CategoryTreeCode = N'videlektro' AND ParentCategoryCode = N'tracni_sistemi';

UPDATE map.CategoryPathMap
  SET CategoryCode = N'razsvetljava___tracni_sistemi', UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = N'migracija 217'
WHERE CategoryTreeCode = N'videlektro' AND CategoryCode = N'tracni_sistemi';

UPDATE canon.Category
  SET IsActive = 0, ParentCategoryCode = N'razsvetljava',
      LevelNo = 2, CategoryPath = @Prefix + CategoryPath
WHERE CategoryTreeCode = N'videlektro' AND CategoryCode = N'tracni_sistemi' AND CategoryPath NOT LIKE @Prefix + N'%';

/* 2b) Ostale zrcaljene korenske kategorije pod razsvetljava. */
UPDATE node
  SET ParentCategoryCode = N'razsvetljava'
FROM canon.Category node
WHERE node.CategoryTreeCode = N'videlektro' AND node.ParentCategoryCode IS NULL AND node.CategoryCode <> N'razsvetljava'
  AND EXISTS (SELECT 1 FROM canon.Category svetila WHERE svetila.CategoryTreeCode = N'svetila_si' AND svetila.CategoryCode = node.CategoryCode);

/* 2c) Raven in shranjena slovenska pot za vse zrcaljene, ki predpone se nimajo. */
UPDATE node
  SET LevelNo = node.LevelNo + 1, CategoryPath = @Prefix + node.CategoryPath
FROM canon.Category node
WHERE node.CategoryTreeCode = N'videlektro' AND node.CategoryPath NOT LIKE @Prefix + N'%'
  AND EXISTS (SELECT 1 FROM canon.Category svetila WHERE svetila.CategoryTreeCode = N'svetila_si' AND svetila.CategoryCode = node.CategoryCode);

/* --- 3) Uvrstitve izdelkov: nova pot iz drevesa --------------------------------------------- */
DECLARE @Tracni nvarchar(400) = N'tracni_sistemi';

/* Koda zrcaljene kopije tracnih sistemov kaze zdaj na obstojeco kategorijo. */
UPDATE #Uvrstitev SET CategoryCode = N'razsvetljava___tracni_sistemi' WHERE CategoryCode = @Tracni;
UPDATE #UvrstitevPim SET CategoryCode = N'razsvetljava___tracni_sistemi' WHERE CategoryCode = @Tracni;

DELETE pc
FROM canon.ProductCategory pc
INNER JOIN #Uvrstitev u ON u.ProductId = pc.ProductId AND u.WebSite = pc.WebSite AND u.OldPath = pc.CategoryPath
WHERE NOT EXISTS (SELECT 1 FROM pim.ProductCategoryOverride o WHERE o.ProductId = pc.ProductId AND o.WebSite = pc.WebSite);

INSERT canon.ProductCategory (ProductId, WebSite, CategoryPath)
SELECT DISTINCT u.ProductId, u.WebSite, node.CategoryPath
FROM #Uvrstitev u
INNER JOIN canon.CategoryPathTranslated node
  ON node.CategoryTreeCode = N'videlektro' AND node.CategoryCode = u.CategoryCode AND node.LanguageCode = u.LanguageCode
WHERE NOT EXISTS (SELECT 1 FROM canon.ProductCategory t WHERE t.ProductId = u.ProductId AND t.WebSite = u.WebSite AND t.CategoryPath = node.CategoryPath)
  AND NOT EXISTS (SELECT 1 FROM pim.ProductCategoryOverride o WHERE o.ProductId = u.ProductId AND o.WebSite = u.WebSite);

DELETE pc
FROM pim.ProductCategory pc
INNER JOIN #UvrstitevPim u ON u.PimProductId = pc.PimProductId AND u.WebSite = pc.WebSite AND u.OldPath = pc.CategoryPath
WHERE NOT EXISTS (SELECT 1 FROM pim.ProductCategoryOverride o WHERE o.ProductId = u.ProductId AND o.WebSite = pc.WebSite);

INSERT pim.ProductCategory (PimProductId, WebSite, CategoryPath)
SELECT DISTINCT u.PimProductId, u.WebSite, node.CategoryPath
FROM #UvrstitevPim u
INNER JOIN canon.CategoryPathTranslated node
  ON node.CategoryTreeCode = N'videlektro' AND node.CategoryCode = u.CategoryCode AND node.LanguageCode = u.LanguageCode
WHERE NOT EXISTS (SELECT 1 FROM pim.ProductCategory t WHERE t.PimProductId = u.PimProductId AND t.WebSite = u.WebSite AND t.CategoryPath = node.CategoryPath)
  AND NOT EXISTS (SELECT 1 FROM pim.ProductCategoryOverride o WHERE o.ProductId = u.ProductId AND o.WebSite = u.WebSite);

DROP TABLE #Uvrstitev;
DROP TABLE #UvrstitevPim;

/* --- 4) Glavi kataloga ---------------------------------------------------------------------- */
DECLARE @ProfileId int = (SELECT ExportProfileId FROM out.ExportProfile WHERE ProfileCode = N'MAGENTO_PRODUCTS');
IF @ProfileId IS NULL THROW 52175, N'217: profil MAGENTO_PRODUCTS manjka.', 1;

UPDATE out.ExportColumn SET OutputColumnName = N'Popust na artikel'
WHERE ExportProfileId = @ProfileId AND IsActive = 1 AND OutputColumnName = N'Popust' AND CanonicalFieldCode = N'Product.ClearancePercent';
UPDATE out.ExportColumn SET OutputColumnName = N'Pakirna količina'
WHERE ExportProfileId = @ProfileId AND IsActive = 1 AND OutputColumnName = N'PAK2' AND CanonicalFieldCode = N'Product.Pak2';

/* --- 5) Dokaz ------------------------------------------------------------------------------- */
IF EXISTS (SELECT 1 FROM canon.Category node
           WHERE node.CategoryTreeCode = N'videlektro' AND node.IsActive = 1 AND node.CategoryPath NOT LIKE @Prefix + N'%'
             AND EXISTS (SELECT 1 FROM canon.Category svetila WHERE svetila.CategoryTreeCode = N'svetila_si' AND svetila.CategoryCode = node.CategoryCode))
  THROW 52176, N'217: zrcaljena kategorija ni pod razsvetljava.', 1;
IF EXISTS (SELECT 1 FROM canon.Category WHERE CategoryTreeCode = N'videlektro' AND ParentCategoryCode = N'tracni_sistemi')
  THROW 52177, N'217: otroci zrcaljenih tracnih sistemov niso prestavljeni.', 1;
IF EXISTS (SELECT 1 FROM canon.Category WHERE CategoryTreeCode = N'videlektro' AND CategoryCode = N'tracni_sistemi' AND IsActive = 1)
  THROW 52178, N'217: zrcaljena kopija tracnih sistemov je se aktivna.', 1;
IF EXISTS (SELECT 1 FROM canon.Category node
           WHERE node.CategoryTreeCode = N'videlektro' AND node.IsActive = 1
             AND NOT EXISTS (SELECT 1 FROM canon.Category parent WHERE parent.CategoryTreeCode = node.CategoryTreeCode AND parent.CategoryCode = node.ParentCategoryCode AND parent.IsActive = 1)
             AND node.ParentCategoryCode IS NOT NULL)
  THROW 52179, N'217: aktivna kategorija z neaktivnim ali neobstojecim starsem.', 1;
IF EXISTS (SELECT 1 FROM canon.ProductCategory pc INNER JOIN canon.WebSite w ON w.WebSiteCode = pc.WebSite
           WHERE w.CategoryTreeCode = N'videlektro' AND w.LanguageCode = N'sl' AND pc.CategoryPath NOT LIKE @Prefix + N'%'
             AND EXISTS (SELECT 1 FROM canon.ProductCategory s INNER JOIN canon.WebSite sw ON sw.WebSiteCode = s.WebSite
                         WHERE s.ProductId = pc.ProductId AND sw.CategoryTreeCode = N'svetila_si' AND sw.LanguageCode = N'sl' AND s.CategoryPath = pc.CategoryPath)
             AND EXISTS (SELECT 1 FROM canon.CategoryPathTranslated node WHERE node.CategoryTreeCode = N'svetila_si' AND node.LanguageCode = N'sl' AND node.CategoryPath = pc.CategoryPath)
             AND NOT EXISTS (SELECT 1 FROM pim.ProductCategoryOverride o WHERE o.ProductId = pc.ProductId AND o.WebSite = pc.WebSite))
  THROW 52180, N'217: uvrstitev na videlektro se vedno brez predpone Razsvetljava.', 1;
IF (SELECT COUNT(*) FROM canon.ProductCategory pc INNER JOIN canon.WebSite w ON w.WebSiteCode = pc.WebSite WHERE w.CategoryTreeCode = N'videlektro') <> @CanonBefore
  THROW 52181, N'217: stevilo uvrstitev na videlektro (canon) se je spremenilo.', 1;
IF (SELECT COUNT(*) FROM pim.ProductCategory pc INNER JOIN canon.WebSite w ON w.WebSiteCode = pc.WebSite WHERE w.CategoryTreeCode = N'videlektro') <> @PimBefore
  THROW 52182, N'217: stevilo uvrstitev na videlektro (pim) se je spremenilo.', 1;
IF NOT EXISTS (SELECT 1 FROM out.ExportColumn WHERE ExportProfileId = @ProfileId AND IsActive = 1 AND OutputColumnName = N'Popust na artikel')
   OR NOT EXISTS (SELECT 1 FROM out.ExportColumn WHERE ExportProfileId = @ProfileId AND IsActive = 1 AND OutputColumnName = N'Pakirna količina')
  THROW 52183, N'217: glavi Popust na artikel / Pakirna kolicina manjkata.', 1;
IF (SELECT COUNT(*) FROM out.ExportColumn WHERE ExportProfileId = @ProfileId AND IsActive = 1) <> 176
  THROW 52184, N'217: katalog nima vec 176 stolpcev.', 1;
