/*
  051 — koncni presledki v glavah Magento predloge se res odrezejo.

  Migracija 050 jih je hotela odrezati, a jih ni: pogoj je bil zapisan kot
  OutputColumnName <> RTRIM(OutputColumnName), MS SQL pa pri primerjavi nizov
  koncne presledke prezre (ANSI dopolnjevanje). Pogoj je bil zato vedno neresnicen
  in UPDATE ni zajel nobene vrstice. Iz istega razloga tega ni ujela niti preverba
  na koncu 050 — tudi ta je primerjala z <>.

  Razliko vidi samo dolzina: LEN() koncne presledke prezre, DATALENGTH() ne.

  Kaj se popravi: devetnajst glav ('Enota dolzine ', 'Nastavitev visine ' ...) in
  njihove kanonicne kode. Razlog ostaja isti kot v 050 — uvoz v Magento povezuje
  stolpce po imenu glave, koncni presledek pa je razlika, ki se je ne vidi.
*/

SET XACT_ABORT ON;

DECLARE @ProductProfileId int =
  (SELECT ExportProfileId FROM out.ExportProfile WHERE ProfileCode = N'MAGENTO_PRODUCTS');

IF @ProductProfileId IS NULL
  THROW 52370, 'Profil MAGENTO_PRODUCTS ne obstaja; najprej mora tece migracija 045.', 1;

UPDATE out.ExportColumn
SET OutputColumnName = RTRIM(LTRIM(OutputColumnName)),
    CanonicalFieldCode = RTRIM(LTRIM(CanonicalFieldCode))
WHERE ExportProfileId = @ProductProfileId
  AND
  (
    DATALENGTH(OutputColumnName) / 2 <> LEN(LTRIM(OutputColumnName))
    OR DATALENGTH(CanonicalFieldCode) / 2 <> LEN(LTRIM(CanonicalFieldCode))
  );

IF EXISTS
(
  SELECT 1 FROM out.ExportColumn
  WHERE ExportProfileId = @ProductProfileId
    AND DATALENGTH(OutputColumnName) / 2 <> LEN(LTRIM(OutputColumnName))
)
  THROW 52371, 'Glava Magento predloge ima se vedno presledek na robu.', 1;

IF EXISTS
(
  SELECT 1 FROM out.ExportColumn
  WHERE ExportProfileId = @ProductProfileId
    AND DATALENGTH(CanonicalFieldCode) / 2 <> LEN(LTRIM(CanonicalFieldCode))
)
  THROW 52372, 'Kanonicna koda stolpca ima se vedno presledek na robu.', 1;
