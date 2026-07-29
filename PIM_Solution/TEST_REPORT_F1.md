# TEST_REPORT — F1

Datum: 2026-07-29
Stanje: PASS — F1 Definition of Done je izpolnjen.

## Izvedeno

- Dodana je migracija `005_CreateOutputContract.sql`.
- Dodana sta izvozna profila `ERP_L1` in `WEB_B2C_PRODUCTS` za PRODUCTS kontrakt.
- Dodanih je 9 aktivnih obveznih ERP L1 stolpcev in 7 aktivnih obveznih B2C stolpcev.
- Izvozna profila sta enolično vezana na validacijska profila `ERP_L1` in `WEB_B2C`.
- Procedura `val.SyncFieldRequirementsFromExportProfiles` generira in usklajuje `val.FieldRequirement` iz `out.ExportColumn`; seznam zahtevanih polj ni zabetoniran v proceduri.
- Dodan je F1 SQL-test `tests/sql/Verify-F1.sql` in razširjeno preverjanje migratorja.

## Preveritve in rezultati

| Preveritev | Rezultat |
|---|---|
| Prvi zagon migracije 005 | PASS — migracija uporabljena |
| Drugi zagon migracij | PASS — 001–005 preskočene kot že uporabljene |
| `--verify` proti MSSQL | PASS — F0 in F1 objekti, sled migracij in generirani zahtevki so skladni |
| `--show-output-contract` | PASS — `ERP_L1: 9/9`, `WEB_B2C: 7/7` (aktivni izvozni stolpci / generirani zahtevki) |
| `dotnet build PIM.sln --configuration Release` | PASS — 0 opozoril, 0 napak |
| F0–F1 migracijski kontraktni test | PASS |
| `npm test` in `npm run lint` | PASS |

## Zaključek

Definicija »poln« za ERP L1 in B2C je podatkovno zapisana v izvoznih profilih. Validacijski zahtevki so izpeljani iz teh profilov in so pri ponovnem zagonu idempotentni.

`PIM_test` ni bil spremenjen. F2 ni bila začeta.
