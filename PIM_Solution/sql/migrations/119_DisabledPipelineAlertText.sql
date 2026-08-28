/*
  119 — alarm ob samodejnem izklopu mora nositi ime postopka, podjetje in napako.

  Migracija 118 je klicala ops.UpsertAlert z NULL za DedupKey, Title in povzetek. Ti parametri
  nimajo privzetkov in ustrezni stolpci v ops.Alert niso NULL-abilni, zato bi izklop padel prav
  v trenutku, ko je najbolj potreben. Tu se popravi besedilo alarma.

  Kaj mora clovek iz alarma izvedeti brez odpiranja baze: kateri postopek, katero podjetje,
  koliko zaporednih napak in kaj je pisalo v zadnji. DedupKey je (podjetje, postopek), zato
  ponovni izklop istega postopka poveca stevec pojavitev in ne ustvari drugega alarma.
*/

SET XACT_ABORT ON;

EXEC(N'
CREATE OR ALTER PROCEDURE ops.DisablePipelineAfterFailures
  @OrganizationId int, @Pipeline nvarchar(100), @Failures int, @ErrorRedacted nvarchar(2000)
AS
BEGIN
  SET NOCOUNT ON;

  DECLARE @Ime nvarchar(200) = (SELECT Name FROM dbo.OrganizationConfig WHERE OrganizationId=@OrganizationId);

  UPDATE ops.ScheduleProfile
  SET IsEnabled=0, UpdatedUtc=SYSUTCDATETIME(), UpdatedBy=N''samodejni izklop po napakah''
  WHERE OrganizationId=@OrganizationId AND Pipeline=@Pipeline AND IsEnabled=1;

  DECLARE @Naslov nvarchar(300) = CONCAT(N''Postopek '', @Pipeline, N'' je ustavljen po '', @Failures, N'' zaporednih napakah'');
  DECLARE @Povzetek nvarchar(2000) = CONCAT(
    N''Podjetje: '', COALESCE(@Ime, CONVERT(nvarchar(20), @OrganizationId)),
    N''. Postopek: '', @Pipeline,
    N''. Zaporednih napak: '', @Failures,
    N''. Zadnja napaka: '', COALESCE(NULLIF(@ErrorRedacted, N''''), N''(brez sporocila)''),
    N''. Postopek je izklopljen; ko je vzrok odpravljen, ga vklopi na /sistem/urniki.'');

  EXEC ops.UpsertAlert
    @OrganizationId=@OrganizationId,
    @Pipeline=@Pipeline,
    @AlertKind=N''PipelineDisabled'',
    @Severity=N''Critical'',
    @DedupKey=NULL,
    @Title=@Naslov,
    @PayloadSummaryRedacted=@Povzetek,
    @Actor=N''ops.CompleteRun'';
END;');

EXEC(N'
CREATE OR ALTER PROCEDURE ops.CompleteRun
  @OrganizationId int,@Pipeline nvarchar(100),@RunId uniqueidentifier,@Succeeded bit,@ErrorRedacted nvarchar(2000)=NULL
AS
BEGIN
  SET NOCOUNT ON;

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
      EXEC ops.DisablePipelineAfterFailures @OrganizationId, @Pipeline, @Failures, @ErrorRedacted;
  END;

  DECLARE @Resource nvarchar(255)=CONCAT(N''PIM:ops:'',@OrganizationId,N'':'',@Pipeline);
  IF APPLOCK_MODE(N''public'',@Resource,N''Session'') <> N''NoLock''
    EXEC sys.sp_releaseapplock @Resource=@Resource,@LockOwner=N''Session'',@DbPrincipal=N''public'';
END;');

IF OBJECT_ID(N'ops.DisablePipelineAfterFailures', N'P') IS NULL
  THROW 52819, 'ops.DisablePipelineAfterFailures ni nastala.', 1;
