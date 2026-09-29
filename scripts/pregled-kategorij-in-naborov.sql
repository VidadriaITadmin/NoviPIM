/*
  Pregled kategorij in naborov atributov po drevesu (svetila ali videlektro) — vse v slovenščini.

  Uporaba: nastavi @Drevo na N'svetila_si' (svetila.si) ali N'videlektro' (videlektro.si) in zaženi.
  Samo bere. Vrne tri tabele:
    1. Kategorije  — drevo z imeni SL/EN, številom izdelkov in velikostjo nabora (lasten / skupaj s podedovanim).
    2. Nabori      — za vsako kategorijo vsi atributi, ki zanjo veljajo (lastni in podedovani), z izpolnjenostjo.
    3. Brez nabora — atributi, ki jih izdelki v kategoriji imajo izpolnjene, v naboru pa niso (kandidati za dodati).

  Izdelki = vsa podjetja (IQ in ViD), uvrščeni točno v to kategorijo (slovensko spletišče drevesa).
*/
SET NOCOUNT ON;

DECLARE @Drevo nvarchar(100) = N'svetila_si';   -- ali N'videlektro'

/* Slovenska spletišča drevesa (za svetila: svetila_si, za videlektro: B2C). */
DECLARE @Spletisca TABLE (WebSiteCode nvarchar(100) PRIMARY KEY);
INSERT @Spletisca SELECT WebSiteCode FROM canon.WebSite WHERE CategoryTreeCode = @Drevo AND LanguageCode = N'sl' AND IsActive = 1;

/* Izdelki po kategoriji (točna uvrstitev). */
SELECT kategorija.CategoryCode, izdelek.PimProductId, izdelek.OrganizationId
INTO #IzdelekVKategoriji
FROM canon.Category AS kategorija
INNER JOIN pim.ProductCategory AS uvrstitev
  ON uvrstitev.CategoryPath = kategorija.CategoryPath AND uvrstitev.WebSite IN (SELECT WebSiteCode FROM @Spletisca)
INNER JOIN pim.Product AS izdelek ON izdelek.PimProductId = uvrstitev.PimProductId
WHERE kategorija.CategoryTreeCode = @Drevo AND kategorija.IsActive = 1
GROUP BY kategorija.CategoryCode, izdelek.PimProductId, izdelek.OrganizationId;

/* Veljavni nabor vsake kategorije (lasten + podedovan od prednikov; najbližji zmaga). */
SELECT kategorija.CategoryCode, nabor.AttributeCode, nabor.Level, nabor.SortOrder, nabor.Note,
       nabor.DefinedAtCategoryCode, nabor.IsInherited
INTO #Nabor
FROM canon.Category AS kategorija
CROSS APPLY canon.CategoryAttributeEffective(kategorija.CategoryTreeCode, kategorija.CategoryCode) AS nabor
WHERE kategorija.CategoryTreeCode = @Drevo AND kategorija.IsActive = 1;

/* ---- 1. Kategorije ---------------------------------------------------------------------------- */
SELECT
  [Pot kategorije]           = kategorija.CategoryPath,
  [Raven]                    = kategorija.LevelNo,
  [Ime (SL)]                 = ISNULL(sl.CategoryName, kategorija.CategoryName),
  [Ime (EN)]                 = en.CategoryName,
  [Aktivna]                  = CASE WHEN kategorija.IsActive = 1 THEN N'Da' ELSE N'Ne' END,
  [Izdelkov IQ]              = (SELECT COUNT(DISTINCT i.PimProductId) FROM #IzdelekVKategoriji i WHERE i.CategoryCode = kategorija.CategoryCode AND i.OrganizationId = 2),
  [Izdelkov ViD]             = (SELECT COUNT(DISTINCT i.PimProductId) FROM #IzdelekVKategoriji i WHERE i.CategoryCode = kategorija.CategoryCode AND i.OrganizationId = 3),
  [Atributov v lastnem naboru] = (SELECT COUNT(*) FROM #Nabor n WHERE n.CategoryCode = kategorija.CategoryCode AND n.IsInherited = 0),
  [Atributov skupaj (s podedovanimi)] = (SELECT COUNT(*) FROM #Nabor n WHERE n.CategoryCode = kategorija.CategoryCode),
  [Brez prevoda EN]          = CASE WHEN en.CategoryName IS NULL THEN N'Manjka' ELSE N'' END,
  [Koda kategorije]          = kategorija.CategoryCode
FROM canon.Category AS kategorija
LEFT JOIN canon.CategoryTranslation AS sl ON sl.CategoryTreeCode = kategorija.CategoryTreeCode AND sl.CategoryCode = kategorija.CategoryCode AND sl.LanguageCode = N'sl'
LEFT JOIN canon.CategoryTranslation AS en ON en.CategoryTreeCode = kategorija.CategoryTreeCode AND en.CategoryCode = kategorija.CategoryCode AND en.LanguageCode = N'en'
WHERE kategorija.CategoryTreeCode = @Drevo
ORDER BY kategorija.CategoryPath;

/* ---- 2. Nabori atributov po kategoriji ----------------------------------------------------------- */
SELECT
  [Pot kategorije]      = kategorija.CategoryPath,
  [Atribut]             = ISNULL(ime.Name, nabor.AttributeCode),
  [Raven]               = CASE nabor.Level WHEN N'REQUIRED' THEN N'Obvezen' WHEN N'RECOMMENDED' THEN N'Priporočen'
                                           WHEN N'EXCLUDED' THEN N'Izločen' ELSE nabor.Level END,
  [Od kod]              = CASE WHEN nabor.IsInherited = 1 THEN N'Podedovano od: ' + izvor.CategoryPath ELSE N'Lasten' END,
  [Vrstni red]          = nabor.SortOrder,
  [Vrsta podatka]       = CASE definicija.DataType WHEN N'TEXT' THEN N'Besedilo' WHEN N'NUMBER' THEN N'Število'
                                                   WHEN N'BOOL' THEN N'Da/Ne' WHEN N'ENUM' THEN N'Seznam' ELSE definicija.DataType END,
  [Enota]               = definicija.Unit,
  [Prevajan (SL/EN)]    = CASE WHEN definicija.IsTranslatable = 1 THEN N'Da' ELSE N'Ne' END,
  [Atribut aktiven]     = CASE WHEN definicija.IsActive = 1 THEN N'Da' WHEN definicija.IsActive = 0 THEN N'Ne' ELSE N'Ni v registru' END,
  [Izdelkov v kategoriji] = izpolnjenost.Vseh,
  [Z vrednostjo]        = izpolnjenost.Izpolnjenih,
  [Izpolnjenost %]      = CASE WHEN izpolnjenost.Vseh = 0 THEN NULL ELSE CONVERT(decimal(5,1), 100.0 * izpolnjenost.Izpolnjenih / izpolnjenost.Vseh) END,
  [Različnih vrednosti] = izpolnjenost.Razlicnih,
  [Primeri vrednosti]   = izpolnjenost.Primeri,
  [Opomba]              = nabor.Note,
  [Koda atributa]       = nabor.AttributeCode
FROM #Nabor AS nabor
INNER JOIN canon.Category AS kategorija ON kategorija.CategoryTreeCode = @Drevo AND kategorija.CategoryCode = nabor.CategoryCode
INNER JOIN canon.Category AS izvor ON izvor.CategoryTreeCode = @Drevo AND izvor.CategoryCode = nabor.DefinedAtCategoryCode
LEFT JOIN canon.AttributeTranslation AS ime ON ime.AttributeCode = nabor.AttributeCode AND ime.LanguageCode = N'sl'
LEFT JOIN canon.AttributeDefinition AS definicija ON definicija.AttributeCode = nabor.AttributeCode
OUTER APPLY
(
  SELECT
    Vseh        = (SELECT COUNT(DISTINCT i.PimProductId) FROM #IzdelekVKategoriji i WHERE i.CategoryCode = nabor.CategoryCode),
    Izpolnjenih = COUNT(DISTINCT vrednost.PimProductId),
    Razlicnih   = COUNT(DISTINCT CASE WHEN ISNULL(vrednost.LanguageCode, N'sl') = N'sl' THEN vrednost.Value END),
    Primeri     = (SELECT STRING_AGG(CONVERT(nvarchar(max), p.Value), N' | ') WITHIN GROUP (ORDER BY p.Stevilo DESC)
                   FROM (SELECT TOP (6) v.Value, COUNT(*) AS Stevilo
                         FROM #IzdelekVKategoriji i
                         INNER JOIN pim.ProductAttribute v ON v.PimProductId = i.PimProductId AND v.AttributeCode = ime.Name
                           AND NULLIF(v.Value, N'') IS NOT NULL AND ISNULL(v.LanguageCode, N'sl') = N'sl'
                         WHERE i.CategoryCode = nabor.CategoryCode
                         GROUP BY v.Value ORDER BY COUNT(*) DESC) AS p)
  FROM #IzdelekVKategoriji AS i
  INNER JOIN pim.ProductAttribute AS vrednost
    ON vrednost.PimProductId = i.PimProductId AND vrednost.AttributeCode = ime.Name AND NULLIF(vrednost.Value, N'') IS NOT NULL
  WHERE i.CategoryCode = nabor.CategoryCode
) AS izpolnjenost
ORDER BY kategorija.CategoryPath, nabor.SortOrder, [Atribut];

/* ---- 3. Atributi, ki jih izdelki imajo, v naboru kategorije pa niso ------------------------------- */
SELECT
  [Pot kategorije]      = kategorija.CategoryPath,
  [Atribut]             = vrednost.AttributeCode,
  [Izdelkov v kategoriji] = (SELECT COUNT(DISTINCT x.PimProductId) FROM #IzdelekVKategoriji x WHERE x.CategoryCode = kategorija.CategoryCode),
  [Z vrednostjo]        = COUNT(DISTINCT vrednost.PimProductId),
  [Različnih vrednosti] = COUNT(DISTINCT CASE WHEN ISNULL(vrednost.LanguageCode, N'sl') = N'sl' THEN vrednost.Value END),
  [Primer vrednosti]    = MIN(CASE WHEN ISNULL(vrednost.LanguageCode, N'sl') = N'sl' THEN vrednost.Value END),
  [Kategorija ima nabor] = CASE WHEN EXISTS (SELECT 1 FROM #Nabor n WHERE n.CategoryCode = kategorija.CategoryCode) THEN N'Da' ELSE N'Ne' END
FROM #IzdelekVKategoriji AS i
INNER JOIN canon.Category AS kategorija ON kategorija.CategoryTreeCode = @Drevo AND kategorija.CategoryCode = i.CategoryCode
INNER JOIN pim.ProductAttribute AS vrednost ON vrednost.PimProductId = i.PimProductId AND NULLIF(vrednost.Value, N'') IS NOT NULL
WHERE vrednost.AttributeCode NOT LIKE N'Enota %'                       -- enote so v glavi stolpca
  AND NOT EXISTS (SELECT 1 FROM #Nabor n
                  INNER JOIN canon.AttributeTranslation t ON t.AttributeCode = n.AttributeCode AND t.LanguageCode = N'sl'
                  WHERE n.CategoryCode = kategorija.CategoryCode AND t.Name = vrednost.AttributeCode)
GROUP BY kategorija.CategoryCode, kategorija.CategoryPath, vrednost.AttributeCode
ORDER BY kategorija.CategoryPath, COUNT(DISTINCT vrednost.PimProductId) DESC;

DROP TABLE #IzdelekVKategoriji;
DROP TABLE #Nabor;
