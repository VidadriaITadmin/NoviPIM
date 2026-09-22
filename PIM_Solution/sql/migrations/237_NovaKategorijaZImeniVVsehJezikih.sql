/* 237: nova kategorija z imeni v vseh jezikih hkrati.

   Uporabnik 2026-09-21 (»napake kategorij v PIM«):
     - »ko izbereš angleško drevo se pot pokaže v slovenščini«
     - »dodajanje angleške podkategorije ni možno ker jo doda v slovensko drevo«

   »Angleško drevo« na strani /nastavitve/kategorije je isto drevo (svetila_si, videlektro),
   gledano v jeziku en (filter »Jezik v ospredju«). Drevo je eno; canon.Category nosi slovensko
   (kanonicno) ime, pot in kodo, canon.CategoryTranslation pa imena v ostalih jezikih. Ko je
   urednik v angleskem pogledu dodal podkategorijo, je obrazec ponujal samo »Ime (slovensko)«:
   anglesko ime je pristalo kot slovensko ime (in v kodi/poti), angleskega prevoda pa ni bilo -
   kategorija je bila videti, kot da je »padla v slovensko drevo«. Pot v izbirnikih starsa in
   premika je poleg tega ostala slovenska tudi po 235 (ta je prevedla samo glavo in drobtinice).

   Kaj ta migracija spremeni:
     canon.SaveCategory dobi neobvezen @TranslationsJson ([{"lang":"en","name":"..."}, ...]).
     Kategorija se ustvari s slovenskim imenom (iz njega nastaneta koda in pot - to ostane, ker
     je pravilo 178/223), v isti transakciji pa se zapisejo se imena v ostalih jezikih prek
     canon.SaveCategoryTranslations (223) - isto pravilo o neznanem jeziku, ista revizijska sled.
     Ce en jezik pade, ne obvelja nic (XACT_ABORT).

   Prevedene poti v izbirnikih (stars nove kategorije, cilj premika) so stvar intraneta
   (CategoryTreeService.GetCategoryOptionsAsync bere canon.CategoryPathTranslated iz 059) in ne
   potrebujejo spremembe baze.

   Obstojeci klici brez @TranslationsJson delujejo nespremenjeno. Migrator ne pozna GO (061),
   zato je procedura v EXEC(N'...'). */
SET XACT_ABORT ON;

EXEC(N'CREATE OR ALTER PROCEDURE canon.SaveCategory
  @CategoryTreeCode nvarchar(100),
  @ParentCategoryCode nvarchar(200) = NULL,   /* NULL = koren drevesa */
  @Name nvarchar(400),
  @Actor nvarchar(200),
  @CategoryCode nvarchar(200) OUTPUT,
  @TranslationsJson nvarchar(max) = NULL      /* 237: imena v ostalih jezikih, neobvezno */
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  SET @Name = NULLIF(LTRIM(RTRIM(@Name)), N'''');
  SET @Actor = NULLIF(LTRIM(RTRIM(@Actor)), N'''');
  SET @ParentCategoryCode = NULLIF(LTRIM(RTRIM(@ParentCategoryCode)), N'''');
  SET @TranslationsJson = NULLIF(LTRIM(RTRIM(@TranslationsJson)), N'''');
  IF @Name IS NULL THROW 51780, N''Ime kategorije je prazno.'', 1;
  IF @Actor IS NULL THROW 51783, N''Kdo ustvarja kategorijo, mora biti znano (Actor).'', 1;
  IF NOT EXISTS (SELECT 1 FROM canon.Category WHERE CategoryTreeCode = @CategoryTreeCode)
    THROW 51784, N''Drevo kategorij ne obstaja.'', 1;
  IF @TranslationsJson IS NOT NULL AND ISJSON(@TranslationsJson) = 0
    THROW 52370, N''Imena po jezikih niso veljaven JSON.'', 1;

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

  /* 237: imena v ostalih jezikih v isti transakciji. Slovensko ime je ze zapisano zgoraj; ce ga
     klicatelj vseeno poslje enakega, SaveCategoryTranslations ne preimenuje nicesar. Postopek
     zavrne neznan ali neaktiven jezik (113003) - takrat se s XACT_ABORT razveljavi tudi
     kategorija sama: kategorija brez obljubljenih imen bi bila videti opravljena, pa ni. */
  IF @TranslationsJson IS NOT NULL
     AND EXISTS (SELECT 1 FROM OPENJSON(@TranslationsJson) WITH (lang nvarchar(10) N''$.lang'', name nvarchar(400) N''$.name'')
                 WHERE NULLIF(LTRIM(RTRIM(name)), N'''') IS NOT NULL)
  BEGIN
    DECLARE @CodeAfter nvarchar(400) = @CategoryCode;
    EXEC canon.SaveCategoryTranslations @CategoryTreeCode, @CodeAfter OUTPUT, @TranslationsJson, @Actor;
    SET @CategoryCode = @CodeAfter;
  END;
  COMMIT TRANSACTION;
END');

/* --- Dokaz ------------------------------------------------------------------------------- */
IF OBJECT_DEFINITION(OBJECT_ID(N'canon.SaveCategory')) NOT LIKE N'%@TranslationsJson%'
  THROW 52371, N'237: canon.SaveCategory ne sprejme imen po jezikih.', 1;
IF OBJECT_ID(N'canon.SaveCategoryTranslations', N'P') IS NULL
  THROW 52372, N'237: canon.SaveCategoryTranslations (223) manjka.', 1;
