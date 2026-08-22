# NoviPIM — živ status dela

Posodobljeno: 2026-08-22

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

Dokazi te meritve: `dotnet build PIM_Solution\PIM.sln` → 0 napak;
`PIM.Migrator --verify` → izhod 0; `PIM.B2bWorker --export-magento --organization-id 1`
→ datoteka 1.729 vrstic. `scripts\run_tests.ps1` v tej seji ni bil pognan (zadnji znani
rezultat 44/0/0 z dne 2026-08-21).

**Prvi štirje koraki po vrsti:** (1) ponovna preslikava zajetih strani za trgovinske
podatke (`--map-run`/`--full`), (2) preslikava `GetItemsTitlesLanguage` — spletni nazivi,
(3) poln zajem NW in BT XML, (4) odločitev o profilu za objavo in `val.Promote` za
organizaciji 3 in 4.

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