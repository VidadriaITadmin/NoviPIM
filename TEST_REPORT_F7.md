# Poročilo preverjanja F7 — B2B kanal

Datum: 2026-07-31

## Sklep

F7 je `PASS` tudi na dejanski MSSQL bazi `PIM`. Migrator je bil idempotentno
zagnan, `--verify` je uspešen, `tests/sql/Verify-F7.sql` pa je izveden iz
MSSQL integracijskega testa. Test uporablja lokalno ignorirano konfiguracijo
`ConnectionStrings:Pim`; povezovalni niz ni bil izpisan in ni zapisan v
repozitoriju.

Živi SAOP ni bil klican. Test v `PIM.F7.Integration` vstavi lasten generični
JSON landing zapis z izvorno oznako `SAOP`, ne izvaja nobenega omrežnega klica.
`PIM_test` ni bil dostopan ali spreminjan. F8 ni bil začet.

## Strogi RED → GREEN

Nov dejanski MSSQL test je bil najprej zagnan s pričakovanjem štirih audit
zapisov in je pravilno padel z:

```text
System.InvalidOperationException: Shranjevanje profila in pragov ni revidirano.
exit 134
```

To je razkrilo, da klici `SaveCustomerWebProfile`, tri `SaveCustomerValueTier`
in `SaveCustomerTypeMapping` ustvarijo **pet** audit zapisov. Pričakovanje je
bilo popravljeno na pet in test je uspešen.

## Dejansko MSSQL preverjanje — PASS

```text
$ dotnet run --project src/PIM.Migrator/PIM.Migrator.csproj --no-restore
Preskočena že uporabljena migracija: 001_CreateSchemas.sql
...
Preskočena že uporabljena migracija: 020_CreateB2bChannel.sql
Migracije so uspešno uporabljene.

$ dotnet run --project src/PIM.Migrator/PIM.Migrator.csproj --no-restore -- --verify
Preverjanje F0–F7 baze je uspešno.

$ dotnet run --project tests/PIM.F7.Integration/PIM.F7.Integration.csproj --no-restore
F7 integration: več strank in izdelkov, komponente pravil, Unknown ter dostava PASS.
F7 MSSQL integration: landing, profil, revizija, B2B izvozi in čiščenje PASS.
```

MSSQL del testa na PIM:

1. izvede `tests/sql/Verify-F7.sql` proti dejansko nameščeni shemi;
2. ustvari izolirano organizacijo `9707` ter GUID testna ključa za stranko in
   izdelek;
3. vstavi generični `b2b.LandingRecord` (`SAOP`/`Customers`) in kliče
   `b2b.ApplyLandingRecord`;
4. kliče `SaveCustomerWebProfile`, vse tri `SaveCustomerValueTier` in
   `SaveCustomerTypeMapping`, nato potrdi profil ter pet audit zapisov;
5. ustvari izoliran `pim.Product`, `pim.ProductCommercial` in S2 popust ter
   kliče dejanske procedure `out.ExportB2bCustomersCsv`,
   `out.ExportB2bProductsCsv` in `out.ExportB2bShippingCsv`;
6. potrdi 18 aktivnih tipov strank, 4 aktivne S-stopnje, 3 aktivne vrednostne
   pragove in odsotnost izmišljene skupine `UNASSIGNED`;
7. obnovi prejšnjo globalno Magento preslikavo `INSTALLER` in odstrani samo
   dokazno organizacijo ter njene B2B/PIM vrstice. Po testu eksplicitno potrdi,
   da organizacija, izdelki in stranke organizacije `9707` ne obstajajo.

## F7 testni sklop in build — PASS

```text
$ dotnet run --project tests/PIM.F7.ContractTests/PIM.F7.ContractTests.csproj --no-restore
F7 contract: B2B podatkovni in izvozni kontrakt PASS.

$ dotnet run --project tests/PIM.F7.BehaviorTests/PIM.F7.BehaviorTests.csproj --no-restore
F7 behavior: deterministični popustni motor PASS.

$ dotnet run --project tests/PIM.F7.MappingTests/PIM.F7.MappingTests.csproj --no-restore
F7 mapping: konfiguracijski landing, replay in zavrnitve PASS.

$ dotnet build PIM.sln --no-restore
Build succeeded.
    0 Warning(s)
    0 Error(s)
```

Spremenjeni sta le PIM F7 integracijski projekt/test in ta dokumentacija ter
`PROGRESS.md`. Obstoječe nesledene datoteke niso bile stageane.
