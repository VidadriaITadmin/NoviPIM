/*
  274 - S-popusti na polno pakiranje: pravila po tipu stranke, stranki, rabatni skupini in S kodi;
        filtri na seznamu izdelkov; S v delovnem listu izdelkov; izvoz v katalog.csv.

  Uporabnik 2026-09-23 (cenik ceniki_skupine_popusta_vpak.xlsx + Magento_Pravila_Cene_Popusti_Postnine
  §4.4, §4.5, §4.8): »artikle urejajo po skupinah strank ali celo po posamezni stranki ali po rabatnih
  skupinah ... da se spremeni S popust za vse INSTALATERJE ... in pod stranko se morajo videti, katerim
  artiklom ima stranka katere S-e«.

  Stanje pred migracijo:
    - privzeti S izdelka: pim.ProductPackagingDiscount (020, vpis 214) - intranet ga ni nikjer pisal;
    - posebni S je bil samo stranka x izdelek (b2b.CustomerPackagingDiscountOverride, 020/216).

  Kaj naredi:
    1. b2b.PackagingDiscountRule - ENA tabela vseh posebnih S:
         komu:        TargetKind = TYPE (tip stranke) | CUSTOMER (stranka)
         za kaj:      ScopeKind  = ITEM (en izdelek) | ITEM_GROUP (rabatna skupina, canon.Product.DiscountGroup)
                                   | S_CODE (vsi izdelki, ki imajo privzeto to S kodo) | ALL (vsi izdelki)
         nova koda:   DiscountCode (S1-S4 iz pim.PackagingDiscountCatalog), veljavnost od/do.
       Obstojece vrstice 216 se prenesejo (CUSTOMER/ITEM). Stara tabela ostane kot
       b2b.CustomerPackagingDiscountOverride_pred274, ime pa nosi pogled z istimi stolpci, da
       bralci (kartica stranke 129, delovni list strank 250) delujejo naprej.
    2. b2b.PackagingDiscountSpecials(@OrganizationId, @OnDate) - ucinkoviti posebni S: za vsak cilj
       (tip ali stranka) in izdelek zmaga najbolj specificno pravilo ITEM > S_CODE > ITEM_GROUP > ALL.
       Stranka ima prednost pred svojim tipom (to razresi bralec: kartica stranke, Magento).
    3. Vpis: b2b.SavePackagingDiscountRule / b2b.RemovePackagingDiscountRule (revizija b2b.AuditLog);
       216-ki proceduri za stranko x izdelek pisete odslej v novo tabelo.
       pim.SaveProductPackagingDiscountsBulk - privzeti S za vec izdelkov naenkrat (delovni list, cenik).
       pim.SavePackagingDiscountPercent - odstotek S kode (sifrant S1-S4).
    4. Branje: intranet.GetProductPackagingDiscount (kartica izdelka, + nabor posebnih S),
       intranet.GetProductPackagingDiscountSheet (delovni list), intranet.GetPackagingDiscountRules
       (stran Pravila), intranet.GetCustomerPackagingDiscounts (kartica stranke).
    5. intranet.GetProductList: filtri @PackagingDiscount (S1-S4/NONE/ANY), @DiscountGroup (rabatna
       skupina), @SpecialFor (TYPE:koda | CUSTOMER:sifra | ANY); intranet.GetProductListFilters:
       faseta DISCOUNT_GROUP; indeks canon.Product (OrganizationId, DiscountGroup).
    6. out.GetExportRows (katalog.csv): »Posebni popust za stranko« (COL037) = ucinkoviti S po stranki
       (tudi iz pravil po skupini, S kodi, vseh izdelkih); nov stolpec COL037B »Posebni S za skupino
       strank« (na koncu profila, za dodatki 234) = Magento skupina\Skoda iz pravil po tipu stranke. Oznaka /* SpecialS274 */.
    7. intranet.GetCustomerList: stolpec SpecialDiscounts nosi vsa pravila stranke v zapisu
       ARTIKEL\S2 | SKUPINA:BRAYTRON\S3 | S:S2\S3 | *\S3 (isti zapis bere delovni list strank).

  Rocni korak: ne. Na strezniku, kjer tece Magento izvoz, se naslednji katalog.csv zgradi z novim
  stolpcem sam (register out.ExportColumn).
*/

SET XACT_ABORT ON;
SET NOCOUNT ON;

/* --- 1) tabela pravil ------------------------------------------------------------------------ */

IF OBJECT_ID(N'b2b.PackagingDiscountRule', N'U') IS NULL
BEGIN
  CREATE TABLE b2b.PackagingDiscountRule
  (
    RuleId bigint IDENTITY(1, 1) NOT NULL CONSTRAINT PK_PackagingDiscountRule PRIMARY KEY,
    OrganizationId int NOT NULL,
    TargetKind nvarchar(10) NOT NULL,
    CustomerTypeCode nvarchar(60) NULL,
    CustomerId bigint NULL,
    ScopeKind nvarchar(12) NOT NULL,
    PimProductId bigint NULL,
    ItemGroupCode nvarchar(100) NULL,
    FromDiscountCode nvarchar(10) NULL,
    DiscountCode nvarchar(10) NOT NULL,
    ValidFrom date NULL,
    ValidTo date NULL,
    IsActive bit NOT NULL CONSTRAINT DF_PackagingDiscountRule_Active DEFAULT (1),
    Note nvarchar(400) NULL,
    CreatedUtc datetime2(3) NOT NULL CONSTRAINT DF_PackagingDiscountRule_Created DEFAULT SYSUTCDATETIME(),
    CreatedBy nvarchar(200) NULL,
    UpdatedUtc datetime2(3) NOT NULL CONSTRAINT DF_PackagingDiscountRule_Updated DEFAULT SYSUTCDATETIME(),
    UpdatedBy nvarchar(200) NULL,
    CONSTRAINT FK_PackagingDiscountRule_Organization FOREIGN KEY (OrganizationId) REFERENCES dbo.OrganizationConfig (OrganizationId),
    CONSTRAINT FK_PackagingDiscountRule_Type FOREIGN KEY (CustomerTypeCode) REFERENCES pim.CustomerTypeCatalog (CustomerTypeCode),
    CONSTRAINT FK_PackagingDiscountRule_Customer FOREIGN KEY (CustomerId) REFERENCES b2b.Customer (CustomerId),
    CONSTRAINT FK_PackagingDiscountRule_Product FOREIGN KEY (PimProductId) REFERENCES pim.Product (PimProductId),
    CONSTRAINT FK_PackagingDiscountRule_From FOREIGN KEY (FromDiscountCode) REFERENCES pim.PackagingDiscountCatalog (DiscountCode),
    CONSTRAINT FK_PackagingDiscountRule_Code FOREIGN KEY (DiscountCode) REFERENCES pim.PackagingDiscountCatalog (DiscountCode),
    CONSTRAINT CK_PackagingDiscountRule_Target CHECK
      ((TargetKind = N'TYPE' AND CustomerTypeCode IS NOT NULL AND CustomerId IS NULL)
    OR (TargetKind = N'CUSTOMER' AND CustomerId IS NOT NULL AND CustomerTypeCode IS NULL)),
    CONSTRAINT CK_PackagingDiscountRule_Scope CHECK
      ((ScopeKind = N'ITEM' AND PimProductId IS NOT NULL AND ItemGroupCode IS NULL AND FromDiscountCode IS NULL)
    OR (ScopeKind = N'ITEM_GROUP' AND PimProductId IS NULL AND ItemGroupCode IS NOT NULL AND FromDiscountCode IS NULL)
    OR (ScopeKind = N'S_CODE' AND PimProductId IS NULL AND ItemGroupCode IS NULL AND FromDiscountCode IS NOT NULL)
    OR (ScopeKind = N'ALL' AND PimProductId IS NULL AND ItemGroupCode IS NULL AND FromDiscountCode IS NULL)),
    CONSTRAINT CK_PackagingDiscountRule_Dates CHECK (ValidFrom IS NULL OR ValidTo IS NULL OR ValidTo >= ValidFrom)
  );

  /* En veljaven zapis na cilj in obseg - vpisna procedura starega umakne, preden zapise novega. */
  CREATE UNIQUE INDEX UX_PackagingDiscountRule_ActiveKey
    ON b2b.PackagingDiscountRule (OrganizationId, TargetKind, CustomerTypeCode, CustomerId, ScopeKind, PimProductId, ItemGroupCode, FromDiscountCode)
    WHERE IsActive = 1;
  CREATE INDEX IX_PackagingDiscountRule_Product ON b2b.PackagingDiscountRule (PimProductId) WHERE PimProductId IS NOT NULL;
  CREATE INDEX IX_PackagingDiscountRule_Customer ON b2b.PackagingDiscountRule (CustomerId) WHERE CustomerId IS NOT NULL;
END;

/* Filter in faseta po rabatni skupini na seznamu izdelkov. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'canon.Product') AND name = N'IX_CanonProduct_OrgDiscountGroup')
  CREATE INDEX IX_CanonProduct_OrgDiscountGroup ON canon.Product (OrganizationId, DiscountGroup) WHERE DiscountGroup IS NOT NULL;

/* --- 1b) prenos 216 -> 274 in pogled z imenom stare tabele ------------------------------------ */

IF OBJECT_ID(N'b2b.CustomerPackagingDiscountOverride', N'U') IS NOT NULL
BEGIN
  /* Na isti kljuc (stranka, izdelek) je 216 dovolila vec vrstic z razlicnim zacetkom; aktivna
     ostane zadnja, ostale gredo kot neaktivne (zgodovina). */
  ;WITH legacy AS
  (
    SELECT old.OverrideId, customer.OrganizationId, old.CustomerId, old.PimProductId, old.DiscountCode,
      old.ValidFrom, old.ValidTo, old.IsActive,
      ActiveRank = ROW_NUMBER() OVER (PARTITION BY old.CustomerId, old.PimProductId, old.IsActive
        ORDER BY old.ValidFrom DESC, old.OverrideId DESC)
    FROM b2b.CustomerPackagingDiscountOverride AS old
    INNER JOIN b2b.Customer AS customer ON customer.CustomerId = old.CustomerId
  )
  INSERT b2b.PackagingDiscountRule
    (OrganizationId, TargetKind, CustomerId, ScopeKind, PimProductId, DiscountCode, ValidFrom, ValidTo, IsActive, Note, CreatedBy, UpdatedBy)
  SELECT legacy.OrganizationId, N'CUSTOMER', legacy.CustomerId, N'ITEM', legacy.PimProductId, legacy.DiscountCode,
    legacy.ValidFrom, legacy.ValidTo,
    CASE WHEN legacy.IsActive = 1 AND legacy.ActiveRank = 1 THEN 1 ELSE 0 END,
    N'Preneseno iz 216 (OverrideId ' + CONVERT(nvarchar(30), legacy.OverrideId) + N')', N'274', N'274'
  FROM legacy;

  EXEC sp_rename N'b2b.CustomerPackagingDiscountOverride', N'CustomerPackagingDiscountOverride_pred274';
END;

/* --- 1c) pogled z imenom stare tabele: stranka x izdelek iz nove tabele (bralci 129/250 delujejo naprej) --- */

IF OBJECT_ID(N'b2b.CustomerPackagingDiscountOverride', N'U') IS NULL
EXEC(N'CREATE OR ALTER VIEW b2b.CustomerPackagingDiscountOverride
AS
SELECT OverrideId = rule274.RuleId, rule274.CustomerId, rule274.PimProductId, rule274.DiscountCode,
  rule274.ValidFrom, rule274.ValidTo, rule274.IsActive
FROM b2b.PackagingDiscountRule AS rule274
WHERE rule274.TargetKind = N''CUSTOMER'' AND rule274.ScopeKind = N''ITEM'';');

/* --- 2) ucinkoviti posebni S: za cilj (tip ali stranka) in izdelek zmaga najbolj specificno pravilo --- */

EXEC(N'CREATE OR ALTER FUNCTION b2b.PackagingDiscountSpecials (@OrganizationId int, @OnDate date)
RETURNS TABLE
AS
RETURN
(
  /* Stirje obsegi so stiri poti do izdelka; vsaka gre po svojem indeksu (izdelek po kljucu,
     S koda po privzetem S, rabatna skupina po canon.Product, vsi izdelki po podjetju). En sam
     spoj z OR bi za vsako pravilo prebral cel katalog. */
  SELECT ranked.RuleId, ranked.TargetKind, ranked.CustomerTypeCode, ranked.CustomerId,
    ranked.PimProductId, ranked.DiscountCode, ranked.ScopeKind
  FROM
  (
    SELECT matched.*,
      PickRank = ROW_NUMBER() OVER (
        PARTITION BY matched.TargetKind, matched.CustomerTypeCode, matched.CustomerId, matched.PimProductId
        ORDER BY matched.Specificity, matched.RuleId DESC)
    FROM
    (
      SELECT rule274.RuleId, rule274.TargetKind, rule274.CustomerTypeCode, rule274.CustomerId,
        rule274.PimProductId, rule274.DiscountCode, rule274.ScopeKind, Specificity = 1
      FROM b2b.PackagingDiscountRule AS rule274
      WHERE rule274.OrganizationId = @OrganizationId AND rule274.IsActive = 1 AND rule274.ScopeKind = N''ITEM''
        AND (rule274.ValidFrom IS NULL OR rule274.ValidFrom <= @OnDate)
        AND (rule274.ValidTo IS NULL OR rule274.ValidTo >= @OnDate)

      UNION ALL
      SELECT rule274.RuleId, rule274.TargetKind, rule274.CustomerTypeCode, rule274.CustomerId,
        base.PimProductId, rule274.DiscountCode, rule274.ScopeKind, Specificity = 2
      FROM b2b.PackagingDiscountRule AS rule274
      INNER JOIN pim.ProductPackagingDiscount AS base ON base.DiscountCode = rule274.FromDiscountCode
      INNER JOIN pim.Product AS product ON product.PimProductId = base.PimProductId AND product.OrganizationId = rule274.OrganizationId
      WHERE rule274.OrganizationId = @OrganizationId AND rule274.IsActive = 1 AND rule274.ScopeKind = N''S_CODE''
        AND (rule274.ValidFrom IS NULL OR rule274.ValidFrom <= @OnDate)
        AND (rule274.ValidTo IS NULL OR rule274.ValidTo >= @OnDate)

      UNION ALL
      SELECT rule274.RuleId, rule274.TargetKind, rule274.CustomerTypeCode, rule274.CustomerId,
        product.PimProductId, rule274.DiscountCode, rule274.ScopeKind, Specificity = 3
      FROM b2b.PackagingDiscountRule AS rule274
      INNER JOIN canon.Product AS canonProduct
        ON canonProduct.OrganizationId = rule274.OrganizationId AND canonProduct.DiscountGroup = rule274.ItemGroupCode
      INNER JOIN pim.Product AS product
        ON product.OrganizationId = canonProduct.OrganizationId AND product.ItemID = canonProduct.ItemID
      WHERE rule274.OrganizationId = @OrganizationId AND rule274.IsActive = 1 AND rule274.ScopeKind = N''ITEM_GROUP''
        AND (rule274.ValidFrom IS NULL OR rule274.ValidFrom <= @OnDate)
        AND (rule274.ValidTo IS NULL OR rule274.ValidTo >= @OnDate)

      UNION ALL
      SELECT rule274.RuleId, rule274.TargetKind, rule274.CustomerTypeCode, rule274.CustomerId,
        product.PimProductId, rule274.DiscountCode, rule274.ScopeKind, Specificity = 4
      FROM b2b.PackagingDiscountRule AS rule274
      INNER JOIN pim.Product AS product ON product.OrganizationId = rule274.OrganizationId
      WHERE rule274.OrganizationId = @OrganizationId AND rule274.IsActive = 1 AND rule274.ScopeKind = N''ALL''
        AND (rule274.ValidFrom IS NULL OR rule274.ValidFrom <= @OnDate)
        AND (rule274.ValidTo IS NULL OR rule274.ValidTo >= @OnDate)
    ) AS matched
  ) AS ranked
  WHERE ranked.PickRank = 1
);');

/* --- 3) vpis pravila posebnega S (en veljaven zapis na cilj in obseg; stari se umakne) --- */

EXEC(N'CREATE OR ALTER PROCEDURE b2b.SavePackagingDiscountRule
  @OrganizationId int,
  @TargetKind nvarchar(10),
  @CustomerTypeCode nvarchar(60) = NULL,
  @CustomerId bigint = NULL,
  @CustomerKey nvarchar(100) = NULL,
  @ScopeKind nvarchar(12),
  @ItemID nvarchar(100) = NULL,
  @ItemGroupCode nvarchar(100) = NULL,
  @FromDiscountCode nvarchar(10) = NULL,
  @DiscountCode nvarchar(10),
  @ValidFrom date = NULL,
  @ValidTo date = NULL,
  @Note nvarchar(400) = NULL,
  @ChangedBy nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  SET @TargetKind = UPPER(LTRIM(RTRIM(@TargetKind)));
  SET @ScopeKind = UPPER(LTRIM(RTRIM(@ScopeKind)));
  SET @CustomerTypeCode = NULLIF(LTRIM(RTRIM(@CustomerTypeCode)), N'''');
  SET @CustomerKey = NULLIF(LTRIM(RTRIM(@CustomerKey)), N'''');
  SET @ItemID = NULLIF(LTRIM(RTRIM(@ItemID)), N'''');
  SET @ItemGroupCode = NULLIF(LTRIM(RTRIM(@ItemGroupCode)), N'''');
  SET @FromDiscountCode = NULLIF(UPPER(LTRIM(RTRIM(@FromDiscountCode))), N'''');
  SET @DiscountCode = NULLIF(UPPER(LTRIM(RTRIM(@DiscountCode))), N'''');

  IF @TargetKind NOT IN (N''TYPE'', N''CUSTOMER'') THROW 52740, N''Cilj pravila mora biti TYPE (tip stranke) ali CUSTOMER (stranka).'', 1;
  IF @ScopeKind NOT IN (N''ITEM'', N''ITEM_GROUP'', N''S_CODE'', N''ALL'') THROW 52741, N''Obseg pravila mora biti ITEM, ITEM_GROUP, S_CODE ali ALL.'', 1;

  IF @TargetKind = N''TYPE''
  BEGIN
    SET @CustomerId = NULL;
    SET @CustomerTypeCode = (SELECT CustomerTypeCode FROM pim.CustomerTypeCatalog WHERE CustomerTypeCode = @CustomerTypeCode OR Name = @CustomerTypeCode);
    IF @CustomerTypeCode IS NULL THROW 52742, N''Tipa stranke ni v sifrantu.'', 1;
  END
  ELSE
  BEGIN
    SET @CustomerTypeCode = NULL;
    IF @CustomerId IS NULL AND @CustomerKey IS NOT NULL
      SET @CustomerId = (SELECT CustomerId FROM b2b.Customer WHERE OrganizationId = @OrganizationId AND CustomerKey = @CustomerKey);
    IF @CustomerId IS NULL OR NOT EXISTS (SELECT 1 FROM b2b.Customer WHERE CustomerId = @CustomerId AND OrganizationId = @OrganizationId)
      THROW 52743, N''Stranke ni v tem podjetju.'', 1;
  END;

  DECLARE @PimProductId bigint = NULL;
  IF @ScopeKind = N''ITEM''
  BEGIN
    IF @ItemID IS NULL THROW 52744, N''Vpisi sifro artikla.'', 1;
    SET @PimProductId = (SELECT PimProductId FROM pim.Product WHERE OrganizationId = @OrganizationId AND ItemID = @ItemID);
    IF @PimProductId IS NULL THROW 52745, N''Artikla ni med objavljenimi izdelki tega podjetja; posebni S se dodeli samo promoviranemu izdelku.'', 1;
    SELECT @ItemGroupCode = NULL, @FromDiscountCode = NULL;
  END
  ELSE IF @ScopeKind = N''ITEM_GROUP''
  BEGIN
    IF @ItemGroupCode IS NULL THROW 52746, N''Vpisi rabatno skupino artiklov.'', 1;
    /* Koda se zapise tako, kot jo nosi izdelek (velike/male crke), sicer pravilo ne zadene nicesar. */
    SET @ItemGroupCode = COALESCE((SELECT TOP (1) DiscountGroup FROM canon.Product
      WHERE OrganizationId = @OrganizationId AND DiscountGroup = @ItemGroupCode), @ItemGroupCode);
    SET @FromDiscountCode = NULL;
  END
  ELSE IF @ScopeKind = N''S_CODE''
  BEGIN
    IF @FromDiscountCode IS NULL OR NOT EXISTS (SELECT 1 FROM pim.PackagingDiscountCatalog WHERE DiscountCode = @FromDiscountCode)
      THROW 52747, N''Za obseg S_CODE vpisi obstojeco S kodo, ki jo izdelki nosijo.'', 1;
    SET @ItemGroupCode = NULL;
  END
  ELSE
    SELECT @ItemGroupCode = NULL, @FromDiscountCode = NULL;

  IF @DiscountCode IS NULL OR NOT EXISTS (SELECT 1 FROM pim.PackagingDiscountCatalog WHERE DiscountCode = @DiscountCode AND IsActive = 1)
    THROW 52748, N''Neznana ali neaktivna S koda.'', 1;
  IF @ValidFrom IS NOT NULL AND @ValidTo IS NOT NULL AND @ValidTo < @ValidFrom
    THROW 52749, N''Konec veljavnosti je pred zacetkom.'', 1;

  BEGIN TRANSACTION;

  DECLARE @Id bigint, @Old nvarchar(max);
  SELECT @Id = RuleId,
    @Old = (SELECT * FROM b2b.PackagingDiscountRule AS oldRule WHERE oldRule.RuleId = active.RuleId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
  FROM b2b.PackagingDiscountRule AS active WITH (UPDLOCK, HOLDLOCK)
  WHERE active.OrganizationId = @OrganizationId AND active.TargetKind = @TargetKind AND active.ScopeKind = @ScopeKind AND active.IsActive = 1
    AND EXISTS (SELECT active.CustomerTypeCode, active.CustomerId, active.PimProductId, active.ItemGroupCode, active.FromDiscountCode
                INTERSECT SELECT @CustomerTypeCode, @CustomerId, @PimProductId, @ItemGroupCode, @FromDiscountCode);

  IF @Id IS NULL
  BEGIN
    INSERT b2b.PackagingDiscountRule
      (OrganizationId, TargetKind, CustomerTypeCode, CustomerId, ScopeKind, PimProductId, ItemGroupCode, FromDiscountCode,
       DiscountCode, ValidFrom, ValidTo, IsActive, Note, CreatedBy, UpdatedBy)
    VALUES
      (@OrganizationId, @TargetKind, @CustomerTypeCode, @CustomerId, @ScopeKind, @PimProductId, @ItemGroupCode, @FromDiscountCode,
       @DiscountCode, @ValidFrom, @ValidTo, 1, @Note, @ChangedBy, @ChangedBy);
    SET @Id = SCOPE_IDENTITY();
  END
  ELSE
    UPDATE b2b.PackagingDiscountRule
    SET DiscountCode = @DiscountCode, ValidFrom = @ValidFrom, ValidTo = @ValidTo,
      Note = COALESCE(@Note, Note), UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = @ChangedBy
    WHERE RuleId = @Id;

  INSERT b2b.AuditLog (OrganizationId, EntityType, EntityKey, ActionCode, OldValueJson, NewValueJson, ChangedBy)
  SELECT @OrganizationId, N''PackagingDiscountRule'', CONVERT(nvarchar(30), @Id),
    CASE WHEN @Old IS NULL THEN N''INSERT'' ELSE N''UPSERT'' END, @Old,
    (SELECT * FROM b2b.PackagingDiscountRule WHERE RuleId = @Id FOR JSON PATH, WITHOUT_ARRAY_WRAPPER), @ChangedBy;

  COMMIT;
  SELECT RuleId = @Id;
END;');

/* --- 3b) umik pravila (zapis ostane kot zgodovina, IsActive = 0) --- */

EXEC(N'CREATE OR ALTER PROCEDURE b2b.RemovePackagingDiscountRule
  @OrganizationId int,
  @RuleId bigint,
  @ChangedBy nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  DECLARE @Old nvarchar(max) = (SELECT * FROM b2b.PackagingDiscountRule
    WHERE RuleId = @RuleId AND OrganizationId = @OrganizationId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
  IF @Old IS NULL THROW 52750, N''Pravilo ne obstaja ali ne pripada temu podjetju.'', 1;

  BEGIN TRANSACTION;
  UPDATE b2b.PackagingDiscountRule
  SET IsActive = 0, UpdatedUtc = SYSUTCDATETIME(), UpdatedBy = @ChangedBy
  WHERE RuleId = @RuleId AND OrganizationId = @OrganizationId AND IsActive = 1;
  INSERT b2b.AuditLog (OrganizationId, EntityType, EntityKey, ActionCode, OldValueJson, NewValueJson, ChangedBy)
  SELECT @OrganizationId, N''PackagingDiscountRule'', CONVERT(nvarchar(30), @RuleId), N''DEACTIVATE'', @Old,
    (SELECT * FROM b2b.PackagingDiscountRule WHERE RuleId = @RuleId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER), @ChangedBy;
  COMMIT;
END;');

/* --- 3c) 216-ka vpis stranka x izdelek pise odslej v novo tabelo (isti podpis za kartico in delovni list strank) --- */

EXEC(N'CREATE OR ALTER PROCEDURE b2b.SaveCustomerPackagingDiscountOverride
  @OrganizationId int,
  @CustomerId bigint,
  @ItemID nvarchar(50),
  @DiscountCode nvarchar(10),
  @ValidFrom date = NULL,
  @ValidTo date = NULL,
  @ChangedBy nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON;
  EXEC b2b.SavePackagingDiscountRule
    @OrganizationId = @OrganizationId, @TargetKind = N''CUSTOMER'', @CustomerId = @CustomerId,
    @ScopeKind = N''ITEM'', @ItemID = @ItemID, @DiscountCode = @DiscountCode,
    @ValidFrom = @ValidFrom, @ValidTo = @ValidTo, @ChangedBy = @ChangedBy;
END;');

/* --- 3d) 216-ki umik stranka x izdelek (OverrideId je odslej RuleId, glej pogled) --- */

EXEC(N'CREATE OR ALTER PROCEDURE b2b.RemoveCustomerPackagingDiscountOverride
  @OrganizationId int,
  @CustomerId bigint,
  @OverrideId bigint,
  @ChangedBy nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON;
  IF NOT EXISTS (SELECT 1 FROM b2b.PackagingDiscountRule WHERE RuleId = @OverrideId AND CustomerId = @CustomerId AND OrganizationId = @OrganizationId)
    THROW 52424, N''Posebni popust ne obstaja ali ne pripada tej stranki.'', 1;
  EXEC b2b.RemovePackagingDiscountRule @OrganizationId = @OrganizationId, @RuleId = @OverrideId, @ChangedBy = @ChangedBy;
END;');

/* --- 3e) privzeti S za vec izdelkov naenkrat (delovni list, cenik); zgodovina v pim.ProductFieldHistory --- */

EXEC(N'CREATE OR ALTER PROCEDURE pim.SaveProductPackagingDiscountsBulk
  @OrganizationId int,
  @ItemsJson nvarchar(max),
  @Actor nvarchar(200),
  @Note nvarchar(400) = NULL,
  @ChangeSource nvarchar(40) = N''EXCEL''
AS
BEGIN
  /* @ItemsJson: [{"i":"BA.BC15.00300","s":"S2"}, {"i":"...","s":""}] - prazen "s" pomeni »brez S«.
     Vrne dva nabora: 1) ChangedCount, 2) preskocene vrstice (ItemID, Reason). */
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  /* Zacasne tabele z DATABASE_DEFAULT: tempdb ima lahko drugo kolacijo kot baza (Msg 468/4191). */
  CREATE TABLE #Wanted (ItemID nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY, DiscountCode nvarchar(10) COLLATE DATABASE_DEFAULT NULL);
  INSERT #Wanted (ItemID, DiscountCode)
  SELECT parsed.ItemID, MAX(NULLIF(UPPER(LTRIM(RTRIM(parsed.DiscountCode))), N''''))
  FROM OPENJSON(@ItemsJson) WITH (ItemID nvarchar(100) N''$.i'', DiscountCode nvarchar(10) N''$.s'') AS parsed
  WHERE NULLIF(LTRIM(RTRIM(parsed.ItemID)), N'''') IS NOT NULL
  GROUP BY parsed.ItemID;

  CREATE TABLE #Skipped (ItemID nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL, Reason nvarchar(400) COLLATE DATABASE_DEFAULT NOT NULL);

  INSERT #Skipped (ItemID, Reason)
  SELECT wanted.ItemID, N''Neznana ali neaktivna S koda '' + wanted.DiscountCode + N''.''
  FROM #Wanted AS wanted
  WHERE wanted.DiscountCode IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM pim.PackagingDiscountCatalog AS catalog WHERE catalog.DiscountCode = wanted.DiscountCode AND catalog.IsActive = 1);

  INSERT #Skipped (ItemID, Reason)
  SELECT wanted.ItemID,
    CASE WHEN canonProduct.ProductId IS NULL THEN N''Artikla ni v tem podjetju.''
         ELSE N''Izdelek se ni promoviran; S koda se dodeli sele objavljenemu izdelku.'' END
  FROM #Wanted AS wanted
  LEFT JOIN canon.Product AS canonProduct ON canonProduct.OrganizationId = @OrganizationId AND canonProduct.ItemID = wanted.ItemID
  LEFT JOIN pim.Product AS product ON product.OrganizationId = @OrganizationId AND product.ItemID = wanted.ItemID
  WHERE product.PimProductId IS NULL
    AND NOT EXISTS (SELECT 1 FROM #Skipped AS skipped WHERE skipped.ItemID = wanted.ItemID);

  CREATE TABLE #Change (PimProductId bigint NOT NULL PRIMARY KEY, ProductId bigint NULL, ItemID nvarchar(100) COLLATE DATABASE_DEFAULT NOT NULL,
    OldCode nvarchar(10) COLLATE DATABASE_DEFAULT NULL, NewCode nvarchar(10) COLLATE DATABASE_DEFAULT NULL);
  INSERT #Change (PimProductId, ProductId, ItemID, OldCode, NewCode)
  SELECT product.PimProductId, canonProduct.ProductId, product.ItemID, current274.DiscountCode, wanted.DiscountCode
  FROM #Wanted AS wanted
  INNER JOIN pim.Product AS product ON product.OrganizationId = @OrganizationId AND product.ItemID = wanted.ItemID
  LEFT JOIN canon.Product AS canonProduct ON canonProduct.OrganizationId = product.OrganizationId AND canonProduct.ItemID = product.ItemID
  LEFT JOIN pim.ProductPackagingDiscount AS current274 ON current274.PimProductId = product.PimProductId
  WHERE NOT EXISTS (SELECT 1 FROM #Skipped AS skipped WHERE skipped.ItemID = wanted.ItemID)
    AND ISNULL(current274.DiscountCode, N'''') <> ISNULL(wanted.DiscountCode, N'''');

  BEGIN TRANSACTION;

  DELETE target274
  FROM pim.ProductPackagingDiscount AS target274
  INNER JOIN #Change AS change274 ON change274.PimProductId = target274.PimProductId
  WHERE change274.NewCode IS NULL;

  UPDATE target274
  SET DiscountCode = change274.NewCode, UpdatedUtc = SYSUTCDATETIME()
  FROM pim.ProductPackagingDiscount AS target274
  INNER JOIN #Change AS change274 ON change274.PimProductId = target274.PimProductId
  WHERE change274.NewCode IS NOT NULL;

  INSERT pim.ProductPackagingDiscount (PimProductId, DiscountCode)
  SELECT change274.PimProductId, change274.NewCode
  FROM #Change AS change274
  WHERE change274.NewCode IS NOT NULL AND change274.OldCode IS NULL;

  IF EXISTS (SELECT 1 FROM #Change)
  BEGIN
    INSERT pim.ProductChangeBatch (BatchId, ChangeSource, ChangedBy, OrganizationId, Note)
    VALUES (NEWID(), @ChangeSource, @Actor, @OrganizationId, @Note);
    DECLARE @BatchId bigint = SCOPE_IDENTITY();

    INSERT pim.ProductFieldHistory (ChangeBatchId, OrganizationId, ProductId, ItemID, FieldKey, CanonTable, CanonColumn, Owner, OldValue, NewValue)
    SELECT @BatchId, @OrganizationId, change274.ProductId, change274.ItemID,
      N''Product.PackagingDiscountCode'', N''pim.ProductPackagingDiscount'', N''DiscountCode'', N''PIM'',
      change274.OldCode, change274.NewCode
    FROM #Change AS change274;
  END;

  COMMIT;

  SELECT ChangedCount = (SELECT COUNT(*) FROM #Change);
  SELECT ItemID, Reason FROM #Skipped ORDER BY ItemID;
END;');

/* --- 3f) sifrant S kod: odstotek obstojece kode ali nova koda (npr. S5) --- */

EXEC(N'CREATE OR ALTER PROCEDURE pim.SavePackagingDiscountPercent
  @OrganizationId int,
  @DiscountCode nvarchar(10),
  @PercentValue decimal(9, 4),
  @IsActive bit = 1,
  @ChangedBy nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  SET @DiscountCode = NULLIF(UPPER(LTRIM(RTRIM(@DiscountCode))), N'''');
  IF @DiscountCode IS NULL THROW 52751, N''Vpisi S kodo.'', 1;
  IF @PercentValue IS NULL OR @PercentValue <= 0 OR @PercentValue > 100 THROW 52752, N''Odstotek mora biti vec kot 0 in najvec 100.'', 1;
  IF @IsActive = 0 AND (EXISTS (SELECT 1 FROM pim.ProductPackagingDiscount WHERE DiscountCode = @DiscountCode)
      OR EXISTS (SELECT 1 FROM b2b.PackagingDiscountRule WHERE IsActive = 1 AND (DiscountCode = @DiscountCode OR FromDiscountCode = @DiscountCode)))
    THROW 52753, N''S koda je v uporabi na izdelkih ali v pravilih; najprej jo zamenjaj tam.'', 1;

  DECLARE @Old nvarchar(max) = (SELECT * FROM pim.PackagingDiscountCatalog WHERE DiscountCode = @DiscountCode FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

  BEGIN TRANSACTION;
  MERGE pim.PackagingDiscountCatalog AS target274
  USING (SELECT @DiscountCode AS DiscountCode) AS source274 ON target274.DiscountCode = source274.DiscountCode
  WHEN MATCHED THEN UPDATE SET PercentValue = @PercentValue, IsActive = @IsActive, UpdatedUtc = SYSUTCDATETIME()
  WHEN NOT MATCHED THEN INSERT (DiscountCode, PercentValue, IsActive) VALUES (@DiscountCode, @PercentValue, @IsActive);

  INSERT b2b.AuditLog (OrganizationId, EntityType, EntityKey, ActionCode, OldValueJson, NewValueJson, ChangedBy)
  SELECT @OrganizationId, N''PackagingDiscountCatalog'', @DiscountCode,
    CASE WHEN @Old IS NULL THEN N''INSERT'' ELSE N''UPSERT'' END, @Old,
    (SELECT * FROM pim.PackagingDiscountCatalog WHERE DiscountCode = @DiscountCode FOR JSON PATH, WITHOUT_ARRAY_WRAPPER), @ChangedBy;
  COMMIT;
END;');

/* --- 4) kartica izdelka: privzeti S, sifrant in posebni S, ki za izdelek danes veljajo --- */

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetProductPackagingDiscount
  @ProductId bigint
AS
BEGIN
  SET NOCOUNT ON;

  DECLARE @OrganizationId int, @PimProductId bigint;
  SELECT @OrganizationId = product.OrganizationId, @PimProductId = promoted.PimProductId
  FROM canon.Product AS product
  LEFT JOIN pim.Product AS promoted ON promoted.OrganizationId = product.OrganizationId AND promoted.ItemID = product.ItemID
  WHERE product.ProductId = @ProductId;

  /* 1) Stanje izdelka. */
  SELECT
    IsPromoted = CONVERT(bit, CASE WHEN promoted.PimProductId IS NULL THEN 0 ELSE 1 END),
    DiscountCode = packaging.DiscountCode,
    PercentValue = catalog.PercentValue,
    Pak2 = commercial.Pak2,
    UpdatedUtc = packaging.UpdatedUtc,
    DiscountGroup = product.DiscountGroup,
    product.OrganizationId
  FROM canon.Product AS product
  LEFT JOIN pim.Product AS promoted
    ON promoted.OrganizationId = product.OrganizationId AND promoted.ItemID = product.ItemID
  LEFT JOIN pim.ProductPackagingDiscount AS packaging ON packaging.PimProductId = promoted.PimProductId
  LEFT JOIN pim.PackagingDiscountCatalog AS catalog ON catalog.DiscountCode = packaging.DiscountCode
  LEFT JOIN pim.ProductCommercial AS commercial ON commercial.PimProductId = promoted.PimProductId
  WHERE product.ProductId = @ProductId;

  /* 2) Sifrant kod. */
  SELECT DiscountCode, PercentValue
  FROM pim.PackagingDiscountCatalog
  WHERE IsActive = 1
  ORDER BY PercentValue, DiscountCode;

  /* 3) Posebni S, ki danes veljajo za ta izdelek - po tipu stranke in po stranki. */
  SELECT special.RuleId, special.TargetKind, special.ScopeKind,
    TargetCode = COALESCE(special.CustomerTypeCode, customer.CustomerKey),
    TargetName = COALESCE(typeValue.Name, customer.Name),
    special.DiscountCode, catalog.PercentValue,
    rule274.ItemGroupCode, rule274.FromDiscountCode, rule274.ValidFrom, rule274.ValidTo
  FROM b2b.PackagingDiscountSpecials(@OrganizationId, CONVERT(date, SYSUTCDATETIME())) AS special
  INNER JOIN b2b.PackagingDiscountRule AS rule274 ON rule274.RuleId = special.RuleId
  LEFT JOIN pim.CustomerTypeCatalog AS typeValue ON typeValue.CustomerTypeCode = special.CustomerTypeCode
  LEFT JOIN b2b.Customer AS customer ON customer.CustomerId = special.CustomerId
  LEFT JOIN pim.PackagingDiscountCatalog AS catalog ON catalog.DiscountCode = special.DiscountCode
  WHERE @PimProductId IS NOT NULL AND special.PimProductId = @PimProductId
  ORDER BY CASE special.TargetKind WHEN N''TYPE'' THEN 0 ELSE 1 END, TargetName;
END;');

/* --- 4b) delovni list izdelkov: privzeti S in posebni S na izdelku (tip stranke / stranka) za dane izdelke --- */

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetProductPackagingDiscountSheet
  @ProductIdsJson nvarchar(max)
AS
BEGIN
  /* Stolpca »Posebni S - tipi strank« in »Posebni S - stranke« nosita samo pravila na TEM izdelku
     (ScopeKind ITEM) - to so tista, ki jih celica lahko ureja. Pravila po rabatni skupini, S kodi
     ali za vse izdelke se urejajo na strani Pravila in v delovnem listu strank. */
  SET NOCOUNT ON;

  DECLARE @Products TABLE (ProductId bigint NOT NULL PRIMARY KEY);
  INSERT @Products (ProductId)
  SELECT DISTINCT CONVERT(bigint, parsed.value) FROM OPENJSON(@ProductIdsJson) AS parsed
  WHERE TRY_CONVERT(bigint, parsed.value) IS NOT NULL;

  SELECT
    ProductId = product.ProductId,
    DiscountCode = packaging.DiscountCode,
    Pak2 = commercial.Pak2,
    TypeSpecials =
    (
      SELECT STRING_AGG(CONVERT(nvarchar(max), rule274.CustomerTypeCode + N''\'' + rule274.DiscountCode), N'' | '')
        WITHIN GROUP (ORDER BY rule274.CustomerTypeCode)
      FROM b2b.PackagingDiscountRule AS rule274
      WHERE rule274.PimProductId = promoted.PimProductId AND rule274.TargetKind = N''TYPE''
        AND rule274.ScopeKind = N''ITEM'' AND rule274.IsActive = 1
    ),
    CustomerSpecials =
    (
      SELECT STRING_AGG(CONVERT(nvarchar(max), customer.CustomerKey + N''\'' + rule274.DiscountCode), N'' | '')
        WITHIN GROUP (ORDER BY customer.CustomerKey)
      FROM b2b.PackagingDiscountRule AS rule274
      INNER JOIN b2b.Customer AS customer ON customer.CustomerId = rule274.CustomerId
      WHERE rule274.PimProductId = promoted.PimProductId AND rule274.TargetKind = N''CUSTOMER''
        AND rule274.ScopeKind = N''ITEM'' AND rule274.IsActive = 1
    )
  FROM @Products AS wanted
  INNER JOIN canon.Product AS product ON product.ProductId = wanted.ProductId
  INNER JOIN pim.Product AS promoted ON promoted.OrganizationId = product.OrganizationId AND promoted.ItemID = product.ItemID
  LEFT JOIN pim.ProductPackagingDiscount AS packaging ON packaging.PimProductId = promoted.PimProductId
  LEFT JOIN pim.ProductCommercial AS commercial ON commercial.PimProductId = promoted.PimProductId;
END;');

/* --- 4c) stran Pravila: vsa pravila posebnega S podjetja s stevilom izdelkov, ki jih danes zadenejo --- */

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetPackagingDiscountRules
  @OrganizationId int,
  @IncludeInactive bit = 0
AS
BEGIN
  SET NOCOUNT ON;

  CREATE TABLE #Hits (RuleId bigint NOT NULL PRIMARY KEY, ProductCount int NOT NULL);
  INSERT #Hits (RuleId, ProductCount)
  SELECT special.RuleId, COUNT(*)
  FROM b2b.PackagingDiscountSpecials(@OrganizationId, CONVERT(date, SYSUTCDATETIME())) AS special
  GROUP BY special.RuleId;

  SELECT rule274.RuleId, rule274.TargetKind, rule274.ScopeKind,
    TargetCode = COALESCE(rule274.CustomerTypeCode, customer.CustomerKey),
    TargetName = COALESCE(typeValue.Name, customer.Name),
    MagentoGroupKey = magentoGroup.MagentoGroupKey,
    ItemID = product.ItemID,
    rule274.ItemGroupCode, rule274.FromDiscountCode, rule274.DiscountCode, catalog.PercentValue,
    rule274.ValidFrom, rule274.ValidTo, rule274.IsActive, rule274.Note,
    rule274.UpdatedUtc, rule274.UpdatedBy,
    ProductCount = ISNULL(hits.ProductCount, 0),
    CustomerCount = CASE WHEN rule274.TargetKind = N''CUSTOMER'' THEN 1 ELSE
      (SELECT COUNT(*) FROM pim.CustomerWebProfile AS profile
       INNER JOIN b2b.Customer AS member ON member.CustomerId = profile.CustomerId
       WHERE profile.CustomerTypeCode = rule274.CustomerTypeCode AND member.OrganizationId = rule274.OrganizationId) END
  FROM b2b.PackagingDiscountRule AS rule274
  LEFT JOIN pim.CustomerTypeCatalog AS typeValue ON typeValue.CustomerTypeCode = rule274.CustomerTypeCode
  LEFT JOIN pim.CustomerTypeMagentoGroup AS magentoGroup ON magentoGroup.CustomerTypeCode = rule274.CustomerTypeCode AND magentoGroup.IsActive = 1
  LEFT JOIN b2b.Customer AS customer ON customer.CustomerId = rule274.CustomerId
  LEFT JOIN pim.Product AS product ON product.PimProductId = rule274.PimProductId
  LEFT JOIN pim.PackagingDiscountCatalog AS catalog ON catalog.DiscountCode = rule274.DiscountCode
  LEFT JOIN #Hits AS hits ON hits.RuleId = rule274.RuleId
  WHERE rule274.OrganizationId = @OrganizationId AND (@IncludeInactive = 1 OR rule274.IsActive = 1)
  ORDER BY rule274.IsActive DESC, CASE rule274.TargetKind WHEN N''TYPE'' THEN 0 ELSE 1 END,
    COALESCE(typeValue.Name, customer.Name),
    CASE rule274.ScopeKind WHEN N''ALL'' THEN 0 WHEN N''S_CODE'' THEN 1 WHEN N''ITEM_GROUP'' THEN 2 ELSE 3 END,
    rule274.ItemGroupCode, product.ItemID;

  DROP TABLE #Hits;
END;');

/* --- 4d) kartica stranke: pravila, ki veljajo zanjo, in katerim izdelkom ima kateri S (stranka pred tipom) --- */

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetCustomerPackagingDiscounts
  @OrganizationId int,
  @CustomerId bigint,
  @Take int = 500
AS
BEGIN
  SET NOCOUNT ON;
  SET @Take = CASE WHEN @Take < 1 THEN 500 WHEN @Take > 20000 THEN 20000 ELSE @Take END;

  DECLARE @TypeCode nvarchar(60) = (SELECT profile.CustomerTypeCode FROM pim.CustomerWebProfile AS profile
    INNER JOIN b2b.Customer AS customer ON customer.CustomerId = profile.CustomerId
    WHERE profile.CustomerId = @CustomerId AND customer.OrganizationId = @OrganizationId);

  CREATE TABLE #Effective (PimProductId bigint NOT NULL PRIMARY KEY, RuleId bigint NOT NULL, Source nvarchar(10) COLLATE DATABASE_DEFAULT NOT NULL,
    ScopeKind nvarchar(12) COLLATE DATABASE_DEFAULT NOT NULL, DiscountCode nvarchar(10) COLLATE DATABASE_DEFAULT NOT NULL);

  /* Stranka ima prednost pred svojim tipom; znotraj vsakega zmaga najbolj specificno pravilo (funkcija). */
  INSERT #Effective (PimProductId, RuleId, Source, ScopeKind, DiscountCode)
  SELECT picked.PimProductId, picked.RuleId, picked.TargetKind, picked.ScopeKind, picked.DiscountCode
  FROM
  (
    SELECT special.*, PickRank = ROW_NUMBER() OVER (PARTITION BY special.PimProductId
      ORDER BY CASE special.TargetKind WHEN N''CUSTOMER'' THEN 0 ELSE 1 END)
    FROM b2b.PackagingDiscountSpecials(@OrganizationId, CONVERT(date, SYSUTCDATETIME())) AS special
    WHERE (special.TargetKind = N''CUSTOMER'' AND special.CustomerId = @CustomerId)
       OR (special.TargetKind = N''TYPE'' AND special.CustomerTypeCode = @TypeCode)
  ) AS picked
  WHERE picked.PickRank = 1;

  /* 1) Povzetek. */
  SELECT CustomerTypeCode = @TypeCode, TypeName = typeValue.Name,
    PackagingDiscountEnabled = CONVERT(bit, ISNULL(profile.PackagingDiscountEnabled, 0)),
    SpecialProductCount = (SELECT COUNT(*) FROM #Effective),
    DefaultProductCount = (SELECT COUNT(*) FROM pim.ProductPackagingDiscount AS base
      INNER JOIN pim.Product AS product ON product.PimProductId = base.PimProductId WHERE product.OrganizationId = @OrganizationId)
  FROM (SELECT 1 AS One) AS one
  LEFT JOIN pim.CustomerWebProfile AS profile ON profile.CustomerId = @CustomerId
  LEFT JOIN pim.CustomerTypeCatalog AS typeValue ON typeValue.CustomerTypeCode = @TypeCode;

  /* 2) Pravila, ki veljajo za stranko: njena in pravila njenega tipa. */
  SELECT rule274.RuleId, rule274.TargetKind, rule274.ScopeKind,
    TargetCode = COALESCE(rule274.CustomerTypeCode, customer.CustomerKey),
    TargetName = COALESCE(typeValue.Name, customer.Name),
    ItemID = product.ItemID, rule274.ItemGroupCode, rule274.FromDiscountCode,
    rule274.DiscountCode, catalog.PercentValue, rule274.ValidFrom, rule274.ValidTo,
    ProductCount = (SELECT COUNT(*) FROM #Effective AS effective WHERE effective.RuleId = rule274.RuleId)
  FROM b2b.PackagingDiscountRule AS rule274
  LEFT JOIN pim.CustomerTypeCatalog AS typeValue ON typeValue.CustomerTypeCode = rule274.CustomerTypeCode
  LEFT JOIN b2b.Customer AS customer ON customer.CustomerId = rule274.CustomerId
  LEFT JOIN pim.Product AS product ON product.PimProductId = rule274.PimProductId
  LEFT JOIN pim.PackagingDiscountCatalog AS catalog ON catalog.DiscountCode = rule274.DiscountCode
  WHERE rule274.OrganizationId = @OrganizationId AND rule274.IsActive = 1
    AND ((rule274.TargetKind = N''CUSTOMER'' AND rule274.CustomerId = @CustomerId)
      OR (rule274.TargetKind = N''TYPE'' AND rule274.CustomerTypeCode = @TypeCode))
  ORDER BY CASE rule274.TargetKind WHEN N''CUSTOMER'' THEN 0 ELSE 1 END,
    CASE rule274.ScopeKind WHEN N''ITEM'' THEN 0 WHEN N''S_CODE'' THEN 1 WHEN N''ITEM_GROUP'' THEN 2 ELSE 3 END,
    rule274.ItemGroupCode, product.ItemID;

  /* 3) Izdelki s posebnim S za to stranko (prvih @Take po sifri). */
  SELECT TOP (@Take) product.ItemID, Name = product.Name, commercial.Pak2,
    DefaultCode = base.DiscountCode, DefaultPercent = baseCatalog.PercentValue,
    effective.DiscountCode, EffectivePercent = catalog.PercentValue,
    effective.Source, effective.ScopeKind, effective.RuleId, canonProduct.DiscountGroup,
    canonProduct.ProductId
  FROM #Effective AS effective
  INNER JOIN pim.Product AS product ON product.PimProductId = effective.PimProductId
  LEFT JOIN canon.Product AS canonProduct ON canonProduct.OrganizationId = product.OrganizationId AND canonProduct.ItemID = product.ItemID
  LEFT JOIN pim.ProductCommercial AS commercial ON commercial.PimProductId = product.PimProductId
  LEFT JOIN pim.ProductPackagingDiscount AS base ON base.PimProductId = product.PimProductId
  LEFT JOIN pim.PackagingDiscountCatalog AS baseCatalog ON baseCatalog.DiscountCode = base.DiscountCode
  LEFT JOIN pim.PackagingDiscountCatalog AS catalog ON catalog.DiscountCode = effective.DiscountCode
  ORDER BY product.ItemID;

  DROP TABLE #Effective;
END;');

/* --- 5b) faseta rabatne skupine na seznamu izdelkov --- */

EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetProductListFilters
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

  /* FacetLabel je to, kar uporabnik bere; FacetValue je to, s cimer filtriramo. Partner je par
     (podjetje, sifra) - ista sifra je v drugem podjetju lahko druga firma (250). Brez izbranega
     podjetja je zato vrednost "podjetje:sifra", z izbranim ostane gola sifra kot doslej. */
  SELECT TOP (@Take) FacetKind = N''MANUFACTURER'',
    FacetValue = CASE WHEN @OrganizationId IS NULL THEN CONCAT(grouped.OrganizationId, N'':'', grouped.koda) ELSE grouped.koda END,
    FacetLabel = COALESCE(partner.PartnerName, grouped.koda), ProductCount = grouped.stevilo,
    FacetCode = grouped.koda,
    OrganizationName = CASE WHEN @OrganizationId IS NULL THEN organization.Name END
  FROM
  (
    SELECT koda = product.Manufacturer, product.OrganizationId, stevilo = COUNT_BIG(*)
    FROM canon.Product AS product
    WHERE @UnknownOrganization = 0 AND ((@OrganizationId IS NULL AND product.OrganizationId IN (SELECT aktivno.OrganizationId FROM dbo.OrganizationConfig aktivno WHERE aktivno.IsActive = 1) /* 264 */) OR product.OrganizationId = @OrganizationId)
      AND product.Manufacturer IS NOT NULL
    GROUP BY product.Manufacturer, product.OrganizationId
  ) AS grouped
  LEFT JOIN canon.PartnerName AS partner
    ON partner.OrganizationId = grouped.OrganizationId AND partner.PartnerCode = grouped.koda
  LEFT JOIN dbo.OrganizationConfig AS organization ON organization.OrganizationId = grouped.OrganizationId
  ORDER BY grouped.stevilo DESC, COALESCE(partner.PartnerName, grouped.koda), grouped.OrganizationId
  OPTION (RECOMPILE);

  SELECT TOP (@Take) FacetKind = N''SUPPLIER'',
    FacetValue = CASE WHEN @OrganizationId IS NULL THEN CONCAT(grouped.OrganizationId, N'':'', grouped.koda) ELSE grouped.koda END,
    FacetLabel = COALESCE(partner.PartnerName, grouped.koda), ProductCount = grouped.stevilo,
    FacetCode = grouped.koda,
    OrganizationName = CASE WHEN @OrganizationId IS NULL THEN organization.Name END
  FROM
  (
    SELECT koda = product.Supplier, product.OrganizationId, stevilo = COUNT_BIG(*)
    FROM canon.Product AS product
    WHERE @UnknownOrganization = 0 AND ((@OrganizationId IS NULL AND product.OrganizationId IN (SELECT aktivno.OrganizationId FROM dbo.OrganizationConfig aktivno WHERE aktivno.IsActive = 1) /* 264 */) OR product.OrganizationId = @OrganizationId)
      AND product.Supplier IS NOT NULL
    GROUP BY product.Supplier, product.OrganizationId
  ) AS grouped
  LEFT JOIN canon.PartnerName AS partner
    ON partner.OrganizationId = grouped.OrganizationId AND partner.PartnerCode = grouped.koda
  LEFT JOIN dbo.OrganizationConfig AS organization ON organization.OrganizationId = grouped.OrganizationId
  ORDER BY grouped.stevilo DESC, COALESCE(partner.PartnerName, grouped.koda), grouped.OrganizationId
  OPTION (RECOMPILE);

  SELECT TOP (@Take) FacetKind = N''ITEM_GROUP'', FacetValue = product.ItemGroup,
    FacetLabel = product.ItemGroup, ProductCount = COUNT_BIG(*),
    FacetCode = product.ItemGroup, OrganizationName = CONVERT(nvarchar(200), NULL)
  FROM canon.Product AS product
  WHERE @UnknownOrganization = 0 AND ((@OrganizationId IS NULL AND product.OrganizationId IN (SELECT aktivno.OrganizationId FROM dbo.OrganizationConfig aktivno WHERE aktivno.IsActive = 1) /* 264 */) OR product.OrganizationId = @OrganizationId)
    AND product.ItemGroup IS NOT NULL
  GROUP BY product.ItemGroup
  ORDER BY COUNT_BIG(*) DESC, product.ItemGroup
  OPTION (RECOMPILE);

  SELECT TOP (@Take) FacetKind = N''DEPARTMENT'', FacetValue = product.Department,
    FacetLabel = product.Department, ProductCount = COUNT_BIG(*),
    FacetCode = product.Department, OrganizationName = CONVERT(nvarchar(200), NULL)
  FROM canon.Product AS product
  WHERE @UnknownOrganization = 0 AND ((@OrganizationId IS NULL AND product.OrganizationId IN (SELECT aktivno.OrganizationId FROM dbo.OrganizationConfig aktivno WHERE aktivno.IsActive = 1) /* 264 */) OR product.OrganizationId = @OrganizationId)
    AND product.Department IS NOT NULL
  GROUP BY product.Department
  ORDER BY COUNT_BIG(*) DESC, product.Department
  OPTION (RECOMPILE);

  /* 274: rabatna skupina artikla (canon.Product.DiscountGroup) - filter za S-popuste in pravila po skupini. */
  SELECT TOP (@Take) FacetKind = N''DISCOUNT_GROUP'', FacetValue = product.DiscountGroup,
    FacetLabel = product.DiscountGroup, ProductCount = COUNT_BIG(*),
    FacetCode = product.DiscountGroup, OrganizationName = CONVERT(nvarchar(200), NULL)
  FROM canon.Product AS product
  WHERE @UnknownOrganization = 0 AND ((@OrganizationId IS NULL AND product.OrganizationId IN (SELECT aktivno.OrganizationId FROM dbo.OrganizationConfig aktivno WHERE aktivno.IsActive = 1) /* 264 */) OR product.OrganizationId = @OrganizationId)
    AND product.DiscountGroup IS NOT NULL
  GROUP BY product.DiscountGroup
  ORDER BY COUNT_BIG(*) DESC, product.DiscountGroup
  OPTION (RECOMPILE);
END;');


/* --- 5) intranet.GetProductList: filtri S-popustov ------------------------------------------ */

DECLARE @definition nvarchar(max), @old nvarchar(max), @new nvarchar(max), @at int, @end int, @headerEnd int;

SET @definition = OBJECT_DEFINITION(OBJECT_ID(N'intranet.GetProductList'));
IF @definition IS NULL THROW 52760, N'274: intranet.GetProductList ne obstaja.', 1;

IF @definition NOT LIKE N'%/* Discount274 */%'
BEGIN
  /* a) parametri */
  SET @old = N'@CategoryCode nvarchar(200) = NULL';
  IF (LEN(@definition) - LEN(REPLACE(@definition, @old, N''))) / LEN(@old) <> 1
    THROW 52761, N'274: intranet.GetProductList nima pricakovanega parametra @CategoryCode.', 1;
  SET @definition = REPLACE(@definition, @old, @old + N',' + NCHAR(10)
    + N'  @PackagingDiscount nvarchar(20) = NULL, /* Discount274: S1-S4 | NONE | ANY */' + NCHAR(10)
    + N'  @DiscountGroup nvarchar(100) = NULL,' + NCHAR(10)
    + N'  @SpecialFor nvarchar(120) = NULL /* TYPE:koda | CUSTOMER:sifra | ANY */');

  /* b) nabor izdelkov po filtrih S - pred glavnim poizvedovanjem */
  SET @old = N';WITH filtered AS';
  IF (LEN(@definition) - LEN(REPLACE(@definition, @old, N''))) / LEN(@old) <> 1
    THROW 52762, N'274: intranet.GetProductList nima pricakovanega ;WITH filtered AS.', 1;
  SET @new = N'/* Discount274: filtri S-popustov. Nabor so canon izdelki, ki ustrezajo vsem izbranim filtrom S. */
  SET @PackagingDiscount = NULLIF(UPPER(LTRIM(RTRIM(@PackagingDiscount))), N'''');
  SET @DiscountGroup = NULLIF(LTRIM(RTRIM(@DiscountGroup)), N'''');
  SET @SpecialFor = NULLIF(LTRIM(RTRIM(@SpecialFor)), N'''');
  DECLARE @DiscountFilter274 bit = CASE WHEN @PackagingDiscount IS NULL AND @DiscountGroup IS NULL AND @SpecialFor IS NULL THEN 0 ELSE 1 END;
  CREATE TABLE #DiscountProduct274 (ProductId bigint NOT NULL PRIMARY KEY);
  IF @DiscountFilter274 = 1
  BEGIN
    DECLARE @SpecialKind274 nvarchar(10) = CASE WHEN UPPER(@SpecialFor) = N''ANY'' THEN N''ANY''
      WHEN @SpecialFor LIKE N''TYPE:%'' THEN N''TYPE'' WHEN @SpecialFor LIKE N''CUSTOMER:%'' THEN N''CUSTOMER'' END;
    DECLARE @SpecialCode274 nvarchar(120) = CASE WHEN CHARINDEX(N'':'', @SpecialFor) > 0
      THEN LTRIM(RTRIM(SUBSTRING(@SpecialFor, CHARINDEX(N'':'', @SpecialFor) + 1, 120))) END;
    CREATE TABLE #SpecialHit274 (PimProductId bigint NOT NULL PRIMARY KEY);
    IF @SpecialFor IS NOT NULL
    BEGIN
      DECLARE @Org274 int;
      DECLARE org274 CURSOR LOCAL FAST_FORWARD FOR
        SELECT aktivno.OrganizationId FROM dbo.OrganizationConfig AS aktivno
        WHERE (@OrganizationId IS NULL AND aktivno.IsActive = 1) OR aktivno.OrganizationId = @OrganizationId;
      OPEN org274;
      FETCH NEXT FROM org274 INTO @Org274;
      WHILE @@FETCH_STATUS = 0
      BEGIN
        INSERT #SpecialHit274 (PimProductId)
        SELECT DISTINCT special.PimProductId
        FROM b2b.PackagingDiscountSpecials(@Org274, CONVERT(date, SYSUTCDATETIME())) AS special
        LEFT JOIN b2b.Customer AS customer ON customer.CustomerId = special.CustomerId
        WHERE @SpecialKind274 = N''ANY''
          OR (@SpecialKind274 = N''TYPE'' AND special.TargetKind = N''TYPE'' AND special.CustomerTypeCode = @SpecialCode274)
          OR (@SpecialKind274 = N''CUSTOMER'' AND special.TargetKind = N''CUSTOMER'' AND customer.CustomerKey = @SpecialCode274)
          OR (@SpecialKind274 = N''CUSTOMER'' AND special.TargetKind = N''TYPE'' AND special.CustomerTypeCode IN
               (SELECT profile.CustomerTypeCode FROM pim.CustomerWebProfile AS profile
                INNER JOIN b2b.Customer AS member ON member.CustomerId = profile.CustomerId
                WHERE member.OrganizationId = @Org274 AND member.CustomerKey = @SpecialCode274));
        FETCH NEXT FROM org274 INTO @Org274;
      END;
      CLOSE org274;
      DEALLOCATE org274;
    END;

    INSERT #DiscountProduct274 (ProductId)
    SELECT product.ProductId
    FROM canon.Product AS product
    LEFT JOIN pim.Product AS promoted ON promoted.OrganizationId = product.OrganizationId AND promoted.ItemID = product.ItemID
    LEFT JOIN pim.ProductPackagingDiscount AS packaging ON packaging.PimProductId = promoted.PimProductId
    WHERE @UnknownOrganization = 0
      AND ((@OrganizationId IS NULL AND product.OrganizationId IN (SELECT aktivno.OrganizationId FROM dbo.OrganizationConfig aktivno WHERE aktivno.IsActive = 1)) OR product.OrganizationId = @OrganizationId)
      AND (@DiscountGroup IS NULL OR product.DiscountGroup = @DiscountGroup)
      AND (@PackagingDiscount IS NULL
        OR (@PackagingDiscount = N''NONE'' AND packaging.DiscountCode IS NULL)
        OR (@PackagingDiscount = N''ANY'' AND packaging.DiscountCode IS NOT NULL)
        OR packaging.DiscountCode = @PackagingDiscount)
      AND (@SpecialFor IS NULL OR EXISTS (SELECT 1 FROM #SpecialHit274 AS hit WHERE hit.PimProductId = promoted.PimProductId))
    OPTION (RECOMPILE);
    DROP TABLE #SpecialHit274;
  END;

  ' + @old;
  SET @definition = REPLACE(@definition, @old, @new);

  /* c) pogoj v obeh WHERE (seznam in stetje) */
  SET @old = N'AND (@CategoryCode IS NULL OR EXISTS';
  IF (LEN(@definition) - LEN(REPLACE(@definition, @old, N''))) / LEN(@old) <> 2
    THROW 52763, N'274: intranet.GetProductList nima dveh pogojev po kategoriji.', 1;
  SET @definition = REPLACE(@definition, @old,
    N'AND (@DiscountFilter274 = 0 OR EXISTS (SELECT 1 FROM #DiscountProduct274 AS discount274 WHERE discount274.ProductId = product.ProductId))' + NCHAR(10)
    + N'      ' + @old);

  /* d) pospravljanje */
  SET @old = N'DROP TABLE #CategoryProduct;';
  IF (LEN(@definition) - LEN(REPLACE(@definition, @old, N''))) / LEN(@old) <> 1
    THROW 52764, N'274: intranet.GetProductList nima DROP TABLE #CategoryProduct.', 1;
  SET @definition = REPLACE(@definition, @old, @old + NCHAR(10) + N'  DROP TABLE #DiscountProduct274;');

  SET @headerEnd = CHARINDEX(N'PROCEDURE', @definition);
  SET @definition = N'ALTER ' + SUBSTRING(@definition, @headerEnd, 2147483647);
  EXEC sys.sp_executesql @definition;
END;

/* --- 6) out.GetExportRows: ucinkoviti posebni S v katalog.csv ------------------------------ */

SET @definition = OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows'));
IF @definition IS NULL THROW 52770, N'274: out.GetExportRows ne obstaja.', 1;

IF @definition NOT LIKE N'%/* SpecialS274 */%'
BEGIN
  /* a) nabor posebnih S za izdelke strani, pred jedrom B1 */
  SET @old = N'/* --- B1) Osnovna polja';
  IF (LEN(@definition) - LEN(REPLACE(@definition, @old, N''))) / LEN(@old) <> 1
    THROW 52771, N'274: out.GetExportRows nima oznake B1.', 1;
  SET @new = N'/* SpecialS274: ucinkoviti posebni S izdelkov strani - po stranki (COL037) in po skupini strank (COL037B). */
    CREATE TABLE #SpecialAll274 (PimProductId bigint NOT NULL, TargetKind nvarchar(10) COLLATE DATABASE_DEFAULT NOT NULL,
      CustomerTypeCode nvarchar(60) COLLATE DATABASE_DEFAULT NULL, CustomerId bigint NULL, DiscountCode nvarchar(10) COLLATE DATABASE_DEFAULT NOT NULL);
    INSERT #SpecialAll274 (PimProductId, TargetKind, CustomerTypeCode, CustomerId, DiscountCode)
    SELECT special.PimProductId, special.TargetKind, special.CustomerTypeCode, special.CustomerId, special.DiscountCode
    FROM b2b.PackagingDiscountSpecials(@OrganizationId, CONVERT(date, SYSUTCDATETIME())) AS special
    WHERE EXISTS (SELECT 1 FROM #Page AS page274 WHERE page274.EntityId = special.PimProductId);

    CREATE TABLE #Special274 (PimProductId bigint NOT NULL PRIMARY KEY, CustomerSpecials nvarchar(max) COLLATE DATABASE_DEFAULT NULL, GroupSpecials nvarchar(max) COLLATE DATABASE_DEFAULT NULL);
    INSERT #Special274 (PimProductId, CustomerSpecials, GroupSpecials)
    SELECT page274.EntityId,
      (SELECT STRING_AGG(CONVERT(nvarchar(max), customer274.CustomerKey + N''\'' + special274.DiscountCode), N'' | '')
         WITHIN GROUP (ORDER BY customer274.CustomerKey)
       FROM #SpecialAll274 AS special274
       INNER JOIN b2b.Customer AS customer274 ON customer274.CustomerId = special274.CustomerId AND customer274.IsActive = 1
       WHERE special274.PimProductId = page274.EntityId AND special274.TargetKind = N''CUSTOMER''),
      (SELECT STRING_AGG(CONVERT(nvarchar(max), group274.MagentoGroupKey + N''\'' + special274.DiscountCode), N'' | '')
         WITHIN GROUP (ORDER BY group274.MagentoGroupKey)
       FROM #SpecialAll274 AS special274
       INNER JOIN pim.CustomerTypeMagentoGroup AS group274
         ON group274.CustomerTypeCode = special274.CustomerTypeCode AND group274.IsActive = 1 AND group274.MagentoGroupKey IS NOT NULL
       WHERE special274.PimProductId = page274.EntityId AND special274.TargetKind = N''TYPE'')
    FROM #Page AS page274
    WHERE EXISTS (SELECT 1 FROM #SpecialAll274 AS any274 WHERE any274.PimProductId = page274.EntityId);

    ' + @old;
  SET @definition = REPLACE(@definition, @old, @new);

  /* b) jedro: namesto podpoizvedbe 216 vrednosti iz #Special274 */
  SET @at = CHARINDEX(N'SpecialCustomerDiscounts = /* SpecialS216 */', @definition);
  SET @end = CHARINDEX(N'AS special216),', @definition, @at);
  IF @at = 0 OR @end = 0 THROW 52772, N'274: out.GetExportRows nima podpoizvedbe SpecialS216.', 1;
  SET @definition = STUFF(@definition, @at, @end + LEN(N'AS special216),') - @at,
    N'SpecialCustomerDiscounts = special274.CustomerSpecials,' + NCHAR(10)
    + N'        SpecialGroupDiscounts = special274.GroupSpecials,');

  SET @old = N'ON discountCatalog.DiscountCode = packaging.DiscountCode AND discountCatalog.IsActive = 1';
  IF (LEN(@definition) - LEN(REPLACE(@definition, @old, N''))) / LEN(@old) <> 1
    THROW 52773, N'274: out.GetExportRows nima pricakovanega spoja discountCatalog.', 1;
  SET @definition = REPLACE(@definition, @old,
    @old + NCHAR(10) + N'      LEFT JOIN #Special274 AS special274 ON special274.PimProductId = product.PimProductId');

  /* c) seznam polj */
  SET @old = N'(N''Product.SpecialCustomerDiscounts'', CONVERT(nvarchar(max), core.SpecialCustomerDiscounts)),';
  IF (LEN(@definition) - LEN(REPLACE(@definition, @old, N''))) / LEN(@old) <> 1
    THROW 52774, N'274: out.GetExportRows nima polja Product.SpecialCustomerDiscounts.', 1;
  SET @definition = REPLACE(@definition, @old,
    @old + NCHAR(10) + N'        (N''Product.SpecialGroupDiscounts'', CONVERT(nvarchar(max), core.SpecialGroupDiscounts)),');

  SET @headerEnd = CHARINDEX(N'PROCEDURE', @definition);
  SET @definition = N'ALTER ' + SUBSTRING(@definition, @headerEnd, 2147483647);
  EXEC sys.sp_executesql @definition;
END;

/* Register stolpcev katalog.csv: nov stolpec NA KONCU (za dodatki 234), kot 234 — prvih 176 stolpcev je
   predloga Magenta (MagentoCsvContract.ProductHeaders) in njihova mesta se ne premikajo. */
DECLARE @ProfileId274 int = (SELECT ExportProfileId FROM out.ExportProfile WHERE ProfileCode = N'MAGENTO_PRODUCTS');
IF @ProfileId274 IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM out.ExportColumn WHERE ExportProfileId = @ProfileId274 AND ColumnCode = N'COL037B')
BEGIN
  INSERT out.ExportColumn (ExportProfileId, ColumnCode, OutputColumnName, CanonicalFieldCode, SortOrder, IsRequired, IsActive)
  SELECT @ProfileId274, N'COL037B', N'Posebni S za skupino strank', N'Product.SpecialGroupDiscounts', MAX(SortOrder) + 1, 0, 1
  FROM out.ExportColumn WHERE ExportProfileId = @ProfileId274;
  UPDATE out.ExportProfile SET UpdatedUtc = SYSUTCDATETIME() WHERE ExportProfileId = @ProfileId274;
END;

/* --- 7) intranet.GetCustomerList: vsa pravila stranke v enem zapisu ------------------------- */

SET @definition = OBJECT_DEFINITION(OBJECT_ID(N'intranet.GetCustomerList'));
IF @definition IS NULL THROW 52780, N'274: intranet.GetCustomerList ne obstaja.', 1;

IF @definition NOT LIKE N'%/* SpecialRules274 */%'
BEGIN
  SET @at = CHARINDEX(N'SELECT STRING_AGG(CONVERT(nvarchar(max), product.ItemID + N''\'' + special.DiscountCode)', @definition);
  SET @old = N'WHERE special.CustomerId = base.CustomerId AND special.IsActive = 1';
  SET @end = CHARINDEX(@old, @definition, @at);
  IF @at = 0 OR @end = 0 THROW 52781, N'274: intranet.GetCustomerList nima pricakovanega bloka SpecialDiscounts.', 1;
  SET @definition = STUFF(@definition, @at, @end + LEN(@old) - @at,
    N'/* SpecialRules274: ARTIKEL\S2 | SKUPINA:koda\S3 | S:S2\S3 | *\S3 */' + NCHAR(10)
    + N'      SELECT STRING_AGG(CONVERT(nvarchar(max), CASE rule274.ScopeKind WHEN N''ITEM'' THEN product.ItemID' + NCHAR(10)
    + N'          WHEN N''ITEM_GROUP'' THEN N''SKUPINA:'' + rule274.ItemGroupCode WHEN N''S_CODE'' THEN N''S:'' + rule274.FromDiscountCode ELSE N''*'' END' + NCHAR(10)
    + N'          + N''\'' + rule274.DiscountCode), N'' | '')' + NCHAR(10)
    + N'        WITHIN GROUP (ORDER BY CASE rule274.ScopeKind WHEN N''ALL'' THEN 0 WHEN N''S_CODE'' THEN 1 WHEN N''ITEM_GROUP'' THEN 2 ELSE 3 END, rule274.FromDiscountCode, rule274.ItemGroupCode, product.ItemID)' + NCHAR(10)
    + N'      FROM b2b.PackagingDiscountRule AS rule274' + NCHAR(10)
    + N'      LEFT JOIN pim.Product AS product ON product.PimProductId = rule274.PimProductId' + NCHAR(10)
    + N'      WHERE rule274.TargetKind = N''CUSTOMER'' AND rule274.CustomerId = base.CustomerId AND rule274.IsActive = 1');

  SET @headerEnd = CHARINDEX(N'PROCEDURE', @definition);
  SET @definition = N'ALTER ' + SUBSTRING(@definition, @headerEnd, 2147483647);
  EXEC sys.sp_executesql @definition;
END;
