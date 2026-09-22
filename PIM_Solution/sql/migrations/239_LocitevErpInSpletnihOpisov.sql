/* 239: ERP opisi (SAOP) loceni od spletnih opisov (PIM).

   Uporabnik 2026-09-21 (»Opisi lociti ERP / Splet«): »Treba bo ločiti opise splet in pa opise ERP.
   Trenutno se ERP opisi pojavijo na kartici pod Splet - opisi. Moramo imeti ERP in pa potem Splet
   opisi tako v bazi kot v PIM aplikaciji.«

   Kako je bilo. SAOP poslje opise artikla po jezikih in vrstah (DescriptionType T/O/K/KD/KK),
   map.ProcessProductTextInbox (080) pa jih je zapisoval v canon.ProductText kot DESCRIPTION,
   DESCRIPTION_O, DESCRIPTION_K ... - v ISTO vrsto besedila, ki jo spletni izvoz (katalog.csv,
   Magento) in kartica izdelka stejeta za spletni opis. Posledici:
     - na kartici so bili ERP opisi prikazani kot »Spletni opis (sl/en/de/hr/it)«;
     - vsak tek SAOP je z MERGE (UPDATE SET Value) prepisal spletni opis z ERP opisom, zato v PIM-u
       ni bilo mogoce vzdrzevati lastnega spletnega opisa - vsaka rocna ali AI sprememba je zivela
       samo do naslednjega zajema.

   Kaj ta migracija spremeni:
     1. Preslikava SAOP (map.FieldMapping, konektorji s CanCreateProducts = 1) se s cilja
        ProductTextByLanguage.DESCRIPTION preusmeri na ProductTextByLanguage.DESCRIPTION_ERP.
        map.ProcessProductTextInbox (080) je nespremenjen: vrsto prebere iz ciljne kode in ji
        pripne pripono vrste (DESCRIPTION_ERP, DESCRIPTION_ERP_O, DESCRIPTION_ERP_K ...). Omejitev
        CK_CanonProductText_Type (143) druzino DESCRIPTION% ze dovoljuje.
     2. DESCRIPTION_ERP* se napolni iz ZADNJE izluscene vrednosti SAOP v map.ExtractedValue (vrstice
        se ob obdelavi ne brisejo - 197/219), po istem pravilu kot 080 (Record.ItemID, Record.LanguageId
        prek canon.Language, Record.TextTypeSuffix). Kar SAOP ni poslal, tu ne nastane; naslednji tek
        SAOP vsekakor napolni vse (»popravi zajem, ne podatkov«).
     3. Spletni opisi (DESCRIPTION*) OSTANEJO taksni, kot so - tudi tam, kjer so danes enaki ERP
        opisu. To je zavestno: so trenutno besedilo spletne trgovine in validacija/izvoz ju bereta;
        brisanje bi izpraznilo spletne opise cez noc. Od zdaj naprej jih SAOP ne prepisuje vec;
        kartica pokaze, kadar je spletni opis se enak ERP opisu, AI predlog in urednik pa ju locita.

   Kar se NE spremeni: out.* izvozi in val.* zahteve berejo DESCRIPTION (spletni opis) naprej;
   TITLE_ERP/TITLE_ERP2/TITLE_SHORT/SEARCH_NAME so ze zdaj ERP nazivi in ostanejo.

   Zgodovina sprememb (canon.TR_ProductText_FieldHistory, 034) dobi polnjenje pod virom
   MIGRATION_239, da je razvidno, od kod so vrstice. */
SET XACT_ABORT ON;

/* --- 1) preusmeritev preslikave SAOP ------------------------------------------------------ */
UPDATE mapping
SET TargetFieldCode = N'ProductTextByLanguage.DESCRIPTION_ERP',
    UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = N'migracija 239'
FROM map.FieldMapping AS mapping
INNER JOIN map.SourceConnector AS connector ON connector.SourceConnectorId = mapping.SourceConnectorId
WHERE connector.CanCreateProducts = 1
  AND mapping.TargetFieldCode = N'ProductTextByLanguage.DESCRIPTION';

/* --- 2) ERP opisi iz zadnje izluscene vrednosti SAOP --------------------------------------- */
EXEC pim.SetChangeContext N'MIGRATION_239', N'migracija 239', NULL, N'ERP opisi iz zadnjega zajema SAOP (DESCRIPTION -> DESCRIPTION_ERP)';

CREATE TABLE #Opis
(
  InboxId bigint NOT NULL, RecordOrdinal int NOT NULL, OrganizationId int NOT NULL,
  ItemID nvarchar(100) COLLATE DATABASE_DEFAULT NULL, LanguageId nvarchar(50) COLLATE DATABASE_DEFAULT NULL,
  TextTypeSuffix nvarchar(20) COLLATE DATABASE_DEFAULT NULL, Opis nvarchar(max) COLLATE DATABASE_DEFAULT NOT NULL
);

/* Izhodisce so opisi (~60 k vrstic), kljuci zapisa pa se poiscejo prek indeksa
   IX_ExtractedValue_Identity (TargetFieldCode, InboxId, RecordOrdinal) - ne obratno. */
INSERT #Opis (InboxId, RecordOrdinal, OrganizationId, ItemID, LanguageId, TextTypeSuffix, Opis)
SELECT opis.InboxId, opis.RecordOrdinal, inbox.OrganizationId,
  (SELECT TOP (1) CONVERT(nvarchar(100), kljuc.Value) FROM map.ExtractedValue AS kljuc
   WHERE kljuc.TargetFieldCode = N'Record.ItemID' AND kljuc.InboxId = opis.InboxId AND kljuc.RecordOrdinal = opis.RecordOrdinal),
  (SELECT TOP (1) CONVERT(nvarchar(50), kljuc.Value) FROM map.ExtractedValue AS kljuc
   WHERE kljuc.TargetFieldCode = N'Record.LanguageId' AND kljuc.InboxId = opis.InboxId AND kljuc.RecordOrdinal = opis.RecordOrdinal),
  (SELECT TOP (1) CONVERT(nvarchar(20), kljuc.Value) FROM map.ExtractedValue AS kljuc
   WHERE kljuc.TargetFieldCode = N'Record.TextTypeSuffix' AND kljuc.InboxId = opis.InboxId AND kljuc.RecordOrdinal = opis.RecordOrdinal),
  CONVERT(nvarchar(max), opis.Value)
FROM map.ExtractedValue AS opis
INNER JOIN raw.Inbox AS inbox ON inbox.InboxId = opis.InboxId
INNER JOIN map.SourceConnector AS connector
  ON connector.SourceCode = inbox.SourceCode AND connector.OrganizationId = inbox.OrganizationId AND connector.CanCreateProducts = 1
WHERE opis.TargetFieldCode IN (N'ProductTextByLanguage.DESCRIPTION', N'ProductTextByLanguage.DESCRIPTION_ERP')
  AND NULLIF(LTRIM(RTRIM(opis.Value)), N'') IS NOT NULL;

;WITH zadnji AS
(
  SELECT izdelek.ProductId, jezik.LanguageCode AS Lang,
    CONVERT(nvarchar(50), N'DESCRIPTION_ERP'
      + CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(o.TextTypeSuffix, N''))), N'') IS NULL OR LTRIM(RTRIM(o.TextTypeSuffix)) = N'T' THEN N''
             ELSE N'_' + LTRIM(RTRIM(o.TextTypeSuffix)) END) AS TextType,
    o.Opis AS Value,
    ROW_NUMBER() OVER (PARTITION BY izdelek.ProductId, jezik.LanguageCode,
      CASE WHEN NULLIF(LTRIM(RTRIM(ISNULL(o.TextTypeSuffix, N''))), N'') IS NULL OR LTRIM(RTRIM(o.TextTypeSuffix)) = N'T' THEN N'' ELSE LTRIM(RTRIM(o.TextTypeSuffix)) END
      ORDER BY o.InboxId DESC, o.RecordOrdinal DESC) AS Mesto
  FROM #Opis AS o
  INNER JOIN canon.Language AS jezik
    ON jezik.OrganizationId = o.OrganizationId AND jezik.LanguageId = LTRIM(RTRIM(o.LanguageId)) AND jezik.LanguageCode IS NOT NULL
  INNER JOIN canon.Product AS izdelek
    ON izdelek.OrganizationId = o.OrganizationId AND izdelek.ItemID = LTRIM(RTRIM(o.ItemID))
  WHERE o.ItemID IS NOT NULL AND o.LanguageId IS NOT NULL
)
MERGE canon.ProductText AS target
USING (SELECT ProductId, Lang, TextType, Value FROM zadnji WHERE Mesto = 1) AS source
  ON target.ProductId = source.ProductId AND target.Lang = source.Lang AND target.TextType = source.TextType
WHEN MATCHED AND target.Value <> source.Value THEN UPDATE SET Value = source.Value
WHEN NOT MATCHED THEN INSERT (ProductId, Lang, TextType, Value) VALUES (source.ProductId, source.Lang, source.TextType, source.Value);

DROP TABLE #Opis;
EXEC pim.ClearChangeContext;

/* --- Dokaz ------------------------------------------------------------------------------- */
IF EXISTS (SELECT 1 FROM map.FieldMapping AS mapping
           INNER JOIN map.SourceConnector AS connector ON connector.SourceConnectorId = mapping.SourceConnectorId
           WHERE connector.CanCreateProducts = 1 AND mapping.TargetFieldCode = N'ProductTextByLanguage.DESCRIPTION')
  THROW 52390, N'239: preslikava SAOP se vedno cilja spletni opis (ProductTextByLanguage.DESCRIPTION).', 1;

/* Kjer so izluscene vrednosti SAOP se na voljo, mora ERP opis obstajati; na bazi brez surovih
   vrednosti (npr. sveza baza) ga napolni naslednji tek SAOP - takrat to ni napaka. */
IF EXISTS (SELECT 1 FROM map.ExtractedValue AS v INNER JOIN raw.Inbox AS i ON i.InboxId = v.InboxId
           INNER JOIN map.SourceConnector AS c ON c.SourceCode = i.SourceCode AND c.OrganizationId = i.OrganizationId AND c.CanCreateProducts = 1
           WHERE v.TargetFieldCode IN (N'ProductTextByLanguage.DESCRIPTION', N'ProductTextByLanguage.DESCRIPTION_ERP') AND NULLIF(LTRIM(RTRIM(v.Value)), N'') IS NOT NULL)
   AND NOT EXISTS (SELECT 1 FROM canon.ProductText WHERE TextType = N'DESCRIPTION_ERP')
  THROW 52391, N'239: surove vrednosti SAOP obstajajo, ERP opisi pa niso nastali.', 1;
