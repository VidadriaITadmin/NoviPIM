# Dokumentacija celotnega sistema PIM (NoviPIM)

Za razvijalce in skrbnike. Stanje: **2026-09-03**, veja `feature/izhodi-erp-01-saop-polji`,
migracije **001–150**. Vse navedbe so povzete iz kode, SQL migracij, skript in obstoječih
dokumentov v tem repozitoriju; kjer je nekaj načrt ali odprta odločitev, je to izrecno
zapisano. Dokument ne vsebuje povezovalnih nizov, gesel ali poverilnic.

Pravila dela so v [`AGENTS.md`](../AGENTS.md) in se tu ne podvajajo. Ta dokument je zemljevid:
kaj sistem je, kje kaj živi in kako podatek potuje od SAOP do spletne trgovine.

---

## 1. Namen in obseg

NoviPIM je sistem za upravljanje podatkov o izdelkih (PIM) za **štiri podjetja** v eni bazi:
DEMO (1), IQLighting (2), Vidadria (3) in Ediito (4); skupaj približno 200.000 artiklov
(`STATUS.md`: katalog 196.531 artiklov, objavljenih 89.129 ob meritvi 2026-08-24).

Kaj sistem dela:

| Vloga | Kaj to pomeni v praksi |
|---|---|
| **Zajem** | bere SAOP (16 končnih točk), XML dobaviteljev Nowodvorski in Braytron, zaloge (SAOP, FTP, HTTPS) in delovne zvezke s spletnimi nazivi |
| **Kanonični katalog** | vse vire poravna v en model (`canon.*`), neodvisen od vira; preslikave in slovar so podatek, ne koda |
| **Kakovost** | validacijski profili z resnostjo in obsegom povedo, kaj blokira ERP in kaj splet; karantena za vhod, ki ga model ne sprejme |
| **Objava** | `val.Promote` prenese veljavne izdelke v potrjeni sloj `pim.*` |
| **Izhod ERP** | nadzorovan zapis nazaj v SAOP prek odhodne vrste (odobritev, poskus, echo, odklon) |
| **Izhod splet** | CSV datoteke za Magento iz registra profilov in stolpcev, s pravili, kaj sme na splet |
| **Nadzor** | teki, zdravje postopkov, alarmi, samodejni izklop po petih napakah |
| **Intranet** | Blazor Server aplikacija za vse zgoraj, v slovenščini, z vlogami |

Kaj sistem **ne** dela (danes): ne dostavlja datotek v Magento, ne piše v produkcijski SAOP
brez ročno vpisanega in omogočenega profila, ne kliče `GetItemDeliveryDate`, nima
zgodovinskih analitičnih modelov. Podrobno v §11.

Tehnologija: .NET 10, C#, Blazor Server, MS SQL Server. Ni Node, ni React. Edini dokaz, da
kaj deluje, je `scripts\run_tests.ps1` (§10).

---

## 2. Arhitektura

### 2.1 Sedem faz toka

Trajni produktni model iz `AGENTS.md` §2.1 in [`docs/PRODUKTNI_MODEL_PIM.md`](PRODUKTNI_MODEL_PIM.md):

| # | Faza | Kaj obsega | Sheme | Vstop v intranetu |
|---|---|---|---|---|
| 1 | **VHODI** | SAOP, dobaviteljski XML in datoteke; zajem, napake, preslikave polj, atributov, kategorij, vrednosti in prevodov | `raw`, `map` | `/zajem`, `/pravila` |
| 2 | **PIM** | kanonični in PIM-lastni podatki: izdelki, besedila, lastnosti, kategorije, mediji, cene, zaloga, stranke, partnerji; lastništvo in zgodovina | `canon`, `pim`, `stock`, `b2b` | `/izdelki`, `/mediji`, `/cene`, `/zaloge`, `/stranke` |
| 3 | **KAKOVOST** | validacijski profili, manjkajoča polja, karantena, pripravljenost za cilj | `val`, `raw` | `/kakovost` |
| 4 | **IZHODI ERP** | zapis nazaj v SAOP: odobritev, poskus, odgovor, echo, odklon | `out`, `dbo.IntegrationProfile` | `/saop`, `/outbound` |
| 5 | **IZHODI SPLET** | izvozni profili in CSV za spletne kanale; pokritost stolpcev, validacija, predogled | `out` | `/splet`, `/izvozi` |
| 6 | **OBVESTILA IN NADZOR** | alarmi, e-pošta, stopnjevanje, zdravje postopkov | `ops` | `/sistem/integracije`, `/sistem/urniki` |
| 7 | **UPRAVLJANJE IN ANALITIKA** | vloge, nastavitve, izvor in lastništvo, komercialna pravila; analitika je načrtovana | `sec`, `pim`, `canon` | `/nastavitve`, `/pravila`, `/sistem` |

Organizacija (`OrganizationId`) je obvezna meja podatkov v vseh shemah. Kanal in jezik sta
dodatni meji spletnih podatkov.

### 2.2 Komponente

```
                 ┌──────────────────────────── scripts\*.ps1 (načrtovana opravila) ─────────────────────────┐
                 │                                                                                           │
 SAOP API ──► PIM.KatalogWorker ─┐                                                                           │
 NW/BT XML ─► PIM.XmlFileWorker ─┤                                                                           │
 FTP/HTTPS ─► PIM.SourceFetchWorker ─► PIM.StockFileWorker ─┤                                                 │
 SAOP zaloga ► PIM.SaopStockWorker ─┘                        │                                                 │
                                                             ▼                                                 │
                                          ┌──────────── MS SQL: baza PIM ────────────┐                        │
                                          │ raw → map → canon → val → pim → out       │ ◄── PIM.Migrator       │
                                          │ stock, b2b, ops, sec, intranet            │                        │
                                          └───────────────┬───────────────────────────┘                        │
                                                          │                                                    │
      PIM.B2bWorker (CSV) ◄───────────────────────────────┤──────────────► PIM.OutboxDispatcher ──► SAOP (HTTP) │
      PIM.Watchdog / PIM.AlertDispatcher ◄────────────────┤                                                    │
      PIM.Intranet (Blazor Server, /PIM) ◄────────────────┘                                                    │
```

| Sklop | Pot | Vloga |
|---|---|---|
| Baza in migracije | `PIM_Solution\sql\migrations\NNN_*.sql`, `PIM_Solution\src\PIM.Migrator` | vsa shema, procedure, registri in semena; migrator sledi `dbo.SchemaMigration` s hashi |
| Domenske knjižnice | `PIM_Solution\src\PIM.B2b`, `PIM.Operations`, `PIM.Outbound`, `PIM.StockMapping`, `PIM.XmlMapping` | CSV pisalci, `OperationsRun` (utrip, `BeginRun`/`CompleteRun`), odhodne varovalke, preslikava zalog, XPath preslikava |
| Workerji | `PIM_Solution\workers\PIM.*` | run-once konzolni programi; sproža jih načrtovano opravilo ali skripta; prekrivanje preprečuje `sp_getapplock` |
| Intranet | `PIM_Solution\src\PIM.Intranet` | Blazor Web App, interaktivni strežniški način, `UsePathBase("/PIM")`, razvojno `http://127.0.0.1:5199` |
| Skripte | `scripts\*.ps1` | nočni tok, zalogovni cikel, nadzor, registracija opravil, testni zaganjalnik |
| Testi | `PIM_Solution\tests\PIM.F*` | 61 projektov: konzolni (`OutputType Exe`) in en xUnit (`PIM.ChangeTracking.Integration`) |

### 2.3 Workerji

| Worker | Piše v bazo | Vhod | Izhod | Ključna stikala |
|---|---|---|---|---|
| `PIM.KatalogWorker` | da | SAOP API (`PIM_SAOP_MODE=Live`) ali fixture | `raw.Inbox` → `map` → `canon` | `--full`, `--organizations`, `--max-parallel`, `--only-ingest`, `--map-run <RunId>`, `--znova-preslikaj <RunId>`, `--preslikaj-zaostanek` |
| `PIM.XmlFileWorker` | da | XML poljubnega dobavitelja (`PIM_XML_SOURCE_CODE`, `PIM_XML_ORGANIZATION_ID`, `PIM_XML_ROOT`) in delovni zvezki (`SPLET_XLSX`) | `raw.Inbox` → `map` → `canon` | `--map-run`, `--znova-preslikaj` |
| `PIM.SourceFetchWorker` | da (`ops`, `map.SourceFetchLocation`) | FTP (NW zaloga), HTTPS (BT) | datoteke v `PIM_Solution\data\prevzem\<VIR>\`; oznaki `.prenos` in `.pocakaj` | `--source`, `--target`, `--po-urniku`, `--samo-nastavitve` |
| `PIM.StockFileWorker` | da | NW CSV / BT XML | `stock.LandingRecord` → `stock.Snapshot`/`stock.Position` | `--file`, `--source`, `--organization-id`, `--date-format`, `--samo-preberi` |
| `PIM.SaopStockWorker` | da | SAOP `GetStocks` ali registrirani pogled (`stock.SaopProviderProfile`) | `stock.*` | `--organizations`, `--page-size`, `--base-url`, `--samo-nastavitve`, `--po-urniku` |
| `PIM.B2bWorker` | bere | `out.GetExportRows` | Magento CSV v mapo | `--export-magento --organization-id --output-dir`; `--export-profile <koda> --file-name <ime>` |
| `PIM.OutboxDispatcher` | da (`out`) | `out.OutboxMessage` | HTTP POST/PATCH samo na omogočen profil; eno sporočilo na zagon | — |
| `PIM.Watchdog` | da (`ops`) | `ops.IntegrationHealth`, `ops.ScheduleProfile` | `ops.Alert` | — |
| `PIM.AlertDispatcher` | da (`ops`) | odprti alarmi | e-pošta/webhook samo pri `PIM_ALERT_DELIVERY_ENABLED=true` | — |
| `PIM.FoundationWorker` | ne | — | prazen `BackgroundService` skelet | — |

`PIM.NwXmlWorker` ima samo `bin\` in `obj\`, ni v `PIM.sln` in ni worker. Vsi workerji berejo
povezavo iz `PIM_CONNECTION_STRING`; skripte jo pred zagonom preberejo iz korenske
`appsettings.Local.json`, če ni nastavljena. Tabela v `docs/WORKERS.md` z dne 13. 8. je pri
`B2bWorker`, `SaopStockWorker` in `StockFileWorker` zastarela — vsi trije danes pišejo oziroma
berejo bazo in tečejo v avtomatiki (§8).

---

## 3. Podatkovni model po shemah

Tok: `raw.Inbox` → `map.ExtractedValue` → `canon.*` → `val.*` → `pim.*` → CSV / outbox.
Sledi seznam shem s ključnimi tabelami (celoten seznam je izpeljan iz `CREATE TABLE` v migracijah).

### 3.1 `raw` — nespremenjen vhod

| Objekt | Vloga |
|---|---|
| `raw.Inbox` | ena vrstica na zajeto stran (vir, entiteta, stran, hash vsebine, celoten odgovor); statusi `Pending`, `Processed`, `Quarantined`; `RunId` kaže na `ops.PipelineRun`; enoličnost (vir, entiteta, stran, hash) preprečuje dvojni zajem |

### 3.2 `map` — konfiguracija virov in preslikav

| Objekt | Vloga |
|---|---|
| `map.SourceConnector` | register virov (`SAOP`, `NW_XML`, `BT_XML`, `NW_STOCK`, `BT_STOCK`, `SAOP_*_STOCK`, `SPLET_XLSX`) po podjetju |
| `map.EntityMapping`, `map.FieldMapping` | element vira (XPath) → kanonično polje; `IsRequired` pri zajemu velja samo za `Product.ItemID` |
| `map.FieldTransform`, `map.ValueLookup` | pretvorbe (`TRIM`, `NUMBER`, `UNIT`, `LOOKUP` …) in slovar vrednosti (`Domain '*'` = povsod; ožja domena zmaga) |
| `map.MissingTranslation`, `map.UnmappedValue`, `map.MissingCategoryMap` | delovni seznami, ne napake |
| `map.CategoryPathMap`, `map.SourceCategory` | dobaviteljeva pot kategorije → naša kategorija; register dobaviteljevih kategorij, ki se polni sam |
| `map.AttributeMap`, `map.SourceAttribute`, `map.SourceAttributeDiscovery` | register dobaviteljevih lastnosti in njihova preslikava v `canon.AttributeDefinition` |
| `map.ExtractedValue` | izluščene vrednosti s sledjo `RawValue` |
| `map.Watermark`, `map.StockIdentityRule`, `map.SourceFetchLocation`, `map.PipelineStep`, `map.B2bFieldMapping` | vodni žig delta zajema, identiteta zaloge (šifra/EAN), mesto prevzema (mapa/FTP/HTTPS), koraki cevovoda, preslikave B2B |

Procedure: `map.ProcessRawInbox` (množično od 044), `map.ApplyValueTransforms`,
`map.ResolveProductCategories`, `map.ReopenRunForMapping` (094).

### 3.3 `canon` — kanonični katalog

| Objekt | Vloga |
|---|---|
| `canon.Product` | izdelek po podjetju: `ItemID`, `EAN`, `IsActive`, `WebPublish`, `ValidationStatus`, `ItemGroup`, `Department` … |
| `canon.ProductText` | besedila; `TextType` je zaprt seznam: `WEB_TITLE`, `TITLE_ERP`, `TITLE_ERP2`, `SEARCH_NAME` (143), družina `DESCRIPTION%`; jezik v `LanguageCode` |
| `canon.ProductAttribute`, `canon.AttributeDefinition`, `canon.AttributeTranslation` | lastnosti izdelka; stabilna koda atributa, imena po jezikih |
| `canon.ProductCategory`, `canon.Category`, `canon.CategoryTranslation`, `canon.WebSite` | kategorije po drevesih (`svetila_si`, `videlektro`), prevodi, spletne strani s stolpcem predloge |
| `canon.CategoryAttributeSet` (147) | nabor atributov po (drevo, kategorija, atribut) z ravnjo `REQUIRED` / `RECOMMENDED` / `EXCLUDED` |
| `canon.ProductMedia`, `canon.ProductDocument` | slike (vloga `PRIMARY`, `SortOrder`) in dokumenti po vlogi |
| `canon.ProductCommercial`, `canon.ProductPrice`, `canon.ProductStockPolicy`, `canon.ProductStockAccounting`, `canon.ProductPlanning` | trgovinski podatki, cene po cenikih, pravila zaloge, konti, planiranje |
| `canon.Warehouse`, `canon.Language`, `canon.Codebook` | šifranti: skladišča (šifra gre v zahtevo SAOP, ime je za prikaz), jeziki, valute/ceniki/tehnološki proces |
| `canon.FieldValue` (pogled) | katalog, sploščen v pare `(FieldCode, Value)`; bere ga validacija in kanonična pot izvoza |
| `canon.CategoryAttributeEffective` (TVF, 147) | učinkoviti nabor po verigi prednikov: najbližja vrstica zmaga, `EXCLUDED` pri otroku razveljavi `REQUIRED` pri staršu |

Sledljivost (028–038): triggerji nad `canon.Product`, `ProductCommercial`, `ProductText`,
`ProductAttribute`, `ProductMedia` pišejo `pim.ProductFieldHistory`; kontekst spremembe
nastavi `pim.SetChangeContext` na isti povezavi, brez njega je vir `NEZNANO`.

### 3.4 `val` — validacija

| Objekt | Vloga |
|---|---|
| `val.ValidationProfile` | profil s `Scope`, `BlocksErp`, `BlocksWeb` in od 146 `CategoryTreeCode` (`WEB_svetila_si` → `svetila_si`, `WEB_videlektro` → `videlektro`) |
| `val.FieldRequirement` | zahteva polja s `Severity` (`ERROR`/`WARNING`), `IsActive` in od 147 obsegom `CategoryTreeCode`/`CategoryCode`; enoličnost `UQ_FieldRequirement_ProfileFieldScope` (148) |
| `val.ProductValidationState` | stanje izdelka po profilu (`VALID`/`INVALID`, `Completeness`) |
| `val.ProductIssue` | odprte pomanjkljivosti |

Procedure: `val.RunValidation @OrganizationId` (upošteva obseg zahtev, 147), `val.Promote`
(objava v `pim.*`), `val.SyncFieldRequirementsFromExportProfiles`. Podrobnosti o profilih v
[`docs/VALIDACIJA.md`](VALIDACIJA.md) in §7.1.

### 3.5 `pim` — potrjeni katalog in PIM-lastni podatki

| Objekt | Vloga |
|---|---|
| `pim.Product`, `pim.ProductText`, `pim.ProductAttribute`, `pim.ProductCategory`, `pim.ProductCategoryOverride`, `pim.ProductMedia`, `pim.ProductPrice`, `pim.ProductCommercial` | objavljeni sloj, ki ga bere spletni izvoz |
| `pim.FieldOwnership`, `pim.ProductChangeBatch`, `pim.ProductFieldHistory` | lastnik polja (`PIM`/`SAOP`/`SHARED`), paket spremembe, zgodovina |
| `pim.TitleRule` (149) | pravila za sestavo spletnih nazivov (§7.3) |
| `pim.CheckThreshold` (150) | pragovi poslovnih preverb (`FAKTOR_MARZE`, privzeto 2,00; po podjetju ali privzeto) |
| `pim.CustomerWebProfile`, `pim.CustomerContact`, `pim.CustomerBranch`, `pim.CustomerNote`, `pim.CustomerTypeCatalog`, `pim.CustomerTypeMagentoGroup`, `pim.CustomerValueDiscountTier` | spletni profil stranke, ročni kontakti (140), poslovne enote, zaznamki, tip stranke → Magento skupina |
| `pim.ValueDiscountTier`, `pim.PackagingDiscountCatalog`, `pim.ProductPackagingDiscount`, `pim.ShippingRuleCatalog` | vrednostni in pakirni popusti, pravila dostave |

Procedure: `pim.SaveProductTexts`, `pim.SaveProductAttributes` (111; zavrneta polje, ki ga piše
SAOP, z napako 52402), `pim.UndoProductField`, `pim.UndoProductBatch`, `pim.ComposeTitle`,
`pim.ResolveTitleRule`, `pim.PreviewTitleRules`, `pim.ApplyTitleRules`, `pim.SaveTitleRule`,
`pim.SaveCheckThreshold`.

### 3.6 `b2b` — stranke iz SAOP

`b2b.Customer`, `b2b.CustomerItem`, `b2b.GroupDiscount`, `b2b.GroupDiscountOverride`,
`b2b.CustomerItemGroupDiscount`, `b2b.CustomerPackagingDiscountOverride`, `b2b.LandingRecord`,
`b2b.MappingRejection`, `b2b.AuditLog` (revizijska sled vseh zapisovalnih procedur intraneta).
Pogled `canon.PartnerName` daje ime partnerja za šifro dobavitelja/proizvajalca.

### 3.7 `out` — izvozne pogodbe in odhodna vrsta

| Objekt | Vloga |
|---|---|
| `out.ExportProfile` | profil (`ProfileCode`, `ChannelCode`, `EntityType`, `ValueSourceCode` = `CANON`/`PIM_PRODUCT`/`PIM_CUSTOMER` od 142, `RequireWebValid` od 146) |
| `out.ExportColumn` | stolpec profila: `ColumnCode`, `OutputColumnName`, `CanonicalFieldCode`, `SortOrder`, `IsRequired`, `IsActive` |
| `out.ExportPriceList` (083) | kateri cenik podjetja gre v stolpec `Cena B2B` / `Cena B2C` |
| `out.ExportStockSource` (146) | register virov zaloge za izvoz: `BASE` / `ADD` / `SUPPLIER` po podjetju (§5.3) |
| `out.OutboxMessage`, `out.OutboxAttempt`, `out.OutboundBatch`, `out.SaopDocument`, `out.SaopItemAssignment` | odhodna vrsta, poskusi, paketi, dokument SAOP, uskladitev nove šifre |
| `out.OwnershipPolicy`, `out.SaopXmlField`, `out.SaopAddDefault` | kdo sme pisati polje pri cilju; pogodba XML polj SAOP; privzetki za nov artikel |

Procedure: `out.GetExportRows` (142, 146, 147), `out.GetStockExportRows` (150),
`out.MagentoNumber` (`0.####`), `out.EnqueueMessage`, `out.ApproveMessage`, `out.CancelMessage`,
`out.RetryMessage`, `out.RequeueOutboxMessage` (138), `out.ClaimMessage`, `out.CompleteAttempt`,
`out.VerifyEcho`, `out.EnqueueSaopItemChanges`, `out.GetSaopXmlContract`.

### 3.8 `stock` — zaloga

| Objekt | Vloga |
|---|---|
| `stock.SaopProviderProfile` (065) | katera pot do SAOP se uporabi po podjetju: `SAOP_GETSTOCKS` ali `SAOP_REGISTERED_VIEW`; `Priority`, `Enabled`, `RegisteredViewId`, `WarehouseSelectionMode` |
| `stock.SyncRun` | tek zaloge (`Endpoint`, `HttpStatus`, `RecordsRead/Applied/Quarantined`) |
| `stock.Snapshot` | posnetek (podjetje, konektor, čas posnetka) — enoličen; ista datoteka je isti posnetek |
| `stock.LandingRecord` | vhodna vrstica kot besedilo; od 145 tudi `OrderedQuantityText`, `ForShipmentQuantityText`, `AvailableQuantityText`, `SupplierOrderedQuantityText` |
| `stock.Position` | pozicija: `Quantity`, `AvailabilityDate`, `IncomingQuantity`, `MatchKey` (`ItemID`/`EAN`/`Unmatched`), `MatchedProductId`; od 145 `OrderedQuantity`, `ForShipmentQuantity`, `AvailableQuantity`, `SupplierOrderedQuantity` |
| `stock.UnmatchedPosition` | karantena zaloge z razlogom |

`stock.ApplyLandingRecord` (088, 145) ujame artikel **samo v istem podjetju** in dodatne
količine pretvori s `TRY_CONVERT` (neveljavno besedilo da `NULL`, ne karantene).

### 3.9 `ops` — teki, zdravje, alarmi

| Objekt | Vloga |
|---|---|
| `ops.ScheduleProfile` | ali postopek sme teči in kako pogosto: `IsEnabled`, `IntervalSeconds`, `NextScheduledUtc`, `MaxConsecutiveFailures` (118), `UpdatedBy` |
| `ops.IntegrationHealth` | **stanje**: ena vrstica na (podjetje, postopek), `LastHeartbeatUtc`, `Status`, `LastErrorRedacted`; edini vir alarma |
| `ops.PipelineRun` | **zgodovina**: od 144 jo piše `ops.BeginRun`/`ops.CompleteRun` za vse postopke; statusi `Pending`, `Running`, `Succeeded`, `Warning`, `Failed`, `TimedOut`, `Cancelled`, `Abandoned` |
| `ops.ErrorLog` | napake s `RunId`; od 144 jo polni `ops.CompleteRun` |
| `ops.Alert`, `ops.AlertRecipientConfig`, `ops.AlertDelivery` | alarmi, prejemniki, dostave |
| `ops.DeadLetterQueue`, `ops.OutboundEvent`, `ops.PipelineStepLog`, `ops.DeploymentRun` | mrtva pošta vhoda, dogodki odhodne poti, koraki teka, namestitve |

`ops.RunWatchdog` dela izključno nad `ops.IntegrationHealth` in `ops.ScheduleProfile`.

### 3.10 `sec` — uporabniki in vloge

`sec.LocalUser` (`AuthSource` = `LOCAL` s PBKDF2-SHA256 ali `DOMAIN` prek Active Directory),
`sec.Role` (`ADMIN`, `CATALOG_EDITOR`, `COMMERCIAL`, `VIEWER`), `sec.LocalUserRole`.
`sec.Navigation*` so zgodovinski bralni model; meni je v kodi (`PimNavigation.cs`).

### 3.11 `intranet` — bralni in zapisovalni modeli za UI

Procedure so imenovane po strani: `intranet.GetDashboard`, `GetProductList`, `GetProductCard`
(15 naborov), `GetProductOrigin`, `GetQualityIssues`, `GetQualityOverview`, `GetStockPositions`,
`GetStockOverview`, `GetExportReadiness` (od 146 z `WebSiteMissingCount`, `WebInvalidCount`,
`WebExportableCount`), `GetWebExportRows`, `GetCategoryAttributeSet`, `GetProductAttributeSet`
(147), `GetTitleRules` (149), `GetPriceChecks`, `GetStockChecks`, `GetCheckThresholds`,
`GetPriceListSheet` (150), `GetSchedules`, `GetSystemIntegrations`, `GetOutboundMessages`,
`GetCustomerCard` … Zapisovalne: `intranet.AcknowledgeAlert`, `intranet.ResolveAlert`; ostale
zapisovalne poti so v `pim.*`, `b2b.*`, `out.*`, `canon.*` in vse dobijo `@ChangedBy`/`@Actor`.

### 3.12 `dbo`

`dbo.OrganizationConfig` (štiri podjetja), `dbo.IntegrationProfile` (cilj, endpoint, HTTP
operacija, odobritev; privzeto `IsEnabled = 0`), `dbo.SchemaMigration`, `dbo.Language`.

---

## 4. Tok podatkov od SAOP do spleta

### 4.1 Zajem

| Vir | Worker | Kako | Kaj nastane |
|---|---|---|---|
| SAOP katalog (16 končnih točk: artikli, opisi, cene, nazivi, lastnosti, pravilo zaloge, skladišča, jeziki, valute, ceniki, tehnološki proces, konti, planiranje, stranke, artikel pri stranki, popusti) | `PIM.KatalogWorker` | `PIM_SAOP_MODE=Live`; polni zajem `--full` prvi dan meseca, sicer delta prek `map.Watermark` | `raw.Inbox` po straneh |
| Nowodvorski XML | `PIM.XmlFileWorker` (`NW_XML`) | datoteka v mapi (ročni prenos, dobavitelj nima strojnega dostopa) | `raw.Inbox` |
| Braytron XML | `PIM.XmlFileWorker` (`BT_XML`) | HTTPS, prevzame `PIM.SourceFetchWorker`; en prenos na 180 minut, prevzemnik čakalni čas spoštuje sam | `raw.Inbox` |
| Spletni nazivi (delovni zvezki) | `PIM.XmlFileWorker` (`SPLET_XLSX`) | samo, če je podana mapa | `raw.Inbox` |
| Zaloga NW (CSV prek FTP), BT (XML prek HTTPS) | `PIM.SourceFetchWorker` + `PIM.StockFileWorker` | vsakih 5 minut, za vsa štiri podjetja | `stock.*` |
| Zaloga SAOP | `PIM.SaopStockWorker` | vsakih 5 minut; pot po `stock.SaopProviderProfile` (§5) | `stock.*` |

Isti paket se ne zajame dvakrat (enoličnost v `raw.Inbox`); ponoven zagon nespremenjene
datoteke ni okvara. Podrobno v [`docs/ZAJEM-SAOP.md`](ZAJEM-SAOP.md) in [`docs/WORKERS.md`](WORKERS.md).

### 4.2 Preslikava

`map.ProcessRawInbox` prebere `Pending` strani, po `map.EntityMapping`/`map.FieldMapping`
izlušči vrednosti v `map.ExtractedValue`, `map.ApplyValueTransforms` jih pretvori in prevede
(`map.FieldTransform`, `map.ValueLookup`), nato gredo z `MERGE` v `canon.*`. Kar model ne
sprejme, gre stran v karanteno (`raw.Inbox.Status = Quarantined`, `FailureReason`).

Zaostanek po zasnovi: ko se preslikava dopolni, so strani že `Processed`. Zato obstajajo
`--znova-preslikaj <RunId>` (strani nazaj na `Pending`, `map.ReopenRunForMapping`) in
`--preslikaj-zaostanek` (vsi zagoni s `Pending` vrsticami, brez klica na SAOP), ki ga nočni tok
požene pred objavo.

Kategorije dobaviteljev se pojavijo same v `map.SourceCategory`; preslikava v naše drevo je
vrstica `map.CategoryPathMap`, neznane poti so v `map.MissingCategoryMap`. Braytronove
kategorije so namenoma nepreslikane, dokler ni odločitve (`TASKBOARD.md`).

### 4.3 Validacija

`val.RunValidation @OrganizationId` gre po aktivnih profilih in zahtevah nad `canon.FieldValue`:

- `ERROR` postavi profil na `INVALID`, `WARNING` samo zabeleži `val.ProductIssue`;
- `canon.Product.ValidationStatus` posluša samo profile z `BlocksErp = 1` ali `BlocksWeb = 1`
  in samo zahteve `ERROR`;
- zahteva z obsegom (147) velja samo za izdelke v tisti kategoriji ali pod njo, če je ni
  prekril `EXCLUDED` nižje.

### 4.4 Objava

`val.Promote @OrganizationId` prenese veljavne izdelke v `pim.*` (potrjeni sloj). Spletni
izvoz bere izključno `pim.*`, `b2b.*` in `stock.*`. Nočni tok požene validacijo in objavo za
vsa štiri podjetja po vseh zajemih (§8.1, korak 7).

### 4.5 Kaj gre na splet (pravila 146)

`out.GetExportRows` za produktne profile uporabi tri pravila:

1. **Spletna stran.** Izdelek gre v izvoz samo, če ima vsaj eno vrstico v `pim.ProductCategory`
   — stolpec »Spletne strani« ni prazen. Velja brezpogojno, tudi v predogledu.
2. **Objava.** `canon.Product.WebPublish = 1`.
3. **Čisti podatki** (`out.ExportProfile.RequireWebValid = 1`). Izdelek gre na spletno stran S
   samo, če je `VALID` v vsakem validacijskem profilu z `BlocksWeb = 1`, ki velja za S: profil
   brez drevesa (`SHARED_CORE`) velja za vse strani, profil z drevesom (`WEB_svetila_si`,
   `WEB_videlektro` po `val.ValidationProfile.CategoryTreeCode`) samo za svojo. Stolpec
   »Spletne strani« in stolpci kategorij nosijo samo strani, za katere je izdelek veljaven.

Katero pravilo blokira, pove `/kakovost`; izvoz ga samo upošteva. `intranet.GetExportReadiness`
vrne `WebSiteMissingCount` (objavljen, brez spletne strani), `WebInvalidCount` (s stranjo, a
blokiran) in `WebExportableCount` (v datoteki); vse tri kaže `/splet`.

Izmerjeno 2026-09-02 po uvedbi pravil (polni izvoz `--export-magento`, ki od tedaj uporablja
samo objavljene izdelke):

| Podjetje | Vrstic pred 146 | Vrstic po 146 |
|---|---|---|
| 2 (IQLighting) | 43.504 | 1.957 |
| 3 (Vidadria) | 10.595 | 2.368 |

### 4.6 Izvoz

`PIM.B2bWorker` in intranet bereta **isto proceduro** `out.GetExportRows`, zato predogled na
`/splet/izvoz` in datoteka, ki odide, ne moreta razhajati. Podrobnosti o profilih in datotekah
v §6.

---

## 5. Zaloga

### 5.1 Viri

| Vir | Podjetja | Pot | Konektor |
|---|---|---|---|
| SAOP `api/Stock/GetStocks` | 1, 2, 4 (in 3 kot rezerva, `Priority 10`) | šifre skladišč iz `canon.Warehouse` (`WarehouseSelectionMode = ActiveFromRegister`), glava `OrganisationId` | `SAOP_DEMO_STOCK`, `SAOP_IQLIGHTING_STOCK`, `SAOP_EDIITO_STOCK` |
| SAOP registrirani pogled (145) | 3 (Vidadria), `Priority 5` → worker ga izbere sam | `POST api/registeredviews/data` z XML telesom, `RegisteredViewId = 16c34ea5-b65d-4954-a699-40f47af11243`, stranicenje po 1000 | `SAOP_VIDADRIA_STOCK` |
| Nowodvorski CSV | 1–4 | FTP → `data\prevzem\NW_STOCK\` | `NW_STOCK` |
| Braytron XML | 1–4 | HTTPS → `data\prevzem\BT_STOCK\` | `BT_STOCK` |

IQLighting ostane na `GetStocks` nad skladiščem `0000001` (Glavno skladišče Brnčičeva 13),
ker SAOP registriranega pogleda za IQ ni omogočil.

### 5.2 Registrirani pogled: pet količin

Iz vsake vrstice registriranega pogleda se vzame pet števil in shrani v `stock.Position`:

| Stolpec pogleda | `stock.Position` | Magento stolpec (koda) |
|---|---|---|
| `TrenutnaZalogaL` | `Quantity` | 43 »VID trenutna zaloga« (`Stock.ErpCurrent`) |
| `NarocenaKolicina` | `OrderedQuantity` | 44 (`Stock.ErpOrdered`) |
| `ZaOdpremoKolicina` | `ForShipmentQuantity` | 45 (`Stock.ErpForShipment`) |
| `RazpolozljivaKolicina` | `AvailableQuantity` | 46 (`Stock.ErpAvailable`) |
| `NarocenaKolicinaDobaviteljem` | `SupplierOrderedQuantity` | 47 (`Stock.ErpSupplierOrdered`) |

Pri virih, ki teh količin ne poznajo (`GetStocks`, NW, BT), so stolpci `NULL`.
`intranet.GetStockPositions` jih vrne, `/zaloge` jih pokaže.

### 5.3 Register virov zaloge za izvoz (`out.ExportStockSource`, 146)

Zaloga v izvozni datoteki podjetja se sestavi iz posnetkov, ki jih našteje register:

| Podjetje izvoza | Vir | Posnetek podjetja | Prispevek | Oznaka skladišča |
|---|---|---|---|---|
| 3 Vidadria | `SAOP_VIDADRIA_STOCK` | 3 | `BASE` | Glavno skladišče Rakovnik 9a |
| 3 Vidadria | `SAOP_IQLIGHTING_STOCK` | 2 | `ADD` | Glavno skladišče Brnčičeva 13 |
| 3 Vidadria | `NW_STOCK`, `BT_STOCK` | 3 | `SUPPLIER` | — |
| 2 IQLighting | `SAOP_IQLIGHTING_STOCK` | 2 | `BASE` | Glavno skladišče Brnčičeva 13 |
| 2 IQLighting | `SAOP_VIDADRIA_STOCK` | 3 | `ADD` | Glavno skladišče Rakovnik 9a |
| 2 IQLighting | `NW_STOCK`, `BT_STOCK` | 2 | `SUPPLIER` | — |
| 1 DEMO, 4 Ediito | lastni `SAOP_*_STOCK` + `NW_STOCK`, `BT_STOCK` | isto podjetje | `BASE`, `SUPPLIER` | — |

Pravila seštevka:

- seštevek je po **šifri artikla (`ItemID`)**, ker je šifra ključ artikla na spletu
  (`docs/EN_ARTIKEL_VEC_PODJETIJ.md`); simetričen vpis za podjetji 2 in 3 zagotovi, da obe
  datoteki pokažeta isto številko za isti artikel;
- »VID trenutna zaloga« = vsota `Quantity`; »VID razpoložljiva količina« = vsota
  `COALESCE(AvailableQuantity, Quantity)`; naročena, za odpremo in naročena dobaviteljem so
  vsote, kjer vir to pozna;
- negativna ERP zaloga gre ven kot 0;
- stolpci dobavitelja (50 `Stock.SupplierQuantity`, 51 `Stock.SupplierIncoming`,
  52 `Stock.SupplierDate`) pridejo iz `SUPPLIER` vrstic (NW: količina, prihajajoča količina,
  datum; BT: količina);
- stolpec 53 »Skladišče« (`Stock.Warehouse`) je oznaka iz registra, npr. »Glavno skladišče
  Rakovnik 9a + Glavno skladišče Brnčičeva 13«;
- stolpca 48 in 49 (»VID datum dobave«, »VID koli. prihodnjih dobav«) ostaneta **brez vira**,
  ker končna točka `GetItemDeliveryDate` v NoviPIM ni zajeta (§11).

Isti register uporablja `intranet.GetPriceListSheet` (150) za zalogo v tiskanem ceniku.

### 5.4 Izvoz zaloge na zahtevo (150)

`out.GetStockExportRows @OrganizationId, @Source (ERP | DOBAVITELJ | VSE), @OnlyWeb, @Skip,
@Take, @TotalCount OUTPUT` vrne pozicije podjetja iz aktivnih posnetkov. Intranet jo pretočno
piše na `GET /izvoz/zaloge.csv?podjetje=<id>&vir=ERP|DOBAVITELJ|VSE&splet=0|1`; gumbi so na
`/zaloge`. Ime datoteke: `PIM_zaloga_<podjetje>_<vir>_<yyyyMMdd_HHmm>.csv`.

---

## 6. Spletni izvoz

### 6.1 Profili

| `ProfileCode` | Kanal | Entiteta | Stolpcev | `ValueSourceCode` | `RequireWebValid` | Migracija |
|---|---|---|---|---|---|---|
| `MAGENTO_PRODUCTS` | `MAGENTO` | `PRODUCTS` | 213 | `PIM_PRODUCT` | 1 | 045, 142, 146, 147 |
| `MAGENTO_CUSTOMERS` | `MAGENTO` | `CUSTOMERS` | 19 | `PIM_CUSTOMER` | — | 045, 142 |
| `MAGENTO_STOCK_PRICES` | `MAGENTO` | `PRODUCTS` | 14 | `PIM_PRODUCT` | **0** | 146 |
| `WEB_B2C_PRODUCTS` | `SVETILA_SI_B2C` | `PRODUCTS` | 7 | `CANON` | 1 | 005 |
| `ERP_L1` | `ERP` | `PRODUCTS` | 9 | `CANON` | 1 | 005 |
| `CUSTOMERS_B2B`, `PRODUCTS_B2B`, `SHIPPING_B2B` | `B2B` | — | 13 / 6 / 6 | — | — | 020 |

Oblika je register, ne koda: nov kanal = nova vrstica `out.ExportProfile` s stolpci; premik
stolpca = `UPDATE SortOrder`; drug vir = `UPDATE CanonicalFieldCode`; izklop = `IsActive = 0`.
Glava je ključ za uvoz v Magento (050): imena glav so enolična in brez robnega presledka.
`PIM.F7.MagentoExportTests` preverja, da se register in predloga `MagentoCsvContract` nista razšla.

### 6.2 Kje stolpci `MAGENTO_PRODUCTS` dobijo vrednosti

| Skupina stolpcev | Vir |
|---|---|
| identiteta, nazivi, opisi, teže, mere | `pim.Product`, `pim.ProductText`, `pim.ProductCommercial` |
| kategorije (24–27) | `pim.ProductCategory` ⋈ `canon.WebSite` (spletna stran → stolpec) ⋈ `canon.CategoryPathTranslated`; od 146 samo strani, za katere je izdelek veljaven |
| cene (28–29) | `pim.ProductPrice` po `out.ExportPriceList` (cenik podjetja, `ValidFrom <= zdaj`) |
| slike, dokumenti | `pim.ProductMedia`, `canon.ProductDocument` |
| zaloga 43–47, 50–53 | `stock.Position` po `out.ExportStockSource` (§5.3) |
| 48–49 dobavni roki | **brez vira** (`GetItemDeliveryDate` ni zajet) |
| atributi 54–213 (`Attr.<koda>`) | `pim.ProductAttribute`; od 147 samo atributi iz nabora kategorije, kadar je nabor določen, sicer vsi |

### 6.3 Hitri profil `MAGENTO_STOCK_PRICES`

Šifra, EAN, ceni, DDV in zaloga — 14 stolpcev, `RequireWebValid = 0`. Namenoma ne gre skozi
validacijo, vsebuje pa samo izdelke, ki so že na spletu (spletna stran + objava). Piše ga
`scripts\Zaloga-cikel.ps1` vsakih 5 minut:

```
PIM.B2bWorker --export-profile MAGENTO_STOCK_PRICES --organization-id <org>
              --output-dir izvoz\magento\<org> --file-name magento-stock-prices.csv
```

Odločitev uporabnika (2026-08-24, 2026-09-02): izdelki na uro oziroma ponoči, cene in zaloge
ločeno in pogosto, cilj 5 minut.

### 6.4 Datoteke

| Datoteka | Kdo | Kdaj |
|---|---|---|
| `izvoz\magento\<org>\katalog.csv` (213 glav) in `stranke.csv` (19 glav) | `PIM.B2bWorker --export-magento` | nočni tok, korak 8 |
| `izvoz\magento\<org>\magento-export.complete` | isti ukaz | oznaka, da je par datotek celovit (ID zagona, čas UTC, števci) |
| `izvoz\magento\<org>\magento-stock-prices.csv` (14 glav) | `PIM.B2bWorker --export-profile` | vsakih 5 minut |
| `PIM_splet_<profil>_<yyyyMMdd_HHmm>.csv` | intranet `GET /izvoz/splet-na-zahtevo?podjetje=&profil=&koda=&spletisce=&objavljeni=&isci=` | na klik z `/splet/izvoz` |
| `PIM_zaloga_<org>_<vir>_<čas>.csv` | intranet `GET /izvoz/zaloge.csv` | na klik z `/zaloge` |
| `/izvoz/izdelki.csv`, `/izvoz/izdelki.xlsx` | intranet | seznam izdelkov z istimi filtri kot `/izdelki`; predloga `saop` ima stolpce iz `out.SaopXmlField` |

Par `katalog.csv`/`stranke.csv` je nedeljiv: najprej `.tmp`, prejšnji par v
`.prej`, zamenjava pod ključavnico `.magento-export.lock`. Datoteke so UTF-8 brez BOM, LF;
`stranke.csv` je v razvojni bazi prazna z glavo, ker nobena stranka nima
`WebEnabled = 1` (podatek, ne okvara).

**Dostava v Magento ni implementirana** — datoteka nastane v mapi, način dostave (mapa / FTP /
HTTP) ni določen (§11).

---

## 7. Pravila, ki jih ureja uporabnik

Vsa pravila so vrstice v bazi. Zapisovalne poti pišejo revizijo v `b2b.AuditLog` oziroma
`pim.ProductFieldHistory`.

### 7.1 Validacija (`/pravila/validacija`, `/kakovost`)

| Profil | Obseg | Blokira ERP | Blokira splet | `CategoryTreeCode` |
|---|---|---|---|---|
| `SHARED_CORE` | `SHARED` | da | da | — (velja za vse strani) |
| `ERP_L1_SLO`, `ERP_L1_EU`, `ERP_L1_THIRD` | `ERP` | da | ne | — |
| `COMMERCIAL_L2` | `COMMERCIAL` | ne | ne | — |
| `WEB_svetila_si` | `WEB` | ne | da | `svetila_si` |
| `WEB_videlektro` | `WEB` | ne | da | `videlektro` |

Zahteva (`val.FieldRequirement`) ima polje, resnost (`ERROR`/`WARNING`), `IsActive` in od 147
obseg (drevo, kategorija). Zahteva se ne briše, ker odprte napake kažejo nanjo; umik je izklop.
Podrobno v [`docs/VALIDACIJA.md`](VALIDACIJA.md).

### 7.2 Nabor atributov po kategoriji (`/nastavitve/kategorije` → gumb »Atributi«)

`canon.CategoryAttributeSet`: vrstica na (drevo, kategorija, atribut) z ravnjo `REQUIRED`,
`RECOMMENDED` ali `EXCLUDED`. Dedovanje navzdol po drevesu, najbližja vrstica zmaga
(`canon.CategoryAttributeEffective`). `canon.SaveCategoryAttributeSet` hkrati vzdržuje zahteve
v `val.FieldRequirement` z obsegom: `REQUIRED` → `ERROR`, `RECOMMENDED` → `WARNING`, profil je
spletni profil drevesa. Učinki:

- `val.RunValidation` upošteva obseg;
- `out.GetExportRows` izvozi samo atribute iz nabora, kadar kategorija izdelka nabor določa;
  izdelek brez nabora obdrži vse;
- kartica izdelka (`/izdelki/{id}`) skupinira lastnosti po naboru
  (`intranet.GetProductAttributeSet`); stran kategorij bere `intranet.GetCategoryAttributeSet`;
- pregled celega drevesa (koliko in katere atribute ima katera kategorija, svetila in videlektro
  posebej) z množičnim urejanjem je na `/nastavitve/nabori-atributov` (170:
  `intranet.GetCategoryAttributeSetTrees`, `intranet.GetCategoryAttributeSetOverview`,
  `canon.SaveCategoryAttributeSetBulk` — koda ali slovensko ime, `canon.CopyCategoryAttributeSet`).

Migracija 148 je odstranila stari enolični indeks `UQ_FieldRequirement_ProfileField`, ki je
prvi vnos v nabor podrl z napako 2601; ostane `UQ_FieldRequirement_ProfileFieldScope`.

### 7.3 Pravila za spletne nazive (`/pravila/nazivi`)

`pim.TitleRule`: `RuleCode`, `CategoryTreeCode`, `CategoryCode`, `LanguageCode` (NULL = vsi
jeziki), `Template`, `Separator`, `IsActive`, `SortOrder`. Obseg: podkategorije pravilo
podedujejo, najbližje zmaga; pravilo brez kategorije je privzeto za drevo, brez drevesa za vse.

Žetoni predloge: `{ItemID}` `{ErpName}` `{WebName}` `{Manufacturer}` `{Category}`
`{Category:N}` `{Attr:<ime>}`.
Modifikatorji (ločilo `|`): `omitIf:<niz>`, `onlyIf:<niz>`, `omitIfAttr:<ime>~<niz>`,
`onlyIfAttr:<ime>~<niz>`, `unit:<enota>`, `years`, `lower`, `upper`, `prefix:<niz>`,
`suffix:<niz>`.

Pravila sestave (`pim.ComposeTitle`): prazen žeton izpade, presledki se strnejo, vrednost, ki je
že v nazivu, se ne ponovi, prva črka je velika. Jeziki: ime kategorije iz
`canon.CategoryTranslation` (padec na slovensko), vrednost atributa v jeziku, sicer angleška
vrednost prevedena prek slovarja `map.ValueLookup` (Domain `*`, SL/DE/HR), sicer izvorna;
ERP naziv `TITLE_ERP.<jezik>`, sicer slovenski; `years` sklanja (`pim.TitleYears`:
sl leto/leti/leta/let, en year/years, de Jahr/Jahre, hr godina/godine).

Zapis: `pim.PreviewTitleRules` pokaže, `pim.ApplyTitleRules` zapiše `WEB_TITLE` z odprtim
kontekstom sprememb (zgodovina kot pri ročnem urejanju), privzeto **samo tja, kjer spletnega
naziva še ni**; prepis obstoječih je izrecna izbira. Naziv, ki ga piše SAOP (`out.SaopXmlField`),
se ne dotakne. Zasejano pravilo `SVETILA_SPLOSNO` (drevo `svetila_si`) je **izklopljeno**:

```
{ErpName} {Category:2} {Attr:Vrsta svetlobnega vira|omitIf:integr|omitIf:vgraj}
{Attr:Nazivna moč|unit:W} {Attr:Temperatura barve|unit:K} {Attr:Prevladujoča barva|lower}
```

### 7.4 Prag faktorja marže (`/preverbe`)

`pim.CheckThreshold` (`CheckCode = FAKTOR_MARZE`, privzeto 2,00 za vsa podjetja; vrstica po
podjetju prevlada). `intranet.GetPriceChecks` ga bere: izdelek, kjer je prodajna cena deljeno
z nabavno (cenik `NAB`) pod pragom, pride v preverbo, izpis pokaže predlagano prodajno ceno
(nabavna × prag). Zapis cene v SAOP tu ni vključen — cene piše SAOP (`out.OwnershipPolicy`).
Preverbe ne blokirajo izvoza.

### 7.5 Preslikave polj in slovar (`/pravila/preslikave`, `/pravila/slovar`, `/kakovost/prevodi`)

`map.FieldMapping` (element vira → kanonično polje, `IsActive`), `map.ValueLookup` (prevod
vrednosti po domeni; strojni predlogi so označeni `Note = '093 strojni prevod, uporabnik
potrdi'`), `map.MissingTranslation` (kaj čaka prevod). Kategorijske preslikave:
`/kakovost/kategorije`, `/izdelki/kategorije`, `/izdelki/{ItemId}/kategorije`.

### 7.6 Register izvoza (`/izvozi`, `/izvozi/profili/{id}`)

Bralni pogled profilov in stolpcev s pokritostjo; spremembe so `UPDATE` nad `out.ExportColumn`,
`out.ExportPriceList`, `out.ExportStockSource` (za te še ni zapisovalne strani).

### 7.7 Urniki (`/sistem/urniki`, vloga `ADMIN`)

`ops.ScheduleProfile` po (podjetje, postopek): vklop/izklop in razmik. Izklop ustavi postopek
takoj — worker s stikalom `--po-urniku` brez omogočenega razporeda zavrne zagon (napaka 51100).
Ročni zagon iz ukazne vrstice urnik namenoma obide.

### 7.8 Ostalo

Stranke in spletni profil (`/stranke/{id}`: `b2b.SaveCustomerWebProfile`,
`b2b.SaveCustomerContact`), popusti (`/pravila-popustov`), lastništvo polj
(`pim.FieldOwnership`, `out.OwnershipPolicy`), atributi (`/nastavitve/atributi`), kanali
(`/nastavitve/kanali` = `canon.WebSite`), jeziki, skladišča.

---

## 8. Avtomatika

### 8.1 Načrtovana opravila Windows

Registrira jih `scripts\Namesti-opravila.ps1` (sistemska nastavitev — požene jo človek,
`AGENTS.md` §4.7). Vsa tri tečejo pod uporabnikovim računom, prek `wscript.exe Tiho.vbs`
(brez konzolnega okna; pot do PowerShella najde `Izvajalec.ps1`), `MultipleInstances IgnoreNew`,
`StartWhenAvailable`.

| Opravilo | Skripta | Ritem | Meja izvajanja | Kaj naredi |
|---|---|---|---|---|
| **PIM nocni tok** | `scripts\Nocno-vse.ps1 -DanPolnegaZajema 1 -HkratnihPodjetij 4 -ZalogaIzSaop` | dnevno ob 02:30 (`-Ura`) | 8 h | koraki spodaj |
| **PIM zaloga** | `scripts\Zaloga-cikel.ps1 -Kaj Vse -PoUrniku` | 5 min (zamik 2 min) | 30 min | NW FTP + BT XML (prevzem in branje v istem prehodu), SAOP zaloga, izvoz `MAGENTO_STOCK_PRICES` |
| **PIM nadzor** | `scripts\Nadzor.ps1` | 5 min (zamik 4 min) | 15 min | `PIM.Watchdog`, `PIM.AlertDispatcher` |

Koraki nočnega toka (`Nocno-vse.ps1`; padec enega ne ustavi ostalih, izhodna koda = število padlih):

| # | Korak | Opomba |
|---|---|---|
| 0 | gradnja `PIM.sln` | workerji tečejo z `--no-build`; če gradnja pade, se ne požene nič |
| 1 | SAOP katalog (`PIM.KatalogWorker`) | `--full` prvi dan meseca; `-BrezSaopKataloga` preskoči |
| 1a | prevzem dobaviteljevih datotek (`PIM.SourceFetchWorker`) | `-BrezPrevzema` preskoči |
| 2 | dobaviteljev XML NW in BT za vsa podjetja | `fixtures\nw`, `fixtures\bt` privzeto; `-MapaNwXml`, `-MapaBtXml` |
| 3 | spletni nazivi iz zvezkov | samo z `-MapaSpletnihNazivov` |
| 4 | preslikava zaostanka (`--preslikaj-zaostanek`) | brez klica na SAOP |
| 5 | zaloge dobaviteljev iz `data\prevzem\*` | od 2026-09-02 **ne bere več** oznak `*.pocakaj` / `*.prenos` kot zaloge (prej je `.pocakaj` končal v karanteni in korak označil kot padel) |
| 6 | zaloga iz SAOP | samo z `-ZalogaIzSaop` |
| 7 | `val.RunValidation` in `val.Promote` za vsa podjetja | prek `sqlcmd` |
| 8 | Magento izvoz (`--export-magento`) | `-BrezIzvoza` preskoči |

Varovalke: pred zagonom preveri, da ne teče živ zajem (`Running` + zadnji v
`ops.IntegrationHealth` + utrip mlajši od 15 minut); zapuščene `Running` vrstice samo prijavi.
Povzetek izpiše `raw.Inbox` `Pending`/`Quarantined`. Dnevniki: `logs\nocno_<datum>_<ura>.log`,
`logs\zaloga-<datum>.log`, `logs\nadzor-<datum>.log`; nočni dnevniki starejši od 90 dni se brišejo.

`Zaloga-cikel.ps1` od 2026-09-02 sam nastavi `PIM_CONNECTION_STRING` iz korenske
`appsettings.Local.json` (ker `PIM.B2bWorker` bere samo okoljsko spremenljivko) in na koncu
izvozi `MAGENTO_STOCK_PRICES` za vsa podjetja.

### 8.2 `ops.ScheduleProfile` in `--po-urniku`

Načrtovano opravilo Windows je samo ura, ki tiktaka na 5 minut. Ali postopek sme teči in kdaj je
zares na vrsti, pove `ops.ScheduleProfile` (`IsEnabled`, `IntervalSeconds`, `NextScheduledUtc`).
Postopki: `SAOP_PRODUCTS`, `GENERIC_XML`, `SOURCE_FETCH`, `STOCK_FILE`, `SAOP_STOCK` (vsi
300 s od 112), `WATCHDOG`, `ALERT_DISPATCH`, `OUTBOUND`. `NextScheduledUtc` se računa od
**začetka** teka (118). Če ritem v `Namesti-opravila.ps1` spremeniš, spremeni tudi bazo.

### 8.3 Sled izvajanja (144)

Vsak zagon workerja gre skozi `ops.BeginRun`/`ops.CompleteRun` (`PIM.Operations.OperationsRun`):
`BeginRun` prepiše stanje v `ops.IntegrationHealth` **in** vstavi vrstico v `ops.PipelineRun` z
istim `RunId`; `CompleteRun` jo zapre (`EndedUtc`, `Status`) in ob napaki pokliče `ops.LogError`.
Stanje in zgodovina imata zato eno identiteto. Pravilo: **`ops.IntegrationHealth` je stanje in
edini vir alarma; `ops.PipelineRun` je zgodovina in forenzika.** Zaloga ima vzporedno zgodovino
v `stock.SyncRun`; pogledi »zadnji teki« jo pobirajo z unijo.

### 8.4 Alarmi in nadzor

- `PIM.Watchdog` (`ops.RunWatchdog`): zastarel utrip, mirujoč vodni žig, `OutboundDead`,
  `OutboundDrift`, `PipelineDisabled` → `ops.Alert` z dedup ključem.
- `PIM.AlertDispatcher`: prejemniki iz `ops.AlertRecipientConfig` (vpisan je `ADMIN`,
  `Critical`, vsa podjetja); pošta odide samo pri `PIM_ALERT_DELIVERY_ENABLED=true` in
  nastavljenih `PIM_ALERT_EMAIL_ENABLED`, `PIM_SMTP_HOST`, `PIM_SMTP_PORT`, `PIM_SMTP_STARTTLS`,
  `PIM_SMTP_USERNAME`, `PIM_SMTP_PASSWORD`, `PIM_SMTP_FROM`. Te spremenljivke **še niso
  nastavljene** (`STATUS.md` 2026-09-02) — alarmi nastanejo, pošta ne odide.
- `/sistem/integracije`: potrditev in razrešitev alarma (`intranet.AcknowledgeAlert`,
  `intranet.ResolveAlert`).

### 8.5 Pet zamahov in povej (118)

Napake 1–4: postopek ostane vklopljen in poskusi ob naslednjem terminu. Napaka 5: postopek se
**izklopi** (`IsEnabled = 0`, `UpdatedBy = samodejni izklop po napakah`) in nastane alarm
`PipelineDisabled` s postopkom, podjetjem in zadnjo napako. Uspeh postavi števec na nič. Prag je
`MaxConsecutiveFailures` po postopku; `NULL`/0 pomeni »nikoli« (velja za `WATCHDOG`).

Primer iz prakse (`STATUS.md`): 28. 8. 2026 je pet zaporednih iztekov časa proti SAOP (VPN)
izklopilo `SAOP_STOCK` pri vseh štirih podjetjih; ker prejemnikov alarmov ni bilo in nadzor
ni tekel, je zaloga stala šest dni. Vklopljeno nazaj 2. 9. ob 20:18; prvi cikel je uspel
(podjetje 2: 8.734 zapisov, 3: 7.016, 4: 3.113, 1: 16; 0 v karanteni).

---

## 9. Intranet — zemljevid strani

Gostovanje: Blazor Web App, `UsePathBase("/PIM")`, piškotna prijava, globalni `FallbackPolicy`
(vse zaprto, kar ni `AllowAnonymous`). Meni je v `Services/PimNavigation.cs`, razdeljen po fazah
toka; vsaka postavka je ena destinacija, podstrani so dosegljive z razdelilne strani.

| Vozlišče (meni) | Pot | Vloge | Podstrani in kaj kažejo |
|---|---|---|---|
| **Nadzorna plošča** | `/nadzorna-plosca` | vsi | `intranet.GetDashboard`: seštevek vseh podjetij, kakovost, procesi, alarmi |
| **Vhodni podatki → Zajem podatkov** | `/zajem` | vsi (tehnični predogled `ADMIN`) | `/zajem/viri/{SourceCode}`, `/zajem/teki`, `/zajem/teki/{RunId}`, `/zajem/tezave`, `/zajem/tezave/{IssueKind}/{IssueId}`, `/zajem/cakalna-vrsta`, `/zajem/neujemanja`, `/zajem/atributi`; aliasa `/teki-obdelave`, `/karantena` |
| **PIM katalog → Izdelki** | `/izdelki` | vsi | seznam vseh podjetij, strežniška paginacija; gumb **»Excel → čakalna lista SAOP«** vodi na `/saop/artikli`; `/izdelki/{ProductId}` kartica (15 naborov, zavihek »SAOP endpoint«, atributi po naboru); `/izdelki/kategorije`, `/izdelki/{ItemId}/kategorije` |
| **PIM katalog → Mediji** | `/mediji` | vsi | slike ⊎ dokumenti |
| **Kakovost → Kakovost podatkov** | `/kakovost` | vsi | vrzeli po polju, načrt odblokiranja, profili; `/kakovost/napake` (alias `/napake-validacije`), `/kakovost/karantena`, `/kakovost/prevodi`, `/kakovost/kategorije` |
| **Izhodi → Izhod v SAOP** | `/saop` | `ADMIN`, `CATALOG_EDITOR` | `/saop/artikli` (voden potek: ročni vnos ali Excel → izbor polj → preverjanje → čakalna vrsta), `/saop/zgodovina`, `/saop/odkloni`, `/saop/polja`; `/outbound` (odobri / prekliči / ponovi); `/izvozi/mnozicno`, `/izvozi/obvestila` |
| **Izhodi → Izhod na splet** | `/splet` | vsi | tri številke iz `GetExportReadiness` (v datoteki / brez spletne strani / s stranjo, a neveljaven), predogled in prenos po profilu; `/splet/izvoz` (profil, spletna stran, samo objavljeni, iskanje, predogled 200 vrstic, prenos celote); `/izvozi`, `/izvozi/profili/{id}` register |
| **Poslovanje → Stranke** | `/stranke` | `ADMIN`, `CATALOG_EDITOR`, `COMMERCIAL` | `/stranke/{CustomerId}` kartica z zavihki, kontakti (140); `/partnerji` je ostanek |
| **Poslovanje → Zaloga** | `/zaloge` | vsi | pozicije s petimi količinami (145), pregled svežine, gumbi za `/izvoz/zaloge.csv` (ERP / dobavitelj / vse; samo splet) |
| **Poslovanje → Cene in ceniki** | `/cene` | vsi | cene po cenikih; **`/cene/tisk`** tiskani cenik (`intranet.GetPriceListSheet`: cenik, jezik, spletna stran, kategorija ali seznam šifer, do 5.000 vrstic; PDF s tiskanjem v brskalniku) |
| **Poslovanje → Preverbe cen in zaloge** | `/preverbe` | vsi (urejanje praga `BusinessWrite`) | `GetPriceChecks`, `GetStockChecks`; urejevalnik praga `FAKTOR_MARZE` (privzeti in po podjetju) |
| **Poslovanje** | `/pravila-popustov` | `ADMIN`, `CATALOG_EDITOR`, `COMMERCIAL` | pravila dostave, vrednostni pragovi, skupine |
| **Upravljanje → Nastavitve kataloga** | `/nastavitve` | `ADMIN`, `CATALOG_EDITOR` | `/nastavitve/atributi`, `/nastavitve/atributi/{AttributeCode}`, `/nastavitve/kategorije` (gumb **»Atributi«** na kategoriji → nabor 147), `/nastavitve/povezave-izdelkov`, `/nastavitve/jeziki`, `/nastavitve/skladisca`, `/nastavitve/kanali` |
| **Upravljanje → Pravila in izvor podatkov** | `/pravila` | `ADMIN`, `CATALOG_EDITOR`, `COMMERCIAL` | `/pravila/validacija`, `/pravila/slovar`, `/pravila/preslikave`, **`/pravila/nazivi`** (pravila nazivov, predogled, uporaba) |
| **Administracija → Sistem** | `/sistem` | `ADMIN` | `/sistem/uporabniki` (alias `/system/uporabniki`), `/sistem/vloge`, `/sistem/integracije` (alias `/system/integracije`), `/sistem/napake`, `/sistem/urniki` |
| — | `/prijava`, `/Error`, `/` (→ nadzorna plošča) | — | |

Ne-Razor končne točke: `POST /auth/prijava`, `POST /odjava`, `GET /health`,
`GET /izvoz/izdelki.csv`, `GET /izvoz/izdelki.xlsx`, `GET /izvoz/splet-na-zahtevo`,
`GET /izvoz/zaloge.csv`. Intranet ne kliče HTTP-ja navzven (varuje `PIM.F8.IntranetTests`).
Podrobna pogodba strani in UX omejitve so v [`docs/INTRANET.md`](INTRANET.md).

---

## 10. Testiranje in dokazi

### 10.1 Edini merodajni zagon

```powershell
scripts\run_tests.ps1              # build + vsi konzolni testni projekti + dotnet test (xUnit)
scripts\run_tests.ps1 -Filter F7   # samo projekti z F7 v imenu
```

Zeleno pomeni izhodna koda 0. Skripta:

1. prebere `PIM_CONNECTION_STRING` ali `ConnectionStrings:Pim` iz korenske
   `appsettings.Local.json` (brez povezave se integracijski testi preskočijo in izhod 0 **ni**
   dokaz);
2. ustavi tekoči `PIM.Intranet` (sicer `MSB3027` zaklep), zgradi `PIM.sln`;
3. požene vsak konzolni projekt iz njegove mape (relativne poti do `workers\`);
4. požene `dotnet test` za xUnit (`PIM.ChangeTracking.Integration`);
5. izpiše uspeli / preskočeni / padli.

`dotnet test PIM_Solution\PIM.sln` sam **ni** dokaz: požene en projekt, ostale samo prevede.
Zadnji zabeležen polni zagon: 58 uspelih, 0 padlih (`STATUS.md`, 2026-08-28 in 2026-09-02).

### 10.2 Testni projekti po fazah

| Faza | Projekti | Kaj varujejo |
|---|---|---|
| F0 | `PIM.F0.Tests` | besedilo temeljnih migracij |
| F2–F3 | `PIM.F2.Integration`, `PIM.F3.*` | SAOP zajem: fixture → `raw` → `map` → `canon` → CSV; `SaopClientTests` |
| F4 | `PIM.F4.*` | intranet pogodbe F4 |
| F5 | `PIM.F5.*` | XML preslikava, odkrivanje atributov, kategorije, pretvorbe vrednosti, validacija in promocija |
| F6 | `PIM.F6.*` | zaloga: NW=2697, BT=1361 zapisov iz fixture; `SaopStockIntegration` z lokalnim strežnikom na `127.0.0.1` |
| F7 | `PIM.F7.*` | B2B, Magento izvoz (213/19 stolpcev, glave = predloga), `WebExportTests` (`out.GetExportRows`), `ProductExportTests` |
| F8 | `PIM.F8.*` | odhodna pot: dedup, retry, dead, echo, drift, lastništvo, XML dokument SAOP, samo `127.0.0.1` |
| F9 | `PIM.F9.*` | watchdog, alarmi, lease/recovery, namestitev |
| F10 | `PIM.F10.*UxTests`, `PIM.F10.AuthTests`, `PIM.F10.IntranetLogicTests` | pogodbe strani intraneta (poti, vloge, dostopnost, prepovedane izmišljene vrednosti) |
| xUnit | `PIM.ChangeTracking.Integration` | undo polja/paketa, lastništvo, čiščenje konteksta |

Pravila testov: nikoli živi SAOP, nikoli `PIM_test` ali produkcija; test sme pobrisati samo
vrstice, ki jih je sam ustvaril (ozek `WHERE`); test se ob manjkajoči povezavi preskoči, ne pade.

### 10.3 Migracije

```powershell
dotnet run --project PIM_Solution\src\PIM.Migrator            # 1. zagon: uporabi manjkajoče
dotnet run --project PIM_Solution\src\PIM.Migrator            # 2. zagon: ne spremeni ničesar
dotnet run --project PIM_Solution\src\PIM.Migrator -- --verify   # »Preverjanje F0–F10 baze je uspešno.«
```

Migracije so samo dodajanje, idempotentne, brez `GO` (procedure so v `EXEC(N'...')`), z
dokazom na koncu (`THROW`, če objekt ne nastane). Migrator preverja hash vsake že uporabljene
datoteke. Pri SQL spremembi: dokaz pred in po (meritev v glavi migracije).

### 10.4 Ročni dokazi

- worker z `--samo-nastavitve` / `--samo-preberi` pokaže, kaj bi naredil, brez zapisa;
- `PIM_SAOP_MODE` brez `Live` pomeni, da worker samo izpiše, kaj bi poklical;
- `Nocno-vse.ps1 -BrezSaopKataloga -BrezPrevzema` preizkusi cel tok brez enega samega klica navzven;
- intranet: `GET /health` → `{"stanje":"zdravo"}`; ročni seznam v `docs/INTRANET.md` §7.

---

## 11. Znane vrzeli in odprte odločitve

| # | Vrzel | Stanje | Kaj bi jo zaprlo |
|---|---|---|---|
| 1 | **Dostava v Magento** | CSV nastane v `izvoz\magento\<org>\`; način dostave (mapa / FTP / HTTP) ni določen; ni evidence oddanih datotek | odločitev o načinu dostave, nato worker ali korak skripte z zapisom v `ops` |
| 2 | **`GetItemDeliveryDate`** | končna točka SAOP ni zajeta; stolpca 48–49 (»VID datum dobave«, »VID koli. prihodnjih dobav«) ostajata brez vira | vrstica `map.EntityMapping`/`map.FieldMapping`, cilj v modelu zaloge, vir za stolpca |
| 3 | **Lastništvo zapisa cen in strank nazaj v SAOP** | `out.OwnershipPolicy`: cene (`SAOP_PRICE`, `SAOP_PRICELIST`) piše SAOP; stranke (`SAOP_CUSTOMER`) imajo pogodbo po `out.SaopXmlField`; predlagana cena iz preverbe `FAKTOR_MARZE` se ne zapisuje | poslovna odločitev, katera polja cen/strank sme PIM pisati; potem `Owner = PIM` vrstice |
| 4 | **Živi SAOP write-back** | `dbo.IntegrationProfile` ni zasejan; `SAOP_PRODUCT` je odprt v razvojni bazi (ni migracija); vsako sporočilo čaka odobritev; dispatcher obdela eno sporočilo na zagon | potrjena pogodba endpointa, varen testni artikel, izrecno dovoljenje (`AGENTS.md` §4.5) |
| 5 | **En artikel na spletu, več podjetij v bazi** | `docs/EN_ARTIKEL_VEC_PODJETIJ.md`: ključ za splet je `ItemID`, register prioritet podjetij (IQL pred VID), zaloga iz izbranega podjetja; zaloga je od 146 sešteta po `ItemID`, **združen katalog** (ena vrstica na `ItemID` čez podjetja) še ni v `out.GetExportRows` | register prioritet + `ROW_NUMBER` nad `ItemID` v proceduri; odločitev uporabnika o prioriteti |
| 6 | **`PIM.Scheduler` storitev** | načrt v `docs/NACRT_RAZPOREJEVALNIK.md`: en dolgoživ proces (`AddWindowsService`), meja na zagon, ključavnica po (podjetje, postopek), utrip, pavza, `Install-Scheduler.ps1`, `PIM.F11.SchedulerTests`. Izvedena je samo migracija 144 (sled izvajanja). Danes: tri načrtovana opravila `InteractiveToken` (tečejo samo ob prijavljenem uporabniku), `dotnet run` na vsak zagon | odločitvi iz načrta §8 (nočni tok kot vrstica urnika? servisni račun), nato koraki 2–5 iz §9 načrta |
| 7 | **Migracija 070 na čisti namestitvi** | vstavi urnik `GENERIC_XML` za podjetja 1, 3 in 4, nato zahteva štiri → na prazni bazi pade z 52701 (na razvojnem računalniku je vrstica za podjetje 2 nastala ročno) | nova migracija, ki doda manjkajočo vrstico (obstoječe 070 se ne ureja); glej `docs/PRENOS_NA_SLUZBENI_RACUNALNIK.md` |
| 8 | **E-poštna dostava alarmov** | prejemnik vpisan, `PIM_ALERT_DELIVERY_ENABLED` in `PIM_SMTP_*` niso nastavljeni | sistemska nastavitev (človek) |
| 9 | **Braytronove kategorije** | `map.CategoryPathMap` za `BT_XML` prazen; predlog v `PIM_Solution\docs\Braytron_druzine_predlog.csv` | potrditev preslikave družin |
| 10 | **Stranke za splet** | nobena stranka nima `WebEnabled = 1`; `stranke.csv` je prazna z glavo; preslikava Tip stranke → Magento skupina vzdržuje poslovni tim | vpis spletnih profilov |
| 11 | **Vstopnica za objavo** | ali je `ERP_L1_SLO` sam ali skupaj s `COMMERCIAL_L2` (`docs/TVOJE_NALOGE.md` §5) | odločitev uporabnika |
| 12 | **Kanonična pot izvoza `ERP_L1`** | `out.ExportProductsCsv` vrne šest praznih stolpcev od devetih (tiho) | dopolnitev `CASE` ali umik profila |
| 13 | **Analitika** | zgodovinskih read modelov ni; nadzorna plošča nima trendov | namenski zgodovinski modeli, ko so viri potrjeni |
| 14 | **Zapisovalne strani registrov izvoza** | `out.ExportStockSource`, `out.ExportPriceList`, `out.ExportColumn` se urejajo z `UPDATE` | strani z revizijo v `b2b.AuditLog` |

Dokumenti, na katere se ta zemljevid opira: [`AGENTS.md`](../AGENTS.md),
[`PRODUKTNI_MODEL_PIM.md`](PRODUKTNI_MODEL_PIM.md), [`DATABASE.md`](DATABASE.md),
[`WORKERS.md`](WORKERS.md), [`EXPORTS.md`](EXPORTS.md), [`VALIDACIJA.md`](VALIDACIJA.md),
[`INTRANET.md`](INTRANET.md), [`NACRT_RAZPOREJEVALNIK.md`](NACRT_RAZPOREJEVALNIK.md),
[`ODHODNA_POT_SAOP.md`](ODHODNA_POT_SAOP.md), [`EN_ARTIKEL_VEC_PODJETIJ.md`](EN_ARTIKEL_VEC_PODJETIJ.md),
[`STATUS.md`](../STATUS.md), glave migracij `142`–`150` v `PIM_Solution\sql\migrations\`.
