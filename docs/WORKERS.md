# PIM workerji — operativna dokumentacija

## Pravilo varnega razvoja

Workerji v razvoju uporabljajo samo fixture/replay vsebino, lokalne datoteke in loopback HTTP fixture (`127.0.0.1`). Ne kličejo živega SAOP, Magenta, webhooka ali produkcijskega endpointa. Vsi workerji so run-once programi; v produkciji jih sproža Scheduled Task. Prekrivanje istega pipeline/organizacije preprečuje SQL `sp_getapplock`.

## Workerji

Stolpec »Piše v bazo« loči workerje od lupin. Prej je ta tabela naštevala vhod in izhod tudi
za programe, ki nimajo nobene povezave do baze — podatke v njihovih tabelah so zapisali
integracijski testi, ne workerji. Stanje 13. 8. 2026:

| Worker | Piše v bazo | Vhod | Izhod | Lokalni dokaz |
|---|---|---|---|---|
| `PIM.KatalogWorker` | **da** | SAOP API (Live) ali fixture | `raw.Inbox` → `map` → `canon` | F3 integration; glej [`ZAJEM-SAOP.md`](ZAJEM-SAOP.md) |
| `PIM.XmlFileWorker` | **da** | XML datoteke poljubnega dobavitelja | `raw.Inbox` → `map` → `canon` | F5 integration, F5 value transform |
| `PIM.Watchdog` | **da** (le `ops`) | `ops` zdravstveno stanje | `ops.IntegrationHealth`, `ops.Alert` | F9 tests |
| `PIM.OutboxDispatcher` | **da** (le `out`) | `out.OutboxMessage` | HTTP samo do eksplicitnega profila | F8 local HTTP fixture |
| `PIM.AlertDispatcher` | **da** (le `ops`) | alert queue | dostava alarma | F9 local fixture; dostava privzeto izklopljena |
| `PIM.StockFileWorker` | **ne** | NW CSV / Braytron XML | prebere datoteko in izpiše število zapisov | `StockLandingWriter` obstaja in je dokazan, a ga kliče samo F6 integration |
| `PIM.B2bWorker` | **ne** | — | en `Console.WriteLine` | `B2bLandingWriter` kliče samo F7 MappingTests |
| `PIM.SaopStockWorker` | **ne** | — | en `Console.WriteLine` | F6 SaopProviderTests |
| `PIM.FoundationWorker` | **ne** | — | prazen `BackgroundService` skelet | build |

`PIM.NwXmlWorker` v `workers\` ima samo `bin\` in `obj\`; projekta ni v `PIM.sln` in izvorne
kode ni. Ni worker, je ostanek.

### `PIM.XmlFileWorker` ni vezan na enega dobavitelja

Kaj bere in kako to razume, mu povedo tri spremenljivke okolja in register — v kodi ni ne
imena dobavitelja ne oblike njegovega XML. Nowodvorski ima za vsako lastnost svoj element,
Braytron eno samo obliko z razločevalnim `slug`; poti se ovrednotijo z `XPathNavigator`
(polni XPath 1.0), zato drugo obliko naslovi pogoj v oglatih oklepajih:

```
Nowodvorski   attributes/attribute_ip/ip_value/text()
Braytron      .//attribute[slug="ip"]/value/text()
```

Nov dobavitelj je zato vrstica v `map.SourceConnector`, `map.EntityMapping` in
`map.FieldMapping` — nova različica programa ni potrebna.

```powershell
$env:PIM_CONNECTION_STRING = (Get-Content .\appsettings.Local.json -Raw | ConvertFrom-Json).ConnectionStrings.Pim
$env:PIM_XML_SOURCE_CODE = 'BT_XML'        # ali 'NW_XML'
$env:PIM_XML_ORGANIZATION_ID = '2'
$env:PIM_XML_ROOT = 'C:\Users\David\Desktop\PIM\NoviPIM\PIM_Solution\fixtures\bt'
dotnet run --project PIM_Solution\workers\PIM.XmlFileWorker
```

Isti paket se ne zajame dvakrat: `raw.Inbox` ima enoličnost po (vir, entiteta, stran, hash
vsebine), zato ponoven zagon nespremenjene datoteke pade z napako 2627. To ni okvara, ampak
zaščita pred podvojenim zajemom.

### Kadar se dopolnijo preslikave (2026-08-22)

Ker se ista datoteka ne zajame dvakrat, dopolnjena preslikava sama po sebi ne pride do že
zajetih strani. Zato ima worker dve stikali:

```powershell
# preslikaj zagon, ki je ostal Pending (na primer po --only-ingest ali po padcu)
dotnet run --project PIM_Solution\workers\PIM.XmlFileWorker -- --map-run <RunId>

# preslikaj znova zagon, ki je ze obdelan — strani gredo nazaj na Pending
dotnet run --project PIM_Solution\workers\PIM.XmlFileWorker -- --znova-preslikaj <RunId>
```

`--znova-preslikaj` ničesar ne briše: izluščene vrednosti in katalog se le dopolnijo, ker so
vsi zapisi združevalni (`MERGE` oziroma »vstavi, če še ni«). Podjetje in vir se prebereta iz
zajetih vrstic, zato zadostuje `RunId`; ob koncu worker izpiše stanje po entitetah.

**Hitrost.** Polni datoteki dobaviteljev (19 MB Nowodvorski, 18 MB Braytron) sta bili do
2026-08-22 predraga za preslikavo — 4 GB po žici na stran, 293.000 prevodov XPath in prav
toliko obhodov do strežnika. Po popravku (dve poizvedbi namesto JOIN-a, prevedena pot in
množičen vpis) je celotna datoteka Nowodvorskega **110 s** za vse tri entitete.

### Zaostanek v `raw.Inbox` — `--preslikaj-zaostanek` (2026-08-23)

`--map-run` in `--znova-preslikaj` zahtevata `RunId`. Nočno opravilo ga nima od kod vzeti, zato
ima `PIM.KatalogWorker` še tretje stikalo, ki si zagone poišče samo:

```powershell
$env:PIM_SAOP_MODE = 'Live'   # klica na SAOP kljub temu ni — podatek je že v raw.Inbox
dotnet run --project PIM_Solution\workers\PIM.KatalogWorker -- --preslikaj-zaostanek
```

Vzame **vsak** zagon, ki ima še kakšno vrstico `Pending`, ne glede na vir (SAOP ali dobaviteljev
XML), in ga požene skozi preslikavo. Padec enega zagona ne ustavi ostalih; izhodna koda je 1,
če je kateri padel. Poverilnice za SAOP niso potrebne.

Zakaj obstaja: zaostanek ne nastane zaradi okvare, ampak po zasnovi. Ko se preslikava dopolni,
so strani že zajete in čakajo pod svojim `RunId`, ki ga naslednji zajem ne pozna. Prvi zagon
tega stikala je 2026-08-23 preslikal **223 strani** vseh štirih podjetij, ki so v bazi ležale
od 21. avgusta.

## Standardni dokaz pred namestitvijo

V `PIM_Solution`:

```powershell
$env:PIM_CONNECTION_STRING = '<lokalno-nastavljen-povezovalni-niz>'
dotnet run --project .\tests\PIM.F3.Integration\PIM.F3.Integration.csproj
dotnet run --project .\tests\PIM.F5.Integration\PIM.F5.Integration.csproj
dotnet run --project .\tests\PIM.F6.FileWorkerTests\PIM.F6.FileWorkerTests.csproj
dotnet run --project .\tests\PIM.F6.Integration\PIM.F6.Integration.csproj
dotnet run --project .\tests\PIM.F6.SaopProviderTests\PIM.F6.SaopProviderTests.csproj
dotnet run --project .\tests\PIM.F7.Integration\PIM.F7.Integration.csproj
dotnet run --project .\tests\PIM.F8.Integration\PIM.F8.Integration.csproj
dotnet run --project .\tests\PIM.F9.Integration\PIM.F9.Integration.csproj
```

Pričakovani znaki: F6 fixture test preveri NW=2697 in BT=1361 zapisov; F8 navaja lokalni HTTP fixture in izolirano organizacijo 9808; F9 preveri watchdog in alert recovery.

## Laptop/Windows namestitev

1. Objavi samo potreben worker self-contained:

```powershell
dotnet publish .\workers\PIM.XmlFileWorker\PIM.XmlFileWorker.csproj -c Release -r win-x64 --self-contained true -o C:\PIM\Workers\PIM.XmlFileWorker
```

2. Ustvari lokalno ovojno `.ps1`, ki nastavi `PIM_CONNECTION_STRING`, identifikator organizacije/izvora in lokalno landing mapo. Ne postavljaj skrivnosti v arguments Scheduled Taska.
3. Najprej ročno zaženi ovojnico z fixture mapo in preveri `ops.PipelineRun`, heartbeat, `RowsRead/RowsSucceeded/RowsFailed`, watermark ter karanteno.
4. Šele nato registriraj Scheduled Task pod namenskim najmanj privilegiranim računom.
5. Dva zaporedna zagona istega pipelinea morata dokazati, da drugi ne prekriva prvega.

`deploy/Install-Workers.ps1` in `deploy/Configure-ScheduledTasks.ps1` podpirata `-DryRun`/`-WhatIf`; na laptopu ju uporabi najprej samo za pregled. Ne uporabljaj `LocalSystem` ali `SYSTEM`.

## Monitoring

`PIM.Watchdog` uporablja lokalni profil `WATCHDOG` v `ops.ScheduleProfile` in ob uspehu zapiše `ops.IntegrationHealth=Healthy`. `PIM.AlertDispatcher` dostavlja samo po izrecnem `PIM_ALERT_DELIVERY_ENABLED=true`; brez tega flaga se ustavi pred omrežnim klicem, a tek `ALERT_DISPATCH` vseeno zabeleži (od 2026-09-17), da razpored dobi utrip. Profila ne ustvarita Scheduled Taska in sama po sebi ne omogočita nobene dostave.

Fixture-only workerjev (`SaopStockWorker`, `StockFileWorker`, `B2bWorker`) sistem ne označuje lažno kot živih DB workerjev; dobijo heartbeat šele, ko imajo dejansko povezavo in potrjen lokalni execution contract. Ob napaki preveri `ops.ErrorLog`, `ops.Alert`, `ops.DeadLetterQueue` in specifično karanteno; ne briši sledi, dokler incident ni raziskan.

## Kaj se danes res bere (stanje 2026-08-23)

| Vir | Stanje |
|---|---|
| SAOP katalog | **dela in je preslikan v celoti** — vseh 16 končnih točk ima cilj v modelu (migracija `087`). Preslikano: izdelki, opisi, cene, nazivi po jezikih, lastnosti po meri, pravilo zaloge, skladišča, jeziki, valute, ceniki, tehnološki proces, konti zaloge, planiranje, stranke, artikel pri stranki, popusti po skupinah |
| Dobaviteljev XML (NW, BT) | **dela** — obe datoteki v celoti, za vsa štiri podjetja. Braytron ima od `087` tudi slike (1.384 izdelkov); Braytronovih kategorij namenoma ni — glej spodaj |
| SAOP zaloge | **pot je narejena in dokazana lokalno; živ klic čaka tebe** — `PIM.SaopStockWorker` bere profil iz `stock.SaopProviderProfile`, šifre skladišč iz `canon.Warehouse` in zapiše v `stock.*`. Klic izvede samo pri `PIM_SAOP_MODE=Live` |
| SAOP šifrant skladišč | **dela** — `canon.Warehouse`: DEMO 7, IQLighting 35, Vidadria 74, Ediito 15 skladišč s šiframi in imeni |
| Zaloge dobaviteljev | **dela za vsa štiri podjetja** (`087`) — `PIM.StockFileWorker` zapiše zalogo v `stock.*`; NW 2.697 in BT 1.361 vrstic na podjetje, 0 v karanteni. Datoteko je treba položiti v mapo, prevzem s FTP je zunanji klic |
| Šifranti in B2B (7 entitet) | **dela** (`082`, `087`) — valute 181, ceniki 7–31 in tehnološki proces 5–101 na podjetje v `canon.Codebook`; stranke 11.558, artikel pri stranki 9.207 in popusti po skupinah 4.270 v `b2b.*` |

**Braytronove kategorije namenoma niso preslikane.** Sama preslikava ne bi naredila ničesar:
`map.ResolveProductCategories` gre čez drevesa iz `map.CategoryPathMap` za ta vir, in za
`BT_XML` tam ni nobene vrstice — brez odločitve, v katero drevo Braytronove družine
(`main_family`/`sub_family`) sodijo, ne nastane ne vrstica v katalogu ne vrstica v delovnem
seznamu manjkajočih. To je poslovna odločitev in je v `TASKBOARD.md`.

## PIM.StockFileWorker — zaloga dobavitelja od datoteke do baze

```powershell
$env:PIM_CONNECTION_STRING = (Get-Content .\appsettings.Local.json -Raw | ConvertFrom-Json).ConnectionStrings.Pim
dotnet run --project PIM_Solution\workers\PIM.StockFileWorker -- --file PIM_Solution\fixtures\stocks\nw\NOWODVORSKI.csv
```

| Argument | Pomen | Privzeto |
|---|---|---|
| `--file` | pot do datoteke (obvezno) | — |
| `--source` | `NW_STOCK` ali `BT_STOCK` | iz končnice: `.xml` = Braytron, ostalo = Nowodvorski CSV |
| `--organization-id` | podjetje | 2 |
| `--endpoint` | oznaka vira v `stock.SyncRun` | `file://<ime datoteke>` |
| `--date-format` | oblika datuma v datoteki | iz vira: Braytron `yyyy-MM-dd`, Nowodvorski `dd/MM/yyyy` |
| `--samo-preberi` | prebere in prešteje, v bazo ne piše | izklopljeno |

Posnetek nosi čas datoteke, ne čas zagona — ista datoteka je zato isti posnetek. Konektor in
pravilo identitete (`map.SourceConnector`, `map.StockIdentityRule`) morata obstajati; worker si
ju ne izmišlja. Izhod je 1, kadar ni bila uporabljena nobena vrstica in je karantena neprazna.

**Ista datoteka drugič ni napaka** (popravljeno 2026-08-23). `stock.Snapshot` ima enoličnost
(podjetje, konektor, čas posnetka), zato je drugi zagon nespremenjene datoteke po zasnovi
podvojen ključ. Doslej je to končalo kot neujeta `SqlException 2627` in worker je padel s
sledjo sklada — v nočnem opravilu pravilo, ne izjema, saj dobavitelj datoteke ne posodobi vsak
dan. Zdaj worker pove `Ta posnetek je ze v bazi ... Zapisano ni bilo nic.` in vrne 0.

**Zaloga se ujame samo z artiklom istega podjetja** (migracija `088`). `stock.ApplyLandingRecord`
je od migracije `018` iskal artikel brez pogoja po podjetju; dokler je zalogo imelo samo
podjetje 2, se to ni poznalo. Ko je `087` zalogo vklopil za vsa štiri, je isti stavek začel
vezati zalogo enega podjetja na artikel drugega. Dokaz po popravku — ujetih vrstic na podjetje:
NW 1.066 / 2.455 / 2.461 / 131, BT 5 / 215 / 1.296 / 40, in nobene pozicije, vezane na artikel
tujega podjetja.

## PIM.SaopStockWorker — količine zaloge iz SAOP

Med šestnajstimi zajetimi končnimi točkami dejanskih količin ni: `GetItemsStockData` nosi
najmanjšo in največjo zalogo po skladišču, `GetItemsStockAccountingData` pa konte. Količine so
na ločenem vmesniku, in katerega uporabimo, je vrstica v `stock.SaopProviderProfile` (migracija
`065`), ne nastavitev v kodi.

| Podjetje | Profil | Vmesnik | Stanje |
|---|---|---|---|
| 1, 2, 3, 4 | `SAOP_GETSTOCKS` | `api/Stock/GetStocks` | vklopljen |
| 3 (Vidadria) | `SAOP_REGISTERED_VIEW` | `api/registeredviews/data` | izklopljen, dokler ni znan `RegisteredViewId` |

Skladišča: `WarehouseSelectionMode = 'ActiveFromRegister'` pomeni vsa aktivna skladišča podjetja
iz `canon.Warehouse` (migracija `064`). V zahtevo gre **samo šifra**; ime je v registru zaradi
prikaza.

```powershell
$env:PIM_CONNECTION_STRING = (Get-Content .\appsettings.Local.json -Raw | ConvertFrom-Json).ConnectionStrings.Pim
dotnet run --project PIM_Solution\workers\PIM.SaopStockWorker -- --organizations 2 --samo-nastavitve
$env:PIM_SAOP_MODE = 'Live'   # brez tega worker samo izpiše, kaj bi poklical
dotnet run --project PIM_Solution\workers\PIM.SaopStockWorker -- --organizations 2
```

Dokaz brez živega SAOP je `PIM.F6.SaopStockIntegration`: lokalni strežnik na `127.0.0.1` vrne
odgovor in posname zahtevo — preverjeno je, da gre na `GetStocks`, da nosi šifre skladišč in
glavo `OrganisationId`, da se znan artikel ujame v pozicijo zaloge in da neznan ne izgine
(pozicija brez izdelka, `MatchKey = 'Unmatched'`).

## Registrirani pogled SAOP za Vidadrio (migracija 145, 2026-09-02)

Uporabnik: »zaloga VID se bere iz registriranega pogleda, IQ pa iz GetStocks, ker SAOP pogleda za
IQ ni omogočil«. Profil `SAOP_REGISTERED_VIEW` (podjetje 3, `RegisteredViewId
16c34ea5-b65d-4954-a699-40f47af11243`, Priority 5) je vklopljen in zmaga pred `SAOP_GETSTOCKS`
(Priority 10). Pogodba je **POST** `api/registeredviews/data` z XML telesom
`GetDataFromRegisteredViewRequest` (RegisteredViewID, ResultPageNumber, ResultPageSize 1000,
prazna Filter/OrderBy), odgovor je stranjen — worker bere, dokler stran ni krajša od zahtevane.
Vsaka vrstica `<Row>` nosi pet količin: `TrenutnaZalogaL` → `Quantity`, `NarocenaKolicina` →
`OrderedQuantity`, `ZaOdpremoKolicina` → `ForShipmentQuantity`, `RazpolozljivaKolicina` →
`AvailableQuantity`, `NarocenaKolicinaDobaviteljem` → `SupplierOrderedQuantity`
(`stock.LandingRecord` besedilo, `stock.Position` število; drugi viri imajo tam NULL). Šifra
»NW. 1234« se ob zajemu popravi v »NW.1234«. Prejšnja izvedba je pošiljala GET `?viewId=`, ki ga
API ne pozna; napaka je bila nevidna, ker je bil profil izklopljen. Živi zajem 2026-09-02: 3.156
vrstic, 21 neujetih, 0 v karanteni. Dokaz: `run_tests.ps1 -Filter F6` (lokalni strežnik posname
POST telesa in dve strani).

## Petminutni cikel izvozi tudi cene in zalogo za splet (2026-09-03)

`scripts\Zaloga-cikel.ps1` po zajemu zaloge požene `PIM.B2bWorker --export-profile
MAGENTO_STOCK_PRICES` za vsa podjetja v `izvoz\magento\<podjetje>\magento-stock-prices.csv`
(glej `docs/EXPORTS.md` §3z). Skripta si povezavo vzame iz `appsettings.Local.json`, ker
`PIM.B2bWorker` bere samo `PIM_CONNECTION_STRING`. Nočni tok (`Nocno-vse.ps1`) od 2026-09-03 ne
bere več označevalnih datotek `*.pocakaj` in `*.prenos` kot zalogo — to je bil vzrok, da je korak
»Zaloge dobaviteljev« 2026-09-02 padel z eno vrstico v karanteni.

## SAOP katalog na strežniku in VatRateId (2026-09-15)

`Product.VatRateId` (šifra DDV, ERP_L1_SLO ga zahteva) je bil prazen pri vseh artiklih razen enega,
čeprav SAOP `GeneralData/VATRateID` pošilja pri vseh in je preslikava `map.FieldMapping`
`GeneralData/VATRateID/text()[1] → Product.VatRateId` aktivna pri vseh štirih SAOP konektorjih.
Vzrok ni bil v preslikavi, ampak v tem, da katalog iz SAOP nihče ni bral:

- zadnje uspešno branje `GetItemsGeneralData` je bilo 2026-09-02 (poln) in 2026-09-03 (delta), še
  preden je bila preslikava dodana; delta bere samo spremenjene artikle, zato nespremenjeni nikoli
  niso dobili nove vrednosti;
- 2026-09-09 ob 00:30 je branje padlo pri vseh štirih podjetjih (`ops.ErrorLog`: SAOP
  `192.168.178.12:81` se ni odzval), potem je nočni tok z razvojnega računalnika izginil;
- `deploy\Configure-WorkerScheduledTasks.ps1` `PIM.KatalogWorker` sploh ni imel, SAOP workerja pa
  sta tekla brez `PIM_SAOP_MODE=Live` in zato SAOP-a nista klicala (izpišeta, kaj bi poklicala, in
  končata z 0).

Popravek: skripta na strežniku zdaj registrira `PIM-SaopKatalog` (delta vsako uro) in
`PIM-SaopKatalogPoln` (poln zajem enkrat na teden — pobere tudi polja z naknadno dodano preslikavo),
v vse `.bat` SAOP workerjev pa zapiše `set PIM_SAOP_MODE=Live`. Po prvi namestitvi se
`PIM-SaopKatalogPoln` enkrat požene ročno (`Start-ScheduledTask`).

**Zastoj pri preslikavi (popravljeno 2026-09-15).** Prvi poln zajem po popravku je tekel hkrati z
urno validacijo (`Katalog-cikel.ps1`); `map.ProcessRawInbox` se je z `val.RunValidation` ujel v
zastoj (SQL 1205) in stran v svojem `CATCH` poslal v karanteno — 8 strani, med njimi 5 od 6 strani
Vidadrie, zato je tam `VatRateId` dobilo samo 3.882 od 22.842 artiklov, v `map.UnmappedValue` pa je
nastalo ~1,07 milijona lažnih zavrnitev. `SqlMappingPipeline.ExtractAndApplyAsync` zdaj po klicu
`map.ProcessRawInbox` strani, ki so v karanteni samo zaradi zastoja (`FailureReason` vsebuje
»deadlock«), vrne na `Pending`, pobriše njihove lažne zavrnitve in postopek ponovi (do trikrat, s
premorom 5/10/15 s). Na strežniku se urno branje kataloga in izvoz z validacijo lahko prekrivata,
zato brez tega podatek tiho izgine do naslednjega polnega zajema.

Ročni poln zajem artiklov (branje iz SAOP, samo `GetItemsGeneralData`), iz mape `PIM_Solution`:

```powershell
$env:PIM_SAOP_MODE = 'Live'
dotnet run --project workers\PIM.KatalogWorker -- --endpoints GetItemsGeneralData --full --max-parallel 4
```

## Izvoz kataloga sam osveži validacijo; razpored za B2B worker (2026-09-14)

`PIM.B2bWorker --export-magento --osvezi-validacijo` pred izvozom za podjetje požene
`val.RunValidation` in `val.Promote` (znotraj istega `ops.BeginRun`, s heartbeatom po koraku).
Katalog vzame samo izdelke, ki so VALID in promovirani v `pim.*`. `Katalog-cikel.ps1` in
`Nocno-vse.ps1` ta korak naredita sama pred klicem workerja; namenski strežnik pa workerja zažene
neposredno iz Scheduled Taska (`deploy\Configure-WorkerScheduledTasks.ps1`, naloga
`PIM-MagentoProducts`), zato ima tam stikalo. Izmerjeno 2026-09-14 na razvojni bazi: podjetje 2
(111.078 izdelkov) 520 s skupaj, večino validacija.

Worker od 2026-09-14 vsak zagon začne z `ops.BeginRun`, ki brez vrstice v `ops.ScheduleProfile`
pade z 51100. Vrstici `MAGENTO_PRODUCTS` (3600 s) in `MAGENTO_STOCK_PRICES` (300 s) za vsa podjetja
doda migracija 201. Kaj gre v datoteki, je v `docs/EXPORTS.md` §3z.

## Nočno opravilo — vsi vhodi na en zagon (2026-08-23)

Do zdaj je načrtovana naloga poganjala samo zajem iz SAOP (`scripts\Nocni-zajem.ps1`). Vse
ostalo — dobaviteljev XML, zaloge, spletni nazivi, preslikava zaostanka, validacija, objava in
izvoz — je bilo treba pognati ročno. Zato je bil katalog svež, vse drugo pa staro toliko,
kolikor časa ni nihče ničesar pognal.

```powershell
# ročni zagon
powershell -ExecutionPolicy Bypass -File scripts\Nocno-vse.ps1

# vse razen klica na ERP (za preizkus ali kadar je SAOP v vzdrževanju)
powershell -ExecutionPolicy Bypass -File scripts\Nocno-vse.ps1 -BrezSaopKataloga
```

Koraki in njihov vrstni red:

| # | Korak | Zakaj tu |
|---|---|---|
| 0 | gradnja | workerji tečejo z `--no-build`; če gradnja pade, se ne poganja nič |
| 1 | SAOP katalog | nova šifra artikla mora obstajati, preden jo kdo obogati |
| 2 | dobaviteljev XML (NW, BT) | lastnosti, kategorije in slike se vežejo na artikel po EAN |
| 3 | spletni nazivi | zvezki se vežejo na artikel po šifri (samo če je podana mapa) |
| 4 | preslikava zaostanka | kar je ostalo `Pending`, pride v katalog, **preden** objava pogleda, kaj ima |
| 5 | zaloge dobaviteljev | za **vsa** podjetja, ne le za privzeto |
| 6 | zaloga iz SAOP | samo s stikalom `-ZalogaIzSaop` — živ klic je odločitev človeka (`AGENTS.md` §4.5) |
| 7 | validacija in objava | šele ko so vsi podatki v katalogu |
| 8 | Magento izvoz | iz objave |

Padec enega koraka ne ustavi ostalih; izhodna koda je število padlih korakov. Dnevnik gre v
`logs\nocno_<datum>_<ura>.log`, dnevniki starejši od 90 dni se pobrišejo.

**Povzetek pove tudi, kaj je ostalo neobdelano** (`raw.Inbox`: `Pending` in `Quarantined`).
Brez tega je »vse OK« lahko pomenilo, da so koraki tekli, podatek pa je ostal ležati — natanko
to se je dogajalo mesece.

**Varovalka za prekrivanje ne gleda samo statusa.** Vrstica `Running` v `ops.PipelineRun` ni
dokaz, da kaj teče: zagon, ki mu je proces umrl, ostane `Running` za vedno (ob pisanju te
skripte jih je bilo v razvojni bazi deset, najstarejši iz julija). Blokira samo zagon, ki je
hkrati `Running`, je zadnji za svoj cevovod v `ops.IntegrationHealth` **in** je utripnil v
zadnjih 15 minutah. Zapuščene zagone skripta prijavi kot opozorilo in nadaljuje.

**Poizvedbe gredo skozi `sqlcmd`, ne skozi ADO.NET.** `Microsoft.Data.SqlClient` je paket NuGet
in ne del PowerShella; ročno naložen iz izhoda gradnje potrebuje še domorodni
`Microsoft.Data.SqlClient.SNI.dll`, ki ga `Add-Type` ne najde. Prejšnja različica skripte bi
zaradi tega padla že ob prvi poizvedbi — in to šele ponoči.

### Načrtovana naloga Windows

Registracija je **sistemska nastavitev** in po `AGENTS.md` §4.7 na zaprtem seznamu: požene jo
človek, ne agent. Ukaz je zapisan, da je ponovljiv:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\Namesti-nocno-opravilo.ps1            # privzeto vsak dan ob 02:30
powershell -ExecutionPolicy Bypass -File scripts\Namesti-nocno-opravilo.ps1 -Ura 03:15
powershell -ExecutionPolicy Bypass -File scripts\Namesti-nocno-opravilo.ps1 -Odstrani
```

Naloga teče pod tvojim računom, se ne podvaja (`IgnoreNew`) in nadoknadi zamujen zagon
(`StartWhenAvailable`). Živi klic na SAOP za količine zaloge **ni** vklopljen; ko se odločiš,
da sme teči, dodaj `-ZalogaIzSaop` med argumente v tej skripti in nalogo registriraj znova.

**Izmerjeno 2026-08-23** (brez koraka 1, ker je živ klic tvoja odločitev): 6 korakov, 0 padlih,
2 min 39 s; `raw.Inbox` `Pending` 0. Validacija in objava štirih podjetij 120 s, Magento izvoz
štirih podjetij 12 s.

## Ročni zagon, izpis v živo in dnevniki v intranetu (2026-09-15)

> Od 2026-09-17 razdelek »Kaj teče samo od sebe« nadomešča razporejevalnik v aplikaciji — glej
> zadnji razdelek »Razporejevalnik v aplikaciji (2026-09-17, migracija 221)«. Windows naloge niso
> več potrebne; cikli tečejo v procesu intraneta, ne prek PowerShell skript.

Stran **Nadzor sistema → Workerji** (`/sistem/workerji`, samo ADMIN). Nastala je, ker je do
15. 9. šest dni tekel samo katalog: po selitvi repozitorija v `Documents\GitHub\PIM` je bila znova
registrirana ena Windows naloga od štirih (»PIM katalog«). Zaloga, nadzor in nočni tok niso tekli,
razpored v bazi pa je kazal vse vklopljeno.

| Razdelek | Kaj pokaže ali naredi |
|---|---|
| Kaj teče samo od sebe | Ali so naloge »PIM zaloga«, »PIM katalog«, »PIM nadzor«, »PIM nocni tok« in »PIM samotest« registrirane (`schtasks /Query`), naslednji zagon in kdaj je cikel zadnjič pisal v dnevnik. Za manjkajočo nalogo pokaže ukaz, ki jo registrira. |
| Ročni zagon | Cikli (iste skripte kot naloge) in posamezni workerji, za vsa podjetja ali eno. Posel, ki kliče SAOP ali dobavitelja ali pošlje e-pošto, zahteva še en klik. Izklopljen razpored je označen in ga lahko vklopiš kar tam. |
| Izpis | Izpis v živo; napake rdeče, opozorila rumena, filter »samo napake«. Zagon se lahko ustavi, kar ubije celo drevo procesov. |
| Dnevniki | Vse datoteke v `logs` in `logs\workerji`, najnovejše najprej, s številom napak v zadnjih 64 KB. Odpre se konec datoteke, do 512 KB. |

**Kako teče.** `WorkerConsoleService` (singleton v intranetu) požene skripto prek
`powershell -Command` ali worker prek `dotnet run --no-build`, enako kot skripte same. Workerju
poda povezavo, ki jo uporablja intranet (`PIM_CONNECTION_STRING`), da piše v isto bazo, ki jo
stran kaže. Vsak ročni zagon piše `logs\workerji\<posel>_<datum>_<ura>.log` z glavo (kdo, kdaj,
podjetja) in zadnjo vrstico `=== KONEC: izhod N`. Isti posel ne teče dvakrat hkrati; prekrivanje
z načrtovano nalogo prepreči `ops.BeginRun`. Zagon in ustavitev gresta v sled sprememb
(`WORKER_RUN`, `WORKER_CANCEL`).

**Omejitve.**

- Ročni zagon ne obide izklopljenega razporeda (51100). To je namen varovalke po zaporednih napakah; razpored se vklopi na isti strani.
- Pod IIS zagon teče pod računom aplikacijskega bazena in se ob recikliranju bazena prekine.
- **Strežnik brez izvorne kode (2026-09-16).** Objavljen intranet nad sabo nima `PIM.sln`, zato je stran do zdaj pisala »izvorne kode ni«. Odslej: `deploy\Publish-All.ps1` objavi intranet, `Workerji\<Worker>\<Worker>.exe` in `scripts\` v **eno mapo**; to mapo prekopiraš čez mapo spletnega mesta (`docs/PUBLISH.md` 1.4) in stran `Workerji\` ter `scripts\` najde ob sebi brez nastavitev (`WorkerConsoleLayout`). Posamezni workerji tečejo kot `.exe`; cikli (skripte) dobijo `-MapaWorkerjev` in prek `scripts\Workerji.ps1` poženejo `.exe` namesto `dotnet run` — tudi `Workerji.ps1` in `Namesti-opravila.ps1` vzameta `<koren>\Workerji` sama, če obstaja. Posel, ki ga na tem strežniku ni (ni `.exe`, ni `scripts\`), ima gumb izklopljen z razlogom. Če so workerji ali skripte drugje, to povedo ključi `WorkerConsole:PublishedWorkersRoot`, `RepositoryRoot`, `LogRoot` v `appsettings.Local.json` ob intranetu (primer: `PIM_Solution\appsettings.Local.example.json`). Skripte povezavo berejo iz okolja, `appsettings.Local.json` ali `appsettings.json` v korenu (`Sql.ps1`), koren prevzema pa iz registra `LANDING_ROOT` — isto kot prevzemnik (`PimPotPrevzema`), da se ne razideta.
- Račun bazena ne vidi nalog drugega uporabnika. Razdelek z nalogami lahko tam kaže »ni registrirana«, čeprav je; sporočilo schtasks je v stolpcu stanja.
- Register `LOG_ROOT` v `ops.SystemPath` ne bere nobena skripta. Stran zato bere `<koren>\logs`, kamor skripte res pišejo.

Naloge registrira `powershell -ExecutionPolicy Bypass -File scripts\Namesti-opravila.ps1`.
PowerShell 7 (`pwsh`) na razvojnem računalniku ni nameščen, zato so ukazi v tej datoteki in v
skriptah `Namesti-*.ps1` zamenjani na `powershell`.

### Datumi dobave iz SAOP niso tekli nikoli (popravljeno 2026-09-15)

`PIM.SaopStockWorker --dostave` je tek odpiral pod imenom `SAOP_DELIVERY_DATES`, razpored v bazi
(migracija 164) pa se imenuje `SAOP_DELIVERY`. `ops.BeginRun` je zato vsak zagon zavrnil z 51100;
v `ops.PipelineRun` ni bilo niti ene vrstice. Worker zdaj uporablja `SAOP_DELIVERY`. Po popravku
nočni tok v koraku »Zaloga iz SAOP (datumi prihoda)« zares kliče `GetItemDeliveryDate`, do 300
artiklov na podjetje.

**Migracije 155–168, 176, 179 in 180 so uporabljene v bazi `DAVID\MSSQL19`, v repozitoriju pa jih
ni.** Za 164, 167 in 180 je preverjeno, da niso bile nikoli dodane v Git. Brez teh datotek se baza
iz repozitorija ne da sestaviti znova.

## Razporejevalnik v aplikaciji (2026-09-17, migracija 221)

Uporabnik: »zakaj na IIS-ju ne delajo workerji, v aplikaciji pa delajo. Naredi mi, da mi bodo
workerji delali ne glede, kje je aplikacija postavljena.« Pod IIS je bila stran `/sistem/workerji`
rdeča: aplikacijski bazen Windows nalog drugega uporabnika ne vidi (`schtasks`: »Access is
denied«), registrirati jih ne sme, objavljen intranet pa nad sabo nima ne `PIM.sln` ne `sqlcmd`,
ki ju skripte ciklov potrebujejo. Nič ni sprožilo ciklov.

**Odslej je ura v intranetu.** `WorkerSchedulerService` (gostujoča storitev v `PIM.Intranet`)
vsakih 30 s obnovi najem v `ops.SchedulerLease`; kdor ga drži, požene cikle, ki so na vrsti, in
preveri zaostanek. Cikli so opisani v C# (`Services/WorkerSchedulerPolicy.cs`, `WorkerCycles`) —
isti workerji in isti vrstni red korakov kot v skriptah — in tečejo v procesu intraneta
(`WorkerCycleRunner`): worker je otroški proces (objavljen `.exe` ali `dotnet run --no-build`),
validacija in objava sta SQL koraka z istim ponovnim poskusom ob zastoju (1205) kot `Sql.ps1`.
PowerShell in `sqlcmd` nista več potrebna.

| Cikel | Razpored | Kaj naredi |
|---|---|---|
| `zaloga` | vsakih 5 min | NW FTP in BT XML zaloga (prevzem + branje za vsa podjetja), zaloga iz SAOP, cene iz SAOP (GetPrices), izvoz cen in zaloge za splet, osvežen katalog.csv/stranke.csv (podjetje 2), na koncu datumi dobave iz SAOP po svojem razporedu (30 min) |
| `katalog` | vsako uro | SAOP katalog (delta, kot `PIM-SaopKatalog` s strežnika), naročila iz SAOP (VNK/VND), validacija in objava vseh podjetij, poln izvoz kataloga in strank (podjetje 2) |
| `nadzor` | vsakih 5 min | `PIM.Watchdog`, `PIM.AlertDispatcher` |
| `nocni-tok` | vsak dan ob 02:30 | `Nocno-vse.ps1 -ZalogaIzSaop`: (razvoj: gradnja workerjev), SAOP katalog (poln 1. v mesecu), prevzem, dobaviteljev XML (prevzeta datoteka, sicer fixtures), preslikava zaostanka, zaloge dobaviteljev, SAOP zaloga in datumi dobave, validacija in objava, izvoz, dnevni mail »Zaloga pod MID« (`STOCK_REPLENISHMENT_DIGEST`, doslej ga ni poganjal nihče) |
| `samotest` | vsak dan ob 04:30 | `PIM.SelfTest.Nightly` — objavljen ob workerjih ali `dotnet run` iz izvorne kode |

Razpored (razmik ali dnevna ura) in vklop sta vrstica v `ops.WorkerCycle` in se urejata na
`/sistem/workerji`; sprememba velja od naslednjega tika. Razpored posameznih postopkov
(`ops.ScheduleProfile`, `--po-urniku`) ostaja: razporejevalnik ga spoštuje, ročni zagon s strani ga
obide (kot skripta brez `-PoUrniku`).

**Podvajanje.** `ops.ClaimWorkerCycle` je edina pot do zagona cikla: pod ključem vrstice preveri,
da cikel ne teče in da je na vrsti, in ga oznaci kot tekočega; dva intraneta nad isto bazo (IIS +
Visual Studio) dobita en zagon in en »že teče«. Stare skripte se same umaknejo, kadar intranet drži
najem (`Sql.ps1`, `PimRazporejevalnikVAplikaciji`; ročni zagon z `-Vseeno`); stran pokaže
»Podvojeno«, če skripta kljub temu piše svoj dnevnik. Windows naloge odstrani:
`scripts\Namesti-opravila.ps1 -Odstrani` in `scripts\Namesti-samotest.ps1 -Odstrani`.

**Dnevnik in sled.** Vsak zagon cikla je vrstica v `ops.WorkerCycleRun` (kdo, kdaj, gostitelj,
stanje, izhodna koda, korak v teku, utrip) s koraki v `ops.WorkerCycleStep` (trajanje, izhodna
koda, ukaz) — vidno na strani pod »Zgodovina zagonov ciklov«, tudi po ponovnem zagonu intraneta.
Besedilni dnevnik je `logs\cikli\<posel>_<datum>_<ura>.log` (ročni zagoni workerjev ostanejo v
`logs\workerji`). `ops.PipelineRun.TriggeredBy` je zdaj res `Scheduler`/`Human`/`Task`
(`OperationsRun.BeginAsync` bere `PIM_TRIGGERED_BY`; doslej je bilo vse `Human`).

**Zaostanek.** Uporabnik: »če je na 5 min naštiman in je že 10 min v mirovanju, je treba
opozorilo dati.« `ops.RaiseOverdueAlerts` (vsak tik) odpre alarm `CycleOverdue` za cikel in
`PipelineOverdue` za postopek, kadar od zadnjega začetka (cikel) oziroma zadnjega utripa
(postopek) mine več kot 2× razmik; zapre se sam ob naslednjem teku. Stran kaže ritem vsakega
cikla (»V ritmu«, »Zamuja«, »ZASTAL«), naslednji termin in kdo je bil zadnji. Alarmi so v zvoncu
(vrste `CycleOverdue`, `PipelineOverdue` in prej manjkajoča `PipelinePaused` so dodane v
`intranet.UserAlertSubscription`). Migracija je uskladila razporede, ki jih nič ne poganja tako
pogosto: `GENERIC_XML` na en dan (bere ga samo nočni tok), `MAGENTO_PRODUCTS` izklopljen za
podjetja 1, 3, 4 (katalog je samo podjetje 2), `SAOP_ORDERS` izklopljen (nadomeščen z VNK/VND).

**Postopek, ki nima kaj delati, se vseeno zabeleži.** Alarm zastalosti meri utrip razporeda, zato
worker, ki je po nastavitvah preskočil delo, odpre in takoj zapre `ops.BeginRun`: `PIM.AlertDispatcher`
brez `PIM_ALERT_DELIVERY_ENABLED=true` (postopek `ALERT_DISPATCH`), `PIM.SaopOrdersWorker` za podjetje
brez nastavljene knjige (`SAOP_ORDERS_VNK`/`SAOP_ORDERS_VND`, `Saop:Organizations:SalesOrderBook`/
`PurchaseOrderBook`). Pred tem sta bila ta postopka večno »ni tekel N min«, čeprav ju je cikel
vsakič preveril; dnevnik cikla še vedno pove, da je bilo preskočeno in zakaj.

**IIS.** Bazen brez zahtev ugasne po 20 minutah; intranet se zato pod IIS sam kliče na `/health`
(`Scheduler:KeepAliveMinutes`, privzeto 5, naslov izve ob prvi zahtevi). Po recikliranju bazena
nov proces nastane šele ob prvi zahtevi — zato `deploy\Configure-IisAlwaysRunning.ps1` (kot
administrator): `startMode=AlwaysRunning`, `idleTimeout=0`, `preloadEnabled` (Application
Initialization). Kar med izpadom ni teklo, pove alarm `CycleOverdue`. Objava mora prinesti
workerje: `dotnet publish PIM.Intranet` (cilj `PimPublishWorkersAndScripts`, `deploy\Publish-All.ps1`)
odloži `Workerji\` ob intranet, zdaj tudi `PIM.SelfTest.Nightly`; brez te mape stran pove, kaj
manjka, razporejevalnik pa ciklov ne poganja in alarmi zastalosti se odprejo — kar je res.
Mapa dnevnikov pod IIS praviloma ni zapisljiva za račun bazena: razporejevalnik takrat piše v
`%TEMP%\PIM\logs` in to pove na strani; nastavi `LOG_ROOT` na `/administracija/mape`.

**Lokalne nastavitve workerjev.** Worker, ki ga požene razporejevalnik, bere `appsettings.Local.json`
po vrsti: ob svojem `.exe`, ob intranetu nad `Workerji\` (objava v eno mapo — ena datoteka za
intranet in vse workerje), v korenu rešitve (`PIM_Solution`) in v korenu repozitorija (isti vir kot
skripte ciklov, `Sql.ps1`); tam so na razvojnem računalniku SAOP in FTP poverilnice
(`PIM.Operations.LocalSettings.Sources`). Povezavo do baze dobi od intraneta prek
`PIM_CONNECTION_STRING`, zato piše v isto bazo, ki jo stran kaže.

Nastavitve (`appsettings.Local.json` ob intranetu ali okolje): `Scheduler:Enabled` /
`PIM_SCHEDULER_ENABLED=false` izklopi uro v tem procesu (npr. razvojni intranet, ki ne sme
poganjati ciklov), `Scheduler:TickSeconds` (30), `Scheduler:LeaseSeconds` (90),
`Scheduler:KeepAliveMinutes` (5, 0 = brez). Dokaz: `PIM.F10.IntranetLogicTests`
(`WorkerSchedulerChecks`: katalog ciklov, načrt korakov, naslednji termin, presoja zaostanka).
