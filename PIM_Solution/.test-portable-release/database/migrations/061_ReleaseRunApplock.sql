/*
  061 — zakljucek izvajanja sprosti kljucavnico, ki jo je vzel zacetek.

  Kaj je narobe. ops.BeginRun vzame sys.sp_getapplock z @LockOwner=N'Session' — kljucavnica
  torej zivi na povezavi, ne na transakciji. ops.CompleteRun je posodobil ops.IntegrationHealth
  in ops.ScheduleProfile, kljucavnice pa ni nikoli sprostil. Sprostila se je sele, ko je
  povezava dejansko umrla.

  Zakaj je to pomembno sele zdaj. PIM.Operations.OperationsRun ima svojo SqlConnection, ADO.NET
  pa povezave zbira v bazenu: Dispose povezavo vrne v bazen, ne ubije je, sp_reset_connection pa
  stece sele ob naslednji izposoji. Kljucavnica zato prezivi logicno zapiranje za nedolocen cas.
  Dokler je vsak worker v svojem procesu opravil eno izvajanje in koncal, se to ni videlo.
  PIM.OutboxDispatcher od 70c677f obdela celo cakalno vrsto in se sme zagnati veckrat, zato
  drugi zagon v istem procesu naleti na svojo lastno kljucavnico in dobi
  51101 'Izvajanje za organizacijo in pipeline ze poteka.' — ceprav nic ne tece.

  Izmerjeno 2026-08-22 v eni seji:

    po BeginRun     APPLOCK_MODE = Exclusive
    po CompleteRun  APPLOCK_MODE = Exclusive     <- tu bi moralo biti NoLock

  Kaj naredi ta migracija. ops.CompleteRun sprosti kljucavnico, ki jo drzi njegova seja.
  Sprostitev je pogojna: sp_releaseapplock vrze napako, ce kljucavnice ne drzi ta seja, klicatelj
  pa lahko zakljuci izvajanje z druge povezave, kot ga je zacel. Zato se najprej vprasa
  APPLOCK_MODE in sprosti samo tisto, kar res drzi. Zakljucek izvajanja ne sme pasti zaradi
  kljucavnice — stanje v ops.IntegrationHealth je pomembnejse od nje.

  Sprostitev je zadnja, po obeh posodobitvah: ce bi bila prva, bi drugi zagon lahko zacel
  izvajanje, preden je prvi zapisal svoj izid.

  Kar ta migracija NE spremeni: ops.BeginRun, obseg kljucavnice in nobeno vedenje workerjev.
  Migrator ne pozna locila GO, zato je procedura zavita v EXEC(N'...').
*/

SET XACT_ABORT ON;

EXEC(N'
CREATE OR ALTER PROCEDURE ops.CompleteRun
  @OrganizationId int,@Pipeline nvarchar(100),@RunId uniqueidentifier,@Succeeded bit,@ErrorRedacted nvarchar(2000)=NULL
AS
BEGIN
  SET NOCOUNT ON;
  UPDATE ops.IntegrationHealth SET Status=CASE WHEN @Succeeded=1 THEN N''Healthy'' ELSE N''Failed'' END,
    LastSuccessfulRunUtc=CASE WHEN @Succeeded=1 THEN SYSUTCDATETIME() ELSE LastSuccessfulRunUtc END,
    LastFailedRunUtc=CASE WHEN @Succeeded=0 THEN SYSUTCDATETIME() ELSE LastFailedRunUtc END,
    LastHeartbeatUtc=SYSUTCDATETIME(),LastErrorRedacted=CASE WHEN @Succeeded=0 THEN @ErrorRedacted END,UpdatedUtc=SYSUTCDATETIME()
  WHERE OrganizationId=@OrganizationId AND Pipeline=@Pipeline AND RunId=@RunId;
  IF @@ROWCOUNT<>1 THROW 51103, ''Izvajanja ni mogoce zakljuciti.'', 1;
  UPDATE ops.ScheduleProfile SET NextScheduledUtc=DATEADD(second,IntervalSeconds,SYSUTCDATETIME()) WHERE OrganizationId=@OrganizationId AND Pipeline=@Pipeline;

  /* Kljucavnico vzame ops.BeginRun z @LockOwner=N''Session''; brez tega ostane na povezavi,
     dokler ta ne umre, in naslednji zagon v istem procesu naleti nase. Sprosti se samo tisto,
     kar ta seja res drzi — zakljucek izvajanja ne sme pasti zaradi kljucavnice. */
  DECLARE @Resource nvarchar(255)=CONCAT(N''PIM:ops:'',@OrganizationId,N'':'',@Pipeline);
  IF APPLOCK_MODE(N''public'',@Resource,N''Session'') <> N''NoLock''
    EXEC sys.sp_releaseapplock @Resource=@Resource,@LockOwner=N''Session'',@DbPrincipal=N''public'';
END;');
