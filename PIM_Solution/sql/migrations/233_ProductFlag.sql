-- 233: Splosen, razsirljiv sistem oznak na artiklu. Prva oznaka je "Razstavni eksponat" (sestanek
-- 2026-09-16, glej 217: "Izpostavljeno, Razstavni eksponat, skupina popusta se najprej uredijo v
-- PIM-u"). Namerno generican register (ProductFlagDefinition) namesto namenske tabele/stolpca, da
-- kasnejse oznake (npr. "Izpostavljeno") ne rabijo nove migracije, samo novo vrstico v registru.
--
-- Isti vzorec kot pim.ProductWebShop (182): register + dejstvo + branje, ki vrne VSE aktivne oznake
-- (tudi neoznacene), da obrazec pokaze prazno potrditveno polje.

SET XACT_ABORT ON;

IF OBJECT_ID(N'pim.ProductFlagDefinition', N'U') IS NULL
BEGIN
  CREATE TABLE pim.ProductFlagDefinition
  (
    FlagCode nvarchar(50) NOT NULL,
    DisplayName nvarchar(200) NOT NULL,
    SortOrder int NOT NULL CONSTRAINT DF_ProductFlagDefinition_SortOrder DEFAULT (0),
    IsActive bit NOT NULL CONSTRAINT DF_ProductFlagDefinition_IsActive DEFAULT (1),
    CONSTRAINT PK_ProductFlagDefinition PRIMARY KEY (FlagCode)
  );
END;

IF OBJECT_ID(N'pim.ProductFlag', N'U') IS NULL
BEGIN
  CREATE TABLE pim.ProductFlag
  (
    ProductId bigint NOT NULL,
    FlagCode nvarchar(50) NOT NULL,
    IsSet bit NOT NULL CONSTRAINT DF_ProductFlag_IsSet DEFAULT (0),
    ChangedBy nvarchar(200) NOT NULL CONSTRAINT DF_ProductFlag_ChangedBy DEFAULT (N'sistem'),
    ChangedUtc datetime2(3) NOT NULL CONSTRAINT DF_ProductFlag_ChangedUtc DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_ProductFlag PRIMARY KEY (ProductId, FlagCode),
    CONSTRAINT FK_ProductFlag_Product FOREIGN KEY (ProductId) REFERENCES canon.Product (ProductId),
    CONSTRAINT FK_ProductFlag_Definition FOREIGN KEY (FlagCode) REFERENCES pim.ProductFlagDefinition (FlagCode)
  );
END;

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'pim.ProductFlag') AND name = N'IX_ProductFlag_Code')
  CREATE INDEX IX_ProductFlag_Code ON pim.ProductFlag(FlagCode, IsSet) INCLUDE (ProductId);

IF NOT EXISTS (SELECT 1 FROM pim.ProductFlagDefinition WHERE FlagCode = N'RAZSTAVNI_EKSPONAT')
  INSERT pim.ProductFlagDefinition (FlagCode, DisplayName, SortOrder) VALUES (N'RAZSTAVNI_EKSPONAT', N'Razstavni eksponat', 1);

-- Branje za kartico izdelka: vse aktivne oznake iz registra, tudi neoznacene.
EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetProductFlags
  @ProductId bigint
AS
BEGIN
  SET NOCOUNT ON;
  SELECT def.FlagCode,
         def.DisplayName,
         CAST(CASE WHEN flag.IsSet = 1 THEN 1 ELSE 0 END AS bit) AS IsSet,
         flag.ChangedBy,
         flag.ChangedUtc
  FROM pim.ProductFlagDefinition def
  LEFT JOIN pim.ProductFlag flag ON flag.ProductId = @ProductId AND flag.FlagCode = def.FlagCode
  WHERE def.IsActive = 1
  ORDER BY def.SortOrder, def.FlagCode;
END;
');

-- Zapis oznak. Vhod je JSON [{"flagCode":"RAZSTAVNI_EKSPONAT","isSet":true}, ...]; kar v njem ni
-- nasteto, ostane nespremenjeno. Oznake ne vplivajo na obseg validacije, zato (za razliko od
-- pim.SaveProductWebShops) ni klica val.RunValidation.
EXEC(N'
CREATE OR ALTER PROCEDURE pim.SaveProductFlags
  @OrganizationId int,
  @ProductId bigint,
  @ChangesJson nvarchar(max),
  @Actor nvarchar(200),
  @Note nvarchar(400) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  IF NOT EXISTS (SELECT 1 FROM canon.Product WHERE ProductId = @ProductId AND OrganizationId = @OrganizationId)
    THROW 52701, N''Izdelek ne pripada temu podjetju.'', 1;

  DECLARE @Changes TABLE (FlagCode nvarchar(50) NOT NULL PRIMARY KEY, IsSet bit NOT NULL);
  INSERT @Changes (FlagCode, IsSet)
  SELECT DISTINCT parsed.flagCode, CASE WHEN parsed.isSet IN (N''1'', N''true'') THEN 1 ELSE 0 END
  FROM OPENJSON(@ChangesJson)
  WITH (flagCode nvarchar(50) N''$.flagCode'', isSet nvarchar(10) N''$.isSet'') AS parsed
  WHERE NULLIF(parsed.flagCode, N'''') IS NOT NULL;

  IF EXISTS (SELECT 1 FROM @Changes changed
             WHERE NOT EXISTS (SELECT 1 FROM pim.ProductFlagDefinition def
                               WHERE def.FlagCode = changed.FlagCode AND def.IsActive = 1))
    THROW 52702, N''Neznana oznaka.'', 1;

  DECLARE @ItemID nvarchar(100) = (SELECT ItemID FROM canon.Product WHERE ProductId = @ProductId);
  DECLARE @BatchId bigint;

  BEGIN TRANSACTION;
  BEGIN TRY
    DECLARE @Changed TABLE (FlagCode nvarchar(50), OldValue nvarchar(10), NewValue nvarchar(10));

    MERGE pim.ProductFlag AS target
    USING @Changes AS source ON target.ProductId = @ProductId AND target.FlagCode = source.FlagCode
    WHEN MATCHED AND target.IsSet <> source.IsSet
      THEN UPDATE SET IsSet = source.IsSet, ChangedBy = @Actor, ChangedUtc = SYSUTCDATETIME()
    WHEN NOT MATCHED BY TARGET
      THEN INSERT (ProductId, FlagCode, IsSet, ChangedBy) VALUES (@ProductId, source.FlagCode, source.IsSet, @Actor)
    OUTPUT inserted.FlagCode,
           CASE WHEN deleted.IsSet IS NULL THEN N''ne'' WHEN deleted.IsSet = 1 THEN N''da'' ELSE N''ne'' END,
           CASE WHEN inserted.IsSet = 1 THEN N''da'' ELSE N''ne'' END
    INTO @Changed (FlagCode, OldValue, NewValue);

    DELETE @Changed WHERE OldValue = NewValue;

    IF EXISTS (SELECT 1 FROM @Changed)
    BEGIN
      INSERT pim.ProductChangeBatch (BatchId, ChangeSource, ChangedBy, OrganizationId, Note)
      VALUES (NEWID(), N''CARD'', @Actor, @OrganizationId, @Note);
      SET @BatchId = SCOPE_IDENTITY();

      INSERT pim.ProductFieldHistory (ChangeBatchId, OrganizationId, ProductId, ItemID, FieldKey, CanonTable, CanonColumn, Owner, OldValue, NewValue)
      SELECT @BatchId, @OrganizationId, @ProductId, @ItemID,
             CONCAT(N''ProductFlag.'', changed.FlagCode), N''pim.ProductFlag'', N''IsSet'', N''PIM'',
             changed.OldValue, changed.NewValue
      FROM @Changed changed;
    END;

    COMMIT;
  END TRY
  BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    THROW;
  END CATCH

  SELECT (SELECT COUNT(*) FROM @Changes) AS RequestedCount,
         (SELECT COUNT(*) FROM pim.ProductFlag WHERE ProductId = @ProductId AND IsSet = 1) AS SetCount;
END;
');

IF OBJECT_ID(N'intranet.GetProductFlags', N'P') IS NULL
  THROW 52703, N'233: intranet.GetProductFlags manjka.', 1;
IF OBJECT_ID(N'pim.SaveProductFlags', N'P') IS NULL
  THROW 52704, N'233: pim.SaveProductFlags manjka.', 1;
IF NOT EXISTS (SELECT 1 FROM pim.ProductFlagDefinition WHERE FlagCode = N'RAZSTAVNI_EKSPONAT')
  THROW 52705, N'233: RAZSTAVNI_EKSPONAT manjka v registru.', 1;
