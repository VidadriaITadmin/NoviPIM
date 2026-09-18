/*
  091 — dobaviteljeve kategorije se odkrijejo same, tudi kadar preslikave zanje se ni.

  Odlocitev uporabnika 2026-08-24: "dobavitelji imajo svoje kategorije, mi pa svoje in bo treba
  vedno delati mapping. Kategorije dobaviteljev se bodo same generirale in uporabnik jih bo
  zmaperal z naso." Nasa drevesa se vnasajo rocno; dobaviteljeva kategorija je podatek, ne
  nastavitev.

  --- Kaj je bilo narobe -----------------------------------------------------------------

  map.ResolveProductCategories je seznam dreves dobil takole:

      CROSS JOIN (SELECT DISTINCT CategoryTreeCode FROM map.CategoryPathMap
                  WHERE SourceCode = @SourceCode AND IsActive = 1) drevo

  Vir brez ene same vrstice v map.CategoryPathMap torej ni imel nobenega drevesa, CROSS JOIN je
  vrnil nic vrstic in postopek je zanj naredil natanko nic — niti vrstice v katalogu niti
  vrstice v delovnem seznamu map.MissingCategoryMap. Da bi se dobaviteljeva kategorija sploh
  pokazala, bi morala zanjo ze obstajati preslikava; da bi nastala preslikava, bi jo moral
  nekdo videti. Kura in jajce.

  Merjeno 2026-08-24: map.CategoryPathMap ima 201 vrstico, vse za NW_XML in vse za drevo
  svetila_si. BT_XML nima nobene, zato ima Braytron 0 kategorij v katalogu in 0 vrstic v
  delovnem seznamu — luknja je bila tiha, ne glasna.

  --- Kaj ta migracija naredi ------------------------------------------------------------

  1. map.SourceCategory — register dobaviteljevih kategorij. Polni se sam iz zajema, ne pozna
     ne dreves ne preslikav: zapise, kaj je dobavitelj poslal, v berljivi obliki (ravni, ne le
     normaliziran kljuc) in s stevilom izdelkov. To je tisti del, ki se "generira sam".

  2. Seznam dreves se ne bere vec iz preslikav, ampak iz canon.WebSite — in samo tista drevesa,
     ki dejansko imajo kategorije (EXISTS canon.Category). Dvoje naenkrat: vir brez preslikav
     ni vec neviden, drevo brez kategorij pa ne dela hrupa v delovnem seznamu. Danes to pomeni
     natanko svetila_si (132 kategorij); videlektro ima 0 in se vklopi sam, ko bo vnesen.

  3. BT_XML dobi entiteto Classification in preslikavi za druzini. Braytron kategorije poslje
     kot lastnosti main_family in sub_family znotraj <attributes>, zato je XPath enak kot pri
     njegovih ostalih lastnostih: .//attribute[slug="..."]/value/text()

  Kar ta migracija NAMENOMA ne naredi: ne vpise nobene preslikave dobaviteljeve kategorije v
  naso. Katera Braytronova druzina sodi v katero naso kategorijo, je odlocitev uporabnika;
  delovni list s predlogom je v docs\Braytron_druzine_predlog.csv. Ta migracija poskrbi le,
  da se 103 druzine sploh pokazejo v delovnem seznamu.
*/

SET XACT_ABORT ON;

/* ---------------------------------------------------------------------------------------
   1. Register dobaviteljevih kategorij
   --------------------------------------------------------------------------------------- */
EXEC(N'
IF OBJECT_ID(N''map.SourceCategory'') IS NULL
BEGIN
  CREATE TABLE map.SourceCategory
  (
    SourceCategoryId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_SourceCategory PRIMARY KEY,
    SourceCode       nvarchar(200)  NOT NULL,
    SourcePathKey    nvarchar(2000) NOT NULL,
    SourceLevel1     nvarchar(400)  NULL,
    SourceLevel2     nvarchar(400)  NULL,
    SourceLevel3     nvarchar(400)  NULL,
    ProductCount     int            NOT NULL CONSTRAINT DF_SourceCategory_ProductCount DEFAULT(0),
    FirstSeenUtc     datetime2(7)   NOT NULL CONSTRAINT DF_SourceCategory_FirstSeenUtc DEFAULT(SYSUTCDATETIME()),
    LastSeenUtc      datetime2(7)   NOT NULL CONSTRAINT DF_SourceCategory_LastSeenUtc  DEFAULT(SYSUTCDATETIME())
  );

  CREATE UNIQUE INDEX UQ_SourceCategory_SourcePath
    ON map.SourceCategory(SourceCode, SourcePathKey);
END;
');

/* Delovni seznam za cloveka: kaj je dobavitelj poslal in se nima cilja v nobenem drevesu.
   Berljiva pot je tu in ne le normaliziran kljuc, ker to bere clovek, ne postopek. */
EXEC(N'
CREATE OR ALTER VIEW map.SourceCategoryToMap
AS
SELECT
  sk.SourceCode,
  sk.SourcePathKey,
  CONCAT(sk.SourceLevel1,
         CASE WHEN sk.SourceLevel2 IS NULL THEN N'''' ELSE N'' > '' + sk.SourceLevel2 END,
         CASE WHEN sk.SourceLevel3 IS NULL THEN N'''' ELSE N'' > '' + sk.SourceLevel3 END) AS SourcePath,
  sk.ProductCount,
  sk.FirstSeenUtc,
  sk.LastSeenUtc
FROM map.SourceCategory sk
WHERE NOT EXISTS
(
  SELECT 1 FROM map.CategoryPathMap slovar
  WHERE slovar.SourceCode = sk.SourceCode
    AND slovar.SourcePathKey = sk.SourcePathKey
    AND slovar.IsActive = 1
);
');

/* ---------------------------------------------------------------------------------------
   2. Postopek: pot se izracuna enkrat, register se polni vedno, drevesa pridejo iz spletnih
      strani in ne iz preslikav.
   --------------------------------------------------------------------------------------- */
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

    Kljuc poti je zapisan enako kot v starem sistemu: male crke, presledek je podcrtaj,
    ravni loci "___". Prazna raven se izpusti, da "Zunanja svetila" ni isto kot
    "Zunanja svetila___".
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
      /* Ista identiteta kot v map.ProcessRawInbox: najprej sifra, sele nato EAN. */
      SELECT TOP(1) product.ProductId
      FROM canon.Product product
      WHERE product.OrganizationId = @OrganizationId
        AND ((surovo.ItemID IS NOT NULL AND product.ItemID = surovo.ItemID)
          OR (surovo.ItemID IS NULL AND surovo.EAN IS NOT NULL AND product.EAN = surovo.EAN))
      ORDER BY CASE WHEN product.ItemID = surovo.ItemID THEN 0 ELSE 1 END, product.ProductId
    ) izdelek
    WHERE NULLIF(LTRIM(RTRIM(surovo.Raven1)), N'''') IS NOT NULL
  ) zapis;

  /* Register dobaviteljevih kategorij. Ne pozna dreves in ne preslikav: pove samo, kaj je
     dobavitelj poslal. To je edini korak, ki tece tudi za vir brez ene same preslikave. */
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

  /* Drevesa: tista, ki so v uporabi na spletnih straneh in dejansko imajo kategorije.
     Prej je ta seznam prisel iz map.CategoryPathMap in je bil za nov vir prazen. */
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

  /* Kar slovar pozna, pristane v katalogu - ena vrstica na spletno stran drevesa. */
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
  ) source
    ON target.ProductId = source.ProductId AND target.WebSite = source.WebSiteCode
      AND target.CategoryPath = source.CategoryPath
  WHEN NOT MATCHED THEN INSERT (ProductId, WebSite, CategoryPath)
    VALUES (source.ProductId, source.WebSiteCode, source.CategoryPath);

  /* Cesar slovar ne pozna, gre v delovni seznam s stevcem - to ni napaka, ampak naloga. */
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

/* ---------------------------------------------------------------------------------------
   3. BT_XML: entiteta Classification in preslikavi za druzini
   --------------------------------------------------------------------------------------- */

DECLARE @Konektorji TABLE(SourceConnectorId int PRIMARY KEY);
INSERT @Konektorji(SourceConnectorId)
SELECT SourceConnectorId FROM map.SourceConnector WHERE SourceCode = N'BT_XML';

IF NOT EXISTS (SELECT 1 FROM @Konektorji)
  THROW 51200, 'BT_XML ni registriran; migracija 069 mora teci pred to.', 1;

INSERT map.EntityMapping (SourceConnectorId, EntityType, RecordXPath, IsActive, TargetDomain)
SELECT k.SourceConnectorId, N'Classification', N'/response/products/product', 1, N'Product'
FROM @Konektorji k
WHERE NOT EXISTS (SELECT 1 FROM map.EntityMapping em
                  WHERE em.SourceConnectorId = k.SourceConnectorId AND em.EntityType = N'Classification');

/* Identiteta je EAN, enako kot pri entitetah Attribute in Media istega vira. */
INSERT map.FieldMapping (SourceConnectorId, EntityType, SourceElement, TargetFieldCode, IsRequired, IsActive)
SELECT k.SourceConnectorId, N'Classification', v.SourceElement, v.TargetFieldCode, v.IsRequired, 1
FROM @Konektorji k
CROSS JOIN (VALUES
  (N'code_ean/text()[1]',                              N'Product.EAN',                    CONVERT(bit,1)),
  (N'.//attribute[slug="main_family"]/value/text()',   N'ProductCategory.SourceLevel1',   CONVERT(bit,0)),
  (N'.//attribute[slug="sub_family"]/value/text()',    N'ProductCategory.SourceLevel2',   CONVERT(bit,0))
) v(SourceElement, TargetFieldCode, IsRequired)
WHERE NOT EXISTS (SELECT 1 FROM map.FieldMapping fm
                  WHERE fm.SourceConnectorId = k.SourceConnectorId
                    AND fm.EntityType = N'Classification'
                    AND fm.TargetFieldCode = v.TargetFieldCode);
