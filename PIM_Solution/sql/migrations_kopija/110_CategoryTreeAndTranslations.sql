/*
  110 — drevo kategorij z zamikom, prevodi v vseh jezikih in uporabni filtri.

  Tri stvari, ki jih stran /nastavitve/kategorije ni znala:

    1. Ni bila drevo. Vozlisca so bila ravna tabela z nivojem kot stevilko v stolpcu; kam kaj
       pase, se je dalo razbrati samo iz polne poti v drobnem tisku.

    2. Stolpec "Prevod" je izpisoval pomisljaj za vsako vrstico - v kodi je bil dobesedno
       zapisan pomisljaj, ne prazna vrednost. Prevodi so v bazi ves cas obstajali.

    3. Stolpec "S podkategorijami" je bil narobe. Formula je iskala potomce z
       LIKE pot + N''/%'', locilo poti pa je N'' > ''. Zato je za "Notranja svetila" pokazala
       1 izdelek namesto 1.579 - in to ne kot prazno polje, ampak kot prepricljivo napacno
       stevilko.

  --- Koliko prevodov manjka (merjeno 2026-08-27) -------------------------------------------

  Jeziki v sifrantu: sl, en, de, hr, it. Kategorij 209. Popolno bi bilo 1.045 prevodov,
  zapisanih je 391, torej manjka 654:

      svetila_si   de 121, en 49, hr 121, it 132   (sl je poln)
      videlektro   de  77, hr  77, it  77          (sl in en sta polna)

  --- Zakaj prevod potrebuje svojo zapisovalno pot -----------------------------------------

  canon.CategoryPathTranslated sestavi pot iz imen prednikov v istem jeziku in kjer prevoda ni,
  vzame slovensko ime. To je prava odlocitev za splet - polovicno prevedena pot je uporabnejsa
  od prazne - ima pa neprijetno posledico: manjkajoc prevod se nikjer ne pokaze kot napaka,
  ampak kot slovenska beseda sredi tuje poti. Brez seznama, ki to sesteje, tega ne opazi nihce.

  Zato intranet.GetCategoryTree pri vsaki kategoriji pove, v katerih jezikih prevoda ni, in
  canon.SaveCategoryTranslation omogoci, da se to popravi brez migracije.
*/

SET XACT_ABORT ON;

/* --- 1) Zgodovina prevodov ---------------------------------------------------------------- */

EXEC(N'
IF OBJECT_ID(N''canon.CategoryTranslationHistory'') IS NULL
BEGIN
  CREATE TABLE canon.CategoryTranslationHistory
  (
    CategoryTranslationHistoryId bigint IDENTITY(1,1) NOT NULL
      CONSTRAINT PK_CategoryTranslationHistory PRIMARY KEY,
    CategoryTreeCode nvarchar(100) NOT NULL,
    CategoryCode     nvarchar(400) NOT NULL,
    LanguageCode     nvarchar(10)  NOT NULL,
    OldName          nvarchar(400) NULL,
    NewName          nvarchar(400) NOT NULL,
    ChangedBy        nvarchar(200) NOT NULL,
    ChangedUtc       datetime2(7)  NOT NULL
      CONSTRAINT DF_CategoryTranslationHistory_ChangedUtc DEFAULT(SYSUTCDATETIME())
  );
  CREATE INDEX IX_CategoryTranslationHistory_Kljuc
    ON canon.CategoryTranslationHistory(CategoryTreeCode, CategoryCode, LanguageCode, ChangedUtc DESC);
END;
');

/* --- 2) Urejanje prevoda ------------------------------------------------------------------ */

EXEC(N'
CREATE OR ALTER PROCEDURE canon.SaveCategoryTranslation
  @CategoryTreeCode nvarchar(100),
  @CategoryCode nvarchar(400),
  @LanguageCode nvarchar(10),
  @CategoryName nvarchar(400),
  @Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  IF NULLIF(LTRIM(RTRIM(@Actor)), N'''') IS NULL
    THROW 110001, N''Akter je obvezen: brez njega sprememba nima lastnika.'', 1;
  IF NULLIF(LTRIM(RTRIM(@CategoryName)), N'''') IS NULL
    THROW 110002, N''Prevod ne sme biti prazen. Prazen prevod ni isto kot manjkajoc - pomeni ime iz nic.'', 1;

  IF NOT EXISTS (SELECT 1 FROM canon.Category
                 WHERE CategoryTreeCode = @CategoryTreeCode AND CategoryCode = @CategoryCode AND IsActive = 1)
    THROW 110003, N''Kategorija v tem drevesu ne obstaja ali ni aktivna.'', 1;

  IF NOT EXISTS (SELECT 1 FROM canon.Language WHERE LanguageCode = @LanguageCode AND IsActive = 1)
    THROW 110004, N''Jezik ni v sifrantu ali ni aktiven.'', 1;

  SET @CategoryName = LTRIM(RTRIM(@CategoryName));

  DECLARE @Staro nvarchar(400) = NULL;
  SELECT @Staro = CategoryName FROM canon.CategoryTranslation
  WHERE CategoryTreeCode = @CategoryTreeCode AND CategoryCode = @CategoryCode AND LanguageCode = @LanguageCode;

  IF @Staro IS NOT NULL AND @Staro = @CategoryName
  BEGIN
    SELECT N''Unchanged'' AS Outcome;
    RETURN;
  END

  BEGIN TRANSACTION;

  IF @Staro IS NULL
    INSERT canon.CategoryTranslation (CategoryTreeCode, CategoryCode, LanguageCode, CategoryName)
    VALUES (@CategoryTreeCode, @CategoryCode, @LanguageCode, @CategoryName);
  ELSE
    UPDATE canon.CategoryTranslation SET CategoryName = @CategoryName
    WHERE CategoryTreeCode = @CategoryTreeCode AND CategoryCode = @CategoryCode AND LanguageCode = @LanguageCode;

  INSERT canon.CategoryTranslationHistory
    (CategoryTreeCode, CategoryCode, LanguageCode, OldName, NewName, ChangedBy)
  VALUES (@CategoryTreeCode, @CategoryCode, @LanguageCode, @Staro, @CategoryName, @Actor);

  COMMIT TRANSACTION;

  SELECT CASE WHEN @Staro IS NULL THEN N''Created'' ELSE N''Updated'' END AS Outcome;
END;
');

/* --- 3) Drevo ------------------------------------------------------------------------------ */

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetCategoryTree
  @CategoryTreeCode nvarchar(100) = NULL,
  @OrganizationId int = NULL,          /* NULL = vsa podjetja */
  @LanguageCode nvarchar(10) = N''en'',
  @Iskanje nvarchar(200) = NULL,
  @Veja nvarchar(400) = NULL,          /* samo ta kategorija in njeni potomci */
  @SamoBrezPrevoda bit = 0,
  @SamoZIzdelki bit = 0,
  @Nivo int = NULL
AS
BEGIN
  SET NOCOUNT ON;

  /*
    Zadetek filtra brez prednikov je iztrgan iz drevesa in bralec ne vidi, kje stoji. Zato se
    ob vsakem filtru dodajo se vsi predniki zadetkov, oznaceni kot kontekst (JeZadetek = 0).
    Brez tega je "drevo z zamikom" samo tabela z odmiki.
  */
  DECLARE @Jezikov int = (SELECT COUNT(DISTINCT LanguageCode) FROM canon.Language WHERE IsActive = 1);

  ;WITH Osnova AS
  (
    SELECT
      kategorija.CategoryTreeCode, kategorija.CategoryCode, kategorija.ParentCategoryCode,
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
      ISNULL(spodaj.Kolicina, 0) AS DescendantProductCount
    FROM VejaFilter v
    LEFT JOIN canon.CategoryTranslation prevod
      ON prevod.CategoryTreeCode = v.CategoryTreeCode AND prevod.CategoryCode = v.CategoryCode
        AND prevod.LanguageCode = @LanguageCode
    OUTER APPLY
    (
      SELECT COUNT(*) AS Manjka, STRING_AGG(jezik.LanguageCode, N'', '') AS Seznam
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
      SELECT COUNT_BIG(DISTINCT k.ProductId) AS Kolicina
      FROM canon.ProductCategory k
      INNER JOIN canon.Product izdelek ON izdelek.ProductId = k.ProductId
      WHERE k.CategoryPath = v.CategoryPath
        AND (@OrganizationId IS NULL OR izdelek.OrganizationId = @OrganizationId)
    ) neposredno
    OUTER APPLY
    (
      /*
        Locilo poti je N'' > '', ne N''/''. Stara formula je iskala potomce z LIKE pot + N''/%''
        in zato nikoli ni nasla nobenega: za "Notranja svetila" je pokazala 1 namesto 1.579.
      */
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
            OR ISNULL(b.TranslatedName, N'''') LIKE N''%'' + @Iskanje + N''%'')
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
    WHERE EXISTS
    (
      SELECT 1 FROM Zadetki z
      WHERE z.CategoryTreeCode = b.CategoryTreeCode AND z.CategoryPath LIKE b.CategoryPath + N'' > %''
    )
  )
  SELECT
    b.CategoryTreeCode, b.CategoryCode, b.ParentCategoryCode, b.LevelNo,
    b.CategoryName, b.CategoryPath, b.IsActive,
    b.TranslatedName, b.MissingLanguages, b.MissingLanguageList,
    b.ProductCount, b.DescendantProductCount,
    MAX(CONVERT(tinyint, izbor.JeZadetek)) AS JeZadetek,
    @Jezikov AS Jezikov
  FROM Bogato b
  INNER JOIN ZPredniki izbor
    ON izbor.CategoryTreeCode = b.CategoryTreeCode AND izbor.CategoryCode = b.CategoryCode
  GROUP BY
    b.CategoryTreeCode, b.CategoryCode, b.ParentCategoryCode, b.LevelNo,
    b.CategoryName, b.CategoryPath, b.IsActive,
    b.TranslatedName, b.MissingLanguages, b.MissingLanguageList,
    b.ProductCount, b.DescendantProductCount
  ORDER BY b.CategoryTreeCode, b.CategoryPath;
END;
');

/* --- 4) Koliko prevodov manjka, po drevesu in jeziku --------------------------------------- */

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetCategoryTranslationGaps
  @CategoryTreeCode nvarchar(100) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SELECT
    kategorija.CategoryTreeCode,
    jezik.LanguageCode,
    COUNT(*) AS Kategorij,
    SUM(CASE WHEN prevod.CategoryName IS NULL THEN 1 ELSE 0 END) AS BrezPrevoda
  FROM canon.Category kategorija
  CROSS JOIN (SELECT DISTINCT LanguageCode FROM canon.Language WHERE IsActive = 1) jezik
  LEFT JOIN canon.CategoryTranslation prevod
    ON prevod.CategoryTreeCode = kategorija.CategoryTreeCode
   AND prevod.CategoryCode = kategorija.CategoryCode
   AND prevod.LanguageCode = jezik.LanguageCode
  WHERE kategorija.IsActive = 1
    AND (@CategoryTreeCode IS NULL OR kategorija.CategoryTreeCode = @CategoryTreeCode)
  GROUP BY kategorija.CategoryTreeCode, jezik.LanguageCode
  ORDER BY kategorija.CategoryTreeCode, jezik.LanguageCode;
END;
');
