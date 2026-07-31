# Dnevnik napredka (observability — sloj 9)

> Vsak agent po zaključeni nalogi doda vrstico. Format:
> `DATUM | KDO (codex/claude) | NALOGA | TESTI (pass/fail) | commit`

| Datum | Kdo | Naloga | Testi | Commit |
|-------|-----|--------|:-----:|--------|
| 2026-01-01 | (primer) codex | postavitev projekta | pass | a1b2c3d |
| 2026-07-29 | Hermes | F0: repo, MSSQL migracije, ops in konfiguracija | pass | ni commita |
| 2026-07-29 | Hermes | F1: izhodni kontrakt in generirani validacijski zahtevki | pass | commit F1 |
| 2026-07-29 | Hermes | F2: kanonični model, validacija in promocija | pass | commit F2 |
| 2026-07-29 | Claude | F3 popravka: migracija 009 (map.StripXmlDeclaration; SupplierID/DiscountGroup1ID → Product.Supplier/DiscountGroup) | build+F0+F3.ContractTests+F3.Integration(brez DB) pass; F3.BehaviorTests fail (obstoječe neujemanje fixture 500 vs. pričakovanih 25, ni del tega popravka); DB migracija/integracija ni preverjena — PIM_CONNECTION_STRING ni na voljo | ni commita |
| 2026-07-30 | Hermes | F3: SAOP fixture iz PIM_test, raw nabiralnik, preslikava, validacija, promocija in PRODUCTS CSV | pass — migracije dvakrat, `--verify`, realna integracija (CSV 17 vrstic), build, testi in win-x64 publish | sledi commit F3 |
| 2026-07-31 | Codex | F5: generični C# XPath extractor, staging in source-agnostic SQL apply | pass — migracija 016 dvakrat, F5 EAN/B2C/pim/CSV, F3 regresija, build, npm test/lint | 4fc64a4 + dokazni commit |
