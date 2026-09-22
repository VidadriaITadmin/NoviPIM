/*
  175 — izvoz izdelkov po kategoriji in stolpci atributov iz nabora kategorije.

  Zahteva uporabnika 2026-09-08: »nekaj atributov smo dodali, preveri ce lahko dodelas izvoze
  glede na kategorijo«.

  Kaj je bilo do zdaj. Delovni list izdelkov (171, 173) je dobil stolpce atributov iz dveh
  virov: kar izdelki ze imajo zapisano, in kar zahteva validacija. Nabor atributov po kategoriji
  (147, 170, 173, 174) v tem ni sodeloval. Posledici sta bili dve:

    1. Atributa, ki ga kategorija zahteva, izdelek pa ga se nima, v listu NI BILO — ravno tistega,
       ki ga je treba vpisati. List je pokazal, kar ze obstaja, in zamolcal, kar manjka.
    2. Vsak izdelek je dobil vseh 148 stolpcev atributov, tudi tiste iz drugih kategorij. Za
       stropno svetilko so bili stolpci o preseku kabla samo hrup.

  Izbire kategorije tudi ni bilo mogoce narediti: intranet.GetProductList nima parametra za
  kategorijo, edina omemba je pogled NO_CATEGORY (izdelki brez nje).

  Kaj ta migracija naredi:

    1. intranet.GetProductList dobi @CategoryTreeCode in @CategoryCode. Izbrana kategorija pomeni
       njo in vse njene potomce — nabor atributov se po drevesu deduje navzdol, zato se mora tudi
       filter. Pogoj je dodan v obe poizvedbi, v stran rezultatov in v stevec, sicer bi seznam in
       stevilo zadetkov govorila vsak svoje (isto pravilo kot pri filtru slike, migracija 126).

    2. intranet.GetProductWorkbook dobi ista dva parametra, peti rezultat (sifrant atributov za
       stolpce lista) pa dve novi polji: InSet in SetLevel. Ucinkoviti nabor da funkcija
       canon.CategoryAttributeEffective (147) — dedovanje po prednikih je zapisano tam in se tu
       ne ponavlja. Kadar je kategorija dana, se nabor vzame zanjo; sicer za vse kategorije danih
       izdelkov. Atribut z ravnijo EXCLUDED v nabor ne sodi.

  Kar ostaja nespremenjeno: kljuc atributa. V naboru je stabilna koda (IP_STOPNJA_ZASCITE), v
  canon.ProductAttribute pa slovensko ime (IP stopnja zascite). Preslikavo dela
  canon.AttributeTranslation v jeziku sl, enako kot na kartici izdelka in v validaciji; brez nje
  bi stolpec iz nabora nosil kodo, vrednost izdelka pa ime, in se ne bi nikoli srecala.

  Procedure nicesar ne pisejo. Migracija je ponovljiva: CREATE OR ALTER.
*/

SET XACT_ABORT ON;

/* --- 1) Seznam izdelkov zna filtrirati po kategoriji --------------------------------------- */

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetProductList
  @OrganizationId int = NULL,
  @Skip int = 0,
  @Take int = 50,
  @Search nvarchar(200) = NULL,
  @View nvarchar(40) = NULL,
  @Manufacturer nvarchar(200) = NULL,
  @Supplier nvarchar(200) = NULL,
  @ItemGroup nvarchar(100) = NULL,
  @ErpStatus nvarchar(30) = NULL,
  @WebStatus nvarchar(30) = NULL,
  @Sort nvarchar(40) = NULL,
  @SortDescending bit = 0,
  @Language nvarchar(20) = N''sl'',
  @Department nvarchar(100) = NULL,
  @Activity nvarchar(20) = NULL,
  @WebPublish nvarchar(20) = NULL,
  @Completeness nvarchar(20) = NULL,
  @HasImage nvarchar(20) = NULL,
  @CategoryTreeCode nvarchar(100) = NULL,
  @CategoryCode nvarchar(200) = NULL
AS
BEGIN
  SET NOCOUNT ON;

  SET @Skip = CASE WHEN @Skip < 0 THEN 0 ELSE @Skip END;
  /* Stran je 50; izvoz vzame vse naenkrat. Prej je bila meja 200 in izvoz je bil 100
     zaporednih klicev z vedno vecjim OFFSET — brskalnik je zahtevo prekinil prej, kot je
     datoteka nastala. */
  SET @Take = CASE WHEN @Take < 1 THEN 50 WHEN @Take > 20000 THEN 20000 ELSE @Take END;
  SET @Search = NULLIF(LTRIM(RTRIM(@Search)), N'''');
  SET @View = NULLIF(UPPER(LTRIM(RTRIM(@View))), N'''');
  SET @Manufacturer = NULLIF(LTRIM(RTRIM(@Manufacturer)), N'''');
  SET @Supplier = NULLIF(LTRIM(RTRIM(@Supplier)), N'''');
  SET @ItemGroup = NULLIF(LTRIM(RTRIM(@ItemGroup)), N'''');
  SET @Department = NULLIF(LTRIM(RTRIM(@Department)), N'''');
  SET @ErpStatus = NULLIF(UPPER(LTRIM(RTRIM(@ErpStatus))), N'''');
  SET @WebStatus = NULLIF(UPPER(LTRIM(RTRIM(@WebStatus))), N'''');
  SET @Activity = NULLIF(UPPER(LTRIM(RTRIM(@Activity))), N'''');
  SET @WebPublish = NULLIF(UPPER(LTRIM(RTRIM(@WebPublish))), N'''');
  SET @Completeness = NULLIF(UPPER(LTRIM(RTRIM(@Completeness))), N'''');
  SET @HasImage = NULLIF(UPPER(LTRIM(RTRIM(@HasImage))), N'''');
  SET @Sort = COALESCE(NULLIF(UPPER(LTRIM(RTRIM(@Sort))), N''''), N''ITEM'');
  SET @Language = COALESCE(NULLIF(LTRIM(RTRIM(@Language)), N''''), N''sl'');
  IF @View = N''ALL'' SET @View = NULL;
  IF @ErpStatus NOT IN (N''VALID'', N''INVALID'') SET @ErpStatus = NULL;
  IF @WebStatus NOT IN (N''VALID'', N''INVALID'') SET @WebStatus = NULL;
  IF @Activity NOT IN (N''ACTIVE'', N''INACTIVE'') SET @Activity = NULL;
  IF @WebPublish NOT IN (N''YES'', N''NO'') SET @WebPublish = NULL;
  IF @Completeness NOT IN (N''EMPTY'', N''LOW'', N''MID'', N''FULL'') SET @Completeness = NULL;
  IF @HasImage NOT IN (N''YES'', N''NO'') SET @HasImage = NULL;

  /* Neznana ali neaktivna organizacija ne sme tiho pomeniti vseh: raje prazen nabor. */
  DECLARE @UnknownOrganization bit = CASE
    WHEN @OrganizationId IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM dbo.OrganizationConfig AS orgValue WHERE orgValue.OrganizationId = @OrganizationId)
    THEN 1 ELSE 0 END;

  DECLARE @Like nvarchar(210) = CASE WHEN @Search IS NULL THEN NULL ELSE N''%'' + @Search + N''%'' END;

  /* Filter po pripravljenosti je mnozicen, ne vrstica-po-vrstici: korelirani EXISTS cez
     celotno podjetje je bil merjeno 2.911 ms, ta zapis 130 ms. Enakovreden je zato, ker
     UQ_ProductValidationState_ProductProfile dovoli najvec eno stanje na profil in izdelek. */
  CREATE TABLE #ErpValid (ProductId bigint NOT NULL PRIMARY KEY);
  CREATE TABLE #WebValid (ProductId bigint NOT NULL PRIMARY KEY);

  DECLARE @ErpProfiles int = (SELECT COUNT(*) FROM val.ValidationProfile WHERE IsActive = 1 AND BlocksErp = 1);
  DECLARE @WebProfiles int = (SELECT COUNT(*) FROM val.ValidationProfile WHERE IsActive = 1 AND BlocksWeb = 1);

  IF @ErpStatus IS NOT NULL AND @ErpProfiles > 0
    INSERT #ErpValid (ProductId)
    SELECT stateValue.ProductId
    FROM val.ProductValidationState AS stateValue
    INNER JOIN val.ValidationProfile AS profileValue
      ON profileValue.ValidationProfileId = stateValue.ValidationProfileId
     AND profileValue.IsActive = 1 AND profileValue.BlocksErp = 1
    INNER JOIN canon.Product AS product
      ON product.ProductId = stateValue.ProductId
     AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
    WHERE stateValue.Status = N''VALID''
    GROUP BY stateValue.ProductId
    HAVING COUNT(*) = @ErpProfiles;

  /* Brez profila, ki blokira, ni nihce blokiran; sicer bi HAVING COUNT(*) = 0 oznacil vse za neveljavne. */
  IF @ErpStatus IS NOT NULL AND @ErpProfiles = 0
    INSERT #ErpValid (ProductId)
    SELECT product.ProductId FROM canon.Product AS product
    WHERE (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId);

  IF @WebStatus IS NOT NULL AND @WebProfiles > 0
    INSERT #WebValid (ProductId)
    SELECT stateValue.ProductId
    FROM val.ProductValidationState AS stateValue
    INNER JOIN val.ValidationProfile AS profileValue
      ON profileValue.ValidationProfileId = stateValue.ValidationProfileId
     AND profileValue.IsActive = 1 AND profileValue.BlocksWeb = 1
    INNER JOIN canon.Product AS product
      ON product.ProductId = stateValue.ProductId
     AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
    WHERE stateValue.Status = N''VALID''
    GROUP BY stateValue.ProductId
    HAVING COUNT(*) = @WebProfiles;

  IF @WebStatus IS NOT NULL AND @WebProfiles = 0
    INSERT #WebValid (ProductId)
    SELECT product.ProductId FROM canon.Product AS product
    WHERE (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId);

  /*
    Filter po kategoriji. Izbrana kategorija pomeni njo IN vse njene potomce: kdor izbere
    ''Notranja svetila'', pricakuje tudi ''Notranja svetila > Visece svetilke''. Nabor atributov
    se po drevesu deduje navzdol, zato se mora tudi filter.

    Pot izdelka je zapisana kot besedilo (canon.ProductCategory.CategoryPath), kodo kategorije
    pa da canon.CategoryPathTranslated v jeziku tiste spletne strani, ki temu drevesu pripada.
  */
  CREATE TABLE #CategoryProduct (ProductId bigint NOT NULL PRIMARY KEY);
  IF NULLIF(LTRIM(RTRIM(@CategoryCode)), N'''') IS NOT NULL
  BEGIN
    ;WITH veja AS
    (
      SELECT koren.CategoryTreeCode, koren.CategoryCode
      FROM canon.Category AS koren
      WHERE koren.CategoryCode = @CategoryCode
        AND (@CategoryTreeCode IS NULL OR koren.CategoryTreeCode = @CategoryTreeCode)
      UNION ALL
      SELECT otrok.CategoryTreeCode, otrok.CategoryCode
      FROM canon.Category AS otrok
      INNER JOIN veja ON veja.CategoryTreeCode = otrok.CategoryTreeCode
        AND veja.CategoryCode = otrok.ParentCategoryCode
    )
    INSERT #CategoryProduct (ProductId)
    SELECT DISTINCT productCategory.ProductId
    FROM canon.ProductCategory AS productCategory
    INNER JOIN canon.WebSite AS site ON site.WebSiteCode = productCategory.WebSite
    INNER JOIN canon.CategoryPathTranslated AS prevod
      ON prevod.CategoryTreeCode = site.CategoryTreeCode AND prevod.LanguageCode = site.LanguageCode
     AND prevod.CategoryPath = productCategory.CategoryPath
    INNER JOIN veja ON veja.CategoryTreeCode = prevod.CategoryTreeCode AND veja.CategoryCode = prevod.CategoryCode
    OPTION (MAXRECURSION 20);
  END;

  ;WITH filtered AS
  (
    SELECT product.ProductId, product.ItemID, product.OrganizationId, product.Completeness, product.LastValidatedUtc
    FROM canon.Product AS product
    WHERE @UnknownOrganization = 0
      AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
      AND (@Like IS NULL OR product.ItemID LIKE @Like OR product.EAN LIKE @Like)
      AND (@Manufacturer IS NULL OR product.Manufacturer = @Manufacturer)
      AND (@Supplier IS NULL OR product.Supplier = @Supplier)
      AND (@ItemGroup IS NULL OR product.ItemGroup = @ItemGroup)
      AND (@Department IS NULL OR product.Department = @Department)
      AND (@Activity IS NULL OR product.IsActive = CASE WHEN @Activity = N''ACTIVE'' THEN 1 ELSE 0 END)
      AND (@WebPublish IS NULL OR product.WebPublish = CASE WHEN @WebPublish = N''YES'' THEN 1 ELSE 0 END)
      AND
      (
        @HasImage IS NULL
        OR (@HasImage = N''YES'' AND EXISTS (SELECT 1 FROM canon.ProductMedia AS imageValue WHERE imageValue.ProductId = product.ProductId))
        OR (@HasImage = N''NO'' AND NOT EXISTS (SELECT 1 FROM canon.ProductMedia AS imageValue WHERE imageValue.ProductId = product.ProductId))
      )
      AND (@CategoryCode IS NULL OR EXISTS
        (SELECT 1 FROM #CategoryProduct AS kategorija WHERE kategorija.ProductId = product.ProductId))
      AND
      (
        @Completeness IS NULL
        OR (@Completeness = N''EMPTY'' AND product.Completeness = 0)
        OR (@Completeness = N''LOW'' AND product.Completeness > 0 AND product.Completeness < 50)
        OR (@Completeness = N''MID'' AND product.Completeness >= 50 AND product.Completeness < 100)
        OR (@Completeness = N''FULL'' AND product.Completeness >= 100)
      )
      AND
      (
        @View IS NULL
        OR (@View = N''TO_FIX'' AND product.ValidationStatus <> N''VALID'')
        OR (@View = N''NO_IMAGE'' AND NOT EXISTS (SELECT 1 FROM canon.ProductMedia AS media WHERE media.ProductId = product.ProductId))
        OR (@View = N''NO_WEB_TITLE'' AND NOT EXISTS (SELECT 1 FROM canon.ProductText AS titleValue WHERE titleValue.ProductId = product.ProductId AND titleValue.TextType = N''WEB_TITLE''))
        OR (@View = N''NO_CATEGORY'' AND NOT EXISTS (SELECT 1 FROM canon.ProductCategory AS categoryValue WHERE categoryValue.ProductId = product.ProductId))
        OR (@View = N''NO_EAN'' AND product.EAN IS NULL)
        OR (@View = N''NOT_PUBLISHED'' AND NOT EXISTS (SELECT 1 FROM pim.Product AS promoted WHERE promoted.OrganizationId = product.OrganizationId AND promoted.ItemID = product.ItemID))
        OR (@View = N''WAITING_SAOP'' AND EXISTS (SELECT 1 FROM out.OutboxMessage AS message WHERE message.OrganizationId = product.OrganizationId AND message.TargetKind = N''SAOP_PRODUCT'' AND message.EntityKey = product.ItemID AND message.Status IN (N''PendingApproval'', N''Pending'', N''Sending'', N''Sent'', N''Error'', N''Retry'', N''Drift'')))
      )
      AND
      (
        @ErpStatus IS NULL
        OR (@ErpStatus = N''VALID'' AND EXISTS (SELECT 1 FROM #ErpValid AS erpValid WHERE erpValid.ProductId = product.ProductId))
        OR (@ErpStatus = N''INVALID'' AND NOT EXISTS (SELECT 1 FROM #ErpValid AS erpValid WHERE erpValid.ProductId = product.ProductId))
      )
      AND
      (
        @WebStatus IS NULL
        OR (@WebStatus = N''VALID'' AND EXISTS (SELECT 1 FROM #WebValid AS webValid WHERE webValid.ProductId = product.ProductId))
        OR (@WebStatus = N''INVALID'' AND NOT EXISTS (SELECT 1 FROM #WebValid AS webValid WHERE webValid.ProductId = product.ProductId))
      )
  ),
  paged AS
  (
    SELECT filtered.ProductId
    FROM filtered
    ORDER BY
      CASE WHEN @SortDescending = 0 AND @Sort = N''COMPLETENESS'' THEN filtered.Completeness END ASC,
      CASE WHEN @SortDescending = 1 AND @Sort = N''COMPLETENESS'' THEN filtered.Completeness END DESC,
      CASE WHEN @SortDescending = 0 AND @Sort = N''CHANGED'' THEN filtered.LastValidatedUtc END ASC,
      CASE WHEN @SortDescending = 1 AND @Sort = N''CHANGED'' THEN filtered.LastValidatedUtc END DESC,
      CASE WHEN @SortDescending = 0 AND @Sort = N''ORGANIZATION'' THEN filtered.OrganizationId END ASC,
      CASE WHEN @SortDescending = 1 AND @Sort = N''ORGANIZATION'' THEN filtered.OrganizationId END DESC,
      CASE WHEN @SortDescending = 1 AND @Sort NOT IN (N''COMPLETENESS'', N''CHANGED'', N''ORGANIZATION'') THEN filtered.ItemID END DESC,
      CASE WHEN @SortDescending = 0 AND @Sort NOT IN (N''COMPLETENESS'', N''CHANGED'', N''ORGANIZATION'') THEN filtered.ItemID END ASC,
      filtered.ItemID, filtered.ProductId
    OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY
  )
  SELECT product.ProductId, product.ItemID, product.EAN,
    Name = COALESCE(webTitle.Value, erpTitle.Value, product.ItemID),
    HasWebTitle = CONVERT(bit, CASE WHEN webTitle.Value IS NULL THEN 0 ELSE 1 END),
    ThumbnailUrl = thumbnail.Url,
    product.Manufacturer, product.Supplier, product.ItemGroup, product.Department,
    product.IsActive, product.WebPublish,
    IsPromoted = CONVERT(bit, CASE WHEN promoted.PimProductId IS NULL THEN 0 ELSE 1 END),
    product.ValidationStatus, product.Completeness, product.LastValidatedUtc,
    product.OrganizationId,
    OrganizationName = COALESCE(organizationValue.Name, CONVERT(nvarchar(200), product.OrganizationId)),
    /* Sifra ostane, ker gre ona nazaj v SAOP; ime je to, kar uporabnik bere. */
    SupplierName = supplierPartner.PartnerName,
    ManufacturerName = manufacturerPartner.PartnerName,
    ErpStatus = CASE
      WHEN @ErpProfiles = 0 THEN N''NOT_CONFIGURED''
      WHEN EXISTS
      (
        SELECT 1 FROM val.ValidationProfile AS profileValue
        LEFT JOIN val.ProductValidationState AS stateValue
          ON stateValue.ValidationProfileId = profileValue.ValidationProfileId
         AND stateValue.ProductId = product.ProductId
        WHERE profileValue.IsActive = 1 AND profileValue.BlocksErp = 1
          AND (stateValue.ProductValidationStateId IS NULL OR stateValue.Status <> N''VALID'')
      ) THEN N''INVALID'' ELSE N''VALID'' END,
    WebStatus = CASE
      WHEN @WebProfiles = 0 THEN N''NOT_CONFIGURED''
      WHEN EXISTS
      (
        SELECT 1 FROM val.ValidationProfile AS profileValue
        LEFT JOIN val.ProductValidationState AS stateValue
          ON stateValue.ValidationProfileId = profileValue.ValidationProfileId
         AND stateValue.ProductId = product.ProductId
        WHERE profileValue.IsActive = 1 AND profileValue.BlocksWeb = 1
          AND (stateValue.ProductValidationStateId IS NULL OR stateValue.Status <> N''VALID'')
      ) THEN N''INVALID'' ELSE N''VALID'' END,
    OpenIssueCount = (SELECT COUNT_BIG(*) FROM val.ProductIssue AS issueValue WHERE issueValue.ProductId = product.ProductId AND issueValue.IsActive = 1),
    CategoryCount = (SELECT COUNT_BIG(*) FROM canon.ProductCategory AS categoryValue WHERE categoryValue.ProductId = product.ProductId),
    MediaCount = (SELECT COUNT_BIG(*) FROM canon.ProductMedia AS mediaValue WHERE mediaValue.ProductId = product.ProductId),
    PendingOutboundCount = (SELECT COUNT_BIG(*) FROM out.OutboxMessage AS message WHERE message.OrganizationId = product.OrganizationId AND message.TargetKind = N''SAOP_PRODUCT'' AND message.EntityKey = product.ItemID AND message.Status IN (N''PendingApproval'', N''Pending'', N''Sending'', N''Sent'', N''Error'', N''Retry'', N''Drift'')),
    LastChangedUtc = COALESCE(lastChange.ChangedAtUtc, product.LastValidatedUtc)
  FROM paged
  INNER JOIN canon.Product AS product ON product.ProductId = paged.ProductId
  LEFT JOIN dbo.OrganizationConfig AS organizationValue ON organizationValue.OrganizationId = product.OrganizationId
  LEFT JOIN canon.PartnerName AS supplierPartner
    ON supplierPartner.OrganizationId = product.OrganizationId AND supplierPartner.PartnerCode = product.Supplier
  LEFT JOIN canon.PartnerName AS manufacturerPartner
    ON manufacturerPartner.OrganizationId = product.OrganizationId AND manufacturerPartner.PartnerCode = product.Manufacturer
  OUTER APPLY
  (
    SELECT TOP (1) textValue.Value
    FROM canon.ProductText AS textValue
    WHERE textValue.ProductId = product.ProductId AND textValue.TextType = N''WEB_TITLE''
    ORDER BY CASE WHEN textValue.Lang = @Language THEN 0 WHEN textValue.Lang = N''sl'' THEN 1 ELSE 2 END, textValue.Lang
  ) AS webTitle
  OUTER APPLY
  (
    SELECT TOP (1) textValue.Value
    FROM canon.ProductText AS textValue
    WHERE textValue.ProductId = product.ProductId AND textValue.TextType = N''TITLE_ERP''
    ORDER BY CASE WHEN textValue.Lang = @Language THEN 0 WHEN textValue.Lang = N''sl'' THEN 1 ELSE 2 END, textValue.Lang
  ) AS erpTitle
  OUTER APPLY
  (
    SELECT TOP (1) media.Url
    FROM canon.ProductMedia AS media
    WHERE media.ProductId = product.ProductId
    ORDER BY CASE WHEN media.Role IN (N''MAIN'', N''Glavna'', N''Primary'') THEN 0 ELSE 1 END, media.SortOrder, media.ProductMediaId
  ) AS thumbnail
  OUTER APPLY
  (
    SELECT TOP (1) history.ChangedAtUtc
    FROM pim.ProductFieldHistory AS history
    WHERE history.OrganizationId = product.OrganizationId AND history.ProductId = product.ProductId
    ORDER BY history.ChangedAtUtc DESC, history.ChangeId DESC
  ) AS lastChange
  LEFT JOIN pim.Product AS promoted ON promoted.OrganizationId = product.OrganizationId AND promoted.ItemID = product.ItemID
  ORDER BY
    CASE WHEN @SortDescending = 0 AND @Sort = N''COMPLETENESS'' THEN product.Completeness END ASC,
    CASE WHEN @SortDescending = 1 AND @Sort = N''COMPLETENESS'' THEN product.Completeness END DESC,
    CASE WHEN @SortDescending = 0 AND @Sort = N''CHANGED'' THEN product.LastValidatedUtc END ASC,
    CASE WHEN @SortDescending = 1 AND @Sort = N''CHANGED'' THEN product.LastValidatedUtc END DESC,
    CASE WHEN @SortDescending = 0 AND @Sort = N''ORGANIZATION'' THEN product.OrganizationId END ASC,
    CASE WHEN @SortDescending = 1 AND @Sort = N''ORGANIZATION'' THEN product.OrganizationId END DESC,
    CASE WHEN @SortDescending = 1 AND @Sort NOT IN (N''COMPLETENESS'', N''CHANGED'', N''ORGANIZATION'') THEN product.ItemID END DESC,
    CASE WHEN @SortDescending = 0 AND @Sort NOT IN (N''COMPLETENESS'', N''CHANGED'', N''ORGANIZATION'') THEN product.ItemID END ASC,
    product.ItemID, product.ProductId
  OPTION (RECOMPILE);

  SELECT TotalCount = COUNT_BIG(*)
  FROM canon.Product AS product
  WHERE @UnknownOrganization = 0
    AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
    AND (@Like IS NULL OR product.ItemID LIKE @Like OR product.EAN LIKE @Like)
    AND (@Manufacturer IS NULL OR product.Manufacturer = @Manufacturer)
    AND (@Supplier IS NULL OR product.Supplier = @Supplier)
    AND (@ItemGroup IS NULL OR product.ItemGroup = @ItemGroup)
    AND (@Department IS NULL OR product.Department = @Department)
    AND (@Activity IS NULL OR product.IsActive = CASE WHEN @Activity = N''ACTIVE'' THEN 1 ELSE 0 END)
    AND (@WebPublish IS NULL OR product.WebPublish = CASE WHEN @WebPublish = N''YES'' THEN 1 ELSE 0 END)
    AND
    (
      @HasImage IS NULL
      OR (@HasImage = N''YES'' AND EXISTS (SELECT 1 FROM canon.ProductMedia AS imageValue WHERE imageValue.ProductId = product.ProductId))
      OR (@HasImage = N''NO'' AND NOT EXISTS (SELECT 1 FROM canon.ProductMedia AS imageValue WHERE imageValue.ProductId = product.ProductId))
    )
    AND (@CategoryCode IS NULL OR EXISTS
      (SELECT 1 FROM #CategoryProduct AS kategorija WHERE kategorija.ProductId = product.ProductId))
    AND
    (
      @Completeness IS NULL
      OR (@Completeness = N''EMPTY'' AND product.Completeness = 0)
      OR (@Completeness = N''LOW'' AND product.Completeness > 0 AND product.Completeness < 50)
      OR (@Completeness = N''MID'' AND product.Completeness >= 50 AND product.Completeness < 100)
      OR (@Completeness = N''FULL'' AND product.Completeness >= 100)
    )
    AND
    (
      @View IS NULL
      OR (@View = N''TO_FIX'' AND product.ValidationStatus <> N''VALID'')
      OR (@View = N''NO_IMAGE'' AND NOT EXISTS (SELECT 1 FROM canon.ProductMedia AS media WHERE media.ProductId = product.ProductId))
      OR (@View = N''NO_WEB_TITLE'' AND NOT EXISTS (SELECT 1 FROM canon.ProductText AS titleValue WHERE titleValue.ProductId = product.ProductId AND titleValue.TextType = N''WEB_TITLE''))
      OR (@View = N''NO_CATEGORY'' AND NOT EXISTS (SELECT 1 FROM canon.ProductCategory AS categoryValue WHERE categoryValue.ProductId = product.ProductId))
      OR (@View = N''NO_EAN'' AND product.EAN IS NULL)
      OR (@View = N''NOT_PUBLISHED'' AND NOT EXISTS (SELECT 1 FROM pim.Product AS promoted WHERE promoted.OrganizationId = product.OrganizationId AND promoted.ItemID = product.ItemID))
      OR (@View = N''WAITING_SAOP'' AND EXISTS (SELECT 1 FROM out.OutboxMessage AS message WHERE message.OrganizationId = product.OrganizationId AND message.TargetKind = N''SAOP_PRODUCT'' AND message.EntityKey = product.ItemID AND message.Status IN (N''PendingApproval'', N''Pending'', N''Sending'', N''Sent'', N''Error'', N''Retry'', N''Drift'')))
    )
    AND
    (
      @ErpStatus IS NULL
      OR (@ErpStatus = N''VALID'' AND EXISTS (SELECT 1 FROM #ErpValid AS erpValid WHERE erpValid.ProductId = product.ProductId))
      OR (@ErpStatus = N''INVALID'' AND NOT EXISTS (SELECT 1 FROM #ErpValid AS erpValid WHERE erpValid.ProductId = product.ProductId))
    )
    AND
    (
      @WebStatus IS NULL
      OR (@WebStatus = N''VALID'' AND EXISTS (SELECT 1 FROM #WebValid AS webValid WHERE webValid.ProductId = product.ProductId))
      OR (@WebStatus = N''INVALID'' AND NOT EXISTS (SELECT 1 FROM #WebValid AS webValid WHERE webValid.ProductId = product.ProductId))
    )
  OPTION (RECOMPILE);

  DROP TABLE #ErpValid;
  DROP TABLE #WebValid;
  DROP TABLE #CategoryProduct;
END;');

/* --- 2) Sifrant atributov delovnega lista pozna nabor kategorije --------------------------- */

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetProductWorkbook
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

  /* 4) Slike. */
  SELECT
    media.ProductId,
    Urls = STRING_AGG(CONVERT(nvarchar(max), media.Url), N'' | '') WITHIN GROUP (ORDER BY media.SortOrder)
  FROM canon.ProductMedia AS media
  INNER JOIN @Products AS product ON product.ProductId = media.ProductId
  GROUP BY media.ProductId;

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

/* --- 3) Dokaz, da je migracija naredila, kar pise ------------------------------------------ */

IF NOT EXISTS (SELECT 1 FROM sys.parameters WHERE object_id = OBJECT_ID(N'intranet.GetProductList') AND name = N'@CategoryCode')
  THROW 51750, N'175: intranet.GetProductList ne pozna filtra po kategoriji.', 1;
IF NOT EXISTS (SELECT 1 FROM sys.parameters WHERE object_id = OBJECT_ID(N'intranet.GetProductWorkbook') AND name = N'@CategoryCode')
  THROW 51751, N'175: intranet.GetProductWorkbook ne pozna kategorije.', 1;
IF NOT EXISTS (SELECT 1 FROM sys.sql_modules WHERE object_id = OBJECT_ID(N'intranet.GetProductWorkbook') AND definition LIKE N'%CategoryAttributeEffective%')
  THROW 51752, N'175: sifrant atributov ne bere nabora kategorije.', 1;
