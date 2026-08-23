/*
  078 — spletni nazivi iz delovnih zvezkov.

  Odlocitev uporabnika 2026-08-23: spletni naziv in ERP naziv sta dve razlicni stvari. ERP naziv
  je v SAOP omejen na dvakrat 30 znakov (ItemTitle1 + ItemTitle2), spletni pa je poljuben in so
  ga sestavljali rocno.

  Sestavljeni nazivi zivijo v 58 delovnih zvezkih (C:\Users\David\Desktop\PIM\PIM_test\
  1-Uvoz artiklov_Splet). Naslovi stolpcev so povsod isti: 'Sifra artikla', 'Naziv artikla',
  'Naziv angleski', 'Naziv nemski', 'Naziv hrvaski'.

  Zvezek ni nov tok podatkov, ampak druga oblika istega: PIM.XmlFileWorker ga pretvori v isti
  genericni XML, ki ga ze zna zajeti, in gre po isti poti — nabiralnik, izluscanje po XPath,
  preslikave iz registra, karantena, mejnik. Imena elementov nastanejo iz naslovov stolpcev
  ('Naziv angleski' -> NazivAngleski); pravilo je zapisano v WorkbookReader.SanitizeName.

  Konektor je registriran pri vseh stirih podjetjih, ujemanje pa je po sifri artikla: zvezek se
  poveze s tistim podjetjem, ki to sifro ima.

  Kar ta migracija NE naredi: opisov (stolpca 'Opis artikla' in 'Dodaten opis') ne prenasa.
  Opis DESCRIPTION danes prihaja iz SAOP in bi ga spletni opis prepisal; kaj je pravi vir opisa,
  je locena odlocitev.
*/

SET XACT_ABORT ON;

MERGE map.SourceConnector AS target
USING (VALUES (1), (2), (3), (4)) AS source(OrganizationId)
  ON target.SourceCode = N'SPLET_XLSX' AND target.OrganizationId = source.OrganizationId
WHEN NOT MATCHED THEN INSERT (SourceCode, OrganizationId, ConnectorType, IsActive)
  VALUES (N'SPLET_XLSX', source.OrganizationId, N'FILE_XLSX', 1);

/* --- podjetje 1 --- */
EXEC(N'
DECLARE @ConnectorId int = (SELECT SourceConnectorId FROM map.SourceConnector WHERE SourceCode = N''SPLET_XLSX'' AND OrganizationId = 1);
IF @ConnectorId IS NOT NULL
BEGIN
  MERGE map.EntityMapping AS target
  USING (VALUES (N''SpletniNaziv'', N''/vrstice/vrstica'', N''Product'')) AS source(EntityType, RecordXPath, TargetDomain)
    ON target.SourceConnectorId = @ConnectorId AND target.EntityType = source.EntityType
  WHEN MATCHED THEN UPDATE SET RecordXPath = source.RecordXPath, TargetDomain = source.TargetDomain, IsActive = 1
  WHEN NOT MATCHED THEN INSERT (SourceConnectorId, EntityType, RecordXPath, TargetDomain, IsActive)
    VALUES (@ConnectorId, source.EntityType, source.RecordXPath, source.TargetDomain, 1);

  MERGE map.FieldMapping AS target
  USING (VALUES
    (N''SifraArtikla/text()[1]'',  N''Product.ItemID'',              CONVERT(bit,1)),
    (N''NazivArtikla/text()[1]'',  N''ProductText.WEB_TITLE.sl'',    CONVERT(bit,0)),
    (N''NazivAngleski/text()[1]'', N''ProductText.WEB_TITLE.en'',    CONVERT(bit,0)),
    (N''NazivNemski/text()[1]'',   N''ProductText.WEB_TITLE.de'',    CONVERT(bit,0)),
    (N''NazivHrvaski/text()[1]'',  N''ProductText.WEB_TITLE.hr'',    CONVERT(bit,0))
  ) AS source(SourceElement, TargetFieldCode, IsRequired)
    ON target.SourceConnectorId = @ConnectorId AND target.EntityType = N''SpletniNaziv''
      AND target.TargetFieldCode = source.TargetFieldCode
  WHEN MATCHED THEN UPDATE SET SourceElement = source.SourceElement, IsRequired = source.IsRequired, IsActive = 1
  WHEN NOT MATCHED THEN INSERT (SourceConnectorId, EntityType, SourceElement, TargetFieldCode, IsRequired, IsActive)
    VALUES (@ConnectorId, N''SpletniNaziv'', source.SourceElement, source.TargetFieldCode, source.IsRequired, 1);
END;
');

/* --- podjetje 2 --- */
EXEC(N'
DECLARE @ConnectorId int = (SELECT SourceConnectorId FROM map.SourceConnector WHERE SourceCode = N''SPLET_XLSX'' AND OrganizationId = 2);
IF @ConnectorId IS NOT NULL
BEGIN
  MERGE map.EntityMapping AS target
  USING (VALUES (N''SpletniNaziv'', N''/vrstice/vrstica'', N''Product'')) AS source(EntityType, RecordXPath, TargetDomain)
    ON target.SourceConnectorId = @ConnectorId AND target.EntityType = source.EntityType
  WHEN MATCHED THEN UPDATE SET RecordXPath = source.RecordXPath, TargetDomain = source.TargetDomain, IsActive = 1
  WHEN NOT MATCHED THEN INSERT (SourceConnectorId, EntityType, RecordXPath, TargetDomain, IsActive)
    VALUES (@ConnectorId, source.EntityType, source.RecordXPath, source.TargetDomain, 1);

  MERGE map.FieldMapping AS target
  USING (VALUES
    (N''SifraArtikla/text()[1]'',  N''Product.ItemID'',              CONVERT(bit,1)),
    (N''NazivArtikla/text()[1]'',  N''ProductText.WEB_TITLE.sl'',    CONVERT(bit,0)),
    (N''NazivAngleski/text()[1]'', N''ProductText.WEB_TITLE.en'',    CONVERT(bit,0)),
    (N''NazivNemski/text()[1]'',   N''ProductText.WEB_TITLE.de'',    CONVERT(bit,0)),
    (N''NazivHrvaski/text()[1]'',  N''ProductText.WEB_TITLE.hr'',    CONVERT(bit,0))
  ) AS source(SourceElement, TargetFieldCode, IsRequired)
    ON target.SourceConnectorId = @ConnectorId AND target.EntityType = N''SpletniNaziv''
      AND target.TargetFieldCode = source.TargetFieldCode
  WHEN MATCHED THEN UPDATE SET SourceElement = source.SourceElement, IsRequired = source.IsRequired, IsActive = 1
  WHEN NOT MATCHED THEN INSERT (SourceConnectorId, EntityType, SourceElement, TargetFieldCode, IsRequired, IsActive)
    VALUES (@ConnectorId, N''SpletniNaziv'', source.SourceElement, source.TargetFieldCode, source.IsRequired, 1);
END;
');

/* --- podjetje 3 --- */
EXEC(N'
DECLARE @ConnectorId int = (SELECT SourceConnectorId FROM map.SourceConnector WHERE SourceCode = N''SPLET_XLSX'' AND OrganizationId = 3);
IF @ConnectorId IS NOT NULL
BEGIN
  MERGE map.EntityMapping AS target
  USING (VALUES (N''SpletniNaziv'', N''/vrstice/vrstica'', N''Product'')) AS source(EntityType, RecordXPath, TargetDomain)
    ON target.SourceConnectorId = @ConnectorId AND target.EntityType = source.EntityType
  WHEN MATCHED THEN UPDATE SET RecordXPath = source.RecordXPath, TargetDomain = source.TargetDomain, IsActive = 1
  WHEN NOT MATCHED THEN INSERT (SourceConnectorId, EntityType, RecordXPath, TargetDomain, IsActive)
    VALUES (@ConnectorId, source.EntityType, source.RecordXPath, source.TargetDomain, 1);

  MERGE map.FieldMapping AS target
  USING (VALUES
    (N''SifraArtikla/text()[1]'',  N''Product.ItemID'',              CONVERT(bit,1)),
    (N''NazivArtikla/text()[1]'',  N''ProductText.WEB_TITLE.sl'',    CONVERT(bit,0)),
    (N''NazivAngleski/text()[1]'', N''ProductText.WEB_TITLE.en'',    CONVERT(bit,0)),
    (N''NazivNemski/text()[1]'',   N''ProductText.WEB_TITLE.de'',    CONVERT(bit,0)),
    (N''NazivHrvaski/text()[1]'',  N''ProductText.WEB_TITLE.hr'',    CONVERT(bit,0))
  ) AS source(SourceElement, TargetFieldCode, IsRequired)
    ON target.SourceConnectorId = @ConnectorId AND target.EntityType = N''SpletniNaziv''
      AND target.TargetFieldCode = source.TargetFieldCode
  WHEN MATCHED THEN UPDATE SET SourceElement = source.SourceElement, IsRequired = source.IsRequired, IsActive = 1
  WHEN NOT MATCHED THEN INSERT (SourceConnectorId, EntityType, SourceElement, TargetFieldCode, IsRequired, IsActive)
    VALUES (@ConnectorId, N''SpletniNaziv'', source.SourceElement, source.TargetFieldCode, source.IsRequired, 1);
END;
');

/* --- podjetje 4 --- */
EXEC(N'
DECLARE @ConnectorId int = (SELECT SourceConnectorId FROM map.SourceConnector WHERE SourceCode = N''SPLET_XLSX'' AND OrganizationId = 4);
IF @ConnectorId IS NOT NULL
BEGIN
  MERGE map.EntityMapping AS target
  USING (VALUES (N''SpletniNaziv'', N''/vrstice/vrstica'', N''Product'')) AS source(EntityType, RecordXPath, TargetDomain)
    ON target.SourceConnectorId = @ConnectorId AND target.EntityType = source.EntityType
  WHEN MATCHED THEN UPDATE SET RecordXPath = source.RecordXPath, TargetDomain = source.TargetDomain, IsActive = 1
  WHEN NOT MATCHED THEN INSERT (SourceConnectorId, EntityType, RecordXPath, TargetDomain, IsActive)
    VALUES (@ConnectorId, source.EntityType, source.RecordXPath, source.TargetDomain, 1);

  MERGE map.FieldMapping AS target
  USING (VALUES
    (N''SifraArtikla/text()[1]'',  N''Product.ItemID'',              CONVERT(bit,1)),
    (N''NazivArtikla/text()[1]'',  N''ProductText.WEB_TITLE.sl'',    CONVERT(bit,0)),
    (N''NazivAngleski/text()[1]'', N''ProductText.WEB_TITLE.en'',    CONVERT(bit,0)),
    (N''NazivNemski/text()[1]'',   N''ProductText.WEB_TITLE.de'',    CONVERT(bit,0)),
    (N''NazivHrvaski/text()[1]'',  N''ProductText.WEB_TITLE.hr'',    CONVERT(bit,0))
  ) AS source(SourceElement, TargetFieldCode, IsRequired)
    ON target.SourceConnectorId = @ConnectorId AND target.EntityType = N''SpletniNaziv''
      AND target.TargetFieldCode = source.TargetFieldCode
  WHEN MATCHED THEN UPDATE SET SourceElement = source.SourceElement, IsRequired = source.IsRequired, IsActive = 1
  WHEN NOT MATCHED THEN INSERT (SourceConnectorId, EntityType, SourceElement, TargetFieldCode, IsRequired, IsActive)
    VALUES (@ConnectorId, N''SpletniNaziv'', source.SourceElement, source.TargetFieldCode, source.IsRequired, 1);
END;
');

/* --- preverbi ---------------------------------------------------------------- */

IF (SELECT COUNT(*) FROM map.SourceConnector WHERE SourceCode = N'SPLET_XLSX' AND IsActive = 1) < 4
  THROW 52781, 'Vir spletnih nazivov ni registriran pri vseh stirih podjetjih.', 1;

IF
(
  SELECT COUNT(*) FROM map.FieldMapping mapping
  INNER JOIN map.SourceConnector connector ON connector.SourceConnectorId = mapping.SourceConnectorId
  WHERE connector.SourceCode = N'SPLET_XLSX' AND mapping.IsActive = 1
    AND mapping.TargetFieldCode LIKE N'ProductText.WEB_TITLE.%'
) < 16
  THROW 52782, 'Preslikave spletnih nazivov niso vpisane.', 1;
