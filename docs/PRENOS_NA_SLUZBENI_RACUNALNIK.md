# Prenos PIM na službeni računalnik

Cilj: na drugem računalniku pognati **cel sistem s prazno bazo**, ki se sama napolni iz virov,
in na njem preizkušati napake.

Nadomešča [`LAPTOP_INSTALL.md`](LAPTOP_INSTALL.md), ki je nastal pred workerji, urniki in
prevzemnikom datotek in navaja .NET 8 namesto .NET 10.

---

## Najprej to: baze ni treba prenašati

Ta korak ljudje najpogosteje naredijo napačno, zato stoji na vrhu.

**Ne delaj varnostne kopije in ne obnavljaj je.** Celotno ogrodje baze — 120 migracij, vse tabele,
pogledi, procedure **in vse nastavitve** — nastane iz datotek v `PIM_Solution\sql\migrations`.
Te so v Gitu.

Iz migracij pridejo tudi vsi šifranti, ki jih sistem potrebuje za delo:

| Kaj | Od kod |
|---|---|
| Štiri podjetja (DEMO, IQLighting, Vidadria, Ediito) | migracija 002 |
| Konektorji virov (SAOP, NW, BT, XLSX) po podjetjih | migracija 069 |
| Validacijski profili in zahteve polj | migracije 006, 047 |
| Urniki obdelav | migracije 106, 107, 112, 118 |
| Register prevzemov datotek | migraciji 099, 114 |

**Prazno ostane samo tisto, kar pride iz virov:** artikli, besedila, lastnosti, kategorije,
mediji, cene, zaloga, stranke. Točno to si želel — ogrodje brez vsebine.

Edina izjema so **prevodi slovarja**, ki niso ne shema ne vir, ampak delo človeka. Zanje obstaja
ločena skripta (korak 6).

---

## 1. Kaj mora biti na računalniku

| Kaj | Zakaj | Preveri z |
|---|---|---|
| **.NET 10 SDK** | prevajanje in zagon | `dotnet --version` → `10.0.x` |
| **SQL Server 2019+** | baza `PIM` | `sqlcmd -S .\IME -E -Q "SELECT @@VERSION"` |
| **PowerShell 7** | skripte in opravila | `pwsh --version` |
| **Git** | repozitorij | `git --version` |

Za spletni del prek IIS dodatno **ASP.NET Core Hosting Bundle 10.x**. Za prvo preizkušanje ga ne
rabiš — intranet lahko poženeš neposredno.

---

## 2. Repozitorij

```powershell
git clone <naslov-repozitorija> C:\PIM\NoviPIM
cd C:\PIM\NoviPIM
git checkout feature/intranet-i0-ia-bralni-moduli
```

Če Gita ni, prenesi mapo — a **brez** `bin`, `obj`, `data`, `logs` in `fixtures`. To so izpisi in
podatki, ne izvorna koda.

---

## 3. Skrivnosti: `appsettings.Local.json`

Ta datoteka **ni v Gitu** in nikoli ne sme biti. Ustvari jo v korenu (`C:\PIM\NoviPIM`) ročno.
Vrednosti prepiši s trenutnega računalnika — na strežnik jih prenesi po varni poti, ne po e-pošti.

```jsonc
{
  "ConnectionStrings": {
    "Pim": "Server=localhost\\IME_INSTANCE;Database=PIM;Integrated Security=True;Encrypt=True;TrustServerCertificate=True"
  },
  "Saop": {
    "BaseUrl": "https://<naslov-saop>/iCenterAPI/",
    "Username": "<uporabnik>",
    "Password": "<geslo>",
    "TimeoutSeconds": 120,
    "PageSize": 5000,
    "AcceptUntrustedCertificate": true,
    "Organizations": [ { "Id": 2, "IsActive": true } ]
  },
  "Fetch": {
    "BT_STOCK": "<naslov Braytronove zaloge>",
    "BT_XML": "<naslov Braytronovega kataloga>",
    "NW_STOCK": {
      "BaseUri": "ftp://<naslov>",
      "UserName": "<uporabnik>",
      "Password": "<geslo>",
      "RemoteDirectory": "/",
      "RemoteFileName": "NOWODVORSKI.csv",
      "UsePassive": true
    }
  }
}
```

> **Past, ki me je stala pol ure.** Pod `PIM_Solution\` stoji **druga** `appsettings.Local.json`,
> ki ima samo povezavo do baze. Workerji zdaj iščejo korensko (prepoznajo jo po `PIM_Solution\PIM.sln`),
> a če v podmapo vpišeš SAOP nastavitve, jih ne bo brala nobena koda. **Ureja se samo korenska.**

---

## 4. Baza

```powershell
cd C:\PIM\NoviPIM\PIM_Solution
dotnet run --project src\PIM.Migrator -- --create-database
dotnet run --project src\PIM.Migrator
dotnet run --project src\PIM.Migrator            # drugič: ne sme spremeniti ničesar
dotnet run --project src\PIM.Migrator -- --verify
```

Kaj mora pisati:

1. prvi zagon uporabi vseh ~120 migracij po vrsti,
2. drugi zagon izpiše samo *»Preskočena že uporabljena migracija«*,
3. `--verify` konča z *»Preverjanje F0–F10 baze je uspešno.«*

Če drugi zagon karkoli spremeni, je migracija napisana napačno — javi, ne nadaljuj.

---

## 5. Prvi skrbnik

Na prazni bazi ni nobenega uporabnika. Strani za uporabnike ne moreš odpreti, ker zahteva
prijavo — prijave pa ni brez računa. Zato zna račun ustvariti migrator:

```powershell
dotnet run --project src\PIM.Migrator -- --ustvari-admina david
```

Vpraša za prikazno ime in geslo (dvakrat, brez izpisa na zaslon). Geslo se **ne** podaja kot
argument — v zgodovini ukazov bi ostalo v čistopisu.

Nato se prijavi na `http://127.0.0.1:5091/prijava` in na `/sistem/uporabniki` vpiši ostale
uporabnike in njihove **domenske e-naslove**. Ti naslovi so hkrati prejemniki opozoril.

---

## 6. Prevodi slovarja (neobvezno, a priporočeno)

```powershell
sqlcmd -S localhost\IME_INSTANCE -d PIM -E -i ..\scripts\seed_prevodi_besede.sql
```

To ni migracija, ker so podatki in ne shema. Brez tega bo veliko vrednosti končalo med
manjkajočimi prevodi — kar je resnično stanje, samo bolj hrupno.

---

## 7. Dokaz, da stoji

```powershell
cd C:\PIM\NoviPIM
scripts\run_tests.ps1
```

Zeleno pomeni **izhodna koda 0**. To je edini merodajni test — `npm test` v tem projektu ne
pomeni nič.

Če build pade z `MSB3021` ali `MSB3027`, to **ni** napaka v kodi, ampak zaklep: intranet ali
worker teče in drži datoteko. Ustavi proces in ponovi.

---

## 8. Zaženi intranet

```powershell
dotnet run --project PIM_Solution\src\PIM.Intranet
```

Odpri **`http://127.0.0.1:5091`**. Vrata so v `Properties\launchSettings.json`; `AGENTS.md` še
navaja 5199, kar ne drži.

Vse strani bodo prazne. **To je pravilno** — vsebine še ni.

---

## 9. Napolni sistem

Zdaj pride tisto, kar si želel: vsebina se naloži sama.

### Najprej enkrat ročno, da vidiš izpise

```powershell
cd C:\PIM\NoviPIM

# 1. dobaviteljeve datoteke in zaloga (brez SAOP)
.\scripts\Zaloga-cikel.ps1 -Kaj Dobavitelji

# 2. zaloga iz SAOP — rabi dostop do ERP (VPN!)
.\scripts\Zaloga-cikel.ps1 -Kaj Saop

# 3. cel tok: katalog, XML, validacija, izvoz. Traja do nekaj ur.
.\scripts\Nocno-vse.ps1 -ZalogaIzSaop
```

Vsak korak izpiše, koliko zapisov je prebral in koliko jih je šlo v karanteno. Dnevniki so v
`logs\`.

### Potem prižgi samodejno

```powershell
.\scripts\Namesti-opravila.ps1
```

Registrira tri opravila:

| Opravilo | Ritem | Kaj dela |
|---|---|---|
| **PIM zaloga** | 5 min | SAOP, Nowodvorski FTP, Braytron XML |
| **PIM nadzor** | 5 min | zastale obdelave in razpošiljanje opozoril |
| **PIM nocni tok** | 02:30 | cel tok |

Odstraniš z `.\scripts\Namesti-opravila.ps1 -Odstrani`.

> Ritem posameznega postopka se **ne** ureja tu, ampak v aplikaciji na **`/sistem/urniki`**.
> Opravilo je samo ura, ki tiktaka; ali postopek sme teči in kdaj je na vrsti, je vrstica v bazi.

---

## 10. Kje iščeš napake

Za to je sistem narejen, zato po vrsti:

| Kaj hočeš vedeti | Kam pogledaš |
|---|---|
| Ali vhodi sploh tečejo | `/zajem` — zadnji poskus, zadnji uspeh, čaka, zavrnjeno |
| Kaj je padlo in zakaj | `/zajem/tezave` — karantena, mrtva pisma, sistemske napake |
| Kaj sistem ne razume | `/zajem/neujemanja`, `/kakovost/prevodi`, `/kakovost/kategorije` |
| Zakaj izdelek ni veljaven | `/kakovost` in `/kakovost/napake` po štirih nivojih |
| Ali je kaj ustavljeno | `/sistem/urniki` — stanje, zadnja napaka, naslednjič |
| Tehnične napake | `/sistem/napake` in `logs\` |

**Filter podjetja je povsod** in privzeto so prikazana **vsa** podjetja. Če vidiš samo DEMO,
gledaš staro različico.

### Kaj se zgodi, ko nekaj neha delati

Po **petih zaporednih napakah** se postopek sam izklopi in nastane opozorilo z imenom postopka,
podjetjem, številom napak in zadnjim sporočilom. Vidiš ga na `/sistem/urniki` in `/sistem/integracije`.
Ko vzrok odpraviš, ga tam vklopiš z enim gumbom.

To je namerno: ponavljanje klica, ki petkrat zapored ni uspel, ne prinese ničesar.

---

## 11. Kar na novem računalniku **ne** bo delalo

Povem naprej, da ne boš iskal napake tam, kje je ni:

1. **SAOP brez omrežnega dostopa.** Preveri s
   `Test-NetConnection -ComputerName <naslov-saop> -Port 81`. Če javi `False`, rabiš VPN ali
   pravilo na požarnem zidu. Brez tega SAOP katalog in zaloga ne bosta tekla — ostalo bo.
2. **Pošiljanje e-pošte.** SMTP ni nastavljen. Opozorila bodo nastajala in bodo vidna v
   aplikaciji, poslana pa ne bodo. Za pošiljanje rabiš naslov poštnega strežnika od IT.
3. **Domenska prijava**, če računalnik ni v isti domeni. Lokalni računi delajo vedno.
4. **Braytronova zaloga takoj po prenosu.** Dovoli en prenos na 3 ure; če je bil pravkar
   prenesen drugje, boš videl *»Razmik dobavitelja še teče«*. To ni napaka.

---

## 12. Če bo tekel na strežniku pod IIS

Za pravo namestitev, ne za preizkus:

```
C:\PIM\program\   ← dotnet publish (gotove .exe, brez izvorne kode)
C:\PIM\data\      ← datoteke od dobaviteljev
C:\PIM\logs\      ← dnevniki
```

Tri stvari drugače kot pri preizkusu:

1. **`dotnet publish`, ne `dotnet run`.** `dotnet run` ob vsakem zagonu znova prevede kodo —
   288-krat na dan je to nesmisel in povzroča zaklepe.
2. **Namenski servisni račun** s pravico *Log on as a batch job*, ne tvoj. Takrat opravila tečejo
   v ozadju in konzolnega okna ni niti načeloma.
3. **Redna varnostna kopija baze.** Na preizkusnem računalniku ni potrebna — bazo lahko kadarkoli
   sestaviš znova iz migracij. V produkciji pa vsebina ni več ponovljiva.

Načrtovana opravila so vezana na računalnik, kjer so registrirana. Uporabnik, ki odpre PIM v
brskalniku, jih ne vidi in ne more sprožiti — to je stvar strežnika, ne spletne strani.

---

## Povzetek na eno stran

```powershell
# 1. koda
git clone <naslov> C:\PIM\NoviPIM ; cd C:\PIM\NoviPIM

# 2. skrivnosti  ->  ustvari appsettings.Local.json v korenu (korak 3)

# 3. baza
cd PIM_Solution
dotnet run --project src\PIM.Migrator -- --create-database
dotnet run --project src\PIM.Migrator
dotnet run --project src\PIM.Migrator -- --verify

# 4. prvi skrbnik
dotnet run --project src\PIM.Migrator -- --ustvari-admina <ime>

# 5. dokaz
cd .. ; scripts\run_tests.ps1

# 6. zagon
dotnet run --project PIM_Solution\src\PIM.Intranet     # http://127.0.0.1:5091

# 7. vsebina
.\scripts\Zaloga-cikel.ps1 -Kaj Dobavitelji
.\scripts\Nocno-vse.ps1 -ZalogaIzSaop

# 8. samodejno
.\scripts\Namesti-opravila.ps1
```
