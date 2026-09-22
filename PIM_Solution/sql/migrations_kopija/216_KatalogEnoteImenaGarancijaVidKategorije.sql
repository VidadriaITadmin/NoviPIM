/*
  216 — katalog.csv: enota v glavi stolpca, imena partnerjev, garancija v letih, velike zacetnice,
        kategorije VID iz svetil, napetost/frekvenca pri Braytronu in Nowodvorskem.

  Uporabnik 2026-09-16 je pregledal katalog.csv (podjetje 2, 2.176 vrstic) in nastel napake. Vsaka
  tocka spodaj je ena od njih; kjer je odlocitev njegova, je zapisana dobesedno.

  1. »Proizvajalec in dobavitelj je koda, moglo bi biti ime dobavitelja pa proizvajalca.«
     Stolpca 6 in 7 sta nosila sifri SAOP (00001625, 91086973). Izvoz zdaj bere ime iz
     canon.PartnerName (isti vir kot kartica izdelka, 128); kjer imena ni, ostane sifra.

  2. »Atributi teze, dolzine nimajo v oklepajih enote ... PIM mora zagotoviti, da je zmeraj enota.«
     in »kjer imajo vrednost in pa enoto posebej, smo v PIM_test bazi enoto odstranili in dali v ime
     vrednosti v [] — tako smo prispsarali na placu.«
     Vsak stolpec z mersko kolicino dobi enoto v glavi: "Bruto teza [kg]", "Visina [mm]",
     "Napetost [V]" ... Vseh 40 stolpcev "Enota ..." se izklopi (IsActive = 0, ne brisanje — 005).
     Katera enota velja za kateri stolpec, je podatek v novem registru out.CatalogUnitRule, ne
     koda: vrstica pove kanonicno polje vrednosti, (neobvezno) polje z enoto in ciljno enoto.
     Izvoz vrednost pretvori v enoto glave (cm -> mm x10, m -> mm x1000, gr -> kg /1000, ...
     out.UnitFactor); ce enota ni znana ali vrednost ni stevilo (npr. "220-240", "50/60",
     "22x12"), se vrednosti samo odvzame enota, ki je enaka enoti glave ("50/60 Hz" -> "50/60",
     "3000K" -> "3000", "120°" -> "120"). Kar izvoz ne razume ("3IN1", "80lm/W", "24°/36°/60°"),
     pusti pri miru — tiho spreminjanje bi bilo laz. Izmerjeno pred pisanjem: pri podjetju 2 ima
     ERP mere paketa v mm (13.886) in m (27.567, vse 0), Braytron mere v mm, pakete v mm in cm,
     Nowodvorski vse v cm; teze Braytron "kgs"; volumen paketa dm3.
     Ciljne enote: dolzine izdelka mm (podatek Braytrona), roke/sencniki/podnozja/paketi
     dobavitelja cm (podatek Nowodvorskega), teze kg, volumen paketa dm3, volumen ERP m3
     (predpostavka — SAOP enote ne poslje, vrednosti so 0), kot °, svetlobni tok lm, frekvenca
     Hz, napetost V, temperatura barve K, zivljenjska doba h, nazivna moc W.

  3. »Kategorija VID je prazna, daj to od svetila prekopiraj v vid kategorijo in morajo biti
     svetila v isti kategoriji.«
     Drevo videlektro (092, 77 kategorij s spletne strani) ni imelo nobene preslikave dobaviteljev
     (map.CategoryPathMap: 226 vrstic, vse svetila_si), zato je map.ResolveProductCategories za
     videlektro vedno naredil nic in stolpca 26/27 sta bila prazna. Drevo svetila_si (132
     kategorij, prevodi sl/en/de/hr) se zrcali v drevo videlektro pod ISTIMI kodami in imeni,
     preslikave dobaviteljev (NW_XML, BT_XML) se prekopirajo na drevo videlektro, obstojece
     uvrstitve svetila_si/svetila_si_en pa se prepisejo v B2C/B2C_EN (canon in pim), da katalog
     ne caka na naslednji zajem XML. Od tu naprej pot dela sama: nova preslikava na svetila_si je
     samo za svetila_si — ce naj velja tudi za VID, jo urednik doda se tam (ali se 216 ponovi).
     Rocna uvrstitev (pim.ProductCategoryOverride, 109) ima prednost in se ne prepise.

  4. »Garancijo imava nekje leti nekje years, to morava vse spremeniti v leti, samo treba je
     pravilno sklanjati: 1 leto, 2 leti, 3 leta, 4 leta.«
     Funkcija pim.WarrantySl: iz "5 years", "3 Years", "2", "5 let" naredi "5 let", "3 leta",
     "2 leti", "5 let" (1 leto, 2 leti, 3 in 4 leta, sicer let). Kar ni stevilo let (SAOP polje
     Warranty pri nekaterih dobaviteljih nosi naziv izdelka, npr. "LED svetilka, stropna,
     vgradna"), ostane nespremenjeno — to je napaka vira, ne oblike. Uporabi se pri zajemu
     (pretvorba WARRANTY na vseh preslikavah v ProductAttribute.Garancija: SAOP, NW, BT), v
     izvozu in enkratno na obstojecih vrsticah canon/pim.

  5. »Uporaba SLO je z malimi crkami ... vsi prevodi so z malo crko, to popravi, da se zacnejo z
     veliko crko.«
     Slovar map.ValueLookup (jeziki SL/DE/HR, domene atributov in '*') dobi veliko zacetnico,
     obstojece prevedene vrednosti (canon/pim.ProductAttribute z jezikom) prav tako, izvoz jo
     zagotovi se sam (stolpci SLO/ANG), zajem pa s pretvorbo CAPITALIZE za vsako preslikavo
     v jezikovni stolpec (... SLO / ... ANG).

  6. »Stolpec Komentarji lahko damo stran.« — COL084 IsActive = 0.

  7. »Pri NW XML-ju je nekje frekvenca in napetost pomesana, treba popraviti ze v PIM-u« in
     »Napetost: enkrat stolpec od Braytrona, enkrat od NW — bi moralo biti eno in isto, od obeh
     v enem stolpcu.«
     - Nowodvorski (NW.11710): frekvenca "~220-230", napetost "50/60". map.ApplyValueTransforms
       po pretvorbah zamenja par, kjer frekvenca nosi stotice in napetost ne; obstojeci vrstici
       se popravita tu.
     - Braytron poslje eno vrednost "220-240V 50/60Hz" in preslikava jo je pisala v DVA atributa
       (Napetost IN Nazivna napetost), frekvence pa ni bilo. Zdaj: Napetost = del pred "V"
       ("220-240"), Frekvenca = del med presledkom in "Hz" ("50/60") — nova preslikava iz istega
       elementa s pretvorbami REQUIRE/AFTER/BEFORE; podvojena preslikava v Nazivna napetost se
       izklopi, njene vrstice (1.202, vse "…Hz" ali "…VDC") se izbrisejo, obstojece vrednosti
       Napetost (1.118 z "Hz") se razcepijo enako kot bo odslej pri zajemu.
     Nove pretvorbe v map.ApplyValueTransforms so splosne: BEFORE <locilo> (del pred prvim
     locilom; brez locila vrednost ostane), AFTER <locilo> (del za prvim locilom; brez locila
     NULL — vrednost izpade), REQUIRE <niz> (vrednost ostane le, ce niz vsebuje), WARRANTY,
     CAPITALIZE.

  Kar ta migracija NAMENOMA ne spremeni (uporabnik odloca):
     - "Naziv artikla EN" je ze WARNING (val.FieldRequirement 50/59, profila WEB_svetila_si in
       WEB_videlektro) in izdelka ne blokira; 652 vrstic brez EN naziva je delo urednika.
     - "Dobavitelj datum" je ze dd.MM.yyyy (CONVERT 104, 146) — v datoteki "28.09.2026".
     - Stolpca "Bruto teza (2)"/"Neto teza (2)" (teza po Braytronu) ostaneta poleg ERP teze;
       zdruzitev je predlog v docs/KATALOG_PRESLIKAVA_ATRIBUTOV.md.

  Stevilo aktivnih stolpcev: 217 (209) - 40 "Enota ..." - Komentarji = 176. SortOrder se
  prestevilci zvezno 1..176, neaktivni gredo na 900+ (kot ze COL055/COL058 po 209).
  Predloga v C# (MagentoCsvContract.ProductHeaders) in testi F7 so uskladeni v istem commitu;
  delujoci worker jih ne potrebuje — glave bere iz registra (ExportProfileRegistry).

  out.GetExportRows se od 171 popravlja z zamenjavo besedila zive definicije (194 ... 213); enako
  tu z oznako /* Catalog216 */ takoj za CREATE CLUSTERED INDEX IX_Value (blok isce po RowKey). map.ApplyValueTransforms
  enako z oznakama /* Transforms216 */ in /* SwapVoltageFrequency216 */. Migrator ne pozna GO
  (061), zato CREATE OR ALTER v EXEC(N'...').
*/

SET XACT_ABORT ON;

DECLARE @ProfileId int = (SELECT ExportProfileId FROM out.ExportProfile WHERE ProfileCode = N'MAGENTO_PRODUCTS');
IF @ProfileId IS NULL THROW 52160, N'216: profil MAGENTO_PRODUCTS manjka.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows')) NOT LIKE N'%/* WebSitesFromFlags213 */%'
  THROW 52161, N'216: out.GetExportRows nima popravka 213 — migracije niso uporabljene po vrsti.', 1;
IF OBJECT_ID(N'canon.PartnerName') IS NULL THROW 52162, N'216: pogled canon.PartnerName (115) manjka.', 1;

/* ======================================================================================
   1) Funkciji: faktor med enotama in garancija v letih
   ====================================================================================== */

EXEC(N'
CREATE OR ALTER FUNCTION out.UnitFactor(@FromUnit nvarchar(50), @ToUnit nvarchar(50))
RETURNS decimal(19,9)
WITH INLINE = OFF /* 216: vgrajevanje skalarne funkcije (SQL 2019) je v out.GetExportRows z iskanjem dalo napako 8632 (meja izrazov) */
AS
BEGIN
  /* 216: koliksnik med izvorno in ciljno enoto. NULL = enote ne poznam ali nista iste vrste;
     klicatelj takrat vrednosti ne sme spreminjati. Sopomenke dobaviteljev: kgs, gr, dm³, ⁰. */
  DECLARE @From nvarchar(50) = LOWER(LTRIM(RTRIM(@FromUnit)));
  DECLARE @To nvarchar(50) = LOWER(LTRIM(RTRIM(@ToUnit)));
  IF @From IS NULL OR @To IS NULL RETURN NULL;
  SET @From = CASE @From WHEN N''kgs'' THEN N''kg'' WHEN N''gr'' THEN N''g'' WHEN N''dm³'' THEN N''dm3'' WHEN N''m³'' THEN N''m3''
                         WHEN N''cm³'' THEN N''cm3'' WHEN N''l'' THEN N''dm3'' WHEN N''⁰'' THEN N''°'' WHEN N''º'' THEN N''°'' WHEN N''˚'' THEN N''°'' WHEN N''deg'' THEN N''°''
                         WHEN N''hours'' THEN N''h'' WHEN N''hr'' THEN N''h'' WHEN N''ur'' THEN N''h'' ELSE @From END;
  SET @To = CASE @To WHEN N''kgs'' THEN N''kg'' WHEN N''gr'' THEN N''g'' WHEN N''dm³'' THEN N''dm3'' WHEN N''m³'' THEN N''m3''
                     WHEN N''cm³'' THEN N''cm3'' WHEN N''l'' THEN N''dm3'' WHEN N''⁰'' THEN N''°'' WHEN N''º'' THEN N''°'' WHEN N''˚'' THEN N''°'' WHEN N''deg'' THEN N''°''
                     WHEN N''hours'' THEN N''h'' WHEN N''hr'' THEN N''h'' WHEN N''ur'' THEN N''h'' ELSE @To END;
  IF @From = @To RETURN 1;
  DECLARE @FromBase decimal(19,9) = CASE @From WHEN N''mm'' THEN 1 WHEN N''cm'' THEN 10 WHEN N''m'' THEN 1000
                                               WHEN N''g'' THEN 1 WHEN N''kg'' THEN 1000
                                               WHEN N''cm3'' THEN 1 WHEN N''dm3'' THEN 1000 WHEN N''m3'' THEN 1000000 END;
  DECLARE @ToBase decimal(19,9) = CASE @To WHEN N''mm'' THEN 1 WHEN N''cm'' THEN 10 WHEN N''m'' THEN 1000
                                           WHEN N''g'' THEN 1 WHEN N''kg'' THEN 1000
                                           WHEN N''cm3'' THEN 1 WHEN N''dm3'' THEN 1000 WHEN N''m3'' THEN 1000000 END;
  /* Ista vrsta kolicine: dolzina (mm/cm/m), masa (g/kg), prostornina (cm3/dm3/m3). */
  IF @FromBase IS NULL OR @ToBase IS NULL RETURN NULL;
  DECLARE @FromKind nvarchar(10) = CASE WHEN @From IN (N''mm'',N''cm'',N''m'') THEN N''len'' WHEN @From IN (N''g'',N''kg'') THEN N''mass'' ELSE N''vol'' END;
  DECLARE @ToKind nvarchar(10) = CASE WHEN @To IN (N''mm'',N''cm'',N''m'') THEN N''len'' WHEN @To IN (N''g'',N''kg'') THEN N''mass'' ELSE N''vol'' END;
  IF @FromKind <> @ToKind RETURN NULL;
  RETURN @FromBase / @ToBase;
END;
');

EXEC(N'
CREATE OR ALTER FUNCTION pim.WarrantySl(@Value nvarchar(400))
RETURNS nvarchar(400)
WITH INLINE = OFF
AS
BEGIN
  /* 216: garancija v letih, sklanjana: 1 leto, 2 leti, 3 leta, 4 leta, 5 let ... Sprejme "5 years",
     "3 Years", "2", "2 leti", "5 let". Kar ni stevilo let (naziv izdelka, meseci, prazno), vrne
     nespremenjeno — oblika se ne sme izmisljati podatka. */
  DECLARE @Text nvarchar(400) = LTRIM(RTRIM(@Value));
  IF @Text IS NULL OR @Text = N'''' RETURN @Value;
  DECLARE @Cut int = PATINDEX(N''%[^0-9]%'', (@Text + N''x'') COLLATE Latin1_General_BIN2);
  DECLARE @Digits nvarchar(400) = LEFT(@Text, @Cut - 1);
  IF @Digits = N'''' RETURN @Value;
  DECLARE @Rest nvarchar(400) = LOWER(LTRIM(RTRIM(SUBSTRING(@Text, @Cut, 400))));
  IF @Rest NOT IN (N'''', N''leto'', N''leti'', N''leta'', N''let'', N''l'', N''year'', N''years'', N''yr'', N''yrs'', N''y'',
                   N''jahr'', N''jahre'', N''godina'', N''godine'', N''god'', N''anni'', N''anno'')
    RETURN @Value;
  DECLARE @Years int = TRY_CONVERT(int, @Digits);
  IF @Years IS NULL OR @Years <= 0 OR @Years > 99 RETURN @Value;
  RETURN CONVERT(nvarchar(20), @Years) + CASE @Years WHEN 1 THEN N'' leto'' WHEN 2 THEN N'' leti'' WHEN 3 THEN N'' leta'' WHEN 4 THEN N'' leta'' ELSE N'' let'' END;
END;
');

/* ======================================================================================
   2) Register enot: katero polje ima katero enoto v glavi
   ====================================================================================== */

IF OBJECT_ID(N'out.CatalogUnitRule') IS NULL
BEGIN
  CREATE TABLE out.CatalogUnitRule
  (
    CatalogUnitRuleId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_CatalogUnitRule PRIMARY KEY,
    ValueFieldCode nvarchar(450) NOT NULL,           /* kanonicna koda stolpca z vrednostjo (out.ExportColumn.CanonicalFieldCode) */
    UnitFieldCode nvarchar(450) NULL,                /* kanonicna koda polja, ki nosi enoto vira (NULL = enota je le v vrednosti ali je ni) */
    TargetUnit nvarchar(50) NOT NULL,                /* enota v glavi stolpca: "[kg]", "[mm]" ... */
    IsActive bit NOT NULL CONSTRAINT DF_CatalogUnitRule_IsActive DEFAULT (1),
    Note nvarchar(400) NULL,
    CONSTRAINT UQ_CatalogUnitRule_Field UNIQUE (ValueFieldCode)
  );
END;

MERGE out.CatalogUnitRule AS target
USING (VALUES
  (N'Product.GrossWeight', NULL, N'kg', N'SAOP teze brez enote; predpostavka kg'),
  (N'Product.NetWeight', NULL, N'kg', N'SAOP teze brez enote; predpostavka kg'),
  (N'Product.Volume', NULL, N'm3', N'SAOP volumen brez enote; predpostavka m3 (vrednosti 0)'),
  (N'Product.PackageLength', N'Product.DimensionUnit', N'mm', N'ERP mere paketa; enota iz ProductCommercial.DimensionUnit'),
  (N'Product.PackageWidth', N'Product.DimensionUnit', N'mm', N'ERP mere paketa; enota iz ProductCommercial.DimensionUnit'),
  (N'Product.PackageHeight', N'Product.DimensionUnit', N'mm', N'ERP mere paketa; enota iz ProductCommercial.DimensionUnit'),
  (N'Attr.Kot svetlobnega snopa', N'Attr.Enota kota svetlobnega snopa', N'°', NULL),
  (N'Attr.Višina stropne kapice', N'Attr.Enota višine stropne kapice', N'cm', NULL),
  (N'Attr.Širina stropne kapice', N'Attr.Enota širine stropne kapice', N'cm', NULL),
  (N'Attr.Nazivna moč', NULL, N'W', NULL),
  (N'Attr.Temperatura barve', NULL, N'K', N'"3000K" -> 3000; "3IN1" ostane'),
  (N'Attr.Premer', NULL, N'mm', N'Braytron "45 mm"'),
  (N'Attr.Višina', N'Attr.Enota višine', N'mm', N'Braytron mm'),
  (N'Attr.Dolžina', N'Attr.Enota dolžine', N'mm', N'Braytron mm'),
  (N'Attr.Širina', N'Attr.Enota širine', N'mm', N'Braytron mm'),
  (N'Attr.Razdalja od stene', N'Attr.Enota razdalje od stene', N'cm', NULL),
  (N'Attr.Svetlobni tok', N'Attr.Enota svetlobnega toka', N'lm', NULL),
  (N'Attr.Frekvenca', N'Attr.Enota frekvence', N'Hz', N'"50/60 Hz" -> 50/60'),
  (N'Attr.Bruto teža (2)', N'Attr.Enota bruto teže (2)', N'kg', N'Braytron "kgs"'),
  (N'Attr.Neto teža (2)', N'Attr.Enota neto teže (2)', N'kg', N'Braytron "kgs"'),
  (N'Attr.Razpon nastavitve višine', N'Attr.Enota razpona nastavitve višine', N'cm', NULL),
  (N'Attr.Višina daljše roke', N'Attr.Enota višine daljše roke', N'cm', NULL),
  (N'Attr.Višina senčnika reflektorja', N'Attr.Enota višine senčnika reflektorja', N'cm', NULL),
  (N'Attr.Višina krajše roke', N'Attr.Enota višine krajše roke', N'cm', NULL),
  (N'Attr.Dimenzije odprtine', N'Attr.Enota dimenzij odprtine', N'cm', N'"22x12" ostane, enota se odvzame'),
  (N'Attr.Dolžina podnožja', N'Attr.Enota dolžine podnožja', N'cm', NULL),
  (N'Attr.Dolžina horizontalne roke', N'Attr.Enota dolžine horizontalne roke', N'cm', NULL),
  (N'Attr.Dolžina senčnika', N'Attr.Enota dolžine senčnika', N'cm', NULL),
  (N'Attr.Dolžina vertikalne roke', N'Attr.Enota dolžine vertikalne roke', N'cm', NULL),
  (N'Attr.Življenjska doba', NULL, N'h', N'"20000 h" -> 20000'),
  (N'Attr.Višina paketa I', N'Attr.Enota višine paketa I', N'cm', N'Nowodvorski cm, Braytron mm ali cm'),
  (N'Attr.Višina paketa II', N'Attr.Enota višine paketa II', N'cm', NULL),
  (N'Attr.Višina paketa III', N'Attr.Enota višine paketa III', N'cm', NULL),
  (N'Attr.Dolžina paketa I', N'Attr.Enota dolžine paketa I', N'cm', N'Nowodvorski cm, Braytron mm ali cm'),
  (N'Attr.Dolžina paketa II', N'Attr.Enota dolžine paketa II', N'cm', NULL),
  (N'Attr.Dolžina paketa III', N'Attr.Enota dolžine paketa III', N'cm', NULL),
  (N'Attr.Volumen paketa', N'Attr.Enota volumna paketa', N'dm3', NULL),
  (N'Attr.Širina paketa I', N'Attr.Enota širine paketa I', N'cm', N'Nowodvorski cm, Braytron mm ali cm'),
  (N'Attr.Širina paketa II', N'Attr.Enota širine paketa II', N'cm', NULL),
  (N'Attr.Širina paketa III', N'Attr.Enota širine paketa III', N'cm', NULL),
  (N'Attr.Dolžina spuščenega stropa', N'Attr.Enota dolžine spuščenega stropa', N'cm', NULL),
  (N'Attr.Napetost', N'Attr.Enota napetosti', N'V', N'"~220-230" ostane (NW zapis za izmenicno)'),
  (N'Attr.Širina podnožja', N'Attr.Enota širine podnožja', N'cm', NULL),
  (N'Attr.Širina senčnika reflektorja', N'Attr.Enota širine senčnika reflektorja', N'cm', NULL)
) AS source (ValueFieldCode, UnitFieldCode, TargetUnit, Note)
  ON target.ValueFieldCode = source.ValueFieldCode
WHEN MATCHED THEN UPDATE SET UnitFieldCode = source.UnitFieldCode, TargetUnit = source.TargetUnit, Note = source.Note, IsActive = 1
WHEN NOT MATCHED THEN INSERT (ValueFieldCode, UnitFieldCode, TargetUnit, Note) VALUES (source.ValueFieldCode, source.UnitFieldCode, source.TargetUnit, source.Note);

IF EXISTS (SELECT 1 FROM out.CatalogUnitRule unitRule
           WHERE NOT EXISTS (SELECT 1 FROM out.ExportColumn c WHERE c.ExportProfileId = @ProfileId AND c.CanonicalFieldCode = unitRule.ValueFieldCode))
  THROW 52163, N'216: pravilo enote kaze na polje, ki ga katalog nima.', 1;

/* ======================================================================================
   3) Stolpci: Komentarji in "Enota ..." ven, enota v glavo, zvezno ostevilcenje
   ====================================================================================== */

UPDATE out.ExportColumn
  SET IsActive = 0
WHERE ExportProfileId = @ProfileId AND IsActive = 1
  AND (OutputColumnName = N'Komentarji' OR OutputColumnName LIKE N'Enota %');

UPDATE c
  SET OutputColumnName = c.OutputColumnName + N' [' + unitRule.TargetUnit + N']'
FROM out.ExportColumn c
INNER JOIN out.CatalogUnitRule unitRule ON unitRule.ValueFieldCode = c.CanonicalFieldCode
WHERE c.ExportProfileId = @ProfileId AND c.IsActive = 1 AND c.OutputColumnName NOT LIKE N'%[[]%]';

/* Dve fazi zaradi UQ (ExportProfileId, SortOrder): najprej vse iz obsega, nato zvezno. */
UPDATE out.ExportColumn SET SortOrder = SortOrder + 100000 WHERE ExportProfileId = @ProfileId;
WITH ranked AS
(
  SELECT SortOrder, IsActive, ROW_NUMBER() OVER (PARTITION BY IsActive ORDER BY SortOrder) AS Position
  FROM out.ExportColumn WHERE ExportProfileId = @ProfileId
)
UPDATE ranked SET SortOrder = CASE WHEN IsActive = 1 THEN Position ELSE 900 + Position END;

/* ======================================================================================
   4) out.GetExportRows: imena partnerjev, garancija, velike zacetnice, enote v glavi
   ====================================================================================== */

DECLARE @definition nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows'));
DECLARE @anchor nvarchar(200) = N'CREATE CLUSTERED INDEX IX_Value ON #Value (RowKey);';
/* Blok tece PO gradnji gruce IX_Value: iskanje enote po RowKey v #Value brez indeksa je bilo pri
   2.176 izdelkih x ~100 polj kvadratno (izmerjeno: > 5 minut), z indeksom nekaj sekund. */
DECLARE @block nvarchar(max) = N'
  IF @ValueSource=N''PIM_PRODUCT'' BEGIN /* Catalog216 */
    /* 216a: sifra partnerja -> ime (canon.PartnerName, isti vir kot kartica izdelka, 128). Brez imena ostane sifra. */
    UPDATE value SET Value=partner.PartnerName
    FROM #Value value
    INNER JOIN canon.PartnerName partner ON partner.OrganizationId=@OrganizationId AND partner.PartnerCode=value.Value
    WHERE value.FieldCode IN(N''Product.Manufacturer'',N''Product.Supplier'') AND NULLIF(partner.PartnerName,N'''') IS NOT NULL;
    /* 216b: garancija v letih, sklanjana (1 leto, 2 leti, 3 leta, 5 let). */
    UPDATE #Value SET Value=pim.WarrantySl(Value) WHERE FieldCode=N''Attr.Garancija'';
    /* 216c: prevedene vrednosti (stolpci SLO/ANG) z veliko zacetnico. */
    UPDATE #Value SET Value=UPPER(LEFT(Value,1))+SUBSTRING(Value,2,4000)
    WHERE (FieldCode LIKE N''Attr.% SLO'' OR FieldCode LIKE N''Attr.% ANG'') AND NULLIF(Value,N'''') IS NOT NULL;
    /* 216d: enota je v glavi stolpca (out.CatalogUnitRule). Stevilo se pretvori v enoto glave
       (out.UnitFactor), nestevilski vrednosti se enota glave samo odvzame, neznana enota pusti
       vrednost pri miru. Enota vira: iz vrednosti same, sicer iz polja z enoto, sicer enota glave. */
    UPDATE value SET Value=converted.Value
    FROM #Value value
    INNER JOIN out.CatalogUnitRule unitRule ON unitRule.ValueFieldCode=value.FieldCode AND unitRule.IsActive=1
    OUTER APPLY(SELECT TOP(1) unitValue.Value AS Unit FROM #Value unitValue
                WHERE unitRule.UnitFieldCode IS NOT NULL AND unitValue.RowKey=value.RowKey AND unitValue.FieldCode=unitRule.UnitFieldCode
                  AND NULLIF(unitValue.Value,N'''') IS NOT NULL) unitColumn
    /* BIN2: pod jezikovno zbirko je nadpisana nicla (⁰, Braytron "120⁰") stevka in bi ostala v stevilu. */
    CROSS APPLY(SELECT Cut=PATINDEX(N''%[^-0-9,. ]%'',(value.Value+N''x'') COLLATE Latin1_General_BIN2)) mark
    CROSS APPLY(SELECT NumberText=NULLIF(REPLACE(LTRIM(RTRIM(LEFT(value.Value,mark.Cut-1))),N'','',N''.''),N''''),
                       InlineUnit=NULLIF(LTRIM(RTRIM(SUBSTRING(value.Value,mark.Cut,400))),N'''')) part
    CROSS APPLY(SELECT Factor=out.UnitFactor(COALESCE(part.InlineUnit,unitColumn.Unit,unitRule.TargetUnit),unitRule.TargetUnit),
                       Number=TRY_CONVERT(decimal(19,6),part.NumberText)) calc
    /* Nestevilska vrednost z enoto glave na koncu ("50/60 Hz", "50/60Hz"): enota se samo odvzame. */
    CROSS APPLY(SELECT Stripped=CASE WHEN LEN(value.Value)>LEN(unitRule.TargetUnit)
        AND RIGHT(value.Value,LEN(unitRule.TargetUnit)) COLLATE Latin1_General_CI_AS=unitRule.TargetUnit COLLATE Latin1_General_CI_AS
        THEN NULLIF(RTRIM(LEFT(value.Value,LEN(value.Value)-LEN(unitRule.TargetUnit))),N'''') END) suffix
    CROSS APPLY(SELECT Value=CASE
        WHEN calc.Factor IS NULL AND suffix.Stripped IS NOT NULL THEN suffix.Stripped
        WHEN calc.Factor IS NULL THEN value.Value
        WHEN calc.Number IS NOT NULL THEN out.MagentoNumber(calc.Number*calc.Factor)
        WHEN calc.Factor=1 AND part.NumberText IS NOT NULL THEN part.NumberText
        ELSE value.Value END) converted
    WHERE NULLIF(value.Value,N'''') IS NOT NULL AND converted.Value<>value.Value;
  END;';

IF @definition NOT LIKE N'%/* Catalog216 */%'
BEGIN
  DECLARE @at int = CHARINDEX(@anchor, @definition);
  IF @at = 0 OR CHARINDEX(@anchor, @definition, @at + 1) <> 0
    THROW 52164, N'216: sidro CREATE CLUSTERED INDEX IX_Value v out.GetExportRows ni najdeno natanko enkrat.', 1;
  SET @definition = STUFF(@definition, @at + LEN(@anchor), 0, @block);
  SET @definition = N'ALTER ' + SUBSTRING(@definition, CHARINDEX(N'PROCEDURE', @definition), 2147483647);
  EXEC sys.sp_executesql @definition;
END;

/* ======================================================================================
   5) map.ApplyValueTransforms: BEFORE / AFTER / REQUIRE / WARRANTY / CAPITALIZE
      in zamenjava napetost <-> frekvenca, kadar sta v viru zamenjani
   ====================================================================================== */

DECLARE @transforms nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'map.ApplyValueTransforms'));
IF @transforms IS NULL THROW 52165, N'216: map.ApplyValueTransforms ne obstaja.', 1;
DECLARE @old nvarchar(max), @new nvarchar(max);

IF @transforms NOT LIKE N'%/* Transforms216 */%'
BEGIN
  SET @old = N'WHEN N''NUMBER'' THEN number.Result';
  SET @new = N'/* Transforms216 */
          WHEN N''BEFORE'' THEN
            CASE WHEN CHARINDEX(step.Argument, value.Value) > 0
                 THEN NULLIF(LTRIM(RTRIM(LEFT(value.Value, CHARINDEX(step.Argument, value.Value) - 1))), N'''')
                 ELSE value.Value END
          WHEN N''AFTER'' THEN
            CASE WHEN CHARINDEX(step.Argument, value.Value) > 0
                 THEN NULLIF(LTRIM(RTRIM(SUBSTRING(value.Value, CHARINDEX(step.Argument, value.Value) + LEN(step.Argument + N''x'') - 1, 4000))), N'''')
                 ELSE NULL END
          WHEN N''REQUIRE'' THEN CASE WHEN CHARINDEX(step.Argument, value.Value) > 0 THEN value.Value ELSE NULL END
          WHEN N''WARRANTY'' THEN pim.WarrantySl(value.Value)
          WHEN N''CAPITALIZE'' THEN UPPER(LEFT(value.Value, 1)) + SUBSTRING(value.Value, 2, 4000)
          WHEN N''NUMBER'' THEN number.Result';
  IF CHARINDEX(@old, @transforms) = 0 OR CHARINDEX(@old, @transforms, CHARINDEX(@old, @transforms) + 1) <> 0
    THROW 52166, N'216: veja NUMBER v map.ApplyValueTransforms ni najdena natanko enkrat.', 1;
  SET @transforms = REPLACE(@transforms, @old, @new);
END;

IF @transforms NOT LIKE N'%/* SwapVoltageFrequency216 */%'
BEGIN
  SET @old = N'IF NOT EXISTS (SELECT 1 FROM #Scope) RETURN;';
  SET @new = N'/* SwapVoltageFrequency216 */
    /* 216: pri Nowodvorskem sta napetost in frekvenca v XML vcasih zamenjani (NW.11710: frekvenca "~220-230", napetost "50/60"). Ce frekvenca nosi stotice (1xx-4xx),
       napetost pa ne in je videti kot 50/60, se par zamenja ze pri zajemu — PIM ne sme nositi
       napacnega podatka. Tece za vse zapise teka, ne le za tiste s pretvorbami. */
    /* Najprej samo vrstice tega teka (iskanje po InboxId prek UQ_ExtractedValue_Trace), sele nato
       primerjava vrednosti: neposreden spoj nad map.ExtractedValue (25 mio vrstic) je trajal 9 s. */
    DECLARE @RunInbox TABLE (InboxId bigint PRIMARY KEY);
    INSERT @RunInbox (InboxId)
    SELECT inbox.InboxId FROM raw.Inbox inbox
    WHERE inbox.RunId = @RunId AND inbox.OrganizationId = @OrganizationId AND inbox.SourceCode = @SourceCode AND inbox.Status = N''Pending'';
    CREATE TABLE #Electric
      (ExtractedValueId bigint NOT NULL PRIMARY KEY, InboxId bigint NOT NULL, RecordOrdinal int NOT NULL,
       TargetFieldCode nvarchar(400) COLLATE DATABASE_DEFAULT NOT NULL, Value nvarchar(max) COLLATE DATABASE_DEFAULT NULL);
    INSERT #Electric (ExtractedValueId, InboxId, RecordOrdinal, TargetFieldCode, Value)
    SELECT extracted.ExtractedValueId, extracted.InboxId, extracted.RecordOrdinal, extracted.TargetFieldCode, extracted.Value
    FROM map.ExtractedValue extracted
    INNER JOIN @RunInbox run ON run.InboxId = extracted.InboxId
    WHERE extracted.TargetFieldCode IN (N''ProductAttribute.Napetost'', N''ProductAttribute.Frekvenca'');
    UPDATE value SET Value = CASE WHEN value.ExtractedValueId = pair.NapetostId THEN pair.Frekvenca ELSE pair.Napetost END
    FROM map.ExtractedValue value
    INNER JOIN
    (
      SELECT napetost.ExtractedValueId AS NapetostId, frekvenca.ExtractedValueId AS FrekvencaId,
             napetost.Value AS Napetost, frekvenca.Value AS Frekvenca
      FROM #Electric napetost
      INNER JOIN #Electric frekvenca
        ON frekvenca.InboxId = napetost.InboxId AND frekvenca.RecordOrdinal = napetost.RecordOrdinal
       AND frekvenca.TargetFieldCode = N''ProductAttribute.Frekvenca''
      WHERE napetost.TargetFieldCode = N''ProductAttribute.Napetost''
        AND frekvenca.Value LIKE N''%[1-4][0-9][0-9]%''
        AND napetost.Value NOT LIKE N''%[1-4][0-9][0-9]%'' AND napetost.Value LIKE N''%[56]0%''
    ) pair ON value.ExtractedValueId IN (pair.NapetostId, pair.FrekvencaId);
    DROP TABLE #Electric;
    IF NOT EXISTS (SELECT 1 FROM #Scope) RETURN;';
  IF CHARINDEX(@old, @transforms) = 0 OR CHARINDEX(@old, @transforms, CHARINDEX(@old, @transforms) + 1) <> 0
    THROW 52167, N'216: stavek RETURN v map.ApplyValueTransforms ni najden natanko enkrat.', 1;
  SET @transforms = REPLACE(@transforms, @old, @new);
END;

IF OBJECT_DEFINITION(OBJECT_ID(N'map.ApplyValueTransforms')) <> @transforms
BEGIN
  SET @transforms = N'ALTER ' + SUBSTRING(@transforms, CHARINDEX(N'PROCEDURE', @transforms), 2147483647);
  EXEC sys.sp_executesql @transforms;
END;

/* ======================================================================================
   6) Preslikave: Braytron napetost/frekvenca, garancija, velike zacetnice
   ====================================================================================== */

/* Seznam dovoljenih pretvorb je omejitev CK_FieldTransform_Code (049); nove kode gredo vanjo. */
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_FieldTransform_Code' AND parent_object_id = OBJECT_ID(N'map.FieldTransform')
           AND definition NOT LIKE N'%CAPITALIZE%')
BEGIN
  ALTER TABLE map.FieldTransform DROP CONSTRAINT CK_FieldTransform_Code;
  ALTER TABLE map.FieldTransform ADD CONSTRAINT CK_FieldTransform_Code CHECK (TransformCode IN
    (N'TRIM', N'NUMBER', N'UNIT', N'PREFIX', N'STRIPPREFIX', N'BOOL', N'UPPER', N'LOWER', N'LOOKUP',
     N'BEFORE', N'AFTER', N'REQUIRE', N'WARRANTY', N'CAPITALIZE'));
END;

/* 6a) Braytron: Napetost = del pred "V" ("220-240V 50/60Hz" -> "220-240", "48VDC" -> "48"). */
INSERT map.FieldTransform (FieldMappingId, StepOrder, TransformCode, Argument, IsActive)
SELECT mapping.FieldMappingId,
       ISNULL((SELECT MAX(step.StepOrder) FROM map.FieldTransform step WHERE step.FieldMappingId = mapping.FieldMappingId), 0) + 1,
       N'BEFORE', N'V', 1
FROM map.FieldMapping mapping
INNER JOIN map.SourceConnector connector ON connector.SourceConnectorId = mapping.SourceConnectorId
WHERE connector.SourceCode = N'BT_XML' AND mapping.SourceElement LIKE N'%slug="voltage"%'
  AND mapping.TargetFieldCode = N'ProductAttribute.Napetost' AND mapping.IsActive = 1
  AND NOT EXISTS (SELECT 1 FROM map.FieldTransform step WHERE step.FieldMappingId = mapping.FieldMappingId AND step.TransformCode = N'BEFORE');

/* 6b) Braytron: Frekvenca iz istega elementa — samo, ce vsebuje "Hz"; del za presledkom, pred "Hz". */
INSERT map.FieldMapping (SourceConnectorId, EntityType, SourceElement, TargetFieldCode, IsRequired, IsActive, MappingVersion, UpdatedBy, UpdatedUtc, IsMultiValue)
SELECT mapping.SourceConnectorId, mapping.EntityType, mapping.SourceElement, N'ProductAttribute.Frekvenca', 0, 1, mapping.MappingVersion,
       N'migracija 216', SYSUTCDATETIME(), 0
FROM map.FieldMapping mapping
INNER JOIN map.SourceConnector connector ON connector.SourceConnectorId = mapping.SourceConnectorId
WHERE connector.SourceCode = N'BT_XML' AND mapping.SourceElement LIKE N'%slug="voltage"%'
  AND mapping.TargetFieldCode = N'ProductAttribute.Napetost' AND mapping.IsActive = 1
  AND NOT EXISTS (SELECT 1 FROM map.FieldMapping other
                  WHERE other.SourceConnectorId = mapping.SourceConnectorId AND other.EntityType = mapping.EntityType
                    AND other.SourceElement = mapping.SourceElement AND other.TargetFieldCode = N'ProductAttribute.Frekvenca');

INSERT map.FieldTransform (FieldMappingId, StepOrder, TransformCode, Argument, IsActive)
SELECT mapping.FieldMappingId, steps.StepOrder, steps.TransformCode, steps.Argument, 1
FROM map.FieldMapping mapping
INNER JOIN map.SourceConnector connector ON connector.SourceConnectorId = mapping.SourceConnectorId
CROSS JOIN (VALUES (1, N'REQUIRE', N'Hz'), (2, N'AFTER', N' '), (3, N'BEFORE', N'Hz')) AS steps (StepOrder, TransformCode, Argument)
WHERE connector.SourceCode = N'BT_XML' AND mapping.SourceElement LIKE N'%slug="voltage"%'
  AND mapping.TargetFieldCode = N'ProductAttribute.Frekvenca'
  AND NOT EXISTS (SELECT 1 FROM map.FieldTransform step WHERE step.FieldMappingId = mapping.FieldMappingId);

/* 6c) Braytron: podvojena preslikava v "Nazivna napetost" se izklopi. */
UPDATE mapping
  SET IsActive = 0, UpdatedBy = N'migracija 216', UpdatedUtc = SYSUTCDATETIME()
FROM map.FieldMapping mapping
INNER JOIN map.SourceConnector connector ON connector.SourceConnectorId = mapping.SourceConnectorId
WHERE connector.SourceCode = N'BT_XML' AND mapping.SourceElement LIKE N'%slug="voltage"%'
  AND mapping.TargetFieldCode = N'ProductAttribute.Nazivna napetost' AND mapping.IsActive = 1;

/* 6d) Garancija: pretvorba WARRANTY na vseh aktivnih preslikavah (SAOP, NW, BT), kot zadnji korak. */
INSERT map.FieldTransform (FieldMappingId, StepOrder, TransformCode, Argument, IsActive)
SELECT mapping.FieldMappingId,
       ISNULL((SELECT MAX(step.StepOrder) FROM map.FieldTransform step WHERE step.FieldMappingId = mapping.FieldMappingId), 0) + 1,
       N'WARRANTY', NULL, 1
FROM map.FieldMapping mapping
WHERE mapping.TargetFieldCode = N'ProductAttribute.Garancija' AND mapping.IsActive = 1
  AND NOT EXISTS (SELECT 1 FROM map.FieldTransform step WHERE step.FieldMappingId = mapping.FieldMappingId AND step.TransformCode = N'WARRANTY');

/* 6e) Velika zacetnica: na vsaki preslikavi v jezikovni stolpec (... SLO / ... ANG), za slovarjem. */
INSERT map.FieldTransform (FieldMappingId, StepOrder, TransformCode, Argument, IsActive)
SELECT mapping.FieldMappingId,
       ISNULL((SELECT MAX(step.StepOrder) FROM map.FieldTransform step WHERE step.FieldMappingId = mapping.FieldMappingId), 0) + 1,
       N'CAPITALIZE', NULL, 1
FROM map.FieldMapping mapping
WHERE (mapping.TargetFieldCode LIKE N'ProductAttribute.% SLO' OR mapping.TargetFieldCode LIKE N'ProductAttribute.% ANG')
  AND mapping.IsActive = 1
  AND NOT EXISTS (SELECT 1 FROM map.FieldTransform step WHERE step.FieldMappingId = mapping.FieldMappingId AND step.TransformCode = N'CAPITALIZE');

/* ======================================================================================
   7) Obstojeci podatki: isto pravilo, kot bo odslej veljalo pri zajemu
   ====================================================================================== */

/* 7a) Slovar prevodov z veliko zacetnico (domene atributov in '*'; SL/DE/HR). */
UPDATE map.ValueLookup
  SET TargetValue = UPPER(LEFT(TargetValue, 1)) + SUBSTRING(TargetValue, 2, 800)
WHERE IsActive = 1 AND Language IN (N'SL', N'DE', N'HR') AND (Domain = N'*' OR Domain LIKE N'% SLO')
  AND NULLIF(TargetValue, N'') IS NOT NULL
  AND LEFT(TargetValue, 1) COLLATE Latin1_General_CS_AS <> UPPER(LEFT(TargetValue, 1)) COLLATE Latin1_General_CS_AS;

/* Zatemnljivo: "Dimmable" ni imel prevoda in je v katalogu ostal anglesko (7 vrstic); par k "Not-Dimmable -> ne". */
IF NOT EXISTS (SELECT 1 FROM map.ValueLookup WHERE Domain = N'Zatemnljivo SLO' AND SourceValue = N'Dimmable' AND Language = N'SL')
  INSERT map.ValueLookup (Domain, SourceValue, Language, TargetValue, Note, IsActive)
  VALUES (N'Zatemnljivo SLO', N'Dimmable', N'SL', N'Da', N'migracija 216', 1);
UPDATE canon.ProductAttribute SET Value = N'Da' WHERE AttributeCode = N'Zatemnljivo' AND LanguageCode = N'sl' AND Value COLLATE Latin1_General_CI_AS = N'dimmable';
UPDATE pim.ProductAttribute SET Value = N'Da' WHERE AttributeCode = N'Zatemnljivo' AND LanguageCode = N'sl' AND Value COLLATE Latin1_General_CI_AS = N'dimmable';

/* 7b) Prevedene vrednosti atributov (vrstice z jezikom) z veliko zacetnico — canon in objava. */
UPDATE canon.ProductAttribute
  SET Value = UPPER(LEFT(Value, 1)) + SUBSTRING(Value, 2, 4000)
WHERE NULLIF(LanguageCode, N'') IS NOT NULL AND NULLIF(Value, N'') IS NOT NULL
  AND LEFT(Value, 1) COLLATE Latin1_General_CS_AS <> UPPER(LEFT(Value, 1)) COLLATE Latin1_General_CS_AS;

UPDATE pim.ProductAttribute
  SET Value = UPPER(LEFT(Value, 1)) + SUBSTRING(Value, 2, 4000)
WHERE NULLIF(LanguageCode, N'') IS NOT NULL AND NULLIF(Value, N'') IS NOT NULL
  AND LEFT(Value, 1) COLLATE Latin1_General_CS_AS <> UPPER(LEFT(Value, 1)) COLLATE Latin1_General_CS_AS;

/* 7c) Garancija v letih. */
UPDATE canon.ProductAttribute SET Value = pim.WarrantySl(Value)
WHERE AttributeCode = N'Garancija' AND pim.WarrantySl(Value) <> Value;
UPDATE pim.ProductAttribute SET Value = pim.WarrantySl(Value)
WHERE AttributeCode = N'Garancija' AND pim.WarrantySl(Value) <> Value;

/* 7d) Nowodvorski: zamenjani par napetost/frekvenca (canon in objava). */
UPDATE attribute
  SET Value = CASE WHEN attribute.AttributeCode = N'Napetost' THEN pair.Frekvenca ELSE pair.Napetost END
FROM canon.ProductAttribute attribute
INNER JOIN
(
  SELECT napetost.ProductId, napetost.Value AS Napetost, frekvenca.Value AS Frekvenca
  FROM canon.ProductAttribute napetost
  INNER JOIN canon.ProductAttribute frekvenca ON frekvenca.ProductId = napetost.ProductId AND frekvenca.AttributeCode = N'Frekvenca'
  WHERE napetost.AttributeCode = N'Napetost'
    AND frekvenca.Value LIKE N'%[1-4][0-9][0-9]%'
    AND napetost.Value NOT LIKE N'%[1-4][0-9][0-9]%' AND napetost.Value LIKE N'%[56]0%'
) pair ON pair.ProductId = attribute.ProductId
WHERE attribute.AttributeCode IN (N'Napetost', N'Frekvenca');

UPDATE attribute
  SET Value = CASE WHEN attribute.AttributeCode = N'Napetost' THEN pair.Frekvenca ELSE pair.Napetost END
FROM pim.ProductAttribute attribute
INNER JOIN
(
  SELECT napetost.PimProductId, napetost.Value AS Napetost, frekvenca.Value AS Frekvenca
  FROM pim.ProductAttribute napetost
  INNER JOIN pim.ProductAttribute frekvenca ON frekvenca.PimProductId = napetost.PimProductId AND frekvenca.AttributeCode = N'Frekvenca'
  WHERE napetost.AttributeCode = N'Napetost'
    AND frekvenca.Value LIKE N'%[1-4][0-9][0-9]%'
    AND napetost.Value NOT LIKE N'%[1-4][0-9][0-9]%' AND napetost.Value LIKE N'%[56]0%'
) pair ON pair.PimProductId = attribute.PimProductId
WHERE attribute.AttributeCode IN (N'Napetost', N'Frekvenca');

/* 7e) Braytron: "220-240V 50/60Hz" -> Frekvenca "50/60" (ce je se ni) in Napetost "220-240". */
INSERT canon.ProductAttribute (ProductId, AttributeCode, Value)
SELECT napetost.ProductId, N'Frekvenca',
       LTRIM(RTRIM(LEFT(SUBSTRING(napetost.Value, CHARINDEX(N' ', napetost.Value) + 1, 400),
                        CHARINDEX(N'Hz', SUBSTRING(napetost.Value, CHARINDEX(N' ', napetost.Value) + 1, 400)) - 1)))
FROM canon.ProductAttribute napetost
WHERE napetost.AttributeCode = N'Napetost' AND napetost.Value LIKE N'%[0-9]V %Hz%'
  AND CHARINDEX(N'Hz', napetost.Value) > CHARINDEX(N' ', napetost.Value)
  AND NOT EXISTS (SELECT 1 FROM canon.ProductAttribute frekvenca
                  WHERE frekvenca.ProductId = napetost.ProductId AND frekvenca.AttributeCode = N'Frekvenca');

INSERT pim.ProductAttribute (PimProductId, AttributeCode, Value)
SELECT napetost.PimProductId, N'Frekvenca',
       LTRIM(RTRIM(LEFT(SUBSTRING(napetost.Value, CHARINDEX(N' ', napetost.Value) + 1, 400),
                        CHARINDEX(N'Hz', SUBSTRING(napetost.Value, CHARINDEX(N' ', napetost.Value) + 1, 400)) - 1)))
FROM pim.ProductAttribute napetost
WHERE napetost.AttributeCode = N'Napetost' AND napetost.Value LIKE N'%[0-9]V %Hz%'
  AND CHARINDEX(N'Hz', napetost.Value) > CHARINDEX(N' ', napetost.Value)
  AND NOT EXISTS (SELECT 1 FROM pim.ProductAttribute frekvenca
                  WHERE frekvenca.PimProductId = napetost.PimProductId AND frekvenca.AttributeCode = N'Frekvenca');

UPDATE canon.ProductAttribute
  SET Value = LTRIM(RTRIM(LEFT(Value, CHARINDEX(N'V', Value) - 1)))
WHERE AttributeCode = N'Napetost' AND Value LIKE N'%[0-9]V%' AND CHARINDEX(N'V', Value) > 1;

UPDATE pim.ProductAttribute
  SET Value = LTRIM(RTRIM(LEFT(Value, CHARINDEX(N'V', Value) - 1)))
WHERE AttributeCode = N'Napetost' AND Value LIKE N'%[0-9]V%' AND CHARINDEX(N'V', Value) > 1;

/* 7f) Braytron: vrstice podvojene preslikave "Nazivna napetost" (vse "…Hz" ali "…VDC") ven. */
DELETE FROM canon.ProductAttribute WHERE AttributeCode = N'Nazivna napetost' AND (Value LIKE N'%Hz%' OR Value LIKE N'%VDC%');
DELETE FROM pim.ProductAttribute WHERE AttributeCode = N'Nazivna napetost' AND (Value LIKE N'%Hz%' OR Value LIKE N'%VDC%');

/* ======================================================================================
   8) Kategorije VID: zrcalo drevesa svetila_si, preslikave dobaviteljev, uvrstitve izdelkov
   ====================================================================================== */

INSERT canon.Category (CategoryTreeCode, CategoryCode, ParentCategoryCode, LevelNo, CategoryName, CategoryPath, IsActive)
SELECT N'videlektro', source.CategoryCode, source.ParentCategoryCode, source.LevelNo, source.CategoryName, source.CategoryPath, source.IsActive
FROM canon.Category source
WHERE source.CategoryTreeCode = N'svetila_si'
  AND NOT EXISTS (SELECT 1 FROM canon.Category target WHERE target.CategoryTreeCode = N'videlektro' AND target.CategoryCode = source.CategoryCode);

INSERT canon.CategoryTranslation (CategoryTreeCode, CategoryCode, LanguageCode, CategoryName)
SELECT N'videlektro', source.CategoryCode, source.LanguageCode, source.CategoryName
FROM canon.CategoryTranslation source
WHERE source.CategoryTreeCode = N'svetila_si'
  AND EXISTS (SELECT 1 FROM canon.Category node WHERE node.CategoryTreeCode = N'videlektro' AND node.CategoryCode = source.CategoryCode)
  AND NOT EXISTS (SELECT 1 FROM canon.CategoryTranslation target
                  WHERE target.CategoryTreeCode = N'videlektro' AND target.CategoryCode = source.CategoryCode AND target.LanguageCode = source.LanguageCode);

INSERT map.CategoryPathMap (SourceCode, CategoryTreeCode, SourcePathKey, CategoryCode, IsActive, UpdatedUtc, UpdatedBy, Note)
SELECT source.SourceCode, N'videlektro', source.SourcePathKey, source.CategoryCode, source.IsActive, SYSUTCDATETIME(), N'migracija 216', N'zrcalo svetila_si (216)'
FROM map.CategoryPathMap source
WHERE source.CategoryTreeCode = N'svetila_si'
  AND NOT EXISTS (SELECT 1 FROM map.CategoryPathMap target
                  WHERE target.SourceCode = source.SourceCode AND target.CategoryTreeCode = N'videlektro' AND target.SourcePathKey = source.SourcePathKey);

/* Uvrstitve: svetila_si -> B2C, svetila_si_en -> B2C_EN (par po drevesu in jeziku iz canon.WebSite). */
INSERT canon.ProductCategory (ProductId, WebSite, CategoryPath)
SELECT source.ProductId, vid.WebSiteCode, source.CategoryPath
FROM canon.ProductCategory source
INNER JOIN canon.WebSite svetila ON svetila.WebSiteCode = source.WebSite AND svetila.CategoryTreeCode = N'svetila_si' AND svetila.IsActive = 1
INNER JOIN canon.WebSite vid ON vid.CategoryTreeCode = N'videlektro' AND vid.LanguageCode = svetila.LanguageCode AND vid.IsActive = 1
WHERE NOT EXISTS (SELECT 1 FROM canon.ProductCategory target
                  WHERE target.ProductId = source.ProductId AND target.WebSite = vid.WebSiteCode AND target.CategoryPath = source.CategoryPath)
  AND NOT EXISTS (SELECT 1 FROM pim.ProductCategoryOverride override
                  WHERE override.ProductId = source.ProductId AND override.WebSite = vid.WebSiteCode);

INSERT pim.ProductCategory (PimProductId, WebSite, CategoryPath)
SELECT source.PimProductId, vid.WebSiteCode, source.CategoryPath
FROM pim.ProductCategory source
INNER JOIN pim.Product pimProduct ON pimProduct.PimProductId = source.PimProductId
INNER JOIN canon.WebSite svetila ON svetila.WebSiteCode = source.WebSite AND svetila.CategoryTreeCode = N'svetila_si' AND svetila.IsActive = 1
INNER JOIN canon.WebSite vid ON vid.CategoryTreeCode = N'videlektro' AND vid.LanguageCode = svetila.LanguageCode AND vid.IsActive = 1
LEFT JOIN canon.Product canonProduct ON canonProduct.OrganizationId = pimProduct.OrganizationId AND canonProduct.ItemID = pimProduct.ItemID
WHERE NOT EXISTS (SELECT 1 FROM pim.ProductCategory target
                  WHERE target.PimProductId = source.PimProductId AND target.WebSite = vid.WebSiteCode AND target.CategoryPath = source.CategoryPath)
  AND NOT EXISTS (SELECT 1 FROM pim.ProductCategoryOverride override
                  WHERE override.ProductId = canonProduct.ProductId AND override.WebSite = vid.WebSiteCode);

/* ======================================================================================
   9) Dokaz
   ====================================================================================== */

IF (SELECT COUNT(*) FROM out.ExportColumn WHERE ExportProfileId = @ProfileId AND IsActive = 1) <> 176
  THROW 52168, N'216: profil MAGENTO_PRODUCTS nima pricakovanih 176 aktivnih stolpcev.', 1;
IF EXISTS (SELECT 1 FROM out.ExportColumn WHERE ExportProfileId = @ProfileId AND IsActive = 1
           AND (OutputColumnName LIKE N'Enota %' OR OutputColumnName = N'Komentarji'))
  THROW 52169, N'216: stolpec Enota/Komentarji je se aktiven.', 1;
IF EXISTS (SELECT SortOrder FROM out.ExportColumn WHERE ExportProfileId = @ProfileId AND IsActive = 1 GROUP BY SortOrder HAVING COUNT(*) > 1)
   OR (SELECT MAX(SortOrder) FROM out.ExportColumn WHERE ExportProfileId = @ProfileId AND IsActive = 1) <> 176
  THROW 52170, N'216: SortOrder aktivnih stolpcev ni zvezen 1..176.', 1;
IF EXISTS (SELECT 1 FROM out.ExportColumn WHERE ExportProfileId = @ProfileId AND IsActive = 1 GROUP BY OutputColumnName HAVING COUNT(*) > 1)
  THROW 52171, N'216: katalog ima podvojene glave.', 1;
IF EXISTS (SELECT 1 FROM out.CatalogUnitRule unitRule
           WHERE unitRule.IsActive = 1 AND NOT EXISTS (SELECT 1 FROM out.ExportColumn c
             WHERE c.ExportProfileId = @ProfileId AND c.IsActive = 1 AND c.CanonicalFieldCode = unitRule.ValueFieldCode
               AND c.OutputColumnName LIKE N'% [[]' + unitRule.TargetUnit + N']'))
  THROW 52172, N'216: stolpec z enoto nima enote v glavi.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows')) NOT LIKE N'%/* Catalog216 */%'
  THROW 52173, N'216: out.GetExportRows nima bloka Catalog216.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'map.ApplyValueTransforms')) NOT LIKE N'%/* Transforms216 */%'
   OR OBJECT_DEFINITION(OBJECT_ID(N'map.ApplyValueTransforms')) NOT LIKE N'%/* SwapVoltageFrequency216 */%'
  THROW 52174, N'216: map.ApplyValueTransforms nima novih pretvorb.', 1;

EXEC(N'
IF pim.WarrantySl(N''5 years'') <> N''5 let'' OR pim.WarrantySl(N''3 Years'') <> N''3 leta'' OR pim.WarrantySl(N''2'') <> N''2 leti''
   OR pim.WarrantySl(N''1 leto'') <> N''1 leto'' OR pim.WarrantySl(N''4 leta'') <> N''4 leta''
   OR pim.WarrantySl(N''LED svetilka, stropna'') <> N''LED svetilka, stropna'' OR pim.WarrantySl(N''24 months'') <> N''24 months''
  THROW 52175, N''216: pim.WarrantySl ne sklanja pravilno.'', 1;
IF out.UnitFactor(N''cm'', N''mm'') <> 10 OR out.UnitFactor(N''m'', N''mm'') <> 1000 OR out.UnitFactor(N''kgs'', N''kg'') <> 1
   OR out.UnitFactor(N''gr'', N''kg'') <> 0.001 OR out.UnitFactor(N''⁰'', N''°'') <> 1 OR out.UnitFactor(N''Hz'', N''Hz'') <> 1
   OR out.UnitFactor(N''x'', N''mm'') IS NOT NULL OR out.UnitFactor(N''kg'', N''mm'') IS NOT NULL
  THROW 52176, N''216: out.UnitFactor ne racuna pravilno.'', 1;
IF EXISTS (SELECT 1 FROM map.ValueLookup WHERE IsActive = 1 AND Language = N''SL'' AND (Domain = N''*'' OR Domain LIKE N''% SLO'')
           AND NULLIF(TargetValue, N'''') IS NOT NULL
           AND LEFT(TargetValue, 1) COLLATE Latin1_General_CS_AS <> UPPER(LEFT(TargetValue, 1)) COLLATE Latin1_General_CS_AS)
  THROW 52177, N''216: slovar prevodov ima se vrednost z malo zacetnico.'', 1;
IF EXISTS (SELECT 1 FROM canon.ProductAttribute WHERE AttributeCode = N''Nazivna napetost'' AND Value LIKE N''%Hz%'')
  THROW 52178, N''216: podvojena Braytronova nazivna napetost je se v katalogu.'', 1;
IF EXISTS (SELECT 1 FROM canon.ProductAttribute WHERE AttributeCode = N''Napetost'' AND Value LIKE N''%Hz%'')
  THROW 52179, N''216: napetost se nosi frekvenco.'', 1;
IF NOT EXISTS (SELECT 1 FROM map.FieldMapping mapping INNER JOIN map.SourceConnector connector ON connector.SourceConnectorId = mapping.SourceConnectorId
               WHERE connector.SourceCode = N''BT_XML'' AND mapping.TargetFieldCode = N''ProductAttribute.Frekvenca'' AND mapping.IsActive = 1)
  THROW 52180, N''216: Braytron nima preslikave v Frekvenca.'', 1;
IF (SELECT COUNT(*) FROM canon.Category WHERE CategoryTreeCode = N''videlektro'')
   < (SELECT COUNT(*) FROM canon.Category WHERE CategoryTreeCode = N''svetila_si'')
  THROW 52181, N''216: drevo videlektro ni prevzelo kategorij svetil.'', 1;
IF EXISTS (SELECT 1 FROM map.CategoryPathMap svetila
           WHERE svetila.CategoryTreeCode = N''svetila_si''
             AND NOT EXISTS (SELECT 1 FROM map.CategoryPathMap vid WHERE vid.SourceCode = svetila.SourceCode
                             AND vid.CategoryTreeCode = N''videlektro'' AND vid.SourcePathKey = svetila.SourcePathKey))
  THROW 52182, N''216: preslikava dobavitelja na svetila_si nima para na videlektro.'', 1;
IF EXISTS (SELECT 1 FROM canon.ProductCategory svetila
           INNER JOIN canon.WebSite site ON site.WebSiteCode = svetila.WebSite AND site.CategoryTreeCode = N''svetila_si''
           WHERE NOT EXISTS (SELECT 1 FROM canon.ProductCategory vid INNER JOIN canon.WebSite vidSite ON vidSite.WebSiteCode = vid.WebSite
                             WHERE vid.ProductId = svetila.ProductId AND vidSite.CategoryTreeCode = N''videlektro''
                               AND vidSite.LanguageCode = site.LanguageCode AND vid.CategoryPath = svetila.CategoryPath)
             AND NOT EXISTS (SELECT 1 FROM pim.ProductCategoryOverride override WHERE override.ProductId = svetila.ProductId))
  THROW 52183, N''216: izdelek s kategorijo svetila_si nima iste kategorije na videlektro.'', 1;
');
