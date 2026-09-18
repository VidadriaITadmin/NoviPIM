/*
  224 — En racun, ena ziva seja. Doslej se je lahko isti racun prijavil na poljubno stevilo
  naprav hkrati, popolnoma tiho — nobena stran ni vedela za drugo. Prijava zdaj zazna, da je
  racun ze aktiven drugje, in ponudi prevzem seje namesto tihega podvajanja.

  LastSeenUtc: sec.GetUserSecurityState se ze klice na vsako preverjeno zahtevo
  (PimSessionValidator, migracija 181) — ista poizvedba zdaj mimogrede osvezi tudi "zadnjic
  viden", brez dodatnega klica v bazo. Pisanje je omejeno na najvec enkrat na 60 sekund na
  uporabnika, da hitro klikanje po straneh ne obremeni tabele z zapisi na vsako zahtevo.

  sec.ForceSignOutUser: prevzem seje = nov SecurityStamp za tega uporabnika. Obstojeci mehanizem
  (migracija 181) sam poskrbi, da stara seja pade ven ob svoji naslednji zahtevi — noben nov
  mehanizem za "izmet" ni potreben, samo klic tega, kar ze imamo. Vrne novi zig nazaj, ker ga
  klicatelj (Program.cs, prijava po potrditvi) takoj potrebuje za novo sejo — brez tega bi bila
  prva zahteva nove seje zavrnjena, ker bi piskotek se nosil stari zig.
*/

SET XACT_ABORT ON;

IF COL_LENGTH(N'sec.LocalUser', N'LastSeenUtc') IS NULL
BEGIN
  ALTER TABLE sec.LocalUser ADD LastSeenUtc datetime2(3) NULL;
END;

EXEC(N'
CREATE OR ALTER PROCEDURE sec.GetUserSecurityState
  @UserName nvarchar(100)
AS
BEGIN
  SET NOCOUNT ON;

  UPDATE sec.LocalUser
    SET LastSeenUtc = SYSUTCDATETIME()
  WHERE UserName = @UserName
    AND (LastSeenUtc IS NULL OR LastSeenUtc < DATEADD(SECOND, -60, SYSUTCDATETIME()));

  SELECT TOP (1)
    localUser.UserName,
    localUser.DisplayName,
    localUser.IsEnabled,
    localUser.SecurityStamp,
    ISNULL((
      SELECT STRING_AGG(roleValue.RoleCode, N'','') WITHIN GROUP (ORDER BY roleValue.RoleCode)
      FROM sec.LocalUserRole userRole
      INNER JOIN sec.Role roleValue ON roleValue.RoleId = userRole.RoleId
      WHERE userRole.LocalUserId = localUser.LocalUserId), N'''') AS Roles
  FROM sec.LocalUser localUser
  WHERE localUser.UserName = @UserName;
END;
');

/* Bere surovo stanje "zadnjic viden" — namenoma brez UPDATE, ker bi prijava sicer prepisala
   ravno vrednost, ki jo mora prebrati (ali je racun TRENUTNO aktiven drugje). */
EXEC(N'
CREATE OR ALTER PROCEDURE sec.GetUserPresence
  @UserName nvarchar(100)
AS
BEGIN
  SET NOCOUNT ON;
  SELECT TOP (1) LastSeenUtc FROM sec.LocalUser WHERE UserName = @UserName;
END;
');

EXEC(N'
CREATE OR ALTER PROCEDURE sec.ForceSignOutUser
  @UserName nvarchar(100)
AS
BEGIN
  SET NOCOUNT ON;
  DECLARE @NoviZig uniqueidentifier = NEWID();
  UPDATE sec.LocalUser SET SecurityStamp = @NoviZig WHERE UserName = @UserName;
  SELECT @NoviZig AS SecurityStamp;
END;
');

IF COL_LENGTH(N'sec.LocalUser', N'LastSeenUtc') IS NULL
  THROW 51224, N'224: sec.LocalUser.LastSeenUtc manjka.', 1;
IF OBJECT_ID(N'sec.GetUserPresence', N'P') IS NULL
  THROW 51224, N'224: sec.GetUserPresence manjka.', 1;
IF OBJECT_ID(N'sec.ForceSignOutUser', N'P') IS NULL
  THROW 51224, N'224: sec.ForceSignOutUser manjka.', 1;
