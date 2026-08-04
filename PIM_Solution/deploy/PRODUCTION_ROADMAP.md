# PIM_Solution — arhitektura, baza in pot do produkcije

Ta dokument opisuje: (1) kako je sistem sestavljen danes, (2) kako je zgrajena baza,
(3) kaj je treba narediti za produkcijo (workerji, intranet, izvozi, SAOP write-back)
in (4) kam ciljamo — sistem, ki deluje ne glede na to, kateri XML, atribut, kategorijo
ali izvoz dodamo.

> Skrivnosti (connection string, tokeni, poverilnice) nikoli ne sodijo v Git, ukazno
> vrstico ali chat. Živi cilji se omogočijo šele po fixture testu in odobritvi.

---

## 1. Kako je sistem sestavljen danes

### Vodilo: en generični, s konfiguracijo gnan pipeline
Za razliko od starega PIM_test (tabela na endpoint, tabela na organizacijo, ločen
model za Stock/XML) je PIM_Solution **vir-agnostičen**. Vsi viri gredo skozi isto pot;
razlike med viri so **vrstice konfiguracije**, ne nova koda ali nove tabele.

### Tok podatkov (vhod → izhod)
```
VIRI (SAOP API, NW XML, BT XML, NW/BT zaloge)
   │  workerji samo zajamejo surovo vsebino (brez transformacij)
   ▼
raw.Inbox / stock.LandingRecord        ← skupni nabiralnik (landing)
   │  generično mapiranje po konfiguraciji (map.*)
   ▼
canon.*  (kanonični model, brez imen virov)   +  map.ExtractedValue / map.UnmappedValue / karantena
   │  val.RunValidation  (bere val.FieldRequirement)
   ▼
val.ProductValidationState / val.ProductIssue
   │  val.Promote  (samo veljavni izdelki)
   ▼
pim.*  (potrjeni katalog)
   │
   ├─► out.Export*Csv  → PRODUCTS / STOCK / CUSTOMERS / SHIPPING CSV  → splet (Magento)
   └─► out.OutboxMessage → PIM.Outbound/OutboxDispatcher → SAOP write-back (F8)

Nadzor čez vse: ops.*  (razporedi, heartbeat, health, watchdog, alarmi)
Dostop/UI:      PIM.Intranet + sec.* (vloge, prijava)
```

### .NET projekti (`src/`)
| Projekt | Vloga |
|---|---|
| `PIM.Migrator` | ustvari/nadgradi bazo, `--verify` |
| `PIM.Operations` | skupni run/heartbeat/complete wrapper (`ops.BeginRun` …) |
| `PIM.XmlMapping` | generični XPath extractor + `SqlMappingPipeline` |
| `PIM.StockMapping` | normalizacija zalog |
| `PIM.B2b` | B2B model in izvozi |
| `PIM.Outbound` | determinističen outbox dispatcher (SAOP write-back) |
| `PIM.Intranet` | Blazor intranet (IIS) |

### Workerji (`workers/`)
| Worker | Namen | Tip zagona | Stanje |
|---|---|---|---|
| `PIM.KatalogWorker` | SAOP katalog (5 endpointov) | interval (Scheduled Task) | fixture ✅ / live TODO |
| `PIM.XmlFileWorker` | generični XML iz mape (NW_XML) | interval | ✅ (popravljen zaključek runa) |
| `PIM.NwXmlWorker` | NW XML transport (varianta) | interval | pripravljeno |
| `PIM.StockFileWorker` | NW CSV / BT XML zaloge | interval | bere fixture; zapis TODO |
| `PIM.SaopStockWorker` | SAOP zaloge (API) | interval | infrastruktura; live TODO |
| `PIM.B2bWorker` | B2B stranke/popusti | interval | fixture ✅ |
| `PIM.OutboxDispatcher` | pošiljanje iz outboxa (SAOP write) | interval | ✅ / live TODO |
| `PIM.Watchdog` | stale/Dead/Drift detekcija | interval (nadzor) | ✅ |
| `PIM.AlertDispatcher` | dostava alarmov | interval (nadzor) | ✅ (dostava privzeto izklopljena) |
| `PIM.FoundationWorker` | temeljni/skeletni | — | temelj |

> Workerji so tipa **„zaženi in končaj"** → v produkciji tečejo kot **Scheduled Task na
> interval**, ne kot klasična Windows storitev. `sp_getapplock` prepreči prekrivanje.

---

## 2. Kako je sestavljena baza

Ena baza `PIM`, organizacija je **stolpec** (`OrganizationId`), ne ločena shema/tabela.
Sheme so razdeljene po odgovornosti:

| Shema | Namen | Ključne tabele |
|---|---|---|
| `dbo` | temelj | `OrganizationConfig`, `SchemaMigration`, `IntegrationProfile` |
| `raw` | surovi landing (vsi viri) | `Inbox` |
| `map` | **konfiguracija mapiranja (možgani)** | `SourceConnector`, `EntityMapping`, `FieldMapping`, `StockIdentityRule`, `Watermark`, `ExtractedValue`, `UnmappedValue` |
| `canon` | kanonični model (vir-agnostičen) | `Product`, `ProductText`, `ProductAttribute` (EAV), `ProductCategory`, `ProductMedia`, `ProductPrice`, `ProductCommercial` |
| `val` | validacija | `FieldRequirement`, `ValidationProfile`, `ProductValidationState`, `ProductIssue` |
| `pim` | potrjeni katalog + B2B | `Product*`, `CustomerTypeCatalog`, `CustomerWebProfile`, popusti/dostave |
| `stock` | zaloge | `LandingRecord`, `Snapshot`, `Position`, `UnmatchedPosition`, `SyncRun`, `SaopProviderProfile` |
| `out` | izhodni kontrakt | `ExportProfile`, `ExportColumn`, `OutboxMessage`, `OutboxAttempt`, `OwnershipPolicy` |
| `ops` | nadzor/orkestracija | `ScheduleProfile`, `PipelineRun`, `IntegrationHealth`, `Heartbeat`, `Watchdog` alarmi (`Alert`, `AlertDelivery`, `AlertRecipientConfig`), `DeadLetterQueue`, `ErrorLog`, `DeploymentRun` |
| `sec` | dostop | `LocalUser`, `Role`, `LocalUserRole`, navigacija |
| `intranet` | UI procedure | (procedure) |

**Srce sistema so `map.*` tabele.** Tam je zapisano, kateri vir ima katere entitete,
katera XPath/element se preslika v katero kanonično polje, kateri je obvezen, po
katerem ključu se združuje (EAN) itd. Dodajanje vira/polja pomeni vpis vrstic sem —
ne novo tabelo.

---

## 3. Trenutno stanje (F0–F10) — kaj že dela

- **Zajem:** SAOP katalog (fixture), NW XML (generični file worker).
- **Mapiranje/validacija/promocija:** generično, s karanteno za neustrezne vrstice.
- **Izvozi:** PRODUCTS / STOCK / CUSTOMERS / SHIPPING CSV iz izvoznih profilov.
- **SAOP write-back:** outbox model (F8) s privzeto `ManualApproval`.
- **Nadzor:** razporedi, heartbeat, health, watchdog, dedup alarmi (F9); stran `/system/integracije`.
- **Intranet:** prijava (lokalno + AD), vloge ADMIN/CATALOG_EDITOR/VIEWER/COMMERCIAL (F10).

---

## 4. Namerno izklopljeno (živi deli za produkcijo)

Ti deli so izklopljeni, ker rabijo skrivnosti ali potrjene pogodbe:

1. **Živi SAOP GET** (`KatalogWorker` `Live`): avtentikacija/token, paginacija, retry/timeout.
2. **Živi SAOP write-back** (F8): potrjena endpoint/payload pogodba + odobritev.
3. **Resnična e-pošta/webhook** (F9): vklop po lokalnem fixture testu.
4. **Dostava izvozov na splet** (Magento): CSV se generira; način dostave (mapa/FTP/HTTP) je treba definirati.
5. **Zapis zalog** (`StockFileWorker`/`SaopStockWorker`): trenutno zajem/branje; polni zapis v bazo TODO.

---

## 5. Pot do produkcije po komponentah

### A. Baza (SQL 2019)
1. Ustvari `PIM`; poženi migracije dvakrat + `--verify` (`Preverjanje F0–F10 baze je uspešno.`).
2. **Dva ločena login-a z najmanjšimi pravicami:**
   - worker račun: `EXECUTE` na `ops.*` + potrebne pipeline procedure, `Modify` na landing mapah;
   - intranet račun: `intranet.*` / `sec.*`;
   - **brez `db_owner`** v produkciji.
3. Redni backup (`deploy/Backup-PIM.sql`, `COPY_ONLY`). Cilj vedno `PIM`, nikoli `PIM_test`.

### B. Workerji, ki vedno tečejo (Scheduled Tasks)
Ker workerji berejo nastavitve iz okoljskih spremenljivk, uporabi **ovojno skripto**,
ki jih nastavi in požene self-contained exe. Primer za XML worker
(`C:\PIM\Workers\run-xml.ps1`):

```powershell
# Ovojna skripta za Scheduled Task — nastavi okolje in požene worker.
$env:PIM_CONNECTION_STRING = (Get-Content 'C:\PIM\Workers\PIM.XmlFileWorker\appsettings.Local.json' -Raw | ConvertFrom-Json).ConnectionStrings.Pim
$env:PIM_XML_SOURCE_CODE     = 'NW_XML'
$env:PIM_XML_ORGANIZATION_ID = '2'
$env:PIM_XML_ROOT            = 'C:\PIM\Inbound\NW_XML'
& 'C:\PIM\Workers\PIM.XmlFileWorker\PIM.XmlFileWorker.exe'
```

Objava (self-contained, ne rabi .NET na cilju):
```powershell
dotnet publish .\workers\PIM.XmlFileWorker\PIM.XmlFileWorker.csproj -c Release -r win-x64 --self-contained true -o C:\PIM\Workers\PIM.XmlFileWorker
```

Registracija naloge pod **namenskim računom** (interval 5 min):
```powershell
$action    = New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\PIM\Workers\run-xml.ps1'
$trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)
$principal = New-ScheduledTaskPrincipal -UserId 'STREZNIK\PIM_SVC' -LogonType Password -RunLevel Limited
Register-ScheduledTask -TaskName 'PIM-XmlFileWorker' -Action $action -Trigger $trigger -Principal $principal -Password (Read-Host 'Geslo' -AsSecureString)
```

**Več organizacij / endpointov = več nalog + več vrstic v `ops.ScheduleProfile`**, isti
exe. Nič se ne podvaja v kodi. Za nadzor registriraj še `PIM-Watchdog` in `PIM-AlertDispatcher`.

### C. Intranet + HTTPS
IIS site `PIM` (No Managed Code), namenski app pool račun s SQL dostopom, **HTTPS
certifikat** na binding 443 (v testu je tekel na portu 80). Objava prek
`deploy/Publish-Intranet.ps1` (ali ročni `dotnet publish`).

### D. Izvozi na splet (Magento)
`out.Export*Csv` že proizvedejo CSV. Dodaj **izvozni task**, ki periodično požene izvoz
za profil (npr. `WEB_B2C_PRODUCTS`) in datoteko **dostavi** na spletni cilj. Definiraj
način dostave (skupna mapa / FTP / HTTP) — to je zadnji operativni člen.

### E. SAOP write-back
`out.OutboxMessage` + `PIM.Outbound`/`OutboxDispatcher` obstajajo. Za živo:
1. potrdi endpoint/payload pogodbo;
2. avtentikacija iz git-ignoriranih nastavitev;
3. lokalni HTTP fixture test;
4. neodvisen review;
5. šele nato kontroliran živi zagon z odobritvijo (`ManualApproval`).

---

## 6. Prenos na strežnik

Če je cilj **drug** strežnik:
1. Predpogoji: .NET 8 SDK (ali le Hosting Bundle za intranet), IIS.
2. Kopiraj repozitorij / publish artefakte.
3. Na cilju **ročno** ustvari `appsettings.Local.json` (connection string tega strežnika), ACL omeji.
4. Migracije + `--verify` proti tej bazi.
5. Intranet → IIS; workerji → publish + Scheduled Taske.

Pravilo: **koda + publish se kopirata; skrivnosti nastaviš ročno na vsakem cilju.**

---

## 7. KAM CILJAMO — sistem, ki deluje ne glede na to, kaj dodamo

Cilj je, da vsaka od naslednjih sprememb pomeni **konfiguracijo (vrstice), ne novo kodo
ali migracijo sheme**:

| Sprememba | Kaj narediš (ciljno) | Koda? |
|---|---|---|
| **Nov XML vir / dobavitelj** | vrstica v `map.SourceConnector` + `map.EntityMapping` (XPath) + `map.FieldMapping`; nova mapa/urnik | ❌ ne |
| **Nov endpoint istega vira** | nova `EntityMapping` vrstica | ❌ ne |
| **Nov atribut** | EAV: nova vrstica v `canon.ProductAttribute` prek `FieldMapping`; brez spremembe sheme | ❌ ne |
| **Nova kategorija / klasifikacija** | podatek (`canon.ProductCategory`) + preslikava v `FieldMapping` | ❌ ne |
| **Nova organizacija** | vrstice: `OrganizationConfig`, `SourceConnector`, `ScheduleProfile`; ista koda/exe | ❌ ne |
| **Nov izvoz / stolpec CSV** | `out.ExportProfile` + `out.ExportColumn`; validacija se samodejno uskladi prek `val.FieldRequirement` | ❌ ne |
| **Nov SAOP write-back** | `out.IntegrationProfile` + `out.OwnershipPolicy` + `OutboxMessage` | ❌ ne |
| **Novo obvezno polje** | vrstica v `val.FieldRequirement` (aktivni izvozni stolpec) | ❌ ne |

**Zlato pravilo:** worker samo zajame surovo vsebino; **vsa logika je podatek** v
`map.*`, `val.*`, `out.*`. Če dodajanje novega XML-ja, atributa, kategorije ali izvoza
zahteva spremembo C# kode ali novo tabelo, je to znak, da nekaj ni šlo skozi konfiguracijo
— in to je natanko napaka, ki jo je imel PIM_test in ki se ji PIM_Solution izogne.

### Kazalniki, da smo „produkcijsko dober PIM"
- Nov vir dodaš brez prevajanja kode (samo konfiguracija + urnik).
- En exe streže vse organizacije in endpointe.
- Karantena jasno pove razlog za vsako zavrnjeno vrstico (vidno v intranetu).
- Izvozi in write-back so gnani z izvoznimi profili in outboxom, ne z ročnimi skripti.
- Nadzor (`/system/integracije`) pokaže zdravje vsakega pipelinea; watchdog javi zastoje.
