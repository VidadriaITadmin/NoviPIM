/*
  109 — zapisovalna pot za preslikave kategorij in za uvrstitev izdelka.

  Do te migracije je bilo urejanje kategorij mogoce samo z novo migracijo. Register
  map.SourceCategory je vestno kazal, katere dobaviteljeve kategorije cakajo na preslikavo,
  map.MissingCategoryMap je stel, kolikokrat je katera pot ostala brez cilja — nihce pa tega
  ni mogel resiti drugace kot z INSERT v SQL. Intranet je bil v celoti bralen: shema intranet
  je imela 30 postopkov Get* in nobenega Save*.

  Ta migracija doda tri stvari in nic vec:

    1. map.SaveCategoryPathMap / map.DeactivateCategoryPathMap
       Preslikava "dobaviteljeva pot -> nasa kategorija" postane urejiv podatek. Vsaka
       sprememba se zapise v map.CategoryPathMapHistory z akterjem in staro vrednostjo.

    2. pim.ProductCategoryOverride + pim.SetProductCategories
       Rocna uvrstitev enega izdelka. Prestavljanje po definiciji pomeni tudi odstranitev iz
       stare kategorije, zato postopek stare vrstice v canon.ProductCategory za ta izdelek in
       to spletno stran ZBRISE. Nic se ne izgubi: prej se stara in nova vrednost zapiseta v
       pim.ProductFieldHistory (FieldKey ProductCategory.CategoryPath), od koder je sprememba
       vidna in izsledljiva.

    3. map.ResolveProductCategories dobi eno novo pravilo: izdelka, ki ima rocno uvrstitev za
       doloceno spletno stran, ponovna preslikava ne povozi. Brez tega bi vsak nocni zajem
       tiho izbrisal urednikovo delo — in to je natanko tista vrsta okvare, ki je nihce ne
       opazi, dokler nekdo ne presteje vrstic.

  --- Zakaj override in ne pisanje naravnost v canon ---------------------------------------

  canon.ProductCategory pove, kaj je povedal VIR. Ce bi urednikovo uvrstitev zapisali samo
  tja, bi bila po prvi ponovni preslikavi nelocljiva od dobaviteljeve in bi jo naslednji zajem
  povozil. Override je locena vrstica z lastnikom PIM: preslikava jo vidi in se ji umakne,
  izvoz pa dobi eno samo resnico, ker canon.ProductCategory ostane tisto, kar izvoz bere.

  --- Kaj ta migracija NE naredi -----------------------------------------------------------

  Ne ustvari nobene kategorije in ne spremeni nobene preslikave. Samo omogoci, da ju clovek
  ureja iz vmesnika.
*/

SET XACT_ABORT ON;

/* --- 1) Revizijski stolpci in zgodovina preslikav ---------------------------------------- */

EXEC(N'
IF COL_LENGTH(N''map.CategoryPathMap'', N''UpdatedUtc'') IS NULL
  ALTER TABLE map.CategoryPathMap ADD UpdatedUtc datetime2(7) NULL;
');
EXEC(N'
IF COL_LENGTH(N''map.CategoryPathMap'', N''UpdatedBy'') IS NULL
  ALTER TABLE map.CategoryPathMap ADD UpdatedBy nvarchar(200) NULL;
');
EXEC(N'
IF COL_LENGTH(N''map.CategoryPathMap'', N''Note'') IS NULL
  ALTER TABLE map.CategoryPathMap ADD Note nvarchar(600) NULL;
');

EXEC(N'
IF OBJECT_ID(N''map.CategoryPathMapHistory'') IS NULL
BEGIN
  CREATE TABLE map.CategoryPathMapHistory
  (
    CategoryPathMapHistoryId bigint IDENTITY(1,1) NOT NULL
      CONSTRAINT PK_CategoryPathMapHistory PRIMARY KEY,
    SourceCode       nvarchar(100)  NOT NULL,
    CategoryTreeCode nvarchar(100)  NOT NULL,
    SourcePathKey    nvarchar(2000) NOT NULL,
    OldCategoryCode  nvarchar(400)  NULL,
    NewCategoryCode  nvarchar(400)  NULL,
    OldIsActive      bit            NULL,
    NewIsActive      bit            NULL,
    ChangedBy        nvarchar(200)  NOT NULL,
    ChangedUtc       datetime2(7)   NOT NULL
      CONSTRAINT DF_CategoryPathMapHistory_ChangedUtc DEFAULT(SYSUTCDATETIME()),
    Note             nvarchar(600)  NULL
  );
  CREATE INDEX IX_CategoryPathMapHistory_Kljuc
    ON map.CategoryPathMapHistory(SourceCode, SourcePathKey, ChangedUtc DESC);
END;
');

/* --- 2) Urejanje preslikave -------------------------------------------------------------- */

EXEC(N'
CREATE OR ALTER PROCEDURE map.SaveCategoryPathMap
  @SourceCode nvarchar(100),
  @CategoryTreeCode nvarchar(100),
  @SourcePathKey nvarchar(2000),
  @CategoryCode nvarchar(400),
  @Actor nvarchar(200),
  @Note nvarchar(600) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  IF NULLIF(LTRIM(RTRIM(@Actor)), N'''') IS NULL
    THROW 106001, N''Akter je obvezen: brez njega sprememba nima lastnika.'', 1;
  IF NULLIF(LTRIM(RTRIM(@SourcePathKey)), N'''') IS NULL
    THROW 106002, N''Izvorna pot je obvezna.'', 1;

  /*
    Cilj mora obstajati. Preslikava na neobstojeco kategorijo se ne javi kot napaka - tiho
    izpade v spoju s canon.Category v map.ResolveProductCategories - zato jo je treba
    zavrniti tu, kjer je clovek se pred zaslonom.
  */
  IF NOT EXISTS
  (
    SELECT 1 FROM canon.Category
    WHERE CategoryTreeCode = @CategoryTreeCode AND CategoryCode = @CategoryCode AND IsActive = 1
  )
    THROW 106003, N''Ciljna kategorija v tem drevesu ne obstaja ali ni aktivna.'', 1;

  /*
    Prevedena pot mora obstajati za vsako aktivno spletno stran tega drevesa, sicer preslikava
    ne bo nikoli nic zapisala. To je natanko past, ki je BT_XML zadrzala mesece.
  */
  DECLARE @BrezPrevoda nvarchar(400) = NULL;
  SELECT TOP (1) @BrezPrevoda = spletna.WebSiteCode
  FROM canon.WebSite spletna
  WHERE spletna.CategoryTreeCode = @CategoryTreeCode AND spletna.IsActive = 1
    AND NOT EXISTS
    (
      SELECT 1 FROM canon.CategoryPathTranslated pot
      WHERE pot.CategoryTreeCode = @CategoryTreeCode AND pot.CategoryCode = @CategoryCode
        AND pot.LanguageCode = spletna.LanguageCode
    );
  IF @BrezPrevoda IS NOT NULL
    THROW 106004, N''Kategorija nima prevedene poti za eno od aktivnih spletnih strani tega drevesa.'', 1;

  DECLARE @StaraKoda nvarchar(400) = NULL, @StaroAktivno bit = NULL;
  SELECT @StaraKoda = CategoryCode, @StaroAktivno = IsActive
  FROM map.CategoryPathMap
  WHERE SourceCode = @SourceCode AND CategoryTreeCode = @CategoryTreeCode AND SourcePathKey = @SourcePathKey;

  IF @StaraKoda IS NOT NULL AND @StaraKoda = @CategoryCode AND @StaroAktivno = 1
  BEGIN
    SELECT N''Unchanged'' AS Outcome;
    RETURN;
  END

  BEGIN TRANSACTION;

  IF @StaraKoda IS NULL
    INSERT map.CategoryPathMap (SourceCode, CategoryTreeCode, SourcePathKey, CategoryCode, IsActive, UpdatedUtc, UpdatedBy, Note)
    VALUES (@SourceCode, @CategoryTreeCode, @SourcePathKey, @CategoryCode, 1, SYSUTCDATETIME(), @Actor, @Note);
  ELSE
    UPDATE map.CategoryPathMap
    SET CategoryCode = @CategoryCode, IsActive = 1, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = @Actor, Note = @Note
    WHERE SourceCode = @SourceCode AND CategoryTreeCode = @CategoryTreeCode AND SourcePathKey = @SourcePathKey;

  INSERT map.CategoryPathMapHistory
    (SourceCode, CategoryTreeCode, SourcePathKey, OldCategoryCode, NewCategoryCode, OldIsActive, NewIsActive, ChangedBy, Note)
  VALUES
    (@SourceCode, @CategoryTreeCode, @SourcePathKey, @StaraKoda, @CategoryCode, @StaroAktivno, 1, @Actor, @Note);

  /* Ko pot dobi cilj, ni vec manjkajoca. Vrstica gre stran iz delovnega seznama, ne iz registra. */
  DELETE map.MissingCategoryMap
  WHERE SourceCode = @SourceCode AND CategoryTreeCode = @CategoryTreeCode AND SourcePathKey = @SourcePathKey;

  COMMIT TRANSACTION;

  SELECT CASE WHEN @StaraKoda IS NULL THEN N''Created'' ELSE N''Updated'' END AS Outcome;
END;
');

EXEC(N'
CREATE OR ALTER PROCEDURE map.DeactivateCategoryPathMap
  @SourceCode nvarchar(100),
  @CategoryTreeCode nvarchar(100),
  @SourcePathKey nvarchar(2000),
  @Actor nvarchar(200),
  @Note nvarchar(600) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  IF NULLIF(LTRIM(RTRIM(@Actor)), N'''') IS NULL
    THROW 106001, N''Akter je obvezen: brez njega sprememba nima lastnika.'', 1;

  DECLARE @StaraKoda nvarchar(400) = NULL, @StaroAktivno bit = NULL;
  SELECT @StaraKoda = CategoryCode, @StaroAktivno = IsActive
  FROM map.CategoryPathMap
  WHERE SourceCode = @SourceCode AND CategoryTreeCode = @CategoryTreeCode AND SourcePathKey = @SourcePathKey;

  IF @StaraKoda IS NULL BEGIN SELECT N''NotFound'' AS Outcome; RETURN; END
  IF @StaroAktivno = 0 BEGIN SELECT N''Unchanged'' AS Outcome; RETURN; END

  BEGIN TRANSACTION;

  /*
    Ne brisemo vrstice. Ugasnjena preslikava pove, da je bila odlocitev sprejeta in preklicana;
    izbrisana pove samo, da je ni - in naslednji zajem bi pot spet prijavil kot manjkajoco,
    ne da bi kdo vedel, da je bila ze obravnavana.
  */
  UPDATE map.CategoryPathMap
  SET IsActive = 0, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = @Actor, Note = @Note
  WHERE SourceCode = @SourceCode AND CategoryTreeCode = @CategoryTreeCode AND SourcePathKey = @SourcePathKey;

  INSERT map.CategoryPathMapHistory
    (SourceCode, CategoryTreeCode, SourcePathKey, OldCategoryCode, NewCategoryCode, OldIsActive, NewIsActive, ChangedBy, Note)
  VALUES (@SourceCode, @CategoryTreeCode, @SourcePathKey, @StaraKoda, @StaraKoda, @StaroAktivno, 0, @Actor, @Note);

  COMMIT TRANSACTION;
  SELECT N''Deactivated'' AS Outcome;
END;
');

/* --- 3) Rocna uvrstitev izdelka ---------------------------------------------------------- */

EXEC(N'
IF OBJECT_ID(N''pim.ProductCategoryOverride'') IS NULL
BEGIN
  CREATE TABLE pim.ProductCategoryOverride
  (
    ProductCategoryOverrideId bigint IDENTITY(1,1) NOT NULL
      CONSTRAINT PK_ProductCategoryOverride PRIMARY KEY,
    OrganizationId int           NOT NULL,
    ProductId      bigint        NOT NULL,
    WebSite        nvarchar(100) NOT NULL,
    CategoryPath   nvarchar(1000) NULL,   /* NULL = izdelek na tej strani namenoma nima kategorije */
    SetBy          nvarchar(200) NOT NULL,
    SetUtc         datetime2(7)  NOT NULL
      CONSTRAINT DF_ProductCategoryOverride_SetUtc DEFAULT(SYSUTCDATETIME()),
    Note           nvarchar(600) NULL,
    CONSTRAINT UQ_ProductCategoryOverride UNIQUE (ProductId, WebSite, CategoryPath)
  );
  CREATE INDEX IX_ProductCategoryOverride_Izdelek ON pim.ProductCategoryOverride(ProductId, WebSite);
END;
');

EXEC(N'
CREATE OR ALTER PROCEDURE pim.SetProductCategories
  @OrganizationId int,
  @ItemID nvarchar(200),
  @WebSite nvarchar(100),
  @CategoryPathsJson nvarchar(max),   /* ["Notranja svetila > Stropna svetila", ...]; [] = brez kategorije */
  @Actor nvarchar(200),
  @Note nvarchar(600) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  IF NULLIF(LTRIM(RTRIM(@Actor)), N'''') IS NULL
    THROW 106001, N''Akter je obvezen: brez njega sprememba nima lastnika.'', 1;

  DECLARE @ProductId bigint = NULL;
  SELECT @ProductId = ProductId FROM canon.Product
  WHERE OrganizationId = @OrganizationId AND ItemID = @ItemID;
  IF @ProductId IS NULL
    THROW 106005, N''Izdelka s to sifro v tem podjetju ni.'', 1;

  IF NOT EXISTS (SELECT 1 FROM canon.WebSite WHERE WebSiteCode = @WebSite AND IsActive = 1)
    THROW 106006, N''Spletna stran ne obstaja ali ni aktivna.'', 1;

  DECLARE @Nove TABLE(CategoryPath nvarchar(1000) NOT NULL PRIMARY KEY);
  INSERT @Nove(CategoryPath)
  SELECT DISTINCT LTRIM(RTRIM(value)) FROM OPENJSON(@CategoryPathsJson)
  WHERE NULLIF(LTRIM(RTRIM(value)), N'''') IS NOT NULL;

  /*
    Vsaka pot mora obstajati v drevesu te spletne strani. Prosto besedilo bi pomenilo izdelek
    v kategoriji, ki je v trgovini ni, in to se pokaze sele pri uvozu na drugi strani.
  */
  DECLARE @Neznana nvarchar(1000) = NULL;
  SELECT TOP (1) @Neznana = nova.CategoryPath
  FROM @Nove nova
  WHERE NOT EXISTS
  (
    SELECT 1
    FROM canon.WebSite spletna
    INNER JOIN canon.CategoryPathTranslated pot
      ON pot.CategoryTreeCode = spletna.CategoryTreeCode AND pot.LanguageCode = spletna.LanguageCode
    WHERE spletna.WebSiteCode = @WebSite AND pot.CategoryPath = nova.CategoryPath
  );
  IF @Neznana IS NOT NULL
    THROW 106007, N''Ena od poti ne obstaja v drevesu te spletne strani.'', 1;

  DECLARE @Stare nvarchar(max) =
    (SELECT STRING_AGG(CategoryPath, N'' | '') FROM canon.ProductCategory
     WHERE ProductId = @ProductId AND WebSite = @WebSite);
  DECLARE @NoveBesedilo nvarchar(max) =
    (SELECT STRING_AGG(CategoryPath, N'' | '') FROM @Nove);

  IF ISNULL(@Stare, N'''') = ISNULL(@NoveBesedilo, N'''')
  BEGIN
    SELECT N''Unchanged'' AS Outcome, @Stare AS OldValue, @NoveBesedilo AS NewValue;
    RETURN;
  END

  BEGIN TRANSACTION;

  /* Revizija najprej: ce karkoli spodaj pade, se ni zgodilo nic, in ce uspe, je zapisano. */
  DECLARE @BatchGuid uniqueidentifier = NEWID();
  INSERT pim.ProductChangeBatch (BatchId, ChangeSource, ChangedBy, ChangedAtUtc, OrganizationId, Note)
  VALUES (@BatchGuid, N''INTRANET'', @Actor, SYSUTCDATETIME(), @OrganizationId,
          ISNULL(@Note, CONCAT(N''Rocna uvrstitev, spletna stran '', @WebSite)));
  DECLARE @BatchId bigint = SCOPE_IDENTITY();

  INSERT pim.ProductFieldHistory
    (ChangeBatchId, OrganizationId, ProductId, ItemID, FieldKey, CanonTable, CanonColumn, Owner, OldValue, NewValue, ChangedAtUtc)
  VALUES
    (@BatchId, @OrganizationId, @ProductId, @ItemID, N''ProductCategory.CategoryPath'',
     N''canon.ProductCategory'', N''CategoryPath'', N''PIM'', @Stare, @NoveBesedilo, SYSUTCDATETIME());

  /* Rocna uvrstitev je odslej lastnik te (izdelek, spletna stran). */
  DELETE pim.ProductCategoryOverride WHERE ProductId = @ProductId AND WebSite = @WebSite;

  INSERT pim.ProductCategoryOverride (OrganizationId, ProductId, WebSite, CategoryPath, SetBy, Note)
  SELECT @OrganizationId, @ProductId, @WebSite, nova.CategoryPath, @Actor, @Note FROM @Nove nova;

  IF NOT EXISTS (SELECT 1 FROM @Nove)
    INSERT pim.ProductCategoryOverride (OrganizationId, ProductId, WebSite, CategoryPath, SetBy, Note)
    VALUES (@OrganizationId, @ProductId, @WebSite, NULL, @Actor, @Note);

  /*
    Prestavljanje pomeni tudi odstranitev iz stare kategorije. Brisemo izkljucno vrstice tega
    izdelka in te spletne strani; stara vrednost je zgoraj ze v pim.ProductFieldHistory, zato
    je sprememba izsledljiva in razveljavljiva.
  */
  DELETE canon.ProductCategory WHERE ProductId = @ProductId AND WebSite = @WebSite;

  INSERT canon.ProductCategory (ProductId, WebSite, CategoryPath)
  SELECT @ProductId, @WebSite, nova.CategoryPath FROM @Nove nova;

  COMMIT TRANSACTION;

  SELECT N''Updated'' AS Outcome, @Stare AS OldValue, @NoveBesedilo AS NewValue;
END;
');

EXEC(N'
CREATE OR ALTER PROCEDURE pim.ClearProductCategoryOverride
  @OrganizationId int, @ItemID nvarchar(200), @WebSite nvarchar(100), @Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  IF NULLIF(LTRIM(RTRIM(@Actor)), N'''') IS NULL
    THROW 106001, N''Akter je obvezen: brez njega sprememba nima lastnika.'', 1;

  DECLARE @ProductId bigint = NULL;
  SELECT @ProductId = ProductId FROM canon.Product WHERE OrganizationId = @OrganizationId AND ItemID = @ItemID;
  IF @ProductId IS NULL THROW 106005, N''Izdelka s to sifro v tem podjetju ni.'', 1;

  DELETE pim.ProductCategoryOverride WHERE ProductId = @ProductId AND WebSite = @WebSite;

  /*
    Vrnitev pod vir ne ugiba, kaj bi vir rekel. Vrstice v canon.ProductCategory pusti pri miru;
    pravo vrednost vrne naslednja preslikava, ki se izdelku odslej ne umika vec.
  */
  SELECT N''Cleared'' AS Outcome;
END;
');

/* --- 4) Preslikava se umakne rocni uvrstitvi --------------------------------------------- */

EXEC(N'
CREATE OR ALTER PROCEDURE map.ResolveProductCategories
  @RunId uniqueidentifier,
  @OrganizationId int,
  @SourceCode nvarchar(100)
AS
BEGIN
  /*
    Dobaviteljeva kategorija -> nasa kategorija. Tece po tem, ko je map.ProcessRawInbox ze
    ustvaril oziroma nasel izdelke, in dela izkljucno iz izluscenih vrednosti tega zagona.

    Novost 109: izdelka z rocno uvrstitvijo (pim.ProductCategoryOverride) ne povozimo.
    Register in delovni seznam se zanj se vedno polnita - urednik mora videti, kaj dobavitelj
    pravi, tudi kadar se je odlocil drugace.
  */
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  IF OBJECT_ID(N''tempdb..#Pot'') IS NOT NULL DROP TABLE #Pot;
  IF OBJECT_ID(N''tempdb..#Kategorija'') IS NOT NULL DROP TABLE #Kategorija;

  SELECT
    zapis.ProductId,
    zapis.SourcePathKey,
    zapis.Raven1,
    zapis.Raven2,
    zapis.Raven3
  INTO #Pot
  FROM
  (
    SELECT
      izdelek.ProductId,
      LTRIM(RTRIM(surovo.Raven1)) AS Raven1,
      NULLIF(LTRIM(RTRIM(surovo.Raven2)), N'''') AS Raven2,
      NULLIF(LTRIM(RTRIM(surovo.Raven3)), N'''') AS Raven3,
      LOWER(CONCAT(
        REPLACE(LTRIM(RTRIM(surovo.Raven1)), N'' '', N''_''),
        CASE WHEN NULLIF(LTRIM(RTRIM(surovo.Raven2)), N'''') IS NULL THEN N''''
             ELSE N''___'' + REPLACE(LTRIM(RTRIM(surovo.Raven2)), N'' '', N''_'') END,
        CASE WHEN NULLIF(LTRIM(RTRIM(surovo.Raven3)), N'''') IS NULL THEN N''''
             ELSE N''___'' + REPLACE(LTRIM(RTRIM(surovo.Raven3)), N'' '', N''_'') END
      )) AS SourcePathKey
    FROM
    (
      SELECT
        inbox.InboxId,
        value.RecordOrdinal,
        MAX(CASE WHEN value.TargetFieldCode = N''Product.ItemID'' THEN CONVERT(nvarchar(100), value.Value) END) AS ItemID,
        MAX(CASE WHEN value.TargetFieldCode = N''Product.EAN'' THEN CONVERT(nvarchar(100), value.Value) END) AS EAN,
        MAX(CASE WHEN value.TargetFieldCode = N''ProductCategory.SourceLevel1'' THEN CONVERT(nvarchar(400), value.Value) END) AS Raven1,
        MAX(CASE WHEN value.TargetFieldCode = N''ProductCategory.SourceLevel2'' THEN CONVERT(nvarchar(400), value.Value) END) AS Raven2,
        MAX(CASE WHEN value.TargetFieldCode = N''ProductCategory.SourceLevel3'' THEN CONVERT(nvarchar(400), value.Value) END) AS Raven3
      FROM raw.Inbox inbox
      INNER JOIN map.ExtractedValue value ON value.InboxId = inbox.InboxId
      WHERE inbox.RunId = @RunId AND inbox.OrganizationId = @OrganizationId AND inbox.SourceCode = @SourceCode
      GROUP BY inbox.InboxId, value.RecordOrdinal
    ) surovo
    CROSS APPLY
    (
      SELECT TOP(1) product.ProductId
      FROM canon.Product product
      WHERE product.OrganizationId = @OrganizationId
        AND ((surovo.ItemID IS NOT NULL AND product.ItemID = surovo.ItemID)
          OR (surovo.ItemID IS NULL AND surovo.EAN IS NOT NULL AND product.EAN = surovo.EAN))
      ORDER BY CASE WHEN product.ItemID = surovo.ItemID THEN 0 ELSE 1 END, product.ProductId
    ) izdelek
    WHERE NULLIF(LTRIM(RTRIM(surovo.Raven1)), N'''') IS NOT NULL
  ) zapis;

  MERGE map.SourceCategory AS target
  USING
  (
    SELECT
      pot.SourcePathKey,
      MAX(pot.Raven1) AS Raven1,
      MAX(pot.Raven2) AS Raven2,
      MAX(pot.Raven3) AS Raven3,
      COUNT(DISTINCT pot.ProductId) AS Izdelkov
    FROM #Pot pot
    GROUP BY pot.SourcePathKey
  ) source
    ON target.SourceCode = @SourceCode AND target.SourcePathKey = source.SourcePathKey
  WHEN MATCHED THEN UPDATE SET
    SourceLevel1 = source.Raven1,
    SourceLevel2 = source.Raven2,
    SourceLevel3 = source.Raven3,
    ProductCount = source.Izdelkov,
    LastSeenUtc  = SYSUTCDATETIME()
  WHEN NOT MATCHED THEN INSERT (SourceCode, SourcePathKey, SourceLevel1, SourceLevel2, SourceLevel3, ProductCount)
    VALUES (@SourceCode, source.SourcePathKey, source.Raven1, source.Raven2, source.Raven3, source.Izdelkov);

  SELECT pot.ProductId, drevo.CategoryTreeCode, pot.SourcePathKey
  INTO #Kategorija
  FROM #Pot pot
  CROSS JOIN
  (
    SELECT DISTINCT spletna.CategoryTreeCode
    FROM canon.WebSite spletna
    WHERE spletna.IsActive = 1
      AND EXISTS (SELECT 1 FROM canon.Category kategorija
                  WHERE kategorija.CategoryTreeCode = spletna.CategoryTreeCode AND kategorija.IsActive = 1)
  ) drevo;

  MERGE canon.ProductCategory AS target
  USING
  (
    SELECT DISTINCT kategorija.ProductId, spletna.WebSiteCode, pot.CategoryPath
    FROM #Kategorija kategorija
    INNER JOIN map.CategoryPathMap slovar
      ON slovar.SourceCode = @SourceCode AND slovar.CategoryTreeCode = kategorija.CategoryTreeCode
        AND slovar.SourcePathKey = kategorija.SourcePathKey AND slovar.IsActive = 1
    INNER JOIN canon.WebSite spletna
      ON spletna.CategoryTreeCode = kategorija.CategoryTreeCode AND spletna.IsActive = 1
    INNER JOIN canon.CategoryPathTranslated pot
      ON pot.CategoryTreeCode = kategorija.CategoryTreeCode AND pot.CategoryCode = slovar.CategoryCode
        AND pot.LanguageCode = spletna.LanguageCode
    /* 109: rocna uvrstitev je mocnejsa od vira. */
    WHERE NOT EXISTS
    (
      SELECT 1 FROM pim.ProductCategoryOverride prekrivka
      WHERE prekrivka.ProductId = kategorija.ProductId AND prekrivka.WebSite = spletna.WebSiteCode
    )
  ) source
    ON target.ProductId = source.ProductId AND target.WebSite = source.WebSiteCode
      AND target.CategoryPath = source.CategoryPath
  WHEN NOT MATCHED THEN INSERT (ProductId, WebSite, CategoryPath)
    VALUES (source.ProductId, source.WebSiteCode, source.CategoryPath);

  MERGE map.MissingCategoryMap AS target
  USING
  (
    SELECT kategorija.CategoryTreeCode, kategorija.SourcePathKey, COUNT(*) AS Kolikokrat
    FROM #Kategorija kategorija
    WHERE NOT EXISTS
    (
      SELECT 1 FROM map.CategoryPathMap slovar
      WHERE slovar.SourceCode = @SourceCode AND slovar.CategoryTreeCode = kategorija.CategoryTreeCode
        AND slovar.SourcePathKey = kategorija.SourcePathKey AND slovar.IsActive = 1
    )
    GROUP BY kategorija.CategoryTreeCode, kategorija.SourcePathKey
  ) source
    ON target.SourceCode = @SourceCode AND target.CategoryTreeCode = source.CategoryTreeCode
      AND target.SourcePathKey = source.SourcePathKey
  WHEN MATCHED THEN UPDATE SET SeenCount = source.Kolikokrat, LastSeenUtc = SYSUTCDATETIME()
  WHEN NOT MATCHED THEN INSERT (SourceCode, CategoryTreeCode, SourcePathKey, SeenCount)
    VALUES (@SourceCode, source.CategoryTreeCode, source.SourcePathKey, source.Kolikokrat);

  DROP TABLE #Kategorija;
  DROP TABLE #Pot;
END;
');

/* --- 5) Bralni modeli za vmesnik --------------------------------------------------------- */

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetCategoryMappings
  @SourceCode nvarchar(100) = NULL,
  @CategoryTreeCode nvarchar(100) = NULL,
  @Stanje nvarchar(20) = NULL,          /* NULL = vse, ''Nepreslikano'', ''Preslikano'', ''Ugasnjeno'' */
  @Iskanje nvarchar(200) = NULL,
  @Stran int = 1,
  @NaStran int = 50
AS
BEGIN
  SET NOCOUNT ON;
  IF @Stran < 1 SET @Stran = 1;
  IF @NaStran < 1 OR @NaStran > 500 SET @NaStran = 50;

  /*
    Ena vrstica na (vir, drevo, izvorna pot). Register pove, kaj je dobavitelj poslal in koliko
    izdelkov je za tem; slovar pove, ali ima to cilj. Strani se stejejo v bazi, ker jih je lahko
    vec sto in filtriranje v pomnilniku je bila natanko napaka, ki jo je odpravila migracija 102.
  */
  WITH Drevo AS
  (
    SELECT DISTINCT spletna.CategoryTreeCode
    FROM canon.WebSite spletna WHERE spletna.IsActive = 1
  ),
  Osnova AS
  (
    SELECT
      register.SourceCode,
      drevo.CategoryTreeCode,
      register.SourcePathKey,
      register.SourceLevel1,
      register.SourceLevel2,
      register.SourceLevel3,
      register.ProductCount,
      register.LastSeenUtc,
      slovar.CategoryCode,
      slovar.IsActive AS MapIsActive,
      slovar.UpdatedUtc,
      slovar.UpdatedBy,
      pot.CategoryPath
    FROM map.SourceCategory register
    CROSS JOIN Drevo drevo
    LEFT JOIN map.CategoryPathMap slovar
      ON slovar.SourceCode = register.SourceCode
     AND slovar.CategoryTreeCode = drevo.CategoryTreeCode
     AND slovar.SourcePathKey = register.SourcePathKey
    OUTER APPLY
    (
      SELECT TOP (1) prevod.CategoryPath
      FROM canon.CategoryPathTranslated prevod
      INNER JOIN canon.WebSite spletna
        ON spletna.CategoryTreeCode = prevod.CategoryTreeCode AND spletna.LanguageCode = prevod.LanguageCode
      WHERE prevod.CategoryTreeCode = drevo.CategoryTreeCode AND prevod.CategoryCode = slovar.CategoryCode
      ORDER BY spletna.SortOrder
    ) pot
    WHERE (@SourceCode IS NULL OR register.SourceCode = @SourceCode)
      AND (@CategoryTreeCode IS NULL OR drevo.CategoryTreeCode = @CategoryTreeCode)
  ),
  Filtrirano AS
  (
    SELECT *,
      CASE WHEN CategoryCode IS NULL THEN N''Nepreslikano''
           WHEN MapIsActive = 0 THEN N''Ugasnjeno''
           ELSE N''Preslikano'' END AS Stanje
    FROM Osnova
  )
  SELECT
    SourceCode, CategoryTreeCode, SourcePathKey, SourceLevel1, SourceLevel2, SourceLevel3,
    ProductCount, LastSeenUtc, CategoryCode, CategoryPath, Stanje, UpdatedUtc, UpdatedBy,
    COUNT(*) OVER () AS SkupajVrstic
  FROM Filtrirano
  WHERE (@Stanje IS NULL OR Stanje = @Stanje)
    AND (@Iskanje IS NULL OR SourcePathKey LIKE N''%'' + @Iskanje + N''%''
         OR ISNULL(SourceLevel1, N'''') LIKE N''%'' + @Iskanje + N''%''
         OR ISNULL(SourceLevel2, N'''') LIKE N''%'' + @Iskanje + N''%''
         OR ISNULL(CategoryPath, N'''') LIKE N''%'' + @Iskanje + N''%'')
  ORDER BY ProductCount DESC, SourcePathKey
  OFFSET (@Stran - 1) * @NaStran ROWS FETCH NEXT @NaStran ROWS ONLY;
END;
');

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetCategoryTreeNodes
  @CategoryTreeCode nvarchar(100),
  @Iskanje nvarchar(200) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  /*
    Izbirnik kategorije. Pot je slovenska (najnizja SortOrder aktivne spletne strani tega
    drevesa), ker clovek izbira po tem, kar vidi v trgovini, ne po sifri.
  */
  SELECT
    kategorija.CategoryCode,
    kategorija.CategoryName,
    kategorija.LevelNo,
    kategorija.ParentCategoryCode,
    pot.CategoryPath
  FROM canon.Category kategorija
  OUTER APPLY
  (
    SELECT TOP (1) prevod.CategoryPath
    FROM canon.CategoryPathTranslated prevod
    INNER JOIN canon.WebSite spletna
      ON spletna.CategoryTreeCode = prevod.CategoryTreeCode AND spletna.LanguageCode = prevod.LanguageCode
    WHERE prevod.CategoryTreeCode = kategorija.CategoryTreeCode AND prevod.CategoryCode = kategorija.CategoryCode
      AND spletna.IsActive = 1
    ORDER BY spletna.SortOrder
  ) pot
  WHERE kategorija.CategoryTreeCode = @CategoryTreeCode AND kategorija.IsActive = 1
    AND (@Iskanje IS NULL OR kategorija.CategoryName LIKE N''%'' + @Iskanje + N''%''
         OR ISNULL(pot.CategoryPath, N'''') LIKE N''%'' + @Iskanje + N''%'')
  ORDER BY pot.CategoryPath, kategorija.CategoryCode;
END;
');

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetProductCategories
  @OrganizationId int,
  @ItemID nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON;
  /*
    Ena vrstica na aktivno spletno stran, tudi kadar izdelek tam kategorije nima - prazna
    vrstica je informacija, izpuscena vrstica je vrzel.
  */
  DECLARE @ProductId bigint = NULL;
  SELECT @ProductId = ProductId FROM canon.Product WHERE OrganizationId = @OrganizationId AND ItemID = @ItemID;

  SELECT
    spletna.WebSiteCode,
    spletna.WebSiteName,
    spletna.CategoryTreeCode,
    (SELECT STRING_AGG(k.CategoryPath, N'' | '') FROM canon.ProductCategory k
      WHERE k.ProductId = @ProductId AND k.WebSite = spletna.WebSiteCode) AS CategoryPaths,
    CASE WHEN EXISTS (SELECT 1 FROM pim.ProductCategoryOverride prekrivka
                      WHERE prekrivka.ProductId = @ProductId AND prekrivka.WebSite = spletna.WebSiteCode)
         THEN CAST(1 AS bit) ELSE CAST(0 AS bit) END AS JeRocna,
    (SELECT TOP (1) prekrivka.SetBy FROM pim.ProductCategoryOverride prekrivka
      WHERE prekrivka.ProductId = @ProductId AND prekrivka.WebSite = spletna.WebSiteCode
      ORDER BY prekrivka.SetUtc DESC) AS SetBy,
    (SELECT TOP (1) prekrivka.SetUtc FROM pim.ProductCategoryOverride prekrivka
      WHERE prekrivka.ProductId = @ProductId AND prekrivka.WebSite = spletna.WebSiteCode
      ORDER BY prekrivka.SetUtc DESC) AS SetUtc
  FROM canon.WebSite spletna
  WHERE spletna.IsActive = 1
  ORDER BY spletna.SortOrder;
END;
');
