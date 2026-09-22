/*
  259 — Nadzor poslov: branje za stran /sistem in /sistem/posel/{posel} (blok 5 prenove nadzora).

  David 2026-09-22: »jaz moram vsaki korak imeti pod nadzorom in videti da se vse izvede … ne pa da so
  kar štirje koraki v enem workerju pa se ti ne delajo … naredi pregledno in uporabno«. Namesto sedmih
  strani (pregled, opravila, zagoni, postopki, integracije, napake, zmogljivost, izvozi) je ena stran
  Nadzor: ena vrstica na posel, zelena / siva / rdeča, in stran posla s koraki in fazami.

  (Številka: načrt je predvidel 257, a jo je med delom zasedla vzporedna seja z
  257_ErpFirstSupplierCandidates.sql; 258 je rezervirana za vire bloka 6.)

  Kaj naredi:
    1. intranet.GetMonitorPipelines — vsak postopek (ops.ScheduleProfile) aktivnih podjetij z zdravjem
       (ops.IntegrationHealth) in s tem, ali je podjetje v avtomatiki. Stran iz tega pove »postopek
       izklopljen« (samodejni izklop po zaporednih napakah) in ponudi vklop.
    2. intranet.GetMonitorAlerts — odprti alarmi brez podatkovnih vrst (ReservationExcluded, ExportRejected,
       WebShopWithdrawn, StockSnapshotStale, StockSnapshotEmpty; isti seznam kot MonitorPolicy.IsDataAlert).
       600 alarmov izključene rezervacije je doslej zakrilo edini alarm, ki pove, da posel ne teče.
    3. intranet.GetJobRunPhases — faze enega teka posla. Gostitelj je do ponovnega zagona tekel s starim
       binarjem, ki workerju ne poda PIM_JOB_RUN_ID, zato so faze teh tekov brez JobRunId. Procedura jih
       najde po času teka in postopkih posla; stolpec JobRunId pove strani, ali je vez natančna.
    4. sec.RolePermission — odstrani dovoljenja strani, ki jih blok 7 odstrani (/sistem/opravila, /sistem/zagoni,
       /sistem?pogled=postopki, /sistem/integracije, /sistem/izvozi, /sistem/zmogljivost, /sistem/napake;
       /sistem/workerji je odstranila že 254). Vloga, ki je imela katero od njih, dobi pregled Nadzora
       (tab.system.overview), sicer bi izgubila alarme in posle, ki so zdaj tam.
    5. Besedila alarmov v ops.EvaluateJobAlerts in ops.RaiseOverdueAlerts kažejo na /sistem namesto na
       odstranjeno /sistem/opravila (zamenjava v živi definiciji, da ne povozi tuje spremembe dolge
       procedure), prav tako že odprti alarmi.

  Česa NE naredi: tabel ne spreminja; ops.JobSourceState in intranet.GetJobSourceState (256) ostaneta.
  Idempotentna: vse procedure so CREATE OR ALTER, brisanje in zamenjava besedil ne najdeta ničesar drugič.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

IF OBJECT_ID(N'ops.JobPhaseRun', N'U') IS NULL OR OBJECT_ID(N'ops.JobSource', N'U') IS NULL
  THROW 52590, N'259: manjkata ops.JobPhaseRun ali ops.JobSource (najprej migraciji 255 in 256).', 1;

/* ── 1. Postopki z zdravjem ─────────────────────────────────────────────────────── */
EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetMonitorPipelines
AS
BEGIN
  SET NOCOUNT ON;
  /* HealthStatus je NULL, kadar postopek za podjetje še ni tekel: MAGENTO_PRODUCTS ima vrstico za vsa podjetja,
     izvoz kataloga pa teče samo za podjetje kataloga. Tak izklop ni izpad (MonitorPolicy, pravilo 5). */
  SELECT profile.Pipeline, profile.OrganizationId, organizationValue.Name AS OrganizationName, profile.IsEnabled,
         COALESCE(policy.IsEnabled, CONVERT(bit, 1)) AS OrganizationInAutomation,
         profile.IntervalSeconds, health.Status AS HealthStatus, health.LastHeartbeatUtc, health.LastSuccessfulRunUtc,
         health.LastErrorRedacted AS LastError, COALESCE(health.ConsecutiveFailures, 0) AS ConsecutiveFailures,
         profile.MaxConsecutiveFailures
  FROM ops.ScheduleProfile profile
  INNER JOIN dbo.OrganizationConfig organizationValue
    ON organizationValue.OrganizationId = profile.OrganizationId AND organizationValue.IsActive = 1
  LEFT JOIN ops.OrganizationAutomationPolicy policy ON policy.OrganizationId = profile.OrganizationId
  LEFT JOIN ops.IntegrationHealth health ON health.OrganizationId = profile.OrganizationId AND health.Pipeline = profile.Pipeline
  ORDER BY profile.Pipeline, profile.OrganizationId;
END;');

/* ── 2. Odprti alarmi brez podatkovnih ──────────────────────────────────────────── */
EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetMonitorAlerts
AS
BEGIN
  SET NOCOUNT ON;
  /* Podatkovne vrste rešuje urednik na svoji strani (rezervacije, izvoz, splet, posnetek zaloge), ne skrbnik
     s ponovnim zagonom; seznam je isti kot PIM.Automation.MonitorPolicy.IsDataAlert. */
  SELECT alert.AlertId, alert.AlertKind, alert.Severity, alert.Pipeline, alert.OrganizationId,
         COALESCE(organizationValue.Name, CONCAT(N''podjetje '', alert.OrganizationId)) AS OrganizationName,
         alert.Title, alert.PayloadSummaryRedacted AS Summary, alert.FirstSeenUtc, alert.LastSeenUtc, alert.AcknowledgedUtc
  FROM ops.Alert alert
  LEFT JOIN dbo.OrganizationConfig organizationValue ON organizationValue.OrganizationId = alert.OrganizationId
  WHERE alert.ResolvedUtc IS NULL
    AND alert.AlertKind NOT IN (N''ReservationExcluded'', N''ExportRejected'', N''WebShopWithdrawn'', N''StockSnapshotStale'', N''StockSnapshotEmpty'')
  ORDER BY CASE WHEN alert.Severity = N''Critical'' THEN 0 ELSE 1 END, alert.LastSeenUtc DESC, alert.AlertId DESC;
END;');

/* ── 3. Faze teka (z nadomestno vezjo po času) ──────────────────────────────────── */
EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetJobRunPhases @JobRunId bigint, @Pipelines nvarchar(max) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  DECLARE @od datetime2(3), @do datetime2(3);
  SELECT @od = StartedUtc, @do = COALESCE(EndedUtc, SYSUTCDATETIME()) FROM ops.JobRun WHERE JobRunId = @JobRunId;

  DECLARE @postopki TABLE (Pipeline nvarchar(200) NOT NULL PRIMARY KEY);
  IF @Pipelines IS NOT NULL
    INSERT @postopki (Pipeline)
    SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@Pipelines, N'','') WHERE LTRIM(RTRIM(value)) <> N'''';

  /* Natančna vez (JobRunId) ali nadomestna: faza brez teka, začeta med tekom, pod postopkom tega posla.
     Nadomestna vez je potrebna, dokler gostitelj teče s starim binarjem brez PIM_JOB_RUN_ID; ročni zagon
     workerja iz ukazne vrstice v istem oknu bi se pokazal tu — zato stran pove, katera vez velja. */
  WITH faze AS
  (
    SELECT phase.JobPhaseRunId FROM ops.JobPhaseRun phase WHERE phase.JobRunId = @JobRunId
    UNION
    SELECT phase.JobPhaseRunId
    FROM ops.JobPhaseRun phase
    WHERE @od IS NOT NULL AND phase.JobRunId IS NULL
      AND phase.StartedUtc >= @od AND phase.StartedUtc <= @do
      AND phase.Pipeline IN (SELECT Pipeline FROM @postopki)
  )
  SELECT phase.JobPhaseRunId, phase.JobRunId, phase.StepOrder, step.StepName, phase.PhaseCode, phase.PhaseOrder,
         phase.OrganizationId, organizationValue.Name AS OrganizationName, phase.Pipeline, phase.SourceCode,
         phase.Status, phase.HasNewData, phase.StartedUtc, phase.EndedUtc,
         DurationMs = CASE WHEN phase.EndedUtc IS NULL THEN NULL ELSE DATEDIFF(millisecond, phase.StartedUtc, phase.EndedUtc) END,
         phase.ItemsIn, phase.ItemsOut, phase.ItemsRejected, phase.ByteCount, phase.Message, phase.RunId
  FROM faze
  INNER JOIN ops.JobPhaseRun phase ON phase.JobPhaseRunId = faze.JobPhaseRunId
  LEFT JOIN ops.JobStepRun step ON step.JobRunId = phase.JobRunId AND step.StepOrder = phase.StepOrder
  LEFT JOIN dbo.OrganizationConfig organizationValue ON organizationValue.OrganizationId = phase.OrganizationId
  ORDER BY CASE WHEN phase.StepOrder IS NULL THEN 1 ELSE 0 END, phase.StepOrder, phase.StartedUtc, phase.PhaseOrder, phase.JobPhaseRunId;
END;');

/* ── 4. Dovoljenja odstranjenih strani ──────────────────────────────────────────── */
IF OBJECT_ID(N'sec.RolePermission', N'U') IS NOT NULL
BEGIN
  DECLARE @odstranjeno TABLE (PermissionKey nvarchar(200) NOT NULL PRIMARY KEY);
  INSERT @odstranjeno (PermissionKey) VALUES
    (N'tab.system.jobs'), (N'tab.system.runs'), (N'tab.system.schedules'), (N'tab.system.alerts'), (N'tab.system.workers'),
    (N'view.system.exports'), (N'view.system.performance'), (N'view.system.errors');

  /* Kdor je videl posle, zagone ali alarme, jih vidi zdaj na Nadzoru. */
  INSERT sec.RolePermission (RoleId, PermissionKey)
  SELECT DISTINCT granted.RoleId, N'tab.system.overview'
  FROM sec.RolePermission granted
  WHERE granted.PermissionKey IN (SELECT PermissionKey FROM @odstranjeno)
    AND NOT EXISTS (SELECT 1 FROM sec.RolePermission existing
                    WHERE existing.RoleId = granted.RoleId AND existing.PermissionKey = N'tab.system.overview');

  DELETE FROM sec.RolePermission WHERE PermissionKey IN (SELECT PermissionKey FROM @odstranjeno);
END;

/* ── 5. Besedila alarmov kažejo na obstoječo stran ──────────────────────────────── */
DECLARE @procedura sysname, @definicija nvarchar(max), @zacetek int;
DECLARE procedure_cursor CURSOR LOCAL FAST_FORWARD FOR
  SELECT name FROM (VALUES (N'ops.EvaluateJobAlerts'), (N'ops.RaiseOverdueAlerts')) AS target(name);
OPEN procedure_cursor;
FETCH NEXT FROM procedure_cursor INTO @procedura;
WHILE @@FETCH_STATUS = 0
BEGIN
  SET @definicija = OBJECT_DEFINITION(OBJECT_ID(@procedura));
  IF @definicija IS NOT NULL AND CHARINDEX(N'/sistem/opravila', @definicija) > 0
  BEGIN
    /* Živa definicija se začne s »CREATE   PROCEDURE« (CREATE OR ALTER brez OR ALTER); zamenja se samo pot. */
    SET @zacetek = CHARINDEX(N'CREATE', @definicija);
    IF @zacetek NOT BETWEEN 1 AND 20
      THROW 52591, N'259: definicija alarmne procedure se ne začne s CREATE; besedila ni mogoče varno zamenjati.', 1;
    SET @definicija = STUFF(@definicija, @zacetek, 6, N'ALTER');
    SET @definicija = REPLACE(@definicija, N'/sistem/opravila', N'/sistem');
    EXEC sys.sp_executesql @definicija;
  END;
  FETCH NEXT FROM procedure_cursor INTO @procedura;
END;
CLOSE procedure_cursor;
DEALLOCATE procedure_cursor;

UPDATE ops.Alert
SET Title = REPLACE(Title, N'/sistem/opravila', N'/sistem'),
    PayloadSummaryRedacted = REPLACE(PayloadSummaryRedacted, N'/sistem/opravila', N'/sistem')
WHERE ResolvedUtc IS NULL
  AND (Title LIKE N'%/sistem/opravila%' OR PayloadSummaryRedacted LIKE N'%/sistem/opravila%');

/* ── Preverjanje ─────────────────────────────────────────────────────────────────── */
IF OBJECT_ID(N'intranet.GetMonitorPipelines', N'P') IS NULL
   OR OBJECT_ID(N'intranet.GetMonitorAlerts', N'P') IS NULL
   OR OBJECT_ID(N'intranet.GetJobRunPhases', N'P') IS NULL
  THROW 52592, N'259: procedure Nadzora niso nameščene.', 1;

IF NOT EXISTS (SELECT 1 FROM sys.dm_exec_describe_first_result_set_for_object(OBJECT_ID(N'intranet.GetMonitorPipelines'), 0) WHERE name = N'OrganizationInAutomation')
   OR NOT EXISTS (SELECT 1 FROM sys.dm_exec_describe_first_result_set_for_object(OBJECT_ID(N'intranet.GetMonitorAlerts'), 0) WHERE name = N'OrganizationName')
   OR NOT EXISTS (SELECT 1 FROM sys.dm_exec_describe_first_result_set_for_object(OBJECT_ID(N'intranet.GetJobRunPhases'), 0) WHERE name = N'JobRunId')
  THROW 52593, N'259: procedure Nadzora ne vračajo pričakovanih stolpcev.', 1;

IF OBJECT_ID(N'sec.RolePermission', N'U') IS NOT NULL AND EXISTS (
    SELECT 1 FROM sec.RolePermission
    WHERE PermissionKey IN (N'tab.system.jobs', N'tab.system.runs', N'tab.system.schedules', N'tab.system.alerts', N'tab.system.workers',
                            N'view.system.exports', N'view.system.performance', N'view.system.errors'))
  THROW 52594, N'259: dovoljenja odstranjenih strani so ostala v sec.RolePermission.', 1;

IF CHARINDEX(N'/sistem/opravila', COALESCE(OBJECT_DEFINITION(OBJECT_ID(N'ops.EvaluateJobAlerts')), N'')) > 0
   OR CHARINDEX(N'/sistem/opravila', COALESCE(OBJECT_DEFINITION(OBJECT_ID(N'ops.RaiseOverdueAlerts')), N'')) > 0
  THROW 52595, N'259: alarmi še kažejo na odstranjeno stran /sistem/opravila.', 1;
