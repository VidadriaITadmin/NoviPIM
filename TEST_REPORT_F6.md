# TEST_REPORT_F6

Datum: 2026-07-31

## TDD

- RED podatkovni kontrakt: manjkala je migracija 018 in vseh deset zahtevanih
  `stock.*`/`map.*`/proceduralnih objektov. GREEN: `F6 contract: ločeni stock
  podatkovni objekti PASS.`
- RED normalizacija: projekt `PIM.StockMapping` ni obstajal (`CS0246`). GREEN:
  konfiguracijska CSV/XML ekstrakcija, NW/BT identiteta, ničelna količina,
  NUL opcijske vrednosti, sintetični tretji vir ter karantena za manjkajočo
  identiteto, negativno/neveljavno količino in datum so uspešni.
- RED fixture transport: projekt `PIM.StockFileWorker` ni obstajal (`CS0246`).
  Prvi GREEN poskus je še pravilno padel, ker je bil NW ločilnik napačno `;`;
  po popravku na dejanski `,` sta bili prebrani natanko 2.697 in 1.361 vrstic.
- RED SAOP provider: projekt `PIM.SaopStockWorker` ni obstajal (`CS0246`).
  GREEN: vsi trije `ProviderKind` profili ustvarijo pravi request shape;
  RegisteredView zahteva ID, warehouse providerja zahtevata warehouse ID-je.
- RED STOCK CSV/intranet: manjkala sta `StockCsvGenerator` in `StockExportRow`
  (`CS0246`). GREEN: ustvarjena je bila prava UTF-8 CSV datoteka s stabilno
  glavo in podatkovno vrstico, slovenska avtorizirana stran pa vsebuje vse
  zahtevane prikaze.

## MSSQL PIM

Uporabljena je bila izolirana migracijska mapa samo s forward migracijo
`018_CreateStockPipeline.sql`; obstoječe untracked 012–014 niso bile uporabljene,
spremenjene ali staged.

- prvi tek: `Uporabljena migracija: 018_CreateStockPipeline.sql`;
- drugi tek: `Preskočena že uporabljena migracija: 018_CreateStockPipeline.sql`;
- `--verify`: `Preverjanje F0–F6 baze je uspešno.`;
- fixture SQL writer: NW `2697 applied / 0 quarantined`, BT
  `1361 applied / 0 quarantined`;
- `intranet.GetStocks` je vrnil realno normalizirano zalogovno vrstico;
- fixture ne vsebuje neveljavnih obveznih vrednosti; negativna, neveljavna in
  manjkajoča identiteta so zato dokazane s sintetičnimi vedenjskimi testi.

SAOP v živo ni bil klican, ker F6 nima potrjene neskrivne provider/warehouse
konfiguracije. Stanje ni bilo fabricirano.

## PIM_test

Izvedena je bila samo read-only poizvedba z `HAS_PERMS_BY_NAME`; noben zapis ni
bil ustvarjen ali spremenjen. Rezultat je `SELECT=1, INSERT=1`, zato lokalna
prijava dejansko ni omejena na read-only in tega poročilo ne prikazuje kot
izpolnjeno varnostno lastnost.

## Končna preverjanja

- F3 contract/behavior/integration: PASS (25 izdelkov, 70 cen, 1 opis,
  CSV 18 vrstic).
- F5 contract/behavior/review integration/integration: PASS.
- vsi F6 contract/behavior/file/provider/integration testi: PASS.
- `dotnet build PIM.sln --no-restore`: PASS, 0 opozoril, 0 napak.
- `dotnet publish src/PIM.Intranet/PIM.Intranet.csproj -c Release --no-restore`:
  PASS; Linux publish artefakt vsebuje `PIM.Intranet.dll`. Končni IIS
  end-user preizkus ni izveden, ker zahteva Windows/IIS okolje.
- `npm test`: PASS, 1 datoteka in 1 test.
- `npm run lint`: PASS; obstoječi skript izpiše `(lint se doda kasneje)`.
- `git diff --check`: PASS.

F7/F8 nista bila začeta.
