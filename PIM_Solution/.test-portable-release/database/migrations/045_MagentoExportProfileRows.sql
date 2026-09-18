/*
  045 — Magento predloga se preseli iz C# v register out.ExportProfile / out.ExportColumn.

  Zakaj: kateri stolpec stoji kje in kaj vanj pride, je bilo doslej zapisano v kodi —
  seznam 215 glav v PIM.B2b.MagentoCsvContract in preslikava indeks->kanonicna koda kot
  switch v workers/PIM.B2bWorker/MagentoProductSchema.cs. Nov spletni kanal ali samo
  premaknjen stolpec sta zato zahtevala spremembo programa in novo namestitev. Register
  za to ze obstaja od migracije 005 in ima natanko pravo obliko; do zdaj v njem Magento
  profila preprosto ni bilo.

  Po tej migraciji je resnica v bazi:
    - nov kanal      = nova vrstica out.ExportProfile + njene vrstice out.ExportColumn,
    - premik stolpca = UPDATE SortOrder,
    - drug vir polja = UPDATE CanonicalFieldCode,
    - stolpec ven    = UPDATE IsActive = 0.
  Nic od tega ni vec sprememba kode.

  Kaj ostane v kodi: poizvedbe, ki *proizvedejo* kanonicne vrednosti (Product.ItemID,
  Product.PriceB2C, Attr.<koda> ...). Register pove, kam gredo, ne kako nastanejo.

  Vrstice so posejane natanko iz obstojece kode, znak za znak, vkljucno s koncnim
  presledkom v glavi 73 ('Enota visine stropne kapice ') — predloga Magenta je zunanja
  pogodba in je test PIM.F7.MagentoExportTests primerja z bazo.

  Dve stvari, ki ju register naredi vidni in ju NE popravlja (to bi bila poslovna
  odlocitev, ne migracija):
    1. Glava 'Frekvenca' se v predlogi pojavi dvakrat (stolpca 58 in 122). Oba dobita
       isto kanonicno kodo Attr.Frekvenca in torej isto vrednost. Doslej je bilo to
       skrito v izrazu 'Attr.' + glava; zdaj se vidi kot dve vrstici in se popravi z
       enim UPDATE, ko bo znano, kaj naj bo v drugem.
    2. Stolpca 24 in 25 ('Kategorije svetila ANG/SLO') sta brez kanonicne kode, ker
       zanju ni vzora; enako 162 atributnih stolpcev nima vira, dokler v map.FieldMapping
       ne obstaja preslikava ProductAttribute.<glava>. Prazna CanonicalFieldCode pomeni
       'stolpec obstaja, vir zanj ni dolocen' — izvoz ga izpise praznega, napacne
       vrednosti pa ne izmisli.

  Migracija samo dodaja: obstojecih vrstic ne prepisuje (WHEN NOT MATCHED THEN INSERT),
  zato rocna sprememba registra prezivi ponoven zagon.
*/

SET XACT_ABORT ON;

/* --- 1) profila ---------------------------------------------------------- */

MERGE out.ExportProfile AS target
USING (VALUES
  (N'MAGENTO_PRODUCTS',  N'Magento - izdelki (predloga 215 stolpcev)', N'MAGENTO', N'PRODUCTS'),
  (N'MAGENTO_CUSTOMERS', N'Magento - stranke (predloga 19 stolpcev)',  N'MAGENTO', N'CUSTOMERS')
) AS source(ProfileCode, Name, ChannelCode, EntityType)
  ON target.ProfileCode = source.ProfileCode
WHEN NOT MATCHED THEN
  INSERT (ProfileCode, Name, ChannelCode, EntityType, IsActive)
  VALUES (source.ProfileCode, source.Name, source.ChannelCode, source.EntityType, 1);

DECLARE @ProductProfileId int =
  (SELECT ExportProfileId FROM out.ExportProfile WHERE ProfileCode = N'MAGENTO_PRODUCTS');
DECLARE @CustomerProfileId int =
  (SELECT ExportProfileId FROM out.ExportProfile WHERE ProfileCode = N'MAGENTO_CUSTOMERS');

IF @ProductProfileId IS NULL OR @CustomerProfileId IS NULL
  THROW 52350, 'Magento izvozna profila nista nastala.', 1;

/* --- 2) 215 stolpcev izdelkov -------------------------------------------- */

MERGE out.ExportColumn AS target
USING (VALUES
  (N'COL001', N'Šifra artikla', N'Product.ItemID', 1),
  (N'COL002', N'EAN', N'Product.EAN', 2),
  (N'COL003', N'Spletne strani', N'Product.WebSites', 3),
  (N'COL004', N'Naziv artikla EN', N'Product.WebTitleEn', 4),
  (N'COL005', N'Naziv artikla', N'Product.WebTitleSl', 5),
  (N'COL006', N'Proizvajalec', N'Product.Manufacturer', 6),
  (N'COL007', N'Dobavitelj', N'', 7),
  (N'COL008', N'ABC klasifikacija', N'', 8),
  (N'COL009', N'Merska enota', N'', 9),
  (N'COL010', N'Oznaka tarifa', N'Product.CustomsTariff', 10),
  (N'COL011', N'Država proizvoda', N'Product.CountryOfOrigin', 11),
  (N'COL012', N'Bruto teža', N'Product.GrossWeight', 12),
  (N'COL013', N'Enota bruto teže', N'', 13),
  (N'COL014', N'Neto teža', N'Product.NetWeight', 14),
  (N'COL015', N'Enota neto teže', N'', 15),
  (N'COL016', N'Volumen', N'', 16),
  (N'COL017', N'Enota volumna', N'', 17),
  (N'COL018', N'Dolžina paketa', N'', 18),
  (N'COL019', N'Enota dolžine paketa', N'', 19),
  (N'COL020', N'Širina paketa', N'', 20),
  (N'COL021', N'Enota širine paketa', N'', 21),
  (N'COL022', N'Višina paketa', N'', 22),
  (N'COL023', N'Enota višine paketa', N'', 23),
  (N'COL024', N'Kategorije svetila ANG', N'', 24),
  (N'COL025', N'Kategorije svetila SLO', N'', 25),
  (N'COL026', N'Kategorije vid ANG', N'Product.CategoryEn', 26),
  (N'COL027', N'Kategorije vid SLO', N'Product.CategorySl', 27),
  (N'COL028', N'Cena B2B', N'Product.PriceB2B', 28),
  (N'COL029', N'Cena B2C', N'Product.PriceB2C', 29),
  (N'COL030', N'Popust', N'', 30),
  (N'COL031', N'Valuta', N'', 31),
  (N'COL032', N'DDV', N'Product.VatRate', 32),
  (N'COL033', N'PAK2', N'Product.Pak2', 33),
  (N'COL034', N'Omejitev pri naročanju', N'', 34),
  (N'COL035', N'Skupina popusta', N'Product.PackagingDiscountCode', 35),
  (N'COL036', N'S popust %', N'Product.PackagingDiscountPercent', 36),
  (N'COL037', N'Posebni popust za stranko', N'', 37),
  (N'COL038', N'Glavna slika', N'Product.MainImage', 38),
  (N'COL039', N'Ostale slike', N'Product.OtherImages', 39),
  (N'COL040', N'Glavni dokument', N'', 40),
  (N'COL041', N'Vloge dokumentov', N'', 41),
  (N'COL042', N'Ostali dokumenti', N'', 42),
  (N'COL043', N'VID trenutna zaloga', N'', 43),
  (N'COL044', N'VID naročena količina', N'', 44),
  (N'COL045', N'VID količina za odpremo', N'', 45),
  (N'COL046', N'VID razpoložljiva količina', N'', 46),
  (N'COL047', N'VID naročena količina dobaviteljem', N'', 47),
  (N'COL048', N'VID datum dobave', N'', 48),
  (N'COL049', N'VID koli. prihodnjih dobav', N'', 49),
  (N'COL050', N'Dobavitelj zaloga', N'', 50),
  (N'COL051', N'Dobavitelj naročena zaloga', N'', 51),
  (N'COL052', N'Dobavitelj datum', N'', 52),
  (N'COL053', N'Skladišče', N'', 53),
  (N'COL054', N'Grlo ANG', N'Attr.Grlo ANG', 54),
  (N'COL055', N'Grlo SLO', N'Attr.Grlo SLO', 55),
  (N'COL056', N'Svetilka vključuje svetlobni vir', N'Attr.Svetilka vključuje svetlobni vir', 56),
  (N'COL057', N'Senzor gibanja', N'Attr.Senzor gibanja', 57),
  (N'COL058', N'Frekvenca', N'Attr.Frekvenca', 58),
  (N'COL059', N'Max moč sijalke', N'Attr.Max moč sijalke', 59),
  (N'COL060', N'Garancija', N'Attr.Garancija', 60),
  (N'COL061', N'Zračni pretok', N'Attr.Zračni pretok', 61),
  (N'COL062', N'Uporaba ANG', N'Attr.Uporaba ANG', 62),
  (N'COL063', N'Uporaba SLO', N'Attr.Uporaba SLO', 63),
  (N'COL064', N'Način montaže ANG', N'Attr.Način montaže ANG', 64),
  (N'COL065', N'Način montaže SLO', N'Attr.Način montaže SLO', 65),
  (N'COL066', N'Simbol atributa', N'Attr.Simbol atributa', 66),
  (N'COL067', N'Baterija', N'Attr.Baterija', 67),
  (N'COL068', N'Kapaciteta baterije', N'Attr.Kapaciteta baterije', 68),
  (N'COL069', N'Kot svetlobnega snopa', N'Attr.Kot svetlobnega snopa', 69),
  (N'COL070', N'Enota kota svetlobnega snopa', N'Attr.Enota kota svetlobnega snopa', 70),
  (N'COL071', N'Presek kabla', N'Attr.Presek kabla', 71),
  (N'COL072', N'Višina stropne kapice', N'Attr.Višina stropne kapice', 72),
  (N'COL073', N'Enota višine stropne kapice ', N'Attr.Enota višine stropne kapice', 73),
  (N'COL074', N'Širina stropne kapice', N'Attr.Širina stropne kapice', 74),
  (N'COL075', N'Enota širine stropne kapice', N'Attr.Enota širine stropne kapice', 75),
  (N'COL076', N'Čas polnjenja', N'Attr.Čas polnjenja', 76),
  (N'COL077', N'Način polnjenja ANG', N'Attr.Način polnjenja ANG', 77),
  (N'COL078', N'Način polnjenja SLO', N'Attr.Način polnjenja SLO', 78),
  (N'COL079', N'Nazivna jakost toka', N'Attr.Nazivna jakost toka', 79),
  (N'COL080', N'Nazivna napetost', N'Attr.Nazivna napetost', 80),
  (N'COL081', N'Nazivna moč', N'Attr.Nazivna moč', 81),
  (N'COL082', N'Kolekcija', N'Attr.Kolekcija', 82),
  (N'COL083', N'Temperatura barve', N'Attr.Temperatura barve', 83),
  (N'COL084', N'Komentarji', N'Attr.Komentarji', 84),
  (N'COL085', N'Dopolnilna barva I ANG', N'Attr.Dopolnilna barva I ANG', 85),
  (N'COL086', N'Dopolnilna barva I SLO', N'Attr.Dopolnilna barva I SLO', 86),
  (N'COL087', N'Dopolnilna barva II ANG', N'Attr.Dopolnilna barva II ANG', 87),
  (N'COL088', N'Dopolnilna barva II SLO', N'Attr.Dopolnilna barva II SLO', 88),
  (N'COL089', N'Dopolnilni simbol tkanine iz vzorčne škatle I', N'Attr.Dopolnilni simbol tkanine iz vzorčne škatle I', 89),
  (N'COL090', N'Dopolnilni material I ANG', N'Attr.Dopolnilni material I ANG', 90),
  (N'COL091', N'Dopolnilni material I SLO', N'Attr.Dopolnilni material I SLO', 91),
  (N'COL092', N'Dopolnilni material II ANG', N'Attr.Dopolnilni material II ANG', 92),
  (N'COL093', N'Dopolnilni material II SLO', N'Attr.Dopolnilni material II SLO', 93),
  (N'COL094', N'Dopolnilni material III ANG', N'Attr.Dopolnilni material III ANG', 94),
  (N'COL095', N'Dopolnilni material III SLO', N'Attr.Dopolnilni material III SLO', 95),
  (N'COL096', N'Indeks barvnega videza (CRI)', N'Attr.Indeks barvnega videza (CRI)', 96),
  (N'COL097', N'Vrsta toka', N'Attr.Vrsta toka', 97),
  (N'COL098', N'Izvrtina (cutout)', N'Attr.Izvrtina (cutout)', 98),
  (N'COL099', N'Kot detekcije', N'Attr.Kot detekcije', 99),
  (N'COL100', N'Razdalja detekcije', N'Attr.Razdalja detekcije', 100),
  (N'COL101', N'Hitrost detekcije', N'Attr.Hitrost detekcije', 101),
  (N'COL102', N'Premer', N'Attr.Premer', 102),
  (N'COL103', N'Višina', N'Attr.Višina', 103),
  (N'COL104', N'Enota višine', N'Attr.Enota višine', 104),
  (N'COL105', N'Dolžina', N'Attr.Dolžina', 105),
  (N'COL106', N'Enota dolžine ', N'Attr.Enota dolžine', 106),
  (N'COL107', N'Širina', N'Attr.Širina', 107),
  (N'COL108', N'Enota širine', N'Attr.Enota širine', 108),
  (N'COL109', N'Zatemnljivo ANG', N'Attr.Zatemnljivo ANG', 109),
  (N'COL110', N'Zatemnljivo SLO', N'Attr.Zatemnljivo SLO', 110),
  (N'COL111', N'Razdalja od stene', N'Attr.Razdalja od stene', 111),
  (N'COL112', N'Enota razdalje od stene ', N'Attr.Enota razdalje od stene', 112),
  (N'COL113', N'EAN koda', N'Attr.EAN koda', 113),
  (N'COL114', N'Električni razred ANG', N'Attr.Električni razred ANG', 114),
  (N'COL115', N'Režim nujne osvetlitve ANG', N'Attr.Režim nujne osvetlitve ANG', 115),
  (N'COL116', N'Režim nujne osvetlitve SLO', N'Attr.Režim nujne osvetlitve SLO', 116),
  (N'COL117', N'Energijski razred', N'Attr.Energijski razred', 117),
  (N'COL118', N'Ekvivalent', N'Attr.Ekvivalent', 118),
  (N'COL119', N'Simbol tkanine iz vzorčne škatle', N'Attr.Simbol tkanine iz vzorčne škatle', 119),
  (N'COL120', N'Svetlobni tok', N'Attr.Svetlobni tok', 120),
  (N'COL121', N'Enota svetlobnega toka', N'Attr.Enota svetlobnega toka', 121),
  (N'COL122', N'Frekvenca', N'Attr.Frekvenca', 122),
  (N'COL123', N'Enota frekvence', N'Attr.Enota frekvence', 123),
  (N'COL124', N'Bruto teža (2)', N'Attr.Bruto teža (2)', 124),
  (N'COL125', N'Enota bruto teže', N'Attr.Enota bruto teže', 125),
  (N'COL126', N'Nastavitev višine ', N'Attr.Nastavitev višine', 126),
  (N'COL127', N'Razpon nastavitve višine', N'Attr.Razpon nastavitve višine', 127),
  (N'COL128', N'Enota razpona nastavitve višine ', N'Attr.Enota razpona nastavitve višine', 128),
  (N'COL129', N'Višina daljše roke', N'Attr.Višina daljše roke', 129),
  (N'COL130', N'Enota višine daljše roke ', N'Attr.Enota višine daljše roke', 130),
  (N'COL131', N'Višina senčnika reflektorja', N'Attr.Višina senčnika reflektorja', 131),
  (N'COL132', N'Enota višine senčnika reflektorja', N'Attr.Enota višine senčnika reflektorja', 132),
  (N'COL133', N'Višina krajše roke', N'Attr.Višina krajše roke', 133),
  (N'COL134', N'Enota višine krajše roke', N'Attr.Enota višine krajše roke', 134),
  (N'COL135', N'Dimenzije odprtine', N'Attr.Dimenzije odprtine', 135),
  (N'COL136', N'Enota dimenzij odprtine', N'Attr.Enota dimenzij odprtine', 136),
  (N'COL137', N'Oblika odprtine ANG', N'Attr.Oblika odprtine ANG', 137),
  (N'COL138', N'Oblika odprtine SLO', N'Attr.Oblika odprtine SLO', 138),
  (N'COL139', N'Ikone', N'Attr.Ikone', 139),
  (N'COL140', N'IK stopnja', N'Attr.IK stopnja', 140),
  (N'COL141', N'Montažna višina', N'Attr.Montažna višina', 141),
  (N'COL142', N'IP stopnja zaščite', N'Attr.IP stopnja zaščite', 142),
  (N'COL143', N'Oblika svetilke ANG', N'Attr.Oblika svetilke ANG', 143),
  (N'COL144', N'Oblika svetilke SLO', N'Attr.Oblika svetilke SLO', 144),
  (N'COL145', N'Prevladujoča barva ANG', N'Attr.Prevladujoča barva ANG', 145),
  (N'COL146', N'Prevladujoča barva SLO', N'Attr.Prevladujoča barva SLO', 146),
  (N'COL147', N'Prevladujoč material ANG', N'Attr.Prevladujoč material ANG', 147),
  (N'COL148', N'Prevladujoč material SLO', N'Attr.Prevladujoč material SLO', 148),
  (N'COL149', N'Dolžina podnožja', N'Attr.Dolžina podnožja', 149),
  (N'COL150', N'Enota dolžine podnožja ', N'Attr.Enota dolžine podnožja', 150),
  (N'COL151', N'Dolžina horizontalne roke', N'Attr.Dolžina horizontalne roke', 151),
  (N'COL152', N'Enota dolžine horizontalne roke ', N'Attr.Enota dolžine horizontalne roke', 152),
  (N'COL153', N'Dolžina senčnika', N'Attr.Dolžina senčnika', 153),
  (N'COL154', N'Enota dolžine senčnika ', N'Attr.Enota dolžine senčnika', 154),
  (N'COL155', N'Dolžina vertikalne roke', N'Attr.Dolžina vertikalne roke', 155),
  (N'COL156', N'Enota dolžine vertikalne roke', N'Attr.Enota dolžine vertikalne roke', 156),
  (N'COL157', N'Življenjska doba', N'Attr.Življenjska doba', 157),
  (N'COL158', N'Vrsta svetlobnega vira ANG', N'Attr.Vrsta svetlobnega vira ANG', 158),
  (N'COL159', N'Vrsta svetlobnega vira SLO', N'Attr.Vrsta svetlobnega vira SLO', 159),
  (N'COL160', N'Luks', N'Attr.Luks', 160),
  (N'COL161', N'Model', N'Attr.Model', 161),
  (N'COL162', N'Vrtenje motorja', N'Attr.Vrtenje motorja', 162),
  (N'COL163', N'Neto teža (2)', N'Attr.Neto teža (2)', 163),
  (N'COL164', N'Enota neto teže', N'Attr.Enota neto teže', 164),
  (N'COL165', N'Hrup', N'Attr.Hrup', 165),
  (N'COL166', N'Število svetlobnih segmentov', N'Attr.Število svetlobnih segmentov', 166),
  (N'COL167', N'Število svetlobnih virov', N'Attr.Število svetlobnih virov', 167),
  (N'COL168', N'Število paketov', N'Attr.Število paketov', 168),
  (N'COL169', N'Število ciklov polnjenja', N'Attr.Število ciklov polnjenja', 169),
  (N'COL170', N'PCN', N'Attr.PCN', 170),
  (N'COL171', N'Kosov na karton', N'Attr.Kosov na karton', 171),
  (N'COL172', N'Višina paketa I', N'Attr.Višina paketa I', 172),
  (N'COL173', N'Višina paketa II', N'Attr.Višina paketa II', 173),
  (N'COL174', N'Višina paketa III', N'Attr.Višina paketa III', 174),
  (N'COL175', N'Enota višine paketa I', N'Attr.Enota višine paketa I', 175),
  (N'COL176', N'Enota višine paketa II ', N'Attr.Enota višine paketa II', 176),
  (N'COL177', N'Enota višine paketa III ', N'Attr.Enota višine paketa III', 177),
  (N'COL178', N'Dolžina paketa I', N'Attr.Dolžina paketa I', 178),
  (N'COL179', N'Dolžina paketa II', N'Attr.Dolžina paketa II', 179),
  (N'COL180', N'Dolžina paketa III', N'Attr.Dolžina paketa III', 180),
  (N'COL181', N'Enota dolžine paketa I ', N'Attr.Enota dolžine paketa I', 181),
  (N'COL182', N'Enota dolžine paketa II ', N'Attr.Enota dolžine paketa II', 182),
  (N'COL183', N'Enota dolžine paketa III ', N'Attr.Enota dolžine paketa III', 183),
  (N'COL184', N'Volumen paketa', N'Attr.Volumen paketa', 184),
  (N'COL185', N'Enota volumna paketa', N'Attr.Enota volumna paketa', 185),
  (N'COL186', N'Širina paketa I', N'Attr.Širina paketa I', 186),
  (N'COL187', N'Širina paketa II', N'Attr.Širina paketa II', 187),
  (N'COL188', N'Širina paketa III', N'Attr.Širina paketa III', 188),
  (N'COL189', N'Enota širine paketa I ', N'Attr.Enota širine paketa I', 189),
  (N'COL190', N'Enota širine paketa II ', N'Attr.Enota širine paketa II', 190),
  (N'COL191', N'Enota širine paketa III ', N'Attr.Enota širine paketa III', 191),
  (N'COL192', N'Faktor moči', N'Attr.Faktor moči', 192),
  (N'COL193', N'Ime izdelka', N'Attr.Ime izdelka', 193),
  (N'COL194', N'Razdelitev na segmente', N'Attr.Razdelitev na segmente', 194),
  (N'COL195', N'Velikost', N'Attr.Velikost', 195),
  (N'COL196', N'Podnožje / socket', N'Attr.Podnožje / socket', 196),
  (N'COL197', N'Dolžina spuščenega stropa', N'Attr.Dolžina spuščenega stropa', 197),
  (N'COL198', N'Enota dolžine spuščenega stropa ', N'Attr.Enota dolžine spuščenega stropa', 198),
  (N'COL199', N'Solarni panel', N'Attr.Solarni panel', 199),
  (N'COL200', N'Solarna moč', N'Attr.Solarna moč', 200),
  (N'COL201', N'Slog ANG', N'Attr.Slog ANG', 201),
  (N'COL202', N'Slog SLO', N'Attr.Slog SLO', 202),
  (N'COL203', N'Tehnična opomba', N'Attr.Tehnična opomba', 203),
  (N'COL204', N'Časovna zakasnitev', N'Attr.Časovna zakasnitev', 204),
  (N'COL205', N'Vrsta kabla', N'Attr.Vrsta kabla', 205),
  (N'COL206', N'Video', N'Attr.Video', 206),
  (N'COL207', N'Napetost', N'Attr.Napetost', 207),
  (N'COL208', N'Enota napetosti', N'Attr.Enota napetosti', 208),
  (N'COL209', N'Širina podnožja', N'Attr.Širina podnožja', 209),
  (N'COL210', N'Enota širine podnožja ', N'Attr.Enota širine podnožja', 210),
  (N'COL211', N'Širina senčnika reflektorja', N'Attr.Širina senčnika reflektorja', 211),
  (N'COL212', N'Enota širine senčnika reflektorja', N'Attr.Enota širine senčnika reflektorja', 212),
  (N'COL213', N'Delovna temperatura', N'Attr.Delovna temperatura', 213),
  (N'COL214', N'Delovni čas', N'Attr.Delovni čas', 214),
  (N'COL215', N'Združljivo z', N'Attr.Združljivo z', 215)
) AS source(ColumnCode, OutputColumnName, CanonicalFieldCode, SortOrder)
  ON target.ExportProfileId = @ProductProfileId AND target.ColumnCode = source.ColumnCode
WHEN NOT MATCHED THEN
  INSERT (ExportProfileId, ColumnCode, OutputColumnName, CanonicalFieldCode, SortOrder, IsRequired, IsActive)
  VALUES (@ProductProfileId, source.ColumnCode, source.OutputColumnName, source.CanonicalFieldCode, source.SortOrder, 0, 1);

/* --- 3) 19 stolpcev strank ----------------------------------------------- */

MERGE out.ExportColumn AS target
USING (VALUES
  (N'CUC01', N'Šifra stranke', N'Customer.Key', 1),
  (N'CUC02', N'Naziv', N'Customer.Name', 2),
  (N'CUC03', N'E-pošta', N'', 3),
  (N'CUC04', N'Tel. številko', N'', 4),
  (N'CUC05', N'Uporabniki', N'', 5),
  (N'CUC06', N'Skupina (Magento)', N'Customer.MagentoGroup', 6),
  (N'CUC07', N'Cenik', N'Customer.PriceList', 7),
  (N'CUC08', N'Plačnik', N'Customer.Payer', 8),
  (N'CUC09', N'Popust polno pakiranje', N'Customer.PackagingDiscountEnabled', 9),
  (N'CUC10', N'Vrednostni rabat', N'Customer.ValueDiscountEnabled', 10),
  (N'CUC11', N'Rabat prag 1', N'Customer.Tier1Threshold', 11),
  (N'CUC12', N'Rabat % 1', N'Customer.Tier1Percent', 12),
  (N'CUC13', N'Rabat prag 2', N'Customer.Tier2Threshold', 13),
  (N'CUC14', N'Rabat % 2', N'Customer.Tier2Percent', 14),
  (N'CUC15', N'Rabat prag 3', N'Customer.Tier3Threshold', 15),
  (N'CUC16', N'Rabat % 3', N'Customer.Tier3Percent', 16),
  (N'CUC17', N'B2B+', N'Customer.B2bPlus', 17),
  (N'CUC18', N'Skupine popustov', N'Customer.GroupDiscounts', 18),
  (N'CUC19', N'Popust NW', N'Customer.NwDiscount', 19)
) AS source(ColumnCode, OutputColumnName, CanonicalFieldCode, SortOrder)
  ON target.ExportProfileId = @CustomerProfileId AND target.ColumnCode = source.ColumnCode
WHEN NOT MATCHED THEN
  INSERT (ExportProfileId, ColumnCode, OutputColumnName, CanonicalFieldCode, SortOrder, IsRequired, IsActive)
  VALUES (@CustomerProfileId, source.ColumnCode, source.OutputColumnName, source.CanonicalFieldCode, source.SortOrder, 0, 1);

/* --- 4) varovalka: register mora imeti natanko toliko stolpcev, kot jih ima predloga --- */

IF (SELECT COUNT(*) FROM out.ExportColumn WHERE ExportProfileId = @ProductProfileId AND IsActive = 1) <> 215
  THROW 52351, 'Profil MAGENTO_PRODUCTS nima 215 aktivnih stolpcev.', 1;
IF (SELECT COUNT(*) FROM out.ExportColumn WHERE ExportProfileId = @CustomerProfileId AND IsActive = 1) <> 19
  THROW 52352, 'Profil MAGENTO_CUSTOMERS nima 19 aktivnih stolpcev.', 1;
