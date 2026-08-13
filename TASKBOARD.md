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

_(prazno)_

## DELAM (v teku)

_(prazno)_

## KONČANO

- **[TESTI]** Pravi testni zaganjalnik `scripts\run_tests.ps1` in popravek UX
  pogodbe kartice izdelka — kdo: Claude Opus 5 — 2026-08-12 — dokaz:
  `scripts\run_tests.ps1` → **42 uspeli, 0 preskočenih, 0 padlih**, izhod 0.
  Razlog: `dotnet test PIM_Solution\PIM.sln` je izvajal **1 projekt od 43** in
  vračal 0, ker so ostali konzolne aplikacije, ki jih samo prevede. Prvi polni
  zagon je razkril 7 padlih projektov; šest jih je padlo zaradi nedosegljive
  baze (zaganjalnik zdaj poda `PIM_CONNECTION_STRING`, ker testi
  `appsettings.Local.json` iz svoje mape ne najdejo), sedmi je bila prava
  napaka v `PIM.F10.ProductDetailUxTests`.

- **[BAZA/WORKERJI]** Odpravljen FK 547 v F3/F5 cleanupu in zaprt regresijski
  paket — kdo: Hermes — 2026-08-12 — vzrok: triggerji sledljivosti so po prvem
  cleanupu ustvarili novo `pim.ProductFieldHistory` za testni produkt; cleanup
  drugič ozko odstrani zgodovino in prazne pripadajoče batche. Dokaz:
  `dotnet run --project PIM_Solution/tests/PIM.F3.Integration --no-restore` = 0;
  `dotnet run --project PIM_Solution/tests/PIM.F5.Integration --no-restore` = 0;
  `dotnet build PIM_Solution/PIM.sln --no-restore` = 0 (0 warnings, 0 errors).
  Opomba: prvotni zapis se je skliceval tudi na `dotnet test PIM.sln` = 0
  dvakrat zapored. To drži, a ni dokaz — ta ukaz izvaja 1 projekt od 43.
  Veljaven dokaz je naknadni polni zagon `scripts\run_tests.ps1`.

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
