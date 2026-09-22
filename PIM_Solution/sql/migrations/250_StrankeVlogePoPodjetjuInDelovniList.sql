/*
  250 - Stranke: vloga (kupec / dobavitelj / proizvajalec) po podjetju, seznam vseh podjetij in
  delovni list za mnozicno urejanje popustov.

  Uporabnik 2026-09-22: stran Stranke nima uporabnih filtrov ne izvoza za paketno urejanje kot pri
  izdelkih; dolociti je treba, kdo je dobavitelj in kdo proizvajalec, in pod "Dobavitelji" mora biti
  vidno, za katero podjetje - "dobavitelj Nowodvorski ima za IQ drugo sifro kot za VIDadria podjetje
  in tako se mora tudi filter obnasati, da ne pokaze obeh, ampak samo za doloceno podjetje, ce je
  filtriran; ce ni, pokaze vse dobavitelje".

  Stanje pred migracijo (lokalna baza, 2026-09-22):
    - Stran /stranke je brala intranet.GetCustomers za PRVO aktivno podjetje (DEMO, 1.614 strank).
      IQLighting (4.721), Vidadria (4.672) in Ediito (616) na strani sploh niso bili vidni.
    - pim.CustomerWebProfile.CustomerKind je samo rocen (098) in je prazen pri vseh strankah, zato
      so zavihki Kupci / Dobavitelji / Proizvajalci kazali 0.
    - Dobavitelj in proizvajalec izdelka sta SAOP sifri partnerja ISTEGA podjetja
      (canon.Product.Supplier / Manufacturer = b2b.Customer.CustomerKey, 115 canon.PartnerName).
      Ista firma ima v vsakem podjetju svojo sifro (Nowodvorski: Vidadria dobavitelj 0001209,
      proizvajalec 0000081; IQLighting 00001625), ista sifra pa je v dveh podjetjih lahko druga
      firma (0000499: Vidadria DETAS, Ediito LUCEPLAN).
    - intranet.GetProductListFilters je brez izbranega podjetja zdruzil sifre cez podjetja
      (GROUP BY koda, MAX imena): 0000499 je bil en vnos, filter pa je nasel izdelke obeh firm.

  Pravilo vloge (izracun ob branju; nic se ne zapise in nic ne prepise rocne odlocitve):
    1. Rocna vrsta s kartice (CustomerKind) prevlada: CUSTOMER = kupec, SUPPLIER = dobavitelj,
       BOTH = kupec in dobavitelj, MANUFACTURER = proizvajalec.
    2. Brez rocne vrste:
         dobavitelj   = sifra je dobavitelj vsaj enega izdelka SVOJEGA podjetja ali SAOP vrsta 'D';
         proizvajalec = sifra je proizvajalec vsaj enega izdelka svojega podjetja;
         kupec        = ima tip stranke (B2B) ali SAOP vrsto 'K' ali ni ne dobavitelj ne proizvajalec.
       SAOP 'O' (99 % partnerjev) ne pove nicesar (098) in se ne uporablja.
    Vse se steje znotraj podjetja stranke, nikoli cez podjetja.

  Kaj naredi:
    1. intranet.GetCustomerList @OrganizationId = NULL (vsa podjetja): ena vrstica na stranko s
       podjetjem, ucinkovitimi splosnimi podatki (rocni prepis 200 prevlada), vlogo in njenim
       virom, stevilom izdelkov, ki jih dobavlja/proizvaja, B2B nastavitvami, lastnimi pragovi,
       skupinskimi popusti stranke, posebnimi S po izdelku, kontakti in SAOP rabati po rabatnem
       ceniku (samo za branje). Iz tega berejo stran /stranke, izvoz /izvoz/stranke.xlsx in uvoz
       /stranke/uvoz - kar vidis, to izvozis, in uvoz primerja z istim stanjem.
       "V stranke.csv" je isto pravilo kot out.GetExportRows (202): aktivna v SAOP + B2B profil.
    2. b2b.RemoveCustomerValueTier in b2b.RemoveGroupDiscountOverride - umik lastnega praga
       (velja splosna lestvica) in skupinskega popusta stranke. Do zdaj ju ni bilo: prag in
       skupinski popust se je dalo samo dodati. Oba z revizijsko sledjo b2b.AuditLog.
    3. intranet.GetProductListFilters: brez izbranega podjetja je faceta proizvajalca/dobavitelja
       en vnos na PODJETJE in sifro, vrednost "podjetje:sifra" (FacetCode in OrganizationName
       povesta oboje posebej); z izbranim podjetjem ostane vrednost gola sifra kot doslej.
       ProductWorkbenchService.GetProductListAsync "3:0001209" razume kot podjetje 3 + sifra.
       Privzeti @Take 100 je bil premajhen (Vidadria ima 124 dobaviteljev); meja ostane 500.

  Cesa NE naredi: izvoza out.GetExportRows ne spreminja (stranke.csv in katalog.csv bereta iste
  tabele, v katere pise uvoz - preverjeno v pogovoru 2026-09-22), CustomerKind se ne polni sam.
*/
SET XACT_ABORT ON;
SET NOCOUNT ON;

/* --- 1) Seznam strank vseh podjetij z vlogo ---------------------------------------------------- */
EXEC(N'CREATE OR ALTER PROCEDURE intranet.GetCustomerList
  @OrganizationId int = NULL
AS
BEGIN
  SET NOCOUNT ON;

  DECLARE @Today date = CONVERT(date, SYSUTCDATETIME());

  WITH supplied AS
  (
    SELECT product.OrganizationId, Code = product.Supplier, ProductCount = COUNT_BIG(*)
    FROM canon.Product AS product
    WHERE product.Supplier IS NOT NULL AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
    GROUP BY product.OrganizationId, product.Supplier
  ),
  made AS
  (
    SELECT product.OrganizationId, Code = product.Manufacturer, ProductCount = COUNT_BIG(*)
    FROM canon.Product AS product
    WHERE product.Manufacturer IS NOT NULL AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
    GROUP BY product.OrganizationId, product.Manufacturer
  ),
  base AS
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
    LEFT JOIN supplied ON supplied.OrganizationId = customer.OrganizationId AND supplied.Code = customer.CustomerKey
    LEFT JOIN made ON made.OrganizationId = customer.OrganizationId AND made.Code = customer.CustomerKey
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
    /* SAOP rabati po skupinah artiklov se vezejo na stranko prek rabatnega cenika
       (b2b.Customer.DiscountPriceListCode = CustomerItemGroupDiscount.CustomerGroupCode). SAOP
       hrani vsako spremembo kot novo vrstico z novim zacetkom; velja zadnja danes veljavna. */
    SaopGroupDiscounts =
    (
      SELECT STRING_AGG(CONVERT(nvarchar(max), picked.ItemGroupCode + N''='' + ISNULL(out.MagentoNumber(picked.DiscountPercent), N''?'')
          + CASE WHEN ISNULL(picked.MinQuantity, 0) = 0 THEN N'''' ELSE N'' (od '' + out.MagentoNumber(picked.MinQuantity) + N'' kos)'' END), N'' | '')
        WITHIN GROUP (ORDER BY picked.ItemGroupCode)
      FROM
      (
        SELECT saop.ItemGroupCode, saop.DiscountPercent, saop.MinQuantity,
          PickRank = ROW_NUMBER() OVER (PARTITION BY saop.ItemGroupCode ORDER BY saop.ValidFrom DESC, saop.CustomerItemGroupDiscountId DESC)
        FROM b2b.CustomerItemGroupDiscount AS saop
        WHERE saop.OrganizationId = base.OrganizationId AND saop.CustomerGroupCode = base.DiscountPriceListCode
          AND saop.ValidFrom <= @Today AND (saop.ValidTo IS NULL OR saop.ValidTo >= @Today)
      ) AS picked
      WHERE picked.PickRank = 1
    )
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
  LEFT JOIN pim.CustomerValueDiscountTier AS tier1 ON tier1.CustomerId = base.CustomerId AND tier1.TierNumber = 1 AND tier1.IsActive = 1
  LEFT JOIN pim.CustomerValueDiscountTier AS tier2 ON tier2.CustomerId = base.CustomerId AND tier2.TierNumber = 2 AND tier2.IsActive = 1
  LEFT JOIN pim.CustomerValueDiscountTier AS tier3 ON tier3.CustomerId = base.CustomerId AND tier3.TierNumber = 3 AND tier3.IsActive = 1
  ORDER BY base.Name, base.OrganizationId, base.CustomerKey
  OPTION (RECOMPILE);
END;');

/* --- 2) Umik lastnega praga in skupinskega popusta ------------------------------------------- */
EXEC(N'CREATE OR ALTER PROCEDURE b2b.RemoveCustomerValueTier
  @OrganizationId int,
  @CustomerId bigint,
  @TierNumber tinyint,
  @ChangedBy nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  IF NOT EXISTS (SELECT 1 FROM b2b.Customer WHERE CustomerId = @CustomerId AND OrganizationId = @OrganizationId)
    THROW 52000, N''Stranka ne obstaja.'', 1;

  DECLARE @Old nvarchar(max) = (SELECT * FROM pim.CustomerValueDiscountTier
    WHERE CustomerId = @CustomerId AND TierNumber = @TierNumber AND IsActive = 1 FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
  IF @Old IS NULL RETURN;

  BEGIN TRANSACTION;
  UPDATE pim.CustomerValueDiscountTier SET IsActive = 0 WHERE CustomerId = @CustomerId AND TierNumber = @TierNumber;
  INSERT b2b.AuditLog (OrganizationId, EntityType, EntityKey, ActionCode, OldValueJson, NewValueJson, ChangedBy)
  SELECT @OrganizationId, N''CustomerValueTier'', CONCAT(@CustomerId, N'':'', @TierNumber), N''DEACTIVATE'', @Old,
    (SELECT * FROM pim.CustomerValueDiscountTier WHERE CustomerId = @CustomerId AND TierNumber = @TierNumber FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
    @ChangedBy;
  COMMIT;
END;');

EXEC(N'CREATE OR ALTER PROCEDURE b2b.RemoveGroupDiscountOverride
  @OrganizationId int,
  @OverrideId bigint,
  @ChangedBy nvarchar(200)
AS
BEGIN
  SET NOCOUNT ON;
  SET XACT_ABORT ON;

  DECLARE @Old nvarchar(max) = (SELECT * FROM b2b.GroupDiscountOverride
    WHERE OverrideId = @OverrideId AND OrganizationId = @OrganizationId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
  IF @Old IS NULL THROW 52551, N''Skupinski popust ne obstaja ali ne pripada temu podjetju.'', 1;

  BEGIN TRANSACTION;
  UPDATE b2b.GroupDiscountOverride SET IsActive = 0 WHERE OverrideId = @OverrideId AND OrganizationId = @OrganizationId;
  INSERT b2b.AuditLog (OrganizationId, EntityType, EntityKey, ActionCode, OldValueJson, NewValueJson, ChangedBy)
  SELECT @OrganizationId, N''GroupDiscountOverride'', CONVERT(nvarchar(30), @OverrideId), N''DEACTIVATE'', @Old,
    (SELECT * FROM b2b.GroupDiscountOverride WHERE OverrideId = @OverrideId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
    @ChangedBy;
  COMMIT;
END;');

/* --- 3) Facete izdelkov: partner je par (podjetje, sifra) ------------------------------------ */
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
    WHERE @UnknownOrganization = 0 AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
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
    WHERE @UnknownOrganization = 0 AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
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
  WHERE @UnknownOrganization = 0 AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
    AND product.ItemGroup IS NOT NULL
  GROUP BY product.ItemGroup
  ORDER BY COUNT_BIG(*) DESC, product.ItemGroup
  OPTION (RECOMPILE);

  SELECT TOP (@Take) FacetKind = N''DEPARTMENT'', FacetValue = product.Department,
    FacetLabel = product.Department, ProductCount = COUNT_BIG(*),
    FacetCode = product.Department, OrganizationName = CONVERT(nvarchar(200), NULL)
  FROM canon.Product AS product
  WHERE @UnknownOrganization = 0 AND (@OrganizationId IS NULL OR product.OrganizationId = @OrganizationId)
    AND product.Department IS NOT NULL
  GROUP BY product.Department
  ORDER BY COUNT_BIG(*) DESC, product.Department
  OPTION (RECOMPILE);
END;');

/* --- Preverbe ---------------------------------------------------------------------------------- */
IF OBJECT_ID(N'intranet.GetCustomerList', N'P') IS NULL
  OR OBJECT_ID(N'b2b.RemoveCustomerValueTier', N'P') IS NULL
  OR OBJECT_ID(N'b2b.RemoveGroupDiscountOverride', N'P') IS NULL
  THROW 52552, N'250: procedure strank niso nastale.', 1;
IF OBJECT_DEFINITION(OBJECT_ID(N'intranet.GetProductListFilters')) NOT LIKE N'%FacetCode%'
  THROW 52553, N'250: intranet.GetProductListFilters ne vraca para (podjetje, sifra).', 1;
