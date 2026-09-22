-- P3-17 iz docs/PREGLED_SISTEMA_IN_UX_2026-09-08.md: »sočasnost — rowversion na pim.* in
-- pričakovana vrednost v SaveProductTexts/Attributes; kartica pokaze konflikt s tujo vrednostjo«.
--
-- Danes dva urednika tiho prepiseta drug drugega: kartica poslje novo vrednost, procedura jo
-- zapise in nihce ne izve, da je nekdo vmes isto polje ze spremenil. Zgodovina to sicer zabelezi,
-- a sele potem, ko je delo izgubljeno.
--
-- Namesto `rowversion` na tabelah je merilo **pricakovana vrednost polja**. Razlog: `rowversion`
-- na `canon.ProductText` bi se spremenil ob vsakem zapisu katerekoli vrstice izdelka, tudi ce se
-- polje, ki ga urednik ureja, sploh ni dotaknilo — dobil bi lazne konflikte. Vrednost polja pove
-- natanko to, kar urednik vidi na zaslonu, in nic vec.
--
-- Zdruzljivost: `expected` je neobvezen. Kdor ga ne poslje (`hasExpected` odsoten ali 0), dobi
-- natanko dosedanje vedenje — tako uvoz delovnega zvezka, ki ima svoje pravilo »prazna celica =
-- ne dotakni se«, ostane nespremenjen. Kartica ga poslje vedno.
--
-- Konflikt ni napaka: sporne vrstice se **preskocijo**, ostale se zapisejo, drugi nabor pa vrne
-- polje in **tujo vrednost**, da jo kartica lahko pokaze. Vse ali nic bi pomenilo, da en konflikt
-- zavrze deset dobrih popravkov.

SET XACT_ABORT ON;

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

  DECLARE @Changes TABLE (Lang nvarchar(40) NOT NULL, TextType nvarchar(100) NOT NULL, Value nvarchar(max) NULL,
                          Expected nvarchar(max) NULL, HasExpected bit NOT NULL);
  INSERT @Changes (Lang, TextType, Value, Expected, HasExpected)
  SELECT LTRIM(RTRIM(parsed.lang)), UPPER(LTRIM(RTRIM(parsed.textType))), parsed.value,
         parsed.expected, CASE WHEN parsed.hasExpected = 1 THEN 1 ELSE 0 END
  FROM OPENJSON(@ChangesJson) WITH (lang nvarchar(40) N''$.lang'', textType nvarchar(100) N''$.textType'',
                                    value nvarchar(max) N''$.value'', expected nvarchar(max) N''$.expected'',
                                    hasExpected bit N''$.hasExpected'') AS parsed
  WHERE NULLIF(LTRIM(RTRIM(parsed.lang)), N'''') IS NOT NULL AND NULLIF(LTRIM(RTRIM(parsed.textType)), N'''') IS NOT NULL;

  /* Katero besedilo potuje v SAOP, ne odloca ime, ampak register out.SaopXmlField. */
  IF EXISTS
  (
    SELECT 1 FROM @Changes AS change
    INNER JOIN out.SaopXmlField AS field
      ON field.TargetKind = N''SAOP_PRODUCT'' AND field.IsEnabled = 1
     AND field.FieldKey = N''ProductText.'' + change.TextType + N''.'' + change.Lang
  )
    THROW 52402, N''To besedilo pise SAOP; sprememba mora skozi odhodno vrsto z odobritvijo.'', 1;

  -- Sporne vrstice: urednik je videl eno, v katalogu pa danes stoji drugo.
  DECLARE @Conflict TABLE (Lang nvarchar(40) NOT NULL, TextType nvarchar(100) NOT NULL,
                           Expected nvarchar(max) NULL, TheirValue nvarchar(max) NULL);
  INSERT @Conflict (Lang, TextType, Expected, TheirValue)
  SELECT change.Lang, change.TextType, change.Expected, current_.Value
  FROM @Changes AS change
  OUTER APPLY
  (
    SELECT TOP (1) textValue.Value
    FROM canon.ProductText AS textValue
    WHERE textValue.ProductId = @ProductId AND textValue.Lang = change.Lang AND textValue.TextType = change.TextType
  ) AS current_
  WHERE change.HasExpected = 1
    AND ISNULL(current_.Value, N'''') <> ISNULL(change.Expected, N'''');

  DELETE change FROM @Changes AS change
  INNER JOIN @Conflict AS conflict ON conflict.Lang = change.Lang AND conflict.TextType = change.TextType;

  DECLARE @BatchId uniqueidentifier = NEWID();
  EXEC pim.SetChangeContext @ChangeSource = N''INTRANET'', @ChangedBy = @Actor, @BatchId = @BatchId, @Note = @Note;

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
    ConflictCount = (SELECT COUNT_BIG(*) FROM @Conflict),
    ValidationStatus = product.ValidationStatus, Completeness = product.Completeness,
    OpenIssueCount = (SELECT COUNT_BIG(*) FROM val.ProductIssue AS issue WHERE issue.ProductId = @ProductId AND issue.IsActive = 1)
  FROM canon.Product AS product WHERE product.ProductId = @ProductId;

  SELECT FieldKey = CONCAT(N''ProductText.'', TextType, N''.'', Lang), Expected, TheirValue FROM @Conflict;
END;
');

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

  DECLARE @Changes TABLE (AttributeCode nvarchar(200) NOT NULL PRIMARY KEY, Value nvarchar(max) NULL,
                          Expected nvarchar(max) NULL, HasExpected bit NOT NULL);
  INSERT @Changes (AttributeCode, Value, Expected, HasExpected)
  SELECT LTRIM(RTRIM(parsed.attributeCode)), parsed.value, parsed.expected,
         CASE WHEN parsed.hasExpected = 1 THEN 1 ELSE 0 END
  FROM OPENJSON(@ChangesJson) WITH (attributeCode nvarchar(200) N''$.attributeCode'', value nvarchar(max) N''$.value'',
                                    expected nvarchar(max) N''$.expected'', hasExpected bit N''$.hasExpected'') AS parsed
  WHERE NULLIF(LTRIM(RTRIM(parsed.attributeCode)), N'''') IS NOT NULL;

  DECLARE @Conflict TABLE (AttributeCode nvarchar(200) NOT NULL PRIMARY KEY,
                           Expected nvarchar(max) NULL, TheirValue nvarchar(max) NULL);
  INSERT @Conflict (AttributeCode, Expected, TheirValue)
  SELECT change.AttributeCode, change.Expected, current_.Value
  FROM @Changes AS change
  OUTER APPLY
  (
    SELECT TOP (1) attributeValue.Value
    FROM canon.ProductAttribute AS attributeValue
    WHERE attributeValue.ProductId = @ProductId AND attributeValue.AttributeCode = change.AttributeCode
    ORDER BY attributeValue.ProductAttributeId
  ) AS current_
  WHERE change.HasExpected = 1
    AND ISNULL(current_.Value, N'''') <> ISNULL(change.Expected, N'''');

  DELETE change FROM @Changes AS change
  INNER JOIN @Conflict AS conflict ON conflict.AttributeCode = change.AttributeCode;

  DECLARE @BatchId uniqueidentifier = NEWID();
  EXEC pim.SetChangeContext @ChangeSource = N''INTRANET'', @ChangedBy = @Actor, @BatchId = @BatchId, @Note = @Note;

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
    ConflictCount = (SELECT COUNT_BIG(*) FROM @Conflict),
    ValidationStatus = product.ValidationStatus, Completeness = product.Completeness,
    OpenIssueCount = (SELECT COUNT_BIG(*) FROM val.ProductIssue AS issue WHERE issue.ProductId = @ProductId AND issue.IsActive = 1)
  FROM canon.Product AS product WHERE product.ProductId = @ProductId;

  SELECT FieldKey = CONCAT(N''ProductAttribute.'', AttributeCode), Expected, TheirValue FROM @Conflict;
END;
');
