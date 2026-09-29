# Diagnoza strežnika — kdo kliče SAOP in kdo bremeni bazo

Mapa `scripts/Diagnoza-streznika/`. Vse datoteke **samo berejo**, ničesar ne spreminjajo.
Celo mapo lahko skopiraš na strežnik (npr. v `C:\Temp\Diagnoza-streznika`).

| Datoteka | Kaj pove | Kje teče |
|---|---|---|
| `SAOP-analiza-streznika.ps1` | kdo in kolikokrat kliče SAOP API, od kod pride Python skripta | na strežniku **IQ-SAOP**, PowerShell kot administrator |
| `PIM-poraba-workerjev.ps1` | koliko CPU, pomnilnika, SQL in klicev SAOP porabi **vsak najin worker** in zakaj | na strežniku s PIM workerji, PowerShell kot administrator |
| `Diagnoza-obremenitve-baze.sql` | kateri program in katera poizvedba bremeni SQL, kateri posli tečejo | v **SSMS** na PIM strežniku (`USE PIM_prd`) |
| `NAVODILA.md` | ta navodila | — |

---

## A. Kdo kliče SAOP API — `SAOP-analiza-streznika.ps1`

Združuje prejšnja skripta `scripts/SAOP-promet.ps1` in `scripts/SAOP-python-izvor.ps1`.

### Zagon

1. Na strežniku **IQ-SAOP**: Start → `PowerShell` → desni klik → **Run as administrator**.
2. Vpiši:

```
cd C:\Temp\Diagnoza-streznika
powershell -ExecutionPolicy Bypass -File .\SAOP-analiza-streznika.ps1
```

3. Počakaj (2. del preišče vse diske, lahko traja nekaj minut). Na koncu se poročila odprejo v Notepadu.

### Kaj dobiš (v `C:\Temp\SAOP-promet\`)

| Datoteka | Vsebina |
|---|---|
| `porocilo_*.txt` | **1. del – Promet:** kdo kliče (IP, ime računalnika, uporabnik, program), kolikokrat, kateri klici, statusi, napake, promet po urah, najpočasnejši klici |
| `zahteve_*.csv` | vsaka zahteva v svoji vrstici – odpri v Excelu (ločilo `;`) in filtriraj |
| `python_izvor_*.txt` | **2. del – Python:** nameščeni Pythoni, procesi, opravila v Task Schedulerju, storitve, datoteke skript z omembo SAOP API, kdo je kaj namestil |

### Pogosti primeri

Samo promet zadnjih 24 ur (najhitreje):
```
powershell -ExecutionPolicy Bypass -File .\SAOP-analiza-streznika.ps1 -Kaj Promet
```

Zadnji 2 uri + 5 minut opazovanja v živo (pove tudi, **kateri proces** kliče):
```
powershell -ExecutionPolicy Bypass -File .\SAOP-analiza-streznika.ps1 -Kaj Promet -Ure 2 -Zivo -Sekund 300
```

Cel teden, samo produkcijski API:
```
powershell -ExecutionPolicy Bypass -File .\SAOP-analiza-streznika.ps1 -Kaj Promet -Spletna SaopApi -Ure 168
```

Ujemi Python skripto pri delu (klici so bili ob :56 in :00 – zaženi okoli :54):
```
powershell -ExecutionPolicy Bypass -File .\SAOP-analiza-streznika.ps1 -Kaj Python -Ujemi 10
```

### Nastavitve

| Nastavitev | Privzeto | Pomen |
|---|---|---|
| `-Kaj` | `Vse` | `Promet`, `Python` ali `Vse` |
| `-Izhod` | `C:\Temp\SAOP-promet` | mapa za rezultate |
| `-NeOdpri` | — | ne odpiraj Notepada |
| `-Spletna` | `SaopApi, SaopApiTest` | IIS spletna mesta (port 81, 82) |
| `-Ure` | `24` | koliko ur nazaj |
| `-Zivo` / `-Sekund` / `-Interval` | — / `120` / `2` | opazovanje povezav v živo |
| `-Top` | `30` | vrstic na tabelo |
| `-PocasiMs` | `5000` | od koliko ms je klic »počasen« |
| `-BrezDns` / `-BrezCsv` | — | brez imen računalnikov / brez CSV (hitreje) |
| `-Ujemi` | `0` | minute čakanja na proces, ki kliče SAOP |
| `-Poti` | vsi diski | kje iskati skripte (npr. `D:\`) |
| `-DniDogodkov` | `365` | koliko dni nazaj v dnevnikih dogodkov |

### Kako brati

- **KDO KLICE – racunalniki:** prvi je največji klicatelj. `TA STREZNIK` = kliče nekaj na samem
  IQ-SAOP; zaženi z `-Zivo` ali `-Ujemi`, da vidiš proces.
- **Status:** `2xx` v redu, `401/403` prijava, `404` ne obstaja, `5xx` napaka v SAOP.
- **PROMET PO URAH:** dolg stolpec `#` vsak dan ob isti uri = opravilo po urniku.

### Če ne dela

- »ni zagnana kot administrator« → PowerShell z **Run as administrator**.
- »beleženje v IIS je IZKLOPLJENO« → IIS Manager → SaopApi → Logging → Enable.
- »V dnevnikih manjkajo polja« → IIS Manager → SaopApi → Logging → Select Fields → Client IP, User
  Name, User Agent, Time Taken, Bytes Sent, URI Query (velja za nove klice).

### Ali se tu vidijo tudi najini workerji?

Da. IIS zapiše **vsak** klic na SAOP API, tudi klice najinih workerjev (`PIM.KatalogWorker`,
`PIM.SaopStockWorker`, `PIM.SaopOrdersWorker`, `PIM.SaopAnalyticsWorker`, pošiljanje v SAOP iz
intraneta). Ker ne pošiljajo imena programa (User-Agent), so v poročilu vidni kot IP PIM strežnika
(`TA STREZNIK`, če teče PIM na IQ-SAOP) s programom `-`. **Kateri** worker je klical, pove skripta
`PIM-poraba-workerjev.ps1` (razdelek 1b): klice pripiše workerju, ki je takrat tekel po bazi.

---

## C. Poraba najinih workerjev — `PIM-poraba-workerjev.ps1`

Odgovori na: koliko procesorja in pomnilnika porabi vsak worker, koliko obremeni SQL, koliko klicev
SAOP naredi **in zakaj** (kateri posel, korak in SQL poizvedba je takrat tekla).

### Zagon

Na strežniku, kjer teče avtomatika, PowerShell **Run as administrator**:
```
cd C:\Temp\Diagnoza-streznika
powershell -ExecutionPolicy Bypass -File .\PIM-poraba-workerjev.ps1 -Minute 15
```
Najbolje: zaženi skripto, nato **zaženi servis PIM.AutomationHost** in pusti, da skripta opazuje
15 minut. Tako se vidi, kaj ob zagonu servisa pobere procesor.

Če baza ni na privzetem strežniku: `-Streznik 'localhost\SQL01' -Baza PIM_prd`.

### Kaj dobiš (v `C:\Temp\PIM-poraba\`)

| Razdelek | Pove |
|---|---|
| **1. Zgodovina** | po workerju za zadnjih `-Ure` ur: zagonov, minut dela, zasedenost %, najdlje, padlih, posli |
| **1b. Klici SAOP** | koliko klicev SAOP je bilo iz tega strežnika, kateremu workerju so pripisani, napake, najpogostejši klici |
| **2. Živo** | po procesu: povprečni in največji CPU %, CPU sekunde, MB, **SQL CPU s** (kar je proces povzročil v bazi), SAOP povezave |
| **Zakaj** | za vsak proces: kateri posel in korak je tekel in katere SQL poizvedbe je izvajal |
| `vzorci_*.csv` | vsak vzorec posebej (čas, proces, CPU, SQL, posli) za Excel in graf |

`CPU %` je delež **celega** strežnika. `SQL CPU s` je čas, ki ga je SQL Server porabil za poizvedbe
tega procesa; ta ni vštet v CPU % procesa, ampak v `sqlservr`.

### Nastavitve

| Nastavitev | Privzeto | Pomen |
|---|---|---|
| `-Minute` | `10` | koliko minut opazujem v živo (`0` = samo zgodovina) |
| `-Interval` | `5` | na koliko sekund vzorec |
| `-Ure` | `24` | zgodovina v urah |
| `-Streznik` / `-Baza` / `-Povezava` | `localhost` / `PIM_prd` | baza PIM (Windows prijava) |
| `-BrezSaop` | — | ne beri IIS dnevnikov SAOP |
| `-PimIp` | IP-ji tega strežnika | če PIM teče na drugem strežniku kot SAOP |
| `-Izhod` | `C:\Temp\PIM-poraba` | mapa za rezultate |

---

## D. Dnevniki servisa PIM avtomatike (PIM.AutomationHost)

Servis piše dve vrsti dnevnikov v **mapo dnevnikov**:

| Pot | Vsebina |
|---|---|
| `<mapa dnevnikov>\gostitelj\gostitelj-<datum>.log` | dnevnik servisa: zagon, najem, kateri posel je začel in končal, opozorila |
| `<mapa dnevnikov>\opravila\<POSEL>_<datum>_<ura>.log` | en dnevnik na zagon posla: vsak korak in izpis workerja |

Hranijo se 14 dni. **Katera je mapa dnevnikov**, se odloči po vrsti:
1. `Automation:LogRoot` v `appsettings.json` ob `PIM.AutomationHost.exe`;
2. register **LOG_ROOT** v intranetu (`/administracija/mape`);
3. privzeto mapa `logs` ob intranetu oziroma repozitoriju;
4. če ta ni zapisljiva: `%TEMP%\PIM\logs` računa, pod katerim teče servis (za LocalSystem
   `C:\Windows\Temp\PIM\logs`).

Prva vrstica dnevnika gostitelja pove, kam piše (`Dnevniki: …`). Najhitreje jo najdeš v bazi:
```sql
SELECT TOP (20) JobKey, StartedUtc, EndedUtc, Status, LogPath FROM ops.JobRun ORDER BY JobRunId DESC;
```
ali v PowerShellu:
```
Get-ChildItem C:\ -Recurse -Filter 'gostitelj-*.log' -ErrorAction SilentlyContinue | Select FullName, LastWriteTime
```
Dnevnik zagona posla odpreš tudi v intranetu (Nadzor → posel → zagon).

### Zakaj servis ob zagonu pobere procesor

Servis ob vsakem tiku (15 s) požene **vse posle, katerih termin je že mimo**. Ko je bil servis
ustavljen, so zamudili vsi, zato ob zagonu začnejo naenkrat: do **3 posli hkrati**
(`MaxConcurrentJobs`), vsak pa lahko dela do **4 podjetja vzporedno** (`Automation:MaxParallel` = 4).
Validacija, izvoz kataloga in zajem iz SAOP skupaj zlahka zasedejo vse jedra in SQL.
Na razvojnem računalniku ob zagonu dodatno zgradi vse workerje (`dotnet build`), na strežniku ne.
Preveri z `PIM-poraba-workerjev.ps1` (zgoraj) in v dnevniku gostitelja, kateri posli so začeli v
prvih minutah.

---

## B. Kdo bremeni bazo — `Diagnoza-obremenitve-baze.sql`

Primer: v upravitelju opravil `SQL Server (MSSQLSERVER)` porablja veliko CPU, zraven pa teče
`PIM.XmlFileWorker`.

### Zagon

1. V upravitelju opravil → zavihek **Details** → poišči `PIM.XmlFileWorker.exe` (in druge
   `PIM.*`) in si zapiši **PID**.
2. Odpri **SSMS**, poveži se na PIM strežnik, odpri `Diagnoza-obremenitve-baze.sql`, izberi bazo
   `PIM_prd` in pritisni **F5**.
3. Poženi, ko je strežnik obremenjen, in še enkrat, ko je miren, ter primerjaj.

### Kako brati

| Razdelek | Vprašanje | Kaj iskati |
|---|---|---|
| **0** | Kateri program bremeni bazo? | stolpec `pid` = PID iz upravitelja opravil. Najvišji `cpu_s_skupaj` je krivec. |
| **1** | Kaj teče ta trenutek? | `pid`, `procedura`, `stavek`, `traja_s`. `blokira_ga` ≠ 0 pomeni čakanje na drugo sejo. |
| 2 | Katere baze in programi so povezani? | ali poleg `PIM_prd` visi še `PIM_test` ali drug intranet |
| 3 | Najdražje poizvedbe od zagona SQL | katera procedura skupaj porabi največ CPU |
| 4 | Kdo drži razporejevalnik | več gostiteljev = več razporejevalnikov hkrati (napaka) |
| **5** | Koliko dneva teče posel | `zasedenost_pct` nad 30 % = razmik prekratek |
| 6 | Ali se posli prekrivajo | `minut_teka` 120 v uri = v povprečju dva hkrati |
| 7 | Najdaljši koraki v 24 h | kateri korak in katero podjetje traja najdlje |
| 8 | Urnik | kako pogosto je kaj nastavljeno |
| **9** | Kaj teče zdaj | kateri posel in korak je trenutno v teku, koliko minut |

### Kaj je `PIM.XmlFileWorker`

Uvozi XML kataloge dobaviteljev (Nowodvorski `NW_XML`, Braytron `BT_XML`) v `raw.Inbox` → `map`
→ `canon`. Zažene ga posel **`SUPPLIER_CATALOG_IMPORT`** vsakih 6 ur (ne kliče SAOP). Med tekom je
nekaj CPU v samem workerju normalno (bere XML). Če pa razdelek 0 pokaže njegov `pid` z velikim
`cpu_s_skupaj`, ali razdelek 5 kaže, da posel teče večji del dneva, je to vredno popraviti.
V tem primeru pošlji Claudu rezultate razdelkov 0, 1, 5 in 9.

**Pomnilnik:** 30 GB pri `SQL Server (MSSQLSERVER)` samo po sebi ni napaka. SQL si vzame
pomnilnik za predpomnilnik in ga ne vrača, dokler ima omejitev (»max server memory«) višjo.
Pomembnejši je CPU.

### Hitro v PowerShellu (na PIM strežniku)

Ali tečejo še stara Windows opravila, ki kličejo iste workerje:
```
Get-ScheduledTask | Where-Object TaskName -like 'PIM*' | Select TaskName, State
```

Kateri `PIM.*` procesi tečejo, od kdaj in s katerim ukazom:
```
Get-CimInstance Win32_Process -Filter "Name LIKE 'PIM.%'" | Select ProcessId, Name, CreationDate, CommandLine | Format-List
```
