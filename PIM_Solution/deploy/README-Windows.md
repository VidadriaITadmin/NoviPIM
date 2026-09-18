# Operativna namestitev PIM v Windows/IIS

## Prenos in predpogoji

Prenesite celoten repozitorij ali podpisan release na strežnik, preverite hash artefakta in najprej izvedite vse skripte z `-DryRun` ter `-WhatIf`. Potrebni so 64-bitni Windows, IIS z ASP.NET Core modulom, PowerShell 7, dostop do `dotnet` CLI za publish in omrežni dostop samo do baze PIM ter odobrenih ciljnih sistemov. Produkcijskega deploya ne izvajajte iz razvojnega imenika.

## Skrivnosti in lokalna konfiguracija

Skrivnosti nikoli ne sodijo v Git, argumente ukazne vrstice ali zapisnike. Na cilju ročno ustvarite `appsettings.Local.json` iz primera in omejite ACL na administratorsko ter namensko storitveno identiteto. Povezavo lahko podate tudi kot zaščiteno sistemsko spremenljivko `PIM_CONNECTION_STRING`. `PIM_ALERT_DELIVERY_ENABLED` je privzeto `false`; webhook URL omogočite šele po lokalnem fixture preizkusu. Deploy ohrani obstoječi `appsettings.Local.json`.

## SQL provisioning

Ustvarite izključno bazo `PIM`, loginom dodelite najmanjše pravice in migracije izvedite s sledeno aplikacijo `PIM.Migrator` (na primer `dotnet run --project .\src\PIM.Migrator --` ter nato isti ukaz z `--verify`; povezavo poda zaščitena spremenljivka `PIM_CONNECTION_STRING` ali lokalna konfiguracija). Najprej naredite backup, nato migrator zaženite dvakrat idempotentno in enkrat z `--verify`. Worker račun potrebuje izvajanje postopkov `ops.*` ter potrebne pipeline postopke, intranet račun pa `intranet.*`; ne dodeljujte `db_owner`. Nikoli ne ciljajte `PIM_test`.

## Workerji, opravila in računi

Od 2026-09-17 cikle (zaloga, katalog, nadzor, nočni tok, samotest) poganja razporejevalnik v samem intranetu (`WorkerSchedulerService`, migracija 221; glej `docs/WORKERS.md`, razdelek »Razporejevalnik v aplikaciji«). Scheduled Tasks za cikle niso več potrebni; objava intraneta mora prinesti mapo `Workerji\` (`dotnet publish PIM.Intranet`, `deploy\Publish-All.ps1`), bazen pa naj bo »Always running« s predhodnim nalaganjem (`deploy\Configure-IisAlwaysRunning.ps1`, kot administrator), sicer po recikliranju ura stoji do prve zahteve. Stanje in zaostanek vsakega cikla sta na `/sistem/workerji`.

Za vsak worker uporabite namenski service account brez interaktivne prijave. `Install-Workers.ps1` objavi self-contained `win-x64`; `Configure-ScheduledTasks.ps1` namesti `PIM.Watchdog` in `PIM.AlertDispatcher`. Drugim pipeline workerjem nastavite interval skladno z `ops.ScheduleProfile`. Račun potrebuje samo Read/Execute na svoji mapi, Modify na izrecnih landing mapah in SQL EXECUTE. Gesla vnesite interaktivno ali prek upravljanega trezorja. Preverite, da prekrivanje iste organizacije/pipeline zavrne drugi zagon.

## IIS namestitev

Ustvarite application pool brez nalaganja uporabniškega profila, nastavite identiteto in HTTPS binding. Najprej:

```powershell
./deploy/Publish-Intranet.ps1 -Destination C:\PIM\Intranet -SiteName PIM -DryRun -WhatIf
```

Nato odstranite `-DryRun`; skripta objavi `win-x64 --self-contained true`, preveri predpogoje, vstavi `app_offline.htm`, atomsko preimenuje trenutno namestitev v backup, obnovi lokalno konfiguracijo in zahteva HTTP 200 na `/health`. Skrivnosti se ne izpisujejo.

## Povrnitev

Ob neuspelem health preverjanju skripta samodejno izvede rollback na atomski backup. Za ročno povrnitev ustavite IIS mesto, trenutno mapo preimenujte v `.failed`, mapo `.backup` preimenujte nazaj, preverite lokalno konfiguracijo, odstranite `app_offline.htm`, zaženite mesto in preverite `/health`. SQL povrnitev izvajajte samo iz predhodno preverjenega backup-a; migracij ne brišite ročno.

## Kontrolni seznam z resničnimi podatki

- Potrdite pravilno organizacijo in samo bazo PIM; izvedite migracijo dvakrat in `--verify`.
- Z namenskim računom sprožite en fixture/replay worker in preverite heartbeat, uspeh ter watermark.
- Sprožite dva enaka zagona in potrdite, da `sp_getapplock` zavrne prekrivanje.
- V izolirani organizaciji ustvarite stale, Dead in Drift ter preverite en dedupliciran alarm in razrešitev po okrevanju.
- Webhook najprej usmerite samo v lokalni fixture; resni kanal omogočite z odobritvijo prejemnikov po vlogah. E-pošte med preizkusom ne pošiljajte.
- Kot ADMIN odprite `/system/integracije`, potrdite in razrešite opozorilo ter preverite audit uporabnika in UTC čas.
- Preverite IIS HTTPS, `/health`, Windows Event Log, Scheduled Tasks, najmanjše ACL/SQL pravice in dokumentiran postopek povrnitve.
- Živi SAOP write-back ostane ročen in zunaj F9.
