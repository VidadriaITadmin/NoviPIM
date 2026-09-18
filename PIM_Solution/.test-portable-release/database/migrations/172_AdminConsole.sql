/*
  172 — nadzorna plosca skrbnika: kaj tece, kdo je kaj spremenil, kaj gre ven in ali celota dela.

  Zakaj
  -----
  Skrbnik danes nima enega mesta, kjer bi videl, ali sistem dela. Podatki so, a so razsuti:

    ops.ScheduleProfile      ali sme teci in kako pogosto        /sistem/urniki
    ops.IntegrationHealth    zadnje stanje na (podjetje,postopek) /sistem/integracije
    ops.PipelineRun          zgodovina zagonov (od 144)          /teki-obdelave
    ops.Alert                alarmi                              /sistem/integracije
    pim.ProductFieldHistory  kdo je spremenil polje izdelka      kartica izdelka

  Tri stvari manjkajo v celoti:

  1. SLED UPORABNIKA CEZ VSE. Zgodovina obstaja samo za polja izdelkov. Kdo je izklopil urnik,
     kdo je odobril odhodno sporocilo, kdo je razresil alarm — vsak od teh je zapisan v svojem
     stolpcu svoje tabele (UpdatedBy, ApprovedBy, ResolvedBy) in nikjer skupaj. ops.UserActivity
     je enotna sled za dejanja, ki drugod ne pustijo vrstice, intranet.GetUserActivityTrail pa
     zdruzi vse vire v en kronoloski seznam.

  2. IZVOZI. out.ExportProfile pove, kaksna naj bo datoteka, ne pa ali je kdaj nastala.
     Po vsakem izvozu ni ostalo nic — ne stevila vrstic, ne velikosti, ne trajanja, ne napake.
     "Ali je zjutraj Magento dobil svez CSV" je bilo vprasanje za Raziskovalca datotek.
     out.ExportRun je ena vrstica na sestavljeno datoteko.

  3. ALI CELOTA DELA. Vsak kos ima svoj zeleni test, celota nima nobenega. ops.SelfTestRun in
     ops.SelfTestStep sta mesto, kamor nocni samotest zapise rezultat in — enako pomembno —
     TRAJANJE vsakega koraka. Brez trajanj ni odgovora na "kako hitro deluje" in ni mogoce
     opaziti, da se je nekaj podvojilo iz treh sekund v tri minute, dokler ne odpove.

  Cas ostaja UTC
  --------------
  Vse tri tabele hranijo UTC, kot vsa baza. Pretvorbo v naso uro dela izkljucno intranet
  (PimTime), ker je edini, ki ve, komu kaze. Ce bi cas pretvarjala baza, bi ista vrstica v
  izvozu, dnevniku in na zaslonu imela tri razlicne ure.

  Cesa ta migracija ne spremeni
  -----------------------------
  - Nobene obstojece tabele, procedure ali stolpca. Vse je novo; obstojece se samo bere.
  - ops.RunWatchdog in alarmiranje ostaneta natanko taka, kot sta.
*/

SET XACT_ABORT ON;

/* --- 1 — nocni samotest: en zagon, njegovi koraki in njihova trajanja ---------- */

IF OBJECT_ID(N'ops.SelfTestRun', N'U') IS NULL
BEGIN
  CREATE TABLE ops.SelfTestRun
  (
    SelfTestRunId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_SelfTestRun PRIMARY KEY,
    RunKey uniqueidentifier NOT NULL CONSTRAINT DF_SelfTestRun_RunKey DEFAULT NEWID(),
    TestCode nvarchar(100) NOT NULL,
    StartedUtc datetime2(3) NOT NULL CONSTRAINT DF_SelfTestRun_StartedUtc DEFAULT SYSUTCDATETIME(),
    EndedUtc datetime2(3) NULL,
    Status nvarchar(20) NOT NULL CONSTRAINT DF_SelfTestRun_Status DEFAULT N'Running',
    StepsTotal int NOT NULL CONSTRAINT DF_SelfTestRun_StepsTotal DEFAULT (0),
    StepsPassed int NOT NULL CONSTRAINT DF_SelfTestRun_StepsPassed DEFAULT (0),
    StepsFailed int NOT NULL CONSTRAINT DF_SelfTestRun_StepsFailed DEFAULT (0),
    StepsSkipped int NOT NULL CONSTRAINT DF_SelfTestRun_StepsSkipped DEFAULT (0),
    DurationMs int NULL,
    TriggeredBy nvarchar(30) NOT NULL CONSTRAINT DF_SelfTestRun_TriggeredBy DEFAULT N'Human',
    DetailRedacted nvarchar(2000) NULL,
    CONSTRAINT UQ_SelfTestRun_RunKey UNIQUE (RunKey),
    CONSTRAINT CK_SelfTestRun_Status CHECK (Status IN (N'Running', N'Passed', N'Warning', N'Failed', N'Abandoned')),
    CONSTRAINT CK_SelfTestRun_TriggeredBy CHECK (TriggeredBy IN (N'Scheduler', N'Human', N'Task'))
  );
END;

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'ops.SelfTestRun') AND name = N'IX_SelfTestRun_Started')
  CREATE INDEX IX_SelfTestRun_Started ON ops.SelfTestRun(TestCode, StartedUtc DESC);

IF OBJECT_ID(N'ops.SelfTestStep', N'U') IS NULL
BEGIN
  CREATE TABLE ops.SelfTestStep
  (
    SelfTestStepId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_SelfTestStep PRIMARY KEY,
    SelfTestRunId bigint NOT NULL,
    Ordinal int NOT NULL,
    StepCode nvarchar(60) NOT NULL,
    Label nvarchar(200) NOT NULL,
    Status nvarchar(20) NOT NULL,
    DurationMs int NOT NULL CONSTRAINT DF_SelfTestStep_DurationMs DEFAULT (0),
    /* Kaj je korak izmeril: vrstic, izdelkov, sekund. Brez tega je "PASS" samo obcutek. */
    Measure decimal(18,3) NULL,
    MeasureUnit nvarchar(30) NULL,
    DetailRedacted nvarchar(1000) NULL,
    CONSTRAINT FK_SelfTestStep_Run FOREIGN KEY (SelfTestRunId) REFERENCES ops.SelfTestRun(SelfTestRunId),
    CONSTRAINT UQ_SelfTestStep UNIQUE (SelfTestRunId, StepCode),
    CONSTRAINT CK_SelfTestStep_Status CHECK (Status IN (N'Passed', N'Warning', N'Failed', N'Skipped'))
  );
END;

/* --- 2 — izvozi: ena vrstica na sestavljeno datoteko --------------------------- */

IF OBJECT_ID(N'out.ExportRun', N'U') IS NULL
BEGIN
  CREATE TABLE out.ExportRun
  (
    ExportRunId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_ExportRun PRIMARY KEY,
    RunKey uniqueidentifier NOT NULL CONSTRAINT DF_ExportRun_RunKey DEFAULT NEWID(),
    ProfileCode nvarchar(100) NOT NULL,
    OrganizationId int NOT NULL,
    StartedUtc datetime2(3) NOT NULL CONSTRAINT DF_ExportRun_StartedUtc DEFAULT SYSUTCDATETIME(),
    EndedUtc datetime2(3) NULL,
    Status nvarchar(20) NOT NULL CONSTRAINT DF_ExportRun_Status DEFAULT N'Running',
    RowCountValue bigint NULL,
    ColumnCountValue int NULL,
    ByteCountValue bigint NULL,
    /* Hash je edini nacin, da se dve dostavi loci brez odpiranja datoteke. */
    Sha256 char(64) NULL,
    FileName nvarchar(400) NULL,
    DurationMs int NULL,
    TriggeredBy nvarchar(30) NOT NULL CONSTRAINT DF_ExportRun_TriggeredBy DEFAULT N'Human',
    Actor nvarchar(200) NULL,
    ErrorRedacted nvarchar(2000) NULL,
    CONSTRAINT UQ_ExportRun_RunKey UNIQUE (RunKey),
    CONSTRAINT FK_ExportRun_Organization FOREIGN KEY (OrganizationId) REFERENCES dbo.OrganizationConfig(OrganizationId),
    CONSTRAINT CK_ExportRun_Status CHECK (Status IN (N'Running', N'Succeeded', N'Failed', N'Abandoned')),
    CONSTRAINT CK_ExportRun_TriggeredBy CHECK (TriggeredBy IN (N'Scheduler', N'Human', N'Task'))
  );
END;

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'out.ExportRun') AND name = N'IX_ExportRun_Profile')
  CREATE INDEX IX_ExportRun_Profile ON out.ExportRun(ProfileCode, OrganizationId, StartedUtc DESC);

/* --- 3 — sled uporabnika za dejanja, ki drugod ne pustijo vrstice -------------- */

IF OBJECT_ID(N'ops.UserActivity', N'U') IS NULL
BEGIN
  CREATE TABLE ops.UserActivity
  (
    ActivityId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_UserActivity PRIMARY KEY,
    OccurredUtc datetime2(3) NOT NULL CONSTRAINT DF_UserActivity_OccurredUtc DEFAULT SYSUTCDATETIME(),
    Actor nvarchar(200) NOT NULL,
    ActionCode nvarchar(60) NOT NULL,
    EntityType nvarchar(100) NOT NULL,
    EntityKey nvarchar(300) NULL,
    OrganizationId int NULL,
    Summary nvarchar(400) NOT NULL,
    OldValue nvarchar(400) NULL,
    NewValue nvarchar(400) NULL,
    CONSTRAINT FK_UserActivity_Organization FOREIGN KEY (OrganizationId) REFERENCES dbo.OrganizationConfig(OrganizationId)
  );
END;

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'ops.UserActivity') AND name = N'IX_UserActivity_Occurred')
  CREATE INDEX IX_UserActivity_Occurred ON ops.UserActivity(OccurredUtc DESC) INCLUDE (Actor, ActionCode);

/* --- 4 — kaj je posamezni skrbnik ze videl ------------------------------------- */

IF OBJECT_ID(N'ops.AlertSeen', N'U') IS NULL
BEGIN
  CREATE TABLE ops.AlertSeen
  (
    UserKey nvarchar(200) NOT NULL,
    AlertId bigint NOT NULL,
    SeenUtc datetime2(3) NOT NULL CONSTRAINT DF_AlertSeen_SeenUtc DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_AlertSeen PRIMARY KEY (UserKey, AlertId),
    CONSTRAINT FK_AlertSeen_Alert FOREIGN KEY (AlertId) REFERENCES ops.Alert(AlertId)
  );
END;

/* --- 5 — zapisovalne procedure ------------------------------------------------- */
/* Migrator ne pozna locila GO, zato je vsaka procedura v svojem EXEC(N'...'). */

EXEC(N'CREATE OR ALTER PROCEDURE ops.BeginSelfTest
  @TestCode nvarchar(100),
  @TriggeredBy nvarchar(30) = N''Human'',
  @RunKey uniqueidentifier OUTPUT
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;

  /* Prejsnji zagon istega testa, ki se ni nikoli zaprl, ni "se tece" — proces je izginil.
     Tisina je videti kot zdravje samo, dokler je nihce ne poimenuje. */
  UPDATE ops.SelfTestRun
     SET Status = N''Abandoned'',
         EndedUtc = SYSUTCDATETIME(),
         DetailRedacted = N''Zagon se ni nikoli zakljucil; zaprl ga je naslednji zagon.''
   WHERE TestCode = @TestCode AND Status = N''Running'';

  SET @RunKey = NEWID();
  INSERT ops.SelfTestRun (RunKey, TestCode, TriggeredBy)
  VALUES (@RunKey, @TestCode,
          CASE WHEN @TriggeredBy IN (N''Scheduler'', N''Human'', N''Task'') THEN @TriggeredBy ELSE N''Human'' END);
END;');

EXEC(N'CREATE OR ALTER PROCEDURE ops.RecordSelfTestStep
  @RunKey uniqueidentifier,
  @Ordinal int,
  @StepCode nvarchar(60),
  @Label nvarchar(200),
  @Status nvarchar(20),
  @DurationMs int,
  @Measure decimal(18,3) = NULL,
  @MeasureUnit nvarchar(30) = NULL,
  @DetailRedacted nvarchar(1000) = NULL
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;

  DECLARE @RunId bigint = (SELECT SelfTestRunId FROM ops.SelfTestRun WHERE RunKey = @RunKey);
  IF @RunId IS NULL THROW 51200, ''Zagon samotesta ne obstaja.'', 1;

  MERGE ops.SelfTestStep AS target
  USING (SELECT @RunId AS SelfTestRunId, @StepCode AS StepCode) AS source
     ON target.SelfTestRunId = source.SelfTestRunId AND target.StepCode = source.StepCode
  WHEN MATCHED THEN UPDATE SET Ordinal = @Ordinal, Label = @Label, Status = @Status,
       DurationMs = @DurationMs, Measure = @Measure, MeasureUnit = @MeasureUnit, DetailRedacted = @DetailRedacted
  WHEN NOT MATCHED THEN INSERT (SelfTestRunId, Ordinal, StepCode, Label, Status, DurationMs, Measure, MeasureUnit, DetailRedacted)
       VALUES (@RunId, @Ordinal, @StepCode, @Label, @Status, @DurationMs, @Measure, @MeasureUnit, @DetailRedacted);
END;');

EXEC(N'CREATE OR ALTER PROCEDURE ops.CompleteSelfTest
  @RunKey uniqueidentifier,
  @DetailRedacted nvarchar(2000) = NULL
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;

  DECLARE @RunId bigint = (SELECT SelfTestRunId FROM ops.SelfTestRun WHERE RunKey = @RunKey);
  IF @RunId IS NULL THROW 51200, ''Zagon samotesta ne obstaja.'', 1;

  /* Koncni status se izpelje iz korakov in ne iz klicatelja: test, ki sam sebi doloci PASS,
     dokazuje samo, da zna izpisati PASS. */
  DECLARE @Passed int, @Failed int, @Warning int, @Skipped int;
  SELECT @Passed = SUM(CASE WHEN Status = N''Passed'' THEN 1 ELSE 0 END),
         @Failed = SUM(CASE WHEN Status = N''Failed'' THEN 1 ELSE 0 END),
         @Warning = SUM(CASE WHEN Status = N''Warning'' THEN 1 ELSE 0 END),
         @Skipped = SUM(CASE WHEN Status = N''Skipped'' THEN 1 ELSE 0 END)
    FROM ops.SelfTestStep WHERE SelfTestRunId = @RunId;

  UPDATE ops.SelfTestRun
     SET EndedUtc = SYSUTCDATETIME(),
         DurationMs = DATEDIFF(millisecond, StartedUtc, SYSUTCDATETIME()),
         StepsTotal = ISNULL(@Passed,0) + ISNULL(@Failed,0) + ISNULL(@Warning,0) + ISNULL(@Skipped,0),
         StepsPassed = ISNULL(@Passed,0),
         StepsFailed = ISNULL(@Failed,0),
         StepsSkipped = ISNULL(@Skipped,0),
         Status = CASE WHEN ISNULL(@Failed,0) > 0 THEN N''Failed''
                       WHEN ISNULL(@Warning,0) > 0 THEN N''Warning''
                       WHEN ISNULL(@Passed,0) = 0 THEN N''Failed''
                       ELSE N''Passed'' END,
         DetailRedacted = @DetailRedacted
   WHERE SelfTestRunId = @RunId;
END;');

EXEC(N'CREATE OR ALTER PROCEDURE out.BeginExportRun
  @ProfileCode nvarchar(100),
  @OrganizationId int,
  @TriggeredBy nvarchar(30) = N''Human'',
  @Actor nvarchar(200) = NULL,
  @RunKey uniqueidentifier OUTPUT
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;

  UPDATE out.ExportRun
     SET Status = N''Abandoned'', EndedUtc = SYSUTCDATETIME(),
         ErrorRedacted = N''Izvoz se ni nikoli zakljucil; zaprl ga je naslednji zagon.''
   WHERE ProfileCode = @ProfileCode AND OrganizationId = @OrganizationId AND Status = N''Running''
     AND StartedUtc < DATEADD(hour, -6, SYSUTCDATETIME());

  SET @RunKey = NEWID();
  INSERT out.ExportRun (RunKey, ProfileCode, OrganizationId, TriggeredBy, Actor)
  VALUES (@RunKey, @ProfileCode, @OrganizationId,
          CASE WHEN @TriggeredBy IN (N''Scheduler'', N''Human'', N''Task'') THEN @TriggeredBy ELSE N''Human'' END,
          @Actor);
END;');

EXEC(N'CREATE OR ALTER PROCEDURE out.CompleteExportRun
  @RunKey uniqueidentifier,
  @Succeeded bit,
  @RowCountValue bigint = NULL,
  @ColumnCountValue int = NULL,
  @ByteCountValue bigint = NULL,
  @Sha256 char(64) = NULL,
  @FileName nvarchar(400) = NULL,
  @ErrorRedacted nvarchar(2000) = NULL
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;

  UPDATE out.ExportRun
     SET EndedUtc = SYSUTCDATETIME(),
         DurationMs = DATEDIFF(millisecond, StartedUtc, SYSUTCDATETIME()),
         Status = CASE WHEN @Succeeded = 1 THEN N''Succeeded'' ELSE N''Failed'' END,
         RowCountValue = @RowCountValue,
         ColumnCountValue = @ColumnCountValue,
         ByteCountValue = @ByteCountValue,
         Sha256 = @Sha256,
         FileName = @FileName,
         ErrorRedacted = CASE WHEN @Succeeded = 0 THEN @ErrorRedacted END
   WHERE RunKey = @RunKey;

  IF @@ROWCOUNT = 0 THROW 51201, ''Zagon izvoza ne obstaja.'', 1;
END;');

EXEC(N'CREATE OR ALTER PROCEDURE ops.LogUserActivity
  @Actor nvarchar(200),
  @ActionCode nvarchar(60),
  @EntityType nvarchar(100),
  @Summary nvarchar(400),
  @EntityKey nvarchar(300) = NULL,
  @OrganizationId int = NULL,
  @OldValue nvarchar(400) = NULL,
  @NewValue nvarchar(400) = NULL
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  INSERT ops.UserActivity (Actor, ActionCode, EntityType, EntityKey, OrganizationId, Summary, OldValue, NewValue)
  VALUES (@Actor, @ActionCode, @EntityType, @EntityKey, @OrganizationId, @Summary, @OldValue, @NewValue);
END;');

EXEC(N'CREATE OR ALTER PROCEDURE intranet.MarkAlertsSeen
  @UserKey nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;

  INSERT ops.AlertSeen (UserKey, AlertId)
  SELECT @UserKey, alert.AlertId
    FROM ops.Alert alert
   WHERE alert.ResolvedUtc IS NULL
     AND NOT EXISTS (SELECT 1 FROM ops.AlertSeen seen
                      WHERE seen.UserKey = @UserKey AND seen.AlertId = alert.AlertId);
END;');

/* --- 6 — utrip sistema: en klic, sedem odgovorov ------------------------------- */
/*
   Zakaj en klic in ne sedem: stran se osvezuje sama vsako minuto. Sedem obiskov baze na
   minuto na eno odprto stran je sedemkrat vec povezav in sedem razlicnih trenutkov — ploscice
   bi kazale stanje, ki ni nikoli hkrati obstajalo.
*/
EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetAdminPulse
  @UserKey nvarchar(200) = NULL
AS
BEGIN
  SET NOCOUNT ON;

  DECLARE @Zdaj datetime2(3) = SYSUTCDATETIME();
  DECLARE @Od datetime2(3) = DATEADD(hour, -24, @Zdaj);

  /* 1 — postopki: kaj sme teci, ali tece in kdaj je nazadnje uspelo */
  SELECT razpored.OrganizationId,
         podjetje.Name AS OrganizationName,
         razpored.Pipeline,
         razpored.IsEnabled,
         razpored.IntervalSeconds,
         razpored.StaleAfterSeconds,
         razpored.NextScheduledUtc,
         zdravje.Status,
         zdravje.LastHeartbeatUtc,
         zdravje.LastSuccessfulRunUtc,
         zdravje.LastFailedRunUtc,
         zdravje.LastErrorRedacted,
         DATEDIFF(second, zdravje.LastHeartbeatUtc, @Zdaj) AS SecondsSinceHeartbeat,
         /* Zamuja = sme teci, pa se dlje casa ni oglasil. Izklopljen postopek ne zamuja. */
         CAST(CASE WHEN razpored.IsEnabled = 1
                    AND (zdravje.LastHeartbeatUtc IS NULL
                         OR DATEDIFF(second, zdravje.LastHeartbeatUtc, @Zdaj) > razpored.StaleAfterSeconds)
                   THEN 1 ELSE 0 END AS bit) AS IsStale,
         zadnji.Status AS LastRunStatus,
         zadnji.StartedUtc AS LastRunStartedUtc,
         zadnji.DurationMs AS LastRunDurationMs,
         zadnji.RowsRead AS LastRunRowsRead,
         zadnji.RowsFailed AS LastRunRowsFailed,
         ISNULL(dan.Runs24h, 0) AS Runs24h,
         ISNULL(dan.Failures24h, 0) AS Failures24h,
         dan.AvgDurationMs,
         dan.MaxDurationMs
    FROM ops.ScheduleProfile razpored
    JOIN dbo.OrganizationConfig podjetje ON podjetje.OrganizationId = razpored.OrganizationId
    LEFT JOIN ops.IntegrationHealth zdravje
           ON zdravje.OrganizationId = razpored.OrganizationId AND zdravje.Pipeline = razpored.Pipeline
    OUTER APPLY (
      SELECT TOP (1) tek.Status, tek.StartedUtc, tek.RowsRead, tek.RowsFailed,
             DATEDIFF(millisecond, tek.StartedUtc, tek.EndedUtc) AS DurationMs
        FROM ops.PipelineRun tek
       WHERE tek.OrganizationId = razpored.OrganizationId AND tek.Pipeline = razpored.Pipeline
       ORDER BY tek.StartedUtc DESC
    ) zadnji
    OUTER APPLY (
      SELECT COUNT(*) AS Runs24h,
             SUM(CASE WHEN tek.Status IN (N''Failed'', N''TimedOut'', N''Abandoned'') THEN 1 ELSE 0 END) AS Failures24h,
             AVG(CASE WHEN tek.EndedUtc IS NOT NULL THEN DATEDIFF(millisecond, tek.StartedUtc, tek.EndedUtc) END) AS AvgDurationMs,
             MAX(CASE WHEN tek.EndedUtc IS NOT NULL THEN DATEDIFF(millisecond, tek.StartedUtc, tek.EndedUtc) END) AS MaxDurationMs
        FROM ops.PipelineRun tek
       WHERE tek.OrganizationId = razpored.OrganizationId AND tek.Pipeline = razpored.Pipeline
         AND tek.StartedUtc >= @Od
    ) dan
   ORDER BY razpored.Pipeline, razpored.OrganizationId;

  /* 2 — odprti alarmi; IsSeen pove, ali jih je TA skrbnik ze videl */
  SELECT TOP (100)
         alarm.AlertId, alarm.OrganizationId, podjetje.Name AS OrganizationName,
         alarm.Pipeline, alarm.AlertKind, alarm.Severity, alarm.Title,
         alarm.PayloadSummaryRedacted, alarm.OccurrenceCount,
         alarm.FirstSeenUtc, alarm.LastSeenUtc, alarm.AcknowledgedUtc, alarm.AcknowledgedBy,
         CAST(CASE WHEN videno.AlertId IS NULL THEN 0 ELSE 1 END AS bit) AS IsSeen
    FROM ops.Alert alarm
    JOIN dbo.OrganizationConfig podjetje ON podjetje.OrganizationId = alarm.OrganizationId
    LEFT JOIN ops.AlertSeen videno ON videno.AlertId = alarm.AlertId AND videno.UserKey = @UserKey
   WHERE alarm.ResolvedUtc IS NULL
   ORDER BY CASE alarm.Severity WHEN N''Critical'' THEN 0 WHEN N''Warning'' THEN 1 ELSE 2 END,
            alarm.LastSeenUtc DESC;

  /* 3 — zadnji nocni samotest */
  SELECT TOP (1) test.SelfTestRunId, test.RunKey, test.TestCode, test.StartedUtc, test.EndedUtc,
         test.Status, test.StepsTotal, test.StepsPassed, test.StepsFailed, test.StepsSkipped,
         test.DurationMs, test.TriggeredBy, test.DetailRedacted
    FROM ops.SelfTestRun test
   ORDER BY test.StartedUtc DESC;

  /* 4 — koraki tega zagona, z izmerjenim trajanjem */
  SELECT korak.Ordinal, korak.StepCode, korak.Label, korak.Status, korak.DurationMs,
         korak.Measure, korak.MeasureUnit, korak.DetailRedacted
    FROM ops.SelfTestStep korak
   WHERE korak.SelfTestRunId = (SELECT TOP (1) SelfTestRunId FROM ops.SelfTestRun ORDER BY StartedUtc DESC)
   ORDER BY korak.Ordinal;

  /* 5 — katalog po podjetjih */
  SELECT podjetje.OrganizationId, podjetje.Name AS OrganizationName,
         COUNT_BIG(izdelek.ProductId) AS ProductCount,
         SUM(CASE WHEN izdelek.IsActive = 1 THEN 1 ELSE 0 END) AS ActiveCount,
         SUM(CASE WHEN izdelek.WebPublish = 1 THEN 1 ELSE 0 END) AS PublishedCount,
         SUM(CASE WHEN izdelek.ValidationStatus = N''Invalid'' THEN 1 ELSE 0 END) AS InvalidCount,
         (SELECT COUNT_BIG(*) FROM raw.Inbox vhod
           WHERE vhod.OrganizationId = podjetje.OrganizationId AND vhod.Status = N''Quarantined'') AS QuarantineCount
    FROM dbo.OrganizationConfig podjetje
    LEFT JOIN canon.Product izdelek ON izdelek.OrganizationId = podjetje.OrganizationId
   WHERE podjetje.IsActive = 1
   GROUP BY podjetje.OrganizationId, podjetje.Name
   ORDER BY podjetje.OrganizationId;

  /* 6 — odhodna vrsta po stanju */
  SELECT sporocilo.Status, COUNT_BIG(*) AS MessageCount
    FROM out.OutboxMessage sporocilo
   GROUP BY sporocilo.Status;

  /* 7 — zadnji izvoz po profilu in podjetju */
  SELECT profil.ProfileCode, profil.Name AS ProfileName, profil.ChannelCode, profil.EntityType, profil.IsActive,
         podjetje.OrganizationId, podjetje.Name AS OrganizationName,
         zadnji.StartedUtc, zadnji.EndedUtc, zadnji.Status, zadnji.RowCountValue,
         zadnji.ColumnCountValue, zadnji.ByteCountValue, zadnji.DurationMs, zadnji.FileName,
         zadnji.TriggeredBy, zadnji.ErrorRedacted
    FROM out.ExportProfile profil
   CROSS JOIN dbo.OrganizationConfig podjetje
   OUTER APPLY (
     SELECT TOP (1) izvoz.StartedUtc, izvoz.EndedUtc, izvoz.Status, izvoz.RowCountValue,
            izvoz.ColumnCountValue, izvoz.ByteCountValue, izvoz.DurationMs, izvoz.FileName,
            izvoz.TriggeredBy, izvoz.ErrorRedacted
       FROM out.ExportRun izvoz
      WHERE izvoz.ProfileCode = profil.ProfileCode AND izvoz.OrganizationId = podjetje.OrganizationId
      ORDER BY izvoz.StartedUtc DESC
   ) zadnji
   WHERE profil.IsActive = 1 AND podjetje.IsActive = 1 AND zadnji.StartedUtc IS NOT NULL
   ORDER BY zadnji.StartedUtc DESC;
END;');

/* --- 7 — zmogljivost postopkov: koliko tece in kako dolgo ---------------------- */
EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetWorkerPerformance
  @Days int = 7
AS
BEGIN
  SET NOCOUNT ON;
  IF @Days IS NULL OR @Days < 1 SET @Days = 7;
  IF @Days > 90 SET @Days = 90;

  DECLARE @Od datetime2(3) = DATEADD(day, -@Days, SYSUTCDATETIME());

  /* Povprecje samo pove, da je nekaj hitro "v povprecju". Najdaljsi tek pove, kdaj sistem
     ne bo ujel svojega razmika — in prav to je tisto, kar pade ponoci. */
  SELECT tek.Pipeline,
         tek.OrganizationId,
         podjetje.Name AS OrganizationName,
         COUNT(*) AS RunCount,
         SUM(CASE WHEN tek.Status = N''Succeeded'' THEN 1 ELSE 0 END) AS SucceededCount,
         SUM(CASE WHEN tek.Status = N''Warning'' THEN 1 ELSE 0 END) AS WarningCount,
         SUM(CASE WHEN tek.Status IN (N''Failed'', N''TimedOut'', N''Abandoned'') THEN 1 ELSE 0 END) AS FailedCount,
         AVG(CASE WHEN tek.EndedUtc IS NOT NULL THEN DATEDIFF(millisecond, tek.StartedUtc, tek.EndedUtc) END) AS AvgDurationMs,
         MAX(CASE WHEN tek.EndedUtc IS NOT NULL THEN DATEDIFF(millisecond, tek.StartedUtc, tek.EndedUtc) END) AS MaxDurationMs,
         SUM(tek.RowsRead) AS RowsRead,
         SUM(tek.RowsFailed) AS RowsFailed,
         MAX(tek.StartedUtc) AS LastStartedUtc,
         /* Razmik iz razporeda je merilo: tek, ki traja dlje od svojega razmika, se lovi sam s seboj. */
         razpored.IntervalSeconds
    FROM ops.PipelineRun tek
    LEFT JOIN dbo.OrganizationConfig podjetje ON podjetje.OrganizationId = tek.OrganizationId
    LEFT JOIN ops.ScheduleProfile razpored
           ON razpored.OrganizationId = tek.OrganizationId AND razpored.Pipeline = tek.Pipeline
   WHERE tek.StartedUtc >= @Od
   GROUP BY tek.Pipeline, tek.OrganizationId, podjetje.Name, razpored.IntervalSeconds
   ORDER BY tek.Pipeline, tek.OrganizationId;
END;');

/* --- 8 — kdo je kaj naredil: en kronoloski seznam iz vseh sledi ---------------- */
/*
   Vsak vir tu ze obstaja; manjkalo je to, da bi bili na enem mestu in v istem stolpcu casa.
   Cas je povsod UTC; v naso uro ga pretvori intranet, ne ta procedura.
*/
EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetUserActivityTrail
  @Days int = 7,
  @Actor nvarchar(200) = NULL,
  @Search nvarchar(200) = NULL,
  @Take int = 300
AS
BEGIN
  SET NOCOUNT ON;
  IF @Days IS NULL OR @Days < 1 SET @Days = 7;
  IF @Days > 365 SET @Days = 365;
  IF @Take IS NULL OR @Take < 1 SET @Take = 300;
  IF @Take > 2000 SET @Take = 2000;

  DECLARE @Od datetime2(3) = DATEADD(day, -@Days, SYSUTCDATETIME());
  DECLARE @Vzorec nvarchar(210) = CASE WHEN @Search IS NULL OR LTRIM(RTRIM(@Search)) = N'''' THEN NULL
                                       ELSE N''%'' + LTRIM(RTRIM(@Search)) + N''%'' END;

  WITH sled AS
  (
    /* Polja izdelkov: edina sled, ki je obstajala ze prej. */
    SELECT zgodovina.ChangedAtUtc AS OccurredUtc,
           paket.ChangedBy AS Actor,
           N''PRODUCT_FIELD'' AS ActionCode,
           N''Izdelek'' AS EntityType,
           zgodovina.ItemID AS EntityKey,
           zgodovina.OrganizationId,
           CONCAT(N''Polje '', zgodovina.FieldKey, N'' ('', zgodovina.Owner, N'')'') AS Summary,
           zgodovina.OldValue,
           zgodovina.NewValue,
           N''pim.ProductFieldHistory'' AS SourceTable
      FROM pim.ProductFieldHistory zgodovina
      JOIN pim.ProductChangeBatch paket ON paket.ChangeBatchId = zgodovina.ChangeBatchId
     WHERE zgodovina.ChangedAtUtc >= @Od

    UNION ALL

    /* Dejanja intraneta, ki drugod ne pustijo vrstice (migracija 172). */
    SELECT dejanje.OccurredUtc, dejanje.Actor, dejanje.ActionCode, dejanje.EntityType,
           dejanje.EntityKey, dejanje.OrganizationId, dejanje.Summary, dejanje.OldValue, dejanje.NewValue,
           N''ops.UserActivity''
      FROM ops.UserActivity dejanje
     WHERE dejanje.OccurredUtc >= @Od

    UNION ALL

    /* Alarmi: potrditev in razresitev sta zapisani v svojih stolpcih. */
    SELECT alarm.AcknowledgedUtc, alarm.AcknowledgedBy, N''ALERT_ACK'', N''Alarm'',
           CAST(alarm.AlertId AS nvarchar(300)), alarm.OrganizationId,
           CONCAT(N''Potrdil alarm: '', alarm.Title), NULL, NULL, N''ops.Alert''
      FROM ops.Alert alarm
     WHERE alarm.AcknowledgedUtc >= @Od AND alarm.AcknowledgedBy IS NOT NULL

    UNION ALL

    SELECT alarm.ResolvedUtc, alarm.ResolvedBy, N''ALERT_RESOLVE'', N''Alarm'',
           CAST(alarm.AlertId AS nvarchar(300)), alarm.OrganizationId,
           CONCAT(N''Razresil alarm: '', alarm.Title), NULL, NULL, N''ops.Alert''
      FROM ops.Alert alarm
     WHERE alarm.ResolvedUtc >= @Od AND alarm.ResolvedBy IS NOT NULL

    UNION ALL

    /* Odobritve odhodnih sporocil v SAOP. */
    SELECT sporocilo.ApprovedUtc, sporocilo.ApprovedBy, N''OUTBOX_APPROVE'', N''Odhodno sporocilo'',
           sporocilo.EntityKey, sporocilo.OrganizationId,
           CONCAT(N''Odobril '', sporocilo.Operation, N'' za '', sporocilo.EntityType), NULL,
           LEFT(ISNULL(sporocilo.FieldSummary, N''''), 400), N''out.OutboxMessage''
      FROM out.OutboxMessage sporocilo
     WHERE sporocilo.ApprovedUtc >= @Od AND sporocilo.ApprovedBy IS NOT NULL

    UNION ALL

    /* Urniki: tabela hrani samo zadnjo spremembo, zato je tu ena vrstica na razpored. */
    SELECT razpored.UpdatedUtc, razpored.UpdatedBy, N''SCHEDULE_UPDATE'', N''Urnik'',
           razpored.Pipeline, razpored.OrganizationId,
           CONCAT(N''Urnik '', razpored.Pipeline, CASE WHEN razpored.IsEnabled = 1 THEN N'' vklopljen'' ELSE N'' izklopljen'' END),
           NULL, CONCAT(razpored.IntervalSeconds / 60, N'' min''), N''ops.ScheduleProfile''
      FROM ops.ScheduleProfile razpored
     WHERE razpored.UpdatedUtc >= @Od

    UNION ALL

    /* Poslovni register B2B. */
    SELECT revizija.ChangedUtc, revizija.ChangedBy, revizija.ActionCode, revizija.EntityType,
           revizija.EntityKey, revizija.OrganizationId,
           CONCAT(revizija.ActionCode, N'' na '', revizija.EntityType), NULL, NULL, N''b2b.AuditLog''
      FROM b2b.AuditLog revizija
     WHERE revizija.ChangedUtc >= @Od
  )
  SELECT TOP (@Take) sled.OccurredUtc, sled.Actor, sled.ActionCode, sled.EntityType, sled.EntityKey,
         sled.OrganizationId, podjetje.Name AS OrganizationName, sled.Summary, sled.OldValue, sled.NewValue,
         sled.SourceTable
    FROM sled
    LEFT JOIN dbo.OrganizationConfig podjetje ON podjetje.OrganizationId = sled.OrganizationId
   WHERE sled.OccurredUtc IS NOT NULL
     AND (@Actor IS NULL OR sled.Actor = @Actor)
     AND (@Vzorec IS NULL
          OR sled.Actor LIKE @Vzorec
          OR sled.EntityKey LIKE @Vzorec
          OR sled.Summary LIKE @Vzorec)
   ORDER BY sled.OccurredUtc DESC;
END;');

/* --- 9 — zgodovina izvozov ----------------------------------------------------- */
EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetExportRuns
  @Days int = 7,
  @ProfileCode nvarchar(100) = NULL,
  @Take int = 300
AS
BEGIN
  SET NOCOUNT ON;
  IF @Days IS NULL OR @Days < 1 SET @Days = 7;
  IF @Days > 365 SET @Days = 365;
  IF @Take IS NULL OR @Take < 1 SET @Take = 300;
  IF @Take > 2000 SET @Take = 2000;

  SELECT TOP (@Take)
         izvoz.ExportRunId, izvoz.ProfileCode, profil.Name AS ProfileName, profil.ChannelCode,
         izvoz.OrganizationId, podjetje.Name AS OrganizationName,
         izvoz.StartedUtc, izvoz.EndedUtc, izvoz.Status, izvoz.RowCountValue, izvoz.ColumnCountValue,
         izvoz.ByteCountValue, izvoz.Sha256, izvoz.FileName, izvoz.DurationMs, izvoz.TriggeredBy,
         izvoz.Actor, izvoz.ErrorRedacted
    FROM out.ExportRun izvoz
    LEFT JOIN out.ExportProfile profil ON profil.ProfileCode = izvoz.ProfileCode
    LEFT JOIN dbo.OrganizationConfig podjetje ON podjetje.OrganizationId = izvoz.OrganizationId
   WHERE izvoz.StartedUtc >= DATEADD(day, -@Days, SYSUTCDATETIME())
     AND (@ProfileCode IS NULL OR izvoz.ProfileCode = @ProfileCode)
   ORDER BY izvoz.StartedUtc DESC;
END;');

/* --- 10 — zgodovina samotestov: ali se je stanje slabsalo ---------------------- */
EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetSelfTestHistory
  @Take int = 30
AS
BEGIN
  SET NOCOUNT ON;
  IF @Take IS NULL OR @Take < 1 SET @Take = 30;
  IF @Take > 500 SET @Take = 500;

  SELECT TOP (@Take) test.SelfTestRunId, test.TestCode, test.StartedUtc, test.EndedUtc, test.Status,
         test.StepsTotal, test.StepsPassed, test.StepsFailed, test.StepsSkipped, test.DurationMs,
         test.TriggeredBy, test.DetailRedacted
    FROM ops.SelfTestRun test
   ORDER BY test.StartedUtc DESC;
END;');
