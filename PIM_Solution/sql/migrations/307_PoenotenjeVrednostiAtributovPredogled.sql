/*
  307 — Predlog lepega zapisa vrednosti atributov (samo predogled) — naloga #15.

  Lastnik 2026-09-29: »atributi naj bodo besedilni, vpisati se da karkoli, uvoz pa besedilo prilagodi,
  popravi in lepo uredi (enotne enote, presledki, velike začetnice, pravopis)«. Lastnik je isti dan pri
  enotah (301) že odločil, da vrednosti ostanejo besedilo in »do 30 m« ostane, kot je.

  PRIVZETO ZA NOČ (lastnik lahko spremeni): pravilo je pripravljeno, a NI vklopljeno. Funkcije ne kliče
  noben zajem (map.ApplyValueTransforms), izvoz (out.GetExportRows) ali validacija. Razlog: če bi veljalo
  samo za nove uvoze, bi imel spletni filter dva zapisa iste vrednosti (»10W« pri starih in »10 W« pri
  novih izdelkih) — ravno težava, ki jo je odpravila 291. Vklop (zajem + katalog.csv + obstoječi podatki
  z dnevnikom pim.AttributeValueNormalizationLog in povratkom) je ločena naloga po potrditvi predogleda.

  Meritev na razvojni bazi PIM (DESKTOP-TONVQHJ\MSSQLSERVER3), 2026-09-29: 14.913 različnih parov
  (atribut, vrednost), predlog spremeni 269 parov (5.645 vrstic v pim.ProductAttribute), od tega 266 več
  kot obstoječe pravilo 291. Klic na vse različne vrednosti traja ~9 s.

  Objekti: nova funkcija pim.PolishAttributeValue (bere pim.NormalizeAttributeValue in map.ValueLookup).
  Podatki: nič. Ročni korak: ne. Migrator ne pozna GO.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;

IF UNICODE(N'č') <> 269
  THROW 53070, N'307: datoteka ni prebrana kot UTF-8 (sqlcmd -f 65001 ali Invoke-PendingMigrations.ps1).', 1;
IF OBJECT_ID(N'pim.NormalizeAttributeValue', N'FN') IS NULL
  THROW 53071, N'307 potrebuje pim.NormalizeAttributeValue (291).', 1;

BEGIN TRAN;

EXEC (N'
CREATE OR ALTER FUNCTION pim.PolishAttributeValue (@AttributeCode nvarchar(400), @Value nvarchar(max))
RETURNS nvarchar(max)
AS
BEGIN
  /*
    307: PREDLOG lepega zapisa vrednosti atributa (samo predogled na /nastavitve/atributi/ciscenje).
    Funkcije ne klice noben zajem, izvoz ali validacija: dokler lastnik predloga ne potrdi, se
    podatki in katalog.csv ne spremenijo. Najprej obstojece pravilo pim.NormalizeAttributeValue (291),
    nato:
      1. razpon brez presledkov okoli vezaja med stevilkama: »30 - 50« -> »30-50«;
      2. presledek med stevilom in enoto z znanega seznama: »50m« -> »50 m«, »do 30m« -> »do 30 m«,
         »10W only LED« -> »10 W only LED«; »IP44«, »E27«, »GU10«, »3CCT« ostanejo (crka pred stevilom
         ali neznana oznaka);
      3. presledek za vejico v seznamu: »3CCT,IP65« -> »3CCT, IP65«; decimalna »1,5« ostane;
      4. velika zacetnica samo pri cistem besedilu brez stevk, ko je prva beseda vsa z malimi crkami in
         dolga vsaj 3 znake: »bela« -> »Bela«; »LED«, »mm«, »iPhone«, »kWh« ostanejo;
      5. se enkrat slovar ENOTNO (izjeme, ki jih vodi uporabnik na /pravila/slovar).
    Napetost in Frekvenca imata svoje pravilo v 291 in ostaneta, kot ju vrne ta. Polja s kodo namesto imena (SAOP, npr. SEKUNDARNAMERSKAENOTA), povezave in e-naslovi
    ostanejo nespremenjeni. NULL ostane NULL. »do 30 m« ostane besedilo (odlocitev lastnika, 301).
  */
  IF @Value IS NULL RETURN NULL;
  DECLARE @v nvarchar(max) = pim.NormalizeAttributeValue(@AttributeCode, @Value);
  IF @v = N'''' OR @AttributeCode IN (N''Napetost'', N''Frekvenca'')
     OR @v LIKE N''%://%'' OR @v LIKE N''%www.%'' OR @v LIKE N''%@%''
     /* polja s kodo namesto imena (SAOP: SEKUNDARNAMERSKAENOTA, BUG) nosijo sifre, ne besedila */
     OR (@AttributeCode NOT LIKE N''% %'' AND @AttributeCode COLLATE Latin1_General_CS_AS = UPPER(@AttributeCode) COLLATE Latin1_General_CS_AS)
    RETURN @v;

  /* 1. »30 - 50« -> »30-50« */
  DECLARE @p int = PATINDEX(N''%[0-9] - [0-9]%'', @v COLLATE Latin1_General_BIN);
  WHILE @p > 0
  BEGIN
    SET @v = STUFF(@v, @p + 1, 3, N''-'');
    SET @p = PATINDEX(N''%[0-9] - [0-9]%'', @v COLLATE Latin1_General_BIN);
  END;

  /* 2. presledek med stevilom in enoto */
  DECLARE @i int = 1, @j int, @k int, @Len int = LEN(@v), @Token nvarchar(20), @Before nchar(1), @After nchar(1);
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

  /* 3. presledek za vejico, razen med stevkama (decimalna vejica) */
  SET @i = 1;
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

/* Dokaz pravila: če kateri primer ne da pričakovanega, migracija pade in nič ne ostane. */
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
  (N'Ikone', N'3CCT,IP65', N'3CCT, IP65'),
  (N'Širina', N'1,5', N'1.5'),
  (N'Širina', N'11.9x11.9', N'11.9x11.9'),
  (N'Video', N'https://www.youtube.com/watch?v=a6vKYaqyMQA', N'https://www.youtube.com/watch?v=a6vKYaqyMQA');
DECLARE @FailedMessage nvarchar(2000) =
  (SELECT TOP (1) N'307: »' + c.Input + N'« (' + c.AttributeCode + N') da »' + ISNULL(r.Value, N'NULL') + N'«, pričakovano »' + c.Expected + N'«.'
   FROM @Check c CROSS APPLY (SELECT Value = pim.PolishAttributeValue(c.AttributeCode, c.Input)) r
   WHERE r.Value IS NULL OR r.Value COLLATE Latin1_General_BIN <> c.Expected COLLATE Latin1_General_BIN);
IF @FailedMessage IS NOT NULL
  THROW 53072, @FailedMessage, 1;
IF pim.PolishAttributeValue(N'Barva', NULL) IS NOT NULL
  THROW 53073, N'307: NULL mora ostati NULL.', 1;

COMMIT;
