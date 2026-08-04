# PIM_Solution — referenca baze (kaj je katera tabela, povezave, primeri)

Ta dokument je zemljevid baze `PIM`: za vsako pomembno tabelo pove **kaj predstavlja**,
**ključna polja**, **na katero tabelo se poveže** (tuji ključ) in **primer vrednosti**.
Na koncu je en izdelek, sledljiv skozi celoten sistem.

> Kako brati povezave: `A.Polje → B.Polje` pomeni, da vrednost v `A.Polje` mora
> obstajati v `B.Polje` (tuji ključ). Organizacija je **povsod stolpec** `OrganizationId`,
> ne ločena tabela.

---

## 0. Model organizacije in vira (odgovor na tvoji vprašanji)

**`OrganizationId` je šifra podjetja/kataloga.** Seed vrednosti:

| OrganizationId | Name | Pomen |
|---|---|---|
| 1 | DEMO | testni |
| **2** | **IQLighting** | tvoja glavna org (SAOP `IQLIGHTING`) |
| 3 | Vidadria | druga org |
| 4 | Ediito | druga org |

**`SourceCode` je šifra vira/dobavitelja** (npr. `SAOP_IQLIGHTING`, `NW_XML`, `NW_STOCK`,
`BT_STOCK`). Ista organizacija ima lahko **več virov**. Povezava vira in organizacije je
tabela `map.SourceConnector`, ki ima **unikatni par `(SourceCode, OrganizationId)`**.

Zato je „source različen, organizacija pa 2": organizacija 2 (IQLighting) dobiva podatke
iz **več virov hkrati** — SAOP katalog, NW XML atribute, NW/BT zaloge. Vsak vir je svoja
vrstica v `map.SourceConnector`, vsi pa polnijo **isti** `canon.Product` iste organizacije.

**Kako se viri združijo:** po **EAN**. SAOP prinese osnovni izdelek (ItemID, cena), NW XML
prinese atribute/slike/kategorije za **isti EAN**. `canon.Product` je unikaten po
`(OrganizationId, ItemID)`, EAN pa je ključ, po katerem se dodatki iz drugih virov
pripnejo na pravi izdelek.

**Za nove organizacije / nove XML-je:** dodaš vrstice v `OrganizationConfig` (če nova org)
in `map.SourceConnector` + `map.EntityMapping` + `map.FieldMapping` (nov vir). Nič kode.

**Payload / 1000 artiklov:** `raw.Inbox.PayloadXml` je `nvarchar(max)` (do ~2 GB), zato
je 1000 artiklov v enem zapisu brez težav. Pri NW XML se **celoten XML** shrani kot en
payload; mapping nato z **različnimi XPath potmi** (vrstice v `map.EntityMapping` /
`map.FieldMapping`) iz iste vsebine bere različne strukture (Attribute, Classification,
Media). Ne razbijamo XML-a na dele — beremo isto vsebino z različnimi XPath pravili.

---

## 1. Temelj (`dbo`)

### `dbo.OrganizationConfig` — seznam organizacij
- **Polja:** `OrganizationId` (PK), `Name`, `SaopPrefix`, `IsActive`.
- **Povezave:** nanjo kaže skoraj vse (`OrganizationId`).
- **Primer:** `2 | IQLighting | IQLighting | 1`.

### `dbo.SchemaMigration` — sled uporabljenih migracij
- **Polja:** ime migracije, hash, čas. Migrator preveri idempotenco.
- **Primer:** `007_CreateSaopPipeline.sql | <hash> | 2026-08-04`.

### `dbo.IntegrationProfile` — profil za odhodno integracijo (write-back)
- **Polja:** `OrganizationId`, `TargetKind`, `IsEnabled`, `EndpointTemplate`, `HttpOperation`.
- **Povezave:** `OrganizationId → dbo.OrganizationConfig`.
- **Primer:** `2 | SAOP | 0 | https://.../items/{key} | PATCH` (privzeto izklopljeno).

---

## 2. Zajem — surovi landing (`raw`)

### `raw.Inbox` — surovi odgovori vseh virov (SRCE ZAJEMA)
- **Kaj:** vsak zajet kos (stran API / cel XML) se shrani nespremenjen sem.
- **Polja:** `InboxId` (PK), `RunId`, `OrganizationId`, `SourceCode`, `EntityType`,
  `PageNumber`, `PayloadXml`, `PayloadHash`, `Status` (`Pending`→`Processed`/`Quarantined`),
  `FailureReason`.
- **Povezave:** `RunId → ops.PipelineRun`, `OrganizationId → dbo.OrganizationConfig`.
- **Unikat (dedup):** `(OrganizationId, SourceCode, EntityType, PageNumber, PayloadHash)` —
  isti vsebine ne zajame dvakrat.
- **Primer:** `55 | <RunId> | 2 | NW_XML | Attribute | 1 | <cel XML> | 7CE3… | Quarantined | "Izdelek za konfigurirani identifikator ne obstaja."`

---

## 3. Konfiguracija mapiranja — „MOŽGANI" sistema (`map`)

### `map.SourceConnector` — kateri vir pripada kateri organizaciji
- **Polja:** `SourceConnectorId` (PK), `SourceCode`, `OrganizationId`, `ConnectorType`
  (`FILE_XML`, `SAOP_API`, …), `IsActive`.
- **Povezave:** `OrganizationId → dbo.OrganizationConfig`. Nanjo kažejo EntityMapping,
  FieldMapping, Watermark, StockIdentityRule.
- **Primer:** `12 | NW_XML | 2 | FILE_XML | 1`.

### `map.EntityMapping` — katere entitete ima vir + kje so v XML-u
- **Kaj:** za vsak (vir, entiteta) pove korenski XPath zapisa.
- **Polja:** `SourceConnectorId`, `EntityType` (`Attribute`/`Classification`/`Media`/…),
  `RecordXPath`, `IsActive`.
- **Povezave:** `SourceConnectorId → map.SourceConnector`.
- **Primer:** `12 | Attribute | /feed/product | 1` (za NW_XML org 2 beri atribute iz `/feed/product`).

### `map.FieldMapping` — katero polje vira → katero kanonično polje
- **Kaj:** najpomembnejša konfiguracijska tabela. Vsaka vrstica = eno pravilo preslikave.
- **Polja:** `SourceConnectorId`, `EntityType`, `SourceElement` (XPath/element vira),
  `TargetFieldCode` (kanonična koda), `IsRequired`, `IsActive`, `MappingVersion`.
- **Povezave:** `SourceConnectorId → map.SourceConnector`.
- **Primer:** `12 | Attribute | ean/text() | Product.EAN | 1 | 1 | 1`
  (element `ean` iz vira se preslika v kanonično polje `Product.EAN`, obvezno).

### `map.Watermark` — do kod smo že zajeli (delta)
- **Polja:** `SourceConnectorId`, `EntityType`, `WatermarkValue`.
- **Povezave:** `SourceConnectorId → map.SourceConnector`.
- **Primer:** `12 | Attribute | 2026-08-04T16:00:00Z` (naslednji zajem od te točke).

### `map.ExtractedValue` — kaj je bilo dejansko izluščeno iz payloada
- **Polja:** `InboxId`, `FieldMappingId`, `TargetFieldCode`, `Value`, `RecordOrdinal`, `MappingVersion`.
- **Povezave:** `InboxId → raw.Inbox`, `FieldMappingId → map.FieldMapping`.
- **Primer:** `— | Inbox 55 | pravilo 12 | Product.EAN | 3859888… `.

### `map.UnmappedValue` — vrednosti brez ciljne kode (v čakalnici)
- **Polja:** `ExtractedValueId`, `TargetFieldCode`, `Value`, `Reason`.
- **Povezave:** `ExtractedValueId → map.ExtractedValue`.
- **Primer:** `— | Unsupported.Foo | "xyz" | "Nepodprta ciljna koda."`.

### `map.StockIdentityRule` — kako se gradi identiteta zaloge
- **Povezave:** `SourceConnectorId → map.SourceConnector`.
- **Primer:** NW → `NW.<šifra>`, BT → `BA.<koda z vezaji v pike>`.

---

## 4. Kanonični model — vir-agnostičen (`canon`)

### `canon.Product` — en izdelek (ne glede na vir)
- **Polja:** `ProductId` (PK), `OrganizationId`, `ItemID`, `EAN`, `UoM`, `ItemGroup`,
  `Manufacturer`, `Supplier`, `ValidationStatus` (`PENDING`/`VALID`/…).
- **Povezave:** `OrganizationId → dbo.OrganizationConfig`.
- **Unikat:** `(OrganizationId, ItemID)`. **EAN = ključ za združevanje virov.**
- **Primer:** `4001 | 2 | ART-12345 | 3859888… | kos | Svetila | Nowodvorski | … | VALID`.

### `canon.ProductAttribute` — EAV atributi (barva, moč, IP …)
- **Kaj:** nov atribut = **nova vrstica**, ne nov stolpec/tabela.
- **Polja:** `ProductId`, `AttributeCode`, `Value`.
- **Povezave:** `ProductId → canon.Product`.
- **Primer:** `4001 | Color | črna` ; `4001 | Wattage | 60W` ; `4001 | IPRating | IP44`.

### `canon.ProductText / ProductCategory / ProductMedia / ProductPrice / ProductCommercial`
- **Kaj:** opisi (jezik+tip), kategorije (spletna pot), slike (URL+vloga+vrstni red),
  cene (net+DDV+veljavnost), komercialni podatki (teža, PAK, carina).
- **Povezave:** vse `ProductId → canon.Product`.
- **Primer kategorije:** `4001 | B2C | Svetila/Notranja/Namizne`.
- **Primer medija:** `4001 | https://…/1.jpg | main | 0`.

---

## 5. Validacija (`val`)

### `val.ValidationProfile` — profil validacije (npr. WEB_B2C)
- **Polja:** `ProfileCode`, `Name`, `ExportProfileId`.
- **Povezave:** `ExportProfileId → out.ExportProfile` (validacija bere iste zahteve kot izvoz).
- **Primer:** `WEB_B2C | Spletni B2C | (izvozni profil B2C)`.

### `val.FieldRequirement` — katero polje je obvezno za profil
- **Kaj:** obvezna polja se generirajo iz aktivnih izvoznih stolpcev.
- **Polja:** `ValidationProfileId`, `SourceExportColumnId`, `FieldCode`, `IsRequired`.
- **Povezave:** `ValidationProfileId → val.ValidationProfile`, `SourceExportColumnId → out.ExportColumn`.
- **Primer:** `WEB_B2C | (stolpec EAN) | Product.EAN | 1`.

### `val.ProductValidationState` / `val.ProductIssue` — rezultat validacije
- **Kaj:** status izdelka po profilu + seznam manjkajočih/napačnih polj.
- **Povezave:** `ProductId → canon.Product`, `ValidationProfileId → val.ValidationProfile`,
  `FieldRequirementId → val.FieldRequirement`.
- **Primer issue:** `Product 4001 | WEB_B2C | manjka Product.Category`.

---

## 6. Potrjeni katalog (`pim`)

### `pim.Product` — samo VELJAVNI izdelki (kopija iz canon po promociji)
- **Polja:** `PimProductId` (PK), `OrganizationId`, `ItemID`, EAN itd.
- **Povezave:** `OrganizationId → dbo.OrganizationConfig`. Nanjo kažejo vsi `pim.Product*` +
  B2B popusti.
- **Primer:** `9001 | 2 | ART-12345 | 3859888…`.

### `pim.ProductText / Attribute / Category / Media / Price / Commercial`
- **Kaj:** enako kot canon, a samo za promovirane izdelke (to gre v izvoz).
- **Povezave:** vse `PimProductId → pim.Product`.

### B2B katalog (`pim.CustomerTypeCatalog`, `CustomerTypeMagentoGroup`, `ValueDiscountTier`,
`PackagingDiscountCatalog`, `ShippingRuleCatalog`) + `b2b.Customer` …
- **Kaj:** tipi strank, Magento skupine, popustne lestvice (S1–S4/PAK2), dostavna pravila.
- **Povezave:** `b2b.Customer.OrganizationId → dbo.OrganizationConfig`; popusti
  `CustomerId → b2b.Customer`, `CustomerTypeCode → pim.CustomerTypeCatalog`.

---

## 7. Izvozni kontrakt (`out`)

### `out.ExportProfile` — definicija enega izvoza (npr. PRODUCTS CSV za B2C)
- **Polja:** `ProfileCode`, `Name`, `ChannelCode`, `EntityType`.
- **Primer:** `WEB_B2C_PRODUCTS | B2C izdelki | MAGENTO | Product`.

### `out.ExportColumn` — stolpci izvoza + iz katerega kanoničnega polja
- **Polja:** `ExportProfileId`, `ColumnCode`, `OutputColumnName`, `CanonicalFieldCode`,
  `SortOrder`, `IsRequired`.
- **Povezave:** `ExportProfileId → out.ExportProfile`.
- **Primer:** `(WEB_B2C_PRODUCTS) | EAN | ean | Product.EAN | 1 | 1`.
- **Pomembno:** dodaš stolpec → izvoz dobi stolpec, validacija samodejno dobi zahtevo (prek `val.FieldRequirement`).

### `out.OutboxMessage` — ena sprememba za pošiljanje nazaj v SAOP (write-back)
- **Polja:** `OrganizationId`, `TargetKind`, `Operation` (POST/PATCH), `EntityType`,
  `EntityKey`, `PayloadJson`, `PayloadHash`, `ExpectedEchoHash`, `DedupKey`, `Status`
  (`Pending`/`Sent`/`Verified`/`Dead`…).
- **Povezave:** `OrganizationId → dbo.OrganizationConfig`. `out.OutboxAttempt.OutboxMessageId → out.OutboxMessage`.
- **Primer:** `2 | SAOP | PATCH | Product | ART-12345 | {"price":…} | Pending`.

---

## 8. Nadzor in orkestracija (`ops`)

### `ops.ScheduleProfile` — kateri pipeline sme teči + kako pogosto (STIKALO)
- **Polja:** `OrganizationId`, `Provider`, `Pipeline`, `IsEnabled`, `IntervalSeconds`,
  `StaleAfterSeconds`, `LockTimeoutMilliseconds`.
- **Povezave:** `OrganizationId → dbo.OrganizationConfig`. Unikat `(OrganizationId, Pipeline)`.
- **Primer:** `2 | SAOP | SAOP_PRODUCTS | 1 | 300 | 900 | 5000`.
- **Če manjka/izklopljeno → worker dobi `THROW 51100 „Razpored ni omogočen."`**

### `ops.PipelineRun` — dnevnik posameznega zagona
- **Polja:** `RunId` (PK), `Pipeline`, `OrganizationId`, `SourceCode`, `Status`
  (`Running`/`Succeeded`/`Failed`), `RowsRead`, `RowsSucceeded`, `RowsFailed`, časi.
- **Povezave:** `OrganizationId → dbo.OrganizationConfig`. Nanjo kažejo `raw.Inbox.RunId`,
  `ops.ErrorLog`, `ops.PipelineStepLog`.
- **Primer:** `<RunId> | SAOP_PRODUCTS | 2 | SAOP_IQLIGHTING | Succeeded | 17 | 17 | 0`.

### `ops.IntegrationHealth` — trenutno zdravje na (org, pipeline)
- **Polja:** `OrganizationId`, `Pipeline`, `Status` (`Healthy`/`Running`/`Failed`/`Stale`),
  `LastHeartbeatUtc`, `LastSuccessfulRunUtc`, `WatermarkUtc`.
- **To prikazuje `/system/integracije`.**
- **Primer:** `2 | GENERIC_XML | Healthy | 16:30 | 16:30`.

### `ops.Alert / AlertDelivery / AlertRecipientConfig` — alarmi
- **Kaj:** watchdog ustvari dedupliciran alarm (Stale/Dead/Drift); dostava je privzeto izklopljena.
- **Povezave:** `Alert.OrganizationId → dbo.OrganizationConfig`, `AlertDelivery.AlertId → ops.Alert`.

### `ops.DeadLetterQueue`, `ops.ErrorLog`, `ops.Heartbeat`, `ops.DeploymentRun`
- **Kaj:** trajno neuspeli zapisi, redigirane napake, srčni utrip, sled deployev.

---

## 9. Zaloge (`stock`)

- `stock.SyncRun` (zagon; `OrganizationId`, `SourceConnectorId`, `SaopProviderProfileId`),
  `stock.LandingRecord` (surova vrstica; `SyncRunId → stock.SyncRun`),
  `stock.Snapshot` (posnetek stanja), `stock.Position` (izračunana pozicija;
  `SnapshotId`/`LandingRecordId`, `MatchedProductId → canon.Product`),
  `stock.UnmatchedPosition` (nepovezane vrstice), `stock.SaopProviderProfile` (konfiguracija SAOP zalog).
- **Primer pozicije:** izdelek `NW.12345` → količina 42 na skladišču.

---

## 10. Dostop in UI (`sec`, `intranet`)

- `sec.LocalUser` (`UserName`, `PasswordHash`, `AuthSource` LOCAL/DOMAIN, `DomainIdentity`, `IsEnabled`),
  `sec.Role` (`ADMIN`/`CATALOG_EDITOR`/`VIEWER`/`COMMERCIAL`),
  `sec.LocalUserRole` (`LocalUserId → sec.LocalUser`, `RoleId → sec.Role`),
  `sec.NavigationGroup` / `NavigationItem` / `NavigationItemRole` (kdo vidi katero stran).
- **Primer:** `admin | <hash> | LOCAL | 1` + vrstica `admin↔ADMIN`.

---

## 11. Sledenje enega izdelka skozi sistem (primer)

1. **Zajem:** SAOP worker (org 2, vir `SAOP_IQLIGHTING`) zapiše stran v `raw.Inbox`
   (`InboxId 55`, `Status=Pending`), pod `RunId` iz `ops.PipelineRun`.
2. **Mapiranje:** po `map.SourceConnector`(12) → `map.EntityMapping`(XPath) →
   `map.FieldMapping` (`ean/text() → Product.EAN`) nastane `map.ExtractedValue`
   (`Product.EAN = 3859888…`). Neustrezno → `raw.Inbox.Status=Quarantined` + `FailureReason`.
3. **Kanon:** vpiše se `canon.Product` (`ProductId 4001`, `OrganizationId 2`, `ItemID ART-12345`,
   `EAN 3859888…`) + `canon.ProductAttribute` (Color=črna …).
4. **NW XML dodatki:** NW worker (vir `NW_XML`) prinese atribute/slike za **isti EAN** →
   pripnejo se na `canon.Product 4001` (ujemanje po EAN).
5. **Validacija:** `val.RunValidation` po profilu `WEB_B2C` napolni
   `val.ProductValidationState` (VALID) ali `val.ProductIssue` (manjka polje).
6. **Promocija:** `val.Promote` kopira veljaven izdelek v `pim.Product` (`PimProductId 9001`).
7. **Izvoz:** `out.ExportProductsCsv` po `out.ExportProfile WEB_B2C_PRODUCTS` +
   `out.ExportColumn` naredi CSV vrstico za Magento.
8. **Write-back:** sprememba za SAOP gre v `out.OutboxMessage` → `PIM.Outbound` pošlje PATCH.
9. **Nadzor:** ves čas `ops.PipelineRun` (dnevnik) + `ops.IntegrationHealth` (zdravje) →
   vidno v `/system/integracije`.

**Kje kaj iskati (na hitro):**
- „Zakaj izdelka ni na spletu?" → `val.ProductIssue` (manjka polje) ali `raw.Inbox` karantena.
- „Od kod ta vrednost?" → `map.FieldMapping` (pravilo) → `map.ExtractedValue` (izluščeno).
- „Zakaj worker ne teče?" → `ops.ScheduleProfile.IsEnabled` + `ops.IntegrationHealth`.
- „Kaj gre v CSV?" → `out.ExportProfile` + `out.ExportColumn`.
- „Kdo ima dostop?" → `sec.LocalUser` + `sec.LocalUserRole`.
