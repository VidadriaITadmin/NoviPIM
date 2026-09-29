/*
  279 — rocna ponovna preslikava vira (244) obdela samo ZADNJI zajem vira, ne vseh.

  Najdeno 2026-09-25 (naloga »novi artikli«): map.ReprocessSupplierSource je v #PonovnaTek pobral
  VSE zajeme vira (organizacija + SourceCode), ki imajo izluscene vrednosti, in jih obdelal s
  kurzorjem brez ORDER BY - v nedolocenem vrstnem redu (RunId je GUID). Lokalno sta imela NW_XML in
  BT_XML za vsako podjetje po dva zajema (2026-08-24 in 2026-09-25); ce bi se star obdelal zadnji,
  bi njegove vrednosti (atributi, kategorije, slike, dokumenti) povozile sveze. Poleg tega je vsak
  pretekli zajem pomenil se en prehod cez ~3000 zapisov - pri velikem podjetju »10 minut in vec«.

  Zadnji zajem dobaviteljevega XML je vedno cel katalog (ena datoteka = vsi artikli dobavitelja),
  zato zadosca; starejsi zajemi ne prinesejo nicesar, kar ne bi bilo ze v zadnjem.
  »Zadnji« = zajem z najnovejso stranjo (MAX(ReceivedUtc)) med stranmi z izluscenimi vrednostmi.

  Telo je iz 244, spremenjen samo izbor #PonovnaTek. Izhod (Runs, Pages, Errors) ostane enak;
  Runs je odslej 0 ali 1. Migrator ne pozna GO (061), zato je procedura v EXEC(N'...').
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

  /* 279: samo zadnji zajem vira - starejsi bi v nedolocenem vrstnem redu povozili sveze vrednosti. */
  SELECT TOP (1) inbox.RunId
  INTO #PonovnaTek
  FROM raw.Inbox inbox
  WHERE inbox.OrganizationId = @OrganizationId AND inbox.SourceCode = @SourceCode
    AND EXISTS (SELECT 1 FROM map.ExtractedValue value WHERE value.InboxId = inbox.InboxId)
  GROUP BY inbox.RunId
  ORDER BY MAX(inbox.ReceivedUtc) DESC;

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
IF OBJECT_DEFINITION(OBJECT_ID(N'map.ReprocessSupplierSource')) NOT LIKE N'%279: samo zadnji zajem%'
  THROW 52790, N'279: map.ReprocessSupplierSource se vedno obdela vse zajeme vira.', 1;
