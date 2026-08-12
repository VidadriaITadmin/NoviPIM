# NoviPIM — živ status dela

Posodobljeno: 2026-08-12

## Trenutno dokazano

- Lokalni intranet je dosegljiv na `http://127.0.0.1:5199/prijava`; `/health`, prijava, CSS in pot pod `/PIM` so vrnili HTTP 200.
- `PIM.Migrator --verify` proti razvojni bazi `PIM` je uspešen za F0–F10.
- Celoten build `PIM.sln` je uspešen z 0 opozorili in 0 napakami.
- F6 fixture/stock, F7 B2B, F8 lokalni outbox fixture, F9 nadzor in vsi F10 auth/UX testi so uspešni.
- Dokumentacija je pripravljena: `docs/DATABASE.md`, `docs/WORKERS.md`, `docs/INTRANET.md`, `docs/EXPORTS.md`, `docs/LAPTOP_INSTALL.md`, `docs/END_TO_END_TEST.md` in `docs/TEST_REPORT_E2E.md`.
- Zahteve S1–S7 za sledljivost so implementirane na dejanskem kanoničnem sloju: `canon.Product`, `canon.ProductCommercial`, `canon.ProductText`, `canon.ProductAttribute` in `canon.ProductMedia`. Register lastništva ima 20 sledljivih polj, zgodovina združuje batch/field spremembe, triggerji so množični in uporabljajo `SESSION_CONTEXT`, kartica izdelka pa ima zavihek »Zgodovina«. Migracije `028`–`038` so uporabljene na `PIM`.
- S5/S6 imata omejeno poslovno pot `pim.UndoProductField` in `pim.UndoProductBatch`: dovoljena sta samo za trenutno eksplicitno podprti PIM-lastni polji `WebPublish` in `IsActive`; preverita konflikt, blokirata ponovljeni undo, zavrneta prazen batch ter SAOP/SHARED polja in ob napaki počistita `SESSION_CONTEXT`. Pravi xUnit `PIM.ChangeTracking.Integration` je dokazno izvedel 6/6 primerov.
- `PIM.Watchdog` je povezan z `ops.IntegrationHealth` za lokalni profil `WATCHDOG`; dokazani status je `Healthy`. `PIM.AlertDispatcher` obdrži privzeto izključeno dostavo in pri izrecnem enable zapiše ops run.

## Odprto pred polnim regresijskim PASS

Celotni paket 42 projektov ima trenutno 40 PASS / 2 FAIL zaradi občasnega SQL timeouta v F3 in F5 integracijskem ciklu. Samostojni F3 in F5 dokazni zagon sta uspela, vendar timeout ni dovoljeno prikriti. Podrobnosti in dokaz: `docs/TEST_REPORT_E2E.md`.

## Meje, ki ostanejo namerne

Razveljavitev ni generični SQL API: za nova polja je treba najprej dodati njihovo preverjeno poslovno pot in test. Živ SAOP, zunanja dostava, IIS in Scheduled Tasks ostanejo izključeni; outbox ni samodejno aktiviran z undo postopkom brez izrecno omogočenega profila/odobritve. Na laptopu slediti `docs/LAPTOP_INSTALL.md` in `docs/END_TO_END_TEST.md`.