# NoviPIM — živ status dela

Posodobljeno: 2026-08-28

## Dopolnitve po primerjavi PIM/PIM_test — v delu 2026-09-02

Migracija **137** je dodala povratni SAOP preslikavi in odhodno pogodbo za
`GeneralData/ItemSearchName` (»Ime za iskanje«) ter `SalesData/Warranty` (»Garancija«).
Ime za iskanje uporablja generični kanonični model `ProductText.SEARCH_NAME.sl`, garancija
pa že obstoječo `ProductAttribute.Garancija`. Lastništvo `PIM` je izpeljano iz poti, ki
ju migracija 068 že označuje kot pisljivi po potrjeni preglednici; drugih politik migracija
ne spreminja. Kartica artikla obe polji vedno pokaže: ime za iskanje v identiteti, garancijo
v skupini »Prodaja«. Zapis gre skozi obstoječo odhodno vrsto in odobritev SAOP. Dokaz:
polni `scripts/run_tests.ps1` = 58/0/0 in `Build OK`.

Migracija **138** je dodala varen ponovni poskus neuspelih odhodnih sporočil: posamična
`out.RequeueOutboxMessage` in skupinska `out.RequeueOutboundBatch` smeta vrniti samo stanji
`Error`/`Dead` v `Pending`. `Sending` in `Sent` ostaneta nedotaknjena, zgodovina poskusov se
ne prepisuje, `LastError` se počisti, dejanje pa ostane v obstoječem dnevniku kot
`REQUEUE`/`INFO`. Ciljni dokaz `PIM.F8.BulkOutboundTests` je zelen (1/0/0, `Build OK`).
Na `/saop` in `/saop/zgodovina` je vrstični gumb »Pošlji znova« viden samo za `Error` ali
`Dead`; `/saop` ima še atomsko dejanje »Pošlji znova vse neuspele« po skupini. Po dejanju
se pogled osveži in pokaže dejansko število vrnjenih sporočil. Zapisovalni strani sta
omejeni na vlogi `ADMIN,CATALOG_EDITOR`. Dokaz: `run_tests.ps1 -Filter F10` = 14/0/0 in
`Build OK`.

Migracija **139** je dodala `intranet.GetWebExportRows` za produktne izvozne profile.
Dinamični rezultat dobi glave, vrstni red in kanonične kode iz registra
`out.ExportProfile/out.ExportColumn`; podpira spletno mesto, samo objavljene, iskanje,
strani in `@Take=0` za celoten nabor. Več vrednosti združi, nepovezan registrski stolpec pa
ostane prazen. Bazni dokaz `PIM.F7.WebExportTests` je zelen (1/0/0, `Build OK`). Servis,
pretočni HTTP prenos in uporabniška stran so dodani: `/splet` vodi na `/splet/izvoz`, kjer
uporabnik izbere produktni profil, spletno mesto, samo objavljene in iskanje. Predogled je
omejen na 200 vrstic; prenos celoten filtrirani nabor piše neposredno iz `SqlDataReader` v
`Response.Body` kot UTF-8 z BOM, `;` in pravilnimi narekovaji. Ime je
`PIM_splet_{profil}_{yyyyMMdd_HHmm}.csv`. Stari `/izvoz/izdelki.csv` zdaj naredi en SQL klic
do 20.000 vrstic namesto 100 zaporednih strani. Dokaz: F7 = 7/0/0, F10 = 14/0/0, oba
`Build OK`.

## Popravki po pregledu uporabnika 2026-08-28

Uporabnik je pregledal cel vmesnik in predal seznam pripomb. Popravljenih je **47 postavk**;
pet je vprašanj, ki čakajo njegovo odločitev. Celoten seznam s stanjem je v
[`docs/POPRAVKI_PIMA.md`](docs/POPRAVKI_PIMA.md).

**Kar se je spremenilo v obnašanju sistema:**

- **Številke niso več samo DEMO.** Nadzorna plošča sešteje vsa aktivna podjetja in pokaže
  razčlenitev po podjetjih; kakovost sešteje nivoje in vrzeli čez vsa podjetja; cene in zaloga
  imata izbiro podjetja. Vzrok je bil povsod isti: `GetCurrentOrganizationAsync` vrne prvo
  podjetje po šifri.
- **Izvoz v Excel je postal delovno orodje.** List »pregled« je bil prepis zaslonskega seznama;
  zdaj nosi skupine ERP, Komerciala in Splet, nazive v petih jezikih, rumeno označene zahteve
  validacije in rdeče označena prazna zahtevana polja.
- **Stran »Preverbe cen in zaloge« dela.** Bralnih procedur `intranet.GetPriceChecks` in
  `intranet.GetStockChecks` prej ni bilo. Merjeno pri organizaciji 1: 20.964 cenovnih in
  536 zalogovnih preverb, med njimi 578 izdelkov s faktorjem marže pod 2,00.
- **Kartica stranke ima zavihke** (splošni podatki, komercialni podatki, poslovne enote in
  tranziti, zaznamki, dokumenti in finance, zgodovina) in vrsto stranke z proizvajalcem.
  Stran »Partnerji« je odpadla — dobavitelj in proizvajalec sta vrsti stranke.
- **Validacijski profil in preslikave polj se dajo urejati** iz vmesnika, z revizijo v
  `b2b.AuditLog`. Zahteva se ne briše, ker odprte napake kažejo nanjo; umik je izklop.
- **Splet pokaže dejanski CSV**, ki gre ven — predogled in prenos, ločeno za artikle in
  stranke. Mapa se nastavi z `WebExport:Directory`.

Migracije: **126–133**. Testi: `scripts\run_tests.ps1` = 58 uspeli, 0 padli.

## Intranet — kanalska kartica, nivoji kakovosti in skupne strehe 2026-08-27

Kartica izdelka je razdeljena na sklope (po popravku 2026-08-28 jih je šest: Pregled,
Osnovni podatki, Prodaja in kanali, Mediji, Zaloga, Kakovost in zgodovina). Glava ter galerija prikazujeta dejanske
slike; skupni `MediaUrlPolicy` varno normalizira tudi Nowodvorskega `//...` naslove. ERP,
komerciala in splet imajo enako tabelo polj, lastništva, izvora, svežine in odprtih težav.

Validacija ima en skupen izpeljan zemljevid **ERP_SLO · ERP_EU/THIRD · KOMERCIALA · SPLET**,
ki ga uporabljajo `/kakovost`, `/kakovost/napake`, `/pravila/validacija` in kartica izdelka.
Skupne zahteve se pokažejo v vsakem blokiranem nivoju, števci pa deduplicirajo izdelke.

Novi delovni pogledi so `/preverbe`, `/saop`, `/saop/zgodovina`, `/saop/odkloni`,
`/saop/polja`, `/splet`, `/nastavitve/atributi/{koda}` in
`/nastavitve/povezave-izdelkov`. `Sent` je povsod rumeno »poslano, nepotrjeno«; zeleno je
rezervirano za `Verified`/potrjen uspeh. Kjer bralni model še ne obstaja, UI pokaže skupni
`PimMissing`, celotna naslednja bazna faza pa je popisana v
`docs/porocila-faz/BAZA_ZAHTEVE_INTRANET.md`.

Dokaz: `scripts\run_tests.ps1 -Filter F10` → **11/0/0**; polni
`scripts\run_tests.ps1` → **52/0/0**, izhod 0 in `Build OK`; ločen build rešitve →
**0 opozoril / 0 napak**. Zagon na `127.0.0.1:5199`: `/health` in `/prijava` 200, vse štiri
preverjene nove zaščitene poti 302 na prijavo. Prijavljeni vizualni izris brez uporabniških
poverilnic ni bil preverjen.

## Intranet — stanje 2026-08-26

**Zadržani intranetni paket je commitan.** Pet vnosov je bilo v `TASKBOARD.md` pod BLOKIRANO
samo zato, ker je imel polni paket en nepovezan padec (`PIM.F3.Integration`, zastarel primer
`GetItemsPlanningData`). Commit `b91bc40` je test uskladil z migracijo 082; polni paket je od
takrat **51 uspelih / 0 preskočenih / 0 padlih**, zadržano delo pa je v `d35e407`.

**Štirje delovni seznami so prenovljeni po načrtu** (`docs/Sprecifikacije_starega_PIMa/`):

| Stran | Migracija | Kaj je bilo narobe |
|---|---|---|
| `/izdelki` | 101, 108 | seznam je pokazal samo šifro, EAN, status in popolnost; od 108 tudi **vsa štiri podjetja** namesto samo DEMO |
| `/kakovost/napake` | 102 | brala je **3.004.688** odprtih težav naenkrat in filtrirala v pomnilniku |
| `/zaloge` | 103 | naložila je vseh **379.610** pozicij naenkrat |
| `/izvozi` | 104 | pokazala je samo register profilov, ne pa kaj v izvoz ne gre in zakaj |

Vse štiri strani so strežniško paginirane, filtri živijo v naslovu URL, vsaka številka vodi na
svoj filtriran seznam, nobena nima gumba brez varne zapisovalne poti.

**`/izdelki` je od 2026-08-27 večorganizacijski.** Do takrat je bral obseg iz
`GetCurrentOrganizationAsync` (prvo aktivno podjetje po šifri) in je pokazal **17.425 od
196.531** izdelkov — samo DEMO. Zdaj so privzeto vsa podjetja, tabela ima stolpec Podjetje,
filter podjetja pa zoži seznam, števce zavihkov in vrednosti spustnih seznamov. Iz tega sta
sledili dve popravljeni posledici: kartica izdelka dobi podjetje iz izdelka (prej bi bil tuj
izdelek »neobstoječ«), množično urejanje pa sprejme samo izbiro iz enega podjetja in prejme
njegovo šifro (prej bi tuje šifre pisalo v privzeto podjetje). Meritve pred/po so v
glavah migracij; največji premik: filter po pripravljenosti 2.911 ms → 172 ms in razvrščanje
po popolnosti 1.489 ms → 67 ms (dva nova ozka indeksa nad `canon.Product`).

**Predogleda izvozne datoteke ni in ne bo v SQL-u.** Obliko Magento izvoza dela
`PIM.B2bWorker`; druga izvedba iste logike bi bila druga resnica. Stran zato pove tisto, kar je
točno: kaj je objavljeno, kaj ni in katera zahteva to ustavi.

**Izmerjeno stanje podjetja 2 ob prenovi:** 111.068 kanoničnih izdelkov, 43.503 objavljenih,
67.565 neobjavljenih; najpogostejši razlogi so manjkajoča kategorija (54.766), slika (54.758)
in spletni naziv (52.649). 22 od 213 stolpcev profila `MAGENTO_PRODUCTS` nima kanoničnega vira.

**Kar ostaja nepreverjeno:** izris prijavljenih strani. Zagon na `127.0.0.1:5199` vrne
`/health` 200, `/prijava` 200 ter 302 na prijavo za `/izdelki` in `/izvoz/izdelki.csv`, prijava
sama pa brez poverilnic ni bila izvedena.

## Intranet prenova — stanje 2026-08-24

Prekinjena navigacijska in bralna osnova je sestavljena v koherentno aplikacijo. Navigacija
je v `PimNavigation` (koda, filtrirana po vlogah), uporablja base-relativne povezave in ima
ciljno stran za vsako menijsko postavko. Skupni gradniki pokrivajo glavo strani, tabele,
stanja nalaganja/napake/praznega nabora, paginacijo, statuse in razdelilne kartice.

Novi bralni pogledi: mediji, partnerji, cene, kakovost in njene vrzeli, zajem z viri in
čakalno vrsto, izvozni profili s stolpci, nastavitve kataloga (atributi, kategorije,
skladišča, kanali, jeziki), pravila (validacija, slovar, preslikave) ter sistemske napake in
vloge. Stare poti ostajajo kot aliasi, zato neposredni zaznamki niso prekinjeni.

Dokaz v tej izvedbi: `scripts\run_tests.ps1 -Filter F10` → 10 uspešnih, 0 preskočenih,
0 padlih; celoten `PIM.sln` build → 0 opozoril/0 napak; bralni smoke-test proti lokalni bazi
`PIM` in kontrola menijskih poti → izhod 0. Polni `scripts\run_tests.ps1` vrne 50 uspešnih,
0 preskočenih in 1 padec (`PIM.F3.Integration`, zastareli primer `GetItemsPlanningData`, ki
je od migracije 082 preslikan). Zaradi pravila, da se napačnega testa ne spreminja za zelen
rezultat, intranetni sklop še ni commitan in ni označen kot končan.

Korenska preusmeritev uporablja .NET 10 nastavitev
`BlazorDisableThrowNavigationException=true`; cilj ostaja `/nadzorna-plosca`, Visual Studio
pa se med statičnim SSR ne ustavi več na notranji `NavigationException`.

Vizualna osnova je 2026-08-24 preslikana iz uporabnikove reference
`src_navigation_ux_v2`: referenčna nevtralna/indigo/oranžna paleta, 18-rem temna stranska
vrstica, kartice, tabele, obrazci, prijava in mobilna prelomnica so uporabljeni na obstoječih
razredih. Razor, poti, `PimNavigation`, vloge in podatkovni dostop ostajajo NoviPIM. Strategija
združitve in zavrnjeni deli reference so v `docs/NACRT_INTRANET_PRENOVA.md` §13.

Navigacijske povezave so dodatno usklajene z referenčnim videzom: niso več brskalniško modre
in podčrtane, aktivna pot je temna kartica z oranžno levo črto, pomembni cilji imajo kratek
opis, razdelilne strani pa puščico. Vzrok starega prikaza je bil Blazor CSS isolation —
izolirani slog starševske komponente ni dosegel sidra, ki ga izriše `NavLink`; selektor zdaj
uporablja `::deep`. Spletnega konteksta oziroma polja »Svetila.si« v meniju ni, ker uporabnik
tega elementa ne želi. Strani, poti in filtriranje po vlogah se niso spremenili.

Modul **Vhodni podatki** je 2026-08-24 izveden kot pet pogledov: Pregled, Viri, Teki,
Težave in Preslikave. Združuje dejanske katalogske vhode (`raw.Inbox` +
`ops.PipelineRun`) in zalogovne vhode (`stock.SyncRun`), pri čemer je zadnji poskus ločen od
zadnjega uspeha. Čakalna vrsta, neujemanja ter podrobnosti vira, teka in težave so dostopne
iz teh pogledov in ne obremenjujejo stranskega menija. Administrator lahko pregleduje vsa
podjetja in omejeno tehnično diagnostiko; drugi uporabniki so na seznamih in neposrednih
podrobnostih omejeni na aktivno organizacijo. Dostava ostaja pošteno bralna brez gumbov za
dejanja, ki nimajo auditirane procedure. Znana vrzel je neuspešen zalogovni tek: writer ob
izjemi povrne celotno transakcijo in zato nima trajnega `Failed` zapisa, ki bi ga UI lahko
prikazal.

Dokaz vhodnega modula: `scripts\\run_tests.ps1 -Filter F10` → 10/0/0 in `Build OK`;
`PIM.Migrator --verify` → uspešno; read-only SQL smoke za glavne, pomožne in podrobnostne
poglede → izhod 0. Polni paket je bil ponovljen po izvedbi in ostaja 50 uspešnih / 0
preskočenih / 1 padel: isti nepovezani `PIM.F3.Integration` na vrstici 89. Zaradi tega sklop
po pravilih ni commitan.

Skupno produktno ogrodje pred prenovo posameznih strani je določeno 2026-08-24. Obvezni
kontekst VHODI → PIM → KAKOVOST → IZHODI ERP/SPLET → OBVESTILA/NADZOR → ANALITIKA je v
`AGENTS.md` §2.1, dejanski zemljevid shem, vlog, pogodb in vrzeli pa v
`docs/PRODUKTNI_MODEL_PIM.md`. `PimNavigation` je razdeljen po istih življenjskih skupinah;
`PimLifecycle` na vsaki poti določi področje, ki ga skupna zgornja vrstica pokaže uporabniku.
Analitika trendov in naročilnice ostajajo pošteno označene vrzeli brez mrtve menijske poti.

Odprta meja: novi domenski bralni servisi imajo parametriziran SQL v intranetnem projektu.
Načrt zahteva `intranet.*` procedure; to je naslednja ločena odvisnost BAZA → INTRANET in ne
sme biti pomešana v isti commit.

## Stanje treh delov po meritvi 2026-08-22

Celotna analiza z vsemi številkami: [`docs/ANALIZA_A_B_C.md`](docs/ANALIZA_A_B_C.md).
Merjeno proti živi bazi (migracija **058**), ne proti dokumentaciji.

| Del | Mehanizem | V obratovanju | Ozko grlo |
|---|---|---|---|
| **A — zajem** | ~90 % | ~55 % | 294 strani v `raw.Inbox` je `Pending` — zajeto, a nepreslikano |
| **B — izvoz** | ~85 % | **~10 %** | v resnični datoteki ima vrednost **15 od 213 stolpcev** |
| **C — odhodna pot** | ~50 % | **0 %** | v `out.OutboxMessage` ni nikoli vstopilo nobeno sporočilo |

**Razkorak ni v kodi, ampak med kodo in podatkom.** Vsi trije deli imajo več zgrajenega,
kot ga je v obratovanju.

Meritev je nastala nad delovnim drevesom **pred** commitom `2beee25`; vse številke iz baze
veljajo naprej, ker se shema od takrat ni spremenila.

**Popravek istega dne, po polnem branju dobaviteljevega XML in migraciji `059`:** del B ni več
pri ~10 %. Dobaviteljev XML se je do takrat bral samo v izrezku (25 izdelkov Nowodvorskega,
3 Braytrona), zato so bile `pim.*` otroške tabele skoraj prazne — vzrok ni bil v objavi, ampak
v zajemu. Po polnem branju obeh datotek, ponovni validaciji in objavi:
`canon.ProductAttribute` 1.064 → **112.820** vrstic (2.548 izdelkov), `pim.ProductAttribute`
901 → **101.462**, `pim.ProductCategory` 21 → **6.494**, izvožena datoteka pa ima vrednost v
**152 od 213 stolpcev** namesto v 15. Podrobno v `TASKBOARD.md` pod 2026-08-22.

Dokazi te meritve: `dotnet build PIM_Solution\PIM.sln` → 0 napak;
`PIM.Migrator --verify` → izhod 0; `PIM.B2bWorker --export-magento --organization-id 1`
→ datoteka 1.729 vrstic. `scripts\run_tests.ps1` v tej seji ni bil pognan (zadnji znani
rezultat 44/0/0 z dne 2026-08-21).

**Prvi štirje koraki po vrsti:** (1) ponovna preslikava zajetih strani za trgovinske
podatke (`--map-run`/`--full`), (2) preslikava `GetItemsTitlesLanguage` — spletni nazivi,
(3) poln zajem NW in BT XML, (4) odločitev o profilu za objavo in `val.Promote` za
organizaciji 3 in 4.

## Vhodi — zaključeni 2026-08-23 (novejše od tabele zgoraj)

Vrstica **A — zajem** v tabeli velja za stanje pri migraciji 058. Za vhode je merodajno to.

**Vseh 16 bralnih končnih točk SAOP ima cilj v modelu.** Do 2026-08-23 jih je bilo preslikanih
12; štiri (`Customers`, `GetItemCustomerDataV2`, `CustomerItemGroupDiscounts`,
`TechnologicalProcess`) so se zajemale in ležale v `raw.Inbox` kot `Pending`. Migracija **087**
jim je dala cilj.

**Tri preslikave iz migracije 082 sploh niso tekle.** Migracija je registrirala šifrante, konte
zaloge in planiranje ter zanje ustvarila `map.ProcessCodebookInbox`,
`map.ProcessStockAccountingInbox` in `map.ProcessPlanningInbox` — poklical pa jih ni nihče.
Vrstice v registru, tabele prazne. Zdaj so v `MappingProcedures` in jih kliče cevovod; test
`PIM.F5.Integration` odslej pade, če kateri `TargetDomain` v registru nima svojega postopka.

Kaj je prišlo v bazo po preslikavi zaostanka (223 strani, ki so ležale od 21. avgusta):

| Tabela | Pred | Po |
|---|---|---|
| `canon.Codebook` (valute, ceniki, tehnološki proces) | 0 | **708** |
| `canon.ProductPlanning` | 0 | **196.512** |
| `canon.ProductStockAccounting` | 0 | **176.086** |
| `b2b.Customer` | 0 | **11.558** |
| `b2b.CustomerItem` (artikel pri stranki) | — | **9.207** |
| `b2b.CustomerItemGroupDiscount` | — | **4.270** |
| Braytronove slike v `canon.ProductMedia` | 0 | **1.384** |

`raw.Inbox` nima več nobene vrstice `Pending` (bilo jih je 229). V karanteni ostane 10 strani
iz julija in začetka avgusta — »Neveljaven XML« in »Izdelek ne obstaja«, rep prejšnjih meritev.

**Dobaviteljeva zaloga teče za vsa štiri podjetja**, ne le za IQLighting. Ob tem sta se
pokazali dve pravi napaki, obe popravljeni:

- ista nespremenjena datoteka je drugič porušila `PIM.StockFileWorker` s podvojenim ključem
  (`UQ_StockSnapshot`) — za nočno opravilo pravilo, ne izjema;
- `stock.ApplyLandingRecord` je od migracije `018` iskal artikel **brez pogoja po podjetju**
  (migracija `088`). Dokler je zalogo imelo samo podjetje 2, se to ni poznalo.

**Nočno opravilo poganja vse vhode** (`scripts\Nocno-vse.ps1`): SAOP katalog, dobaviteljev XML,
spletni nazivi, preslikava zaostanka, zaloge za vsa podjetja, validacija, objava in izvoz.
Načrtovano nalogo Windows registrira `scripts\Namesti-nocno-opravilo.ps1` — to je po
`AGENTS.md` §4.7 tvoj korak, ne agentov. Podrobno: `docs/WORKERS.md`.

**Kar pri vhodih ostaja odprto:** Braytronove kategorije (potrebujejo odločitev o drevesu),
prevzem dobaviteljevih datotek s FTP (zunanji klic) in izvoz strank — `b2b.Customer` ima zdaj
11.558 vrstic, `out.ExportB2bCustomersCsv` pa jih ne izvozi, ker se veže na
`pim.CustomerWebProfile`, ki je prazen.

## Vhodi — posodobljeno 2026-08-24

**Nočno opravilo je ugasnjeno.** Naloga `NoviPIM - nocni zajem SAOP` je v stanju `Disabled`, ker
je SAOP s tega računalnika dosegljiv le prek FortiClient: zagon ob 02:00 je padal na časovni
iztek do gostitelja `192.168.178.12:81`. Ko bo koda v domeni, se registrira `Nocno-vse.ps1`.

**Padec se je skrival v skripti, ne v kodi.** `Nocni-zajem.ps1` je pod `$ErrorActionPreference =
'Stop'` umrl ob prvi vrstici, ki jo je worker napisal na stderr — brez zapisa v dnevnik in z
ubitim procesom, zato so zagoni ostajali `Running`. Popravljeno; ob tem so bili popravljeni še
dnevniki v pokvarjeni slovenščini (konzola v kodni strani 852 proti UTF-8 iz workerja).
Zataknjenih 14 zagonov `Running` je zaprtih kot `Failed`; `Running` je zdaj 0.

**Ročni zajem 2026-08-24 je uspel:** 69 strani, 280.407 zapisov, izhod 0. V `raw.Inbox` 79 novih
strani vseh štirih podjetij, `canon.Product` 196.515 → 196.531, `Pending` 0.

**Ediito iz dobaviteljev ne dobi ničesar in to ni napaka.** Ima 33.423 EAN (najboljša polnost od
vseh štirih), a nobenega z GS1 predpono Nowodvorskega (`5903139*`) ali Braytrona (`5949097*`) —
njegova ponudba je italijanska in španska. Pravi strop obogatitve je drugje: **6.651 artiklov
obeh dobaviteljev v katalogu v julijskih datotekah sploh ni**, obratno pa 1.979 Braytronovih EAN
iz datoteke ne ustreza nobenemu artiklu. Podrobno v `TASKBOARD.md`.

## Izvozi — meritev 2026-08-23 (novejša od tabele zgoraj)

Vrstica **B — izvoz** v tabeli velja za stanje pri migraciji 058. Za izvoze je merodajna
novejša meritev: [`docs/ANALIZA_IZVOZI.md`](docs/ANALIZA_IZVOZI.md) (migracija **080**,
merjeno na resničnih datotekah za vsa štiri podjetja).

- Objavljenih je **89.129** izdelkov v vseh štirih podjetjih — Vidadria in Ediito nista
  več na ničli. Vstopnica za objavo je še vedno `ERP_L1`.
- Magento izvoz teče v živo za vsa štiri podjetja; vrednost ima **180 od 213** stolpcev
  (2026-08-22: 15), polnost celic pa je **8,2 %**.
- Od sedmih izvoznih profilov ima poganjalnik **en**. Dostave do Magenta ni (namerna meja).
- `val.Promote` za organizaciji 3 in 4 je bila pognana 2026-08-23; objava od takrat ni v
  zaostanku za katalogom pri nobenem podjetju.


## Migracije 049–058

`dbo.SchemaMigration` je na **058**. Deset migracij (`049`–`058`) je uporabljenih na
razvojni bazi in od commita `2beee25` (2026-08-22) tudi v git — skupaj s popravki
`MagentoCsvContract.cs` in testov F2/F5/F7. Kar prinašajo:

- **049** slovar vrednosti in pretvorbe (`map.FieldTransform` 40, `map.ValueLookup` 6.316)
- **050–053** čiščenje glav Magento predloge (213 aktivnih stolpcev namesto 215)
- **054/055** preslikave lastnosti iz Nowodvorski (108) in Braytron (76) XML
- **056** vrstni red manjkajočih prevodov
- **057** trgovinski podatki iz SAOP — 11 preslikav v `canon.ProductCommercial`
- **058** `val.Promote` polni tudi otroške tabele

Bradavica: `dbo.SchemaMigration` vsebuje zapisa `047_ValueDictionaryAndTransforms.sql` in
`048_ValueDictionaryAndTransforms.sql`, ki kot datoteki ne obstajata (preimenovani v 049).
`--verify` kljub temu vrne 0.


## BAZA naloga — karantena NW XML po izdelku

- **Stanje: BLOKIRANO.** Claude je z zahtevanima `--permission-mode acceptEdits` in `--max-turns 40` pripravil `PIM_Solution/sql/migrations/040_QuarantineGenericXmlPerRecord.sql`; XML ne vstavi `canon.Product`, lookup vsebuje `OrganizationId`, zapis se obdeluje po `RecordOrdinal`, neujemanja pa so po trenutnem nalogu tiho preskočena in `raw.Inbox` konča `Processed`. Codexov neodvisni statični pregled je vrnil `VERDICT: PASS`.
- **Blokada dokazov:** `scripts/run_tests.ps1` → izhod 1, 41 uspešnih / 0 preskočenih / 1 padel. `PIM.F5.Integration` na `PIM_Solution/tests/PIM.F5.Integration/Program.cs:192` še zahteva `Quarantined` za neujemajoči zapis, trenutni nalog pa zahteva `Processed` in tiho preskakovanje. Testa ne spreminjamo, da bi šel skozi. Znotraj Hermesove seje tudi ni varno dostopne povezave za ponovitev NW XML E2E meritev.
- **Uporabnik:** potrebna je odločitev, ali trenutna specifikacija velja in se v ločenem/izrecno odobrenem koraku posodobi F5 integracijski test, ali se specifikacija vrne na karantensko semantiko.

## Aktivno preverjanje E2E

- **Stanje: KONČANO.** Hermes je sam izvedel korake 1–5 iz
  `.hermes/naloge/2026-08-13-e2e-koraki-1-5.md`; nalog ni spreminjal kode,
  SQL-a ali testov.
- **Dokaz:** build 0 opozoril/0 napak; migrator `--verify` 0 in dva
  idempotentna zagona brez nove migracije; `scripts\run_tests.ps1` →
  `REZULTAT: VSE OK`, 42/0/0; F3/F5/F6/F7/F8 fixture dokazi in Kestrel health
  na 5088 so uspešni. Podrobnosti: `docs/TEST_REPORT_E2E.md`.
- **QA:** Codex je po pregledu dejanskega diffa in izvornih testov vrnil
  `VERDICT: PASS`.
- **Uporabnik:** ničesar ni treba storiti.

## Zajem iz SAOP — stanje 2026-08-13

- **Živ zajem je pripravljen, a še ni bil izveden.** Na tem računalniku ni SAOP
  poverilnic; koda in konfiguracijsko mesto sta pripravljena, vpiše jih uporabnik.
  Navodila: `docs/ZAJEM-SAOP.md`.
- **Worker do danes sploh ni mogel teči.** `ops.BeginRun` je vrgel 51100, ker za
  `SAOP_PRODUCTS` ni bilo razporeda. Zadnji uspešen SAOP zajem je 30. 7. 2026.
- **Od migracije 017 SAOP ni mogel ustvariti novega artikla.** Zdaj sme, ker ima
  konektor `CanCreateProducts`; dobaviteljski viri ostajajo brez te pravice.
- **Preslikava ni več ozko grlo** (2026-08-21, migracija `044`). Bilo je 8–9 artiklov/s
  (~6–7 ur za 200.000). Merjeno z istim merilom pred in po
  (`PIM_Solution\tools\Bench-ProcessRawInbox.sql`): 2.000 zapisov 219.347 ms → 1.145 ms,
  torej **9,1 → 1.747 zapisov/s**; pri 20.000 zapisih 2.149/s. Za 200.000 artiklov je to
  okrog 1,5 minute. `--only-ingest` zato ni več nujen zaradi hitrosti.
- Pokritost: zajem dela za vseh 16 končnih točk, preslikava v `canon` za tri.
- **Zajem brez preslikave ne premakne mejnika** (2026-08-20). Preostalih 13 končnih
  točk se sme zajemati, ne da bi se podatek izgubil: zapisi ostanejo `Pending` v
  `raw.Inbox`, mejnik pa počaka, zato jih bo prvi zagon po dodani preslikavi zajel
  znova. Worker to izpiše kot `BREZ PRESLIKAVE`. Prej se je mejnik premaknil in bi
  bilo tisto obdobje trajno preskočeno.
- **Padec enega podjetja ne ustavi ostalih** (2026-08-20). `ops.BeginRun` je zdaj
  znotraj obravnave napak, zato podjetje brez razporeda (51100) ne ubije zajema za
  preostala tri.

## Stanje razvojne baze na tem računalniku

- Baza `PIM` na `localhost\MSSQLSERVER3` (računalnik `DESKTOP-TONVQHJ`) je od
  2026-08-21 na migraciji **047**; do 2026-08-20 je bila na **043**. Pred tem je imela samo do `027`: migracije
  `028`–`043` so bile opravljene na drugem računalniku in tu nikoli uporabljene,
  zato je 7 integracijskih testnih projektov padalo s `Class:20` (povezava).
  Dokaz po popravku: migrator 1. zagon uporabi 16 migracij, 2. zagon nobene,
  `--verify` izhod 0, `scripts\run_tests.ps1` → 44 uspeli, 0 preskočenih, 0 padlih.
- Zaradi tega velja pravilo: **trditev „migracija je uporabljena" ni prenosljiva med
  računalniki.** Preveri `dbo.SchemaMigration`, ne dokumentacije.

## Izvozi

- **Oblika Magento izvoza je od 2026-08-21 v registru** (`out.ExportProfile` /
  `out.ExportColumn`, migracija `045`). Profila `MAGENTO_PRODUCTS` in `MAGENTO_CUSTOMERS`
  sta vrstici v bazi; nov spletni kanal ne zahteva več spremembe programa. Preslikava
  stolpec→kanonična koda ni več `switch` v `MagentoProductSchema`.
- Kar ostaja koda: poizvedbe, ki kanonične vrednosti proizvedejo. Nov *podatek* je še
  vedno koda, nov *kanal* ni.
- **Popravljeno 2026-08-22:** trditev „162 atributnih stolpcev je praznih, ker manjka
  odločitev" ne velja več. Odgovor je zapisan kot vrstice registra v migracijah 054
  (Nowodvorski, 108 preslikav) in 055 (Braytron, 76). Od 160 atributnih stolpcev aktivnega
  profila jih ima vir **156**; brez vira ostanejo **4**, ločeno pa **33 stolpcev sploh nima
  kanonične kode** (zaloge VID, dobavitelj, dokumenti, kategorije svetila, popust, valuta,
  skladišče).
- **Prazni so kljub temu — a iz drugega razloga.** Zagnan izvoz za organizacijo 1
  (2026-08-22) je dal 1.728 vrstic, v katerih ima vrednost **15 od 213 stolpcev**: šifra,
  EAN, proizvajalec in DDV pri vseh, cena B2B pri 1.109, vse ostalo pri enem ali nič.
  Vzrok je prazen `canon`, ne izvoz. Podrobno: `docs/ANALIZA_A_B_C.md`.

## Validacija — od 2026-08-21 po dogovorjenem modelu

- Sedem profilov kot vrstice (`SHARED_CORE`, `ERP_L1_SLO`, `ERP_L1_EU`, `ERP_L1_THIRD`,
  `COMMERCIAL_L2`, `WEB_svetila_si`, `WEB_videlektro`), stopnja resnosti `ERROR`/`WARNING`
  in obseg blokade (`BlocksErp`, `BlocksWeb`). Podrobno: `docs\VALIDACIJA.md`.
- **Obveznost polja se je preselila iz zajema v validacijo.** Pri zajemu je obvezna samo
  `Product.ItemID`. Skupina popusta ostaja obvezna kot `ERROR` v `ERP_L1_SLO`.
- Stanje org 2 (6.265 aktivnih): `ERP_L1_SLO` 5.474 VALID / 791 INVALID; `SHARED_CORE`
  906 / 5.359; `ERP_L1_EU`, `COMMERCIAL_L2` in spletna profila 0 / 6.265 — trgovinski
  podatki, spletni nazivi, kategorije, cene in slike še niso zajeti.
- Devet zahtev čaka na kanonično polje (volumen, mere pakiranja, kosi v paketu, izločitev iz
  rezervacije); zapisane so z `IsActive = 0`, da je model viden v celoti.

## Katalog po prvem polnem zajemu (2026-08-21)

- **196.515 artiklov**: IQLighting 111.063, Ediito 39.130, Vidadria 28.897, DEMO 17.425.
  IQLighting je bil 2026-08-21 dopolnjen z vsemi 16 končnimi točkami (27 minut, 571.909
  zapisov); cene zanj 144.816 (prej 798), besedila 110.313.
- **Nič ni bilo zavrnjeno** ob preslikavi — posledica migracije 047, ki je obveznost polj
  prestavila iz zajema v validacijo. Prej bi izpadlo 8,2 % zapisov.
- Validacija IQLighting: `ERP_L1_SLO` 89.360 VALID / 8.147 INVALID; `SHARED_CORE`
  49.081 / 48.426 (EAN); `ERP_L1_EU`, `COMMERCIAL_L2` in spletna profila 0 %.

- **195.756 artiklov** v štirih podjetjih: IQLighting 110.304, Ediito 39.130,
  Vidadria 28.897, DEMO 17.425. Cene 156.114, besedila 195.723.
- **Preslikane so 3 od 16 SAOP končnih točk.** Ostalo je zajeto in leži v `raw.Inbox` kot
  `Pending` — 2026-08-22 je bilo takih **294 strani**, največ `GetItemsPlanningData` (110),
  `GetItemsStockAccountingData` (87) in `GetItemsTitlesLanguage` (45, spletni nazivi).
- **`canon.ProductCommercial` — popravljeno 2026-08-22.** Preslikava zdaj obstaja
  (migracija 057, uporabljena). Tabela je kljub temu pri **1 vrstici**, ker so zajete strani
  že `Processed`: potreben je `--full` ali `--map-run`, ne nova preslikava. Zato so
  `ERP_L1_EU`, `ERP_L1_THIRD` in `COMMERCIAL_L2` še vedno pri 1 veljavnem artiklu od 115.685.
- **`val.Promote` — popravljeno 2026-08-22.** Migracija 058 jo je razširila na otroške
  tabele in to dela: `pim.Product` 44.510, `pim.ProductText` 44.511, `pim.ProductPrice`
  85.777. Nizke ostajajo `pim.ProductAttribute` (901 / 27 izdelkov), `pim.ProductCategory`
  (21), `pim.ProductMedia` (21) in `pim.ProductCommercial` (1) — ker je nizek `canon`,
  ne ker `Promote` ne bi delala.
- **Objava teče samo za organizaciji 1 in 2.** Vidadria (3) in Ediito (4) imata 0
  objavljenih artiklov. Vstopnica je še stari profil `ERP_L1` (44.510 VALID); po
  `ERP_L1_SLO` bi jih bilo 100.809. Zamenjava je poslovna odločitev.
- Zaloge: `stock.Position` (168.594) se polni iz datotek. Končni točki SAOP
  `GetItemsStockData` in `GetItemsStockAccountingData` sta zajeti, a brez preslikave.
- Celoten zemljevid baze z vrsticami po tabelah: glej `docs/VALIDACIJA.md` in objavljeni
  pregled baze.

## Živ zajem iz SAOP — prvič izveden 2026-08-21

- **Prvi živi klic je uspel.** `GetItemsGeneralData` za podjetje 2 je vrnil 183 artiklov
  (delta, ne cel katalog — mejnik je bil postavljen ob prejšnjih zagonih). Poln zajem z
  `--full` še ni bil izveden.
- **Izmerjeno:** 168 obogatenih, 15 (8,2 %) zavrnjenih v celoti, ker manjka
  `Product.DiscountGroup`. 148 novih artiklov; skupaj 6.299. EAN 789 → 906,
  `ItemGroup` 0 → 168, `Department` 0 → 162.
- **Popravljena napaka, ki jo je razkril ta zajem:** `--only-ingest` je premaknil mejnik,
  čeprav ni ničesar preslikal; ob ponovnem zajemu iste vsebine je dedup po hashu pomenil,
  da preslikava nima česa obdelati. 183 artiklov je ostalo za mejnikom. Zdaj mejnik stoji
  tudi v teh dveh primerih in izpis pove razlog. Nov `--map-run <RunId>` preslika že zajet
  zagon brez klica na SAOP.

## Odhodna pot (outbox)

- **Napake so od 2026-08-21 razvrščene** (`ErrorClass`, migracija `046`). Poslovna
  zavrnitev ne porabi poskusov; napaka poverilnice ustavi kanal in naredi en alarm na
  integracijo, ne enega na vsak artikel.
- **Nadomeščeno sporočilo ima svoje stanje** (`Superseded`). Prej je starejše sporočilo
  za isto polje ostalo `Sent` za vedno in je bilo videti kot nepotrjeno.
- **Uskladitev nove šifre ne sloni več samo na EAN** (`out.SaopItemAssignment`): odgovor
  SAOP → zahtevana šifra → enoličen EAN → človek. Dvoumen EAN ni ujemanje.
- **Izmerjeno 2026-08-22: skozi to pot ni šlo nikoli nobeno sporočilo.**
  `out.OutboxMessage` 0, `out.OutboxAttempt` 0, `out.SaopItemAssignment` 0,
  `out.OwnershipPolicy` 0. Koda in shema sta zgrajeni, obratovanje je na ničli.
- **Trije konkretni manjki:**
  1. *Nihče ne piše v outbox.* Ni proizvajalca sporočil — ne iz intraneta, ne iz preslikave,
     ne iz razveljavitve. Tabela je prazna, ker vanjo nihče ne vstavlja.
  2. *Dispatcher obdela natanko eno sporočilo in konča.*
     `workers\PIM.OutboxDispatcher\Program.cs` naredi en `ClaimMessage`, en HTTP klic in
     en `CompleteAttempt`. Ni zanke čez čakalno vrsto.
  3. *Ni razporeda.* `ops.ScheduleProfile` ima vrstice za `SAOP_PRODUCTS`, `GENERIC_XML`,
     `ALERT_DISPATCH` in `WATCHDOG`; za `OUTBOUND` je ni.
- **Kar še ne obstaja:** odhodna pot pošlje spremembo polja, artikla ne ustvari, zato
  `out.ResolveSaopItemAssignment` v živo še nihče ne kliče. Stanje `Error` ostaja mrtva pot.
  Ni urnika, ni dostave na splet, ni živega SAOP klica.

## Trenutno dokazano

- Lokalna intranet konfiguracija je poenotena: edina veljavna datoteka je korenska appsettings.Local.json; PIM.Intranet da prednost PIM_CONNECTION_STRING, nato uporabi ConnectionStrings:Pim iz korenske datoteke. Podrejeni lokalni datoteki sta preimenovani v .zastarelo in ignorirani. Dokaz: /health 200 ter prijavni SQL POST 302 brez SqlException 26, oba brez nastavljene okoljske povezave; polni paket 42/0/0 in Codex VERDICT: PASS.

- Lokalni intranet je dosegljiv na `http://127.0.0.1:5199/prijava`; `/health`, prijava, CSS in pot pod `/PIM` so vrnili HTTP 200.
- `PIM.Migrator --verify` proti razvojni bazi `PIM` je uspešen za F0–F10.
- Celoten build `PIM.sln` je uspešen z 0 opozorili in 0 napakami.
- F6 fixture/stock, F7 B2B, F8 lokalni outbox fixture, F9 nadzor in vsi F10 auth/UX testi so uspešni.
- Dokumentacija je pripravljena: `docs/DATABASE.md`, `docs/WORKERS.md`, `docs/INTRANET.md`, `docs/EXPORTS.md`, `docs/LAPTOP_INSTALL.md`, `docs/END_TO_END_TEST.md` in `docs/TEST_REPORT_E2E.md`.
- Zahteve S1–S7 za sledljivost so implementirane na dejanskem kanoničnem sloju: `canon.Product`, `canon.ProductCommercial`, `canon.ProductText`, `canon.ProductAttribute` in `canon.ProductMedia`. Register lastništva ima 20 sledljivih polj, zgodovina združuje batch/field spremembe, triggerji so množični in uporabljajo `SESSION_CONTEXT`, kartica izdelka pa ima zavihek »Zgodovina«. Migracije `028`–`038` so uporabljene na `PIM`.
- S5/S6 imata omejeno poslovno pot `pim.UndoProductField` in `pim.UndoProductBatch`: dovoljena sta samo za trenutno eksplicitno podprti PIM-lastni polji `WebPublish` in `IsActive`; preverita konflikt, blokirata ponovljeni undo, zavrneta prazen batch ter SAOP/SHARED polja in ob napaki počistita `SESSION_CONTEXT`. Pravi xUnit `PIM.ChangeTracking.Integration` je dokazno izvedel 6/6 primerov.
- `PIM.Watchdog` je povezan z `ops.IntegrationHealth` za lokalni profil `WATCHDOG`; dokazani status je `Healthy`. `PIM.AlertDispatcher` obdrži privzeto izključeno dostavo in pri izrecnem enable zapiše ops run.

## Zaprt regresijski paket

- F3/F5 cleanup je imel FK 547, ne SQL timeout: triggerji sledljivosti so po prvem čiščenju ustvarili novo zgodovino testnega izdelka. Cleanup zdaj drugič ozko odstrani le to zgodovino in njene prazne batche. Podrobnosti in dokaz: `docs/TEST_REPORT_E2E.md`.
- **Testni paket je prvič dokazano zelen v celoti:** `scripts\run_tests.ps1` → **42 uspeli, 0 preskočenih, 0 padlih**, izhod 0. Nič ni preskočeno, kar pomeni, da so se integracijski testi dejansko izvedli proti razvojni bazi `PIM`.
- Prejšnje trditve o zelenem paketu so bile zavajajoče: `dotnet test PIM_Solution\PIM.sln` izvaja **1 projekt od 43** (ostali so konzolne aplikacije, ki jih samo prevede) in je vračal 0, tudi če ni izvedel skoraj ničesar. Od zdaj je edini merodajni ukaz `scripts\run_tests.ps1`.
- UX pogodba kartice izdelka je bila vezana na fiksne številke (3 zavihki, 2 tabeli, 8 stolpcev) in je po dodanem zavihku »Zgodovina« padala. Trditve so zdaj vezane na razmerja; zavihek je bil pred tem preverjen, da ima resničen podatkovni vir.

## Meje, ki ostanejo namerne

Razveljavitev ni generični SQL API: za nova polja je treba najprej dodati njihovo preverjeno poslovno pot in test. Živ SAOP, zunanja dostava, IIS in Scheduled Tasks ostanejo izključeni; outbox ni samodejno aktiviran z undo postopkom brez izrecno omogočenega profila/odobritve. Na laptopu slediti `docs/LAPTOP_INSTALL.md` in `docs/END_TO_END_TEST.md`.
