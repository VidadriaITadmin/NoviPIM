# Arhitektura sistema NoviPIM — od vhodnih do izhodnih podatkov

Napisano: 2026-08-31. Ta dokument opisuje **dejansko stanje** sistema, ne načrtov.
Kjer nekaj še ne deluje ali je namerno izklopljeno, je to izrecno zapisano.
Namenjen je bralcu, ki sistema še ne pozna, in gre od splošne slike do podrobnosti.

Kazalo:

1. [Kaj je NoviPIM](#1-kaj-je-novipim)
2. [Velika slika — tok podatkov](#2-velika-slika--tok-podatkov)
3. [Iz česa je sistem sestavljen](#3-iz-česa-je-sistem-sestavljen)
4. [Kdo kaj proži — glavna tabela](#4-kdo-kaj-proži--glavna-tabela)
5. [Podatkovna baza](#5-podatkovna-baza)
6. [Vhodi](#6-vhodi)
7. [Sredica: preslikave, kanonični katalog, kategorije, mediji](#7-sredica-preslikave-kanonični-katalog-kategorije-mediji)
8. [Kakovost: validacija in objava](#8-kakovost-validacija-in-objava)
9. [Izhodi](#9-izhodi)
10. [Intranet](#10-intranet)
11. [Nadzor, alarmi in urniki](#11-nadzor-alarmi-in-urniki)
12. [Namestitev in okolja](#12-namestitev-in-okolja)
13. [Kaj namerno ne deluje ali še ni narejeno](#13-kaj-namerno-ne-deluje-ali-še-ni-narejeno)
14. [Znana neskladja v dokumentaciji](#14-znana-neskladja-v-dokumentaciji)
15. [Slovar pojmov](#15-slovar-pojmov)

---

## 1. Kaj je NoviPIM

NoviPIM je sistem za upravljanje podatkov o izdelkih (PIM — Product Information
Management) za približno **200.000 artiklov štirih podjetij** (v bazi so to organizacije
z ID 1–4: DEMO, IQLighting, Vidadria, Ediito). Njegova naloga je:

1. **zbrati** podatke o artiklih iz več virov (ERP SAOP, XML datoteke dobaviteljev,
   datoteke z zalogo, ročni vnosi),
2. jih **poenotiti** v en kanoničen katalog, ne glede na to, iz katerega vira so prišli,
3. jih **preveriti** (validacija: ali ima artikel vse, kar posamezen cilj zahteva),
4. in jih **oddati** naprej: kot CSV za spletno trgovino (Magento) in kot nadzorovan
   zapis nazaj v ERP SAOP.

Tehnološka osnova: **.NET 10** (C#), **Blazor Server** za spletni vmesnik (intranet),
**MS SQL Server** za bazo `PIM`, **PowerShell 7** za operativne skripte in **Windows
Task Scheduler** za samodejno proženje. Ni Node, ni React, ni ločenega frontend builda.

Ključno načelo celotnega sistema: **vsa logika in vse stanje živita v bazi**. Workerji
so kratkotrajni konzolni programi, ki se zaženejo, opravijo en cikel in končajo;
intranet je okno v bazo in nikoli ne poganja procesov; konfiguracija virov, preslikav,
validacije in izvozov so vrstice v tabelah, ne koda. Nov dobavitelj, nov stolpec izvoza
ali nova validacijska zahteva je praviloma `INSERT`, ne nova različica programa.

## 2. Velika slika — tok podatkov

```
  VHODI                      SREDICA (baza PIM)                       IZHODI
  ─────                      ──────────────────                      ──────

  SAOP iCenter API ──┐
  (katalog, 16 točk) │
                     │      ┌───────────┐   ┌──────────────┐   ┌─────────┐
  Dobaviteljev XML ──┼────▶ │ raw.Inbox │──▶│ map.*        │──▶│ canon.* │
  (NW, BT katalogi)  │      │ (surovo)  │   │ (preslikave) │   │ (enotni │
                     │      └───────────┘   └──────────────┘   │ katalog)│
  Spletni nazivi ────┘                                         └────┬────┘
  (XLSX zvezki, ročno)                                              │
                                                                    ▼
  Zaloge ────────────────▶ stock.*  (ločena, hitrejša pot)     ┌─────────┐
  (NW FTP, BT HTTP,                                            │ val.*   │ validacija
   SAOP GetStocks)                                             └────┬────┘
                                                                    │ samo VALID
  Stranke (SAOP) ────────▶ b2b.*                                    ▼
                                                               ┌─────────┐
                                                               │ pim.*   │ objavljeni
                                                               │         │ katalog
                                                               └────┬────┘
                                                                    │
                                            ┌───────────────────────┴──────────┐
                                            ▼                                  ▼
                                   katalog.csv              out.OutboxMessage
                                   stranke.csv             (odhodna vrsta
                                   (spletni izvoz na disk;            nazaj v SAOP;
                                    dostave naprej še ni)             odobri človek)
```

Vzporedno s podatkovnim tokom teče **nadzorna veriga** v shemi `ops`: vsak zagon
workerja se prijavi, utripa in odjavi; watchdog opazi zastoje in ustvari alarme;
po petih zaporednih napakah se postopek sam izklopi in pusti opozorilo.

Vodilo za branje sheme: podatek na poti proti izhodu **vedno napreduje skozi iste
postaje** — surovo (`raw`), izluščeno (`map`), poenoteno (`canon`), preverjeno (`val`),
objavljeno (`pim`), oddano (`out`). Vsaka postaja je SQL shema in vsak prehod je
procedura ali worker, ki ga je mogoče pognati tudi ročno.

## 3. Iz česa je sistem sestavljen

Rešitev `PIM_Solution\PIM.sln` ima 79 projektov: 7 knjižnic/aplikacij v `src\`,
10 workerjev v `workers\`, 3 orodja v `tools\` in 59 testnih projektov. Vsi ciljajo
`net10.0`.

### 3.1 Projekti `src\`

| Projekt | Vloga |
|---|---|
| `PIM.Intranet` | Blazor Server spletni vmesnik — edina stvar, ki jo uporabniki vidijo |
| `PIM.Migrator` | konzolno orodje, ki iz SQL migracij sestavi in preverja bazo |
| `PIM.XmlMapping` | knjižnica: XPath izluščanje in SQL preslikovalni cevovod (uporabljajo jo workerji) |
| `PIM.StockMapping` | knjižnica: zapis zaloge (`StockLandingWriter`) in CSV zaloge |
| `PIM.B2b` | knjižnica: B2B pravila, popusti, pogodba Magento CSV |
| `PIM.Outbound` | knjižnica: gradnja SAOP dokumentov, echo preverba, pravila lastništva polj |
| `PIM.Operations` | skupna operativna knjižnica: ovoj za `ops.BeginRun`/heartbeat, gesla, delovni zvezki |

### 3.2 Workerji (`workers\`)

Workerji so **run-once konzolni programi**: zaženejo se, opravijo en cikel, izpišejo
povzetek in se končajo. Niso Windows Service in niso stalno rezidenti — proži jih
Windows Task Scheduler ali človek iz ukazne vrstice. Prekrivanje dveh zagonov istega
cevovoda preprečuje SQL `sp_getapplock` (na ravni podjetje + cevovod).

| Worker | Kaj dela | Stanje |
|---|---|---|
| `PIM.KatalogWorker` | zajem kataloga iz SAOP API (16 končnih točk) + preslikava v `canon` | deluje, dnevno v nočnem toku |
| `PIM.SourceFetchWorker` | prevzem dobaviteljevih datotek (FTP/HTTP) v landing mapo | deluje, v 5-min ciklu |
| `PIM.XmlFileWorker` | branje dobaviteljevih XML/XLSX katalogov v `raw.Inbox` + preslikava | deluje, dnevno v nočnem toku |
| `PIM.StockFileWorker` | branje datotek z zalogo (NW CSV, BT XML) v `stock.*` | deluje, v 5-min ciklu |
| `PIM.SaopStockWorker` | zajem količin zaloge iz SAOP (`GetStocks`) v `stock.*` | deluje, v 5-min ciklu (živ klic le pri `PIM_SAOP_MODE=Live`) |
| `PIM.B2bWorker` | Magento CSV izvoz (`--export-magento`) | deluje, korak 8 nočnega toka |
| `PIM.OutboxDispatcher` | dostava odhodnih sporočil v SAOP (outbox) | mehanizem narejen; **nima urnika, proži se samo ročno; v SAOP še ni bilo poslano nič** |
| `PIM.Watchdog` | zazna zastale cevovode, ustvari alarme | deluje, v 5-min ciklu nadzora |
| `PIM.AlertDispatcher` | pošlje alarme po e-pošti/webhooku | teče v 5-min ciklu, a dostava je privzeto **izklopljena** (glej §11.3) |
| `PIM.FoundationWorker` | prazen `BackgroundService` skelet | neaktiven ostanek, ne uporablja se |

`workers\PIM.NwXmlWorker` ima samo `bin\` in `obj\`, izvorne kode ni in ni v `PIM.sln`
— je ostanek, ne worker.

### 3.3 Skripte (`scripts\`) in naloge

PowerShell skripte so **lepilo med Task Schedulerjem in workerji**: nastavijo okolje
(povezavo do baze, spremenljivke vira), pokličejo workerje v pravem vrstnem redu,
pišejo dnevnik in vrnejo izhodno kodo. Uporabnik jih lahko požene tudi ročno.

| Skripta | Vloga |
|---|---|
| `Nocno-vse.ps1` | nočni tok: vseh 8 korakov od gradnje do Magento izvoza |
| `Zaloga-cikel.ps1` | 5-minutni cikel zaloge: prevzem + branje vseh treh virov |
| `Nadzor.ps1` | 5-minutni nadzor: Watchdog + AlertDispatcher |
| `Namesti-opravila.ps1` | registrira/odstrani tri načrtovane naloge Windows (požene človek) |
| `Namesti-nocno-opravilo.ps1` | starejša samostojna registracija samo nočnega toka (presežena z `Namesti-opravila.ps1`) |
| `Nocni-zajem.ps1` | predhodnik nočnega toka (samo SAOP zajem); presežen z `Nocno-vse.ps1` |
| `run_tests.ps1` | edini merodajni testni zagon (build + vsi konzolni testni projekti + xUnit) |

### 3.4 Orodja (`tools\`)

`PIM.UserProvisioning` (ustvarjanje lokalnih uporabnikov), `PIM.FixtureExport`
(izvoz posnetih odgovorov za teste), `PIM.SaopXmlPreview` (suhi predogled SAOP
dokumentov, ki bi jih poslala odhodna pot). V mapi `tools\` je še
`PIM.RawPipelineReplay` (ročni ponovni zagon preslikave za en RunId) — ima izvorno
kodo, a ni vključen v `PIM.sln`.

## 4. Kdo kaj proži — glavna tabela

To je odgovor na vprašanje »kdo požene kateri korak«. Sprožilci so trije: **Windows
Task Scheduler** (samodejno, po registraciji nalog), **človek** (ročni ukaz ali klik)
in **drug korak v isti skripti**. Intranet ničesar ne proži — samo bere in piše bazo
(podrobno v §10.3).

| Kaj | Sprožilec | Kdaj | Kaj konkretno teče |
|---|---|---|---|
| Nočni tok (vsi vhodi → validacija → objava → izvoz) | naloga **PIM nocni tok** | vsak dan 02:30 | `pwsh Nocno-vse.ps1 -DanPolnegaZajema 1 -HkratnihPodjetij 4 -ZalogaIzSaop` |
| Cikel zaloge (prevzem + branje NW, BT, SAOP) | naloga **PIM zaloga** | vsakih 5 min (zamik 2) | `pwsh Zaloga-cikel.ps1 -Kaj Vse` |
| Nadzor (watchdog + alarmi) | naloga **PIM nadzor** | vsakih 5 min (zamik 4) | `pwsh Nadzor.ps1` |
| Registracija/odstranitev teh nalog | **človek** | enkratno | `pwsh Namesti-opravila.ps1` (po `AGENTS.md` §4.7 tega agent ne sme) |
| Odhodna pot v SAOP (outbox dispatch) | **samo človek, ročno** | — | `dotnet run --project workers\PIM.OutboxDispatcher -- --saop-documents` (+ `--send` za pravo pošiljanje); urnika ni |
| Odobritev odhodnega sporočila | **človek v intranetu** | — | stran `/outbound`, gumb Odobri (`out.ApproveMessage`) |
| Zajem spletnih nazivov (XLSX zvezki) | **samo človek, ročno** | — | `Nocno-vse.ps1 -MapaSpletnihNazivov <pot>`; registrirana naloga tega parametra ne podaja |
| Nowodvorski XML katalog v landing mapo | **človek, ročno** | — | vir `NW_XML` ima v registru `Kind=MAPA` — datoteko položi človek |
| Vklop/izklop posameznega postopka | **človek v intranetu** | — | Sistem → Urniki obdelav (`ops.ScheduleProfile`); worker ob naslednjem zagonu stikalo spoštuje |
| Ponovni vklop po samodejnem izklopu (5 napak) | **človek v intranetu** | — | ista stran, gumb Vklopi |
| Ročni zagon kateregakoli workerja | človek | — | `dotnet run --project workers\<worker>` (ročni zagon brez `--po-urniku` urnik namenoma obide) |

Vse tri naloge tečejo pod uporabnikovim računom (`RunLevel Limited`), z `IgnoreNew`
(brez podvajanja), `StartWhenAvailable` (nadoknadijo zamujen zagon) in skritim oknom
(`-WindowStyle Hidden`; otroški `dotnet` procesi podedujejo skrito konzolo — na
namizju se ne prikazuje nič). Podrobnosti v §11.4.

### 4.1 Koraki nočnega toka (`Nocno-vse.ps1`)

| # | Korak | Zakaj na tem mestu |
|---|---|---|
| 0 | gradnja rešitve | workerji tečejo z `--no-build`; če gradnja pade, ne teče nič |
| 1 | SAOP katalog | šifra artikla mora obstajati, preden jo drugi viri obogatijo |
| 1a | prevzem dobaviteljevih datotek | datoteke morajo biti na disku, preden ju bereta koraka 2 in 5 (korak 1 datotek ne potrebuje) |
| 2 | dobaviteljev XML (NW, BT) | lastnosti, kategorije, slike se vežejo na artikel po EAN |
| 3 | spletni nazivi | samo če je podana `-MapaSpletnihNazivov` (naloga je ne podaja) |
| 4 | preslikava zaostanka | kar je v `raw.Inbox` ostalo `Pending`, pride v katalog pred objavo |
| 5 | zaloge dobaviteljev | za vsa štiri podjetja |
| 6 | zaloga iz SAOP | samo s stikalom `-ZalogaIzSaop` (registrirana naloga ga podaja) |
| 7 | validacija in objava | `val.RunValidation` + `val.Promote` za vsako podjetje |
| 8 | Magento izvoz | `PIM.B2bWorker --export-magento` za vsako podjetje, v `izvoz\magento\<org>` |

Padec enega koraka ne ustavi ostalih; izhodna koda skripte je število padlih korakov.
Povzetek na koncu vedno pove tudi, koliko je v `raw.Inbox` ostalo `Pending` in
`Quarantined` — »vse OK« brez tega podatka je v preteklosti mesece skrivalo ležeče
podatke. Izmerjeno 2026-08-23: 6 korakov, 0 padlih, 2 min 39 s (validacija in objava
štirih podjetij 120 s, Magento izvoz 12 s).

## 5. Podatkovna baza

### 5.1 Sheme in njihove vloge

Ena baza `PIM`, več shem; vsaka shema je postaja v toku podatkov:

| Shema | Vloga |
|---|---|
| `raw` | nespremenjeni zajeti payloadi (`raw.Inbox`) in karantena — kar je prišlo, tako kot je prišlo |
| `map` | konfiguracija virov in preslikav (`SourceConnector`, `EntityMapping`, `FieldMapping`), izluščene vrednosti (`ExtractedValue`), slovarji in pretvorbe (`ValueLookup`, `FieldTransform`), mejniki (`Watermark`), delovni seznami neznanega (`MissingTranslation`, `MissingCategoryMap`, `UnmappedValue`) |
| `canon` | kanonični, virsko neodvisen katalog: `Product`, `ProductText`, `ProductAttribute`, `ProductCategory`, `ProductMedia`, `ProductPrice`, `ProductCommercial`, šifranti (`Warehouse`, `Language`, `WebSite`, `Codebook`) |
| `val` | validacija: profili (`ValidationProfile`), zahteve (`FieldRequirement`), stanja (`ProductValidationState`), težave (`ProductIssue`), objava (`Promote`) |
| `pim` | objavljeni katalog (`pim.Product` + otroške tabele) ter lastništvo in zgodovina polj (`FieldOwnership`, `ProductFieldHistory`, `ProductChangeBatch`) |
| `stock` | zaloge: `SyncRun`, `Snapshot`, `LandingRecord`, `Position`, `UnmatchedPosition`, `SaopProviderProfile` |
| `b2b` | stranke in komerciala: `Customer`, popusti po skupinah, artikel pri stranki, `AuditLog` |
| `out` | izhodi: register izvoznih profilov (`ExportProfile`, `ExportColumn`), izvozne procedure, odhodna vrsta v SAOP (`OutboxMessage`, `OutboxAttempt`, `SaopDocument`, `SaopXmlField`, `OwnershipPolicy`) |
| `ops` | obratovanje: teki (`PipelineRun`), zdravje (`IntegrationHealth`), urniki (`ScheduleProfile`), alarmi (`Alert`, `AlertDelivery`, `AlertRecipientConfig`), dnevniki (`ErrorLog`, `DeadLetterQueue`) |
| `sec` | uporabniki in vloge (`LocalUser`, `Role`, `LocalUserRole`) |
| `intranet` | bralne/zapisovalne procedure za spletni vmesnik (`GetProductCard`, `GetProductList`, `GetSchedules` …) |
| `dbo` | podjetja (`OrganizationConfig`), integracije (`IntegrationProfile`), ledger migracij (`SchemaMigration`) |

**`OrganizationId` je povsod obvezen izolacijski ključ** — podatki štirih podjetij se
nikoli ne mešajo. Vsak worker, vsaka procedura in vsak pogled delajo znotraj enega
podjetja (ali se izrecno zavrtijo čez vsa).

### 5.2 Kako baza nastane in kako se spreminja

Bazo iz nič sestavi konzolno orodje `PIM.Migrator`:

```powershell
dotnet run --project PIM_Solution\src\PIM.Migrator -- --create-database   # ustvari bazo + vse migracije
dotnet run --project PIM_Solution\src\PIM.Migrator                        # drugi zagon: vse preskoči
dotnet run --project PIM_Solution\src\PIM.Migrator -- --verify            # preveri F0–F10, nič ne spreminja
dotnet run --project PIM_Solution\src\PIM.Migrator -- --ustvari-admina X  # prvi skrbniški račun
```

Migracije so oštevilčene SQL datoteke v `PIM_Solution\sql\migrations`
(`NNN_Opis.sql`; trenutno 134 datotek, 001–136, številki 015 in 048 ne obstajata).
Migrator jih uporabi po vrsti, **vse v eni transakciji** pod `sp_getapplock`, in za
vsako zapiše SHA-256 hash v `dbo.SchemaMigration`. Pravila so trda:

- že uporabljene migracije se **nikoli ne ureja** — spremenjen hash je napaka;
  popravek je vedno nova, višja številka;
- ročne spremembe sheme v SSMS niso dovoljene; edina pot je nova migracija;
- ob padcu katerekoli migracije se razveljavi vse (baza ostane v prejšnjem stanju).

Povezavo bere iz okoljske spremenljivke `PIM_CONNECTION_STRING` ali iz
`ConnectionStrings:Pim` v `appsettings.Local.json` (ta datoteka ni v Gitu — glej
§12.1). V bazi se poleg sheme zasejejo tudi nastavitve: štiri podjetja, konektorji
virov, validacijski profili, urniki, izvozni profili — zato je sveža baza takoj
konfigurirana, prazni so samo podatki (artikli, cene, zaloge), ki jih naložijo vhodi.

## 6. Vhodi

Vsi katalozni vhodi tečejo skozi isti cevovod: surov zapis v `raw.Inbox` →
izluščanje po konfiguraciji v `map` → zapis v `canon`. Zaloga ima svojo, hitrejšo
pot naravnost v `stock.*`. Nobena vhodna pot ne piše v `pim.*` — tja pride podatek
šele skozi objavo (§8).

### 6.1 SAOP katalog (`PIM.KatalogWorker`)

Vir je ERP **SAOP iCenter API** (HTTP, Basic avtentikacija + glava `OrganisationId`
za izbiro podjetja; dostop zahteva VPN). Worker za vsako aktivno podjetje pokliče
**16 bralnih končnih točk**: 8 straničenih o artiklih (splošni podatki, opisi,
nazivi po jezikih, lastnosti po meri, planiranje, podatki o zalogi in kontih,
artikel pri stranki), 7 šifrantov (jeziki, valute, ceniki, skladišča, stranke,
popusti po skupinah, tehnološki proces) in cene (`GetPrices`, po cenikih).

Kako zajem deluje:

- **Vsaka prebrana stran gre sproti v `raw.Inbox`** (MERGE po ključu podjetje + vir +
  entiteta + stran + SHA-256 hash vsebine). Enaka vsebina se ne vstavi dvakrat.
- **Delta zajem je privzet**: worker bere mejnik iz `map.Watermark`, odšteje
  `LookbackDays` (privzeto 7) in zahteva samo spremenjene zapise. `--full` prebere
  vse; ker delta ne vidi brisanj, nočni tok 1. dan v mesecu naredi poln zajem.
- **Mejnik se premakne šele po uspešni preslikavi** in samo za entitete, kjer iz
  tega zagona ni ostalo nič `Pending`. Če preslikava ni tekla (npr.
  `--only-ingest`), mejnik stoji in naslednji zagon isto obdobje zajame znova.
  Zaostanek iz *prejšnjih* zagonov mejnika ne zadržuje — worker ga izpiše kot
  opozorilo, pospravi pa ga korak 4 nočnega toka (`--preslikaj-zaostanek`).
- Prehodne HTTP napake (408/429/502/503/504) se ponovijo trikrat z odmikom 1 s → 2 s
  → 4 s; trajna napaka ustavi samo tisto končno točko.
- Način določa `PIM_SAOP_MODE`: `Live` (pravi klic), `Fixture` (posneti odgovori za
  teste), `Disabled`. Preslikovalna stikala (`--map-run <RunId>`,
  `--znova-preslikaj <RunId>`, `--preslikaj-zaostanek`) delajo nad že zajetimi
  podatki in ne potrebujejo ne SAOP ne poverilnic.

Stanje preslikav: **vseh 16 končnih točk ima cilj v modelu** (postopno dodano do
migracije `087`) — izdelki, opisi, cene, nazivi po jezikih, lastnosti, skladišča,
jeziki, valute, ceniki, tehnološki proces, stranke, artikel pri stranki, popusti po
skupinah. Izmerjeno 2026-08-21: poln živ zajem vseh štirih podjetij je prinesel
195.756 artiklov; množična preslikava (migracija `044`) obdela ~2.000 zapisov/s.

### 6.2 Dobaviteljevi katalogi XML (`PIM.SourceFetchWorker` + `PIM.XmlFileWorker`)

Pot ima **namerno ločena koraka**, ker so napake prevzema (omrežje, poverilnice)
druga vrsta napake kot napake preslikave:

1. **Prevzem** (`PIM.SourceFetchWorker`): od kod se vir prevzame, je vrstica v
   registru `map.SourceFetchLocation` — `BT_XML` prek HTTPS, `NW_STOCK` prek FTP,
   `BT_STOCK` prek HTTPS, `NW_XML` pa ima `Kind=MAPA`: Nowodvorski ima svojo PIM
   platformo in XML **položi človek ročno** v landing mapo. Naslovi in poverilnice
   niso v bazi — register hrani samo ime ključa (npr. `Fetch:BT_STOCK`), vrednosti
   so v `appsettings.Local.json`. Datoteka se odloži v
   `PIM_Solution\data\prevzem\<SourceCode>\`; vsebina, ki je po SHA-256 enaka
   obstoječi, se zavrže (obdrži se stara datoteka z njenim časom).
2. **Branje** (`PIM.XmlFileWorker`): worker je **generičen** — v kodi ni imena
   nobenega dobavitelja. Kaj bere, mu povedo okoljske spremenljivke
   (`PIM_XML_SOURCE_CODE`, `PIM_XML_ORGANIZATION_ID`, `PIM_XML_ROOT`) in register:
   `map.EntityMapping` pove, kje v XML je zapis (`RecordXPath`), `map.FieldMapping`
   pa, kje je vsako polje (`FieldXPath`, poln XPath 1.0). Dve povsem različni obliki
   XML pokrije samo drugačen izraz v registru:

   ```
   Nowodvorski   attributes/attribute_ip/ip_value/text()
   Braytron      .//attribute[slug="ip"]/value/text()
   ```

   **Nov dobavitelj je zato vrstica v treh tabelah** (`map.SourceConnector`,
   `map.EntityMapping`, `map.FieldMapping`), ne nova različica programa. XLSX
   datoteke gredo skozi isti cevovod (pretvorba v generični XML).

Enoličnost `raw.Inbox` po hashu vsebine pomeni, da ponoven zajem nespremenjene
datoteke pade s SQL napako 2627 — worker jo ujame in šteje kot »že zajeto«. To je
zaščita pred podvojenim zajemom, ne okvara. Obe polni datoteki (NW 19 MB, BT 18 MB)
se bereta za vsa štiri podjetja; preslikava cele NW datoteke traja ~110 s.

### 6.3 Zaloge (`Zaloga-cikel.ps1`, vsakih 5 minut)

Zaloga tečejo po ločeni poti v `stock.*` in iz treh virov; vse tri v istem
petminutnem prehodu prevzame in prebere `Zaloga-cikel.ps1`:

- **Nowodvorski** (`NW_STOCK`): CSV s FTP (5 stolpcev po vrstnem redu: EAN, šifra,
  količina, datum dobave, prihajajoča količina). Najmanjši razmik med prevzemoma
  120 min.
- **Braytron** (`BT_STOCK`): XML prek HTTPS. Braytron dovoli en prenos na
  **180 minut** — ob prekoračitvi vrne HTTP 200 z zavrnitvijo `<Hata>`; prevzemnik
  to prepozna, zavrže odgovor, obdrži prejšnjo datoteko in zapiše cooldown v
  `.pocakaj`. Petminutni ritem torej ne pomeni petminutnega prenašanja.
- **SAOP** (`PIM.SaopStockWorker`): količine prek `api/Stock/GetStocks`; kateri
  vmesnik se uporablja, je vrstica v `stock.SaopProviderProfile`, šifre skladišč
  pridejo iz `canon.Warehouse`. Živ klic samo pri `PIM_SAOP_MODE=Live` — registracija
  naloge »PIM zaloga« je človekova privolitev v ta ponavljajoči se zunanji klic.

Zapis v bazo gre pri vseh treh skozi isti `StockLandingWriter`: `stock.SyncRun` +
`stock.Snapshot` (pri datotečnih virih NW/BT posnetek nosi **čas datoteke**, ne čas
zagona — ista datoteka je isti posnetek in drugi zagon mirno konča z 0; pri SAOP
posnetek nosi čas klica, zato je vsak zagon nov posnetek) + `stock.LandingRecord`,
nato za vsako
vrstico `stock.ApplyLandingRecord`: normalizacija (neveljavne vrstice v karanteno),
ujemanje z artiklom — najprej po šifri (`map.StockIdentityRule`), sicer po EAN, in
**od migracije `088` izključno znotraj istega podjetja** — ter zapis `stock.Position`.
Neujeta vrstica ne izgine: dobi `MatchKey='Unmatched'`.

### 6.4 Spletni nazivi (XLSX zvezki) — ročni vhod

Zvezki s spletnimi nazivi se vežejo na artikel po šifri, a korak teče **samo**, če
nočnemu toku podaš `-MapaSpletnihNazivov <pot>`. Registrirana naloga tega parametra
ne podaja, zato je ta vhod danes **ročen**: požene ga človek, ko dobi nove zvezke.

### 6.5 Stranke in B2B

Stranke, artikel pri stranki in popusti po skupinah pridejo **iz SAOP** (končne
točke `GetCustomers`, `GetItemCustomerDataV2`, `GetCustomerItemGroupDiscounts`)
skozi isti `raw → map → b2b.*` cevovod (preslikava od migracije `087`). Stanje:
11.558 strank, 9.207 zapisov artikel-pri-stranki, 4.270 popustov. Ločena landing
pot `b2b.LandingRecord → b2b.ApplyLandingRecord` v kodi obstaja, a je danes
**neaktivna veja** — noben worker je ne kliče (uporabljajo jo samo testi).

## 7. Sredica: preslikave, kanonični katalog, kategorije, mediji

### 7.1 Od surovega zapisa do kanona

Preslikava (`SqlMappingPipeline` iz `PIM.XmlMapping`; uporabljata jo KatalogWorker
in XmlFileWorker) teče v korakih:

1. **Izluščanje**: za vsako vrstico `raw.Inbox` z aktivno preslikavo se po XPath
   izrazih izluščijo pari polje/vrednost v `map.ExtractedValue`.
2. **Pretvorbe** (`map.ApplyValueTransforms`): nad vrednostmi se izvedejo koraki iz
   `map.FieldTransform` (TRIM, NUMBER, UNIT, PREFIX, BOOL, LOOKUP …) in prevodi iz
   slovarja `map.ValueLookup`. Izvirna vrednost vedno ostane v `RawValue`.
   **Manjkajoč prevod ni napaka** — vrednost gre naprej nespremenjena, manjkajoči
   prevod pa se zapiše v delovni seznam `map.MissingTranslation`.
3. **Kanonizacija** (`map.ProcessRawInbox` + entitetni postopki): MERGE v `canon.*`.
   Vsi zapisi so združevalni (»vstavi ali dopolni«), zato je ponovna preslikava
   varna in nič ne briše.
4. **Kategorije** (`map.ResolveProductCategories`): glej §7.2.

Zavrnjene vrednosti gredo v `map.UnmappedValue` z razlogom. Vse, kar sistem ne
razume, je torej **viden delovni seznam** (manjkajoči prevodi, neznane kategorije,
nepreslikane vrednosti), ne tiha izguba.

### 7.2 Kategorije

Kategorijska drevesa so po spletnih mestih v `canon.Category*` (register spletnih
mest `canon.WebSite`; drevesi za svetila in Videlektro — Videlektro je spletno
mesto/cilj, **ne** vhodni vir). Preslikava dobaviteljevih poti v drevo gre prek
`map.CategoryPathMap`; neznane poti pristanejo v `map.MissingCategoryMap` (delovni
seznam v intranetu, `/zajem/neujemanja`).

**Braytronove kategorije so preslikane delno**: migracija `105` (2026-08-27) je po
uporabnikovem Excelu zapisala 25 preslikav za `BT_XML` v drevo `svetila_si`
(pokrijejo 309 izdelkov). Preostalih ~53 izvornih kategorij namenoma čaka odločitve:
26 nima ciljne kategorije v drevesu, 7 je odvisnih od tipa izdelka, 15 je izključenih
z odločitvijo, 5 nima vnosa v Excelu.

### 7.3 Mediji (slike)

V sistemu so izključno **URL-ji** slik iz dobaviteljevega XML (`canon.ProductMedia`;
od migracij `135`/`136` vse slike izdelka z vrstnim redom, ne samo prva). Prenosa in
hrambe binarnih slik ni nikjer; slike se tudi **ne pišejo v SAOP** (polje `MEDIA` je
na trdem seznamu prepovedanih polj odhodne poti).

### 7.4 Lastništvo polj in zgodovina sprememb

Register `pim.FieldOwnership` pove za vsako sledeno polje, kdo je njegov gospodar:
`SAOP` (piše ga ERP; v intranetu se ne da urejati neposredno), `PIM` (piše ga
urednik v intranetu) ali `SHARED`. Triggerji nad `canon.*` ob vsaki spremembi
zapišejo zgodovino v `pim.ProductFieldHistory` (stara/nova vrednost, vir, izvajalec,
čas); kontekst spremembe nastavi `pim.SetChangeContext`. Razveljavitev (`undo`) je
danes podprta samo za PIM-lastni polji `Product.WebPublish` in `Product.IsActive`.

## 8. Kakovost: validacija in objava

### 8.1 Validacijski profili

Validacija je podatkovno gnana: profili, zahteve in stopnje resnosti so vrstice v
`val.*` — nova zahteva je `INSERT`. Pri **zajemu** je obvezna samo šifra
(`Product.ItemID`); vse ostalo je zahteva profila, ki artikel kvečjemu označi,
nikoli pa ne zavrne zajema.

| Profil | Blokira | Pomen |
|---|---|---|
| `SHARED_CORE` | ERP in splet | skupno jedro (EAN …) |
| `ERP_L1_SLO` | ERP | prodaja v Sloveniji |
| `ERP_L1_EU`, `ERP_L1_THIRD` | ERP | **dodatek** k SLO za EU/tretje trge, ne zamenjava |
| `COMMERCIAL_L2` | nič | komercialni podatki; napake so vidne, ne blokirajo |
| `WEB_svetila_si`, `WEB_videlektro` | splet | zahteve spletnih mest |
| `ERP_L1`, `WEB_B2C` | (starejša) | izpeljana iz izvoznih profilov; `ERP_L1` je privzeti profil objave |

Stopnji resnosti: `ERROR` postavi profil na `INVALID`; `WARNING` samo zabeleži
pomanjkljivost v `val.ProductIssue`. Skupni status artikla
(`canon.Product.ValidationStatus`) posluša samo blokirajoče profile in samo `ERROR`
zahteve. **Popolnost** (Completeness) se šteje po vseh aktivnih zahtevah — meri
polnost podatka, ne blokade, zato ni isto kot status.

### 8.2 Objava (publish)

Objava sta dve ločeni idempotentni proceduri, ki ju kot korak 7 požene nočni tok
(ali človek ročno):

1. **`val.RunValidation`** prebere zahteve in `canon.*`, za vsak profil izračuna
   napake, status in popolnost. V `pim.*` ne piše. Zna tudi revalidirati en sam
   izdelek (to se zgodi takoj, ko urednik shrani spremembo v intranetu).
2. **`val.Promote`** izdelke s statusom `VALID` po izbranem profilu (privzeto
   `ERP_L1`) z MERGE prenese iz `canon.*` v objavljeni katalog `pim.*` (glava + šest
   otroških tabel: besedila, cene, mediji, kategorije, lastnosti, trgovinski
   podatki). **Namenoma ne briše** vrstic, ki so iz `canon` izginile — brisanje je
   odločitev človeka.

Pomembna operativna posledica: izvozi berejo `pim.*`, zato mora objava teči po vsaki
migraciji, ki doda objavljeni stolpec — sicer izvoz kaže staro stanje.

»Pripravljenost za cilj« na kartici izdelka sta ločena statusa `ErpStatus` in
`WebStatus`: `VALID`, ko so vsi aktivni blokirajoči profili za ta cilj zeleni;
`INVALID` sicer; `NOT_CONFIGURED`, če blokirajočega profila ni. Napake uporabnik
vidi na `/kakovost` in `/kakovost/napake` (združeno **po polju**, ne po profilu),
na nadzorni plošči in na kartici izdelka; odpravi jih urednik — PIM-lastna polja
neposredno (s takojšnjo revalidacijo), SAOP-lastna pa samo prek odhodne vrste (§9.2).

## 9. Izhodi

Izhodna svetova sta dva in se ne mešata: **spletni izvoz** je pull brez stanja
(datoteka se vsakič izdela na novo), **odhodna pot v SAOP** je push s stanjem,
odobritvijo in potrditvijo.

### 9.1 Spletni izvoz (Magento CSV)

Obliko določa register: `out.ExportProfile` + `out.ExportColumn` (profil
`MAGENTO_PRODUCTS` z 213 aktivnimi stolpci in `MAGENTO_CUSTOMERS` z 19). Nov stolpec
ali kanal je vrstica v registru, ne koda.

Izvoz naredi `PIM.B2bWorker --export-magento --organization-id <N> --output-dir <dir>`
(korak 8 nočnega toka, za vsa štiri podjetja, v `izvoz\magento\<org>`): bere
**objavljeni sloj `pim.*`** in zapiše nedeljiv par `katalog.csv` +
`stranke.csv` (UTF-8 brez BOM, LF) — atomsko prek `.tmp` in zamenjave pod
ključavnico, z oznako `magento-export.complete` (ID zagona, čas, števili vrstic).
Porabnik sme brati šele, ko oznaka obstaja.

Stanje in meje:

- **Dostava naprej NI narejena** (namerna meja): datoteka nastane na disku, do
  Magenta (FTP/HTTP/mapa) je nihče ne odnese; evidence dostav še ni.
- `stranke.csv` je danes povsod samo glava — izvoz strank se veže na
  `pim.CustomerWebProfile`, kjer od migracij `097`/`098` sicer obstaja 4.390
  profilov, a nobeden nima `WebEnabled=1`: stranka brez določenega tipa (odločitev
  človeka) v izvoz ne sme.
- Preostalih šest izvoznih poti v bazi (`out.ExportProductsCsv`, B2B profili,
  zaloga) nima produkcijskega klicatelja — kličejo jih samo testi.
- Intranet stran `/splet` pokaže pripravljenost izvoza in **dejanske CSV datoteke z
  diska** (mapa iz nastavitve `WebExport:Directory`): seznam, predogled prvih 50
  vrstic in prenos. Namenoma bere isto datoteko, ki jo izdela worker — druga
  izvedba iste logike bi bila druga resnica.

### 9.2 Odhodna pot nazaj v SAOP (outbox)

To je nadzorovan zapis PIM-ovih sprememb nazaj v ERP. Vsak korak je ločen in
sledljiv:

1. **Nastanek.** Urednik v intranetu spremeni polje, ki ga piše SAOP → sprememba
   se ne zapiše v `canon`, ampak prek `out.EnqueueSaopItemChanges` v vrsto
   `out.OutboxMessage` (eno sporočilo = ena sprememba enega polja). Baza pri vpisu
   uveljavi vse varovalke: omogočen `dbo.IntegrationProfile`, polje v lasti PIM po
   `out.OwnershipPolicy`, polje del dokumenta. Lastniško politiko zaseje migracija
   `068` iz preglednice Mapiranje_SAOP_API_PIM.xlsx (112 vrstic; PIM sme pri
   izdelkih pisati 20 polj). **Integracijskega profila pa migracije ne zasejejo**
   — brez ročnega vpisa operaterja v `dbo.IntegrationProfile` pot fizično ne more
   oddati ničesar (vpis pade z napako 51001).
2. **Odobritev.** Privzeto sporočilo obstane v `PendingApproval`, dokler ga človek
   na strani `/outbound` ne odobri (`out.ApproveMessage`). Odobritev sporočilo samo
   uvrsti v vrsto — ne pošlje ga.
3. **Dostava.** `PIM.OutboxDispatcher --saop-documents` združi čakajoče spremembe
   enega artikla v en XML dokument (oblika je podatek v `out.SaopDocument` /
   `out.SaopXmlField`) in ga pošlje s pravilno avtentikacijo, glavo `OrganisationId`
   in `application/xml`. Uspeh je presek: HTTP 2xx **in** `ResultCode Ok/Created` v
   telesu — HTTP 200 z napako v telesu je zavrnitev. Napačna metoda
   (ItemAlreadyExists/ItemNotFound) se samopopravi enkrat, takoj. Privzeto je
   **suhi tek** (dokumenti v datoteke, baza nedotaknjena); pravo pošiljanje zahteva
   hkrati stikalo `--send` in poverilnice v okolju.
4. **Potrditev (echo).** `out.VerifyEcho` ob naslednjem vhodnem zajemu primerja
   dejansko vrednost v SAOP s poslano: ujemanje → `Verified`, neujemanje → `Drift`.
   Sistem po odklonu **nikoli ne pošlje samodejno**.

Stanja sporočila: `PendingApproval → Pending → Sending → Sent → Verified`, ob
napakah `Retry`/`Dead` (glede na razred napake), ob neskladju `Drift`, ob novejši
spremembi istega polja `Superseded`. Napaka avtentikacije samodejno ustavi cel kanal
(profil se izklopi, en alarm) — znova ga odpre človek.

**Trenutno stanje: v SAOP še ni bilo poslano nič.** Mehanizem je narejen in dokazan
lokalno (proti `127.0.0.1` fixture), a: (a) dispatcher nima urnika — proži se samo
ročno; (b) klic `out.VerifyEcho` iz vhodne preslikave še ni vgrajen, zato bi
poslano sporočilo danes obstalo v `Sent` in nikoli postalo `Verified`. Cene in
ceniki se **namerno ne pošiljajo** (njihov gospodar je SAOP); devet polj (šifra,
DDV, konti, mediji, kategorije, zaloga …) je trdo prepovedanih.

## 10. Intranet

### 10.1 Tehnična osnova

`PIM.Intranet` je Blazor Web App (Razor Components, `AddInteractiveServerComponents()`),
celoten vmesnik v slovenščini. Uporablja `app.UsePathBase("/PIM")` in dinamičen
`<base href>`, zato **brez sprememb kode deluje tako pod korenom strežnika kot pod
IIS virtualno aplikacijo `/PIM`** — vse notranje povezave so base-relativne. Razvojno
teče prek `dotnet run` (launch profil `http` na `localhost:5091`; v statusnih zapisih
in AGENTS.md se za ročni zagon uporablja tudi `127.0.0.1:5199`, E2E smoke test pa
teče na `5088` z `--no-launch-profile`).

### 10.2 Prijava, uporabniki, vloge

Avtentikacija je piškotna; vse strani razen prijave in `/health` zahtevajo prijavo
(globalni `FallbackPolicy`). Uporabniki so v `sec.LocalUser` z dvema izvoroma:
**LOCAL** (geslo PBKDF2-SHA256, 210.000 iteracij) in **DOMAIN** (preverjanje proti
Active Directory; deluje samo, če je računalnik v domeni). Vloge v `sec.Role`:
`ADMIN`, `CATALOG_EDITOR`, `COMMERCIAL`, `VIEWER`. Uporabniki nastanejo po treh
poteh: prvi skrbnik z `PIM.Migrator --ustvari-admina`, lokalni računi prek orodja
`PIM.UserProvisioning` ali strani Sistem → Uporabniki, domenski pa tako, da jih
ADMIN doda po uspešnem iskanju v AD. E-naslovi uporabnikov so vir prejemnikov
opozoril — brez naslova človek obvestil ne dobi.

### 10.3 Kaj intranet je in česa namerno ne dela

Intranet je **nadzorna plošča nad bazo**: bere in piše izključno MS SQL prek
parametriziranih procedur sheme `intranet`. Dvoje namenoma **ne** počne: ne kliče
HTTP-ja (to varuje test F8) in ne poganja procesov (načelo zasnove; posebne testne
varovalke za to ni). Vse zapisovalne akcije so
vpisi v bazo, ki jih workerji upoštevajo ob svojem naslednjem zagonu:

- urejanje PIM-lastnih polj (`pim.SaveProductTexts`/`SaveProductAttributes`) —
  takojšnja revalidacija tega izdelka;
- SAOP-lastna polja → odhodna vrsta (`/outbound`), kjer čakajo odobritev;
- Sistem → Urniki obdelav → stikala v `ops.ScheduleProfile`: **izklop tu ustavi
  postopek takoj** (worker brez omogočenega razporeda zavrne zagon z napako 51100),
  Windows naloga je samo »ura, ki tiktaka«.

Meni je razdeljen po fazah toka (Vhodni podatki, PIM katalog, Kakovost, Izhodi ERP
in splet, Poslovanje, Upravljanje, Administracija) in filtriran po vlogah. Glavne
strani: nadzorna plošča (KPI čez vsa podjetja), `/izdelki` (strežniška paginacija,
vsa štiri podjetja, filtri v URL), kartica izdelka (15 naborov: polja z lastništvom
in izvorom, besedila, cene, zaloga, kategorije, mediji, težave, zgodovina),
`/zajem*` (viri, teki, težave, preslikave — pogled v `raw`/`map`/`ops`),
`/kakovost*`, `/zaloge`, `/stranke`, `/preverbe` (preverbe cen in zalog),
`/outbound` in `/saop*` (odhodna pot), `/splet` (spletni izvoz), Sistem
(integracije, uporabniki, urniki).

## 11. Nadzor, alarmi in urniki

### 11.1 Prijava, utrip, odjava

Vsak worker ob zagonu pokliče `ops.BeginRun`: preveri, da je postopek v
`ops.ScheduleProfile` omogočen (sicer napaka 51100 »Razpored ni omogočen«), vzame
`sp_getapplock` proti sočasnemu teku (51101) in zapiše `Running` v
`ops.IntegrationHealth`. Med tekom utripa (`ops.RecordHeartbeat`), ob koncu
`ops.CompleteRun` zapiše uspeh/neuspeh in izračuna naslednji termin (od **začetka**
teka, da se razmik ne sešteva s trajanjem). Zagoni zajemnih in preslikovalnih
workerjev (katalog, XML, zaloge) so tudi vrstica v `ops.PipelineRun` s števci
prebranih/uspelih/padlih vrstic; nadzorni in izvozni workerji (Watchdog,
AlertDispatcher, SourceFetch, B2b, OutboxDispatcher) puščajo sled samo v
`ops.IntegrationHealth`.

Pomembno: vrstica `Running` **ni dokaz, da kaj teče** — proces, ki umre, jo pusti
za vedno. Zato vse varovalke (nočni tok, watchdog) gledajo tudi utrip: blokira samo
zagon, ki je `Running`, je zadnji za svoj cevovod **in** je utripnil v zadnjih 15
minutah.

### 11.2 Pet napak → samodejni izklop

`ops.CompleteRun` šteje zaporedne napake; ko jih je toliko, kot pove
`ops.ScheduleProfile.MaxConsecutiveFailures` (privzeto **5**), se postopek sam
izklopi (`IsEnabled=0`) in nastane kritični alarm `PipelineDisabled`, ki pove:
kateri postopek, katero podjetje, koliko napak, kaj je pisalo v zadnji, in napotek
na Sistem → Urniki obdelav, kjer ga človek po odpravi vzroka spet vklopi z enim
gumbom. Logika: klic, ki petkrat zapored ni uspel, se ne bo posrečil šestič.
Watchdog se edini nikoli ne izklopi sam — sicer bi izgubili prav tistega, ki naj
bi povedal, da je nekaj narobe.

### 11.3 Watchdog in dostava alarmov

Naloga »PIM nadzor« vsakih 5 minut požene `Nadzor.ps1`:

1. **`PIM.Watchdog`** → `ops.RunWatchdog`: zagone brez utripa označi za `Stale`,
   ustvari/posodobi alarme (`StaleHeartbeat`, `OutboundDead`, `OutboundDrift`,
   `StalledWatermark`; deduplicirani — obstoječemu se poveča števec). Samodejno
   razreši samo ozdravljene alarme vrste `StaleHeartbeat`; ostale vrste razreši
   človek. Nato napolni vrsto dostav iz prejemnikov v `ops.AlertRecipientConfig`.
2. **`PIM.AlertDispatcher`**: prevzame dostave in jih pošlje po e-pošti
   (`SmtpClient`, nastavitve `PIM_SMTP_*`) ali webhooku; neuspehi se ponavljajo z
   odmikom, po 5 poskusih `Dead`.

**Dostava je privzeto izklopljena**: brez okoljske spremenljivke
`PIM_ALERT_DELIVERY_ENABLED=true` dispatcher izvede samo stopnjevanje odhodnih
napak (`ops.EscalateOutboundEvents`, piše v bazo) in konča, ne da bi se dotaknil
vrste dostav — pošta ne odide. Vklop e-pošte zahteva poleg tega še
`PIM_ALERT_EMAIL_ENABLED=true` in nastavitve `PIM_SMTP_*` (ali webhook prek
`PIM_ALERT_WEBHOOK_URL`) ter omogočene prejemnike. Nobena skripta teh
spremenljivk ne nastavlja; vklop je zavesten korak ob namestitvi na strežnik. Do takrat so alarmi **vidni v aplikaciji** (Sistem → Integracije),
poslani pa ne.

Ob incidentu se gleda: `ops.ErrorLog`, `ops.Alert`, `ops.DeadLetterQueue` in
specifična karantena (npr. `raw.Inbox` s statusom `Quarantined`). Sledi se ne
brišejo, dokler incident ni raziskan.

### 11.4 Načrtovane naloge Windows

Registrira jih človek z `Namesti-opravila.ps1` (glej tabelo v §4). Tehnične
podrobnosti: polna pot do `pwsh.exe` (razporejevalnik ne deduje PATH), zamika
zaloge (+2 min) in nadzora (+4 min) sta razmaknjena, da nadzornik ne razglasi za
zastalo izvajanje, ki se je pravkar začelo; `ExecutionTimeLimit` 8 ur; okno je
skrito (`-WindowStyle Hidden` — prijava je `Interactive`, ker batch prijava
zahteva skrbniške pravice; na strežniku je pravi način namenski račun z »Log on as
a batch job«, takrat teče povsem nevidno tudi brez prijavljenega uporabnika).

Naloga, ki tiktaka pogosteje od razporeda v bazi (`ops.ScheduleProfile`; zalogovni
cevovodi so na 300 s), ne povzroči napake: worker s stikalom `--po-urniku` zagon,
ki še ni na vrsti, tiho preskoči (`intranet.IsPipelineDue`). Napaka 51100 nastane
le, če razpored za par (podjetje, cevovod) ne obstaja ali je izklopljen.

Dnevniki: `logs\nocno_<datum>_<ura>.log` (čisti se po 90 dneh),
`logs\nadzor-<datum>.log` in `logs\zaloga-<datum>.log` (brez samodejnega čiščenja).

## 12. Namestitev in okolja

### 12.1 Skrivnosti

Vse poverilnice in naslovi (baza, SAOP, dobavitelji, mapa spletnega izvoza) živijo
v `appsettings.Local.json` **v korenu repozitorija** — datoteka ni in ne sme biti
v Gitu. Ključi: `ConnectionStrings.Pim`, sklop `Saop` (BaseUrl, Username, Password,
PageSize, Organizations …), sklop `Fetch` (BT_XML, BT_STOCK, NW_STOCK s FTP
podatki), `WebExport.Directory`. Alternativa za workerje je okoljska spremenljivka
`PIM_CONNECTION_STRING`. Pozor: v `PIM_Solution\` je **druga** datoteka z istim
imenom (samo povezava + AD domena) — po navodilih se je ne ureja.

### 12.2 Razvojni/službeni računalnik

Postopek po korakih je v [`PRENOS_NA_SLUZBENI_RACUNALNIK.md`](PRENOS_NA_SLUZBENI_RACUNALNIK.md):
namesti .NET 10 SDK + PowerShell 7 + Git + SQL Server → kloniraj → build → ustvari
`appsettings.Local.json` → `PIM.Migrator --create-database` + `--verify` →
`--ustvari-admina` → `dotnet run` intranet → napolni podatke
(`Zaloga-cikel.ps1`, `Nocno-vse.ps1 -ZalogaIzSaop`) → `Namesti-opravila.ps1`.

Znane omejitve novega okolja: **SAOP zahteva VPN** (brez njega katalog in zaloga iz
ERP ne tečeta, vse ostalo dela); e-pošta ni nastavljena; domenska prijava dela samo
v isti domeni; Braytron dovoli en prenos na 3 ure. **Znana napaka:** na prazni bazi
migracije padejo na `070` (napaka 52701 — urnik dobaviteljevega XML je vstavljen za
tri podjetja, preverjajo pa se štiri; vrstica za podjetje 2 je na razvojnem
računalniku nastala ročno). Migrator ob padcu vse razveljavi; popravek je
enovrstičen in čaka odločitev.

### 12.3 Produkcija (IIS + Task Scheduler)

Delitev vlog na strežniku:

- **IIS gosti samo intranet.** Aplikacija je pripravljena za virtualno aplikacijo
  `/PIM` (glej §10.1); potrebna sta ASP.NET Core Hosting Bundle oz. self-contained
  publish (`deploy\Publish-Intranet.ps1`: win-x64, `app_offline.htm`, atomski
  backup, obvezen HTTP 200 na `/health`, samodejni rollback) in aplikacijski bazen
  brez skrbniških pravic. Blazor Server potrebuje vklopljene WebSockets.
- **Workerji NE tečejo pod IIS.** So run-once programi, proži jih izključno Task
  Scheduler pod namenskim najmanj privilegiranim računom (nikoli `LocalSystem` /
  `SYSTEM` — namestitvene skripte to izrecno zavrnejo).

Obstoječe deploy skripte (`PIM_Solution\deploy\`): `Apply-Migrations.ps1` (+
`Backup-PIM.sql` pred migracijami), `Install-Workers.ps1` in
`Configure-ScheduledTasks.ps1` (pokrivata **samo** Watchdog in AlertDispatcher;
obe podpirata `-DryRun`/`-WhatIf`), `Publish-Intranet.ps1`. Pozor:
`Install-Workers.ps1` oba workerja poleg objave registrira tudi kot Windows
storitev (`New-Service`), kar je v neskladju z run-once zasnovo in z roadmapom —
za proženje se uporabi `Configure-ScheduledTasks.ps1`, registracija storitve pa
je napaka skripte, ne arhitekture. Namestitev preostalih
workerjev v `C:\PIM\Workers\<worker>` z ovojnimi skriptami in namenskim računom je
popisana v `deploy\PRODUCTION_ROADMAP.md` — to je **načrt**, ne stanje. Priporočeni
vzorec pravic: worker račun samo `EXECUTE` na svojih procedurah, intranet račun na
`intranet.*`, brez `db_owner`.

## 13. Kaj namerno ne deluje ali še ni narejeno

Zaprt seznam, da se napake ne išče tam, kjer je ni:

| Kaj | Stanje | Kje je zapisano |
|---|---|---|
| Dostava Magento CSV do spletne trgovine | **ni narejeno** (namerna meja) — datoteka konča na disku | `EXPORTS.md` §8, `ANALIZA_IZVOZI.md` |
| Pošiljanje v SAOP (outbox) | mehanizem narejen, **nič še ni bilo poslano**; brez urnika, brez echo zanke | `ODHODNA_POT_SAOP.md` §8 |
| Dostava alarmov (e-pošta/webhook) | privzeto izklopljena (`PIM_ALERT_DELIVERY_ENABLED`) | §11.3 |
| Izvoz strank (`stranke.csv`) | samo glava — 4.390 profilov obstaja, a nobeden nima `WebEnabled=1` (tip stranke je odločitev človeka) | `TASKBOARD.md`, migraciji `097`/`098` |
| Del Braytronovih kategorij | 25 preslikav je od migracije `105` vpisanih; ~53 izvornih kategorij namenoma čaka odločitve | §7.2, `TASKBOARD.md` |
| Nowodvorski XML katalog | prevzem je ročen (`Kind=MAPA`) po odločitvi uporabnika | migracija `099` |
| Spletni nazivi v nočnem toku | tečejo samo z ročnim parametrom `-MapaSpletnihNazivov` | `Nocno-vse.ps1` |
| Migracija `070` na prazni bazi | pade (52701); popravek čaka odločitev | `PRENOS_NA_SLUZBENI_RACUNALNIK.md` §4.4 |
| Binarne slike | ni prenosa/hrambe — samo URL-ji | §7.3 |
| Vnos/potrjevanje prevodov v intranetu | ni zapisovalne poti — edina pot je SQL; intranet kaže samo vrzeli | `INTRANET.md` |
| Undo | samo `Product.WebPublish` in `Product.IsActive` | `DATABASE.md` |
| `PIM.FoundationWorker`, `PIM.NwXmlWorker` | neaktivna ostanka | §3.2 |
| B2B landing pot (`b2b.ApplyLandingRecord`) | neaktivna veja — stranke pridejo iz SAOP prek `map` | §6.5 |
| Registrirani pogled za zalogo Vidadrie | vpisan izklopljen, dokler ni znan `RegisteredViewId` | migracija `065` |

## 14. Znana neskladja v dokumentaciji

Ob branju starejših dokumentov upoštevaj datum — sistem se je razvijal hitreje od
dokumentov:

- **.NET različica**: koren `CLAUDE.md` navaja .NET 9, `PIM_Solution\README.md`
  .NET 8 — dejansko vsi projekti ciljajo `net10.0` in navodila zahtevajo .NET 10 SDK.
- **`DATABASE.md`** pravi »migracije 001–100« — dejansko jih je 134 (001–136).
- **`ZAJEM-SAOP.md` §8** pravi »preslikane 3 od 16 entitet« — od migracije `087`
  imajo cilj vse; novejše stanje je v `WORKERS.md`.
- **Tabela workerjev v `WORKERS.md`** (stanje 13. 8.) pravi, da StockFileWorker in
  SaopStockWorker ne pišeta v bazo — kasnejši razdelki istega dokumenta in koda
  kažejo, da pišeta.
- **Porti intraneta**: 5091 (launch profil), 5199 (ročni zagon po AGENTS/README),
  5088 (E2E smoke) — vsi so resnični v svojem kontekstu.
- **Stare nočne naloge**: »NoviPIM - nocni zajem SAOP« (02:00) in »PIM nocno
  opravilo« sta preseženi s »PIM nocni tok«; `Namesti-opravila.ps1 -Odstrani` ju
  **ne** odstrani — če sta na stroju še registrirani, ju odstrani ročno v Task
  Schedulerju.
- **`EXPORTS.md`** (pregled 2026-08-09) opisuje starejše stanje odhodne poti;
  novejša resnica je `ODHODNA_POT_SAOP.md` (2026-08-23).

## 15. Slovar pojmov

| Pojem | Pomen |
|---|---|
| **organizacija / podjetje** | eno od štirih podjetij (`dbo.OrganizationConfig`, ID 1–4); trdi izolacijski ključ vseh podatkov |
| **konektor / vir** | vrstica v `map.SourceConnector` (npr. `SAOP_IQLIGHTING`, `NW_XML`, `BT_STOCK`); pove, od kod podatek prihaja in kako se razume |
| **cevovod (pipeline)** | poimenovan postopek v `ops` (npr. `SAOP_PRODUCTS`, `GENERIC_XML`, `STOCK_FILE`, `WATCHDOG`), ki se mu meri zdravje in urnik |
| **RunId / tek** | en zagon enega cevovoda (`ops.PipelineRun`); vse zajete strani nosijo njegov RunId |
| **watermark / mejnik** | čas v `map.Watermark`, do katerega je vir dokazano zajet in preslikan; osnova za delta zajem |
| **karantena** | zapisi, ki jih sistem ni mogel uporabiti (v `raw`, `stock` …); vidni, ne izbrisani |
| **landing mapa** | `PIM_Solution\data\prevzem\<vir>` — kamor prevzemnik odloži dobaviteljeve datoteke |
| **kanonični katalog** | `canon.*` — poenoteni podatki vseh virov, še neobjavljeni |
| **objava / promocija** | `val.Promote` — prenos veljavnih artiklov iz `canon` v `pim`; izvozi berejo samo `pim` |
| **profil (validacijski)** | nabor zahtev za en cilj (ERP SLO/EU, splet, komerciala) s stopnjo resnosti |
| **outbox** | vrsta `out.OutboxMessage` — spremembe, ki čakajo odobritev in pošiljanje v SAOP |
| **echo / drift** | primerjava poslane vrednosti z dejansko v SAOP ob naslednjem zajemu; neskladje = `Drift` (odklon) |
| **lastništvo polja** | kdo sme polje pisati: SAOP, PIM ali SHARED (`pim.FieldOwnership`, `out.OwnershipPolicy`) |
| **heartbeat / utrip** | periodični znak življenja teka; brez njega watchdog tek razglasi za zastalega |
| **fixture / replay** | posneti odgovori za teste; razvoj nikoli ne kliče živega SAOP ali dobavitelja |
