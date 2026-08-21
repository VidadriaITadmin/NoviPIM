# TASKBOARD — skupni spomin agentov

Edini vir resnice o tem, kdo kaj dela in kaj je narejeno.
Pravila so v [`AGENTS.md`](AGENTS.md); ta tabla jih ne podvaja.

## Kako se uporablja

- **Pred delom:** preberi to tablo in `STATUS.md`, poženi `git status --short`.
- **Med delom:** premakni nalogo v DELAM, vpiši ime in ozemlje.
- **Po delu:** premakni v KONČANO z **dokazom** — kateri ukaz, kakšen izhod.
- Eno ozemlje = en commit. Ozemlja: BAZA / INTRANET / WORKERJI / DOMENA.

---

> **Kar čaka človeka, ne agenta, je zbrano na enem mestu:
> [`docs/TVOJE_NALOGE.md`](docs/TVOJE_NALOGE.md)** — po vrsti, z razlogom in koraki.
> Vsaka postavka BLOKIRANO spodaj ima tam svojo nalogo.

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
- **[WORKERJI]** `PIM.StockFileWorker` in `PIM.B2bWorker` dobita pravi `Program.cs`.
  Pisalna logika (`StockLandingWriter`, `B2bLandingWriter`) obstaja in je dokazana,
  a jo kliče samo test — worker sam v bazo ne piše ničesar.
- **[WORKERJI]** Odločitev o `PIM.SaopStockWorker`, `PIM.FoundationWorker` in ostanku
  `PIM.NwXmlWorker` (samo `bin\`/`obj\`, projekta ni v `PIM.sln`).
- **[TESTI]** Pet projektov brez baze pade namesto da bi se preskočilo. Izmerjeno
  2026-08-20 z odmaknjenim `appsettings.Local.json` in praznim
  `PIM_CONNECTION_STRING`: `scripts\run_tests.ps1` → izhod 1, 38 uspeli,
  1 preskočen, **5 padli**. `PIM.F3.Integration` in xUnit se korektno preskočita
  (izhod 0), `PIM.F2.Integration`, `PIM.F5.Integration`, `PIM.F8.HardeningTests`,
  `PIM.F8.Integration` in `PIM.F9.Integration` pa končajo z izhodom 2
  „MSSQL BLOCKED". Posledica: na računalniku brez razvojne baze je paket videti
  pokvarjen, čeprav ni, in CI ne more poganjati testov — zato zdaj samo prevaja.
  Vzorec za popravek je `PIM.F3.Integration/Program.cs:5-10`.
- **[IZVOZ]** `PIM.B2bWorker\MagentoExportRunner.cs` je mrtva koda — nanj se ne
  sklicuje nič (`grep` po celotni rešitvi vrne samo definicijo). Je druga, vzporedna
  izvedba istega izvoza; priklopljen je `MagentoExportCommand`. Potrebna je odločitev,
  ali se izbriše — brisanje je na zaprtem seznamu `AGENTS.md` §4.1.

## DELAM (v teku)

_(prazno)_


## BLOKIRANO

- **[IZVOZ]** 162 atributnih stolpcev Magento predloge (stolpci 54–215) je v izvozu
  praznih — blokirano 2026-08-20, **potrebna je tvoja odločitev**. Mehanizem dela in
  je dokazan: `PIM.F7.MagentoExportTests` posadi atribut s kodo `Grlo ANG` in ta
  pristane v svojem stolpcu. Manjka konfiguracija, ne koda: da se stolpec napolni,
  mora v `map.FieldMapping` obstajati vrstica s `TargetFieldCode` = `ProductAttribute.<glava>`
  (na primer `ProductAttribute.Grlo ANG`). Danes je edina obstoječa koda atributa v
  bazi `CategoryRequired` (`canon.ProductAttribute`: 2 vrstici), zato se ne ujema
  nobeden od 162 stolpcev.
  **Vprašanje:** katera SAOP oziroma NW lastnost pripada kateremu stolpcu predloge?
  Tega ne smem ugibati. Če je odgovor v `docs/Mapiranje_SAOP_NoviPIM.xlsx`, povej —
  preslikave bom zapisal kot vrstice registra, ne kot kodo.
  Do takrat izvoz te stolpce izpiše prazne; napačnih vrednosti ne izvozi.

_(prazno)_

- **[WORKERJI / Agent B]** `PIM.B2bWorker` dobi pravi `Program.cs` — blokirano
  2026-08-20: `B2bLandingWriter` že zna atomarno zapisati en JSON zapis, toda
  repozitorij ne določa lokalnega execution contracta workerja (vhodne datoteke
  oziroma fixture, argumenti/okoljske nastavitve za `OrganizationId`, `SourceCode`,
  `EntityType` in stabilni `SourceRecordKey`, ter obravnava podvojenega landing
  ključa). `docs/WORKERS.md` ga izrecno označuje kot fixture-only in brez potrjenega
  contracta. Implementacija bi te vrednosti izumila, zato je Agent B ne začne.

## KONČANO

- **[WORKERJI]** Mejnik se ne premakne pri `--only-ingest` in pri podvojenih straneh; nov
  `--map-run` — kdo: Claude Opus 5 — 2026-08-21. **Napako je razkril prvi živi zajem in
  sprožilo jo je moje navodilo** v `docs/TVOJE_NALOGE.md`, ki je predlagalo `--only-ingest`.
  Kaj se je zgodilo: `--only-ingest` po definiciji ničesar ne preslika, mejnik pa je vseeno
  premaknil. Ponovni zagon s preslikavo je od SAOP dobil enako vsebino, `raw.Inbox` jo je
  prepoznal po hashu in je ni vstavil znova, zato preslikava ni imela česa obdelati —
  mejnik pa je bil že naprej. Rezultat: 183 artiklov `Pending` za mejnikom, ki jih delta
  zajem ne bi več prinesel. Isti razred napake kot 2026-08-20 (Codex), drug sprožilec.
  Popravljeno: mejnik zdaj stoji tudi (1) pri `--only-ingest` in (2) kadar je SAOP vrnil
  zapise, a ni pristala nobena nova vrstica te entitete. Izpis vedno pove razlog
  (`WatermarkHold`). Nepreslikane vrstice iz prejšnjih zagonov so opozorilo, ne zapora —
  sicer bi bil zajem odvisen od nepovezanih ostankov v skupni bazi.
  Nov `--map-run <RunId>` preslika že zajet zagon brez klica na SAOP; ne potrebuje niti
  poverilnic niti `PIM_SAOP_MODE=Live`.
  Dokaz RED→GREEN: z izklopljeno varovalko `PIM.F3.Integration` pade, z varovalko
  `scripts\run_tests.ps1 -Filter F3` → 4 uspeli, 0 padlih. Test zdaj v enem bloku pokrije
  tri razloge za zadržan mejnik (brez preslikave, `--only-ingest`, podvojene strani) in za
  sabo pobriše vse tri zagone.
  Popravek v praksi: `--map-run E4980729…` je obdelal vrstico 501 — 168 uspelo, 15
  preskočenih, 148 novih artiklov. Polni paket: **44 uspeli, 0 preskočenih, 0 padlih**.

- **[MERITEV]** Prvi živi SAOP zajem na tem računalniku — 2026-08-21, podjetje 2.
  `GetItemsGeneralData` (delta) je vrnil 183 artiklov; 168 obogatenih, **15 (8,2 %)
  zavrnjenih v celoti** z razlogom `Obvezna preslikana vrednost manjka.` V vseh 15 primerih
  manjka `Product.DiscountGroup` (`SalesData/DiscountGroup1ID`); `AccountingGroup` manjka
  pri 4, `Manufacturer`, `Supplier` in `UoM` pri po enem — vsi so podmnožica istih 15.
  Stanje po zajemu: 6.299 artiklov, EAN 789 → 906, `ItemGroup` 0 → 168, `Department` 0 → 162.
  **To je meritev, ki je migraciji `042` manjkala.** Pri 200.000 artiklih bi enak delež
  pomenil okrog 16.000 artiklov, ki jih v PIM sploh ne bi bilo. Odločitev, ali
  `DiscountGroup1ID` ostane obvezen, je naloga 1b v `docs/TVOJE_NALOGE.md`; moje priporočilo
  je, da ne ostane — nepopolnost že lovi validacija.

- **[ODHODNA POT]** Trije resnični manjki odhodne poti: razred napake, nadomeščeno
  sporočilo in uskladitev nove šifre — kdo: Claude Opus 5 — 2026-08-21, migracija
  `046_OutboundErrorClassSupersededAssignment.sql`.
  Vir zahtev je list `Outbound-vrzeli` v
  `PIM_Solution\docs\Povezave_virov_in_sistemov\Mapiranje_SAOP_API_PIM.xlsx`
  (vrzeli O18, O16 in O19). Tam so opisane nad tabelami starega sistema; prenesene so
  na dejansko shemo NoviPIM, ki je `out.OutboxMessage`.
  1. **O18 — razred napake.** Nov stolpec `ErrorClass` (`Transient` | `Business` |
     `AuthConfig`) na sporočilu in na poskusu. `Business` gre takoj v `Dead` in ne porabi
     poskusov; `AuthConfig` poleg tega ustavi kanal (`IntegrationProfile.IsEnabled = 0`) in
     sproži **en** alarm `OUTBOUND_AUTH` na integracijo namesto enega na vsak artikel.
  2. **O16 — stanje `Superseded`.** Zaporedje „pošlji A → popravi na B → pošlji B → SAOP
     potrdi B" je prej pustilo A v `Sent` za vedno, kar je na nadzorni strani videti kot
     „SAOP ni potrdil". Nadomestitev nastavita `out.EnqueueMessage` (ob novem sporočilu za
     isto polje) in `out.VerifyEcho` (ko novejše dobi odgovor — to pokrije primer, ko je bilo
     starejše ob vpisu novejšega še v roki workerja). Ključ vsebuje tudi qualifier, zato
     cena za `B2B` ne nadomesti cene za `B2C`.
  3. **O19 — uskladitev nove šifre.** Nova tabela `out.SaopItemAssignment` in procedura
     `out.ResolveSaopItemAssignment` z vrstnim redom odgovor SAOP → zahtevana šifra → EAN →
     človek. **Dvoumen EAN namenoma ni ujemanje** — napačna povezava je slabša od nobene,
     ker se ne vidi. Omejitev `CK_SaopItemAssignment_Resolved` prepove način ujemanja brez
     dejansko dodeljene šifre.
  **En obstoječi test sem moral popraviti in to ni skrito.** `PIM.F8.HardeningTests` je
  trdil `Equal("Sent", ...)` z namenom „echo novejše spremembe ne sme starejše označiti kot
  Drift". Namen je nespremenjen in zdaj celo izrecno preverjen; spremenil se je odgovor,
  ker do te migracije stanja `Superseded` ni bilo. Trditev se zdaj glasi `Superseded` plus
  ločena trditev, da ni `Drift`.
  **Kar ta naloga NE naredi:** odhodna pot danes pošlje spremembo polja, ne ustvari artikla,
  zato poti, ki bi `out.ResolveSaopItemAssignment` klicala v živo, še ni. Tabela, procedura
  in pravila so pripravljeni in dokazani s testom. Stanje `Error` ostaja mrtva pot.
  Dokaz: migrator uporabi `046`, 2. zagon nobene, `--verify` izhod 0 (razširjen s preverbo
  stolpca `ErrorClass` in stanja `Superseded`); `scripts\run_tests.ps1 -Filter F8` →
  7 uspeli, 0 padlih; `scripts\run_tests.ps1` → **44 uspeli, 0 preskočenih, 0 padlih**;
  `dotnet build PIM_Solution\PIM.sln -warnaserror` → 0 opozoril, 0 napak. Dokazi proti bazi
  tečejo v izoliranem podjetju 9808 in za sabo ne pustijo nobene vrstice (preverjeno).

- **[IZVOZ]** Magento predloga se je preselila iz C# v register `out.ExportProfile` /
  `out.ExportColumn` — kdo: Claude Opus 5 — 2026-08-21, migracija
  `045_MagentoExportProfileRows.sql`.
  Prej sta obliko izvoza določala seznam 215 nizov v `MagentoCsvContract` in `switch`
  `MagentoProductSchema.GetCanonicalCode`; nov spletni kanal ali samo premaknjen stolpec
  sta bila zato nova različica programa. Zdaj sta profila `MAGENTO_PRODUCTS` (215 vrstic)
  in `MAGENTO_CUSTOMERS` (19 vrstic) vrstice v bazi, `ExportProfileRegistry` pa ju prebere.
  Nov kanal = profil + vrstice; premik stolpca = `UPDATE SortOrder`; drug vir =
  `UPDATE CanonicalFieldCode`; stolpec ven = `UPDATE IsActive = 0`.
  V kodi ostanejo poizvedbe, ki kanonične vrednosti proizvedejo — register pove, kam
  gredo, ne kako nastanejo. Nov kanonični podatek je torej še vedno koda.
  **Dokaz, da to ni le trditev:** nov test posadi profil `F7_KANAL_PROBE`, ki ga program
  nikjer ne pozna, in prek istega zapisovalnika dobi datoteko z njegovimi glavami, njegovim
  vrstnim redom in preskočenim izklopljenim stolpcem; za sabo profil pobriše. Drugi nov
  test primerja 215 glav iz registra s predlogo znak za znak, vključno s končnim presledkom
  v glavi 73. **Negativni preizkus:** z ročno izklopljenim `COL033` `PIM.F7.MagentoExportTests`
  pade (`Program.cs:125`), po vrnitvi `IsActive = 1` spet uspe — izvoz res visi na registru.
  **Kar je register naredil vidno in ni popravljeno:** glava `Frekvenca` je v predlogi
  dvakrat (stolpca 58 in 122), zato oba dobita `Attr.Frekvenca` in isto vrednost. Doslej je
  bilo to skrito v izrazu `"Attr." + glava`. Popravek je en `UPDATE`, ko bo znano, kaj sodi
  v drugega — ugibati ne smem.
  Dokaz: migrator uporabi `045`, 2. zagon nobene, `--verify` izhod 0;
  `scripts\run_tests.ps1` → **44 uspeli, 0 preskočenih, 0 padlih**;
  `dotnet build PIM_Solution\PIM.sln -warnaserror` → 0 opozoril, 0 napak.

- **[BAZA]** Hitrost `map.ProcessRawInbox`: ugnezdeni kurzor zamenjan z množično obdelavo —
  kdo: Claude Opus 5 — 2026-08-21, migracija `044_BulkProcessRawInbox.sql`.
  **Merjeno pred in po, z istim merilom in istimi podatki**
  (`PIM_Solution\tools\Bench-ProcessRawInbox.sql`, novo — ustvari svoj konektor, svojo
  vhodno vrstico in @N zapisov, izmeri, prebere kaj je nastalo in za sabo pobriše vse svoje
  vrstice; preveri, da je ostankov 0):
  - 2.000 zapisov **pred**: 219.347 ms = **9,1 zapisa/s** (potrjuje ~8/s s prejšnje meritve);
  - 2.000 zapisov **po**: 1.145 ms = **1.747 zapisov/s** → **192×**;
  - 20.000 zapisov **po**: 9.306 ms = **2.149 zapisov/s** (raste linearno, ne kvadratno).
  Za 200.000 artiklov to pomeni okrog **1,5 minute** namesto okrog 6 ur.
  Odpravljena vzroka: (1) na vsak zapis je tekel obhod s petimi `MERGE`, enim `UPDATE` in
  dvema iskanjema izdelka; (2) vsak od teh stavkov je posebej sprožil sledilne prožilce, ki
  vsak zase vzamejo `UPDLOCK/HOLDLOCK` na `pim.ProductChangeBatch` — pri 2.000 zapisih
  8.000 svežnjev, zdaj 4. Dodan je tudi indeks `canon.Product(OrganizationId, EAN)`; iskanje
  po EAN je bilo edino brez indeksa.
  **Kar se ni spremenilo:** pravila in besedila zavrnitev, vrstni red preverjanj, pravica
  ERP vira do ustvarjanja artikla, karantena celotne vhodne vrstice ob napaki, besedilo
  `FailureReason` in števci. Vhodne vrstice se še vedno obdelujejo ena za drugo, ker so
  nosilec izolacije napake.
  **Kar se je spremenilo in je treba vedeti:** zgodovina sprememb dobi en svežnj
  (`pim.ProductChangeBatch`) na vhodno vrstico namesto enega na zapis; vsebina
  (`pim.ProductFieldHistory`) je ista.
  Nov varovalni test `PIM.F3.Integration` (dva zapisa iste šifre v isti strani → en artikel,
  polje prvega zapisa ohranjeno, polje in naziv drugega obveljata) — to je edino pravilo, ki
  ga je prej nosil vrstni red kurzorja in ga mora množična obdelava izraziti izrecno.
  Dokaz: migrator 1. zagon uporabi `044`, 2. zagon nobene, `--verify` izhod 0;
  `scripts\run_tests.ps1 -Filter F3` → 4 uspeli, 0 preskočenih, 0 padlih;
  `scripts\run_tests.ps1` → **44 uspeli, 0 preskočenih, 0 padlih**.

- **[INFRASTRUKTURA]** Node scaffold izbrisan in CI prevezan na .NET — kdo:
  Claude Opus 5, na izrecno zahtevo uporabnika — 2026-08-20. Odstranjeni:
  `package.json`, `package-lock.json`, `node_modules\` (26 MB), `src\index.js`
  (`sestej(a,b)`), `tests\index.test.js` (`sestej(2,3) === 5`). Nič od tega ni
  bilo sledeno v Gitu. `PIM_Solution\src\` in 46 testnih projektov nedotaknjeni.
  **Zakaj se je scaffold vrnil, čeprav je bil 2026-08-12 že arhiviran:**
  `.github\workflows\ci.yml` ga je še vedno zahteval — poganjal je `npm ci` in
  `npm test` in ni prevedel niti ene .NET vrstice. CI zdaj na `windows-latest`
  prevede `PIM_Solution\PIM.sln` z `-warnaserror` in pade, če se scaffold vrne.
  Dokaz: `dotnet build PIM_Solution\PIM.sln -warnaserror` → 0 opozoril, 0 napak,
  53 projektov; `scripts\run_tests.ps1` → 44 uspeli, 0 preskočenih, 0 padlih.
  **Nepreverjeno:** delovni tok GitHub Actions na tem računalniku ni bil zagnan
  (brez `git push`), zato je preverjena vsebina ukazov, ne pa sam zagon v CI.

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

  > **PREKLICANO 2026-08-20 — ta naloga NI končana.** Navedeni dokaz ne dokazuje
  > tega ukaza. `PIM.F7.MagentoExportTests` pokriva samo `MagentoCsvContract` v
  > `PIM.B2b` (v njegovem `bin\` je zgolj `PIM.B2b.dll`) in ni v `PIM.sln`, zato ga
  > `dotnet build PIM.sln` sploh ne prevede, `run_tests.ps1` pa ga poganja z
  > `--no-build` — lahko poroča zeleno iz zastarelih binarnih datotek.
  > Sam ukaz `--export-magento` ni bil nikoli izveden. Codex je v neodvisnem
  > pregledu našel dve napaki, obe potrjeni proti kodi, migracijam in bazi:
  >
  > 1. **Ukaz sploh ne more teči.** `MagentoExportCommand.cs:55` bere
  >    `prb2c.VatRate`, podpoizvedba `prb2c` pa izbere samo `PimProductId`, `Net`
  >    in `rn` — SQL se ne prevede („Invalid column name"). Pri `prb2b` je
  >    `VatRate` prisoten, pri `prb2c` je izpadel.
  > 2. **Glavna slika ne bi bila nikoli izpolnjena.** `MagentoExportCommand.cs:143`
  >    primerja vlogo z `MAIN`, migracije 012/013/016/017/040/042 pa dosledno
  >    vstavljajo `PRIMARY`; v `canon.ProductMedia` je dejansko `Primary`.
  >    Vsaka slika bi torej pristala v `Product.OtherImages`, obvezni Magento
  >    stolpec za glavno sliko pa bi ostal prazen.
  >
  > Naloga se vrne v TODO za področje IZVOZ; popravek mora spremljati test, ki
  > dejansko izvede `--export-magento` proti razvojni bazi.

- **[DOMENA/IZVOZ]** Magento CSV izvoz — obe napaki odpravljeni in prvič dokazano
  izveden proti bazi — kdo: Claude Opus 5 (izvedba), Codex (neodvisni QA) —
  2026-08-20. To nadomešča preklicano vrstico zgoraj.
  1. `prb2c` podpoizvedba zdaj izbere `VatRate`, ki ga zunanji `COALESCE` bere.
     Brez tega se SQL ni prevedel in ukaz ni zajel niti ene vrstice.
  2. Vloga glavne slike se ugotavlja z `IsPrimaryMediaRole`: `PRIMARY` in `MAIN`,
     neobčutljivo na velikost črk, ker migracije pišejo `PRIMARY`, v
     `canon.ProductMedia` pa so tudi vrstice `Primary`. Vrstni red medijev je
     zdaj `SortOrder` in ne `Role` — prej bi ob več glavnih slikah izbral
     abecedno prvo vlogo namesto najnižjega `SortOrder`.
  3. **Vzrok, da tega ni ujel noben test:** obstajali sta dve vzporedni definiciji
     glav — `MagentoCsvContract` (215/19, testirana, a jo uporablja samo mrtvi
     `MagentoExportRunner`) in `MagentoProductSchema`/`MagentoCustomerSchema`
     (uporablja ju pravi ukaz, netestirani). Bili sta znakovno enaki, a nevezani.
     Zdaj sta shemi izpeljani iz pogodbe — en sam vir resnice.
  4. `PIM.F7.MagentoExportTests` je dodan v `PIM.sln` in dobi referenco na
     `PIM.B2bWorker`; prej je pokrival samo `PIM.B2b` in ga `dotnet build PIM.sln`
     sploh ni prevajal.
  Dokaz RED→GREEN, oba popravka posebej: z odstranjenim `VatRate` test pade;
  z vlogo vrnjeno na `role == "MAIN"` test pade; z obema popravkoma gre skozi.
  Test zdaj dejansko izvede `MagentoExportCommand.ExecuteAsync` proti bazi:
  **18 izdelkov, 0 strank**, glavna slika za `ACB.A3660001N` pravilno napolnjena,
  ostale slike brez podvojene glavne; 215 in 19 stolpcev preverjenih z RFC 4180
  razčlenjevalnikom, ne z `Split(',')`. Test si sam doda dva medija in ju za sabo
  pobriše. `scripts\run_tests.ps1` → **44 uspeli, 0 preskočenih, 0 padlih**;
  `dotnet build PIM.sln -warnaserror` → 0 opozoril, 0 napak.
  5. **Sedem nadaljnjih napak iz osmih Codexovih krogov**, vse potrjene proti shemi
     in vse dokazane z RED→GREEN: prihodnja cena (`ValidFrom` v prihodnosti) se je
     izvozila namesto tekoče; izklopljen prag stranke (`IsActive=0`) je povozil
     privzetega; potekel in prihodnji skupinski rabat sta se izvozila; `B2B+` se je
     izvozil kot `1` tudi s poteklim oknom; izklopljen katalog pakirnih popustov
     (`IsActive=0`) se je še vedno izvozil; stolpca `Kategorije vid ANG/SLO` sta
     ostajala prazna, čeprav so poti v `pim.ProductCategory` obstajale; par datotek
     je bilo mogoče objaviti na pol.
  6. Par datotek je zdaj nedeljiv: enolična začasna imena, ključavnica na izhodni
     mapi, povratek na prejšnji par ob vsaki napaki in oznaka `magento-export.complete`,
     ki porabniku pove, kdaj je par popoln.
  **Nepreverjeno:** izvoz na razvojnih podatkih vrne 18 izdelkov in 1 stranko, pri
  čemer si stranko ustvari test sam — `pim.CustomerWebProfile` v razvojni bazi nima
  nobene vrstice z `WebEnabled=1`. Popolna atomarnost proti bralcu, ki oznako
  ignorira, ni mogoča z dvema preimenovanjema; dokončna rešitev je odvisna od načina
  dostave na splet, ki še ni določen.

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
