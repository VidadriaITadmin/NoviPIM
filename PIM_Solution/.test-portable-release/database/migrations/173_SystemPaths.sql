/*
  173 — kam se datoteke shranjujejo, je nastavitev sistema in ne lastnost racunalnika, na
  katerem je bila koda prevedena.

  Kaj je bilo narobe
  ------------------
  Vsaka pot je danes drugje in nobene ni mogoce spremeniti brez posega v datoteke:

    prevzem dobaviteljev   --target, sicer PIM_FETCH_ROOT, sicer <repo>\PIM_Solution\data\prevzem
    izvozi za splet        --output-dir, ki ga skripta izracuna kot <repo>\izvoz\magento\<podjetje>
    dnevniki               <repo>\logs, izracunano v vsaki skripti posebej
    mapa vira MAPA         map.SourceFetchLocation.Location — edina, ki je ze v bazi

  Vse razen zadnje se opira na "koren repozitorija". To drzi na razvojnem racunalniku in pade
  na strezniku: pod IIS je koren objavljena mapa spletnega mesta, ki jo naslednja objava
  prepise, aplikacijski bazen pa vanjo praviloma nima pravice pisati. Datoteke, ki nastanejo
  tam, so torej ali izgubljene ob objavi ali pa sploh ne nastanejo — in oboje se pokaze sele
  na strezniku.

  Kaj ta migracija naredi
  -----------------------
  Register poti z zaprtim seznamom kljucev. Kljuc je zaprt namenoma: prosto besedilo pomeni,
  da tipkarska napaka tiho izklopi nastavitev in datoteke gredo spet na privzeto mesto, ne da
  bi kdo opazil.

  Cesa ta migracija NE naredi
  ---------------------------
  - Ne premakne nobene datoteke in ne spremeni nobene obstojece poti. Dokler register nima
    vrstice, velja natanko to, kar velja danes.
  - Ne dovoli zapisa poti, ki je ni: preverbo, ali je mapa dosegljiva in pisljiva, opravi
    intranet pod svojim racunom, preden vrstico shrani. Baza tega ne more vedeti.
*/

SET XACT_ABORT ON;

IF OBJECT_ID(N'ops.SystemPath', N'U') IS NULL
BEGIN
  CREATE TABLE ops.SystemPath
  (
    SystemPathId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_SystemPath PRIMARY KEY,
    PathKey nvarchar(60) NOT NULL,
    /* NULL pomeni "velja za vsa podjetja". Izvozi se delijo po podjetju, prevzem in dnevniki ne. */
    OrganizationId int NULL,
    Location nvarchar(400) NOT NULL,
    IsActive bit NOT NULL CONSTRAINT DF_SystemPath_IsActive DEFAULT (1),
    Note nvarchar(400) NULL,
    /* Zadnja uspesna preverba dosegljivosti; brez nje je vrstica samo obljuba. */
    LastCheckedUtc datetime2(3) NULL,
    LastCheckResult nvarchar(400) NULL,
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_SystemPath_UpdatedUtc DEFAULT SYSUTCDATETIME(),
    UpdatedBy nvarchar(200) NOT NULL,
    CONSTRAINT FK_SystemPath_Organization FOREIGN KEY (OrganizationId) REFERENCES dbo.OrganizationConfig(OrganizationId),
    /* SQL Server v UNIQUE steje NULL kot eno vrednost — natanko en skupen zapis na kljuc. */
    CONSTRAINT UQ_SystemPath UNIQUE (PathKey, OrganizationId),
    CONSTRAINT CK_SystemPath_Key CHECK (PathKey IN
      (N'LANDING_ROOT', N'EXPORT_ROOT', N'LOG_ROOT', N'WORKBOOK_ROOT')),
    /* Prazna pot ni "privzeto", ampak nastavitev, ki ne pove nicesar. */
    CONSTRAINT CK_SystemPath_Location CHECK (LEN(LTRIM(RTRIM(Location))) > 0)
  );
END;

EXEC(N'CREATE OR ALTER PROCEDURE ops.SetSystemPath
  @PathKey nvarchar(60),
  @Location nvarchar(400),
  @UpdatedBy nvarchar(200),
  @OrganizationId int = NULL,
  @Note nvarchar(400) = NULL,
  @IsActive bit = 1,
  @LastCheckResult nvarchar(400) = NULL
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;

  MERGE ops.SystemPath AS target
  USING (SELECT @PathKey AS PathKey, @OrganizationId AS OrganizationId) AS source
     ON target.PathKey = source.PathKey
    AND ((target.OrganizationId IS NULL AND source.OrganizationId IS NULL)
         OR target.OrganizationId = source.OrganizationId)
  WHEN MATCHED THEN UPDATE SET
       Location = @Location, IsActive = @IsActive, Note = @Note,
       LastCheckedUtc = CASE WHEN @LastCheckResult IS NULL THEN LastCheckedUtc ELSE SYSUTCDATETIME() END,
       LastCheckResult = COALESCE(@LastCheckResult, LastCheckResult),
       UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = @UpdatedBy
  WHEN NOT MATCHED THEN
       INSERT (PathKey, OrganizationId, Location, IsActive, Note, LastCheckedUtc, LastCheckResult, UpdatedBy)
       VALUES (@PathKey, @OrganizationId, @Location, @IsActive, @Note,
               CASE WHEN @LastCheckResult IS NULL THEN NULL ELSE SYSUTCDATETIME() END, @LastCheckResult, @UpdatedBy);
END;');

EXEC(N'CREATE OR ALTER PROCEDURE ops.ClearSystemPath
  @PathKey nvarchar(60),
  @OrganizationId int = NULL
AS
BEGIN
  SET NOCOUNT ON; SET XACT_ABORT ON;
  DELETE FROM ops.SystemPath
   WHERE PathKey = @PathKey
     AND ((OrganizationId IS NULL AND @OrganizationId IS NULL) OR OrganizationId = @OrganizationId);
END;');

/*
  Razresitev ene poti. Podjetju lastna vrstica premaga skupno; kadar ni ne ene ne druge,
  procedura vrne NULL in klicatelj obdrzi svoj privzetek. Privzetki so v kodi in ne tu:
  register pove, kam naj gre, ne kam gre, kadar nihce ni nicesar nastavil.
*/
EXEC(N'CREATE OR ALTER PROCEDURE ops.ResolveSystemPath
  @PathKey nvarchar(60),
  @OrganizationId int = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SELECT TOP (1) pot.Location
    FROM ops.SystemPath pot
   WHERE pot.PathKey = @PathKey
     AND pot.IsActive = 1
     AND (pot.OrganizationId IS NULL OR pot.OrganizationId = @OrganizationId)
   ORDER BY CASE WHEN pot.OrganizationId IS NULL THEN 1 ELSE 0 END;
END;');

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetSystemPaths
AS
BEGIN
  SET NOCOUNT ON;
  SELECT pot.SystemPathId, pot.PathKey, pot.OrganizationId, podjetje.Name AS OrganizationName,
         pot.Location, pot.IsActive, pot.Note, pot.LastCheckedUtc, pot.LastCheckResult,
         pot.UpdatedUtc, pot.UpdatedBy
    FROM ops.SystemPath pot
    LEFT JOIN dbo.OrganizationConfig podjetje ON podjetje.OrganizationId = pot.OrganizationId
   ORDER BY pot.PathKey, CASE WHEN pot.OrganizationId IS NULL THEN 0 ELSE 1 END, pot.OrganizationId;
END;');
