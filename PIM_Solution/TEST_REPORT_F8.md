# TEST_REPORT_F8 — SAOP outbox in echo

Datum: 2026-07-31

## Rezultat

F8 je izveden in preverjen z lokalnim HTTP fixture strežnikom ter izoliranimi
vrsticami organizacije `9808` v razvojni bazi `PIM`. Test je v `finally`
odstranil sporočila, poskuse, policy, profil in organizacijo. Migracija 021 in
forward popravek 022 sta bila uporabljena, ponovni zagon ju je idempotentno
preskočil. SHA-256 datotek sta `021_CreateOutboundOutbox.sql`
`2c1b44f818f927dca97d86a8e5ef7a265c5486cd2061b00a6a24f7f7465616bf` in
`022_StabilizeOutboundScheduling.sql`
`5ab33e212bd1f787bb744177c715e747e950bd24f2178f2a5e99a675a4985591`.

Dokazani so aktivni dedup, atomski claim/lease, `Retry`, `Dead`, `Sent`,
`Verified`, `Drift`, redakcija odziva, prepovedana polja, ročni gate in
anti-loop. HTTP testi so izvedli samo `PATCH` proti `127.0.0.1`; dispatcher
dovoljuje samo `POST` in `PATCH`. Status 2xx pomeni `Sent`, nikoli neposredno
`Verified`.

## Ukazi in izidi

- `dotnet run --project src/PIM.Migrator/PIM.Migrator.csproj` — PASS; 021
  uporabljena, drugi zagon jo je preskočil.
- `dotnet run --project src/PIM.Migrator/PIM.Migrator.csproj -- --verify` —
  PASS; ledger hash in F0–F8 objekti, vključno z outbox in intranetnim pogledom.
- vsi `tests/PIM.F3.*` do `tests/PIM.F8.*` z `dotnet run --no-build` — PASS.
- `dotnet run --project tests/PIM.F8.Integration/PIM.F8.Integration.csproj` —
  PASS; izolirana org. 9808, lokalni fixture, čiščenje PASS.
- `dotnet build PIM.sln --no-restore` — PASS, 0 opozoril, 0 napak.
- `npm test --prefix ..` — PASS, 1 datoteka in 1 test.
- `npm run lint --prefix ..` — PASS; obstoječi skript je placeholder
  `(lint se doda kasneje)` in ne izvaja dejanskega linterja.
- `git diff --check` — PASS.

Regresijski F6 test je izvedel svojo obstoječo read-only capability poizvedbo
do `PIM_test`; ni izvedel zapisovanja. Obstoječa nesledena mapa `PIM_test` ter
vse druge uporabniško navedene nesledene poti niso bile spremenjene, staged ali
commitirane.

## Blokada živega SAOP

Živi SAOP write ni bil izveden in ni označen kot uspešen. Ostaja `BLOCKED`, ker
niso podani potrjena neprodukcijska endpoint/payload pogodba, varen testni
izdelek, poverilnice in izrecno dovoljenje za zunanjo spremembo. Privzeti profil
je onemogočen in uporablja `ManualApproval`.
