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

`PIM.Watchdog` uporablja lokalni profil `WATCHDOG` v `ops.ScheduleProfile` in ob uspehu zapiše `ops.IntegrationHealth=Healthy`. `PIM.AlertDispatcher` uporablja `ALERT_DISPATCH` samo po izrecnem `PIM_ALERT_DELIVERY_ENABLED=true`; brez tega flaga se ustavi pred povezavo oziroma omrežnim klicem. Profila ne ustvarita Scheduled Taska in sama po sebi ne omogočita nobene dostave.

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

## Nočno opravilo — vsi vhodi na en zagon (2026-08-23)

Do zdaj je načrtovana naloga poganjala samo zajem iz SAOP (`scripts\Nocni-zajem.ps1`). Vse
ostalo — dobaviteljev XML, zaloge, spletni nazivi, preslikava zaostanka, validacija, objava in
izvoz — je bilo treba pognati ročno. Zato je bil katalog svež, vse drugo pa staro toliko,
kolikor časa ni nihče ničesar pognal.

```powershell
# ročni zagon
pwsh -File scripts\Nocno-vse.ps1

# vse razen klica na ERP (za preizkus ali kadar je SAOP v vzdrževanju)
pwsh -File scripts\Nocno-vse.ps1 -BrezSaopKataloga
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
pwsh -File scripts\Namesti-nocno-opravilo.ps1            # privzeto vsak dan ob 02:30
pwsh -File scripts\Namesti-nocno-opravilo.ps1 -Ura 03:15
pwsh -File scripts\Namesti-nocno-opravilo.ps1 -Odstrani
```

Naloga teče pod tvojim računom, se ne podvaja (`IgnoreNew`) in nadoknadi zamujen zagon
(`StartWhenAvailable`). Živi klic na SAOP za količine zaloge **ni** vklopljen; ko se odločiš,
da sme teči, dodaj `-ZalogaIzSaop` med argumente v tej skripti in nalogo registriraj znova.

**Izmerjeno 2026-08-23** (brez koraka 1, ker je živ klic tvoja odločitev): 6 korakov, 0 padlih,
2 min 39 s; `raw.Inbox` `Pending` 0. Validacija in objava štirih podjetij 120 s, Magento izvoz
štirih podjetij 12 s.
