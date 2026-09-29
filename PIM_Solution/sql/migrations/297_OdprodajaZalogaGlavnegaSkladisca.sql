/*
  297 — odprodaja: primerjava z zalogo v glavnem skladišču (IQ: Brnčičeva, 0000001).

  Uporabnik 2026-09-28: količino odprodaje vpišemo (uvoz ali ročno). Ob vpisu se preveri zaloga artikla:
    - zaloga = vpisana količina  → vsa zaloga je za odprodajo (CELA); velja zaloga iz glavnega skladišča,
      ki jo SAOP ob prodaji sam zmanjša; naročila se odštevajo samo za vsak slučaj;
    - zaloga > vpisana količina  → redna prodaja in nekaj kosov za odprodajo (DEL); velja vpisana količina
      minus naročila kupcev;
    - zaloga < vpisana količina  → napaka (PREMALO): na strani, kartici in v predogledu uvoza jasno opozorilo;
    - zaloge ni v PIM            → NEZNANA.
  Med skladišči se nič ne prestavlja (uporabnik), zato je »zaloga« = lastna zaloga iz out.CatalogStock
  (register out.ExportStockSource, za IQ glavno skladišče).

  Pravilo za katalog.csv (enako v vseh načinih, načini se razlikujejo samo v opozorilu):
    preostanek = vpisano − naročeno (288/289), in če je zaloga sveža (out.CatalogOwnStockFresh + posnetek
    mlajši od 30 min, isto pravilo kot 207), največ toliko, kot je na zalogi. Tako splet nikoli ne ponuja
    kosa, ki ga ni; pri CELA zaloga ujame prodajo v 5 minutah, naročila pa v 2 urah. Stara zaloga
    (SAOP ne odgovarja) ne zniža ničesar — velja vpisano minus naročila; izjema je PREMALO (ob vpisu je bilo
    zaloge manj kot vpisano): tam velja največ zadnja znana zaloga, da splet ne ponuja kosa, ki ga ni.

  Objekti:
    - pim.ClearanceItem: ZalogaObVpisu, ZalogaObVpisuUtc (zaloga in čas posnetka ob vpisu količine);
    - sprožilec pim.TR_ClearanceItem_StetjeOd: zdaj AFTER INSERT, UPDATE; ob vnosu, novi količini ali obnovi
      zapiše še zalogo ob vpisu;
    - pim.ClearanceItemRemaining: nova stolpca Zaloga, ZalogaSveza, ZalogaObVpisu, ZalogaObVpisuUtc, Nacin;
      Kolicina upošteva svežo zalogo;
    - intranet.GetClearanceOverview, intranet.GetClearanceItemsForProduct: novi stolpci.
  Ročni korak: ne. Brez GO. Številke 291–295 je rezervirala druga seja.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

IF UNICODE(N'č') <> 269
  THROW 52970, N'297: datoteka ni prebrana kot UTF-8 (sqlcmd -f 65001 ali Invoke-PendingMigrations.ps1).', 1;
IF OBJECT_ID(N'pim.ClearanceItemRemaining', N'IF') IS NULL THROW 52971, N'297: najprej 288.', 1;
IF OBJECT_ID(N'out.CatalogStock', N'V') IS NULL THROW 52972, N'297: out.CatalogStock manjka (204).', 1;

/* --- 1) zaloga ob vpisu ------------------------------------------------------ */
IF COL_LENGTH(N'pim.ClearanceItem', N'ZalogaObVpisu') IS NULL
  ALTER TABLE pim.ClearanceItem ADD ZalogaObVpisu decimal(19,4) NULL, ZalogaObVpisuUtc datetime2(3) NULL;

EXEC(N'
UPDATE item SET ZalogaObVpisu = stock.OwnAvailable, ZalogaObVpisuUtc = stock.OwnSnapshotUtc
FROM pim.ClearanceItem AS item
INNER JOIN canon.Product AS product ON product.ProductId = item.ProductId
INNER JOIN out.CatalogStock AS stock ON stock.OrganizationId = product.OrganizationId AND stock.ItemID = product.ItemID
WHERE item.ZalogaObVpisuUtc IS NULL AND stock.OwnObserved > 0;');

EXEC(N'
CREATE OR ALTER TRIGGER pim.TR_ClearanceItem_StetjeOd ON pim.ClearanceItem
AFTER INSERT, UPDATE
AS
BEGIN
  /* 288: nova količina ali obnovljena vrstica = štetje prodaje od zdaj. Ponovni uvoz iste količine
     štetja ne ponastavi, zato že prodani kosi ostanejo odšteti.
     297: ob vnosu, novi količini ali obnovi se zapiše še zaloga v glavnem skladišču (primerjava z vpisom). */
  SET NOCOUNT ON;
  IF TRIGGER_NESTLEVEL(@@PROCID) > 1 RETURN;
  DECLARE @Changed TABLE (ClearanceItemId bigint PRIMARY KEY, IsNew bit NOT NULL);
  INSERT @Changed (ClearanceItemId, IsNew)
  SELECT changed.ClearanceItemId, CASE WHEN previous.ClearanceItemId IS NULL THEN 1 ELSE 0 END
  FROM inserted AS changed
  LEFT JOIN deleted AS previous ON previous.ClearanceItemId = changed.ClearanceItemId
  WHERE previous.ClearanceItemId IS NULL
     OR ISNULL(previous.Kolicina, -1) <> ISNULL(changed.Kolicina, -1)
     OR (previous.IsActive = 0 AND changed.IsActive = 1);
  IF NOT EXISTS (SELECT 1 FROM @Changed) RETURN;

  UPDATE item SET
    StetjeOdUtc = CASE WHEN marked.IsNew = 1 THEN item.StetjeOdUtc ELSE SYSUTCDATETIME() END,
    ZalogaObVpisu = stock.OwnAvailable,
    ZalogaObVpisuUtc = stock.OwnSnapshotUtc
  FROM pim.ClearanceItem AS item
  INNER JOIN @Changed AS marked ON marked.ClearanceItemId = item.ClearanceItemId
  INNER JOIN canon.Product AS product ON product.ProductId = item.ProductId
  OUTER APPLY (
    SELECT OwnAvailable = CASE WHEN own.OwnObserved > 0 THEN own.OwnAvailable END,
           OwnSnapshotUtc = CASE WHEN own.OwnObserved > 0 THEN own.OwnSnapshotUtc END
    FROM out.CatalogStock AS own
    WHERE own.OrganizationId = product.OrganizationId AND own.ItemID = product.ItemID
  ) AS stock;
END;');

/* --- 2) preostanek z zalogo -------------------------------------------------- */
EXEC(N'
CREATE OR ALTER FUNCTION pim.ClearanceItemRemaining (@OrganizationId int)
RETURNS TABLE
AS
RETURN
  /* 288/289/297: vrstice odprodaje podjetja.
     Kolicina = preostanek, ki gre v katalog.csv: vpisano − naročeno, pri sveži zalogi največ zaloga.
     Nacin (ob vpisu): CELA = vsa zaloga za odprodajo, DEL = del redne zaloge, PREMALO = zaloge manj kot
     vpisano (napaka), NEZNANA = zaloge ni v PIM. */
  SELECT item.ClearanceItemId, item.ProductId, item.Vir, item.Sifra, item.Ean, item.NaSvetila, item.NaVidelektro,
         Kolicina = CASE
           WHEN item.Kolicina IS NULL THEN NULL
           WHEN (fresh.IsFresh = 1 OR (stock.OwnAvailable IS NOT NULL AND item.ZalogaObVpisu < item.Kolicina))
                AND ISNULL(stock.OwnAvailable, 0) < calc.PoNarocilih
             THEN CASE WHEN ISNULL(stock.OwnAvailable, 0) > 0 THEN stock.OwnAvailable ELSE CONVERT(decimal(19,4), 0) END
           ELSE calc.PoNarocilih END,
         ZacetnaKolicina = item.Kolicina,
         Prodano = ISNULL(sold.Prodano, 0),
         Narocila = sold.Narocila,
         Zaloga = stock.OwnAvailable,
         ZalogaSveza = CONVERT(bit, ISNULL(fresh.IsFresh, 0)),
         item.ZalogaObVpisu, item.ZalogaObVpisuUtc,
         Nacin = CASE
           WHEN item.ZalogaObVpisu IS NULL THEN N''NEZNANA''
           WHEN item.ZalogaObVpisu = item.Kolicina THEN N''CELA''
           WHEN item.ZalogaObVpisu > item.Kolicina THEN N''DEL''
           ELSE N''PREMALO'' END,
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
  ) AS sold
  OUTER APPLY (
    SELECT OwnAvailable = CASE WHEN own.OwnObserved > 0 THEN own.OwnAvailable END, own.OwnSnapshotUtc
    FROM out.CatalogStock AS own
    WHERE own.OrganizationId = product.OrganizationId AND own.ItemID = product.ItemID
  ) AS stock
  CROSS APPLY (
    SELECT IsFresh = CASE WHEN stock.OwnAvailable IS NOT NULL
                            AND stock.OwnSnapshotUtc >= DATEADD(minute, -30, SYSUTCDATETIME())
                            AND out.CatalogOwnStockFresh(product.OrganizationId) = 1 THEN 1 ELSE 0 END
  ) AS fresh
  CROSS APPLY (
    SELECT PoNarocilih = CASE WHEN item.Kolicina - ISNULL(sold.Prodano, 0) > 0
                              THEN CONVERT(decimal(19,4), item.Kolicina - ISNULL(sold.Prodano, 0))
                              ELSE CONVERT(decimal(19,4), 0) END
  ) AS calc;');

/* --- 3) stran Odprodaja in kartica ----------------------------------------------- */
EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetClearanceOverview
  @OrganizationId int,
  @IncludeEnded bit = 0
AS
BEGIN
  /* Pregled za /izdelki/odprodaja. Ena vrstica na vrstico odprodaje; artikel z oznako razstavni
     eksponat brez aktivne odprodaje pride kot vrstica brez ClearanceItemId.
     288: Kolicina = preostanek, ZacetnaKolicina = vpisana, Prodano + Narocila.
     297: Zaloga (glavno skladišče), ZalogaSveza, ZalogaObVpisu, Nacin (CELA/DEL/PREMALO/NEZNANA).
     VKatalogu = artikel gre v katalog.csv z Odprodaja = DA: najnovejša aktivna vrstica, preostanek > 0,
     aktiven artikel z obkljukano spletno stranjo. */
  SET NOCOUNT ON;

  WITH Items AS (
    SELECT item.*,
           ROW_NUMBER() OVER (PARTITION BY item.ProductId, item.IsActive ORDER BY item.ImportiranoUtc DESC) AS Rn
    FROM pim.ClearanceItemRemaining(@OrganizationId) AS item
    WHERE item.IsActive = 1 OR @IncludeEnded = 1
  )
  SELECT items.ClearanceItemId, product.ProductId, product.ItemID, title.Value AS Naziv,
         items.Vir, items.Kolicina, items.ZacetnaKolicina, items.Prodano, items.Narocila,
         items.Zaloga, items.ZalogaSveza, items.ZalogaObVpisu, items.ZalogaObVpisuUtc, items.Nacin,
         items.PopustOdstotek, items.RednaCena, items.OdprodajnaCena,
         CAST(ISNULL(flag.IsSet, 0) AS bit) AS Razstavni,
         shops.Strani AS SpletneStrani,
         CAST(CASE WHEN items.IsActive = 1 AND items.Rn = 1 AND ISNULL(items.Kolicina, 0) > 0
                    AND product.IsActive = 1 AND shops.Strani IS NOT NULL THEN 1 ELSE 0 END AS bit) AS VKatalogu,
         items.ImportiranoUtc, CAST(ISNULL(items.IsActive, 0) AS bit) AS IsActive, items.EndedUtc, items.EndedBy,
         items.IzvornaDatoteka
  FROM canon.Product product
  LEFT JOIN Items items ON items.ProductId = product.ProductId
  LEFT JOIN pim.ProductFlag flag ON flag.ProductId = product.ProductId AND flag.FlagCode = N''RAZSTAVNI_EKSPONAT''
  LEFT JOIN canon.ProductText title ON title.ProductId = product.ProductId AND title.TextType = N''TITLE_ERP'' AND title.Lang = N''sl''
  OUTER APPLY (
    SELECT STRING_AGG(shop.WebShopCode, N''|'') WITHIN GROUP (ORDER BY shop.WebShopCode) AS Strani
    FROM pim.ProductWebShop shop WHERE shop.ProductId = product.ProductId AND shop.IsPublished = 1
  ) shops
  WHERE product.OrganizationId = @OrganizationId
    AND (items.ClearanceItemId IS NOT NULL
         OR (flag.IsSet = 1 AND NOT EXISTS (SELECT 1 FROM pim.ClearanceItem active WHERE active.ProductId = product.ProductId AND active.IsActive = 1)))
  ORDER BY CASE WHEN items.ClearanceItemId IS NULL THEN 1 ELSE 0 END, ISNULL(items.IsActive, 0) DESC, product.ItemID, items.Vir;
END;');

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetClearanceItemsForProduct
  @ProductId bigint
AS
BEGIN
  /* 296/297: Kolicina = preostanek, ZacetnaKolicina = vpisana, zaloga in način ob vpisu. */
  SET NOCOUNT ON;
  DECLARE @OrganizationId int = (SELECT OrganizationId FROM canon.Product WHERE ProductId = @ProductId);
  SELECT ClearanceItemId, Vir, Sifra, Kolicina, ZacetnaKolicina, Prodano, Narocila,
         Zaloga, ZalogaSveza, ZalogaObVpisu, ZalogaObVpisuUtc, Nacin,
         RednaCena, PopustOdstotek, OdprodajnaCena,
         IzvornaDatoteka, ImportiranoUtc, IsActive, EndedUtc, EndedBy
  FROM pim.ClearanceItemRemaining(@OrganizationId)
  WHERE ProductId = @ProductId
  ORDER BY IsActive DESC, ImportiranoUtc DESC;
END;');

/* --- 4) preverjanje ------------------------------------------------------------ */
IF COL_LENGTH(N'pim.ClearanceItem', N'ZalogaObVpisu') IS NULL THROW 52973, N'297: ZalogaObVpisu manjka.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'pim.ClearanceItemRemaining')) NOT LIKE N'%PREMALO%' THROW 52974, N'297: funkcija ni posodobljena.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'pim.TR_ClearanceItem_StetjeOd')) NOT LIKE N'%AFTER INSERT, UPDATE%' THROW 52975, N'297: sprožilec ni posodobljen.', 1;
