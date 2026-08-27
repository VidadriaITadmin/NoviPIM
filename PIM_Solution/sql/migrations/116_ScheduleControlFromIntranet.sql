/*
  115 — urnik se ureja v aplikaciji, ne v razporejevalniku Windows.

  Doslej je bil nadzor razdeljen na dve mesti, ki se nista poznali: ops.ScheduleProfile v bazi
  (kaj sme teci) in nacrtovana opravila Windows (kdaj se sprozi). Uporabnik PIM-a ni imel do
  nobenega dostopa - vklop, izklop in razmik so bili stvar prijave na streznik.

  Po tej migraciji je delitev jasna:

    nacrtovano opravilo Windows   ura, ki tiktaka na 5 minut in nima poslovne vednosti
    ops.ScheduleProfile           ali postopek sme teci in kako pogosto je zares na vrsti

  Ura ostane preprosta nalasc: vsaka sprememba ritma je vrstica v bazi in ne poseg v sistemske
  nastavitve streznika. Uporabnik z vlogo ADMIN jo spremeni na strani /sistem/integracije.

  ops.CompleteRun ze zdaj ob koncu postavi NextScheduledUtc na SYSUTCDATETIME() + IntervalSeconds.
  Ta migracija doda proceduri, ki to vrednost berete in urejate; upostevanje je v workerjih
  (stikalo --po-urniku), da rocni zagon ostane takojsen.
*/

SET XACT_ABORT ON;

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetSchedules
AS
BEGIN
  SET NOCOUNT ON;
  SELECT profile.OrganizationId, organization.Name AS OrganizationName, profile.Provider, profile.Pipeline,
         profile.IsEnabled, profile.IntervalSeconds, profile.StaleAfterSeconds, profile.NextScheduledUtc,
         profile.UpdatedUtc, profile.UpdatedBy,
         health.Status, health.LastHeartbeatUtc, health.LastSuccessfulRunUtc, health.LastFailedRunUtc,
         health.LastErrorRedacted
  FROM ops.ScheduleProfile profile
  INNER JOIN dbo.OrganizationConfig organization ON organization.OrganizationId = profile.OrganizationId
  LEFT JOIN ops.IntegrationHealth health
    ON health.OrganizationId = profile.OrganizationId AND health.Pipeline = profile.Pipeline
  ORDER BY profile.Pipeline, profile.OrganizationId;
END');

EXEC(N'CREATE OR ALTER PROCEDURE intranet.SaveSchedule
  @OrganizationId int, @Pipeline nvarchar(100), @IsEnabled bit, @IntervalSeconds int, @Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  IF @IntervalSeconds < 60 THROW 52811, N''Razmik ne sme biti krajsi od 60 sekund.'', 1;
  IF @IntervalSeconds > 86400 THROW 52812, N''Razmik ne sme biti daljsi od enega dneva.'', 1;

  /* Okno zastalosti mora ostati daljse od razmika, sicer se zagon razglasi za zastalega sam od
     sebe. Uporabnika s tem ne obremenjujemo - izpeljemo ga iz razmika. */
  DECLARE @Stale int = CASE WHEN @IntervalSeconds * 3 < 900 THEN 900 ELSE @IntervalSeconds * 3 END;

  UPDATE ops.ScheduleProfile
  SET IsEnabled = @IsEnabled,
      IntervalSeconds = @IntervalSeconds,
      StaleAfterSeconds = @Stale,
      UpdatedUtc = SYSUTCDATETIME(),
      UpdatedBy = @Actor
  WHERE OrganizationId = @OrganizationId AND Pipeline = @Pipeline;

  IF @@ROWCOUNT = 0 THROW 52813, N''Razpored za to podjetje in postopek ne obstaja.'', 1;
END');

EXEC(N'CREATE OR ALTER PROCEDURE intranet.IsPipelineDue
  @OrganizationId int, @Pipeline nvarchar(100)
AS
BEGIN
  SET NOCOUNT ON;
  /* Vrne 1, kadar postopek sme teci in je na vrsti. Prazen NextScheduledUtc pomeni, da se ni
     tekel nikoli - takrat je na vrsti takoj. */
  SELECT CONVERT(bit, CASE
    WHEN IsEnabled = 0 THEN 0
    WHEN NextScheduledUtc IS NULL THEN 1
    WHEN NextScheduledUtc <= SYSUTCDATETIME() THEN 1
    ELSE 0 END) AS IsDue
  FROM ops.ScheduleProfile
  WHERE OrganizationId = @OrganizationId AND Pipeline = @Pipeline;
END');

/* --- preverba --------------------------------------------------------------- */

IF OBJECT_ID(N'intranet.GetSchedules', N'P') IS NULL THROW 52814, 'intranet.GetSchedules ni nastala.', 1;
IF OBJECT_ID(N'intranet.SaveSchedule', N'P') IS NULL THROW 52815, 'intranet.SaveSchedule ni nastala.', 1;
IF OBJECT_ID(N'intranet.IsPipelineDue', N'P') IS NULL THROW 52816, 'intranet.IsPipelineDue ni nastala.', 1;
