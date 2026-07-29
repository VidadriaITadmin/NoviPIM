# PLAN — izvedene in naslednje faze PIM sistema

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
