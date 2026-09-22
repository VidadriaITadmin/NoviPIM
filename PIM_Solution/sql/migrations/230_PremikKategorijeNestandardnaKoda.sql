/*
  230 — 229 je predpostavljala, da je CategoryCode VEDNO starsevaKoda + "___" + slug; napacno za
  zrcaljeno vejo "Razsvetljava" v drevesu videlektro.

  Uporabnik je ob testiranju 229 v UI naletel na pravo SQL napako (ne na lepo sporocilo):
  "Violation of UNIQUE KEY constraint 'UQ_Category_TreeCode' ... duplicate key value is
  (videlektro, razsvetljava___xxx)". Vzrok: migracija 092 (VidelektroCategoryTree) je pod korenom
  "videlektro"/"razsvetljava" zrcalila CELO drevo svetila_si tako, da je OBDRZALA IDENTICNE kode
  (npr. "cameleon_sistem", "tracni_sistemi", "tracni_sistemi___1_fazni_24v_nano_lvm"), ceprav je
  ParentCategoryCode preusmerjen v videlektro hierarhijo (npr. "cameleon_sistem" ima
  ParentCategoryCode = "razsvetljava", ne "razsvetljava___cameleon_sistem"). Preverjeno na
  DAVID\MSSQL19:

    SELECT CategoryTreeCode, CategoryCode, ParentCategoryCode FROM canon.Category
    WHERE ParentCategoryCode IS NOT NULL AND CategoryCode NOT LIKE ParentCategoryCode + '___%';

  vrne 11 vrstic, vse pod videlektro/razsvetljava (cameleon_sistem, notranja_svetila, prostor,
  svetlobni_viri_in_dodatki, tracni_sistemi, zunanja_svetila in 5 otrok "tracni_sistemi").

  229 je OwnCodeSlug racunala kot SUBSTRING(CategoryCode, LEN(ParentCategoryCode) + 4, 200) - za te
  vrstice to vrne prazen niz ali smetje (predpona starsa fizicno ne obstaja v kodi), @Affected pa je
  isto naredila za VSE potomce premaknjenega poddrevesa preko SUBSTRING(node.CategoryCode,
  LEN(root.CategoryCode) + 1, ...) - ce en sam potomec krsi predpostavko "moja koda se zacne s kodo
  korena", dobi popolnoma nepovezano novo kodo, ki lahko trci ob obstojeco kategorijo (natanko to se
  je zgodilo: nekdo je premikal vejo, katere izracunana nova koda je pomotoma pristala na
  "razsvetljava___xxx", ki je pod Razsvetljavo ze obstajala).

  Popravek: canon.MoveCategories za vsako korensko vejo preveri, ali PREDPOSTAVKA "koda = stars +
  ___ + slug" drzi za CELO poddrevo (koren glede na svojega dejanskega starsa IN vsak potomec glede
  na kodo korena kot dobesedno predpono). Ce ne drzi (CodeIsWellFormed = 0), se za to vejo (koren +
  vsi njeni potomci) koda NE spremeni - obnasanje se za to vejo vrne na prvotno 228 ("koda ostane
  stabilna"), ParentCategoryCode/LevelNo/CategoryPath pa se posodobijo kot prej. Za vse ostale,
  standardno kodirane veje (velika vecina drevesa) ostane popravek iz 229 v celoti veljaven. Obstojeci
  varovali 229001/229002 (predolga/podvojena nova koda) ostaneta nespremenjeni - ker je za
  nestandardno vejo NewRootCode zdaj enak stari CategoryCode, ju ne moreta vec sprozila po nepotrebnem.

  Kot pri 229: canon.GetCategoryChangeImpact in canon.DeleteCategories se ne spremenita.
*/

SET XACT_ABORT ON;

EXEC(N'
CREATE OR ALTER PROCEDURE canon.MoveCategories
  @CategoriesJson nvarchar(max),
  @TargetCategoryTreeCode nvarchar(50),
  @TargetParentCategoryCode nvarchar(200) = NULL, /* NULL = koren drevesa */
  @Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  SET @Actor = NULLIF(LTRIM(RTRIM(@Actor)), N'''');
  SET @TargetCategoryTreeCode = NULLIF(LTRIM(RTRIM(@TargetCategoryTreeCode)), N'''');
  SET @TargetParentCategoryCode = NULLIF(LTRIM(RTRIM(@TargetParentCategoryCode)), N'''');
  IF @Actor IS NULL THROW 228010, N''Akter je obvezen.'', 1;
  IF @TargetCategoryTreeCode IS NULL THROW 228011, N''Ciljno drevo je obvezno.'', 1;
  IF ISJSON(@CategoriesJson) <> 1 THROW 228012, N''Izbor kategorij ni veljaven.'', 1;

  DECLARE @Selected TABLE
  (
    CategoryTreeCode nvarchar(50) NOT NULL,
    CategoryCode nvarchar(200) NOT NULL,
    PRIMARY KEY (CategoryTreeCode, CategoryCode)
  );
  INSERT @Selected(CategoryTreeCode, CategoryCode)
  SELECT DISTINCT LTRIM(RTRIM(j.CategoryTreeCode)), LTRIM(RTRIM(j.CategoryCode))
  FROM OPENJSON(@CategoriesJson)
  WITH (CategoryTreeCode nvarchar(50) N''$.tree'', CategoryCode nvarchar(200) N''$.code'') AS j
  WHERE NULLIF(LTRIM(RTRIM(j.CategoryTreeCode)), N'''') IS NOT NULL
    AND NULLIF(LTRIM(RTRIM(j.CategoryCode)), N'''') IS NOT NULL;
  IF NOT EXISTS (SELECT 1 FROM @Selected) THROW 228013, N''Izberi vsaj eno kategorijo.'', 1;
  IF EXISTS (SELECT 1 FROM @Selected WHERE CategoryTreeCode <> @TargetCategoryTreeCode)
    THROW 228014, N''Kategorije je mogoce premikati samo znotraj istega drevesa.'', 1;

  BEGIN TRANSACTION;

  /* Zaklep prepreči, da bi se med preverjanjem in zapisom veja spremenila v drugem oknu. */
  DECLARE @LockedSelected int;
  SELECT @LockedSelected = COUNT(*)
  FROM canon.Category AS node WITH (UPDLOCK, HOLDLOCK)
  INNER JOIN @Selected AS selected
    ON selected.CategoryTreeCode = node.CategoryTreeCode AND selected.CategoryCode = node.CategoryCode;

  IF (SELECT COUNT(*) FROM @Selected) <> @LockedSelected
    THROW 228015, N''Ena od izbranih kategorij ne obstaja vec. Osvezi stran.'', 1;

  DECLARE @TargetPath nvarchar(1000) = NULL, @TargetLevel int = 0;
  IF @TargetParentCategoryCode IS NOT NULL
  BEGIN
    SELECT @TargetPath = CategoryPath, @TargetLevel = LevelNo
    FROM canon.Category WITH (UPDLOCK, HOLDLOCK)
    WHERE CategoryTreeCode = @TargetCategoryTreeCode
      AND CategoryCode = @TargetParentCategoryCode AND IsActive = 1;
    IF @TargetPath IS NULL THROW 228016, N''Ciljna kategorija ne obstaja ali ni aktivna.'', 1;
  END;

  DECLARE @Roots TABLE
  (
    CategoryTreeCode nvarchar(50) NOT NULL,
    CategoryCode nvarchar(200) NOT NULL,
    ParentCategoryCode nvarchar(200) NULL,
    LevelNo int NOT NULL,
    CategoryName nvarchar(400) NOT NULL,
    CategoryPath nvarchar(1000) NOT NULL,
    NewRootPath nvarchar(1000) NULL,
    CodeIsWellFormed bit NULL,
    OwnCodeSlug nvarchar(200) NULL,
    NewRootCode nvarchar(200) NULL,
    PRIMARY KEY (CategoryTreeCode, CategoryCode)
  );
  INSERT @Roots(CategoryTreeCode, CategoryCode, ParentCategoryCode, LevelNo, CategoryName, CategoryPath)
  SELECT node.CategoryTreeCode, node.CategoryCode, node.ParentCategoryCode,
         node.LevelNo, node.CategoryName, node.CategoryPath
  FROM canon.Category AS node
  INNER JOIN @Selected AS selected
    ON selected.CategoryTreeCode = node.CategoryTreeCode AND selected.CategoryCode = node.CategoryCode
  WHERE NOT EXISTS
  (
    SELECT 1
    FROM canon.Category AS ancestor
    INNER JOIN @Selected AS selectedAncestor
      ON selectedAncestor.CategoryTreeCode = ancestor.CategoryTreeCode
     AND selectedAncestor.CategoryCode = ancestor.CategoryCode
    WHERE ancestor.CategoryTreeCode = node.CategoryTreeCode
      AND node.CategoryPath LIKE ancestor.CategoryPath + N'' > %''
  );

  IF EXISTS (SELECT 1 FROM @Roots WHERE CategoryCode = @TargetParentCategoryCode)
    THROW 228017, N''Kategorije ni mogoce premakniti same vase.'', 1;
  IF EXISTS
  (
    SELECT 1 FROM @Roots AS root
    WHERE @TargetPath LIKE root.CategoryPath + N'' > %''
  )
    THROW 228018, N''Kategorije ni mogoce premakniti v lastno podkategorijo.'', 1;
  IF NOT EXISTS
  (
    SELECT 1 FROM @Roots
    WHERE ISNULL(ParentCategoryCode, N'''') <> ISNULL(@TargetParentCategoryCode, N'''')
  )
    THROW 228019, N''Izbrane kategorije so ze na tem mestu.'', 1;

  /* Dve enako poimenovani veji pod istim novim starsem bi bili nerazlocljivi. */
  IF EXISTS
  (
    SELECT canon.CategoryCodeFromName(CategoryName)
    FROM @Roots GROUP BY canon.CategoryCodeFromName(CategoryName) HAVING COUNT(*) > 1
  )
    THROW 228020, N''Med izbranimi vejami sta dve z enakim imenom; pod istega starsa ju ni mogoce premakniti.'', 1;
  IF EXISTS
  (
    SELECT 1
    FROM @Roots AS root
    INNER JOIN canon.Category AS sibling
      ON sibling.CategoryTreeCode = @TargetCategoryTreeCode
     AND ((@TargetParentCategoryCode IS NULL AND sibling.ParentCategoryCode IS NULL)
       OR sibling.ParentCategoryCode = @TargetParentCategoryCode)
     AND sibling.CategoryCode <> root.CategoryCode
     AND canon.CategoryCodeFromName(sibling.CategoryName) = canon.CategoryCodeFromName(root.CategoryName)
    WHERE NOT EXISTS (SELECT 1 FROM @Roots AS moved WHERE moved.CategoryCode = sibling.CategoryCode)
  )
    THROW 228021, N''Na cilju ze obstaja kategorija z enakim imenom.'', 1;

  UPDATE @Roots
    SET NewRootPath = CASE WHEN @TargetPath IS NULL THEN CategoryName ELSE CONCAT(@TargetPath, N'' > '', CategoryName) END;
  IF EXISTS (SELECT 1 FROM @Roots WHERE LEN(NewRootPath) > 1000)
    THROW 228022, N''Nova pot kategorije je predolga.'', 1;

  /*
    Koda je NAVADNO stars + "___" + lastni slug (078/178) - a ne vedno: zrcaljena veja Razsvetljava
    (092, drevo videlektro) je obdrzala kode iz svetila_si brez preprefiksanja. Predpostavko zato
    preverimo za CELO poddrevo (koren glede na svojega dejanskega starsa, vsak potomec glede na kodo
    korena kot dobesedno predpono); ce kje ne drzi, koda za CELO to vejo ostane nespremenjena (230).
  */
  UPDATE r
    SET CodeIsWellFormed = CASE
      WHEN r.ParentCategoryCode IS NOT NULL AND r.CategoryCode NOT LIKE r.ParentCategoryCode + N''___%'' THEN 0
      WHEN EXISTS
      (
        SELECT 1 FROM canon.Category AS descendant
        WHERE descendant.CategoryTreeCode = r.CategoryTreeCode
          AND descendant.CategoryPath LIKE r.CategoryPath + N'' > %''
          AND LEFT(descendant.CategoryCode, LEN(r.CategoryCode)) <> r.CategoryCode
      ) THEN 0
      ELSE 1
    END
  FROM @Roots AS r;

  UPDATE @Roots
    SET OwnCodeSlug = CASE
      WHEN ParentCategoryCode IS NULL THEN CategoryCode
      ELSE SUBSTRING(CategoryCode, LEN(ParentCategoryCode) + 4, 200)
    END;
  UPDATE @Roots
    SET NewRootCode = CASE
      WHEN CodeIsWellFormed = 0 THEN CategoryCode
      WHEN @TargetParentCategoryCode IS NULL THEN OwnCodeSlug
      ELSE CONCAT(@TargetParentCategoryCode, N''___'', OwnCodeSlug)
    END;
  IF EXISTS (SELECT 1 FROM @Roots WHERE LEN(NewRootCode) > 200)
    THROW 229001, N''Nova koda kategorije je predolga.'', 1;
  IF EXISTS
  (
    SELECT 1 FROM @Roots AS root
    WHERE root.NewRootCode <> root.CategoryCode
      AND EXISTS
      (
        SELECT 1 FROM canon.Category AS existing
        WHERE existing.CategoryTreeCode = @TargetCategoryTreeCode
          AND existing.CategoryCode = root.NewRootCode
          AND NOT EXISTS (SELECT 1 FROM @Roots AS moved WHERE moved.CategoryCode = existing.CategoryCode)
      )
  )
    THROW 229002, N''Koda kategorije, ki bi nastala s premikom, v tem drevesu ze obstaja.'', 1;

  DECLARE @Affected TABLE
  (
    CategoryTreeCode nvarchar(50) NOT NULL,
    CategoryCode nvarchar(200) NOT NULL,
    MoveRootCode nvarchar(200) NOT NULL,
    OldPath nvarchar(1000) NOT NULL,
    NewPath nvarchar(1000) NOT NULL,
    NewCode nvarchar(200) NOT NULL,
    OldLevel int NOT NULL,
    NewLevel int NOT NULL,
    PRIMARY KEY (CategoryTreeCode, CategoryCode)
  );
  INSERT @Affected(CategoryTreeCode, CategoryCode, MoveRootCode, OldPath, NewPath, NewCode, OldLevel, NewLevel)
  SELECT node.CategoryTreeCode, node.CategoryCode, root.CategoryCode, node.CategoryPath,
         root.NewRootPath + SUBSTRING(node.CategoryPath, LEN(root.CategoryPath) + 1, 4000),
         CASE WHEN root.CodeIsWellFormed = 1
           THEN root.NewRootCode + SUBSTRING(node.CategoryCode, LEN(root.CategoryCode) + 1, 4000)
           ELSE node.CategoryCode
         END,
         node.LevelNo, node.LevelNo + ((@TargetLevel + 1) - root.LevelNo)
  FROM canon.Category AS node
  INNER JOIN @Roots AS root
    ON root.CategoryTreeCode = node.CategoryTreeCode
   AND (node.CategoryCode = root.CategoryCode OR node.CategoryPath LIKE root.CategoryPath + N'' > %'');

  IF EXISTS (SELECT 1 FROM @Affected WHERE LEN(NewPath) > 1000)
    THROW 228023, N''Ena od novih poti v poddrevesu je predolga.'', 1;
  IF EXISTS (SELECT 1 FROM @Affected WHERE NewLevel > 12)
    THROW 228024, N''Premik bi ustvaril vec kot 12 nivojev kategorij.'', 1;

  DECLARE @MovedPaths TABLE
  (
    CategoryTreeCode nvarchar(50) NOT NULL,
    CategoryCode nvarchar(200) NOT NULL,
    NewCode nvarchar(200) NOT NULL,
    WebSite nvarchar(100) NOT NULL,
    OldPath nvarchar(1000) NOT NULL,
    NewPath nvarchar(1000) NULL,
    PRIMARY KEY (CategoryTreeCode, CategoryCode, WebSite)
  );
  INSERT @MovedPaths(CategoryTreeCode, CategoryCode, NewCode, WebSite, OldPath)
  SELECT translated.CategoryTreeCode, translated.CategoryCode, affected.NewCode, website.WebSiteCode, translated.CategoryPath
  FROM canon.CategoryPathTranslated AS translated
  INNER JOIN canon.WebSite AS website
    ON website.CategoryTreeCode = translated.CategoryTreeCode
   AND website.LanguageCode = translated.LanguageCode
   AND website.IsActive = 1
  INNER JOIN @Affected AS affected
    ON affected.CategoryTreeCode = translated.CategoryTreeCode
   AND affected.CategoryCode = translated.CategoryCode;

  INSERT canon.CategoryChangeHistory
    (Operation, CategoryTreeCode, CategoryCode, CategoryName, OldParentCategoryCode,
     NewParentCategoryCode, OldCategoryPath, NewCategoryPath, ChangedBy)
  SELECT N''MOVE'', root.CategoryTreeCode, root.CategoryCode, root.CategoryName,
         root.ParentCategoryCode, @TargetParentCategoryCode, root.CategoryPath, root.NewRootPath, @Actor
  FROM @Roots AS root;

  /*
    FK_CategoryAttributeSet_Category kaze na canon.Category(CategoryTreeCode, CategoryCode). Med
    spodnjima dvema UPDATE (Category dobi novo kodo, CategoryAttributeSet je se na stari) bi SQL
    Server takoj javil krsitev FK - enak ovinek kot 223.
  */
  ALTER TABLE canon.CategoryAttributeSet NOCHECK CONSTRAINT FK_CategoryAttributeSet_Category;

  UPDATE node
    SET ParentCategoryCode = CASE WHEN root.CategoryCode IS NOT NULL THEN @TargetParentCategoryCode ELSE parentMap.NewCode END,
        LevelNo = affected.NewLevel,
        CategoryPath = affected.NewPath,
        CategoryCode = affected.NewCode
  FROM canon.Category AS node
  INNER JOIN @Affected AS affected
    ON affected.CategoryTreeCode = node.CategoryTreeCode AND affected.CategoryCode = node.CategoryCode
  LEFT JOIN @Roots AS root
    ON root.CategoryTreeCode = node.CategoryTreeCode AND root.CategoryCode = node.CategoryCode
  LEFT JOIN @Affected AS parentMap
    ON parentMap.CategoryTreeCode = node.CategoryTreeCode AND parentMap.CategoryCode = node.ParentCategoryCode;

  UPDATE t SET CategoryCode = affected.NewCode
  FROM canon.CategoryTranslation t INNER JOIN @Affected affected
    ON affected.CategoryTreeCode = t.CategoryTreeCode AND affected.CategoryCode = t.CategoryCode
  WHERE affected.CategoryCode <> affected.NewCode;

  UPDATE h SET CategoryCode = affected.NewCode
  FROM canon.CategoryTranslationHistory h INNER JOIN @Affected affected
    ON affected.CategoryTreeCode = h.CategoryTreeCode AND affected.CategoryCode = h.CategoryCode
  WHERE affected.CategoryCode <> affected.NewCode;

  UPDATE a SET CategoryCode = affected.NewCode
  FROM canon.CategoryAttributeSet a INNER JOIN @Affected affected
    ON affected.CategoryTreeCode = a.CategoryTreeCode AND affected.CategoryCode = a.CategoryCode
  WHERE affected.CategoryCode <> affected.NewCode;

  ALTER TABLE canon.CategoryAttributeSet WITH CHECK CHECK CONSTRAINT FK_CategoryAttributeSet_Category;

  INSERT map.CategoryPathMapHistory (SourceCode, CategoryTreeCode, SourcePathKey, OldCategoryCode, NewCategoryCode, OldIsActive, NewIsActive, ChangedBy, Note)
  SELECT m.SourceCode, m.CategoryTreeCode, m.SourcePathKey, m.CategoryCode, affected.NewCode, m.IsActive, m.IsActive, @Actor, N''premik kategorije (229/230)''
  FROM map.CategoryPathMap m INNER JOIN @Affected affected
    ON affected.CategoryTreeCode = m.CategoryTreeCode AND affected.CategoryCode = m.CategoryCode
  WHERE affected.CategoryCode <> affected.NewCode;

  UPDATE m SET CategoryCode = affected.NewCode, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = @Actor
  FROM map.CategoryPathMap m INNER JOIN @Affected affected
    ON affected.CategoryTreeCode = m.CategoryTreeCode AND affected.CategoryCode = m.CategoryCode
  WHERE affected.CategoryCode <> affected.NewCode;

  UPDATE f SET CategoryCode = affected.NewCode
  FROM val.FieldRequirement f INNER JOIN @Affected affected
    ON affected.CategoryTreeCode = f.CategoryTreeCode AND affected.CategoryCode = f.CategoryCode
  WHERE affected.CategoryCode <> affected.NewCode;

  UPDATE tr SET CategoryCode = affected.NewCode
  FROM pim.TitleRule tr INNER JOIN @Affected affected
    ON affected.CategoryTreeCode = tr.CategoryTreeCode AND affected.CategoryCode = tr.CategoryCode
  WHERE affected.CategoryCode <> affected.NewCode;

  UPDATE moved
    SET NewPath = translated.CategoryPath
  FROM @MovedPaths AS moved
  INNER JOIN canon.WebSite AS website ON website.WebSiteCode = moved.WebSite
  INNER JOIN canon.CategoryPathTranslated AS translated
    ON translated.CategoryTreeCode = moved.CategoryTreeCode
   AND translated.CategoryCode = moved.NewCode
   AND translated.LanguageCode = website.LanguageCode;

  IF EXISTS (SELECT 1 FROM @MovedPaths WHERE NewPath IS NULL)
    THROW 228025, N''Ciljna veja nima vseh prevodov, potrebnih za aktivne spletne strani. Najprej dopolni prevode.'', 1;

  DECLARE @CanonMoved TABLE
    (ProductId bigint NOT NULL, WebSite nvarchar(100) NOT NULL, NewPath nvarchar(1000) NOT NULL,
     PRIMARY KEY(ProductId, WebSite, NewPath));
  INSERT @CanonMoved(ProductId, WebSite, NewPath)
  SELECT DISTINCT assignment.ProductId, assignment.WebSite, path.NewPath
  FROM canon.ProductCategory AS assignment
  INNER JOIN @MovedPaths AS path ON path.WebSite = assignment.WebSite AND path.OldPath = assignment.CategoryPath
  WHERE path.OldPath <> path.NewPath;
  DELETE assignment FROM canon.ProductCategory AS assignment
  INNER JOIN @MovedPaths AS path ON path.WebSite = assignment.WebSite AND path.OldPath = assignment.CategoryPath
  WHERE path.OldPath <> path.NewPath;
  INSERT canon.ProductCategory(ProductId, WebSite, CategoryPath)
  SELECT moved.ProductId, moved.WebSite, moved.NewPath FROM @CanonMoved AS moved
  WHERE NOT EXISTS
    (SELECT 1 FROM canon.ProductCategory AS existingAssignment
     WHERE existingAssignment.ProductId = moved.ProductId AND existingAssignment.WebSite = moved.WebSite AND existingAssignment.CategoryPath = moved.NewPath);

  DECLARE @PimMoved TABLE
    (PimProductId bigint NOT NULL, WebSite nvarchar(100) NOT NULL, NewPath nvarchar(1000) NOT NULL,
     PRIMARY KEY(PimProductId, WebSite, NewPath));
  INSERT @PimMoved(PimProductId, WebSite, NewPath)
  SELECT DISTINCT assignment.PimProductId, assignment.WebSite, path.NewPath
  FROM pim.ProductCategory AS assignment
  INNER JOIN @MovedPaths AS path ON path.WebSite = assignment.WebSite AND path.OldPath = assignment.CategoryPath
  WHERE path.OldPath <> path.NewPath;
  DELETE assignment FROM pim.ProductCategory AS assignment
  INNER JOIN @MovedPaths AS path ON path.WebSite = assignment.WebSite AND path.OldPath = assignment.CategoryPath
  WHERE path.OldPath <> path.NewPath;
  INSERT pim.ProductCategory(PimProductId, WebSite, CategoryPath)
  SELECT moved.PimProductId, moved.WebSite, moved.NewPath FROM @PimMoved AS moved
  WHERE NOT EXISTS
    (SELECT 1 FROM pim.ProductCategory AS existingAssignment
     WHERE existingAssignment.PimProductId = moved.PimProductId AND existingAssignment.WebSite = moved.WebSite AND existingAssignment.CategoryPath = moved.NewPath);

  DECLARE @OverrideMoved TABLE
  (
    OrganizationId int NOT NULL, ProductId bigint NOT NULL, WebSite nvarchar(100) NOT NULL,
    NewPath nvarchar(1000) NOT NULL, Note nvarchar(600) NULL,
    PRIMARY KEY(ProductId, WebSite, NewPath)
  );
  INSERT @OverrideMoved(OrganizationId, ProductId, WebSite, NewPath, Note)
  SELECT assignment.OrganizationId, assignment.ProductId, assignment.WebSite, path.NewPath, assignment.Note
  FROM pim.ProductCategoryOverride AS assignment
  INNER JOIN @MovedPaths AS path ON path.WebSite = assignment.WebSite AND path.OldPath = assignment.CategoryPath
  WHERE path.OldPath <> path.NewPath;
  DELETE assignment FROM pim.ProductCategoryOverride AS assignment
  INNER JOIN @MovedPaths AS path ON path.WebSite = assignment.WebSite AND path.OldPath = assignment.CategoryPath
  WHERE path.OldPath <> path.NewPath;
  INSERT pim.ProductCategoryOverride(OrganizationId, ProductId, WebSite, CategoryPath, SetBy, Note)
  SELECT moved.OrganizationId, moved.ProductId, moved.WebSite, moved.NewPath, @Actor, moved.Note
  FROM @OverrideMoved AS moved
  WHERE NOT EXISTS
    (SELECT 1 FROM pim.ProductCategoryOverride AS existingAssignment
     WHERE existingAssignment.ProductId = moved.ProductId AND existingAssignment.WebSite = moved.WebSite AND existingAssignment.CategoryPath = moved.NewPath);

  DECLARE @RootCount int = (SELECT COUNT(*) FROM @Roots);
  DECLARE @CategoryCount int = (SELECT COUNT(*) FROM @Affected);
  DECLARE @AssignmentCount bigint =
    (SELECT COUNT_BIG(*) FROM @CanonMoved) + (SELECT COUNT_BIG(*) FROM @PimMoved) + (SELECT COUNT_BIG(*) FROM @OverrideMoved);

  COMMIT TRANSACTION;
  SELECT RootCount = @RootCount, CategoryCount = @CategoryCount, AssignmentCount = @AssignmentCount;
  SELECT CategoryTreeCode, OldCategoryCode = CategoryCode, NewCategoryCode = NewRootCode FROM @Roots;
END;
');
