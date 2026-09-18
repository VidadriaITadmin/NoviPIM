/*
  138 — varen rocni ponovni poskus neuspelih SAOP sporocil.

  Ponovni poskus ni nov poskus v zgodovini. Ta nastane sele, ko sporocilo znova prevzame
  worker. Zato proceduri ne spreminjata AttemptCount in ne piseta v out.OutboxAttempt;
  sporocilo samo vrneta v Pending ter odstranita LastError in morebitni potekli lease.

  Dovoljena sta izkljucno Error in Dead. Sending bi lahko pomenil dvojno posiljanje, Sent pa
  podvajanje ze izvedene spremembe v ERP, zato posamicna procedura obe stanji izrecno zavrne,
  skupinska pa ju s pogojem UPDATE pusti nedotaknjeni.

  Migrator ne pozna locila GO; procedure so v EXEC(N'...').
*/

SET XACT_ABORT ON;

/* Obstojeci seznam korakov razsirimo brez brisanja stare omejitve. Nova, preverjena omejitev
   varuje celotno tabelo; prvotna se izkljuci, ker sicer ne bi dovolila REQUEUE. */
IF NOT EXISTS
(
  SELECT 1 FROM sys.check_constraints
  WHERE parent_object_id = OBJECT_ID(N'ops.OutboundEvent')
    AND name = N'CK_OutboundEvent_Step_138'
)
  ALTER TABLE ops.OutboundEvent WITH CHECK ADD CONSTRAINT CK_OutboundEvent_Step_138 CHECK
  (
    Step IN (N'Queued', N'Approved', N'Cancelled', N'Sent', N'Verified', N'Drift',
             N'Failed', N'SelfHealed', N'REQUEUE')
  );

IF EXISTS
(
  SELECT 1 FROM sys.check_constraints
  WHERE parent_object_id = OBJECT_ID(N'ops.OutboundEvent')
    AND name = N'CK_OutboundEvent_Step'
    AND is_disabled = 0
)
  ALTER TABLE ops.OutboundEvent NOCHECK CONSTRAINT CK_OutboundEvent_Step;

EXEC(N'
CREATE OR ALTER PROCEDURE out.RequeueOutboxMessage
  @OutboxMessageId bigint,
  @Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  IF NULLIF(LTRIM(RTRIM(@Actor)), N'''') IS NULL
    THROW 52943, ''Ponovni poskus zahteva uporabnika.'', 1;

  BEGIN TRAN;

  DECLARE @OrganizationId int, @OutboundBatchId bigint, @EntityType nvarchar(100),
          @EntityKey nvarchar(450), @FieldName nvarchar(200), @Status nvarchar(30);

  SELECT @OrganizationId = OrganizationId,
         @OutboundBatchId = OutboundBatchId,
         @EntityType = EntityType,
         @EntityKey = EntityKey,
         @FieldName = FieldSummary,
         @Status = Status
  FROM out.OutboxMessage WITH (UPDLOCK, HOLDLOCK)
  WHERE OutboxMessageId = @OutboxMessageId;

  IF @Status IS NULL
  BEGIN
    ROLLBACK;
    THROW 52944, ''Odhodno sporocilo ne obstaja.'', 1;
  END;

  IF @Status NOT IN (N''Error'', N''Dead'')
  BEGIN
    ROLLBACK;
    THROW 52945, ''Ponovni poskus je dovoljen samo za sporocilo v stanju Error ali Dead.'', 1;
  END;

  UPDATE out.OutboxMessage
     SET Status = N''Pending'',
         LastError = NULL,
         NextAttemptUtc = SYSUTCDATETIME(),
         LeaseOwner = NULL,
         LeaseUntilUtc = NULL,
         UpdatedUtc = SYSUTCDATETIME()
   WHERE OutboxMessageId = @OutboxMessageId
     AND Status IN (N''Error'', N''Dead'');

  INSERT ops.OutboundEvent
    (OrganizationId, OutboundBatchId, OutboxMessageId, EntityType, EntityKey,
     Step, Severity, Title, Detail, FieldName, ActorUserName)
  VALUES
    (@OrganizationId, @OutboundBatchId, @OutboxMessageId, @EntityType, @EntityKey,
     N''REQUEUE'', N''INFO'', N''Sporocilo je znova v vrsti za SAOP.'',
     N''Uporabnik je neuspel zapis varno vrnil v cakalno vrsto.'', @FieldName, @Actor);

  IF @OutboundBatchId IS NOT NULL
    UPDATE out.OutboundBatch SET ClosedUtc = NULL WHERE OutboundBatchId = @OutboundBatchId;

  COMMIT;
  SELECT Ponastavljenih = 1;
END;');

EXEC(N'
CREATE OR ALTER PROCEDURE out.RequeueOutboundBatch
  @OutboundBatchId bigint,
  @Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  IF NULLIF(LTRIM(RTRIM(@Actor)), N'''') IS NULL
    THROW 52946, ''Ponovni poskus skupine zahteva uporabnika.'', 1;

  DECLARE @Ponovno TABLE
  (
    OrganizationId int NOT NULL,
    OutboxMessageId bigint NOT NULL,
    EntityType nvarchar(100) NOT NULL,
    EntityKey nvarchar(450) NOT NULL,
    FieldName nvarchar(200) NULL
  );

  BEGIN TRAN;

  UPDATE message WITH (UPDLOCK)
     SET Status = N''Pending'',
         LastError = NULL,
         NextAttemptUtc = SYSUTCDATETIME(),
         LeaseOwner = NULL,
         LeaseUntilUtc = NULL,
         UpdatedUtc = SYSUTCDATETIME()
  OUTPUT inserted.OrganizationId, inserted.OutboxMessageId, inserted.EntityType,
         inserted.EntityKey, LEFT(inserted.FieldSummary, 200)
    INTO @Ponovno(OrganizationId, OutboxMessageId, EntityType, EntityKey, FieldName)
  FROM out.OutboxMessage AS message
  WHERE message.OutboundBatchId = @OutboundBatchId
    AND message.Status IN (N''Error'', N''Dead'');

  DECLARE @Ponastavljenih int = @@ROWCOUNT;

  INSERT ops.OutboundEvent
    (OrganizationId, OutboundBatchId, OutboxMessageId, EntityType, EntityKey,
     Step, Severity, Title, Detail, FieldName, ActorUserName)
  SELECT OrganizationId, @OutboundBatchId, OutboxMessageId, EntityType, EntityKey,
         N''REQUEUE'', N''INFO'', N''Sporocilo je znova v vrsti za SAOP.'',
         N''Uporabnik je neuspel zapis varno vrnil v cakalno vrsto.'', FieldName, @Actor
  FROM @Ponovno;

  IF @Ponastavljenih > 0
    UPDATE out.OutboundBatch SET ClosedUtc = NULL WHERE OutboundBatchId = @OutboundBatchId;

  COMMIT;
  SELECT Ponastavljenih = @Ponastavljenih;
END;');

/* Varovalke migracije: objekt, zaupan seznam korakov in pogoj, ki omejuje spremembo stanja. */
IF OBJECT_ID(N'out.RequeueOutboxMessage', N'P') IS NULL
  THROW 52947, 'Procedura out.RequeueOutboxMessage ni nastala.', 1;

IF OBJECT_ID(N'out.RequeueOutboundBatch', N'P') IS NULL
  THROW 52948, 'Procedura out.RequeueOutboundBatch ni nastala.', 1;

IF NOT EXISTS
(
  SELECT 1 FROM sys.check_constraints
  WHERE parent_object_id = OBJECT_ID(N'ops.OutboundEvent')
    AND name = N'CK_OutboundEvent_Step_138'
    AND is_disabled = 0 AND is_not_trusted = 0
    AND definition LIKE N'%REQUEUE%'
)
  THROW 52949, 'Dogodek REQUEUE ni zasciten s preverjeno omejitvijo.', 1;

IF OBJECT_DEFINITION(OBJECT_ID(N'out.RequeueOutboxMessage')) NOT LIKE N'%Status IN (N''Error'', N''Dead'')%'
  THROW 52950, 'Posamicni ponovni poskus ni omejen na Error in Dead.', 1;

IF OBJECT_DEFINITION(OBJECT_ID(N'out.RequeueOutboundBatch')) NOT LIKE N'%Status IN (N''Error'', N''Dead'')%'
  THROW 52951, 'Skupinski ponovni poskus ni omejen na Error in Dead.', 1;
