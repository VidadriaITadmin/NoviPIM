/*
  217 - odstranitev opuščenih profilov ERP_L1 in WEB_B2C.

  Veljavna pravila so samostojni profili (ERP_L1_SLO, ERP_L1_EU,
  ERP_L1_THIRD, SHARED_CORE, WEB_svetila_si, WEB_videlektro …). Stara profila
  sta bila ostanek prvotnega izvoza in ne smeta več vplivati na validacijo,
  promocijo ali nadzorno ploščo.

  Odstranijo se tudi njuni izpeljani zahtevki, stanja in stari izvoz
  WEB_B2C_PRODUCTS. Vrstni red brisanja sledi tujim ključem; nobena vrstica
  drugega profila ni zajeta.
*/
SET XACT_ABORT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;

DECLARE @LegacyProfiles TABLE (ProfileCode nvarchar(100) NOT NULL PRIMARY KEY);
INSERT @LegacyProfiles(ProfileCode) VALUES (N'ERP_L1'), (N'WEB_B2C');

DECLARE @LegacyValidationProfileIds TABLE (ValidationProfileId int NOT NULL PRIMARY KEY);
INSERT @LegacyValidationProfileIds(ValidationProfileId)
SELECT profileValue.ValidationProfileId
FROM val.ValidationProfile AS profileValue
INNER JOIN @LegacyProfiles AS legacy ON legacy.ProfileCode = profileValue.ProfileCode;

DECLARE @LegacyExportProfileIds TABLE (ExportProfileId int NOT NULL PRIMARY KEY);
INSERT @LegacyExportProfileIds(ExportProfileId)
SELECT DISTINCT profileValue.ExportProfileId
FROM val.ValidationProfile AS profileValue
INNER JOIN @LegacyValidationProfileIds AS legacy ON legacy.ValidationProfileId = profileValue.ValidationProfileId
WHERE profileValue.ExportProfileId IS NOT NULL;

/* WEB_B2C_PRODUCTS je izvoz, ki je pripadal izključno profilu WEB_B2C. */
INSERT @LegacyExportProfileIds(ExportProfileId)
SELECT exportProfile.ExportProfileId
FROM out.ExportProfile AS exportProfile
WHERE exportProfile.ProfileCode = N'WEB_B2C_PRODUCTS'
  AND NOT EXISTS
  (
    SELECT 1 FROM @LegacyExportProfileIds AS legacy
    WHERE legacy.ExportProfileId = exportProfile.ExportProfileId
  );

BEGIN TRANSACTION;

DELETE issueValue
FROM val.ProductIssue AS issueValue
INNER JOIN @LegacyValidationProfileIds AS legacy
  ON legacy.ValidationProfileId = issueValue.ValidationProfileId;

DELETE stateValue
FROM val.ProductValidationState AS stateValue
INNER JOIN @LegacyValidationProfileIds AS legacy
  ON legacy.ValidationProfileId = stateValue.ValidationProfileId;

DELETE requirement
FROM val.FieldRequirement AS requirement
INNER JOIN @LegacyValidationProfileIds AS legacy
  ON legacy.ValidationProfileId = requirement.ValidationProfileId;

DELETE profileValue
FROM val.ValidationProfile AS profileValue
INNER JOIN @LegacyValidationProfileIds AS legacy
  ON legacy.ValidationProfileId = profileValue.ValidationProfileId;

DELETE exportColumn
FROM out.ExportColumn AS exportColumn
INNER JOIN @LegacyExportProfileIds AS legacy
  ON legacy.ExportProfileId = exportColumn.ExportProfileId;

DELETE exportProfile
FROM out.ExportProfile AS exportProfile
INNER JOIN @LegacyExportProfileIds AS legacy
  ON legacy.ExportProfileId = exportProfile.ExportProfileId;

COMMIT TRANSACTION;

/* Promocija brez izrecnega profila zdaj uporablja veljavno slovensko ERP pravilo. */
DECLARE @PromoteDefinition nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'val.Promote'));
IF @PromoteDefinition IS NULL
  THROW 53217, N'217: manjka val.Promote.', 1;

DECLARE @PromoteProcedurePosition int = PATINDEX(N'%PROCEDURE%', UPPER(@PromoteDefinition));
IF @PromoteProcedurePosition = 0
  THROW 53223, N'217: glava val.Promote ni veljavna.', 1;
SET @PromoteDefinition = STUFF(@PromoteDefinition, 1, @PromoteProcedurePosition - 1, N'ALTER ');
SET @PromoteDefinition = REPLACE(
  @PromoteDefinition,
  N'@ValidationProfileCode nvarchar(100) = N''ERP_L1''',
  N'@ValidationProfileCode nvarchar(100) = N''ERP_L1_SLO''');
SET @PromoteDefinition = REPLACE(
  @PromoteDefinition,
  N'@ValidationProfileCode nvarchar(100)=N''ERP_L1''',
  N'@ValidationProfileCode nvarchar(100)=N''ERP_L1_SLO''');

IF @PromoteDefinition LIKE N'%@ValidationProfileCode nvarchar(100) = N''ERP_L1''%'
  THROW 53218, N'217: privzetega profila val.Promote ni bilo mogoče zamenjati.', 1;
EXEC sys.sp_executesql @PromoteDefinition;

/* Stara procedura CSV ostane zaradi združljivosti, vendar nima več starega privzetega profila. */
DECLARE @CsvDefinition nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'out.ExportProductsCsv'));
IF @CsvDefinition IS NOT NULL
BEGIN
  DECLARE @CsvProcedurePosition int = PATINDEX(N'%PROCEDURE%', UPPER(@CsvDefinition));
  IF @CsvProcedurePosition = 0
    THROW 53224, N'217: glava out.ExportProductsCsv ni veljavna.', 1;
  SET @CsvDefinition = STUFF(@CsvDefinition, 1, @CsvProcedurePosition - 1, N'ALTER ');
  SET @CsvDefinition = REPLACE(
    @CsvDefinition,
    N'@ProfileCode nvarchar(100)=N''WEB_B2C_PRODUCTS''',
    N'@ProfileCode nvarchar(100)=N''MAGENTO_PRODUCTS''');
  IF @CsvDefinition LIKE N'%@ProfileCode nvarchar(100)=N''WEB_B2C_PRODUCTS''%'
    THROW 53219, N'217: privzetega profila out.ExportProductsCsv ni bilo mogoče zamenjati.', 1;
  EXEC sys.sp_executesql @CsvDefinition;
END;

/* Nadzorna plošča šteje aktivna pravila po namenu, ne po zgodovinski kodi. */
DECLARE @DashboardDefinition nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'intranet.GetDashboard'));
IF @DashboardDefinition IS NOT NULL
BEGIN
  DECLARE @DashboardProcedurePosition int = PATINDEX(N'%PROCEDURE%', UPPER(@DashboardDefinition));
  IF @DashboardProcedurePosition = 0
    THROW 53225, N'217: glava intranet.GetDashboard ni veljavna.', 1;
  SET @DashboardDefinition = STUFF(@DashboardDefinition, 1, @DashboardProcedurePosition - 1, N'ALTER ');
  SET @DashboardDefinition = REPLACE(
    @DashboardDefinition,
    N'profileValue.ProfileCode = N''ERP_L1'' AND stateValue.Status = N''VALID''',
    N'profileValue.IsActive = 1 AND profileValue.BlocksErp = 1 AND stateValue.Status = N''VALID''');
  SET @DashboardDefinition = REPLACE(
    @DashboardDefinition,
    N'profileValue.ProfileCode = N''WEB_B2C'' AND stateValue.Status = N''INVALID''',
    N'profileValue.IsActive = 1 AND profileValue.BlocksWeb = 1 AND stateValue.Status = N''INVALID''');
  IF @DashboardDefinition LIKE N'%ProfileCode = N''ERP_L1''%'
     OR @DashboardDefinition LIKE N'%ProfileCode = N''WEB_B2C''%'
    THROW 53220, N'217: stari profil je ostal v intranet.GetDashboard.', 1;
  EXEC sys.sp_executesql @DashboardDefinition;
END;

EXEC val.RunValidation;

IF EXISTS
(
  SELECT 1
  FROM val.ValidationProfile
  WHERE ProfileCode IN (N'ERP_L1', N'WEB_B2C')
)
  THROW 53221, N'217: stari validacijski profil ni odstranjen.', 1;

IF EXISTS
(
  SELECT 1
  FROM out.ExportProfile
  WHERE ProfileCode IN (N'ERP_L1', N'WEB_B2C_PRODUCTS')
)
  THROW 53222, N'217: stari izvozni profil ni odstranjen.', 1;
