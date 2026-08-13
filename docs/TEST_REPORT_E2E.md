# E2E dokazno poročilo — lokalni PIM

Datum: 2026-08-12
Okolje: lokalni Windows, SQL Server `DESKTOP-2CGGQIC\MSSQLSERVER3`, razvojna baza `PIM`, Windows Integrated Authentication, `Encrypt=True`, `TrustServerCertificate=True`.

## Izvedeni in uspešni dokazi

| Področje | Dokaz | Rezultat |
|---|---|---|
| Build | `dotnet build PIM.sln --no-restore --nologo -v minimal` | PASS, 0 warnings, 0 errors |
| Migracije | `PIM.Migrator --verify` proti `PIM` | PASS: `Preverjanje F0–F10 baze je uspešno.` |
| F0 | migracijski izhodiščni kontrakt | PASS |
| F2 | integracija | PASS |
| F3 | samostojni fixture tok | PASS: CSV vrstic=17, XML deklaracija/ERP upravičenost/requeue karantene preverjeni |
| F5 | samostojni fixture tok | PASS v uspešnem samostojnem zagonu: EAN kategorija/medij/atribut, B2C validacija, promocija, CSV |
| F6 | file worker/stock integracija | PASS: NW=2697/0, BT=1361/0, intranet read model vrne vrstico |
| F7 | B2B integration/mapping/behavior/contract | PASS |
| F8 | contract/behavior/dispatcher/echo/hardening/integration/intranet | PASS; lokalni HTTP fixture, brez zunanjega klica |
| F9 | alert/behavior/contract/deploy/integration/intranet | PASS |
| F10 | auth + Dashboard, Products, ProductDetail, Customers, Stocks, Quality, PipelineRuns, Outbound, SystemIntegrations UX pogodbe | PASS |
| Intranet | Kestrel `http://127.0.0.1:5199` | PASS: `/health`, `/prijava`, `/PIM/prijava`, CSS vsi HTTP 200 |

## Popravki med dokaznim ciklom

1. `StockCsvGenerator` zdaj izrecno uporablja UTF-8 brez BOM in LF, zato je STOCK CSV determinističen tudi v Windows okolju.
2. F0 kontrakt preverja najmanj osnovnih deset migracij, ne napačno točno deset po razširitvi F0–F10 paketa.
3. F5 staging dokaz preverja dejansko aktivno `map.*` konfiguracijo, ne zastarelega fiksnega števila mappingov.
4. Outbound in Stocks UI ohranjata pogodbeni števili stolpcev ter zahtevane slovenske/dostopne oznake, brez novih read modelov ali lažnih podatkov.
5. `.gitignore` izključi `appsettings.Local.json` v korenu in podmapah.

## Odpravljen problem FK 547 v F3/F5 cleanupu

Prejšnje poročilo je vzrok napačno označilo kot SQL timeout. Ponovitev z dejanskima
izvršljivima integracijama je pokazala `SqlException 547` v cleanupu obeh tokov:
`pim.ProductFieldHistory.ProductId` ima FK na `canon.Product.ProductId`.

Cleanup je najprej pobrisal obstoječo zgodovino, nato pa z `DELETE` nad
`canon.ProductText`, `canon.ProductAttribute` in `canon.ProductMedia` sprožil
triggerje sledljivosti. Ti so za isti ozko določeni testni izdelek ustvarili nove
zgodovinske vrstice. Poznejši `DELETE canon.Product` je zato padel na FK 547.

F3 in F5 zdaj po brisanju sledenih kanoničnih podtabel še enkrat pobrišeta samo
zgodovino izdelka z lastnima pogojema `OrganizationId` + `ItemID` in nato samo
prazne batche, ki pripadajo temu testu. Ni `DROP`, `TRUNCATE` ali neomejenega
brisanja. S tem cleanup ne posega v zgodovino drugih izdelkov niti v batche z
drugo zgodovino.

Dokaz po popravku, 2026-08-12:

- `dotnet run --project PIM_Solution/tests/PIM.F3.Integration --no-restore` → 0;
- `dotnet run --project PIM_Solution/tests/PIM.F5.Integration --no-restore` → 0;
- `dotnet test PIM_Solution/PIM.sln --no-restore` → 0, dvakrat zapored;
- `dotnet build PIM_Solution/PIM.sln --no-restore` → 0 (0 warnings, 0 errors).

## Zunanje meje

Niso bile izvedene in ostajajo SKIP:
- živi SAOP GET ali write-back;
- Magento/FTP/HTTP dostava izvozov;
- resni webhook/e-mail alerti;
- IIS deploy in Scheduled Tasks (sistemske spremembe niso bile izvedene).

Za natančen prenos na laptop uporabi `docs/LAPTOP_INSTALL.md`; za korak-po-korak E2E izvedbo uporabi `docs/END_TO_END_TEST.md`.

## E2E zagon 2026-08-13 (koraki 1-5)

Okolje: lokalni Windows, razvojna baza `PIM`; zunanji endpointi in produkcijska
dostava niso bili uporabljeni. Povezovalni niz ni izpisan. Izvedel: Hermes.

### 1 — baza in zgradba — PASS

- `dotnet build PIM_Solution/PIM.sln --nologo -v:minimal` → izhod 0; `0 Warning(s)`,
  `0 Error(s)`.
- Prvi `dotnet run --project PIM_Solution/src/PIM.Migrator -- --verify` je vrnil
  izhod 2, ker predpisani `PIM_MIGRATIONS_PATH` še ni bil nastavljen in je
  migrator iskal neobstoječo pot `...\NoviPIM\sql\migrations`. To ni napaka
  kode ali migracije.
- Ponovitev z `PIM_MIGRATIONS_PATH=...\PIM_Solution\sql\migrations` → izhod 0:
  `Preverjanje F0–F10 baze je uspešno.`
- Dva zaporedna zagona migratorja brez `--verify` z isto nastavitvijo → oba
  izhod 0 in `Migracije so uspešno uporabljene.` Drugi zagon ni uporabil nove
  migracije: vse `001`–`039` so bile izpisane kot že uporabljene.

### 2 — vsi testi — PASS

- Iz korena repozitorija: `scripts\run_tests.ps1` → izhod 0;
  `REZULTAT: VSE OK`.
- Povzetek zaganjalnika: `uspeli: 42`, `preskoceni: 0`, `padli: 0`.
- Zaganjalnik je povezavo do lokalne razvojne baze varno prevzel iz
  `appsettings.Local.json`; vrednost ni bila izpisana.

### 3 — fixture pipeline — PASS

- F3: `dotnet run --project PIM_Solution/tests/PIM.F3.Integration --no-build`
  → izhod 0; SAOP katalog, XML deklaracija/ERP upravičenost in varna ponovna
  vrstitev karantene so uspešni; CSV ima `17` vrstic.
- F5: `dotnet run --project PIM_Solution/tests/PIM.F5.Integration --no-build`
  → izhod 0; EAN obogatitev kategorije, medija in atributa, B2C validacija,
  promocija v `pim` in CSV so uspešni. Testni izhod ne izpiše števca ali
  RunId-ja; zato ni naveden noben izmišljen števec in dokaz ostaja izhod 0.
- F6: iz projektne mape z lokalno `PIM_CONNECTION_STRING`:
  `dotnet run --project PIM.F6.Integration.csproj --no-build` → izhod 0;
  `NW=2697/0 applied/quarantine`, `BT=1361/0`, intranet read model je vrnil
  realno vrstico. Test ne izpisuje RunId-ja.
- F7: iz projektne mape z lokalno `PIM_CONNECTION_STRING`:
  `dotnet run --project PIM.F7.Integration.csproj --no-build` → izhod 0;
  lokalno ustvarjeni in preverjeni so `customers.csv`, `products.csv` in
  `shipping.csv`; MSSQL landing, profil, revizija, B2B izvozi in cleanup so
  uspešni. Test ne izpisuje RunId-ja.

### 4 — outbox meja — PASS / SKIP

- F8: iz projektne mape z lokalno `PIM_CONNECTION_STRING`:
  `dotnet run --project PIM.F8.Integration.csproj --no-build` → izhod 0;
  izolirana organizacija `9808`, dedup, retry, dead, sent, verified in drift
  so uspešni. HTTP fixture uporablja le dinamični `127.0.0.1` listener in dva
  lokalna PATCH klica; noben zunanji endpoint ni bil klican.
- F8 lease recovery: `dotnet run --project PIM.F8.HardeningTests.csproj --no-build`
  → izhod 0; uspešni so potekli lease, crash reclaim in sočasna recovery.
- Živ SAOP write-back — **SKIP**: ni potrjenega testnega endpointa/pogodbe,
  testnega artikla, skrivnosti in izrecne odobritve. Živega klica ni bilo.

### 5 — intranet smoke — PASS

- Končni kontrolirani PowerShell zagon:
  `$env:ASPNETCORE_URLS = 'http://127.0.0.1:5088'`; nato
  `$p = Start-Process dotnet -ArgumentList 'run','--project','PIM_Solution\src\PIM.Intranet','--no-build','--no-launch-profile' -PassThru`;
  `Invoke-WebRequest http://127.0.0.1:5088/health -UseBasicParsing` → HTTP
  `200`, telo `{"stanje":"zdravo"}`; na koncu `$p | Stop-Process`.
- Proces je bil v `finally` ustavljen (`INTRANET_STOPPED=True`), zato ni ostal
  živ intranet proces.
- Opomba o izvedbi: brez `--no-launch-profile` je `launchSettings.json`
  preusmeril proces na `localhost:5091`; s pravilnim parametrom je zahtevan
  5088 endpoint uspešen.

### 6 — IIS smoke — SKIP

Izven obsega: zahteva laptop, skrbniške pravice in sistemske nastavitve IIS.
Ni bil izveden noben publish, IIS poseg ali Scheduled Task.

### Za ročno preverjanje (človek)

- `/nadzorna-plosca`: preveri podatkovne KPI; FAIL so statične ali izmišljene številke.
- `/izdelki`: preveri strežniško iskanje, status, paginacijo in obstoječo kartico; FAIL je nedelujoče iskanje ali prazna kartica za obstoječ izdelek.
- `/zaloge`: preveri količino, prihod, vir in posodobitev/status; FAIL so izmišljena skladišča/rezervacije ali manjkajoč realni podatek.
- `/napake-validacije`: preveri resnično prazno, napako in podatkovno stanje; FAIL je lažno ali neberljivo stanje.
- `/karantena`: preveri resnično prazno, napako in podatkovno stanje; FAIL je lažno ali neberljivo stanje.
- `/teki-obdelave`: preveri realne pipeline teke; FAIL so placeholderji namesto dejanskih tekov.
- `/outbound`: samo odobri, prekliči ali ponovi testno outbox sporočilo; FAIL je možnost zagona živega dispatcherja ali zunanji klic.
- `/system/integracije` kot ADMIN: potrdi/razreši testni alarm ter preveri audit akterja in UTC čas; FAIL je manjkajoč ali napačen audit.
- Po prijavi preveri odjavo, VIEWER/ADMIN navigacijo, tipkovnični fokus in konzolo brskalnika; FAIL so 404 CSS/JS ali nedostopen fokus.

### Meje in nepreverjeno

Avtomatizirano so preverjeni koraki 1–5. Niso preverjeni ročni brskalniški
koraki, IIS/laptop objava, živ SAOP write-back, FTP/Magento/HTTP dostava,
webhooki in e-pošta. Zato ta zagon ni dokaz produkcijske pripravljenosti.
VERDICT: PASS
