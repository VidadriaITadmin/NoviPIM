# Načrt prenove PIM Intraneta — analiza in načrt

Datum: 2026-08-23. Avtor: Claude Code. Stanje: **izvedba v teku; stanje izvedbe je v §11–12.**
Sprejeti odločitvi (2026-08-23, uporabnik): **retarget na `net10.0` v fazi I0** (§2.3 B2) in
**model zapisa nazaj v SAOP** (§4).

Ta dokument je analiza starega intraneta (`..\PIM_test\src`), meritev novega
(`PIM_Solution\src\PIM.Intranet`) in predlog informacijske arhitekture, funkcionalnosti
in vrstnega reda dela. Ni referenca stanja — to ostane `docs\INTRANET.md`.

---

## 0. Kaj sem pregledal in kaj so številke

| Kaj | Meritev |
|---|---|
| Stari intranet — strani | **61** `.razor` strani, skupaj **15.124** vrstic (Pages + Shared + Layout) |
| Stari intranet — podatkovni sloj | `PimQueryService` razbit na **29** delnih datotek + 8 SAOP graditeljev |
| Novi intranet — vse skupaj | **1.412** vrstic (15 strani, 7 storitev, 2 postavitvi) |
| Baza NoviPIM | **78** migracij (001–080, brez 015 in 048), ~85 tabel, **18** `intranet.*` procedur |
| Potrjene UX reference | 12 slik v `..\PIM_test\UX_pictures`, preslikava v `PIM_Solution\UX\TARGET_STATE.md` |

Razmerje pove vse: **baza je zrela, intranet je skica.** Prenova ni prepis stare aplikacije,
ampak izdelava vmesnika za sistem, ki ga stara aplikacija nikoli ni imela.

---

## 1. Stari PIM_test — kaj je znal in kaj je narobe

### 1.1 Informacijska arhitektura je bila dobra

`Services\PimNavigationCatalog.cs` opisuje **13 področij po življenjskem ciklu izdelka**:
Pregled → Izdelki → Mediji → Stranke → Partnerji → Zaloga → Cene → Kakovost → Uvozi →
Izvozi → Nastavitve kataloga → Pravila → Sistem. Vsaka stran je v meniju natanko enkrat,
podstrani so dosegljive iz matične strani, skupine z eno destinacijo so direktne povezave.
**To je edini del stare aplikacije, ki ga je vredno prevzeti skoraj nespremenjenega.**

### 1.2 Kaj je funkcionalno znala (in kar moramo tudi mi)

| Skupina | Kaj je delala |
|---|---|
| **Izdelki** | seznam z zavihki po statusu, iskanje, sestavljivi filtri (organizacija, ABC, proizvajalec, vir, slika/brez slike, popolnost, kaskada kategorij 4 nivoje), izbira stolpcev, shranjen pogled, CSV izvoz, kartica izdelka z zavihki |
| **Priprava (STG)** | ločen seznam artiklov pred potrditvijo, množično urejanje prek CSV izvoza in uvoza, validacija, potrditev za ERP |
| **Zajem** | pregled XML uvoza (novi/spremenjeni/manjkajoči/umaknjeni), novi artikli iz XML, uvoz iz Excela z validacijo pred zapisom |
| **Kakovost** | pregled kakovosti (koliko napak, katera pravila jih sprožijo), seznam odprtih napak, karantena po artiklu, urejanje v karanteni z revalidacijo |
| **ERP zapis nazaj** | nov artikel v SAOP (posamično ali iz Excela), sprememba artikla, množične spremembe, izločitev iz rezervacije, vrsta pošiljanja z zgodovino in ponovnim pošiljanjem, odhodni pregled vseh zahtevkov |
| **Stranke** | register strank iz SAOP, podrobnost s kuriranimi polji, ki gredo nazaj v SAOP (PATCH), nova stranka (POST), popusti stranke, povezava stranka ↔ dobavitelj/proizvajalec |
| **Nastavitve kataloga** | atributi, kategorije, mapiranje atributov, mapiranje kategorij na spletni kanal (drevo↔drevo), spletni kanali, jeziki in prevodi, referenčni šifranti |
| **Pravila** | profili validacije (urejanje brez posega v kodo), spletna pravila, B2B pravila, pravila virov, sestava spletnih nazivov |
| **Sistem** | stanje sistema, uporabniki (lokalni BCrypt + AD), vloge in pravice, SAOP povezave prod/test, dnevnik dejavnosti, tehnični zemljevid (katera stran bere/piše katero tabelo) |

### 1.3 Zakaj je razmetano — konkretno, ne na občutek

1. **Poti so v štirih različnih jezikovnih registrih.** `/products`, `/stg/products`,
   `/artikli/xml-novi`, `/ingestion/xml-monitor`, `/pim/multiwebsite/title-rules`,
   `/export/saop-item-new`, `/exports/saop`. Uporabnik ne more uganiti poti, agent ne more
   uganiti, kam sodi nova stran.
2. **Ena entiteta, šest seznamov.** Isti izdelek se pojavi v `Products`, `StgProducts`,
   `XmlNewProducts`, `ErpReadyProducts`, `Quarantine` in `QualityIssues` — vsak s svojo
   tabelo, svojimi filtri, svojo paginacijo in svojim CSV izvozom. Popravek filtriranja je
   šestkratno delo.
3. **Dve navigacijski resnici.** Meni ima »Izvozi → SAOP / Splet«, dejansko delo pa je na
   `/export/saop-item-*`, ki v meniju sploh ni. »Stranke« so na `/customers`, »Povezave
   strank« pa na `/reference/customers`.
4. **Strani so monoliti.** `CustomerDetail.razor` 1.139 vrstic, `Products.razor` 917,
   `SaopItemNew.razor` 903 — v vsaki so hkrati postavitev, filtri, klici v bazo, gradnja
   XML in CSV izvoz.
5. **Podatkovni sloj brez oblike.** `PimQueryService` je razbit na 29 delnih datotek po
   straneh, ne po domeni; vsaka stran ima svojo poizvedbo za isti izdelek.
6. **Ni skupnega mrežnega gradnika.** Vsaka tabela je ročno napisan `<table>` s svojo
   paginacijo — od tod izvira tako neenoten videz kot slaba hitrost.

**Sklep:** prevzamemo IA in seznam funkcionalnosti, zavržemo strukturo strani in podatkovni sloj.

---

## 2. NoviPIM danes — kaj imamo in kaj blokira

### 2.1 Kar je že zgrajeno (in intranet tega še ne pokaže)

- `canon.*` — 2.548 izdelkov z 112.820 lastnostmi, kategorije, mediji, cene, besedila po
  jezikih, trgovinski podatki, embalaža, politika zaloge
- `val.*` — 7 validacijskih profilov, stopnja resnosti `ERROR`/`WARNING`, obseg blokade
  (`BlocksErp`/`BlocksWeb`), stanje in odprte napake po izdelku
- `pim.*` — objavljeni katalog, **zgodovina polj po izdelku, paketi sprememb in razveljavitev**
  (`ProductFieldHistory`, `ProductChangeBatch`, `UndoProductField`, `UndoProductBatch`)
- `out.*` — odhodna pošta z odobritvijo, razvrstitvijo napak, `Superseded` stanjem, preverjanjem
  odmeva (echo) in registrom izvoznih profilov/stolpcev
- `map.*` — konektorji virov, preslikave polj, slovar vrednosti (6.316 vrstic), pretvorbe,
  neujemanja, manjkajoči prevodi in kategorije
- `stock.*` — posnetki, pozicije (168.594), neujemanja, skladišča
- `ops.*` — teki, koraki, alarmi, srčni utrip, zdravje integracij, mrtva pisma
- `sec.*` — uporabniki (lokalni + AD), vloge, **navigacija v bazi**

### 2.2 Kaj intranet danes je

15 strani, od tega 3 mrtve (`Counter`, `Weather`, `Home`). Lupina (temna navigacija + zgornja
vrstica) in nadzorna plošča sta narejeni po potrjeni sliki in berejo iz baze. Vse ostalo so
osnovne tabele nad 18 `intranet.*` procedurami.

### 2.3 Blokade, ki jih moramo odpraviti takoj

| # | Ugotovitev | Dokaz | Posledica |
|---|---|---|---|
| B1 | **Nobena komponenta nima `@rendermode InteractiveServer`** | `grep -rni rendermode src/PIM.Intranet` vrne samo `Program.cs` in `_Imports.razor` | Aplikacija teče kot statični SSR: gumbi »Uporabi filtre«, »Naslednja stran«, preklop menija in `@bind` **v brskalniku ne naredijo nič**. Interaktivnost je registrirana, a nikjer uporabljena. |
| B2 | Vsi projekti so `net8.0` | `grep TargetFramework src/*/*.csproj` → 16× `net8.0` | **Odločeno: retarget na `net10.0` v I0.** .NET 8 (LTS) je podprt do 10. 11. 2026, .NET 9 je izven podpore od maja 2026 — izbira ni bila 8 ali 9, ampak 8 ali 10. .NET 10 je LTS do novembra 2028. Podrobnosti v §8, faza I0. |
| B3 | Strežniška paginacija obstaja samo za izdelke | `UX/LESSONS.md`, `intranet.GetProducts` | Stranke, teki, outbound in zaloge se paginirajo na odjemalcu nad vrnjenim naborom — pri 196.515 artiklih to ni izvedljivo. |
| B4 | Ni preslikave uporabnik ↔ organizacija, kanal, jezik | `MainLayout.razor` — izbirniki so `disabled` | Zgornja vrstica ima tri mrtve kontrole; večpodjetnost je vidna, a ne uporabna. |
| B5 | `sec.NavigationItem` ima 6 postavk | migraciji 010 in 018 | Navigacija v bazi obstaja, a ne pokriva IA. Bodisi jo napolnimo, bodisi ostane katalog v kodi — ne oboje. |
| B6 | Bootstrap je še vklopljen | `App.razor`, `wwwroot/bootstrap` | Dva vizualna sistema hkrati; `UX/LESSONS.md` že prepoveduje Bootstrap razrede na prenovljenih straneh. |

---

## 3. Zakaj Akeneo ni dovolj — in kaj to pomeni za dizajn

Akeneo je enosmeren: PIM je izvor resnice, podatki gredo ven. Naš sistem je **dvosmeren** —
SAOP je solastnik podatka. Iz tega izhajajo štirje koncepti, ki jih Akeneo nima in ki morajo
biti vidni v vmesniku:

1. **Lastništvo polja.** `pim.FieldOwnership` (`PIM` / `SAOP` / `SHARED`) in
   `out.OwnershipPolicy` (po organizaciji, tarči in polju). Vsako polje v kartici izdelka
   mora nositi značko lastnika, polja v lasti SAOP pa niso navadno urejanje.
2. **Urejanje kot predlog, ne kot dejstvo.** Sprememba polja v lasti SAOP ustvari sporočilo
   v `out.OutboxMessage` s stanjem `PendingApproval`. Uporabnik mora videti razliko med
   »shranjeno v PIM« in »poslano v SAOP, čaka potrditev«.
3. **Preverjanje odmeva.** `ExpectedEchoHash` / `out.VerifyEcho` / stanje `Drift`. Sporočilo
   ni končano, ko je poslano, ampak ko SAOP vrne isto vrednost. Za to potrebuje stran
   »Odhodna pošta« svoj življenjski cikel: čaka odobritev → poslano → potrjeno / odmik / mrtvo.
4. **Sledljivost in razveljavitev.** `pim.ProductFieldHistory` + `ProductChangeBatch` +
   `UndoProductBatch` pomenita, da ima vsaka sprememba avtorja, čas, prejšnjo vrednost in
   gumb »razveljavi« — za posamezno polje ali za cel paket množične obdelave.

**Vizualni jezik prevzamemo iz Akeneo (in iz potrjenih slik), delovni model pa je naš.**

---

## 4. Zapis nazaj v SAOP — sprejeta odločitev

Odločeno 2026-08-23. To je najtežje vprašanje celotnega vmesnika, zato je tu zapisano tudi,
kaj smo zavrnili in zakaj.

### 4.1 Pravilo

> **`canon` je to, kar pravi SAOP. Vanj ne zapišemo ničesar, česar SAOP še ni potrdil.**
> Želena vrednost živi v `out.OutboxMessage`; uporabnik jo vidi kot **prekrivko** nad
> kanonično vrednostjo, označeno z »čaka potrditev«.

Prekrivka da oba učinka hkrati: takojšnjo povratno informacijo (kot dvojni vpis) in resnico
(kot čakanje na GET). Vrednost je takoj vidna — samo ne pretvarjamo se, da je dejstvo.

### 4.2 Zavrnjeni možnosti

**Dvojni vpis (hkrati v PIM in v SAOP, nato čakanje na potrditev) — zavrnjeno.**

1. **SAOP zavrne.** PIM ima vrednost, SAOP je nima, in nič tega ne zazna. Nastane laž, ki je
   nevidna.
2. **SAOP normalizira.** Obreže na dolžino polja, zaokroži, prevede skupino popusta. Shranjena
   je naša različica; naslednji delta zajem jo tiho povozi. Urednik čez dve uri vidi, da je
   popravek »izginil«, in to prijavi kot napako. Pri echo modelu je isti primer **poimenovan**:
   `Drift`, s pričakovano in dejansko vrednostjo.
3. **Atomarnosti ni.** »Zapiši v SQL« in »zapiši v SAOP prek HTTP« ne moreta biti ena
   transakcija. Nikoli.

**Čisto čakanje na GET (brez lokalnega stanja) — zavrnjeno.** Urednik shrani ob 9:00 in do
naslednjega zajema ne vidi ničesar; poleg tega ni sledu, da smo poskusili.

### 4.3 Trije primeri, tri poti

| Primer | Pot | Odziv za uporabnika |
|---|---|---|
| **Polje v lasti PIM** — spletni naziv, opis, kategorija, medij, lastnost | neposreden zapis v `canon`/`pim`, SAOP sploh ne izve | takojšen |
| **Polje v lasti SAOP, obstoječi artikel** | `out.OutboxMessage`: `PendingApproval` → `Sent` → echo → `Verified` / `Drift`; v `canon` piše samo zajem | takoj viden kot prekrivka, potrjen v sekundah |
| **Nov artikel** | SAOP-first, ker **šifro dodeli SAOP** — dvojni vpis tu sploh ni mogoč, ker ključa nimamo: osnutek v PIM → POST → odgovor vrne šifro; če je ne vrne, `out.SaopItemAssignment` ujame po enoličnem EAN (dvoumen EAN ni ujemanje → človek) → naslednji zajem ustvari pravi `canon.Product` in osnutek se nanj priveže | osnutek takoj, šifra ob potrditvi |

Lastnika določa `pim.FieldOwnership` (`PIM` / `SAOP` / `SHARED`) oziroma `out.OwnershipPolicy`
po organizaciji in tarči. Ker je večina uredniškega dela na poljih v lasti PIM, velja stanje
»čaka potrditev« za manjšino polj — to ni splošna počasnost vmesnika.

### 4.4 Odgovor SAOP ni dokaz

HTTP 2xx pomeni »sprejeto«, ne »shranjeno tako, kot je bilo poslano«. Odgovor uporabimo samo
za prehod v `Sent` in za prevzem dodeljene šifre. Dokaz je **echo iz GET-a** — za to obstaja
`ExpectedEchoHash` in `out.VerifyEcho`.

### 4.5 Kako potrditev ne traja ur

Po uspešnem pošiljanju **ne čakamo na razporejen zajem**, ampak sprožimo ozko delta branje:
`searchQuery.recordDtModifiedFrom` = čas pošiljanja − 2 minuti, samo za prizadeto končno točko.
`SaopApiClient` to že zna; per-item filtra API nima, zato je **ozek watermark naše ciljno
branje**. Vrne nekaj zapisov, potrditev je v ~10–30 sekundah.

Pri množični spremembi 500 artiklov ne sprožimo 500 branj — **eno** delta branje potrdi vse,
ker jih okno zajame skupaj.

Dve pasti:

- **To branje ne sme premakniti `map.Watermark`.** Na tem smo se že opekli pri `--only-ingest`
  (glej `STATUS.md`, 2026-08-21): premaknjen mejnik pomeni trajno preskočeno obdobje.
- **`Customers` je `Lookup`, brez watermarka.** Za stranke echo pride šele iz naslednjega
  polnega branja šifranta — en klic, zato poceni, a ne ciljano.

### 4.6 Zajem ne sme povoziti čakajoče spremembe

Če delta prinese vrednost za polje, za katero obstaja sporočilo v stanju `Sent`, in se hash ne
ujema, je to `Drift` — ne tiho prepisovanje. Če je bilo medtem poslano novejše sporočilo za
isto polje, je starejše `Superseded`. Obe pravili sta že razrešeni v `EchoVerifier.cs` in
`out.VerifyEcho`.

### 4.7 Kaj manjka, da to zares deluje

Preverjeno 2026-08-23: **`out.VerifyEcho` ni nikoli poklicana.** Procedura obstaja, migrator
preverja njen obstoj, `EchoVerifier.cs` ima pravila razrešena do zadnjega primera — a je ne
kliče ne worker ne `map.ProcessRawInbox`. Zanka torej ni sklenjena: pošiljanje bi delovalo,
potrditev pa nikoli ne bi prišla in vsako sporočilo bi za vedno obtičalo v `Sent`.

Štiri manjkajoče stvari, vse v fazi I4:

1. `map.ProcessRawInbox` ob preslikavi pokliče `out.VerifyEcho` s hashem prejete vrednosti.
2. Zapisovalne končne točke SAOP (POST/PATCH poti) v register — danes je v `SaopEndpoints`
   samo 16 bralnih. Dispatcher (`SaopOutboundHandler`) POST in PATCH že podpira.
3. Ciljno delta branje po pošiljanju, brez premika `map.Watermark`.
4. Zapisovalna pot in prekrivka v intranetu.

---

## 5. Predlagana informacijska arhitektura

Devet skupin namesto trinajstih. Združil sem stanja izdelka v eno os in izvoze v en modul.

| # | Skupina | Pot | Strani |
|---|---|---|---|
| 1 | **Pregled** | `/` | nadzorna plošča, moja opravila |
| 2 | **Izdelki** | `/izdelki` | seznam s shranjenimi pogledi (vsi / za urediti / v pripravi / objavljeni / arhiv), kartica izdelka, množična obdelava, zgodovina in razveljavitev |
| 3 | **Kakovost** | `/kakovost` | pregled po profilih, napake, karantena, manjkajoči prevodi in kategorije |
| 4 | **Zajem** | `/zajem` | viri in konektorji, teki obdelave, čakajoče strani `raw.Inbox`, neujemanja, ročni uvoz (Excel/CSV) |
| 5 | **Objava** | `/objava` | izvozni profili, predogled, zgodovina izvozov, prenosi datotek |
| 6 | **Odhodna pošta (ERP)** | `/erp` | vrsta za odobritev, poslano, odmiki, mrtva pisma, lastništvo polj, dodelitev novih šifer |
| 7 | **Poslovni podatki** | `/zaloge`, `/cene`, `/stranke`, `/partnerji` | zaloge po skladiščih, ceniki, register strank in popusti, dobavitelji/proizvajalci |
| 8 | **Nastavitve kataloga** | `/nastavitve` | atributi, kategorije, preslikave (atributi, kategorije, vrednosti), spletni kanali, jeziki in prevodi, pravila validacije, šifranti |
| 9 | **Sistem** | `/sistem` | uporabniki, vloge, integracije, alarmi, dnevnik dejavnosti, zdravje |

Pravila, ki jih ta IA uveljavlja:

- **Vse poti so slovenske in enonivojske do skupine.** `/izdelki/{id}`, `/kakovost/karantena`.
  Nobene `/stg/`, `/export/`, `/ingestion/`.
- **Ena entiteta = ena stran.** Statusi (v pripravi, z napako, v karanteni, objavljen) so
  **shranjeni pogledi** iste mreže izdelkov, ne ločene strani.
- **Vsako dejanje se zgodi tam, kjer je predmet.** Pošiljanje v SAOP je dejanje nad izbiro v
  seznamu izdelkov; `/erp` je samo pregled poslanega.
- **Vsaka stran ima natanko en vir podatkov** (ena `intranet.*` procedura) in nobenega
  vgrajenega SQL-a v Razorju.

---

## 6. Funkcionalne vrzeli — kaj baza podpira in kaj je treba dodati

| Modul | Vir danes | Manjka |
|---|---|---|
| Izdelki — seznam | `intranet.GetProducts` (iskanje, status, paginacija) | filtri po proizvajalcu, dobavitelju, kategoriji, viru, popolnosti, sliki; izbira stolpcev; `TotalCount` po zavihkih |
| Izdelki — kartica | `intranet.GetProductDetail` (profili) | besedila po jezikih, lastnosti, kategorije, mediji, cene, zaloga, trgovinski podatki, lastništvo polj, **zapisovalna pot** |
| Izdelki — množično | `pim.ProductChangeBatch`, `UndoProductBatch` | procedura za množično spremembo polja nad izbiro + predogled učinka |
| Zgodovina | `pim.GetProductHistory` | prikaz in gumb »razveljavi« |
| Kakovost | `intranet.GetValidationIssues` | razčlenitev po `Severity`/`BlocksErp`/`BlocksWeb` (migracija 047 to že ima) |
| Karantena | `intranet.GetRawQuarantine` | urejanje in revalidacija iz vmesnika |
| Zajem | `intranet.GetPipelineRuns` | števci `raw.Inbox` po stanju in končni točki, `map.UnmappedValue`, `map.MissingTranslation`, `map.MissingCategoryMap`, ročni zagon preslikave |
| Objava | `out.ExportProfile` / `out.ExportColumn` | read model za profil, predogled vrstic, zgodovina izvozov, prenos datoteke |
| Odhodna pošta | `intranet.GetOutboundMessages`, `GetOutboundMessage` | odobritev/ponovno pošiljanje iz UI (procedure `out.ApproveMessage`, `RetryMessage`, `CancelMessage` že obstajajo), pregled `out.SaopItemAssignment` |
| Zaloge | `intranet.GetStocks` | agregat po skladišču, `stock.UnmatchedPosition`, dobavni roki |
| Cene | — | read model nad `canon.ProductPrice` + ceniki |
| Stranke | `intranet.GetCustomers`, `GetCustomerDetail`, popusti | zapisovalna pot v SAOP prek outboxa |
| Partnerji | — | dobavitelji iz `canon.Product.Supplier` + register konektorjev |
| Nastavitve | — | atributi, kategorijsko drevo, preslikave (`map.FieldMapping`, `map.ValueLookup`, `map.CategoryPathMap`), kanali (`canon.WebSite`), jeziki (`canon.Language`), profili (`val.*`) |
| Sistem | `intranet.GetSystemIntegrations`, uporabniki | vloge in pravice, dnevnik dejavnosti, `ops.Alert` iz UI |

Vzorec je jasen: **branje večinoma obstaja, zapisovanje skoraj nikjer.** Vsak zapisovalni
tok mora iti čez proceduro in čez outbox — nikoli neposredno iz Blazorja v tabelo.

---

## 7. Tehnični načrt

### 6.1 Način izrisa

- **Seznami: statični SSR + streaming rendering.** Stanje seznama (iskanje, filtri, stran,
  razvrstitev) živi v **query stringu**, ne v komponenti. Prednosti: povezava je deljiva,
  brskalnikov »nazaj« dela, ni SignalR prometa za branje, prvi izris je takojšen.
- **Urejevalniki in mreža z izbiro: `@rendermode InteractiveServer`** na ravni strani.
  Odpravi B1 in ostane omejeno na strani, ki interaktivnost res potrebujejo.
- Nikjer WebAssembly — baza je lokalna, podatki so občutljivi, promet ostane na strežniku.

### 6.2 Podatkovni sloj

```
src/PIM.Intranet/Data/
  PimDatabase.cs            povezava, izvedba, preslikava po imenu stolpca (GetOrdinal)
  Products/…                en modul = ena mapa = en niz zapisov + ena storitev
  Quality/… Ingest/… Outbound/… Stock/… Pricing/… Customers/… Settings/… System/…
```

Pravila: vsaka poizvedba je klic `intranet.*` procedure; nobenega SQL-a v `.razor`;
vsak seznam vrne `(vrstice, TotalCount)`; šifranti (jeziki, kanali, kategorije, skladišča)
gredo v `IMemoryCache` z razveljavitvijo ob spremembi.

### 6.3 Komponentna knjižnica (naredi enkrat, uporabi povsod)

`PimPage` (glava, drobtine, dejanja) · `PimTabs` (zavihki s števci) · `PimToolbar`
(iskanje + filtri + pogled + stolpci + izvoz) · `PimFilterChips` (aktivni filtri z ✕) ·
`PimDataGrid<T>` (strežniška paginacija, izbira, razvrstitev, izbira stolpcev, `Virtualize`
za dolge nabore) · `PimStatusChip` · `PimCompleteness` · `PimOwnerBadge` (PIM/SAOP/SHARED) ·
`PimDrawer` (stranski predal za podrobnost brez izgube seznama) · `PimEmptyState` ·
`PimSkeleton` · `PimIcon` (inline SVG sprite, brez ikonske knjižnice).

Te komponente so razlika med »lepo« in »razmetano«: 61 strani stare aplikacije je imelo 61
tabel, mi imamo eno.

### 6.4 Vizualni sistem

- **Odstranimo Bootstrap.** En `app.css` z žetoni (`--pim-*`: barve, razmiki, radiji, sence,
  tipografija) + `.razor.css` za komponentne posebnosti.
- Paleta in postavitev iz potrjenih slik: temna navigacija ~200 px, svetla površina `#f6f8fb`,
  bela zgornja vrstica, oranžna značka PIM kot edini poudarek, modra za dejanja, zelena/rumena/rdeča
  samo za status.
- Goste tabele (vrstica ~40 px), kartice z 1 px robom in minimalno senco, statusni čipi,
  napredek popolnosti kot tanka črta z odstotkom.
- Temna tema **ni** v tem obsegu; žetoni jo pozneje omogočijo brez prepisa.

### 6.5 Optimizacija (merljivo, ne na občutek)

1. Filtriranje, razvrščanje in `COUNT_BIG` **v isti proceduri** — nikoli `WHERE` v C#.
2. `Virtualize` za sezname nad 200 vrsticami, privzeta stran 25/50.
3. Šifranti v `IMemoryCache`; kategorijsko drevo se naloži enkrat na sejo.
4. Brez ORM in brez `SELECT *`; `SqlDataReader` z `GetOrdinal` preslikavo.
5. Vsaka nova poizvedba nad `canon.Product` ali `stock.Position` dobi svoj indeks v migraciji
   (kot 071 in 079) — merjeno s `SET STATISTICS IO/TIME`, zapisano v poročilo.
6. Cilj: seznam izdelkov s filtri nad 196.515 artikli pod **300 ms** strežniško.

### 6.6 Dostopnost in jezik

Vsa vidna besedila v slovenščini, `lang="sl"`, oznake za vsak vnos, `caption` za vsako tabelo,
`aria-live` za rezultate filtrov, fokus viden, celotna mreža uporabna s tipkovnico.
Ta pravila že veljajo v obstoječih testih F10 — ohranimo jih.


### 7.7 IIS je ciljno okolje, ne le lokalni Kestrel

Aplikacija tece na IIS, pogosto kot virtualna aplikacija pod `/PIM`, in mora tam izgledati
enako kot lokalno. Iz tega sledijo stiri trde zahteve, ki veljajo za vsako novo stran:

1. **Nobene korensko-absolutne povezave.** `href="/izdelki"` pod `/PIM` pristane na korenu
   streznika. Vse povezave so base-relativne (`href="izdelki"`), `<base href>` pa se racuna iz
   `NavigationManager.BaseUri`. Ta napaka je ta projekt ze enkrat stala zavrnjen posnetek.
2. **Objava je `--self-contained`.** Runtime potuje z aplikacijo, zato prehod na .NET 10 ne
   zahteva posega na strezniku; IIS potrebuje samo modul `AspNetCoreModuleV2`, ki je ze tam.
3. **WebSockets.** Interaktivne strani gredo prek SignalR. Ce IIS nima vklopljenih WebSocketov,
   se povezava tiho degradira na dolgo pooling in vmesnik je opazno pocasnejsi.
4. **Antiforgery obrazci zahtevajo staticni SSR.** Zato prijava in odjava ostajata navadna
   obrazca; preklop navigacije je izveden s CSS, ne z JavaScriptom.

Dokaz, ki ga je treba ponoviti ob vsaki vecji spremembi lupine: isti binarni izvod odgovori
`200 text/css` na `/app.css` in na `/PIM/app.css`, `<base href>` pa se prilagodi obema.

---

## 8. Vrstni red dela

Vsaka faza je en commit na svoji veji, z dokazom `scripts\run_tests.ps1` (izhod 0) in
posnetkom prijavljene strani.

| Faza | Vsebina | Dokaz |
|---|---|---|
| **I0 — Temelji** | **retarget vseh 16 projektov na `net10.0`**, odprava B1 (rendermode), odstranitev Bootstrapa in mrtvih strani, žetoni CSS, komponentna knjižnica, lupina brez globalnega konteksta, odločitev o navigaciji (baza ali koda) | `dotnet --version` → 10.x, build 0/0, `scripts\run_tests.ps1` izhod 0, F10 PASS, stran se odziva na klik |
| **I1 — Izdelki, branje** | nova procedura za iskanje s polnimi filtri in `TotalCount`, mreža s shranjenimi pogledi, kartica izdelka z zavihki (pregled, besedila, lastnosti, kategorije, mediji, cene, zaloga, ERP, zgodovina) | seznam pod 300 ms, kartica prikaže vseh 8 zavihkov iz baze |
| **I2 — Kakovost** | pregled po profilih z resnostjo in obsegom blokade, napake, karantena z urejanjem in revalidacijo | števci se ujemajo z `val.*` |
| **I3 — Izdelki, pisanje** | zapisovalna pot za polja v lasti PIM, značke lastnika, zgodovina in razveljavitev, množična obdelava s paketom | sprememba je v `pim.ProductFieldHistory`, razveljavitev jo vrne |
| **I4 — Odhodna pošta (ERP)** | štiri manjkajoče stvari iz §4.7 (klic `out.VerifyEcho` iz preslikave, zapisovalne končne točke v register, ciljno delta branje brez premika mejnika, zapisovalna pot in prekrivka v UI), nato vrsta za odobritev, odmiki, ponovni poskusi, dodelitev šifer | prvo sporočilo skozi `out.OutboxMessage` od `PendingApproval` do `Verified`; namerno napačna vrednost konča v `Drift`, ne tiho |
| **I5 — Zajem** | viri, teki, čakajoče strani, neujemanja, ročni uvoz | 294 čakajočih strani `raw.Inbox` je vidnih in obdelanih iz UI |
| **I6 — Objava** | izvozni profili, predogled, zgodovina, prenos | Magento CSV iz UI je enak datoteki iz workerja |
| **I7 — Poslovni podatki** | zaloge, cene, stranke, partnerji | vsak seznam ima strežniško paginacijo |
| **I8 — Nastavitve in sistem** | atributi, kategorije, preslikave, kanali, jeziki, profili validacije, uporabniki, vloge, dnevnik | nov spletni kanal je dodan brez spremembe kode |

I0–I2 dajo uporabno aplikacijo za urednika kataloga. I3–I4 sta srce razlike od Akeneo.

---

## 9. Odločitve

### Sprejeto 2026-08-23

- **Ciljni framework: `net10.0`**, retarget v fazi I0. Razlog v §2.3 B2. Ob retargetu je treba
  posodobiti tudi `AGENTS.md` §2, ki trdi .NET 9. Opomba za namestitev: aplikacija, prevedena
  za `net8.0`, se **ne zažene sama** na strežniku, kjer je le runtime 10 — privzeti
  `rollForward` je `Minor` in ne skoči čez glavno verzijo. Po retargetu to vprašanje odpade.
- **Model zapisa nazaj v SAOP:** prekrivka nad kanonično vrednostjo z echo potrditvijo, brez
  dvojnega vpisa. Celoten model in zavrnjeni možnosti v §4.

### Še odprto

1. **Navigacija:** katalog v kodi (kot v starem, pregledno, zahteva build) ali v bazi
   (`sec.Navigation*`, spremenljivo brez builda)? Priporočam **kodo** — navigacija je del
   izdelka, ne konfiguracija, in v bazi je danes le 6 postavk.
2. **Slovenske poti** (`/izdelki`, `/kakovost`) — potrjeno? Obstoječe strani jih že uporabljajo,
   stara aplikacija pa je bila angleška.
3. **Obseg prve dostave:** ali gremo I0–I2 (uporaben katalog) in šele nato pisanje, ali je
   zapis nazaj v SAOP tako nujen, da I3–I4 prestavimo naprej?
4. **Mediji:** `canon.ProductMedia` hrani samo `Url`, `Role`, `SortOrder` — ni datotečnega
   skladišča. Ali je modul »Mediji« pregled povezav (izvedljivo takoj) ali pravo upravljanje
   datotek (potrebuje nov podatkovni model in shrambo)?

---

## 10. Kaj ta načrt namenoma ne obljublja

- Nobenega prikaza podatka, ki nima vira v bazi — pravilo iz `UX\README.md` ostane.
- Nobene kontrole, ki bi videti shranjevala, če zapisovalna pot ne obstaja.
- Nobenega prepisa stare kode: iz `PIM_test` prevzemamo **seznam funkcionalnosti in IA**,
  ne datotek.


---

## 11. Izvedba I0 — stanje 2026-08-23

### Narejeno in dokazano

| Tocka I0 | Stanje | Dokaz |
|---|---|---|
| Retarget na `net10.0` | narejeno | 68 `.csproj`, build 0/0; commit `e649cc2` |
| B1 — `@rendermode InteractiveServer` | narejeno | 12 strani; postavitev ostaja staticni SSR zaradi antiforgery |
| Preklop navigacije brez JS | narejeno | skrito potrditveno polje + oznaka; `menu-glyph-icon` ohranjen |
| Odstranitev Bootstrapa | narejeno v kodi | povezava iz `App.razor` in ostanki iz `app.css`; datoteki v `wwwroot/bootstrap` cakata na dovoljenje za brisanje |
| Zetoni CSS | narejeno | `--pim-*` v `app.css`, vrednosti nespremenjene |
| Globalni kontekst organizacija/kanal/jezik | odstranjen 2026-08-26 | lupina nima izbirnikov ali POST poti `/kontekst`; organizacijski in kanalski filtri sodijo na konkretno stran |
| Zvonec opozoril | narejeno | dejansko stevilo nerazresenih `ops.Alert` |
| IIS pot | preverjeno | `/app.css` in `/PIM/app.css` oba `200 text/css`; `<base href>` se prilagodi |
| Vseh 10 F10 pogodbenih testov | PASS | zagnani posamicno |

### Ustavljeno in zakaj

**Komponentna knjizica (tocka I0.6) ni izvedena.** Devet UX pogodbenih testov preverja
**dobesedno oznako v izvorni datoteki strani**, ne izrisanega rezultata — na primer
`Regex.IsMatch(markup, "<h1>Izdelki</h1>")` nad `Products.razor`. Vsaka zamenjava te oznake s
komponento (`<PimPageHeader Title="Izdelki" />`) tak test podre, tudi ce je izrisani HTML
identicen.

Po `AGENTS.md` par. 5.3 testa ne smem spremeniti zato, da bi sel skozi. Testi niso napacni
glede dostopnosti — pinajo pa izvedbo strani, ki jih nacrt namerno prenavlja. To je odlocitev
za cloveka, ne zame:

- **Moznost A:** testi se ob I1 zavestno posodobijo tako, da preverjajo **izrisani** HTML
  (prek komponente), ne izvorne oznake strani. Vsebina zahtev (ARIA, `caption`, `scope`,
  `:focus-visible`, prepoved Unicode ikon) ostane ista.
- **Moznost B:** komponentne knjizice ni; vsaka stran ostane svoja oznaka. To pomeni, da
  ostane tudi vzrok, zaradi katerega je bila stara aplikacija razmetana.

Priporocam **A**, izvedeno kot loceno, izrecno odobreno opravilo na zacetku I1.

**Navigacija ostaja v bazi in nespremenjena.** Odlocitev iz par. 9 se ni sprejeta, poleg tega
je `sec.NavigationItem` v tuji domeni (BAZA) in bi zahteval novo migracijo v trenutku, ko na
isti veji nastajajo migracije `080`–`087`. Posledica ostaja: v meniju je 6 postavk, strani
`stranke`, `zaloge`, `outbound`, `pravila-popustov`, `system/*` pa so dosegljive samo prek
naslova.

### Opozorilo o soocasnem delu

Med to sejo je na isti veji in v istem delovnem drevesu delal se en agent (migracije
`080`–`087`, `PIM.Outbound`, `PIM.SaopXmlPreview`). Posledice, ki jih je treba vedeti:

- Commit `d261014` z opisom o odhodni poti **vsebuje tudi vseh 22 datotek intranetne faze I0**.
  Vsebina je cela, sporocilo commita pa je zavajajoce. Tuje zgodovine nisem prepisoval.
- `PIM.F3.Integration` pade zaradi migracije `082`, ki je `GetItemsPlanningData` dala aktivno
  preslikavo, test pa trdi, da je ta entiteta nepreslikana. Ni posledica intraneta.
- Polnega `scripts/run_tests.ps1` ni bilo mogoce dokoncati, ker se `tools/PIM.SaopXmlPreview`
  v tujem vmesnem stanju ne prevede.

---

## 12. Nadaljevanje izvedbe — 2026-08-24

Prekinjeni I0 sklop je nadaljevan brez spremembe obstoječih UX testov:

- `PimPage`, `PimTable`, `PimState`, `PimPager`, `PimChip`, `PimBar`, `PimStat` in
  `PimHubCard` so skupni gradniki novih strani. Stare pogodbeno pinane strani za zdaj ostajajo
  v svoji oznaki; zato F10 preverja isto dostopnostno pogodbo kot prej.
- Navigacijska resnica je `PimNavigation` v kodi, kot je priporočeno v §9. Katalog upošteva
  vloge, uporablja base-relativne poti in nobena menijska postavka več ne vodi na 404.
- Dodani so bralni pogledi za medije, partnerje, cene, kakovost, zajem, izvozne profile,
  nastavitve kataloga, validacijska pravila, slovar, preslikave, sistemske napake in vloge.
  Stare poti kakovosti, tekov in `system/*` ostajajo kot združljivi aliasi.
- Novi pogledi nastavitev so namenoma brez zapisovalnih gumbov. Zapisovalne procedure in
  revizijska sled zanje še ne obstajajo, zato bi bil gumb navidezna funkcionalnost.

Dokaz tega sklopa: ciljni F10 paket 10/0/0, build intraneta 0 opozoril/0 napak, avtomatski
pregled navigacijskih poti izhod 0 in bralni SQL smoke-test proti lokalni bazi `PIM` izhod 0.

Naslednja tehnična meja: bralne SQL poizvedbe iz `CatalogReadService`, `PipelineReadService`
in `GovernanceReadService` je treba v ločenem zaporedju BAZA → INTRANET preseliti v
`intranet.*` procedure. Ta commit ne meša ozemlja BAZA v intranetno izvedbo.

---

## 13. Vizualna združitev z referenco `src_navigation_ux_v2` — 2026-08-24

Referenca je vizualni vir, ne nova kodna osnova. Njeni CSS žetoni in razmerja so preslikani
na obstoječe razrede NoviPIM; Razor strani, `PimNavigation`, poti, vloge in podatkovni dostop
se niso kopirali ali zamenjali.

### Kaj vzamemo iz katere aplikacije

| Področje | Iz reference v2 | Iz NoviPIM | Ciljna združitev |
|---|---|---|---|
| Vizualni sistem | podlaga `#f4f6f9`, bele površine, meja `#e5e7eb`, indigo `#4f46e5`, oranžna identiteta, 12-px kartice in mehke sence | enotni `--pim-*` žetoni brez Bootstrapa | referenčne vrednosti ostanejo na enem mestu v `app.css`; strani ne zakodirajo svojih primarnih barv |
| Lupina | 18-rem temna skrilasta stranska vrstica in zračna vsebina | zgornja vrstica z dejansko organizacijo, kanalom, jezikom, opozorili in uporabnikom | referenčni sidebar + obstoječi funkcionalni topbar; mobilni preklop ostane CSS/SSR |
| Navigacija | jasna aktivna kartica z oranžno črto, večji cilji klika, opisna hierarhija in puščice pri razdelilnih straneh | `PimNavigation` v kodi, filtriranje po vlogah, slovenske base-relativne poti in nič mrtvih povezav | struktura ostane NoviPIM, vizualna stanja so iz reference; `NavLink` se zaradi CSS isolation slogi prek `::deep`; spletnega konteksta »Svetila.si« ne prenesemo |
| Kartice in tabele | dobra gostota, lepljive glave, statusne značke, prazna stanja in hover | dostopni `caption`/`scope`, resnični podatki, strežniška paginacija ter `PimTable`, `PimState`, `PimChip`, `PimBar` | referenčni izgled na skupnih komponentah; posamezne strani ne podvajajo osnovnih pravil |
| Obrazci in filtri | jasne orodne vrstice, aktivni filtri, zavihki, meniji in vidna hierarhija dejanj | dejanski servisni filtri, antiforgery, avtorizacija in brez navideznih zapisovalnih gumbov | interakcijske vzorce dodajamo stran po stran šele, ko obstaja prava podatkovna/zapisovalna pogodba |
| Mobilno in dostopnost | 900-px mobilni sidebar, dovolj veliki cilji in pomične tabele | viden `:focus-visible`, slovenska stanja, ARIA pogodbe in F10 testi | ohranimo oboje; vizualni odzivni pregled dopolni avtomatske pogodbe |

### Česa iz reference ne prenesemo

- 1.680-vrstične globalne datoteke z več hkratnimi generacijami navigacije (`rail`, `subnav`
  in `sidebar`) ter podvojenimi selektorji;
- Bootstrapa in njegovih razredov, ker ima NoviPIM manjšo lastno komponentno plast;
- zunanjega Google Fonts klica; intranet mora delovati brez dostopa do interneta, zato ostane
  sistemski sklad z `Inter` samo kot lokalno razpoložljivo prvo izbiro;
- slogovnih blokov znotraj posameznih `.razor` strani in poslovnih vrednosti v CSS/HTML;
- strani, SQL-a, servisov, navigacijskega kataloga ali konfiguracije iz referenčnega projekta.

### Predlagani vrstni red strani

1. **Nadzorna plošča:** referenčni ritem KPI in kartic, podatki ter dovoljenja NoviPIM.
2. **Izdelki:** referenčna orodna vrstica, hitri filtri in gostota; obstoječe strežniško
   iskanje, izbor in paginacija.
3. **Kartica izdelka:** referenčni hero, domenski zavihki in galerija; kanonični podatki,
   lastništvo polj, zgodovina in validacija NoviPIM.
4. **Kakovost in karantena:** referenčni delovni seznam in statusni filtri; `val.*` kot edini
   vir resnice ter zapisovanje šele prek revizijsko sledljive procedure.
5. **Zajem, izvozi in poslovni moduli:** enaki skupni gradniki, vendar vsaka stran šele po
   potrditvi svojega bralnega in zapisovalnega kontrakta.

Prvi CSS korak je že izveden brez spremembe označbe strani: barvni žetoni, lupina,
navigacijska stanja, skupne kartice/tabele/obrazci, prijava in mobilna prelomnica sledijo
referenci. Nadaljnje spremembe so namerno stran-po-stran, da se vizualna prenova ne zamenja
za nekritično kopiranje stare aplikacije. Navigacijski korak je dokončan tudi na ravni
izoliranega CSS: povezave niso več privzeto modre/podčrtane, aktivna pot ima referenčno
kartico in oranžen poudarek, pomembne postavke imajo opis in razdelilne strani puščico.

---

## 14. Izvedba modula Vhodni podatki — 2026-08-24

Odločitev po pregledu prvotnega predloga z dvanajstimi stranmi je izvedena: v stranskem
meniju ostane en cilj, modul pa ima pet jasnih pogledov **Pregled, Viri, Teki, Težave in
Preslikave**. Čakalna vrsta, posamezen vir, posamezen tek, posamezna težava in neujemanja so
podrobnosti iz teh pogledov, ne dodatne enakovredne menijske postavke.

Pregled združuje vseh pet dejanskih vhodnih poti: SAOP katalog, dobaviteljev XML, SAOP
zalogo, dobaviteljevo zalogo in delovni zvezek. `ops.PipelineRun` in `stock.SyncRun` nista
ista sledilna modela, zato sta združena samo v bralnem servisu. Zadnji poskus in zadnji uspeh
sta ločena stolpca; star uspeh ne sme skriti novega padca. Zdravje zajema zaloge je v tem
modulu, poslovno stanje količin pa ostane na strani Zaloga.

Pogled Težave združi samo operativne težave vhodov: čakajoče in karantenske strani,
zavrnjene zalogovne pozicije, mrtva pisma registriranih vhodnih konektorjev in napake z
dejanskim `PipelineRun`. Vsebinske odločitve — neznane vrednosti, kategorije in prevodi — so
ločene v Preslikave. Podrobnosti vsebujejo omejeno tehnično diagnostiko samo za `ADMIN`;
neadministratorska neposredna pot je omejena na aktivno organizacijo. Ker `sec.Role` danes
pozna samo `ADMIN`, `CATALOG_EDITOR`, `COMMERCIAL` in `VIEWER`, izvedba ne izumlja vlog
»operater integracij« ali »tehnična podpora«.

Prva dostava je namenoma bralna. Za ponovni zagon, upload, popravljanje prevoda ali
preslikavo kategorije ni gumba, dokler ne obstajata zapisovalna procedura in revizijska
sled. Znana tehnična vrzel je zalogovni writer: nepričakovana napaka povrne transakcijo,
zato neuspešen `stock.SyncRun` ni trajno zapisan. UI tega ne ponareja; pokaže zadnji uspeh,
svežino in dejansko zavrnjene pozicije. Zaprtje te vrzeli zahteva ločeno spremembo zapisa
workerja, ne kozmetičnega gumba v intranetu.

Dokazi izvedbe: parametrizirane SQL poizvedbe za vseh osem glavnih in pomožnih bralnih
pogledov ter štiri vrste podrobnosti so bile izvedene proti lokalni razvojni bazi `PIM` z
izhodom 0; `PIM.Migrator --verify` potrdi F0–F10; ciljni F10 paket ostaja 10/0/0.
