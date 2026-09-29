/*
  296 — kartica izdelka (Splet → Odprodaja) kaže preostanek po naročilih kupcev (288/289).

  Do zdaj je intranet.GetClearanceItemsForProduct bral pim.ClearanceItem neposredno, zato je kartica
  kazala vpisano količino, katalog.csv pa preostanek. Zdaj bere pim.ClearanceItemRemaining za podjetje
  izdelka: Kolicina = preostanek (ta gre v katalog.csv), ZacetnaKolicina, Prodano, Narocila.

  Številke 291–295 je rezervirala seja »Izvoz Kataloga in strank za splet« (2026-09-28).
  Objekti: sprememba intranet.GetClearanceItemsForProduct. Ročni korak: ne. Brez GO.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

IF UNICODE(N'č') <> 269
  THROW 52960, N'296: datoteka ni prebrana kot UTF-8 (sqlcmd -f 65001 ali Invoke-PendingMigrations.ps1).', 1;
IF OBJECT_ID(N'pim.ClearanceItemRemaining', N'IF') IS NULL THROW 52961, N'296: najprej 288.', 1;

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetClearanceItemsForProduct
  @ProductId bigint
AS
BEGIN
  /* 296: Kolicina = preostanek po naročilih kupcev (288), ZacetnaKolicina = vpisana. */
  SET NOCOUNT ON;
  DECLARE @OrganizationId int = (SELECT OrganizationId FROM canon.Product WHERE ProductId = @ProductId);
  SELECT ClearanceItemId, Vir, Sifra, Kolicina, ZacetnaKolicina, Prodano, Narocila,
         RednaCena, PopustOdstotek, OdprodajnaCena,
         IzvornaDatoteka, ImportiranoUtc, IsActive, EndedUtc, EndedBy
  FROM pim.ClearanceItemRemaining(@OrganizationId)
  WHERE ProductId = @ProductId
  ORDER BY IsActive DESC, ImportiranoUtc DESC;
END;');

IF OBJECT_DEFINITION(OBJECT_ID(N'intranet.GetClearanceItemsForProduct')) NOT LIKE N'%ClearanceItemRemaining%'
  THROW 52962, N'296: kartica ne bere preostanka.', 1;
