/*
  Rocno napisani slovenski opisi (DESCRIPTION.sl) za 16 izdelkov Nowodvorski,
  ki so po migraciji 041 in scripts/seed_web_titles.sql veljavni po WEB_B2C.

  NI migracija. Podatki o izdelkih, ne shema. Rocni zagon, idempotenten -
  pise samo tja, kjer opisa se ni, obstojecih nikoli ne prepise.

  Zagon zaradi sumnikov obvezno s kodno stranjo UTF-8:
    sqlcmd -S "localhost\MSSQLSERVER3" -d PIM -E -f 65001 -i scripts\seed_descriptions_nw16.sql

  IZVOR VSAKEGA PODATKA: PIM_Solution\fixtures\nw\products_en_US.xml, veja
  <attributes> pripadajocega <product> (ujemanje po EAN). Nobena specifikacija
  ni izmisljena in nobena ni prevzeta iz drugega izdelka. Kjer dobavitelj
  podatka nima, ga opis ne omenja.

  KAJ OPISI NAMENOMA NE VSEBUJEJO:
  - Mer embalaze (Package height / Width packaging / Length packing). To so
    dimenzije skatle, ne izdelka; kupca bi zavedle. Izjema so tračnice
    NW.9448/9451/9452, kjer je Length packing dejanska dolzina tračnice
    (100 oziroma 200 cm) in to potrjuje ze naziv izdelka (TRACK 1 M / 2 M).
  - Trzenjskih trditev, ocen kakovosti in priporocil za uporabo, ki jih v
    podatkih dobavitelja ni.

  Razveljavitev:
    DELETE FROM canon.ProductText
    WHERE TextType = N'DESCRIPTION' AND Lang = N'sl'
      AND ProductId IN (SELECT ProductId FROM canon.Product WHERE ItemID LIKE N'NW.%');
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Description TABLE (ItemID nvarchar(100) PRIMARY KEY, Value nvarchar(max));

INSERT @Description (ItemID, Value) VALUES

(N'NW.8911',
 N'Nadometna reflektorska svetilka EYE S iz masivne medenine v medeninasti barvi. '
 + N'Sprejme en zamenljiv svetlobni vir GU10 R50 z močjo do 10 W (samo LED); '
 + N'žarnica ni priložena. Zaščita IP20 jo omejuje na suhe notranje prostore. '
 + N'Priklop 220-230 V, 50/60 Hz, razred zaščite I. Montaža je neposredna na podlago.'),

(N'NW.8945',
 N'Viseča stropna svetilka TURDA s tekstilnim senčnikom v kremni barvi (tkanina T023) '
 + N'in belo notranjostjo (T002). Senčnik meri 50 cm v širino in 14 cm v višino, '
 + N'dopolnjujeta ga plastika in lakirano jeklo. Sprejme tri zamenljive svetlobne vire '
 + N'E27 z močjo do 15 W (samo LED); žarnice niso priložene. Stropna rozeta meri '
 + N'5,5 cm v premeru in 7,5 cm v višino. Višino obesitve lahko prilagodi usposobljen '
 + N'elektrikar. Priklop 220-230 V, 50/60 Hz, razred zaščite I, zaščita IP20 za suhe '
 + N'notranje prostore. Pritrditev z nosilcem.'),

(N'NW.8953',
 N'Stropna plafonjera TURDA s tekstilnim senčnikom v sivi barvi (tkanina T024) '
 + N'in belo notranjostjo (T002). Senčnik meri 50 cm v širino in 13 cm v višino, '
 + N'dopolnjujeta ga plastika in lakirano jeklo. Sprejme tri zamenljive svetlobne vire '
 + N'E27 z močjo do 15 W (samo LED); žarnice niso priložene. Priklop 220-230 V, '
 + N'50/60 Hz, razred zaščite I, zaščita IP20 za suhe notranje prostore. '
 + N'Montaža je neposredna na strop.'),

(N'NW.8958',
 N'Stropna plafonjera TURDA s tekstilnim senčnikom v kremni barvi (tkanina T023) '
 + N'in belo notranjostjo (T002). Senčnik meri 78 cm v širino in 15 cm v višino, '
 + N'dopolnjujeta ga plastika in lakirano jeklo. Sprejme sedem zamenljivih svetlobnih '
 + N'virov E27 z močjo do 15 W (samo LED), razporejenih v dva sklopa v razmerju 3/4; '
 + N'žarnice niso priložene. Priklop 220-230 V, 50/60 Hz, razred zaščite I, '
 + N'zaščita IP20 za suhe notranje prostore. Montaža je neposredna na strop.'),

(N'NW.8996',
 N'Tirna reflektorska svetilka PROFILE IRIS z vgrajenim LED virom moči 7 W. '
 + N'Svetlobni tok znaša 530 lm pri barvni temperaturi 3000 K, indeks barvne '
 + N'reprodukcije je nad 80, kot snopa 30 stopinj, faktor moči nad 0,5. '
 + N'Deklarirana življenjska doba je 30000 ur. Ohišje je iz lakiranega aluminija '
 + N'v črni barvi, dopolnjeno s plastiko PC. Svetlobni vir je vgrajen in ni zamenljiv. '
 + N'Priklop 220-230 V, 50/60 Hz, razred zaščite II, zaščita IP20. '
 + N'Združljiva s tirnim sistemom Profile.'),

(N'NW.9068',
 N'Stenska reflektorska svetilka EYE FLEX S z gibljivim krakom, ki omogoča odmik '
 + N'od stene med 17 in 32,5 cm. Glava svetilke meri 5,5 cm v širino in 9,6 cm v višino. '
 + N'Ohišje je iz lakiranega jekla v črni barvi. Sprejme en zamenljiv svetlobni vir '
 + N'GU10 R50 z močjo do 10 W (samo LED); žarnica ni priložena. Priklop 220-230 V, '
 + N'50/60 Hz, razred zaščite I, zaščita IP20 za suhe notranje prostore. '
 + N'Pritrditev z nosilcem.'),

(N'NW.9173',
 N'LED sijalka z navojem G9 in močjo 3 W. Svetlobni tok znaša 330 lm pri barvni '
 + N'temperaturi 3000 K, indeks barvne reprodukcije je najmanj 80, kot snopa '
 + N'90 stopinj, faktor moči nad 0,5. Deklarirana življenjska doba je 25000 ur, '
 + N'razred energijske učinkovitosti F. Ohišje je keramično, z lečko iz plastike PC, '
 + N'v beli barvi. Priklop 220-230 V, 50/60 Hz, zaščita IP20.'),

(N'NW.9448',
 N'Enokrogotokovna tračnica PROFILE dolžine 1 m iz lakiranega aluminija v črni barvi. '
 + N'Osnovni gradnik tirnega sistema Profile, na katerega se nameščajo tirne svetilke. '
 + N'Nadometna montaža. Priklop 220-230 V, 50/60 Hz, razred zaščite I, zaščita IP20 '
 + N'za suhe notranje prostore.'),

(N'NW.9451',
 N'Enokrogotokovna tračnica PROFILE dolžine 2 m iz lakiranega aluminija v beli barvi. '
 + N'Osnovni gradnik tirnega sistema Profile, na katerega se nameščajo tirne svetilke. '
 + N'Nadometna montaža. Priklop 220-230 V, 50/60 Hz, razred zaščite I, zaščita IP20 '
 + N'za suhe notranje prostore.'),

(N'NW.9452',
 N'Enokrogotokovna tračnica PROFILE dolžine 2 m iz lakiranega aluminija v črni barvi. '
 + N'Osnovni gradnik tirnega sistema Profile, na katerega se nameščajo tirne svetilke. '
 + N'Nadometna montaža. Priklop 220-230 V, 50/60 Hz, razred zaščite I, zaščita IP20 '
 + N'za suhe notranje prostore.'),

(N'NW.9457',
 N'Končni pokrovček PROFILE iz plastike PC v beli barvi. Zapira prosti konec tračnice '
 + N'tirnega sistema Profile in nima električne funkcije. Dodatek k tirnemu sistemu '
 + N'Profile.'),

(N'NW.9458',
 N'Končni pokrovček PROFILE iz plastike PC v črni barvi. Zapira prosti konec tračnice '
 + N'tirnega sistema Profile in nima električne funkcije. Dodatek k tirnemu sistemu '
 + N'Profile.'),

(N'NW.9463',
 N'Napajalni končni kos PROFILE v črni barvi, prek katerega se tračnica tirnega '
 + N'sistema Profile priključi na električno omrežje. Ohišje je iz plastike PC, '
 + N'z jeklenimi in bakrenimi sestavnimi deli. Priklop 220-230 V, 50/60 Hz, '
 + N'razred zaščite I, zaščita IP20 za suhe notranje prostore.'),

(N'NW.9517',
 N'Zunanja stenska svetilka NICO iz lakiranega aluminija v grafitni barvi, '
 + N'dopolnjena s steklom. Sveti navzgor in navzdol prek dveh zamenljivih svetlobnih '
 + N'virov GU10 R50 z močjo do 10 W (samo LED); žarnici nista priloženi. '
 + N'Odmik od stene znaša 9,5 cm. Zaščita IP54 omogoča uporabo na prostem. '
 + N'Priklop 220-230 V, 50/60 Hz, razred zaščite I. Montaža je neposredna na steno.'),

(N'NW.9607',
 N'Viseča zunanja svetilka CUMULUS L s senčnikom iz plastike PE v beli barvi, '
 + N'z deli iz lakiranega jekla. Senčnik meri 60 cm v širino in 53 cm v višino, '
 + N'stropna rozeta 10 cm v premeru in 3 cm v višino. Višino obesitve je mogoče '
 + N'nastaviti med 98 in 140 cm; prilagoditev opravi usposobljen elektrikar. '
 + N'Sprejme en zamenljiv svetlobni vir E27 z močjo do 25 W (samo LED); žarnica ni '
 + N'priložena. Zaščita IP65 omogoča uporabo na prostem, obratovalno temperaturno '
 + N'območje je od -23 °C do +40 °C. Priklop 220-230 V, 50/60 Hz, razred zaščite II. '
 + N'Pritrditev z nosilcem.'),

(N'NW.9715',
 N'Viseča zunanja svetilka CUMULUS M s senčnikom iz plastike PE v beli barvi, '
 + N'z deli iz lakiranega jekla in prosojnimi elementi. Senčnik meri 45 cm v širino '
 + N'in 40 cm v višino, stropna rozeta 10 cm v premeru in 3 cm v višino. Višino '
 + N'obesitve je mogoče nastaviti med 98 in 140 cm; prilagoditev opravi usposobljen '
 + N'elektrikar. Sprejme en zamenljiv svetlobni vir E27 z močjo do 25 W (samo LED); '
 + N'žarnica ni priložena. Zaščita IP65 omogoča uporabo na prostem, obratovalno '
 + N'temperaturno območje je od -23 °C do +40 °C. Priklop 220-230 V, 50/60 Hz, '
 + N'razred zaščite II. Pritrditev z nosilcem.');

DECLARE @Expected int = (SELECT COUNT(*) FROM @Description);
PRINT CONCAT(N'Pripravljenih opisov: ', @Expected);

/* Vsak ItemID se mora ujemati z natanko enim izdelkom, sicer je nekaj narobe
   in ne zelimo tihega delnega vpisa. */
DECLARE @Matched int =
(
  SELECT COUNT(*)
  FROM @Description description
  INNER JOIN canon.Product product ON product.ItemID = description.ItemID
);

IF @Matched <> @Expected
BEGIN
  RAISERROR(N'Ujemanje ItemID ni ena na ena: pricakovano %d, najdeno %d. Nic ni vpisano.', 16, 1, @Expected, @Matched);
  RETURN;
END;

INSERT canon.ProductText (ProductId, Lang, TextType, Value)
SELECT product.ProductId, N'sl', N'DESCRIPTION', description.Value
FROM @Description description
INNER JOIN canon.Product product ON product.ItemID = description.ItemID
WHERE NOT EXISTS
(
  SELECT 1 FROM canon.ProductText existing
  WHERE existing.ProductId = product.ProductId
    AND existing.Lang = N'sl'
    AND existing.TextType = N'DESCRIPTION'
);

PRINT CONCAT(N'Dodanih DESCRIPTION.sl: ', @@ROWCOUNT);
