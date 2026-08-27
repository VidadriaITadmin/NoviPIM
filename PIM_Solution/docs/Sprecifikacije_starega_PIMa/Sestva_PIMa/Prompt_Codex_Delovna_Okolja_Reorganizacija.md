# Prompt za Codex — dopolnitev delovnih okolij v PIM.Intranet

> Ta dokument je pripravljen kot **samostojen prompt**, ki ga prilepiš Codexu (ali drugemu
> agentu) v tem repozitoriju. Ne predpostavlja nobenega predhodnega pogovora — vse potrebno
> ozadje je spodaj. Piši v slovenščini, komentarje v kodi minimalno (samo kjer WHY ni očiten).

---

## 0. Obvezno branje pred začetkom

1. [`CLAUDE.md`](../../CLAUDE.md) — arhitekturna pravila projekta (5 pravil, glej §2 spodaj).
2. [`_SPEC/PIM_SISTEM_MENI_Master_Specifikacija.txt`](../../_SPEC/PIM_SISTEM_MENI_Master_Specifikacija.txt) — enotna referenca sistema.
3. `src/Services/PimNavigationCatalog.cs` — **vir resnice za meni**. Aplikacija ŽE IMA 13-področno
   informacijsko arhitekturo (Pregled/Izdelki/Mediji/Stranke/Partnerji/Zaloga/Cene/Kakovost/
   Uvozi/Izvozi/Nastavitve/Pravila/Sistem). Ne izumljaj nove IA — dopolnjuj obstoječo.
4. Ta dokument **ne** predlaga rušenja obstoječega. Precej od spodaj opisanega že obstaja in
   deluje — nalogo razdeli na "**že obstaja, samo preveri/poveži**" in "**manjka, zgradi**".
   Pred vsakim sklopom najprej **poglej dejansko stanje kode**, ne zaupaj samo temu dokumentu
   (nastal je iz analize 27. 8. 2026 — koda se je lahko premaknila).

## 1. Kontekst — kaj je PIM.Intranet

ASP.NET Core Blazor Server aplikacija (`src/`, projekt PIM.Intranet) nad SQL Server bazo
`PIM_test` (testno okolje `DAVID\MSSQL19`, produkcija `IQ-SAOP\SQL01` — **isto ime baze, različen
strežnik**). Podatki prihajajo iz ERP-ja SAOP (prek Windows servisov v `Windows_services/`,
gitignored) v plasteh `raw` → `stg` → `pim`. Uporabnik (David) SQL skripte poganja **sam** —
Claude/Codex SQL nikoli ne izvaja neposredno na bazi, samo piše skripte v `sql/` oz.
`sql/migrations/` (glej §2.6).

## 2. Trdna pravila (kršitev = napačna implementacija)

1. **En vir resnice za validacijo** — pravila živijo v šifrantih (`pim.ValidationRuleLookup`,
   `pim.ValidationProfile`), ne trdo kodirana v proceduri. Validacija je **issue-driven**:
   status izhaja iz odprtih vrstic `pim.ProductValidationIssue`, nikoli ročno kopiran flag.
2. **Ločeni kanali**: ERP (SLO/EU/THIRD) | Komerciala | Splet (po spletni strani) so neodvisni
   validacijski nivoji (`ValidationLayer`). Cene in zaloga **NISO** validacijski nivo — glej §4.
3. **STG je prehod, ne shramba.** Nikoli ne grade nove trajne funkcionalnosti na `stg` kot na
   "bazo resnice" — bralni modeli za UI so dovoljeni (npr. cene trenutno berejo `stg` iz
   utemeljenega razloga, glej `docs/specifikacije/Nacrt_Cene_In_Ceniki.md`), a pisanje uporabnika
   nikoli ne sme končati samo v STG brez poti naprej.
4. **`OrganizationId` povsod** — vsaka nova tabela, pogled, poizvedba.
5. **Zaloga je samo za branje.** `docs/PIM_Ciljna_Arhitektura_2026-07.md` §7.5 to **namerno**
   izključuje. Edino polje, ki se piše nazaj, je `ItemExcludeQtyReservation` (zastavica, ne
   količina). **Nikoli ne dodajaj pisanja količin nazaj v SAOP.**
6. **Migracije**: nove SQL spremembe gredo v `sql/migrations/` (format glej obstoječe datoteke),
   poganja jih `Invoke-PimMigrations.ps1` (ne `USE` stavkov, checksum zaklene datoteko po
   namestitvi). Vedno preveri `-WhatIf` najprej. `.ps1` datoteke pišeš kot čist ASCII + UTF-8 BOM
   (PowerShell 5.1 past — brez BOM se šumniki/pomišljaji sesujejo v razčlenjevanju).
7. **Ne dodajaj odvečnih možnosti v vmesnik.** En koncept = eno mesto. Ne dodajaj filtrov,
   gumbov ali stolpcev, ki jih nihče ni zahteval "za vsak slučaj" — nejasnost je slabša od
   manjkajoče funkcije.
8. **Besedilno ujemanje (šumniki)**: privzeta kolacija baze (`Slovenian_CI_AI` ipd.) **ne** druži
   č/š/ž kot iste črke pri toleratnem iskanju — če rabiš ohlapno ujemanje po nazivu, uporabi
   `COLLATE Latin1_General_CI_AI` eksplicitno.
9. **Zastavice v bazi so `D`/`N`, ne `Y`/`N`** (SAOP konvencija) — velja za `IsActive`,
   objavljeno-na-spletu ipd.

## 3. Trenutno stanje navigacije (da ne podvajaš)

Meni ima danes (`PimNavigationCatalog.cs`) te skupine in strani — **preveri v kodi, ker se to
hitro spreminja**:

- **Izdelki** (`/products`) — Magento-slog seznam s statusnimi zavihki (Vsi/V pripravi/Veljavni/
  Arhivirani) + značke popolnosti (brez slike, brez kategorije …). Detajl artikla:
  `/products/detail` in urejevalnik `/stg/product` z zavihki po viru podatka.
- **Mediji** (`/media`, `/media/assets`, `/media/missing`, `/media/quarantine`,
  `/media/imports`, `/media/settings`) — **že zgrajeno** (shema `media`, 12 tabel, migracije
  1100-1105). Glej §7.
- **Stranke** (`/customers`) + **Partnerji** (`/partners/suppliers`, `/partners/manufacturers`).
- **Zaloga** (`/stock/overview`, `/stock/delivery`, `/stock/issues`) — bralni model
  `pim.vw_StockUnified` / `pim.ProductStock`.
- **Cene in ceniki** (`/prices/products`, `/prices/lists`, `/prices/special`) — bralni model
  bere `stg.ProductPrice` (razlog v `docs/specifikacije/Nacrt_Cene_In_Ceniki.md`).
- **Kakovost** (`/quality/health`, `/quality/issues`, `/quality/categories`,
  `/quality/quarantine`) — to je **validacija** (issue-driven, gl. pravilo #1).
- **Izvozi** (`/exports/saop` hub → `/export/saop-item-new|edit|bulk|queue`,
  `/export/saop-outbound` (vsi kanali), `/export/planning-exclude`; `/exports/web`).
- **Nastavitve kataloga** (`/settings/attributes`, `/settings/categories`,
  `/settings/product-links`, `/settings/mappings/attributes`, `/settings/mappings/categories`,
  `/settings/channels`, `/settings/languages`, `/settings/references`).
- **Pravila** (`/rules/validation`, `/rules/web`, `/rules/b2b`, `/rules/sources`).
- **Sistem** (status/uporabniki/vloge/integracije/audit/tehnični zemljevid).

Skupna UI konvencija za vse nove strani: `<PageHeader Title=".." Subtitle="..">` +
`<Breadcrumbs><PimBreadcrumbNav Items="@_crumbs" /></Breadcrumbs>` na vrhu, filtri v
`<PimSectionCard>` ali `.pim-filter-panel`/`.pim-filter-panel-grid`, KPI kartice kot
`.pim-stat-card` (variante `--success/--danger/--warning/--info`), akcijske bližnjice kot
`<QuickActionCard Href=".." Title=".." Description=".." AccentClass="pim-quick-card--.." />`,
nedokončane funkcije kot `<UiPlaceholder Title=".." Subtitle=".." Features="@[]" Needs="@[]" />`.
`@rendermode InteractiveServer` na straneh z interakcijo. Vse nove poti dodaj v
`PimNavigationCatalog.cs`, preveri z `dotnet build src` da je vsak `@page` unikaten.

---

## 4. Okolje A — Izdelki + napake (ERP / Komerciala / Splet)

**Stanje: v veliki meri ŽE ZGRAJENO.** Preveri, ne gradi na novo:
- `Products.razor` (`/products`) — glavni seznam.
- `ProductDetail.razor` / `ProductCatalogEditorSections.razor` — osebna izkaznica artiklov z
  ločenimi zavihki po `ValidationLayer` (ERP SLO/EU/THIRD, Komerciala, Splet — slednji je
  per-spletna-stran, glej `pim.WebSiteChannel` in `stg.ProductWebValidation.WebSiteId`).
- `/quality/issues` (`QualityIssues.razor`) — **skupen seznam vseh odprtih napak** z filtrom
  `Kanal` (ERP/Komerciala/Splet), organizacijo, pravilom, resnostjo. To je pravzaprav TOČNO
  funkcija, ki jo uporabnik opisuje kot "izdelki, potem vse napake izdelka — ERP, komercialne,
  splet napake".

**Naloga v tem sklopu (če kaj manjka):**
1. Preveri, da `/quality/issues` in zavihki na `ProductDetail` kažejo **isti vir resnice**
   (`pim.ProductValidationIssue`) in se ne razhajata (npr. filter "Kanal" na `/quality/issues`
   mora ustrezati istim trem vrednostim kot zavihki na artiklu).
2. Na `/quality/health` (»Kaj manjka«) preveri, da obstaja povzetek po kanalu (koliko izdelkov
   ima ERP napako, koliko komercialno, koliko spletno) — če ne obstaja, dodaj KPI vrstico
   (`.pim-stat-card` × 3, en na kanal) nad obstoječo vsebino.
3. **Ne** dodajaj cen/zaloge v ta issue-driven model (glej pravilo §2.1) — to gre v okolje B.

---

## 5. Okolje B — Cene in Zaloga kot PREVERBE (ne validacija)

To je **glavna nova zahteva** iz pogovora s Kolegom (Luka): *"bolj bi rabil neki čeking b2b
cena / prevzemna cena, da bi vidu, če mamo kje napake, in bi nam to javljalo … kje so cene, kje
niso, in pa zaloge, kje so in kje niso, pa tudi kakšen min/max, kdaj bodo prišle"*.

**Ključna konceptualna razlika od okolja A:** to NISO blokirajoča validacijska pravila iz
`pim.ValidationRuleLookup` (artikel zaradi manjkajoče cene ne sme postati "INVALID" ali oditi v
karanteno) — so **opozorila/preverbe**, informativen sloj nad cenami in zalogo. Ne mešaj ju v
isto tabelo/proceduro kot §4.

### 5.1 Kaj že obstaja (razširi, ne podvajaj)

- `/prices/products` (`PricesProducts.razor`) — že ima filter "Stanje cene" z vrednostmi:
  Brez cene, Brez DDV, Cena = 0, Poteče/potekla. **To je že preverba, samo skrita v filtru.**
- `/stock/overview` (`StockOverview.razor`) — že ima KPI kartice: Na zalogi, Brez zaloge
  (+ "od tega X s prihajajočo dobavo"), V prihodu, Zastarel podatek.
- `/stock/delivery`, `/stock/issues` — dobavni roki in znane težave.
- `pim.PriceListPolicy`, znane pasti podvojenega zrna cen (RC3) in izgube DDV-kljukice (RC4) —
  glej `docs/specifikacije/Nacrt_Cene_In_Ceniki.md` §"Tokokrog cen".

### 5.2 Kaj zgraditi — enotna stran "Cene in zaloga — opozorila"

Nova stran, npr. `/prices/checks` (ali `/quality/prices-stock` če jo želiš pod Kakovost kot
ločen, nevalidacijski zavihek — **odloči se za eno mesto in dodaj vanj, ne za oboje**), ki
združi cenovna in zalogovna opozorila v en pregled, ker ju uporabnik uporablja skupaj (nabavna
cena vs. prodajna cena je smiselna samo skupaj z razpoložljivostjo).

**Postavitev strani (od zgoraj navzdol):**
1. `PageHeader` + `PimBreadcrumbNav`.
2. Vrstica KPI kartic (`.pim-stat-card`), npr.: Brez B2C cene · Brez B2B cene · Marža pod pragom
   (glej 5.3) · Podvojen zapis cene (RC3 opozorilo) · Brez zaloge in brez prihoda · Zaloga pod
   min. pragom. Vsaka kartica je klikljiva bližnjica, ki filtrira tabelo spodaj (isti vzorec kot
   `/products` značke).
3. Filter panel: Organizacija, Cenik/skladišče, "Vrsta opozorila" (multi-select seznam vseh
   pravil spodaj), iskanje po šifri/EAN/nazivu.
4. Rezultatska tabela: šifra, naziv, organizacija, **vrsta opozorila** (badge), vrednost
   (npr. "B2B 24,90 € < nabavna 26,10 €"), starost podatka ("pred X" — glej 5.4), povezava na
   `/products/detail`.
5. Izvoz trenutnega pogleda v CSV/XLSX (isti vzorec kot obstoječi izvozi drugje v aplikaciji).

**Pravila/preverbe, ki jih stran izračuna** (vsako kot ločeno "pravilo" v majhnem šifrantu ali
enum — NE v `pim.ValidationRuleLookup`, glej §2.1):
- Cena: brez B2C cene, brez B2B cene, cena = 0, cena brez DDV, cenik potekel/poteče v X dneh,
  **faktor marže pod pragom** (glej §5.3 — natančno definirano, ni več odprto vprašanje),
  podvojen zapis za isti (artikel, cenik) — RC3.
- Zaloga: brez zaloge in brez prihajajoče dobave, zaloga pod min. pragom (če prag obstaja —
  preveri `pim.ProductStock`/`stg.ProductCommercial` za min/max stolpce; če jih ni, to je odprto
  vprašanje za uporabnika, ne izmišljuj), zastarel posnetek (starejši od X min/ur).

### 5.3 Faktor marže (B2B/PRC) — natančna definicija (potrjeno z uporabnikom)

Uporabnik je podal konkreten primer iz SAOP kartice artikla (`VD.TF.0150PA.TR`, glej sliko v
pogovoru): artikel ima na kartici seznam cenikov (`Cenik` / `Naziv` / `Cena` / `DE` /
`Začetek` / `Konec`) — vsak artikel lahko nastopa v več cenikih hkrati, med njimi:
- **B2B** — »Veleprodajni cenik« (prodajna cena za B2B stranke),
- **B2C** — »B2C cenik« (prodajna cena za splet/potrošnika),
- **PRC** — »Prevzemni cenik« (**nabavna/prevzemna cena** — to je iskani podatek iz §5.2, ki smo
  ga prej označili kot "morda ne obstaja"; **obstaja, samo kot ločen cenik z lastno šifro, ne kot
  poseben stolpec**).

V primeru s slike: B2B = 0,59000 EUR, PRC = 0,11000 EUR → **faktor = B2B / PRC = 0,59 / 0,11 ≈
5,36**. Uporabnikova pravila:
- **Faktor = prodajna cena (B2B, po potrebi tudi B2C) deljena s prevzemno ceno (PRC).**
- **Privzeti prag alarma: faktor < 2** — uredljiv (organizacija/kategorija naj bo urejljiv prag,
  ne trdo kodiran; shrani v majhen šifrant, npr. `pim.MarginFactorPolicy` ali podobno, s privzeto
  vrednostjo 2, override po organizaciji in/ali kategoriji).
- To je **opozorilo za ROČNI pregled, ne avtomatska blokada ali popravek.** Nizek faktor je
  lahko napaka (napačno vnesena prevzemna ali prodajna cena — kot v uporabnikovem primeru, kjer
  bi po pomoti prodal blister/10 kosov po ceni ene sponke), ALI legitimna odločitev (npr. akcija,
  distress prodaja, zavestno nizka marža). Sistem samo **javi**, človek presodi.

**Implementacijske podrobnosti:**
1. Identificiraj pravo `PriceListId`/šifro cenika za "prevzemni" (`PRC` v primeru zgoraj) **po
   organizaciji** — ne predpostavljaj, da je šifra `PRC` enaka v vseh 4 organizacijah (isti
   vzorec previdnosti kot pri B2C/B2B v `pim.PriceListPolicy`: identiteta je vedno
   `(OrganizationId, PriceListId)`, nikoli sklepanje iz imena/šifre po eni organizaciji na vse).
   Preveri dejanske šifre cenikov po organizaciji v `raw.{Org}_PriceLists_current` /
   `pim.PriceListPolicy`, preden karkoli trdo kodiraš.
2. **Past z enoto/pakiranjem:** uporabnikov primer izrecno omenja tveganje, da je ena cena na
   kos, druga na pakiranje ("10 kos sponk + blister"). Preden izračunaš faktor kot zanesljivo
   napako, preveri, ali imata B2B in PRC cena isto mersko osnovo (kos vs. pakiranje —
   `PackageQuantity`/`ItemQuantityOfPackaging2`/VPAK polja). Če osnova ni zagotovo ista, faktor
   še vedno izračunaj in prikaži, a ga NE predstavljaj kot potrjeno napako — pusti presojo
   človeku (to je razlog, zakaj je to opozorilo in ne trda validacija, glej pravilo zgoraj).
3. Tabela na strani iz §5.2 dobi za vsak artikel (kjer obstajata oba cenika) stolpce: **B2B
   cena**, **PRC cena**, **Faktor** (B2B/PRC, 2 decimalki), obarvano opozorilo (npr. rdeče), če
   je faktor pod pragom. Enako po potrebi za B2C/PRC, če uporabnik kasneje potrdi, da ga zanima
   tudi ta par.
4. KPI kartica na vrhu strani (§5.2 točka 2): "Faktor marže pod pragom" s številom prizadetih
   artiklov, klik filtrira tabelo nanje.

### 5.4 Odprto vprašanje — min/max zaloge

**Preden implementiraš "zaloga pod min":** preveri v bazi, ali ta polja sploh obstajajo
(`stg.ProductCommercial`/`pim.ProductStock` za min/max). Če ne obstajajo, **ne izmišljuj
privzetih vrednosti** — postavi kot placeholder (`UiPlaceholder`) z jasnim opisom "rabi podatek X
iz SAOP API-ja" in vrni to kot odprto vprašanje uporabniku namesto tihe napačne implementacije.

### 5.5 Prikaz svežine podatka

Ponavljajoča zahteva v projektu: vsaka SAOP/ERP-sinhronizirana vrednost mora ob sebi kazati
"pred X" (ne samo vrednost) — isti vzorec kot že uveden na cenovni kartici artikla (`Ago()`
pomočnik, glej `ProductCatalogEditorSections.razor`). Uporabi ta vzorec dosledno na novi strani.

---

## 6. Okolje C — SAOP: pisanje nazaj (artikli, stranke, cene, ceniki)

### 6.1 Kaj že obstaja (artikli in stranke DELUJEJO — samo poveži/predstavi enotno)

- **Artikli**: `pim.SaopItemOutboundQueue` → `ItemOutboundWorker`
  (`windows_services/SAOP_API_WS/SAOP_Insert_products`). UI: `/export/saop-item-new` (ADD),
  `/export/saop-item-edit` (PATCH posamezen), `/export/saop-item-bulk` (PATCH množično),
  `/export/saop-item-queue` (zgodovina), `/export/planning-exclude` (izločitev iz rezervacije).
- **Stranke**: `pim.SaopCustomerOutboundQueue` → `CustomerOutboundWorker`, urejanje na
  `/customers/{OrgId}/{Code}` (`CustomerDetail.razor`).
- **Skupen pregled**: `/export/saop-outbound` (`SaopOutbound.razor`) — vsi kanali na enem mestu
  (status/payload/napaka, ponovno pošiljanje), a **pokriva samo 2 od takrat obstoječih 4
  kanalov** (preveri trenutno stanje — glej `docs/specifikacije/Nacrt_Pisanje_Nazaj_V_SAOP.md`).
- Hub stran `/exports/saop` (`ExportsSaop.razor`) — kartice do zgornjih strani.

**Naloga:** ko dodaš cene in cenike (spodaj), razširi `/export/saop-outbound` in
`/exports/saop`, da pokrivata **vse štiri** kanale (artikli, stranke, cene, ceniki) — ne
naredi ločenega petega pregleda mimo obstoječega.

### 6.2 Kaj zgraditi — Cene (novo)

`pim.SaopPriceOutboundQueue` **še ne obstaja**. Delna koda za worker že obstaja
(`SaopPriceOutboundWorker.cs`, `SqlRepository.SaopPriceOutbound.cs` v
`windows_services/SAOP_API_WS/SaopCatalogWorker/Services/`) **z znanim hroščem**:
worker bere `Status='Approved'` namesto `'Pending'`, in ima napako `orgId = orgs[0].Id`
(vedno prva organizacija namesto prave). **Popravi oba pred registracijo v `Program.cs`.**

Zgradi po istem vzorcu kot artikli/stranke:
1. SQL skripta (v `sql/`, uporabnik jo požene sam) `Create_SaopPrice_Outbound.sql`:
   `pim.SaopPriceOutboundQueue` (OrganizationId, PriceListId, ItemID/ItemCode, polje, stara/nova
   vrednost, Status, RequestedAtUtc/SentAtUtc/ResponseJson/ErrorMessage — isti stolpčni vzorec
   kot `pim.SaopItemOutboundQueue`, glej `sql/Create_SaopItem_Outbound.sql`).
2. Popravljen `SaopPriceOutboundWorker` (Status filter, org zanka namesto `orgs[0]`), registriran
   v `Program.cs` workerja.
3. Backend v intranetu: `PimQueryService.SaopPriceOutbound.cs` z `EnqueueSaopPriceUpdateAsync`,
   `GetSaopPriceQueueAsync` (isti vzorec kot `EnqueueSaopItemUpdateAsync`).
4. UI: nova stran `/export/saop-price` — urejanje cene enega artikla/cenika (form z
   staro vrednostjo poleg polja za vnos, isti vzorec kot `/export/saop-item-edit`) + tabela
   vrste/zgodovine. Doda se kartica na `/exports/saop` hub.

### 6.3 Kaj zgraditi — Ceniki (popolnoma novo, tudi na nivoju branja UI)

Danes ni UI-ja za **urejanje** cenika kot celote (samo posamezne cene). Preveri
`/prices/lists` (`PricesLists.razor`, `PriceListDetail.razor`) — če je samo bralni pregled,
dodaj:
1. `pim.SaopPriceListOutboundQueue` (SQL skripta po istem vzorcu, zrno = cenik kot celota ali
   skupina sprememb cen, ki gredo skupaj) — **razjasni z uporabnikom**, ali je "cenik" v SAOP
   API-ju sploh entiteta, ki se popravlja kot celota, ali je to vedno le vsota posameznih cen
   (`api/pricelists/ModifyPriceLists` iz Swaggerja, ki ga je uporabnik pokazal na sliki — to
   POTRJUJE, da endpoint obstaja: `POST /api/pricelists/AddPriceLists`,
   `POST /api/pricelists/ModifyPriceLists`, `GET /api/pricelists/{priceListId}`,
   `GET /api/pricelists`). Preglej `docs/SAOP_API_Inventar.xlsx` za natančno polje-po-polje shemo
   teh dveh endpointov, preden pišeš builder.
2. UI na `/prices/lists/{id}` (ali nov `/export/saop-pricelist`): urejanje meta-polj cenika
   (naziv, veljavnost, valuta …) + gumb "Pošlji spremembo v SAOP", ki napolni zgornjo vrsto.
3. Upoštevaj načela N1-N7 iz §6.4 — cenik je tvegan zapis (vpliva na VSE artikle na njem), zato
   je še posebej pomembno, da UI pred pošiljanjem pokaže jasen diff (stara → nova vrednost).

### 6.4 Sedem načel za VSAK nov outbound kanal (iz revizije `Nacrt_Pisanje_Nazaj_V_SAOP.md`)

Veljajo enako za cene in cenike kot za artikle/stranke:
- **N1** `pim.FieldOwnership` je osrednja resnica o tem, katero polje sploh sme iti nazaj.
- **N2** brez branja nazaj ni pisanja (`CanWriteBack` privzeto 0 za novo polje).
- **N3** hash je kanoničen (`FieldKey` + normalizirana vrednost), ne nad surovim XML/JSON.
- **N4** echo/potrditev primerja proti **poslani** vrednosti (`SentFieldsJson`), NE proti
  trenutnemu stanju PIM (drugače lažen "Drift" pri zaporedju pošlji A → spremeni v B → sync
  vrne A).
- **N5** en `OutboundOperationId` teče skozi cel tok ene operacije.
- **N6** napake ločuj na `Transient`/`Business`/`AuthConfig` z različno politiko ponovnega
  poskusa.
- **N7** `Sent` NIKOLI ni prikazan kot zeleno/uspešno v UI — pomeni samo, da je HTTP klic uspel.
  Zeleno je rezervirano za `Verified` (ko naslednji sync iz SAOP potrdi vrednost).

Vir podatka za PATCH-e mora biti **STG/aplikacija**, nikoli `pim` glavne tabele direktno
(razlog: promocija v `pim` je selektivna in zakasnjena — pisanje iz `pim` bi poslalo staro
vrednost). Enako velja za cene: bazira na `stg.ProductPrice`, ne na `pim.ProductPrice`.

---

## 7. Okolje D — Mediji (samo pregled)

**Stanje: v veliki meri ŽE ZGRAJENO** (shema `media`, migracije 1100-1105, 6 strani: `/media`
hub, `/media/assets` knjižnica, `/media/missing`, `/media/quarantine`, `/media/imports`,
`/media/settings`, + `/media/{id}` detajl sredstva izven menija). Uporabnik je izrecno rekel, da
za zdaj potrebuje samo **pregledovanje** — torej:

1. Preveri, da `/media/assets` omogoča: iskanje/filter po artiklu, vlogi slike (glavna/ostale/
   dokument), organizaciji; da prikazuje sliko + kje vse (na katerih artiklih) se uporablja
   (`media.AssetUsage` je že indeksiran pogled).
2. Preveri `/media/missing` — seznam artiklov brez medija (176.419 znanih odprtih po zadnji
   meritvi) — mora biti filtrirljiv po organizaciji/kategoriji, ne samo skupno število.
3. **Ne** gradi nalaganja/uvoza novih datotek (M6-M9 iz `docs/specifikacije/Nacrt_Medija.md`) —
   to NI bilo zahtevano zdaj. Če je `/media/imports` že placeholder za to, pusti kot je.
4. Znana past: stran `Media.razor` se prevede v razred `Media` → vbrizgana storitev v tej
   komponenti **ne sme** biti poimenovana `Media` (CS0542, konflikt imena s konstruktorjem).

---

## 8. Okolje E — Struktura kataloga (atributi, kategorije, mapiranja, variante)

Uporabnik je dodatno naštel: atributi + prevodi, mapiranje atributov, kategorije z drevesno
strukturo (urejanje + prevajanje), variante artiklov, podobni/povezani izdelki. **Dobra novica:
večina tega že obstaja** — preveri, preden karkoli gradiš na novo:

| Funkcija | Stran | Stanje |
|---|---|---|
| Atributi (šifrant) + prevodi vrednosti | `/settings/attributes` (`PimAttributes.razor`) | **Deluje** — izvoz/uvoz prevodov XLSX v `pim.AttributeValueTranslation` |
| Mapiranje atributov (zunanji vir → PIM atribut) | `/settings/mappings/attributes` (`MappingsAttributes.razor`) | **PLACEHOLDER** — glej 8.1 |
| Kategorije (drevo, urejanje) | `/settings/categories` (`PimCategories.razor`) | **Deluje** — ima uvoz drevesa, filter po spletni strani/statusu |
| Mapiranje kategorij (dobaviteljeva → spletna) | `/settings/mappings/categories` (`CategoryPathMap.razor`) | **Deluje** — po spletni strani |
| Jeziki in splošen prevodni slovar | `/settings/languages` | **PLACEHOLDER** — glej 8.2 |
| Variante / podobni / povezani izdelki | `/settings/product-links` (`ProductLinks.razor`) | **Deluje** — 3 sekcije: variante (skupina izdelka), podobni, povezani |
| Obvezni atributi po kategoriji | ni samostojne strani — `pim.CategoryAttributeMap` (migracije 1300-1302) | **Šifrant nameščen, a PRAZEN** — nihče še ni vnesel pravil |

### 8.1 Mapiranje atributov — zgradi zares

Zamenjaj `UiPlaceholder` na `/settings/mappings/attributes` z delujočo stranjo:
- Tabela: izvorni vir (NW/BT/SAOP…), proizvajalec (kjer je mapiranje odvisno od proizvajalca —
  glej [[saop-builders-are-per-source-not-manufacturer]] v projektnem spominu: **mapiranje je
  po VIRU, ne po proizvajalcu**, razen če najdeš dokaz o nasprotnem v konkretnih podatkih),
  organizacija, izvorni atribut (surovo ime iz `raw`), → PIM atribut (dropdown iz
  `pim.Attribute`, ki ga `/settings/attributes` že upravlja), status (mapirano/nemapirano).
- Filtri: vir, proizvajalec, organizacija, status mapiranja, iskanje po izvornem/PIM imenu.
- Potrebna nova tabela (SQL skripta, uporabnik jo požene): mapiranje (vir, proizvajalec NULL-abilen,
  organizacija, izvorni atribut) → PIM AttributeId, z zgodovino kdo/kdaj (glej
  `security.AuditLog` konvencijo — `Audit.WriteAsync` ob vsaki spremembi).
- Vir "nemapiranih" izvornih atributov: poglej, ali `raw.*` že hrani surovo ime atributa kje
  dostopno (npr. iz XML uvoza) — če ne, to je odprto vprašanje, ne izmišljuj vira.

### 8.2 Jeziki in prevodi — presoditi obseg

Preden gradiš splošen "prevodni slovar", preveri, ali sploh manjka: `/settings/attributes` že
rešuje prevode VREDNOSTI atributov. Kaj torej manjka na `/settings/languages`?
- Verjetno: seznam aktivnih jezikov (šifrant `pim.Language` ali podoben), in prevodi
  **nazivov/opisov artikla** po jeziku (ne vrednosti atributov) — preveri, ali `pim.ProductCore`
  ali sorodna tabela sploh nosi večjezične nazive, ali je to danes en jezik (SL) na artikel.
  Če večjezičnost naziva/opisa še ne obstaja nikjer v shemi, **to je arhitekturna odločitev, ki
  jo mora potrditi uporabnik** (nova tabela `pim.ProductTranslation`?) — ne uvajaj je tiho mimo
  vprašanja.
- Če je obseg samo "kateri jeziki so aktivni + slovar ponavljajočih se UI izrazov", zgradi
  enostavno CRUD stran po vzorcu `/settings/references`.

### 8.3 Obvezni atributi po kategoriji (CategoryAttributeMap)

Uporabnik tega ni izrecno omenil v zadnjem sporočilu, a je neposredno povezano z "atributi +
kategorije" in shema že obstaja prazna (`pim.CategoryAttributeMap`, migracije 1300-1302,
`docs/specifikacije` mastri analiza v `mastri-category-attribute-rules`). **Predlog, ne
zahteva:** omeni uporabniku kot naslednji korak, ne implementiraj brez potrditve, ker manjka
vsebina pravil (53 mastrov, ki jih mora nekdo pregledati in prenesti).

---

## 9. Kaj JE ŠE MANJKALO uporabniku (dodaj to, on te ni izrecno vprašal)

Med analizo obstoječe kode sem opazil sorodne stvari, ki spadajo v isto vizijo, a jih uporabnik
ni omenil — **predlagaj mu jih, ne implementiraj tiho**:
- **Spletni kanali** (`/settings/channels`) — preveri stanje; to je nastavitveni del okolja
  "Splet", ki spada zraven, ko govorimo o "SAOP okolju" vs "spletnem okolju" simetrično.
- **Pravila virov** (`/rules/sources`) in **B2B pravila** (`/rules/b2b`) — če uporabnik gradi
  "preverbe" za cene/zalogo (okolje B), verjetno bo želel tudi prag marže/min-zaloge urejati kot
  **pravilo** v enem od teh šifrantov, ne trdo kodirano v strani iz §5 — razjasni z njim, ali naj
  bodo pragovi urejljivi (verjetno da, glede na "kdaj bodo prišle" — to zveni kot nekaj, kar se bo
  s časom nastavljalo po kategoriji/organizaciji).
- **Obveščanje** (`Notifications.razor` že obstaja v kodi) — če Luka želi, da mu preverbe iz
  okolja B "javljajo" napake (njegova beseda), preveri, ali obstoječi `Notifications.razor`
  mehanizem lahko nosi tudi opozorila o cenah/zalogi, namesto da izumljaš nov kanal obveščanja.

---

## 10. Predlagano zaporedje dela (fazno, ne vse naenkrat)

1. **Faza 1 — preveri in poveži obstoječe** (poglavja 4, 7, 8 kjer piše "Deluje"): brez novih
   tabel, samo preverjanje skladnosti in manjše UI popravke (KPI vrstica na `/quality/health`,
   preverba usklajenosti kanala med `/quality/issues` in zavihki artikla).
2. **Faza 2 — mapiranje atributov** (§8.1): nova tabela + stran, srednje tvegano, brez
   posega v obstoječe podatkovne tokove.
3. **Faza 3 — Cene in zaloga: opozorilna stran** (§5): najprej razjasni odprti vprašanji (5.3)
   z uporabnikom, šele nato gradi izračune in stran.
4. **Faza 4 — SAOP cene** (§6.2): popravi obstoječi worker hrošč + zgradi UI. To je
   najbolj neposredno nadaljevanje že napisane, a nedokončane kode.
5. **Faza 5 — SAOP ceniki** (§6.3): počakaj na razjasnitev entitete "cenik" v SAOP API-ju
   (pregled `docs/SAOP_API_Inventar.xlsx`) preden pišeš builder.
6. **Faza 6 — Jeziki/prevodi** (§8.2): šele ko je obseg potrjen z uporabnikom.

Po vsaki fazi: `dotnet build src` mora biti čist (0 napak, 0 opozoril), vse `@page` poti
unikatne, nove SQL skripte samo NAPISANE (uporabnik jih sam požene na `DAVID\MSSQL19`), nobena
sprememba sheme ni izvedena avtomatsko. Vizualno testiranje v brskalniku ni mogoče lokalno
(prijava rabi DB račun/BCrypt) — po vsaki fazi to preveri uporabnik sam.
