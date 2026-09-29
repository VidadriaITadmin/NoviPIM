/*
  271 — popravi pokvarjene sumnike v glavah izvoznih stolpcev (out.ExportColumn.OutputColumnName).

  Na strezniku je katalog.csv imel glavi "Pakirna koliÄŤina" (217) in "Odprodaja - koliÄŤina" (234),
  ostale glave s "količina" pa so bile pravilne. Vzrok: 217 in 234 sta tekli skozi sqlcmd brez
  -f 65001, zato je sqlcmd UTF-8 datoteko bral v kodni tabeli Windows-1250 in "č" (bajta C4 8D)
  zapisal kot "Ä" + "Ť". Invoke-PendingMigrations.ps1 ima -f 65001 danes vgrajen; ta migracija
  popravi, kar je ze v bazi. Na bazi, kjer ni pokvarjenega, ne spremeni nicesar.

  V ukazih so znaki zapisani z NCHAR (sumniki so samo v tem komentarju), zato popravka ne more
  pokvariti ista napaka, ce bi datoteka spet tekla brez -f 65001.
  Zaporedje UTF-8 bajtov, prebranih kot Windows-1250 -> pravi znak:
    C4 8D  U+00C4 U+0164  -> č      C4 8C  U+00C4 U+015A  -> Č
    C5 A1  U+0139 U+02C7  -> š      C5 A0  U+0139 U+00A0  -> Š
    C5 BE  U+0139 U+013E  -> ž      C5 BD  U+0139 U+02DD  -> Ž
    C4 87  U+00C4 U+2021  -> ć      C4 86  U+00C4 U+2020  -> Ć
    C4 91  U+00C4 U+2018  -> đ
  Ročni korak: ne.
*/

SET XACT_ABORT ON;
BEGIN TRANSACTION;

UPDATE out.ExportColumn
SET OutputColumnName =
  REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(OutputColumnName COLLATE Latin1_General_BIN2,
    NCHAR(0x00C4) + NCHAR(0x0164), NCHAR(0x010D)),
    NCHAR(0x00C4) + NCHAR(0x015A), NCHAR(0x010C)),
    NCHAR(0x0139) + NCHAR(0x02C7), NCHAR(0x0161)),
    NCHAR(0x0139) + NCHAR(0x00A0), NCHAR(0x0160)),
    NCHAR(0x0139) + NCHAR(0x013E), NCHAR(0x017E)),
    NCHAR(0x0139) + NCHAR(0x02DD), NCHAR(0x017D)),
    NCHAR(0x00C4) + NCHAR(0x2021), NCHAR(0x0107)),
    NCHAR(0x00C4) + NCHAR(0x2020), NCHAR(0x0106)),
    NCHAR(0x00C4) + NCHAR(0x2018), NCHAR(0x0111))
WHERE OutputColumnName COLLATE Latin1_General_BIN2 LIKE N'%' + NCHAR(0x00C4) + N'%'
   OR OutputColumnName COLLATE Latin1_General_BIN2 LIKE N'%' + NCHAR(0x0139) + N'%';

-- Po popravku ne sme ostati noben znak, ki se v slovenskih glavah ne pojavi, v UTF-8 zmesi pa vedno.
IF EXISTS (SELECT 1 FROM out.ExportColumn
           WHERE OutputColumnName COLLATE Latin1_General_BIN2 LIKE N'%' + NCHAR(0x00C4) + N'%'
              OR OutputColumnName COLLATE Latin1_General_BIN2 LIKE N'%' + NCHAR(0x0139) + N'%')
  THROW 52710, N'271: v out.ExportColumn.OutputColumnName so se ostali pokvarjeni znaki.', 1;

COMMIT TRANSACTION;
