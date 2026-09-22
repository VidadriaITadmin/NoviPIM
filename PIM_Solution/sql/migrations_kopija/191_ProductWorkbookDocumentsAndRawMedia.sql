/*
  191 — izvoz izdelkov (Nastavitve -> Izdelki -> Izvozi Excel) dobi stolpec Dokumenti in
  loci slike od vsega drugega, kar canon.ProductMedia danes meša skupaj.

  Zahteva uporabnika 2026-09-10:
    1) nov stolpec »Dokumenti« za Slike, z vsem, kar ni slika (dokumenti, videi, arhivi …);
    2) »Spletne strani« naj jezikovno razlicico iste strani (Svetila.si (ANG)) zdruzi z
       osnovno (Svetila.si) — to je resila samo koda C# (ProductWorkbookService.cs), tu ni
       nič za spremeniti;
    3) kje »Spletni opis« dobi podatek — canon.ProductText (TextType='DESCRIPTION', na jezik),
       preko VIEW canon.FieldValue kot ProductText.DESCRIPTION.<jezik>; vir je SAOP
       GetItemsDescriptions (preslikava ProductTextByLanguage.DESCRIPTION), tudi to ni
       sprememba sheme, samo odgovor.

  Zakaj je »Slike« doslej nosila vse: canon.ProductMedia nima stolpca z vrsto (samo URL in
  vloga) — enako opozorilo kot v MediaKindPolicy.cs za stran Mediji: »Stran je zato dolgo
  prikazovala vse kot sliko in video ter dokument sta bila nevidna.« intranet.GetProductWorkbook
  je slike doslej agregiral z golim STRING_AGG brez razvrstitve, torej je bilo v stolpcu Slike
  vse, tudi PDF-ji in video povezave iz canon.ProductMedia; pravi dokumenti iz locene tabele
  canon.ProductDocument pa niso bili v izvozu SPLOH.

  Kaj ta migracija spremeni: samo cetrti rezultat procedure intranet.GetProductWorkbook.
  Namesto STRING_AGG(Urls) po ProductId vrne SUROVE vrstice (ProductId, Url, Role, SortOrder)
  iz OBEH tabel (canon.ProductMedia + canon.ProductDocument), urejene po ProductId, SortOrder.
  Razvrstitev slika/dokument naredi C# (ProductWorkbookService.ReadAsync) z ISTO
  MediaKindPolicy.Classify, ki jo uporablja stran Mediji — SQL nima dostopa do tega razreda in
  bi podvojen CASE prej ali slej zdrsnil narazen od resnicnega pravila. Noben drug rezultat
  procedure se ne spremeni.
*/

SET XACT_ABORT ON;

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetProductWorkbook
  @ProductIdsJson nvarchar(max),
  @FieldCodesJson nvarchar(max),
  @CategoryTreeCode nvarchar(100) = NULL,
  @CategoryCode nvarchar(200) = NULL
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

  SET @CategoryCode = NULLIF(LTRIM(RTRIM(@CategoryCode)), N'''');
  SET @CategoryTreeCode = NULLIF(LTRIM(RTRIM(@CategoryTreeCode)), N'''');

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

  /* 4) Mediji — surovo, brez STRING_AGG in brez razvrstitve slika/dokument. C# razvrsti z
        MediaKindPolicy.Classify (isto pravilo kot stran Mediji) in sele nato zdruzi v celico. */
  SELECT media.ProductId, media.Url, media.Role, media.SortOrder
  FROM canon.ProductMedia AS media
  INNER JOIN @Products AS product ON product.ProductId = media.ProductId
  UNION ALL
  SELECT document.ProductId, document.Url, document.Role, document.SortOrder
  FROM canon.ProductDocument AS document
  INNER JOIN @Products AS product ON product.ProductId = document.ProductId
  ORDER BY ProductId, SortOrder;

  /*
    5) Sifrant atributov za naslove stolpcev.

    Trije viri, zdruzeni po slovenskem imenu, ker je to kljuc v canon.ProductAttribute:
      NABOR    — ucinkoviti nabor kategorije (dedovanje da canon.CategoryAttributeEffective);
                 kadar je kategorija dana, samo zanjo, sicer za vse kategorije danih izdelkov,
      VREDNOST — kar dani izdelki ze imajo zapisano,
      ZAHTEVA  — kar zahteva validacija.

    Prazen seznam izdelkov in brez kategorije pomeni ves sifrant: uvoz ne ve vnaprej, katere
    izdelke datoteka nosi, in mora prepoznati vsak stolpec, ki ga je izvoz izpisal.
  */
  DECLARE @Kategorije TABLE (CategoryTreeCode nvarchar(100) NOT NULL, CategoryCode nvarchar(200) NOT NULL,
    PRIMARY KEY (CategoryTreeCode, CategoryCode));

  IF @CategoryCode IS NOT NULL
  BEGIN
    INSERT @Kategorije (CategoryTreeCode, CategoryCode)
    SELECT DISTINCT node.CategoryTreeCode, node.CategoryCode
    FROM canon.Category AS node
    WHERE node.CategoryCode = @CategoryCode
      AND (@CategoryTreeCode IS NULL OR node.CategoryTreeCode = @CategoryTreeCode);
  END
  ELSE IF @VsiIzdelki = 0
  BEGIN
    INSERT @Kategorije (CategoryTreeCode, CategoryCode)
    SELECT DISTINCT node.CategoryTreeCode, node.CategoryCode
    FROM canon.ProductCategory AS productCategory
    INNER JOIN @Products AS product ON product.ProductId = productCategory.ProductId
    INNER JOIN canon.WebSite AS site ON site.WebSiteCode = productCategory.WebSite
    INNER JOIN canon.Category AS node
      ON node.CategoryTreeCode = site.CategoryTreeCode AND node.CategoryPath = productCategory.CategoryPath;
  END

  ;WITH nabor AS
  (
    SELECT effective.AttributeCode, effective.Level, MinSort = MIN(effective.SortOrder)
    FROM @Kategorije AS kategorija
    CROSS APPLY canon.CategoryAttributeEffective(kategorija.CategoryTreeCode, kategorija.CategoryCode) AS effective
    WHERE effective.Level <> N''EXCLUDED''
    GROUP BY effective.AttributeCode, effective.Level
  ),
  imena AS
  (
    SELECT
      AttributeName = COALESCE(translation.Name, nabor.AttributeCode),
      /* Ista koda v dveh kategorijah z razlicno ravnijo: obvelja strozja. REQUIRED je po
         abecedi za RECOMMENDED, zato MAX in ne MIN. */
      Level = MAX(nabor.Level),
      SortOrder = MIN(nabor.MinSort)
    FROM nabor
    LEFT JOIN canon.AttributeTranslation AS translation
      ON translation.AttributeCode = nabor.AttributeCode AND translation.LanguageCode = N''sl''
    GROUP BY COALESCE(translation.Name, nabor.AttributeCode)
  ),
  vsi AS
  (
    SELECT AttributeName, IsRequired = 0, InSet = 1, SetLevel = Level, SortOrder FROM imena
    UNION ALL
    SELECT DISTINCT attributeValue.AttributeCode, 0, 0, NULL, 1000
    FROM canon.ProductAttribute AS attributeValue
    WHERE (@VsiIzdelki = 1 AND @CategoryCode IS NULL)
       OR EXISTS (SELECT 1 FROM @Products AS product WHERE product.ProductId = attributeValue.ProductId)
    UNION ALL
    SELECT DISTINCT SUBSTRING(requirement.FieldCode, 18, 200), 1, 0, NULL, 0
    FROM val.FieldRequirement AS requirement
    INNER JOIN val.ValidationProfile AS validationProfile
      ON validationProfile.ValidationProfileId = requirement.ValidationProfileId
    WHERE requirement.IsActive = 1 AND requirement.IsRequired = 1 AND validationProfile.IsActive = 1
      AND requirement.FieldCode LIKE N''ProductAttribute.%''
      AND CHARINDEX(N''.'', SUBSTRING(requirement.FieldCode, 18, 200)) = 0
  )
  SELECT
    AttributeCode = vsi.AttributeName,
    Name = vsi.AttributeName,
    IsRequired = CONVERT(bit, MAX(vsi.IsRequired)),
    InSet = CONVERT(bit, MAX(vsi.InSet)),
    SetLevel = MAX(vsi.SetLevel),
    SortOrder = MIN(vsi.SortOrder)
  FROM vsi
  WHERE NULLIF(LTRIM(RTRIM(vsi.AttributeName)), N'''') IS NOT NULL
  GROUP BY vsi.AttributeName;

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

/* --- Preverbe ---------------------------------------------------------------------------- */

IF NOT EXISTS
(
  SELECT 1 FROM sys.sql_modules
  WHERE object_id = OBJECT_ID(N'intranet.GetProductWorkbook') AND definition LIKE N'%canon.ProductDocument%'
    AND definition LIKE N'%media.Role%' AND definition NOT LIKE N'%Urls = STRING_AGG%'
)
  THROW 53010, 'intranet.GetProductWorkbook se ne vrne surovih vrstic medijev in dokumentov.', 1;
