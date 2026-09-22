/*
  253 - Skupine popustov iz SAOP v stranke.csv, na strani Stranke in na kartici; samo veljavni.

  Uporabnik 2026-09-22: »dodaj, da izvoz tako na strani Stranke prebere skupine popustov kot tudi
  stranke.csv, ki bo sel na spletno stran, ampak samo aktivne popuste«.

  Dokument Magento_Pravila_Cene_Popusti_Postnine §2, §4.3 in §4.10: stolpec »Skupine popustov«
  (KODA=xx% | ...) je kataloski popust po skupini artiklov; vir je SAOP ComercialTerms; prazno =
  tranzit; poslovna enota (PE) popuste podeduje od placnika (»berejo se z zapisa placnika«).

  Stanje pred migracijo (lokalna baza, 2026-09-22):
    - SAOP rabati so v b2b.CustomerItemGroupDiscount (4.312 vrstic; zajem 087 iz
      CustomerItemGroupDiscountsComercialTermsV2). Na stranko se vezejo prek rabatnega cenika:
      b2b.Customer.DiscountPriceListCode = CustomerGroupCode (187 ujemanj v Vidadrii).
    - stranke.csv (out.GetExportRows, blok /* CatalogCustomer205 */) je kot ERP vir bral
      b2b.GroupDiscount, ki je prazna in je nic ne polni - stolpec »Skupine popustov« in »Popust NW«
      sta bila prazna pri vseh 3.988 strankah IQLighting.
    - Kartica (intranet.GetCustomerCard, nabor 2) je SAOP rabate iskala po Magento skupini
      stranke namesto po rabatnem ceniku - ni nasla nicesar.
    - PE/tranzit: pim.CustomerWebProfile.PayerKind (097) ni nihce izpolnil. Tipi strank pa ga
      nosijo (INSTALLER_BRANCH = »Instalater - PE«, RESELLER_TRANSIT = »Trgovec - tranzit« ...),
      tako kot v PIM_test. Merjeno: PE (34 strank) ima SAOP rabate na lastnem ceniku 1-krat, na
      placnikovem 27-krat; tranzit (86) na placnikovem 85-krat - zato tranzit NE deduje.

  Pravilo (b2b.CustomerGroupDiscounts, ena vrstica na stranko in skupino artiklov):
    1. rocni popust stranke (b2b.GroupDiscountOverride, CUSTOMER),
    2. rocni popust tipa stranke (TYPE),
    3. b2b.GroupDiscount (ERP, danes prazna - ostane zaradi 205),
    4. SAOP rabatni cenik: navadna stranka lasten; PE placnikov (brez placnika lasten); tranzit nic.
       PE/tranzit: PayerKind na profilu, sicer iz tipa (_BRANCH = PE, _TRANSIT = tranzit).
    Samo danes veljavni (od <= danes <= do; rocni se IsActive = 1). Med veljavnimi iste skupine
    zmaga nizja prioriteta, nato najnovejsi zacetek. Skupina, ki ji na koncu ostane 0 %, se ne
    izpise (SAOP 0 % pomeni »ni popusta«; rocni 0 % zavestno preglasi SAOP). SAOP vrstice s
    kolicinskim pogojem (MinQuantity > 0; ena, potekla) se ne izpisejo - zapis KODA=xx% ga ne zna.
    Rocni popusti veljajo tudi za tranzit: to je izrecna cloveska odlocitev.

  Kaj naredi:
    1. funkcija b2b.CustomerGroupDiscounts(@Today) - vse stranke naenkrat (klic po stranki je za 11.623
       strank trajal 4,5 s),
    2. out.GetExportRows: blok /* CatalogCustomer205 */ nadomesti /* SaopGroups253 */ s to funkcijo
       (stranke.csv: »Skupine popustov« in »Popust NW«) - zamenjava zive definicije kot 194-216,
    3. intranet.GetCustomerCard, nabor 2: ista funkcija; stolpec CustomerGroupCode nosi vir,
    4. intranet.GetCustomerList (250): ExportGroupDiscounts (natanko niz iz stranke.csv) in
       PayerKind namesto SaopGroupDiscounts.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

/* --- 1) Pravilo skupin popustov ---------------------------------------------------------------- */
EXEC(N'CREATE OR ALTER FUNCTION b2b.CustomerGroupDiscounts (@Today date)
RETURNS TABLE
AS
RETURN
(
  WITH customerValue AS
  (
    SELECT customer.CustomerId, customer.OrganizationId, customer.CustomerKey, profile.CustomerTypeCode,
      OwnList = COALESCE(generalOverride.DiscountPriceListCode, customer.DiscountPriceListCode),
      PayerCode = NULLIF(COALESCE(generalOverride.PayerCode, customer.PayerCode), customer.CustomerKey),
      PayerKind = COALESCE(profile.PayerKind, CASE
        WHEN profile.CustomerTypeCode LIKE N''%[_]BRANCH%'' THEN N''PE''
        WHEN profile.CustomerTypeCode LIKE N''%[_]TRANSIT%'' THEN N''TRANZIT'' END)
    FROM b2b.Customer AS customer
    LEFT JOIN pim.CustomerGeneralOverride AS generalOverride
      ON generalOverride.OrganizationId = customer.OrganizationId AND generalOverride.CustomerId = customer.CustomerId
    LEFT JOIN pim.CustomerWebProfile AS profile ON profile.CustomerId = customer.CustomerId
  ),
  listValue AS
  (
    SELECT customerValue.*,
      SaopList = CASE customerValue.PayerKind
        WHEN N''TRANZIT'' THEN NULL
        WHEN N''PE'' THEN COALESCE(payerValue.DiscountList, customerValue.OwnList)
        ELSE customerValue.OwnList END,
      FromPayer = CONVERT(bit, CASE WHEN customerValue.PayerKind = N''PE'' AND payerValue.DiscountList IS NOT NULL THEN 1 ELSE 0 END)
    FROM customerValue
    /* (OrganizationId, CustomerKey) je enolicen, zato je placnik najvec eden. */
    LEFT JOIN
    (
      SELECT payer.OrganizationId, payer.CustomerKey, DiscountList = COALESCE(payerOverride.DiscountPriceListCode, payer.DiscountPriceListCode)
      FROM b2b.Customer AS payer
      LEFT JOIN pim.CustomerGeneralOverride AS payerOverride
        ON payerOverride.OrganizationId = payer.OrganizationId AND payerOverride.CustomerId = payer.CustomerId
    ) AS payerValue ON payerValue.OrganizationId = customerValue.OrganizationId AND payerValue.CustomerKey = customerValue.PayerCode
  ),
  candidates AS
  (
    SELECT listValue.CustomerId, groupRule.ItemGroupCode, groupRule.PercentValue, groupRule.ValidFrom, groupRule.ValidTo,
      Priority = CASE groupRule.TargetKind WHEN N''CUSTOMER'' THEN 1 ELSE 2 END, RuleId = groupRule.OverrideId,
      SourceKind = groupRule.TargetKind, SourceCode = COALESCE(groupRule.CustomerTypeCode, listValue.CustomerKey)
    FROM listValue
    INNER JOIN b2b.GroupDiscountOverride AS groupRule
      ON groupRule.OrganizationId = listValue.OrganizationId AND groupRule.IsActive = 1
     AND ((groupRule.TargetKind = N''CUSTOMER'' AND groupRule.CustomerId = listValue.CustomerId)
       OR (groupRule.TargetKind = N''TYPE'' AND groupRule.CustomerTypeCode = listValue.CustomerTypeCode))
    WHERE (groupRule.ValidFrom IS NULL OR groupRule.ValidFrom <= @Today)
      AND (groupRule.ValidTo IS NULL OR groupRule.ValidTo >= @Today)
    UNION ALL
    SELECT listValue.CustomerId, legacy.ItemGroupCode, legacy.PercentValue, legacy.ValidFrom, legacy.ValidTo,
      3, legacy.GroupDiscountId, N''ERP'', listValue.CustomerKey
    FROM listValue
    INNER JOIN b2b.GroupDiscount AS legacy ON legacy.CustomerId = listValue.CustomerId
    WHERE (legacy.ValidFrom IS NULL OR legacy.ValidFrom <= @Today)
      AND (legacy.ValidTo IS NULL OR legacy.ValidTo >= @Today)
    UNION ALL
    SELECT listValue.CustomerId, saop.ItemGroupCode, saop.DiscountPercent, saop.ValidFrom, saop.ValidTo,
      4, saop.CustomerItemGroupDiscountId, CASE WHEN listValue.FromPayer = 1 THEN N''SAOP_PAYER'' ELSE N''SAOP'' END,
      CASE WHEN listValue.FromPayer = 1 THEN listValue.PayerCode ELSE listValue.SaopList END
    FROM listValue
    /* HASH: brez namiga je optimizator pri spoju po izracunanem ceniku izbral zanko z zacasnim
       zapisom - 340.000 branj in 14 s za vse stranke; z namigom 90 ms (izmerjeno 2026-09-22). */
    INNER HASH JOIN b2b.CustomerItemGroupDiscount AS saop
      ON saop.OrganizationId = listValue.OrganizationId AND saop.CustomerGroupCode = listValue.SaopList
    WHERE saop.ValidFrom <= @Today AND (saop.ValidTo IS NULL OR saop.ValidTo >= @Today)
      AND saop.DiscountPercent IS NOT NULL AND ISNULL(saop.MinQuantity, 0) = 0
  ),
  ranked AS
  (
    SELECT candidates.*,
      PickRank = ROW_NUMBER() OVER (PARTITION BY candidates.CustomerId, candidates.ItemGroupCode
        ORDER BY candidates.Priority, candidates.ValidFrom DESC, candidates.RuleId DESC)
    FROM candidates
  )
  SELECT ranked.CustomerId, ranked.ItemGroupCode, ranked.PercentValue, ranked.ValidFrom, ranked.ValidTo, ranked.SourceKind, ranked.SourceCode
  FROM ranked
  WHERE ranked.PickRank = 1 AND ranked.PercentValue > 0
);');

/* --- 2) stranke.csv: out.GetExportRows ----------------------------------------------------------- */
DECLARE @definition nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows'));
IF @definition IS NULL THROW 52531, N'253: out.GetExportRows ne obstaja.', 1;
IF @definition NOT LIKE N'%/* SaopGroups253 */%'
BEGIN
  DECLARE @start int = CHARINDEX(N'    /* CatalogCustomer205 */', @definition);
  DECLARE @finish int = CHARINDEX(N'INSERT #Value (RowKey, FieldCode, Value)' + NCHAR(10) + N'    SELECT RowKey, N''Customer.GroupDiscounts''', @definition, @start);
  IF @start = 0 OR @finish <= @start THROW 52532, N'253: out.GetExportRows nima pricakovanega bloka skupin popustov (205).', 1;
  SET @definition = STUFF(@definition, @start, @finish - @start, N'    /* SaopGroups253 */
    /* Skupine popustov stranke: b2b.CustomerGroupDiscounts - rocni popust stranke, rocni popust
       tipa, SAOP rabatni cenik po pravilu PE/tranzit; samo danes veljavni in nad 0 %. Isto
       pravilo bereta stran Stranke (intranet.GetCustomerList) in kartica stranke. */
    INSERT #GroupDiscount (RowKey, ItemGroupCode, PercentText)
    SELECT page.RowKey, effective.ItemGroupCode, out.MagentoNumber(effective.PercentValue)
    FROM #Page AS page
    INNER JOIN b2b.CustomerGroupDiscounts(CONVERT(date, SYSUTCDATETIME())) AS effective ON effective.CustomerId = page.EntityId;

    ');
  SET @definition = N'ALTER ' + SUBSTRING(@definition, CHARINDEX(N'PROCEDURE', @definition), 2147483647);
  EXEC sys.sp_executesql @definition;
END;

/* --- 3) Kartica stranke: nabor 2 ---------------------------------------------------------------- */
SET @definition = OBJECT_DEFINITION(OBJECT_ID(N'intranet.GetCustomerCard'));
IF @definition IS NULL THROW 52533, N'253: intranet.GetCustomerCard ne obstaja.', 1;
IF @definition NOT LIKE N'%/* SaopGroups253 */%'
BEGIN
  DECLARE @cardStart int = CHARINDEX(N'  /* 2 - skupine popustov po skupini artiklov.', @definition);
  DECLARE @cardEnd nvarchar(100) = N'  ORDER BY discount.ItemGroupCode;';
  DECLARE @cardFinish int = CHARINDEX(@cardEnd, @definition, @cardStart);
  IF @cardStart = 0 OR @cardFinish <= @cardStart THROW 52534, N'253: intranet.GetCustomerCard nima pricakovanega nabora 2.', 1;
  SET @definition = STUFF(@definition, @cardStart, @cardFinish + LEN(@cardEnd) - @cardStart, N'  /* 2 - skupine popustov: isto pravilo in isti popusti kot stranke.csv (b2b.CustomerGroupDiscounts,
         253). CustomerGroupCode nosi vir popusta, da uporabnik vidi, od kod je. */ /* SaopGroups253 */
  SELECT effective.ItemGroupCode, DiscountPercent = effective.PercentValue, MinQuantity = CONVERT(decimal(19,5), NULL),
    ValidFrom = CONVERT(date, effective.ValidFrom), ValidTo = CONVERT(date, effective.ValidTo),
    CustomerGroupCode = CASE effective.SourceKind
      WHEN N''CUSTOMER'' THEN N''ročno za stranko''
      WHEN N''TYPE'' THEN N''ročno za tip '' + effective.SourceCode
      WHEN N''ERP'' THEN N''ERP''
      WHEN N''SAOP_PAYER'' THEN N''SAOP, od plačnika '' + effective.SourceCode
      ELSE N''SAOP, rabatni cenik '' + effective.SourceCode END
  FROM b2b.CustomerGroupDiscounts(CONVERT(date, SYSUTCDATETIME())) AS effective
  WHERE effective.CustomerId = @CustomerId
  ORDER BY effective.ItemGroupCode;');
  SET @definition = N'ALTER ' + SUBSTRING(@definition, CHARINDEX(N'PROCEDURE', @definition), 2147483647);
  EXEC sys.sp_executesql @definition;
END;

/* --- 4) Seznam strank (250): skupine iz stranke.csv in PE/tranzit ------------------------------- */
EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetCustomerList
  @OrganizationId int = NULL
AS
BEGIN
  SET NOCOUNT ON;

  DECLARE @Today date = CONVERT(date, SYSUTCDATETIME());

  /* Vmesni rezultati v zacasnih tabelah s kljucem (253): z vec CTE-ji hkrati je optimizator
     izbral nacrt, ki je tekel 14 s namesto manj kot sekundo. */
  CREATE TABLE #Supplied (OrganizationId int NOT NULL, Code nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL, ProductCount bigint NOT NULL,
    PRIMARY KEY (OrganizationId, Code));
  INSERT #Supplied (OrganizationId, Code, ProductCount)
  SELECT product.OrganizationId, product.Supplier, COUNT_BIG(*)
  FROM canon.Product AS product
  WHERE product.Supplier IS NOT NULL AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
  GROUP BY product.OrganizationId, product.Supplier;

  CREATE TABLE #Made (OrganizationId int NOT NULL, Code nvarchar(200) COLLATE DATABASE_DEFAULT NOT NULL, ProductCount bigint NOT NULL,
    PRIMARY KEY (OrganizationId, Code));
  INSERT #Made (OrganizationId, Code, ProductCount)
  SELECT product.OrganizationId, product.Manufacturer, COUNT_BIG(*)
  FROM canon.Product AS product
  WHERE product.Manufacturer IS NOT NULL AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
  GROUP BY product.OrganizationId, product.Manufacturer;

  /* Skupine popustov vseh strank naenkrat, natanko kot v stranke.csv (253). */
  CREATE TABLE #ExportGroups (CustomerId bigint NOT NULL PRIMARY KEY, GroupDiscounts nvarchar(max) NULL);
  INSERT #ExportGroups (CustomerId, GroupDiscounts)
  SELECT effective.CustomerId,
    STRING_AGG(CONVERT(nvarchar(max), effective.ItemGroupCode + N''='' + out.MagentoNumber(effective.PercentValue) + N''%''), N'' | '')
      WITHIN GROUP (ORDER BY effective.ItemGroupCode)
  FROM b2b.CustomerGroupDiscounts(@Today) AS effective
  GROUP BY effective.CustomerId;

  WITH base AS
  (
    SELECT
      customer.CustomerId, customer.OrganizationId, OrganizationName = organization.Name,
      customer.CustomerKey,
      Name = COALESCE(generalOverride.Name, customer.Name),
      City = COALESCE(generalOverride.City, customer.City),
      TaxNumber = COALESCE(generalOverride.TaxNumber, customer.TaxNumber),
      IsActive = CONVERT(bit, ISNULL(COALESCE(generalOverride.IsActive, customer.IsActive), 0)),
      SourceIsActive = CONVERT(bit, ISNULL(customer.IsActive, 0)),
      SaopPartnerType = COALESCE(generalOverride.CustomerType, customer.CustomerType),
      PriceListCode = COALESCE(generalOverride.PriceListCode, customer.PriceListCode),
      DiscountPriceListCode = COALESCE(generalOverride.DiscountPriceListCode, customer.DiscountPriceListCode),
      HasProfile = CONVERT(bit, CASE WHEN profile.CustomerId IS NULL THEN 0 ELSE 1 END),
      profile.CustomerTypeCode, CustomerTypeName = typeCatalog.Name, magentoGroup.MagentoGroupKey,
      ManualKind = profile.CustomerKind,
      /* PE/tranzit (253): rocno na profilu, sicer iz tipa - isto kot b2b.CustomerGroupDiscounts. */
      PayerKind = COALESCE(profile.PayerKind, CASE
        WHEN profile.CustomerTypeCode LIKE N''%[_]BRANCH%'' THEN N''PE''
        WHEN profile.CustomerTypeCode LIKE N''%[_]TRANSIT%'' THEN N''TRANZIT'' END),
      SuppliedProductCount = CONVERT(int, ISNULL(supplied.ProductCount, 0)),
      ManufacturedProductCount = CONVERT(int, ISNULL(made.ProductCount, 0)),
      PackagingDiscountEnabled = CONVERT(bit, ISNULL(profile.PackagingDiscountEnabled, 0)),
      ValueDiscountEnabled = CONVERT(bit, ISNULL(profile.ValueDiscountEnabled, 0)),
      B2bPlusEnabled = CONVERT(bit, ISNULL(profile.B2bPlusEnabled, 0)),
      profile.B2bPlusValidFrom, profile.B2bPlusValidTo,
      WebEnabled = CONVERT(bit, ISNULL(profile.WebEnabled, 0)),
      contact.Email, contact.Phone, contact.Mobile, contact.Persons
    FROM b2b.Customer AS customer
    INNER JOIN dbo.OrganizationConfig AS organization ON organization.OrganizationId = customer.OrganizationId
    LEFT JOIN pim.CustomerGeneralOverride AS generalOverride
      ON generalOverride.OrganizationId = customer.OrganizationId AND generalOverride.CustomerId = customer.CustomerId
    LEFT JOIN pim.CustomerWebProfile AS profile ON profile.CustomerId = customer.CustomerId
    LEFT JOIN pim.CustomerTypeCatalog AS typeCatalog ON typeCatalog.CustomerTypeCode = profile.CustomerTypeCode
    /* Brez IsActive, natanko kot izvoz stranke.csv (out.GetExportRows, vir PIM_CUSTOMER). */
    LEFT JOIN pim.CustomerTypeMagentoGroup AS magentoGroup ON magentoGroup.CustomerTypeCode = profile.CustomerTypeCode
    LEFT JOIN pim.CustomerContact AS contact
      ON contact.OrganizationId = customer.OrganizationId AND contact.CustomerId = customer.CustomerId
    LEFT JOIN #Supplied AS supplied ON supplied.OrganizationId = customer.OrganizationId AND supplied.Code = customer.CustomerKey
    LEFT JOIN #Made AS made ON made.OrganizationId = customer.OrganizationId AND made.Code = customer.CustomerKey
    WHERE @OrganizationId IS NULL OR customer.OrganizationId = @OrganizationId
  )
  SELECT
    base.*,
    IsSupplier = derived.IsSupplier,
    IsManufacturer = derived.IsManufacturer,
    IsBuyer = CONVERT(bit, CASE
      WHEN base.ManualKind IS NOT NULL THEN CASE WHEN base.ManualKind IN (N''CUSTOMER'', N''BOTH'') THEN 1 ELSE 0 END
      WHEN base.CustomerTypeCode IS NOT NULL OR base.SaopPartnerType = N''K''
        OR (derived.IsSupplier = 0 AND derived.IsManufacturer = 0) THEN 1
      ELSE 0 END),
    RoleSource = CASE
      WHEN base.ManualKind IS NOT NULL THEN N''MANUAL''
      WHEN base.SuppliedProductCount > 0 OR base.ManufacturedProductCount > 0 THEN N''PRODUCTS''
      WHEN base.SaopPartnerType IN (N''D'', N''K'') THEN N''SAOP''
      WHEN base.CustomerTypeCode IS NOT NULL THEN N''TYPE''
      ELSE N''DEFAULT'' END,
    InCustomerExport = CONVERT(bit, CASE WHEN base.SourceIsActive = 1 AND base.HasProfile = 1 THEN 1 ELSE 0 END),
    Tier1Threshold = tier1.ThresholdGrossExVat, Tier1Percent = tier1.PercentValue,
    Tier2Threshold = tier2.ThresholdGrossExVat, Tier2Percent = tier2.PercentValue,
    Tier3Threshold = tier3.ThresholdGrossExVat, Tier3Percent = tier3.PercentValue,
    /* Ena vrednost na skupino artiklov, ista izbira kot v stranke.csv (205): najnovejsi zacetek,
       nato zadnji vnos. Neveljavni danes so tu vidni, ker so se vedno aktivni in urejljivi. */
    GroupDiscounts =
    (
      SELECT STRING_AGG(CONVERT(nvarchar(max), picked.ItemGroupCode + N''='' + out.MagentoNumber(picked.PercentValue)), N'' | '')
        WITHIN GROUP (ORDER BY picked.ItemGroupCode)
      FROM
      (
        SELECT groupRule.ItemGroupCode, groupRule.PercentValue,
          PickRank = ROW_NUMBER() OVER (PARTITION BY groupRule.ItemGroupCode ORDER BY groupRule.ValidFrom DESC, groupRule.OverrideId DESC)
        FROM b2b.GroupDiscountOverride AS groupRule
        WHERE groupRule.TargetKind = N''CUSTOMER'' AND groupRule.CustomerId = base.CustomerId
          AND groupRule.OrganizationId = base.OrganizationId AND groupRule.IsActive = 1
      ) AS picked
      WHERE picked.PickRank = 1
    ),
    SpecialDiscounts =
    (
      SELECT STRING_AGG(CONVERT(nvarchar(max), product.ItemID + N''\'' + special.DiscountCode), N'' | '')
        WITHIN GROUP (ORDER BY product.ItemID)
      FROM b2b.CustomerPackagingDiscountOverride AS special
      INNER JOIN pim.Product AS product ON product.PimProductId = special.PimProductId
      WHERE special.CustomerId = base.CustomerId AND special.IsActive = 1
    ),
    /* Skupine popustov natanko tako, kot gredo v stranke.csv (253): isto pravilo, isti zapis. */
    ExportGroupDiscounts = exportGroups.GroupDiscounts
  FROM base
  CROSS APPLY
  (
    SELECT
      IsSupplier = CONVERT(bit, CASE
        WHEN base.ManualKind IS NOT NULL THEN CASE WHEN base.ManualKind IN (N''SUPPLIER'', N''BOTH'') THEN 1 ELSE 0 END
        WHEN base.SuppliedProductCount > 0 OR base.SaopPartnerType = N''D'' THEN 1
        ELSE 0 END),
      IsManufacturer = CONVERT(bit, CASE
        WHEN base.ManualKind IS NOT NULL THEN CASE WHEN base.ManualKind = N''MANUFACTURER'' THEN 1 ELSE 0 END
        WHEN base.ManufacturedProductCount > 0 THEN 1
        ELSE 0 END)
  ) AS derived
  LEFT JOIN #ExportGroups AS exportGroups ON exportGroups.CustomerId = base.CustomerId
  LEFT JOIN pim.CustomerValueDiscountTier AS tier1 ON tier1.CustomerId = base.CustomerId AND tier1.TierNumber = 1 AND tier1.IsActive = 1
  LEFT JOIN pim.CustomerValueDiscountTier AS tier2 ON tier2.CustomerId = base.CustomerId AND tier2.TierNumber = 2 AND tier2.IsActive = 1
  LEFT JOIN pim.CustomerValueDiscountTier AS tier3 ON tier3.CustomerId = base.CustomerId AND tier3.TierNumber = 3 AND tier3.IsActive = 1
  ORDER BY base.Name, base.OrganizationId, base.CustomerKey
  OPTION (RECOMPILE);
END;');

/* --- Preverbe ---------------------------------------------------------------------------------- */
IF OBJECT_ID(N'b2b.CustomerGroupDiscounts', N'IF') IS NULL THROW 52535, N'253: funkcija b2b.CustomerGroupDiscounts ni nastala.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows')) NOT LIKE N'%/* SaopGroups253 */%'
  OR OBJECT_DEFINITION(OBJECT_ID(N'out.GetExportRows')) LIKE N'%/* CatalogCustomer205 */%'
  THROW 52536, N'253: out.GetExportRows ne bere skupin popustov iz b2b.CustomerGroupDiscounts.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'intranet.GetCustomerCard')) NOT LIKE N'%/* SaopGroups253 */%'
  THROW 52537, N'253: kartica stranke ne bere skupin popustov iz b2b.CustomerGroupDiscounts.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'intranet.GetCustomerList')) NOT LIKE N'%ExportGroupDiscounts%'
  THROW 52538, N'253: seznam strank nima stolpca ExportGroupDiscounts.', 1;
