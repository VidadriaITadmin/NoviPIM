/*
  289 — odprodaja (288): naročilo šteje samo, če ga je PIM prvič videl po začetku štetja.

  Preizkus 288 na DEV 2026-09-28: SAOP pri naročilu kupca pove samo dan (OrderDate). Če komerciala isti dan,
  ko je bil kos prodan, popravi količino (npr. iz 3 na 2, ker ve za prodajo), se je današnje naročilo
  odštelo še enkrat — ostala bi 1 namesto 2. Primerjava po dnevu tega ne loči.

  sales.OrderHeader dobi PrvicVidenoUtc: kdaj je PIM naročilo prvič zapisal (privzeta vrednost, MERGE v
  map.ProcessSalesOrderInbox stolpca ne navaja, zato ga posodobitev ne spremeni). Naročilo šteje, če:
    - je njegov dan na dan začetka štetja ali pozneje (zajem zgodovine starih naročil ne šteje) IN
    - ga je PIM prvič videl po začetku štetja (naročilo, ki je bilo znano ob popravku količine, je že
      upoštevano v novi količini).
  Naročilo, ki nastane pred uvozom seznama, a ga delavec (na 2 uri) zapiše šele po uvozu, šteje — seznam
  je bil pripravljen brez njega.
  Obstoječa naročila dobijo PrvicVidenoUtc = UpdatedUtc (najboljši znani približek).

  Objekti: sales.OrderHeader.PrvicVidenoUtc (nov stolpec), pim.ClearanceItemRemaining (sprememba pogoja).
  Ročni korak: ne. Brez GO.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

IF UNICODE(N'č') <> 269
  THROW 52890, N'289: datoteka ni prebrana kot UTF-8 (sqlcmd -f 65001 ali Invoke-PendingMigrations.ps1).', 1;
IF OBJECT_ID(N'pim.ClearanceItemRemaining', N'IF') IS NULL THROW 52891, N'289: najprej 288.', 1;

IF COL_LENGTH(N'sales.OrderHeader', N'PrvicVidenoUtc') IS NULL
BEGIN
  ALTER TABLE sales.OrderHeader ADD PrvicVidenoUtc datetime2(3) NULL
    CONSTRAINT DF_SalesOrderHeader_PrvicVidenoUtc DEFAULT (SYSUTCDATETIME());
  EXEC(N'UPDATE sales.OrderHeader SET PrvicVidenoUtc = ISNULL(UpdatedUtc, SYSUTCDATETIME()) WHERE PrvicVidenoUtc IS NULL;');
END;

EXEC(N'
CREATE OR ALTER FUNCTION pim.ClearanceItemRemaining (@OrganizationId int)
RETURNS TABLE
AS
RETURN
  /* 288/289: vrstice odprodaje podjetja; Kolicina = preostanek (nikoli pod 0), ZacetnaKolicina = vpisana. */
  SELECT item.ClearanceItemId, item.ProductId, item.Vir, item.Sifra, item.Ean, item.NaSvetila, item.NaVidelektro,
         Kolicina = CASE WHEN item.Kolicina IS NULL THEN NULL
                         WHEN item.Kolicina - ISNULL(sold.Prodano, 0) > 0 THEN item.Kolicina - ISNULL(sold.Prodano, 0)
                         ELSE CONVERT(decimal(10,2), 0) END,
         ZacetnaKolicina = item.Kolicina,
         Prodano = ISNULL(sold.Prodano, 0),
         Narocila = sold.Narocila,
         item.RednaCena, item.PopustOdstotek, item.OdprodajnaCena, item.IzvornaDatoteka, item.ImportiranoUtc,
         item.IsActive, item.EndedUtc, item.EndedBy, item.StetjeOdUtc
  FROM pim.ClearanceItem AS item
  INNER JOIN canon.Product AS product ON product.ProductId = item.ProductId AND product.OrganizationId = @OrganizationId
  OUTER APPLY (
    SELECT Prodano = SUM(line.Kos),
           Narocila = STRING_AGG(CONVERT(nvarchar(max), CONCAT(line.OrderYear, N''/'', line.OrderBook, N''/'', line.OrderNumber,
                        N'' ('', CONVERT(nvarchar(30), CONVERT(decimal(19,2), line.Kos)), N'')'')), N'', '')
                      WITHIN GROUP (ORDER BY line.OrderDate, line.OrderNumber)
    FROM (
      SELECT header.OrderYear, header.OrderBook, header.OrderNumber, header.OrderDate,
             Kos = CASE WHEN orderLine.ClosedLine = 1 THEN ISNULL(orderLine.ShippedQTY, 0) ELSE ISNULL(orderLine.Qty, 0) END
      FROM sales.OrderLine AS orderLine
      INNER JOIN sales.OrderHeader AS header ON header.OrderHeaderId = orderLine.OrderHeaderId
      WHERE orderLine.ItemID = product.ItemID
        AND header.OrganizationId = product.OrganizationId
        AND header.OrderDate IS NOT NULL
        AND CONVERT(date, header.OrderDate) >= CONVERT(date, item.StetjeOdUtc AT TIME ZONE ''UTC'' AT TIME ZONE ''Central European Standard Time'')
        AND header.PrvicVidenoUtc >= item.StetjeOdUtc
        AND ISNULL(header.OrderStatus, N'''') NOT IN (N''Stornirano'', N''Preklicano'')
        AND ISNULL(orderLine.Status, N'''') NOT IN (N''Stornirano'', N''Preklicano'')
    ) AS line
    WHERE line.Kos > 0
  ) AS sold;');

IF COL_LENGTH(N'sales.OrderHeader', N'PrvicVidenoUtc') IS NULL THROW 52892, N'289: PrvicVidenoUtc manjka.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'pim.ClearanceItemRemaining')) NOT LIKE N'%PrvicVidenoUtc%'
  THROW 52893, N'289: pim.ClearanceItemRemaining ne upošteva PrvicVidenoUtc.', 1;
