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

## Ponovljiv odprt problem

Celotni zaporedni paket 42 testnih projektov se zaključi z `40 PASS / 2 FAIL`:

- `PIM.F3.Integration`: občasni SQL command timeout pri end-to-end izvoznem ukazu; samostojni ponovni zagon je uspešen (`CSV vrstic=17`).
- `PIM.F5.Integration`: občasni SQL timeout pri `val.RunValidation`; samostojni ponovni zagon je lahko uspešen, vendar se timeout ponovi tudi ob kasnejšem zagonu.

Po timeoutu ni bilo aktivne SQL blokade ali odprte transakcije v `PIM`, vendar so testi lahko pustili `F5_INTEGRATION` teke v stanju `Running`. To je stabilnostna napaka testnega cleanup/validation cikla in je treba jo odpraviti pred trditvijo, da celotni regresijski paket vedno prehaja. Nisem ročno brisal sledljivih testnih vrstic, ker so zaščitene s tujimi ključi in bi to prikrilo problem.

## Zunanje meje

Niso bile izvedene in ostajajo SKIP:
- živi SAOP GET ali write-back;
- Magento/FTP/HTTP dostava izvozov;
- resni webhook/e-mail alerti;
- IIS deploy in Scheduled Tasks (sistemske spremembe niso bile izvedene).

Za natančen prenos na laptop uporabi `docs/LAPTOP_INSTALL.md`; za korak-po-korak E2E izvedbo uporabi `docs/END_TO_END_TEST.md`.
