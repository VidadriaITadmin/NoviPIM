/*
  120 — alarm ob samodejnem izklopu potrebuje svoj kljuc za zdruzevanje.

  Migracija 119 je klicala ops.UpsertAlert z @DedupKey=NULL v prepricanju, da ga procedura
  izracuna sama. Ne izracuna ga: ops.Alert.DedupKey je NOT NULL in vstavljanje je padlo z
  "Cannot insert the value NULL into column DedupKey". Postopek se je torej izklopil, alarma pa
  ni bilo - najslabsi mozni izid, ker se sistem tiho ustavi.

  Izmerjeno pri preizkusu 28. 8. 2026: po petih napakah je IsEnabled padel na 0, ops.Alert pa je
  ostal prazen.

  Kljuc je zgoscena vrednost para (podjetje, postopek). Tako drugi izklop istega postopka poveca
  stevec pojavitev na obstojecem alarmu namesto da bi nastal nov, dva razlicna postopka pa imata
  vsak svojega.
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

  DECLARE @Kljuc varchar(64) = CONVERT(varchar(64),
    HASHBYTES(N''SHA2_256'', CONCAT(N''PipelineDisabled:'', @OrganizationId, N'':'', @Pipeline)), 2);

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
    @DedupKey=@Kljuc,
    @Title=@Naslov,
    @PayloadSummaryRedacted=@Povzetek,
    @Actor=N''ops.CompleteRun'';
END;');
