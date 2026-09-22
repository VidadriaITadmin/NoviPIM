-- 154: pim.ClearanceItem je uporabljal decimal(19,4) po vzoru canon.ProductPrice/stock.Position,
-- a za ceno (EUR) in kolicino (kos) 4 decimalke nimajo pomena - poenoti na decimal(10,2).
-- Obstojece vrednosti imajo najvec 2 decimalki (izvor: rocno prestete kolicine in cene v EUR),
-- zato zozanje natancnosti ne izgubi podatkov, samo pobrise odvecne binarne artefakte (npr. 34.50000000000001).

ALTER TABLE pim.ClearanceItem ALTER COLUMN Kolicina decimal(10,2) NULL;
ALTER TABLE pim.ClearanceItem ALTER COLUMN RednaCena decimal(10,2) NULL;
ALTER TABLE pim.ClearanceItem ALTER COLUMN OdprodajnaCena decimal(10,2) NULL;

IF NOT EXISTS (
  SELECT 1 FROM sys.columns c
  JOIN sys.types t ON t.user_type_id = c.user_type_id
  WHERE c.object_id = OBJECT_ID(N'pim.ClearanceItem') AND c.name = N'RednaCena'
    AND c.precision = 10 AND c.scale = 2
)
  THROW 51510, N'154: pim.ClearanceItem.RednaCena ni decimal(10,2).', 1;
IF NOT EXISTS (
  SELECT 1 FROM sys.columns c
  WHERE c.object_id = OBJECT_ID(N'pim.ClearanceItem') AND c.name = N'Kolicina'
    AND c.precision = 10 AND c.scale = 2
)
  THROW 51511, N'154: pim.ClearanceItem.Kolicina ni decimal(10,2).', 1;
