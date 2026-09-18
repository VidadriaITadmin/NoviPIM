# Publish intraneta (PIM.Intranet) — korak po korak

Kratko, osredotočeno navodilo samo za **objavo aplikacije** (kodo) na IIS strežnik. Za bazo
(migracije, backup/restore, podatki) glej [`PRENOS_NA_TEST.md`](PRENOS_NA_TEST.md) — to tu je
podmnožica njegovega 6. poglavja, izluščena za hitro uporabo.

**Pomembno:** kodo na strežnik prenašaš prek **Git** (`git pull`), ne prek omrežnega deljenja
datotek (`\\STREZNIK\...`). Publish sam (`dotnet publish`) poganjaš **lokalno na strežniku**, ne
na razvojnem računalniku — zato ni potreben noben prenos velikih datotek prek SMB.

---

## 0. Enkratna priprava strežnika (samo prvič)

- [ ] **.NET nameščen ni potreben** — publish je self-contained (nosi svoj runtime). Za IIS pa
  rabiš **ASP.NET Core Hosting Bundle 10** (Microsoftova stran, "Hosting Bundle") — to namesti
  ANCM modul, ki ga IIS potrebuje. Po namestitvi `iisreset`.
- [ ] **Git nameščen** na strežniku (`git --version`).
- [ ] **IIS spletno mesto že obstaja.** Publish skripta ga ne ustvari — samo objavi vanj.
  - Application Pool `PIM`: **.NET CLR version = No Managed Code**, identiteta = servisni račun
    ali `ApplicationPoolIdentity` z dostopom do baze.
  - Site/aplikacija pod potjo **`/PIM`** (koda ima `UsePathBase("/PIM")` v `Program.cs`), fizična
    mapa npr. `C:\PIM\Intranet`.
  - Da se app pool ne ugaša po 20 min neaktivnosti:
    ```powershell
    Import-Module WebAdministration
    Set-ItemProperty 'IIS:\AppPools\PIM' -Name startMode -Value 'AlwaysRunning'
    Set-ItemProperty 'IIS:\AppPools\PIM' -Name processModel.idleTimeout -Value ([TimeSpan]::Zero)
    Set-ItemProperty 'IIS:\AppPools\PIM' -Name recycling.periodicRestart.time -Value ([TimeSpan]::Zero)
    ```
- [ ] **Koda klonirana** na strežniku, npr. `C:\PIM\NoviPIM`:
  ```powershell
  mkdir C:\PIM
  cd C:\PIM
  git clone <NASLOV-REPOZITORIJA> NoviPIM
  cd NoviPIM
  git checkout main
  ```
- [ ] **`appsettings.Local.json`** obstaja v ciljni mapi objave (`C:\PIM\Intranet\`) že od prej,
  ali pa ga tja ročno položiš pred prvim publishem (glej [`PRENOS_NA_TEST.md`](PRENOS_NA_TEST.md)
  korak 2.4). Publish skripta jo ob vsakem naslednjem publishu **ohrani** (ne prepiše).

---

## 1. Vsak naslednji publish — na strežniku

```powershell
cd C:\PIM\NoviPIM
git pull origin main
git log -1 --format='%H %s'
```

Preveri, da je hash tisti, ki ga pričakuješ (ujema se z zadnjim commitom na razvojnem računalniku).

- [ ] **1.1 Predogled (varno, nič ne spremeni):**
  ```powershell
  cd C:\PIM\NoviPIM\PIM_Solution
  pwsh -File .\deploy\Publish-Intranet.ps1 -Destination C:\PIM\Intranet -SiteName PIM -HealthUrl http://localhost/PIM/health -DryRun
  ```
  Izpiše korake, ki bi jih naredil (`DRYRUN: ...`), ne naredi ničesar.

- [ ] **1.2 Dejanski publish:**
  ```powershell
  pwsh -File .\deploy\Publish-Intranet.ps1 -Destination C:\PIM\Intranet -SiteName PIM -HealthUrl http://localhost/PIM/health
  ```

  Skripta sama naredi:
  1. `dotnet publish` (Release, `win-x64`, **self-contained** — vključuje .NET 10 runtime, na
     strežniku ni treba imeti ločeno nameščenega .NET-a) v začasno mapo.
  2. Shrani obstoječi `appsettings.Local.json` iz cilja.
  3. Postavi `app_offline.htm` (IIS med zamenjavo pokaže stran vzdrževanja).
  4. Staro mapo premakne v `C:\PIM\Intranet.backup`, novo premakne na njeno mesto (atomsko).
  5. Vrne nazaj `appsettings.Local.json`, odstrani `app_offline.htm`.
  6. Pokliče `HealthUrl` — če ni 200, **samodejno povrne prejšnjo mapo** (rollback) in vrže napako.

  Če vidiš napako, glej sporočilo — rollback se je že zgodil, prejšnja različica spet teče.

- [ ] **1.3 Preveri po objavi:**
  ```powershell
  Invoke-WebRequest http://localhost/PIM/health -UseBasicParsing | Select-Object StatusCode
  ```
  Pričakuj **200**. Nato v brskalniku `http://<strežnik>/PIM/prijava` — prijavna stran.

- [ ] **1.4 Vse v eni mapi — brez Gita na strežniku (workerji in cikli zraven).** Če na strežniku ni
  klona repozitorija (samo objavljena spletna stran, npr. `PIM_test_app`), objavi **na razvojnem
  računalniku**. Navaden publish intraneta zdaj sam doda še workerje in skripte (cilj
  `PimPublishWorkersAndScripts` v `PIM.Intranet.csproj`):
  ```powershell
  dotnet publish PIM_Solution\src\PIM.Intranet\PIM.Intranet.csproj -c Release -r win-x64 --self-contained true -o C:\PIM_publish\PIM_test_app
  ```
  Enakovredno, z izpisom korakov za strežnik: `powershell -ExecutionPolicy Bypass -File .\PIM_Solution\deploy\Publish-All.ps1 -Destination C:\PIM_publish\PIM_test_app`.
  Hiter popravek samo intraneta: dodaj `-p:PublishWorkers=false` (oz. `-BrezWorkerjev`).

  Nastane intranet + `Workerji\<Worker>\<Worker>.exe` + `scripts\` (samo `*.ps1`/`*.vbs`). `appsettings.Local.json`
  ni zraven — namenoma: na strežniku ostane tisti, ki je že v mapi spletnega mesta. **Povezava mora biti tam
  v `appsettings.Local.json`, ne v `appsettings.json`** — slednjega objava prepiše.

  Prenos (v RDP seji z omogočenim lokalnim diskom je razvojni `C:` viden kot `\\tsclient\C`; alternativa
  `\\STREŽNIK\C$\...` z razvojnega računalnika). Med kopiranjem naj cikli ne tečejo:
  ```powershell
  $site = 'C:\inetpub\wwwroot\PIM_test_app'
  Get-ScheduledTask 'PIM *' -ErrorAction SilentlyContinue | Disable-ScheduledTask
  Set-Content "$site\app_offline.htm" '<h1>Vzdrzevanje PIM</h1>'
  robocopy \\tsclient\C\PIM_publish\PIM_test_app $site /MIR /XF appsettings.Local.json app_offline.htm /XD logs izvoz /R:2 /W:5 /NP /NFL /NDL
  Remove-Item "$site\app_offline.htm"
  Get-ScheduledTask 'PIM *' -ErrorAction SilentlyContinue | Enable-ScheduledTask
  ```
  `/MIR` naredi točno kopijo (pobriše stare datoteke), `/XF appsettings.Local.json` ohrani povezavo,
  `/XD logs izvoz` ohrani dnevnike in izvoze po podjetjih. `app_offline.htm` IIS-u pove, naj aplikacijo
  ustavi, da datoteke niso zaklenjene.

  Intranet (`/sistem/workerji`) najde `Workerji\` in `scripts\` ob sebi **brez nastavitev**; ključi
  `WorkerConsole:*` so potrebni le, če so drugje. Windows naloge (samo prvič, v PowerShellu pod računom,
  pod katerim naj tečejo):
  ```powershell
  cd C:\inetpub\wwwroot\PIM_test_app
  powershell -ExecutionPolicy Bypass -File scripts\Namesti-opravila.ps1
  ```
  `Workerji\` najde sam; skripte berejo povezavo iz `appsettings.Local.json` v isti mapi. Nato v Task
  Scheduler pri nalogah `PIM *` označi »Run whether user is logged on or not«, na `/sistem/workerji` vklopi
  postopke (izklopljen zavrne tudi urnik, 51100), na `/administracija/mape` nastavi `EXPORT_ROOT` in
  `LANDING_ROOT` izven mape spletnega mesta. Workerji, ki kličejo SAOP, rabijo `appsettings.Local.json`
  s poverilnicami ob svojem `.exe` (`Workerji\PIM.SaopStockWorker\` …) ali `PIM_SAOP_*` v okolju.
  Podrobno: `docs/WORKERS.md`, »Strežnik brez izvorne kode«.

---

## 2. Ročna alternativa (če skripta ni na voljo ali za prvo ročno preverbo)

```powershell
dotnet publish C:\PIM\NoviPIM\PIM_Solution\src\PIM.Intranet -c Release -r win-x64 --self-contained true -o C:\PIM\Intranet
```

Nato ročno:
1. Kopiraj `appsettings.Local.json` v `C:\PIM\Intranet\` (če ni že tam).
2. `iisreset` ali samo restart app poola `PIM`:
   ```powershell
   Restart-WebAppPool -Name PIM
   ```
3. Preveri `http://localhost/PIM/health` → 200.

Opomba: ročna pot **nima** atomske zamenjave, `app_offline.htm` ali samodejnega rollbacka —
uporabi jo samo izjemoma, sicer vedno skripto iz 1. poglavja.

---

## 3. Če kaj ne gre

- **`Manjka predpogoj: dotnet` ali `Get-WebSite`** — Hosting Bundle ni nameščen ali PowerShell
  seja nima naloženega `WebAdministration` modula (`Import-Module WebAdministration`).
- **`IIS spletno mesto ne obstaja: PIM`** — pojdi nazaj na 0. poglavje, ustvari site v IIS Manager.
- **Health endpoint ne vrne 200** — skripta je že sama povrnila prejšnjo različico
  (`C:\PIM\Intranet.backup` → nazaj na `C:\PIM\Intranet`). Preglej `C:\PIM\Intranet.failed`
  (neuspeli poskus) za vzrok, npr. napačen connection string v `appsettings.Local.json`.
- **`Dejanski IIS deploy je dovoljen samo v Windows`** — skripta se je pognala v PowerShell 7 na
  ne-Windows okolju (npr. pomotoma prek WSL) — poženi jo v navadnem Windows PowerShell/pwsh.

---

## Povzetek — vse na enem mestu

```powershell
# na strežniku
cd C:\PIM\NoviPIM
git pull origin main
cd PIM_Solution
pwsh -File .\deploy\Publish-Intranet.ps1 -Destination C:\PIM\Intranet -SiteName PIM -HealthUrl http://localhost/PIM/health -DryRun
pwsh -File .\deploy\Publish-Intranet.ps1 -Destination C:\PIM\Intranet -SiteName PIM -HealthUrl http://localhost/PIM/health
Invoke-WebRequest http://localhost/PIM/health -UseBasicParsing | Select-Object StatusCode
```
