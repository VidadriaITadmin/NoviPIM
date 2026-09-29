/*
  282 — Varovalka datoteke cen in zaloge za splet (MAGENTO_STOCK_PRICES).

  Uporabnik 2026-09-24: »dej mi še ostale varovalke notri«. Datoteka cen in zaloge gre na Magento vsakih nekaj
  minut in nosi CENE (Cena B2B, Cena B2C) — varovalka katalog.csv (277) je ni pokrivala, zato bi cena ×100 prišla na
  splet po tej poti. Poleg cen pazi še na nenaden padec zaloge na 0 pri veliko artiklih hkrati (npr. zajem zaloge
  iz SAOP ni uspel ali je prinesel prazno).

  Kako deluje (kot katalog.csv): worker zapiše datoteko, pokliče ops.EvaluateStockPriceSafeguards, sumljive artikle
  izpusti iz objavljene datoteke (na spletu ostanejo s prejšnjo ceno in zalogo), ostale objavi in zapiše objavo
  (out.RecordExportPublication). Potrditev na /varovalke/{id} (ops.ApproveSafeguardFindings, 277 — zahteva zagon
  WEB_STOCK_EXPORT). Vse primerjave so z zadnjo objavo; prvi zagon po uvedbi samo zapiše izhodišče.

  Pravila (področje ZALOGA_CSV):
    ZAL_CENA_VEJICA  cena ×10/×100/×1000 ali ÷ glede na zadnjo objavo (±2 %)
    ZAL_CENA_NIC     cena je bila > 0, zdaj 0 ali negativna
    ZAL_CENA_PRAZNA  cena je bila, zdaj je prazna
    ZAL_CENA_SKOK    sprememba cene nad pragom (25 %)
    ZAL_ZALOGA_NIC   razpoložljiva zaloga pade z >0 na 0 ali prazno pri vsaj N artiklih hkrati (20) — posamična
                     prodaja do 0 je običajna in ne zadrži
    ZAL_VRSTICE      artiklov v datoteki je za več kot prag (20 %) manj kot ob zadnji objavi — opozorilo

  Objekti: out.ExportColumn.GuardKind (dovoljen še 'STOCK'; nastavljeno za MAGENTO_STOCK_PRICES),
  out.ExportPublishedValue (izhodišče), ops.EvaluateStockPriceSafeguards, out.RecordExportPublication,
  pravila v ops.SafeguardRule. Ročni korak: ne. Migrator ne pozna GO, zato CREATE OR ALTER v EXEC(N'...').
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

IF UNICODE(N'č') <> 269
  THROW 52950, N'282: datoteka ni prebrana kot UTF-8 (sqlcmd -f 65001 ali Invoke-PendingMigrations.ps1).', 1;
IF OBJECT_ID(N'ops.SafeguardRule', N'U') IS NULL OR COL_LENGTH(N'out.ExportColumn', N'GuardKind') IS NULL
  THROW 52951, N'282 potrebuje migracijo 277.', 1;

/* --- 1) Varovani stolpci datoteke cen in zaloge ----------------------------------------------------- */
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_ExportColumn_GuardKind'
           AND definition NOT LIKE N'%STOCK%')
  ALTER TABLE out.ExportColumn DROP CONSTRAINT CK_ExportColumn_GuardKind;
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_ExportColumn_GuardKind')
  ALTER TABLE out.ExportColumn ADD CONSTRAINT CK_ExportColumn_GuardKind CHECK (GuardKind IN (N'PRICE', N'STOCK'));

EXEC(N'UPDATE exportColumn
  SET GuardKind = CASE WHEN exportColumn.CanonicalFieldCode IN (N''Product.PriceB2B'', N''Product.PriceB2C'') THEN N''PRICE''
                       WHEN exportColumn.CanonicalFieldCode = N''Stock.ErpAvailable'' THEN N''STOCK'' END
  FROM out.ExportColumn AS exportColumn
  INNER JOIN out.ExportProfile AS exportProfile ON exportProfile.ExportProfileId = exportColumn.ExportProfileId
  WHERE exportProfile.ProfileCode = N''MAGENTO_STOCK_PRICES''
    AND exportColumn.CanonicalFieldCode IN (N''Product.PriceB2B'', N''Product.PriceB2C'', N''Stock.ErpAvailable'');');

/* --- 2) Izhodišče: vrednosti zadnje objavljene datoteke -------------------------------------------------- */
IF OBJECT_ID(N'out.ExportPublishedValue', N'U') IS NULL
  CREATE TABLE out.ExportPublishedValue
  (
    ProfileCode nvarchar(100) NOT NULL,
    OrganizationId int NOT NULL,
    ItemID nvarchar(100) NOT NULL,
    /* Kanonična koda stolpca; vrednost v invariantni obliki (pika), NULL = prazno. */
    FieldCode nvarchar(200) NOT NULL,
    Value nvarchar(400) NULL,
    PublishedUtc datetime2(3) NOT NULL,
    CONSTRAINT PK_ExportPublishedValue PRIMARY KEY (ProfileCode, OrganizationId, ItemID, FieldCode)
  );

/* --- 3) Pravila ------------------------------------------------------------------------------------ */
MERGE ops.SafeguardRule AS target
USING (VALUES
  (N'ZAL_CENA_VEJICA', N'Cena ×10/×100 (izgubljena ali dodana vejica)', N'cena ×10/×100',
   N'Cena v datoteki cen in zaloge je 10-, 100- ali 1000-krat večja ali manjša od zadnje objavljene.',
   N'Preveri ceno v SAOP. Če je prav, potrdi; če ni, jo popravi — naslednji izvoz artikel objavi sam.',
   CONVERT(decimal(19,4), NULL), CONVERT(nvarchar(100), NULL), 1, 1, 10),
  (N'ZAL_CENA_NIC', N'Cena 0', N'cena 0', N'Cena je bila objavljena, zdaj je 0 ali negativna.',
   N'Če je prav, potrdi; sicer popravi ceno v SAOP.', NULL, NULL, 1, 1, 20),
  (N'ZAL_CENA_PRAZNA', N'Prazna cena', N'prazna cena', N'Cena je bila objavljena, zdaj je prazna.',
   N'Preveri cenik v SAOP. Če je prav (artikel se po tem ceniku ne prodaja več), potrdi.', NULL, NULL, 1, 1, 30),
  (N'ZAL_CENA_SKOK', N'Velika sprememba cene', N'velik skok cene', N'Cena se od zadnje objave spremeni za več, kot dovoljuje prag.',
   N'Preveri novo ceno; če je prav (nov cenik), potrdi.', CONVERT(decimal(19,4), 25), N'sprememba cene v %', 1, 1, 40),
  (N'ZAL_ZALOGA_NIC', N'Zaloga naenkrat na 0 pri veliko artiklih', N'zaloga na 0',
   N'Razpoložljiva zaloga pade na 0 pri veliko artiklih hkrati — pogosto znak, da zajem zaloge iz SAOP ni uspel. '
     + N'Posamična prodaja do 0 je običajna in ne zadrži.',
   N'Preveri zalogo v SAOP in zadnji zajem zaloge (Nadzor). Če je res, potrdi.', NULL, NULL, 20, 1, 50),
  (N'ZAL_VRSTICE', N'V datoteki je bistveno manj artiklov', N'padec artiklov',
   N'Artiklov v datoteki cen in zaloge je za več kot prag manj kot ob zadnji objavi.',
   N'Preveri, zakaj artikli manjkajo (umik s spleta, validacija, zajem).', CONVERT(decimal(19,4), 20), N'padec v %', 1, 0, 60)
) AS source (RuleCode, Title, ShortLabel, Explanation, WhatToDo, ThresholdValue, ThresholdLabel, MinCount, CanHold, SortOrder)
ON target.RuleCode = source.RuleCode
WHEN MATCHED THEN UPDATE SET Title = source.Title, ShortLabel = source.ShortLabel, Explanation = source.Explanation,
  WhatToDo = source.WhatToDo, ThresholdLabel = source.ThresholdLabel, SortOrder = source.SortOrder, CanHold = source.CanHold
WHEN NOT MATCHED THEN INSERT (RuleCode, AreaCode, Title, ShortLabel, Explanation, WhatToDo, RequiresConfirmation, CanHold,
    IsInformational, IsEnabled, ThresholdValue, ThresholdLabel, MinCount, SortOrder, UpdatedUtc, UpdatedBy)
  VALUES (source.RuleCode, N'ZALOGA_CSV', source.Title, source.ShortLabel, source.Explanation, source.WhatToDo, source.CanHold,
    source.CanHold, 0, 1, source.ThresholdValue, source.ThresholdLabel, source.MinCount, source.SortOrder, SYSUTCDATETIME(), N'migracija 282');

/* --- 4) Preverjanje pred objavo ---------------------------------------------------------------------- */
EXEC(N'CREATE OR ALTER PROCEDURE ops.EvaluateStockPriceSafeguards
  @ProfileCode nvarchar(100),
  @OrganizationId int,
  @RowsJson nvarchar(max),              /* [{"i":"<šifra>","s":"","v":{"Product.PriceB2C":"13.02","Stock.ErpAvailable":"5"}}] */
  @RowCount int,
  @Actor nvarchar(200) = N''PIM.B2bWorker''
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  /* 282: worker poda vrstice pravkar zapisane datoteke cen in zaloge (vrednosti s piko). Primerjava je z zadnjo
     objavo (out.ExportPublishedValue). Vrne izid in šifre zadržanih artiklov — worker jih izpusti iz datoteke. */
  DECLARE @Area nvarchar(50) = N''ZALOGA_CSV'';
  DECLARE @Now datetime2(3) = SYSUTCDATETIME();
  IF @OrganizationId IS NULL OR ISNULL(ISJSON(@RowsJson), 0) <> 1
    THROW 52952, N''Varovalka cen in zaloge potrebuje podjetje in vrstice datoteke (JSON).'', 1;

  CREATE TABLE #Value
    (ItemID nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL,
     FieldCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
     RawValue nvarchar(400) COLLATE DATABASE_DEFAULT NULL,
     Number decimal(19,4) NULL,
     PRIMARY KEY (ItemID, FieldCode));
  INSERT #Value (ItemID, FieldCode, RawValue, Number)
  SELECT parsed.i, LEFT(field.[key], 200), MAX(LEFT(NULLIF(LTRIM(RTRIM(field.value)), N''''), 400)),
    MAX(TRY_CONVERT(decimal(19,4), NULLIF(LTRIM(RTRIM(field.value)), N'''')))
  FROM OPENJSON(@RowsJson) WITH (i nvarchar(100) N''$.i'', v nvarchar(max) N''$.v'' AS JSON) AS parsed
  CROSS APPLY OPENJSON(parsed.v) AS field
  WHERE NULLIF(LTRIM(RTRIM(parsed.i)), N'''') IS NOT NULL
  GROUP BY parsed.i, LEFT(field.[key], 200);

  CREATE TABLE #Finding
    (RuleCode nvarchar(50) COLLATE DATABASE_DEFAULT NOT NULL,
     ItemID nvarchar(100) COLLATE DATABASE_DEFAULT NULL,
     FieldCode nvarchar(200) COLLATE DATABASE_DEFAULT NULL,
     OldValue nvarchar(400) COLLATE DATABASE_DEFAULT NULL,
     NewValue nvarchar(400) COLLATE DATABASE_DEFAULT NULL,
     ChangeText nvarchar(100) COLLATE DATABASE_DEFAULT NULL,
     RequiresConfirmation bit NOT NULL DEFAULT (0),
     ApprovalId bigint NULL,
     Fingerprint varbinary(32) NULL);

  DECLARE @Jump decimal(19,4) = ISNULL((SELECT ThresholdValue FROM ops.SafeguardRule WHERE RuleCode = N''ZAL_CENA_SKOK''), 25);
  DECLARE @RowDrop decimal(19,4) = ISNULL((SELECT ThresholdValue FROM ops.SafeguardRule WHERE RuleCode = N''ZAL_VRSTICE''), 20);

  /* Cene glede na zadnjo objavo (brez izhodišča ni ugotovitve — prvi zagon ga samo zapiše). */
  WITH compared AS
  (
    SELECT value.ItemID, value.FieldCode, previous.Value AS OldValue, value.RawValue AS NewValue,
      OldNumber = TRY_CONVERT(decimal(19,4), previous.Value), NewNumber = value.Number
    FROM #Value AS value
    INNER JOIN out.ExportPublishedValue AS previous
      ON previous.ProfileCode = @ProfileCode AND previous.OrganizationId = @OrganizationId
     AND previous.ItemID = value.ItemID AND previous.FieldCode = value.FieldCode
    WHERE value.FieldCode IN (N''Product.PriceB2B'', N''Product.PriceB2C'')
      AND ISNULL(previous.Value, N''<prazno>'') <> ISNULL(value.RawValue, N''<prazno>'')
  )
  INSERT #Finding (RuleCode, ItemID, FieldCode, OldValue, NewValue, ChangeText)
  SELECT CASE
           WHEN compared.NewValue IS NULL THEN N''ZAL_CENA_PRAZNA''
           WHEN compared.NewNumber <= 0 THEN N''ZAL_CENA_NIC''
           WHEN factor.Value IS NOT NULL THEN N''ZAL_CENA_VEJICA''
           ELSE N''ZAL_CENA_SKOK'' END,
    compared.ItemID, compared.FieldCode, compared.OldValue, compared.NewValue,
    CASE WHEN factor.Value IS NOT NULL THEN CONCAT(CASE WHEN compared.NewNumber > compared.OldNumber THEN NCHAR(215) ELSE NCHAR(247) END, factor.Value)
         WHEN compared.NewNumber > 0 AND compared.OldNumber > 0
           THEN CONCAT(CASE WHEN compared.NewNumber > compared.OldNumber THEN N''+'' ELSE N'''' END,
                       CONVERT(decimal(9,1), (compared.NewNumber - compared.OldNumber) / compared.OldNumber * 100), N'' %'') END
  FROM compared
  OUTER APPLY (SELECT TOP (1) factor.Value FROM (VALUES (10), (100), (1000)) AS factor (Value)
               WHERE compared.NewNumber > 0 AND compared.OldNumber > 0
                 AND (ABS(compared.NewNumber / NULLIF(compared.OldNumber, 0) - factor.Value) <= 0.02 * factor.Value
                   OR ABS(compared.OldNumber / NULLIF(compared.NewNumber, 0) - factor.Value) <= 0.02 * factor.Value)
               ORDER BY factor.Value) AS factor
  WHERE compared.OldValue IS NOT NULL AND ISNULL(compared.OldNumber, 0) > 0
    AND (compared.NewValue IS NULL OR compared.NewNumber <= 0 OR factor.Value IS NOT NULL
         OR ABS(compared.NewNumber - compared.OldNumber) / NULLIF(compared.OldNumber, 0) * 100 > @Jump);

  /* Zaloga: z >0 na 0 ali prazno (zadrži šele, ko je takih artiklov vsaj MinCount). */
  INSERT #Finding (RuleCode, ItemID, FieldCode, OldValue, NewValue)
  SELECT N''ZAL_ZALOGA_NIC'', value.ItemID, value.FieldCode, previous.Value, value.RawValue
  FROM #Value AS value
  INNER JOIN out.ExportPublishedValue AS previous
    ON previous.ProfileCode = @ProfileCode AND previous.OrganizationId = @OrganizationId
   AND previous.ItemID = value.ItemID AND previous.FieldCode = value.FieldCode
  WHERE value.FieldCode = N''Stock.ErpAvailable'' AND TRY_CONVERT(decimal(19,4), previous.Value) > 0 AND ISNULL(value.Number, 0) <= 0;

  /* Število artikov glede na zadnjo objavo (opozorilo). */
  DECLARE @PreviousRows int =
    (SELECT COUNT(DISTINCT ItemID) FROM out.ExportPublishedValue WHERE ProfileCode = @ProfileCode AND OrganizationId = @OrganizationId);
  IF @PreviousRows > 0 AND @RowCount < @PreviousRows * (1 - @RowDrop / 100)
    INSERT #Finding (RuleCode, OldValue, NewValue, ChangeText)
    VALUES (N''ZAL_VRSTICE'', CONVERT(nvarchar(400), @PreviousRows), CONVERT(nvarchar(400), @RowCount),
      CONCAT(CONVERT(decimal(9,1), (@RowCount - @PreviousRows) * 100.0 / @PreviousRows), N'' %''));

  DELETE finding FROM #Finding AS finding
  WHERE NOT EXISTS (SELECT 1 FROM ops.SafeguardRule AS safeguardRule WHERE safeguardRule.RuleCode = finding.RuleCode AND safeguardRule.IsEnabled = 1);

  UPDATE #Finding SET Fingerprint = HASHBYTES(''SHA2_256'', CONCAT(RuleCode, N''|'', ItemID, N''|'', FieldCode, N''|'', OldValue, N''|'',
    CASE WHEN RuleCode = N''ZAL_VRSTICE'' THEN N'''' ELSE NewValue END));
  UPDATE finding SET ApprovalId = approval.SafeguardApprovalId
  FROM #Finding AS finding
  CROSS APPLY (SELECT TOP (1) approval.SafeguardApprovalId FROM ops.SafeguardApproval AS approval
               WHERE approval.AreaCode = @Area AND approval.OrganizationId = @OrganizationId
                 AND approval.Fingerprint = finding.Fingerprint AND approval.ApprovedUtc >= DATEADD(day, -14, @Now)
               ORDER BY approval.ApprovedUtc DESC) AS approval;

  DECLARE @PreviousCheckId bigint = (SELECT MAX(SafeguardCheckId) FROM ops.SafeguardCheck WHERE AreaCode = @Area AND OrganizationId = @OrganizationId);
  UPDATE finding SET RequiresConfirmation = 1
  FROM #Finding AS finding
  INNER JOIN ops.SafeguardRule AS safeguardRule
    ON safeguardRule.RuleCode = finding.RuleCode AND safeguardRule.RequiresConfirmation = 1 AND safeguardRule.CanHold = 1
  WHERE finding.ApprovalId IS NULL AND finding.ItemID IS NOT NULL
    AND ((SELECT COUNT(DISTINCT other.ItemID) FROM #Finding AS other WHERE other.RuleCode = finding.RuleCode) >= safeguardRule.MinCount
         OR EXISTS (SELECT 1 FROM ops.SafeguardFinding AS earlier
                    WHERE earlier.SafeguardCheckId = @PreviousCheckId AND earlier.Fingerprint = finding.Fingerprint AND earlier.RequiresConfirmation = 1));

  CREATE TABLE #Held (ItemID nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY);
  INSERT #Held SELECT DISTINCT ItemID FROM #Finding WHERE RequiresConfirmation = 1 AND ItemID IS NOT NULL;
  DECLARE @HeldCount int = (SELECT COUNT(*) FROM #Held);
  DECLARE @FindingCount int = (SELECT COUNT(*) FROM #Finding);
  DECLARE @ConfirmCount int = (SELECT COUNT(*) FROM #Finding WHERE RequiresConfirmation = 1);
  DECLARE @Status nvarchar(20) = CASE WHEN @HeldCount > 0 THEN N''WAITING'' WHEN @FindingCount > 0 THEN N''WARNED'' ELSE N''CLEAN'' END;
  DECLARE @Headline nvarchar(400) =
    (SELECT LEFT(STRING_AGG(CONVERT(nvarchar(max), CONCAT(safeguardRule.ShortLabel, N'': '',
              CASE WHEN counted.RuleCode = N''ZAL_VRSTICE'' THEN counted.ChangeText ELSE CONVERT(nvarchar(20), counted.Items) END)), N'', '')
            WITHIN GROUP (ORDER BY safeguardRule.SortOrder), 400)
     FROM (SELECT RuleCode, Items = COUNT(DISTINCT ISNULL(ItemID, N''*'')), ChangeText = MAX(ChangeText) FROM #Finding GROUP BY RuleCode) AS counted
     INNER JOIN ops.SafeguardRule AS safeguardRule ON safeguardRule.RuleCode = counted.RuleCode);
  IF @Status = N''WAITING'' SET @Headline = LEFT(CONCAT(N''zadržanih artiklov: '', @HeldCount, N'' ('', @Headline, N'')''), 400);

  /* Odprto čakajoče preverjanje z enakimi nepotrjenimi zadržanimi se osveži. */
  DECLARE @OpenCheckId bigint = (SELECT TOP (1) SafeguardCheckId FROM ops.SafeguardCheck
                                 WHERE AreaCode = @Area AND OrganizationId = @OrganizationId AND Status = N''WAITING'' ORDER BY SafeguardCheckId DESC);
  DECLARE @CheckId bigint = NULL;
  IF @OpenCheckId IS NOT NULL AND @Status = N''WAITING''
     AND NOT EXISTS (SELECT Fingerprint FROM #Finding WHERE RequiresConfirmation = 1
                     EXCEPT SELECT Fingerprint FROM ops.SafeguardFinding WHERE SafeguardCheckId = @OpenCheckId AND RequiresConfirmation = 1)
     AND NOT EXISTS (SELECT finding.Fingerprint FROM ops.SafeguardFinding AS finding
                     WHERE finding.SafeguardCheckId = @OpenCheckId AND finding.RequiresConfirmation = 1
                       AND NOT EXISTS (SELECT 1 FROM ops.SafeguardApproval AS approval
                                       WHERE approval.AreaCode = @Area AND approval.OrganizationId = @OrganizationId
                                         AND approval.Fingerprint = finding.Fingerprint AND approval.ApprovedUtc >= DATEADD(day, -14, @Now))
                     EXCEPT SELECT Fingerprint FROM #Finding WHERE RequiresConfirmation = 1)
  BEGIN
    UPDATE ops.SafeguardCheck SET RowCountValue = @RowCount, EvaluationCount = EvaluationCount + 1, LastEvaluatedUtc = @Now
    WHERE SafeguardCheckId = @OpenCheckId;
    SET @CheckId = @OpenCheckId;
  END
  ELSE
  BEGIN
    BEGIN TRANSACTION;
    INSERT ops.SafeguardCheck (AreaCode, OrganizationId, Status, SubjectLabel, RowCountValue, PreviousPublishedRows, FindingCount,
      ConfirmCount, HeldCount, Headline, CreatedUtc, LastEvaluatedUtc, CreatedBy)
    VALUES (@Area, @OrganizationId, @Status, N''cene in zaloga'', @RowCount, NULLIF(@PreviousRows, 0), @FindingCount, @ConfirmCount,
      @HeldCount, @Headline, @Now, @Now, @Actor);
    SET @CheckId = SCOPE_IDENTITY();
    UPDATE ops.SafeguardCheck SET Status = N''SUPERSEDED'', SupersededByCheckId = @CheckId
    WHERE AreaCode = @Area AND OrganizationId = @OrganizationId AND Status = N''WAITING'' AND SafeguardCheckId <> @CheckId;
    INSERT ops.SafeguardFinding (SafeguardCheckId, RuleCode, ItemID, ProductId, FieldCode, FieldLabel, OldValue, NewValue, ChangeText,
      RequiresConfirmation, ApprovalId, Fingerprint)
    SELECT @CheckId, finding.RuleCode, finding.ItemID, product.ProductId, finding.FieldCode,
      CASE finding.FieldCode WHEN N''Product.PriceB2B'' THEN N''Cena B2B'' WHEN N''Product.PriceB2C'' THEN N''Cena B2C''
                             WHEN N''Stock.ErpAvailable'' THEN N''Razpoložljiva zaloga'' ELSE finding.FieldCode END,
      finding.OldValue, finding.NewValue, finding.ChangeText, finding.RequiresConfirmation, finding.ApprovalId, finding.Fingerprint
    FROM #Finding AS finding
    LEFT JOIN canon.Product AS product ON product.OrganizationId = @OrganizationId AND product.ItemID = finding.ItemID;
    COMMIT;
  END;

  DECLARE @DedupKey varchar(64) = CONVERT(varchar(64), HASHBYTES(''SHA2_256'', CONCAT(N''SafeguardPending|'', @Area, N''|'', @OrganizationId)), 2);
  IF @Status = N''WAITING''
  BEGIN
    DECLARE @Title nvarchar(300) = LEFT(CONCAT(N''Cene in zaloga za splet: '', @Headline), 300);
    EXEC ops.UpsertAlert @OrganizationId = @OrganizationId, @Pipeline = N''VAROVALKA:ZALOGA_CSV'', @AlertKind = N''SafeguardPending'',
      @Severity = N''Warning'', @DedupKey = @DedupKey, @Title = @Title,
      @PayloadSummaryRedacted = N''Zadržani artikli niso v datoteki cen in zaloge — na spletu ostanejo s prejšnjo ceno in zalogo, dokler jih ne potrdiš ali popraviš (Varovalke).'',
      @Actor = @Actor;
  END
  ELSE
    UPDATE ops.Alert SET ResolvedUtc = @Now, ResolvedBy = N''SISTEM'', UpdatedUtc = @Now, UpdatedBy = N''SISTEM''
    WHERE OrganizationId = @OrganizationId AND DedupKey = @DedupKey AND ResolvedUtc IS NULL;

  /* Čiščenje kot pri katalog.csv. */
  DELETE finding FROM ops.SafeguardFinding AS finding
  INNER JOIN ops.SafeguardCheck AS safeguardCheck ON safeguardCheck.SafeguardCheckId = finding.SafeguardCheckId
  WHERE safeguardCheck.AreaCode = @Area
    AND ((safeguardCheck.Status = N''SUPERSEDED'' AND safeguardCheck.LastEvaluatedUtc < DATEADD(day, -2, @Now))
      OR (safeguardCheck.Status IN (N''CLEAN'', N''WARNED'') AND safeguardCheck.CreatedUtc < DATEADD(day, -7, @Now)));
  DELETE ops.SafeguardCheck WHERE AreaCode = @Area AND Status IN (N''CLEAN'', N''SUPERSEDED'') AND CreatedUtc < DATEADD(day, -7, @Now);

  SELECT SafeguardCheckId = @CheckId, Status = @Status, FindingCount = @FindingCount, ConfirmCount = @ConfirmCount,
    Headline = @Headline, HeldCount = @HeldCount;
  SELECT ItemID FROM #Held ORDER BY ItemID;
END;');

/* --- 5) Po objavi: izhodišče za naslednjo primerjavo --------------------------------------------------- */
EXEC(N'CREATE OR ALTER PROCEDURE out.RecordExportPublication
  @ProfileCode nvarchar(100),
  @OrganizationId int,
  @RowsJson nvarchar(max),              /* samo objavljene vrstice (brez zadržanih) */
  @SafeguardCheckId bigint = NULL,
  @HeldItemsJson nvarchar(max) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  /* 282: objavljene vrednosti postanejo izhodišče; zadržani artikli obdržijo prejšnje (v datoteki jih ni bilo).
     Artikel, ki ga v datoteki ni več, izgine iz izhodišča — ob vrnitvi se primerja kot nov (brez ugotovitve). */
  DECLARE @Now datetime2(3) = SYSUTCDATETIME();
  CREATE TABLE #Held (ItemID nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY);
  IF ISJSON(@HeldItemsJson) = 1 INSERT #Held SELECT DISTINCT value FROM OPENJSON(@HeldItemsJson) WHERE value IS NOT NULL;
  CREATE TABLE #Value (ItemID nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL, FieldCode nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL,
    Value nvarchar(400) COLLATE DATABASE_DEFAULT NULL, PRIMARY KEY (ItemID, FieldCode));
  INSERT #Value (ItemID, FieldCode, Value)
  SELECT parsed.i, LEFT(field.[key], 200), MAX(LEFT(NULLIF(LTRIM(RTRIM(field.value)), N''''), 400))
  FROM OPENJSON(@RowsJson) WITH (i nvarchar(100) N''$.i'', v nvarchar(max) N''$.v'' AS JSON) AS parsed
  CROSS APPLY OPENJSON(parsed.v) AS field
  WHERE NULLIF(LTRIM(RTRIM(parsed.i)), N'''') IS NOT NULL AND parsed.i NOT IN (SELECT ItemID FROM #Held)
  GROUP BY parsed.i, LEFT(field.[key], 200);

  BEGIN TRANSACTION;
  DELETE published FROM out.ExportPublishedValue AS published
  WHERE published.ProfileCode = @ProfileCode AND published.OrganizationId = @OrganizationId
    AND published.ItemID NOT IN (SELECT ItemID FROM #Held)
    AND NOT EXISTS (SELECT 1 FROM #Value AS value WHERE value.ItemID = published.ItemID AND value.FieldCode = published.FieldCode);
  MERGE out.ExportPublishedValue AS target
  USING (SELECT ItemID, FieldCode, Value FROM #Value) AS source
  ON target.ProfileCode = @ProfileCode AND target.OrganizationId = @OrganizationId AND target.ItemID = source.ItemID AND target.FieldCode = source.FieldCode
  WHEN MATCHED AND ISNULL(target.Value, N''<prazno>'') <> ISNULL(source.Value, N''<prazno>'') THEN UPDATE SET Value = source.Value, PublishedUtc = @Now
  WHEN NOT MATCHED THEN INSERT (ProfileCode, OrganizationId, ItemID, FieldCode, Value, PublishedUtc)
    VALUES (@ProfileCode, @OrganizationId, source.ItemID, source.FieldCode, source.Value, @Now);
  IF @SafeguardCheckId IS NOT NULL
    UPDATE ops.SafeguardCheck SET PublishedUtc = @Now, PublishedRows = (SELECT COUNT(DISTINCT ItemID) FROM #Value)
    WHERE SafeguardCheckId = @SafeguardCheckId;
  COMMIT;
END;');
