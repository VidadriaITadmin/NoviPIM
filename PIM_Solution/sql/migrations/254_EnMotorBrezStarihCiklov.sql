/*
  254 — en motor avtomatike: odstranitev starih ciklov (221) in lažnih alarmov.

  David 2026-09-22: »Prevec so nepregledni potem preveč barv z opozorili ... jaz moram vsaki korak imeti
  pod nadzorom.« Blok 1 načrta: avtomatiko poganja samo še PIM.AutomationHost (ops.JobDefinition,
  ops.JobRun, ops.JobStepRun). Razporejevalnik v intranetu, strani /sistem/workerji in /sistem/urniki
  ter njihove tabele gredo v istem commitu iz kode.

  Kaj je bilo narobe na lokalni bazi (izmerjeno 2026-09-22 17:40 UTC):
    - Novi gostitelj ni tekel še nikoli (ops.JobRun prazen); vse so poganjale Windows naloge.
    - 246 je stare cikle izklopila samo, če je gostitelj ob migraciji že tekel; ni, zato je bilo vseh
      5 vrstic ops.WorkerCycle še vklopljenih. PIM.Watchdog (ops.RaiseOverdueAlerts) je zanje vsakih
      5 min odprl CycleOverdue, gostitelj (ops.EvaluateJobAlerts) jih je minuto kasneje zaprl, vsak
      ponovni odprti alarm pa je šel še v vrsto za e-pošto.
    - 4 alarmi StockSnapshotStale z dne 2026-09-08 so lažni (zaloga SAOP je sveža) in se ne morejo
      zapreti sami: proceduri ops.EvaluateStockSnapshotAlerts ne kliče nihče.
    - OutboundDead in OutboundUnacknowledged sta za podjetje 1 (DEMO), ki ga je 246 izključila iz
      avtomatike; nihče ju ne more več ovrednotiti ali zapreti.
    - 16 vrstic ops.PipelineRun visi v stanju Running od 2026-09-10 naprej (ops.AbandonOrphanRuns
      nima klicatelja).
    - PipelineOverdue je merilo 2 × razmik iz ops.ScheduleProfile. Gostitelj poganja zalogo in cene
      na ~10-13 min, ob 00:30 pa pas SAOP za 15-20 min zasede nočna uskladitev: pri 900 s bi alarm
      vsako noč lažno zazvonil. Razpošiljanje alarmov in nadzornik pri 300 s zazvonita že, kadar
      gostitelj čaka na prosto mesto (največ 3 posli hkrati).

  Kaj naredi:
    1. Zapre odprte CycleOverdue, lažne StockSnapshotStale/Empty in alarma odhodne poti podjetja DEMO.
    2. ops.RaiseOverdueAlerts brez dela za cikle (samo PipelineOverdue); besedilo kaže na /sistem/opravila.
    3. Odstrani procedure in tabele starih ciklov: najprej procedure, nato tabele (WorkerCycleStep ima
       tuji ključ na WorkerCycleRun).
    4. Odstrani naročnine na CycleOverdue in dovoljenje tab.system.workers (stran /sistem/workerji ne obstaja več).
    5. Razmiki v ops.ScheduleProfile po ritmu gostitelja (samo navzgor; skrbnikov daljši razmik ostane).
    6. Zapre viseče vrstice ops.PipelineRun, starejše od 2 ur (Abandoned).

  Česa NE naredi: ops.SchedulerLease (najem gostitelja), ops.AcquireSchedulerLease/ReleaseSchedulerLease
  in ops.RunWatchdog ostanejo. ops.EvaluateJobAlerts zapira CycleOverdue še naprej (3 vrstice, ki
  ne najdejo ničesar); CK_UserAlertSubscription_Kind ostane nespremenjen, da ne povozi vrst, ki jih
  dodajajo vzporedne migracije.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

DECLARE @kdo nvarchar(200) = N'254_EnMotorBrezStarihCiklov';
DECLARE @now datetime2(3) = SYSUTCDATETIME();

/* ── 1. Alarmi, ki se ne morejo zapreti sami ─────────────────────────────────────── */
UPDATE alert
SET ResolvedUtc = @now, ResolvedBy = @kdo, UpdatedUtc = @now, UpdatedBy = @kdo
FROM ops.Alert alert
LEFT JOIN ops.OrganizationAutomationPolicy policy ON policy.OrganizationId = alert.OrganizationId
WHERE alert.ResolvedUtc IS NULL
  AND (
       alert.AlertKind = N'CycleOverdue'
    OR alert.AlertKind IN (N'StockSnapshotStale', N'StockSnapshotEmpty')
    OR (alert.AlertKind IN (N'OutboundDead', N'OutboundUnacknowledged') AND policy.IsEnabled = 0)
  );

/* ── 2. Zamujanje samo še za postopke ───────────────────────────────────────────── */
EXEC(N'CREATE OR ALTER PROCEDURE ops.RaiseOverdueAlerts @Actor nvarchar(200) = N''PIM.Watchdog''
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  DECLARE @now datetime2(3) = SYSUTCDATETIME();

  /* 254: starih ciklov ni več; zamujanje poslov javlja ops.EvaluateJobAlerts (JobOverdue). */
  DECLARE @postopki TABLE (OrganizationId int, Pipeline nvarchar(200), DedupKey varchar(64), Title nvarchar(300), Summary nvarchar(2000));
  INSERT @postopki (OrganizationId, Pipeline, DedupKey, Title, Summary)
  SELECT profile.OrganizationId, profile.Pipeline,
         CONVERT(varchar(64), HASHBYTES(''SHA2_256'', CONCAT(N''PipelineOverdue:'', profile.OrganizationId, N'':'', profile.Pipeline)), 2),
         CONCAT(N''Postopek '', profile.Pipeline, N'' ni tekel '', DATEDIFF(minute, COALESCE(health.LastHeartbeatUtc, profile.UpdatedUtc), @now), N'' min.''),
         CONCAT(N''Podjetje: '', organizationValue.Name, N''. Zadnji utrip: '', COALESCE(CONVERT(nvarchar(19), health.LastHeartbeatUtc, 120), N''nikoli''),
                N'' UTC. Preveri posel in zadnje zagone na /sistem/opravila.'')
  FROM ops.ScheduleProfile profile
  INNER JOIN dbo.OrganizationConfig organizationValue ON organizationValue.OrganizationId=profile.OrganizationId
  LEFT JOIN ops.IntegrationHealth health ON health.OrganizationId=profile.OrganizationId AND health.Pipeline=profile.Pipeline
  LEFT JOIN ops.OrganizationAutomationPolicy policy ON policy.OrganizationId=profile.OrganizationId
  WHERE profile.IsEnabled=1 AND organizationValue.IsActive=1 AND COALESCE(policy.IsEnabled, CONVERT(bit, 1))=1
    AND DATEDIFF(second, COALESCE(health.LastHeartbeatUtc, profile.UpdatedUtc), @now)>2*profile.IntervalSeconds;

  MERGE ops.Alert AS target
  USING (SELECT OrganizationId,Pipeline,DedupKey,Title,Summary FROM @postopki) AS source
    ON target.OrganizationId=source.OrganizationId AND target.DedupKey=source.DedupKey AND target.ResolvedUtc IS NULL
  WHEN MATCHED THEN UPDATE SET LastSeenUtc=@now, OccurrenceCount=target.OccurrenceCount+1, Title=source.Title, PayloadSummaryRedacted=source.Summary, UpdatedUtc=@now, UpdatedBy=@Actor
  WHEN NOT MATCHED THEN INSERT (OrganizationId,Pipeline,AlertKind,Severity,DedupKey,Title,PayloadSummaryRedacted,UpdatedBy)
    VALUES (source.OrganizationId,source.Pipeline,N''PipelineOverdue'',N''Critical'',source.DedupKey,source.Title,source.Summary,@Actor);

  UPDATE alert SET ResolvedUtc=@now, ResolvedBy=@Actor, UpdatedUtc=@now, UpdatedBy=@Actor
  FROM ops.Alert alert WHERE alert.AlertKind=N''PipelineOverdue'' AND alert.ResolvedUtc IS NULL
    AND NOT EXISTS (SELECT 1 FROM @postopki profile WHERE profile.DedupKey=alert.DedupKey AND profile.OrganizationId=alert.OrganizationId);
END;');

/* ── 3. Procedure in tabele starih ciklov ───────────────────────────────────────── */
IF OBJECT_ID(N'intranet.GetWorkerCycles', N'P') IS NOT NULL      DROP PROCEDURE intranet.GetWorkerCycles;
IF OBJECT_ID(N'intranet.GetWorkerCycleRuns', N'P') IS NOT NULL   DROP PROCEDURE intranet.GetWorkerCycleRuns;
IF OBJECT_ID(N'intranet.GetWorkerCycleSteps', N'P') IS NOT NULL  DROP PROCEDURE intranet.GetWorkerCycleSteps;
IF OBJECT_ID(N'intranet.SaveWorkerCycle', N'P') IS NOT NULL      DROP PROCEDURE intranet.SaveWorkerCycle;
IF OBJECT_ID(N'ops.EnsureWorkerCycle', N'P') IS NOT NULL         DROP PROCEDURE ops.EnsureWorkerCycle;
IF OBJECT_ID(N'ops.SetWorkerCycleNextDue', N'P') IS NOT NULL     DROP PROCEDURE ops.SetWorkerCycleNextDue;
IF OBJECT_ID(N'ops.ClaimWorkerCycle', N'P') IS NOT NULL          DROP PROCEDURE ops.ClaimWorkerCycle;
IF OBJECT_ID(N'ops.HeartbeatWorkerCycle', N'P') IS NOT NULL      DROP PROCEDURE ops.HeartbeatWorkerCycle;
IF OBJECT_ID(N'ops.RecordWorkerCycleStep', N'P') IS NOT NULL     DROP PROCEDURE ops.RecordWorkerCycleStep;
IF OBJECT_ID(N'ops.CompleteWorkerCycle', N'P') IS NOT NULL       DROP PROCEDURE ops.CompleteWorkerCycle;
IF OBJECT_ID(N'ops.AbandonWorkerCycleRuns', N'P') IS NOT NULL    DROP PROCEDURE ops.AbandonWorkerCycleRuns;

IF OBJECT_ID(N'ops.WorkerCycleStep', N'U') IS NOT NULL DROP TABLE ops.WorkerCycleStep;
IF OBJECT_ID(N'ops.WorkerCycleRun', N'U') IS NOT NULL  DROP TABLE ops.WorkerCycleRun;
IF OBJECT_ID(N'ops.WorkerCycle', N'U') IS NOT NULL     DROP TABLE ops.WorkerCycle;

/* ── 4. Naročnine in dovoljenja za odstranjeno ──────────────────────────────────── */
IF OBJECT_ID(N'intranet.UserAlertSubscription', N'U') IS NOT NULL
  DELETE FROM intranet.UserAlertSubscription WHERE AlertKind = N'CycleOverdue';

IF OBJECT_ID(N'sec.RolePermission', N'U') IS NOT NULL
  DELETE FROM sec.RolePermission WHERE PermissionKey = N'tab.system.workers';

/* ── 5. Razmiki postopkov po ritmu gostitelja (samo navzgor) ────────────────────── */
/* Zaloga in cene iz SAOP: ~10-13 min, ponoči pas SAOP zasede nočna uskladitev do ~20 min. Prag 2 × 1800 s = 1 h. */
UPDATE ops.ScheduleProfile
SET IntervalSeconds = 1800,
    StaleAfterSeconds = CASE WHEN StaleAfterSeconds < 1800 THEN 1800 ELSE StaleAfterSeconds END,
    UpdatedUtc = @now, UpdatedBy = @kdo
WHERE Pipeline IN (N'SAOP_STOCK', N'SAOP_PRICES') AND IntervalSeconds < 1800;

/* Nadzornik in razpošiljanje alarmov: 5 min od konca, lahko čakata na prosto mesto. Prag 2 × 900 s = 30 min. */
UPDATE ops.ScheduleProfile
SET IntervalSeconds = 900,
    StaleAfterSeconds = CASE WHEN StaleAfterSeconds < 900 THEN 900 ELSE StaleAfterSeconds END,
    UpdatedUtc = @now, UpdatedBy = @kdo
WHERE Pipeline IN (N'WATCHDOG', N'ALERT_DISPATCH') AND IntervalSeconds < 900;

/* ── 6. Viseči teki postopkov ───────────────────────────────────────────────────── */
UPDATE ops.PipelineRun
SET Status = N'Abandoned', EndedUtc = @now
WHERE Status = N'Running' AND StartedUtc < DATEADD(hour, -2, @now);

/* ── Preverjanje ─────────────────────────────────────────────────────────────────── */
IF OBJECT_ID(N'ops.WorkerCycle', N'U') IS NOT NULL OR OBJECT_ID(N'ops.ClaimWorkerCycle', N'P') IS NOT NULL
  THROW 52540, N'254: stari cikli niso odstranjeni.', 1;
IF CHARINDEX(N'FROM ops.WorkerCycle', OBJECT_DEFINITION(OBJECT_ID(N'ops.RaiseOverdueAlerts'))) > 0
  THROW 52541, N'254: ops.RaiseOverdueAlerts še bere ops.WorkerCycle.', 1;
