/*
  266 — Validacijski profili: sprememba zahteve zadene natanko izbrano vrstico.

  Pregled 2026-09-22: intranet.SaveFieldRequirement (133) je zahtevo iskal samo po profilu in polju
  (TOP (1)). Spletna profila imata zahteve PO KATEGORIJAH (WEB_svetila_si 253 vrstic za 51 polj,
  WEB_videlektro 342 za 82), zato je preklop resnosti v eni vrstici spremenil naključno vrstico z
  istim poljem v drugi kategoriji; ob naslednjem shranjevanju nabora pa bi ga nabor tako ali tako
  povozil (canon.SaveCategoryAttributeSet: REQUIRED = ERROR, RECOMMENDED = WARNING).

  Popravek:
    1. Nov neobvezen parameter @FieldRequirementId: stran pošlje točno vrstico.
    2. Vrstica s kategorijo se ne ureja mimo nabora: napaka → atribut je v naboru kategorije
       »obvezen«, opozorilo → »priporočen«, umik → odstranjen iz nabora. Nabor in validacija
       tako ostaneta ena resnica; revizija in usklajevanje zahtev ostaneta v nabornem postopku.
    3. Nova zahteva brez vrstice velja za cel profil: obstoječa vrstica se išče samo med
       zahtevami brez kategorije, zato ne prevzame kategorijske vrstice z istim poljem.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

EXEC (N'
CREATE OR ALTER PROCEDURE intranet.SaveFieldRequirement
  @ValidationProfileId int,
  @FieldCode nvarchar(200),
  @Severity nvarchar(20) = N''ERROR'',
  @IsRequired bit = 1,
  @IsActive bit = 1,
  @ChangedBy nvarchar(200) = N''neznan'',
  @FieldRequirementId int = NULL
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

  DECLARE @Existing int, @TreeCode nvarchar(100), @CategoryCode nvarchar(200);
  IF @FieldRequirementId IS NOT NULL
  BEGIN
    SELECT @Existing = FieldRequirementId, @FieldCode = FieldCode, @TreeCode = CategoryTreeCode, @CategoryCode = CategoryCode
    FROM val.FieldRequirement
    WHERE FieldRequirementId = @FieldRequirementId AND ValidationProfileId = @ValidationProfileId;
    IF @Existing IS NULL THROW 51104, N''Zahteva ne pripada izbranemu profilu.'', 1;
  END
  ELSE
    SET @Existing = (
      SELECT TOP (1) FieldRequirementId FROM val.FieldRequirement
      WHERE ValidationProfileId = @ValidationProfileId AND FieldCode = @FieldCode AND CategoryCode IS NULL
      ORDER BY FieldRequirementId);

  /* 266: kategorijska zahteva nastane iz nabora atributov kategorije; spremeni se prek nabora. */
  IF @CategoryCode IS NOT NULL AND @FieldCode LIKE N''ProductAttribute.%''
  BEGIN
    DECLARE @AttributeName nvarchar(400) = SUBSTRING(@FieldCode, LEN(N''ProductAttribute.'') + 1, 400);
    DECLARE @AttributeCode nvarchar(200) = (
      SELECT TOP (1) translation.AttributeCode
      FROM canon.AttributeTranslation translation
      INNER JOIN canon.AttributeDefinition definition
        ON definition.AttributeCode = translation.AttributeCode AND definition.IsActive = 1
      WHERE translation.LanguageCode = N''sl'' AND translation.Name = @AttributeName
      ORDER BY translation.AttributeCode);

    IF @AttributeCode IS NOT NULL
    BEGIN
      DECLARE @Level nvarchar(20) =
        CASE WHEN @IsActive = 0 THEN NULL WHEN @Severity = N''ERROR'' THEN N''REQUIRED'' ELSE N''RECOMMENDED'' END;
      EXEC canon.SaveCategoryAttributeSet @CategoryTreeCode = @TreeCode, @CategoryCode = @CategoryCode,
        @AttributeCode = @AttributeCode, @Level = @Level, @Actor = @ChangedBy, @Note = N''Validacijski profili'';

      SELECT FieldRequirementId = @Existing, FieldKnown = CONVERT(bit, 1),
        IsActive = (SELECT IsActive FROM val.FieldRequirement WHERE FieldRequirementId = @Existing);
      RETURN;
    END;
  END;

  /* Zahteva nad kodo, ki je canon.FieldValue ne pozna, ne bi nikoli nastala kot napaka.
     Sprejmemo jo, a neaktivno - enako, kot ze danes cakajo zahteve na polje. */
  DECLARE @FieldKnown bit = CASE WHEN EXISTS
    (SELECT 1 FROM canon.FieldValue AS fieldValue WHERE fieldValue.FieldCode = @FieldCode)
    THEN 1 ELSE 0 END;
  DECLARE @EffectiveActive bit = CASE WHEN @FieldKnown = 0 THEN 0 ELSE @IsActive END;

  DECLARE @OldJson nvarchar(max) = (
    SELECT TOP (1) CONCAT(N''{"severity":"'', Severity, N''","required":'', CONVERT(nvarchar(5), IsRequired),
      N'',"active":'', CONVERT(nvarchar(5), IsActive), N''}'')
    FROM val.FieldRequirement WHERE FieldRequirementId = @Existing);

  IF @Existing IS NULL
  BEGIN
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

IF NOT EXISTS (SELECT 1 FROM sys.parameters WHERE object_id = OBJECT_ID(N'intranet.SaveFieldRequirement') AND name = N'@FieldRequirementId')
  THROW 52660, N'266: intranet.SaveFieldRequirement nima parametra @FieldRequirementId.', 1;
