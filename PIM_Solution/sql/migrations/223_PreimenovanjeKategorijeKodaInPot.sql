/*
  223 — preimenovanje kategorije (SL naziv) posodobi tudi kodo in pot, ne samo prevod.

  Uporabnik na strani "Kategorije": ko v zavihku "Prevodi" spremenis slovensko ime kategorije in
  shranis, se v desnem podrobnostnem panelu koda (@Selected.CategoryCode) in pot z ">" locili
  (@Selected.CategoryPath) NE spremenita - ostaneta pri starem imenu. Primer iz seje: kategorija
  "LED sijalke E27" preimenovana v "Sijalke E27"; koda je ostala
  "razsvetljava___sijalke___led_sijalke_e27", pot "Razsvetljava > Sijalke > LED sijalke E27".

  Vzrok: canon.SaveCategoryTranslations (113) pise SAMO v canon.CategoryTranslation (prevod po
  jeziku). canon.Category.CategoryName/CategoryCode/CategoryPath - slovenski "master" zapis, iz
  katerega SaveCategory (178) ob nastanku izpelje kodo in pot - se po nastanku nikoli ne
  posodobi. Otroske kode/poti fizicno vsebujejo starsevo kodo/pot kot predpono (078/178:
  koda = starsevaKoda + "___" + slug, pot = starsevaPot + " > " + ime), zato je treba ob
  preimenovanju prepisati CELO PODVEJO, ne le enega vozlisca.

  Ta migracija razsiri canon.SaveCategoryTranslations: ce vhod vsebuje jezik "sl" z drugacnim
  imenom, kot ga trenutno nosi canon.Category:
    1. Vedno (tudi ce se slug/koda ne spremeni, npr. samo velikost crk): posodobi CategoryName
       vozlisca in CategoryPath vozlisca + vseh potomcev (predpona zamenjana).
    2. Ce se izracunana koda spremeni: preveri podvajanje (enako pravilo kot pri ustvarjanju,
       51781/51782 v 178) in prepise CategoryCode vozlisca + vseh potomcev, ter vse tabele, ki
       kodo hranijo kot besedilo ali FK: canon.CategoryTranslation(History),
       canon.CategoryAttributeSet (FK_CategoryAttributeSet_Category - brez tega bi UPDATE padel
       na FK), map.CategoryPathMap(History), val.FieldRequirement.
    3. canon.ProductCategory / pim.ProductCategory / pim.ProductCategoryOverride hranijo uvrstitev
       izdelka po CategoryPath BESEDILU (ne po kodi - ni FK, glej 006/109), zato se stare vrstice s
       potjo skozi preimenovano vozlisce prestavijo na novo pot (izbrisi+vstavi, da ne podvoji ob
       morebitnem trku); to velja samo za jezik, v katerem je bila uvrstitev zapisana z isto potjo
       kot slovenska (v praksi B2C/sl) - poti v drugih jezikih gradi CategoryPathTranslated iz
       SVOJEGA prevoda in se s to spremembo ne premaknejo.

  Izhodisce vedno ostane @CategoryCode (parameter): ce se preimenuje, ga procedura interno prestavi
  na novo kodo, zato spodnji, nespremenjeni del (revizija prevodov + MERGE) dela na pravem vozliscu.
  Parameter @CategoryCode je zdaj OUTPUT, da klicatelj (CategoryTreeService.SaveTranslationsAsync)
  izve koncno kodo in lahko po ponovnem nalaganju drevesa spet izbere isto vozlisce - drugace bi
  izbira po preimenovanju izginila (stara koda v seznamu ne obstaja vec).

  Ce sl v vhodu ni ali se ujema s trenutnim imenom, se obnasanje ne spremeni.
*/

SET XACT_ABORT ON;

EXEC(N'
CREATE OR ALTER PROCEDURE canon.SaveCategoryTranslations
  @CategoryTreeCode nvarchar(100),
  @CategoryCode nvarchar(400) OUTPUT,
  @TranslationsJson nvarchar(max),   /* [{"lang":"en","name":"Interior lighting"}, ...] */
  @Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  IF NULLIF(LTRIM(RTRIM(@Actor)), N'''') IS NULL
    THROW 113001, N''Akter je obvezen: brez njega sprememba nima lastnika.'', 1;

  DECLARE @CategoryCodeOld nvarchar(400) = @CategoryCode;
  DECLARE @OldName nvarchar(400), @OldPath nvarchar(1000), @ParentCode nvarchar(200);
  SELECT @OldName = CategoryName, @OldPath = CategoryPath, @ParentCode = ParentCategoryCode
  FROM canon.Category
  WHERE CategoryTreeCode = @CategoryTreeCode AND CategoryCode = @CategoryCodeOld AND IsActive = 1;
  IF @OldPath IS NULL
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

  BEGIN TRANSACTION;

  /* --- Slovenski naziv je master: koda in pot (vozlisce + cela podveja) mu sledita ----------- */
  DECLARE @NewSlName nvarchar(400) = (SELECT TOP (1) CategoryName FROM @Vhod WHERE LanguageCode = N''sl'');
  IF @NewSlName IS NOT NULL AND @NewSlName <> @OldName
  BEGIN
    DECLARE @ParentPath nvarchar(1000) = NULL;
    IF @ParentCode IS NOT NULL
      SELECT @ParentPath = CategoryPath FROM canon.Category WHERE CategoryTreeCode = @CategoryTreeCode AND CategoryCode = @ParentCode;

    DECLARE @Slug nvarchar(200) = canon.CategoryCodeFromName(@NewSlName);
    IF NULLIF(@Slug, N'''') IS NULL THROW 223001, N''Iz imena ni mogoce narediti kode kategorije.'', 1;
    DECLARE @NewCode nvarchar(200) = CASE WHEN @ParentCode IS NULL THEN @Slug ELSE CONCAT(@ParentCode, N''___'', @Slug) END;
    DECLARE @NewPath nvarchar(1000) = CASE WHEN @ParentPath IS NULL THEN @NewSlName ELSE CONCAT(@ParentPath, N'' > '', @NewSlName) END;

    /* Podvajanje pod istim starsem - enako pravilo kot pri ustvarjanju (178/51781). */
    DECLARE @Existing nvarchar(400) =
      (SELECT TOP (1) CategoryName FROM canon.Category
       WHERE CategoryTreeCode = @CategoryTreeCode AND CategoryCode <> @CategoryCodeOld
         AND ((@ParentCode IS NULL AND ParentCategoryCode IS NULL) OR ParentCategoryCode = @ParentCode)
         AND canon.CategoryCodeFromName(CategoryName) = @Slug);
    IF @Existing IS NOT NULL
    BEGIN
      DECLARE @DuplicateMessage nvarchar(1000) = CONCAT(N''Pod isto nadrejeno kategorijo ze obstaja "'', @Existing, N''" — preimenovanje bi podvojilo ime.'');
      THROW 223002, @DuplicateMessage, 1;
    END;
    IF @NewCode <> @CategoryCodeOld AND EXISTS (SELECT 1 FROM canon.Category WHERE CategoryTreeCode = @CategoryTreeCode AND CategoryCode = @NewCode)
      THROW 223003, N''Koda kategorije, ki bi nastala iz novega imena, ze obstaja v tem drevesu.'', 1;

    /* Vozlisce + vsi potomci: stara predpona kode/poti se zamenja z novo (predpona je zajamcena, glej 178/059). */
    DECLARE @Preimenovani TABLE(StaraKoda nvarchar(200) NOT NULL PRIMARY KEY, NovaKoda nvarchar(200) NOT NULL, StaraPot nvarchar(1000) NOT NULL, NovaPot nvarchar(1000) NOT NULL);
    INSERT @Preimenovani(StaraKoda, NovaKoda, StaraPot, NovaPot)
    SELECT c.CategoryCode,
           @NewCode + SUBSTRING(c.CategoryCode, LEN(@CategoryCodeOld) + 1, 4000),
           c.CategoryPath,
           @NewPath + SUBSTRING(c.CategoryPath, LEN(@OldPath) + 1, 4000)
    FROM canon.Category c
    WHERE c.CategoryTreeCode = @CategoryTreeCode
      AND (c.CategoryCode = @CategoryCodeOld OR c.CategoryPath LIKE @OldPath + N'' > %'');

    /*
      FK_CategoryAttributeSet_Category kaze na canon.Category(CategoryTreeCode, CategoryCode).
      Med spodnjima dvema UPDATE stavkoma (Category dobi novo kodo, CategoryAttributeSet je se na
      stari) bi SQL Server takoj po prvem UPDATE javil krsitev FK (izmerjeno: Msg 547 na kategoriji
      z ze dodeljenim naborom atributov, npr. "Sijalke"). Znotraj ene transakcije je zato treba
      preverjanje za trenutek izklopiti in ga takoj po obeh UPDATE nazaj vklopiti WITH CHECK, da se
      obstojeci podatki - zdaj spet skladni - ponovno potrdijo.
    */
    ALTER TABLE canon.CategoryAttributeSet NOCHECK CONSTRAINT FK_CategoryAttributeSet_Category;

    UPDATE c
      SET CategoryCode = p.NovaKoda,
          CategoryPath = p.NovaPot,
          ParentCategoryCode = COALESCE(pp.NovaKoda, c.ParentCategoryCode),
          CategoryName = CASE WHEN c.CategoryCode = @CategoryCodeOld THEN @NewSlName ELSE c.CategoryName END
    FROM canon.Category c
    INNER JOIN @Preimenovani p ON p.StaraKoda = c.CategoryCode
    LEFT JOIN @Preimenovani pp ON pp.StaraKoda = c.ParentCategoryCode
    WHERE c.CategoryTreeCode = @CategoryTreeCode;

    UPDATE t SET CategoryCode = p.NovaKoda
    FROM canon.CategoryTranslation t INNER JOIN @Preimenovani p ON p.StaraKoda = t.CategoryCode
    WHERE t.CategoryTreeCode = @CategoryTreeCode AND p.StaraKoda <> p.NovaKoda;

    UPDATE h SET CategoryCode = p.NovaKoda
    FROM canon.CategoryTranslationHistory h INNER JOIN @Preimenovani p ON p.StaraKoda = h.CategoryCode
    WHERE h.CategoryTreeCode = @CategoryTreeCode AND p.StaraKoda <> p.NovaKoda;

    UPDATE a SET CategoryCode = p.NovaKoda
    FROM canon.CategoryAttributeSet a INNER JOIN @Preimenovani p ON p.StaraKoda = a.CategoryCode
    WHERE a.CategoryTreeCode = @CategoryTreeCode AND p.StaraKoda <> p.NovaKoda;

    ALTER TABLE canon.CategoryAttributeSet WITH CHECK CHECK CONSTRAINT FK_CategoryAttributeSet_Category;

    INSERT map.CategoryPathMapHistory (SourceCode, CategoryTreeCode, SourcePathKey, OldCategoryCode, NewCategoryCode, OldIsActive, NewIsActive, ChangedBy, Note)
    SELECT m.SourceCode, m.CategoryTreeCode, m.SourcePathKey, m.CategoryCode, p.NovaKoda, m.IsActive, m.IsActive, @Actor, N''preimenovanje kategorije (223)''
    FROM map.CategoryPathMap m INNER JOIN @Preimenovani p ON p.StaraKoda = m.CategoryCode
    WHERE m.CategoryTreeCode = @CategoryTreeCode AND p.StaraKoda <> p.NovaKoda;

    UPDATE m SET CategoryCode = p.NovaKoda, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = @Actor
    FROM map.CategoryPathMap m INNER JOIN @Preimenovani p ON p.StaraKoda = m.CategoryCode
    WHERE m.CategoryTreeCode = @CategoryTreeCode AND p.StaraKoda <> p.NovaKoda;

    UPDATE f SET CategoryCode = p.NovaKoda
    FROM val.FieldRequirement f INNER JOIN @Preimenovani p ON p.StaraKoda = f.CategoryCode
    WHERE f.CategoryTreeCode = @CategoryTreeCode AND p.StaraKoda <> p.NovaKoda;

    /* Uvrstitve izdelkov: pot je shranjena kot besedilo (brez FK, 006/109), zato se prepise rocno. */
    DECLARE @PotCanon TABLE(ProductId bigint NOT NULL, WebSite nvarchar(100) NOT NULL, NovaPot nvarchar(1000) NOT NULL, PRIMARY KEY (ProductId, WebSite));
    INSERT @PotCanon(ProductId, WebSite, NovaPot)
    SELECT DISTINCT pc.ProductId, pc.WebSite, p.NovaPot
    FROM canon.ProductCategory pc INNER JOIN @Preimenovani p ON p.StaraPot = pc.CategoryPath;
    DELETE pc FROM canon.ProductCategory pc INNER JOIN @PotCanon u ON u.ProductId = pc.ProductId AND u.WebSite = pc.WebSite;
    INSERT canon.ProductCategory (ProductId, WebSite, CategoryPath)
    SELECT u.ProductId, u.WebSite, u.NovaPot FROM @PotCanon u
    WHERE NOT EXISTS (SELECT 1 FROM canon.ProductCategory t WHERE t.ProductId = u.ProductId AND t.WebSite = u.WebSite AND t.CategoryPath = u.NovaPot);

    DECLARE @PotPim TABLE(PimProductId bigint NOT NULL, WebSite nvarchar(100) NOT NULL, NovaPot nvarchar(1000) NOT NULL, PRIMARY KEY (PimProductId, WebSite));
    INSERT @PotPim(PimProductId, WebSite, NovaPot)
    SELECT DISTINCT pc.PimProductId, pc.WebSite, p.NovaPot
    FROM pim.ProductCategory pc INNER JOIN @Preimenovani p ON p.StaraPot = pc.CategoryPath;
    DELETE pc FROM pim.ProductCategory pc INNER JOIN @PotPim u ON u.PimProductId = pc.PimProductId AND u.WebSite = pc.WebSite;
    INSERT pim.ProductCategory (PimProductId, WebSite, CategoryPath)
    SELECT u.PimProductId, u.WebSite, u.NovaPot FROM @PotPim u
    WHERE NOT EXISTS (SELECT 1 FROM pim.ProductCategory t WHERE t.PimProductId = u.PimProductId AND t.WebSite = u.WebSite AND t.CategoryPath = u.NovaPot);

    /* Rocna uvrstitev (pim.ProductCategoryOverride) ima prednost pred izracunano (109) - ce ostane na stari poti, jo prekrije in preimenovanje navzven ne bi ucinkovalo. */
    DECLARE @PotOverride TABLE(ProductId bigint NOT NULL, WebSite nvarchar(100) NOT NULL, OrganizationId int NOT NULL, NovaPot nvarchar(1000) NOT NULL, Note nvarchar(600) NULL, PRIMARY KEY (ProductId, WebSite));
    INSERT @PotOverride(ProductId, WebSite, OrganizationId, NovaPot, Note)
    SELECT DISTINCT o.ProductId, o.WebSite, o.OrganizationId, p.NovaPot, o.Note
    FROM pim.ProductCategoryOverride o INNER JOIN @Preimenovani p ON p.StaraPot = o.CategoryPath;
    DELETE o FROM pim.ProductCategoryOverride o INNER JOIN @PotOverride u ON u.ProductId = o.ProductId AND u.WebSite = o.WebSite;
    INSERT pim.ProductCategoryOverride (OrganizationId, ProductId, WebSite, CategoryPath, SetBy, Note)
    SELECT u.OrganizationId, u.ProductId, u.WebSite, u.NovaPot, @Actor, u.Note FROM @PotOverride u
    WHERE NOT EXISTS (SELECT 1 FROM pim.ProductCategoryOverride t WHERE t.ProductId = u.ProductId AND t.WebSite = u.WebSite AND t.CategoryPath = u.NovaPot);

    SET @CategoryCode = @NewCode;
  END;

  /*
    Ce en jezik pade na pravilu, ne obvelja noben. Delno shranjen prevod izgleda opravljen in
    ga nihce ne pregleda znova. Deluje na @CategoryCode, ki je zdaj morebiti ze preimenovan zgoraj.
  */
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
