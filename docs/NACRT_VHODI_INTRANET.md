# Vhodi (zajem) v intranetu — pregled stanja, uporabniški načrt in prompt za Codex

Datum: 2026-08-24. Avtor: Claude Code. Ozemlje: analiza (brez sprememb kode).

Vir vseh trditev je koda in migracije v tem repozitoriju, ne načrti:
`src/PIM.Intranet/Components/Pages/Ingest*.razor`, `PipelineRuns.razor`, `RawQuarantine.razor`,
`Missing*.razor`, `FieldMappings.razor`, `src/PIM.Intranet/Services/PipelineReadService.cs`,
`workers/*`, `sql/migrations/001–092`.

Referenčni dokumenti: [`PRODUKTNI_MODEL_PIM.md`](PRODUKTNI_MODEL_PIM.md) (faza VHODI),
[`INTRANET.md`](INTRANET.md) (dejansko stanje aplikacije), [`ZAJEM-SAOP.md`](ZAJEM-SAOP.md)
(operativa zajema), [`NACRT_INTRANET_PRENOVA.md`](NACRT_INTRANET_PRENOVA.md) §5–§8 (faza I5).

---

## 1. Kaj je v tem sistemu sploh »vhod«

Vhodnih poti je pet in **ne končajo vse v isti tabeli**. To je izhodišče celotnega načrta.

| # | Pot | Kdo jo izvede | Mesto prevzema | Zapiše v | Sled teka | Vidno v intranetu danes |
|---|---|---|---|---|---|---|
| 1 | SAOP iCenter API, 16 končnih točk | `PIM.KatalogWorker` | HTTPS `/iCenterAPI/` | `raw.Inbox` → `map.ExtractedValue` → `canon.*` | `ops.PipelineRun` + `ops.PipelineStepLog` | **da** (`/zajem`, `/teki-obdelave`) |
| 2 | Dobaviteljev XML izdelkov (NW ročno v mapo, BT prek HTTPS) | `PIM.XmlFileWorker` | mapa / HTTP(S) | `raw.Inbox` → `canon.*` | `ops.PipelineRun` | **da**, a brez oznake, kateri vir je datotečni |
| 3 | Zaloga dobaviteljev (NW CSV prek FTP, BT XML prek HTTP) | `PIM.StockFileWorker` | FTP / HTTP | `stock.LandingRecord` → `stock.Snapshot`/`Position`, zavrnjeno v `stock.UnmatchedPosition` | `stock.SyncRun` | **ne** |
| 4 | Zaloga iz SAOP (registrirani pogled) | `PIM.SaopStockWorker` | HTTPS | isto kot 3 | `stock.SyncRun` | **ne** |
| 5 | Ročni uvoz iz Excela (spletni nazivi, delovni listi) | `PIM.XmlFileWorker/WorkbookReader` | zvezek v mapi | `canon.*` | delno | **ne** |

Dokaz za 3 in 4: nobena datoteka v `workers/PIM.StockFileWorker` in `workers/PIM.SaopStockWorker`
ne omenja `raw.Inbox` ali `ops.PipelineRun`. Zato **stran `/zajem` in stran `/teki-obdelave`
zalog ne prikažeta — niti kot manjkajoče**. Uporabnik, ki gleda vhode, vidi dve poti od štirih
in ne izve, da drugi dve obstajata.

---

## 2. Kaj intranet o vhodih pokaže danes

| Pot | Datoteka | Kaj kaže | Kaj bere | Vloge |
|---|---|---|---|---|
| `/zajem` | `Ingest.razor` | 4 KPI (čaka na preslikavo, preslikano, karantena, nerazvrščene vrednosti) + 4 razdelilne kartice | `PipelineReadService.GetSummaryAsync` | vsi prijavljeni |
| `/zajem/viri` | `IngestSources.razor` | vir, stanje, pravica ustvarjanja, št. entitet/polj, čaka, skupaj strani, zadnji prejem, mejnik | `map.SourceConnector` + podpoizvedbe | vsi |
| `/zajem/teki` = `/teki-obdelave` | `PipelineRuns.razor` | kartice zadnjega teka po virih + tabela zgodovine | `intranet.GetPipelineRuns` | vsi |
| `/zajem/cakalna-vrsta` | `IngestQueue.razor` | povzetek po viru/entiteti/stanju + strani s strežniško paginacijo (50) | `raw.Inbox` | vsi |
| `/zajem/neujemanja` | `IngestUnmapped.razor` | TOP 300 vrednosti po pogostosti | `map.UnmappedValue` ⋈ `ExtractedValue` ⋈ `raw.Inbox` | vsi |
| `/karantena`, `/kakovost/karantena` | `RawQuarantine.razor` | izločene strani, odjemalsko iskanje, brez paginacije | `intranet.GetRawQuarantine` | vsi |
| `/kakovost/prevodi` | `MissingTranslations.razor` | TOP 300 manjkajočih prevodov, filter jezika | `map.MissingTranslation` | vsi |
| `/kakovost/kategorije` | `MissingCategories.razor` | TOP 300 nepreslikanih poti | `map.MissingCategoryMap` | vsi |
| `/pravila/preslikave` | `FieldMappings.razor` | element vira → ciljno polje, obveznost, stanje | `map.FieldMapping` | ADMIN, CATALOG_EDITOR, COMMERCIAL |
| `/pravila/slovar` | `ValueDictionary.razor` | `map.ValueLookup` | isti trije |
| `/system/integracije` | `SystemIntegrations.razor` | zdravje integracij + alarmi, s **Potrdi/Razreši** | `intranet.GetSystemIntegrations` | samo ADMIN |

Vse našteto razen `/system/integracije` je **izključno bralno**. Nobenega dejanja nad vhodom ni.

---

## 3. Ugotovitve — kaj konkretno manjka

Razvrščeno po tem, koliko boli pri vsakodnevnem delu.

1. **Vidiš problem, ne moreš ukrepati.** Stran v `Pending`, ki je obtičala, se po
   [`ZAJEM-SAOP.md`](ZAJEM-SAOP.md) §5 vrne v vrsto z ročnim `UPDATE raw.Inbox` v SSMS. To je
   dokumentirano kot normalen postopek. Uporabnik brez SSMS in brez pravic je slep.
2. **Zaloge niso del vhodov.** `stock.SyncRun`, `stock.Snapshot`, `stock.UnmatchedPosition`
   nimajo nobene strani. Ravno zaloga je po odločitvi uporabnika (`TVOJE_NALOGE.md` §8) cilj
   »na 5 minut« — najhitrejši vhod je najmanj viden.
3. **Vir ne pove, od kod prihaja.** `map.SourceConnector` ima samo `ConnectorType` (`SAOP`,
   `FILE_XML`). Ni mesta prevzema (mapa / HTTP / FTP), ni urnika, ni zadnjega uspeha in
   neuspeha. `ops.ScheduleProfile` in `ops.IntegrationHealth` obstajata, a ju vidi le ADMIN
   na povsem drugi strani.
4. **»Zajeto brez preslikave« nima imena v UI.** Worker to stanje izrecno izpiše
   (`BREZ PRESLIKAVE — mejnik NI premaknjen`), ker za entiteto ni aktivne `map.EntityMapping`
   **in** vsaj ene aktivne `map.FieldMapping`. V vmesniku vidiš samo številko »Čaka«, ne pa
   razloga. To je razlika med »še ni obdelano« in »nikoli ne bo, dokler nekdo ne doda preslikave«.
5. **Teki brez korakov.** `ops.PipelineStepLog` (StepCode, Attempt, RowsIn, RowsMerged,
   DurationMs, Status) se ne prikaže nikjer. Ko tek pade, je edini odgovor `RowsFailed`.
6. **Teki brez strežniških filtrov.** `PipelineRuns.razor` naloži nabor in ga filtrira ter
   pagina na odjemalcu po 10. Ni filtra po datumu, organizaciji, cevovodu; ni povezave
   `RunId` → strani tega teka.
7. **Neujemanja so slepa ulica.** Vidiš vrednost, razlog in pogostost, ne moreš pa je niti
   dodati v slovar (`map.ValueLookup`) niti videti, na katerih straneh se pojavlja. Isto velja
   za manjkajoče prevode, čeprav je odločitev uporabnika (`TVOJE_NALOGE.md` §6) izrecno
   »uporabnik mora imeti možnost popravljanja v vmesniku«.
8. **Register dobaviteljevih kategorij iz migracije 091 ni prikazan.** `map.SourceCategory` in
   pogled `map.SourceCategoryToMap` sta narejena prav zato, da se kategorija dobavitelja
   pokaže tudi brez preslikave. Stran `/kakovost/kategorije` še vedno bere staro
   `map.MissingCategoryMap` in ne pozna ne števila izdelkov ne berljive poti po ravneh.
9. **Karantena je najšibkejša tabela vhodov.** Brez paginacije, brez združevanja po razlogu,
   brez predogleda `PayloadXml`, brez ponovnega poskusa. Danes je v njej 10 strani iz julija —
   ravno prav, da nihče ne opazi enajste.
10. **Ni sledi od zapisa do izdelka.** `raw.Inbox.PayloadXml` in `map.ExtractedValue` se ne
    prikažeta. Vprašanje »zakaj ima ta artikel to vrednost« se v vmesniku ne da odgovoriti.
11. **Vse je vezano na eno organizacijo iz piškotka.** Nočni zajem teče za štiri podjetja,
    pregled pa je enopodjetniški. Ni pogleda »vsa podjetja«, čeprav se okvara običajno pokaže
    ravno kot »eno podjetje molči«.
12. **Mejnik je samo `MAX` po viru.** `map.Watermark` je po `(SourceConnectorId, EntityType)`;
    stran seštevek zravna v en datum in skrije prav tisto entiteto, ki zaostaja.
13. **`ops.DeadLetterQueue` in `ops.ErrorLog` sta nevidna** na vhodni poti.
14. **Ročnega uvoza ni.** Množično urejanje prek Excela obstaja samo na odhodni poti
    (`/izvozi/mnozicno`). Vhodni Excel (spletni nazivi, delovni listi kategorij) gre mimo
    vmesnika.

---

## 4. Kaj hoče uporabnik — po vlogah

Vloge so dejanske vrstice v `sec.Role`: `ADMIN`, `CATALOG_EDITOR`, `COMMERCIAL`, `VIEWER`.
Nove vloge (»operater integracij«) si ne izmišljujemo — `PRODUKTNI_MODEL_PIM.md` §4 to prepoveduje.

### 4.1 ADMIN — skrbnik integracij

Jutranje vprašanje: **»Je nocoj vse prišlo in ali kaj molči?«**

Mora videti:
- vseh pet vhodnih poti za **vsa podjetja hkrati**, v eni tabeli: zadnji uspeh, zadnji neuspeh,
  stanje (`Healthy`/`Stale`/`Failed`/`Running`/`NeverRun`), naslednji načrtovani zagon;
- kje se je nocojšnji tek ustavil — po korakih, ne po skupnem številu;
- katere strani so obtičale in koliko časa (starost najstarejše `Pending` strani je merilo);
- odprte alarme, ki izvirajo iz vhodov, in mrtva pisma.

Mora znati narediti:
- vrniti obtičale strani v vrsto (nadomestek za `UPDATE raw.Inbox` iz SSMS);
- ponovno pognati preslikavo za `RunId` brez novega klica na SAOP (`map.ProcessRawInbox`);
- vklopiti/izklopiti urnik vira in premakniti naslednji zagon (`ops.ScheduleProfile`);
- potrditi in razrešiti alarm (to že obstaja, a na napačni strani);
- videti zadnjo napako v očiščeni obliki (`LastErrorRedacted`), nikoli poverilnic.

Ne sme ga motiti: vsebina posameznega artikla.

### 4.2 CATALOG_EDITOR — urednik kataloga

Vprašanje: **»Kaj je prišlo in česa PIM ni razumel — in kaj lahko danes popravim?«**

Mora videti:
- delovni seznam nerazvrščenih vrednosti, urejen po pogostosti, z razlogom in ciljnim poljem;
- manjkajoče prevode po domeni in jeziku;
- dobaviteljeve kategorije, ki nimajo naše (register 091), s številom izdelkov — ker 103
  Braytronovih družin ni enako pomembnih;
- katere entitete se zajemajo **brez preslikave** (torej kje bi njegovo delo sploh kaj odklenilo);
- primer surovega zapisa, ko se ne ujema, kar vidi, s tem, kar pričakuje.

Mora znati narediti (to je bistvo — brez tega je stran samo poročilo):
- vrednost iz seznama neujemanj **dodati v slovar** (`map.ValueLookup`: domena, izvorna
  vrednost, jezik, ciljna vrednost) in videti, koliko zapisov to odklene;
- **preslikati dobaviteljevo kategorijo** v našo (`map.CategoryPathMap`), z iskalnikom po
  našem drevesu in prikazom, koliko izdelkov s tem dobi uvrstitev;
- **popraviti ali potrditi prevod** (odločitev iz `TVOJE_NALOGE.md` §6: AI predlaga, človek
  popravi);
- naročiti ponovno preslikavo za vir, ko je preslikavo dopolnil.

Ne sme videti: gumbov za urnike, poverilnic, sistemskih napak.

### 4.3 COMMERCIAL — komerciala

Vprašanje: **»So cene, ceniki, zaloga in stranke svežih toliko, da lahko obljubim rok?«**

Mora videti:
- svežino po **entiteti**, ne po viru: `GetPrices`, `PriceLists`, `Customers`,
  `CustomerItemGroupDiscounts`, zaloga — zadnji uspešen prevzem in starost;
- zavrnjene zaloge (`stock.UnmatchedPosition`) z razlogom — to so artikli, ki jih splet
  prikazuje napačno;
- ali je čakajoča vrsta takšna, da bo današnji izvoz nepopoln.

Mora znati narediti: samo naročiti ponoven prevzem zaloge in prijaviti sporno vrstico naprej;
urejanje preslikav ni njegovo delo.

### 4.4 VIEWER — pregledovalec

Bere vse zgoraj, brez enega samega gumba. Pomembno je, da so mu vidne **iste številke**, da se
sklicevanja med ljudmi ujemajo.

### 4.5 Lastnik sistema — pogled 60 sekund

Ena vrstica na vhodno pot za štiri podjetja: **prišlo / obdelano / čaka / zavrnjeno / zadnjič**.
Rdeče samo takrat, ko je zares problem. Vse ostalo je klik globlje.

---

## 5. Predlagana zgradba modula VHODI

Ena skupina v meniju (`PimNavigation`, sekcija »Vhodni podatki«), ena razdelilna stran, devet
delovnih strani. Stare poti ostanejo kot aliasi (kot `/teki-obdelave` danes).

| Pot | Stran | Vloge |
|---|---|---|
| `/zajem` | Nadzor vhodov — vseh pet poti, vsa podjetja, ukrepi na dosegu | vsi (dejanja po vlogi) |
| `/zajem/viri` | Register virov + zdravje + urnik | vsi; urnik ADMIN |
| `/zajem/viri/{sourceCode}` | Vir podrobno: entitete, mejniki po entiteti, preslikave, zadnji teki | vsi |
| `/zajem/teki` | Zgodovina tekov, strežniško filtrirana in paginirana | vsi |
| `/zajem/teki/{runId}` | Koraki teka (`ops.PipelineStepLog`), strani teka, napake | vsi |
| `/zajem/cakalna-vrsta` | `raw.Inbox` po viru/entiteti/stanju + posamezne strani | vsi; »vrni v vrsto« ADMIN |
| `/zajem/stran/{inboxId}` | Ena stran: glava, razlog, predogled `PayloadXml`, izluščene vrednosti | vsi; predogled ADMIN+CATALOG_EDITOR |
| `/zajem/karantena` | Izločene strani, združene po razlogu, s ponovnim poskusom | vsi; dejanje ADMIN |
| `/zajem/neujemanja` | Nerazvrščene vrednosti + **dodaj v slovar** | vsi; dejanje ADMIN, CATALOG_EDITOR |
| `/zajem/kategorije` | Dobaviteljeve kategorije (register 091) + **preslikaj v naše drevo** | isti |
| `/zajem/prevodi` | Manjkajoči prevodi + **vpiši prevod** | isti |
| `/zajem/zaloge` | Vhod zaloge: `stock.SyncRun`, posnetki, `UnmatchedPosition` | vsi |

Aliasi, ki ostanejo: `/teki-obdelave`, `/karantena`, `/kakovost/karantena`, `/kakovost/prevodi`,
`/kakovost/kategorije`.

Pravilo, ki ga ta zgradba uveljavlja: **dejanje se zgodi tam, kjer je predmet.** Prevod se vpiše
na seznamu manjkajočih prevodov, ne v ločenem urejevalniku slovarja.

---

## 6. Specifikacija strani

Skupno za vse: `PimPage` z naslovom in podnaslovom, `PimState` (nalaganje / napaka / prazno),
`PimTable` s `caption` in `scope`, `PimPager` za strežniško paginacijo, `PimChip` za statuse,
slovenska besedila, base-relativne povezave, brez Bootstrap razredov, brez izmišljenih vrednosti.

### 6.1 `/zajem` — nadzor vhodov

**Namen:** v 60 sekundah povedati, ali je nocoj vse prišlo.

**Preklop obsega:** stikalo »Aktivno podjetje / Vsa podjetja«. Privzeto aktivno podjetje iz
konteksta; »vsa podjetja« doda stolpec Podjetje.

**KPI vrstica (6 kartic, vse iz baze):**
1. Vhodne poti v redu — `n/m` (`ops.IntegrationHealth.Status = Healthy`)
2. Čaka na preslikavo — strani `raw.Inbox.Status = Pending` + starost najstarejše
3. V karanteni — `raw.Inbox.Status = Quarantined`
4. Nerazvrščene vrednosti — `map.UnmappedValue`
5. Delovni seznam preslikav — vsota manjkajočih prevodov + dobaviteljevih kategorij brez cilja
6. Zaloga — zadnji uspešen `stock.SyncRun` in število `stock.UnmatchedPosition`

**Tabela »Vhodne poti«** — ena vrstica na (podjetje, vir):

| Stolpec | Vir |
|---|---|
| Podjetje | `dbo.OrganizationConfig.Name` |
| Vir / cevovod | `map.SourceConnector.SourceCode`, `ops.IntegrationHealth.Pipeline` |
| Vrsta prevzema | `ConnectorType` + nov `IntakeKind` (glej §7) |
| Stanje | `ops.IntegrationHealth.Status` → čip: Healthy=zeleno, Running=nevtralno, Stale=oranžno, Failed=rdeče, NeverRun=sivo |
| Zadnji uspeh / neuspeh | `LastSuccessfulRunUtc` / `LastFailedRunUtc` (relativno: »pred 7 h«) |
| Naslednji zagon | `ops.ScheduleProfile.NextScheduledUtc`, `IsEnabled` |
| Prišlo (24 h) | `SUM(RowsRead)` iz `ops.PipelineRun` |
| Čaka | `raw.Inbox` Pending za ta vir → povezava |
| Zavrnjeno | `raw.Inbox` Quarantined + `map.UnmappedValue` |
| Zadnja napaka | `LastErrorRedacted`, skrajšano, celotno v naslovu (title) |

**Panel »Zajeto brez preslikave«:** entitete, kjer je `raw.Inbox` Pending, a ni aktivne
`map.EntityMapping` + `map.FieldMapping`. Besedilo: »Zajeto je, preslikave ni — mejnik ostaja,
zato se bo isto obdobje zajelo znova.« Povezava na `/pravila/preslikave`.

**Panel »Odprti alarmi vhodov«:** `ops.Alert` za vhodne cevovode, s Potrdi/Razreši za ADMIN.

**Dejanja (samo ADMIN):** »Preslikaj čakajoče« (na vrstico), »Vklopi/izklopi urnik«,
»Zaženi ob naslednjem ciklu«. Vsako dejanje je POST z antiforgery in potrditvijo, nikoli GET.

### 6.2 `/zajem/viri`

Register + zdravje v eni tabeli. Filtri: podjetje, vrsta prevzema, stanje, samo aktivni.
Stolpci: vir, vrsta prevzema, mesto prevzema (mapa/URL/FTP gostitelj — **brez poverilnic**),
pravica ustvarjanja artiklov, entitet, polj, strani skupaj, čaka, zadnji prejem, mejnik,
urnik (interval, naslednji zagon, vklopljen).
Dejanja: ADMIN vklop/izklop urnika in interval; ostalo bralno.

### 6.3 `/zajem/viri/{sourceCode}`

Zavihki: **Entitete** (entiteta, aktivna preslikava da/ne, št. polj, obvezna polja, mejnik za to
entiteto, strani po stanju, zadnji prejem), **Teki** (zadnjih 20), **Preslikave** (povezava na
`/pravila/preslikave` z že nastavljenim filtrom), **Napake** (`ops.ErrorLog` + `DeadLetterQueue`).
Ključni podatek te strani je stolpec **Mejnik po entiteti** — dokler ga ni, se ne da ugotoviti,
katera entiteta zaostaja.

### 6.4 `/zajem/teki` in `/zajem/teki/{runId}`

Seznam: strežniška paginacija (50), strežniški filtri — podjetje, cevovod, vir, status,
obdobje (danes / 7 dni / 30 dni / po meri), iskanje. Stolpci: začetek, trajanje, cevovod, vir,
prebrano, uspešno, zavrnjeno, status, konec. Vrstica je povezava na tek.

Podrobnost teka: glava (RunId, korelacija, podjetje, vir, trajanje), tabela korakov iz
`ops.PipelineStepLog` (korak, poskus, vrstic v, združenih, trajanje, status), tabela strani
`raw.Inbox` tega teka, napake tega teka iz `ops.ErrorLog`.
Dejanje ADMIN: »Preslikaj ta tek znova« → `map.ProcessRawInbox` za `RunId`.

### 6.5 `/zajem/cakalna-vrsta` in `/zajem/stran/{inboxId}`

Ohrani obstoječi vzorec (povzetek po skupinah + strani), doda:
- filtre: podjetje, vir, entiteta, stanje, obdobje, starost (»starejše od 24 h«);
- stolpec starosti in `RunId` s povezavo na tek;
- izbiro vrstic s potrditvenim poljem in množično dejanje **»Vrni v vrsto«** (ADMIN);
- povezavo na stran `/zajem/stran/{inboxId}`.

Podrobnost strani: glava (vir, entiteta, stran, stanje, prejeto, obdelano, razlog, hash),
predogled `PayloadXml` — **omejen na prvih ~20 000 znakov, v `<pre>` z vodoravnim drsnikom**,
in tabela izluščenih vrednosti (`map.ExtractedValue` + `map.UnmappedValue` z razlogom).
To je edina stran, ki odgovori na »zakaj ima ta artikel to vrednost«.

### 6.6 `/zajem/karantena`

Zgoraj združeno po razlogu (razlog, št. strani, najstarejša, najnovejša, viri) — ker je 10 strani
z dvema razlogoma, ne deset različnih problemov. Spodaj strani s strežniško paginacijo in filtri
(vir, entiteta, razlog, obdobje). Dejanje ADMIN: »Poskusi znova« (posamično ali množično).

### 6.7 `/zajem/neujemanja`

Filtri: podjetje, ciljno polje, razlog, iskanje po vrednosti, minimalna pogostost.
Strežniška paginacija namesto TOP 300.
Stolpci: ciljno polje, vrednost iz vira, razlog, pojavitev, prvič, nazadnje, primer strani
(povezava na `/zajem/stran/{inboxId}`).
**Dejanje (ADMIN, CATALOG_EDITOR): »Dodaj v slovar«** — vgrajen obrazec z domeno (privzeto iz
ciljnega polja), izvorno vrednostjo (predizpolnjeno, samo za branje), jezikom, ciljno vrednostjo
in opombo. Po shranjevanju sporočilo: »Shranjeno. Odklenjeno bo ob naslednji preslikavi vira X.«
Nikoli ne trdimo, da je vrednost že popravljena — ker ni, dokler preslikava ne teče znova.

### 6.8 `/zajem/kategorije`

Vir: **`map.SourceCategory` / pogled `map.SourceCategoryToMap`** (migracija 091), ne stara
`map.MissingCategoryMap`.
Stolpci: vir, berljiva pot (raven 1 > 2 > 3), normaliziran ključ, št. izdelkov, prvič, nazadnje,
stanje preslikave (preslikana v drevo X / brez cilja).
Filtri: vir, drevo (`canon.WebSite`), samo nepreslikane, iskanje po poti, minimalno št. izdelkov.
**Dejanje (ADMIN, CATALOG_EDITOR): »Preslikaj«** — izbira drevesa in kategorije iz `canon.Category`
z iskalnikom po poti; zapiše `map.CategoryPathMap`. Prikaži »s tem dobi uvrstitev N izdelkov«.
Panel zgoraj: pokritost po viru — koliko odstotkov izdelkov ima uvrstitev.

### 6.9 `/zajem/prevodi`

Filtri: domena, jezik, iskanje, minimalna pogostost; strežniška paginacija.
Stolpci: domena, jezik, vrednost iz vira, pojavitev, prvič, nazadnje, predlog (če obstaja).
**Dejanje (ADMIN, CATALOG_EDITOR): »Vpiši prevod«** — zapiše `map.ValueLookup` in vrstico
označi kot rešeno. Če pride AI-predlog, je v svojem stolpcu in je jasno označen kot predlog,
dokler ga človek ne potrdi.

### 6.10 `/zajem/zaloge`

Prva stran, ki vhod zaloge sploh pokaže.
KPI: zadnji uspešen prevzem po viru, prebranih zapisov, uporabljenih, zavrnjenih, starost
aktivnega posnetka.
Tabela tekov: `stock.SyncRun` (vir, ponudnik, končna točka, HTTP status, začetek, trajanje,
prebrano/uporabljeno/zavrnjeno, status).
Tabela zavrnjenih: `stock.UnmatchedPosition` (razlog, podrobnost, izvorna šifra/EAN, datum) s
filtri in paginacijo — to je delovni seznam komerciale.
Brez zapisovalnih gumbov, dokler ne obstaja procedura za ponoven prevzem.

---

## 7. Kaj mora nastati v bazi (ozemlje BAZA)

Pravilo `AGENTS.md` §7: BAZA → INTRANET, ločena commita. Intranet **ne sme** dobiti novih
strani z vgrajenim SQL-om; `NACRT_INTRANET_PRENOVA.md` zahteva `intranet.*` procedure.

### 7.1 Migracija 093 — bralni model vhodov (samo branje)

| Procedura | Vrne |
|---|---|
| `intranet.GetIngestOverview @OrganizationId (NULL = vsa)` | 4 nabori: KPI, vrstice vhodnih poti, entitete brez preslikave, odprti alarmi vhodov |
| `intranet.GetIngestSources @OrganizationId, @IncludeInactive` | register + zdravje + urnik v eni vrstici na vir |
| `intranet.GetIngestSourceDetail @OrganizationId, @SourceCode` | 4 nabori: entitete z mejniki, zadnji teki, povzetek preslikav, napake |
| `intranet.GetIngestRuns @OrganizationId, @Pipeline, @SourceCode, @Status, @FromUtc, @ToUtc, @Search, @Skip, @Take` | vrstice + `TotalCount` |
| `intranet.GetIngestRunDetail @RunId` | glava, koraki, strani, napake |
| `intranet.GetInboxPages @OrganizationId, @SourceCode, @EntityType, @Status, @OlderThanHours, @Skip, @Take` | vrstice + `TotalCount` |
| `intranet.GetInboxPageDetail @InboxId, @PayloadMaxLength` | glava, odrezan payload, izluščene vrednosti, neujemanja |
| `intranet.GetIngestQuarantine @OrganizationId, @SourceCode, @EntityType, @Search, @Skip, @Take` | povzetek po razlogu + vrstice + `TotalCount` |
| `intranet.GetUnmappedValues @OrganizationId, @TargetFieldCode, @Reason, @Search, @MinSeen, @Skip, @Take` | vrstice + `TotalCount` + primer `InboxId` |
| `intranet.GetSourceCategories @OrganizationId, @SourceCode, @TreeCode, @OnlyUnmapped, @Search, @MinProducts, @Skip, @Take` | vrstice + `TotalCount` + pokritost po viru |
| `intranet.GetMissingTranslations @Domain, @Language, @Search, @MinSeen, @Skip, @Take` | vrstice + `TotalCount` |
| `intranet.GetStockIngest @OrganizationId, @Skip, @Take` | KPI, teki `stock.SyncRun`, zavrnjene pozicije |

Zahteve za vse: parametrizirano, `OrganizationId` obvezna meja (razen izrecnega »vsa podjetja«),
brez `SELECT *`, `TotalCount` v drugem naboru, brez poverilnic in gesel v izhodu,
`LastErrorRedacted` se vrne takšen, kot je zapisan (že očiščen).

Dodatno v 093: stolpec **`map.SourceConnector.IntakeKind`** (`API`, `FOLDER`, `HTTP`, `FTP`,
`MANUAL`) in **`IntakeLocation`** (mapa, URL brez poverilnic, FTP gostitelj + pot) — brez tega
stran ne more povedati, od kod vir prihaja, to pa je bila izrecna odločitev uporabnika
(`TVOJE_NALOGE.md` §1). Poverilnice ostanejo v `appsettings.Local.json`.

### 7.2 Migracija 094 — zapisovalne poti (šele po 093)

| Procedura | Kaj naredi | Revizija |
|---|---|---|
| `intranet.RequeueInboxPages @OrganizationId, @InboxIds (TVP), @Actor, @Reason` | `Pending`/`Quarantined` → `Quarantined` z razlogom »Ročna vrnitev v vrsto«, `ProcessedUtc = NULL` | zapiše v `ops.ErrorLog` ali novo `ops.UserActionLog` |
| `intranet.RemapRun @RunId, @OrganizationId, @SourceCode, @Actor` | pokliče `map.ProcessRawInbox` | isto |
| `intranet.SaveValueLookup @Domain, @SourceValue, @Language, @TargetValue, @Note, @Actor` | MERGE v `map.ValueLookup`; če obstaja `map.MissingTranslation`, jo označi kot rešeno | isto |
| `intranet.SaveCategoryPathMap @SourceCode, @CategoryTreeCode, @SourcePathKey, @CategoryCode, @Actor` | MERGE v `map.CategoryPathMap`, preveri obstoj kategorije v `canon.Category` | isto |
| `intranet.SetIngestSchedule @OrganizationId, @Pipeline, @IsEnabled, @IntervalSeconds, @NextScheduledUtc, @Actor` | UPDATE `ops.ScheduleProfile` z `UpdatedBy` | stolpec `UpdatedBy` že obstaja |

Vsaka zapisovalna procedura dobi `@Actor` iz prijavljene identitete (vzorec `@ChangedBy`
iz `b2b.*`), nikoli konstante. Vsaka je idempotentna in v transakciji.

**Kar zavestno ne delamo:** intranet ne kliče SAOP in ne zaganja workerjev. Test F8 prepoveduje
`HttpClient` v intranetu. »Zaženi zdaj« je v resnici »premakni `NextScheduledUtc`«, in besedilo
v UI mora to povedati: **»Naročeno. Zajem se bo zagnal ob naslednjem ciklu.«**

---

## 8. Vrstni red dela

| Korak | Ozemlje | Vsebina | Dokaz |
|---|---|---|---|
| V1 | BAZA | migracija 093 (bralne procedure + `IntakeKind`/`IntakeLocation`) | migrator 1. in 2. zagon + `--verify` = 0; ročni `EXEC` vsake procedure vrne pričakovane nabore |
| V2 | INTRANET | vseh 12 strani, **samo branje**, `IngestReadService` nad 093, brez SQL v Razorju | `scripts\run_tests.ps1 -Filter F1` … oz. nov `PIM.F11.IngestUxTests` = 0; build = 0/0 |
| V3 | BAZA | migracija 094 (zapisovalne procedure + revizija) | migrator + `--verify` = 0; pred/po vrstici za vsako proceduro |
| V4 | INTRANET | dejanja na straneh (vrni v vrsto, preslikaj znova, dodaj v slovar, preslikaj kategorijo, prevod, urnik) | pogodbeni test preveri vloge in obstoj zapisovalne poti; ročni seznam iz `INTRANET.md` §7 |

V2 je uporabna dostava sama zase: vse vidno, nič lažnih gumbov.

---

## 9. Prompt za Codex

Spodnje besedilo je namenjeno neposrednemu lepljenju. Poganjaj korak za korakom (V1, nato V2 …),
ne vseh naenkrat — ozemlji BAZA in INTRANET ne smeta biti v istem commitu.

````text
KONTEKST

Delaš v repozitoriju NoviPIM (C:\Users\David\Namizje\PIM\NoviPIM). Preberi in upoštevaj
AGENTS.md v celoti — to je edini vir pravil. Posebej §2.1 (produktni model), §3 (kaj je dokaz),
§4 (kdaj vprašaš), §7 (ozemlja: BAZA in INTRANET nikoli v istem commitu), §8 (delovni tok).
Preberi tudi docs/PRODUKTNI_MODEL_PIM.md (§2 faza VHODI, §5 obvezna pogodba strani),
docs/INTRANET.md (§6 UX omejitve — obvezne), docs/NACRT_VHODI_INTRANET.md (ta načrt) in
docs/ZAJEM-SAOP.md (kako zajem dejansko teče).

Stack: .NET 10, Blazor Server (interaktivni strežniški način), MS SQL. Ni Node, ni React.
Aplikacija teče tudi pod IIS na /PIM, zato so VSE notranje povezave base-relativne
("zajem/viri", nikoli "/zajem/viri"). Jezik celotnega vmesnika je slovenščina.

NALOGA (korak V1 — ozemlje BAZA)

Napiši migracijo sql/migrations/093_IngestReadModel.sql. Migracija je samo dodajanje,
idempotentna, brez DROP in DELETE.

1. Dodaj v map.SourceConnector stolpca:
   - IntakeKind nvarchar(20) NOT NULL DEFAULT N'API', CHECK IN (N'API',N'FOLDER',N'HTTP',N'FTP',N'MANUAL')
   - IntakeLocation nvarchar(1000) NULL  -- mapa, URL brez poverilnic ali FTP gostitelj+pot
   Obstoječim vrsticam nastavi: ConnectorType='SAOP' -> 'API'; 'FILE_XML' -> 'FOLDER'.
   IntakeLocation pusti NULL, kjer je ne veš — NE izmišljuj poti.

2. Ustvari bralne procedure v shemi intranet (vse parametrizirane, brez SELECT *,
   OrganizationId je obvezna meja podatkov, paginirane vračajo TotalCount v drugem naboru):

   intranet.GetIngestOverview @OrganizationId int = NULL
     Nabor 1 (KPI, ena vrstica): HealthyPaths, TotalPaths, PendingPages, OldestPendingUtc,
       QuarantinedPages, UnmappedValues, MissingTranslations, UnmappedSourceCategories,
       StockUnmatched, LastStockSyncUtc
     Nabor 2 (vhodne poti, ena vrstica na organizacijo+vir): OrganizationId, OrganizationName,
       SourceCode, Pipeline, IntakeKind, IntakeLocation, HealthStatus, LastSuccessfulRunUtc,
       LastFailedRunUtc, NextScheduledUtc, ScheduleEnabled, RowsRead24h, PendingPages,
       QuarantinedPages, UnmappedValues, LastErrorRedacted
       Viri: map.SourceConnector, ops.IntegrationHealth, ops.ScheduleProfile, ops.PipelineRun,
       raw.Inbox, dbo.OrganizationConfig. Vključi tudi vire zaloge iz stock.SyncRun.
     Nabor 3 (zajeto brez preslikave): OrganizationId, SourceCode, EntityType, PendingPages,
       OldestUtc — entitete z raw.Inbox Status='Pending', za katere NE obstaja hkrati aktivna
       map.EntityMapping IN aktivna map.FieldMapping.
     Nabor 4 (odprti alarmi vhodov): AlertId, OrganizationId, Pipeline, AlertKind, Severity,
       naslov, CreatedUtc, AcknowledgedUtc.

   intranet.GetIngestSources @OrganizationId int = NULL, @IncludeInactive bit = 1
   intranet.GetIngestSourceDetail @OrganizationId int, @SourceCode nvarchar(100)
     4 nabori: entitete (EntityType, HasEntityMapping, ActiveFieldCount, RequiredFieldCount,
     WatermarkValue, WatermarkUpdatedUtc, PendingPages, ProcessedPages, QuarantinedPages,
     LastReceivedUtc), zadnjih 20 tekov, povzetek preslikav, zadnje napake iz ops.ErrorLog
     in ops.DeadLetterQueue.
   intranet.GetIngestRuns @OrganizationId int = NULL, @Pipeline nvarchar(100) = NULL,
     @SourceCode nvarchar(100) = NULL, @Status nvarchar(30) = NULL, @FromUtc datetime2(3) = NULL,
     @ToUtc datetime2(3) = NULL, @Search nvarchar(200) = NULL, @Skip int = 0, @Take int = 50
   intranet.GetIngestRunDetail @RunId uniqueidentifier
     4 nabori: glava teka, koraki iz ops.PipelineStepLog, strani raw.Inbox tega teka,
     napake iz ops.ErrorLog s tem RunId/CorrelationId.
   intranet.GetInboxPages @OrganizationId int, @SourceCode = NULL, @EntityType = NULL,
     @Status = NULL, @OlderThanHours int = NULL, @Skip int = 0, @Take int = 50
     Poleg vrstic vrni tudi povzetek po viru/entiteti/stanju (prvi nabor) — kot ima danes
     stran /zajem/cakalna-vrsta.
   intranet.GetInboxPageDetail @InboxId bigint, @PayloadMaxLength int = 20000
     3 nabori: glava strani, LEFT(PayloadXml, @PayloadMaxLength) + PayloadLength,
     izluščene vrednosti iz map.ExtractedValue z morebitnim razlogom iz map.UnmappedValue.
   intranet.GetIngestQuarantine @OrganizationId int, @SourceCode = NULL, @EntityType = NULL,
     @Search = NULL, @Skip int = 0, @Take int = 50   -- prvi nabor: povzetek po razlogu
   intranet.GetUnmappedValues @OrganizationId int, @TargetFieldCode = NULL, @Reason = NULL,
     @Search = NULL, @MinSeen int = 1, @Skip int = 0, @Take int = 50
     Vrni tudi SampleInboxId (ena stran, kjer se vrednost pojavi) in FirstSeenUtc.
   intranet.GetSourceCategories @OrganizationId int, @SourceCode = NULL, @TreeCode = NULL,
     @OnlyUnmapped bit = 1, @Search = NULL, @MinProducts int = 0, @Skip int = 0, @Take int = 50
     Vir je map.SourceCategory / pogled map.SourceCategoryToMap iz migracije 091 (NE stara
     map.MissingCategoryMap). Prvi nabor: pokritost po viru (izdelkov skupaj, z uvrstitvijo, %).
   intranet.GetMissingTranslations @Domain = NULL, @Language = NULL, @Search = NULL,
     @MinSeen int = 1, @Skip int = 0, @Take int = 50
   intranet.GetStockIngest @OrganizationId int, @Skip int = 0, @Take int = 50
     3 nabori: KPI zaloge, teki stock.SyncRun, zavrnjene pozicije stock.UnmatchedPosition
     z razlogom in podrobnostjo.

DOKAZ ZA V1 (brez tega naloga ni končana)
- dotnet run --project PIM_Solution\src\PIM.Migrator -- --verify  => izhod 0
- migrator pognan dvakrat zapored (idempotentnost) => izhod 0 obakrat
- za VSAKO novo proceduro en EXEC proti lokalni bazi PIM z izpisom števila vrstic po naboru;
  izpis prilepi v poročilo
- dotnet build PIM_Solution\PIM.sln => 0 napak
- posodobi docs/DATABASE.md in TASKBOARD.md v ISTEM commitu
- commit: feat(baza): bralni model vhodov za intranet (093)

PREPOVEDANO
- spreminjanje obstoječih migracij (samo nova, višja številka)
- DROP, DELETE, TRUNCATE karkoli
- poverilnice, gesla ali connection stringi v migraciji ali dokumentaciji
- spreminjanje datotek v src/PIM.Intranet v tem commitu
````

Ko je V1 potrjen, poženi drugi prompt:

````text
NALOGA (korak V2 — ozemlje INTRANET, samo branje)

Predpogoj: migracija 093 je uporabljena in preverjena.

Zgradi modul VHODI po docs/NACRT_VHODI_INTRANET.md §5 in §6. Nobene strani z vgrajenim SQL-om:
vse gre skozi nov PIM.Intranet/Services/IngestReadService.cs, ki kliče izključno procedure
intranet.* iz migracije 093, prek obstoječega PimDb (parametrizirano, preslikava stolpcev po
IMENU, nikoli po zaporedni številki).

STRANI (vse [Authorize], @rendermode InteractiveServer, MainLayout, base-relativne povezave)

1. /zajem — Nadzor vhodov (nadomesti obstoječi Ingest.razor)
   - stikalo obsega: "Aktivno podjetje" / "Vsa podjetja"
   - 6 KPI kartic (PimStat): Vhodne poti v redu (n/m), Čaka na preslikavo (+ starost najstarejše),
     V karanteni, Nerazvrščene vrednosti, Delovni seznam preslikav, Zaloga
   - tabela "Vhodne poti": Podjetje, Vir, Vrsta prevzema, Stanje (PimChip), Zadnji uspeh,
     Zadnji neuspeh, Naslednji zagon, Prišlo (24 h), Čaka, Zavrnjeno, Zadnja napaka (skrajšano)
     Čipi: Healthy=good, Running=nevtralno, Stale=warn, Failed=bad, NeverRun=brez tona.
     NEZNAN status se izpiše z izvorno vrednostjo.
   - panel "Zajeto brez preslikave" s pojasnilom v enem stavku in povezavo na pravila/preslikave
   - panel "Odprti alarmi vhodov" (branje; dejanja šele v V4)
   - razdelilne kartice (PimHubCard) na vse podstrani, vsaka s številko iz baze

2. /zajem/viri — register + zdravje + urnik; filtri: podjetje, vrsta prevzema, stanje, samo aktivni
3. /zajem/viri/{SourceCode} — zavihki Entitete / Teki / Preslikave / Napake;
   stolpec "Mejnik" je PO ENTITETI, ne po viru
4. /zajem/teki (+ alias /teki-obdelave) — STREŽNIŠKI filtri in paginacija (PimPager, Take=50):
   podjetje, cevovod, vir, status, obdobje (danes / 7 dni / 30 dni / po meri), iskanje;
   stolpci: Začetek, Trajanje, Cevovod, Vir, Prebrano, Uspešno, Zavrnjeno, Status, Konec;
   vrstica vodi na /zajem/teki/{RunId}
5. /zajem/teki/{RunId} — glava, koraki (ops.PipelineStepLog), strani teka, napake teka
6. /zajem/cakalna-vrsta — povzetek po skupinah + strani; filtri: podjetje, vir, entiteta, stanje,
   starost ("starejše od 24 h"); stolpca Starost in RunId (povezava na tek);
   vrstica vodi na /zajem/stran/{InboxId}
7. /zajem/stran/{InboxId} — glava strani, predogled payloada v <pre> znotraj vsebnika z
   overflow-x:auto (NIKOLI ne razširi strani), tabela izluščenih vrednosti z razlogom zavrnitve
8. /zajem/karantena (+ aliasa /karantena in /kakovost/karantena) — najprej povzetek PO RAZLOGU,
   nato strani s filtri in strežniško paginacijo
9. /zajem/neujemanja — filtri: ciljno polje, razlog, iskanje, minimalna pogostost;
   stolpci: Ciljno polje, Vrednost iz vira, Razlog, Pojavitev, Prvič, Nazadnje, Primer strani
10. /zajem/kategorije (+ alias /kakovost/kategorije) — vir je map.SourceCategory iz migracije 091;
    stolpci: Vir, Berljiva pot (raven 1 > 2 > 3), Ključ, Izdelkov, Prvič, Nazadnje, Stanje;
    zgoraj panel pokritosti po viru
11. /zajem/prevodi (+ alias /kakovost/prevodi) — filtri domena, jezik, iskanje, min. pogostost
12. /zajem/zaloge — KPI zaloge, teki stock.SyncRun, zavrnjene pozicije stock.UnmatchedPosition

NAVIGACIJA
V Services/PimNavigation.cs pusti eno menijsko postavko "Zajem in preslikave" -> "zajem"
(IsHub: true). Podstrani so dosegljive samo z razdelilne strani. Vse stare poti morajo še naprej
delovati kot aliasi (@page direktive), da zaznamki ne padejo.

OBVEZNE OMEJITVE (docs/INTRANET.md §6 — pogodbeni testi jih preverjajo)
- NOBENE izmišljene vrednosti. Vsaka številka, ime in datum pride iz baze.
- NOBENEGA gumba, ki bi videti shranjeval. V tem koraku so vse strani BRALNE. Zapisovalna
  dejanja pridejo v koraku V4 in šele po migraciji 094.
- Skupni razredi, ne Bootstrap: page-header, ui-card, data-table, error-state, loading-state,
  status, metric-card. Razredi row/col/card/table/form-control/form-select/form-check/btn so
  prepovedani.
- Uporabi obstoječe gradnike: PimPage, PimTable, PimState, PimPager, PimChip, PimStat,
  PimHubCard, PimColumn, PimCrumb. Ne piši novih tabel na roko.
- Dostopnost: vsak sklop ima aria-labelledby na obstoječ h2; tabele imajo <caption> in scope;
  statusni čipi imajo skrito oznako "Status: "; stanje napake je role="alert", nalaganje
  role="status"; okrasne ikone aria-hidden="true"; vse interaktivno ima :focus-visible z outline.
- Nalaganje in napaka se izključujeta.
- Vsaka stran ima svojo <Stran>.razor.css; brez <style> blokov v .razor.
- Organizacija se VEDNO vzame iz Data.GetCurrentOrganizationAsync(), nikoli kot konstanta
  (vzorec "Async(2," je prepovedan in ga preverja test).
- Intranet ne sme uporabljati HttpClient (preverja test F8).
- Ikone so CSS/SVG, ne Unicode znaki; znak ☰ je prepovedan.
- Vsa besedila v slovenščini, vključno s praznimi stanji in napakami. Prazno stanje pove, kaj
  to pomeni ("Ni čakajočih strani" ni isto kot "Ni podatkov").

NOV POGODBENI TEST
Ustvari tests/PIM.F11.IngestUxTests (konzolna aplikacija, OutputType Exe, net10.0, dodana v
PIM.sln, po vzoru tests/PIM.F10.QualityUxTests). Preveri:
- obstoj vsake od 12 strani in pripadajoče .razor.css datoteke
- da je vsaka pot registrirana natanko enkrat in da aliasi obstajajo
- da nobena stran ne vsebuje niza "Data.Get...Async(2," (trda organizacija)
- da nobena stran ne vsebuje Bootstrap razredov iz seznama zgoraj
- da nobena stran ne vsebuje HttpClient
- da nobena stran v tem koraku nima zapisovalnih gumbov (išči @onclick z imeni Save/Shrani/Dodaj/
  Vrni/Preslikaj) — v V2 morajo strani biti brez njih
- dostopnostno pogodbo: caption, scope="col", role="alert", role="status", aria-labelledby
- da so vse href povezave base-relativne (ne začnejo se z "/")
Izpis ob uspehu: "F11 ingest UX contract PASS."

DOKAZ ZA V2
- scripts\run_tests.ps1 -Filter F11  => izhod 0
- scripts\run_tests.ps1 -Filter F10  => izhod 0 (nič obstoječega ne sme pasti)
- dotnet build PIM_Solution\PIM.sln  => 0 opozoril, 0 napak
- ročni zagon intraneta in klik skozi vseh 12 strani; navedi, katere si odprl in kaj si videl
- posodobi docs/INTRANET.md (§2 poti, §3 viri podatkov, §7 ročni seznam) in TASKBOARD.md
  v ISTEM commitu
- commit: feat(intranet): modul vhodov z nadzorom, teki, vrsto in delovnimi seznami

ČE SE USTAVIŠ
Če procedura iz 093 vrne drugačne stolpce, kot jih stran potrebuje, NE piši SQL-a v Razor in NE
spreminjaj testa. Javi BLOKIRANO z imenom procedure, pričakovanimi in dejanskimi stolpci.
````

Tretji in četrti prompt (V3 = migracija 094, V4 = dejanja v UI) se napišeta po enakem vzorcu,
ko je V2 potrjen. Ključni stavek za V4: vsako dejanje je POST z antiforgery, vsako pokliče
proceduro iz 094 z `@Actor` iz prijavljene identitete, in besedilo po uspehu nikoli ne trdi
več, kot se je zgodilo — »Naročeno. Zajem se bo zagnal ob naslednjem ciklu.«

---

## 10. Česa ta načrt ne obljublja

- Nobenega zagona workerja iz vmesnika. Intranet nima `HttpClient` in ga ne bo dobil; »zaženi«
  pomeni premik `NextScheduledUtc`.
- Nobenega grafa trendov. Zgodovinskega read modela za vhode ni; `ops.PipelineRun` ni
  zgodovinski vir za trende in ga tako ne bomo uporabili.
- Nobenega urejanja `map.FieldMapping` iz vmesnika v tem krogu. Preslikave polj imajo večjo
  posledico kot slovar in potrebujejo svojo revizijsko pogodbo.
- Nobenega prikaza poverilnic, URL-jev s ključi ali vsebine `appsettings.Local.json`.
