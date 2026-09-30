/*
  314 — Vklop lepega zapisa vrednosti atributov (zajem + katalog.csv + obstoječi podatki) — naloga #49.

  Lastnik 2026-09-29 na vprašanje »Ali vklopimo lepši zapis vrednosti atributov za vse naenkrat (nove uvoze,
  spletni katalog in obstoječe vrednosti, z zgodovino in možnostjo povratka)?« → »Da«. 2026-09-30: nič v SAOP,
  cene se ne spreminjajo, katalog.csv samo SL in EN (ta migracija jezikov in cen ne spreminja).

  Meritev na razvojni bazi PIM (DESKTOP-TONVQHJ\MSSQLSERVER3), 2026-09-30, pred 314:
    - 21.191 različnih parov (atribut, vrednost) v canon + pim; predlog 307 spremeni 272 parov v
      pim.ProductAttribute (5.693 vrstic) in 2.327 parov v canon.ProductAttribute (27.806 vrstic);
    - 7 vrednosti predloga 307 NI bilo stabilnih (drugi klic je spet nekaj spremenil), npr.
      »Li-Ion,Battery 18650 3.7V,6600mAh« → »…, 6600mAh« → »…, 6600 mAh«: presledek za vejico (korak 3)
      je tekel ŠELE po presledku pred enoto (korak 2). 314 obrne vrstni red (vejica, nato enota);
    - atribut »Garancija« je polje, ki ga PIM sme pisati v SAOP (out.SaopXmlField ProductAttribute.Garancija).
      Lastnik: »nič SAOP« → polja, ki gredo v SAOP, lep zapis preskoči (ostane samo pravilo 291);
    - izjema iz slovarja ENOTNO (/pravila/slovar) je prej veljala samo, če je lep zapis ni spremenil naprej
      (»5000k« → slovar »5000K« → korak 2 »5000 K«). Zdaj vrednost, ki je cilj slovarja ENOTNO, ostane.

  Kaj naredi 314 (vse v eni transakciji; če katerakoli kontrola pade, se nič ne spremeni):
    1. pim.PolishAttributeValue: nov vrstni red korakov (vejica pred enoto), preskok polj za SAOP in ciljev
       slovarja ENOTNO. Samopreizkus: vsi primeri iz 307 + nestabilni primeri + stabilnost (dvakrat = enkrat).
    2. pim.AttributeValueNormalizationLog dobi indeks po ChangedBy (povratek po migraciji je hiter).
    3. Enkratno poenotenje obstoječih vrednosti v canon.ProductAttribute (sprožilec zapiše prej/potem v
       pim.ProductFieldHistory, vir POENOTENJE) in pim.ProductAttribute; vsaka sprememba gre v dnevnik
       pim.AttributeValueNormalizationLog z ChangedBy = »migracija 314« (organizacija, šifra, prej, potem, kdaj).
       Pred zapisom kontrola: vsaka nova vrednost je stabilna (Polish(nova) = nova).
    4. Zajem: map.ApplyValueTransforms (blok Poenotenje291, oba klica) in izvoz: out.GetExportRows (blok
       #NormalMap291) kličeta pim.PolishAttributeValue namesto pim.NormalizeAttributeValue. Polish najprej
       pokliče Normalize, zato pravilo 291 (napetost, frekvenca, decimalke, presledki) velja naprej.
       Klic ostane po RAZLIČNIH vrednostih strani/teka, ne po vrstici izdelka.
    5. Nova procedura pim.RevertAttributeValueNormalization (@ChangedBy, @Actor, @DryRun): vrne OldValue
       iz dnevnika za izbrano poenotenje (npr. »migracija 314«), a samo, kjer je vrednost še enaka NewValue
       (ročno urejanje po poenotenju ostane). Povratek sam zapiše dnevnik (»povratek migracija 314 (kdo)«)
       in zgodovino canon (vir POVRAT_POENOTENJA). Opomba: povratek podatkov ne izklopi pravila v zajemu in
       izvozu — katalog.csv bo vrednosti še vedno lepo zapisal; za popoln izklop je potrebna nova migracija.

  Nič ne gre v SAOP: poenotenje ne kliče out.EnqueueSaopItemChange in ne piše v out.*; polja za SAOP preskoči.
  Objekti: pim.PolishAttributeValue (ALTER), pim.RevertAttributeValueNormalization (nova),
  IX_AttributeValueNormalizationLog_ChangedBy (nov), map.ApplyValueTransforms, out.GetExportRows (REPLACE na živi
  definiciji); podatki canon/pim.ProductAttribute (+ dnevnik, + pim.ProductFieldHistory). Ročni korak: ne.
  Migrator ne pozna GO.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;

IF UNICODE(N'č') <> 269
  THROW 53140, N'314: datoteka ni prebrana kot UTF-8 (sqlcmd -f 65001 ali Invoke-PendingMigrations.ps1).', 1;
IF OBJECT_ID(N'pim.PolishAttributeValue', N'FN') IS NULL OR OBJECT_ID(N'pim.NormalizeAttributeValue', N'FN') IS NULL
   OR OBJECT_ID(N'pim.AttributeValueNormalizationLog', N'U') IS NULL
   OR OBJECT_ID(N'map.ApplyValueTransforms', N'P') IS NULL OR OBJECT_ID(N'out.GetExportRows', N'P') IS NULL
   OR OBJECT_ID(N'out.SaopXmlField', N'U') IS NULL
  THROW 53141, N'314 potrebuje 291 (NormalizeAttributeValue, dnevnik) in 307 (PolishAttributeValue).', 1;

/* Sidra v živih definicijah (291, 292 in 293 so zadnje spremembe izvoza). Klic mora biti natanko tolikokrat, kot ga je
   vstavila 291: 2x v zajemu (prazen in poln tek), 1x v izvozu. Ob neujemanju se nič ne spremeni. */
DECLARE @CallOld nvarchar(200) = N'pim.NormalizeAttributeValue(distinctValue.AttributeCode, distinctValue.OldValue)';
DECLARE @CallNew nvarchar(200) = N'pim.PolishAttributeValue(distinctValue.AttributeCode, distinctValue.OldValue) /* Lep314 */';
DECLARE @Transforms nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'map.ApplyValueTransforms'));
DECLARE @Export nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows'));
DECLARE @TransformsDone bit = CASE WHEN @Transforms LIKE N'%/* Lep314 */%' THEN 1 ELSE 0 END;
DECLARE @ExportDone bit = CASE WHEN @Export LIKE N'%/* Lep314 */%' THEN 1 ELSE 0 END;
IF @TransformsDone = 0 AND (@Transforms NOT LIKE N'%/* Poenotenje291 */%'
   OR (DATALENGTH(@Transforms) - DATALENGTH(REPLACE(@Transforms, @CallOld, N''))) / DATALENGTH(@CallOld) <> 2)
  THROW 53142, N'314: map.ApplyValueTransforms nima natanko dveh klicev pravila 291 (blok Poenotenje291); nič ni spremenjeno.', 1;
IF @ExportDone = 0 AND (@Export NOT LIKE N'%#NormalMap291%' OR @Export NOT LIKE N'%/* VsiAtributi291 */%'
   OR @Export NOT LIKE N'%/* 292 */%' OR @Export NOT LIKE N'%Stolpci293%'
   OR (DATALENGTH(@Export) - DATALENGTH(REPLACE(@Export, @CallOld, N''))) / DATALENGTH(@CallOld) <> 1)
  THROW 53143, N'314: out.GetExportRows nima natanko enega klica pravila 291 (blok #NormalMap291, oznake 291/292/293); nič ni spremenjeno.', 1;

BEGIN TRAN;

/* === 1. Pravilo lepega zapisa: vrstni red, SAOP polja, izjeme slovarja ================================= */
EXEC (N'
ALTER FUNCTION pim.PolishAttributeValue (@AttributeCode nvarchar(400), @Value nvarchar(max))
RETURNS nvarchar(max)
AS
BEGIN
  /*
    307 + 314: lep zapis vrednosti atributa. VKLOPLJENO s 314 (lastnik 2026-09-29): klicejo ga zajem
    (map.ApplyValueTransforms), izvoz katalog.csv (out.GetExportRows) in predogled na
    /nastavitve/atributi/ciscenje. Najprej obstojece pravilo pim.NormalizeAttributeValue (291), nato:
      1. razpon brez presledkov okoli vezaja med stevilkama: »30 - 50« -> »30-50«;
      2. presledek za vejico v seznamu: »3CCT,IP65« -> »3CCT, IP65«; decimalna »1,5« ostane;
      3. presledek med stevilom in enoto z znanega seznama: »50m« -> »50 m«, »do 30m« -> »do 30 m«,
         »10W only LED« -> »10 W only LED«; »IP44«, »E27«, »GU10«, »3CCT« ostanejo;
         (314: vejica PRED enoto, sicer »3.7V,6600mAh« ni bil stabilen)
      4. velika zacetnica samo pri cistem besedilu brez stevk, ko je prva beseda vsa z malimi crkami in
         dolga vsaj 3 znake: »bela« -> »Bela«; »LED«, »mm«, »iPhone«, »kWh« ostanejo;
      5. se enkrat slovar ENOTNO (izjeme, ki jih vodi uporabnik na /pravila/slovar).
    Ostanejo, kot jih vrne 291: Napetost, Frekvenca, polja s kodo namesto imena (SEKUNDARNAMERSKAENOTA),
    povezave, e-naslovi, polja, ki jih PIM pise v SAOP (out.SaopXmlField, npr. Garancija; lastnik: nic SAOP),
    in vrednost, ki je cilj slovarja ENOTNO (izjema uporabnika velja, kot jo je zapisal). NULL ostane NULL.
  */
  IF @Value IS NULL RETURN NULL;
  DECLARE @v nvarchar(max) = pim.NormalizeAttributeValue(@AttributeCode, @Value);
  IF @v = N'''' OR @AttributeCode IN (N''Napetost'', N''Frekvenca'')
     OR @v LIKE N''%://%'' OR @v LIKE N''%www.%'' OR @v LIKE N''%@%''
     OR (@AttributeCode NOT LIKE N''% %'' AND @AttributeCode COLLATE Latin1_General_CS_AS = UPPER(@AttributeCode) COLLATE Latin1_General_CS_AS)
    RETURN @v;
  IF EXISTS (SELECT 1 FROM out.SaopXmlField AS saop
             WHERE saop.FieldKey = N''ProductAttribute.'' + @AttributeCode AND saop.IsEnabled = 1)
    RETURN @v;
  IF LEN(@v) <= 800 AND EXISTS (SELECT 1 FROM map.ValueLookup AS lookup
             WHERE lookup.Language = N''ENOTNO'' AND lookup.IsActive = 1 AND lookup.Domain IN (@AttributeCode, N''*'')
               AND lookup.TargetValue COLLATE Latin1_General_BIN2 = CAST(@v AS nvarchar(800)) COLLATE Latin1_General_BIN2)
    RETURN @v;

  /* 1. »30 - 50« -> »30-50« */
  DECLARE @p int = PATINDEX(N''%[0-9] - [0-9]%'', @v COLLATE Latin1_General_BIN);
  WHILE @p > 0
  BEGIN
    SET @v = STUFF(@v, @p + 1, 3, N''-'');
    SET @p = PATINDEX(N''%[0-9] - [0-9]%'', @v COLLATE Latin1_General_BIN);
  END;

  /* 2. presledek za vejico, razen med stevkama (decimalna vejica) */
  DECLARE @i int = 1, @j int, @k int, @Len int = LEN(@v), @Token nvarchar(20), @Before nchar(1), @After nchar(1);
  WHILE @i < @Len
  BEGIN
    IF SUBSTRING(@v, @i, 1) = N'','' AND SUBSTRING(@v, @i + 1, 1) <> N'' ''
       AND NOT (@i > 1 AND SUBSTRING(@v, @i - 1, 1) LIKE N''[0-9]'' AND SUBSTRING(@v, @i + 1, 1) LIKE N''[0-9]'')
    BEGIN
      SET @v = STUFF(@v, @i + 1, 0, N'' '');
      SET @Len = @Len + 1;
    END;
    SET @i = @i + 1;
  END;

  /* 3. presledek med stevilom in enoto */
  SET @i = 1;
  WHILE @i < @Len
  BEGIN
    IF SUBSTRING(@v, @i, 1) LIKE N''[0-9]'' AND SUBSTRING(@v, @i + 1, 1) COLLATE Latin1_General_BIN LIKE N''[A-Za-z]''
    BEGIN
      /* zacetek stevila: pred njim ne sme biti crke (IP44, GU10, E27, T25) */
      SET @k = @i;
      WHILE @k > 1 AND SUBSTRING(@v, @k - 1, 1) LIKE N''[0-9.,]'' SET @k = @k - 1;
      SET @Before = CASE WHEN @k > 1 THEN SUBSTRING(@v, @k - 1, 1) END;
      /* »2x5W«, »1x10W«: mnozenje pred stevilom ni crka oznake */
      IF @Before IN (N''x'', N''X'') AND @k > 2 AND SUBSTRING(@v, @k - 2, 1) LIKE N''[0-9]'' SET @Before = NULL;
      SET @j = @i + 1;
      WHILE @j <= @Len AND SUBSTRING(@v, @j, 1) COLLATE Latin1_General_BIN LIKE N''[A-Za-z]'' SET @j = @j + 1;
      SET @Token = CASE WHEN @j - @i - 1 <= 20 THEN SUBSTRING(@v, @i + 1, @j - @i - 1) END;
      SET @After = CASE WHEN @j <= @Len THEN SUBSTRING(@v, @j, 1) END;
      IF (@Before IS NULL OR @Before COLLATE Latin1_General_BIN NOT LIKE N''[A-Za-z]'')
         AND (@After IS NULL OR @After COLLATE Latin1_General_BIN NOT LIKE N''[A-Za-z0-9]'')
         AND @Token COLLATE Latin1_General_BIN IN (N''mm'', N''cm'', N''m'', N''km'', N''g'', N''kg'', N''W'', N''kW'', N''V'', N''A'', N''mA'',
           N''mAh'', N''Wh'', N''kWh'', N''K'', N''lm'', N''lx'', N''h'', N''Hz'', N''kHz'', N''VA'', N''kVA'', N''cd'')
      BEGIN
        SET @v = STUFF(@v, @i + 1, 0, N'' '');
        SET @Len = @Len + 1;
        SET @i = @j + 1;
      END
      ELSE SET @i = @j;
    END
    ELSE SET @i = @i + 1;
  END;

  /* 4. velika zacetnica pri cistem besedilu */
  DECLARE @FirstWord nvarchar(400) = LEFT(@v, PATINDEX(N''%[ ,/;(-]%'', @v + N'' '') - 1);
  IF @v NOT LIKE N''%[0-9]%'' AND LEN(@FirstWord) >= 3
     AND @FirstWord COLLATE Latin1_General_CS_AS = LOWER(@FirstWord) COLLATE Latin1_General_CS_AS
     AND LEFT(@v, 1) COLLATE Latin1_General_CS_AS <> UPPER(LEFT(@v, 1)) COLLATE Latin1_General_CS_AS
    SET @v = UPPER(LEFT(@v, 1)) + SUBSTRING(@v, 2, 4000000);

  /* 5. izjeme iz slovarja ENOTNO */
  DECLARE @Hit nvarchar(max) =
    (SELECT TOP (1) lookup.TargetValue FROM map.ValueLookup AS lookup
     WHERE lookup.Language = N''ENOTNO'' AND lookup.IsActive = 1
       AND lookup.SourceKey = LOWER(@v) AND lookup.Domain IN (@AttributeCode, N''*'')
     ORDER BY CASE WHEN lookup.Domain = N''*'' THEN 1 ELSE 0 END);
  RETURN COALESCE(@Hit, @v);
END
');

/* Dokaz pravila: primeri iz 307, nestabilni primeri s 30. 9. in SAOP polje. */
DECLARE @Check TABLE (AttributeCode nvarchar(400), Input nvarchar(400), Expected nvarchar(400));
INSERT @Check VALUES
  (N'Dolžina kabla', N'do 30m', N'do 30 m'),
  (N'Dolžina kabla', N'do 30 m', N'do 30 m'),
  (N'Dolžina kabla', N'50m', N'50 m'),
  (N'Dolžina kabla', N'30 - 50m', N'30-50 m'),
  (N'IP stopnja zaščite', N'IP44', N'IP44'),
  (N'Grlo', N'GU10', N'GU10'),
  (N'Enota', N'mm', N'mm'),
  (N'Vrsta svetlobnega vira', N'LED', N'LED'),
  (N'Barva svetlobe', N'toplo bela', N'Toplo bela'),
  (N'Model', N'iPhone', N'iPhone'),
  (N'SEKUNDARNAMERSKAENOTA', N'kom', N'kom'),
  (N'Napetost', N'~220-30', N'~220-230'),
  (N'CRI', N'≥ 80', N'≥80'),
  (N'Max moč sijalke', N'1x10W only LED', N'1x10 W only LED'),
  (N'Max moč sijalke', N'16A, 3.7kVA', N'16 A, 3.7 kVA'),
  (N'Max moč sijalke', N'10W', N'10 W'),
  (N'Ikone', N'3CCT,IP65', N'3CCT, IP65'),
  (N'Ikone', N'TOUCH,DIMMABLE,5000K', N'TOUCH, DIMMABLE, 5000 K'),
  (N'Baterija', N'Li-Ion,Battery 18650 3.7V,6600mAh', N'Li-Ion, Battery 18650 3.7 V, 6600 mAh'),
  (N'Združljivo z', N'11525 BULB LED, E14, T25, 4W,3000K', N'11525 BULB LED, E14, T25, 4 W, 3000 K'),
  (N'Garancija', N'OSRAM GU10,DIMM, 8.3W,3.000K,C', N'OSRAM GU10,DIMM, 8.3W,3.000K,C'),
  (N'Širina', N'1,5', N'1.5'),
  (N'Širina', N'11.9x11.9', N'11.9x11.9'),
  (N'Video', N'https://www.youtube.com/watch?v=a6vKYaqyMQA', N'https://www.youtube.com/watch?v=a6vKYaqyMQA');
DECLARE @FailedMessage nvarchar(2000) =
  (SELECT TOP (1) N'314: »' + c.Input + N'« (' + c.AttributeCode + N') da »' + ISNULL(r.Value, N'NULL') + N'«, pričakovano »' + c.Expected + N'«.'
   FROM @Check c CROSS APPLY (SELECT Value = pim.PolishAttributeValue(c.AttributeCode, c.Input)) r
   WHERE r.Value IS NULL OR r.Value COLLATE Latin1_General_BIN2 <> c.Expected COLLATE Latin1_General_BIN2);
IF @FailedMessage IS NOT NULL
  THROW 53144, @FailedMessage, 1;
SET @FailedMessage =
  (SELECT TOP (1) N'314: pravilo ni stabilno za »' + c.Expected + N'« (' + c.AttributeCode + N').'
   FROM @Check c
   WHERE pim.PolishAttributeValue(c.AttributeCode, c.Expected) COLLATE Latin1_General_BIN2 <> c.Expected COLLATE Latin1_General_BIN2);
IF @FailedMessage IS NOT NULL
  THROW 53145, @FailedMessage, 1;
IF pim.PolishAttributeValue(N'Barva', NULL) IS NOT NULL
  THROW 53146, N'314: NULL mora ostati NULL.', 1;

/* === 2. Dnevnik: iskanje po poenotenju (povratek) ====================================================== */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'pim.AttributeValueNormalizationLog')
               AND name = N'IX_AttributeValueNormalizationLog_ChangedBy')
  CREATE INDEX IX_AttributeValueNormalizationLog_ChangedBy
    ON pim.AttributeValueNormalizationLog (ChangedBy, TableName, RowId) INCLUDE (AttributeValueNormalizationLogId);

/* === 3. Enkratno poenotenje obstoječih vrednosti (po različnih vrednostih) ============================= */
CREATE TABLE #Map
  (AttributeCode nvarchar(400) COLLATE DATABASE_DEFAULT NOT NULL,
   OldValue nvarchar(max) COLLATE Latin1_General_BIN2 NOT NULL,
   NewValue nvarchar(max) COLLATE DATABASE_DEFAULT NULL);
INSERT #Map (AttributeCode, OldValue, NewValue)
SELECT distinctValue.AttributeCode, distinctValue.OldValue, pim.PolishAttributeValue(distinctValue.AttributeCode, distinctValue.OldValue)
FROM (SELECT AttributeCode, Value COLLATE Latin1_General_BIN2 AS OldValue FROM canon.ProductAttribute WHERE Value IS NOT NULL
      UNION
      SELECT AttributeCode, Value COLLATE Latin1_General_BIN2 FROM pim.ProductAttribute WHERE Value IS NOT NULL) AS distinctValue;
DELETE FROM #Map WHERE ISNULL(NewValue, N'') COLLATE Latin1_General_BIN2 = OldValue;

/* Kontrola pred zapisom: vsaka nova vrednost mora biti stabilna, sicer bi naslednji zajem ali izvoz spet
   spreminjal isto vrednost (in spletni filter bi imel dva zapisa). */
SET @FailedMessage =
  (SELECT TOP (1) N'314: nova vrednost ni stabilna: »' + CAST(m.OldValue AS nvarchar(300)) + N'« → »'
     + CAST(m.NewValue AS nvarchar(300)) + N'« (' + m.AttributeCode + N'); nič ni spremenjeno.'
   FROM #Map m
   WHERE m.NewValue IS NULL
      OR pim.PolishAttributeValue(m.AttributeCode, m.NewValue) COLLATE Latin1_General_BIN2 <> m.NewValue COLLATE Latin1_General_BIN2);
IF @FailedMessage IS NOT NULL
  THROW 53147, @FailedMessage, 1;

EXEC sys.sp_set_session_context @key = N'ChangeSource', @value = N'POENOTENJE';
EXEC sys.sp_set_session_context @key = N'ChangedBy', @value = N'migracija 314';
EXEC sys.sp_set_session_context @key = N'ChangeNote', @value = N'314: lep zapis vrednosti atributov (enote, vejice, velika začetnica); povratek: pim.RevertAttributeValueNormalization';

DECLARE @CanonChanged TABLE (ProductAttributeId bigint PRIMARY KEY, OldValue nvarchar(max), NewValue nvarchar(max));
UPDATE attribute SET Value = polish.NewValue
OUTPUT inserted.ProductAttributeId, deleted.Value, inserted.Value INTO @CanonChanged
FROM canon.ProductAttribute AS attribute
INNER JOIN #Map AS polish ON polish.AttributeCode = attribute.AttributeCode AND polish.OldValue = attribute.Value COLLATE Latin1_General_BIN2;

INSERT pim.AttributeValueNormalizationLog (TableName, RowId, OrganizationId, ItemID, AttributeCode, LanguageCode, OldValue, NewValue, ChangedBy)
SELECT N'canon.ProductAttribute', changed.ProductAttributeId, product.OrganizationId, product.ItemID, attribute.AttributeCode,
       attribute.LanguageCode, changed.OldValue, changed.NewValue, N'migracija 314'
FROM @CanonChanged changed
INNER JOIN canon.ProductAttribute attribute ON attribute.ProductAttributeId = changed.ProductAttributeId
INNER JOIN canon.Product product ON product.ProductId = attribute.ProductId;

DECLARE @PimChanged TABLE (PimProductAttributeId bigint PRIMARY KEY, OldValue nvarchar(max), NewValue nvarchar(max));
UPDATE attribute SET Value = polish.NewValue
OUTPUT inserted.PimProductAttributeId, deleted.Value, inserted.Value INTO @PimChanged
FROM pim.ProductAttribute AS attribute
INNER JOIN #Map AS polish ON polish.AttributeCode = attribute.AttributeCode AND polish.OldValue = attribute.Value COLLATE Latin1_General_BIN2;

INSERT pim.AttributeValueNormalizationLog (TableName, RowId, OrganizationId, ItemID, AttributeCode, LanguageCode, OldValue, NewValue, ChangedBy)
SELECT N'pim.ProductAttribute', changed.PimProductAttributeId, product.OrganizationId, product.ItemID, attribute.AttributeCode,
       attribute.LanguageCode, changed.OldValue, changed.NewValue, N'migracija 314'
FROM @PimChanged changed
INNER JOIN pim.ProductAttribute attribute ON attribute.PimProductAttributeId = changed.PimProductAttributeId
INNER JOIN pim.Product product ON product.PimProductId = attribute.PimProductId;

EXEC sys.sp_set_session_context @key = N'ChangeSource', @value = NULL;
EXEC sys.sp_set_session_context @key = N'ChangedBy', @value = NULL;
EXEC sys.sp_set_session_context @key = N'ChangeNote', @value = NULL;

IF (SELECT COUNT(*) FROM pim.AttributeValueNormalizationLog WHERE ChangedBy = N'migracija 314')
   <> (SELECT COUNT(*) FROM @CanonChanged) + (SELECT COUNT(*) FROM @PimChanged)
  THROW 53148, N'314: dnevnik nima vrstice za vsako spremembo; nič ni spremenjeno.', 1;

/* === 4. Zajem in izvoz kličeta lep zapis ================================================================ */
IF @TransformsDone = 0
BEGIN
  SET @Transforms = REPLACE(@Transforms, @CallOld, @CallNew);
  SET @Transforms = N'ALTER ' + SUBSTRING(@Transforms, CHARINDEX(N'PROCEDURE', @Transforms), 2147483647);
  EXEC sys.sp_executesql @Transforms;
END;
IF @ExportDone = 0
BEGIN
  SET @Export = REPLACE(@Export, @CallOld, @CallNew);
  SET @Export = N'ALTER ' + SUBSTRING(@Export, CHARINDEX(N'PROCEDURE', @Export), 2147483647);
  EXEC sys.sp_executesql @Export;
END;
IF OBJECT_DEFINITION(OBJECT_ID(N'map.ApplyValueTransforms')) LIKE N'%NormalizeAttributeValue%'
   OR OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows')) LIKE N'%NormalizeAttributeValue%'
   OR (DATALENGTH(OBJECT_DEFINITION(OBJECT_ID(N'map.ApplyValueTransforms')))
       - DATALENGTH(REPLACE(OBJECT_DEFINITION(OBJECT_ID(N'map.ApplyValueTransforms')), @CallNew, N''))) / DATALENGTH(@CallNew) <> 2
   OR (DATALENGTH(OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows')))
       - DATALENGTH(REPLACE(OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows')), @CallNew, N''))) / DATALENGTH(@CallNew) <> 1
   OR OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows')) NOT LIKE N'%Stolpci293%'
  THROW 53149, N'314: zamenjava klica v zajemu ali izvozu ni uspela; nič ni spremenjeno.', 1;

/* === 5. Povratek ======================================================================================== */
EXEC (N'
CREATE OR ALTER PROCEDURE pim.RevertAttributeValueNormalization
  @ChangedBy nvarchar(200),
  @Actor nvarchar(200),
  @DryRun bit = 0
AS
BEGIN
  /*
    314: vrne vrednosti atributov, ki jih je spremenilo poenotenje @ChangedBy (npr. »migracija 314«), na
    OldValue iz pim.AttributeValueNormalizationLog. Vrne samo, kjer je vrednost se enaka NewValue —
    vrednost, ki jo je kdo po poenotenju rocno ali z uvozom spremenil, ostane. Vsak povratek zapise dnevnik
    (ChangedBy = »povratek <poenotenje> (<kdo>)«) in zgodovino canon (sprozilec, vir POVRAT_POENOTENJA).
    @DryRun = 1 samo presteje. Pravila v zajemu in izvozu ne izklopi (za to je potrebna migracija).
  */
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  SET @ChangedBy = NULLIF(LTRIM(RTRIM(@ChangedBy)), N'''');
  SET @Actor = NULLIF(LTRIM(RTRIM(@Actor)), N'''');
  IF @ChangedBy IS NULL OR @Actor IS NULL
    THROW 53150, N''Povratek poenotenja potrebuje oznako poenotenja (@ChangedBy) in izvajalca (@Actor).'', 1;
  IF @ChangedBy LIKE N''povratek %''
    THROW 53151, N''Povratka ni mogoce povrniti s to proceduro; vrednosti uredi na kartici izdelka.'', 1;
  IF NOT EXISTS (SELECT 1 FROM pim.AttributeValueNormalizationLog WHERE ChangedBy = @ChangedBy)
    THROW 53152, N''V dnevniku poenotenja ni sprememb s to oznako.'', 1;

  DECLARE @RevertBy nvarchar(200) = LEFT(N''povratek '' + @ChangedBy + N'' ('' + @Actor + N'')'', 200);

  /* Zadnja sprememba te oznake na vrstico. */
  CREATE TABLE #Revert
    (TableName nvarchar(60) COLLATE DATABASE_DEFAULT NOT NULL, RowId bigint NOT NULL,
     OldValue nvarchar(max) NULL, NewValue nvarchar(max) NULL, PRIMARY KEY (TableName, RowId));
  INSERT #Revert (TableName, RowId, OldValue, NewValue)
  SELECT TableName, RowId, OldValue, NewValue
  FROM (SELECT TableName, RowId, OldValue, NewValue,
               ROW_NUMBER() OVER (PARTITION BY TableName, RowId ORDER BY AttributeValueNormalizationLogId DESC) AS RowNo
        FROM pim.AttributeValueNormalizationLog WHERE ChangedBy = @ChangedBy) AS logged
  WHERE logged.RowNo = 1;

  DECLARE @Candidates int = (SELECT COUNT(*) FROM #Revert);
  DECLARE @CanonReady int = (SELECT COUNT(*) FROM #Revert r INNER JOIN canon.ProductAttribute a ON a.ProductAttributeId = r.RowId
                             WHERE r.TableName = N''canon.ProductAttribute''
                               AND a.Value COLLATE Latin1_General_BIN2 = r.NewValue COLLATE Latin1_General_BIN2);
  DECLARE @PimReady int = (SELECT COUNT(*) FROM #Revert r INNER JOIN pim.ProductAttribute a ON a.PimProductAttributeId = r.RowId
                           WHERE r.TableName = N''pim.ProductAttribute''
                             AND a.Value COLLATE Latin1_General_BIN2 = r.NewValue COLLATE Latin1_General_BIN2);
  IF @DryRun = 1
  BEGIN
    SELECT @Candidates AS Candidates, @CanonReady AS CanonReverted, @PimReady AS PimReverted,
           @Candidates - @CanonReady - @PimReady AS SkippedChangedSince, CAST(1 AS bit) AS DryRun;
    RETURN;
  END;

  DECLARE @CanonDone TABLE (RowId bigint PRIMARY KEY, OldValue nvarchar(max), NewValue nvarchar(max));
  DECLARE @PimDone TABLE (RowId bigint PRIMARY KEY, OldValue nvarchar(max), NewValue nvarchar(max));

  BEGIN TRANSACTION;
    EXEC sys.sp_set_session_context @key = N''ChangeSource'', @value = N''POVRAT_POENOTENJA'';
    EXEC sys.sp_set_session_context @key = N''ChangedBy'', @value = @Actor;
    EXEC sys.sp_set_session_context @key = N''ChangeNote'', @value = @RevertBy;

    UPDATE attribute SET Value = r.OldValue
    OUTPUT inserted.ProductAttributeId, deleted.Value, inserted.Value INTO @CanonDone
    FROM canon.ProductAttribute AS attribute
    INNER JOIN #Revert AS r ON r.TableName = N''canon.ProductAttribute'' AND r.RowId = attribute.ProductAttributeId
    WHERE attribute.Value COLLATE Latin1_General_BIN2 = r.NewValue COLLATE Latin1_General_BIN2;

    INSERT pim.AttributeValueNormalizationLog (TableName, RowId, OrganizationId, ItemID, AttributeCode, LanguageCode, OldValue, NewValue, ChangedBy)
    SELECT N''canon.ProductAttribute'', done.RowId, product.OrganizationId, product.ItemID, attribute.AttributeCode,
           attribute.LanguageCode, done.OldValue, done.NewValue, @RevertBy
    FROM @CanonDone done
    INNER JOIN canon.ProductAttribute attribute ON attribute.ProductAttributeId = done.RowId
    INNER JOIN canon.Product product ON product.ProductId = attribute.ProductId;

    UPDATE attribute SET Value = r.OldValue
    OUTPUT inserted.PimProductAttributeId, deleted.Value, inserted.Value INTO @PimDone
    FROM pim.ProductAttribute AS attribute
    INNER JOIN #Revert AS r ON r.TableName = N''pim.ProductAttribute'' AND r.RowId = attribute.PimProductAttributeId
    WHERE attribute.Value COLLATE Latin1_General_BIN2 = r.NewValue COLLATE Latin1_General_BIN2;

    INSERT pim.AttributeValueNormalizationLog (TableName, RowId, OrganizationId, ItemID, AttributeCode, LanguageCode, OldValue, NewValue, ChangedBy)
    SELECT N''pim.ProductAttribute'', done.RowId, product.OrganizationId, product.ItemID, attribute.AttributeCode,
           attribute.LanguageCode, done.OldValue, done.NewValue, @RevertBy
    FROM @PimDone done
    INNER JOIN pim.ProductAttribute attribute ON attribute.PimProductAttributeId = done.RowId
    INNER JOIN pim.Product product ON product.PimProductId = attribute.PimProductId;

    EXEC sys.sp_set_session_context @key = N''ChangeSource'', @value = NULL;
    EXEC sys.sp_set_session_context @key = N''ChangedBy'', @value = NULL;
    EXEC sys.sp_set_session_context @key = N''ChangeNote'', @value = NULL;
  COMMIT TRANSACTION;

  SELECT @Candidates AS Candidates, (SELECT COUNT(*) FROM @CanonDone) AS CanonReverted, (SELECT COUNT(*) FROM @PimDone) AS PimReverted,
         @Candidates - (SELECT COUNT(*) FROM @CanonDone) - (SELECT COUNT(*) FROM @PimDone) AS SkippedChangedSince, CAST(0 AS bit) AS DryRun;
END
');

/* Povratek je takoj po poenotenju mogoč za vsako spremenjeno vrstico (suhi tek, nič se ne zapiše). */
DECLARE @Dry TABLE (Candidates int, CanonReverted int, PimReverted int, SkippedChangedSince int, DryRun bit);
IF EXISTS (SELECT 1 FROM pim.AttributeValueNormalizationLog WHERE ChangedBy = N'migracija 314')
BEGIN
  INSERT @Dry EXEC pim.RevertAttributeValueNormalization @ChangedBy = N'migracija 314', @Actor = N'migracija 314', @DryRun = 1;
  IF EXISTS (SELECT 1 FROM @Dry WHERE SkippedChangedSince <> 0
             OR CanonReverted <> (SELECT COUNT(*) FROM @CanonChanged) OR PimReverted <> (SELECT COUNT(*) FROM @PimChanged))
    THROW 53153, N'314: suhi tek povratka ne najde vseh spremenjenih vrstic; nič ni spremenjeno.', 1;
END;

COMMIT;
