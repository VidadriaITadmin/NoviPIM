# Strani PIM intraneta — tabele in procedure po straneh

Ta dokument gre stran za stranjo skozi **celoten PIM intranet** (`PIM_Solution\src\PIM.Intranet\`),
v vrstnem redu, kot si strani sledijo v levem meniju (`Services\PimNavigation.cs`). Za vsako stran
pove: kaj prikaže, iz katerih **tabel/pogledov** bere podatke (in prek katere shranjene procedure
ali poizvedbe), ter kaj naredi vsak **gumb** — katero metodo v `@code` pokliče in katera procedura
ali stavek se ob tem izvede nad bazo.

Napisano: 2026-09-08. Vsak podatek je preverjen neposredno v kodi (`.razor` datoteke, `Services\*.cs`,
SQL migracije v `PIM_Solution\sql\migrations\`) — nič ni uganjeno. Kjer procedura ali tabela ni bila
najdena, to piše izrecno namesto izmišljenega imena.

## Kako brati ta dokument

- **Stran ne kliče vedno imenovane shranjene procedure.** Precej strani (predvsem "Zajem podatkov",
  "Kakovost" in del "Nastavitev") gradi poizvedbo neposredno v C# storitvi (`database.QueryAsync("SELECT ...")`
  prek pomožnega razreda `PimDb`, ali gol `new SqlCommand("SELECT ...")`). To je v tabelah označeno kot
  **"ni procedura — raw SQL"** oz. **"neposredna poizvedba"**. Samo klici z `CommandType.StoredProcedure`
  in imenom oblike `intranet.X` / `out.X` / `map.X` / `b2b.X` / `sec.X` so prave shranjene procedure.
- **Sheme baze** (glej tudi [`docs/DATABASE.md`](DATABASE.md)): `raw` (zajeti payloadi, karantena),
  `map` (viri, preslikave, slovar), `canon` (virsko neodvisen kanonični katalog), `val` (validacija),
  `pim` (potrjeni katalog in B2B domena), `stock` (zaloga), `out` (izvozni kontrakti in outbox),
  `ops` (teki, alarmi, dnevniki), `sec` (uporabniki, vloge), `intranet` (bralne/zapisovalne procedure za UI),
  `dbo` (organizacije).
- Kjer je bila procedura v migracijah definirana večkrat (`CREATE OR ALTER`), so tabele razbrane iz
  **zadnje** (najvišje oštevilčene) različice.
- Razdelilne strani ("hub", v meniju s puščico ›) same največkrat ne nalagajo podatkov — so samo
  kartice-povezave na podstrani. Podstrani niso v meniju neposredno, ampak dosegljive prek teh kartic.

## Kazalo (vrstni red menija)

1. [Nadzorna plošča](#1-nadzorna-plošča)
2. [Vhodni podatki — Zajem podatkov](#2-vhodni-podatki--zajem-podatkov)
3. [PIM katalog — Izdelki in Mediji](#3-pim-katalog--izdelki-in-mediji)
4. [Kakovost — Kakovost podatkov](#4-kakovost--kakovost-podatkov)
5. [Izhodi ERP in splet](#5-izhodi-erp-in-splet)
   - 5.1 [Izhod v SAOP](#51-izhod-v-saop)
   - 5.2 [Izhod na splet](#52-izhod-na-splet)
6. [Poslovanje](#6-poslovanje)
7. [Upravljanje](#7-upravljanje)
   - 7.1 [Nastavitve kataloga](#71-nastavitve-kataloga)
   - 7.2 [Pravila in izvor podatkov](#72-pravila-in-izvor-podatkov)
8. [Administracija — Sistem](#8-administracija--sistem)
9. [Prijava (izven menija)](#9-prijava-izven-menija)
10. [Dodatek A — strani, ki niso (več) v meniju](#dodatek-a--strani-ki-niso-več-v-meniju)
11. [Dodatek B — v kodi klicane procedure, ki v migracijah ne obstajajo](#dodatek-b--v-kodi-klicane-procedure-ki-v-migracijah-ne-obstajajo)

---

# 1. Nadzorna plošča

### Nadzorna plošča — `/nadzorna-plosca`
**Datoteka:** `Components/Pages/Dashboard.razor`
**Namen:** Skupni pregled stanja vseh aktivnih podjetij naenkrat (izdelki, ERP veljavnost, objave, napake, karantena), s podrobnostjo po podjetjih, kakovostjo po profilih, zadnjimi procesi in odprtimi opozorili integracij. Namenjena vsem prijavljenim uporabnikom kot vstopna stran.

**Prikazani podatki:**
| Procedura (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| brez procedure — raw SQL v `IntranetDataService.GetOrganizationsAsync` | `dbo.OrganizationConfig` | seznam aktivnih podjetij, po katerih se sešteva |
| `intranet.GetDashboard` (klic na vsako podjetje) | `canon.Product`, `pim.Product`, `val.ProductValidationState`, `val.ValidationProfile`, `raw.Inbox` | skupno izdelkov, ERP veljavnih, objavljenih, spletno neveljavnih, karantena |
| `intranet.GetValidationIssues` (klic na vsako podjetje) | `val.ProductIssue`, `canon.Product`, `val.ValidationProfile`, `val.ProductValidationState` | popolnost po profilih kakovosti |
| `intranet.GetPipelineRuns` (klic na vsako podjetje) | `ops.PipelineRun` | zadnjih 100 procesnih tekov, prikazanih zadnjih 5 |
| `intranet.GetSystemIntegrations` (klic na vsako podjetje) | `ops.ScheduleProfile`, `dbo.OrganizationConfig`, `ops.IntegrationHealth`, `ops.Alert`, `out.OutboxMessage` | stanje integracij in odprta opozorila |

**Akcije / gumbi:**
Samo za branje — brez zapisovalnih akcij. (Kartice in vrstice so povezave na druge strani: `izdelki`, `napake-validacije`, `karantena`, `teki-obdelave`, `system/integracije`.)

---

# 2. Vhodni podatki — Zajem podatkov

Hub `/zajem`. Podstrani spodaj so dosegljive prek te razdelilne strani ali neposredno prek povezav iz drugih strani (npr. vrstica izdelka → izvor podatkov).

### Vhodni podatki (pregled) — `/zajem`
**Datoteka:** `Components/Pages/Ingest.razor`
**Namen:** Enotni pregled vseh registriranih vhodnih tokov vseh podjetij: kaj se bere, od kod, stanje, zadnji poskus/uspeh in naslednji zagon. Ločuje zadnji poskus od zadnjega uspeha, da neuspeh ne ostane skrit.

**Prikazani podatki:**
| Procedura (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| brez procedure — raw SQL v `IntranetDataService.GetOrganizationsAsync` | `dbo.OrganizationConfig` | filter po podjetjih |
| brez procedure — raw SQL v `PipelineReadService.GetInboundFlowsAsync` | `map.SourceConnector`, `dbo.OrganizationConfig`, `ops.PipelineRun`, `stock.SyncRun`, `ops.IntegrationHealth`, `ops.ScheduleProfile`, `raw.Inbox`, `stock.LandingRecord` | tabela registriranih vhodov (vir, vrsta, stanje, zadnji poskus/uspeh, naslednji zagon, količine) |
| brez procedure — raw SQL v `PipelineReadService.GetInboundOverviewSummaryAsync` | `raw.Inbox`, `map.UnmappedValue`, `map.ExtractedValue`, `map.MissingTranslationOpen`, `map.SourceCategoryToMap`/`map.MissingCategoryMap`, `stock.UnmatchedPosition`, `stock.LandingRecord`, `ops.DeadLetterQueue`, `ops.ErrorLog`, `ops.PipelineRun`, `map.SourceConnector` | KPI vrstica: čaka, karantena, nerazvrščene vrednosti, zavrnjena zaloga, tehnične težave |
| brez procedure — raw SQL v `PipelineReadService.GetInboundFilterOptionsAsync` | `map.SourceConnector` (viri); `ops.PipelineRun`, `stock.SyncRun` (postopki) | vrednosti za spustne filtre |

**Akcije / gumbi:**
Samo za branje — brez zapisovalnih akcij. Filtri (podjetje/vir/vrsta/stanje/aktivnost) so lokalni; vrstice vodijo na `zajem/viri/{vir}` in `zajem/teki/{id}`.

---

### Atributi iz virov — `/zajem/atributi`
**Datoteka:** `Components/Pages/IngestAttributes.razor`
**Namen:** Delovni seznam vseh atributov, ki jih dobavitelji dejansko pošiljajo, in urejanje njihove preslikave na lastnost v PIM (šifrant `canon.AttributeDefinition`). Vrstica brez cilja ni napaka, ampak naloga.

**Prikazani podatki:**
| Procedura (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| brez procedure — raw SQL v `AttributeMappingService.GetSourceCodesAsync` | `map.SourceAttribute` | filter po viru |
| brez procedure — raw SQL v `CategoryTreeService.GetLanguagesAsync` | `canon.Language` | jeziki za urejanje |
| `intranet.GetSourceAttributes` | `map.SourceAttribute`, `map.AttributeMap`, `canon.AttributeTranslation` | vrstice: vir, izvorni atribut, izdelkov, stanje preslikave, ciljna lastnost |
| `intranet.GetAttributeDefinitions` (ob prvem urejanju, `BeginEditAsync`) | `canon.AttributeDefinition`, `canon.AttributeTranslation`, `map.AttributeMap`, `canon.ProductAttribute`, `canon.Language` | šifrant ciljnih lastnosti za spustni seznam |

**Akcije / gumbi:**
| Gumb ali akcija | Metoda v @code | Procedura ki jo pokliče | Učinek |
|---|---|---|---|
| "Preslikaj" / "Uredi" | `BeginEditAsync` | `intranet.GetAttributeDefinitions` (samo prvič, bralno) | odpre urejevalno vrstico, naloži šifrant lastnosti |
| "Shrani" | `SaveAsync` → `Attributes.SaveMapAsync` | `map.SaveAttributeMap` | preveri, da cilj obstaja v `canon.AttributeDefinition`, jezik v `canon.Language` in izvorni atribut v `map.SourceAttribute`; vstavi/posodobi `map.AttributeMap`, zapiše zgodovino v `map.AttributeMapHistory` |
| "Ugasni preslikavo" | `DeactivateAsync` → `Attributes.DeactivateMapAsync` | `map.DeactivateAttributeMap` | nastavi `map.AttributeMap.IsActive = 0` (vrstica ostane), zapiše `map.AttributeMapHistory` |
| "Prekliči" | `CancelEdit` | — | brez klica, samo zapre urejevalno vrstico |


**Izbira cilja (177):** naša lastnost se izbere v **izbirniku s tipkanjem** (ime in koda); ime, ki ga register nima, se ustvari kar tu (`canon.EnsureAttributeDefinition`) — izbirnik pred tem opozori, če z istim imenom (brez šumnikov in velikosti črk) atribut že obstaja (ustvarjanja ne ponudi) ali če obstaja podoben.
---

### Podrobnosti težave — `/zajem/tezave/{IssueKind}/{IssueId}`
**Datoteka:** `Components/Pages/IngestIssueDetail.razor`
**Namen:** Poslovno razumljiv opis ene tehnične težave zajema (čakalna stran, zavrnjena zaloga, mrtvo pismo ali sistemska napaka), z omejeno tehnično diagnostiko samo za administratorje.

**Prikazani podatki:**
| Procedura (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| brez procedure — raw SQL v `IntranetDataService.GetCurrentOrganizationAsync` | `dbo.OrganizationConfig` | privzeta organizacija (za nadzor obsega, če ni admin) |
| brez procedure — raw SQL v `PipelineReadService.GetInboundIssueDetailAsync` (veja glede na `IssueKind`) | `raw.Inbox` + `dbo.OrganizationConfig` (INBOX); `stock.UnmatchedPosition` + `stock.LandingRecord` + `map.SourceConnector` + `dbo.OrganizationConfig` (STOCK); `ops.DeadLetterQueue` + `dbo.OrganizationConfig` (DEADLETTER); `ops.ErrorLog` + `ops.PipelineRun` + `dbo.OrganizationConfig` (ERROR) | povzetek, stanje, kontekst; za administratorja tudi tehnične podrobnosti in omejen predogled vhodnega payloada (do 20.000 znakov) |

**Akcije / gumbi:**
Samo za branje — brez zapisovalnih akcij.

---

### Težave vhodnih podatkov — `/zajem/tezave`
**Datoteka:** `Components/Pages/IngestIssues.razor`
**Namen:** Enoten delovni seznam tehničnih napak zajema (čakalne strani, karantena, zavrnjena zaloga, mrtva pisma, sistemske napake), združen po viru in vzroku, da se ponavljajoči vzrok ne prikaže tisočkrat.

**Prikazani podatki:**
| Procedura (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| brez procedure — raw SQL v `IntranetDataService.GetOrganizationsAsync` | `dbo.OrganizationConfig` | filter po podjetjih |
| brez procedure — raw SQL v `PipelineReadService.GetInboundFilterOptionsAsync` | `map.SourceConnector`, `ops.PipelineRun`, `stock.SyncRun` | filter po virih |
| brez procedure — raw SQL v `PipelineReadService.GetInboundIssuesAsync` (začasna tabela, UNION štirih virov) | `raw.Inbox`, `dbo.OrganizationConfig`, `stock.UnmatchedPosition`, `stock.LandingRecord`, `map.SourceConnector`, `ops.DeadLetterQueue`, `ops.ErrorLog`, `ops.PipelineRun` | združene skupine težav po resnosti, viru, podjetju in pogostosti |

**Akcije / gumbi:**
Samo za branje — brez zapisovalnih akcij. Vrstica vodi na `zajem/tezave/{vrsta}/{id}` (IngestIssueDetail) oz. `zajem/teki/{id}`.

---

### Čakalna vrsta zajema — `/zajem/cakalna-vrsta`
**Datoteka:** `Components/Pages/IngestQueue.razor`
**Namen:** Prikaz zajetih strani (`raw.Inbox`) po viru, entiteti in stanju za trenutno organizacijo. Stanje "Pending" ni napaka: stran je shranjena in čaka na preslikavo.

**Prikazani podatki:**
| Procedura (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| brez procedure — raw SQL v `IntranetDataService.GetCurrentOrganizationAsync` | `dbo.OrganizationConfig` | aktivna organizacija (stran nima izbire podjetja) |
| brez procedure — raw SQL v `PipelineReadService.GetInboxGroupsAsync` | `raw.Inbox` | povzetek po viru/entiteti/stanju s številom strani |
| brez procedure — raw SQL v `PipelineReadService.GetInboxPagesAsync` | `raw.Inbox` | posamezne strani, straničeno po 50 |

**Akcije / gumbi:**
| Gumb ali akcija | Metoda v @code | Procedura ki jo pokliče | Učinek |
|---|---|---|---|
| Klik na entiteto v povzetku | `FilterAsync` → `Pipeline.GetInboxPagesAsync` | brez procedure (raw SQL) | zoži spodnji seznam strani na izbrano entiteto/stanje — bralna akcija |

---

### Tek vhodnih podatkov — `/zajem/teki/{RunId}`
**Datoteka:** `Components/Pages/IngestRunDetail.razor`
**Namen:** Podrobnosti ene izvedbe zajema: identiteta, rezultat, koraki obdelave, napake, zavrnjene pozicije zaloge in vhodne strani. Tehnične podrobnosti (RunKind, endpoint, CorrelationId) so vidne samo administratorju.

**Prikazani podatki:**
| Procedura (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| brez procedure — raw SQL v `IntranetDataService.GetCurrentOrganizationAsync` | `dbo.OrganizationConfig` | nadzor obsega za ne-administratorje |
| brez procedure — raw SQL v `PipelineReadService.GetInboundRunAsync` (glava) | `ops.PipelineRun` + `dbo.OrganizationConfig` (UNION) `stock.SyncRun` + `dbo.OrganizationConfig` + `map.SourceConnector` | identiteta in rezultat teka |
| brez procedure — raw SQL (koraki) | `ops.PipelineStepLog` | koraki, poskusi, trajanje |
| brez procedure — raw SQL (strani) | `raw.Inbox` | do 200 vhodnih strani teka |
| brez procedure — raw SQL (napake) | `ops.ErrorLog` | do 100 napak teka |
| brez procedure — raw SQL (zaloga) | `stock.UnmatchedPosition`, `stock.LandingRecord` | do 200 zavrnjenih pozicij zaloge |

**Akcije / gumbi:**
Samo za branje — brez zapisovalnih akcij.

---

### Teki vhodnih podatkov — `/zajem/teki`
**Datoteka:** `Components/Pages/IngestRuns.razor`
**Namen:** Skupna zgodovina kataloških, XML, delovnih in zalogovnih izvedb zajema, s filtri po podjetju, viru, postopku in statusu.

**Prikazani podatki:**
| Procedura (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| brez procedure — raw SQL v `IntranetDataService.GetOrganizationsAsync` | `dbo.OrganizationConfig` | filter po podjetjih |
| brez procedure — raw SQL v `PipelineReadService.GetInboundFilterOptionsAsync` | `map.SourceConnector`, `ops.PipelineRun`, `stock.SyncRun` | filtra po viru in postopku |
| brez procedure — raw SQL v `PipelineReadService.GetInboundRunsAsync` (začasna tabela, UNION PIPELINE + STOCK) | `ops.PipelineRun`, `dbo.OrganizationConfig`, `stock.SyncRun`, `map.SourceConnector` | zgodovina tekov, straničeno po 50 |

**Akcije / gumbi:**
Samo za branje — brez zapisovalnih akcij. Vrstica vodi na `zajem/teki/{RunId}` (IngestRunDetail).

---

### Vir: {SourceCode} — `/zajem/viri/{SourceCode}`
**Datoteka:** `Components/Pages/IngestSourceDetail.razor`
**Namen:** Operativno stanje enega vira (konektorja): entitete, preslikave, svežina in zadnjih 20 tekov. Isti vir (npr. `BT_XML`) je lahko registriran pri več podjetjih, zato stran ponudi zavihek po podjetju.

**Prikazani podatki:**
| Procedura (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| brez procedure — raw SQL v `PipelineReadService.GetInboundFlowsAsync` (ponovna uporaba, filtrirano po `SourceCode`) | glej stran "Vhodni podatki (pregled)" | operativno stanje in količine izbranega vira |
| brez procedure — raw SQL v `PipelineReadService.GetSourceEntitiesAsync` | `map.SourceConnector`, `map.FieldMapping`, `map.Watermark`, `raw.Inbox`, `map.StockIdentityRule`, `stock.LandingRecord`, `stock.SyncRun` | entitete vira: preslikava, št. polj, čaka/obdelano/karantena |
| brez procedure — raw SQL v `PipelineReadService.GetInboundRunsAsync` (ponovna uporaba, `take=20`) | `ops.PipelineRun`, `dbo.OrganizationConfig`, `stock.SyncRun`, `map.SourceConnector` | zadnjih 20 tekov vira |

**Akcije / gumbi:**
Samo za branje — brez zapisovalnih akcij. Zavihki nad tabelo preklopijo podjetje prek query parametra `podjetje`; vrstica teka vodi na `zajem/teki/{RunId}`.

---

### Neujemanja — `/zajem/neujemanja`
**Datoteka:** `Components/Pages/IngestUnmapped.razor`
**Namen:** Seznam vrednosti iz virov, ki jih preslikava ni znala razvrstiti, združen po vrednosti (ista neznana vrednost pogosto pride na tisočih zapisih).

**Prikazani podatki:**
| Procedura (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| brez procedure — raw SQL v `IntranetDataService.GetCurrentOrganizationAsync` | `dbo.OrganizationConfig` | aktivna organizacija |
| brez procedure — raw SQL v `PipelineReadService.GetUnmappedValuesAsync` | `map.UnmappedValue`, `map.ExtractedValue`, `raw.Inbox` | do 300 nerazvrščenih vrednosti, razvrščenih po pogostosti |

**Akcije / gumbi:**
Samo za branje — brez zapisovalnih akcij.

---

### Uvozi (starejši pogled) — `/teki-obdelave`
**Datoteka:** `Components/Pages/PipelineRuns.razor`
**Namen:** Viri in zgodovina procesnih tekov ene organizacije — starejši, enostavnejši pogled od `/zajem/teki`, brez presoje več podjetij; kartice zadnjega teka po viru in filtrirana/straničena tabela zgodovine.

**Prikazani podatki:**
| Procedura (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| brez procedure — raw SQL v `IntranetDataService.GetCurrentOrganizationAsync` | `dbo.OrganizationConfig` | aktivna organizacija |
| `intranet.GetPipelineRuns` | `ops.PipelineRun` | zadnjih 100 tekov: postopek, vir, vrstice, napake, status, začetek/konec |

**Akcije / gumbi:**
Samo za branje — brez zapisovalnih akcij. Iskanje, filter po statusu in straničenje so izvedeni lokalno (v pomnilniku) nad že naloženimi podatki.

---

# 3. PIM katalog — Izdelki in Mediji

### Izdelki — `/izdelki`
**Datoteka:** `Components/Pages/Products.razor`
**Namen:** Delovni seznam kataloga izdelkov (privzeto vseh podjetij, filter zoži na eno) s shranjenimi pogledi (zavihki), filtri, iskanjem, razvrščanjem, množično izbiro in izvozom v Excel / predlogo SAOP. Odpiranje vrstice vodi na kartico izdelka (`ProductCard.razor`).

**Prikazani podatki:**
| Procedura (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| — (raw SQL v `IntranetDataService.GetOrganizationsAsync`, ni SP) | `dbo.OrganizationConfig` | Seznam podjetij za filter "Podjetje" |
| `intranet.GetProductListViews` | `canon.Product`, `canon.ProductMedia`, `canon.ProductText`, `canon.ProductCategory`, `pim.Product`, `out.OutboxMessage` | Števci ob zavihkih (Vsi, Za urediti, Brez slike, Brez spletnega naziva, Brez kategorije, Brez EAN, Neobjavljeni, Čaka SAOP) |
| `intranet.GetProductListFilters` | `canon.Product`, `canon.PartnerName` | Fasete filtrov: proizvajalec, dobavitelj, skupina artikla, ABC klasifikacija (s števci) |
| `intranet.GetProductList` | `canon.Product`, `canon.ProductMedia`, `canon.ProductText`, `canon.ProductCategory`, `canon.PartnerName`, `dbo.OrganizationConfig`, `val.ValidationProfile`, `val.ProductValidationState`, `val.ProductIssue`, `out.OutboxMessage`, `pim.Product`, `pim.ProductFieldHistory` | Stran seznama (50/stran): slika, naziv, EAN, podjetje, proizvajalec, dobavitelj, status ERP/splet, popolnost, št. odprtih težav, vrzeli, zadnja sprememba |

**Akcije / gumbi:**
| Gumb ali akcija | Metoda v @code | Procedura ki jo pokliče | Učinek |
|---|---|---|---|
| "Uporabi filtre" | `ApplyFiltersAsync` | (posredno) `intranet.GetProductList` | Filtri gredo v naslov (query string), stran se znova naloži |
| Razvrstitev (spustni seznam) | `ApplySortAsync` | (posredno) `intranet.GetProductList` | Takoj spremeni vrstni red brez gumba "Uporabi" |
| Klik na vrstico / Enter/Presledek | `OpenAsync` / `OpenKeyAsync` | — (brez SP) | Navigira na `izdelki/{ProductId}` (kartica izdelka) |
| Kljukica v vrstici | `Toggle` | — (brez SP) | Doda/odstrani izdelek iz lokalne izbire `Selected` |
| "Uredi izbrane (N)" | `EditSelectedAsync` | — (brez SP na tej strani) | Navigira na `izvozi/mnozicno?items=...&podjetje=...` (množično urejanje) |
| "Izvozi Excel" / "Predloga SAOP" | — (`<a href>` na `ExportHref`) | zunaj obsega (izvozni modul) | Prenese delovni zvezek Excel z istimi filtri kot pogled |
| "Excel → čakalna lista SAOP" | — (`<a href>` na `saop/artikli`) | zunaj obsega | Vodi na stran za pametni uvoz Excela v čakalno listo SAOP |
| Paginacija (PimPager) | `GoToSkipAsync` | (posredno) `intranet.GetProductList` | Naloži naslednjo/prejšnjo stran rezultatov |

---

### Kartica izdelka — `/izdelki/{ProductId:long}`
**Datoteka:** `Components/Pages/ProductCard.razor`
**Namen:** Osrednja stran za urejanje in pregled enega izdelka: identiteta, tri "kanali" (ERP/SAOP, Komerciala, Splet), primerjava z zapisom SAOP, mediji, zaloga, kakovost in zgodovina. Najkompleksnejša stran aplikacije — en obrazec z osmimi sklopi (zavihki), en gumb "Shrani spremembe" za vse hkrati.

**Prikazani podatki (naloženo v `LoadAsync`, ob vstopu na stran):**
| Procedura (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| — (raw SQL v `IntranetDataService.GetProductOrganizationAsync`, ni SP) | `canon.Product`, `dbo.OrganizationConfig` | Določi, kateremu podjetju izdelek pripada |
| `intranet.GetProductCard` | `canon.Product`, `canon.ProductCommercial`, `canon.ProductAttribute`, `canon.ProductCategory`, `canon.Category`, `canon.ProductDocument`, `canon.ProductMedia`, `canon.ProductPrice`, `canon.ProductText`, `canon.PartnerName`, `out.OutboxMessage`, `out.OutboxAttempt`, `out.OwnershipPolicy`, `pim.ProductFieldHistory`, `pim.ProductChangeBatch`, `pim.Product`, `pim.FieldOwnership`, `stock.Position`, `stock.Snapshot`, `canon.Warehouse`, `canon.ProductStockPolicy`, `val.ProductIssue`, `val.ValidationProfile`, `val.ProductValidationState`, `val.FieldRequirement` | Glavni večsklopni odgovor kartice: header, validacijski profili, odprte težave, besedila, atributi, kategorije, mediji/dokumenti, cene, zaloga, zgodovina sprememb, čakajoče prekrivke, komercialni podatki |
| `intranet.GetProductOrigin` | `canon.Product`, `raw.Inbox`, `map.ExtractedValue` | Vhodni zapisi (teki, strani), iz katerih izvirajo podatki izdelka — zavihek "Izvor podatkov" |
| `intranet.GetPriceChecks` | `canon.Product`, `canon.ProductPrice`, `canon.ProductText`, `pim.CheckThreshold` | Poslovne preverbe cen tega artikla (uporabljeno le za opozorilo `PimMissing`, če procedura manjka) |
| `intranet.GetStockChecks` | `stock.Position`, `stock.Snapshot`, `map.SourceConnector`, `canon.Product`, `canon.ProductStockPolicy`, `canon.ProductText` | Poslovne preverbe zaloge (enako, za zavihek Zaloga) |
| — (raw SQL, `CatalogReadService.GetWebSitesAsync`) | `canon.WebSite`, `canon.Category` | Seznam spletnih mest za izbiro v zavihku Splet |
| — (raw SQL, `CatalogReadService.GetLanguagesAsync`) | `canon.Language` | Register jezikov podjetja |
| `intranet.GetWritableSaopFields` | `out.SaopXmlField`, `out.OwnershipPolicy`, `out.SaopDocument` | Kateri podatkovni ključi so pisljivi nazaj v SAOP — določa urejivost polj kartice |
| `intranet.GetProductAttributeSet` | `canon.ProductCategory`, `canon.WebSite`, `canon.Category`, `canon.ProductAttribute`, `canon.AttributeTranslation`, TVF `canon.CategoryAttributeEffective` | Nabor atributov, ki jih izdelek potrebuje glede na kategorijo |
| `intranet.GetSaopEndpointSnapshot` (šele ob odprtju zavihka "SAOP endpoint") | `map.SourceConnector`, `map.EntityMapping`, `map.FieldMapping`, `raw.Inbox` | Zajeti zapis, kot ga ima ERP (SAOP) — primerjava z vrednostmi PIM, odkloni |

**Skupna akcija (velja za vse zavihke naenkrat, zgoraj desno):**
| Gumb ali akcija | Metoda v @code | Procedura ki jo pokliče | Učinek |
|---|---|---|---|
| "Prekliči" | `DiscardChanges` | — (brez SP) | Počisti nabor nepotrjenih sprememb (`Drafts`) |
| "Shrani spremembe (N)" | `SaveChangesAsync` | `pim.SaveProductTexts` (besedila v lasti PIM) + `pim.SaveProductAttributes` (lastnosti v lasti PIM) + `out.EnqueueSaopItemChanges` (polja, ki jih piše SAOP) | Besedila/atributi gredo naravnost v `canon.ProductText` / `canon.ProductAttribute` in sprožijo revalidacijo (`val.RunValidation`); polja v lasti SAOP gredo v `out.OutboxMessage` in čakajo odobritev |

**Zavihek "Pregled" (`overview`):** Povzetek iz že naloženega `Detail`; navigacija med zavihki brez lastnih SP klicev.

**Zavihek "ERP — SAOP" (`core`):** `ProductChannelPanel` s polji identitete, ERP šifrantov, partnerjev, naziva za ERP, teže/tarife/porekla, pakiranja in dimenzij. Urejanje gre skozi skupni gumb "Shrani spremembe" (polja so `Saop` prek `out.EnqueueSaopItemChanges` ali `Text` prek `pim.SaveProductTexts`).

**Zavihek "Komerciala" (`commercial`):** `ProductChannelPanel` s klasifikacijo (ABC, skupina), aktivnostjo, nabavo, knjiženjem; podsekcija "Cene" samo za branje, z linkom na `cene?izdelek=...`.

**Zavihek "Splet" (`web`):** `ProductChannelPanel` z objavo, nazivi/opisi po jezikih, kategorijami (samo za branje — uvrstitev se ureja na `ProductCategories.razor`) in atributi (iz `intranet.GetProductAttributeSet`). Spustni seznam "Spletno mesto" je lokalni filter brez SP klica.

**Zavihek "SAOP endpoint" (`saop-endpoint`):** Samo za branje. Ob prvem odprtju kliče `intranet.GetSaopEndpointSnapshot` in prikaže surov zapis SAOP po sklopih, z označenimi odkloni od PIM.

**Zavihek "Mediji" (`media`):** Vgrajuje `ProductMediaGallery` — podatki (`Detail.Media`, `Detail.Documents`) so že prišli z `intranet.GetProductCard`. Link "Vsi mediji tega izdelka" vodi na `mediji?izdelek=...`.

**Zavihek "Zaloga" (`stock`):** Tabela `Detail.Stock`, samo za branje, z linkom na `zaloge?isci=...`.

**Zavihek "Kakovost in zgodovina" (`quality-history`):** Štiri podsekcije, vse samo za branje:
- "Kakovost" — `Detail.Issues` (odprte validacijske težave).
- "Zapisi v SAOP" — `Detail.Outbound`, link na `saop`.
- "Zgodovina sprememb" — `Detail.History`.
- "Izvor podatkov" — `Origins` (iz `intranet.GetProductOrigin`), linki na `zajem/tezave/INBOX/{InboxId}` in `zajem/teki/{RunId}`.

---

### Panel kanala (podkomponenta kartice izdelka) — brez lastne poti
**Datoteka:** `Components/Pages/ProductCard/ProductChannelPanel.razor`
**Namen:** NI samostojna stran (nima `@page`, nima `@inject`). Vgrajena je trikrat v `ProductCard.razor` (zavihki ERP, Komerciala, Splet) za izris skupine polj kanala. Ureja lokalno prek parametra `Drafts` in dogodka `FieldChanged`, ki ga starševska kartica prestreže — sama komponenta ne kliče baze.

---

### Galerija medijev izdelka (podkomponenta kartice izdelka) — brez lastne poti
**Datoteka:** `Components/Pages/ProductCard/ProductMediaGallery.razor`
**Namen:** NI samostojna stran. Vgrajena v `ProductCard.razor`, zavihek "Mediji". Parametra `Media` in `Documents` prejme od kartice — sama ne kliče baze.

---

### Uvrstitev izdelka (kategorije) — `/izdelki/kategorije` in `/izdelki/{ItemId}/kategorije`
**Datoteka:** `Components/Pages/ProductCategories.razor`
**Namen:** Ročna uvrstitev enega izdelka v kategorije, ločeno po vsaki aktivni spletni strani. Namensko ločena stran (ne zavihek kartice) — edino mesto, kjer se kategorija dejansko zapiše; ročna uvrstitev je močnejša od vira.

**Prikazani podatki:**
| Procedura (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| — (raw SQL, `IntranetDataService.GetCurrentOrganizationAsync`) | `dbo.OrganizationConfig` | Aktivna organizacija |
| `intranet.GetProductCategories` | `canon.Product`, `canon.ProductCategory`, `pim.ProductCategoryOverride`, `canon.WebSite` | Trenutna uvrstitev izdelka po vsaki aktivni spletni strani |
| `intranet.GetCategoryTreeNodes` (ob "Uredi") | `canon.Category`, `canon.CategoryPathTranslated`, `canon.WebSite` | Drevo kategorij te spletne strani |

**Akcije / gumbi:**
| Gumb ali akcija | Metoda v @code | Procedura ki jo pokliče | Učinek |
|---|---|---|---|
| "Poišči" | `LoadProductAsync` | `intranet.GetProductCategories` | Naloži trenutno uvrstitev izdelka |
| "Uredi" | `BeginEditAsync` | `intranet.GetCategoryTreeNodes` | Odpre urejanje za eno spletno stran |
| "Dodaj na seznam" / "odstrani" | `AddPicked` / `Chosen.Remove` | — | Lokalni seznam `Chosen` pred shranjevanjem |
| "Shrani uvrstitev" | `SaveAsync` | `pim.SetProductCategories` | Piše `canon.ProductCategory` (nov nabor), `pim.ProductChangeBatch` + `pim.ProductFieldHistory` (revizija), `pim.ProductCategoryOverride` (ročna prekrivka) |
| "Vrni pod vir" | `ClearAsync` | `pim.ClearProductCategoryOverride` | Izbriše ročno prekrivko iz `pim.ProductCategoryOverride`; naslednja preslikava iz vira spet velja |

---

### Izdelek (zgodovinska/opuščena kartica) — brez javne poti
**Datoteka:** `Components/Pages/ProductDetail.razor`
**Namen:** **Opuščena datoteka — ni dosegljiva.** Nima direktive `@page`, zato je router ne poveže z nobeno potjo. Komentar na vrhu: *"Zgodovinska izvedba je ohranjena brez javne poti zaradi sledljivosti stare F10 pogodbe. Aktivna kartica izdelka je ProductCard.razor."* Podrobnosti glej v [Dodatku A](#dodatek-a--strani-ki-niso-več-v-meniju).

---

### Mediji — `/mediji`
**Datoteka:** `Components/Pages/Media.razor`
**Namen:** Skupni pregled vseh medijev (slik in dokumentov) izdelkov izbrane organizacije — `canon.ProductMedia` in `canon.ProductDocument` v enem predalu, z iskanjem, filtri, razvrščanjem, preklopom mreža/seznam in predogledom.

**Prikazani podatki:**
| Procedura (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| — (raw SQL, `IntranetDataService.GetCurrentOrganizationAsync`) | `dbo.OrganizationConfig` | Aktivna organizacija |
| — (raw SQL, `CatalogReadService.GetMediaSummaryAsync`) | `canon.ProductMedia`, `canon.ProductDocument`, `canon.Product` | Povzetek: koliko izdelkov ima medij / nima slike |
| — (raw SQL, `CatalogReadService.GetMediaRolesAsync`) | isto | Vloge medija (s števci) za filter |
| — (raw SQL, `CatalogReadService.GetMediaAsync`) | isto | Stran rezultatov (mreža 48 / seznam 50) |
| — (raw SQL, `CatalogReadService.GetMediaKindCountsAsync`) | isto | Števci po vrsti medija za "kind" zavihke |

**Akcije / gumbi:** Samo za branje — brez zapisovalnih akcij. Iskanje, filtri, razvrstitev in preklop pogleda le ponovno pokličejo zgornje bralne poizvedbe; klik na sličico odpre lokalni lightbox brez klica baze.

---

# 4. Kakovost — Kakovost podatkov

### Kakovost — `/kakovost`
**Datoteka:** `Components/Pages/Quality.razor`
**Namen:** Razdelilna stran kakovosti: pripravljenost za objavo po štirih poslovnih nivojih (ERP SLO, ERP EU/tretje države, splet, komerciala) in seznam polj, ki najbolj ustavljajo izdelke; drugi zavihek pokaže vse validacijske profile v eni tabeli.

**Prikazani podatki:**
| Vir (ob nalaganju) | Glavne tabele | Kaj prikaže |
|---|---|---|
| `IntranetDataService.GetOrganizationsAsync` — ni procedura, SQL v servisu | `dbo.OrganizationConfig` | Seznam aktivnih podjetij |
| `GovernanceReadService.GetValidationProfilesAsync` — ni procedura | `val.ValidationProfile`, `val.FieldRequirement`, `val.ProductValidationState`, `canon.Product` | Validacijski profili z (zahtev, veljavnih, neveljavnih) |
| `GovernanceReadService.GetValidationLayerSummariesAsync` — ni procedura | `canon.Product`, `val.ProductIssue`, `val.FieldRequirement` | Delež pripravljenih izdelkov po nivoju |
| `GovernanceReadService.GetFieldGapsAsync` — ni procedura | `val.ProductIssue`, `canon.Product`, `val.FieldRequirement` | Odprte zahteve, združene po polju |
| `GovernanceReadService.GetUnblockPlanAsync` — ni procedura | `val.ProductIssue`, `canon.Product`, `val.FieldRequirement` | Skupno število prizadetih/aktivnih izdelkov |
| `PipelineReadService.GetSummaryAsync` — ni procedura | `raw.Inbox`, `map.UnmappedValue`, `map.ExtractedValue`, `map.MissingTranslationOpen`, `map.SourceCategoryToMap`, `map.SourceConnector` | Števci za kartice (manjkajoči prevodi/kategorije, karantena) |
| `intranet.GetQualityByCategory` (177, zavihek **Po kategorijah**) | `canon.Category`, `canon.CategoryPathTranslated`, `canon.WebSite`, `canon.ProductCategory`, `canon.Product`, `val.ProductIssue`, `val.FieldRequirement` | Vrstica na kategorijo drevesa (svetila / videlektro), **večnivojsko**: izdelki, izdelki z odprto zahtevo, napake, opozorila in tri najpogosteje manjkajoča polja — za kategorijo in vse njene podkategorije; vsa podjetja skupaj |
| `CategoryTreeService.GetTreeCodesAsync` — ni procedura | `canon.Category` | Izbirnik drevesa za zavihek Po kategorijah |

Storitev `CatalogReadService Catalog` je injicirana, a v `@code` ni uporabljena (mrtev vbrizg).

**Akcije / gumbi:**
Samo za branje — brez zapisovalnih akcij. Preklop zavihkov Pregled / Profili ne kliče baze znova; zavihek **Po kategorijah** (`kakovost?pogled=kategorije`) prebere `intranet.GetQualityByCategory` ob izbiri drevesa in resnosti. Veje se zlagajo (»Samo 1. raven«, »Do 2. ravni«, »Razpri vse«, puščica na vrstici); filter »Samo kategorije z izdelki«. Gumb »Odpri napake« pelje na `kakovost/napake?drevo=…&kategorija=…` (obseg = kategorija s podkategorijami). Povezave vodijo na Napake validacije, Karantena, Manjkajoči prevodi, Nepreslikane kategorije.

---

### Nepreslikane kategorije — `/kakovost/kategorije`
**Datoteka:** `Components/Pages/MissingCategories.razor`
**Namen:** Delovni seznam poti iz virov brez naše kategorije, z urejanjem preslikave na mestu.

**Prikazani podatki:**
| Procedura / vir (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| `intranet.GetCategoryMappings` | `map.SourceCategory`, `canon.WebSite`, `map.CategoryPathMap`, `canon.CategoryPathTranslated` | Poti iz virov s stanjem (Nepreslikano/Preslikano/Ugasnjeno), številom izdelkov in ciljno kategorijo |
| `CategoryMappingService.GetSourceCodesAsync` — ni procedura | `map.SourceCategory` | Seznam virov za filter |
| `CategoryMappingService.GetTreeCodesAsync` — ni procedura | `canon.WebSite` | Seznam dreves za filter |
| `intranet.GetCategoryTreeNodes` (ob urejanju) | `canon.Category`, `canon.CategoryPathTranslated`, `canon.WebSite` | Vozlišča ciljnega drevesa |

**Akcije / gumbi:**
| Gumb ali akcija | Metoda v @code | Procedura ki jo pokliče | Učinek |
|---|---|---|---|
| "Preslikaj" / "Uredi" | `BeginEditAsync` | `intranet.GetCategoryTreeNodes` | Odpre urejevalno vrstico |
| "Shrani" | `SaveAsync` → `CategoryMappingService.SaveMappingAsync` | `map.SaveCategoryPathMap` | Vpiše/posodobi `map.CategoryPathMap`, doda `map.CategoryPathMapHistory`, izbriše vrstico iz `map.MissingCategoryMap` |
| "Ugasni preslikavo" | `DeactivateAsync` | `map.DeactivateCategoryPathMap` | Nastavi `IsActive = 0` v `map.CategoryPathMap` |
| "Prekliči" | `CancelEdit` | — | Zapre urejevalno vrstico |


**Izbira cilja (177/178):** ciljna kategorija se izbere v **izbirniku s tipkanjem** (`PimPicker`): išče po imenu in celotni poti brez šumnikov, prikaže drevo z zamikom in polno pot. Ime, ki ga v drevesu ni, ponudi »Ustvari novo kategorijo« → izbira nadrejene (prazno = koren) → `canon.SaveCategory`; izbirnik pred tem opozori na enako ali podobno ime, stran pa zavrne isto ime pod istim starsem.
---

### Manjkajoči prevodi — `/kakovost/prevodi`
**Datoteka:** `Components/Pages/MissingTranslations.razor`
**Namen:** Seznam vrednosti iz vseh virov, za katere slovar nima prevoda v izbrani jezik, razvrščen po pogostosti.

**Prikazani podatki:**
| Vir (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| `PipelineReadService.GetMissingTranslationsAsync` — ni procedura | `map.MissingTranslationOpen` (pogled) | Domena, jezik, izvorna vrednost, pojavitve, nazadnje viden |

**Akcije / gumbi:** Samo za branje — brez zapisovalnih akcij.

---

### Napake validacije — `/napake-validacije`, `/kakovost/napake`
**Datoteka:** `Components/Pages/ValidationErrors.razor`
**Namen:** Podroben seznam izdelkov z odprtimi validacijskimi težavami, plus razčlenitev po pravilu in po dobavitelju. Izrecno bralna — napake ni mogoče "zapreti" ročno.

**Prikazani podatki:**
| Procedura / vir (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| `IntranetDataService.GetCurrentOrganizationAsync` — ni procedura | `dbo.OrganizationConfig` | Aktivna organizacija |
| `intranet.GetQualityOverview` | `val.ProductIssue`, `canon.Product`, `val.ValidationProfile`, `val.FieldRequirement` | KPI kartice, "Katera zahteva ustavi največ izdelkov" |
| `GovernanceReadService.GetValidationProfilesAsync` — ni procedura | isto kot zgoraj + `val.ProductValidationState` | Seznam profilov za filter/nivo |
| `CatalogReadService.GetWebSitesAsync` — ni procedura | `canon.WebSite`, `canon.Category` | Spletna mesta za filter (nivo SPLET) |
| `intranet.GetQualityIssues` (brez filtra "nivo") | `canon.Product`, `val.ProductIssue`, `val.ValidationProfile`, `val.FieldRequirement`, `canon.ProductText`; od 177 tudi `canon.Category`, `canon.CategoryPathTranslated`, `canon.ProductCategory` za obseg kategorije | Stran izdelkov z odprtimi težavami |
| `QualityReadService.GetIssuesForProfilesAsync` (s filtrom "nivo") — ni procedura | isto, prek začasnih tabel `#Page` in `#Scope` | Ista stran, omejena na profile izbranega nivoja |
| `CategoryTreeService.GetTreeCodesAsync`, `GetCategoryOptionsAsync` — ni procedura (177) | `canon.Category` | Izbirnik drevesa in kategorije (ravni z zamikom) za filter »Kategorija« |

**Akcije / gumbi:** Samo za branje. Filtri in pager samo navigirajo (query string), kar sproži ponovno branje. Filter **Kategorija** (177; parametra `drevo`, `kategorija`) je **večnivojski**: izbrana kategorija zajame tudi vse podkategorije (veriga `ParentCategoryCode`), pot izdelka se ujema v jeziku spletnega mesta.

---

### Karantena — `/karantena`, `/kakovost/karantena`
**Datoteka:** `Components/Pages/RawQuarantine.razor`
**Namen:** Seznam zapisov iz virov, ki jih je preslikava zavrnila (izdelka iz njih sploh ni). Za diagnostiko zajema podatkov.

**Prikazani podatki:**
| Procedura / vir (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| `IntranetDataService.GetCurrentOrganizationAsync` — ni procedura | `dbo.OrganizationConfig` | Aktivna organizacija |
| `intranet.GetRawQuarantine` | `raw.Inbox` (`Status = 'Quarantined'`) | Vir, entiteta, stran, razlog izločitve, čas prejema |

**Akcije / gumbi:** Samo za branje — iskalno polje filtrira že naložene vrstice v pomnilniku.

---

# 5. Izhodi ERP in splet

## 5.1 Izhod v SAOP

Hub `/saop`. Opomba: `GetCurrentOrganizationAsync`, `GetOrganizationsAsync`, `SaopItemWriteService.GetChannelStateAsync` idr. ne kličejo poimenovanih procedur, ampak raw SQL neposredno nad tabelami — v tabelah spodaj označeno kot "raw SQL".

### Pregled SAOP — `/saop`
**Datoteka:** `Components/Pages/Saop.razor`
**Namen:** Vstopna razdelilna stran izhoda v SAOP — stanje zapisov po entitetah (čaka, v vrsti, poslano, potrjeno, napake, odkloni) in seznam neuspelih sporočil/skupin za varen ponovni poskus.

**Prikazani podatki:**
| Procedura (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| raw SQL (`GetCurrentOrganizationAsync`) | `dbo.OrganizationConfig` | aktivna organizacija |
| `intranet.GetOutboundMessages` | `out.OutboxMessage` | vsa odhodna sporočila organizacije, po entiteti in stanju |
| `intranet.GetOutboundBatches` | `out.OutboundBatch`, `out.OutboxMessage` | zadnjih 50 skupin z agregiranimi stanji |

**Akcije / gumbi:**
| Gumb ali akcija | Metoda v @code | Procedura ki jo pokliče | Učinek |
|---|---|---|---|
| "Pošlji znova" (neuspelo sporočilo) | `RequeueMessageAsync` | `out.RequeueOutboxMessage` | Sporočilo Error/Dead → Pending, počisti napako/lease, zapiše `ops.OutboundEvent` (REQUEUE) |
| "Pošlji znova vse neuspele" (skupina) | `RequeueBatchAsync` | `out.RequeueOutboundBatch` | Vsa Error/Dead sporočila skupine → Pending |

---

### Odkloni SAOP — `/saop/odkloni`
**Datoteka:** `Components/Pages/SaopDrifts.razor`
**Namen:** Prikaže odhodne operacije, kjer je zaznan `DriftDetail` (poslana vrednost se ne ujema s tem, kar je vrnila naslednja sinhronizacija ERP).

**Prikazani podatki:**
| Procedura (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| `intranet.GetOutboundMessages` | `out.OutboxMessage` | vse odhodne vrstice, filtrirane na `DriftDetail is not null` |

Opozorilo na strani (`PimMissing`): manjka strukturiran posnetek poslanih vrednosti in echo iz SAOP — trenutni `DriftDetail` je le povzetek.

**Akcije / gumbi:**
| Gumb ali akcija | Metoda v @code | Procedura ki jo pokliče | Učinek |
|---|---|---|---|
| "Pošlji ponovno" | `RetryAsync` | `out.RetryMessage` | Sporočilo (Error/Dead) → Retry, počisti lease |

---

### Kaj sme nazaj v SAOP — `/saop/polja`
**Datoteka:** `Components/Pages/SaopFields.razor`
**Namen:** Bralni pregled polj, za katera obstaja nadzorovana zapisovalna pot nazaj v SAOP. Urejanje lastništva na strani ni dovoljeno.

**Prikazani podatki:**
| Procedura (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| `intranet.GetWritableSaopFields` | `out.SaopXmlField`, `out.SaopDocument`, `out.OwnershipPolicy` | Polja dokumenta SAOP_PRODUCT v lasti PIM, omogočena za pisanje nazaj |

Opozorilo na strani: stolpca "Lastnik" in "Bere se nazaj" sta vedno prazna — manjka povezava s `pim.FieldOwnership` in dokaz povratnega branja.

**Akcije / gumbi:** Samo za branje.

---

### Zgodovina zapisov v SAOP — `/saop/zgodovina`
**Datoteka:** `Components/Pages/SaopHistory.razor`
**Namen:** Filtrirana zgodovina operacij zapisa v SAOP, ena vrstica na poslovno operacijo; omogoča ponovno pošiljanje neuspelih.

**Prikazani podatki:**
| Procedura (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| `intranet.GetOutboundMessages` | `out.OutboxMessage` | operacije zapisa, filtrirane po entiteti/stanju/obdobju/iskanju |

Opozorilo na strani: manjkajo odobritelj, čas pošiljanja, stara/nova vrednost in razčlenitev po poskusih.

**Akcije / gumbi:**
| Gumb ali akcija | Metoda v @code | Procedura ki jo pokliče | Učinek |
|---|---|---|---|
| "Pošlji znova" (Error/Dead) | `RequeueMessageAsync` | `out.RequeueOutboxMessage` | Sporočilo → Pending |

---

### Artikli v SAOP — `/saop/artikli`
**Datoteka:** `Components/Pages/SaopItems.razor`
**Namen:** Glavni 4-koračni tok za pripravo novih artiklov in sprememb obstoječih za SAOP: izbira artiklov (ročno ali Excel), izbira polj, vnos vrednosti s preverjanjem pripravljenosti, oddaja v nadzorovano čakalno vrsto in odobritev/preklic skupine.

**Prikazani podatki:**
| Procedura (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| raw SQL (`GetOrganizationsAsync`, `GetCurrentOrganizationAsync`) | `dbo.OrganizationConfig` | seznam podjetij, privzeto izbrano |
| `out.GetSaopXmlContract` | `out.SaopDocument`, `out.SaopXmlField` | oblika dokumenta (ADD/PATCH), vsa polja |
| `intranet.GetWritableSaopFields` | `out.SaopXmlField`, `out.SaopDocument`, `out.OwnershipPolicy` | katera polja so v lasti PIM |
| raw SQL (`GetChannelStateAsync`) | `dbo.IntegrationProfile` | ali je kanal SAOP_PRODUCT omogočen, način odobritve |
| `out.GetSaopItemWriteState` (na artikel) | `canon.Product`, `canon.ProductCommercial`, `canon.ProductText`, `out.SaopAddDefault` | ali artikel že obstaja v SAOP (ADD vs PATCH), privzetki |

**Akcije / gumbi:**
| Gumb ali akcija | Metoda v @code | Procedura ki jo pokliče | Učinek |
|---|---|---|---|
| "Preveri in dodaj artikle" | `AddCodesAsync` → `AddRowsAsync` | `out.GetSaopItemWriteState` | Samo bere stanje artikla |
| "Izberi izpolnjeno datoteko XLSX" | `OnFileAsync` | `out.GetSaopItemWriteState` (za nove vrstice) | Prebere/preslika Excel v spremembe |
| "Pripravi N sprememb za pošiljanje" | `EnqueueAsync` | `out.EnqueueSaopItemChanges` (znotraj `out.EnqueueSaopItemChange`, `out.BeginOutboundBatch`) | Ustvari `out.OutboundBatch`, za vsako spremembo vstavi `out.OutboxMessage`; še nič ne pošlje v SAOP |
| "Odobri skupino …" | `ApproveAsync` | `out.ApproveOutboundBatch` | Sporočila skupine PendingApproval → Pending |
| "Prekliči skupino" | `CancelAsync` | `out.CancelOutboundBatch` | Sporočila skupine → Cancelled |

---

### Množično urejanje — `/izvozi/mnozicno`
**Datoteka:** `Components/Pages/BulkOutbound.razor`
**Namen:** Množična sprememba enega polja za več artiklov (ročni seznam šifer ali Excel uvoz), uvrstitev v čakalno vrsto SAOP in odobritev/preklic nastale skupine. Dosežena z gumbom "Uredi izbrane" na strani Izdelki.

**Prikazani podatki:**
| Procedura (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| raw SQL (`GetOrganizationsAsync`/`GetCurrentOrganizationAsync`) | `dbo.OrganizationConfig` | podjetje izbranih artiklov |
| `intranet.GetWritableSaopFields` | `out.SaopXmlField`, `out.SaopDocument`, `out.OwnershipPolicy` | polja, ki jih sme PIM pisati nazaj |

**Akcije / gumbi:**
| Gumb ali akcija | Metoda v @code | Procedura ki jo pokliče | Učinek |
|---|---|---|---|
| "Uvrsti v vrsto (N artiklov)" | `QueueManualAsync` → `QueueAsync` | `out.EnqueueSaopItemChanges` | Za vsak artikel vstavi/preveri `out.OutboxMessage` |
| "Uvrsti N sprememb v vrsto" (po Excelu) | `QueueWorkbookAsync` → `QueueAsync` | `out.EnqueueSaopItemChanges` | Enako, iz uvoženega zvezka |
| "Odobri skupino" | `ApproveAsync` | `out.ApproveOutboundBatch` | Sporočila skupine → Pending |
| "Prekliči skupino" | `CancelAsync` | `out.CancelOutboundBatch` | Sporočila skupine → Cancelled |

---

### Obvestila izvozov — `/izvozi/obvestila`
**Datoteka:** `Components/Pages/OutboundEvents.razor`
**Namen:** Dnevnik dogodkov odhodne poti SAOP (napake, opozorila, stopnjevanja po e-pošti, tihi uspehi), s potrditvijo posameznega obvestila.

**Prikazani podatki:**
| Procedura (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| raw SQL (`GetCurrentOrganizationAsync`) | `dbo.OrganizationConfig` | aktivna organizacija |
| `intranet.GetOutboundEvents` | `ops.OutboundEvent` | dogodki (privzeto nepotrjeni), resnost, korak, entiteta, sporočilo |
| `intranet.GetOutboundEventCounts` | `ops.OutboundEvent` | KPI kartice: nepotrjene napake, opozorila, stopnjevana, tiha v 24h |

**Akcije / gumbi:**
| Gumb ali akcija | Metoda v @code | Procedura ki jo pokliče | Učinek |
|---|---|---|---|
| "Potrdi" | `AcknowledgeAsync` | `intranet.AcknowledgeOutboundEvent` | Označi `ops.OutboundEvent` kot potrjen |

---

### Izvozi (čakalna vrsta) — `/outbound`
**Datoteka:** `Components/Pages/Outbound.razor`
**Namen:** Glavna tabela vseh odhodnih sporočil aktivne organizacije (filtrirana, straničena), z odobritvijo, preklicom in ponovnim poskusom po posameznem sporočilu.

**Prikazani podatki:**
| Procedura (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| raw SQL (`GetCurrentOrganizationAsync`) | `dbo.OrganizationConfig` | aktivna organizacija |
| `intranet.GetOutboundMessages` | `out.OutboxMessage` | vsa odhodna sporočila: cilj, operacija, entiteta, polja, stanje, poskusi, odziv ERP, odklon |

**Akcije / gumbi:**
| Gumb ali akcija | Metoda v @code | Procedura ki jo pokliče | Učinek |
|---|---|---|---|
| "Odobri" (PendingApproval) | `Approve` | `out.ApproveMessage` | Sporočilo → Pending |
| "Prekliči" | `Cancel` | `out.CancelMessage` | Sporočilo → Cancelled |
| "Ponovi" (Error/Dead) | `Retry` | `out.RetryMessage` | Sporočilo → Retry |

---

## 5.2 Izhod na splet

Hub `/splet`.

### Izhod na splet — `/splet`
**Datoteka:** `Components/Pages/Web.razor`
**Namen:** Vstopna razdelilna stran spletnega izvoza — pripravljenost kataloga za splet, pokritost stolpcev profilov ter seznam datotek za splet s predogledom in prenosom.

**Prikazani podatki:**
| Procedura (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| raw SQL (`GetCurrentOrganizationAsync`) | `dbo.OrganizationConfig` | aktivna organizacija |
| raw SQL (`GetWebSitesAsync`) | `canon.WebSite`, `canon.Category` | spletna mesta za filter |
| raw SQL (`GetExportProfilesAsync`) | `out.ExportProfile`, `out.ExportColumn` | izvozni profili (ne-SAOP/ne-ERP kanali) |
| raw SQL (`GetValidationProfilesAsync`) | `val.ValidationProfile`, `val.FieldRequirement`, `val.ProductValidationState`, `canon.Product` | validacijski profili za "Gre, a z opozorilom" |
| `intranet.GetExportReadiness` | `canon.Product`, `pim.Product`, `pim.ProductCategory`, `canon.WebSite`, `val.ValidationProfile`, `val.ProductValidationState`, `val.ProductIssue`, `val.FieldRequirement`, `out.ExportProfile`, `out.ExportColumn` | KPI pripravljenosti, razlogi blokade, pokritost stolpcev |
| raw SQL (`GetValidationLayerSummariesAsync`) | `val.ProductIssue`, `canon.Product`, `val.FieldRequirement` | povzetek plasti "Splet" |
| `intranet.GetWebExportRows` (ob "Poglej") | glej WebExportBuild.razor | predogled izvozne datoteke |

**Akcije / gumbi:**
| Gumb ali akcija | Metoda v @code | Procedura ki jo pokliče | Učinek |
|---|---|---|---|
| "Poglej"/"Skrij" | `TogglePreviewAsync` | `intranet.GetWebExportRows` → `out.GetExportRows` | Prebere prvih 50 vrstic izvoza (samo branje) |
| "Prenesi" (povezava) | — | isti tok prek `WebExportBuildService.WriteCsvAsync` → `out.GetExportRows` | Prenese celotno CSV datoteko (ločen endpoint) |
| "Pripravi izvoz" (povezava) | — | — | navigacija na `/splet/izvoz` |

Razdelek "Zgodovina dostav" ima opozorilo `PimMissing` — procedura `intranet.GetWebExportDeliveries` **ni najdena** v migracijah (glej [Dodatek B](#dodatek-b--v-kodi-klicane-procedure-ki-v-migracijah-ne-obstajajo)).

---

### Pripravi spletni izvoz — `/splet/izvoz`
**Datoteka:** `Components/Pages/WebExportBuild.razor`
**Namen:** Ročno orodje za predogled (do 200 vrstic) in prenos CSV izvoza izbranega spletnega profila, s filtri spletno mesto / iskanje / samo objavljeni.

**Prikazani podatki:**
| Procedura (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| raw SQL (`GetCurrentOrganizationAsync`) | `dbo.OrganizationConfig` | aktivna organizacija |
| raw SQL (`GetWebSitesAsync`) | `canon.WebSite`, `canon.Category` | spletna mesta |
| raw SQL (`GetExportProfilesAsync`) | `out.ExportProfile`, `out.ExportColumn` | profili (aktivni, `CanBuildOnDemand`) |

**Akcije / gumbi:**
| Gumb ali akcija | Metoda v @code | Procedura ki jo pokliče | Učinek |
|---|---|---|---|
| "Prikaži" | `ShowAsync` | `intranet.GetWebExportRows` → `out.GetExportRows` | Prebere do 200 vrstic (`canon.*` pri `CANON`, `pim.*` pri `PIM_PRODUCT`) |
| "Prenesi CSV" (povezava) | — | `WebExportBuildService.WriteCsvAsync` → `out.GetExportRows` | Prenese celotno CSV (ločen endpoint) |

---

### Izvozni profil — `/izvozi/profili/{ExportProfileId}`
**Datoteka:** `Components/Pages/ExportProfileDetail.razor`
**Namen:** Podrobnost enega izvoznega profila — vsi stolpci s stanjem preslikave (kanonično polje, obvezen/neobvezen, aktiven) in predogled prvih 20 vrstic dejanskega izvoza.

**Prikazani podatki:**
| Procedura (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| raw SQL (`GetExportProfilesAsync`) | `out.ExportProfile`, `out.ExportColumn` | naziv/koda profila |
| raw SQL (`GetExportColumnsAsync`) | `out.ExportColumn` | vsi stolpci profila |
| raw SQL (`GetCurrentOrganizationAsync`) | `dbo.OrganizationConfig` | aktivna organizacija |
| `intranet.GetExportPreview` | — | **ni najdeno** — procedura ni definirana v migracijah (glej [Dodatek B](#dodatek-b--v-kodi-klicane-procedure-ki-v-migracijah-ne-obstajajo)) |

**Akcije / gumbi:** Samo za branje.

---

# 6. Poslovanje

### Stranke — `/stranke`
**Datoteka:** `Components/Pages/Customers.razor`
**Namen:** Seznam vseh strank aktivne organizacije (kupci, dobavitelji, proizvajalci) z zavihki po vrsti stranke, iskanjem in filtrom po tipu; klik na vrstico odpre kartico stranke.

**Prikazani podatki:**
| Procedura (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| `intranet.GetCustomers` | `b2b.Customer`, `pim.CustomerWebProfile`, `pim.CustomerTypeCatalog`, `pim.CustomerTypeMagentoGroup` | šifra, naziv, vrsta stranke, tip, Magento skupina, zastavici B2B+ in Splet |

**Akcije / gumbi:** Samo za branje — klik na vrstico navigira na `stranke/{CustomerId}`.

---

### Kartica stranke — `/stranke/{CustomerId:long}`
**Datoteka:** `Components/Pages/CustomerDetail.razor`
**Namen:** Podrobna kartica ene stranke v šestih zavihkih (splošni podatki, komercialni podatki, poslovne enote in tranziti, zaznamki, dokumenti in finance, zgodovina); ureja B2B spletni profil, kontakte, vrednostne pragove in poslovne enote.

**Prikazani podatki:**
| Procedura (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| `intranet.GetCustomerCard` (8 naborov) | `b2b.Customer`, `pim.CustomerWebProfile`, `pim.CustomerTypeCatalog`, `pim.CustomerTypeMagentoGroup`, `b2b.CustomerItemGroupDiscount`, `pim.CustomerValueDiscountTier`, `b2b.CustomerPackagingDiscountOverride`, `pim.Product`, `pim.CustomerBranch`, `pim.CustomerNote`, `b2b.AuditLog`, `pim.CustomerContact`, `map.FieldMapping`, `map.SourceConnector` | splošni podatki, popusti, vrednostni pragovi, poslovne enote, zaznamki, zgodovina, kontakti |
| `intranet.GetCustomerTypes` | `pim.CustomerTypeCatalog`, `pim.CustomerTypeMagentoGroup` | tipi strank |
| `intranet.GetCustomers` | `b2b.Customer`, ... | kandidati poslovnih enot |

**Akcije / gumbi:**
| Gumb ali akcija | Metoda v @code | Procedura ki jo pokliče | Učinek |
|---|---|---|---|
| "Shrani kontakte" | `SaveContactsAsync` | `b2b.SaveCustomerContact` | Zapiše ročni prepis v `pim.CustomerContact` |
| "Počisti ročni prepis" | `ClearContactsAsync` | `b2b.SaveCustomerContact` | Umakne ročni prepis |
| "Shrani nastavitve" | `SaveProfileAsync` | `b2b.SaveCustomerWebProfile` | Zapiše B2B profil v `pim.CustomerWebProfile` |
| "Shrani prag" | `SaveTierAsync` | `b2b.SaveCustomerValueTier` | Zapiše/posodobi `pim.CustomerValueDiscountTier` |
| "Dodaj" (poslovna enota) | `SaveBranchAsync` | `intranet.SaveCustomerBranch` | Vstavi/posodobi `pim.CustomerBranch` |
| "Zapiši zaznamek" | `AddNoteAsync` | `intranet.AddCustomerNote` | Vstavi vrstico v `pim.CustomerNote` |

---

### Zaloga — `/zaloge`
**Datoteka:** `Components/Pages/Stocks.razor`
**Namen:** Pregled zalogovnih pozicij (ERP/SAOP in dobaviteljevih), svežine po viru in izpeljanih težav; samo za branje — PIM zaloge nikoli ne piše nazaj v ERP.

**Prikazani podatki:**
| Procedura (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| `intranet.GetStockPositions` | `stock.Position`, `stock.Snapshot`, `map.SourceConnector`, `dbo.OrganizationConfig`, `canon.Product`, `canon.ProductText`, `canon.ProductStockPolicy` | pozicije: količina, razpoložljivost, prihod, min/max, vir, svežina |
| `intranet.GetStockOverview` | `stock.Position`, `stock.Snapshot`, `map.SourceConnector`, `stock.UnmatchedPosition`, `stock.LandingRecord` | povzetek po viru, izpeljane težave |

**Akcije / gumbi:**
| Gumb ali akcija | Metoda v @code | Procedura ki jo pokliče | Učinek |
|---|---|---|---|
| "Uporabi filtre" | `ApplyFiltersAsync` | (posredno) `intranet.GetStockPositions`/`GetStockOverview` | Osveži tabelo po filtrih |
| "Prenesi zalogo po filtrih" (povezava) | — | `out.GetStockExportRows` (`StockReadService.WriteStockCsvAsync`) | Pretočno zapiše CSV zaloge (samo branje) |

---

### Cene in ceniki — `/cene`
**Datoteka:** `Components/Pages/Prices.razor`
**Namen:** Seznam izdelkov s cenami, ena vrstica na izdelek (ceniki zgoščeni), s filtri po ceniku, številu cenikov in veljavnosti.

**Prikazani podatki:**
| Procedura (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| ni SP — inline SQL v `CatalogReadService.GetProductPriceGroupsAsync` | `canon.ProductPrice`, `canon.Product`, `canon.ProductText` | izdelek, predogled cenikov, min/max neto, zadnja veljavnost |
| ni SP — inline SQL v `CatalogReadService.GetPriceListsAsync` | `canon.ProductPrice`, `canon.Product` | seznam cenikov za filter |
| ni SP — inline SQL v `CatalogReadService.GetPricesForProductAsync` | `canon.ProductPrice`, `canon.Product` | podrobnost cenikov izbranega izdelka |

**Akcije / gumbi:** Samo za branje. Povezavi "Cenik za tisk" in "Preverbe cen in zaloge" so navigacija.

---

### Cenik za tisk — `/cene/tisk`
**Datoteka:** `Components/Pages/PriceSheet.razor`
**Namen:** Sestavi digitalni cenik (iz kategorije ali izbranih šifer artiklov) za tiskanje ali shranjevanje kot PDF prek brskalnika.

**Prikazani podatki:**
| Procedura (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| ni SP — inline SQL | `dbo.OrganizationConfig` | podjetja za filter |
| ni SP — inline SQL | `canon.WebSite`, `canon.Category` | spletna mesta za filter |
| `intranet.GetPriceListSheet` (ob "Pripravi cenik") | `canon.Product`, `canon.PartnerName`, `canon.ProductCategory`, `canon.WebSite`, `canon.ProductText`, `canon.ProductPrice`, `out.ExportStockSource`, `map.SourceConnector`, `stock.Snapshot`, `stock.Position`, `canon.ProductMedia` | vrstice cenika |

**Akcije / gumbi:**
| Gumb ali akcija | Metoda v @code | Procedura ki jo pokliče | Učinek |
|---|---|---|---|
| "Pripravi cenik" | `LoadAsync` | `intranet.GetPriceListSheet` | Napolni tabelo cenika |
| "Natisni / PDF" | `PrintAsync` | — | `window.print` (brez klica baze) |

---

### Preverbe cen in zaloge — `/preverbe`
**Datoteka:** `Components/Pages/Checks.razor`
**Namen:** Zbirni pregled poslovnih opozoril o cenah in zalogi (manjkajoča cena, nizek faktor marže, zaloga pod minimumom, zastarel posnetek) ter urejanje praga faktorja marže in odprtih alarmov. Opozorila ne blokirajo izvoza.

**Prikazani podatki:**
| Procedura (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| `intranet.GetCheckThresholds` | `pim.CheckThreshold`, `dbo.OrganizationConfig` | prag faktorja marže |
| `intranet.GetPriceChecks` | `canon.Product`, `canon.ProductText`, `canon.ProductPrice`, `pim.CheckThreshold` | cenovne preverbe |
| `intranet.GetStockChecks` | `stock.Position`, `stock.Snapshot`, `map.SourceConnector`, `canon.Product`, `canon.ProductText`, `canon.ProductStockPolicy` | zalogovne preverbe |
| ni SP — inline SQL v `GovernanceReadService.GetAlertsAsync` | `ops.Alert` | odprti/vsi alarmi PRICE_CHECK/STOCK_CHECK |

**Akcije / gumbi:**
| Gumb ali akcija | Metoda v @code | Procedura ki jo pokliče | Učinek |
|---|---|---|---|
| "Shrani prag" | `SaveThresholdsAsync` | `pim.SaveCheckThreshold` | Zapiše prag v `pim.CheckThreshold` |
| "Uporabi filtre" | `ApplyAsync` | (posredno) `intranet.GetPriceChecks`/`GetStockChecks` | Osveži seznam preverb |
| "Potrdi" (alarm) | `AcknowledgeAsync` | `intranet.AcknowledgeAlert` | Zapiše potrditev v `ops.Alert` |
| "Reši" (alarm) | `ResolveAsync` | `intranet.ResolveAlert` | Zapiše razrešitev v `ops.Alert` |

---

### Partnerji — `/partnerji`
**Datoteka:** `Components/Pages/Partners.razor`
**Namen:** Stran je ukinjena. Glej [Dodatek A](#dodatek-a--strani-ki-niso-več-v-meniju).

---

# 7. Upravljanje

## 7.1 Nastavitve kataloga

Hub `/nastavitve` (vloga ADMIN ali CATALOG_EDITOR).

### Nastavitve kataloga — `/nastavitve`
**Datoteka:** `Components/Pages/CatalogSettings.razor`
**Namen:** Razdelilna stran s šestimi kartami-povezavami na podstrani nastavitev kataloga. Ne injicira storitve, ne kliče baze.

---

### Atributi — `/nastavitve/atributi`
**Datoteka:** `Components/Pages/CatalogAttributes.razor`
**Namen:** Šifrant atributov s stalno kodo: slovensko ime, prevodi v vseh jezikih, preslikave iz virov in poraba pri izdelkih.

**Prikazani podatki:**
| Procedura (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| `intranet.GetAttributeDefinitions` | `canon.AttributeDefinition`, `canon.AttributeTranslation`, `map.AttributeMap`, `canon.ProductAttribute`, `canon.Language` | koda, slovensko ime, tip/enota, prevodi, št. virov, št. izdelkov |
| neposredna poizvedba v `CategoryTreeService.GetLanguagesAsync` | `canon.Language` | aktivni jeziki za stolpce prevodov |

**Akcije / gumbi:**
| Gumb ali akcija | Metoda v @code | Procedura ki jo pokliče | Učinek |
|---|---|---|---|
| "Uredi" | `BeginEdit` | — | Odpre urejevalnik prevodov |
| "Shrani" | `SaveAsync` | `canon.SaveAttributeTranslations` (+ `canon.SaveAttributeDefinition`, če je enota) | Zapiše `canon.AttributeTranslation` (+ zgodovina), po potrebi poveže enoto v `canon.AttributeDefinition` |
| "Prekliči" | `CancelEdit` | — | Zapre brez shranjevanja |

---

### Atribut (podrobnosti) — `/nastavitve/atributi/{AttributeCode}`
**Datoteka:** `Components/Pages/CatalogAttributeDetail.razor`
**Namen:** Prikaže vse različne vrednosti izbranega atributa: koliko izdelkov jih ima, prevod, vir, ali je uporabljena na spletu. Izključno bralna stran.

**Prikazani podatki:**
| Procedura (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| `intranet.GetAttributeValues` | **ni najdeno** (glej [Dodatek B](#dodatek-b--v-kodi-klicane-procedure-ki-v-migracijah-ne-obstajajo)) | — stran prikaže `PimMissing` |
| neposredna poizvedba v `IntranetDataService.GetCurrentOrganizationAsync` | `dbo.OrganizationConfig` | aktivna organizacija |

**Akcije / gumbi:** Samo za branje.

---

### Kategorije — `/nastavitve/kategorije`
**Datoteka:** `Components/Pages/CatalogCategories.razor`
**Namen:** Drevo kategorij, kot ga vidi spletna trgovina, s pokritostjo prevodov po jeziku, urejanjem imen in urejanjem nabora obveznih/priporočenih/izločenih atributov po kategoriji (dedovanje na podkategorije).

**Prikazani podatki:**
| Procedura (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| `intranet.GetCategoryTree` | `canon.Category`, `canon.Language`, `canon.CategoryTranslation`, `canon.ProductCategory`, `canon.Product` | drevo vozlišč, prevodi, manjkajoči jeziki, št. izdelkov |
| `intranet.GetCategoryTranslationCoverage` | `canon.Category`, `canon.Language`, `canon.CategoryTranslation` | pokritost prevoda na jezik |
| neposredne poizvedbe | `canon.Language`, `canon.Category`, `dbo.OrganizationConfig` | izbirniki jezika, drevesa, podjetja |

**Akcije / gumbi:**
| Gumb ali akcija | Metoda v @code | Procedura ki jo pokliče | Učinek |
|---|---|---|---|
| "Shrani imena" | `SaveAsync` | `canon.SaveCategoryTranslations` | Zapiše prevode v `canon.CategoryTranslation` (+ zgodovina) |
| "Ustvari kategorijo" (panel **Nova kategorija**: drevo, nadrejena prek izbirnika s tipkanjem, ime) | `CreateCategoryAsync` | `canon.SaveCategory` (178) | Nova kategorija pod starsem (koda iz imena, pot, slovenski prevod, revizija). **Preverba podvajanja:** isto ime pod istim starsem (brez šumnikov in velikosti črk) stran zavrne vnaprej in postopek zavrne (51781); podobno ime kjerkoli v drevesu pokaže kot opozorilo |
| "Atributi" (na vozlišču) | `ToggleAttributesAsync` | `intranet.GetCategoryAttributeSet` | Prikaže učinkoviti nabor atributov kategorije |
| Izbira ravni atributa / "Odstrani" / "Dodaj v nabor" / "priporočen"/"obvezen" | `SetAttributeLevelAsync` / `AddAttributeAsync` / `QuickAddAsync` | `canon.SaveCategoryAttributeSet` | Zapiše/deaktivira vrstico v `canon.CategoryAttributeSet`, uskladi `val.FieldRequirement` |

---

### Nabori atributov po kategorijah — `/nastavitve/nabori-atributov`
**Datoteka:** `Components/Pages/CategoryAttributeSets.razor`
**Namen:** Za vsako drevo (svetila_si, videlektro) pove, koliko in katere atribute ima katera kategorija — lastne in podedovane vrstice po ravneh, izdelke neposredno in v poddrevesu ter koliko atributov izdelki nosijo izven nabora. Isti register kot gumb »Atributi« na `/nastavitve/kategorije` (migracija 147), a za celo drevo naenkrat in z množičnim urejanjem. Nabor določa skupine atributov na kartici izdelka, zahteve spletne validacije in stolpce atributov v spletnem izvozu.

**Prikazani podatki:**
| Procedura (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| `intranet.GetCategoryAttributeSetTrees` (170) | `canon.Category`, `canon.CategoryAttributeSet`, `canon.WebSite`, `val.ValidationProfile` | izbirnik dreves: št. kategorij, kategorij z lastnim naborom, izdelkov, spletni profil (brez njega shranjevanje ni mogoče) |
| `intranet.GetCategoryAttributeSetOverview` (170) | `canon.Category`, `canon.CategoryAttributeEffective`, `canon.ProductCategory`, `canon.ProductAttribute`, `canon.AttributeTranslation` | vrstica na kategorijo: obvezni / priporočeni / izločeni (učinkoviti in »tu«), imena atributov (obvezni z zvezdico), izdelki, atributi v rabi izven nabora; drugi rezultat je povzetek drevesa |
| `intranet.GetCategoryAttributeSet` (147) | `canon.CategoryAttributeEffective`, `canon.ProductAttribute` | urejevalnik ene kategorije: trenutni nabor s pokritostjo in predlogi atributov, ki jih izdelki že nosijo |
| neposredna poizvedba `CategoryTreeService.GetAttributeOptionsAsync` | `canon.AttributeDefinition`, `canon.AttributeTranslation` | register atributov za izbiro |

**Akcije / gumbi:**
| Gumb ali akcija | Metoda v @code | Procedura ki jo pokliče | Učinek |
|---|---|---|---|
| Izbira drevesa, iskanje, raven, »Samo brez nabora«, »Samo z izdelki« | `SelectTreeAsync`, `LoadAsync` | `intranet.GetCategoryAttributeSetOverview` | Osveži pregled |
| "Uredi" / "Zapri" (na kategoriji) | `ToggleEditorAsync` | `intranet.GetCategoryAttributeSet` | Odpre urejevalnik nabora pod vrstico |
| Izbira ravni / "Odstrani" / "priporočen" / "obvezen" pri predlogu | `SetLevelAsync` | `canon.SaveCategoryAttributeSet` (147) | Ena vrstica nabora; postopek uskladi `val.FieldRequirement` in zapiše `b2b.AuditLog` |
| "Dodaj izbrane (n)" / "Dodaj vse iz registra kot priporočene" | `AddPickedAsync`, `AddAllSuggestionsAsync` → `SaveManyAsync` | `canon.SaveCategoryAttributeSetBulk` (170) | Več atributov v enem klicu; neznani se zavrnejo vsi naenkrat, nič se ne shrani |
| "Uvozi seznam" (prilepljeno besedilo: `koda ali ime[;raven]`) | `ImportPasteAsync` → `SaveManyAsync` | `canon.SaveCategoryAttributeSetBulk` (170) | Atribut sme biti naveden s kodo ali slovenskim imenom (seznami iz mastrov); raven v slovenščini ali angleščini, brez nje privzeta |
| "Kopiraj nabor" | `CopyAsync` | `canon.CopyCategoryAttributeSet` (170) | Učinkoviti nabor izbrane kategorije (tudi iz drugega drevesa) postane lastni nabor te; obstoječe vrstice ostanejo, razen ob »prepiši raven« |
| "Ustvari v registru in dodaj kot …" (iskanje brez zadetka) / "ustvari v registru in dodaj" (predlog brez kode) | `CreateAndAddAsync` | `canon.EnsureAttributeDefinition` (177) + `canon.SaveCategoryAttributeSet` | Atribut po slovenskem imenu nastane v registru (koda iz `canon.AttributeCodeFromName`, tip TEXT, revizija) in gre takoj v nabor — brez obiska `/nastavitve/atributi` |
| "Uvozi seznam" z neznanimi imeni → panel "Ustvari v registru in dodaj vse" / "Dodaj samo znane" / "Prekliči" | `ImportResolvedAsync`, `CreateUnknownAndSaveAsync`, `SaveKnownOnlyAsync` | `canon.ResolveAttributeNames` (177), `canon.EnsureAttributeDefinition`, `canon.SaveCategoryAttributeSetBulk` | Seznam se najprej razreši; neznana imena niso napaka, ampak ponudba |

---

### Spletni kanali — `/nastavitve/kanali`
**Datoteka:** `Components/Pages/CatalogChannels.razor`
**Namen:** Register spletnih mest (kanalov): jezik, kategorijsko drevo, kanonično polje po spletnem mestu.

**Prikazani podatki:**
| Procedura (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| neposredna poizvedba v `CatalogReadService.GetWebSitesAsync` | `canon.WebSite`, `canon.Category` (podpoizvedba) | seznam kanalov: ime, koda, jezik, drevo, št. kategorij, aktivnost |

**Akcije / gumbi:** Samo za branje.

---

### Jeziki — `/nastavitve/jeziki`
**Datoteka:** `Components/Pages/CatalogLanguages.razor`
**Namen:** SAOP-ova šifra jezika in njena preslikava v jezikovno kodo kataloga, za izbrano organizacijo.

**Prikazani podatki:**
| Procedura (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| neposredna poizvedba v `CatalogReadService.GetLanguagesAsync` | `canon.Language` | jeziki organizacije: ime, šifra SAOP, koda kataloga, stanje |

**Akcije / gumbi:** Samo za branje.

---

### Skladišča — `/nastavitve/skladisca`
**Datoteka:** `Components/Pages/CatalogWarehouses.razor`
**Namen:** Šifrant skladišč izbrane organizacije, kot je prišel iz SAOP.

**Prikazani podatki:**
| Procedura (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| neposredna poizvedba v `CatalogReadService.GetWarehousesAsync` | `canon.Warehouse` | šifra, ime, vrsta, skupina, stanje |

**Akcije / gumbi:** Samo za branje.

---

### Povezave izdelkov — `/nastavitve/povezave-izdelkov`
**Datoteka:** `Components/Pages/ProductLinks.razor`
**Namen:** Prikaže povezave med izdelki (nadomestni, sorodni, dodatek ...), kot izhajajo iz vrednosti atributov, ki jih pošlje dobavitelj — sistem še nima lastnega registra povezav.

**Prikazani podatki:**
| Procedura (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| `intranet.GetProductLinks` | `canon.ProductAttribute`, `canon.Product` | izvorni izdelek, vrsta povezave, ciljna šifra, ujemanje |

**Akcije / gumbi:** Samo za branje.

---

## 7.2 Pravila in izvor podatkov

Hub `/pravila` (vloge ADMIN, CATALOG_EDITOR, COMMERCIAL). Kartice hub-strani vodijo na: Validacijski profili, Slovar vrednosti, Preslikave polj, Komercialna pravila, Pravila za nazive.

### Pravila — `/pravila`
**Datoteka:** `Components/Pages/Rules.razor`
**Namen:** Razdelilna stran s povezavami na registre, ki določajo veljavnost, prevode in preslikavo podatkov. Nima `@code` bloka, ne kliče nobene storitve.

---

### Validacijski profili — `/pravila/validacija`
**Datoteka:** `Components/Pages/ValidationRules.razor`
**Namen:** Urejanje zahtevanih polj po validacijskem profilu in poslovnem nivoju (resnost, obveznost, vklop/izklop); validacija se ravna po tem, kar je tu zapisano.

**Prikazani podatki:**
| Procedura / vir (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| `IntranetDataService.GetCurrentOrganizationAsync` — ni procedura | `dbo.OrganizationConfig` | aktivna organizacija |
| `GovernanceReadService.GetValidationProfilesAsync` — ni procedura | `val.ValidationProfile`, `val.FieldRequirement`, `val.ProductValidationState`, `canon.Product` | seznam profilov |
| `GovernanceReadService.GetFieldRequirementsAsync` (na profil) — ni procedura | `val.FieldRequirement`, `val.ProductIssue`, `canon.Product` | zahteve po profilu/nivoju + neaktivne "ki čakajo na polje" |

**Akcije / gumbi:**
| Gumb ali akcija | Metoda v @code | Procedura ki jo pokliče | Učinek |
|---|---|---|---|
| "Dodaj" (nova zahteva) | `AddRequirementAsync` | `intranet.SaveFieldRequirement` | Vpiše/posodobi `val.FieldRequirement`, `b2b.AuditLog` |
| Izbirnik resnosti | `ChangeSeverityAsync` | `intranet.SaveFieldRequirement` | Spremeni resnost zahteve |
| "Umakni" / "Vklopi" | `SetActiveAsync` | `intranet.SaveFieldRequirement` | (De)aktivira zahtevo |

---

### Slovar vrednosti — `/pravila/slovar`
**Datoteka:** `Components/Pages/ValueDictionary.razor`
**Namen:** Register prevodov izvornih vrednosti v ciljne znotraj domene (npr. enote, statusi). Izrecno samo za branje — urejanje bo dodano šele z zapisovalno proceduro in revizijsko sledjo.

**Prikazani podatki:**
| Procedura / vir (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| `GovernanceReadService.GetValueDomainsAsync` — ni procedura | `map.ValueLookup` | domene s številom vrstic |
| `GovernanceReadService.GetValueLookupsAsync` — ni procedura | `map.ValueLookup` | domena, izvorna/ciljna vrednost, jezik, opomba, stanje |

**Akcije / gumbi:** Samo za branje.

---

### Preslikave polj — `/pravila/preslikave`
**Datoteka:** `Components/Pages/FieldMappings.razor`
**Namen:** Od kod polje pride (vir + element) in kam se zapiše v PIM (ciljno polje), z možnostjo urejanja obveznosti in aktivnosti preslikave neposredno v vrstici.

**Prikazani podatki:**
| Procedura / vir (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| `GovernanceReadService.GetMappedEntityTypesAsync` — ni procedura | `map.FieldMapping`, `map.SourceConnector` | filter po entiteti |
| `GovernanceReadService.GetFieldMappingsAsync` — ni procedura | `map.FieldMapping`, `map.SourceConnector` | vir/element → ciljno polje, obveznost, stanje |

**Akcije / gumbi:**
| Gumb ali akcija | Metoda v @code | Procedura ki jo pokliče | Učinek |
|---|---|---|---|
| "Shrani" | `SaveAsync` | `intranet.SaveFieldMapping` | Posodobi/vstavi `map.FieldMapping`, zapiše `b2b.AuditLog` |

---

### Komercialna pravila — `/pravila-popustov`
**Datoteka:** `Components/Pages/DiscountRules.razor`
**Namen:** Upravljanje registrov, ki poganjajo B2B popuste in poštnino: preslikava tipa stranke v Magento skupino, vrednostni pragovi rabata, pravila poštnine in override-i skupinskih popustov.

**Prikazani podatki:**
| Procedura (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| `intranet.GetCustomerTypes` | `pim.CustomerTypeCatalog`, `pim.CustomerTypeMagentoGroup` | tipi strank → Magento skupina |
| `intranet.GetValueDiscountTiers` | `pim.ValueDiscountTier` | vrednostni pragovi rabata |
| `intranet.GetDiscountRules` (metoda `GetShippingRulesAsync`) | `pim.ShippingRuleCatalog` | pravila poštnine |
| `intranet.GetGroupDiscountOverrides` | `b2b.GroupDiscountOverride`, `b2b.Customer` | override-i skupinskih popustov |

**Akcije / gumbi:**
| Gumb ali akcija | Metoda v @code | Procedura ki jo pokliče | Učinek |
|---|---|---|---|
| "Shrani preslikavo" | `SaveType` | `b2b.SaveCustomerTypeMapping` | Posodobi `pim.CustomerTypeMagentoGroup` |
| "Shrani prag" | `SaveTier` | `b2b.SaveValueDiscountTier` | Posodobi `pim.ValueDiscountTier` |
| "Shrani pravilo" (poštnina) | `Save(row)` | `b2b.SaveDiscountRule` | Vstavi/posodobi `pim.ShippingRuleCatalog` |
| "Dodaj override" | `SaveOverride` | `b2b.SaveGroupDiscountOverride` | Vstavi `b2b.GroupDiscountOverride` |

---

### Pravila za nazive — `/pravila/nazivi`
**Datoteka:** `Components/Pages/TitleRules.razor`
**Namen:** Urejevalnik pravil za sestavo spletnega naziva izdelka (izbirnik sestavnih delov namesto ročnega vpisovanja predloge), s predogledom po podjetju/jeziku in zapisom nazivov. *(Dosežena iz kartice "Pravila za nazive" na hub-strani `/pravila`.)*

**Prikazani podatki:**
| Procedura / vir (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| `TitleRuleService.GetCategoriesAsync` — ni procedura | `canon.Category` | kategorije za obseg pravila |
| `intranet.GetTitleRules` | `pim.TitleRule`, `canon.Category` | tabela pravil |
| `intranet.GetAttributeDefinitions` | `canon.AttributeDefinition`, `canon.AttributeTranslation`, `map.AttributeMap`, `canon.ProductAttribute` | atributi za izbirnik sestavnih delov |
| `intranet.GetCategoryAttributeSet` | `canon.Category`, `canon.CategoryAttributeEffective`, `canon.AttributeTranslation`, `canon.WebSite`, `canon.ProductCategory`, `canon.ProductAttribute`, `canon.AttributeDefinition` | atributi izbrane kategorije |
| `pim.PreviewTitleRules` (ob vsaki spremembi osnutka) | `canon.Category`, `canon.Product`, `canon.ProductCategory`, `canon.WebSite`, `canon.ProductText`, `pim.TitleRule` | predogled sestavljenih nazivov |

**Akcije / gumbi:**
| Gumb ali akcija | Metoda v @code | Procedura ki jo pokliče | Učinek |
|---|---|---|---|
| "Shrani pravilo" | `SaveAsync` | `pim.SaveTitleRule` | Vpiše/posodobi `pim.TitleRule`, `b2b.AuditLog` |
| "Osveži predogled" | `PreviewDraftAsync` | `pim.PreviewTitleRules` | Samo branje |
| "Zapiši nazive" | `ApplyAsync` | `pim.ApplyTitleRules` | `MERGE` zapiše `canon.ProductText` (WEB_TITLE); preveri, da naziva ne piše SAOP |

---

# 8. Administracija — Sistem

Hub `/sistem` (vloga ADMIN).

### Sistem (razdelilna stran) — `/sistem`
**Datoteka:** `Components/Pages/System.razor`
**Namen:** Vstopna stran — pet kartic na podstrani (Urniki obdelav, Integracije in alarmi, Uporabniki, Vloge, Dnevnik napak). Brez lastnih podatkov.

---

### Dnevnik napak — `/sistem/napake`
**Datoteka:** `Components/Pages/SystemErrors.razor`
**Namen:** Skrbniški pregled zadnjih tehničnih dogodkov iz baze (varni povzetek), s filtrom po resnosti.

**Prikazani podatki:**
| Poizvedba (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| neposreden SELECT (ni SP) v `GovernanceReadService.GetErrorLogAsync` | `ops.ErrorLog` | čas, resnost, plast, koda napake, sporočilo, RunId; omejeno na 300 vrstic |

**Akcije / gumbi:** Izbira resnosti ponovno naloži seznam (isti SELECT, drug filter). Sicer samo za branje.

---

### Integracije in alarmi — `/system/integracije`, `/sistem/integracije`
**Datoteka:** `Components/Pages/SystemIntegrations.razor`
**Namen:** Zdravje integracij (srčni utrip, zadnji uspešni/neuspešni tek, vodni žig, naslednje izvajanje) in operativna opozorila za aktivno organizacijo; potrjevanje in razreševanje alarmov.

**Prikazani podatki:**
| Procedura (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| neposreden SELECT (ni SP) | `dbo.OrganizationConfig` | prva aktivna organizacija |
| `intranet.GetSystemIntegrations` | `ops.ScheduleProfile`, `dbo.OrganizationConfig`, `ops.IntegrationHealth`, `ops.Alert`, `out.OutboxMessage` | integracije (ponudnik, postopek, stanje, utrip/uspeh/napaka, naslednje izvajanje) in opozorila |

**Akcije / gumbi:**
| Gumb ali akcija | Metoda v @code | Procedura ki jo pokliče | Učinek |
|---|---|---|---|
| "Osveži stanje" | `Reload` | `intranet.GetSystemIntegrations` | Ponovno naloži |
| "Potrdi" | `Acknowledge` | `intranet.AcknowledgeAlert` | Zapiše potrditev v `ops.Alert` |
| "Razreši" | `Resolve` | `intranet.ResolveAlert` | Zapiše razrešitev v `ops.Alert` |

---

### Vloge — `/sistem/vloge`
**Datoteka:** `Components/Pages/SystemRoles.razor`
**Namen:** Seznam varnostnih vlog in koliko uporabnikov ima posamezno vlogo dodeljeno.

**Prikazani podatki:**
| Poizvedba (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| neposreden SELECT (ni SP) v `GovernanceReadService.GetRolesAsync` | `sec.Role`, `sec.LocalUserRole` | koda vloge, ime, št. uporabnikov |

**Akcije / gumbi:** Samo za branje.

---

### Urniki obdelav — `/sistem/urniki`
**Datoteka:** `Components/Pages/SystemSchedules.razor`
**Namen:** Nadzor nad tem, kateri postopki (pipeline-i) smejo teči, s kakšnim razmikom in v kakšnem stanju so — ločeno od Windows načrtovanega opravila (ura na 5 minut).

**Prikazani podatki:**
| Procedura (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| `intranet.GetSchedules` | `ops.ScheduleProfile`, `dbo.OrganizationConfig`, `ops.IntegrationHealth` | postopek, podjetje, omogočeno, razmik, zdravje, naslednji tek, zadnja napaka |

**Akcije / gumbi:**
| Gumb ali akcija | Metoda v @code | Procedura ki jo pokliče | Učinek |
|---|---|---|---|
| "Vklopi" / "Izklopi" | `Preklopi` | `intranet.SaveSchedule` | Preklopi `IsEnabled` v `ops.ScheduleProfile` |
| "Shrani razmik" | `Shrani` | `intranet.SaveSchedule` | Zapiše nov `IntervalSeconds` |

---

### Uporabniki — `/system/uporabniki`, `/sistem/uporabniki`
**Datoteka:** `Components/Pages/SystemUsers.razor`
**Namen:** Upravljanje lokalnih in domenskih (AD) uporabnikov PIM intraneta, njihovih vlog, e-poštnih naslovov za opozorila in stanja (aktiven/onemogočen).

**Prikazani podatki:**
| Poizvedba (ob nalaganju) | Glavne tabele/poglede | Kaj prikaže |
|---|---|---|
| neposreden SELECT (ni SP) v `IntranetUserAdministrationService.GetUsersAsync` | `sec.LocalUser`, `sec.LocalUserRole`, `sec.Role` | uporabniško ime, prikazno ime, vir (LOCAL/DOMAIN), aktiven, vloge, e-pošta |

**Akcije / gumbi:**
| Gumb ali akcija | Metoda v @code | Procedura ki jo pokliče | Učinek |
|---|---|---|---|
| "Najdi v AD" | `Find` | **ni SQL** — `ActiveDirectoryService.Lookup` (LDAP) | Poišče uporabnika v AD, ne zapiše ničesar |
| "Dodaj" (domenski uporabnik) | `Add` | AD lookup, nato `sec.CreateDomainUser` | Vstavi `sec.LocalUser` (AuthSource=DOMAIN) + `sec.LocalUserRole` |
| "Ustvari račun" (lokalni) | `DodajLokalnega` | `PasswordHasher.Hash` (brez SQL), nato `sec.CreateLocalUser` | Vstavi `sec.LocalUser` (AuthSource=LOCAL, geslo zgoščeno) + `sec.LocalUserRole` |
| "Shrani" (ime/e-pošta) | `Shrani` | **ni SP** — neposreden `UPDATE sec.LocalUser` | Posodobi prikazno ime in/ali e-pošto |
| "Nastavi geslo" | `PonastaviGeslo` | **ni SP** — `PasswordHasher.Hash` + `UPDATE sec.LocalUser SET PasswordHash` | Novo geslo (samo lokalni uporabniki) |
| "Onemogoči" / "Omogoči" | `Preklopi` | **ni SP** — `UPDATE sec.LocalUser SET IsEnabled` | Vklopi/izklopi dostop |

Opomba: dodajanje uporabnikov gre prek imenovanih procedur v shemi `sec` (ne `intranet`); vse ostale spremembe so neposredni `UPDATE` stavki.

---

# 9. Prijava (izven menija)

### Prijava — `/prijava`
**Datoteka:** `Components/Pages/Login.razor`
**Namen:** Vstopna stran za avtentikacijo; dostopna anonimno (`[AllowAnonymous]`), poseben prazen layout (`EmptyLayout`). Obrazec se ne obdela v `@code` te strani — POST-a neposredno na minimalni API endpoint `/auth/prijava` v `Program.cs`.

**Mehanizem avtentikacije (`POST /auth/prijava` v `Program.cs`):**
1. Preveri antiforgery žeton.
2. Prebere uporabniško ime/geslo, pokliče `LocalUserAuthenticationService.AuthenticateAsync`.
3. Ta izvede neposreden SELECT (ni SP) nad `sec.LocalUser` (LEFT JOIN `sec.LocalUserRole`, `sec.Role`) — po uporabniškem imenu (LOCAL) ali normalizirani domenski identiteti (DOMAIN).
4. DOMAIN: geslo preveri `ActiveDirectoryService.Validate` (LDAP, brez SQL). LOCAL: `PasswordHasher.Verify` proti `sec.LocalUser.PasswordHash`.
5. Ob uspehu: `ClaimsPrincipal` + `HttpContext.SignInAsync` (cookie, "Zapomni si me" = `IsPersistent`). Ob neuspehu: preusmeritev na `/prijava?napaka=1`.
6. `POST /odjava` kliče `SignOutAsync` in preusmeri na `/prijava`.

**Akcije / gumbi:**
| Gumb ali akcija | Metoda v @code | Procedura ki jo pokliče | Učinek |
|---|---|---|---|
| "Prijava" (submit) | ni metoda v `@code` — POST na `/auth/prijava` | ni SP — glej mehanizem zgoraj | Nastavi avtentikacijski piškotek in preusmeri v aplikacijo, ali prikaže napako |

---

# Dodatek A — strani, ki niso (več) v meniju

Med pregledom je bilo najdenih pet datotek, ki obstajajo v kodi, a niso (več) del uporabniške poti prek menija:

| Datoteka | Pot | Stanje |
|---|---|---|
| `ProductDetail.razor` | brez `@page` | **Nedosegljiva.** Nima routing direktive; komentar v kodi pravi, da je ohranjena samo zaradi sledljivosti stare "F10" pogodbe. Aktivna kartica izdelka je `ProductCard.razor`. |
| `Partners.razor` | `/partnerji` | **Samo preusmeritev** na `/stranke` (`Navigation.NavigateTo("stranke", replace: true)`). Uporabnik jo je 2026-08-28 odpisal, ker sta dobavitelj in proizvajalec zdaj vrsti stranke. Ohranjena zaradi starih zaznamkov. |
| `Exports.razor` | `/izvozi` | **Samo preusmeritev** na `/splet`. Stran je bila podvojen pogled, 2026-08-28 ukinjena v korist `Web.razor`. Ohranjena zaradi starih zaznamkov. |
| `ProductChannelPanel.razor` | brez `@page` | Ni stran — podkomponenta, vgrajena v `ProductCard.razor` (zavihki ERP/Komerciala/Splet). |
| `ProductMediaGallery.razor` | brez `@page` | Ni stran — podkomponenta, vgrajena v `ProductCard.razor` (zavihek Mediji). |

Poleg tega `Counter.razor`, `Weather.razor` in `Error.razor` so standardni Blazor-predlogi ("scaffold") in niso del funkcionalnosti PIM-a.

---

# Dodatek B — v kodi klicane procedure, ki v migracijah ne obstajajo

Tri mesta v kodi kličejo shranjeno proceduro, ki v `PIM_Solution\sql\migrations\*.sql` ni definirana. Klic je v vseh treh primerih oviti v `try/catch (SqlException) when (PimReadModel.IsMissingReadModel(...))`, zato stran namesto napake prikaže gradnik `PimMissing` — to je torej znano, obravnavano stanje, ne skrita napaka:

| Procedura | Kje se kliče | Kaj bi morala prikazati |
|---|---|---|
| `intranet.GetAttributeValues` | `CatalogAttributeDetail.razor` (`/nastavitve/atributi/{koda}`) | Vse vrednosti atributa: št. izdelkov, prevod, vir, ali je uporabljena na spletu |
| `intranet.GetWebExportDeliveries` | `Web.razor` (`/splet`, razdelek "Zgodovina dostav") | Čas izdelave, profil, št. vrstic, velikost, rezultat, cilj dostave (podatek bi moral priti iz `PIM.B2bWorker` in dostavnega transporta) |
| `intranet.GetExportPreview` | `ExportProfileDetail.razor` (`/izvozi/profili/{id}`) | Predogled prvih 20 vrstic dejanskega izvoza za izbrani profil |

Če se te tri funkcionalnosti dokončajo, je treba dodati ustrezno migracijo z `CREATE OR ALTER PROCEDURE` in odstraniti `PimMissing` prikaz na navedenih straneh.
