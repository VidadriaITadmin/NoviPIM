-- 232: Odprodaja artiklov — obuditev pim.ClearanceItem (153, doslej brez ene vrstice in brez kode) za
-- rocni uvoz dobaviteljevega odprodajnega seznama (Sifra, Kolicina, Popust %, ...) iz Excela.
--
-- Uporabnik 2026-09-18: cena se v izvozu ne spreminja in ne dodaja (glej 235) — RednaCena/OdprodajnaCena
-- ostajata v tabeli samo za interni pregled na kartici izdelka. Ponovni uvoz istega vira (Vir, npr.
-- "Azzardo 2026-09") je edino veljavno stanje za ta vir: sifre, ki jih v novi datoteki ni vec, se
-- samodejno zakljucijo (IsActive = 0), ne izbrisejo.
--
-- Zaloga v katalogu (235) kasneje prevzame prednost pred to uvozeno Kolicina, ko je registriran zivi vir
-- za skladisce ODPRODAJA (234) — do takrat je Kolicina iz te tabele edini vir kolicine.

SET XACT_ABORT ON;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'pim.ClearanceItem') AND name = N'IsActive')
  ALTER TABLE pim.ClearanceItem ADD IsActive bit NOT NULL CONSTRAINT DF_ClearanceItem_IsActive DEFAULT (1);
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'pim.ClearanceItem') AND name = N'EndedUtc')
  ALTER TABLE pim.ClearanceItem ADD EndedUtc datetime2(3) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'pim.ClearanceItem') AND name = N'EndedBy')
  ALTER TABLE pim.ClearanceItem ADD EndedBy nvarchar(200) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'pim.ClearanceItem') AND name = N'IX_ClearanceItem_Active')
  CREATE INDEX IX_ClearanceItem_Active ON pim.ClearanceItem(ProductId, IsActive) INCLUDE (Vir, Kolicina, PopustOdstotek);

-- Mnozicni uvoz/posodobitev enega vira naenkrat. Vhod je JSON
-- [{"sifra":"AZ.0059","kolicina":3,"rednaCena":49.9,"popustOdstotek":40,"odprodajnaCena":29.9}, ...].
-- Sifre brez ujemajocega canon.Product v tej organizaciji se preskocijo in vrnejo kot NeujemajoceSifre,
-- da jih predogled v UI pokaze, preden se karkoli zapise (isti vzorec kot ProductWorkbookService).
EXEC(N'
CREATE OR ALTER PROCEDURE pim.SaveClearanceItems
  @OrganizationId int,
  @Vir nvarchar(100),
  @ItemsJson nvarchar(max),
  @Actor nvarchar(200),
  @IzvornaDatoteka nvarchar(260) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  IF NULLIF(LTRIM(RTRIM(@Vir)), N'''') IS NULL
    THROW 52601, N''Vnesi vir odprodajnega seznama.'', 1;
  IF NULLIF(@Actor, N'''') IS NULL
    THROW 52602, N''Manjka izvajalec.'', 1;

  DECLARE @Rows TABLE (
    Sifra nvarchar(100) NOT NULL,
    ProductId bigint NULL,
    Kolicina decimal(19,4) NULL,
    RednaCena decimal(19,4) NULL,
    PopustOdstotek decimal(5,2) NULL,
    OdprodajnaCena decimal(19,4) NULL
  );
  INSERT @Rows (Sifra, ProductId, Kolicina, RednaCena, PopustOdstotek, OdprodajnaCena)
  SELECT parsed.sifra, product.ProductId, parsed.kolicina, parsed.rednaCena, parsed.popustOdstotek, parsed.odprodajnaCena
  FROM OPENJSON(@ItemsJson)
  WITH (
    sifra nvarchar(100) N''$.sifra'',
    kolicina decimal(19,4) N''$.kolicina'',
    rednaCena decimal(19,4) N''$.rednaCena'',
    popustOdstotek decimal(5,2) N''$.popustOdstotek'',
    odprodajnaCena decimal(19,4) N''$.odprodajnaCena''
  ) AS parsed
  LEFT JOIN canon.Product product ON product.OrganizationId = @OrganizationId AND product.ItemID = parsed.sifra
  WHERE NULLIF(parsed.sifra, N'''') IS NOT NULL;

  DECLARE @Ean TABLE (ProductId bigint PRIMARY KEY, Ean nvarchar(100));
  INSERT @Ean (ProductId, Ean) SELECT ProductId, EAN FROM canon.Product WHERE ProductId IN (SELECT ProductId FROM @Rows WHERE ProductId IS NOT NULL);

  BEGIN TRANSACTION;
  BEGIN TRY
    MERGE pim.ClearanceItem AS target
    USING (SELECT * FROM @Rows WHERE ProductId IS NOT NULL) AS source
      ON target.ProductId = source.ProductId AND target.Vir = @Vir
    WHEN MATCHED THEN UPDATE SET
      Sifra = source.Sifra, Kolicina = source.Kolicina, RednaCena = source.RednaCena,
      PopustOdstotek = source.PopustOdstotek, OdprodajnaCena = source.OdprodajnaCena,
      IsActive = 1, EndedUtc = NULL, EndedBy = NULL,
      IzvornaDatoteka = @IzvornaDatoteka, ImportiranoUtc = SYSUTCDATETIME()
    WHEN NOT MATCHED BY TARGET THEN INSERT
      (ProductId, Vir, Sifra, Ean, NaSvetila, NaVidelektro, Kolicina, RednaCena, PopustOdstotek, OdprodajnaCena, IzvornaDatoteka)
      VALUES (source.ProductId, @Vir, source.Sifra, (SELECT Ean FROM @Ean WHERE ProductId = source.ProductId), 0, 0,
              source.Kolicina, source.RednaCena, source.PopustOdstotek, source.OdprodajnaCena, @IzvornaDatoteka)
    WHEN NOT MATCHED BY SOURCE AND target.Vir = @Vir AND target.IsActive = 1 THEN UPDATE SET
      IsActive = 0, EndedUtc = SYSUTCDATETIME(), EndedBy = CONCAT(N''uvoz: '', @Vir);

    DECLARE @BatchId bigint;
    IF EXISTS (SELECT 1 FROM @Rows WHERE ProductId IS NOT NULL)
    BEGIN
      INSERT pim.ProductChangeBatch (BatchId, ChangeSource, ChangedBy, OrganizationId, Note)
      VALUES (NEWID(), N''CLEARANCE_IMPORT'', @Actor, @OrganizationId, CONCAT(N''Uvoz odprodaje: '', @Vir));
      SET @BatchId = SCOPE_IDENTITY();

      INSERT pim.ProductFieldHistory (ChangeBatchId, OrganizationId, ProductId, ItemID, FieldKey, CanonTable, CanonColumn, Owner, OldValue, NewValue)
      SELECT @BatchId, @OrganizationId, r.ProductId, r.Sifra, CONCAT(N''ClearanceItem.'', @Vir), N''pim.ClearanceItem'', N''Kolicina/PopustOdstotek'', N''PIM'', NULL,
        CONCAT(N''kolicina='', ISNULL(CONVERT(nvarchar(50), r.Kolicina), N''-''), N'', popust='', ISNULL(CONVERT(nvarchar(50), r.PopustOdstotek), N''-''), N''%'')
      FROM @Rows r WHERE r.ProductId IS NOT NULL;
    END;

    COMMIT;
  END TRY
  BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    THROW;
  END CATCH

  SELECT
    (SELECT COUNT(*) FROM @Rows) AS RequestedCount,
    (SELECT COUNT(*) FROM @Rows WHERE ProductId IS NOT NULL) AS MatchedCount,
    (SELECT COUNT(*) FROM @Rows WHERE ProductId IS NULL) AS UnmatchedCount;
  SELECT Sifra AS NeujemajocaSifra FROM @Rows WHERE ProductId IS NULL;
END;
');

-- Rocna zakljucitev ene vrstice s kartice izdelka (npr. artikel ni vec na odprodaji, ceprav zaloga
-- v skladiscu se ni 0).
EXEC(N'
CREATE OR ALTER PROCEDURE pim.EndClearanceItem
  @ClearanceItemId bigint,
  @Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON;
  IF NULLIF(@Actor, N'''') IS NULL THROW 52603, N''Manjka izvajalec.'', 1;
  UPDATE pim.ClearanceItem
    SET IsActive = 0, EndedUtc = SYSUTCDATETIME(), EndedBy = @Actor
  WHERE ClearanceItemId = @ClearanceItemId AND IsActive = 1;
END;
');

-- Branje za kartico izdelka: aktivne vrstice, najnovejse najprej.
EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetClearanceItemsForProduct
  @ProductId bigint
AS
BEGIN
  SET NOCOUNT ON;
  SELECT ClearanceItemId, Vir, Sifra, Kolicina, RednaCena, PopustOdstotek, OdprodajnaCena,
         IzvornaDatoteka, ImportiranoUtc, IsActive, EndedUtc, EndedBy
  FROM pim.ClearanceItem
  WHERE ProductId = @ProductId
  ORDER BY IsActive DESC, ImportiranoUtc DESC;
END;
');

IF OBJECT_ID(N'pim.SaveClearanceItems', N'P') IS NULL
  THROW 52604, N'232: pim.SaveClearanceItems manjka.', 1;
IF OBJECT_ID(N'pim.EndClearanceItem', N'P') IS NULL
  THROW 52605, N'232: pim.EndClearanceItem manjka.', 1;
IF OBJECT_ID(N'intranet.GetClearanceItemsForProduct', N'P') IS NULL
  THROW 52606, N'232: intranet.GetClearanceItemsForProduct manjka.', 1;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'pim.ClearanceItem') AND name = N'IsActive')
  THROW 52607, N'232: pim.ClearanceItem.IsActive manjka.', 1;
