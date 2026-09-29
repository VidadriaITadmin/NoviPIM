/*
  283 — Varovalka zaloge virov (datoteke dobaviteljev NW_STOCK, BT_STOCK in zajem zaloge iz SAOP).

  Uporabnik 2026-09-24: »dej mi še ostale varovalke notri« (predlog: vir nenadoma prinese veliko manj artiklov ali
  prazno zalogo). Nov posnetek zaloge v celoti nadomesti prejšnjega (stock.Snapshot.IsActive) — artikel, ki ga v
  datoteki ni, nima več zaloge. Okrnjena ali prazna datoteka (napaka pri dobavitelju, prekinjen prenos, SAOP vrne
  prazno) bi tako čez noč pobrala zalogo vsem artiklom vira, na spletu in na kartici.

  Kako deluje: StockLandingWriter pred zapisom pokliče ops.EvaluateStockFeedSafeguards s številom vrstic in številom
  vrstic z zalogo > 0. Če je padec prevelik, posnetek NI zapisan: velja prejšnji (zadnji dober) posnetek, v zvoncu je
  opozorilo, na /varovalke preverjanje z vzrokom. Ko uporabnik potrdi (npr. dobavitelj je res umaknil pol programa),
  naslednji zajem iste datoteke posnetek zapiše. Posel se ne ustavi (faza ZAPIS je preskočena z razlogom).

  Pravila (področje ZALOGA_VIR):
    ZALV_VRSTICE  artiklov v novem posnetku je za več kot prag (30 %) manj kot v veljavnem
    ZALV_NIC      artiklov z zalogo > 0 je za več kot prag (50 %) manj kot v veljavnem (vsaj 20 v veljavnem)

  Objekti: ops.EvaluateStockFeedSafeguards, pravila v ops.SafeguardRule. Potrebuje 277.
  Ročni korak: ne. Migrator ne pozna GO, zato CREATE OR ALTER v EXEC(N'...').
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

IF UNICODE(N'č') <> 269
  THROW 52960, N'283: datoteka ni prebrana kot UTF-8 (sqlcmd -f 65001 ali Invoke-PendingMigrations.ps1).', 1;
IF OBJECT_ID(N'ops.SafeguardRule', N'U') IS NULL THROW 52961, N'283 potrebuje migracijo 277.', 1;

MERGE ops.SafeguardRule AS target
USING (VALUES
  (N'ZALV_VRSTICE', N'Vir zaloge prinese veliko manj artiklov', N'manj artiklov v viru',
   N'Nova datoteka (ali zajem iz SAOP) ima bistveno manj artiklov kot veljavni posnetek. Ker nov posnetek nadomesti '
     + N'starega, bi artikli, ki jih ni, izgubili zalogo.',
   N'Preveri datoteko vira (prenos, dobavitelj). Če je res (dobavitelj je umaknil artikle), potrdi — naslednji zajem jo uporabi.',
   CONVERT(decimal(19,4), 30), N'padec v %', 10),
  (N'ZALV_NIC', N'Vir zaloge: veliko artiklov naenkrat brez zaloge', N'zaloga vira na 0',
   N'V novem posnetku ima bistveno manj artiklov zalogo večjo od 0 kot v veljavnem — pogosto znak prazne ali napačne datoteke.',
   N'Preveri datoteko vira. Če je res, potrdi — naslednji zajem jo uporabi.', CONVERT(decimal(19,4), 50), N'padec v %', 20)
) AS source (RuleCode, Title, ShortLabel, Explanation, WhatToDo, ThresholdValue, ThresholdLabel, SortOrder)
ON target.RuleCode = source.RuleCode
WHEN MATCHED THEN UPDATE SET Title = source.Title, ShortLabel = source.ShortLabel, Explanation = source.Explanation,
  WhatToDo = source.WhatToDo, ThresholdLabel = source.ThresholdLabel, SortOrder = source.SortOrder
WHEN NOT MATCHED THEN INSERT (RuleCode, AreaCode, Title, ShortLabel, Explanation, WhatToDo, RequiresConfirmation, CanHold,
    IsInformational, IsEnabled, ThresholdValue, ThresholdLabel, MinCount, SortOrder, UpdatedUtc, UpdatedBy)
  VALUES (source.RuleCode, N'ZALOGA_VIR', source.Title, source.ShortLabel, source.Explanation, source.WhatToDo, 1, 1, 0, 1,
    source.ThresholdValue, source.ThresholdLabel, 1, source.SortOrder, SYSUTCDATETIME(), N'migracija 283');

EXEC(N'CREATE OR ALTER PROCEDURE ops.EvaluateStockFeedSafeguards
  @OrganizationId int,
  @SourceConnectorId int,
  @SourceCode nvarchar(100),
  @RecordCount int,
  @WithQuantity int,          /* vrstice z zalogo > 0 v novem posnetku */
  @Actor nvarchar(200) = N''PIM.StockMapping''
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  /* 283: nov posnetek zaloge vira proti veljavnemu (stock.Snapshot.IsActive). Vrne Hold = 1, če posnetka ne smemo
     zapisati, dokler kdo ne potrdi; Reason je en stavek za fazo ZAPIS in konzolo. */
  DECLARE @Area nvarchar(50) = N''ZALOGA_VIR'';
  DECLARE @Now datetime2(3) = SYSUTCDATETIME();
  DECLARE @PreviousRecords int, @PreviousWithQuantity int;
  SELECT TOP (1) @PreviousRecords = run.RecordsRead,
    @PreviousWithQuantity = (SELECT COUNT(*) FROM stock.Position AS position
                             WHERE position.SnapshotId = snapshot.SnapshotId
                               AND COALESCE(position.AvailableQuantity, position.Quantity) > 0)
  FROM stock.Snapshot AS snapshot
  INNER JOIN stock.SyncRun AS run ON run.SyncRunId = snapshot.SyncRunId
  WHERE snapshot.OrganizationId = @OrganizationId AND snapshot.SourceConnectorId = @SourceConnectorId AND snapshot.IsActive = 1
  ORDER BY snapshot.SnapshotId DESC;

  CREATE TABLE #Finding (RuleCode nvarchar(50) COLLATE DATABASE_DEFAULT NOT NULL, OldValue nvarchar(400) COLLATE DATABASE_DEFAULT,
    NewValue nvarchar(400) COLLATE DATABASE_DEFAULT, ChangeText nvarchar(100) COLLATE DATABASE_DEFAULT,
    RequiresConfirmation bit NOT NULL DEFAULT (0), ApprovalId bigint NULL, Fingerprint varbinary(32) NULL);

  IF @PreviousRecords > 0
  BEGIN
    DECLARE @RowsDrop decimal(19,4) = ISNULL((SELECT ThresholdValue FROM ops.SafeguardRule WHERE RuleCode = N''ZALV_VRSTICE'' AND IsEnabled = 1), -1);
    DECLARE @ZeroDrop decimal(19,4) = ISNULL((SELECT ThresholdValue FROM ops.SafeguardRule WHERE RuleCode = N''ZALV_NIC'' AND IsEnabled = 1), -1);
    IF @RowsDrop >= 0 AND @RecordCount < @PreviousRecords * (1 - @RowsDrop / 100)
      INSERT #Finding (RuleCode, OldValue, NewValue, ChangeText)
      VALUES (N''ZALV_VRSTICE'', CONVERT(nvarchar(20), @PreviousRecords), CONVERT(nvarchar(20), @RecordCount),
        LEFT(CONCAT(CONVERT(decimal(9,1), (@RecordCount - @PreviousRecords) * 100.0 / @PreviousRecords), N'' % · '', @SourceCode), 100));
    IF @ZeroDrop >= 0 AND @PreviousWithQuantity >= 20 AND @WithQuantity < @PreviousWithQuantity * (1 - @ZeroDrop / 100)
      INSERT #Finding (RuleCode, OldValue, NewValue, ChangeText)
      VALUES (N''ZALV_NIC'', CONVERT(nvarchar(20), @PreviousWithQuantity), CONVERT(nvarchar(20), @WithQuantity),
        LEFT(CONCAT(CONVERT(decimal(9,1), (@WithQuantity - @PreviousWithQuantity) * 100.0 / @PreviousWithQuantity), N'' % z zalogo · '', @SourceCode), 100));
  END;

  /* Potrditev velja za ta posnetek (vir, število vrstic, število z zalogo) — ista datoteka gre ob naslednjem zajemu skozi. */
  UPDATE #Finding SET Fingerprint = HASHBYTES(''SHA2_256'', CONCAT(RuleCode, N''|'', @SourceCode, N''|'', @RecordCount, N''|'', @WithQuantity));
  UPDATE finding SET ApprovalId = approval.SafeguardApprovalId
  FROM #Finding AS finding
  CROSS APPLY (SELECT TOP (1) approval.SafeguardApprovalId FROM ops.SafeguardApproval AS approval
               WHERE approval.AreaCode = @Area AND approval.OrganizationId = @OrganizationId
                 AND approval.Fingerprint = finding.Fingerprint AND approval.ApprovedUtc >= DATEADD(day, -14, @Now)
               ORDER BY approval.ApprovedUtc DESC) AS approval;
  UPDATE finding SET RequiresConfirmation = 1
  FROM #Finding AS finding
  INNER JOIN ops.SafeguardRule AS safeguardRule ON safeguardRule.RuleCode = finding.RuleCode AND safeguardRule.RequiresConfirmation = 1
  WHERE finding.ApprovalId IS NULL;

  DECLARE @Hold bit = CASE WHEN EXISTS (SELECT 1 FROM #Finding WHERE RequiresConfirmation = 1) THEN 1 ELSE 0 END;
  DECLARE @Headline nvarchar(400) =
    (SELECT LEFT(STRING_AGG(CONVERT(nvarchar(max), CONCAT(safeguardRule.ShortLabel, N'': '', finding.OldValue, N'' → '', finding.NewValue)), N'', ''), 400)
     FROM #Finding AS finding INNER JOIN ops.SafeguardRule AS safeguardRule ON safeguardRule.RuleCode = finding.RuleCode);
  DECLARE @OpenCheckId bigint = (SELECT TOP (1) SafeguardCheckId FROM ops.SafeguardCheck
                                 WHERE AreaCode = @Area AND OrganizationId = @OrganizationId AND SubjectLabel = @SourceCode AND Status = N''WAITING''
                                 ORDER BY SafeguardCheckId DESC);
  DECLARE @CheckId bigint = NULL;
  DECLARE @DedupKey varchar(64) = CONVERT(varchar(64), HASHBYTES(''SHA2_256'', CONCAT(N''SafeguardPending|'', @Area, N''|'', @OrganizationId)), 2);

  IF @Hold = 1
  BEGIN
    IF @OpenCheckId IS NOT NULL
       AND NOT EXISTS (SELECT Fingerprint FROM #Finding WHERE RequiresConfirmation = 1
                       EXCEPT SELECT Fingerprint FROM ops.SafeguardFinding WHERE SafeguardCheckId = @OpenCheckId)
    BEGIN
      UPDATE ops.SafeguardCheck SET EvaluationCount = EvaluationCount + 1, LastEvaluatedUtc = @Now WHERE SafeguardCheckId = @OpenCheckId;
      SET @CheckId = @OpenCheckId;
    END
    ELSE
    BEGIN
      BEGIN TRANSACTION;
      INSERT ops.SafeguardCheck (AreaCode, OrganizationId, Status, SubjectLabel, RowCountValue, PreviousPublishedRows, FindingCount,
        ConfirmCount, HeldCount, Headline, CreatedUtc, LastEvaluatedUtc, CreatedBy)
      VALUES (@Area, @OrganizationId, N''WAITING'', @SourceCode, @RecordCount, @PreviousRecords,
        (SELECT COUNT(*) FROM #Finding), (SELECT COUNT(*) FROM #Finding WHERE RequiresConfirmation = 1), 0, @Headline, @Now, @Now, @Actor);
      SET @CheckId = SCOPE_IDENTITY();
      UPDATE ops.SafeguardCheck SET Status = N''SUPERSEDED'', SupersededByCheckId = @CheckId
      WHERE AreaCode = @Area AND OrganizationId = @OrganizationId AND SubjectLabel = @SourceCode AND Status = N''WAITING'' AND SafeguardCheckId <> @CheckId;
      INSERT ops.SafeguardFinding (SafeguardCheckId, RuleCode, FieldCode, FieldLabel, OldValue, NewValue, ChangeText, SiteLabel,
        RequiresConfirmation, ApprovalId, Fingerprint)
      SELECT @CheckId, RuleCode, N''Stock.Records'', N''artiklov v posnetku'', OldValue, NewValue, ChangeText, @SourceCode,
        RequiresConfirmation, ApprovalId, Fingerprint
      FROM #Finding;
      COMMIT;
    END;
    DECLARE @Title nvarchar(300) = LEFT(CONCAT(N''Zaloga vira '', @SourceCode, N'': nov posnetek ni uporabljen — '', @Headline), 300);
    EXEC ops.UpsertAlert @OrganizationId = @OrganizationId, @Pipeline = N''VAROVALKA:ZALOGA_VIR'', @AlertKind = N''SafeguardPending'',
      @Severity = N''Warning'', @DedupKey = @DedupKey, @Title = @Title,
      @PayloadSummaryRedacted = N''Velja zadnji dober posnetek zaloge tega vira. Preveri datoteko; če je prav, potrdi na Varovalkah — naslednji zajem jo uporabi.'',
      @Actor = @Actor;
  END
  ELSE
  BEGIN
    IF @OpenCheckId IS NOT NULL
      UPDATE ops.SafeguardCheck
      SET Status = CASE WHEN EXISTS (SELECT 1 FROM #Finding WHERE ApprovalId IS NOT NULL) THEN N''CONFIRMED'' ELSE N''SUPERSEDED'' END,
          DecidedUtc = ISNULL(DecidedUtc, @Now), DecidedBy = ISNULL(DecidedBy, @Actor), LastEvaluatedUtc = @Now
      WHERE SafeguardCheckId = @OpenCheckId;
    UPDATE ops.Alert SET ResolvedUtc = @Now, ResolvedBy = N''SISTEM'', UpdatedUtc = @Now, UpdatedBy = N''SISTEM''
    WHERE OrganizationId = @OrganizationId AND DedupKey = @DedupKey AND ResolvedUtc IS NULL;
  END;

  SELECT Hold = @Hold, Reason = CASE WHEN @Hold = 1 THEN CONCAT(N''zadržano (varovalka): '', @Headline, N'' — velja prejšnji posnetek, potrdi na Varovalkah'') END,
    SafeguardCheckId = @CheckId;
END;');
