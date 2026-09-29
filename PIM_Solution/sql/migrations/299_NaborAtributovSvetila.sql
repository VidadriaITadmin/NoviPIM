/*
  299 — nabor atributov za svetila (svetila.si in videlektro razsvetljava).

  Uporabnik 2026-09-28 je poslal seznam atributov, ki veljajo za vse kategorije na svetila.si
  in za razsvetljavo na videlektro. Migracija:

    1. Ustvari atribute, ki jih v registru se ni (Barva svetlobe, Pametno upravljanje,
       Povezljivost, Vrsta senzorja) prek canon.CreateAttributeDefinition.

    2. Pri vseh ostalih uporabi OBSTOJECI atribut, ker izdelki vrednosti hranijo po
       slovenskem imenu atributa (canon.ProductAttribute.AttributeCode = ime). Nov atribut
       "Barva" bi bil pri vseh izdelkih prazen, "Prevladujoca barva" pa ima ~15.000 vrednosti.
       Ime s seznama in zelja za spletni filter (drsnik) sta zapisana v opombi vrstice nabora.

    3. Atribute doda v nabor korenskih kategorij obeh dreves kot RECOMMENDED (opozorilo pri
       validaciji, ne blokira spleta) prek canon.SaveCategoryAttributeSet, ki vzdrzuje zahteve
       validacije in pise b2b.AuditLog. Podkategorije nabor podedujejo.
       Vrstice, ki na isti kategoriji ze obstajajo (tudi EXCLUDED ali REQUIRED), ostanejo
       nespremenjene; migracija samo dodaja.

  Ponovljiva: drugi zagon ne naredi nicesar.
  Povratek: canon.SaveCategoryAttributeSet z @Level = NULL za vrstice z UpdatedBy = 'migracija 298'.
*/

SET XACT_ABORT ON;
SET NOCOUNT ON;

DECLARE @Actor nvarchar(200) = N'migracija 298';
DECLARE @CreatedCode nvarchar(200);

/* --- 1) Novi atributi ----------------------------------------------------------------------- */

IF NOT EXISTS (SELECT 1 FROM canon.AttributeTranslation WHERE LanguageCode = N'sl' AND Name = N'Barva svetlobe')
   AND NOT EXISTS (SELECT 1 FROM canon.AttributeDefinition WHERE AttributeCode = N'BARVA_SVETLOBE')
  EXEC canon.CreateAttributeDefinition @Name = N'Barva svetlobe', @AttributeCode = N'BARVA_SVETLOBE', @DataType = N'ENUM',
    @IsTranslatable = 1,
    @Note = N'Z imenom, ne s kelvini: topla, dnevna, hladna. CCT (nastavljiva) = vse tri. Kelvini so v atributu Temperatura barve.',
    @TranslationsJson = N'[{"lang":"en","name":"Light colour"},{"lang":"de","name":"Lichtfarbe"},{"lang":"hr","name":"Boja svjetla"},{"lang":"it","name":"Colore della luce"}]',
    @Actor = @Actor, @CreatedCode = @CreatedCode OUTPUT;

IF NOT EXISTS (SELECT 1 FROM canon.AttributeTranslation WHERE LanguageCode = N'sl' AND Name = N'Pametno upravljanje')
   AND NOT EXISTS (SELECT 1 FROM canon.AttributeDefinition WHERE AttributeCode = N'PAMETNO_UPRAVLJANJE')
  EXEC canon.CreateAttributeDefinition @Name = N'Pametno upravljanje', @AttributeCode = N'PAMETNO_UPRAVLJANJE', @DataType = N'ENUM',
    @IsTranslatable = 1,
    @Note = N'Wi-Fi, daljinec, aplikacija. Brez vrednosti on/off (kupcu nic ne pove).',
    @TranslationsJson = N'[{"lang":"en","name":"Smart control"},{"lang":"de","name":"Smarte Steuerung"},{"lang":"hr","name":"Pametno upravljanje"},{"lang":"it","name":"Controllo smart"}]',
    @Actor = @Actor, @CreatedCode = @CreatedCode OUTPUT;

IF NOT EXISTS (SELECT 1 FROM canon.AttributeTranslation WHERE LanguageCode = N'sl' AND Name = N'Povezljivost')
   AND NOT EXISTS (SELECT 1 FROM canon.AttributeDefinition WHERE AttributeCode = N'POVEZLJIVOST')
  EXEC canon.CreateAttributeDefinition @Name = N'Povezljivost', @AttributeCode = N'POVEZLJIVOST', @DataType = N'ENUM',
    @IsTranslatable = 0,
    @Note = N'Wi-Fi, Bluetooth, Zigbee, Matter ...',
    @TranslationsJson = N'[{"lang":"en","name":"Connectivity"},{"lang":"de","name":"Konnektivität"},{"lang":"hr","name":"Povezivost"},{"lang":"it","name":"Connettività"}]',
    @Actor = @Actor, @CreatedCode = @CreatedCode OUTPUT;

IF NOT EXISTS (SELECT 1 FROM canon.AttributeTranslation WHERE LanguageCode = N'sl' AND Name = N'Vrsta senzorja')
   AND NOT EXISTS (SELECT 1 FROM canon.AttributeDefinition WHERE AttributeCode = N'VRSTA_SENZORJA')
  EXEC canon.CreateAttributeDefinition @Name = N'Vrsta senzorja', @AttributeCode = N'VRSTA_SENZORJA', @DataType = N'ENUM',
    @IsTranslatable = 1,
    @Note = N'Npr. PIR (infrardeci), mikrovalovni, somracni.',
    @TranslationsJson = N'[{"lang":"en","name":"Sensor type"},{"lang":"de","name":"Sensortyp"},{"lang":"hr","name":"Vrsta senzora"},{"lang":"it","name":"Tipo di sensore"}]',
    @Actor = @Actor, @CreatedCode = @CreatedCode OUTPUT;

/* --- 2) Seznam: ime s seznama uporabnika -> atribut v registru --------------------------------- */

DECLARE @Seznam TABLE
(
  SortOrder int NOT NULL PRIMARY KEY,
  ImeNaSeznamu nvarchar(100) NOT NULL,
  AttributeCode nvarchar(200) NOT NULL,
  Opomba nvarchar(200) NULL
);

INSERT @Seznam (SortOrder, ImeNaSeznamu, AttributeCode, Opomba) VALUES
  ( 10, N'Prostor',                 N'UPORABA', NULL),
  ( 20, N'Stil',                    N'SLOG', NULL),
  ( 30, N'Barva',                   N'PREVLADUJOCA_BARVA', NULL),
  ( 40, N'Material',                N'PREVLADUJOC_MATERIAL', NULL),
  ( 50, N'Družina',                 N'DRUZINA', NULL),
  ( 60, N'Svetlobni vir',           N'VRSTA_SVETLOBNEGA_VIRA', N'integrirana LED / zamenljiva žarnica'),
  ( 70, N'Zatemnitev',              N'ZATEMNLJIVO', N'Da / Ne; svetila na grlo (ne LED) = Da, z opozorilom o zatemnitveni žarnici in stikalu'),
  ( 80, N'Barva svetlobe',          N'BARVA_SVETLOBE', N'topla / dnevna / hladna; CCT = vse tri'),
  ( 90, N'Pametno upravljanje',     N'PAMETNO_UPRAVLJANJE', N'wi-fi, daljinec, aplikacija; brez on/off'),
  (100, N'Povezljivost',            N'POVEZLJIVOST', N'wi-fi, bluetooth, zigbee, matter'),
  (110, N'IP zaščita',              N'IP_STOPNJA_ZASCITE', N'filter: drsnik'),
  (120, N'Moč',                     N'NAZIVNA_MOC', N'filter: drsnik'),
  (130, N'Grlo',                    N'GRLO', NULL),
  (140, N'Oblika',                  N'OBLIKA', NULL),
  (150, N'Senzor',                  N'SENZOR_GIBANJA', NULL),
  (160, N'Način montaže',           N'NACIN_MONTAZE', NULL),
  (170, N'Temperatura svetlobe',    N'TEMPERATURA_BARVE', N'v kelvinih'),
  (180, N'Material komplementarni', N'DOPOLNILNI_MATERIAL_I', NULL),
  (190, N'Barva komplementarna',    N'DOPOLNILNA_BARVA_I', NULL),
  (200, N'Domet',                   N'RAZDALJA_DETEKCIJE', N'senzor'),
  (210, N'Kot zaznavanja',          N'KOT_DETEKCIJE', N'senzor'),
  (220, N'Čas delovanja',           N'CASOVNA_ZAKASNITEV', N'senzor'),
  (230, N'Svetlobna občutljivost',  N'LUKS', N'senzor'),
  (240, N'Vrsta senzorja',          N'VRSTA_SENZORJA', N'senzor'),
  (250, N'Kot svetenja',            N'KOT_SVETLOBNEGA_SNOPA', NULL),
  (260, N'Število sijalk',          N'STEVILO_SVETLOBNIH_VIROV', NULL),
  (270, N'Vključuje sijalko',       N'SVETILKA_VKLJUCUJE_SVETLOBNI_VIR', NULL),
  (280, N'Max moč sijalke',         N'MAX_MOC_SIJALKE', NULL),
  (290, N'Vključuje napajalnik',    N'VKLJUCUJE_NAPAJALNIK', NULL),
  (300, N'Tip napajalnika',         N'TIP_NAPAJALNIKA', NULL),
  (310, N'Svetlobni tok',           N'SVETLOBNI_TOK', N'v lumnih; filter: drsnik ali od-do'),
  (320, N'Vhodna napetost',         N'NAPETOST', NULL),
  (330, N'Frekvence',               N'FREKVENCA', NULL),
  (340, N'CRI',                     N'INDEKS_BARVNEGA_VIDEZA_CRI', NULL),
  (350, N'Življenjska doba',        N'ZIVLJENJSKA_DOBA', NULL),
  (360, N'Garancija',               N'GARANCIJA', NULL),
  (370, N'Vidna dimenzija',         N'DOLZINA', N'vidna dimenzija; filter: drsnik'),
  (371, N'Vidna dimenzija',         N'SIRINA', N'vidna dimenzija; filter: drsnik'),
  (372, N'Vidna dimenzija',         N'VISINA', N'vidna dimenzija; filter: drsnik'),
  (373, N'Vidna dimenzija',         N'PREMER', N'vidna dimenzija; filter: drsnik'),
  (380, N'Vgradna dimenzija',       N'IZVRTINA_CUTOUT', N'filter: drsnik?'),
  (390, N'Energijski razred',       N'ENERGIJSKI_RAZRED', NULL);

DECLARE @Manjka nvarchar(max) =
  (SELECT STRING_AGG(seznam.AttributeCode, N', ') FROM @Seznam seznam
   WHERE NOT EXISTS (SELECT 1 FROM canon.AttributeDefinition d WHERE d.AttributeCode = seznam.AttributeCode));
IF @Manjka IS NOT NULL
BEGIN
  DECLARE @ManjkaMessage nvarchar(max) = CONCAT(N'299: v registru manjkajo atributi: ', @Manjka);
  THROW 52980, @ManjkaMessage, 1;
END;

/* Neaktiven atribut s seznama se vklopi (SaveCategoryAttributeSet sprejme samo aktivne). */
UPDATE d SET IsActive = 1, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = @Actor
FROM canon.AttributeDefinition d
WHERE d.IsActive = 0 AND d.AttributeCode IN (SELECT AttributeCode FROM @Seznam);

/* --- 3) Korenske kategorije svetil ---------------------------------------------------------- */

DECLARE @Kategorije TABLE (CategoryTreeCode nvarchar(50) NOT NULL, CategoryCode nvarchar(200) NOT NULL,
  PRIMARY KEY (CategoryTreeCode, CategoryCode));

/* svetila.si: vse korenske kategorije drevesa. */
INSERT @Kategorije (CategoryTreeCode, CategoryCode)
SELECT CategoryTreeCode, CategoryCode FROM canon.Category
WHERE CategoryTreeCode = N'svetila_si' AND ParentCategoryCode IS NULL;

/* videlektro: razsvetljava in korenski tracni sistemi, ki so v drevesu loceni. */
INSERT @Kategorije (CategoryTreeCode, CategoryCode)
SELECT CategoryTreeCode, CategoryCode FROM canon.Category
WHERE CategoryTreeCode = N'videlektro' AND ParentCategoryCode IS NULL
  AND (CategoryCode = N'razsvetljava' OR CategoryCode LIKE N'razsvetljava[_][_][_]%');

/* --- 4) Vpis v nabor ------------------------------------------------------------------------ */

DECLARE @Tree nvarchar(50), @Category nvarchar(200), @Attr nvarchar(200), @Note nvarchar(400);

DECLARE vpis CURSOR LOCAL FAST_FORWARD FOR
  SELECT kategorija.CategoryTreeCode, kategorija.CategoryCode, seznam.AttributeCode,
    LEFT(CONCAT(N'Svetila 2026-09-28: ', seznam.ImeNaSeznamu, CASE WHEN seznam.Opomba IS NULL THEN N'' ELSE CONCAT(N' (', seznam.Opomba, N')') END), 400)
  FROM @Kategorije kategorija
  CROSS JOIN @Seznam seznam
  WHERE NOT EXISTS (SELECT 1 FROM canon.CategoryAttributeSet obstojeca
                    WHERE obstojeca.CategoryTreeCode = kategorija.CategoryTreeCode
                      AND obstojeca.CategoryCode = kategorija.CategoryCode
                      AND obstojeca.AttributeCode = seznam.AttributeCode)
  ORDER BY kategorija.CategoryTreeCode, kategorija.CategoryCode, seznam.SortOrder;

OPEN vpis;
FETCH NEXT FROM vpis INTO @Tree, @Category, @Attr, @Note;
WHILE @@FETCH_STATUS = 0
BEGIN
  EXEC canon.SaveCategoryAttributeSet @CategoryTreeCode = @Tree, @CategoryCode = @Category,
    @AttributeCode = @Attr, @Level = N'RECOMMENDED', @Actor = @Actor, @Note = @Note;
  FETCH NEXT FROM vpis INTO @Tree, @Category, @Attr, @Note;
END;
CLOSE vpis;
DEALLOCATE vpis;

/* Vrstni red na kartici in v izvozu sledi seznamu uporabnika. */
UPDATE s SET SortOrder = seznam.SortOrder
FROM canon.CategoryAttributeSet s
INNER JOIN @Kategorije kategorija ON kategorija.CategoryTreeCode = s.CategoryTreeCode AND kategorija.CategoryCode = s.CategoryCode
INNER JOIN @Seznam seznam ON seznam.AttributeCode = s.AttributeCode
WHERE s.UpdatedBy = @Actor AND s.SortOrder <> seznam.SortOrder;
