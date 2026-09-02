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

## 3. Kaj se spremeni v intranetu

`/sistem/urniki` (`SystemSchedules.razor`, vloga ADMIN) dobi:

- **vrstico stanja razporejevalnika** — teče / zadnji utrip pred N sekundami / ne teče;
- gumb **Zaženi zdaj** na vrstici postopka — postavi `NextScheduledUtc = SYSUTCDATETIME()`;
- gumb **Pavza / Nadaljuj** za celoto.

Obstoječa gumba »Izklopi« in »Shrani razmik« ostaneta nespremenjena; razporejevalnik ju bo
upošteval takoj ob naslednjem tiku, torej najkasneje v 30 sekundah namesto v petih minutah.

**Migracija 142:** vrstica za utrip razporejevalnika in globalno stikalo pavze. Idempotentna,
po pravilu iz `AGENTS.md`.

---

## 4. Kaj se odstrani in kaj ostane

| Danes | Po tem načrtu |
|---|---|
| opravilo `PIM zaloga` (5 min) | odpade — postopek je vrstica v urniku |
| opravilo `PIM nadzor` (5 min) | odpade — enako |
| opravilo `PIM nocni tok` (02:30) | **odločitev, glej §7** |
| `scripts/Zaloga-cikel.ps1`, `Nadzor.ps1` | **ostaneta** za ročni zagon; sta tudi zapis ritma in edini način, da človek stvar požene takoj |
| `scripts/Tiho.vbs`, `Izvajalec.ps1` | ostaneta; na strežniku nista potrebna (seja 0 okna nima), na prenosniku sta |
| `deploy/Configure-ScheduledTasks.ps1` | odpade |
| `deploy/Install-Workers.ps1` | nadomesti ga `Install-Scheduler.ps1` |

---

## 5. Namestitev na strežnik

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

## 6. Testi — najprej rdeči

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

---

## 7. Kaj potrebujem od tebe

1. **Nočni tok:** naj postane navadna vrstica v urniku (dnevni ritem, isti razporejevalnik), ali
   naj ostane ločeno načrtovano opravilo ob 02:30? Priporočam prvo — ena pot, en dnevnik, en
   nadzor. Proti govori le to, da je poln zajem dolg in ga je lažje ločeno ubiti.
2. **Servisni račun na strežniku** — ime in geslo, ko bo namestitev na vrsti. Zunanji svet in
   sistemske nastavitve sta na zaprtem seznamu (`AGENTS.md` §4.5, §4.7), zato tega ne postavim sam.
3. **Potrditev vrstnega reda** iz §8.

---

## 8. Vrstni red dela

| # | Korak | Ozemlje | Dokaz ob koncu |
|---|---|---|---|
| 1 | migracija 142 (utrip + pavza) | BAZA | migrator 1. in 2. zagon + `--verify` |
| 2 | `PIM.Scheduler` + `PIM.F11.SchedulerTests` | WORKERJI | `scripts\run_tests.ps1` zelen |
| 3 | `/sistem/urniki`: stanje, »Zaženi zdaj«, pavza | INTRANET | `PIM.F10.*UxTests` + build |
| 4 | `Install-Scheduler.ps1` + dokumentacija | WORKERJI | `-WhatIf` izpis |
| 5 | na tem prenosniku: storitev gor, stari opravili dol | — | `Get-Service`, `schtasks /query` |

Ocena: dva dneva dela. Koraka 1 in 2 sta odvisna zaporedno, 3 lahko počaka.

---

## 9. Kar ta načrt namenoma ne rešuje

- **Vsebine workerjev.** Kdo kaj bere in kam piše, ostane natanko tako, kot je.
- **Ritma.** Pet minut ostane pet minut; sprememba je, da ga po novem res drži urnik iz baze.
- **`SAOP_STOCK` je izklopljen.** To je stanje vrstice v `ops.ScheduleProfile`, ne okvara, in ga
  vklopiš na `/sistem/urniki`, ko bo živi klic na ERP zaželen.
