/*
  173 — sifrant atributov delovnega lista mora biti isti v obe smeri.

  Napaka, ki jo je nasel test PIM.F10.ProductWorkbookTests 2026-09-08 (izhod pred popravkom):

    FAIL noben stolpec izvoza ne ostane neprepoznan — BUG, ID METAKOCKE, SEKUNDARNAMERSKAENOTA,
         STEVILOKOSOVVPAKETU
    FAIL nespremenjena datoteka ne prinese nobene spremembe — vrstic s spremembo: 20000
    FAIL ena spremenjena celica da eno spremembo — vrstic 20000, PIM 1, SAOP 20021

  Vzrok. Izvoz je vprasal za sifrant atributov z DANIM seznamom izdelkov, uvoz pa s praznim,
  ker takrat se ne ve, katere izdelke datoteka nosi. Prvi je dobil 148 kod, drugi tri. Uvoz
  zato ni imel stolpcev za atribute — imena atributov pa so se ujela s slovenskimi oznakami
  polj SAOP (»Garancija« je oboje). Vrednosti atributov so tako pristale na ERP poljih in bi
  napolnile odhodno vrsto z 20.021 spremembami, ki jih ni nihce naredil.

  Popravek: prazen seznam izdelkov pomeni »ves sifrant«, ne »nobenega«. Uvoz s tem pozna
  natanko iste stolpce kot izvoz in imena, ki se prekrivajo, razresi pogodba (stolpec dobi za
  naslov se svojo kanonicno kodo) — enako v obe smeri.

  Spremeni se samo peti rezultat procedure intranet.GetProductWorkbook. Ostalih pet je
  nespremenjenih in so prepisani zato, ker CREATE OR ALTER zamenja celo proceduro.
*/

SET XACT_ABORT ON;

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetProductWorkbook
  @ProductIdsJson nvarchar(max),
  @FieldCodesJson nvarchar(max)
AS
BEGIN
  SET NOCOUNT ON;

  DECLARE @Products TABLE (ProductId bigint NOT NULL PRIMARY KEY);
  INSERT @Products (ProductId)
  SELECT DISTINCT CONVERT(bigint, parsed.value) FROM OPENJSON(@ProductIdsJson) AS parsed
  WHERE ISJSON(parsed.value) = 0 AND TRY_CONVERT(bigint, parsed.value) IS NOT NULL;

  DECLARE @VsiIzdelki bit = CASE WHEN EXISTS (SELECT 1 FROM @Products) THEN 0 ELSE 1 END;

  DECLARE @Fields TABLE (FieldCode nvarchar(200) NOT NULL PRIMARY KEY);
  INSERT @Fields (FieldCode)
  SELECT DISTINCT CONVERT(nvarchar(200), parsed.value) FROM OPENJSON(@FieldCodesJson) AS parsed
  WHERE ISJSON(parsed.value) = 0 AND NULLIF(LTRIM(RTRIM(parsed.value)), N'''') IS NOT NULL;

  /* 1) Vrednosti polj. */
  SELECT
    fieldValue.ProductId,
    fieldValue.FieldCode,
    Value = STRING_AGG(CONVERT(nvarchar(max), fieldValue.Value), N'' | '') WITHIN GROUP (ORDER BY fieldValue.Value)
  FROM canon.FieldValue AS fieldValue
  INNER JOIN @Products AS product ON product.ProductId = fieldValue.ProductId
  INNER JOIN @Fields AS field ON field.FieldCode = fieldValue.FieldCode
  WHERE fieldValue.Value IS NOT NULL
  GROUP BY fieldValue.ProductId, fieldValue.FieldCode;

  /* 2) Kategorije po spletnih straneh. */
  SELECT
    category.ProductId,
    category.WebSite,
    CategoryPaths = STRING_AGG(CONVERT(nvarchar(max), category.CategoryPath), N'' | '') WITHIN GROUP (ORDER BY category.CategoryPath)
  FROM canon.ProductCategory AS category
  INNER JOIN @Products AS product ON product.ProductId = category.ProductId
  GROUP BY category.ProductId, category.WebSite;

  /* 3) Atributi. */
  SELECT
    attributeValue.ProductId,
    attributeValue.AttributeCode,
    Value = STRING_AGG(CONVERT(nvarchar(max), attributeValue.Value), N'' | '') WITHIN GROUP (ORDER BY attributeValue.Value)
  FROM canon.ProductAttribute AS attributeValue
  INNER JOIN @Products AS product ON product.ProductId = attributeValue.ProductId
  WHERE attributeValue.Value IS NOT NULL
  GROUP BY attributeValue.ProductId, attributeValue.AttributeCode;

  /* 4) Slike. */
  SELECT
    media.ProductId,
    Urls = STRING_AGG(CONVERT(nvarchar(max), media.Url), N'' | '') WITHIN GROUP (ORDER BY media.SortOrder)
  FROM canon.ProductMedia AS media
  INNER JOIN @Products AS product ON product.ProductId = media.ProductId
  GROUP BY media.ProductId;

  /*
    5) Sifrant atributov za naslove stolpcev.

    Prazen seznam izdelkov pomeni ves sifrant. Uvoz namrec ne ve vnaprej, katere izdelke
    datoteka nosi, izvoz pa ve — in ce bi zato dobila razlicna seznama, bi se imena atributov
    pri uvozu ujela s slovenskimi oznakami polj SAOP in vrednosti bi pristale na napacnem
    mestu. Stolpci morajo biti v obe smeri isti.
  */
  SELECT
    codes.AttributeCode,
    Name = ISNULL(translation.Name, codes.AttributeCode),
    IsRequired = CONVERT(bit, MAX(codes.IsRequired))
  FROM
  (
    SELECT DISTINCT AttributeCode = attributeValue.AttributeCode, IsRequired = 0
    FROM canon.ProductAttribute AS attributeValue
    WHERE @VsiIzdelki = 1
       OR EXISTS (SELECT 1 FROM @Products AS product WHERE product.ProductId = attributeValue.ProductId)
    UNION ALL
    SELECT DISTINCT
      AttributeCode = SUBSTRING(requirement.FieldCode, 18, 200),
      IsRequired = 1
    FROM val.FieldRequirement AS requirement
    INNER JOIN val.ValidationProfile AS validationProfile
      ON validationProfile.ValidationProfileId = requirement.ValidationProfileId
    WHERE requirement.IsActive = 1 AND requirement.IsRequired = 1 AND validationProfile.IsActive = 1
      AND requirement.FieldCode LIKE N''ProductAttribute.%''
      AND CHARINDEX(N''.'', SUBSTRING(requirement.FieldCode, 18, 200)) = 0
  ) AS codes
  LEFT JOIN canon.AttributeTranslation AS translation
    ON translation.AttributeCode = codes.AttributeCode AND translation.LanguageCode = N''sl''
  WHERE NULLIF(LTRIM(RTRIM(codes.AttributeCode)), N'''') IS NOT NULL
  GROUP BY codes.AttributeCode, translation.Name;

  /* 6) Register zahtevanih polj. */
  SELECT
    requirement.FieldCode,
    BlocksErp = CONVERT(bit, MAX(CASE WHEN exportProfile.ChannelCode LIKE N''%ERP%'' THEN 1 ELSE 0 END)),
    BlocksWeb = CONVERT(bit, MAX(CASE WHEN exportProfile.ChannelCode LIKE N''%ERP%'' THEN 0 ELSE 1 END))
  FROM val.FieldRequirement AS requirement
  INNER JOIN val.ValidationProfile AS validationProfile
    ON validationProfile.ValidationProfileId = requirement.ValidationProfileId
  INNER JOIN out.ExportProfile AS exportProfile
    ON exportProfile.ExportProfileId = validationProfile.ExportProfileId
  WHERE requirement.IsActive = 1 AND requirement.IsRequired = 1 AND validationProfile.IsActive = 1
  GROUP BY requirement.FieldCode;
END;');

IF NOT EXISTS (SELECT 1 FROM sys.sql_modules WHERE object_id = OBJECT_ID(N'intranet.GetProductWorkbook') AND definition LIKE N'%@VsiIzdelki%')
  THROW 51730, N'173: intranet.GetProductWorkbook ne pozna praznega seznama izdelkov.', 1;
