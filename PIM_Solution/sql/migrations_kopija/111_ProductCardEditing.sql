/*
  111 — kartica izdelka postane urejiva.

  Do zdaj je bila kartica bralna: seznam je pisal »urejanje polja je na kartici izdelka«,
  kartica pa ni imela nobene zapisovalne poti. Vse, kar je uporabnik lahko spremenil, je šlo
  skozi /izvozi/mnozicno, torej prek šifre artikla in imena polja, brez izdelka pred sabo.

  Ta migracija doda tisto, česar za urejanje na kartici manjka, in nič več:

  1. **val.RunValidation dobi @ProductId.** Prej je znala samo celo podjetje: nad podjetjem 1
     (17.425 izdelkov) teče 26 sekund, nad podjetjem 2 (111.068) več. Po popravku enega polja
     tega ni mogoče počakati, brez tega pa kartica po shranjevanju kaže staro stanje. Filter je
     dodan na istih petih mestih kot @OrganizationId; brez @ProductId se obnaša natanko kot prej.

  2. **pim.SaveProductTexts** in **pim.SaveProductAttributes** — zapis podatka, ki je last PIM.
     Zavestno ozko: besedila samo vrste WEB_*, ker ERP naziv (TITLE_ERP) piše SAOP in mora iti
     skozi odhodno vrsto z odobritvijo, ne mimo nje. Kdor poskusi zapisati kaj drugega, dobi
     napako, ne tihe zavrnitve.

  Zgodovine ni treba pisati ročno: canon.ProductText in canon.ProductAttribute imata sprožilca
  TR_ProductText_FieldHistory in TR_ProductAttribute_FieldHistory, ki zapišeta staro in novo
  vrednost v pim.ProductFieldHistory. Zato obe proceduri najprej nastavita pim.SetChangeContext
  (kdo, od kod, zakaj) in ga na koncu počistita — sicer bi bila zgodovina brez avtorja.

  Prazna vrednost pomeni izbris vrstice, ne praznega niza: validacija šteje NULLIF(Value, '')
  kot manjkajoče, dve poti do istega pomena pa bi bili dve poti do iste napake.
*/

SET XACT_ABORT ON;

EXEC(N'
CREATE OR ALTER PROCEDURE val.RunValidation
  @OrganizationId int = NULL,
  @ProductId bigint = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;
  BEGIN TRY
    BEGIN TRANSACTION;
    ;WITH RequiredField AS
    (
      SELECT product.ProductId, profile.ValidationProfileId, requirement.FieldRequirementId, requirement.FieldCode
      FROM canon.Product product
      CROSS JOIN val.ValidationProfile profile
      INNER JOIN val.FieldRequirement requirement ON requirement.ValidationProfileId = profile.ValidationProfileId
      WHERE product.IsActive = 1 AND profile.IsActive = 1 AND requirement.IsActive = 1 AND requirement.IsRequired = 1
        AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
        AND (@ProductId IS NULL OR product.ProductId = @ProductId)
    ), MissingField AS
    (
      SELECT requiredField.*
      FROM RequiredField requiredField
      WHERE NOT EXISTS
      (
        SELECT 1 FROM canon.FieldValue fieldValue
        WHERE fieldValue.ProductId = requiredField.ProductId
          AND fieldValue.FieldCode = requiredField.FieldCode
          AND NULLIF(fieldValue.Value, N'''') IS NOT NULL
      )
    )
    MERGE val.ProductIssue AS target
    USING MissingField AS source
    ON target.ProductId = source.ProductId AND target.FieldRequirementId = source.FieldRequirementId
    WHEN MATCHED THEN UPDATE SET ValidationProfileId = source.ValidationProfileId, IssueCode = N''MISSING_REQUIRED_FIELD'', Message = CONCAT(N''Manjka obvezno polje: '', source.FieldCode), IsActive = 1, LastDetectedUtc = SYSUTCDATETIME(), ResolvedUtc = NULL
    WHEN NOT MATCHED THEN INSERT (ProductId, ValidationProfileId, FieldRequirementId, IssueCode, Message) VALUES (source.ProductId, source.ValidationProfileId, source.FieldRequirementId, N''MISSING_REQUIRED_FIELD'', CONCAT(N''Manjka obvezno polje: '', source.FieldCode));

    UPDATE issue SET IsActive = 0, ResolvedUtc = SYSUTCDATETIME()
    FROM val.ProductIssue issue
    INNER JOIN canon.Product product ON product.ProductId = issue.ProductId
    WHERE issue.IsActive = 1
      AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
      AND (@ProductId IS NULL OR product.ProductId = @ProductId)
      AND NOT EXISTS
      (
        SELECT 1 FROM val.FieldRequirement requirement
        WHERE requirement.FieldRequirementId = issue.FieldRequirementId AND requirement.IsActive = 1 AND requirement.IsRequired = 1
          AND NOT EXISTS (SELECT 1 FROM canon.FieldValue fieldValue WHERE fieldValue.ProductId = product.ProductId AND fieldValue.FieldCode = requirement.FieldCode AND NULLIF(fieldValue.Value, N'''') IS NOT NULL)
      );

    /*
      Stopnja resnosti odloca o statusu, ne o tem, ali se pomanjkljivost zabelezi (047).
      WARNING se se vedno zapise kot val.ProductIssue — urednik ga vidi — a profila ne
      postavi na INVALID. Popolnost se steje po vseh aktivnih zahtevkih.
    */
    ;WITH ProfileScore AS
    (
      SELECT product.ProductId, profile.ValidationProfileId,
        CAST(100.0 * (COUNT(requirement.FieldRequirementId) - SUM(CASE WHEN issue.ProductIssueId IS NULL THEN 0 ELSE 1 END)) / NULLIF(COUNT(requirement.FieldRequirementId), 0) AS decimal(5,2)) AS Completeness,
        CASE WHEN SUM(CASE WHEN issue.ProductIssueId IS NOT NULL AND requirement.Severity = N''ERROR'' THEN 1 ELSE 0 END) = 0
          THEN N''VALID'' ELSE N''INVALID'' END AS Status
      FROM canon.Product product
      CROSS JOIN val.ValidationProfile profile
      INNER JOIN val.FieldRequirement requirement ON requirement.ValidationProfileId = profile.ValidationProfileId AND requirement.IsActive = 1 AND requirement.IsRequired = 1
      LEFT JOIN val.ProductIssue issue ON issue.ProductId = product.ProductId AND issue.FieldRequirementId = requirement.FieldRequirementId AND issue.IsActive = 1
      WHERE product.IsActive = 1 AND profile.IsActive = 1
        AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
        AND (@ProductId IS NULL OR product.ProductId = @ProductId)
      GROUP BY product.ProductId, profile.ValidationProfileId
    )
    MERGE val.ProductValidationState AS target
    USING ProfileScore AS source ON target.ProductId = source.ProductId AND target.ValidationProfileId = source.ValidationProfileId
    WHEN MATCHED THEN UPDATE SET Status = source.Status, Completeness = source.Completeness, ValidatedUtc = SYSUTCDATETIME()
    WHEN NOT MATCHED THEN INSERT (ProductId, ValidationProfileId, Status, Completeness, ValidatedUtc) VALUES (source.ProductId, source.ValidationProfileId, source.Status, source.Completeness, SYSUTCDATETIME());

    /*
      Skupni status artikla poslusa samo profile, ki kaj blokirajo. COMMERCIAL_L2 je izrecno
      oznacen kot profil, ki ne blokira ne ERP ne spleta.
    */
    UPDATE product
    SET ValidationStatus =
        CASE WHEN EXISTS
        (
          SELECT 1 FROM val.ProductIssue issue
          INNER JOIN val.FieldRequirement requirement ON requirement.FieldRequirementId = issue.FieldRequirementId
          INNER JOIN val.ValidationProfile profile ON profile.ValidationProfileId = issue.ValidationProfileId
          WHERE issue.ProductId = product.ProductId AND issue.IsActive = 1
            AND requirement.Severity = N''ERROR''
            AND (profile.BlocksErp = 1 OR profile.BlocksWeb = 1)
        ) THEN N''INVALID'' ELSE N''VALID'' END,
        Completeness = ISNULL
        ((
          SELECT MIN(state.Completeness) FROM val.ProductValidationState state
          INNER JOIN val.ValidationProfile profile ON profile.ValidationProfileId = state.ValidationProfileId
          WHERE state.ProductId = product.ProductId AND (profile.BlocksErp = 1 OR profile.BlocksWeb = 1)
        ), 0),
        LastValidatedUtc = SYSUTCDATETIME()
    FROM canon.Product product
    WHERE product.IsActive = 1
      AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
      AND (@ProductId IS NULL OR product.ProductId = @ProductId);

    COMMIT TRANSACTION;
  END TRY
  BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    DECLARE @ErrorMessage nvarchar(4000) = ERROR_MESSAGE();
    EXEC ops.LogError @Layer = N''val'', @Severity = N''Error'', @ErrorCode = N''RUN_VALIDATION_FAILED'', @Message = @ErrorMessage;
    THROW;
  END CATCH;
END;');

EXEC(N'
CREATE OR ALTER PROCEDURE pim.SaveProductTexts
  @OrganizationId int,
  @ProductId bigint,
  @ChangesJson nvarchar(max),
  @Actor nvarchar(200),
  @Note nvarchar(400) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  IF NOT EXISTS (SELECT 1 FROM canon.Product WHERE ProductId = @ProductId AND OrganizationId = @OrganizationId)
    THROW 52401, N''Izdelek ne obstaja v tem podjetju.'', 1;

  DECLARE @Changes TABLE (Lang nvarchar(40) NOT NULL, TextType nvarchar(100) NOT NULL, Value nvarchar(max) NULL);
  INSERT @Changes (Lang, TextType, Value)
  SELECT LTRIM(RTRIM(parsed.lang)), UPPER(LTRIM(RTRIM(parsed.textType))), parsed.value
  FROM OPENJSON(@ChangesJson) WITH (lang nvarchar(40) N''$.lang'', textType nvarchar(100) N''$.textType'', value nvarchar(max) N''$.value'') AS parsed
  WHERE NULLIF(LTRIM(RTRIM(parsed.lang)), N'''') IS NOT NULL AND NULLIF(LTRIM(RTRIM(parsed.textType)), N'''') IS NOT NULL;

  /* Katero besedilo potuje v SAOP, ne odloca ime, ampak register out.SaopXmlField. ERP naziv
     (TITLE_ERP) je tam; zapisan mimo odhodne vrste bi ga naslednji zajem tiho povozil, SAOP pa
     o spremembi ne bi vedel nic. Zato glasna napaka namesto tihe zavrnitve. */
  IF EXISTS
  (
    SELECT 1 FROM @Changes AS change
    INNER JOIN out.SaopXmlField AS field
      ON field.TargetKind = N''SAOP_PRODUCT'' AND field.IsEnabled = 1
     AND field.FieldKey = N''ProductText.'' + change.TextType + N''.'' + change.Lang
  )
    THROW 52402, N''To besedilo pise SAOP; sprememba mora skozi odhodno vrsto z odobritvijo.'', 1;

  DECLARE @BatchId uniqueidentifier = NEWID();
  EXEC pim.SetChangeContext @ChangeSource = N''INTRANET'', @ChangedBy = @Actor, @BatchId = @BatchId,
    @Note = @Note;

  BEGIN TRY
    BEGIN TRANSACTION;

    DELETE textValue
    FROM canon.ProductText AS textValue
    INNER JOIN @Changes AS change ON change.Lang = textValue.Lang AND change.TextType = textValue.TextType
    WHERE textValue.ProductId = @ProductId AND NULLIF(LTRIM(RTRIM(change.Value)), N'''') IS NULL;

    MERGE canon.ProductText AS target
    USING (SELECT Lang, TextType, Value FROM @Changes WHERE NULLIF(LTRIM(RTRIM(Value)), N'''') IS NOT NULL) AS source
    ON target.ProductId = @ProductId AND target.Lang = source.Lang AND target.TextType = source.TextType
    WHEN MATCHED AND ISNULL(target.Value, N'''') <> source.Value THEN UPDATE SET Value = source.Value
    WHEN NOT MATCHED THEN INSERT (ProductId, Lang, TextType, Value) VALUES (@ProductId, source.Lang, source.TextType, source.Value);

    COMMIT TRANSACTION;
  END TRY
  BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    EXEC pim.ClearChangeContext;
    THROW;
  END CATCH;

  EXEC pim.ClearChangeContext;
  EXEC val.RunValidation @OrganizationId = @OrganizationId, @ProductId = @ProductId;

  SELECT ChangedCount = (SELECT COUNT_BIG(*) FROM @Changes),
    ValidationStatus = product.ValidationStatus, Completeness = product.Completeness,
    OpenIssueCount = (SELECT COUNT_BIG(*) FROM val.ProductIssue AS issue WHERE issue.ProductId = @ProductId AND issue.IsActive = 1)
  FROM canon.Product AS product WHERE product.ProductId = @ProductId;
END;');

EXEC(N'
CREATE OR ALTER PROCEDURE pim.SaveProductAttributes
  @OrganizationId int,
  @ProductId bigint,
  @ChangesJson nvarchar(max),
  @Actor nvarchar(200),
  @Note nvarchar(400) = NULL
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  IF NOT EXISTS (SELECT 1 FROM canon.Product WHERE ProductId = @ProductId AND OrganizationId = @OrganizationId)
    THROW 52401, N''Izdelek ne obstaja v tem podjetju.'', 1;

  DECLARE @Changes TABLE (AttributeCode nvarchar(200) NOT NULL PRIMARY KEY, Value nvarchar(max) NULL);
  INSERT @Changes (AttributeCode, Value)
  SELECT LTRIM(RTRIM(parsed.attributeCode)), parsed.value
  FROM OPENJSON(@ChangesJson) WITH (attributeCode nvarchar(200) N''$.attributeCode'', value nvarchar(max) N''$.value'') AS parsed
  WHERE NULLIF(LTRIM(RTRIM(parsed.attributeCode)), N'''') IS NOT NULL;

  DECLARE @BatchId uniqueidentifier = NEWID();
  EXEC pim.SetChangeContext @ChangeSource = N''INTRANET'', @ChangedBy = @Actor, @BatchId = @BatchId,
    @Note = @Note;

  BEGIN TRY
    BEGIN TRANSACTION;

    DELETE attributeValue
    FROM canon.ProductAttribute AS attributeValue
    INNER JOIN @Changes AS change ON change.AttributeCode = attributeValue.AttributeCode
    WHERE attributeValue.ProductId = @ProductId AND NULLIF(LTRIM(RTRIM(change.Value)), N'''') IS NULL;

    MERGE canon.ProductAttribute AS target
    USING (SELECT AttributeCode, Value FROM @Changes WHERE NULLIF(LTRIM(RTRIM(Value)), N'''') IS NOT NULL) AS source
    ON target.ProductId = @ProductId AND target.AttributeCode = source.AttributeCode
    WHEN MATCHED AND ISNULL(target.Value, N'''') <> source.Value THEN UPDATE SET Value = source.Value
    WHEN NOT MATCHED THEN INSERT (ProductId, AttributeCode, Value) VALUES (@ProductId, source.AttributeCode, source.Value);

    COMMIT TRANSACTION;
  END TRY
  BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    EXEC pim.ClearChangeContext;
    THROW;
  END CATCH;

  EXEC pim.ClearChangeContext;
  EXEC val.RunValidation @OrganizationId = @OrganizationId, @ProductId = @ProductId;

  SELECT ChangedCount = (SELECT COUNT_BIG(*) FROM @Changes),
    ValidationStatus = product.ValidationStatus, Completeness = product.Completeness,
    OpenIssueCount = (SELECT COUNT_BIG(*) FROM val.ProductIssue AS issue WHERE issue.ProductId = @ProductId AND issue.IsActive = 1)
  FROM canon.Product AS product WHERE product.ProductId = @ProductId;
END;');
