# E2E dokazno poročilo — lokalni PIM

Datum: 2026-08-12
Okolje: lokalni Windows, SQL Server `DESKTOP-2CGGQIC\MSSQLSERVER3`, razvojna baza `PIM`, Windows Integrated Authentication, `Encrypt=True`, `TrustServerCertificate=True`.

## Izvedeni in uspešni dokazi

| Področje | Dokaz | Rezultat |
|---|---|---|
| Build | `dotnet build PIM.sln --no-restore --nologo -v minimal` | PASS, 0 warnings, 0 errors |
| Migracije | `PIM.Migrator --verify` proti `PIM` | PASS: `Preverjanje F0–F10 baze je uspešno.` |
| F0 | migracijski izhodiščni kontrakt | PASS |
| F2 | integracija | PASS |
| F3 | samostojni fixture tok | PASS: CSV vrstic=17, XML deklaracija/ERP upravičenost/requeue karantene preverjeni |
| F5 | samostojni fixture tok | PASS v uspešnem samostojnem zagonu: EAN kategorija/medij/atribut, B2C validacija, promocija, CSV |
| F6 | file worker/stock integracija | PASS: NW=2697/0, BT=1361/0, intranet read model vrne vrstico |
| F7 | B2B integration/mapping/behavior/contract | PASS |
| F8 | contract/behavior/dispatcher/echo/hardening/integration/intranet | PASS; lokalni HTTP fixture, brez zunanjega klica |
| F9 | alert/behavior/contract/deploy/integration/intranet | PASS |
| F10 | auth + Dashboard, Products, ProductDetail, Customers, Stocks, Quality, PipelineRuns, Outbound, SystemIntegrations UX pogodbe | PASS |
| Intranet | Kestrel `http://127.0.0.1:5199` | PASS: `/health`, `/prijava`, `/PIM/prijava`, CSS vsi HTTP 200 |

## Popravki med dokaznim ciklom

1. `StockCsvGenerator` zdaj izrecno uporablja UTF-8 brez BOM in LF, zato je STOCK CSV determinističen tudi v Windows okolju.
2. F0 kontrakt preverja najmanj osnovnih deset migracij, ne napačno točno deset po razširitvi F0–F10 paketa.
3. F5 staging dokaz preverja dejansko aktivno `map.*` konfiguracijo, ne zastarelega fiksnega števila mappingov.
4. Outbound in Stocks UI ohranjata pogodbeni števili stolpcev ter zahtevane slovenske/dostopne oznake, brez novih read modelov ali lažnih podatkov.
5. `.gitignore` izključi `appsettings.Local.json` v korenu in podmapah.

## Odpravljen problem FK 547 v F3/F5 cleanupu

Prejšnje poročilo je vzrok napačno označilo kot SQL timeout. Ponovitev z dejanskima
izvršljivima integracijama je pokazala `SqlException 547` v cleanupu obeh tokov:
`pim.ProductFieldHistory.ProductId` ima FK na `canon.Product.ProductId`.

Cleanup je najprej pobrisal obstoječo zgodovino, nato pa z `DELETE` nad
`canon.ProductText`, `canon.ProductAttribute` in `canon.ProductMedia` sprožil
triggerje sledljivosti. Ti so za isti ozko določeni testni izdelek ustvarili nove
zgodovinske vrstice. Poznejši `DELETE canon.Product` je zato padel na FK 547.

F3 in F5 zdaj po brisanju sledenih kanoničnih podtabel še enkrat pobrišeta samo
zgodovino izdelka z lastnima pogojema `OrganizationId` + `ItemID` in nato samo
prazne batche, ki pripadajo temu testu. Ni `DROP`, `TRUNCATE` ali neomejenega
brisanja. S tem cleanup ne posega v zgodovino drugih izdelkov niti v batche z
drugo zgodovino.

Dokaz po popravku, 2026-08-12:

- `dotnet run --project PIM_Solution/tests/PIM.F3.Integration --no-restore` → 0;
- `dotnet run --project PIM_Solution/tests/PIM.F5.Integration --no-restore` → 0;
- `dotnet test PIM_Solution/PIM.sln --no-restore` → 0, dvakrat zapored;
- `dotnet build PIM_Solution/PIM.sln --no-restore` → 0 (0 warnings, 0 errors).

## Zunanje meje

Niso bile izvedene in ostajajo SKIP:
- živi SAOP GET ali write-back;
- Magento/FTP/HTTP dostava izvozov;
- resni webhook/e-mail alerti;
- IIS deploy in Scheduled Tasks (sistemske spremembe niso bile izvedene).

Za natančen prenos na laptop uporabi `docs/LAPTOP_INSTALL.md`; za korak-po-korak E2E izvedbo uporabi `docs/END_TO_END_TEST.md`.
