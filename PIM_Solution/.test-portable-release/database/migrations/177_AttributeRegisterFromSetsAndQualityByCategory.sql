/*
  177 — atributi: ustvarjanje v registru iz nabora, manjkajoci atributi iz mastrov, kakovost po kategorijah.

  Uporabnik 2026-09-08: "naredi tako, da se bo ponudilo tudi ustvarjanje v registru, dodaj manjkajoce
  atribute iz mastrov, dodaj filter ... da bo po kategorijah — samo tako, da bo lahko vecnivojsko;
  atribute v izvozih bomo posebej dodali, ne sedaj."

    1. canon.EnsureAttributeDefinition(@Name, @Actor) — atribut po slovenskem imenu: ce obstaja (po kodi
       iz canon.AttributeCodeFromName ali po slovenskem imenu), vrne njegovo kodo; neaktivnega vklopi;
       sicer ga ustvari (TEXT, brez prevoda razen sl) in vpise revizijo. Do 177 je definicije ustvarjala
       samo migracija 122; canon.SaveAttributeDefinition zna le posodabljati.

    2. canon.ResolveAttributeNames(@NamesJson) — za seznam imen ali kod pove, katere so v registru in
       katere ne. Stran naborov s tem pred zapisom ponudi "ustvari v registru in dodaj".

    3. intranet.GetQualityByCategory(drevo, podjetje, resnost) — odprte zahteve po kategorijah drevesa,
       vecnivojsko: vsaka kategorija steje izdelke in tezave v sebi IN v vseh podkategorijah (veriga
       ParentCategoryCode). Pove izdelke, izdelke z odprto zahtevo, napake, opozorila in tri polja, ki
       najveckrat manjkajo.

    4. intranet.GetQualityIssues dobi @CategoryTreeCode / @CategoryCode: seznam napak po eni kategoriji
       in njenih podkategorijah. Vse ostalo je nespremenjeno od 102.

    5. Register dobi 33 atributov iz mastrov, ki jih do zdaj ni imel (docs/NABORI_ATRIBUTOV_IZ_MASTROV.md,
       "Kar ni preslikano": pravi atributi z >= 2 pojavitvama; "Vidna dimenzija" ostane izpuscena, ker je
       sestavljeno polje, njeni deli so ze preslikani v VISINA/SIRINA/DOLZINA). Nato nabori dobijo
       84 novih priporocenih vrstic v 30 kategorijah — po isti preslikavi mastrov kot 173
       (tools/Mastri), vse RECOMMENDED (odlocitev 174: opozorilo, ne napaka), skozi
       canon.SaveCategoryAttributeSetBulk po slovenskem imenu.

  Migrator ne pozna locila GO; procedure so v EXEC(N'...').
*/

SET XACT_ABORT ON;

/* --- 1) Atribut po imenu: najdi ali ustvari --------------------------------------------------- */

EXEC(N'CREATE OR ALTER PROCEDURE canon.EnsureAttributeDefinition
  @Name nvarchar(400),
  @Actor nvarchar(200),
  @AttributeCode nvarchar(200) OUTPUT
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  SET @Name = NULLIF(LTRIM(RTRIM(@Name)), N'''');
  SET @Actor = NULLIF(LTRIM(RTRIM(@Actor)), N'''');
  IF @Name IS NULL THROW 51760, N''Ime atributa je prazno.'', 1;
  IF @Actor IS NULL THROW 51761, N''Kdo ustvarja atribut, mora biti znano (Actor).'', 1;

  /* Najprej koda (uporabnik je lahko vpisal kodo), potem slovensko ime, potem koda iz imena. */
  SET @AttributeCode =
    COALESCE(
      (SELECT TOP (1) AttributeCode FROM canon.AttributeDefinition WHERE AttributeCode = UPPER(@Name)),
      (SELECT TOP (1) translation.AttributeCode FROM canon.AttributeTranslation AS translation
       INNER JOIN canon.AttributeDefinition AS definition ON definition.AttributeCode = translation.AttributeCode
       WHERE translation.LanguageCode = N''sl'' AND translation.Name = @Name ORDER BY definition.IsActive DESC, translation.AttributeCode),
      (SELECT TOP (1) AttributeCode FROM canon.AttributeDefinition WHERE AttributeCode = canon.AttributeCodeFromName(@Name)));

  IF @AttributeCode IS NOT NULL
  BEGIN
    IF EXISTS (SELECT 1 FROM canon.AttributeDefinition WHERE AttributeCode = @AttributeCode AND IsActive = 0)
    BEGIN
      UPDATE canon.AttributeDefinition SET IsActive = 1, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = @Actor WHERE AttributeCode = @AttributeCode;
      INSERT b2b.AuditLog (OrganizationId, EntityType, EntityKey, ActionCode, OldValueJson, NewValueJson, ChangedBy, ChangedUtc)
      VALUES (0, N''AttributeDefinition'', @AttributeCode, N''REACTIVATE'', NULL, (SELECT @Name AS name FOR JSON PATH, WITHOUT_ARRAY_WRAPPER), @Actor, SYSUTCDATETIME());
    END;
    IF NOT EXISTS (SELECT 1 FROM canon.AttributeTranslation WHERE AttributeCode = @AttributeCode AND LanguageCode = N''sl'')
      INSERT canon.AttributeTranslation (AttributeCode, LanguageCode, Name) VALUES (@AttributeCode, N''sl'', @Name);
    RETURN;
  END;

  SET @AttributeCode = canon.AttributeCodeFromName(@Name);
  IF NULLIF(@AttributeCode, N'''') IS NULL THROW 51762, N''Iz imena ni mogoce narediti kode atributa.'', 1;

  BEGIN TRANSACTION;
  INSERT canon.AttributeDefinition (AttributeCode, DataType, IsTranslatable, IsUnitCandidate, IsActive, UpdatedUtc, UpdatedBy, Note)
  VALUES (@AttributeCode, N''TEXT'', 0, CASE WHEN @Name LIKE N''Enota %'' THEN 1 ELSE 0 END, 1, SYSUTCDATETIME(), @Actor, CONCAT(N''Ustvarjeno iz imena: '', @Name));
  INSERT canon.AttributeTranslation (AttributeCode, LanguageCode, Name) VALUES (@AttributeCode, N''sl'', @Name);
  INSERT b2b.AuditLog (OrganizationId, EntityType, EntityKey, ActionCode, OldValueJson, NewValueJson, ChangedBy, ChangedUtc)
  VALUES (0, N''AttributeDefinition'', @AttributeCode, N''ADD'', NULL, (SELECT @Name AS name FOR JSON PATH, WITHOUT_ARRAY_WRAPPER), @Actor, SYSUTCDATETIME());
  COMMIT TRANSACTION;
END');

/* --- 2) Katera imena so v registru ----------------------------------------------------------- */

EXEC(N'CREATE OR ALTER PROCEDURE canon.ResolveAttributeNames
  @NamesJson nvarchar(max)     /* ["Garancija", "NAPETOST", "Neznano ime"] */
AS
BEGIN
  SET NOCOUNT ON;
  IF @NamesJson IS NULL OR ISJSON(@NamesJson) = 0 THROW 51763, N''Seznam imen ni veljaven JSON.'', 1;
  SELECT Given = given.Name,
    AttributeCode = COALESCE(byCode.AttributeCode, byName.AttributeCode),
    AttributeName = COALESCE(codeName.Name, byName.Name, given.Name),
    ProposedCode = canon.AttributeCodeFromName(given.Name)
  FROM (SELECT DISTINCT Name = LTRIM(RTRIM(value)) FROM OPENJSON(@NamesJson) WHERE NULLIF(LTRIM(RTRIM(value)), N'''') IS NOT NULL) AS given
  OUTER APPLY (SELECT TOP (1) AttributeCode FROM canon.AttributeDefinition WHERE AttributeCode = UPPER(given.Name) AND IsActive = 1) AS byCode
  OUTER APPLY (SELECT TOP (1) translation.AttributeCode, translation.Name FROM canon.AttributeTranslation AS translation
    INNER JOIN canon.AttributeDefinition AS definition ON definition.AttributeCode = translation.AttributeCode AND definition.IsActive = 1
    WHERE translation.LanguageCode = N''sl'' AND translation.Name = given.Name ORDER BY translation.AttributeCode) AS byName
  OUTER APPLY (SELECT TOP (1) Name FROM canon.AttributeTranslation WHERE AttributeCode = byCode.AttributeCode AND LanguageCode = N''sl'') AS codeName
  ORDER BY given.Name;
END');

/* --- 3) Kakovost po kategorijah, vecnivojsko ------------------------------------------------- */

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetQualityByCategory
  @CategoryTreeCode nvarchar(100),
  @OrganizationId int = NULL,       /* NULL = vsa podjetja */
  @Severity nvarchar(20) = NULL     /* ERROR | WARNING | NULL = obe */
AS
BEGIN
  SET NOCOUNT ON;
  IF NOT EXISTS (SELECT 1 FROM canon.Category WHERE CategoryTreeCode = @CategoryTreeCode)
    THROW 51764, N''Drevo kategorij ne obstaja.'', 1;
  SET @Severity = NULLIF(UPPER(LTRIM(RTRIM(@Severity))), N'''');
  IF @Severity NOT IN (N''ERROR'', N''WARNING'') SET @Severity = NULL;

  /* Izdelek -> kategorija, po vseh spletnih mestih drevesa (pot v jeziku mesta). */
  CREATE TABLE #Assigned (ProductId bigint NOT NULL, CategoryCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL, PRIMARY KEY (ProductId, CategoryCode));
  INSERT #Assigned (ProductId, CategoryCode)
  SELECT DISTINCT productCategory.ProductId, translated.CategoryCode
  FROM canon.ProductCategory AS productCategory
  INNER JOIN canon.WebSite AS site ON site.WebSiteCode = productCategory.WebSite AND site.CategoryTreeCode = @CategoryTreeCode
  INNER JOIN canon.CategoryPathTranslated AS translated ON translated.CategoryTreeCode = @CategoryTreeCode AND translated.LanguageCode = site.LanguageCode AND translated.CategoryPath = productCategory.CategoryPath
  INNER JOIN canon.Product AS product ON product.ProductId = productCategory.ProductId AND product.IsActive = 1
  WHERE (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId);

  /* Vecnivojsko: izdelek se steje pri kategoriji in pri vsakem predniku. */
  CREATE TABLE #Subtree (ProductId bigint NOT NULL, CategoryCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL, PRIMARY KEY (CategoryCode, ProductId));
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
  INSERT #Subtree (ProductId, CategoryCode) SELECT DISTINCT ProductId, CategoryCode FROM chain;

  /* Odprte zahteve izdelkov drevesa (ena vrstica na izdelek in polje). */
  /* Brez primarnega kljuca: FieldCode je nvarchar(450) in kljuc bi presegel 900 bajtov (opozorilo 1946). */
  CREATE TABLE #Issue (ProductId bigint NOT NULL, FieldCode nvarchar(450) COLLATE DATABASE_DEFAULT NOT NULL, Severity nvarchar(20) COLLATE DATABASE_DEFAULT NOT NULL);
  CREATE INDEX IX_Issue_Product ON #Issue (ProductId) INCLUDE (Severity);
  INSERT #Issue (ProductId, FieldCode, Severity)
  SELECT DISTINCT issue.ProductId, COALESCE(requirement.FieldCode, issue.IssueCode), COALESCE(requirement.Severity, N''ERROR'')
  FROM val.ProductIssue AS issue
  LEFT JOIN val.FieldRequirement AS requirement ON requirement.FieldRequirementId = issue.FieldRequirementId
  WHERE issue.IsActive = 1
    AND EXISTS (SELECT 1 FROM #Assigned AS assigned WHERE assigned.ProductId = issue.ProductId)
    AND (@Severity IS NULL OR COALESCE(requirement.Severity, N''ERROR'') = @Severity);

  /* Tri najpogostejsa polja na kategorijo. */
  CREATE TABLE #TopField (CategoryCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL, FieldCode nvarchar(450) COLLATE DATABASE_DEFAULT NOT NULL, Products int NOT NULL, Rank int NOT NULL);
  INSERT #TopField (CategoryCode, FieldCode, Products, Rank)
  SELECT CategoryCode, FieldCode, Products, Rank FROM
  (
    SELECT subtree.CategoryCode, issue.FieldCode, Products = COUNT(DISTINCT subtree.ProductId),
      Rank = ROW_NUMBER() OVER (PARTITION BY subtree.CategoryCode ORDER BY COUNT(DISTINCT subtree.ProductId) DESC, issue.FieldCode)
    FROM #Subtree AS subtree
    INNER JOIN #Issue AS issue ON issue.ProductId = subtree.ProductId
    GROUP BY subtree.CategoryCode, issue.FieldCode
  ) AS ranked
  WHERE Rank <= 3;

  SELECT node.CategoryTreeCode, node.CategoryCode, node.ParentCategoryCode, node.LevelNo, node.CategoryName, node.CategoryPath, node.IsActive,
    ChildCount = (SELECT COUNT(*) FROM canon.Category AS child WHERE child.CategoryTreeCode = node.CategoryTreeCode AND child.ParentCategoryCode = node.CategoryCode),
    ProductCount = (SELECT COUNT(*) FROM #Assigned AS assigned WHERE assigned.CategoryCode = node.CategoryCode),
    SubtreeProductCount = (SELECT COUNT(*) FROM #Subtree AS subtree WHERE subtree.CategoryCode = node.CategoryCode),
    ProductsWithIssue = (SELECT COUNT(*) FROM #Subtree AS subtree WHERE subtree.CategoryCode = node.CategoryCode AND EXISTS (SELECT 1 FROM #Issue AS issue WHERE issue.ProductId = subtree.ProductId)),
    ProductsWithError = (SELECT COUNT(*) FROM #Subtree AS subtree WHERE subtree.CategoryCode = node.CategoryCode AND EXISTS (SELECT 1 FROM #Issue AS issue WHERE issue.ProductId = subtree.ProductId AND issue.Severity = N''ERROR'')),
    ErrorCount = (SELECT COUNT(*) FROM #Subtree AS subtree INNER JOIN #Issue AS issue ON issue.ProductId = subtree.ProductId AND issue.Severity = N''ERROR'' WHERE subtree.CategoryCode = node.CategoryCode),
    WarningCount = (SELECT COUNT(*) FROM #Subtree AS subtree INNER JOIN #Issue AS issue ON issue.ProductId = subtree.ProductId AND issue.Severity = N''WARNING'' WHERE subtree.CategoryCode = node.CategoryCode),
    TopFields = STUFF((SELECT N''; '' + top3.FieldCode + N'' ('' + CONVERT(nvarchar(20), top3.Products) + N'')''
      FROM #TopField AS top3 WHERE top3.CategoryCode = node.CategoryCode ORDER BY top3.Rank
      FOR XML PATH(N''''), TYPE).value(N''.'', N''nvarchar(max)''), 1, 2, N'''')
  FROM canon.Category AS node
  WHERE node.CategoryTreeCode = @CategoryTreeCode
  ORDER BY node.CategoryPath;
END');

/* --- 4) Napake validacije z obsegom kategorije ------------------------------------------------ */

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetQualityIssues
  @OrganizationId int,
  @Skip int = 0,
  @Take int = 50,
  @Search nvarchar(200) = NULL,
  @ProfileCode nvarchar(100) = NULL,
  @Severity nvarchar(20) = NULL,
  @Blocks nvarchar(20) = NULL,
  @FieldCode nvarchar(200) = NULL,
  @Language nvarchar(20) = N''sl'',
  @CategoryTreeCode nvarchar(100) = NULL,   /* 177: obseg = kategorija in vse njene podkategorije */
  @CategoryCode nvarchar(200) = NULL
AS
BEGIN
  SET NOCOUNT ON;

  SET @Skip = CASE WHEN @Skip < 0 THEN 0 ELSE @Skip END;
  SET @Take = CASE WHEN @Take < 1 THEN 50 WHEN @Take > 200 THEN 200 ELSE @Take END;
  SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'''');
  SET @ProfileCode = NULLIF(LTRIM(RTRIM(@ProfileCode)), N'''');
  SET @Severity = NULLIF(UPPER(LTRIM(RTRIM(@Severity))), N'''');
  SET @Blocks = NULLIF(UPPER(LTRIM(RTRIM(@Blocks))), N'''');
  SET @FieldCode = NULLIF(LTRIM(RTRIM(@FieldCode)), N'''');
  SET @Language = COALESCE(NULLIF(LTRIM(RTRIM(@Language)), N''''), N''sl'');
  IF @Severity NOT IN (N''ERROR'', N''WARNING'') SET @Severity = NULL;
  IF @Blocks NOT IN (N''ERP'', N''WEB'', N''NONE'') SET @Blocks = NULL;

  /* 177: vecnivojski obseg kategorije. Izdelek je v obsegu, kadar je njegova pot na kateremkoli
     spletnem mestu drevesa pot izbrane kategorije ali katere od njenih potomk (po ParentCategoryCode,
     ne po nizu poti, zato velja v vseh jezikih prek canon.CategoryPathTranslated). */
  SET @CategoryTreeCode = NULLIF(LTRIM(RTRIM(@CategoryTreeCode)), N'''');
  SET @CategoryCode = NULLIF(LTRIM(RTRIM(@CategoryCode)), N'''');
  IF @CategoryTreeCode IS NULL SET @CategoryCode = NULL;
  CREATE TABLE #Scope (ProductId bigint NOT NULL PRIMARY KEY);
  IF @CategoryCode IS NOT NULL
  BEGIN
    ;WITH subtree AS
    (
      SELECT CategoryCode FROM canon.Category WHERE CategoryTreeCode = @CategoryTreeCode AND CategoryCode = @CategoryCode
      UNION ALL
      SELECT child.CategoryCode FROM subtree
      INNER JOIN canon.Category AS child ON child.CategoryTreeCode = @CategoryTreeCode AND child.ParentCategoryCode = subtree.CategoryCode
    )
    INSERT #Scope (ProductId)
    SELECT DISTINCT productCategory.ProductId
    FROM subtree
    INNER JOIN canon.CategoryPathTranslated AS translated ON translated.CategoryTreeCode = @CategoryTreeCode AND translated.CategoryCode = subtree.CategoryCode
    INNER JOIN canon.WebSite AS site ON site.CategoryTreeCode = @CategoryTreeCode AND site.LanguageCode = translated.LanguageCode
    INNER JOIN canon.ProductCategory AS productCategory ON productCategory.WebSite = site.WebSiteCode AND productCategory.CategoryPath = translated.CategoryPath;
  END;

  DECLARE @Like nvarchar(210) = CASE WHEN @Search IS NULL THEN NULL ELSE N''%'' + @Search + N''%'' END;

  /* Stranicenje je po izdelku, ne po tezavi: tezav je 3,0 milijona, izdelkov z odprto tezavo
     pa 96.847 v najvecjem podjetju. Urednik dela po izdelkih, zato je izdelek tudi enota strani. */
  CREATE TABLE #Page (ProductId bigint NOT NULL PRIMARY KEY, ItemID nvarchar(100) NOT NULL);

  INSERT #Page (ProductId, ItemID)
  SELECT product.ProductId, product.ItemID
  FROM canon.Product AS product
  WHERE product.OrganizationId = @OrganizationId
    AND (@Like IS NULL OR product.ItemID LIKE @Like OR product.EAN LIKE @Like)
    AND (@CategoryCode IS NULL OR EXISTS (SELECT 1 FROM #Scope AS scope WHERE scope.ProductId = product.ProductId))
    AND EXISTS
    (
      SELECT 1
      FROM val.ProductIssue AS issueValue
      INNER JOIN val.ValidationProfile AS profileValue ON profileValue.ValidationProfileId = issueValue.ValidationProfileId
      LEFT JOIN val.FieldRequirement AS requirement ON requirement.FieldRequirementId = issueValue.FieldRequirementId
      WHERE issueValue.ProductId = product.ProductId AND issueValue.IsActive = 1
        AND (@ProfileCode IS NULL OR profileValue.ProfileCode = @ProfileCode)
        AND (@Severity IS NULL OR requirement.Severity = @Severity)
        AND (@FieldCode IS NULL OR requirement.FieldCode = @FieldCode)
        AND
        (
          @Blocks IS NULL
          OR (@Blocks = N''ERP'' AND profileValue.BlocksErp = 1)
          OR (@Blocks = N''WEB'' AND profileValue.BlocksWeb = 1)
          OR (@Blocks = N''NONE'' AND profileValue.BlocksErp = 0 AND profileValue.BlocksWeb = 0)
        )
    )
  ORDER BY product.ItemID
  OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY
  OPTION (RECOMPILE);

  SELECT product.ProductId, product.ItemID, product.EAN,
    Name = COALESCE(webTitle.Value, erpTitle.Value, product.ItemID),
    product.ValidationStatus, product.Completeness, product.IsActive, product.WebPublish,
    IssueCount = counters.IssueCount, ErrorCount = counters.ErrorCount,
    WarningCount = counters.WarningCount, BlockingErpCount = counters.BlockingErpCount,
    BlockingWebCount = counters.BlockingWebCount, LastDetectedUtc = counters.LastDetectedUtc
  FROM #Page AS pageRow
  INNER JOIN canon.Product AS product ON product.ProductId = pageRow.ProductId
  CROSS APPLY
  (
    SELECT IssueCount = COUNT_BIG(*),
      ErrorCount = SUM(CASE WHEN requirement.Severity = N''ERROR'' THEN 1 ELSE 0 END),
      WarningCount = SUM(CASE WHEN requirement.Severity = N''WARNING'' THEN 1 ELSE 0 END),
      BlockingErpCount = SUM(CASE WHEN profileValue.BlocksErp = 1 THEN 1 ELSE 0 END),
      BlockingWebCount = SUM(CASE WHEN profileValue.BlocksWeb = 1 THEN 1 ELSE 0 END),
      LastDetectedUtc = MAX(issueValue.LastDetectedUtc)
    FROM val.ProductIssue AS issueValue
    INNER JOIN val.ValidationProfile AS profileValue ON profileValue.ValidationProfileId = issueValue.ValidationProfileId
    LEFT JOIN val.FieldRequirement AS requirement ON requirement.FieldRequirementId = issueValue.FieldRequirementId
    WHERE issueValue.ProductId = product.ProductId AND issueValue.IsActive = 1
  ) AS counters
  OUTER APPLY
  (
    SELECT TOP (1) textValue.Value FROM canon.ProductText AS textValue
    WHERE textValue.ProductId = product.ProductId AND textValue.TextType = N''WEB_TITLE''
    ORDER BY CASE WHEN textValue.Lang = @Language THEN 0 WHEN textValue.Lang = N''sl'' THEN 1 ELSE 2 END, textValue.Lang
  ) AS webTitle
  OUTER APPLY
  (
    SELECT TOP (1) textValue.Value FROM canon.ProductText AS textValue
    WHERE textValue.ProductId = product.ProductId AND textValue.TextType = N''TITLE_ERP''
    ORDER BY CASE WHEN textValue.Lang = @Language THEN 0 WHEN textValue.Lang = N''sl'' THEN 1 ELSE 2 END, textValue.Lang
  ) AS erpTitle
  ORDER BY product.ItemID;

  /* Tezave samo za izdelke na strani: brez tega bi seznam znova prebral milijone vrstic. */
  SELECT issueValue.ProductIssueId, issueValue.ProductId,
    profileValue.ProfileCode, profileValue.BlocksErp, profileValue.BlocksWeb,
    FieldCode = requirement.FieldCode,
    Severity = COALESCE(requirement.Severity, N''ERROR''),
    issueValue.IssueCode, issueValue.Message,
    issueValue.FirstDetectedUtc, issueValue.LastDetectedUtc
  FROM #Page AS pageRow
  INNER JOIN val.ProductIssue AS issueValue ON issueValue.ProductId = pageRow.ProductId AND issueValue.IsActive = 1
  INNER JOIN val.ValidationProfile AS profileValue ON profileValue.ValidationProfileId = issueValue.ValidationProfileId
  LEFT JOIN val.FieldRequirement AS requirement ON requirement.FieldRequirementId = issueValue.FieldRequirementId
  WHERE (@ProfileCode IS NULL OR profileValue.ProfileCode = @ProfileCode)
    AND (@Severity IS NULL OR requirement.Severity = @Severity)
    AND (@FieldCode IS NULL OR requirement.FieldCode = @FieldCode)
    AND
    (
      @Blocks IS NULL
      OR (@Blocks = N''ERP'' AND profileValue.BlocksErp = 1)
      OR (@Blocks = N''WEB'' AND profileValue.BlocksWeb = 1)
      OR (@Blocks = N''NONE'' AND profileValue.BlocksErp = 0 AND profileValue.BlocksWeb = 0)
    )
  ORDER BY pageRow.ItemID, profileValue.ProfileCode, requirement.FieldCode
  OPTION (RECOMPILE);

  SELECT TotalCount = COUNT_BIG(*)
  FROM canon.Product AS product
  WHERE product.OrganizationId = @OrganizationId
    AND (@Like IS NULL OR product.ItemID LIKE @Like OR product.EAN LIKE @Like)
    AND (@CategoryCode IS NULL OR EXISTS (SELECT 1 FROM #Scope AS scope WHERE scope.ProductId = product.ProductId))
    AND EXISTS
    (
      SELECT 1
      FROM val.ProductIssue AS issueValue
      INNER JOIN val.ValidationProfile AS profileValue ON profileValue.ValidationProfileId = issueValue.ValidationProfileId
      LEFT JOIN val.FieldRequirement AS requirement ON requirement.FieldRequirementId = issueValue.FieldRequirementId
      WHERE issueValue.ProductId = product.ProductId AND issueValue.IsActive = 1
        AND (@ProfileCode IS NULL OR profileValue.ProfileCode = @ProfileCode)
        AND (@Severity IS NULL OR requirement.Severity = @Severity)
        AND (@FieldCode IS NULL OR requirement.FieldCode = @FieldCode)
        AND
        (
          @Blocks IS NULL
          OR (@Blocks = N''ERP'' AND profileValue.BlocksErp = 1)
          OR (@Blocks = N''WEB'' AND profileValue.BlocksWeb = 1)
          OR (@Blocks = N''NONE'' AND profileValue.BlocksErp = 0 AND profileValue.BlocksWeb = 0)
        )
    )
  OPTION (RECOMPILE);

  DROP TABLE #Page;
  DROP TABLE #Scope;
END;');

/* --- 5) Register: atributi iz mastrov ---------------------------------------------------------- */

DECLARE @Attribute TABLE (Seq int IDENTITY(1,1) PRIMARY KEY, Name nvarchar(400) NOT NULL);
INSERT @Attribute (Name) VALUES
  (N'Upravljanje'),
  (N'Vključuje napajalnik'),
  (N'Število polov'),
  (N'Oblika'),
  (N'Material pokrova'),
  (N'Tip napajalnika'),
  (N'Tehnologija'),
  (N'RAL'),
  (N'Otroška zaščita'),
  (N'Pokrov'),
  (N'Barva vrat'),
  (N'Dimenzija varovalke'),
  (N'Dolžina kabla'),
  (N'Dolžina varovalke'),
  (N'Končni navoj'),
  (N'Napajanje'),
  (N'Predpripravljeni vhodi'),
  (N'Presek kabla max'),
  (N'Presek kabla min'),
  (N'Priključne sponke'),
  (N'Priklop'),
  (N'Pritrditev'),
  (N'Prosojnost'),
  (N'Sponka PE/N'),
  (N'Temperaturna obstojnost'),
  (N'Velikost doze'),
  (N'Velikost uvodnice'),
  (N'Vrsta doze'),
  (N'Za LED profil'),
  (N'Širina modula'),
  (N'Širina varovalke'),
  (N'Število modulov'),
  (N'Število vrst');

DECLARE @Seq int = 0, @Name nvarchar(400), @Code nvarchar(200), @Created int = 0;
WHILE 1 = 1
BEGIN
  SELECT TOP (1) @Seq = Seq, @Name = Name FROM @Attribute WHERE Seq > @Seq ORDER BY Seq;
  IF @@ROWCOUNT = 0 BREAK;
  EXEC canon.EnsureAttributeDefinition @Name, N'mastri 2026-09-08', @Code OUTPUT;
  SET @Created += 1;
END;
PRINT CONCAT(N'177: atributov iz mastrov v registru: ', @Created);

/* --- 6) Nabori: nove priporocene vrstice po slovenskem imenu ---------------------------------- */

DECLARE @Seed TABLE (Seq int IDENTITY(1,1) PRIMARY KEY, CategoryTreeCode nvarchar(100), CategoryCode nvarchar(200), AttributeName nvarchar(400), Masters nvarchar(400));
INSERT @Seed (CategoryTreeCode, CategoryCode, AttributeName, Masters) VALUES
  (N'svetila_si', N'notranja_svetila', N'Material pokrova', N'znamke:2A1+2A7+2A9'),
  (N'svetila_si', N'notranja_svetila', N'Tehnologija', N'znamke:2A6+2A9'),
  (N'svetila_si', N'notranja_svetila', N'Tip napajalnika', N'znamke:2A1+2A6'),
  (N'svetila_si', N'notranja_svetila', N'Upravljanje', N'znamke:2A1+2A6+2A13'),
  (N'svetila_si', N'notranja_svetila', N'Vključuje napajalnik', N'znamke:2A1+2A6+2A9'),
  (N'svetila_si', N'svetlobni_viri_in_dodatki', N'Prosojnost', N'2G1,2G2'),
  (N'svetila_si', N'svetlobni_viri_in_dodatki', N'Tehnologija', N'2G2'),
  (N'svetila_si', N'svetlobni_viri_in_dodatki___napajalniki', N'Priklop', N'2E'),
  (N'svetila_si', N'svetlobni_viri_in_dodatki___napajalniki', N'Tip napajalnika', N'2E'),
  (N'svetila_si', N'svetlobni_viri_in_dodatki___napajalniki', N'Upravljanje', N'2E'),
  (N'svetila_si', N'tracni_sistemi___1_fazni_24v_nano_lvm___led_svetilke', N'Upravljanje', N'2H2'),
  (N'svetila_si', N'tracni_sistemi___1_fazni_24v_nano_lvm___led_svetilke', N'Vključuje napajalnik', N'2H2'),
  (N'svetila_si', N'tracni_sistemi___1_fazni_48v_lvm___led_svetilke', N'Upravljanje', N'2H2'),
  (N'svetila_si', N'tracni_sistemi___1_fazni_48v_lvm___led_svetilke', N'Vključuje napajalnik', N'2H2'),
  (N'svetila_si', N'tracni_sistemi___1_fazni_48v_ut_lvm___led_svetilke', N'Upravljanje', N'2H2'),
  (N'svetila_si', N'tracni_sistemi___1_fazni_48v_ut_lvm___led_svetilke', N'Vključuje napajalnik', N'2H2'),
  (N'svetila_si', N'tracni_sistemi___1_fazni_profile___svetila', N'Upravljanje', N'2H2'),
  (N'svetila_si', N'tracni_sistemi___1_fazni_profile___svetila', N'Vključuje napajalnik', N'2H2'),
  (N'svetila_si', N'tracni_sistemi___3_fazni_ctls___svetila', N'Upravljanje', N'2H2'),
  (N'svetila_si', N'tracni_sistemi___3_fazni_ctls___svetila', N'Vključuje napajalnik', N'2H2'),
  (N'svetila_si', N'zunanja_svetila', N'Material pokrova', N'znamke:2A1+2A7+2A9'),
  (N'svetila_si', N'zunanja_svetila', N'Tehnologija', N'znamke:2A6+2A9'),
  (N'svetila_si', N'zunanja_svetila', N'Tip napajalnika', N'znamke:2A1+2A6'),
  (N'svetila_si', N'zunanja_svetila', N'Upravljanje', N'znamke:2A1+2A6+2A13'),
  (N'svetila_si', N'zunanja_svetila', N'Vključuje napajalnik', N'znamke:2A1+2A6+2A9'),
  (N'svetila_si', N'zunanja_svetila___prenosna_svetila', N'Upravljanje', N'2A3'),
  (N'svetila_si', N'zunanja_svetila___prenosna_svetila', N'Vključuje napajalnik', N'2A3'),
  (N'videlektro', N'instalacije___elektro_omare_in_razdelilniki', N'Barva vrat', N'1H,1H2'),
  (N'videlektro', N'instalacije___elektro_omare_in_razdelilniki', N'Dimenzija varovalke', N'1H,1H2'),
  (N'videlektro', N'instalacije___elektro_omare_in_razdelilniki', N'Dolžina varovalke', N'1H,1H2'),
  (N'videlektro', N'instalacije___elektro_omare_in_razdelilniki', N'Širina varovalke', N'1H,1H2'),
  (N'videlektro', N'instalacije___elektro_omare_in_razdelilniki', N'Sponka PE/N', N'1H,1H2'),
  (N'videlektro', N'instalacije___elektro_omare_in_razdelilniki', N'Število modulov', N'1H,1H2'),
  (N'videlektro', N'instalacije___elektro_omare_in_razdelilniki', N'Število vrst', N'1H,1H2'),
  (N'videlektro', N'instalacije___kabli_in_vodniki', N'Dolžina kabla', N'1A6'),
  (N'videlektro', N'instalacije___kabli_in_vodniki___kabelski_koncniki_in_spojke', N'Presek kabla max', N'1A3'),
  (N'videlektro', N'instalacije___kabli_in_vodniki___kabelski_koncniki_in_spojke', N'Presek kabla min', N'1A3'),
  (N'videlektro', N'instalacije___kabli_in_vodniki___kabelski_spoji_in_zalivke', N'Oblika', N'1A1,1A2'),
  (N'videlektro', N'instalacije___kabli_in_vodniki___kabelski_spoji_in_zalivke', N'Presek kabla max', N'1A1'),
  (N'videlektro', N'instalacije___kabli_in_vodniki___kabelski_spoji_in_zalivke', N'Presek kabla min', N'1A1'),
  (N'videlektro', N'instalacije___kabli_in_vodniki___kabelski_spojni_material', N'Presek kabla max', N'1A4'),
  (N'videlektro', N'instalacije___kabli_in_vodniki___kabelski_spojni_material', N'Presek kabla min', N'1A4'),
  (N'videlektro', N'instalacije___kabli_in_vodniki___kabelski_spojni_material', N'Število polov', N'1A4'),
  (N'videlektro', N'instalacije___kabli_in_vodniki___kabelski_spojni_material', N'Temperaturna obstojnost', N'1A4'),
  (N'videlektro', N'instalacije___kabli_in_vodniki___podaljski_in_razdelilci', N'Dolžina kabla', N'1A5'),
  (N'videlektro', N'instalacije___kabli_in_vodniki___podaljski_in_razdelilci', N'Otroška zaščita', N'1A5'),
  (N'videlektro', N'instalacije___omare_in_stikalna_tehnika___instalacijski_odklopniki', N'Pritrditev', N'1B1'),
  (N'videlektro', N'instalacije___omare_in_stikalna_tehnika___instalacijski_odklopniki', N'Širina modula', N'1B1'),
  (N'videlektro', N'instalacije___omare_in_stikalna_tehnika___instalacijski_odklopniki', N'Število polov', N'1B1'),
  (N'videlektro', N'instalacije___omare_in_stikalna_tehnika___zbiralke_in_pribor', N'Presek kabla max', N'1B2'),
  (N'videlektro', N'instalacije___omare_in_stikalna_tehnika___zbiralke_in_pribor', N'Presek kabla min', N'1B2'),
  (N'videlektro', N'instalacije___omare_in_stikalna_tehnika___zbiralke_in_pribor', N'Število polov', N'1B2'),
  (N'videlektro', N'instalacije___razvodne_doze', N'Predpripravljeni vhodi', N'1G,1G2'),
  (N'videlektro', N'instalacije___razvodne_doze', N'Priključne sponke', N'1G,1G2'),
  (N'videlektro', N'instalacije___razvodne_doze', N'RAL', N'1G,1G2'),
  (N'videlektro', N'instalacije___razvodne_doze', N'Velikost doze', N'1G,1G2'),
  (N'videlektro', N'instalacije___razvodne_doze', N'Velikost uvodnice', N'1G,1G2'),
  (N'videlektro', N'instalacije___razvodne_doze', N'Vrsta doze', N'1G,1G2'),
  (N'videlektro', N'instalacije___stikala_in_vticnice___klasicni_program', N'Otroška zaščita', N'1D1'),
  (N'videlektro', N'instalacije___stikala_in_vticnice___klasicni_program', N'Pokrov', N'1D1'),
  (N'videlektro', N'instalacije___stikala_in_vticnice___zvonci', N'Oblika', N'1D3'),
  (N'videlektro', N'instalacije___stikala_in_vticnice___zvonci', N'Širina modula', N'1D3'),
  (N'videlektro', N'instalacije___strelovod_in_ozemljitev', N'Število polov', N'1J'),
  (N'videlektro', N'orodje___prenosni_merilni_instrumenti', N'Napajanje', N'1E4'),
  (N'videlektro', N'orodje___rocno_orodje___predvleke', N'Končni navoj', N'1E1,1E5'),
  (N'videlektro', N'razsvetljava___led_trakovi_in_profili___kontrolerji_in_zatemnilniki', N'Napajanje', N'2D'),
  (N'videlektro', N'razsvetljava___led_trakovi_in_profili___kontrolerji_in_zatemnilniki', N'Priklop', N'2D'),
  (N'videlektro', N'razsvetljava___led_trakovi_in_profili___kontrolerji_in_zatemnilniki', N'Upravljanje', N'2D,2D'),
  (N'videlektro', N'razsvetljava___led_trakovi_in_profili___led_profili_in_dodatki', N'Pokrov', N'2B1'),
  (N'videlektro', N'razsvetljava___led_trakovi_in_profili___led_profili_in_dodatki', N'Pritrditev', N'2B4'),
  (N'videlektro', N'razsvetljava___led_trakovi_in_profili___led_profili_in_dodatki', N'Za LED profil', N'2B2,2B4'),
  (N'videlektro', N'razsvetljava___led_trakovi_in_profili___napajalniki', N'Priklop', N'2E'),
  (N'videlektro', N'razsvetljava___led_trakovi_in_profili___napajalniki', N'Tip napajalnika', N'2E'),
  (N'videlektro', N'razsvetljava___led_trakovi_in_profili___napajalniki', N'Upravljanje', N'2E'),
  (N'videlektro', N'razsvetljava___luci', N'Material pokrova', N'znamke:2A1+2A7+2A9'),
  (N'videlektro', N'razsvetljava___luci', N'Tehnologija', N'znamke:2A6+2A9'),
  (N'videlektro', N'razsvetljava___luci', N'Tip napajalnika', N'znamke:2A1+2A6'),
  (N'videlektro', N'razsvetljava___luci', N'Upravljanje', N'znamke:2A1+2A6+2A13'),
  (N'videlektro', N'razsvetljava___luci', N'Vključuje napajalnik', N'znamke:2A1+2A6+2A9'),
  (N'videlektro', N'razsvetljava___luci___zasilna_razsvetljava', N'Temperaturna obstojnost', N'2A2'),
  (N'videlektro', N'razsvetljava___luci___zasilna_razsvetljava', N'Upravljanje', N'2A2'),
  (N'videlektro', N'razsvetljava___luci___zasilna_razsvetljava', N'Vključuje napajalnik', N'2A2'),
  (N'videlektro', N'razsvetljava___sijalke', N'Prosojnost', N'2G1,2G2'),
  (N'videlektro', N'razsvetljava___sijalke', N'Tehnologija', N'2G2');

DELETE seed FROM @Seed AS seed
WHERE EXISTS (SELECT 1 FROM canon.CategoryAttributeSet AS existing
  INNER JOIN canon.AttributeTranslation AS translation ON translation.AttributeCode = existing.AttributeCode AND translation.LanguageCode = N'sl'
  WHERE existing.CategoryTreeCode = seed.CategoryTreeCode AND existing.CategoryCode = seed.CategoryCode
    AND translation.Name = seed.AttributeName AND existing.IsActive = 1 AND existing.UpdatedBy <> N'mastri 2026-09-08');

DECLARE @Tree nvarchar(100), @Category nvarchar(200), @Json nvarchar(max), @Saved int, @Total int = 0;
DECLARE category_cursor CURSOR LOCAL FAST_FORWARD FOR
  SELECT CategoryTreeCode, CategoryCode FROM @Seed GROUP BY CategoryTreeCode, CategoryCode ORDER BY MIN(Seq);
OPEN category_cursor;
FETCH NEXT FROM category_cursor INTO @Tree, @Category;
WHILE @@FETCH_STATUS = 0
BEGIN
  SET @Json = (SELECT code = AttributeName, level = N'RECOMMENDED' FROM @Seed WHERE CategoryTreeCode = @Tree AND CategoryCode = @Category ORDER BY Seq FOR JSON PATH);
  EXEC canon.SaveCategoryAttributeSetBulk @Tree, @Category, @Json, N'mastri 2026-09-08', @Saved OUTPUT;
  SET @Total += @Saved;
  FETCH NEXT FROM category_cursor INTO @Tree, @Category;
END;
CLOSE category_cursor; DEALLOCATE category_cursor;
PRINT CONCAT(N'177: novih vrstic nabora iz mastrov: ', @Total);
