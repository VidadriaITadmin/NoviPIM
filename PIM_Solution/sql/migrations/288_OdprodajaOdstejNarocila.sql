/*
  288 — odprodaja: naročila kupcev iz SAOP zmanjšajo količino v odprodaji.

  Uporabnik 2026-09-28: na strani Odprodaja se nastavi samo, kateri artikli so v odprodaji in koliko jih
  je; katalog.csv pošlje odprodajo, popust % in količino; naročila kupcev pa količino sproti zmanjšujejo.
  Odločitve:
    - štejejo VSA naročila kupcev iz SAOP (VNK, sales.OrderLine iz PIM.SaopOrdersWorker), ne glede na
      kanal (splet, trgovina, B2B) — kos je en, kdorkoli ga kupi;
    - odšteje se ob naročilu (naročena količina); stornirano/preklicano naročilo ne šteje, zaprta vrstica
      šteje samo odpremljeno količino (preklican ostanek se vrne);
    - pri 0 gre v katalog.csv Odprodaja = NE in količina 0 (Magento artikla s količino 0 tako ali tako
      ne pokaže v odprodaji); vrstica ostane na strani kot »razprodano«.

  Nič se ne odšteva v tabeli — preostanek se izračuna: Kolicina − prodano od StetjeOdUtc. Tako ponovni
  zajem istega naročila ali ponovni uvoz iste datoteke ne odšteje dvakrat. StetjeOdUtc se postavi ob
  vnosu vrstice, ob spremembi količine (nova količina = nova zaloga, štetje od takrat) in ob obnovi
  zaključene vrstice (sprožilec, ker v vrstico pišejo trije postopki: uvoz, ročni vnos, obnova).
  Naročilo se šteje, če je njegov datum na dan začetka štetja ali pozneje (datum naročila v SAOP je dan;
  naročilo z istega dne pred uvozom se šteje — raje en kos manj na spletu kot prodan dvakrat).
  Naročila istega podjetja kot artikel (canon.Product.OrganizationId = sales.OrderHeader.OrganizationId).

  Objekti:
    - pim.ClearanceItem: nov stolpec StetjeOdUtc (obstoječe vrstice = ImportiranoUtc);
    - sprožilec pim.TR_ClearanceItem_StetjeOd;
    - nova funkcija pim.ClearanceItemRemaining (preostanek, prodano, naročila);
    - out.GetExportRows: blok /* OdprodajaExport234 */ bere preostanek namesto začetne količine;
    - intranet.GetClearanceOverview: ZacetnaKolicina, Prodano, Narocila; VKatalogu upošteva preostanek,
      obkljukano spletno stran in aktiven artikel (prej je kazal DA tudi za artikle, ki niso na spletu).
  Ročni korak: ne. Brez GO (Migrator ga ne pozna).
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

IF UNICODE(N'č') <> 269
  THROW 52880, N'288: datoteka ni prebrana kot UTF-8 (sqlcmd -f 65001 ali Invoke-PendingMigrations.ps1).', 1;
IF OBJECT_ID(N'pim.ClearanceItem', N'U') IS NULL THROW 52881, N'288: pim.ClearanceItem manjka.', 1;
IF OBJECT_ID(N'sales.OrderLine', N'U') IS NULL THROW 52882, N'288: sales.OrderLine manjka (199).', 1;

/* --- 1) začetek štetja prodaje ------------------------------------------------ */
IF COL_LENGTH(N'pim.ClearanceItem', N'StetjeOdUtc') IS NULL
  ALTER TABLE pim.ClearanceItem ADD StetjeOdUtc datetime2(3) NULL
    CONSTRAINT DF_ClearanceItem_StetjeOdUtc DEFAULT (SYSUTCDATETIME());

EXEC(N'UPDATE pim.ClearanceItem SET StetjeOdUtc = ImportiranoUtc WHERE StetjeOdUtc IS NULL;');

EXEC(N'
CREATE OR ALTER TRIGGER pim.TR_ClearanceItem_StetjeOd ON pim.ClearanceItem
AFTER UPDATE
AS
BEGIN
  /* 288: nova količina ali obnovljena vrstica = štetje prodaje od zdaj. Ponovni uvoz iste količine
     štetja ne ponastavi, zato že prodani kosi ostanejo odšteti. */
  SET NOCOUNT ON;
  IF TRIGGER_NESTLEVEL(@@PROCID) > 1 RETURN;
  UPDATE item SET StetjeOdUtc = SYSUTCDATETIME()
  FROM pim.ClearanceItem AS item
  INNER JOIN inserted AS changed ON changed.ClearanceItemId = item.ClearanceItemId
  INNER JOIN deleted AS previous ON previous.ClearanceItemId = changed.ClearanceItemId
  WHERE ISNULL(previous.Kolicina, -1) <> ISNULL(changed.Kolicina, -1)
     OR (previous.IsActive = 0 AND changed.IsActive = 1);
END;');

/* --- 2) preostanek po naročilih ------------------------------------------------ */
EXEC(N'
CREATE OR ALTER FUNCTION pim.ClearanceItemRemaining (@OrganizationId int)
RETURNS TABLE
AS
RETURN
  /* 288: vrstice odprodaje podjetja; Kolicina = preostanek (nikoli pod 0), ZacetnaKolicina = vpisana. */
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
        AND ISNULL(header.OrderStatus, N'''') NOT IN (N''Stornirano'', N''Preklicano'')
        AND ISNULL(orderLine.Status, N'''') NOT IN (N''Stornirano'', N''Preklicano'')
    ) AS line
    WHERE line.Kos > 0
  ) AS sold;');

/* --- 3) katalog.csv: preostanek namesto začetne količine ------------------------ */
DECLARE @Definition nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows'));
IF @Definition IS NULL THROW 52883, N'288: out.GetExportRows manjka.', 1;
IF @Definition NOT LIKE N'%/* 288 */%'
BEGIN
  DECLARE @Old nvarchar(200) = N'FROM pim.ClearanceItem WHERE IsActive=1';
  IF @Definition NOT LIKE N'%OdprodajaExport234%' OR (LEN(@Definition) - LEN(REPLACE(@Definition, @Old, N''))) / LEN(@Old) <> 1
    THROW 52884, N'288: v out.GetExportRows ni natanko enega bloka odprodaje iz 234.', 1;
  SET @Definition = REPLACE(@Definition, @Old,
    N'FROM pim.ClearanceItemRemaining(@OrganizationId) WHERE IsActive=1 /* 288 */');
  SET @Definition = N'ALTER ' + SUBSTRING(@Definition, CHARINDEX(N'PROCEDURE', @Definition), 2147483647);
  EXEC sys.sp_executesql @Definition;
END;

/* --- 4) stran Odprodaja ------------------------------------------------------ */
EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetClearanceOverview
  @OrganizationId int,
  @IncludeEnded bit = 0
AS
BEGIN
  /* Pregled za /izdelki/odprodaja. Ena vrstica na vrstico odprodaje; artikel z oznako razstavni
     eksponat brez aktivne odprodaje pride kot vrstica brez ClearanceItemId.
     288: Kolicina = preostanek po naročilih kupcev, ZacetnaKolicina = vpisana, Prodano + Narocila.
     VKatalogu = artikel gre v katalog.csv z Odprodaja = DA: najnovejša aktivna vrstica, preostanek > 0,
     aktiven artikel z obkljukano spletno stranjo (isto kot izvoz 234/288). */
  SET NOCOUNT ON;

  WITH Items AS (
    SELECT item.*,
           ROW_NUMBER() OVER (PARTITION BY item.ProductId, item.IsActive ORDER BY item.ImportiranoUtc DESC) AS Rn
    FROM pim.ClearanceItemRemaining(@OrganizationId) AS item
    WHERE item.IsActive = 1 OR @IncludeEnded = 1
  )
  SELECT items.ClearanceItemId, product.ProductId, product.ItemID, title.Value AS Naziv,
         items.Vir, items.Kolicina, items.ZacetnaKolicina, items.Prodano, items.Narocila,
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

/* --- 5) preverjanje ------------------------------------------------------------ */
IF COL_LENGTH(N'pim.ClearanceItem', N'StetjeOdUtc') IS NULL THROW 52885, N'288: StetjeOdUtc manjka.', 1;
IF OBJECT_ID(N'pim.TR_ClearanceItem_StetjeOd', N'TR') IS NULL THROW 52886, N'288: sprožilec manjka.', 1;
IF OBJECT_ID(N'pim.ClearanceItemRemaining', N'IF') IS NULL THROW 52887, N'288: pim.ClearanceItemRemaining manjka.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows')) NOT LIKE N'%ClearanceItemRemaining(@OrganizationId)%'
  THROW 52888, N'288: izvoz ne bere preostanka odprodaje.', 1;
