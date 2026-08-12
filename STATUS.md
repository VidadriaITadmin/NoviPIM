# NoviPIM — živ status dela

Posodobljeno: 2026-08-12

## Trenutno dokazano

- Lokalni intranet je dosegljiv na `http://127.0.0.1:5199/prijava`; `/health`, prijava, CSS in pot pod `/PIM` so vrnili HTTP 200.
- `PIM.Migrator --verify` proti razvojni bazi `PIM` je uspešen za F0–F10.
- Celoten build `PIM.sln` je uspešen z 0 opozorili in 0 napakami.
- F6 fixture/stock, F7 B2B, F8 lokalni outbox fixture, F9 nadzor in vsi F10 auth/UX testi so uspešni.
- Dokumentacija je pripravljena: `docs/DATABASE.md`, `docs/WORKERS.md`, `docs/INTRANET.md`, `docs/EXPORTS.md`, `docs/LAPTOP_INSTALL.md`, `docs/END_TO_END_TEST.md` in `docs/TEST_REPORT_E2E.md`.
- Zahteve za sledljivost sprememb so implementirane na `canon.Product` in `canon.ProductCommercial`: 17 registriranih polj, batch/field zgodovina, množična triggerja, varni `SESSION_CONTEXT` in zavihek »Zgodovina« na kartici izdelka. Migracije `028`–`031` so uporabljene na `PIM`; rollback-only SQL dokaz je potrdil zapis polja, vira, izvajalca in opombe brez trajne spremembe podatkov.

## Odprto pred polnim regresijskim PASS

Celotni paket 42 projektov ima trenutno 40 PASS / 2 FAIL zaradi občasnega SQL timeouta v F3 in F5 integracijskem ciklu. Samostojni F3 in F5 dokazni zagon sta uspela, vendar timeout ni dovoljeno prikriti. Podrobnosti in dokaz: `docs/TEST_REPORT_E2E.md`.

## Naslednji varen korak

Naslednja implementacijska faza sledljivosti je varni Ctrl+Z prek namenske poslovne shranjevalne poti; neposredni SQL update je namenoma blokiran. Na laptopu izvesti `docs/LAPTOP_INSTALL.md`, nato slediti `docs/END_TO_END_TEST.md`. Živ SAOP, zunanja dostava, IIS in Scheduled Tasks ostanejo izključeni, dokler niso lokalni/laptop dokazi zaključeni in pregledani.