/*
  244 — rocna ponovna preslikava celega vira (organizacija + SourceCode), brez odobritve kandidatov.

  Uporabnik 2026-09-22: nic vec ne sme blokirati - ne polja na kartici artikla (zaklep "caka SAOP"
  je odstranjen v ProductChannelPanel.razor) ne uvoz novih artiklov zaradi manjkajoce preslikave
  kategorije ali atributa. Namesto da uporabnik blokado popravlja artikel po
  artikel, dobi pojavno okno z vrzelmi (kategorija/atribut), gumb za ustvarjanje/preslikavo in nato
  EN gumb "ponovno preslikaj vir" — isto surovo XML gre skozi preslikavo se enkrat, tokrat z
  dopolnjenimi mapami, ne da bi bilo datoteko treba znova nalagati (surove strani ze zivijo v
  raw.Inbox).

  Zakaj ne kar map.ImportSupplierProductCandidates znova: ta zahteva map.ApproveSupplierProductCandidate
  (Status='PENDING') za vsakega kandidata - ze uvozeni artikli (Status='APPROVED') bi padli v Skipped
  in NJIHOVE surove strani sploh ne bi bile ponovno obdelane (#Tek v 240 se gradi iz @Odobreni). Prav to
  so artikli, ki jim manjka kategorija/atribut, ker so ze bili ustvarjeni PRED popravkom preslikave.

  Zacasne tabele imajo namenoma edinstveni imeni (#PonovnaTek, #PonovnaPrej): SQL Server v gnezdeni
  proceduri veze ime zacasne tabele na klicateljevo, ce ta ze ima tabelo z istim imenom (preizkus je
  z #Prej padel na "Invalid column name").

  map.ReprocessSupplierSource zato pobere strani vira NEPOSREDNO iz raw.Inbox (organizacija +
  SourceCode), ne prek odobritve kandidata - isto jedro (ProcessRawInbox, ProcessAttributePairInbox,
  ProcessDocumentInbox, ResolveProductCategories) kot pri rednem uvozu (240) in nocni uskladitvi.
  map.ResolveProductCategories je MERGE in spostuje rocno uvrstitev (109) - veckratni zagon nad istimi
  stranmi je varen, to je isti mehanizem, ki ga nocna uskladitev ze pozene vsako noc.

  Migrator ne pozna GO, zato CREATE OR ALTER v EXEC(N'...').
*/

SET XACT_ABORT ON;

EXEC(N'
CREATE OR ALTER PROCEDURE map.ReprocessSupplierSource
  @OrganizationId int, @SourceCode nvarchar(100), @Actor nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON;
  SET @Actor = NULLIF(LTRIM(RTRIM(@Actor)), N'''');
  IF @Actor IS NULL THROW 52460, N''Kdo pozene ponovno preslikavo, mora biti znano (Actor).'', 1;

  DECLARE @Napake TABLE (RunId uniqueidentifier NULL, Sporocilo nvarchar(500) NOT NULL);

  SELECT DISTINCT inbox.RunId
  INTO #PonovnaTek
  FROM raw.Inbox inbox
  WHERE inbox.OrganizationId = @OrganizationId AND inbox.SourceCode = @SourceCode
    AND EXISTS (SELECT 1 FROM map.ExtractedValue value WHERE value.InboxId = inbox.InboxId);

  /* Ponovna obdelava istih strani ni nov pojav artikla - stevec in cas zadnjega pojava se po
     obdelavi vrneta na stanje pred preslikavo (isto pravilo kot pri map.ImportSupplierProductCandidates, 240). */
  SELECT candidate.SupplierProductCandidateId, candidate.OccurrenceCount, candidate.LastSeenUtc
  INTO #PonovnaPrej
  FROM map.SupplierProductCandidate candidate
  WHERE candidate.OrganizationId = @OrganizationId AND candidate.SourceCode = @SourceCode AND candidate.IsActive = 1;

  DECLARE @Strani int = 0;
  UPDATE inbox SET Status = N''Pending'', ProcessedUtc = NULL
  FROM raw.Inbox inbox
  INNER JOIN #PonovnaTek tek ON tek.RunId = inbox.RunId
  WHERE inbox.Status = N''Processed''
    AND EXISTS (SELECT 1 FROM map.ExtractedValue value WHERE value.InboxId = inbox.InboxId);
  SET @Strani = @@ROWCOUNT;

  DECLARE @RunId uniqueidentifier, @Opomba nvarchar(400);
  DECLARE tek_cursor CURSOR LOCAL FAST_FORWARD FOR SELECT RunId FROM #PonovnaTek;
  OPEN tek_cursor;
  FETCH NEXT FROM tek_cursor INTO @RunId;
  WHILE @@FETCH_STATUS = 0
  BEGIN
    SET @Opomba = CONCAT(N''Rocna ponovna preslikava vira '', @SourceCode, N'', zajem '', CONVERT(nvarchar(36), @RunId));
    EXEC pim.SetChangeContext N''XML_IMPORT'', @Actor, @RunId, @Opomba;
    BEGIN TRY
      EXEC map.ProcessRawInbox @RunId, @OrganizationId, @SourceCode;
      EXEC map.ProcessAttributePairInbox @RunId, @OrganizationId, @SourceCode;
      EXEC map.ProcessDocumentInbox @RunId, @OrganizationId, @SourceCode;
      EXEC map.ResolveProductCategories @RunId, @OrganizationId, @SourceCode;
    END TRY
    BEGIN CATCH
      IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
      INSERT @Napake (RunId, Sporocilo) VALUES (@RunId, LEFT(ERROR_MESSAGE(), 500));
    END CATCH;
    EXEC pim.ClearChangeContext;
    FETCH NEXT FROM tek_cursor INTO @RunId;
  END;
  CLOSE tek_cursor; DEALLOCATE tek_cursor;

  UPDATE candidate SET OccurrenceCount = prej.OccurrenceCount, LastSeenUtc = prej.LastSeenUtc
  FROM map.SupplierProductCandidate candidate
  INNER JOIN #PonovnaPrej prej ON prej.SupplierProductCandidateId = candidate.SupplierProductCandidateId
  WHERE candidate.IsActive = 1;

  SELECT
    Runs = (SELECT COUNT(*) FROM #PonovnaTek),
    Pages = @Strani,
    Errors = (SELECT STRING_AGG(CONCAT(N''zajem '', CONVERT(nvarchar(36), RunId), N'': '', Sporocilo), N''; '') FROM @Napake);
  DROP TABLE #PonovnaTek; DROP TABLE #PonovnaPrej;
END;
');

/* --- Dokaz --------------------------------------------------------------------------------- */
IF OBJECT_ID(N'map.ReprocessSupplierSource', N'P') IS NULL
  THROW 52462, N'244: map.ReprocessSupplierSource ni nastala.', 1;
