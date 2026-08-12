# TEST_REPORT_F9 — operacije in namestitev

Datum: 2026-07-31

## Rezultat

F9 je implementiran in preverjen na razvojni bazi `PIM`. Migracija
`025_CreateOperationsMonitoring.sql` (SHA-256
`7b298991a7568447943a4537a64f9fed8f1c30b3d194bb6b449d1f4a17f9a8de`) je bila
uporabljena enkrat, ob drugem zagonu preskočena, `--verify` pa je potrdil F0–F9.
Izolirana organizacija `9909` je bila po testu odstranjena.

Izvedeni so schedule/health/alert/delivery/deployment kontrakt, session
`sp_getapplock` wrapper, heartbeat, watchdog z deduplikacijo in recoveryjem,
privzeto izključen dispatcher, lokalni webhook fixture, administratorska
slovenska stran `/system/integracije`, audit potrditve/razrešitve ter Windows/IIS
deploy skripte in operaterska navodila.

## Dokazi

- Strogi RED/GREEN je bil izveden za F9 contract, behavior, alert, intranet,
  deploy in MSSQL integration projekte.
- `dotnet build PIM.sln -c Release` — PASS, 0 opozoril, 0 napak.
- Vsi projekti `tests/PIM.F3*` do `tests/PIM.F9*` — PASS. F9 lokalni webhook je
  klical samo `127.0.0.1`; nobena e-pošta ali resnični webhook ni bila poslana.
- `PIM.F9.Integration` — PASS: en lease za organizacijo/pipeline, zavrnjen
  sočasni zagon, stale/dedup/recovery, stalled watermark ter ločena Dead/Drift
  alarma v bazi `PIM`.
- Migrator prvi/drugi zagon in `--verify` — PASS; drugi zagon je preskočil 025.
- `npm test` — PASS, 1 datoteka/1 test. `npm run lint` — ukaz PASS, vendar
  projektna skripta izrecno pove, da pravi lint še ni dodan.
- `git diff --check` — PASS.
- Deploy contract test — PASS; `pwsh` v Linux okolju ni nameščen, zato dejanski
  PowerShell parser, `-WhatIf`, Windows/IIS publish, atomic swap, rollback in
  health validacija ostajajo varno **BLOCKED** za izvedbo na Windows gostitelju.

Obstoječi F6 integracijski projekt je med zahtevanim polnim F3–F9 zagonom izpisal
svoje read-only preverjanje zmožnosti za `PIM_test` (`SELECT=1, INSERT=1`). F9
koda/testi niso ciljali ali spreminjali `PIM_test`; nobena njegova datoteka ni
bila spremenjena ali stageana. Ta obstoječi pregled je naveden zaradi popolne
sledljivosti.

## Zunanje blokade

Živi SAOP write-back ni bil izveden. Produkcijska dostava opozoril ostaja
privzeto onemogočena. Realna Windows namestitev zahteva uporabnikovo preverjanje
predpogojev, service accountov, skrivnosti/lokalne konfiguracije, IIS bindingov,
health endpointa in rollbacka po kontrolnem seznamu v `deploy/README-Windows.md`.
