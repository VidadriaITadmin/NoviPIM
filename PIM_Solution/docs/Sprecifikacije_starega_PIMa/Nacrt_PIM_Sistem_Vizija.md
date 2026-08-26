# PIM sistem — vizija in stanje (NoviPIM)

Verzija: 2.0 · Datum: 2026-08-26 · Status: referenčni dokument, **prepisan za NoviPIM**

> **Kaj je ta dokument in kaj ni.**
> Različica 1.0 je opisovala **stari sistem** (`..\PIM_test`): njegove sheme, poti,
> workerje in izmerjeno stanje. Ta različica ohrani poslovno vizijo — ker se ni
> spremenila — in vse tehnične navedbe prepiše na dejanski NoviPIM.
> Izvirnik je ohranjen v [`izvirniki_stari_PIM/`](izvirniki_stari_PIM/).
>
> Pravila in ozemlja so v [`AGENTS.md`](../../../AGENTS.md), trajni zemljevid faz v
> [`docs/PRODUKTNI_MODEL_PIM.md`](../../../docs/PRODUKTNI_MODEL_PIM.md), izmerjeno stanje v
> [`STATUS.md`](../../../STATUS.md). Ta dokument jih **ne podvaja** — pove POMEN in NAMEN
> ter kaj uporabniki od sistema pričakujejo. Kjer se razhaja s `STATUS.md`, velja `STATUS.md`.

---

## 0. Kaj je pri prepisu izpadlo in zakaj

Da se stari pojmi ne bi vlekli naprej po navadi:

| Iz stare vizije | Zakaj ne velja za NoviPIM | Kaj je namesto tega |
|---|---|---|
| `_SPEC/PIM_SISTEM_MENI_Master_Specifikacija.txt` | ni del tega repozitorija | `AGENTS.md` §2.1 + `docs/PRODUKTNI_MODEL_PIM.md` |
| `STG` kot vmesna plast toka | v NoviPIM ne obstaja | `raw.Inbox` → `map.*` → `canon.*` → `val.*` → `pim.*` |
| `pim.OutputChannel` / `pim.OutputColumn` | poimenovanje starega registra izvozov | `out.ExportProfile` / `out.ExportColumn` |
| `pim.vw_StockUnified` | pogled starega sistema | `stock.Position`, `stock.Snapshot`, `stock.UnmatchedPosition` |
| shema `media.*` | ne obstaja | `canon.ProductMedia`, `canon.ProductDocument`, `pim.ProductMedia` |
| `pim.Attribute` kot ravni slovar | tabele ni; atribut je **koda vrednosti** v `canon.ProductAttribute` | glej vrzel 4.1 |
| trije kanali ERP / Komerciala / Splet | poenostavitev; register jih ima sedem | `val.ValidationProfile` (7 profilov + 2 zapuščinska) |
| 6 Windows workerjev | drugačna zasedba | 10 workerjev v `PIM_Solution\workers\` |
| makete `UX_pictures/`, `docs/PIM_OS_Mockup/` | vira ni v tem repozitoriju | `PIM_Solution\UX\`, `docs/NACRT_INTRANET_PRENOVA.md` §13 |

Poslovne trditve iz starega sistema, ki jih v NoviPIM **ni mogoče izmeriti** (119 ročno
vzdrževanih Excel datotek, 39 različic glave, 53 kategorij s 16–123 atributi iz 61 master
datotek), so ohranjene kot **podedovano izhodišče**, izrecno označene. Niso dokaz o NoviPIM.

---

## 1. Kaj PIM je in zakaj obstaja

PIM ni »baza artiklov«. Je **posredniška plast med tremi svetovi**, ki so si prej podajali
podatke ročno prek Excelov: ERP (SAOP iCenter), dobavitelji/proizvajalci (Nowodvorski in
Braytron XML, CSV/FTP) in spletna prodaja (Magento).

*Podedovano izhodišče (stari sistem, tu neizmerljivo):* pred PIM-om je podjetje uvažalo in
izvažalo artikle prek 119 ročno vzdrževanih Excel datotek, z ročnim štetjem znakov namesto
validacije.

Dejanski tok NoviPIM:

```text
SAOP API (16 bralnih končnih točk) · dobaviteljski XML · datoteke (CSV/Excel) · ročni vnos
        ↓
raw.Inbox                    zajeta stran, dedup po hashu, karantena, mejnik v map.Watermark
        ↓  map.ProcessRawInbox + registrirane preslikave (map.FieldMapping, map.EntityMapping,
        ↓  map.ValueLookup, map.FieldTransform, map.CategoryPathMap)
canon.*                      kanonični katalog: Product, ProductText, ProductAttribute,
        ↓                    ProductCategory, ProductMedia, ProductDocument, ProductPrice,
        ↓                    ProductCommercial, ProductPlanning, ProductStockAccounting
val.*                        7 profilov, ERROR/WARNING, BlocksErp/BlocksWeb, val.ProductIssue
        ↓  val.Promote (vstopnica za objavo)
pim.*                        objavljeni katalog + lastništvo polj + zgodovina + razveljavitev
        ├──────────────→ out.OutboxMessage → SAOP (odobritev → poskus → odgovor → echo)
        └──────────────→ out.ExportProfile/ExportColumn → CSV za splet (Magento)
                              ↓
                    ops.Alert / e-pošta / nadzor (ops.IntegrationHealth, ops.Heartbeat)
```

**`OrganizationId` je meja podatka povsod.** Štiri podjetja (DEMO, IQLighting, Vidadria,
Ediito) si delijo bazo, ne pa števcev, alarmov in dejanj.

---

## 2. Kaj sistem danes zna — izmerjeno, ne domnevano

Številke so meritve iz `STATUS.md` in `docs/ANALIZA_*.md`; ob vsaki je datum, ker se
spreminjajo. Register migracij je 2026-08-26 na `099`.

| Domena | Stanje | Zadnja meritev |
|---|---|---|
| **Zajem** | 10 workerjev (`PIM.KatalogWorker`, `PIM.SaopStockWorker`, `PIM.XmlFileWorker`, `PIM.NwXmlWorker`, `PIM.StockFileWorker`, `PIM.B2bWorker`, `PIM.FoundationWorker`, `PIM.OutboxDispatcher`, `PIM.AlertDispatcher`, `PIM.Watchdog`). **Vseh 16 bralnih končnih točk SAOP ima cilj v modelu** (migracija 087). `raw.Inbox` brez vrstic `Pending`. | 2026-08-24 |
| **Katalog** | `canon.Product` **196.531** artiklov: IQLighting 111.063, Ediito 39.130, Vidadria 28.897, DEMO 17.425 | 2026-08-24 |
| **Preslikave** | `map.ValueLookup` 6.316 vrstic, `map.FieldTransform` 40, lastnosti iz NW XML 108 in BT XML 76 preslikav (migraciji 054/055) | 2026-08-22 |
| **Validacija** | 7 profilov kot vrstice registra: `SHARED_CORE`, `ERP_L1_SLO`, `ERP_L1_EU`, `ERP_L1_THIRD`, `COMMERCIAL_L2`, `WEB_svetila_si`, `WEB_videlektro`; resnost `ERROR`/`WARNING`, obseg blokade `BlocksErp`/`BlocksWeb`. Zapuščinska `ERP_L1` in `WEB_B2C` še živita. | 2026-08-21 |
| **Objava** | `val.Promote` je pognana za vsa štiri podjetja; **89.129** objavljenih izdelkov, vstopnica je še vedno `ERP_L1` | 2026-08-23 |
| **Sledljivost** | `pim.FieldOwnership` (20 sledljivih polj), `pim.ProductFieldHistory`, `pim.ProductChangeBatch`, množični triggerji prek `SESSION_CONTEXT` | 2026-08-13 |
| **Razveljavitev** | `pim.UndoProductField` / `pim.UndoProductBatch` delujeta, a **samo za PIM-lastni polji `WebPublish` in `IsActive`** | 2026-08-13 |
| **Zaloga** | `stock.Position` 168.594; dobaviteljska zaloga teče za vsa štiri podjetja; **pisanja nazaj v ERP ni in ne bo** (namerna meja) | 2026-08-23 |
| **Cene** | `canon.ProductPrice` polnjen iz SAOP (za IQLighting 144.816 vrstic po polnem zajemu); pisanja cen v SAOP ni | 2026-08-21 |
| **Mediji** | `canon.ProductMedia` iz dobaviteljskih XML (Braytron 1.384 slik); `canon.ProductDocument` od migracije 095 | 2026-08-23 |
| **Stranke / B2B** | `b2b.Customer` **11.558**, `b2b.CustomerItem` 9.207, `b2b.CustomerItemGroupDiscount` 4.270, skupinski popusti, pragovi, poštnina, `pim.CustomerWebProfile` z delovnim seznamom odločitev (migraciji 097/098) | 2026-08-24 |
| **Izvoz na splet** | Magento izvoz teče v živo za vsa štiri podjetja; vrednost ima **180 od 213 stolpcev**, polnost celic **8,2 %**. Od 7 izvoznih profilov ima poganjalnik **en**. Dostave do Magenta ni (namerna meja). | 2026-08-23 |
| **Izhod v ERP** | shema in koda obstajata (`out.OutboxMessage`, `out.OutboxAttempt`, `out.OutboundBatch`, `out.SaopDocument`, `out.SaopItemAssignment`, razvrstitev napak, `Superseded`, echo) — **skozi pot ni šlo nikoli nobeno sporočilo** | 2026-08-22 |
| **Varnost** | lokalna (PBKDF2-SHA256) + domenska (AD) prijava, vloge `ADMIN` / `CATALOG_EDITOR` / `COMMERCIAL` / `VIEWER`, piškotna seja, revizijski zapisi | 2026-08-24 |
| **Intranet** | Blazor Web App, .NET 10, interaktivni strežniški način, pot `/PIM`, slovenske poti, navigacija v kodi (`PimNavigation`) — pretežno **bralen** | 2026-08-24 |
| **Nadzor** | `ops.IntegrationHealth`, `ops.Heartbeat`, `ops.Alert`, `ops.DeadLetterQueue`, `PIM.Watchdog`; dostava alarmov privzeto izklopljena | 2026-08-13 |

---

## 3. Kaj sistem MORA omogočati (želje, ki se niso spremenile)

1. **En sistem resnice namesto razpršenih Excelov.** Vsaka nova zahteva (nov proizvajalec,
   nova spletna stran, novo obvezno polje) gre skozi **vrstico registra**, ne skozi novo
   kopijo datoteke in ne skozi nov `IF` v proceduri.
2. **Nič ne gre na splet ali v ERP brez nadzora kakovosti.** Validacija ni administrativna
   ovira, ampak zaščita: kupec ne sme videti artikla brez cene, slike ali naziva, ERP ne sme
   dobiti nepopolnega zapisa.
3. **Zanesljivo, ne »trenutno delujoče«.** Stanje se **izmeri**, preden se razglasi za
   končano. Poročilo, ki se ne ujema z izhodom ukaza, je hujša napaka kot neopravljeno delo
   (`AGENTS.md` §11).
4. **B2B pravila na enem mestu** — popusti, ceniki, poštnina, tipi strank, izjeme — kot
   podatek z zgodovino, ne kot dogovor v glavi ali v e-pošti.
5. **Sledljivost vsake spremembe** (kdo, kdaj, kaj, prej/potem) in razveljavitev tam, kjer je
   varna — ne za polja, ki jih naslednji zajem tako ali tako povozi.
6. **En pogled na artikel ne glede na izvor.** SAOP, NW XML, BT XML, datoteka ali ročni vnos —
   ena kartica, isti zavihki, ista logika validacije, viden pa mora biti **izvor vsakega polja**.
7. **Zaloga in dobavni roki v realnem času, brez pisanja nazaj.** Zaloga je pri izvoru;
   PIM je ne popravlja. To ni vrzel, ampak meja sistema.
8. **Odprtost za rast.** Nov proizvajalec, nova spletna stran, nov izvozni kanal = nova
   vrstica v registru, ne nova procedura.
9. **Manj klikov, manj ugibanja.** Sistem sam pove, kaj je narobe in kje; uporabnik ne sme
   iskati težave po petih zavihkih.
10. **Samopostrežna dokumentacija**, da »notri vse piše«.

---

## 4. Kaj bi moral znati, pa še ne zna (vrzeli NoviPIM)

### 4.1 Atributi nimajo registra in niso vezani na kategorijo

V NoviPIM atribut ni entiteta: obstaja samo kot **koda vrednosti** v `canon.ProductAttribute`
(in `pim.ProductAttribute`). Ni tabele z imenom, tipom, enoto, dovoljenimi vrednostmi in
prevodom, in ni preslikave kategorija → nabor atributov. Stran `/nastavitve/atributi` zato
pošteno prikaže samo »atributi, ki v katalogu dejansko imajo vsaj eno vrednost«.

Posledica je ista kot v starem sistemu: kartica artikla ne more pokazati **samo relevantnih**
atributov, uvozna/izvozna predloga po kategoriji pa ni mogoča.

*Predlog (še ne obstaja):* `canon.Attribute` (šifrant) + `canon.CategoryAttribute` (kateri
atribut pripada kateri kategoriji, obvezen/neobvezen, vrstni red).

### 4.2 Razveljavitev pokriva dve polji

`pim.UndoProductField` / `pim.UndoProductBatch` sta omejena na `WebPublish` in `IsActive`.
Vsako novo polje zahteva svojo preverjeno poslovno pot in test — razveljavitev **ni** generičen
SQL API in tudi ne sme postati.

### 4.3 Odhodna pot v SAOP nima proizvajalca sporočil

Trije konkretni manjki (izmerjeno 2026-08-22):

1. **nihče ne piše v `out.OutboxMessage`** — ne intranet, ne preslikava, ne razveljavitev;
2. `PIM.OutboxDispatcher` obdela **natanko eno** sporočilo in konča — ni zanke čez vrsto;
3. `ops.ScheduleProfile` nima vrstice za `OUTBOUND`.

Dokler to velja, je »poslano v SAOP« v vmesniku obljuba brez pokritja.

### 4.4 Potrditev iz SAOP (echo) v obratovanju ni preizkušena

Mehanizem obstaja (`ExpectedEchoHash`, `Superseded`, `Drift`), ni pa še šel skozenj noben
resničen zapis. Uspešen HTTP odgovor ni potrditev; potrditev je šele **naslednje branje iz
SAOP z isto vrednostjo**.

### 4.5 Intranet je skoraj v celoti bralen

Pravilo je, da gumba brez varne zapisovalne procedure ni. Zato manjkajo: urejanje preslikav,
prevodov in kategorij iz vmesnika, urejanje PIM-lastnih polj na kartici, množične spremembe s
predogledom, ročni zagon vira in izvoza, potrjevanje alarmov. Vsaka od teh potrebuje
proceduro z revizijsko sledjo, ne le gumb.

### 4.6 Izvoz strank je blokiran pri odločitvi človeka

`b2b.Customer` ima 11.558 vrstic, `out.ExportB2bCustomersCsv` pa jih ne izvozi, ker je
`pim.CustomerWebProfile` brez potrjenega tipa stranke. Vrsta (kupec / trgovec / oboje) in
PE/tranzit **nista podatek iz SAOP** — izmerjeno 2026-08-24: `CustomerType` ima vrednost `O`
pri 99,5 % strank, `CompanyLinkType` pri vseh `I`. To je delovni seznam za človeka, ne napaka.

### 4.7 Zgodovinskih (analitičnih) bralnih modelov ni

Trendi artiklov, zaloge, cen in naročilnic potrebujejo namenske zgodovinske modele.
Operativne tabele se ne uporabljajo kot lažni zgodovinski vir, zato analitika ostane
dokumentirana vrzel brez mrtve menijske poti.

### 4.8 Preostalo

- **Braytronove kategorije** čakajo odločitev o drevesu (`map.SourceCategory`, `canon.Category`).
- **Prevzem dobaviteljevih datotek s FTP** je zunanji klic (`AGENTS.md` §4.5).
- **Nočno opravilo je ugasnjeno**: SAOP je s tega računalnika dosegljiv le prek FortiClient.
- **Dostave do Magenta ni** — datoteka nastane, prenos je namerna meja.
- **Prenos artikla med organizacijami** ni prvorazredno dejanje na kartici.
- **Samodejni enqueue v ERP po `ERP_L1 VALID`** ni izveden; vse je ročno.

---

## 5. Kaj je bilo pokvarjeno — izmerjeno v NoviPIM

Ta razdelek je namenoma odkrit. Vsi primeri so iz tega repozitorija; primeri iz starega
sistema so ostali v izvirniku.

### 5.1 Zeleni dokaz, ki ni dokazoval ničesar

`dotnet test PIM_Solution\PIM.sln` je izvajal **1 projekt od 43** in vračal 0; ostalo so
konzolne aplikacije, ki jih samo prevede. V repozitoriju je bil obenem Node scaffold, čigar
`npm test` je preverjal `2+3=5` — in se je **vrnil** tudi po arhiviranju, ker ga je zahteval
`ci.yml`. Nauk: dokler avtomatika nekaj zahteva, bo to nekdo znova ustvaril; odstraniti je
treba razlog, ne datoteko. Edini merodajni ukaz je `scripts\run_tests.ps1`.

### 5.2 Tri preslikave, registrirane in nikoli poklicane

Migracija 082 je registrirala šifrante, konte zaloge in planiranje ter zanje ustvarila
procedure — poklical pa jih ni nihče. Vrstice v registru, tabele prazne. Po popravku:
`canon.Codebook` 0 → 708, `canon.ProductPlanning` 0 → 196.512,
`canon.ProductStockAccounting` 0 → 176.086. Test `PIM.F5.Integration` odslej pade, če
`TargetDomain` v registru nima svojega postopka.

### 5.3 Prazen izvoz ni bil kriv izvoz

2026-08-22 je izvožena datoteka imela vrednost v **15 od 213 stolpcev**. Videti je bilo kot
napaka izvoza; v resnici je bil prazen `canon`, ker se je dobaviteljev XML bral samo v
izrezku. Po polnem branju: `canon.ProductAttribute` 1.064 → 112.820, `pim.ProductCategory`
21 → 6.494, datoteka 152 od 213 stolpcev. **Najprej izmeri vzrok, potem popravi posledico.**

### 5.4 Mejnik, ki je prehitel preslikavo

`--only-ingest` je premaknil `map.Watermark`, čeprav ni ničesar preslikal; ob ponovnem zajemu
je dedup po hashu pomenil, da preslikava nima česa obdelati — 183 artiklov je ostalo za
mejnikom. Zdaj mejnik ob zajemu brez preslikave stoji, worker pa izpiše `BREZ PRESLIKAVE`.

### 5.5 Zaloga brez pogoja po podjetju

`stock.ApplyLandingRecord` je od migracije 018 iskal artikel **brez `OrganizationId`**
(popravljeno z 088). Dokler je zalogo imelo eno samo podjetje, se to ni poznalo — klasična
napaka, ki jo razkrije šele drugo podjetje.

### 5.6 Padec, skrit v skripti

`Nocni-zajem.ps1` je pod `$ErrorActionPreference = 'Stop'` umrl ob prvi vrstici, ki jo je
worker napisal na stderr: brez zapisa v dnevnik, s pobitim procesom in s 14 zagoni, ki so za
vedno ostali `Running`. Zaprti kot `Failed`; `Running` je zdaj 0.

### 5.7 ERP profili nosijo imena, ne pravil

Izmerjeno 2026-08-26 (`docs/ANALIZA_ERP_PRAVIL.md`): `ERP_L1_EU` in `ERP_L1_THIRD` zahtevata
**natanko iste štiri vrednosti** — trije profili, tri identične številke veljavnih izdelkov.
`ERP_L1_SLO` nima nobene zahteve, vezane na slovenski trg, in ne zahteva stopnje DDV, čeprav
jo zapuščinski `ERP_L1` zahteva. Profila, ki se ne razlikujeta v pravilu, sta en profil z
dvema imenoma.

### 5.8 »Migracija je uporabljena« ni prenosljiva trditev

Ista veja je na enem računalniku tekla na migraciji 043 in na drugem na 027; sedem
integracijskih projektov je padalo s `Class:20`. Preveri `dbo.SchemaMigration`, ne
dokumentacije.

---

## 6. Strateška vprašanja, ki presegajo aplikacijo

Podedovano iz analize starega sistema (v NoviPIM **ni ponovljeno in ne izmerjeno**):

- **Menjava ERP (Odoo).** Poslovna logika je v bazi, ne v aplikaciji, zato »zamenjaj le
  aplikacijo« ni izvedljivo. Priporočilo, ki drži ne glede na izid: **PIM nikoli ne postane
  modul znotraj ERP-ja.** Odprto vprašanje ostaja, kateri moduli obstoječega ERP-ja so sploh
  v uporabi.
- **Migracija baze na PostgreSQL** je bila ocenjena kot izvedljiva, a šele na koncu poti.

Novo, kar velja za NoviPIM:

- **Produkcije ni.** Živ SAOP klic, dostava na splet, IIS in Scheduled Tasks so po
  `AGENTS.md` §4.5 izven agentskega dosega; vse izmerjeno velja za razvojno bazo `PIM`.
  Razkorak razvoj → produkcija je zato treba načrtovati kot ločen korak z lastnimi dokazi.

---

## 7. Kam naprej (prioritete)

Vrstni red je usklajen z `docs/PRODUKTNI_MODEL_PIM.md` §7 in
`NAVIGACIJSKI_SISTEM_IN_FUNKCIJE_STRANI.txt` §6:

1. **Izdelki — bralna celota.** Seznam in kartica morata samo z branjem odgovoriti:
   *»Zakaj ta izdelek ni pripravljen za ERP ali za splet in od kod je prišel njegov podatek?«*
2. **Kakovost** — napaka povezana z izdelkom, poljem in pravilom, z jasno blokado.
3. **Urejanje PIM-lastnih polj** z zgodovino in razveljavitvijo.
4. **ERP izhod**: proizvajalec sporočil, zanka v dispatcherju, razpored `OUTBOUND`,
   odobritev in echo potrditev.
5. **Spletni izvozi**: predogled, zgodovina datotek, prenos CSV, razlogi za izpuščene vrstice.
6. **Stranke, popusti, cene in zaloga** — vključno z odločitvijo o tipu stranke,
   ki danes blokira izvoz strank.
7. **Nastavitve**: varno urejanje atributov, kategorij, prevodov in preslikav — pogoj za to je
   register atributov iz vrzeli 4.1.
8. **Sistem**: uporabniki, pravice, alarmi, obvestila, revizijska sled.
9. **Analitika**, šele ko obstajajo zgodovinski bralni modeli.

Popravek ERP profilov (5.7) ni na tem seznamu kot faza — je **poslovna odločitev**, ki mora
priti pred korakom 4, sicer se avtomatizira napačno pravilo.

---

## 8. Vodilo skozi ves nadaljnji razvoj

- **En vir resnice.** Pravilo se doda v register, ne v nov `IF` v proceduri.
- **Kakovost izhaja iz napak, ne iz ročnega označevanja.** Status se izračuna, ne kopira.
- **Profili so neodvisni.** Eden ne sme zahtevati polj drugega brez izrecnega pravila — in
  dva profila z istim naborom zahtev sta en profil.
- **`raw.Inbox` je prehod, ne skladišče.** Če stran tam obstane kot `Pending`, manjka
  preslikava — to je vrzel, ne stanje.
- **`OrganizationId` je povsod.** Brez izjeme, tudi kadar bi bilo »začasno« lažje brez njega.
- **PIM-lastno in SAOP-lastno polje nista ista stvar.** Prvo se zapiše, drugo se predlaga,
  odobri, pošlje in šele z echo potrdi.
- **Kar ni izmerjeno, ni narejeno.** Če česa ne moreš pokazati z izhodom ukaza, tega ne trdiš.
