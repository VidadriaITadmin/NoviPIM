/*
  133 — validacijske zahteve in preslikave polj se dajo urejati.

  Zahtevi uporabnika 2026-08-28:

    L1 »Validacijski profil – vreden mi je nacin, ni mi vsec dizajn, pa nic ne mores urejat.
        To bi bilo misljeno da uporabniki spreminjajo in da se potem validacija na podlagi
        tega dela. Treba je omogocit da dodajajo napake in opozorila.«
    L3 »Preslikave polj je misljeno dobro, samo ni mi vsec dizajn in pa ne morem nic urejati.
        Ni to misljeno da vemo od kje je polje prislo in kam se pise v PIM?«

  Obe strani sta bili bralni, ker ni bilo zapisovalne poti. Ta migracija jo doda — in nic vec:
  merila validacije ostanejo ista, spremeni se samo, kdo jih sme urejati.

  Kaj je pri tem pomembno:

  1. **Zahteva se ne brise.** val.ProductIssue kaze na FieldRequirementId; brisanje zahteve bi
     osirotelo tisoce odprtih napak. Umik zahteve je zato IsActive = 0 — zahteva ostane vidna
     na delovnem seznamu »Zahteve, ki cakajo na polje«, napake pa se ob naslednji validaciji
     zaprejo same.

  2. **Resnost je ERROR ali WARNING in nic drugega.** Ista omejitev kot v migraciji 047; tu je
     samo se enkrat preverjena, ker vrednost zdaj prihaja iz vmesnika.

  3. **Polje mora obstajati v canon.FieldValue.** Zahteva nad kodo, ki je pogled ne pozna, ne bi
     nikoli nastala kot napaka in bi bila tiha laz. Procedura tako zahtevo sprejme, a jo
     zapise kot neaktivno in to pove v izhodu — enako, kot ze danes cakajo zahteve na polje.

  4. **Preslikava ima svojo revizijo.** Obe proceduri pisata v b2b.AuditLog, ki ze obstaja in
     ga bere kartica stranke; nova tabela revizije bi bila drugi vir resnice.

  Migracija je ponovljiva: CREATE OR ALTER in preverjen dodatek stolpca.
*/

SET XACT_ABORT ON;

/* Preslikava polj do zdaj ni vedela, kdo jo je nazadnje spremenil. */
IF COL_LENGTH(N'map.FieldMapping', N'UpdatedBy') IS NULL
  ALTER TABLE map.FieldMapping ADD UpdatedBy nvarchar(200) NULL;

IF COL_LENGTH(N'map.FieldMapping', N'UpdatedUtc') IS NULL
  ALTER TABLE map.FieldMapping ADD UpdatedUtc datetime2(3) NULL;

/* --- 1) Urejanje validacijske zahteve --------------------------------------------------- */

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.SaveFieldRequirement
  @ValidationProfileId int,
  @FieldCode nvarchar(200),
  @Severity nvarchar(20) = N''ERROR'',
  @IsRequired bit = 1,
  @IsActive bit = 1,
  @ChangedBy nvarchar(200) = N''neznan''
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  SET @FieldCode = NULLIF(LTRIM(RTRIM(@FieldCode)), N'''');
  SET @Severity = UPPER(NULLIF(LTRIM(RTRIM(@Severity)), N''''));

  IF @FieldCode IS NULL THROW 51101, N''Zahteva brez polja ni zahteva.'', 1;
  IF @Severity IS NULL OR @Severity NOT IN (N''ERROR'', N''WARNING'')
    THROW 51102, N''Resnost je lahko samo ERROR ali WARNING.'', 1;

  DECLARE @ProfileCode nvarchar(100) = (
    SELECT ProfileCode FROM val.ValidationProfile WHERE ValidationProfileId = @ValidationProfileId);
  IF @ProfileCode IS NULL THROW 51103, N''Validacijski profil ne obstaja.'', 1;

  /* Zahteva nad kodo, ki je canon.FieldValue ne pozna, ne bi nikoli nastala kot napaka.
     Sprejmemo jo, a neaktivno — enako, kot ze danes cakajo zahteve na polje. */
  DECLARE @FieldKnown bit = CASE WHEN EXISTS
    (SELECT 1 FROM canon.FieldValue AS fieldValue WHERE fieldValue.FieldCode = @FieldCode)
    THEN 1 ELSE 0 END;
  DECLARE @EffectiveActive bit = CASE WHEN @FieldKnown = 0 THEN 0 ELSE @IsActive END;

  DECLARE @Existing int = (
    SELECT TOP (1) FieldRequirementId FROM val.FieldRequirement
    WHERE ValidationProfileId = @ValidationProfileId AND FieldCode = @FieldCode);

  DECLARE @OldJson nvarchar(max) = (
    SELECT TOP (1) CONCAT(N''{"severity":"'', Severity, N''","required":'', CONVERT(nvarchar(5), IsRequired),
      N'',"active":'', CONVERT(nvarchar(5), IsActive), N''}'')
    FROM val.FieldRequirement WHERE FieldRequirementId = @Existing);

  IF @Existing IS NULL
  BEGIN
    /* SourceExportColumnId sme biti NULL od migracije 047 naprej: zahteva ni nujno vezana
       na stolpec izvoza — lahko je poslovno pravilo, ki ga je vpisal uporabnik. */
    INSERT val.FieldRequirement (ValidationProfileId, SourceExportColumnId, FieldCode, IsRequired, IsActive, Severity)
    VALUES (@ValidationProfileId, NULL, @FieldCode, @IsRequired, @EffectiveActive, @Severity);
    SET @Existing = SCOPE_IDENTITY();
  END
  ELSE
    UPDATE val.FieldRequirement
    SET Severity = @Severity, IsRequired = @IsRequired, IsActive = @EffectiveActive
    WHERE FieldRequirementId = @Existing;

  INSERT b2b.AuditLog (OrganizationId, EntityType, EntityKey, ActionCode, OldValueJson, NewValueJson, ChangedBy, ChangedUtc)
  SELECT 0, N''FieldRequirement'', CONVERT(nvarchar(200), @Existing),
    CASE WHEN @OldJson IS NULL THEN N''ADD'' ELSE N''UPDATE'' END,
    @OldJson,
    CONCAT(N''{"profile":"'', @ProfileCode, N''","field":"'', @FieldCode, N''","severity":"'', @Severity,
      N''","required":'', CONVERT(nvarchar(5), @IsRequired), N'',"active":'', CONVERT(nvarchar(5), @EffectiveActive), N''}''),
    @ChangedBy, SYSUTCDATETIME();

  SELECT FieldRequirementId = @Existing, FieldKnown = @FieldKnown, IsActive = @EffectiveActive;
END;');

/* --- 2) Urejanje preslikave polja ------------------------------------------------------- */

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.SaveFieldMapping
  @FieldMappingId bigint = NULL,
  @OrganizationId int,
  @SourceCode nvarchar(100) = NULL,
  @EntityType nvarchar(100) = NULL,
  @SourceElement nvarchar(400) = NULL,
  @TargetFieldCode nvarchar(200) = NULL,
  @IsRequired bit = 0,
  @IsActive bit = 1,
  @ChangedBy nvarchar(200) = N''neznan''
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  SET @SourceElement = NULLIF(LTRIM(RTRIM(@SourceElement)), N'''');
  SET @TargetFieldCode = NULLIF(LTRIM(RTRIM(@TargetFieldCode)), N'''');

  DECLARE @OldJson nvarchar(max);

  IF @FieldMappingId IS NOT NULL
  BEGIN
    SELECT @OldJson = CONCAT(N''{"element":"'', mapping.SourceElement, N''","target":"'', mapping.TargetFieldCode,
      N''","required":'', CONVERT(nvarchar(5), mapping.IsRequired), N'',"active":'', CONVERT(nvarchar(5), mapping.IsActive), N''}'')
    FROM map.FieldMapping AS mapping WHERE mapping.FieldMappingId = @FieldMappingId;

    IF @OldJson IS NULL THROW 51104, N''Preslikava ne obstaja.'', 1;

    UPDATE map.FieldMapping
    SET TargetFieldCode = COALESCE(@TargetFieldCode, TargetFieldCode),
      SourceElement = COALESCE(@SourceElement, SourceElement),
      IsRequired = @IsRequired, IsActive = @IsActive,
      UpdatedBy = @ChangedBy, UpdatedUtc = SYSUTCDATETIME()
    WHERE FieldMappingId = @FieldMappingId;
  END
  ELSE
  BEGIN
    IF @SourceElement IS NULL OR @TargetFieldCode IS NULL
      THROW 51105, N''Nova preslikava potrebuje element vira in ciljno polje.'', 1;

    DECLARE @SourceConnectorId int = (
      SELECT TOP (1) SourceConnectorId FROM map.SourceConnector
      WHERE OrganizationId = @OrganizationId AND SourceCode = @SourceCode);
    IF @SourceConnectorId IS NULL THROW 51106, N''Vir tega podjetja ne obstaja.'', 1;

    INSERT map.FieldMapping (SourceConnectorId, EntityType, SourceElement, TargetFieldCode, IsRequired, IsActive, UpdatedBy, UpdatedUtc)
    VALUES (@SourceConnectorId, @EntityType, @SourceElement, @TargetFieldCode, @IsRequired, @IsActive, @ChangedBy, SYSUTCDATETIME());
    SET @FieldMappingId = SCOPE_IDENTITY();
  END

  INSERT b2b.AuditLog (OrganizationId, EntityType, EntityKey, ActionCode, OldValueJson, NewValueJson, ChangedBy, ChangedUtc)
  SELECT @OrganizationId, N''FieldMapping'', CONVERT(nvarchar(200), @FieldMappingId),
    CASE WHEN @OldJson IS NULL THEN N''ADD'' ELSE N''UPDATE'' END, @OldJson,
    CONCAT(N''{"element":"'', mapping.SourceElement, N''","target":"'', mapping.TargetFieldCode,
      N''","required":'', CONVERT(nvarchar(5), mapping.IsRequired), N'',"active":'', CONVERT(nvarchar(5), mapping.IsActive), N''}''),
    @ChangedBy, SYSUTCDATETIME()
  FROM map.FieldMapping AS mapping WHERE mapping.FieldMappingId = @FieldMappingId;

  SELECT FieldMappingId = @FieldMappingId;
END;');
