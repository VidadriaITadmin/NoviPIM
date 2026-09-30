/*
  313_IndeksUndoOfChangeId — naloga #82 (razvijalec #82, 2026-09-30).

  pim.UndoProductField in pim.UndoProductBatch (zadnja definicija 037) preverjata
    IF EXISTS (SELECT 1 FROM pim.ProductFieldHistory WHERE UndoOfChangeId = @ChangeId)
  Na UndoOfChangeId ni bilo indeksa: vsaka razveljavitev je prebrala celo zgodovino
  (~2,7 mio vrstic, na DEV 88.730 logicnih branj) in pri READ COMMITTED cakala na vsako
  tujo odprto transakcijo, ki pise zgodovino (zajem, uvoz, testi). Isti pregled je naredil
  tudi tuji kljuc FK_PimProductFieldHistory_Undo ob vsakem brisanju vrstic zgodovine.

  Tuji kljuc FK_PimProductFieldHistory_Product (ProductId -> canon.Product) nima indeksa,
  ki bi se zacel s ProductId (IX_PimProductFieldHistory_Product je OrganizationId, ProductId, ...),
  zato je brisanje artikla (ciscenje testov) pregledalo celo zgodovino.

  1) IX_PimProductFieldHistory_UndoOf: filtriran (samo vrstice razveljavitev) -> skoraj prazen,
     pisanje navadne zgodovine ga ne vzdrzuje. Vse procedure in sprozilci, ki pisejo v tabelo,
     imajo QUOTED_IDENTIFIER ON (preverjeno v sys.sql_modules), Invoke-PendingMigrations.ps1 tece s sqlcmd -I.
  2) IX_PimProductFieldHistory_ProductId: ozek indeks za tuji kljuc na izdelek.

  ONLINE = ON, kjer izdaja to dopusca (Enterprise/Developer/Azure), da gradnja ne zaklene pisanja zgodovine.
  Idempotentna. Procedur ne spreminja.
*/

SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;

DECLARE @online nvarchar(40) =
  CASE WHEN CONVERT(int, SERVERPROPERTY('EngineEdition')) IN (3, 5, 8) THEN N' WITH (ONLINE = ON)' ELSE N'' END;
DECLARE @sql nvarchar(max);

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'pim.ProductFieldHistory') AND name = N'IX_PimProductFieldHistory_UndoOf')
BEGIN
  SET @sql = N'CREATE INDEX IX_PimProductFieldHistory_UndoOf ON pim.ProductFieldHistory(UndoOfChangeId) WHERE UndoOfChangeId IS NOT NULL' + @online + N';';
  EXEC sys.sp_executesql @sql;
END;

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'pim.ProductFieldHistory') AND name = N'IX_PimProductFieldHistory_ProductId')
BEGIN
  SET @sql = N'CREATE INDEX IX_PimProductFieldHistory_ProductId ON pim.ProductFieldHistory(ProductId)' + @online + N';';
  EXEC sys.sp_executesql @sql;
END;

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'pim.ProductFieldHistory') AND name = N'IX_PimProductFieldHistory_UndoOf')
  THROW 53131, 'Indeks zgodovine po UndoOfChangeId ni nastal.', 1;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'pim.ProductFieldHistory') AND name = N'IX_PimProductFieldHistory_ProductId')
  THROW 53132, 'Indeks zgodovine po ProductId ni nastal.', 1;
