/*
  115 — dobavitelj in proizvajalec dobita ime; izvoz gre v enem klicu.

  Dve napaki, obe vidni na zaslonu:

  1. **Filtra »dobavitelj« in »proizvajalec« sta ponujala šifre** (0000061), ne imen. Vprašanje
     uporabnika je bilo: kje sploh je določeno, kdo je kdo? Odgovor je v preslikavah — obe polji
     prideta izključno iz SAOP dokumenta ItemGeneralData:

         StockData/SupplierID     → Product.Supplier
         StockData/ManufacturerID → Product.Manufacturer

     To sta **šifri partnerja v SAOP**, ne imeni. Register imen v katalogu ne obstaja
     (canon.Codebook ima samo CURRENCY, PRICELIST in TECHPROCESS), imena istih šifer pa so že
     zajeta v b2b.Customer — to je isti šifrant partnerjev iz SAOP. Merjeno: 273 od 275 šifer
     dobaviteljev in 290 od 292 šifer proizvajalcev se ujame z b2b.Customer. Zato filter in
     seznam odslej kažeta ime, šifra pa ostane ob njem, ker je ona tista, ki gre nazaj v SAOP.

     Kjer imena ni (2 šifri), ostane šifra sama — izmišljati je ne gre.

  2. **Izvoz v Excel ni deloval.** Stran je zvezek sestavljala s 100 zaporednimi klici po 200
     vrstic, ker je bila zgornja meja @Take 200. Vsak klic z večjim @Skip je dražji (OFFSET),
     brskalnik pa je zahtevo prekinil, preden je datoteka nastala — od tod TaskCanceledException
     v dnevniku. Meja @Take je zato dvignjena na 20.000: izvoz je en klic, stran ostane pri 50.

  Nobena procedura ničesar ne piše.
*/

SET XACT_ABORT ON;

/* Ime partnerja za šifro. Pogled, ne stolpec: šifrant je last b2b, katalog pa hrani šifro,
   ki potuje nazaj v SAOP. Kopija imena v canon.Product bi bila drugi vir resnice. */
EXEC(N'
CREATE OR ALTER VIEW canon.PartnerName
AS
SELECT customer.OrganizationId, PartnerCode = customer.CustomerKey, PartnerName = customer.Name
FROM b2b.Customer AS customer;');

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

  /* FacetLabel je to, kar uporabnik bere; FacetValue ostane sifra, ker z njo filtriramo. */
  SELECT TOP (@Take) FacetKind = N''MANUFACTURER'', FacetValue = grouped.koda,
    FacetLabel = COALESCE(MAX(partner.PartnerName), grouped.koda), ProductCount = SUM(grouped.stevilo)
  FROM
  (
    SELECT koda = product.Manufacturer, product.OrganizationId, stevilo = COUNT_BIG(*)
    FROM canon.Product AS product
    WHERE @UnknownOrganization = 0 AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
      AND product.Manufacturer IS NOT NULL
    GROUP BY product.Manufacturer, product.OrganizationId
  ) AS grouped
  LEFT JOIN canon.PartnerName AS partner
    ON partner.OrganizationId = grouped.OrganizationId AND partner.PartnerCode = grouped.koda
  GROUP BY grouped.koda
  ORDER BY SUM(grouped.stevilo) DESC, COALESCE(MAX(partner.PartnerName), grouped.koda)
  OPTION (RECOMPILE);

  SELECT TOP (@Take) FacetKind = N''SUPPLIER'', FacetValue = grouped.koda,
    FacetLabel = COALESCE(MAX(partner.PartnerName), grouped.koda), ProductCount = SUM(grouped.stevilo)
  FROM
  (
    SELECT koda = product.Supplier, product.OrganizationId, stevilo = COUNT_BIG(*)
    FROM canon.Product AS product
    WHERE @UnknownOrganization = 0 AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
      AND product.Supplier IS NOT NULL
    GROUP BY product.Supplier, product.OrganizationId
  ) AS grouped
  LEFT JOIN canon.PartnerName AS partner
    ON partner.OrganizationId = grouped.OrganizationId AND partner.PartnerCode = grouped.koda
  GROUP BY grouped.koda
  ORDER BY SUM(grouped.stevilo) DESC, COALESCE(MAX(partner.PartnerName), grouped.koda)
  OPTION (RECOMPILE);

  SELECT TOP (@Take) FacetKind = N''ITEM_GROUP'', FacetValue = product.ItemGroup,
    FacetLabel = product.ItemGroup, ProductCount = COUNT_BIG(*)
  FROM canon.Product AS product
  WHERE @UnknownOrganization = 0 AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
    AND product.ItemGroup IS NOT NULL
  GROUP BY product.ItemGroup
  ORDER BY COUNT_BIG(*) DESC, product.ItemGroup
  OPTION (RECOMPILE);

  SELECT TOP (@Take) FacetKind = N''DEPARTMENT'', FacetValue = product.Department,
    FacetLabel = product.Department, ProductCount = COUNT_BIG(*)
  FROM canon.Product AS product
  WHERE @UnknownOrganization = 0 AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
    AND product.Department IS NOT NULL
  GROUP BY product.Department
  ORDER BY COUNT_BIG(*) DESC, product.Department
  OPTION (RECOMPILE);
END;');

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
