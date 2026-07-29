SET NOCOUNT ON;

IF (SELECT COUNT(*) FROM val.ValidationProfile WHERE ProfileCode IN (N'ERP_L1', N'WEB_B2C') AND IsActive = 1) <> 2
  THROW 52101, 'F1 preverjanje: manjkajo aktivni validacijski profili.', 1;

IF EXISTS
(
  SELECT 1
  FROM out.ExportColumn exportColumn
  INNER JOIN val.ValidationProfile validationProfile ON validationProfile.ExportProfileId = exportColumn.ExportProfileId
  WHERE exportColumn.IsActive = 1
    AND exportColumn.IsRequired = 1
    AND NOT EXISTS
    (
      SELECT 1
      FROM val.FieldRequirement requirement
      WHERE requirement.ValidationProfileId = validationProfile.ValidationProfileId
        AND requirement.SourceExportColumnId = exportColumn.ExportColumnId
        AND requirement.FieldCode = exportColumn.CanonicalFieldCode
        AND requirement.IsRequired = 1
        AND requirement.IsActive = 1
    )
)
  THROW 52102, 'F1 preverjanje: izvozni stolpec nima skladnega generiranega zahtevka.', 1;

IF EXISTS
(
  SELECT 1
  FROM val.FieldRequirement requirement
  INNER JOIN val.ValidationProfile validationProfile ON validationProfile.ValidationProfileId = requirement.ValidationProfileId
  LEFT JOIN out.ExportColumn exportColumn ON exportColumn.ExportColumnId = requirement.SourceExportColumnId
    AND exportColumn.ExportProfileId = validationProfile.ExportProfileId
  WHERE requirement.IsActive = 1
    AND (exportColumn.ExportColumnId IS NULL OR exportColumn.IsActive = 0)
)
  THROW 52103, 'F1 preverjanje: najden je aktivni zahtevek brez aktivnega izvoznega stolpca.', 1;

PRINT 'F1 preverjanje MSSQL je uspešno.';
