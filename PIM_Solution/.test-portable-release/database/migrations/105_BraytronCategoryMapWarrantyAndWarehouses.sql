/*
  105 — tri odlocitve uporabnika, zapisane kot podatek: Braytronove kategorije, garancija kot
        zahteva profila in skladisce za zalogo iz SAOP.

  Vir vseh treh: uporabnikovi datoteki "brayxtron_kategorije.xlsx" in
  "Kartica artikla - podatki in pravila.xlsx" (2026-08-27). Nic od tega ni sklep programa.

  --- 1) Braytronove kategorije ------------------------------------------------------------

  BT_XML je imel do te migracije NIC vrstic v map.CategoryPathMap, medtem ko je zajem sam
  prepoznal 78 izvornih kategorij (1.086 izdelkov) in jih pustil v map.SourceCategory. Zato je
  map.ResolveProductCategories za ta vir tekel in ni naredil nicesar — niti vrstice v katalogu
  niti vrstice v delovnem seznamu. Vseh 411 Braytronovih izdelkov org 2 je bilo INVALID na
  ProductCategory.CategoryPath.

  Ta migracija zapise 25 preslikav, za katere velja OBOJE: uporabnik jih je v Excelu poimenoval
  IN cilj ze obstaja v drevesu svetila_si. Pokrivajo 309 izdelkov.

  Kar ta migracija NAMENOMA ne zapise:

    26 kategorij (465 izdelkov) — uporabnik je cilj poimenoval, kategorije pa v nasem drevesu
                                  ni: "LED paneli" (imamo "LED panel"), "Spotlight",
                                  "Solarna svetila", "LED trakovi", "Zasilne svetilke",
                                  "Prahotesne svetilke", "Highbay" (imamo "Hibay").
                                  Preslikava na neobstojeco kategorijo bi bila tiha laz.
     7 kategorij (148 izdelkov) — cilj je odvisen od TIPA izdelka, ne od druzine. Braytronov XML
                                  ima atribut "type" (2.726 pojavitev), ki ga za BT_XML ne
                                  beremo; map.SourceCategory in SourcePathKey tretji nivo ze
                                  podpirata (091). To je locena odlocitev.
    15 kategorij (126 izdelkov) — uporabnik jih je izkljucil ("NE BOMO IMELI", "ZAENKRAT
                                  NIMAMO", "TA GRUPA NE GRE NA SVETILA.SI").
     5 kategorij  (38 izdelkov) — so v bazi, v Excelu jih ni.

  Sijalke (113 izdelkov) niso in ne morejo biti tu: uporabnikovo pravilo je "vedno gledas GRLO",
  torej kategorija po atributu socket in ne po poti dobavitelja. To je drug mehanizem.

  --- 2) Garancija kot zahteva -------------------------------------------------------------

  Uporabnikov list "Pravila" nasteje pet veljavnih pravil validacije; sistem je imel stiri.
  Peto — "obvezen atribut garancija" — ni bilo zapisano nikjer, ceprav atribut Garancija v
  canon.ProductAttribute obstaja na 1.725 izdelkih.

  Zapisana je kot WARNING in ne kot ERROR. Razlog je izmerjen, ne previden: od 2.090 izdelkov
  org 2, ki so danes VALID po WEB_svetila_si, jih ima garancijo 77. Kot ERROR bi ta zahteva
  razveljavila 2.013 od 2.090 veljavnih izdelkov — se pravi skoraj cel spletni nabor — in to
  ne zato, ker bi bili izdelki slabsi, ampak ker podatka se nismo zajeli.

  Kot WARNING je pomanjkljivost vidna v val.ProductIssue in v delovnem seznamu urednika, profila
  pa ne postavi na INVALID (glej 047). Ko bo pokritost dovolj velika, je prehod na ERROR en
  UPDATE nad val.FieldRequirement.Severity in nobena sprememba programa.

  --- 3) Skladisce za zalogo iz SAOP -------------------------------------------------------

  stock.SaopProviderProfile je imel WarehouseSelectionMode = ActiveFromRegister in prazen
  WarehouseIdsJson. Za org 2 to pomeni zahtevo cez vseh 35 aktivnih skladisc, za org 3 cez 70.
  Uporabnikov list "Skladisca" pove drugace: "To zaenkrat ne, samo glavno".

  Zato org 2 in org 3 dobita nacin List in eno samo sifro 0000001 (obe preverjeni v
  canon.Warehouse, obe aktivni). Org 1 in 4 v listu nista in ostaneta nespremenjena.

  Migracija ne izvede nobenega klica navzven. Prvi ziv klic za zalogo je po AGENTS.md §4.5
  odlocitev cloveka.
*/

SET XACT_ABORT ON;

/* --- 1) Braytronove kategorije ---------------------------------------------------------- */

EXEC(N'
DECLARE @Preslikave TABLE
(
  SourceCode       nvarchar(100)  NOT NULL,
  CategoryTreeCode nvarchar(100)  NOT NULL,
  SourcePathKey    nvarchar(2000) NOT NULL,
  CategoryCode     nvarchar(400)  NOT NULL,
  IsActive         bit            NOT NULL
);

INSERT @Preslikave (SourceCode, CategoryTreeCode, SourcePathKey, CategoryCode, IsActive)
VALUES
  (N''BT_XML'', N''svetila_si'', N''decorative_led___ceiling_light_bella'',    N''notranja_svetila___stropna_svetila___plafonjere'', 1),
  (N''BT_XML'', N''svetila_si'', N''decorative_led___ceiling_light_blade'',    N''notranja_svetila___stropna_svetila___plafonjere'', 1),
  (N''BT_XML'', N''svetila_si'', N''decorative_led___ceiling_light_jade'',     N''notranja_svetila___stropna_svetila___plafonjere'', 1),
  (N''BT_XML'', N''svetila_si'', N''decorative_led___ceiling_light_nela'',     N''notranja_svetila___stropna_svetila___nadgradne_svetilke'', 1),
  (N''BT_XML'', N''svetila_si'', N''decorative_led___led_desk_lamp'',          N''notranja_svetila___namizna_svetila'', 1),
  (N''BT_XML'', N''svetila_si'', N''decorative_led___led_wall_light'',         N''notranja_svetila___stenska_svetila___ostala_svetila'', 1),
  (N''BT_XML'', N''svetila_si'', N''decorative_led___linear_light_lina'',      N''notranja_svetila___viseca_svetila'', 1),
  (N''BT_XML'', N''svetila_si'', N''decorative_led___pendant_light_bella'',    N''notranja_svetila___viseca_svetila'', 1),
  (N''BT_XML'', N''svetila_si'', N''decorative_led___pendant_light_blade'',    N''notranja_svetila___viseca_svetila'', 1),
  (N''BT_XML'', N''svetila_si'', N''decorative_led___pendant_light_lina'',     N''notranja_svetila___viseca_svetila'', 1),
  (N''BT_XML'', N''svetila_si'', N''decorative_led___pendant_light_nela'',     N''notranja_svetila___viseca_svetila'', 1),
  (N''BT_XML'', N''svetila_si'', N''indoor_lighting___accessories'',           N''notranja_svetila___dodatki'', 1),
  (N''BT_XML'', N''svetila_si'', N''indoor_lighting___ceiling_light'',         N''notranja_svetila___stropna_svetila___plafonjere'', 1),
  (N''BT_XML'', N''svetila_si'', N''indoor_lighting___gu10_pendant_spotlight'', N''notranja_svetila___viseca_svetila'', 1),
  (N''BT_XML'', N''svetila_si'', N''indoor_lighting___gu10_surface_spotlight'', N''notranja_svetila___reflektorska_svetila'', 1),
  (N''BT_XML'', N''svetila_si'', N''indoor_lighting___led_batten_light'',      N''notranja_svetila___stropna_svetila___linijska_svetila'', 1),
  (N''BT_XML'', N''svetila_si'', N''indoor_lighting___sensor_fixtures'',       N''notranja_svetila___stropna_svetila___nadgradne_svetilke'', 1),
  (N''BT_XML'', N''svetila_si'', N''outdoor_lighting___ceiling_light'',        N''zunanja_svetila___stropna_svetila___plafonjere'', 1),
  (N''BT_XML'', N''svetila_si'', N''outdoor_lighting___e27_bollard'',          N''zunanja_svetila___talna_svetila'', 1),
  (N''BT_XML'', N''svetila_si'', N''outdoor_lighting___led_bollard'',          N''zunanja_svetila___talna_svetila'', 1),
  (N''BT_XML'', N''svetila_si'', N''outdoor_lighting___led_bulkhead'',         N''zunanja_svetila___stenska_svetila___bulkhead'', 1),
  (N''BT_XML'', N''svetila_si'', N''outdoor_lighting___led_floodlight'',       N''zunanja_svetila___led_reflektorji'', 1),
  (N''BT_XML'', N''svetila_si'', N''outdoor_lighting___spike_light'',          N''zunanja_svetila___talna_svetila'', 1),
  /* Ta dva ciljata na nivo 1, ker uporabnik podkategorije ni dolocil. Zadostita zahtevi
     ProductCategory.CategoryPath, nista pa koncna uvrstitev. */
  (N''BT_XML'', N''svetila_si'', N''indoor_lighting___ceiling_fan'',           N''notranja_svetila'', 1),
  (N''BT_XML'', N''svetila_si'', N''rechargeables___led_rechargeable'',        N''notranja_svetila'', 1);

/*
  Preslikava na kategorijo, ki je v drevesu ni, bi bila tiha laz: map.ResolveProductCategories
  bi jo nasel v slovarju in nato tiho izpustil pri spoju s canon.Category. Zato se vsaka vrstica
  preveri in migracija pade, ce cilj ne obstaja.
*/
DECLARE @Manjka nvarchar(4000) = NULL;
SELECT @Manjka = STRING_AGG(p.CategoryCode, N'', '')
FROM @Preslikave p
WHERE NOT EXISTS
(
  SELECT 1 FROM canon.Category kategorija
  WHERE kategorija.CategoryTreeCode = p.CategoryTreeCode AND kategorija.CategoryCode = p.CategoryCode
);
IF @Manjka IS NOT NULL
  THROW 105001, N''Migracija 105: ciljne kategorije ne obstajajo v canon.Category.'', 1;

MERGE map.CategoryPathMap AS target
USING @Preslikave AS source
  ON target.SourceCode = source.SourceCode
 AND target.CategoryTreeCode = source.CategoryTreeCode
 AND target.SourcePathKey = source.SourcePathKey
WHEN MATCHED THEN UPDATE SET CategoryCode = source.CategoryCode, IsActive = source.IsActive
WHEN NOT MATCHED THEN INSERT (SourceCode, CategoryTreeCode, SourcePathKey, CategoryCode, IsActive)
  VALUES (source.SourceCode, source.CategoryTreeCode, source.SourcePathKey, source.CategoryCode, source.IsActive);
');

/* --- 2) Garancija kot zahteva profila --------------------------------------------------- */

EXEC(N'
MERGE val.FieldRequirement AS target
USING
(
  SELECT profil.ValidationProfileId, N''ProductAttribute.Garancija'' AS FieldCode
  FROM val.ValidationProfile profil
  WHERE profil.ProfileCode IN (N''WEB_svetila_si'', N''WEB_videlektro'')
) AS source
  ON target.ValidationProfileId = source.ValidationProfileId AND target.FieldCode = source.FieldCode
WHEN MATCHED THEN UPDATE SET IsRequired = 1, IsActive = 1, Severity = N''WARNING''
WHEN NOT MATCHED THEN INSERT (ValidationProfileId, SourceExportColumnId, FieldCode, IsRequired, IsActive, Severity)
  VALUES (source.ValidationProfileId, NULL, source.FieldCode, 1, 1, N''WARNING'');
');

/* --- 3) Skladisce za zalogo iz SAOP ----------------------------------------------------- */

EXEC(N'
/* Sifra mora obstajati in biti aktivna, sicer bi worker klical SAOP za skladisce, ki ga ni. */
IF EXISTS (SELECT 1 FROM canon.Warehouse WHERE OrganizationId = 2 AND WarehouseCode = N''0000001'' AND IsActive = 1)
  UPDATE stock.SaopProviderProfile
  SET WarehouseSelectionMode = N''List'', WarehouseIdsJson = N''["0000001"]''
  WHERE OrganizationId = 2 AND ProfileCode = N''SAOP_GETSTOCKS'';

IF EXISTS (SELECT 1 FROM canon.Warehouse WHERE OrganizationId = 3 AND WarehouseCode = N''0000001'' AND IsActive = 1)
  UPDATE stock.SaopProviderProfile
  SET WarehouseSelectionMode = N''List'', WarehouseIdsJson = N''["0000001"]''
  WHERE OrganizationId = 3 AND ProfileCode = N''SAOP_GETSTOCKS'';
');
