# Prenos na TEST — z razvojnega računalnika na bazo TEST na strežniku

Datum: 2026-09-03. Za enega človeka (lastnika), ki dela sam. Vsak korak ima kljukico, ukaz in
to, kar mora pisati na zaslonu.

**Izhodišče:** razvojni računalnik Windows, SQL Server `localhost\MSSQLSERVER3`, baza `PIM`,
repozitorij `C:\Users\david\Desktop\PIM\NoviPIM`, veja `feature/izhodi-erp-01-saop-polji`,
zadnja migracija **150**.

**Cilj:** ista koda in ista shema na strežniku podjetja, nad bazo **TEST** (ne produkcija).

Podrobna namestitev »iz nule« (namestitev .NET, Gita, SQL, ustvarjanje uporabnika, kam
klikneš) je že v [`PRENOS_NA_SLUZBENI_RACUNALNIK.md`](PRENOS_NA_SLUZBENI_RACUNALNIK.md).
Ta zapis je ne ponavlja — nanjo se sklicuje in pokrije tisto, kar je pri prenosu **na strežnik**
drugače: bazo TEST, znano oviro pri migraciji 070, kaj v bazi nastane samo in kaj je bilo na
razvojnem računalniku nastavljeno ročno, opravila pod servisnim računom ter IIS.
[`LAPTOP_INSTALL.md`](LAPTOP_INSTALL.md) je zastarel in ga ne uporabljaj.

---

## 0. Kaj prenašamo in kaj ne

**Prenašamo:**

- kodo (`PIM_Solution\`), skripte (`scripts\`, `PIM_Solution\deploy\`) in dokumentacijo — vse, kar je v Gitu;
- **migracije** `PIM_Solution\sql\migrations\001…150` — iz njih nastane celotna shema
  (tabele, procedure, registri: štiri podjetja, viri, validacijski profili, urniki, izvozni profili).

**Ne prenašamo:**

- **podatkov** — artikli, cene, zaloga, slike, stranke se naložijo iz SAOP in od dobaviteljev
  (korak 4); izjema je možnost (b) v koraku 3, kjer bazo TEST začnemo iz varnostne kopije DEV;
- **`appsettings.Local.json`** (v korenu repozitorija) — vsebuje gesla za SAOP, FTP in povezovalni
  niz. **Ni in ne sme biti v Gitu.** Na strežnik jo preneseš ročno (USB ključ ali upravitelj gesel),
  nikoli po e-pošti ali v klepetu;
- mape `logs\`, `izvoz\`, `PIM_Solution\data\prevzem\` — nastanejo same ob prvem zagonu.

**Kaj na TEST ne pride z migracijami in je treba narediti na roko** (podrobno v koraku 3.5):
uporabniki in gesla (`sec.LocalUser`), prejemniki alarmov (`ops.AlertRecipientConfig`), kanal
`SAOP_PRODUCT` v `dbo.IntegrationProfile`, SMTP nastavitve v okolju.

---

## 1. Na razvojnem računalniku — zapakiraj stanje

Vse v PowerShellu 7 v mapi repozitorija.

```powershell
cd C:\Users\david\Desktop\PIM\NoviPIM
```

- [ ] **1.1 Delovno drevo je čisto.** Kar ni commitano, na strežnik ne pride.

```powershell
git status --short
```

Mora biti **prazno**. Če ni, preglej spremembe in jih commitaj (točka 1.4) ali zavrzi — to je tvoja
odločitev, ne agentova (AGENTS.md §4.2).

- [ ] **1.2 Testi so zeleni.** `dotnet test` sam ni dokaz — konzolne testne projekte požene samo ta skripta.

```powershell
.\scripts\run_tests.ps1
```

Izhodna koda mora biti **0**. Če pade, se ustavi; na TEST ne prenašamo rdečega stanja.

- [ ] **1.3 Migracijska sled na DEV se ujema z datotekami.**

```powershell
cd PIM_Solution
dotnet run --project src\PIM.Migrator -- --verify
dotnet run --project src\PIM.Migrator -- --show-migrations
cd ..
```

Mora pisati `Preverjanje F0–F10 baze je uspešno.` in v izpisu zadnjih treh migracij mora biti prva
`150_BusinessThresholdsStockExportPriceSheet.sql`. Če `--verify` javi *»Migracijska sled za NNN
manjka ali ne ustreza vsebini skripte«*, je bila že uporabljena migracija spremenjena — tega ne
prenašaj, dokler ni razčiščeno.

- [ ] **1.4 Commit.** Če je 1.1 pokazal spremembe:

```powershell
git add -A
git commit -m "prenos: stanje za TEST, migracija 150"
```

- [ ] **1.5 Push veje.** `git push` je po AGENTS.md §4.5 človekova odločitev — zato ga narediš ti:

```powershell
git push origin feature/izhodi-erp-01-saop-polji
git log -1 --format='%H %s'
```

Zapiši si izpisani hash — na strežniku preveriš, da si dobil isto.

- [ ] **1.6 Če strežnik nima dostopa do Gita** — namesto 1.5 naredi arhiv, ki nosi celo zgodovino:

```powershell
git bundle create C:\Prenos\NoviPIM.bundle --all
Get-FileHash C:\Prenos\NoviPIM.bundle -Algorithm SHA256
```

Bundle prenesi na strežnik skupaj z izpisanim SHA-256 (drug kanal). Alternativa je navaden zip
delovne mape **brez** `appsettings.Local.json`, `logs\`, `izvoz\`, `bin\` in `obj\` — a bundle je
boljši, ker ohrani commite in kasnejši `git pull` deluje.

- [ ] **1.7 (samo za možnost 3b) Varnostna kopija baze DEV.** V SSMS ali `sqlcmd` proti `localhost\MSSQLSERVER3`:

```sql
BACKUP DATABASE [PIM]
TO DISK = N'C:\Prenos\PIM_dev_20260903.bak'
WITH COPY_ONLY, COMPRESSION, CHECKSUM, STATS = 5,
     NAME = N'PIM dev pred prenosom na TEST';

RESTORE VERIFYONLY FROM DISK = N'C:\Prenos\PIM_dev_20260903.bak' WITH CHECKSUM;
```

`COPY_ONLY` pomeni, da kopija ne prekine verige rednih kopij. Isti vzorec je v
`PIM_Solution\deploy\Backup-PIM.sql`. Datoteko prenesi na strežnik (nekaj GB — USB ali omrežna mapa).

---

## 2. Na strežniku — predpogoji, koda, skrivnosti

- [ ] **2.1 Predpogoji.** Preveri, kaj je že tam:

```powershell
dotnet --version; git --version; pwsh --version; sqlcmd -?
```

| Kaj | Mora biti | Če manjka |
|---|---|---|
| .NET SDK | `10.0.x` (SDK, ne samo Runtime) | `PRENOS_NA_SLUZBENI_RACUNALNIK.md` korak 1.2 |
| PowerShell | `7.x` | korak 1.3 tam |
| Git | `2.x` | korak 1.4 tam (ali bundle iz 1.6) |
| `sqlcmd` ali SSMS | dostop do instance TEST | SSMS z Microsoftove strani |
| ASP.NET Core Hosting Bundle 10 | samo za IIS (korak 6) | Microsoft, »Hosting Bundle« |
| VPN / FortiClient | dostop do SAOP `192.168.178.12:81` (`:82` je TEST ERP) | omrežni skrbnik |

Preveri dostop do ERP-ja, sicer bo vse razen SAOP delalo in boš iskal napako na napačnem mestu:

```powershell
Test-NetConnection -ComputerName 192.168.178.12 -Port 81
```

`TcpTestSucceeded : True`. Če `False`, vklopi VPN in ponovi.

- [ ] **2.2 Klon repozitorija.** Predlagana mapa `C:\PIM\NoviPIM` (ista kot v obstoječem navodilu).

```powershell
mkdir C:\PIM
cd C:\PIM
git clone <NASLOV-REPOZITORIJA> NoviPIM
cd NoviPIM
git checkout feature/izhodi-erp-01-saop-polji
git log -1 --format='%H %s'
```

Hash mora biti **isti** kot v koraku 1.5. Z bundlom namesto `git clone <naslov>`:

```powershell
Get-FileHash C:\Prenos\NoviPIM.bundle -Algorithm SHA256   # primerjaj z 1.6
git clone C:\Prenos\NoviPIM.bundle NoviPIM
```

- [ ] **2.3 Build.**

```powershell
dotnet build C:\PIM\NoviPIM\PIM_Solution\PIM.sln
```

`Build succeeded.` z `0 Error(s)`.

- [ ] **2.4 `appsettings.Local.json` v korenu** `C:\PIM\NoviPIM\` (ne v `PIM_Solution\` — tam je
  druga datoteka z istim imenom, ki se je ne dotikaj). Ustvari jo po koraku 3.1 obstoječega navodila
  (Beležnica, ime v narekovajih, UTF-8). Struktura — **vrednosti so nadomestki, vpiši prave**:

```json
{
  "ConnectionStrings": {
    "Pim": "Server=IME-STREZNIKA\\INSTANCA;Database=PIM_TEST;Integrated Security=True;Encrypt=True;TrustServerCertificate=True"
  },
  "Saop": {
    "BaseUrl": "https://192.168.178.12:81/iCenterAPI/",
    "Username": "<SAOP-UPORABNIK>",
    "Password": "<SAOP-GESLO>",
    "TimeoutSeconds": 120,
    "PageSize": 5000,
    "MaxPagesPerEndpoint": 0,
    "IncludeNonActiveItems": false,
    "AcceptUntrustedCertificate": true,
    "LookbackDays": 0,
    "DelayAfterSuccessMilliseconds": 0,
    "RetryMaxExtraAttempts": 0,
    "RetryBaseDelayMilliseconds": 0,
    "PriceListIds": [],
    "Organizations": [
      { "Id": 1, "Name": "<IME>", "SourceCode": "<SAOP_KODA>", "IsActive": true },
      { "Id": 2, "Name": "<IME>", "SourceCode": "<SAOP_KODA>", "IsActive": true },
      { "Id": 3, "Name": "<IME>", "SourceCode": "<SAOP_KODA>", "IsActive": true },
      { "Id": 4, "Name": "<IME>", "SourceCode": "<SAOP_KODA>", "IsActive": true }
    ]
  },
  "Fetch": {
    "BT_STOCK": "<URL-BRAYTRON-ZALOGA>",
    "BT_XML": "<URL-BRAYTRON-KATALOG>",
    "NW_STOCK": {
      "BaseUri": "ftp://<FTP-STREZNIK>",
      "UserName": "<FTP-UPORABNIK>",
      "Password": "<FTP-GESLO>",
      "RemoteDirectory": "/",
      "RemoteFileName": "NOWODVORSKI.csv",
      "UsePassive": true
    }
  }
}
```

Prave vrednosti (številske nastavitve SAOP, imena in `SourceCode` podjetij, naslovi dobaviteljev)
prepiši iz iste datoteke na razvojnem računalniku `C:\Users\david\Desktop\PIM\NoviPIM\appsettings.Local.json`.
**Edino, kar se spremeni, je `ConnectionStrings:Pim`** — kaže na TEST bazo. Če aplikacijski bazen
IIS ali servisni račun ne bosta imela Windows dostopa do SQL, uporabi SQL prijavo:
`Server=…;Database=PIM_TEST;User ID=<SQL-UPORABNIK>;Password=<SQL-GESLO>;Encrypt=True;TrustServerCertificate=True`.

Ime baze `PIM_TEST` je predlog — uporabi tisto, ki jo dobiš od skrbnika strežnika, a **ne** imena
produkcijske baze.

- [ ] **2.5 `PIM_CONNECTION_STRING`.** Migrator in workerji berejo povezavo najprej iz okoljske
  spremenljivke, šele nato iz `appsettings.Local.json`; `PIM.AlertDispatcher` jo bere **samo** iz
  okolja. Za ročno delo v seji zadostuje:

```powershell
$env:PIM_CONNECTION_STRING = (Get-Content C:\PIM\NoviPIM\appsettings.Local.json -Raw | ConvertFrom-Json).ConnectionStrings.Pim
```

Za opravila (korak 5) in IIS (korak 6) jo nastavi **strojno** kot skrbnik, da jo vidi tudi seja
servisnega računa — vrednost vpiši ročno, ne iz izpisa:

```powershell
[Environment]::SetEnvironmentVariable('PIM_CONNECTION_STRING', 'Server=…;Database=PIM_TEST;…', 'Machine')
```

Po tem odpri novo okno PowerShell, sicer spremenljivke še ne vidi.

---

## 3. Baza TEST

- [ ] **3.1 Prazna baza.** Migrator z `--create-database` bazo ustvari sam, če je ni (potrebuje
  pravico `CREATE DATABASE`). Če jo ustvari skrbnik strežnika, naj bo prazna, brez tabel.

- [ ] **3.2 Prvi zagon migratorja** — uporabi vse migracije `001…150`:

```powershell
cd C:\PIM\NoviPIM\PIM_Solution
dotnet run --project src\PIM.Migrator -- --create-database
```

Pričakovano: `Baza PIM_TEST je pripravljena.`, nato `Uporabljena migracija: 001_…` do `150_…` in
`Migracije so uspešno uporabljene.`

> ### Znana ovira: migracija 070 na popolnoma prazni bazi pade
>
> Preizkušeno 31. 8. 2026. Izpis:
>
> ```
> Uporabljena migracija: 069_SupplierConnectorsForAllOrganizations.sql
> Napaka 52701: Razpored za dobaviteljev XML ni omogocen pri vseh stirih podjetjih.
> ```
>
> **Zakaj.** `070` prepiše intervale iz vrstice `GENERIC_XML` podjetja 2 v `ops.ScheduleProfile` in
> vstavi vrstice za podjetja 1, 3 in 4, potem preveri, da so **štiri** omogočene. Vrstica podjetja 2 je
> na razvojnem računalniku nastala **ročno** in je nobena migracija ne ustvari — na prazni bazi so po
> `070` tri, preverba vrže 52701.
>
> **Posledica.** Migrator izvede vse migracije v **eni transakciji** (`PIM.Migrator/Program.cs`,
> `BeginTransactionAsync` … `RollbackAsync`). Ob napaki razveljavi vse — baza ostane prazna, tudi
> `dbo.SchemaMigration`. Nič ni pokvarjeno, a nič ni narejeno.
>
> **Dve možnosti — izbereš ti:**
>
> **(a) Popravek `070`** — ena vrstica: `USING (VALUES (1), (2), (3), (4))` namesto `(1), (3), (4)`.
> To je **izjema od pravila »samo dodajaj«** (že uporabljene migracije se ne spreminjajo), zato jo
> mora odobriti lastnik. Ker migrator ob vsakem zagonu primerja SHA-256 datoteke s shranjenim hashem,
> bi razvojna baza po popravku javila *»Vsebina že uporabljene migracije 070 … je bila spremenjena«*;
> zato je treba po popravku na DEV ročno posodobiti `dbo.SchemaMigration.ScriptHash` za `070` (novi
> hash izpiše `Get-FileHash -Algorithm SHA256` nad datoteko, zapisan z malimi črkami). Čisto, a
> zahteva poseg na dveh mestih in en commit.
>
> **(b) Obnovi varnostno kopijo DEV na TEST kot izhodišče** — **priporočeno zaradi hitrosti.** Baza
> DEV je že prešla vseh 150 migracij in ima 196.531 artiklov, zato prvi zajem SAOP ni nujen za
> preizkus. Slabost: na TEST pridejo tudi ročno nastavljene vrstice in razvojni uporabniki (glej 3.5)
> — pregledaš in popraviš jih z SQL spodaj.

- [ ] **3.3 Možnost (b): obnovitev kopije na TEST.** Kopijo iz 1.7 imaš na strežniku, npr.
  `D:\Prenos\PIM_dev_20260903.bak`. Najprej poglej logična imena datotek v kopiji:

```sql
RESTORE FILELISTONLY FROM DISK = N'D:\Prenos\PIM_dev_20260903.bak';
```

Stolpec `LogicalName` (običajno `PIM` in `PIM_log`) uporabi v `MOVE`. Poti prilagodi mapam
podatkov na strežniku:

```sql
USE [master];
RESTORE DATABASE [PIM_TEST]
FROM DISK = N'D:\Prenos\PIM_dev_20260903.bak'
WITH MOVE N'PIM'     TO N'D:\SQLData\PIM_TEST.mdf',
     MOVE N'PIM_log' TO N'D:\SQLLog\PIM_TEST_log.ldf',
     CHECKSUM, STATS = 5, RECOVERY;
```

Potem poženi migrator — uporabi samo, kar je novejše od kopije (danes nič), sicer vse preskoči:

```powershell
cd C:\PIM\NoviPIM\PIM_Solution
dotnet run --project src\PIM.Migrator
```

Mora pisati samo `Preskočena že uporabljena migracija: …` za vseh 150 in na koncu `Migracije so
uspešno uporabljene.`

- [ ] **3.4 Drugi zagon in `--verify`** (pri obeh možnostih):

```powershell
dotnet run --project src\PIM.Migrator            # nobena »Uporabljena«, samo »Preskočena«
dotnet run --project src\PIM.Migrator -- --verify
```

Zadnja vrstica: `Preverjanje F0–F10 baze je uspešno.` Če drugi zagon karkoli »uporabi«, se ustavi.

- [ ] **3.5 Kaj pride z migracijami in kaj je bilo na DEV nastavljeno ročno.**

Migracije **145–150** zasejejo te registre (pridejo same, v obeh možnostih):

| Migracija | Kar nastane |
|---|---|
| 145 | `stock.SaopProviderProfile`: podjetje 3 `SAOP_REGISTERED_VIEW` dobi `RegisteredViewId = 16c34ea5-…`, `Enabled = 1`, `Priority = 5`; nove kolicinske stolpce na `stock.Position` |
| 146 | `out.ExportStockSource` (BASE / ADD / SUPPLIER za podjetji 2 in 3), profil `MAGENTO_STOCK_PRICES`, `out.ExportProfile.RequireWebValid`, `val.ValidationProfile.CategoryTreeCode` |
| 147 | `canon.CategoryAttributeSet`, obseg na `val.FieldRequirement` |
| 148 | popravek enoličnosti iz 147 |
| 149 | `pim.TitleRule` + `pim.ApplyTitleRules`; privzeto pravilo je **izklopljeno** (`IsActive = 0`) |
| 150 | `pim.CheckThreshold`: vrstica `FAKTOR_MARZE = 2.0` (privzeto za vsa podjetja); `out.GetStockExportRows`; `intranet.GetPriceListSheet` |

**Ročno nastavljeno na DEV** — z migracijami ne pride (možnost a) oziroma pride v stanju, kot je na
DEV (možnost b). Preveri in odloči:

| Kaj | Stanje na DEV | Kaj narediti na TEST |
|---|---|---|
| `ops.ScheduleProfile` `SAOP_STOCK` | 106 ga zaseje omogočenega; 28. 8. samodejno izklopljen po 5 napakah, 2. 9. **ročno** vklopljen nazaj s ponastavitvijo števca | odloči, ali naj živi klic na ERP teče iz TEST; vklop na `/sistem/urniki` |
| `dbo.IntegrationProfile` `SAOP_PRODUCT` | **ročno** odprt za vsa štiri podjetja, naslov TEST ERP (`:82`), `ManualApproval`; migracije tu ne zasejejo ničesar (namenoma — okoljska nastavitev) | pri (a) prazno; pri (b) preveri naslov, po potrebi izklopi: `UPDATE dbo.IntegrationProfile SET IsEnabled = 0 WHERE TargetKind = N'SAOP_PRODUCT';` |
| `ops.AlertRecipientConfig` | en prejemnik (`ADMIN`, e-pošta, `Critical`, vsa podjetja), vpisan ročno 2. 9. | vpiši prave prejemnike na `/sistem`; brez tega alarmi nastajajo, a ne odidejo |
| `sec.LocalUser` in gesla | razvojni računi | pri (a): `dotnet run --project src\PIM.Migrator -- --ustvari-admina <ime>`; pri (b): **zamenjaj gesla** na `/sistem/uporabniki` in odstrani nepotrebne račune |
| SMTP (`PIM_SMTP_*`, `PIM_ALERT_*`) | ni nastavljeno, pošta ne odide | okoljske spremenljivke strežnika (korak 5) — poverilnice so tvoje |

SQL za pregled teh tabel na TEST:

```sql
SELECT OrganizationId, Pipeline, IsEnabled, IntervalSeconds, UpdatedBy, NextScheduledUtc
FROM ops.ScheduleProfile ORDER BY Pipeline, OrganizationId;

SELECT OrganizationId, TargetKind, IsEnabled, BaseUrl, ApprovalMode
FROM dbo.IntegrationProfile ORDER BY TargetKind, OrganizationId;

SELECT * FROM ops.AlertRecipientConfig;

SELECT UserName, DisplayName, AuthSource, IsActive FROM sec.LocalUser;

SELECT OrganizationId, ProfileCode, ProviderKind, Priority, Enabled, RegisteredViewId
FROM stock.SaopProviderProfile ORDER BY OrganizationId, Priority;

SELECT OrganizationId, StockOrganizationId, SourceCode, Contribution, WarehouseLabel
FROM out.ExportStockSource ORDER BY OrganizationId, SortOrder;

SELECT CheckCode, OrganizationId, Threshold, IsActive FROM pim.CheckThreshold;
SELECT RuleCode, CategoryTreeCode, LanguageCode, IsActive FROM pim.TitleRule;
```

---

## 4. Prvi zagon

- [ ] **4.1 Intranet lokalno (Kestrel), preden gre v IIS.** Prvo okno:

```powershell
cd C:\PIM\NoviPIM
$env:ASPNETCORE_URLS = 'http://127.0.0.1:5199'
dotnet run --project PIM_Solution\src\PIM.Intranet
```

Drugo okno:

```powershell
Invoke-WebRequest http://127.0.0.1:5199/health -UseBasicParsing | Select-Object StatusCode
Invoke-WebRequest http://127.0.0.1:5199/PIM/prijava -UseBasicParsing | Select-Object StatusCode
```

Oba **200**. Aplikacija sprejme tako `/prijava` kot `/PIM/prijava` (`UsePathBase("/PIM")` v
`Program.cs`) — druga pot je tista, ki jo bo uporabljal IIS. Prijavi se v brskalniku z računom iz 3.5.
Brez `ASPNETCORE_URLS` posluša na `localhost:5091` (iz `launchSettings.json`) — tudi to je v redu.

- [ ] **4.2 Prvi zajem SAOP (katalog).** Živi klic — `PIM_SAOP_MODE=Live` je privolitev v klic na ERP.

```powershell
cd C:\PIM\NoviPIM\PIM_Solution
$env:PIM_SAOP_MODE = 'Live'
dotnet run --project workers\PIM.KatalogWorker -- --full --max-parallel 4
```

Traja **ure** (196.531 artiklov na DEV). Pri možnosti (b) ga lahko preskočiš in pustiš nočnemu toku
(delta). Enakovredno naredi cel tok skripta, ki jo bo poganjalo opravilo:

```powershell
cd C:\PIM\NoviPIM
.\scripts\Nocno-vse.ps1 -ZalogaIzSaop
```

Koraki po vrsti: SAOP katalog → prevzem in XML dobaviteljev → spletni nazivi → preslikava
zaostanka → zaloge dobaviteljev → SAOP zaloga → validacija in objava → izvoz. Dnevnik:
`logs\nocno-*.log`. Konec: `padlih korakov: 0`.

- [ ] **4.3 Zaloga (dobavitelji in SAOP), isto kot petminutni cikel:**

```powershell
.\scripts\Zaloga-cikel.ps1 -Kaj Dobavitelji
.\scripts\Zaloga-cikel.ps1 -Kaj Saop
```

Vsak konča z `Zalogovni cikel koncan; padlih korakov: 0.` Pri Braytronu je *»Razmik dobavitelja
še teče«* pravilno (en prenos na 180 min). `-Kaj Vse` požene oboje in še izvoz
`MAGENTO_STOCK_PRICES`.

- [ ] **4.4 Validacija in objava** (če nisi pognal `Nocno-vse.ps1`), za vsako podjetje:

```sql
EXEC val.RunValidation @OrganizationId = 3;
EXEC val.Promote @OrganizationId = 3;
```

- [ ] **4.5 Izvoz.** Poln spletni izvoz in hitri profil cen/zaloge za podjetje 3:

```powershell
cd C:\PIM\NoviPIM\PIM_Solution
dotnet run --project workers\PIM.B2bWorker -- --export-magento --organization-id 3 --output-dir C:\PIM\NoviPIM\izvoz\magento\3
dotnet run --project workers\PIM.B2bWorker -- --export-profile MAGENTO_STOCK_PRICES --organization-id 3 --output-dir C:\PIM\NoviPIM\izvoz\magento\3 --file-name magento-stock-prices.csv
```

- [ ] **4.6 Kontrolne številke iz DEV (2. 9. 2026)** — ne pričakuj istih do artikla, a red velikosti mora biti ta:

```sql
SELECT COUNT(*) FROM canon.Product;                          -- DEV: 196.531 (17.425 / 111.068 / 28.901 / 39.137 po podjetjih)
SELECT OrganizationId, COUNT(*) FROM stock.Position GROUP BY OrganizationId;  -- SAOP zaloga: 16 / 8.734 / 7.016 / 3.113 zapisov
```

Spletni izvoz podjetja 3 (`--export-magento`, čisti podatki: objavljen + spletna stran + veljaven)
je imel na DEV **2.368 vrstic**, podjetja 2 **1.957**. Če je vrstic 40.000+, izvoz ne upošteva
pravila iz 146 — preveri, da bereš pravo bazo.

---

## 5. Načrtovana opravila

Trije ritmi, isti kot na DEV: **PIM zaloga** (5 min), **PIM nadzor** (5 min, zamaknjen za 2 min),
**PIM nočni tok** (02:30, `-ZalogaIzSaop`). Ritem mora ustrezati `ops.ScheduleProfile`, sicer
worker zavrne zagon z napako 51100.

- [ ] **5.1 Registracija** (kot skrbnik; `Namesti-nocno-opravilo.ps1` je starejša varianta samo za nočni tok):

```powershell
cd C:\PIM\NoviPIM
.\scripts\Namesti-opravila.ps1 -WhatIf     # predogled
.\scripts\Namesti-opravila.ps1
Get-ScheduledTask -TaskName 'PIM *' | Get-ScheduledTaskInfo | Select-Object TaskName, NextRunTime, LastTaskResult
```

> ### Na strežniku to tako, kot je, NE bo teklo
>
> `Namesti-opravila.ps1` registrira naloge z `-User $env:USERNAME -RunLevel Limited`, kar Windows
> zapiše kot `LogonType = InteractiveToken` — *»Run only when user is logged on«*. Na razvojnem
> prenosniku je to v redu (nekdo je vedno prijavljen; `Tiho.vbs` skrije okno). Na strežniku brez
> prijavljene seje se naloga **ne sproži in tega ne javi** — izmerjeno in zapisano v
> [`NACRT_RAZPOREJEVALNIK.md`](NACRT_RAZPOREJEVALNIK.md) §1.
>
> **Kaj narediti (sistemska nastavitev, AGENTS.md §4.7 — narediš ti):** po registraciji vsako
> od treh nalog v Task Schedulerju odpri → **Properties → General** → izberi **servisni račun**
> (namenski, ne LocalSystem) → **Run whether user is logged on or not** → shrani z geslom računa.
> Servisni račun rabi pravico *»Log on as a batch job«*, branje/izvajanje nad `C:\PIM\NoviPIM`,
> pisanje v `logs\`, `izvoz\`, `PIM_Solution\data\` ter dostop do baze TEST. Isto lahko narediš z
> `Set-ScheduledTask -TaskName 'PIM zaloga' -Principal (New-ScheduledTaskPrincipal -UserId 'DOMENA\svc_pim' -LogonType Password -RunLevel Limited)`.
> `Tiho.vbs` v seji 0 ni potreben, a ne škodi.
>
> Trajna rešitev — ena Windows storitev **`PIM.Scheduler`**, ki bere urnik iz baze in poganja
> zgrajene `.exe` namesto `dotnet run` — je **načrtovana, ne zgrajena** (`NACRT_RAZPOREJEVALNIK.md`).
> Do takrat velja zgornji obvoz.

- [ ] **5.2 Okolje za servisni račun.** Naloge dobijo strojne spremenljivke iz 2.5. Če naj pošta
  odide, dodaj še `PIM_ALERT_DELIVERY_ENABLED`, `PIM_ALERT_EMAIL_ENABLED`, `PIM_SMTP_HOST`,
  `PIM_SMTP_PORT`, `PIM_SMTP_STARTTLS`, `PIM_SMTP_USERNAME`, `PIM_SMTP_PASSWORD`, `PIM_SMTP_FROM`
  (strojno, kot skrbnik).

- [ ] **5.3 Po prvem tiku** (počakaj 10 minut): `LastTaskResult` mora biti **0** in v `logs\` morata
  nastati `zaloga-YYYY-MM-DD.log` in `nadzor-YYYY-MM-DD.log`. `0x800710E0` pomeni, da prejšnja
  instanca še teče (meja izvajanja jo ubije po 30 oz. 15 min).

Odstranitev: `.\scripts\Namesti-opravila.ps1 -Odstrani`.

---

## 6. IIS objava intraneta (sistemska nastavitev — narediš ti)

Obstaja `PIM_Solution\deploy\Publish-Intranet.ps1`: naredi `dotnet publish` (win-x64,
self-contained), ohrani `appsettings.Local.json` v ciljni mapi, postavi `app_offline.htm`, zamenja
mapo atomsko, preveri `/health` in ob napaki povrne prejšnjo mapo. Predpogoj: spletno mesto v IIS
**že obstaja**.

- [ ] **6.1 IIS enkratna postavitev:** ASP.NET Core Hosting Bundle 10; aplikacijski bazen `PIM`
  (**No Managed Code**, identiteta = servisni račun ali `ApplicationPoolIdentity` z dostopom do baze);
  spletno mesto oziroma aplikacija pod poti **`/PIM`** (koda ima `UsePathBase("/PIM")`), fizična mapa
  npr. `C:\PIM\Intranet`. Da intranet ne ugasne po 20 minutah brez zahtevka:

```powershell
Import-Module WebAdministration
Set-ItemProperty 'IIS:\AppPools\PIM' -Name startMode -Value 'AlwaysRunning'
Set-ItemProperty 'IIS:\AppPools\PIM' -Name processModel.idleTimeout -Value ([TimeSpan]::Zero)
Set-ItemProperty 'IIS:\AppPools\PIM' -Name recycling.periodicRestart.time -Value ([TimeSpan]::Zero)
```

- [ ] **6.2 Predogled, potem objava:**

```powershell
cd C:\PIM\NoviPIM\PIM_Solution
pwsh -File .\deploy\Publish-Intranet.ps1 -Destination C:\PIM\Intranet -SiteName PIM -HealthUrl http://localhost/PIM/health -DryRun
pwsh -File .\deploy\Publish-Intranet.ps1 -Destination C:\PIM\Intranet -SiteName PIM -HealthUrl http://localhost/PIM/health
```

Ročna alternativa: `dotnet publish src\PIM.Intranet -c Release -r win-x64 --self-contained true -o C:\PIM\Intranet`,
v `C:\PIM\Intranet` daj kopijo `appsettings.Local.json`, nato `iisreset`. Povezovalni niz lahko
namesto datoteke pride iz `PIM_CONNECTION_STRING` (strojno) — potem datoteke v mapi objave ni.

- [ ] **6.3 Preveri:** `http://<streznik>/PIM/health` → 200, `http://<streznik>/PIM/prijava` →
  prijavna stran. Domenska prijava dela samo, če je strežnik v isti domeni; lokalni računi vedno.

---

## 7. Preverjanje po prenosu

Vse na bazi TEST. Ob vsaki poizvedbi piše, kaj mora biti.

```sql
-- 7.1 Migracijska sled: prva vrstica 150_BusinessThresholdsStockExportPriceSheet.sql
SELECT TOP (3) MigrationId, AppliedUtc FROM dbo.SchemaMigration ORDER BY AppliedUtc DESC, MigrationId DESC;
SELECT COUNT(*) FROM dbo.SchemaMigration;                    -- 150

-- 7.2 Urniki: GENERIC_XML, SAOP_PRODUCTS, SAOP_STOCK, STOCK_FILE, SOURCE_FETCH, WATCHDOG, ALERT_DISPATCH
--     za štiri podjetja; IsEnabled po tvoji odločitvi iz 3.5; UpdatedBy ne sme biti
--     'samodejni izklop po napakah' pri postopku, ki naj teče.
SELECT Pipeline, OrganizationId, IsEnabled, IntervalSeconds, UpdatedBy, NextScheduledUtc
FROM ops.ScheduleProfile ORDER BY Pipeline, OrganizationId;

-- 7.3 Vir zaloge SAOP: podjetje 3 SAOP_REGISTERED_VIEW Enabled=1 Priority=5 z RegisteredViewId;
--     podjetje 2 GetStocks nad skladiščem 0000001.
SELECT OrganizationId, ProfileCode, ProviderKind, Priority, Enabled, RegisteredViewId
FROM stock.SaopProviderProfile ORDER BY OrganizationId, Priority;

-- 7.4 Sestava zaloge v izvozu: za podjetje 3 BASE (lastna) + ADD (podjetje 2, Brnčičeva 13) + SUPPLIER
SELECT OrganizationId, StockOrganizationId, SourceCode, Contribution, WarehouseLabel
FROM out.ExportStockSource ORDER BY OrganizationId, SortOrder;

-- 7.5 Zdravje: po prvem ciklu vsi postopki Healthy, LastHeartbeatUtc mlajši od 10 minut
SELECT OrganizationId, Pipeline, Status, LastHeartbeatUtc, LastError
FROM ops.IntegrationHealth ORDER BY Pipeline, OrganizationId;

-- 7.6 Sled izvajanja (144): vsak zagon ena vrstica; nič večno 'Running'
SELECT TOP (20) Pipeline, OrganizationId, Status, StartedUtc, EndedUtc, RowsRead, RowsFailed, TriggeredBy
FROM ops.PipelineRun ORDER BY StartedUtc DESC;

-- 7.7 Odprti alarmi: po zdravem prvem dnevu prazno
SELECT AlertCode, Severity, OrganizationId, Pipeline, Message, CreatedUtc FROM ops.Alert WHERE ResolvedUtc IS NULL;
```

In v intranetu: **Sistem → Urniki obdelav** (nič izklopljenega, kar naj teče), **Zajem → Teki**
(zadnji teki uspešni), **Izdelki** (vrstice so), **Sistem → Dnevnik napak** (prazen ali razumljiv).

Zapiši si brez skrivnosti: hash commita, izid obeh zagonov migratorja in `--verify`, HTTP status
`/health` (Kestrel in IIS), `LastTaskResult` treh opravil, števci iz 4.6.

---

## 8. Vrnitev nazaj (rollback)

Migracije se ne »odvijajo« — vračanje baze je vedno **obnovitev kopije**. Zato pred vsakim
naslednjim prenosom na TEST najprej:

```sql
BACKUP DATABASE [PIM_TEST] TO DISK = N'D:\Backups\PIM_TEST_pred_prenosom_YYYYMMDD.bak'
WITH COPY_ONLY, COMPRESSION, CHECKSUM, STATS = 5;
RESTORE VERIFYONLY FROM DISK = N'D:\Backups\PIM_TEST_pred_prenosom_YYYYMMDD.bak' WITH CHECKSUM;
```

Če gre kaj narobe:

```powershell
# 1. ustavi opravila in intranet, da nihče ne piše v bazo
Get-ScheduledTask -TaskName 'PIM *' | Disable-ScheduledTask
Stop-WebAppPool -Name PIM
```

```sql
-- 2. obnovi bazo
USE [master];
ALTER DATABASE [PIM_TEST] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
RESTORE DATABASE [PIM_TEST] FROM DISK = N'D:\Backups\PIM_TEST_pred_prenosom_YYYYMMDD.bak'
WITH REPLACE, CHECKSUM, STATS = 5, RECOVERY;
ALTER DATABASE [PIM_TEST] SET MULTI_USER;
```

```powershell
# 3. koda nazaj na prejšnji commit (hash iz zapisa v 7), potem build
cd C:\PIM\NoviPIM
git checkout <PREJSNJI-HASH>
dotnet build PIM_Solution\PIM.sln

# 4. intranet: Publish-Intranet.ps1 ob padlem /health sam vrne mapo iz C:\PIM\Intranet.backup;
#    ročno: zamenjaj C:\PIM\Intranet s C:\PIM\Intranet.backup, potem
Start-WebAppPool -Name PIM
Get-ScheduledTask -TaskName 'PIM *' | Enable-ScheduledTask
```

Preveri s poizvedbo 7.1, da `dbo.SchemaMigration` kaže stanje, ki ustreza obnovljeni kodi — migrator
ob neskladju hasha ali manjkajoče sledi zavrne zagon, kar je varovalka, ne napaka.

---

## Povzetek — vsi ukazi na enem mestu

```powershell
# DEV
cd C:\Users\david\Desktop\PIM\NoviPIM
git status --short ; .\scripts\run_tests.ps1
cd PIM_Solution ; dotnet run --project src\PIM.Migrator -- --verify ; cd ..
git push origin feature/izhodi-erp-01-saop-polji            # ali: git bundle create ... --all
# SQL: BACKUP DATABASE [PIM] ... WITH COPY_ONLY (za možnost 3b)

# STREŽNIK
Test-NetConnection 192.168.178.12 -Port 81
mkdir C:\PIM ; cd C:\PIM ; git clone <naslov> NoviPIM ; cd NoviPIM ; git checkout feature/izhodi-erp-01-saop-polji
dotnet build PIM_Solution\PIM.sln
# -> C:\PIM\NoviPIM\appsettings.Local.json (ConnectionStrings:Pim = TEST), PIM_CONNECTION_STRING strojno
# SQL (3b): RESTORE DATABASE [PIM_TEST] ... WITH MOVE ...
cd PIM_Solution
dotnet run --project src\PIM.Migrator -- --create-database    # (3a) vse 001-150 | (3b) vse preskočene
dotnet run --project src\PIM.Migrator                          # nobene »Uporabljena«
dotnet run --project src\PIM.Migrator -- --verify
dotnet run --project src\PIM.Migrator -- --ustvari-admina <ime>   # samo 3a
cd .. ; $env:ASPNETCORE_URLS='http://127.0.0.1:5199' ; dotnet run --project PIM_Solution\src\PIM.Intranet
.\scripts\Zaloga-cikel.ps1 -Kaj Dobavitelji ; .\scripts\Nocno-vse.ps1 -ZalogaIzSaop
.\scripts\Namesti-opravila.ps1        # potem: servisni račun, »Run whether user is logged on or not«
pwsh -File PIM_Solution\deploy\Publish-Intranet.ps1 -Destination C:\PIM\Intranet -SiteName PIM -HealthUrl http://localhost/PIM/health
```
