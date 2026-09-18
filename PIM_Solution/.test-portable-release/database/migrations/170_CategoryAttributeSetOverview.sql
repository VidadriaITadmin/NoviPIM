/*
  170 — pregled naborov atributov po kategorijah: koliko in katere atribute ima katera kategorija,
  za vsako drevo (svetila_si, videlektro) posebej; množični vnos in kopiranje nabora.

  Uporabnik 2026-09-08: "Za atribute je se treba dodati neko novo stran pod nastavitve ... da povemo
  po kategorijah ali od svetil ali od videlektra koliko atributov in katerih ima katera kategorija
  in na podlagi tega lahko uporabniki spreminjajo in dodajajo po zelji ... in pa bova potem dodala
  kar nastavitve notri, kar bova prebrala od mastrov da bova naredila vsaj polovico."

  Register, dedovanje, validacija, izvoz in kartica so iz migracije 147 in se NE spreminjajo.
  Urejanje po eni kategoriji je ze na /nastavitve/kategorije (gumb Atributi); tam pa se ne vidi,
  katere kategorije nabor sploh imajo, koliko atributov nosijo in kje je luknja. To doda:

    1. intranet.GetCategoryAttributeSetTrees — drevesa s stevilom kategorij, kategorij z lastnim
       naborom, izdelkov in spletnim profilom (brez profila canon.SaveCategoryAttributeSet zavrne).

    2. intranet.GetCategoryAttributeSetOverview(drevo, iskanje, filtri) — vrstica na kategorijo:
       lastne in ucinkovite (podedovane) vrstice po ravneh, imena atributov v naboru, izdelki
       neposredno in v poddrevesu, koliko razlicnih atributov izdelki poddrevesa dejansko nosijo
       in koliko od teh nabor ne omenja. Drugi rezultat je povzetek drevesa.

    3. canon.SaveCategoryAttributeSetBulk — vec atributov za eno kategorijo v enem klicu (JSON
       [{code, level}]); atribut se sme navesti s kodo ALI s slovenskim imenom, ker bo uporabnik
       sezname lepil iz mastrov starega PIM-a, kjer so imena. Neznani se zavrnejo vsi naenkrat
       z naštetimi imeni, da ni petnajstih zaporednih napak. Vsaka vrstica gre skozi
       canon.SaveCategoryAttributeSet (147), zato pravila, zahteve in revizija ostanejo na enem
       mestu.

    4. canon.CopyCategoryAttributeSet — ucinkoviti nabor ene kategorije (tudi iz drugega drevesa)
       se prepise kot lastne vrstice ciljne kategorije. Obstojece lastne vrstice cilja ostanejo,
       razen ce @Overwrite = 1 (takrat dobijo raven iz vira).

  Migrator ne pozna locila GO; procedure so v EXEC(N'...').
*/

SET XACT_ABORT ON;

/* --- 1) Drevesa --------------------------------------------------------------------------- */

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetCategoryAttributeSetTrees
AS
BEGIN
  SET NOCOUNT ON;

  /* Zastavica lastnega nabora je izpeljana pred zdruzevanjem: SUM nad EXISTS SQL Server zavrne (130). */
  SELECT tree.CategoryTreeCode,
    Categories = COUNT(*),
    CategoriesWithOwnSet = SUM(tree.HasOwnSet),
    ProductCount = (SELECT COUNT(DISTINCT productCategory.ProductId)
      FROM canon.ProductCategory AS productCategory
      INNER JOIN canon.WebSite AS site ON site.WebSiteCode = productCategory.WebSite
      INNER JOIN canon.Product AS product ON product.ProductId = productCategory.ProductId AND product.IsActive = 1
      WHERE site.CategoryTreeCode = tree.CategoryTreeCode),
    WebSites = STUFF((SELECT N'', '' + site.WebSiteCode FROM canon.WebSite AS site
      WHERE site.CategoryTreeCode = tree.CategoryTreeCode AND site.IsActive = 1 ORDER BY site.SortOrder, site.WebSiteCode
      FOR XML PATH(N''''), TYPE).value(N''.'', N''nvarchar(max)''), 1, 2, N''''),
    WebProfileCode = (SELECT TOP (1) ProfileCode FROM val.ValidationProfile
      WHERE CategoryTreeCode = tree.CategoryTreeCode AND IsActive = 1 AND BlocksWeb = 1 ORDER BY ValidationProfileId)
  FROM (SELECT node.CategoryTreeCode, node.CategoryCode,
          HasOwnSet = CASE WHEN EXISTS (SELECT 1 FROM canon.CategoryAttributeSet AS setRow
            WHERE setRow.CategoryTreeCode = node.CategoryTreeCode AND setRow.CategoryCode = node.CategoryCode AND setRow.IsActive = 1) THEN 1 ELSE 0 END
        FROM canon.Category AS node) AS tree
  GROUP BY tree.CategoryTreeCode
  ORDER BY tree.CategoryTreeCode;
END');

/* --- 2) Pregled po kategorijah ------------------------------------------------------------- */

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetCategoryAttributeSetOverview
  @CategoryTreeCode nvarchar(100),
  @Search nvarchar(200) = NULL,
  @OnlyWithoutSet bit = 0,     /* samo kategorije brez ucinkovitega nabora */
  @OnlyWithProducts bit = 0,   /* samo kategorije, ki imajo izdelke v poddrevesu */
  @LevelNo int = NULL          /* samo ta raven drevesa */
AS
BEGIN
  SET NOCOUNT ON;

  IF NOT EXISTS (SELECT 1 FROM canon.Category WHERE CategoryTreeCode = @CategoryTreeCode)
    THROW 51700, N''Drevo kategorij ne obstaja.'', 1;

  SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'''');
  DECLARE @SearchLike nvarchar(410) = CASE WHEN @Search IS NULL THEN NULL ELSE
    N''%'' + REPLACE(REPLACE(REPLACE(@Search, N''['', N''[[]''), N''%'', N''[%]''), N''_'', N''[_]'') + N''%'' END;

  /* Izdelki po kategoriji: neposredno in v poddrevesu (izdelek se steje pri vsakem predniku). */
  CREATE TABLE #Assigned (ProductId bigint NOT NULL, CategoryCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
    PRIMARY KEY (ProductId, CategoryCode));
  INSERT #Assigned (ProductId, CategoryCode)
  SELECT DISTINCT productCategory.ProductId, node.CategoryCode
  FROM canon.ProductCategory AS productCategory
  INNER JOIN canon.WebSite AS site ON site.WebSiteCode = productCategory.WebSite AND site.CategoryTreeCode = @CategoryTreeCode
  INNER JOIN canon.Category AS node ON node.CategoryTreeCode = @CategoryTreeCode AND node.CategoryPath = productCategory.CategoryPath
  INNER JOIN canon.Product AS product ON product.ProductId = productCategory.ProductId AND product.IsActive = 1;

  CREATE TABLE #Subtree (ProductId bigint NOT NULL, CategoryCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
    PRIMARY KEY (CategoryCode, ProductId));
  ;WITH chain AS
  (
    SELECT assigned.ProductId, node.CategoryCode, node.ParentCategoryCode, 0 AS Depth
    FROM #Assigned AS assigned
    INNER JOIN canon.Category AS node ON node.CategoryTreeCode = @CategoryTreeCode AND node.CategoryCode = assigned.CategoryCode
    UNION ALL
    SELECT chain.ProductId, parent.CategoryCode, parent.ParentCategoryCode, chain.Depth + 1
    FROM chain
    INNER JOIN canon.Category AS parent ON parent.CategoryTreeCode = @CategoryTreeCode AND parent.CategoryCode = chain.ParentCategoryCode
    WHERE chain.Depth < 12
  )
  INSERT #Subtree (ProductId, CategoryCode)
  SELECT DISTINCT ProductId, CategoryCode FROM chain;

  /* Ucinkoviti nabor vsake kategorije (147: najblizji prednik zmaga). */
  CREATE TABLE #Effective (CategoryCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
    AttributeCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
    AttributeName nvarchar(400) COLLATE DATABASE_DEFAULT NOT NULL,
    Level nvarchar(20) COLLATE DATABASE_DEFAULT NOT NULL, IsInherited bit NOT NULL, SortOrder int NOT NULL,
    PRIMARY KEY (CategoryCode, AttributeCode));
  INSERT #Effective (CategoryCode, AttributeCode, AttributeName, Level, IsInherited, SortOrder)
  SELECT node.CategoryCode, effective.AttributeCode, COALESCE(translation.Name, effective.AttributeCode), effective.Level, effective.IsInherited, effective.SortOrder
  FROM canon.Category AS node
  CROSS APPLY canon.CategoryAttributeEffective(@CategoryTreeCode, node.CategoryCode) AS effective
  LEFT JOIN canon.AttributeTranslation AS translation ON translation.AttributeCode = effective.AttributeCode AND translation.LanguageCode = N''sl''
  WHERE node.CategoryTreeCode = @CategoryTreeCode;

  /* Atributi, ki jih izdelki poddrevesa dejansko nosijo (artikel nosi slovensko ime, 147). */
  CREATE TABLE #Used (CategoryCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
    AttributeName nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL, ProductsWithValue int NOT NULL,
    PRIMARY KEY (CategoryCode, AttributeName));
  INSERT #Used (CategoryCode, AttributeName, ProductsWithValue)
  SELECT subtree.CategoryCode, attributeValue.AttributeCode, COUNT(DISTINCT subtree.ProductId)
  FROM #Subtree AS subtree
  INNER JOIN canon.ProductAttribute AS attributeValue ON attributeValue.ProductId = subtree.ProductId
  WHERE NULLIF(attributeValue.Value, N'''') IS NOT NULL
  GROUP BY subtree.CategoryCode, attributeValue.AttributeCode;

  /* 1 — vrstica na kategorijo */
  SELECT node.CategoryTreeCode, node.CategoryCode, node.ParentCategoryCode, node.LevelNo, node.CategoryName, node.CategoryPath, node.IsActive,
    ProductCount = (SELECT COUNT(*) FROM #Assigned AS assigned WHERE assigned.CategoryCode = node.CategoryCode),
    DescendantProductCount = (SELECT COUNT(*) FROM #Subtree AS subtree WHERE subtree.CategoryCode = node.CategoryCode),
    ChildCount = (SELECT COUNT(*) FROM canon.Category AS child WHERE child.CategoryTreeCode = node.CategoryTreeCode AND child.ParentCategoryCode = node.CategoryCode),
    OwnRequired = (SELECT COUNT(*) FROM canon.CategoryAttributeSet AS own WHERE own.CategoryTreeCode = node.CategoryTreeCode AND own.CategoryCode = node.CategoryCode AND own.IsActive = 1 AND own.Level = N''REQUIRED''),
    OwnRecommended = (SELECT COUNT(*) FROM canon.CategoryAttributeSet AS own WHERE own.CategoryTreeCode = node.CategoryTreeCode AND own.CategoryCode = node.CategoryCode AND own.IsActive = 1 AND own.Level = N''RECOMMENDED''),
    OwnExcluded = (SELECT COUNT(*) FROM canon.CategoryAttributeSet AS own WHERE own.CategoryTreeCode = node.CategoryTreeCode AND own.CategoryCode = node.CategoryCode AND own.IsActive = 1 AND own.Level = N''EXCLUDED''),
    EffectiveRequired = (SELECT COUNT(*) FROM #Effective AS effective WHERE effective.CategoryCode = node.CategoryCode AND effective.Level = N''REQUIRED''),
    EffectiveRecommended = (SELECT COUNT(*) FROM #Effective AS effective WHERE effective.CategoryCode = node.CategoryCode AND effective.Level = N''RECOMMENDED''),
    EffectiveExcluded = (SELECT COUNT(*) FROM #Effective AS effective WHERE effective.CategoryCode = node.CategoryCode AND effective.Level = N''EXCLUDED''),
    InheritedCount = (SELECT COUNT(*) FROM #Effective AS effective WHERE effective.CategoryCode = node.CategoryCode AND effective.IsInherited = 1),
    EffectiveNames = STUFF((SELECT N'', '' + effective.AttributeName + CASE effective.Level WHEN N''REQUIRED'' THEN N''*'' ELSE N'''' END
      FROM #Effective AS effective WHERE effective.CategoryCode = node.CategoryCode AND effective.Level <> N''EXCLUDED''
      ORDER BY CASE effective.Level WHEN N''REQUIRED'' THEN 0 ELSE 1 END, effective.SortOrder, effective.AttributeName
      FOR XML PATH(N''''), TYPE).value(N''.'', N''nvarchar(max)''), 1, 2, N''''),
    UsedAttributeCount = (SELECT COUNT(*) FROM #Used AS used WHERE used.CategoryCode = node.CategoryCode),
    UsedNotInSetCount = (SELECT COUNT(*) FROM #Used AS used
      WHERE used.CategoryCode = node.CategoryCode
        AND NOT EXISTS (SELECT 1 FROM #Effective AS effective WHERE effective.CategoryCode = node.CategoryCode AND effective.AttributeName = used.AttributeName))
  FROM canon.Category AS node
  WHERE node.CategoryTreeCode = @CategoryTreeCode
    AND (@LevelNo IS NULL OR node.LevelNo = @LevelNo)
    AND (@SearchLike IS NULL OR node.CategoryPath LIKE @SearchLike OR node.CategoryCode LIKE @SearchLike)
    AND (@OnlyWithoutSet = 0 OR NOT EXISTS (SELECT 1 FROM #Effective AS effective WHERE effective.CategoryCode = node.CategoryCode AND effective.Level <> N''EXCLUDED''))
    AND (@OnlyWithProducts = 0 OR EXISTS (SELECT 1 FROM #Subtree AS subtree WHERE subtree.CategoryCode = node.CategoryCode))
  ORDER BY node.CategoryPath;

  /* 2 — povzetek drevesa (neodvisen od filtrov, da so stevilke primerljive med obiski) */
  SELECT
    Categories = (SELECT COUNT(*) FROM canon.Category WHERE CategoryTreeCode = @CategoryTreeCode),
    CategoriesWithOwnSet = (SELECT COUNT(DISTINCT CategoryCode) FROM canon.CategoryAttributeSet WHERE CategoryTreeCode = @CategoryTreeCode AND IsActive = 1),
    CategoriesWithEffectiveSet = (SELECT COUNT(DISTINCT CategoryCode) FROM #Effective WHERE Level <> N''EXCLUDED''),
    OwnRows = (SELECT COUNT(*) FROM canon.CategoryAttributeSet WHERE CategoryTreeCode = @CategoryTreeCode AND IsActive = 1),
    ProductCount = (SELECT COUNT(DISTINCT ProductId) FROM #Assigned),
    ProductsUnderSet = (SELECT COUNT(DISTINCT assigned.ProductId) FROM #Assigned AS assigned
      WHERE EXISTS (SELECT 1 FROM #Effective AS effective WHERE effective.CategoryCode = assigned.CategoryCode AND effective.Level <> N''EXCLUDED'')),
    AttributesInRegister = (SELECT COUNT(*) FROM canon.AttributeDefinition WHERE IsActive = 1),
    WebProfileCode = (SELECT TOP (1) ProfileCode FROM val.ValidationProfile
      WHERE CategoryTreeCode = @CategoryTreeCode AND IsActive = 1 AND BlocksWeb = 1 ORDER BY ValidationProfileId);
END');

/* --- 3) Mnozicni vnos ---------------------------------------------------------------------- */

EXEC(N'CREATE OR ALTER PROCEDURE canon.SaveCategoryAttributeSetBulk
  @CategoryTreeCode nvarchar(100),
  @CategoryCode nvarchar(200),
  @ItemsJson nvarchar(max),     /* [{"code":"GARANCIJA","level":"REQUIRED"}, {"code":"Napetost","level":null}] */
  @Actor nvarchar(200),
  @Saved int OUTPUT
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  SET @Saved = 0;

  IF @ItemsJson IS NULL OR ISJSON(@ItemsJson) = 0 THROW 51701, N''Seznam atributov ni veljaven JSON.'', 1;

  DECLARE @Item TABLE (Seq int IDENTITY(1,1) PRIMARY KEY, Given nvarchar(400) NOT NULL, Level nvarchar(20) NULL, AttributeCode nvarchar(200) NULL);
  INSERT @Item (Given, Level)
  SELECT LTRIM(RTRIM(item.code)), NULLIF(UPPER(LTRIM(RTRIM(item.level))), N'''')
  FROM OPENJSON(@ItemsJson) WITH (code nvarchar(400) N''$.code'', level nvarchar(20) N''$.level'') AS item
  WHERE NULLIF(LTRIM(RTRIM(item.code)), N'''') IS NOT NULL;

  IF NOT EXISTS (SELECT 1 FROM @Item) THROW 51702, N''Seznam atributov je prazen.'', 1;

  /* Koda ali slovensko ime; koda ima prednost. */
  UPDATE item SET AttributeCode = definition.AttributeCode
  FROM @Item AS item
  INNER JOIN canon.AttributeDefinition AS definition ON definition.AttributeCode = UPPER(item.Given) AND definition.IsActive = 1;

  UPDATE item SET AttributeCode = translation.AttributeCode
  FROM @Item AS item
  CROSS APPLY (SELECT TOP (1) translation.AttributeCode FROM canon.AttributeTranslation AS translation
    INNER JOIN canon.AttributeDefinition AS definition ON definition.AttributeCode = translation.AttributeCode AND definition.IsActive = 1
    WHERE translation.LanguageCode = N''sl'' AND translation.Name = item.Given
    ORDER BY translation.AttributeCode) AS translation
  WHERE item.AttributeCode IS NULL;

  DECLARE @Unknown nvarchar(max) = STUFF((SELECT N'', '' + Given FROM @Item WHERE AttributeCode IS NULL ORDER BY Seq
    FOR XML PATH(N''''), TYPE).value(N''.'', N''nvarchar(max)''), 1, 2, N'''');
  IF @Unknown IS NOT NULL
  BEGIN
    DECLARE @UnknownMessage nvarchar(4000) = CONCAT(N''Teh atributov ni v registru (koda ali slovensko ime): '', LEFT(@Unknown, 3500));
    THROW 51703, @UnknownMessage, 1;
  END;

  DECLARE @BadLevel nvarchar(max) = STUFF((SELECT N'', '' + Level FROM @Item WHERE Level IS NOT NULL AND Level NOT IN (N''REQUIRED'', N''RECOMMENDED'', N''EXCLUDED'') ORDER BY Seq
    FOR XML PATH(N''''), TYPE).value(N''.'', N''nvarchar(max)''), 1, 2, N'''');
  IF @BadLevel IS NOT NULL
  BEGIN
    DECLARE @BadLevelMessage nvarchar(4000) = CONCAT(N''Raven mora biti REQUIRED, RECOMMENDED ali EXCLUDED (prazna odstrani): '', LEFT(@BadLevel, 3500));
    THROW 51704, @BadLevelMessage, 1;
  END;

  BEGIN TRANSACTION;

  DECLARE @Seq int = 0, @AttributeCode nvarchar(200), @Level nvarchar(20);
  WHILE 1 = 1
  BEGIN
    /* Isti atribut dvakrat na seznamu: obvelja zadnja vrstica, ker gre po vrsti. */
    SELECT TOP (1) @Seq = Seq, @AttributeCode = AttributeCode, @Level = Level FROM @Item WHERE Seq > @Seq ORDER BY Seq;
    IF @@ROWCOUNT = 0 BREAK;
    EXEC canon.SaveCategoryAttributeSet @CategoryTreeCode, @CategoryCode, @AttributeCode, @Level, @Actor, NULL;
    SET @Saved += 1;
  END;

  COMMIT TRANSACTION;
END');

/* --- 4) Kopiranje nabora ------------------------------------------------------------------- */

EXEC(N'CREATE OR ALTER PROCEDURE canon.CopyCategoryAttributeSet
  @FromCategoryTreeCode nvarchar(100),
  @FromCategoryCode nvarchar(200),
  @ToCategoryTreeCode nvarchar(100),
  @ToCategoryCode nvarchar(200),
  @Actor nvarchar(200),
  @IncludeInherited bit = 1,   /* 1 = ucinkoviti nabor vira (tudi podedovano), 0 = samo lastne vrstice vira */
  @Overwrite bit = 0,          /* 1 = lastne vrstice cilja dobijo raven iz vira; 0 = obstojece ostanejo */
  @Copied int OUTPUT
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  SET @Copied = 0;

  IF @FromCategoryTreeCode = @ToCategoryTreeCode AND @FromCategoryCode = @ToCategoryCode
    THROW 51705, N''Vir in cilj kopiranja sta ista kategorija.'', 1;
  IF NOT EXISTS (SELECT 1 FROM canon.Category WHERE CategoryTreeCode = @FromCategoryTreeCode AND CategoryCode = @FromCategoryCode)
    THROW 51706, N''Izvorna kategorija ne obstaja.'', 1;

  DECLARE @Row TABLE (Seq int IDENTITY(1,1) PRIMARY KEY, AttributeCode nvarchar(200) NOT NULL, Level nvarchar(20) NOT NULL);
  INSERT @Row (AttributeCode, Level)
  SELECT effective.AttributeCode, effective.Level
  FROM canon.CategoryAttributeEffective(@FromCategoryTreeCode, @FromCategoryCode) AS effective
  WHERE (@IncludeInherited = 1 OR effective.IsInherited = 0)
    AND (@Overwrite = 1 OR NOT EXISTS (SELECT 1 FROM canon.CategoryAttributeSet AS existing
      WHERE existing.CategoryTreeCode = @ToCategoryTreeCode AND existing.CategoryCode = @ToCategoryCode
        AND existing.AttributeCode = effective.AttributeCode AND existing.IsActive = 1))
  ORDER BY effective.SortOrder, effective.AttributeCode;

  BEGIN TRANSACTION;

  DECLARE @Seq int = 0, @AttributeCode nvarchar(200), @Level nvarchar(20);
  WHILE 1 = 1
  BEGIN
    SELECT TOP (1) @Seq = Seq, @AttributeCode = AttributeCode, @Level = Level FROM @Row WHERE Seq > @Seq ORDER BY Seq;
    IF @@ROWCOUNT = 0 BREAK;
    EXEC canon.SaveCategoryAttributeSet @ToCategoryTreeCode, @ToCategoryCode, @AttributeCode, @Level, @Actor, NULL;
    SET @Copied += 1;
  END;

  COMMIT TRANSACTION;
END');
