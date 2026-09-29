/* 277: Uvoz delovnega lista piše prevedljive atribute po jezikih.

   Test 2026-09-24 (BA.BA09.00511, »Oblika svetilke«): pim.SaveProductAttributesBulk (218) je
   ujemal (izdelek, koda atributa) brez jezika, zato je ena vrednost iz Excela povozila vse
   jezikovne vrstice — slovenska »Neusmerjena« je nadomestila angleško »Non-Directional«.
   Procedura sprejme neobvezen languageCode; uvoz (ProductWorkbookService) ga pošlje za vsak del
   celice »sl | en«, ki ga poveže z jezikom. Brez languageCode ostane dosedanje vedenje. */
SET XACT_ABORT ON;
GO

CREATE OR ALTER PROCEDURE pim.SaveProductAttributesBulk
  @OrganizationId int,
  @ChangesJson nvarchar(max),   /* [{"productId":123,"attributeCode":"Barva","languageCode":"sl","value":"..."}, ...] */
  @Actor nvarchar(200),
  @Note nvarchar(400) = NULL
AS
BEGIN
  /*
    218: mnozicni zapis atributov za uvoz delovnega lista - dvojcek pim.SaveProductAttributes
    za poljubno mnogo izdelkov v enem klicu (glej pim.SaveProductTextsBulk za razlog).
    277: neobvezen languageCode. Z njim se zapise samo vrstica tega jezika; brez njega (atribut brez
    jezika) velja kot doslej - vse vrstice atributa. Prej je vrednost iz Excela povozila vse jezike:
    slovenska vrednost je pristala tudi v anglescini (test 2026-09-24, »Oblika svetilke«).
  */
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  DECLARE @Changes TABLE (ProductId bigint NOT NULL, AttributeCode nvarchar(200) NOT NULL,
                          LanguageCode nvarchar(10) NULL, Value nvarchar(max) NULL);
  INSERT @Changes (ProductId, AttributeCode, LanguageCode, Value)
  SELECT vrstica.ProductId, vrstica.AttributeCode, vrstica.LanguageCode, vrstica.Value
  FROM
  (
    SELECT parsed.productId AS ProductId, LTRIM(RTRIM(parsed.attributeCode)) AS AttributeCode,
      NULLIF(LTRIM(RTRIM(parsed.languageCode)), N'') AS LanguageCode, parsed.value AS Value,
      ROW_NUMBER() OVER (PARTITION BY parsed.productId, LTRIM(RTRIM(parsed.attributeCode)), ISNULL(NULLIF(LTRIM(RTRIM(parsed.languageCode)), N''), N'')
                         ORDER BY CONVERT(int, element.[key])) AS Zaporedna
    FROM OPENJSON(@ChangesJson) AS element
    CROSS APPLY OPENJSON(element.value)
      WITH (productId bigint N'$.productId', attributeCode nvarchar(200) N'$.attributeCode',
            languageCode nvarchar(10) N'$.languageCode', value nvarchar(max) N'$.value') AS parsed
    WHERE parsed.productId IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(parsed.attributeCode)), N'') IS NOT NULL
  ) AS vrstica
  WHERE vrstica.Zaporedna = 1;

  DECLARE @Skipped TABLE (ProductId bigint NOT NULL PRIMARY KEY, Reason nvarchar(200) NOT NULL);
  INSERT @Skipped (ProductId, Reason)
  SELECT DISTINCT change.ProductId, N'Izdelek ne obstaja v tem podjetju.'
  FROM @Changes AS change
  WHERE NOT EXISTS (SELECT 1 FROM canon.Product AS product WHERE product.ProductId = change.ProductId AND product.OrganizationId = @OrganizationId);
  DELETE change FROM @Changes AS change INNER JOIN @Skipped AS skipped ON skipped.ProductId = change.ProductId;

  DECLARE @BatchId uniqueidentifier = NEWID();
  EXEC pim.SetChangeContext @ChangeSource = N'INTRANET', @ChangedBy = @Actor, @BatchId = @BatchId, @Note = @Note;

  BEGIN TRY
    BEGIN TRANSACTION;

    DELETE attributeValue
    FROM canon.ProductAttribute AS attributeValue
    INNER JOIN @Changes AS change
      ON change.ProductId = attributeValue.ProductId AND change.AttributeCode = attributeValue.AttributeCode
     AND (change.LanguageCode IS NULL OR attributeValue.LanguageCode = change.LanguageCode)
    WHERE NULLIF(LTRIM(RTRIM(change.Value)), N'') IS NULL;

    MERGE canon.ProductAttribute AS target
    USING (SELECT ProductId, AttributeCode, LanguageCode, Value FROM @Changes WHERE NULLIF(LTRIM(RTRIM(Value)), N'') IS NOT NULL) AS source
    ON target.ProductId = source.ProductId AND target.AttributeCode = source.AttributeCode
       AND (source.LanguageCode IS NULL OR target.LanguageCode = source.LanguageCode)
    WHEN MATCHED AND ISNULL(target.Value, N'') <> source.Value THEN UPDATE SET Value = source.Value
    WHEN NOT MATCHED THEN INSERT (ProductId, AttributeCode, LanguageCode, Value)
      VALUES (source.ProductId, source.AttributeCode, source.LanguageCode, source.Value);

    COMMIT TRANSACTION;
  END TRY
  BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    EXEC pim.ClearChangeContext;
    THROW;
  END CATCH;

  EXEC pim.ClearChangeContext;

  DECLARE @ProductIdsJson nvarchar(max) =
    (SELECT N'[' + STRING_AGG(CONVERT(nvarchar(max), izdelek.ProductId), N',') + N']'
     FROM (SELECT DISTINCT ProductId FROM @Changes) AS izdelek);
  IF @ProductIdsJson IS NOT NULL
    EXEC val.RunValidationForProducts @ProductIdsJson = @ProductIdsJson;

  SELECT ChangedCount = (SELECT COUNT_BIG(*) FROM @Changes),
         ProductCount = (SELECT COUNT_BIG(DISTINCT ProductId) FROM @Changes),
         SkippedCount = (SELECT COUNT_BIG(*) FROM @Skipped);

  SELECT ProductId, Reason FROM @Skipped ORDER BY ProductId;
END;
GO

IF OBJECT_DEFINITION(OBJECT_ID(N'pim.SaveProductAttributesBulk')) NOT LIKE N'%languageCode%'
  THROW 52930, N'277: pim.SaveProductAttributesBulk ne pozna jezika.', 1;
GO
