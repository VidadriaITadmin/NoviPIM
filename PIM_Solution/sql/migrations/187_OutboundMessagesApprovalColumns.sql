/*
  187 — intranet.GetOutboundMessages doda ApprovedBy/ApprovedUtc/SentUtc.

  Uporabnik je na /saop/zgodovina videl »Odobril« in »Poslano« vedno kot »—«, ceprav ju
  out.OutboxMessage ze hrani: ApprovedUtc/ApprovedBy pise out.ApproveMessage/ApproveItemDocument
  (021/152), SentUtc pise out.MarkMessageResult (021). Razlog je bil ozek SELECT v tej proceduri,
  ne manjkajoc bralni model — PimMissing na /saop/zgodovina je zato govoril napacno.

  Kar se s tem ne popravi (in ostaja za PimMissing): stara/nova vrednost polja ob spremembi in
  razclenitev po poskusih iz out.OutboxAttempt — za oboje bi bil potreben nov klic na artikel/
  sporocilo, ne le sirsi SELECT na seznamu. intranet.GetOutboundMessage (ednina, po
  OutboxMessageId) to razclenitev ze vraca, a ni se povezana z nobeno stranjo.
*/

SET XACT_ABORT ON;

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetOutboundMessages @OrganizationId int
AS
  SELECT OutboxMessageId,TargetKind,Operation,EntityType,EntityKey,FieldSummary,DedupKey,Status,AttemptCount,NextAttemptUtc,
    ResponseStatusCode,ResponseCorrelationId,DriftDetail,CreatedUtc,ApprovedBy,ApprovedUtc,SentUtc
  FROM out.OutboxMessage WHERE OrganizationId=@OrganizationId ORDER BY CreatedUtc DESC;');

IF OBJECT_ID(N'intranet.GetOutboundMessages', N'P') IS NULL
  THROW 51487, N'187: intranet.GetOutboundMessages manjka.', 1;
IF NOT EXISTS (SELECT 1 FROM sys.dm_exec_describe_first_result_set_for_object(OBJECT_ID(N'intranet.GetOutboundMessages'), 0) WHERE name = N'ApprovedBy')
  THROW 51488, N'187: intranet.GetOutboundMessages ne vraca ApprovedBy.', 1;
