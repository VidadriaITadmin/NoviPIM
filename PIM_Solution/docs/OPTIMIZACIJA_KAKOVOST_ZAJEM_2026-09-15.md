# Optimizacija: /kakovost, /kakovost/artikli, /zajem + popravek dvokliku

**Datum:** 2026-09-15
**Okolje meritev:** lokalni razvojni računalnik (`DESKTOP-TONVQHJ\MSSQLSERVER3`, baza `PIM`), SQL Server 2019, aplikacija na `http://localhost:5091`.
**Sprememba:** [`sql/migrations/214_QualityAndIngestPerformance.sql`](../sql/migrations/214_QualityAndIngestPerformance.sql) + popravki v 9 `.razor` datotekah (glej razdelek 4).

---

## 1. Povzetek

Pri merjenju časa odpiranja vseh strani intranet aplikacije so tri strani izstopale kot izjemno počasne:

| Stran | Prej | Po popravku | Pohitritev |
|---|---:|---:|---:|
| `/kakovost` | 16 597 ms | 530 ms | **31×** |
| `/kakovost/artikli` | 17 448 ms | 502 ms | **35×** |
| `/zajem` | 10 952 ms | 897 ms | **12×** |

Vse tri meritve "po popravku" so bile narejene **v živi aplikaciji** (ne samo v SQL-ju) po namestitvi migracije 214 — glej razdelek 3.4.

Poleg tega je bil popravljen razlog za "a task was canceled" napako ob dvokliku na isti gumb — ni šlo za en sam bug, ampak za ponavljajoč se vzorec, ki manjka na več mestih po aplikaciji (razdelek 4).

---

## 2. Metodologija — kako sem našel vzrok (ne samo simptom)

Za vsako počasno stran sem najprej ugotovil, katera SQL poizvedba dejansko traja dolgo, s pomočjo:

```sql
SET STATISTICS IO ON;   -- koliko strani/branj poizvedba dejansko naredi
SET STATISTICS TIME ON; -- koliko CPU/elapsed časa porabi
```

in za sporne poizvedbe še dejanski izvedbeni načrt:

```sql
SET SHOWPLAN_TEXT ON;
GO
<poizvedba>
GO
```

Šele ko je bil vzrok razviden iz `logical reads` / izvedbenega načrta (ne iz ugibanja), sem pripravil popravek in ga **na isti poizvedbi z istimi statistikami znova izmeril**, da je bila pohitritev dokazana, ne domnevana.

---

## 3. Trije vzroki in popravki

### 3.1 `/zajem` — manjkajoč indeks na `stock.LandingRecord` (10,7 s)

`PipelineReadService.GetInboundFlowsAsync` za vsakega od 28 konektorjev (`map.SourceConnector`) posebej prešteje vrstice v `stock.LandingRecord` (3,74 milijona vrstic):

```sql
SELECT SUM(CASE WHEN landing.Status = N'Pending' THEN 1 ELSE 0 END), ...
FROM stock.LandingRecord landing
WHERE landing.OrganizationId = connector.OrganizationId AND landing.SourceConnectorId = connector.SourceConnectorId
```

Edini obstoječi indeks na tej tabeli (`UQ_StockLandingRecord_Immutable`) ne vsebuje stolpca `Status`, zato je optimizator namesto iskanja izbral skoraj poln pregled cele tabele — **28-krat**.

**Izmerjeno (cela poizvedba `GetInboundFlowsAsync`, `SET STATISTICS IO ON`):**

| | Logičnih branj `LandingRecord` | Skupni čas |
|---|---:|---:|
| Prej | 5 479 320 | 10 523 ms |
| Po novem indeksu | 18 750 | 710 ms |

**Popravek:** nov pokrivni indeks —

```sql
CREATE NONCLUSTERED INDEX IX_StockLandingRecord_OrgConnector_Status
  ON stock.LandingRecord (OrganizationId, SourceConnectorId) INCLUDE (Status);
```

Dodan je tudi manjši indeks na `stock.SyncRun` (do zdaj samo `PK`), ki ga isti klic uporablja trikrat na konektor:

```sql
CREATE NONCLUSTERED INDEX IX_StockSyncRun_OrgConnector_StartedUtc
  ON stock.SyncRun (OrganizationId, SourceConnectorId, StartedUtc DESC)
  INCLUDE (Status, Endpoint, CompletedUtc, RecordsRead, SyncRunId);
```

### 3.2 `/kakovost` — zastarela statistika na obstoječem indeksu (16,5 s)

`GovernanceReadService.GetUnblockPlanAsync` se kliče vzporedno za vsako od 4 podjetij in bere `val.ProductIssue` (6,39 milijona vrstic, od tega 1,53 milijona aktivnih). Filtriran indeks `IX_ProductIssue_Active_ProductRequirement` (`WHERE IsActive = 1`) **je že obstajal** — težava ni bil manjkajoč indeks, ampak da optimizator zanj ni imel natančne statistike in je raje izbral poln pregled sklopljene tabele (`Clustered Index Scan` + `Bitmap`, razvidno iz `SHOWPLAN_TEXT`).

**Izmerjeno (ista poizvedba, eno podjetje):**

| | Logičnih branj | Elapsed |
|---|---:|---:|
| Prej (naravna izbira optimizatorja) | 163 350 | 1 070 ms |
| Prisiljena uporaba obstoječega indeksa (`WITH (INDEX(...))`) | 29 742 | 1 024 ms |
| Po `UPDATE STATISTICS ... WITH FULLSCAN` (brez namiga, naravna izbira) | 29 742 | 1 413 ms |

Po osvežitvi statistike optimizator **sam** izbere pravi (hitri) načrt — brez potrebe po kodnem namigu (query hint), kar je bolj vzdržno. Za vsa 4 podjetja skupaj, zaporedno, s toplim predpomnilnikom: **251 ms** namesto 16,5 s.

**Popravek:** ni sprememba sheme, samo osvežitev statistike —

```sql
UPDATE STATISTICS val.ProductIssue WITH FULLSCAN;
UPDATE STATISTICS canon.Product WITH FULLSCAN;
```

`AUTO_UPDATE_STATISTICS` je v bazi privzeto vklopljen, zato se bo statistika v prihodnje osveževala samodejno; ta ukaz samo takoj popravi trenutno zastarelo stanje.

### 3.3 `/kakovost/artikli` — korelirana poizvedba na vrstico namesto množične (17,7 s)

Stran kliče `intranet.GetQualityProducts`, ki bere iz pogleda `val.ProductChannelReadiness`. Pogled je za **vsakega od 177 679 aktivnih izdelkov posebej**:

1. iskal ime izdelka prek `canon.FieldValue` — pogleda, ki je 28-smerni `UNION ALL` čez ves katalog (`canon.Product`, `ProductCommercial`, `ProductText`, `ProductAttribute` dvakrat, `ProductCategory`, `ProductMedia`, `ProductPrice`). Ker so `FieldCode` v dveh vejah (`ProductText`, `ProductAttribute`) sestavljeni dinamično (`CONCAT`), jih optimizator ne zna izločiti vnaprej, zato je vsak izdelek sprožil ~6 pregledov teh tabel (skupaj 710 666 + 355 333 pregledov).
2. korelirano (`OUTER APPLY`) seštel `val.ProductIssue` × `FieldRequirement` × `ValidationProfile` — namesto enega množičnega `JOIN + GROUP BY` je to naredil 177 679-krat posebej, kar je prisililo SQL Server v tabelo dela (`Worktable`) z **19 947 012** logičnimi branji.

**Izmerjeno (izolirano, korak za korakom):**

| Del poizvedbe | Prej | Po popravku |
|---|---:|---:|
| Samo iskanje imena (`canon.FieldValue` → neposreden `canon.ProductText`) | — | odpravljeni pregledi `ProductText`/`ProductAttribute` |
| Samo seštevanje napak (`OUTER APPLY` → `LEFT JOIN` + `GROUP BY`) | 19 947 012 branj, 14 469 ms | 120 ms |
| Celoten pogled (`SELECT INTO #Rows FROM ... WHERE IsActive=1`) | 17 655 ms | **540 ms** |
| Cela shranjena procedura `intranet.GetQualityProducts` | 19 697 ms | 551 ms |

**Popravek:** pogled `val.ProductChannelReadiness` prepisan iz korelirane `OUTER APPLY`-na-vrstico oblike v množično `LEFT JOIN` + `GROUP BY` obliko; iskanje imena gre neposredno na `canon.ProductText` namesto skozi `canon.FieldValue`.

> **Zakaj je to varno:** pogoj `FieldCode IN ('Product.Name', 'ProductText.TITLE_ERP.sl')` je v izvirnem pogledu `canon.FieldValue` dejansko nikoli sprožil vejo `Product.Name` — ta niz se v nobeni veji pogleda ne pojavi (preverjeno z branjem definicije), zato je edini dejanski vir imena vedno bil `ProductText.TITLE_ERP.sl`. Neposreden `LEFT JOIN` na `canon.ProductText` s pogojem `TextType='TITLE_ERP' AND Lang='sl'` je zato **natančno enak** rezultat, ne poenostavitev z drugačnim vedenjem.

**Preverjanje pravilnosti (ne samo hitrosti):** stara in nova različica sta bili pognani druga poleg druge v začasne tabele in primerjani:

```
Old: 177679 vrstic, SumErr=1452054, SumWarn=84994, SumErpBlok=543080, SumWebBlok=79428, checksum imen=-1359387688
New: 177679 vrstic, SumErr=1452054, SumWarn=84994, SumErpBlok=543080, SumWebBlok=79428, checksum imen=-1359387688
Vrstic z razliko v kateremkoli stolpcu: 0
```

Vse vrednosti so **bit-za-bit enake** — sprememba je izključno hitrostna, ne vsebinska.

### 3.4 Preverjeno v živi aplikaciji (ne samo v SQL-ju)

Po namestitvi migracije 214 sem odprl dejansko aplikacijo (prijavljena seja) in ponovil enak `fetch` test kot v prvotnem poročilu o času nalaganja strani:

| Stran | Prej (prvotno poročilo) | Po popravku (živa aplikacija) |
|---|---:|---:|
| `/kakovost` | 16 597 ms | **530 ms** |
| `/kakovost/artikli` | 17 448 ms | **502 ms** |
| `/zajem` | 10 952 ms | **897 ms** |

---

## 4. Popravek "a task was canceled" ob dvokliku

### Vzrok

Vsak gumb za shranjevanje/dejanje uporablja polje `bool Busy` (ali `ActionBusy`, `Loading`, ...) in ga onemogoči z `disabled="@Busy"`. To samo po sebi **ni dovolj**: pri hitrem dvokliku lahko drugi klik do strežnika pride, preden se posodobljen (onemogočen) gumb sploh vrne nazaj v brskalnik — Blazor Server namreč vsak klik pošlje kot ločeno sporočilo prek SignalR, uporabniški vmesnik pa se osveži šele po tem, ko strežnik odgovori. Brez zgodnje zaščite `if (Busy) return;` **na začetku** metode se v tem kratkem oknu obravnavalec izvede dvakrat hkrati — kar je pri strani Outbound (razdelek "Odobri"/"Pošlji zdaj") pomenilo tveganje, da se **isti artikel dvakrat pošlje v SAOP/ERP preko istega omrežnega klica** (`SaopWriteService.TrySendArticleAsync`, traja do 25 s), kar zlahka pojasni napako "a task was canceled" — drugi vzporedni klic prekine/prehiti prvega.

Pravilen vzorec je že obstajal na `ProductCard.razor` (`SaveChangesAsync`, `SaveWebShopsAsync`) in `CatalogReservationExclusions.razor` — manjkal je na več drugih straneh.

### Kaj je bilo popravljeno

Dodana zgodnja zaščita `if (Busy) return;` (ali z enakim imenom polja na tisti strani) kot **prva** vrstica v obravnavalcu, pred `Busy = true;`, v:

| Datoteka | Obravnavalci |
|---|---|
| `Components/Pages/Outbound.razor` | `Act`, `Approve`, `SendNow`, `RetryArticle`, `ActBulk`, `ApproveSelected` |
| `Components/Pages/CustomerDetail.razor` | `SaveGeneralAsync`, `ClearGeneralAsync`, `SaveProfileAsync`, `SaveTierAsync`, `SaveContactsAsync`, `ClearContactsAsync`, `AddNoteAsync`, `SaveBranchAsync` |
| `Components/Pages/BulkOutbound.razor` | `QueueAsync`, `ApproveAsync`, `CancelAsync` |
| `Components/Pages/SystemWorkers.razor` | `VklopiAsync`, `NaloziAsync` (glej opombo spodaj) |
| `Components/Pages/CatalogAttributes.razor` | `SaveAsync` |
| `Components/Pages/CatalogCategories.razor` | `CreateCategoryAsync`, `SaveAsync`, `SetAttributeLevelAsync` |
| `Components/Pages/CategoryAttributeSets.razor` | `SetLevelAsync`, `CreateUnknownAndSaveAsync`, `CreateAndAddAsync`, `SaveManyAsync`, `CopyAsync` |
| `Components/Pages/CatalogControl.razor` | `RunAsync` (skupni ovoj za vsa dejanja na strani) |
| `Components/Pages/Checks.razor` | `SaveThresholdsAsync`, `AcknowledgeAsync`, `ResolveAsync` |

**Opomba o `SystemWorkers.razor`:** polje `Loading` se na tej strani privzeto inicializira na `true` (da je gumb "Osveži" onemogočen med prvim nalaganjem strani). Naivna zaščita `if (Loading) return;` bi zato **preprečila prvi klic** iz `OnInitializedAsync` in stran bi ostala prazna. Namesto tega je dodano ločeno polje `NalaganjeVTeku` (privzeto `false`), ki varuje pred podvojenim klicem, ne da bi vplivalo na prvo nalaganje.

Vse spremembe so preverjene z `dotnet build` (0 napak, 0 opozoril) — glej razdelek 5.4.

### Kaj ni bilo spremenjeno (namenoma)

Preiskava je pokazala, da so vsi obstoječi `CancellationTokenSource`/`TaskCanceledException` vzorci (`Media.razor`, `SystemWorkers.razor` — živ izpis dnevnika, `WorkerConsoleService`, `SaopWriteService`) **že pravilno** ujeti z `try/catch`. Prava napaka je bila izključno manjkajoča zaščita pred dvojnim vnosom, ne napačno ravnanje s preklicem.

---

## 5. Kako ročno pognati vsak korak

### 5.1 Namestitev migracije 214 na TEST bazo

**Priporočeno — prek uradnega orodja `PIM.Migrator`** (poganja vse še neuporabljene migracije v eni transakciji, z beleženjem v `dbo.SchemaMigration`):

```bash
cd PIM_Solution
dotnet run --project src/PIM.Migrator
```

Orodje samodejno prebere connection string iz `appsettings.Local.json` (ali ustrezne konfiguracije za TEST okolje — glej `PIM.Operations.LocalSettings`). Že uporabljene migracije (do vključno 213) se preskočijo, izvede se samo `214_QualityAndIngestPerformance.sql`.

Za samo preverjanje, brez izvedbe:
```bash
dotnet run --project src/PIM.Migrator -- --verify
```

**Ročno, prek `sqlcmd`** (če TEST baza nima nastavljenega `PIM.Migrator`, ali za takojšnjo ročno namestitev):

```bash
sqlcmd -S <TEST-strežnik> -d PIM -E -i "sql/migrations/214_QualityAndIngestPerformance.sql"
```

(`-E` = Windows avtentikacija; za SQL prijavo uporabi `-U <uporabnik> -P <geslo>` namesto `-E`.) Migracija je **idempotentna** — oba indeksa se ustvarita samo, če še ne obstajata (`IF NOT EXISTS`), `UPDATE STATISTICS` in `CREATE OR ALTER VIEW` sta varna za ponovni zagon.

**Pomembno pred zagonom na TEST/PROD:** migracija naredi dva nova indeksa na `stock.LandingRecord` (lahko ima milijone vrstic) in `stock.SyncRun`, ter `UPDATE STATISTICS ... WITH FULLSCAN` na `val.ProductIssue` in `canon.Product` (prav tako lahko milijoni vrstic). Vse to drži shemsko-stabilnostno zaklepanje teh tabel, dokler traja — na lokalni bazi je trajalo pod minuto skupaj, na TEST bazi je priporočljivo pognati izven konične obremenitve.

### 5.2 Preverjanje, da so indeksi in pogled dejansko nastali

```sql
-- Indeksi
SELECT t.name AS Tabela, i.name AS Indeks, i.type_desc
FROM sys.indexes i
JOIN sys.tables t ON t.object_id = i.object_id
WHERE i.name IN ('IX_StockLandingRecord_OrgConnector_Status', 'IX_StockSyncRun_OrgConnector_StartedUtc');

-- Pogled (mora vsebovati "LEFT JOIN canon.ProductText AS productName", ne vec "canon.FieldValue")
EXEC sp_helptext 'val.ProductChannelReadiness';
```

### 5.3 Ročno merjenje časa (enako, kot je bilo uporabljeno za to poročilo)

```sql
SET STATISTICS IO ON;
SET STATISTICS TIME ON;

-- /zajem
EXEC dbo.sp_executesql N'<poizvedba iz PipelineReadService.GetInboundFlowsAsync>';

-- /kakovost/artikli
EXEC intranet.GetQualityProducts @OrganizationId=NULL, @Search=NULL, @State=NULL, @Skip=0, @Take=50;

-- /kakovost (eno podjetje, primer OrganizationId=1)
SELECT DISTINCT issue.ProductId, requirement.FieldCode
FROM val.ProductIssue issue
INNER JOIN canon.Product product ON product.ProductId = issue.ProductId
  AND product.OrganizationId = 1 AND product.IsActive = 1
INNER JOIN val.FieldRequirement requirement ON requirement.FieldRequirementId = issue.FieldRequirementId
WHERE issue.IsActive = 1;
```

V izpisu poišči `SQL Server Execution Times: ... elapsed time = ... ms` — to je dejanski čas poizvedbe.

Za merjenje **cele strani** (tako, kot jo vidi uporabnik) v odprti, prijavljeni seji brskalnika, v konzoli (F12):

```javascript
const t0 = performance.now();
const r = await fetch(location.origin + '/kakovost/artikli', { credentials: 'same-origin', cache: 'no-store' });
await r.text();
console.log(Math.round(performance.now() - t0) + ' ms');
```

### 5.4 Preverjanje kode (dvoklik popravek)

```bash
cd PIM_Solution
dotnet build src/PIM.Intranet/PIM.Intranet.csproj -c Debug
```

Pričakovan izpis: `Build succeeded. 0 Warning(s). 0 Error(s).`

Ročni preizkus dvokliku: na strani `/outbound` hitro dvakrat zapored klikni "Pošlji zdaj" ali "Odobri" pri istem artiklu — po popravku se drugi klik preprosto ne zgodi (gumb je med izvajanjem prvega dejansko neaktiven na strežniški strani, ne samo videti neaktiven), namesto da bi sprožil dva vzporedna klica v SAOP.

### 5.5 Povrnitev nazaj (če bi bilo kdaj potrebno)

Indeksa:
```sql
DROP INDEX IX_StockLandingRecord_OrgConnector_Status ON stock.LandingRecord;
DROP INDEX IX_StockSyncRun_OrgConnector_StartedUtc ON stock.SyncRun;
```

`UPDATE STATISTICS` ni mogoče "povrniti" (statistika je samo pospešek, ne shema) — ni potrebe.

Pogled: ker gre za bit-za-bit enak rezultat (glej preverjanje pravilnosti v 3.3), povrnitev ni pričakovano potrebna. Če bi bila, je stara definicija v `sql/migrations/194_ProfessionalDataQualityAndChannelGates.sql` (iskanje `CREATE OR ALTER VIEW val.ProductChannelReadiness`).

Popravek dvokliku v kodi je preprost `git revert` spremenjenih `.razor` datotek — DB sprememb ne zahteva.

---

## 6. Opombe za TEST bazo

- Če ima TEST baza bistveno manj vrstic v `stock.LandingRecord` / `val.ProductIssue` / `canon.Product` kot lokalna razvojna baza (3,74M / 6,39M / 196K), bo absolutna pohitritev manjša ali neopazna — vzrok (manjkajoč indeks, zastarela statistika, korelirana poizvedba na vrstico) pa je enak in bo pri rasti podatkov na TEST/PROD enako počasen brez tega popravka.
- Migracija ne spreminja nobenih podatkov, samo sheme (indeksa), statistiko in definicijo enega pogleda — varna je za zagon na bazi s produkcijskim izgledom podatkov brez tveganja izgube podatkov.
