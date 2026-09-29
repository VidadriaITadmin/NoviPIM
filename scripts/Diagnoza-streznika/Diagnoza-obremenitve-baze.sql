/*
  Diagnoza obremenitve baze - SAMO BRANJE, nic ne spreminja.
  Navodila: NAVODILA.md (ista mapa).

  Pozeni v SSMS na produkcijski bazi (USE PIM_prd), ko je streznik obremenjen, in se enkrat, ko
  je miren. Vsak razdelek odgovori na eno vprasanje:

    0  KATERI PROGRAM (PID iz upravitelja opravil) bremeni bazo? -> npr. PIM.XmlFileWorker
    1  Kaj ta trenutek zre CPU (katera poizvedba, iz katerega procesa, na kateri bazi)?
    2  Katere baze in programi imajo odprte seje - ali poleg PRD tece se kdo (PIM_test, drug intranet)?
    3  Katere poizvedbe so od zadnjega zagona SQL porabile najvec CPU skupaj?
    4  Kdo drzi razporejevalnik (najem) - en sam gostitelj ali se jih menja vec?
    5  Koliko casa na uro posel dejansko tece (zasedenost = trajanje / razmik)?
    6  Ali se posli prekrivajo (vec hkrati), in kdo jih sprozi (urnik, odvisnost, clovek)?
    7  Koraki, ki so v zadnjih 24 h vzeli najvec casa (podjetje, worker).
    8  Trenutni urnik vseh poslov.
    9  Posli, ki tecejo ZDAJ.

  Vsi PIM programi se v SQL predstavijo z istim imenom ("Core Microsoft SqlClient Data Provider"),
  zato jih locimo po stolpcu pid = PID v upravitelju opravil (zavihek Details, stolpec PID).
*/
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

/* 0 - obremenitev po procesu (PID) na tem strezniku -------------------------------------------- */
SELECT
  s.host_process_id                    AS pid,
  s.host_name                          AS gostitelj,
  s.program_name                       AS program,
  s.login_name                         AS prijava,
  COUNT(*)                             AS sej,
  SUM(CASE WHEN r.session_id IS NOT NULL THEN 1 ELSE 0 END) AS aktivnih_zdaj,
  SUM(s.cpu_time) / 1000               AS cpu_s_skupaj,
  SUM(s.logical_reads)                 AS branj_skupaj,
  SUM(s.writes)                        AS pisanj_skupaj,
  MIN(s.login_time)                    AS prijavljen_od,
  MAX(s.last_request_start_time)       AS zadnja_zahteva
FROM sys.dm_exec_sessions AS s
LEFT JOIN sys.dm_exec_requests AS r ON r.session_id = s.session_id
WHERE s.is_user_process = 1 AND s.session_id <> @@SPID
GROUP BY s.host_process_id, s.host_name, s.program_name, s.login_name
ORDER BY cpu_s_skupaj DESC;

/* 1 - trenutno aktivne zahteve, najdrazje najprej ---------------------------------------------- */
SELECT TOP (25)
  r.session_id,
  s.host_process_id                    AS pid,
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

/* 2 - seje po bazi, programu in gostitelju ------------------------------------------------------ */
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

/* 3 - najdrazje poizvedbe v predpomnilniku nacrtov ---------------------------------------------- */
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

/* 4 - kdo drzi razporejevalnik ------------------------------------------------------------------ */
SELECT LeaseKey, Owner, HostName, ProcessId, Application, AcquiredUtc, HeartbeatUtc, ExpiresUtc, TickCount, CanRunCycles
FROM ops.SchedulerLease;

-- Iz katerih gostiteljev so tekli zagoni v zadnjih 24 h. Vec kot en gostitelj = vec razporejevalnikov.
SELECT HostName, StartedBy, TriggeredBy, COUNT(*) AS zagonov, MIN(StartedUtc) AS prvi, MAX(StartedUtc) AS zadnji
FROM ops.JobRun
WHERE StartedUtc >= DATEADD(HOUR, -24, SYSUTCDATETIME())
GROUP BY HostName, StartedBy, TriggeredBy
ORDER BY zagonov DESC;

/* 5 - zasedenost po poslih v zadnjih 24 h ------------------------------------------------------- */
-- zasedenost_pct = koliko odstotkov dneva posel tece. Nad ~30 % je razmik prekratek za to trajanje;
-- nad 100 % se posel sam sebi nalaga (takoj ko konca, je spet na vrsti).
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

/* 6 - prekrivanje: koliko poslov je teklo hkrati, po urah --------------------------------------- */
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
  -- 60 minut teka v uri = en posel ves cas; 180 = v povprecju trije hkrati.
  STRING_AGG(CONVERT(nvarchar(max), r.JobKey), N', ') WITHIN GROUP (ORDER BY r.StartedUtc) AS posli
FROM ure AS u
LEFT JOIN ops.JobRun AS r
  ON r.StartedUtc < DATEADD(HOUR, 1, u.ura)
 AND COALESCE(r.EndedUtc, SYSUTCDATETIME()) > u.ura
 AND r.Status <> N'Blocked'
GROUP BY u.ura
ORDER BY u.ura DESC;

/* 7 - najdaljsi koraki v zadnjih 24 h ----------------------------------------------------------- */
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

/* 8 - trenutni urnik in odvisnosti -------------------------------------------------------------- */
SELECT JobKey, Label, IsEnabled, IntervalSeconds, DailyAtLocal, TimeoutSeconds, NextDueUtc,
       LastStartedUtc, LastEndedUtc, LastStatus, UpdatedBy, UpdatedUtc
FROM ops.JobDefinition
ORDER BY SortOrder;

SELECT JobKey, DependsOnJobKey, IsGate, TriggersDependent, MaxAgeSeconds, Note
FROM ops.JobDependency
WHERE TriggersDependent = 1
ORDER BY DependsOnJobKey;

/* 9 - posli in koraki, ki tecejo ZDAJ ----------------------------------------------------------- */
-- Korak se v ops.JobStepRun zapise sele, ko konca; trenutni korak je v ops.JobRun.CurrentStep.
SELECT r.JobRunId, r.JobKey, r.HostName, r.StartedBy, r.TriggeredBy, r.StartedUtc,
       DATEDIFF(MINUTE, r.StartedUtc, SYSUTCDATETIME()) AS tece_min,
       r.CurrentStep AS trenutni_korak, r.HeartbeatUtc
FROM ops.JobRun AS r
WHERE r.EndedUtc IS NULL AND r.Status = N'Running'
ORDER BY r.StartedUtc;
