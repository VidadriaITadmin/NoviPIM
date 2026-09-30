# 08 — Bralni API za AI in analize

API omogoča AI orodjem (Claude, ChatGPT, lastne skripte, Excel), da **berejo** podatke iz PIM:
izdelke, cene, zalogo, stranke, naročila dobaviteljem in analitiko. **Pisati ne more nič**: ne v
katalog, ne v SAOP, ne v nastavitve. Tehnični opis je v [`docs/API.md`](../docs/API.md).

```
AI (Claude / ChatGPT / skripta / Excel)
        │  HTTPS + ključ (X-Api-Key: pim_...)
        ▼
PIM.Api  (IIS spletno mesto PIM-API, vrata 5095)
        │  prijava v bazo: uporabnik v vlogi pim_api_reader
        ▼
baza PIM → samo postopki sheme api (branje) → canon, b2b, stock, purch, ana
```

Vsak ključ ima **ime**, **dovoljena podjetja**, **področja** (izdelki, cene, zaloga, stranke, nabava,
analitika), **omejitev klicev na minuto** in po želji **rok veljavnosti**. Vsak klic se zapiše
(kdo, kdaj, kaj, koliko vrstic); dnevnik se hrani 90 dni.

---

## 1. Namestitev na strežnik (enkrat)

### 1.1 Baza

Migracija `287_BralniApiZaAnalizeInAi.sql` mora biti uveljavljena, kot vse ostale
([02_Migracije.md](02_Migracije.md)). Ustvari shemo `api` in vlogo `pim_api_reader`.

### 1.2 Objava na razvojnem računalniku

```powershell
cd C:\Users\David\Desktop\PIM\NoviPIM
powershell -ExecutionPolicy Bypass -File PIM_Solution\deploy\Publish-Api.ps1
```

Nastane mapa `publish_api_<datum>` ob repozitoriju (PIM.Api.exe, web.config, Install-PimApi.ps1).
Prenesi jo na strežnik (npr. `C:\prenos\publish_api_2026-09-26`).

### 1.2a Preizkus na razvojnem računalniku (brez IIS)

Če želiš API samo preizkusiti, ga lahko zaženeš neposredno iz repozitorija (bere razvojno bazo):

```powershell
cd C:\Users\David\Desktop\PIM\NoviPIM\PIM_Solution
$env:PIM_API_CONNECTION_STRING = 'Server=DESKTOP-TONVQHJ\MSSQLSERVER3;Database=PIM;Integrated Security=True;TrustServerCertificate=True'
$env:ASPNETCORE_URLS = 'http://localhost:5095'
dotnet run --project src\PIM.Api -c Release
```

V drugem oknu preveri `http://localhost:5095/health` (mora vrniti `"status":"ok"`). Ključ za preizkus
ustvari z istim ukazom kot v 2, le da namesto `.\PIM.Api.exe` napišeš
`dotnet run --project src\PIM.Api -c Release --`, na primer:

```powershell
dotnet run --project src\PIM.Api -c Release -- odjemalec dodaj --ime "Preizkus" --podjetja 2,3 --podrocja izdelki,cene,zaloga --velja-do 2026-10-06
```

Po preizkusu ključ prekliči (`odjemalec preklici --id N`). Ključa s področjem `stranke` za preizkus ne
ustvarjaj (osebni podatki).

### 1.3 Namestitev na strežniku

Predpogoj je isti kot za intranet: IIS in **ASP.NET Core Hosting Bundle 10**.

PowerShell **kot skrbnik**:

```powershell
cd C:\prenos\publish_api_2026-09-26
powershell -ExecutionPolicy Bypass -File .\Install-PimApi.ps1 -SqlServer 'IME-STREZNIKA\INSTANCA' -OpenFirewall
```

Skripta ustvari aplikacijsko skupino in spletno mesto `PIM-API` (vrata 5095, mapa
`C:\inetpub\PIM-API`), ob prvi namestitvi še `appsettings.Local.json` s povezavo do baze, v bazi
prijavo `IIS APPPOOL\PIM-API` v vlogi `pim_api_reader` in na koncu preveri `http://localhost:5095/health`.

- **SQL na drugem strežniku kot IIS:** dodaj `-SqlLogin 'DOMENA\IME-IIS-STREZNIKA$'` (račun računalnika).
- **Brez sqlcmd:** dodaj `-SkipSql`; skripta izpiše tri ukaze SQL za SSMS.
- **Posodobitev:** nova objava + ista skripta (nastavitve in dnevniki ostanejo).

### 1.4 Dostop od zunaj (samo, če ga res rabiš)

AI v oblaku (Claude.ai, ChatGPT) dostopa **prek interneta**. Takrat:

1. API objavi **samo prek HTTPS** (IIS vezava 443 s certifikatom ali obratni posrednik). Ključ po
   navadnem HTTP lahko kdorkoli na poti prebere.
2. V `C:\inetpub\PIM-API\appsettings.Local.json` omeji naslove, ki smejo klicati:

   ```json
   "Api": { "AllowedRemoteIps": [ "192.168.1.0/24", "203.0.113.10" ], "PublicBaseUrl": "https://pim-api.<vaša-domena>" }
   ```

   Prazen seznam = vsi naslovi. `PublicBaseUrl` je naslov, ki ga vidi AI (v opisu OpenAPI).
3. Po spremembi: `Restart-WebAppPool PIM-API`.

Lokalna orodja (Claude Code, Claude Desktop na računalniku v omrežju, Excel) delujejo brez tega.

---

## 2. Uporabniki (ključi)

Ključe upravlja skrbnik baze z ukazi v `PIM.Api.exe`. Ukaz poženi **kot uporabnik z pravicami v bazi**
(isti, ki poganja migracije). Vloga API-ja ključev ne more ustvarjati.

```powershell
cd C:\inetpub\PIM-API
```

**Nov ključ**, npr. za Claude, samo za IQ Lighting in Vidadrio, brez strank:

```powershell
.\PIM.Api.exe odjemalec dodaj --ime "Claude analitika" --podjetja 2,3 --podrocja izdelki,cene,zaloga,nabava,analitika
```

Izpiše ključ `pim_...` **samo enkrat**. V bazi je shranjen le njegov odtis (SHA-256), zato izgubljenega
ključa ni mogoče prebrati; ustvari novega in starega prekliči. Ključ shrani v upravitelj gesel.

Neobvezno: `--velja-do 2027-12-31` (rok), `--na-minuto 60` (privzeto 120), `--opomba "..."`.
Brez `--podjetja` ključ bere vsa aktivna podjetja, brez `--podrocja` vsa področja.

| Kaj | Ukaz |
|---|---|
| Seznam ključev (stanje, zadnja uporaba, klici v 7 dneh) | `.\PIM.Api.exe odjemalec seznam` |
| Dodaj področje stranke | `.\PIM.Api.exe odjemalec spremeni --id 3 --podrocja izdelki,cene,zaloga,stranke` |
| Vsa podjetja | `.\PIM.Api.exe odjemalec spremeni --id 3 --podjetja vsa` |
| Odstrani rok | `.\PIM.Api.exe odjemalec spremeni --id 3 --brez-roka` |
| Prekliči ključ | `.\PIM.Api.exe odjemalec preklici --id 3` |
| Pomoč | `.\PIM.Api.exe odjemalec pomoc` |

Sprememba ali preklic začne veljati v **največ 60 sekundah**. Vsaka sprememba je zapisana v
`api.ClientHistory` (kdo, kdaj, prej in potem).

**Področja:** `izdelki` (iskanje, kartica, dobavitelji), `cene` (ceniki, spremembe, marža), `zaloga`
(zaloga, vrednost, pod minimumom), `stranke` (stranke, popusti, artikli stranke — osebni podatki, dajaj
premišljeno), `nabava` (naročila dobaviteljem), `analitika` (predlogi naročil, zaležana zaloga).

---

## 3. Povezava AI

Naslov v primerih: `http://IME-STREZNIKA:5095` (od zunaj `https://...`).

### Claude Code (ukazna vrstica)

```bash
claude mcp add --transport http pim-api http://IME-STREZNIKA:5095/mcp --header "X-Api-Key: pim_..."
```

Nato Claudu piši npr. »Koliko je vredna zaloga Vidadrie po dobaviteljih?«. Claude sam izbere orodja
(`stock_summary`, `search_stock`, `search_prices` …).

### Claude Desktop

V `%APPDATA%\Claude\claude_desktop_config.json` (potreben Node.js):

```json
{
  "mcpServers": {
    "pim-api": {
      "command": "npx",
      "args": ["mcp-remote", "http://IME-STREZNIKA:5095/mcp", "--allow-http", "--header", "X-Api-Key:${PIM_KEY}"],
      "env": { "PIM_KEY": "pim_..." }
    }
  }
}
```

Po spremembi Claude Desktop zapri in odpri.

### Claude.ai v brskalniku

Povezovalniki po meri v Claude.ai (in v ChatGPT) tečejo v oblaku: do strežnika v podjetju ne vidijo,
potrebujejo javni HTTPS naslov in praviloma prijavo OAuth, ne ključa v glavi. Zato danes zanesljivo
delujeta **Claude Code** in **Claude Desktop** na računalniku v notranjem omrežju. Objava na internet (1.4)
je tvoja odločitev; brez nje API ostane samo v notranjem omrežju.

### ChatGPT (GPT z akcijami) in druga orodja z OpenAPI

Uvozi opis z `https://<javni naslov>/openapi.json`, preverjanje pristnosti **API Key**, glava
`X-Api-Key`. Deluje samo z javnim HTTPS naslovom (1.4).

### Excel (Power Query) in skripte

Vsak seznam zna vrniti CSV za Excel (`format=csv`, podpičje, decimalna vejica):

```
Podatki → Iz spleta → Napredno
URL: http://IME-STREZNIKA:5095/api/v1/stock?organizationId=3&onlyPositive=true&take=1000&format=csv
Glava zahteve: X-Api-Key = pim_...
```

PowerShell:

```powershell
$h = @{ 'X-Api-Key' = 'pim_...' }
Invoke-RestMethod 'http://IME-STREZNIKA:5095/api/v1/stock/summary?organizationId=3&groupBy=dobavitelj' -Headers $h
```

---

## 4. Kaj API ponuja

Celoten, vedno ažuren opis vrne API sam: **`/api/v1/guide`** (navodila za AI, berljiva tudi človeku) in
**`/openapi.json`**. Na kratko:

| Pot | Kaj vrne |
|---|---|
| `/api/v1/organizations` | podjetja, ki jih ključ sme brati |
| `/api/v1/freshness` | kako stari so podatki (zaloga po virih, cene, stranke, naročila) |
| `/api/v1/products`, `/products/detail` | iskanje izdelkov (z zalogo in cenami), kartica izdelka |
| `/api/v1/partners` | šifre in imena dobaviteljev / proizvajalcev |
| `/api/v1/prices`, `/prices/lists`, `/prices/history`, `/prices/comparison` | cene, ceniki, zgodovina, marža |
| `/api/v1/stock`, `/stock/summary` | zaloga po izdelkih, vrednost zaloge po skupinah |
| `/api/v1/customers`, `/customers/detail` | stranke, popusti, artikli stranke |
| `/api/v1/purchase-orders` | naročila dobaviteljem: kaj pride in kdaj |
| `/api/v1/analytics/items`, `/analytics/suppliers` | predlogi naročil, zaležana zaloga (ko teče posel SAOP_ANALYTICS) |

Primeri vprašanj za AI:

- »Kateri artikli Vidadrie so pod minimalno zalogo in ali so naročeni?«
- »Katere B2C cene so se ta mesec spremenile in za koliko?«
- »Kje je faktor marže pod 2?«
- »Kakšna je vrednost zaloge IQ Lightinga po dobaviteljih?«
- »Kdaj pride roba od Duralampa?«

---

## 5. Težave

| Znak | Vzrok in rešitev |
|---|---|
| `/health` vrne 503 »baza ni dosegljiva« | napačen `Server=` v `appsettings.Local.json` ali prijava `IIS APPPOOL\PIM-API` nima dostopa do baze (1.3, `-SqlLogin`) |
| 401 »Ključ ni veljaven« | tipkarska napaka, ključ preklican ali potekel (`odjemalec seznam`) |
| 403 »Ključ nima področja« / »podjetja« | `odjemalec spremeni --id N --podrocja ...` ali `--podjetja ...` |
| 403 »Klic iz tega omrežja ni dovoljen« | naslov ni v `Api:AllowedRemoteIps` |
| 429 »Preveč klicev na minuto« | počakaj minuto ali `odjemalec spremeni --id N --na-minuto 300` |
| 500 pri klicu | v IIS dnevniku (Event Viewer → Application) je vzrok; pogosto manjkajoča migracija 287 |
| `odjemalec dodaj` javi »nima pravice upravljati ključev« | ukaz poženi kot skrbnik baze ali dodaj `--povezava "Server=...;Database=PIM;Integrated Security=True;TrustServerCertificate=True"` |
| AI pravi, da ima izdelek napako, v intranetu pa je v redu (ali obratno) | `validationStatus` v iskanju je shranjeno stanje zadnje validacije; merodajen je nabor `validation` na kartici izdelka (`get_product`). Naj AI pogleda kartico. |
| Podatki so stari | API bere, kar PIM ima. Svežino pove `/api/v1/freshness`; osvežuje jo gostitelj avtomatike ([05](05_AutomationHost.md)) |

Kdo je kaj klical: `SELECT TOP 100 * FROM api.RequestLog ORDER BY RequestLogId DESC;` (v SSMS).
