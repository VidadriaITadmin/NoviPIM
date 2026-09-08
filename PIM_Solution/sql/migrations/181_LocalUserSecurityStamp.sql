-- A3 iz pregleda 2026-09-08: onemogocen racun ostane prijavljen.
--
-- Dokaz iz pregleda: skripta se je prijavila, nato je nastavila sec.LocalUser.IsEnabled = 0
-- za svoj racun in z istim piskotkom dobila /izdelki s HTTP 200. Vzrok je bil, da se IsEnabled
-- in vloge preberejo samo ob prijavi, piskotek pa velja se 14 dni.
--
-- Resitev je zig seje (SecurityStamp). Vsaka sprememba, ki mora podreti obstojece seje --
-- izklop racuna, novo geslo, zamenjava vira prijave in vsaka sprememba vlog -- zig zavrti na
-- novo vrednost. Intranet zig nosi v piskotku in ga ob vsaki zahtevi (najvec vsakih pet minut)
-- primerja s tem, kar je v bazi; ob neujemanju sejo zavrne.
--
-- Zakaj sprozilca in ne klic iz aplikacije: racun se v praksi izklopi tudi neposredno v bazi
-- (tako je bil narejen dokaz A3). Ce bi zig obnavljala samo aplikacija, bi taka sprememba
-- ostala neopazna in bi napaka prezivela svoj popravek.

SET XACT_ABORT ON;

IF COL_LENGTH(N'sec.LocalUser', N'SecurityStamp') IS NULL
BEGIN
  ALTER TABLE sec.LocalUser ADD SecurityStamp uniqueidentifier NOT NULL
    CONSTRAINT DF_LocalUser_SecurityStamp DEFAULT (NEWID());
END;

-- Sprozilec na uporabniku. Namenoma ne zavrti ziga ob spremembi prikaznega imena ali
-- e-postnega naslova: to ne spremeni nicesar, kar bi seja smela poceti, prijavljeni uporabnik
-- pa naj zaradi popravka priimka ne izgubi dela v obrazcu.
EXEC(N'
CREATE OR ALTER TRIGGER sec.TR_LocalUser_SecurityStamp
ON sec.LocalUser
AFTER UPDATE
AS
BEGIN
  SET NOCOUNT ON;
  IF NOT (UPDATE(IsEnabled) OR UPDATE(PasswordHash) OR UPDATE(AuthSource) OR UPDATE(DomainIdentity))
    RETURN;

  UPDATE localUser
    SET SecurityStamp = NEWID()
  FROM sec.LocalUser localUser
  INNER JOIN inserted ON inserted.LocalUserId = localUser.LocalUserId
  INNER JOIN deleted ON deleted.LocalUserId = inserted.LocalUserId
  WHERE inserted.IsEnabled <> deleted.IsEnabled
     OR ISNULL(inserted.PasswordHash, N'''') <> ISNULL(deleted.PasswordHash, N'''')
     OR inserted.AuthSource <> deleted.AuthSource
     OR ISNULL(inserted.DomainIdentity, N'''') <> ISNULL(deleted.DomainIdentity, N'''');
END;
');

-- Sprozilec na vlogah. Odvzeta vloga mora veljati takoj; drugace bi urednik, ki mu je vloga
-- odvzeta, do izteka piskotka se naprej pisal v katalog.
EXEC(N'
CREATE OR ALTER TRIGGER sec.TR_LocalUserRole_SecurityStamp
ON sec.LocalUserRole
AFTER INSERT, DELETE
AS
BEGIN
  SET NOCOUNT ON;
  UPDATE localUser
    SET SecurityStamp = NEWID()
  FROM sec.LocalUser localUser
  WHERE localUser.LocalUserId IN (SELECT LocalUserId FROM inserted
                                  UNION SELECT LocalUserId FROM deleted);
END;
');

-- Bralni model za preverjanje seje. Ena vrstica na ime; vloge pridejo z njo, da lahko seja
-- dobi tudi odvzeto ali dodano vlogo brez ponovne prijave.
EXEC(N'
CREATE OR ALTER PROCEDURE sec.GetUserSecurityState
  @UserName nvarchar(100)
AS
BEGIN
  SET NOCOUNT ON;
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
