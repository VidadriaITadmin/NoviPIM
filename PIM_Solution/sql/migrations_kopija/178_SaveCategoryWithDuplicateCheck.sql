/*
  178 — nova kategorija iz aplikacije, s preverbo podvajanja.

  Uporabnik 2026-09-08: "rabimo neko preverbo, da ne bomo podvajali atribute in kategorije pri vsaki
  strani, tako da mora obstajati opozorilo" in "da lahko lepo pise notri in se mu v dropdown meniju
  zacne prikazovati kategorija in celotna drevesna struktura".

  Do 178 je kategorije vstavljala samo migracija (MERGE v 059/092); v aplikaciji ni bilo poti, da bi
  urednik dodal vozlisce, in nobene preverbe, da pod istim starsem ze obstaja kategorija z istim
  imenom (UQ_CategoryTranslation je le (drevo, koda, jezik)).

    1. canon.CategoryCodeFromName(@Name) — koda vozlisca po isti konvenciji kot v 059/092: male crke,
       brez sumnikov, vse, kar ni crka ali stevka, je podcrtaj; ravni loci "___".
       "LED sijalke GU5.3" -> led_sijalke_gu5_3, "Instalacije" -> instalacije.

    2. canon.SaveCategory(drevo, stars, ime, akter) — ustvari kategorijo pod starsem (NULL = koren):
       koda = koda starsa + "___" + koda imena, LevelNo = stars + 1, CategoryPath = pot starsa + " > " + ime,
       slovenski prevod, revizija. PODVAJANJE: ce pod istim starsem ze obstaja kategorija, katere ime
       da isto kodo (torej enako ime brez sumnikov in velikosti crk, npr. "Viseca svetila" in
       "Viseča svetila"), postopek zavrne z imenom obstojece (51781) — tudi ce je ta neaktivna, ker se
       takrat vklopi nazaj, ne podvoji. Enako, ce bi koda ze obstajala kjerkoli v drevesu (51782).
       Podobna imena (vsebovanost) presoja clovek: izbirnik jih pokaze pred klikom.

  canon.CategoryPathTranslated je pogled, zato nova kategorija takoj dobi pot v vseh jezikih
  (slovensko ime, dokler prevoda ni). Migrator ne pozna locila GO; objekti so v EXEC(N'...').
*/

SET XACT_ABORT ON;

EXEC(N'CREATE OR ALTER FUNCTION canon.CategoryCodeFromName(@Name nvarchar(400))
RETURNS nvarchar(200)
AS
BEGIN
  DECLARE @Code nvarchar(400) = LOWER(LTRIM(RTRIM(@Name)));
  SET @Code = REPLACE(REPLACE(REPLACE(@Code, NCHAR(269), N''c''), NCHAR(353), N''s''), NCHAR(382), N''z'');
  SET @Code = REPLACE(REPLACE(REPLACE(@Code, NCHAR(263), N''c''), NCHAR(273), N''d''), NCHAR(228), N''a'');
  SET @Code = REPLACE(REPLACE(REPLACE(@Code, NCHAR(246), N''o''), NCHAR(252), N''u''), NCHAR(223), N''ss'');
  DECLARE @Out nvarchar(400) = N'''', @I int = 1, @Ch nchar(1), @Prev bit = 0;
  WHILE @I <= LEN(@Code)
  BEGIN
    SET @Ch = SUBSTRING(@Code, @I, 1);
    IF @Ch LIKE N''[a-z0-9]'' COLLATE Latin1_General_BIN
    BEGIN SET @Out += @Ch; SET @Prev = 0; END
    ELSE IF @Prev = 0 AND LEN(@Out) > 0
    BEGIN SET @Out += N''_''; SET @Prev = 1; END
    SET @I += 1;
  END;
  IF RIGHT(@Out, 1) = N''_'' SET @Out = LEFT(@Out, LEN(@Out) - 1);
  RETURN LEFT(@Out, 200);
END');

EXEC(N'CREATE OR ALTER PROCEDURE canon.SaveCategory
  @CategoryTreeCode nvarchar(100),
  @ParentCategoryCode nvarchar(200) = NULL,   /* NULL = koren drevesa */
  @Name nvarchar(400),
  @Actor nvarchar(200),
  @CategoryCode nvarchar(200) OUTPUT
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  SET @Name = NULLIF(LTRIM(RTRIM(@Name)), N'''');
  SET @Actor = NULLIF(LTRIM(RTRIM(@Actor)), N'''');
  SET @ParentCategoryCode = NULLIF(LTRIM(RTRIM(@ParentCategoryCode)), N'''');
  IF @Name IS NULL THROW 51780, N''Ime kategorije je prazno.'', 1;
  IF @Actor IS NULL THROW 51783, N''Kdo ustvarja kategorijo, mora biti znano (Actor).'', 1;
  IF NOT EXISTS (SELECT 1 FROM canon.Category WHERE CategoryTreeCode = @CategoryTreeCode)
    THROW 51784, N''Drevo kategorij ne obstaja.'', 1;

  DECLARE @ParentLevel int = 0, @ParentPath nvarchar(1000) = NULL;
  IF @ParentCategoryCode IS NOT NULL
  BEGIN
    SELECT @ParentLevel = LevelNo, @ParentPath = CategoryPath FROM canon.Category
    WHERE CategoryTreeCode = @CategoryTreeCode AND CategoryCode = @ParentCategoryCode;
    IF @ParentPath IS NULL THROW 51785, N''Nadrejena kategorija ne obstaja v tem drevesu.'', 1;
  END;

  DECLARE @Slug nvarchar(200) = canon.CategoryCodeFromName(@Name);
  IF NULLIF(@Slug, N'''') IS NULL THROW 51786, N''Iz imena ni mogoce narediti kode kategorije.'', 1;
  SET @CategoryCode = CASE WHEN @ParentCategoryCode IS NULL THEN @Slug ELSE CONCAT(@ParentCategoryCode, N''___'', @Slug) END;

  /* Podvajanje: isto ime (po kodi) pod istim starsem. */
  DECLARE @Existing nvarchar(400) =
    (SELECT TOP (1) CategoryName FROM canon.Category
     WHERE CategoryTreeCode = @CategoryTreeCode
       AND ((@ParentCategoryCode IS NULL AND ParentCategoryCode IS NULL) OR ParentCategoryCode = @ParentCategoryCode)
       AND canon.CategoryCodeFromName(CategoryName) = @Slug);
  IF @Existing IS NOT NULL
  BEGIN
    DECLARE @DuplicateMessage nvarchar(1000) = CONCAT(N''Pod isto nadrejeno kategorijo ze obstaja "'', @Existing, N''" — kategorija se ne podvoji; izberi obstojeco.'');
    THROW 51781, @DuplicateMessage, 1;
  END;
  IF EXISTS (SELECT 1 FROM canon.Category WHERE CategoryTreeCode = @CategoryTreeCode AND CategoryCode = @CategoryCode)
  BEGIN
    DECLARE @CodeMessage nvarchar(1000) = CONCAT(N''Koda kategorije "'', @CategoryCode, N''" ze obstaja v tem drevesu.'');
    THROW 51782, @CodeMessage, 1;
  END;

  BEGIN TRANSACTION;
  INSERT canon.Category (CategoryTreeCode, CategoryCode, ParentCategoryCode, LevelNo, CategoryName, CategoryPath, IsActive)
  VALUES (@CategoryTreeCode, @CategoryCode, @ParentCategoryCode, @ParentLevel + 1, @Name,
    CASE WHEN @ParentPath IS NULL THEN @Name ELSE CONCAT(@ParentPath, N'' > '', @Name) END, 1);
  IF NOT EXISTS (SELECT 1 FROM canon.CategoryTranslation WHERE CategoryTreeCode = @CategoryTreeCode AND CategoryCode = @CategoryCode AND LanguageCode = N''sl'')
    INSERT canon.CategoryTranslation (CategoryTreeCode, CategoryCode, LanguageCode, CategoryName) VALUES (@CategoryTreeCode, @CategoryCode, N''sl'', @Name);
  INSERT b2b.AuditLog (OrganizationId, EntityType, EntityKey, ActionCode, OldValueJson, NewValueJson, ChangedBy, ChangedUtc)
  VALUES (0, N''Category'', CONCAT(@CategoryTreeCode, N''/'', @CategoryCode), N''ADD'', NULL,
    (SELECT @Name AS name, @ParentCategoryCode AS parent FOR JSON PATH, WITHOUT_ARRAY_WRAPPER), @Actor, SYSUTCDATETIME());
  COMMIT TRANSACTION;
END');
