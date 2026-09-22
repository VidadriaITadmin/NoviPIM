/*
  060 — enajst poti tracnih sistemov in odstranitev dobaviteljevih kategorij.

  Dvoje, oboje po odlocitvi uporabnika 2026-08-22.

  1. Nowodvorski poslje poti tracnih sistemov na treh ravneh
     ("Track systems > 3-circuit CTLS > Accessories"), stari slovar pa jih je imel na
     stirih ("... > Accessories > Recessed mounted"). Zato jih migracija 059 ni nasla in so
     cakale v map.MissingCategoryMap — enajst poti, 158 izdelkov. Vseh enajst gre v
     nadrejeno kategorijo, ki v nasem drevesu ze obstaja; predlogi so bili potrjeni
     (PIM_Solution\docs\Kategorije_manjkajoce.csv).

  2. Stare vrstice canon.ProductCategory s spletno stranjo 'B2C' in dobaviteljevo kategorijo
     prve ravni v anglescini ('Interior lighting', 'Cameleon System', 'Track systems',
     'Outdoor lighting', 'Light sources and accessories'). Naredila jih je preslikava, ki jo
     je 059 izklopila, ker je pisala angleisko besedo dobavitelja v slovenski stolpec
     videlektra. Brisanje je bilo na zaprtem seznamu (AGENTS.md #4.1) in je odobreno.

     Brise se natanko teh pet poti pod 'B2C' in nic drugega — v canon.ProductCategory in v
     pim.ProductCategory, ker objava vrstic, ki jih v katalogu ni vec, ne odstranjuje (058).
     Kategorije istih izdelkov pod 'svetila_si' in 'svetila_si_en' ostanejo; te so nase.
*/

SET XACT_ABORT ON;

/* --- 1) enajst potrjenih poti --------------------------------------------- */

MERGE map.CategoryPathMap AS target
USING (VALUES
  (N'track_systems___3-circuit_ctls___accessories',N'tracni_sistemi___3_fazni_ctls___dodatki'),
  (N'track_systems___1-circuit_profile___accessories',N'tracni_sistemi___1_fazni_profile___dodatki'),
  (N'track_systems___1-circuit_low-voltage_48v_lvm___accessories',N'tracni_sistemi___1_fazni_48v_lvm___dodatki'),
  (N'track_systems___1-circuit_low-voltage_24v_nano-lvm___accessories',N'tracni_sistemi___1_fazni_24v_nano_lvm___dodatki'),
  (N'track_systems___1-circuit_low-voltage_48v_lvm___tracks',N'tracni_sistemi___1_fazni_48v_lvm___tracnice'),
  (N'track_systems___1-circuit_profile___tracks',N'tracni_sistemi___1_fazni_profile___tracnice'),
  (N'track_systems___3-circuit_ctls___tracks',N'tracni_sistemi___3_fazni_ctls___tracnice'),
  (N'track_systems___1-circuit_low-voltage_24v_nano-lvm___tracks',N'tracni_sistemi___1_fazni_24v_nano_lvm___tracnice'),
  (N'track_systems___1-circuit_low-voltage_48v___ut-_lvm___accessories',N'tracni_sistemi___1_fazni_48v_ut_lvm___dodatki'),
  (N'track_systems___1-circuit_low-voltage_48v___ut-_lvm___tracks',N'tracni_sistemi___1_fazni_48v_ut_lvm___tracnice'),
  (N'track_systems___power_supplies_for_low_-voltage_systems___power_supplies_for_24v_low-voltage_system',N'svetlobni_viri_in_dodatki___napajalniki')
) AS source(SourcePathKey,CategoryCode)
  ON target.SourceCode = N'NW_XML' AND target.CategoryTreeCode = N'svetila_si'
    AND target.SourcePathKey = source.SourcePathKey
WHEN MATCHED THEN UPDATE SET CategoryCode = source.CategoryCode, IsActive = 1
WHEN NOT MATCHED THEN INSERT (SourceCode,CategoryTreeCode,SourcePathKey,CategoryCode,IsActive)
  VALUES (N'NW_XML',N'svetila_si',source.SourcePathKey,source.CategoryCode,1);

/* Ciljna kategorija mora obstajati, sicer bi preslikava tiho pisala v prazno. */
IF EXISTS
(
  SELECT 1 FROM map.CategoryPathMap slovar
  WHERE slovar.SourceCode = N'NW_XML' AND slovar.IsActive = 1
    AND NOT EXISTS
    (
      SELECT 1 FROM canon.Category category
      WHERE category.CategoryTreeCode = slovar.CategoryTreeCode
        AND category.CategoryCode = slovar.CategoryCode
    )
)
  THROW 52601, 'Slovar poti kaze na kategorijo, ki je v drevesu ni.', 1;

/* Pot, ki je zdaj v slovarju, ne sodi vec na delovni seznam manjkajocih. */
DELETE manjkajoce
FROM map.MissingCategoryMap manjkajoce
WHERE EXISTS
(
  SELECT 1 FROM map.CategoryPathMap slovar
  WHERE slovar.SourceCode = manjkajoce.SourceCode
    AND slovar.CategoryTreeCode = manjkajoce.CategoryTreeCode
    AND slovar.SourcePathKey = manjkajoce.SourcePathKey
    AND slovar.IsActive = 1
);

/* --- 2) dobaviteljeve kategorije pod 'B2C' gredo ven ----------------------- */

DECLARE @Dobaviteljeve TABLE(CategoryPath nvarchar(1000) PRIMARY KEY);
INSERT @Dobaviteljeve(CategoryPath) VALUES
  (N'Interior lighting'), (N'Outdoor lighting'), (N'Track systems'),
  (N'Cameleon System'), (N'Light sources and accessories');

DELETE objavljena
FROM pim.ProductCategory objavljena
INNER JOIN @Dobaviteljeve dobaviteljeva ON dobaviteljeva.CategoryPath = objavljena.CategoryPath
WHERE objavljena.WebSite = N'B2C';

DELETE kategorija
FROM canon.ProductCategory kategorija
INNER JOIN @Dobaviteljeve dobaviteljeva ON dobaviteljeva.CategoryPath = kategorija.CategoryPath
WHERE kategorija.WebSite = N'B2C';

/* --- 3) preverbe ---------------------------------------------------------- */

IF EXISTS
(
  SELECT 1 FROM canon.ProductCategory kategorija
  INNER JOIN @Dobaviteljeve dobaviteljeva ON dobaviteljeva.CategoryPath = kategorija.CategoryPath
  WHERE kategorija.WebSite = N'B2C'
)
  THROW 52602, 'Dobaviteljeve kategorije pod B2C so se vedno v katalogu.', 1;

IF (SELECT COUNT(*) FROM map.CategoryPathMap WHERE SourceCode = N'NW_XML' AND IsActive = 1) < 201
  THROW 52603, 'Enajst potrjenih poti ni vpisanih.', 1;
