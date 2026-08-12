# TEST_REPORT_F3 — SAOP → PRODUCTS CSV

Čas preverjanja: 2026-07-30T10:20:04Z

## Rezultat

**PASS.** F3 je dokazano izvedena proti živima neprodukcijskima bazama na isti SQL Server instanci. `PIM_test` je bil uporabljen izključno za branje zgodovine SAOP odgovorov; `PIM` je cilj migracij in F3 obdelave.

## Povezava in namestitev

- SQL Server: `host.docker.internal:14333`, SQL Server Developer Edition (64-bit), ime strežnika `a54dda0f8901`.
- `PIM_test`: podatkovni datoteki sta `/var/opt/mssql/data/PIM_test.mdf` in `/var/opt/mssql/data/PIM_test_log.ldf`.
- `PIM`: podatkovni datoteki sta `/var/opt/mssql/data/PIM.mdf` in `/var/opt/mssql/data/PIM_log.ldf`.
- Prijava `pim_hermes` se uspešno poveže v obe bazi. V `PIM_test` je bil izveden le bralni izvoz; v `PIM` ima potreben dostop za migracije in F3 tok.

## Dejanski vir in zajem

Orodje `PIM.FixtureExport` je iz `PIM_test.raw_history.ApiResponses` samo bralno izbralo polne, ne-prazne zajete SAOP odgovore organizacije IQLighting (2) in zapisalo manifest z vsemi stranmi:

| Končna točka | Izbrani RunId | Strani |
|---|---:|---:|
| ItemGeneralData | `1cb417976ae4` | 7 |
| Prices | `4a39cc4d1d9f` | 4 |
| Descriptions | `894943c14257` | 2 |
| Currencies | `05d0ebe33252` | 2 |
| PriceLists | `5cf5e1bacf91` | 2 |

Worker v načinu Fixture je prebral manifest in brez omrežnega klica obdelal 5.303 izdelkov, 288 cen in 156 opisov. Prazni odgovori strani se pri štetju varno preskočijo, surovi payload pa ostane nespremenjen v nabiralniku.

## MSSQL dokaz F3

- Prvi zagon migratorja je potrdil obstoječo bazo `PIM` in skladnih 9 migracij F0–F3.
- Drugi zagon je vseh 9 migracij pravilno preskočil.
- `PIM.Migrator --verify` je vrnil: `Preverjanje F0–F3 baze je uspešno.`
- Realni F3 integracijski tok je uspešno izvedel registrirano zaporedje preslikava → validacija → promocija in vrnil 17 CSV vrstic.
- Zadnji obdelani `ops.PipelineRun` ima stanje `Succeeded`, 10 zajetih raw zapisov, 9 uspešno obdelanih in 1 karantenski zapis. Razlika med številom prebranih manifestnih strani in novimi raw zapisi je posledica hash deduplikacije že zajetih enakih strani.
- Za organizacijo 2 je stanje validacije: `ERP_L1 VALID = 17`, `ERP_L1 INVALID = 6.098`, `WEB_B2C INVALID = 6.115`.
- `pim.Product` za organizacijo 2 vsebuje 17 promoviranih izdelkov.
- `out.ExportProductsCsv` je za aktivni profil vrnil 17 vrstic.

## Samodejni testi in objava

| Preverjanje | Rezultat |
|---|---|
| `dotnet build PIM.sln --no-restore` | PASS, 0 opozoril in 0 napak |
| F0–F3 migracijski kontrakt | PASS |
| F3 statični kontrakt | PASS |
| F3 vedenjski test | PASS — 25 izdelkov, 70 cen, 1 opis; brez omrežnih klicev v Fixture načinu |
| F3 integracija proti `PIM` | PASS — CSV 17 vrstic, XML/preslikava in varna ponovna vrstitev preverjeni |
| `npm test` | PASS — 1 test |
| `npm run lint` | PASS — trenutno informativni ukaz |
| self-contained `win-x64` publish | PASS — `PIM.KatalogWorker.exe` preverjen v `/tmp/pim-f3-publish` |
| `git diff --check` | PASS |

## Meja F3

F3 pokriva samo SAOP → PRODUCTS CSV za organizacijo IQLighting. NW XML, B2B, zaloge, intranet in zapisovanje v zunanje sisteme niso bili dodani.

Poverilnice in povezovalni nizi niso zapisani v tem poročilu ali sledeni datoteki.
