SET NOCOUNT ON;

/* 2026-09-16: ERP_L1 in WEB_B2C sta bila po uporabnikovi odlocitvi umaknjena iz validacije
   (nadomestila sta ju ERP_L1_EU/SLO/THIRD/SHARED_CORE in WEB_svetila_si/WEB_videlektro/
   SHARED_CORE) - preverba zdaj zahteva vsaj en aktiven blokirajoc profil na vsako stran, ne
   vec ti dve konkretni, zdaj neaktivni/nescinkovito imeni. */
IF (SELECT COUNT(*) FROM val.ValidationProfile WHERE BlocksErp = 1 AND IsActive = 1) < 1
  THROW 52101, 'F1 preverjanje: ni nobenega aktivnega validacijskega profila, ki bi blokiral ERP.', 1;
IF (SELECT COUNT(*) FROM val.ValidationProfile WHERE BlocksWeb = 1 AND IsActive = 1) < 1
  THROW 52104, 'F1 preverjanje: ni nobenega aktivnega validacijskega profila, ki bi blokiral splet.', 1;

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
