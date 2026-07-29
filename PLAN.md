# PLAN — izvedene in naslednje faze PIM sistema

## F0 — temelji

Status: zaključeno in verzionirano v commitu `ce7feac`.

Vzpostavljeni so rešitev .NET 8, migrator, `dbo.SchemaMigration`, sheme, `ops.*`, `dbo.OrganizationConfig`, varna okoljska konfiguracija, testni skelet in dokaz dvakratnega zagona migracij proti razvojni bazi `PIM`.

## F1 — izhodni kontrakt: definicija »poln«

Status: zaključeno; čaka na ločen commit F1.

### Meja izvedbe
Izvedena bo izključno F1 iz avtoritativne specifikacije. Ne začne se F2 ali katera koli kasnejša faza. Ni zajema virov, kanoničnih tabel, poslovne validacije, promocije v katalog ali CSV datoteke.

### Koraki

1. Napisati test, ki zahteva dva izvozna profila in preverja, da je vsak zahtevek validacije ustvarjen iz izvoznega stolpca, ne iz samostojnega ročnega seznama.

2. Dodati novo oštevilčeno MSSQL migracijo za:
   - `out.ExportProfile` in `out.ExportColumn`;
   - `val.ValidationProfile` in `val.FieldRequirement`;
   - integritetne omejitve, aktivnost, vrstni red in enoličnost;
   - sledljive povezave med izvoznim stolpcem in generiranim validacijskim zahtevkom.

3. V register zapisati minimalni izhodni kontrakt:
   - PRODUCTS CSV za B2C / svetila.si;
   - obvezne ERP L1 in WEB_B2C zahteve iz DEL 5;
   - obvezne B2C stolpce: slovenski spletni naziv, EAN, kategorije, slika, B2C cena z DDV, proizvajalec in ključni atributi.

4. Dodati idempotentno proceduro, ki izključno iz aktivnih izvoznih stolpcev generira oziroma uskladi `val.FieldRequirement`. Ne sme imeti zabetoniranega seznama poslovnih polj.

5. Razširiti migratorjevo preverjanje in SQL-test, da dokazujeta profile, stolpce, generirane zahteve in ponovni zagon brez podvojitev.

6. Preveriti F1 na razvojni bazi `PIM`:
   - prvi zagon nove migracije;
   - drugi zagon brez podvojitev;
   - `--verify` in ciljni SQL-test;
   - build, kontraktni testi, `npm test`, lint, pregled skrivnosti in `git diff --check`.

7. Posodobiti `TEST_REPORT.md` in `PROGRESS.md`, pregledati spremembe, ustvariti ločen commit F1 v slovenščini ter se ustaviti pred F2.

### Merila uspeha F1

- Iz šifranta je razvidno, kaj pomeni »poln« izdelek za B2C.
- ERP L1 in WEB_B2C zahteve izhajajo iz izvoznega profila; ne obstaja ločeno ročno vzdrževan seznam.
- Ponovni zagon je idempotenten in dokazljiv na MSSQL.
- Nobena skrivnost ni v repoju in `PIM_test` ostane nespremenjen.
