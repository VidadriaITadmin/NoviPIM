/*
  113 — drevo vrne vse jezike naenkrat in prevodi se shranijo v enem koraku.

  Kaj je bilo narobe pri 110. Drevo je vracalo prevod za en sam izbrani jezik, zato je moral
  urednik za pet jezikov petkrat prevesti isto vrstico in petkrat menjati filter. Delo pa ne
  poteka tako: kategorijo prevedes enkrat, v vse jezike, ker jo takrat imas pred sabo.

  Zato ta migracija:

    1. intranet.GetCategoryTree doda TranslationsJson - vse zapisane prevode te kategorije v
       eni celici - in ChildCount, ki vmesniku pove, ali je vozlisce sploh mogoce razpreti.
       Stolpec TranslatedName ostane, ker po njem tece filter "samo brez prevoda v jeziku X".

    2. canon.SaveCategoryTranslations sprejme vec jezikov hkrati in jih zapise v eni transakciji.
       Delno shranjenih prevodov ni: ce en jezik pade na pravilu, ne obvelja noben. Delno
       shranjeno stanje je pri prevodih huje od nezapisanega, ker izgleda opravljeno.

    3. intranet.GetCategoryTranslationCoverage vrne pokritost po jeziku v eni vrstici na jezik,
       cez vsa drevesa skupaj in po drevesih. Deset locenih stevilk je bilo treba sesteti v
       glavi in so zasedle cel zaslon, preden se je videla prva kategorija.

  Ta migracija ne spremeni nobenega prevoda in ne doda nobene kategorije.
*/

SET XACT_ABORT ON;

/* --- 1) Drevo z vsemi jeziki -------------------------------------------------------------- */

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetCategoryTree
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
    OUTER APPLY
    (
      SELECT COUNT_BIG(DISTINCT k.ProductId) AS Kolicina
      FROM canon.ProductCategory k
      INNER JOIN canon.Product izdelek ON izdelek.ProductId = k.ProductId
      WHERE k.CategoryPath = v.CategoryPath
        AND (@OrganizationId IS NULL OR izdelek.OrganizationId = @OrganizationId)
    ) neposredno
    OUTER APPLY
    (
      /* Locilo poti je N'' > '', ne N''/'' - glej 110. */
      SELECT COUNT_BIG(DISTINCT k.ProductId) AS Kolicina
      FROM canon.ProductCategory k
      INNER JOIN canon.Product izdelek ON izdelek.ProductId = k.ProductId
      WHERE (k.CategoryPath = v.CategoryPath OR k.CategoryPath LIKE v.CategoryPath + N'' > %'')
        AND (@OrganizationId IS NULL OR izdelek.OrganizationId = @OrganizationId)
    ) spodaj
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
    b.CategoryName, b.CategoryPath, b.IsActive,
    b.TranslatedName, b.MissingLanguages, b.MissingLanguageList, b.TranslationsJson,
    b.ProductCount, b.DescendantProductCount, b.ChildCount,
    MAX(CONVERT(tinyint, izbor.JeZadetek)) AS JeZadetek,
    @Jezikov AS Jezikov
  FROM Bogato b
  INNER JOIN ZPredniki izbor
    ON izbor.CategoryTreeCode = b.CategoryTreeCode AND izbor.CategoryCode = b.CategoryCode
  GROUP BY
    b.CategoryTreeCode, b.CategoryCode, b.ParentCategoryCode, b.LevelNo,
    b.CategoryName, b.CategoryPath, b.IsActive,
    b.TranslatedName, b.MissingLanguages, b.MissingLanguageList, b.TranslationsJson,
    b.ProductCount, b.DescendantProductCount, b.ChildCount
  ORDER BY b.CategoryTreeCode, b.CategoryPath;
END;
');

/* --- 2) Shranjevanje vec jezikov hkrati --------------------------------------------------- */

EXEC(N'
CREATE OR ALTER PROCEDURE canon.SaveCategoryTranslations
  @CategoryTreeCode nvarchar(100),
  @CategoryCode nvarchar(400),
  @TranslationsJson nvarchar(max),   /* [{"lang":"en","name":"Interior lighting"}, ...] */
  @Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  IF NULLIF(LTRIM(RTRIM(@Actor)), N'''') IS NULL
    THROW 113001, N''Akter je obvezen: brez njega sprememba nima lastnika.'', 1;

  IF NOT EXISTS (SELECT 1 FROM canon.Category
                 WHERE CategoryTreeCode = @CategoryTreeCode AND CategoryCode = @CategoryCode AND IsActive = 1)
    THROW 113002, N''Kategorija v tem drevesu ne obstaja ali ni aktivna.'', 1;

  DECLARE @Vhod TABLE(LanguageCode nvarchar(10) NOT NULL PRIMARY KEY, CategoryName nvarchar(400) NOT NULL);
  INSERT @Vhod(LanguageCode, CategoryName)
  SELECT LTRIM(RTRIM(vrstica.lang)), LTRIM(RTRIM(vrstica.name))
  FROM OPENJSON(@TranslationsJson)
    WITH (lang nvarchar(10) N''$.lang'', name nvarchar(400) N''$.name'') vrstica
  WHERE NULLIF(LTRIM(RTRIM(vrstica.name)), N'''') IS NOT NULL;

  DECLARE @NeznanJezik nvarchar(10) = NULL;
  SELECT TOP (1) @NeznanJezik = vhod.LanguageCode FROM @Vhod vhod
  WHERE NOT EXISTS (SELECT 1 FROM canon.Language WHERE LanguageCode = vhod.LanguageCode AND IsActive = 1);
  IF @NeznanJezik IS NOT NULL
    THROW 113003, N''Eden od jezikov ni v sifrantu ali ni aktiven.'', 1;

  /*
    Ce en jezik pade na pravilu, ne obvelja noben. Delno shranjen prevod izgleda opravljen in
    ga nihce ne pregleda znova.
  */
  BEGIN TRANSACTION;

  INSERT canon.CategoryTranslationHistory
    (CategoryTreeCode, CategoryCode, LanguageCode, OldName, NewName, ChangedBy)
  SELECT @CategoryTreeCode, @CategoryCode, vhod.LanguageCode, staro.CategoryName, vhod.CategoryName, @Actor
  FROM @Vhod vhod
  LEFT JOIN canon.CategoryTranslation staro
    ON staro.CategoryTreeCode = @CategoryTreeCode AND staro.CategoryCode = @CategoryCode
   AND staro.LanguageCode = vhod.LanguageCode
  WHERE staro.CategoryName IS NULL OR staro.CategoryName <> vhod.CategoryName;

  MERGE canon.CategoryTranslation AS target
  USING (SELECT LanguageCode, CategoryName FROM @Vhod) AS source
    ON target.CategoryTreeCode = @CategoryTreeCode AND target.CategoryCode = @CategoryCode
   AND target.LanguageCode = source.LanguageCode
  WHEN MATCHED AND target.CategoryName <> source.CategoryName
    THEN UPDATE SET CategoryName = source.CategoryName
  WHEN NOT MATCHED THEN INSERT (CategoryTreeCode, CategoryCode, LanguageCode, CategoryName)
    VALUES (@CategoryTreeCode, @CategoryCode, source.LanguageCode, source.CategoryName);

  DECLARE @Spremenjenih int = @@ROWCOUNT;
  COMMIT TRANSACTION;

  SELECT @Spremenjenih AS Changed;
END;
');

/* --- 3) Pokritost v eni vrstici na jezik --------------------------------------------------- */

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetCategoryTranslationCoverage
  @CategoryTreeCode nvarchar(100) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SELECT
    jezik.LanguageCode,
    MAX(jezik.Name) AS LanguageName,
    COUNT(*) AS Categories,
    SUM(CASE WHEN prevod.CategoryName IS NOT NULL THEN 1 ELSE 0 END) AS Translated,
    SUM(CASE WHEN prevod.CategoryName IS NULL THEN 1 ELSE 0 END) AS Missing
  FROM canon.Category kategorija
  CROSS JOIN (SELECT DISTINCT LanguageCode, Name FROM canon.Language WHERE IsActive = 1) jezik
  LEFT JOIN canon.CategoryTranslation prevod
    ON prevod.CategoryTreeCode = kategorija.CategoryTreeCode
   AND prevod.CategoryCode = kategorija.CategoryCode
   AND prevod.LanguageCode = jezik.LanguageCode
  WHERE kategorija.IsActive = 1
    AND (@CategoryTreeCode IS NULL OR kategorija.CategoryTreeCode = @CategoryTreeCode)
  GROUP BY jezik.LanguageCode
  ORDER BY jezik.LanguageCode;
END;
');
