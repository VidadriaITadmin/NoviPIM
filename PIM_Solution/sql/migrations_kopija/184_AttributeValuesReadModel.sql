-- P2-15 iz docs/PREGLED_SISTEMA_IN_UX_2026-09-08.md: stran `/nastavitve/atributi/{koda}` je bila
-- brez vsebine. Vzrok ni bila stran — ta je napisana v celoti, s tabelo, stranmi in postenim
-- <PimMissing> — ampak manjkajoc bralni model `intranet.GetAttributeValues`.
--
-- Stran pricakuje po vrstici na **razlicno vrednost** atributa v podjetju:
--   Value                   vrednost, kot stoji v katalogu
--   ProductCount            koliko izdelkov jo ima
--   Translation             prevod iz slovarja (map.ValueLookup); NULL pomeni, da ga ni
--   SourceCode              vir, ki je vrednost prinesel; NULL, kadar ga ni mogoce dolociti
--   UsedOnWeb               ali je atribut stolpec kateregakoli aktivnega izvoznega profila
--   MissingTranslationCount kolikokrat je bila vrednost videna brez prevoda
-- in drugi nabor s skupnim stevilom razlicnih vrednosti.
--
-- Domena slovarja je koda atributa, `'*'` pa pomeni »velja povsod«; ozja domena premaga sirso,
-- zato se prevod izbere po tem vrstnem redu in ne z eno samo zdruzitvijo.

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

  -- Ali je atribut sploh kje na spletu: stolpec aktivnega izvoznega profila. Enkrat, ne na vrstico.
  DECLARE @UsedOnWeb bit =
    CASE WHEN EXISTS
    (
      SELECT 1
      FROM out.ExportColumn column_
      INNER JOIN out.ExportProfile profile ON profile.ExportProfileId = column_.ExportProfileId
      WHERE column_.IsActive = 1
        AND column_.CanonicalFieldCode = CONCAT(N''ProductAttribute.'', @AttributeCode)
    ) THEN 1 ELSE 0 END;

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
    (
      SELECT TOP (1) connector.SourceCode
      FROM map.ExtractedValue extracted
      INNER JOIN raw.Inbox inbox ON inbox.InboxId = extracted.InboxId
      INNER JOIN map.SourceConnector connector
        ON connector.OrganizationId = inbox.OrganizationId AND connector.SourceCode = inbox.SourceCode
      WHERE extracted.TargetFieldCode = CONCAT(N''ProductAttribute.'', @AttributeCode)
        AND CONVERT(nvarchar(400), extracted.Value) = valueRow.Value
        AND inbox.OrganizationId = @OrganizationId
      ORDER BY inbox.InboxId DESC
    ) AS SourceCode,
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
