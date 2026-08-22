# Analiza treh domenskih delov — A zajem, B izvoz, C odhodna pot

Datum meritve: **2026-08-22**. Merjeno proti živi bazi `PIM` na
`localhost\MSSQLSERVER3` (računalnik `DESKTOP-TONVQHJ`, migracija **058**) in
proti delovnemu drevesu veje `feature/baza-a3-mnozicna-obdelava`.

Razdelitev na A/B/C je iz [`PIM_Solution/docs/AGENTSKA_ORKESTRACIJA.md`](../PIM_Solution/docs/AGENTSKA_ORKESTRACIJA.md):
A = zajem in normalizacija, B = CSV/B2B izvozi, C = outbox in povratna SAOP sinhronizacija.

> **Zakaj ta dokument obstaja.** `STATUS.md` in `TASKBOARD.md` sta bila do te meritve
> zastarela za deset migracij: `049`–`058` so bile **uporabljene v bazi**, a jih tabla ni
> poznala. Trije zapisi na tabli so bili s tem dejansko napačni (glej §5).
>
> *Opomba k času:* meritev je nastala nad delovnim drevesom **pred** commitom `2beee25`
> (2026-08-22), s katerim so `049`–`058` prišle v git. Številke iz baze veljajo naprej —
> shema se od meritve ni spremenila.

---

## 0. Kaj sem pognal kot dokaz

| Ukaz | Izhod |
|---|---|
| `dotnet build PIM_Solution\PIM.sln` | **Build succeeded**, 0 napak, 3 opozorila MSB3026 (zaklenjena `.dll`, ker je tekel `PIM.F3.Integration`) |
| `dotnet run --project src\PIM.Migrator -- --verify` | `Preverjanje F0–F10 baze je uspešno.`, **izhod 0** |
| `dotnet run --project workers\PIM.B2bWorker -- --export-magento --organization-id 1 --output-dir <temp>` | `Magento CSV izvoz končan`, nastali `magento-products.csv` (1.729 vrstic, 433 KB), `magento-customers.csv`, `magento-export.complete` |
| ~20 poizvedb nad `PIM` | številke v nadaljevanju |

Testni paket `scripts\run_tests.ps1` v tej seji **ni** bil pognan — je PowerShell
skripta in ta meritev je potekala iz WSL. Zadnji znani rezultat je 44/0/0 iz 2026-08-21.

---

## 1. Povzetek

| Del | Mehanizem (koda + shema) | V obratovanju (podatek dejansko teče) | Ozko grlo |
|---|---|---|---|
| **A — ZAJEM** | ~90 % | ~55 % | 294 strani v `raw.Inbox` je `Pending` — zajeto, a nepreslikano |
| **B — IZVOZ** | ~85 % | **~10 %** | `pim.*` otroške tabele so skoraj prazne → **15 od 213 stolpcev** ima vrednost |
| **C — ODHODNA POT** | ~50 % | **0 %** | v `out.OutboxMessage` ni nikoli vstopilo nobeno sporočilo |

Skupna ugotovitev: **razkorak ni v kodi, ampak med kodo in podatkom.** Vsi trije deli
imajo več zgrajenega, kot ga je v obratovanju. Najdražje ni napisati manjkajoče logike,
ampak pognati tisto, kar že obstaja, čez ves katalog.

---

## 2. A — ZAJEM

### 2.1 Kar dela in je dokazano v živo

- **Vseh 16 SAOP končnih točk** se zajema, za štiri podjetja.
- `canon.Product` **196.516** artiklov: IQLighting 111.064, Ediito 39.130,
  Vidadria 28.897, DEMO 17.425.
- `canon.ProductPrice` 300.133, `canon.ProductText` 195.734.
- `map.ExtractedValue` **5.698.644** vrstic.
- Množična `map.ProcessRawInbox` (migracija 044) je odpravila ozko grlo preslikave
  (9,1 → 1.747 zapisov/s).
- **Pravilo mejnika iz 046 drži tudi v podatkih:** 13 entitet ima `Pending` strani in
  njihovi mejniki se niso premaknili. Podatek za tistim obdobjem torej ni izgubljen.

### 2.2 Kar je delno

**Preslikane so 3 od 16 SAOP entitet.** `map.FieldMapping` ima 321 vrstic, razporejenih:

| Vir | Entiteta | Preslikav |
|---|---|---|
| SAOP_IQLIGHTING / VIDADRIA / EDIITO / DEMO | `ItemGeneralData` | 23 vsak |
| " | `Prices` | 6 vsak |
| " | `Descriptions` | 2 vsak |
| NW_XML | `Attribute` / `Classification` / `Media` | 108 / 2 / 2 |
| BT_XML | `Attribute` | 76 |
| F5_FUTURE_CONFIG | `FutureProduct` | 9 |

**V `raw.Inbox` čaka 294 strani** (529 `Processed`, 10 `Quarantined`):

| Entiteta | Strani `Pending` |
|---|---|
| `GetItemsPlanningData` | 110 |
| `GetItemsStockAccountingData` | 87 |
| **`GetItemsTitlesLanguage`** | **45** |
| `GetItemsCustomProperties` | 10 |
| `GetItemCustomerDataV2` | 8 |
| `GetItemsStockData` | 5 |
| `Customers`, `Warehouses`, `GetLanguages`, `TechnologicalProcess`, `CustomerItemGroupDiscounts` | 4 vsak |
| `Currencies`, `PriceLists` | 3 vsak |
| NW_XML `Attribute` / `Classification` / `Media` (iz 4. 8.) | 1 vsak |

`GetItemsTitlesLanguage` je med njimi najbolj boleč — to so spletni nazivi, ki jih
potrebuje izvoz (§3.3).

**Migracija 057 je uporabljena, a brez učinka.** Doda 11 preslikav za
`canon.ProductCommercial` in razširi `map.ProcessRawInbox`, vendar ima
`canon.ProductCommercial` **1 vrstico** (testno). Migracija to sama pove: zajete strani so
že `Processed`, zato je potreben `--full` ali `--map-run <RunId>`. Posledica se vidi v
validaciji: `ERP_L1_EU`, `ERP_L1_THIRD` in `COMMERCIAL_L2` imajo **po 1 veljaven artikel
od 115.685**.

**Dobaviteljski XML (NW/BT) — mehanizem je cel, zagon ni bil.**

- Zgrajeno: `map.FieldTransform` **40** pretvorb, `map.ValueLookup` **6.316** prevodov
  (migracija 049), 108 preslikav Nowodvorski (054), 76 Braytron (055).
  `SqlMappingPipeline` kliče `map.ApplyValueTransforms` med izluščanjem in prenosom.
- Dejansko zajeto: BT_XML **ena stran** (228 izluščenih vrednosti), NW_XML nekaj strani.
- Rezultat: `canon.ProductAttribute` **1.064 vrstic / 75 različnih kod / 27 izdelkov**.
- `map.UnmappedValue` ima **31.738** vrstic z razlogom
  „Izdelek za konfigurirani identifikator ne obstaja." (iz 2026-08-04) — dobaviteljev XML
  normalno vsebuje več, kot ga vodimo mi; to je pričakovano, ne napaka.
- `map.MissingTranslation` ima 29 vrstic — delovni seznam za prevod, ne dnevnik napak.

### 2.3 Napake, vidne v `ops.PipelineRun`

- Zadnji `SAOP_PRODUCTS` zagon za IQLighting (2026-08-21 11:09) je **`Failed`**
  (14.563 prebranih, 3 padli).
- Zadnji `GENERIC_XML` zagon (2026-08-04) je **`Failed`**.
- Dva zagona `F5_INTEGRATION` sta obtičala v **`Running`** brez `EndedUtc` — ostanek
  integracijskih testov, ne pravo delo.
- `ops.DeadLetterQueue` ima 16 vrstic.

### 2.4 Delo, ki po tabli še ni začeto

`PIM.StockFileWorker` nima pravega `Program.cs` (pisalna logika obstaja, kliče jo samo
test). Za `PIM.SaopStockWorker`, `PIM.FoundationWorker` in ostanek `PIM.NwXmlWorker` ni
odločitve.

---

## 3. B — IZVOZ

### 3.1 Kar dela

Izvoz je resnično gnan iz registra (migracija 045), ne iz `switch` stavka v kodi:

- `out.ExportProfile` **7 profilov**: `MAGENTO_PRODUCTS`, `MAGENTO_CUSTOMERS`,
  `CUSTOMERS_B2B`, `PRODUCTS_B2B`, `SHIPPING_B2B`, `WEB_B2C_PRODUCTS`, `ERP_L1`.
- `out.ExportColumn` **275 vrstic**, od tega `MAGENTO_PRODUCTS` 215 (**213 aktivnih**,
  2 izklopljeni z migracijama 052/053 — `Grlo SLO` in podvojena `Frekvenca`).
- Atomarni par datotek je resničen: `.tmp` → zamenjava pod ključavnico na izhodni mapi →
  `magento-export.complete`; ob padcu se prejšnji par vrne.
- **Pognal sem ga v živo** (organizacija 1): 1.729 vrstic, oba CSV-ja in oznaka nastanejo.

### 3.2 Blokada „162 praznih atributnih stolpcev" je večinoma odpravljena

Tabla jo je vodila kot `BLOKIRANO` z vprašanjem za človeka. Migraciji **054** (Nowodvorski)
in **055** (Braytron) sta odgovor že zapisali kot vrstice registra:

- atributnih stolpcev v aktivnem profilu: **160**
- od tega jih ima vir v `map.FieldMapping`: **156**
- brez vira ostane: **4**

Ločeno od tega je **33 stolpcev, ki sploh nimajo kanonične kode** — zanje ni odločeno,
od kod naj pridejo: `Dobavitelj`, `ABC klasifikacija`, `Merska enota`, enote teže/volumna/
paketa, `Kategorije svetila ANG/SLO`, `Popust`, `Valuta`, `Omejitev pri naročanju`,
`Posebni popust za stranko`, dokumenti (3), zaloge `VID *` (7), dobaviteljeva zaloga (3),
`Skladišče`.

### 3.3 Pravo ozko grlo — izmerjeno na resnični datoteki

V izvoženem `magento-products.csv` (organizacija 1, 1.728 izdelkov) ima vrednost
**15 od 213 stolpcev**, in večina samo pri enem izdelku:

| Stolpec | Izpolnjen pri |
|---|---|
| Šifra artikla | 1728 |
| EAN | 1728 |
| Proizvajalec | 1728 |
| DDV | 1728 |
| Cena B2B | 1109 |
| Cena B2C | 3 |
| Spletne strani, Naziv artikla EN, **Naziv artikla**, Oznaka tarifa, Država proizvoda, Bruto teža, Neto teža, PAK2, Glavna slika | **1** |
| ostalih 198 stolpcev | 0 |

Vzrok je v `pim.*`. Migracija **058** je `val.Promote` razširila na otroške tabele in to
je delovalo — a vanje pride le tisto, kar v `canon` je:

| Tabela | Vrstic |
|---|---|
| `pim.Product` | 44.510 |
| `pim.ProductText` | 44.511 |
| `pim.ProductPrice` | 85.777 |
| `pim.ProductAttribute` | **901** (27 izdelkov) |
| `pim.ProductCategory` | **21** |
| `pim.ProductMedia` | **21** |
| `pim.ProductCommercial` | **1** |

Torej: izvoz **ni** pokvarjen. Prazen je zato, ker sta A-ja dva koraka (§2.2) neopravljena.

### 3.4 Dve odprti odločitvi, ki nista tehnični

1. **Objava teče samo za organizaciji 1 in 2** — `pim.Product` ima 42.782 vrstic za org 2
   in 1.728 za org 1. **Vidadria (3) in Ediito (4) imata 0 objavljenih artiklov.**
2. **Vstopnica za objavo je še stari profil `ERP_L1`.** Stanje validacije:

   | Profil | VALID | INVALID |
   |---|---|---|
   | `ERP_L1` (vstopnica za objavo) | 44.510 | 71.175 |
   | `ERP_L1_SLO` | **100.809** | 14.876 |
   | `SHARED_CORE` | 55.963 | 59.722 |
   | `ERP_L1_EU`, `ERP_L1_THIRD`, `COMMERCIAL_L2`, `WEB_B2C`, `WEB_svetila_si`, `WEB_videlektro` | 1 | 115.684 |

   Zamenjava `ERP_L1` → `ERP_L1_SLO` bi objavljene artikle povečala za faktor 2,3.
   Migracija 058 te odločitve nalašč ni sprejela.

### 3.5 Ostalo

- Dostave na Magento/FTP/HTTP ni — to je namerna meja agenta B.
- `PIM.B2bWorker\MagentoExportRunner.cs` je še vedno mrtva koda (vzporedna izvedba istega
  izvoza; priklopljen je `MagentoExportCommand`). Brisanje je na zaprtem seznamu `AGENTS.md` §4.1.
- Popravki glav predloge (050–053) in `MagentoCsvContract.cs` so **necommitani**.

---

## 4. C — ODHODNA POT / povratna SAOP sinhronizacija

### 4.1 Kar obstaja

Shema in koda sta zgrajeni in pokriti s testi: `out.OutboxMessage` / `out.OutboxAttempt`,
najem sporočila z zakupom, echo preverjanje po pričakovanem hashu (024), `ErrorClass` in
stanje `Superseded` (046), `SaopItemAssignmentResolver`, `OwnershipPolicy`,
`OutboundPayloadBuilder`, `EchoVerifier`. Testnih projektov je šest: `PIM.F8.ContractTests`,
`BehaviorTests`, `DispatcherTests`, `EchoTests`, `HardeningTests`, `Integration` —
izključno proti loopback `127.0.0.1`.

### 4.2 Kar v resnici teče: nič

| Tabela | Vrstic |
|---|---|
| `out.OutboxMessage` | **0** |
| `out.OutboxAttempt` | **0** |
| `out.SaopItemAssignment` | **0** |
| `out.OwnershipPolicy` | **0** |

Skozi to pot ni šlo nikoli nobeno sporočilo. Trije konkretni manjki:

1. **Nihče ne piše v outbox.** Ni proizvajalca sporočil — ne iz intraneta, ne iz
   preslikave, ne iz razveljavitve. Tabela je prazna, ker vanjo nihče ne vstavlja.
2. **Dispatcher obdela natanko eno sporočilo in konča.**
   `workers\PIM.OutboxDispatcher\Program.cs` naredi en `out.ClaimMessage`, en HTTP klic,
   en `out.CompleteAttempt` in se zaključi. Ni zanke čez čakalno vrsto, ni ponavljanja
   znotraj procesa.
3. **Ni razporeda.** `ops.ScheduleProfile` ima 7 vrstic — `SAOP_PRODUCTS` (org 1–4),
   `GENERIC_XML`, `ALERT_DISPATCH`, `WATCHDOG`. Za `OUTBOUND` vrstice **ni**.

Poleg tega ostaja znana meja: pot zna poslati spremembo polja, ne zna ustvariti artikla v
SAOP, zato `out.ResolveSaopItemAssignment` v živo ni bil nikoli klican in stanje `Error`
ostaja mrtva pot.

**Zaključek za C: koda je približno na pol, obratovanje je na ničli.** Dokler ni
proizvajalca sporočil, je vse ostalo neuporabljeno.

---

## 5. Kje sta bila `STATUS.md` in `TASKBOARD.md` napačna

| Trditev v dokumentaciji (do 2026-08-21) | Dejansko stanje 2026-08-22 |
|---|---|
| „162 atributnih stolpcev je praznih, manjka odločitev, katera lastnost pripada kateremu stolpcu" — vodeno kot `BLOKIRANO` | Odgovor je zapisan v migracijah 054/055. **156 od 160** atributnih stolpcev ima vir. Ostane 4 + 33 stolpcev brez kanonične kode. |
| „`canon.ProductCommercial` je prazna, manjka preslikava" | Preslikava obstaja (057, uporabljena). Manjka **ponovna preslikava zajetih strani**, ne preslikava sama. |
| „`val.Promote` polni samo `pim.Product`, otroške tabele so vse na 0" | 058 to odpravi. `pim.ProductText` 44.511, `pim.ProductPrice` 85.777. Ostale tri so nizke, ker je nizek `canon`, ne ker `Promote` ne dela. |
| „Preslikane so 3 od 16 končnih točk" | Za SAOP še vedno drži. Dodano je dvoje neomenjenega: pretvorbe in slovar vrednosti (049) ter drugi dobavitelj Braytron (055). |

Manjša bradavica: `dbo.SchemaMigration` vsebuje zapisa
`047_ValueDictionaryAndTransforms.sql` in `048_ValueDictionaryAndTransforms.sql`, ki kot
datoteki ne obstajata (preimenovani v `049`). `--verify` kljub temu vrne 0, ker preverja
shemo in ne imen; vseeno je zapis zavajajoč.

Vse od migracije `049` naprej, skupaj s popravki `MagentoCsvContract.cs` in testov
F2/F5/F7, je bilo ob meritvi necommitano; v git je prišlo s commitom `2beee25` istega dne.

---

## 6. Priporočen vrstni red naslednjih korakov

1. **Ponovna preslikava obstoječih zagonov za trgovinske podatke** (`--map-run <RunId>`
   ali `--full`). Migracija 057 je že v bazi, podatek je že v `raw.Inbox`. Odklene stolpce
   10–23 izvoza in tri validacijske profile, ki so danes pri 1 veljavnem artiklu.
2. **Preslikava `GetItemsTitlesLanguage`** (45 strani čaka). To je „Naziv artikla" —
   stolpec, ki ga ima danes izpolnjenega **1 izdelek od 1.728**. Brez njega spletni izvoz
   ni uporaben, ne glede na to, koliko atributov dodamo.
3. **Zajem NW in BT XML v polnem obsegu.** 156 stolpcev ima vir, podatek ima 27 izdelkov —
   to je največji razkorak med „narejeno" in „teče" v celotnem sistemu.
4. **Odločitev o profilu za objavo** (`ERP_L1` vs `ERP_L1_SLO`) in zagon `val.Promote`
   še za organizaciji 3 in 4.
5. **Šele nato C.** Prvi smiselni korak tam ni dodelava dispatcherja, ampak
   **proizvajalec sporočil**: kdo in ob čem vstavi vrstico v `out.OutboxMessage`. Za tem
   zanka v dispatcherju in vrstica `OUTBOUND` v `ops.ScheduleProfile`.
6. **Počistiti rep:** dva zagona `F5_INTEGRATION`, obtičala v `Running` brez `EndedUtc`,
   in odločitev o mrtvi kodi `MagentoExportRunner.cs`.
