/*
  255 — faze znotraj koraka: vsak worker pove, kaj je naredil in koliko.

  David 2026-09-22: »če greva na primer BT_STOCK moram videti da se ta worker izvaja, da se je prenesel
  XML uspešno in da se je dal prebrati in da so se podatki vnesli v tabele.« Doslej je bila najmanjša
  vidna enota korak (ops.JobStepRun = en zagon workerja) z izhodno kodo. Vse vmesno je bilo samo v
  dnevniku, števil pa ni bilo nikjer: ops.RecordRunCounts nima klicatelja, zato so RowsRead/Succeeded
  v ops.PipelineRun vedno prazni.

  Dokaz, zakaj to ni kozmetika (izmerjeno 2026-09-22): zaloga Braytron se ni zapisala od 17. 9.,
  ker prenosa 83-krat ni bilo (»ni na vrsti po razporedu«) oziroma ga je zavrnila omejitev dobavitelja,
  branje pa je vsakič prebralo isto staro datoteko in javilo uspeh. Vsi koraki zeleni, podatki stari
  pet dni.

  Model: posel (ops.JobDefinition) → tek (ops.JobRun) → korak (ops.JobStepRun, en proces workerja)
  → FAZA (ta tabela). Faza je en dejanski posel workerja s številom: Prenos, Branje, Zapis, Ujemanje,
  Preslikava, Mejnik, Datoteka, Izračun, Pošiljanje. Faze piše worker sam, tudi kadar ga požene
  človek iz ukazne vrstice (takrat JobRunId ostane NULL).

  Ključno pravilo: »preskočeno« ni »uspelo«. Faza brez novega dela je Skipped z razlogom, uspeh z
  novimi podatki pa nosi HasNewData = 1. Iz tega se bo računala svežina vira (»podatki stari 5 dni«),
  ne iz izhodne kode.

  Kaj naredi:
    1. ops.JobPhaseRun — ena vrstica na fazo, s števili, sporočilom in povezavami na tek posla
       (JobRunId + StepOrder) in na tek postopka (ops.PipelineRun.RunId).
    2. ops.BeginJobPhase / ops.CompleteJobPhase — worker odpre fazo in jo zapre; obe sta neškodljivi,
       če kdo pošlje nesmisel (poročanje ne sme nikoli podreti zajema podatkov).
    3. ops.SourceFreshness — bralni model: kdaj je posamezen vir zadnjič PRINESEL nove podatke.
    4. intranet.GetJobPhases — faze enega teka posla za stran Nadzor (blok 5).
    5. ops.PurgeJobPhaseRuns — čiščenje starejših od N dni (privzeto 30), da tabela ne raste v nedogled.

  Česa NE naredi: ops.JobStepRun in ops.PipelineRun ostaneta nedotaknjena; nobenega workerja ta
  migracija ne spremeni (to je koda bloka 2 in 3). Šifranta faz namenoma ni v CHECK omejitvi —
  nove vrste faz pridejo skupaj z workerji, omejitev bi zahtevala migracijo za vsako.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

IF OBJECT_ID(N'ops.JobRun', N'U') IS NULL
  THROW 52550, N'255: ops.JobRun ne obstaja (najprej migracija 237).', 1;

/* ── 1. Tabela faz ──────────────────────────────────────────────────────────────── */
IF OBJECT_ID(N'ops.JobPhaseRun', N'U') IS NULL
BEGIN
  CREATE TABLE ops.JobPhaseRun
  (
    JobPhaseRunId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_JobPhaseRun PRIMARY KEY,

    /* Tek posla in korak v njem; NULL, kadar je worker pognal človek iz ukazne vrstice. */
    JobRunId bigint NULL CONSTRAINT FK_JobPhaseRun_JobRun REFERENCES ops.JobRun (JobRunId),
    StepOrder int NULL,

    /* Tek postopka, ki ga je odprl isti worker (ops.BeginRun), da se faza veže na ops.PipelineRun. */
    RunId uniqueidentifier NULL,

    OrganizationId int NULL,
    /* Postopek (SOURCE_FETCH, STOCK_FILE, SAOP_PRODUCTS ...): ista beseda kot v ops.ScheduleProfile. */
    Pipeline nvarchar(100) NULL,
    /* Vir ali predmet faze: BT_STOCK, NW_XML, GetItemsGeneralData, MAGENTO_PRODUCTS ... */
    SourceCode nvarchar(100) NULL,

    /* PRENOS, BRANJE, ZAPIS, UJEMANJE, PRESLIKAVA, MEJNIK, DATOTEKA, IZRACUN, POSILJANJE ... */
    PhaseCode nvarchar(40) NOT NULL,
    /* Vrstni red faze znotraj koraka; worker ga šteje od 1. */
    PhaseOrder int NOT NULL CONSTRAINT DF_JobPhaseRun_PhaseOrder DEFAULT (1),

    Status nvarchar(20) NOT NULL CONSTRAINT DF_JobPhaseRun_Status DEFAULT (N'Running'),
    /* Ali je faza prinesla NOVE podatke. Zelena lučka na strani Nadzor se meri po tem, ne po izhodni kodi. */
    HasNewData bit NOT NULL CONSTRAINT DF_JobPhaseRun_HasNewData DEFAULT (0),

    StartedUtc datetime2(3) NOT NULL CONSTRAINT DF_JobPhaseRun_StartedUtc DEFAULT (SYSUTCDATETIME()),
    EndedUtc datetime2(3) NULL,

    /* Števila; pomen je odvisen od faze (prebrane vrstice, zapisane vrstice, zavrnjene, bajti). */
    ItemsIn bigint NULL,
    ItemsOut bigint NULL,
    ItemsRejected bigint NULL,
    ByteCount bigint NULL,

    /* Stavek za človeka: »dobavitelj dovoli 1x na 3 h, naslednji ob 19:44«, »isti posnetek je že v bazi«. */
    Message nvarchar(1000) NULL,
    WorkerId nvarchar(200) NULL,

    CONSTRAINT CK_JobPhaseRun_Status CHECK (Status IN (N'Running', N'Succeeded', N'Skipped', N'Failed'))
  );
  CREATE INDEX IX_JobPhaseRun_JobRun ON ops.JobPhaseRun (JobRunId, StepOrder, PhaseOrder)
    WHERE JobRunId IS NOT NULL;
  /* Svežina vira: zadnja uspešna faza z novimi podatki po viru in postopku. */
  CREATE INDEX IX_JobPhaseRun_Source ON ops.JobPhaseRun (Pipeline, SourceCode, OrganizationId, StartedUtc DESC)
    INCLUDE (Status, HasNewData, PhaseCode, EndedUtc, ItemsOut);
  CREATE INDEX IX_JobPhaseRun_Started ON ops.JobPhaseRun (StartedUtc);
END;

/* ── 2. Pisanje faz ─────────────────────────────────────────────────────────────── */
/*
  Odpre fazo in vrne njen ključ. Namerno brez preverjanj obstoja teka: če je JobRunId neznan,
  bi tuji ključ padel — zato ga pred vstavljanjem preverimo in po potrebi zavržemo. Poročanje o
  fazah ne sme nikoli podreti zajema podatkov.
*/
EXEC(N'CREATE OR ALTER PROCEDURE ops.BeginJobPhase
  @PhaseCode nvarchar(40), @PhaseOrder int = 1, @JobRunId bigint = NULL, @StepOrder int = NULL,
  @RunId uniqueidentifier = NULL, @OrganizationId int = NULL, @Pipeline nvarchar(100) = NULL,
  @SourceCode nvarchar(100) = NULL, @WorkerId nvarchar(200) = NULL, @Message nvarchar(1000) = NULL,
  @JobPhaseRunId bigint OUTPUT
AS
BEGIN
  SET NOCOUNT ON;
  IF @JobRunId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM ops.JobRun WHERE JobRunId = @JobRunId)
    SET @JobRunId = NULL;

  INSERT ops.JobPhaseRun (JobRunId, StepOrder, RunId, OrganizationId, Pipeline, SourceCode,
                          PhaseCode, PhaseOrder, Status, StartedUtc, Message, WorkerId)
  VALUES (@JobRunId, @StepOrder, @RunId, @OrganizationId, @Pipeline, @SourceCode,
          @PhaseCode, COALESCE(@PhaseOrder, 1), N''Running'', SYSUTCDATETIME(), @Message, @WorkerId);

  SET @JobPhaseRunId = SCOPE_IDENTITY();
END');

/*
  Zapre fazo. Status je eden od Succeeded, Skipped, Failed; karkoli drugega velja za Failed, da
  napaka nikoli ne izpade kot uspeh. @HasNewData pove, ali so prišli novi podatki (Skipped je
  vedno brez).
*/
EXEC(N'CREATE OR ALTER PROCEDURE ops.CompleteJobPhase
  @JobPhaseRunId bigint, @Status nvarchar(20), @HasNewData bit = 0,
  @ItemsIn bigint = NULL, @ItemsOut bigint = NULL, @ItemsRejected bigint = NULL, @ByteCount bigint = NULL,
  @Message nvarchar(1000) = NULL, @RunId uniqueidentifier = NULL
AS
BEGIN
  SET NOCOUNT ON;
  IF @Status NOT IN (N''Succeeded'', N''Skipped'', N''Failed'') SET @Status = N''Failed'';

  UPDATE ops.JobPhaseRun
  SET Status = @Status,
      HasNewData = CASE WHEN @Status = N''Succeeded'' THEN COALESCE(@HasNewData, CONVERT(bit, 0)) ELSE CONVERT(bit, 0) END,
      EndedUtc = SYSUTCDATETIME(),
      ItemsIn = COALESCE(@ItemsIn, ItemsIn),
      ItemsOut = COALESCE(@ItemsOut, ItemsOut),
      ItemsRejected = COALESCE(@ItemsRejected, ItemsRejected),
      ByteCount = COALESCE(@ByteCount, ByteCount),
      Message = COALESCE(@Message, Message),
      RunId = COALESCE(@RunId, RunId)
  WHERE JobPhaseRunId = @JobPhaseRunId;
END');

/* ── 3. Svežina vira ────────────────────────────────────────────────────────────── */
/*
  Kdaj je vir zadnjič prinesel nove podatke in kdaj je bil nazadnje sploh preverjen. To je merilo
  za rdečo lučko na strani Nadzor: »Braytron zaloga: podatki stari 5 dni«. Zadnja napaka je zraven,
  da stran ne potrebuje druge poizvedbe.
*/
EXEC(N'CREATE OR ALTER PROCEDURE ops.SourceFreshness
  @Pipeline nvarchar(100) = NULL, @SourceCode nvarchar(100) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SELECT Pipeline, SourceCode, OrganizationId,
         LastNewDataUtc = MAX(CASE WHEN Status = N''Succeeded'' AND HasNewData = 1 THEN COALESCE(EndedUtc, StartedUtc) END),
         LastCheckedUtc = MAX(COALESCE(EndedUtc, StartedUtc)),
         LastFailureUtc = MAX(CASE WHEN Status = N''Failed'' THEN COALESCE(EndedUtc, StartedUtc) END),
         LastItemsOut = MAX(CASE WHEN Status = N''Succeeded'' AND HasNewData = 1 THEN ItemsOut END),
         Phases = COUNT(*)
  FROM ops.JobPhaseRun
  WHERE (@Pipeline IS NULL OR Pipeline = @Pipeline)
    AND (@SourceCode IS NULL OR SourceCode = @SourceCode)
  GROUP BY Pipeline, SourceCode, OrganizationId;
END');

/* ── 4. Faze enega teka (stran Nadzor) ──────────────────────────────────────────── */
EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetJobPhases @JobRunId bigint
AS
BEGIN
  SET NOCOUNT ON;
  SELECT phase.JobPhaseRunId, phase.StepOrder, step.StepName, phase.PhaseCode, phase.PhaseOrder,
         phase.OrganizationId, organizationValue.Name AS OrganizationName, phase.Pipeline, phase.SourceCode,
         phase.Status, phase.HasNewData, phase.StartedUtc, phase.EndedUtc,
         DurationMs = CASE WHEN phase.EndedUtc IS NULL THEN NULL ELSE DATEDIFF(millisecond, phase.StartedUtc, phase.EndedUtc) END,
         phase.ItemsIn, phase.ItemsOut, phase.ItemsRejected, phase.ByteCount, phase.Message, phase.RunId
  FROM ops.JobPhaseRun phase
  LEFT JOIN ops.JobStepRun step ON step.JobRunId = phase.JobRunId AND step.StepOrder = phase.StepOrder
  LEFT JOIN dbo.OrganizationConfig organizationValue ON organizationValue.OrganizationId = phase.OrganizationId
  WHERE phase.JobRunId = @JobRunId
  ORDER BY phase.StepOrder, phase.PhaseOrder, phase.JobPhaseRunId;
END');

/* ── 5. Čiščenje ────────────────────────────────────────────────────────────────── */
EXEC(N'CREATE OR ALTER PROCEDURE ops.PurgeJobPhaseRuns @KeepDays int = 30, @MaxRows int = 100000
AS
BEGIN
  SET NOCOUNT ON;
  DECLARE @cut datetime2(3) = DATEADD(day, -ABS(COALESCE(@KeepDays, 30)), SYSUTCDATETIME());
  DELETE TOP (COALESCE(@MaxRows, 100000)) FROM ops.JobPhaseRun WHERE StartedUtc < @cut;
  RETURN @@ROWCOUNT;
END');

/* ── Preverjanje ────────────────────────────────────────────────────────────────── */
IF OBJECT_ID(N'ops.JobPhaseRun', N'U') IS NULL
   OR OBJECT_ID(N'ops.BeginJobPhase', N'P') IS NULL
   OR OBJECT_ID(N'ops.CompleteJobPhase', N'P') IS NULL
   OR OBJECT_ID(N'ops.SourceFreshness', N'P') IS NULL
   OR OBJECT_ID(N'intranet.GetJobPhases', N'P') IS NULL
   OR OBJECT_ID(N'ops.PurgeJobPhaseRuns', N'P') IS NULL
  THROW 52551, N'255: faze korakov niso nameščene.', 1;
