/*
  214 — S-popust na polno pakiranje na kartici izdelka.

  Uporabnik 2026-09-15: »na artiklu kartica manjka polje S popustov, tako kot smo imeli prej«
  (PIM_test, migracija 0108_Faza1_SPopust_In_Enote_V_Projekciji). Pravilo iz dokumenta
  Magento_Pravila_Cene_Popusti_Postnine §4.4: izdelek nosi PAK2 (kolicina v polnem pakiranju)
  in S kodo z odstotkom (S1 = 3 %, S2 = 5 %, S3 = 10 %, S4 = 15 %); stranka z zastavico
  »Popust polno pakiranje« pri kolicini >= PAK2 dobi ceno x (1 - S %).

  Shema je od migracije 020 (pim.PackagingDiscountCatalog, pim.ProductPackagingDiscount) in
  izvoz za Magento jo ze bere (142/146: stolpca »S popust %« in »Posebni popust za stranko«),
  vpisati pa je ni bilo kje: tabela je bila prazna. Ta migracija doda:
    1) intranet.GetProductPackagingDiscount — trenutna koda, odstotek, PAK2 in sifrant za kartico,
    2) pim.SaveProductPackagingDiscount — zapis z zgodovino (pim.ProductFieldHistory).

  pim.ProductPackagingDiscount je kljucena na pim.Product (promoviran izdelek), ne na
  canon.Product; izdelek, ki se ni promoviran, S kode ne more dobiti in kartica to pove.
*/

SET XACT_ABORT ON;

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetProductPackagingDiscount
  @ProductId bigint
AS
BEGIN
  SET NOCOUNT ON;

  /* 1) Stanje izdelka. */
  SELECT
    IsPromoted = CONVERT(bit, CASE WHEN promoted.PimProductId IS NULL THEN 0 ELSE 1 END),
    DiscountCode = packaging.DiscountCode,
    PercentValue = catalog.PercentValue,
    Pak2 = commercial.Pak2,
    UpdatedUtc = packaging.UpdatedUtc
  FROM canon.Product AS product
  LEFT JOIN pim.Product AS promoted
    ON promoted.OrganizationId = product.OrganizationId AND promoted.ItemID = product.ItemID
  LEFT JOIN pim.ProductPackagingDiscount AS packaging ON packaging.PimProductId = promoted.PimProductId
  LEFT JOIN pim.PackagingDiscountCatalog AS catalog ON catalog.DiscountCode = packaging.DiscountCode
  LEFT JOIN pim.ProductCommercial AS commercial ON commercial.PimProductId = promoted.PimProductId
  WHERE product.ProductId = @ProductId;

  /* 2) Sifrant kod. */
  SELECT DiscountCode, PercentValue
  FROM pim.PackagingDiscountCatalog
  WHERE IsActive = 1
  ORDER BY PercentValue, DiscountCode;
END;');

EXEC(N'CREATE OR ALTER PROCEDURE pim.SaveProductPackagingDiscount
  @OrganizationId int,
  @ProductId bigint,
  @DiscountCode nvarchar(10) = NULL,
  @Actor nvarchar(200),
  @Note nvarchar(400) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  SET @DiscountCode = NULLIF(UPPER(LTRIM(RTRIM(@DiscountCode))), N'''');

  DECLARE @ItemID nvarchar(50) = (SELECT ItemID FROM canon.Product WHERE ProductId = @ProductId AND OrganizationId = @OrganizationId);
  IF @ItemID IS NULL THROW 52401, N''Izdelek ne pripada temu podjetju.'', 1;

  DECLARE @PimProductId bigint = (SELECT PimProductId FROM pim.Product WHERE OrganizationId = @OrganizationId AND ItemID = @ItemID);
  IF @PimProductId IS NULL THROW 52411, N''Izdelek se ni promoviran; S koda se dodeli sele objavljenemu izdelku.'', 1;

  IF @DiscountCode IS NOT NULL AND NOT EXISTS (SELECT 1 FROM pim.PackagingDiscountCatalog WHERE DiscountCode = @DiscountCode AND IsActive = 1)
    THROW 52412, N''Neznana ali neaktivna S koda.'', 1;

  DECLARE @Old nvarchar(10) = (SELECT DiscountCode FROM pim.ProductPackagingDiscount WHERE PimProductId = @PimProductId);
  IF EXISTS (SELECT 1 WHERE ISNULL(@Old, N'''') = ISNULL(@DiscountCode, N''''))
  BEGIN
    SELECT Changed = CONVERT(bit, 0), DiscountCode = @DiscountCode;
    RETURN;
  END;

  BEGIN TRANSACTION;
  BEGIN TRY
    IF @DiscountCode IS NULL
      DELETE pim.ProductPackagingDiscount WHERE PimProductId = @PimProductId;
    ELSE IF @Old IS NULL
      INSERT pim.ProductPackagingDiscount (PimProductId, DiscountCode) VALUES (@PimProductId, @DiscountCode);
    ELSE
      UPDATE pim.ProductPackagingDiscount SET DiscountCode = @DiscountCode, UpdatedUtc = SYSUTCDATETIME() WHERE PimProductId = @PimProductId;

    INSERT pim.ProductChangeBatch (BatchId, ChangeSource, ChangedBy, OrganizationId, Note)
    VALUES (NEWID(), N''CARD'', @Actor, @OrganizationId, @Note);
    DECLARE @BatchId bigint = SCOPE_IDENTITY();

    INSERT pim.ProductFieldHistory (ChangeBatchId, OrganizationId, ProductId, ItemID, FieldKey, CanonTable, CanonColumn, Owner, OldValue, NewValue)
    VALUES (@BatchId, @OrganizationId, @ProductId, @ItemID,
            N''Product.PackagingDiscountCode'', N''pim.ProductPackagingDiscount'', N''DiscountCode'', N''PIM'',
            @Old, @DiscountCode);

    COMMIT;
  END TRY
  BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    THROW;
  END CATCH;

  SELECT Changed = CONVERT(bit, 1), DiscountCode = @DiscountCode;
END;');

/* --- Preverbe ---------------------------------------------------------------------------- */

IF OBJECT_ID(N'intranet.GetProductPackagingDiscount', N'P') IS NULL
  THROW 53020, 'intranet.GetProductPackagingDiscount ni nastala.', 1;
IF OBJECT_ID(N'pim.SaveProductPackagingDiscount', N'P') IS NULL
  THROW 53021, 'pim.SaveProductPackagingDiscount ni nastala.', 1;
IF (SELECT COUNT(*) FROM pim.PackagingDiscountCatalog WHERE IsActive = 1) < 4
  THROW 53022, 'Sifrant S kod (S1-S4) iz migracije 020 manjka.', 1;
