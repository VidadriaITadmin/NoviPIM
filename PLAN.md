# PLAN — izvedene in naslednje faze PIM sistema

## F8 — SAOP outbox in echo

Status: fixture in izolirani PIM MSSQL dokaz zaključena 2026-07-31; ustavljeno
pred F9. Živi SAOP write je blokiran brez potrjene neprodukcijske pogodbe in
izrecnega dovoljenja.

Izvedeni so generični `out.OutboxMessage`/`out.OutboxAttempt`, konfiguracijska
policy lastništva in integracijski profil s privzetim `ManualApproval`, atomske
procedure za enqueue/claim/lease/attempt/approve/cancel/retry/echo, determinističen
`PIM.Outbound`, POST/PATCH dispatcher z redakcijo in omejenim retryjem, echo
anti-loop ter slovenski `/outbound` monitor. Migracija 021 je bila na razvojni
bazi `PIM` uporabljena in idempotentno ponovno preverjena. Izolirana organizacija
9808 je z lokalnim HTTP fixture strežnikom dokazala dedup, Retry, Dead, Sent,
Verified in Drift ter bila po testu odstranjena. F9 ni začeta.

## F6 — zaloge

Status: zaključeno in dokazano 2026-07-31; ustavljeno pred F7/F8.

Izvedeni so ločena `stock.*` domena, konfiguracijska pravila
`map.StockIdentityRule`, immutable landing/snapshot/position/unmatched/sync
model, generična normalizacija, tanka NW CSV in BT XML transporta,
konfiguracijski SAOP provider registry, realna MSSQL persistenca, STOCK CSV ter
avtorizirana slovenska intranetna stran. Migraciji 018 in forward 019 (pravila
identitete v konfiguraciji, ki jo worker bere po konektorju) sta bili proti `PIM`
uspešno izvedeni dvakrat in preverjeni. Živi SAOP ni bil klican brez potrjene
konfiguracije. `PIM_test` ni bil spremenjen; read-only preverjanje pravic je
pokazalo, da lokalna prijava poleg SELECT trenutno ima tudi INSERT.

## F0 — temelji

Status: zaključeno in verzionirano v commitu `ce7feac`.

Vzpostavljeni so rešitev .NET 8, migrator, `dbo.SchemaMigration`, sheme, `ops.*`, `dbo.OrganizationConfig`, varna okoljska konfiguracija, testni skelet in dokaz dvakratnega zagona migracij proti razvojni bazi `PIM`.

## F1 — izhodni kontrakt: definicija »poln«

Status: zaključeno in verzionirano v commitu `eb2bf98`.

Vzpostavljena sta izvozna profila ERP L1 in WEB B2C ter generiranje `val.FieldRequirement` iz aktivnih izvoznih stolpcev.

## F2 — enotni obrazec in pravilnik

Status: zaključeno; čaka na ločen commit F2.

### Meja izvedbe

Izvedena bo izključno F2 iz avtoritativne specifikacije. Ne bodo dodani workerji, zajem iz SAOP/NW/BT, `raw.*`, `map.*`, CSV izvoz, intranetne strani ali pisanje v zunanje sisteme. Vnos testnega izdelka je dovoljen izključno za dokazovanje F2 v razvojni bazi.

### Koraki

1. Napisati kontraktne teste za kanonični model, ločeni proceduri validacije/promocije in idempotentni dokaz z ročnim testnim izdelkom.

2. Dodati novo oštevilčeno MSSQL migracijo, ki ustvari vir-agnostične tabele `canon.*`:
   - `canon.Product` s skalarnimi polji iz DEL 3.5;
   - `canon.ProductText`, `canon.ProductAttribute` (EAV), `canon.ProductCategory`, `canon.ProductMedia`, `canon.ProductPrice` in `canon.ProductCommercial`;
   - enolične ključe, tuje ključe do `dbo.OrganizationConfig`, omejitve in indekse za idempotentne postopke.

3. Dodati potrjeni katalog `pim.Product*`, ločen od `canon.*`, z identiteto izdelka in kopijo potrjenih podatkov, potrebnih za dokaz promocije.

4. Dodati `val.ProductIssue` in razširiti kanonični izdelek s statusom validacije ter completeness po aktivnih validacijskih profilih.

5. Dodati dve ločeni idempotentni proceduri:
   - `val.RunValidation`: bere samo `val.FieldRequirement` in `canon.*`, za vsak profil ponovno izračuna napake, status in completeness; ne piše v `pim.*`;
   - `val.Promote`: promovira samo izdelke brez aktivnih napak oziroma statusom `VALID` iz `canon.*` v `pim.*`; ne izvaja validacije.

6. Uvesti razreševanje vseh F1 `FieldCode` vrednosti proti kanoničnim skalarnim, besedilnim, EAV, kategorijskim, medijskim in cenovnim podatkom. Postopek ostane podatkovno gnan: novo zahtevo določa `val.FieldRequirement`, ne nova veja poslovne logike.

7. Dodati F2 SQL-dokaz in migratorjevo `--verify` preverjanje za:
   - obstoj in hash nove migracije;
   - kanonične, validacijske in PIM objekte;
   - dokaz manjkajočega zahtevanega polja → `val.ProductIssue`;
   - popoln testni izdelek → `VALID` in ena idempotentna promocija v `pim.*`.

8. Preveriti na razvojni bazi `PIM`:
   - prvi zagon nove migracije;
   - drugi zagon brez podvojitev;
   - `--verify`, F2 SQL-dokaz in determinističen testni scenarij;
   - build, kontraktni testi, `npm test`, lint, pregled skrivnosti in `git diff --check`.

9. Posodobiti `TEST_REPORT_F2.md` in `PROGRESS.md`, pregledati izključno F2 spremembe, ustvariti ločen slovenski commit F2 in se ustaviti pred F3.

### Merila uspeha F2

- Kanonični model je brez odvisnosti od SAOP, Nowodvorski ali Braytron imen in struktur.
- EAV omogoča dodajanje atributa kot podatek, ne spremembo sheme.
- Validacija bere iste F1 šifrante kot izvoz ter označi manjkajoča polja v `val.ProductIssue`.
- Promocija je ločena od validacije in v `pim.*` sprejme samo veljavne izdelke.
- Ponovni zagon validacije in promocije ne ustvari podvojenih napak ali katalogskih zapisov.
- Nobena skrivnost ni v repoju, `PIM_test` ostane nespremenjen, F3 ni začeta.

## F3 — prva navpična rezina SAOP → PRODUCTS CSV

Status: zaključeno in dokazano na razvojni MSSQL instanci; sledi ločen commit F3.

### Meja izvedbe

Izvedena bo prva SAOP pot za organizacijo IQLighting (2). Worker bo samo zajel odgovor SAOP in ga zapisal v nabiralnik; vsa preslikava, validacija, promocija in izvoz bodo v MSSQL. NW XML, B2B, zaloge, intranet in write-back niso del F3.

### Predpogoji, ki jih mora zagotoviti uporabnik

- dosegljiv neprodukcijski SAOP iCenter API osnovni URL;
- način prijave in poverilnice oziroma drug varen način dostopa za GET;
- dovoljen dostop za `ItemGeneralData`, `Prices`, `Descriptions`, `Currencies` in `PriceLists` organizacije 2;
- potrditev razvojnega vzorca podatkov oziroma dovolj velik obseg za približno 500 izdelkov.

Poverilnice bodo uporabljene izključno prek okoljske spremenljivke ali lokalne, ignorirane konfiguracije; ne bodo zapisane v repo.

### Izvedbeni dodatek F3 — skupni MSSQL in lokalna konfiguracija

Pred migracijami F3 se na dosegljivem neprodukcijskem MSSQL strežniku na vratih 1433 preveri instanca in stanje baz. Ustvari oziroma uskladi se SQL-prijava `pim_hermes`; v `PIM_test` dobi samo pravico branja, v `PIM` pa članstvo `db_owner`. Če `PIM` na tem strežniku še ne obstaja, jo migrator idempotentno ustvari in nato uporabi vse migracije od F0 do F3; obstoječa baza se ne prepisuje ali obnavlja.

Oba povezovalna niza se shranita izključno v `PIM_Solution/appsettings.Local.json`, ki je že izključen iz Git-a. Migrator, F3 worker, integracijski test in izvoz fixture bodo najprej prebrali lokalno konfiguracijo, okoljske spremenljivke pa bodo ostale podprte kot prednostni način za CI/produkcijo. Niti gesla niti celotna povezovalna niza ne bodo vključeni v poročila, commit ali sledene datoteke.

Pred zaključkom se preveri: povezava prijave do obeh baz, dejanska pravica `db_datareader` v `PIM_test`, `db_owner` v `PIM`, prvi in drugi zagon migracij proti `PIM`, migracijska sled/hash, `--verify`, F3 integracija proti realni bazi in lokalna uporaba konfiguracije brez ročnega izvoza spremenljivk.

### Koraki

1. Dodati teste in oštevilčeno migracijo za `raw.*` nabiralnik, `map.SourceConnector`, `map.FieldMapping`, vodne žige in registrsko orkestracijo korakov.
2. Napisati tanek .NET 8 `KatalogWorker`, ki za pet dovoljenih SAOP entitet izvaja straničenje/delto in surove odgovore zapisuje v nabiralnik, z `ops.PipelineRun` ter heartbeatom.
3. Dodati parametrirano, šifrantno gnano MSSQL sortirnico iz nabiralnika v `canon.*`, z EAV, hashom in karanteno za pokvarjene vrstice.
4. Orkestrirati korake zajem → sortiranje → validacija → promocija ter izdelati PRODUCTS CSV iz aktivnega profila za org 2/B2C.
5. Preveriti razvojni in IIS self-contained `win-x64` objavni artefakt, testno pot približno 500 izdelkov, števce pipeline teka in dejanski CSV.
6. Posodobiti poročilo in napredek, nato ustvariti ločen commit F3 in se ustaviti pred F4.

### Merila uspeha F3

- En dokumentiran `ops.PipelineRun` dokazuje zajeto, veljavno in izvoženo število izdelkov.
- Worker ne izvaja transformacij; spremembe preslikav so vrstice registrov.
- PRODUCTS CSV vsebuje podatke iz `pim.*` in pravila iz F1 izvoznega profila.
- Enaka vertikalna pot je preverjena v `dotnet run` in IIS objavnem artefaktu.

### Meja NW XML

NW XML ni del F3. V F5 bo izključno konfiguracija skupnega mehanizma: `raw.LandingRecord` s `SourceCode = NW_XML`, `EntityType = Attribute | Classification | Media`, XPath vrstice v `map.FieldMapping`, merge po EAN in unmapped nabiralnik; brez NW parserja in brez NW tabel.

### Sprejeta omejitev razvojnega dokaza

Za F3 fixture dokaz je uporabnik potrdil trenutno razpoložljivi veljavni vzorec 25 artiklov, 70 cen in enega opisa. Worker in registri morajo vseeno obdelovati vse konfigurirane strani in pet endpointov; večji neokrnjeni vzorec oziroma živi SAOP bo naknadna operativna preveritev na uporabnikovem stroju s FortiClient VPN. B2C ostane resničen in zato pravilno nepopoln brez kategorije, slike in zahtevanega atributa; F3 dokaže tudi CSV mehaniko s praznimi spletnimi stolpci. Veljaven spletno-pripravljen B2C CSV je F5 DoD po združitvi SAOP in NW po EAN.

### Prihodnji NW XML kontrakt

NW XML ne dobi ločenega parserja ali ločenih tabel. Ob njegovi uvedbi se celotni nespremenjeni XML z `SourceCode='NW_XML'` shrani v skupni generični nabiralnik `raw.LandingRecord`; `EntityType` je `Attribute`, `Classification` ali `Media`. Preslikave XPath v `canon.*` so konfiguracijske vrstice `map.FieldMapping`, ujemanje s SAOP poteka po EAN, neznana polja pa se zadržijo v unmapped nabiralniku. F3 NW transporta, parserja ali podatkov ne uvaja.

## F7 — B2B kanal

Status: fixture izvedba zaključena in preverjena 2026-07-31; MSSQL PIM in živi SAOP sta blokirana brez `PIM_CONNECTION_STRING` oziroma potrjene žive konfiguracije. Ustavljeno pred F8.

Izvedeni so ločen `b2b.*` model, 18 poslovnih tipov strank z urejljivo Magento preslikavo, ročni spletni profili, S1–S4/PAK2, vrednostni in skupinski override popusti, dostavne politike, audit, konfiguracijski Customers/CustomerItemGroupDiscounts landing z replayem ter konfigurirani CUSTOMERS, PRODUCTS in SHIPPING CSV izvozi. Slovenski intranet uporablja prave auditirane procedure in eksplicitne vloge ADMIN, CATALOG_EDITOR ter COMMERCIAL.

Fixture/replay dokazuje parser in preslikavo; resnični SAOP GET ni bil izveden ali zatrjevan. Migrator prepozna 020 in varno zavrne zagon brez skrivnosti, vendar migracija 020, ponovni zagon in `--verify` na MSSQL PIM niso bili izvedeni, ker `PIM_CONNECTION_STRING` ni prisoten. `PIM_test` ni bil dostopan. F7 se ustavi pred F8 write-backom.
