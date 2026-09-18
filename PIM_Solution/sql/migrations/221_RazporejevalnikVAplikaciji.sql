/*
  221 — razporejevalnik v aplikaciji: cikli tecejo v intranetu, ne glede na gostitelja.

  Zakaj
  -----
  Do te migracije je cikle (zaloga, katalog, nadzor, nocni tok, samotest) sprozala nacrtovana
  naloga Windows, registrirana pod racunom cloveka na razvojnem racunalniku
  (scripts\Namesti-opravila.ps1). Pod IIS to ne deluje: aplikacijski bazen nalog drugega
  uporabnika ne vidi (schtasks: "Access is denied"), registrirati jih ne sme, objavljen intranet
  pa nad sabo nima ne PIM.sln ne sqlcmd, ki ju skripte potrebujejo. Uporabnik 2026-09-17:
  "naredi mi, da mi bodo workerji delali ne glede, kje je aplikacija postavljena".

  Odslej je ura v aplikaciji: PIM.Intranet ima gostujoco storitev (WorkerSchedulerService), ki
  vsakih 30 s pogleda, kateri cikel je na vrsti, in ga pozene v svojem procesu — isti workerji in
  isti vrstni red korakov kot v skriptah. Kar mora ta migracija dati bazi:

    ops.SchedulerLease    EN razporejevalnik naenkrat. Intranet lahko tece veckrat nad isto bazo
                          (IIS + Visual Studio, dva bazena, dve napravi); cikle sme poganjati samo
                          tisti, ki drzi najem, ostali cakajo. Najem se obnavlja z utripom in
                          potece sam, ce proces izgine.
    ops.WorkerCycle       razpored in stanje na cikel: razmik ali dnevna ura, vklop, kdaj je
                          naslednjic na vrsti, kaj tece zdaj in kako se je koncal zadnji zagon.
    ops.WorkerCycleRun    zgodovina: ena vrstica na zagon cikla, s korakom v teku in utripom.
    ops.WorkerCycleStep   koraki zagona s trajanjem in izhodno kodo — dnevnik, ki ga ni treba
                          brati iz datotek.

  Podvajanje. ops.ClaimWorkerCycle je edina pot do zagona cikla: pod kljucem vrstice preveri, da
  cikel ne tece (RunningRunId) in da je na vrsti (NextDueUtc), in ga v istem koraku oznaci kot
  tekocega. Dva gostitelja, ki bi hkrati ugotovila "na vrsti je", dobita en zagon in en "ze tece".
  Prekrivanje na ravni posameznega postopka in podjetja ostaja pri ops.BeginRun (sp_getapplock).

  Zaostanek. Uporabnik: "ce je na 5 min nastavljen in je ze 10 min v mirovanju, je treba
  opozorilo dati". ops.RaiseOverdueAlerts (klice jo razporejevalnik ob vsakem tiku) odpre alarm
  CycleOverdue za cikel in PipelineOverdue za postopek iz ops.ScheduleProfile, kadar od zadnjega
  zacetka mine vec kot WarnAfterMultiplier (privzeto 2) x razmik; alarm se zapre sam, ko cikel
  oziroma postopek spet tece. Doslej je ops.RunWatchdog oznacil "Stale" samo tek, ki je bil v
  teku in je nehal utripati; postopek, ki se sploh ni zacel, je bil videti zdrav.

  Uskladitev razporedov s cikli, ki jih res poganjajo (sicer bi novo pravilo o zaostanku odpiralo
  alarme za vrstice, ki so bile napacno nastavljene ze prej):
    GENERIC_XML                 300 s -> 86400 s: dobaviteljev XML (19 MB) bere samo nocni tok
    STOCK_REPLENISHMENT_DIGEST  ostane 86400 s; odslej ga nocni tok tudi res pozene
    MAGENTO_PRODUCTS            podjetja 1, 3 in 4 izklopljena: katalog.csv je en par datotek
                                samo za podjetje 2 (uporabnik 2026-09-15, -PodjetjeKataloga)
    SAOP_ORDERS                 izklopljen: nadomescen z SAOP_ORDERS_VNK in SAOP_ORDERS_VND (210)
  Nic ni pobrisano; vrstice ostanejo in jih skrbnik vklopi nazaj na /sistem?pogled=postopki.

  Zvonec. intranet.UserAlertSubscription (214) ima zaprt seznam vrst; brez razsiritve novih
  alarmov nihce ne bi videl v zvoncu. Dodane so CycleOverdue, PipelineOverdue in tudi
  PipelinePaused (167), ki je v seznamu manjkala ze prej; skrbniki so nanje naroceni kot v 214.

  Cas ostaja UTC. Dnevna ura cikla (DailyAtLocal) je nasa ura; v UTC jo pretvori intranet
  (PimTime), ker je edini, ki ve, po katerem pasu kaze.
*/

SET XACT_ABORT ON;

/* --- 1 — najem: kdo je ura ---------------------------------------------------- */

IF OBJECT_ID(N'ops.SchedulerLease', N'U') IS NULL
BEGIN
  CREATE TABLE ops.SchedulerLease
  (
    LeaseKey nvarchar(40) NOT NULL CONSTRAINT PK_SchedulerLease PRIMARY KEY,
    Owner nvarchar(200) NOT NULL,
    HostName nvarchar(200) NOT NULL,
    ProcessId int NOT NULL,
    Application nvarchar(200) NOT NULL,
    AcquiredUtc datetime2(3) NOT NULL,
    HeartbeatUtc datetime2(3) NOT NULL,
    ExpiresUtc datetime2(3) NOT NULL,
    TickCount bigint NOT NULL CONSTRAINT DF_SchedulerLease_TickCount DEFAULT (0),
    CanRunCycles bit NOT NULL CONSTRAINT DF_SchedulerLease_CanRunCycles DEFAULT (1)
  );
END;

/* Intranet brez workerjev (objava brez mape Workerji, zacasna kopija brez izvorne kode) najem sme
   vzeti samo, dokler ga nima nihce drug, da vsaj alarmi zastalosti tecejo; intranet, ki cikle
   lahko pozene, mu ga sme vzeti. Sicer bi prazna kopija drzala uro, cikli pa bi stali. */
IF COL_LENGTH(N'ops.SchedulerLease', N'CanRunCycles') IS NULL
  ALTER TABLE ops.SchedulerLease ADD CanRunCycles bit NOT NULL CONSTRAINT DF_SchedulerLease_CanRunCycles DEFAULT (1);

/* --- 2 — cikli: razpored in zadnje stanje ------------------------------------- */

IF OBJECT_ID(N'ops.WorkerCycle', N'U') IS NULL
BEGIN
  CREATE TABLE ops.WorkerCycle
  (
    CycleKey nvarchar(40) NOT NULL CONSTRAINT PK_WorkerCycle PRIMARY KEY,
    Label nvarchar(100) NOT NULL,
    SortOrder int NOT NULL CONSTRAINT DF_WorkerCycle_SortOrder DEFAULT (0),
    IsEnabled bit NOT NULL CONSTRAINT DF_WorkerCycle_IsEnabled DEFAULT (1),
    IntervalSeconds int NULL,
    DailyAtLocal time(0) NULL,
    WarnAfterMultiplier decimal(4,1) NOT NULL CONSTRAINT DF_WorkerCycle_Warn DEFAULT (2.0),
    NextDueUtc datetime2(3) NULL,
    RunningRunId bigint NULL,
    RunningSinceUtc datetime2(3) NULL,
    RunningHost nvarchar(200) NULL,
    LastStartedUtc datetime2(3) NULL,
    LastEndedUtc datetime2(3) NULL,
    LastStatus nvarchar(20) NULL,
    LastExitCode int NULL,
    LastDurationMs int NULL,
    LastTriggeredBy nvarchar(30) NULL,
    LastHost nvarchar(200) NULL,
    LastStepsFailed int NULL,
    LastError nvarchar(2000) NULL,
    CreatedUtc datetime2(3) NOT NULL CONSTRAINT DF_WorkerCycle_CreatedUtc DEFAULT SYSUTCDATETIME(),
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_WorkerCycle_UpdatedUtc DEFAULT SYSUTCDATETIME(),
    UpdatedBy nvarchar(200) NOT NULL CONSTRAINT DF_WorkerCycle_UpdatedBy DEFAULT N'221_RazporejevalnikVAplikaciji',
    /* Bodisi razmik bodisi dnevna ura; oboje hkrati ali nic od tega ni razpored. */
    CONSTRAINT CK_WorkerCycle_Schedule CHECK (
      (IntervalSeconds IS NOT NULL AND IntervalSeconds >= 60 AND DailyAtLocal IS NULL)
      OR (IntervalSeconds IS NULL AND DailyAtLocal IS NOT NULL)),
    CONSTRAINT CK_WorkerCycle_Warn CHECK (WarnAfterMultiplier >= 1.0)
  );
END;

/* --- 3 — zgodovina zagonov in njihovi koraki ---------------------------------- */

IF OBJECT_ID(N'ops.WorkerCycleRun', N'U') IS NULL
BEGIN
  CREATE TABLE ops.WorkerCycleRun
  (
    WorkerCycleRunId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_WorkerCycleRun PRIMARY KEY,
    CycleKey nvarchar(40) NOT NULL,
    StartedUtc datetime2(3) NOT NULL CONSTRAINT DF_WorkerCycleRun_StartedUtc DEFAULT SYSUTCDATETIME(),
    EndedUtc datetime2(3) NULL,
    Status nvarchar(20) NOT NULL CONSTRAINT DF_WorkerCycleRun_Status DEFAULT N'Running',
    ExitCode int NULL,
    TriggeredBy nvarchar(30) NOT NULL,
    StartedBy nvarchar(200) NOT NULL,
    HostName nvarchar(200) NOT NULL,
    LogPath nvarchar(800) NULL,
    HeartbeatUtc datetime2(3) NOT NULL CONSTRAINT DF_WorkerCycleRun_HeartbeatUtc DEFAULT SYSUTCDATETIME(),
    CurrentStep nvarchar(200) NULL,
    StepsTotal int NOT NULL CONSTRAINT DF_WorkerCycleRun_StepsTotal DEFAULT (0),
    StepsFailed int NOT NULL CONSTRAINT DF_WorkerCycleRun_StepsFailed DEFAULT (0),
    ErrorLines int NOT NULL CONSTRAINT DF_WorkerCycleRun_ErrorLines DEFAULT (0),
    Summary nvarchar(2000) NULL,
    CONSTRAINT CK_WorkerCycleRun_Status CHECK (Status IN (N'Running', N'Succeeded', N'Failed', N'Cancelled', N'Abandoned')),
    CONSTRAINT CK_WorkerCycleRun_TriggeredBy CHECK (TriggeredBy IN (N'Scheduler', N'Human'))
  );
  CREATE INDEX IX_WorkerCycleRun_Cycle ON ops.WorkerCycleRun (CycleKey, StartedUtc DESC);
  CREATE INDEX IX_WorkerCycleRun_Started ON ops.WorkerCycleRun (StartedUtc DESC);
END;

IF OBJECT_ID(N'ops.WorkerCycleStep', N'U') IS NULL
BEGIN
  CREATE TABLE ops.WorkerCycleStep
  (
    WorkerCycleStepId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_WorkerCycleStep PRIMARY KEY,
    WorkerCycleRunId bigint NOT NULL CONSTRAINT FK_WorkerCycleStep_Run REFERENCES ops.WorkerCycleRun (WorkerCycleRunId),
    StepOrder int NOT NULL,
    StepName nvarchar(200) NOT NULL,
    OrganizationId int NULL,
    Command nvarchar(1000) NULL,
    StartedUtc datetime2(3) NOT NULL,
    EndedUtc datetime2(3) NULL,
    ExitCode int NULL,
    Status nvarchar(20) NOT NULL,
    Note nvarchar(2000) NULL,
    CONSTRAINT CK_WorkerCycleStep_Status CHECK (Status IN (N'Succeeded', N'Failed', N'Skipped', N'Cancelled'))
  );
  CREATE INDEX IX_WorkerCycleStep_Run ON ops.WorkerCycleStep (WorkerCycleRunId, StepOrder);
END;

/* --- 4 — cikli, kot jih poganjajo skripte (isti razmiki kot v Namesti-opravila.ps1) --- */

MERGE ops.WorkerCycle AS target
USING (VALUES
  (N'zaloga',    N'Zaloga in cene',   10, 300,  NULL),
  (N'katalog',   N'Katalog za splet', 20, 3600, NULL),
  (N'nadzor',    N'Nadzor in alarmi', 30, 300,  NULL),
  (N'nocni-tok', N'Nočni tok',        40, NULL, CONVERT(time(0), '02:30')),
  (N'samotest',  N'Nočni samotest',   50, NULL, CONVERT(time(0), '04:30'))
) AS source (CycleKey, Label, SortOrder, IntervalSeconds, DailyAtLocal)
ON target.CycleKey = source.CycleKey
WHEN NOT MATCHED THEN
  INSERT (CycleKey, Label, SortOrder, IntervalSeconds, DailyAtLocal)
  VALUES (source.CycleKey, source.Label, source.SortOrder, source.IntervalSeconds, source.DailyAtLocal);

/* --- 5 — najem -------------------------------------------------------------- */

EXEC(N'CREATE OR ALTER PROCEDURE ops.AcquireSchedulerLease
  @Owner nvarchar(200), @HostName nvarchar(200), @ProcessId int, @Application nvarchar(200), @TtlSeconds int = 90,
  /* Privzeto 0: klicatelj, ki ne pove, da cikle lahko pozene (starejsa razlicica intraneta), uro
     drzi samo, dokler je ne zahteva tak, ki to pove. */
  @CanRunCycles bit = 0
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  DECLARE @now datetime2(3) = SYSUTCDATETIME(), @acquired bit = 0;
  BEGIN TRAN;
    DECLARE @current nvarchar(200), @expires datetime2(3), @currentCanRun bit;
    SELECT @current = Owner, @expires = ExpiresUtc, @currentCanRun = CanRunCycles
    FROM ops.SchedulerLease WITH (UPDLOCK, HOLDLOCK) WHERE LeaseKey = N''PIM'';

    IF @current IS NULL
    BEGIN
      INSERT ops.SchedulerLease (LeaseKey, Owner, HostName, ProcessId, Application, AcquiredUtc, HeartbeatUtc, ExpiresUtc, CanRunCycles)
      VALUES (N''PIM'', @Owner, @HostName, @ProcessId, @Application, @now, @now, DATEADD(second, @TtlSeconds, @now), @CanRunCycles);
      SET @acquired = 1;
    END
    ELSE IF @current = @Owner
    BEGIN
      UPDATE ops.SchedulerLease
      SET HeartbeatUtc = @now, ExpiresUtc = DATEADD(second, @TtlSeconds, @now), TickCount = TickCount + 1, CanRunCycles = @CanRunCycles
      WHERE LeaseKey = N''PIM'';
      SET @acquired = 1;
    END
    ELSE IF @expires < @now OR (@CanRunCycles = 1 AND @currentCanRun = 0)
    BEGIN
      /* Prejsnji lastnik je nehal utripati (proces je izginil, bazen recikliran) ali pa ciklov
         sploh ne more poganjati, ta klicatelj pa jih lahko — ura gre k tistemu, ki jo zna vrteti. */
      UPDATE ops.SchedulerLease
      SET Owner = @Owner, HostName = @HostName, ProcessId = @ProcessId, Application = @Application,
          AcquiredUtc = @now, HeartbeatUtc = @now, ExpiresUtc = DATEADD(second, @TtlSeconds, @now), TickCount = 0,
          CanRunCycles = @CanRunCycles
      WHERE LeaseKey = N''PIM'';
      SET @acquired = 1;
    END
  COMMIT;

  SELECT @acquired AS IsOwner, Owner, HostName, ProcessId, Application, AcquiredUtc, HeartbeatUtc, ExpiresUtc, TickCount, CanRunCycles
  FROM ops.SchedulerLease WHERE LeaseKey = N''PIM'';
END');

EXEC(N'CREATE OR ALTER PROCEDURE ops.ReleaseSchedulerLease @Owner nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON;
  DELETE FROM ops.SchedulerLease WHERE LeaseKey = N''PIM'' AND Owner = @Owner;
END');

/* --- 6 — zagon cikla: edina vrata ------------------------------------------- */

EXEC(N'CREATE OR ALTER PROCEDURE ops.ClaimWorkerCycle
  @CycleKey nvarchar(40), @NextDueUtc datetime2(3), @TriggeredBy nvarchar(30), @StartedBy nvarchar(200),
  @HostName nvarchar(200), @LogPath nvarchar(800) = NULL, @Force bit = 0,
  @WorkerCycleRunId bigint OUTPUT, @Reason nvarchar(200) OUTPUT
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  DECLARE @now datetime2(3) = SYSUTCDATETIME();
  SET @WorkerCycleRunId = NULL;
  BEGIN TRAN;
    DECLARE @enabled bit, @due datetime2(3), @running bigint, @runningHost nvarchar(200), @runningSince datetime2(3);
    SELECT @enabled = IsEnabled, @due = NextDueUtc, @running = RunningRunId, @runningHost = RunningHost, @runningSince = RunningSinceUtc
    FROM ops.WorkerCycle WITH (UPDLOCK, HOLDLOCK) WHERE CycleKey = @CycleKey;

    IF @enabled IS NULL
      SET @Reason = N''Unknown'';
    ELSE IF @running IS NOT NULL
      SET @Reason = CONCAT(N''Running:'', @runningHost, N'' od '', CONVERT(nvarchar(19), @runningSince, 120), N'' UTC'');
    ELSE IF @Force = 0 AND @enabled = 0
      SET @Reason = N''Disabled'';
    ELSE IF @Force = 0 AND @due IS NOT NULL AND @due > @now
      SET @Reason = N''NotDue'';
    ELSE
    BEGIN
      INSERT ops.WorkerCycleRun (CycleKey, StartedUtc, TriggeredBy, StartedBy, HostName, LogPath, HeartbeatUtc)
      VALUES (@CycleKey, @now, @TriggeredBy, @StartedBy, @HostName, @LogPath, @now);
      SET @WorkerCycleRunId = SCOPE_IDENTITY();

      /* Naslednji termin se steje od ZACETKA tega teka (isto pravilo kot ops.CompleteRun od 118):
         sicer bi se razmik sesteval s trajanjem. Tudi rocni zagon prestavi ritem — kdor je
         pravkar pognal cikel, noce, da ga ura cez minuto pozene se enkrat. */
      UPDATE ops.WorkerCycle
      SET RunningRunId = @WorkerCycleRunId, RunningSinceUtc = @now, RunningHost = @HostName,
          NextDueUtc = @NextDueUtc, LastStartedUtc = @now, LastTriggeredBy = @TriggeredBy, LastHost = @HostName
      WHERE CycleKey = @CycleKey;
      SET @Reason = N''Claimed'';
    END
  COMMIT;
END');

EXEC(N'CREATE OR ALTER PROCEDURE ops.HeartbeatWorkerCycle @WorkerCycleRunId bigint, @CurrentStep nvarchar(200) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  UPDATE ops.WorkerCycleRun SET HeartbeatUtc = SYSUTCDATETIME(), CurrentStep = @CurrentStep
  WHERE WorkerCycleRunId = @WorkerCycleRunId AND Status = N''Running'';
END');

EXEC(N'CREATE OR ALTER PROCEDURE ops.RecordWorkerCycleStep
  @WorkerCycleRunId bigint, @StepOrder int, @StepName nvarchar(200), @OrganizationId int = NULL,
  @Command nvarchar(1000) = NULL, @StartedUtc datetime2(3), @EndedUtc datetime2(3), @ExitCode int = NULL,
  @Status nvarchar(20), @Note nvarchar(2000) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  INSERT ops.WorkerCycleStep (WorkerCycleRunId, StepOrder, StepName, OrganizationId, Command, StartedUtc, EndedUtc, ExitCode, Status, Note)
  VALUES (@WorkerCycleRunId, @StepOrder, @StepName, @OrganizationId, @Command, @StartedUtc, @EndedUtc, @ExitCode, @Status, @Note);
END');

EXEC(N'CREATE OR ALTER PROCEDURE ops.CompleteWorkerCycle
  @WorkerCycleRunId bigint, @Status nvarchar(20), @ExitCode int = NULL, @StepsTotal int = 0, @StepsFailed int = 0,
  @ErrorLines int = 0, @Summary nvarchar(2000) = NULL, @Actor nvarchar(200) = N''razporejevalnik''
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  DECLARE @now datetime2(3) = SYSUTCDATETIME(), @cycle nvarchar(40), @started datetime2(3);
  SELECT @cycle = CycleKey, @started = StartedUtc FROM ops.WorkerCycleRun WHERE WorkerCycleRunId = @WorkerCycleRunId;

  UPDATE ops.WorkerCycleRun
  SET EndedUtc = @now, Status = @Status, ExitCode = @ExitCode, StepsTotal = @StepsTotal, StepsFailed = @StepsFailed,
      ErrorLines = @ErrorLines, Summary = @Summary, CurrentStep = NULL
  WHERE WorkerCycleRunId = @WorkerCycleRunId AND Status = N''Running'';

  UPDATE ops.WorkerCycle
  SET RunningRunId = NULL, RunningSinceUtc = NULL, RunningHost = NULL,
      LastEndedUtc = @now, LastStatus = @Status, LastExitCode = @ExitCode,
      LastDurationMs = CASE WHEN @started IS NULL THEN NULL ELSE DATEDIFF(second, @started, @now) * 1000 END,
      LastStepsFailed = @StepsFailed,
      LastError = CASE WHEN @Status = N''Succeeded'' THEN NULL ELSE @Summary END
  WHERE CycleKey = @cycle AND RunningRunId = @WorkerCycleRunId;

  /* Cikel je tekel: alarm o zastalem ciklu ne velja vec. */
  UPDATE ops.Alert
  SET ResolvedUtc = @now, ResolvedBy = @Actor, UpdatedUtc = @now, UpdatedBy = @Actor
  WHERE AlertKind = N''CycleOverdue'' AND Pipeline = CONCAT(N''CIKEL:'', @cycle) AND ResolvedUtc IS NULL;
END');

EXEC(N'CREATE OR ALTER PROCEDURE ops.AbandonWorkerCycleRuns
  @HostName nvarchar(200), @Actor nvarchar(200), @StaleMinutes int = 30
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  /* Dva razloga, isti izid. Ob zagonu razporejevalnika noben tek TEGA gostitelja iz prejsnjega
     procesa ne tece vec — proces je izginil in tega ni povedal nihce. Tuj tek brez utripa dlje
     od @StaleMinutes je enako mrtev, ceprav je bil na drugem gostitelju. Abandoned je izrecen in
     ni Failed (144): "nikoli se ni zaprlo" in "padlo je" sta razlicni stvari. */
  DECLARE @now datetime2(3) = SYSUTCDATETIME();
  DECLARE @mrtvi TABLE (WorkerCycleRunId bigint PRIMARY KEY, CycleKey nvarchar(40));

  UPDATE run
  SET Status = N''Abandoned'', EndedUtc = @now, CurrentStep = NULL,
      Summary = CONCAT(N''Zagon se ni koncal sam; zaprl ga je '', @Actor, N'' ob '', CONVERT(nvarchar(19), @now, 120), N'' UTC.'')
  OUTPUT inserted.WorkerCycleRunId, inserted.CycleKey INTO @mrtvi
  FROM ops.WorkerCycleRun run
  WHERE run.Status = N''Running''
    AND (run.HostName = @HostName OR run.HeartbeatUtc < DATEADD(minute, -@StaleMinutes, @now));

  UPDATE cycle
  SET RunningRunId = NULL, RunningSinceUtc = NULL, RunningHost = NULL,
      LastEndedUtc = @now, LastStatus = N''Abandoned''
  FROM ops.WorkerCycle cycle
  INNER JOIN @mrtvi mrtev ON mrtev.WorkerCycleRunId = cycle.RunningRunId;

  SELECT COUNT(*) AS ZaprtihZagonov FROM @mrtvi;
END');

/* --- 7 — zaostanek: alarm, ko cikel ali postopek ne tece 2x svojega razmika --- */

EXEC(N'CREATE OR ALTER PROCEDURE ops.RaiseOverdueAlerts @Actor nvarchar(200) = N''razporejevalnik''
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  DECLARE @now datetime2(3) = SYSUTCDATETIME();
  /* ops.Alert zahteva podjetje; cikel ni vezan na nobeno, zato gre pod prvo aktivno (enako kot
     WATCHDOG in ALERT_DISPATCH tečeta pod enim podjetjem). */
  DECLARE @org int = (SELECT MIN(OrganizationId) FROM dbo.OrganizationConfig WHERE IsActive = 1);
  IF @org IS NULL RETURN;

  /* Cikli. Merilo je zacetek zadnjega zagona; cikel, ki se ni tekel nikoli, se steje od trenutka,
     ko je bil nazadnje nastavljen (UpdatedUtc) — nov ali pravkar vklopljen cikel ni takoj zastal. */
  DECLARE @cikli TABLE (Pipeline nvarchar(200), DedupKey varchar(64), Title nvarchar(300), Summary nvarchar(2000));
  INSERT @cikli (Pipeline, DedupKey, Title, Summary)
  SELECT CONCAT(N''CIKEL:'', c.CycleKey),
         CONVERT(varchar(64), HASHBYTES(''SHA2_256'', CONCAT(N''CycleOverdue:'', c.CycleKey)), 2),
         CONCAT(N''Cikel "'', c.Label, N''" ni tekel '', DATEDIFF(minute, COALESCE(c.LastStartedUtc, c.UpdatedUtc), @now), N'' min (razmik '',
                CASE WHEN c.IntervalSeconds IS NULL THEN N''1 dan'' ELSE CONCAT(c.IntervalSeconds / 60, N'' min'') END, N'')''),
         CONCAT(N''Zadnji zacetek: '', COALESCE(CONVERT(nvarchar(19), c.LastStartedUtc, 120), N''nikoli''), N'' UTC. '',
                N''Naslednji termin: '', COALESCE(CONVERT(nvarchar(19), c.NextDueUtc, 120), N''takoj''), N'' UTC. '',
                N''Razporejevalnik v aplikaciji ga ni pognal — preveri, ali intranet tece in drzi najem (/sistem/workerji).'')
  FROM ops.WorkerCycle c
  WHERE c.IsEnabled = 1 AND c.RunningRunId IS NULL
    AND DATEDIFF(second, COALESCE(c.LastStartedUtc, c.UpdatedUtc), @now) > c.WarnAfterMultiplier * COALESCE(c.IntervalSeconds, 86400);

  MERGE ops.Alert AS target
  USING (SELECT Pipeline, DedupKey, Title, Summary FROM @cikli) AS source
    ON target.OrganizationId = @org AND target.DedupKey = source.DedupKey AND target.ResolvedUtc IS NULL
  WHEN MATCHED THEN UPDATE SET LastSeenUtc = @now, OccurrenceCount = target.OccurrenceCount + 1, Title = source.Title,
                               PayloadSummaryRedacted = source.Summary, UpdatedUtc = @now, UpdatedBy = @Actor
  WHEN NOT MATCHED THEN INSERT (OrganizationId, Pipeline, AlertKind, Severity, DedupKey, Title, PayloadSummaryRedacted, UpdatedBy)
    VALUES (@org, source.Pipeline, N''CycleOverdue'', N''Critical'', source.DedupKey, source.Title, source.Summary, @Actor);

  UPDATE alert SET ResolvedUtc = @now, ResolvedBy = @Actor, UpdatedUtc = @now, UpdatedBy = @Actor
  FROM ops.Alert alert
  WHERE alert.AlertKind = N''CycleOverdue'' AND alert.ResolvedUtc IS NULL
    AND NOT EXISTS (SELECT 1 FROM @cikli c WHERE c.DedupKey = alert.DedupKey);

  /* Postopki iz ops.ScheduleProfile: merilo je zadnji utrip (BeginRun, Heartbeat, CompleteRun ga
     vsi premaknejo), zato steje vsaka dejavnost, tudi neuspel tek — "ne tece" pomeni tisino. */
  DECLARE @postopki TABLE (OrganizationId int, Pipeline nvarchar(200), DedupKey varchar(64), Title nvarchar(300), Summary nvarchar(2000));
  INSERT @postopki (OrganizationId, Pipeline, DedupKey, Title, Summary)
  SELECT p.OrganizationId, p.Pipeline,
         CONVERT(varchar(64), HASHBYTES(''SHA2_256'', CONCAT(N''PipelineOverdue:'', p.OrganizationId, N'':'', p.Pipeline)), 2),
         CONCAT(N''Postopek '', p.Pipeline, N'' ni tekel '', DATEDIFF(minute, COALESCE(h.LastHeartbeatUtc, p.UpdatedUtc), @now), N'' min (razmik '', p.IntervalSeconds / 60, N'' min)''),
         CONCAT(N''Podjetje: '', o.Name, N''. Zadnji utrip: '', COALESCE(CONVERT(nvarchar(19), h.LastHeartbeatUtc, 120), N''nikoli''), N'' UTC. '',
                N''Naslednji termin po razporedu: '', COALESCE(CONVERT(nvarchar(19), p.NextScheduledUtc, 120), N''takoj''), N'' UTC. '',
                N''Alarm se zapre sam ob naslednjem teku.'')
  FROM ops.ScheduleProfile p
  INNER JOIN dbo.OrganizationConfig o ON o.OrganizationId = p.OrganizationId
  LEFT JOIN ops.IntegrationHealth h ON h.OrganizationId = p.OrganizationId AND h.Pipeline = p.Pipeline
  WHERE p.IsEnabled = 1 AND o.IsActive = 1
    AND DATEDIFF(second, COALESCE(h.LastHeartbeatUtc, p.UpdatedUtc), @now) > 2 * p.IntervalSeconds;

  MERGE ops.Alert AS target
  USING (SELECT OrganizationId, Pipeline, DedupKey, Title, Summary FROM @postopki) AS source
    ON target.OrganizationId = source.OrganizationId AND target.DedupKey = source.DedupKey AND target.ResolvedUtc IS NULL
  WHEN MATCHED THEN UPDATE SET LastSeenUtc = @now, OccurrenceCount = target.OccurrenceCount + 1, Title = source.Title,
                               PayloadSummaryRedacted = source.Summary, UpdatedUtc = @now, UpdatedBy = @Actor
  WHEN NOT MATCHED THEN INSERT (OrganizationId, Pipeline, AlertKind, Severity, DedupKey, Title, PayloadSummaryRedacted, UpdatedBy)
    VALUES (source.OrganizationId, source.Pipeline, N''PipelineOverdue'', N''Critical'', source.DedupKey, source.Title, source.Summary, @Actor);

  UPDATE alert SET ResolvedUtc = @now, ResolvedBy = @Actor, UpdatedUtc = @now, UpdatedBy = @Actor
  FROM ops.Alert alert
  WHERE alert.AlertKind = N''PipelineOverdue'' AND alert.ResolvedUtc IS NULL
    AND NOT EXISTS (SELECT 1 FROM @postopki p WHERE p.DedupKey = alert.DedupKey AND p.OrganizationId = alert.OrganizationId);
END');

/* --- 8 — bralni modeli in nastavitve za /sistem/workerji ----------------------- */

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetWorkerCycles
AS
BEGIN
  SET NOCOUNT ON;
  SELECT c.CycleKey, c.Label, c.SortOrder, c.IsEnabled, c.IntervalSeconds, c.DailyAtLocal, c.WarnAfterMultiplier,
         c.NextDueUtc, c.RunningRunId, c.RunningSinceUtc, c.RunningHost,
         c.LastStartedUtc, c.LastEndedUtc, c.LastStatus, c.LastExitCode, c.LastDurationMs, c.LastTriggeredBy, c.LastHost,
         c.LastStepsFailed, c.LastError, c.UpdatedUtc, c.UpdatedBy,
         run.CurrentStep AS RunningStep, run.HeartbeatUtc AS RunningHeartbeatUtc,
         (SELECT COUNT(*) FROM ops.Alert a WHERE a.AlertKind = N''CycleOverdue'' AND a.Pipeline = CONCAT(N''CIKEL:'', c.CycleKey) AND a.ResolvedUtc IS NULL) AS OpenOverdueAlerts
  FROM ops.WorkerCycle c
  LEFT JOIN ops.WorkerCycleRun run ON run.WorkerCycleRunId = c.RunningRunId
  ORDER BY c.SortOrder, c.CycleKey;
END');

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetWorkerCycleRuns @Take int = 40, @CycleKey nvarchar(40) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SELECT TOP (@Take) run.WorkerCycleRunId, run.CycleKey, c.Label, run.StartedUtc, run.EndedUtc, run.Status, run.ExitCode,
         run.TriggeredBy, run.StartedBy, run.HostName, run.LogPath, run.HeartbeatUtc, run.CurrentStep,
         run.StepsTotal, run.StepsFailed, run.ErrorLines, run.Summary
  FROM ops.WorkerCycleRun run
  LEFT JOIN ops.WorkerCycle c ON c.CycleKey = run.CycleKey
  WHERE @CycleKey IS NULL OR run.CycleKey = @CycleKey
  ORDER BY run.StartedUtc DESC;
END');

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetWorkerCycleSteps @WorkerCycleRunId bigint
AS
BEGIN
  SET NOCOUNT ON;
  SELECT StepOrder, StepName, OrganizationId, Command, StartedUtc, EndedUtc, ExitCode, Status, Note
  FROM ops.WorkerCycleStep WHERE WorkerCycleRunId = @WorkerCycleRunId ORDER BY StepOrder;
END');

EXEC(N'CREATE OR ALTER PROCEDURE intranet.SaveWorkerCycle
  @CycleKey nvarchar(40), @IsEnabled bit, @IntervalSeconds int = NULL, @DailyAtLocal time(0) = NULL, @Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  IF @IntervalSeconds IS NOT NULL AND @IntervalSeconds < 60 THROW 52211, N''Razmik ne sme biti krajsi od 60 sekund.'', 1;
  IF @IntervalSeconds IS NOT NULL AND @IntervalSeconds > 86400 THROW 52212, N''Razmik ne sme biti daljsi od enega dneva.'', 1;
  IF (@IntervalSeconds IS NULL AND @DailyAtLocal IS NULL) OR (@IntervalSeconds IS NOT NULL AND @DailyAtLocal IS NOT NULL)
    THROW 52213, N''Cikel ima bodisi razmik bodisi dnevno uro.'', 1;

  /* Sprememba razporeda razveljavi izracunani naslednji termin: razporejevalnik ga ob naslednjem
     tiku izracuna na novo iz nove nastavitve (in ne caka na star termin). */
  UPDATE ops.WorkerCycle
  SET IsEnabled = @IsEnabled, IntervalSeconds = @IntervalSeconds, DailyAtLocal = @DailyAtLocal,
      NextDueUtc = NULL, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = @Actor
  WHERE CycleKey = @CycleKey;
  IF @@ROWCOUNT = 0 THROW 52214, N''Cikel ne obstaja.'', 1;
END');

EXEC(N'CREATE OR ALTER PROCEDURE ops.EnsureWorkerCycle
  @CycleKey nvarchar(40), @Label nvarchar(100), @SortOrder int, @IntervalSeconds int = NULL, @DailyAtLocal time(0) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  /* Nov cikel v kodi dobi vrstico brez migracije; obstojeca vrstica (skrbnikova nastavitev) se ne prepise. */
  IF NOT EXISTS (SELECT 1 FROM ops.WorkerCycle WHERE CycleKey = @CycleKey)
    INSERT ops.WorkerCycle (CycleKey, Label, SortOrder, IntervalSeconds, DailyAtLocal, UpdatedBy)
    VALUES (@CycleKey, @Label, @SortOrder, @IntervalSeconds, @DailyAtLocal, N''ops.EnsureWorkerCycle'');
  ELSE
    UPDATE ops.WorkerCycle SET Label = @Label, SortOrder = @SortOrder WHERE CycleKey = @CycleKey AND (Label <> @Label OR SortOrder <> @SortOrder);
END');

EXEC(N'CREATE OR ALTER PROCEDURE ops.SetWorkerCycleNextDue @CycleKey nvarchar(40), @NextDueUtc datetime2(3), @OnlyIfNull bit = 1
AS
BEGIN
  SET NOCOUNT ON;
  UPDATE ops.WorkerCycle SET NextDueUtc = @NextDueUtc
  WHERE CycleKey = @CycleKey AND (@OnlyIfNull = 0 OR NextDueUtc IS NULL);
END');

/* --- 9 — uskladitev razporedov s cikli, ki jih poganjajo -------------------------- */

EXEC sp_executesql N'
  UPDATE ops.ScheduleProfile
  SET IntervalSeconds = 86400, StaleAfterSeconds = 3 * 86400, UpdatedUtc = SYSUTCDATETIME(),
      UpdatedBy = N''221: dobaviteljev XML bere nocni tok''
  WHERE Pipeline = N''GENERIC_XML'' AND IntervalSeconds < 86400;

  UPDATE ops.ScheduleProfile
  SET IsEnabled = 0, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = N''221: katalog.csv je samo za podjetje 2''
  WHERE Pipeline = N''MAGENTO_PRODUCTS'' AND OrganizationId <> 2 AND IsEnabled = 1;

  UPDATE ops.ScheduleProfile
  SET IsEnabled = 0, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = N''221: nadomescen z SAOP_ORDERS_VNK/VND (210)''
  WHERE Pipeline = N''SAOP_ORDERS'' AND IsEnabled = 1;';

/* --- 10 — zvonec pozna nove vrste alarmov ----------------------------------------- */

/* Zaprt seznam se razsiri, ne prepise: kasnejsa migracija (222) je dodala svoje vrste, zato se
   omejitev sestavi iz vrst, ki so ze v tabeli, in teh treh — in samo takrat, kadar katera od treh
   se manjka. Sicer bi ponovni zagon te migracije (ali njen zagon za 222) podrl tuje vrstice (547). */
EXEC(N'
  DECLARE @definicija nvarchar(max) = (SELECT definition FROM sys.check_constraints WHERE name = N''CK_UserAlertSubscription_Kind'');
  IF @definicija IS NULL OR CHARINDEX(N''CycleOverdue'', @definicija) = 0
     OR CHARINDEX(N''PipelineOverdue'', @definicija) = 0 OR CHARINDEX(N''PipelinePaused'', @definicija) = 0
  BEGIN
    DECLARE @vrste nvarchar(max);
    SELECT @vrste = STRING_AGG(CONCAT(N''N'''''', REPLACE(AlertKind, N'''''''', N''''''''''''), N''''''''), N'', '')
    FROM (
      SELECT DISTINCT AlertKind FROM intranet.UserAlertSubscription
      UNION
      SELECT AlertKind FROM (VALUES
        (N''StaleHeartbeat''), (N''OutboundDead''), (N''OutboundDrift''), (N''StalledWatermark''),
        (N''PipelineDisabled''), (N''ReservationExcluded''), (N''OutboundUnacknowledged''),
        (N''PipelinePaused''), (N''CycleOverdue''), (N''PipelineOverdue'')) AS znane(AlertKind)
    ) AS vse;
    IF @definicija IS NOT NULL
      ALTER TABLE intranet.UserAlertSubscription DROP CONSTRAINT CK_UserAlertSubscription_Kind;
    EXEC(N''ALTER TABLE intranet.UserAlertSubscription ADD CONSTRAINT CK_UserAlertSubscription_Kind CHECK (AlertKind IN ('' + @vrste + N''))'');
  END');

INSERT intranet.UserAlertSubscription (UserName, AlertKind, UpdatedBy)
SELECT localUser.UserName, kind.AlertKind, N'221_RazporejevalnikVAplikaciji'
FROM sec.LocalUser localUser
INNER JOIN sec.LocalUserRole userRole ON userRole.LocalUserId = localUser.LocalUserId
INNER JOIN sec.Role roleValue ON roleValue.RoleId = userRole.RoleId AND roleValue.RoleCode = N'ADMIN'
CROSS JOIN (VALUES (N'PipelinePaused'), (N'CycleOverdue'), (N'PipelineOverdue')) AS kind(AlertKind)
WHERE NOT EXISTS (
  SELECT 1 FROM intranet.UserAlertSubscription existing
  WHERE existing.UserName = localUser.UserName AND existing.AlertKind = kind.AlertKind);

/* --- preverba ---------------------------------------------------------------- */

IF OBJECT_ID(N'ops.SchedulerLease', N'U') IS NULL OR OBJECT_ID(N'ops.WorkerCycle', N'U') IS NULL
   OR OBJECT_ID(N'ops.WorkerCycleRun', N'U') IS NULL OR OBJECT_ID(N'ops.WorkerCycleStep', N'U') IS NULL
  THROW 52215, 'Tabele razporejevalnika niso nastale.', 1;

IF OBJECT_ID(N'ops.AcquireSchedulerLease', N'P') IS NULL OR OBJECT_ID(N'ops.ClaimWorkerCycle', N'P') IS NULL
   OR OBJECT_ID(N'ops.CompleteWorkerCycle', N'P') IS NULL OR OBJECT_ID(N'ops.RaiseOverdueAlerts', N'P') IS NULL
   OR OBJECT_ID(N'intranet.GetWorkerCycles', N'P') IS NULL OR OBJECT_ID(N'intranet.SaveWorkerCycle', N'P') IS NULL
  THROW 52216, 'Procedure razporejevalnika niso nastale.', 1;

IF (SELECT COUNT(*) FROM ops.WorkerCycle WHERE CycleKey IN (N'zaloga', N'katalog', N'nadzor', N'nocni-tok', N'samotest')) <> 5
  THROW 52217, 'Pet ciklov ni zasejanih.', 1;
