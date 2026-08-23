# Analiza izvozov iz PIM — koliko je narejeno in kaj manjka

Datum meritve: **2026-08-23, 20:45**. Merjeno proti živi bazi `PIM` na
`localhost\MSSQLSERVER3` (migracija **080**, uporabljena isti dan) in proti delovnemu
drevesu veje `feature/baza-a3-mnozicna-obdelava`.

Ta dokument nadomešča razdelek „B — IZVOZ" iz [`ANALIZA_A_B_C.md`](ANALIZA_A_B_C.md)
(meritev 2026-08-22, migracija 058). Od takrat je bilo uporabljenih **22 migracij**
(059–080) in številke iz tistega dokumenta so za izvoz zastarele.

> **Opomba k času meritve.** Med merjenjem je tekel `PIM.KatalogWorker` (PID 33576,
> od 20:41) in v `raw.Inbox` je bilo 356 strani `Pending`. Številke iz kataloga se zato
> še premikajo; razmerja in ugotovitve o mehanizmu to ne spremeni. Migracija `080` je
> uporabljena v bazi, a še ni commitana.

---

## 0. Kaj sem pognal kot dokaz

| Ukaz | Izhod |
|---|---|
| `dotnet build workers\PIM.B2bWorker` | **Build succeeded**, 0 opozoril, 0 napak |
| `PIM.B2bWorker --export-magento --organization-id 1..4` | štirikrat `Magento CSV izvoz končan`; nastali pari `magento-products.csv` + `magento-customers.csv` + `magento-export.complete` |
| `dotnet run --project tests\PIM.F7.MagentoExportTests` | **PASS** — pogodba 213/19 glav, vloga glavne slike, UTF-8 brez BOM, izvoz proti bazi (43.506 izdelkov, 1 stranka) |
| ~15 poizvedb nad `PIM` | številke v nadaljevanju |
| štiri izvožene datoteke, preštete stolpec za stolpcem | razdelek 3 |

`dotnet build PIM.sln` v celoti ni šel skozi: `PIM.KatalogWorker` je med meritvijo tekel in
zaklenil `PIM.Operations.dll` ter `PIM.XmlMapping.dll` (MSB3027). To je zaklep datotek,
ne napaka prevoda — procesa nisem ustavljal.

---

## 1. Povzetek po kanalih

| Kanal | Mehanizem (koda + register) | V obratovanju | Kje se ustavi |
|---|---|---|---|
| **Magento — izdelki** | ~95 % | **~55 %** | teče v živo za vsa štiri podjetja; vsebine ima 8,2 % celic |
| **Magento — stranke** | ~90 % | **0 %** | `b2b.Customer` ima 0 vrstic — datoteka je samo glava |
| **B2B (3 profili)** | ~60 % | **0 %** | procedure obstajajo, poganjalnika ni |
| **WEB_B2C_PRODUCTS** | ~40 % | **0 %** | 7 stolpcev v registru, brez poganjalnika |
| **ERP_L1 (izvoz)** | ~40 % | **0 %** | isto |
| **Zaloga (`out.ExportStockCsv`)** | ~50 % | **0 %** | podatek je (278.160 pozicij), izvoz ga ne bere |
| **Dostava (FTP/HTTP/Magento)** | **0 %** | 0 % | namerna meja — datoteka nastane, nihče je ne odnese |
| **Odhodna pot (outbox)** | ~55 % | **0 %** | `out.OutboxMessage` = 0 vrstic |

**Ena poved:** od sedmih izvoznih profilov v obratovanju teče **en**, in ta en teče dobro —
kar mu manjka, ni izvozna koda, ampak vsebina v objavljenem sloju in pot iz mape do Magenta.

---

## 2. Kar dela, in kaj je od zadnje meritve novega

- **Izvoz je gnan iz registra** (`out.ExportProfile` 7 profilov, `out.ExportColumn` 275
  vrstic; Magento izdelki 215, od tega **213 aktivnih**). Nov stolpec je vrstica v bazi,
  ne sprememba programa. To potrdi tudi negativni preizkus v `PIM.F7.MagentoExportTests`.
- **Atomarni par datotek** je resničen: `.tmp` → zamenjava pod ključavnico → oznaka
  `magento-export.complete`; ob padcu se prejšnji par vrne.
- **Vsa štiri podjetja imajo objavljen katalog.** 2026-08-22 sta Vidadria in Ediito imeli
  **0** objavljenih artiklov; danes je objavljenih **89.129** (DEMO 1.728, IQLighting 43.503,
  Vidadria 10.594, Ediito 33.304). To se natanko ujema z `ERP_L1 VALID = 89.129` — vstopnica
  za objavo je torej **še vedno stari profil `ERP_L1`**.
- **Otroške tabele objave niso več prazne:** `pim.ProductText` 177.033, `pim.ProductPrice`
  189.748, `pim.ProductAttribute` 247.148, `pim.ProductCommercial` 89.127,
  `pim.ProductCategory` 9.973, `pim.ProductMedia` 4.991.

---

## 3. Meritev na resničnih datotekah (vse štiri hkrati)

| Podjetje | Vrstic | Polnih stolpcev od 213 | Polnost celic |
|---|---|---|---|
| DEMO (1) | 1.728 | **125** | 14,8 % |
| IQLighting (2) | 43.503 | **167** | 10,0 % |
| Vidadria (3) | 10.594 | **169** | 10,9 % |
| Ediito (4) | 33.304 | **10** | 4,7 % |
| **skupaj** | **89.129** | **180 vsaj pri enem podjetju** | **8,2 %** |

Napredek proti 2026-08-22 je resničen: takrat 15 od 213 stolpcev, danes 180. **Toda polnih
stolpcev ni isto kot polna datoteka.** Pri IQLightingu je slika taka:

| Delež izpolnjenosti | Stolpcev | Kaj je notri |
|---|---|---|
| 100 % | 13 | šifra, EAN, proizvajalec, dobavitelj, merska enota, teže, volumen, mere paketa, DDV, PAK2 |
| 90–100 % | 5 | država proizvoda, enote mer, cena B2C |
| 50–90 % | 1 | oznaka tarifa (87,9 %) |
| 10–50 % | 1 | **naziv artikla (10,6 %)** |
| 1–10 % | 61 | skoraj vse lastnosti iz dobaviteljevega XML (4–6 %) |
| pod 1 % | 86 | dolgi rep lastnosti |
| 0 % | 46 | glej razdelek 4 |

Torej: **hrbtenica ERP podatkov je polna, spletna vsebina pa ne.** Spletni naziv ima
4.593 od 43.503 izdelkov (10,6 %), angleški 3.265 (7,5 %), kategorijo in glavno sliko
pa 2.267 (5,2 %). Lastnosti ima v celotni objavi **7.694 izdelkov od 89.129 (8,6 %)**.

---

## 4. 33 stolpcev, ki so prazni pri vseh štirih podjetjih

| Skupina | Stolpci | Zakaj je prazno |
|---|---|---|
| **Zaloga (11)** | `VID trenutna zaloga`, `VID naročena količina`, `VID količina za odpremo`, `VID razpoložljiva količina`, `VID naročena količina dobaviteljem`, `VID datum dobave`, `VID koli. prihodnjih dobav`, `Dobavitelj zaloga`, `Dobavitelj naročena zaloga`, `Dobavitelj datum`, `Skladišče` | **Podatek obstaja** — `stock.Position` ima 278.160 vrstic — ampak `MagentoExportCommand.LoadProductRowsAsync` zaloge sploh ne bere. Manjka poizvedba in odločitev, katero skladišče gre v kateri stolpec. |
| **Dokumenti (3)** | `Glavni dokument`, `Vloge dokumentov`, `Ostali dokumenti` | ni vira; dokumentov v katalogu ni |
| **Trgovinski pogoji (6)** | `Popust`, `Valuta`, `Omejitev pri naročanju`, `Skupina popusta`, `S popust %`, `Posebni popust za stranko` | ni kanonične kode; ni odločeno, od kod pridejo |
| **Enote in klasifikacija (4)** | `Enota bruto teže`, `Enota neto teže`, `Enota volumna`, `ABC klasifikacija` | SAOP pošlje eno samo enoto mer (`ItemDimensionUOM`), ločenih enot za težo in volumen ni |
| **Kategorije Videlektro (2)** | `Kategorije vid ANG`, `Kategorije vid SLO` | register `canon.WebSite` ima obe strani (`B2C`, `B2C_EN`), a `pim.ProductCategory` ima kategorije **samo** za `svetila_si` (4.987) in `svetila_si_en` (4.986) |
| **Ostale slike (1)** | `Ostale slike` | `pim.ProductMedia` ima izključno vlogo `Primary` (4.991 vrstic) — druge slike v katalog ne pridejo |
| **Lastnosti brez podatka (6)** | `Vrsta toka`, `EAN koda`, `Število ciklov polnjenja`, `Ime izdelka`, `Tehnična opomba`, `Vrsta kabla` | preslikava obstaja, dobaviteljev XML te vrednosti ne vsebuje |

---

## 5. Pet konkretnih vrzeli, ki jih je razkrila ta meritev

### 5.1 Vidadria in Ediito nimata dobavitelja in merske enote — objava zaostaja za katalogom

> **ODPRAVLJENO 2026-08-23, 21:05.** `val.Promote @OrganizationId = 3` in `= 4` sta bila
> pognana (3 oziroma 4 sekunde). Rezultat je v razdelku 5.1a; spodnja meritev je stanje
> pred zagonom.

Stolpca `Dobavitelj` in `Merska enota` sta polna pri podjetjih 1 in 2, prazna pri 3 in 4.
Vzrok ni v izvozu:

| Podjetje | `canon.Product` z dobaviteljem | `pim.Product` z dobaviteljem |
|---|---|---|
| DEMO | 16.683 | 1.728 |
| IQLighting | 107.071 | 43.502 |
| **Vidadria** | **24.364** | **0** |
| **Ediito** | **38.171** | **0** |

`val.Promote` oba stolpca zna prenesti (od migracije `077`), le da za podjetji 3 in 4 od
takrat ni bila pognana. **Popravek je zagon `val.Promote` za organizaciji 3 in 4**, ne
sprememba kode. To je najcenejši ukrep v tem dokumentu.

### 5.1a Kaj je zagon dejansko prinesel

Objava ni prinesla samo dobavitelja in merske enote — nadoknadila je vse, kar je v katalog
prišlo z migracijami 072–080:

| Meritev | Pred | Po |
|---|---|---|
| `pim.Product` z dobaviteljem (org 3 / org 4) | 0 / 0 | **10.593 / 33.304** |
| `pim.ProductText` `DESCRIPTION` | 12.064 | **35.613** |
| `pim.ProductText` `WEB_TITLE` | 20.623 | **48.203** |
| `pim.ProductText` `TITLE_ERP2` | 48.968 | **63.437** |
| `pim.ProductAttribute` | 247.150 | **251.079** |

V izvoženi datoteki:

| Podjetje | Polnih stolpcev prej | Polnih stolpcev zdaj | Naziv artikla | Angleški naziv |
|---|---|---|---|---|
| Vidadria (3) | 169 | **180** | 0 → **8.671** | 0 → **7.250** |
| Ediito (4) | 10 | **21** | 0 → 15 | 0 → 3 |

**Za organizaciji 1 in 2 je bil isti zagon prazen tek** (2026-08-23, 21:20; 0 oziroma 5 sekund).
Nobena vrstica se ni spremenila — DEMO in IQLighting sta bila objavljena že po migracijah
072–080, zaostajali sta samo Vidadria in Ediito. Preverjeno tudi z druge strani: opisi za
objavljene izdelke v `canon` (org 2: 12.096, org 3: 22.012, org 4: 1.627) se natanko ujemajo
z vrsticami v `pim.ProductText`. Objava torej ni več v zaostanku za katalogom pri nobenem
podjetju. (DEMO ima v katalogu en sam opis in ta izdelek ni objavljen.)

Vidadria je s tem najbolj poln izvoz od štirih. **Ediito ostaja skoraj prazna** in to ni
stvar objave: nima ne spletnih nazivov, ne kategorij, ne slik, ne lastnosti — njenih EAN-ov
v dobaviteljevih datotekah ni (izmerjeno 2026-08-23, migraciji 069/070), spletnih nazivov
zanjo pa je v delovnih zvezkih 1.158 in se z objavljenimi šiframi skoraj ne ujemajo.

### 5.2 Cenika sta v kodi zapisana s trdo roko — `B2B` in `B2C`

> **ODPRAVLJENO 2026-08-23, migracija `083`.** Šifra cenika je zdaj vrstica v
> `out.ExportPriceList` (podjetje → kanonična koda cenovnega stolpca → šifra cenika,
> s `SortOrder` kot prednostjo). Izvoz je po zamenjavi do zadnjega znaka enak kot prej;
> podrobno v [`EXPORTS.md`](EXPORTS.md) §2b. **Odločitev uporabnika:** manjkajoča vrstica
> ni napaka — če podjetje cenika nima, stolpec ostane prazen. Ali ima IQLighting B2B cenik
> pod drugo šifro, preveri uporabnik pri viru.

`MagentoExportCommand` bere `pim.ProductPrice WHERE PriceList = N'B2B'` oziroma `N'B2C'`.
Cenike pa vsako podjetje imenuje po svoje:

| Podjetje | Ceniki v objavi |
|---|---|
| DEMO | B2B 1.109, B2C 3, NAB 1.665, PRC 7 |
| **IQLighting** | B2C 43.218, LOM 24.914, NAB 6.833, PRC 3.288, EGL 3.126, BTT 1.880, IDE 1.156, ACB 20 — **cenika `B2B` sploh ni** |
| Vidadria | B2B 9.691, B2C 9.758 + 16 drugih |
| **Ediito** | B2B 33.315, LOM 24.914, NAB 3.185, ACB 2.212, PRC 390 — **cenika `B2C` ni** |

Posledica v datoteki: IQLighting ima `Cena B2B` prazno pri vseh 43.503 izdelkih, Ediito
ima prazno `Cena B2C` pri vseh 33.304. Nista napaki podatka — **kateri cenik je B2B in
kateri B2C, je nastavitev podjetja in sodi v register**, tako kot so tja šle glave stolpcev
(045) in spletne strani (059). Danes je to `switch` v kodi, samo brez besede `switch`.

### 5.3 Opisi pridejo v katalog, do izvoza pa ne

Migracija `080` (danes) je odpravila tiho vrzel: opisi so se izluščali po napačni poti in
vseh 84.466 vrednosti je bilo praznih. Zdaj je v `canon.ProductText` **56.706 opisov** (sl 20.338, en 12.322, hr 11.925,
de 11.876, it 5, plus `DESCRIPTION_O` 235 in `DESCRIPTION_K` 5).

Do izvoza jih pride **nič**, in to iz dveh ločenih razlogov:

1. `pim.ProductText` nima **nobene** vrstice tipa `DESCRIPTION` — `val.Promote` jih zna
   prenesti, a od `080` še ni bila pognana.
2. **Magento predloga nima stolpca za opis.** V 213 aktivnih stolpcih ni ne `Opis`, ne
   `Kratek opis`, ne `Vsebina`. Tudi po zagonu objave opis nikamor ne pride.

Druga točka je odločitev, ne napaka: ali predloga dobi stolpec za opis (in v katerih jezikih).

### 5.4 Datoteka strank je povsod samo glava

`magento-customers.csv` ima pri vseh štirih podjetjih 230 bajtov — 19 glav in nič vrstic.
`b2b.Customer` = **0**, `pim.CustomerWebProfile` = **0**. Mehanizem (rabatne stopnje,
skupine popustov, B2B+, veljavnostna okna) je napisan in testiran, podatka ni: strani
`Customers` (4) in `GetItemCustomerDataV2` (8) čakajo v `raw.Inbox` kot `Pending` in
preslikave zanje ni.

### 5.5 Šest izvoznih poti nima poganjalnika

`out.ExportProductsCsv`, `out.ExportB2bCustomersCsv`, `out.ExportB2bProductsCsv`,
`out.ExportB2bShippingCsv` in `out.ExportStockCsv` obstajajo v bazi. V produkcijski kodi jih
ne kliče **nihče** — pojavijo se samo v seznamu, ki ga preverja `PIM.Migrator --verify`, in
v testih. Isto velja za profila `WEB_B2C_PRODUCTS` in `ERP_L1`: vrstice v registru so,
ukaza, ki bi ju izvozil, ni. Edini pravi poganjalnik je
`PIM.B2bWorker --export-magento`.

Ob tem: `ops.ScheduleProfile` ima 10 vrstic (`SAOP_PRODUCTS`, `GENERIC_XML`,
`ALERT_DISPATCH`, `WATCHDOG`) in **nobene za izvoz**. Izvoz je izključno ročen ukaz.

---

## 6. Odhodna pot (outbox) — kaj se je od 2026-08-22 spremenilo

Ena stvar, in pomembna: `out.OwnershipPolicy` ni več prazna — ima **112 vrstic**
(migracija `068`, lastništvo polj iz preglednice). To je bila varovalka, ki je fizično
preprečevala vstop v outbox: `out.EnqueueMessage` je vsako sporočilo zavrnil z napako 51010.

Vse ostalo je nespremenjeno: `out.OutboxMessage` **0**, `out.OutboxAttempt` **0**,
`out.SaopItemAssignment` **0**. Manjka **proizvajalec sporočil** — nihče ne vstavlja vrstic —
dispatcher obdela eno sporočilo in konča, vrstice `OUTBOUND` v razporedu ni.

---

## 7. Priporočen vrstni red

1. ~~**Pognati `val.Promote` za organizaciji 3 in 4**~~ — **narejeno 2026-08-23, 21:05**
   (razdelek 5.1a). Ostane pravilo: objavo je treba pognati po vsaki migraciji, ki doda
   objavljeni stolpec, sicer izvoz kaže staro stanje.
2. ~~**Cenik B2B/B2C v register**~~ — **narejeno 2026-08-23, migracija `083`** (§5.2).
   Ostane preveriti, ali ima IQLighting B2B cenik pod drugo šifro; če ga ima, je to en
   `INSERT` v `out.ExportPriceList`.
3. **Odločitev o opisu v predlogi** — ali Magento dobi stolpce za opis in v katerih jezikih.
   Podatek je od danes v katalogu (56.706 opisov v petih jezikih).
4. **Zaloga v izvoz** — 11 stolpcev, podatek obstaja (278.160 pozicij). Potrebna je
   odločitev, katero skladišče gre v kateri stolpec `VID *`.
5. **Spletna vsebina** je pravo ozko grlo vsebine: naziv 10,6 %, kategorija in slika 5,2 %,
   lastnosti 8,6 %. To ni izvozna naloga — je pokritost dobaviteljevih datotek in delovnih
   zvezkov.
6. **Odločitev o vstopnici za objavo:** danes `ERP_L1` (89.129 VALID). `ERP_L1_SLO` bi dal
   **156.141** — 1,75-krat več objavljenih artiklov. Odločitev je poslovna in od 2026-08-22
   nespremenjena.
7. **Stranke:** preslikava za `Customers` in `GetItemCustomerDataV2` (12 strani čaka).
   Brez nje je druga polovica Magento para trajno prazna.
8. **Ostali profili:** ali dobijo poganjalnik ali pa se v registru označijo kot neuporabljeni.
   Šest izvoznih poti brez klicatelja je danes videti kot narejeno delo, pa ni.
9. **Dostava** ostaja namerna meja (`AGENTS.md` §4.5) — datoteka nastane, do Magenta je
   nihče ne odnese.
