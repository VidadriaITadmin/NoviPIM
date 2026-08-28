/*
  117 — pet zaporednih napak ustavi postopek in o tem obvesti.

  Izmerjeno 28. 8. 2026 zjutraj: SAOP je bil nedosegljiv (izklopljen VPN) in petminutni cikel je
  padel 18-krat zapored. Vsak zagon je cakal stiri podjetja krat priblizno 21 sekund iztecnega
  casa; pri 288 ciklih na dan je to skoraj sedem ur praznega cakanja. O tem ni izvedel nihce:
  ALERT_DISPATCH in WATCHDOG imata razpored, a LastSuccessfulRunUtc je bil pri obeh NULL.

  Pravilo, ki ga uvaja ta migracija:

    napaka 1-4   postopek ostane vklopljen in poskusi znova ob naslednjem terminu
    napaka 5     postopek se IZKLOPI (IsEnabled = 0) in nastane alarm z imenom postopka,
                 podjetjem in zadnjo napako
    uspeh        stevec se postavi na nic

  Zakaj izklop in ne samo alarm. Ponavljanje klica, ki 18-krat zapored ni uspel, ne prinese
  nicesar - okvara je zunaj nas (omrezje, poverilnice, izpad ERP) in se ne popravi sama. Izklop
  je jasno stanje: na /sistem/urniki se vidi, kaj je ustavljeno in zakaj, in clovek ga vklopi z
  enim gumbom, ko je vzrok odpravljen.

  NextScheduledUtc se odslej racuna od ZACETKA teka, ne od konca. Doslej je bil ritem
  "konec + razmik": tek, ki traja stiri minute, je pri razmiku petih minut dejansko tekel na
  devet. Zacetek teka je v ops.IntegrationHealth.LastHeartbeatUtc ob BeginRun, zato ga vzamemo
  od tam; ce ga ni, pade nazaj na trenutni cas.

  Prag je nastavljiv na postopek: stolpec MaxConsecutiveFailures. Nic ali NULL pomeni "nikoli ne
  izklopi" - to je smiselno za WATCHDOG, ki mora tudi ob napakah ostati ziv, sicer ne bi imel kdo
  povedati, da je nekaj narobe.
*/

SET XACT_ABORT ON;

IF COL_LENGTH(N'ops.IntegrationHealth', N'ConsecutiveFailures') IS NULL
  ALTER TABLE ops.IntegrationHealth ADD ConsecutiveFailures int NOT NULL CONSTRAINT DF_IntegrationHealth_ConsecutiveFailures DEFAULT (0);

IF COL_LENGTH(N'ops.ScheduleProfile', N'MaxConsecutiveFailures') IS NULL
  ALTER TABLE ops.ScheduleProfile ADD MaxConsecutiveFailures int NULL;

EXEC sp_executesql N'
  UPDATE ops.ScheduleProfile SET MaxConsecutiveFailures = 5 WHERE Pipeline <> N''WATCHDOG'';
  UPDATE ops.ScheduleProfile SET MaxConsecutiveFailures = NULL WHERE Pipeline = N''WATCHDOG'';';

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
    DECLARE @Failures int, @Prag int, @Ime nvarchar(200);
    SELECT @Failures = health.ConsecutiveFailures, @Prag = profile.MaxConsecutiveFailures
    FROM ops.IntegrationHealth health
    INNER JOIN ops.ScheduleProfile profile
      ON profile.OrganizationId=health.OrganizationId AND profile.Pipeline=health.Pipeline
    WHERE health.OrganizationId=@OrganizationId AND health.Pipeline=@Pipeline;

    IF @Prag IS NOT NULL AND @Prag > 0 AND @Failures >= @Prag
    BEGIN
      SELECT @Ime = Name FROM dbo.OrganizationConfig WHERE OrganizationId=@OrganizationId;

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

/* --- preverba --------------------------------------------------------------- */

IF COL_LENGTH(N'ops.IntegrationHealth', N'ConsecutiveFailures') IS NULL
  THROW 52817, 'Stevec zaporednih napak ni nastal.', 1;

EXEC sp_executesql N'
  IF EXISTS (SELECT 1 FROM ops.ScheduleProfile WHERE Pipeline <> N''WATCHDOG'' AND MaxConsecutiveFailures IS NULL)
    THROW 52818, ''Vsak postopek razen nadzornika mora imeti prag napak.'', 1;';
