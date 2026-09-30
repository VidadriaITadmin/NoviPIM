/* 324_PrekliciZahtevoZaZagon — rezervirano za nalogo #69 (razvijalec #69, 2026-09-30 18:23). */
/*
  324 — umik oddane, še ne prevzete ročne zahteve za zagon posla (naloga #69).

  Doslej: »Poženi zdaj« (ops.RequestJobRun, 237) zapiše RequestedRunUtc/RequestedBy in NextDueUtc = zdaj;
  zahteve ni bilo mogoče umakniti, gostitelj jo je prevzel ob naslednjem tiku ali ob naslednjem zagonu
  (npr. izvoz kataloga po preizkusu s testnega intraneta, 29. 9.).

  Zdaj: ops.CancelJobRunRequest @JobKey, @Actor, @NextDueUtc
    - pod UPDLOCK preveri, da posel obstaja (52376), da ne teče (52388) in da zahteva še čaka (52389) —
      gostitelj jo lahko prevzame tik pred klikom, takrat se nič ne spremeni;
    - počisti RequestedRunUtc, RequestedBy (in TriggerSource, razen zagona zaradi predhodnika) in postavi NextDueUtc na @NextDueUtc
      (izračuna intranet: naslednji redni termin po urniku od zdaj; NULL = gostitelj ga izračuna sam);
      RequestJobRun je izvirni termin prepisal, zato ga ni mogoče vrniti;
    - vrne eno vrstico s prejšnjo zahtevo (RequestedBy, RequestedRunUtc) za sled v ops.UserActivity
      (JOB_RUN_REQUEST_CANCEL piše intranet, MonitorService.CancelRunRequestAsync).
  Brez sprememb tabel. Ročni korak: samo uveljavitev migracije.
*/

EXEC(N'CREATE OR ALTER PROCEDURE ops.CancelJobRunRequest
  @JobKey nvarchar(60), @Actor nvarchar(200), @NextDueUtc datetime2 = NULL
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  IF @Actor IS NULL OR LTRIM(RTRIM(@Actor)) = N'''' THROW 52389, N''Manjka uporabnik, ki umika zahtevo.'', 1;

  BEGIN TRANSACTION;
  DECLARE @running bigint, @requestedUtc datetime2, @requestedBy nvarchar(200);
  SELECT @running = RunningJobRunId, @requestedUtc = RequestedRunUtc, @requestedBy = RequestedBy
  FROM ops.JobDefinition WITH (UPDLOCK, HOLDLOCK) WHERE JobKey = @JobKey;
  IF @@ROWCOUNT = 0 THROW 52376, N''Posel ne obstaja.'', 1;
  IF @running IS NOT NULL
    THROW 52388, N''Gostitelj je zahtevo že prevzel in posel teče; tek lahko samo ustaviš.'', 1;
  IF @requestedUtc IS NULL
    THROW 52389, N''Zahteve za zagon ni (več): gostitelj jo je že prevzel ali jo je umaknil kdo drug.'', 1;

  UPDATE ops.JobDefinition
  SET RequestedRunUtc = NULL, RequestedBy = NULL,
      /* zagon, ki ga je sprožil uspeh predhodnika (TriggerSource Dependency:…), ostane: umakne se samo ročna zahteva */
      NextDueUtc = CASE WHEN TriggerSource LIKE N''Dependency:%'' THEN NextDueUtc ELSE @NextDueUtc END,
      TriggerSource = CASE WHEN TriggerSource LIKE N''Dependency:%'' THEN TriggerSource ELSE NULL END
  WHERE JobKey = @JobKey;
  COMMIT TRANSACTION;

  SELECT @requestedBy AS RequestedBy, @requestedUtc AS RequestedRunUtc;
END');

IF OBJECT_ID(N'ops.CancelJobRunRequest', N'P') IS NULL
  THROW 52389, N'324: ops.CancelJobRunRequest ni nastala.', 1;
