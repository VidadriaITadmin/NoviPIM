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

> Vrstni red spodnjih petih postavk je priporočilo iz meritve 2026-08-22
> ([`docs/ANALIZA_A_B_C.md`](docs/ANALIZA_A_B_C.md)) — od najcenejšega učinka navzdol.

- **[WORKERJI] 1. Ponovna preslikava zajetih strani za trgovinske podatke.** Migracija
  **057** je uporabljena in doda 11 preslikav v `canon.ProductCommercial`, tabela pa ima
  **1 vrstico**: zajete strani so že `Processed`, zato jih nova preslikava ne vidi.
  Potreben je `--map-run <RunId>` ali `--full`. Odklene stolpce 10–23 Magento izvoza in
  profile `ERP_L1_EU`, `ERP_L1_THIRD`, `COMMERCIAL_L2`, ki so danes pri **1 veljavnem
  artiklu od 115.685**.
- **[WORKERJI] 2. Preslikava `GetItemsTitlesLanguage`.** 45 strani čaka kot `Pending`.
  To so spletni nazivi — stolpec „Naziv artikla" ima danes izpolnjen **1 izdelek od 1.728**.
  Brez tega spletni izvoz ni uporaben, ne glede na atribute.
- **[WORKERJI] 3. Poln zajem NW in BT XML.** Mehanizem je cel (049 pretvorbe in slovar,
  054/055 preslikave), pognan pa je bil samo za vzorec: BT_XML **ena stran**,
  `canon.ProductAttribute` ima **1.064 vrstic za 27 izdelkov**. To je največji razkorak
  med „narejeno" in „teče" v celotnem sistemu.
- **[BAZA / odločitev] 4. Kateri profil je vstopnica za objavo** in objava za organizaciji
  3 in 4. Danes je vstopnica stari `ERP_L1` → **44.510 VALID**; po `ERP_L1_SLO` bi jih bilo
  **100.809**. Vidadria (3) in Ediito (4) imata **0** objavljenih artiklov. Migracija 058 te
  odločitve nalašč ni sprejela — je poslovna, ne tehnična.
- **[ODHODNA POT / odločitev] Vrstica `OUTBOUND` v `ops.ScheduleProfile` — namerno še ni
  dodana.** Preverjeno 2026-08-22 v `WatchdogRules.Evaluate`: ko za omogočen razpored obstaja
  vrstica v `ops.IntegrationHealth` z `LastHeartbeatUtc` starejšim od `StaleAfterSeconds`,
  nastane **Critical `StaleHeartbeat`**. Dispatcherja ne poganja nič po urniku (Scheduled Task
  je na zaprtem seznamu `AGENTS.md` §4.7), zato bi vklop razporeda po prvem zagonu naredil
  trajen kritičen alarm za pot, ki je nihče ne poganja. Razpored zato sodi v isti korak kot
  odločitev, kaj dispatcherja sploh zaganja — to je tvoja odločitev, ne tehnična.
- **[ODHODNA POT] 5. Proizvajalec sporočil za outbox.** `out.OutboxMessage` ima **0**
  vrstic in nihče vanjo ne piše — ne intranet, ne preslikava, ne razveljavitev. Dokler
  proizvajalca ni, sta dodelava dispatcherja in urnik brezpredmetna. Za tem šele:
  zanka v `PIM.OutboxDispatcher\Program.cs` (danes obdela **eno** sporočilo in konča)
  in vrstica `OUTBOUND` v `ops.ScheduleProfile` (danes je ni).
- **[BAZA] Počistiti rep meritve 2026-08-22:** dva zagona `F5_INTEGRATION` obtičala
  v `ops.PipelineRun` kot `Running` brez
  `EndedUtc`; `dbo.SchemaMigration` vsebuje zapisa `047_ValueDictionaryAndTransforms.sql`
  in `048_ValueDictionaryAndTransforms.sql`, ki kot datoteki ne obstajata (preimenovani
  v 049) — `--verify` kljub temu vrne 0.

- **[WORKERJI]** Preslikave za 13 še nepreslikanih SAOP končnih točk (2026-08-22: **294 strani `Pending`**). Zajem dela za
  vseh 16, preslikava v `canon` je nastavljena za `GetItemsGeneralData`, `GetPrices`
  in `GetItemsDescriptions`. Za šest končnih točk oblika XML ni znana — v posnetih
  odgovorih ni bilo vsebine, zato se preslikava zanje piše šele po prvem živem zajemu.
  Šifranti (`Currencies`, `PriceLists`, `Warehouses`, `GetLanguages`) in B2B
  (`Customers`, `GetItemCustomerDataV2`, `CustomerItemGroupDiscounts`) nimajo cilja v
  `map.ProcessRawInbox` — potrebujejo odločitev, kam v modelu spadajo.
  Od 2026-08-20 to ni več tiho: zajem teh entitet mejnika ne premakne, zato bo prvi
  zagon po dodani preslikavi isto obdobje zajel znova. Prej bi bilo trajno izgubljeno.
- **[WORKERJI]** `PIM.StockFileWorker` dobi pravi `Program.cs`; pri `PIM.B2bWorker`
  manjka **landing pot**, ne cel worker. Popravljeno 2026-08-22: `PIM.B2bWorker\Program.cs`
  obstaja in dela — podpira `--export-magento` in je bil v tej meritvi pognan v živo.
  Kar ne obstaja, je pot za `StockLandingWriter` in `B2bLandingWriter`: pisalna logika je
  dokazana, a jo kliče samo test in worker sam v bazo ne piše ničesar.
- **[WORKERJI]** Dostava datotek dobavitelja: `PIM.StockFileWorker` zdaj zna zapisati
  zalogo v bazo, datoteko pa mu je treba še vedno položiti v mapo. Prevzem s FTP oziroma
  drugega vira dobavitelja je zunanji klic (`AGENTS.md` §4.5) in čaka na odločitev.
- **[WORKERJI]** Preslikave za preostale šifrante (`Currencies`, `PriceLists`,
  `GetLanguages`) in B2B entitete. Pot je od migracije `064` znana: nova vrstica v registru s
  svojim `TargetDomain` in svoj postopek, brez posega v postopek za izdelke. Kam v modelu
  spadajo, je še vedno odločitev uporabnika (`docs/TVOJE_NALOGE.md`, naloga 5).

## DELAM (v teku)

_(prazno)_

## BLOKIRANO

- **[IZVOZ]** ~~162 atributnih stolpcev Magento predloge nima vira~~ — **preklicano
  2026-08-22, blokada je iz 2026-08-20 in je bila medtem odpravljena.** Odgovor je
  zapisan kot vrstice registra v migracijah **054** (Nowodvorski, 108 preslikav) in
  **055** (Braytron, 76). Merjeno v bazi: od **160** atributnih stolpcev aktivnega
  profila jih ima vir **156**.
  **Kar od te blokade ostane, je ožje in še vedno čaka tvojo odločitev:**
  1. **4 atributni stolpci** brez vira v `map.FieldMapping`.
  2. **31 stolpcev sploh nima kanonične kode** (dva sta dobila vir 2026-08-22:
     `Kategorije svetila ANG/SLO`, migracija `059`) — zanje ni odločeno, od kod pridejo:
     `Dobavitelj`, `ABC klasifikacija`, `Merska enota`, enote teže/volumna/paketa,
     `Popust`, `Valuta`, `Omejitev pri naročanju`,
     `Posebni popust za stranko`, dokumenti (3), zaloge `VID *` (7), dobaviteljeva
     zaloga (3), `Skladišče`.
  3. **`slug=sensor_type` pri Braytronu** ('Motion', 'PIR', 'Microwave') ni Da/Ne in ni
     isto kot stolpec `Senzor gibanja` — migracija 055 ga zato nalašč ne preslika.

- **[WORKERJI / Agent B]** `PIM.B2bWorker` dobi **landing** pot — blokirano
  2026-08-20: `B2bLandingWriter` že zna atomarno zapisati en JSON zapis, toda
  repozitorij ne določa lokalnega execution contracta workerja (vhodne datoteke
  oziroma fixture, argumenti/okoljske nastavitve za `OrganizationId`, `SourceCode`,
  `EntityType` in stabilni `SourceRecordKey`, ter obravnava podvojenega landing
  ključa). `docs/WORKERS.md` ga izrecno označuje kot fixture-only in brez potrjenega
  contracta. Implementacija bi te vrednosti izumila, zato je Agent B ne začne.

## KONČANO

- **[IZVOZ]** Dobavitelj in merska enota prideta do izvoza — kdo: Claude Opus 5 — 2026-08-23,
  migracija `077`. Stolpca 7 in 9 sta bila prazna, čeprav podatka v katalogu obstajata od prvega
  zajema (`canon.Product.Supplier`, `canon.Product.UoM`). Objava (`pim.Product`) ju ni poznala —
  tabela je imela šifro, EAN, naziv in proizvajalca. Izvoz bere objavo, ne kataloga; isti razred
  napake kot `058`, `075` in `077`.
  Merska enota je hkrati obvezno polje profila `ERP_L1_SLO`, zato je bila njena odsotnost v
  izvozu še posebej zavajajoča: validacija je izdelek priznala, izvoz pa je stolpec pustil prazen.
  Rezultat: **43.502 izdelkov z dobaviteljem in mersko enoto**; izvoz ima **165 od 213** polnih
  stolpcev. **Opomba:** dobavitelj je šifra (`91086973`), ne ime — šifranta dobaviteljev SAOP med
  16 končnimi točkami ne pošilja.

- **[ZAJEM]** Lastnosti po meri, pravilo najmanjše/največje zaloge in ločena naziva — kdo:
  Claude Opus 5 — 2026-08-23, migracija `076`.
  **Lastnosti po meri** (`GetItemsCustomProperties`, 10 strani, ki so čakale od prvega zajema):
  zapis je par — ime lastnosti in vrednost. Isti razlog za svoj postopek kot pri nazivih: ključ
  pride iz podatka, ne iz imena ciljne kode. Ime lastnosti se ne prevaja — kar SAOP imenuje
  `BUG`, se v katalogu imenuje `BUG` (3.841 izdelkov).
  **Pravilo zaloge** (`GetItemsStockData`, 5 strani): to ni količina na zalogi, ampak koliko naj
  bi je bilo. Zato svoja tabela `canon.ProductStockPolicy` in ne `stock.*`, kjer živijo posnetki
  količin. **2.099 pravil pri 2.097 izdelkih v treh skladiščih.**
  **ERP naziv in spletni naziv sta različna** — odločitev uporabnika 2026-08-23. Migracija `074`
  je ERP naziv uporabila kot rezervo za spletni stolpec; to je zdaj odpravljeno. `pim.Product.Name`
  ostaja ERP naziv (in ima ga 43.502 od 43.503 izdelkov), stolpca »Naziv artikla« in »Naziv
  artikla EN« pa polni izključno `WEB_TITLE`. Danes sta zato prazna — in to je resnica: spletnih
  nazivov v katalogu (še) ni.
  Izvoz: polnih **163 od 213 stolpcev**.

- **[ZAJEM/IZVOZ]** Nazivi po jezikih, šifrant jezikov in trgovinski podatki do izvoza — kdo:
  Claude Opus 5 — 2026-08-23, migracije `072`–`075`.
  **Šifrant jezikov (`072`).** SAOP govori v šifrah (1, 2, 3), katalog v kodah jezika
  (`sl`, `en`, `de`), ker tako je zapisan `canon.ProductText.Lang`. Prevod imena v kodo je
  vrstica slovarja (`map.ValueLookup`, domena `SAOP jezik`), ne veja v programu. Pet jezikov
  pri vseh štirih podjetjih.
  **Nazivi po jezikih (`072`).** `map.ProcessRawInbox` tega ne zna, ker jezik pozna samo kot del
  imena ciljne kode; tu pride iz podatka. Zato svoj postopek `map.ProcessProductTextInbox`, po
  vzorcu skladišč. Šifra artikla je v tem odgovoru en nivo višje, zato pot `../../ItemID` —
  XPath 1.0 to zna in nova koda ni bila potrebna.
  Rezultat: **angleških nazivov 67.880**, nemških 12.349, hrvaških 12.398, drugih vrstic naziva
  (`TITLE_ERP2`) 83.281. 45 strani, ki so čakale od prvega zajema, je obdelanih.
  **Kar je razkrila ista pot:** ponovna preslikava je uveljavila tudi preslikave iz `057` —
  `canon.ProductCommercial` ima **196.513 vrstic namesto ene**. Trgovinski podatki so bili
  preslikani avgusta, a nikoli pognani čez že zajete strani.
  **Tri napake, ki so bile do zdaj nevidne:**
  1. `073` — `TITLE_ERP2` ni bil dovoljena vrsta besedila, zato je 92.735 izluščenih vrednosti
     padlo na `CK_CanonProductText_Type`. Naziv ima v SAOP dve vrstici in obe sta naziv.
  2. `074` — `pim.Product.Name` je bil `NULL` pri **vseh** izdelkih: objava ga je brala samo iz
     spletnega naziva, teh pa je v katalogu ena sama vrstica. Stolpec »Naziv artikla« je bil
     zato prazen pri 43.503 izdelkih, čeprav naziv obstaja pri 196.515. Odslej velja: spletni
     naziv, če obstaja, sicer ERP naziv istega jezika.
  3. `075` — objava ni nesla volumna in mer pakiranja: stolpci so bili dodani v `canon`
     (migracija `057`), v `pim.ProductCommercial` pa ne. Isti razred napake kot `058`, eno
     nadstropje nižje.
  **Izvoz:** polnih **165 od 213 stolpcev** (prej 156). Naziv 43.502, angleški naziv 11.193,
  volumen in mere pakiranja 43.502, enota mer 41.555.
  Nov ukaz `--znova-preslikaj <RunId>` tudi v `PIM.KatalogWorker` (prej samo v XML workerju).

- **[ZAJEM]** Dobavitelj se veže na vsa štiri podjetja — kdo: Claude Opus 5 — 2026-08-23,
  migraciji `069` in `070`. Odločitev uporabnika: dobavitelj ni last enega podjetja; njegov XML
  se poveže z vsemi štirimi katalogi po EAN.
  Konektorja `NW_XML` in `BT_XML` sta bila registrirana samo pri podjetju 2, zato je Vidadria
  ostala brez vsega, čeprav ima **več** ujemanj kot IQLighting. Prepis entitet, preslikav in
  pretvorb je narejen iz konektorja podjetja 2, ne na novo — vir resnice ostane ena, že
  dokazana nastavitev.
  **Ob tem je padla ista varovalka kot 2026-08-20 pri SAOP:** `ops.BeginRun` je zavrnil zagon z
  »Razpored ni omogočen«, ker je `GENERIC_XML` imelo vrstico v `ops.ScheduleProfile` samo pri
  podjetju 2. Varovalke nismo obšli; register je dopolnjen (`070`), kot je bilo takrat storjeno
  z `043`.
  **Izmerjeno po zagonu vseh šestih kombinacij:** Vidadria 2.571 (NW) + 1.086 (BT) obogatenih,
  DEMO 1.145 + 7, Ediito 0 (njenih EAN-ov v datotekah dobaviteljev ni). Lastnosti ima zdaj
  **7.645 izdelkov** namesto 2.835: Vidadria 3.657 (143.493 vrstic), IQLighting 2.835 (112.819),
  DEMO 1.153 (45.959). Kategorijo ima 6.254 izdelkov, sliko 6.261.
  **Kar ostaja odprto in je zdaj vidno v številkah:** zapisi brez ujemanja (Braytron 1.996 pri
  Vidadrii, Nowodvorski 48) so nove dobaviteljeve šifre. Te ne smejo v katalog mimo SAOP —
  šifra artikla je last SAOP (`068`), zato dobaviteljev konektor ostaja `CanCreateProducts = 0`.
  Pot zanje je opisana v `docs/TVOJE_NALOGE.md` in čaka na potrditveni seznam.

- **[ODHODNA POT]** C8: lastništvo polj iz preglednice — kdo: Claude Opus 5 — 2026-08-22,
  migracija `068`. **To je bil manjkajoči kos odhodne poti, ne dispatcher.**
  `out.EnqueueMessage` zavrne vsako spremembo, za katero ni vrstice v `out.OwnershipPolicy` z
  `Owner = 'PIM'` (napaka 51010); tabela je bila prazna, zato v `out.OutboxMessage` ni moglo
  nikoli vstopiti nobeno sporočilo. Zdaj je napolnjena iz stolpcev »Smer« in »Master« v
  `Mapiranje_SAOP_API_PIM.xlsx`: od 259 polj s smerjo je 50 pisljivih.
  **Pravilo O9 je izvedeno in ne le zapisano:** pravica nastane samo za polja, ki imajo aktivno
  vhodno preslikavo — česar ne beremo nazaj, ne moremo preveriti, zato ne sme biti pisljivo.
  Rezultat: **20 polj s pravico do pisanja in 8 samo za branje** na podjetje. Polja, ki so po
  preglednici pisljiva, a jih (še) ne beremo, pravice ne dobijo; ko preslikava nastane, jo
  dobijo brez spremembe kode.
  Dokaz: nov `PIM.F8.OwnershipPolicyTests` — preveri pravilo O9 nad celotno tabelo, potrdi
  `Product.ItemID` kot pisljiv in `ProductPrice.Net` kot samo za branje, nato v transakciji, ki
  se povrne, res pošlje eno spremembo skozi `out.EnqueueMessage` in dokaže, da druga pade s
  51010; v bazi ne ostane nobeno sporočilo.
  **Kar ni zajeto:** stranke (10 pisljivih polj lista »Stranke«) — odhodna pot za stranke danes
  ne obstaja, `TargetKind` bi bil `SAOP_CUSTOMER`.

- **[PREVODI]** Delovni list s predlogi prevodov — kdo: Claude Opus 5 — 2026-08-22.
  `map.MissingTranslation` ima **213 vrednosti v 16 lastnostih**, ki v izvozu ostanejo v
  angleščini. Nastal je `PIM_Solution\docs\Prevodi_predlog.csv`: za vsako vrednost lastnost,
  jezik, število izdelkov, kandidati iz uporabnikove preglednice in **moj predlog**.
  Predlog je pri **120 od 213 vrstic**, kar pokrije **96 % pojavitev** (19.036 od 19.792).
  Oblika je izbrana po lastnosti, ker je od nje odvisna: barva je ženskega spola (`White` →
  `bela`), material je samostalnik (`Painted steel` → `barvano jeklo`), tehnične oznake
  materialov (`PC+PC`, `FPCB`) pa ostanejo, kot so.

- **[WORKERJI/BAZA]** Zaloga iz SAOP: šifrant skladišč, profili in worker, ki ni več izpis —
  kdo: Claude Opus 5 — 2026-08-22, migracije `064`, `065`, `066`.
  **Kaj se je pokazalo najprej:** med šestnajstimi zajetimi končnimi točkami dejanskih količin
  ni. `GetItemsStockData` nosi najmanjšo in največjo zalogo po skladišču,
  `GetItemsStockAccountingData` pa konte. Količine so na ločenem vmesniku, zato je bila naloga
  drugačna, kot je izgledala: ne »preslikaj že zajeto«, ampak »napiši pot do vmesnika, ki ga
  še nismo klicali«.
  **Šifrant skladišč (`064`).** `canon.Warehouse` s šifro in imenom — DEMO 7, IQLighting 35,
  Vidadria 74, Ediito 15. Podatek je bil že zajet in je čakal v `raw.Inbox`; nov klic ni bil
  potreben. Ob tem je register dobil razliko med šifrantom in izdelkom
  (`map.EntityMapping.TargetDomain`): `map.ProcessRawInbox` zna samo izdelke in bi skladišče
  zavrnil kot artikel brez šifre, zato ga zdaj preskoči, obdela pa ga
  `map.ProcessWarehouseInbox`. Isti vzorec je odslej pot za valute, cenike in jezike.
  **Profili (`065`, `066`).** Odločitev uporabnika: `GetStocks` za vsa štiri podjetja,
  `RegisteredViewData` za Vidadrio (dela samo tam). Registrirani pogled je vpisan izklopljen,
  ker njegove šifre ne poznamo — dobi se z živim klicem `api/registeredviews`. Skladišča se
  jemljejo iz registra (`ActiveFromRegister`); v zahtevo gre samo šifra, ime je za prikaz.
  Zaloga ima svoje konektorje (`SAOP_*_STOCK`) in pravila identitete po šifri artikla brez
  predpone — SAOP pošlje našo šifro, dobavitelj tujo.
  **Napaka, ki jo je razkrilo pisanje workerja:** `SaopStockProviderRegistry` je za `GetStocks`
  in `StockAdvance` gradil `POST` z JSON telesom. Swagger SAOP pravi `GET` s parametri v naslovu
  in odgovorom v XML. Klica ni nikoli nihče izvedel, zato je bila napaka nevidna.
  **Dokaz brez živega SAOP:** nov `PIM.F6.SaopStockIntegration` v izoliranem podjetju 9606 —
  lokalni strežnik na `127.0.0.1` vrne odgovor in posname zahtevo. Preverjeno: zahteva gre na
  `api/Stock/GetStocks`, nosi šifre skladišč in ne imen, ima glavo `OrganisationId`, znan
  artikel dobi pozicijo s količino, neznan pa pozicijo brez izdelka (`MatchKey = 'Unmatched'`)
  namesto da bi izginil. Test za sabo pobriše vse svoje vrstice.
  **Kar ostane človeku:** šifra registriranega pogleda za Vidadrio in prvi živi klic
  (`PIM_SAOP_MODE=Live`), oboje po `AGENTS.md` §4.5.
  Ob tem se je `StockLandingWriter` preselil iz `PIM.StockFileWorker` v `src\PIM.StockMapping`:
  pisalna pot je skupna vsem virom zaloge, sicer bi worker referenciral drugega workerja.

- **[WORKERJI/TESTI]** Zaloga dobavitelja pride v bazo; paket brez baze ne laže več — kdo:
  Claude Opus 5 — 2026-08-22.
  **`PIM.StockFileWorker` je dobil pravi `Program.cs`.** Bralna stran (NW CSV, BT XML) in
  pisalna stran (`StockLandingWriter`, `stock.ApplyLandingRecord`) sta obstajali in bili
  dokazani, manjkal je zapisan vhodni dogovor — čigava zaloga je in v kateri vir gre. Zdaj:
  `--file <pot>` z izbirnimi `--source`, `--organization-id`, `--endpoint`, `--date-format`
  in `--samo-preberi`. Vir se privzeto ugane iz končnice (`.xml` = Braytron, ostalo =
  Nowodvorski CSV), oblika datuma iz vira (Braytron ISO, Nowodvorski evropsko). Konektorja in
  pravila identitete si worker ne izmišlja — morata biti v registru.
  Dokaz proti bazi: `NOWODVORSKI.csv` → 2.697 uporabljenih, 0 v karanteni;
  `Braytron_stocks.xml` → 1.361 uporabljenih, 0 v karanteni. Vhodni dogovor pokriva
  `PIM.F6.FileWorkerTests` (privzetki, prevlada `--source`, pet napačnih klicev).
  **Kar ostaja:** datoteko je treba položiti v mapo; prevzem s FTP je zunanji klic.
  **Pet projektov, ki so brez baze padli, se zdaj preskoči.** Izmerjeno z odmaknjenim
  `appsettings.Local.json` in praznim `PIM_CONNECTION_STRING`: prej izhod 1, 38 uspeli,
  1 preskočen, **5 padlih**; zdaj **izhod 0, 36 uspeli, 10 preskočenih, 0 padlih**.
  Preskoči se samo, kadar povezave ni nikjer; kjer je nastavljena, dokaz teče kot prej, in
  izpis paketa izrecno pove, da preskočeno ni dokaz. Popravljenih je osem projektov (pet s
  table, plus `PIM.F5.ValueTransformTests`, `PIM.F5.CategoryMappingTests` in
  `PIM.F7.Integration`, ki so padli iz istega razloga).
  **Kar je bilo za to treba prevzeti nazaj:** trije testi so imeli v kodi zapisano »ni
  dovoljeno preskočiti«. Namen te trditve je bil, da se dokaz ne izgubi tiho; ostaja
  izpolnjen, ker se preskoči izključno takrat, ko povezave ni nikjer.

- **[BAZA]** Kategorija ne sme kazati na spletno stran, ki je v registru ni — kdo:
  Claude Opus 5 — 2026-08-22, migracija `063`. Po odobritvi je pobrisana zadnja vrstica
  `canon.ProductCategory` s spletno stranjo `svetila.si` (s piko) in potjo `Svetila/Test`;
  naredil jo je dokazni izdelek `F2-PROOF-001`, ki ga `PIM.F2.Integration` namenoma pušča v
  razvojni bazi, koda pa v registru ne obstaja — od `059` se stran imenuje `svetila_si`.
  Da se ne ponovi, je pravilo zdaj omejitev baze (`FK_ProductCategory_WebSite`), test pa
  uporablja registrirano kodo. Ob tem je `canon.WebSite.WebSiteCode` razširjen na
  `nvarchar(100)`, ker tuji ključ zahteva enak tip kot `canon.ProductCategory.WebSite`.

- **[BAZA]** Enajst poti tračnih sistemov, odstranjene dobaviteljeve kategorije in napaka, ki
  jo je to razkrilo — kdo: Claude Opus 5 — 2026-08-22, migraciji `060` in `062`.
  Uporabnik je potrdil vseh enajst predlogov (`PIM_Solution\docs\Kategorije_manjkajoce.csv`):
  Nowodvorski pošilja te poti na treh ravneh, stari slovar jih je imel na štirih, zato gredo
  v nadrejeno kategorijo, ki v drevesu že obstaja. `map.MissingCategoryMap` je prazen,
  kategorijo ima **2.540 izdelkov** (prej 2.382).
  Ob tem so po odobritvi pobrisane vrstice, ki jih je delala preslikava, izklopljena v `059`
  — 2.541 vrstic `canon.ProductCategory` in enako v `pim.ProductCategory` s spletno stranjo
  `B2C` in dobaviteljevo kategorijo prve ravni v angleščini. Brisanje je omejeno na natanko
  pet znanih poti; kategorije istih izdelkov pod `svetila_si` ostanejo.
  **Napaka, ki jo je to razkrilo (migracija `062`):** vrstice so se ob prvi ponovni preslikavi
  vrnile. `map.ProcessRawInbox` bere `map.ExtractedValue` in ni gledal, ali je preslikava, ki
  je vrednost izluščila, še aktivna — izluščene vrednosti namenoma ostanejo kot sled, zato je
  izklopljena preslikava pisala naprej. `IsActive = 0` je bil s tem samo napol resničen: novih
  vrednosti ni več luščil, stare pa so tekle v katalog. Popravljenih je vseh pet mest, kjer
  postopek bere vrednosti za vpis (identiteta zapisa, preverba cene, zmagovalne vrednosti,
  kategorije, cene); nespremenjeno ostane branje, ki ob karanteni zapiše v `map.UnmappedValue`,
  ker tam je pravilno videti vse, kar je vhodna vrstica nosila.
  Dokaz: po `062` ponovna preslikava istega zajema vrstic pod `B2C` **ne vrne** (prej 2.540),
  `svetila_si` ostane 2.540; migrator uporabi `060` in `062`, 2. zagon nobene, `--verify` 0;
  `scripts\run_tests.ps1` → 46 uspeli, 0 padlih.
  **Opomba za pregled veje:** moja datoteka je bila najprej oštevilčena `061`, kar je trčilo z
  `061_ReleaseRunApplock.sql` druge seje. Preimenovana je v `062`, njena vrstica v
  `dbo.SchemaMigration` pa je bila pobrisana, da se je uporabila pod novim imenom — šlo je za
  mojo vrstico, staro nekaj minut, na tem računalniku.

- **[ODHODNA POT / Agent C + BAZA]** Zanka dispatcherja utrjena; ob tem najdena kljucavnica,
  ki je nihce ni sprostil — kdo: Claude Opus 5 — 2026-08-22.
  **Tri luknje v zanki, ki sem jo dodal v `70c677f`:**
  1. *Zastrupljeno sporočilo je zaprlo vso vrsto.* Lovljena je bila samo `HttpRequestException`
     in `TaskCanceledException`. `out.ClaimMessage` bere vrsto po `OutboxMessageId`, zato bi
     eno sporočilo s pokvarjeno nastavitvijo (`HttpOperation`, ki ni POST/PATCH, neveljaven
     `EndpointTemplate`) ob **vsakem** zagonu vrglo na istem mestu in nobeno sporočilo za njim
     ne bi prišlo nikoli na vrsto. Zdaj se ujame vsaka izjema; sporočilo gre v `Retry`.
     V bazo gre samo **vrsta** izjeme — sporočilo izjeme lahko nosi naslov s poverilnico.
  2. *Prekrivanje s samim sabo je bilo neobravnavana izjema.* `51101` je za načrtovan worker
     normalno stanje; zdaj se drugi zagon umakne in vrne `AlreadyRunning`.
  3. *Meja `maxMessages` je bila tiha.* Odrezana vrsta je izgledala kot prazna; zdaj se izpiše.
  **Kaj je pri tem prišlo na dan (in je večje):** `ops.BeginRun` vzame `sp_getapplock` z
  `@LockOwner=N'Session'`, `ops.CompleteRun` pa je ni nikoli sprostil. Ker `OperationsRun` svojo
  `SqlConnection` ob `Dispose` vrne v bazen namesto da bi jo ubil, je ključavnica preživela
  logično zapiranje za nedoločen čas. **To zadene vsak worker, ne le dispatcherja** — le da je
  bilo doslej nevidno, ker je vsak worker v svojem procesu opravil eno izvajanje in končal.
  Popravljeno z migracijo **061**.
  **Dokaz — RED:** `PIM.F8.Integration` z novimi trditvami → izhod 82, `Error Number:51101`
  na testovem lastnem `BeginAsync`. Neposredna meritev v eni seji: `po BeginRun Exclusive`,
  `po CompleteRun` **`Exclusive`** — tam bi moralo biti `NoLock`.
  **Dokaz — GREEN:** po 061 `po CompleteRun NoLock` in drugi `BeginRun` v isti seji uspe.
  Testi: **F8 vseh sedem izhod 0**, **F9 vseh šest izhod 0** (drugi uporabnik
  `ops.CompleteRun`), **F3 vsi štirje izhod 0**. Migrator: 1. zagon uporabi 061, 2. zagon
  nobene, `--verify` izhod 0.
  **Trk številk migracij:** moja je najprej nastala kot `060`, ker je druga seja svojo `060`
  uporabila na bazo, ne da bi jo commitala. Preštevilčena v `061`. **V `dbo.SchemaMigration`
  zato ostaja vrstica `060_ReleaseRunApplock.sql`, ki ji datoteka ne pripada** — brisanje je
  na zaprtem seznamu `AGENTS.md` §4.1, zato je nisem odstranil. Isto vrsto ostanka imata že
  `047_ValueDictionaryAndTransforms.sql` in `048_...`.

- **[ODHODNA POT / Agent C]** Dispatcher: razpored pred prevzemom, zanka čez čakalno vrsto in
  prvi test, ki `Program.cs` sploh pokriva — kdo: Claude Opus 5 — 2026-08-22.
  **Napaka, ki je bila najdena:** `ops.BeginRun` vrže `51100 'Razpored ni omogočen.'`, če za
  par (organizacija, `OUTBOUND`) ni omogočene vrstice v `ops.ScheduleProfile` — te vrstice ni
  za nobeno podjetje. `PIM.OutboxDispatcher\Program.cs` pa je klical `out.ClaimMessage`
  **pred** `BeginRun`. Ob prvem resničnem sporočilu bi ga torej prevzel, povečal `AttemptCount`,
  vpisal vrstico v `out.OutboxAttempt` in šele nato umrl — poskus porabljen, zahteva nikoli
  poslana. Ob dovolj ponovitvah bi sporočilo prišlo v `Dead` od poskusov, ki se niso zgodili.
  **Zakaj tega ni ujel noben test:** `F8.DispatcherTests` preizkuša `SaopOutboundHandler` in
  `DispatchClassifier`, `F8.Integration` in `F8.HardeningTests` pa kličeta procedure
  neposredno. `Program.cs` do zdaj ni pokrival noben test.
  **Kaj je spremenjeno:** logika je izluščena v `OutboxDispatchRunner` (zato je sploh
  preizkusljiva); razpored se prebere pred prvim prevzemom in manjkajoč razpored je izid
  zagona, ne izjema; zagoni za vsa podjetja se odprejo pred prvim prevzemom; obdelava je
  zanka do prazne vrste z mejo `maxMessages`; utrip gre po vsakem sporočilu. Sporočilo
  podjetja brez razporeda se ne ubije — zaključi se kot `Transient` in gre v `Retry`,
  ker je to nastavitvena in ne poslovna napaka.
  **Dokaz — RED:** `PIM.F8.Integration` z novimi trditvami → izhod 82,
  `Error Number:51100` iz `OperationsRun.BeginAsync`, klicanega iz
  `OutboxDispatchRunner.RunAsync`.
  **Dokaz — GREEN:** vseh sedem F8 projektov posamično → **izhod 0**
  (`BehaviorTests`, `ContractTests`, `DispatcherTests`, `EchoTests`, `HardeningTests`,
  `Integration`, `IntranetTests`). Build `PIM.OutboxDispatcher` in `PIM.F8.Integration`:
  0 opozoril, 0 napak. Živ zagon workerja proti bazi:
  `Za pipeline OUTBOUND ni omogocenega razporeda v ops.ScheduleProfile; nobeno sporocilo ni
  bilo prevzeto.`, izhod 1 — prej bi na tem mestu crknil s 51100 sredi prevzema.
  Po zagonih: `out.OutboxMessage` 0, `ops.ScheduleProfile` za `OUTBOUND` 0, org 9808 0 —
  test počisti izključno svoje vrstice.
  **Česa NI:** poln `scripts\run_tests.ps1` v tej seji ni bil izveden. Build celotne rešitve
  pade izključno na `MSB3021`/`MSB3027` — druga seja hkrati poganja svoj
  `PIM.F5.CategoryMappingTests` in drži `PIM.XmlMapping.dll` zaklenjeno. Nobene `error CS`;
  po `AGENTS.md` §3 to ni napaka v kodi, tujih procesov pa nisem ustavljal.
  **Ostane:** vrstica `OUTBOUND` v `ops.ScheduleProfile` za prava podjetja (migracija 060,
  čaka, da se sprosti migracijska steza — druga seja ima odprto 059) in vrstica o dispatcherju
  v `docs/WORKERS.md` (datoteka je bila ob commitu odprta v drugi seji).

- **[ZAJEM/IZVOZ]** Dobaviteljev XML se prvič prebere v celoti; kategorije so naše —
  kdo: Claude Opus 5 — 2026-08-22, migracija `059_CategoryTreeAndSupplierMapping.sql`.
  **Kaj je bilo narobe:** preslikave iz migracij `054`/`055` so obstajale, brala pa se je
  samo 336 KB izrezek Nowodvorskega (25 izdelkov) in 30 KB izrezek Braytrona (3 izdelki).
  Polna datoteka (19 MB) je 4. 8. končala v karanteni in od takrat je ni nihče pognal.
  Lastnosti je imelo **29 izdelkov** — zato so bili atributni stolpci izvoza v praksi prazni,
  čeprav je bil mehanizem dokazan.
  **Zakaj polna datoteka ni šla skozi:** trije razlogi, vsi izmerjeni.
  1. `SqlMappingPipeline` je bral strani in preslikave z enim JOIN-om, zato je vsaka vrstica
     nosila cel `PayloadXml`: 37 MB × 112 preslikav ≈ 4 GB po žici za eno stran. Zdaj sta to
     dve poizvedbi in vsebina strani gre po žici enkrat.
  2. `XPathMappingExtractor` je pot prevajal ob vsakem zapisu — 2.619 × 112 = 293.000 prevodov
     istih 112 izrazov. Zdaj se prevede enkrat na preslikavo.
  3. Vsaka izluščena vrednost je bila svoj obhod do strežnika (`IF NOT EXISTS` + `INSERT`),
     torej 293.000 obhodov na stran. Zdaj gredo množično v začasno tabelo, vstavi pa jih en
     stavek z istim pravilom »kar že obstaja, se ne vstavi znova«.
  Merjeno na isti datoteki: prej **prek 20 minut brez konca**, zdaj **110 s** za vse tri
  entitete. `canon.ProductAttribute` 1.064 → **112.820** vrstic, 29 → **2.548** izdelkov.
  Braytron: od 3.082 izdelkov v datoteki jih je 291 v našem katalogu (ujemanje po EAN).
  **Kategorije (naloga 3):** dobaviteljeva kategorija ni naša. Iz stare baze `PIM_test`
  (samo branje) je prenesenih 132 kategorij, 225 prevodov in 190 poti slovarja; nastali so
  `canon.WebSite`, `canon.Category`, `canon.CategoryTranslation`, `map.CategoryPathMap`,
  `map.MissingCategoryMap` in pogled `canon.CategoryPathTranslated`. Ključ poti je isti kot v
  starem sistemu (male črke, presledek je podčrtaj, ravni loči `___`) in pokrije 44 od 56 poti
  Nowodvorskega, kar je 93 % izdelkov; preostalih 11 poti (tračni sistemi, 161 izdelkov) gre
  v `map.MissingCategoryMap` in čaka človeka.
  Katera spletna stran gre v kateri stolpec, je zdaj vrstica v `canon.WebSite` — prej stikalo
  v C# (`"B2C" => SLO`), zaradi katerega je bila nova spletna stran nova različica programa.
  **Izvoz:** polnih **152 od 213 stolpcev** (prej 12). Stolpca 24/25 sta polna pri 2.113
  izdelkih (`Cameleon sistem > Rozete` / `Cameleon System > Canopies`).
  **Nov ukaz** `--znova-preslikaj <RunId>`: iste datoteke ni mogoče zajeti dvakrat (`raw.Inbox`
  je enoličen po vsebini), zato ta ukaz strani zagona postavi nazaj na `Pending` in jih požene
  skozi dopolnjeno preslikavo. Nič ne briše; preslikava je združevalna.
  **Kar namenoma ostaja:** 2.267 starih vrstic `canon.ProductCategory` z dobaviteljevo
  kategorijo pod `B2C`; preslikava, ki jih je delala, je izklopljena, brisanje pa je odločitev
  uporabnika (`AGENTS.md` §4.1).
  Dokaz: migrator uporabi `059`, 2. zagon nobene, `--verify` izhod 0; nov test
  `PIM.F5.CategoryMappingTests` (ključ poti, naša pot v obeh jezikih, delovni seznam neznanih,
  ponoven zagon brez podvojitev), ki za sabo pobriše vse svoje vrstice;
  `dotnet build PIM_Solution\PIM.sln -warnaserror` → 0 opozoril, 0 napak.

- **[IZVOZ]** `MagentoExportRunner.cs` ostane, a je zavarovan — kdo: Claude Opus 5 —
  2026-08-22, odločitev uporabnika (naloga 6). Mrtva koda se ne briše; namesto tega
  `PIM.F7.MappingTests` pade, če se nanjo sklicuje karkoli razen komentarja. RED dokazan z
  začasno datoteko, ki jo uporabi (`sklicujejo se nanj: ZzzRedProbe.cs`), GREEN po njeni
  odstranitvi.

- **[WORKERJI]** `PIM.FoundationWorker` in ostanek `PIM.NwXmlWorker` sta arhiv — kdo:
  Claude Opus 5 — 2026-08-22, odločitev uporabnika (naloga 7). Nič ni pobrisano;
  `FoundationWorker` to pove v svojem izpisu, `NwXmlWorker` pa sta samo še `bin\`/`obj\`,
  ni ne v rešitvi ne v Gitu.

- **[DOKUMENTACIJA]** Analiza treh delov A/B/C proti živi bazi — kdo: Claude Opus 5 —
  2026-08-22. Nastal je [`docs/ANALIZA_A_B_C.md`](docs/ANALIZA_A_B_C.md); `STATUS.md` in
  ta tabla sta popravljena tam, kjer sta bila zastarela.
  **Dokazi:** `dotnet build PIM_Solution\PIM.sln` → **Build succeeded**, 0 napak
  (3× MSB3026, zaklenjena `.dll`, ker je tekel `PIM.F3.Integration`);
  `dotnet run --project src\PIM.Migrator -- --verify` → `Preverjanje F0–F10 baze je
  uspešno.`, izhod **0**; `dotnet run --project workers\PIM.B2bWorker -- --export-magento
  --organization-id 1 --output-dir <temp>` → nastali `magento-products.csv` (**1.729
  vrstic**, 433 KB), `magento-customers.csv` in `magento-export.complete`; ~20 poizvedb nad
  bazo `PIM` (migracija **058**).
  **Kaj je meritev pokazala:** A zajem ~90 % mehanizma / ~55 % v obratovanju,
  B izvoz ~85 % / **~10 %**, C odhodna pot ~50 % / **0 %**. Razkorak ni v kodi, ampak med
  kodo in podatkom.
  **Tri trditve na tabli in v `STATUS.md` so bile napačne** in so popravljene:
  (1) „162 atributnih stolpcev nima vira" — 156 od 160 ga ima (054/055);
  (2) „`canon.ProductCommercial` nima preslikave" — ima jo (057), manjka ponovna preslikava
  zajetih strani; (3) „`val.Promote` polni samo `pim.Product`" — 058 to odpravi,
  `pim.ProductText` 44.511, `pim.ProductPrice` 85.777.
  **Novo, kar prej ni bilo nikjer zapisano:** izvožena datoteka ima vrednost v **15 od 213
  stolpcev**; `out.OutboxMessage`/`OutboxAttempt`/`SaopItemAssignment`/`OwnershipPolicy`
  imajo **0** vrstic; `PIM.OutboxDispatcher` obdela **eno** sporočilo na zagon in nima
  zanke; za `OUTBOUND` ni vrstice v `ops.ScheduleProfile`; objava teče samo za organizaciji
  1 in 2.
  **Ni bilo pognano:** `scripts\run_tests.ps1` (PowerShell, meritev je tekla iz WSL) —
  zadnji znani rezultat ostaja 44/0/0 z dne 2026-08-21.

- **[WORKERJI]** IQLighting dopolnjen: vseh 16 končnih točk, oba popravka potrjena v živo —
  2026-08-21. Prejšnji zagon je umrl po **eni** končni točki v 100 minutah; ta je opravil
  **vseh 16 v 27 minutah** (571.909 zapisov, 131 strani, `Succeeded`, 0 padlih).
  **Kaj je s tem dokazano:**
  1. *Znak življenja po strani.* `GetItemsGeneralData` je trajal 1.256 s — 21 minut v enem
     klicu končne točke, kar je 84× več od okna zastalosti (900 s). Zagon je preživel.
  2. *Mejnik po preslikavi.* Mejniki `ItemGeneralData`, `Descriptions` in `Prices` so bili
     zapisani ob 13:19, torej **po** preslikavi, ne ob 12:21 ob koncu zajema. Za 11
     nepreslikanih entitet mejnik ni šel nikamor. Natanko pravilo iz migracije 044/046.
  3. *`PageSize` 5.000.* `ItemGeneralData` v **23 straneh namesto 112**; cena klica je
     ostala ~55 s, torej 5× manj klicev na SAOP za isti podatek.
  4. *Odločitev iz migracije 047.* **Nič ni bilo zavrnjeno** — 0 novih vrstic v
     `map.UnmappedValue`. Pri starem pravilu bi 8,2 % zapisov izpadlo v celoti; zdaj
     8.092 artiklov brez skupine popusta **obstaja in je označenih**, namesto da jih ne bi bilo.
  **Katalog:** 196.515 artiklov skupaj; IQLighting 111.063 (EAN 53.163, skupina 102.562),
  besedila 110.313, **cene 144.816** (prej 798).
  **Validacija IQLighting** (97.507 aktivnih artiklov): `ERP_L1_SLO` 89.360 VALID / 8.147
  INVALID; `SHARED_CORE` 49.081 / 48.426 (pade na EAN pri 48.423 artiklih);
  `ERP_L1_EU`, `ERP_L1_THIRD`, `COMMERCIAL_L2` in oba spletna profila 0 % — manjkajo
  `canon.ProductCommercial`, spletni nazivi, kategorije in slike.
  Najpogostejši manjki v `ERP_L1_SLO`: `Product.DiscountGroup` 8.092, `AccountingGroup` 7.403,
  `UoM` 7.042, `Manufacturer` 4.008, `Supplier` 3.981.
  **Odprto po tem zajemu:** 64 strani v `raw.Inbox` iz 11 entitet brez preslikave;
  `val.Promote` da za IQLighting samo 786 artiklov, ker uporablja stari profil `ERP_L1`.

- **[WORKERJI]** Prvi polni zajem vseh štirih podjetij + dve napaki, ki ju je razkril — kdo:
  Claude Opus 5 — 2026-08-21. **195.756 artiklov** (prej 6.141): IQLighting 110.304,
  Ediito 39.130, Vidadria 28.897, DEMO 17.425.
  1. **Znak življenja je šel samo med končnimi točkami.** `GetItemsGeneralData` za IQLighting
     je 112 strani ob ~51 s = 1 h 40 min v enem klicu končne točke, okno zastalosti pa je
     900 s. Zagon se je razglasil za zastalega (`51102 Aktivno izvajanje ne obstaja`),
     podjetje je padlo po prvi končni točki in preostalih 15 sploh ni prišlo na vrsto.
     Popravljeno: utrip po vsaki strani, omejen na enkrat na 60 s.
  2. **Mejnik je šel čez nepreslikan podatek — drugič, skozi druga vrata.** Mejnik se je
     premikal takoj po končani končni točki, preslikava pa teče šele po vseh točkah podjetja.
     Ko je podjetje vmes padlo, je 112 strani (**111.065 artiklov**) ostalo `Pending` za
     mejnikom in delta jih ne bi več prinesla. Rešil jih je `--map-run`.
     Popravljeno: mejnik zapisuje **samo** `AdvanceWatermarksAsync`, po preslikavi in le, če
     za to entiteto iz tega zagona ni ostalo nič `Pending`. Pravilo je zdaj eno in
     preverljivo: *mejnik ne sme nikoli pokazati na obdobje, katerega podatek ni v katalogu.*
     `PIM.F3.Integration` ima regresijsko varovalko za točno ta scenarij (mejnik stoji, dokler
     je kaj Pending; premakne se, ko je obdelano).
  Nova stikala: `--max-parallel <n>` (podjetja hkrati), `--max-parallel-endpoints <n>`
  (končne točke istega podjetja), `--max-pages`, `--page-size`, `--brez-neaktivnih`.
  Izpis po končni točki zdaj navede čas in **sekunde na stran** — to je merilo, ali je SAOP
  pod obremenitvijo.
  Dokaz: `dotnet build PIM_Solution\PIM.sln -warnaserror` → 0/0;
  `scripts\run_tests.ps1` → **45 uspeli, 0 preskočenih, 0 padlih**.

- **[MERITEV]** Cena klica SAOP je na klic, ne na zapis — 2026-08-21, `GetItemsGeneralData`
  za IQLighting, vse meritve v isti uri:
  1.000 zapisov v 1 klicu = **50,4 s**; istih 1.000 v 4 klicih po 250 = **202,8 s**;
  5.000 zapisov v 1 klicu = **51,6 s**.
  Iz tega: manjše strani so strogo slabše, večje strogo boljše — pri `PageSize` 5.000 je poln
  zajem IQLighting 23 klicev namesto 112, torej **~20 minut namesto ~95**, in hkrati 5×
  manj zahtevkov na SAOP. **`PageSize` je na uporabnikovo odločitev 2026-08-21 postavljen na
  5.000** (`appsettings.Local.json` in vzorec v Gitu).
  Ob tem pobrisanih 32 strani `raw.Inbox`, ki so nastale kot ostanek teh meritev — na
  izrecno zahtevo uporabnika, po točnih `RunId` sedmih merilnih zagonov, vse v stanju
  `Pending` in brez vezanih izluščenih vrednosti. Po brisanju: 0 ostankov, v podjetju 2
  ostanejo 3 čakajoče strani iz rednega zajema.
  Počasna je **ena končna točka, ne podjetje**: na istem podjetju in v isti minuti je
  `GetItemsDescriptions` 0,78 s/stran, `GetPrices` 2,16 s/stran, `GetItemsGeneralData` 50 s/stran.
  **Vzporedne končne točke: varne, a skoraj brez učinka.** Tri hkrati proti zaporedno:
  228 s → 203 s (11 %), časi na stran pa ostanejo enaki (50,1 proti 52,0). SAOP se pod tremi
  hkratnimi zahtevki ne upogne; vzporednost ne pomaga, ker ena končna točka porabi 92 % časa.
  Zato `--max-parallel-endpoints` ostaja privzeto 1.

- **[OBRATOVANJE]** Nočni zajem kot načrtovana naloga — 2026-08-21, na izrecno zahtevo
  uporabnika. `NoviPIM - nocni zajem SAOP` vsak dan ob 02:00 požene `scripts\Nocni-zajem.ps1`;
  skripta sama odloči poln (1. v mesecu) ali delta. Dvojna varovalka proti prekrivanju:
  `IgnoreNew` na nalogi in preverba `ops.PipelineRun` v skripti — dokazano v živo med polnim
  zajemom (`PRESKOCENO`, izhod 0). Teče kot prijavljen uporabnik, ker rabi Windows Integrated
  Auth in `appsettings.Local.json`. Podrobno: razdelek 3.4 v `docs/ZAJEM-SAOP.md`.

- **[TESTI]** `PIM.ChangeTracking.Integration` je puščal artikle v razvojni bazi — kdo:
  Claude Opus 5 — 2026-08-21. Najdeno med preverjanjem, ali je naloga 1 zaključena:
  v podjetju 2 se je nabralo **38 artiklov `CHANGE-TRACKING-*`**, približno štirje na vsak
  polni zagon paketa. Niso bili samo smet — sedeli so med pravimi artikli IQLighting in
  kvarili vsako štetje (6.303 namesto 6.265).
  **Vzrok:** seja je tekla v transakciji, ki se ob koncu povrne, a `ExpectSqlErrorAsync`
  namenoma sproži napako v proceduri s `SET XACT_ABORT ON`. Taka napaka objemno transakcijo
  povrne **takoj**, zato je vse, kar je test naredil za tem, teklo v samopotrditvenem načinu
  in ostalo zapisano; ob koncu ni bilo več česa povrniti.
  **Popravek:** seja si zapomni vsak artikel, ki ga je ustvarila, in ga ob koncu pobriše, če
  je preživel; ob začetku pobriše ostanke prejšnjih zagonov istega testa. Briše izključno to,
  kar je ustvaril ta test (`AGENTS.md` §4.1).
  Dokaz: `scripts\run_tests.ps1` → 44 uspeli, 0 padlih; po zagonu
  `SELECT COUNT(*) FROM canon.Product WHERE ItemID LIKE 'CHANGE-TRACKING-%'` → **0**
  (pred tem 38), podjetje 2 pa ima 6.265 pravih artiklov.

- **[BAZA/VALIDACIJA]** Validacijski model iz preglednic naročnika: profili, stopnja resnosti
  in obseg blokade — kdo: Claude Opus 5 — 2026-08-21, migracija
  `047_ValidationProfilesSeverityAndScope.sql`. Podrobno: [`docs/VALIDACIJA.md`](docs/VALIDACIJA.md).
  Sedem profilov kot vrstice: `SHARED_CORE`, `ERP_L1_SLO`, `ERP_L1_EU`, `ERP_L1_THIRD`,
  `COMMERCIAL_L2`, `WEB_svetila_si`, `WEB_videlektro`; 47 zahtev, od tega 41 aktivnih in
  9 (v štirih vrsticah) zapisanih z `IsActive = 0`, ker kanoničnega polja še ni.
  Shema je dobila troje, česar prej ni znala izraziti: `Severity` (`ERROR`/`WARNING`),
  `BlocksErp`/`BlocksWeb`/`Scope` na profilu ter profile brez izvoznega profila
  (`ExportProfileId` sme biti `NULL`; enoličnost 1:1 zdaj drži filtriran unikaten indeks,
  ker bi `UNIQUE` dovolil samo en `NULL`). `canon.FieldValue` je dobil polja, ki jih profili
  zahtevajo, sistem pa jih prej ni videl.
  **Sprememba, ki jo je treba vedeti:** obveznost polja se je preselila iz zajema v
  validacijo. Pri zajemu ostaja obvezna samo `Product.ItemID`. Razlog je izmerjen: pri prvem
  živem zajemu je 15 od 183 artiklov (8,2 %) izpadlo v celoti, ker jim je manjkala skupina
  popusta — pri 200.000 artiklih bi to bilo okrog 16.000 artiklov, ki jih v PIM sploh ne bi
  bilo. Skupina popusta **ostaja obvezna**, a kot `ERROR` v `ERP_L1_SLO`, ki blokira ERP:
  artikel obstaja, je viden, je označen in se ne promovira. Če se s tem ne strinjaš, je
  popravek en `UPDATE` nad `map.FieldMapping`.
  **Popravljen obstoječi test in ni skrito:** `PIM.F2.Integration` je trdil, da »poln izdelek«
  nima nobene aktivne pomanjkljivosti. Trditev je ostala ista, spremenila se je definicija
  polnosti — izdelek je zdaj posajen poln za **vse** aktivne profile, ne le za prva dva.
  Test je hkrati okrepljen: dokazuje obe smeri stopnje resnosti — brez angleškega spletnega
  naziva nastane opozorilo, izdelek pa ostane `VALID`.
  Izmerjeno po zagonu (org 2, 6.265 aktivnih artiklov): `ERP_L1_SLO` 5.474 VALID / 791
  INVALID; `SHARED_CORE` 906 / 5.359 (pade na EAN); `ERP_L1_EU`, `COMMERCIAL_L2` in oba
  spletna profila 0 / 6.265, ker trgovinski podatki, spletni nazivi, kategorije, cene in
  slike še niso zajeti.
  **Kar ta naloga ne naredi:** ne upokoji profilov `ERP_L1` in `WEB_B2C` — uporablja ju
  `val.Promote` in ju preverja migrator; to je ločena odločitev.
  Dokaz: migrator uporabi `047`, 2. zagon nobene, `--verify` izhod 0;
  `scripts\run_tests.ps1` → **44 uspeli, 0 preskočenih, 0 padlih**;
  `dotnet build PIM_Solution\PIM.sln -warnaserror` → 0 opozoril, 0 napak.

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
