/*
  149 — pravila za sestavo spletnih nazivov.

  Uporabnik 2026-09-02: "Stran, kjer se doloci sestavljanje pravil za sestavo nazivov; nazivi
  morajo biti skladni s tem, kaj mora biti notri, in s slovnico. Nato je treba nazive prevesti
  v vse jezike." Stari sistem je imel pim.TitleCompositionRule s koraki (ATTRIBUTE, LITERAL,
  CATEGORY_LEVEL, DUAL_COLOR), pogoji omitIf/includeOnlyIf, protipodvojitvijo in sklanjatvijo
  let garancije (PIM_test, sql/MultiWebSite/07-09, ufn_FormatWarrantyYearsSl). Tu je isto
  zajeto v eni predlogi z zetoni, da je pravilo berljivo v eni vrstici:

      {ErpName} {Category} {Attr:Vrsta svetlobnega vira|omitIf:integr} {Attr:Nazivna moč|unit:W}
      {Attr:Temperatura barve|unit:K} {Attr:Prevladujoča barva|lower} {Attr:Garancija|years}

  Zetoni:  {ItemID} {ErpName} {WebName} {Manufacturer} {Category} {Category:N} {Attr:<ime>}
  Modifikatorji (locilo |): omitIf:<niz>  onlyIf:<niz>  omitIfAttr:<ime>~<niz>  onlyIfAttr:<ime>~<niz>
                            unit:<enota>  years  lower  upper  prefix:<niz>  suffix:<niz>
  Pravila sestave: prazen zeton izpade brez sledu, presledki se strnejo, vrednost, ki je ze v
  sestavljenem nazivu, se ne ponovi (protipodvojitev), prva crka je velika.

  Jeziki. Predloga ima jezik ali pa velja za vse; vrednosti pridejo v jeziku predloge:
    - ime kategorije iz canon.CategoryTranslation (padec na slovensko),
    - vrednost atributa: vrstica v jeziku; ce je ni, angleska vrstica prevedena prek slovarja
      map.ValueLookup (Domain '*', Language SL/DE/HR — 6.316 parov iz Prevajalne tabele);
      ce ni prevoda, angleska vrednost; sicer vrstica brez jezika,
    - ERP naziv v jeziku (TITLE_ERP.<jezik>), sicer slovenski,
    - "years" sklanja leta: sl leto/leti/leta/let, en year/years, de Jahr/Jahre, hr godina/godine.
  Tako nastane naziv v vseh jezikih iz istih podatkov; kjer prevoda ni, ostane izvorna
  vrednost in to je vidno v predogledu, ne skrito.

  Obseg pravila: (drevo, kategorija) — podkategorije ga podedujejo, najblizje zmaga; pravilo
  brez kategorije je privzeto za drevo, brez drevesa za vse. Zapis gre skozi pim.ApplyTitleRules
  z odprtim kontekstom sprememb (zgodovina kot pri rocnem urejanju) in privzeto samo tja, kjer
  spletnega naziva se ni; prepis obstojecih je izrecna izbira. Naziv, ki ga pise SAOP
  (out.SaopXmlField), se ne dotakne — isto pravilo kot pim.SaveProductTexts.

  Migrator ne pozna locila GO; funkcije in procedure so v EXEC(N'...').
*/

SET XACT_ABORT ON;

/* --- 1) Register pravil ------------------------------------------------------------------ */

IF OBJECT_ID(N'pim.TitleRule', N'U') IS NULL
BEGIN
  CREATE TABLE pim.TitleRule
  (
    TitleRuleId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_TitleRule PRIMARY KEY,
    RuleCode nvarchar(100) NOT NULL,
    Name nvarchar(200) NOT NULL,
    CategoryTreeCode nvarchar(50) NULL,
    CategoryCode nvarchar(200) NULL,
    LanguageCode nvarchar(20) NULL,
    Template nvarchar(1000) NOT NULL,
    Separator nvarchar(10) NOT NULL CONSTRAINT DF_TitleRule_Separator DEFAULT (N' '),
    IsActive bit NOT NULL CONSTRAINT DF_TitleRule_IsActive DEFAULT (1),
    SortOrder int NOT NULL CONSTRAINT DF_TitleRule_SortOrder DEFAULT (100),
    Note nvarchar(400) NULL,
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_TitleRule_UpdatedUtc DEFAULT (SYSUTCDATETIME()),
    UpdatedBy nvarchar(200) NOT NULL CONSTRAINT DF_TitleRule_UpdatedBy DEFAULT (N'migracija 149'),
    CONSTRAINT UQ_TitleRule_Code UNIQUE (RuleCode),
    CONSTRAINT CK_TitleRule_Scope CHECK (CategoryCode IS NULL OR CategoryTreeCode IS NOT NULL)
  );
END;

/* --- 2) Sestava enega naziva ------------------------------------------------------------- */

EXEC(N'CREATE OR ALTER FUNCTION pim.TitleYears(@Value nvarchar(100), @LanguageCode nvarchar(20))
RETURNS nvarchar(120)
AS
BEGIN
  /* Sklanjatev let: prepisano iz starega pim.ufn_FormatWarrantyYearsSl. Nestevilska vrednost
     se vrne, kot je. */
  DECLARE @Number int = TRY_CONVERT(int, LEFT(LTRIM(@Value), PATINDEX(N''%[^0-9]%'', LTRIM(@Value) + N''x'') - 1));
  IF @Number IS NULL RETURN @Value;
  DECLARE @Word nvarchar(20) =
    CASE LOWER(ISNULL(@LanguageCode, N''sl''))
      WHEN N''sl'' THEN CASE WHEN @Number % 100 BETWEEN 11 AND 14 THEN N''let''
                          WHEN @Number % 10 = 1 THEN N''leto'' WHEN @Number % 10 = 2 THEN N''leti''
                          WHEN @Number % 10 IN (3, 4) THEN N''leta'' ELSE N''let'' END
      WHEN N''en'' THEN CASE WHEN @Number = 1 THEN N''year'' ELSE N''years'' END
      WHEN N''de'' THEN CASE WHEN @Number = 1 THEN N''Jahr'' ELSE N''Jahre'' END
      WHEN N''hr'' THEN CASE WHEN @Number % 10 = 1 AND @Number % 100 <> 11 THEN N''godina''
                          WHEN @Number % 10 IN (2, 3, 4) AND @Number % 100 NOT BETWEEN 12 AND 14 THEN N''godine'' ELSE N''godina'' END
      WHEN N''it'' THEN CASE WHEN @Number = 1 THEN N''anno'' ELSE N''anni'' END
      ELSE N''''
    END;
  RETURN CONVERT(nvarchar(20), @Number) + CASE WHEN @Word = N'''' THEN N'''' ELSE N'' '' + @Word END;
END');

EXEC(N'CREATE OR ALTER FUNCTION pim.TitleAttributeValue(@ProductId bigint, @AttributeName nvarchar(400), @LanguageCode nvarchar(20))
RETURNS nvarchar(500)
AS
BEGIN
  /* Vrednost atributa v jeziku: vrstica v jeziku > angleska vrstica prek slovarja > angleska
     vrstica > vrstica brez jezika > slovenska vrstica. Slovar je map.ValueLookup, Domain ''*''. */
  DECLARE @Language nvarchar(20) = LOWER(ISNULL(@LanguageCode, N''sl''));
  DECLARE @Value nvarchar(500);

  SELECT TOP (1) @Value = attributeValue.Value
  FROM canon.ProductAttribute AS attributeValue
  WHERE attributeValue.ProductId = @ProductId AND attributeValue.AttributeCode = @AttributeName
    AND LOWER(attributeValue.LanguageCode) = @Language AND NULLIF(attributeValue.Value, N'''') IS NOT NULL
  ORDER BY attributeValue.ProductAttributeId DESC;
  IF @Value IS NOT NULL RETURN @Value;

  DECLARE @English nvarchar(500);
  SELECT TOP (1) @English = attributeValue.Value
  FROM canon.ProductAttribute AS attributeValue
  WHERE attributeValue.ProductId = @ProductId AND attributeValue.AttributeCode = @AttributeName
    AND LOWER(attributeValue.LanguageCode) = N''en'' AND NULLIF(attributeValue.Value, N'''') IS NOT NULL
  ORDER BY attributeValue.ProductAttributeId DESC;

  IF @English IS NOT NULL
  BEGIN
    IF @Language = N''en'' RETURN @English;
    SELECT TOP (1) @Value = lookup.TargetValue
    FROM map.ValueLookup AS lookup
    WHERE lookup.IsActive = 1 AND lookup.Language = UPPER(@Language)
      AND (lookup.Domain = @AttributeName + N'' SLO'' OR lookup.Domain = N''*'')
      AND lookup.SourceValue = @English
    ORDER BY CASE WHEN lookup.Domain = N''*'' THEN 1 ELSE 0 END;
    IF @Value IS NOT NULL RETURN @Value;
    RETURN @English;
  END;

  SELECT TOP (1) @Value = attributeValue.Value
  FROM canon.ProductAttribute AS attributeValue
  WHERE attributeValue.ProductId = @ProductId AND attributeValue.AttributeCode = @AttributeName
    AND NULLIF(attributeValue.Value, N'''') IS NOT NULL
  ORDER BY CASE WHEN attributeValue.LanguageCode IS NULL OR attributeValue.LanguageCode = N'''' THEN 0
                WHEN LOWER(attributeValue.LanguageCode) = N''sl'' THEN 1 ELSE 2 END, attributeValue.ProductAttributeId DESC;
  RETURN @Value;
END');

EXEC(N'CREATE OR ALTER FUNCTION pim.TitleCategoryName(@ProductId bigint, @LanguageCode nvarchar(20), @Level int)
RETURNS nvarchar(400)
AS
BEGIN
  /* Ime kategorije izdelka v jeziku (canon.CategoryTranslation, padec na slovensko).
     @Level NULL = list (najgloblja); N = prednik na nivoju N. Vzame se prva stran po
     vrstnem redu registra canon.WebSite. */
  DECLARE @Language nvarchar(20) = LOWER(ISNULL(@LanguageCode, N''sl''));
  DECLARE @Tree nvarchar(50), @Code nvarchar(200);
  SELECT TOP (1) @Tree = node.CategoryTreeCode, @Code = node.CategoryCode
  FROM canon.ProductCategory AS productCategory
  INNER JOIN canon.WebSite AS site ON site.WebSiteCode = productCategory.WebSite AND site.IsActive = 1
  INNER JOIN canon.Category AS node ON node.CategoryTreeCode = site.CategoryTreeCode AND node.CategoryPath = productCategory.CategoryPath
  WHERE productCategory.ProductId = @ProductId
  ORDER BY site.SortOrder, node.LevelNo DESC;
  IF @Code IS NULL RETURN NULL;

  IF @Level IS NOT NULL
  BEGIN
    DECLARE @Guard int = 0;
    WHILE @Guard < 12
    BEGIN
      DECLARE @LevelNo int, @Parent nvarchar(200);
      SELECT @LevelNo = LevelNo, @Parent = ParentCategoryCode FROM canon.Category WHERE CategoryTreeCode = @Tree AND CategoryCode = @Code;
      IF @LevelNo IS NULL OR @LevelNo <= @Level BREAK;
      IF @Parent IS NULL BREAK;
      SET @Code = @Parent; SET @Guard += 1;
    END;
    IF (SELECT LevelNo FROM canon.Category WHERE CategoryTreeCode = @Tree AND CategoryCode = @Code) <> @Level RETURN NULL;
  END;

  RETURN COALESCE(
    (SELECT TOP (1) translation.CategoryName FROM canon.CategoryTranslation AS translation
     WHERE translation.CategoryTreeCode = @Tree AND translation.CategoryCode = @Code AND LOWER(translation.LanguageCode) = @Language
       AND NULLIF(translation.CategoryName, N'''') IS NOT NULL),
    (SELECT node.CategoryName FROM canon.Category AS node WHERE node.CategoryTreeCode = @Tree AND node.CategoryCode = @Code));
END');

EXEC(N'CREATE OR ALTER FUNCTION pim.ComposeTitle(@ProductId bigint, @LanguageCode nvarchar(20), @Template nvarchar(1000), @Separator nvarchar(10))
RETURNS nvarchar(500)
AS
BEGIN
  DECLARE @Language nvarchar(20) = LOWER(ISNULL(@LanguageCode, N''sl''));
  DECLARE @Out nvarchar(1200) = N'''';
  DECLARE @Pos int = 1, @Open int, @Close int, @Token nvarchar(300), @Literal nvarchar(500);
  DECLARE @OrganizationId int = (SELECT OrganizationId FROM canon.Product WHERE ProductId = @ProductId);
  SET @Separator = ISNULL(@Separator, N'' '');

  WHILE @Pos <= LEN(@Template) + 1
  BEGIN
    SET @Open = CHARINDEX(N''{'', @Template, @Pos);
    SET @Literal = CASE WHEN @Open = 0 THEN SUBSTRING(@Template, @Pos, 1200) ELSE SUBSTRING(@Template, @Pos, @Open - @Pos) END;
    IF LTRIM(RTRIM(@Literal)) <> N'''' SET @Out = @Out + @Literal;
    IF @Open = 0 BREAK;
    SET @Close = CHARINDEX(N''}'', @Template, @Open);
    IF @Close = 0 BREAK;
    SET @Token = SUBSTRING(@Template, @Open + 1, @Close - @Open - 1);
    SET @Pos = @Close + 1;

    /* zeton = osnova | modifikator | modifikator ... */
    DECLARE @Base nvarchar(300) = CASE WHEN CHARINDEX(N''|'', @Token) = 0 THEN @Token ELSE LEFT(@Token, CHARINDEX(N''|'', @Token) - 1) END;
    DECLARE @Modifiers nvarchar(300) = CASE WHEN CHARINDEX(N''|'', @Token) = 0 THEN N'''' ELSE SUBSTRING(@Token, CHARINDEX(N''|'', @Token) + 1, 300) END;
    DECLARE @Value nvarchar(500) = NULL;
    DECLARE @BaseKind nvarchar(50) = CASE WHEN CHARINDEX(N'':'', @Base) = 0 THEN @Base ELSE LEFT(@Base, CHARINDEX(N'':'', @Base) - 1) END;
    DECLARE @BaseArg nvarchar(300) = CASE WHEN CHARINDEX(N'':'', @Base) = 0 THEN NULL ELSE SUBSTRING(@Base, CHARINDEX(N'':'', @Base) + 1, 300) END;

    IF @BaseKind = N''ItemID'' SET @Value = (SELECT ItemID FROM canon.Product WHERE ProductId = @ProductId);
    ELSE IF @BaseKind = N''ErpName'' SET @Value = COALESCE(
      (SELECT TOP (1) Value FROM canon.ProductText WHERE ProductId = @ProductId AND TextType = N''TITLE_ERP'' AND LOWER(Lang) = @Language AND NULLIF(Value, N'''') IS NOT NULL),
      (SELECT TOP (1) Value FROM canon.ProductText WHERE ProductId = @ProductId AND TextType = N''TITLE_ERP'' AND Lang = N''sl'' AND NULLIF(Value, N'''') IS NOT NULL));
    ELSE IF @BaseKind = N''WebName'' SET @Value = COALESCE(
      (SELECT TOP (1) Value FROM canon.ProductText WHERE ProductId = @ProductId AND TextType = N''WEB_TITLE'' AND LOWER(Lang) = @Language AND NULLIF(Value, N'''') IS NOT NULL),
      (SELECT TOP (1) Value FROM canon.ProductText WHERE ProductId = @ProductId AND TextType = N''WEB_TITLE'' AND Lang = N''sl'' AND NULLIF(Value, N'''') IS NOT NULL));
    ELSE IF @BaseKind = N''Manufacturer'' SET @Value =
      (SELECT TOP (1) partner.PartnerName FROM canon.Product AS product
       INNER JOIN canon.PartnerName AS partner ON partner.OrganizationId = product.OrganizationId AND partner.PartnerCode = product.Manufacturer
       WHERE product.ProductId = @ProductId);
    ELSE IF @BaseKind = N''Category'' SET @Value = pim.TitleCategoryName(@ProductId, @Language, TRY_CONVERT(int, @BaseArg));
    ELSE IF @BaseKind = N''Attr'' AND @BaseArg IS NOT NULL SET @Value = pim.TitleAttributeValue(@ProductId, @BaseArg, @Language);

    /* modifikatorji, po vrsti */
    DECLARE @Rest nvarchar(300) = @Modifiers, @Modifier nvarchar(300), @ModKind nvarchar(50), @ModArg nvarchar(300);
    WHILE @Rest <> N''''
    BEGIN
      SET @Modifier = CASE WHEN CHARINDEX(N''|'', @Rest) = 0 THEN @Rest ELSE LEFT(@Rest, CHARINDEX(N''|'', @Rest) - 1) END;
      SET @Rest = CASE WHEN CHARINDEX(N''|'', @Rest) = 0 THEN N'''' ELSE SUBSTRING(@Rest, CHARINDEX(N''|'', @Rest) + 1, 300) END;
      SET @ModKind = CASE WHEN CHARINDEX(N'':'', @Modifier) = 0 THEN @Modifier ELSE LEFT(@Modifier, CHARINDEX(N'':'', @Modifier) - 1) END;
      SET @ModArg = CASE WHEN CHARINDEX(N'':'', @Modifier) = 0 THEN NULL ELSE SUBSTRING(@Modifier, CHARINDEX(N'':'', @Modifier) + 1, 300) END;

      IF @ModKind = N''omitIf'' AND @Value IS NOT NULL AND @ModArg IS NOT NULL AND CHARINDEX(LOWER(@ModArg), LOWER(@Value)) > 0 SET @Value = NULL;
      ELSE IF @ModKind = N''onlyIf'' AND (@Value IS NULL OR @ModArg IS NULL OR CHARINDEX(LOWER(@ModArg), LOWER(@Value)) = 0) SET @Value = NULL;
      ELSE IF @ModKind IN (N''omitIfAttr'', N''onlyIfAttr'') AND @ModArg IS NOT NULL AND CHARINDEX(N''~'', @ModArg) > 0
      BEGIN
        DECLARE @OtherName nvarchar(300) = LEFT(@ModArg, CHARINDEX(N''~'', @ModArg) - 1);
        DECLARE @Needle nvarchar(300) = SUBSTRING(@ModArg, CHARINDEX(N''~'', @ModArg) + 1, 300);
        DECLARE @Other nvarchar(500) = pim.TitleAttributeValue(@ProductId, @OtherName, @Language);
        DECLARE @Hit bit = CASE WHEN @Other IS NOT NULL AND CHARINDEX(LOWER(@Needle), LOWER(@Other)) > 0 THEN 1 ELSE 0 END;
        IF (@ModKind = N''omitIfAttr'' AND @Hit = 1) OR (@ModKind = N''onlyIfAttr'' AND @Hit = 0) SET @Value = NULL;
      END
      ELSE IF @ModKind = N''unit'' AND @Value IS NOT NULL AND @ModArg IS NOT NULL
        AND RIGHT(LOWER(RTRIM(@Value)), LEN(@ModArg)) <> LOWER(@ModArg) SET @Value = RTRIM(@Value) + N'' '' + @ModArg;
      ELSE IF @ModKind = N''years'' AND @Value IS NOT NULL SET @Value = pim.TitleYears(@Value, @Language);
      ELSE IF @ModKind = N''lower'' AND @Value IS NOT NULL SET @Value = LOWER(@Value);
      ELSE IF @ModKind = N''upper'' AND @Value IS NOT NULL SET @Value = UPPER(@Value);
      ELSE IF @ModKind = N''prefix'' AND @Value IS NOT NULL SET @Value = ISNULL(@ModArg, N'''') + @Value;
      ELSE IF @ModKind = N''suffix'' AND @Value IS NOT NULL SET @Value = @Value + ISNULL(@ModArg, N'''');
    END;

    SET @Value = NULLIF(LTRIM(RTRIM(@Value)), N'''');
    /* protipodvojitev: vrednost, ki je ze v nazivu (tudi brez presledkov), se ne ponovi */
    IF @Value IS NOT NULL AND CHARINDEX(LOWER(@Value), LOWER(@Out)) = 0
      AND CHARINDEX(REPLACE(LOWER(@Value), N'' '', N''''), REPLACE(LOWER(@Out), N'' '', N'''')) = 0
    BEGIN
      IF @Out <> N'''' AND RIGHT(@Out, 1) NOT IN (N'' '', N''-'', N''/'', N'','') SET @Out = @Out + @Separator;
      SET @Out = @Out + @Value;
    END;
  END;

  /* strnjeni presledki, obrezano, velika zacetnica */
  WHILE CHARINDEX(N''  '', @Out) > 0 SET @Out = REPLACE(@Out, N''  '', N'' '');
  SET @Out = LTRIM(RTRIM(@Out));
  IF @Out = N'''' RETURN NULL;
  RETURN LEFT(UPPER(LEFT(@Out, 1)) + SUBSTRING(@Out, 2, 1200), 500);
END');

/* --- 3) Katero pravilo velja za izdelek -------------------------------------------------- */

EXEC(N'CREATE OR ALTER FUNCTION pim.ResolveTitleRule(@ProductId bigint, @LanguageCode nvarchar(20))
RETURNS int
AS
BEGIN
  /* Najblizje pravilo po verigi prednikov prve strani izdelka; jezikovno pravilo pred
     splosnim; brez kategorije = privzeto za drevo; brez drevesa = privzeto za vse. */
  DECLARE @Language nvarchar(20) = LOWER(ISNULL(@LanguageCode, N''sl''));
  DECLARE @Tree nvarchar(50), @Code nvarchar(200), @RuleId int;
  SELECT TOP (1) @Tree = node.CategoryTreeCode, @Code = node.CategoryCode
  FROM canon.ProductCategory AS productCategory
  INNER JOIN canon.WebSite AS site ON site.WebSiteCode = productCategory.WebSite AND site.IsActive = 1
  INNER JOIN canon.Category AS node ON node.CategoryTreeCode = site.CategoryTreeCode AND node.CategoryPath = productCategory.CategoryPath
  WHERE productCategory.ProductId = @ProductId
  ORDER BY site.SortOrder, node.LevelNo DESC;

  DECLARE @Guard int = 0;
  WHILE @Code IS NOT NULL AND @Guard < 12
  BEGIN
    SELECT TOP (1) @RuleId = TitleRuleId FROM pim.TitleRule
    WHERE IsActive = 1 AND CategoryTreeCode = @Tree AND CategoryCode = @Code
      AND (LOWER(LanguageCode) = @Language OR LanguageCode IS NULL)
    ORDER BY CASE WHEN LanguageCode IS NULL THEN 1 ELSE 0 END, SortOrder, TitleRuleId;
    IF @RuleId IS NOT NULL RETURN @RuleId;
    SET @Code = (SELECT ParentCategoryCode FROM canon.Category WHERE CategoryTreeCode = @Tree AND CategoryCode = @Code);
    SET @Guard += 1;
  END;

  SELECT TOP (1) @RuleId = TitleRuleId FROM pim.TitleRule
  WHERE IsActive = 1 AND CategoryCode IS NULL AND (CategoryTreeCode = @Tree OR CategoryTreeCode IS NULL)
    AND (LOWER(LanguageCode) = @Language OR LanguageCode IS NULL)
  ORDER BY CASE WHEN CategoryTreeCode IS NULL THEN 1 ELSE 0 END, CASE WHEN LanguageCode IS NULL THEN 1 ELSE 0 END, SortOrder, TitleRuleId;
  RETURN @RuleId;
END');

/* --- 4) Shranjevanje, predogled, zapis --------------------------------------------------- */

EXEC(N'CREATE OR ALTER PROCEDURE pim.SaveTitleRule
  @RuleCode nvarchar(100),
  @Name nvarchar(200),
  @CategoryTreeCode nvarchar(50) = NULL,
  @CategoryCode nvarchar(200) = NULL,
  @LanguageCode nvarchar(20) = NULL,
  @Template nvarchar(1000),
  @Separator nvarchar(10) = N'' '',
  @IsActive bit = 1,
  @SortOrder int = 100,
  @Note nvarchar(400) = NULL,
  @Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  SET @RuleCode = NULLIF(UPPER(LTRIM(RTRIM(@RuleCode))), N'''');
  SET @Template = NULLIF(LTRIM(RTRIM(@Template)), N'''');
  SET @CategoryTreeCode = NULLIF(LTRIM(RTRIM(@CategoryTreeCode)), N'''');
  SET @CategoryCode = NULLIF(LTRIM(RTRIM(@CategoryCode)), N'''');
  SET @LanguageCode = NULLIF(LOWER(LTRIM(RTRIM(@LanguageCode))), N'''');
  IF @RuleCode IS NULL THROW 51490, N''Koda pravila je obvezna.'', 1;
  IF @Template IS NULL THROW 51491, N''Predloga je obvezna.'', 1;
  IF CHARINDEX(N''{'', @Template) = 0 THROW 51492, N''Predloga brez zetona {…} bi vsem izdelkom dala isti naziv.'', 1;
  IF @CategoryCode IS NOT NULL AND @CategoryTreeCode IS NULL THROW 51493, N''Kategorija brez drevesa ni mogoca.'', 1;
  IF @CategoryTreeCode IS NOT NULL AND NOT EXISTS (SELECT 1 FROM canon.Category WHERE CategoryTreeCode = @CategoryTreeCode)
    THROW 51494, N''Drevo ne obstaja.'', 1;
  IF @CategoryCode IS NOT NULL AND NOT EXISTS (SELECT 1 FROM canon.Category WHERE CategoryTreeCode = @CategoryTreeCode AND CategoryCode = @CategoryCode)
    THROW 51495, N''Kategorija ne obstaja v tem drevesu.'', 1;
  IF @LanguageCode IS NOT NULL AND NOT EXISTS (SELECT 1 FROM canon.Language WHERE LOWER(LanguageCode) = @LanguageCode AND IsActive = 1)
    THROW 51496, N''Jezik ni v registru.'', 1;
  IF NULLIF(LTRIM(RTRIM(@Actor)), N'''') IS NULL THROW 51497, N''Kdo shranjuje pravilo, mora biti znano.'', 1;

  DECLARE @OldJson nvarchar(max) = (SELECT Name, CategoryTreeCode, CategoryCode, LanguageCode, Template, Separator, IsActive, SortOrder, Note
    FROM pim.TitleRule WHERE RuleCode = @RuleCode FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

  IF @OldJson IS NULL
    INSERT pim.TitleRule (RuleCode, Name, CategoryTreeCode, CategoryCode, LanguageCode, Template, Separator, IsActive, SortOrder, Note, UpdatedBy)
    VALUES (@RuleCode, ISNULL(@Name, @RuleCode), @CategoryTreeCode, @CategoryCode, @LanguageCode, @Template, ISNULL(@Separator, N'' ''), @IsActive, @SortOrder, @Note, @Actor);
  ELSE
    UPDATE pim.TitleRule SET Name = ISNULL(@Name, Name), CategoryTreeCode = @CategoryTreeCode, CategoryCode = @CategoryCode,
      LanguageCode = @LanguageCode, Template = @Template, Separator = ISNULL(@Separator, N'' ''), IsActive = @IsActive, SortOrder = @SortOrder,
      Note = @Note, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = @Actor
    WHERE RuleCode = @RuleCode;

  INSERT b2b.AuditLog (OrganizationId, EntityType, EntityKey, ActionCode, OldValueJson, NewValueJson, ChangedBy, ChangedUtc)
  VALUES (0, N''TitleRule'', @RuleCode, CASE WHEN @OldJson IS NULL THEN N''ADD'' ELSE N''UPDATE'' END, @OldJson,
    (SELECT Name, CategoryTreeCode, CategoryCode, LanguageCode, Template, Separator, IsActive, SortOrder, Note
     FROM pim.TitleRule WHERE RuleCode = @RuleCode FOR JSON PATH, WITHOUT_ARRAY_WRAPPER), @Actor, SYSUTCDATETIME());

  SELECT TitleRuleId FROM pim.TitleRule WHERE RuleCode = @RuleCode;
END');

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetTitleRules
AS
BEGIN
  SET NOCOUNT ON;
  SELECT titleRule.TitleRuleId, titleRule.RuleCode, titleRule.Name, titleRule.CategoryTreeCode, titleRule.CategoryCode,
    CategoryName = node.CategoryName, CategoryPath = node.CategoryPath,
    titleRule.LanguageCode, titleRule.Template, titleRule.Separator, titleRule.IsActive, titleRule.SortOrder, titleRule.Note, titleRule.UpdatedUtc, titleRule.UpdatedBy
  FROM pim.TitleRule AS titleRule
  LEFT JOIN canon.Category AS node ON node.CategoryTreeCode = titleRule.CategoryTreeCode AND node.CategoryCode = titleRule.CategoryCode
  ORDER BY titleRule.IsActive DESC, ISNULL(titleRule.CategoryTreeCode, N''''), ISNULL(node.CategoryPath, N''''), ISNULL(titleRule.LanguageCode, N''''), titleRule.SortOrder, titleRule.RuleCode;
END');

EXEC(N'CREATE OR ALTER PROCEDURE pim.PreviewTitleRules
  @OrganizationId int,
  @LanguageCode nvarchar(20) = N''sl'',
  @TitleRuleId int = NULL,        /* NULL = pravilo, ki ga izdelek dobi sam */
  @Template nvarchar(1000) = NULL, /* nesprejeta predloga za poskus, prednost pred pravilom */
  @CategoryTreeCode nvarchar(50) = NULL,
  @CategoryCode nvarchar(200) = NULL,
  @OnlyMissing bit = 1,
  @Take int = 20
AS
BEGIN
  SET NOCOUNT ON;
  SET @Take = CASE WHEN @Take < 1 THEN 20 WHEN @Take > 200 THEN 200 ELSE @Take END;
  SET @LanguageCode = LOWER(ISNULL(NULLIF(@LanguageCode, N''''), N''sl''));

  DECLARE @Separator nvarchar(10) = N'' '';
  IF @Template IS NULL AND @TitleRuleId IS NOT NULL
    SELECT @Template = Template, @Separator = Separator, @CategoryTreeCode = ISNULL(@CategoryTreeCode, CategoryTreeCode), @CategoryCode = ISNULL(@CategoryCode, CategoryCode)
    FROM pim.TitleRule WHERE TitleRuleId = @TitleRuleId;

  ;WITH subtree AS
  (
    SELECT CategoryTreeCode, CategoryCode FROM canon.Category WHERE CategoryTreeCode = @CategoryTreeCode AND CategoryCode = @CategoryCode
    UNION ALL
    SELECT child.CategoryTreeCode, child.CategoryCode FROM subtree
    INNER JOIN canon.Category AS child ON child.CategoryTreeCode = subtree.CategoryTreeCode AND child.ParentCategoryCode = subtree.CategoryCode
  ),
  candidates AS
  (
    SELECT DISTINCT product.ProductId, product.ItemID
    FROM canon.Product AS product
    WHERE product.OrganizationId = @OrganizationId AND product.IsActive = 1
      AND EXISTS (SELECT 1 FROM canon.ProductCategory AS productCategory WHERE productCategory.ProductId = product.ProductId)
      AND (@CategoryCode IS NULL OR EXISTS
        (SELECT 1 FROM canon.ProductCategory AS productCategory
         INNER JOIN canon.WebSite AS site ON site.WebSiteCode = productCategory.WebSite
         INNER JOIN canon.Category AS node ON node.CategoryTreeCode = site.CategoryTreeCode AND node.CategoryPath = productCategory.CategoryPath
         INNER JOIN subtree ON subtree.CategoryTreeCode = node.CategoryTreeCode AND subtree.CategoryCode = node.CategoryCode
         WHERE productCategory.ProductId = product.ProductId))
      AND (@CategoryCode IS NOT NULL OR @CategoryTreeCode IS NULL OR EXISTS
        (SELECT 1 FROM canon.ProductCategory AS productCategory
         INNER JOIN canon.WebSite AS site ON site.WebSiteCode = productCategory.WebSite
         WHERE productCategory.ProductId = product.ProductId AND site.CategoryTreeCode = @CategoryTreeCode))
      AND (@OnlyMissing = 0 OR NOT EXISTS
        (SELECT 1 FROM canon.ProductText AS textValue
         WHERE textValue.ProductId = product.ProductId AND textValue.TextType = N''WEB_TITLE'' AND LOWER(textValue.Lang) = @LanguageCode
           AND NULLIF(textValue.Value, N'''') IS NOT NULL))
  )
  SELECT TOP (@Take) candidates.ProductId, candidates.ItemID,
    CurrentTitle = (SELECT TOP (1) Value FROM canon.ProductText WHERE ProductId = candidates.ProductId AND TextType = N''WEB_TITLE'' AND LOWER(Lang) = @LanguageCode),
    ErpTitle = (SELECT TOP (1) Value FROM canon.ProductText WHERE ProductId = candidates.ProductId AND TextType = N''TITLE_ERP'' AND Lang = N''sl''),
    RuleCode = titleRule.RuleCode,
    ComposedTitle = pim.ComposeTitle(candidates.ProductId, @LanguageCode, COALESCE(@Template, titleRule.Template), COALESCE(@Separator, titleRule.Separator, N'' ''))
  FROM candidates
  LEFT JOIN pim.TitleRule AS titleRule ON titleRule.TitleRuleId = COALESCE(@TitleRuleId, pim.ResolveTitleRule(candidates.ProductId, @LanguageCode))
  WHERE @Template IS NOT NULL OR titleRule.TitleRuleId IS NOT NULL
  ORDER BY candidates.ItemID;
END');

EXEC(N'CREATE OR ALTER PROCEDURE pim.ApplyTitleRules
  @OrganizationId int,
  @LanguageCode nvarchar(20) = N''sl'',
  @TitleRuleId int = NULL,
  @CategoryTreeCode nvarchar(50) = NULL,
  @CategoryCode nvarchar(200) = NULL,
  @OnlyMissing bit = 1,
  @Actor nvarchar(200),
  @Note nvarchar(400) = NULL
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  SET @LanguageCode = LOWER(ISNULL(NULLIF(@LanguageCode, N''''), N''sl''));
  IF NULLIF(LTRIM(RTRIM(@Actor)), N'''') IS NULL THROW 51498, N''Kdo zapisuje nazive, mora biti znano.'', 1;
  /* Naziv, ki ga pise SAOP, gre skozi odhodno vrsto (isto pravilo kot pim.SaveProductTexts). */
  IF EXISTS (SELECT 1 FROM out.SaopXmlField WHERE TargetKind = N''SAOP_PRODUCT'' AND IsEnabled = 1
             AND FieldKey = N''ProductText.WEB_TITLE.'' + @LanguageCode)
    THROW 51499, N''Spletni naziv v tem jeziku pise SAOP; sprememba mora skozi odhodno vrsto.'', 1;

  IF @TitleRuleId IS NOT NULL
    SELECT @CategoryTreeCode = ISNULL(@CategoryTreeCode, CategoryTreeCode), @CategoryCode = ISNULL(@CategoryCode, CategoryCode)
    FROM pim.TitleRule WHERE TitleRuleId = @TitleRuleId;

  CREATE TABLE #Composed (ProductId bigint NOT NULL PRIMARY KEY, Title nvarchar(500) NOT NULL);

  ;WITH subtree AS
  (
    SELECT CategoryTreeCode, CategoryCode FROM canon.Category WHERE CategoryTreeCode = @CategoryTreeCode AND CategoryCode = @CategoryCode
    UNION ALL
    SELECT child.CategoryTreeCode, child.CategoryCode FROM subtree
    INNER JOIN canon.Category AS child ON child.CategoryTreeCode = subtree.CategoryTreeCode AND child.ParentCategoryCode = subtree.CategoryCode
  ),
  candidates AS
  (
    SELECT product.ProductId
    FROM canon.Product AS product
    WHERE product.OrganizationId = @OrganizationId AND product.IsActive = 1
      AND EXISTS (SELECT 1 FROM canon.ProductCategory AS productCategory WHERE productCategory.ProductId = product.ProductId)
      AND (@CategoryCode IS NULL OR EXISTS
        (SELECT 1 FROM canon.ProductCategory AS productCategory
         INNER JOIN canon.WebSite AS site ON site.WebSiteCode = productCategory.WebSite
         INNER JOIN canon.Category AS node ON node.CategoryTreeCode = site.CategoryTreeCode AND node.CategoryPath = productCategory.CategoryPath
         INNER JOIN subtree ON subtree.CategoryTreeCode = node.CategoryTreeCode AND subtree.CategoryCode = node.CategoryCode
         WHERE productCategory.ProductId = product.ProductId))
      AND (@CategoryCode IS NOT NULL OR @CategoryTreeCode IS NULL OR EXISTS
        (SELECT 1 FROM canon.ProductCategory AS productCategory
         INNER JOIN canon.WebSite AS site ON site.WebSiteCode = productCategory.WebSite
         WHERE productCategory.ProductId = product.ProductId AND site.CategoryTreeCode = @CategoryTreeCode))
      AND (@OnlyMissing = 0 OR NOT EXISTS
        (SELECT 1 FROM canon.ProductText AS textValue
         WHERE textValue.ProductId = product.ProductId AND textValue.TextType = N''WEB_TITLE'' AND LOWER(textValue.Lang) = @LanguageCode
           AND NULLIF(textValue.Value, N'''') IS NOT NULL))
  )
  INSERT #Composed (ProductId, Title)
  SELECT candidates.ProductId, composed.Title
  FROM candidates
  INNER JOIN pim.TitleRule AS titleRule ON titleRule.TitleRuleId = COALESCE(@TitleRuleId, pim.ResolveTitleRule(candidates.ProductId, @LanguageCode)) AND titleRule.IsActive = 1
  CROSS APPLY (SELECT Title = pim.ComposeTitle(candidates.ProductId, @LanguageCode, titleRule.Template, titleRule.Separator)) AS composed
  WHERE composed.Title IS NOT NULL;

  DECLARE @BatchId uniqueidentifier = NEWID();
  EXEC pim.SetChangeContext @ChangeSource = N''INTRANET'', @ChangedBy = @Actor, @BatchId = @BatchId,
    @Note = @Note;

  DECLARE @Written int = 0;
  BEGIN TRY
    BEGIN TRANSACTION;
    MERGE canon.ProductText AS target
    USING #Composed AS source ON target.ProductId = source.ProductId AND target.TextType = N''WEB_TITLE'' AND LOWER(target.Lang) = @LanguageCode
    WHEN MATCHED AND ISNULL(target.Value, N'''') <> source.Title THEN UPDATE SET Value = source.Title
    WHEN NOT MATCHED THEN INSERT (ProductId, Lang, TextType, Value) VALUES (source.ProductId, @LanguageCode, N''WEB_TITLE'', source.Title);
    SET @Written = @@ROWCOUNT;
    COMMIT TRANSACTION;
  END TRY
  BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    EXEC pim.ClearChangeContext;
    THROW;
  END CATCH;
  EXEC pim.ClearChangeContext;

  INSERT b2b.AuditLog (OrganizationId, EntityType, EntityKey, ActionCode, OldValueJson, NewValueJson, ChangedBy, ChangedUtc)
  VALUES (@OrganizationId, N''TitleRuleApply'', CONVERT(nvarchar(200), @BatchId), N''APPLY'', NULL,
    (SELECT @LanguageCode AS lang, @TitleRuleId AS ruleId, @CategoryTreeCode AS tree, @CategoryCode AS category, @OnlyMissing AS onlyMissing, @Written AS written FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
    @Actor, SYSUTCDATETIME());

  IF @Written > 0 EXEC val.RunValidation @OrganizationId = @OrganizationId;
  SELECT Written = @Written, Candidates = (SELECT COUNT(*) FROM #Composed);
END');

/* --- 5) Privzeto pravilo za svetila (zacetna vrstica, ne odlocitev) ----------------------- */

/* Ena predloga za drevo svetila_si, brez jezika (velja za vse), izpeljana iz starega
   LIGHTS_GENERAL: ime izdelka, kategorija 2. nivoja, svetlobni vir (razen vgrajenega),
   moc, barva svetlobe, barva. Je izklopljena (IsActive = 0): uporabnik jo pregleda v
   predogledu in vklopi sam — samodejni zapis nazivov brez pregleda ni sprejemljiv. */
IF NOT EXISTS (SELECT 1 FROM pim.TitleRule WHERE RuleCode = N'SVETILA_SPLOSNO')
  INSERT pim.TitleRule (RuleCode, Name, CategoryTreeCode, CategoryCode, LanguageCode, Template, IsActive, SortOrder, Note)
  VALUES (N'SVETILA_SPLOSNO', N'Svetila - splosno (izpeljano iz starega LIGHTS_GENERAL)', N'svetila_si', NULL, NULL,
    N'{ErpName} {Category:2} {Attr:Vrsta svetlobnega vira|omitIf:integr|omitIf:vgraj} {Attr:Nazivna moč|unit:W} {Attr:Temperatura barve|unit:K} {Attr:Prevladujoča barva|lower}',
    0, 100, N'Predlog iz migracije 149; vklopi po predogledu na /pravila/nazivi.');

/* --- dokaz ------------------------------------------------------------------------------ */

IF OBJECT_ID(N'pim.TitleRule', N'U') IS NULL THROW 51500, N'149: pim.TitleRule ni nastal.', 1;
IF OBJECT_ID(N'pim.ComposeTitle', N'FN') IS NULL THROW 51501, N'149: pim.ComposeTitle ni nastala.', 1;
IF pim.TitleYears(N'1', N'sl') <> N'1 leto' OR pim.TitleYears(N'2', N'sl') <> N'2 leti' OR pim.TitleYears(N'3', N'sl') <> N'3 leta'
  OR pim.TitleYears(N'5', N'sl') <> N'5 let' OR pim.TitleYears(N'12', N'sl') <> N'12 let' OR pim.TitleYears(N'2', N'en') <> N'2 years'
  THROW 51502, N'149: sklanjatev let ni pravilna.', 1;

/* Sestava nad resnicnim izdelkom: zeton brez vrednosti izpade, presledki se strnejo. */
DECLARE @ProbeProduct bigint = (SELECT MIN(ProductId) FROM canon.Product WHERE IsActive = 1);
IF @ProbeProduct IS NOT NULL
BEGIN
  DECLARE @Probe nvarchar(500) = pim.ComposeTitle(@ProbeProduct, N'sl', N'{ItemID}  {Attr:__NI_TAKEGA_ATRIBUTA__}   test {Attr:Garancija|years}', N' ');
  IF @Probe IS NULL OR @Probe NOT LIKE (SELECT ItemID + N' test%' FROM canon.Product WHERE ProductId = @ProbeProduct)
    THROW 51503, N'149: sestava naziva ne izpusti praznega zetona ali ne strne presledkov.', 1;
END;
EXEC intranet.GetTitleRules;
