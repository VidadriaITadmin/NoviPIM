# Windows: izvedbeni seznam za backup, namestitev in E2E PIM

Ta dokument izvajaš ti na Windows računalniku. Ne pošiljaj gesel, connection stringov, API ključev ali `.bak` datoteke v Git oziroma chat.

## A. Najprej backup baze `PIM`

1. Na SQL Server računalniku ustvari mapo:

```powershell
New-Item -ItemType Directory -Force C:\PIM\Backups | Out-Null
```

2. SQL Server service accountu dodeli pravico zapisa v `C:\PIM\Backups`.
3. V SSMS se poveži na instanco, ki vsebuje bazo `PIM`.
4. Odpri in zaženi:

```text
C:\PIM\Source\NoviPIM\PIM_Solution\deploy\Backup-PIM.sql
```

5. Pred zagonom v datoteki spremeni samo:

```sql
DECLARE @BackupFile nvarchar(4000) = N'C:\PIM\Backups\PIM_full_YYYYMMDD.bak';
```

Uspeh: `RESTORE VERIFYONLY` se uspešno zaključi, zadnji SELECT pa pokaže točno pot `.bak` datoteke. Ta backup je `COPY_ONLY`, zato ne spreminja običajne SQL backup verige. Cilj je izključno `PIM`, ne `PIM_test`.

## B. Prenos projekta

1. Na Windows ustvari `C:\PIM\Source`.
2. Vanj prenesi celoten repozitorij `NoviPIM`.
3. V PowerShellu preveri:

```powershell
Set-Location C:\PIM\Source\NoviPIM
Get-Item .\PIM_Solution\PIM.sln
```

## C. Namesti predpogoje

PowerShell zaženi kot Administrator:

```powershell
winget install Microsoft.DotNet.SDK.8
winget install Microsoft.PowerShell
Enable-WindowsOptionalFeature -Online -FeatureName IIS-WebServerRole -All
```

Nato iz uradne Microsoft strani namesti **ASP.NET Core Hosting Bundle 8.x**, odpri nov PowerShell in preveri:

```powershell
pwsh -Version
dotnet --info
iisreset
```

Če SQL Server/SSMS še nista nameščena, ju namesti pred naslednjim korakom.

## D. Baza in connection string

1. V SSMS izključno za bazo `PIM` uporabi:

```text
C:\PIM\Source\NoviPIM\SSMS_PIM_PROVISIONING.md
```

2. Ustvari lokalno, Git-ignorirano datoteko:

```text
C:\PIM\Source\NoviPIM\PIM_Solution\appsettings.Local.json
```

3. Vsebina z lastnim geslom:

```json
{
  "ConnectionStrings": {
    "Pim": "Server=localhost,1433;Database=PIM;User Id=pim_hermes;Password=VSTAVI_GESLO;Encrypt=True;TrustServerCertificate=True"
  }
}
```

Če je SQL na drugem strežniku, spremeni samo `Server=localhost,1433`.

4. Preveri, da ni Git sprememba:

```powershell
Set-Location C:\PIM\Source\NoviPIM
git status --short PIM_Solution\appsettings.Local.json
```

Pričakovano: prazen izpis.

## E. Migracije in preverjanje sistema

```powershell
Set-Location C:\PIM\Source\NoviPIM\PIM_Solution
$env:PIM_CONNECTION_STRING = (Get-Content .\appsettings.Local.json -Raw | ConvertFrom-Json).ConnectionStrings.Pim
pwsh -File .\deploy\Apply-Migrations.ps1
pwsh -File .\deploy\Apply-Migrations.ps1
pwsh -File .\deploy\Apply-Migrations.ps1 -VerifyOnly
dotnet build .\PIM.sln -c Release --no-restore
```

Uspeh:
- drugi migracijski zagon ničesar ne podvoji;
- izpis: `Preverjanje F0–F9 baze je uspešno.`;
- build: `0 Warning(s)`, `0 Error(s)`.

## F. Lokalni intranet pred IIS

Prvo okno PowerShell:

```powershell
Set-Location C:\PIM\Source\NoviPIM\PIM_Solution
$env:ASPNETCORE_URLS = "http://127.0.0.1:5088"
dotnet run --project .\src\PIM.Intranet\PIM.Intranet.csproj
```

Drugo okno:

```powershell
Invoke-WebRequest http://127.0.0.1:5088/health -UseBasicParsing
```

Pričakuj HTTP 200. V brskalniku odpri:

```text
http://127.0.0.1:5088/prijava
```

## G. IIS

1. Ustvari Application Pool `PIM`, **No Managed Code**, namenski račun `PIM_SVC`.
2. Ustvari IIS site `PIM`, fizična pot `C:\PIM\Intranet`, nastavi HTTPS binding.
3. Najprej predogled:

```powershell
Set-Location C:\PIM\Source\NoviPIM\PIM_Solution
pwsh -File .\deploy\Publish-Intranet.ps1 -Destination C:\PIM\Intranet -SiteName PIM -HealthUrl https://localhost/health -DryRun -WhatIf
```

4. Nato dejanska objava:

```powershell
pwsh -File .\deploy\Publish-Intranet.ps1 -Destination C:\PIM\Intranet -SiteName PIM -HealthUrl https://localhost/health
```

5. Preveri:

```powershell
Invoke-WebRequest https://localhost/health -UseBasicParsing
```

Pričakuj HTTP 200.

## H. E2E testni seznam

### Katalog
- SAOP samo bralni zajem; zapiši `RunId`, read/succeeded/failed, watermark in karanteno.
- NW XML: preveri EAN, attribute, classification in media.
- Preveri veljaven, neveljaven in neznan XML primer.
- Preveri `PRODUCTS CSV` in število vrstic.

### Zaloge
- NW CSV identiteta `NW.<šifra>`.
- BT XML identiteta `BA.<koda z vezaji zamenjanimi s pikami>`.
- SAOP org. 3 RegisteredView samo, če je v resnici konfiguriran; ostali org. samo konfiguriran warehouse provider.
- Preveri `/zaloge` in STOCK CSV.

### B2B
- Preveri testno stranko, ročni tip/vrsto, Magento group mapping, PAK2, S1–S4 in pragove 800/1500/3000.
- Preveri CUSTOMERS, B2B PRODUCTS in SHIPPING CSV.

### F8
- Ne pošiljaj realnega SAOP write-backa, dokler nimamo potrjenega varnega testnega artikla in endpoint/payload pogodbe.
- Preglej `/outbound`, lokalni fixture stanje in audit.

### F9
- Preveri `/system/integracije`.
- Preveri watchdog/alarm stale-recovery v izoliranem testu.
- Pravi e-mail/webhook naj ostane izključen.

Podrobnejši seznam in format rezultatov je v:

```text
C:\PIM\Source\NoviPIM\.hermes\plans\2026-07-31_150000-windows-e2e-handoff.md
```

## I. Kaj mi pošlji

Pošlji brez skrivnosti:

```text
- rezultat Backup-PIM.sql (pot, velikost in VERIFYONLY uspeh)
- `PIM.Migrator --verify` izpis
- IIS health HTTP rezultat
- za vsak pipeline: RunId, organizacija, vir, read/succeeded/failed, watermark, karantena
- število vrstic vseh CSV in 2 anonimizirana primera iz vsake datoteke
- NW/BT/SAOP stock števce in unmatched/karanteno
- F7 customer/group/discount rezultat
- F8: fixture ali live SAOP ter statusi outboxa
- F9: lease/alarm/recovery in Scheduled Task LastTaskResult
- celoten error/log brez gesel in connection stringov
```
