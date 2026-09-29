/*
  302 — »Pakirno naročanje«: artikel se na spletu naroča samo po celih paketih.

  Uporabnik 2026-09-29 (z razvijalcem spletne trgovine): v PIM-u označimo, da je artikel »samo paketno
  naročanje«; oznaka gre v izvoz/uvoz artiklov (delovni list) in v katalog.csv kot Da/Ne. Količino paketa
  Magento vzame iz obstoječega stolpca »Pakirna količina« (Product.Pak2 = SAOP ItemQuantityOfPackaging2).
  Stolpec 34 »Omejitev pri naročanju« je bil od 045 brez vira (vedno prazen) in nihče ni vedel, kaj
  pomeni; zdaj se imenuje »Pakirno naročanje« in nosi to oznako.

  Kaj naredi:
    1. pim.ProductFlagDefinition dobi oznako PAKIRNO_NAROCANJE (register iz 233). Kartica izdelka jo
       pokaže sama na zavihku Oznake; zapis gre prek pim.SaveProductFlags z zgodovino.
    2. out.ExportColumn COL034 v profilu MAGENTO_PRODUCTS: glava »Pakirno naročanje«, vir
       ProductFlag.PakirnoNarocanje.
    3. out.GetExportRows: vrednost DA/NE (enako kot »Razstavni eksponat«, 234).
    4. val.SyncPackageOrderHolds: artikel z oznako, ki nima Pakiranja 2 (prazno ali <= 1), dobi zadržek za
       splet (val.ProductHold, kanal WEB, CreatedBy = 'pravilo 302'), da na spletu ne nastane naročanje po
       paketih brez količine. Ko je Pakiranje 2 popravljeno ali oznaka odstranjena, se zadržek sprosti.
       Ročnega zadržka (drug CreatedBy) pravilo ne spreminja. Zadržek že upoštevajo izvoz, pripravljenost
       za splet (242), kartica in /kakovost. Klicatelji: shranjevanje oznak na kartici, uvoz delovnega
       lista in izvoz katalog.csv pred sestavo datoteke (ujame tudi Pakiranje 2, ki ga spremeni zajem SAOP).
    5. pim.SetProductFlagsBulk: katerakoli oznaka iz registra za več artiklov naenkrat po šifri (uvoz
       delovnega lista, množično dejanje na /izdelki), z zgodovino v pim.ProductFieldHistory. Po zapisu
       Pakirnega naročanja takoj uskladi zadržke (točka 4).

  SAOP: nič. Oznaka je samo PIM (lastnik PIM), v SAOP se ne pošilja.
  Ročni korak: ne. Migrator ne pozna GO, zato postopki v EXEC(N'...').
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;

IF UNICODE(N'č') <> 269
  THROW 53020, N'302: datoteka ni prebrana kot UTF-8 (sqlcmd -f 65001 ali Invoke-PendingMigrations.ps1).', 1;

/* --- 1) Oznaka v registru --------------------------------------------------------------------- */

IF NOT EXISTS (SELECT 1 FROM pim.ProductFlagDefinition WHERE FlagCode = N'PAKIRNO_NAROCANJE')
  INSERT pim.ProductFlagDefinition (FlagCode, DisplayName, SortOrder)
  VALUES (N'PAKIRNO_NAROCANJE', N'Pakirno naročanje', 2);

/* --- 2) Stolpec 34 katalog.csv ---------------------------------------------------------------- */

UPDATE column34
SET OutputColumnName = N'Pakirno naročanje', CanonicalFieldCode = N'ProductFlag.PakirnoNarocanje'
FROM out.ExportColumn AS column34
INNER JOIN out.ExportProfile AS profile ON profile.ExportProfileId = column34.ExportProfileId
WHERE profile.ProfileCode = N'MAGENTO_PRODUCTS' AND column34.ColumnCode = N'COL034'
  AND (column34.OutputColumnName <> N'Pakirno naročanje' OR ISNULL(column34.CanonicalFieldCode, N'') <> N'ProductFlag.PakirnoNarocanje');

/* --- 3) Vrednost v izvozu --------------------------------------------------------------------- */

DECLARE @definition nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows'));
IF @definition IS NULL THROW 53021, N'302: out.GetExportRows manjka.', 1;
IF @definition NOT LIKE N'%/* PakirnoNarocanje302 */%'
BEGIN
  DECLARE @anchor nvarchar(max) = N'CREATE CLUSTERED INDEX IX_Value ON #Value (RowKey);';
  IF CHARINDEX(@anchor, @definition) = 0 OR CHARINDEX(@anchor, @definition, CHARINDEX(@anchor, @definition) + 1) > 0
    THROW 53022, N'302: v out.GetExportRows ni natanko enega sidra IX_Value; nič ni spremenjeno.', 1;
  DECLARE @values nvarchar(max) = N'IF @ValueSource=N''PIM_PRODUCT'' BEGIN
    /* PakirnoNarocanje302 */
    /* Pakirno naročanje: DA = na spletu samo po celih paketih (količina je »Pakirna količina«). */
    INSERT #Value(RowKey,FieldCode,Value)
    SELECT page.RowKey,N''ProductFlag.PakirnoNarocanje'',CASE WHEN flag.IsSet=1 THEN N''DA'' ELSE N''NE'' END
    FROM #Page page
    JOIN canon.Product product ON product.OrganizationId=@OrganizationId AND product.ItemID=page.RowKey
    LEFT JOIN pim.ProductFlag flag ON flag.ProductId=product.ProductId AND flag.FlagCode=N''PAKIRNO_NAROCANJE'';
  END;
  ';
  SET @definition = REPLACE(@definition, @anchor, @values + @anchor);
  SET @definition = N'ALTER ' + SUBSTRING(@definition, CHARINDEX(N'PROCEDURE', @definition), 2147483647);
  EXEC sys.sp_executesql @definition;
END;

IF OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows')) NOT LIKE N'%/* PakirnoNarocanje302 */%'
  THROW 53023, N'302: vrednost Pakirno naročanje ni v out.GetExportRows.', 1;

/* --- 4) Zadržek za splet brez količine paketa ------------------------------------------------- */

EXEC(N'CREATE OR ALTER PROCEDURE val.SyncPackageOrderHolds
  @OrganizationId int = NULL,
  @ProductId bigint = NULL,
  @Held int = NULL OUTPUT,
  @Released int = NULL OUTPUT
AS
BEGIN
  /* 302: artikel s »Pakirnim naročanjem« brez Pakiranja 2 (> 1) ne sme na splet. Pravilo vodi samo
     svoje zadržke (CreatedBy = pravilo 302); ročnega zadržka ne prepiše in ne sprosti. */
  SET NOCOUNT ON; SET XACT_ABORT ON;
  DECLARE @Rule nvarchar(200) = N''pravilo 302'';
  DECLARE @Reason nvarchar(500) = N''Pakirno naročanje brez količine paketa: vpiši Pakiranje 2 (večje od 1) ali odstrani oznako Pakirno naročanje.'';

  CREATE TABLE #Missing (ProductId bigint NOT NULL PRIMARY KEY);
  INSERT #Missing (ProductId)
  SELECT flag.ProductId
  FROM pim.ProductFlag AS flag
  INNER JOIN canon.Product AS product ON product.ProductId = flag.ProductId
  LEFT JOIN pim.Product AS promoted ON promoted.OrganizationId = product.OrganizationId AND promoted.ItemID = product.ItemID
  LEFT JOIN pim.ProductCommercial AS commercial ON commercial.PimProductId = promoted.PimProductId
  WHERE flag.FlagCode = N''PAKIRNO_NAROCANJE'' AND flag.IsSet = 1
    AND ISNULL(commercial.Pak2, 0) <= 1
    AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
    AND (@ProductId IS NULL OR flag.ProductId = @ProductId);

  BEGIN TRANSACTION;

  INSERT val.ProductHold (ProductId, ChannelCode, Reason, CreatedBy)
  SELECT missing.ProductId, N''WEB'', @Reason, @Rule
  FROM #Missing AS missing
  WHERE NOT EXISTS (SELECT 1 FROM val.ProductHold AS hold
                    WHERE hold.ProductId = missing.ProductId AND hold.IsActive = 1 AND hold.ChannelCode IN (N''WEB'', N''ALL''));
  SET @Held = @@ROWCOUNT;

  UPDATE hold SET IsActive = 0, ReleasedUtc = SYSUTCDATETIME(), ReleasedBy = @Rule
  FROM val.ProductHold AS hold
  INNER JOIN canon.Product AS product ON product.ProductId = hold.ProductId
  WHERE hold.IsActive = 1 AND hold.CreatedBy = @Rule
    AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
    AND (@ProductId IS NULL OR hold.ProductId = @ProductId)
    AND NOT EXISTS (SELECT 1 FROM #Missing AS missing WHERE missing.ProductId = hold.ProductId);
  SET @Released = @@ROWCOUNT;

  COMMIT TRANSACTION;
END;');

/* --- 5) Množični zapis oznak --------------------------------------------------------------- */

EXEC(N'CREATE OR ALTER PROCEDURE pim.SetProductFlagsBulk
  @OrganizationId int,
  @FlagCode nvarchar(50),
  @ItemsJson nvarchar(max),          /* [{"i":"ŠIFRA","s":1}, ...] */
  @Actor nvarchar(200),
  @ChangeSource nvarchar(32),        /* EXCEL | INTRANET | CARD */
  @Note nvarchar(400) = NULL
AS
BEGIN
  /* 302: splošna različica pim.SetShowcaseFlags (275) za katerokoli oznako registra, po šifri artikla.
     Vrne: ChangedCount, UnknownItems (šifre, ki jih v podjetju ni), Held, Released (samo Pakirno naročanje). */
  SET NOCOUNT ON; SET XACT_ABORT ON;
  SET @Actor = NULLIF(LTRIM(RTRIM(@Actor)), N'''');
  IF @Actor IS NULL THROW 53030, N''Kdo shranjuje oznake, mora biti znano (Actor).'', 1;
  IF NOT EXISTS (SELECT 1 FROM pim.ProductFlagDefinition WHERE FlagCode = @FlagCode AND IsActive = 1)
    THROW 53031, N''Neznana ali neaktivna oznaka.'', 1;
  IF @ItemsJson IS NULL OR ISJSON(@ItemsJson) = 0 THROW 53032, N''Seznam artiklov ni veljaven JSON.'', 1;

  CREATE TABLE #Item (ItemID nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY, IsSet bit NOT NULL, ProductId bigint NULL);
  INSERT #Item (ItemID, IsSet)
  SELECT LTRIM(RTRIM(parsed.i)), MAX(CONVERT(int, parsed.s))
  FROM OPENJSON(@ItemsJson) WITH (i nvarchar(100) N''$.i'', s bit N''$.s'') AS parsed
  WHERE NULLIF(LTRIM(RTRIM(parsed.i)), N'''') IS NOT NULL AND parsed.s IS NOT NULL
  GROUP BY LTRIM(RTRIM(parsed.i));

  UPDATE item SET ProductId = product.ProductId
  FROM #Item AS item
  INNER JOIN canon.Product AS product ON product.OrganizationId = @OrganizationId AND product.ItemID = item.ItemID;

  DECLARE @Changed TABLE (ProductId bigint, OldValue nvarchar(10), NewValue nvarchar(10));
  DECLARE @Held int = 0, @Released int = 0;

  BEGIN TRANSACTION;

  MERGE pim.ProductFlag AS target
  USING (SELECT ProductId, IsSet FROM #Item WHERE ProductId IS NOT NULL) AS source
    ON target.ProductId = source.ProductId AND target.FlagCode = @FlagCode
  WHEN MATCHED AND target.IsSet <> source.IsSet
    THEN UPDATE SET IsSet = source.IsSet, ChangedBy = @Actor, ChangedUtc = SYSUTCDATETIME()
  WHEN NOT MATCHED BY TARGET AND source.IsSet = 1
    THEN INSERT (ProductId, FlagCode, IsSet, ChangedBy) VALUES (source.ProductId, @FlagCode, 1, @Actor)
  OUTPUT inserted.ProductId,
         CASE WHEN deleted.IsSet = 1 THEN N''da'' ELSE N''ne'' END,
         CASE WHEN inserted.IsSet = 1 THEN N''da'' ELSE N''ne'' END
  INTO @Changed (ProductId, OldValue, NewValue);

  DELETE @Changed WHERE OldValue = NewValue;

  IF EXISTS (SELECT 1 FROM @Changed)
  BEGIN
    DECLARE @BatchId bigint;
    INSERT pim.ProductChangeBatch (BatchId, ChangeSource, ChangedBy, OrganizationId, Note)
    VALUES (NEWID(), @ChangeSource, @Actor, @OrganizationId, @Note);
    SET @BatchId = SCOPE_IDENTITY();

    INSERT pim.ProductFieldHistory (ChangeBatchId, OrganizationId, ProductId, ItemID, FieldKey, CanonTable, CanonColumn, Owner, OldValue, NewValue)
    SELECT @BatchId, @OrganizationId, changed.ProductId, product.ItemID,
           CONCAT(N''ProductFlag.'', @FlagCode), N''pim.ProductFlag'', N''IsSet'', N''PIM'', changed.OldValue, changed.NewValue
    FROM @Changed AS changed
    INNER JOIN canon.Product AS product ON product.ProductId = changed.ProductId;
  END;

  IF @FlagCode = N''PAKIRNO_NAROCANJE'' AND EXISTS (SELECT 1 FROM @Changed)
    EXEC val.SyncPackageOrderHolds @OrganizationId = @OrganizationId, @Held = @Held OUTPUT, @Released = @Released OUTPUT;

  COMMIT TRANSACTION;

  SELECT ChangedCount = (SELECT COUNT(*) FROM @Changed),
         UnknownItems = STRING_AGG(CONVERT(nvarchar(max), item.ItemID), N'', '') WITHIN GROUP (ORDER BY item.ItemID),
         Held = @Held, Released = @Released
  FROM (SELECT 1 AS One) AS anchor
  LEFT JOIN #Item AS item ON item.ProductId IS NULL;
END;');

IF NOT EXISTS (SELECT 1 FROM pim.ProductFlagDefinition WHERE FlagCode = N'PAKIRNO_NAROCANJE' AND IsActive = 1)
  THROW 53024, N'302: oznaka PAKIRNO_NAROCANJE manjka v registru.', 1;
IF EXISTS (SELECT 1 FROM out.ExportColumn AS c INNER JOIN out.ExportProfile AS p ON p.ExportProfileId = c.ExportProfileId
           WHERE p.ProfileCode = N'MAGENTO_PRODUCTS' AND c.ColumnCode = N'COL034' AND c.CanonicalFieldCode <> N'ProductFlag.PakirnoNarocanje')
  THROW 53025, N'302: stolpec COL034 nima vira ProductFlag.PakirnoNarocanje.', 1;
IF OBJECT_ID(N'val.SyncPackageOrderHolds', N'P') IS NULL
  THROW 53026, N'302: val.SyncPackageOrderHolds manjka.', 1;
IF OBJECT_ID(N'pim.SetProductFlagsBulk', N'P') IS NULL
  THROW 53027, N'302: pim.SetProductFlagsBulk manjka.', 1;

/* Zadržki za artikle, ki so oznako morda že dobili pred to migracijo (ponovni zagon). */
EXEC val.SyncPackageOrderHolds;
