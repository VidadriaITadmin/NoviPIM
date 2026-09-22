/*
  256 — viri po poslih in svežina podatkov (blok 4 prenove nadzora).

  Uporabnik 2026-09-22: zelena lučka mora pomeniti »podatki so prišli«, ne »proces se je končal brez
  napake«. Blok 2 in 3 sta dala faze (ops.JobPhaseRun); ta migracija pove, KATERE vire posel prinaša
  in KOLIKO smejo biti stari. Katalog virov je v kodi (JobCatalog.All[*].Sources), gostitelj ga ob
  zagonu uskladi v ops.JobSource (ops.EnsureJobSource); tu so isti podatki zasejani, da stran in
  alarmi delujejo že pred ponovnim zagonom gostitelja.

  Dve meri na vir:
    - stik: zadnja uspešna faza (podatki so bili preverjeni, tudi če se niso spremenili);
    - novi podatki: zadnja uspešna faza s HasNewData = 1.
  Kateri šteje, pove JobSource.MeasureNewData: zaloga se meri po novih podatkih (Braytron je pet dni
  vračal isto datoteko), cene in artikli po stiku (tedni brez spremembe cene so normalni).

  Stanje vira (ops.JobSourceState):
    Fresh    — merilo je znotraj MaxAgeSeconds;
    Stale    — merilo je starejše od MaxAgeSeconds ali ga še ni, čeprav je vir v bazi dlje od meje;
    Failed   — zadnji poskus je padel (zadnja padla faza je novejša od zadnje uspešne);
    Unknown  — vir je nov, faz še ni, meja še ni potekla.
  Stale odpre alarm SourceStale (Critical) v ops.EvaluateJobAlerts; Fresh ga zapre. Failed nima
  svojega alarma: padec koraka javlja JobFailed, faza pa je rdeča na strani.

  Kaj naredi:
    1. ops.JobSource, ops.EnsureJobSource, ops.RetireJobSources.
    2. ops.JobSourceState() — tabelarična funkcija za stran Nadzor in alarme; intranet.GetJobSourceState.
    3. ops.EvaluateJobAlerts z alarmom SourceStale (ostalo kot v 247, brez zapiranja CycleOverdue — 254).
    4. SourceStale med dovoljene vrste naročnin; skrbniki nanj naročeni kot na JobFailed.
    5. Seme virov (isti seznam kot JobCatalog.cs).
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

IF OBJECT_ID(N'ops.JobPhaseRun', N'U') IS NULL
  THROW 52560, N'256: ops.JobPhaseRun ne obstaja (najprej migracija 255).', 1;

/* ── 1. Viri poslov ─────────────────────────────────────────────────────────────── */
IF OBJECT_ID(N'ops.JobSource', N'U') IS NULL
BEGIN
  CREATE TABLE ops.JobSource
  (
    JobKey nvarchar(60) NOT NULL CONSTRAINT FK_JobSource_Job REFERENCES ops.JobDefinition (JobKey),
    Pipeline nvarchar(100) NOT NULL,
    SourceCode nvarchar(100) NOT NULL,
    Label nvarchar(120) NOT NULL,
    MaxAgeSeconds int NOT NULL,
    PerOrganization bit NOT NULL CONSTRAINT DF_JobSource_PerOrganization DEFAULT (1),
    MeasureNewData bit NOT NULL CONSTRAINT DF_JobSource_MeasureNewData DEFAULT (0),
    SortOrder int NOT NULL CONSTRAINT DF_JobSource_SortOrder DEFAULT (0),
    IsActive bit NOT NULL CONSTRAINT DF_JobSource_IsActive DEFAULT (1),
    CreatedUtc datetime2(3) NOT NULL CONSTRAINT DF_JobSource_CreatedUtc DEFAULT (SYSUTCDATETIME()),
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_JobSource_UpdatedUtc DEFAULT (SYSUTCDATETIME()),
    UpdatedBy nvarchar(200) NULL,
    CONSTRAINT PK_JobSource PRIMARY KEY (JobKey, Pipeline, SourceCode),
    CONSTRAINT CK_JobSource_MaxAge CHECK (MaxAgeSeconds >= 60)
  );
END;

EXEC(N'CREATE OR ALTER PROCEDURE ops.EnsureJobSource
  @JobKey nvarchar(60), @SourceCode nvarchar(100), @Pipeline nvarchar(100), @Label nvarchar(120),
  @MaxAgeSeconds int, @PerOrganization bit = 1, @MeasureNewData bit = 0, @SortOrder int = 0,
  @Actor nvarchar(200) = N''ops.EnsureJobSource''
AS
BEGIN
  SET NOCOUNT ON;
  IF NOT EXISTS (SELECT 1 FROM ops.JobDefinition WHERE JobKey = @JobKey) RETURN;
  MERGE ops.JobSource AS target
  USING (SELECT @JobKey AS JobKey, @Pipeline AS Pipeline, @SourceCode AS SourceCode) AS source
    ON target.JobKey = source.JobKey AND target.Pipeline = source.Pipeline AND target.SourceCode = source.SourceCode
  WHEN MATCHED AND (target.Label <> @Label OR target.MaxAgeSeconds <> @MaxAgeSeconds OR target.PerOrganization <> @PerOrganization
                    OR target.MeasureNewData <> @MeasureNewData OR target.SortOrder <> @SortOrder OR target.IsActive = 0) THEN
    UPDATE SET Label = @Label, MaxAgeSeconds = @MaxAgeSeconds, PerOrganization = @PerOrganization, MeasureNewData = @MeasureNewData,
               SortOrder = @SortOrder, IsActive = 1, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = @Actor
  WHEN NOT MATCHED THEN
    INSERT (JobKey, Pipeline, SourceCode, Label, MaxAgeSeconds, PerOrganization, MeasureNewData, SortOrder, UpdatedBy)
    VALUES (@JobKey, @Pipeline, @SourceCode, @Label, @MaxAgeSeconds, @PerOrganization, @MeasureNewData, @SortOrder, @Actor);
END');

/* Viri, ki jih koda ne našteje več, se izklopijo (ne izbrišejo): zgodovina faz ostane berljiva. */
EXEC(N'CREATE OR ALTER PROCEDURE ops.RetireJobSources @JobKey nvarchar(60), @KeepSourceCodes nvarchar(max), @Actor nvarchar(200) = N''ops.RetireJobSources''
AS
BEGIN
  SET NOCOUNT ON;
  UPDATE js SET IsActive = 0, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = @Actor
  FROM ops.JobSource js
  WHERE js.JobKey = @JobKey AND js.IsActive = 1
    AND NOT EXISTS (SELECT 1 FROM STRING_SPLIT(COALESCE(@KeepSourceCodes, N''''), N'','') keep
                    WHERE keep.value = CONCAT(js.Pipeline, N''|'', js.SourceCode));
END');

/* ── 2. Stanje virov ────────────────────────────────────────────────────────────── */
IF OBJECT_ID(N'ops.JobSourceState', N'IF') IS NOT NULL DROP FUNCTION ops.JobSourceState;
EXEC(N'CREATE FUNCTION ops.JobSourceState()
RETURNS TABLE
AS
RETURN
WITH podjetja AS
(
  SELECT o.OrganizationId, o.Name
  FROM dbo.OrganizationConfig o
  LEFT JOIN ops.OrganizationAutomationPolicy p ON p.OrganizationId = o.OrganizationId
  WHERE o.IsActive = 1 AND COALESCE(p.IsEnabled, CONVERT(bit, 1)) = 1
),
viri AS
(
  SELECT js.JobKey, js.Pipeline, js.SourceCode, js.Label, js.MaxAgeSeconds, js.PerOrganization, js.MeasureNewData, js.SortOrder, js.CreatedUtc,
         OrganizationId = CASE WHEN js.PerOrganization = 1 THEN podjetje.OrganizationId END,
         OrganizationName = CASE WHEN js.PerOrganization = 1 THEN podjetje.Name END
  FROM ops.JobSource js
  LEFT JOIN podjetja podjetje ON js.PerOrganization = 1
  WHERE js.IsActive = 1 AND (js.PerOrganization = 0 OR podjetje.OrganizationId IS NOT NULL)
),
faze AS
(
  SELECT v.JobKey, v.Pipeline, v.SourceCode, v.OrganizationId,
         LastContactUtc = MAX(CASE WHEN f.Status = N''Succeeded'' THEN COALESCE(f.EndedUtc, f.StartedUtc) END),
         LastNewDataUtc = MAX(CASE WHEN f.Status = N''Succeeded'' AND f.HasNewData = 1 THEN COALESCE(f.EndedUtc, f.StartedUtc) END),
         LastFailureUtc = MAX(CASE WHEN f.Status = N''Failed'' THEN COALESCE(f.EndedUtc, f.StartedUtc) END),
         LastPhaseId = MAX(f.JobPhaseRunId)
  FROM viri v
  INNER JOIN ops.JobPhaseRun f ON f.Pipeline = v.Pipeline AND f.SourceCode = v.SourceCode
    AND (v.OrganizationId IS NULL OR f.OrganizationId = v.OrganizationId)
  GROUP BY v.JobKey, v.Pipeline, v.SourceCode, v.OrganizationId
)
SELECT v.JobKey, v.Pipeline, v.SourceCode, v.Label, v.OrganizationId, v.OrganizationName, v.MaxAgeSeconds, v.MeasureNewData, v.SortOrder,
       f.LastContactUtc, f.LastNewDataUtc, f.LastFailureUtc,
       BasisUtc = CASE WHEN v.MeasureNewData = 1 THEN f.LastNewDataUtc ELSE f.LastContactUtc END,
       LastMessage = zadnja.Message, LastStatus = zadnja.Status, LastPhaseCode = zadnja.PhaseCode,
       LastItemsOut = zadnja.ItemsOut, LastItemsRejected = zadnja.ItemsRejected,
       State = CASE
         WHEN f.LastFailureUtc IS NOT NULL AND (f.LastContactUtc IS NULL OR f.LastFailureUtc > f.LastContactUtc) THEN N''Failed''
         WHEN CASE WHEN v.MeasureNewData = 1 THEN f.LastNewDataUtc ELSE f.LastContactUtc END IS NULL
           THEN CASE WHEN v.CreatedUtc < DATEADD(second, -v.MaxAgeSeconds, SYSUTCDATETIME()) THEN N''Stale'' ELSE N''Unknown'' END
         WHEN CASE WHEN v.MeasureNewData = 1 THEN f.LastNewDataUtc ELSE f.LastContactUtc END < DATEADD(second, -v.MaxAgeSeconds, SYSUTCDATETIME()) THEN N''Stale''
         ELSE N''Fresh'' END
FROM viri v
LEFT JOIN faze f ON f.JobKey = v.JobKey AND f.Pipeline = v.Pipeline AND f.SourceCode = v.SourceCode
  AND ((f.OrganizationId IS NULL AND v.OrganizationId IS NULL) OR f.OrganizationId = v.OrganizationId)
OUTER APPLY (SELECT TOP (1) p.Message, p.Status, p.PhaseCode, p.ItemsOut, p.ItemsRejected FROM ops.JobPhaseRun p WHERE p.JobPhaseRunId = f.LastPhaseId) zadnja;');

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetJobSourceState @JobKey nvarchar(60) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SELECT JobKey, Pipeline, SourceCode, Label, OrganizationId, OrganizationName, MaxAgeSeconds, MeasureNewData, SortOrder,
         LastContactUtc, LastNewDataUtc, LastFailureUtc, BasisUtc, LastMessage, LastStatus, LastPhaseCode, LastItemsOut, LastItemsRejected, State,
         AgeSeconds = CASE WHEN BasisUtc IS NULL THEN NULL ELSE DATEDIFF(second, BasisUtc, SYSUTCDATETIME()) END
  FROM ops.JobSourceState()
  WHERE @JobKey IS NULL OR JobKey = @JobKey
  ORDER BY JobKey, SortOrder, SourceCode, OrganizationId;
END');

/* ── 3. Alarmi poslov z zastarelim virom ────────────────────────────────────────── */
EXEC(N'CREATE OR ALTER PROCEDURE ops.EvaluateJobAlerts @Actor nvarchar(200) = N''gostitelj avtomatike''
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  DECLARE @now datetime2(3) = SYSUTCDATETIME();
  DECLARE @org int = (
    SELECT MIN(o.OrganizationId) FROM dbo.OrganizationConfig o
    LEFT JOIN ops.OrganizationAutomationPolicy p ON p.OrganizationId = o.OrganizationId
    WHERE o.IsActive = 1 AND COALESCE(p.IsEnabled, CONVERT(bit, 1)) = 1);
  IF @org IS NULL RETURN;

  DECLARE @alarmi TABLE (AlertKind nvarchar(60), Severity nvarchar(20), Pipeline nvarchar(200), DedupKey varchar(64), Title nvarchar(300), Summary nvarchar(2000));

  /* Zaostanek (247): posel, katerega termin je minil za več kot (WarnAfterMultiplier - 1) × razmik in ne teče. */
  INSERT @alarmi (AlertKind, Severity, Pipeline, DedupKey, Title, Summary)
  SELECT N''JobOverdue'', N''Critical'', CONCAT(N''OPRAVILO:'', j.JobKey),
         CONVERT(varchar(64), HASHBYTES(''SHA2_256'', CONCAT(N''JobOverdue:'', j.JobKey)), 2),
         CONCAT(N''Posel "'', j.Label, N''" zamuja '', DATEDIFF(minute, j.NextDueUtc, @now), N'' min čez termin (razmik '',
                CASE WHEN j.IntervalSeconds IS NULL THEN N''1 dan'' ELSE CONCAT(j.IntervalSeconds / 60, N'' min'') END, N'').''),
         CONCAT(N''Termin: '', CONVERT(nvarchar(19), j.NextDueUtc, 120), N'' UTC. Zadnji začetek: '', COALESCE(CONVERT(nvarchar(19), j.LastStartedUtc, 120), N''nikoli''),
                N'' UTC. Preveri gostitelja avtomatike na /sistem/opravila.'')
  FROM ops.JobDefinition j
  WHERE j.IsEnabled = 1 AND j.RunningJobRunId IS NULL AND j.NextDueUtc IS NOT NULL AND j.NextDueUtc < @now
    AND DATEDIFF(second, j.NextDueUtc, @now) > (j.WarnAfterMultiplier - 1.0) * COALESCE(j.IntervalSeconds, 86400);

  /* Padec: zadnji zagon Failed, TimedOut ali Abandoned. */
  INSERT @alarmi (AlertKind, Severity, Pipeline, DedupKey, Title, Summary)
  SELECT N''JobFailed'', CASE WHEN j.IsFlowResult = 1 THEN N''Critical'' ELSE N''Warning'' END, CONCAT(N''OPRAVILO:'', j.JobKey),
         CONVERT(varchar(64), HASHBYTES(''SHA2_256'', CONCAT(N''JobFailed:'', j.JobKey)), 2),
         CONCAT(N''Posel "'', j.Label, N''" se je končal s stanjem '', j.LastStatus, N''.''),
         CONCAT(COALESCE(LEFT(j.LastError, 1500), N''Brez opisa napake.''), N'' Zadnji uspeh: '', COALESCE(CONVERT(nvarchar(19), j.LastSucceededUtc, 120), N''nikoli''), N'' UTC.'')
  FROM ops.JobDefinition j
  WHERE j.IsEnabled = 1 AND j.LastStatus IN (N''Failed'', N''TimedOut'', N''Abandoned'');

  /* Blokada: odvisen posel čaka na predhodnika. */
  INSERT @alarmi (AlertKind, Severity, Pipeline, DedupKey, Title, Summary)
  SELECT N''JobBlocked'', N''Warning'', CONCAT(N''OPRAVILO:'', j.JobKey),
         CONVERT(varchar(64), HASHBYTES(''SHA2_256'', CONCAT(N''JobBlocked:'', j.JobKey)), 2),
         CONCAT(N''Posel "'', j.Label, N''" je blokiran.''),
         CONCAT(COALESCE(LEFT(j.LastError, 1500), N''''), N'' Zadnji uspeh: '', COALESCE(CONVERT(nvarchar(19), j.LastSucceededUtc, 120), N''nikoli''), N'' UTC.'')
  FROM ops.JobDefinition j
  WHERE j.IsEnabled = 1 AND j.LastStatus = N''Blocked'';

  /* Zastarel vir (256): podatki vira so starejši od meje, čeprav posel teče. Merilo so faze workerjev. */
  INSERT @alarmi (AlertKind, Severity, Pipeline, DedupKey, Title, Summary)
  SELECT N''SourceStale'', N''Critical'', CONCAT(N''OPRAVILO:'', s.JobKey),
         CONVERT(varchar(64), HASHBYTES(''SHA2_256'', CONCAT(N''SourceStale:'', s.JobKey, N'':'', s.Pipeline, N'':'', s.SourceCode, N'':'', COALESCE(s.OrganizationId, 0))), 2),
         CONCAT(N''Vir "'', s.Label, N''"'', CASE WHEN s.OrganizationName IS NULL THEN N'''' ELSE CONCAT(N'' ('', s.OrganizationName, N'')'') END,
                CASE WHEN s.BasisUtc IS NULL THEN N'' še ni prinesel podatkov.''
                     ELSE CONCAT(N'': podatki so stari '', DATEDIFF(minute, s.BasisUtc, @now) / 60, N'' h '', DATEDIFF(minute, s.BasisUtc, @now) % 60, N'' min (meja '', s.MaxAgeSeconds / 3600, N'' h).'') END),
         CONCAT(N''Posel "'', j.Label, N''". Zadnji stik: '', COALESCE(CONVERT(nvarchar(19), s.LastContactUtc, 120), N''nikoli''),
                N'' UTC, zadnji novi podatki: '', COALESCE(CONVERT(nvarchar(19), s.LastNewDataUtc, 120), N''nikoli''), N'' UTC. '',
                COALESCE(CONCAT(N''Zadnja faza: '', s.LastMessage, N''. ''), N''''), N''Odpri posel na /sistem/opravila.'')
  FROM ops.JobSourceState() s
  INNER JOIN ops.JobDefinition j ON j.JobKey = s.JobKey
  WHERE j.IsEnabled = 1 AND s.State = N''Stale'';

  /* Gostitelj: najem manjka, ne utripa 10 minut ali ga drži kdo, ki ni gostitelj avtomatike. */
  DECLARE @leaseApp nvarchar(200), @leaseHeartbeat datetime2(3), @leaseOwner nvarchar(200);
  SELECT @leaseApp = Application, @leaseHeartbeat = HeartbeatUtc, @leaseOwner = Owner FROM ops.SchedulerLease WHERE LeaseKey = N''PIM'';
  IF EXISTS (SELECT 1 FROM ops.JobDefinition WHERE IsEnabled = 1)
     AND (@leaseApp IS NULL OR @leaseApp NOT LIKE N''AutomationHost%'' OR @leaseHeartbeat < DATEADD(minute, -10, @now))
    INSERT @alarmi (AlertKind, Severity, Pipeline, DedupKey, Title, Summary)
    VALUES (N''AutomationHostDown'', N''Critical'', N''GOSTITELJ'',
            CONVERT(varchar(64), HASHBYTES(''SHA2_256'', N''AutomationHostDown''), 2),
            N''Gostitelj avtomatike (PIM.AutomationHost) ne teče.'',
            CONCAT(CASE WHEN @leaseApp IS NULL THEN N''Najema ni.'' WHEN @leaseApp NOT LIKE N''AutomationHost%'' THEN CONCAT(N''Najem drži '', @leaseOwner, N'' (ni gostitelj avtomatike).'')
                        ELSE CONCAT(N''Zadnji utrip gostitelja '', CONVERT(nvarchar(19), @leaseHeartbeat, 120), N'' UTC.'') END,
                   N'' Opravila ne tečejo. Preveri storitev PIM.AutomationHost (Get-Service PIM.AutomationHost) in dnevnik.''));

  MERGE ops.Alert AS target
  USING (SELECT AlertKind, Severity, Pipeline, DedupKey, Title, Summary FROM @alarmi) AS source
    ON target.OrganizationId = @org AND target.DedupKey = source.DedupKey AND target.ResolvedUtc IS NULL
  WHEN MATCHED THEN UPDATE SET LastSeenUtc = @now, OccurrenceCount = target.OccurrenceCount + 1, Title = source.Title, Severity = source.Severity,
                               PayloadSummaryRedacted = source.Summary, UpdatedUtc = @now, UpdatedBy = @Actor
  WHEN NOT MATCHED THEN INSERT (OrganizationId, Pipeline, AlertKind, Severity, DedupKey, Title, PayloadSummaryRedacted, UpdatedBy)
    VALUES (@org, source.Pipeline, source.AlertKind, source.Severity, source.DedupKey, source.Title, source.Summary, @Actor);

  UPDATE alert SET ResolvedUtc = @now, ResolvedBy = @Actor, UpdatedUtc = @now, UpdatedBy = @Actor
  FROM ops.Alert alert
  WHERE alert.AlertKind IN (N''JobOverdue'', N''JobFailed'', N''JobBlocked'', N''SourceStale'', N''AutomationHostDown'') AND alert.ResolvedUtc IS NULL
    AND NOT EXISTS (SELECT 1 FROM @alarmi a WHERE a.DedupKey = alert.DedupKey);
END');

/* ── 4. Naročnine ───────────────────────────────────────────────────────────────── */
EXEC(N'
  DECLARE @definicija nvarchar(max) = (SELECT definition FROM sys.check_constraints WHERE name = N''CK_UserAlertSubscription_Kind'');
  IF @definicija IS NOT NULL AND CHARINDEX(N''SourceStale'', @definicija) = 0
  BEGIN
    DECLARE @vrste nvarchar(max);
    SELECT @vrste = STRING_AGG(CONCAT(N''N'''''', REPLACE(AlertKind, N'''''''', N''''''''''''), N''''''''), N'', '')
    FROM (
      SELECT DISTINCT AlertKind FROM intranet.UserAlertSubscription
      UNION SELECT N''SourceStale''
      UNION SELECT AlertKind FROM (VALUES
        (N''StaleHeartbeat''), (N''OutboundDead''), (N''OutboundDrift''), (N''StalledWatermark''),
        (N''PipelineDisabled''), (N''ReservationExcluded''), (N''OutboundUnacknowledged''),
        (N''PipelinePaused''), (N''PipelineOverdue''), (N''StockSnapshotStale''), (N''StockSnapshotEmpty''),
        (N''ExportRejected''), (N''JobOverdue''), (N''JobFailed''), (N''JobBlocked''), (N''AutomationHostDown''),
        (N''WebShopWithdrawn'')) AS znane(AlertKind)
    ) AS vse;
    ALTER TABLE intranet.UserAlertSubscription DROP CONSTRAINT CK_UserAlertSubscription_Kind;
    EXEC(N''ALTER TABLE intranet.UserAlertSubscription ADD CONSTRAINT CK_UserAlertSubscription_Kind CHECK (AlertKind IN ('' + @vrste + N''))'');
  END');

INSERT intranet.UserAlertSubscription (UserName, AlertKind, UpdatedBy)
SELECT existing.UserName, N'SourceStale', N'256_ViriPoslovInSvezina'
FROM intranet.UserAlertSubscription existing
WHERE existing.AlertKind = N'JobFailed'
  AND NOT EXISTS (SELECT 1 FROM intranet.UserAlertSubscription s WHERE s.UserName = existing.UserName AND s.AlertKind = N'SourceStale');

/* ── 5. Seme virov (isti seznam kot JobCatalog.cs; gostitelj ga ob zagonu uskladi) ─ */
DECLARE @kdo nvarchar(200) = N'256_ViriPoslovInSvezina';
EXEC ops.EnsureJobSource N'SAOP_PRODUCT_IMPORT', N'GetItemsGeneralData', N'SAOP_PRODUCTS', N'Osnovni podatki artiklov', 7200, 1, 0, 1, @kdo;
EXEC ops.EnsureJobSource N'SAOP_PRODUCT_IMPORT', N'GetItemsDescriptions', N'SAOP_PRODUCTS', N'Opisi artiklov', 7200, 1, 0, 2, @kdo;
EXEC ops.EnsureJobSource N'SAOP_PRODUCT_IMPORT', N'GetItemsTitlesLanguage', N'SAOP_PRODUCTS', N'Nazivi po jezikih', 7200, 1, 0, 3, @kdo;
EXEC ops.EnsureJobSource N'SAOP_PRODUCT_IMPORT', N'GetItemsCustomProperties', N'SAOP_PRODUCTS', N'Lastnosti artiklov', 7200, 1, 0, 4, @kdo;
EXEC ops.EnsureJobSource N'SAOP_PRODUCT_IMPORT', N'GetItemsPlanningData', N'SAOP_PRODUCTS', N'Planski podatki', 7200, 1, 0, 5, @kdo;
EXEC ops.EnsureJobSource N'SAOP_PRODUCT_IMPORT', N'GetItemsStockData', N'SAOP_PRODUCTS', N'Zalogovni podatki', 7200, 1, 0, 6, @kdo;
EXEC ops.EnsureJobSource N'SAOP_PRODUCT_IMPORT', N'GetItemsStockAccountingData', N'SAOP_PRODUCTS', N'Knjigovodski podatki zaloge', 7200, 1, 0, 7, @kdo;
EXEC ops.EnsureJobSource N'SAOP_PRODUCT_IMPORT', N'GetItemCustomerDataV2', N'SAOP_PRODUCTS', N'Podatki artiklov po kupcih', 7200, 1, 0, 8, @kdo;
EXEC ops.EnsureJobSource N'STOCK_IMPORT', N'SAOP_STOCK', N'SAOP_STOCK', N'Zaloga iz SAOP', 1800, 1, 1, 1, @kdo;
EXEC ops.EnsureJobSource N'PRICE_IMPORT', N'GetPrices', N'SAOP_PRICES', N'Cene iz SAOP', 1800, 1, 0, 1, @kdo;
EXEC ops.EnsureJobSource N'SUPPLIER_STOCK_IMPORT', N'BT_STOCK', N'STOCK_FILE', N'Braytron zaloga', 21600, 1, 1, 1, @kdo;
EXEC ops.EnsureJobSource N'SUPPLIER_STOCK_IMPORT', N'NW_STOCK', N'STOCK_FILE', N'Nowodvorski zaloga', 14400, 1, 1, 2, @kdo;
EXEC ops.EnsureJobSource N'NIGHTLY_RECONCILIATION', N'SAOP_DELIVERY', N'SAOP_DELIVERY', N'Datumi dobave iz SAOP', 129600, 1, 0, 1, @kdo;

/* ── Preverjanje ────────────────────────────────────────────────────────────────── */
IF OBJECT_ID(N'ops.JobSource', N'U') IS NULL OR OBJECT_ID(N'ops.JobSourceState', N'IF') IS NULL
   OR OBJECT_ID(N'intranet.GetJobSourceState', N'P') IS NULL
  THROW 52561, N'256: viri poslov niso nameščeni.', 1;
IF CHARINDEX(N'SourceStale', OBJECT_DEFINITION(OBJECT_ID(N'ops.EvaluateJobAlerts'))) = 0
  THROW 52562, N'256: ops.EvaluateJobAlerts ne pozna alarma SourceStale.', 1;
