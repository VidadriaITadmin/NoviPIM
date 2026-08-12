# PIM workerji — operativna dokumentacija

## Pravilo varnega razvoja

Workerji v razvoju uporabljajo samo fixture/replay vsebino, lokalne datoteke in loopback HTTP fixture (`127.0.0.1`). Ne kličejo živega SAOP, Magenta, webhooka ali produkcijskega endpointa. Vsi workerji so run-once programi; v produkciji jih sproža Scheduled Task. Prekrivanje istega pipeline/organizacije preprečuje SQL `sp_getapplock`.

## Workerji

| Worker | Vhod | Izhod | Lokalni dokaz |
|---|---|---|---|
| `PIM.KatalogWorker` | SAOP katalog fixture | `raw.Inbox` → catalog pipeline | F3 integration |
| `PIM.XmlFileWorker` | XML datoteke, npr. NW | `raw.Inbox` → `map` → `canon` | F5 integration |
| `PIM.StockFileWorker` | NW CSV / Braytron XML | `stock.LandingRecord`, snapshot, position | F6 FileWorkerTests + F6 integration |
| `PIM.SaopStockWorker` | SAOP stock provider | stock pipeline | F6 SaopProviderTests; live ni omogočen |
| `PIM.B2bWorker` | B2B fixture podatki | `pim` B2B modeli / CSV podatki | F7 integration |
| `PIM.OutboxDispatcher` | `out.OutboxMessage` | HTTP samo do eksplicitnega profila | F8 local HTTP fixture |
| `PIM.Watchdog` | `ops` zdravstveno stanje | alarmi v `ops.Alert` | F9 tests |
| `PIM.AlertDispatcher` | alert queue | dostava alarma | F9 local fixture; dostava privzeto izklopljena |
| `PIM.FoundationWorker` | skupne osnove | operativne pomožne poti | build/pogodbeni testi |

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

Vsak pomemben tek se dokazuje v `ops.PipelineRun`, zaključek pa se vidi prek heartbeat/health in watchdoga. Alarm delivery ostane izklopljen, dokler lokalni fixture ne dokaže cilja in deduplikacije. Ob napaki preveri `ops.ErrorLog`, `ops.Alert`, `ops.DeadLetterQueue` in specifično karanteno; ne briši sledi, dokler incident ni raziskan.
