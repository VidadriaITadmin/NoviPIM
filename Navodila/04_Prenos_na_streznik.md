# 04 — Prenos aplikacije na IIS strežnik

Poti spodaj so **primeri** — zamenjaj jih s svojimi:

| Oznaka | Primer |
|---|---|
| mapa spletnega mesta (IIS) | `C:\inetpub\wwwroot\PIM_test_app` |
| objava z razvojnega računalnika | `C:\PIM_publish\PIM_app` (v RDP: `\\tsclient\C\PIM_publish\PIM_app`) |
| IIS application pool | `PIM` |

## A. Enkratna priprava strežnika (samo prvič)

1. **ASP.NET Core Hosting Bundle 10** (Microsoftova stran ».NET 10 Hosting Bundle«), nato `iisreset`.
2. **IIS application pool** `PIM`: *.NET CLR version = No Managed Code*.
   Da se ne ugaša in da ob recikliranju ne čaka na prvo zahtevo:
   ```powershell
   Import-Module WebAdministration
   Set-ItemProperty 'IIS:\AppPools\PIM' -Name startMode -Value 'AlwaysRunning'
   Set-ItemProperty 'IIS:\AppPools\PIM' -Name processModel.idleTimeout -Value ([TimeSpan]::Zero)
   ```
3. **Spletno mesto / aplikacija** kaže na mapo spletnega mesta, pool = `PIM`.
4. **`appsettings.Local.json`** v mapo spletnega mesta — začni iz `PIM_Solution\appsettings.Local.example.json`
   in vpiši **strežniško** povezavo do baze `PIM` (in SAOP poverilnice). Pravice na datoteko: samo
   administratorji, identiteta poola in račun AutomationHosta.
5. **Mape za podatke** izven mape spletnega mesta (npr. `D:\PIM\izvoz`, `D:\PIM\prevzem`) — nastavi jih
   v aplikaciji na `/administracija/mape` (`EXPORT_ROOT`, `LANDING_ROOT`). Tja objava nikoli ne piše.
6. Prvi prenos (korak B), nato **namesti AutomationHost kot storitev** —
   [05_AutomationHost.md](05_AutomationHost.md), razdelek »Strežnik«.
7. Stare Windows naloge ciklov (iz časa pred AutomationHostom), če še obstajajo, odstrani:
   ```powershell
   Get-ScheduledTask 'PIM *' | Select-Object TaskName, State
   powershell -ExecutionPolicy Bypass -File <mapa spletnega mesta>\scripts\Namesti-opravila.ps1 -Odstrani
   ```
   Ostane naj samo **»PIM nadzor avtomatike«** (zunanji nadzor utripa).

## B. Vsak prenos nove različice

PowerShell **kot administrator** na strežniku (RDP z vklopljenim lokalnim diskom, da vidiš `\\tsclient\C`):

```powershell
$site = 'C:\inetpub\wwwroot\PIM_test_app'
$src  = '\\tsclient\C\PIM_publish\PIM_app'

# 0. backup baze + migracije (02_Migracije.md) - VEDNO PRED kopiranjem

# 1. ustavi avtomatiko (drži Workerji\PIM.AutomationHost\*.exe zaklenjen)
Stop-Service PIM.AutomationHost
Disable-ScheduledTask 'PIM nadzor avtomatike' -ErrorAction SilentlyContinue   # da med tem ne sproži alarma

# 2. IIS ustavi aplikacijo
Set-Content "$site\app_offline.htm" '<h1>Vzdrzevanje PIM</h1>'
Start-Sleep 5

# 3. kopiraj (točna kopija; ohrani nastavitve, dnevnike in izvoze)
robocopy $src $site /MIR /XF appsettings.Local.json app_offline.htm /XD logs izvoz /R:2 /W:5 /NP /NFL /NDL

# 4. zaženi nazaj
Remove-Item "$site\app_offline.htm"
Start-Service PIM.AutomationHost
Enable-ScheduledTask 'PIM nadzor avtomatike' -ErrorAction SilentlyContinue
```

`robocopy` izhodna koda 0–7 pomeni uspeh (1 = kopirane datoteke). 8 ali več = napaka — preberi izpis.

## C. Preveri

```powershell
Invoke-WebRequest http://localhost/PIM/health -UseBasicParsing | Select-Object StatusCode   # pričakuj 200
Get-Service PIM.AutomationHost                                                             # Running
```

V brskalniku:
- prijava deluje,
- `/sistem` — gostitelj kaže **`AutomationHost:service · <ime strežnika>`**, utrip pred nekaj sekundami,
- prvi posli po urniku se končajo zeleno.

## D. Povrnitev (če nova različica ne dela)

Najhitreje: ponovno prekopiraj **prejšnjo** objavo (hrani zadnjo delujočo mapo, npr.
`C:\PIM_publish\PIM_app_prejsnja`) z istim postopkom B.
Baze ne vračaj z brisanjem migracij — samo iz backupa (korak 0), in samo če je res potrebno.

Samodejna različica z rollbackom (ko je izvorna koda na strežniku): `deploy\Publish-Intranet.ps1`,
opisano v `docs/PUBLISH.md`.
