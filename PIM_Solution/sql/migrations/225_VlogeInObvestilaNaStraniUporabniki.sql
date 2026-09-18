/*
  225 — Stran "Uporabniki" je znala vlogo dolociti samo ob ustvarjanju racuna; obstojecemu
  uporabniku je ni bilo mogoce spremeniti, ne da bi ga izbrisali in ustvarili znova. Migracija
  214 je dala SetUserAlertSubscription (kljukica za eno vrsto alarma), a nobenega nacina, da
  stran prebere, na katere vrste je uporabnik trenutno narocen — zvonec je bil zato urejen samo
  iz baze, ne s strani.

  sec.SetUserRoles nadomesti CELOTEN nabor vlog uporabnika (ne doda/odvzame ene same), ker je to
  tocno to, kar mnozica kljukic na strani predstavlja: "te vloge naj ima, nobenih drugih". Vsaj
  ena vloga je obvezna — prazen nabor bi uporabnika brez opozorila pustil brez dostopa do
  cesarkoli. Sprozilec TR_LocalUserRole_SecurityStamp (181) ob vsaki spremembi vlog ze zavrti
  zig, zato odvzeta vloga velja takoj, brez dodatnega koraka tukaj.
*/

SET XACT_ABORT ON;

EXEC(N'
CREATE OR ALTER PROCEDURE sec.SetUserRoles
  @UserName nvarchar(100),
  @RoleCodesCsv nvarchar(400)
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  DECLARE @LocalUserId int = (SELECT LocalUserId FROM sec.LocalUser WHERE UserName = @UserName);
  IF @LocalUserId IS NULL THROW 51225, N''225: uporabnik ne obstaja.'', 1;

  DECLARE @Zeljene TABLE (RoleId int NOT NULL PRIMARY KEY);
  INSERT @Zeljene (RoleId)
  SELECT DISTINCT roleValue.RoleId
  FROM sec.Role roleValue
  INNER JOIN STRING_SPLIT(@RoleCodesCsv, N'','') razdeljeno ON LTRIM(RTRIM(razdeljeno.value)) = roleValue.RoleCode;

  IF NOT EXISTS (SELECT 1 FROM @Zeljene)
    THROW 51225, N''225: vsaj ena vloga je obvezna.'', 1;

  BEGIN TRANSACTION;

  DELETE FROM sec.LocalUserRole
  WHERE LocalUserId = @LocalUserId
    AND RoleId NOT IN (SELECT RoleId FROM @Zeljene);

  INSERT sec.LocalUserRole (LocalUserId, RoleId)
  SELECT @LocalUserId, zeljena.RoleId FROM @Zeljene zeljena
  WHERE NOT EXISTS (
    SELECT 1 FROM sec.LocalUserRole obstojeca
    WHERE obstojeca.LocalUserId = @LocalUserId AND obstojeca.RoleId = zeljena.RoleId);

  COMMIT TRANSACTION;
END;
');

/* Vseh sedem znanih vrst (glej CK_UserAlertSubscription_Kind, 214) + ali je uporabnik narocen
   na vsako — stran s tem izrise polno mnozico kljukic, tudi za vrste, na katere (se) ni narocen. */
EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetUserAlertSubscriptions
  @UserName nvarchar(100)
AS
BEGIN
  SET NOCOUNT ON;
  SELECT vrsta.AlertKind,
    CAST(CASE WHEN narocnina.AlertKind IS NULL THEN 0 ELSE 1 END AS bit) AS IsSubscribed
  FROM (VALUES
    (N''StaleHeartbeat''), (N''OutboundDead''), (N''OutboundDrift''), (N''StalledWatermark''),
    (N''PipelineDisabled''), (N''ReservationExcluded''), (N''OutboundUnacknowledged'')) AS vrsta(AlertKind)
  LEFT JOIN intranet.UserAlertSubscription narocnina
    ON narocnina.UserName = @UserName AND narocnina.AlertKind = vrsta.AlertKind
  ORDER BY vrsta.AlertKind;
END;
');

IF OBJECT_ID(N'sec.SetUserRoles', N'P') IS NULL
  THROW 51225, N'225: sec.SetUserRoles manjka.', 1;
IF OBJECT_ID(N'intranet.GetUserAlertSubscriptions', N'P') IS NULL
  THROW 51225, N'225: intranet.GetUserAlertSubscriptions manjka.', 1;
