# 07 — Ko kaj ne dela

| Znak | Vzrok | Rešitev |
|---|---|---|
| `... .ps1 is not digitally signed` / `cannot be loaded` | datoteke iz ZIP-a so označene »z interneta« | `Get-ChildItem <mapa> -Recurse -File \| Unblock-File`, ali zaženi z `powershell -ExecutionPolicy Bypass -File ...` |
| build: `CS0104 ... is an ambiguous reference` | ZIP razpakiran čez staro mapo, ostale so izbrisane datoteke | razpakiraj v prazno mapo, prekopiraj samo `appsettings.Local.json` |
| build: `file is locked by ...` / `MSB3027` | Visual Studio ali tekoči program drži `bin\` | Shift+F5 v VS, ustavi `PIM.AutomationHost`, ali `-p:OutDir=$env:TEMP\pim-build\` |
| `Invoke-PendingMigrations`: `empty string` za Path | Windows PowerShell 5.1 + `-File` | dodaj `-MigrationsPath <absolutna pot do sql\migrations>` |
| migracija: napaka **1934** (QUOTED_IDENTIFIER) | ročni `sqlcmd` brez `-I` | vedno `sqlcmd -I`; skripta za migracije to naredi sama |
| `-Status` kaže `CHANGED` / `SPREMENJENA` | uveljavljena datoteka je bila kasneje spremenjena (pogosto samo konci vrstic CRLF/LF) | skripta jo preskoči; ne briši vrstice iz `dbo.SchemaMigration`, ne poganjaj na silo — najprej preveri, ali baza že ima stanje, ki ga datoteka opisuje |
| sqlcmd v Git Bashu: `-E and -U/-P mutually exclusive` ali `Access denied C:` | Bash pretvori `/`-stikala v poti | pred ukaz `MSYS_NO_PATHCONV=1` ali uporabi PowerShell |
| `/health` ne vrne 200 po objavi | napačna/manjkajoča povezava v `appsettings.Local.json`, manjka Hosting Bundle, baza ni migrirana | `eventvwr` → Application; preveri `appsettings.Local.json` v mapi spletnega mesta; poženi `-Status` migracij |
| IIS: **HTTP 500.19 / 500.30** | Hosting Bundle ni nameščen ali aplikacija pade ob zagonu | namesti *.NET 10 Hosting Bundle* + `iisreset`; za 500.30 poglej `eventvwr` |
| robocopy: »file in use« | aplikacija/gostitelj teče | `app_offline.htm` + `Stop-Service PIM.AutomationHost` pred kopiranjem |
| `/sistem`: utrip star več minut | gostitelj ne teče | lokalno zaženi (05); strežnik: `Get-Service PIM.AutomationHost`, dnevnik gostitelja |
| `/sistem`: piše `console` na strežniški bazi | nekdo poganja gostitelja ročno proti tej bazi | ustavi ročni primerek; na eni bazi en gostitelj |
| storitev se ne zažene (*Error 1069: logon failure*) | napačno geslo ali račun nima pravice *Log on as a service* | `services.msc` → lastnosti → Log On; `secpol.msc` → User Rights → *Log on as a service* |
| storitev teče, a posli padajo z napako prijave v SQL | račun storitve nima prijave v SQL Server | v SSMS dodaj login za račun in pravice na bazo `PIM` |
| posel teče zelo dolgo / visi | zaklepanje z drugo operacijo (dolga migracija, ročni izvoz) | na `/sistem/posel/<KLJUČ>` poglej trenutni korak; po potrebi prekliči in ponovi izven konic |

## Kje iskati dnevnike

| Kaj | Kje |
|---|---|
| gostitelj avtomatike | `<LOG_ROOT>\gostitelj\gostitelj-<datum>.log` (LOG_ROOT na `/administracija/mape`) |
| posamezen zagon posla | `/sistem/posel/<KLJUČ>` → zagon → pot do dnevnika (`ops.JobRun.LogPath`) |
| intranet v IIS | `eventvwr` → Windows Logs → Application (vir *IIS AspNetCore Module V2*) |
| storitve | `eventvwr` → Windows Logs → System (vir *Service Control Manager*) |
