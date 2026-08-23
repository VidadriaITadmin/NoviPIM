# PIM Intranet — referenca

Ta dokument opisuje **dejansko stanje** aplikacije `PIM_Solution/src/PIM.Intranet`
(Blazor Web App, .NET 8, interaktivni strežniški način). Vse navedbe so povzete iz
izvorne kode, SQL migracij in testnih projektov v tem repozitoriju; nič ni povzeto
iz načrtov ali UX slik. Dokument ne vsebuje povezovalnih nizov, gesel ali vsebine
`appsettings*.json`.

Zadnji pregled kode: 2026-08-09.

---

## 1. Gostovanje in vstopne točke

| Dejstvo | Vrednost | Vir |
|---|---|---|
| Ogrodje | Razor Components + `AddInteractiveServerComponents()` | `Program.cs:12` |
| Osnovna pot | `app.UsePathBase("/PIM")` — deluje pod korenom in pod IIS virtualno aplikacijo `/PIM` | `Program.cs:36` |
| `<base href>` | dinamičen `@NavigationManager.BaseUri` | `Components/App.razor` |
| Statična sredstva | `UseStaticWebAssets()` + `app.css`, `PIM.Intranet.styles.css`, `bootstrap/bootstrap.min.css`, `favicon.svg` | `Program.cs:8`, `App.razor` |
| Razvojni URL | profil `http` → `http://localhost:5091`, IIS Express → `http://localhost:12988` | `Properties/launchSettings.json` |
| Jezik dokumenta | `<html lang="sl">`, celoten UI v slovenščini | `App.razor` |

Ne-Razor končne točke:

| Metoda | Pot | Avtorizacija | Opis |
|---|---|---|---|
| POST | `/auth/prijava` | `AllowAnonymous`, obvezen antiforgery token | prevzame `uporabniskoIme`, `geslo`, neobvezno `zapomniMe`; ob uspehu prijavi in preusmeri na `{PathBase}/nadzorna-plosca`, sicer na `{PathBase}/prijava?napaka=1` |
| POST | `/odjava` | zahteva sejo (velja `FallbackPolicy`) | odjava iz piškotne sheme, preusmeritev na `{PathBase}/prijava` |
| GET | `/health` | `AllowAnonymous` | vrne `{ "stanje": "zdravo" }` |

Avtentikacija je piškotna (`CookieAuthenticationDefaults`), `LoginPath` in
`AccessDeniedPath` sta oba `/prijava`. Globalni `FallbackPolicy` zahteva
prijavljenega uporabnika, zato je vse, kar ni izrecno `AllowAnonymous`, zaprto.
`zapomniMe` nastavi trajni piškotek z veljavnostjo 14 dni (`Program.cs:67-69`).

Zahtevki (claims) po prijavi: `ClaimTypes.Name` (uporabniško ime),
`ClaimTypes.GivenName` (prikazno ime), po en `ClaimTypes.Role` na vlogo.

---

## 2. Poti (routes)

| Pot | Komponenta | Avtorizacija | Postavitev |
|---|---|---|---|
| `/` | `Pages/Home.razor` | zahteva sejo (fallback) | preusmeri na `/nadzorna-plosca` |
| `/prijava` | `Pages/Login.razor` | `[AllowAnonymous]` | `EmptyLayout` |
| `/nadzorna-plosca` | `Pages/Dashboard.razor` | `[Authorize]` | `MainLayout` |
| `/izdelki` | `Pages/Products.razor` | `[Authorize]` | `MainLayout` |
| `/izdelki/{ProductId:long}` | `Pages/ProductDetail.razor` | `[Authorize]` | `MainLayout` |
| `/zaloge` | `Pages/Stocks.razor` | `[Authorize]` | `MainLayout` |
| `/napake-validacije` | `Pages/ValidationErrors.razor` | `[Authorize]` | `MainLayout` |
| `/karantena` | `Pages/RawQuarantine.razor` | `[Authorize]` | `MainLayout` |
| `/teki-obdelave` | `Pages/PipelineRuns.razor` | `[Authorize]` | `MainLayout` |
| `/outbound` | `Pages/Outbound.razor` | `ADMIN, CATALOG_EDITOR, COMMERCIAL` | `MainLayout` |
| `/stranke` | `Pages/Customers.razor` | `ADMIN, CATALOG_EDITOR, COMMERCIAL` | `MainLayout` |
| `/stranke/{CustomerId:long}` | `Pages/CustomerDetail.razor` | `ADMIN, CATALOG_EDITOR, COMMERCIAL` | `MainLayout` |
| `/pravila-popustov` | `Pages/DiscountRules.razor` | `ADMIN, CATALOG_EDITOR, COMMERCIAL` | `MainLayout` |
| `/system/integracije` | `Pages/SystemIntegrations.razor` | `ADMIN` | `MainLayout` |
| `/system/uporabniki` | `Pages/SystemUsers.razor` | `ADMIN` | `MainLayout` |
| `/Error` | `Pages/Error.razor` | zahteva sejo (fallback) | privzeto |

`Pages/Counter.razor` in `Pages/Weather.razor` sta ostanka predloge in **nimata**
direktive `@page`; pogodbeni test to izrecno preverja.

`Routes.razor` za nepooblaščene uporabnike izriše besedilo »Za nadaljevanje se
prijavite.« s povezavo na `prijava` (base-relativno) in ne preusmeri samodejno.

---

## 3. Dejanski viri podatkov

Vsa poslovna vsebina se bere prek `Services/IntranetDataService.cs` in
`Services/IntranetUserAdministrationService.cs`. Obe storitvi uporabljata
`Microsoft.Data.SqlClient` in povezovalni niz `ConnectionStrings:Pim`. Intranet ne
kliče HTTP-ja neposredno — to varovalko preverja test F8.

### 3.1 Bralne poti

| Metoda storitve | SQL vir | Uporabljeno na |
|---|---|---|
| `GetCurrentOrganizationAsync` | `SELECT TOP (1) … FROM dbo.OrganizationConfig WHERE IsActive = 1` | `MainLayout` in vse strani s podatki |
| `GetNavigationAsync` | `sec.NavigationItem` ⋈ `sec.NavigationGroup` ⋈ `sec.NavigationItemRole` ⋈ `sec.Role` (parametriziran `IN` seznam vlog) | `NavMenu` |
| `GetDashboardAsync` | `intranet.GetDashboard` | `/nadzorna-plosca` |
| `GetProductsAsync` | `intranet.GetProducts @OrganizationId, @Skip, @Take, @Search, @Status` (2 nabora: vrstice + `TotalCount`) | `/izdelki` |
| `GetProductDetailAsync` | `intranet.GetProductDetail` (4 nabori: glava, profili, težave, zgodovina sprememb) | `/izdelki/{id}` |
| `GetValidationIssuesAsync` | `intranet.GetValidationIssues` (3 nabori: težave, profili, najpogostejše) | `/napake-validacije`, `/nadzorna-plosca` |
| `GetQuarantineAsync` | `intranet.GetRawQuarantine` | `/karantena` |
| `GetPipelineRunsAsync` | `intranet.GetPipelineRuns` | `/teki-obdelave`, `/nadzorna-plosca` |
| `GetStocksAsync` | `intranet.GetStocks` | `/zaloge` |
| `GetCustomersAsync` | `intranet.GetCustomers` | `/stranke` |
| `GetCustomerDetailAsync` | `intranet.GetCustomerDetail` | `/stranke/{id}` |
| `GetCustomerTypesAsync` | `intranet.GetCustomerTypes` | `/stranke/{id}`, `/pravila-popustov` |
| `GetShippingRulesAsync` | `intranet.GetDiscountRules` | `/pravila-popustov` |
| `GetValueTiersAsync` | `intranet.GetValueDiscountTiers` | `/pravila-popustov` |
| `GetGroupOverridesAsync` | `intranet.GetGroupDiscountOverrides` | `/pravila-popustov` |
| `GetOutboundAsync` | `intranet.GetOutboundMessages` | `/outbound` |
| `GetSystemIntegrationsAsync` | `intranet.GetSystemIntegrations` (2 nabora: integracije, opozorila) | `/system/integracije`, `/nadzorna-plosca` |
| `IntranetUserAdministrationService.GetUsersAsync` | `sec.LocalUser` ⋈ `sec.LocalUserRole` ⋈ `sec.Role`, `STRING_AGG` vlog | `/system/uporabniki` |

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
| `/izdelki` | **strežniška**, `Take = 50`, `TotalCount` iz drugega nabora | strežniški `@Search` in `@Status` |
| `/stranke` | odjemalska nad naloženim naborom, `PageSize = 25` | odjemalski (iskanje, vrsta, tip) |
| `/teki-obdelave` | odjemalska, `PageSize = 10` | odjemalski (iskanje, status) |
| `/outbound` | odjemalska, `PageSize = 10` | odjemalski (iskanje, status) |
| `/zaloge`, `/napake-validacije`, `/karantena`, `/system/integracije` | brez strežniške paginacije; prikaže se vrnjeni nabor | odjemalski |

Read modeli strank, tekov, outbounda in zalog **nimajo** `TotalCount` niti
strežniških filtrov, zato prikazano število vedno predstavlja samo vrnjeni nabor.

### 3.4 Podatki, ki jih shell namenoma ne ponuja

`MainLayout` prikaže ime aktivne organizacije iz baze in prikazno ime iz zahtevka.
Izbirniki za **kanal**, **jezik** in **obvestila** so prisotni kot `disabled`
kontrole z razlago v `title`, ker za njih ni podatkovnega modela. Preslikave
uporabnik → organizacija oziroma uporabnik → kanal ni.

---

## 4. Vloge in navigacija

Vloge so vrstice v `sec.Role`; imena so kode, ki se preslikajo v `ClaimTypes.Role`.

| Koda | Ime | Seed |
|---|---|---|
| `ADMIN` | Skrbnik | `sql/migrations/010_CreateIntranetF4.sql` |
| `CATALOG_EDITOR` | Urednik kataloga | `010_CreateIntranetF4.sql` |
| `VIEWER` | Pregledovalec | `010_CreateIntranetF4.sql` |
| `COMMERCIAL` | Urednik komerciale | `sql/migrations/020_CreateB2bChannel.sql` |

Levi meni **ni** hardkodiran: `NavMenu` prebere `sec.NavigationItem` za vloge
prijavljenega uporabnika. Ikone se izberejo v `NavMenu.IconClass` po poti; za
neznano pot se uporabi `icon-link`.

Zasejane navigacijske skupine in postavke:

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

Pomembne posledice, ki jih je treba preveriti v vsakem okolju posebej:

- Migracija 018 veže postavko `STOCKS` na skupino z `GroupCode = N'PIM'`. Te skupine
  migracije v tem repozitoriju ne ustvarijo; če v bazi ne obstaja, se postavka ne
  vstavi in `/zaloge` v meniju ni, čeprav je pot dosegljiva neposredno.
- Za `/outbound` in `/system/integracije` v migracijah **ni** navigacijske postavke.
  Strani sta dosegljivi samo z neposrednim URL-jem (in prek nadzorne plošče).
- Postavke iz 010 in 018 so vezane na vloge s CROSS JOIN v času izvedbe migracije,
  zato vloga `COMMERCIAL` (dodana v 020) teh postavk ne dobi samodejno.

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
| `tests/PIM.F10.ProductDetailUxTests` | `/izdelki/{id}` | `F10 product detail UX contract PASS.` |
| `tests/PIM.F10.StocksUxTests` | `/zaloge` | `F10 stocks UX contract PASS.` |
| `tests/PIM.F10.QualityUxTests` | `/napake-validacije` in `/karantena` | `F10 quality UX contract PASS.` |
| `tests/PIM.F10.CustomersUxTests` | `/stranke` | `F10 customers UX contract PASS.` |
| `tests/PIM.F10.PipelineRunsUxTests` | `/teki-obdelave` | `F10 pipeline runs UX contract PASS.` |
| `tests/PIM.F10.OutboundUxTests` | `/outbound` (predstavitveni del) | `F10 outbound UX contract PASS.` |
| `tests/PIM.F10.SystemIntegrationsUxTests` | `/system/integracije` (predstavitveni del) | `F10 system integrations UX contract PASS.` |

Vsi `PIM.F10.*UxTests` imajo isti vzorec: preverijo obstoj `Pages/<Stran>.razor`
**in** pripadajočega `<Stran>.razor.css`, dostopnostne atribute, sloge fokusa,
zaprt seznam dovoljenih `Data.*` klicev in izrecen seznam prepovedanih izmišljenih
vrednosti iz UX slik.

**Opozorilo:** v `PIM.sln` je od projektov F10 vključen samo `PIM.F10.AuthTests`.
Projekti `PIM.F10.*UxTests` v rešitvi niso, zato jih `dotnet build PIM.sln` in
`dotnet test PIM.sln` ne zajameta — pognati jih je treba posamično.

`npm test` (vitest) in `npm run lint` sta v korenu repozitorija; `lint` je še vedno
samo nadomestek (`echo "(lint se doda kasneje)"`) in ničesar ne preverja.

---

## 6. UX omejitve

Vir pravil: `PIM_Solution/UX/README.md`, `TARGET_STATE.md`, `LESSONS.md`.

1. **Vsaka vidna poslovna vrednost izvira iz PIM baze.** Statični števci, odstotki,
   imena, datumi in primeri iz UX slik so prepovedani; pogodbeni testi vsebujejo
   poimenske črne sezname (npr. `12.480`, `Janez Novak`, `Nedavne aktivnosti`).
2. **Referenčne slike so v `../PIM_test/UX_pictures/` in so samo vizualni standard**,
   ne podatkovna pogodba. Nova referenca se doda šele po potrditvi uporabnika, z
   imenom, ki se začne z `NOV_UX_` in vsebuje `PREDLOG`.
3. **Ne prikazujemo kontrol, ki navidezno shranjujejo**, če procedura ne obstaja.
   Kanal, jezik in obvestila v glavi so zato onemogočeni z razlago.
4. **Vizualni sistem:** temna leva navigacija ≈200 px, svetla vsebina, bela zgornja
   vrstica; modra za dejanja, oranžna kot poudarek/opozorilo, zelena uspeh, rdeča
   napaka; bele kartice s tankim robom in minimalno senco; goste tabele z jasnim
   zaglavjem, statusnimi oznakami in enotnim dnom.
5. **Skupni razredi namesto Bootstrapa** na prenovljenih straneh: `page-header`,
   `ui-card`, `data-table`, `error-state`, `loading-state`, `status`, `metric-card`.
   Test prepoveduje Bootstrap razrede `row`, `col`, `card`, `table`, `form-control`,
   `form-select`, `form-check`, `btn` na `DiscountRules`, `CustomerDetail` in
   `SystemUsers`.
6. **Ikone so CSS/SVG, ne Unicode znaki.** Meni uporablja `menu-glyph-icon`; znak
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
11. **Brez read modela ni strani.** Mediji, partnerji, ceniki izdelkov in nastavitve
    kataloga niso implementirani, ker zanje ni dogovorjenih poti in modelov.
    Resnosti validacijskih napak ni, ker je shema nima.

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
- [ ] `GET /app.css`, `/PIM.Intranet.styles.css`, `/bootstrap/bootstrap.min.css`,
      `/favicon.svg` vrnejo 200 s pravim `Content-Type`; isto pod `/PIM/…`.
- [ ] Izrisani `<head>` vsebuje `<base href="…/">` oziroma `<base href="…/PIM/">`
      glede na način dostopa.
- [ ] Napačno geslo → vrnitev na `/prijava?napaka=1` s slovenskim sporočilom, brez
      podrobnosti o tem, kaj je bilo narobe.
- [ ] Pravilna prijava → preusmeritev na `/nadzorna-plosca`.
- [ ] `zapomniMe` označen → piškotek je trajen (potek ≈ 14 dni); neoznačen → sejni.
- [ ] Levi meni vsebuje samo postavke, dovoljene za vloge prijavljenega uporabnika;
      preveri z uporabnikom vloge `VIEWER` in `ADMIN`.
- [ ] V glavi je vidno ime aktivne organizacije iz `dbo.OrganizationConfig` in
      prikazno ime uporabnika; kanal/jezik/obvestila so onemogočeni.
- [ ] Gumb menija je viden in preklaplja navigacijo tudi pri ozkem oknu.
- [ ] `/nadzorna-plosca`: pet KPI kartic v eni vrsti na namizju, paneli za kakovost,
      procese, opozorila, integracije in hitre dostope; nobene izmišljene vsebine.
- [ ] `/izdelki`: iskanje in status filtrirata **strežniško**; »Prejšnja/Naslednja«
      se pravilno onemogočita na robovih; števec strani ustreza `TotalCount`.
- [ ] `/izdelki/{id}`: glava, profili in odprte težave se ujemajo z bazo; neobstoječ
      ID ne vrže napake strežnika.
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

Nato še `npm test` v korenu repozitorija. `npm run lint` uspe, vendar ničesar ne
preveri.

---

## 8. Znane omejitve

- Vizualnega E2E pregleda prijavljenih strani ni mogoče avtomatizirati brez
  veljavne uporabniške seje; agenti gesel ne uporabljajo. Ta pregled ostaja ročen.
- `/_framework/blazor.web.js` za neprijavljeno zahtevo vrne 302 na prijavo
  (posledica `FallbackPolicy`); prijava je navaden POST in JS ne potrebuje.
- Ni modela uporabnik → organizacija in uporabnik → kanal; shell zato prikaže prvo
  aktivno organizacijo.
- Zgodovinskega read modela ni, zato na nadzorni plošči ni časovnih trendov.
