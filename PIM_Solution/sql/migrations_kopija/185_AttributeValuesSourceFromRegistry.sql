-- Popravek migracije 184, ki je bila izmerjena in je padla na hitrosti.
--
-- 184 je vir vrednosti iskala z korelirano podpoizvedbo `TOP (1)` nad `map.ExtractedValue`.
-- Ta tabela ima **20.252.420 vrstic** in nima indeksa na `TargetFieldCode`, zato je vsaka vrstica
-- strani sprozila svoj pregled cele tabele. Merjeno: `@Take = 5` 784 ms, `@Take = 50` pa
-- **96.506 ms** za podjetje 1 in **271.595 ms** za podjetje 2. Stran je zato obtičala na 60 s.
--
-- Indeksa na `map.ExtractedValue` namenoma ne dodajam: to je vhodna tabela, v katero zajem pise
-- v velikih svezenjih, indeks nad `TargetFieldCode` z vkljucenim `Value` pa bi vsak zapis podrazil.
--
-- Namesto tega vir pride iz **registra**: kateri konektorji tega podjetja sploh imajo preslikavo
-- za ta atribut (`map.FieldMapping` + `map.SourceConnector`). To je majhna poizvedba, odgovor pa
-- je posten — pove, od kod atribut prihaja. Vir na **posamezno vrednost** je bil moja izmisljena
-- natancnost: stran ima stolpec »Vir«, ne »Vir te vrednosti«, in za vsako vrednost posebej ga iz
-- zajema tako ali tako ni mogoce dobiti poceni.

SET XACT_ABORT ON;

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetAttributeValues
  @OrganizationId int,
  @AttributeCode nvarchar(200),
  @Skip int = 0,
  @Take int = 50
AS
BEGIN
  SET NOCOUNT ON;
  IF @Skip IS NULL OR @Skip < 0 SET @Skip = 0;
  IF @Take IS NULL OR @Take <= 0 SET @Take = 50;

  DECLARE @FieldCode nvarchar(300) = CONCAT(N''ProductAttribute.'', @AttributeCode);

  -- Ali je atribut kje na spletu: stolpec aktivnega izvoznega profila.
  DECLARE @UsedOnWeb bit =
    CASE WHEN EXISTS
    (
      SELECT 1 FROM out.ExportColumn column_
      WHERE column_.IsActive = 1 AND column_.CanonicalFieldCode = @FieldCode
    ) THEN 1 ELSE 0 END;

  -- Vir iz registra, ne iz 20 milijonov zajetih vrednosti.
  DECLARE @Sources nvarchar(400) =
  (
    SELECT STRING_AGG(source.SourceCode, N'', '') WITHIN GROUP (ORDER BY source.SourceCode)
    FROM
    (
      SELECT DISTINCT connector.SourceCode
      FROM map.FieldMapping mapping
      INNER JOIN map.SourceConnector connector ON connector.SourceConnectorId = mapping.SourceConnectorId
      WHERE mapping.TargetFieldCode = @FieldCode
        AND mapping.IsActive = 1
        AND connector.OrganizationId = @OrganizationId
    ) source
  );

  CREATE TABLE #Value (Value nvarchar(400) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY, ProductCount bigint NOT NULL);
  INSERT #Value (Value, ProductCount)
  SELECT CONVERT(nvarchar(400), attributeValue.Value), COUNT_BIG(DISTINCT attributeValue.ProductId)
  FROM canon.ProductAttribute attributeValue
  INNER JOIN canon.Product product ON product.ProductId = attributeValue.ProductId
  WHERE product.OrganizationId = @OrganizationId
    AND attributeValue.AttributeCode = @AttributeCode
    AND NULLIF(attributeValue.Value, N'''') IS NOT NULL
  GROUP BY CONVERT(nvarchar(400), attributeValue.Value);

  SELECT
    @AttributeCode AS AttributeCode,
    valueRow.Value AS Value,
    valueRow.ProductCount AS ProductCount,
    (
      SELECT TOP (1) lookupRow.TargetValue
      FROM map.ValueLookup lookupRow
      WHERE lookupRow.IsActive = 1
        AND lookupRow.SourceValue = valueRow.Value
        AND lookupRow.Domain IN (@AttributeCode, N''*'')
      ORDER BY CASE WHEN lookupRow.Domain = @AttributeCode THEN 0 ELSE 1 END, lookupRow.ValueLookupId
    ) AS Translation,
    @Sources AS SourceCode,
    @UsedOnWeb AS UsedOnWeb,
    ISNULL((
      SELECT TOP (1) missing.SeenCount
      FROM map.MissingTranslation missing
      WHERE missing.SourceValue = valueRow.Value
        AND missing.Domain IN (@AttributeCode, N''*'')
      ORDER BY CASE WHEN missing.Domain = @AttributeCode THEN 0 ELSE 1 END, missing.MissingTranslationId
    ), 0) AS MissingTranslationCount
  FROM #Value valueRow
  ORDER BY valueRow.ProductCount DESC, valueRow.Value
  OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY;

  SELECT COUNT_BIG(*) AS TotalCount FROM #Value;
END;
');
