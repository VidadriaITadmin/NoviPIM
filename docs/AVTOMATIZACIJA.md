# Avtomatizacija: en model izvajanja, en gostitelj, nadzor rezultata

Datum: 2026-09-21. Migracija: **237**. Stanje: izvedeno na razvojni bazi `DAVID\MSSQL19`; namestitev
storitve na strežnik je ročni korak (§6).

Uporabnik: »Realno: trenutna rešitev deluje, vendar arhitekturno še ni zaključena. Problem ni
število strani, ampak to, da so pomešani poslovni tokovi, urniki, worker procesi in nadzor. […]
Naredi mi to za vse workerje, da bom imel vse pod nadzorom.«

---

## 1. Kaj je bilo narobe

| # | Težava | Kje je bilo vidno |
|---|---|---|
| 1 | Cikel »katalog« je zaporedoma izvajal zajem artiklov, zajem naročil, validacijo in objavo štirih podjetij; naročila z objavo kataloga nimajo poslovne odvisnosti | `WorkerSchedulerPolicy.PlanKatalog` |
| 2 | `PIM.B2bWorker --osvezi-validacijo`: izvoz ni bil več samo izvoz | `WorkerCycles.Plan(Magento)` |
| 3 | Urniki na dveh ravneh: pet `ops.WorkerCycle` ciklov in 51 vrstic `ops.ScheduleProfile` | `/sistem/workerji`, `/sistem?pogled=postopki` |
| 4 | Cikel je po padcu ene skupine nadaljeval z naslednjimi: izvoz tudi po padlem vhodu | `WorkerCycleRunner.RunAsync` |
| 5 | Interni watchdog je poganjal isti razporejevalnik, ki ga je nadziral | `WorkerSchedulerService.TickAsync` |
| 6 | Ura je bila vezana na proces intraneta (IIS bazen) | `Program.cs`, `Configure-IisAlwaysRunning.ps1` |
| 7 | `WorkerCycleRunId` 188 in 192 sta bila 3,5 h `Running` brez utripa; najem je potekel ob 11:26 UTC | razvojna baza, 2026-09-21 |

---

## 2. Ciljna postavitev

```
IIS / PIM.Intranet                       nadzorna konzola
  /sistem            pregled: štiri poslovne kartice, kaj potrebuje pozornost
  /sistem/opravila   urniki, vklop, časovna meja, ročni zagon (zahteva), ustavitev (zahteva)
  /sistem/zagoni     zgodovina zagonov, koraki, napake, tehnični izpis
  /sistem/workerji   »Izvajalniki« — napredni tehnični pogled (procesi, izpis, dnevniki, stari cikli)

PIM.AutomationHost                       motor (Windows storitev; na razvoju konzola)
  najem ops.SchedulerLease s prednostjo 10 (intranet 0)
  vsakih 15 s: viseči zagoni → Abandoned, ocena alarmov, posli na vrsti → ops.ClaimJobRun → zagon
  worker = otroški proces (objavljen .exe ali dotnet run --no-build), validacija/objava = SQL
  utrip zagona vsakih 30 s, časovna meja na zagon, ustavitev na zahtevo

SQL Server
  ops.JobDefinition, ops.JobDependency     kaj, kdaj, s katero mejo, od česa odvisno
  ops.JobRun, ops.JobStepRun               en zagon, njegovi koraki
  ops.DataCheckpoint, ops.Artifact         do kod smo prišli, katera datoteka je nastala (hash, vrstice)
  ops.Alert                                JobOverdue, JobFailed, JobBlocked, AutomationHostDown
```

En gostitelj na bazo drži najem; drugi (npr. drug strežnik) samo čaka. Intranet dobi najem šele,
ko gostitelj neha utripati, in takrat poganja samo stare cikle kot rezervo prehodnega obdobja
(§7).

---

## 3. Posli

| Posel | Tok | Urnik | Meja | Kaj naredi | Odvisnost |
|---|---|---|---|---|---|
| `SAOP_PRODUCT_IMPORT` | Vhodni viri (rezultat) | 1 h | 60 min | `PIM.KatalogWorker` delta (poln 1. v mesecu) | — |
| `SAOP_ORDER_IMPORT` | Naročila (rezultat) | 1 h | 30 min | `PIM.SaopOrdersWorker` VNK/VND | — (nobena, nihče ni odvisen) |
| `STOCK_IMPORT` | Cene in zaloga | 5 min | 15 min | prevzem + branje NW/BT zaloge za vsa podjetja, `PIM.SaopStockWorker` količine | — |
| `PRICE_IMPORT` | Cene in zaloga | 5 min | 15 min | `PIM.KatalogWorker --endpoints GetPrices` | — |
| `SAOP_DELIVERY_IMPORT` | Cene in zaloga | 30 min | 30 min | `PIM.SaopStockWorker --dostave` | — |
| `PRODUCT_VALIDATION` | Spletni katalog | 1 h | 60 min | `val.RunValidation` na podjetje | sproži jo uspešen zajem artiklov (ne blokira) |
| `PRODUCT_PUBLICATION` | Spletni katalog | 1 h | 30 min | `val.Promote` na podjetje | **vrata**: validacija uspešna in mlajša od 2 h; sproži jo validacija |
| `WEB_CATALOG_EXPORT` | Spletni katalog (rezultat) | 5 min | 30 min | `PIM.B2bWorker --export-magento --organization-id 2` (brez validacije) | **vrata**: objava uspešna; sproži jo objava |
| `WEB_STOCK_EXPORT` | Cene in zaloga (rezultat) | 5 min | 15 min | `PIM.B2bWorker --export-profile MAGENTO_STOCK_PRICES` na podjetje | sprožita ga zajem zaloge in cen |
| `ALERT_EVALUATION` | Sistem | 5 min | 5 min | `PIM.Watchdog` | — |
| `ALERT_DELIVERY` | Sistem | 5 min | 5 min | `PIM.AlertDispatcher` | sproži ga nadzornik |
| `NIGHTLY_RECONCILIATION` | Vhodni viri | 02:30 | 6 h | vsi vhodi (kot `Nocno-vse.ps1 -ZalogaIzSaop`), nato validacija in objava vseh podjetij — **blokirani**, če je padel katerikoli vhod | — |
| `STOCK_REPLENISHMENT_DIGEST` | Naročila | 05:30 | 15 min | `PIM.StockReplenishmentWorker` | — |
| `SYSTEM_SELF_TEST` | Sistem | 04:30 | 30 min | `PIM.SelfTest.Nightly` | — |
| `SAOP_OUTBOUND_DISPATCH` | Sistem | 5 min, **izklopljen** | 15 min | `PIM.OutboxDispatcher` (pošiljanje v SAOP je ročna odločitev) | — |

Vsak worker iz `workers\` ima svoj posel (test `JobCatalogChecks`). Kar cikel potrebuje od sveta
(podjetja, mape, register), pride prek `CycleEnvironment` — isti gradniki ukaznih vrstic kot
pri starih ciklih (`WorkerCycles.Worker`, `StockFilesSteps`, `XmlSteps`), da se ne razidejo.

Poslovni tok kataloga: `SAOP artikli → validacija → objava → spletni izvoz`. Naročila: `SAOP
naročila → shranjevanje naročil`, popolnoma ločeno.

### Kaj je s ScheduleProfile

`ops.ScheduleProfile` ostane, a **ni več urnik**: je ključavnica in stanje na (podjetje,
postopek), ki ju workerji uporabljajo prek `ops.BeginRun`/`ops.CompleteRun` (izklopljen
postopek še vedno zavrne zagon z 51100, `MaxConsecutiveFailures` še vedno samodejno izklopi
padajoč postopek). Noben posel ne podaja `--po-urniku` (test); ritem je ena raven —
`ops.JobDefinition`. Stran `/sistem?pogled=postopki` ostane kot tehnični pogled (povezava z
Opravil), ne kot zavihek.

### Validacija samo spremenjenih artiklov

`val.RunValidationForProducts @ProductIdsJson` (218) obstaja, a `canon.Product` nima stolpca
spremembe (samo `LastValidatedUtc`), zato sistem ne more ugotoviti, kateri artikli so se od
zadnje validacije spremenili. `PRODUCT_VALIDATION` zato validira cel katalog podjetja (kot
doslej urno), migracija 236 pa tako ali tako zahteva validacijo, mlajšo od dveh ur. Naslednji
korak, ko bo potreben: stolpec `canon.Product.ChangedUtc`, ki ga polnijo `map.ProcessRawInbox`
in `pim.Save*`, in posel, ki kliče `val.RunValidationForProducts` za spremenjene.

---

## 4. Življenjski cikel zagona

```
Running ──► Succeeded | Warning | Failed | TimedOut | Cancelled | Abandoned
Blocked  (zapisan takoj ob prevzemu: predhodnik ni uspel ali je njegov uspeh prestar)
```

- **Prevzem** (`ops.ClaimJobRun`): edina vrata. Pod ključavnico vrstice preveri, da posel ne
  teče, da je na vrsti (ali zahtevan), da noben neposredni predhodnik ravno ne teče (sicer
  `WaitingOn`), in vrata odvisnosti. Gostitelj dodatno počaka, če teče **katerikoli** predhodnik
  po verigi (izvoz kataloga ne sme teči med validacijo istega podjetja).
- **Blokada**: zagon `Blocked` z razlogom (`Blokirano: Objava v PIM se je nazadnje končala s
  stanjem TimedOut …`) in `BlockedByJobKey`; ista ovira drugič ne podvaja vrstice, šteje
  `Occurrences`. Odvisen posel se **ne izvede vseeno**.
- **Utrip** vsakih 30 s (`ops.HeartbeatJobRun`), ki hkrati pove, ali je kdo zahteval ustavitev.
- **Časovna meja** na zagonu (`TimeoutSeconds`): ob preseženi meji gostitelj ubije drevo
  procesov, korak in zagon sta `TimedOut`.
- **Zapuščen**: `Running` brez utripa 10 min → `ops.AbandonStaleJobRuns` ob **vsakem tiku**
  (ne šele ob ponovnem zagonu gostitelja), bralni model pa ga kaže kot `Abandoned` že prej
  (`EffectiveStatus`).
- **Koraki** (`ops.JobStepRun`): padec koraka preskoči preostale v isti skupini; skupina z
  `RequiresAllPrevious` se po padli skupini ne izvede — koraki so `Blocked`, ne tiho
  preskočeni.
- **Uspeh** zapiše kontrolno točko (`ops.DataCheckpoint`), sproži odvisne (`NextDueUtc = zdaj`,
  `TriggerSource = Dependency:<posel>`), zapre alarme posla in pri izvozih zapiše artefakt
  (`ops.Artifact`: pot, velikost, vrstice, SHA-256) — »splet trenutno uporablja verzijo N«.

Dokaz: `tests\PIM.F11.AutomationTests` nad živo bazo (blokada, ponovitev, sprožilec, alarm,
zapuščen zagon, ustavitev, ročna zahteva, neveljaven urnik).

---

## 5. Nadzor

**Pregled** (`/sistem`): štiri kartice — Spletni katalog, Cene in zaloga, Naročila, Vhodni viri.
Merilo je rezultat toka (posel z `IsFlowResult`): starost zadnjega uspeha proti SLA, zadnje
stanje, blokada po verigi predhodnikov, živost gostitelja. Vsaka pove stanje (`DELUJE`,
`ZASTAREL`, `BLOKIRAN`, `NAPAKA`, `IZKLOPLJEN`, `GOSTITELJ NE TEČE`), zadnji uspeh, kaj teče,
naslednji termin, vzrok, posledico in en ukrep (`Ponovi Validacija artiklov`, ki je zahteva za
gostitelja). Logika je čista funkcija `AutomationOverview.Build` (test `JobCatalogChecks`).

**Opravila** (`/sistem/opravila`): posli po tokovih, urnik/meja/vklop, zadnji zagon, naslednji
termin, zahteve za zagon in ustavitev; stanje gostitelja (utrip, tikov, čakajoče zahteve).

**Zagoni** (`/sistem/zagoni`): zgodovina s filtri, koraki, blokator, tehnični izpis
(`<LOG_ROOT>\opravila\<POSEL>_<datum>_<ura>.log`).

**Alarmi** (`ops.EvaluateJobAlerts`, vsako minuto iz gostitelja): `JobOverdue` (posel ni tekel
2× razmika), `JobFailed` (kritičen za rezultat toka, sicer opozorilo), `JobBlocked`,
`AutomationHostDown`. Zaprejo se sami ob naslednjem uspehu. Dokler gostitelj utripa, se stari
`CycleOverdue` alarmi zaprejo.

**Zunanji nadzor** (obvezen): `PIM.AutomationHost.exe --preveri` iz načrtovane naloge Windows
»PIM nadzor avtomatike« (`scripts\Namesti-nadzor-avtomatike.ps1`, vsakih 5 min): ob molku
gostitelja > 10 min odpre `AutomationHostDown`, ga uvrsti v vrsto in požene
`PIM.AlertDispatcher`, da e-pošta odide tudi, ko gostitelj leži. Storitev ima poleg tega
samodejni ponovni zagon (`sc.exe failure`, 5/10/30 s).

---

## 6. Namestitev in zagon

Razvoj (konzola, iz izvorne kode; workerje zgradi sam ob zagonu):

```powershell
dotnet run --project PIM_Solution\workers\PIM.AutomationHost
dotnet run --project PIM_Solution\workers\PIM.AutomationHost -- --enkrat ALERT_EVALUATION   # en posel zdaj
dotnet run --project PIM_Solution\workers\PIM.AutomationHost -- --posli WEB_STOCK_EXPORT     # samo našteti
dotnet run --project PIM_Solution\workers\PIM.AutomationHost -- --samo-nadzor                # brez zagona poslov
dotnet run --project PIM_Solution\workers\PIM.AutomationHost -- --preveri                    # zunanji nadzor
```

Strežnik (objava intraneta v eno mapo odloži `Workerji\PIM.AutomationHost\PIM.AutomationHost.exe`
ob druge workerje; nastavitve bere iz `appsettings.Local.json` ob intranetu, isti vir kot workerji):

```powershell
# kot administrator; racun storitve s prijavo v SQL Server, brez LocalSystem
.\PIM_Solution\deploy\Install-AutomationHost.ps1 -BinaryPath C:\inetpub\wwwroot\PIM\Workerji\PIM.AutomationHost\PIM.AutomationHost.exe -ServiceAccount 'DOMENA\pim-avtomatika' -ZunanjiNadzor
```

Nastavitve (`appsettings.json` ob gostitelju ali `appsettings.Local.json`): `Automation:TickSeconds`
(15), `LeaseSeconds` (90), `MaxConcurrentJobs` (3), `StaleMinutes` (10), `RepositoryRoot`,
`PublishedWorkersRoot`, `LogRoot`; `Pim:TimeZone`. Dnevnik gostitelja:
`<LOG_ROOT>\gostitelj\gostitelj-<datum>.log`.

---

## 7. Vrstni red uvedbe in prehodno obdobje

1. ✅ Življenjski cikel: časovne meje, `Abandoned` ob vsakem tiku, blokiranje odvisnih korakov (237).
2. ✅ `PIM.AutomationHost`; scheduler ni več motor v IIS (najem s prednostjo).
3. ✅ Enotni `JobDefinition`/`JobRun` model; `--po-urniku` in `--osvezi-validacijo` nista več v avtomatiki.
4. ✅ Naročila, validacija, objava in izvoz so ločeni posli z vrati in sprožilci.
5. ✅ UI: Pregled s karticami, Opravila, Zagoni; Workerji → Izvajalniki.
6. ⏳ **Po dveh tednih** vzporednega spremljanja: izklopi stare cikle na `/sistem/workerji`,
   odstrani Windows naloge (`scripts\Namesti-opravila.ps1 -Odstrani`), nato v ločeni migraciji
   umakni `ops.WorkerCycle*`, `WorkerSchedulerService`/`WorkerCycleRunner` in PowerShell cikle.

Dokler gostitelj teče, stari cikli ne tečejo (intranet nima najema; skripte se umaknejo, ker je
najem živ — `Sql.ps1 PimRazporejevalnikVAplikaciji`). Če gostitelj pade in ga Windows ne obudi,
intranet po 90 s prevzame najem in poganja stare cikle kot rezervo — stran to izrecno pove.

---

## 8. Kaj ni pokrito

| Vrzel | Predlog |
|---|---|
| Inkrementalna validacija | `canon.Product.ChangedUtc` + posel nad `val.RunValidationForProducts` (§3) |
| Datoteka za Magento: dostava | `ops.Artifact` dokazuje nastanek in hash; prevzem s strani Magenta ni potrjen |
| `SAOP_OUTBOUND_DISPATCH` | izklopljen; vklop zahteva razpored `OUTBOUND` in odločitev o pošiljanju |
| `WEB_STOCK_EXPORT` z registrom `EXPORT_ROOT` | vsa štiri podjetja pišejo `magento-stock-prices.csv` v isto mapo (kot doslej); podjetju dodaj svojo vrstico `EXPORT_ROOT` na `/administracija/mape` |
