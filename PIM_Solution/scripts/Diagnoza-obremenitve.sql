/*
  Diagnoza obremenitve strežnika — SAMO BRANJE, nič ne spreminja.

  Poženi v SSMS na produkcijski bazi (USE PIM_prd), ko je strežnik obremenjen, in še enkrat, ko
  je miren. Vsak razdelek odgovori na eno vprašanje:

    1  Kaj ta trenutek žre CPU (katera poizvedba, iz katerega programa, na kateri bazi)?
    2  Katere baze in programi imajo odprte seje — ali poleg PRD teče še kdo (PIM_test, drug intranet)?
    3  Katere poizvedbe so od zadnjega zagona SQL porabile največ CPU skupaj?
    4  Kdo drži razporejevalnik (najem) — en sam gostitelj ali se jih menja več?
    5  Koliko časa na uro posel dejansko teče (zasedenost = trajanje / razmik)?
    6  Ali se posli prekrivajo (več hkrati), in kdo jih sproža (urnik, odvisnost, človek)?
    7  Koraki, ki so v zadnjih 24 h vzeli največ časa (podjetje, worker).
    8  Trenutni urnik vseh poslov.

  Vzporedno v PowerShellu na strežniku preveri, ali tečejo še stara Windows opravila
  (drugi razporejevalnik, ki kliče iste workerje):
    Get-ScheduledTask | Where-Object TaskName -like 'PIM*' | Select TaskName, State
*/
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

/* 1 — trenutno aktivne zahteve, najdražje najprej ---------------------------------------------- */
SELECT TOP (25)
  r.session_id,
  DB_NAME(r.database_id)               AS baza,
  s.program_name                       AS program,
  s.host_name                          AS gostitelj,
  r.status,
  r.cpu_time / 1000                    AS cpu_s,
  r.total_elapsed_time / 1000          AS traja_s,
  r.logical_reads,
  r.wait_type,
  r.blocking_session_id                AS blokira_ga,
  OBJECT_SCHEMA_NAME(t.objectid, t.dbid) + N'.' + OBJECT_NAME(t.objectid, t.dbid) AS procedura,
  SUBSTRING(t.text, r.statement_start_offset / 2 + 1,
    (CASE r.statement_end_offset WHEN -1 THEN DATALENGTH(t.text) ELSE r.statement_end_offset END
      - r.statement_start_offset) / 2 + 1) AS stavek
FROM sys.dm_exec_requests AS r
JOIN sys.dm_exec_sessions AS s ON s.session_id = r.session_id
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
WHERE r.session_id <> @@SPID AND s.is_user_process = 1
ORDER BY r.cpu_time DESC;

/* 2 — seje po bazi, programu in gostitelju ------------------------------------------------------ */
SELECT
  DB_NAME(s.database_id)  AS baza,
  s.program_name          AS program,
  s.host_name             AS gostitelj,
  COUNT(*)                AS seje,
  SUM(CASE WHEN r.session_id IS NOT NULL THEN 1 ELSE 0 END) AS aktivne,
  SUM(s.cpu_time) / 1000  AS cpu_s_skupaj
FROM sys.dm_exec_sessions AS s
LEFT JOIN sys.dm_exec_requests AS r ON r.session_id = s.session_id
WHERE s.is_user_process = 1
GROUP BY DB_NAME(s.database_id), s.program_name, s.host_name
ORDER BY cpu_s_skupaj DESC;

/* 3 — najdražje poizvedbe v predpomnilniku načrtov ---------------------------------------------- */
SELECT TOP (20)
  DB_NAME(t.dbid)                                    AS baza,
  OBJECT_SCHEMA_NAME(t.objectid, t.dbid) + N'.' + OBJECT_NAME(t.objectid, t.dbid) AS procedura,
  q.execution_count                                  AS izvedb,
  q.total_worker_time / 1000000                      AS cpu_s_skupaj,
  q.total_worker_time / NULLIF(q.execution_count, 0) / 1000 AS cpu_ms_na_izvedbo,
  q.total_elapsed_time / NULLIF(q.execution_count, 0) / 1000 AS traja_ms_na_izvedbo,
  q.total_logical_reads / NULLIF(q.execution_count, 0) AS branj_na_izvedbo,
  q.last_execution_time                              AS zadnjic,
  SUBSTRING(t.text, q.statement_start_offset / 2 + 1,
    (CASE q.statement_end_offset WHEN -1 THEN DATALENGTH(t.text) ELSE q.statement_end_offset END
      - q.statement_start_offset) / 2 + 1)          AS stavek
FROM sys.dm_exec_query_stats AS q
CROSS APPLY sys.dm_exec_sql_text(q.sql_handle) AS t
ORDER BY q.total_worker_time DESC;

/* 4 — kdo drži razporejevalnik ------------------------------------------------------------------ */
SELECT LeaseKey, Owner, HostName, ProcessId, Application, AcquiredUtc, HeartbeatUtc, ExpiresUtc, TickCount, CanRunCycles
FROM ops.SchedulerLease;

-- Iz katerih gostiteljev so tekli zagoni v zadnjih 24 h. Več kot en gostitelj = več razporejevalnikov.
SELECT HostName, StartedBy, TriggeredBy, COUNT(*) AS zagonov, MIN(StartedUtc) AS prvi, MAX(StartedUtc) AS zadnji
FROM ops.JobRun
WHERE StartedUtc >= DATEADD(HOUR, -24, SYSUTCDATETIME())
GROUP BY HostName, StartedBy, TriggeredBy
ORDER BY zagonov DESC;

/* 5 — zasedenost po poslih v zadnjih 24 h ------------------------------------------------------- */
-- zasedenost_pct = koliko odstotkov dneva posel teče. Nad ~30 % je razmik prekratek za to trajanje;
-- nad 100 % se posel sam sebi nalaga (takoj ko konča, je spet na vrsti).
SELECT
  d.JobKey,
  d.Label,
  d.IsEnabled,
  d.IntervalSeconds                                            AS razmik_s,
  d.DailyAtLocal                                               AS dnevno_ob,
  COUNT(r.JobRunId)                                            AS zagonov_24h,
  SUM(CASE WHEN r.TriggeredBy = N'Dependency' THEN 1 ELSE 0 END) AS od_odvisnosti,
  SUM(CASE WHEN r.Status IN (N'Failed', N'TimedOut') THEN 1 ELSE 0 END) AS padlih,
  AVG(DATEDIFF(SECOND, r.StartedUtc, COALESCE(r.EndedUtc, SYSUTCDATETIME())))  AS povprecno_s,
  MAX(DATEDIFF(SECOND, r.StartedUtc, COALESCE(r.EndedUtc, SYSUTCDATETIME())))  AS najdlje_s,
  SUM(DATEDIFF(SECOND, r.StartedUtc, COALESCE(r.EndedUtc, SYSUTCDATETIME()))) / 60 AS minut_teka_24h,
  CAST(100.0 * SUM(DATEDIFF(SECOND, r.StartedUtc, COALESCE(r.EndedUtc, SYSUTCDATETIME()))) / 86400 AS decimal(6,1)) AS zasedenost_pct
FROM ops.JobDefinition AS d
LEFT JOIN ops.JobRun AS r
  ON r.JobKey = d.JobKey
 AND r.StartedUtc >= DATEADD(HOUR, -24, SYSUTCDATETIME())
 AND r.Status <> N'Blocked'
GROUP BY d.JobKey, d.Label, d.IsEnabled, d.IntervalSeconds, d.DailyAtLocal
ORDER BY minut_teka_24h DESC;

/* 6 — prekrivanje: koliko poslov je teklo hkrati, po urah --------------------------------------- */
;WITH ure AS (
  SELECT TOP (24) DATEADD(HOUR, -ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) + 1,
    DATEADD(HOUR, DATEDIFF(HOUR, 0, SYSUTCDATETIME()), 0)) AS ura
  FROM sys.all_objects
)
SELECT
  u.ura AS ura_utc,
  COUNT(r.JobRunId) AS poslov_v_uri,
  SUM(DATEDIFF(SECOND,
        CASE WHEN r.StartedUtc > u.ura THEN r.StartedUtc ELSE u.ura END,
        CASE WHEN COALESCE(r.EndedUtc, SYSUTCDATETIME()) < DATEADD(HOUR, 1, u.ura)
             THEN COALESCE(r.EndedUtc, SYSUTCDATETIME()) ELSE DATEADD(HOUR, 1, u.ura) END)) / 60 AS minut_teka,
  -- 60 minut teka v uri = en posel ves čas; 180 = v povprečju trije hkrati.
  STRING_AGG(CONVERT(nvarchar(max), r.JobKey), N', ') WITHIN GROUP (ORDER BY r.StartedUtc) AS posli
FROM ure AS u
LEFT JOIN ops.JobRun AS r
  ON r.StartedUtc < DATEADD(HOUR, 1, u.ura)
 AND COALESCE(r.EndedUtc, SYSUTCDATETIME()) > u.ura
 AND r.Status <> N'Blocked'
GROUP BY u.ura
ORDER BY u.ura DESC;

/* 7 — najdaljši koraki v zadnjih 24 h ----------------------------------------------------------- */
SELECT TOP (30)
  r.JobKey,
  s.StepName,
  s.OrganizationId,
  COUNT(*)                                                         AS izvedb,
  AVG(DATEDIFF(SECOND, s.StartedUtc, COALESCE(s.EndedUtc, SYSUTCDATETIME()))) AS povprecno_s,
  SUM(DATEDIFF(SECOND, s.StartedUtc, COALESCE(s.EndedUtc, SYSUTCDATETIME()))) / 60 AS minut_skupaj,
  SUM(CASE WHEN s.Status <> N'Succeeded' THEN 1 ELSE 0 END)        AS neuspelih
FROM ops.JobStepRun AS s
JOIN ops.JobRun AS r ON r.JobRunId = s.JobRunId
WHERE s.StartedUtc >= DATEADD(HOUR, -24, SYSUTCDATETIME())
GROUP BY r.JobKey, s.StepName, s.OrganizationId
ORDER BY minut_skupaj DESC;

/* 8 — trenutni urnik in odvisnosti -------------------------------------------------------------- */
SELECT JobKey, Label, IsEnabled, IntervalSeconds, DailyAtLocal, TimeoutSeconds, NextDueUtc,
       LastStartedUtc, LastEndedUtc, LastStatus, UpdatedBy, UpdatedUtc
FROM ops.JobDefinition
ORDER BY SortOrder;

SELECT JobKey, DependsOnJobKey, IsGate, TriggersDependent, MaxAgeSeconds, Note
FROM ops.JobDependency
WHERE TriggersDependent = 1
ORDER BY DependsOnJobKey;
