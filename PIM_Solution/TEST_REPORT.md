# TEST_REPORT — F0

Datum: 2026-07-29
Stanje: PASS — F0 Definition of Done je izpolnjen.

## Izvedeno

- Ustvarjena je .NET 8 rešitev s strukturami `src/`, `workers/`, `sql/migrations/`, `sql/registry-seed/`, `deploy/`, `tests/`, `_SPEC/` in `docs/`.
- Dodan je migrator z oštevilčenimi migracijami, SHA-256 sledjo v `dbo.SchemaMigration`, transakcijsko aplikacijsko ključavnico ter podprtim varnim ustvarjanjem ciljne baze; način `--verify` preveri tudi popolnost in vsebinski hash migracijske sledi.
- Dodane so sheme `raw`, `map`, `canon`, `val`, `pim`, `out`, `ops`, `dbo` in `sec`.
- Dodani so F0 objekti nadzorne sobe `ops.PipelineRun`, `ops.PipelineStepLog`, `ops.DeadLetterQueue`, `ops.ErrorLog` in `ops.Heartbeat`.
- Dodan je `dbo.OrganizationConfig` s štirimi začetnimi organizacijami: DEMO, IQLighting, Vidadria in Ediito.
- Dodani so centralni pomožni proceduri `ops.LogError` in `ops.EnqueueDeadLetter` ter vzorčna transakcijska procedura `ops.RecordPipelineStep`.
- Dodane so konfiguracije Development/Production brez skrivnosti, lokalni primer konfiguracije in zagonski PowerShell skript.

## Preveritve in rezultati

| Preveritev | Rezultat |
|---|---|
| `dotnet build PIM.sln --configuration Release` | PASS — 0 opozoril, 0 napak |
| `dotnet run --project tests/PIM.F0.Tests/PIM.F0.Tests.csproj --configuration Release` | PASS — kontrakt štirih F0 migracij in zahtevanih objektov |
| Migrator brez `PIM_CONNECTION_STRING` | PASS — varno zavrne z jasnim sporočilom, brez zapisa skrivnosti v repo |
| Blazor razvojni zagon in HTTP zahteva `/` | PASS — aplikacija posluša na localhost in vrne začetno stran |
| `npm test` | PASS — 1 test |
| `npm run lint` | PASS — trenutni lint skript iz nadrejenega repozitorija je informativen |
| `git diff --check` | PASS |
| Pregled slednih connection stringov/gesel v `PIM_Solution` | PASS — ni najdenih |
| Ustvarjanje baze `PIM` in prvi zagon migracij proti dosegljivemu razvojnemu MSSQL | PASS — uporabljene migracije 001–004 |
| Drugi zagon migracij | PASS — vse štiri migracije so bile preskočene kot že uporabljene |
| `--verify` proti MSSQL | PASS — sheme, F0 objekti, štiri organizacije in SHA-256 sled migracij so skladni |
| `TOP (3)` iz `dbo.SchemaMigration` | PASS — izpisan z migratorjem; podatki so spodaj |

## Dokaz iz `dbo.SchemaMigration`

| MigrationId | AppliedUtc (UTC) |
|---|---|
| `004_CreateProcedureSkeleton.sql` | `2026-07-29T10:21:08.1290000` |
| `003_CreateOperationalProcedures.sql` | `2026-07-29T10:21:08.1210000` |
| `002_CreateOperationsAndOrganization.sql` | `2026-07-29T10:21:08.1160000` |

## Zaključek

`PIM_test` ni bil spremenjen. F1 ni bila začeta. Sistem čaka na izrecni ukaz `nadaljuj`.
