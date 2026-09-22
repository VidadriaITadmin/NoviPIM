/* 235: "Podrobnosti kategorije" (/nastavitve/kategorije) kaze drobtinico poti (npr. "Notranja
   svetila > Downlights") pod izbrano vejo. Uporabnik 2026-09-21: ko v filtru zamenja jezik na en,
   se ime v glavi prevede (DisplayName ze bere canon.CategoryTranslation), pot pod njim pa ostane
   slovenska, ker jo je intranet.GetCategoryTree od nekdaj vracal iz kategorija.CategoryPath
   (canon.Category, slovenska "kanonicna" pot) - stolpec ni bil nikoli prevajan. Koda kategorije
   (npr. "notranja_svetila___downlights") namerno ostane taksna, kot je - uporabnik je izrecno rekel,
   naj se ne spreminja.

   Dodan stolpec CategoryPathDisplay: pot v @LanguageCode, prek canon.CategoryPathTranslated (059) -
   isti rekurzivni pogled, ki ga za pot v izbranem jeziku ze uporabljata GetCategoryTreeNodes in
   izbirnik kategorij (GetCategoryPickerAsync); manjkajoc prevod posameznega prednika v pogledu ze
   pade nazaj na njegovo slovensko ime. Izracunan ENKRAT v zacasno tabelo #PotPrikaz, NE prek OUTER
   APPLY na vsako vrstico - korelirano APPLY nad tem pogledom je bilo v 218 izmerjeno na 6 s na
   drevo. Zunanji ISNULL(pot.CategoryPath, v.CategoryPath) lovi se en rob primer: jezik, za katerega
   v celi bazi ni zapisanega SE NOBENEGA prevoda (potem ga niti CROSS JOIN znotraj pogleda ne zajame).

   Obstojeci CategoryPath (slovenska pot) ostane nespremenjen in se se naprej uporablja za notranjo
   logiko strani (zlaganje/Collapsed, iskanje @Iskanje, VejaFilter/ZPredniki) - to ni del prijavljene
   napake in bi sprememba primerjav po prevedeni poti tvegala neujemanje pri delno prevedenem drevesu.
   Migrator ne pozna GO (061), zato je cela procedura v EXEC(N'...') - enako kot 218. */
SET XACT_ABORT ON;

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetCategoryTree
  @CategoryTreeCode nvarchar(100) = NULL,
  @OrganizationId int = NULL,
  @LanguageCode nvarchar(10) = N''en'',
  @Iskanje nvarchar(200) = NULL,
  @Veja nvarchar(400) = NULL,
  @SamoBrezPrevoda bit = 0,
  @SamoZIzdelki bit = 0,
  @Nivo int = NULL
AS
BEGIN
  SET NOCOUNT ON;

  DECLARE @Jezikov int = (SELECT COUNT(DISTINCT LanguageCode) FROM canon.Language WHERE IsActive = 1);

  /* 218: uvrstitve izdelkov se preberejo enkrat (#Uvrstitev), stevci na kategorijo pa se izracunajo
     mnozicno: neposredni po enakosti poti (#Neposredno), poddrevo prek poti pod kategorijo (#Spodaj).
     Prej je OUTER APPLY za vsako kategorijo znova pregledal vse uvrstitve z LIKE - izmerjeno 12,5 s
     na klic, stran /nastavitve/kategorije ga klice dvakrat. Pomen je isti: stetje po poti, ne po
     drevesu (poti iz vseh spletnih strani), locilo poti je N'' > '' (110). */
  CREATE TABLE #Uvrstitev (CategoryPath nvarchar(1000) COLLATE DATABASE_DEFAULT NOT NULL, ProductId bigint NOT NULL);
  INSERT #Uvrstitev (CategoryPath, ProductId)
  SELECT DISTINCT k.CategoryPath, k.ProductId
  FROM canon.ProductCategory k
  INNER JOIN canon.Product izdelek ON izdelek.ProductId = k.ProductId
  WHERE (@OrganizationId IS NULL OR izdelek.OrganizationId = @OrganizationId);

  /* Brez kljuca po poti: nvarchar(1000) presega mejo kljuca 1700 bajtov; vrstic je nekaj tisoc. */
  CREATE TABLE #Neposredno (CategoryPath nvarchar(1000) COLLATE DATABASE_DEFAULT NOT NULL, Kolicina bigint NOT NULL);
  INSERT #Neposredno (CategoryPath, Kolicina)
  SELECT CategoryPath, COUNT_BIG(DISTINCT ProductId) FROM #Uvrstitev GROUP BY CategoryPath;

  CREATE TABLE #Spodaj (CategoryTreeCode nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL, CategoryCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
                        Kolicina bigint NOT NULL, PRIMARY KEY (CategoryTreeCode, CategoryCode));
  INSERT #Spodaj (CategoryTreeCode, CategoryCode, Kolicina)
  SELECT kategorija.CategoryTreeCode, kategorija.CategoryCode, COUNT_BIG(DISTINCT uvrstitev.ProductId)
  FROM canon.Category kategorija
  INNER JOIN (SELECT DISTINCT CategoryPath FROM #Uvrstitev) pot
    ON pot.CategoryPath = kategorija.CategoryPath OR pot.CategoryPath LIKE kategorija.CategoryPath + N'' > %''
  INNER JOIN #Uvrstitev uvrstitev ON uvrstitev.CategoryPath = pot.CategoryPath
  WHERE (@CategoryTreeCode IS NULL OR kategorija.CategoryTreeCode = @CategoryTreeCode)
  GROUP BY kategorija.CategoryTreeCode, kategorija.CategoryCode;

  /* 235: prikazana pot v izbranem jeziku - glej obrazlozitev na vrhu datoteke. */
  CREATE TABLE #PotPrikaz (CategoryTreeCode nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL, CategoryCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
                           CategoryPath nvarchar(1000) COLLATE DATABASE_DEFAULT NOT NULL, PRIMARY KEY (CategoryTreeCode, CategoryCode));
  INSERT #PotPrikaz (CategoryTreeCode, CategoryCode, CategoryPath)
  SELECT prevod.CategoryTreeCode, prevod.CategoryCode, prevod.CategoryPath
  FROM canon.CategoryPathTranslated prevod
  WHERE prevod.LanguageCode = @LanguageCode
    AND (@CategoryTreeCode IS NULL OR prevod.CategoryTreeCode = @CategoryTreeCode);

  ;WITH Osnova AS
  (
    SELECT kategorija.CategoryTreeCode, kategorija.CategoryCode, kategorija.ParentCategoryCode,
           kategorija.LevelNo, kategorija.CategoryName, kategorija.CategoryPath, kategorija.IsActive
    FROM canon.Category kategorija
    WHERE (@CategoryTreeCode IS NULL OR kategorija.CategoryTreeCode = @CategoryTreeCode)
  ),
  VejaFilter AS
  (
    SELECT o.* FROM Osnova o
    WHERE @Veja IS NULL
       OR o.CategoryCode = @Veja
       OR EXISTS (SELECT 1 FROM Osnova koren
                  WHERE koren.CategoryCode = @Veja
                    AND o.CategoryPath LIKE koren.CategoryPath + N'' > %'')
  ),
  Bogato AS
  (
    SELECT v.*,
      prevod.CategoryName AS TranslatedName,
      ISNULL(pot.CategoryPath, v.CategoryPath) AS CategoryPathDisplay,
      manjka.Manjka AS MissingLanguages,
      manjka.Seznam AS MissingLanguageList,
      ISNULL(neposredno.Kolicina, 0) AS ProductCount,
      ISNULL(spodaj.Kolicina, 0) AS DescendantProductCount,
      ISNULL(otroci.Kolicina, 0) AS ChildCount,
      vsi.Json AS TranslationsJson
    FROM VejaFilter v
    LEFT JOIN canon.CategoryTranslation prevod
      ON prevod.CategoryTreeCode = v.CategoryTreeCode AND prevod.CategoryCode = v.CategoryCode
        AND prevod.LanguageCode = @LanguageCode
    LEFT JOIN #PotPrikaz pot
      ON pot.CategoryTreeCode = v.CategoryTreeCode AND pot.CategoryCode = v.CategoryCode
    OUTER APPLY
    (
      SELECT COUNT(*) AS Manjka, STRING_AGG(jezik.LanguageCode, N'','') AS Seznam
      FROM (SELECT DISTINCT LanguageCode FROM canon.Language WHERE IsActive = 1) jezik
      WHERE NOT EXISTS
      (
        SELECT 1 FROM canon.CategoryTranslation p
        WHERE p.CategoryTreeCode = v.CategoryTreeCode AND p.CategoryCode = v.CategoryCode
          AND p.LanguageCode = jezik.LanguageCode
      )
    ) manjka
    OUTER APPLY
    (
      /* Vsi zapisani prevodi te kategorije v eni celici: urednik prevaja enkrat, v vse jezike. */
      SELECT (SELECT p.LanguageCode AS lang, p.CategoryName AS name
              FROM canon.CategoryTranslation p
              WHERE p.CategoryTreeCode = v.CategoryTreeCode AND p.CategoryCode = v.CategoryCode
              ORDER BY p.LanguageCode
              FOR JSON PATH) AS Json
    ) vsi
    OUTER APPLY
    (
      SELECT COUNT_BIG(*) AS Kolicina FROM canon.Category otrok
      WHERE otrok.CategoryTreeCode = v.CategoryTreeCode AND otrok.ParentCategoryCode = v.CategoryCode
        AND otrok.IsActive = 1
    ) otroci
    LEFT JOIN #Neposredno neposredno ON neposredno.CategoryPath = v.CategoryPath
    LEFT JOIN #Spodaj spodaj ON spodaj.CategoryTreeCode = v.CategoryTreeCode AND spodaj.CategoryCode = v.CategoryCode
  ),
  Zadetki AS
  (
    SELECT b.* FROM Bogato b
    WHERE (@Iskanje IS NULL
            OR b.CategoryName LIKE N''%'' + @Iskanje + N''%''
            OR b.CategoryPath LIKE N''%'' + @Iskanje + N''%''
            OR ISNULL(b.TranslationsJson, N'''') LIKE N''%'' + @Iskanje + N''%'')
      AND (@Nivo IS NULL OR b.LevelNo = @Nivo)
      AND (@SamoBrezPrevoda = 0 OR b.TranslatedName IS NULL)
      AND (@SamoZIzdelki = 0 OR b.DescendantProductCount > 0)
  ),
  ZPredniki AS
  (
    SELECT z.CategoryTreeCode, z.CategoryCode, CONVERT(bit, 1) AS JeZadetek FROM Zadetki z
    UNION
    SELECT b.CategoryTreeCode, b.CategoryCode, CONVERT(bit, 0)
    FROM Bogato b
    WHERE EXISTS (SELECT 1 FROM Zadetki z
                  WHERE z.CategoryTreeCode = b.CategoryTreeCode
                    AND z.CategoryPath LIKE b.CategoryPath + N'' > %'')
  )
  SELECT
    b.CategoryTreeCode, b.CategoryCode, b.ParentCategoryCode, b.LevelNo,
    b.CategoryName, b.CategoryPath, b.CategoryPathDisplay, b.IsActive,
    b.TranslatedName, b.MissingLanguages, b.MissingLanguageList, b.TranslationsJson,
    b.ProductCount, b.DescendantProductCount, b.ChildCount,
    MAX(CONVERT(tinyint, izbor.JeZadetek)) AS JeZadetek,
    @Jezikov AS Jezikov
  FROM Bogato b
  INNER JOIN ZPredniki izbor
    ON izbor.CategoryTreeCode = b.CategoryTreeCode AND izbor.CategoryCode = b.CategoryCode
  GROUP BY
    b.CategoryTreeCode, b.CategoryCode, b.ParentCategoryCode, b.LevelNo,
    b.CategoryName, b.CategoryPath, b.CategoryPathDisplay, b.IsActive,
    b.TranslatedName, b.MissingLanguages, b.MissingLanguageList, b.TranslationsJson,
    b.ProductCount, b.DescendantProductCount, b.ChildCount
  ORDER BY b.CategoryTreeCode, b.CategoryPath;

  DROP TABLE #PotPrikaz; DROP TABLE #Spodaj; DROP TABLE #Neposredno; DROP TABLE #Uvrstitev;
END;');

/* --- Dokaz ------------------------------------------------------------------------------- */
IF OBJECT_DEFINITION(OBJECT_ID(N'intranet.GetCategoryTree')) NOT LIKE N'%CategoryPathDisplay%'
  THROW 52351, N'235: CategoryPathDisplay ni bil zapisan v intranet.GetCategoryTree.', 1;
