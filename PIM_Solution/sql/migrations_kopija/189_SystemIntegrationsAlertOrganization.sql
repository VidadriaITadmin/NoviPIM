/*
  189 — opozorila na /sistem/integracije nosijo svojo organizacijo.

  Zahteva uporabnika 2026-09-10: stran /sistem/integracije je pokazala samo en alarm
  "Izlocitve iz rezervacije zaloge" (DEMO, 11), namesto vseh stirih (DEMO, IQLighting,
  Vidadria, Ediito). Vzrok je isti kot pri Nadzorni plosci pred to (glej komentar uporabnika
  2026-08-28 v Dashboard.razor: "te stevilke kazejo samo DEMO podjetje, morajo pa kazati
  celotno tabelo") — stran uporablja Data.GetCurrentOrganizationAsync, ki vedno vrne prvo
  podjetje po sifri (DEMO), ne pa izbiro uporabnika ali vsa podjetja.

  Dashboard.razor je to ze resil: klice intranet.GetSystemIntegrations enkrat na podjetje in
  sestavi rezultat (glej migracija 183, opomba "Plosca postopek klice enkrat na podjetje").
  Ista pot je prava tudi tu — SystemIntegrations.razor bo popravljen na strani C#, da naredi
  isto. Manjka pa mu en podatek, ki ga Dashboard ne rabi (ker alarmov sam ne prikazuje po
  organizaciji): opozorila danes NE nosijo OrganizationId, zato jih po zdruzitvi vec klicev ni
  mogoce lociti niti prikazati, kateri organizaciji pripadajo, niti pravilno potrditi/resiti
  (intranet.AcknowledgeAlert/ResolveAlert oba zahtevata @OrganizationId).

  Ta migracija samo doda OrganizationId (in ime organizacije) v drugi rezultat
  intranet.GetSystemIntegrations. Nič drugega se ne spremeni — isti filter, isti vrstni red.
*/

SET XACT_ABORT ON;

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetSystemIntegrations @OrganizationId int
AS
  SELECT profile.OrganizationId,organization.Name AS OrganizationCode,profile.Provider,profile.Pipeline,profile.IsEnabled,health.Status,health.LastHeartbeatUtc,health.LastSuccessfulRunUtc,health.LastFailedRunUtc,health.WatermarkUtc,profile.NextScheduledUtc,
    (SELECT COUNT(*) FROM ops.Alert alert WHERE alert.OrganizationId=profile.OrganizationId AND alert.Pipeline=profile.Pipeline AND alert.ResolvedUtc IS NULL) OpenAlerts,
    (SELECT COUNT(*) FROM out.OutboxMessage message WHERE message.OrganizationId=profile.OrganizationId AND message.Status=N''Dead'') OutboxDeadCount,
    (SELECT COUNT(*) FROM out.OutboxMessage message WHERE message.OrganizationId=profile.OrganizationId AND message.Status=N''Drift'') OutboxDriftCount
  FROM ops.ScheduleProfile profile INNER JOIN dbo.OrganizationConfig organization ON organization.OrganizationId=profile.OrganizationId
  LEFT JOIN ops.IntegrationHealth health ON health.OrganizationId=profile.OrganizationId AND health.Pipeline=profile.Pipeline
  WHERE profile.OrganizationId=@OrganizationId ORDER BY profile.Provider,profile.Pipeline;
  SELECT alert.AlertId,alert.OrganizationId,organization.Name AS OrganizationName,alert.Pipeline,alert.AlertKind,alert.Severity,alert.Title,alert.PayloadSummaryRedacted,alert.OccurrenceCount,alert.FirstSeenUtc,alert.LastSeenUtc,alert.AcknowledgedUtc,alert.AcknowledgedBy,alert.ResolvedUtc,alert.ResolvedBy
  FROM ops.Alert alert INNER JOIN dbo.OrganizationConfig organization ON organization.OrganizationId=alert.OrganizationId
  WHERE alert.OrganizationId=@OrganizationId ORDER BY CASE alert.Severity WHEN N''Critical'' THEN 0 WHEN N''Warning'' THEN 1 ELSE 2 END,alert.LastSeenUtc DESC;');

/* --- Preverbe -------------------------------------------------------------------------- */

IF NOT EXISTS
(
  SELECT 1 FROM sys.sql_modules
  WHERE object_id = OBJECT_ID(N'intranet.GetSystemIntegrations') AND definition LIKE N'%alert.OrganizationId%'
    AND definition LIKE N'%OrganizationName%'
)
  THROW 52995, 'intranet.GetSystemIntegrations se ne vrne organizacije ob vsakem opozorilu.', 1;
