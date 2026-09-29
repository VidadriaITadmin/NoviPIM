/*
  280 — Zgodovina uvozov in povratek (»Povrni uvoz«).

  Uporabnik 2026-09-24: »hitra sprememba samo za eno polje ni uporabna; mišljeno je, da ko se spremenijo artikli,
  da se povrne — pri uvozih artiklov, cen, strank in SAOP; ne vem, kako bo s SAOP, ker se pošlje v SAOP, razen če
  se ponovno prejšnje stanje pošlje.«

  Do zdaj uvoz ni imel identitete: en uvoz delovnega lista izdelkov je nastal kot desetine serij v
  pim.ProductChangeBatch (vsaka procedura svojo), uvoz cen ni prejšnjih vrednosti nikjer shranil, uvoz strank je
  imel samo b2b.AuditLog po vrsticah. Zato ga ni bilo mogoče ne pokazati kot celote ne povrniti.

  Ta migracija doda:
    1. ops.ImportRun — en zapis na uveljavljen uvoz (vrsta, datoteka, kdo, kdaj, koliko, skupine za SAOP), in
       povezavo povratka (UndoOfImportRunId / UndoneByImportRunId).
    2. ops.ImportRunChange — vsaka spremenjena celica: vrstica (artikel, stranka, cenik|artikel), polje,
       prej → potem, kam je šla (PIM ali SAOP). »Prej« zajame predogled uvoza tik pred zapisom.
    3. ops.RecordImportRun, intranet.GetImportRuns, intranet.GetImportRun.
    4. Pravica page.imports.history.

  Povratek ni nova pot zapisa: intranet iz »prej« sestavi nov uvoz in ga pošlje skozi iste procedure kot vsak
  uvoz (zgodovina, validacija, sled). Kar gre v SAOP, gre v odhodno vrsto kot vedno — čaka odobritev, nikoli
  samodejno. Celica, ki jo je po uvozu že kdo drug spremenil, se ne povrne (pokaže se kot spor).

  Ročni korak: ne. Čiščenje: zapisi starejši od 180 dni (ob vsakem novem zapisu).
  Migrator ne pozna GO, zato CREATE OR ALTER v EXEC(N'...').
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

IF UNICODE(N'č') <> 269
  THROW 52800, N'280: datoteka ni prebrana kot UTF-8 (sqlcmd -f 65001 ali Invoke-PendingMigrations.ps1).', 1;

/* --- 1) ops.ImportRun ------------------------------------------------------------------------------ */
IF OBJECT_ID(N'ops.ImportRun', N'U') IS NULL
BEGIN
  CREATE TABLE ops.ImportRun
  (
    ImportRunId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_ImportRun PRIMARY KEY,
    Kind nvarchar(20) NOT NULL CONSTRAINT CK_ImportRun_Kind CHECK (Kind IN (N'IZDELKI', N'CENE', N'STRANKE')),
    Title nvarchar(400) NOT NULL,
    Note nvarchar(1000) NULL,
    Actor nvarchar(200) NOT NULL,
    AppliedUtc datetime2(3) NOT NULL CONSTRAINT DF_ImportRun_AppliedUtc DEFAULT (SYSUTCDATETIME()),
    RowCountValue int NOT NULL CONSTRAINT DF_ImportRun_RowCount DEFAULT (0),
    ChangeCount int NOT NULL CONSTRAINT DF_ImportRun_ChangeCount DEFAULT (0),
    SaopCount int NOT NULL CONSTRAINT DF_ImportRun_SaopCount DEFAULT (0),
    OutboundBatchIds nvarchar(1000) NULL,
    Problems nvarchar(max) NULL,
    Snapshot nvarchar(max) NULL,            /* stranke: vrstice seznama strank pred uvozom (JSON) — iz njih nastane povratek */
    UndoOfImportRunId bigint NULL CONSTRAINT FK_ImportRun_UndoOf REFERENCES ops.ImportRun (ImportRunId),
    UndoneByImportRunId bigint NULL,
    UndoneUtc datetime2(3) NULL,
    UndoneBy nvarchar(200) NULL
  );
  CREATE INDEX IX_ImportRun_Kind_Applied ON ops.ImportRun (Kind, AppliedUtc DESC);
END;

IF COL_LENGTH(N'ops.ImportRun', N'Snapshot') IS NULL
  ALTER TABLE ops.ImportRun ADD Snapshot nvarchar(max) NULL;

/* --- 2) ops.ImportRunChange -------------------------------------------------------------------------- */
IF OBJECT_ID(N'ops.ImportRunChange', N'U') IS NULL
BEGIN
  CREATE TABLE ops.ImportRunChange
  (
    ImportRunChangeId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_ImportRunChange PRIMARY KEY,
    ImportRunId bigint NOT NULL CONSTRAINT FK_ImportRunChange_Run REFERENCES ops.ImportRun (ImportRunId) ON DELETE CASCADE,
    OrganizationId int NOT NULL,
    OrganizationName nvarchar(200) NULL,
    RowKey nvarchar(200) NOT NULL,          /* šifra artikla, ključ stranke ali cenik|šifra */
    RowLabel nvarchar(400) NULL,            /* naziv (za prikaz) */
    FieldKey nvarchar(300) NOT NULL,        /* koda polja, kot jo pozna uvoz */
    FieldLabel nvarchar(300) NULL,          /* naslov stolpca v Excelu */
    Target nvarchar(10) NOT NULL CONSTRAINT CK_ImportRunChange_Target CHECK (Target IN (N'PIM', N'SAOP')),
    ValueKind nvarchar(10) NOT NULL CONSTRAINT DF_ImportRunChange_ValueKind DEFAULT (N'TEXT')
      CONSTRAINT CK_ImportRunChange_ValueKind CHECK (ValueKind IN (N'TEXT', N'BOOL', N'NUMBER')),
    OldValue nvarchar(max) NULL,            /* NULL = polje je bilo prazno */
    NewValue nvarchar(max) NULL
  );
  CREATE INDEX IX_ImportRunChange_Run ON ops.ImportRunChange (ImportRunId, RowKey);
END;

/* --- 3) Procedure ------------------------------------------------------------------------------------- */
EXEC(N'CREATE OR ALTER PROCEDURE ops.RecordImportRun
  @Kind nvarchar(20),
  @Title nvarchar(400),
  @Note nvarchar(1000) = NULL,
  @Actor nvarchar(200),
  @RowCount int = 0,
  @SaopCount int = 0,
  @OutboundBatchIds nvarchar(1000) = NULL,
  @Problems nvarchar(max) = NULL,
  @UndoOfImportRunId bigint = NULL,
  @Snapshot nvarchar(max) = NULL,
  @ChangesJson nvarchar(max)          /* [{"org":2,"orgName":"…","row":"A-1","label":"…","field":"…","fieldLabel":"…","target":"PIM","kind":"TEXT","old":null,"new":"…"}] */
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  /* 280: en uveljavljen uvoz in vse njegove spremenjene celice. Povratek je tudi uvoz: zapiše se z
     @UndoOfImportRunId, prvotni zapis dobi UndoneBy*. */
  IF NULLIF(LTRIM(RTRIM(@Actor)), N'''') IS NULL THROW 52801, N''Zapis uvoza potrebuje uporabnika.'', 1;
  IF ISJSON(@ChangesJson) <> 1 THROW 52802, N''Spremembe uvoza niso veljaven JSON.'', 1;

  DECLARE @Now datetime2(3) = SYSUTCDATETIME();
  DECLARE @RunId bigint;

  BEGIN TRANSACTION;
  INSERT ops.ImportRun (Kind, Title, Note, Actor, AppliedUtc, RowCountValue, ChangeCount, SaopCount, OutboundBatchIds, Problems, Snapshot, UndoOfImportRunId)
  VALUES (@Kind, LEFT(@Title, 400), NULLIF(LTRIM(RTRIM(@Note)), N''''), @Actor, @Now, ISNULL(@RowCount, 0), 0, ISNULL(@SaopCount, 0),
    NULLIF(@OutboundBatchIds, N''''), NULLIF(@Problems, N''''), NULLIF(@Snapshot, N''''), @UndoOfImportRunId);
  SET @RunId = SCOPE_IDENTITY();

  INSERT ops.ImportRunChange (ImportRunId, OrganizationId, OrganizationName, RowKey, RowLabel, FieldKey, FieldLabel, Target, ValueKind, OldValue, NewValue)
  SELECT @RunId, change.org, LEFT(change.orgName, 200), LEFT(change.rowKey, 200), LEFT(change.label, 400), LEFT(change.field, 300),
    LEFT(change.fieldLabel, 300), CASE WHEN change.target = N''SAOP'' THEN N''SAOP'' ELSE N''PIM'' END,
    CASE WHEN change.kind IN (N''BOOL'', N''NUMBER'') THEN change.kind ELSE N''TEXT'' END, change.oldValue, change.newValue
  FROM OPENJSON(@ChangesJson) WITH (
    org int ''$.org'', orgName nvarchar(200) ''$.orgName'', rowKey nvarchar(200) ''$.row'', label nvarchar(400) ''$.label'',
    field nvarchar(300) ''$.field'', fieldLabel nvarchar(300) ''$.fieldLabel'', target nvarchar(10) ''$.target'',
    kind nvarchar(10) ''$.kind'', oldValue nvarchar(max) ''$.old'', newValue nvarchar(max) ''$.new'') AS change
  WHERE change.org IS NOT NULL AND change.rowKey IS NOT NULL AND change.field IS NOT NULL;

  UPDATE ops.ImportRun SET ChangeCount = @@ROWCOUNT WHERE ImportRunId = @RunId;

  IF @UndoOfImportRunId IS NOT NULL
    UPDATE ops.ImportRun SET UndoneByImportRunId = @RunId, UndoneUtc = @Now, UndoneBy = @Actor
    WHERE ImportRunId = @UndoOfImportRunId;
  COMMIT;

  /* Čiščenje: uvozi, starejši od 180 dni (povezave povratka se prej sprostijo). */
  UPDATE ops.ImportRun SET UndoOfImportRunId = NULL
  WHERE UndoOfImportRunId IN (SELECT ImportRunId FROM ops.ImportRun WHERE AppliedUtc < DATEADD(day, -180, @Now));
  DELETE ops.ImportRun WHERE AppliedUtc < DATEADD(day, -180, @Now);

  SELECT ImportRunId = @RunId;
END;');

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetImportRuns
  @Kind nvarchar(20) = NULL,
  @Take int = 100
AS
BEGIN
  SET NOCOUNT ON;
  SET @Take = CASE WHEN @Take IS NULL OR @Take < 1 THEN 100 WHEN @Take > 500 THEN 500 ELSE @Take END;
  SELECT TOP (@Take) importRun.ImportRunId, importRun.Kind, importRun.Title, importRun.Note, importRun.Actor, importRun.AppliedUtc,
    importRun.RowCountValue, importRun.ChangeCount, importRun.SaopCount, importRun.OutboundBatchIds, importRun.UndoOfImportRunId,
    importRun.UndoneByImportRunId, importRun.UndoneUtc, importRun.UndoneBy,
    Organizations = (SELECT STRING_AGG(names.OrganizationName, N'', '') FROM
                       (SELECT DISTINCT change.OrganizationName FROM ops.ImportRunChange AS change
                        WHERE change.ImportRunId = importRun.ImportRunId AND change.OrganizationName IS NOT NULL) AS names)
  FROM ops.ImportRun AS importRun
  WHERE @Kind IS NULL OR importRun.Kind = @Kind
  ORDER BY importRun.ImportRunId DESC;
END;');

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetImportRun
  @ImportRunId bigint
AS
BEGIN
  SET NOCOUNT ON;
  SELECT importRun.ImportRunId, importRun.Kind, importRun.Title, importRun.Note, importRun.Actor, importRun.AppliedUtc,
    importRun.RowCountValue, importRun.ChangeCount, importRun.SaopCount, importRun.OutboundBatchIds, importRun.UndoOfImportRunId,
    importRun.UndoneByImportRunId, importRun.UndoneUtc, importRun.UndoneBy, importRun.Problems, importRun.Snapshot,
    Organizations = (SELECT STRING_AGG(names.OrganizationName, N'', '') FROM
                       (SELECT DISTINCT change.OrganizationName FROM ops.ImportRunChange AS change
                        WHERE change.ImportRunId = importRun.ImportRunId AND change.OrganizationName IS NOT NULL) AS names)
  FROM ops.ImportRun AS importRun
  WHERE importRun.ImportRunId = @ImportRunId;

  SELECT change.ImportRunChangeId, change.OrganizationId, change.OrganizationName, change.RowKey, change.RowLabel, change.FieldKey,
    change.FieldLabel, change.Target, change.ValueKind, change.OldValue, change.NewValue
  FROM ops.ImportRunChange AS change
  WHERE change.ImportRunId = @ImportRunId
  ORDER BY change.OrganizationId, change.RowKey, change.ImportRunChangeId;
END;');

/* --- 4) Pravica ------------------------------------------------------------------------------------- */
INSERT sec.RolePermission (RoleId, PermissionKey)
SELECT roleValue.RoleId, N'page.imports.history'
FROM sec.Role AS roleValue
WHERE roleValue.RoleCode IN (N'ADMIN', N'CATALOG_EDITOR', N'VIEWER', N'COMMERCIAL')
  AND NOT EXISTS (SELECT 1 FROM sec.RolePermission AS existing
                  WHERE existing.RoleId = roleValue.RoleId AND existing.PermissionKey = N'page.imports.history');
