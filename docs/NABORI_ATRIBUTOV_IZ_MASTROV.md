# Nabori atributov iz mastrov starega PIM-a

Datum: 2026-09-08. Migracija: `173_CategoryAttributeSetsFromMastri.sql`. Zahteva uporabnika:
»preberi mastre iz PIM_test in napolni nabore«.

## Vir

`..\PIM_test\Mastri\` — 53 Excel mastrov (oznake `1A1` … `2H2`) in zbirni
`_Pregled_atributov_po_kategorijah.xlsx`, list **Matrika**: 923 vrstic (atributov) × 53 mastrov z
odstotkom zasedenosti. Stari sistem je iz Matrike že generiral izpis parov s pragom 50 %
(`..\PIM_test\sql\migrations\tools\Seed_CategoryAttributeImport_Mastri.sql`: 1058 parov, 358 imen,
samo skupini »Tehnični atribut« in »Splošni atribut«) — ta izpis je bil vhod tu. **Preslikave stari
sistem nikoli ni naredil**: `pim.CategoryAttributeMap`, `pim.AttributeAlias` in
`pim.CategoryExternalMap (MASTRI)` so v bazi `PIM_test` prazni. Zato je preslikava narejena tu in
zapisana v tem dokumentu, da jo je mogoče preveriti in popraviti.

## Rezultat

| | |
|---|---|
| parov master × atribut (prag 50 %) | 1058 |
| ujetih v register `canon.AttributeDefinition` | 483 |
| vrstic nabora (`canon.CategoryAttributeSet`) | 484, vse priporočene (173: 209 obveznih + 275 priporočenih; 174: vse na priporočeno) |
| kategorij z naborom | 46 (svetila_si 13, videlektro 33) |
| atributi iz mastrov, ki blokirajo splet | 0 (po 174); manjkajoči so opozorila |

Pregled in urejanje: `/nastavitve/nabori-atributov`. Kar tu ni preslikano, uporabnik doda tam
(prilepi seznam ali kopira nabor).

## Pravilo za raven

**Odločitev uporabnika 2026-09-08 (migracija 174): nabor iz mastrov opozarja, ne blokira.** Vse vrstice
iz mastrov so **RECOMMENDED**: manjkajoč atribut je opozorilo (`WARNING`) v spletnem profilu drevesa —
vidno na `/kakovost` in `/napake-validacije` (filter resnosti »opozorilo«) ter na kartici izdelka —
izvoza na splet pa ne ustavi. Raven **obvezen** (`ERROR`, blokira splet) ostane na voljo za ročno
nastavitev na `/nastavitve/nabori-atributov`; taka vrstica ima drugega avtorja in je 173/174 ne
prepišeta.

Zgodovina: 173 je po pravilu zasedenosti (≥ 95 % v mastru in ≥ 90 % pokritost pri izdelkih ali brez
izdelkov) 209 vrstic zapisala kot REQUIRED; 174 jih je spustila na RECOMMENDED. Vrednosti v 173 se ne
urejajo (migracije so samo dodajanje); generator `tools/Mastri` od 174 naprej ni več merodajen za
raven — merodajna je ta odločitev.

## Master → kategorija

Elektro mastri (`1xx`) gredo v drevo **videlektro**, mastri svetil (`2xx`) v **svetila_si** in v
ustrezno vejo `videlektro/razsvetljava`. Mastri po blagovnih znamkah (2A1, 2A5, 2A6, 2A7, 2A8, 2A9, 2A10, 2A13) nimajo
ustrezne kategorije (drevo svetil je po vrsti svetila, ne po znamki); združeni so v skupni nabor
korenov `notranja_svetila`, `zunanja_svetila` in `razsvetljava___luci`: atribut, ki je ≥ 50 %
zaseden v **vsaj dveh** znamkah, z zasedenostjo = povprečje. Master `Vezice.xlsx` nima oznake in v
Matriki ni zajet.

| Master | Ime | Cilj (drevo / kategorija) |
|---|---|---|
| 1A1 | Kabelski spoji | videlektro / `instalacije___kabli_in_vodniki___kabelski_spoji_in_zalivke` |
| 1A2 | Zalivke | videlektro / `instalacije___kabli_in_vodniki___kabelski_spoji_in_zalivke` |
| 1A3 | Kabelski končniki in spojke | videlektro / `instalacije___kabli_in_vodniki___kabelski_koncniki_in_spojke` |
| 1A4 | Kabelski spojni material | videlektro / `instalacije___kabli_in_vodniki___kabelski_spojni_material` |
| 1A5 | Podaljški in razdelilci | videlektro / `instalacije___kabli_in_vodniki___podaljski_in_razdelilci` |
| 1A6 | Kabli | videlektro / `instalacije___kabli_in_vodniki` |
| 1B1 | Inštalacijski odklopniki | videlektro / `instalacije___omare_in_stikalna_tehnika___instalacijski_odklopniki` |
| 1B2 | Zbiralke in pribor | videlektro / `instalacije___omare_in_stikalna_tehnika___zbiralke_in_pribor` |
| 1C1 | Izolirni trakovi | videlektro / `instalacije___prikljucni_in_pritrdilni_material___izolirni_trakovi` |
| 1C2 | Objemke | videlektro / `instalacije___prikljucni_in_pritrdilni_material___objemke` |
| 1C3 | Uvodnice | videlektro / `instalacije___prikljucni_in_pritrdilni_material___uvodnice` |
| 1D1 | Stikala in vtičnice | videlektro / `instalacije___stikala_in_vticnice___klasicni_program` |
| 1D2 | Thea Modular | videlektro / `instalacije___stikala_in_vticnice___modularni_program` |
| 1D3 | Zvonci | videlektro / `instalacije___stikala_in_vticnice___zvonci` |
| 1E1 | Predvleke | videlektro / `orodje___rocno_orodje___predvleke` |
| 1E5 | Dodatki za predvleke | videlektro / `orodje___rocno_orodje___predvleke` |
| 1E2 | Ročno orodje | videlektro / `orodje___rocno_orodje___ostalo_orodje` |
| 1E3 | Električno orodje | videlektro / `orodje___elektricno_orodje` |
| 1E4 | Prenosni merilni inštrumenti | videlektro / `orodje___prenosni_merilni_instrumenti` |
| 1F | Parapetni kanali | videlektro / `instalacije___instalacijski_kanali` |
| 1G | Razvodne doze | videlektro / `instalacije___razvodne_doze` |
| 1G2 | Razvodne doze Atex | videlektro / `instalacije___razvodne_doze` |
| 1H | Elektro omare, razdelilniki | videlektro / `instalacije___elektro_omare_in_razdelilniki` |
| 1H2 | Elektro omare F-elektro | videlektro / `instalacije___elektro_omare_in_razdelilniki` |
| 1I | Vtikači in spojke | videlektro / `instalacije___vtikaci_in_vticnice` |
| 1J | Strelovod in ozemljitev | videlektro / `instalacije___strelovod_in_ozemljitev` |
| 2A2 | Zasilna svetila | videlektro / `razsvetljava___luci___zasilna_razsvetljava` |
| 2A3 | Baterijske svetilke | svetila_si / `zunanja_svetila___prenosna_svetila` |
| 2A11 | Svetila_Nowodvorski_Cameleon | svetila_si / `cameleon_sistem`, videlektro / `razsvetljava___luci___cameleon_sistem` |
| 2A15 | Ohišje in ostali dodatki k svetilom | svetila_si / `notranja_svetila___dodatki`, videlektro / `razsvetljava___luci___dodatki` |
| 2B1 | Profili | videlektro / `razsvetljava___led_trakovi_in_profili___led_profili_in_dodatki` |
| 2B2 | Pokrovi | videlektro / `razsvetljava___led_trakovi_in_profili___led_profili_in_dodatki` |
| 2B3 | Zaključni elementi | videlektro / `razsvetljava___led_trakovi_in_profili___led_profili_in_dodatki` |
| 2B4 | Montažne ploščice | videlektro / `razsvetljava___led_trakovi_in_profili___led_profili_in_dodatki` |
| 2C1 | LED trakovi | videlektro / `razsvetljava___led_trakovi_in_profili___led_trakovi` |
| 2D | LED kontrolerji in zatemnilniki | videlektro / `razsvetljava___led_trakovi_in_profili___kontrolerji_in_zatemnilniki` |
| 2E | LED napajalniki | videlektro / `razsvetljava___led_trakovi_in_profili___napajalniki`, svetila_si / `svetlobni_viri_in_dodatki___napajalniki` |
| 2F1 | Senzorji gibanja | videlektro / `razsvetljava___senzorji_gibanja___senzorji` |
| 2F2 | Dodatki k senzorjem | videlektro / `razsvetljava___senzorji_gibanja___dodatki_k_senzorjem` |
| 2G1 | Sijalke | svetila_si / `svetlobni_viri_in_dodatki`, videlektro / `razsvetljava___sijalke` |
| 2G2 | Sijalke_Braytron | svetila_si / `svetlobni_viri_in_dodatki`, videlektro / `razsvetljava___sijalke` |
| 2G3 | Grla | svetila_si / `svetlobni_viri_in_dodatki___dodatki` |
| 2H1 | Tračnice in pribor | svetila_si / `tracni_sistemi`, videlektro / `razsvetljava___tracni_sistemi` |
| 2H2 | Tračna svetila | svetila_si / `tracni_sistemi___1_fazni_24v_nano_lvm___led_svetilke`, svetila_si / `tracni_sistemi___1_fazni_48v_lvm___led_svetilke`, svetila_si / `tracni_sistemi___1_fazni_48v_ut_lvm___led_svetilke`, svetila_si / `tracni_sistemi___1_fazni_profile___svetila`, svetila_si / `tracni_sistemi___3_fazni_ctls___svetila` |

Kjer je več mastrov preslikanih v isto kategorijo (npr. 1G in 1G2), je zasedenost največja od obeh.
`1A6 Kabli` nima svoje kategorije in je preslikan na starša `instalacije___kabli_in_vodniki`;
podkategorije ga podedujejo, kar je pri kablih (presek, napetost, tok) smiselno.

## Ime v Matriki → koda registra

Najprej enako ime (brez šumnikov in velikosti črk), potem izrecni aliasi spodaj. Register se **ni**
širil: atribut, ki ga v `canon.AttributeDefinition` ni, ni v naboru. »Oblika« je preslikana v
`OBLIKA_SVETILKE` samo pri mastrih svetil (pri elektro mastrih pomeni obliko doze ali uvodnice).

| Koda registra | Imena v mastrih |
|---|---|
| `BATERIJA` | Baterija |
| `DELOVNA_TEMPERATURA` | Temperatura delovanja, Temperatura delovanja (min/max), Temperaturno območje |
| `DELOVNI_CAS` | AVTONOMIJA, Čas delovanja |
| `DOLZINA` | Dolžina, Vidna dim. dolžina |
| `EKVIVALENT` | Ekvivalent |
| `ELEKTRICNI_RAZRED` | Klasa |
| `ENERGIJSKI_RAZRED` | Energijski razred |
| `FREKVENCA` | Frekvenca, Frekvence |
| `GARANCIJA` | Garancija |
| `GRLO` | Grlo |
| `INDEKS_BARVNEGA_VIDEZA_CRI` | CRI, REPRODUKCIJA BARV |
| `IP_STOPNJA_ZASCITE` | IP zaščita |
| `KOT_DETEKCIJE` | Kot zaznavanja |
| `KOT_SVETLOBNEGA_SNOPA` | Kot svetenja |
| `MAX_MOC_SIJALKE` | Max moč sijalke |
| `MONTAZNA_VISINA` | Višina montaže |
| `NACIN_MONTAZE` | Montaža tračne luči, Način montaže, Vrsta montaže |
| `NACIN_POLNJENJA` | Polnjenje |
| `NAPETOST` | Napetost, Napetost do, Napetost od, Vhodna napetost, Vhodna napetost max., Vhodna napetost min., Vrsta napetosti |
| `NAZIVNA_JAKOST_TOKA` | Nazivni tok |
| `NAZIVNA_MOC` | ELEKTRIČNA MOČ, Max moč, Max. moč, Moč, Moč max. |
| `NAZIVNA_NAPETOST` | Nazivna napetost |
| `OBLIKA_SVETILKE` | Tip svetilke, Vrsta svetilke, Vrsta svetilke 1 |
| `PREMER` | Premer |
| `PRESEK_KABLA` | Presek kabla, Presek žice |
| `PREVLADUJOCA_BARVA` | Barva, Barva (nesklanjana), Barva lastnost, Barva-lastnost, Lastnost barve |
| `PREVLADUJOC_MATERIAL` | Material, Material ohišja, Metarial ohišja, OHIŠJE |
| `RAZDALJA_DETEKCIJE` | Domet |
| `SENZOR_GIBANJA` | Senzor |
| `SIRINA` | Vidna dim. širina, Širina |
| `SLOG` | STIL |
| `STEVILO_SVETLOBNIH_VIROV` | Število sijalk |
| `SVETILKA_VKLJUCUJE_SVETLOBNI_VIR` | Vključuje sijalko |
| `SVETLOBNI_TOK` | CELOTNI SVETLOBNI TOK, Svetlobni tok |
| `TEMPERATURA_BARVE` | Barva svetlobe, Barva svetlobe (K), PODOBNA BARVNA TEMPERATURA, Temperatura svetlobe |
| `UPORABA` | Način uporabe, Uporaba |
| `VELIKOST` | Velikost |
| `VISINA` | Vidna dim. višina |
| `VRSTA_KABLA` | Kabel, Priključni kabel |
| `VRSTA_SVETLOBNEGA_VIRA` | LED, SVETLOBNI VIR, Tehnologija LED, Tip sijalke, Tip svetlobe |
| `ZATEMNLJIVO` | Dimmable |
| `ZDRUZLJIVO_Z` | Kompatibilno, Kompatibilno z |
| `ZIVLJENJSKA_DOBA` | Življenjska doba |

## Kar ni preslikano

575 od 1058 parov. Večina so **polja izdelka**, ne atributi (Proizvajalec, Tip/Tip1–6, Ključne
besede, IQLSHOP, MIMOVRSTE, nazivi za nalepke, PAK 1/2, Enota mere, Država, PROSTOR, Filter …) —
ta gredo v kanonične stolpce ali kategorije, ne v nabor. Pravi atributi, ki jih register še nima
(pojavitev v mastrih ≥ 2), so delovni seznam za širitev registra na `/nastavitve/atributi`:

| Ime v mastrih | Mastrov |
|---|---|
| Vidna dimenzija | 29 |
| Upravljanje | 7 |
| Vidna dim. | 6 |
| Vključuje napajalnik | 6 |
| Število polov | 4 |
| Oblika | 3 |
| Material pokrova | 3 |
| Tip napajalnika | 3 |
| Tehnologija | 3 |
| RAL | 2 |
| Otroška zaščita | 2 |
| Pokrov | 2 |
| Barva vrat | 2 |
| Dimenzija varovalke | 2 |
| Dolžina kabla | 2 |
| Dolžina varovalke | 2 |
| Končni navoj | 2 |
| Napajanje | 2 |
| Način upravljanja | 2 |
| Predpripravljeni vhodi | 2 |
| Presek kabla max | 2 |
| Presek kabla min | 2 |
| Presek žice max | 2 |
| Presek žice min | 2 |
| Priključne sponke | 2 |
| Priklop | 2 |
| Pritrditev | 2 |
| Prosojnost | 2 |
| Sponka PE/N | 2 |
| Temperaturna obstojnost | 2 |
| Velikost doze | 2 |
| Velikost uvodnice | 2 |
| Vrsta doze | 2 |
| Za LED profil | 2 |
| Širina modula | 2 |
| Širina varovalke | 2 |
| Število modulov | 2 |
| Število vrst | 2 |

»Vidna dimenzija« / »Vidna dim.« (35 pojavitev) je sestavljeno polje; posamezne mere so preslikane
prek »Vidna dim. višina/širina/dolžina« v `VISINA` / `SIRINA` / `DOLZINA`.

## Ponovitev

Generator preslikave (`PIM_Solution/tools/Mastri/build_category_attribute_sets.py`) iz izpisa
Matrike in registra naredi seznam kandidatov; raven določi SQL po pravilu zgoraj; rezultat je
zapisan kot migracija. Če se Matrika spremeni, se naredi **nova** migracija — 173 se ne ureja.
