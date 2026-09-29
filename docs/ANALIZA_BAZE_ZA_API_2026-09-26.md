# Analiza baze PIM in primernost za API (2026-09-26)

Baza: lokalna razvojna `DESKTOP-TONVQHJ\MSSQLSERVER3` / `PIM`, SQL Server 2019 Developer (15.0.2190),
združljivost 150. Vse številke so iz žive baze na ta dan. Produkcijska baza ima enako shemo (iste migracije),
količine se lahko razlikujejo.

## 1. Odgovor na kratko

**Da, baza je dobra osnova za API**, pod dvema pogojema, ki sta zdaj izpolnjena:

1. AI ne sme brati tabel neposredno, ampak prek stalne pogodbe. Zato obstaja shema `api` (migracija 287):
   17 bralnih postopkov, ki poznajo pravila PIM (katera zaloga je naša, kateri cenik je nabavni, kako se
   ujemajo podjetja). Neposredna poizvedba po tabelah bi AI-ju dala napačne številke. Primer:
   `stock.Position` ima 4,93 milijona vrstic, veljavnih pa je samo 0,6 %.
2. API mora imeti svojega uporabnika baze, ki sme samo brati. Vloga `pim_api_reader` ima pravico samo
   izvajati postopke `api.*`. Tabel, gesel (`sec.LocalUser`), ključev in zapisovalnih postopkov ne doseže
   (preverjeno).

Glavni omejitvi podatkov (ne API-ja): podatki so **stari 80–100 ur**, ker lokalno avtomatika ne teče od
22. 9., in **analitika prodaje je še prazna** (`ana.*`, `sales.*`), ker posel SAOP_ANALYTICS še ni tekel.

## 2. Migracije

- Pred pregledom je bilo 21 neuveljavljenih migracij (270–286). **Vse so uveljavljene**
  (`Invoke-PendingMigrations.ps1`, brez napak). V vseh so bili pregledani nevarni ukazi: DROP in TRUNCATE
  se nanašajo samo na začasne tabele (`#...`).
- Dodana in uveljavljena **287_BralniApiZaAnalizeInAi.sql** (shema `api`).
- 11 migracij javlja »spremenjeno vsebino« (044–047, 057, 058, 171, 173, 209, 214, 220). Znano in
  preverjeno 2026-09-22: gre za zamenjavo koncev vrstic (CRLF → LF) in popravke za svežo namestitev.
  Ukrepati ni treba.
- Dvojne številke (256, 276–279 po dve) so posledica vzporednih sej. Izvajalec jih uveljavi po abecedi;
  pregledani pari ne posegajo v iste objekte.

## 3. Obseg

| Shema | Tabel | Vrstic | Vloga |
|---|---:|---:|---|
| map | 22 | 28,2 mio | preslikave virov; `map.ExtractedValue` 28 mio / 3,3 GB |
| stock | 9 | 9,9 mio | zaloga; `stock.Position` 4,9 mio, `stock.LandingRecord` 4,9 mio / 2,1 GB |
| val | 8 | 6,2 mio | validacija; `val.ProductIssue` 5,5 mio / 1,3 GB |
| pim | 39 | 4,3 mio | potrjeni katalog; `pim.ProductFieldHistory` 2,7 mio |
| canon | 23 | 2,4 mio | kanonični katalog (vir za API) |
| b2b | 11 | 27.630 | stranke, artikli strank, popusti |
| ops, out, purch, raw, sec, … | | | nadzor, izvozi, naročila, varnost |
| ana, sales | 14 | ~0 | analitika in prodaja: **prazno** |

Velikost podatkov je 17,6 GB, dnevnika 2,6 GB. Tabel je 196, pogledov 12, postopkov več kot 380.

| Podjetje | Izdelkov | Aktivnih | Za splet | Brez EAN | Strank |
|---|---:|---:|---:|---:|---:|
| 1 DEMO (neaktivno) | 17.425 | 17.414 | 2.933 | 11.263 | 1.614 |
| 2 IQLighting | 111.098 | 98.287 | 2.753 | 57.894 | 4.729 |
| 3 Vidadria | 28.948 | 22.699 | 9.457 | 10.813 | 4.676 |
| 4 Ediito | 39.159 | 39.154 | 0 | 5.734 | 618 |

55.612 šifer artiklov je v več podjetjih hkrati. Zato API vedno zahteva podjetje in ga ne sešteva sam.

## 4. Ocena modela

### Dobro (zakaj je primerna za API)

- **Jasne plasti:** `raw` (vhod) → `map` → `canon` (kanonični katalog) → `val` → `pim` (objavljeno) → `out`.
  API bere `canon`, torej zadnje stanje iz ERP in dobaviteljev.
- **Meja podjetja** je povsod (`OrganizationId`), enoličnost `(OrganizationId, ItemID)` je zavarovana z indeksom.
- **Referenčna celovitost:** 160 tujih ključev, vsi zaupanja vredni (`is_not_trusted = 0`), nobeden izklopljen.
- **Primarni ključi** na vseh tabelah razen ene varnostne kopije (`out.WebPublication_pred285`).
- **Indeksi** za vse poti, ki jih API uporablja: `canon.Product` (12 indeksov: podjetje + šifra, EAN,
  dobavitelj, proizvajalec, skupina …), `canon.ProductPrice (ProductId, PriceList, ValidFrom)`,
  `canon.ProductText (ProductId, Lang, TextType)`, `stock.Position (MatchedProductId)`, `b2b.CustomerItem`.
- **Zgodovina cen** je v tabeli (več `ValidFrom` na izdelek in cenik), zato so poročila o spremembah cen
  možna brez dodatnega dela.
- **Sled sprememb** kataloga (`pim.ProductFieldHistory` prek sprožilcev) in navada, da vse gre skozi postopke.

### Slabosti in tveganja

| # | Ugotovitev | Posledica | Predlog |
|---|---|---|---|
| 1 | Podatki so zadnjič osveženi 22. 9. (zaloga 80 h, cene 100 h) | poročila so zastarela | zaženi gostitelja avtomatike ([05](../Navodila/05_AutomationHost.md)); API svežino javlja v `/api/v1/freshness` |
| 2 | `ana.*` in `sales.*` sta prazna, `purch` ima podatke samo za Vidadrio (609 naročil) | ni prodaje, trendov in predlogov naročil | zaženi posel SAOP_ANALYTICS (migracija 284) za podjetja 2, 3 in 4 |
| 3 | 99,4 % `stock.Position` (4,90 mio vrstic, 1.574 posnetkov od 31. 7.) so neaktivni posnetki; `stock.LandingRecord` 2,1 GB | baza raste za ~86.000 vrstic zaloge na dan (4,9 mio v 57 dneh) | hramba: posnetke, starejše od 14 dni, briši (dnevna zaloga je od 284 v `ana.StockDaily`) |
| 4 | `map.ExtractedValue` 28 mio vrstic / 3,3 GB, `val.ProductIssue` 5,5 mio / 1,3 GB | počasnejši varnostni kopiji in obnova | preveri hrambo po zajemu; zaprte težave starejše od N dni arhiviraj |
| 5 | `READ_COMMITTED_SNAPSHOT` je izklopljen | bralci (intranet, API) in nočni zapisi se lahko čakajo | vklopi RCSI (enkraten ukaz v času brez prometa; tempdb dobi hrambo različic) |
| 6 | `max server memory` ni omejen (2.147.483.647 MB) | na 8 GB računalniku SQL vzame ves pomnilnik (znano zamrzovanje) | nastavi na ~4–5 GB (razvoj) oz. 75–80 % RAM (strežnik) |
| 7 | Način obnove SIMPLE | obnova samo do zadnje polne kopije | na produkciji preveri; če je SIMPLE, vsaj dnevna polna kopija |
| 8 | 31.049 aktivnih izdelkov nima nobene cene | poročila o marži in vrednosti zaloge jih ne zajamejo | API jih šteje (`itemsWithoutCost`), ne skrije; vzrok iskati v zajemu cen |
| 9 | 1.845 pozicij zaloge ni ujetih na izdelek (`stock.UnmatchedPosition`) | ta zaloga v API ni vidna | pregled na `/zaloge` (karantena) |
| 10 | `canon.Product` nima časa zadnje spremembe | »izdelki, spremenjeni od …« ni poceni | po potrebi stolpec `UpdatedUtc` ali branje iz `pim.ProductFieldHistory` |
| 11 | Kolacija baze `SQL_Latin1_General_CP1_CI_AS` razlikuje šumnike; brez polnobesedilnega indeksa | iskanje »crna« ne najde »črna« | API išče s `CI_AI` (~1 s na 111.000 izdelkih); pri večjem obsegu izračunan iskalni stolpec |
| 12 | Ostanki varnostnih kopij: `out.WebPublication_pred285` (kopica), `b2b.CustomerPackagingDiscountOverride_pred274` | nered | po potrditvi, da povratek ni več potreben, pobriši |
| 13 | V repozitoriju je sledena datoteka `appsettings.Local.json` v korenu (`git ls-files`) | če vsebuje geslo (SAOP, baza), je v zgodovini Gita | preveri vsebino; če ima skrivnosti, jo odstrani iz Gita in zamenjaj gesla |
| 14 | Imena dobaviteljev prihajajo iz `b2b.Customer` (`canon.PartnerName`) | dobavitelj, ki v SAOP ni vpisan kot partner, nima imena | sprejemljivo; API vrne šifro in `null` ime |

Predlogi SQL Serverja za manjkajoče indekse (`sys.dm_db_missing_index_*`) zadevajo `ops.Alert`, `raw.Inbox`,
`map.FieldMapping` in `stock.Snapshot (IsActive, SnapshotUtc)`. API nobenega od njih ne potrebuje; zadnji je
majhen (1.586 vrstic).

## 5. Zakaj API bere prek postopkov in ne neposredno

| Možnost | Ocena |
|---|---|
| AI dobi SQL dostop do baze | ne: napačne številke (neaktivni posnetki, cene brez veljavnosti, mešanje podjetij), tveganje za bazo, brez nadzora |
| pogledi (`VIEW`) nad tabelami | delno: brez parametrov, listanja in varovalk pri zmogljivosti |
| **postopki v shemi `api` + tanka spletna plast** | izbrano: ena pogodba, pravila PIM na enem mestu, strežniško listanje, ena pravica (EXECUTE), sled klicev |

## 6. Priporočeni vrstni red

1. Zaženi avtomatiko in posel SAOP_ANALYTICS (točki 1, 2): brez tega AI poroča o starih podatkih brez prodaje.
2. Preveri `appsettings.Local.json` v Gitu (točka 13).
3. Omeji pomnilnik SQL in vklopi RCSI (točki 5, 6).
4. Hramba posnetkov zaloge in izvlečkov (točki 3, 4).
5. Namesti API na strežnik ([Navodila/08_API_za_AI.md](../Navodila/08_API_za_AI.md)).
