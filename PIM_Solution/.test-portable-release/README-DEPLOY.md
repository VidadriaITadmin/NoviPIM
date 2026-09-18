# PIM: prenosljiv paket za IIS in bazo

Ta postopek ne predpostavlja enakih map, istega diska ali istega connection stringa na razvojnem in strežniku.

## 1. Na razvojnem računalniku sestavi paket

Odpri PowerShell v korenu `PIM_Solution` in zaženi:

```powershell
pwsh -File .\deploy\New-PortableRelease.ps1 -OutputDirectory D:\PIM-Release\PIM-2026-09-15
```

Nastane ena mapa s tremi pomembnimi deli:

```text
PIM-2026-09-15\
  intranet\                 self-contained IIS aplikacija
  database\
    PIM.Migrator.exe         self-contained migrator
    migrations\              vse SQL migracije
    Apply-PimDatabase.ps1
  Install-PimIntranet.ps1
```

Na strežnik prenesi celotno mapo, na primer v `D:\Deploy\PIM-2026-09-15`. Ne kopiraj razvojnega `appsettings.Local.json`.

## 2. Enkrat na IIS strežniku pripravi site

Na strežniku morata biti nameščena IIS in **ASP.NET Core Hosting Bundle za .NET 10**. Application Pool mora biti `No Managed Code`.

Primer, kjer so poti samo primeri in jih zamenjaš s svojimi:

```powershell
Import-Module WebAdministration
New-Item -ItemType Directory -Path 'D:\Sites\PIM' -Force
New-WebAppPool -Name 'PIM'
Set-ItemProperty IIS:\AppPools\PIM -Name managedRuntimeVersion -Value ''
Set-ItemProperty IIS:\AppPools\PIM -Name processModel.identityType -Value 'ApplicationPoolIdentity'
New-Website -Name 'PIM' -PhysicalPath 'D:\Sites\PIM' -ApplicationPool 'PIM' -Port 8088
```

HTTPS binding in certifikat doda skrbnik strežnika glede na dejansko domeno in certifikat.

## 3. Na strežniku ustvari lokalno konfiguracijo

Shrani jo izven release mape, na primer kot `D:\PIM-Config\appsettings.Local.json`. Začni z `appsettings.Local.example.json` iz paketa in vpiši povezavo do **prave ciljne baze**.

```json
{
  "ConnectionStrings": {
    "Pim": "Server=SQL-STREZNIK,1433;Database=PIM;Integrated Security=True;Encrypt=True;TrustServerCertificate=True"
  }
}
```

IIS identiteta mora imeti dostop do SQL strežnika in pravico branja te datoteke. Gesla ne vpisuj v PowerShell ukaze.

## 4. Najprej posodobi bazo

Zaženi na strežniku iz mape release paketa:

```powershell
Set-Location D:\Deploy\PIM-2026-09-15\database
.\Apply-PimDatabase.ps1 -ConfigFile D:\PIM-Config\appsettings.Local.json
.\Apply-PimDatabase.ps1 -ConfigFile D:\PIM-Config\appsettings.Local.json -VerifyOnly
```

Prvi ukaz uporabi vse še neuporabljene migracije. Drugi preveri shemo in pogodbe F0–F10. Migracij nikoli ne poganjaj neposredno z `sqlcmd` in ne spreminjaj že uporabljenih `.sql` datotek.

Če želiš imeti skripto neposredno v ločeni mapi migracij, kot je `C:\Users\admindavidp\Desktop\migrations`, vanjo kopiraj `Zazeni-Pim-Migracije.ps1` iz `database\migrations`. Nato uporabi:

```powershell
Set-Location C:\Users\admindavidp\Desktop\migrations
.\Zazeni-Pim-Migracije.ps1 `
  -ConfigFile 'D:\PIM-Config\appsettings.Local.json' `
  -MigratorPath 'D:\Deploy\PIM-2026-09-15\database\PIM.Migrator.exe'
```

Skripta najprej za **vsako** `.sql` datoteko izpiše `Applied`, `Pending`, `CHANGED - STOP` ali `MISSING FILE - STOP`. Pri skladnem paketu izpiše `ALLOWED`; `Pending` pri tem pomeni, da se bo datoteka pravkar namestila. Nato uporabi samo `Pending`, ponovno preveri, da jih ni več, in zažene preverjanje baze. Če izpiše `NOT ALLOWED`, ni naredila nobene spremembe. Za samo pregled brez sprememb dodaj `-StatusOnly`.

## 5. Objavi intranet v IIS

```powershell
Set-Location D:\Deploy\PIM-2026-09-15
.\Install-PimIntranet.ps1 `
  -Destination 'D:\Sites\PIM' `
  -SiteName 'PIM' `
  -HealthUrl 'http://localhost:8088/health' `
  -ConfigFile 'D:\PIM-Config\appsettings.Local.json'
```

Ob naslednji objavi je dovolj isti ukaz z novo release mapo. Skripta ohrani obstoječi `appsettings.Local.json`, če `-ConfigFile` izpustiš, in prejšnjo aplikacijo preimenuje v mapo z `.backup-<čas>`.

## 6. Preveri po objavi

```powershell
Invoke-WebRequest 'http://localhost:8088/health'
```

Pričakovan je HTTP 200. Nato v brskalniku odpri naslov IIS mesta; če je PIM nameščen kot virtualna aplikacija `/PIM`, uporabi `https://tvoja-domena/PIM/` in health URL `https://tvoja-domena/PIM/health`.

## Povrnitev aplikacije

Če health check ob objavi ne uspe, skripta samodejno povrne prejšnjo mapo. Baze ne vračaj z brisanjem migracij: povrnitev baze naredi samo iz backup-a, ki ga je pred migracijo pripravil skrbnik SQL strežnika.
