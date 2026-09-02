# Razporejevalnik obdelav — načrt za en dolgoživ proces namesto načrtovanih opravil

Datum: 2026-09-02. Avtor: Claude Code. Ozemlje: načrt (brez sprememb kode).

Vir vseh trditev je koda in stanje tega računalnika, ne domneve: `scripts/*.ps1`,
`workers/*/Program.cs`, `src/PIM.Operations/OperationsRun.cs`,
`src/PIM.Intranet/Components/Pages/SystemSchedules.razor`, `sql/migrations/025`, `112`, `116`,
`deploy/Install-Workers.ps1`, `deploy/Configure-ScheduledTasks.ps1` ter izpisi
`schtasks /query /xml` in `Get-CimInstance Win32_Process`, posneti 2026-09-02.

Povezano: [`PRENOS_NA_SLUZBENI_RACUNALNIK.md`](PRENOS_NA_SLUZBENI_RACUNALNIK.md) (namestitev),
[`VALIDACIJA.md`](VALIDACIJA.md), `TASKBOARD.md` (vnos o oknu in obtičali instanci, 2026-09-02).

---

## 1. Zakaj sploh

Naročilo je bilo: *»Lahko midva te workerje imava bolj pod nadzorom in večjo kontrolo nad
njimi?«* Ob tem se je pokazalo, da ciljno okolje ni ta prenosnik, ampak strežnik z IIS, ki je
prižgan ne glede na to, ali je kdo prijavljen.

Štiri stvari, ki jih današnja postavitev ne zna. Vsaka je izmerjena, ne domnevana.

| # | Kaj | Dokaz |
|---|---|---|
| 1 | **Na strežniku se ne bi zagnalo nič.** Vsa tri opravila so `InteractiveToken`, kar je v Task Schedulerju »Run **only** when user is logged on«. Brez prijavljene seje se ne sprožijo in tega ne javijo. | `schtasks /query /tn "PIM zaloga" /xml` → `<LogonType>InteractiveToken</LogonType>` |
| 2 | **Ni vidno, ali sploh teče.** `PIM nadzor` je od 1. 9. 2026 20:31 visel 22 ur s 1,5 s procesorja; vsak petminutni tik se je vrnil z `0x800710E0` (`IgnoreNew`), dnevnika za 2. 9. ni bilo. Watchdog — edini, ki naj bi povedal, da se je nekaj ustavilo — je bil dan mrtev. | `Get-CimInstance Win32_Process`, PID 19708, `CreationDate 1. 09. 2026 20:31:46` |
| 3 | **Cena zagona je nesorazmerna.** En cikel zaloge požene do enajst procesov `dotnet run`; v treh minutah vzorčenja je bilo živih 23 procesov `dotnet`. Vsak s sabo potegne MSBuild, da nato požene program, ki dela dve sekundi. | `Zaloga-cikel.ps1:88`, vzorčenje procesov 19:02–19:05 |
| 4 | **Gumba ni.** `/sistem/urniki` zna postopek vklopiti in mu nastaviti razmik, ne zna pa povedati, ali razporejevalnik živi, ne zna pognati zdaj in ne zna ustaviti tekočega. | `SystemSchedules.razor` |

### 1.1 Namestitvena pot na strežnik danes ni skladna sama s sabo

Dve skripti postavljata **ista dva workerja na dva različna načina**:

- `deploy/Install-Workers.ps1` ju objavi in nato pokliče `New-Service`;
- `deploy/Configure-ScheduledTasks.ps1` ju registrira kot načrtovani opravili `PIM-<worker>`
  z `-LogonType Password`.

Prva pot **ne more delovati**: `workers/PIM.Watchdog/Program.cs` je navaden konzolni program s
`top-level statements`, ki naredi svoje in vrne 0. Windows storitev, ki ni `ServiceBase`, ob
zagonu odpove z napako 1053 (»služba se ni odzvala na zahtevo za zagon«). Nobena od skript
tudi ne postavi zaloge in nočnega toka — samo watchdog in razpošiljanje alarmov.

Načrt to razreši tako, da je **en sam** proces, ki je storitev po zasnovi, in en sam način
namestitve.

---

## 2. Kaj nastane

`PIM_Solution/workers/PIM.Scheduler` — en dolgoživ proces, `net10.0`, `Microsoft.Extensions.Hosting`.

```
PIM.Scheduler.exe                 storitev na strežniku (AddWindowsService)
PIM.Scheduler.exe --konzola       isti program v ospredju, za razvoj in preizkus
```

Isti izvršljivi program v obeh vlogah; razlika je samo v gostitelju. Tako se ne zgodi, da bi
na strežniku tekla druga koda kot tista, ki si jo preizkusil.

### 2.1 Kaj dela ob vsakem tiku

Tik je privzeto vsakih 30 sekund. Tik sam po sebi ne pomeni dela — pomeni pogled v urnik.

1. Prebere `ops.ScheduleProfile` (`IsEnabled`, `IntervalSeconds`, `NextScheduledUtc`). **Vir
   resnice o ritmu ostane baza in ne koda** — tako je že danes in stran `/sistem/urniki` to že
   ureja; načrtovano opravilo je bilo od nekdaj samo ura, ki tiktaka.
2. Za vsak postopek, ki je na vrsti, požene pripadajoči worker **kot zgrajen `.exe`**, ne prek
   `dotnet run`: `ProcessStartInfo` s `CreateNoWindow = true` in preusmerjenima `stdout`/`stderr`.
   MSBuild s tem izpade iz vroče poti.
3. Izpis workerja gre v isti dnevnik kot danes (`logs/zaloga-*.log`, `logs/nadzor-*.log`),
   dekodiran kot UTF-8 — navada se ne spremeni, samo pisec je drug.
4. Zapiše utrip v `ops.IntegrationHealth` (`LastHeartbeatUtc`, `Status`); tabela obstaja od
   migracije 025 in je stran `/sistem/urniki` že bere.

### 2.2 Kaj mora znati, česar danes nihče ne zna

| Lastnost | Zakaj je v načrtu |
|---|---|
| **Meja na zagon workerja** (privzeto 10 min, nastavljivo na postopek) | Prekoračitev pomeni, da se proces ubije in zapiše kot napaka. Primer iz točke 1.2 se s tem ne more ponoviti — ne po sreči, ampak po zasnovi. |
| **Ključavnica na (podjetje, postopek)** | Isti postopek ne teče dvakrat vzporedno. Danes to opravi `IgnoreNew` na ravni celega cikla, kar je pregrobo: obtičal SAOP ustavi tudi Braytron. |
| **Zgornja meja hkratnih workerjev** (privzeto 4) | Da nočni poln zajem ne poje strežnika, ki hkrati streže IIS. |
| **Utrip razporejevalnika** | Da »ne teče« postane vidno stanje in ne tišina. |
| **Čisto ustavljanje** | `IHostApplicationLifetime`: ob ustavitvi storitve počaka tekoče workerje do meje, potem jih ubije. Storitev, ki se ne da ustaviti, je nova različica istega problema. |
| **Pavza** | Globalna varovalka: razporejevalnik teče, a ne poganja ničesar. Za posege v bazo brez odstranjevanja storitve. |

---

## 3. Sled izvajanja: ena vrstica na zagon

Vprašanje je bilo, ali razporejevalnik ob vsakem zagonu workerja zapiše vrstico v bazo —
začetek, konec, status, prebrano, zapisano, napaka — in ali `OperationsRun` to že zna.

**Ne zna.** Tabela s točno temi stolpci obstaja, a `OperationsRun` je ne uporablja.

### 3.1 Kaj je danes

| Kaj | Kje | Kdo piše | Kaj manjka |
|---|---|---|---|
| **Stanje** postopka | `ops.IntegrationHealth` | `ops.BeginRun` / `ops.CompleteRun`, torej **vsi** workerji | **ena sama vrstica na (podjetje, postopek)**, ki se ob vsakem zagonu prepiše. Ni zgodovine, ni števcev, prejšnja napaka se ob uspehu izbriše. |
| **Zgodovina** teka | `ops.PipelineRun` — ima `StartedUtc`, `EndedUtc`, `Status`, `RowsRead`, `RowsSucceeded`, `RowsFailed` | samo `PIM.KatalogWorker` in `PIM.XmlFileWorker`, vsak s svojim `INSERT` | ostalih pet postopkov je tam **ni** |
| **Zgodovina** zaloge | `stock.SyncRun` — `RecordsRead`, `RecordsApplied`, `RecordsQuarantined` | zalogovna workerja | vzporedna, drugačna oblika; `/zajem` je ne bere |
| **Napake** teka | `ops.ErrorLog`, procedura `ops.LogError` obstaja od migracije 003 | **nihče** | intranet jo bere na petih mestih, a je vedno prazna |

Merjeno v bazi `PIM` 2026-09-02:

```
ops.PipelineRun po postopkih:   SAOP_PRODUCTS 57, GENERIC_XML 74, testni 7
                                SOURCE_FETCH, STOCK_FILE, SAOP_STOCK, WATCHDOG,
                                ALERT_DISPATCH:  0 vrstic — a vsi so v IntegrationHealth
ops.ErrorLog:                   0 vrstic
ops.Heartbeat:                  0 vrstic (mrtva tabela, nasledila jo je IntegrationHealth)
ops.PipelineRun brez EndedUtc:  19  (od tega 5 še vedno v stanju 'Running')
stock.SyncRun:                  512 vrstic
```

Dvoje od tega je treba brati počasi.

**Prvič: `ops.ErrorLog` je prazna, intranet pa jo bere.** `PipelineReadService.cs` na štirih
mestih šteje napake na tek in na petem izpiše seznam napak teka. Ker vanjo nihče ne piše, je
stolpec »napake« v vmesniku strukturno vedno nič — ne zato, ker napak ne bi bilo, ampak ker jih
nihče ne zapiše. To ni okvara razporejevalnika, je pa razlog, zakaj tega vprašanja ni odkril
prej nihče.

**Drugič: tudi tam, kjer se zgodovina piše, RunId ni isti.** `PIM.KatalogWorker/Program.cs:57`
naredi `var runId = Guid.NewGuid()` za `ops.PipelineRun`, vrstico kasneje pa `OperationsRun.BeginAsync`
ustvari **svoj** `RunId` za `ops.IntegrationHealth`. Dve identiteti istega teka, ki se ne dasta
sestaviti nazaj. Enako v `PIM.XmlFileWorker`.

In 19 vrstic brez `EndedUtc` pove, da tudi obstoječi `UPDATE` na koncu ni zanesljiv: če worker
pade vmes, vrstica ostane večno »Running«, ker jo zapre samo srečen konec.

### 3.2 Kaj naredimo

**Vrstico piše `ops.BeginRun` / `ops.CompleteRun`, ne razporejevalnik.** To je ključna odločitev
in je vredna razlage: če bi jo pisal razporejevalnik, bi ročni zagon `Zaloga-cikel.ps1` ali
nočnega toka ne pustil nobene sledi. Točno ta razcep je zalogo do migracije 106 držal nevidno v
`/zajem`. Ker `BeginRun` že danes dobi podjetje, postopek in `WorkerId` ter vrne `RunId`, je
zapis zgodovine njegov naravni posel — in **vseh sedem postopkov ga dobi hkrati, brez posega v
posameznega workerja**.

Razporejevalnik doda tisto, kar ve samo on: izhodno kodo procesa, dejstvo, da ga je ubila meja,
in to, da je zagon sprožil on in ne človek.

**Migracija 142** torej ni samo utrip in pavza, ampak:

| # | Sprememba | Zakaj |
|---|---|---|
| 1 | `ops.BeginRun` poleg `IntegrationHealth` vstavi še vrstico v `ops.PipelineRun` z istim `RunId` | ena identiteta teka namesto dveh |
| 2 | `ops.CompleteRun` isto vrstico zapre: `EndedUtc`, `Status` = `Succeeded`/`Failed` | konec je zapisan tudi takrat, ko tek pade |
| 3 | `ops.CompleteRun` ob napaki pokliče `ops.LogError` z istim `RunId` | `ops.ErrorLog` se končno polni; stolpci v intranetu nehajo lagati |
| 4 | novi stolpci na `ops.PipelineRun`: `WorkerId nvarchar(200)`, `ExitCode int`, `TriggeredBy nvarchar(30)` (`Scheduler` / `Human` / `Task`) | brez tega ni razvidno, kdo je zagnal in s čim je končal |
| 5 | `CK_PipelineRun_Status` dobi `N'TimedOut'` | ubit po meji ni isto kot padel |
| 6 | nova procedura `ops.RecordRunCounts @RunId, @RowsRead, @RowsSucceeded, @RowsFailed`; ovoj `OperationsRun.ReportCountsAsync` | števci so danes stvar vsakega workerja posebej |
| 7 | `PIM.KatalogWorker` in `PIM.XmlFileWorker` opustita svoj `INSERT` in preideta na `operationsRun.RunId`; `FinishRunAsync` **ostane** (glej §3.4 C) | sicer nastaneta dve vrstici na tek |
| 8 | osirotele vrstice se zaprejo v `Abandoned`: ob **zagonu razporejevalnika** vse tuje `Running`, med tekom pa nadzornik po `StaleAfterSeconds` | tistih 19 odprtih vrstic je dokaz, da se to zgodi |
| 9 | `ops.Heartbeat` se spusti; odstrani se tudi iz `expectedObjects` v `PIM.Migrator` | prazna tabela je past (§3.5) |

Točka 7 je edina, ki se dotakne obstoječih workerjev. Varna je, ker ima `raw.Inbox.RunId` tuji
ključ na `ops.PipelineRun` (migracija 007) in `BeginRun` vrstico ustvari **prej** kot worker piše
v `raw.Inbox` — vrstni red torej drži tudi po zamenjavi.

**Česa migracija 142 ne naredi:** `stock.SyncRun` pusti pri miru. Tam je zapis bogatejši
(`Endpoint`, `HttpStatus`, `QueryParametersHash`) in ima 512 vrstic zgodovine, ki je ne bomo
prelivali. Ko bo `/zajem` pokazal tudi zalogo, se poveže prek novega stolpca `RunId` na
`stock.SyncRun` — to je ločena naloga, ne pogoj za razporejevalnik.

### 3.3 Kaj bo torej v bazi po enem zagonu workerja

```
ops.PipelineRun     RunId, Pipeline, OrganizationId, SourceCode,
                    StartedUtc, EndedUtc, Status, RowsRead, RowsSucceeded, RowsFailed,
                    WorkerId, ExitCode, TriggeredBy          <- ena vrstica na zagon
ops.ErrorLog        RunId, OccurredUtc, Severity, ErrorCode, Message, Detail
                                                             <- ena ali več, samo ob napaki
ops.IntegrationHealth                                        <- stanje, prepisano (kot doslej)
```

Testi 8–12 v §7 to držijo.

### 3.4 Kaj so pokazala preverjanja pred izvedbo

Tri stvari je bilo treba preveriti, preden se migracije dotaknem. Dve sta se izšli drugače, kot
je bilo pričakovati.

**A. Slepa pega pri zalogi ne nastane — ker alarm sploh ne bere `ops.PipelineRun`.**

`ops.RunWatchdog` (migracija 025, vrstice 190–223) dela **izključno** nad `ops.IntegrationHealth`
in `ops.ScheduleProfile`. Zastarel utrip, mirujoč vodni žig, odhodna sporočila — vse troje bere
stanje, ne zgodovine. In v `ops.IntegrationHealth` zaloga **je**: `SAOP_STOCK` za štiri podjetja
in `STOCK_FILE` za štiri podjetja, izmerjeno 2026-09-02.

Zato dodajanje vrstic v `ops.PipelineRun` alarma ne premakne in najpogostejšega postopka ne
skrije. Nevarnost je obrnjena od pričakovane: nastala bi šele, če bi kdo alarm **preselil** na
`ops.PipelineRun`, ker se zdi bogatejši. Zato pravilo, zapisano tu in ne prepuščeno spominu:

> **`ops.IntegrationHealth` je stanje in edini vir alarma. `ops.PipelineRun` je zgodovina in
> forenzika. Alarm se nanjo ne seli.** Vsak nov pogled »zadnji teki« mora zalogo pobrati iz
> `stock.SyncRun` z unijo, ne samo iz `ops.PipelineRun`.

Unija ni nova iznajdba: `PipelineReadService.cs` jo ima že danes na šestih mestih (vrstice 134,
141, 172, 292, 352, 812 — zadnja doda celo `N'STOCK_SYNC'` kot samostojen postopek). Nov pogled
v `/sistem/urniki` uporabi isti vzorec.

**B. Osirotele vrstice se zaprejo ob zagonu razporejevalnika, ne po urniku.**

Pometanje samo po času pomeni, da sesut tek visi kot `Running` do naslednjega pometanja. Zato
dvoje:

1. **ob zagonu razporejevalnika** — vsaka vrstica v stanju `Running`, ki je ni zapisal ta proces,
   dobi status takoj; razporejevalnik ve, da je nov, in da nihče od prejšnjih ne teče več;
2. **med tekom** — nadzornik zapre vrstice brez utripa dlje od `StaleAfterSeconds`, za primer,
   ko pade worker in ne razporejevalnik.

Status je `Abandoned`, izrecno in ločeno od `Failed` in od `Cancelled`. Tri stanja, tri različne
zgodbe: *padlo je* (`Failed`), *nekdo ga je ustavil* (`Cancelled`), *nikoli se ni zaprlo*
(`Abandoned`). Zlivanje teh treh je natanko tisto, zaradi česar tišina izgleda kot zdravje.

**Glede zaprtega seznama:** `Status` že **je** zaprt seznam — `CK_PipelineRun_Status` iz
migracije 002 dovoli `Pending`, `Running`, `Succeeded`, `Failed`, `Cancelled`. Zato ga ne
preimenujem v `Success`/`Error`, ampak razširim. Razlog je merljiv: v bazi je 138 vrstic z
obstoječimi vrednostmi, `PipelineReadService.cs` pa se na imena naslanja na enajstih mestih —
med drugim `CASE lastPipeline.Status WHEN N'Succeeded' THEN N'Healthy'` (vrstica 85) in filtra v
vrsticah 120 in 128. Preimenovanje bi bila migracija podatkov in sprememba vmesnika zaradi
besede. Seznam po migraciji 142:

```
Pending | Running | Succeeded | Warning | Failed | TimedOut | Cancelled | Abandoned
```

`Warning` je nov in pokriva delni uspeh (del vrstic v karanteni) — danes se tak tek zapiše kot
`Succeeded` in se ne loči od čistega.

**C. Poti brez `BeginRun` obstajajo — tri. Ena od njih se `ops.PipelineRun` dotika.**

To je bilo edino mesto s tveganjem in tveganje je resnično:

| Pot | Kliče `BeginRun`? | Se dotika `ops.PipelineRun`? | Posledica |
|---|---|---|---|
| `PIM.XmlFileWorker --map-run <RunId>` (`Program.cs:42–65`) | **ne** | **da** — `FinishRunAsync(mapConnection, existingRunId)` | če bi `FinishRunAsync` odstranil, bi ponovno preslikan zagon ostal odprt |
| `PIM.KatalogWorker --map-run <RunId>` (`Program.cs:184–213`) | ne | ne | preslikava ne pusti nobene sledi |
| `PIM.KatalogWorker --preslikaj-zaostanek` (`Program.cs:116–149`) | ne | ne | isto; in prav ta gre čez **vse** zaostale zagone naenkrat |

Zato se točka 7 iz §3.2 popravi: **odstrani se `InsertRunAsync` / `InsertPipelineRunAsync`,
`FinishRunAsync` pa ostane.** Vstavljanje prevzame `ops.BeginRun`; zapiranje ostane tam, kjer je,
ker ima svojo pot brez zagona.

Drugi dve poti nista pokvarjeni in jih ta migracija ne popravlja, sta pa zapisani: preslikava
zaostanka je danes nevidna. Ko bo `TriggeredBy` na mestu, je pravi popravek zanju vrstica s
`Pipeline = 'REMAP'` in `TriggeredBy = 'Human'` — ločena naloga, ne pogoj za razporejevalnik.

### 3.5 Mrtve tabele gredo v isti migraciji

`ops.Heartbeat` ima 0 vrstic in nobenega pisca; nasledila jo je `ops.IntegrationHealth`. Prazna
tabela je past — naslednji, ki jo najde, bo domneval, da nekaj pomeni. Zato jo migracija 142
spusti, skupaj z dvema mestoma, ki jo držita pri življenju:

- `src/PIM.Migrator/Program.cs:304` jo našteva med obveznimi objekti v `--verify` in bi po
  spustu padel;
- `tests/PIM.F0.Tests/Program.cs:30` preverja **besedilo migracije 002**, ne baze, zato ostane
  zelen — 002 se ne spreminja.

`ops.PipelineStepLog` in `ops.RecordPipelineStep` ostaneta: prva ima svoj tuji ključ na
`ops.PipelineRun` in svoj namen (koraki znotraj teka), četudi je danes prazna. Če se izkaže, da
je tudi ta mrtva, gre ven ločeno in zavestno, ne mimogrede.

## 4. Kaj se spremeni v intranetu

`/sistem/urniki` (`SystemSchedules.razor`, vloga ADMIN) dobi:

- **vrstico stanja razporejevalnika** — teče / zadnji utrip pred N sekundami / ne teče;
- gumb **Zaženi zdaj** na vrstici postopka — postavi `NextScheduledUtc = SYSUTCDATETIME()`;
- gumb **Pavza / Nadaljuj** za celoto.

Obstoječa gumba »Izklopi« in »Shrani razmik« ostaneta nespremenjena; razporejevalnik ju bo
upošteval takoj ob naslednjem tiku, torej najkasneje v 30 sekundah namesto v petih minutah.

**Migracija 142** poleg utripa razporejevalnika in globalnega stikala pavze nosi še sled
izvajanja iz §3.2. Idempotentna, po pravilu iz `AGENTS.md`.

---

## 5. Kaj se odstrani in kaj ostane

| Danes | Po tem načrtu |
|---|---|
| opravilo `PIM zaloga` (5 min) | odpade — postopek je vrstica v urniku |
| opravilo `PIM nadzor` (5 min) | odpade — enako |
| opravilo `PIM nocni tok` (02:30) | **odločitev, glej §8** |
| `scripts/Zaloga-cikel.ps1`, `Nadzor.ps1` | **ostaneta** za ročni zagon; sta tudi zapis ritma in edini način, da človek stvar požene takoj |
| `scripts/Tiho.vbs`, `Izvajalec.ps1` | ostaneta; na strežniku nista potrebna (seja 0 okna nima), na prenosniku sta |
| `deploy/Configure-ScheduledTasks.ps1` | odpade |
| `deploy/Install-Workers.ps1` | nadomesti ga `Install-Scheduler.ps1` |

---

## 6. Namestitev na strežnik

`deploy/Install-Scheduler.ps1` po vzoru obstoječe skripte, s `-WhatIf` in `-DryRun`:

1. `dotnet publish -c Release -r win-x64 --self-contained` v `InstallRoot\PIM.Scheduler`;
2. `icacls` — namenski, najmanj privilegiran servisni račun, `ReadAndExecute`;
3. `New-Service -StartupType Automatic -Credential <servisni račun>`;
4. `sc.exe failure PIM.Scheduler reset= 86400 actions= restart/5000/restart/10000/restart/30000`
   — samodejni ponovni zagon ob padcu;
5. povezovalni niz iz strojnega okolja (`PIM_CONNECTION_STRING`), ne iz datoteke v mapi objave.

**IIS ob tem:** intranet je ločena stvar in ga ta načrt ne premakne. Če naj bo »skoz prižgan«,
potrebuje aplikacijski bazen `startMode="AlwaysRunning"` in `idleTimeout="00:00:00"`, sicer ga
IIS po 20 minutah brez zahtevka ugasne. To je nastavitev strežnika (`AGENTS.md` §4.7) in gre na
seznam tvojih nalog, ne mojih.

---

## 7. Testi — najprej rdeči

Nov konzolni testni projekt `PIM.F11.SchedulerTests` (kot ostali; `dotnet test` ga ne bi pognal,
zato gre v `scripts/run_tests.ps1`). Namesto pravih workerjev kliče kratek lažni program, da
noben test ne kliče ERP ali dobavitelja.

| # | Test | Kaj drži |
|---|---|---|
| 1 | postopek ni na vrsti → ni zagona | ritem se bere iz baze, ne iz tika |
| 2 | `IsEnabled = 0` → ni zagona | izklop v intranetu res ustavi |
| 3 | worker preseže mejo → ubit, zapisan kot napaka | 22-urni visečnik ni več mogoč |
| 4 | dva tika med tekočim workerjem → en sam zagon | ključavnica drži |
| 5 | vsak tik zapiše utrip | »ne teče« je vidno |
| 6 | ustavitev med tekočim workerjem → čist izhod pred mejo | storitev se da ustaviti |
| 7 | pavza → tiki tečejo, zagonov ni | varovalka drži |
| 8 | vsak zagon workerja pusti **eno** vrstico v `ops.PipelineRun` z `StartedUtc`, `EndedUtc`, `Status`, `ExitCode` | odgovor na vprašanje iz §3 |
| 9 | padel worker → vrstica zaprta s `Failed` **in** zapis v `ops.ErrorLog` z istim `RunId` | napaka ima ime in mesto |
| 10 | ubit po meji → `Status = 'TimedOut'`, ne `Failed` | ubit ni isto kot padel |
| 11 | worker ubit brez zaključka → nadzornik vrstico zapre s `Cancelled` | osirotelih vrstic ne pušča več |
| 12 | ročni zagon iz ukazne vrstice pusti vrstico s `TriggeredBy = 'Human'` | sled ni odvisna od tega, kdo je zagnal |
| 13 | ob zagonu razporejevalnika tuje vrstice `Running` → `Abandoned`, ne `Failed` | »nikoli se ni zaprlo« ni »padlo« |
| 14 | `--map-run` v `PIM.XmlFileWorker` še vedno zapre svoj tek | §3.4 C: `FinishRunAsync` ostane |
| 15 | pogled zadnjih tekov pokaže tudi `STOCK_FILE` in `SAOP_STOCK` | unija s `stock.SyncRun` drži |

---

## 8. Kaj potrebujem od tebe

1. **Nočni tok:** naj postane navadna vrstica v urniku (dnevni ritem, isti razporejevalnik), ali
   naj ostane ločeno načrtovano opravilo ob 02:30? Priporočam prvo — ena pot, en dnevnik, en
   nadzor. Proti govori le to, da je poln zajem dolg in ga je lažje ločeno ubiti.
2. **Servisni račun na strežniku** — ime in geslo, ko bo namestitev na vrsti. Zunanji svet in
   sistemske nastavitve sta na zaprtem seznamu (`AGENTS.md` §4.5, §4.7), zato tega ne postavim sam.
3. **Potrditev vrstnega reda** iz §9.

---

## 9. Vrstni red dela

| # | Korak | Ozemlje | Dokaz ob koncu |
|---|---|---|---|
| 1 | migracija 142 (utrip, pavza, sled izvajanja iz §3.2) | BAZA | migrator 1. in 2. zagon + `--verify`; pred in po: `SELECT COUNT(*) FROM ops.PipelineRun` po enem zagonu watchdoga |
| 2 | `PIM.Scheduler` + `PIM.F11.SchedulerTests` | WORKERJI | `scripts\run_tests.ps1` zelen |
| 3 | `/sistem/urniki`: stanje, »Zaženi zdaj«, pavza | INTRANET | `PIM.F10.*UxTests` + build |
| 4 | `Install-Scheduler.ps1` + dokumentacija | WORKERJI | `-WhatIf` izpis |
| 5 | na tem prenosniku: storitev gor, stari opravili dol | — | `Get-Service`, `schtasks /query` |

Ocena: dva dneva dela. Koraka 1 in 2 sta odvisna zaporedno, 3 lahko počaka.

---

## 10. Kar ta načrt namenoma ne rešuje

- **Vsebine workerjev.** Kdo kaj bere in kam piše, ostane natanko tako, kot je.
- **Ritma.** Pet minut ostane pet minut; sprememba je, da ga po novem res drži urnik iz baze.
- **`SAOP_STOCK` je izklopljen.** To je stanje vrstice v `ops.ScheduleProfile`, ne okvara, in ga
  vklopiš na `/sistem/urniki`, ko bo živi klic na ERP zaželen.
