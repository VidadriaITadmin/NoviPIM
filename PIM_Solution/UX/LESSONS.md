# UX lekcije

## Potrjena pravila

- Potrjene slike iz `../PIM_test/UX_pictures` so edini vizualni standard.
- Različnega fonta, generiranega sloga ali alternativne kompozicije ne uvajamo brez potrditve.
- Vizualni primeri niso podatkovni fixtureji: prikazani podatki v aplikaciji morajo izhajati iz PIM baze.
- Implementator in pregledovalec sta ločena: Codex spremeni kodo, Claude neodvisno pregleda razliko in primerja s potrjeno referenco.

## Odprta vprašanja za implementacijo

- Pred izdelavo medijev, partnerjev, cenikov in nastavitev kataloga je treba najprej najti obstoječe read modele oziroma dodati podatkovno podprte poizvedbe.
- Globalna izbira organizacije, kanala, jezika in prijavljenega uporabnika ne sme ostati statična.

## Preverjeno 2026-08-04

- `dbo.OrganizationConfig` zagotavlja aktivno organizacijo, trenutna avtentikacija pa ne vsebuje uporabnik–organizacija ali kanal preslikave. Shell zato varno prikaže prvo aktivno organizacijo in ime iz avtentikacijskega zahtevka, ne ponuja pa lažnih izbirnikov.
- Obstoječi produktni read model vrača samo ItemID, EAN ter statuse/popolnost validacijskih profilov. Urejevalnega obrazca in gumba Shrani ni mogoče pošteno implementirati brez realne bralne in zapisovalne poti.
- `GetProducts` omeji rezultat na prvih 100 vrstic, zato so trenutni filtri odjemalski nad vrnjenim naborom; prava paginacija zahteva razširitev procedure z rezultatom skupnega števila.
- `npm run lint` trenutno ni pravi lint: obstoječi paketni skript samo izpiše `(lint se doda kasneje)`.
- Spremenjene datoteke tega sklopa: `src/PIM.Intranet/Components/App.razor`, `src/PIM.Intranet/Components/Layout/MainLayout.razor`, `src/PIM.Intranet/Components/Layout/MainLayout.razor.css`, `src/PIM.Intranet/Components/Layout/NavMenu.razor`, `src/PIM.Intranet/Components/Pages/Dashboard.razor`, `src/PIM.Intranet/Components/Pages/Products.razor`, `src/PIM.Intranet/Components/Pages/ProductDetail.razor`, `src/PIM.Intranet/Components/Pages/Stocks.razor`, `src/PIM.Intranet/Components/Pages/ValidationErrors.razor`, `src/PIM.Intranet/Components/Pages/RawQuarantine.razor`, `src/PIM.Intranet/Services/IntranetDataService.cs`, `src/PIM.Intranet/wwwroot/app.css`, `src/PIM.Intranet/wwwroot/favicon.svg`, `tests/PIM.F10.AuthTests/Program.cs`, `UX/PROGRESS.md`, `UX/LESSONS.md`.
- Izvedeni ukazi: `dotnet build PIM.sln --no-restore` (uspeh, 0 opozoril, 0 napak), `dotnet run --project tests/PIM.F10.AuthTests/PIM.F10.AuthTests.csproj --no-build` (PASS), `dotnet run --project tests/PIM.F9.IntranetTests/PIM.F9.IntranetTests.csproj --no-build` (PASS), `npm test` (1 test PASS), `npm run lint` (skript uspe, dejanskega linterja ni).

## Pogodbene ugotovitve blokirajočega pregleda 2026-08-04

- `val.ProductIssue` v migraciji 006 nima resnosti. `IssueCode`, `Message` in čas zaznave so resnični podatki, oznaka »Napaka« kot poslovna resnost pa ni bila utemeljena in je odstranjena. Nova resnost se sme dodati šele, ko validacijska pravila dobijo dogovorjen, resničen vir zanjo.
- Procedure iz migracije 010 imajo imenovane stolpce, zato morajo C# preslikave uporabljati `GetOrdinal` oziroma ime stolpca. Ordinalne preslikave so preveč krhke pri razširitvah result seta.
- `canon.Product.Completeness` in `val.ProductValidationState.Completeness` sta preverjeni vrednosti 0–100; prikaz odstotka je zato dovoljen. Odstotka se ne računa ali prikazuje tam, kjer pogodba ne zagotavlja imenovalca.
- Prava paginacija potrebuje filtriranje in `COUNT_BIG` v isti pogodbi procedure; število vrnjenih vrstic ni skupno število.
- SQL seznam vlog je varen, če so dinamična samo imena lokalno ustvarjenih parametrov, vrednosti vlog pa ostanejo `SqlParameter`; fiksne tri vloge niso del podatkovne pogodbe.
- Polna referenca Kakovost je izvedljiva iz obstoječih validacijskih stanj in težav. Trendi skozi čas niso pošteni brez zgodovinskega read modela, ker trenutno stanje težav ni časovna serija.

Nove lekcije se dodajo šele po preverjenem rezultatu.

## Preverjeno v zaključnem operativnem sklopu 2026-08-04

- Zapisovalne B2B in administratorske strani morajo uporabljati `GetCurrentOrganizationAsync`; hardkodirani ID `2` ni varen kontekst.
- Read modeli strank, tekov in outbound nimajo `TotalCount` in strežniških filtrov, zato odjemalska paginacija predstavlja samo vrnjeni nabor.
- Neznan procesni status ostane prikazan z izvorno vrednostjo; UI prevaja samo znane statuse.
- Številske začetne vrednosti za vrednostni prag niso poslovna konfiguracija in so odstranjene.
- Mediji, partnerji, produktni ceniki in nastavitve kataloga potrebujejo dogovorjene poti ter read/write modele; referenčne slike niso podatkovna pogodba.

## Zaključni korekcijski pregled 2026-08-04

- Statični opis stopenj popustov ni nadomestilo za podatkovni read model; DiscountRules prikazuje samo vrstice, ki jih vrne `GetValueTiersAsync`.
- Zapisovalna stran je skladna z intranetnim dizajnom šele, ko kartice, tabele, obrazci, dejanja in sporočila uporabljajo skupne PIM razrede; sama zamenjava naslova ne odstrani odvisnosti od Bootstrap vizualnega jezika.
- Pogodbeni test preverja tri popravljene strani za zahtevane PIM razrede, prepoved Bootstrap razredov in odsotnost statičnega stavka S1–S4, ne da bi posegal v njihove podatkovne operacije ali vezave.

## Preverjeno po uporabi migracije 027

- `027_HardenIntranetQualityReadModels.sql` je uporabljena v dovoljeni bazi PIM in preverjanje migratorja F0–F10 uspe. Zato nove strežniške pogodbe za izdelke, podrobnost izdelka in kakovost niso samo sprememba izvorne kode.
- Vizualnega E2E testa v prijavljenem IIS okolju ni mogoče avtomatizirati brez uporabniške prijave; agent ne uporablja ali ne zahteva gesel. Tak pregled ostaja ločen dokaz pred produkcijsko objavo.
