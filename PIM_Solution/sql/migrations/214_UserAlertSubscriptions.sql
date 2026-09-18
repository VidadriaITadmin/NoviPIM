/*
  214 — Osebna obvestila: katero vrsto sistemskega alarma (ops.Alert.AlertKind) prejema kateri
  uporabnik.

  Zvonec v glavi (MainLayout, migracija 188) je bil doslej samo skrbnikov in je kazal VSE odprte
  alarme ne glede na vrsto. Uporabnik je 2026-09-15 zahteval, da uporabniki sami vidijo in
  odpravljajo svoja obvestila, admin pa na strani Uporabniki s kljukicami doloci, katere vrste
  alarmov posamezen uporabnik sploh dobiva.

  intranet.GetRecentAlerts zdaj filtrira po narocnini v novi tabeli. Obstojeci skrbniki so ob tej
  migraciji zacetno narocni na vseh sedem znanih vrst (glej CK_UserAlertSubscription_Kind), da se
  jim seznam v zvoncu ne skrci — vseh sedem je edinih vrst, ki jih ops.UpsertAlert/RunWatchdog
  (025) in kasnejse migracije (090, 119/120, 187/188) sploh kdaj vpisejo.
*/

SET XACT_ABORT ON;

IF OBJECT_ID(N'intranet.UserAlertSubscription', N'U') IS NULL
BEGIN
  CREATE TABLE intranet.UserAlertSubscription
  (
    UserName nvarchar(100) NOT NULL,
    AlertKind nvarchar(50) NOT NULL,
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_UserAlertSubscription_UpdatedUtc DEFAULT SYSUTCDATETIME(),
    UpdatedBy nvarchar(200) NOT NULL,
    CONSTRAINT PK_UserAlertSubscription PRIMARY KEY (UserName, AlertKind),
    CONSTRAINT FK_UserAlertSubscription_User FOREIGN KEY (UserName) REFERENCES sec.LocalUser (UserName),
    CONSTRAINT CK_UserAlertSubscription_Kind CHECK (AlertKind IN (
      N'StaleHeartbeat', N'OutboundDead', N'OutboundDrift', N'StalledWatermark',
      N'PipelineDisabled', N'ReservationExcluded', N'OutboundUnacknowledged'))
  );
END;

/* Obstojeci skrbniki: brez tega bi jim ta migracija izpraznila zvonec, ki je prej kazal vse. */
INSERT intranet.UserAlertSubscription (UserName, AlertKind, UpdatedBy)
SELECT localUser.UserName, kind.AlertKind, N'214_UserAlertSubscriptions'
FROM sec.LocalUser localUser
INNER JOIN sec.LocalUserRole userRole ON userRole.LocalUserId = localUser.LocalUserId
INNER JOIN sec.Role roleValue ON roleValue.RoleId = userRole.RoleId AND roleValue.RoleCode = N'ADMIN'
CROSS JOIN (VALUES
  (N'StaleHeartbeat'), (N'OutboundDead'), (N'OutboundDrift'), (N'StalledWatermark'),
  (N'PipelineDisabled'), (N'ReservationExcluded'), (N'OutboundUnacknowledged')) AS kind(AlertKind)
WHERE NOT EXISTS (
  SELECT 1 FROM intranet.UserAlertSubscription existing
  WHERE existing.UserName = localUser.UserName AND existing.AlertKind = kind.AlertKind);

/* Ena kljukica na strani Uporabniki = en klic: vklopi ali izklopi eno vrsto za enega uporabnika. */
EXEC(N'CREATE OR ALTER PROCEDURE intranet.SetUserAlertSubscription
  @UserName nvarchar(100),
  @AlertKind nvarchar(50),
  @IsEnabled bit,
  @Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  IF @IsEnabled = 1
    INSERT intranet.UserAlertSubscription (UserName, AlertKind, UpdatedBy)
    SELECT @UserName, @AlertKind, @Actor
     WHERE NOT EXISTS (SELECT 1 FROM intranet.UserAlertSubscription existing
                        WHERE existing.UserName = @UserName AND existing.AlertKind = @AlertKind);
  ELSE
    DELETE FROM intranet.UserAlertSubscription WHERE UserName = @UserName AND AlertKind = @AlertKind;
END;');

/* 188: zvonec zdaj kaze samo vrste alarmov, na katere je uporabnik narocen — prej vse odprte. */
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
     AND EXISTS (SELECT 1 FROM intranet.UserAlertSubscription sub
                 WHERE sub.UserName = @UserKey AND sub.AlertKind = alarm.AlertKind)
   ORDER BY CASE alarm.Severity WHEN N''Critical'' THEN 0 WHEN N''Warning'' THEN 1 ELSE 2 END,
            alarm.LastSeenUtc DESC;
END;');

IF OBJECT_ID(N'intranet.UserAlertSubscription', N'U') IS NULL
  THROW 51488, N'214: intranet.UserAlertSubscription manjka.', 1;
IF OBJECT_ID(N'intranet.SetUserAlertSubscription', N'P') IS NULL
  THROW 51488, N'214: intranet.SetUserAlertSubscription manjka.', 1;
IF OBJECT_ID(N'intranet.GetRecentAlerts', N'P') IS NULL
  THROW 51488, N'214: intranet.GetRecentAlerts manjka.', 1;
