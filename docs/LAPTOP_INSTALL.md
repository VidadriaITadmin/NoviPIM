# Prenos in namestitev celotnega PIM na laptop

To navodilo je za nov Windows laptop in razvojno/testno okolje. Cilj je lokalni dokaz sistema nad bazo `PIM`, ne produkcijska objava in ne živa integracija.

## 0. Varnostna pravila

- Ne kopiraj `.env`, `appsettings.Local.json`, gesel, tokenov ali `.bak` datotek v Git/chat.
- Cilj baze je izključno `PIM`, nikoli `PIM_test`.
- Živi SAOP write-back, zunanji webhooki in Magento dostava ostanejo izključeni.
- Najprej izvedi vsak deploy/worker script z `-DryRun` ali `-WhatIf`.

## 1. Predpogoji laptopa

1. Windows 10/11 x64, lokalni administratorski račun samo za IIS/predpogoje.
2. SQL Server 2019+ instance ali dosegljiva razvojna SQL instanca.
3. .NET 8 SDK; za IIS tudi ASP.NET Core Hosting Bundle 8.x.
4. IIS z ASP.NET Core modulom, če bo intranet gostovan prek IIS.
5. PowerShell 7 za deploy skripte.
6. Git ali preverjen arhiv repozitorija.

Preveri:

```powershell
dotnet --info
pwsh -Version
```

## 2. Prenos

1. Ustvari `C:\PIM\Source`.
2. Kopiraj repozitorij `NoviPIM` v `C:\PIM\Source\NoviPIM`.
3. Preveri, da obstaja `C:\PIM\Source\NoviPIM\PIM_Solution\PIM.sln`.
4. Če je prenos prek arhiva/releasea, preveri SHA-256, ki ga je ustvaril izvorni računalnik.

```powershell
Set-Location C:\PIM\Source\NoviPIM
Get-FileHash .\PIM_Solution\PIM.sln -Algorithm SHA256
```

## 3. Baza

1. Pred posegom naredi COPY_ONLY backup izvorne `PIM` baze in izvede `RESTORE VERIFYONLY`.
2. Na laptopu ustvari ali obnovi samo `PIM`.
3. Lokalno, izven Gita, ustvari `C:\PIM\Source\NoviPIM\PIM_Solution\appsettings.Local.json` z Windows-integrirano povezavo do laptop SQL instance. Uporabi `Encrypt=True;TrustServerCertificate=True` le za lokalno/testno potrdilo.
4. Ne izpisuj vsebine te datoteke v terminal ali poročilo.

Nato:

```powershell
Set-Location C:\PIM\Source\NoviPIM\PIM_Solution
$env:PIM_CONNECTION_STRING = (Get-Content .\appsettings.Local.json -Raw | ConvertFrom-Json).ConnectionStrings.Pim
$env:PIM_MIGRATIONS_PATH = 'C:\PIM\Source\NoviPIM\PIM_Solution\sql\migrations'
pwsh -File .\deploy\Apply-Migrations.ps1
pwsh -File .\deploy\Apply-Migrations.ps1
pwsh -File .\deploy\Apply-Migrations.ps1 -VerifyOnly
```

STOP, če drugi zagon spremeni shemo ali `--verify` ni uspešen.

## 4. Build in avtomatski test

```powershell
dotnet restore .\PIM.sln
dotnet build .\PIM.sln -c Release --no-restore
npm test
```

Nato zaženi dokazne teste po navodilu `docs\END_TO_END_TEST.md`. Testi, ki zahtevajo bazo, se izvajajo samo z `PIM_CONNECTION_STRING` proti `PIM`.

## 5. Lokalni intranet pred IIS

Prvo okno:

```powershell
Set-Location C:\PIM\Source\NoviPIM\PIM_Solution
$env:ASPNETCORE_URLS = 'http://127.0.0.1:5088'
dotnet run --project .\src\PIM.Intranet\PIM.Intranet.csproj
```

Drugo okno:

```powershell
Invoke-WebRequest http://127.0.0.1:5088/health -UseBasicParsing
```

Pričakuješ HTTP 200 in JSON z `stanje: zdravo`. Odpri `http://127.0.0.1:5088/prijava` in izpelji intranetni del E2E seznama.

## 6. IIS (samo po uspešnem lokalnem Kestrel testu)

1. Ustvari App Pool `PIM`: No Managed Code, namenska identiteta z najmanjšimi SQL pravicami.
2. Ustvari site `PIM` in HTTPS binding z laptop testnim certifikatom.
3. Najprej naredi predogled:

```powershell
Set-Location C:\PIM\Source\NoviPIM\PIM_Solution
pwsh -File .\deploy\Publish-Intranet.ps1 -Destination C:\PIM\Intranet -SiteName PIM -HealthUrl https://localhost/health -DryRun -WhatIf
```

4. Preglej poti, site in health URL. Šele potem odstrani `-DryRun -WhatIf`.
5. Preveri `https://localhost/health` in nato `/PIM/prijava`, če je intranet objavljen kot IIS aplikacija.

Ob neuspelem health preverjanju `Publish-Intranet.ps1` vrne prejšnjo mapo iz atomskega backupa. Ne briši migracij za rollback baze; za bazo uporabi le preverjen backup.

## 7. Workerji

1. Najprej samo fixture/replay workerji in lokalne landing mape.
2. Objavi posamezen worker self-contained.
3. Ročno poženi njegovo lokalno ovojno skripto in preveri pipeline/heartbeat/karanteno.
4. Šele nato preglej Scheduled Task `-DryRun -WhatIf`.
5. Task registriraj pod namenskim servisnim računom, nikoli LocalSystem/SYSTEM.

Podrobnosti: `docs\WORKERS.md`.

## 8. Predaja

Zapiši brez skrivnosti:
- hash prenesenega repozitorija/artefakta;
- rezultat obeh migratorskih zagonov in `--verify`;
- build/test rezultate;
- HTTP status `/health` za Kestrel in IIS;
- za vsak fixture pipeline RunId, števec read/success/fail, watermark in karanteno;
- rezultat outbox lokalnega fixture testa;
- znane omejitve oziroma neizvedene žive integracije.
