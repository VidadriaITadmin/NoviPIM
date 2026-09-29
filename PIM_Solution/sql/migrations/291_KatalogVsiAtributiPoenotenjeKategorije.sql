/*
  291 — katalog.csv: vsi atributi, poenotene vrednosti atributov, samo veljavne kategorije.

  Uporabnik 2026-09-28: »Pazi, da bodo vsi atributi notri, da kljukice za Spletne strani delajo zanesljivo,
  da imamo za Napetost vedno isto za izmenično in za frekvenco tudi, kategorije morajo štimati.«
  Primer s spleta: filter »NAPETOST (V)« je kazal »~220-230« (111) in »220-230« (22) kot dve vrednosti.

  Meritve na razvojni bazi (DAVID\MSSQL19), 2026-09-28, pred 291:
    - 81.257 vrednosti atributov je bilo v PIM, stolpec v katalogu je obstajal, v katalog.csv pa je ostal prazen.
      Vzrok: 147 (#AttributeFilter) — ko ima kategorija izdelka nabor atributov, so šli v izvoz SAMO atributi
      iz nabora; vse ostalo (mere paketa I, kolekcija, grlo, električni razred, PCN …) je izpadlo.
    - Napetost: ~220-230 / 220-230 / 220/230 / ~220-230V / 220-230V / ~220-30 za isto izmenično napetost;
      24 / 48 / DC5 brez oznake enosmerne. Frekvenca: 50/60 / 50/60 Hz / 50-60 / 50-60Hz.
      CRI »≥ 80« in »≥80«, faktor moči »>0,5« in »>0.5«, mere z decimalno vejico ali piko.
    - Kategorije: 385 poti na videlektro (org 2) ni bilo v drevesu (okrnjene »1-fazni Profile« brez
      »Razsvetljava > Tračni sistemi«, ostanki starih preslikav); prevod »1-fazni 48V LVM« v EN je bil
      »1-circuit 48V   UT- LVM« (napačen sistem in trije presledki). Vzrok, da ostanki ostanejo:
      map.ResolveProductCategories in val.Promote poti samo dodajata, stare nikoli ne odstranita.
    - Kljukice »Spletne strani«: kartica (pim.WebShopReason = PUBLISHED) in izvoz (#Site) sta se ujemala
      v 100 % (org 2: 2176/2176, org 3: 2448/2448) — pravilo ostane nespremenjeno.

  Kaj naredi 291:
    1. pim.NormalizeAttributeValue — eno pravilo poenotenja za izvoz, zajem in obstoječe podatke:
         - presledki: odreže, več zaporednih v enega, trd presledek v navadnega;
         - znak na začetku: »≥ 80« → »≥80«, »> 0,5« → »>0,5«;
         - število z decimalno vejico (samo čisto število ali razpon) → pika: »1,08« → »1.08«;
         - Napetost: izmenična vedno »~220-230«, enosmerna vedno »DC 24«; enota V odpade (je v glavi);
           brez oznake: od 100 V naprej izmenična, pod 100 V enosmerna (220-240 → ~220-240, 48 → DC 48);
         - Frekvenca: »50/60« (Hz odpade, 50-60 → 50/60);
         - na koncu slovar map.ValueLookup z jezikom »ENOTNO« (domena = ime atributa ali *), ki ga
           uporabnik ureja na /pravila/slovar — za izjeme in tipkarske napake (~220-30 → ~220-230).
    2. Obstoječe vrednosti v canon.ProductAttribute (sprožilec zapiše pim.ProductFieldHistory) in
       pim.ProductAttribute (dnevnik pim.AttributeValueNormalizationLog) se poenotijo — prej/potem ostane.
    3. map.ApplyValueTransforms poenoti vrednosti atributov vsakega zajema (XML, SAOP) — izvirnik ostane
       v map.ExtractedValue.RawValue (ponovna obdelava 094 ga vrne), zato novi uvozi ne prinesejo starih zapisov.
    4. out.GetExportRows:
         - nabor atributov kategorije je le še izločevalen: izpade samo atribut z ravnijo EXCLUDED
           (in ne REQUIRED/RECOMMENDED v drugi kategoriji izdelka); vse ostalo gre v izvoz;
           ker EXCLUDED zdaj nikjer ni, se izračun nabora preskoči (hitreje);
         - vsaka vrednost atributa gre skozi pim.NormalizeAttributeValue;
         - v stolpce kategorij gre samo pot, ki obstaja v drevesu v jeziku spletišča
           (canon.CategoryPathTranslated) — Magento ne dobi več izmišljenih kategorij.
    5. Kategorije:
         - prevod EN »1-fazni 48V LVM« → »1-circuit 48V LVM« (canon.SaveCategoryTranslations, zgodovina),
           angleške poti izdelkov pod tem vozliščem se prepišejo;
         - odvečne neveljavne poti (izdelek ima na istem spletišču tudi veljavno) se odstranijo iz canon in pim;
           kopija v canon.ProductCategory_pred291 / pim.ProductCategory_pred291 (razveljavitev = INSERT nazaj);
         - map.ResolveProductCategories in val.Promote po zapisu odstranita isto vrsto ostankov za obdelane
           izdelke (samo neveljavno pot in samo, če ima izdelek na istem spletišču veljavno; ročna uvrstitev ostane).

  Objekti: nov indeks IX_ValueLookup_LanguageKey, nova funkcija pim.NormalizeAttributeValue, nova tabela
  pim.AttributeValueNormalizationLog, kopiji *_pred291, spremembe out.GetExportRows, map.ApplyValueTransforms,
  map.ResolveProductCategories, val.Promote; podatki canon/pim.ProductAttribute, canon/pim.ProductCategory,
  canon.CategoryTranslation, map.ValueLookup (1 vrstica). Ročni korak: ne. Migrator ne pozna GO.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;

IF UNICODE(N'č') <> 269
  THROW 52910, N'291: datoteka ni prebrana kot UTF-8 (sqlcmd -f 65001 ali Invoke-PendingMigrations.ps1).', 1;
IF OBJECT_ID(N'out.GetExportRows', N'P') IS NULL OR OBJECT_ID(N'map.ApplyValueTransforms', N'P') IS NULL
   OR OBJECT_ID(N'map.ResolveProductCategories', N'P') IS NULL OR OBJECT_ID(N'val.Promote', N'P') IS NULL
   OR OBJECT_ID(N'canon.CategoryPathTranslated', N'V') IS NULL OR OBJECT_ID(N'canon.SaveCategoryTranslations', N'P') IS NULL
  THROW 52911, N'291 potrebuje out.GetExportRows, map.ApplyValueTransforms, map.ResolveProductCategories, val.Promote, canon.CategoryPathTranslated in canon.SaveCategoryTranslations.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows')) NOT LIKE N'%/* 287 */%'
  THROW 52912, N'291: najprej 287 (out.GetExportRows brez oznake 287).', 1;

/* === 1. Slovar: hitro iskanje po jeziku in ključu + pravilo za tipkarsko napako ====================== */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'map.ValueLookup') AND name = N'IX_ValueLookup_LanguageKey')
  CREATE INDEX IX_ValueLookup_LanguageKey ON map.ValueLookup (Language, SourceKey, Domain) INCLUDE (TargetValue, IsActive);

IF NOT EXISTS (SELECT 1 FROM map.ValueLookup WHERE Domain = N'Napetost' AND SourceValue = N'~220-30' AND Language = N'ENOTNO')
  INSERT map.ValueLookup (Domain, SourceValue, Language, TargetValue, Note, IsActive)
  VALUES (N'Napetost', N'~220-30', N'ENOTNO', N'~220-230', N'291: tipkarska napaka (NW), poenotenje za splet', 1);

/* === 2. Pravilo poenotenja ============================================================================ */
/* Prva različica (vrstična funkcija) je bila za SQL Server preveč sestavljena (napaka 8632); skalarna s koraki
   se kliče enkrat na različno vrednost (izvoz, zajem in poenotenje gradijo preslikavo po različnih vrednostih). */
IF OBJECT_ID(N'pim.NormalizeAttributeValue', N'IF') IS NOT NULL
  DROP FUNCTION pim.NormalizeAttributeValue;
EXEC (N'CREATE OR ALTER FUNCTION pim.NormalizeAttributeValue (@AttributeCode nvarchar(400), @Value nvarchar(max))
RETURNS nvarchar(max)
AS
BEGIN
  /*
    291: ena pravilna oblika vrednosti atributa. Isto pravilo uporabljajo izvoz (out.GetExportRows), zajem
    (map.ApplyValueTransforms) in enkratno poenotenje podatkov. Spremeni samo obliko, ne pomena:
    presledki, znak na zacetku, decimalna vejica v stevilu, zapis napetosti in frekvence, nato slovar
    map.ValueLookup (Language = ENOTNO; ozja domena premaga *). NULL ostane NULL.
  */
  IF @Value IS NULL RETURN NULL;
  DECLARE @v nvarchar(max) = REPLACE(REPLACE(REPLACE(REPLACE(@Value, NCHAR(160), N'' ''), NCHAR(9), N'' ''), NCHAR(13), N'' ''), NCHAR(10), N'' '');
  WHILE CHARINDEX(N''  '', @v) > 0 SET @v = REPLACE(@v, N''  '', N'' '');
  SET @v = LTRIM(RTRIM(@v));
  IF @v = N'''' RETURN @v;

  /* »≥ 80« -> »≥80«, »> 0,5« -> »>0,5« */
  IF @v LIKE N''[≥≤<>~±] %'' SET @v = LEFT(@v, 1) + LTRIM(SUBSTRING(@v, 2, 4000));

  /* Decimalna vejica samo v cistem stevilu ali razponu (z znakom spredaj); »16A, 3,7kVA« ali »1,2,3« ostane. */
  DECLARE @Commas int = LEN(@v) - LEN(REPLACE(@v, N'','', N''''));
  IF @v LIKE N''%[0-9],[0-9]%'' AND @v NOT LIKE N''%.%'' AND @v NOT LIKE N''%[^0-9,≥≤<>~± -]%''
     AND (@Commas = 1 OR (@Commas = 2 AND @v LIKE N''%[0-9]-%''))
    SET @v = REPLACE(@v, N'','', N''.'');

  IF @AttributeCode = N''Napetost''
  BEGIN
    /* Oznaka toka spredaj (~ izmenicna, DC enosmerna), brez enote V (je v glavi), razpon z vezajem.
       Brez oznake: od 100 V naprej izmenicna (omrezje), pod 100 V enosmerna (LED, tracni sistemi). */
    DECLARE @Upper nvarchar(max) = UPPER(@v), @Dc bit = 0, @Ac bit = 0, @Core nvarchar(max), @First decimal(9,2);
    IF @Upper LIKE N''DC%'' OR @Upper LIKE N''%V DC'' OR @Upper LIKE N''%VDC'' SET @Dc = 1;
    IF @Upper LIKE N''~%'' OR @Upper LIKE N''AC%'' OR @Upper LIKE N''%V AC'' OR @Upper LIKE N''%VAC'' SET @Ac = 1;
    SET @Core = LTRIM(CASE WHEN @Upper LIKE N''DC%'' OR @Upper LIKE N''AC%'' THEN SUBSTRING(@Upper, 3, 4000)
                           WHEN @Upper LIKE N''~%'' THEN SUBSTRING(@Upper, 2, 4000) ELSE @Upper END);
    SET @Core = RTRIM(CASE WHEN @Core LIKE N''%V DC'' OR @Core LIKE N''%V AC'' THEN LEFT(@Core, LEN(@Core) - 4)
                           WHEN @Core LIKE N''%VDC'' OR @Core LIKE N''%VAC'' THEN LEFT(@Core, LEN(@Core) - 3)
                           WHEN @Core LIKE N''%V'' THEN LEFT(@Core, LEN(@Core) - 1) ELSE @Core END);
    SET @Core = REPLACE(REPLACE(@Core, N'' '', N''''), N''/'', N''-'');
    IF @Core <> N'''' AND @Core NOT LIKE N''%[^0-9.-]%'' AND @Core NOT LIKE N''-%'' AND @Core NOT LIKE N''%-''
       AND @Core NOT LIKE N''%-%-%''
    BEGIN
      SET @First = TRY_CONVERT(decimal(9,2), LEFT(@Core, CHARINDEX(N''-'', @Core + N''-'') - 1));
      IF @First IS NOT NULL
        SET @v = CASE WHEN @Dc = 1 OR (@Ac = 0 AND @First < 100) THEN N''DC '' + @Core ELSE N''~'' + @Core END;
    END;
  END
  ELSE IF @AttributeCode = N''Frekvenca''
  BEGIN
    /* Brez Hz, 50-60 -> 50/60. */
    DECLARE @Frequency nvarchar(max) = RTRIM(CASE WHEN @v LIKE N''%Hz'' THEN LEFT(@v, LEN(@v) - 2) ELSE @v END);
    SET @Frequency = REPLACE(REPLACE(@Frequency, N'' '', N''''), N''-'', N''/'');
    IF @Frequency <> N'''' AND @Frequency NOT LIKE N''%[^0-9./]%'' SET @v = @Frequency;
  END;

  DECLARE @Hit nvarchar(max) =
    (SELECT TOP (1) lookup.TargetValue FROM map.ValueLookup AS lookup
     WHERE lookup.Language = N''ENOTNO'' AND lookup.IsActive = 1
       AND lookup.SourceKey = LOWER(@v) AND lookup.Domain IN (@AttributeCode, N''*'')
     ORDER BY CASE WHEN lookup.Domain = N''*'' THEN 1 ELSE 0 END);
  RETURN COALESCE(@Hit, @v);
END;');

/* Samopreizkus pravila: če katera vrstica pade, se nič ne spremeni. */
DECLARE @Check TABLE (AttributeCode nvarchar(400), Input nvarchar(200), Expected nvarchar(200));
INSERT @Check VALUES
  (N'Napetost', N'~220-230', N'~220-230'), (N'Napetost', N'220-230', N'~220-230'), (N'Napetost', N'220/230', N'~220-230'),
  (N'Napetost', N'~220-230V', N'~220-230'), (N'Napetost', N'220-230V', N'~220-230'), (N'Napetost', N'~220-30', N'~220-230'),
  (N'Napetost', N'220-240', N'~220-240'), (N'Napetost', N'~250', N'~250'), (N'Napetost', N'DC 48', N'DC 48'),
  (N'Napetost', N'48', N'DC 48'), (N'Napetost', N'DC5', N'DC 5'), (N'Napetost', N'24', N'DC 24'), (N'Napetost', N'12V DC', N'DC 12'),
  (N'Napetost', N'AC 230V', N'~230'), (N'Napetost', N'100-240V', N'~100-240'),
  (N'Frekvenca', N'50/60', N'50/60'), (N'Frekvenca', N'50/60 Hz', N'50/60'), (N'Frekvenca', N'50-60Hz', N'50/60'), (N'Frekvenca', N'50', N'50'),
  (N'Indeks barvnega videza (CRI)', N'≥ 80', N'≥80'), (N'Faktor moči', N'>0,5', N'>0.5'), (N'Faktor moči', N'> 0.5', N'>0.5'),
  (N'Volumen paketa', N'1,08', N'1.08'), (N'Višina paketa I', N' 6,5 ', N'6.5'), (N'Max moč sijalke', N'16A, 3,7kVA', N'16A, 3,7kVA'),
  (N'Združljivo z', N'1 x  CAMELEON', N'1 x CAMELEON'), (N'Delovna temperatura', N'-20⁰C ~ +40⁰C', N'-20⁰C ~ +40⁰C'),
  (N'Kolekcija', N'MONO', N'MONO'), (N'Kolekcija', N'MONO  ', N'MONO'), (N'Kolekcija', N'  A   B  ', N'A B'),
  (N'Napetost', N'AC/DC 12', N'AC/DC 12'), (N'Napetost', N'~ 230 V', N'~230');
DECLARE @Failed nvarchar(400) = (SELECT TOP (1) CONCAT(c.AttributeCode, N': "', c.Input, N'" -> "', n.Value, N'" namesto "', c.Expected, N'"')
  FROM @Check c CROSS APPLY (SELECT Value = pim.NormalizeAttributeValue(c.AttributeCode, c.Input)) n
  WHERE ISNULL(n.Value, N'') COLLATE Latin1_General_BIN2 <> c.Expected COLLATE Latin1_General_BIN2);
IF @Failed IS NOT NULL
BEGIN
  DECLARE @FailedMessage nvarchar(600) = CONCAT(N'291: pravilo poenotenja se ne obnaša pričakovano — ', @Failed);
  THROW 52913, @FailedMessage, 1;
END;
IF pim.NormalizeAttributeValue(N'Napetost', NULL) IS NOT NULL
  THROW 52914, N'291: NULL mora ostati NULL.', 1;

/* Veljavne poti kategorij po spletišču: pot v jeziku spletišča iz imen prednikov (kot jo piše zajem, 109)
   in — za slovenska spletišča — še shranjena pot vozlišča (kot jo piše ročna uvrstitev). */
EXEC (N'CREATE OR ALTER VIEW canon.WebSiteCategoryPath
AS
/* 291: pot, ki jo sme izdelek imeti na spletišču. Pot izven tega nabora je ostanek (stara preslikava,
   premaknjena ali preimenovana kategorija) in ne gre v katalog.csv. */
SELECT site.WebSiteCode, site.CategoryTreeCode, site.LanguageCode, path.CategoryCode, path.CategoryPath
FROM canon.WebSite AS site
INNER JOIN canon.CategoryPathTranslated AS path
  ON path.CategoryTreeCode = site.CategoryTreeCode AND path.LanguageCode = site.LanguageCode
WHERE site.IsActive = 1
UNION
SELECT site.WebSiteCode, site.CategoryTreeCode, site.LanguageCode, category.CategoryCode, category.CategoryPath
FROM canon.WebSite AS site
INNER JOIN canon.Category AS category ON category.CategoryTreeCode = site.CategoryTreeCode AND category.IsActive = 1
WHERE site.IsActive = 1 AND site.LanguageCode = N''sl'';');

/* === 3. Dnevnik in enkratno poenotenje obstoječih vrednosti ========================================== */
IF OBJECT_ID(N'pim.AttributeValueNormalizationLog', N'U') IS NULL
  CREATE TABLE pim.AttributeValueNormalizationLog
  (
    AttributeValueNormalizationLogId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_AttributeValueNormalizationLog PRIMARY KEY,
    TableName nvarchar(60) NOT NULL,
    RowId bigint NOT NULL,
    OrganizationId int NULL,
    ItemID nvarchar(200) NULL,
    AttributeCode nvarchar(400) NOT NULL,
    LanguageCode nvarchar(20) NULL,
    OldValue nvarchar(max) NULL,
    NewValue nvarchar(max) NULL,
    ChangedUtc datetime2(3) NOT NULL CONSTRAINT DF_AttributeValueNormalizationLog_ChangedUtc DEFAULT SYSUTCDATETIME(),
    ChangedBy nvarchar(200) NOT NULL
  );

/* Preslikava po različnih vrednostih (canon + pim): funkcija se kliče enkrat na vrednost. BIN2, da »MONO« in »mono«
   ostaneta ločeni vrednosti. */
CREATE TABLE #Map
  (AttributeCode nvarchar(400) COLLATE DATABASE_DEFAULT NOT NULL,
   OldValue nvarchar(max) COLLATE Latin1_General_BIN2 NOT NULL,
   NewValue nvarchar(max) COLLATE DATABASE_DEFAULT NULL);
INSERT #Map (AttributeCode, OldValue, NewValue)
SELECT distinctValue.AttributeCode, distinctValue.OldValue, pim.NormalizeAttributeValue(distinctValue.AttributeCode, distinctValue.OldValue)
FROM (SELECT AttributeCode, Value COLLATE Latin1_General_BIN2 AS OldValue FROM canon.ProductAttribute WHERE Value IS NOT NULL
      UNION
      SELECT AttributeCode, Value COLLATE Latin1_General_BIN2 FROM pim.ProductAttribute WHERE Value IS NOT NULL) AS distinctValue;
DELETE FROM #Map WHERE ISNULL(NewValue, N'') COLLATE Latin1_General_BIN2 = OldValue;

BEGIN TRANSACTION;
  /* canon: sprožilec TR_ProductAttribute_FieldHistory zapiše prej/potem v pim.ProductFieldHistory. */
  EXEC sys.sp_set_session_context @key = N'ChangeSource', @value = N'POENOTENJE';
  EXEC sys.sp_set_session_context @key = N'ChangedBy', @value = N'migracija 291';
  EXEC sys.sp_set_session_context @key = N'ChangeNote', @value = N'291: poenotenje zapisa vrednosti atributov (napetost, frekvenca, decimalke, presledki)';

  DECLARE @CanonChanged TABLE (ProductAttributeId bigint PRIMARY KEY, OldValue nvarchar(max), NewValue nvarchar(max));
  UPDATE attribute SET Value = normal.NewValue
  OUTPUT inserted.ProductAttributeId, deleted.Value, inserted.Value INTO @CanonChanged
  FROM canon.ProductAttribute AS attribute
  INNER JOIN #Map AS normal ON normal.AttributeCode = attribute.AttributeCode AND normal.OldValue = attribute.Value COLLATE Latin1_General_BIN2;

  INSERT pim.AttributeValueNormalizationLog (TableName, RowId, OrganizationId, ItemID, AttributeCode, LanguageCode, OldValue, NewValue, ChangedBy)
  SELECT N'canon.ProductAttribute', changed.ProductAttributeId, product.OrganizationId, product.ItemID, attribute.AttributeCode,
         attribute.LanguageCode, changed.OldValue, changed.NewValue, N'migracija 291'
  FROM @CanonChanged changed
  INNER JOIN canon.ProductAttribute attribute ON attribute.ProductAttributeId = changed.ProductAttributeId
  INNER JOIN canon.Product product ON product.ProductId = attribute.ProductId;

  DECLARE @PimChanged TABLE (PimProductAttributeId bigint PRIMARY KEY, OldValue nvarchar(max), NewValue nvarchar(max));
  UPDATE attribute SET Value = normal.NewValue
  OUTPUT inserted.PimProductAttributeId, deleted.Value, inserted.Value INTO @PimChanged
  FROM pim.ProductAttribute AS attribute
  INNER JOIN #Map AS normal ON normal.AttributeCode = attribute.AttributeCode AND normal.OldValue = attribute.Value COLLATE Latin1_General_BIN2;

  INSERT pim.AttributeValueNormalizationLog (TableName, RowId, OrganizationId, ItemID, AttributeCode, LanguageCode, OldValue, NewValue, ChangedBy)
  SELECT N'pim.ProductAttribute', changed.PimProductAttributeId, product.OrganizationId, product.ItemID, attribute.AttributeCode,
         attribute.LanguageCode, changed.OldValue, changed.NewValue, N'migracija 291'
  FROM @PimChanged changed
  INNER JOIN pim.ProductAttribute attribute ON attribute.PimProductAttributeId = changed.PimProductAttributeId
  INNER JOIN pim.Product product ON product.PimProductId = attribute.PimProductId;

  EXEC sys.sp_set_session_context @key = N'ChangeSource', @value = NULL;
  EXEC sys.sp_set_session_context @key = N'ChangedBy', @value = NULL;
  EXEC sys.sp_set_session_context @key = N'ChangeNote', @value = NULL;
COMMIT TRANSACTION;

/* === 4. Zajem: map.ApplyValueTransforms poenoti vrednosti atributov vsakega teka ====================== */
DECLARE @Transforms nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'map.ApplyValueTransforms'));
IF @Transforms NOT LIKE N'%/* Poenotenje291 */%'
BEGIN
  DECLARE @ReturnText nvarchar(100) = N'IF NOT EXISTS (SELECT 1 FROM #Scope) RETURN;';
  DECLARE @DropText nvarchar(100) = N'DROP TABLE #Scope;';
  IF (DATALENGTH(@Transforms) - DATALENGTH(REPLACE(@Transforms, @ReturnText, N''))) / DATALENGTH(@ReturnText) <> 1
     OR (DATALENGTH(@Transforms) - DATALENGTH(REPLACE(@Transforms, @DropText, N''))) / DATALENGTH(@DropText) <> 1
     OR @Transforms NOT LIKE N'%DECLARE @RunInbox TABLE%'
    THROW 52915, N'291: map.ApplyValueTransforms ni v pričakovani obliki; nič ni spremenjeno.', 1;

  /* Poenotenje teče po vseh pretvorbah (ali takoj, če pretvorb ni). Izvirnik ostane v RawValue —
     094 (ReopenRunForMapping) ga ob ponovni obdelavi vrne in pravilo se uporabi znova. */
  DECLARE @NormalizeBlock nvarchar(max) = N'/* Poenotenje291 */
    DELETE FROM @Normal291;
    INSERT @Normal291 (AttributeCode, OldValue, NewValue)
    SELECT distinctValue.AttributeCode, distinctValue.OldValue, pim.NormalizeAttributeValue(distinctValue.AttributeCode, distinctValue.OldValue)
    FROM (SELECT DISTINCT SUBSTRING(value.TargetFieldCode, 18, 400) AS AttributeCode, value.Value COLLATE Latin1_General_BIN2 AS OldValue
          FROM map.ExtractedValue value INNER JOIN @RunInbox run ON run.InboxId = value.InboxId
          WHERE value.TargetFieldCode LIKE N''ProductAttribute.%'' AND value.Value IS NOT NULL) AS distinctValue;
    DELETE FROM @Normal291 WHERE ISNULL(NewValue, N'''') COLLATE Latin1_General_BIN2 = OldValue;
    UPDATE value SET RawValue = ISNULL(value.RawValue, value.Value), Value = normal.NewValue
    FROM map.ExtractedValue value
    INNER JOIN @RunInbox run ON run.InboxId = value.InboxId
    INNER JOIN @Normal291 normal ON normal.AttributeCode = SUBSTRING(value.TargetFieldCode, 18, 400)
      AND normal.OldValue = value.Value COLLATE Latin1_General_BIN2
    WHERE value.TargetFieldCode LIKE N''ProductAttribute.%'';
';
  SET @Transforms = REPLACE(@Transforms, @ReturnText,
    N'DECLARE @Normal291 TABLE (AttributeCode nvarchar(400) NOT NULL, OldValue nvarchar(max) COLLATE Latin1_General_BIN2 NOT NULL, NewValue nvarchar(max) NULL);
    IF NOT EXISTS (SELECT 1 FROM #Scope)
    BEGIN
    ' + @NormalizeBlock + N'
      RETURN;
    END;');
  SET @Transforms = REPLACE(@Transforms, @DropText, @NormalizeBlock + N'
  DROP TABLE #Scope;');
  SET @Transforms = N'ALTER ' + SUBSTRING(@Transforms, CHARINDEX(N'PROCEDURE', @Transforms), 2147483647);
  EXEC sys.sp_executesql @Transforms;
END;

/* === 5. Izvoz: vsi atributi, poenotene vrednosti, samo veljavne poti kategorij ======================== */
DECLARE @Export nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows'));
IF @Export NOT LIKE N'%/* VsiAtributi291 */%'
BEGIN
  DECLARE @Anchors TABLE (Anchor nvarchar(400), Replacement nvarchar(max));
  INSERT @Anchors VALUES
  /* a) nabor se izračuna samo, če kje obstaja EXCLUDED (drugače bi le porabil čas) */
  (N'INSERT #AttributeFilter (PimProductId, AttributeName, Level)',
   N'IF EXISTS (SELECT 1 FROM canon.CategoryAttributeSet WHERE Level = N''EXCLUDED'' AND IsActive = 1) /* VsiAtributi291 */
    INSERT #AttributeFilter (PimProductId, AttributeName, Level)'),
  /* b) ostane samo učinkovita izločitev: EXCLUDED, ki ga nobena druga kategorija izdelka ne vključi */
  (N'INSERT #Attribute (RowKey, AttributeCode, LanguageCode, Value, AttributeId)',
   N'DELETE filter291 FROM #AttributeFilter AS filter291
    WHERE filter291.Level <> N''EXCLUDED''
       OR EXISTS (SELECT 1 FROM #AttributeFilter AS keep291 WHERE keep291.PimProductId = filter291.PimProductId
                    AND keep291.AttributeName = filter291.AttributeName AND keep291.Level <> N''EXCLUDED'');

    /* 291: preslikava poenotenja po različnih vrednostih teh izdelkov (funkcija enkrat na vrednost). */
    CREATE TABLE #NormalMap291
      (AttributeCode nvarchar(400) COLLATE DATABASE_DEFAULT NOT NULL,
       OldValue nvarchar(max) COLLATE Latin1_General_BIN2 NOT NULL, NewValue nvarchar(max) COLLATE DATABASE_DEFAULT NULL);
    INSERT #NormalMap291 (AttributeCode, OldValue, NewValue)
    SELECT distinctValue.AttributeCode, distinctValue.OldValue, pim.NormalizeAttributeValue(distinctValue.AttributeCode, distinctValue.OldValue)
    FROM (SELECT DISTINCT attribute.AttributeCode, attribute.Value COLLATE Latin1_General_BIN2 AS OldValue
          FROM #Page AS page INNER JOIN pim.ProductAttribute AS attribute ON attribute.PimProductId = page.EntityId
          WHERE attribute.Value IS NOT NULL) AS distinctValue;
    DELETE FROM #NormalMap291 WHERE ISNULL(NewValue, N'''') COLLATE Latin1_General_BIN2 = OldValue;

    INSERT #Attribute (RowKey, AttributeCode, LanguageCode, Value, AttributeId)'),
  (N'WHERE filter.PimProductId = page.EntityId AND filter.Level <> N''EXCLUDED'')',
   N'WHERE filter.PimProductId = page.EntityId AND filter.Level = N''EXCLUDED'' AND filter.AttributeName = attribute.AttributeCode) /* 291: izpade samo izločen */'),
  /* c) poenotena vrednost */
  (N'attribute.LanguageCode, attribute.Value, attribute.PimProductAttributeId',
   N'attribute.LanguageCode, COALESCE(normal291.NewValue, attribute.Value), attribute.PimProductAttributeId'),
  (N'INNER JOIN pim.ProductAttribute AS attribute ON attribute.PimProductId = page.EntityId',
   N'INNER JOIN pim.ProductAttribute AS attribute ON attribute.PimProductId = page.EntityId
    LEFT JOIN #NormalMap291 AS normal291 ON normal291.AttributeCode = attribute.AttributeCode
      AND normal291.OldValue = attribute.Value COLLATE Latin1_General_BIN2'),
  /* d) samo poti, ki obstajajo v drevesu v jeziku spletišča */
  (N'CREATE TABLE #Category',
   N'CREATE TABLE #ValidPath291
      (WebSite nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL, CategoryPath nvarchar(2000) COLLATE DATABASE_DEFAULT NOT NULL);
    INSERT #ValidPath291 (WebSite, CategoryPath)
    SELECT DISTINCT WebSiteCode, CategoryPath FROM canon.WebSiteCategoryPath;

    CREATE TABLE #Category'),
  (N'INNER JOIN #Site AS site ON site.PimProductId = category.PimProductId AND site.WebSite = category.WebSite;',
   N'INNER JOIN #Site AS site ON site.PimProductId = category.PimProductId AND site.WebSite = category.WebSite
    WHERE EXISTS (SELECT 1 FROM #ValidPath291 AS valid291
                  WHERE valid291.WebSite = category.WebSite AND valid291.CategoryPath = category.CategoryPath) /* VeljavnaPot291 */;');

  DECLARE @MissingAnchor nvarchar(400) = (SELECT TOP (1) Anchor FROM @Anchors
    WHERE (DATALENGTH(@Export) - DATALENGTH(REPLACE(@Export, Anchor, N''))) / DATALENGTH(Anchor) <> 1);
  IF @MissingAnchor IS NOT NULL
  BEGIN
    DECLARE @AnchorMessage nvarchar(600) = CONCAT(N'291: out.GetExportRows nima natanko enega sidra »', @MissingAnchor, N'«; nič ni spremenjeno.');
    THROW 52916, @AnchorMessage, 1;
  END;

  DECLARE @Anchor nvarchar(400), @Replacement nvarchar(max);
  DECLARE anchors CURSOR LOCAL FAST_FORWARD FOR SELECT Anchor, Replacement FROM @Anchors;
  OPEN anchors;
  FETCH NEXT FROM anchors INTO @Anchor, @Replacement;
  WHILE @@FETCH_STATUS = 0
  BEGIN
    SET @Export = REPLACE(@Export, @Anchor, @Replacement);
    FETCH NEXT FROM anchors INTO @Anchor, @Replacement;
  END;
  CLOSE anchors; DEALLOCATE anchors;
  IF @Export NOT LIKE N'%/* VsiAtributi291 */%' OR @Export NOT LIKE N'%normal291.NewValue%' OR @Export NOT LIKE N'%/* VeljavnaPot291 */%'
     OR @Export NOT LIKE N'%/* 287 */%' OR @Export NOT LIKE N'%/* 288 */%'
    THROW 52917, N'291: zamenjave v out.GetExportRows niso vse uspele; nič ni spremenjeno.', 1;
  SET @Export = N'ALTER ' + SUBSTRING(@Export, CHARINDEX(N'PROCEDURE', @Export), 2147483647);
  EXEC sys.sp_executesql @Export;
END;

/* === 6. Kategorije: prevod, odvečne neveljavne poti, zajem in objava brez ostankov ==================== */
IF OBJECT_ID(N'canon.ProductCategory_pred291', N'U') IS NULL
  CREATE TABLE canon.ProductCategory_pred291
    (ProductCategoryId bigint NOT NULL PRIMARY KEY, ProductId bigint NOT NULL, WebSite nvarchar(100) NOT NULL,
     CategoryPath nvarchar(1000) NOT NULL, Reason nvarchar(60) NOT NULL, SavedUtc datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME());
IF OBJECT_ID(N'pim.ProductCategory_pred291', N'U') IS NULL
  CREATE TABLE pim.ProductCategory_pred291
    (PimProductCategoryId bigint NOT NULL PRIMARY KEY, PimProductId bigint NOT NULL, WebSite nvarchar(100) NOT NULL,
     CategoryPath nvarchar(1000) NOT NULL, Reason nvarchar(60) NOT NULL, SavedUtc datetime2(3) NOT NULL DEFAULT SYSUTCDATETIME());

/* 6a. Prevod EN »1-fazni 48V LVM«: bil je »1-circuit 48V   UT- LVM« (drug sistem, trije presledki). */
CREATE TABLE #Retranslate
  (CategoryTreeCode nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL, CategoryCode nvarchar(400) COLLATE DATABASE_DEFAULT NOT NULL,
   OldPath nvarchar(1000) COLLATE DATABASE_DEFAULT NOT NULL, NewPath nvarchar(1000) COLLATE DATABASE_DEFAULT NULL);
INSERT #Retranslate (CategoryTreeCode, CategoryCode, OldPath)
SELECT path.CategoryTreeCode, path.CategoryCode, path.CategoryPath
FROM canon.CategoryPathTranslated AS path
WHERE path.LanguageCode = N'en'
  AND EXISTS (SELECT 1 FROM canon.CategoryTranslation AS bad
              WHERE bad.CategoryTreeCode = path.CategoryTreeCode AND bad.LanguageCode = N'en'
                AND bad.CategoryCode = N'tracni_sistemi___1_fazni_48v_lvm' AND bad.CategoryName LIKE N'1-circuit 48V %UT- LVM'
                AND (path.CategoryCode = bad.CategoryCode OR path.CategoryCode LIKE bad.CategoryCode + N'[_][_][_]%'));

DECLARE @Tree nvarchar(100), @Code nvarchar(400);
DECLARE retranslate CURSOR LOCAL FAST_FORWARD FOR
  SELECT DISTINCT CategoryTreeCode FROM #Retranslate;
OPEN retranslate;
FETCH NEXT FROM retranslate INTO @Tree;
WHILE @@FETCH_STATUS = 0
BEGIN
  SET @Code = N'tracni_sistemi___1_fazni_48v_lvm';
  EXEC canon.SaveCategoryTranslations @CategoryTreeCode = @Tree, @CategoryCode = @Code OUTPUT,
    @TranslationsJson = N'[{"lang":"en","name":"1-circuit 48V LVM"}]', @Actor = N'migracija 291';
  FETCH NEXT FROM retranslate INTO @Tree;
END;
CLOSE retranslate; DEALLOCATE retranslate;

UPDATE retranslate SET NewPath = path.CategoryPath
FROM #Retranslate AS retranslate
INNER JOIN canon.CategoryPathTranslated AS path
  ON path.CategoryTreeCode = retranslate.CategoryTreeCode AND path.CategoryCode = retranslate.CategoryCode AND path.LanguageCode = N'en';

BEGIN TRANSACTION;
  /* Angleške poti izdelkov pod tem vozliščem: stara pot -> nova (kopija stare vrstice ostane). */
  INSERT canon.ProductCategory_pred291 (ProductCategoryId, ProductId, WebSite, CategoryPath, Reason)
  SELECT category.ProductCategoryId, category.ProductId, category.WebSite, category.CategoryPath, N'PREVOD_EN'
  FROM canon.ProductCategory category
  INNER JOIN canon.WebSite site ON site.WebSiteCode = category.WebSite AND site.LanguageCode = N'en'
  INNER JOIN #Retranslate retranslate ON retranslate.CategoryTreeCode = site.CategoryTreeCode AND retranslate.OldPath = category.CategoryPath
  WHERE retranslate.NewPath IS NOT NULL AND retranslate.NewPath <> retranslate.OldPath COLLATE Latin1_General_BIN2
    AND NOT EXISTS (SELECT 1 FROM canon.ProductCategory_pred291 saved WHERE saved.ProductCategoryId = category.ProductCategoryId);
  DELETE category FROM canon.ProductCategory category
  INNER JOIN canon.WebSite site ON site.WebSiteCode = category.WebSite AND site.LanguageCode = N'en'
  INNER JOIN #Retranslate retranslate ON retranslate.CategoryTreeCode = site.CategoryTreeCode AND retranslate.OldPath = category.CategoryPath
  WHERE retranslate.NewPath IS NOT NULL AND retranslate.NewPath <> retranslate.OldPath COLLATE Latin1_General_BIN2
    AND EXISTS (SELECT 1 FROM canon.ProductCategory other WHERE other.ProductId = category.ProductId
                  AND other.WebSite = category.WebSite AND other.CategoryPath = retranslate.NewPath);
  UPDATE category SET CategoryPath = retranslate.NewPath
  FROM canon.ProductCategory category
  INNER JOIN canon.WebSite site ON site.WebSiteCode = category.WebSite AND site.LanguageCode = N'en'
  INNER JOIN #Retranslate retranslate ON retranslate.CategoryTreeCode = site.CategoryTreeCode AND retranslate.OldPath = category.CategoryPath
  WHERE retranslate.NewPath IS NOT NULL AND retranslate.NewPath <> retranslate.OldPath COLLATE Latin1_General_BIN2;

  INSERT pim.ProductCategory_pred291 (PimProductCategoryId, PimProductId, WebSite, CategoryPath, Reason)
  SELECT category.PimProductCategoryId, category.PimProductId, category.WebSite, category.CategoryPath, N'PREVOD_EN'
  FROM pim.ProductCategory category
  INNER JOIN canon.WebSite site ON site.WebSiteCode = category.WebSite AND site.LanguageCode = N'en'
  INNER JOIN #Retranslate retranslate ON retranslate.CategoryTreeCode = site.CategoryTreeCode AND retranslate.OldPath = category.CategoryPath
  WHERE retranslate.NewPath IS NOT NULL AND retranslate.NewPath <> retranslate.OldPath COLLATE Latin1_General_BIN2
    AND NOT EXISTS (SELECT 1 FROM pim.ProductCategory_pred291 saved WHERE saved.PimProductCategoryId = category.PimProductCategoryId);
  DELETE category FROM pim.ProductCategory category
  INNER JOIN canon.WebSite site ON site.WebSiteCode = category.WebSite AND site.LanguageCode = N'en'
  INNER JOIN #Retranslate retranslate ON retranslate.CategoryTreeCode = site.CategoryTreeCode AND retranslate.OldPath = category.CategoryPath
  WHERE retranslate.NewPath IS NOT NULL AND retranslate.NewPath <> retranslate.OldPath COLLATE Latin1_General_BIN2
    AND EXISTS (SELECT 1 FROM pim.ProductCategory other WHERE other.PimProductId = category.PimProductId
                  AND other.WebSite = category.WebSite AND other.CategoryPath = retranslate.NewPath);
  UPDATE category SET CategoryPath = retranslate.NewPath
  FROM pim.ProductCategory category
  INNER JOIN canon.WebSite site ON site.WebSiteCode = category.WebSite AND site.LanguageCode = N'en'
  INNER JOIN #Retranslate retranslate ON retranslate.CategoryTreeCode = site.CategoryTreeCode AND retranslate.OldPath = category.CategoryPath
  WHERE retranslate.NewPath IS NOT NULL AND retranslate.NewPath <> retranslate.OldPath COLLATE Latin1_General_BIN2;

  UPDATE override SET CategoryPath = retranslate.NewPath
  FROM pim.ProductCategoryOverride override
  INNER JOIN canon.WebSite site ON site.WebSiteCode = override.WebSite AND site.LanguageCode = N'en'
  INNER JOIN #Retranslate retranslate ON retranslate.CategoryTreeCode = site.CategoryTreeCode AND retranslate.OldPath = override.CategoryPath
  WHERE retranslate.NewPath IS NOT NULL AND retranslate.NewPath <> retranslate.OldPath COLLATE Latin1_General_BIN2;
COMMIT TRANSACTION;

/* 6b. Odvečne neveljavne poti: pot ni v drevesu v jeziku spletišča, izdelek pa ima na istem spletišču
       veljavno. Ročna uvrstitev (pim.ProductCategoryOverride) ostane nedotaknjena. */
CREATE TABLE #ValidPath
  (WebSite nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL, CategoryPath nvarchar(2000) COLLATE DATABASE_DEFAULT NOT NULL);
INSERT #ValidPath (WebSite, CategoryPath)
SELECT DISTINCT WebSiteCode, CategoryPath FROM canon.WebSiteCategoryPath;

BEGIN TRANSACTION;
  INSERT canon.ProductCategory_pred291 (ProductCategoryId, ProductId, WebSite, CategoryPath, Reason)
  SELECT stale.ProductCategoryId, stale.ProductId, stale.WebSite, stale.CategoryPath, N'NI_V_DREVESU'
  FROM canon.ProductCategory stale
  INNER JOIN canon.WebSite site ON site.WebSiteCode = stale.WebSite AND site.IsActive = 1
  WHERE NOT EXISTS (SELECT 1 FROM #ValidPath valid WHERE valid.WebSite = stale.WebSite AND valid.CategoryPath = stale.CategoryPath)
    AND EXISTS (SELECT 1 FROM canon.ProductCategory good INNER JOIN #ValidPath valid ON valid.WebSite = good.WebSite AND valid.CategoryPath = good.CategoryPath
                WHERE good.ProductId = stale.ProductId AND good.WebSite = stale.WebSite)
    AND NOT EXISTS (SELECT 1 FROM pim.ProductCategoryOverride manual WHERE manual.ProductId = stale.ProductId
                      AND manual.WebSite = stale.WebSite AND manual.CategoryPath = stale.CategoryPath)
    AND NOT EXISTS (SELECT 1 FROM canon.ProductCategory_pred291 saved WHERE saved.ProductCategoryId = stale.ProductCategoryId);
  DELETE stale FROM canon.ProductCategory stale
  INNER JOIN canon.ProductCategory_pred291 saved ON saved.ProductCategoryId = stale.ProductCategoryId AND saved.Reason = N'NI_V_DREVESU';

  INSERT pim.ProductCategory_pred291 (PimProductCategoryId, PimProductId, WebSite, CategoryPath, Reason)
  SELECT stale.PimProductCategoryId, stale.PimProductId, stale.WebSite, stale.CategoryPath, N'NI_V_DREVESU'
  FROM pim.ProductCategory stale
  INNER JOIN canon.WebSite site ON site.WebSiteCode = stale.WebSite AND site.IsActive = 1
  INNER JOIN pim.Product product ON product.PimProductId = stale.PimProductId
  LEFT JOIN canon.Product canonProduct ON canonProduct.OrganizationId = product.OrganizationId AND canonProduct.ItemID = product.ItemID
  WHERE NOT EXISTS (SELECT 1 FROM #ValidPath valid WHERE valid.WebSite = stale.WebSite AND valid.CategoryPath = stale.CategoryPath)
    AND EXISTS (SELECT 1 FROM pim.ProductCategory good INNER JOIN #ValidPath valid ON valid.WebSite = good.WebSite AND valid.CategoryPath = good.CategoryPath
                WHERE good.PimProductId = stale.PimProductId AND good.WebSite = stale.WebSite)
    AND NOT EXISTS (SELECT 1 FROM pim.ProductCategoryOverride manual WHERE manual.ProductId = canonProduct.ProductId
                      AND manual.WebSite = stale.WebSite AND manual.CategoryPath = stale.CategoryPath)
    AND NOT EXISTS (SELECT 1 FROM pim.ProductCategory_pred291 saved WHERE saved.PimProductCategoryId = stale.PimProductCategoryId);
  DELETE stale FROM pim.ProductCategory stale
  INNER JOIN pim.ProductCategory_pred291 saved ON saved.PimProductCategoryId = stale.PimProductCategoryId AND saved.Reason = N'NI_V_DREVESU';
COMMIT TRANSACTION;

/* 6c. Zajem (map.ResolveProductCategories): po zapisu odstrani enake ostanke za izdelke tega teka. */
DECLARE @Resolve nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'map.ResolveProductCategories'));
IF @Resolve NOT LIKE N'%/* Pospravi291:%'
BEGIN
  DECLARE @ResolveAnchor nvarchar(200) = N'VALUES (source.ProductId, source.WebSiteCode, source.CategoryPath);';
  IF (DATALENGTH(@Resolve) - DATALENGTH(REPLACE(@Resolve, @ResolveAnchor, N''))) / DATALENGTH(@ResolveAnchor) <> 1
     OR @Resolve NOT LIKE N'%#Kategorija%'
    THROW 52918, N'291: map.ResolveProductCategories ni v pričakovani obliki; nič ni spremenjeno.', 1;
  SET @Resolve = REPLACE(@Resolve, @ResolveAnchor, @ResolveAnchor + N'

  /* Pospravi291: pot, ki je ni (vec) v drevesu, odstranimo, ce ima izdelek na istem spletiscu veljavno
     (npr. po premiku ali preimenovanju kategorije). Rocna uvrstitev ostane. */
  CREATE TABLE #ValidPathResolve291 (WebSite nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
    CategoryPath nvarchar(2000) COLLATE DATABASE_DEFAULT NOT NULL);
  INSERT #ValidPathResolve291 (WebSite, CategoryPath)
  SELECT DISTINCT WebSiteCode, CategoryPath FROM canon.WebSiteCategoryPath;
  DELETE stale FROM canon.ProductCategory stale
  WHERE stale.ProductId IN (SELECT kategorija.ProductId FROM #Kategorija kategorija)
    AND EXISTS (SELECT 1 FROM canon.WebSite spletisce WHERE spletisce.WebSiteCode = stale.WebSite AND spletisce.IsActive = 1)
    AND NOT EXISTS (SELECT 1 FROM #ValidPathResolve291 valid WHERE valid.WebSite = stale.WebSite AND valid.CategoryPath = stale.CategoryPath)
    AND EXISTS (SELECT 1 FROM canon.ProductCategory good INNER JOIN #ValidPathResolve291 valid ON valid.WebSite = good.WebSite AND valid.CategoryPath = good.CategoryPath
                WHERE good.ProductId = stale.ProductId AND good.WebSite = stale.WebSite)
    AND NOT EXISTS (SELECT 1 FROM pim.ProductCategoryOverride prekrivka WHERE prekrivka.ProductId = stale.ProductId
                      AND prekrivka.WebSite = stale.WebSite AND prekrivka.CategoryPath = stale.CategoryPath);
  DROP TABLE #ValidPathResolve291;');
  SET @Resolve = N'ALTER ' + SUBSTRING(@Resolve, CHARINDEX(N'PROCEDURE', @Resolve), 2147483647);
  EXEC sys.sp_executesql @Resolve;
END;

/* 6d. Objava (val.Promote): pim sledi canon — ostanek, ki ga v canon ni več, gre tudi iz pim. */
DECLARE @Promote nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'val.Promote'));
IF @Promote NOT LIKE N'%/* Pospravi291:%'
BEGIN
  DECLARE @PromoteAnchor nvarchar(200) = N'VALUES (source.PimProductId, source.WebSite, source.CategoryPath);';
  IF (DATALENGTH(@Promote) - DATALENGTH(REPLACE(@Promote, @PromoteAnchor, N''))) / DATALENGTH(@PromoteAnchor) <> 1
     OR @Promote NOT LIKE N'%DECLARE @Objavljeni TABLE(PimProductId bigint PRIMARY KEY, ProductId bigint);%'
    THROW 52919, N'291: val.Promote ni v pričakovani obliki; nič ni spremenjeno.', 1;
  SET @Promote = REPLACE(@Promote, @PromoteAnchor, @PromoteAnchor + N'

    /* Pospravi291: pot, ki je ni v drevesu in je ni vec v canon, izdelek pa ima na istem spletiscu
       veljavno, ne ostane v pim (MERGE zgoraj samo dodaja). */
    CREATE TABLE #ValidPathPromote291 (WebSite nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
      CategoryPath nvarchar(2000) COLLATE DATABASE_DEFAULT NOT NULL);
    INSERT #ValidPathPromote291 (WebSite, CategoryPath)
    SELECT DISTINCT WebSiteCode, CategoryPath FROM canon.WebSiteCategoryPath;
    DELETE stale FROM pim.ProductCategory stale
    INNER JOIN @Objavljeni objavljen ON objavljen.PimProductId = stale.PimProductId
    WHERE EXISTS (SELECT 1 FROM canon.WebSite spletisce WHERE spletisce.WebSiteCode = stale.WebSite AND spletisce.IsActive = 1)
      AND NOT EXISTS (SELECT 1 FROM canon.ProductCategory c WHERE c.ProductId = objavljen.ProductId
                        AND c.WebSite = stale.WebSite AND c.CategoryPath = stale.CategoryPath)
      AND NOT EXISTS (SELECT 1 FROM #ValidPathPromote291 valid WHERE valid.WebSite = stale.WebSite AND valid.CategoryPath = stale.CategoryPath)
      AND EXISTS (SELECT 1 FROM pim.ProductCategory good
                  INNER JOIN #ValidPathPromote291 valid ON valid.WebSite = good.WebSite AND valid.CategoryPath = good.CategoryPath
                  WHERE good.PimProductId = stale.PimProductId AND good.WebSite = stale.WebSite);
    DROP TABLE #ValidPathPromote291;');
  SET @Promote = N'ALTER ' + SUBSTRING(@Promote, CHARINDEX(N'PROCEDURE', @Promote), 2147483647);
  EXEC sys.sp_executesql @Promote;
END;

/* === dokaz ============================================================================================ */
IF OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows')) NOT LIKE N'%/* VsiAtributi291 */%'
   OR OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows')) NOT LIKE N'%/* VeljavnaPot291 */%'
   OR OBJECT_DEFINITION(OBJECT_ID(N'map.ApplyValueTransforms')) NOT LIKE N'%/* Poenotenje291 */%'
   OR OBJECT_DEFINITION(OBJECT_ID(N'map.ResolveProductCategories')) NOT LIKE N'%/* Pospravi291:%'
   OR OBJECT_DEFINITION(OBJECT_ID(N'val.Promote')) NOT LIKE N'%/* Pospravi291:%'
  THROW 52920, N'291: procedure niso vse posodobljene.', 1;
IF EXISTS (SELECT 1 FROM canon.CategoryTranslation WHERE LanguageCode = N'en' AND CategoryName LIKE N'%  %')
  THROW 52921, N'291: prevod kategorije ima še dvojni presledek.', 1;
