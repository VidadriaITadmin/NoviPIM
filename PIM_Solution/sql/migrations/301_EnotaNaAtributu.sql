/*
  301 — merska enota na atributu: PIM in katalog.csv gledata samo glavni atribut v njegovi enoti.

  Uporabnik 2026-09-29: »fino bi bilo, da bi atributi imeli mersko enoto in potem uvozi prepoznajo, katero enoto
  so pisali uporabniki, potem pretvori v to«; »atribute, ki so v enoti, lahko uporabimo za lažje pisanje XML-jev,
  samo jih je treba shraniti pod enoto pod sam atribut, ker PIM in katalog.csv bo samo glavne atribute gledal in
  njihove enote da v []«; »atribute kot tekst pustiva … uvoz dovoli karkoli, enoto naj še vedno upošteva in
  opozori, naj bo vse v enoti, ki je nastavljena«.

  Stanje pred 301 (razvojna baza): 0 atributov s stalno enoto (canon.AttributeDefinition.Unit), 34 atributov enot
  (»Enota dolžine« …) s 47.529 vrednostmi in mešanimi zapisi (mm/mt, cm/mm), 148 preslikav XML v atribute enot.
  katalog.csv je enoto v glavi (»Dolžina [mm]«) in pretvorbo že imel — out.CatalogUnitRule (216).

  Kaj naredi:
    1. Glavni atribut dobi enoto iz out.CatalogUnitRule (ista kot v glavi katalog.csv): canon.AttributeDefinition.Unit;
       atribut enote dobi povezavo UnitOfAttributeCode na glavnega (če je še ni).
    2. canon.UnitConversion — količnik med enotama (mm/cm/m, g/kg, cm3/dm3/l/m3; enaka enota = 1; sopomenke mt, kgs,
       gr …). Inline funkcija, ker jo uporablja pogled nad vsemi vrednostmi.
    3. canon.AttributeUnitValue (ena vrednost) in canon.NormalizeAttributeUnits (nad začasno tabelo #AttributeSource
       klicatelja) — vrednosti atributov iz izvornega sloja (canon, kot jih pošlje vir),
       glavni atribut z enoto pretvorjen v enoto atributa (število iz vrednosti, enota iz vrednosti »5m« ali iz
       atributa enote istega izdelka ali privzeto enota atributa), atribut enote poravnan na enoto atributa.
       Vrednost, ki ni število (»do 30m«), ostane, kot je.
    4. val.Promote pred MERGE pokliče canon.NormalizeAttributeUnits (oznaka Enota301): PIM (pim.ProductAttribute) ima glavni atribut
       v enoti atributa ne glede na vir; izvorni sloj ostane nespremenjen.
    5. canon.AlignAttributeUnits + pim.SaveProductAttributes / pim.SaveProductAttributesBulk: vrednost iz intraneta
       (kartica, uvoz Excel) je v enoti atributa, zato se atribut enote tega izdelka nastavi na enoto atributa —
       sicer bi stara enota iz XML (»m«) novo vrednost v mm pretvorila še enkrat.
    6. Enkrat: PIM se uskladi s pogledom. Menja se samo vrstica, ki je enaka izvornemu sloju (razlika je samo
       enota), vsaka sprememba gre v pim.AttributeValueNormalizationLog (ChangedBy »migracija 301«).

  Objekti: canon.AttributeDefinition (Unit, UnitOfAttributeCode), canon.UnitConversion, canon.AttributeUnitValue, canon.NormalizeAttributeUnits,
  canon.AlignAttributeUnits, spremembe val.Promote, pim.SaveProductAttributes, pim.SaveProductAttributesBulk;
  podatki pim.ProductAttribute. Ročni korak: ne. Povratek: pim.AttributeValueNormalizationLog (OldValue).
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

IF UNICODE(N'č') <> 269
  THROW 53010, N'301: datoteka ni prebrana kot UTF-8 (sqlcmd -f 65001 ali Invoke-PendingMigrations.ps1).', 1;
IF OBJECT_ID(N'pim.AttributeValueNormalizationLog', N'U') IS NULL OR OBJECT_ID(N'out.CatalogUnitRule', N'U') IS NULL
  THROW 53011, N'301 potrebuje pim.AttributeValueNormalizationLog (291) in out.CatalogUnitRule (216).', 1;
GO

/* --- 1) Enota na glavnem atributu, povezava atributa enote -------------------------------------------- */
UPDATE main
SET Unit = rule_.TargetUnit, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = N'migracija 301'
FROM out.CatalogUnitRule AS rule_
INNER JOIN canon.AttributeTranslation AS mainName
  ON mainName.LanguageCode = N'sl' AND N'Attr.' + mainName.Name = rule_.ValueFieldCode
INNER JOIN canon.AttributeDefinition AS main ON main.AttributeCode = mainName.AttributeCode
WHERE rule_.IsActive = 1 AND rule_.ValueFieldCode LIKE N'Attr.%'
  AND NULLIF(LTRIM(RTRIM(main.Unit)), N'') IS NULL AND main.IsUnitCandidate = 0;

UPDATE unitDefinition
SET UnitOfAttributeCode = main.AttributeCode, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = N'migracija 301'
FROM out.CatalogUnitRule AS rule_
INNER JOIN canon.AttributeTranslation AS mainName
  ON mainName.LanguageCode = N'sl' AND N'Attr.' + mainName.Name = rule_.ValueFieldCode
INNER JOIN canon.AttributeDefinition AS main ON main.AttributeCode = mainName.AttributeCode
INNER JOIN canon.AttributeTranslation AS unitName
  ON unitName.LanguageCode = N'sl' AND N'Attr.' + unitName.Name = rule_.UnitFieldCode
INNER JOIN canon.AttributeDefinition AS unitDefinition ON unitDefinition.AttributeCode = unitName.AttributeCode
WHERE rule_.IsActive = 1 AND rule_.UnitFieldCode LIKE N'Attr.%' AND unitDefinition.UnitOfAttributeCode IS NULL;
GO

/* --- 2) Količnik med enotama ------------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION canon.UnitConversion(@FromUnit nvarchar(50), @ToUnit nvarchar(50))
RETURNS TABLE
AS RETURN
  /* 301: NULL = enote ne poznam ali nista iste vrste — klicatelj vrednosti ne spreminja. Enaka enota (tudi V, W,
     Hz, lm, K, h, °) = 1. Isto pravilo kot out.UnitFactor (216) in ProductWorkbookService.UnitFactor. */
  WITH unit AS
  (
    SELECT FromUnit = CASE LOWER(LTRIM(RTRIM(@FromUnit)))
             WHEN N'mt' THEN N'm' WHEN N'kgs' THEN N'kg' WHEN N'gr' THEN N'g' WHEN N'l' THEN N'dm3' WHEN N'dm³' THEN N'dm3'
             WHEN N'cm³' THEN N'cm3' WHEN N'm³' THEN N'm3' WHEN N'deg' THEN N'°' WHEN N'hours' THEN N'h' WHEN N'hr' THEN N'h'
             WHEN N'ur' THEN N'h' ELSE LOWER(LTRIM(RTRIM(@FromUnit))) END,
           ToUnit = CASE LOWER(LTRIM(RTRIM(@ToUnit)))
             WHEN N'mt' THEN N'm' WHEN N'kgs' THEN N'kg' WHEN N'gr' THEN N'g' WHEN N'l' THEN N'dm3' WHEN N'dm³' THEN N'dm3'
             WHEN N'cm³' THEN N'cm3' WHEN N'm³' THEN N'm3' WHEN N'deg' THEN N'°' WHEN N'hours' THEN N'h' WHEN N'hr' THEN N'h'
             WHEN N'ur' THEN N'h' ELSE LOWER(LTRIM(RTRIM(@ToUnit))) END
  )
  SELECT Factor = CASE
      WHEN unit.FromUnit IS NULL OR unit.ToUnit IS NULL OR unit.FromUnit = N'' OR unit.ToUnit = N'' THEN NULL
      WHEN unit.FromUnit = unit.ToUnit THEN CONVERT(decimal(19,9), 1)
      WHEN source.Kind = target.Kind THEN CONVERT(decimal(19,9), source.Base / target.Base)
    END
  FROM unit
  OUTER APPLY (SELECT known.Kind, known.Base FROM (VALUES (N'mm', N'len', 1.0), (N'cm', N'len', 10.0), (N'm', N'len', 1000.0),
      (N'g', N'mass', 1.0), (N'kg', N'mass', 1000.0), (N'cm3', N'vol', 1.0), (N'dm3', N'vol', 1000.0), (N'm3', N'vol', 1000000.0))
      AS known(Unit, Kind, Base) WHERE known.Unit = unit.FromUnit) AS source
  OUTER APPLY (SELECT known.Kind, known.Base FROM (VALUES (N'mm', N'len', 1.0), (N'cm', N'len', 10.0), (N'm', N'len', 1000.0),
      (N'g', N'mass', 1.0), (N'kg', N'mass', 1000.0), (N'cm3', N'vol', 1.0), (N'dm3', N'vol', 1000.0), (N'm3', N'vol', 1000000.0))
      AS known(Unit, Kind, Base) WHERE known.Unit = unit.ToUnit) AS target;
GO

/* --- 3a) Ena vrednost v enoti atributa ------------------------------------------------------------ */
CREATE OR ALTER FUNCTION canon.AttributeUnitValue(@Value nvarchar(400), @PairUnit nvarchar(100), @TargetUnit nvarchar(50))
RETURNS TABLE
AS RETURN
  /* 301: Converts = 1, kadar vrednost gre v enoto atributa (Result); sicer 0 in vrednost ostane.
     - ista enota: enota se odstrani, število ostane zapisano, kot je (»25.000 h« -> »25.000«);
     - druga znana enota iste vrste: pretvori (»5 m« ali 5 + atribut enote »m« -> 5000), razen dvoumnega zapisa
       s piko pred tremi števkami (»1.500 m« je lahko 1,5 m ali 1500 m);
     - vse drugo (»do 30m«, »~220-230«, neznana enota) ostane.
     Zapis števila brez skalarne funkcije (out.MagentoNumber je 20× počasnejša na 40.000 vrsticah). */
  SELECT Converts = CASE
      WHEN part.Number IS NULL OR factor.Factor IS NULL THEN 0
      WHEN factor.Factor = 1 THEN 1
      WHEN part.NumberText LIKE N'%[0-9].[0-9][0-9][0-9]' AND part.NumberText NOT LIKE N'%,%' THEN 0
      ELSE 1 END,
    Result = CASE
      WHEN part.Number IS NULL OR factor.Factor IS NULL THEN @Value
      WHEN factor.Factor = 1 THEN part.NumberText
      ELSE CASE WHEN RIGHT(formatted.Trimmed, 1) = N'.' THEN LEFT(formatted.Trimmed, LEN(formatted.Trimmed) - 1) ELSE formatted.Trimmed END END
  FROM (SELECT Cut = PATINDEX(N'%[^-0-9,. ]%', (ISNULL(@Value, N'') + N'x') COLLATE Latin1_General_BIN2)) AS mark
  /* BIN2: nadpisana ničla (⁰) je pod jezikovno zbirko števka (glej 216d). */
  CROSS APPLY (SELECT NumberText = NULLIF(LTRIM(RTRIM(LEFT(@Value, mark.Cut - 1))), N''),
                      InlineUnit = NULLIF(LTRIM(RTRIM(SUBSTRING(@Value, mark.Cut, 100))), N'')) AS raw_
  CROSS APPLY (SELECT raw_.NumberText, raw_.InlineUnit,
                      Number = TRY_CONVERT(decimal(19,6), REPLACE(raw_.NumberText, N',', N'.'))) AS part
  OUTER APPLY canon.UnitConversion(COALESCE(part.InlineUnit, NULLIF(LTRIM(RTRIM(@PairUnit)), N''), @TargetUnit), @TargetUnit) AS factor
  CROSS APPLY (SELECT Plain = CONVERT(nvarchar(60), CONVERT(decimal(28,6), part.Number * factor.Factor))) AS plain_
  CROSS APPLY (SELECT Trimmed = CASE WHEN CHARINDEX(N'.', plain_.Plain) = 0 THEN plain_.Plain
                 ELSE LEFT(plain_.Plain, LEN(plain_.Plain) - PATINDEX(N'%[^0]%', REVERSE(plain_.Plain)) + 1) END) AS formatted
  WHERE @Value IS NOT NULL AND @TargetUnit IS NOT NULL;
GO

/* --- 3) Vrednosti v enoti atributa (nad začasno tabelo klicatelja) ------------------------------ */
DROP VIEW IF EXISTS canon.ProductAttributeUnitNormalized;   /* prva različica 301 na razvojni bazi: prepočasna (>10 min) */
GO
CREATE OR ALTER PROCEDURE canon.NormalizeAttributeUnits
AS
BEGIN
  /* 301: klicatelj pripravi #AttributeSource (ProductId, AttributeCode, LanguageCode, Value, OriginalValue = Value);
     postopek v Value zapiše glavni atribut v enoti atributa in atribut enote poravna na to enoto (pravilo v
     canon.AttributeUnitValue). Vse nad začasno tabelo in z enim branjem pravil — pogled nad vsemi 365.000
     vrednostmi je bil na razvojni bazi prepočasen. */
  SET NOCOUNT ON;
  CREATE TABLE #UnitRule
    (MainName nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY, UnitName nvarchar(200) COLLATE DATABASE_DEFAULT NULL,
     TargetUnit nvarchar(50) COLLATE DATABASE_DEFAULT NOT NULL);
  INSERT #UnitRule (MainName, UnitName, TargetUnit)
  SELECT mainName.Name, MIN(unitName.Name), MIN(LTRIM(RTRIM(main.Unit)))
  FROM canon.AttributeDefinition AS main
  INNER JOIN canon.AttributeTranslation AS mainName ON mainName.AttributeCode = main.AttributeCode AND mainName.LanguageCode = N'sl'
  LEFT JOIN canon.AttributeDefinition AS unitDefinition ON unitDefinition.UnitOfAttributeCode = main.AttributeCode AND unitDefinition.IsActive = 1
  LEFT JOIN canon.AttributeTranslation AS unitName ON unitName.AttributeCode = unitDefinition.AttributeCode AND unitName.LanguageCode = N'sl'
  WHERE main.IsActive = 1 AND main.IsUnitCandidate = 0 AND NULLIF(LTRIM(RTRIM(main.Unit)), N'') IS NOT NULL
  GROUP BY mainName.Name;
  IF NOT EXISTS (SELECT 1 FROM #UnitRule) RETURN;

  /* Samo vrstice atributov z enoto in njihovih atributov enot (vrednosti so kratke: do 400 znakov). */
  CREATE TABLE #UnitRow
    (ProductId bigint NOT NULL, AttributeCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
     LanguageCode nvarchar(20) COLLATE DATABASE_DEFAULT NULL, OriginalValue nvarchar(400) COLLATE DATABASE_DEFAULT NULL,
     IsMain bit NOT NULL);
  INSERT #UnitRow (ProductId, AttributeCode, LanguageCode, OriginalValue, IsMain)
  SELECT source.ProductId, source.AttributeCode, source.LanguageCode, LEFT(source.OriginalValue, 400),
    CASE WHEN rule_.MainName IS NOT NULL THEN 1 ELSE 0 END
  FROM #AttributeSource AS source
  LEFT JOIN #UnitRule AS rule_ ON rule_.MainName = source.AttributeCode
  WHERE (rule_.MainName IS NOT NULL OR EXISTS (SELECT 1 FROM #UnitRule AS unitRule WHERE unitRule.UnitName = source.AttributeCode))
    AND LEN(source.OriginalValue) <= 400;

  /* Enota iz atributa enote istega izdelka (ena na izdelek). */
  CREATE TABLE #PairUnit (ProductId bigint NOT NULL, MainName nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
    UnitValue nvarchar(100) COLLATE DATABASE_DEFAULT NULL, PRIMARY KEY (ProductId, MainName));
  INSERT #PairUnit (ProductId, MainName, UnitValue)
  SELECT unit.ProductId, rule_.MainName, MAX(LEFT(LTRIM(RTRIM(unit.OriginalValue)), 100))
  FROM #UnitRow AS unit
  INNER JOIN #UnitRule AS rule_ ON rule_.UnitName = unit.AttributeCode
  WHERE NULLIF(LTRIM(RTRIM(unit.OriginalValue)), N'') IS NOT NULL
  GROUP BY unit.ProductId, rule_.MainName;

  /* Glavni atribut: enota iz vrednosti ali iz atributa enote istega izdelka. */
  CREATE TABLE #MainResult (ProductId bigint NOT NULL, AttributeCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
    LanguageCode nvarchar(20) COLLATE DATABASE_DEFAULT NULL, Value nvarchar(400) COLLATE DATABASE_DEFAULT NULL);
  INSERT #MainResult (ProductId, AttributeCode, LanguageCode, Value)
  SELECT main.ProductId, main.AttributeCode, main.LanguageCode, converted.Result
  FROM #UnitRow AS main
  INNER JOIN #UnitRule AS rule_ ON rule_.MainName = main.AttributeCode
  LEFT JOIN #PairUnit AS pair ON pair.ProductId = main.ProductId AND pair.MainName = main.AttributeCode
  CROSS APPLY canon.AttributeUnitValue(main.OriginalValue, pair.UnitValue, rule_.TargetUnit) AS converted
  WHERE main.IsMain = 1 AND converted.Converts = 1;

  CREATE TABLE #UnitResult
    (ProductId bigint NOT NULL, AttributeCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
     LanguageCode nvarchar(20) COLLATE DATABASE_DEFAULT NULL, Value nvarchar(400) COLLATE DATABASE_DEFAULT NULL);
  INSERT #UnitResult (ProductId, AttributeCode, LanguageCode, Value)
  SELECT ProductId, AttributeCode, LanguageCode, Value FROM #MainResult;

  /* Atribut enote: enota atributa, kadar se glavni atribut istega izdelka pretvori. */
  INSERT #UnitResult (ProductId, AttributeCode, LanguageCode, Value)
  SELECT unit.ProductId, unit.AttributeCode, unit.LanguageCode, rule_.TargetUnit
  FROM #UnitRow AS unit
  INNER JOIN #UnitRule AS rule_ ON rule_.UnitName = unit.AttributeCode
  WHERE unit.IsMain = 0
    AND EXISTS (SELECT 1 FROM #MainResult AS main WHERE main.ProductId = unit.ProductId AND main.AttributeCode = rule_.MainName);

  UPDATE source SET Value = result.Value
  FROM #AttributeSource AS source
  INNER JOIN #UnitResult AS result ON result.ProductId = source.ProductId AND result.AttributeCode = source.AttributeCode
   AND ISNULL(result.LanguageCode, N'~') = ISNULL(source.LanguageCode, N'~');
END;
GO

/* --- 4) val.Promote: atributi v PIM v enoti atributa ------------------------------------------- */
DECLARE @Definition nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'val.Promote'));
IF @Definition NOT LIKE N'%Enota301%'
BEGIN
  DECLARE @StartText nvarchar(100) = N'    MERGE pim.ProductAttribute AS target';
  DECLARE @EndText nvarchar(200) = N'VALUES (source.PimProductId, source.AttributeCode, source.LanguageCode, source.Value);';
  DECLARE @Start int = CHARINDEX(@StartText, @Definition);
  DECLARE @End int = CASE WHEN @Start > 0 THEN CHARINDEX(@EndText, @Definition, @Start) ELSE 0 END;
  IF @Start = 0 OR @End = 0 OR CHARINDEX(@StartText, @Definition, @Start + 1) > 0
     OR SUBSTRING(@Definition, @Start, @End - @Start) NOT LIKE N'%INNER JOIN canon.ProductAttribute a ON a.ProductId = o.ProductId%'
    THROW 53012, N'301: val.Promote nima pričakovanega bloka atributov (enkrat); nič ni spremenjeno.', 1;
  SET @End = @End + LEN(@EndText);
  DECLARE @Block nvarchar(max) = N'    /* Enota301: glavni atribut v enoti atributa (canon.NormalizeAttributeUnits); izvorni sloj ostane, kot je.
       124: jezik je stolpec, ne del imena (brez njega bi MERGE padel z 8672). */
    CREATE TABLE #AttributeSource
      (ProductId bigint NOT NULL, PimProductId bigint NOT NULL,
       AttributeCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL, LanguageCode nvarchar(20) COLLATE DATABASE_DEFAULT NULL,
       Value nvarchar(max) COLLATE DATABASE_DEFAULT NULL, OriginalValue nvarchar(max) COLLATE DATABASE_DEFAULT NULL);
    INSERT #AttributeSource (ProductId, PimProductId, AttributeCode, LanguageCode, Value, OriginalValue)
    SELECT a.ProductId, o.PimProductId, a.AttributeCode, a.LanguageCode, a.Value, a.Value
    FROM @Objavljeni o INNER JOIN canon.ProductAttribute a ON a.ProductId = o.ProductId;
    EXEC canon.NormalizeAttributeUnits;

    MERGE pim.ProductAttribute AS target
    USING (SELECT PimProductId, AttributeCode, LanguageCode, Value FROM #AttributeSource) AS source
    ON target.PimProductId = source.PimProductId AND target.AttributeCode = source.AttributeCode
      AND ISNULL(target.LanguageCode, N''~'') = ISNULL(source.LanguageCode, N''~'')
    WHEN MATCHED THEN UPDATE SET Value = source.Value
    WHEN NOT MATCHED THEN INSERT (PimProductId, AttributeCode, LanguageCode, Value)
      VALUES (source.PimProductId, source.AttributeCode, source.LanguageCode, source.Value);
    DROP TABLE #AttributeSource;';
  SET @Definition = STUFF(@Definition, @Start, @End - @Start, @Block);
  SET @Definition = N'ALTER ' + SUBSTRING(@Definition, CHARINDEX(N'PROCEDURE', @Definition), 2147483647);
  EXEC sys.sp_executesql @Definition;
END;
GO

/* --- 5) Vrednost iz intraneta je v enoti atributa: atribut enote se poravna ------------------------- */
CREATE OR ALTER PROCEDURE canon.AlignAttributeUnits
  @PairsJson nvarchar(max)   /* [{"productId":123,"attributeCode":"Dolžina"}, ...] — kaj je intranet pravkar zapisal */
AS
BEGIN
  /* 301: kliče se znotraj transakcije shranjevanja (pim.SaveProductAttributes[Bulk]). Za vsak zapisan glavni
     atribut z enoto: atribut enote izdelka = enota atributa; izbrisan glavni atribut izbriše tudi atribut enote. */
  SET NOCOUNT ON;
  IF @PairsJson IS NULL RETURN;
  CREATE TABLE #Pair (ProductId bigint NOT NULL, MainName nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
    UnitName nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL, TargetUnit nvarchar(50) COLLATE DATABASE_DEFAULT NOT NULL,
    HasValue bit NOT NULL, PRIMARY KEY (ProductId, UnitName));
  INSERT #Pair (ProductId, MainName, UnitName, TargetUnit, HasValue)
  SELECT DISTINCT pair.productId, mainName.Name, unitName.Name, LTRIM(RTRIM(main.Unit)),
    CASE WHEN EXISTS (SELECT 1 FROM canon.ProductAttribute AS value WHERE value.ProductId = pair.productId
                        AND value.AttributeCode = mainName.Name AND NULLIF(LTRIM(RTRIM(value.Value)), N'') IS NOT NULL) THEN 1 ELSE 0 END
  FROM OPENJSON(@PairsJson) WITH (productId bigint N'$.productId', attributeCode nvarchar(200) N'$.attributeCode') AS pair
  INNER JOIN canon.AttributeTranslation AS mainName ON mainName.LanguageCode = N'sl' AND mainName.Name = LTRIM(RTRIM(pair.attributeCode))
  INNER JOIN canon.AttributeDefinition AS main ON main.AttributeCode = mainName.AttributeCode AND main.IsActive = 1
    AND main.IsUnitCandidate = 0 AND NULLIF(LTRIM(RTRIM(main.Unit)), N'') IS NOT NULL
  INNER JOIN canon.AttributeDefinition AS unitDefinition ON unitDefinition.UnitOfAttributeCode = main.AttributeCode AND unitDefinition.IsActive = 1
  INNER JOIN canon.AttributeTranslation AS unitName ON unitName.AttributeCode = unitDefinition.AttributeCode AND unitName.LanguageCode = N'sl'
  WHERE pair.productId IS NOT NULL;

  DELETE unitValue FROM canon.ProductAttribute AS unitValue
  INNER JOIN #Pair AS pair ON pair.ProductId = unitValue.ProductId AND pair.UnitName = unitValue.AttributeCode
  WHERE pair.HasValue = 0;

  MERGE canon.ProductAttribute AS target
  USING (SELECT ProductId, UnitName, TargetUnit FROM #Pair WHERE HasValue = 1) AS source
  ON target.ProductId = source.ProductId AND target.AttributeCode = source.UnitName
  WHEN MATCHED AND ISNULL(target.Value, N'') <> source.TargetUnit THEN UPDATE SET Value = source.TargetUnit
  WHEN NOT MATCHED THEN INSERT (ProductId, AttributeCode, Value) VALUES (source.ProductId, source.UnitName, source.TargetUnit);
END;
GO

DECLARE @Proc sysname, @Definition nvarchar(max), @Call nvarchar(600), @Anchor nvarchar(100) = N'    COMMIT TRANSACTION;';
DECLARE procs CURSOR LOCAL FAST_FORWARD FOR
  SELECT name, call_ FROM (VALUES
    (N'pim.SaveProductAttributesBulk', N'    /* Enota301 */ DECLARE @Pairs301 nvarchar(max) = (SELECT ProductId AS productId, AttributeCode AS attributeCode FROM @Changes FOR JSON PATH);
    EXEC canon.AlignAttributeUnits @PairsJson = @Pairs301;
'),
    (N'pim.SaveProductAttributes', N'    /* Enota301 */ DECLARE @Pairs301 nvarchar(max) = (SELECT @ProductId AS productId, AttributeCode AS attributeCode FROM @Changes FOR JSON PATH);
    EXEC canon.AlignAttributeUnits @PairsJson = @Pairs301;
')) AS target_(name, call_);
OPEN procs;
FETCH NEXT FROM procs INTO @Proc, @Call;
WHILE @@FETCH_STATUS = 0
BEGIN
  SET @Definition = OBJECT_DEFINITION(OBJECT_ID(@Proc));
  IF @Definition NOT LIKE N'%/* Enota301 */%'
  BEGIN
    IF (LEN(@Definition) - LEN(REPLACE(@Definition, @Anchor, N''))) / LEN(@Anchor) <> 1
      THROW 53013, N'301: shranjevanje atributov nima pričakovanega COMMIT (enkrat); nič ni spremenjeno.', 1;
    SET @Definition = STUFF(@Definition, CHARINDEX(@Anchor, @Definition), 0, @Call);
    SET @Definition = N'ALTER ' + SUBSTRING(@Definition, CHARINDEX(N'PROCEDURE', @Definition), 2147483647);
    EXEC sys.sp_executesql @Definition;
  END;
  FETCH NEXT FROM procs INTO @Proc, @Call;
END;
CLOSE procs;
DEALLOCATE procs;
GO

/* --- 6) Enkratna uskladitev PIM (samo vrstice, ki so enake izvornemu sloju) ------------------------ */
CREATE TABLE #AttributeSource
  (ProductId bigint NOT NULL, PimProductAttributeId bigint NOT NULL, OrganizationId int NOT NULL,
   ItemID nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL, AttributeCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
   LanguageCode nvarchar(20) COLLATE DATABASE_DEFAULT NULL, Value nvarchar(max) COLLATE DATABASE_DEFAULT NULL,
   OriginalValue nvarchar(max) COLLATE DATABASE_DEFAULT NULL, PimValue nvarchar(max) COLLATE DATABASE_DEFAULT NULL);
INSERT #AttributeSource (ProductId, PimProductAttributeId, OrganizationId, ItemID, AttributeCode, LanguageCode, Value, OriginalValue, PimValue)
SELECT canonValue.ProductId, pimValue.PimProductAttributeId, pimProduct.OrganizationId, pimProduct.ItemID, canonValue.AttributeCode,
  canonValue.LanguageCode, canonValue.Value, canonValue.Value, pimValue.Value
FROM pim.ProductAttribute AS pimValue
INNER JOIN pim.Product AS pimProduct ON pimProduct.PimProductId = pimValue.PimProductId
INNER JOIN canon.Product AS canonProduct ON canonProduct.OrganizationId = pimProduct.OrganizationId AND canonProduct.ItemID = pimProduct.ItemID
INNER JOIN canon.ProductAttribute AS canonValue
  ON canonValue.ProductId = canonProduct.ProductId AND canonValue.AttributeCode = pimValue.AttributeCode
 AND ISNULL(canonValue.LanguageCode, N'~') = ISNULL(pimValue.LanguageCode, N'~');
EXEC canon.NormalizeAttributeUnits;

CREATE TABLE #Normalize301
  (PimProductAttributeId bigint NOT NULL PRIMARY KEY, OrganizationId int NOT NULL,
   ItemID nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL, AttributeCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
   LanguageCode nvarchar(20) COLLATE DATABASE_DEFAULT NULL, OldValue nvarchar(max) COLLATE DATABASE_DEFAULT NULL,
   NewValue nvarchar(max) COLLATE DATABASE_DEFAULT NULL);
INSERT #Normalize301 (PimProductAttributeId, OrganizationId, ItemID, AttributeCode, LanguageCode, OldValue, NewValue)
SELECT PimProductAttributeId, OrganizationId, ItemID, AttributeCode, LanguageCode, PimValue, Value
FROM #AttributeSource
WHERE ISNULL(Value, N'') <> ISNULL(OriginalValue, N'') AND ISNULL(PimValue, N'') = ISNULL(OriginalValue, N'');
DROP TABLE #AttributeSource;

BEGIN TRANSACTION;
INSERT pim.AttributeValueNormalizationLog (TableName, RowId, OrganizationId, ItemID, AttributeCode, LanguageCode, OldValue, NewValue, ChangedUtc, ChangedBy)
SELECT N'pim.ProductAttribute', PimProductAttributeId, OrganizationId, ItemID, AttributeCode, LanguageCode, OldValue, NewValue,
  SYSUTCDATETIME(), N'migracija 301'
FROM #Normalize301;
UPDATE pimValue SET Value = normalized.NewValue
FROM pim.ProductAttribute AS pimValue
INNER JOIN #Normalize301 AS normalized ON normalized.PimProductAttributeId = pimValue.PimProductAttributeId;
COMMIT;

DECLARE @Changed int = (SELECT COUNT(*) FROM #Normalize301);
RAISERROR(N'301: v PIM usklajenih %d vrednosti atributov (dnevnik pim.AttributeValueNormalizationLog).', 0, 1, @Changed) WITH NOWAIT;
DROP TABLE #Normalize301;
GO

/* --- dokaz ------------------------------------------------------------------------------- */
IF OBJECT_DEFINITION(OBJECT_ID(N'val.Promote')) NOT LIKE N'%canon.NormalizeAttributeUnits%'
   OR OBJECT_DEFINITION(OBJECT_ID(N'pim.SaveProductAttributes')) NOT LIKE N'%/* Enota301 */%'
   OR OBJECT_DEFINITION(OBJECT_ID(N'pim.SaveProductAttributesBulk')) NOT LIKE N'%/* Enota301 */%'
   OR OBJECT_ID(N'canon.NormalizeAttributeUnits', N'P') IS NULL
  THROW 53014, N'301: ni uveljavljena v celoti.', 1;
GO
