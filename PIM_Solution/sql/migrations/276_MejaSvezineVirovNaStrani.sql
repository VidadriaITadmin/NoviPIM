/* 276: meja svežine vira se nastavi na strani posla, ne samo v kodi.

   Uporabnik 2026-09-24: »treba je še to mejo, ki je v kodi, da se spreminja za opozorila, al bom
   mogel vedno v kodo it?« Meja (ops.JobSource.MaxAgeSeconds, 256) je prihajala samo iz kode
   (JobCatalog.Sources); gostitelj jo ob vsakem zagonu prepiše z ops.EnsureJobSource, zato ročni
   popravek v bazi ni zdržal.

   Kaj naredi:
     1. ops.JobSource.MaxAgeSecondsOverride — meja, ki jo nastavi skrbnik na /sistem/opravila/<posel>.
        NULL = velja meja iz kode. ops.EnsureJobSource tega stolpca ne pozna, zato ga gostitelj ne
        prepiše; MaxAgeSeconds ostane privzeta vrednost iz kode.
     2. ops.JobSourceState(): MaxAgeSeconds je zdaj veljavna meja (preglas ali koda), dodana
        DefaultMaxAgeSeconds in IsMaxAgeOverridden. Stanje Stale in alarm SourceStale
        (ops.EvaluateJobAlerts bere to funkcijo) zato sledita meji s strani brez spremembe procedure.
     3. intranet.GetJobSourceState vrne še DefaultMaxAgeSeconds in IsMaxAgeOverridden.
     4. intranet.SetJobSourceMaxAge — zapis ali brisanje preglasa (NULL = nazaj na mejo iz kode).

   Ročni korak: ne. Sled spremembe zapiše intranet (ops.LogUserActivity, JOB_SOURCE_MAX_AGE). */
SET XACT_ABORT ON;
SET NOCOUNT ON;
GO

IF OBJECT_ID(N'ops.JobSource', N'U') IS NULL
  THROW 52760, N'276: ops.JobSource ne obstaja (najprej migracija 256).', 1;
GO

/* ── 1. Preglas meje ────────────────────────────────────────────────────────────── */
IF COL_LENGTH(N'ops.JobSource', N'MaxAgeSecondsOverride') IS NULL
  ALTER TABLE ops.JobSource ADD MaxAgeSecondsOverride int NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_JobSource_MaxAgeOverride')
  ALTER TABLE ops.JobSource ADD CONSTRAINT CK_JobSource_MaxAgeOverride
    CHECK (MaxAgeSecondsOverride IS NULL OR MaxAgeSecondsOverride BETWEEN 60 AND 2592000);
GO

/* ── 2. Stanje virov z veljavno mejo ────────────────────────────────────────────── */
CREATE OR ALTER FUNCTION ops.JobSourceState()
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
  SELECT js.JobKey, js.Pipeline, js.SourceCode, js.Label,
         MaxAgeSeconds = COALESCE(js.MaxAgeSecondsOverride, js.MaxAgeSeconds),
         DefaultMaxAgeSeconds = js.MaxAgeSeconds,
         IsMaxAgeOverridden = CONVERT(bit, CASE WHEN js.MaxAgeSecondsOverride IS NULL THEN 0 ELSE 1 END),
         js.PerOrganization, js.MeasureNewData, js.SortOrder, js.CreatedUtc,
         OrganizationId = CASE WHEN js.PerOrganization = 1 THEN podjetje.OrganizationId END,
         OrganizationName = CASE WHEN js.PerOrganization = 1 THEN podjetje.Name END
  FROM ops.JobSource js
  LEFT JOIN podjetja podjetje ON js.PerOrganization = 1
  WHERE js.IsActive = 1 AND (js.PerOrganization = 0 OR podjetje.OrganizationId IS NOT NULL)
),
faze AS
(
  SELECT v.JobKey, v.Pipeline, v.SourceCode, v.OrganizationId,
         LastContactUtc = MAX(CASE WHEN f.Status = N'Succeeded' THEN COALESCE(f.EndedUtc, f.StartedUtc) END),
         LastNewDataUtc = MAX(CASE WHEN f.Status = N'Succeeded' AND f.HasNewData = 1 THEN COALESCE(f.EndedUtc, f.StartedUtc) END),
         LastFailureUtc = MAX(CASE WHEN f.Status = N'Failed' THEN COALESCE(f.EndedUtc, f.StartedUtc) END),
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
         WHEN f.LastFailureUtc IS NOT NULL AND (f.LastContactUtc IS NULL OR f.LastFailureUtc > f.LastContactUtc) THEN N'Failed'
         WHEN CASE WHEN v.MeasureNewData = 1 THEN f.LastNewDataUtc ELSE f.LastContactUtc END IS NULL
           THEN CASE WHEN v.CreatedUtc < DATEADD(second, -v.MaxAgeSeconds, SYSUTCDATETIME()) THEN N'Stale' ELSE N'Unknown' END
         WHEN CASE WHEN v.MeasureNewData = 1 THEN f.LastNewDataUtc ELSE f.LastContactUtc END < DATEADD(second, -v.MaxAgeSeconds, SYSUTCDATETIME()) THEN N'Stale'
         ELSE N'Fresh' END,
       v.DefaultMaxAgeSeconds, v.IsMaxAgeOverridden
FROM viri v
LEFT JOIN faze f ON f.JobKey = v.JobKey AND f.Pipeline = v.Pipeline AND f.SourceCode = v.SourceCode
  AND ((f.OrganizationId IS NULL AND v.OrganizationId IS NULL) OR f.OrganizationId = v.OrganizationId)
OUTER APPLY (SELECT TOP (1) p.Message, p.Status, p.PhaseCode, p.ItemsOut, p.ItemsRejected FROM ops.JobPhaseRun p WHERE p.JobPhaseRunId = f.LastPhaseId) zadnja;
GO

/* ── 3. Branje za stran ─────────────────────────────────────────────────────────── */
CREATE OR ALTER PROCEDURE intranet.GetJobSourceState @JobKey nvarchar(60) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SELECT JobKey, Pipeline, SourceCode, Label, OrganizationId, OrganizationName, MaxAgeSeconds, MeasureNewData, SortOrder,
         LastContactUtc, LastNewDataUtc, LastFailureUtc, BasisUtc, LastMessage, LastStatus, LastPhaseCode, LastItemsOut, LastItemsRejected, State,
         AgeSeconds = CASE WHEN BasisUtc IS NULL THEN NULL ELSE DATEDIFF(second, BasisUtc, SYSUTCDATETIME()) END,
         DefaultMaxAgeSeconds, IsMaxAgeOverridden
  FROM ops.JobSourceState()
  WHERE @JobKey IS NULL OR JobKey = @JobKey
  ORDER BY JobKey, SortOrder, SourceCode, OrganizationId;
END;
GO

/* ── 4. Zapis preglasa ──────────────────────────────────────────────────────────── */
/* @MaxAgeSeconds NULL ali enak meji iz kode = preglas se odstrani (velja koda). Meja velja za vir v vseh
   podjetjih; alarm SourceStale jo upošteva ob naslednjem ops.EvaluateJobAlerts (tik gostitelja). */
CREATE OR ALTER PROCEDURE intranet.SetJobSourceMaxAge
  @JobKey nvarchar(60), @Pipeline nvarchar(100), @SourceCode nvarchar(100), @MaxAgeSeconds int = NULL,
  @Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  IF @MaxAgeSeconds IS NOT NULL AND (@MaxAgeSeconds < 60 OR @MaxAgeSeconds > 2592000)
    THROW 52761, N'Meja svežine mora biti med 1 minuto in 30 dnevi.', 1;

  UPDATE ops.JobSource
  SET MaxAgeSecondsOverride = CASE WHEN @MaxAgeSeconds = MaxAgeSeconds THEN NULL ELSE @MaxAgeSeconds END,
      UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = @Actor
  WHERE JobKey = @JobKey AND Pipeline = @Pipeline AND SourceCode = @SourceCode AND IsActive = 1;

  IF @@ROWCOUNT = 0
    THROW 52762, N'Vir posla ne obstaja ali je izklopljen.', 1;
END;
GO

/* ── Preverjanje ────────────────────────────────────────────────────────────────── */
IF COL_LENGTH(N'ops.JobSource', N'MaxAgeSecondsOverride') IS NULL
   OR OBJECT_ID(N'intranet.SetJobSourceMaxAge', N'P') IS NULL
   OR CHARINDEX(N'MaxAgeSecondsOverride', OBJECT_DEFINITION(OBJECT_ID(N'ops.JobSourceState'))) = 0
   OR CHARINDEX(N'IsMaxAgeOverridden', OBJECT_DEFINITION(OBJECT_ID(N'intranet.GetJobSourceState'))) = 0
  THROW 52763, N'276: meja svežine s strani ni nameščena.', 1;
GO
