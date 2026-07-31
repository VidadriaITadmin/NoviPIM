# Poročilo preverjanja F7 — B2B kanal

Datum: 2026-07-31

## Sklep

F7 fixture pogodba, vedenje, preslikava in integracija so `PASS`. MSSQL PIM
preverjanje je `BLOCKED`, ker `PIM_CONNECTION_STRING` ni prisoten. Živi SAOP je
`BLOCKED` in ni bil klican. `PIM_test` ni bil dostopan. F8 ni bil začet.

Migrator odkriva `*.sql`, jih deterministično razvrsti po imenu, zato prepozna
`020_CreateB2bChannel.sql`, in njegov `--verify` kliče `VerifyF7Async`. To je
pokrito tudi s pogodbenim testom.

## Fixture testi — PASS

Vsi ukazi so bili izvedeni z odstranjenima `PIM_CONNECTION_STRING` in
`PIM_TEST_CONNECTION_STRING` ter `--no-restore`.

```text
$ dotnet run --project tests/PIM.F7.ContractTests/PIM.F7.ContractTests.csproj --no-restore
F7 contract: B2B podatkovni in izvozni kontrakt PASS.
exit 0

$ dotnet run --project tests/PIM.F7.BehaviorTests/PIM.F7.BehaviorTests.csproj --no-restore
F7 behavior: deterministični popustni motor PASS.
exit 0

$ dotnet run --project tests/PIM.F7.MappingTests/PIM.F7.MappingTests.csproj --no-restore
F7 mapping: konfiguracijski landing, replay in zavrnitve PASS.
exit 0

$ dotnet run --project tests/PIM.F7.Integration/PIM.F7.Integration.csproj --no-restore
F7 integration: več strank in izdelkov, komponente pravil, Unknown ter dostava PASS.
exit 0
```

## F3/F5/F6 regresije

```text
$ dotnet run --project tests/PIM.F3.ContractTests/PIM.F3.ContractTests.csproj --no-restore
F3 statični kontrakt je izpolnjen.
exit 0

$ dotnet run --project tests/PIM.F3.BehaviorTests/PIM.F3.BehaviorTests.csproj --no-restore
F3 vedenjski testi so uspešni: izdelki=25, cene=70, opisi=1.
exit 0

$ dotnet run --project PIM_Solution/tests/PIM.F3.Integration/PIM.F3.Integration.csproj --no-restore
F3 integracija preskočena: manjka PIM_CONNECTION_STRING oziroma ConnectionStrings:Pim v appsettings.Local.json.
exit 0

$ dotnet run --project tests/PIM.F5.ContractTests/PIM.F5.ContractTests.csproj --no-restore
F5 contract: generična staging/apply pot PASS.
exit 0

$ dotnet run --project tests/PIM.F5.BehaviorTests/PIM.F5.BehaviorTests.csproj --no-restore
F5 behavior: generična XPath ekstrakcija in config-only prihodnji vir PASS.
exit 0

$ dotnet run --project PIM_Solution/tests/PIM.F5.Integration/PIM.F5.Integration.csproj --no-restore
Unhandled exception. System.InvalidOperationException: Manjka razvojna povezava Pim; F5 integracije ni dovoljeno preskočiti.
   at Program.<Main>$(String[] args) in /workspace/projekti/NoviPIM/PIM_Solution/tests/PIM.F5.Integration/Program.cs:line 12
   at Program.<Main>(String[] args)
exit 134 — BLOCKED, ni PASS

$ dotnet run --project tests/PIM.F6.ContractTests/PIM.F6.ContractTests.csproj --no-restore
F6 contract: ločeni stock podatkovni objekti PASS.
exit 0

$ dotnet run --project tests/PIM.F6.BehaviorTests/PIM.F6.BehaviorTests.csproj --no-restore
F6 behavior: generična normalizacija CSV/XML in karantena PASS.
exit 0

$ dotnet run --project tests/PIM.F6.FileWorkerTests/PIM.F6.FileWorkerTests.csproj --no-restore
F6 fixtures: NW=2697, BT=1361, SHA-256 sled PASS.
exit 0

$ dotnet run --project tests/PIM.F6.SaopProviderTests/PIM.F6.SaopProviderTests.csproj --no-restore
F6 SAOP: konfiguracijska izbira providerja in zahtev PASS.
exit 0

$ dotnet run --project tests/PIM.F6.Integration/PIM.F6.Integration.csproj --no-restore
F6 integration (brez DB): realni STOCK CSV in slovenska stran PASS.
F6 DB integration: SKIP — povezava Pim ni konfigurirana.
PIM_test capability: SKIP — povezava ni konfigurirana.
exit 0
```

F6 integracija je bila zagnana iz izoliranega fixture delovnega imenika brez
lokalne konfiguracije, zato ni dostopila do PIM ali `PIM_test`.

## MSSQL PIM — BLOCKED

V okolju ni nepraznega `PIM_CONNECTION_STRING`. Migrator je bil zagnan brez te
spremenljivke in ni poskusil povezave ali izvedbe migracije:

```text
$ env -u PIM_CONNECTION_STRING dotnet run --project PIM_Solution/src/PIM.Migrator/PIM.Migrator.csproj --no-restore
Manjka PIM_CONNECTION_STRING oziroma ConnectionStrings:Pim v appsettings.Local.json. Connection string ni zapisan v repozitorij.
exit 2
```

Zato migracija 020 na MSSQL, ponovni idempotentni zagon, `--verify` in
`tests/sql/Verify-F7.sql` niso bili izvedeni in niso označeni kot uspešni.

## Živi SAOP — BLOCKED

Živi SAOP ni bil klican, ker za ta closeout ni bila podana potrjena živa
konfiguracija. Uspešen `PIM.F6.SaopProviderTests` je fixture/config test in ni
dokaz živega SAOP dostopa.

## Build in repozitorijske kontrole — PASS

```text
$ dotnet build PIM_Solution/PIM.sln --no-restore
Build succeeded.
    0 Warning(s)
    0 Error(s)

Time Elapsed 00:00:11.81
exit 0

$ npm test
> NoviPIM@0.1.0 test
> vitest run

 RUN  v2.1.9 /workspace/projekti/NoviPIM

 ✓ tests/index.test.js (1 test) 2ms

 Test Files  1 passed (1)
      Tests  1 passed (1)
exit 0

$ npm run lint
> NoviPIM@0.1.0 lint
> echo "(lint se doda kasneje)"

(lint se doda kasneje)
exit 0

$ git diff --check
exit 0 (brez izhoda)
```

Nesledeni `PIM_Solution/docs`, `.hermes`, `PIM_test`, `package-lock.json` in
migracije 012–014 niso bili stageani.
