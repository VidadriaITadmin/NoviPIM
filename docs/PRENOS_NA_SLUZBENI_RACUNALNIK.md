# Prenos PIM na službeni računalnik — korak za korakom

Navodila za nekoga, ki tega še ni delal. **Vsak korak pove, kam klikneš, kaj vtipkaš in kaj
mora pisati na zaslonu.** Če piše kaj drugega, je pod korakom napisano, kaj narediti.

Ne preskakuj korakov in ne delaj dveh hkrati.

**Koliko časa:** priprava računalnika 1–2 uri (večinoma čakanje na namestitve), potem 30 minut
do delujočega sistema. Polnjenje podatkov teče samo, do nekaj ur.

Nadomešča [`LAPTOP_INSTALL.md`](LAPTOP_INSTALL.md).

---

## Preden začneš — kaj sploh delamo

Prenašamo **kodo**, ne podatkov. Baza se sestavi sama iz datotek, ki so v Gitu: vse tabele,
procedure in nastavitve (štiri podjetja, viri, validacijski profili, urniki).

Prazno ostane samo tisto, kar pride iz dobaviteljev in SAOP: artikli, cene, zaloga, slike.
Tega potem ne prenašaš — sistem si to naloži sam.

> ### ⚠ Preberi to, preden porabiš dve uri
>
> **Trenutno korak 4 ne bo uspel.** Preizkusil sem 31. 8. 2026 na prazni bazi: migracije padejo
> na `070`, ker ta preveri, da urnik obstaja pri štirih podjetjih, vstavi pa ga le pri treh.
> Vrstica za podjetje 2 je na razvojnem računalniku nastala ročno in v migracijah je ni.
>
> Popravek je enovrstičen, a zahteva tvojo odločitev (podrobno v koraku 4.4). **Reci mi, naj ga
> naredim, preden greš na službeni računalnik** — sicer boš obtičal na sredini.

---

# DEL 1 — Pripravi računalnik

Vse iz tega dela narediš enkrat.

## Korak 1.1 — Preveri, ali je kaj že nameščeno

1. Pritisni tipko **Windows** na tipkovnici.
2. Natipkaj `powershell`.
3. V seznamu klikni **Windows PowerShell** (navaden klik, ne skrbniški).
4. Odpre se modro okno. Vanj **prilepi** to vrstico in pritisni **Enter**:

```powershell
dotnet --version; git --version; pwsh --version
```

**Kaj mora pisati:**

```
10.0.xxx
git version 2.xx.x
PowerShell 7.x.x
```

Vsaka vrstica, ki manjka ali javi *»ni prepoznan kot ukaz«*, pomeni, da ta program namesti v
naslednjih korakih. Kar že je, preskoči.

## Korak 1.2 — Namesti .NET 10 SDK

1. Odpri brskalnik in pojdi na **`https://dotnet.microsoft.com/download`**.
2. Poišči **.NET 10.0** in klikni gumb za **SDK** (ne »Runtime« — rabimo SDK).
3. Izberi **Windows x64**. Prenese se datoteka `dotnet-sdk-10...exe`.
4. Dvoklikni preneseno datoteko.
5. Klikni **Install**. Če Windows vpraša za dovoljenje, klikni **Da**.
6. Počakaj do konca in klikni **Close**.
7. **Zapri okno PowerShell in ga odpri na novo** (korak 1.1) — brez tega novega ukaza ne bo našel.
8. Preveri:

```powershell
dotnet --version
```

Mora pisati `10.0` in nato številke. Če piše `8.0` ali `9.0`, imaš staro različico — namesti
še 10 in ponovi.

## Korak 1.3 — Namesti PowerShell 7

1. V brskalniku pojdi na **`https://github.com/PowerShell/PowerShell/releases`**.
2. Pri najnovejši različici brez oznake `preview` poišči datoteko, ki se konča z
   **`-win-x64.msi`**, in jo klikni.
3. Dvoklikni preneseno datoteko, klikaj **Next**, na koncu **Install** in **Finish**.
4. Preveri v novem oknu PowerShell:

```powershell
pwsh --version
```

## Korak 1.4 — Namesti Git

1. Pojdi na **`https://git-scm.com/download/win`**. Prenos se začne sam.
2. Dvoklikni datoteko in klikaj **Next** čez vse zaslone (privzete nastavitve so v redu).
3. Na koncu **Install**, potem **Finish**.
4. Preveri v novem oknu:

```powershell
git --version
```

## Korak 1.5 — Namesti SQL Server

Če je SQL Server na računalniku že (ali imaš dostop do strežniškega), pojdi na korak 1.6.

1. Pojdi na **`https://www.microsoft.com/sql-server/sql-server-downloads`**.
2. Pri **Developer** klikni **Download now** (brezplačna, polna različica za razvoj).
3. Zaženi preneseno datoteko.
4. Izberi **Basic** (osnovna namestitev).
5. Klikni **Accept**, potem **Install**. Traja 10–20 minut.
6. Ko konča, si **zapiši ime instance** z zaslona — piše pri »Instance name«. Običajno
   `MSSQLSERVER` ali `SQLEXPRESS`.
7. Klikni **Close**.

Priporočam še **SQL Server Management Studio (SSMS)** — ni nujen, a koristi, ko boš gledal v bazo:
**`https://learn.microsoft.com/sql/ssms/download-sql-server-management-studio-ssms`** →
**Download SSMS** → zaženi → **Install**.

## Korak 1.6 — Ugotovi točno ime instance

To ime boš potreboval v koraku 3. Ne ugibaj ga.

V PowerShell prilepi:

```powershell
Get-Service | Where-Object { $_.Name -like 'MSSQL$*' -or $_.Name -eq 'MSSQLSERVER' } |
  Select-Object Name, Status
```

**Primer izpisa:**

```
Name                Status
----                ------
MSSQL$MSSQLSERVER3  Running
```

**Kako preberi:**

| Kar piše | Kaj vpišeš v koraku 3 |
|---|---|
| `MSSQL$MSSQLSERVER3` | `localhost\MSSQLSERVER3` |
| `MSSQL$SQLEXPRESS` | `localhost\SQLEXPRESS` |
| `MSSQLSERVER` (brez `$`) | `localhost` |

Torej: **vzameš tisto za znakom `$`** in pred to napišeš `localhost\`.

Če v stolpcu `Status` ne piše `Running`, ga zaženi:

```powershell
Start-Service 'MSSQL$IME_INSTANCE'
```

Zapiši si ime na listek. Rabil ga boš dvakrat.

---

# DEL 2 — Prenesi kodo

## Korak 2.1 — Naredi mapo in prenesi

V PowerShell prilepi **vsako vrstico posebej** in po vsaki pritisni Enter:

```powershell
mkdir C:\PIM
cd C:\PIM
git clone <NASLOV-REPOZITORIJA> NoviPIM
```

`<NASLOV-REPOZITORIJA>` zamenjaj z resničnim naslovom (dobiš ga na strani repozitorija z
gumbom **Code** → **HTTPS** → ikona za kopiranje).

Če te vpraša za uporabniško ime in geslo, vpiši svoje podatke za Git.

## Korak 2.2 — Preklopi na pravo vejo

```powershell
cd C:\PIM\NoviPIM
git checkout feature/intranet-i0-ia-bralni-moduli
```

Mora pisati `Switched to branch ...`.

## Korak 2.3 — Preveri, da je koda cela

```powershell
dotnet build C:\PIM\NoviPIM\PIM_Solution\PIM.sln
```

Prvič traja nekaj minut. **Mora pisati:**

```
Build succeeded.
    0 Warning(s)
    0 Error(s)
```

Če piše `error CS...`, se ustavi in javi — kode ne popravljaj sam.

---

# DEL 3 — Vpiši gesla in naslove

Tu vpišeš stvari, ki jih v Gitu ni in jih tudi nikoli ne sme biti.

## Korak 3.1 — Ustvari datoteko

1. Pritisni **Windows**, natipkaj `notepad`, klikni **Beležnica**.
2. Prilepi vanjo spodnje besedilo.
3. Klikni **Datoteka → Shrani kot**.
4. Zgoraj v naslovno vrstico vpiši `C:\PIM\NoviPIM` in pritisni Enter.
5. V polje **Ime datoteke** vpiši **z narekovaji**: `"appsettings.Local.json"`
   *(narekovaji so nujni, sicer Beležnica doda `.txt` in datoteka ne bo delovala)*
6. Pri **Kodiranje** izberi **UTF-8**.
7. Klikni **Shrani**.

Besedilo za prilepit:

```json
{
  "ConnectionStrings": {
    "Pim": "Server=localhost\\IME_INSTANCE;Database=PIM;Integrated Security=True;Encrypt=True;TrustServerCertificate=True"
  },
  "Saop": {
    "BaseUrl": "https://NASLOV-SAOP/iCenterAPI/",
    "Username": "UPORABNIK",
    "Password": "GESLO",
    "TimeoutSeconds": 120,
    "PageSize": 5000,
    "AcceptUntrustedCertificate": true,
    "Organizations": [ { "Id": 2, "IsActive": true } ]
  },
  "Fetch": {
    "BT_STOCK": "NASLOV-BRAYTRON-ZALOGA",
    "BT_XML": "NASLOV-BRAYTRON-KATALOG",
    "NW_STOCK": {
      "BaseUri": "ftp://NASLOV-FTP",
      "UserName": "FTP-UPORABNIK",
      "Password": "FTP-GESLO",
      "RemoteDirectory": "/",
      "RemoteFileName": "NOWODVORSKI.csv",
      "UsePassive": true
    }
  }
}
```

## Korak 3.2 — Zamenjaj vrednosti z velikimi črkami

| Zamenjaj | S čim |
|---|---|
| `IME_INSTANCE` | ime iz koraka 1.6 (npr. `MSSQLSERVER3`) |
| `NASLOV-SAOP`, `UPORABNIK`, `GESLO` | podatki za SAOP |
| `NASLOV-BRAYTRON-*`, `FTP-*` | podatki dobaviteljev |

**Vse te vrednosti so na trenutnem računalniku** v isti datoteki
`C:\Users\david\Desktop\PIM\NoviPIM\appsettings.Local.json`. Odpri jo z Beležnico in prepiši.

> **Prenesi jih varno.** Ne pošiljaj te datoteke po e-pošti, Teamsih ali v klepetu. Uporabi
> USB ključ ali upravitelja gesel. V njej so gesla do ERP in dobaviteljev.

> **Če instanca nima imena** (v koraku 1.6 je pisalo samo `MSSQLSERVER`), napiši
> `Server=localhost;` — brez poševnice in imena.

## Korak 3.3 — Preveri, da si datoteko shranil prav

```powershell
Get-Content C:\PIM\NoviPIM\appsettings.Local.json | Select-Object -First 3
```

Mora izpisati prve tri vrstice. Če javi *»ne obstaja«*, se je Beležnica shranila kot
`appsettings.Local.json.txt` — ponovi korak 3.1 z narekovaji.

> **Pomembna past.** V mapi `PIM_Solution\` je **druga** datoteka z istim imenom. **Te se ne
> dotikaj.** Ureja se samo tista v `C:\PIM\NoviPIM`.

---

# DEL 4 — Sestavi bazo

## Korak 4.1 — Ustvari bazo in naloži ogrodje

```powershell
cd C:\PIM\NoviPIM\PIM_Solution
dotnet run --project src\PIM.Migrator -- --create-database
```

Ta en ukaz ustvari bazo `PIM` in vanjo naloži vse tabele in nastavitve.

**Kaj mora pisati:** dolg seznam vrstic *»Uporabljena migracija: 001_...«*, *»002_...«* in tako
naprej do zadnje, na koncu pa:

```
Migracije so uspešno uporabljene.
```

## Korak 4.2 — Preveri, da se drugi zagon ne spremeni nič

```powershell
dotnet run --project src\PIM.Migrator
```

Zdaj mora pisati samo *»Preskočena že uporabljena migracija«* pri vsaki vrstici.
Če karkoli spet »uporabi«, se ustavi in javi.

## Korak 4.3 — Zadnja preverba

```powershell
dotnet run --project src\PIM.Migrator -- --verify
```

Mora pisati:

```
Preverjanje F0–F10 baze je uspešno.
```

## Korak 4.4 — Če korak 4.1 pade

Trenutno **bo padel**. Videl boš:

```
Uporabljena migracija: 069_SupplierConnectorsForAllOrganizations.sql
Napaka 52701: Razpored za dobaviteljev XML ni omogocen pri vseh stirih podjetjih.
```

**Kaj to pomeni.** Migracija `070` vstavi urnik za podjetja 1, 3 in 4, nato pa preveri, da so
štirje. Vrstice za podjetje 2 ne naredi nobena migracija — na starem računalniku je nastala ročno.

**Ni nevarno.** Migrator dela vse v enem kosu, zato ob padcu razveljavi vse. Baza ostane prazna,
nič se ne pokvari.

**Kaj narediti:** javi mi in popravim `070` tako, da vstavi vsa štiri podjetja. Popravek je ena
vrstica, a se ga moram dotakniti na datoteki, ki je na starem računalniku že nameščena — zato
rabim tvojo privolitev. Po popravku korak 4.1 steče do konca.

---

# DEL 5 — Naredi si uporabnika

Baza je zdaj prazna in v njej ni nobenega uporabnika. V PIM se ne moreš prijaviti, dokler si
računa ne narediš.

## Korak 5.1 — Ustvari skrbnika

```powershell
cd C:\PIM\NoviPIM\PIM_Solution
dotnet run --project src\PIM.Migrator -- --ustvari-admina david
```

`david` zamenjaj z uporabniškim imenom, ki ga hočeš.

**Kaj se zgodi:**

1. Vpraša **`Prikazno ime za david:`** → vpiši ime in priimek, Enter.
2. Vpraša **`Geslo (vsaj 10 znakov):`** → vtipkaj geslo, Enter.
   *Med tipkanjem se ne bo videlo nič — niti zvezdic. Tako je prav.*
3. Vpraša **`Ponovi geslo:`** → isto geslo, Enter.

**Mora pisati:**

```
Skrbnik david je ustvarjen. Prijavi se na /prijava in geslo takoj spremeni na /sistem/uporabniki.
```

Če javi *»Gesli se ne ujemata«*, ponovi ukaz.

---

# DEL 6 — Zaženi in se prijavi

## Korak 6.1 — Zaženi PIM

```powershell
cd C:\PIM\NoviPIM
dotnet run --project PIM_Solution\src\PIM.Intranet
```

**To okno pusti odprto.** Dokler je odprto, PIM teče. Ko ga zapreš, se ustavi.

Mora pisati nekaj takega:

```
Now listening on: http://127.0.0.1:5091
```

## Korak 6.2 — Odpri v brskalniku

1. Odpri brskalnik.
2. V naslovno vrstico vpiši **`http://127.0.0.1:5091`** in pritisni Enter.
3. Odpre se prijavna stran.
4. Vpiši uporabniško ime in geslo iz koraka 5.1.
5. Klikni **Prijava**.

**Vse strani bodo prazne. To je pravilno** — podatkov še ni. Naložimo jih v naslednjem delu.

## Korak 6.3 — Vpiši uporabnike

1. V meniju levo klikni **Sistem**.
2. Klikni kartico **Uporabniki**.
3. Za vsakega sodelavca:
   - domenski (ima službeni račun): v polje **Domenski uporabnik** vpiši `DOMENA\uporabnik`,
     izberi **Vlogo**, klikni **Najdi v AD**, potem **Dodaj**;
   - brez domenskega računa: izpolni **Dodaj lokalnega uporabnika** in klikni **Ustvari račun**.
4. V tabeli spodaj vsakemu vpiši **službeni e-naslov** in klikni **Shrani**.

> **E-naslovi niso okras.** Ravno s tega seznama sistem vzame, komu poslati opozorilo, ko se kaj
> ustavi. Brez naslova ta človek obvestil ne dobi.

---

# DEL 7 — Naloži podatke

Zdaj pride tisto, zaradi česar si vse to delal.

**Odpri drugo okno PowerShell** — prvo pusti, da PIM teče.

## Korak 7.1 — Dobaviteljeva zaloga

```powershell
cd C:\PIM\NoviPIM
.\scripts\Zaloga-cikel.ps1 -Kaj Dobavitelji
```

Traja minuto ali dve. Mora se končati z:

```
Zalogovni cikel koncan; padlih korakov: 0.
```

Med izpisi boš videl vrstice *»Zaloga zapisana; vir=NW_STOCK, podjetje=1, uporabljenih=2762«* —
to so prebrani zapisi.

## Korak 7.2 — Zaloga iz SAOP

**Najprej preveri, ali sploh dosežeš SAOP:**

```powershell
Test-NetConnection -ComputerName NASLOV-SAOP -Port 81
```

Poglej vrstico **`TcpTestSucceeded`**:

- `True` → nadaljuj;
- `False` → **vklopi VPN** in poskusi znova. Brez tega SAOP ne bo delal, vse drugo pa bo.

```powershell
.\scripts\Zaloga-cikel.ps1 -Kaj Saop
```

## Korak 7.3 — Cel katalog

```powershell
.\scripts\Nocno-vse.ps1 -ZalogaIzSaop
```

**To traja dolgo — tudi nekaj ur.** Zažene se lahko čez noč. Prebere cel katalog iz SAOP,
dobaviteljeve XML-e, naredi validacijo in pripravi izvoze.

Sproti piše, kaj dela. Dnevnik je v `C:\PIM\NoviPIM\logs\`.

## Korak 7.4 — Poglej, da so podatki notri

V brskalniku osveži PIM in klikni **Izdelki**. Zdaj morajo biti vrstice.
Če jih ni, poglej dnevnik v `logs\`.

---

# DEL 8 — Naj teče samo

## Korak 8.1 — Prižgi opravila

```powershell
cd C:\PIM\NoviPIM
.\scripts\Namesti-opravila.ps1
```

Registrira tri opravila:

| Opravilo | Kako pogosto | Kaj dela |
|---|---|---|
| **PIM zaloga** | 5 minut | SAOP, Nowodvorski, Braytron |
| **PIM nadzor** | 5 minut | preveri, ali se je kaj ustavilo, in pošlje opozorila |
| **PIM nocni tok** | vsak dan 02:30 | cel katalog |

## Korak 8.2 — Preveri, da so registrirana

```powershell
Get-ScheduledTask -TaskName 'PIM *' | Get-ScheduledTaskInfo |
  Select-Object TaskName, NextRunTime, LastTaskResult
```

Pri `NextRunTime` mora biti čas v prihodnosti. Po prvem zagonu mora biti `LastTaskResult` **0**
(nič pomeni uspeh).

## Korak 8.3 — Če te opravila motijo

Med razvojem lahko motijo, ker vsakih 5 minut zasedejo datoteke.

- **Ustaviš posamezen postopek:** v PIM-u **Sistem → Urniki obdelav** → gumb **Izklopi**.
- **Odstraniš vsa opravila:**

```powershell
.\scripts\Namesti-opravila.ps1 -Odstrani
```

---

# DEL 9 — Kako iščeš napake

Zaradi tega si hotel testno okolje. Po vrsti od zgoraj navzdol:

| Kaj hočeš vedeti | Kam klikneš |
|---|---|
| Ali vhodi tečejo | **Zajem in preslikave** → zavihek **Vhodi** |
| Kaj je padlo in zakaj | **Zajem** → zavihek **Težave** |
| Kdaj je kaj nazadnje uspelo | **Zajem** → zavihek **Teki** |
| Česa sistem ne razume | **Kakovost** → *Prevodi* in *Kategorije* |
| Zakaj izdelek ni veljaven | **Kakovost** → **Napake validacije** |
| Ali se je kaj ustavilo | **Sistem** → **Urniki obdelav** |
| Tehnične napake | **Sistem** → **Dnevnik napak** in mapa `logs\` |

**Filter podjetja je na vsaki strani** in privzeto so prikazana **vsa**. Če vidiš samo DEMO,
imaš staro različico kode.

## Kaj se zgodi, ko nekaj neha delati

Po **petih zaporednih napakah** se postopek sam izklopi in nastane opozorilo, ki pove:
kateri postopek, katero podjetje, koliko napak in kaj je pisalo v zadnji.

Vidiš ga na **Sistem → Urniki obdelav**. Ko vzrok odpraviš, ga tam **vklopiš z enim gumbom**.

To je namerno: klic, ki petkrat zapored ni uspel, se ne bo posrečil šestič.

---

# Kar na novem računalniku ne bo delalo

Da ne boš iskal napake tam, kje je ni:

1. **SAOP brez VPN.** Katalog in zaloga iz ERP ne bosta tekla. Vse drugo bo.
2. **Pošiljanje e-pošte.** Poštni strežnik še ni nastavljen. Opozorila bodo nastajala in bodo
   vidna v aplikaciji, poslana pa ne bodo.
3. **Domenska prijava**, če računalnik ni v isti domeni. Lokalni računi delajo vedno.
4. **Braytronova zaloga takoj po prenosu.** Dovoli en prenos na 3 ure. Če piše
   *»Razmik dobavitelja še teče«*, to ni napaka.

---

# Povzetek — vsi ukazi na enem mestu

Za tistega, ki je to že delal in rabi le opomnik:

```powershell
# 1. koda
mkdir C:\PIM ; cd C:\PIM
git clone <naslov> NoviPIM
cd NoviPIM ; git checkout feature/intranet-i0-ia-bralni-moduli
dotnet build PIM_Solution\PIM.sln

# 2. skrivnosti -> ustvari C:\PIM\NoviPIM\appsettings.Local.json (korak 3)

# 3. baza
cd PIM_Solution
dotnet run --project src\PIM.Migrator -- --create-database
dotnet run --project src\PIM.Migrator -- --verify

# 4. uporabnik
dotnet run --project src\PIM.Migrator -- --ustvari-admina <ime>

# 5. zagon  ->  http://127.0.0.1:5091
cd .. ; dotnet run --project PIM_Solution\src\PIM.Intranet

# 6. podatki (drugo okno)
.\scripts\Zaloga-cikel.ps1 -Kaj Dobavitelji
.\scripts\Nocno-vse.ps1 -ZalogaIzSaop

# 7. samodejno
.\scripts\Namesti-opravila.ps1
```
