/*
  228 — varno premikanje in trajno brisanje kategorij.

  Kategorija je stabilna entiteta: pri premiku se njena koda ne spremeni. Spremenijo se stars,
  nivo in pot celotnega poddrevesa. Tako ostanejo prevodi, nabori atributov, preslikave in pravila
  pripeti na isto kategorijo. Ker uvrstitve izdelkov hranijo pot kot besedilo, jih postopek v isti
  transakciji prestavi na novo pot v vsakem jeziku aktivne spletne strani.

  Brisanje je namerno trajno in zajame celo poddrevo. Pred klicem UI vedno poklice predogled vpliva;
  sam zapisovalni postopek pa vseeno znova sestavi obseg pod zaklepom in atomsko odstrani povezave,
  uvrstitve, pravila, prevode ter kategorije. Izdelkov ne brise — odstrani samo njihove uvrstitve v
  izbrisane kategorije. Vsaka premaknjena ali izbrisana kategorija ostane v revizijski zgodovini.
*/

SET XACT_ABORT ON;

IF OBJECT_ID(N'canon.CategoryChangeHistory', N'U') IS NULL
BEGIN
  CREATE TABLE canon.CategoryChangeHistory
  (
    CategoryChangeHistoryId bigint IDENTITY(1,1) NOT NULL
      CONSTRAINT PK_CategoryChangeHistory PRIMARY KEY,
    Operation nvarchar(20) NOT NULL,
    CategoryTreeCode nvarchar(50) NOT NULL,
    CategoryCode nvarchar(200) NOT NULL,
    CategoryName nvarchar(400) NOT NULL,
    OldParentCategoryCode nvarchar(200) NULL,
    NewParentCategoryCode nvarchar(200) NULL,
    OldCategoryPath nvarchar(1000) NOT NULL,
    NewCategoryPath nvarchar(1000) NULL,
    ChangedBy nvarchar(200) NOT NULL,
    ChangedUtc datetime2(7) NOT NULL
      CONSTRAINT DF_CategoryChangeHistory_ChangedUtc DEFAULT(SYSUTCDATETIME()),
    CONSTRAINT CK_CategoryChangeHistory_Operation CHECK (Operation IN (N'MOVE', N'DELETE'))
  );
  CREATE INDEX IX_CategoryChangeHistory_Category
    ON canon.CategoryChangeHistory(CategoryTreeCode, CategoryCode, ChangedUtc DESC);
END;

EXEC(N'
CREATE OR ALTER PROCEDURE canon.GetCategoryChangeImpact
  @CategoriesJson nvarchar(max) /* [{"tree":"svetila_si","code":"..."}, ...] */
AS
BEGIN
  SET NOCOUNT ON;

  IF ISJSON(@CategoriesJson) <> 1
    THROW 228001, N''Izbor kategorij ni veljaven.'', 1;

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

  IF NOT EXISTS (SELECT 1 FROM @Selected)
    THROW 228002, N''Izberi vsaj eno kategorijo.'', 1;

  DECLARE @Roots TABLE
  (
    CategoryTreeCode nvarchar(50) NOT NULL,
    CategoryCode nvarchar(200) NOT NULL,
    CategoryPath nvarchar(1000) NOT NULL,
    PRIMARY KEY (CategoryTreeCode, CategoryCode)
  );
  INSERT @Roots(CategoryTreeCode, CategoryCode, CategoryPath)
  SELECT node.CategoryTreeCode, node.CategoryCode, node.CategoryPath
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

  IF NOT EXISTS (SELECT 1 FROM @Roots)
    THROW 228003, N''Izbrane kategorije ne obstajajo vec. Osvezi stran.'', 1;

  DECLARE @Affected TABLE
  (
    CategoryTreeCode nvarchar(50) NOT NULL,
    CategoryCode nvarchar(200) NOT NULL,
    CategoryPath nvarchar(1000) NOT NULL,
    PRIMARY KEY (CategoryTreeCode, CategoryCode)
  );
  INSERT @Affected(CategoryTreeCode, CategoryCode, CategoryPath)
  SELECT DISTINCT node.CategoryTreeCode, node.CategoryCode, node.CategoryPath
  FROM canon.Category AS node
  INNER JOIN @Roots AS root
    ON root.CategoryTreeCode = node.CategoryTreeCode
   AND (node.CategoryCode = root.CategoryCode OR node.CategoryPath LIKE root.CategoryPath + N'' > %'');

  DECLARE @Paths TABLE
  (
    CategoryTreeCode nvarchar(50) NOT NULL,
    CategoryCode nvarchar(200) NOT NULL,
    WebSite nvarchar(100) NOT NULL,
    CategoryPath nvarchar(1000) NOT NULL,
    PRIMARY KEY (CategoryTreeCode, CategoryCode, WebSite)
  );
  INSERT @Paths(CategoryTreeCode, CategoryCode, WebSite, CategoryPath)
  SELECT translated.CategoryTreeCode, translated.CategoryCode, website.WebSiteCode, translated.CategoryPath
  FROM canon.CategoryPathTranslated AS translated
  INNER JOIN canon.WebSite AS website
    ON website.CategoryTreeCode = translated.CategoryTreeCode
   AND website.LanguageCode = translated.LanguageCode
   AND website.IsActive = 1
  INNER JOIN @Affected AS affected
    ON affected.CategoryTreeCode = translated.CategoryTreeCode
   AND affected.CategoryCode = translated.CategoryCode;

  SELECT
    SelectedCount = (SELECT COUNT_BIG(*) FROM @Selected),
    RootCount = (SELECT COUNT_BIG(*) FROM @Roots),
    CategoryCount = (SELECT COUNT_BIG(*) FROM @Affected),
    DescendantCount = (SELECT COUNT_BIG(*) FROM @Affected) - (SELECT COUNT_BIG(*) FROM @Roots),
    CanonProductAssignments =
      (SELECT COUNT_BIG(*) FROM canon.ProductCategory AS assignment
       INNER JOIN @Paths AS path ON path.WebSite = assignment.WebSite AND path.CategoryPath = assignment.CategoryPath),
    PimProductAssignments =
      (SELECT COUNT_BIG(*) FROM pim.ProductCategory AS assignment
       INNER JOIN @Paths AS path ON path.WebSite = assignment.WebSite AND path.CategoryPath = assignment.CategoryPath),
    OverrideAssignments =
      (SELECT COUNT_BIG(*) FROM pim.ProductCategoryOverride AS assignment
       INNER JOIN @Paths AS path ON path.WebSite = assignment.WebSite AND path.CategoryPath = assignment.CategoryPath),
    MappingCount =
      (SELECT COUNT_BIG(*) FROM map.CategoryPathMap AS mapping
       INNER JOIN @Affected AS affected ON affected.CategoryTreeCode = mapping.CategoryTreeCode AND affected.CategoryCode = mapping.CategoryCode),
    AttributeSetCount =
      (SELECT COUNT_BIG(*) FROM canon.CategoryAttributeSet AS attributeSet
       INNER JOIN @Affected AS affected ON affected.CategoryTreeCode = attributeSet.CategoryTreeCode AND affected.CategoryCode = attributeSet.CategoryCode),
    ValidationRuleCount =
      (SELECT COUNT_BIG(*) FROM val.FieldRequirement AS requirement
       INNER JOIN @Affected AS affected ON affected.CategoryTreeCode = requirement.CategoryTreeCode AND affected.CategoryCode = requirement.CategoryCode),
    TitleRuleCount =
      (SELECT COUNT_BIG(*) FROM pim.TitleRule AS titleRule
       INNER JOIN @Affected AS affected ON affected.CategoryTreeCode = titleRule.CategoryTreeCode AND affected.CategoryCode = titleRule.CategoryCode);
END;
');

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

  DECLARE @Affected TABLE
  (
    CategoryTreeCode nvarchar(50) NOT NULL,
    CategoryCode nvarchar(200) NOT NULL,
    MoveRootCode nvarchar(200) NOT NULL,
    OldPath nvarchar(1000) NOT NULL,
    NewPath nvarchar(1000) NOT NULL,
    OldLevel int NOT NULL,
    NewLevel int NOT NULL,
    PRIMARY KEY (CategoryTreeCode, CategoryCode)
  );
  INSERT @Affected(CategoryTreeCode, CategoryCode, MoveRootCode, OldPath, NewPath, OldLevel, NewLevel)
  SELECT node.CategoryTreeCode, node.CategoryCode, root.CategoryCode, node.CategoryPath,
         root.NewRootPath + SUBSTRING(node.CategoryPath, LEN(root.CategoryPath) + 1, 4000),
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
    WebSite nvarchar(100) NOT NULL,
    OldPath nvarchar(1000) NOT NULL,
    NewPath nvarchar(1000) NULL,
    PRIMARY KEY (CategoryTreeCode, CategoryCode, WebSite)
  );
  INSERT @MovedPaths(CategoryTreeCode, CategoryCode, WebSite, OldPath)
  SELECT translated.CategoryTreeCode, translated.CategoryCode, website.WebSiteCode, translated.CategoryPath
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

  UPDATE node
    SET ParentCategoryCode = CASE WHEN root.CategoryCode IS NOT NULL THEN @TargetParentCategoryCode ELSE node.ParentCategoryCode END,
        LevelNo = affected.NewLevel,
        CategoryPath = affected.NewPath
  FROM canon.Category AS node
  INNER JOIN @Affected AS affected
    ON affected.CategoryTreeCode = node.CategoryTreeCode AND affected.CategoryCode = node.CategoryCode
  LEFT JOIN @Roots AS root
    ON root.CategoryTreeCode = node.CategoryTreeCode AND root.CategoryCode = node.CategoryCode;

  UPDATE moved
    SET NewPath = translated.CategoryPath
  FROM @MovedPaths AS moved
  INNER JOIN canon.WebSite AS website ON website.WebSiteCode = moved.WebSite
  INNER JOIN canon.CategoryPathTranslated AS translated
    ON translated.CategoryTreeCode = moved.CategoryTreeCode
   AND translated.CategoryCode = moved.CategoryCode
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
END;
');

EXEC(N'
CREATE OR ALTER PROCEDURE canon.DeleteCategories
  @CategoriesJson nvarchar(max),
  @Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  SET @Actor = NULLIF(LTRIM(RTRIM(@Actor)), N'''');
  IF @Actor IS NULL THROW 228030, N''Akter je obvezen.'', 1;
  IF ISJSON(@CategoriesJson) <> 1 THROW 228031, N''Izbor kategorij ni veljaven.'', 1;

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
  IF NOT EXISTS (SELECT 1 FROM @Selected) THROW 228032, N''Izberi vsaj eno kategorijo.'', 1;

  BEGIN TRANSACTION;

  DECLARE @LockedSelected int;
  SELECT @LockedSelected = COUNT(*)
  FROM canon.Category AS node WITH (UPDLOCK, HOLDLOCK)
  INNER JOIN @Selected AS selected
    ON selected.CategoryTreeCode = node.CategoryTreeCode AND selected.CategoryCode = node.CategoryCode;

  IF (SELECT COUNT(*) FROM @Selected) <> @LockedSelected
    THROW 228033, N''Ena od izbranih kategorij ne obstaja vec. Osvezi stran.'', 1;

  DECLARE @Roots TABLE
  (
    CategoryTreeCode nvarchar(50) NOT NULL,
    CategoryCode nvarchar(200) NOT NULL,
    CategoryPath nvarchar(1000) NOT NULL,
    PRIMARY KEY (CategoryTreeCode, CategoryCode)
  );
  INSERT @Roots(CategoryTreeCode, CategoryCode, CategoryPath)
  SELECT node.CategoryTreeCode, node.CategoryCode, node.CategoryPath
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

  DECLARE @Affected TABLE
  (
    CategoryTreeCode nvarchar(50) NOT NULL,
    CategoryCode nvarchar(200) NOT NULL,
    ParentCategoryCode nvarchar(200) NULL,
    CategoryName nvarchar(400) NOT NULL,
    CategoryPath nvarchar(1000) NOT NULL,
    PRIMARY KEY (CategoryTreeCode, CategoryCode)
  );
  INSERT @Affected(CategoryTreeCode, CategoryCode, ParentCategoryCode, CategoryName, CategoryPath)
  SELECT DISTINCT node.CategoryTreeCode, node.CategoryCode, node.ParentCategoryCode, node.CategoryName, node.CategoryPath
  FROM canon.Category AS node
  INNER JOIN @Roots AS root
    ON root.CategoryTreeCode = node.CategoryTreeCode
   AND (node.CategoryCode = root.CategoryCode OR node.CategoryPath LIKE root.CategoryPath + N'' > %'');

  DECLARE @Paths TABLE
  (
    CategoryTreeCode nvarchar(50) NOT NULL,
    CategoryCode nvarchar(200) NOT NULL,
    WebSite nvarchar(100) NOT NULL,
    CategoryPath nvarchar(1000) NOT NULL,
    PRIMARY KEY (CategoryTreeCode, CategoryCode, WebSite)
  );
  INSERT @Paths(CategoryTreeCode, CategoryCode, WebSite, CategoryPath)
  SELECT translated.CategoryTreeCode, translated.CategoryCode, website.WebSiteCode, translated.CategoryPath
  FROM canon.CategoryPathTranslated AS translated
  INNER JOIN canon.WebSite AS website
    ON website.CategoryTreeCode = translated.CategoryTreeCode
   AND website.LanguageCode = translated.LanguageCode
   AND website.IsActive = 1
  INNER JOIN @Affected AS affected
    ON affected.CategoryTreeCode = translated.CategoryTreeCode
   AND affected.CategoryCode = translated.CategoryCode;

  DECLARE @RootCount int = (SELECT COUNT(*) FROM @Roots);
  DECLARE @CategoryCount int = (SELECT COUNT(*) FROM @Affected);
  DECLARE @AssignmentCount bigint =
    (SELECT COUNT_BIG(*) FROM canon.ProductCategory AS assignment INNER JOIN @Paths AS path ON path.WebSite = assignment.WebSite AND path.CategoryPath = assignment.CategoryPath)
    + (SELECT COUNT_BIG(*) FROM pim.ProductCategory AS assignment INNER JOIN @Paths AS path ON path.WebSite = assignment.WebSite AND path.CategoryPath = assignment.CategoryPath)
    + (SELECT COUNT_BIG(*) FROM pim.ProductCategoryOverride AS assignment INNER JOIN @Paths AS path ON path.WebSite = assignment.WebSite AND path.CategoryPath = assignment.CategoryPath);
  DECLARE @MappingCount bigint =
    (SELECT COUNT_BIG(*) FROM map.CategoryPathMap AS mapping INNER JOIN @Affected AS affected
      ON affected.CategoryTreeCode = mapping.CategoryTreeCode AND affected.CategoryCode = mapping.CategoryCode);

  INSERT canon.CategoryChangeHistory
    (Operation, CategoryTreeCode, CategoryCode, CategoryName, OldParentCategoryCode,
     NewParentCategoryCode, OldCategoryPath, NewCategoryPath, ChangedBy)
  SELECT N''DELETE'', affected.CategoryTreeCode, affected.CategoryCode, affected.CategoryName,
         affected.ParentCategoryCode, NULL, affected.CategoryPath, NULL, @Actor
  FROM @Affected AS affected;

  DELETE assignment FROM canon.ProductCategory AS assignment
  INNER JOIN @Paths AS path ON path.WebSite = assignment.WebSite AND path.CategoryPath = assignment.CategoryPath;
  DELETE assignment FROM pim.ProductCategory AS assignment
  INNER JOIN @Paths AS path ON path.WebSite = assignment.WebSite AND path.CategoryPath = assignment.CategoryPath;
  DELETE assignment FROM pim.ProductCategoryOverride AS assignment
  INNER JOIN @Paths AS path ON path.WebSite = assignment.WebSite AND path.CategoryPath = assignment.CategoryPath;

  INSERT map.CategoryPathMapHistory
    (SourceCode, CategoryTreeCode, SourcePathKey, OldCategoryCode, NewCategoryCode,
     OldIsActive, NewIsActive, ChangedBy, Note)
  SELECT mapping.SourceCode, mapping.CategoryTreeCode, mapping.SourcePathKey,
         mapping.CategoryCode, NULL, mapping.IsActive, 0, @Actor, N''brisanje kategorije (228)''
  FROM map.CategoryPathMap AS mapping
  INNER JOIN @Affected AS affected
    ON affected.CategoryTreeCode = mapping.CategoryTreeCode AND affected.CategoryCode = mapping.CategoryCode;
  DELETE mapping FROM map.CategoryPathMap AS mapping
  INNER JOIN @Affected AS affected
    ON affected.CategoryTreeCode = mapping.CategoryTreeCode AND affected.CategoryCode = mapping.CategoryCode;

  DELETE titleRule FROM pim.TitleRule AS titleRule
  INNER JOIN @Affected AS affected
    ON affected.CategoryTreeCode = titleRule.CategoryTreeCode AND affected.CategoryCode = titleRule.CategoryCode;
  DELETE requirement FROM val.FieldRequirement AS requirement
  INNER JOIN @Affected AS affected
    ON affected.CategoryTreeCode = requirement.CategoryTreeCode AND affected.CategoryCode = requirement.CategoryCode;
  DELETE attributeSet FROM canon.CategoryAttributeSet AS attributeSet
  INNER JOIN @Affected AS affected
    ON affected.CategoryTreeCode = attributeSet.CategoryTreeCode AND affected.CategoryCode = attributeSet.CategoryCode;
  DELETE translation FROM canon.CategoryTranslation AS translation
  INNER JOIN @Affected AS affected
    ON affected.CategoryTreeCode = translation.CategoryTreeCode AND affected.CategoryCode = translation.CategoryCode;
  DELETE category FROM canon.Category AS category
  INNER JOIN @Affected AS affected
    ON affected.CategoryTreeCode = category.CategoryTreeCode AND affected.CategoryCode = category.CategoryCode;

  COMMIT TRANSACTION;
  SELECT RootCount = @RootCount, CategoryCount = @CategoryCount,
         AssignmentCount = @AssignmentCount, MappingCount = @MappingCount;
END;
');
