/*
  247 — alarmi zamujanja po novem ritmu avtomatike (nadaljevanje 246).

  Pregled sprememb 246 (2026-09-22) je našel dva vira lažnih kritičnih alarmov:

  1. ops.RaiseOverdueAlerts (PIM.Watchdog) odpre PipelineOverdue, kadar postopek molči več kot
     2 × ops.ScheduleProfile.IntervalSeconds. Tam so še stari razmiki (300 s), gostitelj pa zalogo in
     cene iz SAOP poganja na ~10-13 min (600 s od konca + pas SAOP), izvoz cen in zaloge po zalogi,
     zalogo dobaviteljev na 30 min. Razmiki v ops.ScheduleProfile se zato poravnajo z novim ritmom
     (samo navzgor; skrbnikov daljši razmik ostane):
       SAOP_STOCK, SAOP_PRICES                       900 s, zastarelost 1800 s
       MAGENTO_STOCK_PRICES, STOCK_FILE, SOURCE_FETCH 1800 s, zastarelost 3600 s
     Iste vrednosti uporabljajo stare skripte s stikalom --po-urniku, kadar tečejo kot rezerva.

  2. ops.EvaluateJobAlerts je JobOverdue meril od ZADNJEGA ZAČETKA (2 × razmik). Z odlogom po napakah
     (do 4 h), čakanjem v pasu SAOP in terminom od konca je to lažni alarm. Zdaj se meri od TERMINA:
     posel zamuja, kadar je NextDueUtc v preteklosti za več kot (WarnAfterMultiplier - 1) × razmik in
     posel ne teče. Posel z odlogom ima termin v prihodnosti in ne zamuja; padec javlja JobFailed.
     Ostali deli postopka (JobFailed, JobBlocked, AutomationHostDown, zapiranje) so enaki kot v 237.
*/

IF OBJECT_ID(N'ops.EvaluateJobAlerts', N'P') IS NULL
  THROW 52980, N'247: ops.EvaluateJobAlerts ne obstaja (najprej migracija 237).', 1;

/* ── 1. ops.ScheduleProfile po novem ritmu ─────────────────────────────────────── */
UPDATE ops.ScheduleProfile
SET IntervalSeconds = 900, StaleAfterSeconds = CASE WHEN StaleAfterSeconds < 1800 THEN 1800 ELSE StaleAfterSeconds END,
    UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = N'247_AlarmiPoNovemRitmu'
WHERE Pipeline IN (N'SAOP_STOCK', N'SAOP_PRICES') AND IntervalSeconds < 900;

UPDATE ops.ScheduleProfile
SET IntervalSeconds = 1800, StaleAfterSeconds = CASE WHEN StaleAfterSeconds < 3600 THEN 3600 ELSE StaleAfterSeconds END,
    UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = N'247_AlarmiPoNovemRitmu'
WHERE Pipeline IN (N'MAGENTO_STOCK_PRICES', N'STOCK_FILE', N'SOURCE_FETCH') AND IntervalSeconds < 1800;

/* ── 2. JobOverdue od termina ──────────────────────────────────────────────────── */
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

  /* Zaostanek (247): posel, katerega termin je minil za več kot (WarnAfterMultiplier - 1) × razmik in ne teče.
     Merjeno od termina, ne od zadnjega začetka: odlog po napakah in čakanje v pasu SAOP nista zaostanek. */
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

  /* Padec: zadnji zagon Failed, TimedOut ali Abandoned. Rezultat toka je kritičen, vmesni posel opozorilo. */
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

  /* Gostitelj: najem manjka, ne utripa 10 minut ali ga drži kdo, ki ni gostitelj avtomatike (intranet kot rezerva). */
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
  WHERE alert.AlertKind IN (N''JobOverdue'', N''JobFailed'', N''JobBlocked'', N''AutomationHostDown'') AND alert.ResolvedUtc IS NULL
    AND NOT EXISTS (SELECT 1 FROM @alarmi a WHERE a.DedupKey = alert.DedupKey);

  /* Dokler gostitelj avtomatike utripa, stari cikli (221) niso več merilo; njihovi alarmi o zaostanku se zaprejo. */
  IF @leaseApp LIKE N''AutomationHost%'' AND @leaseHeartbeat >= DATEADD(minute, -10, @now)
    UPDATE ops.Alert SET ResolvedUtc = @now, ResolvedBy = @Actor, UpdatedUtc = @now, UpdatedBy = @Actor
    WHERE AlertKind = N''CycleOverdue'' AND ResolvedUtc IS NULL;
END');

/* ── Preverbe ───────────────────────────────────────────────────────────────────── */
IF EXISTS (SELECT 1 FROM ops.ScheduleProfile WHERE Pipeline IN (N'SAOP_STOCK', N'SAOP_PRICES') AND IntervalSeconds < 900)
  THROW 52981, N'247: razmik SAOP_STOCK ali SAOP_PRICES v ops.ScheduleProfile je še pod 900 s.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'ops.EvaluateJobAlerts')) NOT LIKE N'%j.NextDueUtc < @now%'
  THROW 52982, N'247: ops.EvaluateJobAlerts ne meri zaostanka od termina.', 1;
