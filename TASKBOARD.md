# TASKBOARD — skupni spomin agentov

Edini vir resnice o tem, kdo kaj dela in kaj je narejeno.
Pravila so v [`AGENTS.md`](AGENTS.md); ta tabla jih ne podvaja.

## Kako se uporablja

- **Pred delom:** preberi to tablo in `STATUS.md`, poženi `git status --short`.
- **Med delom:** premakni nalogo v DELAM, vpiši ime in ozemlje.
- **Po delu:** premakni v KONČANO z **dokazom** — kateri ukaz, kakšen izhod.
- Eno ozemlje = en commit. Ozemlja: BAZA / INTRANET / WORKERJI / DOMENA.

---

## TODO (čaka)

- **[WORKERJI]** Preslikave za 13 še nepreslikanih SAOP končnih točk. Zajem dela za
  vseh 16, preslikava v `canon` je nastavljena za `GetItemsGeneralData`, `GetPrices`
  in `GetItemsDescriptions`. Za šest končnih točk oblika XML ni znana — v posnetih
  odgovorih ni bilo vsebine, zato se preslikava zanje piše šele po prvem živem zajemu.
  Šifranti (`Currencies`, `PriceLists`, `Warehouses`, `GetLanguages`) in B2B
  (`Customers`, `GetItemCustomerDataV2`, `CustomerItemGroupDiscounts`) nimajo cilja v
  `map.ProcessRawInbox` — potrebujejo odločitev, kam v modelu spadajo.
  Od 2026-08-20 to ni več tiho: zajem teh entitet mejnika ne premakne, zato bo prvi
  zagon po dodani preslikavi isto obdobje zajel znova. Prej bi bilo trajno izgubljeno.
- **[BAZA]** Hitrost `map.ProcessRawInbox`. Izmerjeno: 5.303 artiklov = 649 s (~8/s),
  kar je za 200.000 artiklov okrog 7 ur. Vzrok je ugnezdeni kurzor s petimi `MERGE`
  stavki na zapis. Potrebna je množična obdelava.
- **[WORKERJI]** `PIM.StockFileWorker` in `PIM.B2bWorker` dobita pravi `Program.cs`.
  Pisalna logika (`StockLandingWriter`, `B2bLandingWriter`) obstaja in je dokazana,
  a jo kliče samo test — worker sam v bazo ne piše ničesar.
- **[WORKERJI]** Odločitev o `PIM.SaopStockWorker`, `PIM.FoundationWorker` in ostanku
  `PIM.NwXmlWorker` (samo `bin\`/`obj\`, projekta ni v `PIM.sln`).

## DELAM (v teku)

_(prazno)_


## BLOKIRANO

_(prazno)_

- **[WORKERJI / Agent B]** `PIM.B2bWorker` dobi pravi `Program.cs` — blokirano
  2026-08-20: `B2bLandingWriter` že zna atomarno zapisati en JSON zapis, toda
  repozitorij ne določa lokalnega execution contracta workerja (vhodne datoteke
  oziroma fixture, argumenti/okoljske nastavitve za `OrganizationId`, `SourceCode`,
  `EntityType` in stabilni `SourceRecordKey`, ter obravnava podvojenega landing
  ključa). `docs/WORKERS.md` ga izrecno označuje kot fixture-only in brez potrjenega
  contracta. Implementacija bi te vrednosti izumila, zato je Agent B ne začne.

## KONČANO

- **[WORKERJI]** Mejnik se ne premakne za zajem brez preslikave; padec enega podjetja
  ne ustavi ostalih — kdo: Claude Opus 5 (izvedba), Codex (neodvisni QA) — 2026-08-20.
  Obe napaki je našel Codex v pregledu ostanka žive SAOP seje; obe sta bili preverjeni
  proti kodi in bazi, preden sta bili popravljeni.
  1. `SaopIngestRunner.RunEndpointAsync` je po uspešnem zajemu vedno premaknil mejnik.
     Preslikane so 3 entitete od 16 (dokaz iz baze: `map.EntityMapping` za
     `SAOP_IQLIGHTING` vrne `Descriptions`, `ItemGeneralData`, `Prices`), ostalih 13 pa
     `SqlMappingPipeline.ReadInboxesAsync` z INNER JOIN sploh ne pobere — ostanejo
     `Pending`. Premaknjen mejnik bi pomenil, da bo ob pozneje dodani preslikavi to
     obdobje trajno preskočeno. Zdaj velja isto pravilo kot pri napaki in manjkajočem
     ceniku: **brez aktivne preslikave se mejnik ne premakne**, zajeti podatek pa
     ostane v `raw.Inbox` in je v izpisu označen z `BREZ PRESLIKAVE`.
  2. `OperationsRun.BeginAsync` je stal zunaj `try`. Podjetje brez razporeda (51100 —
     prav to je odpravila migracija 043) bi ubilo worker in podjetja za njim sploh ne
     bi prišla na vrsto. Zanka je zdaj v `OrganizationLoop` z eno zavezo: padec enega
     podjetja ne ustavi ostalih.
  Dokaz RED→GREEN: z odstranjeno varovalko `PIM.F3.Integration` pade
  (`Program.cs:211`, „mejnik premaknjen — tiha izguba podatkov"); z varovalko
  `scripts\run_tests.ps1 -Filter F3` → 4 uspeli, 0 preskočenih, 0 padlih, dvakrat
  zapored. Nov test zažene cel zajem prek `SaopIngestRunner` proti lažnemu HTTP
  odgovoru (brez živega SAOP) za preslikano in nepreslikano entiteto hkrati ter
  preveri `map.Watermark` in `raw.Inbox` v bazi; za sabo počisti vse svoje vrstice in
  vrne mejnik `ItemGeneralData` na prejšnjo vrednost (preverjeno: 0 ostankov).
  Polni paket: `scripts\run_tests.ps1` → **44 uspeli, 0 preskočenih, 0 padlih**;
  `dotnet build PIM_Solution\PIM.sln` → 0 opozoril, 0 napak.

- **[INFRASTRUKTURA]** Razvojna baza usklajena s kodo — kdo: Claude Opus 5 —
  2026-08-20. `dbo.SchemaMigration` je imela migracije samo do `027`; migracije
  `028`–`043` na tem računalniku nikoli niso bile uporabljene, čeprav `STATUS.md` in
  ta tabla trdita nasprotno — delo je bilo opravljeno na drugem računalniku
  (`DESKTOP-2CGGQIC`, ta je `DESKTOP-TONVQHJ`). Zaradi tega je vseh 7 integracijskih
  testnih projektov padalo s `Class:20` (povezava), ne s poslovno napako.
  Popravljeno: korenski `appsettings.Local.json` (lokalen, gitignoriran) kaže na
  `localhost\MSSQLSERVER3` namesto na staro ime računalnika — poverilnice
  nedotaknjene; `core.filemode=false`, ker WSL na `/mnt/c` javlja 644→755 in je iz
  14 resničnih sprememb delal 335 lažnih.
  Dokaz: migrator 1. zagon → uporabljenih 16 migracij `028`…`043`; 2. zagon → brez
  nove migracije; `--verify` → „Preverjanje F0–F10 baze je uspešno", izhod 0.

- **[DOMENA/IZVOZ / Agent B]** Magento CSV izvoz: lokalni, read-only ukaz
  `PIM.B2bWorker --export-magento --organization-id <int> --output-dir <dir>`
  ustvari datoteki po referenčnih Excel predlogah (215 oziroma 19 glav), UTF-8
  brez BOM in LF, brez FTP/HTTP in brez spremembe SQL sheme — 2026-08-20.
  Dokaz: `dotnet run --project PIM_Solution\tests\PIM.F7.MagentoExportTests` →
  PASS; `dotnet build PIM_Solution\workers\PIM.B2bWorker\PIM.B2bWorker.csproj
  --no-restore` → 0 napak; `scripts\run_tests.ps1 -Filter F7` → 4 F7 testi
  PASS, F7 integracija in xUnit pa nedosegljiva razvojna baza.

- **[WORKERJI + BAZA]** Živ SAOP zajem: pravi HTTP odjemalec, vseh 16 končnih točk,
  štiri podjetja, in odprava treh zapor, zaradi katerih worker sploh ni mogel teči —
  kdo: Claude Opus 5 — 2026-08-13 — **ni še commitano, čaka na uporabnikov preizkus.**

  Tri zapore, vsaka dokazana v bazi pred popravkom:

  1. `PIM.KatalogWorker` je padel takoj ob zagonu z 51100 `Razpored ni omogočen.` —
     `ops.ScheduleProfile` ni imel vrstice za `SAOP_PRODUCTS`. Profili so bili dodani
     v 035 za `WATCHDOG` in `ALERT_DISPATCH`, za SAOP nikoli. Zadnji uspešen SAOP
     zajem je bil 30. 7. 2026, dan pred migracijo 025. Popravek: `043`.
  2. Od migracije 017 `map.ProcessRawInbox` ne ustvarja artiklov — vsak neznan
     `ItemID` konča z `Izdelek za konfigurirani identifikator ne obstaja.` Za
     dobaviteljski XML je to pravilno, za ERP je zapora. Popravek: `042` doda
     `map.SourceConnector.CanCreateProducts` (privzeto 0; 1 samo za `SAOP`).
  3. `LiveSaopSource` je klical eno samo stran brez avtentikacije, paginacije in
     glave `OrganisationId`. Nadomešča ga `SaopApiClient` (Basic auth, `searchQuery.page`
     /`pageSize`, `recordDtModifiedFrom`, ponovni poskusi na 408/429/502/503/504).

  Dokaz: migrator 1. zagon → `Uporabljena migracija: 042…`, `043…`; 2. zagon brez nove
  migracije; `--verify` → izhod 0. Fixture zajem prek novega `map.ProcessRawInbox` →
  izhod 0; `EXEC map.ProcessRawInbox` za 5.303 artiklov → izhod 0 v **649 s**.
  Meritev pred → po na `canon.Product` (org 2): artiklov 6.145 → 6.285 (**140 novih,
  ustvarjenih iz ERP vira**), EAN 788 → 1.026, `ItemGroup` **0 → 5.269**,
  `Department` 0 → 285, `WebPublish` 0 → 184. `scripts\run_tests.ps1` →
  **42 uspeli, 0 preskočenih, 0 padlih**.

  Vzrok manjkajočih EAN je bil neposlikan `GeneralData/ItemEANCode`; `ItemGeneralData`
  je imel 7 preslikanih polj od 12 razpoložljivih. Živ klic še ni bil izveden — na tem
  računalniku ni poverilnic. Navodila za zagon in debagiranje: `docs/ZAJEM-SAOP.md`.

- **[BAZA]** Register jezikov in spletni nazivi za 18 promoviranih izdelkov —
  kdo: Claude Opus 5 — 2026-08-13 — dokaz: migracija
  `041_AddLanguageRegistryAndNwTitleMapping.sql`, migrator 1. zagon →
  `Uporabljena migracija: 041...`, 2. zagon → brez nove migracije,
  `--verify` → izhod 0; `scripts\run_tests.ps1` → **42 uspeli, 0 preskočenih,
  0 padlih**. Dodan `dbo.Language` (`sl` privzeti, `en`, `de`, `hr`) s
  filtriranim unique indeksom za natanko en privzeti jezik. NW_XML preslikava
  `product_name` preusmerjena z mrtve tarče `Unsupported.F5Probe` na
  `ProductText.WEB_TITLE.en` — datoteka dobavitelja je `products_en_US.xml`,
  torej angleška. `scripts\seed_web_titles.sql` (ni migracija, ročni zagon,
  idempotenten) napolnil 17× `WEB_TITLE.sl` iz `TITLE_ERP.sl` in 16×
  `WEB_TITLE.en` iz NW XML; 2. zagon dodal 0. Posledica: **WEB_B2C VALID
  1 → 17**. `pim.Product` ostaja 18, ker promocijo vodi ERP_L1, ki se ni
  spremenil.

  Slovenski ERP nazivi niso enolični: `NW.9448`/`NW.9451`/`NW.9452` imajo
  vsi `PROFILE tračnica NT1N`, čeprav so 1 m in 2 m različice — angleški naziv
  to loči. Za splet je to premalo; nazivi so uporabna začetna vrednost.

- **[BAZA]** Ročno napisani slovenski opisi za 16 izdelkov Nowodvorski —
  kdo: Claude Opus 5 — 2026-08-13 — dokaz:
  `scripts\seed_descriptions_nw16.sql` (ni migracija, ročni zagon,
  idempotenten, obvezno `sqlcmd -f 65001`) → `Dodanih DESCRIPTION.sl: 16`,
  2. zagon → `0`; šumniki preverjeni v bazi prek `UNICODE()`/`NCHAR()`
  (č=269, š=353, ž=382 prisotni v vseh treh vzorcih);
  `scripts\run_tests.ps1` → **42 uspeli, 0 preskočenih, 0 padlih**.
  `canon.ProductText` zdaj: `sl/TITLE_ERP` 5846, `sl/WEB_TITLE` 18,
  `sl/DESCRIPTION` 16, `en/WEB_TITLE` 16.

  Vsaka specifikacija v opisih izhaja iz veje `<attributes>` pripadajočega
  `<product>` v `PIM_Solution\fixtures\nw\products_en_US.xml` (ujemanje po
  EAN). Nič ni izmišljeno. Mere embalaže so namenoma izpuščene, ker so to
  dimenzije škatle in ne izdelka — izjema so tračnice, kjer je `Length
  packing` dejanska dolžina in to potrjuje naziv (`TRACK 1 M` / `2 M`).
  Skript ima v glavi zapisan tudi ukaz za razveljavitev.

  Validacija se ni spremenila (`DESCRIPTION` ni obvezno polje v nobenem
  profilu): ERP_L1 VALID 18, WEB_B2C VALID 17.

  Odprto: `ACB.A3660001N` nima opisa in ni v NW XML — je čisti SAOP izdelek.
  Za preostalih ~6.100 izdelkov opisov ni; SAOP fixture
  `Descriptions/page-001.xml` ima 155 zapisov, nobeden ni naš, `page-002.xml`
  je prazna. Pravi vir bo `Descriptions` endpoint iz živega SAOP-a.

- **[INTRANET/DOKUMENTACIJA]** Poenotena lokalna konfiguracija povezave — kdo: Hermes (koordinacija in dokaz), Claude (implementacija), Codex (neodvisni QA) — 2026-08-13 — dokaz: dotnet build PIM_Solution/PIM.sln --no-restore → 0 (0 warnings, 0 errors); zagon intraneta brez PIM_CONNECTION_STRING, samo z ASPNETCORE_URLS → /health HTTP 200; prijavni POST, ki odpre SQL povezavo → HTTP 302, brez SqlException 26; scripts/run_tests.ps1 → REZULTAT: VSE OK, 42 uspešnih, 0 preskočenih, 0 padlih; git diff --cached --check → 0; Codex → VERDICT: PASS. Korenska konfiguracija ima SHA-256 a913f6ff231de8da7e7f4e85291d25f67185ad1558562ad9a3de0a0c81d82a5d; obe preimenovani podrejeni konfiguraciji imata SHA-256 1e70f708c6896994194cafc41a682ece0837b90206709738431ac4c233b65558.

- **[DOKUMENTACIJA]** E2E protokol koraki 1–5 — kdo: Hermes, Codex (neodvisni
  QA) — 2026-08-13 — dokaz: `dotnet build PIM_Solution/PIM.sln` → 0 (0
  warnings, 0 errors); migrator `--verify` → 0; dva zagona migratorja brez
  `--verify` → 0 in drugi brez nove migracije; `scripts\run_tests.ps1` →
  `REZULTAT: VSE OK`, 42 uspešnih, 0 preskočenih, 0 padlih; F3/F5/F6/F7 in F8
  fixture testi → 0; intranet `/health` na 5088 → HTTP 200, `stanje=zdravo`,
  proces ustavljen; `codex exec --model gpt-5.6-terra` → `VERDICT: PASS`.

- **[DOKUMENTACIJA]** Preizkus protokola predaje: `docs\\PREIZKUS-PREDAJE.md`
  je ustvaril Claude; kdo: Hermes (koordinacija), Claude (izvedba), Codex (QA)
  — 2026-08-13 — dokaz: `wc -l` → 1, `grep -c '[^[:space:]]'` → 1;
  `codex exec --model gpt-5.6-terra` → `VERDICT: PASS`.

- **[TESTI]** Pravi testni zaganjalnik `scripts\\run_tests.ps1` in popravek UX
  pogodbe kartice izdelka — kdo: Claude Opus 5 — 2026-08-12 — dokaz:
  `scripts\run_tests.ps1` → **42 uspeli, 0 preskočenih, 0 padlih**, izhod 0.
  Razlog: `dotnet test PIM_Solution\PIM.sln` je izvajal **1 projekt od 43** in
  vračal 0, ker so ostali konzolne aplikacije, ki jih samo prevede. Prvi polni
  zagon je razkril 7 padlih projektov; šest jih je padlo zaradi nedosegljive
  baze (zaganjalnik zdaj poda `PIM_CONNECTION_STRING`, ker testi
  `appsettings.Local.json` iz svoje mape ne najdejo), sedmi je bila prava
  napaka v `PIM.F10.ProductDetailUxTests`.

- **[BAZA/WORKERJI]** Odpravljen FK 547 v F3/F5 cleanupu in zaprt regresijski
  paket — kdo: Hermes — 2026-08-12 — vzrok: triggerji sledljivosti so po prvem
  cleanupu ustvarili novo `pim.ProductFieldHistory` za testni produkt; cleanup
  drugič ozko odstrani zgodovino in prazne pripadajoče batche. Dokaz:
  `dotnet run --project PIM_Solution/tests/PIM.F3.Integration --no-restore` = 0;
  `dotnet run --project PIM_Solution/tests/PIM.F5.Integration --no-restore` = 0;
  `dotnet build PIM_Solution/PIM.sln --no-restore` = 0 (0 warnings, 0 errors).
  Opomba: prvotni zapis se je skliceval tudi na `dotnet test PIM.sln` = 0
  dvakrat zapored. To drži, a ni dokaz — ta ukaz izvaja 1 projekt od 43.
  Veljaven dokaz je naknadni polni zagon `scripts\run_tests.ps1`.

- **[INFRASTRUKTURA]** Reorganizacija map in poenotenje pravil — kdo: Claude Opus 5 —
  2026-08-12 — dokaz: `AGENTS.md` je edini pravilnik; nasprotujoči si dokumenti
  premaknjeni v `..\_arhiv\`; Node scaffold umaknjen, ker je `npm test` dajal
  lažno zeleno; 52 necommitanih datotek zavarovanih v 5 commitih in v
  `..\Backups\pred-reorg_20260812_191646\`.
- **[BAZA/INTRANET]** S1–S4 sledljivost izdelkov: register lastništva, batch/field
  zgodovina, množična triggerja, XML `SESSION_CONTEXT`, zavihek Zgodovina —
  kdo: Hermes — 2026-08-12 — migracije 028–031 uporabljene na `PIM`,
  rollback-only dokaz PASS.
- **[DOKUMENTACIJA]** Ločena dokumentacija baze, workerjev, intraneta, izvozov,
  laptop namestitve in E2E protokola — kdo: Hermes — 2026-08-12 — brez skrivnosti.
- **[WORKERJI/IZVOZI]** Fixture/replay dokaz F6/F7/F8/F9 — kdo: Hermes — 2026-08-12
  — F6 NW=2697, BT=1361; F8 samo loopback fixture.
- **[INTRANET]** Uskladitev nadzorne plošče z odobrenim UX in strežba CSS pod `/`
  in `/PIM` — kdo: intranet_dashboard — 2026-08-04 — build 0/0, F10 PASS, CSS 200.
