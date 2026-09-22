/* 256 — zvonec prikazuje samo nova, uporabniku naročena obvestila.
   Odpiranje vrstice jo označi kot prebrano; prikaz že pregledanih vrstic bi zato le polnil seznam
   in povzročal, da se števec ter vsebina zvonca ne ujemata. */
SET XACT_ABORT ON;
SET NOCOUNT ON;

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetRecentAlerts
  @UserKey nvarchar(200),
  @Take int = 5
AS
BEGIN
  SET NOCOUNT ON;
  SELECT TOP (@Take)
         alarm.AlertId, alarm.OrganizationId, podjetje.Name AS OrganizationName,
         alarm.Pipeline, alarm.AlertKind, alarm.Severity, alarm.Title,
         alarm.PayloadSummaryRedacted, alarm.OccurrenceCount,
         alarm.FirstSeenUtc, alarm.LastSeenUtc, alarm.AcknowledgedUtc, alarm.AcknowledgedBy,
         CAST(0 AS bit) AS IsSeen
    FROM ops.Alert alarm
    JOIN dbo.OrganizationConfig podjetje ON podjetje.OrganizationId = alarm.OrganizationId
    LEFT JOIN ops.AlertSeen videno ON videno.AlertId = alarm.AlertId AND videno.UserKey = @UserKey
   WHERE alarm.ResolvedUtc IS NULL
     AND videno.AlertId IS NULL
     AND EXISTS (SELECT 1 FROM intranet.UserAlertSubscription narocnina
                 WHERE narocnina.UserName = @UserKey AND narocnina.AlertKind = alarm.AlertKind)
   ORDER BY CASE alarm.Severity WHEN N''Critical'' THEN 0 WHEN N''Warning'' THEN 1 ELSE 2 END,
            alarm.LastSeenUtc DESC;
END;');

IF OBJECT_ID(N'intranet.GetRecentAlerts', N'P') IS NULL
  THROW 51506, N'256: intranet.GetRecentAlerts manjka.', 1;