/*
  152 — odobritev odhodnih sporocil po artiklu, ne po polju; popravek CK_OutboundBatch_Source.

  Uporabnik je na /outbound videl sedem locenih vrstic za en artikel (eno na spremenjeno
  polje) in vsako moral odobriti posebej. Worker (SaopDocumentRunner.ClaimAsync,
  out.ClaimItemDocument) ze zdaj pobere VSA cakajoca/ponovljiva sporocila za en artikel in
  jih poslje kot en XML/API klic — ne glede na to, iz katere seje (OutboundBatchId) so
  prisla. Odobritev je zato edini korak, ki se je se drzal stare, polje-za-polje slike.

  out.ApproveItemDocument/out.CancelItemDocument odobrita oz. preklicheta VSA sporocila
  enega artikla (OrganizationId + EntityType + EntityKey) v enem koraku, po vzoru
  out.ApproveOutboundBatch/out.CancelOutboundBatch (089), le da grupirata po artiklu in ne
  po eni oddajni seji — tocno to je uporabnik zahteval (»po artiklu, ne glede na cas«).

  Bug, najden pri sledenju te poti: ProductCard.razor posilja @Source='CARD' pri vsakem
  navadnem shranjevanju kartice artikla (SaopWrite.EnqueueAsync(..., "CARD", ...)), toda
  CK_OutboundBatch_Source (084) dovoljuje samo SINGLE/BULK/EXCEL. Vsak tak klic bi moral
  pasti na CHECK constraint, preden nastane sploh ena vrstica v out.OutboxMessage — kar bi
  pomenilo, da normalno urejanje artikla na kartici danes SAOP polj sploh ne uvrsti v vrsto.
  Constraint se tu razsiri s CARD.
*/

SET XACT_ABORT ON;

IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_OutboundBatch_Source')
  ALTER TABLE out.OutboundBatch DROP CONSTRAINT CK_OutboundBatch_Source;

ALTER TABLE out.OutboundBatch ADD CONSTRAINT CK_OutboundBatch_Source
  CHECK (Source IN (N'SINGLE', N'BULK', N'EXCEL', N'CARD'));

EXEC(N'
CREATE OR ALTER PROCEDURE out.ApproveItemDocument
  @OrganizationId int, @EntityType nvarchar(100), @EntityKey nvarchar(200), @Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON; BEGIN TRAN;
  UPDATE out.OutboxMessage
  SET Status = N''Pending'', ApprovedUtc = SYSUTCDATETIME(), ApprovedBy = @Actor,
      NextAttemptUtc = SYSUTCDATETIME(), UpdatedUtc = SYSUTCDATETIME()
  WHERE OrganizationId = @OrganizationId AND EntityType = @EntityType AND EntityKey = @EntityKey
    AND Status = N''PendingApproval'';
  DECLARE @Odobrenih int = @@ROWCOUNT;
  IF @Odobrenih = 0 BEGIN ROLLBACK; THROW 51005, N''Za ta artikel ni cakajocih sprememb za odobritev.'', 1; END;
  COMMIT;
  SELECT Odobrenih = @Odobrenih;
END;');

EXEC(N'
CREATE OR ALTER PROCEDURE out.CancelItemDocument
  @OrganizationId int, @EntityType nvarchar(100), @EntityKey nvarchar(200), @Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON; BEGIN TRAN;
  UPDATE out.OutboxMessage
  SET Status = N''Cancelled'', LastError = N''Preklical: '' + @Actor,
      NextAttemptUtc = NULL, UpdatedUtc = SYSUTCDATETIME()
  WHERE OrganizationId = @OrganizationId AND EntityType = @EntityType AND EntityKey = @EntityKey
    AND Status IN (N''PendingApproval'', N''Pending'', N''Error'', N''Retry'');
  DECLARE @Preklicanih int = @@ROWCOUNT;
  IF @Preklicanih = 0 BEGIN ROLLBACK; THROW 51006, N''Za ta artikel ni sporocil, ki bi jih bilo mogoce preklicati.'', 1; END;
  COMMIT;
  SELECT Preklicanih = @Preklicanih;
END;');

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints cc JOIN sys.tables t ON t.object_id = cc.parent_object_id
  WHERE cc.name = N'CK_OutboundBatch_Source' AND cc.definition LIKE N'%CARD%')
  THROW 51484, N'152: CK_OutboundBatch_Source se ne dovoljuje CARD.', 1;
IF OBJECT_ID(N'out.ApproveItemDocument', N'P') IS NULL
  THROW 51485, N'152: out.ApproveItemDocument manjka.', 1;
IF OBJECT_ID(N'out.CancelItemDocument', N'P') IS NULL
  THROW 51486, N'152: out.CancelItemDocument manjka.', 1;
