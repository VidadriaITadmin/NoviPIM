# TASKBOARD — skupni spomin agentov

Edini vir resnice o tem, kdo kaj dela in kaj je narejeno.
Pravila so v [`AGENTS.md`](AGENTS.md); ta tabla jih ne podvaja.

## Kako se uporablja

- **Pred delom:** preberi to tablo in `STATUS.md`, poženi `git status --short`.
- **Med delom:** premakni nalogo v DELAM, vpiši ime in ozemlje.
- **Po delu:** premakni v KONČANO z **dokazom** — kateri ukaz, kakšen izhod.
- Eno ozemlje = en commit. Ozemlja: BAZA / INTRANET / WORKERJI / DOMENA.

---

## TODO (čaka)

- **[BAZA]** Odpraviti ponovljiv SQL timeout v F3 in F5 integracijskem ciklu, ko
  teče celoten paket. Samostojni zagon obeh uspe, v celotnem paketu pade.
  DoD: `dotnet test PIM_Solution\PIM.sln --no-restore` vrne 0 dvakrat zapored;
  vzrok je zapisan v `docs\TEST_REPORT_E2E.md`; timeout ni skrit z večanjem
  časovne omejitve brez pojasnila vzroka.
- **[BAZA/INTRANET]** S5/S6: varna razveljavitev polja in paketa prek namenske
  poslovne shranjevalne poti, s preverjanjem konflikta in lastništva SAOP.
  Neposredni SQL update ostane namenoma blokiran.

## DELAM (v teku)

<!-- - [OZEMLJE] opis — kdo: <agent> — začeto: <datum> -->

_(prazno)_

## KONČANO

- **[INFRASTRUKTURA]** Reorganizacija map in poenotenje pravil — kdo: Claude Opus 5 —
  2026-08-12 — dokaz: `AGENTS.md` je edini pravilnik; nasprotujoči si dokumenti
  premaknjeni v `..\_arhiv\`; Node scaffold umaknjen, ker je `npm test` dajal
  lažno zeleno; 52 necommitanih datotek zavarovanih v 5 commitih in v
  `..\Backups\pred-reorg_20260812_191646\`.
- **[BAZA/INTRANET]** S1–S4 sledljivost izdelkov: register lastništva, batch/field
  zgodovina, množična triggerja, XML `SESSION_CONTEXT`, zavihek Zgodovina —
  kdo: Hermes — 2026-08-12 — migracije 028–031 uporabljene na `PIM`,
  rollback-only dokaz PASS.
- **[DOKUMENTACIJA]** Ločena dokumentacija baze, workerjev, intraneta, izvozov,
  laptop namestitve in E2E protokola — kdo: Hermes — 2026-08-12 — brez skrivnosti.
- **[WORKERJI/IZVOZI]** Fixture/replay dokaz F6/F7/F8/F9 — kdo: Hermes — 2026-08-12
  — F6 NW=2697, BT=1361; F8 samo loopback fixture.
- **[INTRANET]** Uskladitev nadzorne plošče z odobrenim UX in strežba CSS pod `/`
  in `/PIM` — kdo: intranet_dashboard — 2026-08-04 — build 0/0, F10 PASS, CSS 200.
