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
