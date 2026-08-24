/*
  095 — dokumenti so cetrti sklop dobaviteljevega XML in edini, ki ga model ni imel.

  Uporabnik 2026-08-24: "Od dobaviteljev je treba lociti atribute, kategorijo, medijo in pa
  datoteke — to je nekak standard. Potem je pa v mappingu treba povedati, kateri so kateri
  atributi itd., ker nekateri so podobni, nekateri pa novi."

  Model je to ze delal za tri od stirih: map.EntityMapping.EntityType loci Attribute,
  Classification (kategorija, dodana v 091) in Media, map.FieldMapping pa za vsakega pove,
  kateri element vira gre v katero kanonicno polje. Cetrtega ni bilo: kanonicne tabele za
  dokumente ni, zato so trije dokumentni stolpci Magento predloge (40 "Glavni dokument",
  41 "Vloge dokumentov", 42 "Ostali dokumenti") brez vira — to je zapisano ze pri blokadi
  izvoza iz 2026-08-20.

  --- Kaj dobavitelja dejansko posljeta (merjeno 2026-08-24) ------------------------------

  Braytron, sklop <sections>/<section>, datoteke z naslovom sklopa kot vlogo. Na 401 izdelku:

      CE Files      972 datotek     8-CE-CERTIFICATE.pdf
      Data Sheet    401             BG38-12581_EN.pdf
      3D Files      209             BG38-XXX26.rar
      DIALux Files  130             BD61-00381.rar
      Video          91             youtube.com/watch?v=...

  Na izdelek jih je od 1 do 10. Nowodvorski ima najvec eno: blok <media>/<file> s <file_type>,
  2.484-krat "Glowna instrukcja montazowa" in 89-krat "Etykieta energetyczna".

  --- Zakaj vloga in ne zaporedje --------------------------------------------------------

  XPathMappingExtractor bere z SelectSingleNode, torej eno vrednost na polje na zapis;
  seznama datotek ne zna vrniti. Zaporedne preslikave ("prva datoteka, druga, tretja") bi bile
  krhke: pri Braytronu vrstni red sklopov ni zajamcen, podatkovni list pa mora ostati
  podatkovni list. Zato je preslikava po VLOGI — natanko tisto, kar pravi zgornja odlocitev:
  v preslikavi povemo, kateri je kateri.

  Kar to ne pokrije: pri vlogi z vec datotekami (CE Files) se vzame prva. Za seznam bi moral
  izluscevalnik znati vec vrednosti na polje, kar je locena sprememba jedra.

  --- Kar ta migracija NE naredi ---------------------------------------------------------

  Ne dotakne se izvoza. pim.ProductDocument, val.Promote in stolpci 40-42 so naslednji korak;
  kateri dokument je "glavni", je poslovna odlocitev in ne sme nastati mimogrede v migraciji.
*/

SET XACT_ABORT ON;

EXEC(N'
IF OBJECT_ID(N''canon.ProductDocument'') IS NULL
BEGIN
  CREATE TABLE canon.ProductDocument
  (
    ProductDocumentId bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_ProductDocument PRIMARY KEY,
    ProductId         bigint         NOT NULL,
    Role              nvarchar(200)  NOT NULL,
    Url               nvarchar(1000) NOT NULL,
    Title             nvarchar(400)  NULL,
    SortOrder         int            NOT NULL CONSTRAINT DF_ProductDocument_SortOrder DEFAULT(0),
    CONSTRAINT FK_ProductDocument_Product FOREIGN KEY (ProductId) REFERENCES canon.Product(ProductId)
  );

  CREATE UNIQUE INDEX UQ_ProductDocument_Role
    ON canon.ProductDocument(ProductId, Role, Url);
END;
');

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

  IF OBJECT_ID(N''tempdb..#Dokument'') IS NOT NULL DROP TABLE #Dokument;

  SELECT
    izdelek.ProductId,
    SUBSTRING(vrednost.TargetFieldCode, 17, 200) AS Vloga,
    LTRIM(RTRIM(CONVERT(nvarchar(1000), vrednost.Value))) AS Url
  INTO #Dokument
  FROM raw.Inbox inbox
  INNER JOIN map.ExtractedValue vrednost ON vrednost.InboxId = inbox.InboxId
  INNER JOIN
  (
    SELECT value.InboxId, value.RecordOrdinal,
      MAX(CASE WHEN value.TargetFieldCode = N''Product.ItemID'' THEN CONVERT(nvarchar(100), value.Value) END) AS ItemID,
      MAX(CASE WHEN value.TargetFieldCode = N''Product.EAN''    THEN CONVERT(nvarchar(100), value.Value) END) AS EAN
    FROM map.ExtractedValue value
    INNER JOIN raw.Inbox i ON i.InboxId = value.InboxId
    WHERE i.RunId = @RunId AND i.OrganizationId = @OrganizationId AND i.SourceCode = @SourceCode
      AND i.Status = N''Pending''
    GROUP BY value.InboxId, value.RecordOrdinal
  ) identiteta
    ON identiteta.InboxId = vrednost.InboxId AND identiteta.RecordOrdinal = vrednost.RecordOrdinal
  CROSS APPLY
  (
    SELECT TOP(1) product.ProductId
    FROM canon.Product product
    WHERE product.OrganizationId = @OrganizationId
      AND ((identiteta.ItemID IS NOT NULL AND product.ItemID = identiteta.ItemID)
        OR (identiteta.ItemID IS NULL AND identiteta.EAN IS NOT NULL AND product.EAN = identiteta.EAN))
    ORDER BY CASE WHEN product.ItemID = identiteta.ItemID THEN 0 ELSE 1 END, product.ProductId
  ) izdelek
  WHERE inbox.RunId = @RunId AND inbox.OrganizationId = @OrganizationId
    AND inbox.SourceCode = @SourceCode AND inbox.Status = N''Pending''
    AND vrednost.TargetFieldCode LIKE N''ProductDocument.%''
    AND NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(1000), vrednost.Value))), N'''') IS NOT NULL
    AND EXISTS (SELECT 1 FROM map.FieldMapping preslikava
                WHERE preslikava.FieldMappingId = vrednost.FieldMappingId AND preslikava.IsActive = 1);

  MERGE canon.ProductDocument AS target
  USING (SELECT DISTINCT ProductId, Vloga, Url FROM #Dokument WHERE NULLIF(Vloga, N'''') IS NOT NULL) AS source
    ON target.ProductId = source.ProductId AND target.Role = source.Vloga AND target.Url = source.Url
  WHEN NOT MATCHED THEN INSERT (ProductId, Role, Url) VALUES (source.ProductId, source.Vloga, source.Url);

  DROP TABLE #Dokument;
END;
');

/* --- dovoljeni svetovi -------------------------------------------------------------- */

/*
  map.EntityMapping ima CHECK z zaprtim seznamom svetov (CK_EntityMapping_TargetDomain).
  Seznam se razsiri, ne prepise: vseh dvanajst obstojecih vrednosti ostane, doda se Document.
  DROP + ADD je edini nacin, kako se v SQL Serverju spremeni CHECK; nobene vrstice se pri tem
  ne dotaknemo, WITH CHECK pa poskrbi, da nova omejitev velja tudi za ze zapisane vrstice.
*/
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_EntityMapping_TargetDomain')
  ALTER TABLE map.EntityMapping DROP CONSTRAINT CK_EntityMapping_TargetDomain;

ALTER TABLE map.EntityMapping WITH CHECK ADD CONSTRAINT CK_EntityMapping_TargetDomain CHECK
(
  TargetDomain IN (N'Product', N'Warehouse', N'Language', N'ProductText', N'ProductAttributePair',
                   N'ProductStockPolicy', N'Codebook', N'ProductStockAccounting', N'ProductPlanning',
                   N'Customer', N'CustomerItem', N'CustomerGroupDiscount', N'Document')
);

/* --- entiteta Document in preslikave po vlogah --------------------------------------- */

DECLARE @Vloge TABLE(SourceCode nvarchar(100), SourceElement nvarchar(400), TargetFieldCode nvarchar(400));

INSERT @Vloge(SourceCode, SourceElement, TargetFieldCode) VALUES
  (N'BT_XML', N'code_ean/text()[1]', N'Product.EAN'),
  (N'BT_XML', N'.//section[section_info/title="Data Sheet"]/files/file[1]/url/text()',    N'ProductDocument.Podatkovni list'),
  (N'BT_XML', N'.//section[section_info/title="CE Files"]/files/file[1]/url/text()',      N'ProductDocument.CE izjava'),
  (N'BT_XML', N'.//section[section_info/title="3D Files"]/files/file[1]/url/text()',      N'ProductDocument.3D datoteka'),
  (N'BT_XML', N'.//section[section_info/title="DIALux Files"]/files/file[1]/url/text()',  N'ProductDocument.DIALux datoteka'),
  (N'BT_XML', N'.//section[section_info/title="Video"]/files/file[1]/url/text()',         N'ProductDocument.Video'),
  (N'NW_XML', N'ean/text()[1]', N'Product.EAN'),
  /* starts-with namesto enakosti: file_type je poljski z diakritiko ("Glowna instrukcja
     montazowa"), primerjava po celem nizu bi bila odvisna od zapisa datoteke. */
  (N'NW_XML', N'media/file[starts-with(file_type,"Etykieta")]/file_path/text()',          N'ProductDocument.Energijska nalepka'),
  (N'NW_XML', N'media/file[not(starts-with(file_type,"Etykieta"))]/file_path/text()',     N'ProductDocument.Navodila za montažo');

INSERT map.EntityMapping (SourceConnectorId, EntityType, RecordXPath, IsActive, TargetDomain)
SELECT k.SourceConnectorId, N'Document',
       CASE WHEN k.SourceCode = N'BT_XML' THEN N'/response/products/product' ELSE N'/channel/products/product' END,
       1, N'Document'
FROM map.SourceConnector k
WHERE k.SourceCode IN (N'BT_XML', N'NW_XML')
  AND NOT EXISTS (SELECT 1 FROM map.EntityMapping em
                  WHERE em.SourceConnectorId = k.SourceConnectorId AND em.EntityType = N'Document');

INSERT map.FieldMapping (SourceConnectorId, EntityType, SourceElement, TargetFieldCode, IsRequired, IsActive)
SELECT k.SourceConnectorId, N'Document', v.SourceElement, v.TargetFieldCode,
       CASE WHEN v.TargetFieldCode = N'Product.EAN' THEN CONVERT(bit,1) ELSE CONVERT(bit,0) END, 1
FROM map.SourceConnector k
INNER JOIN @Vloge v ON v.SourceCode = k.SourceCode
WHERE NOT EXISTS (SELECT 1 FROM map.FieldMapping fm
                  WHERE fm.SourceConnectorId = k.SourceConnectorId AND fm.EntityType = N'Document'
                    AND fm.TargetFieldCode = v.TargetFieldCode);
