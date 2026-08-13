# NoviPIM — živ status dela

Posodobljeno: 2026-08-13

## BAZA naloga — karantena NW XML po izdelku

- **Stanje: BLOKIRANO.** Claude je z zahtevanima `--permission-mode acceptEdits` in `--max-turns 40` pripravil `PIM_Solution/sql/migrations/040_QuarantineGenericXmlPerRecord.sql`; XML ne vstavi `canon.Product`, lookup vsebuje `OrganizationId`, zapis se obdeluje po `RecordOrdinal`, neujemanja pa so po trenutnem nalogu tiho preskočena in `raw.Inbox` konča `Processed`. Codexov neodvisni statični pregled je vrnil `VERDICT: PASS`.
- **Blokada dokazov:** `scripts/run_tests.ps1` → izhod 1, 41 uspešnih / 0 preskočenih / 1 padel. `PIM.F5.Integration` na `PIM_Solution/tests/PIM.F5.Integration/Program.cs:192` še zahteva `Quarantined` za neujemajoči zapis, trenutni nalog pa zahteva `Processed` in tiho preskakovanje. Testa ne spreminjamo, da bi šel skozi. Znotraj Hermesove seje tudi ni varno dostopne povezave za ponovitev NW XML E2E meritev.
- **Uporabnik:** potrebna je odločitev, ali trenutna specifikacija velja in se v ločenem/izrecno odobrenem koraku posodobi F5 integracijski test, ali se specifikacija vrne na karantensko semantiko.

## Aktivno preverjanje E2E

- **Stanje: KONČANO.** Hermes je sam izvedel korake 1–5 iz
  `.hermes/naloge/2026-08-13-e2e-koraki-1-5.md`; nalog ni spreminjal kode,
  SQL-a ali testov.
- **Dokaz:** build 0 opozoril/0 napak; migrator `--verify` 0 in dva
  idempotentna zagona brez nove migracije; `scripts\run_tests.ps1` →
  `REZULTAT: VSE OK`, 42/0/0; F3/F5/F6/F7/F8 fixture dokazi in Kestrel health
  na 5088 so uspešni. Podrobnosti: `docs/TEST_REPORT_E2E.md`.
- **QA:** Codex je po pregledu dejanskega diffa in izvornih testov vrnil
  `VERDICT: PASS`.
- **Uporabnik:** ničesar ni treba storiti.

## Trenutno dokazano

- Lokalna intranet konfiguracija je poenotena: edina veljavna datoteka je korenska appsettings.Local.json; PIM.Intranet da prednost PIM_CONNECTION_STRING, nato uporabi ConnectionStrings:Pim iz korenske datoteke. Podrejeni lokalni datoteki sta preimenovani v .zastarelo in ignorirani. Dokaz: /health 200 ter prijavni SQL POST 302 brez SqlException 26, oba brez nastavljene okoljske povezave; polni paket 42/0/0 in Codex VERDICT: PASS.

- Lokalni intranet je dosegljiv na `http://127.0.0.1:5199/prijava`; `/health`, prijava, CSS in pot pod `/PIM` so vrnili HTTP 200.
- `PIM.Migrator --verify` proti razvojni bazi `PIM` je uspešen za F0–F10.
- Celoten build `PIM.sln` je uspešen z 0 opozorili in 0 napakami.
- F6 fixture/stock, F7 B2B, F8 lokalni outbox fixture, F9 nadzor in vsi F10 auth/UX testi so uspešni.
- Dokumentacija je pripravljena: `docs/DATABASE.md`, `docs/WORKERS.md`, `docs/INTRANET.md`, `docs/EXPORTS.md`, `docs/LAPTOP_INSTALL.md`, `docs/END_TO_END_TEST.md` in `docs/TEST_REPORT_E2E.md`.
- Zahteve S1–S7 za sledljivost so implementirane na dejanskem kanoničnem sloju: `canon.Product`, `canon.ProductCommercial`, `canon.ProductText`, `canon.ProductAttribute` in `canon.ProductMedia`. Register lastništva ima 20 sledljivih polj, zgodovina združuje batch/field spremembe, triggerji so množični in uporabljajo `SESSION_CONTEXT`, kartica izdelka pa ima zavihek »Zgodovina«. Migracije `028`–`038` so uporabljene na `PIM`.
- S5/S6 imata omejeno poslovno pot `pim.UndoProductField` in `pim.UndoProductBatch`: dovoljena sta samo za trenutno eksplicitno podprti PIM-lastni polji `WebPublish` in `IsActive`; preverita konflikt, blokirata ponovljeni undo, zavrneta prazen batch ter SAOP/SHARED polja in ob napaki počistita `SESSION_CONTEXT`. Pravi xUnit `PIM.ChangeTracking.Integration` je dokazno izvedel 6/6 primerov.
- `PIM.Watchdog` je povezan z `ops.IntegrationHealth` za lokalni profil `WATCHDOG`; dokazani status je `Healthy`. `PIM.AlertDispatcher` obdrži privzeto izključeno dostavo in pri izrecnem enable zapiše ops run.

## Zaprt regresijski paket

- F3/F5 cleanup je imel FK 547, ne SQL timeout: triggerji sledljivosti so po prvem čiščenju ustvarili novo zgodovino testnega izdelka. Cleanup zdaj drugič ozko odstrani le to zgodovino in njene prazne batche. Podrobnosti in dokaz: `docs/TEST_REPORT_E2E.md`.
- **Testni paket je prvič dokazano zelen v celoti:** `scripts\run_tests.ps1` → **42 uspeli, 0 preskočenih, 0 padlih**, izhod 0. Nič ni preskočeno, kar pomeni, da so se integracijski testi dejansko izvedli proti razvojni bazi `PIM`.
- Prejšnje trditve o zelenem paketu so bile zavajajoče: `dotnet test PIM_Solution\PIM.sln` izvaja **1 projekt od 43** (ostali so konzolne aplikacije, ki jih samo prevede) in je vračal 0, tudi če ni izvedel skoraj ničesar. Od zdaj je edini merodajni ukaz `scripts\run_tests.ps1`.
- UX pogodba kartice izdelka je bila vezana na fiksne številke (3 zavihki, 2 tabeli, 8 stolpcev) in je po dodanem zavihku »Zgodovina« padala. Trditve so zdaj vezane na razmerja; zavihek je bil pred tem preverjen, da ima resničen podatkovni vir.

## Meje, ki ostanejo namerne

Razveljavitev ni generični SQL API: za nova polja je treba najprej dodati njihovo preverjeno poslovno pot in test. Živ SAOP, zunanja dostava, IIS in Scheduled Tasks ostanejo izključeni; outbox ni samodejno aktiviran z undo postopkom brez izrecno omogočenega profila/odobritve. Na laptopu slediti `docs/LAPTOP_INSTALL.md` in `docs/END_TO_END_TEST.md`.