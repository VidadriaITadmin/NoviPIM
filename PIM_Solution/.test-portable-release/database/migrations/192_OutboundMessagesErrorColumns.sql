/*
  192 — intranet.GetOutboundMessages doda LastError/SaopErrorKind.

  Uporabnik je vprasal: ce SAOP zavrne dokument, ali se to pokaze kot Error in ali uporabnik
  vidi razlog? Status se je ze prej pravilno postavil (out.CompleteItemDocument/out.CompleteMessage
  piseta Status, LastError, SaopErrorKind na out.OutboxMessage), samo ta procedura (in s tem
  Cakalna vrsta/Zgodovina) teh dveh stolpcev ni brala — enak vzorec kot 187 (ApprovedBy/SentUtc).
*/

SET XACT_ABORT ON;

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetOutboundMessages @OrganizationId int
AS
  SELECT OutboxMessageId,TargetKind,Operation,EntityType,EntityKey,FieldSummary,DedupKey,Status,AttemptCount,NextAttemptUtc,
    ResponseStatusCode,ResponseCorrelationId,DriftDetail,CreatedUtc,ApprovedBy,ApprovedUtc,SentUtc,LastError,SaopErrorKind
  FROM out.OutboxMessage WHERE OrganizationId=@OrganizationId ORDER BY CreatedUtc DESC;');

IF OBJECT_ID(N'intranet.GetOutboundMessages', N'P') IS NULL
  THROW 51489, N'192: intranet.GetOutboundMessages manjka.', 1;
IF NOT EXISTS (SELECT 1 FROM sys.dm_exec_describe_first_result_set_for_object(OBJECT_ID(N'intranet.GetOutboundMessages'), 0) WHERE name = N'LastError')
  THROW 51490, N'192: intranet.GetOutboundMessages ne vraca LastError.', 1;
