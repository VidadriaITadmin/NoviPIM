/*
  144 — sled izvajanja: ena vrstica na zagon.

  Zakaj. Vprasanje je bilo preprosto: ali se ob vsakem zagonu workerja v bazo zapise vrstica z
  zacetkom, koncem, statusom, prebranim, zapisanim in napako. Odgovor je bil ne, ceprav tabela
  s tocno temi stolpci obstaja od migracije 002.

    ops.IntegrationHealth   stanje; ena vrstica na (podjetje, postopek), ki se ob vsakem
                            zagonu prepise. Zgodovine ni, prejsnja napaka se ob uspehu izbrise.
    ops.PipelineRun         zgodovina; StartedUtc, EndedUtc, Status, RowsRead, RowsSucceeded,
                            RowsFailed. Vanjo sta pisala samo PIM.KatalogWorker in
                            PIM.XmlFileWorker, vsak s svojim INSERT in svojim RunId.
    ops.ErrorLog            napake; procedura ops.LogError obstaja od 003, klical je ni nihce.

  Izmerjeno v razvojni bazi 2026-09-02: ops.PipelineRun je imela SAOP_PRODUCTS in GENERIC_XML,
  za SOURCE_FETCH, STOCK_FILE, SAOP_STOCK, WATCHDOG in ALERT_DISPATCH pa nic — ceprav so vsi ti
  v ops.IntegrationHealth. ops.ErrorLog je imela nic vrstic, ceprav jo intranet bere na petih
  mestih; stolpec "napake" je bil zato strukturno vedno nic. 19 vrstic je stalo brez EndedUtc,
  pet med njimi v stanju Running.

  Kje se vrstica pise. V ops.BeginRun in ops.CompleteRun, ne v razporejevalniku ali workerju.
  Razporejevalnik ni edina vrata: rocni zagon Zaloga-cikel.ps1 gre mimo njega in vsak prihodnji
  sprozilec tudi. BeginRun je ozko grlo, skozi katero gre vse — in ker ze dobi podjetje,
  postopek in WorkerId ter vrne RunId, je zapis zgodovine njegov naravni posel. S tem sled
  dobi vseh sedem postopkov naenkrat, brez posega v posameznega workerja.

  Status ostane zaprt seznam, kot je bil (CK_PipelineRun_Status iz 002), samo daljsi. Imen
  Succeeded in Failed ne preimenujem: v bazi je 138 vrstic z njimi, PipelineReadService pa se
  nanje naslanja na enajstih mestih. Nova stanja locijo tri razlicne zgodbe, ki so se doslej
  zlivale v eno:

    Failed      padlo je
    TimedOut    ubila ga je meja izvajanja
    Cancelled   nekdo ga je ustavil
    Abandoned   nikoli se ni zaprlo — proces je izginil in tega ni povedal nihce
    Warning     koncalo je, a del vrstic je v karanteni

  Zlivanje teh stanj je natanko tisto, zaradi cesar tisina izgleda kot zdravje.

  Cesa ta migracija ne premakne. ops.RunWatchdog dela nad ops.IntegrationHealth in
  ops.ScheduleProfile in tam ostane: IntegrationHealth je stanje in edini vir alarma,
  ops.PipelineRun je zgodovina in forenzika. Zaloga je v IntegrationHealth prisotna, v
  ops.PipelineRun je ne bo — zato mora vsak pogled "zadnji teki" zalogo pobrati iz
  stock.SyncRun z unijo, tako kot to ze pocne PipelineReadService.

  Migrator ne pozna locila GO; vse, kar se dotika novih stolpcev, je zato zavito v EXEC(N'...'),
  ker bi se ad hoc stavek prevedel prezgodaj in padel z "Invalid column name".
*/

SET XACT_ABORT ON;

/* --- 1 — stolpci, ki jih zgodovina doslej ni imela --------------------------- */

IF COL_LENGTH(N'ops.PipelineRun', N'WorkerId') IS NULL
  ALTER TABLE ops.PipelineRun ADD WorkerId nvarchar(200) NULL;

IF COL_LENGTH(N'ops.PipelineRun', N'ExitCode') IS NULL
  ALTER TABLE ops.PipelineRun ADD ExitCode int NULL;

/* Kdo je zagon sprozil. Ob dveh ponoci je razlika med "urnik je pognal" in "nekdo je
   pritisnil" prvo vprasanje. Vrednost pride iz okolja (PIM_TRIGGERED_BY); kdor je ne postavi,
   je clovek za ukazno vrstico. */
IF COL_LENGTH(N'ops.PipelineRun', N'TriggeredBy') IS NULL
  ALTER TABLE ops.PipelineRun ADD TriggeredBy nvarchar(30) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_PipelineRun_TriggeredBy')
  EXEC(N'ALTER TABLE ops.PipelineRun ADD CONSTRAINT CK_PipelineRun_TriggeredBy
         CHECK (TriggeredBy IS NULL OR TriggeredBy IN (N''Scheduler'', N''Human'', N''Task''));');

/* --- 2 — zaprt seznam stanj, daljsi za tri ---------------------------------- */

IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_PipelineRun_Status')
  ALTER TABLE ops.PipelineRun DROP CONSTRAINT CK_PipelineRun_Status;

ALTER TABLE ops.PipelineRun ADD CONSTRAINT CK_PipelineRun_Status
  CHECK (Status IN (N'Pending', N'Running', N'Succeeded', N'Warning',
                    N'Failed', N'TimedOut', N'Cancelled', N'Abandoned'));

/* --- 3 — BeginRun odslej odpre tudi vrstico zgodovine ------------------------ */

EXEC(N'CREATE OR ALTER PROCEDURE ops.BeginRun
  @OrganizationId int,
  @Pipeline nvarchar(100),
  @WorkerId nvarchar(200),
  @RunId uniqueidentifier OUTPUT,
  @SourceCode nvarchar(100) = NULL,
  @TriggeredBy nvarchar(30) = N''Human''
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;

  DECLARE @LockTimeout int, @LockResult int, @Resource nvarchar(255)=CONCAT(N''PIM:ops:'',@OrganizationId,N'':'',@Pipeline);
  SELECT @LockTimeout=LockTimeoutMilliseconds FROM ops.ScheduleProfile WHERE OrganizationId=@OrganizationId AND Pipeline=@Pipeline AND IsEnabled=1;
  IF @LockTimeout IS NULL THROW 51100, ''Razpored ni omogočen.'', 1;
  EXEC @LockResult=sys.sp_getapplock @Resource=@Resource,@LockMode=N''Exclusive'',@LockOwner=N''Session'',@LockTimeout=@LockTimeout,@DbPrincipal=N''public'';
  IF @LockResult<0 THROW 51101, ''Izvajanje za organizacijo in pipeline že poteka.'', 1;

  SET @RunId=NEWID();

  /* Zgodovina. Ista identiteta kot jo dobi klicatelj — doslej sta KatalogWorker in
     XmlFileWorker delala svoj Guid in teka ni bilo mogoce sestaviti nazaj. */
  INSERT ops.PipelineRun (RunId, Pipeline, OrganizationId, SourceCode, Status, WorkerId, TriggeredBy)
  VALUES (@RunId, @Pipeline, @OrganizationId, @SourceCode, N''Running'', @WorkerId,
          CASE WHEN @TriggeredBy IN (N''Scheduler'', N''Human'', N''Task'') THEN @TriggeredBy ELSE N''Human'' END);

  /* Stanje. Nespremenjeno od 025. */
  MERGE ops.IntegrationHealth AS target USING (SELECT @OrganizationId OrganizationId,@Pipeline Pipeline) source
    ON target.OrganizationId=source.OrganizationId AND target.Pipeline=source.Pipeline
  WHEN MATCHED THEN UPDATE SET RunId=@RunId,WorkerId=@WorkerId,Status=N''Running'',LastHeartbeatUtc=SYSUTCDATETIME(),LastErrorRedacted=NULL,UpdatedUtc=SYSUTCDATETIME()
  WHEN NOT MATCHED THEN INSERT(OrganizationId,Pipeline,RunId,WorkerId,Status,LastHeartbeatUtc) VALUES(@OrganizationId,@Pipeline,@RunId,@WorkerId,N''Running'',SYSUTCDATETIME());
END;');

/* --- 4 — CompleteRun zapre vrstico in napako zapise tja, kjer jo intranet bere -- */

EXEC(N'CREATE OR ALTER PROCEDURE ops.CompleteRun
  @OrganizationId int,
  @Pipeline nvarchar(100),
  @RunId uniqueidentifier,
  @Succeeded bit,
  @ErrorRedacted nvarchar(2000) = NULL,
  @Status nvarchar(30) = NULL,
  @ExitCode int = NULL
AS
BEGIN
  SET NOCOUNT ON;

  /* @Succeeded ostane, ker ga kliceta vseh sedem workerjev. @Status je za tiste, ki znajo
     povedati vec: TimedOut ni isto kot Failed, Warning ni isto kot Succeeded. */
  DECLARE @KoncniStatus nvarchar(30) = COALESCE(@Status, CASE WHEN @Succeeded=1 THEN N''Succeeded'' ELSE N''Failed'' END);
  IF @KoncniStatus NOT IN (N''Succeeded'', N''Warning'', N''Failed'', N''TimedOut'', N''Cancelled'', N''Abandoned'')
    THROW 51104, ''Neveljavno koncno stanje izvajanja.'', 1;

  DECLARE @StartedUtc datetime2(3);
  SELECT @StartedUtc = LastHeartbeatUtc FROM ops.IntegrationHealth
  WHERE OrganizationId=@OrganizationId AND Pipeline=@Pipeline AND RunId=@RunId;

  UPDATE ops.IntegrationHealth SET Status=CASE WHEN @Succeeded=1 THEN N''Healthy'' ELSE N''Failed'' END,
    LastSuccessfulRunUtc=CASE WHEN @Succeeded=1 THEN SYSUTCDATETIME() ELSE LastSuccessfulRunUtc END,
    LastFailedRunUtc=CASE WHEN @Succeeded=0 THEN SYSUTCDATETIME() ELSE LastFailedRunUtc END,
    LastHeartbeatUtc=SYSUTCDATETIME(),LastErrorRedacted=CASE WHEN @Succeeded=0 THEN @ErrorRedacted END,
    ConsecutiveFailures=CASE WHEN @Succeeded=1 THEN 0 ELSE ConsecutiveFailures+1 END,
    UpdatedUtc=SYSUTCDATETIME()
  WHERE OrganizationId=@OrganizationId AND Pipeline=@Pipeline AND RunId=@RunId;
  IF @@ROWCOUNT<>1 THROW 51103, ''Izvajanja ni mogoce zakljuciti.'', 1;

  /* Zgodovina se zapre tudi takrat, ko tek pade — doslej jo je zapiral samo srecen konec in
     19 vrstic je zato stalo odprtih. */
  UPDATE ops.PipelineRun
  SET Status = @KoncniStatus,
      EndedUtc = SYSUTCDATETIME(),
      ExitCode = COALESCE(@ExitCode, ExitCode)
  WHERE RunId = @RunId;

  /* Napaka dobi mesto, kjer jo intranet ze bere. Brez tega je stolpec "napake" strukturno
     vedno nic — in prazna tabela, ki jo vmesnik bere, lazje kot manjkajoc stolpec. */
  IF @Succeeded = 0 AND @ErrorRedacted IS NOT NULL AND LEN(LTRIM(RTRIM(@ErrorRedacted))) > 0
    EXEC ops.LogError
      @Layer = N''Worker'',
      @Severity = N''Error'',
      @ErrorCode = @KoncniStatus,
      @Message = @ErrorRedacted,
      @RunId = @RunId;

  /* Ritem od zacetka teka, ne od konca: sicer se razmik sesteva s trajanjem. */
  UPDATE ops.ScheduleProfile
  SET NextScheduledUtc = DATEADD(second, IntervalSeconds, COALESCE(@StartedUtc, SYSUTCDATETIME()))
  WHERE OrganizationId=@OrganizationId AND Pipeline=@Pipeline;

  IF @Succeeded = 0
  BEGIN
    DECLARE @Failures int, @Prag int;
    SELECT @Failures = health.ConsecutiveFailures, @Prag = profile.MaxConsecutiveFailures
    FROM ops.IntegrationHealth health
    INNER JOIN ops.ScheduleProfile profile
      ON profile.OrganizationId=health.OrganizationId AND profile.Pipeline=health.Pipeline
    WHERE health.OrganizationId=@OrganizationId AND health.Pipeline=@Pipeline;

    IF @Prag IS NOT NULL AND @Prag > 0 AND @Failures >= @Prag
    BEGIN
      UPDATE ops.ScheduleProfile
      SET IsEnabled=0, UpdatedUtc=SYSUTCDATETIME(), UpdatedBy=N''samodejni izklop po napakah''
      WHERE OrganizationId=@OrganizationId AND Pipeline=@Pipeline AND IsEnabled=1;

      /* DedupKey je na (podjetje, postopek), zato ponovni izklop ne ustvari novega alarma,
         ampak poveca stevec pojavitev na obstojecem. */
      EXEC ops.UpsertAlert
        @OrganizationId=@OrganizationId,
        @Pipeline=@Pipeline,
        @AlertKind=N''PipelineDisabled'',
        @Severity=N''Critical'',
        @DedupKey=NULL,
        @Title=NULL,
        @PayloadSummaryRedacted=NULL,
        @Actor=N''ops.CompleteRun'';
    END;
  END;

  /* Kljucavnico vzame ops.BeginRun z @LockOwner=N''Session''; brez tega ostane na povezavi,
     dokler ta ne umre, in naslednji zagon v istem procesu naleti nase. Sprosti se samo tisto,
     kar ta seja res drzi — zakljucek izvajanja ne sme pasti zaradi kljucavnice. */
  DECLARE @Resource nvarchar(255)=CONCAT(N''PIM:ops:'',@OrganizationId,N'':'',@Pipeline);
  IF APPLOCK_MODE(N''public'',@Resource,N''Session'') <> N''NoLock''
    EXEC sys.sp_releaseapplock @Resource=@Resource,@LockOwner=N''Session'',@DbPrincipal=N''public'';
END;');

/* --- 5 — stevci: doslej jih je vsak worker pisal po svoje -------------------- */

EXEC(N'CREATE OR ALTER PROCEDURE ops.RecordRunCounts
  @RunId uniqueidentifier,
  @RowsRead bigint = NULL,
  @RowsSucceeded bigint = NULL,
  @RowsFailed bigint = NULL
AS
BEGIN
  SET NOCOUNT ON;
  UPDATE ops.PipelineRun
  SET RowsRead = COALESCE(@RowsRead, RowsRead),
      RowsSucceeded = COALESCE(@RowsSucceeded, RowsSucceeded),
      RowsFailed = COALESCE(@RowsFailed, RowsFailed)
  WHERE RunId = @RunId;
  IF @@ROWCOUNT <> 1 THROW 51105, ''Izvajanja za zapis stevcev ni.'', 1;
END;');

/* --- 6 — osirotele vrstice dobijo ime ---------------------------------------- */

EXEC(N'CREATE OR ALTER PROCEDURE ops.AbandonOrphanRuns
  @Actor nvarchar(200),
  @ExceptWorkerId nvarchar(200) = NULL,
  @OnlyStale bit = 0
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;

  /* Dva klicatelja, dva namena.

     @OnlyStale = 0  razporejevalnik ob svojem zagonu: nic od prejsnjega procesa ne tece vec,
                     zato gredo vse tuje vrstice Running takoj v Abandoned. Cakanje na urnik
                     bi pomenilo, da sesut tek visi do naslednjega pometanja.
     @OnlyStale = 1  nadzornik med tekom: zapre samo tiste, ki so starejse od StaleAfterSeconds
                     svojega postopka — za primer, ko pade worker in ne razporejevalnik.

     Abandoned je izrecen in ni Failed: "nikoli se ni zaprlo" in "padlo je" sta razlicni
     stvari in zlitje teh dveh je razlog, da tisina izgleda kot zdravje. */
  DECLARE @now datetime2(3) = SYSUTCDATETIME();

  UPDATE run
  SET Status = N''Abandoned'', EndedUtc = @now
  FROM ops.PipelineRun run
  LEFT JOIN ops.ScheduleProfile profile
    ON profile.OrganizationId = run.OrganizationId AND profile.Pipeline = run.Pipeline
  WHERE run.Status = N''Running''
    AND (@ExceptWorkerId IS NULL OR run.WorkerId IS NULL OR run.WorkerId <> @ExceptWorkerId)
    AND (@OnlyStale = 0
         OR run.StartedUtc < DATEADD(second, -COALESCE(profile.StaleAfterSeconds, 3600), @now));

  DECLARE @zaprtih int = @@ROWCOUNT;

  IF @zaprtih > 0
    EXEC ops.LogError
      @Layer = N''Operations'',
      @Severity = N''Warning'',
      @ErrorCode = N''Abandoned'',
      @Message = N''Zaprta izvajanja, ki se niso koncala sama.'',
      @Detail = @Actor;

  SELECT @zaprtih AS ZaprtihIzvajanj;
END;');

/* --- 7 — mrtva tabela gre ven ------------------------------------------------ */

/* ops.Heartbeat je imela 0 vrstic in nobenega pisca; nasledila jo je ops.IntegrationHealth.
   Prazna tabela je past: naslednji, ki jo najde, bo domneval, da nekaj pomeni. Spusti se samo,
   ce je res prazna — ce je vmes kdo zacel pisati vanjo, je to novo dejstvo in ne tiho brisanje.
   Zavito v EXEC, ker bi se ponovni zagon migracije sicer ne prevedel: tabele takrat ni vec. */
IF OBJECT_ID(N'ops.Heartbeat', N'U') IS NOT NULL
  EXEC(N'
    DECLARE @vrstic int;
    SELECT @vrstic = COUNT(*) FROM ops.Heartbeat;
    IF @vrstic > 0 THROW 52142, ''ops.Heartbeat ni prazna; spust bi pobrisal podatke.'', 1;
    DROP TABLE ops.Heartbeat;');

/* --- preverba ---------------------------------------------------------------- */

IF COL_LENGTH(N'ops.PipelineRun', N'WorkerId') IS NULL
  OR COL_LENGTH(N'ops.PipelineRun', N'ExitCode') IS NULL
  OR COL_LENGTH(N'ops.PipelineRun', N'TriggeredBy') IS NULL
  THROW 52143, 'Zgodovina ni dobila vseh stolpcev.', 1;

IF OBJECT_ID(N'ops.RecordRunCounts', N'P') IS NULL OR OBJECT_ID(N'ops.AbandonOrphanRuns', N'P') IS NULL
  THROW 52144, 'Manjka procedura za stevce ali za osirotela izvajanja.', 1;

IF OBJECT_ID(N'ops.Heartbeat', N'U') IS NOT NULL
  THROW 52145, 'ops.Heartbeat ni bila spuscena.', 1;

/* Stanja morajo biti tocno tista iz zaprtega seznama — ne vec in ne manj. */
EXEC(N'
  DECLARE @definicija nvarchar(max);
  SELECT @definicija = definition FROM sys.check_constraints WHERE name = N''CK_PipelineRun_Status'';
  IF @definicija IS NULL THROW 52146, ''Stanja izvajanja niso zaprt seznam.'', 1;
  IF CHARINDEX(N''Abandoned'', @definicija) = 0 OR CHARINDEX(N''TimedOut'', @definicija) = 0
     OR CHARINDEX(N''Warning'', @definicija) = 0
    THROW 52147, ''Zaprt seznam stanj nima novih stanj.'', 1;');
