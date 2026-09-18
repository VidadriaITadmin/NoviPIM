/*
  059 — kategorije: nase drevo namesto dobaviteljevega.

  Zakaj: kategorije, ki jih posilja dobavitelj, niso nase. Nowodvorski jih pise po svoje
  ("Interior lighting > Wall lamps > Sconces"), Braytron po svoje, mi pa imamo lastno drevo,
  ki ga uporablja splet. Doslej je v katalog padla dobaviteljeva kategorija prve ravni, in to
  v anglescini: v canon.ProductCategory je bilo 'Interior lighting' pod spletno stranjo 'B2C'.
  V izvozu je bil zato stolpec 'Kategorije vid SLO' poln anglescine, stolpca 24/25
  ('Kategorije svetila ANG/SLO') pa prazna, ker zanju vira sploh ni bilo.

  Odlocitev uporabnika 2026-08-22: stolpca 24/25 sta drevo svetila.si, 26/27 drevo videlektro;
  dobaviteljeva kategorija se preslika v naso, drevo pa je nase.

  Vir podatkov je stari sistem (baza PIM_test, samo branje) — tam drevo ze zivi:
    pim.Category (132 kategorij, 4 ravni)   -> canon.Category
    pim.CategoryTranslation (225 vrstic)    -> canon.CategoryTranslation (sl/en/de/hr)
    pim.Category_path_map (190 poti)        -> map.CategoryPathMap
  Nic od tega ni na novo izumljeno; prenesen je obstojeci in ze uporabljen slovar.

  Kaj nastane:
    canon.WebSite              register spletnih strani: katera stran je kateri jezik katerega
                               drevesa in v kateri stolpec izvoza gre
    canon.Category             nase drevo kategorij
    canon.CategoryTranslation  ime kategorije po jeziku
    canon.CategoryPathTranslated  pogled: cela pot v izbranem jeziku
    map.CategoryPathMap        dobaviteljeva pot -> nasa kategorija
    map.MissingCategoryMap     delovni seznam poti, ki jih slovar (se) ne pozna
    map.ResolveProductCategories  postopek, ki to izvede nad zajetim zagonom

  Kljuc dobaviteljeve poti je enak kot v starem sistemu: ravni z malimi crkami, presledek
  postane podcrtaj, ravni loci '___'. Merjeno na pravi datoteki dobavitelja (2.619 izdelkov,
  56 razlicnih poti): slovar pokrije 44 poti in s tem 93 % izdelkov. Preostalih 12 poti so
  tracni sistemi; te se zapisejo v map.MissingCategoryMap in cakajo na cloveka.

  Namenoma NE brise nicesar: stare vrstice 'B2C' z dobaviteljevo kategorijo ostanejo, dokler
  se o njih ne odloci (AGENTS.md #4.1).
*/

SET XACT_ABORT ON;

/* --- 1) register spletnih strani ----------------------------------------- */

IF OBJECT_ID(N'canon.WebSite') IS NULL
BEGIN
  CREATE TABLE canon.WebSite
  (
    WebSiteId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_WebSite PRIMARY KEY,
    WebSiteCode nvarchar(50) NOT NULL CONSTRAINT UQ_WebSite_Code UNIQUE,
    WebSiteName nvarchar(200) NOT NULL,
    CategoryTreeCode nvarchar(50) NOT NULL,
    LanguageCode nvarchar(10) NOT NULL,
    CategoryFieldCode nvarchar(200) NOT NULL,
    SortOrder int NOT NULL CONSTRAINT DF_WebSite_SortOrder DEFAULT(100),
    IsActive bit NOT NULL CONSTRAINT DF_WebSite_IsActive DEFAULT(1)
  );
END;

/*
  'B2C' in 'B2C_EN' sta zgodovinski oznaki, s katerima je drevo videlektro ze zapisano v
  canon.ProductCategory in v izvoznih poizvedbah. Ne preimenujeva ju, ker sta vezani na
  validacijski profil in na teste; register samo pove, kaj sta.
*/
MERGE canon.WebSite AS target
USING (VALUES
  (N'svetila_si',    N'Svetila.si',           N'svetila_si', N'sl', N'Product.CategorySvetilaSl', 10),
  (N'svetila_si_en', N'Svetila.si (ANG)',     N'svetila_si', N'en', N'Product.CategorySvetilaEn', 20),
  (N'B2C',           N'Videlektro',           N'videlektro', N'sl', N'Product.CategorySl',        30),
  (N'B2C_EN',        N'Videlektro (ANG)',     N'videlektro', N'en', N'Product.CategoryEn',        40)
) AS source(WebSiteCode,WebSiteName,CategoryTreeCode,LanguageCode,CategoryFieldCode,SortOrder)
  ON target.WebSiteCode = source.WebSiteCode
WHEN MATCHED THEN UPDATE SET
  WebSiteName = source.WebSiteName, CategoryTreeCode = source.CategoryTreeCode,
  LanguageCode = source.LanguageCode, CategoryFieldCode = source.CategoryFieldCode,
  SortOrder = source.SortOrder
WHEN NOT MATCHED THEN INSERT (WebSiteCode,WebSiteName,CategoryTreeCode,LanguageCode,CategoryFieldCode,SortOrder,IsActive)
  VALUES (source.WebSiteCode,source.WebSiteName,source.CategoryTreeCode,source.LanguageCode,source.CategoryFieldCode,source.SortOrder,1);

/* --- 2) drevo kategorij in prevodi ---------------------------------------- */

IF OBJECT_ID(N'canon.Category') IS NULL
BEGIN
  CREATE TABLE canon.Category
  (
    CategoryId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_Category PRIMARY KEY,
    CategoryTreeCode nvarchar(50) NOT NULL,
    CategoryCode nvarchar(200) NOT NULL,
    ParentCategoryCode nvarchar(200) NULL,
    LevelNo int NOT NULL,
    CategoryName nvarchar(400) NOT NULL,
    CategoryPath nvarchar(1000) NOT NULL,
    IsActive bit NOT NULL CONSTRAINT DF_Category_IsActive DEFAULT(1),
    CONSTRAINT UQ_Category_TreeCode UNIQUE (CategoryTreeCode, CategoryCode)
  );
END;

IF OBJECT_ID(N'canon.CategoryTranslation') IS NULL
BEGIN
  CREATE TABLE canon.CategoryTranslation
  (
    CategoryTranslationId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_CategoryTranslation PRIMARY KEY,
    CategoryTreeCode nvarchar(50) NOT NULL,
    CategoryCode nvarchar(200) NOT NULL,
    LanguageCode nvarchar(10) NOT NULL,
    CategoryName nvarchar(400) NOT NULL,
    CONSTRAINT UQ_CategoryTranslation UNIQUE (CategoryTreeCode, CategoryCode, LanguageCode)
  );
END;

MERGE canon.Category AS target
USING (VALUES
  (N'cameleon_sistem',NULL,1,N'Cameleon sistem',N'Cameleon sistem',1),
  (N'notranja_svetila',NULL,1,N'Notranja svetila',N'Notranja svetila',1),
  (N'prostor',NULL,1,N'PROSTOR',N'PROSTOR',1),
  (N'svetlobni_viri_in_dodatki',NULL,1,N'Svetlobni viri in dodatki',N'Svetlobni viri in dodatki',1),
  (N'tracni_sistemi',NULL,1,N'Tračni sistemi',N'Tračni sistemi',1),
  (N'zunanja_svetila',NULL,1,N'Zunanja svetila',N'Zunanja svetila',1),
  (N'cameleon_sistem___pritrdila',N'cameleon_sistem',2,N'Pritrdila',N'Cameleon sistem > Pritrdila',1),
  (N'cameleon_sistem___rozete',N'cameleon_sistem',2,N'Rozete',N'Cameleon sistem > Rozete',1),
  (N'cameleon_sistem___sencniki_in_svetila',N'cameleon_sistem',2,N'Senčniki in svetila',N'Cameleon sistem > Senčniki in svetila',1),
  (N'cameleon_sistem___viseci_sistemi',N'cameleon_sistem',2,N'Viseči sistemi',N'Cameleon sistem > Viseči sistemi',1),
  (N'notranja_svetila___dodatki',N'notranja_svetila',2,N'Dodatki',N'Notranja svetila > Dodatki',1),
  (N'notranja_svetila___downlights',N'notranja_svetila',2,N'Downlights',N'Notranja svetila > Downlights',1),
  (N'notranja_svetila___lestenci',N'notranja_svetila',2,N'Lestenci',N'Notranja svetila > Lestenci',1),
  (N'notranja_svetila___namizna_svetila',N'notranja_svetila',2,N'Namizna svetila',N'Notranja svetila > Namizna svetila',1),
  (N'notranja_svetila___reflektorska_svetila',N'notranja_svetila',2,N'Reflektorska svetila',N'Notranja svetila > Reflektorska svetila',1),
  (N'notranja_svetila___stenska_svetila',N'notranja_svetila',2,N'Stenska svetila',N'Notranja svetila > Stenska svetila',1),
  (N'notranja_svetila___stojeca_svetila',N'notranja_svetila',2,N'Stoječa svetila',N'Notranja svetila > Stoječa svetila',1),
  (N'notranja_svetila___stropna_svetila',N'notranja_svetila',2,N'Stropna svetila',N'Notranja svetila > Stropna svetila',1),
  (N'notranja_svetila___svetila_za_slike_in_ogledala',N'notranja_svetila',2,N'Svetila za slike in ogledala',N'Notranja svetila > Svetila za slike in ogledala',1),
  (N'notranja_svetila___talna_svetila',N'notranja_svetila',2,N'Talna svetila',N'Notranja svetila > Talna svetila',1),
  (N'notranja_svetila___vgradna_svetila',N'notranja_svetila',2,N'Vgradna svetila',N'Notranja svetila > Vgradna svetila',1),
  (N'notranja_svetila___viseca_svetila',N'notranja_svetila',2,N'Viseča svetila',N'Notranja svetila > Viseča svetila',1),
  (N'prostor___dnevna_soba',N'prostor',2,N'Dnevna soba',N'PROSTOR > Dnevna soba',1),
  (N'prostor___hodnik',N'prostor',2,N'Hodnik',N'PROSTOR > Hodnik',1),
  (N'prostor___jedilnica',N'prostor',2,N'Jedilnica',N'PROSTOR > Jedilnica',1),
  (N'prostor___kopalnica',N'prostor',2,N'Kopalnica',N'PROSTOR > Kopalnica',1),
  (N'prostor___kuhinja',N'prostor',2,N'Kuhinja',N'PROSTOR > Kuhinja',1),
  (N'prostor___otroska_soba',N'prostor',2,N'Otroška soba',N'PROSTOR > Otroška soba',1),
  (N'prostor___pisarna',N'prostor',2,N'Pisarna',N'PROSTOR > Pisarna',1),
  (N'prostor___podstresje',N'prostor',2,N'podstrešje',N'PROSTOR > podstrešje',1),
  (N'prostor___spalnica',N'prostor',2,N'Spalnica',N'PROSTOR > Spalnica',1),
  (N'prostor___stopnisce',N'prostor',2,N'Stopnišče',N'PROSTOR > Stopnišče',1),
  (N'prostor___vrt',N'prostor',2,N'Vrt',N'PROSTOR > Vrt',1),
  (N'svetlobni_viri_in_dodatki___cevi_led_t8',N'svetlobni_viri_in_dodatki',2,N'Cevi LED T8',N'Svetlobni viri in dodatki > Cevi LED T8',1),
  (N'svetlobni_viri_in_dodatki___dodatki',N'svetlobni_viri_in_dodatki',2,N'Dodatki',N'Svetlobni viri in dodatki > Dodatki',1),
  (N'svetlobni_viri_in_dodatki___e14',N'svetlobni_viri_in_dodatki',2,N'E14',N'Svetlobni viri in dodatki > E14',1),
  (N'svetlobni_viri_in_dodatki___e27',N'svetlobni_viri_in_dodatki',2,N'E27',N'Svetlobni viri in dodatki > E27',1),
  (N'svetlobni_viri_in_dodatki___g13',N'svetlobni_viri_in_dodatki',2,N'G13',N'Svetlobni viri in dodatki > G13',1),
  (N'svetlobni_viri_in_dodatki___g9',N'svetlobni_viri_in_dodatki',2,N'G9',N'Svetlobni viri in dodatki > G9',1),
  (N'svetlobni_viri_in_dodatki___gu10',N'svetlobni_viri_in_dodatki',2,N'GU10',N'Svetlobni viri in dodatki > GU10',1),
  (N'svetlobni_viri_in_dodatki___gu10_es111',N'svetlobni_viri_in_dodatki',2,N'GU10 ES111',N'Svetlobni viri in dodatki > GU10 ES111',1),
  (N'svetlobni_viri_in_dodatki___gu10_r35',N'svetlobni_viri_in_dodatki',2,N'GU10 R35',N'Svetlobni viri in dodatki > GU10 R35',1),
  (N'svetlobni_viri_in_dodatki___gu10_r50',N'svetlobni_viri_in_dodatki',2,N'GU10 R50',N'Svetlobni viri in dodatki > GU10 R50',1),
  (N'svetlobni_viri_in_dodatki___gu5_3',N'svetlobni_viri_in_dodatki',2,N'GU5.3',N'Svetlobni viri in dodatki > GU5.3',1),
  (N'svetlobni_viri_in_dodatki___gx53',N'svetlobni_viri_in_dodatki',2,N'GX53',N'Svetlobni viri in dodatki > GX53',1),
  (N'svetlobni_viri_in_dodatki___napajalniki',N'svetlobni_viri_in_dodatki',2,N'Napajalniki',N'Svetlobni viri in dodatki > Napajalniki',1),
  (N'tracni_sistemi___1_fazni_24v_nano_lvm',N'tracni_sistemi',2,N'1-fazni 24V NANO-LVM',N'Tračni sistemi > 1-fazni 24V NANO-LVM',1),
  (N'tracni_sistemi___1_fazni_48v_lvm',N'tracni_sistemi',2,N'1-fazni 48V LVM',N'Tračni sistemi > 1-fazni 48V LVM',1),
  (N'tracni_sistemi___1_fazni_48v_ut_lvm',N'tracni_sistemi',2,N'1-fazni 48V UT- LVM',N'Tračni sistemi > 1-fazni 48V UT- LVM',1),
  (N'tracni_sistemi___1_fazni_profile',N'tracni_sistemi',2,N'1-fazni Profile',N'Tračni sistemi > 1-fazni Profile',1),
  (N'tracni_sistemi___3_fazni_ctls',N'tracni_sistemi',2,N'3-fazni CTLS',N'Tračni sistemi > 3-fazni CTLS',1),
  (N'zunanja_svetila___hibay',N'zunanja_svetila',2,N'Hibay',N'Zunanja svetila > Hibay',1),
  (N'zunanja_svetila___led_reflektorji',N'zunanja_svetila',2,N'LED reflektorji',N'Zunanja svetila > LED reflektorji',1),
  (N'zunanja_svetila___namizna_svetila',N'zunanja_svetila',2,N'Namizna svetila',N'Zunanja svetila > Namizna svetila',1),
  (N'zunanja_svetila___pohodne_svetilke',N'zunanja_svetila',2,N'Pohodne svetilke',N'Zunanja svetila > Pohodne svetilke',1),
  (N'zunanja_svetila___prenosna_svetila',N'zunanja_svetila',2,N'Prenosna svetila',N'Zunanja svetila > Prenosna svetila',1),
  (N'zunanja_svetila___stenska_svetila',N'zunanja_svetila',2,N'Stenska svetila',N'Zunanja svetila > Stenska svetila',1),
  (N'zunanja_svetila___stojeca_svetila',N'zunanja_svetila',2,N'Stoječa svetila',N'Zunanja svetila > Stoječa svetila',1),
  (N'zunanja_svetila___stropna_svetila',N'zunanja_svetila',2,N'Stropna svetila',N'Zunanja svetila > Stropna svetila',1),
  (N'zunanja_svetila___svetlobne_verige',N'zunanja_svetila',2,N'Svetlobne verige',N'Zunanja svetila > Svetlobne verige',1),
  (N'zunanja_svetila___talna_svetila',N'zunanja_svetila',2,N'Talna svetila',N'Zunanja svetila > Talna svetila',1),
  (N'zunanja_svetila___ulicna_svetila',N'zunanja_svetila',2,N'Ulična svetila',N'Zunanja svetila > Ulična svetila',1),
  (N'zunanja_svetila___viseca_svetila',N'zunanja_svetila',2,N'Viseča svetila',N'Zunanja svetila > Viseča svetila',1),
  (N'notranja_svetila___downlights___nadgradne_svetilke',N'notranja_svetila___downlights',3,N'Nadgradne svetilke',N'Notranja svetila > Downlights > Nadgradne svetilke',1),
  (N'notranja_svetila___downlights___vgradne_svetilke',N'notranja_svetila___downlights',3,N'Vgradne svetilke',N'Notranja svetila > Downlights > Vgradne svetilke',1),
  (N'notranja_svetila___stenska_svetila___gibljive_svetilke',N'notranja_svetila___stenska_svetila',3,N'Gibljive svetilke',N'Notranja svetila > Stenska svetila > Gibljive svetilke',1),
  (N'notranja_svetila___stenska_svetila___indirektna_osvetlitev',N'notranja_svetila___stenska_svetila',3,N'Indirektna osvetlitev',N'Notranja svetila > Stenska svetila > Indirektna osvetlitev',1),
  (N'notranja_svetila___stenska_svetila___linijska_svetila',N'notranja_svetila___stenska_svetila',3,N'Linijska svetila',N'Notranja svetila > Stenska svetila > Linijska svetila',1),
  (N'notranja_svetila___stenska_svetila___ostala_svetila',N'notranja_svetila___stenska_svetila',3,N'Ostala svetila',N'Notranja svetila > Stenska svetila > Ostala svetila',1),
  (N'notranja_svetila___stenska_svetila___osvetlitev_stopnic',N'notranja_svetila___stenska_svetila',3,N'Osvetlitev stopnic',N'Notranja svetila > Stenska svetila > Osvetlitev stopnic',1),
  (N'notranja_svetila___stenska_svetila___reflektorska_svetila',N'notranja_svetila___stenska_svetila',3,N'Reflektorska svetila',N'Notranja svetila > Stenska svetila > Reflektorska svetila',1),
  (N'notranja_svetila___stenska_svetila___svecniki',N'notranja_svetila___stenska_svetila',3,N'Svečniki',N'Notranja svetila > Stenska svetila > Svečniki',1),
  (N'notranja_svetila___stenska_svetila___svetila_gor_dol',N'notranja_svetila___stenska_svetila',3,N'Svetila gor-dol',N'Notranja svetila > Stenska svetila > Svetila gor-dol',1),
  (N'notranja_svetila___stenska_svetila___svetilke_za_stopnisca',N'notranja_svetila___stenska_svetila',3,N'Svetilke za stopnišča',N'Notranja svetila > Stenska svetila > Svetilke za stopnišča',1),
  (N'notranja_svetila___stenska_svetila___tulci',N'notranja_svetila___stenska_svetila',3,N'Tulci',N'Notranja svetila > Stenska svetila > Tulci',1),
  (N'notranja_svetila___stenska_svetila___usmerjena_svetila',N'notranja_svetila___stenska_svetila',3,N'Usmerjena svetila',N'Notranja svetila > Stenska svetila > Usmerjena svetila',1),
  (N'notranja_svetila___stropna_svetila___dodatki',N'notranja_svetila___stropna_svetila',3,N'Dodatki',N'Notranja svetila > Stropna svetila > Dodatki',1),
  (N'notranja_svetila___stropna_svetila___led_panel',N'notranja_svetila___stropna_svetila',3,N'LED panel',N'Notranja svetila > Stropna svetila > LED panel',1),
  (N'notranja_svetila___stropna_svetila___lestenci',N'notranja_svetila___stropna_svetila',3,N'Lestenci',N'Notranja svetila > Stropna svetila > Lestenci',1),
  (N'notranja_svetila___stropna_svetila___linijska_svetila',N'notranja_svetila___stropna_svetila',3,N'Linijska svetila',N'Notranja svetila > Stropna svetila > Linijska svetila',1),
  (N'notranja_svetila___stropna_svetila___nadgradne_svetilke',N'notranja_svetila___stropna_svetila',3,N'Nadgradne svetilke',N'Notranja svetila > Stropna svetila > Nadgradne svetilke',1),
  (N'notranja_svetila___stropna_svetila___ostala_svetila',N'notranja_svetila___stropna_svetila',3,N'Ostala svetila',N'Notranja svetila > Stropna svetila > Ostala svetila',1),
  (N'notranja_svetila___stropna_svetila___plafonjere',N'notranja_svetila___stropna_svetila',3,N'Plafonjere',N'Notranja svetila > Stropna svetila > Plafonjere',1),
  (N'notranja_svetila___stropna_svetila___reflektorska_svetila',N'notranja_svetila___stropna_svetila',3,N'Reflektorska svetila',N'Notranja svetila > Stropna svetila > Reflektorska svetila',1),
  (N'notranja_svetila___stropna_svetila___tulci',N'notranja_svetila___stropna_svetila',3,N'Tulci',N'Notranja svetila > Stropna svetila > Tulci',1),
  (N'notranja_svetila___stropna_svetila___usmerjena_svetila',N'notranja_svetila___stropna_svetila',3,N'Usmerjena svetila',N'Notranja svetila > Stropna svetila > Usmerjena svetila',1),
  (N'notranja_svetila___vgradna_svetila___osvetlitev_stopnic',N'notranja_svetila___vgradna_svetila',3,N'Osvetlitev stopnic',N'Notranja svetila > Vgradna svetila > Osvetlitev stopnic',1),
  (N'notranja_svetila___vgradna_svetila___paneli',N'notranja_svetila___vgradna_svetila',3,N'Paneli',N'Notranja svetila > Vgradna svetila > Paneli',1),
  (N'notranja_svetila___vgradna_svetila___reflektorska_svetila',N'notranja_svetila___vgradna_svetila',3,N'Reflektorska svetila',N'Notranja svetila > Vgradna svetila > Reflektorska svetila',1),
  (N'notranja_svetila___vgradna_svetila___tulci',N'notranja_svetila___vgradna_svetila',3,N'Tulci',N'Notranja svetila > Vgradna svetila > Tulci',1),
  (N'notranja_svetila___vgradna_svetila___usmerjena_svetila',N'notranja_svetila___vgradna_svetila',3,N'Usmerjena svetila',N'Notranja svetila > Vgradna svetila > Usmerjena svetila',1),
  (N'tracni_sistemi___1_fazni_24v_nano_lvm___dodatki',N'tracni_sistemi___1_fazni_24v_nano_lvm',3,N'Dodatki',N'Tračni sistemi > 1-fazni 24V NANO-LVM > Dodatki',1),
  (N'tracni_sistemi___1_fazni_24v_nano_lvm___led_svetilke',N'tracni_sistemi___1_fazni_24v_nano_lvm',3,N'LED svetilke',N'Tračni sistemi > 1-fazni 24V NANO-LVM > LED svetilke',1),
  (N'tracni_sistemi___1_fazni_24v_nano_lvm___tracnice',N'tracni_sistemi___1_fazni_24v_nano_lvm',3,N'Tračnice',N'Tračni sistemi > 1-fazni 24V NANO-LVM > Tračnice',1),
  (N'tracni_sistemi___1_fazni_48v_lvm___dodatki',N'tracni_sistemi___1_fazni_48v_lvm',3,N'Dodatki',N'Tračni sistemi > 1-fazni 48V LVM > Dodatki',1),
  (N'tracni_sistemi___1_fazni_48v_lvm___led_svetilke',N'tracni_sistemi___1_fazni_48v_lvm',3,N'LED svetilke',N'Tračni sistemi > 1-fazni 48V LVM > LED svetilke',1),
  (N'tracni_sistemi___1_fazni_48v_lvm___tracnice',N'tracni_sistemi___1_fazni_48v_lvm',3,N'Tračnice',N'Tračni sistemi > 1-fazni 48V LVM > Tračnice',1),
  (N'tracni_sistemi___1_fazni_48v_ut_lvm___dodatki',N'tracni_sistemi___1_fazni_48v_ut_lvm',3,N'Dodatki',N'Tračni sistemi > 1-fazni 48V UT- LVM > Dodatki',1),
  (N'tracni_sistemi___1_fazni_48v_ut_lvm___led_svetilke',N'tracni_sistemi___1_fazni_48v_ut_lvm',3,N'LED svetilke',N'Tračni sistemi > 1-fazni 48V UT- LVM > LED svetilke',1),
  (N'tracni_sistemi___1_fazni_48v_ut_lvm___tracnice',N'tracni_sistemi___1_fazni_48v_ut_lvm',3,N'Tračnice',N'Tračni sistemi > 1-fazni 48V UT- LVM > Tračnice',1),
  (N'tracni_sistemi___1_fazni_profile___dodatki',N'tracni_sistemi___1_fazni_profile',3,N'Dodatki',N'Tračni sistemi > 1-fazni Profile > Dodatki',1),
  (N'tracni_sistemi___1_fazni_profile___svetila',N'tracni_sistemi___1_fazni_profile',3,N'Svetila',N'Tračni sistemi > 1-fazni Profile > Svetila',1),
  (N'tracni_sistemi___1_fazni_profile___tracnice',N'tracni_sistemi___1_fazni_profile',3,N'Tračnice',N'Tračni sistemi > 1-fazni Profile > Tračnice',1),
  (N'tracni_sistemi___3_fazni_ctls___dodatki',N'tracni_sistemi___3_fazni_ctls',3,N'Dodatki',N'Tračni sistemi > 3-fazni CTLS > Dodatki',1),
  (N'tracni_sistemi___3_fazni_ctls___svetila',N'tracni_sistemi___3_fazni_ctls',3,N'Svetila',N'Tračni sistemi > 3-fazni CTLS > Svetila',1),
  (N'tracni_sistemi___3_fazni_ctls___tracnice',N'tracni_sistemi___3_fazni_ctls',3,N'Tračnice',N'Tračni sistemi > 3-fazni CTLS > Tračnice',1),
  (N'zunanja_svetila___stenska_svetila___bulkhead',N'zunanja_svetila___stenska_svetila',3,N'Bulkhead',N'Zunanja svetila > Stenska svetila > Bulkhead',1),
  (N'zunanja_svetila___stenska_svetila___nadgradne_svetilke',N'zunanja_svetila___stenska_svetila',3,N'Nadgradne svetilke',N'Zunanja svetila > Stenska svetila > Nadgradne svetilke',1),
  (N'zunanja_svetila___stenska_svetila___vgradne_svetilke',N'zunanja_svetila___stenska_svetila',3,N'Vgradne svetilke',N'Zunanja svetila > Stenska svetila > Vgradne svetilke',1),
  (N'zunanja_svetila___stropna_svetila___plafonjere',N'zunanja_svetila___stropna_svetila',3,N'Plafonjere',N'Zunanja svetila > Stropna svetila > Plafonjere',1),
  (N'tracni_sistemi___1_fazni_24v_nano_lvm___dodatki___dodatki_za_nadgradne_tracnice',N'tracni_sistemi___1_fazni_24v_nano_lvm___dodatki',4,N'Dodatki za nadgradne tračnice',N'Tračni sistemi > 1-fazni 24V NANO-LVM > Dodatki > Dodatki za nadgradne tračnice',1),
  (N'tracni_sistemi___1_fazni_24v_nano_lvm___dodatki___dodatki_za_vgradne_tracnice',N'tracni_sistemi___1_fazni_24v_nano_lvm___dodatki',4,N'Dodatki za vgradne tračnice',N'Tračni sistemi > 1-fazni 24V NANO-LVM > Dodatki > Dodatki za vgradne tračnice',1),
  (N'tracni_sistemi___1_fazni_24v_nano_lvm___dodatki___univerzalni_dodatki',N'tracni_sistemi___1_fazni_24v_nano_lvm___dodatki',4,N'Univerzalni dodatki',N'Tračni sistemi > 1-fazni 24V NANO-LVM > Dodatki > Univerzalni dodatki',1),
  (N'tracni_sistemi___1_fazni_24v_nano_lvm___tracnice___nadgradne_tracnice',N'tracni_sistemi___1_fazni_24v_nano_lvm___tracnice',4,N'Nadgradne tračnice',N'Tračni sistemi > 1-fazni 24V NANO-LVM > Tračnice > Nadgradne tračnice',1),
  (N'tracni_sistemi___1_fazni_24v_nano_lvm___tracnice___vgradne_tracnice',N'tracni_sistemi___1_fazni_24v_nano_lvm___tracnice',4,N'Vgradne tračnice',N'Tračni sistemi > 1-fazni 24V NANO-LVM > Tračnice > Vgradne tračnice',1),
  (N'tracni_sistemi___1_fazni_48v_lvm___dodatki___dodatki_za_nadgradne_tracnice',N'tracni_sistemi___1_fazni_48v_lvm___dodatki',4,N'Dodatki za nadgradne tračnice',N'Tračni sistemi > 1-fazni 48V LVM > Dodatki > Dodatki za nadgradne tračnice',1),
  (N'tracni_sistemi___1_fazni_48v_lvm___dodatki___dodatki_za_vgradne_tracnice',N'tracni_sistemi___1_fazni_48v_lvm___dodatki',4,N'Dodatki za vgradne tračnice',N'Tračni sistemi > 1-fazni 48V LVM > Dodatki > Dodatki za vgradne tračnice',1),
  (N'tracni_sistemi___1_fazni_48v_lvm___dodatki___univerzalni_dodatki',N'tracni_sistemi___1_fazni_48v_lvm___dodatki',4,N'Univerzalni dodatki',N'Tračni sistemi > 1-fazni 48V LVM > Dodatki > Univerzalni dodatki',1),
  (N'tracni_sistemi___1_fazni_48v_lvm___tracnice___nadgradne_tracnice',N'tracni_sistemi___1_fazni_48v_lvm___tracnice',4,N'Nadgradne tračnice',N'Tračni sistemi > 1-fazni 48V LVM > Tračnice > Nadgradne tračnice',1),
  (N'tracni_sistemi___1_fazni_48v_lvm___tracnice___vgradne_tracnice',N'tracni_sistemi___1_fazni_48v_lvm___tracnice',4,N'Vgradne tračnice',N'Tračni sistemi > 1-fazni 48V LVM > Tračnice > Vgradne tračnice',1),
  (N'tracni_sistemi___1_fazni_48v_ut_lvm___dodatki___dodatki_za_nadgradne_tracnice',N'tracni_sistemi___1_fazni_48v_ut_lvm___dodatki',4,N'Dodatki za nadgradne tračnice',N'Tračni sistemi > 1-fazni 48V UT- LVM > Dodatki > Dodatki za nadgradne tračnice',1),
  (N'tracni_sistemi___1_fazni_48v_ut_lvm___dodatki___dodatki_za_vgradne_tracnice',N'tracni_sistemi___1_fazni_48v_ut_lvm___dodatki',4,N'Dodatki za vgradne tračnice',N'Tračni sistemi > 1-fazni 48V UT- LVM > Dodatki > Dodatki za vgradne tračnice',1),
  (N'tracni_sistemi___1_fazni_48v_ut_lvm___tracnice___nadgradne_tracnice',N'tracni_sistemi___1_fazni_48v_ut_lvm___tracnice',4,N'Nadgradne tračnice',N'Tračni sistemi > 1-fazni 48V UT- LVM > Tračnice > Nadgradne tračnice',1),
  (N'tracni_sistemi___1_fazni_48v_ut_lvm___tracnice___vgradne_tracnice',N'tracni_sistemi___1_fazni_48v_ut_lvm___tracnice',4,N'Vgradne tračnice',N'Tračni sistemi > 1-fazni 48V UT- LVM > Tračnice > Vgradne tračnice',1),
  (N'tracni_sistemi___1_fazni_profile___dodatki___dodatki_za_nadgradne_tracnice',N'tracni_sistemi___1_fazni_profile___dodatki',4,N'Dodatki za nadgradne tračnice',N'Tračni sistemi > 1-fazni Profile > Dodatki > Dodatki za nadgradne tračnice',1),
  (N'tracni_sistemi___1_fazni_profile___dodatki___dodatki_za_vgradne_tracnice',N'tracni_sistemi___1_fazni_profile___dodatki',4,N'Dodatki za vgradne tračnice',N'Tračni sistemi > 1-fazni Profile > Dodatki > Dodatki za vgradne tračnice',1),
  (N'tracni_sistemi___1_fazni_profile___tracnice___nadgradne_tracnice',N'tracni_sistemi___1_fazni_profile___tracnice',4,N'Nadgradne tračnice',N'Tračni sistemi > 1-fazni Profile > Tračnice > Nadgradne tračnice',1),
  (N'tracni_sistemi___1_fazni_profile___tracnice___vgradne_tracnice',N'tracni_sistemi___1_fazni_profile___tracnice',4,N'Vgradne tračnice',N'Tračni sistemi > 1-fazni Profile > Tračnice > Vgradne tračnice',1),
  (N'tracni_sistemi___3_fazni_ctls___dodatki___dodatki_za_nadgradne_tracnice',N'tracni_sistemi___3_fazni_ctls___dodatki',4,N'Dodatki za nadgradne tračnice',N'Tračni sistemi > 3-fazni CTLS > Dodatki > Dodatki za nadgradne tračnice',1),
  (N'tracni_sistemi___3_fazni_ctls___dodatki___dodatki_za_vgradne_tracnice',N'tracni_sistemi___3_fazni_ctls___dodatki',4,N'Dodatki za vgradne tračnice',N'Tračni sistemi > 3-fazni CTLS > Dodatki > Dodatki za vgradne tračnice',1),
  (N'tracni_sistemi___3_fazni_ctls___tracnice___nadgradne_tracnice',N'tracni_sistemi___3_fazni_ctls___tracnice',4,N'Nadgradne tračnice',N'Tračni sistemi > 3-fazni CTLS > Tračnice > Nadgradne tračnice',1),
  (N'tracni_sistemi___3_fazni_ctls___tracnice___vgradne_tracnice',N'tracni_sistemi___3_fazni_ctls___tracnice',4,N'Vgradne tračnice',N'Tračni sistemi > 3-fazni CTLS > Tračnice > Vgradne tračnice',1)
) AS source(CategoryCode,ParentCategoryCode,LevelNo,CategoryName,CategoryPath,IsActive)
  ON target.CategoryTreeCode = N'svetila_si' AND target.CategoryCode = source.CategoryCode
WHEN MATCHED THEN UPDATE SET
  ParentCategoryCode = source.ParentCategoryCode, LevelNo = source.LevelNo,
  CategoryName = source.CategoryName, CategoryPath = source.CategoryPath, IsActive = source.IsActive
WHEN NOT MATCHED THEN INSERT (CategoryTreeCode,CategoryCode,ParentCategoryCode,LevelNo,CategoryName,CategoryPath,IsActive)
  VALUES (N'svetila_si',source.CategoryCode,source.ParentCategoryCode,source.LevelNo,source.CategoryName,source.CategoryPath,source.IsActive);

MERGE canon.CategoryTranslation AS target
USING (VALUES
  (N'cameleon_sistem',N'de',N'Cameleon System'),
  (N'cameleon_sistem',N'en',N'Cameleon System'),
  (N'cameleon_sistem',N'hr',N'Cameleon sustav'),
  (N'cameleon_sistem',N'sl',N'Cameleon sistem'),
  (N'cameleon_sistem___pritrdila',N'en',N'Fixing'),
  (N'cameleon_sistem___pritrdila',N'sl',N'Pritrdila'),
  (N'cameleon_sistem___rozete',N'de',N'Überdachungen'),
  (N'cameleon_sistem___rozete',N'en',N'Canopies'),
  (N'cameleon_sistem___rozete',N'hr',N'Nadstrešnice'),
  (N'cameleon_sistem___rozete',N'sl',N'Rozete'),
  (N'cameleon_sistem___sencniki_in_svetila',N'de',N'Schatten und Lichter'),
  (N'cameleon_sistem___sencniki_in_svetila',N'en',N'Shades and lighting fixtures'),
  (N'cameleon_sistem___sencniki_in_svetila',N'hr',N'Sjenila i svjetla'),
  (N'cameleon_sistem___sencniki_in_svetila',N'sl',N'Senčniki in svetila'),
  (N'cameleon_sistem___viseci_sistemi',N'de',N'Hängesysteme'),
  (N'cameleon_sistem___viseci_sistemi',N'hr',N'Viseći sustavi'),
  (N'cameleon_sistem___viseci_sistemi',N'sl',N'Viseči sistemi'),
  (N'notranja_svetila',N'en',N'Interior lighting'),
  (N'notranja_svetila',N'sl',N'Notranja svetila'),
  (N'notranja_svetila___dodatki',N'en',N'Accessories'),
  (N'notranja_svetila___dodatki',N'sl',N'Dodatki'),
  (N'notranja_svetila___downlights',N'de',N'Downlights'),
  (N'notranja_svetila___downlights',N'en',N'Downlights'),
  (N'notranja_svetila___downlights',N'hr',N'Downlights'),
  (N'notranja_svetila___downlights',N'sl',N'Downlights'),
  (N'notranja_svetila___downlights___nadgradne_svetilke',N'en',N'Surfaced mounted'),
  (N'notranja_svetila___downlights___nadgradne_svetilke',N'sl',N'Nadgradne svetilke'),
  (N'notranja_svetila___downlights___vgradne_svetilke',N'en',N'Recessed mounted'),
  (N'notranja_svetila___downlights___vgradne_svetilke',N'sl',N'Vgradne svetilke'),
  (N'notranja_svetila___lestenci',N'sl',N'Lestenci'),
  (N'notranja_svetila___namizna_svetila',N'en',N'Table lamps'),
  (N'notranja_svetila___namizna_svetila',N'sl',N'Namizna svetila'),
  (N'notranja_svetila___reflektorska_svetila',N'en',N'Spotlights and spots'),
  (N'notranja_svetila___reflektorska_svetila',N'sl',N'Reflektorska svetila'),
  (N'notranja_svetila___stenska_svetila',N'en',N'Wall lamps'),
  (N'notranja_svetila___stenska_svetila',N'sl',N'Stenska svetila'),
  (N'notranja_svetila___stenska_svetila___gibljive_svetilke',N'en',N'Adjustable lamps'),
  (N'notranja_svetila___stenska_svetila___gibljive_svetilke',N'sl',N'Gibljive svetilke'),
  (N'notranja_svetila___stenska_svetila___indirektna_osvetlitev',N'sl',N'Indirektna osvetlitev'),
  (N'notranja_svetila___stenska_svetila___linijska_svetila',N'sl',N'Linijska svetila'),
  (N'notranja_svetila___stenska_svetila___ostala_svetila',N'sl',N'Ostala svetila'),
  (N'notranja_svetila___stenska_svetila___osvetlitev_stopnic',N'sl',N'Osvetlitev stopnic'),
  (N'notranja_svetila___stenska_svetila___reflektorska_svetila',N'sl',N'Reflektorska svetila'),
  (N'notranja_svetila___stenska_svetila___svecniki',N'en',N'Sconces'),
  (N'notranja_svetila___stenska_svetila___svecniki',N'sl',N'Svečniki'),
  (N'notranja_svetila___stenska_svetila___svetila_gor_dol',N'sl',N'Svetila gor-dol'),
  (N'notranja_svetila___stenska_svetila___svetilke_za_stopnisca',N'sl',N'Svetilke za stopnišča'),
  (N'notranja_svetila___stenska_svetila___tulci',N'sl',N'Tulci'),
  (N'notranja_svetila___stenska_svetila___usmerjena_svetila',N'sl',N'Usmerjena svetila'),
  (N'notranja_svetila___stojeca_svetila',N'sl',N'Stoječa svetila'),
  (N'notranja_svetila___stropna_svetila',N'en',N'Ceiling lamps'),
  (N'notranja_svetila___stropna_svetila',N'sl',N'Stropna svetila'),
  (N'notranja_svetila___stropna_svetila___dodatki',N'sl',N'Dodatki'),
  (N'notranja_svetila___stropna_svetila___led_panel',N'en',N'LED panel'),
  (N'notranja_svetila___stropna_svetila___led_panel',N'sl',N'LED panel'),
  (N'notranja_svetila___stropna_svetila___lestenci',N'en',N'Chandeliers'),
  (N'notranja_svetila___stropna_svetila___lestenci',N'sl',N'Lestenci'),
  (N'notranja_svetila___stropna_svetila___linijska_svetila',N'en',N'Linear lamps'),
  (N'notranja_svetila___stropna_svetila___linijska_svetila',N'sl',N'Linijska svetila'),
  (N'notranja_svetila___stropna_svetila___nadgradne_svetilke',N'en',N'Flush mounted lamps'),
  (N'notranja_svetila___stropna_svetila___nadgradne_svetilke',N'sl',N'Nadgradne svetilke'),
  (N'notranja_svetila___stropna_svetila___ostala_svetila',N'sl',N'Ostala svetila'),
  (N'notranja_svetila___stropna_svetila___plafonjere',N'en',N'Plafonds'),
  (N'notranja_svetila___stropna_svetila___plafonjere',N'sl',N'Plafonjere'),
  (N'notranja_svetila___stropna_svetila___reflektorska_svetila',N'sl',N'Reflektorska svetila'),
  (N'notranja_svetila___stropna_svetila___tulci',N'sl',N'Tulci'),
  (N'notranja_svetila___stropna_svetila___usmerjena_svetila',N'sl',N'Usmerjena svetila'),
  (N'notranja_svetila___svetila_za_slike_in_ogledala',N'sl',N'Svetila za slike in ogledala'),
  (N'notranja_svetila___talna_svetila',N'en',N'Floor lamps'),
  (N'notranja_svetila___talna_svetila',N'sl',N'Talna svetila'),
  (N'notranja_svetila___vgradna_svetila',N'sl',N'Vgradna svetila'),
  (N'notranja_svetila___vgradna_svetila___osvetlitev_stopnic',N'sl',N'Osvetlitev stopnic'),
  (N'notranja_svetila___vgradna_svetila___paneli',N'sl',N'Paneli'),
  (N'notranja_svetila___vgradna_svetila___reflektorska_svetila',N'sl',N'Reflektorska svetila'),
  (N'notranja_svetila___vgradna_svetila___tulci',N'sl',N'Tulci'),
  (N'notranja_svetila___vgradna_svetila___usmerjena_svetila',N'sl',N'Usmerjena svetila'),
  (N'notranja_svetila___viseca_svetila',N'en',N'Suspended lamps'),
  (N'notranja_svetila___viseca_svetila',N'sl',N'Viseča svetila'),
  (N'svetlobni_viri_in_dodatki',N'sl',N'Svetlobni viri in dodatki'),
  (N'svetlobni_viri_in_dodatki___cevi_led_t8',N'sl',N'Cevi LED T8'),
  (N'svetlobni_viri_in_dodatki___dodatki',N'en',N'Accessories'),
  (N'svetlobni_viri_in_dodatki___dodatki',N'sl',N'Dodatki'),
  (N'svetlobni_viri_in_dodatki___e14',N'de',N'E14'),
  (N'svetlobni_viri_in_dodatki___e14',N'en',N'E14'),
  (N'svetlobni_viri_in_dodatki___e14',N'hr',N'E14'),
  (N'svetlobni_viri_in_dodatki___e14',N'sl',N'E14'),
  (N'svetlobni_viri_in_dodatki___e27',N'sl',N'E27'),
  (N'svetlobni_viri_in_dodatki___g13',N'sl',N'G13'),
  (N'svetlobni_viri_in_dodatki___g9',N'de',N'G9'),
  (N'svetlobni_viri_in_dodatki___g9',N'en',N'G9'),
  (N'svetlobni_viri_in_dodatki___g9',N'hr',N'G9'),
  (N'svetlobni_viri_in_dodatki___g9',N'sl',N'G9'),
  (N'svetlobni_viri_in_dodatki___gu10',N'sl',N'GU10'),
  (N'svetlobni_viri_in_dodatki___gu10_es111',N'de',N'GU10 ES111'),
  (N'svetlobni_viri_in_dodatki___gu10_es111',N'en',N'GU10 ES111'),
  (N'svetlobni_viri_in_dodatki___gu10_es111',N'hr',N'GU10 ES111'),
  (N'svetlobni_viri_in_dodatki___gu10_es111',N'sl',N'GU10 ES111'),
  (N'svetlobni_viri_in_dodatki___gu10_r35',N'de',N'GU10 R35'),
  (N'svetlobni_viri_in_dodatki___gu10_r35',N'en',N'GU10 R35'),
  (N'svetlobni_viri_in_dodatki___gu10_r35',N'hr',N'GU10 R35'),
  (N'svetlobni_viri_in_dodatki___gu10_r35',N'sl',N'GU10 R35'),
  (N'svetlobni_viri_in_dodatki___gu10_r50',N'de',N'GU10 R50'),
  (N'svetlobni_viri_in_dodatki___gu10_r50',N'en',N'GU10 R50'),
  (N'svetlobni_viri_in_dodatki___gu10_r50',N'hr',N'GU10 R50'),
  (N'svetlobni_viri_in_dodatki___gu10_r50',N'sl',N'GU10 R50'),
  (N'svetlobni_viri_in_dodatki___gu5_3',N'sl',N'GU5.3'),
  (N'svetlobni_viri_in_dodatki___gx53',N'de',N'GX53'),
  (N'svetlobni_viri_in_dodatki___gx53',N'en',N'GX53'),
  (N'svetlobni_viri_in_dodatki___gx53',N'hr',N'GX53'),
  (N'svetlobni_viri_in_dodatki___gx53',N'sl',N'GX53'),
  (N'svetlobni_viri_in_dodatki___napajalniki',N'en',N'Power supplies'),
  (N'svetlobni_viri_in_dodatki___napajalniki',N'sl',N'Napajalniki'),
  (N'tracni_sistemi',N'en',N'Track systems'),
  (N'tracni_sistemi',N'sl',N'Tračni sistemi'),
  (N'tracni_sistemi___1_fazni_24v_nano_lvm',N'en',N'1-circuit 24V NANO-LVM'),
  (N'tracni_sistemi___1_fazni_24v_nano_lvm',N'sl',N'1-fazni 24V NANO-LVM'),
  (N'tracni_sistemi___1_fazni_24v_nano_lvm___dodatki',N'en',N'Accessories'),
  (N'tracni_sistemi___1_fazni_24v_nano_lvm___dodatki',N'sl',N'Dodatki'),
  (N'tracni_sistemi___1_fazni_24v_nano_lvm___dodatki___dodatki_za_nadgradne_tracnice',N'en',N'Surfaced mounted'),
  (N'tracni_sistemi___1_fazni_24v_nano_lvm___dodatki___dodatki_za_nadgradne_tracnice',N'sl',N'Dodatki za nadgradne tračnice'),
  (N'tracni_sistemi___1_fazni_24v_nano_lvm___dodatki___dodatki_za_vgradne_tracnice',N'en',N'Recessed mounted'),
  (N'tracni_sistemi___1_fazni_24v_nano_lvm___dodatki___dodatki_za_vgradne_tracnice',N'sl',N'Dodatki za vgradne tračnice'),
  (N'tracni_sistemi___1_fazni_24v_nano_lvm___dodatki___univerzalni_dodatki',N'en',N'Universal'),
  (N'tracni_sistemi___1_fazni_24v_nano_lvm___dodatki___univerzalni_dodatki',N'sl',N'Univerzalni dodatki'),
  (N'tracni_sistemi___1_fazni_24v_nano_lvm___led_svetilke',N'en',N'LED lamps'),
  (N'tracni_sistemi___1_fazni_24v_nano_lvm___led_svetilke',N'sl',N'LED svetilke'),
  (N'tracni_sistemi___1_fazni_24v_nano_lvm___tracnice',N'en',N'Tracks'),
  (N'tracni_sistemi___1_fazni_24v_nano_lvm___tracnice',N'sl',N'Tračnice'),
  (N'tracni_sistemi___1_fazni_24v_nano_lvm___tracnice___nadgradne_tracnice',N'en',N'Surfaced mounted'),
  (N'tracni_sistemi___1_fazni_24v_nano_lvm___tracnice___nadgradne_tracnice',N'sl',N'Nadgradne tračnice'),
  (N'tracni_sistemi___1_fazni_24v_nano_lvm___tracnice___vgradne_tracnice',N'en',N'Recessed mounted'),
  (N'tracni_sistemi___1_fazni_24v_nano_lvm___tracnice___vgradne_tracnice',N'sl',N'Vgradne tračnice'),
  (N'tracni_sistemi___1_fazni_48v_lvm',N'en',N'1-circuit 48V   UT- LVM'),
  (N'tracni_sistemi___1_fazni_48v_lvm',N'sl',N'1-fazni 48V LVM'),
  (N'tracni_sistemi___1_fazni_48v_lvm___dodatki',N'en',N'Accessories'),
  (N'tracni_sistemi___1_fazni_48v_lvm___dodatki',N'sl',N'Dodatki'),
  (N'tracni_sistemi___1_fazni_48v_lvm___dodatki___dodatki_za_nadgradne_tracnice',N'en',N'Surfaced mounted'),
  (N'tracni_sistemi___1_fazni_48v_lvm___dodatki___dodatki_za_nadgradne_tracnice',N'sl',N'Dodatki za nadgradne tračnice'),
  (N'tracni_sistemi___1_fazni_48v_lvm___dodatki___dodatki_za_vgradne_tracnice',N'en',N'Recessed mounted'),
  (N'tracni_sistemi___1_fazni_48v_lvm___dodatki___dodatki_za_vgradne_tracnice',N'sl',N'Dodatki za vgradne tračnice'),
  (N'tracni_sistemi___1_fazni_48v_lvm___dodatki___univerzalni_dodatki',N'en',N'Universal'),
  (N'tracni_sistemi___1_fazni_48v_lvm___dodatki___univerzalni_dodatki',N'sl',N'Univerzalni dodatki'),
  (N'tracni_sistemi___1_fazni_48v_lvm___led_svetilke',N'en',N'LED lamps'),
  (N'tracni_sistemi___1_fazni_48v_lvm___led_svetilke',N'sl',N'LED svetilke'),
  (N'tracni_sistemi___1_fazni_48v_lvm___tracnice',N'en',N'Tracks'),
  (N'tracni_sistemi___1_fazni_48v_lvm___tracnice',N'sl',N'Tračnice'),
  (N'tracni_sistemi___1_fazni_48v_lvm___tracnice___nadgradne_tracnice',N'en',N'Surfaced mounted'),
  (N'tracni_sistemi___1_fazni_48v_lvm___tracnice___nadgradne_tracnice',N'sl',N'Nadgradne tračnice'),
  (N'tracni_sistemi___1_fazni_48v_lvm___tracnice___vgradne_tracnice',N'en',N'Recessed mounted'),
  (N'tracni_sistemi___1_fazni_48v_lvm___tracnice___vgradne_tracnice',N'sl',N'Vgradne tračnice'),
  (N'tracni_sistemi___1_fazni_48v_ut_lvm',N'en',N'1-circuit 48V UT- LVM'),
  (N'tracni_sistemi___1_fazni_48v_ut_lvm',N'sl',N'1-fazni 48V UT- LVM'),
  (N'tracni_sistemi___1_fazni_48v_ut_lvm___dodatki',N'en',N'Accessories'),
  (N'tracni_sistemi___1_fazni_48v_ut_lvm___dodatki',N'sl',N'Dodatki'),
  (N'tracni_sistemi___1_fazni_48v_ut_lvm___dodatki___dodatki_za_nadgradne_tracnice',N'en',N'Surfaced mounted'),
  (N'tracni_sistemi___1_fazni_48v_ut_lvm___dodatki___dodatki_za_nadgradne_tracnice',N'sl',N'Dodatki za nadgradne tračnice'),
  (N'tracni_sistemi___1_fazni_48v_ut_lvm___dodatki___dodatki_za_vgradne_tracnice',N'en',N'Recessed mounted'),
  (N'tracni_sistemi___1_fazni_48v_ut_lvm___dodatki___dodatki_za_vgradne_tracnice',N'sl',N'Dodatki za vgradne tračnice'),
  (N'tracni_sistemi___1_fazni_48v_ut_lvm___led_svetilke',N'en',N'LED lamps'),
  (N'tracni_sistemi___1_fazni_48v_ut_lvm___led_svetilke',N'sl',N'LED svetilke'),
  (N'tracni_sistemi___1_fazni_48v_ut_lvm___tracnice',N'en',N'Tracks'),
  (N'tracni_sistemi___1_fazni_48v_ut_lvm___tracnice',N'sl',N'Tračnice'),
  (N'tracni_sistemi___1_fazni_48v_ut_lvm___tracnice___nadgradne_tracnice',N'en',N'Surfaced mounted'),
  (N'tracni_sistemi___1_fazni_48v_ut_lvm___tracnice___nadgradne_tracnice',N'sl',N'Nadgradne tračnice'),
  (N'tracni_sistemi___1_fazni_48v_ut_lvm___tracnice___vgradne_tracnice',N'en',N'Recessed mounted'),
  (N'tracni_sistemi___1_fazni_48v_ut_lvm___tracnice___vgradne_tracnice',N'sl',N'Vgradne tračnice'),
  (N'tracni_sistemi___1_fazni_profile',N'en',N'1-circuit Profile'),
  (N'tracni_sistemi___1_fazni_profile',N'sl',N'1-fazni Profile'),
  (N'tracni_sistemi___1_fazni_profile___dodatki',N'en',N'Accessories'),
  (N'tracni_sistemi___1_fazni_profile___dodatki',N'sl',N'Dodatki'),
  (N'tracni_sistemi___1_fazni_profile___dodatki___dodatki_za_nadgradne_tracnice',N'en',N'Surfaced mounted'),
  (N'tracni_sistemi___1_fazni_profile___dodatki___dodatki_za_nadgradne_tracnice',N'sl',N'Dodatki za nadgradne tračnice'),
  (N'tracni_sistemi___1_fazni_profile___dodatki___dodatki_za_vgradne_tracnice',N'en',N'Recessed mounted'),
  (N'tracni_sistemi___1_fazni_profile___dodatki___dodatki_za_vgradne_tracnice',N'sl',N'Dodatki za vgradne tračnice'),
  (N'tracni_sistemi___1_fazni_profile___svetila',N'en',N'Lamps'),
  (N'tracni_sistemi___1_fazni_profile___svetila',N'sl',N'Svetila'),
  (N'tracni_sistemi___1_fazni_profile___tracnice',N'en',N'Tracks'),
  (N'tracni_sistemi___1_fazni_profile___tracnice',N'sl',N'Tračnice'),
  (N'tracni_sistemi___1_fazni_profile___tracnice___nadgradne_tracnice',N'en',N'Surfaced mounted'),
  (N'tracni_sistemi___1_fazni_profile___tracnice___nadgradne_tracnice',N'sl',N'Nadgradne tračnice'),
  (N'tracni_sistemi___1_fazni_profile___tracnice___vgradne_tracnice',N'en',N'Recessed mounted'),
  (N'tracni_sistemi___1_fazni_profile___tracnice___vgradne_tracnice',N'sl',N'Vgradne tračnice'),
  (N'tracni_sistemi___3_fazni_ctls',N'sl',N'3-fazni CTLS'),
  (N'tracni_sistemi___3_fazni_ctls___dodatki',N'en',N'Accessories'),
  (N'tracni_sistemi___3_fazni_ctls___dodatki',N'sl',N'Dodatki'),
  (N'tracni_sistemi___3_fazni_ctls___dodatki___dodatki_za_nadgradne_tracnice',N'en',N'Surfaced mounted'),
  (N'tracni_sistemi___3_fazni_ctls___dodatki___dodatki_za_nadgradne_tracnice',N'sl',N'Dodatki za nadgradne tračnice'),
  (N'tracni_sistemi___3_fazni_ctls___dodatki___dodatki_za_vgradne_tracnice',N'en',N'Recessed mounted'),
  (N'tracni_sistemi___3_fazni_ctls___dodatki___dodatki_za_vgradne_tracnice',N'sl',N'Dodatki za vgradne tračnice'),
  (N'tracni_sistemi___3_fazni_ctls___svetila',N'en',N'Lamps'),
  (N'tracni_sistemi___3_fazni_ctls___svetila',N'sl',N'Svetila'),
  (N'tracni_sistemi___3_fazni_ctls___tracnice',N'en',N'Tracks'),
  (N'tracni_sistemi___3_fazni_ctls___tracnice',N'sl',N'Tračnice'),
  (N'tracni_sistemi___3_fazni_ctls___tracnice___nadgradne_tracnice',N'en',N'Surfaced mounted'),
  (N'tracni_sistemi___3_fazni_ctls___tracnice___nadgradne_tracnice',N'sl',N'Nadgradne tračnice'),
  (N'tracni_sistemi___3_fazni_ctls___tracnice___vgradne_tracnice',N'en',N'Recessed mounted'),
  (N'tracni_sistemi___3_fazni_ctls___tracnice___vgradne_tracnice',N'sl',N'Vgradne tračnice'),
  (N'zunanja_svetila',N'en',N'Outdoor lighting'),
  (N'zunanja_svetila',N'sl',N'Zunanja svetila'),
  (N'zunanja_svetila___hibay',N'sl',N'Hibay'),
  (N'zunanja_svetila___led_reflektorji',N'sl',N'LED reflektorji'),
  (N'zunanja_svetila___namizna_svetila',N'sl',N'Namizna svetila'),
  (N'zunanja_svetila___pohodne_svetilke',N'en',N'Overrun lamps'),
  (N'zunanja_svetila___pohodne_svetilke',N'sl',N'Pohodne svetilke'),
  (N'zunanja_svetila___prenosna_svetila',N'en',N'Portable lamps'),
  (N'zunanja_svetila___prenosna_svetila',N'sl',N'Prenosna svetila'),
  (N'zunanja_svetila___stenska_svetila',N'sl',N'Stenska svetila'),
  (N'zunanja_svetila___stenska_svetila___bulkhead',N'sl',N'Bulkhead'),
  (N'zunanja_svetila___stenska_svetila___nadgradne_svetilke',N'en',N'Surface mounted'),
  (N'zunanja_svetila___stenska_svetila___nadgradne_svetilke',N'sl',N'Nadgradne svetilke'),
  (N'zunanja_svetila___stenska_svetila___vgradne_svetilke',N'en',N'Built-in lamps'),
  (N'zunanja_svetila___stenska_svetila___vgradne_svetilke',N'sl',N'Vgradne svetilke'),
  (N'zunanja_svetila___stojeca_svetila',N'en',N'Standing lamps'),
  (N'zunanja_svetila___stojeca_svetila',N'sl',N'Stoječa svetila'),
  (N'zunanja_svetila___stropna_svetila',N'en',N'Ceiling lamps'),
  (N'zunanja_svetila___stropna_svetila',N'sl',N'Stropna svetila'),
  (N'zunanja_svetila___stropna_svetila___plafonjere',N'en',N'Plafonds'),
  (N'zunanja_svetila___stropna_svetila___plafonjere',N'sl',N'Plafonjere'),
  (N'zunanja_svetila___svetlobne_verige',N'en',N'Festoon'),
  (N'zunanja_svetila___svetlobne_verige',N'sl',N'Svetlobne verige'),
  (N'zunanja_svetila___talna_svetila',N'en',N'Ground lights'),
  (N'zunanja_svetila___talna_svetila',N'sl',N'Talna svetila'),
  (N'zunanja_svetila___ulicna_svetila',N'sl',N'Ulična svetila'),
  (N'zunanja_svetila___viseca_svetila',N'en',N'Suspended lamps'),
  (N'zunanja_svetila___viseca_svetila',N'sl',N'Viseča svetila')
) AS source(CategoryCode,LanguageCode,CategoryName)
  ON target.CategoryTreeCode = N'svetila_si' AND target.CategoryCode = source.CategoryCode
    AND target.LanguageCode = source.LanguageCode
WHEN MATCHED THEN UPDATE SET CategoryName = source.CategoryName
WHEN NOT MATCHED THEN INSERT (CategoryTreeCode,CategoryCode,LanguageCode,CategoryName)
  VALUES (N'svetila_si',source.CategoryCode,source.LanguageCode,source.CategoryName);

/* Kategorija brez slovenskega vpisa dobi svoje ime — pot v slovenscini mora obstajati vedno. */
INSERT canon.CategoryTranslation(CategoryTreeCode,CategoryCode,LanguageCode,CategoryName)
SELECT category.CategoryTreeCode, category.CategoryCode, N'sl', category.CategoryName
FROM canon.Category category
WHERE NOT EXISTS
(
  SELECT 1 FROM canon.CategoryTranslation prevod
  WHERE prevod.CategoryTreeCode = category.CategoryTreeCode
    AND prevod.CategoryCode = category.CategoryCode AND prevod.LanguageCode = N'sl'
);

/* --- 3) cela pot v izbranem jeziku ---------------------------------------- */

EXEC(N'
CREATE OR ALTER VIEW canon.CategoryPathTranslated
AS
/*
  Pot sestavimo iz imen prednikov v istem jeziku. Kjer prevoda ni, obvelja slovensko ime —
  polovicno prevedena pot je za splet uporabnejsa od prazne.

  Prevod se poisce v prvem, nerekurzivnem delu (ime), ker zunanji stik v rekurzivnem delu
  ni dovoljen; veriga nato dela samo se z inner stikom.
*/
WITH ime AS
(
  SELECT category.CategoryTreeCode, category.CategoryCode, category.ParentCategoryCode,
    jezik.LanguageCode,
    CONVERT(nvarchar(400), ISNULL(prevod.CategoryName, category.CategoryName)) AS CategoryName
  FROM canon.Category category
  CROSS JOIN (SELECT DISTINCT LanguageCode FROM canon.CategoryTranslation) jezik
  LEFT JOIN canon.CategoryTranslation prevod
    ON prevod.CategoryTreeCode = category.CategoryTreeCode AND prevod.CategoryCode = category.CategoryCode
      AND prevod.LanguageCode = jezik.LanguageCode
  WHERE category.IsActive = 1
),
veriga AS
(
  SELECT ime.CategoryTreeCode, ime.CategoryCode, ime.LanguageCode,
    CONVERT(nvarchar(1000), ime.CategoryName) AS CategoryPath
  FROM ime
  WHERE ime.ParentCategoryCode IS NULL
  UNION ALL
  SELECT ime.CategoryTreeCode, ime.CategoryCode, ime.LanguageCode,
    CONVERT(nvarchar(1000), starsi.CategoryPath + N'' > '' + ime.CategoryName)
  FROM ime
  INNER JOIN veriga starsi
    ON starsi.CategoryTreeCode = ime.CategoryTreeCode AND starsi.CategoryCode = ime.ParentCategoryCode
      AND starsi.LanguageCode = ime.LanguageCode
)
SELECT CategoryTreeCode, CategoryCode, LanguageCode, CategoryPath FROM veriga;
');

/* --- 4) dobaviteljeva pot -> nasa kategorija ------------------------------ */

IF OBJECT_ID(N'map.CategoryPathMap') IS NULL
BEGIN
  CREATE TABLE map.CategoryPathMap
  (
    CategoryPathMapId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_CategoryPathMap PRIMARY KEY,
    SourceCode nvarchar(100) NOT NULL,
    CategoryTreeCode nvarchar(50) NOT NULL,
    SourcePathKey nvarchar(1000) NOT NULL,
    CategoryCode nvarchar(200) NOT NULL,
    IsActive bit NOT NULL CONSTRAINT DF_CategoryPathMap_IsActive DEFAULT(1),
    CONSTRAINT UQ_CategoryPathMap UNIQUE (SourceCode, CategoryTreeCode, SourcePathKey)
  );
END;

IF OBJECT_ID(N'map.MissingCategoryMap') IS NULL
BEGIN
  CREATE TABLE map.MissingCategoryMap
  (
    MissingCategoryMapId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_MissingCategoryMap PRIMARY KEY,
    SourceCode nvarchar(100) NOT NULL,
    CategoryTreeCode nvarchar(50) NOT NULL,
    SourcePathKey nvarchar(1000) NOT NULL,
    SeenCount int NOT NULL CONSTRAINT DF_MissingCategoryMap_SeenCount DEFAULT(0),
    FirstSeenUtc datetime2(3) NOT NULL CONSTRAINT DF_MissingCategoryMap_First DEFAULT SYSUTCDATETIME(),
    LastSeenUtc datetime2(3) NOT NULL CONSTRAINT DF_MissingCategoryMap_Last DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_MissingCategoryMap UNIQUE (SourceCode, CategoryTreeCode, SourcePathKey)
  );
END;

MERGE map.CategoryPathMap AS target
USING (VALUES
  (N'bulbs_&_tubes___gu10_bulbs___gu10',N'svetlobni_viri_in_dodatki___gu10'),
  (N'bulbs_&_tubes___led_tubes___g13_double_side_connection',N'svetlobni_viri_in_dodatki___g13'),
  (N'bulbs_&_tubes___mr16_bulbs___gu5.3',N'svetlobni_viri_in_dodatki___gu5_3'),
  (N'cameleon_system',N'cameleon_sistem'),
  (N'cameleon_system___canopies',N'cameleon_sistem___rozete'),
  (N'cameleon_system___fixing',N'cameleon_sistem___pritrdila'),
  (N'cameleon_system___shades_and_lighting_fixtures',N'cameleon_sistem___sencniki_in_svetila'),
  (N'cameleon_system___suspensions',N'cameleon_sistem___viseci_sistemi'),
  (N'decorative_cls___fixtures___ceiling_light',N'notranja_svetila___stropna_svetila___nadgradne_svetilke'),
  (N'decorative_cls___fixtures___pendant_light',N'notranja_svetila___viseca_svetila'),
  (N'decorative_cls___fixtures___table_lamp',N'notranja_svetila___namizna_svetila'),
  (N'decorative_cls___fixtures___wall_light',N'notranja_svetila___stenska_svetila'),
  (N'decorative_cls___floor___floor_lamp',N'notranja_svetila___talna_svetila'),
  (N'decorative_cls___floor___table_lamp',N'notranja_svetila___namizna_svetila'),
  (N'decorative_cls___glass_clr___pendant_light',N'notranja_svetila___viseca_svetila'),
  (N'decorative_cls___glass_clr___table_lamp',N'notranja_svetila___namizna_svetila'),
  (N'decorative_cls___glass_clr___wall_light',N'notranja_svetila___stenska_svetila___ostala_svetila'),
  (N'decorative_cls___glass_cry___pendant_light',N'notranja_svetila___viseca_svetila'),
  (N'decorative_cls___glass_cry___wall_light',N'notranja_svetila___stenska_svetila___ostala_svetila'),
  (N'decorative_cls___glass_opl___ceiling_light',N'notranja_svetila___stropna_svetila___nadgradne_svetilke'),
  (N'decorative_cls___glass_opl___pendant_light',N'notranja_svetila___viseca_svetila'),
  (N'decorative_cls___glass_opl___table_lamp',N'notranja_svetila___namizna_svetila'),
  (N'decorative_cls___glass_opl___wall_light',N'notranja_svetila___stenska_svetila'),
  (N'decorative_cls___metal___ceiling_light',N'notranja_svetila___stropna_svetila___nadgradne_svetilke'),
  (N'decorative_cls___metal___floor_lamp',N'notranja_svetila___talna_svetila'),
  (N'decorative_cls___metal___pendant_light',N'notranja_svetila___viseca_svetila'),
  (N'decorative_cls___metal___table_lamp',N'notranja_svetila___namizna_svetila'),
  (N'decorative_cls___metal___wall_light',N'notranja_svetila___stenska_svetila'),
  (N'decorative_cls___rattan___pendant_light',N'notranja_svetila___viseca_svetila'),
  (N'decorative_cls___wiring___ceiling_light',N'notranja_svetila___stropna_svetila___nadgradne_svetilke'),
  (N'decorative_cls___wiring___floor_lamp',N'notranja_svetila___talna_svetila'),
  (N'decorative_cls___wiring___pendant_light',N'notranja_svetila___viseca_svetila'),
  (N'decorative_cls___wiring___table_lamp',N'notranja_svetila___namizna_svetila'),
  (N'decorative_cls___wiring___wall_light',N'notranja_svetila___stenska_svetila___ostala_svetila'),
  (N'decorative_cls___wooden___ceiling_light',N'notranja_svetila___stropna_svetila___nadgradne_svetilke'),
  (N'decorative_cls___wooden___floor_lamp',N'notranja_svetila___talna_svetila'),
  (N'decorative_cls___wooden___pendant_light',N'notranja_svetila___viseca_svetila'),
  (N'decorative_cls___wooden___table_lamp',N'notranja_svetila___namizna_svetila'),
  (N'decorative_cls___wooden___wall_light',N'notranja_svetila___stenska_svetila___ostala_svetila'),
  (N'decorative_led___ceiling_light_bella___ceiling_light',N'notranja_svetila___stropna_svetila___plafonjere'),
  (N'decorative_led___ceiling_light_blade___ceiling_light',N'notranja_svetila___stropna_svetila___plafonjere'),
  (N'decorative_led___ceiling_light_crystal___ceiling_light',N'notranja_svetila___stropna_svetila___nadgradne_svetilke'),
  (N'decorative_led___ceiling_light_jade',N'notranja_svetila___stropna_svetila'),
  (N'decorative_led___ceiling_light_jade___ceiling_light',N'notranja_svetila___stropna_svetila___plafonjere'),
  (N'decorative_led___ceiling_light_nela___ceiling_light',N'notranja_svetila___stropna_svetila___nadgradne_svetilke'),
  (N'decorative_led___led_desk_lamp___desk',N'notranja_svetila___namizna_svetila'),
  (N'decorative_led___led_desk_lamp___table_lamp',N'notranja_svetila___namizna_svetila'),
  (N'decorative_led___led_wall_light___wall',N'notranja_svetila___stenska_svetila___ostala_svetila'),
  (N'decorative_led___led_wall_light___wall_light',N'notranja_svetila___stenska_svetila___ostala_svetila'),
  (N'decorative_led___linear_light_lina___pendant',N'notranja_svetila___viseca_svetila'),
  (N'decorative_led___pendant_light_arcana___ceiling_light',N'notranja_svetila___stropna_svetila___nadgradne_svetilke'),
  (N'decorative_led___pendant_light_arcana___pendant_light',N'notranja_svetila___viseca_svetila'),
  (N'decorative_led___pendant_light_bella___pendant',N'notranja_svetila___viseca_svetila'),
  (N'decorative_led___pendant_light_blade___pendant',N'notranja_svetila___viseca_svetila'),
  (N'decorative_led___pendant_light_lina___pendant',N'notranja_svetila___viseca_svetila'),
  (N'decorative_led___pendant_light_nela___pendant_light',N'notranja_svetila___viseca_svetila'),
  (N'decorative_led___picture_&_mirror_light___mirror',N'notranja_svetila___svetila_za_slike_in_ogledala'),
  (N'indoor_lighting___accessories',N'notranja_svetila___dodatki'),
  (N'indoor_lighting___accessories___pendant_part',N'notranja_svetila___dodatki'),
  (N'indoor_lighting___accessories___reflector',N'notranja_svetila___dodatki'),
  (N'indoor_lighting___accessories___spring',N'notranja_svetila___dodatki'),
  (N'indoor_lighting___accessories___surface_frame',N'notranja_svetila___dodatki'),
  (N'indoor_lighting___ceiling_light___ceiling_light',N'notranja_svetila___stropna_svetila___plafonjere'),
  (N'indoor_lighting___gu10_pendant_spotlight___pendant',N'notranja_svetila___viseca_svetila'),
  (N'indoor_lighting___gu10_recessed_spotlight',N'notranja_svetila___downlights'),
  (N'indoor_lighting___gu10_recessed_spotlight___spotlight',N'notranja_svetila___downlights___vgradne_svetilke'),
  (N'indoor_lighting___gu10_surface_spotlight___spotlight',N'notranja_svetila___reflektorska_svetila'),
  (N'indoor_lighting___led_batten_light',N'notranja_svetila___stropna_svetila'),
  (N'indoor_lighting___led_batten_light___batten_light',N'notranja_svetila___stropna_svetila___linijska_svetila'),
  (N'indoor_lighting___led_big_panel',N'notranja_svetila___stropna_svetila'),
  (N'indoor_lighting___led_big_panel___recessed_panel',N'notranja_svetila___stropna_svetila___led_panel'),
  (N'indoor_lighting___led_downlight___downlight',N'notranja_svetila___downlights___nadgradne_svetilke'),
  (N'indoor_lighting___led_downlight___recessed_downlight',N'notranja_svetila___downlights___vgradne_svetilke'),
  (N'indoor_lighting___led_downlight___recessed_panel',N'notranja_svetila___downlights___vgradne_svetilke'),
  (N'indoor_lighting___led_floor_lamp___ambient_light',N'notranja_svetila___talna_svetila'),
  (N'indoor_lighting___led_small_panel',N'notranja_svetila___stropna_svetila___led_panel'),
  (N'indoor_lighting___led_small_panel___recessed_&_surface_panel',N'notranja_svetila___stropna_svetila___led_panel'),
  (N'indoor_lighting___led_small_panel___recessed_panel',N'notranja_svetila___stropna_svetila___led_panel'),
  (N'indoor_lighting___led_small_panel___suface_panel',N'notranja_svetila___stropna_svetila___led_panel'),
  (N'indoor_lighting___led_small_panel___surface_frame',N'notranja_svetila___stropna_svetila___led_panel'),
  (N'indoor_lighting___led_small_panel___surface_panel',N'notranja_svetila___stropna_svetila___led_panel'),
  (N'indoor_lighting___led_spotlight',N'notranja_svetila___stropna_svetila'),
  (N'indoor_lighting___led_spotlight___linear_fixture',N'notranja_svetila___stropna_svetila___reflektorska_svetila'),
  (N'indoor_lighting___led_spotlight___spotlight',N'notranja_svetila___stropna_svetila___reflektorska_svetila'),
  (N'indoor_lighting___linear_light',N'notranja_svetila___stropna_svetila'),
  (N'indoor_lighting___linear_light___clips',N'notranja_svetila___stropna_svetila___dodatki'),
  (N'indoor_lighting___linear_light___connector',N'notranja_svetila___stropna_svetila___dodatki'),
  (N'indoor_lighting___linear_light___diffuser',N'notranja_svetila___stropna_svetila___dodatki'),
  (N'indoor_lighting___linear_light___linear_light',N'notranja_svetila___stropna_svetila___linijska_svetila'),
  (N'indoor_lighting___linear_light___locker',N'notranja_svetila___stropna_svetila___dodatki'),
  (N'indoor_lighting___linear_light___pendant_part',N'notranja_svetila___stropna_svetila___dodatki'),
  (N'indoor_lighting___sensor_fixtures___ceiling_light',N'notranja_svetila___stropna_svetila___nadgradne_svetilke'),
  (N'indoor_lighting___steplight___cover',N'notranja_svetila___stenska_svetila___svetilke_za_stopnisca'),
  (N'indoor_lighting___steplight___steplight',N'notranja_svetila___stenska_svetila___svetilke_za_stopnisca'),
  (N'interior_lighting',N'notranja_svetila'),
  (N'interior_lighting___ceiling_lamps',N'notranja_svetila___stropna_svetila'),
  (N'interior_lighting___ceiling_lamps___chandeliers',N'notranja_svetila___stropna_svetila___lestenci'),
  (N'interior_lighting___ceiling_lamps___flush_mounted_lamps',N'notranja_svetila___stropna_svetila___nadgradne_svetilke'),
  (N'interior_lighting___ceiling_lamps___linear_lamps',N'notranja_svetila___stropna_svetila___linijska_svetila'),
  (N'interior_lighting___ceiling_lamps___panel_led',N'notranja_svetila___stropna_svetila___led_panel'),
  (N'interior_lighting___ceiling_lamps___plafonds',N'notranja_svetila___stropna_svetila___plafonjere'),
  (N'interior_lighting___ceiling_lamps___suspended_lamps',N'notranja_svetila___viseca_svetila'),
  (N'interior_lighting___downlights',N'notranja_svetila___downlights'),
  (N'interior_lighting___downlights___recessed_mounted',N'notranja_svetila___downlights___vgradne_svetilke'),
  (N'interior_lighting___downlights___surfaced_mounted',N'notranja_svetila___downlights___nadgradne_svetilke'),
  (N'interior_lighting___floor_lamps',N'notranja_svetila___talna_svetila'),
  (N'interior_lighting___petit_lamps_to_assembly',N'notranja_svetila___stropna_svetila___dodatki'),
  (N'interior_lighting___spotlights_and_spots',N'notranja_svetila___reflektorska_svetila'),
  (N'interior_lighting___table_lamps',N'notranja_svetila___namizna_svetila'),
  (N'interior_lighting___wall_lamps',N'notranja_svetila___stenska_svetila'),
  (N'interior_lighting___wall_lamps___adjustable_lamps',N'notranja_svetila___stenska_svetila___gibljive_svetilke'),
  (N'interior_lighting___wall_lamps___adjustable_with_switch',N'notranja_svetila___stenska_svetila___gibljive_svetilke'),
  (N'interior_lighting___wall_lamps___sconces',N'notranja_svetila___stenska_svetila___svecniki'),
  (N'interior_lighting___wall_lamps___sconces_with_switch',N'notranja_svetila___stenska_svetila___svecniki'),
  (N'interior_lighting___wall_lamps___stairway_lights',N'notranja_svetila___stenska_svetila___svetilke_za_stopnisca'),
  (N'light_sources_and_accessories',N'svetlobni_viri_in_dodatki'),
  (N'light_sources_and_accessories___accessories',N'svetlobni_viri_in_dodatki___dodatki'),
  (N'light_sources_and_accessories___e14',N'svetlobni_viri_in_dodatki___e14'),
  (N'light_sources_and_accessories___e27',N'svetlobni_viri_in_dodatki___e27'),
  (N'light_sources_and_accessories___g9',N'svetlobni_viri_in_dodatki___g9'),
  (N'light_sources_and_accessories___gu10_es111',N'svetlobni_viri_in_dodatki___gu10_es111'),
  (N'light_sources_and_accessories___gu10_r35',N'svetlobni_viri_in_dodatki___gu10_r35'),
  (N'light_sources_and_accessories___gu10_r50',N'svetlobni_viri_in_dodatki___gu10_r50'),
  (N'light_sources_and_accessories___gx53',N'svetlobni_viri_in_dodatki___gx53'),
  (N'light_sources_and_accessories___led_t8_tubes',N'svetlobni_viri_in_dodatki___cevi_led_t8'),
  (N'light_sources_and_accessories___power_supplies',N'svetlobni_viri_in_dodatki___dodatki'),
  (N'outdoor_lighting',N'zunanja_svetila'),
  (N'outdoor_lighting___ceiling_lamps',N'zunanja_svetila___stropna_svetila'),
  (N'outdoor_lighting___ceiling_lamps___plafonds',N'zunanja_svetila___stropna_svetila___plafonjere'),
  (N'outdoor_lighting___ceiling_lamps___suspended_lamps',N'zunanja_svetila___viseca_svetila'),
  (N'outdoor_lighting___ceiling_light___ceiling_light',N'zunanja_svetila___talna_svetila'),
  (N'outdoor_lighting___e27_bollard',N'zunanja_svetila___talna_svetila'),
  (N'outdoor_lighting___e27_bollard___bollard',N'zunanja_svetila___talna_svetila'),
  (N'outdoor_lighting___e27_wall_light',N'zunanja_svetila___stenska_svetila'),
  (N'outdoor_lighting___e27_wall_light___bollard',N'zunanja_svetila___talna_svetila'),
  (N'outdoor_lighting___e27_wall_light___pendant',N'zunanja_svetila___stenska_svetila___nadgradne_svetilke'),
  (N'outdoor_lighting___e27_wall_light___wall',N'zunanja_svetila___stenska_svetila___nadgradne_svetilke'),
  (N'outdoor_lighting___festoon',N'zunanja_svetila___svetlobne_verige'),
  (N'outdoor_lighting___ground_lights',N'zunanja_svetila___talna_svetila'),
  (N'outdoor_lighting___gu10_wall_light___wall',N'zunanja_svetila___stenska_svetila___nadgradne_svetilke'),
  (N'outdoor_lighting___led_bollard___bollard',N'zunanja_svetila___talna_svetila'),
  (N'outdoor_lighting___led_bulkhead___bulkhead',N'zunanja_svetila___led_reflektorji'),
  (N'outdoor_lighting___led_floodlight',N'zunanja_svetila___led_reflektorji'),
  (N'outdoor_lighting___led_floodlight___flood',N'zunanja_svetila___led_reflektorji'),
  (N'outdoor_lighting___led_floodlight___floodlight',N'zunanja_svetila___led_reflektorji'),
  (N'outdoor_lighting___led_hibay',N'zunanja_svetila___hibay'),
  (N'outdoor_lighting___led_hibay___canopy',N'zunanja_svetila___hibay'),
  (N'outdoor_lighting___led_hibay___hibay',N'zunanja_svetila___hibay'),
  (N'outdoor_lighting___led_hibay___linear_hibay',N'zunanja_svetila___hibay'),
  (N'outdoor_lighting___led_hibay___sensor',N'zunanja_svetila___hibay'),
  (N'outdoor_lighting___led_wall_light',N'zunanja_svetila___stenska_svetila'),
  (N'outdoor_lighting___led_wall_light___bulkhead',N'zunanja_svetila___stenska_svetila___bulkhead'),
  (N'outdoor_lighting___led_wall_light___wall_light',N'zunanja_svetila___led_reflektorji'),
  (N'outdoor_lighting___overrun_lamps',N'zunanja_svetila___pohodne_svetilke'),
  (N'outdoor_lighting___portable_lamps',N'zunanja_svetila___prenosna_svetila'),
  (N'outdoor_lighting___standing_lamps',N'zunanja_svetila___stojeca_svetila'),
  (N'outdoor_lighting___wall_lamps',N'zunanja_svetila___stenska_svetila'),
  (N'outdoor_lighting___wall_lamps___built-in_lamps',N'zunanja_svetila___stenska_svetila___vgradne_svetilke'),
  (N'outdoor_lighting___wall_lamps___surface_mounted',N'zunanja_svetila___stenska_svetila___nadgradne_svetilke'),
  (N'track_systems',N'tracni_sistemi'),
  (N'track_systems___1-circuit_low-voltage_24v_nano-lvm',N'tracni_sistemi___1_fazni_24v_nano_lvm'),
  (N'track_systems___1-circuit_low-voltage_24v_nano-lvm___accessories___recessed_mounted',N'tracni_sistemi___1_fazni_24v_nano_lvm___dodatki___dodatki_za_vgradne_tracnice'),
  (N'track_systems___1-circuit_low-voltage_24v_nano-lvm___accessories___surfaced_mounted',N'tracni_sistemi___1_fazni_24v_nano_lvm___dodatki___dodatki_za_nadgradne_tracnice'),
  (N'track_systems___1-circuit_low-voltage_24v_nano-lvm___accessories___universal',N'tracni_sistemi___1_fazni_24v_nano_lvm___dodatki___univerzalni_dodatki'),
  (N'track_systems___1-circuit_low-voltage_24v_nano-lvm___led_lamps',N'tracni_sistemi___1_fazni_24v_nano_lvm___led_svetilke'),
  (N'track_systems___1-circuit_low-voltage_24v_nano-lvm___tracks___recessed_mounted',N'tracni_sistemi___1_fazni_24v_nano_lvm___tracnice___vgradne_tracnice'),
  (N'track_systems___1-circuit_low-voltage_24v_nano-lvm___tracks___surfaced_mounted',N'tracni_sistemi___1_fazni_24v_nano_lvm___tracnice___nadgradne_tracnice'),
  (N'track_systems___1-circuit_low-voltage_48v___ut-_lvm',N'tracni_sistemi___1_fazni_48v_ut_lvm'),
  (N'track_systems___1-circuit_low-voltage_48v___ut-_lvm___accessories___surfaced_mounted',N'tracni_sistemi___1_fazni_48v_ut_lvm___dodatki___dodatki_za_nadgradne_tracnice'),
  (N'track_systems___1-circuit_low-voltage_48v___ut-_lvm___led_lamps',N'tracni_sistemi___1_fazni_48v_ut_lvm___led_svetilke'),
  (N'track_systems___1-circuit_low-voltage_48v___ut-_lvm___tracks___surfaced_mounted',N'tracni_sistemi___1_fazni_48v_lvm___tracnice___nadgradne_tracnice'),
  (N'track_systems___1-circuit_low-voltage_48v_lvm',N'tracni_sistemi___1_fazni_48v_lvm'),
  (N'track_systems___1-circuit_low-voltage_48v_lvm___accessories___recessed_mounted',N'tracni_sistemi___1_fazni_48v_lvm___dodatki___dodatki_za_vgradne_tracnice'),
  (N'track_systems___1-circuit_low-voltage_48v_lvm___accessories___surfaced_mounted',N'tracni_sistemi___1_fazni_48v_lvm___dodatki___dodatki_za_nadgradne_tracnice'),
  (N'track_systems___1-circuit_low-voltage_48v_lvm___accessories___universal',N'tracni_sistemi___1_fazni_48v_lvm___dodatki___univerzalni_dodatki'),
  (N'track_systems___1-circuit_low-voltage_48v_lvm___led_lamps',N'tracni_sistemi___1_fazni_48v_lvm___led_svetilke'),
  (N'track_systems___1-circuit_low-voltage_48v_lvm___tracks___recessed_mounted',N'tracni_sistemi___1_fazni_48v_lvm___tracnice___vgradne_tracnice'),
  (N'track_systems___1-circuit_low-voltage_48v_lvm___tracks___surfaced_mounted',N'tracni_sistemi___1_fazni_48v_lvm___tracnice___nadgradne_tracnice'),
  (N'track_systems___1-circuit_profile',N'tracni_sistemi___1_fazni_profile'),
  (N'track_systems___1-circuit_profile___accessories___recessed_mounted',N'tracni_sistemi___1_fazni_profile___dodatki___dodatki_za_vgradne_tracnice'),
  (N'track_systems___1-circuit_profile___accessories___surfaced_mounted',N'tracni_sistemi___1_fazni_profile___dodatki___dodatki_za_nadgradne_tracnice'),
  (N'track_systems___1-circuit_profile___lamps',N'tracni_sistemi___1_fazni_profile'),
  (N'track_systems___1-circuit_profile___tracks___recessed_mounted',N'tracni_sistemi___1_fazni_profile___tracnice___vgradne_tracnice'),
  (N'track_systems___1-circuit_profile___tracks___surfaced_mounted',N'tracni_sistemi___1_fazni_profile___tracnice___nadgradne_tracnice'),
  (N'track_systems___3-circuit_ctls',N'tracni_sistemi___3_fazni_ctls'),
  (N'track_systems___3-circuit_ctls___accessories___recessed_mounted',N'tracni_sistemi___3_fazni_ctls___dodatki___dodatki_za_vgradne_tracnice'),
  (N'track_systems___3-circuit_ctls___accessories___surfaced_mounted',N'tracni_sistemi___3_fazni_ctls___dodatki___dodatki_za_nadgradne_tracnice'),
  (N'track_systems___3-circuit_ctls___lamps',N'tracni_sistemi___3_fazni_ctls___svetila'),
  (N'track_systems___3-circuit_ctls___tracks___recessed_mounted',N'tracni_sistemi___3_fazni_ctls___tracnice___vgradne_tracnice'),
  (N'track_systems___3-circuit_ctls___tracks___surfaced_mounted',N'tracni_sistemi___3_fazni_ctls___tracnice___nadgradne_tracnice')
) AS source(SourcePathKey,CategoryCode)
  ON target.SourceCode = N'NW_XML' AND target.CategoryTreeCode = N'svetila_si'
    AND target.SourcePathKey = source.SourcePathKey
WHEN MATCHED THEN UPDATE SET CategoryCode = source.CategoryCode, IsActive = 1
WHEN NOT MATCHED THEN INSERT (SourceCode,CategoryTreeCode,SourcePathKey,CategoryCode,IsActive)
  VALUES (N'NW_XML',N'svetila_si',source.SourcePathKey,source.CategoryCode,1);

/* --- 5) postopek, ki dobaviteljevo pot prevede v naso kategorijo ---------- */
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

  IF OBJECT_ID(N''tempdb..#Kategorija'') IS NOT NULL DROP TABLE #Kategorija;

  SELECT
    zapis.ProductId,
    drevo.CategoryTreeCode,
    zapis.SourcePathKey
  INTO #Kategorija
  FROM
  (
    SELECT
      izdelek.ProductId,
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
  ) zapis
  CROSS JOIN (SELECT DISTINCT CategoryTreeCode FROM map.CategoryPathMap WHERE SourceCode = @SourceCode AND IsActive = 1) drevo;

  /* Kar slovar pozna, pristane v katalogu — ena vrstica na spletno stran drevesa. */
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

  /* Cesar slovar ne pozna, gre v delovni seznam s stevcem — to ni napaka, ampak naloga. */
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
END;
');

/* --- 6) Nowodvorski: vse tri ravni klasifikacije, ne samo prva ------------ */

DECLARE @NwConnectorId int =
  (SELECT SourceConnectorId FROM map.SourceConnector WHERE SourceCode = N'NW_XML' AND OrganizationId = 2);

IF @NwConnectorId IS NULL
  THROW 52590, 'Konektor NW_XML ne obstaja.', 1;

MERGE map.FieldMapping AS target
USING (VALUES
  (N'product_classification/product_classification_i/i/text()[1]',   N'ProductCategory.SourceLevel1'),
  (N'product_classification/product_classification_i/ii/text()[1]',  N'ProductCategory.SourceLevel2'),
  (N'product_classification/product_classification_i/iii/text()[1]', N'ProductCategory.SourceLevel3')
) AS source(SourceElement, TargetFieldCode)
  ON target.SourceConnectorId = @NwConnectorId AND target.EntityType = N'Classification'
    AND target.TargetFieldCode = source.TargetFieldCode
WHEN MATCHED THEN UPDATE SET SourceElement = source.SourceElement, IsActive = 1, IsRequired = 0
WHEN NOT MATCHED THEN INSERT (SourceConnectorId, EntityType, SourceElement, TargetFieldCode, IsRequired, IsActive)
  VALUES (@NwConnectorId, N'Classification', source.SourceElement, source.TargetFieldCode, 0, 1);

/*
  Stara preslikava (prva raven -> ProductCategory.CategoryPath, spletna stran ''B2C'') se
  izklopi: pisala je dobaviteljevo angleisko ime prve ravni v slovenski stolpec videlektra.
  Vrstice, ki jih je ze naredila, ostanejo — o njih se odloci clovek.
*/
UPDATE map.FieldMapping
SET IsActive = 0
WHERE SourceConnectorId = @NwConnectorId AND EntityType = N'Classification'
  AND TargetFieldCode = N'ProductCategory.CategoryPath';

/* --- 7) stolpca 24 in 25 izvoza dobita vir -------------------------------- */

DECLARE @ProductProfileId int =
  (SELECT ExportProfileId FROM out.ExportProfile WHERE ProfileCode = N'MAGENTO_PRODUCTS');

UPDATE out.ExportColumn SET CanonicalFieldCode = N'Product.CategorySvetilaEn'
WHERE ExportProfileId = @ProductProfileId AND OutputColumnName = N'Kategorije svetila ANG';

UPDATE out.ExportColumn SET CanonicalFieldCode = N'Product.CategorySvetilaSl'
WHERE ExportProfileId = @ProductProfileId AND OutputColumnName = N'Kategorije svetila SLO';

/* --- 8) preverbe ---------------------------------------------------------- */

IF (SELECT COUNT(*) FROM canon.Category WHERE CategoryTreeCode = N'svetila_si') < 132
  THROW 52591, 'Drevo kategorij svetila.si ni v celoti preneseno.', 1;

IF (SELECT COUNT(*) FROM map.CategoryPathMap WHERE SourceCode = N'NW_XML' AND IsActive = 1) < 190
  THROW 52592, 'Slovar poti Nowodvorskega ni v celoti prenesen.', 1;

IF NOT EXISTS
(
  SELECT 1 FROM canon.CategoryPathTranslated
  WHERE CategoryTreeCode = N'svetila_si' AND LanguageCode = N'en' AND CategoryPath LIKE N'%>%'
)
  THROW 52593, 'Angleska pot kategorije se ne sestavi.', 1;

IF (SELECT COUNT(*) FROM out.ExportColumn
    WHERE ExportProfileId = @ProductProfileId AND IsActive = 1
      AND CanonicalFieldCode IN (N'Product.CategorySvetilaEn', N'Product.CategorySvetilaSl')) <> 2
  THROW 52594, 'Stolpca 24 in 25 nista dobila vira.', 1;
