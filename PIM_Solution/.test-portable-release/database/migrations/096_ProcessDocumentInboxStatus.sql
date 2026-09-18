/*
  096 — map.ProcessDocumentInbox mora stran tudi zakljuciti.

  Postopek iz migracije 095 je dokumente pravilno prebral in vpisal, strani v raw.Inbox pa je
  pustil v stanju Pending: manjkala sta zakljucek strani in obravnava napake. Vsi ostali
  postopki (map.ProcessAttributePairInbox, map.ProcessWarehouseInbox, ...) so zgrajeni okrog
  kurzorja cez strani z izrecnim UPDATE raw.Inbox na koncu vsake; ta ni bil.

  Zakaj to ni malenkost: stran, ki ostane Pending, jo naslednji zagon pobere znova, kar je
  brez skode (MERGE je zdruzevalen), a delovni seznam "nepreslikanih strani" s tem trajno
  kaze delo, ki je opravljeno. Nocno opravilo (Nocno-vse.ps1) na koncu izpise "raw.Inbox:
  Pending N" — ta stevec bi rasel z vsakim zajemom in nihce ne bi vedel, zakaj.

  Ta migracija postopek prepise po istem vzorcu kot ostale: kurzor cez strani, transakcija na
  stran, Processed s povzetkom v FailureReason (koliko zapisov je bilo uporabljenih), ob napaki
  Quarantined z razlogom. Vsebinsko branje dokumentov je nespremenjeno.
*/

SET XACT_ABORT ON;

EXEC(N'
CREATE OR ALTER PROCEDURE map.ProcessDocumentInbox
  @RunId uniqueidentifier,
  @OrganizationId int,
  @SourceCode nvarchar(100)
AS
BEGIN
  /*
    Dokumenti dobavitelja. Vloga je zapisana v ciljni kodi (ProductDocument.<vloga>), enako
    kot ime lastnosti pri ProductAttribute.<ime>; naslov sklopa oziroma file_type je torej
    stvar preslikave in ne podatka.

    Identiteta izdelka je ista kot pri map.ProcessRawInbox in map.ResolveProductCategories:
    najprej sifra, sele nato EAN. Zapis, ki se ne ujame z artiklom, se preskoci — dobavitelj
    artikla ne sme ustvariti (CanCreateProducts = 0, migracija 069).
  */
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  DECLARE @InboxId bigint;
  DECLARE document_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT inbox.InboxId
    FROM raw.Inbox inbox
    WHERE inbox.RunId = @RunId AND inbox.OrganizationId = @OrganizationId
      AND inbox.SourceCode = @SourceCode AND inbox.Status = N''Pending''
      AND EXISTS
      (
        SELECT 1
        FROM map.EntityMapping entityMapping
        INNER JOIN map.SourceConnector connector ON connector.SourceConnectorId = entityMapping.SourceConnectorId
        WHERE connector.SourceCode = inbox.SourceCode AND connector.OrganizationId = inbox.OrganizationId
          AND entityMapping.EntityType = inbox.EntityType AND entityMapping.IsActive = 1
          AND entityMapping.TargetDomain = N''Document''
      )
    ORDER BY inbox.InboxId;

  OPEN document_cursor;
  FETCH NEXT FROM document_cursor INTO @InboxId;
  WHILE @@FETCH_STATUS = 0
  BEGIN
    BEGIN TRY
      BEGIN TRANSACTION;

      IF OBJECT_ID(N''tempdb..#Dokument'') IS NOT NULL DROP TABLE #Dokument;

      SELECT
        izdelek.ProductId,
        SUBSTRING(vrednost.TargetFieldCode, 17, 200) AS Vloga,
        LTRIM(RTRIM(CONVERT(nvarchar(1000), vrednost.Value))) AS Url,
        vrednost.RecordOrdinal
      INTO #Dokument
      FROM map.ExtractedValue vrednost
      INNER JOIN
      (
        SELECT value.RecordOrdinal,
          MAX(CASE WHEN value.TargetFieldCode = N''Product.ItemID'' THEN CONVERT(nvarchar(100), value.Value) END) AS ItemID,
          MAX(CASE WHEN value.TargetFieldCode = N''Product.EAN''    THEN CONVERT(nvarchar(100), value.Value) END) AS EAN
        FROM map.ExtractedValue value
        WHERE value.InboxId = @InboxId
        GROUP BY value.RecordOrdinal
      ) identiteta ON identiteta.RecordOrdinal = vrednost.RecordOrdinal
      CROSS APPLY
      (
        SELECT TOP(1) product.ProductId
        FROM canon.Product product
        WHERE product.OrganizationId = @OrganizationId
          AND ((identiteta.ItemID IS NOT NULL AND product.ItemID = identiteta.ItemID)
            OR (identiteta.ItemID IS NULL AND identiteta.EAN IS NOT NULL AND product.EAN = identiteta.EAN))
        ORDER BY CASE WHEN product.ItemID = identiteta.ItemID THEN 0 ELSE 1 END, product.ProductId
      ) izdelek
      WHERE vrednost.InboxId = @InboxId
        AND vrednost.TargetFieldCode LIKE N''ProductDocument.%''
        AND NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(1000), vrednost.Value))), N'''') IS NOT NULL
        AND EXISTS (SELECT 1 FROM map.FieldMapping preslikava
                    WHERE preslikava.FieldMappingId = vrednost.FieldMappingId AND preslikava.IsActive = 1);

      MERGE canon.ProductDocument AS target
      USING (SELECT DISTINCT ProductId, Vloga, Url FROM #Dokument WHERE NULLIF(Vloga, N'''') IS NOT NULL) AS source
        ON target.ProductId = source.ProductId AND target.Role = source.Vloga AND target.Url = source.Url
      WHEN NOT MATCHED THEN INSERT (ProductId, Role, Url) VALUES (source.ProductId, source.Vloga, source.Url);

      DECLARE @Zapisov int = (SELECT COUNT(DISTINCT value.RecordOrdinal) FROM map.ExtractedValue value WHERE value.InboxId = @InboxId);
      DECLARE @Uporabljenih int = (SELECT COUNT(DISTINCT RecordOrdinal) FROM #Dokument);

      UPDATE raw.Inbox
      SET Status = N''Processed'', ProcessedUtc = SYSUTCDATETIME(),
          FailureReason = CASE WHEN @Uporabljenih = @Zapisov THEN NULL
            ELSE CONCAT(N''Dokumenti uporabljeni pri '', @Uporabljenih, N'' zapisih od '', @Zapisov,
                        N''. Preostali nimajo artikla v katalogu ali nimajo nobene datoteke.'') END
      WHERE InboxId = @InboxId;

      DROP TABLE #Dokument;
      COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
      IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
      DECLARE @Napaka nvarchar(500) = ERROR_MESSAGE();
      UPDATE raw.Inbox SET Status = N''Quarantined'', ProcessedUtc = SYSUTCDATETIME(), FailureReason = LEFT(@Napaka, 2000)
      WHERE InboxId = @InboxId;
    END CATCH;

    FETCH NEXT FROM document_cursor INTO @InboxId;
  END;
  CLOSE document_cursor;
  DEALLOCATE document_cursor;
END;
');
