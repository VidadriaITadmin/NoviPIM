/*
  105 — delovni seznam izdelkov cez vsa podjetja.

  Seznam je bral samo eno podjetje, ker je stran vzela dbo.OrganizationConfig TOP (1)
  ORDER BY OrganizationId, to pa je DEMO (17.425 izdelkov od 196.531). Ostalih 179.106
  izdelkov treh podjetij prek te strani ni bilo mogoce videti. Migracija odpre isti bralni
  model na vsa podjetja: @OrganizationId postane neobvezen, NULL pomeni vsa podjetja.
  Vsaka vrstica zdaj pove tudi, cigava je (OrganizationId, OrganizationName), sicer bi bila
  sifra artikla dvoumna — enaka sifra obstaja v vec podjetjih.

  Novi filtri so tisti, ki jih seznam ze ima v stolpcih in jih doslej ni bilo mogoce zoziti:
  oddelek (Department), aktivnost (IsActive), zastavica za splet (WebPublish) in razred
  popolnosti. Vsi so v isti obliki kot obstojeci — NULL pomeni brez omejitve.

  Zakaj nov indeks IX_CanonProduct_ItemOrg: privzeta razvrstitev je po sifri artikla; brez
  podjetja v pogoju je to razvrscanje cez 196.531 vrstic, ki ga UQ_CanonProduct_OrganizationItem
  (organizacija, sifra) ne pokrije, ker se zacne z organizacijo. Merjeno pred indeksom in po
  njem — stevilke so v TASKBOARD zapisu naloge.

  Nobena procedura nicesar ne pise; to je bralni model.
*/

SET XACT_ABORT ON;

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'canon.Product') AND name = N'IX_CanonProduct_ItemOrg')
  CREATE INDEX IX_CanonProduct_ItemOrg ON canon.Product(ItemID, OrganizationId) INCLUDE (Completeness, LastValidatedUtc);

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
  @Completeness nvarchar(20) = NULL
AS
BEGIN
  SET NOCOUNT ON;

  SET @Skip = CASE WHEN @Skip < 0 THEN 0 ELSE @Skip END;
  SET @Take = CASE WHEN @Take < 1 THEN 50 WHEN @Take > 200 THEN 200 ELSE @Take END;
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
  SET @Sort = COALESCE(NULLIF(UPPER(LTRIM(RTRIM(@Sort))), N''''), N''ITEM'');
  SET @Language = COALESCE(NULLIF(LTRIM(RTRIM(@Language)), N''''), N''sl'');
  IF @View = N''ALL'' SET @View = NULL;
  IF @ErpStatus NOT IN (N''VALID'', N''INVALID'') SET @ErpStatus = NULL;
  IF @WebStatus NOT IN (N''VALID'', N''INVALID'') SET @WebStatus = NULL;
  IF @Activity NOT IN (N''ACTIVE'', N''INACTIVE'') SET @Activity = NULL;
  IF @WebPublish NOT IN (N''YES'', N''NO'') SET @WebPublish = NULL;
  IF @Completeness NOT IN (N''EMPTY'', N''LOW'', N''MID'', N''FULL'') SET @Completeness = NULL;

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
END;');

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetProductListViews
  @OrganizationId int = NULL
AS
BEGIN
  SET NOCOUNT ON;

  DECLARE @UnknownOrganization bit = CASE
    WHEN @OrganizationId IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM dbo.OrganizationConfig AS orgValue WHERE orgValue.OrganizationId = @OrganizationId)
    THEN 1 ELSE 0 END;

  SELECT
    TotalCount = COUNT_BIG(*),
    ToFixCount = COALESCE(SUM(CASE WHEN product.ValidationStatus <> N''VALID'' THEN 1 ELSE 0 END), 0),
    NoImageCount = COALESCE(SUM(CASE WHEN media.ProductId IS NULL THEN 1 ELSE 0 END), 0),
    NoWebTitleCount = COALESCE(SUM(CASE WHEN webTitle.ProductId IS NULL THEN 1 ELSE 0 END), 0),
    NoCategoryCount = COALESCE(SUM(CASE WHEN categoryValue.ProductId IS NULL THEN 1 ELSE 0 END), 0),
    NoEanCount = COALESCE(SUM(CASE WHEN product.EAN IS NULL THEN 1 ELSE 0 END), 0),
    NotPublishedCount = COALESCE(SUM(CASE WHEN promoted.ItemID IS NULL THEN 1 ELSE 0 END), 0),
    WaitingSaopCount = COALESCE(SUM(CASE WHEN waiting.EntityKey IS NULL THEN 0 ELSE 1 END), 0)
  FROM canon.Product AS product
  LEFT JOIN (SELECT DISTINCT mediaValue.ProductId FROM canon.ProductMedia AS mediaValue) AS media
    ON media.ProductId = product.ProductId
  LEFT JOIN (SELECT DISTINCT textValue.ProductId FROM canon.ProductText AS textValue WHERE textValue.TextType = N''WEB_TITLE'') AS webTitle
    ON webTitle.ProductId = product.ProductId
  LEFT JOIN (SELECT DISTINCT categoryRow.ProductId FROM canon.ProductCategory AS categoryRow) AS categoryValue
    ON categoryValue.ProductId = product.ProductId
  LEFT JOIN pim.Product AS promoted
    ON promoted.OrganizationId = product.OrganizationId AND promoted.ItemID = product.ItemID
  LEFT JOIN (SELECT DISTINCT message.OrganizationId, message.EntityKey FROM out.OutboxMessage AS message WHERE message.TargetKind = N''SAOP_PRODUCT'' AND message.Status IN (N''PendingApproval'', N''Pending'', N''Sending'', N''Sent'', N''Error'', N''Retry'', N''Drift'')) AS waiting
    ON waiting.OrganizationId = product.OrganizationId AND waiting.EntityKey = product.ItemID
  WHERE @UnknownOrganization = 0
    AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
  OPTION (RECOMPILE);
END;');

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetProductListFilters
  @OrganizationId int = NULL,
  @Take int = 100
AS
BEGIN
  SET NOCOUNT ON;
  SET @Take = CASE WHEN @Take < 1 THEN 100 WHEN @Take > 500 THEN 500 ELSE @Take END;

  DECLARE @UnknownOrganization bit = CASE
    WHEN @OrganizationId IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM dbo.OrganizationConfig AS orgValue WHERE orgValue.OrganizationId = @OrganizationId)
    THEN 1 ELSE 0 END;

  SELECT TOP (@Take) FacetKind = N''MANUFACTURER'', FacetValue = product.Manufacturer, ProductCount = COUNT_BIG(*)
  FROM canon.Product AS product
  WHERE @UnknownOrganization = 0 AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
    AND product.Manufacturer IS NOT NULL
  GROUP BY product.Manufacturer
  ORDER BY COUNT_BIG(*) DESC, product.Manufacturer
  OPTION (RECOMPILE);

  SELECT TOP (@Take) FacetKind = N''SUPPLIER'', FacetValue = product.Supplier, ProductCount = COUNT_BIG(*)
  FROM canon.Product AS product
  WHERE @UnknownOrganization = 0 AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
    AND product.Supplier IS NOT NULL
  GROUP BY product.Supplier
  ORDER BY COUNT_BIG(*) DESC, product.Supplier
  OPTION (RECOMPILE);

  SELECT TOP (@Take) FacetKind = N''ITEM_GROUP'', FacetValue = product.ItemGroup, ProductCount = COUNT_BIG(*)
  FROM canon.Product AS product
  WHERE @UnknownOrganization = 0 AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
    AND product.ItemGroup IS NOT NULL
  GROUP BY product.ItemGroup
  ORDER BY COUNT_BIG(*) DESC, product.ItemGroup
  OPTION (RECOMPILE);

  SELECT TOP (@Take) FacetKind = N''DEPARTMENT'', FacetValue = product.Department, ProductCount = COUNT_BIG(*)
  FROM canon.Product AS product
  WHERE @UnknownOrganization = 0 AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
    AND product.Department IS NOT NULL
  GROUP BY product.Department
  ORDER BY COUNT_BIG(*) DESC, product.Department
  OPTION (RECOMPILE);
END;');
