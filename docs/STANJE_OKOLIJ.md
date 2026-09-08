# Stanje okolij PIM — DEV / TEST / PRD

> Ta dokument je namenjen kopiranju v Word na SharePointu in sprotnemu poročanju. Vsak
> razdelek ima tabelo, v katero se vpisuje stanje; zgodovina sprememb je na dnu.
> Posodobljeno: 2026-09-03 (po nočnem delu 2026-09-02/03).

## 1. Kje kaj teče

| Okolje | Računalnik / strežnik | Baza | Koda (veja) | Migracija | Intranet | Načrtovana opravila |
|---|---|---|---|---|---|---|
| **DEV** | razvojni računalnik `DESKTOP-TONVQHJ` | `localhost\MSSQLSERVER3`, baza `PIM` | `feature/izhodi-erp-01-saop-polji` | **150** | `http://127.0.0.1:5199/PIM` (ročni zagon) | `PIM zaloga` (5 min), `PIM nadzor` (5 min), `PIM nocni tok` (02:30) — vsa tri aktivna |
| **TEST** | službeni strežnik (ime: ______) | baza `PIM_TEST` (ime: ______) | — še ni preneseno | — | — | — |
| **PRD** | — | — | — | — | — | — |

Navodilo za prenos DEV → TEST: [`docs/PRENOS_NA_TEST.md`](PRENOS_NA_TEST.md).

## 2. Kaj je na DEV narejeno in preizkušeno (2026-09-03)

| Področje | Stanje | Dokaz |
|---|---|---|
| Branje iz SAOP (16 končnih točk, katalog, cene, ceniki, stranke, zaloga) | **dela**, samodejno (nočni tok + 5-min zaloga) | `ops.PipelineRun`, `ops.IntegrationHealth = Healthy` |
| Zaloga Vidadria iz registriranega pogleda SAOP (5 količin) | **dela** (migracija 145) | živi zajem 2026-09-02: 3.156 vrstic, 0 v karanteni |
| Zaloga IQLighting iz GetStocks (skladišče Brnčičeva 13) | **dela** | 8.734 pozicij |
| Dobaviteljeva zaloga NW (FTP) in BT (HTTPS) | **dela**, 5 min | `stock.Snapshot` |
| Dobaviteljev katalog NW/BT XML | **dela**, nočno (NW datoteka ročno v mapo) | `raw.Inbox`, `canon.ProductAttribute` 362.417 |
| Validacija ERP (SLO/EU/THIRD), Komerciala, Splet | **dela**, po vsakem zajemu in ob shranjevanju | `val.ProductValidationState` |
| Nabor atributov po kategoriji (obvezen/priporočen/izločen) | **dela** (147/148), napolnjen iz mastrov starega PIM-a (173): 484 vrstic v 46 kategorijah; pregled in množično urejanje na `/nastavitve/nabori-atributov` (170) | `/nastavitve/nabori-atributov`, `/nastavitve/kategorije` → Atributi |
| Pravila za nazive z prevodi | **dela** (149), eno neaktivno predlogo je treba pregledati in vklopiti | `/pravila/nazivi` |
| Spletni izvoz — čisti podatki (objavljen + spletna stran + veljaven) | **dela** (146) | org 3: 2.368 vrstic, org 2: 1.957 |
| Zaloga v spletnem izvozu (VID + IQL Brnčičeva, dobavitelj, skladišče) | **dela** (146) | `NW.10157`: 2 + 1 = 3 |
| Hitra osvežitev cen in zalog (magento-stock-prices.csv) | **dela**, vsakih 5 minut | `logs\zaloga-*.log`: »Izvoz cen in zaloge za splet« |
| Prag faktorja marže pod nadzorom uporabnika | **dela** (150) | `/preverbe` |
| Izvoz zalog z izbiro SAOP / dobavitelj | **dela** (150) | `/zaloge` → Prenesi zalogo |
| Digitalni cenik (tisk / PDF) | **dela** (150) | `/cene/tisk` |
| Uvoz artiklov iz Excela → čakalna lista SAOP | **dela** (obstoječe, povezava z /izdelki) | `/saop/artikli` |
| Pisanje v SAOP: artikli (20 polj) | **dela**, z odobritvijo | `/saop` |
| Pisanje v SAOP: cene, ceniki, stranke | **ne** — lastništvo je SAOP (`out.OwnershipPolicy`), odločitev uporabnika | `docs/ODHODNA_POT_SAOP.md` §7 |
| Dostava datotek v Magento (FTP/HTTP) | **ne** — datoteke nastanejo v `izvoz\magento\<podjetje>\`, dostave ni | `docs/EXPORTS.md` §8 |
| Alarmi po e-pošti | **ne** — SMTP nastavitve (okoljske spremenljivke) čakajo človeka | `STATUS.md` |

Testi: `scripts\run_tests.ps1` (60 projektov + xUnit) — rezultat zadnjega zagona je zapisan v `STATUS.md`.

## 3. Kaj čaka odločitev lastnika

| # | Odločitev | Kje piše | Posledica, če ni odločena |
|---|---|---|---|
| 1 | Cene/ceniki/stranke: ali jih PIM sme pisati v SAOP (sprememba `out.OwnershipPolicy`) | `docs/ODHODNA_POT_SAOP.md` | urejanje cen na intranetu ostane samo prikaz |
| 2 | Kam in kako se dostavijo CSV datoteke Magentu (mapa/FTP/HTTP, kdo bere) | `docs/EXPORTS.md` §8 | datoteke ostanejo na disku razvojnega računalnika |
| 3 | En artikel več podjetij: vrstni red podjetij za združen katalog, 99 šifer z različnim EAN | `docs/EN_ARTIKEL_VEC_PODJETIJ.md` | izvoz ostane po podjetjih (danes za VID in IQL vsak svoja datoteka) |
| 4 | Migracija 070 pade na prazni bazi (svež TEST) — popravek ali obnovitev varnostne kopije DEV | `docs/PRENOS_NA_TEST.md` | brez tega TEST ni mogoče postaviti iz nič |
| 5 | SMTP za alarme (`PIM_SMTP_*`) | `STATUS.md` | alarmi ostanejo samo v aplikaciji |
| 6 | Servisni račun za načrtovana opravila na strežniku (ali storitev PIM.Scheduler) | `docs/NACRT_RAZPOREJEVALNIK.md` | opravila na strežniku ne tečejo brez prijavljenega uporabnika |
| 7 | Pregled naborov iz mastrov (173) — potrditi ali popraviti ravni, dodati atribute, ki jih register še nima (`docs/NABORI_ATRIBUTOV_IZ_MASTROV.md`, razdelek »Kar ni preslikano«); katera pravila za nazive se vklopijo | `/nastavitve/nabori-atributov`, `/nastavitve/atributi`, `/pravila/nazivi` | nabor je izhodišče iz mastrov, ne potrjena odločitev; nazivi ostanejo iz virov |

## 4. Poročilo po dnevih (vpisuj sproti)

| Datum | Okolje | Kaj je bilo narejeno | Kdo | Dokaz / opomba |
|---|---|---|---|---|
| 2026-09-02 | DEV | Zaloga iz SAOP ponovno vklopljena po izpadu VPN; kanal SAOP_PRODUCT odprt | David | `STATUS.md` |
| 2026-09-02/03 | DEV | Migracije 145–150: registrirani pogled, pravila spletnega izvoza in zaloga v datoteki, hitri profil, nabor atributov, pravila nazivov, prag faktorja, izvoz zalog, cenik za tisk; popravek nočnega toka (`*.pocakaj`) | Claude (seja) | `git log` na veji, `run_tests.ps1` |
| | TEST | | | |
| | PRD | | | |

## 5. Kontrolni seznam pred prenosom na naslednje okolje

- [ ] `scripts\run_tests.ps1` → `REZULTAT: VSE OK`
- [ ] `dotnet run --project PIM_Solution\src\PIM.Migrator -- --verify` → izhod 0
- [ ] `git status --short` čist, veja commitana (push je odločitev lastnika)
- [ ] `appsettings.Local.json` za ciljno okolje pripravljen ločeno (ni v Gitu)
- [ ] Odprte odločitve iz razdelka 3 pregledane
- [ ] Po prenosu: kontrolne poizvedbe iz `docs/PRENOS_NA_TEST.md` §7
