/* 301: stran /outbound nalozi samo sporocila, ki se niso zakljucena.

   Zakaj: intranet.GetOutboundMessages je vracal VSA sporocila podjetja, tudi zgodovino.
   Pri Vidadrii jih je 2026-09-29 50.744; stran jih je nalozila v celoti in sele v C#
   odvrgla zakljucene (Outbound.razor, Terminal). Blazor povezava tega ni zdrzala
   (»Rejoining the server…«), zato cakajocih sprememb (Braytron uvoz, ~1.000 artiklov)
   ni bilo mogoce odobriti.

   Kaj: neobvezen parameter @SamoAktivna (privzeto 0 = kot doslej). Z 1 vrne samo sporocila,
   katerih status ni koncen (Verified, Succeeded, Completed, Cancelled, Superseded) — ista
   mnozica, kot jo Outbound.razor ze doslej prikazuje. Zgodovina, odkloni in pregled SAOP
   klicejo brez parametra in dobijo enako kot prej.

   Stolpci in njihov vrstni red so nespremenjeni (273: Value je 20. stolpec). */
SET XACT_ABORT ON;
SET QUOTED_IDENTIFIER ON;

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetOutboundMessages @OrganizationId int, @SamoAktivna bit = 0
AS
  SELECT OutboxMessageId,TargetKind,Operation,EntityType,EntityKey,FieldSummary,DedupKey,Status,AttemptCount,NextAttemptUtc,
    ResponseStatusCode,ResponseCorrelationId,DriftDetail,CreatedUtc,ApprovedBy,ApprovedUtc,SentUtc,LastError,SaopErrorKind,
    Value=CONVERT(nvarchar(4000),JSON_VALUE(PayloadJson,N''$.value''))
  FROM out.OutboxMessage
  WHERE OrganizationId=@OrganizationId
    AND (@SamoAktivna=0 OR Status NOT IN (N''Verified'',N''Succeeded'',N''Completed'',N''Cancelled'',N''Superseded''))
  ORDER BY CreatedUtc DESC;');

/* --- Dokaz ------------------------------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM sys.parameters WHERE object_id = OBJECT_ID(N'intranet.GetOutboundMessages') AND name = N'@SamoAktivna')
  THROW 53010, N'301: intranet.GetOutboundMessages nima parametra @SamoAktivna.', 1;
IF NOT EXISTS (SELECT 1 FROM sys.dm_exec_describe_first_result_set_for_object(OBJECT_ID(N'intranet.GetOutboundMessages'), 0) WHERE name = N'Value' AND column_ordinal = 20)
  THROW 53011, N'301: intranet.GetOutboundMessages ne vraca poslane vrednosti kot 20. stolpca (273).', 1;
