/*
  237 — enotni model opravil: ops.JobDefinition, ops.JobRun, ops.JobStepRun, ops.JobDependency,
        ops.DataCheckpoint, ops.Artifact. Gostitelj avtomatike (PIM.AutomationHost) namesto ure v IIS.

  Zakaj
  -----
  Uporabnik 2026-09-21: »Problem ni število strani, ampak to, da so pomešani poslovni tokovi, urniki,
  worker procesi in nadzor.« Cikel »katalog« (221) je zaporedoma izvajal zajem artiklov, zajem
  naročil, validacijo in objavo štirih podjetij ter izvoz; naročila z objavo spletnega kataloga
  nimajo nobene poslovne odvisnosti in sta bila skupaj samo zato, ker oboje teče vsako uro.
  B2bWorker je z --osvezi-validacijo izvoz spremenil v validacijo. Urniki so obstajali na dveh
  ravneh (ops.WorkerCycle in ops.ScheduleProfile), cikel je po padcu ene skupine nadaljeval z
  naslednjimi (izvoz tudi po padlem vhodu), interni watchdog je nadziral sam sebe, ura pa je bila
  vezana na proces intraneta. Konkreten dokaz v razvojni bazi ob pisanju: WorkerCycleRunId 188 in
  192 sta bila 3,5 ure »Running« brez utripa, najem razporejevalnika pa je potekel ob 11:26 UTC.

  Kaj ta migracija da bazi
  ------------------------
    ops.JobDefinition   EN posel = ena odgovornost (zajem artiklov, zajem naročil, validacija, objava,
                        izvoz kataloga, izvoz cen in zaloge, nadzornik, alarmi, nočna uskladitev,
                        samotest ...), z urnikom, časovno mejo (timeout), SLA in poslovnim tokom
                        (Flow), po katerem nadzorna plošča sestavi štiri poslovne kartice.
    ops.JobDependency   dovoljene odvisnosti: vrata (IsGate — odvisen posel se ne izvede, če
                        predhodnik ni uspel ali je njegov uspeh prestar) in sprožilec
                        (TriggersDependent — uspeh predhodnika postavi odvisnega na vrsto takoj).
                        Objava teče samo po uspešni validaciji, izvoz samo iz uspešne objave.
    ops.JobRun          en konkreten zagon; vedno konča kot Succeeded, Warning, Failed, TimedOut,
                        Cancelled, Abandoned ali Blocked. Blokiran zagon je zapisan z razlogom in
                        predhodnikom, ki ga je blokiral — ne izvede se »vseeno«.
    ops.JobStepRun      tehnični koraki zagona (proces workerja ali SQL) s trajanjem in izidom;
                        koraki po padlem obveznem koraku so Blocked, ne tiho preskočeni.
    ops.DataCheckpoint  do katerega podatka smo prišli (zadnji uspešen zagon posla po podjetju).
    ops.Artifact        nastale datoteke (katalog.csv, stranke.csv, magento-stock-prices.csv):
                        pot, velikost, število vrstic, SHA-256 in čas — »splet trenutno uporablja
                        verzijo N«.

  Najem (ops.SchedulerLease) dobi Priority: gostitelj avtomatike (10) uro vzame intranetu (0), tudi
  kadar ta drži živ najem; intranet jo dobi nazaj samo, če gostitelj neha utripati. Intranet je odslej
  nadzorna konzola: ročni zagon je zahteva (ops.RequestJobRun), ki jo gostitelj prevzame ob naslednjem
  tiku; ustavitev je prav tako zahteva (ops.RequestJobCancel).

  Življenjski cikel. ops.AbandonStaleJobRuns zapre vsak Running zagon brez utripa dlje od 10 minut;
  kliče se ob vsakem tiku gostitelja, ne šele ob njegovem ponovnem zagonu. Bralni model
  (intranet.GetJobRuns) tak zagon že prej kaže kot Abandoned (EffectiveStatus). Časovna meja
  (TimeoutSeconds) je zapisana na zagonu; gostitelj ob preseženi meji ubije drevo procesov in zagon
  označi TimedOut.

  Alarmi. ops.EvaluateJobAlerts odpre JobOverdue (posel ni tekel dvakrat svojega razmika), JobFailed
  (zadnji zagon Failed/TimedOut/Abandoned), JobBlocked in AutomationHostDown (najem gostitelja
  manjka ali ne utripa 10 minut — to lahko odkrije samo nekdo drug: intranet, kadar drži rezervni
  najem, ali zunanje opravilo PIM.AutomationHost --preveri). Alarmi se zaprejo sami ob naslednjem
  uspešnem zagonu.

  Stari cikli (ops.WorkerCycle) ostanejo: intranet jih poganja samo, dokler ne teče noben gostitelj
  avtomatike (rezerva v prehodnem obdobju). Po dveh tednih vzporednega spremljanja jih skrbnik izklopi
  na /sistem/workerji; ta migracija jih ne briše in ne izklaplja.

  Čas ostaja UTC. Dnevna ura posla (DailyAtLocal) je naša ura; v UTC jo pretvori gostitelj.
*/

SET XACT_ABORT ON;

/* --- 1 — najem dobi prednost --------------------------------------------------- */

IF COL_LENGTH(N'ops.SchedulerLease', N'Priority') IS NULL
  ALTER TABLE ops.SchedulerLease ADD Priority int NOT NULL CONSTRAINT DF_SchedulerLease_Priority DEFAULT (0);

EXEC(N'CREATE OR ALTER PROCEDURE ops.AcquireSchedulerLease
  @Owner nvarchar(200), @HostName nvarchar(200), @ProcessId int, @Application nvarchar(200), @TtlSeconds int = 90,
  @CanRunCycles bit = 0,
  /* 237: gostitelj avtomatike (10) uro vzame vsakemu z nižjo prednostjo; intranet (0) jo dobi nazaj
     samo, kadar gostitelj neha utripati (najem poteče). */
  @Priority int = 0
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  DECLARE @now datetime2(3) = SYSUTCDATETIME(), @acquired bit = 0;
  BEGIN TRAN;
    DECLARE @current nvarchar(200), @expires datetime2(3), @currentCanRun bit, @currentPriority int;
    SELECT @current = Owner, @expires = ExpiresUtc, @currentCanRun = CanRunCycles, @currentPriority = Priority
    FROM ops.SchedulerLease WITH (UPDLOCK, HOLDLOCK) WHERE LeaseKey = N''PIM'';

    IF @current IS NULL
    BEGIN
      INSERT ops.SchedulerLease (LeaseKey, Owner, HostName, ProcessId, Application, AcquiredUtc, HeartbeatUtc, ExpiresUtc, CanRunCycles, Priority)
      VALUES (N''PIM'', @Owner, @HostName, @ProcessId, @Application, @now, @now, DATEADD(second, @TtlSeconds, @now), @CanRunCycles, @Priority);
      SET @acquired = 1;
    END
    ELSE IF @current = @Owner
    BEGIN
      UPDATE ops.SchedulerLease
      SET HeartbeatUtc = @now, ExpiresUtc = DATEADD(second, @TtlSeconds, @now), TickCount = TickCount + 1, CanRunCycles = @CanRunCycles, Priority = @Priority
      WHERE LeaseKey = N''PIM'';
      SET @acquired = 1;
    END
    ELSE IF @expires < @now OR @Priority > @currentPriority OR (@Priority = @currentPriority AND @CanRunCycles = 1 AND @currentCanRun = 0)
    BEGIN
      UPDATE ops.SchedulerLease
      SET Owner = @Owner, HostName = @HostName, ProcessId = @ProcessId, Application = @Application,
          AcquiredUtc = @now, HeartbeatUtc = @now, ExpiresUtc = DATEADD(second, @TtlSeconds, @now), TickCount = 0,
          CanRunCycles = @CanRunCycles, Priority = @Priority
      WHERE LeaseKey = N''PIM'';
      SET @acquired = 1;
    END
  COMMIT;

  SELECT @acquired AS IsOwner, Owner, HostName, ProcessId, Application, AcquiredUtc, HeartbeatUtc, ExpiresUtc, TickCount, CanRunCycles, Priority
  FROM ops.SchedulerLease WHERE LeaseKey = N''PIM'';
END');

/* --- 2 — definicije poslov ------------------------------------------------------ */

IF OBJECT_ID(N'ops.JobDefinition', N'U') IS NULL
BEGIN
  CREATE TABLE ops.JobDefinition
  (
    JobKey nvarchar(60) NOT NULL CONSTRAINT PK_JobDefinition PRIMARY KEY,
    Label nvarchar(120) NOT NULL,
    Description nvarchar(600) NOT NULL CONSTRAINT DF_JobDefinition_Description DEFAULT (N''),
    /* Poslovni tok, po katerem nadzorna plošča sestavi kartico: WEB_CATALOG, STOCK, ORDERS, INPUTS, SYSTEM. */
    Flow nvarchar(30) NOT NULL,
    /* Posel, katerega uspeh je rezultat toka (izvoz kataloga, izvoz cen in zaloge, zajem naročil, zajem artiklov). */
    IsFlowResult bit NOT NULL CONSTRAINT DF_JobDefinition_IsFlowResult DEFAULT (0),
    SortOrder int NOT NULL CONSTRAINT DF_JobDefinition_SortOrder DEFAULT (0),
    /* Internal, ExternalCall (SAOP, dobavitelj), SendsEmail. */
    Reach nvarchar(20) NOT NULL CONSTRAINT DF_JobDefinition_Reach DEFAULT (N'Internal'),
    IsEnabled bit NOT NULL CONSTRAINT DF_JobDefinition_IsEnabled DEFAULT (1),
    IntervalSeconds int NULL,
    DailyAtLocal time(0) NULL,
    TimeoutSeconds int NOT NULL CONSTRAINT DF_JobDefinition_Timeout DEFAULT (3600),
    /* Starost zadnjega uspeha, po kateri poslovna kartica pove ZASTAREL; NULL pomeni brez SLA. */
    SlaSeconds int NULL,
    WarnAfterMultiplier decimal(4,1) NOT NULL CONSTRAINT DF_JobDefinition_Warn DEFAULT (2.0),
    NextDueUtc datetime2(3) NULL,
    /* Ročna zahteva iz intraneta (ops.RequestJobRun): gostitelj jo prevzame ob naslednjem tiku. */
    RequestedRunUtc datetime2(3) NULL,
    RequestedBy nvarchar(200) NULL,
    /* Kdo je posel postavil na vrsto mimo urnika: Dependency:<JobKey> ob uspehu predhodnika. */
    TriggerSource nvarchar(80) NULL,
    RunningJobRunId bigint NULL,
    LastJobRunId bigint NULL,
    LastStartedUtc datetime2(3) NULL,
    LastEndedUtc datetime2(3) NULL,
    LastStatus nvarchar(20) NULL,
    LastSucceededUtc datetime2(3) NULL,
    LastSucceededJobRunId bigint NULL,
    LastError nvarchar(2000) NULL,
    CreatedUtc datetime2(3) NOT NULL CONSTRAINT DF_JobDefinition_CreatedUtc DEFAULT SYSUTCDATETIME(),
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_JobDefinition_UpdatedUtc DEFAULT SYSUTCDATETIME(),
    UpdatedBy nvarchar(200) NOT NULL CONSTRAINT DF_JobDefinition_UpdatedBy DEFAULT N'237_EnotniModelOpravil',
    CONSTRAINT CK_JobDefinition_Schedule CHECK (
      (IntervalSeconds IS NOT NULL AND IntervalSeconds >= 60 AND DailyAtLocal IS NULL)
      OR (IntervalSeconds IS NULL AND DailyAtLocal IS NOT NULL)),
    CONSTRAINT CK_JobDefinition_Timeout CHECK (TimeoutSeconds >= 30),
    CONSTRAINT CK_JobDefinition_Warn CHECK (WarnAfterMultiplier >= 1.0),
    CONSTRAINT CK_JobDefinition_Reach CHECK (Reach IN (N'Internal', N'ExternalCall', N'SendsEmail')),
    CONSTRAINT CK_JobDefinition_Flow CHECK (Flow IN (N'WEB_CATALOG', N'STOCK', N'ORDERS', N'INPUTS', N'SYSTEM'))
  );
END;

IF OBJECT_ID(N'ops.JobDependency', N'U') IS NULL
BEGIN
  CREATE TABLE ops.JobDependency
  (
    JobKey nvarchar(60) NOT NULL CONSTRAINT FK_JobDependency_Job REFERENCES ops.JobDefinition (JobKey),
    DependsOnJobKey nvarchar(60) NOT NULL CONSTRAINT FK_JobDependency_DependsOn REFERENCES ops.JobDefinition (JobKey),
    /* Vrata: odvisen posel se ne izvede (Blocked), kadar predhodnik ni uspel ali je njegov uspeh prestar. */
    IsGate bit NOT NULL CONSTRAINT DF_JobDependency_IsGate DEFAULT (1),
    MaxAgeSeconds int NULL,
    /* Sprožilec: uspeh predhodnika postavi odvisnega na vrsto takoj (NextDueUtc = zdaj). */
    TriggersDependent bit NOT NULL CONSTRAINT DF_JobDependency_Triggers DEFAULT (1),
    Note nvarchar(300) NULL,
    CONSTRAINT PK_JobDependency PRIMARY KEY (JobKey, DependsOnJobKey),
    CONSTRAINT CK_JobDependency_NotSelf CHECK (JobKey <> DependsOnJobKey)
  );
END;

/* --- 3 — zagoni in koraki ------------------------------------------------------- */

IF OBJECT_ID(N'ops.JobRun', N'U') IS NULL
BEGIN
  CREATE TABLE ops.JobRun
  (
    JobRunId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_JobRun PRIMARY KEY,
    JobKey nvarchar(60) NOT NULL,
    StartedUtc datetime2(3) NOT NULL CONSTRAINT DF_JobRun_StartedUtc DEFAULT SYSUTCDATETIME(),
    EndedUtc datetime2(3) NULL,
    Status nvarchar(20) NOT NULL CONSTRAINT DF_JobRun_Status DEFAULT N'Running',
    ExitCode int NULL,
    TriggeredBy nvarchar(30) NOT NULL,
    StartedBy nvarchar(200) NOT NULL,
    HostName nvarchar(200) NOT NULL,
    HostOwner nvarchar(200) NULL,
    LogPath nvarchar(800) NULL,
    HeartbeatUtc datetime2(3) NOT NULL CONSTRAINT DF_JobRun_HeartbeatUtc DEFAULT SYSUTCDATETIME(),
    CurrentStep nvarchar(200) NULL,
    StepsTotal int NOT NULL CONSTRAINT DF_JobRun_StepsTotal DEFAULT (0),
    StepsFailed int NOT NULL CONSTRAINT DF_JobRun_StepsFailed DEFAULT (0),
    StepsBlocked int NOT NULL CONSTRAINT DF_JobRun_StepsBlocked DEFAULT (0),
    ErrorLines int NOT NULL CONSTRAINT DF_JobRun_ErrorLines DEFAULT (0),
    Summary nvarchar(2000) NULL,
    TimeoutSeconds int NULL,
    CancelRequestedUtc datetime2(3) NULL,
    CancelRequestedBy nvarchar(200) NULL,
    BlockedByJobKey nvarchar(60) NULL,
    /* Blokiran zagon se ob isti oviri ne podvaja; šteje se, kolikokrat je bil posel na vrsti in blokiran. */
    Occurrences int NOT NULL CONSTRAINT DF_JobRun_Occurrences DEFAULT (1),
    CONSTRAINT CK_JobRun_Status CHECK (Status IN (N'Running', N'Succeeded', N'Warning', N'Failed', N'TimedOut', N'Cancelled', N'Abandoned', N'Blocked')),
    CONSTRAINT CK_JobRun_TriggeredBy CHECK (TriggeredBy IN (N'Scheduler', N'Human', N'Dependency'))
  );
  CREATE INDEX IX_JobRun_Job ON ops.JobRun (JobKey, StartedUtc DESC);
  CREATE INDEX IX_JobRun_Started ON ops.JobRun (StartedUtc DESC);
  CREATE INDEX IX_JobRun_Running ON ops.JobRun (HeartbeatUtc) WHERE Status = N'Running';
END;

IF OBJECT_ID(N'ops.JobStepRun', N'U') IS NULL
BEGIN
  CREATE TABLE ops.JobStepRun
  (
    JobStepRunId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_JobStepRun PRIMARY KEY,
    JobRunId bigint NOT NULL CONSTRAINT FK_JobStepRun_Run REFERENCES ops.JobRun (JobRunId),
    StepOrder int NOT NULL,
    StepName nvarchar(200) NOT NULL,
    OrganizationId int NULL,
    Command nvarchar(1000) NULL,
    StartedUtc datetime2(3) NOT NULL,
    EndedUtc datetime2(3) NULL,
    ExitCode int NULL,
    Status nvarchar(20) NOT NULL,
    Note nvarchar(2000) NULL,
    CONSTRAINT CK_JobStepRun_Status CHECK (Status IN (N'Succeeded', N'Failed', N'Skipped', N'Cancelled', N'TimedOut', N'Blocked'))
  );
  CREATE INDEX IX_JobStepRun_Run ON ops.JobStepRun (JobRunId, StepOrder);
END;

/* --- 4 — kontrolne točke in artefakti ------------------------------------------ */

IF OBJECT_ID(N'ops.DataCheckpoint', N'U') IS NULL
BEGIN
  CREATE TABLE ops.DataCheckpoint
  (
    CheckpointKey nvarchar(80) NOT NULL,
    /* 0 pomeni vsa podjetja (posel brez podjetja); sicer podjetje koraka. */
    OrganizationId int NOT NULL CONSTRAINT DF_DataCheckpoint_Org DEFAULT (0),
    JobKey nvarchar(60) NOT NULL,
    JobRunId bigint NULL,
    ReachedUtc datetime2(3) NOT NULL,
    Detail nvarchar(400) NULL,
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_DataCheckpoint_UpdatedUtc DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_DataCheckpoint PRIMARY KEY (CheckpointKey, OrganizationId)
  );
END;

IF OBJECT_ID(N'ops.Artifact', N'U') IS NULL
BEGIN
  CREATE TABLE ops.Artifact
  (
    ArtifactId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_Artifact PRIMARY KEY,
    JobRunId bigint NULL,
    JobKey nvarchar(60) NOT NULL,
    OrganizationId int NULL,
    /* MAGENTO_PRODUCTS, MAGENTO_CUSTOMERS, MAGENTO_STOCK_PRICES … — koda izvoznega profila. */
    Kind nvarchar(60) NOT NULL,
    FilePath nvarchar(800) NOT NULL,
    FileName nvarchar(200) NOT NULL,
    ByteCount bigint NOT NULL,
    RowCountValue bigint NULL,
    Sha256 char(64) NULL,
    FileModifiedUtc datetime2(3) NULL,
    CreatedUtc datetime2(3) NOT NULL CONSTRAINT DF_Artifact_CreatedUtc DEFAULT SYSUTCDATETIME()
  );
  CREATE INDEX IX_Artifact_Kind ON ops.Artifact (Kind, OrganizationId, CreatedUtc DESC);
END;

/* --- 5 — definicije: koda jih uskladi ob zagonu, skrbnik ureja urnik in vklop --- */

EXEC(N'CREATE OR ALTER PROCEDURE ops.EnsureJobDefinition
  @JobKey nvarchar(60), @Label nvarchar(120), @Description nvarchar(600), @Flow nvarchar(30), @IsFlowResult bit,
  @SortOrder int, @Reach nvarchar(20), @IntervalSeconds int = NULL, @DailyAtLocal time(0) = NULL,
  @TimeoutSeconds int = 3600, @SlaSeconds int = NULL, @IsEnabledDefault bit = 1
AS
BEGIN
  SET NOCOUNT ON;
  /* Nov posel v kodi dobi vrstico brez migracije; obstoječi vrstici koda popravi samo opisne stolpce,
     urnik, vklop, časovna meja in SLA so skrbnikovi (intranet.SaveJobSchedule). */
  IF NOT EXISTS (SELECT 1 FROM ops.JobDefinition WHERE JobKey = @JobKey)
    INSERT ops.JobDefinition (JobKey, Label, Description, Flow, IsFlowResult, SortOrder, Reach, IsEnabled, IntervalSeconds, DailyAtLocal, TimeoutSeconds, SlaSeconds, UpdatedBy)
    VALUES (@JobKey, @Label, @Description, @Flow, @IsFlowResult, @SortOrder, @Reach, @IsEnabledDefault, @IntervalSeconds, @DailyAtLocal, @TimeoutSeconds, @SlaSeconds, N''ops.EnsureJobDefinition'');
  ELSE
    UPDATE ops.JobDefinition SET Label = @Label, Description = @Description, Flow = @Flow, IsFlowResult = @IsFlowResult, SortOrder = @SortOrder, Reach = @Reach
    WHERE JobKey = @JobKey
      AND (Label <> @Label OR Description <> @Description OR Flow <> @Flow OR IsFlowResult <> @IsFlowResult OR SortOrder <> @SortOrder OR Reach <> @Reach);
END');

EXEC(N'CREATE OR ALTER PROCEDURE ops.EnsureJobDependency
  @JobKey nvarchar(60), @DependsOnJobKey nvarchar(60), @IsGate bit = 1, @MaxAgeSeconds int = NULL, @TriggersDependent bit = 1, @Note nvarchar(300) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  MERGE ops.JobDependency AS target
  USING (SELECT @JobKey AS JobKey, @DependsOnJobKey AS DependsOnJobKey) AS source
    ON target.JobKey = source.JobKey AND target.DependsOnJobKey = source.DependsOnJobKey
  WHEN MATCHED THEN UPDATE SET IsGate = @IsGate, MaxAgeSeconds = @MaxAgeSeconds, TriggersDependent = @TriggersDependent, Note = @Note
  WHEN NOT MATCHED THEN INSERT (JobKey, DependsOnJobKey, IsGate, MaxAgeSeconds, TriggersDependent, Note)
    VALUES (@JobKey, @DependsOnJobKey, @IsGate, @MaxAgeSeconds, @TriggersDependent, @Note);
END');

EXEC(N'CREATE OR ALTER PROCEDURE ops.SetJobNextDue @JobKey nvarchar(60), @NextDueUtc datetime2(3), @OnlyIfNull bit = 1
AS
BEGIN
  SET NOCOUNT ON;
  UPDATE ops.JobDefinition SET NextDueUtc = @NextDueUtc
  WHERE JobKey = @JobKey AND (@OnlyIfNull = 0 OR NextDueUtc IS NULL);
END');

EXEC(N'CREATE OR ALTER PROCEDURE intranet.SaveJobSchedule
  @JobKey nvarchar(60), @IsEnabled bit, @IntervalSeconds int = NULL, @DailyAtLocal time(0) = NULL, @TimeoutSeconds int = NULL, @Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  IF @IntervalSeconds IS NOT NULL AND @IntervalSeconds < 60 THROW 52371, N''Razmik ne sme biti krajši od 60 sekund.'', 1;
  IF @IntervalSeconds IS NOT NULL AND @IntervalSeconds > 86400 THROW 52372, N''Razmik ne sme biti daljši od enega dneva.'', 1;
  IF (@IntervalSeconds IS NULL AND @DailyAtLocal IS NULL) OR (@IntervalSeconds IS NOT NULL AND @DailyAtLocal IS NOT NULL)
    THROW 52373, N''Posel ima bodisi razmik bodisi dnevno uro.'', 1;
  IF @TimeoutSeconds IS NOT NULL AND @TimeoutSeconds < 30 THROW 52374, N''Časovna meja ne sme biti krajša od 30 sekund.'', 1;

  /* Sprememba urnika razveljavi izračunani naslednji termin; gostitelj ga izračuna na novo ob naslednjem tiku. */
  UPDATE ops.JobDefinition
  SET IsEnabled = @IsEnabled, IntervalSeconds = @IntervalSeconds, DailyAtLocal = @DailyAtLocal,
      TimeoutSeconds = COALESCE(@TimeoutSeconds, TimeoutSeconds),
      NextDueUtc = NULL, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = @Actor
  WHERE JobKey = @JobKey;
  IF @@ROWCOUNT = 0 THROW 52375, N''Posel ne obstaja.'', 1;
END');

/* --- 6 — zahteve iz konzole: zagon in ustavitev prevzame gostitelj ---------------- */

EXEC(N'CREATE OR ALTER PROCEDURE ops.RequestJobRun @JobKey nvarchar(60), @Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  DECLARE @running bigint;
  SELECT @running = RunningJobRunId FROM ops.JobDefinition WITH (UPDLOCK) WHERE JobKey = @JobKey;
  IF @@ROWCOUNT = 0 THROW 52376, N''Posel ne obstaja.'', 1;
  IF @running IS NOT NULL THROW 52377, N''Posel že teče; počakaj, da konča, ali ga ustavi.'', 1;
  UPDATE ops.JobDefinition
  SET RequestedRunUtc = SYSUTCDATETIME(), RequestedBy = @Actor, NextDueUtc = SYSUTCDATETIME()
  WHERE JobKey = @JobKey;
END');

EXEC(N'CREATE OR ALTER PROCEDURE ops.RequestJobCancel @JobRunId bigint, @Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON;
  UPDATE ops.JobRun SET CancelRequestedUtc = SYSUTCDATETIME(), CancelRequestedBy = @Actor
  WHERE JobRunId = @JobRunId AND Status = N''Running'' AND CancelRequestedUtc IS NULL;
  IF @@ROWCOUNT = 0 THROW 52378, N''Zagon ne teče (več).'', 1;
END');

/* --- 7 — zagon posla: edina vrata, z odvisnostmi ---------------------------------- */

EXEC(N'CREATE OR ALTER PROCEDURE ops.ClaimJobRun
  @JobKey nvarchar(60), @NextDueUtc datetime2(3), @StartedBy nvarchar(200), @HostName nvarchar(200), @HostOwner nvarchar(200) = NULL,
  @LogPath nvarchar(800) = NULL, @Force bit = 0,
  @JobRunId bigint OUTPUT, @Reason nvarchar(200) OUTPUT, @TriggeredBy nvarchar(30) OUTPUT
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  DECLARE @now datetime2(3) = SYSUTCDATETIME();
  SET @JobRunId = NULL; SET @TriggeredBy = NULL;
  BEGIN TRAN;
    DECLARE @enabled bit, @due datetime2(3), @running bigint, @requested datetime2(3), @requestedBy nvarchar(200),
            @trigger nvarchar(80), @timeout int, @lastRun bigint;
    SELECT @enabled = IsEnabled, @due = NextDueUtc, @running = RunningJobRunId, @requested = RequestedRunUtc, @requestedBy = RequestedBy,
           @trigger = TriggerSource, @timeout = TimeoutSeconds, @lastRun = LastJobRunId
    FROM ops.JobDefinition WITH (UPDLOCK, HOLDLOCK) WHERE JobKey = @JobKey;

    DECLARE @how nvarchar(30) = CASE WHEN @requested IS NOT NULL THEN N''Human'' WHEN @trigger IS NOT NULL THEN N''Dependency'' ELSE N''Scheduler'' END;

    IF @enabled IS NULL
      SET @Reason = N''Unknown'';
    ELSE IF @running IS NOT NULL
      SET @Reason = N''Running'';
    ELSE IF @Force = 0 AND @requested IS NULL AND @enabled = 0
      SET @Reason = N''Disabled'';
    ELSE IF @Force = 0 AND @requested IS NULL AND @due IS NOT NULL AND @due > @now
      SET @Reason = N''NotDue'';
    ELSE
    BEGIN
      /* Predhodnik, ki ravno teče: počakamo na naslednji tik, ne blokiramo (validacija ne sme teči sredi zajema). */
      DECLARE @waitingOn nvarchar(60) = (
        SELECT TOP (1) d.DependsOnJobKey FROM ops.JobDependency d
        INNER JOIN ops.JobDefinition p ON p.JobKey = d.DependsOnJobKey
        WHERE d.JobKey = @JobKey AND p.RunningJobRunId IS NOT NULL ORDER BY d.DependsOnJobKey);
      IF @waitingOn IS NOT NULL
        SET @Reason = CONCAT(N''WaitingOn:'', @waitingOn);
      ELSE
      BEGIN
        /* Vrata: predhodnik mora biti vklopljen, njegov zadnji zagon uspešen in uspeh dovolj svež. */
        DECLARE @blockedBy nvarchar(60), @blockReason nvarchar(400);
        SELECT TOP (1) @blockedBy = d.DependsOnJobKey,
          @blockReason = CASE
            WHEN p.IsEnabled = 0 THEN CONCAT(p.Label, N'' je izklopljen.'')
            WHEN p.LastSucceededUtc IS NULL THEN CONCAT(p.Label, N'' še ni nikoli uspel.'')
            WHEN p.LastStatus NOT IN (N''Succeeded'', N''Warning'') THEN CONCAT(p.Label, N'' se je nazadnje končal s stanjem '', p.LastStatus, N'' ('', CONVERT(nvarchar(19), p.LastEndedUtc, 120), N'' UTC).'')
            ELSE CONCAT(N''Zadnji uspeh posla '', p.Label, N'' je starejši od '', d.MaxAgeSeconds / 60, N'' min.'') END
        FROM ops.JobDependency d
        INNER JOIN ops.JobDefinition p ON p.JobKey = d.DependsOnJobKey
        WHERE d.JobKey = @JobKey AND d.IsGate = 1
          AND (p.IsEnabled = 0 OR p.LastSucceededUtc IS NULL OR p.LastStatus NOT IN (N''Succeeded'', N''Warning'')
               OR (d.MaxAgeSeconds IS NOT NULL AND p.LastSucceededUtc < DATEADD(second, -d.MaxAgeSeconds, @now)))
        ORDER BY d.DependsOnJobKey;

        IF @blockedBy IS NOT NULL
        BEGIN
          DECLARE @summary nvarchar(2000) = CONCAT(N''Blokirano: '', @blockReason, N'' Ta posel se ne izvede, dokler predhodnik ne uspe.'');
          /* Ista ovira kot pri zadnjem zagonu: ne podvajamo vrstice, štejemo ponovitve. */
          IF EXISTS (SELECT 1 FROM ops.JobRun WHERE JobRunId = @lastRun AND Status = N''Blocked'' AND BlockedByJobKey = @blockedBy AND TriggeredBy <> N''Human'') AND @how <> N''Human''
          BEGIN
            UPDATE ops.JobRun SET EndedUtc = @now, HeartbeatUtc = @now, Occurrences = Occurrences + 1, Summary = @summary WHERE JobRunId = @lastRun;
            SET @JobRunId = @lastRun;
          END
          ELSE
          BEGIN
            INSERT ops.JobRun (JobKey, StartedUtc, EndedUtc, Status, TriggeredBy, StartedBy, HostName, HostOwner, HeartbeatUtc, Summary, BlockedByJobKey, TimeoutSeconds)
            VALUES (@JobKey, @now, @now, N''Blocked'', @how, COALESCE(@requestedBy, @StartedBy), @HostName, @HostOwner, @now, @summary, @blockedBy, @timeout);
            SET @JobRunId = SCOPE_IDENTITY();
          END
          UPDATE ops.JobDefinition
          SET LastJobRunId = @JobRunId, LastStartedUtc = @now, LastEndedUtc = @now, LastStatus = N''Blocked'', LastError = @summary,
              NextDueUtc = @NextDueUtc, RequestedRunUtc = NULL, RequestedBy = NULL, TriggerSource = NULL
          WHERE JobKey = @JobKey;
          SET @JobRunId = NULL;
          SET @Reason = CONCAT(N''Blocked:'', @blockedBy);
        END
        ELSE
        BEGIN
          SET @TriggeredBy = @how;
          INSERT ops.JobRun (JobKey, StartedUtc, TriggeredBy, StartedBy, HostName, HostOwner, LogPath, HeartbeatUtc, TimeoutSeconds)
          VALUES (@JobKey, @now, @how, COALESCE(@requestedBy, @StartedBy), @HostName, @HostOwner, @LogPath, @now, @timeout);
          SET @JobRunId = SCOPE_IDENTITY();
          /* Naslednji termin se šteje od ZAČETKA tega teka (isto pravilo kot 118 in 221). */
          UPDATE ops.JobDefinition
          SET RunningJobRunId = @JobRunId, LastJobRunId = @JobRunId, LastStartedUtc = @now, NextDueUtc = @NextDueUtc,
              RequestedRunUtc = NULL, RequestedBy = NULL, TriggerSource = NULL
          WHERE JobKey = @JobKey;
          SET @Reason = N''Claimed'';
        END
      END
    END
  COMMIT;
END');

EXEC(N'CREATE OR ALTER PROCEDURE ops.HeartbeatJobRun @JobRunId bigint, @CurrentStep nvarchar(200) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  UPDATE ops.JobRun SET HeartbeatUtc = SYSUTCDATETIME(), CurrentStep = @CurrentStep
  WHERE JobRunId = @JobRunId AND Status = N''Running'';
  /* Gostitelj ob vsakem utripu izve, ali je kdo zahteval ustavitev. */
  SELECT CASE WHEN CancelRequestedUtc IS NULL THEN CONVERT(bit, 0) ELSE CONVERT(bit, 1) END AS CancelRequested, CancelRequestedBy
  FROM ops.JobRun WHERE JobRunId = @JobRunId;
END');

EXEC(N'CREATE OR ALTER PROCEDURE ops.RecordJobStepRun
  @JobRunId bigint, @StepOrder int, @StepName nvarchar(200), @OrganizationId int = NULL,
  @Command nvarchar(1000) = NULL, @StartedUtc datetime2(3), @EndedUtc datetime2(3), @ExitCode int = NULL,
  @Status nvarchar(20), @Note nvarchar(2000) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  INSERT ops.JobStepRun (JobRunId, StepOrder, StepName, OrganizationId, Command, StartedUtc, EndedUtc, ExitCode, Status, Note)
  VALUES (@JobRunId, @StepOrder, @StepName, @OrganizationId, @Command, @StartedUtc, @EndedUtc, @ExitCode, @Status, @Note);
END');

EXEC(N'CREATE OR ALTER PROCEDURE ops.SetDataCheckpoint
  @CheckpointKey nvarchar(80), @OrganizationId int = 0, @JobKey nvarchar(60), @JobRunId bigint = NULL, @Detail nvarchar(400) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  MERGE ops.DataCheckpoint AS target
  USING (SELECT @CheckpointKey AS CheckpointKey, @OrganizationId AS OrganizationId) AS source
    ON target.CheckpointKey = source.CheckpointKey AND target.OrganizationId = source.OrganizationId
  WHEN MATCHED THEN UPDATE SET JobKey = @JobKey, JobRunId = @JobRunId, ReachedUtc = SYSUTCDATETIME(), Detail = @Detail, UpdatedUtc = SYSUTCDATETIME()
  WHEN NOT MATCHED THEN INSERT (CheckpointKey, OrganizationId, JobKey, JobRunId, ReachedUtc, Detail)
    VALUES (@CheckpointKey, @OrganizationId, @JobKey, @JobRunId, SYSUTCDATETIME(), @Detail);
END');

EXEC(N'CREATE OR ALTER PROCEDURE ops.RegisterArtifact
  @JobRunId bigint = NULL, @JobKey nvarchar(60), @OrganizationId int = NULL, @Kind nvarchar(60), @FilePath nvarchar(800), @FileName nvarchar(200),
  @ByteCount bigint, @RowCountValue bigint = NULL, @Sha256 char(64) = NULL, @FileModifiedUtc datetime2(3) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  /* Ista datoteka (isti hash in velikost) kot zadnjič ni nov artefakt: izvoz brez spremembe ne podvaja vrstic. */
  IF EXISTS (SELECT 1 FROM (
      SELECT TOP (1) Sha256, ByteCount FROM ops.Artifact WHERE Kind = @Kind AND ((@OrganizationId IS NULL AND OrganizationId IS NULL) OR OrganizationId = @OrganizationId) ORDER BY ArtifactId DESC) last
    WHERE last.Sha256 = @Sha256 AND last.ByteCount = @ByteCount AND @Sha256 IS NOT NULL)
  BEGIN
    SELECT CONVERT(bigint, NULL) AS ArtifactId, CONVERT(bit, 0) AS IsNew;
    RETURN;
  END
  INSERT ops.Artifact (JobRunId, JobKey, OrganizationId, Kind, FilePath, FileName, ByteCount, RowCountValue, Sha256, FileModifiedUtc)
  VALUES (@JobRunId, @JobKey, @OrganizationId, @Kind, @FilePath, @FileName, @ByteCount, @RowCountValue, @Sha256, @FileModifiedUtc);
  SELECT CONVERT(bigint, SCOPE_IDENTITY()) AS ArtifactId, CONVERT(bit, 1) AS IsNew;
END');

/* --- 8 — konec zagona: stanje posla, kontrolna točka, sprožitev odvisnih, alarmi ---- */

EXEC(N'CREATE OR ALTER PROCEDURE ops.CompleteJobRun
  @JobRunId bigint, @Status nvarchar(20), @ExitCode int = NULL, @StepsTotal int = 0, @StepsFailed int = 0, @StepsBlocked int = 0,
  @ErrorLines int = 0, @Summary nvarchar(2000) = NULL, @Actor nvarchar(200) = N''gostitelj avtomatike''
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  IF @Status NOT IN (N''Succeeded'', N''Warning'', N''Failed'', N''TimedOut'', N''Cancelled'', N''Abandoned'')
    THROW 52379, N''Neveljavno končno stanje zagona.'', 1;

  DECLARE @now datetime2(3) = SYSUTCDATETIME(), @job nvarchar(60), @started datetime2(3);
  SELECT @job = JobKey, @started = StartedUtc FROM ops.JobRun WHERE JobRunId = @JobRunId;

  UPDATE ops.JobRun
  SET EndedUtc = @now, Status = @Status, ExitCode = @ExitCode, StepsTotal = @StepsTotal, StepsFailed = @StepsFailed, StepsBlocked = @StepsBlocked,
      ErrorLines = @ErrorLines, Summary = @Summary, CurrentStep = NULL
  WHERE JobRunId = @JobRunId AND Status = N''Running'';
  IF @@ROWCOUNT = 0 RETURN; /* že zaprt (npr. Abandoned): stanje posla je določil tisti, ki ga je zaprl */

  DECLARE @succeeded bit = CASE WHEN @Status IN (N''Succeeded'', N''Warning'') THEN 1 ELSE 0 END;

  UPDATE ops.JobDefinition
  SET RunningJobRunId = NULL, LastEndedUtc = @now, LastStatus = @Status,
      LastError = CASE WHEN @Status = N''Succeeded'' THEN NULL ELSE @Summary END,
      LastSucceededUtc = CASE WHEN @succeeded = 1 THEN @now ELSE LastSucceededUtc END,
      LastSucceededJobRunId = CASE WHEN @succeeded = 1 THEN @JobRunId ELSE LastSucceededJobRunId END
  WHERE JobKey = @job AND RunningJobRunId = @JobRunId;

  IF @succeeded = 1
  BEGIN
    EXEC ops.SetDataCheckpoint @CheckpointKey = @job, @OrganizationId = 0, @JobKey = @job, @JobRunId = @JobRunId, @Detail = @Summary;

    /* Sprožitev odvisnih: uspeh predhodnika postavi odvisnega na vrsto takoj, a ne v teku in ne izklopljenega. */
    UPDATE dependent
    SET NextDueUtc = @now, TriggerSource = CONCAT(N''Dependency:'', @job)
    FROM ops.JobDefinition dependent
    INNER JOIN ops.JobDependency link ON link.JobKey = dependent.JobKey
    WHERE link.DependsOnJobKey = @job AND link.TriggersDependent = 1 AND dependent.IsEnabled = 1
      AND dependent.RunningJobRunId IS NULL AND (dependent.NextDueUtc IS NULL OR dependent.NextDueUtc > @now);

    /* Posel je uspel: alarmi o njegovem zaostanku, padcu ali blokadi ne veljajo več. */
    UPDATE ops.Alert
    SET ResolvedUtc = @now, ResolvedBy = @Actor, UpdatedUtc = @now, UpdatedBy = @Actor
    WHERE AlertKind IN (N''JobOverdue'', N''JobFailed'', N''JobBlocked'') AND Pipeline = CONCAT(N''OPRAVILO:'', @job) AND ResolvedUtc IS NULL;
  END
END');

EXEC(N'CREATE OR ALTER PROCEDURE ops.AbandonStaleJobRuns
  @Actor nvarchar(200), @StaleMinutes int = 10, @HostName nvarchar(200) = NULL
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  /* Dva razloga, isti izid: zagon TEGA gostitelja iz prejšnjega procesa (ob zagonu gostitelja) ali
     katerikoli zagon brez utripa dlje od @StaleMinutes (ob vsakem tiku). Abandoned ni Failed:
     »nikoli se ni zaprlo« in »padlo je« sta različni stvari (144, 221). */
  DECLARE @now datetime2(3) = SYSUTCDATETIME();
  DECLARE @mrtvi TABLE (JobRunId bigint PRIMARY KEY, JobKey nvarchar(60));

  UPDATE run
  SET Status = N''Abandoned'', EndedUtc = @now, CurrentStep = NULL,
      Summary = CONCAT(N''Zagon se ni končal sam (zadnji utrip '', CONVERT(nvarchar(19), run.HeartbeatUtc, 120), N'' UTC); zaprl ga je '', @Actor, N'' ob '', CONVERT(nvarchar(19), @now, 120), N'' UTC.'')
  OUTPUT inserted.JobRunId, inserted.JobKey INTO @mrtvi
  FROM ops.JobRun run
  WHERE run.Status = N''Running''
    AND ((@HostName IS NOT NULL AND run.HostName = @HostName) OR run.HeartbeatUtc < DATEADD(minute, -@StaleMinutes, @now));

  UPDATE job
  SET RunningJobRunId = NULL, LastEndedUtc = @now, LastStatus = N''Abandoned'',
      LastError = N''Zagon se ni končal sam; gostitelj ali proces je izginil brez zaključka.''
  FROM ops.JobDefinition job
  INNER JOIN @mrtvi mrtev ON mrtev.JobRunId = job.RunningJobRunId;

  SELECT COUNT(*) AS ZaprtihZagonov FROM @mrtvi;
END');

/* --- 9 — alarmi poslov in gostitelja ---------------------------------------------- */

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

  /* Zaostanek: posel, ki od zadnjega začetka (ali nastavitve) miruje več kot WarnAfterMultiplier × razmik. */
  INSERT @alarmi (AlertKind, Severity, Pipeline, DedupKey, Title, Summary)
  SELECT N''JobOverdue'', N''Critical'', CONCAT(N''OPRAVILO:'', j.JobKey),
         CONVERT(varchar(64), HASHBYTES(''SHA2_256'', CONCAT(N''JobOverdue:'', j.JobKey)), 2),
         CONCAT(N''Posel "'', j.Label, N''" ni tekel '', DATEDIFF(minute, COALESCE(j.LastStartedUtc, j.UpdatedUtc), @now), N'' min (razmik '',
                CASE WHEN j.IntervalSeconds IS NULL THEN N''1 dan'' ELSE CONCAT(j.IntervalSeconds / 60, N'' min'') END, N'').''),
         CONCAT(N''Zadnji začetek: '', COALESCE(CONVERT(nvarchar(19), j.LastStartedUtc, 120), N''nikoli''), N'' UTC. Naslednji termin: '',
                COALESCE(CONVERT(nvarchar(19), j.NextDueUtc, 120), N''takoj''), N'' UTC. Preveri gostitelja avtomatike na /sistem/opravila.'')
  FROM ops.JobDefinition j
  WHERE j.IsEnabled = 1 AND j.RunningJobRunId IS NULL
    AND DATEDIFF(second, COALESCE(j.LastStartedUtc, j.UpdatedUtc), @now) > j.WarnAfterMultiplier * COALESCE(j.IntervalSeconds, 86400);

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

/* --- 10 — bralni modeli za /sistem, /sistem/opravila in /sistem/zagoni ---------------- */

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetJobDefinitions
AS
BEGIN
  SET NOCOUNT ON;
  DECLARE @now datetime2(3) = SYSUTCDATETIME();
  SELECT j.JobKey, j.Label, j.Description, j.Flow, j.IsFlowResult, j.SortOrder, j.Reach, j.IsEnabled, j.IntervalSeconds, j.DailyAtLocal,
         j.TimeoutSeconds, j.SlaSeconds, j.WarnAfterMultiplier, j.NextDueUtc, j.RequestedRunUtc, j.RequestedBy, j.TriggerSource,
         j.RunningJobRunId, j.LastJobRunId, j.LastStartedUtc, j.LastEndedUtc, j.LastStatus, j.LastSucceededUtc, j.LastSucceededJobRunId, j.LastError,
         j.UpdatedUtc, j.UpdatedBy,
         run.CurrentStep AS RunningStep, run.HeartbeatUtc AS RunningHeartbeatUtc, run.StartedUtc AS RunningSinceUtc, run.HostName AS RunningHost,
         run.CancelRequestedUtc,
         CASE WHEN run.JobRunId IS NOT NULL AND run.HeartbeatUtc < DATEADD(minute, -10, @now) THEN CONVERT(bit, 1) ELSE CONVERT(bit, 0) END AS RunningIsStale,
         (SELECT COUNT(*) FROM ops.Alert a WHERE a.Pipeline = CONCAT(N''OPRAVILO:'', j.JobKey) AND a.ResolvedUtc IS NULL) AS OpenAlerts,
         lastRun.Summary AS LastSummary, lastRun.StepsTotal AS LastStepsTotal, lastRun.StepsFailed AS LastStepsFailed, lastRun.StepsBlocked AS LastStepsBlocked,
         lastRun.TriggeredBy AS LastTriggeredBy, lastRun.BlockedByJobKey AS LastBlockedByJobKey, lastRun.HostName AS LastHost,
         CASE WHEN lastRun.EndedUtc IS NULL OR lastRun.StartedUtc IS NULL THEN NULL ELSE DATEDIFF(second, lastRun.StartedUtc, lastRun.EndedUtc) * 1000 END AS LastDurationMs
  FROM ops.JobDefinition j
  LEFT JOIN ops.JobRun run ON run.JobRunId = j.RunningJobRunId
  LEFT JOIN ops.JobRun lastRun ON lastRun.JobRunId = j.LastJobRunId
  ORDER BY j.SortOrder, j.JobKey;

  SELECT d.JobKey, d.DependsOnJobKey, d.IsGate, d.MaxAgeSeconds, d.TriggersDependent, d.Note
  FROM ops.JobDependency d ORDER BY d.JobKey, d.DependsOnJobKey;

  /* Zadnji artefakt po vrsti in podjetju: kaj splet trenutno uporablja. */
  SELECT a.ArtifactId, a.JobKey, a.JobRunId, a.OrganizationId, a.Kind, a.FilePath, a.FileName, a.ByteCount, a.RowCountValue, a.Sha256, a.FileModifiedUtc, a.CreatedUtc
  FROM ops.Artifact a
  WHERE a.ArtifactId = (SELECT MAX(b.ArtifactId) FROM ops.Artifact b WHERE b.Kind = a.Kind AND ((b.OrganizationId IS NULL AND a.OrganizationId IS NULL) OR b.OrganizationId = a.OrganizationId))
  ORDER BY a.Kind, a.OrganizationId;
END');

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetJobRuns @Take int = 60, @JobKey nvarchar(60) = NULL, @Status nvarchar(20) = NULL, @Days int = 7
AS
BEGIN
  SET NOCOUNT ON;
  DECLARE @now datetime2(3) = SYSUTCDATETIME();
  SELECT TOP (@Take) run.JobRunId, run.JobKey, j.Label, j.Flow, run.StartedUtc, run.EndedUtc, run.Status,
         /* Running brez utripa 10 minut je za bralca Abandoned, tudi preden ga gostitelj zapre. */
         CASE WHEN run.Status = N''Running'' AND run.HeartbeatUtc < DATEADD(minute, -10, @now) THEN N''Abandoned'' ELSE run.Status END AS EffectiveStatus,
         run.ExitCode, run.TriggeredBy, run.StartedBy, run.HostName, run.HostOwner, run.LogPath, run.HeartbeatUtc, run.CurrentStep,
         run.StepsTotal, run.StepsFailed, run.StepsBlocked, run.ErrorLines, run.Summary, run.TimeoutSeconds,
         run.CancelRequestedUtc, run.CancelRequestedBy, run.BlockedByJobKey, run.Occurrences
  FROM ops.JobRun run
  LEFT JOIN ops.JobDefinition j ON j.JobKey = run.JobKey
  WHERE (@JobKey IS NULL OR run.JobKey = @JobKey)
    AND (@Status IS NULL OR run.Status = @Status)
    AND (@Days IS NULL OR run.StartedUtc >= DATEADD(day, -@Days, @now))
  ORDER BY run.StartedUtc DESC, run.JobRunId DESC;
END');

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetJobStepRuns @JobRunId bigint
AS
BEGIN
  SET NOCOUNT ON;
  SELECT StepOrder, StepName, OrganizationId, Command, StartedUtc, EndedUtc, ExitCode, Status, Note
  FROM ops.JobStepRun WHERE JobRunId = @JobRunId ORDER BY StepOrder;
END');

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetAutomationHost
AS
BEGIN
  SET NOCOUNT ON;
  DECLARE @now datetime2(3) = SYSUTCDATETIME();
  SELECT l.Owner, l.HostName, l.ProcessId, l.Application, l.AcquiredUtc, l.HeartbeatUtc, l.ExpiresUtc, l.TickCount, l.CanRunCycles, l.Priority,
         @now AS NowUtc,
         CASE WHEN l.Application LIKE N''AutomationHost%'' AND l.ExpiresUtc > @now THEN CONVERT(bit, 1) ELSE CONVERT(bit, 0) END AS IsAutomationHostLive,
         (SELECT COUNT(*) FROM ops.JobRun WHERE Status = N''Running'') AS RunningJobs,
         (SELECT COUNT(*) FROM ops.JobRun WHERE Status = N''Running'' AND HeartbeatUtc < DATEADD(minute, -10, @now)) AS StaleRunningJobs,
         (SELECT COUNT(*) FROM ops.JobRun WHERE StartedUtc >= DATEADD(hour, -24, @now)) AS RunsLast24h,
         (SELECT COUNT(*) FROM ops.JobRun WHERE StartedUtc >= DATEADD(hour, -24, @now) AND Status IN (N''Failed'', N''TimedOut'', N''Abandoned'')) AS FailedLast24h,
         (SELECT COUNT(*) FROM ops.JobRun WHERE StartedUtc >= DATEADD(hour, -24, @now) AND Status = N''Blocked'') AS BlockedLast24h,
         (SELECT COUNT(*) FROM ops.JobDefinition WHERE IsEnabled = 1) AS EnabledJobs,
         (SELECT COUNT(*) FROM ops.JobDefinition WHERE RequestedRunUtc IS NOT NULL) AS PendingRequests,
         (SELECT COUNT(*) FROM ops.Alert WHERE AlertKind = N''AutomationHostDown'' AND ResolvedUtc IS NULL) AS OpenHostAlerts
  FROM (SELECT 1 AS one) AS ena
  LEFT JOIN ops.SchedulerLease l ON l.LeaseKey = N''PIM'';
END');

/* --- 11 — posli: vsak worker ima svoj posel, naročila so ločena od kataloga ----------- */

EXEC ops.EnsureJobDefinition N'SAOP_PRODUCT_IMPORT', N'Artikli iz SAOP',
  N'Zajem in preslikava artiklov iz SAOP za vsa vključena podjetja (delta; prvi dan v mesecu poln zajem). Samo vhod: brez validacije, objave in izvoza. Uspeh sproži validacijo.',
  N'INPUTS', 1, 10, N'ExternalCall', 3600, NULL, 3600, 7200, 1;
EXEC ops.EnsureJobDefinition N'SAOP_ORDER_IMPORT', N'Naročila iz SAOP',
  N'Naročila kupcev (VNK) in naročila dobaviteljem (VND) za MIN/MID/MAX. Popolnoma ločeno od spletnega kataloga.',
  N'ORDERS', 1, 20, N'ExternalCall', 3600, NULL, 1800, 7200, 1;
EXEC ops.EnsureJobDefinition N'STOCK_IMPORT', N'Zaloga iz datotek in SAOP',
  N'Prevzem in branje zaloge Nowodvorski (FTP) in Braytron (HTTPS) za vsa podjetja ter količine zaloge iz SAOP. Uspeh sproži izvoz cen in zaloge.',
  N'STOCK', 0, 30, N'ExternalCall', 300, NULL, 900, 1800, 1;
EXEC ops.EnsureJobDefinition N'PRICE_IMPORT', N'Cene iz SAOP',
  N'Delta zajem cen (GetPrices) za vsa vključena podjetja.',
  N'STOCK', 0, 31, N'ExternalCall', 300, NULL, 900, 1800, 1;
EXEC ops.EnsureJobDefinition N'SAOP_DELIVERY_IMPORT', N'Datumi dobave iz SAOP',
  N'Datumi in količine prihoda, en klic na artikel (do 300 artiklov na podjetje); počasen, zato na pol ure.',
  N'STOCK', 0, 32, N'ExternalCall', 1800, NULL, 1800, 7200, 1;
EXEC ops.EnsureJobDefinition N'PRODUCT_VALIDATION', N'Validacija artiklov',
  N'val.RunValidation za vsako podjetje (celotna validacija, ker canon nima sledenja sprememb artiklov). Sproži jo uspešen zajem artiklov, sicer teče vsako uro.',
  N'WEB_CATALOG', 0, 40, N'Internal', 3600, NULL, 3600, 7200, 1;
EXEC ops.EnsureJobDefinition N'PRODUCT_PUBLICATION', N'Objava v PIM',
  N'val.Promote: veljavni artikli iz canon v pim za vsako podjetje. Teče samo po uspešni in sveži validaciji; sicer je blokirana.',
  N'WEB_CATALOG', 0, 41, N'Internal', 3600, NULL, 1800, 7200, 1;
EXEC ops.EnsureJobDefinition N'WEB_CATALOG_EXPORT', N'Katalog in stranke za splet',
  N'katalog.csv in stranke.csv (podjetje 2) iz objavljenega stanja. Brez validacije: bere samo potrjeno stanje in teče samo po uspešni objavi.',
  N'WEB_CATALOG', 1, 42, N'Internal', 300, NULL, 1800, 7200, 1;
EXEC ops.EnsureJobDefinition N'WEB_STOCK_EXPORT', N'Cene in zaloga za splet',
  N'magento-stock-prices.csv za vsako podjetje iz trenutnega objavljenega stanja (profil MAGENTO_STOCK_PRICES).',
  N'STOCK', 1, 43, N'Internal', 300, NULL, 900, 1800, 1;
EXEC ops.EnsureJobDefinition N'ALERT_EVALUATION', N'Nadzornik',
  N'Nadzornik zastalih obdelav (PIM.Watchdog): zastareli utripi, mirujoči vodni žigi, mrtva odhodna sporočila; alarme uvrsti v vrsto za dostavo.',
  N'SYSTEM', 0, 50, N'Internal', 300, NULL, 300, 1800, 1;
EXEC ops.EnsureJobDefinition N'ALERT_DELIVERY', N'Razpošiljanje alarmov',
  N'Odprte alarme pošlje po e-pošti oziroma webhooku, če je dostava vklopljena (PIM_ALERT_DELIVERY_ENABLED).',
  N'SYSTEM', 0, 51, N'SendsEmail', 300, NULL, 300, 1800, 1;
EXEC ops.EnsureJobDefinition N'NIGHTLY_RECONCILIATION', N'Nočna uskladitev',
  N'Kontrolni polni pregled, ne redna produkcijska pot: SAOP katalog, prevzem in dobaviteljev XML, preslikava zaostanka, zaloge iz datotek, zaloga in dobave iz SAOP, nato validacija in objava vseh podjetij. Če pade katerikoli vhod, sta validacija in objava blokirani.',
  N'INPUTS', 0, 60, N'ExternalCall', NULL, '02:30', 21600, 129600, 1;
EXEC ops.EnsureJobDefinition N'STOCK_REPLENISHMENT_DIGEST', N'Zaloga pod MID (dnevni mail)',
  N'Dnevni mail o artiklih na ali pod MID pragom prejemnikom s kljukico »Zaloga pod MID«.',
  N'ORDERS', 0, 61, N'SendsEmail', NULL, '05:30', 900, 129600, 1;
EXEC ops.EnsureJobDefinition N'SYSTEM_SELF_TEST', N'Nočni samotest',
  N'Prehodi celo verigo (baza, razporedi, utripi, katalog, izvoz) in rezultat zapiše v ops.SelfTestRun. Samo bere.',
  N'SYSTEM', 0, 70, N'Internal', NULL, '04:30', 1800, 129600, 1;
EXEC ops.EnsureJobDefinition N'SAOP_OUTBOUND_DISPATCH', N'Pošiljanje v SAOP (odhodna vrsta)',
  N'Odhodna pot v SAOP (PIM.OutboxDispatcher). Privzeto izklopljeno: pošiljanje je ročna odločitev z odobritvijo in zahteva razpored OUTBOUND ter poverilnice.',
  N'SYSTEM', 0, 80, N'ExternalCall', 300, NULL, 900, NULL, 0;

/* Odvisnosti: vrata in sprožilci. Naročila nimajo nobene. */
EXEC ops.EnsureJobDependency N'PRODUCT_VALIDATION', N'SAOP_PRODUCT_IMPORT', 0, NULL, 1,
  N'Uspešen zajem artiklov sproži validacijo; padec zajema je ne blokira (validira se obstoječi katalog, tudi urejanja v PIM).';
EXEC ops.EnsureJobDependency N'PRODUCT_PUBLICATION', N'PRODUCT_VALIDATION', 1, 7200, 1,
  N'Objava samo po uspešni validaciji, mlajši od dveh ur (236: pripravljenost zahteva svežo validacijo).';
EXEC ops.EnsureJobDependency N'WEB_CATALOG_EXPORT', N'PRODUCT_PUBLICATION', 1, NULL, 1,
  N'Izvoz samo iz uspešno objavljenega stanja.';
EXEC ops.EnsureJobDependency N'WEB_STOCK_EXPORT', N'STOCK_IMPORT', 0, NULL, 1,
  N'Uspešen zajem zaloge sproži izvoz cen in zaloge; padec ga ne blokira (izvoz bere zadnje objavljeno stanje).';
EXEC ops.EnsureJobDependency N'WEB_STOCK_EXPORT', N'PRICE_IMPORT', 0, NULL, 1,
  N'Uspešen zajem cen sproži izvoz cen in zaloge.';
EXEC ops.EnsureJobDependency N'ALERT_DELIVERY', N'ALERT_EVALUATION', 0, NULL, 1,
  N'Nadzornik najprej uvrsti alarme v vrsto, razpošiljanje jih nato dostavi.';

/* --- 12 — zvonec pozna nove vrste alarmov ------------------------------------------- */

EXEC(N'
  DECLARE @definicija nvarchar(max) = (SELECT definition FROM sys.check_constraints WHERE name = N''CK_UserAlertSubscription_Kind'');
  IF @definicija IS NULL OR CHARINDEX(N''JobOverdue'', @definicija) = 0 OR CHARINDEX(N''JobFailed'', @definicija) = 0
     OR CHARINDEX(N''JobBlocked'', @definicija) = 0 OR CHARINDEX(N''AutomationHostDown'', @definicija) = 0
  BEGIN
    DECLARE @vrste nvarchar(max);
    SELECT @vrste = STRING_AGG(CONCAT(N''N'''''', REPLACE(AlertKind, N'''''''', N''''''''''''), N''''''''), N'', '')
    FROM (
      SELECT DISTINCT AlertKind FROM intranet.UserAlertSubscription
      UNION
      SELECT AlertKind FROM (VALUES
        (N''StaleHeartbeat''), (N''OutboundDead''), (N''OutboundDrift''), (N''StalledWatermark''),
        (N''PipelineDisabled''), (N''ReservationExcluded''), (N''OutboundUnacknowledged''),
        (N''PipelinePaused''), (N''CycleOverdue''), (N''PipelineOverdue''),
        (N''StockSnapshotStale''), (N''StockSnapshotEmpty''), (N''ExportRejected''),
        (N''JobOverdue''), (N''JobFailed''), (N''JobBlocked''), (N''AutomationHostDown'')) AS znane(AlertKind)
    ) AS vse;
    IF @definicija IS NOT NULL
      ALTER TABLE intranet.UserAlertSubscription DROP CONSTRAINT CK_UserAlertSubscription_Kind;
    EXEC(N''ALTER TABLE intranet.UserAlertSubscription ADD CONSTRAINT CK_UserAlertSubscription_Kind CHECK (AlertKind IN ('' + @vrste + N''))'');
  END');

INSERT intranet.UserAlertSubscription (UserName, AlertKind, UpdatedBy)
SELECT localUser.UserName, kind.AlertKind, N'237_EnotniModelOpravil'
FROM sec.LocalUser localUser
INNER JOIN sec.LocalUserRole userRole ON userRole.LocalUserId = localUser.LocalUserId
INNER JOIN sec.Role roleValue ON roleValue.RoleId = userRole.RoleId AND roleValue.RoleCode = N'ADMIN'
CROSS JOIN (VALUES (N'JobOverdue'), (N'JobFailed'), (N'JobBlocked'), (N'AutomationHostDown')) AS kind(AlertKind)
WHERE NOT EXISTS (
  SELECT 1 FROM intranet.UserAlertSubscription existing
  WHERE existing.UserName = localUser.UserName AND existing.AlertKind = kind.AlertKind);

/* --- 13 — viseči zagoni starih ciklov brez utripa se zaprejo že tu ------------------- */

/* Ob pisanju sta bila v razvojni bazi WorkerCycleRunId 188 in 192 tri ure in pol »Running« brez
   utripa; zaprl bi ju šele naslednji prevzem najema v intranetu. @HostName = N'' ne ujame nobenega
   gostitelja, zato se zaprejo samo zagoni z utripom, starejšim od 30 minut. */
IF OBJECT_ID(N'ops.AbandonWorkerCycleRuns', N'P') IS NOT NULL
  EXEC ops.AbandonWorkerCycleRuns @HostName = N'', @Actor = N'237_EnotniModelOpravil', @StaleMinutes = 30;

/* --- preverba ----------------------------------------------------------------------- */

IF OBJECT_ID(N'ops.JobDefinition', N'U') IS NULL OR OBJECT_ID(N'ops.JobDependency', N'U') IS NULL
   OR OBJECT_ID(N'ops.JobRun', N'U') IS NULL OR OBJECT_ID(N'ops.JobStepRun', N'U') IS NULL
   OR OBJECT_ID(N'ops.DataCheckpoint', N'U') IS NULL OR OBJECT_ID(N'ops.Artifact', N'U') IS NULL
  THROW 52380, 'Tabele enotnega modela opravil niso nastale.', 1;

IF OBJECT_ID(N'ops.ClaimJobRun', N'P') IS NULL OR OBJECT_ID(N'ops.CompleteJobRun', N'P') IS NULL
   OR OBJECT_ID(N'ops.AbandonStaleJobRuns', N'P') IS NULL OR OBJECT_ID(N'ops.EvaluateJobAlerts', N'P') IS NULL
   OR OBJECT_ID(N'ops.RequestJobRun', N'P') IS NULL OR OBJECT_ID(N'ops.RequestJobCancel', N'P') IS NULL
   OR OBJECT_ID(N'intranet.GetJobDefinitions', N'P') IS NULL OR OBJECT_ID(N'intranet.GetJobRuns', N'P') IS NULL
   OR OBJECT_ID(N'intranet.GetAutomationHost', N'P') IS NULL OR OBJECT_ID(N'intranet.SaveJobSchedule', N'P') IS NULL
  THROW 52381, 'Procedure enotnega modela opravil niso nastale.', 1;

IF COL_LENGTH(N'ops.SchedulerLease', N'Priority') IS NULL
  THROW 52382, 'ops.SchedulerLease nima stolpca Priority.', 1;

IF (SELECT COUNT(*) FROM ops.JobDefinition) < 15
  THROW 52383, 'Posli niso zasejani.', 1;

IF (SELECT COUNT(*) FROM ops.JobDependency WHERE JobKey = N'WEB_CATALOG_EXPORT' AND DependsOnJobKey = N'PRODUCT_PUBLICATION' AND IsGate = 1) <> 1
  THROW 52384, 'Izvoz kataloga ni vezan na uspešno objavo.', 1;

IF EXISTS (SELECT 1 FROM ops.JobDependency WHERE JobKey IN (N'SAOP_ORDER_IMPORT') OR DependsOnJobKey = N'SAOP_ORDER_IMPORT')
  THROW 52385, 'Naročila morajo biti brez odvisnosti od kataloga.', 1;
