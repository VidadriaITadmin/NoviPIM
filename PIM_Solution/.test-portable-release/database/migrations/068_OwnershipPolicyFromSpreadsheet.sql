/*
  068 — C8: kdo je lastnik polja, iz stolpcev "Smer" in "Master" tvoje preglednice.

  Zakaj to ni kozmetika: out.EnqueueMessage zavrne vsako odhodno spremembo, za katero ni vrstice
  v out.OwnershipPolicy z Owner = 'PIM' (napaka 51010). Tabela je bila prazna, zato odhodna pot
  doslej ni mogla poslati nicesar — out.OutboxMessage ima 0 vrstic. To je tisti manjkajoci kos,
  ne dispatcher.

  Vir je Mapiranje_SAOP_API_PIM.xlsx: 259 polj ima zapisano smer. Pisljivih je 50
  ("obojesmerno" ali "PIM -> SAOP"); ostalo je "samo RAW" ali "SAOP -> PIM".

  Pravilo O9 — polje, ki ga ne beremo nazaj, ne sme biti zapisljivo — je tu izvedeno tako, da
  pravica nastane samo za polja, ki imajo aktivno vhodno preslikavo. Ce polja ne beremo, ne
  moremo preveriti, ali je SAOP naso spremembo sprejel; taka pravica bi bila slepa.

  Kar nastane:
    Owner = 'PIM'   polje je pisljivo po preglednici IN ga beremo nazaj;
    Owner = 'SAOP'  polje beremo, a po preglednici ni pisljivo — vrstica obstaja zato, da je
                    pravilo vidno in da se zavrnitev da razloziti.

  Kar NI zajeto: stranke (list "Stranke", 10 pisljivih polj). Odhodna pot za stranke danes ne
  obstaja — TargetKind bi bil SAOP_CUSTOMER, procedura, dispatcher in echo pa so narejeni za
  izdelke. Ko bo pot obstajala, se doda po istem vzorcu.
*/

SET XACT_ABORT ON;

/* Pisljive poti iz preglednice; zapisane tako, kot jih ima map.FieldMapping.SourceElement. */
DECLARE @Pisljivo TABLE(SourceElement nvarchar(400) PRIMARY KEY);
INSERT @Pisljivo(SourceElement) VALUES
  (N'ItemID'),
  (N'ItemTitle1'),
  (N'ItemTitle2'),
  (N'SuggestFirstFreeCode'),
  (N'GeneralData/ItemType'),
  (N'GeneralData/ItemUnitOfMeas'),
  (N'GeneralData/VATRateID'),
  (N'GeneralData/ItemGroup'),
  (N'GeneralData/WebPublish'),
  (N'GeneralData/ItemSearchName'),
  (N'GeneralData/CustomsTariffNo'),
  (N'GeneralData/ItemEANCode'),
  (N'GeneralData/ItemDepartment'),
  (N'GeneralData/AccountingBookGroupID'),
  (N'SalesData/Warranty'),
  (N'SalesData/DiscountGroup1ID'),
  (N'SalesData/IsActive'),
  (N'SalesData/AdditionalProperty1ID'),
  (N'SalesData/AdditionalProperty4ID'),
  (N'StockData/SupplierID'),
  (N'StockData/ManufacturerID'),
  (N'PropertiesData/ItemCountryOfOrigin'),
  (N'PropertiesData/ItemDimensionUOM'),
  (N'PropertiesData/ItemGrossWeight'),
  (N'PropertiesData/ItemHeight'),
  (N'PropertiesData/ItemWeightPerUnit'),
  (N'PropertiesData/ItemWidth'),
  (N'ItemDescription/ItemDescription'),
  /* Preglednica polje imenuje po DTO ('ItemDescription/ItemDescription'), odgovor SAOP pa ga
     nosi na poti 'Descriptions/Description'. Isto polje, dve imeni; preslikava bere pravo. */
  (N'Descriptions/Description'),
  (N'ItemDescription/DescriptionType'),
  (N'ItemDescription/LanguageID'),
  (N'ItemTitleLanguage/ItemTitle1'),
  (N'ItemTitleLanguage/ItemTitle2'),
  (N'ItemTitleLanguage/LanguageID'),
  (N'ItemCustomProperty/PropertyID'),
  (N'ItemCustomProperty/PropertyValue'),
  (N'ItemPlanningData/ItemExcludeQtyReservation');

/* Vsako polje, ki ga beremo, dobi vrstico; pravico do pisanja samo tisto, ki je v preglednici. */
;WITH beremo AS
(
  SELECT DISTINCT connector.OrganizationId,
    mapping.TargetFieldCode,
    /* SourceElement nosi se '/text()[1]'; primerjamo pot brez njega. */
    REPLACE(mapping.SourceElement, N'/text()[1]', N'') AS Pot
  FROM map.FieldMapping mapping
  INNER JOIN map.SourceConnector connector ON connector.SourceConnectorId = mapping.SourceConnectorId
  WHERE connector.SourceCode LIKE N'SAOP[_]%' AND connector.SourceCode NOT LIKE N'%[_]STOCK'
    AND connector.IsActive = 1 AND mapping.IsActive = 1
    AND mapping.TargetFieldCode NOT LIKE N'Warehouse.%'
),
pravica AS
(
  SELECT beremo.OrganizationId, beremo.TargetFieldCode,
    CASE WHEN EXISTS(SELECT 1 FROM @Pisljivo pisljivo WHERE pisljivo.SourceElement = beremo.Pot)
      THEN N'PIM' ELSE N'SAOP' END AS Owner
  FROM beremo
),
zdruzeno AS
(
  /* Isto polje lahko pride iz vec entitet (ItemID iz splosnih podatkov in iz cen); ce je
     pisljivo kjerkoli, je pisljivo. */
  SELECT OrganizationId, TargetFieldCode, MIN(Owner) AS Owner
  FROM pravica GROUP BY OrganizationId, TargetFieldCode
)
MERGE out.OwnershipPolicy AS target
USING
(
  SELECT OrganizationId, N'SAOP_PRODUCT' AS TargetKind, N'Product' AS EntityType,
    TargetFieldCode AS FieldName, Owner
  FROM zdruzeno
) source
  ON target.OrganizationId = source.OrganizationId AND target.TargetKind = source.TargetKind
    AND target.EntityType = source.EntityType AND target.FieldName = source.FieldName
    AND target.ConstraintValue IS NULL
WHEN MATCHED THEN UPDATE SET Owner = source.Owner, IsEnabled = 1, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = N'migracija 068'
WHEN NOT MATCHED THEN INSERT (OrganizationId, TargetKind, EntityType, FieldName, Owner, IsEnabled, UpdatedBy)
  VALUES (source.OrganizationId, source.TargetKind, source.EntityType, source.FieldName, source.Owner, 1, N'migracija 068');

/* --- preverbe -------------------------------------------------------------- */

/* O9: pravica do pisanja brez vhodne preslikave ne sme obstajati. */
IF EXISTS
(
  SELECT 1 FROM out.OwnershipPolicy policy
  WHERE policy.Owner = N'PIM' AND policy.TargetKind = N'SAOP_PRODUCT' AND policy.IsEnabled = 1
    AND NOT EXISTS
    (
      SELECT 1
      FROM map.FieldMapping mapping
      INNER JOIN map.SourceConnector connector ON connector.SourceConnectorId = mapping.SourceConnectorId
      WHERE connector.OrganizationId = policy.OrganizationId AND connector.SourceCode LIKE N'SAOP[_]%'
        AND connector.SourceCode NOT LIKE N'%[_]STOCK' AND mapping.IsActive = 1
        AND mapping.TargetFieldCode = policy.FieldName
    )
)
  THROW 52681, 'Polje ima pravico do pisanja, a ga ne beremo nazaj (O9).', 1;

IF (SELECT COUNT(*) FROM out.OwnershipPolicy WHERE TargetKind = N'SAOP_PRODUCT' AND Owner = N'PIM' AND IsEnabled = 1) < 40
  THROW 52682, 'Pravic do pisanja je premalo; preslikave ali seznam poti se ne ujemata.', 1;

IF NOT EXISTS (SELECT 1 FROM out.OwnershipPolicy WHERE Owner = N'SAOP')
  THROW 52683, 'Nobeno polje ni zabelezeno kot samo za branje; pravilo O9 tako ni vidno.', 1;
