# PIM Intranet — referenca

Ta dokument opisuje **dejansko stanje** aplikacije `PIM_Solution/src/PIM.Intranet`
(Blazor Web App, .NET 10, interaktivni strežniški način). Vse navedbe so povzete iz
izvorne kode, SQL migracij in testnih projektov v tem repozitoriju; nič ni povzeto
iz načrtov ali UX slik. Dokument ne vsebuje povezovalnih nizov, gesel ali vsebine
`appsettings*.json`.

Zadnji pregled kode: 2026-08-26.

---

## 1. Gostovanje in vstopne točke

| Dejstvo | Vrednost | Vir |
|---|---|---|
| Ogrodje | Razor Components + `AddInteractiveServerComponents()` | `Program.cs:12` |
| Osnovna pot | `app.UsePathBase("/PIM")` — deluje pod korenom in pod IIS virtualno aplikacijo `/PIM` | `Program.cs:36` |
| `<base href>` | dinamičen `@NavigationManager.BaseUri` | `Components/App.razor` |
| Statična sredstva | `UseStaticWebAssets()` + `app.css`, `PIM.Intranet.styles.css`, `favicon.svg`; Bootstrap ni več vključen | `Program.cs:8`, `App.razor` |
| Razvojni URL | profil `http` → `http://localhost:5091`, IIS Express → `http://localhost:12988` | `Properties/launchSettings.json` |
| Jezik dokumenta | `<html lang="sl">`, celoten UI v slovenščini | `App.razor` |

Ne-Razor končne točke:

| Metoda | Pot | Avtorizacija | Opis |
|---|---|---|---|
| POST | `/auth/prijava` | `AllowAnonymous`, obvezen antiforgery token | prevzame `uporabniskoIme`, `geslo`, neobvezno `zapomniMe`; ob uspehu prijavi in preusmeri na `{PathBase}/nadzorna-plosca`, sicer na `{PathBase}/prijava?napaka=1` |
| POST | `/odjava` | zahteva sejo (velja `FallbackPolicy`) | odjava iz piškotne sheme, preusmeritev na `{PathBase}/prijava` |
| GET | `/health` | `AllowAnonymous` | vrne `{ "stanje": "zdravo" }` |
| GET | `/izvoz/izdelki.xlsx` | zahteva sejo (velja `FallbackPolicy`) | **izvoz, ki ga ponuja stran**: isti filtri kot `/izdelki`, vključno s `kategorija=<drevo>:<koda>`, ki zoži vrstice IN stolpce atributov na nabor kategorije. Tri predloge (`predloga=delovni` — delovni list, ki se vrne na `/izdelki/uvoz`; `predloga=saop`; brez predloge pregled) in dva obsega (cel pogled ali `items=` za izbrane). Predloga SAOP ima stolpce iz registra `out.SaopXmlField` — ista datoteka za izvoz, urejanje in vračanje. Delovni zvezek dela `PIM.Operations.WorkbookWriter` (brez zunanje knjižnice): zamrznjena naslovna vrstica, samodejni filter, šifra artikla ostane besedilo. En klic v bazo, zgornja meja 20.000 vrstic je zapisana v datoteko |
| GET | `/izvoz/izdelki.csv` | zahteva sejo (velja `FallbackPolicy`) | izvozi trenutni filtriran pogled seznama izdelkov; isti filtri kot `/izdelki` (vključno s `podjetje`, `oddelek`, `aktivnost`, `objava`, `popolnost`), brez `podjetje` zajame vsa podjetja, prvi stolpec je podjetje; CSV s podpičjem in UTF-8 BOM, zgornja meja 20.000 vrstic je zapisana v datoteko, kadar je nabor večji |

Avtentikacija je piškotna (`CookieAuthenticationDefaults`), `LoginPath` je `/prijava`,
`AccessDeniedPath` pa `/brez-dostopa`. Globalni `FallbackPolicy` zahteva
prijavljenega uporabnika, zato je vse, kar ni izrecno `AllowAnonymous`, zaprto.
`zapomniMe` nastavi trajni piškotek z veljavnostjo 14 dni.

Zahtevki (claims) po prijavi: `ClaimTypes.Name` (uporabniško ime),
`ClaimTypes.GivenName` (prikazno ime), po en `ClaimTypes.Role` na vlogo in `pim:zig`
(žig seje iz `sec.LocalUser.SecurityStamp`, migracija 181).

### 1.1 Veljavnost seje in omejitev prijave (P0, 2026-09-09)

Popravek ugotovitve **A3** iz `docs/PREGLED_SISTEMA_IN_UX_2026-09-08.md`: onemogočen račun je
ostal prijavljen, ker sta se `IsEnabled` in seznam vlog prebrala samo ob prijavi.

- `Events.OnValidatePrincipal = PimSessionValidator.ValidateAsync` (`Services/PimSessionSecurity.cs`)
  ob **vsaki** zahtevi s piškotkom prebere `sec.GetUserSecurityState` in primerja žig. Ob
  neujemanju, izbrisanem ali onemogočenem računu sejo zavrne in odjavi. Prvi poskus je imel
  petminutni interval; zahtevo »izklop velja takoj« je zgrešil, zato ga ni več. Statične datoteke
  sem ne pridejo (`UseStaticFiles` stoji pred `UseAuthentication`), vezje Blazor Server pa se
  overi enkrat ob vzpostavitvi, zato je to ena poizvedba po enoličnem ključu na odprto stran.
- Spremenjene vloge ne zahtevajo ponovne prijave: piškotek se prepiše z novimi vlogami.
- Prijava ima dva obroča: `AddRateLimiter` s politiko `PimRateLimits.Login` (30 zahtev na
  15 minut na naslov, zavrnitev 429 s slovenskim sporočilom) in `PimLoginThrottle`, ki šteje samo
  **neuspele** poskuse na par uporabniško ime + naslov (10 na 15 minut; enajsti dobi 429 in do
  konca okna sploh ne pride do preverjanja gesla). Uspešna prijava števec počisti.

### 1.2 Politike zapisovalnih poti (P0, 2026-09-09)

Popravek ugotovitev **A1** in **A4**: vloga je bila preverjena samo z `[Authorize]` na strani,
urejivost polj pa se je odločala po vrsti polja. Bralna vloga `VIEWER` je na kartici izdelka
dobila 14 urejivih polj in gumb »Shrani spremembe«, strežniška pot zapisa pa vloge ni pogledala.

`Services/PimAuthorization.cs` uvaja štiri politike in varovalko `PimWriteGuard`:

| Politika | Vloge | Kje se preveri |
|---|---|---|
| `CatalogWrite` | `ADMIN`, `CATALOG_EDITOR` | `ProductEditService.SaveTextsAsync/SaveAttributesAsync` |
| `SaopWrite` | `ADMIN`, `CATALOG_EDITOR` | `SaopWriteService` — uvrstitev v vrsto, odobritev, preklic, ponovno pošiljanje, potrditev dogodkov |
| `AlertWrite` | `ADMIN`, `COMMERCIAL` | `IntranetDataService.AcknowledgeAlertAsync/ResolveAlertAsync`, `RulesWriteService.SaveCheckThresholdAsync` |
| `BusinessWrite` | `ADMIN`, `CATALOG_EDITOR`, `COMMERCIAL` | `RulesWriteService.SaveRequirementAsync/SaveMappingAsync` |

Varovalka teče **pred** klicem baze in vrže `UnauthorizedAccessException`. Uporabnika poišče v
`HttpContext` (minimalni API) oziroma v `AuthenticationStateProvider` (vezje Blazor Server).
`PimWriteGuard.Trusted(...)` je izhod za procese brez prijavljenega uporabnika (konzolni testi,
orodja); v `src/PIM.Intranet` ga pogodbeni test `PIM.F10.AuthTests` prepove.

Kartica izdelka in stran `/preverbe` isti seznam vlog uporabita za izris: brez pravice ni gumba
»Shrani spremembe«, polja kanala se izrišejo kot vrednosti in ob kartici stoji značka
»Samo za branje«. To je videz; varovalka je v servisu.

### 1.4 Spletišča izdelka namesto »Objava na spletu« (P1-6, 2026-09-09)

Kartica izdelka ima v sklopu **Splet** razdelek »Spletišča« s potrditvenim poljem na spletišče
(`svetila_si`, `videlektro`). Označeno spletišče pomeni dvoje: izdelek tja gre in spletni profil
tega spletišča ga validira. `Product.WebPublish` iz SAOP za to **ni** več merilo — odločitev
uporabnika 2026-09-08; podrobnosti in migracija 182 so v [`DATABASE.md`](DATABASE.md).

- branje: `ProductEditService.GetWebShopsAsync` → `intranet.GetProductWebShops` (vrne tudi
  neoznačena spletišča, sicer obrazec nima praznega polja);
- zapis: `ProductEditService.SaveWebShopsAsync` → `pim.SaveProductWebShops`, pod politiko
  `CatalogWrite`; procedura zapiše zgodovino in izdelek takoj revalidira, zato se stanje kakovosti
  spremeni v istem klicu;
- vloga brez pravice pisanja polja vidi onemogočena in namesto gumba dobi pojasnilo.

Dokaz: `docs/pregled-20260909/Preveri-Spletisca.ps1` — 10 preverb, vse OK.

### 1.3 Zavrnjen dostop in napaka (P0, 2026-09-09)

Popravek ugotovitve **A5**. `/brez-dostopa` (`Pages/AccessDenied.razor`) pove, kdo si, katere
vloge imaš, katero pot si zahteval in komu pisati. `Pages/Error.razor` ni več angleška predloga
(»Error.«, »Development Mode«), ampak slovenska stran z oznako zahteve in potjo nazaj. Meni
postavk, ki jih vloga ne sme odpreti, ne kaže več: `PimNavigation` ima vloge na postavkah
`Izhod v SAOP` in `Stranke`, ujemanje z `[Authorize(Roles = …)]` ciljne strani pa preverja test.

---

## 2. Poti (routes)

| Pot | Komponenta | Avtorizacija | Postavitev |
|---|---|---|---|
| `/` | `Pages/Home.razor` | zahteva sejo (fallback) | preusmeri na `/nadzorna-plosca`; .NET 10 SSR-preusmeritev ne uporablja `NavigationException` (`BlazorDisableThrowNavigationException=true`) |
| `/prijava` | `Pages/Login.razor` | `[AllowAnonymous]` | `EmptyLayout` |
| `/nadzorna-plosca` | `Pages/Dashboard.razor` | `[Authorize]` | `MainLayout` |
| `/izdelki` | `Pages/Products.razor` | `[Authorize]` | `MainLayout` |
| `/izdelki/uvoz` | `Pages/ProductImport.razor` | `[Authorize(Roles = "ADMIN,CATALOG_EDITOR,COMMERCIAL")]` | `MainLayout` |
| `/izdelki/{ProductId:long}` | `Pages/ProductCard.razor` | `[Authorize]` | `MainLayout` |
| `/zaloge` | `Pages/Stocks.razor` | `[Authorize]` | `MainLayout` |
| `/napake-validacije` | `Pages/ValidationErrors.razor` | `[Authorize]` | `MainLayout` |
| `/karantena` | `Pages/RawQuarantine.razor` | `[Authorize]` | `MainLayout` |
| `/teki-obdelave` | `Pages/PipelineRuns.razor` | `[Authorize]` | `MainLayout` |
| `/mediji` | `Pages/Media.razor` (mreža predogledov, vrste kot filtri) | `[Authorize]` | `MainLayout` |
| `/partnerji`, `/cene` | istoimenske strani | `[Authorize]` | `MainLayout` |
| `/kakovost` | `Pages/Quality.razor` | `[Authorize]` | `MainLayout` |
| `/kakovost/napake`, `/kakovost/karantena` | alias obstoječih strani | `[Authorize]` | `MainLayout` |
| `/kakovost/prevodi`, `/kakovost/kategorije` | strani vrzeli preslikave | `[Authorize]` | `MainLayout` |
| `/zajem` | `Pages/Ingest.razor` | `[Authorize]` | `MainLayout` |
| `/zajem/viri`, `/zajem/teki`, `/zajem/tezave`, `/zajem/preslikave` | pet glavnih pogledov vhodnega modula skupaj z `/zajem` | `[Authorize]` | `MainLayout` |
| `/zajem/viri/{SourceCode}`, `/zajem/teki/{RunId:guid}`, `/zajem/tezave/{IssueKind}/{IssueId:long}` | podrobnosti vira, teka in težave | `[Authorize]`; tehnični predogled samo `ADMIN` | `MainLayout` |
| `/zajem/cakalna-vrsta`, `/zajem/neujemanja` | podrobna delovna seznama iz pogleda Preslikave/Težave | `[Authorize]` | `MainLayout` |
| `/izvozi`, `/izvozi/profili/{id}` | profili in stolpci izvoza | `[Authorize]` | `MainLayout` |
| `/izvozi/mnozicno`, `/izvozi/obvestila` | odhodna množična obdelava in dogodki | `ADMIN, CATALOG_EDITOR, COMMERCIAL` | `MainLayout` |
| `/outbound` | `Pages/Outbound.razor` | `ADMIN, CATALOG_EDITOR, COMMERCIAL` | `MainLayout` |
| `/saop`, `/saop/zgodovina`, `/saop/odkloni`, `/saop/polja` | pregled, zgodovina, odkloni in šifrant polj izhoda v SAOP | `ADMIN, CATALOG_EDITOR` (`/saop/polja` `[Authorize]`) | `MainLayout` |
| `/saop/artikli` | `Pages/SaopItems.razor` — **vnos novih artiklov in sprememb v enem obrazcu**; metoda (POST/PATCH) ni izbira uporabnika, ampak izpeljava iz tega, ali je artikel v `canon.Product` | `ADMIN, CATALOG_EDITOR` | `MainLayout` |
| `/stranke` | `Pages/Customers.razor` | `ADMIN, CATALOG_EDITOR, COMMERCIAL` | `MainLayout` |
| `/stranke/{CustomerId:long}` | `Pages/CustomerDetail.razor` | `ADMIN, CATALOG_EDITOR, COMMERCIAL` | `MainLayout` |
| `/pravila-popustov` | `Pages/DiscountRules.razor` | `ADMIN, CATALOG_EDITOR, COMMERCIAL` | `MainLayout` |
| `/pravila`, `/pravila/validacija`, `/pravila/slovar`, `/pravila/preslikave` | registri pravil | `ADMIN, CATALOG_EDITOR, COMMERCIAL` | `MainLayout` |
| `/nastavitve` in `/nastavitve/{atributi,kategorije,skladisca,kanali,jeziki}` | bralni pogledi nastavitev kataloga | `ADMIN, CATALOG_EDITOR` | `MainLayout` |
| `/nastavitve/nabori-atributov` | `Pages/CategoryAttributeSets.razor` — pregled naborov atributov po kategorijah za vsako drevo (svetila, videlektro) z množičnim urejanjem (izbira več, lepljenje seznama, kopiranje nabora); migracija 170 | `ADMIN, CATALOG_EDITOR` | `MainLayout` |
| `/sistem`, `/sistem/napake`, `/sistem/vloge` | sistemska razdelilna stran in bralni pogledi | `ADMIN` | `MainLayout` |
| `/system/integracije` | `Pages/SystemIntegrations.razor` | `ADMIN` | `MainLayout` |
| `/system/uporabniki` | `Pages/SystemUsers.razor` | `ADMIN` | `MainLayout` |
| `/Error` | `Pages/Error.razor` | zahteva sejo (fallback) | privzeto |

`Pages/Counter.razor` in `Pages/Weather.razor` sta ostanka predloge in **nimata**
direktive `@page`; pogodbeni test to izrecno preverja.

`Routes.razor` za nepooblaščene uporabnike izriše besedilo »Za nadaljevanje se
prijavite.« s povezavo na `prijava` (base-relativno) in ne preusmeri samodejno.

### 2.1 Modul Vhodni podatki

V stranskem meniju je namenoma samo en cilj **Zajem in preslikave**. Znotraj njega je pet
enakovrednih operativnih pogledov, zato uporabniku ni treba izbirati med dvanajstimi
tehničnimi stranmi:

| Pogled | Odgovori na vprašanje | Dejanski vir |
|---|---|---|
| **Pregled** | Ali vsi vhodi delajo; kdaj je bil zadnji poskus in kdaj zadnji uspeh? | `map.SourceConnector`, `ops.PipelineRun`, `ops.IntegrationHealth`, `ops.ScheduleProfile`, `stock.SyncRun` |
| **Viri** | Kaj je registrirano, kaj sme ustvarjati artikle, katere entitete in preslikave ima? | `map.SourceConnector`, `map.EntityMapping`, `map.FieldMapping`, `map.Watermark`, `map.StockIdentityRule` |
| **Teki** | Kaj se je izvedlo, s kakšnim rezultatom, koraki in vhodnimi stranmi? | enoten bralni pogled čez `ops.PipelineRun`/`ops.PipelineStepLog` in `stock.SyncRun` |
| **Težave** | Kaj čaka, je v karanteni, zavrnjeno ali tehnično spodletelo? | `raw.Inbox`, `stock.UnmatchedPosition`, vhodna `ops.DeadLetterQueue` in `ops.ErrorLog` z dejanskim `RunId` |
| **Preslikave** | Česa PIM vsebinsko še ne razume? | `map.UnmappedValue`, `map.MissingTranslationOpen`, `map.SourceCategoryToMap`, `map.FieldMapping` |

Zaloga je zavestno razdeljena: zdravje **zajema zaloge** je tukaj, trenutno poslovno stanje
zaloge pa ostane na `/zaloge`. Administrator lahko na Pregledu, Tekih in Težavah preklopi na
vsa podjetja; drugi uporabniki in neposredne podrobnostne poti so omejeni na aktivno
organizacijo. Predogled vhodnega payload-a je samo za `ADMIN`, omejen na 20.000 znakov in
nikoli ne bere poverilnic. Ločene vloge »operater integracij« ali »tehnična podpora« še ni v
`sec.Role`, zato je vmesnik ne izumlja.

Prva dostava je bralna. Ponovni zagon, nalaganje datoteke, potrjevanje prevoda in urejanje
preslikav se ne prikažejo, dokler zanje ni revizijsko sledljive procedure. Znana sledilna
vrzel ostaja pri zalogovnem writerju: nepričakovana izjema povrne celotno transakcijo, zato
`stock.SyncRun` nima lažnega zapisa `Failed`; UI lahko pokaže zadnji uspeh, svežino in
zavrnjene pozicije, ne more pa prikazati dogodka, ki ga worker ni trajno zapisal.

---

## 3. Dejanski viri podatkov

Poslovna vsebina se bere prek `IntranetDataService`, `ProductWorkbenchService`,
`CatalogReadService`, `PipelineReadService`, `GovernanceReadService` in
`IntranetUserAdministrationService`.
Skupni `PimDb` izvaja parametrizirane ukaze in preslikava stolpce po imenu. Storitve uporabljajo
`Microsoft.Data.SqlClient` in povezovalni niz `ConnectionStrings:Pim`. Intranet ne
kliče HTTP-ja neposredno — to varovalko preverja test F8.

### 3.1 Bralne poti

| Metoda storitve | SQL vir | Uporabljeno na |
|---|---|---|
| `GetCurrentOrganizationAsync` | `SELECT TOP (1) … FROM dbo.OrganizationConfig WHERE IsActive = 1` | `MainLayout` in vse strani s podatki |
| `PimNavigation.For` | katalog poti v kodi + filtriranje po zahtevkih vlog | `NavMenu` |
| `GetDashboardAsync` | `intranet.GetDashboard` | `/nadzorna-plosca` |
| `ProductWorkbenchService.GetProductListAsync` | `intranet.GetProductList` (2 nabora: vrstice + `TotalCount`); `@OrganizationId` je neobvezen — `NULL` pomeni **vsa podjetja**, neznano podjetje vrne prazen nabor; filtri iskanje, shranjen pogled, podjetje, proizvajalec, dobavitelj, skupina, oddelek, ERP/spletni status, aktivnost, zastavica za splet, razred popolnosti, **kategorija z vsemi potomci** (migracija 175), razvrstitev in stran | `/izdelki`, `/izvoz/izdelki.csv` |
| `ProductWorkbenchService.GetProductListViewsAsync` | `intranet.GetProductListViews` (števci osmih shranjenih pogledov); `NULL` podjetje pomeni vsa | `/izdelki` |
| `ProductWorkbenchService.GetProductListFacetsAsync` | `intranet.GetProductListFilters` (4 nabori: proizvajalci, dobavitelji, skupine, oddelki); `FacetLabel` je **ime partnerja** iz `canon.PartnerName` (pogled nad `b2b.Customer`), `FacetValue` ostane šifra, ker ta potuje v SAOP; `NULL` podjetje pomeni vsa | `/izdelki` |
| `ProductExportService.BuildAsync` | `intranet.GetProductList` (en klic, `@Take` do 20.000) + `intranet.GetProductFieldValues` in `intranet.GetSaopTemplateColumns` (migracija 117) | `/izvoz/izdelki.xlsx` |
| `ProductWorkbookService.BuildAsync` | `intranet.GetProductList` + `intranet.GetProductWorkbook` (migracije 171, 173 in 175; šest naborov: vrednosti polj, kategorije po straneh, atributi, slike, šifrant atributov z naborom kategorije, register zahtevanih polj) | `/izvoz/izdelki.xlsx?predloga=delovni` |
| `ProductWorkbookService.PreviewAsync` | isti klic; predogled obdrži samo celice, ki se razlikujejo od zapisanega stanja | `/izdelki/uvoz` |
| `ProductWorkbookService.ApplyAsync` | `pim.SaveProductTexts`, `pim.SaveProductAttributes`, `pim.SetProductCategories`, `out.EnqueueSaopItemChanges` — vsak stolpec gre k svojemu lastniku | `/izdelki/uvoz` |
| `ProductEditService.SaveTextsAsync` | `pim.SaveProductTexts` (migracija 111) — piše besedila, ki so last PIM, sproži zgodovino prek sprožilcev in **takoj revalidira ta en izdelek**; besedilo, ki ga piše SAOP, zavrne z napako 52402 | `/izdelki/{id}` |
| `ProductEditService.SaveAttributesAsync` | `pim.SaveProductAttributes` (migracija 111) — enako za lastnosti izdelka | `/izdelki/{id}` |
| `SaopWriteService.EnqueueAsync` | `out.EnqueueSaopItemChanges` — polje, ki ga PIM piše nazaj v SAOP, gre v odhodno vrsto in čaka odobritev | `/izdelki/{id}`, `/izvozi/mnozicno`, `/saop/artikli` |
| `SaopItemWriteService.GetContractAsync` | `out.GetSaopXmlContract` (oblika dokumenta + 26 elementov) in `intranet.GetWritableSaopFields` (23 od njih je v lasti PIM) — vmesnik ponudi samo polja, ki jih baza dovoli, sicer bi jih `out.EnqueueMessage` zavrnil z 51010 | `/saop/artikli` |
| `SaopItemWriteService.GetItemStateAsync` | `out.GetSaopItemWriteState` (3 nabori: `ExistsInSaop` in izvor, kanonične vrednosti, privzetki iz `out.SaopAddDefault`) | `/saop/artikli` |
| `SaopItemWriteService.GetChannelStateAsync` | `SELECT … FROM dbo.IntegrationProfile WHERE TargetKind = 'SAOP_PRODUCT'` — brez omogočenega profila baza zavrne vsako sporočilo z 51001; stran to pove **pred** vnosom | `/saop/artikli` |
| `SaopItemWriteService.BuildPlan` → `PIM.Outbound.SaopItemPlanner.Plan` | brez baze: `SaopIntentResolver` izbere POST ali PATCH, `SaopDocumentBuilder` sestavi dokument — ista gradnika kot pošiljatelj (`SaopDocumentRunner.Assemble`), zato je predogled enak poslanemu | `/saop/artikli` |
| `GetProductOrganizationAsync` | `SELECT TOP (1) OrganizationId … FROM canon.Product WHERE ProductId = @ProductId` — kartica izdelka dobi obseg iz izdelka, ker je dosegljiva iz seznama vseh podjetij | `/izdelki/{id}` |
| `GetProductsAsync` | `intranet.GetProducts @OrganizationId, @Skip, @Take, @Search, @Status` (2 nabora: vrstice + `TotalCount`) | zapuščinska pot; seznam je od migracije 101 na `GetProductList` |
| `ProductWorkbenchService.GetProductCardAsync` | `intranet.GetProductCard` (15 naborov: glava, polja z lastništvom, čakajoče prekrivke, besedila, lastnosti, kategorije, mediji, dokumenti, cene, zaloga, trgovinski podatki, profili, težave, odhodna pot in zgodovina) | `/izdelki/{id}` |
| `ProductWorkbenchService.GetProductOriginAsync` | `intranet.GetProductOrigin` (zadnjih največ 100 ujemajočih se vhodnih zapisov po dejanski izluščeni identiteti) | `/izdelki/{id}` |
| `QualityReadService.GetIssuesAsync` | `intranet.GetQualityIssues` (3 nabori: izdelki na strani, njihove težave, `TotalCount`); stranicenje je po **izdelku**, filtri profil, resnost, obseg blokade, polje in iskanje | `/kakovost/napake`, `/napake-validacije` |
| `QualityReadService.GetOverviewAsync` | `intranet.GetQualityOverview` (3 nabori: skupno stanje, zahteve z največjim vplivom, razčlenitev po dobavitelju) | `/kakovost/napake` |
| `GetValidationIssuesAsync` | `intranet.GetValidationIssues` (3 nabori: težave, profili, najpogostejše) | `/nadzorna-plosca` |
| `GetQuarantineAsync` | `intranet.GetRawQuarantine` | `/karantena` |
| `GetPipelineRunsAsync` | `intranet.GetPipelineRuns` | `/teki-obdelave`, `/nadzorna-plosca` |
| `StockReadService.GetPositionsAsync` | `intranet.GetStockPositions` (2 nabora: pozicije + `TotalCount`); filtri vir, razpoložljivost, ujemanje z artiklom, svežina posnetka in iskanje | `/zaloge` |
| `StockReadService.GetOverviewAsync` | `intranet.GetStockOverview` (3 nabori: skupno stanje, svežina po viru, zavrnjene pozicije po razlogu) | `/zaloge` |
| `GetStocksAsync` | `intranet.GetStocks` | zapuščinska pot; seznam je od migracije 103 na `GetStockPositions` |
| `GetCustomersAsync` | `intranet.GetCustomers` | `/stranke` |
| `GetCustomerDetailAsync` | `intranet.GetCustomerDetail` | `/stranke/{id}` |
| `GetCustomerTypesAsync` | `intranet.GetCustomerTypes` | `/stranke/{id}`, `/pravila-popustov` |
| `GetShippingRulesAsync` | `intranet.GetDiscountRules` | `/pravila-popustov` |
| `GetValueTiersAsync` | `intranet.GetValueDiscountTiers` | `/pravila-popustov` |
| `GetGroupOverridesAsync` | `intranet.GetGroupDiscountOverrides` | `/pravila-popustov` |
| `GetOutboundAsync` | `intranet.GetOutboundMessages` | `/outbound` |
| `GetSystemIntegrationsAsync` | `intranet.GetSystemIntegrations` (2 nabora: integracije, opozorila) | `/system/integracije`, `/nadzorna-plosca` |
| `GovernanceReadService.GetFieldGapsAsync` | `val.ProductIssue` ⋈ `val.FieldRequirement`, združeno **po polju** in ne po profilu | `/kakovost` |
| `GovernanceReadService.GetUnblockPlanAsync` | en obhod `val.ProductIssue`; kumulativni učinek se izračuna v pomnilniku z bitno masko na izdelek | `/kakovost` |
| `IntranetUserAdministrationService.GetUsersAsync` | `sec.LocalUser` ⋈ `sec.LocalUserRole` ⋈ `sec.Role`, `STRING_AGG` vlog | `/system/uporabniki` |
| `CatalogReadService` | `canon.ProductMedia` **⊎ `canon.ProductDocument`** (`UNION ALL`), `ProductPrice`, partnerji na izdelku, atributi, kategorije, skladišča, kanali in jeziki | `/mediji`, `/cene`, `/partnerji`, `/nastavitve/*` |
| `PipelineReadService` | enotni vhodi čez `map.*`, `raw.Inbox`, `ops.PipelineRun`/napake in `stock.SyncRun`/zavrnjene pozicije | `/zajem/*`, deli `/kakovost` |
| `GovernanceReadService` | izvozni in validacijski profili, slovar, preslikave, napake, alarmi in vloge | `/izvozi/*`, `/pravila/*`, `/sistem/*` |
| `GovernanceReadService.GetExportReadinessAsync` | `intranet.GetExportReadiness` (3 nabori: objavljeno/neobjavljeno, zahteve ki ustavijo objavo, pokritost stolpcev po profilu) | `/izvozi` |

### 3.2 Zapisovalne poti

| Metoda storitve | SQL procedura | Stran |
|---|---|---|
| `SaveCustomerWebProfileAsync` | `b2b.SaveCustomerWebProfile` | `/stranke/{id}` |
| `SaveCustomerValueTierAsync` | `b2b.SaveCustomerValueTier` | `/stranke/{id}` |
| `SaveShippingRuleAsync` | `b2b.SaveDiscountRule` | `/pravila-popustov` |
| `SaveCustomerTypeMappingAsync` | `b2b.SaveCustomerTypeMapping` | `/pravila-popustov` |
| `SaveValueTierAsync` | `b2b.SaveValueDiscountTier` | `/pravila-popustov` |
| `SaveGroupOverrideAsync` | `b2b.SaveGroupDiscountOverride` | `/pravila-popustov` |
| `ApproveOutboundAsync` / `CancelOutboundAsync` / `RetryOutboundAsync` | `out.ApproveMessage` / `out.CancelMessage` / `out.RetryMessage` | `/outbound` |
| `AcknowledgeAlertAsync` / `ResolveAlertAsync` | `intranet.AcknowledgeAlert` / `intranet.ResolveAlert` | `/system/integracije` |
| `IntranetUserAdministrationService.AddDomainUserAsync` | `sec.CreateDomainUser` (po uspešnem AD iskanju) | `/system/uporabniki` |

Vse zapisovalne procedure prejmejo `@ChangedBy` oziroma `@Actor` iz prijavljene
identitete; organizacija se vzame iz `GetCurrentOrganizationAsync`, nikoli kot
konstanta (pogodbeni test prepoveduje vzorec `Async(2,`).

### 3.3 Paginacija in filtri — kaj je strežniško in kaj ne

| Stran | Paginacija | Filtri |
|---|---|---|
| `/izdelki` | **strežniška**, `Take = 50`, `TotalCount` iz drugega nabora | vsi strežniški: podjetje (privzeto vsa), iskanje, shranjen pogled, proizvajalec, dobavitelj, skupina, oddelek, ERP, splet, aktivnost, objava, popolnost |
| `/stranke` | odjemalska nad naloženim naborom, `PageSize = 25` | odjemalski (iskanje, vrsta, tip) |
| `/teki-obdelave` | odjemalska, `PageSize = 10` | odjemalski (iskanje, status) |
| `/outbound` | odjemalska, `PageSize = 10` | odjemalski (iskanje, status) |
| `/zaloge`, `/napake-validacije`, `/karantena`, `/system/integracije` | brez strežniške paginacije; prikaže se vrnjeni nabor | odjemalski |

Read modeli strank, tekov, outbounda in zalog **nimajo** `TotalCount` niti
strežniških filtrov, zato prikazano število vedno predstavlja samo vrnjeni nabor.

### 3.4 Organizacijska meja brez globalnega izbirnika

`MainLayout` nima globalnih izbirnikov organizacije, kanala ali jezika. Strani, ki delajo v
privzetem organizacijskem obsegu, uporabijo prvo aktivno organizacijo iz
`dbo.OrganizationConfig`; večorganizacijski in kanalski pregledi ponudijo filter lokalno,
kjer je njegov pomen jasen. Pot `/kontekst` in kontekstni piškotki niso del aktivne aplikacije.

---

## 4. Vloge in navigacija

Vloge so vrstice v `sec.Role`; imena so kode, ki se preslikajo v `ClaimTypes.Role`.

| Koda | Ime | Seed |
|---|---|---|
| `ADMIN` | Skrbnik | `sql/migrations/010_CreateIntranetF4.sql` |
| `CATALOG_EDITOR` | Urednik kataloga | `010_CreateIntranetF4.sql` |
| `VIEWER` | Pregledovalec | `010_CreateIntranetF4.sql` |
| `COMMERCIAL` | Urednik komerciale | `sql/migrations/020_CreateB2bChannel.sql` |

Levi meni uporablja katalog `PimNavigation` v kodi. Navigacija je del izdelka, zato se pot,
avtorizacija in stran spremenijo v istem commitu; `NavMenu` postavke filtrira po vlogah.
Vse povezave so base-relativne zaradi gostovanja pod IIS `/PIM`.

Meni je razdeljen po trajnem podatkovnem toku: **Vhodni podatki**, **PIM katalog**,
**Kakovost**, **Izhodi ERP in splet**, **Poslovanje**, **Upravljanje** in
**Administracija**. `PimLifecycle.ResolveLifecycleArea` isto področje izpelje tudi za
podstrani in ga prikaže v zgornji vrstici. S tem uporabnik na primer na strani preslikav še
vedno vidi, da je v upravljanju podatkov, na karanteni pa v kakovosti. Poslovni model in
obvezna pogodba vsake strani sta v `docs/PRODUKTNI_MODEL_PIM.md`.

Vizualna pogodba menija sledi referenci v2, ne njeni informacijski arhitekturi: temno
skrilasto ozadje, svetle nepodčrtane povezave, aktivna kartica z oranžno levo črto, opis pri
pomembnih delovnih ciljih in puščica pri razdelilnih straneh. Ker sidro izriše komponenta
`NavLink`, ga izolirani `NavMenu.razor.css` doseže prek `::deep`; brez tega brskalnik pokaže
privzeto modro podčrtano povezavo. Referenčni blok »Spletni kontekst / Svetila.si« ni del
NoviPIM menija in se ne prenese.

Tabele `sec.Navigation*` ostajajo v bazi kot zgodovinski bralni model, vendar menija ne polnijo.
Njihove zasejane postavke so:

| Skupina (`GroupCode`) | Postavka (`ItemCode`) | Pot | Vloge | Migracija |
|---|---|---|---|---|
| `NADZOR` (Nadzor) | `DASHBOARD` | `/nadzorna-plosca` | vse takrat obstoječe vloge (CROSS JOIN) | 010 |
| `KATALOG` (Katalog) | `PRODUCTS` | `/izdelki` | vse takrat obstoječe vloge | 010 |
| `NADZOR` | `ISSUES` | `/napake-validacije` | vse takrat obstoječe vloge | 010 |
| `NADZOR` | `QUARANTINE` | `/karantena` | vse takrat obstoječe vloge | 010 |
| `NADZOR` | `RUNS` | `/teki-obdelave` | vse takrat obstoječe vloge | 010 |
| `PIM` | `STOCKS` | `/zaloge` | vse vloge (CROSS JOIN) | 018 |
| `PRAVILA` (Pravila) | `CUSTOMERS_B2B` | `/stranke` | `ADMIN`, `CATALOG_EDITOR`, `COMMERCIAL` | 020 |
| `PRAVILA` | `DISCOUNT_RULES_B2B` | `/pravila-popustov` | isti trije | 020 |
| `NADZOR` | `USERS` | `/system/uporabniki` | `ADMIN` | 026 |

Te vrstice ne vplivajo več na vidnost ali vrstni red menija.

### Prijava in izvor uporabnikov

`sec.LocalUser.AuthSource` loči dve poti (`Services/LocalUserAuthenticationService.cs`):

- `LOCAL` — geslo se preveri s `PasswordHasher.Verify` (PBKDF2-SHA256, 210 000
  iteracij, 16 B sol, 32 B ključ, zapis `v1.<iteracije>.<sol>.<ključ>`).
- `DOMAIN` — geslo se preveri prek `ActiveDirectoryService.Validate`
  (`PrincipalContext(ContextType.Domain, …)`, `ContextOptions.Negotiate`). Domena se
  bere iz konfiguracije `ActiveDirectory:Domain`, privzeto `AD`. Identiteta mora
  biti v obliki `DOMENA\uporabnik`; AD pot je na voljo samo na Windows.

Lokalne uporabnike ustvarja orodje `tools/PIM.UserProvisioning` (procedura
`sec.CreateLocalUser`); domenske uporabnike doda skrbnik na `/system/uporabniki`
prek `sec.CreateDomainUser`. Aplikacija nikjer ne vsebuje privzetega gesla —
pogodbeni test to preverja tako v migraciji kot v provisioning orodju.

---

## 5. Testni projekti

Testi so **konzolne aplikacije** (`OutputType=Exe`, net10.0), ne xUnit. Vsak vrne
izjemo ob kršitvi in izpiše vrstico `… PASS.` ob uspehu. Poganja se jih z
`dotnet run --project <pot>`.

| Projekt | Kaj varuje | Izpis ob uspehu |
|---|---|---|
| `tests/PIM.F8.IntranetTests` | `/outbound`: pot, vloge, slovenske oznake, uporaba `intranet.GetOutboundMessages` in `out.*` procedur, prepoved `HttpClient` | `F8 intranet: … PASS.` |
| `tests/PIM.F9.IntranetTests` | `/system/integracije`: pot, `ADMIN`, dejanji Potrdi/Razreši, `intranet.GetSystemIntegrations`, prepoved `TODO` | `F9 intranet: … PASS.` |
| `tests/PIM.F10.AuthTests` | prijava, AD, administracija uporabnikov, migraciji 026/027, preslikave po imenih stolpcev, uporaba `GetCurrentOrganizationAsync` na vseh straneh, prepoved Bootstrap razredov na treh zapisovalnih straneh, `Counter`/`Weather` brez poti | `F10 auth contract PASS.` |
| `tests/PIM.F10.DashboardUxTests` | `/nadzorna-plosca`: 5 KPI kartic, poimenovane regije, `aria-hidden` na ikonah, oznake statusnih čipov, `role="progressbar"`, `role="alert"`/`role="status"`, `:focus-visible`, dovoljeni nabor `Data.*` klicev, prepoved kontrol pisanja in izmišljenih vrednosti | `F10 dashboard UX contract PASS.` |
| `tests/PIM.F10.ProductsUxTests` | `/izdelki` | `F10 products UX contract PASS.` |
| `tests/PIM.F10.ProductWorkbookTests` | `/izdelki` → `/izdelki/uvoz` | `F10 delovni list izdelkov: vse OK.` |
| `tests/PIM.F10.ProductDetailUxTests` | `/izdelki/{id}` | `F10 product detail UX contract PASS.` |
| `tests/PIM.F10.StocksUxTests` | `/zaloge` | `F10 stocks UX contract PASS.` |
| `tests/PIM.F10.QualityUxTests` | `/kakovost` (pregled po polju, načrt odblokiranja, zavihek profilov), `/napake-validacije` in `/karantena` | `F10 quality UX contract PASS.` |
| `tests/PIM.F10.CustomersUxTests` | `/stranke` | `F10 customers UX contract PASS.` |
| `tests/PIM.F10.MediaUxTests` | `/mediji`: razvrstitev vrste medija (C# in SQL iz istih seznamov), združen izvor `ProductMedia` ⊎ `ProductDocument`, vrste kot filtri s števci, samodejno večbesedno iskanje, prepoved `RenderTreeBuilder` v predogledih | `PIM.F10.MediaUxTests: vse trditve drzijo.` |
| `tests/PIM.F10.PipelineRunsUxTests` | `/teki-obdelave` | `F10 pipeline runs UX contract PASS.` |
| `tests/PIM.F10.OutboundUxTests` | `/outbound` (predstavitveni del) | `F10 outbound UX contract PASS.` |
| `tests/PIM.F10.SystemIntegrationsUxTests` | `/system/integracije` (predstavitveni del) | `F10 system integrations UX contract PASS.` |
| `tests/PIM.F10.CategoryAttributeSetUxTests` | `/nastavitve/nabori-atributov`: pot, vloge, akter, napaka iz baze do uporabnika, stran ne pozna tabel in ne piše sama, servis kliče postopke 147/170, izbira drevesa, stolpci »koliko in kateri«, tri množične poti (izbira več, lepljenje, kopiranje), hub in `PimLifecycle`, migracija 170 gre skozi `canon.SaveCategoryAttributeSet` | `PIM.F10.CategoryAttributeSetUxTests: vse pogodbe drzijo.` |

Vsi `PIM.F10.*UxTests` imajo isti vzorec: preverijo obstoj `Pages/<Stran>.razor`
**in** pripadajočega `<Stran>.razor.css`, dostopnostne atribute, sloge fokusa,
zaprt seznam dovoljenih `Data.*` klicev in izrecen seznam prepovedanih izmišljenih
vrednosti iz UX slik.

Vsi projekti F10 so v `PIM.sln`; merodajni zagon ostaja
`scripts\run_tests.ps1`, ker ta poleg builda dejansko požene tudi konzolne testne projekte.

---

## 6. UX omejitve

Vir pravil: `PIM_Solution/UX/README.md`, `TARGET_STATE.md`, `LESSONS.md`.

1. **Vsaka vidna poslovna vrednost izvira iz PIM baze.** Statični števci, odstotki,
   imena, datumi in primeri iz UX slik so prepovedani; pogodbeni testi vsebujejo
   poimenske črne sezname (npr. `12.480`, `Janez Novak`, `Nedavne aktivnosti`).
2. **Referenčne slike so v `../PIM_test/UX_pictures/` in so samo vizualni standard**,
   ne podatkovna pogodba. Nova referenca se doda šele po potrditvi uporabnika, z
   imenom, ki se začne z `NOV_UX_` in vsebuje `PREDLOG`.
3. **Ne prikazujemo kontrol, ki navidezno shranjujejo**, če zapisovalna pot ne obstaja.
   Nove strani nastavitev so zato bralne; globalnih kontekstnih izbirnikov ni.
3a. **Izbira kategorije ali atributa gre skozi `Components/Shared/PimPicker.razor`** (izbirnik s
   tipkanjem, brez JavaScripta): išče po imenu, poti in kodi brez šumnikov (`PimText.Fold`), kaže
   drevo z zamikom in polno pot, tipke ↑ ↓ Enter Esc. Spustni seznam z vsemi 209 kategorijami ali
   vsemi atributi registra ni več sprejemljiv. Kjer izbirnik dovoli ustvarjanje (`AllowCreate`),
   pred tem opozori na isto ime (ustvarjanja ne ponudi) in našteje podobna imena — stran ne rabi
   svoje preverbe podvajanja (uporabnik 2026-09-08).
4. **Vizualni sistem:** temna leva navigacija 18 rem, svetla vsebina, bela zgornja
   vrstica; indigo za dejanja, oranžna kot identiteta/poudarek, zelena uspeh, rdeča
   napaka; bele kartice s tankim robom in minimalno senco; goste tabele z jasnim
   zaglavjem, statusnimi oznakami in enotnim dnom.
5. **Skupni razredi namesto Bootstrapa** na prenovljenih straneh: `page-header`,
   `ui-card`, `data-table`, `error-state`, `loading-state`, `status`, `metric-card`.
   Test prepoveduje Bootstrap razrede `row`, `col`, `card`, `table`, `form-control`,
   `form-select`, `form-check`, `btn` na `DiscountRules`, `CustomerDetail` in
   `SystemUsers`.
6. **Ikone so CSS/SVG, ne Unicode znaki.** Meni uporablja `navigation-icon`; znak
   `☰` je izrecno prepovedan. Okrasne ikone morajo imeti `aria-hidden="true"`.
7. **Dostopnost je del pogodbe:** vsak sklop ima `aria-labelledby` na obstoječ `h2`,
   statusni čipi imajo skrito oznako »Status: «, merilniki imajo
   `role="progressbar"` z `aria-valuenow/min/max/label`, stanje napake je
   `role="alert"`, nalaganje `role="status"`, vse interaktivne postavke pa imajo
   `:focus-visible` z `outline`.
8. **Nalaganje in napaka se izključujeta** — nadzorna plošča ne sme prikazati obojega
   hkrati; tabele potrebujejo `<caption>`.
9. **Vse notranje povezave morajo biti base-relativne** (`href="izdelki"`, ne
   `href="/izdelki"`), sicer pod `/PIM` padejo na koren strežnika. Prijavni obrazec
   oddaja na `auth/prijava`.
10. **Neznan status se izpiše z izvorno vrednostjo**; UI prevaja samo znane statuse.
11. **Brez read modela ni strani.** Novi pogledi prikazujejo samo registre in tabele, ki
    dejansko obstajajo; zapisovalnih gumbov na bralnih nastavitvah ni.
12. **Vgrajen predogled tuje datoteke mora imeti zasilni izhod.** Prvo stran PDF izriše
    brskalnikov bralnik v `<object type="application/pdf">`, vsebina pa pride s strežnika
    dobavitelja. Ta sme vgrajevanje zavrniti (`X-Frame-Options`, `frame-ancestors`) ali
    datoteko postreči samo po `http`. Zato je povezava na izvirnik **znotraj** `<object>`,
    kot nadomestna vsebina, in ne samo v nogi okna. Vgrajujemo le, kar brskalnik res zna
    pokazati (`MediaKindPolicy.IsInlineViewable` — danes samo PDF); `.rar`, `.dwg` in `.ldt`
    ostanejo povezava.
13. **Zavihek ostane na svoji strani.** Vrstica `page-tabs` sme vsebovati samo postavke, ki
    prikažejo vsebino na isti poti (gumb ali povezava na isti `@page` z drugim poizvedbenim
    parametrom). Povezava na drugo pot v vrstici zavihkov je past: videti je kot preklop
    pogleda, v resnici pa zamenja stran in z njo celo navigacijsko drevo. Take povezave sodijo
    med kartice (`PimHubCard`) ali navadne povezave. Prepoved velja za vse strani in jo
    preverja `PIM.F10.AuthTests` nad dobesednimi naslovi v vsaki `page-tabs` vrstici.
14. **Delo se deli po polju, ne po profilu.** Isto polje zahteva več profilov, zato razdelitev
    po profilih isto delo prikaže večkrat: merjeno je 340.227 odprtih napak izviralo iz 16 polj,
    stran pa je imela štiri zaporedne tabele profilov. Pregledi kakovosti se zato združujejo po
    `FieldCode`; profili ostanejo dosegljivi v svojem zavihku (`kakovost?pogled=profili`).
15. **Ob vsakem odstotku piše, česa je odstotek.** Delež na nivoju validacije je delež izdelkov
    **brez** odprte zahteve; gola številka »18,1 %« je bila neberljiva.
16. **Imena polj se ne prevajajo iz slovarja.** `QualityFieldPolicy` prevede samo predpono
    entitete (`ProductMedia` → »Medij«), ki pride iz imena kanonične tabele; ime polja ostane
    tako, kot je v registru. Register izvoznih stolpcev ima imena samo za del polj in so to
    imena stolpcev v CSV (`ean`, `images`, `name`), zato za to niso uporabna.
17. **Predogled slike ima vedno svoje razmerje in omejeno sliko.** Elementi, sestavljeni prek
    `RenderTreeBuilder` v `@code`, **ne dobijo oznake obsegnega CSS** (`b-…`), zato jih
    `<Stran>.razor.css` ne more omejiti — slika pride v naravni velikosti in razbije stran.
    Predogledi se zato pišejo kot razčlenjevalni izpis (`RenderFragment … => __builder => { … }`
    z markupom), ne s `builder.OpenElement`.

---

## 7. Ročni testni seznam (lokalno)

Predpogoji: razvojna baza `PIM` z uporabljenimi migracijami 001–027
(`dotnet run --project src/PIM.Migrator/PIM.Migrator.csproj -- --verify` vrne
uspeh), veljaven uporabnik v `sec.LocalUser`, konfiguriran `ConnectionStrings:Pim`.
Nikoli proti produkcijski bazi.

### 7.1 Zagon

```powershell
cd PIM_Solution
dotnet build PIM.sln --no-restore
$env:ASPNETCORE_URLS = "http://127.0.0.1:5088"
dotnet run --project .\src\PIM.Intranet\PIM.Intranet.csproj
```

Za preverjanje obeh načinov gostovanja se ista instanca odziva na `/…` in `/PIM/…`.

### 7.2 Seznam

- [ ] `GET http://127.0.0.1:5088/health` vrne 200 in `{"stanje":"zdravo"}`.
- [ ] `GET /` brez seje preusmeri oziroma pripelje na `/prijava`.
- [ ] `/prijava` se izriše s PIM identiteto in **stiliziran** (če je videti kot gol
      HTML, CSS ni dostavljen — glej naslednjo točko).
- [ ] `GET /app.css`, `/PIM.Intranet.styles.css`,
      `/favicon.svg` vrnejo 200 s pravim `Content-Type`; isto pod `/PIM/…`.
- [ ] Izrisani `<head>` vsebuje `<base href="…/">` oziroma `<base href="…/PIM/">`
      glede na način dostopa.
- [ ] Napačno geslo → vrnitev na `/prijava?napaka=1` s slovenskim sporočilom, brez
      podrobnosti o tem, kaj je bilo narobe.
- [ ] Pravilna prijava → preusmeritev na `/nadzorna-plosca`.
- [ ] `zapomniMe` označen → piškotek je trajen (potek ≈ 14 dni); neoznačen → sejni.
- [ ] Levi meni vsebuje samo postavke, dovoljene za vloge prijavljenega uporabnika;
      preveri z uporabnikom vloge `VIEWER` in `ADMIN`.
- [ ] V glavi so faza toka, opozorila in prikazno ime uporabnika; globalnih izbirnikov
      organizacije, kanala in jezika ni.
- [ ] Gumb menija je viden in preklaplja navigacijo tudi pri ozkem oknu.
- [ ] `/nadzorna-plosca`: pet KPI kartic v eni vrsti na namizju, paneli za kakovost,
      procese, opozorila, integracije in hitre dostope; nobene izmišljene vsebine.
- [ ] `/izdelki`: privzeto so vidna **vsa podjetja**, stolpec Podjetje pove, čigav je
      izdelek; filter podjetja zoži seznam, števce zavihkov in vrednosti spustnih
      seznamov. Iskanje in status filtrirata **strežniško**; »Prejšnja/Naslednja« se
      pravilno onemogočita na robovih; števec strani ustreza `TotalCount`.
- [ ] `/izdelki`: izbira izdelkov iz **dveh podjetij** onemogoči »Uredi izbrane« in to
      pove na glas; izbira iz enega podjetja odpre množično urejanje tega podjetja.
- [ ] `/izdelki/{id}`: glava, profili in odprte težave se ujemajo z bazo; neobstoječ
      ID ne vrže napake strežnika.
- [ ] `/izdelki/{id}`: aktivni zavihek je razpoznaven (podlaga, krepka pisava, črta) tudi
      med drsenjem; vrstica zavihkov je lepljiva.
- [ ] `/izdelki/{id}`: sprememba spletnega naziva ali lastnosti se po »Shrani in preveri«
      pozna takoj — popolnost in število težav se spremenita v isti zahtevi.
- [ ] `/izdelki/{id}`: sprememba polja, ki ga piše SAOP (npr. merska enota), **ne** spremeni
      kataloga takoj, ampak ustvari skupino v `/outbound`, ki čaka odobritev.
- [ ] `/zaloge`, `/napake-validacije`, `/karantena`, `/teki-obdelave`: podatki,
      prazno stanje in stanje napake so slovenski in razumljivi.
- [ ] `/stranke` → odpri stranko → spremeni spletni profil → Shrani; sprememba je
      vidna po ponovnem nalaganju in zapisana z uporabnikovim imenom v `b2b.AuditLog`.
- [ ] `/pravila-popustov`: prikazani so samo pragovi iz `GetValueTiersAsync`; brez
      statičnega stavka S1–S4.
- [ ] `/outbound` z vlogo `COMMERCIAL`: dejanja Odobri / Prekliči / Ponovi delujejo
      in po osvežitvi spremenijo stanje sporočila.
- [ ] `/system/integracije` z vlogo `ADMIN`: Potrdi in Razreši zapišeta uporabnika
      in čas na opozorilo.
- [ ] `/system/uporabniki` z vlogo `ADMIN`: iskanje po AD vrne razumljivo napako,
      kadar domena ni dosegljiva (in ne izjeme strežnika).
- [ ] Uporabnik brez vloge `ADMIN` na `/system/integracije` in `/system/uporabniki`
      ne dobi vsebine (preusmeritev na `/prijava` zaradi `AccessDeniedPath`).
- [ ] Odjava: gumb v glavi odjavi in pripelje na `/prijava`; vrnitev nazaj ne
      pokaže vsebine.
- [ ] Tipkovnica: `Tab` skozi glavo, meni in tabele vedno riše viden obris fokusa.
- [ ] Brskalniška konzola je brez napak 404 za CSS/JS.

### 7.3 Testi pred zaključkom

```powershell
cd PIM_Solution
dotnet run --project tests\PIM.F10.AuthTests\PIM.F10.AuthTests.csproj
dotnet run --project tests\PIM.F9.IntranetTests\PIM.F9.IntranetTests.csproj
dotnet run --project tests\PIM.F8.IntranetTests\PIM.F8.IntranetTests.csproj
# UX pogodbeni testi so od 2026-08-23 v PIM.sln in jih pozene scripts\run_tests.ps1.
# Posamicen zagon je se vedno mogoc:
dotnet run --project tests\PIM.F10.DashboardUxTests\PIM.F10.DashboardUxTests.csproj
dotnet run --project tests\PIM.F10.ProductsUxTests\PIM.F10.ProductsUxTests.csproj
dotnet run --project tests\PIM.F10.ProductDetailUxTests\PIM.F10.ProductDetailUxTests.csproj
dotnet run --project tests\PIM.F10.StocksUxTests\PIM.F10.StocksUxTests.csproj
dotnet run --project tests\PIM.F10.QualityUxTests\PIM.F10.QualityUxTests.csproj
dotnet run --project tests\PIM.F10.CustomersUxTests\PIM.F10.CustomersUxTests.csproj
dotnet run --project tests\PIM.F10.PipelineRunsUxTests\PIM.F10.PipelineRunsUxTests.csproj
dotnet run --project tests\PIM.F10.OutboundUxTests\PIM.F10.OutboundUxTests.csproj
dotnet run --project tests\PIM.F10.SystemIntegrationsUxTests\PIM.F10.SystemIntegrationsUxTests.csproj
```

Merodajni zaključni dokaz je `scripts\run_tests.ps1`; ukazi Node niso del tega sistema.

---

## 8. Znane omejitve

- Vizualnega E2E pregleda prijavljenih strani ni mogoče avtomatizirati brez
  veljavne uporabniške seje; agenti gesel ne uporabljajo. Ta pregled ostaja ročen.
- `/_framework/blazor.web.js` za neprijavljeno zahtevo vrne 302 na prijavo
  (posledica `FallbackPolicy`); prijava je navaden POST in JS ne potrebuje.
- Preslikava pravic uporabnika na dovoljene organizacije ali kanale še ne obstaja;
  večorganizacijski pogledi zato ostajajo omejeni na strani, ki imajo svojo preverjeno pot.
- Zgodovinskega read modela ni, zato na nadzorni plošči ni časovnih trendov.
