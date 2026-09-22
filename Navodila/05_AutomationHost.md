# 05 — AutomationHost (gostitelj avtomatike)

`PIM.AutomationHost.exe` je **edini** motor avtomatike: po urniku poganja posle (zajem iz SAOP, zaloga,
datumi dobave, BT/NW XML, validacija, izvozi za splet, alarmi …), vsakega kot korake z workerji iz
mape `Workerji\`. Intranet ga samo prikazuje in mu pošilja ročne zagone — **prek baze**, nista
neposredno povezana.

```
IIS  ── PIM.Intranet ──┐
                       ├──►  baza PIM  (ops.SchedulerLease = utrip, ops.JobRun = zagoni)
Windows storitev ──────┘
  PIM.AutomationHost ──► Workerji\PIM.*Worker.exe
```

Zakaj ni v IIS: recikliranje poola, objava ali mirovanje bi ustavili tudi avtomatiko.

## Kako vidiš, ali teče

Stran **`/sistem`** v intranetu, vrstica gostitelja, npr. `AutomationHost:console · DESKTOP-TONVQHJ · utrip pred 7 s`:

| Del | Pomen |
|---|---|
| `console` / `service` | zagnan ročno kot program / kot Windows storitev |
| ime računalnika | kje teče |
| utrip pred N s | zadnji znak življenja; normalno do ~30 s. Več kot 10 min = gostitelj ne teče |

Iz SQL:
```sql
SELECT Application, HostName, ProcessId, HeartbeatUtc, DATEDIFF(second, HeartbeatUtc, SYSUTCDATETIME()) AS sekund
FROM ops.SchedulerLease;
```

## Lokalno (razvojni računalnik) — konzola

Tu **ni** nameščen kot storitev in ne sme biti (storitev bi zaklenila `bin\` in Visual Studio ne bi
mogel prevajati). Zato ga v `services.msc` ne najdeš. Poganjaš ga kot program:

```powershell
cd C:\Users\david\Desktop\PIM\NoviPIM\PIM_Solution
dotnet run --project workers\PIM.AutomationHost
```

ali zaženi projekt `PIM.AutomationHost` v Visual Studiu. Ustaviš ga s **Ctrl+C** v oknu ali v
upravitelju opravil (*Podrobnosti* → `PIM.AutomationHost.exe` → Končaj opravilo).
Ali teče: `Get-Process PIM.AutomationHost -ErrorAction SilentlyContinue`.

Povezavo do baze bere iz `appsettings.Local.json` (ali okoljske spremenljivke `PIM_CONNECTION_STRING`).

### Stikala

```powershell
PIM.AutomationHost.exe --pomoc                 # izpis vseh stikal
PIM.AutomationHost.exe --enkrat SAOP_DELIVERY  # en zagon posla zdaj, nato izhod
PIM.AutomationHost.exe --posli SAOP_STOCK,NW_STOCK   # samo našteti posli
PIM.AutomationHost.exe --samo-nadzor           # brez poslov, samo utrip, čiščenje, alarmi
PIM.AutomationHost.exe --preveri               # ali gostitelj utripa (0 = da, 1 = molči, 2 = ni baze)
```

Z `dotnet run` dodaj stikala za `--`: `dotnet run --project workers\PIM.AutomationHost -- --enkrat SAOP_DELIVERY`.

Primeri ključev poslov: `SAOP_STOCK`, `SAOP_DELIVERY`, `SAOP_ORDERS_VNK`, `SAOP_ORDERS_VND`, `BT_STOCK`,
`NW_STOCK`, `BT_XML`, `NW_XML`, `STOCK_REPLENISHMENT_DIGEST`. Vsi so na `/sistem`.

## Strežnik — Windows storitev

### Namestitev (enkrat)

PowerShell **kot administrator**, po prvem prenosu objave (04):

```powershell
cd <mapa spletnega mesta>
powershell -ExecutionPolicy Bypass -File <NoviPIM>\PIM_Solution\deploy\Install-AutomationHost.ps1 `
  -BinaryPath 'C:\inetpub\wwwroot\PIM_test_app\Workerji\PIM.AutomationHost\PIM.AutomationHost.exe' `
  -ServiceAccount 'DOMENA\pim-avtomatika' `
  -ZunanjiNadzor -DryRun
```

Preberi izpis, nato isti ukaz **brez `-DryRun`** (vpraša za geslo računa). Skripta:

1. računu da pravico branja/izvajanja mape programa,
2. ustvari storitev **`PIM.AutomationHost`** (prikazno ime *PIM gostitelj avtomatike*), zagon *Automatic*,
3. nastavi ponovni zagon ob padcu (5 s, 10 s, 30 s),
4. storitev zažene,
5. z `-ZunanjiNadzor` registrira nalogo **»PIM nadzor avtomatike«**, ki vsakih 5 min preveri utrip in
   ob 10 min molka pošlje alarm.

**Račun storitve** (`DOMENA\pim-avtomatika` ali lokalni uporabnik) potrebuje:
- prijavo v SQL Server na bazo `PIM` z enakimi pravicami kot workerji (ne `db_owner`, ne `LocalSystem` — skripta ga zavrne),
- pisanje v `EXPORT_ROOT`, `LANDING_ROOT` in mapo dnevnikov,
- branje mape spletnega mesta (tam je `appsettings.Local.json` in `Workerji\`).

Skripta ni na strežniku (ni izvorne kode)? Prekopiraj samo `Install-AutomationHost.ps1` in
`scripts\Namesti-nadzor-avtomatike.ps1`, ali storitev ustvari ročno:
```powershell
New-Service -Name PIM.AutomationHost -BinaryPathName '"C:\inetpub\wwwroot\PIM_test_app\Workerji\PIM.AutomationHost\PIM.AutomationHost.exe"' `
  -DisplayName 'PIM gostitelj avtomatike' -StartupType Automatic -Credential (Get-Credential 'DOMENA\pim-avtomatika')
sc.exe failure PIM.AutomationHost reset= 86400 actions= restart/5000/restart/10000/restart/30000
sc.exe failureflag PIM.AutomationHost 1
Start-Service PIM.AutomationHost
```

### Vsakdanje upravljanje

| Kaj | Ukaz |
|---|---|
| stanje | `Get-Service PIM.AutomationHost` |
| ustavi / zaženi / ponovno | `Stop-Service` / `Start-Service` / `Restart-Service PIM.AutomationHost` |
| grafično | `services.msc` → *PIM gostitelj avtomatike* |
| dnevnik | `<LOG_ROOT>\gostitelj\gostitelj-<datum>.log`; padci storitve v `eventvwr` → Windows Logs → Application/System |
| odstrani | `Install-AutomationHost.ps1 -Odstrani` |

**Ob vsaki objavi:** `Stop-Service` pred kopiranjem, `Start-Service` po njem (04, korak B).
Ker je pot do `.exe` ista, storitve ni treba ponovno nameščati.

## Pogoste zmede

- **Na strani piše `console`, na strežniku bi moral biti `service`:** na isto bazo je priklopljen
  nekdo, ki ga poganja ročno (npr. tvoj razvojni računalnik z razvojno povezavo na strežniško bazo).
  Ugasni ga — na eni bazi naj teče en gostitelj.
- **Utrip star več minut:** gostitelj ne teče. Lokalno ga zaženi; na strežniku `Get-Service`, nato dnevnik.
- **Posli se ne zaženejo, utrip pa je živ:** posel ali podjetje je izklopljeno na `/sistem`, ali čaka
  na odvisnost (drug posel še teče / je padel) — razlog piše pri poslu.
