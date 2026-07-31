# TEST_REPORT_F8 — SAOP outbox in echo

Datum: 2026-07-31

## Rezultat

F8 je lokalno/MSSQL preverjen in utrjen. Forward-only migraciji
`023_HardenOutboundIntegrityAndLeases.sql` in `024_MatchEchoByExpectedHash.sql`
sta uporabljeni v razvojni bazi `PIM`; ponovni zagon migratorja je njun ledger
in celoten F0–F8 kontrakt preveril. SHA-256 sta:

- `023_HardenOutboundIntegrityAndLeases.sql` —
  `be50aa2bd6d61aac65fd91893576a9ad9c5bed300b2f5590186db4969fbb0c6f`
- `024_MatchEchoByExpectedHash.sql` —
  `1613b7d747a22bc81da6bb9e452e9fa2ce924f8630f249204c3240811619d74c`

`out.EnqueueMessage` je zdaj dejanska strežniška meja: sprejme le dovoljeno
pogodbo spremembe, iz payload-a izpelje `EntityKey` in `FieldSummary`, preveri
aktivno PIM ownership policy ter kanonično shrani payload in strežniško izračuna
`PayloadHash`, `ExpectedEchoHash` in `DedupKey`. Ne morejo jih več podtakniti
klicateljevi parametri. Testi so dokazali zavrnitev `VAT`, dodatnega JSON polja
in nedovoljene `ExactValue` vrednosti.

Lease je vezan na konfigurirani HTTP timeout z 30-sekundno rezervo, ne na
fiksnih 60 sekund. `ClaimMessage` v isti transakciji zapre en potekli `Sending`
poskus kot `Retry` oziroma `Dead`, nato ga lahko varno ponovno prevzame. Veljavni
worker lahko zaključi odgovor, ki prispe po poteku lease-a, dokler ga drug worker
še ni ponovno prevzel; po reclaimu stari worker ne more zaključiti novega poskusa.
Dva sočasna workerja ne dobita istega sporočila. Echo najprej poišče `Sent`
sporočilo z ujemajočim pričakovanim hashem, zato echo novejše spremembe ne označi
starejše spremembe kot `Drift`.

## Dokaz in ukazi

- Strogi RED: `PIM.F8.HardeningTests` je pred 023 padel, ker stari
  `EnqueueMessage` še zahteva klicateljev `@EntityKey`; pred 024 je padel z
  dokazom, da echo novejšega hasha označi starejše sporočilo kot `Drift`.
- `dotnet run --project src/PIM.Migrator/PIM.Migrator.csproj` — PASS; 023 in
  024 uporabljeni, drugi zagon ju je preskočil.
- `dotnet run --project src/PIM.Migrator/PIM.Migrator.csproj -- --verify` —
  PASS; ledger in F0–F8 podatkovni kontrakt.
- F8 contract, behavior, dispatcher, echo in intranet testi — PASS.
- `dotnet run --project tests/PIM.F8.Integration/PIM.F8.Integration.csproj` —
  PASS; izolirana org. `9808`, dedup/retry/dead/sent/verified/drift, čiščenje in
  dva `PATCH` klica izključno na lokalni `127.0.0.1` fixture.
- `dotnet run --project tests/PIM.F8.HardeningTests/PIM.F8.HardeningTests.csproj`
  — PASS; izolirana org. `9813`, adversarial enqueue, pozni completion, crash,
  atomic reclaim, closure poskusa, concurrent recovery in izbira echo hasha.
- `dotnet build PIM.sln --no-restore` — PASS, 0 opozoril, 0 napak.
- `git diff --check` — PASS.

Oba MSSQL testa v `finally` odstranita izključno svoje vrstice, profile, policy
in organizacije. `PIM_test` ni bil dostopan ali spremenjen.

## Blokada živega SAOP

Živi SAOP write ni bil izveden in ni označen kot uspešen. Ostaja **BLOCKED** za
ročno testiranje: manjkajo potrjen neprodukcijski endpoint/payload kontrakt,
varen testni izdelek, poverilnice in izrecno dovoljenje za zunanjo spremembo.
Privzeti integracijski profil ostaja onemogočen z `ManualApproval`.
