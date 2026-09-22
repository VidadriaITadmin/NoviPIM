/*
  137 — dve polji, ki ju preglednica dovoljuje pisati v SAOP, doslej nista imeli
  vhodne preslikave in zato tudi ne kanonične kode v pogodbi odhodnega dokumenta.

  Kanonični kodi nista novi ugibanji:
    - garancija se že steka v `ProductAttribute.Garancija` iz obeh dobaviteljskih XML-jev;
    - ime za iskanje je besedilo in zato uporablja obstoječi splošni model
      `ProductText.<TextType>.<Lang>` kot `ProductText.SEARCH_NAME.sl`.

  `map.ProcessRawInbox` obe družini kod že zapisuje generično v `canon.ProductText`
  oziroma `canon.ProductAttribute`; dodatna zapisovalna koda zato ni potrebna.

  Lastništvo ni nova poslovna odločitev. Migracija 068 obe poti že našteva med
  pisljivimi iz preglednice `Mapiranje_SAOP_API_PIM.xlsx`, vendar vrstice ni mogla
  ustvariti, ker je lastništvo namenoma omejeno na polja z aktivno povratno preslikavo.
  Ta migracija najprej doda povratno preslikavo in nato obnovi natanko ti dve izpeljani
  pravici, brez posega v katerokoli drugo politiko.
*/

SET XACT_ABORT ON;

/* --- 1) Povratno branje iz GetItemsGeneralData --------------------------------------- */

MERGE map.FieldMapping AS target
USING
(
  SELECT connector.SourceConnectorId, N'ItemGeneralData' AS EntityType,
         field.SourceElement, field.TargetFieldCode
  FROM map.SourceConnector AS connector
  CROSS JOIN (VALUES
    (N'GeneralData/ItemSearchName/text()[1]', N'ProductText.SEARCH_NAME.sl'),
    (N'SalesData/Warranty/text()[1]',         N'ProductAttribute.Garancija')
  ) AS field(SourceElement, TargetFieldCode)
  WHERE connector.IsActive = 1
    AND connector.SourceCode LIKE N'SAOP[_]%'
    AND connector.SourceCode NOT LIKE N'%[_]STOCK'
) AS source
  ON target.SourceConnectorId = source.SourceConnectorId
 AND target.EntityType = source.EntityType
 AND target.SourceElement = source.SourceElement
WHEN MATCHED THEN UPDATE SET
  TargetFieldCode = source.TargetFieldCode,
  IsRequired = 0,
  IsActive = 1,
  MappingVersion = CASE WHEN target.MappingVersion < 1 THEN 1 ELSE target.MappingVersion END
WHEN NOT MATCHED THEN
  INSERT (SourceConnectorId, EntityType, SourceElement, TargetFieldCode,
          IsRequired, IsActive, MappingVersion)
  VALUES (source.SourceConnectorId, source.EntityType, source.SourceElement,
          source.TargetFieldCode, 0, 1, 1);

/* --- 2) Izpeljano lastništvo iz že potrjene politike 068 -------------------------- */

MERGE out.OwnershipPolicy AS target
USING
(
  SELECT DISTINCT connector.OrganizationId,
         N'SAOP_PRODUCT' AS TargetKind,
         N'Product' AS EntityType,
         mapping.TargetFieldCode AS FieldName
  FROM map.FieldMapping AS mapping
  INNER JOIN map.SourceConnector AS connector
    ON connector.SourceConnectorId = mapping.SourceConnectorId
  WHERE connector.IsActive = 1
    AND connector.SourceCode LIKE N'SAOP[_]%'
    AND connector.SourceCode NOT LIKE N'%[_]STOCK'
    AND mapping.IsActive = 1
    AND mapping.SourceElement IN
      (N'GeneralData/ItemSearchName/text()[1]', N'SalesData/Warranty/text()[1]')
) AS source
  ON target.OrganizationId = source.OrganizationId
 AND target.TargetKind = source.TargetKind
 AND target.EntityType = source.EntityType
 AND target.FieldName = source.FieldName
 AND target.ConstraintValue IS NULL
WHEN MATCHED THEN UPDATE SET
  Owner = N'PIM',
  ConstraintKind = NULL,
  IsEnabled = 1,
  UpdatedUtc = SYSUTCDATETIME(),
  UpdatedBy = N'migracija 137 — politika iz 068'
WHEN NOT MATCHED THEN
  INSERT (OrganizationId, TargetKind, EntityType, FieldName, Owner,
          ConstraintKind, ConstraintValue, IsEnabled, UpdatedBy)
  VALUES (source.OrganizationId, source.TargetKind, source.EntityType,
          source.FieldName, N'PIM', NULL, NULL, 1,
          N'migracija 137 — politika iz 068');

/* --- 3) Pogodba odhodnega dokumenta -------------------------------------------------- */

MERGE out.SaopXmlField AS target
USING
(
  VALUES
    (N'GeneralData', N'ItemSearchName', N'ProductText.SEARCH_NAME.sl', 195, 0, N'text', NULL, NULL),
    (N'SalesData',   N'Warranty',       N'ProductAttribute.Garancija', 215, 0, N'text', NULL, NULL)
) AS source(Section, ElementName, FieldKey, SortOrder, IsAddMandatory,
            ValueFormat, TrueValue, FalseValue)
  ON target.TargetKind = N'SAOP_PRODUCT'
 AND target.Section = source.Section
 AND target.ElementName = source.ElementName
WHEN MATCHED THEN UPDATE SET
  FieldKey = source.FieldKey,
  SortOrder = source.SortOrder,
  IsAddMandatory = source.IsAddMandatory,
  ValueFormat = source.ValueFormat,
  TrueValue = source.TrueValue,
  FalseValue = source.FalseValue,
  IsEnabled = 1,
  UpdatedUtc = SYSUTCDATETIME(),
  UpdatedBy = N'migracija 137'
WHEN NOT MATCHED THEN
  INSERT (TargetKind, Section, ElementName, FieldKey, SortOrder,
          IsAddMandatory, ValueFormat, TrueValue, FalseValue, IsEnabled, UpdatedBy)
  VALUES (N'SAOP_PRODUCT', source.Section, source.ElementName, source.FieldKey,
          source.SortOrder, source.IsAddMandatory, source.ValueFormat,
          source.TrueValue, source.FalseValue, 1, N'migracija 137');

/* --- 4) Varovalke: preslikava, politika in dejanski rezultat procedure ---------------- */

DECLARE @ActiveSaopOrganizations int =
(
  SELECT COUNT(DISTINCT connector.OrganizationId)
  FROM map.SourceConnector AS connector
  WHERE connector.IsActive = 1
    AND connector.SourceCode LIKE N'SAOP[_]%'
    AND connector.SourceCode NOT LIKE N'%[_]STOCK'
);

IF @ActiveSaopOrganizations = 0
  THROW 52937, 'Ni aktivnega SAOP konektorja; preslikav polj ni mogoče dokazati.', 1;

IF
(
  SELECT COUNT(*)
  FROM map.FieldMapping AS mapping
  INNER JOIN map.SourceConnector AS connector
    ON connector.SourceConnectorId = mapping.SourceConnectorId
  WHERE connector.IsActive = 1
    AND connector.SourceCode LIKE N'SAOP[_]%'
    AND connector.SourceCode NOT LIKE N'%[_]STOCK'
    AND mapping.IsActive = 1
    AND
    (
      (mapping.SourceElement = N'GeneralData/ItemSearchName/text()[1]'
       AND mapping.TargetFieldCode = N'ProductText.SEARCH_NAME.sl')
      OR
      (mapping.SourceElement = N'SalesData/Warranty/text()[1]'
       AND mapping.TargetFieldCode = N'ProductAttribute.Garancija')
    )
) <> @ActiveSaopOrganizations * 2
  THROW 52938, 'Vsak aktivni SAOP konektor mora imeti obe povratni preslikavi.', 1;

IF
(
  SELECT COUNT(*)
  FROM out.SaopXmlField
  WHERE TargetKind = N'SAOP_PRODUCT' AND IsEnabled = 1
    AND
    (
      (Section = N'GeneralData' AND ElementName = N'ItemSearchName'
       AND FieldKey = N'ProductText.SEARCH_NAME.sl' AND SortOrder = 195)
      OR
      (Section = N'SalesData' AND ElementName = N'Warranty'
       AND FieldKey = N'ProductAttribute.Garancija' AND SortOrder = 215)
    )
) <> 2
  THROW 52939, 'Pogodba SAOP nima obeh novih polj s pravilnima kanoničnima kodama.', 1;

IF
(
  SELECT COUNT(*)
  FROM out.OwnershipPolicy AS policy
  WHERE policy.TargetKind = N'SAOP_PRODUCT'
    AND policy.EntityType = N'Product'
    AND policy.FieldName IN (N'ProductText.SEARCH_NAME.sl', N'ProductAttribute.Garancija')
    AND policy.Owner = N'PIM' AND policy.IsEnabled = 1
    AND policy.ConstraintKind IS NULL AND policy.ConstraintValue IS NULL
) <> @ActiveSaopOrganizations * 2
  THROW 52940, 'Iz preglednice izpeljano lastništvo obeh polj manjka za aktivno organizacijo.', 1;

CREATE TABLE #WritableSaopField
(
  FieldKey nvarchar(200) NOT NULL,
  ElementName nvarchar(100) NOT NULL,
  Section nvarchar(50) NOT NULL,
  ValueFormat nvarchar(30) NOT NULL,
  TrueValue nvarchar(20) NULL,
  FalseValue nvarchar(20) NULL,
  IsAddMandatory bit NOT NULL,
  SortOrder int NOT NULL,
  EntityType nvarchar(100) NOT NULL
);

DECLARE @OrganizationId int, @CheckedOrganizations int = 0;
DECLARE organization_cursor CURSOR LOCAL FAST_FORWARD FOR
  SELECT DISTINCT connector.OrganizationId
  FROM map.SourceConnector AS connector
  WHERE connector.IsActive = 1
    AND connector.SourceCode LIKE N'SAOP[_]%'
    AND connector.SourceCode NOT LIKE N'%[_]STOCK'
  ORDER BY connector.OrganizationId;

OPEN organization_cursor;
FETCH NEXT FROM organization_cursor INTO @OrganizationId;
WHILE @@FETCH_STATUS = 0
BEGIN
  SET @CheckedOrganizations += 1;
  INSERT #WritableSaopField
    EXEC intranet.GetWritableSaopFields
      @OrganizationId = @OrganizationId,
      @TargetKind = N'SAOP_PRODUCT';

  IF (SELECT COUNT(*) FROM #WritableSaopField
      WHERE FieldKey = N'ProductText.SEARCH_NAME.sl') <> @CheckedOrganizations
    THROW 52941, 'GetWritableSaopFields ne vrne Imena za iskanje za aktivno organizacijo.', 1;

  IF (SELECT COUNT(*) FROM #WritableSaopField
      WHERE FieldKey = N'ProductAttribute.Garancija') <> @CheckedOrganizations
    THROW 52942, 'GetWritableSaopFields ne vrne Garancije za aktivno organizacijo.', 1;

  FETCH NEXT FROM organization_cursor INTO @OrganizationId;
END;
CLOSE organization_cursor;
DEALLOCATE organization_cursor;
