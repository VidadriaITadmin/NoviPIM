# PIM izvozi in odhodna pot (outbox) — referenca

Ta dokument opisuje **dejansko stanje** izhodne strani sistema `PIM_Solution`:
izvozne profile in procedure (`out.Export*`), CSV generatorje, odhodni outbox
(`out.OutboxMessage`) z varovalkami, varno lokalno testno pot in **mejo, pri
kateri se sistem ustavi pred dostavo zunanjemu sistemu**.

Vse navedbe so povzete iz SQL migracij, izvorne kode in testnih projektov v tem
repozitoriju. Dokument ne vsebuje povezovalnih nizov, gesel, tokenov ali vsebine
`appsettings*.json` in ne opisuje želenega stanja — samo tisto, kar je v kodi.

Zadnji pregled kode: 2026-08-09. Migracije 001–027.

---

## 1. Dva ločena izhodna kanala

Izhod ima **dve popolnoma ločeni poti**, ki si ne delita ne tabel ne varovalk:

```
pim.*  (potrjeni katalog)  +  b2b.*  +  stock.*
   │
   ├─► A) IZVOZI (pull, brez stanja)
   │      out.ExportProfile / out.ExportColumn  ──►  out.Export*Csv (SELECT)
   │      PIM.B2b / PIM.StockMapping CSV generatorji  ──►  datoteka
   │      dostava na splet (Magento): NI implementirana
   │
   └─► B) ODHODNA SPOROČILA (push, s stanjem in odobritvijo)
          out.EnqueueMessage ──► out.OutboxMessage ──► out.ClaimMessage
          ──► PIM.OutboxDispatcher (HTTP POST/PATCH) ──► out.CompleteAttempt
          ──► out.VerifyEcho (Verified / Drift)
          cilj (SAOP write-back): profil privzeto ONEMOGOČEN
```

| Lastnost | A) Izvozi | B) Outbox |
|---|---|---|
| Sprožilec | ročni klic procedure oziroma generatorja | `out.EnqueueMessage` |
| Stanje | brez stanja (SELECT/datoteka) | `out.OutboxMessage.Status` |
| Odobritev | ni je | `ManualApproval` / `Automatic` |
| Ponovni poskusi | ni jih (izvoz se preprosto ponovi) | `AttemptCount`, eksponentni zamik |
| Dedup | ni ga | unikatni filtrirani indeks nad `DedupKey` |
| Potrditev pri cilju | ni je | echo → `Verified` ali `Drift` |
| Nadzor | `ops.PipelineRun` pri workerjih vira | `ops.Alert` (`OutboundDead`, `OutboundDrift`) |
| Zunanja dostava danes | **ni sklenjena** (datoteka nastane, dostave ni) | **onemogočena** (ni profila, ni policy vrstic) |

---

## 2. Izvozni kontrakt: `out.ExportProfile` in `out.ExportColumn`

Kaj gre v izvoz, je **podatek**, ne koda. Profil je nabor stolpcev; vsak stolpec
preslika kanonično polje (`CanonicalFieldCode`) v izhodno ime (`OutputColumnName`)
z vrstnim redom in obveznostjo.

Shema: `sql/migrations/005_CreateOutputContract.sql:3-38`.

| Tabela | Ključne omejitve |
|---|---|
| `out.ExportProfile` | `UQ_ExportProfile_ProfileCode`, `IsActive` privzeto 1 |
| `out.ExportColumn` | unikaten `(ExportProfileId, ColumnCode)` **in** `(ExportProfileId, SortOrder)`, `CK … SortOrder > 0` |
| `val.ValidationProfile` | 1 : 1 z izvoznim profilom (`UQ_ValidationProfile_ExportProfile`) |
| `val.FieldRequirement` | 1 : 1 z izvoznim stolpcem (`UQ_FieldRequirement_ProfileColumn`) |

### 2.1 Zasejani profili

| `ProfileCode` | Kanal | Entiteta | Št. stolpcev | Migracija |
|---|---|---|---|---|
| `ERP_L1` | `ERP` | `PRODUCTS` | 9 | `005:75` |
| `WEB_B2C_PRODUCTS` | `SVETILA_SI_B2C` | `PRODUCTS` | 7 | `005:76` |
| `CUSTOMERS_B2B` | `B2B` | `CUSTOMERS` | 13 | `020:173` |
| `PRODUCTS_B2B` | `B2B` | `PRODUCTS` | 6 | `020:173` |
| `SHIPPING_B2B` | `B2B` | `SHIPPING` | 6 | `020:173` |

`PIM.Migrator --verify` zahteva obstoj `out.ExportProductsCsv` (F3),
`out.ExportStockCsv` (F6) ter `out.ExportB2bCustomersCsv` in
`out.ExportB2bProductsCsv` (F7), poleg dveh aktivnih B2B profilov
(`src/PIM.Migrator/Program.cs:391,408,425,433`).

### 2.2 Validacija je izpeljana iz izvoza

`val.SyncFieldRequirementsFromExportProfiles`
(`005_CreateOutputContract.sql:127-189`) uskladi `val.FieldRequirement` z
aktivnimi izvoznimi stolpci: obstoječe posodobi, manjkajoče vstavi, odvzete
deaktivira (`IsActive = 0`, nikoli brisanje). Ob napaki zapiše `ops.LogError`
s kodo `SYNC_FIELD_REQUIREMENTS_FAILED` in vrže naprej. Migracija jo požene
takoj (`005:191`).

**Posledica, ki jo je treba poznati:** validacijska profila sta zasejana samo za
`ERP_L1` in `WEB_B2C_PRODUCTS` (`005:114-124`). Trije B2B profili
(`CUSTOMERS_B2B`, `PRODUCTS_B2B`, `SHIPPING_B2B`) **nimajo** validacijskega
profila, zato njihovi stolpci niso zajeti v `val.FieldRequirement` in obveznost
polj pri njih preverja šele CSV generator ob pisanju (razdelek 3.2).

---

## 3. A) Izvozi

### 3.1 Izvozne procedure (vrnejo nabor vrstic, ne datoteke)

| Procedura | Parametri | Kaj vrne | Vir |
|---|---|---|---|
| `out.ExportProductsCsv` | `@OrganizationId int = 2`, `@ProfileCode nvarchar(100) = N'WEB_B2C_PRODUCTS'` | en stolpec `CsvLine` na izdelek; vse vrednosti v narekovajih, **brez glave**; `THROW 52301` če profil ni aktiven | `007_CreateSaopPipeline.sql:324-355` |
| `out.ExportStockCsv` | `@OrganizationId int` | pozicije iz `stock.Position` ⋈ aktivni `stock.Snapshot` ⋈ `map.SourceConnector` | `018_CreateStockPipeline.sql:176-183` |
| `out.ExportB2bCustomersCsv` | `@OrganizationId int` | stranke z `pim.CustomerWebProfile.WebEnabled = 1`; pragovi `COALESCE(strankin, globalni)`; `B2bWebPercent` je konstanta `2` | `020_CreateB2bChannel.sql:227` |
| `out.ExportB2bProductsCsv` | `@OrganizationId int` | izdelek × aktivna Magento skupina (`CROSS JOIN`, samo `MagentoGroupKey IS NOT NULL`) | `020:228` |
| `out.ExportB2bShippingCsv` | — (**brez** organizacije) | globalna pravila `pim.ShippingRuleCatalog` z `IsActive = 1`, urejena po `Priority` | `020:229` |

`out.ExportProductsCsv` je edina procedura, ki bere konfiguracijo stolpcev iz
`out.ExportColumn`; preostale štiri imajo nabor stolpcev zapisan v besedilu
procedure.

**Znana vrzel:** `out.ExportProductsCsv` preslika osem kanoničnih polj
(`Product.ItemID`, `Product.EAN`, `Product.Manufacturer`,
`ProductText.WEB_TITLE.sl`, `ProductCategory.CategoryPath`, `ProductMedia.Url`,
`ProductPrice.Gross`, `ProductAttribute.CategoryRequired`). Profil `ERP_L1`
zahteva `ProductText.TITLE_ERP.sl`, `Product.UoM`, `Product.Supplier`,
`Product.AccountingGroup`, `Product.DiscountGroup` in `ProductPrice.VatRate` —
teh `CASE` ne pokriva, zato `COALESCE(…, N'')` vrne **prazno vrednost** in klic
z `@ProfileCode = N'ERP_L1'` ne pade, ampak tiho izpiše šest praznih stolpcev
od devetih.

### 3.2 CSV generatorji (edini del, ki dejansko zapiše datoteko)

| Razred | Datoteka | Značilnosti |
|---|---|---|
| `CustomerCsvGenerator` | `src/PIM.B2b/CustomerCsvGenerator.cs:44` | sestavljena polja `Customer.Flags`, `Customer.ValueTiers`, `Customer.GroupDiscounts`, `Policy.Shipping`; `Policy.B2bWebPercent` iz `DiscountPolicy.B2bWebPercent = 2` |
| `B2bProductCsvGenerator` | `CustomerCsvGenerator.cs:89` | zavrne `Pak2 <= 0` in neusklajeno S-šifro/odstotek |
| `ShippingPolicyCsvGenerator` | `CustomerCsvGenerator.cs:117` | urejeno po `Priority` |
| `ConfiguredCsvWriter` | `CustomerCsvGenerator.cs:133` | skupni pisalec za vse tri |
| `StockCsvGenerator` | `src/PIM.StockMapping/StockCsvGenerator.cs:8` | **fiksna** glava, brez konfiguriranih stolpcev |

`ConfiguredCsvWriter` je pogodbena varovalka izvoza
(`CustomerCsvGenerator.cs:135-156`):

- upošteva samo `IsActive` stolpce, uredi po `SortOrder`, nato po `ColumnCode`;
- ob praznem naboru ali podvojenem `SortOrder` vrže `ExportContractException`;
- glava so `OutputColumnName` vrednosti;
- manjkajoča **ali prazna** vrednost obveznega stolpca → `ExportContractException`;
- UTF-8 **brez BOM**, `NewLine = "\n"`, ubežanje `,` `"` CR LF po pravilu podvojenega narekovaja.

`StockCsvGenerator` piše prav tako UTF-8 brez BOM, vendar **ne** nastavi
`NewLine`, zato na Windows uporabi CRLF — izhod se v tem pogledu razlikuje od
B2B izvozov.

### 3.3 Kdo izvoze danes kliče

**Noben produkcijski klicatelj.** Iskanje po `PIM_Solution` pokaže, da procedure
`out.Export*Csv` in generatorje kličejo izključno testi
(`tests/PIM.F5.Integration/Program.cs:57`, `tests/PIM.F3.Integration/Program.cs:38`,
`tests/PIM.F6.Integration/Program.cs:9`, `tests/PIM.F7.Integration/Program.cs:60-62,181-183`)
in pogodbeni testi, ki preverjajo besedilo migracij. V `workers/` ni izvoznega
workerja in `deploy/Configure-ScheduledTasks.ps1:11` registrira samo
`PIM.Watchdog` in `PIM.AlertDispatcher`.

To je skladno z `deploy/PRODUCTION_ROADMAP.md:117` (»Dostava izvozov na splet
(Magento): CSV se generira; način dostave (mapa/FTP/HTTP) je treba definirati«)
in `PRODUCTION_ROADMAP.md:167-170`: izvozni task in način dostave sta zadnji
manjkajoči operativni člen.

---

## 4. B) Odhodna sporočila (outbox)

### 4.1 Tabele in profili

| Objekt | Namen | Vir |
|---|---|---|
| `dbo.IntegrationProfile` | cilj, endpoint, HTTP operacija, način odobritve, timeout, ponovni poskusi | `021_CreateOutboundOutbox.sql:6-29` |
| `out.OwnershipPolicy` | katero polje sme PIM spremeniti pri cilju | `021:31-51` |
| `out.OutboxMessage` | sporočilo s stanjem, hashi, lease-om in odzivom | `021:53-92` |
| `out.OutboxAttempt` | zgodovina posameznih poskusov | `021:101-120` |

`dbo.IntegrationProfile` — privzetki in omejitve:

| Polje | Privzeto | Omejitev |
|---|---|---|
| `IsEnabled` | `0` | `CK … EnabledContract`: vklop zahteva `EndpointTemplate` **in** `HttpOperation IN (POST, PATCH)` |
| `ApprovalMode` | `ManualApproval` | `ManualApproval` ali `Automatic` |
| `TimeoutSeconds` | `30` | 1–300 |
| `MaxAttempts` | `5` | 1–20 |
| `BaseRetrySeconds` | `30` | 1–86400 |
| unikatnost | — | ena vrstica na `(OrganizationId, TargetKind)` |

`out.OwnershipPolicy`: `Owner IN (PIM, SAOP)`, `IsEnabled` privzeto `0`,
`ConstraintKind` je `NULL`, `PriceList` (primerja se s `qualifier`) ali
`ExactValue` (primerja se z `value`).

> Migracije **ne zasejejo nobene vrstice** v `dbo.IntegrationProfile` ali
> `out.OwnershipPolicy`. Brez ročnega vpisa operaterja odhodna pot fizično ne
> more oddati ničesar (glej razdelek 8).

### 4.2 Stanja in prehodi

Dovoljena stanja (`CK_OutboxMessage_Status`, `021:87`): `PendingApproval`,
`Pending`, `Sending`, `Sent`, `Verified`, `Error`, `Retry`, `Dead`, `Cancelled`,
`Drift`.

```
EnqueueMessage
   ├─ ApprovalMode=ManualApproval ─► PendingApproval ─(ApproveMessage)─► Pending
   └─ ApprovalMode=Automatic ──────────────────────────────────────────► Pending
Pending / Retry ─(ClaimMessage)─► Sending
Sending ─(CompleteAttempt)─┬─ uspeh ─────────────────────────► Sent
                           ├─ začasna napaka ────────────────► Retry (zamik)
                           └─ trajna napaka / poskusi porabljeni ► Dead
Sending ─(potekel lease, ClaimMessage)─► Retry | Dead
Sent ─(VerifyEcho)─┬─ hash se ujema ───► Verified
                   └─ hash se ne ujema ► Drift
PendingApproval | Pending | Error | Retry ─(CancelMessage)─► Cancelled
Error | Dead ─(RetryMessage)─► Retry
```

Dve poštenosti glede tega diagrama:

- Stanje `Error` je dovoljeno v omejitvi, v dedup indeksu ter v filtrih
  `CancelMessage` in `RetryMessage`, vendar ga **nobena procedura ne nastavi** —
  `CompleteAttempt` pozna samo `Sent`, `Retry` in `Dead`.
- Iz stanja `Drift` ni izhoda prek procedur: `RetryMessage` dovoli le `Error` in
  `Dead`, `CancelMessage` pa `Drift` ne zajema. Odklon se obravnava ročno.

### 4.3 Procedure

| Procedura | Vloga | Napake |
|---|---|---|
| `out.EnqueueMessage` | strežniška meja vpisa (razdelek 5.1) | `51000`, `51006`–`51010`, `51001` |
| `out.ApproveMessage` | `PendingApproval → Pending`, zapiše `ApprovedBy/Utc` | `51002` |
| `out.CancelMessage` | → `Cancelled`, `NextAttemptUtc = NULL` | `51003` |
| `out.RetryMessage` | `Error`/`Dead` → `Retry`, sprosti lease | `51004` |
| `out.ClaimMessage` | obnovi en potekli poskus, nato prevzame eno sporočilo | — |
| `out.CompleteAttempt` | zaključi poskus in izračuna naslednje stanje | `51005` |
| `out.VerifyEcho` | `Sent` → `Verified` ali `Drift` | — |
| `intranet.GetOutboundMessages` / `…Message` | bralni model za `/outbound` | — |

Vsaka od `Approve`/`Cancel`/`Retry` zahteva natanko eno prizadeto vrstico, sicer
`ROLLBACK` in `THROW` — sočasna ali neveljavna dejanja ne uspejo tiho
(`021:150-178`).

### 4.4 Dispatcher (`PIM.OutboxDispatcher`)

`workers/PIM.OutboxDispatcher/Program.cs`:

- brez `PIM_CONNECTION_STRING` izpiše obvestilo in se konča **brez enega samega
  HTTP klica** (`Program.cs:5-10`);
- `WorkerId = {MachineName}:{ProcessId}`;
- en zagon obdela **natanko eno** sporočilo (en `out.ClaimMessage`, brez zanke);
- tek je zavit v `OperationsRun` s pipeline oznako `OUTBOUND` (heartbeat, health,
  `ops.CompleteRun`);
- `HttpClient.Timeout` je `TimeoutSeconds` iz profila;
- `HttpRequestException` / `TaskCanceledException` → `Retry`, oziroma `Dead`, če
  je `AttemptCount >= MaxAttempts`.

`SaopOutboundHandler` (`SaopOutboundHandler.cs`):

| Varovalka | Izvedba |
|---|---|
| dovoljeni metodi | samo `POST` in `PATCH`, drugo vrže `InvalidOperationException` (`:20-25`) |
| razvrstitev odziva | 2xx → `Sent`; 408, 429 in ≥ 500 → `Retry`; drugo 4xx → `Dead` (`DispatchClassifier:69-76`) |
| redakcija odziva | JSON ključi `token`, `access_token`, `refresh_token`, `password`, `secret`, `authorization`, `apiKey` → `[REDACTED]`, rekurzivno (`:54-61`) |
| omejitev odziva | shrani največ 4000 znakov (`:51`) |
| korelacija | `X-Correlation-ID`, sicer `Request-ID` (`:37`) |

`RetryPolicy.Delay` (`:81-85`) je referenčna implementacija eksponentnega zamika
z zgornjo mejo; **v teku uporabi zamik SQL** (`CompleteAttempt`), ki zgornje meje
ne pozna.

---

## 5. Varovalke odhodne poti

### 5.1 Pogodba vpisa je strežniška

Po `023_HardenOutboundIntegrityAndLeases.sql:3-54` klicatelj **ne more** več
podtakniti ključa, hasha ali dedup ključa. `out.EnqueueMessage` sprejme samo
`@PayloadJson` in:

1. zahteva neprazna `@Actor` in `@Operation` (`51006`, `51007`);
2. zahteva JSON objekt (`51000`);
3. dovoli **natanko 3 ali 4** lastnosti iz nabora `entityKey`, `field`, `value`,
   `qualifier`, vse tipa niz; vse drugo je `51008`;
4. zavrne manjkajoče obvezne vrednosti (`51009`);
5. zahteva **omogočen** `dbo.IntegrationProfile` (`51001`);
6. zahteva **omogočeno** `out.OwnershipPolicy` vrstico z `Owner = PIM` za
   `(organizacija, cilj, entiteta, polje)`, pri čemer `PriceList` primerja
   `qualifier` in `ExactValue` primerja `value` (`51010`);
7. kanonizira payload prek `FOR JSON PATH, WITHOUT_ARRAY_WRAPPER` in izračuna
   `PayloadHash = ExpectedEchoHash = DedupKey = SHA2_256(kanonični payload)`;
8. status je `Pending` samo pri `ApprovalMode = Automatic`, sicer
   `PendingApproval`.

`PIM.Outbound.OwnershipPolicy` (`src/PIM.Outbound/OwnershipPolicy.cs:21-43`) ima
poleg tega **trdi seznam prepovedanih polj**, ki jih ne odpre nobena vrstica v
bazi: `ItemID`, `VAT`, `ACCOUNTING_GROUP`, `INVENTORY_ACCOUNT`, `MEDIA`,
`CATEGORY`, `WEB_TITLE`, `STOCK`, `DELIVERY`. `OutboundPayloadBuilder`
(`OutboundPayloadBuilder.cs:21-38`) dovoli samo `POST`/`PATCH` in v kanonični
JSON zapiše tri polja (`entityKey`, `field`, `value`) — `qualifier` ne, zato je
za hash in dedup merodajen izključno SQL.

### 5.2 Odobritev

Privzeti `ApprovalMode` je `ManualApproval`, zato sporočilo obtiči v
`PendingApproval` in ga `out.ClaimMessage` ne vidi (prevzema samo `Pending` in
`Retry`). Odobritev je izrecno dejanje z zapisanim akterjem
(`ApprovedBy`, `ApprovedUtc`) na strani `/outbound` — in **samo uvrsti v čakalno
vrsto**, kar piše tudi v UI besedilu
(`src/PIM.Intranet/Components/Pages/Outbound.razor:6`).

### 5.3 Dedup

Unikatni filtrirani indeks `UX_OutboxMessage_ActiveDedup` nad
`(OrganizationId, DedupKey)` velja za stanja `PendingApproval`, `Pending`,
`Sending`, `Sent`, `Error`, `Retry` (`021:94-96`). Ker je `DedupKey` hash
kanoničnega payloada, dvojni vpis iste spremembe ne ustvari drugega sporočila:
`EnqueueMessage` prestreže napako 2601/2627 in vrne **obstoječi**
`OutboxMessageId` (`023:46-52`). Zaključena stanja (`Verified`, `Dead`,
`Cancelled`, `Drift`) niso v filtru, zato je kasnejši ponovni vpis iste
spremembe dovoljen.

### 5.4 Ponovni poskusi, lease in okrevanje

- `out.ClaimMessage` v isti transakciji **najprej** zapre en poskus s poteklim
  lease-om: `Dead`, če je `AttemptCount >= MaxAttempts`, sicer `Retry`, in
  ustrezno zaključi vrstico v `out.OutboxAttempt`
  (`023:62-77`).
- Prevzem uporablja `TOP(1) … WITH (UPDLOCK, READPAST, ROWLOCK)` z urejanjem po
  `OutboxMessageId` (FIFO), zato dva workerja ne dobita istega sporočila.
- Lease je `TimeoutSeconds + 30 s` iz profila, ne fiksnih 60 s (`023:87`).
- `out.CompleteAttempt` zahteva `Status = Sending` in ujemajoč `LeaseOwner`,
  ne pa več veljavnega lease-a (`023:106`) — pozen odziv veljavnega workerja se
  še zaključi, po ponovnem prevzemu pa ne več.
- Zamik: `NextAttemptUtc = now + BaseRetrySeconds × 2^(AttemptCount − 1)`
  (`023:110`).
- `022_StabilizeOutboundScheduling.sql:19` nastavi `NextAttemptUtc` na
  `now − 1 ms`, da prvega prevzema ne preskoči enaka časovna žiga.

### 5.5 Echo in odklon (drift)

`out.VerifyEcho` (`024_MatchEchoByExpectedHash.sql`) najprej poišče `Sent`
sporočilo, katerega `ExpectedEchoHash` **se ujema** s prispelim hashem (najnovejše
najprej), in šele če ga ni, vzame najnovejše `Sent` sporočilo istega ključa.
Zato echo novejše spremembe ne označi starejše kot `Drift`. Ujemanje → `Verified`
z `VerifiedUtc`; neujemanje → `Drift` z `DriftDetail`. Pogoj `@ObservedUtc >=
SentUtc` prepreči, da bi star odmev potrdil novo sporočilo.

Protipovratna zanka je izrecna:

- `EchoVerifier.Decide` loči `Missing`, `Stale`, `Verified`, `Drift`, a
  `ShouldAutomaticallyResend` **vedno vrne `false`** — sistem po odklonu nikoli
  ne pošlje samodejno (`src/PIM.Outbound/EchoVerifier.cs:18`);
- `EchoAntiLoop.ShouldEnqueue` prepreči vpis spremembe, ki je hash-identična že
  potrjeni vrednosti (`OwnershipPolicy.cs:53-57`).

### 5.6 Sledljivost in nadzor

- Vsak poskus je vrstica v `out.OutboxAttempt` z `WorkerId`, časi, izidom,
  statusno kodo, **rediranim** odzivom in korelacijskim ključem; unikatnost
  `(OutboxMessageId, AttemptNumber)`.
- `ops.RunWatchdog` odpre kritična opozorila `OutboundDead` in `OutboundDrift`,
  združena po organizaciji in statusu, z dedup ključem
  (`025_CreateOperationsMonitoring.sql:205-209`).
- `intranet.GetSystemIntegrations` vrne `OutboxDeadCount` in `OutboxDriftCount`
  na pipeline (`025:262-263`), viden na `/system/integracije`.
- `/outbound` (`Outbound.razor`) je omejen na vloge `ADMIN`,
  `CATALOG_EDITOR`, `COMMERCIAL`, bere `intranet.GetOutboundMessages` za aktivno
  organizacijo in ponuja Odobri / Prekliči / Ponovi z akterjem iz prijavljene
  identitete. Intranet ne kliče HTTP-ja neposredno; to varovalko preverja
  `tests/PIM.F8.IntranetTests`.

---

## 6. Kaj mora biti izpolnjeno, da sporočilo sploh nastane

Vse spodnje mora držati hkrati; vsak manjkajoči pogoj je izrecna napaka, ne tiho
preskočena pot:

1. `dbo.IntegrationProfile` za `(organizacija, TargetKind)` obstaja in ima
   `IsEnabled = 1` (sicer `51001`);
2. profil ima `EndpointTemplate` in `HttpOperation IN (POST, PATCH)` (sicer ga
   `CK_IntegrationProfile_EnabledContract` ne pusti vklopiti);
3. `out.OwnershipPolicy` ima omogočeno vrstico `Owner = PIM` za entiteto in polje
   (sicer `51010`);
4. polje ni na trdem seznamu prepovedanih v `PIM.Outbound` (razdelek 5.1);
5. payload ustreza pogodbi 3–4 nizovnih polj (sicer `51008`/`51009`);
6. če je `ApprovalMode = ManualApproval`, mora človek sporočilo odobriti;
7. za dejansko oddajo mora nekdo pognati `PIM.OutboxDispatcher` z nastavljenim
   `PIM_CONNECTION_STRING`.

---

## 7. Varna lokalna testna pot

### 7.1 Pravila, ki jih testi uveljavljajo sami

`tests/PIM.F8.Integration/Program.cs:9-15`:

- povezava se bere iz `PIM_F8_TEST_CONNECTION_STRING`, sicer
  `PIM_CONNECTION_STRING`, sicer `ConnectionStrings:Pim` iz git-ignorirane
  lokalne datoteke (skrivnosti se ne commitajo in ne izpisujejo);
- `InitialCatalog = PIM_test` → izjema (`»F8 dokaz ne sme dostopati do
  PIM_test.«`);
- karkoli razen `InitialCatalog = PIM` → izjema (dovoljena je samo razvojna baza);
- HTTP cilj je `HttpListener` na `http://127.0.0.1:<prosti port>` — nikoli
  zunanji naslov;
- `finally` blok pobriše **izključno svoje** vrstice: poskuse, sporočila,
  ownership policy, integracijski profil in testno organizacijo.

Izolirane testne organizacije: `9808` (`PIM.F8.Integration`) in `9813`
(`PIM.F8.HardeningTests`, `TEST_REPORT_F8.md:46-48`). Izvozni test piše CSV v
mapo pod `Path.GetTempPath()` in jo v `finally` izbriše
(`tests/PIM.F7.Integration/Program.cs:53,91`).

### 7.2 Ukazi (razvojna baza `PIM`)

```powershell
cd PIM_Solution
dotnet build .\PIM.sln --no-restore

# shema in pogodba F0–F10
dotnet run --project .\src\PIM.Migrator\PIM.Migrator.csproj
dotnet run --project .\src\PIM.Migrator\PIM.Migrator.csproj -- --verify

# izvozi
dotnet run --project .\tests\PIM.F3.Integration\PIM.F3.Integration.csproj
dotnet run --project .\tests\PIM.F5.Integration\PIM.F5.Integration.csproj
dotnet run --project .\tests\PIM.F6.Integration\PIM.F6.Integration.csproj
dotnet run --project .\tests\PIM.F7.Integration\PIM.F7.Integration.csproj

# odhodna pot in varovalke
dotnet run --project .\tests\PIM.F8.ContractTests\PIM.F8.ContractTests.csproj
dotnet run --project .\tests\PIM.F8.BehaviorTests\PIM.F8.BehaviorTests.csproj
dotnet run --project .\tests\PIM.F8.DispatcherTests\PIM.F8.DispatcherTests.csproj
dotnet run --project .\tests\PIM.F8.EchoTests\PIM.F8.EchoTests.csproj
dotnet run --project .\tests\PIM.F8.Integration\PIM.F8.Integration.csproj
dotnet run --project .\tests\PIM.F8.HardeningTests\PIM.F8.HardeningTests.csproj
dotnet run --project .\tests\PIM.F8.IntranetTests\PIM.F8.IntranetTests.csproj
```

Kaj lokalni dokaz pokrije (`TEST_REPORT_F8.md:33-53`): dedup, `Retry`, `Dead`,
`Sent`, `Verified`, `Drift`, zavrnitev `VAT`, zavrnitev dodatnega JSON polja,
zavrnitev nedovoljene `ExactValue`, pozen zaključek poskusa, sesutje workerja,
atomarni ponovni prevzem, sočasnost dveh workerjev, izbira echo hasha in dva
`PATCH` klica izključno na `127.0.0.1`.

### 7.3 Ročni pregled brez zunanjega klica

`out.EnqueueMessage` je mogoče varno preizkusiti tudi brez pošiljanja: profil
pusti `IsEnabled = 1` z `ApprovalMode = ManualApproval` in **ne** poženi
dispatcherja. Sporočilo obstane v `PendingApproval`, `/outbound` pokaže
`FieldSummary`, dedup ključ in stanje, `out.ClaimMessage` pa ga ne prevzame.

Prepovedano ostaja tudi v testu: zagon proti `PIM_test` ali produkcijski bazi,
uporaba pravih poverilnic in klic zunanjega endpointa
(`CLAUDE.md`, `deploy/WINDOWS_E2E_RUNBOOK.md:3,177`).

---

## 8. Meja zunanje dostave

Meja ni stvar dobre volje — v repozitoriju je sedem konkretnih zapor:

| # | Zapora | Kje je | Kaj bi jo odprlo |
|---|---|---|---|
| 1 | ni izvoznega workerja in ni dostave datotek | v `workers/` ga ni; `Configure-ScheduledTasks.ps1:11` registrira le Watchdog in AlertDispatcher | dogovorjen način dostave (mapa/FTP/HTTP) + izvozni task (`PRODUCTION_ROADMAP.md:167-170`) |
| 2 | noben `dbo.IntegrationProfile` ni zasejan | migracija 021 tabelo samo ustvari | zaveden vpis operaterja z potrjenim endpointom |
| 3 | `IsEnabled = 0` in `ApprovalMode = ManualApproval` privzeto | `021:15-16` | izrecen vklop + odobritev vsakega sporočila |
| 4 | nobena `out.OwnershipPolicy` vrstica ni zasejana, privzeto `IsEnabled = 0` | `021:43` | eksplicitna dodelitev lastništva polja PIM-u |
| 5 | živi SAOP write-back je **BLOCKED** | `TEST_REPORT_F8.md:55-60` | potrjena neprodukcijska endpoint/payload pogodba, varen testni artikel, poverilnice iz git-ignoriranih nastavitev, lokalni fixture test, neodvisen pregled in izrecno dovoljenje (`PRODUCTION_ROADMAP.md:172-178`) |
| 6 | dostava opozoril privzeto izklopljena | `AlertDeliveryOptions(Enabled = false)` → izid `Disabled` (`workers/PIM.AlertDispatcher/WebhookAlertSender.cs:5,13`) | vklop po lokalnem fixture testu (`PRODUCTION_ROADMAP.md:116`) |
| 7 | dispatcher brez povezave ne naredi ničesar | `PIM.OutboxDispatcher/Program.cs:5-10` | nastavljen `PIM_CONNECTION_STRING` v ovojni skripti Scheduled Taska |

Kar torej **v tem trenutku** prestopi mejo procesa PIM: nič. Izvozi obstanejo kot
naboru vrstic oziroma lokalna datoteka, odhodna sporočila obstanejo v
`out.OutboxMessage`, dispatcher pa opravi HTTP klic samo proti naslovu, ki ga je
nekdo vpisal v `EndpointTemplate` omogočenega profila — v dokazih je to vedno
`127.0.0.1`.

Skrivnosti (povezovalni nizi, tokeni, poverilnice) ne sodijo v Git, ukazno
vrstico ali chat; na vsakem cilju se nastavijo ročno
(`PRODUCTION_ROADMAP.md:8-9,191`).

---

## 9. Znane vrzeli in tveganja

1. **Izvoz ni sklenjen do cilja.** CSV nastane samo, kadar ga nekdo generira; ni
   urnika, ni dostave, ni evidence oddanih datotek (nasprotno kot outbox, ki ima
   `Status` in poskuse).
2. **`ERP_L1` prek `out.ExportProductsCsv` vrne prazne stolpce** za šest od
   devetih polj (razdelek 3.1) — tiha, ne glasna napaka.
3. **B2B profili niso pokriti z `val.FieldRequirement`**, ker za njih ni
   validacijskega profila (razdelek 2.2).
4. **Trije od petih izvozov imajo stolpce zapisane v proceduri**, ne v
   `out.ExportColumn`, zato pri njih »nov stolpec = vrstica konfiguracije« ne
   drži (nasprotno od cilja v `PRODUCTION_ROADMAP.md:207`).
5. **`out.ExportB2bShippingCsv` ne pozna organizacije** — pravila dostave so
   globalna za vse štiri organizacije.
6. **`B2bWebPercent = 2` je konstanta** na dveh mestih (`020:227` in
   `src/PIM.B2b/DiscountCalculator.cs:14`), ne konfiguracija.
7. **Stanje `Error` je mrtva pot**, iz `Drift` pa prek procedur ni izhoda
   (razdelek 4.2).
8. **Dispatcher obdela eno sporočilo na zagon**, zato je pretok odhodne poti
   določen z intervalom Scheduled Taska; večja zaostanka ne nadoknadi.
9. **`StockCsvGenerator` uporablja CRLF in fiksno glavo**, medtem ko B2B izvozi
   uporabljajo LF in konfigurirane stolpce — dva različna izhodna sloga.
10. **Odklon (`Drift`) se ne razrešuje samodejno** in po zasnovi tudi ne sme
    (`ShouldAutomaticallyResend → false`); brez ročnega postopka se opozorilo
    `OutboundDrift` samo ponavlja.

---

## 10. Kje je kaj

| Področje | Pot |
|---|---|
| Izvozni kontrakt | `PIM_Solution/sql/migrations/005_CreateOutputContract.sql` |
| Izvoz izdelkov (profil-gnan) | `007_CreateSaopPipeline.sql:324` |
| Izvoz zalog | `018_CreateStockPipeline.sql:176` |
| B2B izvozi in kanal | `020_CreateB2bChannel.sql:173,227-229` |
| Outbox (tabele, procedure) | `021_CreateOutboundOutbox.sql` |
| Stabilizacija razporejanja | `022_StabilizeOutboundScheduling.sql` |
| Utrditev pogodbe in lease-a | `023_HardenOutboundIntegrityAndLeases.sql` |
| Izbira echo hasha | `024_MatchEchoByExpectedHash.sql` |
| Nadzor odhodne poti | `025_CreateOperationsMonitoring.sql:190-268` |
| CSV generatorji | `src/PIM.B2b/CustomerCsvGenerator.cs`, `src/PIM.StockMapping/StockCsvGenerator.cs` |
| Domenske varovalke | `src/PIM.Outbound/OwnershipPolicy.cs`, `OutboundPayloadBuilder.cs`, `EchoVerifier.cs` |
| Dispatcher | `workers/PIM.OutboxDispatcher/` |
| UI | `src/PIM.Intranet/Components/Pages/Outbound.razor` |
| Dokazi | `PIM_Solution/TEST_REPORT_F8.md`, `tests/PIM.F5–F8*` |
| Operativa | `deploy/PRODUCTION_ROADMAP.md`, `deploy/WINDOWS_E2E_RUNBOOK.md` |
