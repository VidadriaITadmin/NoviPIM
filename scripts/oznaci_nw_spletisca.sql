/*
  Masovna oznaka spletisc: vsem AKTIVNIM artiklom s sifro NW.* pri podjetjih 2 in 3 postavi
  kljukici svetila_si in videlektro (pim.ProductWebShop, migracija 182).

  Uporabnik 2026-09-15: »za organizaciji 2 in 3 izberi vsa "NW." artikle in jim vsem oznaci
  svetila in videlektro kljukico.«

  To ni migracija (podatki, ne shema) — pozene se rocno, npr. v SSMS ali:
    sqlcmd -S <streznik> -d PIM -E -C -i scripts\oznaci_nw_spletisca.sql

  Kaj naredi:
    1. MERGE v pim.ProductWebShop: manjkajoca vrstica nastane, ugasnjena se prizge, prizgana ostane.
    2. Vsaka sprememba pusti sled v pim.ProductFieldHistory (isti zapis kot pim.SaveProductWebShops
       s kartice), da je vidno, kdo in kdaj je artikel dal na splet.
    3. Ponovna validacija podjetij 2 in 3 (val.RunValidation), da spletna profila zajameta nove
       artikle. Traja nekaj minut (podjetje 2 ~8 min). Objavo in izvoz naredi naslednji urni
       cikel (Katalog-cikel.ps1) ali rocni zagon workerja.

  Neaktivni artikli se namenoma ne oznacijo: izvoz jih ne bi vzel (201), profil pa bi jim odpiral
  napake. Ponovni zagon je varen — ze oznaceni artikli se ne dotaknejo in ne dobijo nove sledi.
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Actor nvarchar(200) = N'masovna oznaka NW ' + CONVERT(nvarchar(19), SYSUTCDATETIME(), 120);
DECLARE @Changed TABLE (ProductId bigint NOT NULL, WebShopCode nvarchar(100) NOT NULL, OldValue nvarchar(10) NOT NULL, NewValue nvarchar(10) NOT NULL);

BEGIN TRANSACTION;

MERGE pim.ProductWebShop AS target
USING
(
  SELECT product.ProductId, shop.WebShopCode
  FROM canon.Product AS product
  CROSS JOIN (VALUES (N'svetila_si'), (N'videlektro')) AS shop (WebShopCode)
  WHERE product.OrganizationId IN (2, 3)
    AND product.IsActive = 1
    AND product.ItemID LIKE N'NW.%'
) AS source
  ON target.ProductId = source.ProductId AND target.WebShopCode = source.WebShopCode
WHEN MATCHED AND target.IsPublished = 0 THEN
  UPDATE SET IsPublished = 1, ChangedBy = @Actor, ChangedUtc = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN
  INSERT (ProductId, WebShopCode, IsPublished, ChangedBy) VALUES (source.ProductId, source.WebShopCode, 1, @Actor)
OUTPUT inserted.ProductId, inserted.WebShopCode,
       CASE WHEN deleted.IsPublished IS NULL THEN N'ne' WHEN deleted.IsPublished = 1 THEN N'da' ELSE N'ne' END,
       N'da'
INTO @Changed (ProductId, WebShopCode, OldValue, NewValue);

/* Sled: en paket na podjetje, ena vrstica zgodovine na (artikel, spletisce). */
DECLARE @OrganizationId int, @BatchId bigint;
DECLARE organizations CURSOR LOCAL FAST_FORWARD FOR
  SELECT DISTINCT product.OrganizationId FROM @Changed AS changed
  INNER JOIN canon.Product AS product ON product.ProductId = changed.ProductId;
OPEN organizations;
FETCH NEXT FROM organizations INTO @OrganizationId;
WHILE @@FETCH_STATUS = 0
BEGIN
  INSERT pim.ProductChangeBatch (BatchId, ChangeSource, ChangedBy, OrganizationId, Note)
  VALUES (NEWID(), N'BULK', @Actor, @OrganizationId, N'Masovna oznaka svetila_si + videlektro za aktivne NW.* artikle');
  SET @BatchId = SCOPE_IDENTITY();

  INSERT pim.ProductFieldHistory (ChangeBatchId, OrganizationId, ProductId, ItemID, FieldKey, CanonTable, CanonColumn, Owner, OldValue, NewValue)
  SELECT @BatchId, product.OrganizationId, product.ProductId, product.ItemID,
         CONCAT(N'ProductWebShop.', changed.WebShopCode), N'pim.ProductWebShop', N'IsPublished', N'PIM',
         changed.OldValue, changed.NewValue
  FROM @Changed AS changed
  INNER JOIN canon.Product AS product ON product.ProductId = changed.ProductId
  WHERE product.OrganizationId = @OrganizationId;

  FETCH NEXT FROM organizations INTO @OrganizationId;
END;
CLOSE organizations;
DEALLOCATE organizations;

COMMIT TRANSACTION;

SELECT product.OrganizationId, changed.WebShopCode, COUNT(*) AS NaNovoOznacenih
FROM @Changed AS changed
INNER JOIN canon.Product AS product ON product.ProductId = changed.ProductId
GROUP BY product.OrganizationId, changed.WebShopCode
ORDER BY product.OrganizationId, changed.WebShopCode;

/* Ponovna validacija — brez tega spletna profila novih artiklov ne vidita do naslednjega cikla. */
EXEC val.RunValidation @OrganizationId = 2;
EXEC val.RunValidation @OrganizationId = 3;
