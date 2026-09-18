/*
  100 — celovita bralna kartica izdelka.

  Kartica mora na enem mestu odgovoriti, zakaj izdelek ni pripravljen za ERP ali splet in
  od kod so podatki prisli. Obstojec intranet.GetProductDetail je vracal samo glavo,
  validacijske profile, tezave in zgodovino. Novi proceduri dodata vse obstojecim virom;
  nobenega poslovnega podatka ne podvajata in nic ne zapisujeta.

  Izvor se poisce po dejanski izluseni identiteti. Meritev pred migracijo nad 837.404
  Product.ItemID vrednostmi je za reprezentativni izdelek vrnila 49 sledi v 415 ms.
  Namenskega indeksa nad nvarchar(max) zato ne dodajamo: poskus materializacije izracunane
  kolone nad celotno tabelo je presegel povezovalni cas in bi bil nesorazmeren s tem branjem.
*/

SET XACT_ABORT ON;

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetProductCard
  @OrganizationId int,
  @ProductId bigint,
  @Language nvarchar(20) = N''sl''
AS
BEGIN
  SET NOCOUNT ON;

  DECLARE @ItemID nvarchar(450), @ItemGroup nvarchar(100);
  SELECT @ItemID = product.ItemID, @ItemGroup = product.ItemGroup
  FROM canon.Product AS product
  WHERE product.OrganizationId = @OrganizationId AND product.ProductId = @ProductId;

  /* 1 — glava in locena pripravljenost ERP/splet. */
  SELECT product.ProductId, product.ItemID,
    product.EAN,
    Name = COALESCE(webTitle.Value, erpTitle.Value, product.ItemID),
    ThumbnailUrl = thumbnail.Url,
    product.IsActive, product.WebPublish,
    IsPromoted = CONVERT(bit, CASE WHEN promoted.PimProductId IS NULL THEN 0 ELSE 1 END),
    ErpStatus = CASE
      WHEN NOT EXISTS
      (
        SELECT 1 FROM val.ValidationProfile profileValue
        WHERE profileValue.IsActive = 1 AND profileValue.BlocksErp = 1
      ) THEN N''NOT_CONFIGURED''
      WHEN EXISTS
      (
        SELECT 1 FROM val.ValidationProfile profileValue
        LEFT JOIN val.ProductValidationState stateValue
          ON stateValue.ValidationProfileId = profileValue.ValidationProfileId
         AND stateValue.ProductId = product.ProductId
        WHERE profileValue.IsActive = 1 AND profileValue.BlocksErp = 1
          AND (stateValue.ProductValidationStateId IS NULL OR stateValue.Status <> N''VALID'')
      ) THEN N''INVALID'' ELSE N''VALID'' END,
    WebStatus = CASE
      WHEN NOT EXISTS
      (
        SELECT 1 FROM val.ValidationProfile profileValue
        WHERE profileValue.IsActive = 1 AND profileValue.BlocksWeb = 1
      ) THEN N''NOT_CONFIGURED''
      WHEN EXISTS
      (
        SELECT 1 FROM val.ValidationProfile profileValue
        LEFT JOIN val.ProductValidationState stateValue
          ON stateValue.ValidationProfileId = profileValue.ValidationProfileId
         AND stateValue.ProductId = product.ProductId
        WHERE profileValue.IsActive = 1 AND profileValue.BlocksWeb = 1
          AND (stateValue.ProductValidationStateId IS NULL OR stateValue.Status <> N''VALID'')
      ) THEN N''INVALID'' ELSE N''VALID'' END,
    product.ValidationStatus, product.Completeness, product.UoM, product.ItemGroup,
    product.Department, product.Manufacturer, product.Supplier, product.DiscountGroup,
    product.AccountingGroup, product.LastValidatedUtc,
    OpenIssueCount =
    (
      SELECT COUNT_BIG(*) FROM val.ProductIssue issueValue
      WHERE issueValue.ProductId = product.ProductId AND issueValue.IsActive = 1
    )
  FROM canon.Product AS product
  OUTER APPLY
  (
    SELECT TOP (1) textValue.Value
    FROM canon.ProductText AS textValue
    WHERE textValue.ProductId = product.ProductId
      AND textValue.TextType = N''WEB_TITLE''
      AND (@Language IS NULL OR textValue.Lang = @Language)
    ORDER BY CASE WHEN textValue.Lang = @Language THEN 0 ELSE 1 END, textValue.Lang
  ) AS webTitle
  OUTER APPLY
  (
    SELECT TOP (1) textValue.Value
    FROM canon.ProductText AS textValue
    WHERE textValue.ProductId = product.ProductId AND textValue.TextType = N''TITLE_ERP''
    ORDER BY CASE WHEN textValue.Lang = @Language THEN 0 WHEN textValue.Lang = N''sl'' THEN 1 ELSE 2 END,
      textValue.Lang
  ) AS erpTitle
  OUTER APPLY
  (
    SELECT TOP (1) media.Url
    FROM canon.ProductMedia AS media
    WHERE media.ProductId = product.ProductId
    ORDER BY CASE WHEN media.Role IN (N''MAIN'', N''Glavna'', N''Primary'') THEN 0 ELSE 1 END,
      media.SortOrder, media.ProductMediaId
  ) AS thumbnail
  LEFT JOIN pim.Product AS promoted
    ON promoted.OrganizationId = product.OrganizationId AND promoted.ItemID = product.ItemID
  WHERE product.OrganizationId = @OrganizationId AND product.ProductId = @ProductId;

  IF @ItemID IS NULL RETURN;

  /* 2 — kljucna polja z dejanskim lastnikom. */
  SELECT fieldValue.FieldKey, fieldValue.Label, fieldValue.Value,
    Owner = COALESCE(policyValue.Owner, ownership.Owner, N''SHARED'')
  FROM canon.Product AS product
  LEFT JOIN canon.ProductCommercial AS commercial ON commercial.ProductId = product.ProductId
  CROSS APPLY
  (
    VALUES
      (N''Product.ItemID'', N''Artikel'', CONVERT(nvarchar(4000), product.ItemID)),
      (N''Product.EAN'', N''EAN'', CONVERT(nvarchar(4000), product.EAN)),
      (N''Product.IsActive'', N''Aktiven'', CONVERT(nvarchar(4000), product.IsActive)),
      (N''Product.WebPublish'', N''Za splet'', CONVERT(nvarchar(4000), product.WebPublish)),
      (N''Product.UoM'', N''Enota mere'', CONVERT(nvarchar(4000), product.UoM)),
      (N''Product.ItemGroup'', N''Skupina'', CONVERT(nvarchar(4000), product.ItemGroup)),
      (N''Product.Department'', N''Oddelek'', CONVERT(nvarchar(4000), product.Department)),
      (N''Product.Manufacturer'', N''Proizvajalec'', CONVERT(nvarchar(4000), product.Manufacturer)),
      (N''Product.Supplier'', N''Dobavitelj'', CONVERT(nvarchar(4000), product.Supplier)),
      (N''Product.DiscountGroup'', N''Skupina popusta'', CONVERT(nvarchar(4000), product.DiscountGroup)),
      (N''Product.AccountingGroup'', N''Kontna skupina'', CONVERT(nvarchar(4000), product.AccountingGroup)),
      (N''ProductCommercial.NetWeight'', N''Neto teza'', CONVERT(nvarchar(4000), commercial.NetWeight)),
      (N''ProductCommercial.GrossWeight'', N''Bruto teza'', CONVERT(nvarchar(4000), commercial.GrossWeight)),
      (N''ProductCommercial.CustomsTariff'', N''Carinska tarifa'', CONVERT(nvarchar(4000), commercial.CustomsTariff)),
      (N''ProductCommercial.CountryOfOrigin'', N''Drzava porekla'', CONVERT(nvarchar(4000), commercial.CountryOfOrigin))
  ) AS fieldValue(FieldKey, Label, Value)
  OUTER APPLY
  (
    SELECT TOP (1) policy.Owner
    FROM out.OwnershipPolicy AS policy
    WHERE policy.OrganizationId = @OrganizationId AND policy.TargetKind = N''SAOP_PRODUCT''
      AND policy.FieldName = fieldValue.FieldKey AND policy.IsEnabled = 1
      AND policy.ConstraintKind IS NULL AND policy.ConstraintValue IS NULL
    ORDER BY policy.OwnershipPolicyId DESC
  ) AS policyValue
  LEFT JOIN pim.FieldOwnership AS ownership
    ON ownership.FieldKey = fieldValue.FieldKey AND ownership.IsActive = 1
  WHERE product.OrganizationId = @OrganizationId AND product.ProductId = @ProductId
  ORDER BY CASE fieldValue.FieldKey
    WHEN N''Product.ItemID'' THEN 1 WHEN N''Product.EAN'' THEN 2
    WHEN N''Product.IsActive'' THEN 3 WHEN N''Product.WebPublish'' THEN 4
    WHEN N''Product.UoM'' THEN 5 WHEN N''Product.ItemGroup'' THEN 6
    WHEN N''Product.Department'' THEN 7 WHEN N''Product.Manufacturer'' THEN 8
    WHEN N''Product.Supplier'' THEN 9 ELSE 20 END;

  /* 3 — cakajoce, poslane ali odklonjene vrednosti; logika ostane v obstojeci proceduri. */
  DECLARE @ItemIdsJson nvarchar(max) = N''["'' + STRING_ESCAPE(@ItemID, N''json'') + N''"]'';
  EXEC intranet.GetPendingOverlay
    @OrganizationId = @OrganizationId, @ItemIdsJson = @ItemIdsJson, @TargetKind = N''SAOP_PRODUCT'';

  /* 4 — besedila. */
  SELECT textValue.ProductTextId, textValue.Lang, textValue.TextType, textValue.Value,
    FieldKey = CONCAT(N''ProductText.'', textValue.TextType, N''.'', textValue.Lang),
    Owner = COALESCE(policyValue.Owner, N''SHARED'')
  FROM canon.ProductText AS textValue
  OUTER APPLY
  (
    SELECT TOP (1) policy.Owner
    FROM out.OwnershipPolicy AS policy
    WHERE policy.OrganizationId = @OrganizationId AND policy.TargetKind = N''SAOP_PRODUCT''
      AND policy.FieldName = CONCAT(N''ProductText.'', textValue.TextType, N''.'', textValue.Lang)
      AND policy.IsEnabled = 1
    ORDER BY policy.OwnershipPolicyId DESC
  ) AS policyValue
  WHERE textValue.ProductId = @ProductId
  ORDER BY textValue.Lang, textValue.TextType;

  /* 5 — lastnosti. */
  SELECT attributeValue.ProductAttributeId, attributeValue.AttributeCode, attributeValue.Value,
    FieldKey = CONCAT(N''ProductAttribute.'', attributeValue.AttributeCode),
    Owner = COALESCE(policyValue.Owner, N''SHARED'')
  FROM canon.ProductAttribute AS attributeValue
  OUTER APPLY
  (
    SELECT TOP (1) policy.Owner
    FROM out.OwnershipPolicy AS policy
    WHERE policy.OrganizationId = @OrganizationId AND policy.TargetKind = N''SAOP_PRODUCT''
      AND policy.FieldName = CONCAT(N''ProductAttribute.'', attributeValue.AttributeCode)
      AND policy.IsEnabled = 1
    ORDER BY policy.OwnershipPolicyId DESC
  ) AS policyValue
  WHERE attributeValue.ProductId = @ProductId
  ORDER BY attributeValue.AttributeCode;

  /* 6 — kategorije z razresenim imenom, kadar register vsebuje pot. */
  SELECT productCategory.ProductCategoryId, productCategory.WebSite, productCategory.CategoryPath,
    category.CategoryTreeCode, category.CategoryCode, category.CategoryName,
    Owner = COALESCE(policyValue.Owner, N''SHARED'')
  FROM canon.ProductCategory AS productCategory
  OUTER APPLY
  (
    SELECT TOP (1) categoryValue.CategoryTreeCode, categoryValue.CategoryCode, categoryValue.CategoryName
    FROM canon.Category AS categoryValue
    WHERE categoryValue.CategoryPath = productCategory.CategoryPath
      AND (categoryValue.CategoryTreeCode = productCategory.WebSite
        OR categoryValue.CategoryCode = productCategory.WebSite)
    ORDER BY CASE WHEN categoryValue.CategoryTreeCode = productCategory.WebSite THEN 0 ELSE 1 END,
      categoryValue.CategoryId
  ) AS category
  OUTER APPLY
  (
    SELECT TOP (1) policy.Owner
    FROM out.OwnershipPolicy AS policy
    WHERE policy.OrganizationId = @OrganizationId AND policy.TargetKind = N''SAOP_PRODUCT''
      AND policy.FieldName = N''ProductCategory.CategoryPath'' AND policy.IsEnabled = 1
    ORDER BY policy.OwnershipPolicyId DESC
  ) AS policyValue
  WHERE productCategory.ProductId = @ProductId
  ORDER BY productCategory.WebSite, productCategory.CategoryPath;

  /* 7 — slike in povezani mediji. */
  SELECT media.ProductMediaId, media.Url, media.Role, media.SortOrder,
    Owner = COALESCE(policyValue.Owner, N''SHARED'')
  FROM canon.ProductMedia AS media
  OUTER APPLY
  (
    SELECT TOP (1) policy.Owner
    FROM out.OwnershipPolicy AS policy
    WHERE policy.OrganizationId = @OrganizationId AND policy.TargetKind = N''SAOP_PRODUCT''
      AND policy.FieldName = N''ProductMedia.Url'' AND policy.IsEnabled = 1
    ORDER BY policy.OwnershipPolicyId DESC
  ) AS policyValue
  WHERE media.ProductId = @ProductId
  ORDER BY media.SortOrder, media.ProductMediaId;

  /* 8 — dokumenti so loceni od slik. */
  SELECT document.ProductDocumentId, document.Role, document.Url, document.Title, document.SortOrder
  FROM canon.ProductDocument AS document
  WHERE document.ProductId = @ProductId
  ORDER BY document.SortOrder, document.Role, document.ProductDocumentId;

  /* 9 — cene. */
  SELECT price.ProductPriceId, price.PriceList, price.Net, price.VatRate,
    Gross = CONVERT(decimal(19,4), price.Net * (1 + price.VatRate / 100)),
    price.ValidFrom, price.IsActive
  FROM canon.ProductPrice AS price
  WHERE price.ProductId = @ProductId
  ORDER BY price.IsActive DESC, price.PriceList, price.ValidFrom DESC;

  /* 10 — dejanska zaloga in pravilo min/max po skladiscu. */
  SELECT position.PositionId, snapshot.SnapshotId, snapshot.ProviderKind, snapshot.Endpoint,
    snapshot.SnapshotUtc, position.Quantity, position.AvailabilityDate, position.IncomingQuantity,
    position.MatchKey, warehouse.WarehouseCode, warehouse.Name AS WarehouseName,
    policy.MinimumStock, policy.MaximumStock
  FROM stock.Position AS position
  INNER JOIN stock.Snapshot AS snapshot ON snapshot.SnapshotId = position.SnapshotId
  LEFT JOIN canon.Warehouse AS warehouse
    ON warehouse.OrganizationId = snapshot.OrganizationId
   AND (warehouse.WarehouseCode = position.MatchKey OR warehouse.WarehouseCode = snapshot.Endpoint)
  LEFT JOIN canon.ProductStockPolicy AS policy
    ON policy.ProductId = position.MatchedProductId
   AND policy.WarehouseCode = COALESCE(warehouse.WarehouseCode, position.MatchKey)
  WHERE position.MatchedProductId = @ProductId AND snapshot.OrganizationId = @OrganizationId
    AND snapshot.IsActive = 1
  ORDER BY snapshot.SnapshotUtc DESC, position.PositionId DESC;

  /* 11 — trgovinski podatki. */
  SELECT commercial.ProductCommercialId, commercial.NetWeight, commercial.GrossWeight,
    commercial.CustomsTariff, commercial.CountryOfOrigin, commercial.Pak1, commercial.Pak2,
    commercial.Dimensions, commercial.Volume, commercial.PackageLength,
    commercial.PackageWidth, commercial.PackageHeight, commercial.DimensionUnit
  FROM canon.ProductCommercial AS commercial
  WHERE commercial.ProductId = @ProductId;

  /* 12 — profili povedo tudi, kaj blokirajo. */
  SELECT profileValue.ValidationProfileId, profileValue.ProfileCode, profileValue.Name,
    profileValue.Scope, profileValue.BlocksErp, profileValue.BlocksWeb,
    Status = COALESCE(stateValue.Status, N''PENDING''),
    Completeness = COALESCE(stateValue.Completeness, CONVERT(decimal(5,2), 0)),
    stateValue.ValidatedUtc,
    OpenIssueCount =
    (
      SELECT COUNT_BIG(*) FROM val.ProductIssue issueValue
      WHERE issueValue.ProductId = @ProductId
        AND issueValue.ValidationProfileId = profileValue.ValidationProfileId
        AND issueValue.IsActive = 1
    )
  FROM val.ValidationProfile AS profileValue
  LEFT JOIN val.ProductValidationState AS stateValue
    ON stateValue.ValidationProfileId = profileValue.ValidationProfileId
   AND stateValue.ProductId = @ProductId
  WHERE profileValue.IsActive = 1
  ORDER BY profileValue.BlocksErp DESC, profileValue.BlocksWeb DESC, profileValue.ProfileCode;

  /* 13 — tezava pove manjkajoce polje, resnost in posledico. */
  SELECT issueValue.ProductIssueId, profileValue.ProfileCode, requirement.FieldCode,
    requirement.Severity, profileValue.BlocksErp, profileValue.BlocksWeb,
    issueValue.IssueCode, issueValue.Message, issueValue.FirstDetectedUtc,
    issueValue.LastDetectedUtc
  FROM val.ProductIssue AS issueValue
  INNER JOIN val.ValidationProfile AS profileValue
    ON profileValue.ValidationProfileId = issueValue.ValidationProfileId
  INNER JOIN val.FieldRequirement AS requirement
    ON requirement.FieldRequirementId = issueValue.FieldRequirementId
  WHERE issueValue.ProductId = @ProductId AND issueValue.IsActive = 1
  ORDER BY CASE requirement.Severity WHEN N''ERROR'' THEN 0 ELSE 1 END,
    profileValue.ProfileCode, requirement.FieldCode;

  /* 14 — odhodna pot z zadnjim dejanskim poskusom. */
  SELECT message.OutboxMessageId, message.Operation, message.EntityType, message.EntityKey,
    message.FieldSummary, message.Status, message.AttemptCount, message.LastError,
    message.DriftDetail, message.CreatedUtc, message.ApprovedUtc, message.SentUtc,
    message.VerifiedUtc, message.UpdatedUtc, message.OutboundBatchId,
    attempt.AttemptNumber, attempt.Outcome AS AttemptOutcome,
    attempt.StartedUtc AS AttemptStartedUtc, attempt.CompletedUtc AS AttemptCompletedUtc,
    attempt.FailureReason AS AttemptFailureReason
  FROM out.OutboxMessage AS message
  OUTER APPLY
  (
    SELECT TOP (1) attemptValue.AttemptNumber, attemptValue.Outcome,
      attemptValue.StartedUtc, attemptValue.CompletedUtc, attemptValue.FailureReason
    FROM out.OutboxAttempt AS attemptValue
    WHERE attemptValue.OutboxMessageId = message.OutboxMessageId
    ORDER BY attemptValue.AttemptNumber DESC, attemptValue.OutboxAttemptId DESC
  ) AS attempt
  WHERE message.OrganizationId = @OrganizationId AND message.TargetKind = N''SAOP_PRODUCT''
    AND message.EntityKey = @ItemID
  ORDER BY message.CreatedUtc DESC, message.OutboxMessageId DESC;

  /* 15 — zgodovina z avtorjem, paketom in razlogom. */
  SELECT history.ChangeId, history.ChangeBatchId, history.FieldKey, history.Owner,
    history.OldValue, history.NewValue, history.ChangedAtUtc, history.SentToSaopAtUtc,
    history.UndoOfChangeId, batch.BatchId, batch.ChangeSource, batch.ChangedBy, batch.Note
  FROM pim.ProductFieldHistory AS history
  INNER JOIN pim.ProductChangeBatch AS batch ON batch.ChangeBatchId = history.ChangeBatchId
  WHERE history.OrganizationId = @OrganizationId AND history.ProductId = @ProductId
  ORDER BY history.ChangedAtUtc DESC, history.ChangeId DESC;
END;');

EXEC(N'
CREATE OR ALTER PROCEDURE intranet.GetProductOrigin
  @OrganizationId int,
  @ProductId bigint
AS
BEGIN
  SET NOCOUNT ON;

  DECLARE @ItemID nvarchar(450), @EAN nvarchar(450);
  SELECT @ItemID = product.ItemID, @EAN = product.EAN
  FROM canon.Product AS product
  WHERE product.OrganizationId = @OrganizationId AND product.ProductId = @ProductId;

  IF @ItemID IS NULL
  BEGIN
    SELECT TOP (0) inbox.InboxId, inbox.RunId, inbox.SourceCode, inbox.EntityType,
      inbox.PageNumber, inbox.Status, inbox.ReceivedUtc, inbox.ProcessedUtc,
      CONVERT(int, NULL) AS RecordOrdinal, CONVERT(bigint, 0) AS ExtractedFieldCount
    FROM raw.Inbox AS inbox;
    RETURN;
  END;

  ;WITH identityValue AS
  (
    SELECT extracted.InboxId, extracted.RecordOrdinal,
      ItemID = MAX(CASE WHEN extracted.TargetFieldCode IN (N''Product.ItemID'', N''Record.ItemID'')
        AND extracted.Value = @ItemID THEN @ItemID END),
      EAN = MAX(CASE WHEN extracted.TargetFieldCode = N''Product.EAN''
        AND @EAN IS NOT NULL AND extracted.Value = @EAN THEN @EAN END)
    FROM map.ExtractedValue AS extracted
    WHERE
      (extracted.TargetFieldCode IN (N''Product.ItemID'', N''Record.ItemID'')
        AND extracted.Value = @ItemID)
      OR
      (extracted.TargetFieldCode = N''Product.EAN'' AND @EAN IS NOT NULL
        AND extracted.Value = @EAN)
    GROUP BY extracted.InboxId, extracted.RecordOrdinal
  )
  SELECT TOP (100) inbox.InboxId, inbox.RunId, inbox.SourceCode, inbox.EntityType,
    inbox.PageNumber, inbox.Status, inbox.ReceivedUtc, inbox.ProcessedUtc,
    identityValue.RecordOrdinal,
    ExtractedFieldCount =
    (
      SELECT COUNT_BIG(*) FROM map.ExtractedValue AS fieldValue
      WHERE fieldValue.InboxId = identityValue.InboxId
        AND fieldValue.RecordOrdinal = identityValue.RecordOrdinal
    )
  FROM identityValue
  INNER JOIN raw.Inbox AS inbox ON inbox.InboxId = identityValue.InboxId
  WHERE inbox.OrganizationId = @OrganizationId
    AND (identityValue.ItemID = @ItemID OR (identityValue.ItemID IS NULL AND identityValue.EAN = @EAN))
  ORDER BY inbox.ReceivedUtc DESC, inbox.InboxId DESC, identityValue.RecordOrdinal DESC;
END;');

IF OBJECT_ID(N'intranet.GetProductCard', N'P') IS NULL
  THROW 53000, 'Bralna procedura kartice izdelka ni nastala.', 1;

IF OBJECT_ID(N'intranet.GetProductOrigin', N'P') IS NULL
  THROW 53001, 'Bralna procedura izvora izdelka ni nastala.', 1;
