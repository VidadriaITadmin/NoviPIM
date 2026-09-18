/*
  188 — zvonec v glavi: zadnjih N obvestil in oznaka "prebrano" za eno samo.

  Zvonec je doslej vodil naravnost na /sistem/integracije, ne da bi skrbnik videl, katera
  obvestila sploh caka. intranet.GetAdminPulse (172) ze vraca odprte alarme z IsSeen, a v enem
  klicu z urniki, samotestom in katalogom — predrago za majhen spustni seznam v glavi vsake
  strani. intranet.MarkAlertsSeen (172) obstaja samo v mnozinski obliki (vse naenkrat); klik na
  "prebrano" pri enem obvestilu potrebuje ozji zapis, ki ne pobrise preostalih.
*/

SET XACT_ABORT ON;

/* Zadnjih @Take odprtih alarmov, enako razvrscenih kot v GetAdminPulse (resnost, nato svezina). */
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
         CAST(CASE WHEN videno.AlertId IS NULL THEN 0 ELSE 1 END AS bit) AS IsSeen
    FROM ops.Alert alarm
    JOIN dbo.OrganizationConfig podjetje ON podjetje.OrganizationId = alarm.OrganizationId
    LEFT JOIN ops.AlertSeen videno ON videno.AlertId = alarm.AlertId AND videno.UserKey = @UserKey
   WHERE alarm.ResolvedUtc IS NULL
   ORDER BY CASE alarm.Severity WHEN N''Critical'' THEN 0 WHEN N''Warning'' THEN 1 ELSE 2 END,
            alarm.LastSeenUtc DESC;
END;');

/* Enojna razlicica intranet.MarkAlertsSeen (172): oznaci samo eno obvestilo za tega skrbnika. */
EXEC(N'CREATE OR ALTER PROCEDURE intranet.MarkAlertSeen
  @UserKey nvarchar(200),
  @AlertId bigint
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  INSERT ops.AlertSeen (UserKey, AlertId)
  SELECT @UserKey, @AlertId
   WHERE NOT EXISTS (SELECT 1 FROM ops.AlertSeen seen WHERE seen.UserKey = @UserKey AND seen.AlertId = @AlertId);
END;');

IF OBJECT_ID(N'intranet.GetRecentAlerts', N'P') IS NULL
  THROW 51488, N'188: intranet.GetRecentAlerts manjka.', 1;
IF OBJECT_ID(N'intranet.MarkAlertSeen', N'P') IS NULL
  THROW 51488, N'188: intranet.MarkAlertSeen manjka.', 1;
